import SwiftUI
import SwiftData
import Combine  // Xcode 26.5 requires explicit Combine import for the
               // Timer.publish().autoconnect() (Publishers.Autoconnect)
               // stored-property type; transitive SwiftUI import no longer suffices.

// MARK: - EPG Guide Program
/// A program block in the guide grid. Carries enough data to render a cell
/// and to play the associated channel.
struct GuideProgram: Identifiable, Equatable {
    var id: String { "\(channelID)-\(title)-\(start.timeIntervalSinceReferenceDate)" }
    let channelID: String  // matches ChannelDisplayItem.id
    let title: String
    let description: String
    let start: Date
    let end: Date
    let category: String

    /// v1.7.x: Dispatcharr's `ProgramData.id` (server-side primary key)
    /// when the program came from `/api/epg/grid/`. Used by ProgramInfoView
    /// to lazy-load `<category>` data via `/api/epg/programs/<id>/` for
    /// programs that the bulk grid intentionally strips categories from.
    /// Nil for programs sourced from XMLTV streams or Xtream Codes (those
    /// paths already carry categories inline, no detail call needed).
    let programID: Int?

    // MARK: EPG badge metadata (guide/list/info-sheet badges)
    // `isLiveBroadcast` is the feed's XMLTV `<live/>` / Dispatcharr
    // `is_live` flag, distinct from the clock-derived `isLive` below.
    let subTitle: String?
    let season: Int?
    let episode: Int?
    let isNew: Bool
    let isLiveBroadcast: Bool
    let isPremiere: Bool
    let isFinale: Bool
    let isRepeat: Bool

    /// Computed: the program is currently airing.
    var isLive: Bool {
        let now = Date()
        return start <= now && end > now
    }

    /// Convenience initializer that defaults `programID` and the badge
    /// metadata so the dozen+ existing call sites (XMLTV merge, Xtream,
    /// dummy fillers, etc.) don't need to change. Data-bearing sites pass
    /// explicit values.
    init(channelID: String, title: String, description: String,
         start: Date, end: Date, category: String, programID: Int? = nil,
         subTitle: String? = nil, season: Int? = nil, episode: Int? = nil,
         isNew: Bool = false, isLiveBroadcast: Bool = false,
         isPremiere: Bool = false, isFinale: Bool = false, isRepeat: Bool = false) {
        self.channelID = channelID
        self.title = title
        self.description = description
        self.start = start
        self.end = end
        self.category = category
        self.programID = programID
        self.subTitle = subTitle
        self.season = season
        self.episode = episode
        self.isNew = isNew
        self.isLiveBroadcast = isLiveBroadcast
        self.isPremiere = isPremiere
        self.isFinale = isFinale
        self.isRepeat = isRepeat
    }
}

import SwiftData

// MARK: - Guide Store
/// Manages EPG programs for the guide grid.
/// Phase 0: loads from SwiftData persistent cache (instant, survives app restart).
/// Phase 1: seeds from current-program data on each ChannelDisplayItem.
/// Phase 2: fetches upcoming programs from network (only if cache is stale).
@MainActor
final class GuideStore: ObservableObject {
    /// Singleton so non-guide views (MainTabView's initial-sync
    /// loading cover, specifically) can observe `isLoading` during
    /// the XMLTV parse. Previously GuideStore was a per-view
    /// `@StateObject` in EPGGuideView — which meant MainTabView had
    /// no visibility into whether XMLTV had finished, so the loading
    /// cover would dismiss on the faster JSON bulk path and drop
    /// the user into a partially-populated guide while XMLTV was
    /// still parsing silently.
    static let shared = GuideStore()

    @Published var programs: [String: [GuideProgram]] = [:] {  // channelID → programs
        // Task #188: any EPG mutation invalidates the focus-path memo below.
        didSet { programChannelMemo.removeAll() }
    }
    /// Task #188: programID -> channelID memo for the D-pad focus hot path.
    /// `channelID(ofProgram:)` is an O(channels) scan (string prefix + list
    /// membership per candidate) that ran on EVERY focus change and up to
    /// ~5x per horizontal press via the retarget/assert-retry loops. Focus
    /// revisits the same programme ids constantly, so a lazy memo turns the
    /// steady state into a dictionary hit. Grows only with programmes the
    /// user actually focuses; cleared on every EPG write.
    var programChannelMemo: [String: String] = [:]
    @Published var isLoading = false

    /// Wall-clock age of the currently-loaded EPG data: the newest
    /// `fetchedAt` across loaded rows (set by `loadFromCache`) or `now`
    /// after a successful network refresh (`fetchUpcoming`). Drives the
    /// warm-foreground staleness check that fixes issue #24 (opening the
    /// app after hours showed an old, never-refreshed guide). `nil` before
    /// the first load.
    var newestFetchedAt: Date?

    /// True when the loaded EPG data is older than `olderThan` (or there is
    /// none yet). Used on `scenePhase .active` to decide whether to kick a
    /// guide refresh, since the orchestrator only runs on cold launch /
    /// server change, not on warm foreground.
    func isEPGStale(olderThan seconds: TimeInterval) -> Bool {
        guard let newestFetchedAt else { return true }
        return Date().timeIntervalSince(newestFetchedAt) > seconds
    }

    // Batch mode: accumulate merges into a backing dict, publish once at end.
    private var _pendingPrograms: [String: [GuideProgram]] = [:]
    private var _isBatching = false

    /// Idempotency cache for `loadFromCache`. Both
    /// `MainTabView.task(channelServerKey)` and
    /// `EPGGuideView.task(id: channels.count)` call `loadFromCache`
    /// on the same `channels.count` transition. Storing the result
    /// here lets the second call replay in microseconds once the
    /// first call has completed. Invalidated by `saveToCache` so a
    /// fresh network-fetch → cache-save cycle triggers a real
    /// SwiftData read on the next caller.
    private var lastLoadFromCacheResult: (serverID: String, isFresh: Bool)? = nil

    /// Coalesces concurrent `loadFromCache` calls. The old sync
    /// version of `loadFromCache` couldn't race because MainActor
    /// serialization ran the first call to completion (including the
    /// `lastLoadFromCacheResult` write) before the second call ever
    /// entered. Now that the fetch is `async` and hits `await
    /// Task.detached.value` internally, the first caller suspends
    /// BEFORE it writes `lastLoadFromCacheResult`, so a second
    /// concurrent caller would otherwise spawn its own duplicate 97k-
    /// row fetch. When an in-flight task exists for the matching
    /// `serverID`, the new caller awaits its `.value` instead.
    private var inFlightLoadTask: (serverID: String, task: Task<Bool, Never>)? = nil

    /// Result payload returned by the off-main XMLTV merge task in
    /// `performXMLTVFetch`. `Sendable` so the compiler lets us
    /// cross the `Task.detached` boundary; all field types are
    /// value types of `Sendable` primitives (`String`, `Date`, `Int`
    /// — `GuideProgram` itself is a struct of these).
    fileprivate struct XMLTVMergeResult: Sendable {
        let dict: [String: [GuideProgram]]
        let matched: Int
        let missed: Int
        let currentCategoriesByChannelID: [String: String]
    }

    /// Coalesces concurrent `fetchXMLTVFromURL` calls. On cold
    /// install with a Dispatcharr playlist, two separate code paths
    /// each kick off an XMLTV download+parse against the same
    /// `{baseURL}/output/epg?tvg_id_source=tvg_id` URL:
    ///
    ///   1. `ChannelStore.loadAllEPG` → `primeXMLTVFromURL` (for
    ///      first-frame tint data on iPhone, which never mounts
    ///      EPGGuideView)
    ///   2. `EPGGuideView.task(id: channels.count)` →
    ///      `fetchUpcoming` → `fetchDispatcharr` (for the guide
    ///      grid itself)
    ///
    /// Both produce byte-identical program data on the 97k-entry
    /// torture playlist; running them serially doubles the cold-
    /// install wait. When the second caller arrives while the
    /// first is still parsing, it awaits the first's `.value`
    /// instead of starting a duplicate download. Coalescing also
    /// has to respect the non-URL semantics introduced later:
    /// `replaceExisting` changes whether the fetched window
    /// replaces the old slice, and `categoryServerID` scopes where
    /// the resulting tint metadata is published. Callers only join
    /// when all three match.
    private struct InFlightXMLTVKey: Equatable {
        let url: URL
        let categoryServerID: String
        let replaceExisting: Bool
    }

    private var inFlightXMLTVTask: (key: InFlightXMLTVKey, task: Task<Bool, Never>)? = nil

    /// The last bulk-XMLTV pass that completed successfully, so a caller
    /// arriving *after* it finished is served from the merge that already
    /// landed instead of re-downloading the feed.
    ///
    /// `inFlightXMLTVTask` above only coalesces callers that overlap in time.
    /// The expensive duplicates are sequential: `ChannelStore.loadAllEPG` →
    /// `primeXMLTVFromURL` pulls the provider's whole guide, finishes, and then
    /// `fetchUpcoming` → `fetchXtreamBulkXMLTV` pulls the identical bytes again
    /// a moment later. Nothing in the in-flight path can see that.
    ///
    /// A hit requires the same request shape AND that this call's channels are
    /// already covered by the completed pass. That subset test is what makes
    /// skipping safe rather than merely cheap: `performXMLTVFetch` parses the
    /// whole feed but merges only the channels it was handed, so a channel the
    /// earlier pass carried has *already* been merged, while one it did not
    /// carry still needs a real fetch.
    private struct CompletedXMLTVPass {
        let key: InFlightXMLTVKey
        let channelKeys: Set<String>
        /// The parse window the pass actually kept programmes for. Reuse must
        /// require the new request's window to fit inside this (with slack for
        /// the natural forward drift of `now`-derived windows): the parser
        /// window-filters at parse time, so a later caller wanting a deeper
        /// window would otherwise be told "already merged" for programmes the
        /// recorded pass threw away. Today all same-URL callers use the same
        /// window shape and this never rejects; it exists so the first future
        /// deep-window caller (catch-up backfill) fails safe into a real fetch.
        let windowStart: Date
        let windowEnd: Date
        let at: Date
    }
    private var lastCompletedXMLTVPass: CompletedXMLTVPass? = nil

    /// How long a completed pass stays reusable. Long enough to absorb a cold
    /// start's overlapping loaders, short enough that a user who waits a few
    /// minutes and pulls to refresh gets real bytes. Explicit refresh carries
    /// `replaceExisting: true`, a different key, so it never lands here at all.
    private static let xmltvReuseWindow: TimeInterval = 180

    /// Generation of the on-disk EPG cache this build trusts. Bump whenever a
    /// shipped defect could have written cache rows that cannot be repaired in
    /// place; the next `loadFromCache` then runs ONE full purge, stamps the
    /// new epoch, and forces a real refetch (see the epoch block inside
    /// `loadFromCache`). Replaces the old chain of per-defect one-shot
    /// UserDefaults keys, which purged the cache serially across several
    /// consecutive app updates.
    /// Epoch 1 covers everything the legacy keys covered
    /// (`xmltvCategoryFixMigrationV2`, `epg.badgeCacheClearedV1`,
    /// `epg.crossPlaylistPurgeV1`).
    nonisolated private static let epgCacheEpoch = 1
    nonisolated private static let epgCacheEpochKey = "epg.cacheEpoch"

    /// Drop the completed-pass record so the next bulk-XMLTV request goes to
    /// the network. Called when the user explicitly asks for fresh data: the
    /// reuse window exists to stop redundant background re-fetches, and must
    /// never turn a deliberate Refresh into a no-op.
    func invalidateBulkGuideReuse() {
        guard lastCompletedXMLTVPass != nil else { return }
        lastCompletedXMLTVPass = nil
        debugLog("📺 GuideStore: bulk-guide reuse invalidated — the next XMLTV request will re-download")
    }

    /// Un-latch a server's EPG refusal state so the next fetch is a real
    /// attempt. The latches exist to stop the app re-asking a refusing
    /// provider hundreds of times per session (measured 155 xmltv.php
    /// repeats, 5,374 get_short_epg calls), but a 403 is NOT always
    /// permanent — Cloudflare rate-limits lift, bans expire. Without a reset,
    /// one transient 403 silenced EPG for the rest of the process and even
    /// Settings → Refresh EPG Data could not recover; a user who purged their
    /// cache on that screen was left with an EMPTY guide until force-quit.
    /// Called from `ChannelStore.forceRefresh` (the user asked; ask again)
    /// and from `beginDisplaying` (the incoming playlist gets a fresh chance).
    func resetEPGRefusalLatches(forServerKey serverKey: String) {
        let hadRefusal = Self.xmltvRefused.remove(serverKey) != nil
        let hadExhausted = Self.xtreamFallbackExhausted.remove(serverKey) != nil
        if hadRefusal || hadExhausted {
            debugLog("📺 GuideStore: cleared EPG refusal latches for \(serverKey.prefix(8)) (refused=\(hadRefusal), fallbackExhausted=\(hadExhausted)) — next fetch is a real attempt")
        }
    }

    /// Every key the XMLTV merge loop can match a programme on, lowercased to
    /// match the parser's case-folded comparison. Shared by the reuse check and
    /// the filter-during-parse allowlist so the two can never drift apart.
    private static func channelMatchKeys(_ channels: [ChannelDisplayItem]) -> Set<String> {
        var keys = Set<String>()
        for ch in channels {
            if let tvg = ch.tvgID, !tvg.isEmpty { keys.insert(tvg.lowercased()) }
            if !ch.number.isEmpty { keys.insert(ch.number.lowercased()) }
            if let uuid = ch.uuid, !uuid.isEmpty { keys.insert(uuid.lowercased()) }
        }
        return keys
    }

    /// Signature of the last seedEPGCache run — "serverID|channelCount|programCount".
    /// Warm relaunch fires `seedEPGCache` three times with identical
    /// inputs (MainTabView.task after loadFromCache, EPGGuideView.task
    /// after its loadFromCache, and the onChange handler when
    /// isEPGLoading flips false). The write is actor-serialized and
    /// idempotent, but iterating 2183 channel refs + snapshotting a
    /// 97k-entry dict three times is pure wasted CPU. If a caller
    /// arrives with the same signature as the last run, we skip —
    /// the first call already populated the EPGCache with the same
    /// data. Synchronous set-before-suspend means concurrent callers
    /// on the same @MainActor won't race.
    private var lastSeedEPGCacheSignature: String? = nil

    // MARK: - Display ownership (2026-08-11, multi-playlist EPG contamination)
    //
    // GuideStore is a singleton and `programs` is keyed by CHANNEL id -- which
    // for Xtream playlists is the panel's bare stream_id ("1", "2", ...). Two
    // playlists routinely collide on those keys. The bug this fixes: open the
    // guide on playlist A (crx, 33MB XMLTV, slow parse), switch to playlist B
    // (Tuliprox) while A's merge is still in flight. B loads and renders
    // correctly, then A's merge completes and does `programs = result.dict`,
    // replacing B's schedule with A's under the same keys. On screen: ESPN's
    // "First Take" on Global Toronto, and colliding cells collapsed to 20pt
    // slivers. Three earlier "sliver fixes" (duration filter, cache-load
    // filter, narrow-cell text gate) all treated symptoms of this race.
    //
    // The rule, which is how every multi-playlist IPTV client stays sane: a
    // bulk programme write is only valid for the playlist the guide is
    // CURRENTLY displaying. Anything else is a stale writer and is discarded.
    // The per-server SwiftData cache still gets saved by the fetch paths, so
    // the discarded work isn't wasted -- it's there when the user switches
    // back. Persisted identifiers are untouched.

    /// UUID string of the server whose programmes the guide is displaying.
    /// Set by `loadFromCache` and `fetchUpcoming` (the two per-server entry
    /// points); every bulk write checks it via `commitPrograms`.
    private(set) var displayedServerID: String? = nil

    /// Records a playlist switch and cancels in-flight EPG work that belongs
    /// to the previous playlist. Deliberately does NOT clear `programs`:
    /// the new server's cache load replaces it wholesale moments later, and
    /// clearing early would blank the guide during the transition.
    private func beginDisplaying(serverID: String) {
        guard displayedServerID != serverID else { return }
        debugLog("📺 GuideStore: display switch \(displayedServerID?.prefix(8) ?? "none") → \(serverID.prefix(8)); cancelling stale in-flight EPG work")
        displayedServerID = serverID
        inFlightLoadTask?.task.cancel()
        inFlightLoadTask = nil
        inFlightXMLTVTask?.task.cancel()
        inFlightXMLTVTask = nil
        // A completed pass belongs to the playlist that was on screen when it
        // ran. Its key is already server-scoped, so a stale entry could not be
        // served to the new playlist, but holding a foreign playlist's channel
        // key set across a switch is exactly the kind of cross-playlist state
        // that caused the contamination this section exists to prevent.
        lastCompletedXMLTVPass = nil
        // The incoming playlist gets a fresh EPG attempt even if it was
        // refusal-latched earlier in the session — see resetEPGRefusalLatches.
        resetEPGRefusalLatches(forServerKey: serverID)
        // Per-cell prefetches belong to the outgoing playlist too. Their
        // merge path also re-checks display ownership (a task already past
        // its cancellation checkpoints still completes), and the fetched-ids
        // / breaker state resets so the new playlist prefetches cleanly.
        resetPrefetchCache()
    }

    /// The single gate for bulk replacement of `programs`. Returns false and
    /// discards when the result was computed for a server the guide has
    /// since navigated away from.
    @discardableResult
    private func commitPrograms(_ dict: [String: [GuideProgram]],
                                for serverID: String, source: String) -> Bool {
        guard displayedServerID == nil || displayedServerID == serverID else {
            debugLog("📺 GuideStore: DISCARDED stale \(source) write for \(serverID.prefix(8)) — guide now displays \(displayedServerID!.prefix(8))")
            return false
        }
        // A bulk write that would leave the guide with NOTHING is a failed
        // fetch, not an empty guide, and it never wins over data we already
        // have. The bulk paths pre-strip the fetch window out of their base
        // dict before the network answers (replacingWindowBase), so a server
        // that returns 200 with zero rows -- an expired token, a hiccup, a
        // provider ban -- used to commit that hole: the guide emptied on
        // screen, and the caller then wrote the empty snapshot over the disk
        // cache and stamped it fresh, so the next launch had nothing either.
        // Android carried the same bug (fixed there 2026-08-20); Logan hit it
        // on the Streamer as "the guide shows for a second, then disappears".
        if !programs.isEmpty && !dict.contains(where: { !$0.value.isEmpty }) {
            debugLog("📺 GuideStore: REJECTED empty \(source) write — keeping the existing guide")
            return false
        }
        programs = dict
        return true
    }

    private func beginBatch(basePrograms: [String: [GuideProgram]]? = nil) {
        _isBatching = true
        _pendingPrograms = basePrograms ?? programs
    }

    private func endBatch(for serverID: String, source: String) {
        _isBatching = false
        commitPrograms(_pendingPrograms, for: serverID, source: source)
        _pendingPrograms = [:]
    }

    private func cancelBatch() {
        _isBatching = false
        _pendingPrograms = [:]
    }

    private func replacingWindowBase(
        for channels: [ChannelDisplayItem],
        windowStart: Date,
        windowEnd: Date
    ) -> [String: [GuideProgram]] {
        let channelIDs = Set(channels.map(\.id))
        guard !channelIDs.isEmpty else { return programs }

        var result = programs
        for channelID in channelIDs {
            guard var existing = result[channelID] else { continue }
            existing.removeAll { $0.end > windowStart && $0.start < windowEnd }
            if existing.isEmpty {
                result.removeValue(forKey: channelID)
            } else {
                result[channelID] = existing
            }
        }
        return result
    }

    /// Phase 0 — load persisted EPG from SwiftData. Returns true if cache was fresh enough.
    ///
    /// Scopes the query to the given `serverID` so EPG data from a
    /// previously-configured server (e.g. the user deleted an Xtream Codes
    /// playlist and added the same server back via Dispatcharr API) doesn't
    /// leak into the guide for the current server. Without this filter,
    /// the freshness check would pass on stale rows from a deleted server
    /// and the network fetch would be skipped, leaving the guide empty
    /// because the channel IDs no longer match.
    func loadFromCache(modelContext: ModelContext, channels: [ChannelDisplayItem], serverID: String) async -> Bool {
        // Completed-fetch shortcut. Match on serverID so a playlist
        // switch still forces a real read.
        beginDisplaying(serverID: serverID)
        if let cached = lastLoadFromCacheResult, cached.serverID == serverID {
            debugLog("📺 GuideStore.loadFromCache: idempotent replay (serverID=\(serverID), fresh=\(cached.isFresh), programs already loaded=\(programs.count) channels)")
            return cached.isFresh
        }
        // In-flight shortcut — see `inFlightLoadTask` doc comment.
        // Without this, two concurrent callers that both arrive
        // before the first fetch completes would each spawn their
        // own off-main fetch and pay for the 97k-row read twice.
        if let inFlight = inFlightLoadTask, inFlight.serverID == serverID {
            debugLog("📺 GuideStore.loadFromCache: joining in-flight fetch (serverID=\(serverID))")
            return await inFlight.task.value
        }

        // Snapshot config + container for the off-main fetch. On the
        // torture playlist, `modelContext.fetch` returns ~97k
        // EPGProgram rows and we then wrap each one in a GuideProgram
        // while bucketing by channelID — that's a 2-3 second main-
        // thread hang. We move both the fetch and the dict build to
        // a background ModelContext (same pattern as saveToCache
        // below) so the initial-sync loading cover keeps advancing
        // instead of freezing. `EPGProgram` instances themselves
        // never cross the thread boundary — they're read + converted
        // to plain `GuideProgram` structs on the bg context; only
        // the resulting Sendable dict (plus counts) comes back.
        let container = modelContext.container
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36
        // Catch-up: load retained history too, not just the last hour.
        let retentionSecs = GuideStore.activeRetentionSeconds()
        let refreshMins = UserDefaults.standard.integer(forKey: "bgRefreshIntervalMins")
        let effectiveMins = refreshMins > 0 ? refreshMins : 1440 // 0 means unset → default 24h
        let stalenessThreshold = TimeInterval(effectiveMins * 60)

        // Wrap the fetch in a Task that concurrent callers can join
        // via `inFlightLoadTask`. The Task inherits @MainActor from
        // the enclosing function, so `self.programs = …` + log +
        // lastLoadFromCacheResult writes all happen on main. The
        // expensive work is still in the nested Task.detached.
        let fetchTask = Task<Bool, Never> { [self] in
            let fetchResult: (loaded: (dict: [String: [GuideProgram]], programCount: Int, isFresh: Bool, newestFetchAgoSec: Int)?, purgedForEpoch: Bool) = await Task.detached(priority: .userInitiated) {
                let bgContext = ModelContext(container)

                // EPG cache epoch. Single integer generation stamp for the
                // on-disk EPG cache, replacing the old chain of per-defect
                // one-shot UserDefaults keys (category-fix migration, badge
                // upgrade, cross-playlist purge). The cache is pure derived
                // data: when the stored epoch is behind the build's epoch,
                // ONE full purge runs here, inside the same detached task
                // that is about to fetch, so there is no race with a
                // concurrent read. Returning a nil load makes the caller
                // treat the cache as empty, and the caller then clears the
                // bulk-guide reuse window and the EPG refusal latches so the
                // follow-up fetch is a real network attempt (the same resets
                // a user-initiated Refresh performs). Bump `epgCacheEpoch`
                // whenever a shipped defect could have written a cache that
                // cannot be repaired in place.
                let defaults = UserDefaults.standard
                if defaults.integer(forKey: Self.epgCacheEpochKey) == 0 {
                    // Devices upgrading from builds that used the legacy
                    // one-shot keys: if every legacy purge already ran, the
                    // cache is exactly what epoch 1 would produce, so stamp
                    // without purging again. Anything less gets the single
                    // epoch purge below, which satisfies all legacy
                    // semantics at once (each legacy one-shot only ever
                    // needed "any full purge plus refetch").
                    if defaults.bool(forKey: "xmltvCategoryFixMigrationV2"),
                       defaults.bool(forKey: "epg.badgeCacheClearedV1"),
                       defaults.bool(forKey: "epg.crossPlaylistPurgeV1") {
                        defaults.set(Self.epgCacheEpoch, forKey: Self.epgCacheEpochKey)
                    }
                }
                if defaults.integer(forKey: Self.epgCacheEpochKey) < Self.epgCacheEpoch {
                    if let allRows = try? bgContext.fetch(FetchDescriptor<EPGProgram>()) {
                        for ep in allRows { bgContext.delete(ep) }
                        try? bgContext.save()
                        debugLog("🗑️ EPG cache epoch purge: dropped \(allRows.count) rows written before epoch \(Self.epgCacheEpoch)")
                    }
                    defaults.set(Self.epgCacheEpoch, forKey: Self.epgCacheEpochKey)
                    return (nil, true)
                }

                let now = Date()
                let windowStart = now.addingTimeInterval(-retentionSecs)
                let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)
                let descriptor = FetchDescriptor<EPGProgram>(
                    predicate: #Predicate<EPGProgram> {
                        $0.serverID == serverID && $0.endTime > windowStart && $0.startTime < windowEnd
                    },
                    sortBy: [SortDescriptor(\.startTime)]
                )
                guard let cachedRows = try? bgContext.fetch(descriptor), !cachedRows.isEmpty else {
                    return (nil, false)
                }
                var dict: [String: [GuideProgram]] = [:]
                for ep in cachedRows {
                    // v1.7.x: thread `programID` so a fresh-cache cold
                    // launch on Dispatcharr can still drive the
                    // ProgramInfoView lazy-load. Pre-v1.7.x rows have
                    // `programID = nil` (lightweight migration); those
                    // get repopulated on the next bulk grid refresh.
                    let gp = GuideProgram(channelID: ep.channelID, title: ep.title,
                                          description: ep.programDescription,
                                          start: ep.startTime, end: ep.endTime,
                                          category: ep.category,
                                          programID: ep.programID,
                                          subTitle: ep.subTitle, season: ep.season,
                                          episode: ep.episode, isNew: ep.isNew,
                                          isLiveBroadcast: ep.isLiveBroadcast,
                                          isPremiere: ep.isPremiere, isFinale: ep.isFinale,
                                          isRepeat: ep.isRepeat)
                    dict[ep.channelID, default: []].append(gp)
                }
                let newestFetch = cachedRows.map(\.fetchedAt).max() ?? .distantPast
                let isFresh = now.timeIntervalSince(newestFetch) < stalenessThreshold
                return ((dict, cachedRows.count, isFresh, Int(now.timeIntervalSince(newestFetch))), false)
            }.value

            if fetchResult.purgedForEpoch {
                // The epoch purge just emptied the cache; make sure the
                // follow-up fetch is a real one. Reuses the exact resets the
                // user-facing Refresh path performs (ChannelStore.forceRefresh)
                // instead of duplicating fetch logic here: the reuse window
                // must not serve a pre-purge pass, and a refusal latch from
                // earlier in the session must not silence the refetch.
                self.invalidateBulkGuideReuse()
                self.resetEPGRefusalLatches(forServerKey: serverID)
            }
            guard let loaded = fetchResult.loaded else {
                debugLog("📺 GuideStore.loadFromCache: no cached programs for server \(serverID)")
                self.lastLoadFromCacheResult = (serverID: serverID, isFresh: false)
                return false
            }

