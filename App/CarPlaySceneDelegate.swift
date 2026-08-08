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

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        // Release-build visible (Logan's real-car session 2026-08-07 was a
        // black box: every CarPlay log line was DEBUG-only print, so "channels
        // never loaded in the car" could not be told apart from "process was
        // never launched").
        debugLog("[CarPlay] didConnect: channels=\(ChannelStore.shared.channels.count) hasFavorites=\(FavoritesStore.shared.hasFavorites) fgScene=\(HeadlessPlaybackController.hasForegroundPlayerScene())")

        sessionConfiguration = CPSessionConfiguration(delegate: self)
        debugLog("[CarPlay] session video support: \(carSupportsVideo)")

        // A car can be the only scene (phone app never opened), so mark the
        // session, default it to audio-only, hydrate channels if the store
        // is empty, and observe the store so the lists fill in once the
        // load lands.
        NowPlayingManager.shared.isCarPlayConnected = true
        hydrateChannelsIfNeeded()
        observeChannelStore()

        let root = buildRootTemplate()
        interfaceController.setRootTemplate(root, animated: false) { ok, err in
            #if DEBUG
            print("[CarPlay] setRootTemplate done ok=\(ok) err=\(String(describing: err))")
            #endif
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        #if DEBUG
        print("[CarPlay] didDisconnect: scene torn down")
        #endif
        self.interfaceController = nil
        favoritesTemplate = nil
        groupsTemplate = nil
        sessionConfiguration = nil
        cancellables.removeAll()
        NowPlayingManager.shared.isCarPlayConnected = false
        // Tear down any headless engine started for this car session (no-op if
        // a foreground view coordinator was the live engine instead).
        HeadlessPlaybackController.shared.stop()
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
            debugLog("[CarPlay] hydrate: skip, load already in flight")
            return
        }
        guard let container = AerioApp.sharedContainer else {
            debugLog("[CarPlay] hydrate: FAIL, sharedContainer is nil (CarPlay scene connected before app init?)")
            return
        }
        let context = ModelContext(container)
        let servers = (try? context.fetch(FetchDescriptor<ServerConnection>())) ?? []
        guard !servers.isEmpty else {
            debugLog("[CarPlay] hydrate: FAIL, 0 servers fetched from SwiftData")
            return
        }

        let hadChannels = !ChannelStore.shared.channels.isEmpty
        let lanBefore = TVLANProbe.persistedLANDetected
        debugLog("[CarPlay] hydrate: servers=\(servers.count) hadChannels=\(hadChannels) lanBefore=\(lanBefore)")
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
            debugLog("[CarPlay] hydrate: LAN probe -> \(lanNow) (was \(lanBefore))")
            if !hadChannels || lanNow != lanBefore {
                ChannelStore.shared.refresh(servers: servers)
            }
        }
    }

    /// Refresh the CarPlay lists in place whenever the channel list changes
    /// (the standalone load above completing, or a server switch on the
    /// phone while connected).
    private func observeChannelStore() {
        ChannelStore.shared.$channels
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLists() }
            }
            .store(in: &cancellables)

        // Rebuild rows when the playing channel changes so the isPlaying
        // indicator and per-item playback configuration (play vs none on a
        // video-capable car) track reality, not just list-build time.
        NowPlayingManager.shared.$playingItem
            .receive(on: RunLoop.main)
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLists() }
            }
            .store(in: &cancellables)
    }

    private func refreshLists() {
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
        let items = FavoritesStore.shared.favoriteItems.map { makeChannelItem($0) }
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
        let groupItems: [CPListItem] = ChannelStore.shared.orderedGroups.map { groupName in
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
        let items = channels.map { makeChannelItem($0) }
        let template = CPListTemplate(title: group, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
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

        let isThisPlaying = NowPlayingManager.shared.playingItem?.id == channel.id
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
        // can predate the EPG populating `currentProgram`, which is why the
        // Now Playing screen showed the channel name with no program. The
        // live store row has the up-to-date program; fall back to the tapped
        // snapshot if the row is gone (e.g. mid-refresh).
        let channel = ChannelStore.shared.channels.first { $0.id == tappedChannel.id } ?? tappedChannel
        guard !channel.streamURLs.isEmpty else { return }
        #if DEBUG
        print("[CarPlay] playChannel: \(channel.name) tappedProgram=\(tappedChannel.currentProgram ?? "nil") freshProgram=\(channel.currentProgram ?? "nil")")
        #endif

        if PlaybackFeatureFlags.useUnifiedPlayback {
            // Phase B routing: funnel through PlayerSession so the iPad UI
            // (if the user unlocks mid-CarPlay session) sees this channel as
            // tile 0 and multiview + lockscreen stay in sync.
            _ = PlayerSession.shared.begin(
                item: channel,
                server: ChannelStore.shared.activeServer
            )
        } else {
            let headers = ChannelStore.shared.activeServer?.authHeaders ?? ["Accept": "*/*"]
            NowPlayingManager.shared.startPlaying(channel, headers: headers)
        }

        // The calls above only mutate shared state; the real player + audio
        // session live in the SwiftUI `MPVPlayerView`, which mounts only when a
        // foreground window scene renders. In a cold car / locked phone that
        // scene doesn't exist, so nothing would actually play. Drive a headless
        // audio engine directly for that case; it no-ops (and lets the view
        // engine take over) whenever the phone app is foreground.
        HeadlessPlaybackController.shared.start(
            item: channel,
            server: ChannelStore.shared.activeServer,
            isLive: true,
            videoCapable: carSupportsVideo
        )

        // Surface Now Playing (pushing it is allowed even though it cannot
        // be a tab).
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
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
        debugLog("[CarPlay] limited UI changed: rawValue=\(limitedUserInterfaces.rawValue)")
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

#endif
