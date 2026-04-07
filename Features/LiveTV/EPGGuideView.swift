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
    func loadFromCache(modelContext: ModelContext, channels: [ChannelDisplayItem]) -> Bool {
        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36
        let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)

        let descriptor = FetchDescriptor<EPGProgram>(
            predicate: #Predicate<EPGProgram> { $0.endTime > windowStart && $0.startTime < windowEnd },
            sortBy: [SortDescriptor(\.startTime)]
        )
        guard let cached = try? modelContext.fetch(descriptor), !cached.isEmpty else {
            debugLog("📺 GuideStore.loadFromCache: no cached programs")
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
        debugLog("📺 GuideStore.loadFromCache: loaded \(cached.count) programs across \(result.count) channels")

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
    func saveToCache(modelContext: ModelContext, serverID: String) {
        let now = Date()
        let hourAgo = now.addingTimeInterval(-3600)

        // Delete stale programs (ended > 1 hour ago)
        let staleDescriptor = FetchDescriptor<EPGProgram>(
            predicate: #Predicate<EPGProgram> { $0.endTime < hourAgo }
        )
        if let stale = try? modelContext.fetch(staleDescriptor) {
            for s in stale { modelContext.delete(s) }
        }

        // Delete existing programs for this server in the current window
        // to avoid duplicates on re-fetch
        let windowStart = now.addingTimeInterval(-3600)
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36
        let windowEnd = now.addingTimeInterval(Double(max(effectiveWindowHours, 24)) * 3600)
        let existingDescriptor = FetchDescriptor<EPGProgram>(
            predicate: #Predicate<EPGProgram> {
                $0.serverID == serverID && $0.endTime > windowStart && $0.startTime < windowEnd
            }
        )
        if let existing = try? modelContext.fetch(existingDescriptor) {
            for e in existing { modelContext.delete(e) }
        }

        // Insert current programs
        var count = 0
        for (channelID, progs) in programs {
            for gp in progs {
                let ep = EPGProgram(channelID: channelID, title: gp.title,
                                    description: gp.description,
                                    startTime: gp.start, endTime: gp.end,
                                    category: gp.category, serverID: serverID)
                modelContext.insert(ep)
                count += 1
            }
        }
        try? modelContext.save()
        debugLog("📺 GuideStore.saveToCache: saved \(count) programs for server \(serverID)")
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

        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        // Use the user's EPG window setting (default 36 hours).
        // 0 means "All available" — use 14 days as a practical maximum.
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36
        let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)

        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else {
            debugLog("📺 GuideStore.fetchUpcoming: no server found")
            isLoading = false
            return
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

        // Try the EPG grid endpoint first — returns -1h to +24h in one request with
        // synthetic dummy programs for channels without EPG data.
        #if DEBUG
        debugLog("📺 Dispatcharr: fetching EPG grid, tvgID map has \(tvgIDToChannelID.count) entries, intID map has \(intIDToChannelID.count) entries")
        #endif
        do {
            let gridPrograms = try await api.getEPGGrid()
            #if DEBUG
            debugLog("📺 Dispatcharr: EPG grid returned \(gridPrograms.count) programs")
            #endif
            var matched = 0
            for prog in gridPrograms {
                guard let start = prog.startTime?.toDate(),
                      let end = prog.endTime?.toDate(),
                      end > windowStart && start < windowEnd else { continue }
                let channelID: String?
                if let tvg = prog.tvgID, !tvg.isEmpty {
                    channelID = tvgIDToChannelID[tvg.lowercased()]
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
            debugLog("📺 Dispatcharr: EPG grid matched \(matched) programs to channels")
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
                    channelID = tvgIDToChannelID[tvg.lowercased()]
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
                    channelID = tvgIDToChannelID[tvg.lowercased()]
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
        guard let parsed = try? await XMLTVParser.fetchAndParse(url: epgURL) else { return }
        beginBatch()
        defer { endBatch() }

        let tvgIDToChannelID: [String: String] = Dictionary(
            channels.compactMap { ch in
                guard let tvg = ch.tvgID, !tvg.isEmpty else { return nil }
                return (tvg, ch.id)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for prog in parsed {
            guard prog.endTime > windowStart && prog.startTime < windowEnd,
                  let channelID = tvgIDToChannelID[prog.channelID] else { continue }
            let gp = GuideProgram(channelID: channelID, title: prog.title,
                                  description: prog.description,
                                  start: prog.startTime, end: prog.endTime,
                                  category: prog.category)
            mergeProgram(gp, for: channelID)
        }
    }

    // MARK: - Rolling Prefetch
    /// Tracks which channel IDs have already been fetched to avoid duplicate requests.
    private var fetchedChannelIDs: Set<String> = []

    /// Called when a guide row appears on screen. Fetches EPG for this channel
    /// (and the next ~20) if not already loaded.
    func prefetchIfNeeded(channel: ChannelDisplayItem, servers: [ServerConnection]) {
        guard !fetchedChannelIDs.contains(channel.id) else { return }
        fetchedChannelIDs.insert(channel.id)

        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else { return }
        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        let windowEnd   = now.addingTimeInterval(3 * 3600)

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
    func seedEPGCache(channels: [ChannelDisplayItem], server: ServerConnection?) {
        guard let server else { return }
        let now = Date()
        let baseURL = server.effectiveBaseURL
        for ch in channels {
            let tvgID = ch.tvgID ?? ""
            let cacheKey: String
            switch server.type {
            case .dispatcharrAPI:
                cacheKey = "d_\(baseURL)_\(tvgID.isEmpty ? ch.id : tvgID)"
            case .xtreamCodes:
                cacheKey = "x_\(baseURL)_\(ch.id)"
            case .m3uPlaylist:
                guard !tvgID.isEmpty else { continue }
                cacheKey = "m3u_\(tvgID)"
            }
            guard let progs = programs[ch.id], !progs.isEmpty else { continue }
            let entries = progs
                .filter { $0.end > now }
                .sorted { $0.start < $1.start }
                .map { EPGEntry(title: $0.title, description: $0.description, startTime: $0.start, endTime: $0.end) }
            guard !entries.isEmpty else { continue }
            Task {
                await EPGCache.shared.set(entries, for: cacheKey)
            }
        }
        debugLog("📺 GuideStore.seedEPGCache: seeded EPGCache for \(channels.count) channels")
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

    @StateObject private var guideStore = GuideStore()
    @EnvironmentObject private var channelStore: ChannelStore
    @Environment(\.modelContext) private var modelContext
    @State private var _epgCacheIsFresh = false

    // Time window: 4 hours (1h back + 3h forward)
    private let hoursBack: TimeInterval = 1
    private let hoursForward: TimeInterval = 3
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
    private let channelColumnWidth: CGFloat = 100
    private let rowHeight: CGFloat = 72
    private let timeHeaderHeight: CGFloat = 32
    private let pixelsPerHour: CGFloat = 360
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
            let activeServer = servers.first(where: { $0.isActive }) ?? servers.first

            // Phase 0: load from persistent SwiftData cache
            let cacheIsFresh = guideStore.loadFromCache(modelContext: modelContext, channels: channels)
            // Phase 1: seed from current-program data on channels (fills gaps)
            guideStore.seedFromChannels(channels)
            // Seed EPGCache so List-view card expansion is instant
            guideStore.seedEPGCache(channels: channels, server: activeServer)

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
            guideStore.seedEPGCache(channels: channels, server: activeServer)
            channelStore.isEPGLoading = false
        }
        // When MainTabView's loadAllEPG() finishes, re-seed guide from EPGCache
        .onChange(of: channelStore.isEPGLoading) { wasLoading, isLoading in
            if wasLoading && !isLoading && !channels.isEmpty {
                let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                guideStore.seedFromChannels(channels)
                guideStore.seedEPGCache(channels: channels, server: activeServer)
            }
        }
        // Timer removed — time indicator redraws via TimelineView
    }

    // MARK: - Horizontal Scroll State
    // Manual horizontal offset — only changes when user explicitly scrolls (drag/swipe).
    // Focus changes do NOT cause horizontal movement.
    // Initial value positions "now" at the left edge of the visible area.
    // Initial value positions "now" at the left edge of the visible area.
    #if os(tvOS)
    @State private var horizontalOffset: CGFloat = -600  // -(hoursBack=1 * pixelsPerHour=600)
    #else
    @State private var horizontalOffset: CGFloat = -360  // -(hoursBack=1 * pixelsPerHour=360)
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
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: rowGap, pinnedViews: [.sectionHeaders]) {
                    Section {
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
            .overlay {
                HorizontalPanGestureView(
                    offset: $horizontalOffset,
                    minOffset: maxHorizontalOffset
                )
            }
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
        }
    }

    // MARK: - Guide Row (single channel)
    private func guideRow(for channel: ChannelDisplayItem, screenWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Program blocks — positioned right of channel column
            programRow(for: channel)
                .frame(width: totalGridWidth, height: rowHeight)
                .offset(x: channelColumnWidth + horizontalOffset)
                // Clip only the right edge using a frame that extends far left
                // but constrains the right side to the screen width.
                // This allows focused cells to overflow left over the channel column.

            // Channel logo + name — pinned to left edge, drawn on top of unfocused programs
            channelCell(for: channel)
                .frame(width: channelColumnWidth, height: rowHeight)
                .background(Color.cardBackground)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.accentPrimary.opacity(0.2)).frame(width: 1)
                }
                .zIndex(0.5) // above unfocused programs (zIndex 0), below focused (zIndex 1)
        }
        .frame(width: screenWidth, height: rowHeight, alignment: .leading)
        .clipped() // clip right edge only — focused cells overflow vertically via row spacing
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
                    Text(timeFormatter.string(from: date).lowercased())
                        .font(.system(size: 10, weight: .medium))
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

    var body: some View {
        #if os(tvOS)
        // Non-focusable label on tvOS — users select program cells to play.
        // This prevents focus from jumping to the channel column when scrolling down.
        channelLabel
        #else
        channelLabel
            .contentShape(Rectangle())
            .onTapGesture { onSelect(channel) }
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
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    private var cellContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            #if os(tvOS)
            Text(prog.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(isFocused ? .white : .textPrimary)
                .lineLimit(1)
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
            Text(prog.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
            if !prog.description.isEmpty {
                Text(prog.description)
                    .font(.system(size: 10))
                    .foregroundColor(.textSecondary)
                    .lineLimit(nil)
            }
            Text("\(shortTimeFormatter.string(from: prog.start)) - \(shortTimeFormatter.string(from: prog.end))")
                .font(.system(size: 9))
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

    var body: some View {
        #if os(tvOS)
        Button { onSelect(channelItem) } label: { cellContent }
            .buttonStyle(GuideButtonStyle())
            .focused($isFocused)
            .contextMenu {
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
            }
        #else
        cellContent
            .contentShape(Rectangle())
            .onTapGesture { onSelect(channelItem) }
            .contextMenu {
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
            }
        #endif
    }

    #if os(tvOS)
    /// Emby-style colors: focused = bright highlight, live = lighter gray, future = dark
    private var cellBackground: Color {
        if isFocused { return Color.white.opacity(0.25) }
        if prog.isLive { return Color.white.opacity(0.12) }
        return Color.white.opacity(0.05)
    }
    #else
    private var cellBackground: Color {
        prog.isLive ? Color.accentPrimary.opacity(0.25) : Color.cardBackground
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

// MARK: - iOS Horizontal Pan Gesture (UIKit bridge)
// SwiftUI's DragGesture doesn't coexist with ScrollView's UIScrollView pan recognizer.
// This UIViewRepresentable adds a UIPanGestureRecognizer that only fires for horizontal
// pans and is configured to work simultaneously with the scroll view.
#if os(iOS)
private struct HorizontalPanGestureView: UIViewRepresentable {
    @Binding var offset: CGFloat
    let minOffset: CGFloat

    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {
        context.coordinator.minOffset = minOffset
    }

    /// UIView that passes through all touches to views behind it,
    /// while still allowing its gesture recognizers to fire.
    final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Return nil so touches pass through to the ScrollView underneath.
            // The pan gesture recognizer still fires because it's attached to this view
            // and UIKit evaluates gesture recognizers before hitTest routing.
            return nil
        }
    }


    func makeCoordinator() -> Coordinator {
        Coordinator(offset: $offset, minOffset: minOffset)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        @Binding var offset: CGFloat
        var minOffset: CGFloat
        private var startOffset: CGFloat = 0

        init(offset: Binding<CGFloat>, minOffset: CGFloat) {
            _offset = offset
            self.minOffset = minOffset
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                startOffset = offset
            case .changed:
                offset = min(0, max(minOffset, startOffset + translation.x))
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: gesture.view).x
                let projected = offset + velocity * 0.15
                withAnimation(.easeOut(duration: 0.25)) {
                    offset = min(0, max(minOffset, projected))
                }
            default: break
            }
        }

        // Only begin for primarily horizontal pans.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        // Allow ScrollView's vertical scroll to work simultaneously.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
#endif