            // Back on the MainActor. The only remaining main-thread
            // work is the `programs` assignment (fires @Published)
            // plus two log lines. The 97k-row fetch + dict build
            // already happened off-main.
            self.commitPrograms(Self.drawableOnly(loaded.dict), for: serverID, source: "cache-load")
            // Record how old the loaded data actually is (newest cached
            // fetch), so the warm-foreground staleness check (issue #24)
            // measures the real age of what the user is looking at, not
            // just this session's network activity.
            self.newestFetchedAt = Date().addingTimeInterval(-Double(loaded.newestFetchAgoSec))
            debugLog("📺 GuideStore.loadFromCache: loaded \(loaded.programCount) programs across \(loaded.dict.count) channels (server \(serverID))")
            debugLog("📺 GuideStore.loadFromCache: newest fetch \(loaded.newestFetchAgoSec)s ago, threshold \(Int(stalenessThreshold))s, fresh=\(loaded.isFresh)")
            self.lastLoadFromCacheResult = (serverID: serverID, isFresh: loaded.isFresh)
            return loaded.isFresh
        }
        inFlightLoadTask = (serverID: serverID, task: fetchTask)
        let result = await fetchTask.value
        // Only clear if we're still the registered in-flight task
        // for this serverID. If a caller with a different serverID
        // overwrote us mid-fetch (extreme edge case — server switch
        // during initial sync), we leave their entry alone.
        if inFlightLoadTask?.serverID == serverID {
            inFlightLoadTask = nil
        }
        return result
    }

    /// User-facing cache reset. Resets the in-memory state to a
    /// pristine "no programs loaded" condition so the next
    /// `loadFromCache` call performs a real SwiftData read instead
    /// of replaying a stale idempotency entry, and so any pending
    /// in-flight loads / parses get cancelled rather than landing
    /// their results into freshly-purged state.
    ///
    /// Caller is responsible for actually clearing SwiftData (see
    /// `purgeAllPrograms(modelContext:)`). Used by:
    /// - The Settings → Guide Display → "Refresh EPG Data" action,
    ///   so users can recover from corrupted cache rows that
    ///   sometimes ship in mid-fetch interrupts (observed user
    ///   report: program cells render as 1-pixel slivers because
    ///   stop-times got truncated mid-parse, leaving rows with
    ///   ~1-minute durations).
    /// - The cache-epoch purge inside `loadFromCache`'s detached
    ///   task (which already does the SwiftData purge inline; just
    ///   calls this for the in-memory side).
    func invalidateCache() {
        programs = [:]
        lastLoadFromCacheResult = nil
        inFlightLoadTask?.task.cancel()
        inFlightLoadTask = nil
        inFlightXMLTVTask?.task.cancel()
        inFlightXMLTVTask = nil
        lastSeedEPGCacheSignature = nil
        // `programs` was just emptied; a completed-pass record claiming "these
        // channels are already merged" would be a lie until the next fetch.
        // Every current caller pairs this with forceRefresh (which also
        // clears it), but the invariant belongs HERE, not in the callers.
        lastCompletedXMLTVPass = nil
    }

    /// User-facing "nuke the EPG cache" action. Clears the in-memory
    /// state via `invalidateCache()` and deletes every `EPGProgram`
    /// row in SwiftData on a background context (matches the
    /// `pruneOrphanedEPGPrograms` pattern in `AerioApp.swift`). The
    /// `await … .value` form means callers can sequence a fresh
    /// fetch right after — typical pattern is
    /// `await purgeAllPrograms(...)` followed by
    /// `await ChannelStore.shared.forceRefresh(servers:)`.
    func purgeAllPrograms(modelContext: ModelContext) async {
        invalidateCache()
        let container = modelContext.container
        await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            let all = (try? bgContext.fetch(FetchDescriptor<EPGProgram>())) ?? []
            for ep in all { bgContext.delete(ep) }
            try? bgContext.save()
            debugLog("🗑️ User-initiated EPG cache purge: removed \(all.count) EPGProgram rows")
        }.value
    }

    /// Per-playlist EPG purge. Deletes only the `EPGProgram` rows
    /// whose `serverID` matches the given playlist UUID string, so
    /// the user can scrub a single misbehaving playlist's cached
    /// guide data without touching the others. v1.6.8: replaces
    /// the global `purgeAllPrograms` action that used to live in
    /// Settings → Appearance → EPG Cache; the per-playlist surface
    /// is `ServerDetailView`'s "EPG Cache" section.
    ///
    /// In-memory state is only flushed when the purged server is
    /// the currently-active one — `programs` is a single dictionary
    /// scoped to whichever server `ChannelStore` last loaded, so
    /// blowing it away while a different server is active would
    /// hide a fresh guide that has nothing to do with the user's
    /// purge target. Callers who need an immediate re-fetch should
    /// pair this with `ChannelStore.shared.forceRefresh(servers:)`
    /// when (and only when) the purge target is active.
    ///
    /// - Parameters:
    ///   - serverID: stringified `ServerConnection.id.uuidString`.
    ///     Matches the `EPGProgram.serverID` field written by the
    ///     normal fetch path.
    ///   - isActiveServer: callers know whether this purge applies
    ///     to the currently-loaded server; only that case wipes the
    ///     in-memory `programs` dictionary.
    ///   - modelContext: any `MainActor` context — used to grab the
    ///     `ModelContainer` so the actual delete can run on a
    ///     background context.
    func purgePrograms(
        for serverID: String,
        isActiveServer: Bool,
        modelContext: ModelContext
    ) async {
        if isActiveServer {
            invalidateCache()
        }
        let container = modelContext.container
        await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            let predicate = #Predicate<EPGProgram> { $0.serverID == serverID }
            let descriptor = FetchDescriptor<EPGProgram>(predicate: predicate)
            let matched = (try? bgContext.fetch(descriptor)) ?? []
            for ep in matched { bgContext.delete(ep) }
            try? bgContext.save()
            debugLog("🗑️ Per-playlist EPG cache purge (server=\(serverID)): removed \(matched.count) EPGProgram rows")
        }.value
    }

    /// Save current programs to SwiftData for persistent caching.
    /// Runs on a background ModelContext (Task.detached) to avoid blocking the main thread.
    /// For 4000+ programs, a main-thread save can cause a 700ms+ hang.
    func saveToCache(modelContext: ModelContext, serverID: String) {
        let container = modelContext.container
        // Snapshot the programs dictionary on the main actor before detaching
        let snapshot = programs
        // NEVER let an empty guide reach the cache. The save below deletes
        // every future row for this server before re-inserting, so writing an
        // empty snapshot destroys a good on-disk guide and leaves the next
        // launch with nothing to paint. In-memory guards keep `programs` from
        // being emptied by a failed fetch in the first place; this is the last
        // line before the data is gone for good.
        guard snapshot.contains(where: { !$0.value.isEmpty }) else {
            debugLog("📺 GuideStore: skipped saveToCache — nothing to save (refusing to blank the cache)")
            return
        }
        // Catch-up: retained-history horizon (read on the main actor; the
        // detached save below must not touch ChannelStore). The retention
        // horizon superseded the old epgWindowHours trim in this save.
        let retentionSecs = GuideStore.activeRetentionSeconds()

        // Invalidate the loadFromCache idempotency cache — a fresh
        // network fetch is landing, so the next loadFromCache caller
        // should re-read SwiftData and observe the updated fetchedAt
        // (which will flip `fresh=true`). Runs synchronously on the
        // MainActor before the detached save so there's no race
        // between a subsequent caller and the stale cached verdict.
        lastLoadFromCacheResult = nil

        Task.detached(priority: .utility) {
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false

            let now = Date()
            // Catch-up: aired programmes are the archive the Watch action
            // hangs off, so the old ended-1h-ago purge becomes a retention
            // prune (Edit Server > Guide History, default 7 days).
            let retentionCutoff = now.addingTimeInterval(-retentionSecs)
            let staleDescriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> { $0.endTime < retentionCutoff }
            )
            if let stale = try? bgContext.fetch(staleDescriptor) {
                for s in stale { bgContext.delete(s) }
            }

            // The fresh snapshot owns the PRESENT AND FUTURE outright:
            // delete that region and re-insert. Already-aired rows are
            // left in place so history accumulates across refreshes
            // (feeds trim their own history between refreshes; deleting
            // the snapshot window used to erase recently-ended shows the
            // feed no longer carried -- the AerioTV-Android data-loss
            // bug, fixed there in DB v20 and mirrored here).
            let existingDescriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> {
                    $0.serverID == serverID && $0.endTime > now
                }
            )
            if let existing = try? bgContext.fetch(existingDescriptor) {
                for e in existing { bgContext.delete(e) }
            }

            // Dedup guard for the PAST region: the in-memory snapshot also
            // carries history (merged from this same cache), so inserting
            // it blindly would duplicate retained rows. SwiftData has no
            // unique index, so skip past inserts whose (channel, start)
            // already exists.
            var pastKeys = Set<String>()
            let pastDescriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> {
                    $0.serverID == serverID && $0.endTime <= now && $0.endTime > retentionCutoff
                }
            )
            if let pastRows = try? bgContext.fetch(pastDescriptor) {
                for r in pastRows {
                    pastKeys.insert("\(r.channelID)|\(Int(r.startTime.timeIntervalSince1970))")
                }
            }

            // Insert current programs (future always; past only when new)
            var count = 0
            for (channelID, progs) in snapshot {
                for gp in progs {
                    if gp.end <= now {
                        let key = "\(channelID)|\(Int(gp.start.timeIntervalSince1970))"
                        if pastKeys.contains(key) { continue }
                        if gp.end <= retentionCutoff { continue }
                        pastKeys.insert(key)
                    }
                    // v1.7.x: persist `programID` so cold-launch
                    // Program Info lazy-load survives the cache hit.
                    let ep = EPGProgram(channelID: channelID, title: gp.title,
                                        description: gp.description,
                                        startTime: gp.start, endTime: gp.end,
                                        category: gp.category, serverID: serverID,
                                        programID: gp.programID,
                                        subTitle: gp.subTitle, season: gp.season,
                                        episode: gp.episode, isNew: gp.isNew,
                                        isLiveBroadcast: gp.isLiveBroadcast,
                                        isPremiere: gp.isPremiere, isFinale: gp.isFinale,
                                        isRepeat: gp.isRepeat)
                    bgContext.insert(ep)
                    count += 1
                }
            }
            try? bgContext.save()
            debugLog("📺 GuideStore.saveToCache: saved \(count) programs for server \(serverID) (background)")
        }
    }

    /// Phase 1 — instant: build guide rows from data that's already in memory.
    func seedFromChannels(_ channels: [ChannelDisplayItem]) {
        var result: [String: [GuideProgram]] = programs // preserve cached data
        var mutated = false
        for ch in channels {
            guard let title = ch.currentProgram, !title.isEmpty,
                  let start = ch.currentProgramStart,
                  let end = ch.currentProgramEnd else { continue }
            let desc = ch.currentProgramDescription ?? ""
            let gp = GuideProgram(channelID: ch.id, title: title,
                                  description: desc, start: start, end: end, category: "")
            if result[ch.id] == nil || result[ch.id]?.isEmpty == true {
                // No programs yet for this channel — seed it
                result[ch.id] = [gp]
                mutated = true
            } else if !desc.isEmpty, var list = result[ch.id] {
                // Channel has programs but check if current one is missing its description
                var updated = false
                for i in list.indices {
                    if list[i].title == title
                        && abs(list[i].start.timeIntervalSince(start)) < 60
                        && list[i].description.isEmpty {
                        list[i] = gp
                        updated = true
                    }
                }
                if updated {
                    result[ch.id] = list
                    mutated = true
                }
            }
        }
        // Only fire @Published if we actually changed anything. On
        // warm relaunch where loadFromCache already populated 97k
        // programs with descriptions, the loop above does nothing
        // useful — but the unconditional `programs = result`
        // re-assignment still triggers SwiftUI invalidations on
        // three observers (MainTabView, EPGGuideView,
        // ChannelListView). Skipping the assignment when nothing
        // changed eliminates that spurious re-render.
        if mutated {
            programs = result
        }
    }

    /// Drops programs that ended more than an hour ago and empties their
    /// channel keys, so the resident `programs` dict tracks the live window
    /// instead of accumulating every aired program for the process lifetime
    /// (audit P1 — the dominant steady-state EPG memory cost on Apple TV; the
    /// SwiftData cache already purges `endTime < hourAgo`, this mirrors it in
    /// memory). Only mutates @Published state when something was actually
    /// removed, so a no-op foreground doesn't churn the guide. Aired programs
    /// sit below "now" in the grid and are never visible, so the trim is
    /// invisible to the user. Runs on warm foreground.
    /// Catch-up (task: Android parity): how many days of ALREADY-AIRED
    /// programming the active server keeps (Edit Server > Guide History,
    /// default 7, clamped 1...30 to match the Dispatcharr server cap).
    /// Everything that used to hard-code the 1-hour history horizon now
    /// derives from this so aired programmes stay replayable.
    static func activeRetentionDays() -> Int {
        let d = ChannelStore.shared.activeServer?.epgRetentionDays ?? 7
        return min(max(d, 1), 30)
    }

    static func activeRetentionSeconds() -> TimeInterval {
        TimeInterval(activeRetentionDays()) * 86_400
    }

    func trimExpiredPrograms() {
        let cutoff = Date().addingTimeInterval(-GuideStore.activeRetentionSeconds())
        var trimmed: [String: [GuideProgram]] = [:]
        var removedAny = false
        for (channelID, list) in programs {
            let kept = list.filter { $0.end >= cutoff }
            if kept.count != list.count { removedAny = true }
            if !kept.isEmpty { trimmed[channelID] = kept }
        }
        guard removedAny else { return }
        let total = trimmed.values.reduce(0) { $0 + $1.count }
        programs = trimmed
        debugLog("📺 GuideStore.trimExpiredPrograms: trimmed resident EPG to live window — \(total) programs across \(trimmed.count) channels")
    }

    /// Phase 2 — async: fetch upcoming programs to fill in the timeline beyond "now playing."
    /// Loads an initial batch quickly, then backfills remaining channels at lower priority.
    @discardableResult
    func fetchUpcoming(
        channels: [ChannelDisplayItem],
        servers: [ServerConnection],
        replaceExisting: Bool = false
    ) async -> Bool {
        guard !isLoading else {
            debugLog("📺 GuideStore.fetchUpcoming: already loading, skipping")
            return false
        }
        isLoading = true
        // Previously the only `isLoading = false` assignment was on
        // the "no server found" early-return path. The normal happy
        // path fell through without resetting the flag, which meant
        // subsequent `fetchUpcoming` calls (tab switch, pull-to-
        // refresh, iCloud sync triggering a channels refresh) would
        // hit the guard above and no-op forever. It also kept the
        // "Syncing…" indicator pinned and the initial-sync loading
        // cover waiting indefinitely.
        defer { isLoading = false }

        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        // Use the user's EPG window setting (default 36 hours).
        // 0 means "All available" — use 14 days as a practical maximum.
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36
        let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)

        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else {
            debugLog("📺 GuideStore.fetchUpcoming: no server found")
            return false  // `defer` above resets isLoading
        }
        debugLog("📺 GuideStore.fetchUpcoming: server=\(server.name), type=\(server.type), channels=\(channels.count)")
        beginDisplaying(serverID: server.id.uuidString)

        let didRefresh: Bool
        switch server.type {
        case .dispatcharrAPI:
            // Dispatcharr: bulk fetch ALL programs at once (no batching needed).
            // getCurrentPrograms + getBulkUpcomingPrograms handles everything.
            didRefresh = await fetchDispatcharr(
                server: server,
                channels: channels,
                windowStart: windowStart,
                windowEnd: windowEnd,
                replaceExisting: replaceExisting
            )
            // Catch-up depth: after the grid lands, layer the server's
            // own upstream XMLTV sources for deep history. Runs OUTSIDE
            // fetchDispatcharr because its beginBatch/endBatch must
            // commit before fetchXMLTVFromURL writes `programs` (a
            // write between begin and end would be lost to the batch
            // re-assignment).
            //
            // NOT awaited (Discord reports 2026-08-08, verified against an
            // affected server): awaiting here held fetchUpcoming - and the
            // sync indicator, and the guide's first paint on a cold cache -
            // hostage to downloads of multi-hundred-MB national XMLTV feeds.
            // The grid is already committed at this point; the layering only
            // ADDS history, and fetchXMLTVFromURL merges into `programs`
            // per-source, so detaching changes nothing about correctness,
            // only about who waits. Android shipped the same restructure
            // (grid in 4.1s, 31,625 history rows merged 104s later in
            // background, measured on the affected server).
            if !upstreamLayeringInFlight {
                upstreamLayeringInFlight = true
                Task { [weak self] in
                    guard let self else { return }
                    await self.layerDispatcharrUpstreamSources(
                        server: server,
                        channels: channels,
                        windowEnd: windowEnd
                    )
                    self.upstreamLayeringInFlight = false
                }
            }
        case .xtreamCodes:
            // ONE request covers the whole playlist, so ask for the whole
            // playlist once. This used to be batched (40, then 20 at a time),
            // and because the bulk-XMLTV attempt lived inside the per-batch
            // function, every batch re-downloaded and re-parsed the provider's
            // complete guide. See `fetchXtreamBulkXMLTV` for the measurements.
            var didReceiveAnyResponse = await fetchXtreamBulkXMLTV(
                server: server,
                channels: channels,
                windowStart: windowStart,
                windowEnd: windowEnd,
                replaceExisting: replaceExisting
            )

            // Only when the provider has no usable bulk guide: walk channels
            // individually via get_short_epg. Also unbatched, for a different
            // reason — the walk latches itself off after one run per session
            // (`xtreamFallbackExhausted`), so under the old batching only the
            // FIRST batch ever ran and the remaining batches no-opped. Passing
            // the full list means the walk's own 300-channel cap decides the
            // coverage instead of an arbitrary first-40, which is strictly more
            // EPG for the same request budget.
            if !didReceiveAnyResponse {
                didReceiveAnyResponse = await fetchXtream(
                    server: server,
                    channels: channels,
                    windowStart: windowStart,
                    windowEnd: windowEnd,
                    replaceExisting: replaceExisting
                )
            }
            didRefresh = didReceiveAnyResponse
        case .m3uPlaylist:
            didRefresh = await fetchXMLTV(
                server: server,
                channels: channels,
                windowStart: windowStart,
                windowEnd: windowEnd,
                replaceExisting: replaceExisting
            )
        }

        // Log final state
        let totalPrograms = programs.values.reduce(0) { $0 + $1.count }
        let channelsWithMultiple = programs.values.filter { $0.count > 1 }.count
        debugLog("📺 GuideStore done: \(totalPrograms) programs across \(programs.count) channels, \(channelsWithMultiple) channels have >1 program")
        // A real network refresh landed, so the loaded data is current as of
        // `now`. Resets the warm-foreground staleness clock (issue #24).
        // Guarded on display ownership: a fetch whose merge was discarded
        // because the user switched playlists mid-flight reports true (to
        // suppress the backstop) but refreshed nothing the user can see, and
        // must not mark the NEW playlist's guide as fresh.
        if didRefresh, displayedServerID == server.id.uuidString { newestFetchedAt = now }
        return didRefresh
    }

    // MARK: - Dispatcharr
    private func fetchDispatcharr(server: ServerConnection, channels: [ChannelDisplayItem],
                                   windowStart: Date, windowEnd: Date,
                                   replaceExisting: Bool = false) async -> Bool {
        // v1.6.22: use Dispatcharr's REST API exclusively. The
        // previous `{baseURL}/output/epg` XMLTV path was attractive
        // because it included `<category>` tags, but it's:
        //   1. Not part of Dispatcharr's documented API surface.
        //   2. Gated by a LAN-only network access policy by default
        //      since Dispatcharr 0.23.0 (commit 3c55649, Feb 2026).
        //      Every WAN / Cloudflare / Synology QuickConnect user
        //      gets HTTP 403 on the public hostname.
        //   3. A separate Django view from `/api/*`, with its own
        //      auth model. Using it meant maintaining two access
        //      paths to the same underlying data.
        // The `/api/epg/grid/` JSON endpoint covers programs+timing
        // for every Dispatcharr deployment regardless of network
        // policy. Categories are missing from the bulk grid response
        // (server-side serializer omission, ProgramData.custom_properties
        // has them but the hand-rolled grid view drops them; see
        // `apps/epg/api_views.py`'s EPGGridAPIView). Acceptable
        // trade-off: programs render universally, categories can be
        // lazily backfilled per visible cell via /api/epg/programs/<id>/
        // in a future pass if the visual loss matters.

        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                  auth: .apiKey(server.effectiveApiKey),
                                  userAgent: server.effectiveUserAgent,
                                  authMode: server.dispatcharrHeaderMode,
                                  serverID: server.id,
                                  savedUsername: server.dispatcharrCredentialType == .usernamePassword
                                      ? server.username : nil)
        let categoryServerID = server.id.uuidString
        debugLog("📺 [EPG source=dispatcharr-api grid] server=\(server.name)")

        // v1.6.22: honor user-provided XMLTV override URL if set.
        // The auto-derived `/output/epg` fallback is gone, but power
        // users who have a reachable XMLTV source can opt in via
        // Settings → Custom XMLTV URL to pick up `<category>` data
        // the bulk grid omits. We layer the XMLTV merge on top of
        // the REST grid below so categories enrich the same dict.
        let explicitXMLTV = server.dispatcharrXMLTVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var didLoadXMLTVOverride = false
        if !explicitXMLTV.isEmpty, let xmltvURL = URL(string: explicitXMLTV) {
            debugLog("📺 [EPG source=dispatcharr-api grid + xmltv-override] server=\(server.name) override=\(xmltvURL.host ?? "?")")
            didLoadXMLTVOverride = await fetchXMLTVFromURL(
                url: xmltvURL,
                channels: channels,
                windowStart: windowStart,
                windowEnd: windowEnd,
                headers: api.streamAuthHeaders,
                categoryServerID: categoryServerID,
                replaceExisting: replaceExisting
            )
            // Fall through to bulk grid below: the merge dedupes by
            // (channel, time) so the REST data fills any gaps the
            // override XMLTV missed.
        }

        let batchBasePrograms: [String: [GuideProgram]]? = {
            guard replaceExisting else { return nil }
            guard !didLoadXMLTVOverride else { return programs }
            return replacingWindowBase(for: channels, windowStart: windowStart, windowEnd: windowEnd)
        }()
        beginBatch(basePrograms: batchBasePrograms)
        var shouldCommitBatch = false
        let batchServerID = server.id.uuidString
        defer {
            if shouldCommitBatch {
                endBatch(for: batchServerID, source: "dispatcharr-grid")
            } else {
                cancelBatch()
            }
        }

        // v1.6.22: fetch the EPGData lookup so we can bridge
        // `Channel.epg_data_id → EPGData.tvg_id` when
        // `Channel.tvg_id` doesn't match how the bulk grid keys
        // programs. About 25% of channels on a real Dispatcharr
        // instance have mismatched ids (EPGData is set at XMLTV
        // ingest, Channel.tvg_id is user-configurable). Without
        // this, those channels appear blank in the guide. Failure
        // is non-fatal: an empty map degrades to today's behavior.
        var epgDataIDToTvgID: [Int: String] = [:]
        do {
            epgDataIDToTvgID = try await api.getAllEPGData()
            debugLog("📺 Dispatcharr: fetched epg_data_id → tvg_id map (\(epgDataIDToTvgID.count) rows)")
        } catch {
            debugLog("📺 Dispatcharr: epg_data_id map fetch failed (\(error.localizedDescription)); channels with mismatched tvg_id won't be bridged")
        }

        // Build tvgID ↔ channelID mapping (case-insensitive keys for matching).
        // Includes BOTH the channel's own tvg_id AND its bridged
        // EPGData.tvg_id (via Channel.epg_data_id) so the program
        // match loop below resolves either casing in a single
        // dictionary lookup.
        //
        // v1.7.3 (Issue #20, jdfrey1 2026-05-16): value type is
        // `[String]` rather than `String` so a tvg-id shared by
        // multiple channels (e.g. Teamarr's multi-source channels
        // for one game: Arsenal-1, Arsenal-2, Arsenal-3 all
        // pointing at one EPG entry) routes the matched programs
        // to EVERY channel that shares the tvg-id, not just one
        // winner. The previous `[String: String]` collapsed shared
        // tvg-ids to whichever channel was iterated last, leaving
        // the others with no Guide programs.
        var tvgIDToChannelIDsBuild: [String: [String]] = [:]
        for ch in channels {
            guard let tvg = ch.tvgID, !tvg.isEmpty else { continue }
            let key = tvg.lowercased()
            if tvgIDToChannelIDsBuild[key]?.contains(ch.id) != true {
                tvgIDToChannelIDsBuild[key, default: []].append(ch.id)
            }
        }
        var bridgedEntryCount = 0
        for ch in channels {
            guard let epgID = ch.dispatcharrEPGDataID,
                  let bridgedTvgID = epgDataIDToTvgID[epgID],
                  !bridgedTvgID.isEmpty else { continue }
            let key = bridgedTvgID.lowercased()
            if tvgIDToChannelIDsBuild[key]?.contains(ch.id) != true {
                tvgIDToChannelIDsBuild[key, default: []].append(ch.id)
                bridgedEntryCount += 1
            }
        }
        if bridgedEntryCount > 0 {
            debugLog("📺 Dispatcharr: bridged \(bridgedEntryCount) channels via epg_data_id → EPGData.tvg_id")
        }
        let tvgIDToChannelIDs = tvgIDToChannelIDsBuild
        // Also build channel int ID → display ID mapping for fallback
        let intIDToChannelID: [Int: String] = Dictionary(
            channels.compactMap { ch in
                guard let intID = Int(ch.id) else { return nil }
                return (intID, ch.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // THIRD key: channel UUID → display ID. Dispatcharr's Dummy
        // EPG feature (custom-pattern + standard no-EPG fallback)
        // synthesizes program entries whose `tvg_id` is NOT the
        // channel's real tvg_id but the channel's UUID string
        // (`str(channel.uuid)` in Dispatcharr's Python source — see
        // `apps/epg/api_views.py::EPGGridAPIView`). Without this
        // mapping, every channel relying on Dummy EPG would appear
        // blank in the Aerio guide because the first-pass
        // `tvgIDToChannelIDs` lookup misses and the `intIDToChannelID`
        // fallback runs only when `prog.tvg_id` is absent. Lowercase
        // both sides for consistency with the tvgID map.
        let uuidToChannelID: [String: String] = Dictionary(
            channels.compactMap { ch in
                guard let u = ch.uuid, !u.isEmpty else { return nil }
                return (u.lowercased(), ch.id)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Try the EPG grid endpoint first — returns -1h to +24h in one request with
        // synthetic dummy programs for channels without EPG data.
        #if DEBUG
        debugLog("📺 Dispatcharr: fetching EPG grid, tvgID map has \(tvgIDToChannelIDs.count) entries, intID map has \(intIDToChannelID.count) entries, uuid map has \(uuidToChannelID.count) entries")
        #endif
        do {
            let gridPrograms = try await api.getEPGGrid()
            #if DEBUG
            debugLog("📺 Dispatcharr: EPG grid returned \(gridPrograms.count) programs")
            #endif
            // v1.7.x: run the grid match+merge OFF the main actor. This
            // ~7000-iteration loop (per-program dedup scan + sort) previously
            // ran on the @MainActor and was the dominant cold-start hang
            // (watchdog ~900ms+, plus part of the 2.5s hang). It mirrors the
            // proven off-main XMLTV merge (performXMLTVFetch): build a LOCAL
            // dict seeded from the current batch base, merge via the nonisolated
            // GuideStore.mergeProgramInto(deferSort: true), sort each touched
            // list ONCE at the end, then do a single @Published write. The cids
            // match logic below (Issue #20 shared-tvg-id fan-out, Dummy-EPG UUID
            // key, and intID fallback) is byte-identical to the prior on-main
            // version; only the thread changed. `_pendingPrograms` was seeded
            // by beginBatch above; assigning the merged result back lets the
            // existing `defer`/endBatch commit it with one invalidation.
            let base = _pendingPrograms
            let merged: (dict: [String: [GuideProgram]], matched: Int, viaUUID: Int) =
                await Task.detached(priority: .userInitiated) {
                    var dict = base
                    var matched = 0
                    var viaUUID = 0
                    var touched = Set<String>()
                    for prog in gridPrograms {
                        guard let start = prog.startTime?.toDate(),
                              let end = prog.endTime?.toDate(),
                              end > windowStart && start < windowEnd else { continue }
                        let cids: [String]
                        if let tvg = prog.tvgID, !tvg.isEmpty {
                            let key = tvg.lowercased()
                            if let arr = tvgIDToChannelIDs[key], !arr.isEmpty {
                                cids = arr
                            } else if let cid = uuidToChannelID[key] {
                                // Dummy EPG entry; the `tvg_id` IS the channel UUID.
                                cids = [cid]
                                viaUUID += 1
                            } else {
                                cids = []
                            }
                        } else if let chInt = prog.channel, let cid = intIDToChannelID[chInt] {
                            cids = [cid]
                        } else {
                            cids = []
                        }
                        if cids.isEmpty { continue }
                        matched += 1
                        let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                        // thread `programID` so ProgramInfoView can lazy-load
                        // `<category>` via /api/epg/programs/<id>/.
                        for cid in cids {
                            let gp = GuideProgram(channelID: cid, title: prog.title,
                                                  description: desc, start: start, end: end,
                                                  category: "", programID: prog.programID,
                                                  subTitle: prog.subTitle.isEmpty ? nil : prog.subTitle,
                                                  season: prog.season, episode: prog.episode,
                                                  isNew: prog.isNew, isLiveBroadcast: prog.isLiveBroadcast,
                                                  isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                                                  isRepeat: prog.isRepeat)
                            GuideStore.mergeProgramInto(&dict, program: gp, for: cid, deferSort: true)
                            touched.insert(cid)
                        }
                    }
                    // deferSort:true above; sort each touched list once.
                    for cid in touched { dict[cid]?.sort { $0.start < $1.start } }
                    return (dict, matched, viaUUID)
                }.value
            _pendingPrograms = merged.dict
            let matched = merged.matched
            let matchedViaUUID = merged.viaUUID
            #if DEBUG
            debugLog("📺 Dispatcharr: EPG grid matched \(matched) programs to channels (\(matchedViaUUID) via Dummy EPG UUID key)")
            #endif

            // v1.6.22: API-only category enrichment for Guide cells
            // and Live-TV cards. Walks the gridPrograms we just
            // merged, identifies the currently-airing program per
            // channel, fans out `/api/epg/programs/<id>/` (the only
            // REST endpoint with categories), throttles at cap-of-4,
            // applies results to BOTH `GuideStore.programs[cid]`
            // (the matching airing GuideProgram's `category` for
            // grid cell tinting) AND `ChannelStore.applyXMLTVCategories`
            // (channel card stripe). API-only. No XMLTV stream.
            //
            // Fire-and-forget: don't block the Guide tab from
            // becoming interactive on the enrichment fan-out (which
            // can be 300+ requests, several seconds of background
            // work even on a healthy server). The Guide cells render
            // with grid data immediately; categories tint in
            // progressively as detail responses land.
            Task { [self] in
                await self.enrichDispatcharrCategories(gridPrograms: gridPrograms,
                                                        api: api,
                                                        tvgIDToChannelIDs: tvgIDToChannelIDs,
                                                        uuidToChannelID: uuidToChannelID,
                                                        serverID: categoryServerID)
            }

            // An empty grid is a failed fetch, not an empty guide: leave
            // shouldCommitBatch false so cancelBatch discards the pending
            // (window-stripped) dict, and report failure so the caller runs its
            // fallback instead of treating the blank as fresh data.
            guard !gridPrograms.isEmpty else {
                debugLog("📺 Dispatcharr: EPG grid returned 0 programmes — discarding batch, falling back")
                return false
            }
            shouldCommitBatch = true
            return true // Grid endpoint succeeded — no need for fallback
        } catch {
            #if DEBUG
            debugLog("📺 Dispatcharr: EPG grid failed (\(error)), falling back to current+bulk approach")
            #endif
        }

        // Fallback: getCurrentPrograms + getBulkUpcomingPrograms (for older Dispatcharr versions
        // that may not have the /api/epg/grid/ endpoint)
        var didFetchFallback = false
        if let current = try? await api.getCurrentPrograms() {
            didFetchFallback = true
            for prog in current {
                guard let start = prog.startTime?.toDate(),
                      let end = prog.endTime?.toDate(),
                      end > windowStart && start < windowEnd else { continue }
                // v1.7.3 (Issue #20): tvg-id may match multiple
                // channels; fan the program out to every matched cid.
                let cids: [String]
                if let tvg = prog.tvgID, !tvg.isEmpty {
                    let key = tvg.lowercased()
                    if let arr = tvgIDToChannelIDs[key], !arr.isEmpty {
                        cids = arr
                    } else if let cid = uuidToChannelID[key] {
                        cids = [cid]
                    } else {
                        cids = []
                    }
                } else if let chInt = prog.channel, let cid = intIDToChannelID[chInt] {
                    cids = [cid]
                } else {
                    cids = []
                }
                if cids.isEmpty { continue }
                let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                for cid in cids {
                    let gp = GuideProgram(channelID: cid, title: prog.title,
                                          description: desc, start: start, end: end,
                                          category: "", programID: prog.programID,
                                          subTitle: prog.subTitle.isEmpty ? nil : prog.subTitle,
                                          season: prog.season, episode: prog.episode,
                                          isNew: prog.isNew, isLiveBroadcast: prog.isLiveBroadcast,
                                          isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                                          isRepeat: prog.isRepeat)
                    mergeProgram(gp, for: cid)
                }
            }
        }

        // Bulk fetch upcoming programs as supplement
        if let allPrograms = try? await api.getBulkUpcomingPrograms(maxPages: 10) {
            didFetchFallback = true
            for prog in allPrograms {
                guard let start = prog.startTime?.toDate(),
                      let end = prog.endTime?.toDate(),
                      end > windowStart && start < windowEnd else { continue }
                // v1.7.3 (Issue #20): tvg-id may match multiple
                // channels; fan the program out to every matched cid.
                let cids: [String]
                if let tvg = prog.tvgID, !tvg.isEmpty {
                    let key = tvg.lowercased()
                    if let arr = tvgIDToChannelIDs[key], !arr.isEmpty {
                        cids = arr
                    } else if let cid = uuidToChannelID[key] {
                        cids = [cid]
                    } else {
                        cids = []
                    }
                } else if let chInt = prog.channel, let cid = intIDToChannelID[chInt] {
                    cids = [cid]
                } else {
                    cids = []
                }
                if cids.isEmpty { continue }
                let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                for cid in cids {
                    let gp = GuideProgram(channelID: cid, title: prog.title,
                                          description: desc, start: start, end: end,
                                          category: "", programID: prog.programID,
                                          subTitle: prog.subTitle.isEmpty ? nil : prog.subTitle,
                                          season: prog.season, episode: prog.episode,
                                          isNew: prog.isNew, isLiveBroadcast: prog.isLiveBroadcast,
                                          isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                                          isRepeat: prog.isRepeat)
                    mergeProgram(gp, for: cid)
                }
            }
        }

        let didRefresh = didLoadXMLTVOverride || didFetchFallback
        shouldCommitBatch = didRefresh
        return didRefresh
    }

    /// Catch-up depth: Dispatcharr's grid only retains a couple of days
    /// of already-aired programming, so Direct Connect users could not
    /// browse catch-up content older than that even when Guide History
    /// (Edit Server) allows up to 30 days. The server knows where its
    /// guide comes from though: `/api/epg/sources/` lists the XMLTV
    /// feeds assigned to channels, and those upstream feeds usually
    /// carry a much deeper past window. Fetch each active xmltv source
    /// directly and layer it on the already-merged grid exactly like
    /// the manual Custom XMLTV URL override, but with a retention-deep
    /// windowStart so history actually survives the merge's time
    /// filter. The bridged `epg_data_id -> EPGData.tvg_id` keys are
    /// passed through because upstream feeds key programmes by exactly
    /// those ids, which routinely differ from a channel's own tvg_id.
    ///
    /// Per-source failures are silent: sources that point at LAN-only
    /// paths or file mounts on the server simply are not reachable from
    /// the app, and the grid data the user already has is never at
    /// risk. No Dispatcharr auth headers are sent to these URLs (they
    /// are third-party providers; the API key must not leak to them).
    private func layerDispatcharrUpstreamSources(server: ServerConnection,
                                                 channels: [ChannelDisplayItem],
                                                 windowEnd: Date) async {
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                  auth: .apiKey(server.effectiveApiKey),
                                  userAgent: server.effectiveUserAgent,
                                  authMode: server.dispatcharrHeaderMode,
                                  serverID: server.id,
                                  savedUsername: server.dispatcharrCredentialType == .usernamePassword
                                      ? server.username : nil)
        let sources: [DispatcharrEPGSource]
        do {
            sources = try await api.getEPGSources()
        } catch {
            debugLog("📺 Dispatcharr upstream-source list failed (\(error.localizedDescription)); catch-up depth stays grid-only")
            return
        }
        let explicit = server.dispatcharrXMLTVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let candidates: [(sourceID: Int, url: URL)] = sources.compactMap { src in
            guard src.isActive ?? true,
                  src.sourceType == "xmltv",
                  src.hasChannels != false,
                  let raw = src.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, raw != explicit,
                  let u = URL(string: raw),
                  let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seen.insert(raw).inserted else { return nil }
            return (src.id, u)
        }
        guard !candidates.isEmpty else { return }
        // GH #53: scope every feed to the channels Dispatcharr actually
        // sourced FROM it. Previously all channels and all bridged keys went
        // to every feed, so two providers reusing one tvg-id (common; the
        // value is a broadcaster string, not a GUID) both wrote into the same
        // channel. That is the second half of the FANSEAT report: named
        // matches belonging to sibling channels turning up on `120 1`.
        //
        // Each EPGData row names both its tvg_id and its source, so
        // source -> channels falls straight out of /api/epg/epgdata/. If that
        // call fails there is nothing to scope BY, and layering wholesale is
        // what caused the bug, so skip the pass entirely: this is bonus
        // catch-up depth, never the user's guide.
        guard let epgRows = try? await api.getAllEPGDataRows() else {
            debugLog("📺 Dispatcharr upstream layering: epgdata unavailable, cannot scope feeds; skipping")
            return
        }
        var sourceIDByEPGDataID: [Int: Int] = [:]
        var tvgIDByEPGDataID: [Int: String] = [:]
        for row in epgRows where !row.tvgID.isEmpty {
            tvgIDByEPGDataID[row.id] = row.tvgID
            if let src = row.epgSource { sourceIDByEPGDataID[row.id] = src }
        }
        var channelsBySource: [Int: [ChannelDisplayItem]] = [:]
        var bridgedBySource: [Int: [String: [String]]] = [:]
        for ch in channels {
            guard let epgID = ch.dispatcharrEPGDataID,
                  let sourceID = sourceIDByEPGDataID[epgID],
                  let tvg = tvgIDByEPGDataID[epgID], !tvg.isEmpty else { continue }
            channelsBySource[sourceID, default: []].append(ch)
            let key = tvg.lowercased()
            if bridgedBySource[sourceID]?[key]?.contains(ch.id) != true {
                bridgedBySource[sourceID, default: [:]][key, default: []].append(ch.id)
            }
        }
        let urls = candidates.filter { channelsBySource[$0.sourceID]?.isEmpty == false }
        guard !urls.isEmpty else {
            debugLog("📺 Dispatcharr upstream layering: no feed supplies any loaded channel; nothing to layer")
            return
        }
        let historyStart = Date().addingTimeInterval(-GuideStore.activeRetentionSeconds())
        // Android's identical loop caused the 2026-08-08 Discord report: every
        // EPG load downloaded up to EIGHT full upstream XMLTV feeds with no
        // ceiling, so on a server whose feeds are large or slow the guide never
        // populated and sat "syncing" forever. This is BONUS history, never the
        // user's guide, so it runs on a strict budget: fewer sources, a ceiling
        // per source, and a whole-phase deadline checked between sources.
        let deadline = Date().addingTimeInterval(Self.upstreamEPGTotalBudget)
        var layered = 0
        for (sourceID, url) in urls.prefix(Self.maxUpstreamEPGSources) {
            if Date() >= deadline {
                debugLog("📺 upstream-source layering: budget spent after \(layered) source(s); skipping \(min(urls.count, Self.maxUpstreamEPGSources) - layered) more")
                break
            }
            let scopedChannels = channelsBySource[sourceID] ?? []
            debugLog("📺 [EPG source=dispatcharr upstream-source] host=\(url.host ?? "?") scopedChannels=\(scopedChannels.count) historyDays=\(GuideStore.activeRetentionDays())")
            // Per-source ceiling: one enormous or stalled feed must not hold the
            // grid (which the user already has) hostage behind it.
            let sourceTask = Task {
                // GH #53: scopedChannels, not every channel. The channel maps
                // fetchXMLTVFromURL builds (tvg-id, number, UUID) are derived
                // from this list, so a duplicate tvg-id in an unrelated feed
                // has no channel here to land on.
                await fetchXMLTVFromURL(url: url,
                                        channels: scopedChannels,
                                        windowStart: historyStart,
                                        windowEnd: windowEnd,
                                        extraTVGIDs: bridgedBySource[sourceID] ?? [:],
                                        categoryServerID: server.id.uuidString,
                                        replaceExisting: false)
            }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Self.upstreamEPGPerSource))
                if !sourceTask.isCancelled {
                    debugLog("📺 upstream-source \(url.host ?? "?") exceeded \(Int(Self.upstreamEPGPerSource))s; skipping it")
                    sourceTask.cancel()
                }
            }
            await sourceTask.value
            watchdog.cancel()
            layered += 1
        }
    }

    /// True while a background upstream-layering pass is running. A refresh
    /// mid-pass must not start a second one: the feeds are identical and the
    /// downloads are enormous.
    private var upstreamLayeringInFlight = false

    /// Upstream Dispatcharr XMLTV feeds layered for catch-up depth (task #210).
    /// Was 8. Each is a FULL XMLTV download on every EPG load, and the value of
    /// the fourth feed is negligible next to the cost of fetching it.
    private static let maxUpstreamEPGSources = 3
    /// Ceiling on ONE upstream feed.
    private static let upstreamEPGPerSource: TimeInterval = 90
    /// Ceiling on the whole layering phase; past this the grid ships as-is.
    private static let upstreamEPGTotalBudget: TimeInterval = 180

    // MARK: - Xtream Codes

    /// Servers whose per-channel EPG fallback has already been run to
    /// exhaustion this session, and must not be run again.
    ///
    /// The cap and the circuit breaker each bound ONE pass. They do not bound
    /// how many passes happen, and that turned out to be the real multiplier:
    /// measured on an iPhone 2026-08-11, the breaker fired 46 times in a single
    /// session and 5,374 get_short_epg requests still went out, because the
    /// guide re-enters this path on every repaint / group change / refresh.
    /// A provider that has no usable per-stream EPG will not grow one thirty
    /// seconds later, so the answer is remembered per server for the life of
    /// the process. Static (not @State) so it survives the view being torn
    /// down and rebuilt, which is exactly what was re-arming it.
    private static var xtreamFallbackExhausted = Set<String>()
    /// Servers whose bulk xmltv.php answered with a definitive refusal.
    /// 403 is not a transient error and re-asking 155 times in one session
    /// (measured, same device) is indistinguishable from an attack.
    private static var xmltvRefused = Set<String>()

    /// Standard XC EPG: the server's bulk `xmltv.php` guide (full programmes,
    /// server-native naming + categories), matched by tvg-id through the same
    /// XMLTV path M3U uses. XC channels carry their epg_channel_id as tvgID
    /// (`ChannelStore.fetchXtream`).
    ///
    /// SEPARATE from the per-stream fallback below, and that separation is the
    /// whole point. One `xmltv.php` request returns the programmes for the
    /// ENTIRE playlist, so it is a whole-playlist operation that must run once.
    /// It used to live at the top of the per-channel function, which
    /// `fetchUpcoming` called once per 20-channel batch — so a single guide
    /// load re-downloaded and re-parsed the complete feed once per batch.
    /// Measured 2026-08-11: 91 downloads of a 44 MB feed in five minutes on one
    /// provider, and 576 downloads of another's 33 MB feed (~19 GB) in a single
    /// session, which is the other half of why that provider's Cloudflare
    /// banned the user's IP. Callers must hand this the FULL channel list.
    private func fetchXtreamBulkXMLTV(server: ServerConnection, channels: [ChannelDisplayItem],
                                      windowStart: Date, windowEnd: Date,
                                      replaceExisting: Bool = false) async -> Bool {
        let api = XtreamCodesAPI(baseURL: server.effectiveBaseURL,
                                  username: server.username,
                                  password: server.effectivePassword)
        let serverKey = server.id.uuidString
        guard let xmltvURL = api.xmltvURL(), !Self.xmltvRefused.contains(serverKey) else { return false }
        return await fetchXMLTVFromURL(
            url: xmltvURL, channels: channels,
            windowStart: windowStart, windowEnd: windowEnd,
            categoryServerID: serverKey,
            replaceExisting: replaceExisting)
    }

    /// Per-stream `get_short_epg` fallback, for providers whose bulk
    /// `xmltv.php` yields nothing usable (no such endpoint, or no channel
    /// carries an epg_channel_id). Genuinely per-channel, hence the cap, the
    /// circuit breaker and the once-per-session latch below.
    private func fetchXtream(server: ServerConnection, channels: [ChannelDisplayItem],
                              windowStart: Date, windowEnd: Date,
                              replaceExisting: Bool = false) async -> Bool {
        let api = XtreamCodesAPI(baseURL: server.effectiveBaseURL,
                                  username: server.username,
                                  password: server.effectivePassword)
        let serverKey = server.id.uuidString

        if Self.xtreamFallbackExhausted.contains(serverKey) {
            debugLog("📺 XC per-channel EPG fallback skipped for \(server.name): already exhausted this session.")
            return false
        }
        Self.xtreamFallbackExhausted.insert(serverKey)

        let batchBasePrograms = replaceExisting
            ? replacingWindowBase(for: channels, windowStart: windowStart, windowEnd: windowEnd)
            : nil
        beginBatch(basePrograms: batchBasePrograms)
        var shouldCommitBatch = false
        defer {
            if shouldCommitBatch {
                endBatch(for: serverKey, source: "xtream-short-epg")
            } else {
                cancelBatch()
            }
        }

        // Fetch with limited concurrency (max 3 concurrent) and 15s timeout per request.
        //
        // HARD CAP + CIRCUIT BREAKER (2026-08-11). This loop used to walk EVERY
        // channel in the playlist. On a 14k-channel panel that is 14,263 API
        // calls in one guide load, three at a time, for minutes on end. Measured
        // on crx.watch: 14,264 get_short_epg requests in a single session, which
        // tripped the provider's Cloudflare bot protection and got the user's IP
        // banned outright -- the stream endpoint then answered every play with
        // `403 [Bot-Protection]: You are banned for repeated abuse` while the
        // (Cloudflare-fronted) API kept working, so it looked like a playback
        // bug rather than what it was: this app hammering the provider.
        //
        // Two independent brakes, because either alone is insufficient:
        //   * the cap bounds a SUCCESSFUL walk (a provider that answers happily
        //     still must not receive thousands of requests for one guide paint),
        //   * the breaker aborts a FAILING walk immediately (when the provider
        //     is rejecting us, continuing is both useless and what escalates a
        //     rate-limit into a ban).
        let maxFallbackChannels = 300
        let breakerFailureThreshold = 8
        let cappedChannels = Array(channels.prefix(maxFallbackChannels))
        if channels.count > maxFallbackChannels {
            DebugLogger.shared.log(
                "EPG per-channel fallback capped: \(cappedChannels.count) of \(channels.count) channels "
                + "(bulk xmltv.php yielded nothing for this provider). The rest keep whatever the grid already has.",
                category: "EPG", level: .warning)
        }

        let didReceiveAnyResponse = await withTaskGroup(of: (String, [GuideProgram], Bool).self) { group in
            let maxConcurrent = 3
            var launched = 0
            var didReceiveAnyResponse = false
            var consecutiveFailures = 0
            var tripped = false

            for ch in cappedChannels {
                if tripped { break }
                if launched >= maxConcurrent {
                    if let (channelID, progs, didRespond) = await group.next() {
                        didReceiveAnyResponse = didReceiveAnyResponse || didRespond
                        if didRespond {
                            consecutiveFailures = 0
                        } else {
                            consecutiveFailures += 1
                            if consecutiveFailures >= breakerFailureThreshold {
                                tripped = true
                                DebugLogger.shared.log(
                                    "EPG per-channel fallback ABORTED after \(consecutiveFailures) consecutive "
                                    + "failures. The provider is refusing these requests; continuing would only "
                                    + "deepen a rate-limit or ban.",
                                    category: "EPG", level: .warning)
                            }
                        }
                        for p in progs { mergeProgram(p, for: channelID) }
                    }
                }
                launched += 1

                group.addTask { [api] in
                    let result: ([GuideProgram], Bool) = await withTaskGroup(of: ([GuideProgram], Bool).self) { inner in
                        inner.addTask {
                            let response = try? await api.getEPG(streamID: ch.id, limit: 12)
                            // Aerio integration fix: PR #13's tuple wrapping
                            // (the inner.addTask now returns `(progs, ok)`)
                            // breaks Swift's type inference on the
                            // compactMap below — the closure has both
                            // `return nil` and `return GuideProgram(...)`
                            // branches, and the outer tuple makes
                            // `ElementOfResult` ambiguous between
                            // `GuideProgram` and `GuideProgram?`. Explicit
                            // closure return type annotation pins it.
                            let progs: [GuideProgram] = (response?.epgListings ?? []).compactMap { item -> GuideProgram? in
                                guard let start = Self.parseXtreamDate(item.start),
                                      let end = Self.parseXtreamDate(item.end),
                                      end > windowStart && start < windowEnd else { return nil }
                                return GuideProgram(channelID: ch.id, title: item.title,
                                                    description: item.description,
                                                    start: start, end: end, category: "")
                            }
                            return (progs, response != nil)
                        }
                        inner.addTask {
                            try? await Task.sleep(nanoseconds: 15_000_000_000)
                            return ([], false)
                        }
                        let result = await inner.next() ?? ([], false)
                        inner.cancelAll()
                        return result
                    }
                    return (ch.id, result.0, result.1)
                }
            }

            for await (channelID, progs, didRespond) in group {
                didReceiveAnyResponse = didReceiveAnyResponse || didRespond
                for p in progs { mergeProgram(p, for: channelID) }
            }

            return didReceiveAnyResponse
        }

        shouldCommitBatch = didReceiveAnyResponse
        return didReceiveAnyResponse
    }

    // MARK: - Dispatcharr Category Enrichment (v1.6.22)

    /// Pulls categories for the currently-airing program per channel
    /// via `/api/epg/programs/<id>/` (the only REST endpoint with
    /// the `categories` array (the bulk `/api/epg/grid/` strips
    /// them server-side). Fans out at cap-of-4 concurrency, then
    /// writes the result to BOTH the matching `GuideProgram.category`
    /// in `programs[channelID]` (for Guide-grid cell tinting) AND
    /// `ChannelStore.applyXMLTVCategories` (for Live-TV card stripe).
    /// Pure REST API path; no XMLTV stream involved.
    private func enrichDispatcharrCategories(
        gridPrograms: [DispatcharrCurrentProgram],
        api: DispatcharrAPI,
        tvgIDToChannelIDs: [String: [String]],
        uuidToChannelID: [String: String],
        serverID: String
    ) async {
        let now = Date()
        var currentByChannelID: [String: Int] = [:]
        var programIDByChannelID: [String: Int] = [:]
        for prog in gridPrograms {
            guard let pid = prog.programID,
                  let start = prog.startTime?.toDate(),
                  let end = prog.endTime?.toDate(),
                  start <= now, end > now else { continue }
            let key = (prog.tvgID ?? "").lowercased()
            guard !key.isEmpty else { continue }
            // v1.7.3 (Issue #20): a single program can match multiple
            // channels sharing the tvg-id; fan the categories out so
            // all of them get the same currently-airing category tint.
            let cids: [String]
            if let arr = tvgIDToChannelIDs[key], !arr.isEmpty {
                cids = arr
            } else if let cid = uuidToChannelID[key] {
                cids = [cid]
            } else {
                continue
            }
            for cid in cids {
                if currentByChannelID[cid] == nil {
                    currentByChannelID[cid] = pid
                    programIDByChannelID[cid] = pid
                }
            }
        }
        guard !currentByChannelID.isEmpty else {
            // v1.7.x diagnostic: surface why enrichment skipped so a
            // user with empty pills can capture the exact condition.
            // Three failure modes worth distinguishing:
            //   • gridPrograms empty (grid endpoint returned nothing)
            //   • gridPrograms had entries but none had a non-nil
            //     programID (Dummy EPG / string-id rows only)
            //   • programIDs were present but none mapped to a channel
            //     via tvgID/uuid lookup (mapping miss)
            debugLog("📺 enrich SKIP: gridPrograms=\(gridPrograms.count) tvgMap=\(tvgIDToChannelIDs.count) uuidMap=\(uuidToChannelID.count); no currently-airing program matched all guards")
            return
        }
        debugLog("📺 Dispatcharr category enrichment: \(currentByChannelID.count) currently-airing programs; fetching /api/epg/programs/<id>/ at cap-of-4")
        let cats = await api.enrichCategories(programIDs: Array(currentByChannelID.values))
        var byChannel: [String: String] = [:]
        var repeatChannels: Set<String> = []
        for (cid, pid) in currentByChannelID {
            guard let entry = cats[pid] else { continue }
            if let c = entry.categories { byChannel[cid] = c }
            if entry.isRepeat { repeatChannels.insert(cid) }
        }
        debugLog("📺 Dispatcharr category enrichment: \(byChannel.count)/\(currentByChannelID.count) channels got categories, \(repeatChannels.count) reruns")
        // v1.7.x diagnostic: print a sample of what came back. If this
        // line says `sample=` with an empty suffix or `nil`, Dispatcharr
        // is returning empty categories arrays — the data simply isn't
        // there (XMLTV source dropped it, Dummy EPG, etc.).
        let sample = byChannel.first.map { "\($0.key.prefix(16))→\($0.value)" } ?? "<none>"
        debugLog("📺 enrich sample: \(sample)")

        // Write categories to the matching airing GuideProgram in
        // `programs[cid]` so Guide-grid cells tint. Single
        // @Published mutation at end (COW snapshot + reassign) keeps
        // SwiftUI invalidations to one even with many channels.
        //
        // v1.7.x: also propagate the now-airing category to every
        // future program of the same channel whose title matches.
        // Mirrors the title-matched heuristic Phase 3 already
        // applies to `EPGCache` entries (HomeView.loadAllEPG): a
        // recurring show like SportsCenter on ESPN HD or Fox 8
        // News on FOX 8 keeps its tint on the 1 AM / 6 AM / etc.
        // re-airings, while one-off programs (NHL Hockey, Big
        // Bang Theory) stay neutral until we have their own
        // category. Without this, PR #13's pull-to-refresh path
        // (which routes through fetchUpcoming → fetchDispatcharr
        // → enrichDispatcharrCategories) populates
        // `GuideStore.programs` for the Live-TV List expanded
        // panel; and since `futurePrograms` prefers
        // `guideStore.programs[item.id]` over EPGCache, the
        // expanded rows lost the title-matched tints my Phase 3
        // had applied to EPGCache. Replicating the same propagation
        // here keeps both data sources visually identical.
        var updated = self.programs
        // Rerun flag applies even to channels that got no categories back, so
        // walk the union of both result sets (mikec79: REPEAT on the guide).
        for cid in Set(byChannel.keys).union(repeatChannels) {
            let cats = byChannel[cid]
            guard var progs = updated[cid] else { continue }
            guard let idx = progs.firstIndex(where: { $0.start <= now && $0.end > now }) else { continue }
            // GuideProgram.category is `let` (struct value). Build a
            // fresh one with the same fields plus the enriched
            // category and swap it in.
            let old = progs[idx]
            let nowTitle = old.title
            progs[idx] = GuideProgram(channelID: old.channelID,
                                       title: old.title,
                                       description: old.description,
                                       start: old.start,
                                       end: old.end,
                                       category: cats ?? old.category,
                                       programID: old.programID,
                                       subTitle: old.subTitle, season: old.season,
                                       episode: old.episode, isNew: old.isNew,
                                       isLiveBroadcast: old.isLiveBroadcast,
                                       isPremiere: old.isPremiere, isFinale: old.isFinale,
                                       isRepeat: old.isRepeat || repeatChannels.contains(cid))

            // Title-matched propagation across the rest of the
            // channel's programs. Skip the now-airing index (just
            // updated above) and any program that already carries
            // a non-empty category (idempotent on warm relaunch +
            // respects categories from XMLTV-merge if that ran
            // first).
            if !nowTitle.isEmpty, let cats {
                for j in progs.indices where j != idx {
                    let p = progs[j]
                    guard p.title == nowTitle, p.category.isEmpty else { continue }
                    progs[j] = GuideProgram(channelID: p.channelID,
                                             title: p.title,
                                             description: p.description,
                                             start: p.start,
                                             end: p.end,
                                             category: cats,
                                             programID: p.programID,
                                             subTitle: p.subTitle, season: p.season,
                                             episode: p.episode, isNew: p.isNew,
                                             isLiveBroadcast: p.isLiveBroadcast,
                                             isPremiere: p.isPremiere, isFinale: p.isFinale,
                                             isRepeat: p.isRepeat)
                }
            }

            updated[cid] = progs
        }
        guard commitPrograms(updated, for: serverID, source: "category-apply") else { return }

        // Apply to Live-TV channel-card stripe.
        ChannelStore.shared.applyXMLTVCategories(byChannel, serverID: serverID)
    }

    // MARK: - M3U + XMLTV
    private func fetchXMLTV(server: ServerConnection, channels: [ChannelDisplayItem],
                             windowStart: Date, windowEnd: Date,
                             replaceExisting: Bool = false) async -> Bool {
        let epgURLStr = server.effectiveEPGURL
        guard !epgURLStr.isEmpty, let epgURL = URL(string: epgURLStr) else { return false }
        return await fetchXMLTVFromURL(
            url: epgURL,
            channels: channels,
            windowStart: windowStart,
            windowEnd: windowEnd,
            categoryServerID: server.id.uuidString,
            replaceExisting: replaceExisting
        )
    }

    /// Core XMLTV fetch/parse path. Accepts a pre-resolved URL so callers
    /// that source their XMLTV feed from somewhere other than
    /// `server.effectiveEPGURL` (e.g. the per-server Dispatcharr XMLTV
    /// override) can reuse the exact same parsing + matching logic.
    ///
    /// Matching strategy: the XMLTV spec says `<programme channel="...">`
    /// must match a `<channel id="...">` earlier in the document, but
    /// the spec is silent on what that id looks like. In the wild we
    /// see three patterns:
    ///   • tvg_id (e.g. "espn.us") — what most pure-XMLTV sources use
    ///   • channel number (e.g. "5") — what Dispatcharr's `/output/epg`
    ///     uses by default when the `tvg_id_source` query param isn't set
    ///   • Dispatcharr channel UUID — used for synthetic "Dummy EPG"
    ///     entries on channels that have no upstream XMLTV mapping
    ///
    /// We build maps for all three (case-insensitive) and try them in
    /// order: tvg_id → number → UUID. A programme matches the first
    /// map that contains its `channel=...` value. This mirrors the
    /// logic in the JSON-API Dispatcharr fetch path above and makes
    /// us resilient to whichever identifier shape the XMLTV source
    /// happened to use.
    /// Internal (no `private`) so `ChannelStore.loadAllEPG` can call
    /// the same path from the non-Guide-view code flow (iPhone never
    /// mounts EPGGuideView, but it still needs XMLTV data for the
    /// Live-TV list tint + per-program expanded-schedule colors).
    /// Both call sites end up populating `programs` + seeding
    /// `EPGCache` via `seedEPGCache`, so Guide view and List view
    /// read from one unified dataset.
    /// Returns `true` when the XMLTV fetch produced parsed programs
    /// (which were merged into `GuideStore.programs`). Returns
    /// `false` when the fetch failed (network error, HTTP 4xx/5xx,
    /// parse error). Callers can use the result to fall through to
    /// a backstop. See `fetchDispatcharr` for the Dispatcharr 403
    /// path (LAN-only `/output/epg` policy on WAN deployments,
    /// v1.6.22 fix).
    @discardableResult
    func fetchXMLTVFromURL(url: URL, channels: [ChannelDisplayItem],
                                    windowStart: Date, windowEnd: Date,
                                    headers: [String: String] = [:],
                                    extraTVGIDs: [String: [String]] = [:],
                                    categoryServerID: String,
                                    replaceExisting: Bool = false) async -> Bool {
        let inFlightKey = InFlightXMLTVKey(
            url: url,
            categoryServerID: categoryServerID,
            replaceExisting: replaceExisting
        )
        // In-flight coalescing — see `inFlightXMLTVTask` doc. On
        // cold install two call sites hit this method with the
        // same URL back-to-back; without dedupe we pay the XMLTV
        // download + parse twice (~3 min each on the 98k-program
        // torture playlist).
        if let inFlight = inFlightXMLTVTask, inFlight.key == inFlightKey {
            debugLog("📺 GuideStore.fetchXMLTVFromURL: joining in-flight parse (url=\(url.host ?? "?"))")
            return await inFlight.task.value
        }

        // Recently-completed reuse — see `lastCompletedXMLTVPass`. Catches the
        // sequential duplicates that in-flight coalescing structurally cannot.
        let requestedKeys = Self.channelMatchKeys(channels)
        if let done = lastCompletedXMLTVPass,
           done.key == inFlightKey,
           Date().timeIntervalSince(done.at) < Self.xmltvReuseWindow,
           windowStart >= done.windowStart - Self.xmltvReuseWindow,
           windowEnd <= done.windowEnd + Self.xmltvReuseWindow,
           requestedKeys.isSubset(of: done.channelKeys) {
            let age = Int(Date().timeIntervalSince(done.at))
            debugLog("📺 GuideStore.fetchXMLTVFromURL: reusing the bulk guide fetched \(age)s ago from \(url.host ?? "?") — these \(channels.count) channels were already merged from it, skipping the re-download")
            return true
        }

        // Wrap the fetch+parse+merge body in a Task so a concurrent
        // caller with the same URL can join via `inFlightXMLTVTask`.
        // Inherits @MainActor from the enclosing GuideStore, which
        // matters for the `beginBatch`/`endBatch` + `mergeProgram`
        // calls that follow.
        let fetchTask = Task<Bool, Never> { [self] in
            return await performXMLTVFetch(url: url, channels: channels,
                                           windowStart: windowStart, windowEnd: windowEnd,
                                           headers: headers,
                                           extraTVGIDs: extraTVGIDs,
                                           categoryServerID: categoryServerID,
                                           replaceExisting: replaceExisting)
        }
        inFlightXMLTVTask = (key: inFlightKey, task: fetchTask)
        let success = await fetchTask.value
        // Only clear if we're still the registered in-flight task
        // for this full request shape. A different XMLTV request
        // starting later would have overwritten the entry; don't
        // stomp it.
        if inFlightXMLTVTask?.key == inFlightKey {
            inFlightXMLTVTask = nil
        }
        // Record the pass so a later caller asking for the same feed and a
        // subset of these channels can be served without touching the network.
        // Successes only: a failed pass merged nothing, so there is nothing to
        // reuse and the next caller should get a real attempt.
        //
        // The display check closes a phantom-success hole: when the user
        // switches playlists mid-parse, performXMLTVFetch's merge is DISCARDED
        // by commitPrograms but it still returns true (deliberately, so the
        // caller does not run its per-channel backstop for a playlist nobody
        // is looking at). beginDisplaying cleared this latch — but that ran
        // BEFORE this line, so recording on `success` alone would re-create a
        // pass whose data was never kept. Switching back within the reuse
        // window would then skip a real fetch. Only a merge that landed on the
        // currently-displayed playlist is reusable.
        if success, displayedServerID == nil || displayedServerID == inFlightKey.categoryServerID {
            lastCompletedXMLTVPass = CompletedXMLTVPass(
                key: inFlightKey,
                channelKeys: requestedKeys,
                windowStart: windowStart,
                windowEnd: windowEnd,
                at: Date()
            )
        }
        return success
    }

    /// Body of `fetchXMLTVFromURL`, split out so the outer function
    /// can wrap it in an in-flight-coalescing `Task`. See
    /// `inFlightXMLTVTask` for the rationale.
    ///
    /// The merge loop runs on a detached task. On the torture
    /// playlist a full XMLTV parse yields ~98k programs, each
    /// triggering an O(m) duplicate scan over the target channel's
    /// current list (m ≈ 45 programs/channel). That's ~4–5 million
    /// comparison ops plus 98k `list.sort` calls — a 5+ second
    /// main-thread freeze at the end of cold-install setup
    /// (observed as `MAIN THREAD FROZEN >5s!` in the watchdog logs
    /// right before the initial-sync cover dismissed).
    ///
    /// Off-main, the merge becomes invisible to the user. The
    /// `@Published programs` property fires exactly once — the
    /// single `programs = result.dict` assignment after the
    /// detached task returns — so SwiftUI invalidations land the
    /// same way they did with the old `beginBatch`/`endBatch`
    /// pattern, just without blocking the main thread in between.
    ///
    /// Trade-off / race: between snapshot time and re-assignment,
    /// a concurrent caller (practically: `seedFromChannels` firing
    /// from `EPGGuideView.task` right after channels publish) may
    /// write stub entries into `programs`. Those stubs get
    /// overwritten when we assign. In practice with a comprehensive
    /// Dispatcharr XMLTV feed the stubs cover the same channels
    /// the XMLTV feed does, so the overwrite is a no-op. Channels
    /// with partial XMLTV coverage lose their stub until the next
    /// per-cell prefetch lands — acceptable given the alternative
    /// is a multi-second frozen UI.
    /// Returns `true` when the fetch+parse+merge completed and at
    /// least some programs landed in `programs`. Returns `false` on
    /// network/HTTP/parse failure, OR when the feed parsed but matched
    /// zero of these channels, so callers can fall through to a
    /// non-XMLTV backstop. The Dispatcharr-specific 403 case
    /// (LAN-only `/output/epg` policy) is the v1.6.22 reason this
    /// signal exists; Dispatcharr also publishes its programs via
    /// `/api/epg/grid/` (no categories), and `EPGGuideView.fetchDispatcharr`
    /// uses the false return to fall through to that endpoint
    /// instead of leaving the Guide grid empty.
    private func performXMLTVFetch(url: URL, channels: [ChannelDisplayItem],
                                   windowStart: Date, windowEnd: Date,
                                   headers: [String: String],
                                   extraTVGIDs: [String: [String]] = [:],
                                   categoryServerID: String,
                                   replaceExisting: Bool) async -> Bool {
        // v1.6.22: log the actual error instead of swallowing it via
        // `try?`. The previous "XMLTV fetch/parse failed for <host>"
        // line told us nothing about WHY (auth? timeout? parse error?),
        // which made Freyguy1975's 403-on-/output/epg invisible until
        // we curl-probed the endpoint manually. Surface status + error
        // so the next case is diagnosable from the log alone.
        // v1.7.3: build the channel allowlist for filter-during-parse.
        // Covers every key the merge loop below can match on (tvg-id,
        // channel number, Dispatcharr UUID), lowercased to match the
        // parser's case-folded comparison. Only the gzip path inside
        // `fetchAndParse` consults this; uncompressed XMLTV parses
        // whole (small enough) and ignores it. Empty set passes nil
        // so a misconfigured channel list never filters everything out.
        var knownChannelKeys = Self.channelMatchKeys(channels)
        // Catch-up depth: bridged `epg_data_id -> EPGData.tvg_id` keys from
        // the caller (layerDispatcharrUpstreamSources). Upstream feeds key
        // programmes by exactly these ids, which routinely differ from a
        // channel's own tvg_id. Already lowercased by the builder.
        for key in extraTVGIDs.keys { knownChannelKeys.insert(key) }
        let parsed: [ParsedEPGProgram]
        do {
            parsed = try await XMLTVParser.fetchAndParse(
                url: url,
                headers: headers,
                knownChannelIDs: knownChannelKeys.isEmpty ? nil : knownChannelKeys
            )
            debugLog("📺 XMLTV fetched OK from \(url.host ?? "?") (headers=\(headers.count), \(parsed.count) programs parsed)")
        } catch let APIError.serverError(code) {
            // v1.6.22: spell out the most common WAN-deployment
            // root cause when we hit 403. Dispatcharr 0.23.0+
            // defaults `/output/epg` to LAN-only. Every Cloudflare
            // tunnel / Synology QuickConnect / public hostname user
            // hits this.
            if code == 403 {
                // Definitive refusal: remember it so this session stops asking.
                // Measured 155 repeats in a single session before this latch.
                Self.xmltvRefused.insert(categoryServerID)
                // Only name the Dispatcharr policy when this actually IS a
                // Dispatcharr server. On a plain Xtream panel the same 403
                // means something completely different (commonly the provider
                // rate-limiting or banning the client's IP), and confidently
                // pointing at a Dispatcharr setting the user does not have
                // sent this investigation down the wrong path on 2026-08-11.
                // Dispatcharr requests carry auth headers (API key / bearer);
                // a plain Xtream panel is fetched with none, which is exactly
                // what the crx.watch log showed (`headers=0`) while this text
                // confidently blamed a Dispatcharr setting the user does not have.
                if !headers.isEmpty {
                    debugLog("📺 XMLTV fetch failed for \(url.host ?? "?"): HTTP 403 (headers=\(headers.count)). Likely Dispatcharr's M3U/EPG Network Access policy blocking non-LAN clients (default since Dispatcharr 0.23.0). Fix in Dispatcharr → Settings → Network Access → 'M3U / EPG Endpoints': add 0.0.0.0/0,::/0 or the client's public IP.")
                } else {
                    debugLog("📺 XMLTV fetch failed for \(url.host ?? "?"): HTTP 403 (headers=\(headers.count)). The provider refused the bulk guide for this client. Common causes: the plan does not include xmltv.php, or the provider is rate-limiting or has banned this IP. Not retried this session.")
                }
            } else {
                debugLog("📺 XMLTV fetch failed for \(url.host ?? "?"): HTTP \(code) (headers=\(headers.count))")
            }
            return false
        } catch {
            debugLog("📺 XMLTV fetch failed for \(url.host ?? "?"): \(error.localizedDescription) (headers=\(headers.count))")
            return false
        }

        // Build channel-lookup dictionaries on the MainActor. All
        // three are small (one entry per channel) and cheap.
        //
        // v1.7.3 (Issue #20, jdfrey1 2026-05-16): `tvgIDToChannelIDs`
        // value is `[String]` rather than `String` so a tvg-id shared
        // by multiple channels routes the matched programs to every
        // channel that shares the tvg-id, not just the first iterated.
        var tvgIDToChannelIDsBuild: [String: [String]] = [:]
        for ch in channels {
            guard let tvg = ch.tvgID, !tvg.isEmpty else { continue }
            let key = tvg.lowercased()
            if tvgIDToChannelIDsBuild[key]?.contains(ch.id) != true {
                tvgIDToChannelIDsBuild[key, default: []].append(ch.id)
            }
        }
        // Catch-up depth: merge the caller's bridged EPGData tvg_id keys so
        // upstream-source programmes route to channels whose own tvg_id
        // differs from the EPGData row they map to (about 25% of channels
        // on a real Dispatcharr instance; see fetchDispatcharr's bridge).
        for (key, ids) in extraTVGIDs {
            for id in ids where tvgIDToChannelIDsBuild[key]?.contains(id) != true {
                tvgIDToChannelIDsBuild[key, default: []].append(id)
            }
        }
        let tvgIDToChannelIDs = tvgIDToChannelIDsBuild
        let numberToChannelID: [String: String] = Dictionary(
            channels.map { ($0.number, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let uuidToChannelID: [String: String] = Dictionary(
            channels.compactMap { ch in
                guard let uuid = ch.uuid, !uuid.isEmpty else { return nil }
                return (uuid.lowercased(), ch.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let hostLabel = url.host ?? "?"
        // Snapshot the current programs dict. Swift dict COW — this
        // is an O(1) reference bump, not a full copy. The detached
        // task below mutates its own local copy; the first write
        // triggers the deep copy, off-main. `self.programs` itself
        // stays untouched until the final assignment.
        let snapshot = replaceExisting
            ? replacingWindowBase(for: channels, windowStart: windowStart, windowEnd: windowEnd)
            : programs

        // Run the 98k-iteration merge off the MainActor.
        let result = await Task.detached(priority: .userInitiated) { () -> XMLTVMergeResult in
            var dict = snapshot
            var matched = 0
            var missed = 0
            // Collect currently-airing categories keyed by channel
            // id so we can push them back to ChannelStore after the
            // loop — that makes the Live TV list view's "Tint
            // Channel Cards" stripe work off the same XMLTV source
            // as the guide itself.
            let now = Date()
            var currentCategoriesByChannelID: [String: String] = [:]
            // Track which channels received at least one insert so
            // we only sort their lists at the end (avoids 98k
            // redundant sort calls on channels whose lists never
            // grew beyond what was in the snapshot).
            var touchedChannelIDs = Set<String>()

            for prog in parsed {
                guard prog.endTime > windowStart && prog.startTime < windowEnd else { continue }
                let key = prog.channelID.lowercased()
                // v1.7.3 (Issue #20): tvg-id may match multiple
                // channels (shared-EPG case). `numberToChannelID`
                // and `uuidToChannelID` stay single-channel because
                // their keys are unique by construction.
                let cids: [String]
                if let arr = tvgIDToChannelIDs[key], !arr.isEmpty {
                    cids = arr
                } else if let cid = numberToChannelID[prog.channelID] {
                    cids = [cid]
                } else if let cid = uuidToChannelID[key] {
                    cids = [cid]
                } else {
                    missed += 1
                    continue
                }
                matched += 1
                // deferSort: true — a 98k-iteration loop over ~2,100
                // channels means each channel gets ~46 inserts on
                // average; sorting per insert is 46× more work than
                // sorting each list once at the end.
                for cid in cids {
                    let gp = GuideProgram(channelID: cid, title: prog.title,
                                          description: prog.description,
                                          start: prog.startTime, end: prog.endTime,
                                          category: prog.category, programID: nil,
                                          subTitle: prog.subTitle, season: prog.season,
                                          episode: prog.episode, isNew: prog.isNew,
                                          isLiveBroadcast: prog.isLiveBroadcast,
                                          isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                                          isRepeat: prog.isRepeat)
                    GuideStore.mergeProgramInto(&dict, program: gp, for: cid, deferSort: true)
                    touchedChannelIDs.insert(cid)
                    // Track currently-airing program category.
                    if !prog.category.isEmpty, prog.startTime <= now, prog.endTime > now {
                        currentCategoriesByChannelID[cid] = prog.category
                    }
                }
            }
            // Sort the lists we actually modified.
            for cid in touchedChannelIDs {
                dict[cid]?.sort { $0.start < $1.start }
            }
            return XMLTVMergeResult(
                dict: dict,
                matched: matched,
                missed: missed,
                currentCategoriesByChannelID: currentCategoriesByChannelID
            )
        }.value

        // Single @Published write on MainActor. SwiftUI sees one
        // invalidation instead of 98k (which is what the old
        // beginBatch/endBatch pair was also designed to do, but
        // that version still ran the merge loop on main).
        // Check the match count BEFORE committing. The dict handed to the merge
        // has the fetch window pre-stripped when replaceExisting is set, so
        // committing a zero-match parse installs that hole over a good guide.
        // The contract below already treats zero matches as "did not land"; it
        // just used to say so 22 lines too late to protect anything.
        guard result.matched > 0 else {
            debugLog("📺 XMLTV \(hostLabel): 0 programs matched — guide left untouched, caller falls through to its backstop")
            return false
        }
        guard commitPrograms(result.dict, for: categoryServerID, source: "xmltv-merge") else {
            // Stale writer: the user switched playlists during this parse.
            // Return true so the caller does NOT fall through to its
            // per-channel backstop for a playlist nobody is looking at.
            // (The persistent save happens in the caller via saveToCache,
            // which snapshots the displayed dict -- correctly the OTHER
            // playlist's by now -- so nothing stale is persisted either.)
            return true
        }
        debugLog("📺 XMLTV \(hostLabel): \(result.matched) programs matched, \(result.missed) skipped (no channel)")
        // Back-fill ChannelStore so Tint Channel Cards reflects
        // the XMLTV categories on every channel row.
        ChannelStore.shared.applyXMLTVCategories(result.currentCategoriesByChannelID, serverID: categoryServerID)
        // Honor the documented contract: "landed" means programmes actually
        // matched channels, not merely that the HTTP fetch + parse succeeded. A
        // reachable feed that matches zero of these channels (an XC provider
        // whose channels carry no epg_channel_id, or an empty <tv/>) must read
        // as false so the caller falls through to its backstop (XC
        // get_short_epg, Dispatcharr /api/epg/grid/). Returning true
        // unconditionally silently stranded those channels with no guide at all
        // (issue #49's own "no channel carries an epg_channel_id" fallback case
        // never fired, because a 0-match parse still reported success).
        return result.matched > 0
    }

    // MARK: - Rolling Prefetch
    /// Tracks channels that have either populated data (via the bulk
    /// fetch) or returned from a per-channel fetch. Reset by
    /// `resetPrefetchCache()` after bulk refresh / pull-to-refresh so
    /// the set doesn't poison subsequent scroll cycles (GH #3:
    /// "scroll past and back = empty" — the set persisted forever
    /// even when the per-channel fetch had returned zero programs,
    /// so the user could never recover without switching views).
    private var fetchedChannelIDs: Set<String> = []

    /// Tail of the serial prefetch chain. Each new prefetch awaits
    /// the previous one before issuing its own network call, which
    /// caps in-flight per-cell fetches at one. Needed because cells
    /// fire `.onAppear` in bursts on Guide open (3-8 at once on tvOS,
    /// more on iOS), and without this gate every burst turned into
    /// that many concurrent `/api/epg/programs/?tvg_id=...` requests
    /// — enough to pin every uwsgi worker on large Dispatcharr
    /// instances and freeze the whole container.
    private var lastPrefetchTask: Task<Void, Never>?

    /// Debounced, per-channel prefetch entry. Each call to
    /// `prefetchIfNeeded` cancels any prior in-flight entry for the
    /// same channel id, then schedules a 250ms-delayed task. A cell
    /// that appears and disappears faster than the debounce never
    /// issues a network request; only rows that stay visible long
    /// enough to actually be read enter the serial chain above.
    ///
    /// The per-entry `id` is a submission token used by the task's
    /// own cleanup block to distinguish "I'm still the current task
    /// for this channel" from "a newer prefetchIfNeeded replaced me
    /// while I was running". Without this identity guard the task
    /// would remove whatever entry happened to be under the key,
    /// including a newer submission's entry — which would then
    /// leak (no way to cancel it on disappear) and could run
    /// concurrently with a subsequent submission, defeating the
    /// serialization goal.
    private struct PendingPrefetch {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var pendingPrefetchTasks: [String: PendingPrefetch] = [:]

    /// Circuit breaker state. On servers that genuinely can't answer
    /// per-cell `/api/epg/programs/` requests (overloaded large
    /// Dispatcharr instance, upstream EPG provider flaking, etc.),
    /// the prior behaviour was to fire a 5s-timeout request for every
    /// visible cell — uselessly burning the server's uwsgi workers
    /// AND our radio for hundreds of guaranteed-to-fail requests.
    /// Once three per-cell fetches in a row time out we trip the
    /// breaker and stop firing until `resetPrefetchCache()` clears
    /// it (pull-to-refresh / bulk re-fetch).
    private var consecutivePrefetchTimeouts: Int = 0
    private var prefetchCircuitBreakerTripped: Bool = false
    /// Timestamp of the most recent breaker trip. `resetPrefetchCache`
    /// consults this to apply a cooldown — if the breaker tripped
    /// recently (within `prefetchBreakerCooldown`), a view-reappear-
    /// triggered reset keeps the breaker tripped instead of giving
    /// the server another round of 3 timeouts. Only a "long enough"
    /// reset (after the cooldown OR explicit user refresh) lets the
    /// breaker clear.
    private var prefetchBreakerTrippedAt: Date? = nil
    private let prefetchBreakerCooldown: TimeInterval = 30

    /// Called by the outer Guide task after a bulk re-fetch or a
    /// pull-to-refresh so that subsequent per-cell `.onAppear`
    /// handlers are free to re-check. Without this, channels that
    /// were fetched during the previous session's scroll remain
    /// flagged and the per-channel prefetch never retries — even
    /// when the bulk fetch has since populated data.
    func resetPrefetchCache() {
        fetchedChannelIDs.removeAll(keepingCapacity: true)
        // Also drop any pending debounce tasks — they're about to
        // fire against stale state. Active in-flight fetches stay
        // and finish naturally; the serial chain just drains.
        for entry in pendingPrefetchTasks.values { entry.task.cancel() }
        pendingPrefetchTasks.removeAll(keepingCapacity: true)
        // Breaker reset is gated on a cooldown. This function fires
        // on every `.task(id: channels.count)` activation — which
        // includes view re-appear after backing out of playback, not
        // just genuine pull-to-refresh. Without the cooldown, we'd
        // un-trip the breaker every time the user stops a stream
        // and then immediately fire three fresh timeouts against
        // the still-unresponsive server. Skipping the breaker clear
        // inside the cooldown window keeps the app quiet until the
        // server has had time to recover (or the user waits long
        // enough that the server probably has).
        if let trippedAt = prefetchBreakerTrippedAt,
           Date().timeIntervalSince(trippedAt) < prefetchBreakerCooldown {
            return
        }
        consecutivePrefetchTimeouts = 0
        prefetchCircuitBreakerTripped = false
        prefetchBreakerTrippedAt = nil
    }

    /// Timeout detector shared with the fetch task. Matches
    /// `VODStore.isTimeoutError` — kept locally so we don't
    /// introduce a new cross-file shared helper just yet. Marked
    /// `nonisolated` so it can be called from inside `withTaskGroup`
    /// closures (which run off the MainActor).
    nonisolated fileprivate static func isTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        return nsError.localizedDescription.lowercased().contains("timed out")
    }

    /// Cancel the pending (debounced, not-yet-fired) prefetch for a
    /// channel. Called from the cell's `.onDisappear` so a row that
    /// scrolls off-screen before its 250ms timer elapses doesn't
    /// waste a server request. In-flight fetches (past the debounce)
    /// are allowed to finish — their data is still useful when the
    /// user scrolls back.
    func cancelPrefetch(channelID: String) {
        pendingPrefetchTasks[channelID]?.task.cancel()
        pendingPrefetchTasks.removeValue(forKey: channelID)
    }

    /// Called when a guide row appears on screen. Fetches EPG for
    /// this channel if not already loaded AND the bulk fetch didn't
    /// already populate its future programs.
    func prefetchIfNeeded(channel: ChannelDisplayItem, servers: [ServerConnection]) {
        guard !fetchedChannelIDs.contains(channel.id) else { return }
        // Circuit breaker — don't fire more per-cell requests once
        // we've seen three consecutive timeouts. The serial chain
        // would otherwise keep working its way through the entire
        // visible channel list, each cell taking 5s to fail.
        guard !prefetchCircuitBreakerTripped else { return }
        // v1.6.22: don't fire per-cell prefetch while a bulk
        // `fetchUpcoming` is in flight. On large Dispatcharr
        // instances (jesmannstl: 2,186 channels, ~19,500 EPGData
        // rows) the bulk grid fetch can take 90+ seconds, and
        // racing 20 visible-cell requests against it on the same
        // worker pool drowns the upstream uWSGI workers; the
        // grid response gets truncated mid-stream, returning
        // NSURLError -1017 "cannot parse response", and per-cell
        // requests time out at 5s each, tripping the circuit
        // breaker. Deferring per-cell prefetch until the bulk
        // path completes lets the server breathe. After the bulk
        // finishes successfully, cells already have data; if the
        // bulk fails, the user can pull-to-refresh to retry.
        guard !isLoading else { return }

        // Skip the per-channel network fetch when we already have
        // upcoming program data for this channel from the bulk
        // fetch. Dispatcharr's `fetchDispatcharr` populates this
        // map for every tvg_id-matched channel in a single XMLTV
        // request, and Xtream's `fetchXtream` does the same via
        // its first batched pass. Without this gate, every guide
        // row's `.onAppear` would fire a redundant per-channel
        // request on top of the bulk response.
        let futureThreshold = Date().addingTimeInterval(30 * 60) // 30 min
        let hasUpcoming = (programs[channel.id] ?? []).contains { $0.end > futureThreshold }
        if hasUpcoming {
            // Cache hit — bulk fetch covered us. Mark as fetched
            // because no per-channel work is needed.
            fetchedChannelIDs.insert(channel.id)
            return
        }

        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else { return }
        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        // Respect the user's EPG window setting (Settings → EPG
        // window hours). Previously hardcoded to 3 hours, which
        // meant even when the user configured a 24- or 36-hour
        // window, per-cell fetches only ever retrieved 3 hours
        // and the guide appeared sparse past that (GH #3 symptom
        // "Not respecting the Time from Settings"). 0 = "All
        // available" — cap at 14 days as a practical maximum.
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? min(epgWindowHours, 14 * 24) : 36
        let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)

        // Capture server properties before entering sendable closure
        let serverType = server.type
        let baseURL = server.effectiveBaseURL
        let apiKey = server.effectiveApiKey
        // v1.7.x: capture identity + saved-username for silent
        // api_key re-bootstrap on 401.
        let dispatcharrServerID = server.id
        let dispatcharrSavedUsername: String? =
            server.dispatcharrCredentialType == .usernamePassword ? server.username : nil
        // v1.6.20: per-server auth shape capture for the off-main API client.
        let authMode = server.dispatcharrHeaderMode
        let userAgent = server.effectiveUserAgent
        let username = server.username
        let password = server.effectivePassword
        let channelID = channel.id
        let tvgID = channel.tvgID
        // Which playlist this prefetch belongs to, checked again at merge
        // time. The task can outlive a playlist switch (beginDisplaying now
        // also cancels these, but a task already past its cancellation checks
        // still completes), and `mergeProgram` writes straight into `programs`
        // where bare stream_id keys collide across playlists — the exact
        // contamination the display-ownership gate exists to stop.
        let prefetchServerKey = server.id.uuidString

        // Cancel any previous debounced task for this same channel
        // so a quickly-repeating `.onAppear` (e.g. SwiftUI diffing a
        // reused cell) restarts the 250ms timer instead of piling
        // two tasks into the serial chain.
        pendingPrefetchTasks[channelID]?.task.cancel()

        // Tail of the serial chain as of this call. We capture it
        // here so each new prefetch awaits the previous one's
        // completion before issuing its own network request —
        // effectively max-concurrency=1 across all prefetches.
        let previousTail = lastPrefetchTask

        // Submission token for this specific prefetch. Used by the
        // cleanup block at the end of the Task to verify we're still
        // the entry under `pendingPrefetchTasks[channelID]` before
        // removing it — a newer prefetchIfNeeded for the same
        // channel could have replaced us while our fetch was running.
        let submissionID = UUID()

        let task = Task { [weak self] in
            // Debounce: drop the request if the cell scrolls off
            // screen (triggering `cancelPrefetch`) before this
            // timer elapses. 250ms is enough to filter out cells
            // that flicker in/out during fast scroll, but short
            // enough that users who stop scrolling don't perceive
            // a stall before "now airing" text starts appearing.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }

            // Serial gate. Waiting on `previousTail.value` chains
            // this fetch behind every earlier-submitted prefetch.
            // If the tail was cancelled, its `value` resolves
            // immediately — we don't care about its result here,
            // just the ordering barrier.
            await previousTail?.value
            if Task.isCancelled { return }

            // Fetch programs with a 15-second timeout (race against
            // a sleep task). Task-group result is now a tuple
            // (programs, didTimeout) so the circuit breaker below can
            // distinguish "server answered empty" from "server didn't
            // answer" — we only count the latter against the breaker.
            let fetchResult: ([GuideProgram], Bool) = await withTaskGroup(of: ([GuideProgram], Bool).self) { group in
                group.addTask {
                    switch serverType {
                    case .dispatcharrAPI:
                        let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                                 userAgent: userAgent, authMode: authMode,
                                                 serverID: dispatcharrServerID,
                                                 savedUsername: dispatcharrSavedUsername)
                        let hasTvgID = tvgID != nil && !tvgID!.isEmpty
                        let chID = Int(channelID)
                        guard hasTvgID || chID != nil else { return ([], false) }
                        do {
                            let upcoming = try await api.getUpcomingPrograms(
                                tvgIDs: hasTvgID ? [tvgID!] : nil,
                                channelIDs: hasTvgID ? nil : (chID.map { [$0] })
                            )
                            let programs: [GuideProgram] = upcoming.compactMap { prog in
                                guard let start = prog.startTime?.toDate(),
                                      let end = prog.endTime?.toDate(),
                                      end > windowStart && start < windowEnd else { return nil }
                                let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                                return GuideProgram(channelID: channelID, title: prog.title,
                                                    description: desc, start: start, end: end,
                                                    category: "", programID: prog.programID,
                                                    subTitle: prog.subTitle.isEmpty ? nil : prog.subTitle,
                                                    season: prog.season, episode: prog.episode,
                                                    isNew: prog.isNew, isLiveBroadcast: prog.isLiveBroadcast,
                                                    isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                                                    isRepeat: prog.isRepeat)
                            }
                            return (programs, false)
                        } catch {
                            return ([], GuideStore.isTimeoutError(error))
                        }
                    case .xtreamCodes:
                        let api = XtreamCodesAPI(baseURL: baseURL, username: username, password: password)
                        do {
                            let response = try await api.getEPG(streamID: channelID, limit: 12)
                            let programs: [GuideProgram] = response.epgListings.compactMap { item in
                                guard let start = Self.parseXtreamDate(item.start),
                                      let end = Self.parseXtreamDate(item.end),
                                      end > windowStart && start < windowEnd else { return nil }
                                return GuideProgram(channelID: channelID, title: item.title,
                                                    description: item.description,
                                                    start: start, end: end, category: "")
                            }
                            return (programs, false)
                        } catch {
                            return ([], GuideStore.isTimeoutError(error))
                        }
                    case .m3uPlaylist:
                        return ([], false)
                    }
                }
                group.addTask {
                    // Hard outer ceiling. Each underlying request also
                    // enforces its own timeout (5s for Dispatcharr's
                    // `getUpcomingPrograms`), so this mostly catches
                    // pathological network stalls where even socket
                    // close takes forever. If this branch wins, treat
                    // it as a timeout signal.
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return ([], true)
                }
                let result = await group.next() ?? ([], false)
                group.cancelAll()
                return result
            }
            let (fetched, didTimeout) = fetchResult
            if Task.isCancelled { return }
            // Merge results back on main actor
            await MainActor.run {
                guard let self else { return }
                // Display ownership: discard if the guide moved to another
                // playlist while this fetch was in flight. Same rule as
                // commitPrograms, applied to the one write path that does
                // not go through it.
                guard self.displayedServerID == nil || self.displayedServerID == prefetchServerKey else {
                    debugLog("📺 GuideStore.prefetch: DISCARDED stale per-cell result for \(prefetchServerKey.prefix(8)) — guide now displays \(self.displayedServerID!.prefix(8))")
                    return
                }
                for prog in fetched {
                    self.mergeProgram(prog, for: channelID)
                }
                // Mark this channel as fetched ONLY if we actually got
                // programs back. Previously the id was inserted BEFORE
                // the fetch ran, so a timeout / transient failure left
                // the channel flagged but empty forever (GH #3 symptom
                // "scroll past and back and the cell stays empty").
                // Deferring the insert until we have data means a later
                // scroll into the same row will retry the fetch.
                if !fetched.isEmpty {
                    self.fetchedChannelIDs.insert(channelID)
                }
                // Update the circuit breaker. A timeout here increments
                // the consecutive counter; any other outcome (success,
                // empty success, non-timeout error) resets it. Three in
                // a row trips the breaker — subsequent prefetchIfNeeded
                // calls short-circuit until resetPrefetchCache clears
                // it (pull-to-refresh / bulk re-fetch).
                if didTimeout {
                    self.consecutivePrefetchTimeouts += 1
                    if self.consecutivePrefetchTimeouts >= 3 && !self.prefetchCircuitBreakerTripped {
                        self.prefetchCircuitBreakerTripped = true
                        self.prefetchBreakerTrippedAt = Date()
                        debugLog("📺 GuideStore.prefetchIfNeeded: CIRCUIT BREAKER tripped — 3 consecutive per-cell timeouts, stopping per-cell prefetch for \(Int(self.prefetchBreakerCooldown))s cooldown")
                        // Cancel every already-queued task in the
                        // serial chain. By the time we trip, the
                        // chain is usually dozens deep (every
                        // visible cell's `.onAppear` from initial
                        // guide paint queued a task before the
                        // first three timeouts came back). Without
                        // this, those queued tasks keep walking the
                        // chain one by one, each firing a fresh
                        // 5-second request against a server we've
                        // already decided is unresponsive. The
                        // `Task.isCancelled` checks inside the task
                        // body catch the cancellation — cancelled
                        // tasks skip their fetch and return early.
                        let cancelledCount = self.pendingPrefetchTasks.count
                        for entry in self.pendingPrefetchTasks.values {
                            entry.task.cancel()
                        }
                        self.pendingPrefetchTasks.removeAll(keepingCapacity: true)
                        if cancelledCount > 0 {
                            debugLog("📺 GuideStore.prefetchIfNeeded: cancelled \(cancelledCount) queued prefetch task(s) on breaker trip")
                        }
                    }
                } else {
                    self.consecutivePrefetchTimeouts = 0
                }
                // Clear our slot in the pending map — but only if
                // we're still the registered task for this channel.
                // A newer `.onAppear` may have replaced our entry
                // while our fetch was running; in that case leaving
                // its entry in place keeps it cancellable on disappear
                // and prevents two in-flight fetches for the same
                // channel from racing.
                if self.pendingPrefetchTasks[channelID]?.id == submissionID {
                    self.pendingPrefetchTasks.removeValue(forKey: channelID)
                }
            }
        }

        pendingPrefetchTasks[channelID] = PendingPrefetch(id: submissionID, task: task)
        lastPrefetchTask = task
    }

    // MARK: - Merge Helper
    /// Adds a program to the store, avoiding duplicates, and keeps
    /// sorted by start time. MainActor-isolated wrapper — picks the
    /// right backing store (`_pendingPrograms` during a batch,
    /// `programs` otherwise) and delegates to the nonisolated static
    /// implementation so the logic can be shared with the
    /// `performXMLTVFetch` off-main merge path.
    private func mergeProgram(_ prog: GuideProgram, for channelID: String) {
        if _isBatching {
            Self.mergeProgramInto(&_pendingPrograms, program: prog, for: channelID)
        } else {
            Self.mergeProgramInto(&programs, program: prog, for: channelID)
        }
    }

    /// Pure data-manipulation version of `mergeProgram`. `nonisolated`
    /// + `static` so the XMLTV off-main merge loop can call it from
    /// inside a `Task.detached` against a local dictionary, without
    /// crossing the @MainActor boundary per iteration. Produces
    /// identical results to the instance method above.
    ///
    /// `deferSort: true` lets bulk callers (the 98k-iteration XMLTV
    /// merge) postpone sorting each channel's list until after all
    /// inserts land — one sort per channel instead of one per
    /// insert. For the single-item callers (Dispatcharr JSON fallback,
    /// Xtream per-channel fetch) the default `false` preserves the
    /// pre-refactor contract of "list is sorted on return."
    /// Minimum duration a programme must have to be drawable, in seconds.
    /// Shared by the live merge path and the disk-cache load path so both
    /// entry points into `programs` enforce the same invariant.
    nonisolated static let minDrawableDuration: TimeInterval = 30

    /// Strips programmes that cannot be rendered (end at or before start, or
    /// shorter than `minDrawableDuration`).
    ///
    /// `mergeProgramInto` guards the LIVE path, but the cache load assigns
    /// `programs` wholesale (`self.programs = loaded.dict`) and never goes
    /// through it. That is why the tvOS guide briefly drew correctly and then
    /// reverted to slivers: the fresh merge was clean, then the disk cache
    /// overwrote it with rows persisted before the guard existed. Filtering on
    /// load also heals caches already holding bad rows, without a migration.
    nonisolated static func drawableOnly(
        _ dict: [String: [GuideProgram]]
    ) -> [String: [GuideProgram]] {
        var out = dict
        for (channelID, list) in dict {
            let kept = list.filter {
                $0.end.timeIntervalSince($0.start) >= minDrawableDuration
            }
            if kept.count != list.count {
                if kept.isEmpty { out.removeValue(forKey: channelID) }
                else { out[channelID] = kept }
            }
        }
        return out
    }

    nonisolated static func mergeProgramInto(
        _ dict: inout [String: [GuideProgram]],
        program prog: GuideProgram,
        for channelID: String,
        deferSort: Bool = false
    ) {
        // Reject degenerate programmes at the single point every source funnels
        // through (bulk XMLTV, get_short_epg, Dispatcharr grid, catch-up).
        //
        // A programme whose end is at or before its start renders as a ~10px
        // vertical sliver with its title wrapped to one character per line --
        // the "weird formatting" visible on TVO / Global / City TV / CTV /
        // Yes TV in the tvOS guide on 2026-08-11. The per-source guards only
        // checked that the programme OVERLAPS the requested window
        // (`end > windowStart && start < windowEnd`), which a zero-length or
        // inverted programme satisfies happily. Nothing downstream can render
        // one sensibly, and the dedup pass below already has to special-case
        // `progDuration > 0`, so drop them here rather than teaching every
        // consumer to cope.
        //
        // 30s floor rather than 0: sub-30s "programmes" are feed noise
        // (placeholder or truncated entries), not schedule data, and they
        // produce the same unreadable sliver.
        guard prog.end.timeIntervalSince(prog.start) >= minDrawableDuration else { return }

        var list = dict[channelID] ?? []
        // Check for duplicate: same title + similar start time, OR
        // >80% time overlap. The overlap check catches feeds that
        // re-emit the same program with slightly-shifted timestamps
        // (e.g. 6 PM vs. 6:01 PM from two mirrored XMLTV sources).
        if let idx = list.firstIndex(where: { existing in
            if existing.title == prog.title && abs(existing.start.timeIntervalSince(prog.start)) < 60 {
                return true
            }
            let overlapStart = max(existing.start, prog.start)
            let overlapEnd   = min(existing.end, prog.end)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            let progDuration = prog.end.timeIntervalSince(prog.start)
            return progDuration > 0 && overlap > 0 && overlap / progDuration > 0.8
        }) {
            // Duplicate found. Build a merged GuideProgram so we
            // never drop a useful piece of metadata that one source
            // had and another didn't. Fields handled:
            //
            //   - description: take the longer one. seedFromChannels
            //     creates placeholders without description; later
            //     fetchUpcoming returns the same slot with a real
            //     `<desc>`. Keep the richer text.
            //   - category: prefer existing if non-empty. The
            //     bulk grid endpoint deliberately returns
            //     category="" for every program (Dispatcharr's
            //     hand-rolled serializer strips it). Without this
            //     guard, the second-pass grid call would clobber
            //     categories that `enrichDispatcharrCategories`
            //     wrote in a prior pass.
            //   - programID: prefer existing if set, else take
            //     new. v1.7.x: pre-v1.7.x SwiftData caches loaded
            //     with `programID = nil`. When the background
            //     fetchUpcoming brings a fresh grid response with
            //     real programIDs, the prior code path would skip
            //     the merge entirely (because the cached
            //     description was the same length or longer), and
            //     the new programID was dropped on the floor.
            //     Result: ProgramInfoView's lazy-load couldn't
            //     fire for non-now-airing programs, leaving them
            //     pill-less on cold-launch upgrades. Capturing
            //     the programID here closes that gap.
            let existing = list[idx]
            let mergedDescription = prog.description.count > existing.description.count
                ? prog.description
                : existing.description
            let mergedCategory = existing.category.isEmpty ? prog.category : existing.category
            let mergedProgramID = existing.programID ?? prog.programID
            // Badge metadata: never drop it during a dedup merge. A
            // seed/JSON entry may carry no flags while the XMLTV merge for
            // the same slot does (or vice versa), so coalesce optionals
            // and OR the Bools - whichever source has data wins.
            let mergedSubTitle = existing.subTitle ?? prog.subTitle
            let mergedSeason = existing.season ?? prog.season
            let mergedEpisode = existing.episode ?? prog.episode
            let mergedIsNew = existing.isNew || prog.isNew
            let mergedIsLiveBroadcast = existing.isLiveBroadcast || prog.isLiveBroadcast
            let mergedIsPremiere = existing.isPremiere || prog.isPremiere
            let mergedIsFinale = existing.isFinale || prog.isFinale
            let mergedIsRepeat = existing.isRepeat || prog.isRepeat
            let needsUpdate = mergedDescription != existing.description
                || mergedCategory != existing.category
                || mergedProgramID != existing.programID
                || mergedSubTitle != existing.subTitle
                || mergedSeason != existing.season
                || mergedEpisode != existing.episode
                || mergedIsNew != existing.isNew
                || mergedIsLiveBroadcast != existing.isLiveBroadcast
                || mergedIsPremiere != existing.isPremiere
                || mergedIsFinale != existing.isFinale
                || mergedIsRepeat != existing.isRepeat
            if needsUpdate {
                list[idx] = GuideProgram(
                    channelID: existing.channelID,
                    title: existing.title,
                    description: mergedDescription,
                    start: existing.start,
                    end: existing.end,
                    category: mergedCategory,
                    programID: mergedProgramID,
                    subTitle: mergedSubTitle,
                    season: mergedSeason,
                    episode: mergedEpisode,
                    isNew: mergedIsNew,
                    isLiveBroadcast: mergedIsLiveBroadcast,
                    isPremiere: mergedIsPremiere,
                    isFinale: mergedIsFinale,
                    isRepeat: mergedIsRepeat
                )
                dict[channelID] = list
            }
            return
        }
        list.append(prog)
        if !deferSort {
            list.sort { $0.start < $1.start }
        }
        dict[channelID] = list
    }

    // MARK: - Seed EPGCache for List-View Cards
    /// Populates the in-memory EPGCache (used by channel card expansion) from
    /// GuideStore data so that cards open instantly without a network fetch.
    /// Runs in a single background Task so 691 channels don't spawn 691 tasks and
    /// block the main thread with the building of entries.
    /// `async` so callers can await the write to `EPGCache` before
    /// dismissing the initial-sync loading cover. Prior version
    /// fire-and-forgot the detached work, which meant the cover
    /// could drop the user into Live TV while the seed was still
    /// running — and the first read of `fetchUpcoming` returned
    /// the JSON bulk's category-less entries, leaving expanded
    /// schedule rows uncolored (user feedback: "still not getting
    /// per-program gradient"). Callers inside the Guide view that
    /// don't care about completion can ignore the await.
    func seedEPGCache(channels: [ChannelDisplayItem], server: ServerConnection?) async {
        guard let server else { return }

        // Dedupe — see `lastSeedEPGCacheSignature` doc. On warm
        // relaunch three call sites fire this back-to-back with
        // identical inputs. The signature is set synchronously
        // BEFORE the `await Task.detached` suspension so concurrent
        // MainActor callers don't race past the check.
        let programCount = programs.values.reduce(0) { $0 + $1.count }
        let signature = "\(server.id.uuidString)|\(channels.count)|\(programCount)"
        if lastSeedEPGCacheSignature == signature {
            debugLog("📺 GuideStore.seedEPGCache: skip duplicate (signature=\(signature))")
            return
        }
        lastSeedEPGCacheSignature = signature

        let serverType = server.type
        let baseURL = server.effectiveBaseURL
        // Snapshot the programs dictionary (MainActor-isolated) before detaching
        let snapshot = programs
        let channelRefs: [(id: String, tvgID: String?)] = channels.map { ($0.id, $0.tvgID) }

        await Task.detached(priority: .utility) {
            let now = Date()
            var built: [(key: String, entries: [EPGEntry])] = []
            built.reserveCapacity(channelRefs.count)
            for ref in channelRefs {
                let tvgID = ref.tvgID ?? ""
                let cacheKey: String
                switch serverType {
                case .dispatcharrAPI:
                    cacheKey = "d_\(baseURL)_\(tvgID.isEmpty ? ref.id : tvgID)"
                case .xtreamCodes:
                    cacheKey = "x_\(baseURL)_\(ref.id)"
                case .m3uPlaylist:
                    guard !tvgID.isEmpty else { continue }
                    cacheKey = "m3u_\(tvgID)"
                }
                guard let progs = snapshot[ref.id], !progs.isEmpty else { continue }
                let entries = progs
                    .filter { $0.end > now }
                    .sorted { $0.start < $1.start }
                    .map {
                        // Passing `category: $0.category` is the bridge
                        // that lets the List-view expanded panel render
                        // per-program gradient tints the same way the
                        // Guide view does — both read from this same
                        // GuideStore dataset, so there's no risk of one
                        // view showing a category color the other doesn't.
                        EPGEntry(title: $0.title, description: $0.description,
                                 startTime: $0.start, endTime: $0.end,
                                 category: $0.category)
                    }
                guard !entries.isEmpty else { continue }
                built.append((cacheKey, entries))
            }
            // Write all entries to the actor-protected cache
            for item in built {
                await EPGCache.shared.set(item.entries, for: item.key)
            }
            debugLog("📺 GuideStore.seedEPGCache: seeded \(built.count) entries (background)")
        }.value
    }

    // MARK: - Helpers
    nonisolated private static func parseXtreamDate(_ s: String) -> Date? {
        XtreamDateParser.parse(s)
    }
}

// MARK: - EPG Guide View
struct EPGGuideView: View {
    let channels: [ChannelDisplayItem]
    let servers: [ServerConnection]
    let onSelectChannel: (ChannelDisplayItem) -> Void
    /// Docked group sidebar (Group Selection: Sidebar Menu) state, threaded
    /// from ChannelListView. When true the grid cells go non-focusable so the
    /// sidebar owns focus and Right can't escape into the guide (tvOS analog of
    /// Android's onPreviewKeyEvent-consumes-Right). Default false = no change.
    var sidebarOpen: Bool = false
    /// Called with the focused now-airing program id when a short-Left on the
    /// now column should open the group sidebar (sidebar mode only).
    /// Optional programme id = the cell to restore focus to when the sidebar
    /// closes. nil when nothing is focused (GH #72: an empty group has no
    /// cells, and the hold must still open the sidebar).
    var onRequestGroupSidebar: ((String?) -> Void)? = nil
    /// Single-flight guard for the return-from-player focus restore: the
    /// notification arrives more than once per minimize (log 2026-08-28:
    /// two handler runs ~50ms apart), and two overlapping scroll+assert
    /// tasks ping-pong focus visibly. New trigger cancels the old task.
    @State private var focusRestoreTask: Task<Void, Never>?

    // Observe the shared GuideStore so its loading state is visible to
    // MainTabView's initial-sync loading cover (see HomeView's
    // `initialSyncKey`). Using `.shared` instead of instantiating per-view
    // also means the guide keeps its populated programs dictionary across
    // view mounts — no more blank guide on a tab switch while XMLTV
    // re-parses from scratch.
    @ObservedObject private var guideStore = GuideStore.shared
    /// v1.7.x: observed so the staging banner appears / disappears
    /// when `isStagingFromGuide` flips, and so the cell-level tap
    /// behavior swaps between "play" and "toggle in pile". Shared
    /// singleton; observation cost is the same as having the cells
    /// observe it directly, with the bonus that the top-level
    /// banner can react to `tiles.count` changes too.
    @ObservedObject private var multiviewStore = MultiviewStore.shared
    @EnvironmentObject private var channelStore: ChannelStore
    @Environment(\.modelContext) private var modelContext
    @State private var _epgCacheIsFresh = false

/// The channel row that `resetFocus(in: guideFocusNS)` on tvOS
    /// should land on. Set before each `.forceGuideFocus` reset to the
    /// currently-playing channel (single-stream) or the last-added
    /// tile's channel (multiview). Nil falls back to `channels.first`
    /// — the historical default. Only set within the tvOS `.forceGuideFocus`
    /// handler; always nil on iOS, so the inline `focusTargetID`
    /// resolution falls through to `channels.first?.id`.
    @State private var guideFocusTargetChannelID: String? = nil

    /// v1.7.x: transient toast string for staging actions ("Added X
    /// to Multiview", "Removed Y", "Max reached", etc.). Set by
    /// `handleMultiviewIntent`; auto-clears after ~2.5s via the
    /// `showStagingToast` helper. Same pattern as
    /// `AddToMultiviewSheet.toastMessage`.
    @State private var stagingToast: String? = nil
    /// Catch-up: the resolved timeshift playback being presented full
    /// screen (recordings-pattern presentation), or nil when none.
    @State private var playingCatchup: CatchupPlayback? = nil
    /// Catch-up: user-facing resolve failure (missing XC password,
    /// unsupported server, URL build failure), shown as an alert.
    @State private var catchupErrorMessage: String? = nil

    /// Hoisted out of `.alert(isPresented:)`. Written inline there, the
    /// `Binding(get:set:)` literal trips Swift's type-inference budget on Xcode
    /// 26.6 ("unable to type-check this expression in reasonable time"); 27's
    /// checker accepts it. App Store builds have to come from the RELEASE
    /// toolchain, so this has to compile on 26.6. Naming the type is what makes
    /// it cheap - the solver no longer has to infer it through the alert call.
    private var catchupErrorAlertPresented: Binding<Bool> {
        Binding(
            get: { catchupErrorMessage != nil },
            set: { if !$0 { catchupErrorMessage = nil } }
        )
    }
    #if os(iOS)
    /// GH #20 (Android parity): hide the iPhone tab bar while the guide
    /// scrolls down; any upward scroll reveals it (TabBarScrollTracker).
    /// Same phone gate as ChannelListView; iPad keeps its bar.
    @State private var guideTabBarHidden = false
    @State private var tabBarTracker = TabBarScrollTracker()
    /// Drives the width-adaptive channel-rail width: compact width (iPhone
    /// portrait, folded foldable) uses a narrower rail so it doesn't eat the
    /// small screen; regular width (iPad, unfolded foldable) keeps the wider
    /// rail. Matches the Android guide, which narrowed its rail for the same
    /// reason.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(tvOS)
    /// Programmatic focus target for a channel row's left-hand cell.
    /// Normally nil (focus engine drives navigation).
    @FocusState private var focusedChannelID: String?

    /// Programmatic focus target keyed by PROGRAM id. The program cells are
    /// the real focusable elements in the grid (the channel column stays a
    /// non-focusable label, which keeps D-pad navigation on the programs).
    /// Each cell binds `.focused($focusedProgramID, equals: prog.id)`, so
    /// the return-from-player / Menu-to-top handlers can land focus on a
    /// specific channel's now-airing program by setting this. Driving a
    /// SwiftUI-native focusable (the cells are now `.focusable()`, not a
    /// UIKit press overlay) is what finally makes the restore work.
    @FocusState private var focusedProgramID: String?

    /// Task #185 (guide "gets away"): channel of the previously focused
    /// programme, so the vertical-move corrective snap can tell a channel
    /// change (UP/DOWN, needs column correction) from a same-row change
    /// (our own snap / restore, must not loop).
    @State private var lastFocusedChannelForSnap: String?

    /// iOS #66: channel index a page move is currently asserting focus onto.
    /// Rapid channel-key presses arrive while the previous write is still in
    /// flight and focusedProgramID reads nil between unfocus and focus - the
    /// exact bug the Android pager hit - so the next press chains off this
    /// instead of bailing.
    @State private var pagePendingChannelIndex: Int?
    /// Task #185: guards the corrective snap's own focus writes from
    /// re-triggering a second snap while the first is still asserting.
    @State private var verticalSnapInFlight = false

    /// #42: while a hold-Right (close corner mini) is in progress, pin the guide
    /// timeline so the still-held Right does not scroll the EPG forward after the
    /// mini closes. Gated in `onMoveCommand(.right)`; driven by the
    /// `.guideRightHold*` notifications with a 2.5s safety backstop.
    @State private var rightHoldPinningTimeline = false
    @State private var rightHoldSafetyTask: Task<Void, Never>?
    /// Timeline offset before the most recent Right-step. A hold-Right
    /// close-mini gesture delivers its press-down as a normal Right
    /// move BEFORE the 0.5s hold recognizes, so the guide scrolls one
    /// step it should not have; the holdBegan handler reverts to this.
    @State private var preRightStepOffset: CGFloat?
    /// When the offset above was last touched; lets repeats of one held press
    /// share a single capture while a fresh gesture re-captures.
    @State private var preRightStepAt = Date.distantPast

    /// Namespace + imperative reset hook for the guide's focus
    /// scope. See ChannelListView's identical setup for the full
    /// rationale — `resetFocus(in:)` is the only reliable way to
    /// pull focus back into the guide from a minimized mini-player
    /// tile, because tvOS's focus engine has already committed to
    /// the mini by the time a plain `@FocusState` write can fire.
    @Namespace private var guideFocusNS
    @Environment(\.resetFocus) private var resetFocus

    #endif

    // Time window: 1h back + user-configured hours forward.
    //
    // `hoursForward` reads `epgWindowHours` from Settings → "EPG
    // Window" (see SettingsView.swift: options are 6/12/24/36/48/72
    // and "All available" = 0). The same `raw > 0 ? raw : 36`
    // formula is used by the EPG *fetch* layer in three places in
    // this file (effectiveWindowHours), so rendering matches the
    // data actually downloaded.
    //
    // Before this was a computed property the grid was hardcoded to
    // 3h forward regardless of the Settings picker — users saw
    // only ~2.5 hours ahead and horizontal scroll felt broken
    // because there was nothing left to scroll to. The computed
    // form also means toggling Settings live updates the grid on
    // the next render without any observer plumbing.
    // Catch-up: the grid scrolls back through aired programmes. Capped at
    // 24h (not the full retention) because every visible row lays out one
    // cell per programme across the whole window -- 7 days of columns
    // would multiply the per-row cell count ~5x on tvOS. Deeper history
    // stays reachable from the channel list's expanded schedule panel,
    // which lists ALL retained aired programmes.
    private var hoursBack: TimeInterval {
        min(TimeInterval(GuideStore.activeRetentionDays()) * 24, 24)
    }
    private var hoursForward: TimeInterval {
        let raw = UserDefaults.standard.integer(forKey: "epgWindowHours")
        return TimeInterval(raw > 0 ? raw : 36)
    }
    private var windowStart: Date { Date().addingTimeInterval(-hoursBack * 3600) }
    private var windowEnd: Date { Date().addingTimeInterval(hoursForward * 3600) }
    private var totalDuration: TimeInterval { (hoursBack + hoursForward) * 3600 }

    // Layout constants
    #if os(tvOS)
    private let channelColumnWidth: CGFloat = 240
    private let rowHeight: CGFloat = 110
    private let timeHeaderHeight: CGFloat = 50
    private let pixelsPerHour: CGFloat = 600
    private let cellGap: CGFloat = 1        // hairline gap between program cells (Emby style)
    private let rowGap: CGFloat = 1         // hairline gap between rows
    #else
    /// User-controllable guide scale (Settings → Network → Guide Display →
    /// Guide Size). Range 0.75…1.5, default 1.0. Multiplies the iOS/iPadOS/Mac
    /// layout constants below so the whole grid (column width, row height,
    /// header height, pixels-per-hour, and per-cell font sizes — see
    /// `GuideProgramButton.cellContent`) scales together. tvOS uses fixed
    /// constants because the slider isn't exposed there.
    @AppStorage("guideScale") private var guideScale: Double = 1.0
    /// Width-adaptive: a 100pt rail eats roughly a quarter of a 375pt phone,
    /// so compact width narrows it to 78pt. Regular width (iPad, unfolded
    /// foldable) keeps 100pt. Both still scale with guideScale.
    private var channelColumnWidth: CGFloat { (horizontalSizeClass == .compact ? 78 : 100) * guideScale }
    private var rowHeight: CGFloat { 72 * guideScale }
    private var timeHeaderHeight: CGFloat { 32 * guideScale }
    private var pixelsPerHour: CGFloat { 360 * guideScale }
    private let cellGap: CGFloat = 1
    private let rowGap: CGFloat = 1
    #endif

    private var totalGridWidth: CGFloat { pixelsPerHour * CGFloat(hoursBack + hoursForward) }

    // Timer removed — time indicator uses TimelineView instead (avoids full view invalidation)

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    var body: some View {
        bodyContent
            .animation(.easeInOut(duration: 0.2), value: stagingToast)
            .animation(.easeInOut(duration: 0.2), value: multiviewStore.isStagingFromGuide)
        #if os(tvOS)
            .ignoresSafeArea(.all, edges: [.leading, .trailing, .bottom])
        #endif
            .task(id: channels.count) {
                guard !channels.isEmpty else { return }
                // Reset the rolling-prefetch "already fetched" set
                // every time the channel list changes (server switch,
                // initial load, iCloud-sync import). Otherwise the
                // set poisoned subsequent scroll cycles: a cell that
                // got fetched empty would stay flagged forever and
                // never retry, producing the GH #3 "scroll past and
                // come back, cell is empty" regression. This line +
                // the "only insert on non-empty fetch" change in
                // `prefetchIfNeeded` together close the loop.
                guideStore.resetPrefetchCache()

                let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                let activeServerID = activeServer?.id.uuidString ?? "unknown"

                // Phase 0: load from persistent SwiftData cache (scoped to active
                // server so orphaned rows from a deleted server can't populate
                // the guide with mismatched channel IDs).
                let cacheIsFresh = await guideStore.loadFromCache(modelContext: modelContext, channels: channels, serverID: activeServerID)
                // Phase 1: seed from current-program data on channels (fills gaps)
                guideStore.seedFromChannels(channels)
                // Seed EPGCache so List-view card expansion is instant
                await guideStore.seedEPGCache(channels: channels, server: activeServer)

                // Phase 2: fetch from network only if cache is stale.
                // Also fetch if the cache has no future programs (e.g., fresh install with only
                // seedFromChannels data: only current programs, nothing upcoming).
                //
                // The previous form (`.values.flatMap { $0 }.contains { … }`)
                // eagerly allocated a flattened Array across every cached
                // program on the main thread; on the 97k-row torture-test
                // playlist that's a 15+ MB alloc and a ~2-3s hang per call.
                // The nested-contains form short-circuits twice: outer on
                // the first channel with any future program, inner on the
                // first future program in that channel. On a healthy EPG
                // cache this is effectively O(1).
                // A program that has NOT STARTED yet means genuine upcoming
                // schedule is cached. The previous `end > now+30min` test was
                // satisfied by the single still-airing program that
                // seedFromChannels seeds per channel, so a cache holding only
                // current programs (e.g. after a silent grid-fetch failure)
                // looked complete and the network refetch was skipped, leaving
                // the guide stuck on the now-playing show with everything in
                // the future blank. `start > now` excludes the airing program
                // and is true only when real future programming is present.
                let gateNow = Date()
                // Identity invariant (matches the orchestrator gate in
                // HomeView): only rows keyed to a channel the guide can
                // display count. Rows keyed to channels that no longer exist
                // are orphans, and a cache that does not match the current
                // channel identity is stale regardless of age; letting
                // orphans satisfy this guard skips the network while the
                // guide renders blank.
                let liveChannelIDs = Set(channels.map(\.id))
                let hasFuturePrograms = guideStore.programs.contains { channelID, progs in
                    liveChannelIDs.contains(channelID) && progs.contains { $0.start > gateNow }
                }
                guard !cacheIsFresh || !hasFuturePrograms else {
                    debugLog("📺 EPG cache is fresh with future programs; skipping network fetch")
                    return
                }
                channelStore.isEPGLoading = true
                await guideStore.fetchUpcoming(channels: channels, servers: servers)
                // Save fetched data to persistent cache
                let serverID = activeServer?.id.uuidString ?? "unknown"
                guideStore.saveToCache(modelContext: modelContext, serverID: serverID)
                // Re-seed EPGCache with freshly fetched data
                await guideStore.seedEPGCache(channels: channels, server: activeServer)
                channelStore.isEPGLoading = false
            }
            // When MainTabView's loadAllEPG() finishes, re-seed guide from EPGCache
            .onChange(of: channelStore.isEPGLoading) { wasLoading, isLoading in
                if wasLoading && !isLoading && !channels.isEmpty {
                    let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                    guideStore.seedFromChannels(channels)
                    Task {
                        await guideStore.seedEPGCache(channels: channels, server: activeServer)
                    }
                }
            }
    }

    /// Body shell that swaps the staging-banner placement strategy
    /// per platform. iOS pins the banner via `safeAreaInset(edge:
    /// .top)` so it stays above the scrolling guide content. tvOS
    /// places the banner as a sibling of `guideContent` in a `VStack`
    /// so the focus engine's spatial search routes from the topmost
    /// guide row up into the banner buttons. (`safeAreaInset` on
    /// tvOS doesn't reliably participate in focus traversal, which
    /// was the symptom Freyguy1975 reported in v1.7.2: he could SEE
    /// the Done button but couldn't D-pad to it.)
    @ViewBuilder
    private var bodyContent: some View {
        #if os(tvOS)
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                if multiviewStore.isStagingFromGuide {
                    stagingBanner
                }
                guideContent
            }
            stagingToastOverlay
        }
        #else
        ZStack {
            Color.appBackground.ignoresSafeArea()
            guideContent
            stagingToastOverlay
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if multiviewStore.isStagingFromGuide {
                stagingBanner
            }
        }
        #endif
    }

    /// Staging-mode toast bottom-center. Sits in the ZStack rather
    /// than as a sibling modifier so it floats above the guide grid
    /// (including the horizontal ScrollView contents) while staying
    /// out of the way of the time header and channel column.
    @ViewBuilder
    private var stagingToastOverlay: some View {
        if let msg = stagingToast {
            VStack {
                Spacer()
                stagingToastView(msg)
                    .padding(.bottom, 32)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Horizontal Scroll State
    // Manual horizontal offset — only changes when user explicitly scrolls (drag/swipe).
    // Focus changes do NOT cause horizontal movement.
    // Initial value positions "now" at the left edge of the visible area.
    // The literal defaults assume the legacy 1h-back window; the guide's
    // .onAppear immediately re-lands on "now" using the real catch-up
    // history depth (hoursBack * pixelsPerHour), gated by
    // `didSetInitialGuideOffset` so later size changes don't re-jump.
    #if os(tvOS)
    @State private var horizontalOffset: CGFloat = -600  // -(hoursBack=1 * pixelsPerHour=600)
    #else
    @State private var horizontalOffset: CGFloat = -360  // -(hoursBack=1 * pixelsPerHour=360)
    #endif
    @State private var didSetInitialGuideOffset = false

    /// Captured `horizontalOffset` at the start of an active drag
    /// gesture. `DragGesture.Value.translation` is cumulative from
    /// the gesture's start, so we need a baseline to add it to.
    /// `nil` = no drag in progress; any callback sets it on first
    /// frame and clears it on `.onEnded`.
    #if os(iOS)
    @State private var dragBaselineOffset: CGFloat? = nil
    #endif

    /// Maximum the user can scroll right (negative = content shifts left).
    /// Uses the visible program area width (screen minus channel column).
    @State private var visibleProgramWidth: CGFloat = 600
    private var maxHorizontalOffset: CGFloat {
        min(0, -(totalGridWidth - visibleProgramWidth))
    }

    // MARK: - Guide Content
    // Vertical ScrollView + LazyVStack for rows.
    // Horizontal position is driven by manual @State offset, not ScrollView,
    // so focus changes never cause horizontal jumps.
    private var guideContent: some View {
        GeometryReader { geo in
            // `ScrollViewReader` so the Menu-button handler on tvOS
            // (see HomeView → posts `.guideScrollToTop`) can jump the
            // guide back to the first channel. The `Color.clear`
            // anchor with `.id("guide.top")` is the first child of the
            // LazyVStack (above the ForEach), so `.scrollTo(..., anchor:
            // .top)` pins it to the top of the scroll viewport — i.e.
            // just below the fixed time-header bar (now a sibling above
            // the ScrollView, no longer a pinned section header), which
            // is exactly where the first channel row belongs.
            ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // ── Fixed time header ──
                // Lifted OUT of the LazyVStack's pinned `Section` header.
                // tvOS 27's AttributeGraph aborts (precondition_failure,
                // input_value_ref_slow, 0 app frames) when the pinned-
                // section-header path reduces its DisplayList.Key /
                // LazyPreference during scroll-recycle layout — confirmed
                // on-device 2026-06-16 (3 identical .ips, guide-scroll under
                // cold-start load). A plain fixed bar above the ScrollView is
                // visually identical (it reads `horizontalOffset` so the time
                // strip stays synced with the program cells) and keeps that
                // machinery out of the scroll-recycle path entirely.
                guideTimeHeader(geoWidth: geo.size.width)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: rowGap) {
                        Color.clear
                            .frame(height: 0)
                            .id("guide.top")
                        // Resolve the focus target once before the
                        // ForEach so the O(n) channels scan happens
                        // once per render pass rather than once per
                        // row. Each guideRow receives the pre-resolved
                        // value and does a single O(1) equality check.
                        let focusTargetID: String? = guideFocusTargetChannelID.flatMap { id in
                            channels.first(where: { $0.id == id })?.id
                        } ?? channels.first?.id
                        // Keyed by the channel id (Identifiable), not the
                        // stream URL, because the guide's focus + scroll
                        // restore targets rows by id (focusedChannelID,
                        // proxy.scrollTo(channelID)). The channel list is
                        // deduped by stream URL at load time, so these ids
                        // are unique even when a provider reuses a tvg-id
                        // across distinct channels.
                        ForEach(channels) { channel in
                            guideRow(for: channel, screenWidth: geo.size.width, focusTargetID: focusTargetID)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            timeIndicatorLine(screenWidth: geo.size.width, now: context.date)
                                .allowsHitTesting(false)
                        }
                    }
                }
                #if os(iOS)
                // GH #20 (Android parity): auto-hide the iPhone tab bar on
                // vertical guide scroll. Direction-based (2026-07-12): hide
                // on a deliberate downward scroll, full bar back on any
                // upward scroll (TabBarScrollTracker); only vertical offset
                // is observed so timeline scrubbing can't toggle the bar.
                .onScrollGeometryChange(for: CGFloat.self) { scrollGeo in
                    scrollGeo.contentOffset.y
                } action: { oldY, y in
                    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
                    if let hidden = tabBarTracker.update(oldY: oldY, newY: y,
                                                         hidden: guideTabBarHidden) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            guideTabBarHidden = hidden
                        }
                    }
                }
                .scrollAwayTabBar(collapsed: guideTabBarHidden)
                #endif
            .clipped()
            #if os(iOS)
            // iOS 26: the Guide is now shown on iPhone too, and it was missing
            // the tab-bar treatment the List already has. Without it the hard
            // bottom scroll-edge effect paints an opaque platter behind the
            // floating tab bar (the "solid bar" regression). Same fix as
            // ChannelListView: hide the bottom scroll-edge effect so guide rows
            // sit cleanly under the floating bar. The container already extends
            // under the bar via .ignoresSafeArea(.bottom) above.
            .aerioContentUnderTabBar()
            #endif
            .onAppear {
                visibleProgramWidth = geo.size.width - channelColumnWidth
                // Audit #50: seed the guide-cell recording markers so the red
                // "set to record" dot renders on first guide open, before any
                // recording mutation or reconcile has refreshed the snapshot.
                RecordingCoordinator.shared.refreshGuideRecordingMarkers(modelContext: modelContext)
                // Task #185: anchor "now" left-aligned (15-min lead) fresh
                // from the wall clock on EVERY appear when the timeline is
                // stale. The old one-shot `-hoursBack * pixelsPerHour` was
                // computed against the view's BUILD time and never refreshed,
                // so a guide revisited hours later opened that far in the
                // past (the "sometimes launches wrong" report - it tracked
                // how long the view had been alive). First appear anchors
                // unanimated before first paint; re-appears only correct
                // when the timeline drifted from now (a user mid-browse
                // within the slop is left alone).
                if !didSetInitialGuideOffset {
                    didSetInitialGuideOffset = true
                    reAnchorTimelineToNow(animated: false)
                } else if timelineIsAwayFromNow() {
                    reAnchorTimelineToNow(animated: false)
                }
            }
            .onChange(of: geo.size.width) { _, w in visibleProgramWidth = w - channelColumnWidth }
            #if os(iOS)
            // iOS-only: `guideScale` (the Settings -> Appearance -> Display
            // Scale -> Guide slider) exists only on iOS; the tvOS guide uses
            // fixed sizing and has no scale slider, so there is nothing to
            // re-anchor there. When the scale changes, pixelsPerHour changes but
            // horizontalOffset (points) does NOT, so the same offset now maps to
            // a different wall-clock time and the grid can jump into an empty
            // window and blank (the Android TV report, same code shape here).
            // Re-anchor to "now" at the new scale, clamped to the valid range.
            // This guide has no live pinch, so guideScale only changes from the
            // discrete slider and this never fights a gesture.
            .onChange(of: guideScale) { _, _ in
                horizontalOffset = min(0, max(maxHorizontalOffset, -CGFloat(hoursBack) * pixelsPerHour))
            }
            #endif
            #if os(iOS)
            // Horizontal drag for scrubbing the guide timeline.
            // Uses `.simultaneousGesture` so it coexists with the
            // outer `ScrollView(.vertical)`'s internal pan — the
            // earlier approach (`HorizontalPanGestureView`, a
            // `PassthroughView` + `UIPanGestureRecognizer` overlay)
            // had been silently broken on iPad: `PassthroughView`'s
            // `hitTest` returned nil on every touch, which in turn
            // prevented UIKit from routing touches to the attached
            // pan recognizer. The bug was invisible when
            // `hoursForward` was hardcoded to 3 because there was
            // almost nothing to scroll to, but became obvious once
            // the grid grew to 36+ hours via the Settings picker.
            //
            // We keep `abs(width) > abs(height)` filtering so a
            // primarily-vertical drag (row scrolling) doesn't steal
            // the horizontal offset, and `.simultaneousGesture`
            // explicitly tells SwiftUI not to race this against
            // ScrollView's own pan — both fire in parallel.
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if dragBaselineOffset == nil {
                            dragBaselineOffset = horizontalOffset
                        }
                        guard let base = dragBaselineOffset else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let target = base + value.translation.width
                        horizontalOffset = min(0, max(maxHorizontalOffset, target))
                    }
                    .onEnded { value in
                        let base = dragBaselineOffset ?? horizontalOffset
                        // `predictedEndTranslation` gives us flick
                        // momentum — iOS's built-in projection based
                        // on the release velocity — so fast swipes
                        // keep gliding instead of stopping dead.
                        let projected = base + value.predictedEndTranslation.width
                        withAnimation(.easeOut(duration: 0.25)) {
                            horizontalOffset = min(0, max(maxHorizontalOffset, projected))
                        }
                        dragBaselineOffset = nil
                    }
            )
            #endif
            #if os(tvOS)
            // iOS #66 (knmplace): channel up/down page the guide. The Siri
            // Remote has no channel buttons, but tvOS maps the channel keys
            // of CEC-bridged TV remotes to .pageUp/.pageDown presses
            // (tvOS 14.3+), so this serves every "I use my TV's remote"
            // setup. Window-level catcher because the presses route to the
            // focused cell, not to any ancestor this background could own.
            .background(pagePressCatcher(proxy: proxy))
            .onMoveCommand { handleGuideMoveCommand($0) }
            // Task #185: vertical corrective snap. UP/DOWN still move focus via
            // the system focus engine, but the engine picks by raw geometry
            // (widest overlap with the outgoing cell), which drifts the column
            // - most visibly landing on programmes that ENDED hours ago when
            // the outgoing cell was long. When focus lands on a DIFFERENT
            // channel and the landed cell does not contain the viewport anchor
            // column, snap to the cell that does. Same-channel changes (our
            // own snaps/restores/pans) are ignored so this can never loop.
            .onChange(of: focusedProgramID) { _, newValue in
                guard let pid = newValue else { lastFocusedChannelForSnap = nil; return }
                let chID = channelID(ofProgram: pid)
                defer { lastFocusedChannelForSnap = chID }
                guard let chID,
                      let previous = lastFocusedChannelForSnap,
                      previous != chID,
                      !verticalSnapInFlight else { return }
                let anchor = viewportAnchorTime
                let progs = guideStore.programs[chID] ?? []
                guard let landed = progs.first(where: { $0.id == pid }) else { return }
                // Engine already picked the anchor-column cell: nothing to do.
                if landed.start <= anchor && anchor < landed.end { return }
                guard let target = programID(forChannel: chID, containing: anchor),
                      target != pid else { return }
                verticalSnapInFlight = true
                debugLog("🧭 [GuideFocus] column snap ch=\(chID) landed=\(landed.start) -> anchor cell")
                Task { @MainActor in
                    for _ in 0..<4 {
                        focusedProgramID = target
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        if focusedProgramID == target { break }
                    }
                    verticalSnapInFlight = false
                }
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .guideRightHoldBegan)) { _ in
                #if os(tvOS)
                // Freeze the EPG timeline for the duration of the close-mini hold.
                // A safety backstop clears the pin if the release event is missed.
                rightHoldPinningTimeline = true
                // The hold's press-down already scrolled one step before
                // recognition; put the timeline back where it was.
                if let restore = preRightStepOffset {
                    withAnimation(.easeOut(duration: 0.3)) { horizontalOffset = restore }
                    preRightStepOffset = nil
                    // The pre-recognition step already RETARGETED focus one
                    // column right; putting the offset back without moving
                    // focus left the focused cell visibly walked to the right
                    // (Logan 2026-08-12). Re-anchor focus to the restored
                    // viewport as well.
                    retargetFocusToViewportColumn()
                }
                rightHoldSafetyTask?.cancel()
                rightHoldSafetyTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if !Task.isCancelled { rightHoldPinningTimeline = false }
                }
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .guideRightHoldEnded)) { _ in
                #if os(tvOS)
                rightHoldPinningTimeline = false
                rightHoldSafetyTask?.cancel()
                rightHoldSafetyTask = nil
                #endif
            }
            // Hold Right to close the corner mini-player. The detector was
            // wired into the LIST view only; the Guide (where tvOS users
            // actually live) merely LISTENED for the pinning notifications
            // and never armed it, so hold-Right did nothing here (ATV
            // field report: "can't stop playback"). Isolated in a wrapper
            // view so this perf-sensitive body does not re-render on
            // every NowPlayingManager publish.
            .background(GuideMiniCloseRightHoldArm())
            .fullScreenCover(item: $playingCatchup) { pb in
                // Catch-up playback: the recordings-pattern presentation.
                // PlayerSession.exit() already silenced any live session
                // before this cover was set, so exactly one player runs.
                PlayerView(
                    urls: [pb.url],
                    title: pb.title,
                    headers: pb.headers,
                    isLive: false,
                    isDVR: false,
                    catchup: pb
                )
            }
            .alert("Catch-up Unavailable",
                   isPresented: catchupErrorAlertPresented) {
                Button("OK", role: .cancel) { catchupErrorMessage = nil }
            } message: {
                Text(catchupErrorMessage ?? "")
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .guideScrollToTop)
            ) { _ in
                #if os(tvOS)
                // Menu on the guide = jump focus to the very top channel.
                // resetFocus alone does NOT honor prefersDefaultFocus in this
                // grid (it lands on whatever row is topmost-realized after the
                // scroll, e.g. ch16 instead of ch1), so we drive the
                // @FocusState target directly: instant-scroll the top row into
                // view to realize it, then re-assert focusedChannelID until the
                // engine accepts it (a single write is dropped while the row is
                // still laying out). The readback log shows what actually stuck.
                // Task #185: the same press also restores a wandered timeline
                // to left-aligned now - "return to top channel" with the axis
                // still hours in the future was useless. This keeps the sacred
                // Menu semantics (top channel) and completes the home position.
                if timelineIsAwayFromNow() { reAnchorTimelineToNow() }
                Task { @MainActor in
                    // Focus the top of the guide. Channel-column cells are non-
                    // focusable on tvOS, so we focus a PROGRAM cell via
                    // focusedProgramID. The very top channel frequently has no
                    // guide data (focusTargetProgramID nil); resolveFocusProgramID
                    // then scans down for the first channel that DOES, so focus
                    // lands on a real cell near the top instead of bailing to the
                    // List toggle (the reported bug). The viewport stays pinned to
                    // guide.top so channel 1 is the topmost visible row.
                    guard let target = resolveFocusProgramID(preferringChannel: channels.first?.id) else {
                        proxy.scrollTo("guide.top", anchor: .top); return
                    }
                    debugLog("🧭 [GuideFocus] scrollToTop(epg) → prog=\(target) count=\(channels.count)")
                    for attempt in 0..<8 {
                        proxy.scrollTo("guide.top", anchor: .top)
                        focusedProgramID = target
                        try? await Task.sleep(nanoseconds: 70_000_000)
                        debugLog("🧭 [GuideFocus] assert(top) attempt=\(attempt) set=\(target) got=\(focusedProgramID ?? "nil")")
                        if focusedProgramID == target { break }
                    }
                    // The focus engine reveal-scrolls the freshly focused cell
                    // and can stop a row short of the absolute top, leaving the
                    // first channel hidden just above the viewport. Let the
                    // engine settle, then force the top so ch1 is the topmost
                    // visible row.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    proxy.scrollTo("guide.top", anchor: .top)
                    debugLog("🧭 [GuideFocus] scrollToTop(epg) final force-top, focus=\(focusedProgramID ?? "nil")")
                }
                #else
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("guide.top", anchor: .top)
                }
                #endif
            }
            #if os(tvOS)
            // Remote Control #196: mapped guide actions posted by
            // GuideRemoteDispatch (hold-Left / hold-Right / hold-Select
            // handlers). Receivers ride a background child - even three
            // slim modifiers appended directly pushed this already-huge
            // body over the type-checker's budget.
            .background(guideRemoteReceivers(proxy: proxy))
            #endif
            // EPG-search jump: consume a pending guide target (set by
            // SearchView) and scroll to that channel + program time.
            // Warm path (guide already on screen) and cold path (guide
            // just mounted / channels just loaded) both route through
            // the same idempotent, guarded consume.
            .onReceive(NotificationCenter.default.publisher(for: .aerioJumpToGuideProgram)) { _ in
                consumePendingGuideJump(proxy: proxy)
            }
            .task(id: channels.count) {
                consumePendingGuideJump(proxy: proxy)
            }
            #if os(tvOS)
            .focusScope(guideFocusNS)
            .onReceive(
                NotificationCenter.default.publisher(for: .forceGuideFocus)
            ) { _ in
                // All work runs on the main actor so @MainActor-
                // isolated singletons (MultiviewStore, NowPlayingManager)
                // and @State mutations are accessed safely regardless
                // of which thread NotificationCenter delivers on.
                if focusRestoreTask != nil { debugLog("🧭 [GuideFocus] superseding prior restore task") }
                focusRestoreTask?.cancel()
                focusRestoreTask = Task { @MainActor in
                    // TEST (branch test/avplayer-hls-engine): the native
                    // AVPlayer cover keeps PlayerSession.mode at .idle,
                    // so without this guard the guide's focus restore
                    // would steal focus from the presented cover (the
                    // delayed resetFocus below lands AFTER the cover
                    // presents), leaving the remote driving the guide
                    // behind fullscreen video.
                    guard PlayerSession.shared.nativeHLSItem == nil else {
                        debugLog("[GuideFocus] forceGuideFocus suppressed (native player presented)")
                        return
                    }
                    // Resolve target: use the last-added multiview tile
                    // (keyed by addedAt, not array order which can change
                    // via drag-rearrange), then fall back to the single-
                    // stream playing item, then nil for the top row.
                    let mvLastID = MultiviewStore.shared.tiles
                        .max(by: { $0.addedAt < $1.addedAt })?.item.id
                    let singleID = NowPlayingManager.shared.playingItem?.id
                    let candidateID = mvLastID ?? singleID
                    // The 400ms delay covers the 350ms minimize spring
                    // animation; triggering during it lets tvOS ignore the
                    // reset because the mini tile's frame is still in flux.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { return }
                    // Re-validate against the current (possibly filtered)
                    // channel list AFTER the delay, in case it changed.
                    let valid = candidateID.flatMap { id in
                        channels.first(where: { $0.id == id })?.id
                    }
                    guideFocusTargetChannelID = valid
                    debugLog("🧭 [GuideFocus] forceGuideFocus(epg) → mvLast=\(mvLastID ?? "nil") single=\(singleID ?? "nil") valid=\(valid ?? "nil") count=\(channels.count)")
                    guard let valid else { resetFocus(in: guideFocusNS); return }
                    // Focus the watched channel's PROGRAM cell (channel-column
                    // cells are non-focusable on tvOS). resolveFocusProgramID falls
                    // back to the nearest channel-with-guide-data if this one has
                    // none, so focus never bails to the List toggle. resetFocus
                    // first pulls focus off the minimized mini tile into the guide;
                    // then scroll the channel into view and re-assert focusedProgramID.
                    guard let target = resolveFocusProgramID(preferringChannel: valid) else {
                        resetFocus(in: guideFocusNS); return
                    }
                    // Realize the target row BEFORE resetFocus: reset lands on
                    // the topmost realized cell, so resetting first produced a
                    // visible hop to the top and then a walk back down as the
                    // assert loop corrected it (Logan 2026-08-27, return from
                    // a retention Jump). With the row on screen,
                    // prefersDefaultFocus (guideFocusTargetChannelID) lets the
                    // reset land directly; the loop below is now a backstop.
                    proxy.scrollTo(valid, anchor: .center)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    if Task.isCancelled { return }
                    resetFocus(in: guideFocusNS)
                    for attempt in 0..<8 {
                        if Task.isCancelled { return }
                        proxy.scrollTo(valid, anchor: .center)
                        focusedProgramID = target
                        try? await Task.sleep(nanoseconds: 70_000_000)
                        debugLog("🧭 [GuideFocus] assert(return) attempt=\(attempt) set=\(target) got=\(focusedProgramID ?? "nil")")
                        if focusedProgramID == target { break }
                    }
                }
            }
            // Docked group sidebar closed: re-assert focus onto the guide grid
            // (the cells became focusable again the same render pass) so Right /
            // Back never orphan focus onto the Live TV nav tab. Reuses the same
            // resetFocus + retry-assert loop as forceGuideFocus.
            .onReceive(
                NotificationCenter.default.publisher(for: .guideGroupSidebarDismissed)
            ) { note in
                let rebind = (note.userInfo?["rebind"] as? Bool) ?? false
                let returnID = note.userInfo?["returnID"] as? String
                Task { @MainActor in
                    // Let the pane tear down + the grid cells become focusable.
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    // Unchanged group → restore the exact origin cell. Group
                    // changed → the origin cell is likely gone, so land on a
                    // fresh now-cell of the newly-filtered list (never the List
                    // toggle).
                    let target: String? = (!rebind ? returnID : nil)
                        ?? resolveFocusProgramID(preferringChannel: channels.first?.id)
                    guard let target else { resetFocus(in: guideFocusNS); return }
                    resetFocus(in: guideFocusNS)
                    for _ in 0..<8 {
                        focusedProgramID = target
                        try? await Task.sleep(nanoseconds: 70_000_000)
                        if focusedProgramID == target { break }
                    }
                }
            }
            #endif
            } // VStack (fixed time header + scrolling body)
            } // ScrollViewReader
        }
    }

    // MARK: - Guide Row (single channel)
    //
    // HStack layout on both tvOS and iPadOS/macOS. Before this change
    // the row was a `ZStack` with `programRow` extended to
    // `totalGridWidth` (~22,200 pt on tvOS, ~13,320 pt on iPad) and
    // offset via `.offset(x:)`, with `channelCell` drawn on top at
    // `zIndex(0.5)` with an opaque `Color.cardBackground`. Program
    // cells whose clamped start landed at `windowStart` (the common
    // case for currently-airing programs that began before the visible
    // scroll window) had their UIView frames extending *behind* the
    // opaque channel column. The tvOS focus engine and iPadOS click
    // routing both treated the occluded regions inconsistently: some
    // cells remained reachable (focus center happened to land clear of
    // the channel column), others disappeared from the focus graph
    // entirely. Specifically reported: a long-duration program
    // (3:00–5:30, overlapping the channel column) was unfocusable on
    // tvOS while a similar program on a different channel (3:00–5:00,
    // same clamped start and offset) worked — likely due to subtle
    // differences in how tvOS samples focus regions across rows in
    // the section.
    //
    // The HStack below mirrors the pinned `timeHeaderRow` structure at
    // line ~807: channel column and program area are siblings, never
    // overlapping. `programRow` still renders at `totalGridWidth` and
    // gets `.offset(x: horizontalOffset)` for the scroll effect, but
    // the enclosing `.frame(width: screenWidth - channelColumnWidth)
    // .clipped()` bounds its visible region so program cell UIViews
    // are always fully inside the program area and never collide with
    // the channel column's bounds. Focus / hit testing becomes
    // unambiguous.
    //
    // Note on the removed "overflow left over the channel column"
    // comment: the previous layout claimed focused cells could
    // overflow left, but no `zIndex(1)` was ever applied to focused
    // cells — they remained at the default `zIndex(0)`, under the
    // channel column's `zIndex(0.5)`. Any leftward overflow was
    // therefore invisible (covered by the opaque channel column),
    // which means this simplification loses no visible behaviour.
    private func guideRow(for channel: ChannelDisplayItem, screenWidth: CGFloat, focusTargetID: String? = nil) -> some View {
        HStack(spacing: 0) {
            // Left: fixed-width channel column. Standalone UIView;
            // no overlap with program cells.
            channelCell(for: channel)
                .frame(width: channelColumnWidth, height: rowHeight)
                .background(Color.cardBackground)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.accentPrimary.opacity(0.2)).frame(width: 1)
                }
                #if os(tvOS)
                // Bind the channel cell (which contains a focusable
                // `GuideChannelButton` on tvOS) to the row-level
                // focus state. Normally left nil — used by the
                // `.forceGuideFocus` notification handler on the
                // outer ScrollView to claim focus from a minimized
                // mini player.
                .focused($focusedChannelID, equals: channel.id)
                // Mark the playing channel as the default-focus
                // target so `resetFocus(in: guideFocusNS)` lands
                // there. `focusTargetID` is resolved once before the
                // ForEach (O(n) total), so this comparison is O(1).
                .prefersDefaultFocus(
                    channel.id == focusTargetID,
                    in: guideFocusNS
                )
                #endif

            // Right: program area, clipped to exactly the visible
            // program-area width. `programRow` is still
            // `totalGridWidth` wide internally and `.offset` by
            // the horizontal scroll amount, but the outer `.frame`
            // + `.clipped()` bound its visible region so program
            // cell UIViews can no longer extend behind the
            // channel column sibling above.
            programRow(for: channel)
                .frame(width: totalGridWidth, height: rowHeight)
                .offset(x: horizontalOffset)
                .frame(width: max(0, screenWidth - channelColumnWidth),
                       height: rowHeight,
                       alignment: .leading)
                .clipped()
        }
        .frame(width: screenWidth, height: rowHeight, alignment: .leading)
        #if os(tvOS)
        .focusSection() // each row is a distinct focus region — Down always moves to the next row
        #endif
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentPrimary.opacity(0.08)).frame(height: 1)
        }
        .onAppear {
            guideStore.prefetchIfNeeded(channel: channel, servers: servers)
        }
        .onDisappear {
            // Cancel the debounced (not-yet-fired) prefetch for this
            // row. If it hasn't slept past its 250ms timer yet, no
            // network request goes out — which is the whole point on
            // fast scrolls where rows flicker on and off screen
            // faster than a human could read them.
            guideStore.cancelPrefetch(channelID: channel.id)
        }
    }

    // MARK: - Channel Cell
    private func channelCell(for channel: ChannelDisplayItem) -> some View {
        GuideChannelButton(channel: channel, onSelect: onSelectChannel)
    }

    #if os(tvOS)
    /// The program id to focus for a channel: the now-airing program if
    /// known, else the first available. Program cells are the focusable
    /// elements, so restoring focus to a channel means focusing one of its
    /// program cells.
    private func focusTargetProgramID(forChannel channelID: String) -> String? {
        let progs = guideStore.programs[channelID] ?? []
        let now = Date()
        return (progs.first { $0.start <= now && now < $0.end } ?? progs.first)?.id
    }
    #endif

    // MARK: - Task #185: viewport-anchored focus (the "guide gets away" fix)
    // Field-traced on the Apple TV 2026-07-18 against Emby's guide as the
    // reference: focus must live at a stable on-screen time column. Before
    // this, LEFT/RIGHT panned the timeline while focus stayed glued to the
    // old cell (which could slide clean off-screen yet remain focused, so
    // OK acted on something invisible), and UP/DOWN's default focus search
    // then navigated by that off-screen geometry - landing on programmes
    // that ended hours ago.

    /// Wall-clock time at the programme strip's visible LEFT edge.
    private var timeAtViewportLeft: Date {
        let x = -horizontalOffset
        let elapsed = TimeInterval(x / totalGridWidth) * totalDuration
        return windowStart.addingTimeInterval(elapsed)
    }

    /// The time column focus should occupy: a quarter-hour inside the
    /// visible window, so it always falls within the first visible slot.
    private var viewportAnchorTime: Date {
        timeAtViewportLeft.addingTimeInterval(15 * 60)
    }

    /// The programme cell on `channelID` containing `date`, if composed data
    /// covers it.
    private func programID(forChannel channelID: String, containing date: Date) -> String? {
        (guideStore.programs[channelID] ?? [])
            .first { $0.start <= date && date < $0.end }?.id
    }

    /// The channel that owns programme `pid`. Programme ids are prefixed
    /// with their channel id, but a channel id can be a prefix of another,
    /// so membership in that channel's programme list is the authority.
    /// Task #188: memoized in GuideStore (cleared on EPG writes) -- the
    /// linear scan ran on every focus change and up to ~5x per horizontal
    /// press via the retarget/assert-retry loops.
    #if os(tvOS)
    /// iOS #66: move focus one viewport of channels up or down, driven by the
    /// CEC channel keys (delivered as pageUp/pageDown). Mirrors the Android
    /// CHANNEL_UP/DOWN pager: clamps at the list edges and never escapes the
    /// grid. Uses the same assert-until-accepted focus write the top-channel
    /// and return-from-player paths need (a single write is dropped while the
    /// target row is still laying out).

    /// Body of the guide's onMoveCommand, hoisted to a method: the inline
    /// closure pushed the grid's modifier chain past the RELEASE compiler's
    /// type-check budget once the page-press catcher joined the chain
    /// (archive-only failure; the beta compiler managed the inline form).
    private func handleGuideMoveCommand(_ direction: MoveCommandDirection) {
        // #42 Part 1: only scroll the EPG timeline when a guide program
        // cell is actually focused. A held Left whose focus has jumped to
        // the "All" pill still resolves ONE onMoveCommand(.left) into the
        // guide on release (focusedProgramID == nil); gating on a focused
        // cell drops that stray scroll, while normal scrolling (which
        // always has a focused cell) is untouched.
        guard focusedProgramID != nil else { return }
        switch direction {
        case .left:
            // Sidebar mode used to open the docked group menu on a
            // short-Left at the now column. REVERSED per Logan
            // 2026-08-06 (matching his Android ruling the same day):
            // hold-Left opens the sidebar (window-level detector ->
            // .guideOpenGroupSidebar) and a single Left is ALWAYS
            // plain navigation, because the tap-opens scheme made the
            // EPG history left of "now" unreachable in sidebar mode.
            withAnimation(.easeOut(duration: 0.3)) {
                horizontalOffset = min(0, horizontalOffset + pixelsPerHour * 0.5)
            }
            // Task #185: focus rides the viewport. Without this, the
            // pan left the OLD cell focused - it slid off-screen while
            // still holding focus, so the ring vanished and OK acted
            // on an invisible programme.
            retargetFocusToViewportColumn()
        case .right:
            // #42: a hold-Right (close corner mini) freezes the timeline so
            // the still-held Right does not scroll the EPG forward after the
            // mini closes. Short/normal Right scrolling is unaffected.
            if rightHoldPinningTimeline { break }
            // Capture the pre-gesture offset ONCE per press train. A
            // held Right emits repeats before the hold recognizes;
            // overwriting per step made the hold's restore land one or
            // more steps to the RIGHT of where the user started.
            // 0.35s of quiet = a new gesture; repeats arrive faster.
            let stepNow = Date()
            if preRightStepOffset == nil
                || stepNow.timeIntervalSince(preRightStepAt) > 0.35 {
                preRightStepOffset = horizontalOffset
            }
            preRightStepAt = stepNow
            withAnimation(.easeOut(duration: 0.3)) {
                horizontalOffset = max(maxHorizontalOffset, horizontalOffset - pixelsPerHour * 0.5)
            }
            retargetFocusToViewportColumn()
        default:
            break
        }
    }

    /// Hoisted out of the body's modifier chain: the inline closure pushed the
    /// already-huge expression past the RELEASE Xcode type-checker's time
    /// budget (archive-only failure; the beta compiler managed it).
    private func pagePressCatcher(proxy: ScrollViewProxy) -> some View {
        TVPagePressCatcher { (down: Bool) in
            pageGuideFocus(down: down, proxy: proxy)
        }
    }

    private func pageGuideFocus(down: Bool, proxy: ScrollViewProxy) {
        // Current row: the in-flight page target first (rapid presses land
        // while the previous focus write is still asserting and
        // focusedProgramID reads nil between unfocus and focus), then live
        // focus, then the sticky last-focused channel. Device pass 2026-08-19:
        // the first cut read focusedProgramID only, so every press after the
        // first bailed here.
        let curIdx: Int
        if let pending = pagePendingChannelIndex {
            curIdx = pending
        } else if let pid = focusedProgramID,
                  let ch = channelID(ofProgram: pid),
                  let i = channels.firstIndex(where: { $0.id == ch }) {
            curIdx = i
        } else if let ch = lastFocusedChannelForSnap,
                  let i = channels.firstIndex(where: { $0.id == ch }) {
            curIdx = i
        } else {
            return
        }
        let visibleRows = max(1, Int(UIScreen.main.bounds.height / rowHeight) - 2)
        let target = min(max(down ? curIdx + visibleRows : curIdx - visibleRows, 0),
                         channels.count - 1)
        guard target != curIdx else { return }
        pagePendingChannelIndex = target
        debugLog("🧭 [GuideFocus] page\(down ? "Down" : "Up") ch#\(curIdx) -> ch#\(target) rows=\(visibleRows)")
        Task { @MainActor in
            defer { if pagePendingChannelIndex == target { pagePendingChannelIndex = nil } }
            // Realize the target row FIRST: the rows live in a LazyVStack, so
            // a row a full page away is not composed and a focus write into
            // it is silently dropped (the other half of the one-press bug).
            // ForEach(channels) tags each row with channel.id for scrollTo.
            proxy.scrollTo(channels[target].id, anchor: down ? .bottom : .top)
            try? await Task.sleep(nanoseconds: 50_000_000)
            // The row may compose without guide data; resolveFocusProgramID
            // scans onward for the first cell that exists.
            guard let targetPID = resolveFocusProgramID(preferringChannel: channels[target].id) else { return }
            for attempt in 0..<8 {
                focusedProgramID = targetPID
                try? await Task.sleep(nanoseconds: 70_000_000)
                if focusedProgramID == targetPID { break }
                if attempt == 3 {
                    proxy.scrollTo(channels[target].id, anchor: down ? .bottom : .top)
                }
            }
        }
    }
    #endif

    private func channelID(ofProgram pid: String) -> String? {
        if let hit = guideStore.programChannelMemo[pid] { return hit }
        let resolved = channels.first { ch in
            pid.hasPrefix("\(ch.id)-") &&
                (guideStore.programs[ch.id]?.contains { $0.id == pid } ?? false)
        }?.id
        if let resolved { guideStore.programChannelMemo[pid] = resolved }
        return resolved
    }

    /// True when the timeline sits more than half an hour away from the
    /// "now left-aligned" anchor position (the same slop the Android guide
    /// uses, so a Menu press near now doesn't burn on a micro-correction).
    private func timelineIsAwayFromNow() -> Bool {
        let lead = pixelsPerHour * 0.25
        let target = min(0, max(maxHorizontalOffset, -xOffset(for: Date()) + lead))
        return abs(horizontalOffset - target) > pixelsPerHour * 0.5
    }

    /// Snap the timeline so "now" sits just right of the channel column
    /// (a 15-minute lead of past visible - the Emby/Android-fix anchor).
    /// Recomputed fresh from the wall clock every call: the old one-shot
    /// initial offset went stale as the guide view outlived its build time
    /// (the "opens two hours in the past" launches).
    private func reAnchorTimelineToNow(animated: Bool = true) {
        let lead = pixelsPerHour * 0.25
        let target = min(0, max(maxHorizontalOffset, -xOffset(for: Date()) + lead))
        if animated {
            withAnimation(.easeOut(duration: 0.3)) { horizontalOffset = target }
        } else {
            horizontalOffset = target
        }
    }

    #if os(tvOS)
    /// After a LEFT/RIGHT timeline pan, walk focus to the cell at the NEW
    /// viewport anchor column on the same channel row, so the ring rides
    /// the visible window instead of sliding off-screen with the old cell.
    private func retargetFocusToViewportColumn() {
        guard let pid = focusedProgramID, let chID = channelID(ofProgram: pid) else { return }
        let anchor = viewportAnchorTime
        guard let target = programID(forChannel: chID, containing: anchor),
              target != pid else { return }
        Task { @MainActor in
            for _ in 0..<4 {
                focusedProgramID = target
                try? await Task.sleep(nanoseconds: 60_000_000)
                if focusedProgramID == target { break }
            }
        }
    }
    #endif

    #if os(tvOS)
    /// Resolve a REAL focusable program id for programmatic focus. Channel-
    /// column cells are intentionally non-focusable on tvOS (only program
    /// cells accept focus), so focus restore must land on a program cell. If
    /// the preferred channel has no guide data (focusTargetProgramID nil; the
    /// very top channel frequently has none), scan forward from it, then
    /// anywhere, for the first channel that DOES. This stops focus from bailing
    /// to the List toggle (the "scroll to top focused the List button" bug).
    // Remote Control #196: mapped guide-action handlers (posted by
    // GuideRemoteDispatch from the hold-press sites).

    /// The notification receivers as an invisible background child, so the
    /// main body chain gains exactly one modifier.
    private func guideRemoteReceivers(proxy: ScrollViewProxy) -> some View {
        Color.clear
            .onReceive(
                NotificationCenter.default.publisher(for: .guideTimelineJump),
                perform: handleTimelineJump
            )
            .onReceive(
                NotificationCenter.default.publisher(for: .guideJumpToNow)
            ) { _ in handleJumpToNow() }
            .onReceive(
                NotificationCenter.default.publisher(for: .guidePageStep)
            ) { note in handlePageStep(note, proxy: proxy) }
            .onReceive(
                NotificationCenter.default.publisher(for: .guideOpenGroupSidebar)
            ) { _ in
                // Sidebar mode's hold-Left (Logan 2026-08-06 ruling): the
                // host posts, we answer with the focused programme so the
                // sidebar knows where to restore focus on dismiss.
                //
                // GH #72: a focused programme must NOT be a precondition.
                // An empty group has no cells, so focusedProgramID is nil and
                // the old `let fpid =` binding failed the guard - hold-Left
                // went dead exactly when the sidebar was the only way out.
                // The return id is optional all the way down (the dismiss
                // handler already falls back to resolveFocusProgramID and
                // then to resetFocus), so nil just means "no cell to
                // restore".
                guard RemoteControlStore.shared.useGroupSidebar, !sidebarOpen,
                      let request = onRequestGroupSidebar else { return }
                request(focusedProgramID)
            }
    }

    /// Timeline jump by userInfo["hours"] (signed; negative = earlier).
    /// Same pan + clamp + focus-retarget as the short-press arrows.
    private func handleTimelineJump(_ note: Notification) {
        guard let hours = note.userInfo?["hours"] as? Double else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            if hours < 0 {
                horizontalOffset = min(0, horizontalOffset + pixelsPerHour * -hours)
            } else {
                horizontalOffset = max(maxHorizontalOffset, horizontalOffset - pixelsPerHour * hours)
            }
        }
        retargetFocusToViewportColumn()
    }

    private func handleJumpToNow() {
        reAnchorTimelineToNow()
        retargetFocusToViewportColumn()
    }

    /// Page the focused row by userInfo["step"] channels (signed, clamped).
    /// Same resolve/scroll pattern as the EPG-search jump.
    private func handlePageStep(_ note: Notification, proxy: ScrollViewProxy) {
        guard let step = note.userInfo?["step"] as? Int, step != 0 else { return }
        let currentIdx = focusedProgramID
            .flatMap { channelID(ofProgram: $0) }
            .flatMap { id in channels.firstIndex(where: { $0.id == id }) } ?? 0
        let targetIdx = max(0, min(channels.count - 1, currentIdx + step))
        guard targetIdx != currentIdx, targetIdx < channels.count else { return }
        let targetChannel = channels[targetIdx]
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(targetChannel.id, anchor: .center)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if let target = resolveFocusProgramID(preferringChannel: targetChannel.id) {
                focusedProgramID = target
            }
        }
    }

    private func resolveFocusProgramID(preferringChannel channelID: String?) -> String? {
        if let channelID, let pid = focusTargetProgramID(forChannel: channelID) {
            return pid
        }
        let startIdx = channelID
            .flatMap { id in channels.firstIndex(where: { $0.id == id }) } ?? 0
        if startIdx < channels.count {
            for ch in channels[startIdx...] {
                if let pid = focusTargetProgramID(forChannel: ch.id) { return pid }
            }
        }
        for ch in channels {
            if let pid = focusTargetProgramID(forChannel: ch.id) { return pid }
        }
        return nil
    }
    #endif

    // MARK: - Fixed Time Header (above the scroll body)
    /// The guide's time strip, rendered as a fixed bar ABOVE the
    /// ScrollView. It used to be the `header:` of a pinned `Section`
    /// inside `LazyVStack(pinnedViews: [.sectionHeaders])`, but that
    /// pinned-section-header path drove the DisplayList.Key /
    /// LazyPreference reduce that aborts tvOS 27's AttributeGraph during
    /// scroll-recycle layout. As a plain sibling above the scroll it is
    /// visually identical: it reads `horizontalOffset` directly so the
    /// time labels stay horizontally synced with the program cells.
    @ViewBuilder
    private func guideTimeHeader(geoWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.cardBackground
                .frame(width: channelColumnWidth, height: timeHeaderHeight)
                // Coolwolf (Discord): show the current time in the
                // guide. Top-left corner cell (the mini-player sits
                // top-right), refreshes each minute, and uses the
                // locale-aware format so it honors the device's
                // 12 or 24-hour setting.
                .overlay {
                    GuideCornerClock(fontSize: timeHeaderHeight * 0.4)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.accentPrimary.opacity(0.2)).frame(width: 1)
                }
                .zIndex(1)

            timeHeaderRow
                .frame(width: totalGridWidth, height: timeHeaderHeight)
                .offset(x: horizontalOffset)
                .frame(width: geoWidth - channelColumnWidth, height: timeHeaderHeight, alignment: .leading)
                .clipped()
        }
        .frame(width: geoWidth, height: timeHeaderHeight, alignment: .leading)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentPrimary.opacity(0.15)).frame(height: 1)
        }
    }

    // MARK: - Time Header
    private var timeHeaderRow: some View {
        ZStack(alignment: .leading) {
            Color.appBackground

            ForEach(hourMarkers(), id: \.self) { date in
                let offset = xOffset(for: date)
                VStack(spacing: 0) {
                    #if os(tvOS)
                    Text(timeFormatter.string(from: date).lowercased())
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.textSecondary)
                    #else
                    // Scale with `guideScale` so shrinking / enlarging
                    // the grid also resizes the time-column labels.
                    // Without this the time strip keeps a fixed 10pt
                    // font while the row / column dimensions stretch,
                    // producing oversized headers at 0.75x and
                    // undersized ones at 1.5x (R3 review finding).
                    Text(timeFormatter.string(from: date).lowercased())
                        .font(.system(size: 10 * guideScale, weight: .medium))
                        .foregroundColor(.textSecondary)
                    #endif
                }
                .offset(x: offset + 8)
            }

            Rectangle().fill(Color.accentPrimary.opacity(0.15))
                .frame(height: 1)
                .offset(y: timeHeaderHeight / 2 - 0.5)
        }
    }

    // MARK: - Program Row
    private func programRow(for channel: ChannelDisplayItem) -> some View {
        ZStack(alignment: .leading) {
            Color.appBackground.opacity(0.5)

            let progs = guideStore.programs[channel.id] ?? []

            // Viewport clipping: only render programs overlapping the visible time window
            // plus 30-min padding on each side for smooth scrolling.
            let visibleFraction = -horizontalOffset / totalGridWidth
            let visibleWidthFraction = visibleProgramWidth / totalGridWidth
            let visibleTimeStart = windowStart.addingTimeInterval(Double(visibleFraction) * totalDuration)
            let visibleTimeEnd = visibleTimeStart.addingTimeInterval(Double(visibleWidthFraction) * totalDuration)
            let pad: TimeInterval = 1800 // 30 minutes
            let filterStart = visibleTimeStart.addingTimeInterval(-pad)
            let filterEnd = visibleTimeEnd.addingTimeInterval(pad)

            // Task #188: no re-sort. Every GuideStore write path stores each
            // channel's programmes start-sorted (loadFromCache uses a
            // SortDescriptor, mergeProgramInto re-sorts touched lists), and
            // .filter preserves order -- the old per-row per-pass .sorted was
            // a pure allocation + O(n log n) tax on the render path.
            let sortedProgs = progs
                .filter { $0.end > filterStart && $0.start < filterEnd }

            if sortedProgs.isEmpty {
                // No VISIBLE guide cells - truly EPG-less channels AND channels
                // whose data all falls outside the current window (task #185
                // follow-up: channel 5 had stale out-of-window entries, so the
                // old `progs.isEmpty` gate rendered NOTHING and the row was
                // unreachable by D-pad). Show a tappable/focusable row either
                // way so the channel is always selectable.
                #if os(tvOS)
                // Sized to the visible viewport and pinned there (the row
                // content is offset by horizontalOffset, so -horizontalOffset
                // is the viewport's left edge). The old full-strip width put
                // the button's frame center hours off-screen and the focus
                // engine's candidate scoring always preferred the next row.
                GuideEmptyRowButton(
                    label: channel.currentProgram ?? "No guide data",
                    width: max(1, visibleProgramWidth), rowHeight: rowHeight
                ) { onSelectChannel(channel) }
                .offset(x: -horizontalOffset)
                #else
                Text(channel.currentProgram ?? "No guide data")
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
                    .frame(width: max(1, visibleProgramWidth), height: rowHeight, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectChannel(channel) }
                    .offset(x: -horizontalOffset)
                #endif
            } else {
                ForEach(Array(sortedProgs.enumerated()), id: \.element.id) { index, prog in
                    let nextStart: Date? = index + 1 < sortedProgs.count ? sortedProgs[index + 1].start : nil
                    programCell(prog, channelItem: channel, nextProgramStart: nextStart)
                }
            }

            // Row bottom border
            Rectangle().fill(Color.accentPrimary.opacity(0.08))
                .frame(height: 1)
                .offset(y: rowHeight / 2 - 0.5)
        }
    }

    // MARK: - Program Cell
    private func programCell(_ prog: GuideProgram, channelItem: ChannelDisplayItem, nextProgramStart: Date? = nil) -> some View {
        let clampedStart = max(prog.start, windowStart)
        let clampedEnd   = min(prog.end, windowEnd)
        // Clamp end to the next program's start to prevent overlap
        let maxEnd: Date = {
            if let next = nextProgramStart {
                let clampedNext = max(next, windowStart)
                return min(clampedEnd, clampedNext)
            }
            return clampedEnd
        }()
        let x = xOffset(for: clampedStart)
        let rawWidth = CGFloat(maxEnd.timeIntervalSince(clampedStart) / totalDuration) * totalGridWidth
        let width = max(20, rawWidth - cellGap)

        // How much of the cell is hidden behind the channel column?
        // screenX = channelColumnWidth + horizontalOffset + x
        // If screenX < channelColumnWidth, the difference is the hidden portion.
        let screenX = channelColumnWidth + horizontalOffset + x
        let leadingClip = max(0, channelColumnWidth - screenX)

        // The program cell now owns the `.focused(focusedProgramID, equals:)`
        // binding internally (on its single SwiftUI-native focusable). There
        // is no longer a competing UIKit overlay, so the binding is safe and
        // is what the focus-restore handlers drive. tvOS passes the binding;
        // iOS uses the no-binding init.
        #if os(tvOS)
        return GuideProgramButton(
            prog: prog, channelItem: channelItem, width: width, rowHeight: rowHeight,
            leadingClip: leadingClip,
            shortTimeFormatter: shortTimeFormatter,
            onSelect: onSelectChannel,
            onMultiviewIntent: { handleMultiviewIntent(channel: $0) },
            onWatchCatchup: { ch, gp in handleWatchCatchup(channel: ch, prog: gp) },
            focusedProgramID: $focusedProgramID,
            sidebarOpen: sidebarOpen
        )
        .offset(x: x, y: 0)
        #else
        return GuideProgramButton(
            prog: prog, channelItem: channelItem, width: width, rowHeight: rowHeight,
            leadingClip: leadingClip,
            shortTimeFormatter: shortTimeFormatter,
            onSelect: onSelectChannel,
            onMultiviewIntent: { handleMultiviewIntent(channel: $0) },
            onWatchCatchup: { ch, gp in handleWatchCatchup(channel: ch, prog: gp) }
        )
        .offset(x: x, y: 0)
        #endif
    }

    // MARK: - Time Indicator Line
    private func timeIndicatorLine(screenWidth: CGFloat, now: Date = Date()) -> some View {
        let x = xOffset(for: now)
        let screenX = channelColumnWidth + horizontalOffset + x
        // Only show if it's within the visible program area
        let visible = screenX >= channelColumnWidth && screenX <= screenWidth
        return Rectangle()
            .fill(Color.statusLive)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .offset(x: screenX)
            .opacity(visible ? 1 : 0)
    }

    // MARK: - Multiview Staging (v1.7.x)

    /// Top-edge banner shown while `MultiviewStore.shared.isStagingFromGuide`
    /// is true. Surfaces the current tile count plus Play and Done
    /// actions. Tapping a channel in the Guide while this banner is
    /// showing toggles that channel in/out of the multiview pile
    /// instead of starting playback. See `handleMultiviewIntent(channel:)`
    /// for the toggle logic.
    ///
    /// v1.7.3 (Freyguy1975 Discord 2026-05-11): added the Play button.
    /// Tapping Done only exits staging mode; users on Apple TV had no
    /// obvious path from "I've staged 3 channels" to "start watching
    /// them." Play flips `PlayerSession.mode` to `.multiview` without
    /// re-seeding (the staged tiles are already in
    /// `MultiviewStore.tiles`), which mounts `MultiviewContainerView`
    /// against them via the existing observer at `HomeView.swift:3583`.
    ///
    /// The banner is wrapped in `.focusSection()` on tvOS so the focus
    /// engine treats the button row as one reachable region. The host
    /// view places the banner inside a `VStack` on tvOS (so spatial
    /// focus routes from the topmost guide row up into the banner) and
    /// inside `safeAreaInset(edge: .top)` on iOS (so the banner stays
    /// pinned during scroll).
    private var stagingBanner: some View {
        let count = multiviewStore.tiles.count
        let label = count == 1
            ? "1 tile staged for Multiview"
            : "\(count) tiles staged for Multiview"
        let banner = HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentPrimary)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.textPrimary)
            Spacer()
            // Clear (Android parity P2): one-press way to abandon a
            // staged set without launching it. The banner persists
            // across tabs, so without this the only outs were Play or
            // unstaging channels one by one.
            Button {
                let staged = multiviewStore.tiles.count
                multiviewStore.reset()
                multiviewStore.isStagingFromGuide = false
                DebugLogger.shared.log(
                    "[MV-Tile] staging mode: user tapped Clear (count=\(staged))",
                    category: "Playback", level: .info
                )
            } label: {
                Text("Clear")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            #if os(tvOS)
            .buttonStyle(TVNoHighlightButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1.0)
            // Play (primary action). Disabled when no tiles are
            // staged so the user doesn't fire `enterMultiview` with
            // an empty store.
            Button {
                let staged = multiviewStore.tiles.count
                multiviewStore.isStagingFromGuide = false
                let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                PlayerSession.shared.enterMultiview(seeding: nil, server: activeServer)
                DebugLogger.shared.log(
                    "[MV-Tile] staging mode: user tapped Play (count=\(staged))",
                    category: "Playback", level: .info
                )
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Play")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentPrimary))
            }
            // tvOS: use the app's themed focus style (accent stroke ring)
            // instead of leaving .plain, which lets the default white system
            // focus glow blob through and clashes with the capsule pill.
            #if os(tvOS)
            .buttonStyle(TVNoHighlightButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1.0)
            // Done (secondary action). Outlined rather than filled so
            // the visual hierarchy reads Play-then-Done.
            Button {
                multiviewStore.isStagingFromGuide = false
                DebugLogger.shared.log(
                    "[MV-Tile] staging mode: user tapped Done (count=\(multiviewStore.tiles.count))",
                    category: "Playback", level: .info
                )
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().stroke(Color.accentPrimary, lineWidth: 1)
                    )
            }
            #if os(tvOS)
            .buttonStyle(TVNoHighlightButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentPrimary.opacity(0.4))
                .frame(height: 1)
        }
        #if os(tvOS)
        return banner.focusSection()
        #else
        return banner
        #endif
    }

    /// Toast bubble for staging-mode add / remove confirmations.
    /// Auto-dismisses after ~2.5s via `showStagingToast(_:)`.
    private func stagingToastView(_ text: String) -> some View {
        Text(text)
            #if os(tvOS)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            #else
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #endif
            .foregroundColor(.white)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.85))
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }

    /// Sets `stagingToast` and schedules an auto-clear ~2.5s later.
    /// Idempotent against rapid successive calls: the second toast
    /// replaces the first, and only the latest message's auto-clear
    /// will null out the state.
    private func showStagingToast(_ message: String) {
        stagingToast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                if stagingToast == message { stagingToast = nil }
            }
        }
    }

    /// Routes a channel selection through the staging-mode toggle:
    /// the first invocation (when staging isn't yet active) wipes
    /// the existing pile and switches the flag on so subsequent
    /// single-taps in the Guide flow back through this same method.
    /// Already-staged channels get removed; not-yet-staged channels
    /// get added. Hitting the hard cap auto-exits staging.
    private func handleMultiviewIntent(channel: ChannelDisplayItem) {
        // First entry: wipe and flip the flag. Subsequent calls just
        // toggle (the flag is already true and the pile is whatever
        // the user has built so far).
        if !multiviewStore.isStagingFromGuide {
            multiviewStore.clearAll()
            multiviewStore.isStagingFromGuide = true
            DebugLogger.shared.log(
                "[MV-Tile] staging mode: entered from Guide (channel=\(channel.name))",
                category: "Playback", level: .info
            )
        }
        // Toggle: already-staged → remove, else → add.
        if let tile = multiviewStore.tile(forChannelID: channel.id) {
            multiviewStore.remove(id: tile.id)
            showStagingToast("Removed \(channel.name)")
            return
        }
        let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
        let result = multiviewStore.add(channel, server: activeServer)
        switch result {
        case .added:
            showStagingToast("Added \(channel.name)")
        case .needsWarning:
            // Staging mode is an explicit "I want a lot of tiles"
            // intent. Bypassing the warning here avoids interrupting
            // the build flow with a confirmation dialog on every
            // tile past the soft limit. The user can still observe
            // the count climbing in the banner.
            _ = multiviewStore.add(channel, server: activeServer, bypassWarning: true)
            showStagingToast("Added \(channel.name)")
        case .rejectedMax:
            showStagingToast("Maximum \(multiviewStore.maxTiles) streams reached")
            // Hit the hard cap. Exit staging so the user gets the
            // banner out of their way and can move on to the
            // Multiview tab.
            multiviewStore.isStagingFromGuide = false
        case .alreadyPresent:
            // Defensive: the tile(forChannelID:) check above should
            // have caught this. If we somehow reach here, surface
            // the toast and move on.
            showStagingToast("Already added")
        case .unresolvable:
            showStagingToast("\(channel.name) has no playable stream")
        }
    }

    // MARK: - Helpers

    /// Catch-up: resolve the aired programme into a playable timeshift URL
    /// and present the player. Silences any live/multiview session FIRST
    /// (the recordings-pattern teardown) so live audio can't keep playing
    /// under the catch-up programme. Resolve failures (missing XC password,
    /// unsupported server type) surface as an alert.
    private func handleWatchCatchup(channel: ChannelDisplayItem, prog: GuideProgram) {
        guard let server = ChannelStore.shared.activeServer else { return }
        Task { @MainActor in
            do {
                let pb = try await CatchupSupport.resolve(
                    server: server,
                    channel: channel,
                    programTitle: prog.title,
                    programStart: prog.start,
                    programEnd: prog.end
                )
                #if os(tvOS)
                // Unified pipeline (task #147): catch-up plays in the
                // SAME container/chrome as live via a session mode
                // switch - no separate cover, no second player UI.
                PlayerSession.shared.beginCatchup(pb)
                #else
                PlayerSession.shared.exit()
                playingCatchup = pb
                #endif
            } catch {
                catchupErrorMessage = error.localizedDescription
            }
        }
    }

    private func xOffset(for date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(windowStart)
        return CGFloat(elapsed / totalDuration) * totalGridWidth
    }

    /// Consume a pending EPG-search "jump to program" target (stashed
    /// in UserDefaults by SearchView) and scroll the guide to that
    /// channel + start time. Idempotent and guarded: it clears the
    /// keys only once a matching, loaded channel exists, so an early
    /// call (channels not yet present) leaves the target for a later
    /// retry via `.task(id: channels.count)`. The horizontal position
    /// uses the same `xOffset(for:)` date→pixel map the now-line uses,
    /// biased a little right of the channel column.
    @MainActor
    private func consumePendingGuideJump(proxy: ScrollViewProxy) {
        let defaults = UserDefaults.standard
        guard let channelID = defaults.string(forKey: "guideJumpChannelID"),
              let startTS = defaults.object(forKey: "guideJumpStart") as? Double,
              channels.contains(where: { $0.id == channelID })
        else { return }
        defaults.removeObject(forKey: "guideJumpChannelID")
        defaults.removeObject(forKey: "guideJumpStart")
        let start = Date(timeIntervalSince1970: startTS)
        Task { @MainActor in
            // Let the guide's own initial scroll-to-now settle first.
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(channelID, anchor: .center)
                let lead = pixelsPerHour * 0.25
                horizontalOffset = min(0, max(maxHorizontalOffset, -xOffset(for: start) + lead))
            }
            #if os(tvOS)
            guideFocusTargetChannelID = channelID
            try? await Task.sleep(nanoseconds: 120_000_000)
            if let target = focusTargetProgramID(forChannel: channelID) {
                focusedProgramID = target
            }
            #endif
        }
    }

    private func hourMarkers() -> [Date] {
        var markers: [Date] = []
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: windowStart)
        let m = comps.minute ?? 0
        if m < 30 {
            comps.minute = 30
        } else {
            comps.minute = 0
            comps.hour = (comps.hour ?? 0) + 1
        }
        comps.second = 0
        guard var cursor = cal.date(from: comps) else { return markers }

        while cursor < windowEnd {
            markers.append(cursor)
            cursor = cursor.addingTimeInterval(1800)
        }
        return markers
    }
}

