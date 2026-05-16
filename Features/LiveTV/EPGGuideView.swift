import SwiftUI
import SwiftData

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

    /// Computed: the program is currently airing.
    var isLive: Bool {
        let now = Date()
        return start <= now && end > now
    }

    /// Convenience initializer that defaults `programID` to nil so the
    /// dozen+ existing call sites (XMLTV merge, Xtream, dummy fillers,
    /// etc.) don't need to change. Dispatcharr-specific construction
    /// sites pass an explicit `programID:` to enable lazy category load.
    init(channelID: String, title: String, description: String,
         start: Date, end: Date, category: String, programID: Int? = nil) {
        self.channelID = channelID
        self.title = title
        self.description = description
        self.start = start
        self.end = end
        self.category = category
        self.programID = programID
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

    @Published var programs: [String: [GuideProgram]] = [:]  // channelID → programs
    @Published var isLoading = false

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

    private func beginBatch(basePrograms: [String: [GuideProgram]]? = nil) {
        _isBatching = true
        _pendingPrograms = basePrograms ?? programs
    }

    private func endBatch() {
        _isBatching = false
        programs = _pendingPrograms
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
        let refreshMins = UserDefaults.standard.integer(forKey: "bgRefreshIntervalMins")
        let effectiveMins = refreshMins > 0 ? refreshMins : 1440 // 0 means unset → default 24h
        let stalenessThreshold = TimeInterval(effectiveMins * 60)

        // Wrap the fetch in a Task that concurrent callers can join
        // via `inFlightLoadTask`. The Task inherits @MainActor from
        // the enclosing function, so `self.programs = …` + log +
        // lastLoadFromCacheResult writes all happen on main. The
        // expensive work is still in the nested Task.detached.
        let fetchTask = Task<Bool, Never> { [self] in
            let loaded: (dict: [String: [GuideProgram]], programCount: Int, isFresh: Bool, newestFetchAgoSec: Int)? = await Task.detached(priority: .userInitiated) {
                let bgContext = ModelContext(container)

                // v1.6.7 one-shot migration: the pre-v1.6.7 XMLTV
                // parser concatenated multiple `<category>` tags
                // into a single string with no separator (bug:
                // `"EpisodeSeriesRealityLaw"` instead of four
                // distinct tokens). Upgrading users have those
                // broken strings persisted in SwiftData; the
                // title+time dedupe in `performXMLTVFetch` would
                // preserve the old rows even after a fresh parse.
                // We purge ALL EPGProgram rows here — inside the
                // same detached task that's about to fetch them —
                // so there's no race with a concurrent fetch
                // starting before the prune finishes. Returning
                // `nil` makes the caller treat the cache as empty,
                // which triggers the full XMLTV re-fetch through
                // the fixed parser. One-shot: the UserDefaults key
                // gates the purge so subsequent launches skip it.
                //
                // Key version bumped to v2 because an earlier
                // attempt ran the migration in
                // `pruneOrphanedEPGPrograms` as a separate
                // lower-priority detached task, which raced the
                // `loadFromCache` fetch — the fetch won, populated
                // `programs` with concatenated strings, and the
                // v1 flag was already set. Bumping the key forces
                // a clean re-run on devices that participated in
                // that race.
                let migrationKey = "xmltvCategoryFixMigrationV2"
                if !UserDefaults.standard.bool(forKey: migrationKey) {
                    if let allRows = try? bgContext.fetch(FetchDescriptor<EPGProgram>()) {
                        for ep in allRows { bgContext.delete(ep) }
                        try? bgContext.save()
                        debugLog("🗑️ v1.6.7 XMLTV category-fix migration: purged \(allRows.count) rows for fresh re-parse")
                    }
                    UserDefaults.standard.set(true, forKey: migrationKey)
                    return nil
                }

                let now = Date()
                let windowStart = now.addingTimeInterval(-3600)
                let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)
                let descriptor = FetchDescriptor<EPGProgram>(
                    predicate: #Predicate<EPGProgram> {
                        $0.serverID == serverID && $0.endTime > windowStart && $0.startTime < windowEnd
                    },
                    sortBy: [SortDescriptor(\.startTime)]
                )
                guard let cachedRows = try? bgContext.fetch(descriptor), !cachedRows.isEmpty else {
                    return nil
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
                                          programID: ep.programID)
                    dict[ep.channelID, default: []].append(gp)
                }
                let newestFetch = cachedRows.map(\.fetchedAt).max() ?? .distantPast
                let isFresh = now.timeIntervalSince(newestFetch) < stalenessThreshold
                return (dict, cachedRows.count, isFresh, Int(now.timeIntervalSince(newestFetch)))
            }.value

            guard let loaded else {
                debugLog("📺 GuideStore.loadFromCache: no cached programs for server \(serverID)")
                self.lastLoadFromCacheResult = (serverID: serverID, isFresh: false)
                return false
            }

            // Back on the MainActor. The only remaining main-thread
            // work is the `programs` assignment (fires @Published)
            // plus two log lines. The 97k-row fetch + dict build
            // already happened off-main.
            self.programs = loaded.dict
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
    /// - The v1.6.7 one-shot migration inside `loadFromCache`'s
    ///   detached task (which already does the SwiftData purge
    ///   inline; just calls this for the in-memory side).
    func invalidateCache() {
        programs = [:]
        lastLoadFromCacheResult = nil
        inFlightLoadTask?.task.cancel()
        inFlightLoadTask = nil
        inFlightXMLTVTask?.task.cancel()
        inFlightXMLTVTask = nil
        lastSeedEPGCacheSignature = nil
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
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36

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
            let hourAgo = now.addingTimeInterval(-3600)

            // Delete stale programs (ended > 1 hour ago)
            let staleDescriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> { $0.endTime < hourAgo }
            )
            if let stale = try? bgContext.fetch(staleDescriptor) {
                for s in stale { bgContext.delete(s) }
            }

            // Delete existing programs for this server in the current window
            let windowStart = now.addingTimeInterval(-3600)
            let windowEnd = now.addingTimeInterval(Double(max(effectiveWindowHours, 24)) * 3600)
            let existingDescriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> {
                    $0.serverID == serverID && $0.endTime > windowStart && $0.startTime < windowEnd
                }
            )
            if let existing = try? bgContext.fetch(existingDescriptor) {
                for e in existing { bgContext.delete(e) }
            }

            // Insert current programs
            var count = 0
            for (channelID, progs) in snapshot {
                for gp in progs {
                    // v1.7.x: persist `programID` so cold-launch
                    // Program Info lazy-load survives the cache hit.
                    let ep = EPGProgram(channelID: channelID, title: gp.title,
                                        description: gp.description,
                                        startTime: gp.start, endTime: gp.end,
                                        category: gp.category, serverID: serverID,
                                        programID: gp.programID)
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
        case .xtreamCodes:
            // Xtream: still need per-channel fetching with batches
            let initialBatchSize = 40
            let initialChannels = Array(channels.prefix(initialBatchSize))
            let remainingChannels = channels.count > initialBatchSize ? Array(channels.suffix(from: initialBatchSize)) : []

            var didReceiveAnyResponse = await fetchXtream(
                server: server,
                channels: initialChannels,
                windowStart: windowStart,
                windowEnd: windowEnd,
                replaceExisting: replaceExisting
            )

            // Phase 2: backfill remaining Xtream channels
            if !remainingChannels.isEmpty {
                let batchSize = 20
                for batchStart in stride(from: 0, to: remainingChannels.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, remainingChannels.count)
                    let batch = Array(remainingChannels[batchStart..<batchEnd])
                    let batchDidRespond = await fetchXtream(
                        server: server,
                        channels: batch,
                        windowStart: windowStart,
                        windowEnd: windowEnd,
                        replaceExisting: replaceExisting
                    )
                    didReceiveAnyResponse = didReceiveAnyResponse || batchDidRespond
                    await Task.yield()
                }
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
        defer {
            if shouldCommitBatch {
                endBatch()
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
        // dictionary lookup. Channel.tvg_id wins when both are
        // present and differ.
        var tvgIDToChannelIDBuild: [String: String] = [:]
        for ch in channels {
            if let tvg = ch.tvgID, !tvg.isEmpty {
                tvgIDToChannelIDBuild[tvg.lowercased()] = ch.id
            }
        }
        var bridgedEntryCount = 0
        for ch in channels {
            guard let epgID = ch.dispatcharrEPGDataID,
                  let bridgedTvgID = epgDataIDToTvgID[epgID],
                  !bridgedTvgID.isEmpty else { continue }
            let key = bridgedTvgID.lowercased()
            if tvgIDToChannelIDBuild[key] == nil {
                tvgIDToChannelIDBuild[key] = ch.id
                bridgedEntryCount += 1
            }
        }
        if bridgedEntryCount > 0 {
            debugLog("📺 Dispatcharr: bridged \(bridgedEntryCount) channels via epg_data_id → EPGData.tvg_id")
        }
        let tvgIDToChannelID = tvgIDToChannelIDBuild
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
        // `tvgIDToChannelID` lookup misses and the `intIDToChannelID`
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
        debugLog("📺 Dispatcharr: fetching EPG grid, tvgID map has \(tvgIDToChannelID.count) entries, intID map has \(intIDToChannelID.count) entries, uuid map has \(uuidToChannelID.count) entries")
        #endif
        do {
            let gridPrograms = try await api.getEPGGrid()
            #if DEBUG
            debugLog("📺 Dispatcharr: EPG grid returned \(gridPrograms.count) programs")
            #endif
            var matched = 0
            var matchedViaUUID = 0
            for prog in gridPrograms {
                guard let start = prog.startTime?.toDate(),
                      let end = prog.endTime?.toDate(),
                      end > windowStart && start < windowEnd else { continue }
                let channelID: String?
                if let tvg = prog.tvgID, !tvg.isEmpty {
                    let key = tvg.lowercased()
                    if let cid = tvgIDToChannelID[key] {
                        channelID = cid
                    } else if let cid = uuidToChannelID[key] {
                        // Dummy EPG entry — the `tvg_id` IS the channel UUID.
                        channelID = cid
                        matchedViaUUID += 1
                    } else {
                        channelID = nil
                    }
                } else if let chInt = prog.channel {
                    channelID = intIDToChannelID[chInt]
                } else {
                    channelID = nil
                }
                guard let cid = channelID else { continue }
                matched += 1
                let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                // v1.7.x: thread `programID` so ProgramInfoView can
                // lazy-load `<category>` via /api/epg/programs/<id>/
                // when the user opens the modal. The bulk grid strips
                // categories server-side, so without this the modal
                // shows zero pills for any program that wasn't part
                // of the now-airing enrichment fan-out.
                let gp = GuideProgram(channelID: cid, title: prog.title,
                                      description: desc, start: start, end: end,
                                      category: "", programID: prog.programID)
                mergeProgram(gp, for: cid)
            }
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
                                                        tvgIDToChannelID: tvgIDToChannelID,
                                                        uuidToChannelID: uuidToChannelID,
                                                        serverID: categoryServerID)
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
                let channelID: String?
                if let tvg = prog.tvgID, !tvg.isEmpty {
                    let key = tvg.lowercased()
                    channelID = tvgIDToChannelID[key] ?? uuidToChannelID[key]
                } else if let chInt = prog.channel {
                    channelID = intIDToChannelID[chInt]
                } else {
                    channelID = nil
                }
                guard let cid = channelID else { continue }
                let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                let gp = GuideProgram(channelID: cid, title: prog.title,
                                      description: desc, start: start, end: end,
                                      category: "", programID: prog.programID)
                mergeProgram(gp, for: cid)
            }
        }

        // Bulk fetch upcoming programs as supplement
        if let allPrograms = try? await api.getBulkUpcomingPrograms(maxPages: 10) {
            didFetchFallback = true
            for prog in allPrograms {
                guard let start = prog.startTime?.toDate(),
                      let end = prog.endTime?.toDate(),
                      end > windowStart && start < windowEnd else { continue }
                let channelID: String?
                if let tvg = prog.tvgID, !tvg.isEmpty {
                    let key = tvg.lowercased()
                    channelID = tvgIDToChannelID[key] ?? uuidToChannelID[key]
                } else if let chInt = prog.channel {
                    channelID = intIDToChannelID[chInt]
                } else {
                    channelID = nil
                }
                guard let cid = channelID else { continue }
                let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                let gp = GuideProgram(channelID: cid, title: prog.title,
                                      description: desc, start: start, end: end,
                                      category: "", programID: prog.programID)
                mergeProgram(gp, for: cid)
            }
        }

        let didRefresh = didLoadXMLTVOverride || didFetchFallback
        shouldCommitBatch = didRefresh
        return didRefresh
    }

    // MARK: - Xtream Codes
    private func fetchXtream(server: ServerConnection, channels: [ChannelDisplayItem],
                              windowStart: Date, windowEnd: Date,
                              replaceExisting: Bool = false) async -> Bool {
        let batchBasePrograms = replaceExisting
            ? replacingWindowBase(for: channels, windowStart: windowStart, windowEnd: windowEnd)
            : nil
        beginBatch(basePrograms: batchBasePrograms)
        var shouldCommitBatch = false
        defer {
            if shouldCommitBatch {
                endBatch()
            } else {
                cancelBatch()
            }
        }
        let api = XtreamCodesAPI(baseURL: server.effectiveBaseURL,
                                  username: server.username,
                                  password: server.effectivePassword)

        // Fetch with limited concurrency (max 3 concurrent) and 15s timeout per request
        let didReceiveAnyResponse = await withTaskGroup(of: (String, [GuideProgram], Bool).self) { group in
            let maxConcurrent = 3
            var launched = 0
            var didReceiveAnyResponse = false

            for ch in channels {
                if launched >= maxConcurrent {
                    if let (channelID, progs, didRespond) = await group.next() {
                        didReceiveAnyResponse = didReceiveAnyResponse || didRespond
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
        tvgIDToChannelID: [String: String],
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
            guard !key.isEmpty,
                  let cid = tvgIDToChannelID[key] ?? uuidToChannelID[key] else { continue }
            if currentByChannelID[cid] == nil {
                currentByChannelID[cid] = pid
                programIDByChannelID[cid] = pid
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
            debugLog("📺 enrich SKIP: gridPrograms=\(gridPrograms.count) tvgMap=\(tvgIDToChannelID.count) uuidMap=\(uuidToChannelID.count); no currently-airing program matched all guards")
            return
        }
        debugLog("📺 Dispatcharr category enrichment: \(currentByChannelID.count) currently-airing programs; fetching /api/epg/programs/<id>/ at cap-of-4")
        let cats = await api.enrichCategories(programIDs: Array(currentByChannelID.values))
        var byChannel: [String: String] = [:]
        for (cid, pid) in currentByChannelID {
            if let c = cats[pid] { byChannel[cid] = c }
        }
        debugLog("📺 Dispatcharr category enrichment: \(byChannel.count)/\(currentByChannelID.count) channels got categories")
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
        for (cid, cats) in byChannel {
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
                                       category: cats,
                                       programID: old.programID)

            // Title-matched propagation across the rest of the
            // channel's programs. Skip the now-airing index (just
            // updated above) and any program that already carries
            // a non-empty category (idempotent on warm relaunch +
            // respects categories from XMLTV-merge if that ran
            // first).
            if !nowTitle.isEmpty {
                for j in progs.indices where j != idx {
                    let p = progs[j]
                    guard p.title == nowTitle, p.category.isEmpty else { continue }
                    progs[j] = GuideProgram(channelID: p.channelID,
                                             title: p.title,
                                             description: p.description,
                                             start: p.start,
                                             end: p.end,
                                             category: cats,
                                             programID: p.programID)
                }
            }

            updated[cid] = progs
        }
        self.programs = updated

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

        // Wrap the fetch+parse+merge body in a Task so a concurrent
        // caller with the same URL can join via `inFlightXMLTVTask`.
        // Inherits @MainActor from the enclosing GuideStore, which
        // matters for the `beginBatch`/`endBatch` + `mergeProgram`
        // calls that follow.
        let fetchTask = Task<Bool, Never> { [self] in
            return await performXMLTVFetch(url: url, channels: channels,
                                           windowStart: windowStart, windowEnd: windowEnd,
                                           headers: headers,
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
    /// network/HTTP/parse failure so callers can fall through to a
    /// non-XMLTV backstop. The Dispatcharr-specific 403 case
    /// (LAN-only `/output/epg` policy) is the v1.6.22 reason this
    /// signal exists; Dispatcharr also publishes its programs via
    /// `/api/epg/grid/` (no categories), and `EPGGuideView.fetchDispatcharr`
    /// uses the false return to fall through to that endpoint
    /// instead of leaving the Guide grid empty.
    private func performXMLTVFetch(url: URL, channels: [ChannelDisplayItem],
                                   windowStart: Date, windowEnd: Date,
                                   headers: [String: String],
                                   categoryServerID: String,
                                   replaceExisting: Bool) async -> Bool {
        // v1.6.22: log the actual error instead of swallowing it via
        // `try?`. The previous "XMLTV fetch/parse failed for <host>"
        // line told us nothing about WHY (auth? timeout? parse error?),
        // which made Freyguy1975's 403-on-/output/epg invisible until
        // we curl-probed the endpoint manually. Surface status + error
        // so the next case is diagnosable from the log alone.
        let parsed: [ParsedEPGProgram]
        do {
            parsed = try await XMLTVParser.fetchAndParse(url: url, headers: headers)
            debugLog("📺 XMLTV fetched OK from \(url.host ?? "?") (headers=\(headers.count), \(parsed.count) programs parsed)")
        } catch let APIError.serverError(code) {
            // v1.6.22: spell out the most common WAN-deployment
            // root cause when we hit 403. Dispatcharr 0.23.0+
            // defaults `/output/epg` to LAN-only. Every Cloudflare
            // tunnel / Synology QuickConnect / public hostname user
            // hits this.
            if code == 403 {
                debugLog("📺 XMLTV fetch failed for \(url.host ?? "?"): HTTP 403 (headers=\(headers.count)). Likely Dispatcharr's M3U/EPG Network Access policy blocking non-LAN clients (default since Dispatcharr 0.23.0). Fix in Dispatcharr → Settings → Network Access → 'M3U / EPG Endpoints': add 0.0.0.0/0,::/0 or the client's public IP.")
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
        let tvgIDToChannelID: [String: String] = Dictionary(
            channels.compactMap { ch in
                guard let tvg = ch.tvgID, !tvg.isEmpty else { return nil }
                return (tvg.lowercased(), ch.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
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
                let channelID = tvgIDToChannelID[key]
                    ?? numberToChannelID[prog.channelID]
                    ?? uuidToChannelID[key]
                guard let cid = channelID else {
                    missed += 1
                    continue
                }
                matched += 1
                let gp = GuideProgram(channelID: cid, title: prog.title,
                                      description: prog.description,
                                      start: prog.startTime, end: prog.endTime,
                                      category: prog.category)
                // deferSort: true — a 98k-iteration loop over ~2,100
                // channels means each channel gets ~46 inserts on
                // average; sorting per insert is 46× more work than
                // sorting each list once at the end.
                GuideStore.mergeProgramInto(&dict, program: gp, for: cid, deferSort: true)
                touchedChannelIDs.insert(cid)
                // Track currently-airing program category.
                if !prog.category.isEmpty, prog.startTime <= now, prog.endTime > now {
                    currentCategoriesByChannelID[cid] = prog.category
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
        programs = result.dict
        debugLog("📺 XMLTV \(hostLabel): \(result.matched) programs matched, \(result.missed) skipped (no channel)")
        // Back-fill ChannelStore so Tint Channel Cards reflects
        // the XMLTV categories on every channel row.
        ChannelStore.shared.applyXMLTVCategories(result.currentCategoriesByChannelID, serverID: categoryServerID)
        return true
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
                                                    category: "", programID: prog.programID)
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
    nonisolated static func mergeProgramInto(
        _ dict: inout [String: [GuideProgram]],
        program prog: GuideProgram,
        for channelID: String,
        deferSort: Bool = false
    ) {
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
            let needsUpdate = mergedDescription != existing.description
                || mergedCategory != existing.category
                || mergedProgramID != existing.programID
            if needsUpdate {
                list[idx] = GuideProgram(
                    channelID: existing.channelID,
                    title: existing.title,
                    description: mergedDescription,
                    start: existing.start,
                    end: existing.end,
                    category: mergedCategory,
                    programID: mergedProgramID
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
    #if os(tvOS)
    /// Programmatic focus target for a channel row's left-hand cell.
    /// Normally nil (focus engine drives navigation).
    @FocusState private var focusedChannelID: String?

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
    private let hoursBack: TimeInterval = 1
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
    private var channelColumnWidth: CGFloat { 100 * guideScale }
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
        ZStack {
            Color.appBackground.ignoresSafeArea()
            guideContent
            // v1.7.x: staging-mode toast bottom-center. Sits in the
            // ZStack rather than as a sibling modifier so it floats
            // above the guide grid (including the horizontal
            // ScrollView contents) while staying out of the way of
            // the time header and channel column.
            if let msg = stagingToast {
                VStack {
                    Spacer()
                    stagingToastView(msg)
                        .padding(.bottom, 32)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: stagingToast)
        // v1.7.x: in-Guide staging banner. Pinned at the top via
        // safeAreaInset so the guide content shifts down rather than
        // being covered. Only renders when `isStagingFromGuide` is
        // true. When the flag flips off (user tapped Done, hit the
        // hard cap, or removed every tile), the safe area collapses
        // back. Conditional view inside the closure cleanly produces
        // an empty inset when off; SwiftUI animates the collapse.
        .safeAreaInset(edge: .top, spacing: 0) {
            if multiviewStore.isStagingFromGuide {
                stagingBanner
            }
        }
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
            // seedFromChannels data — only current programs, nothing upcoming).
            //
            // The previous form (`.values.flatMap { $0 }.contains { … }`)
            // eagerly allocated a flattened Array across every cached
            // program on the main thread — on the 97k-row torture-test
            // playlist that's a 15+ MB alloc and a ~2-3s hang per call.
            // The nested-contains form short-circuits twice: outer on
            // the first channel with any future program, inner on the
            // first future program in that channel. On a healthy EPG
            // cache this is effectively O(1).
            let futureCutoff = Date().addingTimeInterval(1800)
            let hasFuturePrograms = guideStore.programs.contains { _, progs in
                progs.contains { $0.end > futureCutoff }
            }
            guard !cacheIsFresh || !hasFuturePrograms else {
                debugLog("📺 EPG cache is fresh with future programs — skipping network fetch")
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
        // Timer removed — time indicator redraws via TimelineView
    }

    // MARK: - Horizontal Scroll State
    // Manual horizontal offset — only changes when user explicitly scrolls (drag/swipe).
    // Focus changes do NOT cause horizontal movement.
    // Initial value positions "now" at the left edge of the visible area.
    #if os(tvOS)
    @State private var horizontalOffset: CGFloat = -600  // -(hoursBack=1 * pixelsPerHour=600)
    #else
    @State private var horizontalOffset: CGFloat = -360  // -(hoursBack=1 * pixelsPerHour=360)
    #endif

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
            // anchor with `.id("guide.top")` lives inside the Section
            // content (above the ForEach) so it scrolls normally —
            // it's not the pinned header, which wouldn't be a valid
            // scroll target anyway. `.scrollTo(..., anchor: .top)`
            // positions the anchor just below the pinned time header,
            // which is exactly where the first channel row belongs.
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: rowGap, pinnedViews: [.sectionHeaders]) {
                    Section {
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
                        ForEach(channels) { channel in
                            guideRow(for: channel, screenWidth: geo.size.width, focusTargetID: focusTargetID)
                        }
                    } header: {
                        // ── Time header (pinned at top) ──
                        HStack(spacing: 0) {
                            Color.cardBackground
                                .frame(width: channelColumnWidth, height: timeHeaderHeight)
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(Color.accentPrimary.opacity(0.2)).frame(width: 1)
                                }
                                .zIndex(1)

                            timeHeaderRow
                                .frame(width: totalGridWidth, height: timeHeaderHeight)
                                .offset(x: horizontalOffset)
                                .frame(width: geo.size.width - channelColumnWidth, height: timeHeaderHeight, alignment: .leading)
                                .clipped()
                        }
                        .frame(width: geo.size.width, height: timeHeaderHeight, alignment: .leading)
                        .background(Color.appBackground)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.accentPrimary.opacity(0.15)).frame(height: 1)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        timeIndicatorLine(screenWidth: geo.size.width, now: context.date)
                            .allowsHitTesting(false)
                    }
                }
            }
            .clipped()
            .onAppear { visibleProgramWidth = geo.size.width - channelColumnWidth }
            .onChange(of: geo.size.width) { _, w in visibleProgramWidth = w - channelColumnWidth }
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
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    withAnimation(.easeOut(duration: 0.3)) {
                        horizontalOffset = min(0, horizontalOffset + pixelsPerHour * 0.5)
                    }
                case .right:
                    withAnimation(.easeOut(duration: 0.3)) {
                        horizontalOffset = max(maxHorizontalOffset, horizontalOffset - pixelsPerHour * 0.5)
                    }
                default:
                    break
                }
            }
            #endif
            .onReceive(
                NotificationCenter.default.publisher(for: .guideScrollToTop)
            ) { _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("guide.top", anchor: .top)
                }
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
                Task { @MainActor in
                    // Resolve target: use the last-added multiview tile
                    // (keyed by addedAt, not array order which can change
                    // via drag-rearrange), then fall back to the single-
                    // stream playing item, then nil → top row.
                    let mvLastID = MultiviewStore.shared.tiles
                        .max(by: { $0.addedAt < $1.addedAt })?.item.id
                    let singleID = NowPlayingManager.shared.playingItem?.id
                    let candidateID = mvLastID ?? singleID
                    // Only store the target if it's actually present in
                    // the current (possibly filtered) channel list —
                    // otherwise leave it nil so the fallback to
                    // channels.first in prefersDefaultFocus still fires.
                    guideFocusTargetChannelID = candidateID.flatMap { id in
                        channels.first(where: { $0.id == id })?.id
                    }
                    // The 400ms delay covers the 350ms minimize spring
                    // animation; triggering during the animation lets
                    // tvOS ignore the reset because the mini tile's
                    // frame is still in flux.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    // Scroll the guide to bring the target row into
                    // view before handing focus to it. Re-validate
                    // against channels here (post-sleep) in case the
                    // list or filter changed during the 400ms delay —
                    // scroll is skipped rather than targeting a missing
                    // id. Falls back to top-row focus via resetFocus.
                    let validatedScrollTargetID = guideFocusTargetChannelID.flatMap { id in
                        channels.first(where: { $0.id == id })?.id
                    }
                    if let id = validatedScrollTargetID {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    resetFocus(in: guideFocusNS)
                }
            }
            #endif
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

            if progs.isEmpty {
                // No guide programs — show a tappable row so the channel is still selectable
                #if os(tvOS)
                GuideEmptyRowButton(
                    label: channel.currentProgram ?? "No guide data",
                    width: totalGridWidth, rowHeight: rowHeight
                ) { onSelectChannel(channel) }
                #else
                Text(channel.currentProgram ?? "No guide data")
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
                    .frame(width: totalGridWidth, height: rowHeight, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectChannel(channel) }
                #endif
            } else {
                // Viewport clipping: only render programs overlapping the visible time window
                // plus 30-min padding on each side for smooth scrolling.
                let visibleFraction = -horizontalOffset / totalGridWidth
                let visibleWidthFraction = visibleProgramWidth / totalGridWidth
                let visibleTimeStart = windowStart.addingTimeInterval(Double(visibleFraction) * totalDuration)
                let visibleTimeEnd = visibleTimeStart.addingTimeInterval(Double(visibleWidthFraction) * totalDuration)
                let pad: TimeInterval = 1800 // 30 minutes
                let filterStart = visibleTimeStart.addingTimeInterval(-pad)
                let filterEnd = visibleTimeEnd.addingTimeInterval(pad)

                let sortedProgs = progs
                    .filter { $0.end > filterStart && $0.start < filterEnd }
                    .sorted { $0.start < $1.start }
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

        return GuideProgramButton(
            prog: prog, channelItem: channelItem, width: width, rowHeight: rowHeight,
            leadingClip: leadingClip,
            shortTimeFormatter: shortTimeFormatter,
            onSelect: onSelectChannel,
            onMultiviewIntent: { handleMultiviewIntent(channel: $0) }
        )
        .offset(x: x, y: 0)
        // NOTE: `.focused($focusedProgramID, equals: prog.id)` was
        // previously attached here on tvOS as a programmatic focus
        // hook for `.forceGuideFocus` (mini-player minimize → land
        // focus on the first channel's "now" cell). It has been
        // removed because it silently created a second focus
        // target on top of the `TVPressOverlay`'s
        // `PressCatcherView` (see
        // `Shared/TVPressGesture.swift:43` — "Do NOT also add
        // `.focusable()` / `.focused()` to cellContent — the
        // overlay UIView is the focusable element. Having both
        // would create two competing focus targets"). The dual
        // targets manifested as specific program cells being
        // unreachable via Siri Remote D-pad: the tvOS focus
        // engine saw two focusable regions per cell and routed
        // inconsistently, skipping some cells entirely (a small
        // set of cells on certain channels at certain times).
        // The minor regression: after mini-player minimize, focus
        // now lands on whatever cell the tvOS focus engine picks
        // by default rather than the first channel's live cell
        // specifically. The user can D-pad to reach their
        // intended cell — acceptable tradeoff versus some cells
        // being permanently unreachable.
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
    /// is true. Surfaces the current tile count and a Done button so
    /// the user always has a visible way to exit staging mode.
    /// Tapping a channel in the Guide while this banner is showing
    /// toggles that channel in/out of the multiview pile instead of
    /// starting playback. See `handleMultiviewIntent(channel:)` for
    /// the toggle logic.
    private var stagingBanner: some View {
        let count = multiviewStore.tiles.count
        let label = count == 1
            ? "1 tile staged for Multiview"
            : "\(count) tiles staged for Multiview"
        return HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentPrimary)
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.textPrimary)
            Spacer()
            Button {
                multiviewStore.isStagingFromGuide = false
                DebugLogger.shared.log(
                    "[MV-Tile] staging mode: user tapped Done (count=\(multiviewStore.tiles.count))",
                    category: "Playback", level: .info
                )
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentPrimary))
            }
            .buttonStyle(.plain)
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

    private func xOffset(for date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSince(windowStart)
        return CGFloat(elapsed / totalDuration) * totalGridWidth
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
private struct GuideChannelButton: View {
    let channel: ChannelDisplayItem
    let onSelect: (ChannelDisplayItem) -> Void
    @EnvironmentObject private var favoritesStore: FavoritesStore

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
            .overlay(alignment: .topTrailing) {
                if favoritesStore.isFavorite(channel.id) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.statusWarning)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect(channel) }
            // Long-press to manage favorite without leaving the guide.
            // Fills the UX gap raised in Veldmuus's feedback pass — adding
            // favorites was previously only possible from Live TV List view.
            .contextMenu {
                Button {
                    favoritesStore.toggle(channel)
                } label: {
                    if favoritesStore.isFavorite(channel.id) {
                        Label("Remove from Favorites", systemImage: "star.slash")
                    } else {
                        Label("Add to Favorites", systemImage: "star")
                    }
                }
            }
        #endif
    }

    private var channelLabel: some View {
        #if os(tvOS)
        // Emby-style: channel number on left, logo + name on right
        HStack(spacing: 8) {
            Text(channel.number)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 38, alignment: .trailing)

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
                Text(channel.name)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        #else
        VStack(spacing: 4) {
            // v1.6.23: same auth-aware fix as the tvOS branch above.
            if channel.logoURL != nil {
                CachedLogoImage(url: channel.logoURL, width: 40, height: 28)
            } else {
                guidePlaceholder
            }
            VStack(spacing: 1) {
                Text(channel.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                Text(channel.number)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.textTertiary)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
    // Access ReminderManager directly — @ObservedObject on a singleton
    // would invalidate every program cell whenever any reminder changes.
    private var reminderManager: ReminderManager { .shared }
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
    // @State (not @FocusState) because a transparent UIKit overlay
    // (TVPressOverlay) is what actually owns focus on tvOS now; it
    // pushes focus changes back into this binding via onFocusChange.
    @State private var isFocused: Bool = false
    #endif

    private var hasReminder: Bool {
        isFutureProgram && reminderManager.hasReminder(forKey: reminderKey)
    }

    private var cellContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            #if os(tvOS)
            HStack(spacing: 4) {
                Text(prog.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(isFocused ? .white : .textPrimary)
                    .lineLimit(1)
                if hasReminder {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 14))
                        .foregroundColor(isFocused ? .white : .accentPrimary)
                }
            }
            if !prog.description.isEmpty {
                Text(prog.description)
                    .font(.system(size: 18))
                    .foregroundColor(isFocused ? .white.opacity(0.8) : .textSecondary)
                    .lineLimit(nil)
            }
            Text("\(shortTimeFormatter.string(from: prog.start)) - \(shortTimeFormatter.string(from: prog.end))")
                .font(.system(size: 17))
                .foregroundColor(isFocused ? .white.opacity(0.6) : .textTertiary)
            #else
            HStack(spacing: 4) {
                Text(prog.title)
                    .font(.system(size: 12 * guideScale, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                if hasReminder {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9 * guideScale))
                        .foregroundColor(.accentPrimary)
                }
            }
            if !prog.description.isEmpty {
                Text(prog.description)
                    .font(.system(size: 10 * guideScale))
                    .foregroundColor(.textSecondary)
                    .lineLimit(nil)
            }
            Text("\(shortTimeFormatter.string(from: prog.start)) - \(shortTimeFormatter.string(from: prog.end))")
                .font(.system(size: 9 * guideScale))
                .foregroundColor(.textTertiary)
            #endif
        }
        .padding(.leading, 8 + leadingClip)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        // Emby style: full row height, flat rectangle, no rounded corners
        .frame(width: width, height: rowHeight, alignment: .topLeading)
        .background(cellBackground)
        .clipped()
    }

    private var reminderKey: String {
        ReminderManager.programKey(channelName: channelItem.name, title: prog.title, start: prog.start)
    }

    private var isFutureProgram: Bool {
        prog.start > Date()
    }

    /// Whether this program can be recorded (future or currently live).
    private var isRecordable: Bool {
        prog.end > Date()
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
        // NOTE: On tvOS, wrapping the cell in a SwiftUI Button makes the
        // Siri Remote's select-click fire the primary action on release,
        // which swallows .onLongPressGesture — the user reported
        // long-press simply played the channel. Using .focusable() +
        // .onTapGesture + .onLongPressGesture gives us both gestures
        // without the Button eating the press event.
        // SwiftUI's tvOS long-press APIs all fire on press release or
        // are marked unavailable (see Shared/TVPressGesture.swift for
        // the audit). `TVPressOverlay` is a transparent, focusable UIKit
        // overlay whose `pressesBegan` starts a Timer that fires
        // `onLongPress` at exactly 0.35s while still pressed, and whose
        // `pressesEnded` fires `onTap` if the timer hadn't fired yet.
        // The overlay preserves SwiftUI layout because it does not wrap
        // or reparent `cellContent`.
        cellContent
            .overlay(
                TVPressOverlay(
                    minimumPressDuration: 0.35,
                    isFocused: $isFocused,
                    onTap: {
                        // v1.7.x: when the Guide is in staging mode,
                        // Select on a cell adds / removes the channel
                        // from the multiview pile instead of playing
                        // it. The parent's `handleMultiviewIntent`
                        // owns the toggle logic; we just forward the
                        // channel.
                        if multiviewStore.isStagingFromGuide {
                            onMultiviewIntent(channelItem)
                        } else {
                            onSelect(channelItem)
                        }
                    },
                    onLongPress: { showCtxDialog = true }
                )
            )
            .confirmationDialog(prog.title,
                                isPresented: $showCtxDialog,
                                titleVisibility: .visible) {
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
                Button("Program Info") {
                    activeSheet = .programInfo(
                        ProgramInfoTarget(
                            channelName: channelItem.name,
                            title: prog.title,
                            start: prog.start,
                            end: prog.end,
                            description: prog.description,
                            category: prog.category,
                            programID: prog.programID
                        )
                    )
                }
                if isRecordable {
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
                                programID: prog.programID
                            )
                        )
                    }
                }
                if isRecordable {
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
