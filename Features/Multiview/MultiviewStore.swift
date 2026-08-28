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

    /// Issue #27: if non-nil, the grid renders this tile large with the
    /// remaining tiles stacked small alongside it (a "spotlight" layout,
    /// like the 3-stream layout) instead of the equal grid. All tiles stay
    /// visible and playing. Set/cleared by the per-tile "Spotlight" menu
    /// action; distinct from `fullscreenTileID`, which hides the others.
    @Published var spotlightTileID: String?

    /// Swap Stream: the tile the user asked to re-point at another
    /// channel. Non-nil raises the normal Add picker in swap mode; the
    /// container owns the presentation, so the per-tile menu (which
    /// lives deep inside the grid) only has to set this. Cleared when
    /// the picker closes, whether or not a channel was chosen.
    @Published var pendingSwapTileID: String?

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

    /// TEST (branch test/avplayer-hls-engine): which engine each tile's
    /// video view chose ("AVPlayer" / "MPV"), keyed by tile id. The
    /// custom chrome renders identically for both engines, so the
    /// chrome shows the audio tile's engine as a badge; without it a
    /// tester cannot tell which pipeline is actually playing.
    @Published private(set) var tileEngines: [String: String] = [:]

    func registerEngine(_ engine: String, for tileID: String) {
        if tileEngines[tileID] != engine {
            tileEngines[tileID] = engine
        }
    }

    func unregisterEngine(for tileID: String) {
        tileEngines.removeValue(forKey: tileID)
    }

    // MARK: - Session-locked engine
    /// The engine for THIS session, resolved once at multiview entry and
    /// inherited by every tile for the session's life. A single value
    /// makes a mixed-engine grid unrepresentable: every tile reads this,
    /// so an "AVPlayer session" can never silently go half-mpv. Defaults
    /// to `.mpv` (the toggle-off behavior); cleared on exit so the next
    /// session re-resolves and honors a freshly-toggled flag.
    @Published private(set) var sessionEngine: PlaybackEngine = .mpv
    /// The upgraded route URL for the seed tile when the lock is
    /// direct-HLS (server-side TS->HLS upgrade); nil otherwise.
    @Published private(set) var sessionRouteURL: URL?
    /// The auth headers resolveEngine built for AVPlayer tiles. These use
    /// the X-API-Key + `Authorization: ApiKey` shape the Dispatcharr HLS
    /// endpoint requires, which differs from a server's configured
    /// authHeaders mode (e.g. X-API-Key only). The mpv/TS endpoint
    /// accepts the leaner headers, but the HLS playlist/segment endpoint
    /// 404s without the Authorization header, so AVPlayer tiles must use
    /// these, not tile.headers. Server-scoped, so they apply to every
    /// tile in the session.
    @Published private(set) var sessionHeaders: [String: String] = [:]

    func lockEngine(_ resolved: ResolvedEngine) {
        sessionEngine = resolved.engine
        sessionRouteURL = resolved.engine == .avPlayerDirectHLS ? resolved.routeURL : nil
        sessionHeaders = resolved.engine.isAVPlayer ? resolved.headers : [:]
    }

    func clearEngineLock() {
        sessionEngine = .mpv
        sessionRouteURL = nil
        sessionHeaders = [:]
    }

    /// One-way downgrade: a runtime AVPlayer failure (codec gate, fatal
    /// item error) pins the WHOLE session to mpv for the rest of its
    /// life, so no tile or re-begin can flip back. Idempotent.
    func downgradeToMPV() {
        guard sessionEngine.isAVPlayer else { return }
        // Test flag: with mpv disabled the session NEVER downgrades -
        // the failing tile shows its own error (failOrFallback) and the
        // log records what would have been silently rescued.
        guard PlaybackFeatureFlags.mpvEngineEnabled else {
            DebugLogger.shared.log("[Engine] AVPlayer failure would downgrade to mpv, but mpv is disabled (dev flag)",
                                   category: "Playback", level: .warning)
            return
        }
        sessionEngine = .mpv
        sessionRouteURL = nil
        DebugLogger.shared.log("[Engine] session downgraded to mpv (AVPlayer failure)",
                               category: "Playback", level: .warning)
    }

    /// TEST (branch test/avplayer-hls-engine): each tile's actual video
    /// aspect ratio (width/height), registered by the tile's video view
    /// when known. The focus border uses it to hug the VIDEO rect
    /// instead of the tile frame (which includes letterbox bars in
    /// spotlight and other non-16:9 panes). Missing entry = assume 16:9.
    @Published private(set) var tileVideoAspects: [String: CGFloat] = [:]

    func registerVideoAspect(_ aspect: CGFloat, for tileID: String) {
        guard aspect > 0.1, aspect < 10 else { return }
        if tileVideoAspects[tileID] != aspect {
            tileVideoAspects[tileID] = aspect
        }
    }

    func unregisterVideoAspect(for tileID: String) {
        tileVideoAspects.removeValue(forKey: tileID)
    }

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

    /// v1.7.x: when `true`, single-taps on Guide channel cells
    /// (`EPGGuideView`'s `GuideProgramButton`) add the channel to
    /// `tiles` (or remove it if already present) instead of starting
    /// playback. Set when the user picks "Add to Multiview" from
    /// the long-press context menu; cleared when the user taps the
    /// "Done" button in the in-Guide staging banner, when `tiles`
    /// hits the hard cap, or when the user manually drains `tiles`
    /// back to zero. Freyguy1975 (Discord 2026-05-11) requested a
    /// way to build a multiview pile directly from the Guide without
    /// having to play a stream first; this flag is the toggle the
    /// Guide checks at tap time.
    @Published var isStagingFromGuide: Bool = false

    /// Looks up the tile currently representing `channelID`, or
    /// `nil` if no tile is tracking that channel. Used by the Guide
    /// staging-mode toggle to find which tile to remove on re-tap,
    /// and by the "Add to Multiview" menu label so an already-staged
    /// channel reads as "Remove from Multiview" instead.
    func tile(forChannelID channelID: String) -> MultiviewTile? {
        tiles.first { $0.item.id == channelID }
    }

    /// Wipes every tile. Used by `EPGGuideView` when entering
    /// staging mode so the user assembles a fresh multiview pile
    /// rather than appending to whatever was previously there
    /// (matches Freyguy's "start fresh" intent). Also clears
    /// `audioTileID`, `fullscreenTileID`, and `relocatingTileID`
    /// so dangling references can't survive across the reset.
    func clearAll() {
        let count = tiles.count
        tiles.removeAll()
        audioTileID = nil
        fullscreenTileID = nil
        spotlightTileID = nil
        relocatingTileID = nil
        if count > 0 {
            DebugLogger.shared.log(
                "[MV-Tile] clearAll: wiped \(count) tile(s)",
                category: "Playback", level: .info
            )
        }
    }

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

    /// Bumps on every `reset()` (which wipes `progressStoresByTileID`). Tile
    /// views fold this into their `.task(id:)` so a SAME-ID re-seed after a
    /// `PlayerSession.exit()` + `enterMultiview()` cycle (e.g. a LAN/WAN
    /// failover re-tune, common on the AVPlayer engine) re-registers the tile's
    /// `PlayerProgressStore`. Without it the wipe leaves `audioProgressStore`
    /// nil and the Options panel can't mount, so the Options pill goes dead.
    @Published private(set) var progressStoreRegistrationEpoch: Int = 0

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
        "file",   // local-file recordings via the TS-ingest container path
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
        // #46 (GH): once the user picks "Don't Show Again" on the warning we
        // never surface it again (device-local, like the other multiview prefs).
        if !bypassWarning && tiles.count >= softLimit && !warningRecentlyShown
            && !UserDefaults.standard.bool(forKey: "multiviewPerfWarningSuppressed") {
            DebugLogger.shared.log(
                "[MV-Tile] add pending: needsWarning (count=\(tiles.count), softLimit=\(softLimit))",
                category: "Playback", level: .info
            )
            return .needsWarning
        }
        // Under a direct-HLS session lock, a raw-TS channel added to the
        // grid must request the server-side HLS upgrade so it plays
        // DIRECT on AVPlayer (the locked engine) instead of feeding raw
        // TS to AVPlayer and tripping the one-way downgrade. Mirrors the
        // seed tile's upgrade. Only fires for a capable host; otherwise
        // the raw URL stands (and would downgrade, the honest edge case).
        var tileURL = resolved.url
        if sessionEngine == .avPlayerDirectHLS,
           classifyStreamURL(resolved.url) == .mpegTS,
           HLSCapabilityStore.shared.isCapable(resolved.url) {
            tileURL = appendingHLSOutputFormat(resolved.url)
        }
        // Commit. `resolved.url` + `resolved.headers` are
        // DELIBERATELY NOT LOGGED — they contain auth credentials.
        let tile = MultiviewTile(
            id: UUID().uuidString,
            item: item,
            streamURL: tileURL,
            headers: resolved.headers,
            addedAt: Date()
        )
        tiles.append(tile)
        // Live Rewind: going 1 -> 2 tiles leaves the first tile's relay
        // session buffering (its eligibility was captured at play time);
        // tell it to drop to the direct stream so multiview never rides
        // the relay or holds the extra engine connection.
        if tiles.count == 2 {
            NotificationCenter.default.post(name: .aerioLiveRewindDropRelay, object: nil)
        }
        // Last-added gets audio (matches the plan's default).
        audioTileID = tile.id
        DebugLogger.shared.log(
            "[MV-Tile] add ok: \(item.name) tileID=\(tile.id) total=\(tiles.count) bypassWarning=\(bypassWarning)",
            category: "Playback", level: .info
        )
        return .added
    }

    /// Swap an existing tile to a different channel, keeping its slot in
    /// the grid and whatever roles it held (audio / spotlight / full-
    /// screen). The tile count never changes, so the hard cap and the
    /// soft-limit performance warning do not apply here; only `add`'s
    /// dedup and stream-resolution rules carry over.
    ///
    /// A NEW tile id is minted deliberately. The tile views key their
    /// player coordinators on the id, so reusing it would leave the old
    /// coordinator attached to a stale URL; a fresh id tears the old
    /// player down and builds one for the new stream. The roles are then
    /// re-pointed at the new id so the swap is invisible to the user.
    func replace(
        tileID: String,
        with item: ChannelDisplayItem,
        server: ServerConnection?
    ) -> AddResult {
        guard let idx = tiles.firstIndex(where: { $0.id == tileID }) else {
            DebugLogger.shared.log(
                "[MV-Tile] swap rejected: unknown tileID=\(tileID)",
                category: "Playback", level: .warning
            )
            return .unresolvable
        }
        // Picking the channel the tile already shows is a no-op, not a
        // rejection: the user asked for this state and now has it.
        if tiles[idx].item.id == item.id { return .added }
        // Dedup against the OTHER tiles only.
        if tiles.contains(where: { $0.id != tileID && $0.item.id == item.id }) {
            DebugLogger.shared.log(
                "[MV-Tile] swap rejected: alreadyPresent id=\(item.id)",
                category: "Playback", level: .info
            )
            return .alreadyPresent
        }
        guard let resolved = Self.resolveStream(item, server: server) else {
            // Never log streamURLs - XC URLs carry credentials in the path.
            DebugLogger.shared.log(
                "[MV-Tile] swap rejected: unresolvable channel=\(item.name)",
                category: "Playback", level: .warning
            )
            return .unresolvable
        }
        // Same direct-HLS upgrade `add` applies, for the same reason: under
        // an AVPlayer session lock a raw-TS stream must request the server
        // side HLS upgrade or it trips the one-way downgrade.
        var tileURL = resolved.url
        if sessionEngine == .avPlayerDirectHLS,
           classifyStreamURL(resolved.url) == .mpegTS,
           HLSCapabilityStore.shared.isCapable(resolved.url) {
            tileURL = appendingHLSOutputFormat(resolved.url)
        }
        let old = tiles[idx]
        let fresh = MultiviewTile(
            id: UUID().uuidString,
            item: item,
            streamURL: tileURL,
            headers: resolved.headers,
            addedAt: old.addedAt   // keep grid ordering stable
        )
        tiles[idx] = fresh
        if audioTileID == old.id { audioTileID = fresh.id }
        if spotlightTileID == old.id { spotlightTileID = fresh.id }
        if fullscreenTileID == old.id { fullscreenTileID = fresh.id }
        DebugLogger.shared.log(
            "[MV-Tile] swap ok: \(old.item.name) -> \(item.name) slot=\(idx) tileID=\(fresh.id)",
            category: "Playback", level: .info
        )
        return .added
    }

    /// Add a VOD (movie / episode) or in-progress DVR-recording tile.
    /// The stream URL must already be resolved (the picker runs the
    /// async Dispatcharr proxy resolve before calling this, so the store
    /// stays synchronous and UI-free). Mirrors `add` for the cap /
    /// warning / audio-focus rules, but builds the tile from a synthetic
    /// `ChannelDisplayItem` (so the existing `tile.item` readers keep
    /// working unchanged) plus the VOD identity that drives resume + the
    /// periodic WatchProgress save in the player coordinator.
    ///
    /// The synthetic item's `streamURL` is deliberately left nil so the
    /// Record affordance (which gates on `item.streamURL != nil`) stays
    /// hidden for VOD tiles; playback uses the tile's own `streamURL`.
    /// Catch-up unification (task #147): replace whatever is playing
    /// with a single catch-up tile. Catch-up is always a solo, full
    /// teardown-and-reseed session — no mixing with live tiles in v1.
    func seedCatchup(_ pb: CatchupPlayback) {
        reset()
        // Catch-up is mpv-only: the aeriocu relay + window re-tune seek
        // model live in the mpv coordinator. Never route to AVPlayer.
        // Catch-up rides the AVPlayer container in the no-mpv regime
        // (archive TS through the live remux arm + window re-tune
        // seeks); with mpv enabled the legacy aeriocu relay path keeps
        // the tile via MultiviewTileView's engine guard.
        if PlaybackFeatureFlags.avPlayerRemuxTS, !PlaybackFeatureFlags.mpvEngineEnabled {
            lockEngine(ResolvedEngine(engine: .avPlayerRemuxTS,
                                      routeURL: pb.url,
                                      headers: pb.headers))
        } else {
            clearEngineLock()
        }
        let syntheticItem = ChannelDisplayItem(
            id: "catchup-\(pb.id.uuidString)",
            name: pb.title,
            number: "",
            logoURL: nil,
            group: "Catch-up",
            categoryOrder: 0,
            streamURL: nil,   // hides the Record affordance, like VOD
            streamURLs: []
        )
        let tile = MultiviewTile(
            id: UUID().uuidString,
            item: syntheticItem,
            streamURL: pb.url,
            headers: pb.headers,
            addedAt: Date(),
            kind: .catchup,
            catchup: pb
        )
        tiles = [tile]
        audioTileID = tile.id
        DebugLogger.shared.log(
            "[MV-Tile] seedCatchup: \(pb.title)",
            category: "Playback", level: .info
        )
    }

    /// The sole catch-up tile when the session is a catch-up replay;
    /// nil in every live/VOD configuration. The chrome and container
    /// key their mode gating on this.
    var catchupTile: MultiviewTile? {
        tiles.count == 1 ? tiles.first(where: { $0.kind == .catchup }) : nil
    }

    /// The sole VOD tile when the session is a single-title VOD play
    /// (the beginVOD path). The chrome gates its seekable transport
    /// (timeline band, 30s skips, D-pad scrub) on this, same as
    /// catch-up: both are fixed-duration seekable programmes.
    var vodSoloTile: MultiviewTile? {
        tiles.count == 1 ? tiles.first(where: { $0.kind == .vod || $0.kind == .dvr }) : nil
    }

    /// Persist the playing VOD's position RIGHT NOW (Back-to-exit path:
    /// "stop the video at that exact time"). The AVPlayer driver also
    /// saves every 10s during playback; this closes the last-10s gap so
    /// Continue Watching resumes exactly where the user left.
    func saveVODProgressNow() {
        guard let ps = audioProgressStore, let vodID = ps.vodID, !vodID.isEmpty,
              ps.durationMs > 0, ps.currentMs > 2_000 else { return }
        let finished = !ps.isDVRWindow && ps.currentMs > Int32(Double(ps.durationMs) * 0.9)
        WatchProgressManager.save(
            vodID: vodID, title: ps.vodTitle ?? "", positionMs: ps.currentMs,
            durationMs: ps.durationMs, posterURL: ps.vodPosterURL,
            vodType: ps.vodType, isFinished: finished,
            streamURL: ps.vodStreamURL, serverID: ps.vodServerID)
        DebugLogger.shared.log(
            "[VOD-PROGRESS] exit save at \(ps.currentMs)ms / \(ps.durationMs)ms",
            category: "Playback", level: .info)
    }

    // MARK: VOD version switching (container parity with the legacy
    // PlayerView cover's Switch Version; Logan's ask 2026-08-25).

    /// Provider copies of the playing VOD title, for the Options panel.
    /// Resume covers resolve these ASYNCHRONOUSLY after launch, so they
    /// arrive via updateVODVersionContext as often as via beginVOD.
    @Published private(set) var vodVersionOptions: [VODVersionOption] = []
    @Published private(set) var vodCurrentVersionID: Int?
    private var vodVersionSelectionKey: String?

    func setVODVersionContext(options: [VODVersionOption],
                              selectedID: Int?,
                              selectionKey: String?) {
        vodVersionOptions = options
        vodVersionSelectionKey = selectionKey
        vodCurrentVersionID = selectedID
            ?? options.first { $0.url == vodSoloTile?.streamURL }?.id
    }

    /// Late arrival from an async provider-copies fetch. Ignored unless
    /// the named title is still the playing solo-VOD tile.
    func updateVODVersionContext(vodID: String,
                                 options: [VODVersionOption],
                                 selectedID: Int?,
                                 selectionKey: String?) {
        guard let tile = vodSoloTile, tile.vodID == vodID else { return }
        setVODVersionContext(options: options, selectedID: selectedID,
                             selectionKey: selectionKey)
    }

    /// In-place provider-copy swap, mirroring the mpv path's
    /// switchVersionAction: stamp the position into explicitResumeMs so
    /// the restarted tile seeks back, persist the pick, update the
    /// Continue Watching URL, and replace the tile's streamURL (same
    /// tile id, so the tile view's streamURL onChange restarts the
    /// pipeline on the new copy).
    /// An in-progress recording FINISHED while the user was watching it:
    /// Dispatcharr stops appending, finalizes, and the /hls/ playlist
    /// route starts falling through to the SPA's HTML (which AVPlayer
    /// reports as -12646 "Playlist parse error"). Swap the tile in place
    /// - same id, so SwiftUI identity and the tile's onChange(streamURL)
    /// restart carry over, exactly like a version switch - onto the
    /// completed-file endpoint (/file/) as a plain .vod tile, resuming
    /// at the position the viewer was at. Returns false when the tile
    /// isn't a DVR-window tile or the URL isn't the HLS DVR shape (the
    /// caller then shows its normal error card).
    func migrateDVRTileToCompletedFile(tileID: String, positionMs: Int32) -> Bool {
        guard let idx = tiles.firstIndex(where: { $0.id == tileID }),
              tiles[idx].kind == .dvr else { return false }
        let tile = tiles[idx]
        let urlString = tile.streamURL.absoluteString
        let hlsSuffix = "hls/index.m3u8"
        guard urlString.hasSuffix(hlsSuffix),
              let fileURL = URL(string: String(urlString.dropLast(hlsSuffix.count)) + "file/")
        else { return false }
        DebugLogger.shared.log(
            "[MV-Tile] DVR recording finished mid-watch; migrating to /file/ at \(positionMs)ms tileID=\(tileID)",
            category: "Playback", level: .info)
        tiles[idx] = MultiviewTile(
            id: tile.id, item: tile.item, streamURL: fileURL,
            headers: tile.headers, addedAt: tile.addedAt, kind: .vod,
            vodID: tile.vodID, vodServerID: tile.vodServerID,
            vodType: tile.vodType,
            resumePositionMs: positionMs > 2_000 ? positionMs : nil)
        return true
    }

    func switchVODVersion(_ option: VODVersionOption) {
        guard let tile = vodSoloTile,
              let idx = tiles.firstIndex(where: { $0.id == tile.id }),
              option.url != tile.streamURL else { return }
        let resumeMs = audioProgressStore?.currentMs ?? 0
        audioProgressStore?.explicitResumeMs = resumeMs > 5_000 ? resumeMs : nil
        audioProgressStore?.vodStreamURL = option.url.absoluteString
        vodCurrentVersionID = option.id
        if let key = vodVersionSelectionKey {
            VODVersionSelectionStore.setSelection(option.id, forKey: key)
        }
        DebugLogger.shared.log(
            "[VOD-VERSION] container switch to '\(option.label)' at \(resumeMs)ms",
            category: "Playback", level: .info)
        var swapped = tile
        swapped = MultiviewTile(
            id: tile.id, item: tile.item, streamURL: option.url,
            headers: tile.headers, addedAt: tile.addedAt, kind: tile.kind,
            vodID: tile.vodID, vodServerID: tile.vodServerID,
            vodType: tile.vodType,
            resumePositionMs: resumeMs > 5_000 ? resumeMs : nil)
        tiles[idx] = swapped
    }

    @discardableResult
    func addVOD(
        title: String,
        streamURL: URL,
        headers: [String: String],
        posterURL: URL?,
        kind: TilePlaybackKind,
        vodID: String?,
        serverID: String?,
        vodType: String,
        resumePositionMs: Int32? = nil,
        bypassWarning: Bool = false,
        dvrScheduledEnd: Date? = nil,
        dvrChannelID: String? = nil
    ) -> AddResult {
        // Dedup on the VOD id when present. Server recordings have no
        // id, so they can be added more than once (matching channels).
        if let vid = vodID, !vid.isEmpty,
           tiles.contains(where: { $0.vodID == vid }) {
            return .alreadyPresent
        }
        if tiles.count >= maxTiles { return .rejectedMax }
        // Same scheme allowlist as `resolveStream`. The URL is already
        // resolved, but a Dispatcharr redirect could land on an exotic
        // scheme; only http(s) / rtmp(s) / rtsp are real streams.
        guard let scheme = streamURL.scheme?.lowercased(),
              Self.allowedSchemes.contains(scheme) else { return .unresolvable }
        if !bypassWarning && tiles.count >= softLimit && !warningRecentlyShown {
            return .needsWarning
        }
        // Synthetic display item: name + poster only. EPG fields stay
        // nil (a VOD has no live programme) and `streamURL` stays nil so
        // the Record affordance hides; playback uses `tile.streamURL`.
        let syntheticItem = ChannelDisplayItem(
            id: vodID ?? UUID().uuidString,
            name: title,
            number: "",
            logoURL: posterURL,
            group: "VOD",
            categoryOrder: 0,
            streamURL: nil,
            streamURLs: []
        )
        let tile = MultiviewTile(
            id: UUID().uuidString,
            item: syntheticItem,
            streamURL: streamURL,
            headers: headers,
            addedAt: Date(),
            kind: kind,
            vodID: vodID,
            vodServerID: serverID,
            vodType: vodType,
            resumePositionMs: resumePositionMs,
            dvrScheduledEnd: dvrScheduledEnd,
            dvrChannelID: dvrChannelID
        )
        tiles.append(tile)
        if tiles.count == 2 {
            NotificationCenter.default.post(name: .aerioLiveRewindDropRelay, object: nil)
        }
        audioTileID = tile.id
        DebugLogger.shared.log(
            "[MV-Tile] addVOD ok: \(title) kind=\(kind) tileID=\(tile.id) total=\(tiles.count)",
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

    /// v1.7.x: in-place swap of a tile's content for a different
    /// channel, preserving the tile's `id` so SwiftUI keeps the
    /// existing `MPVPlayerView` mounted (and its `Coordinator` +
    /// mpv handle + AVSampleBufferDisplayLayer alive). Used by the
    /// Apple-TV-and-iPhone channel-flip path
    /// (`NowPlayingManager.flushPendingChannelChange`) instead of
    /// the old `PlayerSession.exit() + enterMultiview()` teardown.
    ///
    /// Why the change: the teardown path called
    /// `mpv_terminate_destroy` on the old coordinator, dismantled
    /// the AVSBDL layer, and stood up a fresh coordinator + handle
    /// for the new channel. The resulting first-frame latency
    /// (mpv_create + mpv_initialize + OpenGL ES setup + AVSBDL
    /// setup + libavformat's 1.5s `analyzeduration` probe per v1.7.0)
    /// produced a visible "30fps then 60fps with a 200ms hiccup"
    /// wobble reported by "the Moterator" (Discord 2026-05-11).
    /// Reusing the coordinator and issuing `loadfile <newURL>
    /// replace` against the existing mpv handle keeps the old
    /// channel's last decoded frame on screen while the new
    /// stream's demuxer probe runs, then the new stream cuts in
    /// at its real container fps with no cadence wobble.
    ///
    /// The caller pairs this with a
    /// `Coordinator.swapStream(to:nowPlayingTitle:)` call which
    /// SwiftUI fires automatically via `updateUIViewController`
    /// when the tile's `streamURL` changes.
    ///
    /// - Parameters:
    ///   - tileID: the existing tile to repurpose. Caller is
    ///     expected to be the N=1 single-stream channel-flip
    ///     path; multi-tile multiview channel-flip isn't a
    ///     supported gesture today.
    ///   - item: the channel to play in this tile next.
    ///   - server: active server for `authHeaders`.
    /// - Returns: `true` if the swap landed, `false` if the
    ///   tile id isn't in the store or the new channel has no
    ///   playable stream URL. Caller may choose to fall back to
    ///   the legacy teardown/rebuild path on `false`.
    @discardableResult
    func swapTileContent(
        tileID: String,
        to item: ChannelDisplayItem,
        server: ServerConnection?
    ) -> Bool {
        guard let idx = tiles.firstIndex(where: { $0.id == tileID }) else {
            DebugLogger.shared.log(
                "[MV-Tile] swapTileContent: tile id=\(tileID) not found (count=\(tiles.count))",
                category: "Playback", level: .warning
            )
            return false
        }
        guard let resolved = Self.resolveStream(item, server: server) else {
            // NOTE: never log `item.streamURLs` (XC URLs carry auth
            // credentials in the path). Name-only is safe.
            DebugLogger.shared.log(
                "[MV-Tile] swapTileContent: unresolvable channel=\(item.name)",
                category: "Playback", level: .warning
            )
            return false
        }
        // Preserve `addedAt` so any "most-recent-tile" ordering
        // heuristics (audio-focus default on remove, recency hints
        // in chrome) keep treating this tile as the same slot.
        let preservedAddedAt = tiles[idx].addedAt
        let previousName = tiles[idx].item.name
        tiles[idx] = MultiviewTile(
            id: tileID,                  // pinned
            item: item,
            streamURL: resolved.url,
            headers: resolved.headers,
            addedAt: preservedAddedAt
        )
        DebugLogger.shared.log(
            "[MV-Tile] swapTileContent: tile id=\(tileID) \(previousName) -> \(item.name)",
            category: "Playback", level: .info
        )
        return true
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
        if spotlightTileID == id {
            spotlightTileID = nil
        }
        if relocatingTileID == id {
            relocatingTileID = nil
        }
        // Become-sole-during-outage: if the removal leaves a single tile that
        // still has a live connection issue, re-post so the now-sole container
        // summons the outage chrome + focuses Retry. A plain audio promotion
        // never re-fires the tile's own connectionIssueChanged flag, so without
        // this the Retry cell wouldn't auto-appear. The container reads soleness
        // fresh inside its handler, so this synchronous post is evaluated
        // against the just-shrunk tile list (2026-07-13 review #162).
        if tiles.count == 1, audioProgressStore?.connectionIssueActive == true {
            NotificationCenter.default.post(name: .connectionIssueChanged, object: true)
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
        spotlightTileID = nil
        relocatingTileID = nil
        isPiPActive = false
        // Clear the progress-store registry so the chrome overlay
        // doesn't keep a dangling reference to a torn-down tile's
        // `PlayerProgressStore`. SwiftUI unmount triggers
        // `.onDisappear` → `unregisterProgressStore(...)` for each
        // tile asynchronously, but this wipe runs now and covers
        // the window between mode flip and disappear.
        progressStoresByTileID = [:]
        // Force still-mounted tiles to re-register after this wipe. A same-id
        // re-seed (exit()+enterMultiview on a failover re-tune) does NOT re-fire
        // the tile's `.task(id: tile.id)`, so without this bump the audio tile's
        // store stays unregistered and the Options panel never mounts.
        progressStoreRegistrationEpoch &+= 1
        tileEngines = [:]
        vodVersionOptions = []
        vodCurrentVersionID = nil
        vodVersionSelectionKey = nil
        // Engine lock is per-session: clear it so the next session
        // re-resolves (and honors a freshly-toggled Developer flag).
        clearEngineLock()
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

extension Notification.Name {
    /// Live Rewind: posted when the tile count goes 1 -> 2 so the solo
    /// tile's coordinator drops the buffer relay (its eligibility was
    /// captured at play time and multiview must never ride the relay).
    static let aerioLiveRewindDropRelay = Notification.Name("aerioLiveRewindDropRelay")
    /// GH #60 seatbelt: posted by the memory-warning hook when RSS crosses the
    /// runaway line during playback; the live coordinator answers with ONE
    /// relay reload (drops the old mpv stream thread + its pinned buffers).
    static let aerioMemorySeatbeltReload = Notification.Name("aerioMemorySeatbeltReload")
}
