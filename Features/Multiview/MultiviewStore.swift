import Foundation
import SwiftUI

// MARK: - User-configurable multiview appearance
//
// v1.6.8: three new prefs surfaced in `Settings → Multiview`:
//   • Audio Focus Indicator — how the active-audio tile is marked.
//   • Padding Between Tiles — flush-meeting tiles vs. small gaps.
//   • Tile Corners            — square-edge tiles vs. rounded.
//
// Defaults preserve pre-v1.6.8 behaviour (`.centerIcon`, no padding,
// square corners) so existing users see no visual change unless they
// opt into one. Storage keys are `@AppStorage`-driven across the
// multiview views so a user toggling a setting sees the change live
// without leaving Settings.

/// How the audio-active tile is highlighted in multiview.
///
/// • `centerIcon` (default, pre-v1.6.8 behaviour) — a speaker icon
///   in the centre of the active tile fades in / out with the rest
///   of the tile chrome.
/// • `grayPersistent` — a muted gray border around the active tile
///   that's always visible, regardless of chrome auto-hide state.
/// • `themeFading` — an accent-colored border that rides the
///   existing 5-second focus-indicator auto-hide, so it appears
///   when the user is interacting with the grid and fades when
///   they're just watching.
enum MultiviewAudioFocusStyle: String, CaseIterable, Identifiable, Sendable {
    case centerIcon
    case grayPersistent
    case themeFading

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .centerIcon:     return "Center Icon"
        case .grayPersistent: return "Gray Outline"
        case .themeFading:    return "Accent Outline (Fading)"
        }
    }

    var subtitle: String {
        switch self {
        case .centerIcon:     return "A speaker icon shows in the center of the active tile."
        case .grayPersistent: return "A muted gray border around the active tile, always visible."
        case .themeFading:    return "An accent-colored border that fades after 5 seconds of inactivity."
        }
    }

    /// Storage key used by `@AppStorage` everywhere in the multiview
    /// views. Centralised here so the views and the Settings submenu
    /// reference the same string.
    static let storageKey = "multiviewAudioFocusStyle"
}

/// Storage key for the boolean "padding between tiles" preference.
/// `false` (default) keeps tiles meeting flush at edges (legacy);
/// `true` inserts an 8pt gap on every grid axis.
let multiviewTilePaddingKey = "multiviewTilePadding"

/// Storage key for the boolean "rounded tile corners" preference.
/// `false` (default) keeps the square-cornered shape that's been the
/// look since multiview shipped; `true` rounds every tile to 12pt.
let multiviewTileCornersRoundedKey = "multiviewTileCornersRounded"

/// Source of truth for the multiview grid's dynamic state:
/// the ordered tile list, which tile has audio, which tile (if any)
/// is temporarily promoted to full-screen-within-grid, the relocate
/// state for tvOS "Move Tile" mode, and the PiP-active flag that
/// tells non-audio tiles to pause.
///
/// Lives alongside `NowPlayingManager` (single-stream authority) and
/// is driven by `PlayerSession.mode`. When mode is `.multiview`, this
/// store is authoritative for everything playback-related; when mode
/// is `.single`, the store stays empty (we don't pay for tracking
/// tiles we're not showing).
///
/// All state mutations go through the public API below so ordering
/// invariants (e.g. "audio tile ID always references a tile in the
/// list" and "removing the audio tile auto-promotes the newest
/// remaining") stay enforced in one place.
@MainActor
final class MultiviewStore: ObservableObject {

    // MARK: - Singleton

    static let shared = MultiviewStore()
    private init() {}

    // MARK: - Limits

    /// Number of tiles above which adding more triggers the
    /// performance-warning confirmation. `softLimit + 1 == 5` is
    /// where the warning fires.
    let softLimit = 4

    /// Hard cap — the grid renders at most 3×3 = 9 tiles.
    let maxTiles = 9

    // MARK: - Published state

    /// Ordered tile list. Tile[0] is the first-seeded tile when
    /// entering multiview from single playback. New tiles append at
    /// the end. Drag-rearrange reorders this list in place, which is
    /// what drives the visual shuffle via `.animation(value: tiles)`.
    @Published private(set) var tiles: [MultiviewTile] = []

