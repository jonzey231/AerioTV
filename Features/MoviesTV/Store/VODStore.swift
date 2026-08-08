import SwiftUI
import SwiftData
import Foundation
import Security

// Extracted VERBATIM from HomeView.swift (lines 12-794) as the first step of
// the Movies & TV rebuild: HomeView was the project's largest file and owned
// this store for historical reasons only. Nothing about the type changed in
// the move, so its behaviour (including the hard-won tvOS AttributeGraph
// publish batching) is byte-for-byte what shipped.


// MARK: - VOD Store
// Shared ObservableObject owned by MainTabView.
// Pre-fetches movies and series as soon as VOD servers are available,
// and re-fetches whenever the server list changes so Movies/Series tabs
// stay current without waiting for the user to switch to them.
@MainActor
final class VODStore: ObservableObject {

    /// Shared instance, mirroring `ChannelStore.shared` /
    /// `NowPlayingManager.shared`. Lets non-Home views (Settings'
    /// delete-playlist flow) reach VOD state without environment-object
    /// plumbing. MainTabView observes this same instance.
    static let shared = VODStore()

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

    /// The server ID whose movies were last loaded against. Set by
    /// `loadMovies` when it begins, retained even when the load
    /// completes with zero results so the views' `.onAppear` retry
    /// guards can tell "we already tried for this server" from
    /// "this is a fresh server we haven't looked at yet" without
    /// having to keep their own per-view bookkeeping. v1.6.22:
    /// promoted from `private` so `MoviesView.onAppear` can check
    /// it before re-firing `refreshMovies` when `movies.isEmpty`.
    @Published private(set) var currentMoviesServerID: UUID? = nil
    /// Series equivalent of `currentMoviesServerID`. Same v1.6.22
    /// promotion rationale: `TVShowsView.onAppear` was re-firing
    /// `refreshSeries` every time the view rebuilt after a load
    /// that returned zero series (Freyguy1975's repro looped through
    /// dozens of identical loads). The view now checks this id and
    /// skips the auto-refresh when we've already attempted a load
    /// for the active server.
    @Published private(set) var currentSeriesServerID: UUID? = nil

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
            // SSRF gate: a malicious VOD source could emit poster URLs that
            // point at localhost / link-local / a LAN IP to probe the user's
            // network. Validate against the configured server host, matching
            // VODService.resolveURL (this used to trust the raw URL blindly).
            guard let url = URL(string: raw) else { return nil }
            let serverHost = URL(string: base)?.host
            return VODService.validateAbsoluteURL(url, serverHost: serverHost)
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

    /// Wipe all in-memory VOD state. Called when a playlist/server is
    /// deleted so On Demand stops showing the removed server's movies and
    /// series (issue #25: Live cleared via ChannelStore but VOD lingered,
    /// surfacing stale entries that no longer played). The next active
    /// server (if any) repopulates via `refresh()`; with no server
    /// remaining, everything stays empty.
    func clear() {
        moviesTask?.cancel(); moviesTask = nil
        seriesTask?.cancel(); seriesTask = nil
        movieSearchTask?.cancel(); movieSearchTask = nil
        seriesSearchTask?.cancel(); seriesSearchTask = nil
        movies = []; movieCategories = []; moviesError = nil
        isLoadingMovies = false; isRefillingMovies = false
        series = []; seriesCategories = []; seriesError = nil
        isLoadingSeries = false; isRefillingSeries = false
        movieSearchResults = []; isSearchingMovies = false
        seriesSearchResults = []; isSearchingSeries = false
        currentMoviesServerID = nil; currentSeriesServerID = nil
        lastMoviesServerName = nil; lastSeriesServerName = nil
    }

    func refreshMovies(servers: [ServerConnection]) {
        moviesTask?.cancel()
        moviesTask = Task { await loadMovies(servers: servers) }
    }

