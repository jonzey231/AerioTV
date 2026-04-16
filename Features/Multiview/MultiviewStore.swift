import Foundation
import SwiftUI

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
