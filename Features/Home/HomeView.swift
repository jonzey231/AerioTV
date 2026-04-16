import SwiftUI
import SwiftData
import Foundation
import Security

// MARK: - VOD Store
// Shared ObservableObject owned by MainTabView.
// Pre-fetches movies and series as soon as VOD servers are available,
// and re-fetches whenever the server list changes so Movies/Series tabs
// stay current without waiting for the user to switch to them.
@MainActor
final class VODStore: ObservableObject {

    @Published private(set) var movies: [VODDisplayItem] = []
    @Published private(set) var movieCategories: [VODCategory] = []
    @Published private(set) var isLoadingMovies = false
    @Published private(set) var moviesError: String?

    @Published private(set) var series: [VODDisplayItem] = []
    @Published private(set) var seriesCategories: [VODCategory] = []
    @Published private(set) var isLoadingSeries = false
    @Published private(set) var seriesError: String?

    /// Server name last used for movies — shown in error/empty state for diagnosis.
    @Published private(set) var lastMoviesServerName: String?
    /// Server name last used for series — shown in error/empty state for diagnosis.
    @Published private(set) var lastSeriesServerName: String?

    private var moviesTask: Task<Void, Never>?
    private var seriesTask: Task<Void, Never>?

    /// The server ID whose movies are currently loaded — used to detect server switches.
    private var currentMoviesServerID: UUID? = nil
    /// The server ID whose series are currently loaded — used to detect server switches.
    private var currentSeriesServerID: UUID? = nil

    /// Server-side search results (supplements locally-loaded items when library isn't fully fetched).
    @Published private(set) var movieSearchResults: [VODDisplayItem] = []
    @Published private(set) var isSearchingMovies = false
    @Published private(set) var seriesSearchResults: [VODDisplayItem] = []
    @Published private(set) var isSearchingSeries = false

    private var movieSearchTask: Task<Void, Never>?
    private var seriesSearchTask: Task<Void, Never>?

    /// Resolves a poster URL string that may be absolute or relative.
    /// Dispatcharr commonly returns relative paths like "/media/posters/xxx.jpg".
    private func resolveURL(_ raw: String, base: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        // Relative path — prepend server base URL.
        let separator = raw.hasPrefix("/") ? "" : "/"
        return URL(string: base + separator + raw)
    }

    func refresh(servers: [ServerConnection]) {
        refreshMovies(servers: servers)
        refreshSeries(servers: servers)
    }

    func refreshMovies(servers: [ServerConnection]) {
        moviesTask?.cancel()
        moviesTask = Task { await loadMovies(servers: servers) }
    }

    func refreshSeries(servers: [ServerConnection]) {
        seriesTask?.cancel()
        seriesTask = Task { await loadSeries(servers: servers) }
    }

