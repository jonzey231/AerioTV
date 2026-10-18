import Foundation
import SwiftUI
import Combine
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Search dismissal

extension Notification.Name {
    /// Broadcast whenever every open search field in the app must close.
    static let aerioDismissSearch = Notification.Name("AerioDismissSearch")
}

/// One switchboard for "close any open search, everywhere" (Logan
/// 2026-09-16).
///
/// The bug: a search field left open on a tab kept its first responder
/// alive. Fullscreening media and then swiping down for Picture in
/// Picture handed first-responder status back to that field, so the
/// keyboard reappeared over the PiP transition.
///
/// The fix: every tab with a search field listens for
/// `.aerioDismissSearch` and closes itself (clears text, drops focus,
/// leaves the search UI shut). `dismissAll` also resigns first responder
/// app-wide, which is what actually stops the keyboard from being
/// re-summoned as views are torn down and rebuilt around PiP.
enum SearchDismissCenter {
    @MainActor
    static func dismissAll(reason: String) {
        debugLog("[SEARCH] dismiss all (\(reason))")
        NotificationCenter.default.post(name: .aerioDismissSearch, object: nil)
        resignKeyboard()
    }

    /// Drop the keyboard without touching any search state. Called again
    /// on the PiP hop so a field that re-mounts cannot take focus back.
    @MainActor
    static func resignKeyboard() {
        #if canImport(UIKit) && !os(tvOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

extension View {
    /// Run `action` when any part of the app asks open searches to close.
    func onDismissSearch(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .aerioDismissSearch)) { _ in
            action()
        }
    }
}

/// Top-level playback-mode arbiter.
///
/// `NowPlayingManager.shared` is single-stream by design, it tracks
/// one `playingItem`, one `playingHeaders`, one `isMinimized`.
/// `MultiviewStore.shared` holds the tile collection.
/// `PlayerSession.mode` decides which of the two is currently
/// authoritative for what the UI draws and what gets routed to
/// `NowPlayingBridge` (lock-screen + remote commands).
///
/// Why not just add `isMultiview: Bool` to `NowPlayingManager`?
/// The review phase flagged that path as brittle because every
/// `NowPlayingManager` call site (CarPlay, PlayerView controls,
/// HomeView inline mount) would have to learn both shapes. Keeping
/// `NowPlayingManager` unchanged and introducing this enum at one
/// level up means those call sites keep their single-stream
/// contract; multiview lives alongside.
@MainActor
final class PlayerSession: ObservableObject {

    // MARK: - Singleton

    static let shared = PlayerSession()
    private init() {}

    // MARK: - Mode

    enum Mode: Equatable {
        /// No playback. UI shows the Live TV guide / VOD grid.
        case idle
        /// One stream playing; `NowPlayingManager.shared` is
        /// authoritative.
        case single
        /// 1–9 tile grid; `MultiviewStore.shared` is authoritative.
        case multiview
    }

    @Published private(set) var mode: Mode = .idle

    // MARK: - Transitions

    /// Transition from `.single` (or `.idle`) into `.multiview`,
    /// seeding tile 0 with the currently-playing channel if there
    /// is one. When `current != nil`, `MultiviewStore.seedInitialTile`
    /// pins the new tile's id to `current.id` so SwiftUI carries
    /// over the existing `MPVPlayerView` instance (no black flash).
    ///
    /// After this call:
    /// - `MultiviewStore.shared.tiles` has the seed tile (or is empty
    ///   if there was no currently-playing channel).
    /// - `MultiviewStore.shared.audioTileID` is that seed tile.
    /// - `mode == .multiview`.
    /// - `NowPlayingManager.shared` stays populated for the seed
    ///   channel so CarPlay / lockscreen keep working, the bridge
    ///   gating in Phase 1d routes remote commands to whichever tile
    ///   holds audio.
    func enterMultiview(seeding current: ChannelDisplayItem?, server: ServerConnection?, isLive: Bool = true) {
        // Refcount float. SwiftUI's swap from the old single
        // `PlayerView` to `MultiviewContainerView` happens across one
        // (or more) render passes; the ordering of unmount-old vs
        // mount-new is implementation-defined. If unmount runs first
        // the audio-session refcount hits 0, triggering
        // `setActive(false) → setActive(true)` on the next mount,
        // audible as a brief routing bounce. Pre-incrementing here
        // keeps the count ≥ 1 through the transition; we release the
        // float ~250 ms later, after both swaps have settled. The
        // refcount's queue-serialisation guarantees this is safe to
        // issue from main actor.
        debugLog("[MV-Audio] enterMultiview pre-increment refcount (transition float)")
        AudioSessionRefCount.increment()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            AudioSessionRefCount.decrement()
            debugLog("[MV-Audio] enterMultiview float released")
        }