// MARK: - Guide Channel Button (own @FocusState for tvOS highlight)
/// Literal wall-clock time of day shown in the Guide's top-left corner
/// cell (Coolwolf, Discord request) - the time of day, not anything to do
/// with the program schedule. Self-contained and Timer-driven: it paints
/// the current time immediately on appear, then re-paints every 30s. A
/// schedule-driven view did not reliably paint this in the pinned guide
/// header on tvOS (the corner read blank), so this uses a plain Timer and
/// @State instead. The locale-aware hour/minute format honors the
/// device's 12 or 24-hour setting.
private struct GuideCornerClock: View {
    let fontSize: CGFloat
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(now, format: .dateTime.hour().minute())
            .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
            .foregroundColor(.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 4)
            .onReceive(tick) { now = $0 }
    }
}

private struct GuideChannelButton: View {
    let channel: ChannelDisplayItem
    let onSelect: (ChannelDisplayItem) -> Void
    @EnvironmentObject private var favoritesStore: FavoritesStore
    /// GH #19 (Android parity): hide the channel number in the guide rail.
    /// Same key as the List view's toggle; the guide's logo is gated by
    /// logoURL presence only, so this is the guide's first appearance flag.
    @AppStorage("ui.showChannelNumbers") private var showChannelNumbers = true
    /// GH #73 (ant462, filed on Android; applied here for parity): hide the
    /// channel NAME text in the guide rail, leaving logo and number.
    @AppStorage("ui.showChannelNames") private var showChannelNames = true