    func searchMovies(query: String, servers: [ServerConnection]) {
        movieSearchTask?.cancel()
        guard !query.isEmpty else {
            movieSearchResults = []
            isSearchingMovies = false
            return
        }
        let vodServers = servers.filter { $0.supportsVOD && $0.type == .dispatcharrAPI }
        guard let server = vodServers.first(where: { $0.isActive }) ?? vodServers.first else { return }
        let baseURL = server.effectiveBaseURL
        let apiKey  = server.effectiveApiKey
        let sID     = server.id
        isSearchingMovies = true
        movieSearchTask = Task {
            let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))
            var results: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 0.5
            do {
                for try await batch in api.searchVODMoviesStream(query: query) {
                    guard !Task.isCancelled else { break }
                    let items = batch.map { m -> VODDisplayItem in
                        let movie = VODMovie(
                            id: String(m.id), name: m.title,
                            posterURL: m.posterURL.flatMap { resolveURL($0, base: baseURL) },
                            backdropURL: nil,
                            rating: m.rating ?? "", plot: m.plot ?? "",
                            genre: m.genre ?? "", releaseDate: "", duration: "",
                            cast: "", director: "", imdbID: "",
                            categoryID: "", categoryName: "Movies",
                            streamURL: api.proxyMovieURL(uuid: m.uuid,
                                                         preferredStreamID: m.streams?.first?.streamID),
                            containerExtension: "mp4", serverID: sID
                        )
                        return VODDisplayItem(movie: movie)
                    }
                    results += items
                    let now = Date()
                    if now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        movieSearchResults = results
                        lastPublishTime = now
                    }
                }
            } catch {}
            if !Task.isCancelled {
                movieSearchResults = results
                isSearchingMovies = false
            }
        }
    }

    func searchSeries(query: String, servers: [ServerConnection]) {
        seriesSearchTask?.cancel()
        guard !query.isEmpty else {
            seriesSearchResults = []
            isSearchingSeries = false
            return
        }
        let vodServers = servers.filter { $0.supportsVOD && $0.type == .dispatcharrAPI }
        guard let server = vodServers.first(where: { $0.isActive }) ?? vodServers.first else { return }
        let baseURL = server.effectiveBaseURL
        let apiKey  = server.effectiveApiKey
        let sID     = server.id
        isSearchingSeries = true
        seriesSearchTask = Task {
            let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))
            var results: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 0.5
            do {
                for try await batch in api.searchVODSeriesStream(query: query) {
                    guard !Task.isCancelled else { break }
                    let items = batch.map { s -> VODDisplayItem in
                        let show = VODSeries(
                            id: String(s.id), name: s.name,
                            posterURL: s.posterURL.flatMap { resolveURL($0, base: baseURL) },
                            backdropURL: nil,
                            rating: s.rating ?? "", plot: s.plot ?? "",
                            genre: s.genre ?? "", releaseDate: "",
                            cast: "", director: "",
                            categoryID: "", categoryName: "Series",
                            serverID: sID, seasons: [], episodeCount: 0
                        )
                        return VODDisplayItem(series: show)
                    }
                    results += items
                    let now = Date()
                    if now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        seriesSearchResults = results
                        lastPublishTime = now
                    }
                }
            } catch {}
            if !Task.isCancelled {
                seriesSearchResults = results
                isSearchingSeries = false
            }
        }
    }

    private func loadMovies(servers: [ServerConnection]) async {
        debugLog("🎬 VODStore.loadMovies: starting, servers=\(servers.count)")
        let activeServer = servers.first(where: { $0.isActive })
        // Active server exists but doesn't support VOD (e.g. M3U) — clear and bail silently.
        if let active = activeServer, !active.supportsVOD {
            debugLog("🎬 VODStore.loadMovies: active server doesn't support VOD, clearing")
            movies = []; movieCategories = []
            isLoadingMovies = false; moviesError = nil
            lastMoviesServerName = nil; currentMoviesServerID = nil
            return
        }
        let vodServers = servers.filter { $0.supportsVOD }
        // Use the active VOD server; fall back to first VOD server only when there is no
        // active server at all (never fall back to an inactive VOD server when a non-VOD
        // server is explicitly active — that would show stale data from the wrong server).
        guard let server = vodServers.first(where: { $0.isActive }) ?? (activeServer == nil ? vodServers.first : nil) else {
            if !servers.isEmpty {
                moviesError = "None of your configured servers support VOD. Use an Xtream Codes or Dispatcharr server to browse movies."
            }
            return
        }
        lastMoviesServerName = server.name
        // Clear stale content immediately when switching to a different server so the
        // loading spinner appears instead of the previous server's movies staying visible.
        if currentMoviesServerID != nil && currentMoviesServerID != server.id {
            movies = []
            movieCategories = []
        }
        currentMoviesServerID = server.id
        isLoadingMovies = true
        moviesError = nil
        DebugLogger.shared.log("VODStore loadMovies — \(server.name) (\(server.type.rawValue)) url=\(server.effectiveBaseURL)",
                               category: "Movies", level: .info)

        // Dispatcharr libraries can be enormous (20 000+ items across 40+ pages).
        // Stream page-by-page so the grid appears after the first 500 items land
        // rather than after the entire library downloads.
        if server.type == .dispatcharrAPI {
            let baseURL = server.effectiveBaseURL
            let apiKey  = server.effectiveApiKey
            let sID     = server.id
            debugLog("🎬 VODStore.loadMovies: dispatcharr baseURL=\(baseURL), hasKey=\(!apiKey.isEmpty)")
            let api     = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))

            // Fetch categories from the dedicated endpoint concurrently
            let apiCats: [DispatcharrVODCategory] = (try? await api.getVODCategories()) ?? []
            let movieCatNames = apiCats
                .filter { $0.categoryType == "movie" || $0.categoryType == "Movie" }
                .map { VODCategory(id: String($0.id), name: $0.name) }
            if !movieCatNames.isEmpty {
                movieCategories = movieCatNames
                debugLog("🎬 VODStore: fetched \(movieCatNames.count) Dispatcharr movie categories")
            }

            var accumulated: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 0.5
            do {
                debugLog("🎬 VODStore.loadMovies: starting stream fetch")
                for try await batch in api.getVODMoviesStream() {
                    guard !Task.isCancelled else { isLoadingMovies = false; return }
                    let newItems = batch.map { m -> VODDisplayItem in
                        let streamURL = api.proxyMovieURL(uuid: m.uuid,
                                                          preferredStreamID: m.streams?.first?.streamID)
                        let genre = m.genre ?? ""
                        let catName = genre.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
                        let movie = VODMovie(
                            id: String(m.id), name: m.title,
                            posterURL: m.posterURL.flatMap { resolveURL($0, base: baseURL) }, backdropURL: nil,
                            rating: m.rating ?? "", plot: m.plot ?? "",
                            genre: genre, releaseDate: "", duration: "",
                            cast: "", director: "", imdbID: "",
                            categoryID: catName, categoryName: catName.isEmpty ? "Uncategorized" : catName,
                            streamURL: streamURL, containerExtension: "mp4", serverID: sID
                        )
                        return VODDisplayItem(movie: movie)
                    }
                    accumulated += newItems
                    // Throttle publishing to max 2x/second to reduce SwiftUI redraws.
                    // Always publish on first batch (to hide spinner).
                    let now = Date()
                    if isLoadingMovies || now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        movies = accumulated
                        lastPublishTime = now
                    }
                    // If no API categories were fetched, build from genre data
                    if movieCatNames.isEmpty {
                        movieCategories = Self.buildCategories(from: accumulated, using: \.movie?.categoryName)
                    }
                    // Hide the spinner after the first page so the grid is visible
                    // while remaining pages continue loading in the background.
                    if isLoadingMovies { isLoadingMovies = false }
                }
                // Final publish to ensure all items visible
                movies = accumulated
            } catch let err as APIError {
                guard !Task.isCancelled else { isLoadingMovies = false; return }
                if accumulated.isEmpty { moviesError = err.errorDescription }
                DebugLogger.shared.logError(err, context: "VODStore.loadMovies(\(server.name))")
            } catch {
                guard !Task.isCancelled else { isLoadingMovies = false; return }
                if accumulated.isEmpty { moviesError = error.localizedDescription }
            }
            isLoadingMovies = false
            return
        }

        // Non-Dispatcharr servers (Xtream Codes) — single request, no progressive load needed.
        do {
            let snap = server.snapshot
            let (raw, cats) = try await VODService.fetchMovies(from: snap)
            guard !Task.isCancelled else { isLoadingMovies = false; return }
            let items = raw.map { VODDisplayItem(movie: $0) }
            movies = items
            let apiCats = cats.filter { $0.itemCount > 0 }
            // Prefer API-provided categories; fall back to building from movie data
            movieCategories = apiCats.isEmpty
                ? Self.buildCategories(from: items, using: \.movie?.categoryName)
                : apiCats
        } catch let err as APIError {
            guard !Task.isCancelled else { isLoadingMovies = false; return }
            moviesError = err.errorDescription
            DebugLogger.shared.logError(err, context: "VODStore.loadMovies(\(server.name))")
        } catch {
            guard !Task.isCancelled else { isLoadingMovies = false; return }
            moviesError = error.localizedDescription
        }
        isLoadingMovies = false
    }

    private func loadSeries(servers: [ServerConnection]) async {
        debugLog("📺 VODStore.loadSeries: starting, servers=\(servers.count)")
        let activeServer = servers.first(where: { $0.isActive })
        if let active = activeServer, !active.supportsVOD {
            series = []; seriesCategories = []
            isLoadingSeries = false; seriesError = nil
            lastSeriesServerName = nil; currentSeriesServerID = nil
            return
        }
        let vodServers = servers.filter { $0.supportsVOD }
        guard let server = vodServers.first(where: { $0.isActive }) ?? (activeServer == nil ? vodServers.first : nil) else {
            if !servers.isEmpty {
                seriesError = "None of your configured servers support VOD. Use an Xtream Codes or Dispatcharr server to browse series."
            }
            return
        }
        lastSeriesServerName = server.name
        // Clear stale content immediately when switching to a different server.
        if currentSeriesServerID != nil && currentSeriesServerID != server.id {
            series = []
            seriesCategories = []
        }
        currentSeriesServerID = server.id
        isLoadingSeries = true
        seriesError = nil
        DebugLogger.shared.log("VODStore loadSeries — \(server.name) (\(server.type.rawValue)) url=\(server.effectiveBaseURL)",
                               category: "TVShows", level: .info)

        if server.type == .dispatcharrAPI {
            let baseURL = server.effectiveBaseURL
            let apiKey  = server.effectiveApiKey
            let sID     = server.id
            let api     = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))

            // Fetch categories from the dedicated endpoint
            let apiCats: [DispatcharrVODCategory] = (try? await api.getVODCategories()) ?? []
            let seriesCatNames = apiCats
                .filter { $0.categoryType == "series" || $0.categoryType == "Series" }
                .map { VODCategory(id: String($0.id), name: $0.name) }
            if !seriesCatNames.isEmpty {
                seriesCategories = seriesCatNames
                debugLog("📺 VODStore: fetched \(seriesCatNames.count) Dispatcharr series categories")
            }

            var accumulated: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 0.5
            do {
                for try await batch in api.getVODSeriesStream() {
                    guard !Task.isCancelled else { isLoadingSeries = false; return }
                    let newItems = batch.map { s -> VODDisplayItem in
                        let genre = s.genre ?? ""
                        let catName = genre.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
                        let show = VODSeries(
                            id: String(s.id), name: s.name,
                            posterURL: s.posterURL.flatMap { resolveURL($0, base: baseURL) }, backdropURL: nil,
                            rating: s.rating ?? "", plot: s.plot ?? "",
                            genre: genre, releaseDate: "",
                            cast: "", director: "",
                            categoryID: catName, categoryName: catName.isEmpty ? "Uncategorized" : catName,
                            serverID: sID, seasons: [], episodeCount: 0
                        )
                        return VODDisplayItem(series: show)
                    }
                    accumulated += newItems
                    // Throttle publishing to max 2x/second to reduce SwiftUI redraws.
                    let now = Date()
                    if isLoadingSeries || now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        series = accumulated
                        lastPublishTime = now
                    }
                    // If no API categories were fetched, build from genre data
                    if seriesCatNames.isEmpty {
                        seriesCategories = Self.buildCategories(from: accumulated, using: \.series?.categoryName)
                    }
                    if isLoadingSeries { isLoadingSeries = false }
                }
                // Final publish to ensure all items visible
                series = accumulated
            } catch let err as APIError {
                guard !Task.isCancelled else { isLoadingSeries = false; return }
                if accumulated.isEmpty { seriesError = err.errorDescription }
                DebugLogger.shared.logError(err, context: "VODStore.loadSeries(\(server.name))")
            } catch {
                guard !Task.isCancelled else { isLoadingSeries = false; return }
                if accumulated.isEmpty { seriesError = error.localizedDescription }
            }
            isLoadingSeries = false
            return
        }

        do {
            let snap = server.snapshot
            let (rawSeries, cats) = try await VODService.fetchSeries(from: snap)
            guard !Task.isCancelled else { isLoadingSeries = false; return }
            let items = rawSeries.map { VODDisplayItem(series: $0) }
            series = items
            let apiCats = cats.filter { $0.itemCount > 0 }
            seriesCategories = apiCats.isEmpty
                ? Self.buildCategories(from: items, using: \.series?.categoryName)
                : apiCats
        } catch let err as APIError {
            guard !Task.isCancelled else { isLoadingSeries = false; return }
            seriesError = err.errorDescription
            DebugLogger.shared.logError(err, context: "VODStore.loadSeries(\(server.name))")
        } catch {
            guard !Task.isCancelled else { isLoadingSeries = false; return }
            seriesError = error.localizedDescription
        }
        isLoadingSeries = false
    }

    // MARK: - Helpers

    /// Build categories from items when the server's category API returns nothing.
    private static func buildCategories(from items: [VODDisplayItem], using keyPath: KeyPath<VODDisplayItem, String?>) -> [VODCategory] {
        var counts: [String: Int] = [:]
        for item in items {
            let name = item[keyPath: keyPath] ?? "Uncategorized"
            counts[name.isEmpty ? "Uncategorized" : name, default: 0] += 1
        }
        let cats = counts.sorted { $0.key < $1.key }
            .map { VODCategory(id: $0.key, name: $0.key, itemCount: $0.value) }
        return cats.isEmpty ? [VODCategory(id: "all", name: "All", itemCount: items.count)] : cats
    }
}

// MARK: - Channel Store
// Owned by MainTabView as a @StateObject.  Pre-fetches channels (and EPG) as
// soon as any server is available and re-fetches whenever the server list
// changes — so the Live TV tab is already populated before the user taps it.
@MainActor
final class ChannelStore: ObservableObject {
    static let shared = ChannelStore()

    // MARK: - Published State
    @Published private(set) var channels: [ChannelDisplayItem] = []
    @Published private(set) var orderedGroups: [String] = []
    @Published private(set) var isLoading = false
    @Published var isEPGLoading = false
    @Published private(set) var error: String?

    // The server that produced the current channel list (for upstream EPG closures).
    private(set) var activeServer: ServerConnection?
    /// ID of the server whose channels are currently loaded — detects server switches.
    private var currentChannelServerID: UUID?

    private var loadTask: Task<Void, Never>?
    private var epgEnrichTask: Task<Void, Never>?

    // MARK: - Public API

    /// Called by MainTabView whenever the server list changes.
    func refresh(servers: [ServerConnection]) {
        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else {
            channels = []; orderedGroups = []; isLoading = false; error = nil
            currentChannelServerID = nil
            return
        }
        // Clear stale channels immediately when the active server changes so old
        // EPG data doesn't linger while the new server's channels are loading.
        if server.id != currentChannelServerID {
            channels = []; orderedGroups = []; error = nil
            currentChannelServerID = server.id
        }
        activeServer = server
        // Set isLoading immediately (before the Task starts) so the UI shows
        // the loading spinner right away. Without this, there's a brief gap
        // where channels are empty and isLoading is false, which shows the
        // "No Channels" empty state — on tvOS this can deadlock the focus engine
        // as views rapidly swap during the onboarding transition.
        if channels.isEmpty { isLoading = true }
        loadTask?.cancel()
        epgEnrichTask?.cancel()
        loadTask = Task { await load(server: server) }
    }

    /// Called by pull-to-refresh — always re-fetches channels AND EPG.
    /// This is async so the pull-to-refresh spinner stays visible until done.
    func forceRefresh(servers: [ServerConnection]) async {
        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else { return }
        activeServer = server
        loadTask?.cancel()
        epgEnrichTask?.cancel()
        await load(server: server)
    }

    // MARK: - Private Loader

