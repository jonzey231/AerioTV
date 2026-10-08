#if canImport(CarPlay)
import CarPlay
import CoreMedia
import UIKit
import Combine
import SwiftData

/// CarPlay scene delegate. Audio-first channel browsing via CarPlay
/// templates, built to run STANDALONE: it hydrates its own channel list
/// from the shared SwiftData container if the phone UI scene has not run,
/// so connecting from a cold car (phone app never opened) still works.
///
/// `@MainActor`: CarPlay's template APIs are main-actor-isolated
/// (CARPLAY_TEMPLATE_UI_ACTOR) and scene-delegate callbacks arrive on the
/// main thread, so the whole delegate is main-actor and reads the shared
/// `@MainActor` stores directly. (An earlier `DispatchQueue.main.sync`
/// here deadlocked the main thread and crashed the app on connect.)
/// Escaping closures (the store observer and CarPlay list handlers) are
/// nonisolated but always invoked on main, so they hop back via
/// `MainActor.assumeIsolated`.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    // Held so the store observer can refresh their sections in place when
    // a standalone channel load completes, instead of swapping the root.
    private var favoritesTemplate: CPListTemplate?
    private var groupsTemplate: CPListTemplate?
    private var cancellables = Set<AnyCancellable>()
    /// Whether the current root is the Favorites+Groups tab bar. The root
    /// is chosen at connect; if favorites appear later (iCloud sync, or the
    /// user stars a channel on the phone) the root is rebuilt once.
    private var rootHasFavoritesTab = false
    /// Remaining retries for a cold connect that raced app init
    /// (`AerioApp.sharedContainer` still nil).
    private var hydrateRetriesLeft = 5
    /// Session capabilities (CarPlay video support lives here). Created on
    /// connect; `supportsVideoPlayback` is stable for the session per Apple,
    /// only the moment-to-moment availability changes (handled by the system
    /// dropping to audio-only while driving).
    private var sessionConfiguration: CPSessionConfiguration?

    /// True when this car session can present video (iOS 26.4+ car with the
    /// video-in-car feature; requires our carplay-video entitlement).
    private var carSupportsVideo: Bool {
        if #available(iOS 26.4, *), let config = sessionConfiguration {
            return config.supportsVideoPlayback
        }
        return false
    }

    // MARK: - Scene Lifecycle

    /// The car window handed to us by the window-variant connect callback
    /// (video-entitled sessions). Held for the video phase (self-rendered
    /// playback draws into this window); templates ignore it.
    private var carWindow: CPWindow?

    /// WINDOW-VARIANT connect (field find 2026-08-31, rPlayTV parity):
    /// with com.apple.developer.carplay-video in the binary, CarPlay
    /// connects the scene through THIS callback - the same window-bearing
    /// variant navigation apps get - and never calls the windowless one.
    /// Implementing only the windowless variant made a video-entitled
    /// build sit frozen on a blank pane: no callback fired, no templates
    /// were ever set (A/B verified: removing just the entitlement key
    /// restored the windowless callback and instant launch). Forward to
    /// the shared connect path; keep the window for the video phase.
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        debugLog("[CarPlay] didConnect (window variant): window=\(window.bounds.size)")
        carWindow = window
        self.templateApplicationScene(scene, didConnect: interfaceController)
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        carWindow = nil
        self.templateApplicationScene(scene,
                                      didDisconnectInterfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        // Release-build visible (Logan's real-car session 2026-08-07 was a
        // black box: every CarPlay log line was DEBUG-only print, so "channels
        // never loaded in the car" could not be told apart from "process was
        // never launched").
        debugLog("[CARPLAY] connect: channels=\(ChannelStore.shared.channels.count) hasFavorites=\(FavoritesStore.shared.hasFavorites) fgScene=\(HeadlessPlaybackController.hasForegroundPlayerScene())")

        sessionConfiguration = CPSessionConfiguration(delegate: self)
        HeadlessPlaybackController.shared.videoCapable = carSupportsVideo
        debugLog("[CARPLAY] connect: session video support=\(carSupportsVideo) phoneLocked=\(!UIApplication.shared.isProtectedDataAvailable) appState=\(UIApplication.shared.applicationState.rawValue)")

        // A car can be the only scene (phone app never opened), so mark the
        // session, default it to audio-only, hydrate channels if the store
        // is empty, and observe the store so the lists fill in once the
        // load lands.
        NowPlayingManager.shared.isCarPlayConnected = true
        CarPlaySceneDelegate.suspendKeepAlive(reason: "car connected")
        // A channel already playing on the phone moves to the car (the phone
        // goes idle, like any media app): Cast-style hand-off.
        if let playing = NowPlayingManager.shared.playingItem,
           MultiviewStore.shared.tiles.count > 0 {
            debugLog("[CARPLAY] connect: phone was playing \(playing.name); handing it to the car")
            endPhoneSession(reason: "car connected")
            HeadlessPlaybackController.shared.start(
                item: playing, server: ChannelStore.shared.activeServer,
                isLive: true, videoCapable: carSupportsVideo)
        }
        hydrateRetriesLeft = 5
        hydrateChannelsIfNeeded()

        setRoot(animated: false)
        // After the root exists, so the observers' first emissions refresh
        // it instead of racing it.
        observeChannelStore()
    }

    private func setRoot(animated: Bool) {
        let root = buildRootTemplate()
        interfaceController?.setRootTemplate(root, animated: animated) { ok, err in
            if !ok || err != nil {
                debugLog("[CARPLAY] error: setRootTemplate ok=\(ok) err=\(String(describing: err))")
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        let headlessOwned = HeadlessPlaybackController.shared.isActive
        debugLog("[CARPLAY] teardown: car disconnected headlessActive=\(headlessOwned) fgScene=\(HeadlessPlaybackController.hasForegroundPlayerScene())")
        self.interfaceController = nil
        favoritesTemplate = nil
        groupsTemplate = nil
        sessionConfiguration = nil
        cancellables.removeAll()
        NowPlayingManager.shared.isCarPlayConnected = false
        HeadlessPlaybackController.shared.videoCapable = false
        // The phone sat idle while the car played, so there is no phone
        // session to restore: stopping the car engine ends playback.
        HeadlessPlaybackController.shared.stop()
        CarPlaySceneDelegate.resumeKeepAlive()
    }

    // MARK: - Standalone hydration

    /// Kick off a channel load if nothing is loaded yet. Reads the saved
    /// servers straight from the shared SwiftData container so this works
    /// without the SwiftUI UI scene, which is what normally drives
    /// `ChannelStore.refresh`. `refresh` is idempotent, so a later phone-UI
    /// launch will not double-load.
    private func hydrateChannelsIfNeeded() {
        // Every bail is logged: the cold-car empty-list report hinged on
        // knowing which of these guards fired, and none of them said a word.
        guard !ChannelStore.shared.isLoading else {
            debugLog("[CARPLAY] hydrate: skip, load already in flight")
            return
        }
        guard let container = AerioApp.sharedContainer else {
            // Cold launch by the car can deliver the scene before the app
            // struct finished init. Used to be a permanent empty list.
            debugLog("[CARPLAY] error: hydrate: sharedContainer is nil, retries left \(hydrateRetriesLeft)")
            if hydrateRetriesLeft > 0 {
                hydrateRetriesLeft -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.interfaceController != nil else { return }
                        self.hydrateChannelsIfNeeded()
                    }
                }
            }
            return
        }
        let context = ModelContext(container)
        let servers = (try? context.fetch(FetchDescriptor<ServerConnection>())) ?? []
        guard !servers.isEmpty else {
            debugLog("[CARPLAY] hydrate: FAIL, 0 servers fetched from SwiftData")
            return
        }

        let hadChannels = !ChannelStore.shared.channels.isEmpty
        let lanBefore = TVLANProbe.persistedLANDetected
        debugLog("[CARPLAY] hydrate: servers=\(servers.count) hadChannels=\(hadChannels) lanBefore=\(lanBefore)")
        Task { @MainActor in
            // THE 2026-08-07 real-car failure: the LAN/WAN routing flag is
            // persisted from the LAST probe (usually "home, LAN reachable"),
            // and the probe itself only ever ran from the phone UI scene. A
            // cold car connect on cellular therefore built every channel and
            // stream URL against the unreachable LAN host - channels never
            // loaded, and nothing played. Seed the probe with OUR servers
            // (RootView may never run in a car-only launch), await a
            // definitive answer, then (re)build channels with correctly
            // routed URLs. Also covers the phone-was-open-at-home case: a
            // connect re-probes and rebuilds when the network flipped.
            TVLANProbe.shared.probe(servers: servers)
            let lanNow = await TVLANProbe.shared.reprobeAndWait()
            // A verdict with no candidate (no Local URL on the active
            // playlist) returns at once and always routes the public URL.
            let active = servers.first(where: { $0.isActive }) ?? servers.first
            let hasLocal = !(active?.localURL.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            debugLog("[CARPLAY] hydrate: LAN probe -> \(lanNow) (was \(lanBefore)) activeHasLocalURL=\(hasLocal)")
            if !hadChannels || lanNow != lanBefore {
                ChannelStore.shared.refresh(servers: servers)
            }
        }
    }

    /// Refresh the CarPlay lists in place whenever the channel list changes
    /// (the standalone load above completing, or a server switch on the
    /// phone while connected).
    private func observeChannelStore() {
        // Debounced: the store republishes on every EPG merge, and each
        // refresh rebuilds every row (and refetches favorites' logos).
        ChannelStore.shared.$channels
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] channels in
                MainActor.assumeIsolated {
                    // Favorites resolve their rows from the channel list, and
                    // only the phone's channel list view did that. A car-only
                    // launch therefore showed an empty Favorites tab forever.
                    if !channels.isEmpty {
                        FavoritesStore.shared.register(items: channels)
                    }
                    debugLog("[CARPLAY] lists: channels=\(channels.count) groups=\(ChannelStore.shared.orderedGroups.count) favorites=\(FavoritesStore.shared.favoriteItems.count)")
                    self?.refreshLists()
                }
            }
            .store(in: &cancellables)

        FavoritesStore.shared.$favoriteItems
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLists() }
            }
            .store(in: &cancellables)

        // Loading -> loaded flips the empty-state copy ("Loading channels"
        // vs "No Channels") even when the channel array itself is unchanged.
        ChannelStore.shared.$isLoading
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLists() }
            }
            .store(in: &cancellables)

        // Rebuild rows when the playing channel changes so the isPlaying
        // indicator and per-item playback configuration (play vs none on a
        // video-capable car) track reality, not just list-build time.
        HeadlessPlaybackController.shared.$carItem
            .receive(on: RunLoop.main)
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLists() }
            }
            .store(in: &cancellables)
    }

    private func refreshLists() {
        guard interfaceController != nil else { return }
        // Root chosen at connect without favorites, favorites exist now
        // (or the reverse): rebuild the root once instead of leaving the
        // Favorites tab missing (or empty) for the whole drive.
        if FavoritesStore.shared.hasFavorites != rootHasFavoritesTab {
            debugLog("[CARPLAY] lists: favorites \(rootHasFavoritesTab ? "gone" : "appeared"), rebuilding root")
            setRoot(animated: false)
            return
        }
        favoritesTemplate?.updateSections(favoritesSections())
        groupsTemplate?.updateSections(groupsSections())
        applyEmptyState(favoritesTemplate, kind: .favorites)
        applyEmptyState(groupsTemplate, kind: .groups)
    }

    // MARK: - Root template

    /// Choose the root: a Favorites/Groups tab bar when the user has saved
    /// favorites, or the Groups list on its own when they have none. With no
    /// favorites the Favorites tab would always be empty, so a tab bar whose
    /// only useful tab is Groups is just an extra tap; dropping straight into
    /// Groups is cleaner. The decision uses `FavoritesStore.hasFavorites`
    /// (persisted IDs), so it is correct even on a cold connect where the
    /// channel list has not resolved `favoriteItems` yet.
    private func buildRootTemplate() -> CPTemplate {
        let groups = makeGroupsTemplate()
        groupsTemplate = groups

        rootHasFavoritesTab = FavoritesStore.shared.hasFavorites
        guard FavoritesStore.shared.hasFavorites else {
            // No favorites: Groups is the whole experience, no tab bar.
            favoritesTemplate = nil
            #if DEBUG
            print("[CarPlay] buildRootTemplate: no favorites -> Groups list as root, groups=\(ChannelStore.shared.orderedGroups.count)")
            #endif
            return groups
        }
        #if DEBUG
        print("[CarPlay] buildRootTemplate: tab bar (Favorites+Groups), favorites=\(FavoritesStore.shared.favoriteItems.count) groups=\(ChannelStore.shared.orderedGroups.count)")
        #endif

        let favorites = makeFavoritesTemplate()
        favoritesTemplate = favorites
        // CPTabBarTemplate only accepts CPListTemplate / CPGridTemplate as
        // tabs. CPNowPlayingTemplate is NOT valid here (it threw at
        // validateTemplates); Now Playing is reached via CarPlay's built-in
        // Now Playing button and the pushTemplate in playChannel.
        return CPTabBarTemplate(templates: [favorites, groups])
    }

    private enum TabKind { case favorites, groups }

    // MARK: - Favorites

    private func makeFavoritesTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Favorites", sections: favoritesSections())
        template.tabSystemItem = .favorites
        applyEmptyState(template, kind: .favorites)
        return template
    }

    private func favoritesSections() -> [CPListSection] {
        let items = Self.capped(FavoritesStore.shared.favoriteItems).map { makeChannelItem($0) }
        return [CPListSection(items: items)]
    }

    // MARK: - Groups

    private func makeGroupsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Groups", sections: groupsSections())
        template.tabSystemItem = .more
        applyEmptyState(template, kind: .groups)
        return template
    }

    private func groupsSections() -> [CPListSection] {
        let channels = ChannelStore.shared.channels
        let groupItems: [CPListItem] = Self.capped(ChannelStore.shared.orderedGroups).map { groupName in
            let count = channels.filter { $0.group == groupName }.count
            let item = CPListItem(
                text: groupName,
                detailText: "\(count) channel\(count == 1 ? "" : "s")"
            )
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated { self?.showChannelsInGroup(groupName) }
                completion()
            }
            item.accessoryType = .disclosureIndicator
            return item
        }
        return [CPListSection(items: groupItems)]
    }

    /// Push a channel list for a specific group.
    private func showChannelsInGroup(_ group: String) {
        let channels = ChannelStore.shared.channels.filter { $0.group == group }
        let items = Self.capped(channels).map { makeChannelItem($0) }
        let template = CPListTemplate(title: group, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// CarPlay rejects lists past the head unit's item limit (it varies by
    /// car; large IPTV groups run to thousands of channels). Trim to the
    /// limit the system reports.
    private static func capped<T>(_ items: [T]) -> [T] {
        let limit = Int(CPListTemplate.maximumItemCount)
        guard limit > 0, items.count > limit else { return items }
        debugLog("[CARPLAY] lists: trimmed \(items.count) rows to the car's limit of \(limit)")
        return Array(items.prefix(limit))
    }

    // MARK: - Empty / loading state

    /// Reflect load state in the list's empty view so a cold connect shows
    /// "Loading…" rather than "No Channels" while the standalone fetch runs.
    private func applyEmptyState(_ template: CPListTemplate?, kind: TabKind) {
        guard let template else { return }
        if ChannelStore.shared.isLoading && ChannelStore.shared.channels.isEmpty {
            template.emptyViewTitleVariants = ["Loading channels…"]
            template.emptyViewSubtitleVariants = ["One moment"]
        } else if ChannelStore.shared.channels.isEmpty {
            template.emptyViewTitleVariants = ["No Channels"]
            template.emptyViewSubtitleVariants = ["Open AerioTV on your phone and add a server"]
        } else {
            switch kind {
            case .favorites:
                template.emptyViewTitleVariants = ["No Favorites"]
                template.emptyViewSubtitleVariants = ["Star channels in the app to see them here"]
            case .groups:
                template.emptyViewTitleVariants = ["No Groups"]
                template.emptyViewSubtitleVariants = ["This server has no channel groups"]
            }
        }
    }

    // MARK: - Program info formatting

    /// Secondary line for a channel row: the current program, how much of
    /// it is left, then a short description, joined with a middle dot. The
    /// order is deliberate so the most glanceable bits lead and CarPlay's
    /// width truncation trims the description first, never the program or
    /// the time. Falls back to the group name when no EPG is available.
    ///
    /// Note: the time-left value is computed when the list is built or
    /// refreshed (cold-connect hydration, an EPG update, or navigating into
    /// a group), not on a per-second ticker, so it can lag a few minutes
    /// between refreshes.
    private func programDetail(for channel: ChannelDisplayItem) -> String {
        var parts: [String] = []
        if let program = channel.currentProgram?.trimmingCharacters(in: .whitespacesAndNewlines),
           !program.isEmpty {
            parts.append(program)
        }
        if let timeLeft = timeRemaining(until: channel.currentProgramEnd) {
            parts.append(timeLeft)
        }
        if let desc = channel.currentProgramDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            parts.append(desc)
        }
        guard !parts.isEmpty else { return channel.group }
        return parts.joined(separator: " · ")
    }

    /// Human "time left" in the current program, or nil when there is no
    /// end time or the program has effectively ended (under ~half a minute
    /// left, or already past).
    private func timeRemaining(until end: Date?) -> String? {
        guard let end else { return nil }
        let secondsLeft = end.timeIntervalSinceNow
        guard secondsLeft > 30 else { return nil }
        let minutesLeft = Int((secondsLeft / 60).rounded())
        if minutesLeft < 60 {
            return "\(minutesLeft) min left"
        }
        let hours = minutesLeft / 60
        let mins = minutesLeft % 60
        return mins == 0 ? "\(hours) hr left" : "\(hours)h \(mins)m left"
    }

    // MARK: - Channel Item Factory

    private func makeChannelItem(_ channel: ChannelDisplayItem) -> CPListItem {
        let item = CPListItem(text: channel.name, detailText: programDetail(for: channel))

        // Load channel logo asynchronously. This Task inherits the
        // delegate's @MainActor isolation; the LogoFetcher await suspends
        // off-main, then setImage runs back on main. v1.6.23: route through
        // LogoFetcher so the active server's auth headers apply.
        if let logoURL = channel.logoURL {
            Task {
                guard !Task.isCancelled else { return }
                // GH #61: decode accepts SVG logos too, so CarPlay rows show
                // artwork for the same channels the list view does.
                if let data = try? await LogoFetcher.fetch(logoURL),
                   let image = AerioImageDecoding.decode(data) {
                    guard !Task.isCancelled else { return }
                    item.setImage(image.scaledToFit(CPListItem.maximumImageSize))
                }
            }
        }

        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated { self?.playChannel(channel) }
            completion()
        }

        let isThisPlaying = HeadlessPlaybackController.shared.carItem?.id == channel.id
        if isThisPlaying {
            item.isPlaying = true
        }

        // CarPlay video (iOS 26.4+): declare the item playable-as-video so a
        // video-capable car presents the stream instead of audio-only Now
        // Playing. Live TV: duration 0 = unknown/live per the API contract,
        // so no progress bar is drawn. Action .play for selectable rows;
        // .none for the row already playing (selecting it just opens Now
        // Playing, it does not toggle pause).
        if #available(iOS 26.4, *), carSupportsVideo {
            item.playbackConfiguration = CPPlaybackConfiguration(
                preferredPresentation: .video,
                playbackAction: isThisPlaying ? .none : .play,
                elapsedTime: .zero,
                duration: .zero
            )
        }
        return item
    }

    // MARK: - Playback

    private func playChannel(_ tappedChannel: ChannelDisplayItem) {
        // Re-resolve against the live store so the seeded tile carries the
        // CURRENT program (and start/end). The `ChannelDisplayItem` captured
        // in the list item's handler is a snapshot from list-build time and
        // can predate the EPG populating `currentProgram`.
        let channel = ChannelStore.shared.channels.first { $0.id == tappedChannel.id } ?? tappedChannel
        guard !channel.streamURLs.isEmpty || channel.streamURL != nil else {
            debugLog("[CARPLAY] error: tune: \(channel.name) has no stream URL")
            return
        }
        let server = ChannelStore.shared.activeServer
        debugLog("[CARPLAY] tune: tap \(channel.name) fgScene=\(HeadlessPlaybackController.hasForegroundPlayerScene()) headless=\(HeadlessPlaybackController.shared.isActive) tiles=\(MultiviewStore.shared.tiles.count)")

        // Logan 2026-10-08 (standing rule): while the app is open in CarPlay
        // the phone never plays video and never presents its player. A car
        // tap only ever drives the headless engine; the phone shows the
        // passive CarPlay dock card. A phone session left over from before
        // (or pinned with Play Here) ends here so there is one producer.
        endPhoneSession(reason: "car tap")
        CarPlaySceneDelegate.suspendKeepAlive(reason: "car tune")

        HeadlessPlaybackController.shared.start(
            item: channel,
            server: server,
            isLive: true,
            videoCapable: carSupportsVideo
        )

        showNowPlaying()
    }

    /// End any phone-side playback session (fullscreen player or tiles) so
    /// the headless engine is the only producer. Never presents anything.
    private func endPhoneSession(reason: String) {
        let tiles = MultiviewStore.shared.tiles.count
        guard tiles > 0 || NowPlayingManager.shared.playingItem != nil else {
            debugLog("[CARPLAY] tune: no phone session to end (\(reason))")
            return
        }
        debugLog("[CARPLAY] tune: ending the phone session (\(tiles) tile(s)) for \(reason); the car owns playback")
        // exit() also stops any headless engine; the caller starts the car's.
        PlayerSession.shared.exit()
    }

    /// Kept Live (Logan 2026-10-08): nothing is kept alive while CarPlay is
    /// active. Releases every kept channel and blocks new ones until the car
    /// disconnects.
    static func suspendKeepAlive(reason: String) {
        if !LiveChannelRetention.suspendedForCarPlay {
            LiveChannelRetention.suspendedForCarPlay = true
            debugLog("[CARPLAY] keep-alive suspended (\(reason))")
        }
        if !LiveChannelRetention.shared.entries.isEmpty {
            debugLog("[CARPLAY] keep-alive: releasing \(LiveChannelRetention.shared.entries.count) kept channel(s)")
            LiveChannelRetention.shared.stopAll(reason: "CarPlay active")
        }
    }

    static func resumeKeepAlive() {
        guard LiveChannelRetention.suspendedForCarPlay else { return }
        LiveChannelRetention.suspendedForCarPlay = false
        debugLog("[CARPLAY] keep-alive resumed (car disconnected)")
    }

    /// Show Now Playing without pushing it twice: pushing a template that is
    /// already in the stack throws inside CarPlay.
    private func showNowPlaying() {
        guard let ic = interfaceController else { return }
        let np = CPNowPlayingTemplate.shared
        if ic.topTemplate === np { return }
        if ic.templates.contains(where: { $0 === np }) {
            ic.pop(to: np, animated: true, completion: nil)
        } else {
            ic.pushTemplate(np, animated: true, completion: nil)
        }
    }
}