        if current == nil { releaseKeptLiveForMultiTileLaunch() }
        if let current {
            // Lock the session engine ONCE, from the seed channel, before
            // any tile renders. Every tile inherits MultiviewStore.
            // sessionEngine for the session's life (no per-tile decision).
            let resolved = PlayerSession.resolveEngine(item: current, server: server, isLive: isLive)
            MultiviewStore.shared.lockEngine(resolved)
            TuneTimeline.shared.mark("lock")
            DebugLogger.shared.log(
                "[Engine] session locked to \(resolved.engine) (seed=\(current.name))",
                category: "Playback", level: .info
            )
            MultiviewStore.shared.seedInitialTile(current, server: server)
        }
        mode = .multiview
        // Tell NowPlayingManager it's no longer the bridge authority.
        // MultiviewStore is, via whichever tile currently holds audio,
        // and MPVPlayerView.Coordinator.shouldDriveNowPlayingBridge()
        // enforces that at the per-coordinator level.
        NowPlayingManager.shared.configuredAsMultiviewAdapter = true
        DebugLogger.shared.log(
            "[MV-Mode] enter multiview; seeded=\(current != nil)",
            category: "Playback", level: .info
        )
    }

    /// GH #76: enter Multiview from a recording playing in the legacy
    /// fullscreen cover. The recording becomes tile 0 through the same
    /// `MultiviewStore.addVOD` tile creation the Add Stream picker's
    /// Recordings source uses (1d4c712), resuming at the cover's current
    /// position, then the container is asked to open its add sheet so the
    /// user picks the second stream. The caller dismisses the cover.
    @discardableResult
    func enterMultiview(seedingRecording title: String,
                        streamURL: URL,
                        headers: [String: String],
                        isDVR: Bool,
                        vodID: String?,
                        serverID: String?,
                        positionMs: Int32?) -> Bool {
        let store = MultiviewStore.shared
        if !store.tiles.isEmpty { exit() }
        // Same transition float as the channel seed above.
        AudioSessionRefCount.increment()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            AudioSessionRefCount.decrement()
        }
        var tileHeaders = headers
        tileHeaders.removeValue(forKey: "X-Aerio-Start-From-Beginning")
        store.lockEngine(ResolvedEngine(
            engine: PlaybackFeatureFlags.mpvEngineEnabled ? .mpv : .avPlayerRemuxTS,
            routeURL: streamURL, headers: tileHeaders))
        let resume: Int32? = (positionMs ?? 0) > 2_000 ? positionMs : (isDVR ? 0 : nil)
        let result = store.addVOD(title: title.isEmpty ? "Recording" : title,
                                  streamURL: streamURL,
                                  headers: tileHeaders,
                                  posterURL: nil,
                                  kind: isDVR ? .dvr : .vod,
                                  vodID: vodID,
                                  serverID: serverID,
                                  vodType: "recording",
                                  resumePositionMs: resume,
                                  bypassWarning: true)
        guard result == .added else {
            DebugLogger.shared.log("[MV-Mode] enter multiview from recording failed: \(result)",
                                   category: "Playback", level: .warning)
            return false
        }
        mode = .multiview
        NowPlayingManager.shared.configuredAsMultiviewAdapter = true
        DebugLogger.shared.log(
            "[MV-Mode] enter multiview; seeded recording kind=\(isDVR ? "dvr" : "vod") resume=\(resume.map(String.init) ?? "none")ms",
            category: "Playback", level: .info)
        // Give the container a beat to mount, then open its add sheet
        // (same notification the native player's Add Stream uses).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NotificationCenter.default.post(name: .multiviewRequestOpenAddSheet, object: nil)
        }
        return true
    }

    /// Exit multiview and continue playing the audio tile's channel
    /// as a regular single-stream. This is what the "Exit" button
    /// in the transport bar calls, after a multiview session the
    /// user's expectation is "take me back to the channel I was
    /// listening to", not "drop me back to the guide".
    ///
    /// Implementation:
    /// 1. Capture the audio tile's channel + headers before reset.
    /// 2. Reset the multiview store (tears down all tile coords).
    /// 3. Flip session mode → `.single`.
    /// 4. Re-seed `NowPlayingManager` with the captured channel so
    ///    HomeView's mode branch falls through to `PlayerView`
    ///    with the correct channel.
    ///
    /// If there's no audio tile (empty grid edge case), falls back
    /// to a full `exit()` which clears NowPlayingManager and lands
    /// the user on the Live TV guide.
    /// iPhone and iPad transport-bar X: closes the SELECTED stream (the
    /// audio tile), which is what a tap on a tile followed by X means to
    /// people (Freyguy1975, Discord 2026-09-09: with two streams the X
    /// closed the other one and kept the one he had picked). The store
    /// promotes audio to the newest remaining tile; the last stream closes
    /// the player.
    func closeAudioTile() {
        let store = MultiviewStore.shared
        guard let audioID = store.audioTileID, store.tiles.contains(where: { $0.id == audioID }) else {
            exit()
            return
        }
        if store.tiles.count <= 1 {
            stop()
            return
        }
        DebugLogger.shared.log(
            "[MV-Mode] close selected tile=\(audioID) remaining=\(store.tiles.count - 1)",
            category: "Playback", level: .info
        )
        store.remove(id: audioID)
    }

    func exitMultiviewKeepingAudioTile() {
        let store = MultiviewStore.shared
        // Capture the audio tile BEFORE we reset the store.
        let audioTile = store.tiles.first { $0.id == store.audioTileID }

        guard let audioTile else {
            // No audio tile means no channel to fall back to, do a
            // full teardown instead of leaving stale state behind.
            exit()
            return
        }

        // Unified-playback path: keep the audio tile as the sole
        // remaining tile and stay in `PlaybackContainerView`. Mode
        // stays `.multiview` even at N=1 because that's the whole
        // point of the unified view, single-stream IS just
        // N=1 multiview. This preserves the `+` / Add Stream pill in
        // the N=1 chrome so the user can re-enter N>=2 without a
        // full teardown + channel re-resolve. Previously this path
        // always flipped to `.single` + swapped to `PlayerView`,
        // which left the user with no way to add another stream
        // except by exiting all the way to the guide and starting
        // over, exactly the "no way to reuse multiview" pain point.
        if PlaybackFeatureFlags.useUnifiedPlayback {
            // Remove every tile except the audio tile, one mpv
            // handle (the audio tile's) survives; everything else
            // dismantles via SwiftUI view disappear. The store's
            // `audioTileID` stays pointed at the same tile.
            let surviving = audioTile.id
            let toRemove = store.tiles.filter { $0.id != surviving }.map { $0.id }
            for id in toRemove {
                store.remove(id: id)
            }
            DebugLogger.shared.log(
                "[MV-Mode] collapse→N=1 (unified, keep audio tile=\(audioTile.item.name))",
                category: "Playback", level: .info
            )
            return
        }

        // Legacy path: reset the store, flip mode to .single,
        // re-seed NowPlayingManager so HomeView's mode branch falls
        // through to the classic PlayerView with the captured
        // channel.
        store.reset()
        mode = .single
        NowPlayingManager.shared.configuredAsMultiviewAdapter = false
        NowPlayingManager.shared.startPlaying(
            audioTile.item,
            headers: audioTile.headers,
            isLive: true
        )
        DebugLogger.shared.log(
            "[MV-Mode] exit→single (legacy, keep audio tile=\(audioTile.item.name))",
            category: "Playback", level: .info
        )
    }

    /// Exit multiview AND stop playback entirely. Tears down the
    /// tile list (which dismantles each tile's MPVPlayerView and
    /// thus each mpv handle) and returns to `.idle`. Called by the
    /// transport bar's "Exit Multiview" button when the user wants
    /// to stop watching, not just collapse to one stream.
    /// Catch-up unification (task #147): mode-switch whatever is
    /// playing into a solo catch-up replay in the SAME container the
    /// live player uses. Replaces the legacy tvOS fullScreenCover
    /// presentation. Structured like exit()+enterMultiview: capture
    /// the guide breadcrumb, tear down the current session's bridges,
    /// then seed the catch-up tile - with the audio-session refcount
    /// float so the 0->1 bounce never drops the (48kHz-pinned) session
    /// between the outgoing and incoming players.
    func beginCatchup(_ pb: CatchupPlayback) {
        #if os(iOS)
        // Replaces the session without exit(): hand foreground PiP over to
        // the replay (no-op when PiP isn't up).
        ForegroundPiPBridge.shared.sessionEnding()
        #endif
        AudioSessionRefCount.increment()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            AudioSessionRefCount.decrement()
        }
        let store = MultiviewStore.shared
        if let audioID = store.audioTileID,
           let audioTile = store.tiles.first(where: { $0.id == audioID }) {
            NowPlayingManager.shared.lastPlayedChannelID = audioTile.item.id
        }
        NowPlayingManager.shared.configuredAsMultiviewAdapter = false
        NowPlayingBridge.shared.teardown()
        NowPlayingManager.shared.stop()
        store.seedCatchup(pb)
        mode = .multiview
        DebugLogger.shared.log(
            "[MV-Mode] beginCatchup: \(pb.title)",
            category: "Playback", level: .info
        )
    }

    func exit() {
        #if os(iOS)
        // GH #99: any path that ENDS playback (Back, playback end, stop
        // from a sheet) must give the home screen its at-rest orientation
        // back. exit() also runs inside channel changes, where a forced
        // landscape must survive, so release only if nothing started again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard PlayerSession.shared.mode == .idle,
                  !NowPlayingManager.shared.isActive else { return }
            AppOrientationLock.release(reason: "session ended")
        }
        // Foreground PiP belongs to this session: take the window down and
        // un-hide the host for whatever plays next (no-op on the PiP X path,
        // which is what called us).
        ForegroundPiPBridge.shared.sessionEnding()
        #endif
        // v1.6.18: capture the audio tile's channel id BEFORE we
        // reset the store. NowPlayingManager.lastPlayedChannelID is
        // the persistent breadcrumb the Live TV guide reads for its
        // default-focused row, without this capture, a full exit
        // from multiview clears playingItem AND wipes the audio
        // tile id from MultiviewStore in the same beat, leaving the
        // guide with no signal at all and falling back to row 0.
        // Capturing here keeps "exit multiview → guide lands on the
        // channel I was just listening to" as the consistent
        // behaviour. `startPlaying(...)` writes the same field on
        // single-stream entry, so this only matters on the
        // multiview-exit path.
        let store = MultiviewStore.shared
        // Catch-up: the tile's item id is synthetic ("catchup-<uuid>"), so
        // the breadcrumb is the guide row the program aired on, and the
        // guide is asked to refocus that exact program cell below.
        let catchup = store.catchupTile?.catchup
        if let cu = catchup, let cid = cu.channelID {
            NowPlayingManager.shared.lastPlayedChannelID = cid
        } else if let audioID = store.audioTileID,
           let audioTile = store.tiles.first(where: { $0.id == audioID }) {
            NowPlayingManager.shared.lastPlayedChannelID = audioTile.item.id
        }
        // Warm-start cancel path: the user left before any tile adopted
        // the pre-opened upstream. Holding it would occupy a provider
        // slot and is exactly what makes the next tune answer 503
        // (review 2026-09-11 section 2).
        LivePrewarm.shared.cancel(reason: "session exit")
        HLSCapabilityStore.shared.runDeferredProbeIfIdle()
        store.reset()
        mode = .idle
        NowPlayingManager.shared.configuredAsMultiviewAdapter = false
        // Explicit bridge teardown: during multiview, the audio tile's
        // coordinator was driving MPNowPlayingInfoCenter. After
        // `MultiviewStore.reset()` that coordinator will dismantle,
        // but its own `stop()`-driven teardown gate now returns `false`
        // (mode just flipped to .idle, tileID != nil), so it won't
        // clear the center. Do it here so the lockscreen doesn't show
        // a ghost entry after "Exit Multiview".
        #if os(iOS)
        // A headless CarPlay engine (cold-car playback with no view mounted)
        // isn't owned by any coordinator, so the store reset above won't stop
        // it, kill it here so "Exit" from any surface silences audio.
        HeadlessPlaybackController.shared.stop()
        #endif
        NowPlayingBridge.shared.teardown()
        // Clear single-stream state too. HomeView's mode branch is
        // `if .multiview { … } else if nowPlaying.isActive { single
        // PlayerView }`, without this clear, the else-if revives
        // single-stream playback of the seed channel after the user
        // tapped "Exit Multiview", which is the opposite of what the
        // button says. Stopping NowPlayingManager lets HomeView fall
        // through to the Live-TV guide / empty state.
        NowPlayingManager.shared.stop()
        #if os(tvOS)
        // NowPlayingManager was already idle during catch-up (beginCatchup
        // stops it), so HomeView's isActive "player closed" refocus does
        // not fire on this exit. Hold the nav circles and ask the guide to
        // refocus the played program's cell in the same turn.
        if let cu = catchup, let cid = cu.channelID, NowPlayingManager.sceneIsActive {
            NowPlayingManager.shared.catchupRefocusTarget = (cid, cu.programStart)
            NowPlayingManager.shared.lastStopWasFullscreen = true
            NowPlayingManager.shared.beginGuideRefocusHold()
            debugLog("[FOCUS] catch-up closed: refocus channel=\(cid) start=\(cu.programStart.timeIntervalSinceReferenceDate)")
            NotificationCenter.default.post(name: .forceGuideFocus, object: nil)
        }
        #endif
        DebugLogger.shared.log(
            "[MV-Mode] exit→idle (full teardown)",
            category: "Playback", level: .info
        )
    }

    /// Live TV "Add to Multiview" (Guide cells and List rows) routing,
    /// shared so both views decide the same way. Returns the channel id of
    /// a single session that was just turned into the first staged
    /// channel, or nil.
    ///
    /// - A real Multiview (2+ tiles, or a phone composite feeding a
    ///   receiver) takes the channel as one more tile (e1dcbd2).
    /// - A unified single session (one tile, the full player or the mini
    ///   player) is NOT a Multiview: appending to it grew the minimized
    ///   container into a full-screen grid while `isMinimized` stayed true,
    ///   so Back was ignored and the app looked stuck (Apple TV log
    ///   2026-10-11 17:05:31 "add ok ... total=2" with no staging line, then
    ///   17:06:28 "isMinimized=true tiles=2 -> minimized -> ignored"). Its
    ///   channel becomes staged channel 1 instead (counted once), staging
    ///   starts and the banner shows; Play opens Multiview.
    /// - Otherwise the first add starts a fresh staged set.
    @discardableResult
    func prepareLiveTVMultiviewAdd() -> String? {
        let store = MultiviewStore.shared
        if let seed = miniPlayerSeedTile {
            if !store.isStagingFromGuide {
                store.isStagingFromGuide = true
                DebugLogger.shared.log(
                    "[MV-Tile] staging mode: entered with mini player playing \(seed.item.name) as staged channel 1",
                    category: "Playback", level: .info)
            }
            return seed.item.id
        }
        if mode == .multiview { return nil }
        if !store.isStagingFromGuide {
            store.clearAll()
            store.stagedExtras = []
            store.isStagingFromGuide = true
            DebugLogger.shared.log("[MV-Tile] staging mode: entered from Live TV",
                                   category: "Playback", level: .info)
        }
        // A Kept Live channel (iPhone has no mini player: the swiped-away
        // player keeps its channel alive headless) counts as the playing
        // channel, same rule as the mini player: it is staged channel 1.
        if let kept = keptLiveSeedChannel, store.tile(forChannelID: kept.id) == nil, store.tiles.isEmpty {
            store.seedInitialTile(kept, server: ChannelStore.shared.activeServer)
            DebugLogger.shared.log(
                "[MV-Tile] staging mode: Kept Live \(kept.name) staged as channel 1",
                category: "Playback", level: .info)
        }
        return nil
    }

    /// The channel kept live in the background (Kept Live card) when no
    /// player is up. Counts as the playing channel for Live TV "Add to
    /// Multiview" (grayed for itself, staged channel 1 for the others).
    /// With several kept, the most recently kept one.
    var keptLiveSeedChannel: ChannelDisplayItem? {
        #if os(iOS)
        guard mode == .idle else { return nil }
        guard let kept = KeptLiveChannels.shared.channels.max(by: { $0.since < $1.since }) else { return nil }
        return ChannelStore.shared.channels.first(where: { $0.id == kept.id })
        #else
        return nil
        #endif
    }

    /// Multiview tiles that are also kept live: a fresh multi-tile mount
    /// does not adopt the kept ingest (only a lone tile does), so the
    /// keep-alive ends here instead of running a second upstream
    /// connection to the same channel next to the tile's own.
    private func releaseKeptLiveForMultiTileLaunch() {
        let store = MultiviewStore.shared
        guard store.tiles.count > 1 else { return }
        for tile in store.tiles where KeptLiveChannels.shared.ids.contains(tile.item.id) {
            DebugLogger.shared.log(
                "[MV-Tile] Kept Live \(tile.item.name) joins Multiview as a tile; keep-alive ended",
                category: "Playback", level: .info)
            LiveChannelRetention.shared.releaseByUser(channelID: tile.item.id)
        }
    }

    /// The one tile of a live single-channel session (the mini player is a
    /// one-tile Multiview internally). Not a Multiview from the user's
    /// point of view: Live TV stages around it instead of growing it.
    var miniPlayerSeedTile: MultiviewTile? {
        let store = MultiviewStore.shared
        guard mode == .multiview, store.tiles.count == 1 else { return nil }
        #if os(iOS)
        if MultiviewCompositeSession.shared.isActive { return nil }
        #endif
        // A background Multiview stays a Multiview at one tile: its last
        // channel reads Remove from Multiview, not the mini player seed.
        if MultiviewBackgroundSession.shared.isActive { return nil }
        return store.tiles.first
    }

    enum LiveTVMultiviewMenuState { case add, addDisabled, remove }

    /// Label/state for a Live TV long-press "Add to Multiview" item. The
    /// channel playing in the mini player reads "Add to Multiview",
    /// disabled (it is already staged channel 1).
    func liveTVMultiviewMenuState(channelID: String) -> LiveTVMultiviewMenuState {
        let store = MultiviewStore.shared
        if let seed = miniPlayerSeedTile {
            if seed.item.id == channelID { return .addDisabled }
            return store.stagedExtras.contains(where: { $0.id == channelID }) ? .remove : .add
        }
        if keptLiveSeedChannel?.id == channelID { return .addDisabled }
        if store.stagedExtras.contains(where: { $0.id == channelID }) { return .remove }
        return store.tile(forChannelID: channelID) != nil ? .remove : .add
    }

    /// Count shown in the "N channels staged for Multiview" banner.
    var liveTVStagedCount: Int {
        let store = MultiviewStore.shared
        return (miniPlayerSeedTile != nil ? 1 : store.tiles.count) + store.stagedExtras.count
    }

    enum LiveTVMultiviewOutcome { case added, removed, alreadyPlaying, maxReached, unresolvable, alreadyAdded }

    /// Live TV "Add to Multiview" (Guide and List). With the mini player
    /// playing, the channel joins `stagedExtras` and the mini player keeps
    /// playing; otherwise the classic pile in `tiles` (no session) or one
    /// more tile in the running Multiview (2+ tiles or composite).
    func handleLiveTVMultiviewIntent(_ channel: ChannelDisplayItem, server: ServerConnection?) -> LiveTVMultiviewOutcome {
        let store = MultiviewStore.shared
        if miniPlayerSeedTile == nil, keptLiveSeedChannel?.id == channel.id { return .alreadyPlaying }
        if prepareLiveTVMultiviewAdd() == channel.id { return .alreadyPlaying }
        if miniPlayerSeedTile != nil || !store.stagedExtras.isEmpty && mode != .multiview {
            if let i = store.stagedExtras.firstIndex(where: { $0.id == channel.id }) {
                store.stagedExtras.remove(at: i)
                DebugLogger.shared.log("[MV-Tile] staged extra removed: \(channel.name) staged=\(liveTVStagedCount)",
                                       category: "Playback", level: .info)
                return .removed
            }
        }
        if miniPlayerSeedTile != nil {
            if liveTVStagedCount >= store.maxTiles {
                store.isStagingFromGuide = false
                return .maxReached
            }
            guard MultiviewStore.resolveStream(channel, server: server) != nil else { return .unresolvable }
            store.stagedExtras.append(channel)
            DebugLogger.shared.log("[MV-Tile] staged extra added (mini player keeps playing): \(channel.name) staged=\(liveTVStagedCount)",
                                   category: "Playback", level: .info)
            return .added
        }
        if let tile = store.tile(forChannelID: channel.id) {
            // Removing the last tile of a running Multiview ends it (the
            // same full stop as Exit Multiview / the dock card's Stop).
            if mode == .multiview, store.tiles.count <= 1 {
                DebugLogger.shared.log(
                    "[MV-Tile] Remove from Multiview: \(channel.name) was the last tile, ending Multiview",
                    category: "Playback", level: .info)
                stop()
                return .removed
            }
            DebugLogger.shared.log(
                "[MV-Tile] Remove from Multiview: \(channel.name) remaining=\(store.tiles.count - 1) background=\(MultiviewBackgroundSession.shared.isActive)",
                category: "Playback", level: .info)
            store.remove(id: tile.id)
            return .removed
        }
        switch store.add(channel, server: server) {
        case .added: return .added
        case .needsWarning:
            // Staging is an explicit many-tiles intent: no warning dialog.
            _ = store.add(channel, server: server, bypassWarning: true)
            return .added
        case .rejectedMax:
            store.isStagingFromGuide = false
            return .maxReached
        case .alreadyPresent: return .alreadyAdded
        case .unresolvable: return .unresolvable
        }
    }

    /// Banner Play. With the mini player playing, the staged extras join
    /// its session (the playing channel stays tile 1, no re-tune, no
    /// duplicate) and the player expands; otherwise the classic launch.
    func playLiveTVStaged(server: ServerConnection?) {
        let store = MultiviewStore.shared
        // One channel staged (Logan 2026-10-11, Android parity): standard
        // single-channel playback, not a one-tile Multiview.
        if liveTVStagedCount == 1, mode != .multiview || miniPlayerSeedTile != nil {
            playStagedSingleChannel(server: server)
            return
        }
        let extras = store.stagedExtras
        store.stagedExtras = []
        store.isStagingFromGuide = false
        let running = mode == .multiview && !store.tiles.isEmpty
        for ch in extras where store.tile(forChannelID: ch.id) == nil {
            if case .needsWarning = store.add(ch, server: server) {
                _ = store.add(ch, server: server, bypassWarning: true)
            }
        }
        DebugLogger.shared.log(
            "[MV-Tile] staging mode: user tapped Play (count=\(store.tiles.count) extras=\(extras.count) running=\(running))",
            category: "Playback", level: .info)
        if running {
            NowPlayingManager.shared.expand()
        } else {
            enterMultiview(seeding: nil, server: server)
        }
    }

    /// The staged channel when exactly one is staged (mini player seed,
    /// Kept Live seed, a lone staged tile or a lone extra), else nil.
    var soleStagedChannel: ChannelDisplayItem? {
        let store = MultiviewStore.shared
        guard liveTVStagedCount == 1 else { return nil }
        if let seed = miniPlayerSeedTile { return seed.item }
        return store.tiles.first?.item ?? store.stagedExtras.first
    }

    /// Play a one-channel staged set the way tapping the channel does
    /// (Logan 2026-10-11, Android parity): the staged set is cleared and
    /// the channel goes through the normal single-channel path (begin),
    /// so no Multiview chrome or Leave Multiview prompt. A channel already
    /// playing in the mini player just expands.
    func playStagedSingleChannel(server: ServerConnection?) {
        let store = MultiviewStore.shared
        guard let item = soleStagedChannel else { return }
        let alreadyPlaying = miniPlayerSeedTile?.item.id == item.id
        store.stagedExtras = []
        store.isStagingFromGuide = false
        DebugLogger.shared.log(
            "[MV-Tile] staging mode: Play with one channel staged -> single playback \(item.name) (playing=\(alreadyPlaying))",
            category: "Playback", level: .info)
        if alreadyPlaying {
            NowPlayingManager.shared.expand()
            return
        }
        if mode != .multiview { store.reset() }
        _ = begin(item: item, server: server ?? ChannelStore.shared.activeServer)
    }

    /// Logan 2026-10-12: a running Multiview reduced to ONE channel (picker
    /// deselects, then the picker closes; or a tile's Remove leaving one)
    /// continues in the standard single-channel player, the same rule as
    /// one staged channel and one background channel. The tile keeps
    /// playing (no re-tune); NowPlaying is re-seeded with it, which is what
    /// makes the session a standard single instead of a one-tile Multiview.
    func collapseToStandardSingleIfOneTile(reason: String) {
        let store = MultiviewStore.shared
        guard mode == .multiview, store.tiles.count == 1, let tile = store.tiles.first,
              tile.kind == .live, store.catchupTile == nil,
              !MultiviewBackgroundSession.shared.isActive else { return }
        #if os(iOS)
        if MultiviewCompositeSession.shared.isActive { return }
        if AerioCastController.shared.isCasting || CompanionClient.shared.isControlling { return }
        #endif
        // Already a standard single for this channel.
        if NowPlayingManager.shared.playingItem?.id == tile.item.id,
           !NowPlayingManager.shared.configuredAsMultiviewAdapter { return }
        store.audioTileID = tile.id
        store.fullscreenTileID = nil
        store.spotlightTileID = nil
        NowPlayingManager.shared.configuredAsMultiviewAdapter = false
        NowPlayingManager.shared.startPlaying(tile.item, headers: tile.headers, isLive: true, wakeChrome: false)
        DebugLogger.shared.log(
            "[MV-Mode] one channel left (\(reason)): \(tile.item.name) continues in the standard player",
            category: "Playback", level: .info)
    }

    /// Banner Clear. Drops the staged extras; a playing mini player is
    /// left exactly as it was.
    func clearLiveTVStaged() {
        let store = MultiviewStore.shared
        let count = liveTVStagedCount
        store.stagedExtras = []
        if miniPlayerSeedTile == nil, mode != .multiview { store.reset() }
        store.isStagingFromGuide = false
        DebugLogger.shared.log("[MV-Tile] staging mode: user tapped Clear (count=\(count))",
                               category: "Playback", level: .info)
    }

    /// "Back to TV Guide" from the multiview exit dialog (Android
    /// parity): the same full playback teardown as `exit()`, except the
    /// staged tile SET survives and staging mode is re-armed, so the
    /// guide greets the user with its "N channels staged" banner and Play
    /// resumes the same grid. The tile players themselves die with the
    /// container unmount; Play mounts fresh ones against the surviving
    /// tile list (the banner path never re-seeds).
    func exitMultiviewKeepingStagedTiles() {
        let store = MultiviewStore.shared
        if let audioID = store.audioTileID,
           let audioTile = store.tiles.first(where: { $0.id == audioID }) {
            NowPlayingManager.shared.lastPlayedChannelID = audioTile.item.id
        }
        mode = .idle
        NowPlayingManager.shared.configuredAsMultiviewAdapter = false
        NowPlayingBridge.shared.teardown()
        NowPlayingManager.shared.stop()
        store.isStagingFromGuide = true
        DebugLogger.shared.log(
            "[MV-Mode] exit→idle keeping staged tiles (Back to TV Guide, count=\(store.tiles.count))",
            category: "Playback", level: .info
        )
    }

    /// Enter `.single` mode. No-op if already there. Doesn't touch
    /// `NowPlayingManager`, the caller is expected to have set up
    /// the single-stream playing item before or after this call.
    func beginSingle() {
        mode = .single
    }

    /// Return to `.idle`. Called when the user dismisses the single
    /// player (PlayerView's exit button / swipe-down). Doesn't
    /// touch `NowPlayingManager`, `NowPlayingManager.stop()`
    /// clears its own state.
    func endSingle() {
        if mode == .single { mode = .idle }
    }

    // MARK: - Unified playback (Phase A skeleton)

    /// Unified playback entry point, eventually replaces every
    /// `NowPlayingManager.startPlaying(...)` + `enterMultiview(...)`
    /// caller with a single funnel that always treats playback as a
    /// `MultiviewStore`-driven tile list.
    ///
    /// Phase A behaviour (current): thin delegate. If the store is
    /// empty, calls `enterMultiview(seeding: item, server:)` so tile 0
    /// is seeded exactly as today and `NowPlayingManager` is mirrored
    /// via the existing `startPlaying` path. If the store already has
    /// tiles, calls `MultiviewStore.add(...)` like the add-sheet does.
    ///
    /// Phase C will swap the internals so `mode` goes straight to
    /// `.playing` (new case) without bouncing through `.single` /
    /// `.multiview`, and HomeView mounts `PlaybackContainerView` for
    /// both cases. Callers don't need to change between phases,
    /// that's the point of routing through `begin(...)` now.
    ///
    /// Returns `false` if stream resolution failed (no playable
    /// URL, no active server, cap reached). Callers can surface an
    /// error toast on `false`. Returns `true` even when an identical
    /// channel is already playing, `add(...)` no-ops with
    /// `.alreadyPresent` which we treat as success from a
    /// "user clicked channel, they see playback happening" POV.
    /// TEST (branch test/avplayer-hls-engine): non-nil presents the native
    /// AVPlayer screen via HomeView's fullScreenCover. Set by the engine
    /// router in begin() when a genuine HLS stream goes to AVPlayer.
    @Published var nativeHLSItem: ChannelDisplayItem?
    /// User-Agent captured alongside, for providers that filter requests.
    var nativeHLSUserAgent: String?
    /// True when the routed stream is raw MPEG-TS and must pass through
    /// the on-device TS-to-HLS remuxer before AVPlayer can play it.
    var nativeHLSUseRemux = false
    /// Ingest headers for the remuxer (Dispatcharr auth + UA).
    var nativeHLSHeaders: [String: String] = [:]
    /// Retained so the remux error path can fall back to mpv with the
    /// same server context.
    var nativeHLSServer: ServerConnection?
    /// Non-nil when the router upgraded the channel URL to request the
    /// server's native HLS output (?output_format=hls); the native
    /// screen plays this instead of the item's raw-TS URL.
    var nativeHLSOverrideURL: URL?

    /// TEST (branch test/avplayer-hls-engine): when the container holds
    /// exactly ONE tile and that tile chose the AVPlayer engine,
    /// fullscreen means the NATIVE player screen with system chrome
    /// (user direction: never show the custom chrome for AVPlayer
    /// playback at N=1). Called from NowPlayingManager.expand(); tears
    /// down the container and re-routes through begin(), so the stream
    /// restarts across the handoff. Returns false when the situation
    /// does not apply (mpv tile, N >= 2, no tile), in which case the
    /// caller expands the container as usual.
    @discardableResult
    func promoteSoleAVPlayerTileToNativeScreen() -> Bool {
        let store = MultiviewStore.shared
        guard mode == .multiview,
              store.tiles.count == 1,
              let tile = store.tiles.first,
              store.tileEngines[tile.id] == "AVPlayer" else { return false }
        let item = tile.item
        let server = nativeHLSServer
        DebugLogger.shared.log(
            "[AVP-HLS] mini expand -> native screen (sole AVPlayer tile)",
            category: "Playback", level: .info
        )
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.begin(item: item, server: server)
        }
        return true
    }

    /// The ONE place the engine is decided. Classifies the URL, consults
    /// the per-host HLS-capability cache, and reads the Developer toggles
    /// exactly once, returning a single locked verdict. Both off (the
    /// default) -> always `.mpv`, so toggle-off users never touch any
    /// AVPlayer path. Non-live -> always `.mpv` (VOD/DVR stay mpv).
    /// Synchronous on the main actor: it resolves HLS capability inline (a
    /// short, time-boxed probe on the first play of a not-yet-cached
    /// server, instant on a cache hit), so even the FIRST play of an
    /// HLS-capable server routes direct-HLS instead of remux-then-mpv.
    static func resolveEngine(item: ChannelDisplayItem,
                              server: ServerConnection?,
                              isLive: Bool) -> ResolvedEngine {
        guard let url = item.streamURL ?? item.streamURLs.first else {
            return ResolvedEngine(engine: .mpv, routeURL: URL(string: "about:blank")!, headers: [:])
        }
        var headers: [String: String] = [:]
        if let ua = server?.effectiveUserAgent, !ua.isEmpty {
            headers["User-Agent"] = ua
        }
        if let server, server.type == .dispatcharrAPI {
            let key = server.effectiveApiKey
            if !key.isEmpty {
                headers["X-API-Key"] = key
                headers["Authorization"] = "ApiKey \(key)"
            }
        }
        if !isLive {
            // VOD (never DVR/catchup: those come through their own URLs
            // and stay mpv). The AVPlayer VOD path plays MP4 natively and
            // MKV through the on-device cue-indexed remux
            // (MKVFMP4Remuxer); anything it cannot open falls back to mpv
            // per-tile. Gated by the same remux toggle as live.
            let ext = url.pathExtension.lowercased()
            let vodShape = url.path.contains("/proxy/vod/")
                || ["mkv", "mp4", "m4v", "mov"].contains(ext)
            if PlaybackFeatureFlags.avPlayerRemuxTS, vodShape {
                return ResolvedEngine(engine: .avPlayerRemuxTS, routeURL: url, headers: headers)
            }
            // mpv disabled (test flag): EVERYTHING non-live rides the
            // AVPlayer container chain (direct / MKV remux / visible
            // failure) - including DVR and catchup URLs that used to be
            // mpv's by fiat. Sink or swim is the point.
            if !PlaybackFeatureFlags.mpvEngineEnabled {
                return ResolvedEngine(engine: .avPlayerRemuxTS, routeURL: url, headers: headers)
            }
            return ResolvedEngine(engine: .mpv, routeURL: url, headers: headers)
        }
        let format = classifyStreamURL(url)
        var routeURL = url
        var effectiveFormat = format
        // The ?output_format=hls upgrade is a Dispatcharr contract. Xtream
        // panels ignore the parameter and routinely 302 live requests to an
        // edge, which the probe read as "HLS capable": AVPlayer was then
        // handed raw TS as direct HLS and failed with -11850 (os8.net, Apple TV,
        // 2026-09-03). Only Dispatcharr sources take the upgrade; everything
        // else keeps its TS on the remux path.
        let isDispatcharr = server?.type == .dispatcharrAPI
        if PlaybackFeatureFlags.forceHLS {
            if isDispatcharr, format == .mpegTS, url.path.lowercased().contains("/proxy/ts/") {
                // Developer Force HLS: skip the probe and the cached
                // verdict, request the server's HLS output and play it
                // direct on AVPlayer (no TS remuxer, no mpv).
                routeURL = appendingHLSOutputFormat(url)
                debugLog("[FORCE-HLS] channel=\(item.name) requested URL \(routeURL.absoluteString)")
                debugLog("[FORCE-HLS] channel=\(item.name) engine=AVPlayer direct HLS (probe skipped, host treated as HLS capable)")
                return ResolvedEngine(engine: .avPlayerDirectHLS, routeURL: routeURL, headers: headers)
            }
            debugLog("[FORCE-HLS] channel=\(item.name) not a Dispatcharr Direct Connect TS channel (server=\(server.map { "\($0.type)" } ?? "none")); toggle ignored")
        }
        if format == .mpegTS, PlaybackFeatureFlags.avPlayerForHLS, isDispatcharr {
            // Tune time (Apple TV review 2026-09-11 section 1 proposal 1;
            // session.txt:259-261, 724-728, 1568-1570): this used to call
            // HLSCapabilityStore.probeBlocking, which parks the MAIN ACTOR
            // on a semaphore for up to 1.5 s. It cost 1537 ms on the first
            // tune of EVERY launch and froze the UI for that long inside
            // enterMultiview. Now: decide from the CACHED verdict (which
            // persists both ways with a 7-day TTL) and fire the probe in
            // the background, so the answer is ready for the next tune. An
            // un-probed HLS-capable server takes the remux path once - the
            // pre-probe behavior, with a working direct-HLS fallback.
            if HLSCapabilityStore.shared.isCapable(url) {
                routeURL = appendingHLSOutputFormat(url)
                effectiveFormat = .hls
            }
            // Deferred, never at tune time: the probe is a second GET to
            // this channel and tripped stream_limit (2026-09-15).
            HLSCapabilityStore.shared.deferProbe(streamURL: url, headers: headers)
        }
        if PlaybackFeatureFlags.avPlayerForHLS, effectiveFormat == .hls {
            return ResolvedEngine(engine: .avPlayerDirectHLS, routeURL: routeURL, headers: headers)
        }
        if PlaybackFeatureFlags.avPlayerRemuxTS, format == .mpegTS {
            return ResolvedEngine(engine: .avPlayerRemuxTS, routeURL: url, headers: headers)
        }
        // mpv disabled (test flag): unknown live formats go through the
        // TS remux arm and fail visibly if they are not TS.
        if !PlaybackFeatureFlags.mpvEngineEnabled {
            return ResolvedEngine(engine: .avPlayerRemuxTS, routeURL: url, headers: headers)
        }
        return ResolvedEngine(engine: .mpv, routeURL: url, headers: headers)
    }

    /// TEST (AVPlayer VOD): route a VOD launch through the unified
    /// container instead of the legacy PlayerView cover, so the tile's
    /// AVPlayer VOD chain (MP4 direct / MKV cue-indexed remux, resume,
    /// display criteria, mpv fallback) runs. Returns false when the
    /// engine toggle is off or the URL is not VOD-shaped - the caller
    /// then mounts the legacy cover exactly as before, so the mpv path
    /// is byte-for-byte untouched.
    ///
    /// Known v1 gaps vs the legacy cover, accepted for the field test:
    /// the in-player Switch Version menu and sleep timer are the
    /// container chrome's versions, and lockscreen/Now Playing mirrors
    /// the tile item generically.
    @discardableResult
    func beginVOD(title: String,
                  streamURL: URL,
                  headers: [String: String],
                  posterURL: URL?,
                  vodID: String?,
                  serverID: String?,
                  vodType: String,
                  resumePositionMs: Int32?,
                  versionOptions: [VODVersionOption] = [],
                  selectedVersionID: Int? = nil,
                  versionSelectionKey: String? = nil,
                  kind: TilePlaybackKind = .vod,
                  dvrScheduledEnd: Date? = nil,
                  dvrChannelID: String? = nil) -> Bool {
        guard PlaybackFeatureFlags.avPlayerRemuxTS else { return false }
        let ext = streamURL.pathExtension.lowercased()
        // m3u8 = HLS-shaped (in-progress DVR windows, HLS-fronted VOD);
        // AVPlayer plays those natively, so they belong in the container.
        let vodShape = streamURL.path.contains("/proxy/vod/")
            || ["mkv", "mp4", "m4v", "mov", "m3u8"].contains(ext)
        // mpv disabled: no legacy-cover escape hatch; every VOD launch
        // goes through the container and fails visibly if it must.
        guard vodShape || !PlaybackFeatureFlags.mpvEngineEnabled else { return false }
        // PERSISTED URLs (Continue Watching rows saved before the
        // session-minting change) arrive WITHOUT a session segment, and
        // sessionless requests go through Dispatcharr's idle-session
        // adoption - the pin is discarded and the play can land on a
        // stale provider connection (13:33 field failure: dead upstream
        // on a resumed sessionless URL). Normalize: mint a session into
        // any bare /proxy/vod/ URL at launch time.
        let streamURL = Self.ensureVODSession(streamURL)
        let store = MultiviewStore.shared
        if !store.tiles.isEmpty { exit() }
        store.lockEngine(ResolvedEngine(engine: .avPlayerRemuxTS,
                                        routeURL: streamURL,
                                        headers: headers))
        let result = store.addVOD(title: title, streamURL: streamURL,
                                  headers: headers, posterURL: posterURL,
                                  kind: kind, vodID: vodID, serverID: serverID,
                                  vodType: vodType,
                                  resumePositionMs: resumePositionMs,
                                  bypassWarning: true,
                                  dvrScheduledEnd: dvrScheduledEnd,
                                  dvrChannelID: dvrChannelID)
        guard result == .added else {
            DebugLogger.shared.log("[Engine] beginVOD: addVOD -> \(result); falling back to legacy cover",
                                   category: "Playback", level: .warning)
            exit()
            return false
        }
        DebugLogger.shared.log("[Engine] beginVOD: \(title) via AVPlayer container (\(ext.isEmpty ? "proxy" : ext))",
                               category: "Playback", level: .info)
        // Resume decision, explicitly (review 2026-09-11 section 5
        // proposal 4): the detail-sheet resume bug had to be found by
        // bisecting button geometry in the [FOCUS] tracer because the
        // only evidence was the ABSENCE of a seek line. Log what was
        // asked for against what is saved, on every launch.
        if let vodID, !vodID.isEmpty {
            let saved = WatchProgressManager.getResumePosition(vodID: vodID, serverID: serverID)
            DebugLogger.shared.log(
                "[VOD-RESUME] vodID=\(vodID) requested=\(resumePositionMs.map { "\($0)ms" } ?? "none") "
                + "source=\(kind) saved=\(saved.map { "\($0)ms" } ?? "none")",
                category: "Playback", level: .info)
        }
        store.setVODVersionContext(options: versionOptions,
                                   selectedID: selectedVersionID,
                                   selectionKey: versionSelectionKey)
        mode = .multiview
        return true
    }

    /// Mint a VOD session id into a bare Dispatcharr /proxy/vod/ URL
    /// (see DispatcharrAPI.mintVODSession for why sessionless requests
    /// are unsafe). URLs that already carry a session, and non-proxy
    /// URLs, pass through untouched.
    static func ensureVODSession(_ url: URL) -> URL {
        let comps = url.pathComponents // ["/", "proxy", "vod", type, uuid, session?]
        guard comps.count == 5, comps[1] == "proxy", comps[2] == "vod" else { return url }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let session = "vod_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...9999))"
        c.path = url.path + "/" + session
        return c.url ?? url
    }

    @discardableResult
    func begin(item: ChannelDisplayItem,
               server: ServerConnection?,
               isLive: Bool = true,
               bypassNativeRouter: Bool = false) -> Bool {
        // Engine routing now happens INSIDE the container: every session
        // (single or multiview, AVPlayer or mpv) enters MultiviewStore,
        // and `enterMultiview` calls `resolveEngine` to lock the engine
        // once. A single AVPlayer-eligible channel is a one-tile AVPlayer
        // session in the same container as mpv, so single<->multiview is
        // one smooth path (no separate cover, no engine-switch restart).
        // `bypassNativeRouter` is retained for source compatibility with
        // the legacy fallback callers but no longer routes anywhere; the
        // session engine is the single source of truth.
        _ = bypassNativeRouter

        // A warm ingest left from an earlier press is dead the moment any
        // OTHER tune starts (different channel, or this channel as catch-up /
        // VOD); release it now instead of after the adoption window, which
        // kept the previous channel's upstream open on the server.
        LivePrewarm.shared.cancel(unlessLiveChannelID: isLive ? item.id : nil,
                                  reason: "another tune started")

        #if os(iOS)
        // GH #33: while this phone is a companion remote, a live channel tap
        // RETUNES THE TV instead of starting local playback. This must gate
        // HERE (not only in NowPlayingManager.startPlaying) because begin()
        // spins the whole tile pipeline up before startPlaying runs -- the
        // 2026-07-17 Streamer test left ESPN2 playing silently BEHIND the
        // remote cover. Non-Dispatcharr channels fall through to local.
        if isLive, CompanionClient.shared.isControlling, !PlayWhereRouter.shared.localPinned,
           let androidID = CompanionClient.androidChannelID(for: item) {
            DebugLogger.shared.log(
                "[Companion] begin: routing \(item.name) to controlled TV",
                category: "Playback", level: .info
            )
            CompanionClient.shared.setChannel(androidID, title: item.name)
            return true
        }
        // Rule 1 / rule 5 (Logan 2026-09-12): same gate for Google Cast, and
        // for the same reason -- begin() spins the tile pipeline up before
        // startPlaying runs, so without this the phone would play the channel
        // locally behind the card.
        if isLive, AerioCastController.shared.isCasting,
           !PlayWhereRouter.shared.localPinned {
            DebugLogger.shared.log(
                "[Cast] begin: routing \(item.name) to the receiver",
                category: "Playback", level: .info
            )
            AerioCastController.shared.castPickedChannel(item)
            return true
        }
        // CarPlay (Logan 2026-10-08): with the app open in CarPlay the phone
        // never plays video. A live channel picked on the phone goes to the
        // car's headless engine, exactly like a pick while casting, and the
        // phone shows the CarPlay dock card.
        if isLive, NowPlayingManager.shared.isCarPlayConnected {
            debugLog("[CARPLAY] tune: phone pick \(item.name) routed to the car")
            HeadlessPlaybackController.shared.start(item: item, server: server, isLive: true,
                                                    videoCapable: HeadlessPlaybackController.shared.videoCapable)
            return true
        }
        #endif

        let store = MultiviewStore.shared

        // Gate at the cap, `add(...)` will reject past `maxTiles` but
        // we want to bail earlier so the caller gets a clean false
        // before we start any side-effect writes. `.info` (not
        // `.warning`) because a user tapping Add while at 9/9 is
        // expected UX, not an error.
        if !store.tiles.isEmpty, store.isAtMax {
            DebugLogger.shared.log(
                "[MV-Mode] begin refused: at cap (\(store.tiles.count))",
                category: "Playback", level: .info
            )
            return false
        }

        #if os(iOS)
        // Seamless AirPlay flip (2026-09-27, device log dev_log18 11:16:00):
        // a channel picked from the list, guide or card while a tile serves
        // an AirPlay receiver used to take the swap-from-mini teardown
        // below, which dropped LAN delivery and re-handshook the receiver
        // (10.5 s handover). Swap the serving tile's content in place
        // instead; the tile then retargets its remuxer under the same LAN
        // playlist. Only live channels that ride the TS remux qualify; the
        // tile itself falls back to a full re-tune for anything it cannot
        // splice.
        if isLive, AirPlayTileDelivery.isServingReceiver, store.tiles.count == 1,
           let tileID = store.audioTileID,
           store.tiles.first?.item.id != item.id,
           let resolved = MultiviewStore.resolveStream(item, server: server),
           classifyStreamURL(resolved.url) == .mpegTS,
           PlayerSession.resolveEngine(item: item, server: server, isLive: true).engine == .avPlayerRemuxTS {
            AirPlayTileDelivery.noteFlipEntry(NowPlayingManager.shared.isMinimized
                ? "PlayerSession.begin(swap-from-mini)" : "PlayerSession.begin")
            if store.swapTileContent(tileID: tileID, to: item, server: server) {
                DebugLogger.shared.log(
                    "[MV-Mode] begin(airplay-in-place): \(item.name)",
                    category: "Playback", level: .info
                )
                NowPlayingManager.shared.startPlaying(
                    item,
                    headers: server?.authHeaders ?? ["Accept": "*/*"],
                    isLive: true
                )
                return true
            }
            AirPlayTileDelivery.noteFlipEntry(nil)
        }
        #endif

        // Special case: user picks a channel from the guide while
        // the mini is up (N=1 + minimized). Expected UX is "swap the
        // mini's stream to the new channel", NOT "append a second
        // tile and turn the mini into a tiny 2-grid". Achieve this
        // with a full teardown + fresh seed, the MultiviewContainer
        // stays mounted (HomeView's `.multiview` branch is driven
        // by `mode`, which stays `.multiview` across the reseed)
        // but the tile's mpv handle is swapped.
        if NowPlayingManager.shared.isMinimized && store.tiles.count == 1 {
            DebugLogger.shared.log(
                "[MV-Mode] begin(swap-from-mini): \(item.name)",
                category: "Playback", level: .info
            )
            // Radio Mode: the pick switches the audio and stays hidden.
            if isLive { RadioModeSession.shared.noteSwitch(to: item) }
            exit()
            enterMultiview(seeding: item, server: server)
            let resolvedHeaders = server?.authHeaders ?? ["Accept": "*/*"]
            NowPlayingManager.shared.startPlaying(
                item,
                headers: resolvedHeaders,
                isLive: isLive
            )
            return true
        }

        if store.tiles.isEmpty {
            // Tune clock starts HERE, at the press (review 2026-09-11,
            // marker inventory): every stage down to the first frame is
            // measured from this instant, not from the player's own
            // construction.
            if isLive { TuneTimeline.shared.press(item.name) }
            // Warm start (review 2026-09-11 section 1 proposal 8): open
            // the upstream NOW, in parallel with the SwiftUI multiview
            // transition, so the 220 to 2532 ms upstream open overlaps
            // the transition instead of following it. Live TS-remux tunes
            // only; LivePrewarm owns the cancel path.
            if isLive, PlaybackFeatureFlags.avPlayerRemuxTS,
               let resolved = MultiviewStore.resolveStream(item, server: server),
               PlayerSession.resolveEngine(item: item, server: server,
                                           isLive: true).engine == .avPlayerRemuxTS,
               classifyStreamURL(resolved.url) == .mpegTS {
                let rewindSeconds: Double = {
                    guard UserDefaults.standard.bool(forKey: "liveRewindEnabled") else { return 0 }
                    let mins = UserDefaults.standard.integer(forKey: "liveRewindDepthMinutes")
                    return Double(mins > 0 ? mins : 30) * 60
                }()
                LivePrewarm.shared.begin(key: resolved.url.absoluteString,
                                         channelID: item.id,
                                         headers: resolved.headers,
                                         rewindSeconds: rewindSeconds)
            }
            // Fresh session, delegate to the existing seed-tile path.
            // This ALSO mirrors into `NowPlayingManager.startPlaying`
            // so CarPlay / MPRemoteCommandCenter / lockscreen get
            // populated, and flips `mode = .multiview`. Phase C will
            // change this to `mode = .playing` + a direct seed call.
            enterMultiview(seeding: item, server: server, isLive: isLive)
            // `NowPlayingManager.startPlaying` isn't called by
            // `enterMultiview`, the original single-mode path did it
            // on the PlayerView mount. Callers under the feature flag
            // are skipping the `.single` path entirely, so do the
            // mirror here. The bridge gating keeps the lockscreen
            // pointed at the audio tile regardless.
            //
            // Header fallback matches `ChannelListView.playerHeaders()`
            // semantics, if `server` resolves but has no custom auth
            // headers (XC / M3U typically), we still want to populate
            // NowPlayingManager so the lockscreen shows the channel
            // name + artwork. Without the fallback, a non-Dispatcharr
            // server would silently skip the mirror and CarPlay /
            // lockscreen would display stale metadata from the
            // previous session.
            let resolvedHeaders = server?.authHeaders ?? ["Accept": "*/*"]
            NowPlayingManager.shared.startPlaying(
                item,
                headers: resolvedHeaders,
                isLive: isLive
            )
            DebugLogger.shared.log(
                "[MV-Mode] begin(fresh): \(item.name) isLive=\(isLive)",
                category: "Playback", level: .info
            )
            return true
        } else {
            // Already playing, add as another tile.
            let result = store.add(item, server: server)
            DebugLogger.shared.log(
                "[MV-Mode] begin(add): \(item.name) result=\(result)",
                category: "Playback", level: .info
            )
            switch result {
            case .added, .alreadyPresent:
                return true
            case .needsWarning:
                // Caller (add-sheet) handles the warning flow. For
                // the non-sheet callers going through `begin(...)`
                // (channel list taps while multiview active, CarPlay
                // flipping channel mid-multiview), treat the warning
                // as implicit consent, they already tapped to play.
                _ = store.add(item, server: server, bypassWarning: true)
                return true
            case .rejectedMax, .unresolvable:
                return false
            }
        }
    }

    /// One-shot LAN/WAN failover for a live Dispatcharr channel that could
    /// not play: re-probe, re-derive the stream URL from the active server's
    /// (possibly flipped) effectiveBaseURL, and re-begin. XC/M3U URLs are
    /// absolute and can't be re-pointed, so bail for them.
    ///
    /// Returns true only when a genuinely different URL was selected and
    /// playback was re-begun; false otherwise (not Dispatcharr, no active
    /// server, no UUID, or the re-probe produced the SAME URL). The
    /// URL-unchanged bail is what stops a dead WAN host from looping: if the
    /// probe didn't flip the LAN/WAN verdict, the rebuilt URL equals the
    /// current one and we fail fast back to the caller's error overlay.
    @discardableResult
    func failoverRetryCurrent() async -> Bool {
        // Re-probe in case the LAN/WAN verdict is stale, then re-tune. Used
        // from the player's terminal-error path (a channel that could not
        // start). The verdict-flip-while-playing case is handled separately
        // and synchronously by `retuneCurrentToActiveURL` (driven by the
        // probe), so this path mainly catches "tapped a channel, it failed".
        _ = await TVLANProbe.shared.reprobeAndWait()
        return retuneCurrentToActiveURL()
    }

    /// Re-point the currently-playing live channel to the active server's
    /// current `effectiveBaseURL` (LAN or WAN), WITHOUT re-probing. Called
    /// when the probe flips the LAN/WAN verdict while a stream is playing (the
    /// leaving-home-WiFi case) so the stream continues on the reachable URL
    /// instead of freezing on a now-dead one. Bails when nothing is playing,
    /// the source is not Dispatcharr (XC/M3U stream URLs are absolute and
    /// cannot be re-pointed), or the rebuilt URL is unchanged (which also
    /// stops any re-tune loop, since a no-flip probe leaves the URL as-is).
    @discardableResult
    func retuneCurrentToActiveURL() -> Bool {
        guard let item = NowPlayingManager.shared.playingItem,
              let server = ChannelStore.shared.activeServer,
              server.type == .dispatcharrAPI,
              let uuid = item.uuid else { return false }
        let newURLs = ChannelStore.dispatcharrStreamURLs(base: server.effectiveBaseURL, uuid: uuid)
        let current = item.streamURL ?? item.streamURLs.first
        guard let primary = newURLs.first, primary != current else { return false }  // URL unchanged
        debugLog("🔁 [Failover] re-tuning live stream to \(primary.scheme ?? "?")://\(primary.host ?? "?") after LAN/WAN flip")
        var rebuilt = item
        rebuilt.streamURL = primary
        rebuilt.streamURLs = newURLs
        stop()
        return begin(item: rebuilt, server: server, isLive: true)
    }

    /// Full-teardown stop that eventually replaces `exit()`. Phase A
    /// just forwards to `exit()` so everything stays identical
    /// behaviourally; Phase E will collapse this path entirely.
    func stop() {
        exit()
    }
}