    private func load(server: ServerConnection) async {
        // Only show a full-screen spinner when there is nothing cached yet.
        isLoading = channels.isEmpty
        error = nil
        let start = Date()

        debugLog("🔷 ChannelStore.load: snapshotting server properties...")
        // Snapshot all needed properties before the first suspension point so
        // we never touch the SwiftData model after an async yield.
        let baseURL  = server.effectiveBaseURL
        let type     = server.type
        let username = server.username
        let password = server.effectivePassword
        let apiKey   = server.effectiveApiKey
        let serverID = server.id
        let epgURL   = server.effectiveEPGURL
        debugLog("🔷 ChannelStore.load: snapshot done (type=\(type), baseURL=\(baseURL), hasPw=\(!password.isEmpty), hasKey=\(!apiKey.isEmpty))")
        debugLog("🔷 ChannelStore.load: starting fetch...")

        // Auto-retry for transient server-side errors (503/502/504) with backoff.
        // This handles the common case where the server is starting up when the app launches.
        let retryableCodes: Set<Int> = [502, 503, 504]
        let maxAttempts = 4
        let retryDelays: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000] // 2s, 5s, 10s

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { isLoading = false; return }
            do {
                debugLog("🔷 ChannelStore.load: calling fetchChannels attempt \(attempt)")
                let (items, groups) = try await fetchChannels(
                    type: type, baseURL: baseURL,
                    username: username, password: password,
                    apiKey: apiKey, serverID: serverID,
                    epgURL: epgURL
                )
                debugLog("🔷 ChannelStore.load: fetchChannels returned \(items.count) items")
                guard !Task.isCancelled else { isLoading = false; return }
                channels      = items
                orderedGroups = groups
                error = nil
                debugLog("🔷 ChannelStore.load: published \(items.count) channels")
                TopShelfDataManager.syncTopChannels(channels: items)
                DebugLogger.shared.logChannelLoad(
                    serverType: type.rawValue,
                    channelCount: items.count,
                    duration: Date().timeIntervalSince(start))
                isLoading = false
                // For Xtream Codes, EPG isn't available in bulk — enrich
                // channels in the background with per-stream short EPG.
                if type == .xtreamCodes {
                    epgEnrichTask?.cancel()
                    epgEnrichTask = Task {
                        await enrichXtreamEPG(baseURL: baseURL, username: username, password: password)
                    }
                }
                return
            } catch is CancellationError {
                isLoading = false; return
            } catch let u as URLError where u.code == .cancelled {
                isLoading = false; return
            } catch let e as APIError {
                if case .serverError(let code) = e, retryableCodes.contains(code), attempt < maxAttempts {
                    // Transient error — show a soft retry message and wait before next attempt.
                    if channels.isEmpty {
                        error = "Server unavailable (\(code)) — retrying in \(attempt == 1 ? "2" : attempt == 2 ? "5" : "10")s… (attempt \(attempt)/\(maxAttempts))"
                    }
                    try? await Task.sleep(nanoseconds: retryDelays[attempt - 1])
                    continue
                }
                if channels.isEmpty { error = e.errorDescription }
                DebugLogger.shared.logChannelLoad(
                    serverType: type.rawValue,
                    duration: Date().timeIntervalSince(start),
                    error: e)
                break
            } catch {
                if channels.isEmpty { self.error = error.localizedDescription }
                break
            }
        }
        isLoading = false
    }

    // MARK: - Bulk EPG Loading

    /// Loads ALL EPG data upfront so browsing/playback never triggers network requests.
    /// Called immediately after channels load. Sets isEPGLoading during the process.
    func loadAllEPG() async {
        guard let server = activeServer else { return }
        let baseURL  = server.effectiveBaseURL
        let type     = server.type
        let username = server.username
        let password = server.effectivePassword
        let apiKey   = server.effectiveApiKey

        isEPGLoading = true
        defer { isEPGLoading = false }

        switch type {
        case .dispatcharrAPI:
            // Dispatcharr: one bulk call via /api/epg/grid/ — all channels, -1h to +24h
            do {
                let dAPI = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))
                let programs = try await dAPI.getEPGGrid()

                // Everything below (dictionary build, ~7k-item sort,
                // cache writes, fallback loop) used to run on the
                // MainActor here and produced a ~560 ms hang while
                // the user was staring at the Loading Guide screen.
                // Offload all of it to a detached task. The channels
                // snapshot is captured by value so the task doesn't
                // reach back into the MainActor-isolated store.
                let channelSnapshot = self.channels
                let base = baseURL
                await Task.detached(priority: .utility) {
                    let now = Date()

                    // Group by tvgID
                    var byTvgID: [String: [EPGEntry]] = [:]
                    for p in programs {
                        guard let start = p.startTime?.toDate(), let end = p.endTime?.toDate(),
                              end > now else { continue }
                        let key = p.tvgID ?? (p.channel.map { "ch_\($0)" } ?? "")
                        guard !key.isEmpty else { continue }
                        let entry = EPGEntry(title: p.title, description: p.description, startTime: start, endTime: end)
                        byTvgID[key, default: []].append(entry)
                    }
                    // Sort each channel's programs then cache them
                    for (tvgID, entries) in byTvgID {
                        let sorted = entries.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
                        await EPGCache.shared.set(sorted, for: "d_\(base)_\(tvgID)")
                    }
                    debugLog("📺 Bulk EPG loaded: \(programs.count) programs across \(byTvgID.count) channels")

                    // Populate empty-array fallbacks for channels the
                    // bulk didn't cover, so per-card expansion can't
                    // trigger post-loading network fetches. Uses the
                    // same cache-key scheme ChannelListView's
                    // makeFetchUpcoming expects: "d_<base>_<tvgID or channelID>".
                    var filledFallbacks = 0
                    for channel in channelSnapshot {
                        let tvgID = channel.tvgID ?? ""
                        let keyPart = tvgID.isEmpty ? channel.id : tvgID
                        let cacheKey = "d_\(base)_\(keyPart)"
                        if await EPGCache.shared.get(cacheKey) == nil {
                            await EPGCache.shared.set([], for: cacheKey)
                            filledFallbacks += 1
                        }
                    }
                    debugLog("📺 Bulk EPG: filled \(filledFallbacks) empty fallbacks so no post-loading network fetches fire")
                }.value

                // Refresh Top Shelf with updated program info
                TopShelfDataManager.syncTopChannels(channels: self.channels)
            } catch {
                debugLog("📺 Bulk EPG failed: \(error.localizedDescription) — falling back to lazy loading")
            }

        case .xtreamCodes:
            // Xtream: batch per-stream EPG (reuses enrichXtreamEPG)
            await enrichXtreamEPG(baseURL: baseURL, username: username, password: password)

        case .m3uPlaylist:
            // M3U: XMLTV is already fully parsed during channel load — EPGCache is populated.
            // Nothing additional needed.
            debugLog("📺 M3U EPG: already loaded from XMLTV during channel fetch")
        }
    }

    // MARK: - Xtream EPG Enrichment

    /// Progressively fetches short EPG for Xtream channels and updates `channels`
    /// so "Now Playing" info appears without user interaction. Runs in batches of 8
    /// concurrent requests to avoid hammering the server.
    /// Parses Xtream EPG timestamp strings — Unix seconds/ms or "yyyy-MM-dd HH:mm:ss".
    /// Must be `nonisolated` so child tasks in `withTaskGroup` can call it freely.
    private nonisolated static func parseXtreamDate(_ s: String) -> Date? {
        XtreamDateParser.parse(s)
    }

    private func enrichXtreamEPG(baseURL: String, username: String, password: String) async {
        let xAPI = XtreamCodesAPI(baseURL: baseURL, username: username, password: password)
        let snapshot = channels
        let batchSize = 8
        let now = Date()

        // Accumulate all enrichment results, publish channels once at end.
        var allResults: [(String, String, String, Date?, Date?)] = []

        // Process in batches to limit concurrency.
        for batchStart in stride(from: 0, to: snapshot.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + batchSize, snapshot.count)
            let batch = Array(snapshot[batchStart..<batchEnd])

            // Fetch EPG for this batch concurrently.
            let results: [(String, String, String, Date?, Date?)] = await withTaskGroup(
                of: (String, String, String, Date?, Date?)?.self
            ) { group in
                for item in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        guard let epg = try? await xAPI.getEPG(streamID: item.id, limit: 3) else { return nil }
                        // Find the currently-airing program.
                        for listing in epg.epgListings {
                            let start = ChannelStore.parseXtreamDate(listing.start)
                            let end   = ChannelStore.parseXtreamDate(listing.end)
                            guard let s = start, let e = end else { continue }
                            if s <= now && e > now {
                                return (item.id, listing.title, listing.description, s, e)
                            }
                        }
                        return nil
                    }
                }
                var collected: [(String, String, String, Date?, Date?)] = []
                for await result in group {
                    if let r = result { collected.append(r) }
                }
                return collected
            }

            allResults.append(contentsOf: results)
        }

        // Single publish with all accumulated results.
        guard !Task.isCancelled, !allResults.isEmpty else { return }
        var updated = channels
        for (id, title, desc, start, end) in allResults {
            if let idx = updated.firstIndex(where: { $0.id == id }) {
                updated[idx].currentProgram             = title
                updated[idx].currentProgramDescription  = desc
                updated[idx].currentProgramStart        = start
                updated[idx].currentProgramEnd          = end
            }
        }
        channels = updated
    }

    // MARK: - Channel Sorting Helpers

    private func numericChannelValue(_ value: String) -> Double {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return Double.greatestFiniteMagnitude }
        if let d = Double(t) { return d }
        var seenDot = false; var collected = ""
        for ch in t {
            if ch >= "0" && ch <= "9" { collected.append(ch); continue }
            if ch == "." && !seenDot  { seenDot = true; collected.append(ch); continue }
            break
        }
        if collected.isEmpty { return Double.greatestFiniteMagnitude }
        if collected.last == "." { collected.removeLast() }
        return Double(collected) ?? Double.greatestFiniteMagnitude
    }

    private func sortChannels(_ items: [ChannelDisplayItem], groupOrder: [String]) -> [ChannelDisplayItem] {
        let idx = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { ($1, $0) })
        return items.sorted {
            let n0 = numericChannelValue($0.number), n1 = numericChannelValue($1.number)
            if n0 != n1 { return n0 < n1 }
            let g0 = idx[$0.group] ?? Int.max, g1 = idx[$1.group] ?? Int.max
            if g0 != g1 { return g0 < g1 }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func derivedGroupOrder(from items: [ChannelDisplayItem]) -> [String] {
        var seen = Set<String>(); var order: [String] = []
        for item in items { if seen.insert(item.group).inserted { order.append(item.group) } }
        return order
    }

    // MARK: - Dispatcher

    private func fetchChannels(
        type: ServerType, baseURL: String,
        username: String, password: String,
        apiKey: String, serverID: UUID,
        epgURL: String = ""
    ) async throws -> ([ChannelDisplayItem], [String]) {
        switch type {
        case .m3uPlaylist:
            return try await fetchM3U(baseURL: baseURL, epgURL: epgURL)
        case .xtreamCodes:
            return try await fetchXtream(baseURL: baseURL, username: username, password: password)
        case .dispatcharrAPI:
            return try await fetchDispatcharr(baseURL: baseURL, apiKey: apiKey)
        }
    }

    // MARK: - M3U

    private func fetchM3U(baseURL: String, epgURL: String = "") async throws -> ([ChannelDisplayItem], [String]) {
        guard let url = URL(string: baseURL) else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let content = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse }
        let parsed = M3UParser.parse(content: content)
        var groups: [String] = []
        for ch in parsed {
            if !ch.groupTitle.isEmpty && !groups.contains(ch.groupTitle) { groups.append(ch.groupTitle) }
        }

        // Fetch EPG concurrently with building channel items (non-fatal on failure).
        async let epgFetch: [ParsedEPGProgram] = {
            guard !epgURL.isEmpty, let epgURLParsed = URL(string: epgURL) else { return [] }
            return (try? await XMLTVParser.fetchAndParse(url: epgURLParsed)) ?? []
        }()

        var items: [ChannelDisplayItem] = parsed.enumerated().compactMap { (i, ch) in
            guard let streamURL = URL(string: ch.url) else { return nil }
            var item = ChannelDisplayItem(
                id: ch.id.uuidString, name: ch.name,
                number: ch.channelNumber.map { String($0) } ?? String(i + 1),
                logoURL: URL(string: ch.tvgLogo),
                group: ch.groupTitle.isEmpty ? "Uncategorized" : ch.groupTitle,
                categoryOrder: groups.firstIndex(of: ch.groupTitle) ?? Int.max,
                streamURL: streamURL, streamURLs: [streamURL])
            if !ch.tvgID.isEmpty { item.tvgID = ch.tvgID }
            return item
        }

        // Apply EPG data to items and pre-populate EPGCache.
        let programs = await epgFetch
        if !programs.isEmpty {
            let now = Date()
            // Index all programs by channelID for fast lookup.
            var byChannel: [String: [ParsedEPGProgram]] = [:]
            for prog in programs {
                byChannel[prog.channelID, default: []].append(prog)
            }
            // Pre-populate EPGCache with upcoming entries for each tvgID.
            for tvgID in byChannel.keys {
                let upcoming = byChannel[tvgID]!
                    .filter { $0.endTime > now }
                    .sorted { $0.startTime < $1.startTime }
                    .map { EPGEntry(title: $0.title, description: $0.description, startTime: $0.startTime, endTime: $0.endTime) }
                if !upcoming.isEmpty {
                    await EPGCache.shared.set(upcoming, for: "m3u_\(tvgID)")
                }
            }
            // Annotate each channel item with its current program.
            for idx in items.indices {
                guard let tvgID = items[idx].tvgID,
                      let progs = byChannel[tvgID] else { continue }
                if let current = progs.first(where: { $0.startTime <= now && $0.endTime > now }) {
                    items[idx].currentProgram             = current.title
                    items[idx].currentProgramDescription  = current.description
                    items[idx].currentProgramStart        = current.startTime
                    items[idx].currentProgramEnd          = current.endTime
                }
            }
        }

        let sorted = sortChannels(items, groupOrder: groups)
        return (sorted, derivedGroupOrder(from: sorted))
    }

    // MARK: - Xtream Codes

    private func fetchXtream(baseURL: String, username: String, password: String) async throws -> ([ChannelDisplayItem], [String]) {
        let xAPI = XtreamCodesAPI(baseURL: baseURL, username: username, password: password)
        async let streamsFetch    = xAPI.getLiveStreams()
        async let categoriesFetch = xAPI.getLiveCategories()
        let streams    = try await streamsFetch
        let categories = (try? await categoriesFetch) ?? []
        let catOrder   = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
        let usedCatIDs = Set(streams.compactMap { $0.categoryID })
        var groupOrder = categories.filter { usedCatIDs.contains($0.id) }.map { $0.name }
        if streams.contains(where: { ($0.categoryID ?? "").isEmpty }) { groupOrder.append("Uncategorized") }
        let items: [ChannelDisplayItem] = streams.enumerated().compactMap { (i, s) in
            let urls = xAPI.streamURLs(for: s); guard let primary = urls.first else { return nil }
            let catName = categories.first(where: { $0.id == s.categoryID })?.name ?? "Uncategorized"
            return ChannelDisplayItem(
                id: String(s.streamID), name: s.name,
                number: String(s.num ?? (i + 1)),
                logoURL: s.streamIcon.flatMap { URL(string: $0) },
                group: catName,
                categoryOrder: catOrder[s.categoryID ?? ""] ?? Int.max,
                streamURL: primary, streamURLs: urls)
        }
        let sorted = sortChannels(items, groupOrder: groupOrder)
        return (sorted, derivedGroupOrder(from: sorted))
    }

    // MARK: - Dispatcharr API

    private func fetchDispatcharr(baseURL: String, apiKey: String) async throws -> ([ChannelDisplayItem], [String]) {
        debugLog("🔷 ChannelStore.fetchDispatcharr: starting")
        let dAPI = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL

        // Fire channels + groups + EPG all concurrently.
        debugLog("🔷 ChannelStore.fetchDispatcharr: launching concurrent fetches")
        async let groupsFetch   = dAPI.getChannelGroups()
        async let channelsFetch = dAPI.getChannels()
        async let programsFetch = dAPI.getCurrentPrograms()

        let dGroups: [DispatcharrChannelGroup]
        do {
            dGroups = try await groupsFetch
            debugLog("🔷 ChannelStore.fetchDispatcharr: groups=\(dGroups.count)")
        } catch {
            debugLog("🔷 ChannelStore.fetchDispatcharr: groups FAILED: \(error.localizedDescription)")
            dGroups = []
        }
        let dChannels: [DispatcharrChannel]
        do {
            dChannels = try await channelsFetch
            debugLog("🔷 ChannelStore.fetchDispatcharr: channels=\(dChannels.count)")
        } catch {
            debugLog("🔷 ChannelStore.fetchDispatcharr: channels FAILED: \(error.localizedDescription)")
            throw error
        }
        let programs  = try? await programsFetch   // EPG — failure is non-fatal
        debugLog("🔷 ChannelStore.fetchDispatcharr: programs=\(programs?.count ?? 0)")

        let groupNameByID = Dictionary(uniqueKeysWithValues: dGroups.map { ($0.id, $0.name) })
        let usedGroupIDs  = Set(dChannels.compactMap { $0.channelGroupID })
        let channelsWithGroup = dChannels.filter { $0.channelGroupID != nil }.count
        let channelsWithoutGroup = dChannels.filter { $0.channelGroupID == nil }.count
        debugLog("🔷 ChannelStore.fetchDispatcharr: groupMapping — \(dGroups.count) groups, \(usedGroupIDs.count) used, \(channelsWithGroup) channels have groupID, \(channelsWithoutGroup) channels have nil groupID")
        if let first = dChannels.first {
            debugLog("🔷 ChannelStore.fetchDispatcharr: sample channel — id=\(first.id), name=\(first.name), channelGroupID=\(String(describing: first.channelGroupID))")
        }
        var groupOrder    = dGroups.filter { usedGroupIDs.contains($0.id) }.map { $0.name }
        if dChannels.contains(where: { $0.channelGroupID == nil }) { groupOrder.append("Uncategorized") }

        func logoURL(_ logoID: Int?) -> URL? {
            guard let id = logoID else { return nil }
            return URL(string: "\(base)/api/channels/logos/\(id)/cache/")
        }
        func streamURLs(_ uuid: String?) -> [URL] {
            guard let uuid, !uuid.isEmpty else { return [] }
            // TS stream — the only working Dispatcharr proxy endpoint.
            // /proxy/ts/channel/ doesn't exist. HLS returns 404 on this instance.
            return [
                "\(base)/proxy/ts/stream/\(uuid)"
            ].compactMap { URL(string: $0) }
        }

        var items: [ChannelDisplayItem] = dChannels.enumerated().map { (i, ch) in
            let grp  = ch.channelGroupID.flatMap { groupNameByID[$0] } ?? "Uncategorized"
            let urls = streamURLs(ch.uuid)
            let num  = ch.channelNumber.map { n in
                n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
            } ?? String(i + 1)
            var item = ChannelDisplayItem(
                id: String(ch.id), name: ch.name, number: num,
                logoURL: logoURL(ch.logoID), group: grp,
                categoryOrder: groupOrder.firstIndex(of: grp) ?? Int.max,
                streamURL: urls.first, streamURLs: urls)
            item.tvgID = ch.tvgID
            return item
        }
        items = sortChannels(items, groupOrder: groupOrder)

        // Apply EPG data.
        if let programs, !programs.isEmpty {
            var epgByTvgID: [String: (title: String, description: String, start: Date?, end: Date?)] = [:]
            for prog in programs {
                guard let tvgID = prog.tvgID, !tvgID.isEmpty, !prog.title.isEmpty else { continue }
                let desc = prog.description.isEmpty ? prog.subTitle : prog.description
                epgByTvgID[tvgID] = (prog.title, desc, prog.startTime?.toDate(), prog.endTime?.toDate())
            }
            items = items.map { item in
                guard let tvgID = item.tvgID, !tvgID.isEmpty,
                      let info = epgByTvgID[tvgID] else { return item }
                var updated = item
                updated.currentProgram             = info.title
                updated.currentProgramDescription  = info.description
                updated.currentProgramStart        = info.start
                updated.currentProgramEnd          = info.end
                return updated
            }
        }

        return (items, derivedGroupOrder(from: items))
    }
}

