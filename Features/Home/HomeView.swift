import SwiftUI
import SwiftData
import Foundation

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

        let now = Date()

        switch type {
        case .dispatcharrAPI:
            // Dispatcharr: one bulk call via /api/epg/grid/ — all channels, -1h to +24h
            do {
                let dAPI = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))
                let programs = try await dAPI.getEPGGrid()
                // Group by tvgID and populate EPGCache
                var byTvgID: [String: [EPGEntry]] = [:]
                for p in programs {
                    guard let start = p.startTime?.toDate(), let end = p.endTime?.toDate(),
                          end > now else { continue }
                    let key = p.tvgID ?? (p.channel.map { "ch_\($0)" } ?? "")
                    guard !key.isEmpty else { continue }
                    let entry = EPGEntry(title: p.title, description: p.description, startTime: start, endTime: end)
                    byTvgID[key, default: []].append(entry)
                }
                // Sort each channel's programs by start time and cache them
                for (tvgID, entries) in byTvgID {
                    let sorted = entries.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
                    await EPGCache.shared.set(sorted, for: "d_\(baseURL)_\(tvgID)")
                }
                debugLog("📺 Bulk EPG loaded: \(programs.count) programs across \(byTvgID.count) channels")
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

    /// App Group suite name — shared with the Top Shelf extension.
    static let appGroupID = "group.app.molinete.Dispatcharr"
    private var sharedDefaults: UserDefaults? { UserDefaults(suiteName: Self.appGroupID) }

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

    /// Writes favorite channel info to shared UserDefaults for the Top Shelf extension.
    private func syncToSharedDefaults() {
        #if os(tvOS)
        guard let shared = sharedDefaults else { return }
        let entries: [[String: String]] = favoriteItems.map { item in
            var entry: [String: String] = [
                "id": item.id,
                "name": item.name,
                "number": item.number
            ]
            if let logo = item.logoURL?.absoluteString { entry["logoURL"] = logo }
            return entry
        }
        shared.set(entries, forKey: "topShelfFavorites")
        #endif
    }
}

// MARK: - Now Playing Manager
@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()
    @Published var playingItem: ChannelDisplayItem? = nil
    @Published var playingHeaders: [String: String] = [:]
    @Published var isMinimized: Bool = false

    var isActive: Bool { playingItem != nil }

    func startPlaying(_ item: ChannelDisplayItem, headers: [String: String]) {
        debugLog("🎮 NowPlaying.startPlaying: \(item.name) (id=\(item.id)), wasMinimized=\(isMinimized), wasPlaying=\(playingItem?.name ?? "nil")")
        playingItem = item
        playingHeaders = headers
        isMinimized = false
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
    case movies    = "movies"
    case tv        = "tv"
    case settings  = "settings"

    var title: String {
        switch self {
        case .liveTV:    return "Live TV"
        case .favorites: return "Favorites"
        case .movies:    return "Movies"
        case .tv:        return "Series"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .liveTV:    return "antenna.radiowaves.left.and.right"
        case .favorites: return "star.fill"
        case .movies:    return "film.stack"
        case .tv:        return "tv"
        case .settings:  return "gearshape.fill"
        }
    }
}

// MARK: - Main Tab View
struct MainTabView: View {
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    @ObservedObject private var theme = ThemeManager.shared
    @Query private var allServers: [ServerConnection]

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
    @StateObject private var nowPlaying = NowPlayingManager.shared
    @StateObject private var favoritesStore = FavoritesStore.shared
    @StateObject private var vodStore = VODStore()
    @StateObject private var channelStore = ChannelStore.shared
    @AppStorage("hasCompletedInitialEPG") private var hasCompletedInitialEPG = false
    @State private var showInitialEPGLoading = false

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
                        isLive: true,
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
                            isLive: true,
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
                        if minimized {
                            VStack {
                                Spacer().frame(height: miniH + 48) // Below the video
                                Button {
                                    nowPlaying.stop()
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.trailing, 40)
                        }
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

            MoviesView(vodStore: vodStore, isPlaying: $isPlaying, isDetailPushed: $isVODDetailPushed, popRequested: $vodNavPopRequested)
                .tabItem { Label(AppTab.movies.title, systemImage: AppTab.movies.icon) }
                .tag(AppTab.movies)

            TVShowsView(vodStore: vodStore, isPlaying: $isPlaying, isDetailPushed: $isVODDetailPushed, popRequested: $vodNavPopRequested)
                .tabItem { Label(AppTab.tv.title, systemImage: AppTab.tv.icon) }
                .tag(AppTab.tv)

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
            // Show EPG loading screen only if the active server has EPG data to load.
            // M3U without EPG URL has nothing to fetch — skip the loading screen.
            let activeServer = allServers.first(where: { $0.isActive }) ?? allServers.first
            let hasEPG: Bool = {
                guard let s = activeServer else { return false }
                if s.type == .m3uPlaylist { return !s.epgURL.isEmpty }
                return true  // Dispatcharr and Xtream always have EPG
            }()
            if hasEPG {
                showInitialEPGLoading = true
            }
            debugLog("🔶 MainTabView.onAppear: done")
        }
        // Dismiss EPG loading screen once EPG finishes downloading
        .onChange(of: channelStore.isEPGLoading) { _, loading in
            if !loading && showInitialEPGLoading && !channelStore.channels.isEmpty {
                withAnimation(.easeOut(duration: 0.4)) {
                    showInitialEPGLoading = false
                }
                debugLog("🔶 EPG download complete — dismissing loading screen")
            }
        }
        .fullScreenCover(isPresented: $showInitialEPGLoading) {
            InitialEPGLoadingView()
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
        .alert("Exit Aerio?", isPresented: $showExitConfirmation) {
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
/// Full-screen loading view shown on first install while EPG data downloads.
/// Dismissed automatically once the download completes.
struct InitialEPGLoadingView: View {
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

                Text("Loading Guide")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.textPrimary)

                Text("Downloading program guide\(dots)")
                    .font(.system(size: 18))
                    .foregroundColor(.textSecondary)
                    .frame(width: 350, alignment: .center)

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