    var body: some View {
        #if os(tvOS)
        // Non-focusable label on tvOS — users select program cells to play.
        // This prevents focus from jumping to the channel column when scrolling down.
        // tvOS long-press overlay lets users still manage favorites from here
        // without having to switch to List view.
        channelLabel
            .overlay(alignment: .topTrailing) {
                if favoritesStore.isFavorite(channel.id) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.statusWarning)
                        .padding(6)
                }
            }
        #else
        channelLabel
            .contentShape(Rectangle())
            .onTapGesture { onSelect(channel) }
            .overlay(alignment: .topTrailing) {
                // Tappable favorite star (issue #35). This used to be a
                // display-only star (drawn only when already favorited)
                // plus a hidden long-press contextMenu, so iPad users had
                // no visible way to ADD a favorite from the guide, which is
                // where iPad lands by default. The recurring "can't add
                // favorites for Xtream" reports (#18, #35) were really this
                // discoverability gap, not an XC bug. The star is now always
                // visible and toggles on tap: a subtle outline when not
                // favorited, filled gold when favorited. The contextMenu is
                // dropped on purpose: a parent .contextMenu steals a child
                // Button's tap (see feedback_context_menu_limitation).
                Button {
                    favoritesStore.toggle(channel)
                } label: {
                    Image(systemName: favoritesStore.isFavorite(channel.id) ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(favoritesStore.isFavorite(channel.id) ? .statusWarning : .textTertiary.opacity(0.55))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favoritesStore.isFavorite(channel.id) ? "Remove \(channel.name) from Favorites" : "Add \(channel.name) to Favorites")
            }
        #endif
    }

    private var channelLabel: some View {
        #if os(tvOS)
        // Emby-style: channel number on left, logo + name on right
        HStack(spacing: 8) {
            // GH #19: number column collapses when numbers are off.
            if showChannelNumbers {
                Text(channel.number)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 38, alignment: .trailing)
            }

            VStack(spacing: 4) {
                // v1.6.23: route through CachedLogoImage so the
                // active server's auth headers (X-API-Key, etc) are
                // applied. Bare AsyncImage hits 401 on Dispatcharr-API
                // mode and falls back to the placeholder.
                if channel.logoURL != nil {
                    CachedLogoImage(url: channel.logoURL, width: 72, height: 48)
                } else {
                    guidePlaceholder
                }
                if showChannelNames {
                    Text(channel.name)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // Catch-up badge (2026-07-20, all-platform parity): a small history
        // clock in the rail's top-right whenever the channel has a
        // replayable archive, so users needn't scroll into the past to check.
        .overlay(alignment: .topTrailing) {
            if channel.hasCatchup {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textTertiary)
                    .padding(.top, 6)
                    .padding(.trailing, 8)
            }
        }
        #else
        VStack(spacing: 4) {
            // v1.6.23: same auth-aware fix as the tvOS branch above.
            if channel.logoURL != nil {
                CachedLogoImage(url: channel.logoURL, width: 40, height: 28)
            } else {
                guidePlaceholder
            }
            VStack(spacing: 1) {
                if showChannelNames {
                    Text(channel.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                }
                // GH #19: hide the number line when numbers are off.
                if showChannelNumbers {
                    Text(channel.number)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.textTertiary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // Catch-up badge, phone-scaled (see tvOS branch above).
        .overlay(alignment: .topTrailing) {
            if channel.hasCatchup {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.textTertiary)
                    .padding(.top, 3)
                    .padding(.trailing, 3)
            }
        }
        #endif
    }

    private var guidePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentPrimary.opacity(0.12))
            NoPosterPlaceholder(compact: true)
        }
        #if os(tvOS)
        .frame(width: 72, height: 48)
        #else
        .frame(width: 36, height: 24)
        #endif
    }
}