// MARK: - Favorites Store
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    @Published private(set) var favoriteItems: [ChannelDisplayItem] = []
    private var favoriteIDs: Set<String>

    /// App Group suite name — retained for reference / historical reasons.
    /// We no longer write to `UserDefaults(suiteName:)` on tvOS because
    /// the sandbox denies writes to every app-group container with EPERM
    /// on this project's Apple TV — see `TopShelfDataManager` doc below.
    /// The value writes go through `TopShelfKeychain` instead.
    static let appGroupID = "group.app.molinete.aerio.topshelf"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "favoriteChannelIDs") ?? []
        self.favoriteIDs = Set(saved)
    }

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    func toggle(_ item: ChannelDisplayItem) {
        if favoriteIDs.contains(item.id) {
            favoriteIDs.remove(item.id)
            favoriteItems.removeAll { $0.id == item.id }
        } else {
            favoriteIDs.insert(item.id)
            favoriteItems.append(item)
            favoriteItems.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "favoriteChannelIDs")
        syncToSharedDefaults()
    }

    /// Called when channels load — hydrates in-memory favorites from fresh item data.
    func register(items: [ChannelDisplayItem]) {
        favoriteItems = items.filter { favoriteIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        syncToSharedDefaults()
    }

    /// Writes favorite channel info to shared storage for the Top Shelf
    /// extension. Uses `TopShelfKeychain` (same as `topChannels` and
    /// `continueWatching`) rather than `UserDefaults(suiteName:)` because
    /// the tvOS sandbox denies app-group container writes with EPERM on
    /// this project, which also triggered a noisy CFPrefsPlistSource
    /// cfprefsd warning on launch.
    private func syncToSharedDefaults() {
        #if os(tvOS)
        let entries: [[String: String]] = favoriteItems.map { item in
            var entry: [String: String] = [
                "id": item.id,
                "name": item.name,
                "number": item.number
            ]
            if let logo = item.logoURL?.absoluteString { entry["logoURL"] = logo }
            return entry
        }
        TopShelfKeychain.write(array: entries, key: "favorites")
        #endif
    }
}