    /// Which tile currently owns audio. Exactly one tile is unmuted
    /// at any time during multiview (binary model, not a mix). The
    /// store enforces this invariant: on `add(...)` the new tile
    /// takes audio; on `remove(...)` of the audio tile, audio
    /// auto-promotes to the newest remaining tile.
    @Published var audioTileID: String?

    /// If non-nil, the grid renders this single tile at full size
    /// and hides the rest. Set by the per-tile "Full Screen" menu
    /// action; cleared by the Menu button / an Esc key. Does NOT
    /// exit multiview — exiting fullscreen brings the grid back.
    @Published var fullscreenTileID: String?

    /// tvOS relocate mode: when non-nil, the container's D-pad
    /// remap kicks in so arrow keys swap `relocatingTileID` with
    /// its neighbor at the pressed direction. Click commits
    /// (clears this to nil), Menu cancels. On iPadOS this stays nil
    /// — iPad uses `.onDrag`/`.onDrop` instead.
    @Published var relocatingTileID: String?

    /// Set to `true` when `AVPictureInPictureController` on the audio
    /// tile engages PiP. Non-audio tiles observe this and call
    /// `mpv_set_property(handle, "pause", true)` so only the PiP
    /// window keeps decoding.
    @Published var isPiPActive: Bool = false

    /// Set to `true` while `AddToMultiviewSheet` is presented on tvOS
    /// at N=1. Pauses EVERY tile's mpv (including the audio tile) so
    /// the picker's channel-list rendering + image loading doesn't
    /// compete with live decode for memory. Observed OOMs at 1.8+ GB
    /// RSS on Apple TV 4K when the picker was up over a playing tile
    /// for more than a few seconds; pausing frees the videotoolbox
    /// decode surface + IOSurface texture pool so the picker has
    /// headroom. Resumes on sheet dismissal (pick or cancel).
    ///
    /// `MPVPlayerView.Coordinator.applyPauseIfChanged(...)` already
    /// handles property-toggle semantics correctly — toggling this
    /// flag translates to a single `mpv_set_property(pause, true/false)`
    /// per tile, not a re-seed.
    @Published var isPickerPresented: Bool = false

    /// Latest `ProcessInfo.thermalState` the app has observed. Kept
    /// in the store (not computed live) so the add-sheet's
    /// `.critical`-refusal banner flips promptly on the
    /// `thermalStateDidChangeNotification` without every observer
    /// having to subscribe separately. Phase 7 wires a single
    /// subscriber in `MultiviewContainerView.task { ... }` that
    /// updates this on change.
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    /// Convenience: `true` when the device is reporting `.critical`
    /// thermal state. The add-sheet / transport bar use this to
    /// surface a "too hot to add more streams" banner without
    /// re-asking `ProcessInfo` every render pass. `.serious` is
    /// intentionally NOT blocking — per the plan, `.serious` is a
    /// soft warning (we already show the perf-warning alert at tile
    /// 5+) and only `.critical` refuses new adds. If the heuristic
    /// ever widens to include `.serious`, update the comment on
    /// `AddToMultiviewSheet.tryAdd` too.
    var isThermallyStressed: Bool {
        thermalState == .critical
    }

    /// Timestamp of the last time the "performance may degrade"
    /// confirmation was shown. The warning re-fires after 2h so a
    /// cool-iPad user who saw it at home gets warned again after the
    /// device has been in a bag all day.
    var warningLastShownAt: Date?

    // MARK: - Progress-store registry
    //
    // The unified N=1 chrome (PlaybackChromeOverlay + PlaybackOptionsPanel)
    // needs to bind scrubber / play-pause / track pickers / speed /
    // sleep timer to *the audio tile's* `PlayerProgressStore`. Each
    // tile's `MultiviewTileView` owns its own store as a
    // `@StateObject`; this registry lets the chrome look one up by
    // tile id without routing state through SwiftUI's environment.
    //
    // Entries are held by strong reference while the tile is mounted;
    // `MultiviewTileView.onAppear` calls `registerProgressStore(...)`,
    // `.onDisappear` calls `unregisterProgressStore(...)`. The
    // `.onDisappear` cleanup means the dictionary never holds a
    // reference to a torn-down tile. We don't weak-ref the store
    // because SwiftUI's `@StateObject` retains it for the view's
    // lifetime — a weak ref would just race ahead of onDisappear
    // without buying anything.
    //
    // The dictionary is NOT `@Published` — every tile mount / remount
    // would otherwise fire `objectWillChange` on `MultiviewStore`,
    // invalidating every chrome/tile view that observes the store.
    // Non-audio tile re-registration is a pure no-op for chrome state,
    // so we don't want to pay the invalidation cost. Instead, we bump
    // `audioProgressStoreRevision` *only* when the entry that
    // `audioProgressStore` resolves to has actually changed — which
    // is the only delta chrome observers care about.
    private var progressStoresByTileID: [String: PlayerProgressStore] = [:]