// MARK: - Guide Program Button (own @FocusState for tvOS highlight)
private struct GuideProgramButton: View {
    let prog: GuideProgram
    let channelItem: ChannelDisplayItem
    let width: CGFloat
    let rowHeight: CGFloat
    /// Pixels of the cell hidden behind the channel column (text pins to visible edge).
    let leadingClip: CGFloat
    let shortTimeFormatter: DateFormatter
    let onSelect: (ChannelDisplayItem) -> Void
    /// v1.7.x: routes "Add to Multiview" context-menu taps AND
    /// single-taps-while-staging back to `EPGGuideView`'s
    /// `handleMultiviewIntent(channel:)`. The cell itself doesn't
    /// know whether staging mode is active; it just calls this
    /// closure whenever the user expresses multiview-pile intent.
    /// The parent does the wipe-on-first-entry, the add / remove
    /// toggle, and the toast.
    let onMultiviewIntent: (ChannelDisplayItem) -> Void
    /// Catch-up: routes a "Watch" tap on an aired, replayable programme
    /// back to `EPGGuideView`, which resolves the timeshift URL and
    /// presents the player. The same `canReplayNow` gate drives the
    /// cell badge and this action so the two can never disagree.
    let onWatchCatchup: (ChannelDisplayItem, GuideProgram) -> Void
    #if os(tvOS)
    /// Parent's program-focus binding. The cell binds
    /// `.focused(focusedProgramID, equals: prog.id)` so the guide can
    /// programmatically focus this cell for focus restore.
    var focusedProgramID: FocusState<String?>.Binding
    /// True while the docked group sidebar is open: makes this cell
    /// non-focusable so the sidebar owns focus and a Right press can't 2D-move
    /// back into the guide (the tvOS analog of Android consuming Right).
    var sidebarOpen: Bool = false
    #endif
    // Access ReminderManager directly — @ObservedObject on a singleton
    // would invalidate every program cell whenever any reminder changes.
    private var reminderManager: ReminderManager { .shared }
    /// Observed (unlike reminderManager above) so a cancelled/deleted
    /// recording drops its red dot without waiting for the guide's next
    /// onAppear (field report 2026-08-27: dot survived a DVR-tab delete
    /// because a tab switch never re-fires onAppear). Cheap in practice:
    /// the marker snapshot is equatable-gated to publish only on REAL
    /// changes, and the coordinator's other @Published fields
    /// (activeSessions/isRecording) mutate only on local-session events.
    @ObservedObject private var recordingCoordinator = RecordingCoordinator.shared
    /// v1.7.x: observed so the cell-level tap behavior swaps between
    /// "play this channel" and "toggle in multiview pile" when the
    /// `isStagingFromGuide` flag flips, and so the long-press menu
    /// label reads "Remove from Multiview" instead of "Add to
    /// Multiview" for an already-staged channel.
    @ObservedObject private var multiviewStore = MultiviewStore.shared
    /// FavoritesStore lets us offer "Add/Remove from Favorites" from a
    /// program cell's long-press menu — users expect that action to
    /// work from anywhere they long-press in the guide, not just the
    /// channel column cell on the left.
    @EnvironmentObject private var favoritesStore: FavoritesStore
    /// Observe the category-colour setting so flipping it in
    /// Settings → Guide Display refreshes every visible cell live
    /// (without this, `cellBackground` would keep reading the old
    /// value through `CategoryColor.isEnabled` until SwiftUI
    /// re-rendered the cell for another reason, e.g. scroll or
    /// focus change). The property is unused inside the body —
    /// its purpose is to tie the cell's render cycle to the
    /// `AppStorage` value so SwiftUI invalidates the view on
    /// toggle. Zero-cost: reading `AppStorage` is the same lookup
    /// as `UserDefaults.standard.bool(forKey:)`.
    @AppStorage(CategoryColor.enabledKey) private var categoryColorsEnabled: Bool = true
    #if !os(tvOS)
    /// User-controllable guide scale (see `EPGGuideView.guideScale`). Multiplies
    /// the iOS/iPadOS/Mac per-cell font sizes so text scales with the grid.
    /// tvOS sizes stay fixed.
    @AppStorage("guideScale") private var guideScale: Double = 1.0
    #endif
    #if os(tvOS)
    // The cell is now a SwiftUI-native focusable, so its focus drives this
    // @FocusState directly (the old UIKit TVPressOverlay is gone). Used for
    // the cell highlight.
    @FocusState private var isFocused: Bool
    #endif