// MARK: - Top Shelf Data Manager (tvOS)
/// Syncs Continue Watching VOD + most-watched channels to a **shared
/// Keychain item**, which is then read by the Top Shelf extension.
///
/// Why Keychain instead of App Groups? On this project's Apple TV, the
/// sandbox denies writes to every app group container with EPERM even
/// though the entitlement is present in the signed binary and
/// containermanagerd recognizes it (we verified both with SecTask* runtime
/// dumps and direct container probes). Keychain sharing goes through a
/// completely separate sandbox path (`keychain-access-groups`) that
/// already has a wildcard `47DTJ3Q67T.*` granted in the provisioning
/// profile, so it works without any portal changes.
///
/// Payload sizes are well under keychain item limits (~10-20 KB total).
@MainActor
enum TopShelfDataManager {
    /// Used only by the (tvOS) `FavoritesStore` below, which still wants a
    /// stable identifier string for UserDefaults suite naming — keychain
    /// shuttling doesn't need it.
    static let appGroupID = "group.app.molinete.aerio.topshelf"

    // MARK: - Public API

    static func incrementWatchCount(for channel: ChannelDisplayItem) {
        #if os(tvOS)
        var counts = TopShelfKeychain.readDictionary(key: "watchCounts") as? [String: Int] ?? [:]
        counts[channel.id, default: 0] += 1
        TopShelfKeychain.write(dictionary: counts, key: "watchCounts")
        #endif
    }

    /// Write top 6 channels (most-watched first, padded with first
    /// logo-bearing channels) to the shared keychain item. Only metadata +
    /// raw logo URLs are stored — no downloading or image processing happens
    /// in the main app. The Top Shelf extension passes the raw `logoURL`
    /// directly to `setImageURL(_:for:)` and tvOS fetches it natively.
    ///
    /// Earlier iterations of this code tried to pre-process the logos into
    /// padded, aspect-fit local PNGs so they'd render consistently at the
    /// `.square` shape. That whole pipeline (main-app → Caches → extension
    /// → file URL → tvOS) was empirically proven unworkable: tvOS's host
    /// process cannot read files from either the extension's OR the main
    /// app's data containers — both are private sandboxes. The only file
    /// locations tvOS can read from are the extension's bundle Resources,
    /// which are sealed at build time and cannot hold dynamic per-user data.
    /// So we rely on remote URLs and accept tvOS's default scaling behavior.
    static func syncTopChannels(channels: [ChannelDisplayItem]) {
        #if os(tvOS)
        let counts = TopShelfKeychain.readDictionary(key: "watchCounts") as? [String: Int] ?? [:]

        // Most-watched channels first, ranked by play count.
        let watched = channels
            .filter { counts[$0.id] ?? 0 > 0 }
            .sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }

        // Pad the ranked list up to 6 with the first logo-bearing channels
        // that aren't already in the watched list. This way a user who has
        // only ever played 1–2 channels still sees a full shelf row.
        var ranked: [ChannelDisplayItem] = Array(watched.prefix(6))
        if ranked.count < 6 {
            let watchedIDs = Set(ranked.map { $0.id })
            for channel in channels where channel.logoURL != nil && !watchedIDs.contains(channel.id) {
                ranked.append(channel)
                if ranked.count >= 6 { break }
            }
        }

        let channelEntries: [[String: String]] = ranked.map { item in
            var entry: [String: String] = ["id": item.id, "name": item.name, "number": item.number]
            if let logo = item.logoURL?.absoluteString { entry["logoURL"] = logo }
            if let program = item.currentProgram { entry["currentProgram"] = program }
            return entry
        }

        debugLog("🔐 TopShelf: syncTopChannels — \(channelEntries.count) channels (from \(channels.count) total)")
        TopShelfKeychain.write(array: channelEntries, key: "topChannels")
        #endif
    }

    /// Sync up to 10 most recent unfinished VOD items to the shared keychain.
    /// Like `syncTopChannels`, this only stores metadata + raw poster URLs —
    /// the extension passes `posterURL` directly to `setImageURL`.
    static func syncContinueWatching(_ items: [WatchProgress]) {
        #if os(tvOS)
        let recent = items
            .filter { !$0.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(10)

        let vodEntries: [[String: String]] = recent.map { p in
            var entry: [String: String] = [
                "vodID": p.vodID, "title": p.title,
                "vodType": p.vodType,
                "positionMs": String(p.positionMs),
                "durationMs": String(p.durationMs)
            ]
            if let poster = p.posterURL { entry["posterURL"] = poster }
            if let stream = p.streamURL { entry["streamURL"] = stream }
            if let serverID = p.serverID { entry["serverID"] = serverID }
            if let seriesID = p.seriesID { entry["seriesID"] = seriesID }
            return entry
        }

        debugLog("🔐 TopShelf: syncContinueWatching — \(vodEntries.count) entries (from \(items.count) total, \(items.filter{!$0.isFinished}.count) unfinished)")
        TopShelfKeychain.write(array: vodEntries, key: "continueWatching")
        #endif
    }

    /// Wipes every keychain item this manager writes. Called on app launch
    /// when the user has no servers configured (fresh install, uninstall +
    /// reinstall, or manually removed all servers) so the Top Shelf
    /// extension stops showing stale data from a previous install.
    ///
    /// This is necessary because iOS/tvOS keychain items persist across
    /// app deletions — they're tied to the app's access group, not to the
    /// app's data container, so `delete + reinstall` does not wipe them
    /// the way it wipes `UserDefaults` or SwiftData.
    static func clearAll() {
        #if os(tvOS)
        TopShelfKeychain.delete(key: "continueWatching")
        TopShelfKeychain.delete(key: "topChannels")
        TopShelfKeychain.delete(key: "watchCounts")
        debugLog("🔐 TopShelf: clearAll — wiped continueWatching, topChannels, watchCounts")
        #endif
    }
}

// MARK: - Shared Keychain Storage
/// Small generic-password keychain helper that stores arbitrary JSON values
/// under `service = "aerio.topshelf"` and a per-key `account`. The access
/// group `$(AppIdentifierPrefix)aerio.topshelf.shared` is covered by the
/// existing `47DTJ3Q67T.*` wildcard in the provisioning profile, so both
/// the main tvOS app and the Top Shelf extension can read/write these
/// items without any portal changes.
enum TopShelfKeychain {
    /// Keychain service identifier — groups all Top Shelf entries together.
    static let service = "aerio.topshelf"
    /// Keychain access group. The team ID prefix is required by iOS and is
    /// covered by the `47DTJ3Q67T.*` wildcard `keychain-access-groups`
    /// entitlement already granted by the provisioning profile.
    static let accessGroup = "47DTJ3Q67T.aerio.topshelf.shared"