    /// Published revision counter that bumps whenever the result of
    /// `audioProgressStore` has changed (audio tile itself register,
    /// re-register, or unregister). Chrome observers can watch this
    /// in an `onChange` if they cache progress-store refs; the
    /// `audioTileID` change is already published separately and
    /// handles the most common case (swap audio between tiles).
    @Published private(set) var audioProgressStoreRevision: Int = 0

    /// Currently-audible tile's progress store. `nil` when there's
    /// no audio tile or the audio tile hasn't registered yet (brief
    /// window between tile mount and first SwiftUI body pass). The
    /// chrome overlay should gate its Options pill on non-nil.
    var audioProgressStore: PlayerProgressStore? {
        guard let id = audioTileID else { return nil }
        return progressStoresByTileID[id]
    }

    /// Called by `MultiviewTileView.onAppear`. Replaces any existing
    /// entry for this tile id (e.g. view re-render mid-session).
    /// Only fires `objectWillChange` when the registered tile is the
    /// audio tile — every other register is a quiet dictionary write.
    func registerProgressStore(_ store: PlayerProgressStore, for tileID: String) {
        let wasAudio = (audioTileID == tileID)
        let prior = progressStoresByTileID[tileID]
        progressStoresByTileID[tileID] = store
        if wasAudio && prior !== store {
            audioProgressStoreRevision &+= 1
        }
        debugLog("[MV-ProgressStore] register tileID=\(tileID) wasAudio=\(wasAudio) audioTileID=\(audioTileID ?? "nil") dictCount=\(progressStoresByTileID.count)")
    }

    /// Called by `MultiviewTileView.onDisappear` (and by `remove(id:)`
    /// / `reset()` below to cover cases where `onDisappear` races the
    /// store mutation). Bumps the revision only if the unregistered
    /// tile was the audio tile.
    func unregisterProgressStore(for tileID: String) {
        let wasAudio = (audioTileID == tileID)
        let had = progressStoresByTileID.removeValue(forKey: tileID) != nil
        if wasAudio && had {
            audioProgressStoreRevision &+= 1
        }
        debugLog("[MV-ProgressStore] unregister tileID=\(tileID) wasAudio=\(wasAudio) audioTileID=\(audioTileID ?? "nil") had=\(had) dictCount=\(progressStoresByTileID.count)")
    }

    /// Seconds during which the perf-warning stays "recently shown"
    /// and the soft-limit gate is auto-skipped. 2h matches the thermal
    /// recovery window documented in the plan's warning-scope section.
    private static let warningThrottleInterval: TimeInterval = 7_200

    /// `true` while we're inside the throttle window and should NOT
    /// re-fire the perf-warning on the next `add`. Reading this is
    /// always cheap and `Date` comparison is monotonic enough for the
    /// 2h grain.
    private var warningRecentlyShown: Bool {
        guard let last = warningLastShownAt else { return false }
        return Date().timeIntervalSince(last) < Self.warningThrottleInterval
    }

    // MARK: - Resolver

    /// Allowlist of URL schemes this app will hand to mpv. Anything
    /// outside this list is rejected as `.unresolvable` — without an
    /// explicit `protocol_whitelist` mpv will happily open `file://`,
    /// `udp://`, or other local/exotic schemes, which is a way for a
    /// malicious M3U or EPG entry to exfiltrate local files or probe
    /// LAN services. The app's real streams are always one of these
    /// five, so the allowlist costs nothing in practice.
    private static let allowedSchemes: Set<String> = [
        "http", "https", "rtmp", "rtmps", "rtsp"
    ]