    @AppStorage(epgBadgesVisibleKey) private var showEpgBadges = true

    private var hasReminder: Bool {
        isFutureProgram && reminderManager.hasReminder(forKey: reminderKey)
    }

    /// Audit #50: this cell's programme has a Scheduled or in-progress
    /// recording. Read directly off RecordingCoordinator's marker snapshot,
    /// same non-observing pattern as `reminderManager` above.
    private var hasScheduledRecording: Bool {
        recordingCoordinator.hasGuideRecordingMarker(
            channelID: channelItem.id, channelName: channelItem.name,
            dispatcharrChannelID: channelItem.dispatcharrChannelID,
            title: prog.title, start: prog.start, end: prog.end)
    }

    /// iPhone/compact guide cell: season/episode pill + feed badges on
    /// their own row below the title and description. Renders nothing when
    /// the program carries neither. (tvOS keeps them on the time-range
    /// line, which reads fine at 10-foot distance.)
    /// Whether compactBadgeRow will render anything (mirrors its own guard).
    private var compactBadgeRowVisible: Bool {
        guard showEpgBadges else { return false }
        return seasonEpisodeLabel(season: prog.season, episode: prog.episode) != nil
            || !epgFlagBadges(isLiveBroadcast: prog.isLiveBroadcast, isNew: prog.isNew,
                              isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                              isRepeat: prog.isRepeat).isEmpty
    }