    // MARK: Write

    static func write(array: [[String: String]], key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: array) else {
            debugLog("🔐 TopShelf: JSON serialization failed for key=\(key)")
            return
        }
        writeData(data, key: key)
    }

    static func write(dictionary: [String: Any], key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            debugLog("🔐 TopShelf: JSON serialization failed for key=\(key)")
            return
        }
        writeData(data, key: key)
    }


    private static func writeData(_ data: Data, key: String) {
        #if os(tvOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess {
            debugLog("🔐 TopShelf: updated \(data.count)B → keychain[\(key)]")
            return
        }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                debugLog("🔐 TopShelf: added \(data.count)B → keychain[\(key)]")
            } else {
                debugLog("🔐 TopShelf: ❌ SecItemAdd failed key=\(key) status=\(addStatus) (\(secErrorMessage(addStatus)))")
            }
            return
        }
        debugLog("🔐 TopShelf: ❌ SecItemUpdate failed key=\(key) status=\(status) (\(secErrorMessage(status)))")
        #endif
    }

    // MARK: Delete

    /// Deletes a single keychain item by account name. Used by
    /// `TopShelfDataManager.clearAll()` to wipe stale Top Shelf data that
    /// would otherwise survive an app delete/reinstall.
    static func delete(key: String) {
        #if os(tvOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            debugLog("🔐 TopShelf: ❌ delete failed key=\(key) status=\(status) (\(secErrorMessage(status)))")
        }
        #endif
    }

    // MARK: Read

    static func readArray(key: String) -> [[String: String]]? {
        guard let data = readData(key: key),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return nil
        }
        return obj
    }

    static func readDictionary(key: String) -> Any? {
        guard let data = readData(key: key),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return obj
    }


    private static func readData(key: String) -> Data? {
        #if os(tvOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return data
        }
        if status != errSecItemNotFound {
            debugLog("🔐 TopShelf: ❌ SecItemCopyMatching failed key=\(key) status=\(status) (\(secErrorMessage(status)))")
        }
        return nil
        #else
        return nil
        #endif
    }

    // MARK: Diagnostics

    private static func secErrorMessage(_ status: OSStatus) -> String {
        if let msg = SecCopyErrorMessageString(status, nil) as String? {
            return msg
        }
        return "OSStatus \(status)"
    }
}

// MARK: - Now Playing Manager
@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()
    @Published var playingItem: ChannelDisplayItem? = nil
    @Published var playingHeaders: [String: String] = [:]
    @Published var isMinimized: Bool = false
    @Published var isLive: Bool = true

    var isActive: Bool { playingItem != nil }

    func startPlaying(_ item: ChannelDisplayItem, headers: [String: String], isLive: Bool = true) {
        debugLog("🎮 NowPlaying.startPlaying: \(item.name) (id=\(item.id)), isLive=\(isLive), wasMinimized=\(isMinimized), wasPlaying=\(playingItem?.name ?? "nil")")
        playingItem = item
        playingHeaders = headers
        self.isLive = isLive
        isMinimized = false
        // Track watch count for Top Shelf "most watched" ranking
        if isLive { TopShelfDataManager.incrementWatchCount(for: item) }
    }

    func minimize() {
        debugLog("🎮 NowPlaying.minimize: \(playingItem?.name ?? "nil")")
        isMinimized = true
    }

    func expand() {
        debugLog("🎮 NowPlaying.expand: \(playingItem?.name ?? "nil")")
        isMinimized = false
    }

    func stop() {
        debugLog("🎮 NowPlaying.stop: \(playingItem?.name ?? "nil")")
        playingItem = nil
        isMinimized = false
    }
}

// MARK: - Tab Definition
enum AppTab: String, CaseIterable {
    case liveTV    = "livetv"
    case favorites = "favorites"
    case dvr       = "dvr"
    case onDemand  = "ondemand"
    case settings  = "settings"

    var title: String {
        switch self {
        case .liveTV:    return "Live TV"
        case .favorites: return "Favorites"
        case .dvr:       return "DVR"
        case .onDemand:  return "On Demand"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .liveTV:    return "antenna.radiowaves.left.and.right"
        case .favorites: return "star.fill"
        case .dvr:       return "record.circle"
        case .onDemand:  return "play.rectangle.on.rectangle"
        case .settings:  return "gearshape.fill"
        }
    }
}

