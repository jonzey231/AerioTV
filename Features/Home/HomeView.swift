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
    /// True for the FULL duration of a `loadMovies` call, including
    /// the per-category streaming pass that keeps running after the
    /// first partial results publish. Distinct from `isLoadingMovies`
    /// (which intentionally flips to `false` at the first batch so
    /// `MoviesView` can drop its spinner and start showing items).
    /// Drives the top-level "Syncing…" indicator so users know the
    /// background fetch is still chewing through categories — we
    /// saw the indicator hide while 700+ categories were still
    /// loading, which left no signal that the cascade of
    /// `@Published movies =` writes would keep triggering view
    /// invalidations for another minute-plus.
    @Published private(set) var isRefillingMovies = false
    @Published private(set) var moviesError: String?

    @Published private(set) var series: [VODDisplayItem] = []
    @Published private(set) var seriesCategories: [VODCategory] = []
    @Published private(set) var isLoadingSeries = false
    /// Series equivalent of `isRefillingMovies` — true for the whole
    /// `loadSeries` run.
    @Published private(set) var isRefillingSeries = false
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

    /// Detects whether an error is specifically a request timeout
    /// (URLError.timedOut / NSURLErrorTimedOut). Used by the VOD
    /// circuit breaker so we only abort on server-unresponsive signals
    /// and keep going through transient 4xx/5xx-style failures.
    fileprivate static func isTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        // APIError doesn't wrap URLError directly; fall back on the
        // description string for its `.serverError`/`.networkError`
        // cases that get constructed from underlying URLErrors.
        return nsError.localizedDescription.lowercased().contains("timed out")
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
        // v1.6.12: also filter by per-server `vodEnabled`. Users with
        // a "main + sandbox" Dispatcharr setup can disable VOD on the
        // sandbox to avoid duplicate fetches and the multi-minute
        // grid wait. Active server with `vodEnabled == false` clears
        // VOD content (same shape as a non-VOD-capable type).
        if let active = activeServer, !active.vodEnabled {
            debugLog("🎬 VODStore.loadMovies: active server has vodEnabled=false, clearing")
            movies = []; movieCategories = []
            isLoadingMovies = false; moviesError = nil
            lastMoviesServerName = nil; currentMoviesServerID = nil
            return
        }
        let vodServers = servers.filter { $0.supportsVOD && $0.vodEnabled }
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
        // `defer` guarantees `isRefillingMovies` returns to false on
        // every exit path — normal loop completion, circuit-breaker
        // abort, `Task.isCancelled` early return, per-server-type
        // branches — without sprinkling resets across each one.
        isRefillingMovies = true
        defer { isRefillingMovies = false }
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

            // Fetch categories from the dedicated endpoint and filter to
            // the ones the user has actually enabled on at least one
            // M3U account. Dispatcharr's `/api/vod/categories/` returns
            // EVERY category it ever saw from the provider (467+ on
            // typical IPTV feeds), including ones the user toggled off
            // in the admin UI's M3U Group Filter. Without the
            // `isEnabledOnAnyAccount` gate we'd display XXX / foreign-
            // language / archived-year buckets that have zero fetchable
            // content — which is GH #1's primary complaint. Matches
            // Dispatcharr's own behaviour: the REST API returns movies
            // only for categories the user enabled for ingest, so the
            // client should show only the same set.
            let apiCats: [DispatcharrVODCategory] = (try? await api.getVODCategories()) ?? []
            let enabledMovieCats = apiCats.filter {
                ($0.categoryType == "movie" || $0.categoryType == "Movie") && $0.isEnabledOnAnyAccount
            }
            debugLog("🎬 VODStore: \(apiCats.count) total categories, \(enabledMovieCats.count) enabled movie categories")

            // Show the category list in Manage Groups immediately so the
            // user sees the real, accurate group list even before movie
            // streaming finishes.
            movieCategories = enabledMovieCats.map { VODCategory(id: String($0.id), name: $0.name) }

            // If the user has no movie categories enabled anywhere, the
            // library is empty by construction. Don't fall back to a
            // flat unfiltered fetch — that was the old bug where we'd
            // show everything Dispatcharr had.
            if enabledMovieCats.isEmpty {
                movies = []
                isLoadingMovies = false
                debugLog("🎬 VODStore.loadMovies: no enabled movie categories, nothing to fetch")
                return
            }

            // v1.6.17 — single-fetch, group client-side by
            // `custom_properties.category_id`. Pre-1.6.17 we iterated
            // each enabled category and called
            // `/api/vod/movies/?category=<name>` in a loop, deduping
            // by uuid. That worked on Archie's Dispatcharr where the
            // `?category=` filter was effectively ignored (each
            // request returned the FULL library, dedup made it look
            // like per-category isolation). On a stricter Dispatcharr
            // build (verified against
            // dispatcharr-freynas.frey-home.synology.me on
            // 2026-04-29 — see release notes for the four-test
            // matrix), the same `?category=Action` query returns
            // `count: 0` because the filter expects something the
            // categories endpoint never tells us. The Series/Movie
            // schemas have NO top-level category field at all; the
            // only place a VOD item's category appears in the list
            // response is `custom_properties.category_id`.
            //
            // Switching to a single unfiltered `/api/vod/movies/?page_size=25`
            // sweep + client-side filter is therefore the only
            // approach that's correct on both lenient and strict
            // builds. Total HTTP volume is comparable (the per-cat
            // loop was redundantly fetching the same pages on
            // Archie's setup anyway), and as a bonus each item now
            // gets tagged with its ACTUAL category — pre-1.6.17 the
            // outer-loop variable owned the tag, so an item in two
            // enabled categories was credited to whichever ran first.
            var enabledByID: [String: VODCategory] = [:]
            for cat in enabledMovieCats {
                enabledByID[String(cat.id)] = VODCategory(id: String(cat.id), name: cat.name)
            }
            // v1.6.17 — fallback bucket for movies that arrive without
            // a `custom_properties.category_id`. Empirically Dispatcharr
            // serializes that field for series (every list item carries
            // it) but NOT for movies (most items have a null/sparse
            // `custom_properties` blob on the list endpoint). The
            // filter-by-category and per-movie provider-info paths are
            // both broken or unviable (see comment in `loadSeries` for
            // the matrix). To avoid showing an empty Movies grid on a
            // server with thousands of movies that we just can't map
            // to one of the user's enabled categories, fall back to
            // the FIRST enabled category — matches the v1.6.16 behavior
            // exactly, where the broken `?category=` filter was being
            // ignored and the dedup picked the first enabled category
            // for every movie. The user sees content; per-category
            // grouping for movies on these servers is best-effort.
            let fallbackCategory: VODCategory? = enabledMovieCats.first.map {
                VODCategory(id: String($0.id), name: $0.name)
            }

            var accumulated: [VODDisplayItem] = []
            var seenUUIDs: Set<String> = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 0.5
            var taggedFromCategoryID = 0
            var taggedFromFallback = 0
            debugLog("🎬 VODStore.loadMovies: starting unfiltered stream fetch — will tag by custom_properties.category_id when present, else fall back to first enabled category (\(enabledMovieCats.count) total)")

            do {
                for try await batch in api.getVODMoviesStream(category: nil) {
                    guard !Task.isCancelled else { isLoadingMovies = false; return }
                    for m in batch {
                        // Resolve category: prefer the per-item
                        // category_id when Dispatcharr supplies one;
                        // otherwise use the user's first enabled
                        // category as the bucket. Drop only when the
                        // user has zero enabled categories — and that
                        // case was already short-circuited above.
                        let category: VODCategory
                        if let catID = m.customProperties?.categoryID,
                           let resolved = enabledByID[catID] {
                            category = resolved
                            taggedFromCategoryID += 1
                        } else if let fallback = fallbackCategory {
                            category = fallback
                            taggedFromFallback += 1
                        } else {
                            continue
                        }
                        guard seenUUIDs.insert(m.uuid).inserted else { continue }
                        let streamURL = api.proxyMovieURL(
                            uuid: m.uuid,
                            preferredStreamID: m.streams?.first?.streamID
                        )
                        let movie = VODMovie(
                            id: String(m.id), name: m.title,
                            posterURL: m.posterURL.flatMap { resolveURL($0, base: baseURL) },
                            backdropURL: nil,
                            rating: m.rating ?? "", plot: m.plot ?? "",
                            genre: m.genre ?? "", releaseDate: "", duration: "",
                            cast: "", director: "", imdbID: "",
                            categoryID: category.id,
                            categoryName: category.name,
                            streamURL: streamURL, containerExtension: "mp4",
                            serverID: sID
                        )
                        accumulated.append(VODDisplayItem(movie: movie))
                    }
                    // Throttle publishing to max 2x/second to reduce
                    // SwiftUI redraws. Always publish on first batch
                    // to hide the spinner.
                    let now = Date()
                    if isLoadingMovies || now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        movies = accumulated
                        lastPublishTime = now
                    }
                    if isLoadingMovies { isLoadingMovies = false }
                }
            } catch let err as APIError {
                DebugLogger.shared.logError(err, context: "VODStore.loadMovies(\(server.name))")
                moviesError = err.errorDescription
            } catch {
                DebugLogger.shared.log(
                    "VODStore.loadMovies(\(server.name)) error: \(error.localizedDescription)",
                    category: "Movies", level: .warning
                )
            }

            movies = accumulated
            isLoadingMovies = false
            debugLog("🎬 VODStore.loadMovies: done, \(accumulated.count) movies (tagged via category_id=\(taggedFromCategoryID), via fallback=\(taggedFromFallback))")
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
        // v1.6.12: per-server VOD toggle — see `loadMovies` for the
        // rationale. Active server with `vodEnabled == false` clears
        // series state the same way a non-VOD-capable server does.
        if let active = activeServer, !active.vodEnabled {
            debugLog("📺 VODStore.loadSeries: active server has vodEnabled=false, clearing")
            series = []; seriesCategories = []
            isLoadingSeries = false; seriesError = nil
            lastSeriesServerName = nil; currentSeriesServerID = nil
            return
        }
        let vodServers = servers.filter { $0.supportsVOD && $0.vodEnabled }
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
        // See `isRefillingMovies` for the rationale. `defer`
        // guarantees we return to false on every exit path.
        isRefillingSeries = true
        defer { isRefillingSeries = false }
        seriesError = nil
        DebugLogger.shared.log("VODStore loadSeries — \(server.name) (\(server.type.rawValue)) url=\(server.effectiveBaseURL)",
                               category: "TVShows", level: .info)

        if server.type == .dispatcharrAPI {
            let baseURL = server.effectiveBaseURL
            let apiKey  = server.effectiveApiKey
            let sID     = server.id
            let api     = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))

            // Mirrors `loadMovies` above — see that function for the
            // full rationale on why per-enabled-category fetching +
            // first-category-wins deduping is the shape of the fix.
            let apiCats: [DispatcharrVODCategory] = (try? await api.getVODCategories()) ?? []
            let enabledSeriesCats = apiCats.filter {
                ($0.categoryType == "series" || $0.categoryType == "Series") && $0.isEnabledOnAnyAccount
            }
            debugLog("📺 VODStore: \(apiCats.count) total categories, \(enabledSeriesCats.count) enabled series categories")

            seriesCategories = enabledSeriesCats.map { VODCategory(id: String($0.id), name: $0.name) }

            if enabledSeriesCats.isEmpty {
                series = []
                isLoadingSeries = false
                debugLog("📺 VODStore.loadSeries: no enabled series categories, nothing to fetch")
                return
            }

            // v1.6.17 — single-fetch + group client-side. See the
            // identical block in `loadMovies` for the full rationale.
            // tl;dr: Dispatcharr's documented `?category=<string>`
            // filter is broken on stricter builds and silently ignored
            // on lenient ones; the only place a series's category
            // reliably appears in the list response is
            // `custom_properties.category_id`.
            var enabledByID: [String: VODCategory] = [:]
            for cat in enabledSeriesCats {
                enabledByID[String(cat.id)] = VODCategory(id: String(cat.id), name: cat.name)
            }

            var accumulated: [VODDisplayItem] = []
            var seenUUIDs: Set<String> = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 0.5
            debugLog("📺 VODStore.loadSeries: starting unfiltered stream fetch — will keep items whose category_id matches one of \(enabledSeriesCats.count) enabled categories")

            do {
                for try await batch in api.getVODSeriesStream(category: nil) {
                    guard !Task.isCancelled else { isLoadingSeries = false; return }
                    for s in batch {
                        guard let catID = s.customProperties?.categoryID,
                              let category = enabledByID[catID] else { continue }
                        guard seenUUIDs.insert(s.uuid).inserted else { continue }
                        let show = VODSeries(
                            id: String(s.id), name: s.name,
                            posterURL: s.posterURL.flatMap { resolveURL($0, base: baseURL) },
                            backdropURL: nil,
                            rating: s.rating ?? "", plot: s.plot ?? "",
                            genre: s.genre ?? "", releaseDate: "",
                            cast: "", director: "",
                            categoryID: category.id,
                            categoryName: category.name,
                            serverID: sID, seasons: [], episodeCount: 0
                        )
                        accumulated.append(VODDisplayItem(series: show))
                    }
                    let now = Date()
                    if isLoadingSeries || now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        series = accumulated
                        lastPublishTime = now
                    }
                    if isLoadingSeries { isLoadingSeries = false }
                }
            } catch let err as APIError {
                DebugLogger.shared.logError(err, context: "VODStore.loadSeries(\(server.name))")
                seriesError = err.errorDescription
            } catch {
                DebugLogger.shared.log(
                    "VODStore.loadSeries(\(server.name)) error: \(error.localizedDescription)",
                    category: "TVShows", level: .warning
                )
            }

            series = accumulated
            isLoadingSeries = false
            debugLog("📺 VODStore.loadSeries: done, \(accumulated.count) series across \(enabledSeriesCats.count) enabled categories")
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
        // v1.6.13.x: idempotent guard. AppEntryView fires `refresh` from
        // its `.onAppear` (during the splash) so the channel network
        // fetch overlaps the 2.8s splash animation. Then MainTabView's
        // `.task(channelServerKey)` fires `refresh` AGAIN once the
        // splash dismisses. Without this guard the second call would
        // cancel the in-flight network request and re-issue it from
        // scratch — wiping out the head start. With it, the second
        // call is a no-op when a load is already in progress (or
        // complete) for the same server.
        if let task = loadTask, !task.isCancelled,
           currentChannelServerID == server.id,
           (isLoading || !channels.isEmpty) {
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

    /// UserDefaults key for the cached channel→category map. Cached
    /// on every successful XMLTV categories pass so subsequent app
    /// launches can render the "Tint Channel Cards" gradient
    /// immediately, before the (multi-second) XMLTV fetch+parse has
    /// even started. Without this cache, users saw channel cards
    /// pop in tintless on every launch and the color faded in
    /// ~5–10 seconds later — which is what the #22 feedback
    /// ("gradients took way too long to load") called out.
    private static let cachedCategoriesKey = "cachedChannelCategories.v1"

    /// Snapshot of the last-known channel→category map. Written by
    /// `applyXMLTVCategories` after a fresh pass lands, read by
    /// `primeCategoriesFromCache()` on the next cold load so the
    /// tint renders on the first frame instead of 5–10 s later.
    private static func loadCachedCategories() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: cachedCategoriesKey) as? [String: String] ?? [:]
    }

    private static func saveCachedCategories(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: cachedCategoriesKey)
    }

    /// Apply whatever category data we have cached from the last
    /// XMLTV pass so the tint stripe renders immediately on cold
    /// launch. The fresh XMLTV pass still runs in `loadAllEPG` and
    /// overwrites with current data — this just means the user
    /// doesn't stare at an uncolored card while the XMLTV parse
    /// churns. Call from the channel-load success path.
    func primeCategoriesFromCache() {
        let cached = Self.loadCachedCategories()
        guard !cached.isEmpty else { return }
        applyXMLTVCategories(cached)
    }

    /// Called by `GuideStore` when an XMLTV parse surfaces category
    /// data. Channel cards in Live TV list view read
    /// `currentProgramCategory` to drive the "Tint Channel Cards"
    /// stripe, but the initial channel load uses Dispatcharr's JSON
    /// API which doesn't include categories — so we back-fill here
    /// from the guide's XMLTV pass. Only updates channels whose
    /// stored category differs, to avoid spurious @Published fires
    /// on every EPG refresh.
    ///
    /// Also writes the map through to UserDefaults so the next
    /// cold launch can `primeCategoriesFromCache()` and render the
    /// tint immediately instead of waiting on the XMLTV fetch.
    func applyXMLTVCategories(_ categoriesByChannelID: [String: String]) {
        guard !categoriesByChannelID.isEmpty else { return }
        var changed = false
        var updated = channels
        for i in updated.indices {
            if let cat = categoriesByChannelID[updated[i].id],
               updated[i].currentProgramCategory != cat {
                updated[i].currentProgramCategory = cat
                changed = true
            }
        }
        if changed {
            channels = updated
        }
        // Persist so the next app launch can prime the tint from
        // cache on the first frame. Merging into the existing cache
        // rather than replacing means a partial XMLTV pass (e.g.,
        // parser errored halfway) doesn't wipe previously-known
        // categories for channels it didn't cover.
        var merged = Self.loadCachedCategories()
        for (id, cat) in categoriesByChannelID {
            merged[id] = cat
        }
        Self.saveCachedCategories(merged)
    }

    /// Mirror of `EPGGuideView.fetchDispatcharr`'s URL-construction
    /// logic. Returns the URL AerioTV should pull XMLTV from for a
    /// Dispatcharr server — the user's explicit override if set,
    /// otherwise the derived `{base}/output/epg?tvg_id_source=tvg_id`
    /// default that emits categories and tvg_id-keyed channels.
    /// Returns nil when there's nothing sane to fetch (empty or
    /// malformed base URL).
    static func dispatcharrXMLTVURL(baseURL: String, override: String) -> URL? {
        let explicit = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty, let url = URL(string: explicit) {
            return url
        }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/output/epg?tvg_id_source=tvg_id")
    }

    /// Full XMLTV pass that feeds the SAME `GuideStore.programs`
    /// dataset the Guide view reads from — so Live-TV list rows
    /// (current-program tint) AND the expanded schedule panel
    /// (per-upcoming-program tint) share one source of truth with
    /// the Guide view's tinted cells. Previously List view re-
    /// derived categories from JSON (which has none), producing
    /// the "Guide shows colors, List doesn't" asymmetry users
    /// rightly called out ("they should both be using the same
    /// dataset").
    ///
    /// Runs on every platform. On iPad / Mac where EPGGuideView
    /// eventually mounts, the view's own fetchXMLTVFromURL call
    /// becomes a refresh (the merge logic in `mergeProgram`
    /// dedupes by title + time). On iPhone this is the only
    /// XMLTV pass that happens — which is exactly why we need it
    /// here.
    func primeXMLTVFromURL(_ url: URL) async {
        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        let epgWindowHours = UserDefaults.standard.integer(forKey: "epgWindowHours")
        let effectiveWindowHours = epgWindowHours > 0 ? epgWindowHours : 36
        let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)

        // Snapshot channels + server on the main actor before
        // handing off — GuideStore's XMLTV method is @MainActor
        // too and will re-dispatch, but snapshotting here keeps
        // the call site sync-clean.
        let snapshot = channels
        guard let activeServer = activeServer else { return }

        await GuideStore.shared.fetchXMLTVFromURL(
            url: url,
            channels: snapshot,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        // Propagate into EPGCache so List-view `fetchUpcoming`
        // (which reads EPGCache) picks up category-enriched
        // EPGEntry items instead of the JSON-sourced, category-
        // empty entries. This is what makes expanded schedule
        // rows tintable on iPhone the same way Guide cells are
        // tintable on iPad / tvOS.
        //
        // `await` here is load-bearing: `seedEPGCache` does its
        // writes on a detached utility-priority task, so without
        // awaiting its `.value` we'd return while the EPGCache
        // set-loop was still running. The ServerSyncView cover
        // would dismiss, the user would expand a channel, and
        // `fetchUpcoming` would hit EPGCache before the seed had
        // overwritten the JSON-bulk's category-less entries —
        // leaving rows uncolored. Awaiting ensures the category
        // data is actually in-place before we return.
        await GuideStore.shared.seedEPGCache(channels: snapshot, server: activeServer)

        // Let any currently-expanded schedule panels know the
        // category data has landed so they can re-fetch with
        // the freshly-seeded EPGCache. Without this, a user who
        // expanded a card BEFORE `loadAllEPG` completed (e.g.,
        // during the second-launch fast path where channels
        // hydrate instantly from cache) would keep staring at
        // non-tinted rows until they manually collapsed and
        // re-expanded.
        NotificationCenter.default.post(name: .epgCategoriesDidUpdate, object: nil)
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

        // Fast reachability probe (only on a cold load). A dead Docker
        // container, a wrong host, or a stopped VPN would otherwise
        // make the user stare at the "Setting Up…" cover for the full
        // 20s URLSession timeout before the error view surfaces.
        // HEAD with a 4s timeout turns that into ~3s with a specific,
        // actionable message. Skipped when we already have cached
        // channels — if the user is refreshing and the probe blips,
        // we don't want to wipe working data over a transient failure.
        if channels.isEmpty {
            if let probeMessage = await Self.reachabilityProbe(baseURL: baseURL) {
                debugLog("🔷 ChannelStore.load: probe failed — \(probeMessage)")
                self.error = probeMessage
                self.isLoading = false
                DebugLogger.shared.logChannelLoad(
                    serverType: type.rawValue,
                    duration: Date().timeIntervalSince(start),
                    error: nil)
                return
            }
            debugLog("🔷 ChannelStore.load: probe ok — starting fetch...")
        } else {
            debugLog("🔷 ChannelStore.load: probe skipped (warm refresh) — starting fetch...")
        }

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
                // Apply any cached categories RIGHT NOW so the tint
                // stripe renders on the first frame channels appear,
                // instead of fading in 5–10 seconds later when the
                // live XMLTV parse wraps. The fresh XMLTV pass in
                // `loadAllEPG` still overwrites with current data.
                primeCategoriesFromCache()
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
            } catch let u as URLError {
                // Full fetch failed with a URL-layer error even though
                // the probe passed (e.g., the server accepts HEAD but
                // hangs on GET, or the route we're hitting isn't up
                // yet). Translate common codes to user-friendly copy
                // instead of surfacing Apple's generic strings.
                if channels.isEmpty {
                    self.error = Self.userFacingURLErrorMessage(u, baseURL: baseURL)
                }
                break
            } catch {
                if channels.isEmpty { self.error = error.localizedDescription }
                break
            }
        }
        isLoading = false
    }

    // MARK: - Reachability Probe

    /// Fast `HEAD`-request probe used at the start of a cold channel
    /// load to short-circuit the 20s URLSession timeout when the
    /// server is completely unreachable (stopped Docker container,
    /// wrong IP, LAN-blocking VPN, no network).
    ///
    /// Returns `nil` when the server responds with anything from
    /// 100–599 — a 401, 404, or 405 all prove the network + host are
    /// alive, which is all we care about at this stage. Returns a
    /// user-facing error string otherwise. Callers use the return
    /// value as an early-exit path: a non-nil result means "set this
    /// as the channel-load error and skip the full fetch."
    ///
    /// The 4-second timeout is chosen so:
    ///  - Dead Docker container / wrong IP → fails in ~1s (TCP reset)
    ///  - LAN-unreachable host → fails at 4s instead of at 20s
    ///  - A healthy-but-slow WAN server → usually answers a HEAD well
    ///    inside 4s, so legitimate servers aren't punished by the probe
    private static func reachabilityProbe(baseURL: String) async -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return "Invalid server URL — check Settings → Server."
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "HEAD"

        // One-shot ephemeral session so the probe never contends with
        // the shared Dispatcharr / Xtream sessions' configured
        // timeouts or connection pools.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        do {
            // v1.6.10: route through HTTPRouter so plain-HTTP URLs that
            // URLSession refuses (HSTS preload, ATS dynamic-upgrade,
            // etc.) get a second chance via NWConnection. Without this,
            // every actual API request would succeed via the router's
            // fallback while the probe sees the URLSession -1022 and
            // we mistakenly tell the user the server is unreachable.
            let (_, response) = try await HTTPRouter.data(for: request, using: session)
            // Any HTTP response proves the TCP + TLS + HTTP path is
            // alive. We don't care about the status code here — even
            // a 404 / 405 means the box is up.
            if let http = response as? HTTPURLResponse,
               (100..<600).contains(http.statusCode) {
                return nil
            }
            // Non-HTTPURLResponse shouldn't happen over http(s) but
            // be defensive rather than crash.
            return "Unexpected response from \(hostDescriptor(url)). Check Settings → Server."
        } catch let u as URLError {
            return userFacingURLErrorMessage(u, baseURL: trimmed)
        } catch {
            return "Can't reach \(hostDescriptor(url)): \(error.localizedDescription)"
        }
    }

    /// Maps the common `URLError` codes hit during a dead-server
    /// probe or fetch into short, user-facing copy. We surface the
    /// host so the user has a concrete thing to check (wrong IP vs
    /// wrong port vs just offline), and hint at the likely fix for
    /// each kind of failure. The previous pass through
    /// `error.localizedDescription` produced Apple's generic strings
    /// ("A server with the specified hostname could not be found.")
    /// which users didn't know how to act on.
    private static func userFacingURLErrorMessage(_ error: URLError, baseURL: String) -> String {
        let host = URL(string: baseURL).map(hostDescriptor) ?? baseURL
        switch error.code {
        case .cannotConnectToHost:
            return "Can't reach \(host). Is your server running?"
        case .cannotFindHost, .dnsLookupFailed:
            return "Couldn't find \(host). Check the URL in Settings → Server."
        case .timedOut:
            return "\(host) isn't responding. Check your server and network connection."
        case .notConnectedToInternet:
            return "No internet connection."
        case .networkConnectionLost:
            return "Lost connection to \(host). Check your network and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected:
            return "Secure connection to \(host) failed. Check your server's TLS certificate."
        default:
            return "Can't reach \(host): \(error.localizedDescription)"
        }
    }

    /// Returns `"host:port"` when the URL has a non-default port, or
    /// just `"host"` otherwise. Used in error messages so the user
    /// sees a concrete thing to verify. Falls back to the full URL
    /// string if the `URL` can't produce a host (shouldn't happen
    /// after `URL(string:)` succeeds, but kept for safety).
    private static func hostDescriptor(_ url: URL) -> String {
        guard let host = url.host, !host.isEmpty else {
            return url.absoluteString
        }
        if let port = url.port, ![80, 443].contains(port) {
            return "\(host):\(port)"
        }
        return host
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
        // Snapshot the Dispatcharr XMLTV override early. `server` is
        // a SwiftData model; reading a property after an `await`
        // suspension risks a thread-context violation.
        let dispatcharrXMLTVOverride = server.dispatcharrXMLTVURL

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

            // XMLTV pass through the shared GuideStore so BOTH the
            // Live-TV list tint AND the Guide grid read from one
            // dataset (user feedback: "they should both be using
            // the same dataset"). iPhone never mounts EPGGuideView,
            // so without this call GuideStore.programs would stay
            // empty on phone and the List-view expanded schedule
            // would have no category data to tint with.
            //
            // Awaited (not Task.detached) on purpose: the user
            // specifically asked for the category cache to land
            // "when EPG is loading while ServerSyncView is
            // showing." Since `isEPGLoading` stays true until this
            // function returns, and `MainTabView.initialSyncKey`
            // observes `isEPGLoading`, the ServerSyncView cover
            // now only dismisses after the XMLTV parse has
            // completed and `seedEPGCache` has written
            // category-enriched EPGEntries into EPGCache. Net
            // effect: first frame of Live TV shows all tints
            // (current-program gradient on cards AND per-program
            // gradients on expanded rows) with zero fade-in lag.
            //
            // iPad / Mac / tvOS also hit this path — the later
            // EPGGuideView fetchXMLTVFromURL call is then a
            // dedupe/refresh (the merge logic in `mergeProgram`
            // replaces-by-overlap, so duplicates don't stack).
            if let xmltvURL = Self.dispatcharrXMLTVURL(
                baseURL: baseURL,
                override: dispatcharrXMLTVOverride
            ) {
                await primeXMLTVFromURL(xmltvURL)
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
        // `uniquingKeysWith: { first, _ in first }` so duplicate
        // group names in `groupOrder` (some IPTV resellers ship
        // multiple categories with identical display names) don't
        // trap the way `uniqueKeysWithValues:` would. First
        // occurrence wins — the duplicate just collapses onto
        // the same display position.
        let idx = Dictionary(groupOrder.enumerated().map { ($1, $0) },
                             uniquingKeysWith: { first, _ in first })
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
                    .map {
                        // M3U's upstream XMLTV carries `<category>`
                        // tags — pass them through so the List-view
                        // expanded schedule can render per-program
                        // tints matching what the Guide view shows.
                        EPGEntry(title: $0.title, description: $0.description,
                                 startTime: $0.startTime, endTime: $0.endTime,
                                 category: $0.category)
                    }
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
                    items[idx].currentProgramCategory     = current.category
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

        // Fire channels + groups concurrently. Current-programs was
        // previously fetched here too (as `async let programsFetch =
        // dAPI.getCurrentPrograms()`) to populate `currentProgram`
        // on each ChannelDisplayItem up-front. That call became a
        // major source of server-side load on large Dispatcharr
        // instances — the endpoint does a full-table scan of
        // epg_programs for every channel's now-airing row, which
        // can pin a uwsgi worker for 30-60+s on playlists with
        // thousands of channels. Combined with the 60s URLSession
        // default timeout on our side, a single app launch would
        // hold a worker for the full minute while building a
        // response the client had already given up on.
        //
        // Now: skip it entirely at fetch time. `GuideStore.loadBulkEPG`
        // uses the much cheaper `/api/epg/grid/` endpoint (-1h to
        // +24h in one indexed range query), which also populates
        // EPGCache for the Guide view. The channel list's
        // "now airing" row starts blank and fills in lazily as
        // per-cell prefetch runs (throttled — see
        // EPGGuideView.prefetchIfNeeded).
        debugLog("🔷 ChannelStore.fetchDispatcharr: launching concurrent fetches")
        async let groupsFetch   = dAPI.getChannelGroups()
        async let channelsFetch = dAPI.getChannels()

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
            // Carry the channel's Dispatcharr UUID so the guide's
            // EPG matcher can recognise Dummy EPG entries, which are
            // tagged with `tvg_id = str(channel.uuid)` by the server
            // (see `fetchDispatcharr` in `EPGGuideView.swift`).
            item.uuid = ch.uuid
            // v1.6.8 (Codex A2): carry the numeric channel ID
            // explicitly so `RecordProgramSheet` doesn't have to
            // string-parse `item.id` to build a Dispatcharr
            // recording request.
            item.dispatcharrChannelID = ch.id
            // v1.6.18: stream IDs for the Stream Info overlay's
            // server-side stats fetch. `ch.streams` is `[Int]?` —
            // typically a single primary plus optional failovers.
            item.dispatcharrStreamIDs = ch.streams
            return item
        }
        items = sortChannels(items, groupOrder: groupOrder)

        // Current-program enrichment used to live here (populated
        // from the removed `getCurrentPrograms()` call above). It
        // now happens lazily via the EPG guide's bulk grid fetch
        // plus per-cell prefetch, so we just return the channels
        // without now-airing data at load time.

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

    /// UserDefaults key persisting the user's manually-chosen favorite ordering.
    /// Mirrored to iCloud KVS via `SyncManager` so the order rides along
    /// with the membership set.
    static let orderKey = "favoriteOrder"

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
            // Append at the end so newly-favorited channels show up after the
            // user's manually-ordered list rather than getting alphabetically
            // shuffled into the middle.
            favoriteItems.append(item)
        }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "favoriteChannelIDs")
        persistOrder()
        syncToSharedDefaults()
        // Favorites are a deliberate user action — push to iCloud KVS
        // immediately instead of the normal 60s debounced preference push.
        // Fixes GitHub issue #2 (Veldmuus): removing a favorite then force-
        // closing the app within 60s would let the next launch's
        // pullFromCloud() restore the stale favorite from KVS.
        SyncManager.shared.pushPreferencesImmediate()
    }

    /// Reorder favorites in response to a SwiftUI `.onMove` from the
    /// iOS Favorites tab. Persists the new order to UserDefaults under
    /// `favoriteOrder` (and SyncManager mirrors that key to iCloud KVS
    /// so the manual order syncs across devices, not just the membership
    /// set under `favoriteChannelIDs`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        favoriteItems.move(fromOffsets: source, toOffset: destination)
        persistOrder()
        syncToSharedDefaults()
        // Same rationale as toggle() — deliberate user action, push now.
        SyncManager.shared.pushPreferencesImmediate()
    }

    /// Called when channels load — hydrates in-memory favorites from fresh item data.
    func register(items: [ChannelDisplayItem]) {
        let filtered = items.filter { favoriteIDs.contains($0.id) }
        let orderedIDs = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        // `uniquingKeysWith: { first, _ in first }` so a corrupted
        // saved order array (duplicate IDs from a reorder race or
        // older bad write) sorts deterministically instead of
        // crashing. First occurrence's index wins.
        let orderIndex = Dictionary(orderedIDs.enumerated().map { ($1, $0) },
                                    uniquingKeysWith: { first, _ in first })
        favoriteItems = filtered.sorted { (a, b) in
            // Items present in the saved order honor that order. Anything not
            // yet ordered (newly favorited on another device, or pre-existing
            // favorites from before this feature shipped) falls through to a
            // stable alphabetical tail so the list isn't randomly shuffled.
            let ai = orderIndex[a.id]
            let bi = orderIndex[b.id]
            switch (ai, bi) {
            case let (a?, b?):
                return a < b
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        // Refresh the persisted order so the next launch sees the merged list
        // (any newly-arrived favorite IDs are now appended in alphabetical
        // order, while previously-ordered IDs keep their position).
        persistOrder()
        syncToSharedDefaults()
    }

    /// Writes the current ordered favorite IDs to UserDefaults under
    /// `favoriteOrder`. SyncManager mirrors this key to iCloud KVS so
    /// the manual order syncs across devices.
    private func persistOrder() {
        let orderedIDs = favoriteItems.map { $0.id }
        UserDefaults.standard.set(orderedIDs, forKey: Self.orderKey)
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

// MARK: - Last Played Tracker (v1.6.13, GH #8)
//
// Persists the last channel started via `NowPlayingManager.startPlaying`
// so the Auto-Resume Last Channel feature in Settings → Appearance →
// App Behaviors can pick up where the user left off on next launch.
//
// Three pieces of state — channel id, server id, isLive — are written
// synchronously to UserDefaults so even a force-quit during playback
// leaves a usable marker. The launch hydration path resolves the
// channel via `ChannelStore.channels.first(where: { $0.id == channelID })`,
// silently giving up if the channel was removed upstream or the
// server was deleted between launches. UserDefaults (not Keychain or
// SwiftData) because the marker is per-device, not credential-class
// data, and we want zero friction on the read path during launch.
//
// Storage is intentionally simple — three keys instead of a single
// JSON-encoded struct — so a malformed value on one key still leaves
// the others readable and makes the data easy to inspect by hand
// (e.g. via `defaults read` for diagnostics).
enum LastPlayedTracker {
    private static let channelIDKey = "lastPlayed.channelID"
    private static let serverIDKey  = "lastPlayed.serverID"
    private static let isLiveKey    = "lastPlayed.isLive"

    struct Marker {
        let channelID: String
        let serverID: UUID
        let isLive: Bool
    }

    /// Snapshot of the most recently started channel + server pair.
    /// `nil` when the user has never started a channel on this
    /// device, or when one of the persisted keys is malformed.
    static var lastPlayed: Marker? {
        let d = UserDefaults.standard
        guard let channelID = d.string(forKey: channelIDKey), !channelID.isEmpty,
              let serverIDStr = d.string(forKey: serverIDKey),
              let serverID = UUID(uuidString: serverIDStr) else {
            return nil
        }
        let isLive = d.object(forKey: isLiveKey) as? Bool ?? true
        return Marker(channelID: channelID, serverID: serverID, isLive: isLive)
    }

    static func record(channelID: String, serverID: UUID, isLive: Bool) {
        let d = UserDefaults.standard
        d.set(channelID, forKey: channelIDKey)
        d.set(serverID.uuidString, forKey: serverIDKey)
        d.set(isLive, forKey: isLiveKey)
    }

    static func clear() {
        let d = UserDefaults.standard
        d.removeObject(forKey: channelIDKey)
        d.removeObject(forKey: serverIDKey)
        d.removeObject(forKey: isLiveKey)
    }
}

// MARK: - Auto-Resume Wiring (v1.6.13)
//
// Consolidates the three auto-resume triggers (cold-launch
// `.onAppear`, channel-list-arrives `.onChange`, warm-resume
// `.onChange(of: scenePhase)`) into a single ViewModifier so
// MainTabView's body stays under Swift's type-checker budget.
// Without this consolidation each `.onChange/.onAppear` is one
// more modifier on body's already-long chain — tvOS x86_64
// hits the heuristic limit and emits "compiler is unable to
// type-check this expression in reasonable time".
private struct AutoResumeWiring: ViewModifier {
    let channelsAreEmpty: Bool
    let scenePhase: ScenePhase
    let onResumeAttempt: () -> Void
    let onScenePhaseChange: (ScenePhase, ScenePhase) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: channelsAreEmpty) { _, isEmpty in
                if !isEmpty { onResumeAttempt() }
            }
            .onAppear { onResumeAttempt() }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                onScenePhaseChange(oldPhase, newPhase)
            }
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

    /// `true` when `PlayerSession.mode == .multiview`. In that state
    /// `playingItem` / `playingHeaders` may still be populated (seed
    /// channel left over from the transition from single to multiview),
    /// but the `MultiviewStore` is authoritative — whichever tile holds
    /// audio drives the lockscreen / remote-command surface via
    /// `NowPlayingBridge`, and this manager's values should NOT also
    /// reach the bridge. Set by `PlayerSession.enterMultiview(...)` /
    /// `.exitMultiviewKeepingAudioTile()` / `.exit()`.
    ///
    /// This flag is the single-switch guard for the Phase 4 HomeView
    /// branch: it tells any future "did NowPlayingManager change →
    /// re-configure bridge" observer to stand down. Today the bridge
    /// is written exclusively from `MPVPlayerView.Coordinator` (which
    /// has its own `tileID` gate), so this flag is currently read-only
    /// / documentary — but it exists so the invariant is queryable
    /// from anywhere without having to also import `PlayerSession`.
    @Published var configuredAsMultiviewAdapter: Bool = false

    /// v1.6.13.x: Absolute (`.global`-coordinate) Y-position of the
    /// corner-mini-player's BOTTOM edge, captured dynamically by an
    /// `.onGeometryChange` on the mini view in `iOSMultiviewWrapper`
    /// / `iOSLegacyPlayerWrapper`. Read by `ChannelListView` to
    /// position the channel-group chip row immediately below the
    /// mini regardless of device chrome (iOS 18 iPad TabView top
    /// tabs add a variable amount of vertical chrome that
    /// `.ignoresSafeArea()` may or may not penetrate, so the mini's
    /// effective bottom isn't reliably `topPadding + height`).
    /// Default 0 means "no measurement yet" — the consumer treats
    /// that as "no push" so layout stays at natural position until
    /// the geometry observer fires.
    @Published var miniPlayerBottomAbs: CGFloat = 0

    /// v1.6.15: stream-start signal — bumped to a fresh UUID inside
    /// `startPlaying(...)` on EVERY live stream begin (cold auto-
    /// resume, channel-row tap, Siri Remote up/down flip). Drives
    /// the `ChannelInfoBanner`'s own 5s auto-hide timer so the
    /// banner appears (without chrome) when the user channel-flips.
    /// Nil at startup = nothing to do.
    @Published var streamStartedToken: UUID? = nil

    /// v1.6.15: chrome-wake signal — bumped only when `wakeChrome ==
    /// true` is passed to `startPlaying(...)`. Live channel-flips
    /// from the Siri Remote pass `wakeChrome: false` so up/down
    /// scrolling doesn't summon the bottom pills (which would put
    /// the next press on the Record button by accident). Other
    /// stream starts (cold-launch auto-resume, channel-row tap)
    /// keep the default `true` so the user sees chrome + banner
    /// together, matching the original "this is a new stream" feel.
    @Published var chromeWakeToken: UUID? = nil

    /// v1.6.15: mirror of whichever player surface (multiview chrome,
    /// legacy PlayerView controls) is currently visible. Driven by
    /// `.onChange(...)` observers on those surfaces. Read by
    /// `ChannelInfoBanner` so its visibility is locked in step with
    /// chrome's auto-fade — banner + chrome appear/disappear together.
    @Published var chromeIsVisible: Bool = false

    /// v1.6.18: mirror of whether the Stream Info overlay is open.
    /// Both the legacy PlayerView and unified MultiviewContainerView
    /// write this when their `showStreamInfo` flips. Read by
    /// `ChannelInfoBanner` to suppress itself while Stream Info is
    /// visible — without this, on iPhone the banner's top-left
    /// position overlaps the Stream Info card's top-left position
    /// and covers the stats the user explicitly opened.
    @Published var streamInfoIsVisible: Bool = false

    /// v1.6.18: most recent channel id the user was actively
    /// watching/listening to. Set on every `startPlaying(...)` call
    /// (single-stream path) and captured from the multiview audio
    /// tile in `PlayerSession.exit()` before the store is reset.
    /// Survives `stop()` so the Live TV guide can default-focus the
    /// row the user JUST exited. Pre-1.6.18 the guide always focused
    /// row 0 after a full multiview exit, which felt random and made
    /// the guide auto-scroll for no apparent reason.
    @Published var lastPlayedChannelID: String? = nil

    var isActive: Bool { playingItem != nil }

    /// v1.6.15: pending steps for the debounced channel-flip helper.
    /// Each Siri Remote up/down press calls `changeChannel(direction:)`
    /// which adds to this counter; the actual channel-load only fires
    /// after a 300ms idle window. Stops rapid presses from queueing
    /// 5 separate stream-loads (which produced the red decode-error
    /// overlay reported in v1.6.15 internal testing).
    private var pendingChannelStep: Int = 0
    private var pendingChannelChangeTask: Task<Void, Never>?

    func startPlaying(_ item: ChannelDisplayItem, headers: [String: String], isLive: Bool = true, wakeChrome: Bool = true) {
        debugLog("🎮 NowPlaying.startPlaying: \(item.name) (id=\(item.id)), isLive=\(isLive), wakeChrome=\(wakeChrome), wasMinimized=\(isMinimized), wasPlaying=\(playingItem?.name ?? "nil")")
        playingItem = item
        // v1.6.18: persistent breadcrumb for guide focus default —
        // see the property docstring above.
        lastPlayedChannelID = item.id
        playingHeaders = headers
        self.isLive = isLive
        isMinimized = false
        // v1.6.15: always bump the stream-start signal for live so
        // the channel-info banner can run its own 5s timer.
        // Optionally also bump the chrome-wake signal — Siri Remote
        // up/down channel-flip passes `wakeChrome: false` because
        // summoning chrome would put the user's next D-pad press on
        // the Record pill by surprise; cold-launch / row-tap keeps
        // the default `true` so chrome + banner come up together.
        if isLive {
            streamStartedToken = UUID()
            if wakeChrome { chromeWakeToken = UUID() }
        }
        // Track watch count for Top Shelf "most watched" ranking
        if isLive { TopShelfDataManager.incrementWatchCount(for: item) }
        // Push into the recents FIFO so the multiview add-sheet's
        // "Recent" section reflects actual watching behavior — not
        // just channels the user added to multiview.
        if isLive { RecentChannelsStore.shared.push(item) }
        // v1.6.13 (GH #8): persist a "last played" marker for the
        // Auto-Resume Last Channel feature in App Behaviors. Synchronous
        // UserDefaults write inside startPlaying so even a force-quit
        // mid-session leaves the marker pointing at the channel the
        // user was just on. The launch hydration in MainTabView reads
        // this back and silently drops it if the channel / server
        // can't be resolved at next launch.
        if let serverID = ChannelStore.shared.activeServer?.id {
            LastPlayedTracker.record(channelID: item.id, serverID: serverID, isLive: isLive)
        }
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

    /// v1.6.15: debounced channel-flip step. Each call accumulates a
    /// signed step (+1 = next channel, -1 = previous) and resets a
    /// 300ms idle timer. When the timer fires, the accumulated step
    /// is applied to the current channel's index in
    /// `ChannelStore.channels`, clamped to the list bounds, and the
    /// new channel starts playing (via the same path as a row tap).
    ///
    /// Why debounce: rapid Siri Remote up/down would otherwise
    /// trigger one full mpv loadfile per press. 5 presses in a
    /// second produced cascading decode failures (red error
    /// overlay) on real hardware. 300ms is short enough that a
    /// single press feels responsive, long enough that a rapid
    /// burst collapses to one final load.
    @MainActor
    func changeChannel(direction: Int) {
        pendingChannelStep += direction
        pendingChannelChangeTask?.cancel()
        debugLog("[MV-ChannelFlip] press direction=\(direction > 0 ? "+1" : "-1") accumulatedStep=\(pendingChannelStep) currentItem=\(playingItem?.name ?? "nil")")
        pendingChannelChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingChannelChange()
        }
    }

    /// Apply the accumulated step from `changeChannel(direction:)`.
    /// Resolves the target channel by index in
    /// `ChannelStore.channels`, clamps to the list bounds (so a
    /// burst at the top/bottom of the guide doesn't wrap or
    /// crash), and routes through the unified-playback or legacy
    /// path depending on the `useUnifiedPlayback` flag.
    @MainActor
    private func flushPendingChannelChange() {
        let step = pendingChannelStep
        pendingChannelStep = 0
        pendingChannelChangeTask = nil
        guard step != 0 else { return }
        guard let current = playingItem else { return }
        let list = ChannelStore.shared.channels
        guard let currentIdx = list.firstIndex(where: { $0.id == current.id }) else { return }
        let newIdx = max(0, min(list.count - 1, currentIdx + step))
        guard newIdx != currentIdx else { return }
        let next = list[newIdx]
        let server = ChannelStore.shared.activeServer
        let resolvedHeaders = server?.authHeaders ?? ["Accept": "*/*"]
        debugLog("[MV-ChannelFlip] flush step=\(step) from=\(current.name)(id=\(current.id)) to=\(next.name)(id=\(next.id)) unified=\(PlaybackFeatureFlags.useUnifiedPlayback)")
        if PlaybackFeatureFlags.useUnifiedPlayback {
            // Unified path: re-enter multiview seeded with the new
            // channel. Mirrors the row-tap path used elsewhere in
            // HomeView. The exit() + enterMultiview() pair drops the
            // current tile and seeds a fresh one — same lifecycle
            // mpv expects for a clean stream swap.
            debugLog("[MV-ChannelFlip] calling PlayerSession.exit() then enterMultiview(...)")
            PlayerSession.shared.exit()
            PlayerSession.shared.enterMultiview(seeding: next, server: server)
        }
        // wakeChrome=false → channel scroll surfaces ONLY the
        // banner (its own 5s timer) and leaves chrome hidden so
        // a follow-up up/down keeps flipping channels instead of
        // walking the bottom pills.
        startPlaying(next, headers: resolvedHeaders, isLive: true, wakeChrome: false)
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
    /// Mirrors "is a Settings subview pushed" from SettingsView.
    /// `.onExitCommand` on the outer TabView intercepts Menu before
    /// the inner NavigationStack can pop, so we need to know from
    /// here whether a Settings subview is on top before falling
    /// through to the "switch to Live TV" default.
    @State private var isSettingsSubviewPushed = false
    /// Signal to SettingsView to pop its innermost pushed subview
    /// (classic stack first, then navPath). Reset by SettingsView
    /// after consuming.
    @State private var settingsPopRequested = false
    #endif
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @StateObject private var vodStore = VODStore()
    @ObservedObject private var channelStore = ChannelStore.shared
    /// Watches the shared GuideStore so the initial-sync loading cover
    /// can wait for the XMLTV parse (which populates category data and
    /// most of the guide content) to finish before dismissing. Without
    /// this, the cover would close on the faster JSON bulk-EPG signal
    /// and drop the user into a partially-populated guide while
    /// XMLTV was still loading silently in the background.
    @ObservedObject private var guideStore = GuideStore.shared
    /// Watches `PlayerSession.shared.mode` so the inline-player slot
    /// can mode-branch between single-stream `PlayerView` and the new
    /// `MultiviewContainerView`. `@ObservedObject` on a singleton is
    /// the right fit here — the session outlives any view and should
    /// not be owned by this view.
    @ObservedObject private var playerSession = PlayerSession.shared
    /// Watched so the `.multiview` branch can distinguish N=1 (the
    /// unified single-stream path) from N≥2. At N=1 on iOS we restore
    /// the 1.6.0 swipe-down-to-minimize + mini-player behaviour that
    /// the legacy `PlayerView` path used to own — the unified
    /// `MultiviewContainerView` is the rendering surface now, but
    /// collapsing it behaves like a single stream at N=1.
    @ObservedObject private var multiviewStore = MultiviewStore.shared
    @AppStorage("hasCompletedInitialEPG") private var hasCompletedInitialEPG = false
    @State private var showInitialEPGLoading = false
    /// CFAbsoluteTime captured when the initial-sync cover is first
    /// shown. Consumed (and cleared) when the cover dismisses so the
    /// dismissal log line can report total duration. Kept as an
    /// instance var rather than a local so the show/dismiss callbacks
    /// (which happen on separate runloop ticks) can share it.
    @State private var initialLoadingStartedAt: CFAbsoluteTime? = nil
    /// Tracks the start time of the current "any background work
    /// active" period so the heartbeat logger can report elapsed
    /// seconds. Set when `isAnyBackgroundWork` transitions
    /// false → true, cleared on true → false.
    @State private var bgWorkStartedAt: CFAbsoluteTime? = nil
    /// Periodic logger Task that ticks every 15s while background
    /// work is active, printing which tasks are still running.
    /// Lets a user / developer watching a stuck "Syncing…" for
    /// minutes figure out WHICH of the six possible background
    /// tasks is responsible. Cancelled + nilled on the true → false
    /// transition so the logger stops cleanly.
    @State private var bgWorkHeartbeatTask: Task<Void, Never>? = nil
    /// Presents the user-facing background-activity details popover
    /// (iOS) / fullScreenCover (tvOS). The "Syncing…" badge is a
    /// tappable Button that flips this true — users open it to see
    /// exactly which background task is holding the indicator
    /// visible (e.g. a 779-category VOD refill that's been churning
    /// for 5 minutes on a slow server).
    @State private var showBackgroundWorkDetails = false
    /// Flipped true after the first DVR reconcile completes so the
    /// initial loading screen knows it can dismiss. Only gates the
    /// dismiss when a Dispatcharr server is configured — other server
    /// types skip this wait entirely.
    @State private var didInitialDVRReconcile = false

    /// v1.6.13 (GH #8): once-per-app-session gate for the
    /// Auto-Resume Last Channel feature. Set to `true` the first
    /// time we attempt resume hydration so the observer doesn't
    /// re-fire when the channel list re-populates from network
    /// after the cache load (or when the user switches active
    /// servers later in the session).
    @State private var didAttemptAutoResume = false

    /// v1.6.13.x: Scene-phase observer for the warm-resume auto-
    /// resume path. tvOS commonly suspends + restores the app
    /// instead of cold-launching when the user goes Home → reopen
    /// from the dock; in that case `MainTabView` is never recreated,
    /// so `didAttemptAutoResume` retains `true` from the original
    /// launch and `attemptAutoResume()` short-circuits. We listen
    /// for the `.background → .active` transition, reset the flag,
    /// and re-fire — but only when no player is currently active
    /// (which protects users who pressed Home mid-watch and want
    /// to come back to the same stream still running).
    @Environment(\.scenePhase) private var scenePhase

    init() {
        debugLog("🔶🔶 MainTabView.init() — NEW INSTANCE CREATED, thread=\(Thread.current)")
    }

    /// Changes whenever any field that affects a VOD fetch changes — triggers re-fetch.
    /// Includes all servers (not just VOD-capable) so switching to/from M3U also fires the task.
    ///
    /// v1.6.17 (GH user report — "VOD detected in logs but never shows up"):
    /// also include `vodEnabled` and `supportsVOD` so toggling either flag
    /// re-fires the task. Without these the user could turn VOD on for the
    /// active playlist (or have iCloud sync flip the flag from another
    /// device) and the On Demand tab would stay hidden until next app
    /// launch — `loadMovies`/`loadSeries` early-return when the active
    /// server has `vodEnabled == false`, so a re-fetch is the only way to
    /// re-populate `vodStore.series`/`movies` and bring `hasVOD` back to
    /// true.
    private var vodServerKey: String {
        allServers
            .map { "\($0.id.uuidString)|\($0.baseURL)|\($0.isActive ? "1" : "0")|\($0.vodEnabled ? "1" : "0")|\($0.supportsVOD ? "1" : "0")" }
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
    /// signals change (channels, EPG, DVR reconcile, OR a channel-
    /// load error). `.onChange(of: initialSyncKey)` listens to it and
    /// calls `tryDismissInitialLoading()` each time.
    ///
    /// VOD is intentionally **not** part of the key. VOD loading does
    /// not block entering Live TV — the loading cover dismisses as
    /// soon as channels + EPG are ready, and the On Demand tab shows
    /// its own spinner while VOD continues loading in the background.
    /// Previously VOD was gating the cover, which on servers with
    /// hundreds of enabled VOD categories kept the cover up for
    /// minutes even though the Live TV path was long ready.
    ///
    /// Including the error field is the thing that unsticks the
    /// loading screen when credentials are wrong: channels stay empty,
    /// `channelsDone` stays false, but flipping error from nil → message
    /// triggers a dismiss + surfaces the actionable error view beneath.
    private var initialSyncKey: String {
        let channelsDone = !channelStore.isLoading && !channelStore.channels.isEmpty
        // Both the JSON bulk EPG (`channelStore.isEPGLoading`) AND the
        // XMLTV parse (`guideStore.isLoading`) need to wrap before the
        // loading cover is honest. XMLTV is generally the slower of
        // the two but carries the category data the user actually
        // sees — dismissing before XMLTV finishes produces the
        // "partial guide appears, then pops in more content" UX that
        // users reported as "no loading indicator, took forever."
        let epgDone      = !channelStore.isEPGLoading && !guideStore.isLoading
        let dvrDone      = didInitialDVRReconcile || !needsInitialDVRSync
        let errorPresent = channelStore.error != nil
        return "\(channelsDone)|\(epgDone)|\(dvrDone)|\(errorPresent)"
    }

    /// Derived stage list for the initial-sync loading cover, passed
    /// to `ServerSyncView` in its `.initialLaunch` mode. The four
    /// phases run partly in parallel (channels + VOD at least), so
    /// the cover shows them as independent rows with their own status
    /// indicators rather than as a single progressing status string.
    /// Derived from the observed stores — no separate fetch logic
    /// lives inside the cover itself.
    private var loadingStages: [SyncStage] {
        // EPG: combined "channels + guide programs" stage. Still
        // `.loading` until both the JSON bulk AND the XMLTV parse
        // have wrapped, so the row flips to `.done` only when the
        // guide is actually usable.
        let channelsReady = !channelStore.isLoading && !channelStore.channels.isEmpty
        let epgReady = !channelStore.isEPGLoading && !guideStore.isLoading
        var epgStage = SyncStage(id: "epg", label: "Loading EPG")
        if channelsReady && epgReady {
            let channelCount = channelStore.channels.count
            let programCount = guideStore.programs.values.reduce(0) { $0 + $1.count }
            let detail: String
            if programCount > 0 {
                detail = "\(channelCount) channels · \(programCount) programs"
            } else if channelCount > 0 {
                detail = "\(channelCount) channels"
            } else {
                detail = ""
            }
            epgStage.status = .done(detail)
        } else {
            epgStage.status = .loading
        }

        // VOD stage — only really meaningful for servers that expose
        // a VOD library. For pure live-TV sources (M3U), the stage
        // resolves immediately to a "not available" done state.
        let hasVODServer = allServers.contains { $0.supportsVOD }
        var vodStage = SyncStage(id: "vod", label: "Loading VOD")
        if !hasVODServer {
            vodStage.status = .done("No VOD on this source")
        } else if vodStore.isLoadingMovies || vodStore.isLoadingSeries {
            vodStage.status = .loading
        } else {
            let titles = vodStore.movies.count + vodStore.series.count
            vodStage.status = .done(titles > 0 ? "\(titles) titles" : "")
        }

        // DVR stage — only relevant for Dispatcharr servers.
        // Resolves to "not available" on XC / M3U since those don't
        // have a server-side recording API.
        var dvrStage = SyncStage(id: "dvr", label: "Loading DVR")
        if !needsInitialDVRSync {
            dvrStage.status = .done("Not available for this server type")
        } else if didInitialDVRReconcile {
            dvrStage.status = .done("")
        } else {
            dvrStage.status = .loading
        }

        // Preferences stage — reflects the iCloud KVS pull. Always
        // done by the time the cover even has channels to show
        // (SyncManager.pullFromCloud fires earlier during onboarding
        // or app launch), so we surface the synced/off state rather
        // than animating a meaningless spinner.
        var prefsStage = SyncStage(id: "preferences", label: "Loading preferences")
        prefsStage.status = .done(
            SyncManager.shared.isSyncEnabled ? "Synced" : "iCloud Sync off"
        )

        return [epgStage, vodStage, dvrStage, prefsStage]
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
    /// - v1.6.13 (GH #8): the user has opted into Skip Loading Screen
    ///   in Settings → Appearance → App Behaviors. They've explicitly
    ///   asked to land on Live TV instantly and accept the brief UI
    ///   stutter while data hydrates in the background.
    private func tryShowInitialLoading() {
        guard !showInitialEPGLoading else { return }
        guard !allServers.isEmpty else { return }
        guard channelStore.channels.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: "appBehaviorsSkipLoadingScreen") {
            debugLog("🔶 Initial sync — skip flag set in App Behaviors, skipping loading cover")
            return
        }
        showInitialEPGLoading = true
        initialLoadingStartedAt = CFAbsoluteTimeGetCurrent()
        debugLog("🔶 Initial sync starting — showing loading screen (servers=\(allServers.count))")
    }

    /// v1.6.13 (GH #8): Auto-Resume Last Channel hydration. Fires
    /// once per app session as soon as the channel list is
    /// resolvable AND the user has opted in via Settings →
    /// Appearance → App Behaviors. Starts the last-played channel
    /// directly in the corner mini-player; the user lands on the
    /// Guide with their last channel already warming up. Press
    /// Play/Pause to expand to fullscreen.
    ///
    /// Platform gate: iPad and Apple TV only. Per the v1.6.13 spec
    /// the corner mini doesn't fit on iPhone (the iPhone keeps its
    /// bottom-anchored `MiniPlayerBar` paradigm), so the toggle is
    /// hidden in Settings on iPhone and this method short-circuits
    /// there even if the UserDefault is somehow true (e.g. an
    /// iCloud-synced preference from an iPad).
    ///
    /// Skipped when:
    /// - Already attempted this session (`didAttemptAutoResume`).
    /// - Toggle is off.
    /// - On iPhone (idiom != .pad).
    /// - No marker recorded (first-ever launch / cleared state).
    /// - Channel list doesn't currently contain a row matching the
    ///   marker's `channelID` (channel was deleted upstream, or the
    ///   active server changed since last play).
    private func attemptAutoResume() {
        guard !didAttemptAutoResume else { return }

        // Settings gate. Reading via UserDefaults rather than
        // @AppStorage so the property doesn't need to live on
        // MainTabView and trigger re-renders on every change.
        guard UserDefaults.standard.bool(forKey: "appBehaviorsAutoResumeLastChannel") else {
            didAttemptAutoResume = true
            return
        }

        // Platform gate. iPhone is excluded from auto-resume because
        // the bottom MiniPlayerBar UX is too jarring for an unsolicited
        // appear; iPad + tvOS get the corner mini-player which feels
        // ambient.
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            didAttemptAutoResume = true
            return
        }
        #endif

        // If a channel is already playing (warm-resume case where
        // tvOS suspended us with the player intact and then woke us
        // back up), we have nothing to resume — the player IS the
        // resume. Mark attempted so we don't fight whatever the
        // user does next.
        if nowPlaying.isActive {
            didAttemptAutoResume = true
            return
        }

        // Channels must be resolvable. We DON'T set
        // `didAttemptAutoResume = true` here so the `.onChange`
        // observer can call us again once channels arrive.
        guard !channelStore.channels.isEmpty else { return }

        // From here on, mark the attempt regardless of whether we
        // actually find a match — failure modes (deleted channel,
        // missing marker) shouldn't keep firing on every channel
        // list change throughout the session.
        didAttemptAutoResume = true

        guard let marker = LastPlayedTracker.lastPlayed else {
            debugLog("🎮 Auto-resume: no LastPlayedTracker marker, skipping")
            return
        }

        guard let channel = channelStore.channels.first(where: { $0.id == marker.channelID }) else {
            debugLog("🎮 Auto-resume: channel id=\(marker.channelID) not in current list (likely deleted upstream or different active server), skipping")
            return
        }

        // Server lookup mirrors `playerHeaders()` in ChannelListView.
        let server = allServers.first(where: { $0.id == marker.serverID })
            ?? channelStore.activeServer
            ?? allServers.first(where: { $0.isActive })

        // v1.6.15: log thermal state at the moment auto-resume kicks
        // playback. Pairs with the `[MPV-WARMUP] thermal=X→Y` line:
        // if a stutter report shows warmup ended fair/serious AND
        // auto-resume started serious, the device was already hot
        // and we lost that race. If warmup ended nominal but resume
        // shows serious, something else (background scan, EPG sync)
        // heated it up between warmup and the first frame.
        let thermalState: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal:  return "nominal"
            case .fair:     return "fair"
            case .serious:  return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }()
        debugLog("🎮 Auto-resume: starting \(channel.name) (id=\(channel.id)) in mini player (unified=\(PlaybackFeatureFlags.useUnifiedPlayback), thermal=\(thermalState))")

        if PlaybackFeatureFlags.useUnifiedPlayback {
            _ = PlayerSession.shared.begin(item: channel, server: server)
        } else {
            let headers = server?.authHeaders ?? ["Accept": "*/*"]
            nowPlaying.startPlaying(channel, headers: headers, isLive: marker.isLive)
        }

        // Drop straight into the corner mini. SwiftUI batches the
        // back-to-back state writes (`isMinimized = false` inside
        // startPlaying / begin, then `true` here) into the same
        // render pass, so the player view mounts already minimized
        // — no fullscreen-then-shrink flicker.
        nowPlaying.minimize()
    }

    /// v1.6.13.x: warm-resume handler. tvOS commonly suspends +
    /// restores the app instead of cold-launching when the user
    /// goes Home → reopen from the dock; in that case `MainTabView`
    /// is never recreated, `didAttemptAutoResume` retains `true`
    /// from the original launch, and `attemptAutoResume()` short-
    /// circuits at its first guard. We listen for the
    /// `.background → .active` (or `.inactive → .active`)
    /// transition, reset the gate, and re-fire — but the
    /// `nowPlaying.isActive` early-return inside `attemptAutoResume`
    /// itself keeps us from restarting a stream that survived the
    /// suspension intact.
    ///
    /// Extracted from the inline `.onChange(of: scenePhase)` closure
    /// so MainTabView's body modifier chain stays under Swift's
    /// type-checker budget on tvOS x86_64.
    private func handleAutoResumeScenePhase(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        guard oldPhase != .active, newPhase == .active else { return }
        guard !nowPlaying.isActive else { return }
        debugLog("🎮 Auto-resume: scenePhase \(oldPhase) → active with no active player — re-trying")
        didAttemptAutoResume = false
        attemptAutoResume()
    }

    /// Called whenever `initialSyncKey` changes. Dismisses the
    /// Loading Guide screen once the Live-TV-critical signals are
    /// done — channels loaded, EPG loaded, DVR reconciled. **VOD is
    /// deliberately NOT gated here**: on servers with hundreds of
    /// enabled VOD categories (real-world user case: 779 movie + 479
    /// series categories) VOD loading takes minutes, and the user
    /// shouldn't wait on On Demand before they can watch a channel.
    /// The On Demand tab has its own loading state and will spin
    /// while `vodStore.isLoadingMovies` / `.isLoadingSeries` are true.
    private func tryDismissInitialLoading() {
        guard showInitialEPGLoading else { return }

        // Error path — channel fetch ended with an error and no data arrived.
        // Dismiss the loading screen so the underlying error view can render
        // its actionable message (e.g. "Invalid credentials — check your API
        // Key in Settings") instead of trapping the user behind a spinner.
        if channelStore.error != nil, channelStore.channels.isEmpty, !channelStore.isLoading {
            withAnimation(.easeOut(duration: 0.4)) {
                showInitialEPGLoading = false
            }
            debugLog("🔶 Initial sync ended with error — dismissing loading screen so error view can show")
            return
        }

        guard !channelStore.isLoading, !channelStore.channels.isEmpty else { return }
        guard !channelStore.isEPGLoading else { return }
        // XMLTV parse must also complete — see `initialSyncKey` doc comment.
        guard !guideStore.isLoading else { return }
        // VOD loading intentionally NOT gated here. VOD can take
        // minutes on large libraries and the user shouldn't wait on
        // On Demand before they can watch Live TV. The On Demand tab
        // shows its own spinner while `vodStore.isLoadingMovies` /
        // `.isLoadingSeries` are true.
        if needsInitialDVRSync && !didInitialDVRReconcile { return }

        withAnimation(.easeOut(duration: 0.4)) {
            showInitialEPGLoading = false
        }
        let elapsed = initialLoadingStartedAt.map {
            Int((CFAbsoluteTimeGetCurrent() - $0) * 1000)
        }
        initialLoadingStartedAt = nil
        let vodStillLoading = vodStore.isLoadingMovies || vodStore.isLoadingSeries
        let elapsedStr = elapsed.map { " \($0)ms" } ?? ""
        debugLog("🔶 Initial sync complete — dismissing loading screen (total=\(elapsedStr), vodStillLoadingInBackground=\(vodStillLoading))")
    }
    /// Shared drag offset — MiniPlayerBar writes it, PlayerView reads it to slide in from below.
    @State private var miniPlayerDragOffset: CGFloat = 0

    /// Drives the top-of-screen "Syncing…" indicator so the user
    /// knows background work is ongoing that may still be publishing
    /// `@Published` updates (which can cause visible view churn on
    /// the Live TV tab — e.g. the contextMenu pulse we diagnosed in
    /// v1.6.7 before switching to the popover).
    ///
    /// Includes both `isLoadingMovies`/`isLoadingSeries` (cover the
    /// "first-partial-data" window) AND
    /// `isRefillingMovies`/`isRefillingSeries` (cover the rest of the
    /// per-category streaming loop, which can run for minutes on
    /// large VOD libraries with slow servers). Also includes the
    /// server-side search flags so users searching a huge library
    /// see the ongoing background activity.
    private var isAnyBackgroundWork: Bool {
        channelStore.isLoading || channelStore.isEPGLoading || guideStore.isLoading
            || vodStore.isLoadingMovies || vodStore.isLoadingSeries
            || vodStore.isRefillingMovies || vodStore.isRefillingSeries
            || vodStore.isSearchingMovies || vodStore.isSearchingSeries
    }

    /// Short identifier labels used by the heartbeat log. Terse
    /// by design — the log consumer needs grep-friendly tokens.
    /// User-facing strings live in
    /// `humanReadableBackgroundTaskLabels`.
    private var activeBackgroundTaskLabels: [String] {
        var labels: [String] = []
        if channelStore.isLoading        { labels.append("channels") }
        if channelStore.isEPGLoading     { labels.append("epg") }
        if guideStore.isLoading          { labels.append("xmltv-parse") }
        if vodStore.isLoadingMovies      { labels.append("vod-movies-initial") }
        if vodStore.isLoadingSeries      { labels.append("vod-series-initial") }
        if vodStore.isRefillingMovies    { labels.append("vod-movies-refill") }
        if vodStore.isRefillingSeries    { labels.append("vod-series-refill") }
        if vodStore.isSearchingMovies    { labels.append("vod-movies-search") }
        if vodStore.isSearchingSeries    { labels.append("vod-series-search") }
        return labels
    }

    /// Friendly labels shown in the user-facing
    /// `BackgroundWorkDetailsView` when the user taps / selects the
    /// "Syncing…" badge. Deduplicates `isLoading*` + `isRefilling*`
    /// (both are typically true at load start — the refill flag
    /// stays true through the category loop, the load flag flips
    /// false at first partial data) so users see a single "Loading
    /// Movies" row rather than two confusingly-named ones. Search
    /// flags are separate because they're user-initiated and
    /// worth distinguishing from the initial library load.
    private var humanReadableBackgroundTaskLabels: [String] {
        var labels: [String] = []
        if channelStore.isLoading        { labels.append("Loading channel list") }
        if channelStore.isEPGLoading     { labels.append("Loading EPG") }
        if guideStore.isLoading          { labels.append("Parsing guide data") }
        if vodStore.isLoadingMovies || vodStore.isRefillingMovies {
            labels.append("Loading Movies")
        }
        if vodStore.isLoadingSeries || vodStore.isRefillingSeries {
            labels.append("Loading Series")
        }
        if vodStore.isSearchingMovies    { labels.append("Searching Movies") }
        if vodStore.isSearchingSeries    { labels.append("Searching Series") }
        return labels
    }

    var body: some View {
        ZStack {
            tabContentView
                #if os(tvOS)
                // While multiview is active, disable the entire tab
                // hierarchy so tvOS's focus engine can't land on guide
                // rows / tab-bar items behind the MultiviewContainer.
                // Without this, users reported hearing D-pad scrolling
                // sounds with no visible focus (focus was on hidden
                // guide cards) and Menu bubbling past multiview's
                // `.onExitCommand` to the app-exit prompt.
                //
                // EXCEPTION: when the unified N=1 player has been
                // minimized to the corner, the guide IS expected to
                // receive focus (so the user can D-pad through
                // channels, pick a new one, or press Menu to stop
                // playback). Without this carve-out the guide stays
                // `.disabled`, which renders every focus-release
                // attempt inside the mini inert — focus has nowhere
                // legal to go. This is the "missing piece" that made
                // `.focusable(false)`, `@FocusState` claims, and
                // `.forceGuideFocus` notifications silently fail for
                // the mini-player UX.
                .disabled(
                    playerSession.mode == .multiview
                    && !(multiviewStore.tiles.count == 1 && nowPlaying.isMinimized)
                )
                #endif

            // Background activity indicator — top left. Tappable on
            // iOS, focusable/selectable on tvOS so users can see
            // WHICH background task is still running when the badge
            // sits "Syncing…" for minutes. Opens a platform-native
            // detail view (popover on iOS, fullScreenCover on tvOS)
            // listing the active tasks + elapsed time.
            if isAnyBackgroundWork, !nowPlaying.isActive || nowPlaying.isMinimized {
                VStack {
                    Button {
                        showBackgroundWorkDetails = true
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView()
                                #if os(tvOS)
                                .scaleEffect(0.6)
                                #else
                                .scaleEffect(0.5)
                                #endif
                            #if os(tvOS)
                            Text("Syncing… · select for info")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                            #else
                            Text("Syncing | Tap for Info")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                            #endif
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.5).clipShape(Capsule()))
                    }
                    // iOS gets `.plain` (no chrome, just the label).
                    // tvOS gets `TVNoHighlightButtonStyle` which
                    // replaces the default system focus halo — the
                    // bright-white outline the system applies to
                    // `.plain` buttons is visually overwhelming on
                    // a tiny capsule badge (user-reported v1.6.8).
                    // `TVNoHighlightButtonStyle` uses the same gentle
                    // accent-tinted scale + shadow pattern as every
                    // other tvOS row in the app so focus feedback
                    // stays consistent across the UI.
                    #if os(tvOS)
                    .buttonStyle(TVNoHighlightButtonStyle())
                    // `.focusSection()` keeps this badge out of the
                    // default D-pad navigation path — it sits in its
                    // own focus region in the top-left corner, so
                    // users navigating the main content grid don't
                    // accidentally land here. They have to
                    // deliberately drive focus up-and-left to reach
                    // it.
                    .focusSection()
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    #if os(iOS)
                    .popover(isPresented: $showBackgroundWorkDetails,
                             attachmentAnchor: .rect(.bounds)) {
                        BackgroundWorkDetailsView(
                            labels: humanReadableBackgroundTaskLabels,
                            elapsedSeconds: bgWorkStartedAt.map {
                                Int(CFAbsoluteTimeGetCurrent() - $0)
                            } ?? 0
                        )
                        .presentationCompactAdaptation(.popover)
                    }
                    #else
                    .fullScreenCover(isPresented: $showBackgroundWorkDetails) {
                        BackgroundWorkDetailsView(
                            labels: humanReadableBackgroundTaskLabels,
                            elapsedSeconds: bgWorkStartedAt.map {
                                Int(CFAbsoluteTimeGetCurrent() - $0)
                            } ?? 0
                        )
                    }
                    #endif
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)
            }

            // Mode branch:
            //   .multiview → MultiviewContainerView (grid + transport)
            //   .single / .idle → existing single-stream PlayerView path
            //
            // When a user taps "Enter Multiview" (iPad top-bar button
            // or tvOS options-panel row), `PlayerSession` flips mode
            // to .multiview and MultiviewStore seeds tile 0 with the
            // currently-playing channel (id pinned to item.id for
            // SwiftUI identity stability). The branch below then
            // swaps to MultiviewContainerView on the next render.
            //
            // `PlayerSession.exit()` flips mode back to .idle and
            // clears the tile list — HomeView falls through to the
            // no-playback state (Live TV guide shows).
            //
            // `NowPlayingManager.playingItem` is intentionally NOT
            // nil-ed during multiview — the seed channel metadata is
            // still the single-stream fallback for when the user
            // exits multiview keeping the audio tile.
            if playerSession.mode == .multiview {
                #if os(tvOS)
                // At N=1 under unified playback, restore the 1.6.0
                // tvOS mini-player UX: double-press Menu shrinks the
                // full-screen player down to a 400×225 corner box so
                // the guide shows through behind. A third Menu press
                // stops playback entirely (handled by HomeView's
                // `.onExitCommand` below). Playback continues without
                // interruption because MultiviewContainerView is
                // never unmounted; only its frame / position change.
                //
                // At N≥2 (real multiview) the mini state is ignored —
                // the mini-player concept doesn't generalise to a
                // grid, and the exit path there is the normal
                // "Exit Multiview?" confirmation.
                let isSoleStream = multiviewStore.tiles.count == 1
                let minimized = isSoleStream && nowPlaying.isMinimized
                GeometryReader { geo in
                    let miniW: CGFloat = 400
                    let miniH: CGFloat = 225
                    ZStack(alignment: .topTrailing) {
                        MultiviewContainerView()
                            .frame(
                                width: minimized ? miniW : geo.size.width,
                                height: minimized ? miniH : geo.size.height
                            )
                            .clipShape(RoundedRectangle(
                                cornerRadius: minimized ? 12 : 0,
                                style: .continuous
                            ))
                            .shadow(
                                color: minimized ? .black.opacity(0.6) : .clear,
                                radius: 20, y: 8
                            )
                            // Hit-testing off so remote taps don't
                            // land on the mini. Focus-release is
                            // forced here by `.disabled(minimized)`
                            // — that makes the tile Button inside
                            // MultiviewTileView non-focusable, so
                            // tvOS's focus engine cannot land on
                            // the mini and must route D-pad focus
                            // to the guide behind. An earlier
                            // attempt delegated focus-release to
                            // MultiviewTileView via conditional
                            // `.focusable(Bool)` on the Button,
                            // but Apple's docs + on-device testing
                            // showed that `.focusable(Bool)` on a
                            // SwiftUI Button is ignored while the
                            // Button already holds focus — so the
                            // tile stayed focused and only the
                            // NEXT D-pad movement escaped the
                            // mini. Disabling at this wrapper
                            // level is what the user sees as
                            // "focus immediately returns to the
                            // guide on minimize."
                            //
                            // `.onPlayPauseCommand { nowPlaying.expand() }`
                            // lives at the MainTabView body level
                            // (see HomeView `.onPlayPauseCommand`
                            // far above) — that handler is attached
                            // OUTSIDE this disabled subtree and
                            // still fires, so Play/Pause on the
                            // Siri Remote still re-expands the
                            // mini. The guide's
                            // `.prefersDefaultFocus` + the
                            // `.forceGuideFocus` `resetFocus`
                            // handler handle the "which guide row
                            // gets focus" question.
                            .disabled(minimized)
                            .allowsHitTesting(!minimized)
                            .padding(.trailing, minimized ? 40 : 0)
                            .padding(.top, minimized ? 40 : 0)
                            // v1.6.13.x: capture mini's actual
                            // bottom for ChannelListView's chip-row
                            // push-down (tvOS branch).
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .global).maxY
                            } action: { newValue in
                                if minimized {
                                    nowPlaying.miniPlayerBottomAbs = newValue
                                } else if nowPlaying.miniPlayerBottomAbs != 0 {
                                    nowPlaying.miniPlayerBottomAbs = 0
                                }
                            }
                    }
                    .frame(
                        width: geo.size.width,
                        height: geo.size.height,
                        alignment: minimized ? .topTrailing : .center
                    )
                    .animation(.spring(response: 0.35), value: minimized)
                }
                .ignoresSafeArea()
                .zIndex(2)
                // Intentionally NO outer `.focusSection()` here.
                // MultiviewContainerView already has a focusSection
                // on its internal grid, which traps focus between
                // tiles while full-screen. When we shrink to the
                // 400×225 corner, we WANT focus to escape to the
                // guide behind (the channel list / EPG grid) so the
                // user can D-pad through channels. An outer
                // focusSection here would trap focus inside the
                // corner player even with hit-testing off, which is
                // exactly the bug the mini UX needs to avoid.
                #else
                // iOS: see `iOSMultiviewWrapper` — extracted out of
                // body to keep Swift's type-checker under budget.
                iOSMultiviewWrapper
                #endif
            } else if nowPlaying.isActive, let item = nowPlaying.playingItem {
                // Single PlayerView kept in hierarchy for uninterrupted playback.
                // Transitions between full-screen and mini use size/position
                // modifiers — the player instance is never destroyed.
                #if os(iOS)
                // iOS: see `iOSLegacyPlayerWrapper` — extracted out of
                // body to keep Swift's type-checker under budget.
                iOSLegacyPlayerWrapper(item: item)
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
                        // v1.6.13.x: capture mini's actual bottom
                        // for ChannelListView's chip-row push-down
                        // (tvOS legacy-path branch).
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .global).maxY
                        } action: { newValue in
                            if minimized {
                                nowPlaying.miniPlayerBottomAbs = newValue
                            } else if nowPlaying.miniPlayerBottomAbs != 0 {
                                nowPlaying.miniPlayerBottomAbs = 0
                            }
                        }

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

            // v1.6.15: channel-info HUD that briefly identifies the
            // current live channel + program when a stream starts
            // (cold launch auto-resume, channel-list tap, Siri Remote
            // up/down flip on tvOS); fades together with the player
            // chrome's auto-fade. Sits above the mini player +
            // reminder banner so it's never occluded.
            ChannelInfoBanner()
                .zIndex(3)
        }
        // safeAreaInset on the outer ZStack pushes the entire TabView (including its tab bar)
        // upward so the tab bar sits above the mini player bar and remains tappable.
        #if os(iOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // v1.6.13: only iPhone uses the bottom MiniPlayerBar.
            // iPad uses a top-right corner mini (handled inside the
            // body's main ZStack — see the iPad GeometryReader
            // branches above), so the bottom bar would double-render
            // an off-screen mini and steal vertical space from the
            // guide.
            if UIDevice.current.userInterfaceIdiom == .phone,
               nowPlaying.isMinimized,
               let item = nowPlaying.playingItem {
                MiniPlayerBar(item: item, nowPlaying: nowPlaying, dragOffset: $miniPlayerDragOffset)
            }
        }
        #endif
        #if os(tvOS)
        // v1.6.12: GH #11 fix (v5).
        //
        // History: this slot used to do
        //   `if nowPlaying.isMinimized { PlayerSession.shared.stop() }`
        // with **nothing** in the `!isMinimized` case. SwiftUI's
        // `.onExitCommand` is a sink — once attached it consumes
        // the Back/Menu press regardless of whether the body does
        // anything. After expanding the player from mini back to
        // full-screen via Play/Pause from the guide, the press
        // from the still-focused guide cell bubbled here, the
        // empty branch ran, and the press died.
        //
        // First fix attempt removed this entire handler thinking
        // the inner `.onExitCommand` on `tabContentView`
        // (`{ handleMenuPress() }`) would catch everything. It
        // doesn't — `.onExitCommand` on a TabView only fires when
        // focus is inside one of the tabs, and after the
        // expand-from-mini path leaves focus in a state where the
        // press bypasses tabContentView entirely (the player
        // overlay's `.focusSection()` is a sibling of
        // tabContentView in the body's outer ZStack, so its
        // children's exit-command bubble doesn't traverse
        // tabContentView at all). With this slot removed the press
        // reached system level → app exited.
        //
        // The right fix is to make THIS handler call
        // `handleMenuPress()` too. That mirrors the inner
        // tabContentView handler so whichever level actually
        // receives the press, the routing is identical:
        //   - full-screen player  → minimize
        //   - mini player         → stop
        //   - VOD detail pushed   → pop
        //   - Settings subview    → pop
        //   - Live TV tab idle    → scroll guide to top
        //   - other tab           → switch to Live TV
        //
        // Net effect: Back works correctly in every transition,
        // including the Live TV → Guide → Live TV cycle that GH #11
        // reported.
        .onExitCommand {
            debugLog("🎮 [MT-OUTER] .onExitCommand FIRED (body's outer modifier — focus was outside tabContentView's TabView)")
            handleMenuPress()
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

    /// True when the **active** server has at least one recording
    /// — local or server-side, scheduled / recording / completed —
    /// in the SwiftData store. v1.6.10:
    ///
    ///   • Original (pre-v1.6.10): `!allRecordings.isEmpty` — surfaced
    ///     the DVR tab whenever **any** server in the user's library
    ///     had recordings, so a user on Xtream playlist A would see
    ///     DVR because their idle Dispatcharr server B had recordings.
    ///   • v1.6.10 first cut: also returned true for any active
    ///     Dispatcharr server, on the reasoning "you can always
    ///     schedule a new one." Wrong call — an active Dispatcharr
    ///     server with zero recordings still showed an empty DVR
    ///     tab, which the user (correctly) didn't want.
    ///   • Now: tab visible iff the active server has at least one
    ///     recording. Server-side scheduled recordings flow into
    ///     `allRecordings` via the tab-bar-level
    ///     `reconcileAllDispatcharrRecordings` task, so scheduling
    ///     a new recording from Live TV → Record makes the tab
    ///     appear; deleting the last recording makes it disappear.
    ///
    /// Mirrors the per-playlist scope applied inside
    /// `MyRecordingsView` itself, so the tab and its contents agree.
    private var hasRecordings: Bool {
        guard let active = allServers.first(where: { $0.isActive }) ?? allServers.first else {
            return false
        }
        let sid = active.id.uuidString
        return allRecordings.contains { $0.serverID == sid }
    }
    /// True when the active server has advertised ANY VOD content, OR
    /// is still loading its VOD library. Keeping the tab visible while
    /// loading prevents the flicker of "tab missing → tab appears" on
    /// cold launch or server switch. A server that completes loading
    /// with zero movies and zero series (e.g., a bare live-TV-only
    /// M3U) hides the tab entirely — matching the dynamic behaviour
    /// of the DVR and Favorites tabs.
    private var hasVOD: Bool {
        !vodStore.movies.isEmpty
            || !vodStore.series.isEmpty
            || vodStore.isLoadingMovies
            || vodStore.isLoadingSeries
    }

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

            // On Demand tab only exists while the active server exposes
            // VOD content (or is still loading its library). A server
            // that returns empty movie + series lists (e.g., a pure
            // live-TV M3U or a Dispatcharr instance without any VOD
            // ingested) hides the tab entirely, matching the dynamic
            // behaviour of Favorites and DVR.
            if hasVOD {
                OnDemandView(vodStore: vodStore, isPlaying: $isPlaying, isDetailPushed: $isVODDetailPushed, popRequested: $vodNavPopRequested)
                    .tabItem { Label(AppTab.onDemand.title, systemImage: AppTab.onDemand.icon) }
                    .tag(AppTab.onDemand)
            }

            #if os(tvOS)
            SettingsView(selectedTab: $selectedTab,
                         isSubviewPushed: $isSettingsSubviewPushed,
                         popRequested: $settingsPopRequested)
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
        // If the VOD library drains (e.g., server switched to a
        // pure live-TV source) while the user is on the On Demand
        // tab, redirect home rather than leaving them staring at a
        // tab whose backing content is gone.
        .onChange(of: hasVOD) { _, nowHasVOD in
            if !nowHasVOD && selectedTab == .onDemand {
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
        // v1.6.13 (GH #8): auto-resume the last-played channel into
        // the corner mini-player as soon as the channel list is
        // resolvable. Fires on the first non-empty `channels`
        // transition; the `didAttemptAutoResume` gate makes it
        // strictly once-per-session.
        // v1.6.13: auto-resume hooks consolidated into a single
        // ViewModifier so the body's modifier chain stays under
        // Swift's type-checker budget on tvOS x86_64. The modifier
        // wires three triggers — `.onAppear` (cold launch),
        // `.onChange(of: channels.isEmpty)` (channels arrive after
        // appear), and `.onChange(of: scenePhase)` (warm resume from
        // suspension) — and forwards each to the corresponding
        // method on this struct.
        .modifier(AutoResumeWiring(
            channelsAreEmpty: channelStore.channels.isEmpty,
            scenePhase: scenePhase,
            onResumeAttempt: { attemptAutoResume() },
            onScenePhaseChange: { old, new in
                handleAutoResumeScenePhase(from: old, to: new)
            }
        ))
        // Background-work heartbeat logger. When `isAnyBackgroundWork`
        // transitions false → true we start a 15s-tick Task that
        // prints the currently-active task labels. The user-visible
        // "Syncing…" badge at the top-left is one bit — the log
        // says WHICH of the six (channels, epg, xmltv-parse, vod-
        // movies-initial/-refill/-search, vod-series-initial/-refill
        // /-search) is responsible. Particularly useful for
        // understanding why a warm relaunch on a large VOD library
        // sits "Syncing…" for 5+ minutes (answer: 1,258 sequential
        // per-category VOD fetches).
        .onChange(of: isAnyBackgroundWork) { wasActive, nowActive in
            if nowActive && !wasActive {
                let start = CFAbsoluteTimeGetCurrent()
                bgWorkStartedAt = start
                debugLog("⏳ Background work STARTED — \(activeBackgroundTaskLabels.joined(separator: ", "))")
                bgWorkHeartbeatTask?.cancel()
                bgWorkHeartbeatTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        if Task.isCancelled { break }
                        // Re-read the current labels on each tick —
                        // individual tasks finish mid-session (e.g.
                        // EPG cache load completes while VOD refill
                        // is still going), so the label set
                        // evolves.
                        let labels = activeBackgroundTaskLabels
                        guard !labels.isEmpty else { break }
                        let elapsed = Int(CFAbsoluteTimeGetCurrent() - start)
                        debugLog("⏳ Background work ongoing (\(elapsed)s elapsed) — \(labels.joined(separator: ", "))")
                    }
                }
            } else if wasActive && !nowActive {
                bgWorkHeartbeatTask?.cancel()
                bgWorkHeartbeatTask = nil
                let elapsed = bgWorkStartedAt.map {
                    Int(CFAbsoluteTimeGetCurrent() - $0)
                } ?? 0
                bgWorkStartedAt = nil
                debugLog("✅ Background work COMPLETE (total \(elapsed)s)")
            }
        }
        .fullScreenCover(isPresented: $showInitialEPGLoading) {
            // Reuse the same cover that fires after onboarding so users
            // see a consistent "Setting Up …" experience whether they
            // just added a server or are booting a fresh install. The
            // `.initialLaunch` mode lets `ServerSyncView` render our
            // store-derived stages instead of driving its own fetches.
            ServerSyncView(
                mode: .initialLaunch(
                    stages: loadingStages,
                    onContinueAnyway: {
                        // User-triggered escape hatch — drops them
                        // into the main UI even if background fetches
                        // are still hung. When the fetch eventually
                        // fails with an error,
                        // `ChannelListView.errorView` handles
                        // surfacing the retry path.
                        showInitialEPGLoading = false
                        debugLog("🔶 User dismissed initial loading screen manually")
                    }
                )
            )
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
            // v1.6.13: closure body extracted to method to keep the
            // body's modifier chain under Swift's type-checker budget
            // on tvOS x86_64. Behavior unchanged.
            await runChannelServerTaskBody()
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
        // Body extracted to `handleMenuPress()` — the inline closure grew
        // past Swift's type-inference budget (the chain of `else if`
        // branches mixed with string interpolation in `debugLog`'s
        // `@autoclosure` repeatedly tripped "unable to type-check this
        // expression in reasonable time"). Calling a plain method side-
        // steps the budget entirely.
        .onExitCommand {
            debugLog("🎮 [MT-INNER] .onExitCommand FIRED (tabContentView/TabView — focus was inside a tab)")
            handleMenuPress()
        }
        .onPlayPauseCommand {
            if nowPlaying.isMinimized {
                debugLog("🎮 Play/Pause pressed: expand mini player to full screen")
                withAnimation(.spring(response: 0.35)) { nowPlaying.expand() }
            }
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

    /// v1.6.13: Channel/EPG load orchestrator. Pulled out of the
    /// `.task(id: channelServerKey)` closure attached to body so the
    /// body's expression complexity stays under Swift's type-checker
    /// budget on tvOS x86_64. Behavior unchanged from the inline
    /// closure that lived here in v1.6.12.
    @MainActor
    private func runChannelServerTaskBody() async {
        debugLog("🔶 MainTabView.task(channelServerKey): firing, servers=\(allServers.count)")
        channelStore.refresh(servers: allServers)
        debugLog("🔶 MainTabView.task(channelServerKey): refresh called")
        // Flip `isEPGLoading` to true RIGHT NOW — before the
        // wait-for-channels loop. Without this there's a race
        // window: `channelStore.isLoading` flips false the
        // instant channels finish hydrating (from
        // SwiftData / the JSON API), but `isEPGLoading` doesn't
        // flip true until the next line starts executing
        // `loadAllEPG`. In that single-run-loop-tick gap,
        // `initialSyncKey` reads `channelsDone=true` AND
        // `epgDone=true` AND dismisses the ServerSyncView
        // cover — before a single XMLTV byte has downloaded.
        // The user sees Live TV with uncolored schedule rows
        // because `seedEPGCache` hasn't run yet. Setting the
        // flag pre-emptively closes the race; `loadAllEPG`'s
        // `defer` still resets it when done.
        if !allServers.isEmpty {
            channelStore.isEPGLoading = true
        }

        // Kick off the SwiftData EPG-cache load IN PARALLEL with
        // the channel network fetch. `loadFromCache` doesn't read
        // the `channels` parameter — it only needs `serverID` +
        // modelContext — so there's no dependency that requires
        // serializing it behind the `while channelStore.isLoading`
        // poll. Channel fetch is network-bound and EPG cache
        // load is disk-bound (SwiftData on a background
        // ModelContext), so they don't compete for the same
        // resource on the client, and the server has no
        // visibility into the local SwiftData work. On the
        // torture playlist this overlap saves ~2-3s off the
        // "Initial sync complete" dismiss. The
        // `inFlightLoadTask` coalescer inside `loadFromCache`
        // keeps EPGGuideView.task's later call from re-doing
        // the work.
        let activeServer = allServers.first(where: { $0.isActive }) ?? allServers.first
        let activeServerID = activeServer?.id.uuidString ?? "unknown"
        // Use a regular `Task` (inherits MainActor from this
        // SwiftUI `.task` scope) rather than `async let` because
        // `ModelContext` is non-Sendable and `async let` wants
        // to hand it across an implicit concurrency boundary.
        // The captured `modelContext` stays on MainActor through
        // the entire chain — `loadFromCache` is @MainActor-
        // isolated and dispatches its own off-main work via
        // `Task.detached` using only the Sendable container.
        let cacheLoadHandle = Task { () -> Bool in
            await guideStore.loadFromCache(
                modelContext: modelContext,
                channels: [],  // unused inside loadFromCache (kept for API shape)
                serverID: activeServerID
            )
        }

        // Wait for channels to finish loading.
        while channelStore.isLoading {
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Collect the parallel cache-load verdict. If the
        // channel fetch took longer than the SwiftData load
        // (the typical case — network RTT vs. local disk) this
        // await resolves immediately.
        let cacheIsFresh = await cacheLoadHandle.value

        if !channelStore.channels.isEmpty {
            // Try to short-circuit the expensive `loadAllEPG`
            // path by checking the SwiftData EPG cache first. On
            // warm relaunches within the 24-hour freshness
            // window, the cache already has everything the guide
            // needs. Re-running `loadAllEPG` would fire
            // `getEPGGrid` (68k+ programs, multi-MB JSON) AND an
            // awaited `primeXMLTVFromURL` (98k+ programs, full
            // XMLTV download + parse) — on a large Dispatcharr
            // instance this easily adds 3-4 minutes to the cover
            // dismissal despite the data already being on disk.
            //
            // Previously this check lived inside
            // `EPGGuideView.task(id: channels.count)` and only
            // gated `guideStore.fetchUpcoming`, which runs in
            // parallel with `loadAllEPG` — so the cache hit was
            // visible in the log ("skipping network fetch") but
            // the cover still waited for `loadAllEPG` to
            // complete. Running the check here instead gates the
            // real offender.
            //
            // iPhone also benefits: it never mounts EPGGuideView,
            // so its EPGCache could previously only be populated
            // by `loadAllEPG`. We now explicitly populate it via
            // `seedEPGCache` on the cache-hit path so List view
            // card expansions don't trigger per-card network
            // fetches.
            //
            // Nested short-circuiting contains — see the matching
            // comment in EPGGuideView.swift. The previous
            // `.values.flatMap { $0 }.contains` form allocated a
            // full flattened Array of all cached programs on the
            // main thread (97k+ entries on the torture playlist),
            // costing a 2-3s hang. Double short-circuit eliminates
            // both the allocation and the scan on a fresh cache.
            let futureCutoff = Date().addingTimeInterval(1800)
            let hasFuturePrograms = guideStore.programs.contains { _, progs in
                progs.contains { $0.end > futureCutoff }
            }
            if cacheIsFresh && hasFuturePrograms {
                debugLog("🔶 MainTabView.task(channelServerKey): EPG cache is fresh + has future programs — skipping loadAllEPG")
                // Seed EPGCache from GuideStore.programs so the
                // List view has per-channel EPG data. Awaited so
                // the cover doesn't dismiss before EPGCache has
                // the entries it needs.
                await guideStore.seedEPGCache(channels: channelStore.channels, server: activeServer)
                channelStore.isEPGLoading = false
            } else {
                debugLog("🔶 MainTabView.task(channelServerKey): EPG cache stale or empty (fresh=\(cacheIsFresh), hasFuture=\(hasFuturePrograms)) — running loadAllEPG")
                await channelStore.loadAllEPG()
            }
        } else {
            // Channel load failed (auth, server down). Reset
            // the flag we pre-set above so the cover can
            // dismiss via the error path — otherwise the user
            // would be stuck staring at "Setting Up …" with
            // no way out.
            channelStore.isEPGLoading = false
        }
    }

    #if os(iOS)
    // MARK: - iOS Player Wrappers (v1.6.13)
    //
    // Pulled out of `body` for the same reason as `handleMenuPress`
    // below: the body's modifier chain + the new iPad corner-mini
    // branches together exceed Swift's type-checker budget on tvOS
    // x86_64 ("unable to type-check this expression in reasonable
    // time"). Each helper has its own scope so the budget resets.
    //
    // Both helpers are iOS-only — `MagnificationGesture` and
    // `UIDevice` aren't available on tvOS, and the tvOS branches in
    // the body are expressed inline with their own corner-mini
    // geometry.

    /// Unified-playback multiview wrapper. iPad shrinks to a top-
    /// right corner mini at N=1 mirroring tvOS UX; iPhone keeps the
    /// full-screen MultiviewContainer (the bottom MiniPlayerBar
    /// continues to handle minimize/expand on phone form factor).
    @ViewBuilder
    private var iOSMultiviewWrapper: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let isSoleStream = multiviewStore.tiles.count == 1
            let minimized = isSoleStream && nowPlaying.isMinimized
            GeometryReader { geo in
                let miniW: CGFloat = 400
                let miniH: CGFloat = 225
                ZStack(alignment: .topTrailing) {
                    MultiviewContainerView()
                        .frame(
                            width: minimized ? miniW : geo.size.width,
                            height: minimized ? miniH : geo.size.height
                        )
                        .clipShape(RoundedRectangle(
                            cornerRadius: minimized ? 12 : 0,
                            style: .continuous
                        ))
                        .shadow(
                            color: minimized ? .black.opacity(0.25) : .clear,
                            radius: 8, y: 3
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentPrimary.opacity(0.5), lineWidth: 1)
                                .opacity(minimized ? 1 : 0)
                                .frame(
                                    width: minimized ? miniW : 0,
                                    height: minimized ? miniH : 0
                                )
                                .allowsHitTesting(false)
                        )
                        .disabled(minimized)
                        .allowsHitTesting(!minimized)
                        .padding(.trailing, minimized ? 24 : 0)
                        .padding(.top, minimized ? 24 : 0)
                        // v1.6.13.x: Capture the mini's ACTUAL
                        // bottom edge in global screen coords and
                        // publish it to NowPlayingManager so
                        // ChannelListView can position the chip row
                        // immediately below the real on-screen
                        // bottom — not below the assumed
                        // `topPadding + height` value, which is
                        // wrong on iPad iOS 18 because
                        // `.ignoresSafeArea()` doesn't penetrate
                        // the TabView's top tab-bar chrome,
                        // shifting the mini's effective frame down
                        // by an unknown amount.
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .global).maxY
                        } action: { newValue in
                            if minimized {
                                nowPlaying.miniPlayerBottomAbs = newValue
                            } else if nowPlaying.miniPlayerBottomAbs != 0 {
                                // Mini went away (expanded back to full-screen
                                // or stopped) — clear the published value so
                                // chip row returns to its natural top.
                                nowPlaying.miniPlayerBottomAbs = 0
                            }
                        }
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onEnded { scale in
                                    guard isSoleStream,
                                          !nowPlaying.isMinimized,
                                          scale < 0.85 else { return }
                                    withAnimation(.spring(response: 0.35)) {
                                        nowPlaying.minimize()
                                    }
                                }
                        )

                    // v1.6.13.x: tap-to-expand overlay. When the
                    // mini is in minimized state, MultiviewContainer
                    // is `.disabled(minimized)` to keep tvOS's focus
                    // engine off it — but that also blocks iPad
                    // tap-to-expand. This sibling overlay sits at
                    // exactly the mini's frame and catches taps,
                    // calling `nowPlaying.expand()` to bring back
                    // full-screen playback. Only present when
                    // minimized so it doesn't intercept full-screen
                    // taps. Sibling-in-ZStack so the
                    // `.disabled(minimized)` on MultiviewContainer
                    // can't reach this view.
                    if minimized {
                        Color.clear
                            .frame(width: miniW, height: miniH)
                            .padding(.trailing, 24)
                            .padding(.top, 24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35)) {
                                    nowPlaying.expand()
                                }
                            }
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: minimized ? .topTrailing : .center
                )
                .animation(.spring(response: 0.35), value: minimized)
            }
            .ignoresSafeArea()
            .zIndex(2)
        } else {
            // v1.6.17 — iPhone branch. NO outer `.ignoresSafeArea()`.
            // MultiviewContainerView's internal black background still
            // extends edge-to-edge via its own `Color.black.ignoresSafeArea()`,
            // and `MultiviewSafeAreaModifier` keeps the tile grid INSIDE
            // the safe area on iPhone so the notch / Dynamic Island /
            // home-indicator carve-outs never overlap a tile. Wrapping
            // in `.ignoresSafeArea()` here was the v1.6.17 regression
            // — it cascaded down and overrode the carve-out, putting
            // the tiles back under the cutout.
            MultiviewContainerView()
                .zIndex(2)
        }
    }

    /// Legacy single-stream player wrapper. iPad uses the corner-
    /// mini geometry (no swipe-down — replaced by pinch-to-zoom-out
    /// per v1.6.13 spec); iPhone keeps today's offset-driven swipe-
    /// down minimize behavior unchanged.
    @ViewBuilder
    private func iOSLegacyPlayerWrapper(item: ChannelDisplayItem) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let minimized = nowPlaying.isMinimized
            GeometryReader { geo in
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
                    .shadow(color: minimized ? .black.opacity(0.25) : .clear, radius: 8, y: 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentPrimary.opacity(0.5), lineWidth: 1)
                            .opacity(minimized ? 1 : 0)
                            .frame(
                                width: minimized ? miniW : 0,
                                height: minimized ? miniH : 0
                            )
                            .allowsHitTesting(false)
                    )
                    .allowsHitTesting(!minimized)
                    .padding(.trailing, minimized ? 24 : 0)
                    .padding(.top, minimized ? 24 : 0)
                    // v1.6.13.x: same dynamic mini-bottom capture
                    // as the unified-path wrapper above. See that
                    // comment for rationale.
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).maxY
                    } action: { newValue in
                        if minimized {
                            nowPlaying.miniPlayerBottomAbs = newValue
                        } else if nowPlaying.miniPlayerBottomAbs != 0 {
                            nowPlaying.miniPlayerBottomAbs = 0
                        }
                    }
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onEnded { scale in
                                guard !nowPlaying.isMinimized,
                                      scale < 0.85 else { return }
                                withAnimation(.spring(response: 0.35)) {
                                    nowPlaying.minimize()
                                }
                            }
                    )

                    // v1.6.13.x: tap-to-expand overlay (legacy
                    // path). Same rationale as the unified-path
                    // wrapper above.
                    if minimized {
                        Color.clear
                            .frame(width: miniW, height: miniH)
                            .padding(.trailing, 24)
                            .padding(.top, 24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35)) {
                                    nowPlaying.expand()
                                }
                            }
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: minimized ? .topTrailing : .center
                )
                .animation(.spring(response: 0.35), value: minimized)
            }
            .ignoresSafeArea()
            .zIndex(2)
        } else {
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
                .id(item.id)
                .ignoresSafeArea()
                .offset(y: nowPlaying.isMinimized ? max(0, containerH + miniPlayerDragOffset) : 0)
                .opacity(nowPlaying.isMinimized ? min(1, -miniPlayerDragOffset / 300) : 1)
                .allowsHitTesting(!nowPlaying.isMinimized)
            }
            .ignoresSafeArea()
        }
    }
    #endif

    #if os(tvOS)
    /// Apple TV Menu-button handler. Pulled out of `.onExitCommand`
    /// because the inline closure repeatedly tripped Swift's
    /// type-inference budget ("unable to type-check this expression in
    /// reasonable time") as the if/else chain grew with the v1.6.x
    /// tab-state additions. A plain method has its own scope so the
    /// budget resets cleanly.
    private func handleMenuPress() {
        debugLog("🎮 [HMP] handleMenuPress | isActive=\(nowPlaying.isActive) isMinimized=\(nowPlaying.isMinimized) isVODDetailPushed=\(isVODDetailPushed) isSettingsSubviewPushed=\(isSettingsSubviewPushed) selectedTab=\(selectedTab.rawValue) playerSession.mode=\(playerSession.mode)")
        if nowPlaying.isActive && !nowPlaying.isMinimized {
            // GH #11: hand off to PlayerView's chrome cycle instead
            // of minimizing directly. PlayerView's `.onExitCommand`
            // would handle this correctly if it had focus, but after
            // expanding from mini via Play/Pause focus is typically
            // still on the guide cell — so the outer handler catches
            // the press first, and we end up here. Posting the
            // notification lets PlayerView run the same
            // hidden-chrome-shows / shown-chrome-minimizes cycle it
            // would have run for a focused press, which is what the
            // user expects ("first Back reveals Stream UI, second
            // Back minimizes").
            debugLog("🎮 [HMP]   → branch: full-screen player → posting .playerBackPress")
            NotificationCenter.default.post(name: .playerBackPress, object: nil)
        } else if nowPlaying.isActive && nowPlaying.isMinimized {
            // Under unified playback, the mini is N=1 multiview
            // collapsed to a corner. Fully stopping requires
            // `PlayerSession.shared.stop()` — it tears down
            // MultiviewStore + mpv + flips mode to `.idle`.
            // `nowPlaying.stop()` alone only clears lockscreen
            // metadata and leaves the container rendering.
            debugLog("🎮 Menu pressed: mini player → stop playback")
            PlayerSession.shared.stop()
        } else if isVODDetailPushed {
            // Pop the VOD detail view back to the browse list.
            // We must do this programmatically because .onExitCommand consumes
            // the Menu event before NavigationStack can handle it.
            debugLog("🎮 Menu pressed: VOD detail pushed → popping to browse list")
            isVODDetailPushed = false
            vodNavPopRequested = true
        } else if isSettingsSubviewPushed {
            // Same problem as VOD: our `.onExitCommand` intercepts Menu
            // before SettingsView's NavigationStack can pop. Signal
            // SettingsView to pop its innermost pushed level — classic
            // stack first (ServerDetailView, MyRecordingsView), then
            // navPath (Appearance, Guide Display, Network, DVR,
            // Developer, Edit Server). SettingsView resets the flag.
            debugLog("🎮 Menu pressed: Settings subview pushed → popping")
            settingsPopRequested = true
        } else if selectedTab == .liveTV {
            // Menu on the guide (nothing playing, no mini) =
            // "take me back to the top of the list". Matches the
            // Apple TV / Music convention for long lists. Posted
            // as a notification so ChannelListView can scroll its
            // internal ScrollViewReader without HomeView having
            // to hold a binding through the tab view hierarchy.
            debugLog("🎮 Menu pressed: Live TV tab → scroll guide to top")
            NotificationCenter.default.post(name: .guideScrollToTop, object: nil)
        } else {
            let tabName = selectedTab.rawValue
            debugLog("🎮 Menu pressed: " + tabName + " tab → switch to Live TV")
            selectedTab = .liveTV
        }
    }
    #endif

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