    /// Turns a `ChannelDisplayItem` + active server into a playback
    /// URL + auth headers pair, or `nil` if the channel has no usable
    /// stream URL. Used by the channel picker when a user selects a
    /// channel to add to the grid.
    ///
    /// Header selection mirrors `Features/LiveTV/ChannelListView.swift`
    /// `playerHeaders()`: pick the server's `authHeaders`, fall back
    /// to `Accept: */*` when no server is configured (shouldn't happen
    /// at add-time but defensive).
    static func resolveStream(
        _ item: ChannelDisplayItem,
        server: ServerConnection?
    ) -> (url: URL, headers: [String: String])? {
        guard let url = item.streamURLs.first else { return nil }
        // Reject schemes outside the allowlist — see `allowedSchemes`
        // above for the full rationale. mpv would otherwise open
        // `file://` / `udp://` / etc.
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        let headers = server?.authHeaders ?? ["Accept": "*/*"]
        return (url, headers)
    }

    // MARK: - Add / Remove

    enum AddResult: Equatable {
        /// Tile added. Caller should proceed.
        case added

        /// Would push the tile count above `softLimit`. Caller should
        /// present the performance-warning alert; on Continue, call
        /// `add(...)` again with `bypassWarning: true`.
        case needsWarning

        /// At hard cap (`maxTiles`). Show a toast; no further action.
        case rejectedMax

        /// This channel is already a tile. No-op.
        case alreadyPresent

        /// `ChannelDisplayItem.streamURLs` was empty — can't build a
        /// playable URL. Show an error; probably a misconfigured
        /// channel on the server.
        case unresolvable
    }

    /// Add a tile. Returns an `AddResult` describing the outcome;
    /// the caller (channel picker sheet) is responsible for showing
    /// any UI (warning alert, toast) based on the result.
    ///
    /// - Parameters:
    ///   - item: The channel to add.
    ///   - server: The currently active server (for header resolution).
    ///   - bypassWarning: When `true`, skips the `needsWarning` check.
    ///     Caller sets this after the user confirms the perf warning.
    @discardableResult
    func add(
        _ item: ChannelDisplayItem,
        server: ServerConnection?,
        bypassWarning: Bool = false
    ) -> AddResult {
        // Dedup
        if tiles.contains(where: { $0.item.id == item.id }) {
            DebugLogger.shared.log(
                "[MV-Tile] add rejected: alreadyPresent id=\(item.id)",
                category: "Playback", level: .info
            )
            return .alreadyPresent
        }
        // Hard cap
        if tiles.count >= maxTiles {
            DebugLogger.shared.log(
                "[MV-Tile] add rejected: hardCap (count=\(tiles.count))",
                category: "Playback", level: .warning
            )
            return .rejectedMax
        }
        // Resolve stream
        guard let resolved = Self.resolveStream(item, server: server) else {
            // NOTE: never log `item.streamURLs` — XC URLs carry auth
            // credentials in the path. Name-only is safe.
            DebugLogger.shared.log(
                "[MV-Tile] add rejected: unresolvable channel=\(item.name)",
                category: "Playback", level: .warning
            )
            return .unresolvable
        }
        // Soft cap → caller shows warning, we don't commit yet.
        // Skipping straight to .added when the 2h window is still warm
        // matches the plan's "don't nag" rule.
        if !bypassWarning && tiles.count >= softLimit && !warningRecentlyShown {
            DebugLogger.shared.log(
                "[MV-Tile] add pending: needsWarning (count=\(tiles.count), softLimit=\(softLimit))",
                category: "Playback", level: .info
            )
            return .needsWarning
        }
        // Commit. `resolved.url` + `resolved.headers` are
        // DELIBERATELY NOT LOGGED — they contain auth credentials.
        let tile = MultiviewTile(
            id: UUID().uuidString,
            item: item,
            streamURL: resolved.url,
            headers: resolved.headers,
            addedAt: Date()
        )
        tiles.append(tile)
        // Last-added gets audio (matches the plan's default).
        audioTileID = tile.id
        DebugLogger.shared.log(
            "[MV-Tile] add ok: \(item.name) tileID=\(tile.id) total=\(tiles.count) bypassWarning=\(bypassWarning)",
            category: "Playback", level: .info
        )
        return .added
    }