    @ViewBuilder
    private var compactBadgeRow: some View {
        let seLabel = seasonEpisodeLabel(season: prog.season, episode: prog.episode)
        let flags = epgFlagBadges(isLiveBroadcast: prog.isLiveBroadcast, isNew: prog.isNew,
                                  isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                                  isRepeat: prog.isRepeat)
        if showEpgBadges, seLabel != nil || !flags.isEmpty {
            HStack(spacing: 4) {
                SeasonEpisodePill(label: seLabel, compact: true)
                EPGFlagsRow(flags: flags, compact: true)
            }
        }
    }

    /// Below this cell width, text is omitted entirely.
    ///
    /// `programCell` clamps every cell to `max(20, …)` so a very short
    /// programme still has a hit target. Real feeds contain plenty of them:
    /// the Tuliprox XMLTV measured 2026-08-11 carries 1,685 one-minute
    /// programmes out of 147,463 (and only 18 that are truly degenerate), and
    /// at a 2.5-hour viewport one minute is roughly 12 points wide.
    ///
    /// `cellContent` stacks four rows -- title, subtitle, time, badges -- so at
    /// that width each row rendered a one-or-two character fragment and the
    /// cell became a vertical column of punctuation. `.lineLimit(1)` does not
    /// help: the problem is four STACKED rows, not wrapping within one.
    ///
    /// So this is a rendering rule, not a data rule. An earlier attempt
    /// filtered these out by duration, which was wrong -- a 1-minute programme
    /// is real schedule data the provider published, and dropping it loses
    /// information. Keeping the cell (focusable, selectable, correctly placed
    /// on the timeline) while omitting text that cannot fit is honest about
    /// both.
    ///
    /// 44pt: below roughly two glyphs plus padding there is nothing legible to
    /// show at any of the guide's font sizes.
    private var minWidthForText: CGFloat { 44 }

