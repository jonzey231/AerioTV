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

    /// Exit multiview and continue playing the audio tile's channel
    /// as a regular single-stream. This is what the "Exit" button
    /// in the transport bar calls — after a multiview session the
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
    func exitMultiviewKeepingAudioTile() {
        let store = MultiviewStore.shared
        // Capture the audio tile BEFORE we reset the store.
        let audioTile = store.tiles.first { $0.id == store.audioTileID }

        guard let audioTile else {
            // No audio tile means no channel to fall back to — do a
            // full teardown instead of leaving stale state behind.
            exit()
            return
        }

        // Unified-playback path: keep the audio tile as the sole
        // remaining tile and stay in `PlaybackContainerView`. Mode
        // stays `.multiview` even at N=1 because that's the whole
        // point of the unified view — single-stream IS just
        // N=1 multiview. This preserves the `+` / Add Stream pill in
        // the N=1 chrome so the user can re-enter N>=2 without a
        // full teardown + channel re-resolve. Previously this path
        // always flipped to `.single` + swapped to `PlayerView`,
        // which left the user with no way to add another stream
        // except by exiting all the way to the guide and starting
        // over — exactly the "no way to reuse multiview" pain point.
        if PlaybackFeatureFlags.useUnifiedPlayback {
            // Remove every tile except the audio tile — one mpv
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
    func exit() {
        // v1.6.18: capture the audio tile's channel id BEFORE we
        // reset the store. NowPlayingManager.lastPlayedChannelID is
        // the persistent breadcrumb the Live TV guide reads for its
        // default-focused row — without this capture, a full exit
        // from multiview clears playingItem AND wipes the audio
        // tile id from MultiviewStore in the same beat, leaving the
        // guide with no signal at all and falling back to row 0.
        // Capturing here keeps "exit multiview → guide lands on the
        // channel I was just listening to" as the consistent
        // behaviour. `startPlaying(...)` writes the same field on
        // single-stream entry, so this only matters on the
        // multiview-exit path.
        let store = MultiviewStore.shared
        if let audioID = store.audioTileID,
           let audioTile = store.tiles.first(where: { $0.id == audioID }) {
            NowPlayingManager.shared.lastPlayedChannelID = audioTile.item.id
        }
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

    // MARK: - Unified playback (Phase A skeleton)

    /// Unified playback entry point — eventually replaces every
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
    /// both cases. Callers don't need to change between phases —
    /// that's the point of routing through `begin(...)` now.
    ///
    /// Returns `false` if stream resolution failed (no playable
    /// URL, no active server, cap reached). Callers can surface an
    /// error toast on `false`. Returns `true` even when an identical
    /// channel is already playing — `add(...)` no-ops with
    /// `.alreadyPresent` which we treat as success from a
    /// "user clicked channel, they see playback happening" POV.
    @discardableResult
    func begin(item: ChannelDisplayItem,
               server: ServerConnection?,
               isLive: Bool = true) -> Bool {
        let store = MultiviewStore.shared

        // Gate at the cap — `add(...)` will reject past `maxTiles` but
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

        // Special case: user picks a channel from the guide while
        // the mini is up (N=1 + minimized). Expected UX is "swap the
        // mini's stream to the new channel", NOT "append a second
        // tile and turn the mini into a tiny 2-grid". Achieve this
        // with a full teardown + fresh seed — the MultiviewContainer
        // stays mounted (HomeView's `.multiview` branch is driven
        // by `mode`, which stays `.multiview` across the reseed)
        // but the tile's mpv handle is swapped.
        if NowPlayingManager.shared.isMinimized && store.tiles.count == 1 {
            DebugLogger.shared.log(
                "[MV-Mode] begin(swap-from-mini): \(item.name)",
                category: "Playback", level: .info
            )
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
            // Fresh session — delegate to the existing seed-tile path.
            // This ALSO mirrors into `NowPlayingManager.startPlaying`
            // so CarPlay / MPRemoteCommandCenter / lockscreen get
            // populated, and flips `mode = .multiview`. Phase C will
            // change this to `mode = .playing` + a direct seed call.
            enterMultiview(seeding: item, server: server)
            // `NowPlayingManager.startPlaying` isn't called by
            // `enterMultiview` — the original single-mode path did it
            // on the PlayerView mount. Callers under the feature flag
            // are skipping the `.single` path entirely, so do the
            // mirror here. The bridge gating keeps the lockscreen
            // pointed at the audio tile regardless.
            //
            // Header fallback matches `ChannelListView.playerHeaders()`
            // semantics — if `server` resolves but has no custom auth
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
            // Already playing — add as another tile.
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
                // as implicit consent — they already tapped to play.
                _ = store.add(item, server: server, bypassWarning: true)
                return true
            case .rejectedMax, .unresolvable:
                return false
            }
        }
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
/// as of Phase D — the unified `PlayerSession.begin(...)` +
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
enum PlaybackFeatureFlags {
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
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "playback.unified") == nil {
            return true
        }
        return defaults.bool(forKey: "playback.unified")
    }
}
