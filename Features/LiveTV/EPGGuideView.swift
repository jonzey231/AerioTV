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

    /// Computed: the program is currently airing.
    var isLive: Bool {
        let now = Date()
        return start <= now && end > now
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

    private func beginBatch() {
        _isBatching = true
        _pendingPrograms = programs
    }

    private func endBatch() {
        _isBatching = false
        programs = _pendingPrograms
        _pendingPrograms = [:]
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
    func loadFromCache(modelContext: ModelContext, channels: [ChannelDisplayItem], serverID: String) -> Bool {
        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36
        let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)

        let descriptor = FetchDescriptor<EPGProgram>(
            predicate: #Predicate<EPGProgram> {
                $0.serverID == serverID && $0.endTime > windowStart && $0.startTime < windowEnd
            },
            sortBy: [SortDescriptor(\.startTime)]
        )
        guard let cached = try? modelContext.fetch(descriptor), !cached.isEmpty else {
            debugLog("📺 GuideStore.loadFromCache: no cached programs for server \(serverID)")
            return false
        }

        var result: [String: [GuideProgram]] = [:]
        for ep in cached {
            let gp = GuideProgram(channelID: ep.channelID, title: ep.title,
                                  description: ep.programDescription,
                                  start: ep.startTime, end: ep.endTime,
                                  category: ep.category)
            result[ep.channelID, default: []].append(gp)
        }
        programs = result
        debugLog("📺 GuideStore.loadFromCache: loaded \(cached.count) programs across \(result.count) channels (server \(serverID))")

        // Check freshness using the user's refresh interval setting.
        // Default 1440 min (24 hours) — EPG data covers days, no need to refresh hourly.
        let refreshMins = UserDefaults.standard.integer(forKey: "bgRefreshIntervalMins")
        let effectiveMins = refreshMins > 0 ? refreshMins : 1440 // 0 means unset → default 24h
        let stalenessThreshold = TimeInterval(effectiveMins * 60)
        let newestFetch = cached.map(\.fetchedAt).max() ?? .distantPast
        let isFresh = now.timeIntervalSince(newestFetch) < stalenessThreshold
        debugLog("📺 GuideStore.loadFromCache: newest fetch \(Int(now.timeIntervalSince(newestFetch)))s ago, threshold \(Int(stalenessThreshold))s, fresh=\(isFresh)")
        return isFresh
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
                    let ep = EPGProgram(channelID: channelID, title: gp.title,
                                        description: gp.description,
                                        startTime: gp.start, endTime: gp.end,
                                        category: gp.category, serverID: serverID)
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
                if updated { result[ch.id] = list }
            }
        }
        programs = result
    }

    /// Phase 2 — async: fetch upcoming programs to fill in the timeline beyond "now playing."
    /// Loads an initial batch quickly, then backfills remaining channels at lower priority.
    func fetchUpcoming(channels: [ChannelDisplayItem], servers: [ServerConnection]) async {
        guard !isLoading else {
            debugLog("📺 GuideStore.fetchUpcoming: already loading, skipping")
            return
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
            return  // `defer` above resets isLoading
        }
        debugLog("📺 GuideStore.fetchUpcoming: server=\(server.name), type=\(server.type), channels=\(channels.count)")

        switch server.type {
        case .dispatcharrAPI:
            // Dispatcharr: bulk fetch ALL programs at once (no batching needed).
            // getCurrentPrograms + getBulkUpcomingPrograms handles everything.
            await fetchDispatcharr(server: server, channels: channels,
                                   windowStart: windowStart, windowEnd: windowEnd)
        case .xtreamCodes:
            // Xtream: still need per-channel fetching with batches
            let initialBatchSize = 40
            let initialChannels = Array(channels.prefix(initialBatchSize))
            let remainingChannels = channels.count > initialBatchSize ? Array(channels.suffix(from: initialBatchSize)) : []

            await fetchXtream(server: server, channels: initialChannels,
                              windowStart: windowStart, windowEnd: windowEnd)

            // Phase 2: backfill remaining Xtream channels
            if !remainingChannels.isEmpty {
                let batchSize = 20
                for batchStart in stride(from: 0, to: remainingChannels.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, remainingChannels.count)
                    let batch = Array(remainingChannels[batchStart..<batchEnd])
                    await fetchXtream(server: server, channels: batch,
                                      windowStart: windowStart, windowEnd: windowEnd)
                    await Task.yield()
                }
            }
        case .m3uPlaylist:
            await fetchXMLTV(server: server, channels: channels,
                             windowStart: windowStart, windowEnd: windowEnd)
        }

        // Log final state
        let totalPrograms = programs.values.reduce(0) { $0 + $1.count }
        let channelsWithMultiple = programs.values.filter { $0.count > 1 }.count
        debugLog("📺 GuideStore done: \(totalPrograms) programs across \(programs.count) channels, \(channelsWithMultiple) channels have >1 program")
    }

    // MARK: - Dispatcharr
    private func fetchDispatcharr(server: ServerConnection, channels: [ChannelDisplayItem],
                                   windowStart: Date, windowEnd: Date) async {
        // Prefer Dispatcharr's XMLTV output endpoint over the JSON REST
        // API. The `/api/epg/*` endpoints strip category data, but
        // `{baseURL}/output/epg` re-emits the upstream XMLTV including
        // `<category>` tags — see `apps/output/views.py`'s
        // `generate_epg()`. This is also what third-party clients like
        // Emby / Jellyfin consume, so it's the canonical "give me my
        // guide data" URL. The user's explicit override wins when set
        // (some setups need a different XMLTV source or auth token).
        //
        // NOTE: handled before beginBatch() to avoid nested batch sessions —
        // fetchXMLTVFromURL manages its own begin/endBatch pair.
        let explicitURL = server.dispatcharrXMLTVURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = server.effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedOutputURL: String? = {
            guard !base.isEmpty else { return nil }
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            // Append `?tvg_id_source=tvg_id` so Dispatcharr emits the
            // <channel id="..."> + <programme channel="..."> attributes
            // using each channel's tvg_id. Without this, Dispatcharr
            // defaults to the channel NUMBER, which is effectively
            // random for our tvg_id-keyed channel matching. See
            // Dispatcharr's apps/output/views.py `generate_epg()`:
            //
            //   if tvg_id_source == 'tvg_id' and channel.tvg_id:
            //       channel_id = channel.tvg_id
            //   else:
            //       channel_id = str(formatted_channel_number)
            return "\(trimmed)/output/epg?tvg_id_source=tvg_id"
        }()
        if let xmltvURL = (explicitURL.isEmpty ? derivedOutputURL : explicitURL),
           let parsedURL = URL(string: xmltvURL) {
            debugLog("📺 [EPG source=xmltv-direct source=\(explicitURL.isEmpty ? "dispatcharr-output" : "custom-override")] server=\(server.name) url=\(parsedURL.host ?? "?")")
            await fetchXMLTVFromURL(url: parsedURL, channels: channels,
                                     windowStart: windowStart, windowEnd: windowEnd)
            return
        }
        debugLog("📺 [EPG source=dispatcharr-api fallback] server=\(server.name) (could not build XMLTV URL)")

        beginBatch()
        defer { endBatch() }
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                  auth: .apiKey(server.effectiveApiKey))

        // Build tvgID ↔ channelID mapping (case-insensitive keys for matching)
        let tvgIDToChannelID: [String: String] = Dictionary(
            channels.compactMap { ch in
                guard let tvg = ch.tvgID, !tvg.isEmpty else { return nil }
                return (tvg.lowercased(), ch.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
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
                let gp = GuideProgram(channelID: cid, title: prog.title,
                                      description: desc, start: start, end: end, category: "")
                mergeProgram(gp, for: cid)
            }
            #if DEBUG
            debugLog("📺 Dispatcharr: EPG grid matched \(matched) programs to channels (\(matchedViaUUID) via Dummy EPG UUID key)")
            #endif
            return // Grid endpoint succeeded — no need for fallback
        } catch {
            #if DEBUG
            debugLog("📺 Dispatcharr: EPG grid failed (\(error)), falling back to current+bulk approach")
            #endif
        }

        // Fallback: getCurrentPrograms + getBulkUpcomingPrograms (for older Dispatcharr versions
        // that may not have the /api/epg/grid/ endpoint)
        if let current = try? await api.getCurrentPrograms() {
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
                                      description: desc, start: start, end: end, category: "")
                mergeProgram(gp, for: cid)
            }
        }

        // Bulk fetch upcoming programs as supplement
        if let allPrograms = try? await api.getBulkUpcomingPrograms(maxPages: 10) {
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
                                      description: desc, start: start, end: end, category: "")
                mergeProgram(gp, for: cid)
            }
        }
    }

    // MARK: - Xtream Codes
    private func fetchXtream(server: ServerConnection, channels: [ChannelDisplayItem],
                              windowStart: Date, windowEnd: Date) async {
        beginBatch()
        defer { endBatch() }
        let api = XtreamCodesAPI(baseURL: server.effectiveBaseURL,
                                  username: server.username,
                                  password: server.effectivePassword)

        // Fetch with limited concurrency (max 3 concurrent) and 15s timeout per request
        await withTaskGroup(of: (String, [GuideProgram]).self) { group in
            let maxConcurrent = 3
            var launched = 0

            for ch in channels {
                if launched >= maxConcurrent {
                    if let (channelID, progs) = await group.next() {
                        for p in progs { mergeProgram(p, for: channelID) }
                    }
                }
                launched += 1

                group.addTask { [api] in
                    let progs: [GuideProgram] = await withTaskGroup(of: [GuideProgram].self) { inner in
                        inner.addTask {
                            let response = try? await api.getEPG(streamID: ch.id, limit: 12)
                            return (response?.epgListings ?? []).compactMap { item in
                                guard let start = Self.parseXtreamDate(item.start),
                                      let end = Self.parseXtreamDate(item.end),
                                      end > windowStart && start < windowEnd else { return nil }
                                return GuideProgram(channelID: ch.id, title: item.title,
                                                    description: item.description,
                                                    start: start, end: end, category: "")
                            }
                        }
                        inner.addTask {
                            try? await Task.sleep(nanoseconds: 15_000_000_000)
                            return []
                        }
                        let result = await inner.next() ?? []
                        inner.cancelAll()
                        return result
                    }
                    return (ch.id, progs)
                }
            }

            for await (channelID, progs) in group {
                for p in progs { mergeProgram(p, for: channelID) }
            }
        }
    }

    // MARK: - M3U + XMLTV
    private func fetchXMLTV(server: ServerConnection, channels: [ChannelDisplayItem],
                             windowStart: Date, windowEnd: Date) async {
        let epgURLStr = server.effectiveEPGURL
        guard !epgURLStr.isEmpty, let epgURL = URL(string: epgURLStr) else { return }
        await fetchXMLTVFromURL(url: epgURL, channels: channels,
                                 windowStart: windowStart, windowEnd: windowEnd)
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
    func fetchXMLTVFromURL(url: URL, channels: [ChannelDisplayItem],
                                    windowStart: Date, windowEnd: Date) async {
        guard let parsed = try? await XMLTVParser.fetchAndParse(url: url) else {
            debugLog("📺 XMLTV fetch/parse failed for \(url.host ?? "?")")
            return
        }
        beginBatch()
        defer { endBatch() }

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

        var matched = 0
        var missed = 0
        // Collect currently-airing categories keyed by channel id so we
        // can push them back to ChannelStore after the loop — that makes
        // the Live TV list view's "Tint Channel Cards" stripe work off
        // the same XMLTV source as the guide itself.
        let now = Date()
        var currentCategoriesByChannelID: [String: String] = [:]
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
            mergeProgram(gp, for: cid)
            // Track the currently-airing program per channel.
            if !prog.category.isEmpty, prog.startTime <= now, prog.endTime > now {
                currentCategoriesByChannelID[cid] = prog.category
            }
        }
        debugLog("📺 XMLTV \(url.host ?? "?"): \(matched) programs matched, \(missed) skipped (no channel)")
        // Back-fill ChannelStore so Tint Channel Cards reflects the
        // XMLTV categories on every channel row.
        ChannelStore.shared.applyXMLTVCategories(currentCategoriesByChannelID)
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

    /// Called by the outer Guide task after a bulk re-fetch or a
    /// pull-to-refresh so that subsequent per-cell `.onAppear`
    /// handlers are free to re-check. Without this, channels that
    /// were fetched during the previous session's scroll remain
    /// flagged and the per-channel prefetch never retries — even
    /// when the bulk fetch has since populated data.
    func resetPrefetchCache() {
        fetchedChannelIDs.removeAll(keepingCapacity: true)
    }

    /// Called when a guide row appears on screen. Fetches EPG for
    /// this channel if not already loaded AND the bulk fetch didn't
    /// already populate its future programs.
    func prefetchIfNeeded(channel: ChannelDisplayItem, servers: [ServerConnection]) {
        guard !fetchedChannelIDs.contains(channel.id) else { return }

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
        let username = server.username
        let password = server.effectivePassword
        let channelID = channel.id
        let tvgID = channel.tvgID

        Task {
            // Fetch programs with a 15-second timeout
            let fetched: [GuideProgram] = await withTaskGroup(of: [GuideProgram].self) { group in
                group.addTask {
                    switch serverType {
                    case .dispatcharrAPI:
                        let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))
                        let hasTvgID = tvgID != nil && !tvgID!.isEmpty
                        let chID = Int(channelID)
                        guard hasTvgID || chID != nil else { return [] }
                        let upcoming = (try? await api.getUpcomingPrograms(
                            tvgIDs: hasTvgID ? [tvgID!] : nil,
                            channelIDs: hasTvgID ? nil : (chID.map { [$0] })
                        )) ?? []
                        return upcoming.compactMap { prog in
                            guard let start = prog.startTime?.toDate(),
                                  let end = prog.endTime?.toDate(),
                                  end > windowStart && start < windowEnd else { return nil }
                            let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                            return GuideProgram(channelID: channelID, title: prog.title,
                                                description: desc, start: start, end: end, category: "")
                        }
                    case .xtreamCodes:
                        let api = XtreamCodesAPI(baseURL: baseURL, username: username, password: password)
                        let response = try? await api.getEPG(streamID: channelID, limit: 12)
                        return (response?.epgListings ?? []).compactMap { item in
                            guard let start = Self.parseXtreamDate(item.start),
                                  let end = Self.parseXtreamDate(item.end),
                                  end > windowStart && start < windowEnd else { return nil }
                            return GuideProgram(channelID: channelID, title: item.title,
                                                description: item.description,
                                                start: start, end: end, category: "")
                        }
                    case .m3uPlaylist:
                        return []
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return []
                }
                let result = await group.next() ?? []
                group.cancelAll()
                return result
            }
            // Merge results back on main actor
            for prog in fetched {
                mergeProgram(prog, for: channelID)
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
        }
    }

    // MARK: - Merge Helper
    /// Adds a program to the store, avoiding duplicates, and keeps sorted by start time.
    private func mergeProgram(_ prog: GuideProgram, for channelID: String) {
        let target = _isBatching ? _pendingPrograms : programs
        var list = target[channelID] ?? []
        // Check for duplicate: same title+time or >80% overlap
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
            // Duplicate found — always replace if the new version has a longer description
            // (e.g., seedFromChannels created a placeholder without description,
            // then fetchUpcoming returned the same program with a description).
            if prog.description.count > list[idx].description.count {
                list[idx] = prog
                if _isBatching { _pendingPrograms[channelID] = list }
                else { programs[channelID] = list }
            }
            return
        }
        list.append(prog)
        list.sort { $0.start < $1.start }
        if _isBatching {
            _pendingPrograms[channelID] = list
        } else {
            programs[channelID] = list
        }
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
    @EnvironmentObject private var channelStore: ChannelStore
    @Environment(\.modelContext) private var modelContext
    @State private var _epgCacheIsFresh = false
    #if os(tvOS)
    /// Programmatic focus target for a channel row's left-hand cell.
    /// Normally nil (focus engine drives navigation).
    @FocusState private var focusedChannelID: String?
    /// Programmatic focus target for a specific program cell. Used
    /// by `.forceGuideFocus` to land focus on the currently-playing
    /// program of the first channel after the single-stream player
    /// minimizes — without this, tvOS's spatial search from the
    /// top-right mini position lands on a program 2–3 hours in the
    /// future (because that's what's directly below the mini).
    /// Setting this to a program's id claims focus on that cell.
    // NOTE: `@FocusState private var focusedProgramID: String?` was
    // removed alongside the `.focused(...)` binding on each program
    // cell. Both formed a redundant focus-routing channel that
    // created two competing focus targets per cell
    // (`TVPressOverlay`'s `PressCatcherView` + the SwiftUI
    // `.focused` binding), which manifested as specific program
    // cells being permanently unreachable via Siri Remote D-pad.
    // See `programCell(_:channelItem:nextProgramStart:)` for the
    // full diagnosis and rationale.

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
        }
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
            let cacheIsFresh = guideStore.loadFromCache(modelContext: modelContext, channels: channels, serverID: activeServerID)
            // Phase 1: seed from current-program data on channels (fills gaps)
            guideStore.seedFromChannels(channels)
            // Seed EPGCache so List-view card expansion is instant
            await guideStore.seedEPGCache(channels: channels, server: activeServer)

            // Phase 2: fetch from network only if cache is stale.
            // Also fetch if the cache has no future programs (e.g., fresh install with only
            // seedFromChannels data — only current programs, nothing upcoming).
            let hasFuturePrograms = guideStore.programs.values
                .flatMap { $0 }
                .contains { $0.end > Date().addingTimeInterval(1800) }
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
                        ForEach(channels) { channel in
                            guideRow(for: channel, screenWidth: geo.size.width)
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
                // Reclaim focus from the minimized mini-player via
                // Apple's imperative focus-reset API. See
                // ChannelListView's `.forceGuideFocus` handler for
                // the full rationale — briefly: a plain
                // `@FocusState` write (what this handler did
                // pre-v1.6.4) was treated by tvOS as a focus
                // REQUEST that the engine routinely rejected
                // because it had already committed to the mini
                // tile by the time the write landed. Calling
                // `resetFocus(in:)` forces tvOS to re-evaluate
                // focus within the scope and lands on the row
                // carrying `.prefersDefaultFocus(true, in:)` —
                // which is the top channel row.
                //
                // The 400ms delay covers the 350ms minimize spring
                // animation; triggering during the animation lets
                // tvOS ignore the reset because the mini tile's
                // frame is still in flux.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
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
    // entirely. Specifically reported: NHL Hockey on ESPN HD
    // (3:00–5:30, overlapping the channel column) was unfocusable on
    // tvOS while College Softball on ESPN2 HD (3:00–5:00, same clamped
    // start and offset) worked — likely due to subtle differences in
    // how tvOS samples focus regions across rows in the section.
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
    private func guideRow(for channel: ChannelDisplayItem, screenWidth: CGFloat) -> some View {
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
                // Mark the top row as the default-focus target so
                // `resetFocus(in: guideFocusNS)` lands here. See
                // the `.forceGuideFocus` handler on the outer
                // ScrollView for the full rationale.
                .prefersDefaultFocus(channel.id == channels.first?.id, in: guideFocusNS)
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
            shortTimeFormatter: shortTimeFormatter, onSelect: onSelectChannel
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
        // inconsistently, skipping some cells entirely (reported:
        // NHL Hockey Eastern on ESPN HD, 2026 NFL Draft Rankings:
        // Offense and Chris Simms Unbuttoned on NBC Sports NOW).
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
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundColor(.textTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 38, alignment: .trailing)

            VStack(spacing: 4) {
                if let logo = channel.logoURL {
                    AsyncImage(url: logo) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 72, height: 48)
                        default:
                            guidePlaceholder
                        }
                    }
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
            if let logo = channel.logoURL {
                AsyncImage(url: logo) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 28)
                    default:
                        guidePlaceholder
                    }
                }
            } else {
                guidePlaceholder
            }
            VStack(spacing: 1) {
                Text(channel.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                Text(channel.number)
                    .font(.system(size: 8))
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
    // Access ReminderManager directly — @ObservedObject on a singleton
    // would invalidate every program cell whenever any reminder changes.
    private var reminderManager: ReminderManager { .shared }
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

    @State private var showRecordSheet = false
    #if os(tvOS)
    // tvOS uses a confirmationDialog instead of .contextMenu because SwiftUI's
    // .contextMenu on tvOS rebuilds its UIMenu items every time the backing
    // cell re-renders, which visibly flashes the highlighted item. The dialog
    // route is a self-contained modal that is not re-evaluated from cell
    // updates, so the highlight stays stable.
    @State private var showCtxDialog = false
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
                    onTap: { onSelect(channelItem) },
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
                if isRecordable {
                    Button(prog.isLive ? "Record from Now" : "Record") {
                        showRecordSheet = true
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
            // tvOS: .sheet presents a small centred modal that cramps the
            // Form rows and clips focus halos. Use .fullScreenCover so the
            // record form gets real estate comparable to the rest of the
            // app's tvOS UI.
            .fullScreenCover(isPresented: $showRecordSheet) {
                RecordProgramSheet(
                    programTitle: prog.title,
                    programDescription: prog.description,
                    channelID: channelItem.id,
                    channelName: channelItem.name,
                    scheduledStart: prog.start,
                    scheduledEnd: prog.end,
                    isLive: prog.isLive
                )
            }
        #else
        cellContent
            .contentShape(Rectangle())
            .onTapGesture { onSelect(channelItem) }
            // `.contextMenu(menuItems:preview:)` — the preview form is
            // REQUIRED here. Program cells are sized to the
            // program's on-guide duration (often hundreds of pixels
            // wide for a 90-minute show), which made the default
            // auto-generated preview enormous; iOS couldn't fit it
            // next to the touch and anchored the whole menu at the
            // screen bottom instead. Supplying a compact 320-pt
            // preview lets the system place the menu right next to
            // the user's finger, which is what #23 asked for.
            .contextMenu(menuItems: {
                // Favorite toggle — same action as long-pressing the
                // channel column on the left. Placed first so users
                // can manage favorites without hunting for the
                // narrow channel cell.
                Button {
                    favoritesStore.toggle(channelItem)
                } label: {
                    if favoritesStore.isFavorite(channelItem.id) {
                        Label("Remove from Favorites", systemImage: "star.slash")
                    } else {
                        Label("Add to Favorites", systemImage: "star")
                    }
                }
                if isRecordable {
                    Button {
                        showRecordSheet = true
                    } label: {
                        Label(prog.isLive ? "Record from Now" : "Record", systemImage: "record.circle")
                    }
                }
                if isFutureProgram {
                    if reminderManager.hasReminder(forKey: reminderKey) {
                        Button(role: .destructive) {
                            reminderManager.cancelReminder(forKey: reminderKey)
                        } label: {
                            Label("Cancel Reminder", systemImage: "bell.slash")
                        }
                    } else {
                        Button {
                            reminderManager.scheduleReminder(
                                programTitle: prog.title,
                                channelName: channelItem.name,
                                startTime: prog.start
                            )
                        } label: {
                            Label("Set Reminder", systemImage: "bell")
                        }
                    }
                }
            }, preview: {
                programPreviewCard
            })
            .sheet(isPresented: $showRecordSheet) {
                RecordProgramSheet(
                    programTitle: prog.title,
                    programDescription: prog.description,
                    channelID: channelItem.id,
                    channelName: channelItem.name,
                    scheduledStart: prog.start,
                    scheduledEnd: prog.end,
                    isLive: prog.isLive
                )
            }
        #endif
    }

    #if !os(tvOS)
    /// Compact preview card used by `.contextMenu(menuItems:preview:)`
    /// so the iOS system can anchor the long-press menu next to the
    /// finger. Sized small enough (320 pt wide, 2-line title, 4-line
    /// description) that iOS never has to punt the menu to the screen
    /// bottom — which was the symptom user Veldmuus called out in #23.
    private var programPreviewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text("\(shortTimeFormatter.string(from: prog.start)) – \(shortTimeFormatter.string(from: prog.end))")
                .font(.system(size: 12))
                .foregroundColor(.textTertiary)

            if !prog.description.isEmpty {
                Text(prog.description)
                    .font(.system(size: 13))
                    .foregroundColor(.textSecondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(Color.cardBackground)
    }
    #endif

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