// MARK: - Debug feature flag

/// Runtime toggle for the Phase B–D migration. **Defaults to `true`**
/// as of Phase D, the unified `PlayerSession.begin(...)` +
/// `PlaybackContainerView` path is now the canonical single-AND-multiview
/// UI, and the legacy `NowPlayingManager.startPlaying` / `PlayerView`
/// path is kept only as a fallback for the (increasingly few) code
/// paths still branching on it during Phase E cleanup.
///
/// The flag remains in place so a user who hits a unified-path
/// regression can flip it off in Developer Settings to get the
/// legacy behaviour, but the default flow for everyone is now unified.
///
/// Flip explicitly via `UserDefaults.standard.set(false, forKey:
/// "playback.unified")` from LLDB or the Developer Settings screen.
///
/// Naming matches the plan: key `"playback.unified"`.
/// The playback engine for a whole session. Decided ONCE when a session
/// begins and held for its life (single stream and every multiview tile),
/// so a session is all-AVPlayer or all-mpv, never mixed.
enum PlaybackEngine: Equatable {
    case mpv
    case avPlayerDirectHLS   // genuine HLS, or a server-side-upgraded TS URL, played direct
    case avPlayerRemuxTS     // raw TS through the on-device remuxer
    var isAVPlayer: Bool { self != .mpv }
}