// MARK: - Session configuration delegate

/// Required by `CPSessionConfiguration`'s designated initializer; both
/// callbacks are optional and currently informational only, but the limited-UI
/// one is logged because it is the signal that the car started driving
/// (keyboards/lists restricted), which is also when video presentation stops.
extension CarPlaySceneDelegate: CPSessionConfigurationDelegate {
    nonisolated func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        debugLog("[CARPLAY] limited UI changed: rawValue=\(limitedUserInterfaces.rawValue)")
    }
}

// MARK: - UIImage Scaling Helper

private extension UIImage {
    func scaledToFit(_ targetSize: CGSize) -> UIImage {
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        let ratio = min(widthRatio, heightRatio)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - CarPlay video window scene

/// Delegate for the `UIWindowSceneSessionRoleCarPlay` window scene.
///
/// REQUIRED FOR LAUNCH with the carplay-video entitlement (field find
/// 2026-08-31): a video-entitled app must declare this window-scene role
/// in its scene manifest or iOS aborts the ENTIRE CarPlay launch - the
/// template scene never connects and the car shows a frozen blank pane.
/// Undocumented in the June 2026 CarPlay guide; discovered by reading
/// rPlayTV's on-device manifest (it declares the same role), and Apple's
/// own CarPlay system apps (Settings, Wallpaper) use it too.
///
/// The scene is the surface iOS gives video apps on the car display.
/// v1 keeps it EMPTY (a black window): browsing and playback run through
/// the template scene + CPPlaybackConfiguration, and video presentation
/// stays on the sanctioned system path - nothing is self-rendered here.
@MainActor
final class CarPlayVideoWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        debugLog("[CarPlay] video window scene connected: \(windowScene.coordinateSpace.bounds.size)")
        let w = UIWindow(windowScene: windowScene)
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        w.rootViewController = vc
        window = w
        // Diagnostic: does a CPTemplateApplicationScene exist alongside
        // this window scene, and did anything claim its delegate? Tells
        // us whether iOS 27 still offers templates to video apps or
        // routes the whole car UI through this window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for sc in UIApplication.shared.connectedScenes {
                let delegate = (sc as? UIWindowScene)?.delegate ?? sc.delegate
                debugLog("[CarPlay] scene census: \(type(of: sc)) role=\(sc.session.role.rawValue) state=\(sc.activationState.rawValue) delegate=\(delegate.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        debugLog("[CarPlay] video window scene disconnected")
        window = nil
    }
}
#endif