// MARK: - Main Tab View
struct MainTabView: View {
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.modelContext) private var modelContext
    @Query private var allServers: [ServerConnection]
    @Query private var allRecordings: [Recording]

    @State private var selectedTab: AppTab = .liveTV
    @State private var showSearch = false
    @State private var isPlaying = false  // for Movies / TV Shows player state
    /// Tracks whether a VOD detail view is pushed (Movies or Series).
    /// When true, Menu button should pop the navigation, not switch tabs.
    @State private var isVODDetailPushed = false
    /// Signal to VOD views to pop their navigation stack.
    @State private var vodNavPopRequested = false
    #if os(tvOS)
    @State private var showExitConfirmation = false
    #endif
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @StateObject private var vodStore = VODStore()
    @ObservedObject private var channelStore = ChannelStore.shared
    @AppStorage("hasCompletedInitialEPG") private var hasCompletedInitialEPG = false
    @State private var showInitialEPGLoading = false
    /// Flipped true after the first DVR reconcile completes so the
    /// initial loading screen knows it can dismiss. Only gates the
    /// dismiss when a Dispatcharr server is configured — other server
    /// types skip this wait entirely.
    @State private var didInitialDVRReconcile = false

    init() {
        debugLog("🔶🔶 MainTabView.init() — NEW INSTANCE CREATED, thread=\(Thread.current)")
    }

    /// Changes whenever any field that affects a VOD fetch changes — triggers re-fetch.
    /// Includes all servers (not just VOD-capable) so switching to/from M3U also fires the task.
    private var vodServerKey: String {
        allServers
            .map { "\($0.id.uuidString)|\($0.baseURL)|\($0.isActive ? "1" : "0")" }
            .sorted()
            .joined(separator: ",")
    }

    /// Changes whenever any server changes — used to trigger channel re-fetch.
    /// Includes isActive so switching the active server always re-fires the task.
    private var channelServerKey: String {
        allServers.map { "\($0.id.uuidString)|\($0.baseURL)|\($0.isActive ? "1" : "0")" }
            .sorted()
            .joined(separator: ",")
    }

    /// Restart the DVR reconcile loop whenever the set of Dispatcharr
    /// servers (or their identity) changes. The loop itself polls
    /// every 2 minutes internally.
    private var dvrReconcileKey: String {
        allServers
            .filter { $0.type == .dispatcharrAPI }
            .map { "\($0.id.uuidString)" }
            .sorted()
            .joined(separator: ",")
    }

    /// Walks every Dispatcharr server, asks the coordinator to
    /// reconcile its server-side recordings against local SwiftData
    /// rows (status sync + prune + orphan import). Fires from a
    /// tab-bar-level .task so the DVR tab can light up even when the
    /// user hasn't navigated to it yet — `hasRecordings` reads
    /// SwiftData, which the reconciler writes into.
    private func reconcileAllDispatcharrRecordings() async {
        let dispatcharrServers = allServers.filter { $0.type == .dispatcharrAPI }
        guard !dispatcharrServers.isEmpty else { return }
        for server in dispatcharrServers {
            let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                     auth: .apiKey(server.effectiveApiKey),
                                     userAgent: server.effectiveUserAgent)
            await RecordingCoordinator.shared.reconcileDispatcharrRecordings(
                api: api,
                serverID: server.id.uuidString,
                modelContext: modelContext
            )
        }
    }

    // MARK: - Initial Loading Screen State

    /// True when the active server list contains a Dispatcharr server
    /// — only those require a DVR reconcile before the loading
    /// screen can dismiss. Other server types ignore the DVR gate.
    private var needsInitialDVRSync: Bool {
        allServers.contains { $0.type == .dispatcharrAPI }
    }

    /// Hashable digest that flips whenever ANY of the initial sync
    /// signals change (channels, EPG, VOD movies, VOD series, DVR
    /// reconcile). `.onChange(of: initialSyncKey)` listens to it and
    /// calls `tryDismissInitialLoading()` each time.
    private var initialSyncKey: String {
        let channelsDone = !channelStore.isLoading && !channelStore.channels.isEmpty
        let epgDone      = !channelStore.isEPGLoading
        let vodDone      = !vodStore.isLoadingMovies && !vodStore.isLoadingSeries
        let dvrDone      = didInitialDVRReconcile || !needsInitialDVRSync
        return "\(channelsDone)|\(epgDone)|\(vodDone)|\(dvrDone)"
    }

    /// Dynamic status string displayed on the Loading Guide screen so
    /// the user knows which phase is in flight. Evaluated top-down in
    /// roughly the order the phases complete.
    private var initialLoadingStatusText: String {
        if channelStore.isLoading || channelStore.channels.isEmpty {
            return "Loading channels"
        }
        if channelStore.isEPGLoading {
            return "Downloading program guide"
        }
        if vodStore.isLoadingMovies || vodStore.isLoadingSeries {
            return "Loading movies & series"
        }
        if needsInitialDVRSync && !didInitialDVRReconcile {
            return "Syncing recordings"
        }
        return "Finishing up"
    }

    /// Show the initial sync loading screen when we have a server
    /// list to load from AND channels haven't populated yet. Called
    /// both on `onAppear` (normal launches) and on `onChange` of the
    /// server count (iCloud-sync onboarding, where servers arrive
    /// after MainTabView has already appeared).
    ///
    /// Skipped when:
    /// - The screen is already showing (avoid a second `.fullScreenCover`).
    /// - No servers are configured (we can't sync anything).
    /// - Channels are already populated (a normal warm reopen where
    ///   the ChannelStore is already hydrated; nothing new to show).
    private func tryShowInitialLoading() {
        guard !showInitialEPGLoading else { return }
        guard !allServers.isEmpty else { return }
        guard channelStore.channels.isEmpty else { return }
        showInitialEPGLoading = true
        debugLog("🔶 Initial sync starting — showing loading screen (servers=\(allServers.count))")
    }

    /// Called whenever `initialSyncKey` changes. Dismisses the
    /// Loading Guide screen only when every initial sync signal is
    /// finished, so the user lands in fully-loaded List / Guide
    /// views instead of a half-populated app.
    private func tryDismissInitialLoading() {
        guard showInitialEPGLoading else { return }
        guard !channelStore.isLoading, !channelStore.channels.isEmpty else { return }
        guard !channelStore.isEPGLoading else { return }
        guard !vodStore.isLoadingMovies, !vodStore.isLoadingSeries else { return }
        if needsInitialDVRSync && !didInitialDVRReconcile { return }

        withAnimation(.easeOut(duration: 0.4)) {
            showInitialEPGLoading = false
        }
        debugLog("🔶 Initial sync complete — dismissing loading screen")
    }
    /// Shared drag offset — MiniPlayerBar writes it, PlayerView reads it to slide in from below.
    @State private var miniPlayerDragOffset: CGFloat = 0

    private var isAnyBackgroundWork: Bool {
        channelStore.isLoading || channelStore.isEPGLoading || vodStore.isLoadingMovies || vodStore.isLoadingSeries
    }

    var body: some View {
        ZStack {
            tabContentView

            // Background activity indicator — top left
            if isAnyBackgroundWork, !nowPlaying.isActive || nowPlaying.isMinimized {
                VStack {
                    HStack(spacing: 6) {
                        ProgressView()
                            #if os(tvOS)
                            .scaleEffect(0.6)
                            #else
                            .scaleEffect(0.5)
                            #endif
                        Text("Syncing…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.5).clipShape(Capsule()))
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .zIndex(1)
            }

            // Single PlayerView kept in hierarchy for uninterrupted playback.
            // Transitions between full-screen and mini use size/position
            // modifiers — the player instance is never destroyed.
            if nowPlaying.isActive, let item = nowPlaying.playingItem {
                #if os(iOS)
                GeometryReader { geo in
                    let containerH = geo.size.height
                    PlayerView(
                        urls: item.streamURLs,
                        title: item.name,
                        headers: nowPlaying.playingHeaders,
                        isLive: nowPlaying.isLive,
                        subtitle: item.currentProgram,
                        subtitleStart: item.currentProgramStart,
                        subtitleEnd: item.currentProgramEnd,
                        artworkURL: item.logoURL,
                        onMinimize: { nowPlaying.minimize() },
                        onClose: { nowPlaying.stop() }
                    )
                    .id(item.id) // Force recreate when channel changes
                    .ignoresSafeArea()
                    // When minimized: push off-screen below; drag up pulls it into view.
                    // When expanded: sit at y=0 (full screen).
                    .offset(y: nowPlaying.isMinimized ? max(0, containerH + miniPlayerDragOffset) : 0)
                    .opacity(nowPlaying.isMinimized ? min(1, -miniPlayerDragOffset / 300) : 1)
                    .allowsHitTesting(!nowPlaying.isMinimized)
                }
                .ignoresSafeArea()
                #elseif os(tvOS)
                // Single PlayerView instance — survives minimize/expand without
                // recreating the player (avoids 1s+ hang and stream restart).
                GeometryReader { geo in
                    let minimized = nowPlaying.isMinimized
                    let miniW: CGFloat = 400
                    let miniH: CGFloat = 225

                    ZStack(alignment: .topTrailing) {
                        PlayerView(
                            urls: item.streamURLs,
                            title: item.name,
                            headers: nowPlaying.playingHeaders,
                            isLive: nowPlaying.isLive,
                            subtitle: item.currentProgram,
                            subtitleStart: item.currentProgramStart,
                            subtitleEnd: item.currentProgramEnd,
                            artworkURL: item.logoURL,
                            onMinimize: { withAnimation(.spring(response: 0.35)) { nowPlaying.minimize() } },
                            onClose: { nowPlaying.stop() }
                        )
                        .id(item.id)
                        .frame(
                            width: minimized ? miniW : geo.size.width,
                            height: minimized ? miniH : geo.size.height
                        )
                        .clipShape(RoundedRectangle(cornerRadius: minimized ? 12 : 0, style: .continuous))
                        .shadow(color: minimized ? .black.opacity(0.6) : .clear, radius: 20, y: 8)
                        .allowsHitTesting(!minimized) // Full-screen: interactive; mini: not
                        .padding(.trailing, minimized ? 40 : 0)
                        .padding(.top, minimized ? 40 : 0)

                        // Stop button — only visible when minimized
                        // Mini player: no stop button — press Menu/Back to stop
                        // (handled by .onExitCommand on the outer ZStack).
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: minimized ? .topTrailing : .center)
                    .animation(.spring(response: 0.35), value: minimized)
                }
                .ignoresSafeArea()
                .zIndex(2)
                // Create an isolated focus section so the guide underneath can't steal
                // focus when the player is full-screen. Without this, the ZStack overlay
                // lets d-pad events fall through to the channel list behind the player.
                .focusSection()
                #endif
            }

            // In-app reminder banner — shows when a reminder fires while app is in foreground
            ReminderBannerView()
        }
        // safeAreaInset on the outer ZStack pushes the entire TabView (including its tab bar)
        // upward so the tab bar sits above the mini player bar and remains tappable.
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if nowPlaying.isMinimized, let item = nowPlaying.playingItem {
                MiniPlayerBar(item: item, nowPlaying: nowPlaying, dragOffset: $miniPlayerDragOffset)
            }
        }
        #endif
        #if os(tvOS)
        // When mini player is active, pressing Menu stops it.
        // When no mini player, Menu navigates normally (tab switch, etc.)
        .onExitCommand {
            if nowPlaying.isMinimized {
                nowPlaying.stop()
            }
        }
        #endif
        .environmentObject(nowPlaying)
        .environmentObject(favoritesStore)
        .environmentObject(channelStore)
        // Refresh native tab bar appearance whenever the theme changes.
        .onChange(of: theme.selectedTheme)   { _, _ in configureTabBarAppearance() }
        .onChange(of: theme.useCustomAccent) { _, _ in configureTabBarAppearance() }
        .onChange(of: theme.customAccentHex) { _, _ in configureTabBarAppearance() }
    }

    private var hasFavorites: Bool { !favoritesStore.favoriteItems.isEmpty }
    private var hasRecordings: Bool { !allRecordings.isEmpty }

    // MARK: - Tab Content
    private var tabContentView: some View {
        TabView(selection: $selectedTab) {
            ChannelListView()
                .tabItem { Label(AppTab.liveTV.title, systemImage: AppTab.liveTV.icon) }
                .tag(AppTab.liveTV)

            // Favorites tab only exists while the user has at least one favorite.
            // The tab bar animates it in/out automatically when the count crosses zero.
            if hasFavorites {
                FavoritesView()
                    .tabItem { Label(AppTab.favorites.title, systemImage: AppTab.favorites.icon) }
                    .tag(AppTab.favorites)
            }

            // DVR tab only exists while the user has at least one recording
            // (local or server-side). Animates in/out as recordings are added/removed.
            if hasRecordings {
                NavigationStack {
                    MyRecordingsView()
                }
                .tabItem { Label(AppTab.dvr.title, systemImage: AppTab.dvr.icon) }
                .tag(AppTab.dvr)
            }

            OnDemandView(vodStore: vodStore, isPlaying: $isPlaying, isDetailPushed: $isVODDetailPushed, popRequested: $vodNavPopRequested)
                .tabItem { Label(AppTab.onDemand.title, systemImage: AppTab.onDemand.icon) }
                .tag(AppTab.onDemand)

            #if os(tvOS)
            SettingsView(selectedTab: $selectedTab)
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.icon) }
                .tag(AppTab.settings)
            #else
            SettingsView()
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.icon) }
                .tag(AppTab.settings)
            #endif
        }
        .tint(theme.accent)
        // If the user removes their last favorite while on the Favorites tab, redirect home.
        .onChange(of: hasFavorites) { _, nowHasFavorites in
            if !nowHasFavorites && selectedTab == .favorites {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    selectedTab = .liveTV
                }
            }
        }
        // If the user deletes their last recording while on the DVR tab, redirect home.
        .onChange(of: hasRecordings) { _, nowHasRecordings in
            if !nowHasRecordings && selectedTab == .dvr {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    selectedTab = .liveTV
                }
            }
        }
        .onAppear {
            debugLog("🔶 MainTabView.onAppear: allServers=\(allServers.count), selectedTab=\(selectedTab), thread=\(Thread.current)")
            if UserDefaults.standard.bool(forKey: "launchOnLiveTV") {
                selectedTab = .liveTV
                UserDefaults.standard.removeObject(forKey: "launchOnLiveTV")
                debugLog("🔶 MainTabView.onAppear: launchOnLiveTV=true, set selectedTab=.liveTV")
            } else {
                selectedTab = AppTab(rawValue: defaultTabRaw) ?? .liveTV
            }
            configureTabBarAppearance()
            tryShowInitialLoading()
            debugLog("🔶 MainTabView.onAppear: done")
        }
        // Also re-evaluate the loading screen whenever the server list
        // transitions (e.g. iCloud sync imports servers after MainTabView
        // has already appeared — without this observer the loading
        // screen would never show for an iCloud-onboarded device and
        // the user would land on Live TV before channels/EPG/VOD/DVR
        // had finished syncing).
        .onChange(of: allServers.count) { _, _ in
            tryShowInitialLoading()
        }
        // Hold the initial loading screen until channels + EPG + VOD
        // + first DVR reconcile are ALL finished. The user previously
        // complained about landing in List/Guide views while VOD was
        // still loading and DVR hadn't synced — this keeps the
        // on-screen state honest. The key is a Hashable digest of
        // every signal; onChange fires each time any of them flip.
        .onChange(of: initialSyncKey) { _, _ in tryDismissInitialLoading() }
        .fullScreenCover(isPresented: $showInitialEPGLoading) {
            InitialEPGLoadingView(statusText: initialLoadingStatusText)
                .interactiveDismissDisabled()
        }
        // Pre-fetch VOD data whenever the VOD server list changes.
        // Delay VOD loading so it doesn't compete with channel loading on remote servers.
        .task(id: vodServerKey) {
            debugLog("🔶 MainTabView.task(vodServerKey): firing, servers=\(allServers.count)")
            // Wait for channels to finish loading first to avoid overwhelming remote servers
            while channelStore.isLoading {
                try? await Task.sleep(for: .milliseconds(500))
            }
            vodStore.refresh(servers: allServers)
            debugLog("🔶 MainTabView.task(vodServerKey): refresh called")
        }
        // Pre-fetch channel list (+ EPG) whenever any server changes.
        // This runs immediately on first appear so the Live TV tab is ready
        // before the user taps it.
        .task(id: channelServerKey) {
            debugLog("🔶 MainTabView.task(channelServerKey): firing, servers=\(allServers.count)")
            channelStore.refresh(servers: allServers)
            debugLog("🔶 MainTabView.task(channelServerKey): refresh called")
            // Wait for channels to finish loading, then load ALL EPG upfront
            while channelStore.isLoading {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !channelStore.channels.isEmpty {
                await channelStore.loadAllEPG()
            }
        }
        // DVR reconcile at tab-bar level so the DVR tab lights up as
        // soon as a Dispatcharr server reports a recording — even if
        // the user scheduled it from the web UI (no local row to
        // trigger MyRecordingsView.task). Runs once on server change,
        // then every 2 minutes while the app is foregrounded. This is
        // cheap: a single GET /api/channels/recordings/ per server.
        .task(id: dvrReconcileKey) {
            // Run one reconcile immediately so the initial loading
            // screen can dismiss as soon as it completes. Then enter
            // the polling loop (every 2 minutes while foregrounded).
            await reconcileAllDispatcharrRecordings()
            didInitialDVRReconcile = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if Task.isCancelled { break }
                await reconcileAllDispatcharrRecordings()
            }
        }
        // Global search — hidden during active playback
        .toolbar {
            if !isPlaying && !nowPlaying.isActive && selectedTab != .settings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
        }
        .liquidGlassTabBar()
        #if os(tvOS)
        .onExitCommand {
            if nowPlaying.isActive && !nowPlaying.isMinimized {
                debugLog("🎮 Menu pressed: full-screen player → minimize to corner")
                withAnimation(.spring(response: 0.35)) { nowPlaying.minimize() }
            } else if nowPlaying.isActive && nowPlaying.isMinimized {
                debugLog("🎮 Menu pressed: mini player → stop playback")
                nowPlaying.stop()
            } else if isVODDetailPushed {
                // Pop the VOD detail view back to the browse list.
                // We must do this programmatically because .onExitCommand consumes
                // the Menu event before NavigationStack can handle it.
                debugLog("🎮 Menu pressed: VOD detail pushed → popping to browse list")
                isVODDetailPushed = false
                vodNavPopRequested = true
            } else if selectedTab == .liveTV {
                debugLog("🎮 Menu pressed: Live TV tab → show exit confirmation")
                showExitConfirmation = true
            } else {
                debugLog("🎮 Menu pressed: \(selectedTab.rawValue) tab → switch to Live TV")
                selectedTab = .liveTV
            }
        }
        .onPlayPauseCommand {
            if nowPlaying.isMinimized {
                debugLog("🎮 Play/Pause pressed: expand mini player to full screen")
                withAnimation(.spring(response: 0.35)) { nowPlaying.expand() }
            }
        }
        .alert("Exit AerioTV?", isPresented: $showExitConfirmation) {
            Button("Exit", role: .destructive) {
                nowPlaying.stop()
                NowPlayingBridge.shared.teardown()
                exit(0)
            }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopPlaybackForBackground)) { _ in
            if nowPlaying.isActive {
                debugLog("🎮 Background: stopping playback")
                nowPlaying.stop()
                NowPlayingBridge.shared.teardown()
            }
        }
        // Top Shelf deep link for a channel → switch to Live TV tab.
        // ChannelListView itself handles starting playback once channels are loaded.
        .onReceive(NotificationCenter.default.publisher(for: .aerioOpenChannel)) { _ in
            debugLog("🔗 MainTabView: aerioOpenChannel → switch to Live TV tab")
            withAnimation { selectedTab = .liveTV }
        }
        // Top Shelf deep link for a VOD item → switch to On Demand tab.
        // OnDemandView handles the Movies/Series segment switch internally.
        .onReceive(NotificationCenter.default.publisher(for: .aerioOpenVOD)) { notif in
            guard let vodType = notif.userInfo?["vodType"] as? String else { return }
            let target: AppTab = .onDemand
            debugLog("🔗 MainTabView: aerioOpenVOD(\(vodType)) → switch to \(target.rawValue) tab")
            withAnimation { selectedTab = target }
        }
        #endif
    }

    private func configureTabBarAppearance() {
        debugLog("🔶 MainTabView.configureTabBarAppearance: thread=\(Thread.current)")
#if os(iOS)
        guard theme.liquidGlassStyle == .disabled else { return }
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(theme.background)

        let normal = UITabBarItemAppearance()
        normal.normal.iconColor = UIColor(Color.textSecondary)
        normal.normal.titleTextAttributes = [.foregroundColor: UIColor(Color.textSecondary)]
        normal.selected.iconColor = UIColor(theme.accent)
        normal.selected.titleTextAttributes = [.foregroundColor: UIColor(theme.accent)]
        appearance.stackedLayoutAppearance = normal

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
#endif
    }
}