/// The resolver's verdict: the locked engine plus the URL/headers to use.
struct ResolvedEngine {
    let engine: PlaybackEngine
    let routeURL: URL    // upgraded URL for direct-HLS, else the original
    let headers: [String: String]
}

enum PlaybackFeatureFlags {
    /// Per-segment [MKV-TIMING] lines for every segment, not just the
    /// first five and the non-zero-slip ones (review 2026-09-11 section 6
    /// proposal 2). Off unless a diagnosis needs the full trace.
    /// Developer "Force HLS" (2026-10-04): Dispatcharr Direct Connect
    /// live channels request `output_format=hls` and route direct to
    /// AVPlayer without waiting for the capability probe. Read per tune.
    static var forceHLS: Bool {
        UserDefaults.standard.bool(forKey: "developer.forceHLS")
    }

    static var verbosePlaybackTiming: Bool {
        UserDefaults.standard.bool(forKey: "playback.verboseTiming")
    }

    /// Engine auto-detection, HLS arm (user directive 2026-07-15: "detect the
    /// stream type; AVPlayer when able, mpv fallback"). **Default ON**: live
    /// streams that are genuine HLS (.m3u8) or come from a Dispatcharr server
    /// that natively segments HLS (HLSCapabilityStore probe) play through
    /// AVPlayer -- the device-verified strong path (fast first frame, native
    /// HEVC decode, real HDR out). mpv remains the automatic engine for
    /// everything else, and a hard AVPlayer failure one-way downgrades the
    /// session to mpv (MultiviewStore.downgradeToMPV). Absent-key-means-on
    /// (object(forKey:) probe) so existing installs pick the default up
    /// without regressing an explicit user opt-out.
    static var avPlayerForHLS: Bool {
        // HARD-OFF RULE: an .m3u8 live channel must route direct HLS -
        // with this flag off and mpv off it would hit the TS remux and
        // fail on playlist bytes.
        if !mpvEngineEnabled { return true }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "playback.avplayerHLS") == nil {
            return true
        }
        return defaults.bool(forKey: "playback.avplayerHLS")
    }

    /// Engine auto-detection, remux arm: raw MPEG-TS live streams
    /// (Dispatcharr /proxy/ts/) through the on-device TS-to-HLS remuxer into
    /// AVPlayer. H.264 + AC-3/AAC only; the codec gate auto-falls back to mpv
    /// (HEVC, MPEG-2, MP2). **Default ON since the 2026-08-21 field test**
    /// (branch test/avplayer-remux-default): Logan is running the remux as
    /// the default engine for a weekend to qualify it for the MPV removal
    /// plan. The June 2026 opt-in reasons still hold and are the test's
    /// watch list: the loopback remux server suspends when the app
    /// backgrounds (no background audio) and native<->container transitions
    /// restart the stream. Absent-key-means-on convention (see
    /// useUnifiedPlayback) so flipping the Developer toggle OFF still works
    /// and is remembered.
    static var avPlayerRemuxTS: Bool {
        // HARD-OFF RULE: no mpv means the AVPlayer engines must be on -
        // a disabled remux flag would leave nothing to play with.
        if !mpvEngineEnabled { return true }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "playback.avplayerRemuxTS") == nil {
            return true
        }
        return defaults.bool(forKey: "playback.avplayerRemuxTS")
    }

    /// `true` (default) while routing through the unified
    /// `PlayerSession.begin(...)` path; `false` keeps the legacy
    /// `NowPlayingManager.startPlaying` + `PlayerView` behaviour.
    ///
    /// Reads UserDefaults with `object(forKey:)` first so we can
    /// distinguish "user explicitly turned it off" (value present,
    /// returns their Bool) from "never set" (value absent → default
    /// true). A plain `bool(forKey:)` would default absent keys to
    /// false and silently regress every existing user to the legacy
    /// path on this build.
    static var useUnifiedPlayback: Bool {
        // HARD-OFF RULE (Logan 2026-08-28): with the mpv engine
        // disabled, the unified container is the ONLY player - the
        // legacy single-stream PlayerView is mpv by construction, so no
        // toggle combination may reach it.
        if !mpvEngineEnabled { return true }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "playback.unified") == nil {
            return true
        }
        return defaults.bool(forKey: "playback.unified")
    }

    /// `true` (default) → the tvOS Live-TV transport uses the native-style
    /// circular tool row (frosted icon buttons, bottom-right) for BOTH engines,
    /// instead of the legacy labeled pill row. This is the "modern player
    /// chrome", deliberately decoupled from the AVPlayer engine so users get
    /// the native look on the stable mpv path. Same absent-key-means-default-on
    /// convention as `useUnifiedPlayback` so existing users are not regressed.
    static var useModernPlayerChrome: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "playback.modernChrome") == nil {
            return true
        }
        return defaults.bool(forKey: "playback.modernChrome")
    }

    /// POLICY (Logan, 2026-08-28): mpv defaults OFF and stays OFF - this
    /// branch feeds an AVPlayer-only beta group, then the wider
    /// TestFlight audience. OFF is a HARD guarantee, not a test flag:
    /// the resolver never picks mpv, tile fallbacks show an on-tile
    /// error instead of swapping engines, downgradeToMPV is a logged
    /// no-op, useUnifiedPlayback/avPlayerRemuxTS are forced on so the
    /// legacy mpv-only surfaces are unreachable, and local-file
    /// recordings ride the TS-ingest container path. The Developer
    /// toggle exists for A/B comparison only. (Superseded 2026-08-26
    /// note said to revert the default before shipping - it now ships
    /// anyone but Logan.
    static var mpvEngineEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "dev.mpvEngineEnabled") == nil {
            return false
        }
        return defaults.bool(forKey: "dev.mpvEngineEnabled")
    }
}