    /// Seed the store with tile[0] from an already-playing single
    /// stream. Called by `PlayerSession.enterMultiview(seeding:)`.
    /// Uses `item.id` as the tile ID to pin SwiftUI identity so the
    /// existing `MPVPlayerView` Coordinator carries over without a
    /// reseed. See the plan's "coordinator reuse" note.
    func seedInitialTile(
        _ item: ChannelDisplayItem,
        server: ServerConnection?
    ) {
        guard tiles.isEmpty else { return }  // idempotent
        guard let resolved = Self.resolveStream(item, server: server) else { return }
        let tile = MultiviewTile(
            id: item.id,                     // pinned, not UUID
            item: item,
            streamURL: resolved.url,
            headers: resolved.headers,
            addedAt: Date()
        )
        tiles = [tile]
        audioTileID = tile.id
        DebugLogger.shared.log(
            "[MV-Tile] seed tile[0] from single: \(item.name) id=\(item.id)",
            category: "Playback", level: .info
        )
    }

    /// Remove the tile with the given id. If the removed tile held
    /// audio, promote the newest remaining tile to audio. If no
    /// tiles remain, audio goes nil (caller should exit multiview).
    func remove(id: String) {
        guard let idx = tiles.firstIndex(where: { $0.id == id }) else { return }
        let removedWasAudio = (audioTileID == id)
        tiles.remove(at: idx)
        DebugLogger.shared.log(
            "[MV-Tile] remove tileID=\(id) remaining=\(tiles.count)",
            category: "Playback", level: .info
        )
        if removedWasAudio {
            // Newest remaining (last in the list) — matches the
            // "last-added gets audio" default.
            audioTileID = tiles.last?.id
            DebugLogger.shared.log(
                "[MV-Focus] audio auto-promoted on remove: newAudio=\(audioTileID ?? "nil") removed=\(id)",
                category: "Playback", level: .info
            )
        }
        if fullscreenTileID == id {
            fullscreenTileID = nil
        }
        if relocatingTileID == id {
            relocatingTileID = nil
        }
    }

    /// Explicit audio-focus move. Used by the tap-to-take-audio
    /// gesture on each tile. No-op if `id` isn't in the list.
    func setAudio(to id: String) {
        guard tiles.contains(where: { $0.id == id }) else { return }
        let prev = audioTileID ?? "nil"
        audioTileID = id
        DebugLogger.shared.log(
            "[MV-Focus] setAudio from=\(prev) to=\(id)",
            category: "Playback", level: .info
        )
    }

    // MARK: - Rearrange

    /// Swap two tiles by id. Used by both iPadOS `.onDrop` and the
    /// tvOS relocate-mode D-pad remap. Audio tile assignment does
    /// NOT change — audio follows content, not position.
    func swap(_ aID: String, _ bID: String) {
        guard let aIdx = tiles.firstIndex(where: { $0.id == aID }),
              let bIdx = tiles.firstIndex(where: { $0.id == bID }),
              aIdx != bIdx else { return }
        tiles.swapAt(aIdx, bIdx)
        DebugLogger.shared.log(
            "[MV-Tile] swap \(aID)↔\(bID)",
            category: "Playback", level: .info
        )
    }

    // MARK: - Reset

    /// Clear the entire store. Called by `PlayerSession.exit()` when
    /// the user leaves multiview — the per-tile Coordinators own
    /// their own mpv handle teardown via SwiftUI view dismantling,
    /// so wiping `tiles` is enough to trigger cleanup.
    func reset() {
        tiles = []
        audioTileID = nil
        fullscreenTileID = nil
        relocatingTileID = nil
        isPiPActive = false
        // Clear the progress-store registry so the chrome overlay
        // doesn't keep a dangling reference to a torn-down tile's
        // `PlayerProgressStore`. SwiftUI unmount triggers
        // `.onDisappear` → `unregisterProgressStore(...)` for each
        // tile asynchronously, but this wipe runs now and covers
        // the window between mode flip and disappear.
        progressStoresByTileID = [:]
        // Intentionally NOT resetting `warningLastShownAt` — it's
        // a 2h throttle across multiview sessions, not per-session.
    }

    // MARK: - Convenience

    var count: Int { tiles.count }
    var isEmpty: Bool { tiles.isEmpty }
    var isAtMax: Bool { tiles.count >= maxTiles }

    /// `true` when a future `add` would hit the perf-warning threshold
    /// (used by the channel picker to pre-badge the "add" button).
    var nextAddNeedsWarning: Bool {
        tiles.count >= softLimit && !warningRecentlyShown
    }
}