    @ViewBuilder
    private var cellContent: some View {
        if width < minWidthForText {
            // Deliberately empty: the cell's background still draws, so the
            // programme remains visible as a block on the timeline and stays
            // focusable/selectable. Details are available on selection.
            Color.clear
        } else {
        VStack(alignment: .leading, spacing: 2) {
            #if os(tvOS)
            HStack(spacing: 4) {
                // Catch-up badge: aired + replayable from the archive.
                if canReplayNow {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(isFocused ? .white : .accentPrimary)
                }
                Text(prog.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(isFocused ? .white : .textPrimary)
                    .lineLimit(1)
                if hasReminder {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 14))
                        .foregroundColor(isFocused ? .white : .accentPrimary)
                }
                // Audit #50: red dot on cells with a scheduled or
                // in-progress recording (same DVR red as the Android twin).
                if hasScheduledRecording {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.28, blue: 0.34))
                        .frame(width: 10, height: 10)
                }
            }
            .layoutPriority(1)
            // GH #34: the XMLTV <sub-title> (episode / sports-match name) is what
            // distinguishes same-title back-to-back programmes. Guarded against
            // the Dispatcharr paths that promote subTitle into description when
            // <desc> is empty, so it never double-prints.
            if let sub = prog.subTitle, !sub.isEmpty, sub != prog.title, sub != prog.description {
                Text(sub)
                    .font(.system(size: 18))
                    .italic()
                    .foregroundColor(isFocused ? .white.opacity(0.85) : .textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if !prog.description.isEmpty {
                Text(prog.description)
                    .font(.system(size: 18))
                    .foregroundColor(isFocused ? .white.opacity(0.8) : .textSecondary)
                    .lineLimit(nil)
            }
            // Time range + season/episode pill + feed badges, folded onto
            // one line so the height-limited cell doesn't gain a row.
            // Trailing badges clip first on narrow (short-duration) cells.
            // layoutPriority(1): in the fixed-height cell the description
            // (priority 0) must be what compresses -- without it, a long
            // description left this row a partial sliver that .clipped()
            // cut through the badges (Logan 2026-08-07 screenshot).
            HStack(spacing: 4) {
                Text("\(shortTimeFormatter.string(from: prog.start)) - \(shortTimeFormatter.string(from: prog.end))")
                    .font(.system(size: 17))
                    .foregroundColor(isFocused ? .white.opacity(0.6) : .textTertiary)
                if showEpgBadges {
                    SeasonEpisodePill(season: prog.season, episode: prog.episode, compact: true)
                    EPGFlagsRow(isLiveBroadcast: prog.isLiveBroadcast, isNew: prog.isNew,
                                isPremiere: prog.isPremiere, isFinale: prog.isFinale,
                                isRepeat: prog.isRepeat, compact: true)
                }
            }
            .layoutPriority(1)
            #else
            HStack(spacing: 4) {
                // Catch-up badge: aired + replayable from the archive.
                if canReplayNow {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9 * guideScale, weight: .semibold))
                        .foregroundColor(.accentPrimary)
                }
                Text(prog.title)
                    .font(.system(size: 12 * guideScale, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                if hasReminder {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9 * guideScale))
                        .foregroundColor(.accentPrimary)
                }
                // Audit #50: red dot on cells with a scheduled or
                // in-progress recording (same DVR red as the Android twin).
                if hasScheduledRecording {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.28, blue: 0.34))
                        .frame(width: 6 * guideScale, height: 6 * guideScale)
                }
            }
            .layoutPriority(1)
            // GH #34: XMLTV <sub-title> (match/episode name), guarded against the
            // Dispatcharr promote-into-description case so it never double-prints.
            let subShown = prog.subTitle.map {
                !$0.isEmpty && $0 != prog.title && $0 != prog.description
            } ?? false
            if subShown, let sub = prog.subTitle {
                Text(sub)
                    .font(.system(size: 10 * guideScale))
                    .italic()
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            // Skip the description when BOTH a sub-title and a badge row
            // render: the 72pt compact cell fits four priority rows (title,
            // sub, time, badges) but not five - the flexible description was
            // offered a sub-line sliver, still drew a full line, and pushed
            // the badge pills into the clip (Logan's iPhone pass 2026-08-19,
            // channels with REPEAT + sub-title). Same rule as the Android
            // cell: the description is the line that gives way. It remains in
            // Program Info.
            if !prog.description.isEmpty, !(subShown && compactBadgeRowVisible) {
                Text(prog.description)
                    .font(.system(size: 10 * guideScale))
                    .foregroundColor(.textSecondary)
                    .lineLimit(nil)
            }
            Text("\(shortTimeFormatter.string(from: prog.start)) - \(shortTimeFormatter.string(from: prog.end))")
                .font(.system(size: 9 * guideScale))
                .foregroundColor(.textTertiary)
                .layoutPriority(1)
            // Season/episode pill + feed badges on their own row at the
            // bottom of the cell content. On the narrow iPhone/compact cell
            // they read too busy folded onto the time line, so the cell
            // stacks title -> description -> badges top-down.
            // layoutPriority(1) on this row + the time line: the flexible
            // description (priority 0) must absorb the height shortfall in
            // the fixed-height cell -- without it these rows got a partial
            // sliver and .clipped() cut the badge pills mid-glyph
            // (Logan 2026-08-07 screenshot).
            compactBadgeRow
                .layoutPriority(1)
            #endif
        }
        .padding(.leading, 8 + leadingClip)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        // Emby style: full row height, flat rectangle, no rounded corners
        .frame(width: width, height: rowHeight, alignment: .topLeading)
        .background(cellBackground)
        #if os(tvOS)
        // The focus highlight is the brighter cellBackground, but on
        // category-tinted (and live) cells that is only a same-hue opacity
        // bump (0.35/0.45 -> 0.55) and reads as "no change" at TV distance,
        // so focus looked lost on colored cells even though it was correctly
        // held (the cell's isFocused state tracks the focus engine fine; the
        // tint delta is just invisible at TV distance). Add a category-
        // independent cue: a light white brightening wash plus a crisp inset
        // outline, both flat (no scale or shadow pop-out, matching the
        // v1.6.21 guide styling) so focus reads on any tint.
        .overlay {
            if isFocused {
                ZStack {
                    Color.white.opacity(0.20)
                    Rectangle().strokeBorder(Color.white, lineWidth: 4)
                }
            }
        }
        #endif
        .clipped()
        }
    }

    private var reminderKey: String {
        ReminderManager.programKey(channelName: channelItem.name, title: prog.title, start: prog.start)
    }

    private var isFutureProgram: Bool {
        prog.start > Date()
    }

    /// Catch-up: this programme has ENDED and is inside the channel's
    /// archive retention window, so the provider can replay it.
    private var canReplayNow: Bool {
        channelItem.canReplay(start: prog.start, end: prog.end)
    }

    /// Whether this program can be recorded (future or currently live).
    private var isRecordable: Bool {
        prog.end > Date()
    }

    /// v1.7.x: whether to offer a Record action for this program given
    /// the connected account's permission tier. A future program can
    /// only be recorded on the Dispatcharr server (POST
    /// /api/channels/recordings/, IsAdmin-only), so when the active
    /// Dispatcharr account isn't an admin we hide Record for future
    /// programs (it would 403 with no fallback; AerioTV can't
    /// auto-start a future local recording). Live programs always keep
    /// Record because the sheet falls back to local recording, which
    /// any account can do while the app is foregrounded.
    /// `dispatcharrCanRecordToServer` is true for non-Dispatcharr and
    /// admin servers, so their behavior is unchanged.
    private var canOfferRecord: Bool {
        guard isRecordable else { return false }
        if prog.isLive { return true }
        let canServer = ChannelStore.shared.activeServer?.dispatcharrCanRecordToServer ?? true
        return canServer
    }

    /// Unified sheet/cover driver for the program cell. Replaces the
    /// previous `showRecordSheet: Bool` + `programInfoTarget:
    /// ProgramInfoTarget?` pair of separate `.sheet` modifiers.
    ///
    /// Why: chaining two `.sheet(...)` modifiers on the same view
    /// (or two `.fullScreenCover(...)` on tvOS) is a known SwiftUI
    /// foot-gun — presenting one rebuilds the view hierarchy while
    /// the other's binding is observed, which cascades back and
    /// visibly flashes any active `contextMenu` during the open
    /// animation. User report on iPad (v1.6.7 Debug): "Long press
    /// on any program → Context menu flickers in and out of focus."
    /// Consolidating to one `.sheet(item:)` (or `.fullScreenCover
    /// (item:)`) + an enum payload keeps a single presentation
    /// channel and eliminates the cross-modifier invalidation.
    fileprivate enum GuideCellSheet: Identifiable {
        case record
        case programInfo(ProgramInfoTarget)
        var id: String {
            switch self {
            case .record:               return "record"
            case .programInfo(let t):   return "info-\(t.id)"
            }
        }
    }
    @State private var activeSheet: GuideCellSheet? = nil
    #if os(tvOS)
    // tvOS uses a confirmationDialog instead of .contextMenu because SwiftUI's
    // .contextMenu on tvOS rebuilds its UIMenu items every time the backing
    // cell re-renders, which visibly flashes the highlighted item. The dialog
    // route is a self-contained modal that is not re-evaluated from cell
    // updates, so the highlight stays stable.
    @State private var showCtxDialog = false
    // #45: per-channel "Add to Collection" picker + new-collection name alert.
    @State private var showCollectionPicker = false
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""
    #endif
    #if os(iOS)
    /// iOS long-press menu. Mirrors the mechanism ChannelListView
    /// already uses on upcoming-schedule rows (`.popover` over
    /// `.onLongPressGesture`) rather than `.contextMenu(menuItems:)`.
    ///
    /// Why: `.contextMenu` compiles to a UIKit `UIMenu` whose elements
    /// are rebuilt every time SwiftUI re-evaluates the cell body. Any
    /// ancestor `@Published` fire (VODStore still churning through
    /// its 779+479 categories on a slow server, for instance)
    /// cascades down to the cell, rebuilds the UIMenuElement array,
    /// and UIKit's "menu appearing" animation fades each item in —
    /// which the user sees as the four menu rows dimming and
    /// brightening over and over while the menu sits open. We
    /// proved this via Equatable + `.equatable()` (didn't help
    /// because `@EnvironmentObject favoritesStore` on the cell is a
    /// second re-render trigger that Equatable can't gate) before
    /// switching to this pure-SwiftUI popover approach.
    ///
    /// The popover renders a custom action-list view (see
    /// `guideProgramActionPopover`). It's SwiftUI all the way down,
    /// so SwiftUI's own diffing handles any ancestor re-renders
    /// without visible animation churn.
    @State private var showGuidePopover = false
    #endif

    var body: some View {
        #if os(tvOS)
        cellContent
            // tvOS: SwiftUI-native focusable cell (not a UIKit press overlay,
            // not a Button). `.focusable()` + `.focused` let the guide restore
            // focus to a specific program cell (return-from-player,
            // Menu-to-top), which the old UIKit overlay could not support
            // because SwiftUI focus APIs cannot drive a UIKit focus object. A
            // Button would swallow the long-press (its action fires on
            // release), so tap and long-press stay separate gestures, as on
            // iOS. isFocused drives the highlight; focusedProgramID is the
            // programmatic restore target.
            .focusable(!sidebarOpen)
            .focused($isFocused)
            .focused(focusedProgramID, equals: prog.id)
            .onTapGesture {
                if multiviewStore.isStagingFromGuide {
                    onMultiviewIntent(channelItem)
                } else {
                    onSelect(channelItem)
                }
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                // Guide "Select (hold)" slot, dispatched BY ACTION VALUE
                // (#196). The confirmationDialog below IS the program menu
                // (okLong = .programInfo by default); any other mapped
                // action runs through the shared dispatcher, and Do
                // Nothing suppresses the press entirely.
                let action = RemoteControlStore.shared.guideAction(.okLong)
                if action == .programInfo {
                    showCtxDialog = true
                } else {
                    GuideRemoteDispatch.perform(action)
                }
            }
            .confirmationDialog(prog.title,
                                isPresented: $showCtxDialog,
                                titleVisibility: .visible) {
                // Catch-up: a replayable aired programme leads with Watch
                // (the primary action for a show that already aired).
                if canReplayNow {
                    Button("Watch") {
                        onWatchCatchup(channelItem, prog)
                    }
                }
                // Favorite toggle first — most frequent action users take
                // on a program cell that isn't "just play it."
                Button(favoritesStore.isFavorite(channelItem.id)
                       ? "Remove from Favorites"
                       : "Add to Favorites") {
                    favoritesStore.toggle(channelItem)
                }
                // v1.7.x: Add / Remove from Multiview. Label flips
                // based on whether this channel is currently staged
                // so the action verb always describes what tapping
                // will do.
                Button(multiviewStore.tile(forChannelID: channelItem.id) != nil
                       ? "Remove from Multiview"
                       : "Add to Multiview") {
                    onMultiviewIntent(channelItem)
                }
                // #45: add/remove this channel from a user collection.
                Button("Add to Collection…") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showCollectionPicker = true }
                }
                // #45: contextual remove (viewing a collection -> that one;
                // otherwise remove from all, when it's in any).
                if let cid = ChannelCollectionsStore.shared.activeFilterCollectionID,
                   let coll = ChannelCollectionsStore.shared.collection(id: cid),
                   coll.memberIDs.contains(channelItem.id) {
                    Button("Remove from \(coll.name)", role: .destructive) {
                        ChannelCollectionsStore.shared.removeMember(channelID: channelItem.id, in: cid)
                    }
                } else if ChannelCollectionsStore.shared.activeFilterCollectionID == nil,
                          ChannelCollectionsStore.shared.isInAnyCollection(channelItem.id) {
                    Button("Remove from All Collections", role: .destructive) {
                        ChannelCollectionsStore.shared.removeFromAllCollections(channelItem.id)
                    }
                }
                Button("Program Info") {
                    activeSheet = .programInfo(
                        ProgramInfoTarget(
                            channelName: channelItem.name,
                            title: prog.title,
                            start: prog.start,
                            end: prog.end,
                            description: prog.description,
                            category: prog.category,
                            programID: prog.programID,
                            subTitle: prog.subTitle,
                            season: prog.season,
                            episode: prog.episode,
                            isNew: prog.isNew,
                            isLiveBroadcast: prog.isLiveBroadcast,
                            isPremiere: prog.isPremiere,
                            isFinale: prog.isFinale,
                            isRepeat: prog.isRepeat
                        )
                    )
                }
                if canOfferRecord {
                    Button(prog.isLive ? "Record from Now" : "Record") {
                        activeSheet = .record
                    }
                }
                if isFutureProgram {
                    if reminderManager.hasReminder(forKey: reminderKey) {
                        Button("Cancel Reminder", role: .destructive) {
                            reminderManager.cancelReminder(forKey: reminderKey)
                        }
                    } else {
                        Button("Set Reminder") {
                            reminderManager.scheduleReminder(
                                programTitle: prog.title,
                                channelName: channelItem.name,
                                startTime: prog.start
                            )
                        }
                    }
                }
            }
            // #45: per-channel "Add to Collection" (guide tvOS menu) — toggle
            // membership in any existing collection (✓ = member) or create one.
            .confirmationDialog("Add to Collection", isPresented: $showCollectionPicker, titleVisibility: .visible) {
                ForEach(ChannelCollectionsStore.shared.collections) { c in
                    Button((ChannelCollectionsStore.shared.contains(channelID: channelItem.id, in: c.id) ? "✓ " : "") + c.name) {
                        ChannelCollectionsStore.shared.toggleMember(channelID: channelItem.id, in: c.id)
                    }
                }
                Button("New Collection…") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNewCollectionAlert = true }
                }
            }
            .alert("New Collection", isPresented: $showNewCollectionAlert) {
                TextField("Name", text: $newCollectionName)
                Button("Add at Beginning") {
                    ChannelCollectionsStore.shared.create(name: newCollectionName, memberIDs: [channelItem.id], placement: .beginning)
                    newCollectionName = ""
                }
                Button("Add at End") {
                    ChannelCollectionsStore.shared.create(name: newCollectionName, memberIDs: [channelItem.id], placement: .end)
                    newCollectionName = ""
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            } message: {
                Text("Name the collection and choose where its pill appears in the Live TV row.")
            }
            // tvOS: .fullScreenCover (single, item-driven) — see
            // `GuideCellSheet` doc for why we consolidated.
            .fullScreenCover(item: $activeSheet) { sheet in
                switch sheet {
                case .record:
                    RecordProgramSheet(
                        programTitle: prog.title,
                        programDescription: prog.description,
                        channelID: channelItem.id,
                        channelName: channelItem.name,
                        scheduledStart: prog.start,
                        scheduledEnd: prog.end,
                        isLive: prog.isLive,
                        dispatcharrChannelID: channelItem.dispatcharrChannelID,
                        streamURL: channelItem.streamURL
                    )
                case .programInfo(let target):
                    ProgramInfoView(target: target)
                }
            }
        #else
        cellContent
            .contentShape(Rectangle())
            .onTapGesture {
                // v1.7.x: when staging is active, the cell tap
                // toggles the channel in the multiview pile rather
                // than starting playback. Otherwise normal Guide
                // behavior (play this channel). See
                // `EPGGuideView.handleMultiviewIntent(channel:)`.
                if multiviewStore.isStagingFromGuide {
                    onMultiviewIntent(channelItem)
                } else {
                    onSelect(channelItem)
                }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showGuidePopover = true
            }
            .popover(isPresented: $showGuidePopover, attachmentAnchor: .rect(.bounds)) {
                guideProgramActionPopover
                    .presentationCompactAdaptation(.popover)
            }
            // iOS: single .sheet(item:) — see `GuideCellSheet` doc
            // for why presenting both Record + Program Info through
            // separate sheet modifiers was bad.
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .record:
                    RecordProgramSheet(
                        programTitle: prog.title,
                        programDescription: prog.description,
                        channelID: channelItem.id,
                        channelName: channelItem.name,
                        scheduledStart: prog.start,
                        scheduledEnd: prog.end,
                        isLive: prog.isLive,
                        dispatcharrChannelID: channelItem.dispatcharrChannelID,
                        streamURL: channelItem.streamURL
                    )
                case .programInfo(let target):
                    ProgramInfoView(target: target)
                }
            }
        #endif
    }

    #if os(iOS)
    /// SwiftUI-native long-press menu content for iOS guide cells.
    /// Replaces the old `.contextMenu(menuItems:preview:)` because
    /// that form re-compiled its UIMenuElement array on every cell
    /// body re-eval, which made the menu items visibly pulse while
    /// the menu was open (the UIKit "menu appearing" fade fires per
    /// rebuild). This popover stays in SwiftUI land end-to-end, so
    /// SwiftUI's own diffing handles any ancestor re-renders without
    /// animation churn. Mirrors `ChannelListView.programActionPopover`
    /// both in structure and visual weight for UX consistency.
    @ViewBuilder
    private var guideProgramActionPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — channel + program title + time range. The
            // iOS context menu used to do this via its
            // `preview:` closure; doing it inline here gives the
            // same "what am I about to act on?" affordance without
            // needing the now-gone preview slot.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if prog.isLive {
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.statusLive)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(channelItem.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(prog.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                Text("\(shortTimeFormatter.string(from: prog.start)) – \(shortTimeFormatter.string(from: prog.end))")
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            VStack(spacing: 0) {
                // Catch-up: a replayable aired programme leads with Watch
                // (the primary action for a show that already aired).
                if canReplayNow {
                    guidePopoverActionButton(
                        title: "Watch",
                        systemImage: "clock.arrow.circlepath",
                        isDestructive: false
                    ) {
                        showGuidePopover = false
                        onWatchCatchup(channelItem, prog)
                    }
                }
                // Favorite toggle first — most frequent action on a
                // program cell that isn't "just play it."
                guidePopoverActionButton(
                    title: favoritesStore.isFavorite(channelItem.id)
                        ? "Remove from Favorites"
                        : "Add to Favorites",
                    systemImage: favoritesStore.isFavorite(channelItem.id)
                        ? "star.slash"
                        : "star",
                    isDestructive: false
                ) {
                    favoritesStore.toggle(channelItem)
                    showGuidePopover = false
                }
                // v1.7.x: Add / Remove from Multiview. Label and icon
                // flip based on whether this channel is currently
                // staged so the action verb always matches the
                // outcome of tapping.
                let isStaged = multiviewStore.tile(forChannelID: channelItem.id) != nil
                guidePopoverActionButton(
                    title: isStaged
                        ? "Remove from Multiview"
                        : "Add to Multiview",
                    systemImage: isStaged
                        ? "rectangle.3.group"
                        : "rectangle.3.group.fill",
                    isDestructive: false
                ) {
                    showGuidePopover = false
                    // Slight delay matches the Program Info / Record
                    // pattern below: iOS occasionally swallows
                    // follow-on UI work if it fires during the
                    // popover's dismiss animation.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onMultiviewIntent(channelItem)
                    }
                }
                guidePopoverActionButton(
                    title: "Program Info",
                    systemImage: "info.circle",
                    isDestructive: false
                ) {
                    showGuidePopover = false
                    // Slight delay so the popover dismiss animation
                    // finishes before the sheet presents — iOS
                    // sometimes swallows the sheet without this.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        activeSheet = .programInfo(
                            ProgramInfoTarget(
                                channelName: channelItem.name,
                                title: prog.title,
                                start: prog.start,
                                end: prog.end,
                                description: prog.description,
                                category: prog.category,
                                programID: prog.programID,
                                subTitle: prog.subTitle,
                                season: prog.season,
                                episode: prog.episode,
                                isNew: prog.isNew,
                                isLiveBroadcast: prog.isLiveBroadcast,
                                isPremiere: prog.isPremiere,
                                isFinale: prog.isFinale,
                                isRepeat: prog.isRepeat
                            )
                        )
                    }
                }
                if canOfferRecord {
                    guidePopoverActionButton(
                        title: prog.isLive ? "Record from Now" : "Record",
                        systemImage: "record.circle",
                        isDestructive: false
                    ) {
                        showGuidePopover = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            activeSheet = .record
                        }
                    }
                }
                if isFutureProgram {
                    if reminderManager.hasReminder(forKey: reminderKey) {
                        guidePopoverActionButton(
                            title: "Cancel Reminder",
                            systemImage: "bell.slash",
                            isDestructive: true
                        ) {
                            reminderManager.cancelReminder(forKey: reminderKey)
                            showGuidePopover = false
                        }
                    } else {
                        guidePopoverActionButton(
                            title: "Set Reminder",
                            systemImage: "bell.badge",
                            isDestructive: false
                        ) {
                            reminderManager.scheduleReminder(
                                programTitle: prog.title,
                                channelName: channelItem.name,
                                startTime: prog.start
                            )
                            showGuidePopover = false
                        }
                    }
                }
            }
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
    }

    /// One row inside `guideProgramActionPopover`. Same visual
    /// contract as `ChannelListView.popoverActionButton` —
    /// full-width tap target with leading icon + label — but the
    /// two views live in different modules so they can't share a
    /// private implementation. Small enough that the duplication
    /// is cheaper than plumbing a shared helper.
    private func guidePopoverActionButton(
        title: String,
        systemImage: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isDestructive ? .red : .accentPrimary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isDestructive ? .red : .textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    // `programPreviewCard` removed — previously fed the iOS
    // `.contextMenu(menuItems:preview:)` preview slot (#23 fix in
    // v1.6.4). The header strip inside `guideProgramActionPopover`
    // now carries the same "what am I about to act on?" affordance
    // (channel name + LIVE badge + program title + time range)
    // inside the popover itself, so the separate preview card is
    // no longer needed.

    #if os(tvOS)
    /// Focused = bright highlight, live = lighter gray, future = dark.
    private var cellBackground: Color {
        // Category colour (indigo / purple / light-blue / green by
        // default) takes precedence over the neutral white tint when
        // the user has the feature on and the program's category
        // matches a bucket.
        // The helper returns nil when the feature is off or no bucket
        // matches, so we fall through to the existing white-tint logic.
        // `categoryColorsEnabled` is intentionally read here (not just
        // via `CategoryColor.isEnabled`) so SwiftUI's dependency
        // tracking observes the `@AppStorage` and invalidates this
        // cell the instant the user flips the toggle in Settings.
        if categoryColorsEnabled,
           let cat = CategoryColor.backgroundColor(
            rawCategory: prog.category,
            isLive: prog.isLive,
            isFocused: isFocused
        ) {
            return cat
        }
        if isFocused { return Color.white.opacity(0.25) }
        if prog.isLive { return Color.white.opacity(0.12) }
        return Color.white.opacity(0.05)
    }
    #else
    private var cellBackground: Color {
        // See tvOS branch above — same fallthrough behaviour when the
        // feature is off or category doesn't match a known bucket.
        // Same `categoryColorsEnabled` dependency-tracking trick so
        // the iOS guide refreshes live on toggle.
        if categoryColorsEnabled,
           let cat = CategoryColor.backgroundColor(
            rawCategory: prog.category,
            isLive: prog.isLive,
            isFocused: false
        ) {
            return cat
        }
        return prog.isLive ? Color.accentPrimary.opacity(0.25) : Color.cardBackground
    }
    #endif
}

// MARK: - Guide Empty Row Button (tvOS — channels without EPG data)
#if os(tvOS)
private struct GuideEmptyRowButton: View {
    let label: String
    let width: CGFloat
    let rowHeight: CGFloat
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(isFocused ? .white : .textTertiary)
                .frame(width: width, height: rowHeight, alignment: .center)
                .background(isFocused ? Color.white.opacity(0.25) : Color.white.opacity(0.05))
        }
        .buttonStyle(GuideButtonStyle())
        .focused($isFocused)
    }
}
#endif

// MARK: - Guide Button Style (tvOS)
// Emby-style: NO scale on focus, just color change handled by the cell itself.
// Prevents program blocks from overlapping when focused.
#if os(tvOS)
private struct GuideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
#endif

// NOTE: `HorizontalPanGestureView` + `PassthroughView` were
// removed in favour of `.simultaneousGesture(DragGesture())`
// attached to the ScrollView (see `guideContent` above). The
// UIKit bridge claimed to "evaluate gesture recognizers before
// hitTest routing," but on iPad that's simply not true — UIKit
// only considers gesture recognizers whose attached view hit-
// tests to the touch, and the `PassthroughView`'s `hitTest`
// unconditionally returned nil. The gesture therefore never
// fired, which only became visible once the guide grid was
// wide enough to actually require horizontal scrolling.

#if os(tvOS)
/// Arms the hold-Right close-mini detector for the Guide (parity with
/// the List view's wiring in ChannelListView). Isolated struct so only
/// THIS invisible background re-renders when NowPlayingManager
/// publishes, never the guide grid.
private struct GuideMiniCloseRightHoldArm: View {
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    // Disarm while the in-place Search screen is up: the recognizer is on the
    // WINDOW, and a hold-Right while typing in the search keyboard closed the
    // mini (Logan 2026-08-12). The gesture belongs to the guide only.
    @ObservedObject private var searchOverlay = TVSearchOverlayState.shared
    var body: some View {
        GuideLongPressRightDetector(
            isEnabled: !searchOverlay.isUp && nowPlaying.isActive && nowPlaying.isMinimized,
            onBegan: {
                NotificationCenter.default.post(name: .guideRightHoldBegan, object: nil)
                // Full session teardown, not just the manager flags: on
                // the unified path the corner mini's player is owned by
                // PlayerSession, so nowPlaying.stop() alone cleared the
                // hint state while the video kept rendering, and Back
                // then EXPANDED the orphan (ATV field report: hold-Right
                // "resumed" the mini).
                withAnimation(.spring(response: 0.35)) { PlayerSession.shared.exit() }
            },
            onEnded: {
                NotificationCenter.default.post(name: .guideRightHoldEnded, object: nil)
            }
        )
    }
}
#else
private struct GuideMiniCloseRightHoldArm: View {
    var body: some View { Color.clear }
}
#endif

#if os(tvOS)
/// Window-level catcher for the pageUp/pageDown presses tvOS synthesizes from
/// CEC TV-remote channel keys (iOS #66). The presses are delivered to the
/// FOCUSED view, so a background sibling never sees them; recognizers on the
/// window do. Installed while the guide is on screen, removed with the view.
/// isUserInteractionEnabled=false keeps this view itself out of hit-testing
/// and the focus system entirely.
private struct TVPagePressCatcher: UIViewRepresentable {
    let onPage: (Bool) -> Void

    func makeUIView(context: Context) -> CatcherView { CatcherView(onPage: onPage) }
    func updateUIView(_ view: CatcherView, context: Context) { view.onPage = onPage }

    final class CatcherView: UIView {
        var onPage: (Bool) -> Void
        private var recognizers: [UITapGestureRecognizer] = []

        init(onPage: @escaping (Bool) -> Void) {
            self.onPage = onPage
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Remove from the OLD window on the way out (view holds the ref).
            recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
            recognizers = []
            guard let window else { return }
            let up = UITapGestureRecognizer(target: self, action: #selector(firePageUp))
            up.allowedPressTypes = [NSNumber(value: UIPress.PressType.pageUp.rawValue)]
            let down = UITapGestureRecognizer(target: self, action: #selector(firePageDown))
            down.allowedPressTypes = [NSNumber(value: UIPress.PressType.pageDown.rawValue)]
            window.addGestureRecognizer(up)
            window.addGestureRecognizer(down)
            recognizers = [up, down]
        }

        @objc private func firePageUp() { onPage(false) }
        @objc private func firePageDown() { onPage(true) }
    }
}
#endif