/// Press-to-first-frame stage clock for a live tune.
///
/// Apple TV review 2026-09-11, marker inventory: the only tune number
/// the app printed was `[AVP-STREAM] first frame playing in Nms from
/// screen open`, measured from the AVPlayer driver's construction -
/// AFTER the remuxer was already READY. The number Logan feels is
/// press -> first frame, 10x to 25x larger. This records the PRESS and
/// every stage in between, then prints one line with the breakdown.
///
/// Deliberately not `@MainActor`: stages are marked from the remuxer's
/// serial ingest queue as well as from main. An NSLock keeps it honest
/// and the work is a couple of string appends per tune.
final class TuneTimeline: @unchecked Sendable {
    static let shared = TuneTimeline()

    private let lock = NSLock()
    private var pressAt: CFTimeInterval?
    private var label = ""
    private var stages: [(name: String, ms: Int)] = []
    /// This tune's program went audio-only (GH AerioTV#90).
    private var audioOnly = false

    /// A channel press (or channel flip) started a tune. Resets the clock.
    func press(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        pressAt = CACurrentMediaTime()
        label = name
        audioOnly = false
        stages.removeAll(keepingCapacity: true)
    }

    /// The remuxer declared the program audio-only: the first "frame" is
    /// the first audio, logged as press->audio.
    func markAudioOnly() {
        mark("audioOnly")
        lock.lock(); audioOnly = true; lock.unlock()
    }

    /// True while a tune is armed and has not reached first frame yet. Read by
    /// the background EPG re-sweep (Logan 2026-09-12), which must not spend
    /// network or CPU between a channel press and the first frame. The same
    /// 60 s sanity bound `firstFrame()` uses applies, so a tune that silently
    /// died can never hold the sweep off forever.
    var isTuning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let pressAt else { return false }
        return CACurrentMediaTime() - pressAt < 60
    }

    /// Record a stage, first occurrence per tune only.
    func mark(_ stage: String) {
        lock.lock(); defer { lock.unlock() }
        guard let pressAt, !stages.contains(where: { $0.name == stage }) else { return }
        stages.append((stage, Int((CACurrentMediaTime() - pressAt) * 1000)))
    }

    /// First frame reached the screen: print the whole breakdown and
    /// disarm until the next press.
    func firstFrame() {
        lock.lock()
        guard let pressAt else { lock.unlock(); return }
        // A tune that never produced a frame must not hand its clock to
        // the next unrelated playback (a VOD launched minutes later).
        guard CACurrentMediaTime() - pressAt < 60 else {
            self.pressAt = nil
            stages.removeAll(keepingCapacity: true)
            lock.unlock()
            return
        }
        let total = Int((CACurrentMediaTime() - pressAt) * 1000)
        let breakdown = stages.map { "\($0.name)=\($0.ms)ms" }.joined(separator: " ")
        let name = label
        let wasAudioOnly = audioOnly
        self.pressAt = nil
        audioOnly = false
        stages.removeAll(keepingCapacity: true)
        lock.unlock()
        if wasAudioOnly {
            debugLog("[TUNE] press->audio \(total) ms channel=\(name) | \(breakdown)")
        } else {
            debugLog("[TUNE] press->firstFrame \(total)ms channel=\(name) | \(breakdown)")
        }
    }
}

/// Live tune warm-start: open the upstream at PRESS time, in parallel
/// with the SwiftUI multiview transition, instead of after the tile
/// mounts.
///
/// Apple TV review 2026-09-11 section 1 proposal 8: `lock -> ingest` cost
/// 125 to 183 ms and the upstream open itself 220 to 2532 ms
/// (session.txt rows 8, 9, 11), all of it serialized AFTER the
/// transition. The tile adopts this remuxer when it mounts; if the user
/// backs out first, `cancel` stops it so no upstream connection is left
/// dangling (which is exactly what generates the 503 in section 2).
@MainActor
final class LivePrewarm {
    static let shared = LivePrewarm()

    struct Pending {
        let key: String
        let channelID: String
        let rewindSeconds: Double
        let remuxer: TSHLSRemuxer
        var readyURL: URL?
        var failure: String?
        var videoParams: (width: Int, height: Int, fps: Double, tenBit: Bool)?
    }

    private var pending: Pending?
    private var expiry: Task<Void, Never>?

    /// Open the upstream now. No-op when a prewarm for the same channel
    /// is already running; any OTHER pending prewarm is cancelled first
    /// so at most one warm connection exists.
    func begin(key: String, channelID: String, headers: [String: String],
               rewindSeconds: Double) {
        if let p = pending {
            if p.key == key { return }
            cancel(reason: "superseded by \(channelID)")
        }
        // A retained channel is already ingesting this upstream; a second
        // connection to it is exactly the 503 generator of section 2.
        guard !LiveChannelRetention.shared.entries.contains(where: {
            $0.key == key || (!channelID.isEmpty && $0.channelID == channelID)
        }) else { return }
        guard let url = URL(string: key) else { return }
        let mux = TSHLSRemuxer(sourceURL: url, headers: headers,
                               rewindWindowSeconds: rewindSeconds)
        pending = Pending(key: key, channelID: channelID,
                          rewindSeconds: rewindSeconds, remuxer: mux)
        mux.onReady = { [weak self] url in
            Task { @MainActor in
                guard let self, self.pending?.key == key else { return }
                self.pending?.readyURL = url
            }
        }
        mux.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.pending?.key == key else { return }
                self.pending?.failure = "\(error)"
            }
        }
        mux.onVideoParameters = { [weak self] w, h, fps, tenBit in
            Task { @MainActor in
                guard let self, self.pending?.key == key else { return }
                self.pending?.videoParams = (w, h, fps, tenBit)
            }
        }
        mux.start()
        TuneTimeline.shared.mark("prewarm")
        debugLog("[TUNE-PREWARM] ingest opened at press for channel=\(channelID)")
        // Cancel path: nothing adopted it (the user backed out of the
        // transition, or the tune routed to another engine), so release
        // the upstream rather than holding a provider slot.
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cancel(reason: "never adopted")
        }
    }

    /// The tile that just mounted takes the warm pipeline, if it is the
    /// same channel AND wants the same rewind window.
    func adopt(key: String, channelID: String, rewindSeconds: Double) -> Pending? {
        guard let p = pending,
              p.key == key || (!channelID.isEmpty && p.channelID == channelID),
              abs(p.rewindSeconds - rewindSeconds) < 0.5 else { return nil }
        pending = nil
        expiry?.cancel()
        expiry = nil
        debugLog("[TUNE-PREWARM] adopted by tile channel=\(channelID)")
        return p
    }

    var hasPending: Bool { pending != nil }

    /// `completion` runs on main once the warm remuxer's ingest task is
    /// cancelled and its session invalidated (immediately when nothing is
    /// pending), so a caller can open its own ingest with no overlap.
    func cancel(reason: String, completion: (@Sendable () -> Void)? = nil) {
        guard let p = pending else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        pending = nil
        expiry?.cancel()
        expiry = nil
        p.remuxer.stop(completion: completion)
        debugLog("[TUNE-PREWARM] cancelled (\(reason)) channel=\(p.channelID)")
    }

    /// Cancel the pending prewarm unless it is for [channelID] (nil cancels
    /// any). Keeps the adoption window only for the tune it was opened for.
    func cancel(unlessLiveChannelID channelID: String?, reason: String) {
        guard let p = pending else { return }
        if let channelID, !channelID.isEmpty, p.channelID == channelID { return }
        cancel(reason: reason)
    }
}

// MARK: - Play where (Logan 2026-10-06)

/// "Play Here" or "Play on <receiver>": while a remote session is active
/// (Google Cast, AirPlay or AerioTV Remote, i.e. whenever the
/// remote-session card is showing) every pick from the list, the guide,
/// the Kept Live card, catch-up, Movies, Series and DVR asks where to play.
/// Every entry point calls `request`; with no session it plays at once.
/// Channel up/down, Recently Watched and other flips inside a player are
/// not entry points and never ask. Android twin: PlayWhereRouter in
/// feature/main.
@MainActor
final class PlayWhereRouter: ObservableObject {
    static let shared = PlayWhereRouter()

    /// True while a player the user sent to THIS device with "Play Here"
    /// is alive during a Cast or AerioTV Remote session. The live gates in
    /// PlayerSession.begin and NowPlayingManager.startPlaying (which send a
    /// live tune to the receiver while a session is up) stand aside, so
    /// the local player and its own channel flips stay here while the
    /// receiver keeps what it plays. Cleared when the local session ends
    /// (the mode stays idle for 1.5 s) or the remote session ends.
    /// AirPlay uses AirPlayMonitor's per-tune local latch instead.
    private(set) var localPinned = false

    #if os(iOS)
    private var modeSubscription: AnyCancellable?
    private var clearTask: Task<Void, Never>?
    #endif

    private init() {}

    /// What the item is, so the router knows which receivers can take it.
    enum Item {
        /// A live channel. Every transport can take it (Cast through the
        /// card's channel path, AerioTV Remote by its Dispatcharr channel
        /// id, AirPlay through the normal headless tune).
        case live(ChannelDisplayItem)
        /// Catch-up, VOD movie or episode, or a DVR recording. Only AirPlay
        /// can take these: the Cast web receiver and Cast Connect load path
        /// is live only (AerioCastController.load refuses non-live content)
        /// and the AerioTV Remote protocol has no command to open a
        /// program, title or recording on the TV, so "Play on" is hidden
        /// for those two transports.
        case nonLive
    }

    /// Entry point for every pick. `title`: channel name for live, program
    /// or title name otherwise. `play`: the existing local play path,
    /// exactly as it runs with no session.
    func request(title: String, item: Item, play: @escaping () -> Void) {
        #if os(iOS)
        guard let transport = Self.activeTransport() else {
            play()
            return
        }
        let receiver = Self.receiverName(transport)
        let canSend: Bool = {
            switch (transport, item) {
            case (.cast, .live), (.airPlay, _): return true
            case (.companion, .live(let ch)): return CompanionClient.androidChannelID(for: ch) != nil
            case (.cast, .nonLive), (.companion, .nonLive): return false
            }
        }()
        present(title: title, receiver: canSend ? receiver : nil,
                onHere: { [weak self] in
                    debugLog("[Cast] play-where prompt: here")
                    self?.playHere(transport: transport, play: play)
                },
                onReceiver: { [weak self] in
                    debugLog("[Cast] play-where prompt: receiver=\(receiver)")
                    self?.playOnReceiver(transport: transport, item: item, play: play)
                })
        #else
        // TV apps are not senders: no prompt.
        play()
        #endif
    }

    #if os(iOS)
    // MARK: Multiview (Logan 2026-10-06)

    /// The receiver name when the active remote session can open Multiview
    /// natively (AerioTV Remote host or Cast Connect TV app that advertised
    /// it), else nil.
    static func multiviewNativeReceiverName() -> String? {
        switch activeTransport() {
        case .cast:
            return AerioCastController.shared.canOpenMultiviewOnReceiver ? receiverName(.cast) : nil
        case .companion:
            let c = CompanionClient.shared
            return c.isControlling && c.hostMultiviewCapable ? receiverName(.companion) : nil
        default:
            return nil
        }
    }