    func refreshSeries(servers: [ServerConnection]) {
        seriesTask?.cancel()
        seriesTask = Task { await loadSeries(servers: servers) }
    }

    /// v1.6.21: awaitable variant of `refreshMovies` for the
    /// initial-sync orchestrator that needs to wait for movies
    /// to fully complete before kicking off series. The fire-and-
    /// forget `refreshMovies` sets up a Task and returns immediately,
    /// which left a race where the orchestrator's wait loop on
    /// `isRefillingMovies` could fall through before `loadMovies`
    /// had a chance to flip that flag. Awaiting `task.value`
    /// guarantees the caller observes a completed (or cancelled)
    /// load.
    func refreshMoviesAndWait(servers: [ServerConnection]) async {
        moviesTask?.cancel()
        let task = Task { await loadMovies(servers: servers) }
        moviesTask = task
        await task.value
    }

    /// v1.6.21: awaitable variant of `refreshSeries` mirroring
    /// `refreshMoviesAndWait`. Used by the initial-sync orchestrator
    /// to sequence series strictly after movies.
    func refreshSeriesAndWait(servers: [ServerConnection]) async {
        seriesTask?.cancel()
        let task = Task { await loadSeries(servers: servers) }
        seriesTask = task
        await task.value
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
        // v1.6.20: capture per-server auth shape for the off-main API client.
        let authMode = server.dispatcharrHeaderMode
        let userAgent = server.effectiveUserAgent
        isSearchingMovies = true
        movieSearchTask = Task {
            let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                     userAgent: userAgent, authMode: authMode)
            var results: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            // v1.7.x: widened from 0.5s to 2.0s. On a large library (e.g.
            // 5000 movies over a ~30s paginated load) the old cadence
            // republished the whole growing array up to 2x/sec on the main
            // actor, each reassign forcing a full SwiftUI diff. Under the
            // tvOS 26.5 SwiftUI runtime that cold-start churn (alongside the
            // channel/EPG publishes) drives heavy display-list rebuilds that
            // both produce the watchdog hangs AND raise the odds of the
            // AttributeGraph "different namespace" abort. The user lands on
            // Live TV during this load, so a chunkier VOD fill is invisible.
            let publishInterval: TimeInterval = 2.0
            do {
                for try await batch in api.searchVODMoviesStream(query: query) {
                    guard !Task.isCancelled else { break }
                    let items = batch.map { m -> VODDisplayItem in
                        var movie = VODMovie(
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
                        // Stamp the tmdb id: the Known For deep-link's strict
                        // id tier walks search results too, and an id-less row
                        // would fall through to the title fallback where a
                        // same-named remake could hijack the match.
                        movie.tmdbID = m.tmdbID ?? ""
                        return VODDisplayItem(movie: movie)
                    }
                    results += items
                    let now = Date()
                    if now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        movieSearchResults = results
                        lastPublishTime = now
                    }
                }
            } catch {
                // Don't swallow silently. Skip logging when the task was
                // cancelled (expected on every query change), but surface a
                // real network/parse failure so an empty result set is
                // diagnosable instead of mysterious.
                if !Task.isCancelled {
                    debugLog("🔎 [Search] movie search stream error: \(error.localizedDescription)")
                }
            }
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
        // v1.6.20: capture per-server auth shape for the off-main API client.
        let authMode = server.dispatcharrHeaderMode
        let userAgent = server.effectiveUserAgent
        isSearchingSeries = true
        seriesSearchTask = Task {
            let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                     userAgent: userAgent, authMode: authMode)
            var results: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            // v1.7.x: widened from 0.5s to 2.0s. On a large library (e.g.
            // 5000 movies over a ~30s paginated load) the old cadence
            // republished the whole growing array up to 2x/sec on the main
            // actor, each reassign forcing a full SwiftUI diff. Under the
            // tvOS 26.5 SwiftUI runtime that cold-start churn (alongside the
            // channel/EPG publishes) drives heavy display-list rebuilds that
            // both produce the watchdog hangs AND raise the odds of the
            // AttributeGraph "different namespace" abort. The user lands on
            // Live TV during this load, so a chunkier VOD fill is invisible.
            let publishInterval: TimeInterval = 2.0
            do {
                for try await batch in api.searchVODSeriesStream(query: query) {
                    guard !Task.isCancelled else { break }
                    let items = batch.map { s -> VODDisplayItem in
                        var show = VODSeries(
                            id: String(s.id), name: s.name,
                            posterURL: s.posterURL.flatMap { resolveURL($0, base: baseURL) },
                            backdropURL: nil,
                            rating: s.rating ?? "", plot: s.plot ?? "",
                            genre: s.genre ?? "", releaseDate: "",
                            cast: "", director: "",
                            categoryID: "", categoryName: "Series",
                            serverID: sID, seasons: [], episodeCount: 0
                        )
                        // Same tmdb-id stamping rationale as the movie
                        // search mapper above (Known For strict-id tier).
                        show.tmdbID = s.tmdbID ?? ""
                        return VODDisplayItem(series: show)
                    }
                    results += items
                    let now = Date()
                    if now.timeIntervalSince(lastPublishTime) >= publishInterval {
                        seriesSearchResults = results
                        lastPublishTime = now
                    }
                }
            } catch {
                // Surface real failures; stay quiet on the expected
                // query-change cancellation (see movie search above).
                if !Task.isCancelled {
                    debugLog("🔎 [Search] series search stream error: \(error.localizedDescription)")
                }
            }
            if !Task.isCancelled {
                seriesSearchResults = results
                isSearchingSeries = false
            }
        }
    }

    /// Known For deep-link support (Android parity dossier Part 1 sec 6):
    /// merge a one-shot server-search hit into the browse list BEFORE the
    /// detail push, so the pushed screen's own lookups can resolve the
    /// item. Appended only when absent (movies dedupe by id, series too;
    /// both ids are stable server ids here).
    func mergeKnownForHit(_ item: VODDisplayItem) {
        switch item.type {
        case .movie:
            guard !movies.contains(where: { $0.id == item.id }) else { return }
            movies.append(item)
        case .series:
            guard !series.contains(where: { $0.id == item.id }) else { return }
            series.append(item)
        case .episode:
            // Known For tiles only ever resolve to movies or series.
            break
        }
    }

    /// Exposes the search-result row mapper for the Known For one-shot
    /// lookup so its rows are shaped identically to regular search hits
    /// (including the resolved poster URL and proxy stream URL).
    func makeSearchMovieItem(_ m: DispatcharrVODMovie, api: DispatcharrAPI, baseURL: String, serverID: UUID) -> VODDisplayItem {
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
            containerExtension: "mp4", serverID: serverID
        )
        var item = movie
        item.tmdbID = m.tmdbID ?? ""
        return VODDisplayItem(movie: item)
    }

    func makeSearchSeriesItem(_ s: DispatcharrVODSeries, baseURL: String, serverID: UUID) -> VODDisplayItem {
        var show = VODSeries(
            id: String(s.id), name: s.name,
            posterURL: s.posterURL.flatMap { resolveURL($0, base: baseURL) },
            backdropURL: nil,
            rating: s.rating ?? "", plot: s.plot ?? "",
            genre: s.genre ?? "", releaseDate: "",
            cast: "", director: "",
            categoryID: "", categoryName: "Series",
            serverID: serverID, seasons: [], episodeCount: 0
        )
        show.tmdbID = s.tmdbID ?? ""
        return VODDisplayItem(series: show)
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
            // v1.6.20: per-server auth shape capture.
            let authMode = server.dispatcharrHeaderMode
            let userAgent = server.effectiveUserAgent
            debugLog("🎬 VODStore.loadMovies: dispatcharr baseURL=\(DebugLogger.sanitize(baseURL)), hasKey=\(!apiKey.isEmpty)")
            let api     = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                         userAgent: userAgent, authMode: authMode)

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
            // flat unfiltered fetch; that was the old bug where we'd
            // show everything Dispatcharr had.
            if enabledMovieCats.isEmpty {
                movies = []
                isLoadingMovies = false
                debugLog("🎬 VODStore.loadMovies: no enabled movie categories, nothing to fetch")
                return
            }

            // v1.7.5: per-category fetch so every movie carries its REAL
            // Dispatcharr category. The movie LIST response omits the
            // category (it lives on the m3u_relations reverse relation, not
            // a top-level field), so the prior single unfiltered sweep
            // could only tag everything to one fallback bucket, which is
            // why the On Demand category filter appeared to do nothing
            // (sjsteve, v1.7.5). Dispatcharr's MovieFilter DOES filter on
            // `?category=<name>|movie` (apps/vod/api_views.py
            // filter_category, matching m3u_relations__category name+type),
            // the same category data TiviMate/iMPlayer filter via the
            // Xtream `category_id`. So fetch one stream per enabled category
            // and tag each movie from the category we asked for. Sequential
            // (not parallel) to avoid saturating Dispatcharr's uwsgi pool.
            // Dedup by uuid across categories: a movie in two categories is
            // tagged with whichever loads first. The per-category [VOD-CAT]
            // counts confirm the server honored the filter (each category a
            // subset) vs ignored it (first category claims everything).
            var accumulated: [VODDisplayItem] = []
            var seenUUIDs: Set<String> = []
            var lastError: APIError?
            let totalCap = 5000   // global memory ceiling on huge libraries
            // Fair share per category so one big early category can't drain
            // the whole budget and leave later enabled categories empty
            // (verified against the test server: 21 enabled movie categories,
            // several with thousands of titles). Page-align the share to the
            // 100-item page size so makePageStream stops exactly on a page
            // boundary (a non-aligned share overshoots by up to a page and
            // re-starves the tail). All N categories then fit inside totalCap
            // (21 x 200 = 4200 <= 5000), so every enabled category is
            // represented; server-side search covers anything past a
            // category's browsable sample.
            let perCatCap = max((totalCap / 100 / max(enabledMovieCats.count, 1)) * 100, 100)
            debugLog("🎬 VODStore.loadMovies: per-category fetch across \(enabledMovieCats.count) enabled categories (cap \(perCatCap)/cat, \(totalCap) total)")

            categoryLoop: for cat in enabledMovieCats {
                guard !Task.isCancelled else { isLoadingMovies = false; return }
                let category = VODCategory(id: String(cat.id), name: cat.name)
                let before = accumulated.count
                do {
                    // getVODMoviesStream pins the `|movie` type on the name.
                    for try await batch in api.getVODMoviesStream(category: cat.name, itemCap: perCatCap) {
                        guard !Task.isCancelled else { isLoadingMovies = false; return }
                        for m in batch {
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
                        // First batch overall: reveal content + hide the
                        // spinner. Then accumulate silently; the full set
                        // publishes once after the sweep. Two publishes
                        // total preserves the tvOS AttributeGraph-crash
                        // mitigation (no progressive per-batch churn).
                        if isLoadingMovies {
                            movies = accumulated
                            isLoadingMovies = false
                        }
                        if accumulated.count >= totalCap { break }
                    }
                } catch let err as APIError {
                    // One category failing must not abort the whole sweep.
                    lastError = err
                    DebugLogger.shared.logError(err, context: "VODStore.loadMovies(\(server.name)) cat=\(cat.name)")
                } catch {
                    DebugLogger.shared.log(
                        "VODStore.loadMovies(\(server.name)) cat=\(cat.name) error: \(error.localizedDescription)",
                        category: "Movies", level: .warning
                    )
                }
                debugLog("🎬 [VOD-CAT] \(cat.name): +\(accumulated.count - before) (total \(accumulated.count))")
                // Cold-load yields to playback (2026-06-29): when a live stream is
                // playing, breathe between category sweeps so the main-actor JSON
                // decode + struct-build bursts don't starve the live decoder on the
                // same main thread (see the fetchUpcoming note in the orchestrator).
                // No-op when nothing is playing — full-speed load.
                if !MultiviewStore.shared.tiles.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if accumulated.count >= totalCap {
                    debugLog("🎬 VODStore.loadMovies: hit total cap \(totalCap), stopping category sweep")
                    break categoryLoop
                }
            }

            // Surface an error only if the whole sweep produced nothing.
            if accumulated.isEmpty, let lastError {
                moviesError = lastError.errorDescription
            }
            movies = accumulated
            isLoadingMovies = false
            debugLog("🎬 VODStore.loadMovies: done, \(accumulated.count) movies across \(enabledMovieCats.count) categories")
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
            // v1.6.20: per-server auth shape capture.
            let authMode = server.dispatcharrHeaderMode
            let userAgent = server.effectiveUserAgent
            let api     = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                         userAgent: userAgent, authMode: authMode)

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

            // v1.7.5: per-category fetch (mirrors loadMovies). The series
            // list response omits the category, so a single unfiltered
            // sweep could only tag everything to one fallback bucket,
            // breaking the On Demand category filter. Dispatcharr's
            // SeriesFilter DOES filter on `?category=<name>|series`
            // (verified against the live server), so fetch one stream per
            // enabled category and tag from what we asked for. Sequential;
            // dedup by uuid across categories.
            var accumulated: [VODDisplayItem] = []
            var seenUUIDs: Set<String> = []
            var lastError: APIError?
            let totalCap = 5000   // global memory ceiling on huge libraries
            // Fair share per category, page-aligned (see loadMovies) so a
            // big early category can't drain the budget and leave later
            // enabled categories empty.
            let perCatCap = max((totalCap / 100 / max(enabledSeriesCats.count, 1)) * 100, 100)
            debugLog("📺 VODStore.loadSeries: per-category fetch across \(enabledSeriesCats.count) enabled categories (cap \(perCatCap)/cat, \(totalCap) total)")

            categoryLoop: for cat in enabledSeriesCats {
                guard !Task.isCancelled else { isLoadingSeries = false; return }
                let category = VODCategory(id: String(cat.id), name: cat.name)
                let before = accumulated.count
                do {
                    // getVODSeriesStream pins the `|series` type on the name.
                    for try await batch in api.getVODSeriesStream(category: cat.name, itemCap: perCatCap) {
                        guard !Task.isCancelled else { isLoadingSeries = false; return }
                        for s in batch {
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
                        if isLoadingSeries {
                            series = accumulated
                            isLoadingSeries = false
                        }
                        if accumulated.count >= totalCap { break }
                    }
                } catch let err as APIError {
                    lastError = err
                    DebugLogger.shared.logError(err, context: "VODStore.loadSeries(\(server.name)) cat=\(cat.name)")
                } catch {
                    DebugLogger.shared.log(
                        "VODStore.loadSeries(\(server.name)) cat=\(cat.name) error: \(error.localizedDescription)",
                        category: "TVShows", level: .warning
                    )
                }
                debugLog("📺 [VOD-CAT] \(cat.name): +\(accumulated.count - before) (total \(accumulated.count))")
                // Cold-load yields to playback (2026-06-29): pace the series sweep
                // while a live stream is playing — same rationale as loadMovies and
                // the orchestrator fetchUpcoming hold. No-op when idle.
                if !MultiviewStore.shared.tiles.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if accumulated.count >= totalCap {
                    debugLog("📺 VODStore.loadSeries: hit total cap \(totalCap), stopping category sweep")
                    break categoryLoop
                }
            }

            if accumulated.isEmpty, let lastError {
                seriesError = lastError.errorDescription
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