#if os(iOS)
// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    let item: ChannelDisplayItem
    @ObservedObject var nowPlaying: NowPlayingManager
    @Binding var dragOffset: CGFloat

    private func expand() {
        let screenH = UIScreen.main.bounds.height
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            dragOffset = -screenH
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            nowPlaying.expand()
            dragOffset = 0
        }
    }

    private func progressFraction(start: Date, end: Date, now: Date) -> CGFloat {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(max(0, min(1, now.timeIntervalSince(start) / total)))
    }

    private func programSubtitle(program: String, start: Date?, end: Date?, now: Date) -> String {
        guard let end else { return program }
        let remaining = max(0, end.timeIntervalSince(now))
        let mins = Int(remaining / 60)
        if mins <= 0 { return "\(program) · Ending soon" }
        if mins < 60 { return "\(program) · \(mins)m left" }
        let h = mins / 60; let m = mins % 60
        let timeStr = m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
        return "\(program) · \(timeStr)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Liquid glass drag handle
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 6)

            HStack(spacing: 12) {
                // Channel logo or placeholder
                AsyncImage(url: item.logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    default:
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentPrimary.opacity(0.15))
                                .frame(width: 40, height: 28)
                            Image(systemName: "tv.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.accentPrimary)
                        }
                    }
                }

                // Channel name + current program + progress
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.headlineSmall)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)

                        if let program = item.currentProgram, !program.isEmpty {
                            Text(programSubtitle(program: program,
                                                 start: item.currentProgramStart,
                                                 end: item.currentProgramEnd,
                                                 now: context.date))
                                .font(.labelSmall)
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)

                            if let start = item.currentProgramStart,
                               let end = item.currentProgramEnd {
                                let progress = progressFraction(start: start, end: end, now: context.date)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.12))
                                            .frame(height: 3)
                                        Capsule()
                                            .fill(Color.accentPrimary.opacity(0.7))
                                            .frame(width: geo.size.width * progress, height: 3)
                                    }
                                }
                                .frame(height: 3)
                            }
                        } else {
                            Text("Live TV")
                                .font(.labelSmall)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }

                Spacer()

                // Stop / close — has its own tap area so it doesn't trigger the bar tap
                Button {
                    nowPlaying.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.textTertiary)
                }
                #if os(tvOS)
                .buttonStyle(TVNoHighlightButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentPrimary.opacity(0.25))
                .frame(height: 1)
        }
        // Tap anywhere on the bar (except the X) to expand
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        // Drag up — synced with the PlayerView so the video follows the finger
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height < 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height < -40 {
                        expand()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}
#endif

// MARK: - Initial EPG Loading View
/// Full-screen loading view shown while initial channels + EPG + VOD
/// + DVR data syncs. Dismissed automatically once every phase is
/// finished so the user never lands in a half-populated List / Guide.
struct InitialEPGLoadingView: View {
    /// Current phase, e.g. "Loading channels", "Downloading program
    /// guide", "Loading movies & series", "Syncing recordings". The
    /// parent (MainTabView) computes this from the live store flags.
    let statusText: String

    @ObservedObject private var theme = ThemeManager.shared
    @State private var dots = ""
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "tv.and.mediabox")
                    .font(.system(size: 64))
                    .foregroundColor(theme.accent)

                Text("Setting Up")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text("\(statusText)\(dots)")
                    .font(.system(size: 18))
                    .foregroundColor(.textSecondary)
                    .frame(width: 400, alignment: .center)
                    .animation(.easeInOut(duration: 0.2), value: statusText)

                ProgressView()
                    .progressViewStyle(.circular)
                    #if os(tvOS)
                    .scaleEffect(1.5)
                    #endif
                    .tint(theme.accent)
                    .padding(.top, 8)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [self] _ in
                Task { @MainActor in
                    dots = dots.count >= 3 ? "" : dots + "."
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