    /// The composite transport when the active receiver cannot run
    /// Multiview itself and the phone can compose it (part 2, Logan
    /// 2026-10-06): the Chromecast web receiver, or an AirPlay receiver
    /// with a screen. nil otherwise.
    static func multiviewCompositeTransport() -> MultiviewCompositeSession.Transport? {
        guard multiviewNativeReceiverName() == nil else { return nil }
        switch activeTransport() {
        case .cast:
            return AerioCastController.shared.receiverTarget == .webReceiver ? .cast : nil
        case .airPlay:
            return AirPlayMonitor.servableAirPlayOutput() != nil
                && AirPlayMonitor.shared.receiver?.isAudioOnly != true ? .airPlay : nil
        default:
            return nil
        }
    }

    /// The "Play on <receiver>" name for `count` staged channels: native
    /// Multiview for any count, the phone composite for 2 to 4.
    static func multiviewReceiverName(count: Int) -> String? {
        if let native = multiviewNativeReceiverName() { return native }
        guard let t = multiviewCompositeTransport(), MultiviewCompositeSession.eligible(count: count) else { return nil }
        return receiverName(t == .cast ? .cast : .airPlay)
    }

    /// One-line note under the play buttons when the receiver can only take
    /// the phone composite and more channels are staged than it carries.
    static func multiviewLimitNote(count: Int) -> String? {
        guard multiviewCompositeTransport() != nil, count > MultiviewCompositeLayout.maxTiles else { return nil }
        return MultiviewCompositeSession.tileLimitNote
    }

    /// Multiview dock card Play: with a receiver that can take it, the
    /// play-where prompt; otherwise straight to Play Here.
    func requestMultiview(channels: [ChannelDisplayItem], focus: Int, play: @escaping () -> Void) {
        guard let receiver = Self.multiviewReceiverName(count: channels.count) else {
            playMultiviewHere(play: play)
            return
        }
        present(title: "Multiview", receiver: receiver,
                onHere: { [weak self] in
                    debugLog("[Cast] play-where prompt: here (multiview)")
                    self?.playMultiviewHere(play: play)
                },
                onReceiver: { [weak self] in
                    debugLog("[Cast] play-where prompt: receiver=\(receiver) (multiview)")
                    self?.playMultiviewOnReceiver(channels: channels, focus: focus)
                })
    }

    /// "Play Here": the local Multiview, pinned like any other Play Here
    /// while a session is up so the receiver keeps what it plays.
    func playMultiviewHere(play: @escaping () -> Void) {
        // A composite feeding the receiver from headless tiles: Play Here
        // ends the composite (the receiver goes idle) and the same tiles
        // become the local fullscreen player.
        if MultiviewCompositeSession.shared.isActive {
            MultiviewCompositeSession.shared.stop(detail: "play here", endTransport: true, teardownTiles: false)
            NowPlayingManager.shared.expand()
        }
        if let transport = Self.activeTransport() {
            playHere(transport: transport, play: play)
        } else {
            play()
        }
    }

    /// "Play on <receiver>": send multiview.open on the active transport
    /// when the receiver runs Multiview itself; otherwise the phone plays
    /// the Multiview here and sends the composite (2 to 4 channels).
    func playMultiviewOnReceiver(channels: [ChannelDisplayItem], focus: Int) {
        if Self.multiviewNativeReceiverName() == nil, let t = Self.multiviewCompositeTransport() {
            playMultiviewComposite(transport: t, count: channels.count)
            return
        }
        let sent: Bool
        switch Self.activeTransport() {
        case .cast: sent = AerioCastController.shared.openMultiviewOnReceiver(channels, focus: focus)
        case .companion: sent = CompanionClient.shared.openMultiview(channels, focus: focus)
        default: sent = false
        }
        guard sent else { return }
        // The receiver took the set: nothing stays staged on the phone.
        MultiviewDockState.clearStaging(reason: "sent to \(Self.receiverName(Self.activeTransport() ?? .cast))")
    }

    /// Phone-side composite: the tiles play here (they are the sources) and
    /// the composite goes to the receiver. AirPlay arms the composite first
    /// so the real tiles mount pinned to this device and the hidden
    /// composite tile takes the route; Cast pins local like Play Here.
    private func playMultiviewComposite(transport t: MultiviewCompositeSession.Transport, count: Int) {
        guard MultiviewCompositeSession.eligible(count: count) else {
            debugLog("[MV-CAST] composite refused: \(count) channels (2 to \(MultiviewCompositeLayout.maxTiles))")
            return
        }
        let store = MultiviewStore.shared
        let fresh = PlayerSession.shared.mode != .multiview
        // Composite audio (Logan 2026-10-07: no audio line logged at all):
        // the focused tile's audio comes from its TSHLSRemuxer ingest tap
        // (Apple documents no audio tap for HLS items, so the player tap
        // rarely delivers). A direct-HLS lock has no remuxer, so a fresh
        // composite session plays its tiles on the remux path instead.
        if fresh, store.sessionEngine == .avPlayerDirectHLS, let first = store.tiles.first {
            store.lockEngine(ResolvedEngine(engine: .avPlayerRemuxTS,
                                            routeURL: removingHLSOutputFormat(first.streamURL),
                                            headers: store.sessionHeaders))
            debugLog("[MV-CAST] composite: tiles on the remux path (ingest audio tap) instead of direct HLS")
        }
        let enterLocal = {
            if PlayerSession.shared.mode != .multiview { MultiviewDockState.playHereNow() }
        }
        switch t {
        case .cast:
            pinLocal()
            enterLocal()
            MultiviewCompositeSession.shared.start(transport: .cast)
        case .airPlay:
            MultiviewCompositeSession.shared.start(transport: .airPlay)
            enterLocal()
        }
        // Logan 2026-10-07: while the composite goes to the receiver the
        // phone shows no player and stays silent. The tiles decode headless
        // (HomeView hides the container in place while the composite runs;
        // the composite mutes every tile), the remote controls sheet shows
        // the live preview grid, and Stop tears the tiles down.
        guard MultiviewCompositeSession.shared.isActive else { return }
        #if os(iOS)
        AppOrientationLock.release()
        #endif
        if !NowPlayingManager.shared.isMinimized {
            NowPlayingManager.shared.applyMinimized()
        }
        debugLog("[MV-CAST] composite: phone player hidden, tiles decode headless and muted")
    }

    enum Transport { case cast, companion, airPlay }

    /// Same precedence as HomeView.activeRemoteTransport (the card).
    static func activeTransport() -> Transport? {
        if AerioCastController.shared.isCasting { return .cast }
        if CompanionClient.shared.isControlling { return .companion }
        let airPlay = AirPlayMonitor.shared
        switch airPlay.phase {
        case .probing, .idleRoute, .active: return .airPlay
        default: return airPlay.isExternal ? .airPlay : nil
        }
    }

    static func receiverName(_ t: Transport) -> String {
        switch t {
        case .cast: return AerioCastController.shared.connectedDeviceName ?? "TV"
        case .companion: return CompanionClient.shared.connectedTVName ?? "TV"
        case .airPlay: return AirPlayMonitor.shared.deviceName ?? "AirPlay"
        }
    }

    private func playHere(transport: Transport, play: @escaping () -> Void) {
        switch transport {
        case .cast, .companion:
            pinLocal()
            play()
        case .airPlay:
            // See AirPlayMonitor.pinLocalForPlayHere: the receiver's stream
            // belongs to the one player session, so it ends here.
            if AirPlayMonitor.shared.pinLocalForPlayHere() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { play() }
            } else {
                play()
            }
        }
    }

    private func playOnReceiver(transport: Transport, item: Item, play: @escaping () -> Void) {
        switch (transport, item) {
        case (.cast, .live(let ch)):
            // The card's channel path: no local player opens.
            AerioCastController.shared.castPickedChannel(ch)
        case (.companion, .live(let ch)):
            if let id = CompanionClient.androidChannelID(for: ch) {
                CompanionClient.shared.setChannel(id, title: ch.name)
            }
        case (.airPlay, _):
            // The normal tune: with the route on AirPlay it runs headless
            // and the receiver takes the player.
            AirPlayMonitor.shared.userPickedReceiver()
            play()
        default:
            break
        }
    }

    private func pinLocal() {
        localPinned = true
        clearTask?.cancel()
        clearTask = nil
        guard modeSubscription == nil else { return }
        modeSubscription = PlayerSession.shared.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self else { return }
                self.clearTask?.cancel()
                guard mode == .idle else { return }
                // A swap from the mini goes idle for an instant; only a
                // session that stays idle has ended.
                self.clearTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, let self,
                          PlayerSession.shared.mode == .idle,
                          NowPlayingManager.shared.playingItem == nil else { return }
                    self.unpin("local player closed")
                }
            }
    }

    func unpin(_ why: String) {
        guard localPinned else { return }
        localPinned = false
        clearTask?.cancel()
        clearTask = nil
        modeSubscription = nil
        debugLog("[Cast] play-where: local pin cleared (\(why))")
    }

    /// Native action sheet from the top-most view controller, so it shows
    /// over sheets, detail pages and covers alike.
    private func present(title: String, receiver: String?,
                         onHere: @escaping () -> Void,
                         onReceiver: @escaping () -> Void) {
        guard let top = Self.topViewController() else {
            onHere()
            return
        }
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Play Here", style: .default) { _ in onHere() })
        if let receiver {
            sheet.addAction(UIAlertAction(title: "Play on \(receiver)", style: .default) { _ in onReceiver() })
        }
        // An iPad popover drops a .cancel action (tapping outside cancels),
        // so the button is a plain one there to stay visible (parity with
        // the phone and the Android dialog).
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        sheet.addAction(UIAlertAction(title: "Cancel", style: pad ? .default : .cancel) { _ in
            debugLog("[Cast] play-where prompt: cancel")
        })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif
}

#if os(tvOS)
/// Multiview in the background on Apple TV (Leave Multiview > Back to
/// Guide). Same API as the iPhone/iPad `MultiviewBackgroundSession`: the
/// tiles keep playing with the container hidden (HomeView), the guide
/// takes focus, and a banner above the guide returns to the Multiview or
/// stops it. tvOS has no pinch-in, so the dialog button is the only entry.
@MainActor
final class MultiviewBackgroundSession: ObservableObject {
    static let shared = MultiviewBackgroundSession()
    @Published private(set) var isActive = false
    private var bag: Set<AnyCancellable> = []

    private init() {
        PlayerSession.shared.$mode
            .sink { [weak self] mode in
                guard let self, self.isActive, mode != .multiview else { return }
                self.clear(reason: "multiview ended")
            }
            .store(in: &bag)
        NowPlayingManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isActive, !NowPlayingManager.shared.isMinimized else { return }
                self.clear(reason: "expanded")
            }
            .store(in: &bag)
    }

    static var canEnter: Bool {
        PlayerSession.shared.mode == .multiview
            && MultiviewStore.shared.tiles.count >= 2
            && !shared.isActive
    }

    func enter() {
        guard Self.canEnter else { return }
        isActive = true
        let store = MultiviewStore.shared
        if let audio = store.tiles.first(where: { $0.id == store.audioTileID }) ?? store.tiles.first {
            NowPlayingManager.shared.lastPlayedChannelID = audio.item.id
        }
        debugLog("[MV-BG] background enter (Back to Guide) tiles=\(store.tiles.count)")
        NowPlayingManager.shared.applyMinimized()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .forceGuideFocus, object: nil)
        }
    }

    /// Banner Return (or Back/Play on the guide): the fullscreen Multiview
    /// as it was; the tiles never stopped.
    func returnToFullscreen() {
        guard isActive else { return }
        isActive = false
        debugLog("[MV-BG] return")
        withAnimation(.spring(response: 0.35)) { NowPlayingManager.shared.expand() }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        debugLog("[MV-BG] stop")
        PlayerSession.shared.stop()
    }

    private func clear(reason: String) {
        isActive = false
        debugLog("[MV-BG] background cleared (\(reason))")
    }
}
#endif

// MARK: - Radio Mode (Android#127 follow-up, Logan 2026-10-12)

/// Radio Mode: a live channel's audio with no video on screen. Reuses the
/// "hidden in place" pattern of MultiviewBackgroundSession: the one-tile
/// container stays mounted and playing with opacity 0 (HomeView), the
/// browse screens take over, and a dock card (iPhone / iPad) or a banner
/// above the guide (Apple TV) returns to the video with no re-tune or
/// stops it. Backgrounding keeps the audio on iPhone / iPad: the tile
/// skips its background quiesce while Radio Mode owns it and detaches
/// its AVPlayerLayer so iOS does not pause a video player in the
/// background (reattached on return). Apple TV is foreground only.
/// Stop-path timing for Radio Mode (iPad 2026-10-13: the card Stop blocked
/// the main thread 839 ms inside a SwiftUI update). Lines are written only
/// within 3 s of a Radio Mode stop: "[RADIO-STOP] <step> Nms (+Nms)".
enum RadioStopTrace {
    @MainActor private static var startedAt: CFTimeInterval = 0
    @MainActor static func begin() { startedAt = CACurrentMediaTime() }
    @MainActor static var isOn: Bool { startedAt > 0 && CACurrentMediaTime() - startedAt < 3 }
    /// Logs the time since `t0` and since the stop.
    @MainActor static func log(_ step: String, since t0: CFTimeInterval) {
        guard isOn else { return }
        let now = CACurrentMediaTime()
        debugLog("[RADIO-STOP] \(step) \(Int((now - t0) * 1000))ms (+\(Int((now - startedAt) * 1000))ms since stop)")
    }
}

extension Notification.Name {
    /// A short confirmation or error over the Live TV list and guide
    /// (userInfo "message").
    static let aerioChannelListToast = Notification.Name("AerioChannelListToast")
}

@MainActor
final class RadioModeSession: ObservableObject {
    static let shared = RadioModeSession()
    @Published private(set) var isActive = false {
        // The remuxer reads this when a tune starts: a Radio Mode tune cuts
        // audio-only from the first audio PES (AudioOnlyStartPolicy).
        didSet {
            AudioOnlyTuneIntent.shared.radioRequested = isActive
            guard oldValue != isActive else { return }
            if isActive {
                DispatchQueue.main.async { RadioModeSession.shared.adoptTileFailure() }
            } else {
                clearFailure()
                isBuffering = false
            }
        }
    }
    /// Set while a tune started from Radio Mode is reseeding the tile, so
    /// the transient idle / expand states of the swap do not end it.
    private var switching = false
    /// A stop that ends playback handles the surface itself (deferred,
    /// outside the SwiftUI transaction), so the isActive sink skips it.
    private var suppressReattach = false
    /// Source suffix for the next "[RADIO] switch" line ("sheet").
    private var pendingSwitchSource: String?
    /// The radio tile's stream failed (the player's Channel Unavailable
    /// state): its error text, nil while the stream plays. The card, the
    /// sheet, the tvOS banner, and the lock screen follow it.
    @Published private(set) var failureMessage: String?
    /// Seconds to the next automatic retry (0: a retry is running).
    @Published private(set) var retryCountdown = 0
    private var retryTask: Task<Void, Never>?
    /// True while Radio Mode is on and its stream is unavailable.
    var isFailed: Bool { isActive && failureMessage != nil }
    /// True while the radio tile holds paused to fill its buffer after an
    /// audio-only hold-back raise (AVPlayerProgressDriver pause-to-fill).
    /// The card and sheet read "Buffering" in the Connecting style, and the
    /// lock screen shows paused.
    @Published private(set) var isBuffering = false