// MARK: - Background Work Details View
//
// Presented (iOS popover / tvOS fullScreenCover) when the user
// taps / selects the top-left "Syncing…" badge. Shows each active
// task on its own row with a subtle progress dot, plus the total
// elapsed-seconds counter for the background-work window. The
// content is a plain value-type snapshot — labels + elapsed are
// passed in by the caller at present-time; the view doesn't
// observe anything, so if the background state changes while the
// modal is open the user sees the moment-of-open snapshot rather
// than a live-updating list. Dismissing and re-opening shows the
// fresh state. Keeps the view stateless and avoids any chance of
// re-triggering the very invalidation cascade we were trying to
// surface.
private struct BackgroundWorkDetailsView: View {
    let labels: [String]
    let elapsedSeconds: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iOSBody
        #endif
    }

    #if os(iOS)
    private var iOSBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Background Activity")
                    .font(.headline)
                Spacer()
            }

            if labels.isEmpty {
                Text("Nothing running right now.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(labels, id: \.self) { label in
                        HStack(spacing: 10) {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 11))
                                .foregroundColor(.accentPrimary)
                            Text(label)
                                .font(.body)
                                .foregroundColor(.textPrimary)
                        }
                    }
                }
            }

            Divider()
            Text("Elapsed: \(elapsedSeconds)s")
                .font(.caption)
                .foregroundColor(.textTertiary)
        }
        .padding(16)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340, alignment: .leading)
    }
    #endif

    #if os(tvOS)
    private var tvBody: some View {
        ZStack(alignment: .topTrailing) {
            Color.appBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 16) {
                    ProgressView().scaleEffect(1.4)
                    Text("Background Activity")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.textPrimary)
                }

                if labels.isEmpty {
                    Text("Nothing running right now.")
                        .font(.system(size: 24))
                        .foregroundColor(.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(labels, id: \.self) { label in
                            HStack(spacing: 18) {
                                Image(systemName: "circle.dotted")
                                    .font(.system(size: 22))
                                    .foregroundColor(.accentPrimary)
                                Text(label)
                                    .font(.system(size: 28))
                                    .foregroundColor(.textPrimary)
                            }
                        }
                    }
                }

                Text("Elapsed: \(elapsedSeconds)s")
                    .font(.system(size: 20))
                    .foregroundColor(.textTertiary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 72)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Button("Close") { dismiss() }
                .padding(.top, 48)
                .padding(.trailing, 64)
        }
        .onExitCommand { dismiss() }
    }
    #endif
}


