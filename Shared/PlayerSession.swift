import Foundation
import SwiftUI

/// Top-level playback-mode arbiter.
///
/// `NowPlayingManager.shared` is single-stream by design — it tracks
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
    ///   channel so CarPlay / lockscreen keep working — the bridge
    ///   gating in Phase 1d routes remote commands to whichever tile
    ///   holds audio.
    func enterMultiview(seeding current: ChannelDisplayItem?, server: ServerConnection?) {
        // Refcount float. SwiftUI's swap from the old single
        // `PlayerView` to `MultiviewContainerView` happens across one
        // (or more) render passes; the ordering of unmount-old vs
        // mount-new is implementation-defined. If unmount runs first
        // the audio-session refcount hits 0, triggering
        // `setActive(false) → setActive(true)` on the next mount —
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

        if let current {
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

    /// Exit multiview. If the user wants to keep watching the audio
    /// tile's channel as a single stream, the caller (`HomeView`)
    /// re-seeds `NowPlayingManager` from the audio tile before
    /// transitioning; otherwise we land back on `.idle`.
    func exitMultiviewKeepingAudioTile() {
        // The audio tile's channel stays as the single-stream
        // currently-playing item. NowPlayingManager is already
        // populated with the seed channel from `enterMultiview`,
        // so if the audio tile IS the seed tile we don't need to
        // touch NowPlayingManager. If the audio tile is a
        // subsequently-added one, HomeView's branch-on-mode view
        // will re-seed it as part of the transition (Phase 4).
        MultiviewStore.shared.reset()
        mode = .single
        // NowPlayingManager is authoritative again.
        NowPlayingManager.shared.configuredAsMultiviewAdapter = false
        DebugLogger.shared.log(
            "[MV-Mode] exit→single (keep audio tile)",
            category: "Playback", level: .info
        )
    }

    /// Exit multiview AND stop playback entirely. Tears down the
    /// tile list (which dismantles each tile's MPVPlayerView and
    /// thus each mpv handle) and returns to `.idle`. Called by the
    /// transport bar's "Exit Multiview" button when the user wants
    /// to stop watching, not just collapse to one stream.
    func exit() {
        MultiviewStore.shared.reset()
        mode = .idle
        NowPlayingManager.shared.configuredAsMultiviewAdapter = false
        // Explicit bridge teardown: during multiview, the audio tile's
        // coordinator was driving MPNowPlayingInfoCenter. After
        // `MultiviewStore.reset()` that coordinator will dismantle,
        // but its own `stop()`-driven teardown gate now returns `false`
        // (mode just flipped to .idle, tileID != nil), so it won't
        // clear the center. Do it here so the lockscreen doesn't show
        // a ghost entry after "Exit Multiview".
        NowPlayingBridge.shared.teardown()
        // Clear single-stream state too. HomeView's mode branch is
        // `if .multiview { … } else if nowPlaying.isActive { single
        // PlayerView }` — without this clear, the else-if revives
        // single-stream playback of the seed channel after the user
        // tapped "Exit Multiview", which is the opposite of what the
        // button says. Stopping NowPlayingManager lets HomeView fall
        // through to the Live-TV guide / empty state.
        NowPlayingManager.shared.stop()
        DebugLogger.shared.log(
            "[MV-Mode] exit→idle (full teardown)",
            category: "Playback", level: .info
        )
    }

    /// Enter `.single` mode. No-op if already there. Doesn't touch
    /// `NowPlayingManager` — the caller is expected to have set up
    /// the single-stream playing item before or after this call.
    func beginSingle() {
        mode = .single
    }

    /// Return to `.idle`. Called when the user dismisses the single
    /// player (PlayerView's exit button / swipe-down). Doesn't
    /// touch `NowPlayingManager` — `NowPlayingManager.stop()`
    /// clears its own state.
    func endSingle() {
        if mode == .single { mode = .idle }
    }
}