    func setBuffering(_ on: Bool) {
        let next = on && isActive
        guard next != isBuffering else { return }
        isBuffering = next
        publishNowPlaying()
    }

    /// Status line for the card, sheet, and banner.
    var statusLine: String {
        if isFailed { return PlaybackFailureCopy.title }
        return isBuffering ? "Buffering" : "Playing in Radio Mode"
    }
    /// "Retrying in Ns", or "Reconnecting..." while a retry runs.
    var retryLine: String {
        retryCountdown > 0 ? PlaybackFailureCopy.retrying(retryCountdown) : PlaybackFailureCopy.reconnecting
    }
    private var bag: Set<AnyCancellable> = []
    #if os(iOS)
    /// The layer detached for background audio, with the player it showed.
    private weak var detachedPlayer: AVPlayer?
    #endif

    private init() {
        PlayerSession.shared.$mode
            .sink { [weak self] mode in
                guard let self, self.isActive, !self.switching, mode == .idle else { return }
                // exit() runs inside a channel swap too; only a session that
                // stays idle has really ended.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard self.isActive, !self.switching, PlayerSession.shared.mode == .idle else { return }
                    self.clear(reason: "playback ended")
                }
            }
            .store(in: &bag)
        NowPlayingManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isActive, !self.switching,
                      PlayerSession.shared.mode != .idle,
                      !NowPlayingManager.shared.isMinimized else { return }
                self.clear(reason: "expanded")
            }
            .store(in: &bag)
        // Channel Up / Down from the sheet swap the tile in place (no
        // begin()): follow the tile's channel for the card, the log and
        // the lock screen.
        MultiviewStore.shared.$tiles
            .map { $0.first?.item.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] id in
                guard let self, self.isActive, id != nil else { return }
                DispatchQueue.main.async {
                    guard self.isActive, let ch = self.channel else { return }
                    if !self.switching { debugLog("[RADIO] switch -> \(ch.name)") }
                    self.publishNowPlaying()
                }
            }
            .store(in: &bag)
        #if os(iOS)
        // Lock screen / Control Center Stop while Radio Mode is on (Play /
        // Pause come from NowPlayingBridge as for any playback).
        $isActive
            .removeDuplicates()
            .dropFirst()
            .sink { active in
                // didSet-time: isActive is about to change; read the player
                // through the store, not radioPlayer (which gates on it).
                let player = MultiviewStore.shared.audioTileID
                    .flatMap { MultiviewCompositeTaps.shared.player(tileID: $0) }
                DispatchQueue.main.async {
                    let radio = RadioModeSession.shared
                    if active { radio.startSurfaceEnforcement() }
                    else if radio.suppressReattach { radio.suppressReattach = false }
                    else { radio.reattachVideoSurface(player: player) }
                }
            }
            .store(in: &bag)
        $isActive
            .removeDuplicates()
            .sink { active in
                let cmd = MPRemoteCommandCenter.shared().stopCommand
                cmd.removeTarget(nil)
                cmd.isEnabled = active
                if active {
                    cmd.addTarget { _ in
                        DispatchQueue.main.async { RadioModeSession.shared.stop(reason: "lock screen Stop") }
                        return .success
                    }
                }
            }
            .store(in: &bag)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { RadioModeSession.shared.didEnterBackground() } }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { RadioModeSession.shared.willEnterForeground() } }
        #endif
    }

    /// Radio Mode is offered only for local playback: hidden while Cast,
    /// AirPlay, the AerioTV Remote or CarPlay owns playback.
    static var isAvailable: Bool {
        #if os(iOS)
        if AerioCastController.shared.isCasting { return false }
        if CompanionClient.shared.isControlling { return false }
        if AirPlayMonitor.shared.isExternal || AirPlayMonitor.shared.hostsHeadless { return false }
        if NowPlayingManager.shared.isCarPlayConnected { return false }
        if MultiviewCompositeSession.shared.isActive { return false }
        #endif
        if MultiviewBackgroundSession.shared.isActive { return false }
        return true
    }

    /// The channel Radio Mode is playing (the one live tile), nil when off.
    var channel: ChannelDisplayItem? {
        guard isActive else { return nil }
        return MultiviewStore.shared.tiles.first?.item
    }

    /// True when `channelID` is the channel playing in Radio Mode (the
    /// long-press menu then offers "Exit Radio Mode").
    func isRadioChannel(_ channelID: String) -> Bool {
        channel?.id == channelID
    }

    // Channel long-press menus (guide grid, channel list): one item.
    static let menuSymbol = "radio"
    /// Nil hides the item (Cast / AirPlay / Remote / CarPlay active, or
    /// the channel has no stream).
    static func menuTitle(for item: ChannelDisplayItem) -> String? {
        guard item.streamURL != nil else { return nil }
        if shared.isRadioChannel(item.id) { return "Exit Radio Mode" }
        return isAvailable ? "Radio Mode" : nil
    }
    static func menuAction(for item: ChannelDisplayItem) {
        if shared.isRadioChannel(item.id) {
            // "Exit Radio Mode" from a channel menu ends playback, exactly
            // like the card's Stop (iPhone 2026-10-12: returning to video
            // from here left a playing tile with no card).
            shared.stop(reason: "menu Exit")
        } else {
            shared.start(item: item, server: ChannelStore.shared.activeServer)
        }
    }

    // MARK: Declared radio channels (backend radio flag)

    /// Settings > Player "Radio Mode by Default" (Discord: Glitzbr). Off by
    /// default and per device: it rides its own Sync Categories row
    /// (SyncCategory.radioModeDefault), excluded unless the user opts in.
    static let byDefaultKey = "radioModeByDefault"
    static let byDefaultFooter = "Every channel opens in Radio Mode. Long-press a channel and choose Watch to play video."
    static var byDefault: Bool { UserDefaults.standard.bool(forKey: byDefaultKey) }

    /// True when a pick of `item` should open Radio Mode: the backend
    /// declares it radio, or "Radio Mode by Default" is on. The long-press
    /// Watch item is offered for exactly these channels.
    static func opensInRadioMode(_ item: ChannelDisplayItem) -> Bool {
        item.isRadio || byDefault
    }

    /// Long-press "Watch" on a radio channel: the next pick of this channel
    /// opens the full-screen player (artwork card) instead of Radio Mode.
    private static var watchOverride: (id: String, at: Date)?

    static func noteWatchVideo(_ item: ChannelDisplayItem) {
        guard opensInRadioMode(item) else { return }
        watchOverride = (item.id, Date())
    }

    /// A pick (tap / Select from the guide, list, favorites, recents, Kept
    /// Live, deep link) of a declared radio channel opens Radio Mode.
    /// False while Radio Mode is hidden (Cast, AirPlay, Remote, CarPlay,
    /// a Multiview grid) or already on (begin switches in place), and for
    /// a long-press Watch.
    static func shouldAutoOpen(for item: ChannelDisplayItem) -> Bool {
        if let o = watchOverride {
            watchOverride = nil
            if o.id == item.id, Date().timeIntervalSince(o.at) < 30 {
                debugLog("[RADIO] declared radio \(item.name): Watch, full-screen player")
                return false
            }
        }
        guard opensInRadioMode(item), item.streamURL != nil, isAvailable, !shared.isActive else { return false }
        let store = MultiviewStore.shared
        if PlayerSession.shared.mode == .multiview, store.tiles.count > 1 { return false }
        return true
    }

    /// Routes a pick of a declared radio channel into Radio Mode. Returns
    /// false when the caller should play it normally.
    static func openIfDeclared(_ item: ChannelDisplayItem, server: ServerConnection?) -> Bool {
        guard shouldAutoOpen(for: item) else { return false }
        debugLog("[RADIO] \(item.isRadio ? "declared radio channel" : "Radio Mode by Default") \(item.name): opening Radio Mode")
        shared.start(item: item, server: server)
        return true
    }

    // MARK: Admin radio flag (Dispatcharr Direct Connect)

    /// "Mark as Radio Channel" / "Unmark Radio Channel" for an admin on a
    /// Dispatcharr Direct Connect playlist; nil hides the item (M3U, XC,
    /// non-admin, or a permission snapshot not loaded yet).
    static func radioFlagMenuTitle(for item: ChannelDisplayItem) -> String? {
        guard let server = ChannelStore.shared.activeServer,
              server.type == .dispatcharrAPI, server.dispatcharrCanSwitchStream,
              item.dispatcharrChannelID != nil else { return nil }
        return item.isRadio ? "Unmark Radio Channel" : "Mark as Radio Channel"
    }
    static let radioFlagMenuSymbol = "dot.radiowaves.left.and.right"

    static func radioFlagMenuAction(for item: ChannelDisplayItem) {
        guard let channelID = item.dispatcharrChannelID,
              let api = SwitchStreamFlow.makeAPI(server: ChannelStore.shared.activeServer) else { return }
        let target = !item.isRadio
        Task { @MainActor in
            do {
                let code = try await api.updateChannelRadioFlag(channelID: channelID, isRadio: target)
                debugLog("[DISPATCHARR] is_radio -> \(target) channel=\(item.name) status=\(code)")
                ChannelStore.shared.setRadioFlag(channelID: item.id, isRadio: target)
                NotificationCenter.default.post(
                    name: .aerioChannelListToast, object: nil,
                    userInfo: ["message": target ? "Marked as a radio channel" : "Radio channel mark removed"])
            } catch {
                let status = SwitchStreamView.httpStatus(of: error)
                debugLog("[DISPATCHARR] is_radio -> \(target) channel=\(item.name) status=\(status.map(String.init) ?? "none") error=\(error.localizedDescription)")
                let message = status == 403 || status == 401
                    ? "You do not have permission to change this channel."
                    : "Could not update the channel. Try again."
                NotificationCenter.default.post(name: .aerioChannelListToast, object: nil,
                                                userInfo: ["message": message])
            }
        }
    }

    /// The one live tile currently playing, when the session is a plain
    /// single live channel (not a Multiview grid, VOD, DVR or catch-up).
    private static var soleLiveTile: MultiviewTile? {
        let store = MultiviewStore.shared
        guard PlayerSession.shared.mode == .multiview, store.tiles.count == 1,
              let t = store.tiles.first, t.kind == .live else { return nil }
        return t
    }

    /// Player options "Radio Mode": the playing channel goes audio only.
    static var canEnterFromPlayer: Bool {
        isAvailable && !shared.isActive && soleLiveTile != nil
    }

    /// Long-press "Radio Mode" on a channel: play it as radio. Re-uses the
    /// playing tile when it is already this channel; otherwise tunes it
    /// (minimized, so the video player never opens).
    func start(item: ChannelDisplayItem, server: ServerConnection?) {
        guard Self.isAvailable else { return }
        if let t = Self.soleLiveTile, t.item.id == item.id {
            enterFromPlayer()
            return
        }
        if isActive {
            switchTo(item: item, server: server)
            return
        }
        // A grid or a non-live session is replaced, like any channel pick.
        if PlayerSession.shared.mode == .multiview, Self.soleLiveTile == nil {
            PlayerSession.shared.stop()
        }
        switching = true
        isActive = true
        debugLog("[RADIO] start \(item.name)")
        NotificationCenter.default.post(name: .radioModeDidStart, object: nil)
        NowPlayingManager.shared.requestStartMinimized()
        _ = PlayerSession.shared.begin(item: item, server: server)
        settleAfterTune()
    }

    /// From the player's options: keep the audio, hide the video.
    func enterFromPlayer() {
        guard Self.isAvailable, let t = Self.soleLiveTile else { return }
        isActive = true
        debugLog("[RADIO] start \(t.item.name)")
        NotificationCenter.default.post(name: .radioModeDidStart, object: nil)
        #if os(iOS)
        AppOrientationLock.release(reason: "radio mode")
        #endif
        // The state half of minimize: never the iPhone PiP hop.
        NowPlayingManager.shared.applyMinimized()
        publishNowPlaying()
        #if os(tvOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .forceGuideFocus, object: nil)
        }
        #endif
    }

    /// A channel picked in Radio Mode (guide, list, channel up/down)
    /// switches the audio; PlayerSession.begin routes here first.
    func noteSwitch(to item: ChannelDisplayItem) {
        guard isActive else { return }
        switching = true
        let src = pendingSwitchSource.map { " (\($0))" } ?? ""
        pendingSwitchSource = nil
        debugLog("[RADIO] switch -> \(item.name)\(src)")
        NowPlayingManager.shared.requestStartMinimized()
        settleAfterTune()
    }

    /// Sheet Channel Up / Down: the same in-place switch a guide pick uses
    /// in Radio Mode (begin's swap path), never the video player's flip.
    func step(_ direction: Int) {
        guard isActive, let ch = channel else { return }
        let list = ChannelStore.shared.channels
        guard let idx = list.firstIndex(where: { $0.id == ch.id }) else { return }
        let next = max(0, min(list.count - 1, idx + direction))
        guard next != idx else { return }
        pendingSwitchSource = "sheet"
        switchTo(item: list[next], server: ChannelStore.shared.activeServer)
    }

    private func switchTo(item: ChannelDisplayItem, server: ServerConnection?) {
        // begin() takes the swap-from-mini path and calls noteSwitch.
        _ = PlayerSession.shared.begin(item: item, server: server)
        NotificationCenter.default.post(name: .radioModeDidStart, object: nil)
    }

    private func settleAfterTune() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.switching = false
            // The tune ended up expanded or never started: not radio.
            if self.isActive, PlayerSession.shared.mode == .idle {
                self.clear(reason: "tune did not start")
            } else if self.isActive, !NowPlayingManager.shared.isMinimized {
                NowPlayingManager.shared.applyMinimized()
            }
            if self.isActive { self.publishNowPlaying() }
        }
    }

    /// Card tap / "Exit Radio Mode": back to the full player with video,
    /// same tile, no re-tune.
    func returnToVideo() {
        guard isActive else { return }
        // A Radio Mode tune cut audio-only over a PMT that declares video:
        // that item has no video track, so the tile restarts as a video
        // program instead of re-attaching the surface.
        let restartAsVideo = AudioOnlyTuneIntent.shared.requestedCutActive
        #if os(iOS)
        // iPad 2026-10-13: the sink's reattach ran inside the expand's
        // SwiftUI update (258 ms, AVKit in the stack). Expand first, then
        // reattach on a later runloop turn, outside the transaction.
        let player = radioPlayer
        suppressReattach = true
        surfaceTimer?.invalidate()
        surfaceTimer = nil
        detachedItem = nil
        #endif
        isActive = false
        debugLog("[RADIO] stop (return to video)")
        #if os(iOS)
        reattachLayer()
        #endif
        withAnimation(.spring(response: 0.35)) { NowPlayingManager.shared.expand() }
        if restartAsVideo {
            AudioOnlyTuneIntent.shared.setRequestedCutActive(false)
            debugLog("[RADIO] video mode: restarting remuxer as video program")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .aerioRadioRestartAsVideo, object: nil)
            }
            return
        }
        #if os(iOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            debugLog("[RADIO] reattach after expand (video mode)")
            RadioModeSession.shared.reattachVideoSurface(player: player)
        }
        #endif
    }

    // MARK: Transport + Now Playing

    var isPaused: Bool { MultiviewStore.shared.audioProgressStore?.isPaused ?? false }

    // MARK: Failed stream (Channel Unavailable)

    /// The tile's live stream failed. Only the radio tile counts.
    func noteTileFailure(tileID: String, message: String) {
        guard isActive, MultiviewStore.shared.audioTileID == tileID else { return }
        let first = failureMessage == nil
        failureMessage = message
        if first { debugLog("[RADIO] channel unavailable \(channel?.name ?? "?")") }
        armRetry()
        if first { publishNowPlaying() }
    }

    /// The tile played again (first frame) or tuned another channel.
    func noteTileFailureCleared(tileID: String, why: String) {
        guard failureMessage != nil else { return }
        guard !isActive || MultiviewStore.shared.audioTileID == tileID else { return }
        clearFailure()
        debugLog("[RADIO] recovered \(channel?.name ?? "?") (\(why))")
        publishNowPlaying()
    }

    private func clearFailure() {
        retryTask?.cancel()
        retryTask = nil
        retryCountdown = 0
        failureMessage = nil
    }

    /// The player's flat 5 s cadence, then one fresh tune.
    private func armRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            var remaining = PlaybackFailureCopy.retryInterval
            while remaining > 0 {
                self?.retryCountdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
            }
            self?.retryNow(source: "auto")
        }
    }

    /// Retry Now (card, sheet, banner, lock screen Play).
    func retryNow(source: String = "Retry Now") {
        guard isFailed else { return }
        retryTask?.cancel()
        retryTask = nil
        retryCountdown = 0
        debugLog("[RADIO] retry \(channel?.name ?? "?") (\(source))")
        MultiviewStore.shared.audioProgressStore?.liveFailureRetryAction?()
    }

    /// Radio Mode came on over a tile that is already failing.
    private func adoptTileFailure() {
        guard isActive, failureMessage == nil,
              let msg = MultiviewStore.shared.audioProgressStore?.liveFailureMessage else { return }
        failureMessage = msg
        debugLog("[RADIO] channel unavailable \(channel?.name ?? "?")")
        armRetry()
    }

    func togglePause() {
        // Play / Pause is off while the stream is unavailable.
        guard !isFailed else { return }
        MultiviewStore.shared.audioProgressStore?.userTogglePause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.publishPlaybackRate() }
    }

    private func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        togglePause()
    }

    /// Now Playing play / pause / toggle. iOS and iPadOS: pause and resume
    /// (the lock screen). Apple TV: the Siri Remote Play/Pause is delivered
    /// to this command while a Now Playing session is up, never to the
    /// guide's key handler, so in the foreground it is the banner's Switch
    /// to Video Mode.
    func handlePlayPauseCommand(pause: Bool) {
        #if os(tvOS)
        if UIApplication.shared.applicationState == .active {
            debugLog("[RADIO] play/pause command -> switch to video")
            returnToVideo()
            return
        }
        #endif
        if isFailed { retryNow(source: "lock screen"); return }
        setPaused(pause)
    }

    private func publishPlaybackRate() {
        guard isActive else { return }
        NowPlayingBridge.shared.updateElapsed(0, rate: (isPaused || isFailed || isBuffering) ? 0 : 1)
    }

    /// Lock screen / Control Center for Radio Mode. The AVPlayer tile path
    /// never configures NowPlayingBridge (only mpv, Cast, CarPlay and the
    /// Remote do), which is why the lock screen card was empty with dead
    /// Play / Pause. Live stream: no elapsed, no duration.
    /// Last published (channel, program) so the 1 s tick republishes only
    /// on a real change (program rollover in the guide, channel switch).
    private var publishedNowPlayingKey: String?

    /// The now-airing program title and episode subtitle for the radio channel.
    private func nowAiringLines(_ ch: ChannelDisplayItem) -> (title: String?, sub: String?) {
        #if os(iOS)
        let live = GuideStore.shared.liveProgram(for: ch.id)
        let title = RemoteSessionSheet.nowAiring(channelID: ch.id)?.title
            ?? live?.title ?? ch.currentProgram
        #else
        let live = GuideStore.shared.liveProgram(for: ch.id)
        let title = live?.title ?? ch.currentProgram
        #endif
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = live?.subTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ((t?.isEmpty == false) ? t : nil, (sub?.isEmpty == false) ? sub : nil)
    }

    private func publishNowPlaying() {
        guard isActive, let ch = channel else { return }
        let lines = nowAiringLines(ch)
        let failed = isFailed
        let buffering = isBuffering && !failed
        publishedNowPlayingKey = "\(ch.id)|\(lines.title ?? "")|\(lines.sub ?? "")|\(failed)|\(buffering)"
        // Title = channel, subtitle (artist) = program, album = the
        // program's episode subtitle. Live stream: the LIVE bar, no times.
        NowPlayingBridge.shared.configure(
            title: ch.name,
            // Failed stream: the player's wording, never the program as if
            // it were playing.
            subtitle: failed ? PlaybackFailureCopy.title : (buffering ? "Buffering" : (lines.title ?? "AerioTV")),
            artworkURL: ch.logoURL,
            duration: nil,
            isLive: true,
            onPlay: { RadioModeSession.shared.handlePlayPauseCommand(pause: false) },
            onPause: { RadioModeSession.shared.handlePlayPauseCommand(pause: true) },
            onSeek: nil,
            programLine: failed ? nil : lines.sub
        )
        #if os(iOS)
        // iOS draws Stop in the center when it is the only enabled
        // transport command it sees; keep Stop registered but make sure
        // Play / Pause / Toggle are enabled so the center is Pause / Play.
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        #endif
        publishPlaybackRate()
        debugLog("[RADIO] now playing -> \(ch.name) | \(failed ? PlaybackFailureCopy.title : (lines.title ?? "AerioTV"))")
    }

    /// 1 s tick: republish when the program (or channel) changed.
    private func refreshNowPlayingIfChanged() {
        guard isActive, let ch = channel else { return }
        let lines = nowAiringLines(ch)
        let key = "\(ch.id)|\(lines.title ?? "")|\(lines.sub ?? "")|\(isFailed)|\(isBuffering && !isFailed)"
        if key != publishedNowPlayingKey { publishNowPlaying() }
    }

    /// Card Stop: end Radio Mode and the audio.
    func stop(reason: String = "stop") {
        guard isActive else { return }
        #if os(iOS)
        // iPhone 2026-10-13: re-enabling the video track on the stop path
        // blocked the main thread 822 to 909 ms inside a SwiftUI update.
        // iPad 2026-10-13 23:09:22 (Kept Live on): the stop still blocked
        // 939 ms. isActive went false BEFORE the teardown, so the hidden
        // docked container turned visible and the store reset's epoch bump
        // re-ran the tile's task while the tile animated out for 0.9 s; the
        // deferred reattach then re-enabled video and seeked a player Kept
        // Live had already released (remux retention keeps the remuxer, not
        // the AVPlayer). Now: tear the session down first, while the host
        // is still hidden, with no animation, then end Radio Mode. Nothing
        // reattaches or seeks on stop; a direct-HLS player Kept Live holds
        // gets its video back when a tile adopts it.
        suppressReattach = true
        surfaceTimer?.invalidate()
        surfaceTimer = nil
        detachedItem = nil
        #endif
        debugLog("[RADIO] stop (\(reason))")
        RadioStopTrace.begin()
        #if os(iOS)
        // iPad 2026-10-13 23:32:33: SwiftUI still updated the radio tile
        // once after the reset (stale tile in the same update), and with
        // isActive false its layer host re-attached the player (a
        // synchronous AVFoundation attach) and armed PiP. The tile's player
        // stays held (no surface, no PiP) until the tile is gone.
        stoppingPlayer = radioPlayer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            RadioModeSession.shared.stoppingPlayer = nil
        }
        #endif
        NowPlayingBridge.shared.teardown()
        let started = Date()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            PlayerSession.shared.stop()
            isActive = false
        }
        #if os(iOS)
        reattachLayer()
        #endif
        debugLog("[RADIO] stop teardown \(Int(Date().timeIntervalSince(started) * 1000))ms (no reattach, no seek)")
        // tvOS guide focus restore (EPGGuideView), every stop reason.
        NotificationCenter.default.post(name: .radioModeDidStop, object: nil, userInfo: ["reason": reason])
    }

    private func clear(reason: String) {
        guard isActive else { return }
        isActive = false
        debugLog("[RADIO] stop (\(reason))")
        if AudioOnlyTuneIntent.shared.requestedCutActive {
            // Same as Switch to Video Mode: a tile still playing a Radio
            // Mode audio-only cut of a video channel restarts as video.
            AudioOnlyTuneIntent.shared.setRequestedCutActive(false)
            if PlayerSession.shared.mode != .idle {
                debugLog("[RADIO] video mode: restarting remuxer as video program")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .aerioRadioRestartAsVideo, object: nil)
                }
            }
        }
        #if os(iOS)
        reattachLayer()
        #endif
    }

    #if os(iOS)
    // MARK: No video surface (iPhone 2026-10-13: PiP flashed on app switch)

    private var surfaceTimer: Timer?
    private weak var detachedItem: AVPlayerItem?

    /// True when `player` is the radio tile's player, or the player of a
    /// radio tile being torn down by a card / sheet Stop.
    func ownsPlayer(_ player: AVPlayer) -> Bool {
        (isActive && radioPlayer === player) || (stoppingPlayer != nil && stoppingPlayer === player)
    }

    /// The radio tile's player while a Stop tears its tile down.
    private weak var stoppingPlayer: AVPlayer?

    /// While Radio Mode is on: the tile's layer shows nothing and the
    /// item's video track is disabled, so nothing decodes or can be
    /// handed to PiP. Re-applied every second so a channel switch (new
    /// item, tracks arriving late) comes up with video off too.
    private func enforceNoVideoSurface() {
        guard let player = radioPlayer else { return }
        if let layer = AVPlayerDisplayLayerRegistry.layer(for: player), layer.player != nil {
            layer.player = nil
        }
        guard let item = player.currentItem else { return }
        let video = item.tracks.filter { $0.assetTrack?.mediaType == .video }
        guard !video.isEmpty else { return }
        var changed = false
        for t in video where t.isEnabled { t.isEnabled = false; changed = true }
        if changed || detachedItem !== item {
            detachedItem = item
            debugLog("[RADIO] video surface detached (video tracks=\(video.count))")
        }
    }

    private func startSurfaceEnforcement() {
        surfaceTimer?.invalidate()
        enforceNoVideoSurface()
        surfaceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                RadioModeSession.shared.enforceNoVideoSurface()
                RadioModeSession.shared.refreshNowPlayingIfChanged()
            }
        }
    }

    /// Switch to Video Mode (and any end of Radio Mode): video track on,
    /// layer back on the player. PiP comes back via the tile's coordinator.
    private func reattachVideoSurface(player: AVPlayer?) {
        surfaceTimer?.invalidate()
        surfaceTimer = nil
        detachedItem = nil
        guard let player else { return }
        player.currentItem?.tracks
            .filter { $0.assetTrack?.mediaType == .video }
            .forEach { $0.isEnabled = true }
        let layer = AVPlayerDisplayLayerRegistry.layer(for: player)
        if let layer, layer.player == nil {
            layer.player = player
        }
        debugLog("[RADIO] video surface reattached")
        // iPad 2026-10-13: a re-enabled video track on a playing item came
        // back lazily, 10 to 19 s of black. Seek to the current time (exact)
        // so decode restarts now from the preceding keyframe; inside the
        // buffer this is near instant. Spinner on the tile until ready.
        guard let item = player.currentItem else { return }
        let now = player.currentTime()
        let started = Date()
        videoWarmingPlayer = player
        debugLog(String(format: "[RADIO] video kick: seek to %.1fs", now.seconds))
        player.seek(to: now, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        guard let layer else { return }
        readyObservation?.invalidate()
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
            guard l.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                debugLog("[RADIO] video ready \(Int(Date().timeIntervalSince(started) * 1000))ms after kick")
                self.readyObservation?.invalidate()
                self.readyObservation = nil
                if self.videoWarmingPlayer === player { self.videoWarmingPlayer = nil }
            }
        }
        // Never leave the spinner up forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.videoWarmingPlayer === player else { return }
            debugLog("[RADIO] video not ready 15 s after kick; spinner cleared item=\(item.status.rawValue)")
            self.videoWarmingPlayer = nil
            self.readyObservation?.invalidate()
            self.readyObservation = nil
        }
    }

    /// The player whose video is coming back after Radio Mode (spinner).
    @Published private(set) var videoWarmingPlayer: AVPlayer?
    private var readyObservation: NSKeyValueObservation?

    // MARK: Remote session sheet transport (same controls as AirPlay)

    private var radioPlayer: AVPlayer? {
        guard isActive, let id = MultiviewStore.shared.audioTileID else { return nil }
        return MultiviewCompositeTaps.shared.player(tileID: id)
    }

    /// The live rewind window the tile's playlist advertises (nil when the
    /// channel has no seekable range: the sheet then shows the read-only
    /// program bar, as Cast does for plain live).
    func remoteSeekWindow() -> RemoteSeekWindow? {
        guard let player = radioPlayer, let item = player.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let lo = range.start.seconds, hi = range.end.seconds
        let pos = player.currentTime().seconds
        guard lo.isFinite, hi.isFinite, pos.isFinite, hi - lo >= 1 else { return nil }
        return RemoteSeekWindow(start: lo, end: hi, position: min(max(pos, lo), hi),
                                isLive: !item.duration.seconds.isFinite)
    }

    func seek(by seconds: Double) {
        guard let player = radioPlayer else { return }
        seek(to: player.currentTime().seconds + seconds)
    }

    func seek(to seconds: Double) {
        guard let player = radioPlayer, let item = player.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let lo = range.start.seconds, hi = range.end.seconds
        guard lo.isFinite, hi.isFinite, seconds.isFinite else { return }
        // Never closer than 1 s to the edge (same as the player's skip).
        let target = min(max(seconds, lo), max(lo, hi - 1))
        debugLog("[RADIO] seek to \(Int(target))s (window \(Int(lo))-\(Int(hi)))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Called by the tile when the app goes to the background: true means
    /// Radio Mode owns this tile and it must keep playing (skip quiesce).
    func keepsPlayingInBackground(tileID: String, player: AVPlayer?) -> Bool {
        guard isActive, MultiviewStore.shared.audioTileID == tileID else { return false }
        guard let player else {
            debugLog("[RADIO] background keepalive lost (no AVPlayer on the tile)")
            return false
        }
        // The layer is already detached and the video track off for the
        // whole of Radio Mode (enforceNoVideoSurface).
        enforceNoVideoSurface()
        detachedPlayer = player
        if player.rate == 0 { player.play() }
        debugLog("[RADIO] background keepalive ok (rate=\(player.rate))")
        return true
    }

    private func didEnterBackground() {
        guard isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.isActive, UIApplication.shared.applicationState == .background else { return }
            let playing = (self.detachedPlayer?.rate ?? 0) > 0
            debugLog("[RADIO] background keepalive \(playing ? "ok" : "lost") (2 s after background)")
        }
    }

    private func willEnterForeground() {
        // Still Radio Mode: the surface stays detached.
        if isActive { enforceNoVideoSurface() }
    }

    private func reattachLayer() {
        // The $isActive sink reattaches on every end of Radio Mode.
        detachedPlayer = nil
    }
    #endif
}

extension Notification.Name {
    /// Radio Mode started (any path): the tvOS guide stores the origin cell.
    static let radioModeDidStart = Notification.Name("radioModeDidStart")
    /// Radio Mode stopped; userInfo["reason"] is the stop reason. The tvOS
    /// guide restores focus to the stored origin cell.
    static let radioModeDidStop = Notification.Name("radioModeDidStop")
}