// MARK: - Channel Info Banner (v1.6.15)

/// Top-left HUD that briefly identifies the current live channel +
/// program when a new stream starts, fades together with the player
/// chrome's auto-fade. Cross-platform; rendered in HomeView's outer
/// ZStack so it sits above the mini player + reminder banner. Only
/// renders for single-stream playback (suppressed in multi-tile
/// multiview because the user is comparing streams and an overlaid
/// channel-info chip would be noise).
///
/// Visibility model: a single shared `NowPlayingManager.chromeIsVisible`
/// flag, written to by the multiview chrome (`MultiviewContainerView`)
/// and the legacy player chrome (`PlayerView`'s `showControls`). When
/// either chrome shows or hides, this banner rides along. Stream
/// starts also wake the chrome, so the banner appears together with
/// the chrome on every channel-flip — no separate timer.
private struct ChannelInfoBanner: View {
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    @ObservedObject private var guideStore = GuideStore.shared
    @ObservedObject private var multiviewStore = MultiviewStore.shared

    /// Local 5s window that opens on every `streamStartedToken`
    /// bump. Lets the banner appear on a Siri Remote channel-flip
    /// without dragging chrome up with it (chrome stays hidden so
    /// the next up/down keeps flipping channels instead of walking
    /// the bottom pills).
    @State private var bannerWindowActive: Bool = false
    @State private var bannerHideTask: Task<Void, Never>?

    /// Renders when EITHER (a) chrome is up — handles brand-new
    /// stream starts (cold-launch / row-tap that bump
    /// `chromeWakeToken`) and Menu/Back chrome summon, OR (b) we're
    /// inside the 5s post-stream-start window — handles channel-
    /// scroll where chrome stays hidden. Suppressed in multi-tile
    /// multiview AND when the player isn't actively visible
    /// (minimized to the corner mini, or stopped entirely) — the
    /// banner is a "what just started playing in the player" cue,
    /// so it shouldn't drift over to the TV Guide tab when the
    /// user has dropped the player to the corner or closed it.
    ///
    /// v1.6.18: also suppressed while the Stream Info overlay is
    /// open. On iPhone the two overlays render at the same
    /// top-left coordinates and would otherwise overlap — banner
    /// would cover the stats card the user explicitly opened.
    private var shouldRender: Bool {
        let isSingleStream = multiviewStore.tiles.count <= 1
        let isFullscreenActive = nowPlaying.isActive && !nowPlaying.isMinimized
        return (nowPlaying.chromeIsVisible || bannerWindowActive)
            && isSingleStream
            && isFullscreenActive
            && !nowPlaying.streamInfoIsVisible
    }

    /// Resolve current program for this channel. First the
    /// lightweight `ChannelDisplayItem.currentProgram*` fields
    /// (cheap, populated for Xtream + Dispatcharr current-programs
    /// cache); fall back to `GuideStore.programs[id].first(where:
    /// \.isLive)` for the bulk-EPG path. Same two-source pattern
    /// `ChannelListView` uses for row subtitles. Returns nil when
    /// neither source has data — the banner then shows just channel
    /// number + name.
    private func liveProgram(for item: ChannelDisplayItem) -> (title: String, start: Date, end: Date)? {
        if let title = item.currentProgram, !title.isEmpty,
           let start = item.currentProgramStart,
           let end = item.currentProgramEnd {
            return (title, start, end)
        }
        if let p = guideStore.programs[item.id]?.first(where: { $0.isLive }) {
            return (p.title, p.start, p.end)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shouldRender, let item = nowPlaying.playingItem, nowPlaying.isLive {
                bannerContent(for: item)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        // v1.6.18: same safe-area carve-out as the chrome and
        // Stream Info overlays — the `iOSDynamicTopInset` formula
        // was designed against an absolute screen-top reference.
        // Without ignoresSafeArea, the parent's safe-area-top
        // (~59pt on Dynamic Island devices) gets added on top of
        // the formula's own clearance, floating the banner ~130pt
        // below the screen top in iPhone portrait. Anchoring at
        // the literal screen top restores the intended ~71pt
        // offset that hugs the Dynamic Island.
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        #endif
        // Open the 5s banner-window every time a new stream starts
        // (live only — token only bumps for live in NowPlayingManager).
        // Independent of chrome so a channel-scroll surfaces just the
        // banner. If chrome is already up (Menu/Back, brand-new
        // stream-start that bumped `chromeWakeToken`), the banner is
        // shown via that path too — both signals together are
        // idempotent.
        .onChange(of: nowPlaying.streamStartedToken) { _, newToken in
            guard newToken != nil else { return }
            bannerWindowActive = true
            bannerHideTask?.cancel()
            bannerHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                bannerWindowActive = false
            }
        }
        .animation(.easeInOut(duration: 0.3), value: nowPlaying.chromeIsVisible)
        .animation(.easeInOut(duration: 0.3), value: bannerWindowActive)
        .animation(.easeInOut(duration: 0.3), value: multiviewStore.tiles.count)
    }

    @ViewBuilder
    private func bannerContent(for item: ChannelDisplayItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let url = item.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fit)
                    default:
                        Color.clear
                    }
                }
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !item.number.isEmpty {
                        Text(item.number)
                            .font(channelNumberFont)
                            .foregroundColor(.white.opacity(0.55))
                    }
                    Text(item.name)
                        .font(channelNameFont)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                if let prog = liveProgram(for: item) {
                    Text(prog.title)
                        .font(programFont)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)

                    if let timeAndDuration = airingTimeAndDuration(start: prog.start, end: prog.end) {
                        Text(timeAndDuration)
                            .font(timeFont)
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .frame(maxWidth: maxBannerWidth, alignment: .leading)
        .padding(.top, topPadding)
        .padding(.leading, sidePadding)
    }

    /// "10:00 PM – 11:30 PM · 1h 30m" — single line, falls back to
    /// nil when the airing window is invalid (defensive — guards
    /// against inverted EPG payloads).
    private func airingTimeAndDuration(start: Date, end: Date) -> String? {
        guard end > start else { return nil }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let window = "\(f.string(from: start)) – \(f.string(from: end))"

        let totalMinutes = Int(end.timeIntervalSince(start) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let durationStr: String
        if hours > 0 && minutes > 0 {
            durationStr = "\(hours)h \(minutes)m"
        } else if hours > 0 {
            durationStr = "\(hours)h"
        } else {
            durationStr = "\(minutes)m"
        }
        return "\(window) · \(durationStr)"
    }

    // MARK: Per-platform sizing

    private var logoSize: CGFloat {
        #if os(tvOS)
        return 56
        #else
        return 36
        #endif
    }
    private var channelNumberFont: Font {
        #if os(tvOS)
        return .system(size: 26, weight: .medium)
        #else
        return .system(size: 15, weight: .medium)
        #endif
    }
    private var channelNameFont: Font {
        #if os(tvOS)
        return .system(size: 28, weight: .semibold)
        #else
        return .system(size: 16, weight: .semibold)
        #endif
    }
    private var programFont: Font {
        #if os(tvOS)
        return .system(size: 22)
        #else
        return .system(size: 14)
        #endif
    }
    private var timeFont: Font {
        #if os(tvOS)
        return .system(size: 18)
        #else
        return .system(size: 12)
        #endif
    }
    private var verticalPadding: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 10
        #endif
    }
    private var maxBannerWidth: CGFloat {
        #if os(tvOS)
        return 720
        #else
        return 460
        #endif
    }
    private var topPadding: CGFloat {
        #if os(tvOS)
        return 32
        #else
        // iPhone PORTRAIT: below the chrome's close button row
        // (close button column is too narrow to share with the
        // banner). iPhone LANDSCAPE / iPad / Mac: align with the
        // close button's vertical center; banner sits to its right
        // since the wider screen has horizontal headroom.
        // v1.6.18: split iPhone landscape from portrait per
        // user feedback — landscape has plenty of horizontal room
        // and the previous "below close button" placement looked
        // awkward.
        if isiPhonePortrait {
            return iOSDynamicTopInset + 60  // close-button height (52) + 8pt spacing
        } else {
            return iOSDynamicTopInset
        }
        #endif
    }
    private var sidePadding: CGFloat {
        #if os(tvOS)
        return 40
        #else
        // iPhone PORTRAIT: left edge (banner sits below the close
        // button so there's no horizontal conflict). iPhone
        // LANDSCAPE / iPad / Mac: clear the close button —
        // `chrome.padding(.horizontal, 16)` + 52pt close-button
        // width + 12pt breathing room = 80pt. v1.6.18: iPhone
        // landscape now matches iPad here so the banner sits to
        // the right of the close button instead of below it.
        if isiPhonePortrait {
            return 8
        } else {
            return 80
        }
        #endif
    }

    #if !os(tvOS)
    /// Replicates `PlaybackChromeOverlay.dynamicTopInset` so the
    /// banner stays vertically aligned with the chrome's close /
    /// overflow / add buttons across every iPhone, iPad, and Mac
    /// Catalyst form factor without hard-coding device tables. See
    /// PlaybackChromeOverlay.swift for the full reasoning.
    private var iOSDynamicTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first

        let windowInset: CGFloat = {
            guard let scene else { return 0 }
            if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                return key.safeAreaInsets.top
            }
            return scene.windows.first?.safeAreaInsets.top ?? 0
        }()
        let statusBarHeight = scene?.statusBarManager?.statusBarFrame.height ?? 0

        let isLandscapePhone: Bool = {
            guard isiPhoneIdiom else { return false }
            return scene?.interfaceOrientation.isLandscape ?? false
        }()
        let floor: CGFloat = isLandscapePhone ? 20 : 48
        return max(max(windowInset, statusBarHeight) + 12, floor)
    }

    /// True only on physical iPhone (UIDevice idiom `.phone`).
    /// iPad / Mac Catalyst / Apple TV all return false.
    private var isiPhoneIdiom: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// v1.6.18: True only on iPhone in portrait orientation. Used
    /// to gate the banner's "below close button" layout — landscape
    /// iPhone now sits the banner to the right of the close button
    /// (matching iPad) since the wider screen has horizontal room.
    private var isiPhonePortrait: Bool {
        guard isiPhoneIdiom else { return false }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        return scene?.interfaceOrientation.isPortrait ?? true
    }
    #endif
}

#if os(iOS)
// MARK: - Mini Player Chrome Modifier

/// Wraps the `MultiviewContainerView` with the mini-player visual
/// chrome (rounded clip + drop shadow) when, and only when, the
/// player is in its minimized state. Applying these modifiers
/// unconditionally — even with cornerRadius=0 / color=.clear —
/// inserts a mask layer + shadow rendering pass into the layer
/// tree at fullscreen, and that extra layer stack was interfering
/// with iOS's auto-PiP restore animation (the transition fell back
/// to the generic "zoom + PiP-icon" placeholder because iOS's
/// floating-window → source-layer animation couldn't cleanly
/// animate through the mask/shadow stack). Using a ViewModifier
/// keeps the wrapped view's identity stable across the branch
/// (SwiftUI's `_ConditionalContent` preserves view identity for
/// the `content` parameter), so flipping between minimized and
/// fullscreen doesn't rebuild `MultiviewContainerView` and tear
/// down the active mpv player.
private struct MiniPlayerChromeModifier: ViewModifier {
    let minimized: Bool

    func body(content: Content) -> some View {
        if minimized {
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 20, y: 8)
        } else {
            content
        }
    }
}

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

