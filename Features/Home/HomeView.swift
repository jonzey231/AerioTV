import SwiftUI
import SwiftData
import Foundation
import Security

// MARK: - VOD Store
// Shared ObservableObject owned by MainTabView.
// Pre-fetches movies and series as soon as VOD servers are available,
// and re-fetches whenever the server list changes so Movies/Series tabs
// stay current without waiting for the user to switch to them.
//
// GH #109 (2026-09-16): the catalog itself no longer lives here. Titles are
// written page by page into `VODCatalogStore` (a SQLite file under
// AppCacheDirectory) as the sweep walks the provider, and the tabs read
// WINDOWS of it. This object now publishes only what the UI needs to know
// ABOUT the catalog: how many titles each kind holds, the category list, the
// loading and error state, and a revision counter the views rebuild their
// windowed lists from. Memory is therefore flat in the size of the library,
// which is what lets a 350,000 title Dispatcharr account browse on an Apple
// TV HD. This matches the Android app's Room-backed VodCatalogStore.
@MainActor
final class VODStore: ObservableObject {

    /// Shared instance, mirroring `ChannelStore.shared` /
    /// `NowPlayingManager.shared`. Lets non-Home views (Settings'
    /// delete-playlist flow) reach VOD state without environment-object
    /// plumbing. MainTabView observes this same instance.
    static let shared = VODStore()

    private let catalog = VODCatalogStore.shared

    /// The catalog identity the tabs are currently showing: server UUID plus
    /// base URL plus account, the same string `VODLibraryCache.identity`
    /// builds. Every catalog read and write is keyed by it, so another
    /// playlist's rows can never be served here and a playlist switch keeps
    /// both catalogs on disk.
    @Published private(set) var catalogKey: String?
    /// How many titles the catalog holds for this playlist. The views use it
    /// where they used `movies.count` / `movies.isEmpty`.
    @Published private(set) var moviesCount = 0
    @Published private(set) var seriesCount = 0
    /// Bumped on every catalog change (a sweep page, a completed sweep, a
    /// restore, a clear). The VOD tabs rebuild their windowed list when it
    /// moves, exactly as they used to rebuild on a republished array.
    @Published private(set) var catalogRevision = 0

    @Published private(set) var movieCategories: [VODCategory] = []
    @Published private(set) var isLoadingMovies = false
    /// True for the FULL duration of a `loadMovies` call, including
    /// the per-category streaming pass that keeps running after the
    /// first partial results publish. Distinct from `isLoadingMovies`
    /// (which intentionally flips to `false` at the first batch so
    /// `MoviesView` can drop its spinner and start showing items).
    @Published private(set) var isRefillingMovies = false
    @Published private(set) var moviesError: String?

    @Published private(set) var seriesCategories: [VODCategory] = []
    @Published private(set) var isLoadingSeries = false
    /// True once a sweep has finished at least once this session. The VOD
    /// tabs show a loading state, not "No TV Shows", before the first one.
    @Published private(set) var hasLoadedMovies = false
    @Published private(set) var hasLoadedSeries = false
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
    /// "this is a fresh server we haven't looked at yet".
    @Published private(set) var currentMoviesServerID: UUID? = nil
    /// Series equivalent of `currentMoviesServerID`.
    @Published private(set) var currentSeriesServerID: UUID? = nil

    /// Server-side search results (supplements the stored catalog when the
    /// sweep has not reached a title yet).
    @Published private(set) var movieSearchResults: [VODDisplayItem] = []
    @Published private(set) var isSearchingMovies = false
    @Published private(set) var seriesSearchResults: [VODDisplayItem] = []
    @Published private(set) var isSearchingSeries = false

    private var movieSearchTask: Task<Void, Never>?
    private var seriesSearchTask: Task<Void, Never>?

    /// Catalog identities whose pre-catalog JSON snapshot has already been
    /// imported this launch, so the migration runs at most once per playlist.
    private var migratedIdentities: Set<String> = []

    // MARK: - Windowed reads

    /// Build the grid's ordered list for one kind. Runs entirely in SQL and
    /// hands back ids plus rail buckets, never rows: the caller holds about
    /// 9 bytes per title and the window cache does the rest.
    func library(kind: VODItemType, hiddenGroups: Set<String>, hiddenTitleKeys: Set<String>,
                 genre: String?, onlyHidden: Bool, sortRaw: String) async -> VODWindowList {
        guard let key = catalogKey else { return .empty }
        return await catalog.buildLibrary(VODCatalogQuery(
            playlistKey: key, kind: kind, hiddenGroups: hiddenGroups,
            hiddenTitleKeys: hiddenTitleKeys, genre: genre,
            onlyHidden: onlyHidden, sortRaw: sortRaw))
    }

    /// Per-keystroke library search, as a database query off the main actor.
    func searchCatalog(kind: VODItemType, query: String, hiddenTitleKeys: Set<String>) async -> [VODDisplayItem] {
        guard let key = catalogKey else { return [] }
        return await catalog.search(playlistKey: key, kind: kind, query: query,
                                    hiddenTitleKeys: hiddenTitleKeys)
    }

    /// Resolve specific provider ids (Continue Watching, Watchlist, deep
    /// links) with one indexed read instead of a walk of the whole library.
    func items(kind: VODItemType, ids: [String]) async -> [String: VODDisplayItem] {
        guard let key = catalogKey else { return [:] }
        return await catalog.items(playlistKey: key, kind: kind, ids: ids)
    }

    func itemsByTMDBID(kind: VODItemType, tmdbIDs: [String]) async -> [String: VODDisplayItem] {
        guard let key = catalogKey else { return [:] }
        return await catalog.itemsByTMDBID(playlistKey: key, kind: kind, tmdbIDs: tmdbIDs)
    }

    func itemsByNormalizedTitle(kind: VODItemType, titles: [String], requireNoTMDBID: Bool) async -> [String: VODDisplayItem] {
        guard let key = catalogKey else { return [:] }
        return await catalog.itemsByNormalizedTitle(playlistKey: key, kind: kind,
                                                    titles: titles, requireNoTMDBID: requireNoTMDBID)
    }

    func itemsByCleanTitle(kind: VODItemType, cleanTitle: String) async -> [VODDisplayItem] {
        guard let key = catalogKey else { return [] }
        return await catalog.itemsByCleanTitle(playlistKey: key, kind: kind, cleanTitle: cleanTitle)
    }

    func recentlyAdded(kind: VODItemType, hiddenGroups: Set<String>,
                       hiddenTitleKeys: Set<String>) async -> [VODDisplayItem] {
        guard let key = catalogKey else { return [] }
        return await catalog.recentlyAdded(playlistKey: key, kind: kind,
                                           hiddenGroups: hiddenGroups, hiddenTitleKeys: hiddenTitleKeys)
    }

    private func count(_ kind: VODItemType) -> Int { kind == .series ? seriesCount : moviesCount }

    /// Resolves a poster URL string that may be absolute or relative.
    /// Dispatcharr commonly returns relative paths like "/media/posters/xxx.jpg".
    /// `nonisolated static` so the off-main page mappers below can use it:
    /// it is pure string and URL shaping and touches no store state.
    nonisolated private static func resolveURL(_ raw: String, base: String) -> URL? {
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

    // MARK: - Off-main page mapping (guide navigation lag, 1.8.40)
    //
    // The uncapped sweep maps every page the provider offers, about 100 items
    // at a time, for as long as the walk takes: tens of minutes on a large
    // library at roughly two pages a second. That mapping used to run on the
    // main actor with the rest of the per-page bookkeeping, so each page
    // landed as a burst of main-thread work and a remote press that arrived
    // in the guide during a burst waited for it. That is the lag users
    // reported in 1.8.40.
    //
    // Nothing in the mapping needs the main actor: it is pure string, date
    // and URL shaping over Sendable value types, and the rows go straight
    // into `VODCatalogStore`, which is already off-main. What stays on the
    // main actor per page is only the lane bookkeeping, the count publish and
    // the log line, which `sweepPageMainHop` times.
    //
    // `Task.detached` rather than a `nonisolated async` function so the hop
    // off the actor is explicit and cannot depend on the language mode's
    // isolation defaults.
    nonisolated private static func mapMoviePage(
        _ items: [DispatcharrVODMovie], api: DispatcharrAPI, baseURL: String,
        sID: UUID, category: VODCategory
    ) -> [VODDisplayItem] {
        var batch: [VODDisplayItem] = []
        batch.reserveCapacity(items.count)
        for m in items {
            let streamURL = api.proxyMovieURL(
                uuid: m.uuid,
                preferredStreamID: m.streams?.first?.streamID
            )
            let cp = m.customProperties
            var movie = VODMovie(
                id: String(m.id), name: m.title,
                posterURL: m.posterURL.flatMap { resolveURL($0, base: baseURL) },
                backdropURL: cp?.backdropPath?.first(where: { !$0.isEmpty })
                    .flatMap { VODService.resolveImageURL($0, base: baseURL) },
                rating: m.rating ?? "", plot: m.plot ?? "",
                genre: m.genre ?? "", releaseDate: m.year.map(String.init) ?? "", duration: "",
                cast: cp?.cast ?? "", director: cp?.director ?? "", imdbID: "",
                categoryID: category.id,
                categoryName: category.name,
                streamURL: streamURL, containerExtension: "mp4",
                serverID: sID
            )
            movie.dispatcharrUUID = m.uuid
            movie.addedAt = m.createdAt.flatMap(VODService.parseISODate)
            batch.append(VODDisplayItem(movie: movie))
        }
        return batch
    }

    /// Series half of `mapMoviePage`. Same shape, same reasons.
    nonisolated private static func mapSeriesPage(
        _ items: [DispatcharrVODSeries], baseURL: String,
        sID: UUID, category: VODCategory
    ) -> [VODDisplayItem] {
        var batch: [VODDisplayItem] = []
        batch.reserveCapacity(items.count)
        for sItem in items {
            let cp = sItem.customProperties
            var show = VODSeries(
                id: String(sItem.id), name: sItem.name,
                posterURL: sItem.posterURL.flatMap { resolveURL($0, base: baseURL) },
                backdropURL: cp?.backdropPath?.first(where: { !$0.isEmpty })
                    .flatMap { VODService.resolveImageURL($0, base: baseURL) },
                rating: sItem.rating ?? "", plot: sItem.plot ?? "",
                genre: sItem.genre ?? "", releaseDate: sItem.year.map(String.init) ?? "",
                cast: cp?.cast ?? "", director: cp?.director ?? "",
                categoryID: category.id,
                categoryName: category.name,
                serverID: sID, seasons: [], episodeCount: 0
            )
            show.tmdbID = sItem.tmdbID ?? ""
            show.addedAt = sItem.createdAt.flatMap(VODService.parseISODate)
            batch.append(VODDisplayItem(series: show))
        }
        return batch
    }

    /// Debug-only budget check for what a single sweep page still costs the
    /// main actor. A user log can confirm the 1.8.40 fix with one grep: the
    /// line should be absent, and was routinely tens of milliseconds when the
    /// mapping ran here.
    private func noteSweepPageMainHop(_ started: CFAbsoluteTime, kind: String,
                                      category: String, page: Int) {
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        guard ms > 8 else { return }
        debugLog("[VOD-CAT] main hop \(Int(ms.rounded()))ms kind=\(kind) "
                 + "cat=\(category) page=\(page)")
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

    /// Wipe the in-memory VOD state. Called when a playlist/server is
    /// deleted so On Demand stops showing the removed server's movies and
    /// series (issue #25). The catalog rows on disk are NOT touched here: a
    /// playlist switch must keep the other playlist's catalog so switching
    /// back is instant. Deleting a playlist removes its rows through
    /// `deleteCatalog(serverID:)`.
    func clear() {
        cancelBackgroundSweep(reason: "playlist cleared")
        VODSweepActivity.shared.clearAll()
        moviesTask?.cancel(); moviesTask = nil
        seriesTask?.cancel(); seriesTask = nil
        movieSearchTask?.cancel(); movieSearchTask = nil
        seriesSearchTask?.cancel(); seriesSearchTask = nil
        catalogKey = nil
        moviesCount = 0; seriesCount = 0
        movieCategories = []; moviesError = nil
        isLoadingMovies = false; isRefillingMovies = false
        seriesCategories = []; seriesError = nil
        isLoadingSeries = false; isRefillingSeries = false
        movieSearchResults = []; isSearchingMovies = false
        seriesSearchResults = []; isSearchingSeries = false
        currentMoviesServerID = nil; currentSeriesServerID = nil
        lastMoviesServerName = nil; lastSeriesServerName = nil
        restoredMoviesAt = nil; restoredSeriesAt = nil
        restoredMoviesProbe = nil; restoredSeriesProbe = nil
        catalogRevision &+= 1
        catalog.clearRowCache()
    }

    /// Delete one server's stored catalog outright: every row, the sweep
    /// bookkeeping, the categories, the legacy snapshot and position files.
    /// Only the playlist DELETE path and Refresh Everything reach this.
    func deleteCatalog(for server: ServerConnection) async {
        let serverID = server.id
        await catalog.deleteServer(serverID: serverID)
        VODLibraryCache.clear(kinds: [.movie, .series], identity: VODLibraryCache.identity(for: server))
        VODSweepProgress.clear(identity: VODSweepProgress.identity(for: server))
        migratedIdentities.remove(VODLibraryCache.identity(for: server))
        if catalogKey == VODLibraryCache.identity(for: server) {
            moviesCount = 0; seriesCount = 0
            hasLoadedMovies = false; hasLoadedSeries = false
            restoredMoviesAt = nil; restoredSeriesAt = nil
            restoredMoviesProbe = nil; restoredSeriesProbe = nil
        }
        catalogRevision &+= 1
    }

    /// Identity of the playlist On Demand is currently showing:
    /// "uuid|baseURL|username", not the UUID alone. The URL and username are
    /// part of it because editing a server row in place to point at a
    /// DIFFERENT panel re-fires the orchestrator with the same UUID.
    private(set) var displayedServerIdentity: String? = nil

    /// Rebuild On Demand from scratch for a new playlist, the same way
    /// channels and the guide are rebuilt. The other playlist's catalog
    /// rows stay on disk; only what is on screen is dropped.
    func beginDisplaying(server: ServerConnection?) {
        let identity = server.map { "\($0.id.uuidString)|\($0.effectiveBaseURL)|\($0.username)" }
        guard displayedServerIdentity != identity else { return }
        let fromLabel = displayedServerIdentity?.prefix(8) ?? "none"
        let toLabel = identity?.prefix(8) ?? "none"
        debugLog("🎬 VODStore: playlist switch \(fromLabel) → \(toLabel); rebuilding On Demand from scratch")
        displayedServerIdentity = identity
        clear()
        VODDetailCaches.reset()
    }

    // MARK: - First-page gate (Edit Playlist > Save)

    /// One-shot "the first page of this kind is on disk, or this kind is
    /// known to be empty" gate.
    ///
    /// The Edit Playlist save screen arms it, wipes the catalog the OLD
    /// account wrote, starts the FOREGROUND sweep and waits on this, so its
    /// Movies / TV Shows rows complete as soon as there is something to show
    /// and the uncapped sweep goes on running in the background, exactly as
    /// it does after Add Playlist. Never block a save on a full sweep: a
    /// 350k-title library takes minutes.
    private var armedFirstPage: Set<VODItemType> = []
    private var firstPageWaiters: [VODItemType: [CheckedContinuation<Int, Never>]] = [:]

    func armFirstVODPage(_ kinds: [VODItemType]) {
        for kind in kinds { armedFirstPage.insert(kind) }
    }

    /// Fired from the sweep's own first-batch publish and, as a catch-all,
    /// from every `loadMovies` / `loadSeries` exit path, so a kind that
    /// short-circuits (denied, no categories, unreachable) resolves too.
    /// Idempotent: only the first call for an armed kind counts.
    fileprivate func noteFirstVODPage(_ kind: VODItemType, count: Int) {
        guard armedFirstPage.remove(kind) != nil else { return }
        let waiters = firstPageWaiters.removeValue(forKey: kind) ?? []
        for waiter in waiters { waiter.resume(returning: count) }
    }

    func awaitFirstVODPage(_ kind: VODItemType) async -> Int {
        guard armedFirstPage.contains(kind) else { return count(kind) }
        return await withCheckedContinuation { continuation in
            firstPageWaiters[kind, default: []].append(continuation)
        }
    }

    func refreshMovies(servers: [ServerConnection]) {
        moviesTask?.cancel()
        moviesTask = Task { await loadMovies(servers: servers) }
    }

    func refreshSeries(servers: [ServerConnection]) {
        seriesTask?.cancel()
        seriesTask = Task { await loadSeries(servers: servers) }
    }

    /// How old the persisted catalog may be before a LAUNCH re-sweeps it.
    /// 0 = every launch; default one day. User-initiated refreshes (pull,
    /// Retry, the server sheet) always bypass this.
    static let refreshHoursKey = "vodLibraryRefreshHours"
    static var refreshInterval: TimeInterval {
        let d = UserDefaults.standard
        let hours = d.object(forKey: refreshHoursKey) == nil ? 24 : d.integer(forKey: refreshHoursKey)
        return TimeInterval(max(0, hours)) * 3600
    }
    /// When each kind's last sweep finished, read back from the catalog's
    /// sweep state, so the cadence gate can judge age exactly as it did from
    /// the snapshot file's timestamp.
    private var restoredMoviesAt: Date?
    private var restoredSeriesAt: Date?

    /// True when the stored catalog is young enough for this launch to skip
    /// the network sweep.
    private func snapshotIsFresh(_ at: Date?, kind: String) -> Bool {
        guard let at else { return false }
        let age = Date().timeIntervalSince(at)
        let limit = Self.refreshInterval
        guard limit > 0, age < limit else { return false }
        debugLog("[VOD-CACHE] \(kind) catalog is \(Int(age / 60)) min old (< \(Int(limit / 3600)) h); skipping launch sweep")
        return true
    }

    /// Change-probe baselines the stored catalog was written under, and the
    /// probe values the running sweep should persist with its results.
    private var restoredMoviesProbe: (count: Int?, newest: String?)?
    private var restoredSeriesProbe: (count: Int?, newest: String?)?
    private var pendingMoviesProbe: (count: Int?, newest: String?)?
    private var pendingSeriesProbe: (count: Int?, newest: String?)?

    /// The quiet background sweep (Logan 2026-09-12). One at a time.
    private var backgroundSweepTask: Task<Void, Never>?

    /// Publish a kind's title count, and the catalog revision the VOD grids
    /// rebuild from.
    ///
    /// Both writes are guarded on a REAL change (the equal-value `@Published`
    /// rule): a write with the value already there still re-renders every
    /// observer, and the progressive sweep publish used to bump
    /// `catalogRevision` unconditionally every 5 s for tens of minutes. Pass
    /// `rowsChanged: false` only where the catalog's rows provably did not
    /// move; a playlist switch, a page write and a sweep's pruning all leave
    /// it `true` so the grids rebuild even when the count happens to match.
    private func publishMovieCount(_ total: Int, _ why: String, rowsChanged: Bool = true) {
        let countChanged = moviesCount != total
        guard countChanged || rowsChanged else { return }
        MainThreadWatchdog.shared.notePublish("publish vod.movies \(total) titles (\(why))")
        if countChanged { moviesCount = total }
        catalogRevision &+= 1
    }

    private func publishSeriesCount(_ total: Int, _ why: String, rowsChanged: Bool = true) {
        let countChanged = seriesCount != total
        guard countChanged || rowsChanged else { return }
        MainThreadWatchdog.shared.notePublish("publish vod.series \(total) titles (\(why))")
        if countChanged { seriesCount = total }
        catalogRevision &+= 1
    }

    // MARK: - Legacy snapshot migration

    /// First launch after the upgrade: import the pre-catalog per-server JSON
    /// snapshot into the catalog, off the main actor, so nothing is
    /// re-downloaded. The imported rows land as generation 0 with the
    /// snapshot's own completion stamp and change probe, so the cadence gate
    /// behaves as it did; the first real sweep refreshes them all.
    private func migrateLegacySnapshots(identity: String) async {
        guard !migratedIdentities.contains(identity) else { return }
        migratedIdentities.insert(identity)
        var imported = 0
        for kind in [VODItemType.movie, VODItemType.series] {
            guard let snap = await VODLibraryCache.load(kind: kind, identity: identity) else { continue }
            let n = await catalog.importLegacySnapshot(kind: kind, playlistKey: identity, snapshot: snap)
            if n > 0 {
                imported += n
                debugLog("[VOD-CAT] migrated \(n) \(kind == .movie ? "movies" : "series") "
                         + "from the legacy snapshot into the catalog")
            }
            // The snapshot has served its purpose; the catalog owns the rows
            // now and keeping a multi-hundred-MB JSON file around would
            // defeat the point of the change.
            VODLibraryCache.clear(kinds: [kind], identity: identity)
        }
        if imported > 0 {
            VODSweepProgress.clear(identity: "v1|" + identity)
        }
    }

    /// Adopt `server` as the catalog the tabs read from, importing a legacy
    /// snapshot when there is one, and publish the stored counts, categories
    /// and sweep timestamps. This is the launch restore: no network at all.
    @discardableResult
    private func adoptCatalog(for server: ServerConnection) async -> String {
        let identity = VODLibraryCache.identity(for: server)
        await migrateLegacySnapshots(identity: identity)
        if catalogKey != identity { catalogKey = identity }
        let movieState = await catalog.sweepState(playlistKey: identity, kind: .movie)
        let seriesState = await catalog.sweepState(playlistKey: identity, kind: .series)
        restoredMoviesAt = movieState?.isOpen == true ? nil : movieState?.completedAt
        restoredSeriesAt = seriesState?.isOpen == true ? nil : seriesState?.completedAt
        restoredMoviesProbe = movieState.map { ($0.remoteCount, $0.remoteNewest) }
        restoredSeriesProbe = seriesState.map { ($0.remoteCount, $0.remoteNewest) }
        return identity
    }

    /// Restore-only launch path: publish what the catalog already holds and
    /// touch nothing on the network.
    ///
    /// The VOD library follows the EPG cache rule (Logan 2026-09-12): the
    /// stored catalog IS what the tabs show at launch, and the network sweep
    /// is a quiet background pass that starts once the app has settled.
    func restoreSnapshots(servers: [ServerConnection]) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let vodServers = servers.filter { $0.supportsVOD && $0.vodEnabled }
        let activeServer = servers.first(where: { $0.isActive })
        guard let server = vodServers.first(where: { $0.isActive }) ?? (activeServer == nil ? vodServers.first : nil) else { return }
        // Dispatcharr 0.30 per-user permissions. The catalog is a disk cache
        // written while the account still had access, so restoring it blindly
        // re-published a full library for an account that is now denied --
        // invisible in the tab bar (the gates hide the tab) but visible to
        // every direct reader of `VODStore.shared`: global search, "More like
        // this", and the multiview picker. Drop the rows instead of
        // publishing them. UNKNOWN never drops anything.
        let identity = await adoptCatalog(for: server)
        let deniedMovies = server.type == .dispatcharrAPI && !server.dispatcharrCanViewVOD
        let deniedSeries = server.type == .dispatcharrAPI && !server.dispatcharrCanViewSeries
        if deniedMovies || deniedSeries {
            debugLog("[VOD-CACHE] permission denied (movies=\(!deniedMovies) series=\(!deniedSeries)); discarding the stored catalog")
            if deniedMovies { await catalog.deleteKind(playlistKey: identity, kind: .movie) }
            if deniedSeries { await catalog.deleteKind(playlistKey: identity, kind: .series) }
        }
        let storedMovies = deniedMovies ? 0 : await catalog.count(playlistKey: identity, kind: .movie)
        let storedSeries = deniedSeries ? 0 : await catalog.count(playlistKey: identity, kind: .series)
        if storedMovies > 0 {
            movieCategories = await catalog.categories(playlistKey: identity, kind: .movie)
            isLoadingMovies = false
            hasLoadedMovies = true
            lastMoviesServerName = server.name
            currentMoviesServerID = server.id
            publishMovieCount(storedMovies, "catalog restore")
        }
        if storedSeries > 0 {
            seriesCategories = await catalog.categories(playlistKey: identity, kind: .series)
            isLoadingSeries = false
            hasLoadedSeries = true
            lastSeriesServerName = server.name
            currentSeriesServerID = server.id
            publishSeriesCount(storedSeries, "catalog restore")
        }
        if storedMovies > 0 || storedSeries > 0 {
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            debugLog("[VOD-CAT] restored \(storedMovies) movies, \(storedSeries) series from the catalog (\(ms)ms)")
            TMDBArtCache.shared.enrichCatalog(playlistKey: identity, isMovie: true)
            TMDBArtCache.shared.enrichCatalog(playlistKey: identity, isMovie: false)
        }
    }

    /// Why a background sweep ran (or did not).
    private enum SweepGate: String {
        /// The cadence setting (Every Launch / Daily / Weekly) says it is due.
        case cadence
        /// Dispatcharr's cheap change probe says the library moved, so sweep
        /// early even though the cadence window has not elapsed.
        case changed
        /// Nothing to do this time.
        case skipped
    }

    /// Schedule the quiet sweep. Starts about `AppSettleGate.settleDelay`
    /// seconds after launch or a foreground return, once the guide has
    /// rendered and any tune is past first frame; pauses mid-run whenever
    /// either of those stops being true.
    func scheduleBackgroundSweep(servers: [ServerConnection], reason: String) {
        guard !servers.isEmpty else { return }
        // One sweep at a time: a foreground return while a sweep is still
        // walking pages is not a reason to start a second walk.
        if let task = backgroundSweepTask, !task.isCancelled {
            debugLog("[VOD] background sweep: already running, \(reason) ignored")
            return
        }
        backgroundSweepTask = Task(priority: .background) { [weak self] in
            await self?.runBackgroundSweep(servers: servers, reason: reason)
            self?.backgroundSweepTask = nil
        }
        // The tabs must not vanish between "a sweep is scheduled" and the
        // gate deciding which kinds it opens: mark both pending now and
        // stand the unwanted half down once the gate has spoken.
        VODSweepActivity.shared.markPending([.movie, .series])
    }

    func cancelBackgroundSweep(reason: String) {
        guard backgroundSweepTask != nil else { return }
        backgroundSweepTask?.cancel()
        backgroundSweepTask = nil
        VODSweepActivity.shared.clearAll()
        debugLog("[VOD] background sweep cancelled (\(reason))")
    }

    private func runBackgroundSweep(servers: [ServerConnection], reason: String) async {
        await AppSettleGate.shared.awaitSettled(reason: "VOD sweep (\(reason))")
        guard !Task.isCancelled else { return }
        let vodServers = servers.filter { $0.supportsVOD && $0.vodEnabled }
        let activeServer = servers.first(where: { $0.isActive })
        guard let server = vodServers.first(where: { $0.isActive }) ?? (activeServer == nil ? vodServers.first : nil) else {
            debugLog("[VOD] background sweep: gate=skipped reason=\(reason) (no VOD server)")
            VODSweepActivity.shared.clearAll()
            return
        }
        // (a) Cadence still applies for every provider type.
        let moviesDueByCadence = !(moviesCount > 0 && snapshotIsFresh(restoredMoviesAt, kind: "movies"))
        let seriesDueByCadence = !(seriesCount > 0 && snapshotIsFresh(restoredSeriesAt, kind: "series"))
        // (b) Dispatcharr only: one tiny request per kind can promote a
        // not-yet-due sweep when the library actually moved.
        var moviesChanged = false
        var seriesChanged = false
        if server.type == .dispatcharrAPI {
            let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                     auth: .apiKey(server.effectiveApiKey),
                                     userAgent: server.effectiveUserAgent,
                                     authMode: server.dispatcharrHeaderMode)
            if server.dispatcharrCanViewVOD, let probe = try? await api.probeVODMovies() {
                pendingMoviesProbe = (probe.count, probe.newestCreatedAt)
                moviesChanged = Self.probeSaysChanged(baseline: restoredMoviesProbe, probe: probe)
            }
            if server.dispatcharrCanViewSeries, let probe = try? await api.probeVODSeries() {
                pendingSeriesProbe = (probe.count, probe.newestCreatedAt)
                seriesChanged = Self.probeSaysChanged(baseline: restoredSeriesProbe, probe: probe)
            }
        }
        let sweepMovies = moviesDueByCadence || moviesChanged
        let sweepSeries = seriesDueByCadence || seriesChanged
        let gate: SweepGate = !sweepMovies && !sweepSeries
            ? .skipped
            : ((moviesChanged || seriesChanged) && !(moviesDueByCadence || seriesDueByCadence) ? .changed : .cadence)
        debugLog("[VOD] background sweep: gate=\(gate.rawValue) reason=\(reason) movies=\(sweepMovies ? (moviesChanged ? "changed" : "due") : "skip") series=\(sweepSeries ? (seriesChanged ? "changed" : "due") : "skip")")
        // Only the kinds the gate opened stay pending; the others stand down
        // now so their tab is not held in a loading state forever.
        if !sweepMovies { VODSweepActivity.shared.markIdle(.movie) }
        if !sweepSeries { VODSweepActivity.shared.markIdle(.series) }
        guard gate != .skipped else { return }
        if sweepMovies {
            guard !Task.isCancelled else { return }
            await loadMovies(servers: servers, background: true)
        }
        if sweepSeries {
            guard !Task.isCancelled else { return }
            await loadSeries(servers: servers, background: true)
        }
    }

    /// A changed count or a newer top row means sweep now. An unknown
    /// baseline (a catalog written before the probe existed) is NOT a change:
    /// the cadence setting stays in charge there.
    private static func probeSaysChanged(baseline: (count: Int?, newest: String?)?,
                                         probe: DispatcharrAPI.VODChangeProbe) -> Bool {
        guard let baseline, baseline.count != nil || baseline.newest != nil else { return false }
        if let was = baseline.count, let now = probe.count, was != now { return true }
        if let was = baseline.newest, let now = probe.newestCreatedAt, was != now { return true }
        return false
    }

    func refreshMoviesAndWait(servers: [ServerConnection], honorCache: Bool = false) async {
        moviesTask?.cancel()
        let task = Task { await loadMovies(servers: servers, honorCache: honorCache) }
        moviesTask = task
        await task.value
    }

    /// Awaitable variant of `refreshSeries` mirroring `refreshMoviesAndWait`.
    /// Used by the initial-sync orchestrator to sequence series after movies.
    func refreshSeriesAndWait(servers: [ServerConnection], honorCache: Bool = false) async {
        seriesTask?.cancel()
        let task = Task { await loadSeries(servers: servers, honorCache: honorCache) }
        seriesTask = task
        await task.value
    }

    func searchMovies(query: String, servers: [ServerConnection], providerID: Int? = nil) {
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
        let authMode = server.dispatcharrHeaderMode
        let userAgent = server.effectiveUserAgent
        isSearchingMovies = true
        movieSearchTask = Task {
            let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                     userAgent: userAgent, authMode: authMode)
            var results: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 2.0
            do {
                for try await batch in api.searchVODMoviesStream(query: query, m3uAccountID: providerID) {
                    guard !Task.isCancelled else { break }
                    let items = batch.map { m -> VODDisplayItem in
                        let cp = m.customProperties
                        var movie = VODMovie(
                            id: String(m.id), name: m.title,
                            posterURL: m.posterURL.flatMap { Self.resolveURL($0, base: baseURL) },
                            backdropURL: cp?.backdropPath?.first(where: { !$0.isEmpty })
                                .flatMap { VODService.resolveImageURL($0, base: baseURL) },
                            rating: m.rating ?? "", plot: m.plot ?? "",
                            genre: m.genre ?? "", releaseDate: m.year.map(String.init) ?? "", duration: "",
                            cast: cp?.cast ?? "", director: cp?.director ?? "", imdbID: "",
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
                        movie.dispatcharrUUID = m.uuid
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

    func searchSeries(query: String, servers: [ServerConnection], providerID: Int? = nil) {
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
        let authMode = server.dispatcharrHeaderMode
        let userAgent = server.effectiveUserAgent
        isSearchingSeries = true
        seriesSearchTask = Task {
            let api = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                     userAgent: userAgent, authMode: authMode)
            var results: [VODDisplayItem] = []
            var lastPublishTime = Date.distantPast
            let publishInterval: TimeInterval = 2.0
            do {
                for try await batch in api.searchVODSeriesStream(query: query, m3uAccountID: providerID) {
                    guard !Task.isCancelled else { break }
                    let items = batch.map { s -> VODDisplayItem in
                        let cp = s.customProperties
                        var show = VODSeries(
                            id: String(s.id), name: s.name,
                            posterURL: s.posterURL.flatMap { Self.resolveURL($0, base: baseURL) },
                            backdropURL: cp?.backdropPath?.first(where: { !$0.isEmpty })
                                .flatMap { VODService.resolveImageURL($0, base: baseURL) },
                            rating: s.rating ?? "", plot: s.plot ?? "",
                            genre: s.genre ?? "", releaseDate: s.year.map(String.init) ?? "",
                            cast: cp?.cast ?? "", director: cp?.director ?? "",
                            categoryID: "", categoryName: "Series",
                            serverID: sID, seasons: [], episodeCount: 0
                        )
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
    /// write a one-shot server-search hit into the catalog BEFORE the detail
    /// push, so the pushed screen's own lookups can resolve the item. Written
    /// under the CURRENT sweep generation so the next finished sweep does not
    /// treat it as a stale row and delete it.
    func mergeKnownForHit(_ item: VODDisplayItem) async {
        guard let key = catalogKey, item.type != .episode else { return }
        let kind: VODItemType = item.type == .series ? .series : .movie
        let generation = await catalog.sweepState(playlistKey: key, kind: kind)?.generation ?? 1
        let written = await catalog.writePage([item], playlistKey: key, kind: kind, generation: generation)
        guard written > 0 else { return }
        if kind == .series { publishSeriesCount(seriesCount + written, "known for") }
        else { publishMovieCount(moviesCount + written, "known for") }
    }

    /// Exposes the search-result row mapper for the Known For one-shot
    /// lookup so its rows are shaped identically to regular search hits
    /// (including the resolved poster URL and proxy stream URL).
    func makeSearchMovieItem(_ m: DispatcharrVODMovie, api: DispatcharrAPI, baseURL: String, serverID: UUID) -> VODDisplayItem {
        let movie = VODMovie(
            id: String(m.id), name: m.title,
            posterURL: m.posterURL.flatMap { Self.resolveURL($0, base: baseURL) },
            backdropURL: nil,
            rating: m.rating ?? "", plot: m.plot ?? "",
            genre: m.genre ?? "", releaseDate: m.year.map(String.init) ?? "", duration: "",
            cast: "", director: "", imdbID: "",
            categoryID: "", categoryName: "Movies",
            streamURL: api.proxyMovieURL(uuid: m.uuid,
                                         preferredStreamID: m.streams?.first?.streamID),
            containerExtension: "mp4", serverID: serverID
        )
        var item = movie
        item.tmdbID = m.tmdbID ?? ""
        item.dispatcharrUUID = m.uuid
        return VODDisplayItem(movie: item)
    }

    func makeSearchSeriesItem(_ s: DispatcharrVODSeries, baseURL: String, serverID: UUID) -> VODDisplayItem {
        let cp = s.customProperties
        var show = VODSeries(
            id: String(s.id), name: s.name,
            posterURL: s.posterURL.flatMap { Self.resolveURL($0, base: baseURL) },
            backdropURL: cp?.backdropPath?.first(where: { !$0.isEmpty })
                .flatMap { VODService.resolveImageURL($0, base: baseURL) },
            rating: s.rating ?? "", plot: s.plot ?? "",
            genre: s.genre ?? "", releaseDate: s.year.map(String.init) ?? "",
            cast: cp?.cast ?? "", director: cp?.director ?? "",
            categoryID: "", categoryName: "Series",
            serverID: serverID, seasons: [], episodeCount: 0
        )
        show.tmdbID = s.tmdbID ?? ""
        return VODDisplayItem(series: show)
    }

    /// `background: true` is the quiet sweep: low-priority requests, a short
    /// pause between pages, a hold whenever a tune is before first frame or
    /// the app is not in the foreground, and no spinner over restored content.
    private func loadMovies(servers: [ServerConnection], honorCache: Bool = false,
                            background: Bool = false) async {
        // Catch-all for the first-page gate: every exit path resolves it, so a
        // waiter can never hang on a kind that short-circuited.
        defer { noteFirstVODPage(.movie, count: moviesCount) }
        debugLog("🎬 VODStore.loadMovies: starting, servers=\(servers.count) honorCache=\(honorCache) background=\(background)")
        let activeServer = servers.first(where: { $0.isActive })
        // Active server exists but doesn't support VOD (e.g. M3U) — clear and bail silently.
        if let active = activeServer, !active.supportsVOD {
            debugLog("🎬 VODStore.loadMovies: active server doesn't support VOD, clearing")
            publishMovieCount(0, "no VOD support", rowsChanged: false); movieCategories = []
            isLoadingMovies = false; moviesError = nil
            lastMoviesServerName = nil; currentMoviesServerID = nil
            return
        }
        // Dispatcharr 0.30: the account's vod_movies_enabled is off. The
        // server would answer with empty lists anyway; skip the sweep.
        if let active = activeServer, active.type == .dispatcharrAPI {
            await DispatcharrCapabilityProbe.refreshIfStale(active, reason: "On Demand (movies)")
        }
        if let active = activeServer, active.type == .dispatcharrAPI, !active.dispatcharrCanViewVOD {
            debugLog("🎬 VODStore.loadMovies: movies disabled for this Dispatcharr account, clearing")
            // Drop the stored rows too, or the next launch restores the
            // catalog this account may no longer see.
            let identity = VODLibraryCache.identity(for: active)
            await catalog.deleteKind(playlistKey: identity, kind: .movie)
            VODLibraryCache.clear(kinds: [.movie], identity: identity)
            VODSweepProgress.clear(kind: .movie, identity: VODSweepProgress.identity(for: active))
            publishMovieCount(0, "movies denied"); movieCategories = []
            isLoadingMovies = false; moviesError = nil
            lastMoviesServerName = nil; currentMoviesServerID = active.id
            return
        }
        // Users with a "main + sandbox" Dispatcharr setup can disable VOD on
        // the sandbox. Active server with `vodEnabled == false` clears VOD.
        if let active = activeServer, !active.vodEnabled {
            debugLog("🎬 VODStore.loadMovies: active server has vodEnabled=false, clearing")
            publishMovieCount(0, "vodEnabled off", rowsChanged: false); movieCategories = []
            isLoadingMovies = false; moviesError = nil
            lastMoviesServerName = nil; currentMoviesServerID = nil
            return
        }
        let vodServers = servers.filter { $0.supportsVOD && $0.vodEnabled }
        // Use the active VOD server; fall back to first VOD server only when there is no
        // active server at all (never fall back to an inactive VOD server when a non-VOD
        // server is explicitly active — that would show stale data from the wrong server).
        guard let server = vodServers.first(where: { $0.isActive }) ?? (activeServer == nil ? vodServers.first : nil) else {
            // Nothing left to load from, so nothing should still be on screen.
            publishMovieCount(0, "no VOD server", rowsChanged: false); movieCategories = []
            isLoadingMovies = false
            lastMoviesServerName = nil; currentMoviesServerID = nil
            if !servers.isEmpty {
                moviesError = "None of your configured servers support VOD. Use an Xtream Codes or Dispatcharr server to browse movies."
            }
            return
        }
        lastMoviesServerName = server.name
        // Switching to a different server shows that server's own catalog,
        // not the previous one's.
        if currentMoviesServerID != nil && currentMoviesServerID != server.id {
            publishMovieCount(0, "server switch", rowsChanged: false)
            movieCategories = []
        }
        currentMoviesServerID = server.id

        // Adopt this playlist's catalog (importing a legacy snapshot the
        // first time) and publish what it already holds, so the tab is
        // populated at once; the sweep below refreshes it.
        let identity = await adoptCatalog(for: server)
        let sweepIdentity = VODSweepProgress.identity(for: server)
        let storedMovies = await catalog.count(playlistKey: identity, kind: .movie)
        let storedSeries = await catalog.count(playlistKey: identity, kind: .series)
        if storedMovies != moviesCount { publishMovieCount(storedMovies, "catalog restore") }
        if storedMovies > 0 {
            if movieCategories.isEmpty { movieCategories = await catalog.categories(playlistKey: identity, kind: .movie) }
            isLoadingMovies = false
            hasLoadedMovies = true
        }
        // The launch orchestrator runs the series sweep only after the movie
        // sweep ends (a minute or more), so publish the stored series count
        // here too; loadSeries then finds it populated.
        if storedSeries > 0, seriesCount == 0 {
            publishSeriesCount(storedSeries, "catalog restore (with movies)")
            if seriesCategories.isEmpty { seriesCategories = await catalog.categories(playlistKey: identity, kind: .series) }
            isLoadingSeries = false
            hasLoadedSeries = true
        }

        // A background sweep never raises the spinner over content that is
        // already on screen; the restored list stays visible untouched.
        isLoadingMovies = !(background && moviesCount > 0)
        // `defer` guarantees `isRefillingMovies` returns to false on every
        // exit path without sprinkling resets across each one.
        isRefillingMovies = true
        VODSweepActivity.shared.markRunning(.movie)
        defer {
            isRefillingMovies = false
            VODSweepActivity.shared.markIdle(.movie)
        }
        var lastProgressivePublish = Date.distantPast
        moviesError = nil
        DebugLogger.shared.log("VODStore loadMovies — \(server.name) (\(server.type.rawValue)) url=\(server.effectiveBaseURL)",
                               category: "Movies", level: .info)

        if honorCache, moviesCount > 0, snapshotIsFresh(restoredMoviesAt, kind: "movies") {
            isLoadingMovies = false
            return
        }

        // Dispatcharr libraries can be enormous (350 000+ items). Pages are
        // written to the catalog as they arrive, so the grid appears after
        // the first page lands and memory never tracks the library size.
        if server.type == .dispatcharrAPI {
            let baseURL = server.effectiveBaseURL
            let apiKey  = server.effectiveApiKey
            let sID     = server.id
            let authMode = server.dispatcharrHeaderMode
            let userAgent = server.effectiveUserAgent
            debugLog("🎬 VODStore.loadMovies: dispatcharr baseURL=\(DebugLogger.sanitize(baseURL)), hasKey=\(!apiKey.isEmpty)")
            let api     = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                         userAgent: userAgent, authMode: authMode)

            // Fetch categories from the dedicated endpoint and filter to the
            // ones the user has actually enabled on at least one M3U account.
            // A network failure here must NOT masquerade as an empty category
            // list: clearing the catalog would hide the On Demand tab and
            // nothing re-fires the load until vodServerKey changes.
            let apiCats: [DispatcharrVODCategory]
            do {
                apiCats = try await api.getVODCategories()
            } catch {
                debugLog("🎬 VODStore.loadMovies: categories fetch FAILED (\(error.localizedDescription)); keeping existing \(moviesCount)-item library")
                moviesError = "Could not reach the server"
                isLoadingMovies = false
                return
            }
            let enabledMovieCats = apiCats.filter {
                ($0.categoryType == "movie" || $0.categoryType == "Movie") && $0.isEnabledOnAnyAccount
            }
            debugLog("🎬 VODStore: \(apiCats.count) total categories, \(enabledMovieCats.count) enabled movie categories")

            // Show the category list in Manage Groups immediately.
            movieCategories = enabledMovieCats.map {
                VODCategory(id: String($0.id), name: $0.name,
                            providerIDs: $0.m3uAccounts.filter(\.enabled).map(\.m3uAccount))
            }
            await catalog.saveCategories(movieCategories, playlistKey: identity, kind: .movie)

            // No enabled movie categories means the library is empty by
            // construction; never fall back to a flat unfiltered fetch.
            if enabledMovieCats.isEmpty {
                await catalog.deleteKind(playlistKey: identity, kind: .movie)
                publishMovieCount(0, "no enabled categories")
                isLoadingMovies = false
                debugLog("🎬 VODStore.loadMovies: no enabled movie categories, nothing to fetch")
                return
            }

            // Per-category fetch so every movie carries its REAL Dispatcharr
            // category (the list response omits it). Sequential, not parallel,
            // to avoid saturating Dispatcharr's uwsgi pool. A movie in two
            // categories keeps the stamp of whichever page wrote it first,
            // which the catalog's "do not touch a row this generation already
            // wrote" rule enforces in SQL.
            var lastError: APIError?
            var failedCategories: [String] = []
            // GH #109 parity: NO total cap. Every page the server offers is
            // stored. Fairness comes from the round-robin walk below, which
            // takes ONE page per category per rotation. Positions are saved
            // in the catalog after every few pages, so a sweep killed by
            // process death, jetsam or a playlist switch resumes where it
            // stopped rather than restarting.
            let lanes = enabledMovieCats
            let plan = await catalog.beginSweep(playlistKey: identity, kind: .movie,
                                                lanes: lanes.map(\.name))
            var nextPage = plan.nextPage
            var finished = plan.done
            var total = moviesCount
            if plan.resumed {
                let mid = nextPage.filter { $0.value > 1 && !finished.contains($0.key) }.count
                debugLog("🎬 [VOD-CAT] resumed from saved positions kind=movies done=\(finished.count) mid-category=\(mid) stored=\(total)")
            }
            debugLog("🎬 [VOD-CAT] sweep start kind=movies server=\(server.name) lanes=\(lanes.count) mode=\(background ? "background" : "foreground") generation=\(plan.generation)")
            debugLog("🎬 [VOD-CAT] no total cap applied kind=movies (every page the server offers is stored)")

            var pagesSinceProgressSave = 0
            while finished.count < lanes.count {
                guard !Task.isCancelled else { isLoadingMovies = false; return }
                // Round-robin rotation: one page per unfinished category.
                // Admitted at most `pageConcurrency` at a time (one quiet lane
                // off screen, three while the user is watching the grid grow).
                let rotation = lanes.filter { !finished.contains($0.name) }
                var laneIndex = 0
                while laneIndex < rotation.count {
                    guard !Task.isCancelled else { isLoadingMovies = false; return }
                    let limit = max(1, VODSweepActivity.shared.pageConcurrency(for: .movie))
                    let upper = min(laneIndex + limit, rotation.count)
                    let requests: [(name: String, catID: String, page: Int)] =
                        rotation[laneIndex..<upper].map {
                            (name: $0.name, catID: String($0.id), page: nextPage[$0.name] ?? 1)
                        }
                    laneIndex = upper
                    let pages = await withTaskGroup(
                        of: (String, Result<DispatcharrAPI.VODPageResult<DispatcharrVODMovie>, Error>).self
                    ) { group in
                        for req in requests {
                            group.addTask {
                                do {
                                    let r = try await api.fetchVODMoviePage(category: req.name,
                                                                page: req.page,
                                                                background: background)
                                    return (req.name, .success(r))
                                } catch {
                                    return (req.name, .failure(error))
                                }
                            }
                        }
                        var acc: [String: Result<DispatcharrAPI.VODPageResult<DispatcharrVODMovie>, Error>] = [:]
                        for await item in group { acc[item.0] = item.1 }
                        return acc
                    }
                    // The lane bookkeeping and the 5-page checkpoint run back
                    // here on the main actor, one page at a time, exactly as
                    // they did when lanes were serial. The MAPPING does not:
                    // see `mapMoviePage` for why, and `noteSweepPageMainHop`
                    // for what is left.
                    for req in requests {
                        guard !Task.isCancelled else { isLoadingMovies = false; return }
                        guard let outcome = pages[req.name] else { continue }
                        let cat = req
                        let category = VODCategory(id: req.catID, name: req.name)
                        let page = req.page
                        var written = 0
                        // Clocks the MAIN-ACTOR portion only, so it is started
                        // after the last `await` of the page and read before
                        // the next one.
                        var mainHopStart = CFAbsoluteTimeGetCurrent()
                        do {
                            let result = try outcome.get()
                            // Off the main actor: about 100 items of string,
                            // date and URL shaping per page.
                            let batch = await Task.detached(priority: .utility) {
                                Self.mapMoviePage(result.items, api: api, baseURL: baseURL,
                                                  sID: sID, category: category)
                            }.value
                            // The page is on disk before the next one is asked
                            // for, so nothing is held in memory between pages.
                            written = await catalog.writePage(batch, playlistKey: identity,
                                                              kind: .movie, generation: plan.generation)
                            mainHopStart = CFAbsoluteTimeGetCurrent()
                            total += written
                            nextPage[cat.name] = page + 1
                            if !result.hasMore { finished.insert(cat.name) }
                            debugLog("🎬 [VOD-CAT] page kind=movies cat=\(cat.name) p=\(page) "
                                     + "+\(written) total=\(total) "
                                     + "serverCount=\(result.serverCount.map(String.init) ?? "?")")
                        } catch let err as APIError {
                            // One category failing must not abort the whole sweep,
                            // and its stored titles must survive the cleanup.
                            lastError = err
                            finished.insert(cat.name)
                            failedCategories.append(cat.name)
                            DebugLogger.shared.logError(err, context: "VODStore.loadMovies(\(server.name)) cat=\(cat.name) p=\(page)")
                            debugLog("🎬 [VOD-CAT] page kind=movies cat=\(cat.name) p=\(page) failed: \(err.localizedDescription)")
                        } catch {
                            finished.insert(cat.name)
                            failedCategories.append(cat.name)
                            DebugLogger.shared.log(
                                "VODStore.loadMovies(\(server.name)) cat=\(cat.name) error: \(error.localizedDescription)",
                                category: "Movies", level: .warning
                            )
                        }

                        // First batch overall: reveal content + hide the spinner.
                        // Then publish at most every 5 s. A publish is now one
                        // integer, not a multi-thousand element array.
                        if isLoadingMovies {
                            publishMovieCount(total, "sweep first batch")
                            // Enough on disk for the Edit Playlist save screen
                            // to complete its Movies row; the sweep keeps going.
                            noteFirstVODPage(.movie, count: total)
                            isLoadingMovies = false
                            lastProgressivePublish = Date()
                        } else if written > 0, Date().timeIntervalSince(lastProgressivePublish) >= 5 {
                            publishMovieCount(total, "sweep progressive")
                            lastProgressivePublish = Date()
                        }

                        noteSweepPageMainHop(mainHopStart, kind: "movies",
                                             category: cat.name, page: page)

                        // Checkpoint the lane positions every few pages. They are
                        // rows now, written in the same database as the titles.
                        pagesSinceProgressSave += 1
                        if pagesSinceProgressSave >= 5 {
                            pagesSinceProgressSave = 0
                            await catalog.saveLanes(playlistKey: identity, kind: .movie,
                                                    generation: plan.generation,
                                                    nextPage: nextPage, done: finished)
                        }

                        // Pacing. A sweep whose own screen is in front of the
                        // user runs unpaced: the wait is the thing being
                        // optimized and the growing count is visible. Off screen
                        // it keeps the quiet pace so it never competes with
                        // playback, and holds while a tune is before first frame
                        // or the app is backgrounded.
                        if VODSweepActivity.shared.isForeground(.movie) {
                            await AppSettleGate.shared.awaitResumeIfPaused()
                        } else if background {
                            try? await Task.sleep(for: VODSweepActivity.shared.backgroundPageDelay(for: .movie))
                            await AppSettleGate.shared.awaitResumeIfPaused()
                        } else if !MultiviewStore.shared.tiles.isEmpty {
                            // Cold-load yields to playback (2026-06-29).
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                }
            }

            // Close the sweep: rows older generations wrote and this one
            // never re-confirmed go, except the groups whose lane failed.
            let deleted = await catalog.finishSweep(playlistKey: identity, kind: .movie,
                                                    generation: plan.generation,
                                                    keepCategories: failedCategories,
                                                    remoteCount: pendingMoviesProbe?.count,
                                                    remoteNewest: pendingMoviesProbe?.newest)
            total = await catalog.count(playlistKey: identity, kind: .movie)
            // Surface an error only if the whole sweep produced nothing.
            if total == 0, let lastError {
                moviesError = lastError.errorDescription
            }
            publishMovieCount(total, "sweep complete", rowsChanged: deleted > 0)
            isLoadingMovies = false
            hasLoadedMovies = true
            debugLog("🎬 [VOD-CAT] sweep complete kind=movies total=\(total) categories=\(lanes.count) "
                     + "pruned=\(max(0, deleted)) (movies=\(total) series=\(seriesCount))")
            debugLog("🎬 VODStore.loadMovies: done, \(total) movies across \(enabledMovieCats.count) categories")
            VODSweepProgress.clear(kind: .movie, identity: sweepIdentity)
            restoredMoviesProbe = pendingMoviesProbe ?? restoredMoviesProbe
            restoredMoviesAt = Date()
            // TMDB art pass from the store, not the tab: tvOS builds a tab's
            // content on first selection, so a view-driven trigger only ran
            // once the user visited the tab.
            TMDBArtCache.shared.enrichCatalog(playlistKey: identity, isMovie: true)
            return
        }

        // Non-Dispatcharr servers (Xtream Codes): single request.
        do {
            let snap = server.snapshot
            let (raw, cats) = try await VODService.fetchMovies(from: snap)
            guard !Task.isCancelled else { isLoadingMovies = false; return }
            let items = raw.map { VODDisplayItem(movie: $0) }
            let plan = await catalog.beginSweep(playlistKey: identity, kind: .movie, lanes: [""])
            for chunk in stride(from: 0, to: items.count, by: 500) {
                let slice = Array(items[chunk..<min(chunk + 500, items.count)])
                _ = await catalog.writePage(slice, playlistKey: identity, kind: .movie, generation: plan.generation)
            }
            await catalog.finishSweep(playlistKey: identity, kind: .movie, generation: plan.generation)
            let apiCats = cats.filter { $0.itemCount > 0 }
            // Prefer API-provided categories; fall back to building from movie data
            movieCategories = apiCats.isEmpty
                ? Self.buildCategories(from: items, using: \.movie?.categoryName)
                : apiCats
            await catalog.saveCategories(movieCategories, playlistKey: identity, kind: .movie)
            publishMovieCount(await catalog.count(playlistKey: identity, kind: .movie), "xtream sweep")
            restoredMoviesAt = Date()
            TMDBArtCache.shared.enrichCatalog(playlistKey: identity, isMovie: true)
        } catch let err as APIError {
            guard !Task.isCancelled else { isLoadingMovies = false; return }
            moviesError = err.errorDescription
            DebugLogger.shared.logError(err, context: "VODStore.loadMovies(\(server.name))")
        } catch {
            guard !Task.isCancelled else { isLoadingMovies = false; return }
            moviesError = error.localizedDescription
        }
        isLoadingMovies = false
        hasLoadedMovies = true
    }

    /// See `loadMovies` for what `background` changes.
    private func loadSeries(servers: [ServerConnection], honorCache: Bool = false,
                            background: Bool = false) async {
        // See `loadMovies`: catch-all so the first-page gate always resolves.
        defer { noteFirstVODPage(.series, count: seriesCount) }
        debugLog("📺 VODStore.loadSeries: starting, servers=\(servers.count) honorCache=\(honorCache) background=\(background)")
        let activeServer = servers.first(where: { $0.isActive })
        if let active = activeServer, !active.supportsVOD {
            publishSeriesCount(0, "no VOD support", rowsChanged: false); seriesCategories = []
            isLoadingSeries = false; seriesError = nil
            lastSeriesServerName = nil; currentSeriesServerID = nil
            return
        }
        // Dispatcharr 0.30: the account's vod_series_enabled is off.
        if let active = activeServer, active.type == .dispatcharrAPI {
            await DispatcharrCapabilityProbe.refreshIfStale(active, reason: "On Demand (series)")
        }
        if let active = activeServer, active.type == .dispatcharrAPI, !active.dispatcharrCanViewSeries {
            debugLog("📺 VODStore.loadSeries: series disabled for this Dispatcharr account, clearing")
            let identity = VODLibraryCache.identity(for: active)
            await catalog.deleteKind(playlistKey: identity, kind: .series)
            VODLibraryCache.clear(kinds: [.series], identity: identity)
            VODSweepProgress.clear(kind: .series, identity: VODSweepProgress.identity(for: active))
            publishSeriesCount(0, "series denied"); seriesCategories = []
            isLoadingSeries = false; seriesError = nil
            lastSeriesServerName = nil; currentSeriesServerID = active.id
            return
        }
        if let active = activeServer, !active.vodEnabled {
            debugLog("📺 VODStore.loadSeries: active server has vodEnabled=false, clearing")
            publishSeriesCount(0, "vodEnabled off", rowsChanged: false); seriesCategories = []
            isLoadingSeries = false; seriesError = nil
            lastSeriesServerName = nil; currentSeriesServerID = nil
            return
        }
        let vodServers = servers.filter { $0.supportsVOD && $0.vodEnabled }
        guard let server = vodServers.first(where: { $0.isActive }) ?? (activeServer == nil ? vodServers.first : nil) else {
            publishSeriesCount(0, "no VOD server", rowsChanged: false); seriesCategories = []
            isLoadingSeries = false
            lastSeriesServerName = nil; currentSeriesServerID = nil
            if !servers.isEmpty {
                seriesError = "None of your configured servers support VOD. Use an Xtream Codes or Dispatcharr server to browse series."
            }
            return
        }
        lastSeriesServerName = server.name
        if currentSeriesServerID != nil && currentSeriesServerID != server.id {
            publishSeriesCount(0, "server switch", rowsChanged: false)
            seriesCategories = []
        }
        currentSeriesServerID = server.id

        let identity = await adoptCatalog(for: server)
        let sweepIdentity = VODSweepProgress.identity(for: server)
        let storedSeries = await catalog.count(playlistKey: identity, kind: .series)
        if storedSeries != seriesCount { publishSeriesCount(storedSeries, "catalog restore") }
        if storedSeries > 0 {
            if seriesCategories.isEmpty { seriesCategories = await catalog.categories(playlistKey: identity, kind: .series) }
            isLoadingSeries = false
            hasLoadedSeries = true
        }

        isLoadingSeries = !(background && seriesCount > 0)
        isRefillingSeries = true
        VODSweepActivity.shared.markRunning(.series)
        defer {
            isRefillingSeries = false
            VODSweepActivity.shared.markIdle(.series)
        }
        var lastSeriesProgressivePublish = Date()
        seriesError = nil
        DebugLogger.shared.log("VODStore loadSeries — \(server.name) (\(server.type.rawValue)) url=\(server.effectiveBaseURL)",
                               category: "TVShows", level: .info)

        if honorCache, seriesCount > 0, snapshotIsFresh(restoredSeriesAt, kind: "series") {
            isLoadingSeries = false
            return
        }

        if server.type == .dispatcharrAPI {
            let baseURL = server.effectiveBaseURL
            let apiKey  = server.effectiveApiKey
            let sID     = server.id
            let authMode = server.dispatcharrHeaderMode
            let userAgent = server.effectiveUserAgent
            let api     = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                         userAgent: userAgent, authMode: authMode)

            // Mirrors `loadMovies` above. Same outage guard: a failed fetch
            // keeps the stored library instead of hiding the On Demand tab.
            let apiCats: [DispatcharrVODCategory]
            do {
                apiCats = try await api.getVODCategories()
            } catch {
                debugLog("📺 VODStore.loadSeries: categories fetch FAILED (\(error.localizedDescription)); keeping existing \(seriesCount)-item library")
                seriesError = "Could not reach the server"
                isLoadingSeries = false
                return
            }
            let enabledSeriesCats = apiCats.filter {
                ($0.categoryType == "series" || $0.categoryType == "Series") && $0.isEnabledOnAnyAccount
            }
            debugLog("📺 VODStore: \(apiCats.count) total categories, \(enabledSeriesCats.count) enabled series categories")

            seriesCategories = enabledSeriesCats.map {
                VODCategory(id: String($0.id), name: $0.name,
                            providerIDs: $0.m3uAccounts.filter(\.enabled).map(\.m3uAccount))
            }
            await catalog.saveCategories(seriesCategories, playlistKey: identity, kind: .series)

            if enabledSeriesCats.isEmpty {
                await catalog.deleteKind(playlistKey: identity, kind: .series)
                publishSeriesCount(0, "no enabled categories")
                isLoadingSeries = false
                debugLog("📺 VODStore.loadSeries: no enabled series categories, nothing to fetch")
                return
            }

            var lastError: APIError?
            var failedCategories: [String] = []
            let lanes = enabledSeriesCats
            let plan = await catalog.beginSweep(playlistKey: identity, kind: .series,
                                                lanes: lanes.map(\.name))
            var nextPage = plan.nextPage
            var finished = plan.done
            var total = seriesCount
            if plan.resumed {
                let mid = nextPage.filter { $0.value > 1 && !finished.contains($0.key) }.count
                debugLog("📺 [VOD-CAT] resumed from saved positions kind=series done=\(finished.count) mid-category=\(mid) stored=\(total)")
            }
            debugLog("📺 [VOD-CAT] sweep start kind=series server=\(server.name) lanes=\(lanes.count) mode=\(background ? "background" : "foreground") generation=\(plan.generation)")
            debugLog("📺 [VOD-CAT] no total cap applied kind=series (every page the server offers is stored)")

            var pagesSinceProgressSave = 0
            while finished.count < lanes.count {
                guard !Task.isCancelled else { isLoadingSeries = false; return }
                // Round-robin rotation: one page per unfinished category.
                // Admitted at most `pageConcurrency` at a time (one quiet lane
                // off screen, three while the user is watching the grid grow).
                let rotation = lanes.filter { !finished.contains($0.name) }
                var laneIndex = 0
                while laneIndex < rotation.count {
                    guard !Task.isCancelled else { isLoadingSeries = false; return }
                    let limit = max(1, VODSweepActivity.shared.pageConcurrency(for: .series))
                    let upper = min(laneIndex + limit, rotation.count)
                    let requests: [(name: String, catID: String, page: Int)] =
                        rotation[laneIndex..<upper].map {
                            (name: $0.name, catID: String($0.id), page: nextPage[$0.name] ?? 1)
                        }
                    laneIndex = upper
                    let pages = await withTaskGroup(
                        of: (String, Result<DispatcharrAPI.VODPageResult<DispatcharrVODSeries>, Error>).self
                    ) { group in
                        for req in requests {
                            group.addTask {
                                do {
                                    let r = try await api.fetchVODSeriesPage(category: req.name,
                                                                page: req.page,
                                                                background: background)
                                    return (req.name, .success(r))
                                } catch {
                                    return (req.name, .failure(error))
                                }
                            }
                        }
                        var acc: [String: Result<DispatcharrAPI.VODPageResult<DispatcharrVODSeries>, Error>] = [:]
                        for await item in group { acc[item.0] = item.1 }
                        return acc
                    }
                    // See the movies sweep: the lane bookkeeping stays on the
                    // main actor, the per-page MAPPING does not.
                    for req in requests {
                        guard !Task.isCancelled else { isLoadingSeries = false; return }
                        guard let outcome = pages[req.name] else { continue }
                        let cat = req
                        let category = VODCategory(id: req.catID, name: req.name)
                        let page = req.page
                        var written = 0
                        var mainHopStart = CFAbsoluteTimeGetCurrent()
                        do {
                            let result = try outcome.get()
                            let batch = await Task.detached(priority: .utility) {
                                Self.mapSeriesPage(result.items, baseURL: baseURL,
                                                   sID: sID, category: category)
                            }.value
                            written = await catalog.writePage(batch, playlistKey: identity,
                                                              kind: .series, generation: plan.generation)
                            mainHopStart = CFAbsoluteTimeGetCurrent()
                            total += written
                            nextPage[cat.name] = page + 1
                            if !result.hasMore { finished.insert(cat.name) }
                            debugLog("📺 [VOD-CAT] page kind=series cat=\(cat.name) p=\(page) "
                                     + "+\(written) total=\(total) "
                                     + "serverCount=\(result.serverCount.map(String.init) ?? "?")")
                        } catch let err as APIError {
                            lastError = err
                            finished.insert(cat.name)
                            failedCategories.append(cat.name)
                            DebugLogger.shared.logError(err, context: "VODStore.loadSeries(\(server.name)) cat=\(cat.name) p=\(page)")
                            debugLog("📺 [VOD-CAT] page kind=series cat=\(cat.name) p=\(page) failed: \(err.localizedDescription)")
                        } catch {
                            finished.insert(cat.name)
                            failedCategories.append(cat.name)
                            DebugLogger.shared.log(
                                "VODStore.loadSeries(\(server.name)) cat=\(cat.name) error: \(error.localizedDescription)",
                                category: "TVShows", level: .warning
                            )
                        }

                        if isLoadingSeries {
                            publishSeriesCount(total, "sweep first batch")
                            // See the movies sweep: unblocks the save screen's
                            // TV Shows row without waiting for the full sweep.
                            noteFirstVODPage(.series, count: total)
                            isLoadingSeries = false
                            lastSeriesProgressivePublish = Date()
                        } else if written > 0,
                                  Date().timeIntervalSince(lastSeriesProgressivePublish) >= 5 {
                            publishSeriesCount(total, "sweep progressive")
                            lastSeriesProgressivePublish = Date()
                        }

                        noteSweepPageMainHop(mainHopStart, kind: "series",
                                             category: cat.name, page: page)

                        pagesSinceProgressSave += 1
                        if pagesSinceProgressSave >= 5 {
                            pagesSinceProgressSave = 0
                            await catalog.saveLanes(playlistKey: identity, kind: .series,
                                                    generation: plan.generation,
                                                    nextPage: nextPage, done: finished)
                        }

                        // See loadMovies: unpaced while the TV Shows screen is
                        // in front of the user, quiet pace otherwise.
                        if VODSweepActivity.shared.isForeground(.series) {
                            await AppSettleGate.shared.awaitResumeIfPaused()
                        } else if background {
                            try? await Task.sleep(for: VODSweepActivity.shared.backgroundPageDelay(for: .series))
                            await AppSettleGate.shared.awaitResumeIfPaused()
                        } else if !MultiviewStore.shared.tiles.isEmpty {
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                }
            }

            let deleted = await catalog.finishSweep(playlistKey: identity, kind: .series,
                                                    generation: plan.generation,
                                                    keepCategories: failedCategories,
                                                    remoteCount: pendingSeriesProbe?.count,
                                                    remoteNewest: pendingSeriesProbe?.newest)
            total = await catalog.count(playlistKey: identity, kind: .series)
            if total == 0, let lastError {
                seriesError = lastError.errorDescription
            }
            publishSeriesCount(total, "sweep complete", rowsChanged: deleted > 0)
            isLoadingSeries = false
            hasLoadedSeries = true
            debugLog("📺 [VOD-CAT] sweep complete kind=series total=\(total) categories=\(lanes.count) "
                     + "pruned=\(max(0, deleted)) (movies=\(moviesCount) series=\(total))")
            debugLog("📺 VODStore.loadSeries: done, \(total) series across \(enabledSeriesCats.count) enabled categories")
            VODSweepProgress.clear(kind: .series, identity: sweepIdentity)
            restoredSeriesProbe = pendingSeriesProbe ?? restoredSeriesProbe
            restoredSeriesAt = Date()
            TMDBArtCache.shared.enrichCatalog(playlistKey: identity, isMovie: false)
            return
        }

        do {
            let snap = server.snapshot
            let (rawSeries, cats) = try await VODService.fetchSeries(from: snap)
            guard !Task.isCancelled else { isLoadingSeries = false; return }
            let items = rawSeries.map { VODDisplayItem(series: $0) }
            let plan = await catalog.beginSweep(playlistKey: identity, kind: .series, lanes: [""])
            for chunk in stride(from: 0, to: items.count, by: 500) {
                let slice = Array(items[chunk..<min(chunk + 500, items.count)])
                _ = await catalog.writePage(slice, playlistKey: identity, kind: .series, generation: plan.generation)
            }
            await catalog.finishSweep(playlistKey: identity, kind: .series, generation: plan.generation)
            let apiCats = cats.filter { $0.itemCount > 0 }
            seriesCategories = apiCats.isEmpty
                ? Self.buildCategories(from: items, using: \.series?.categoryName)
                : apiCats
            await catalog.saveCategories(seriesCategories, playlistKey: identity, kind: .series)
            publishSeriesCount(await catalog.count(playlistKey: identity, kind: .series), "xtream sweep")
            restoredSeriesAt = Date()
            TMDBArtCache.shared.enrichCatalog(playlistKey: identity, isMovie: false)
        } catch let err as APIError {
            guard !Task.isCancelled else { isLoadingSeries = false; return }
            seriesError = err.errorDescription
            DebugLogger.shared.logError(err, context: "VODStore.loadSeries(\(server.name))")
        } catch {
            guard !Task.isCancelled else { isLoadingSeries = false; return }
            seriesError = error.localizedDescription
        }
        isLoadingSeries = false
        hasLoadedSeries = true
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

    /// Builds the Dispatcharr live-stream URL(s) for a channel UUID.
    /// Single source of truth for the proxy/ts/stream format so the
    /// LAN/WAN failover path (`PlayerSession.failoverRetryCurrent`) can
    /// re-derive the exact same URL against a freshly-flipped
    /// `effectiveBaseURL`. The nested `streamURLs` closure in
    /// `fetchDispatcharr` delegates here so behaviour stays byte-identical.
    ///
    /// `base` is normalised to drop a trailing slash before composing,
    /// matching `fetchDispatcharr`'s pre-stripped `base` local. `nil` /
    /// empty `uuid` yields an empty array (non-Dispatcharr or unconfigured
    /// channels have no server-side UUID).
    static func dispatcharrStreamURLs(base: String, uuid: String?) -> [URL] {
        guard let uuid, !uuid.isEmpty else { return [] }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        // TS stream — the only working Dispatcharr proxy endpoint.
        // /proxy/ts/channel/ doesn't exist. HLS returns 404 on this instance.
        //
        // v1.7.x: pin `?output_format=mpegts`. Dispatcharr v0.25.0
        // added fragmented-MP4 live output, selectable per-request
        // and overridable by a per-user / server-wide default. Our
        // live path is libmpv expecting MPEG-TS, so we request the
        // TS container explicitly rather than inherit a server
        // default that an admin may have flipped to fmp4. Unknown
        // query params are ignored by older servers, so this is a
        // safe, version-agnostic pin (it matches what Dispatcharr's
        // own preview player sends).
        return [
            "\(trimmedBase)/proxy/ts/stream/\(uuid)?output_format=mpegts"
        ].compactMap { URL(string: $0) }
    }

    // MARK: - Published State
    @Published private(set) var channels: [ChannelDisplayItem] = []
    @Published private(set) var orderedGroups: [String] = []
    @Published private(set) var isLoading = false
    @Published var isEPGLoading = false
    @Published private(set) var error: String?

    // The server that produced the current channel list (for upstream EPG closures).
    private(set) var activeServer: ServerConnection? {
        didSet {
            // Connection-limit notices are Direct Connect only.
            DispatcharrConnectionLimit.directConnectActive = activeServer?.type == .dispatcharrAPI
        }
    }
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
            DispatcharrConnectionLimit.directConnectActive = false
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
        // Recently Watched is per playlist (Logan 2026-09-14).
        RecentChannelsStore.shared.setScope(playlistID: server.id.uuidString)
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

    /// Channels only, awaitable. Used by the Edit Playlist save screen so its
    /// "Loading channels" row completes on the real channel fetch instead of a
    /// timer. Deliberately does NOT pull the guide: the credential change
    /// bumped `credentialGeneration`, and the launch orchestrator owns the EPG
    /// pass that follows. Unlike `refresh`, there is no idempotent early-out,
    /// the list on screen belongs to the previous account and must be replaced.
    func reloadChannelsAndWait(servers: [ServerConnection]) async {
        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else { return }
        activeServer = server
        currentChannelServerID = server.id
        RecentChannelsStore.shared.setScope(playlistID: server.id.uuidString)
        channels = []; orderedGroups = []; error = nil
        isLoading = true
        loadTask?.cancel()
        epgEnrichTask?.cancel()
        let task = Task { await load(server: server) }
        loadTask = task
        await task.value
    }

    /// Called by pull-to-refresh — always re-fetches channels AND EPG.
    /// This is async so the pull-to-refresh spinner stays visible until done.
    /// Pass `modelContext` to persist the rebuilt guide back to SwiftData.
    func forceRefresh(servers: [ServerConnection], modelContext: ModelContext? = nil) async {
        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else { return }
        // The user asked for fresh data, so the bulk guide must actually be
        // re-downloaded even if a pass completed moments ago — and a server
        // that got refusal-latched by an earlier 403 must get a real retry,
        // not a silent no-op (Cloudflare rate-limits lift; bans expire).
        GuideStore.shared.invalidateBulkGuideReuse()
        GuideStore.shared.resetEPGRefusalLatches(forServerKey: server.id.uuidString)
        // Incremental guide loading: the chunk coverage record would otherwise
        // make this walk skip every day it already holds. The user asked for
        // fresh data (Edit Playlist > Refresh, Refresh EPG Data, Refresh
        // Everything, pull to refresh), so force a full reload of the range.
        GuideStore.shared.invalidateGridCoverage()
        activeServer = server
        currentChannelServerID = server.id
        RecentChannelsStore.shared.setScope(playlistID: server.id.uuidString)
        loadTask?.cancel()
        epgEnrichTask?.cancel()
        await load(server: server)

        guard !Task.isCancelled, !channels.isEmpty else { return }

        isEPGLoading = true
        let didRefreshGuide = await GuideStore.shared.fetchUpcoming(
            channels: channels,
            servers: servers,
            replaceExisting: true
        )
        isEPGLoading = false

        await GuideStore.shared.seedEPGCache(channels: channels, server: server)
        if didRefreshGuide, let modelContext {
            GuideStore.shared.saveToCache(modelContext: modelContext, serverID: server.id.uuidString)
        }
    }

    /// UserDefaults key prefix for the cached channel→category map.
    /// Scoped per server so switching playlists can't briefly reuse
    /// tint data learned from a different server that happens to
    /// share the same channel ids.
    nonisolated private static let cachedCategoriesKeyPrefix = "cachedChannelCategories.v1"

    /// Snapshot of the last-known channel→category map. Written by
    /// `applyXMLTVCategories` after a fresh pass lands, read by
    /// `primeCategoriesFromCache(serverID:)` on the next cold load so
    /// the tint renders on the first frame instead of 5–10 s later.
    // nonisolated so the persist can run inside a Task.detached off the main
    // actor (UserDefaults is thread-safe). See applyXMLTVCategories.
    nonisolated private static func cachedCategoriesKey(for serverID: String) -> String {
        "\(cachedCategoriesKeyPrefix).\(serverID)"
    }

    nonisolated private static func loadCachedCategories(for serverID: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: cachedCategoriesKey(for: serverID)) as? [String: String] ?? [:]
    }

    nonisolated private static func saveCachedCategories(_ map: [String: String], for serverID: String) {
        UserDefaults.standard.set(map, forKey: cachedCategoriesKey(for: serverID))
    }

    /// Apply whatever category data we have cached from the last
    /// XMLTV pass so the tint stripe renders immediately on cold
    /// launch. The fresh XMLTV pass still runs in `loadAllEPG` and
    /// overwrites with current data — this just means the user
    /// doesn't stare at an uncolored card while the XMLTV parse
    /// churns. Call from the channel-load success path.
    func primeCategoriesFromCache(serverID: String) {
        let cached = Self.loadCachedCategories(for: serverID)
        guard !cached.isEmpty else { return }
        applyXMLTVCategories(cached, serverID: serverID)
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
    /// v1.7: snapshot of a single currently-airing program. Used by
    /// `applyCurrentPrograms` to enrich `ChannelDisplayItem` rows with
    /// "now playing" data so the Live-TV List view shows the program
    /// title under each channel without waiting on the per-cell
    /// prefetch fan-out.
    struct CurrentProgramSnapshot: Sendable {
        let title: String
        let description: String
        let start: Date
        let end: Date
    }

    /// v1.7: apply now-airing program data to channels. Mirrors
    /// `applyXMLTVCategories` in shape (keyed by `ChannelDisplayItem.id`,
    /// silent no-op when nothing changed) but writes the title /
    /// description / start / end fields the List view's `liveProgram`
    /// reads first. Called from `HomeView.loadAllEPG` after the bulk
    /// `/api/epg/grid/` response is parsed, with one entry per channel
    /// whose currently-airing program could be resolved (by tvg_id,
    /// epg_data_id bridge, OR Dummy EPG UUID match). Same three
    /// keys the Guide view uses.
    ///
    /// Non-Dispatcharr server types (M3U, Xtream Codes) keep their
    /// existing per-source enrichment paths. This method is additive.
    func applyCurrentPrograms(_ map: [String: CurrentProgramSnapshot]) {
        guard !map.isEmpty else { return }
        var changed = false
        var updated = channels
        for i in updated.indices {
            guard let snap = map[updated[i].id] else { continue }
            // Skip the @Published fire when nothing changed (warm
            // relaunch where every channel still has yesterday's
            // current program lined up identically). Dictionary
            // equality on Date is exact; the EPG grid emits
            // wall-clock-second precision so this is reliable.
            // v1.7.x (Round 1 review): description is also part of
            // the comparison. Pre-fix the skip-no-fire branch
            // ignored description, so a description-only change
            // (rare but possible: enrichment fan-out lands a richer
            // program detail after the initial bulk parse with
            // empty description) silently dropped. Now any field
            // change triggers the rewrite.
            let snapDescription = snap.description.isEmpty ? nil : snap.description
            if updated[i].currentProgram            == snap.title &&
               updated[i].currentProgramDescription == snapDescription &&
               updated[i].currentProgramStart       == snap.start &&
               updated[i].currentProgramEnd         == snap.end {
                continue
            }
            updated[i].currentProgram            = snap.title
            updated[i].currentProgramDescription = snapDescription
            updated[i].currentProgramStart       = snap.start
            updated[i].currentProgramEnd         = snap.end
            changed = true
        }
        if changed {
            channels = updated
        }
    }

    func applyXMLTVCategories(_ categoriesByChannelID: [String: String], serverID: String) {
        guard !categoriesByChannelID.isEmpty else {
            debugLog("📺 applyXMLTVCategories: SKIP — empty categories dict (serverID=\(serverID.prefix(8)))")
            return
        }
        let shouldApplyToCurrentChannels =
            currentChannelServerID?.uuidString == serverID || activeServer?.id.uuidString == serverID
        debugLog("📺 applyXMLTVCategories: serverID=\(serverID.prefix(8)) currentSrv=\(currentChannelServerID?.uuidString.prefix(8) ?? "nil") activeSrv=\(activeServer?.id.uuidString.prefix(8) ?? "nil") shouldApply=\(shouldApplyToCurrentChannels) catCount=\(categoriesByChannelID.count)")

        if shouldApplyToCurrentChannels {
            var changed = false
            var matched = 0
            var updated = channels
            for i in updated.indices {
                if let cat = categoriesByChannelID[updated[i].id] {
                    matched += 1
                    if updated[i].currentProgramCategory != cat {
                        updated[i].currentProgramCategory = cat
                        changed = true
                    }
                }
            }
            debugLog("📺 applyXMLTVCategories: matched \(matched)/\(categoriesByChannelID.count) by ch.id, changed=\(changed) (channels.count=\(channels.count))")
            if changed {
                channels = updated
            }
        }
        // Persist so the next app launch can prime the tint from cache on the
        // first frame. Merging into the existing cache rather than replacing
        // means a partial XMLTV pass doesn't wipe previously-known categories
        // for channels it didn't cover.
        // v1.7.x: done OFF the main actor. The synchronous plist
        // read+serialize+write of the merged map was firing on the main thread
        // on every category pass during the cold-start storm (2x at launch).
        // UserDefaults is thread-safe and the cache is only read on the NEXT
        // launch, so eventual consistency is fine.
        let snapshot = categoriesByChannelID
        Task.detached(priority: .utility) {
            var merged = Self.loadCachedCategories(for: serverID)
            for (id, cat) in snapshot { merged[id] = cat }
            Self.saveCachedCategories(merged, for: serverID)
        }
    }

    /// Returns the URL AerioTV should pull XMLTV from for a
    /// Dispatcharr server when the user has set an EXPLICIT
    /// override. v1.6.22 retired the auto-derived
    /// `{base}/output/epg?tvg_id_source=tvg_id` fallback because
    /// Dispatcharr 0.23.0 (commit 3c55649, 2026-02-01) made
    /// `/output/epg` LAN-only by default and most public-facing
    /// deployments now block it for security. The default EPG
    /// path is REST-only via `/api/epg/grid/` + `/api/epg/epgdata/`.
    /// This override is honored only when the user types a URL
    /// in Settings, so power users with a reachable XMLTV source
    /// (their own Dispatcharr LAN URL, a third-party EPG
    /// aggregator, etc.) can still get category-tinted guide
    /// rows. Returns nil when the override is blank or
    /// unparseable.
    static func dispatcharrXMLTVURL(override: String) -> URL? {
        let explicit = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !explicit.isEmpty, let url = URL(string: explicit) else { return nil }
        return url
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
    @discardableResult
    func primeXMLTVFromURL(_ url: URL, headers: [String: String] = [:]) async -> Bool {
        let now = Date()
        let windowStart = now.addingTimeInterval(-3600)
        // Guide Days (Logan 2026-09-11): the playlist's Guide Days setting
        // bounds this prime as well; the Settings > Network "Guide Window"
        // preference is gone.
        let effectiveWindowHours = GuideStore.activeForwardDays() * 24
        let windowEnd = now.addingTimeInterval(Double(effectiveWindowHours) * 3600)

        // Snapshot channels + server on the main actor before
        // handing off — GuideStore's XMLTV method is @MainActor
        // too and will re-dispatch, but snapshotting here keeps
        // the call site sync-clean.
        let snapshot = channels
        guard let activeServer = activeServer else { return false }
        let categoryServerID = activeServer.id.uuidString

        let xmltvDidLand = await GuideStore.shared.fetchXMLTVFromURL(
            url: url,
            channels: snapshot,
            windowStart: windowStart,
            windowEnd: windowEnd,
            headers: headers,
            categoryServerID: categoryServerID
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
        return xmltvDidLand
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
        // v1.6.20: capture the auto-detected Dispatcharr auth header
        // mode + UA so the off-main-thread DispatcharrAPI clients use
        // the per-server shape that Test Connection discovered.
        let authMode = server.dispatcharrHeaderMode
        let userAgent = server.effectiveUserAgent
        // v1.7.x: the connected Dispatcharr user's assigned Channel
        // Profile ids (empty = no profile = show all channels). When
        // non-empty, fetchDispatcharr filters the channel list to the
        // union of those profiles' memberships - a child-safety filter.
        let channelProfileIDs = server.dispatcharrProfileIDList
        debugLog("🔷 ChannelStore.load: snapshot done (type=\(type), baseURL=\(DebugLogger.sanitize(baseURL)), hasPw=\(!password.isEmpty), hasKey=\(!apiKey.isEmpty))")

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
                    epgURL: epgURL,
                    authMode: authMode, userAgent: userAgent,
                    dispatcharrChannelProfileIDs: channelProfileIDs
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
                primeCategoriesFromCache(serverID: serverID.uuidString)
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
        let xtreamXMLTVOverride = server.xtreamXMLTVURL
        let categoryServerID = server.id.uuidString
        // v1.6.20: snapshot the auto-detected auth header mode + UA
        // so the off-main-thread API constructor uses the per-server
        // shape instead of the default `.xapikey`.
        let authMode = server.dispatcharrHeaderMode
        let userAgent = server.effectiveUserAgent

        isEPGLoading = true
        defer { isEPGLoading = false }

        switch type {
        case .dispatcharrAPI:
            // v1.6.21: track whether the bulk EPG fetch succeeded.
            // When it fails (slow / parse error / network failure)
            // we skip the follow-up `primeXMLTVFromURL` pass below.
            // The XMLTV endpoint lives on the same Dispatcharr
            // container as the bulk grid; if the grid couldn't
            // respond after 30+ seconds, hammering the same server
            // for another 24+ MB of XMLTV right after is the
            // classic pile-on that wedges fragile deployments.
            // EPGGuideView still triggers its own XMLTV fetch
            // lazily when the user opens the Guide tab, so the
            // category data is just deferred, not abandoned.
            var bulkEPGSucceeded = false
            // Dispatcharr: one bulk call via /api/epg/grid/ — all channels, -1h to +24h
            do {
                let dAPI = DispatcharrAPI(baseURL: baseURL,
                                          auth: .apiKey(apiKey),
                                          userAgent: userAgent,
                                          authMode: authMode)
                let programs = try await dAPI.getEPGGrid()
                bulkEPGSucceeded = true

                // v1.6.22: fetch the EPGData lookup so we can bridge
                // `Channel.epg_data_id → EPGData.tvg_id` when
                // `Channel.tvg_id` doesn't agree with how the bulk
                // grid keys programs. On a real Dispatcharr instance
                // about 25% of channels with EPG have mismatched
                // ids; without the bridge those channels show up
                // blank in the Live TV guide. Failure is non-fatal:
                // an empty map degrades gracefully to today's behavior.
                var epgDataMap: [Int: String] = [:]
                do {
                    epgDataMap = try await dAPI.getAllEPGData()
                    debugLog("📺 Bulk EPG: fetched epg_data_id → tvg_id map (\(epgDataMap.count) rows)")
                } catch {
                    debugLog("📺 Bulk EPG: epg_data_id map fetch failed (\(error.localizedDescription)); channels with mismatched tvg_id won't be bridged")
                }

                // Everything below (dictionary build, ~7k-item sort,
                // cache writes, fallback loop) used to run on the
                // MainActor here and produced a ~560 ms hang while
                // the user was staring at the Loading Guide screen.
                // Offload all of it to a detached task. The channels
                // snapshot is captured by value so the task doesn't
                // reach back into the MainActor-isolated store.
                let channelSnapshot = self.channels
                let base = baseURL
                let bridgeMap = epgDataMap
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
                    // Sort each channel's programs then cache them by
                    // the program's own tvg_id key. This covers the
                    // case `Channel.tvg_id == program.tvg_id` (the 75%
                    // path on a real instance).
                    for (tvgID, entries) in byTvgID {
                        let sorted = entries.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
                        await EPGCache.shared.set(sorted, for: "d_\(base)_\(tvgID)")
                    }
                    debugLog("📺 Bulk EPG loaded: \(programs.count) programs across \(byTvgID.count) channels")

                    // Populate cache entries for each channel at the
                    // EXACT key its reader will look at:
                    //   `d_<base>_<channel.tvgID ?? channel.id>`
                    // matches `ChannelListView.makeFetchUpcoming`.
                    //
                    // For channels where `Channel.tvg_id !=
                    // EPGData.tvg_id` (the 25% mismatch case), the
                    // first-pass write above landed under the EPGData
                    // tvg_id, which doesn't match the reader's key.
                    // Bridge via `epg_data_id → EPGData.tvg_id` to
                    // copy the same programs to the reader's key.
                    //
                    // v1.7: also try the channel's UUID. Dispatcharr's
                    // `/api/epg/grid/` emits synthetic "Dummy EPG"
                    // entries for channels without real EPG data,
                    // tagging them with `tvg_id == str(channel.uuid)`.
                    // Pre-v1.7 the bulk path missed those, leading to
                    // hundreds of "filled empty fallbacks" entries
                    // that hid valid (if synthetic) program data
                    // from the List view rows. The Guide view's
                    // `fetchDispatcharr` path always handled this
                    // case; the cold-launch bulk path now matches.
                    //
                    // Falls through to an empty fallback so per-cell
                    // prefetch can't trigger post-loading network
                    // fetches for genuinely EPG-less channels.
                    //
                    // While iterating, also build a map of channel.id
                    // → currently-airing program so we can populate
                    // `ChannelDisplayItem.currentProgram*` in one
                    // batched MainActor write. The List view's
                    // `liveProgram` lookup reads those fields first;
                    // pre-v1.7 they were never set on the Dispatcharr
                    // path so List rows showed only the channel name
                    // until the user opened the Guide tab.
                    var bridgedCount = 0
                    var matchedViaUUID = 0
                    var filledFallbacks = 0
                    var currentByChannelID: [String: ChannelStore.CurrentProgramSnapshot] = [:]

                    /// Helper. Pluck the now-airing entry from a
                    /// pre-sorted list (start ascending). Used three
                    /// times below so factored into a closure.
                    func nowAiring(in entries: [EPGEntry]) -> EPGEntry? {
                        return entries.first(where: { entry in
                            guard let s = entry.startTime, let e = entry.endTime else { return false }
                            return s <= now && e > now
                        })
                    }

                    for channel in channelSnapshot {
                        let tvgID = channel.tvgID ?? ""
                        let keyPart = tvgID.isEmpty ? channel.id : tvgID
                        let cacheKey = "d_\(base)_\(keyPart)"

                        // 1. Direct tvg_id match (the 75% path).
                        //    Already cached by the program-keyed
                        //    write above when keyPart matches a
                        //    program's tvg_id. Capture now-airing
                        //    for the List-view enrichment.
                        if let directEntries = byTvgID[keyPart] {
                            if let nowProg = nowAiring(in: directEntries) {
                                currentByChannelID[channel.id] = .init(
                                    title: nowProg.title,
                                    description: nowProg.description,
                                    start: nowProg.startTime ?? now,
                                    end: nowProg.endTime ?? now
                                )
                            }
                            // Already cached at this key, no copy needed.
                            if await EPGCache.shared.get(cacheKey) != nil {
                                continue
                            }
                        }

                        // 2. EPGData bridge (the 25% mismatch case).
                        if let epgID = channel.dispatcharrEPGDataID,
                           let epgTvgID = bridgeMap[epgID],
                           let bridgeEntries = byTvgID[epgTvgID] {
                            let sorted = bridgeEntries.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
                            await EPGCache.shared.set(sorted, for: cacheKey)
                            if currentByChannelID[channel.id] == nil,
                               let nowProg = nowAiring(in: sorted) {
                                currentByChannelID[channel.id] = .init(
                                    title: nowProg.title,
                                    description: nowProg.description,
                                    start: nowProg.startTime ?? now,
                                    end: nowProg.endTime ?? now
                                )
                            }
                            bridgedCount += 1
                            continue
                        }

                        // 3. UUID match (Dummy EPG entries). The
                        //    bulk grid emits synthetic entries with
                        //    tvg_id == channel.uuid for channels
                        //    that have no real EPG data assigned.
                        //    Match those so the List view shows
                        //    "<channel name>" placeholder programs
                        //    instead of an empty subtitle.
                        if let uuid = channel.uuid?.lowercased(),
                           let dummyEntries = byTvgID[uuid] {
                            let sorted = dummyEntries.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
                            await EPGCache.shared.set(sorted, for: cacheKey)
                            if currentByChannelID[channel.id] == nil,
                               let nowProg = nowAiring(in: sorted) {
                                currentByChannelID[channel.id] = .init(
                                    title: nowProg.title,
                                    description: nowProg.description,
                                    start: nowProg.startTime ?? now,
                                    end: nowProg.endTime ?? now
                                )
                            }
                            matchedViaUUID += 1
                            continue
                        }

                        // No match. Empty fallback so per-cell
                        // prefetch doesn't fire post-loading.
                        if await EPGCache.shared.get(cacheKey) == nil {
                            await EPGCache.shared.set([], for: cacheKey)
                            filledFallbacks += 1
                        }
                    }
                    debugLog("📺 Bulk EPG: bridged \(bridgedCount) channels via epg_data_id, matched \(matchedViaUUID) via Dummy EPG UUID, filled \(filledFallbacks) empty fallbacks; \(currentByChannelID.count) now-airing programs ready for List view")

                    // Hop to MainActor for the @Published write.
                    // ChannelStore lives there; SwiftUI will see one
                    // invalidation and the List view rows pick up
                    // the now-airing program data immediately.
                    let currentMap = currentByChannelID
                    await MainActor.run {
                        ChannelStore.shared.applyCurrentPrograms(currentMap)
                    }
                }.value

                // Refresh Top Shelf with updated program info
                TopShelfDataManager.syncTopChannels(channels: self.channels)

                // v1.6.22: API-only category enrichment.
                // `/api/epg/grid/` deliberately strips `<category>`
                // tags (server-side serializer omission, see
                // Dispatcharr's `EPGGridAPIView`). The fix:
                // `/api/epg/programs/<id>/` returns categories per
                // program. We fan out detail fetches for the
                // CURRENTLY-AIRING program of each channel,
                // throttled at cap-of-4 concurrency, fire-and-forget
                // so initial sync isn't blocked. ~330 calls at 41ms
                // each = ~3-7s background; channel cards tint
                // progressively as results land. Strictly /api/*;
                // no XMLTV stream involved.
                let chSnapForEnrich = self.channels
                let progSnap = programs
                let bridgeMapForEnrich = epgDataMap
                let dAPIForEnrich = DispatcharrAPI(baseURL: baseURL,
                                                   auth: .apiKey(apiKey),
                                                   userAgent: userAgent,
                                                   authMode: authMode)
                Task.detached(priority: .utility) {
                    let now = Date()
                    // Build the same channel lookup used by the bulk
                    // cache write (Channel.tvg_id + EPGData.tvg_id
                    // bridge), so currently-airing matching covers
                    // the 25% of channels with mismatched ids.
                    var tvgToChan: [String: String] = [:]
                    for ch in chSnapForEnrich {
                        if let tvg = ch.tvgID, !tvg.isEmpty {
                            tvgToChan[tvg.lowercased()] = ch.id
                        }
                    }
                    for ch in chSnapForEnrich {
                        guard let epgID = ch.dispatcharrEPGDataID,
                              let bridgedTvg = bridgeMapForEnrich[epgID],
                              !bridgedTvg.isEmpty else { continue }
                        let key = bridgedTvg.lowercased()
                        if tvgToChan[key] == nil { tvgToChan[key] = ch.id }
                    }

                    var currentByChannelID: [String: Int] = [:]
                    for p in progSnap {
                        guard let pid = p.programID,
                              let start = p.startTime?.toDate(),
                              let end = p.endTime?.toDate(),
                              start <= now, end > now,
                              let tvg = p.tvgID, !tvg.isEmpty,
                              let cid = tvgToChan[tvg.lowercased()] else { continue }
                        if currentByChannelID[cid] == nil {
                            currentByChannelID[cid] = pid
                        }
                    }
                    let pids = Array(currentByChannelID.values)
                    debugLog("📺 Category enrichment: \(pids.count) currently-airing programs across \(currentByChannelID.count) channels; fetching /api/epg/programs/<id>/")
                    let cats = await dAPIForEnrich.enrichCategories(programIDs: pids)

                    // v1.7.x Phase 3: capture title alongside category
                    // so propagation can match by exact title rather
                    // than tinting channel-wide. Look up titles by
                    // program_id from the bulk grid snapshot.
                    var titlesByPID: [Int: String] = [:]
                    for p in progSnap {
                        if let pid = p.programID, !p.title.isEmpty {
                            titlesByPID[pid] = p.title
                        }
                    }
                    var byChan: [String: String] = [:]
                    var enrichedByChannel: [String: (category: String, title: String)] = [:]
                    for (cid, pid) in currentByChannelID {
                        guard let c = cats[pid]?.categories else { continue }
                        byChan[cid] = c
                        let title = titlesByPID[pid] ?? ""
                        enrichedByChannel[cid] = (c, title)
                    }
                    debugLog("📺 Category enrichment: \(byChan.count)/\(currentByChannelID.count) channels got categories")
                    await MainActor.run {
                        ChannelStore.shared.applyXMLTVCategories(byChan, serverID: categoryServerID)
                    }

                    // v1.7.x Phase 3: title-matched category
                    // propagation. v1.7.0 ran a channel-wide sweep
                    // (every entry in a channel's EPGCache got the
                    // now-airing category) which was correct >90% of
                    // the time on sports / news / weather channels
                    // but over-tinted variety channels (HBO etc.) by
                    // applying the wrong genre to every program.
                    // v1.7.x narrows the sweep: only entries whose
                    // title EXACTLY matches the enriched program's
                    // now-airing title are tinted. Recurring shows
                    // (SportsCenter ×6/day on ESPN HD, Anderson
                    // Cooper 360 ×2/day on CNN) still get full
                    // coverage; one-off entries (NHL Hockey at
                    // 4-6AM, a movie premiere) stay neutral until
                    // we have their own category. Honest partial
                    // coverage > confident wrong tinting.
                    //
                    // The category-stripe at the channel-card level
                    // (driven by `applyXMLTVCategories` above) still
                    // reflects the now-airing category since that's
                    // about what's playing right now, not the whole
                    // schedule.
                    //
                    // Cost: same number of EPGCache reads + writes
                    // as before (one read per enriched channel, one
                    // write only when at least one entry matches).
                    // The `.map` walks every entry but the title
                    // comparison is cheap (String == String, no
                    // allocations).
                    let baseSnap = base
                    let chSnap = chSnapForEnrich
                    var rewritten = 0
                    var entriesTinted = 0
                    for (cid, info) in enrichedByChannel {
                        guard !info.category.isEmpty,
                              !info.title.isEmpty,
                              let channel = chSnap.first(where: { $0.id == cid })
                        else { continue }
                        let tvgID = channel.tvgID ?? ""
                        let keyPart = tvgID.isEmpty ? channel.id : tvgID
                        let cacheKey = "d_\(baseSnap)_\(keyPart)"
                        guard let entries = await EPGCache.shared.get(cacheKey),
                              !entries.isEmpty else { continue }
                        // Walk entries; tint only exact title matches
                        // that don't already carry the right category
                        // (idempotent on warm relaunch).
                        var localTinted = 0
                        let updated = entries.map { entry -> EPGEntry in
                            guard entry.title == info.title,
                                  entry.category != info.category else {
                                return entry
                            }
                            localTinted += 1
                            return EPGEntry(title: entry.title,
                                            description: entry.description,
                                            startTime: entry.startTime,
                                            endTime: entry.endTime,
                                            category: info.category)
                        }
                        guard localTinted > 0 else { continue }
                        await EPGCache.shared.set(updated, for: cacheKey)
                        rewritten += 1
                        entriesTinted += localTinted
                    }
                    debugLog("📺 Category propagation: tinted \(entriesTinted) title-matched entries across \(rewritten) channels (title-match heuristic; one-off programs stay neutral)")
                }
            } catch {
                debugLog("📺 Bulk EPG failed: \(error.localizedDescription); falling back to lazy loading")
            }

            // v1.6.22: dropped the secondary auto-derived
            // `{base}/output/epg?tvg_id_source=tvg_id` XMLTV pass.
            // Dispatcharr 0.23.0+ (commit 3c55649, 2026-02-01) gates
            // `/output/epg` LAN-only by default; every Cloudflare,
            // Synology QuickConnect, or port-forward user hit HTTP
            // 403. The default EPG path is now REST-only.
            //
            // We DO still honor an explicit user-provided XMLTV
            // override here. Power users who have a reachable
            // XMLTV source (their own LAN-side Dispatcharr URL, a
            // separate XMLTV aggregator, etc.) can paste it into
            // Settings → Custom XMLTV URL and get the
            // `<category>` data the bulk grid omits, layered on
            // top of the REST data already cached above.
            if bulkEPGSucceeded,
               let xmltvURL = Self.dispatcharrXMLTVURL(override: dispatcharrXMLTVOverride) {
                let dAPIForXMLTV = DispatcharrAPI(baseURL: baseURL,
                                                  auth: .apiKey(apiKey),
                                                  userAgent: userAgent,
                                                  authMode: authMode)
                debugLog("📺 loadAllEPG: honoring user XMLTV override at \(xmltvURL.host ?? "?") (in addition to /api/epg/grid/)")
                await primeXMLTVFromURL(xmltvURL, headers: dAPIForXMLTV.streamAuthHeaders)
            }

        case .xtreamCodes:
            // Standard XC EPG: pull the server's bulk xmltv.php guide (full
            // programmes, server-native naming + categories) like every other
            // XC client, through the same XMLTV path Dispatcharr/M3U use.
            // primeXMLTVFromURL populates GuideStore.programs + EPGCache, so the
            // now-playing line (which falls back to GuideStore.programs) and the
            // guide grid both read the bulk feed. Only fall back to per-stream
            // get_short_epg when the feed yields nothing (provider exposes no
            // xmltv.php, or no channel carries an epg_channel_id).
            let xAPIForEPG = XtreamCodesAPI(baseURL: baseURL, username: username, password: password)
            var xmltvOK = false
            if let xcEPGURL = xAPIForEPG.xmltvURL() {
                xmltvOK = await primeXMLTVFromURL(xcEPGURL)
            }
            if !xmltvOK {
                await enrichXtreamEPG(baseURL: baseURL, username: username, password: password)
            }
            // v1.7.3: optional custom XMLTV drives the channel-card
            // category tints (Sports/News/Movies/Kids). Xtream's API
            // exposes no per-program category, so this is the only way
            // XC users get tints. No-op unless the user set a URL.
            let xcXMLTV = xtreamXMLTVOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !xcXMLTV.isEmpty, let xcURL = URL(string: xcXMLTV) {
                await primeXtreamCategoriesFromXMLTV(url: xcURL, baseURL: baseURL,
                                                     username: username, password: password,
                                                     serverID: categoryServerID)
            }

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

        // v1.6.23: circuit breaker for Xtream EPG enrichment, mirroring
        // the GuideStore prefetch breaker. On Xtream servers under
        // duress (slow get_short_epg endpoint, rate limiting, or
        // transient outage), we'd otherwise loop through every
        // channel making 8 concurrent failing requests per batch.
        // After 3 consecutive empty/failed batches we abort the
        // remaining batches and accept partial enrichment for this
        // launch. The Live-TV "now playing" line for un-enriched
        // channels stays empty (matches the channels-loaded-but-no-EPG
        // state Xtream users already see today; not a regression).
        var consecutiveEmptyBatches = 0
        let maxConsecutiveEmpty = 3
        var batchesProcessed = 0
        var batchesAborted = 0

        // Process in batches to limit concurrency.
        for batchStart in stride(from: 0, to: snapshot.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            if consecutiveEmptyBatches >= maxConsecutiveEmpty {
                let remaining = snapshot.count - batchStart
                batchesAborted = (remaining + batchSize - 1) / batchSize
                debugLog("📺 Xtream EPG enrichment: circuit breaker tripped after \(consecutiveEmptyBatches) consecutive empty batches; aborting \(batchesAborted) remaining batches (\(remaining) channels)")
                break
            }
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

            batchesProcessed += 1
            allResults.append(contentsOf: results)
            // Track consecutive-empty for the circuit breaker. An
            // "empty" batch is one where every channel either failed
            // to fetch (try? = nil) or the response had no
            // currently-airing program. The first counts as server
            // distress; the second is normal idle channels. We can't
            // distinguish them cheaply at this layer, so we treat
            // any 0-result batch as a soft signal.
            if results.isEmpty {
                consecutiveEmptyBatches += 1
            } else {
                consecutiveEmptyBatches = 0
            }
        }

        debugLog("📺 Xtream EPG enrichment: enriched \(allResults.count) channels across \(batchesProcessed) batches (\(batchesAborted) batches aborted by circuit breaker)")

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

    /// v1.7.3: fetch an Xtream server's optional custom XMLTV feed and
    /// apply the currently-airing `<category>` per channel so the
    /// channel-card color tints (Sports/News/Movies/Kids) light up.
    /// Xtream's own API exposes no per-program category, so without a
    /// custom XMLTV the tints never appear for XC. The parse is filtered
    /// to the server's known epg_channel_ids to keep memory bounded on
    /// large feeds, then categories route to the same
    /// `applyXMLTVCategories` path Dispatcharr uses. No-op when nothing
    /// matches.
    private func primeXtreamCategoriesFromXMLTV(url: URL, baseURL: String,
                                                username: String, password: String,
                                                serverID: String) async {
        let xAPI = XtreamCodesAPI(baseURL: baseURL, username: username, password: password)
        guard let streams = try? await xAPI.getLiveStreams() else { return }
        // epg_channel_id (lowercased) -> [app channel id (= String(stream_id))]
        var channelIDsByEPGID: [String: [String]] = [:]
        for s in streams {
            guard let epgID = s.epgChannelID?.lowercased(), !epgID.isEmpty else { continue }
            channelIDsByEPGID[epgID, default: []].append(String(s.streamID))
        }
        guard !channelIDsByEPGID.isEmpty else {
            debugLog("📺 XC custom XMLTV: no channels carry an epg_channel_id; nothing to tint")
            return
        }
        let knownIDs = Set(channelIDsByEPGID.keys)
        guard let programs = try? await XMLTVParser.fetchAndParse(url: url, knownChannelIDs: knownIDs),
              !programs.isEmpty else {
            debugLog("📺 XC custom XMLTV: no matching programmes parsed from \(url.host ?? "?")")
            return
        }
        let now = Date()
        var catByChannelID: [String: String] = [:]
        for p in programs where p.startTime <= now && p.endTime > now && !p.category.isEmpty {
            if let cids = channelIDsByEPGID[p.channelID.lowercased()] {
                for cid in cids { catByChannelID[cid] = p.category }
            }
        }
        guard !catByChannelID.isEmpty else {
            debugLog("📺 XC custom XMLTV: parsed \(programs.count) programmes but none currently airing with a category")
            return
        }
        debugLog("📺 XC custom XMLTV: tinting \(catByChannelID.count) channels from custom XMLTV")
        applyXMLTVCategories(catByChannelID, serverID: serverID)
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

    // MARK: - GH #59: Dispatcharr-behind-Xtream channel numbering

    /// What we decided to do with a Dispatcharr-backed XC playlist's numbers.
    private struct XCNumbering {
        /// Sort on the panel's row order rather than on `num`.
        var trustRowOrder = false
        /// Indices (into the raw stream array) whose `num` we will NOT show.
        var suppressed: Set<Int> = []
    }

    /// Detects an Xtream playlist that is really a Dispatcharr server and works
    /// out which of its channel numbers are safe to display.
    ///
    /// Dispatcharr's XC emulation cannot express decimal channel numbers. It
    /// remaps every fractional one to the nearest FREE integer server-side
    /// (`_xc_live_streams_setup`, `apps/output/views.py`), so a lineup of
    /// 1.1/1.2/1.3/2/3/4 reaches us as 1/5/6/2/3/4. Sorting on that scatters
    /// the subchannels to the end of the list, which is what users report as
    /// "subchannels are not appearing". The decimals are destroyed before they
    /// leave the server, so no client can recover them.
    ///
    /// What survives is the ROW ORDER: Dispatcharr emits the list
    /// `.order_by("effective_channel_number")`. So we sort on row order and
    /// blank the numbers we can prove are wrong.
    ///
    /// "Provably wrong" is deliberately conservative: a row is suppressed only
    /// when some LATER row carries a SMALLER number. Because the rows are in
    /// true channel-number order, such a row cannot be holding its own real
    /// number. That catches 5 and 6 above and never blanks a number that is
    /// consistent with everything after it. It is not a complete classifier -
    /// a lineup where a subchannel happens to land on a free low integer (1.2
    /// taking "2" when there is no real channel 2) is indistinguishable from
    /// a genuine channel and keeps its number. We accept showing an occasional
    /// wrong-but-plausible number over blanking correct ones.
    ///
    /// Detection costs no extra request: Dispatcharr always serves logos from
    /// `/api/channels/logos/<id>/cache/`. Real Xtream panels never match, so
    /// they keep sorting by channel number exactly as before.
    ///
    /// Note this only touches DISPLAY. `tvgID` keeps the panel's
    /// `epg_channel_id`, which Dispatcharr derives from the same remapped
    /// integer it uses in its XMLTV output (`apps/output/epg.py`), so EPG
    /// matching stays self-consistent and unaffected.
    private func dispatcharrXCNumbering(for streams: [XtreamStream]) -> XCNumbering {
        guard streams.count > 1 else { return XCNumbering() }
        let looksLikeDispatcharr = streams.contains { s in
            guard let icon = s.streamIcon else { return false }
            return icon.contains("/api/channels/logos/") && icon.hasSuffix("/cache/")
        }
        guard looksLikeDispatcharr else { return XCNumbering() }

        var result = XCNumbering()
        result.trustRowOrder = true

        // Suffix minimum: smallestAfter[i] is the smallest number appearing
        // strictly after row i. A row whose own number exceeds it is out of
        // order relative to the panel's own sorting, so its number is not its
        // own. Channels the panel sent without a number never suppress.
        let nums: [Double?] = streams.map { s -> Double? in
            guard let raw = s.channelNumber else { return nil }
            return Double(raw)
        }
        var smallestAfter = [Double](repeating: .greatestFiniteMagnitude, count: nums.count)
        var running = Double.greatestFiniteMagnitude
        for i in stride(from: nums.count - 1, through: 0, by: -1) {
            smallestAfter[i] = running
            if let n = nums[i] { running = min(running, n) }
        }
        for (i, maybeNum) in nums.enumerated() {
            guard let n = maybeNum else { continue }
            if n > smallestAfter[i] { result.suppressed.insert(i) }
        }
        if !result.suppressed.isEmpty {
            debugLog("📺 XC/Dispatcharr numbering: row order trusted, \(result.suppressed.count) of \(streams.count) channel numbers blanked (server remapped decimal subchannels)")
        }
        return result
    }

    private func sortChannels(_ items: [ChannelDisplayItem], groupOrder: [String]) -> [ChannelDisplayItem] {
        // Belt-and-suspenders dedup: drop EXACT-duplicate streams before
        // sorting. A messy provider can return two rows that resolve to
        // the same stream URL (a repeated M3U entry, or a reseller Xtream
        // panel that lists a stream_id twice). Collapsing them here keeps
        // every downstream channel list free of duplicate SwiftUI
        // identities, which otherwise drop rows / mis-animate on iOS and
        // hard-crash the equivalent LazyColumn on Android. Keyed by the
        // unique stream URL (rowKey falls back to id when a channel has no
        // URL), so DISTINCT channels that merely share a tvg-id are all
        // kept: they carry different stream URLs. First occurrence wins.
        var seenRowKeys = Set<String>()
        let deduped = items.filter { seenRowKeys.insert($0.rowKey).inserted }

        // `uniquingKeysWith: { first, _ in first }` so duplicate
        // group names in `groupOrder` (some IPTV resellers ship
        // multiple categories with identical display names) don't
        // trap the way `uniqueKeysWithValues:` would. First
        // occurrence wins — the duplicate just collapses onto
        // the same display position.
        let idx = Dictionary(groupOrder.enumerated().map { ($1, $0) },
                             uniquingKeysWith: { first, _ in first })
        // GH #59: when the provider's row order is more trustworthy than its
        // channel numbers (Dispatcharr behind Xtream — see
        // `dispatcharrXCNumbering`), sort on that and skip the numeric compare
        // entirely. Sorting by number here is exactly what displaced decimal
        // subchannels to the end of the list.
        if deduped.contains(where: { $0.panelOrder != nil }) {
            return deduped.sorted { ($0.panelOrder ?? Int.max) < ($1.panelOrder ?? Int.max) }
        }
        return deduped.sorted {
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
        epgURL: String = "",
        authMode: DispatcharrAuthHeaderMode = .xapikey,
        userAgent: String = DeviceInfo.defaultUserAgent,
        dispatcharrChannelProfileIDs: [Int] = []
    ) async throws -> ([ChannelDisplayItem], [String]) {
        switch type {
        case .m3uPlaylist:
            // A pasted XC get.php link is an Xtream playlist wearing an M3U
            // hat. Load it through the panel's JSON instead: 23.7MB rather
            // than 538MB on the provider measured 2026-08-10, and it carries
            // the epg_channel_id the M3U omits entirely (that panel emitted
            // tvg-id="" on every single entry). fetchXtream also gives these
            // playlists correct catch-up and channel numbering for free.
            if let xc = XtreamCodesAPI.credentials(fromGetPhpURL: baseURL) {
                debugLog("📺 M3U URL is an Xtream get.php link; loading via player_api instead")
                do {
                    return try await fetchXtream(baseURL: xc.base,
                                                 username: xc.username,
                                                 password: xc.password)
                } catch {
                    // The reroute is a URL-shape guess, not a probe. Some
                    // middleware serves get.php but has player_api disabled,
                    // broken, or separately IP-locked — for those users the
                    // pasted M3U worked before the reroute existed, and it
                    // must keep working. Only a get.php URL lands here, so
                    // falling back re-fetches at most the M3U they pasted.
                    debugLog("📺 player_api failed for the get.php link (\(error.localizedDescription)); falling back to the pasted M3U itself")
                    return try await fetchM3U(baseURL: baseURL, epgURL: epgURL)
                }
            }
            return try await fetchM3U(baseURL: baseURL, epgURL: epgURL)
        case .xtreamCodes:
            return try await fetchXtream(baseURL: baseURL, username: username, password: password)
        case .dispatcharrAPI:
            // v1.7.x: thread serverID + username so Dispatcharr's
            // API instance can drive silent api_key re-bootstrap on
            // 401 (Save Credentials Option 1). dispatcharrChannelProfileIDs
            // drives the child-safety Channel Profile filter (empty = show all).
            return try await fetchDispatcharr(baseURL: baseURL, apiKey: apiKey,
                                              authMode: authMode, userAgent: userAgent,
                                              serverID: serverID,
                                              savedUsername: username,
                                              channelProfileIDs: dispatcharrChannelProfileIDs)
        }
    }

    // MARK: - M3U

    private func fetchM3U(baseURL: String, epgURL: String = "") async throws -> ([ChannelDisplayItem], [String]) {
        guard let url = URL(string: baseURL) else { throw APIError.invalidURL }
        // Download to disk and line-stream the parse. This used to buffer the
        // WHOLE body as Data and then build a String of it (UTF-16, ~2x again)
        // before parsing -- on a provider playlist measured at 538MB that is
        // well over a gigabyte resident, which no device survives. Android hit
        // exactly this (GH #26/#31) and fixed it; the fix was never brought
        // across. M3UParser.fetchAndParse already does the streaming download,
        // charset detection and the empty-body / HTTP guards this inline copy
        // was duplicating by hand.
        let parsed = try await M3UParser.fetchAndParse(url: url)
        var groups: [String] = []
        for ch in parsed {
            if !ch.groupTitle.isEmpty && !groups.contains(ch.groupTitle) { groups.append(ch.groupTitle) }
        }

        // Fetch EPG concurrently with building channel items (non-fatal on failure).
        async let epgFetch: [ParsedEPGProgram] = {
            guard !epgURL.isEmpty, let epgURLParsed = URL(string: epgURL) else { return [] }
            return (try? await XMLTVParser.fetchAndParse(url: epgURLParsed)) ?? []
        }()

        // v1.7.3: derive a deterministic, reload-stable id from the
        // stream URL so M3U favorites (and now-playing restore /
        // multiview tile identity) survive a playlist refresh. The
        // previous `ch.id.uuidString` was a fresh UUID every parse, so
        // anything keyed by `ChannelDisplayItem.id` silently reset.
        // Dedup by occurrence so a playlist that repeats a URL still
        // yields distinct, stable ids. See `M3UParser.stableChannelID`.
        var m3uIDOccurrence: [String: Int] = [:]
        var items: [ChannelDisplayItem] = parsed.enumerated().compactMap { (i, ch) in
            guard let streamURL = URL(string: ch.url) else { return nil }
            let baseID = M3UParser.stableChannelID(forStreamURL: ch.url)
            let occ = m3uIDOccurrence[baseID, default: 0]
            m3uIDOccurrence[baseID] = occ + 1
            let stableID = occ == 0 ? baseID : "\(baseID)-\(occ)"
            var item = ChannelDisplayItem(
                id: stableID, name: ch.name,
                // v1.7.x: `M3UChannel.channelNumber` is now the raw
                // `tvg-chno` string, so decimal numbers like "2.1"
                // pass through unchanged. Fall back to the 1-based
                // list index when `tvg-chno` is missing or empty.
                number: ch.channelNumber ?? String(i + 1),
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
        // `uniquingKeysWith: { first, _ in first }` so a provider that returns
        // two categories sharing an id (misconfigured / reseller Xtream panels)
        // collapses the duplicate instead of trapping the channel load on a
        // duplicate-key fatal error. First occurrence wins. Mirrors the same
        // defense in sortChannels above.
        let catOrder   = Dictionary(categories.enumerated().map { ($1.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let usedCatIDs = Set(streams.compactMap { $0.categoryID })
        var groupOrder = categories.filter { usedCatIDs.contains($0.id) }.map { $0.name }
        if streams.contains(where: { ($0.categoryID ?? "").isEmpty }) { groupOrder.append("Uncategorized") }
        // GH #59: decide up-front whether this panel's `num` field can be
        // trusted. See `dispatcharrXCNumbering` for the full reasoning.
        let numbering = dispatcharrXCNumbering(for: streams)
        let items: [ChannelDisplayItem] = streams.enumerated().compactMap { (i, s) in
            let urls = xAPI.streamURLs(for: s); guard let primary = urls.first else { return nil }
            let catName = categories.first(where: { $0.id == s.categoryID })?.name ?? "Uncategorized"
            var item = ChannelDisplayItem(
                id: String(s.streamID), name: s.name,
                // GH #59: keep the panel's channel number verbatim (decimal
                // subchannels like "6.1" included); list index only when the
                // panel sent nothing. On a Dispatcharr-backed XC playlist a
                // number the server demonstrably remapped is blanked instead
                // (`numbering.suppressed`) — better to show nothing than a
                // number belonging to a different channel.
                number: numbering.suppressed.contains(i) ? "" : (s.channelNumber ?? String(i + 1)),
                logoURL: s.streamIcon.flatMap { URL(string: $0) },
                group: catName,
                categoryOrder: catOrder[s.categoryID ?? ""] ?? Int.max,
                streamURL: primary, streamURLs: urls,
                panelOrder: numbering.trustRowOrder ? i : nil)
            // Carry the Xtream epg_channel_id as the tvg-id so the bulk
            // xmltv.php guide can match `<programme channel="...">` back to
            // this channel through the same path M3U/Dispatcharr use.
            if let epgID = s.epgChannelID, !epgID.isEmpty { item.tvgID = epgID }
            // Catch-up: carry the provider's archive window (days); 0 when
            // tv_archive is off. The XC stream_id doubles as item.id, which
            // is what the timeshift URL builder needs.
            if s.tvArchive == 1, s.tvArchiveDuration > 0 {
                item.catchupDays = s.tvArchiveDuration
            }
            return item
        }
        let sorted = sortChannels(items, groupOrder: groupOrder)
        return (sorted, derivedGroupOrder(from: sorted))
    }

    // MARK: - Dispatcharr API

    private func fetchDispatcharr(baseURL: String, apiKey: String,
                                  authMode: DispatcharrAuthHeaderMode = .xapikey,
                                  userAgent: String = DeviceInfo.defaultUserAgent,
                                  serverID: UUID? = nil,
                                  savedUsername: String? = nil,
                                  channelProfileIDs: [Int] = []) async throws -> ([ChannelDisplayItem], [String]) {
        debugLog("🔷 ChannelStore.fetchDispatcharr: starting")
        // v1.7.x: silent api_key re-bootstrap is gated on a non-nil
        // serverID + savedUsername. Empty username (server is in
        // API Key mode without saved credentials) → re-bootstrap is
        // a no-op and 401s surface to the caller as before.
        let dAPI = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                  userAgent: userAgent, authMode: authMode,
                                  serverID: serverID,
                                  savedUsername: (savedUsername?.isEmpty ?? true) ? nil : savedUsername)
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
        var dChannels: [DispatcharrChannel]
        do {
            dChannels = try await channelsFetch
            debugLog("🔷 ChannelStore.fetchDispatcharr: channels=\(dChannels.count)")
        } catch {
            debugLog("🔷 ChannelStore.fetchDispatcharr: channels FAILED: \(error.localizedDescription)")
            throw error
        }

        // Self-heal the Channel Profile assignment on every load. The
        // persisted dispatcharrChannelProfileIDs is captured only when a
        // server is first added (AddServer Save) - never on load, and not
        // even on Edit Server > Test Connection - so a server added before
        // this build, or one whose profile changed server-side, carries a
        // stale or empty snapshot. That would skip the filter below and
        // leak the full channel list (the reported "kids profile still
        // shows all channels"). Re-fetch the connected user's profiles
        // live and let them win; persist the result back (only when it
        // changed) so the stored model is accurate and serves as a
        // fail-closed fallback on a later load whose whoami call fails.
        // Verified against the live server: /api/accounts/users/me/ returns
        // channel_profiles for X-API-Key auth (kids=[44], admin=[]).
        var effectiveProfileIDs = channelProfileIDs
        if let user = try? await dAPI.fetchCurrentUser() {
            effectiveProfileIDs = user.channelProfiles
            if let server = activeServer,
               server.dispatcharrProfileIDList != user.channelProfiles {
                server.dispatcharrChannelProfileIDs =
                    user.channelProfiles.map(String.init).joined(separator: ",")
                debugLog("🔷 ChannelStore.fetchDispatcharr: captured Channel Profile assignment \(user.channelProfiles)")
            }
        }

        // v1.7.x Channel Profile filter (child-safety): when the
        // connected Dispatcharr user is assigned one or more Channel
        // Profiles (a curated subset of channels, e.g. a "Kids" profile),
        // /api/channels/channels/ STILL returns every channel, so we
        // fetch each profile's membership from /api/channels/profiles/<id>/
        // and keep only channels whose id is in the union. Empty
        // `channelProfileIDs` (no profile assigned, or a non-Dispatcharr
        // path) skips this entirely and shows all channels - the common
        // admin case, identical to pre-v1.7.x behaviour.
        //
        // Fail-closed policy: a Channel Profile is a child-safety filter,
        // so it must never leak the full channel list. If any
        // profile-membership fetch throws (network blip, decode error),
        // we let it propagate so the whole channel load fails and the
        // caller keeps the prior channels (or retries), instead of
        // showing everything unfiltered. A profile that decodes to an
        // empty allow-set is respected literally (it enables no channels).
        if !effectiveProfileIDs.isEmpty {
            var allowedIDs = Set<Int>()
            for profileID in effectiveProfileIDs {
                let ids = try await dAPI.fetchChannelProfileChannelIDs(profileID: profileID)
                allowedIDs.formUnion(ids)
                debugLog("🔷 ChannelStore.fetchDispatcharr: profile \(profileID) -> \(ids.count) channel ids")
            }
            let before = dChannels.count
            dChannels = dChannels.filter { allowedIDs.contains($0.id) }
            debugLog("🔷 ChannelStore.fetchDispatcharr: Channel Profile filter \(before) -> \(dChannels.count) channels (allowed union=\(allowedIDs.count))")
        }

        // Task #189 (Android parity): USER-CHOSEN Channel Profile from the
        // Edit Playlist picker, applied as a second intersection AFTER the
        // account filter above (matching Android PlaylistRepository's
        // Layer A/Layer B order). Unlike the account filter this is a
        // convenience selection, so it fails OPEN: a membership-fetch
        // error logs and keeps the current list instead of failing the
        // whole load or blanking the lineup.
        if let selectedProfileID = activeServer?.dispatcharrSelectedProfileID {
            do {
                let ids = Set(try await dAPI.fetchChannelProfileChannelIDs(profileID: selectedProfileID))
                let before = dChannels.count
                dChannels = dChannels.filter { ids.contains($0.id) }
                debugLog("🔷 ChannelStore.fetchDispatcharr: selected profile \(selectedProfileID) filter \(before) -> \(dChannels.count) channels")
            } catch {
                debugLog("🔷 ChannelStore.fetchDispatcharr: selected profile \(selectedProfileID) fetch failed, keeping all channels (fail-open): \(error.localizedDescription)")
            }
        }

        // uniquingKeysWith so duplicate group ids (or a malformed paginated
        // response that repeats a row) collapse instead of trapping the load
        // on a duplicate-key fatal error. First occurrence wins.
        let groupNameByID = Dictionary(dGroups.map { ($0.id, $0.name) },
                                       uniquingKeysWith: { first, _ in first })
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
            // Delegate to the shared builder so the live-stream URL
            // format has a single source of truth (the LAN/WAN failover
            // path re-derives the same URL from a flipped effectiveBaseURL).
            // `base` is already trailing-slash-stripped here, so the
            // helper's own stripping is a no-op and the result is
            // byte-identical to the previous inline format.
            return ChannelStore.dispatcharrStreamURLs(base: base, uuid: uuid)
        }

        var items: [ChannelDisplayItem] = dChannels.enumerated().map { (i, ch) in
            let grp  = ch.channelGroupID.flatMap { groupNameByID[$0] } ?? "Uncategorized"
            let urls = streamURLs(ch.uuid)
            // v1.7.x: `DispatcharrChannel.channelNumber` is now a
            // pre-normalised string (whole-number doubles flattened
            // to integer form, decimals preserved, strings passed
            // through trimmed). Fall back to the 1-based list index
            // when the API returned null / missing.
            let num = ch.channelNumber ?? String(i + 1)
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
            // v1.6.22: carry the epg_data_id FK so the EPG matcher
            // can bridge `Channel.epg_data_id → EPGData.tvg_id`
            // when `Channel.tvg_id` doesn't agree with how the
            // bulk grid keys programs (the 25% mismatch case).
            // v1.7.x: prefer the server's computed effective_epg_data_id
            // when present (it accounts for auto-mapping and can diverge
            // from the raw FK), falling back to epg_data_id on older
            // servers. Single assignment site, so all three bridge loops
            // (guide, list-enrichment, category-enrichment) inherit it.
            item.dispatcharrEPGDataID = ch.effectiveEpgDataID ?? ch.epgDataID
            // Catch-up: server-side rollup of the channel's provider
            // streams (is_catchup + MAX catchup_days, Dispatcharr dev).
            // Dispatcharr 0.30: catchup_enabled off for this account
            // hides every catch-up affordance (the server 403s them).
            if ch.isCatchup, ch.catchupDays > 0, activeServer?.dispatcharrCanUseCatchup ?? true {
                item.catchupDays = ch.catchupDays
            }
            return item
        }
        items = sortChannels(items, groupOrder: groupOrder)
        // Catch-up depth as the server reports it (Logan 2026-09-05: "why
        // can't I replay older programmes"): one histogram line per load.
        let catchupHistogram = Dictionary(grouping: items, by: { $0.catchupDays })
            .mapValues(\.count).sorted { $0.key < $1.key }
            .map { "\($0.key)d: \($0.value)" }.joined(separator: ", ")
        let sample = items.filter { $0.catchupDays > 0 }.prefix(6)
            .map { "\($0.name)=\($0.catchupDays)d" }.joined(separator: ", ")
        debugLog("📺 Dispatcharr catch-up days across \(items.count) channels: [\(catchupHistogram)] e.g. \(sample)")

        // Current-program enrichment used to live here (populated
        // from the removed `getCurrentPrograms()` call above). It
        // now happens lazily via the EPG guide's bulk grid fetch
        // plus per-cell prefetch, so we just return the channels
        // without now-airing data at load time.

        return (items, derivedGroupOrder(from: items))
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
    ///
    /// `servers` gates the rows against Dispatcharr 0.30 per-user
    /// permissions. Top Shelf keychain items survive app deletion (see
    /// `clearAll`), so a movie row written while `vod_movies_enabled` was
    /// true kept rendering on the tvOS home screen (and its deep link kept
    /// working) after the permission was revoked. The extension is a
    /// separate process with no access to SwiftData, so the gate has to be
    /// here, on the write side. An empty `servers` (or an unprobed account)
    /// denies nothing.
    static func syncContinueWatching(_ items: [WatchProgress], servers: [ServerConnection] = []) {
        #if os(tvOS)
        func permitted(_ p: WatchProgress) -> Bool {
            guard let sid = p.serverID,
                  let server = servers.first(where: { $0.id.uuidString == sid }) else { return true }
            // "series" / "episode" rows belong to the series catalog;
            // everything else is a movie.
            let isSeries = p.vodType == "series" || p.vodType == "episode" || p.seriesID != nil
            return isSeries ? server.dispatcharrCanViewSeries : server.dispatcharrCanViewVOD
        }
        let recent = items
            .filter { !$0.isFinished && permitted($0) }
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

    /// Serial background queue for the actual SecItem read/write/delete
    /// calls. v1.7.x launch-hang fix: Archie's 2026-06-06 Apple TV log
    /// showed `[WATCHDOG] HANG: ping#3 took 4754.8ms` during launch, with
    /// the TopShelf `keychain[continueWatching]` / `keychain[topChannels]`
    /// writes landing right in the hang window. SecItemUpdate/SecItemAdd on
    /// tvOS routinely take hundreds of ms to multiple seconds (keychain
    /// index work, iCloud-Keychain coordination), and these ran
    /// SYNCHRONOUSLY on the main actor from RootView.onAppear's launch
    /// sequence. The Top Shelf extension only reads these items lazily when
    /// tvOS renders the shelf - nothing about app launch needs the write to
    /// have completed - so the SecItem calls move to this background queue.
    /// Serial (not concurrent) so writes/deletes to the same key keep their
    /// program order: clearAll()'s deletes stay ahead of a subsequent
    /// syncContinueWatching() write. The JSON payload is built on the
    /// caller's thread (cheap, microseconds for these tiny arrays) and only
    /// the Sendable `Data` is handed to the queue.
    private static let ioQueue = DispatchQueue(label: "aerio.topshelf.keychain", qos: .utility)

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
        // Run the SecItem calls off the main thread (see ioQueue). `data`
        // and `key` are Sendable value types, safe to capture.
        ioQueue.async {
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
        }
        #endif
    }

    // MARK: Delete

    /// Deletes a single keychain item by account name. Used by
    /// `TopShelfDataManager.clearAll()` to wipe stale Top Shelf data that
    /// would otherwise survive an app delete/reinstall.
    static func delete(key: String) {
        #if os(tvOS)
        // Same off-main treatment as writeData, on the SAME serial queue so
        // a clearAll() delete stays ordered ahead of any subsequent write
        // to the same key. `key` is Sendable.
        ioQueue.async {
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
    /// Equal-value writes to these are FILTERED (review 2026-09-11
    /// section 6 proposal 4, session.txt:284 and :3800): the tune second
    /// carried `pub:nowPlaying=11` and then `=16`, each publish
    /// re-rendering three view trees, and a @Published write with an
    /// equal value still fires objectWillChange
    /// (memory/feedback_published_write_on_equal_value.md). The storage
    /// keeps the @Published wrapper (so observers still see real
    /// changes); the public name is a guarded setter. None of these are
    /// used as a Binding anywhere, so the lost `$` projection costs
    /// nothing - `$playingItem` is the only projection in use and stays
    /// a plain @Published below.
    @Published var playingItem: ChannelDisplayItem? = nil {
        didSet {
            // Entering the fullscreen player cancels and closes any open
            // search (Logan 2026-09-16). See SearchDismissCenter.
            if playingItem != nil, oldValue == nil {
                SearchDismissCenter.dismissAll(reason: "fullscreen player")
            }
        }
    }
    @Published private var _playingHeaders: [String: String] = [:]
    var playingHeaders: [String: String] {
        get { _playingHeaders }
        set { if newValue != _playingHeaders { _playingHeaders = newValue } }
    }
    @Published private var _isMinimized: Bool = false
    var isMinimized: Bool {
        get { _isMinimized }
        set { if newValue != _isMinimized { _isMinimized = newValue } }
    }
    // #42 Part 3: debounce state distinguishing a SINGLE Back (restore the mini
    // to fullscreen) from a DOUBLE Back (jump to the top channel).
    var menuMiniPressCount = 0
    var menuMiniDebounce: Task<Void, Never>?

    /// Double-Back-to-close (Logan 2026-09-14, reworked): the solo player's
    /// Menu/Back does NOT minimize on the press any more. It schedules the
    /// minimize `doubleBackCloseWindow` later and parks the task here. A
    /// second Menu/Back inside that window cancels the task and closes the
    /// session outright, so the user never sees a mini flash up and vanish.
    /// Not @Published: nothing renders off it, and a publish here would
    /// re-run every observer on each press.
    var pendingMinimize: Task<Void, Never>?
    /// How long the first Back waits for a possible second one. Short enough
    /// that a single Back still feels immediate.
    static let doubleBackCloseWindow: TimeInterval = 0.3

    /// Arm the deferred minimize. `body` runs on the main actor once the
    /// window elapses without a second Menu/Back; it is the caller's whole
    /// minimize path (minimize + any follow-up focus work).
    func scheduleMinimize(_ body: @escaping @MainActor () -> Void) {
        pendingMinimize?.cancel()
        pendingMinimize = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.doubleBackCloseWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NowPlayingManager.shared.pendingMinimize = nil
            body()
        }
    }

    /// Consume-once: true when this Menu/Back press arrived while a deferred
    /// minimize was still pending, i.e. it is the second press of a double
    /// Back. Cancels the pending minimize so no mini player is ever shown.
    func consumeDoubleBackClose() -> Bool {
        guard let task = pendingMinimize else { return false }
        task.cancel()
        pendingMinimize = nil
        return true
    }

    /// True while a CarPlay scene is connected (set by CarPlaySceneDelegate
    /// on connect/disconnect). Drives the CarPlay branch in
    /// MPVPlayerView.didEnterBackground so audio keeps playing in the car
    /// with video suppressed. Always false off CarPlay and on tvOS.
    @Published var isCarPlayConnected: Bool = false
    @Published private var _isLive: Bool = true
    var isLive: Bool {
        get { _isLive }
        set { if newValue != _isLive { _isLive = newValue } }
    }

    /// The channel that was playing before the current one, for the
    /// last-channel "zap back" gesture (rightShort default in the tvOS remote
    /// map). Captured on every distinct live tune.
    @Published private var _previousChannelID: String? = nil
    var previousChannelID: String? {
        get { _previousChannelID }
        set { if newValue != _previousChannelID { _previousChannelID = newValue } }
    }
    /// Set when the fullscreen player hands off to global search (hold-Down);
    /// the search sheet's onDismiss restores fullscreen when this is true.
    @Published var searchOpenedFromPlayer: Bool = false

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
    @Published private var _configuredAsMultiviewAdapter: Bool = false
    var configuredAsMultiviewAdapter: Bool {
        get { _configuredAsMultiviewAdapter }
        set { if newValue != _configuredAsMultiviewAdapter { _configuredAsMultiviewAdapter = newValue } }
    }

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
    @Published private var _miniPlayerBottomAbs: CGFloat = 0
    var miniPlayerBottomAbs: CGFloat {
        get { _miniPlayerBottomAbs }
        set { if newValue != _miniPlayerBottomAbs { _miniPlayerBottomAbs = newValue } }
    }

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
    @Published private var _chromeIsVisible: Bool = false
    var chromeIsVisible: Bool {
        get { _chromeIsVisible }
        set { if newValue != _chromeIsVisible { _chromeIsVisible = newValue } }
    }

    /// v1.6.18: mirror of whether the Stream Info overlay is open.
    /// Both the legacy PlayerView and unified MultiviewContainerView
    /// write this when their `showStreamInfo` flips. Read by
    /// `ChannelInfoBanner` to suppress itself while Stream Info is
    /// visible — without this, on iPhone the banner's top-left
    /// position overlaps the Stream Info card's top-left position
    /// and covers the stats the user explicitly opened.
    @Published private var _streamInfoIsVisible: Bool = false
    var streamInfoIsVisible: Bool {
        get { _streamInfoIsVisible }
        set { if newValue != _streamInfoIsVisible { _streamInfoIsVisible = newValue } }
    }

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
        #if os(iOS)
        // GH #33: while this phone is a companion remote, a live channel tap
        // RETUNES THE TV instead of starting local playback (the user browsed
        // the guide via the remote's Channels button). Non-Dispatcharr
        // channels can't be addressed on the TV and fall through to local.
        if isLive, CompanionClient.shared.isControlling,
           let androidID = CompanionClient.androidChannelID(for: item) {
            debugLog("🎮 NowPlaying.startPlaying: routing \(item.name) to companion TV")
            CompanionClient.shared.setChannel(androidID, title: item.name)
            return
        }
        // Rule 1 / rule 5 (Logan 2026-09-12): the same gate for Google Cast.
        // While a cast session is live a channel tap CASTS the channel (the
        // phone shows nothing locally but the card update) -- including the
        // session that connected with nothing playing, where the card says
        // "Select a Channel".
        if isLive, AerioCastController.shared.isCasting {
            debugLog("🎮 NowPlaying.startPlaying: routing \(item.name) to the cast receiver")
            AerioCastController.shared.castPickedChannel(item)
            return
        }
        #endif
        debugLog("🎮 NowPlaying.startPlaying: \(item.name) (id=\(item.id)), isLive=\(isLive), wakeChrome=\(wakeChrome), wasMinimized=\(isMinimized), wasPlaying=\(playingItem?.name ?? "nil")")
        // Capture the outgoing channel for the last-channel zap gesture (a
        // second zap toggles back because this fires again on the return tune).
        if isLive, let outgoing = playingItem?.id, outgoing != item.id {
            previousChannelID = outgoing
        }
        // Captured before the write below: the PiP handoff check further
        // down needs to know whether this is a different item.
        let wasItemID = playingItem?.id
        if playingItem != item { playingItem = item }
        // v1.6.18: persistent breadcrumb for guide focus default —
        // see the property docstring above.
        lastPlayedChannelID = item.id
        playingHeaders = headers
        self.isLive = isLive
        isMinimized = consumeStartMinimized()
        #if os(iOS)
        // AirPlay route already selected (device log 2026-09-25 12:36:33):
        // never present the fullscreen player; mount minimized and hidden,
        // the remote-session card carries the tune.
        if isLive, AirPlayMonitor.shared.beginHeadlessTune(channel: item.name) {
            isMinimized = true
        }
        // A new tune while foreground PiP is up stays in PiP (Logan
        // 2026-09-14): hand the window over to the new session instead of
        // expanding. The same item re-announcing itself is not a tune.
        let pip = ForegroundPiPBridge.shared
        if pip.isActive, wasItemID != item.id { pip.beginHandoff() }
        if pip.isHandingOff {
            isMinimized = true
        } else if !isMinimized {
            pip.dismissForExpand()
        }
        #endif
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

    /// tvOS "Play Channels In: Mini Player" (Android #226 twin, AerioTV-
    /// Android 8cfddab): armed right before a browse tune so startPlaying
    /// mounts the session ALREADY minimized. The old flow began fullscreen
    /// and minimized 400ms later, flashing the full player over the guide.
    /// Consume-once with a freshness cap so an aborted tune can't leak the
    /// flag into an unrelated later fullscreen tune.
    private var startMinimizedRequestedAt: Date?

    func requestStartMinimized() {
        startMinimizedRequestedAt = Date()
    }

    private func consumeStartMinimized() -> Bool {
        guard let at = startMinimizedRequestedAt else { return false }
        startMinimizedRequestedAt = nil
        return Date().timeIntervalSince(at) <= 2
    }

    func minimize() {
        debugLog("🎮 NowPlaying.minimize: \(playingItem?.name ?? "nil")")
        #if os(iOS)
        // iPhone has no docked mini (Logan 2026-09-14): every minimize is
        // foreground PiP, which hides the host and calls applyMinimized.
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The PiP hop tears the host down and rebuilds the tab beneath
            // it; resign once more here so nothing under it can claim the
            // keyboard on the way through.
            SearchDismissCenter.dismissAll(reason: "minimize to PiP")
            ForegroundPiPBridge.shared.request()
            return
        }
        #endif
        applyMinimized()
    }

    /// The state half of minimize, without the iPhone PiP routing.
    func applyMinimized() {
        isMinimized = true
        SearchDismissCenter.resignKeyboard()
        // #42: the chrome can't be visible once we minimize. Clear the shared
        // mirror here so the re-coupled ChannelInfoBanner can't strand on a
        // stale `true` (the .onChange mirror won't fire if the container
        // unmounts before the chrome's own auto-hide does).
        chromeIsVisible = false
    }

    func expand() {
        debugLog("🎮 NowPlaying.expand: \(playingItem?.name ?? "nil")")
        // Engine-agnostic now: an AVPlayer sole tile lives in the same
        // container as mpv, so "fullscreen" is just un-minimizing the
        // mounted container, no teardown, no restart, no separate screen
        // (the old promote-to-native-screen path is retired).
        isMinimized = false
        pendingMinimize?.cancel()
        pendingMinimize = nil
        #if os(iOS)
        // No-op after a PiP restore (the bridge already cleared itself).
        ForegroundPiPBridge.shared.dismissForExpand()
        #endif
    }

    func stop() {
        debugLog("🎮 NowPlaying.stop: \(playingItem?.name ?? "nil")")
        playingItem = nil
        isMinimized = false
        pendingMinimize?.cancel()
        pendingMinimize = nil
        // #42: authoritative reset of the chrome mirror on every playback
        // teardown. The flag is only ever *set* by .onChange observers in
        // MultiviewContainerView / PlayerView, which don't fire `false` when
        // those views unmount — so without this it persists `true` into the
        // next session and the re-coupled banner flashes on the guide.
        chromeIsVisible = false
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

    /// Remote Control #195: a recognized Up/Down HOLD supersedes the
    /// short-press flip its press-down queued (the 0.25s hold threshold
    /// beats this 300ms debounce, so the cancel always lands first).
    @MainActor
    func cancelPendingChannelChange() {
        pendingChannelChangeTask?.cancel()
        pendingChannelChangeTask = nil
        pendingChannelStep = 0
    }

    /// Tune the previously-playing channel (last-channel "zap back"). Immediate
    /// (bypasses the 300ms flip accumulate) so a decisive zap isn't swallowed;
    /// the tune re-captures the outgoing channel, so a second zap toggles
    /// back to where you were.
    @MainActor
    func zapToPreviousChannel() {
        guard let prevID = previousChannelID,
              let target = ChannelStore.shared.channels.first(where: { $0.id == prevID }) else { return }
        tuneDirect(target)
    }

    /// Remote Control #195: direct in-place tune to [target] from the player
    /// overlays (Channels / Recently Watched) and the last-channel zap. Same
    /// engine path as `flushPendingChannelChange`: unified playback swaps the
    /// sole tile's content in place (no teardown blackdrop), falling back to
    /// a session rebuild when the swap can't target a tile; legacy playback
    /// routes through `startPlaying`. `startPlaying` always runs for the
    /// manager bookkeeping (banner, recents, last-played, zap memory).
    @MainActor
    func tuneDirect(_ target: ChannelDisplayItem) {
        guard target.id != playingItem?.id else { return }
        let server = ChannelStore.shared.activeServer
        let headers = server?.authHeaders ?? ["Accept": "*/*"]
        if PlaybackFeatureFlags.useUnifiedPlayback {
            let store = MultiviewStore.shared
            let didSwap: Bool = {
                guard store.tiles.count == 1,
                      let tileID = store.audioTileID else { return false }
                return store.swapTileContent(tileID: tileID, to: target, server: server)
            }()
            if !didSwap {
                debugLog("[TuneDirect] swap path unavailable; rebuilding session for \(target.name)")
                PlayerSession.shared.exit()
                PlayerSession.shared.enterMultiview(seeding: target, server: server)
            }
        }
        startPlaying(target, headers: headers, isLive: true, wakeChrome: false)
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
        // Remember where we came from so the last-channel zap can return here
        // (the unified in-place swap below doesn't route through startPlaying).
        previousChannelID = current.id
        let server = ChannelStore.shared.activeServer
        let resolvedHeaders = server?.authHeaders ?? ["Accept": "*/*"]
        debugLog("[MV-ChannelFlip] flush step=\(step) from=\(current.name)(id=\(current.id)) to=\(next.name)(id=\(next.id)) unified=\(PlaybackFeatureFlags.useUnifiedPlayback)")
        if PlaybackFeatureFlags.useUnifiedPlayback {
            // v1.7.x Option A: in-place content swap on the existing
            // N=1 tile instead of `PlayerSession.exit() +
            // enterMultiview(seeding:)`. The old teardown lifecycle
            // dismantled the entire MPVPlayerView Coordinator (mpv
            // handle destroyed, GL context torn down, AVSampleBuffer
            // DisplayLayer detached), then stood a fresh one up for
            // the next channel. The user saw a brief blackdrop, then
            // the new stream's libavformat 1.5s `analyzeduration`
            // probe playing out with `detectedFps == 0` for the first
            // frame and a ~200ms hiccup as cadence locked. "the
            // Moterator" (Discord 2026-05-11) reported the symptom
            // as "30fps for a while, hiccup, then 60fps."
            //
            // `swapTileContent` preserves the tile's SwiftUI id so
            // the Coordinator survives; SwiftUI's update pass spots
            // the new `streamURL` on the Representable and routes
            // through `Coordinator.swapStream` →
            // `mpv loadfile <newURL> replace`. mpv probes the new
            // stream internally while the old channel's last
            // decoded frame stays in the AVSBDL; once
            // `playback-restart` fires, new frames flow at the
            // correct container fps. No teardown blackdrop, no
            // cadence wobble.
            //
            // Gated on N=1 because:
            //   - Channel-flip itself is N=1-only at the call site
            //     (`MultiviewContainerView.swift:732`); we should
            //     never reach this branch with N>1, but the guard
            //     is cheap and defensive.
            //   - Multi-tile multiview channel-flip isn't a
            //     supported gesture today, and the swap-on-audio-
            //     tile path would need additional thought about
            //     non-audio-tile invariants.
            //
            // Fallback to the legacy `exit() + enterMultiview()`
            // path when the store doesn't have a single tile we can
            // target, or when `swapTileContent` returns false
            // (channel not resolvable on the active server, tile
            // id no longer in store). Preserves the prior user-
            // visible behaviour for those edge cases.
            let store = MultiviewStore.shared
            let didSwap: Bool = {
                guard store.tiles.count == 1,
                      let tileID = store.audioTileID else { return false }
                return store.swapTileContent(tileID: tileID, to: next, server: server)
            }()
            if didSwap {
                debugLog("[MV-ChannelFlip] swapTileContent succeeded (in-place reuse, no teardown)")
            } else {
                debugLog("[MV-ChannelFlip] swap path unavailable; falling back to PlayerSession.exit() + enterMultiview(...)")
                PlayerSession.shared.exit()
                PlayerSession.shared.enterMultiview(seeding: next, server: server)
            }
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
    // Movies & TV redesign (2026-09): On Demand split into two first-class
    // tabs. The raw values are new on purpose: a persisted "ondemand"
    // selection from an older build decodes to nil and falls back to Live TV.
    case movies    = "movies"
    case tvShows   = "tvshows"
    case settings  = "settings"

    /// Tabs a user can pick as the default. Favorites is a channel group now.
    static var selectable: [AppTab] { allCases.filter { $0 != .favorites } }

    var title: String {
        switch self {
        case .liveTV:    return "Live TV"
        case .favorites: return "Favorites"
        case .dvr:       return "DVR"
        case .movies:    return "Movies"
        case .tvShows:   return "TV Shows"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .liveTV:    return "antenna.radiowaves.left.and.right"
        case .favorites: return "star.fill"
        case .dvr:       return "record.circle"
        case .movies:    return "film.stack"
        // "tv" has a separate screen layer that keeps its own colour in the
        // selected pill (Logan 2026-09-05); the filled glyph is one layer.
        case .tvShows:   return "tv.fill"
        case .settings:  return "gearshape.fill"
        }
    }

    /// Either half of the former On Demand tab.
    var isVOD: Bool { self == .movies || self == .tvShows }
    /// Tabs built on the media-center scaffold (hero, shelves, grid): Menu
    /// scrolls to the top instead of switching tabs, and the parked-bar
    /// heal stays out of their scroll-driven bar hiding.
    var isMediaCenter: Bool { isVOD || self == .dvr }
}

// MARK: - Main Tab View
#if os(tvOS)
/// Whether the in-place Search screen currently covers the tab content.
/// The guide's hold-Left/hold-Right recognizers live on the WINDOW, so the
/// guide behind the overlay kept reacting to holds aimed at the search
/// keyboard - a hold-Right while typing closed the corner mini (Logan
/// 2026-08-12). Detector sites disarm while this is up.
/// Movies & TV redesign (2026-09): a tab's content has scrolled its tab bar
/// away, so the nav-bar action circles (Refresh, Search) hide with it. The
/// TabView's own bar is hidden by the tab through `.toolbar(.hidden, for:
/// .tabBar)`; the circles are an overlay outside the TabView and need this.
@MainActor
final class TVTabBarScrollState: ObservableObject {
    static let shared = TVTabBarScrollState()
    @Published var isHidden = false
    private init() {}
}

@MainActor
final class TVSearchOverlayState: ObservableObject {
    static let shared = TVSearchOverlayState()
    @Published var isUp = false
    private init() {}
}

/// Whether the guide's group drawer is open, for the Menu handler: Back
/// closes the drawer before anything else (it expanded the mini player
/// instead, Logan 2026-09-05).
@MainActor
final class TVGuideSidebarState {
    static let shared = TVGuideSidebarState()
    var isOpen = false
    private init() {}
}

/// One of the round action buttons beside the tvOS tab bar (Refresh /
/// Search). Sized to read as a sibling of the system tab pills; the focus
/// visual is a white platter with dark glyph to match how the system bar
/// renders its focused pill, so the whole top row reads as one control strip.
struct TVNavActionCircle: View {
    let systemImage: String
    let label: String
    var spinning: Bool = false
    /// Android-parity selected fill: the Search circle stays accent-filled
    /// while its screen is up, so the chrome shows where you are.
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if spinning {
                    ProgressView()
                        .scaleEffect(0.9)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 25, weight: .medium))  // glyph in a fixed box: not text, stays fixed
                }
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(TVNavCircleButtonStyle(isSelected: isSelected))
        .disabled(spinning)
        .accessibilityLabel(label)
    }
}

/// Round focus platter owned by the app (tvOS focus canon: never the squared
/// system platter on custom chrome). Unfocused it is a quiet translucent
/// circle like Android TV's action circles; focused it flips to the white
/// pill-platter look of the adjacent system tab bar.
struct TVNavCircleButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isFocused || isSelected ? .black : .white.opacity(0.85))
            .background(
                Circle()
                    .fill(isFocused ? Color.white
                          : (isSelected ? Color.accentPrimary : Color.white.opacity(0.12)))
            )
            .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.96 : 1.0))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif

/// Builds its content only once the tab has been selected at least once, then
/// keeps it. A tab that has never been opened costs nothing when a store it
/// observes publishes (2026-09-12).
private struct LazyTabContent<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: () -> Content
    @State private var everSelected = false

    var body: some View {
        Group {
            if everSelected || isSelected {
                content()
            } else {
                Color.appBackground
            }
        }
        .onChange(of: isSelected) { _, now in
            if now, !everSelected { everSelected = true }
        }
        .onAppear { if isSelected { everSelected = true } }
    }
}

struct MainTabView: View {
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.modelContext) private var modelContext
    @Query private var allServers: [ServerConnection]
    @Query private var allRecordings: [Recording]

    @State private var selectedTab: AppTab = .liveTV
    /// iPad: the user tapped the stashed mini sliver on Settings to bring it
    /// back out. Cleared on every tab switch so Settings stashes again.
    @State private var settingsMiniPeek = false
    @State private var showSearch = false
    /// Channel-retention status circle (tvOS): observed so the count
    /// circle appears/disappears live as channels are kept or dropped.
    @ObservedObject private var retention = LiveChannelRetention.shared
    #if os(tvOS)
    /// Bottom edge of the Channel Preview banner's art slot: the corner mini
    /// player's bottom is locked to it while the banner is shown.
    @ObservedObject private var guideArtAnchor = GuidePreviewArtAnchor.shared
    #endif
    @State private var retentionListPresented = false
    @State private var retentionActionKey: String?
    /// The per-channel dialog was reached from the channel LIST dialog,
    /// so a Back/Menu dismissal returns to the list instead of closing
    /// the whole flow (Logan 2026-08-27). Explicit choices still close.
    @State private var retentionActionFromList = false
    @State private var retentionActionResolved = false
    @State private var isPlaying = false  // for Movies / TV Shows player state
    /// Tracks whether a VOD detail view is pushed (Movies or Series).
    /// When true, Menu button should pop the navigation, not switch tabs.
    @State private var isVODDetailPushed = false
    #if os(tvOS)
    /// True once the system tab bar has been seen on screen (polled at
    /// launch); the nav circles mount only then so they never take the
    /// launch focus away from the Live TV pill.
    @State private var tvTabBarSeen = false
    @State private var tabFocusSelectTask: Task<Void, Never>?
    @FocusState private var liveTVEntryCatcherFocused: Bool
    /// Any nav circle focused. The Down catcher below the circles exists
    /// only then, so Up from the guide never finds it (trace 13:09).
    @FocusState private var navCirclesFocused: Bool
    #endif
    /// Signal to VOD views to pop their navigation stack.
    @State private var vodNavPopRequested = false
    #if os(tvOS)
    /// Mirrors "is a Settings subview pushed" from SettingsView.
    /// `.onExitCommand` on the outer TabView intercepts Menu before
    /// the inner NavigationStack can pop, so we need to know from
    /// here whether a Settings subview is on top before falling
    /// through to the "switch to Live TV" default.
    @State private var isSettingsSubviewPushed = false
    #if os(tvOS)
    /// Task #254 round 2: incremented by healCollapsedTabBarIfNeeded to
    /// force a TabView remount when the tab bar is detected parked
    /// off-screen after backing out of a tall settings detail page.
    @State private var tvBarHealToken = 0
    #endif
    /// Signal to SettingsView to pop its innermost pushed subview
    /// (classic stack first, then navPath). Reset by SettingsView
    /// after consuming.
    @State private var settingsPopRequested = false
    /// Latched, navigation-safe mirrors of hasFavorites / hasRecordings /
    /// hasVOD for the TabView's conditional tabs. Inserting or removing a
    /// sibling tab while the Settings tab has a sub-page pushed tears down
    /// that NavigationStack (blank sub-page, then dead navigation: the
    /// "can't open Settings submenus while the playlist is syncing" bug, since
    /// these gates flip false->true as VOD / favorites / recordings load).
    /// syncTabVisibility() copies the live values in only when it is safe to
    /// mutate the tab set, so the set never changes underneath an active
    /// Settings navigation; deferred changes apply when the user leaves it.
    @State private var tabShowRecordings = false
    @State private var tabShowMovies = false
    @State private var tabShowSeries = false
    @ObservedObject private var tabBarScrollState = TVTabBarScrollState.shared
    #endif
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    #if os(iOS)
    /// Swipe-started foreground PiP: the docked bar stays hidden while the
    /// video lives in the PiP window.
    @ObservedObject private var foregroundPiP = ForegroundPiPBridge.shared
    #endif
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    /// NOT observed (1.8.40 guide navigation lag): the sweep publishes a
    /// progressive count every 5 s for as long as an uncapped walk takes, and
    /// observing the store here invalidated `MainTabView.body` (and the Live
    /// TV subtree under it) on every one of them. The tab bar's own needs live
    /// on `vodFacts`, which only publishes on a real transition; this
    /// reference stays for the imperative calls and for the initial-sync
    /// cover's title count, neither of which wants a body dependency.
    private let vodStore = VODStore.shared
    /// Keeps the Movies / TV Shows tabs on screen, in a loading state, for
    /// the whole life of a catalog sweep (Android parity, Logan 2026-09-16).
    /// Without this the count drops to 0 at the start of "Refresh
    /// Everything" and the tab vanished until the first page landed. Folded
    /// into `vodFacts` for the same reason as the store above.
    private let sweepActivity = VODSweepActivity.shared
    /// The two tab-gate booleans plus the background-work flags, on an
    /// observable that changes only when one of them really flips.
    @ObservedObject private var vodFacts = VODCatalogFacts.shared
    private var isTVOS: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }
    @ObservedObject private var channelStore = ChannelStore.shared
    /// Watched purely so `hasRecordings` recomputes the moment a capture
    /// starts or stops — the DVR tab has to stay up for an in-flight
    /// recording even when it belongs to a server the user has switched away
    /// from. See `hasRecordings`.
    @ObservedObject private var recordingCoordinator = RecordingCoordinator.shared
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
    #if os(iOS)
    /// GH #33 basic cast: MainTabView owns the local<->remote swap. On
    /// session connect it hands the playing channel to the web receiver and
    /// tears down local playback; while connected it shows the remote-session
    /// card above the tab bar; on session end it just closes (no local
    /// resume, rule 4).
    @ObservedObject private var castController = AerioCastController.shared
    /// GH #33 companion remote: same card for a paired AerioTV TV.
    @ObservedObject private var companionClient = CompanionClient.shared
    /// AirPlay rides the same card (rule 2): the monitor reports when the
    /// AVPlayer engine's output actually moved to an AirPlay receiver.
    @ObservedObject private var airPlay = AirPlayMonitor.shared
    /// Presents the "Control a TV" picker from the floating pill (no channel
    /// needs to be playing on the phone -- act as a pure remote).
    @State private var showCompanionPickerGlobal = false
    /// Rule 3: the remote-controls sheet the session card opens.
    @State private var showRemoteControls = false
    #endif
    @AppStorage("hasCompletedInitialEPG") private var hasCompletedInitialEPG = false
    @State private var showInitialEPGLoading = false
    /// v1.6.23 — set to `true` when the user explicitly Skips the
    /// initial-sync cover so we don't immediately re-present it. The
    /// cover's natural re-show triggers (`onAppear`, `allServers.count`
    /// change) would otherwise fire right after dismissal, making the
    /// Skip button visually do nothing (jesmannstl v1.6.22 report:
    /// "Skip did nothing"). Resets on cold launch — the next session
    /// re-evaluates whether the cover should appear.
    @State private var userDismissedInitialLoading = false
    /// One-shot LAN/WAN failover guard for the channel/EPG orchestrator.
    /// When a channel load comes back empty (server down, or LAN host
    /// unreachable after travelling off the home network), we re-run the
    /// LAN probe once and retry the refresh against the freshly-selected
    /// LAN-or-WAN URL. Reset to false at the very top of
    /// `runChannelServerTaskBody` so each fresh server-key change gets
    /// exactly one attempt.
    @State private var didAttemptGuideFailover = false
    /// Oki's debug log (2026-08-16): true once the orchestrator has run
    /// this session. Every LATER orchestratorKey change debounces 900ms
    /// before firing (SwiftUI cancels the pending task when the key
    /// changes again), so a burst of key changes - each keystroke of a
    /// URL edit that reaches the model, a sync merge rewriting servers -
    /// collapses to ONE reload of the settled value instead of a full
    /// channels + EPG + recordings + VOD run against every intermediate
    /// state. First run stays immediate so cold launch pays nothing.
    @State private var orchestratorRanOnce = false
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
    ///
    /// Dispatcharr 0.30 per-user permissions are folded in for the same
    /// reason: `loadMovies` / `loadSeries` early-return and CLEAR the store
    /// when the account is denied, so a permission that later flips back to
    /// allowed needs a re-fetch to repopulate the library and bring the tab
    /// back. Without these two flags in the key the only recovery was an app
    /// relaunch. Capability changes reach here because the launch / foreground
    /// probe writes them onto the observed `ServerConnection`.
    private var vodServerKey: String {
        allServers
            .map { "\($0.id.uuidString)|\($0.baseURL)|\($0.isActive ? "1" : "0")|\($0.vodEnabled ? "1" : "0")|\($0.supportsVOD ? "1" : "0")|\($0.dispatcharrCanViewVOD ? "1" : "0")|\($0.dispatcharrCanViewSeries ? "1" : "0")" }
            .sorted()
            .joined(separator: ",")
    }

    /// Changes whenever any server changes — used to trigger channel re-fetch.
    /// Includes isActive so switching the active server always re-fires the task.
    /// `credentialGeneration` is part of the key so that replacing a
    /// playlist's credentials re-runs the whole load sequence the way
    /// switching playlists does. Without it, editing a Dispatcharr
    /// playlist from one account to another left every already-loaded
    /// channel, guide, VOD and DVR list in place -- all of it fetched
    /// as, and filtered for, the PREVIOUS account.
    private var channelServerKey: String {
        allServers.map {
            "\($0.id.uuidString)|\($0.baseURL)|\($0.isActive ? "1" : "0")|\($0.credentialGeneration)"
        }
            .sorted()
            .joined(separator: ",")
    }

    /// v1.6.21: combined key driving the unified initial-sync
    /// orchestrator that runs channels, EPG, VOD movies, and VOD
    /// series strictly in order. Re-fires whenever either
    /// `channelServerKey` or `vodServerKey` changes, so a
    /// `vodEnabled` toggle (the only field in `vodServerKey`
    /// that isn't already in `channelServerKey`) still re-runs
    /// the full sequence. See the `task(id:)` comment in the body
    /// modifier chain for the race-condition rationale this
    /// exists to fix. Distinct from `initialSyncKey` lower in
    /// the file, which is a separate signal that gates the
    /// loading-cover dismiss.
    private var orchestratorKey: String {
        "\(channelServerKey)||\(vodServerKey)"
    }

    /// Restart the DVR reconcile loop whenever the set of Dispatcharr
    /// servers (or their identity) changes. The loop itself polls
    /// every 2 minutes internally.
    private var dvrReconcileKey: String {
        // ACTIVE SERVER ONLY (Logan 2026-09-16: inactive server
        // 192.168.50.163 polled every 2 minutes). The key used to name
        // every saved Dispatcharr server, and the poll below walked the
        // same set, so a saved but inactive playlist was hit with
        // GET /api/channels/recordings/ every 2 minutes forever - on
        // Logan's iPhone and Apple TV that was a timeout every cycle.
        activeDispatcharrServers
            // dvr_access is part of the key so a permission that flips back
            // to view/manage re-fires the reconcile at once instead of
            // waiting out the 2-minute poll below.
            .map { "\($0.id.uuidString)|\($0.dispatcharrCanViewDVR ? "1" : "0")" }
            .sorted()
            .joined(separator: ",")
    }

    /// Walks every Dispatcharr server, asks the coordinator to
    /// reconcile its server-side recordings against local SwiftData
    /// rows (status sync + prune + orphan import). Fires from a
    /// tab-bar-level .task so the DVR tab can light up even when the
    /// user hasn't navigated to it yet — `hasRecordings` reads
    /// SwiftData, which the reconciler writes into.
    /// Dispatcharr 0.30 granular permissions: re-read /users/me/ (and the
    /// server version) on every launch so a permission change made on
    /// the server applies without re-adding the playlist. Off the
    /// critical path; a failure leaves the persisted values as they are.
    ///
    /// Policy (Android parity, 2026-09-15):
    ///  - COLD LAUNCH always probes, ignoring the ~6 hour TTL. A snapshot
    ///    younger than the TTL used to short-circuit the launch pass, so a
    ///    permission change made on the server could NOT be picked up by
    ///    force quitting and reopening the app, which is exactly what a
    ///    user (and an admin) tries first. One probe per server per launch
    ///    (`needsLaunchProbe`), plus the probe's own in-flight dedupe.
    ///  - The softer triggers stay TTL gated: foreground return and the
    ///    opportunistic DVR / On Demand entry checks.
    ///  - Server creation, Test Connection and manual refresh force.
    /// A failed probe always keeps the last good snapshot.
    private func refreshDispatcharrPermissions(reason: String = "cold launch",
                                               isColdLaunch: Bool = true,
                                               force: Bool = false) {
        // ACTIVE PLAYLIST ONLY (Logan 2026-09-16, Android parity). This used
        // to walk every saved Dispatcharr server with a 3-attempt retry
        // ladder each, so one inactive, unreachable saved playlist delayed
        // the active server's probe by up to ~18 s and filled the log with
        // "[PERMS] probe FAILED server=..." for a playlist nobody is using.
        // A server that is not active gates nothing on this device, and the
        // orchestrator key includes isActive, so switching to it re-fires
        // this pass and `needsLaunchProbe` lets it through once. Targeted
        // paths are untouched: Test Connection, server creation, credential
        // change, and the opportunistic DVR / On Demand refreshIfStale all
        // probe their own specific server directly.
        let dispatcharrServers = activeDispatcharrServers
        guard !dispatcharrServers.isEmpty else { return }
        Task { @MainActor in
            for server in dispatcharrServers {
                // RETRY rather than discard. The old code fired once and,
                // on any transport hiccup, left the device gating on
                // whatever stale (or absent) snapshot it happened to have
                // until the next cold launch. Three attempts with a short
                // backoff costs one request in the healthy case.
                // ACTIVE-SERVER CHANGE FORCES A PROBE (Logan 2026-09-16).
                // Switching the active playlist must re-probe the newly
                // active server exactly the way a cold launch does: ignore
                // the ~6 hour TTL AND ignore `launchProbed`. Without this,
                // a permission changed on server B while server A was
                // active was not picked up until the next relaunch, because
                // B was already in `launchProbed` from an earlier pass.
                let activeChanged = DispatcharrCapabilityProbe.needsActiveServerProbe(server)
                let mustProbe = force || activeChanged
                if mustProbe {
                    // Count it as this launch's probe too, so the cold-launch
                    // pass does not immediately repeat the same request.
                    DispatcharrCapabilityProbe.noteLaunchProbed(server)
                } else if isColdLaunch {
                    // Unconditional, TTL ignored, but only once per server
                    // per process: the launch orchestrator can re-fire on a
                    // server-key change within the same launch.
                    guard DispatcharrCapabilityProbe.needsLaunchProbe(server) else { continue }
                    DispatcharrCapabilityProbe.noteLaunchProbed(server)
                } else {
                    guard server.dispatcharrCapabilities.isStale else { continue }
                }
                DispatcharrCapabilityProbe.noteActiveServerProbed(server)
                var reached = false
                for attempt in 1...3 {
                    reached = await DispatcharrCapabilityProbe.refresh(server, reason: "\(reason) #\(attempt)")
                    if reached { break }
                    try? await Task.sleep(for: .seconds(attempt * 3))
                }
                if !reached {
                    debugLog("[PERMS] probe FAILED server=\(server.name) reason=\(reason) "
                             + "detail=unresolved-after-retries; keeping the last good snapshot "
                             + "(\(server.dispatcharrCapabilities.probeSummary))")
                }
                // Publish unconditionally after an active-server change
                // (Logan 2026-09-16). `DispatcharrCapabilityProbe.refresh`
                // only posts when THAT server's stored snapshot changed, but
                // the thing that changed here is WHICH server is active, so
                // the Movies / TV Shows tab-visibility observers must
                // re-evaluate against the new server's permissions without a
                // relaunch.
                if activeChanged || force {
                    NotificationCenter.default.post(name: .dispatcharrCapabilitiesDidChange, object: nil)
                }
            }
            // Capabilities are synced, so a device that just repaired a
            // wrong snapshot shares the good one.
            SyncManager.shared.pushServers(allServers)
        }
    }

    // Cast audio, 2026-09-13: the launch / foreground re-resolve of the
    // Dispatcharr AAC output profile is GONE. Cast sessions ingest the plain
    // stream and AC-3 / E-AC-3 passes through to the receiver, so there is no
    // server-side profile to keep in sync.

    /// The Dispatcharr server this device is actually using: the active
    /// one, or - when nothing is marked active at all - the first saved
    /// one, so a freshly imported list still works.
    ///
    /// ACTIVE ONLY (Logan 2026-09-16: inactive server 192.168.50.163
    /// polled every 2 minutes). An inactive playlist gates nothing on
    /// this device, so no periodic or launch-time fetch may touch it.
    private var activeDispatcharrServers: [ServerConnection] {
        if let active = allServers.first(where: { $0.isActive && $0.type == .dispatcharrAPI }) {
            return [active]
        }
        // No server is marked active at all: fall back to the first saved
        // Dispatcharr server rather than going silent.
        guard allServers.allSatisfy({ !$0.isActive }),
              let first = allServers.first(where: { $0.type == .dispatcharrAPI }) else { return [] }
        return [first]
    }

    private func reconcileAllDispatcharrRecordings() async {
        // ACTIVE SERVER ONLY (Logan 2026-09-16: inactive server
        // 192.168.50.163 polled every 2 minutes). DVR access "none": the
        // recordings endpoints answer 403; skip.
        let dispatcharrServers = activeDispatcharrServers.filter { $0.dispatcharrCanViewDVR }
        guard !dispatcharrServers.isEmpty else { return }
        for server in dispatcharrServers {
            let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                     auth: .apiKey(server.effectiveApiKey),
                                     userAgent: server.effectiveUserAgent,
                                     authMode: server.dispatcharrHeaderMode)
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
            // Cached count, not a scan: `loadingStages` is evaluated from the
            // initial-sync cover's body (2026-09-12 render-path fix).
            let programCount = guideStore.loadedProgramCount
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
        // Permission- and toggle-gated the same way Edit Playlist > Save
        // gates its Movies / TV Shows rows (2026-09-18): the row is not a
        // claim that a library is loading when On Demand is off for the
        // playlist, or when the Direct Connect account may view neither
        // movies nor series.
        let hasVODServer = allServers.contains { server in
            guard server.supportsVOD, server.vodEnabled else { return false }
            guard server.type == .dispatcharrAPI else { return true }
            return server.dispatcharrCanViewVOD || server.dispatcharrCanViewSeries
        }
        var vodStage = SyncStage(id: "vod", label: "Loading VOD")
        if !hasVODServer {
            vodStage.status = .done(
                allServers.contains { $0.supportsVOD } ? "Not available for this account"
                                                       : "No VOD on this source")
        } else if vodFacts.isLoadingMovies || vodFacts.isLoadingSeries {
            vodStage.status = .loading
        } else {
            // A plain read, not an observation: this stage is only on screen
            // during the initial sync cover, which re-renders on the channel
            // and guide stages anyway, and the count is settled by the time
            // the stage stops saying "loading".
            let titles = vodStore.moviesCount + vodStore.seriesCount
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
        // v1.6.23: don't re-present after the user explicitly Skipped.
        // Without this gate, dismissing via the Skip button is visually
        // a no-op when a downstream onChange (e.g. allServers.count
        // settling after iCloud sync, or another tryShow trigger
        // during the same session) fires immediately after.
        guard !userDismissedInitialLoading else {
            debugLog("🔶 Initial sync — user dismissed this session, not re-showing")
            return
        }
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

    /// Issue #24: the sync orchestrator only runs on cold launch / server
    /// change (`.task(id: orchestratorKey)`), so opening the app after it
    /// sat backgrounded for hours left the guide stale and never refreshed
    /// (only force-quitting, which forces a cold relaunch, re-synced). On
    /// foreground, if the loaded EPG is older than the staleness window,
    /// kick the same channels + guide refresh that pull-to-refresh uses
    /// (`forceRefresh`, which deliberately does NOT re-pull VOD). Gated on
    /// staleness so ordinary app-switching doesn't refetch every time.
    /// See the `.task` at the wiring site. A named function, not an
    /// inline closure: the modifier chain there is at the Release-mode
    /// type-checker's budget in Xcode 26 (archive-blocking timeout).
    @Sendable private func runPeriodicGuideStalenessSweep() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            // Never refresh under active playback: the tester's 2026-08-31
            // jetsam died seconds after this sweep fired an 8MB grid fetch +
            // 7.8k-programme XMLTV parse WHILE a 20Mbps MKV remux was
            // scrubbing. The guide can be 5 minutes staler; a dead player
            // cannot. Same policy as Android's PlaylistRefreshWorker gate.
            if scenePhase == .active, PlayerSession.shared.mode == .idle {
                refreshGuideIfStale(reason: "periodic sweep")
            }
            if scenePhase == .active {
                // Cheap (one request, throttled to 15 minutes inside
                // GuideStore) and safe under playback: it only GATES a
                // background re-sweep that pauses itself during a tune.
                checkEPGSourcesForChanges(reason: "periodic sweep")
            }
        }
    }

    /// When the app last left the foreground, for the permission re-probe.
    private static var backgroundedAt: Date?
    /// Away this long and the next foreground re-reads permissions.
    private static let foregroundReprobeSeconds: TimeInterval = 60

    private func refreshGuideIfStaleOnForeground(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase != .active { Self.backgroundedAt = Date() }
        guard oldPhase != .active, newPhase == .active else { return }
        // Away longer than a minute: re-read permissions for real rather than
        // letting the staleness gate hold an answer from hours ago. Matches
        // Android's foreground re-probe window.
        let awayLongEnough = Self.backgroundedAt.map {
            Date().timeIntervalSince($0) >= Self.foregroundReprobeSeconds
        } ?? false
        // Independent of the guide staleness gate below: one cheap request,
        // throttled to 15 minutes per server.
        refreshGuideIfStale(reason: "foreground")
        checkEPGSourcesForChanges(reason: "foreground")
        // Foreground after a while: re-read the per-user capability
        // snapshot so a permission the admin changed while the app was
        // backgrounded applies without a cold launch. Staleness-gated
        // (about 6 hours), so a quick app switch costs nothing.
        refreshDispatcharrPermissions(reason: "foreground", isColdLaunch: false, force: awayLongEnough)
        // Restart the settle window, then queue the quiet VOD sweep behind it
        // (it starts ~20 s from here, once the guide is painted and any tune is
        // past first frame). The DVR poll keeps its own cadence.
        AppSettleGate.shared.noteForegroundReturn()
        vodStore.scheduleBackgroundSweep(servers: allServers, reason: "foreground")
    }

    /// Dispatcharr EPG source gate (Logan 2026-09-12). Logan re-ingests his EPG
    /// sources every few hours, so a changed source must NOT cost the user a
    /// foreground reload: the guide keeps serving the cached chunks and a quiet
    /// background re-sweep replaces one day at a time. Every 15 minutes while
    /// active (the throttle lives in GuideStore, so the 5-minute sweep calling
    /// this is free) and on the foreground edge.
    private func checkEPGSourcesForChanges(reason: String) {
        guard let server = allServers.first(where: { $0.isActive }) ?? allServers.first else { return }
        // Never race a cold-launch / server-change sync; that path runs its own
        // gate check at the end of its grid walk.
        guard !channelStore.isLoading, !channelStore.isEPGLoading else { return }
        let channels = channelStore.channels
        Task { @MainActor in
            await GuideStore.shared.considerBackgroundGridSweep(server: server,
                                                               channels: channels,
                                                               reason: reason)
        }
    }

    /// Shared staleness gate for the foreground edge AND the 5-minute
    /// always-active sweep (see the `.task` at the wiring site).
    private func refreshGuideIfStale(reason: String) {
        guard !allServers.isEmpty else { return }
        // Don't pile on top of an in-flight cold-launch / server-change sync.
        guard !channelStore.isLoading, !channelStore.isEPGLoading else { return }
        // 30 minutes: long enough that normal app-switching never refetches,
        // short enough that "opened it after a few hours" always lands fresh.
        let staleAfter: TimeInterval = 30 * 60
        guard GuideStore.shared.isEPGStale(olderThan: staleAfter) else { return }
        debugLog("🔄 Guide refresh (\(reason)): EPG stale (>\(Int(staleAfter / 60))m old) — forcing channels + guide refresh")
        let servers = allServers
        let ctx = modelContext
        Task { await channelStore.forceRefresh(servers: servers, modelContext: ctx) }
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
            || vodFacts.isLoadingMovies || vodFacts.isLoadingSeries
            || vodFacts.isRefillingMovies || vodFacts.isRefillingSeries
            || vodFacts.isSearchingMovies || vodFacts.isSearchingSeries
    }

    /// Short identifier labels used by the heartbeat log. Terse
    /// by design — the log consumer needs grep-friendly tokens.
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

    var body: some View {
        let _ = TabProbe.body("MainTabView")
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

            // The "Syncing | Tap for Info" pill is gone (Logan
            // 2026-09-14). tvOS already spins the nav bar's Refresh
            // circle while a sync runs; iPhone / iPad show a small
            // spinning refresh glyph in the Live TV header
            // (`PhoneHeaderSyncSpinner`), with pull-to-refresh still the
            // manual trigger.

            // Nav action circles: Refresh + Search immediately LEFT of the
            // system tab bar, on every content tab (hidden on Settings) —
            // matching Android TV's TvTopTabBar, which was itself built to
            // this design. Placement ruling (Logan 2026-08-12): these live
            // beside the nav bar, NOT in the Live TV filter row, and do not
            // depend on the guide's sidebar-vs-pills mode. The old global-
            // search toolbar item stopped rendering here when the tab
            // hierarchy changed; this overlay replaces it on tvOS (iOS keeps
            // the toolbar item). Refresh is the TV stand-in for
            // pull-to-refresh: re-fetches channels + EPG without a trip
            // through Settings.
            // A pushed VOD detail hides the tab bar (VODDetailView's
            // .toolbar(.hidden, for: .tabBar)), but these circles are an
            // overlay OUTSIDE the TabView, so that hide never reached them:
            // they kept drawing at zIndex 2 over the detail page and stayed
            // focusable through their own focusSection. Gate on the same
            // isDetailPushed flag OnDemandView already uses to drop its
            // Movies/Series pill row.
            #if os(tvOS)
            if selectedTab != .settings && !isVODDetailPushed
                && !tabBarScrollState.isHidden
                && (!nowPlaying.isActive || nowPlaying.isMinimized) {
                GeometryReader { geo in
                    // Centered-bar estimate: ~230pt per tab, deliberately
                    // WIDE so the circles sit shy of the bar's real edge
                    // rather than under it.
                    let visibleTabs = 2
                        + (showRecordingsTab ? 1 : 0)
                        + (showMoviesTab ? 1 : 0)
                        + (showSeriesTab ? 1 : 0)
                    let barLeading = (geo.size.width - CGFloat(visibleTabs) * 230) / 2
                    VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) {
                        // Refresh and Search are Live TV only (Logan
                        // 2026-09-03): the other tabs carry their own.
                        // Not before the tab bar exists: at launch the
                        // circles were the only focusable thing and took
                        // the default focus (Logan 2026-09-05).
                        if selectedTab == .liveTV && tvTabBarSeen {
                            TVNavActionCircle(
                                systemImage: "arrow.clockwise",
                                label: "Refresh channels and guide",
                                spinning: isAnyBackgroundWork
                            ) {
                                let servers = allServers
                                let ctx = modelContext
                                Task {
                                    await channelStore.forceRefresh(servers: servers,
                                                                    modelContext: ctx)
                                }
                            }
                            TVNavActionCircle(
                                systemImage: "magnifyingglass",
                                label: "Search",
                                isSelected: showSearch
                            ) {
                                withAnimation(.easeOut(duration: 0.2)) { showSearch.toggle() }
                            }
                        }
                        // Channel retention status (Logan 2026-08-27): a
                        // count circle appears while flipped-away channels
                        // are still ingesting upstream, so background
                        // provider connections are always one glance -
                        // and one click - from being cancelled.
                        if !retention.entries.isEmpty {
                            TVNavActionCircle(
                                systemImage: "\(min(retention.entries.count, 5)).circle",
                                label: "Channels kept live in background"
                            ) {
                                if retention.entries.count == 1 {
                                    retentionActionFromList = false
                                    retentionActionKey = retention.entries[0].key
                                } else {
                                    retentionListPresented = true
                                }
                            }
                        }
                    }
                    .focused($navCirclesFocused)
                    // Down from the circles: the guide's entry point (banner
                    // description or first channel), not the Live TV pill
                    // beside them (Logan 2026-09-05).
                    if selectedTab == .liveTV && tvTabBarSeen
                        && (navCirclesFocused || liveTVEntryCatcherFocused) {
                        Color.clear
                            .frame(width: 140, height: 10)
                            .focusable(true)
                            .focused($liveTVEntryCatcherFocused)
                            .onChange(of: liveTVEntryCatcherFocused) { _, focused in
                                guard focused else { return }
                                NotificationCenter.default.post(name: .aerioLiveTVEntryFromTop, object: nil)
                            }
                    }
                    }
                    .confirmationDialog(
                        "Channels Live in Background",
                        isPresented: $retentionListPresented,
                        titleVisibility: .visible
                    ) {
                        ForEach(retention.entries, id: \.key) { entry in
                            Button(entry.channelName) {
                                // Beat between dialogs: presenting the
                                // per-channel dialog in the same runloop
                                // turn as this one's dismissal drops it.
                                let key = entry.key
                                retentionActionFromList = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    retentionActionKey = key
                                }
                            }
                        }
                        Button("Stop All", role: .destructive) {
                            LiveChannelRetention.shared.stopAll(reason: "user (status circle)")
                        }
                        Button("Close", role: .cancel) {}
                    } message: {
                        Text("These channels keep buffering for Live Rewind and each holds a stream connection.")
                    }
                    .confirmationDialog(
                        retention.entries.first(where: { $0.key == retentionActionKey })?.channelName ?? "Channel",
                        isPresented: Binding(
                            get: { retentionActionKey != nil },
                            set: { presented in
                                guard !presented else { return }
                                let dismissedWithoutChoice = retentionActionKey != nil && !retentionActionResolved
                                retentionActionKey = nil
                                retentionActionResolved = false
                                if dismissedWithoutChoice, retentionActionFromList,
                                   !retention.entries.isEmpty {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        retentionListPresented = true
                                    }
                                }
                            }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button {
                            guard let key = retentionActionKey,
                                  let entry = retention.entries.first(where: { $0.key == key }) else { return }
                            retentionActionResolved = true
                            retentionActionKey = nil
                            DebugLogger.shared.log(
                                "[AVP-RETAIN] status circle: jump to '\(entry.channelName)'",
                                category: "Playback", level: .info)
                            NotificationCenter.default.post(
                                name: .aerioOpenChannel, object: nil,
                                userInfo: ["channelID": entry.channelID])
                        } label: {
                            Label("Jump to Channel", systemImage: "play.tv")
                        }
                        Button(role: .destructive) {
                            guard let key = retentionActionKey else { return }
                            retentionActionResolved = true
                            retentionActionKey = nil
                            DebugLogger.shared.log(
                                "[AVP-RETAIN] status circle: cancel retained channel",
                                category: "Playback", level: .info)
                            LiveChannelRetention.shared.drop(key: key)
                        } label: {
                            Label("Stop Playback", systemImage: "xmark.circle")
                        }

                    }
                    // Own focus region beside the tab bar: LEFT from the
                    // first tab pill (or up-and-left from content) reaches
                    // them; grid navigation never lands here by accident.
                    .focusSection()
                    // 152 fits the two standing circles; the retention
                    // circle adds its 60pt + 16pt spacing so the row grows
                    // LEFT instead of overlapping the tab bar (screenshot,
                    // 2026-08-27).
                    // 76pt per circle (60 + 16 spacing) so the row hugs the
                    // bar however many circles are showing; Search only
                    // shows on Live TV.
                    .padding(.leading, max(16, barLeading
                        - (selectedTab == .liveTV ? 152 : 0)
                        - (retention.entries.isEmpty ? 0 : 76)))
                    // Mirror-measured against the system tab bar: at .top 2 the
                    // circle centers sat ~12pt below the capsule's center line
                    // (Logan: "not centered vertically with the nav bar").
                    .padding(.top, -10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .zIndex(2)
            }
            #endif

            // In-place Search screen (tvOS): covers the tab content while the
            // nav bar + action circles stay visible in the band above, exactly
            // like Android TV's Search screen. zIndex between the hints and
            // the circles so the circles remain interactive on top.
            #if os(tvOS)
            if showSearch {
                VStack(spacing: 0) {
                    // Transparent band: the system tab bar and the action
                    // circles show through here. 106 tucks the search surface
                    // right under the bar so nothing of the tab content (the
                    // guide's pill row) can peek through the seam.
                    Color.clear.frame(height: 106)
                    SearchView(embedsInTabChrome: true, onClose: { showSearch = false })
                        .background(Color.appBackground)
                }
                .focusSection()
                .zIndex(1.7)
                .transition(.opacity)
            }
            #endif

            // The tvOS Menu/Back hint pills were removed (Logan 2026-09-05).

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
            // Rules 1 and 3 (Logan 2026-09-12): connecting a remote transport
            // no longer mounts ANYTHING full screen here. The old
            // RemoteControlScreen covers (cast + companion) and the
            // CastChannelPickCover are deleted; the user stays on the page
            // they were on, a RemoteSessionCard appears above the tab bar
            // (safeAreaInset below), and tapping it opens the applicable
            // remote controls in a sheet.
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
                // Settings tab: the mini stashes at the trailing edge.
                let stashed = minimized && selectedTab == .settings
                GeometryReader { geo in
                    let miniW: CGFloat = 410
                    let miniH: CGFloat = 231
                    // Mini bottom = the Channel Preview banner's art slot
                    // bottom (Streamer parity). 87 is the fallback for when
                    // the banner is not on screen / not yet measured; it was
                    // the old hard-coded inset that only lined up with the
                    // art's former fixed 360x203 frame.
                    let miniTop: CGFloat = guideArtAnchor.bottomAbs > 0
                        ? max(0, guideArtAnchor.bottomAbs - miniH)
                        : 87
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
                            .padding(.top, minimized ? miniTop : 0)
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
                    .animation(.spring(response: 0.35), value: miniTop)
                    .modifier(MiniPlayerSettingsStash(stashed: stashed, travel: miniW + 40 - MiniPlayerSettingsStash.sliver))
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
                    // Settings tab: the mini stashes at the trailing edge.
                    let stashed = minimized && selectedTab == .settings
                    let miniW: CGFloat = 410
                    let miniH: CGFloat = 231
                    // Mini bottom = the Channel Preview banner's art slot
                    // bottom (Streamer parity). 87 is the fallback for when
                    // the banner is not on screen / not yet measured; it was
                    // the old hard-coded inset that only lined up with the
                    // art's former fixed 360x203 frame.
                    let miniTop: CGFloat = guideArtAnchor.bottomAbs > 0
                        ? max(0, guideArtAnchor.bottomAbs - miniH)
                        : 87

                    ZStack(alignment: .topTrailing) {
                        PlayerView(
                            urls: item.streamURLs,
                            title: item.name,
                            headers: nowPlaying.playingHeaders,
                            isLive: nowPlaying.isLive,
                            subtitle: item.currentProgram,
                            subtitleStart: item.currentProgramStart,
                            subtitleEnd: item.currentProgramEnd,
                            programSubtitle: PlayerInfoCardSettings.liveEpisodeTitle(forChannelID: item.id),
                            programDescription: PlayerInfoCardSettings.liveSynopsis(
                                forChannelID: item.id,
                                itemDescription: item.currentProgramDescription),
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
                        // Bottom edge locked to the banner's art slot; the
                        // fallback clears the tab bar (Logan 2026-09-05).
                        .padding(.top, minimized ? miniTop : 0)
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
                    .animation(.spring(response: 0.35), value: miniTop)
                    .modifier(MiniPlayerSettingsStash(stashed: stashed, travel: miniW + 40 - MiniPlayerSettingsStash.sliver))
                    // Stashed sliver must never take Settings focus.
                    .disabled(stashed)
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
        // GH #33: round floating "Control a TV" button above the right end of
        // the tab bar -- appears the moment a controllable AerioTV TV is
        // discovered so the phone can act as a remote without opening a
        // channel first. Hidden while the full-screen player is up (the
        // in-player Control-a-TV button owns that surface) and while already
        // controlling / casting (their covers take over).
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            // The remote-session card above the tab bar owns re-entry now
            // (rule 2), so the old "Controlling <TV>" floating pill is gone.
            if !companionClient.devices.isEmpty || castController.state != .unavailable,
               !companionClient.isControlling,
               !castController.isCasting,
               !airPlay.hostsHeadless,
               nowPlaying.playingItem == nil || nowPlaying.isMinimized,
               // Container sessions (VOD/DVR/live via PlayerSession) never
               // set nowPlaying.playingItem, so the FAB floated over the
               // fullscreen player (field find 2026-08-26, "rogue cast
               // button"). Gate on the session mode too.
               playerSession.mode == .idle || nowPlaying.isMinimized {
                CompanionControlFABDock { showCompanionPickerGlobal = true }
            }
        }
        .overlay(alignment: .bottomLeading) {
            MinimizedTabButton(tab: selectedTab)
        }
        // AirPlay handoff (device test 2026-09-25): the receiver took the
        // channel, the fullscreen player was minimized, so land on Live TV
        // with the remote-session card driving the session (Cast parity).
        .onChange(of: airPlay.hostsHeadless) { _, headless in
            guard headless, selectedTab != .liveTV else { return }
            selectedTab = .liveTV
        }
        #endif
        // safeAreaInset on the outer ZStack pushes the entire TabView (including its tab bar)
        // upward so the tab bar sits above the mini player bar and remains tappable.
        //
        // 2026-09-12: that claim does NOT hold for the cast card. The iOS 26/27
        // TabView is UITabBarController-backed and lays its UITabBar at the
        // bottom of its OWN bounds, and every tab's scroll view carries
        // `ignoresSafeArea(.container, edges: .bottom)` (GH #20 follow-up), so
        // an inset added out here reserved nothing either the bar or the lists
        // respected: the card rendered ON TOP of the tab labels (Logan's
        // iPhone, iOS 27). The card is now an overlay lifted by the MEASURED
        // tab bar height instead (see RemoteSessionCardDock). The mini player
        // bar keeps the inset: it is mutually exclusive with the card (rule 5)
        // and its long-standing geometry is not part of this change.
        #if os(iOS)
        // The iPhone docked MiniPlayerBar inset lived here; removed with the
        // docked bar itself (Logan 2026-09-14): iPhone minimize is
        // foreground PiP only (ForegroundPiPBridge).
        // Rule 2 (Logan 2026-09-12): ONE small card ABOVE the bottom nav bar on
        // every tab while a Google Cast, AirPlay or companion session is live.
        // Tap opens the remote controls sheet (rule 3); the X ends the session
        // and just closes (rule 4). Styled off the Android CastTransportCard /
        // CastMiniController. The dock pins it 8 pt above the measured tab bar,
        // 12 pt in from both screen edges, and publishes its height so the tabs
        // can scroll their last row clear of it.
        .overlay(alignment: .bottom) {
            RemoteSessionCardDock { remoteSessionCard }
        }
        // Task #225 follow-up: the global pill used to open the companion-ONLY
        // CompanionPickerSheet, which has no Google Cast section and never
        // starts Cast discovery, so Cast devices could never appear outside the
        // in-player chrome (Logan's iPhone 17 Pro, 2026-09-11: "AerioTV devices"
        // only while the Nothing Phone saw 11 Cast routes). Use the unified
        // sectioned picker instead. No channel is playing from here, so the
        // AirPlay section (an AVPlayer-session affordance) stays off.
        .sheet(isPresented: $showCompanionPickerGlobal) {
            // AirPlay row too (2026-09-21 rebuild): picking a TV here puts
            // the card in its "Select a channel" idle-route state.
            CastPickerSheet(showGoogleCast: true, showAirPlay: true)
        }
        // Rule 3: "tapping the cast card brings up applicable remote controls
        // in a new window" -- a sheet, NOT a full-screen cover. Same
        // RemoteControlScreen content the deleted covers used, so every
        // transport keeps its transport buttons, channel up/down and the
        // Options it supports (tracks / speed / stream info / Switch Stream /
        // sleep timer), plus Disconnect.
        .sheet(isPresented: $showRemoteControls) {
            remoteControlsSheet
        }
        // The session ending (card X, TV death, sleep timer) must take the
        // sheet with it -- rule 4 means nothing is left behind to control.
        .onChange(of: activeRemoteTransport) { _, transport in
            if transport == nil { showRemoteControls = false }
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
        // aerio://settings/<page> -> select the Settings tab. SettingsView
        // itself drives the navigation once it is mounted. This sits on the
        // outer body, not on `tabContentView`: one more modifier on that
        // chain tips the tvOS type-checker budget.
        .onReceive(NotificationCenter.default.publisher(for: .aerioOpenSettingsPage)) { _ in
            selectSettingsTabForDeepLink()
        }
    }

    #if os(iOS)
    // MARK: - Remote session card + controls sheet (Logan 2026-09-12)

    /// Which transport, if any, owns the phone's playback right now. Cast wins
    /// over companion (they are already mutually exclusive), and AirPlay is
    /// last because it is the only one that keeps a local AVPlayer alive.
    private var activeRemoteTransport: RemoteSessionCard.Transport? {
        if castController.isCasting { return .cast }
        if companionClient.isControlling { return .companion }
        switch airPlay.phase {
        case .probing, .idleRoute, .active: return .airPlay
        default: return airPlay.isExternal ? .airPlay : nil
        }
    }

    /// "AirPlay to <receiver>" (Cast's "Casting to <device>" wording),
    /// plain "AirPlay" until the receiver name resolves.
    private var airPlayPlayingStatus: String {
        airPlay.deviceName.map { "AirPlay to \($0)" } ?? "AirPlay"
    }

    private var airPlayIsIdleRoute: Bool {
        if case .idleRoute = airPlay.phase { return true }
        return false
    }

    private var airPlayIsProbing: Bool {
        if case .probing = airPlay.phase { return true }
        return false
    }

    @ViewBuilder
    private var remoteSessionCard: some View {
        switch activeRemoteTransport {
        case .cast:
            let device = castController.connectedDeviceName ?? "TV"
            let content = castController.castingContent
            RemoteSessionCard(
                transport: .cast,
                // Rule 1: a session connected with nothing playing reads as
                // the invitation, not as a channel.
                title: content?.title ?? "Casting to \(device)",
                // A web-receiver channel flip replaces this with
                // "Switching to <channel>" until the receiver plays.
                status: content == nil ? "Select a Channel"
                    : castController.castStatusLine(deviceName: device),
                artURL: content?.artURL,
                isPlaying: castController.remoteIsPlaying,
                // Android parity: no transport button until something plays.
                showTransport: content != nil,
                onTap: { showRemoteControls = true },
                onTogglePlayPause: { castController.remoteTogglePlayPause() },
                // X = stop playback on the TV AND close the card.
                onStop: {
                    debugLog("[Remote] X: stop + close")
                    castController.stopCasting()
                }
            )
        case .companion:
            let device = companionClient.connectedTVName ?? "TV"
            RemoteSessionCard(
                transport: .companion,
                title: companionClient.nowPlaying.isEmpty
                    ? "Controlling \(device)" : companionClient.nowPlaying,
                status: companionClient.nowPlaying.isEmpty
                    ? "Select a Channel" : "Controlling \(device)",
                isPlaying: companionClient.remoteIsPlaying,
                showTransport: !companionClient.nowPlaying.isEmpty,
                onTap: { showRemoteControls = true },
                onTogglePlayPause: { companionClient.togglePlayPause() },
                // X = stop playback on the TV AND close the card, same as the
                // other two transports. "Disconnect" (leave the TV playing)
                // lives in the controls sheet.
                onStop: { companionClient.stopPlaybackAndDisconnect() }
            )
        case .airPlay:
            let item = nowPlaying.playingItem
            if airPlayIsIdleRoute {
                // Route picked, nothing playing: the invitation state.
                RemoteSessionCard(
                    transport: .airPlay,
                    title: airPlayPlayingStatus,
                    status: "Select a Channel",
                    isPlaying: false,
                    showTransport: false,
                    onTap: { showRemoteControls = true },
                    onTogglePlayPause: {},
                    onStop: {
                        // An app cannot drop the route: X presents the
                        // system route picker (disconnectIdleRoute).
                        debugLog("[Remote] X: disconnect (AirPlay idle route)")
                        airPlay.disconnectIdleRoute()
                    }
                )
            } else {
                let probing = airPlayIsProbing
                RemoteSessionCard(
                    transport: .airPlay,
                    title: item?.name ?? "AirPlay",
                    status: probing ? "Connecting to AirPlay" : airPlayPlayingStatus,
                    artURL: item?.logoURL?.absoluteString,
                    isPlaying: airPlay.isPlaying,
                    // Nothing to pause until the receiver has the video.
                    showTransport: !probing,
                    onTap: { showRemoteControls = true },
                    onTogglePlayPause: { airPlay.togglePlayPause() },
                    // X = stop playback on the TV AND close the card.
                    onStop: {
                        debugLog("[Remote] X: stop + close")
                        airPlay.stop()
                    }
                )
            }
        case nil:
            EmptyView()
        }
    }

    /// Rule 3: the SAME RemoteControlScreen the deleted covers used, now in a
    /// sheet. Each transport passes the options surface it actually supports.
    @ViewBuilder
    private var remoteControlsSheet: some View {
        switch activeRemoteTransport {
        case .cast:
            // 2026-09-21 production recording: the shared Cast/AirPlay sheet.
            // A session with nothing loaded is the idle Close / Connected
            // state; a web-receiver flip keeps the playing layout.
            let content = castController.castingContent
            let item = content.flatMap { c in
                ChannelStore.shared.channels.first(where: { $0.id == c.mediaID })
            }
            RemoteSessionSheet(
                transport: .cast,
                mode: content == nil ? .idleRoute : .playing,
                channelName: content?.title
                    ?? "Casting to \(castController.connectedDeviceName ?? "TV")",
                statusText: castController.castStatusLine(
                    deviceName: castController.connectedDeviceName ?? "TV"),
                artURL: content?.artURL,
                channelID: content?.mediaID,
                fallbackSubtitle: content?.subtitle,
                isPlaying: castController.remoteIsPlaying,
                item: item,
                onTogglePlayPause: { castController.remoteTogglePlayPause() },
                onChannelUp: { castController.castChannel(1) },
                onChannelDown: { castController.castChannel(-1) },
                onSeek: { castController.remoteSeek(by: $0) },
                onStop: {
                    castController.stopCasting()
                    showRemoteControls = false
                }
            )
        case .companion:
            RemoteControlScreen(
                title: companionClient.nowPlaying,
                subtitle: nil,
                artURL: nil,
                statusText: "Controlling \(companionClient.connectedTVName ?? "TV")",
                isPlaying: companionClient.remoteIsPlaying,
                stopLabel: "Stop and close",
                onTogglePlayPause: { companionClient.togglePlayPause() },
                onChannelUp: { companionClient.flipChannel(1) },
                onChannelDown: { companionClient.flipChannel(-1) },
                // Same semantic as the card's X: stop the TV, then close.
                onStop: {
                    companionClient.stopPlaybackAndDisconnect()
                    showRemoteControls = false
                },
                // Companion-only: drop the link, TV keeps playing.
                onDisconnect: {
                    companionClient.disconnectLeavingTVPlaying()
                    showRemoteControls = false
                },
                companion: companionClient  // full options (scrubber + sheet)
            )
        case .airPlay:
            // Production Cast parity (device recording 2026-09-25): idle
            // route = Close / Connected only (the card's X opens the route
            // picker); probing = the playing layout with controls disabled
            // until the receiver has the video.
            let item = nowPlaying.playingItem
            RemoteSessionSheet(
                transport: .airPlay,
                mode: airPlayIsIdleRoute ? .idleRoute
                    : (airPlayIsProbing ? .connecting : .playing),
                channelName: item?.name ?? "AirPlay",
                statusText: airPlayIsProbing ? "Connecting to AirPlay" : airPlayPlayingStatus,
                artURL: item?.logoURL?.absoluteString,
                channelID: item?.id,
                fallbackSubtitle: nil,
                isPlaying: airPlay.isPlaying,
                item: item,
                onTogglePlayPause: { airPlay.togglePlayPause() },
                onChannelUp: { nowPlaying.changeChannel(direction: 1) },
                onChannelDown: { nowPlaying.changeChannel(direction: -1) },
                onSeek: { airPlay.seek(by: $0) },
                onStop: {
                    airPlay.stop()
                    showRemoteControls = false
                }
            )
        case nil:
            EmptyView()
        }
    }
    #endif

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
    ///
    /// One exception to the per-server scope: a capture that is CURRENTLY
    /// running keeps the tab up no matter which server is active. The
    /// per-server filter is right for stored rows, but a local recording
    /// outlives a playlist switch — the capture keeps writing in the
    /// background — and scoping it away hid the only UI that can show or stop
    /// it, and bounced the user off the tab mid-recording (the `.onChange(of:
    /// hasRecordings)` redirect below). Android already ORs its live recorder
    /// state in the same way (`LocalRecordingService.activeRecording`).
    private var hasRecordings: Bool {
        if recordingCoordinator.isRecording { return true }
        guard let active = allServers.first(where: { $0.isActive }) ?? allServers.first else {
            return false
        }
        let sid = active.id.uuidString
        // DVR access "none" (Dispatcharr 0.30): server recordings are not
        // listable; only this device's own local recordings count.
        if !active.dispatcharrCanViewDVR {
            return allRecordings.contains { $0.serverID == sid && $0.destination == .local }
        }
        return allRecordings.contains { $0.serverID == sid }
    }
    /// True when the active server has advertised ANY VOD content, OR
    /// is still loading its VOD library. Keeping the tab visible while
    /// loading prevents the flicker of "tab missing → tab appears" on
    /// cold launch or server switch. A server that completes loading
    /// with zero movies and zero series (e.g., a bare live-TV-only
    /// M3U) hides the tab entirely — matching the dynamic behaviour
    /// of the DVR and Favorites tabs.
    private var hasVOD: Bool { hasMovies || hasSeries }

    /// Movies half of the former On Demand tab. Dispatcharr 0.30 per-user
    /// permissions: an account whose `vod_movies_enabled` is explicitly
    /// false retires the Movies tab even while the series library is
    /// populated (without this the tab survived on its sibling's content
    /// and showed an empty grid). UNKNOWN never hides: `dispatcharrCanViewVOD`
    /// is true for an unprobed / unreadable account.
    ///
    /// The catalog half of this ("stored titles, or a sweep that will store
    /// some") comes from `vodFacts`, so a progressive count publish cannot
    /// re-evaluate this body; the permission half stays here, where the active
    /// server lives.
    private var hasMovies: Bool {
        if let active = activeServerForTabs, !active.dispatcharrCanViewVOD { return false }
        return vodFacts.hasMovies
    }

    /// Series half. Mirrors `hasMovies` against `vod_series_enabled`.
    private var hasSeries: Bool {
        if let active = activeServerForTabs, !active.dispatcharrCanViewSeries { return false }
        return vodFacts.hasSeries
    }

    /// Wires `vodFacts` to the two objects it folds, once. The closure is the
    /// ONLY place the tab bar's catalog truth is computed, so the store and the
    /// sweep activity can never disagree about whether a tab belongs on screen.
    private func startVODCatalogFacts() {
        let facts = VODCatalogFacts.shared
        let store = vodStore
        let activity = sweepActivity
        facts.start(
            recompute: { @MainActor in
                facts.apply(
                    hasMovies: store.moviesCount > 0
                        || store.isLoadingMovies
                        || store.isRefillingMovies
                        || activity.isActive(.movie),
                    hasSeries: store.seriesCount > 0
                        || store.isLoadingSeries
                        || store.isRefillingSeries
                        || activity.isActive(.series),
                    isLoadingMovies: store.isLoadingMovies,
                    isLoadingSeries: store.isLoadingSeries,
                    isRefillingMovies: store.isRefillingMovies,
                    isRefillingSeries: store.isRefillingSeries,
                    isSearchingMovies: store.isSearchingMovies,
                    isSearchingSeries: store.isSearchingSeries)
            },
            sources: [store.objectWillChange, activity.objectWillChange])
    }

    /// The server every tab gate reads. Deliberately the same expression the
    /// DVR gate uses so the two can never disagree about which playlist is
    /// live. nil (no servers yet) leaves every capability at UNKNOWN, which
    /// hides nothing.
    private var activeServerForTabs: ServerConnection? {
        allServers.first(where: { $0.isActive }) ?? allServers.first
    }

    /// Tab-presence flags the TabView actually reads. On tvOS these come from
    /// the latched, navigation-safe @State (tabShow*); on iOS they read the
    /// live values directly (iOS NavigationStacks are not torn down by a
    /// sibling-tab insertion the way tvOS's are).
    #if os(tvOS)
    private var showRecordingsTab: Bool { tabShowRecordings }
    private var showMoviesTab: Bool { tabShowMovies }
    private var showSeriesTab: Bool { tabShowSeries }
    #else
    private var showRecordingsTab: Bool { hasRecordings }
    private var showMoviesTab: Bool { hasMovies }
    private var showSeriesTab: Bool { hasSeries }
    #endif

    /// Is `tab` currently part of the TabView's child set? Used to bounce a
    /// selection off a tab that has just been retired (and to reject a
    /// persisted default tab at launch).
    private func isTabVisible(_ tab: AppTab) -> Bool {
        switch tab {
        case .liveTV, .settings: return true
        case .favorites:         return false
        case .dvr:               return showRecordingsTab
        case .movies:            return showMoviesTab
        case .tvShows:           return showSeriesTab
        }
    }

    #if os(tvOS)
    /// One Equatable key combining the nav-state gates, so a SINGLE .onChange
    /// re-applies deferred tab-visibility changes. Folding the three triggers
    /// into one keeps the tabContentView modifier chain short enough for the
    /// Swift type-checker (three chained .onChange modifiers tipped it over).
    private var tabNavStateKey: String {
        "\(isSettingsSubviewPushed)|\(isVODDetailPushed)|\(selectedTab.rawValue)"
    }
    #endif

    #if os(tvOS) && DEBUG
    /// Task #254 diagnostic: walk the key window and log every view whose
    /// class name smells like a tab bar / toolbar, with frame + hidden +
    /// alpha. The nav-bar-vanishes bug leaves SwiftUI state healthy, so the
    /// truth has to come from the UIKit layer.
    private func dumpBarHierarchy(_ tag: String) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard !windows.isEmpty else {
            debugLog("[BARDUMP \(tag)] no windows")
            return
        }
        var lines = 0
        // Every window (the tvOS 27 tab bar was never found under the key
        // window), and the FULL subtree under any UITabBar so its layout
        // (stack view spacing, item frames) can be read.
        func walk(_ v: UIView, _ depth: Int, insideBar: Bool) {
            let name = String(describing: type(of: v))
            let isBar = v is UITabBar
            if isBar || insideBar
                || name.range(of: "tab", options: .caseInsensitive) != nil
                || name.range(of: "toolbar", options: .caseInsensitive) != nil
                || name.range(of: "navigationbar", options: .caseInsensitive) != nil {
                var extra = ""
                if let st = v as? UIStackView { extra = " spacing=\(st.spacing) axis=\(st.axis.rawValue)" }
                debugLog("[BARDUMP \(tag)] d\(depth) \(name) frame=\(v.frame) hidden=\(v.isHidden) alpha=\(v.alpha) sub=\(v.subviews.count)\(extra)")
                lines += 1
            }
            for s in v.subviews { walk(s, depth + 1, insideBar: isBar || insideBar) }
        }
        for (i, w) in windows.enumerated() {
            debugLog("[BARDUMP \(tag)] window \(i) \(String(describing: type(of: w))) key=\(w.isKeyWindow) level=\(w.windowLevel.rawValue)")
            walk(w, 0, insideBar: false)
        }
        debugLog("[BARDUMP \(tag)] done, matches=\(lines), windows=\(windows.count)")
    }
    #endif

    /// Copy the live tab-gate values into the latched @State, but ONLY when it
    /// is safe to mutate the TabView's child set: not while a Settings subview
    /// or VOD detail is pushed, and not while the Settings tab is selected (the
    /// entry point into those fragile NavigationStacks). Keeps the sync-time
    /// tab insertions from tearing down a Settings sub-page mid-navigation.
    /// No-op on iOS.
    private func syncTabVisibility() {
        #if os(tvOS)
        guard !isSettingsSubviewPushed, !isVODDetailPushed, selectedTab != .settings else {
            // Diagnostic for the sticky blank-Settings bug: confirm the latch is
            // deferring while in Settings/nav. If a blank ever coincides with a
            // DEFER-less tab-set mutation below, this + the APPLYING line pinpoint it.
            debugLog("🔶 syncTabVisibility DEFER (settingsPushed=\(isSettingsSubviewPushed) vodPushed=\(isVODDetailPushed) tab=\(selectedTab.rawValue)) live[rec=\(hasRecordings) mov=\(hasMovies) ser=\(hasSeries)] latched[rec=\(tabShowRecordings) mov=\(tabShowMovies) ser=\(tabShowSeries)]")
            return
        }
        let recChange = tabShowRecordings != hasRecordings
        let movChange = tabShowMovies != hasMovies
        let serChange = tabShowSeries != hasSeries
        let vodChange = movChange || serChange
        if recChange || vodChange {
            // A tab APPEARING/DISAPPEARING mutates the TabView child set — the
            // exact action that can tear down a fragile Settings NavigationStack.
            // If the blank recurs, the last such line before it (with tab context)
            // is the culprit trigger.
            debugLog("🔶 syncTabVisibility APPLYING tab-set change (tab=\(selectedTab.rawValue) settingsPushed=\(isSettingsSubviewPushed) vodPushed=\(isVODDetailPushed)): rec \(tabShowRecordings)→\(hasRecordings) mov \(tabShowMovies)→\(hasMovies) ser \(tabShowSeries)→\(hasSeries)")
        }
        if recChange { tabShowRecordings = hasRecordings }
        if movChange { tabShowMovies = hasMovies }
        if serChange { tabShowSeries = hasSeries }
        // A latch that just retired the selected tab must move the selection
        // too; the TabView keeps a tag that no longer has a child otherwise
        // and tvOS lands on a blank pane.
        redirectIfSelectedTabHidden()
        #endif
    }

    /// Move the selection somewhere valid when the tab the user is on has
    /// just been retired (a capability flipped to denied, the library
    /// drained, the last recording was deleted). Settings and Live TV are
    /// always present, so Live TV is a safe destination.
    private func redirectIfSelectedTabHidden() {
        guard !isTabVisible(selectedTab) else { return }
        debugLog("🔶 selected tab \(selectedTab.rawValue) is no longer visible; redirecting to Live TV")
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedTab = .liveTV
        }
    }

    // MARK: - Tab Content
    #if os(tvOS)
    /// Task #254: recreate the TabView when the ACTIVE PLAYLIST changes.
    /// The tvOS top tab bar auto-collapses (container slides to y=-115)
    /// while focus sits deep in a tall settings page - exactly where the
    /// Dispatcharr detail's Set Active row lives. Activating a playlist
    /// from there re-layouts the settings content under the collapsed bar
    /// and breaks UIKit's restore coordination: the bar stays parked
    /// off-screen forever and Menu is swallowed, trapping the user
    /// (device-verified via _UITabBarContainerView_TV frame dumps; also
    /// reproduces on stock 1.8.9). Everything rebuilds on a playlist
    /// switch anyway, so giving the TabView a fresh identity per active
    /// server is consistent and puts the bar back in its resting visible
    /// state. Selection and nav-path state live on MainTabView, not the
    /// TabView child, so they survive the identity change.
    private var tvTabViewIdentity: String {
        let serverPart = allServers.first(where: { $0.isActive })?.id.uuidString ?? "none"
        // tvBarHealToken: bumping it remounts the TabView exactly like a
        // playlist switch does. See healCollapsedTabBarIfNeeded.
        return "\(serverPart)#heal\(tvBarHealToken)"
    }

    /// Task #254 round 2 (Logan 2026-08-13): the Set Active remount above
    /// only heals when the ACTIVE SERVER changes. The underlying UIKit bug
    /// fires on ANY tall settings detail page that re-layouts under the
    /// auto-collapsed bar - Edit mode on the Dispatcharr playlist page,
    /// then backing out, reproduces the same parked-forever bar with no
    /// playlist switch to trigger the heal. So: whenever Settings pops
    /// back to its root, inspect the UIKit layer (same signature the
    /// task #254 forensics established: container frame minY < 0 with
    /// hidden=false alpha=1) and, if the bar is parked, bump the heal
    /// token to force the remount. Checked twice (0.8s + 2.5s) because a
    /// legitimate restore animation may still be in flight at the first
    /// check; a healthy bar rests at minY ~46 well before the second.
    private func scheduleTabBarHealCheck() {
        for delay in [0.8, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                healCollapsedTabBarIfNeeded()
            }
        }
    }

    private func healCollapsedTabBarIfNeeded() {
        guard !isSettingsSubviewPushed else { return }
        // A tab that hid the bar on scroll (Movies) parks it off-screen on
        // purpose; remounting the TabView here tore down every tab, the
        // 5k-title grid included (device log 2026-09-03, "froze up").
        guard !tabBarScrollState.isHidden else { return }
        // The VOD tabs own their bar (hide on scroll, restore on hero
        // focus). tvOS also collapses the bar for ANY content scroll, so a
        // first step into the poster grid (below Movies' hide threshold)
        // looked parked and this remounted the TabView 2.5 s after the
        // tab switch (trace 2026-09-04 15:41, "jumped back to the tab").
        guard !selectedTab.isMediaCenter else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return }
        var parked = false
        func walk(_ v: UIView) {
            let name = String(describing: type(of: v))
            if name.contains("TabBarContainerView"),
               !v.isHidden, v.alpha > 0, v.frame.minY < 0 {
                parked = true
                return
            }
            for s in v.subviews where !parked { walk(s) }
        }
        walk(window)
        guard parked else { return }
        debugLog("[TABBAR-HEAL] bar parked off-screen at settings root; remounting TabView (token \(tvBarHealToken) -> \(tvBarHealToken + 1))")
        tvBarHealToken += 1
    }
    #endif

    /// Re-tapping the tab you are already on (iPhone / iPad).
    ///
    /// The floating bar is the system's `TabView` bar, and the ONLY signal it
    /// gives for a re-tap is a selection write with the value already there,
    /// so the binding is where this is intercepted. Popping a pushed page is
    /// UIKit's own re-tap behaviour on the `NavigationStack` inside the tab
    /// (that is why Settings already did it, and Movies / TV Shows / DVR get
    /// it for free); what was missing is the AT-ROOT half. Every tab gets one
    /// `.aerioTabReselected` post and decides for itself what its top is,
    /// scrolling only when it is at root - the pop wins this tap, the next tap
    /// scrolls. One write per tap, nothing during a scroll.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { tapped in
                guard tapped == selectedTab else {
                    selectedTab = tapped
                    return
                }
                #if os(iOS)
                debugLog("[TAB] reselect \(tapped.rawValue) (vodPushed=\(isVODDetailPushed))")
                // The scroll trackers swallow a programmatic jump, so the bar
                // is expanded here rather than waiting for the scroll to
                // report it (each tab also clears its own collapsed flag).
                TabBarCollapseState.shared.set(false)
                NotificationCenter.default.post(
                    name: .aerioTabReselected, object: nil,
                    userInfo: ["tab": tapped.rawValue])
                #endif
            }
        )
    }

    private var tabContentView: some View {
        TabView(selection: tabSelection) {
            ChannelListView()
                .tabItem { Label(AppTab.liveTV.title, systemImage: AppTab.liveTV.icon) }
                .tag(AppTab.liveTV)


            // Favorites is a pinned channel group inside Live TV now
            // (Logan 2026-09-05); the tab is gone. `AppTab.favorites` stays
            // so a persisted default tab from an older build decodes.

            // DVR tab only exists while the user has at least one recording
            // (local or server-side). Animates in/out as recordings are added/removed.
            if showRecordingsTab {
                // Media-center DVR tab on every platform (iPhone 2026-09-05);
                // the old My Recordings list stays reachable from Settings.
                DVRView(isPlaying: $isPlaying, isSelected: selectedTab == .dvr)
                    .tabItem { Label(AppTab.dvr.title, systemImage: AppTab.dvr.icon) }
                    .tag(AppTab.dvr)
            }

            // On Demand tab only exists while the active server exposes
            // VOD content (or is still loading its library). A server
            // that returns empty movie + series lists (e.g., a pure
            // live-TV M3U or a Dispatcharr instance without any VOD
            // ingested) hides the tab entirely, matching the dynamic
            // behaviour of Favorites and DVR.
            if showMoviesTab {
                // Lazy until first shown (2026-09-12 lag hunt): both VOD tabs
                // observe vodStore, so the launch-time snapshot restore
                // publishes (5035 movies, 3063 series) used to build and lay
                // out tab content the user was not looking at. Measured as a
                // 3032 ms run loop turn after `publish vod.series 3063 items`
                // while the Live TV tab was on screen. Once a tab has been
                // selected it stays built, so tab-switch latency is unchanged.
                LazyTabContent(isSelected: selectedTab == .movies) {
                    MoviesView(vodStore: vodStore, isPlaying: $isPlaying,
                               isDetailPushed: $isVODDetailPushed, popRequested: $vodNavPopRequested,
                               isSelected: selectedTab == .movies)
                }
                    .tabItem { Label(AppTab.movies.title, systemImage: AppTab.movies.icon) }
                    .tag(AppTab.movies)
            }

            // Series is gated independently of Movies: Dispatcharr 0.30 can
            // deny `vod_series_enabled` while movies stay allowed.
            if showSeriesTab {
                LazyTabContent(isSelected: selectedTab == .tvShows) {
                MoviesView(vodStore: vodStore, isPlaying: $isPlaying,
                           isDetailPushed: $isVODDetailPushed, popRequested: $vodNavPopRequested,
                           isSelected: selectedTab == .tvShows, kind: .series)
                }
                    .tabItem {
                        Label(AppTab.tvShows.title, systemImage: AppTab.tvShows.icon)
                            .symbolRenderingMode(.monochrome)
                    }
                    .tag(AppTab.tvShows)
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
        #if os(tvOS)
        // Task #254: see tvTabViewIdentity - fresh TabView per active
        // playlist so the collapsed top bar cannot survive a switch.
        // (Round 2's heal check rides the existing tabNavStateKey
        // onChange below - a separate chained .onChange here re-tipped
        // the Release type-checker, the exact failure tabNavStateKey
        // was created to avoid.)
        .id(tvTabViewIdentity)
        #endif
        .tint(theme.accent)
        // Cast card clearance: the tabs' scroll views get a bottom content
        // inset equal to the card's height while a session is live.
        #if os(iOS)
        .aerioRemoteCardContentInset()
        #endif
        // Tab switch latency probe (Logan 2026-09-06, "visual hang").
        .onChange(of: selectedTab) { _, _ in
            settingsMiniPeek = false
            #if os(iOS)
            // A new tab may be too short to scroll the bar back.
            TabBarCollapseState.shared.set(false)
            #endif
        }
        .onChange(of: selectedTab, initial: true) { _, new in
            // Lets the quiet catalog sweep slow its page pace while the guide
            // owns the screen (1.8.40 guide navigation lag). Plain state on
            // `VODSweepActivity`, so this publishes nothing.
            sweepActivity.setLiveTVOnScreen(new == .liveTV)
        }
        .onChange(of: selectedTab) { old, new in
            debugLog("[TAB] switch \(old) -> \(new)")
            // Leaving a tab cancels and closes its search (Logan
            // 2026-09-16) so no field is left holding first responder for
            // the PiP transition to hand the keyboard back to.
            SearchDismissCenter.dismissAll(reason: "tab \(old) -> \(new)")
            // Entering the DVR tab is the moment recordings must be
            // current; it is also what lets the background poll back off
            // (review 2026-09-11 section 6 proposal 5).
            if new == .dvr {
                Task { await reconcileAllDispatcharrRecordings() }
            }
        }
        // GH #20 auto-hide, iOS 26+ path (reworked 2026-07-12): minimize
        // is set to .never so there is no minimized pill and no system
        // minimize state machine competing with the manual toggle - that
        // competition is what made .visible unable to restore the bar
        // (field report 2026-07-11: "tab bar doesn't come back after
        // fading out the first time"). The four scroll-driven sites drive
        // full hide/show on every iOS version via
        // scrollAwayTabBar(collapsed:), Android-style: hide on a
        // deliberate scroll down, full bar back on any scroll up
        // (TabBarScrollTracker).
        .aerioTabBarAutoMinimize()
        // If the user deletes their last recording while on the DVR tab, redirect home.
        .onChange(of: hasRecordings) { _, _ in
            syncTabVisibility()
            redirectIfSelectedTabHidden()
        }
        // If the VOD library drains (e.g., server switched to a
        // pure live-TV source) while the user is on the On Demand
        // tab, redirect home rather than leaving them staring at a
        // tab whose backing content is gone.
        // Movies and TV Shows are observed separately: denying one half
        // (vod_movies_enabled / vod_series_enabled) leaves `hasVOD` true, so
        // a combined observer would never fire for the half that went away.
        .onChange(of: hasMovies) { _, _ in
            syncTabVisibility()
            redirectIfSelectedTabHidden()
        }
        .onChange(of: hasSeries) { _, _ in
            syncTabVisibility()
            redirectIfSelectedTabHidden()
        }
        // Re-apply any tab-visibility change that was deferred while a Settings
        // subview / VOD detail was open, or while the Settings tab was selected,
        // the instant the user returns to a safe spot. This is what lets the
        // deferred sync-time tab insertions land without tearing down an active
        // Settings navigation (the submenu-stuck-while-syncing fix).
        #if os(tvOS)
        .onChange(of: tabNavStateKey) { _, _ in
            syncTabVisibility()
            // Task #254 round 2: when Settings just popped to root the
            // key flips isSettingsSubviewPushed to false - check whether
            // the tab bar came back and remount if it is parked.
            if !isSettingsSubviewPushed { scheduleTabBarHealCheck() }
        }
        #endif
        .onAppear {
            startVODCatalogFacts()
            syncTabVisibility()
            debugLog("🔶 MainTabView.onAppear: allServers=\(allServers.count), selectedTab=\(selectedTab), thread=\(Thread.current)")
            if UserDefaults.standard.bool(forKey: "launchOnLiveTV") {
                selectedTab = .liveTV
                UserDefaults.standard.removeObject(forKey: "launchOnLiveTV")
                debugLog("🔶 MainTabView.onAppear: launchOnLiveTV=true, set selectedTab=.liveTV")
            } else {
                // A persisted default tab is a HINT, never an authority: the
                // Android startup race pinned the DVR tab because the
                // restored selection was trusted before capabilities had
                // resolved. Restore only into a tab that is actually part of
                // the child set right now; the `.onChange` gates above bring
                // it back on their own if the capability later resolves to
                // allowed.
                let restored = AppTab(rawValue: defaultTabRaw) ?? .liveTV
                selectedTab = isTabVisible(restored) ? restored : .liveTV
            }
            // Cold launch via aerio://settings/<page>: the URL is delivered
            // before this view exists, so the notification above landed with
            // nobody listening. The pending page is still parked on
            // SettingsDeepLink (peek only; SettingsView consumes it).
            if SettingsDeepLink.shared.hasPending {
                debugLog("🔗 MainTabView.onAppear: pending Settings deep link → Settings tab")
                selectedTab = .settings
            }
            configureTabBarAppearance()
            tryShowInitialLoading()
            #if os(tvOS)
            // The circles mount once a tab bar button HOLDS focus (seen by
            // the focus-update observer below); mounting them the instant
            // the bar existed handed them the launch focus (trace 2026-09-05
            // 13:13). Backstop so they are never hidden for good.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                if !tvTabBarSeen { tvTabBarSeen = true }
            }
            #endif
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
                refreshGuideIfStaleOnForeground(from: old, to: new)
                // Audit P1 memory: trim aired programs out of the resident
                // GuideStore dict on every warm foreground so it tracks the
                // live window instead of accumulating every past program for
                // the process lifetime. Independent of the staleness refresh
                // above (runs even when the cache is fresh).
                if new == .active && old != .active {
                    GuideStore.shared.trimExpiredPrograms()
                }
            }
        ))
        // Field 2026-08-30 (MLS group): a session that STAYS foregrounded
        // never refetches - the staleness refresh above only fires on the
        // background->active edge, so an evening of continuous use rendered
        // a channel lineup from before teamarr's event-channel rewrite (the
        // server had removed 12 finished events and regrouped the new MLS
        // games; the app kept showing its 17:27 snapshot for 80+ minutes).
        // Sweep the SAME gated check on a 5-minute tick while active: the
        // 30-minute staleness window still decides whether anything is
        // actually refetched, so steady state adds one cheap age check per
        // tick and at most the pull-to-refresh workload per half hour.
        .task(runPeriodicGuideStalenessSweep)
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
                        // v1.6.23: also set the session flag so any
                        // downstream onChange-driven `tryShowInitial-
                        // Loading` call (server count settling, etc.)
                        // can't immediately re-present the cover and
                        // make Skip look like a no-op (jesmannstl
                        // v1.6.22 report).
                        userDismissedInitialLoading = true
                        showInitialEPGLoading = false
                        debugLog("🔶 User dismissed initial loading screen manually")
                    }
                )
            )
        }
        // v1.6.21: single orchestrator task running all four initial-sync
        // phases sequentially: channels, then EPG, then VOD movies, then
        // VOD series. Previously this lived in two parallel `.task(id:)`
        // blocks (one for channelServerKey, one for vodServerKey) that
        // tried to coordinate via shared `@Published` flags, but the
        // start order of the two tasks is non-deterministic, so the
        // VOD task's `while channelStore.isLoading` wait loop fell
        // through immediately whenever it raced ahead of the channel
        // task's `channelStore.refresh()` call. The result was that
        // channels, EPG, and both VOD streams all fanned out paginated
        // requests in parallel, overwhelming Dispatcharr's worker pool
        // on large libraries (the v1.6.21 Apple TV freeze repro on
        // jesmannstl's 3,640-group server).
        //
        // Collapsing into a single task with a combined key removes
        // the race: there is no second task to start before the
        // orchestrator. The sequencing is enforced by `await`,
        // not by polling shared state. Trade-off: when the user
        // toggles `vodEnabled` on a server (the only thing in
        // `vodServerKey` that isn't in `channelServerKey`), this
        // task re-fires and re-runs every phase including channels.
        // Channels re-fetch is fast and the new concurrency cap
        // keeps the total request rate bounded, so it's an
        // acceptable cost for race-free orchestration.
        .task(id: orchestratorKey) {
            // Debounce every re-fire after the first run (see
            // orchestratorRanOnce). Task.sleep throws when SwiftUI
            // cancels this task because the key changed again, so a
            // burst of changes runs the orchestrator exactly once,
            // 900ms after the last one. Staging the Edit Server URL
            // field (EditServerSheet/Page) is the source fix for the
            // keystroke storm; this net covers every other writer
            // (sync merges, older edit surfaces, future fields).
            if orchestratorRanOnce {
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            }
            orchestratorRanOnce = true
            await runChannelServerTaskBody()
        }
        // TEST (branch test/avplayer-hls-engine): hosts the native AVPlayer
        // screen when the engine router in PlayerSession.begin sends a
        // genuine HLS stream to AVPlayer (Developer toggle gated). The mpv
        // pipeline is untouched; dismissing returns to the guide.
        .fullScreenCover(item: $playerSession.nativeHLSItem) { hlsItem in
            NativeHLSPlayerScreen(
                item: hlsItem,
                userAgent: playerSession.nativeHLSUserAgent,
                useRemux: playerSession.nativeHLSUseRemux,
                ingestHeaders: playerSession.nativeHLSHeaders,
                overrideURL: playerSession.nativeHLSOverrideURL
            )
        }
        // DVR reconcile at tab-bar level so the DVR tab lights up as
        // soon as a Dispatcharr server reports a recording — even if
        // the user scheduled it from the web UI (no local row to
        // trigger MyRecordingsView.task). Runs once on server change,
        // then every 2 minutes while the app is foregrounded. This is
        // cheap: a single GET /api/channels/recordings/ per server.
        .task(id: dvrReconcileKey) {
            // Recordings follow the EPG cache rule too (Logan 2026-09-12): the
            // list is RESTORED from its persisted store and shown instantly,
            // and the first network refresh waits for the same settle point the
            // VOD and EPG sweeps use. The SwiftData store IS the DVR cache --
            // every row the last reconcile wrote is already on disk, scoped to
            // its server by `Recording.serverID`, so a second JSON mirror under
            // AppCacheDirectory would only be a chance to disagree with it.
            let restored = (try? modelContext.fetch(FetchDescriptor<Recording>()))?.count ?? 0
            debugLog("[DVR] restored \(restored) recordings from cache")
            // The loading cover must not wait on the network refresh any more:
            // the restored list is what the DVR tab shows.
            didInitialDVRReconcile = true
            await AppSettleGate.shared.awaitSettled(reason: "DVR refresh")
            if Task.isCancelled { return }
            await reconcileAllDispatcharrRecordings()
            let after = (try? modelContext.fetch(FetchDescriptor<Recording>()))?.count ?? 0
            debugLog("[DVR] background refresh: \(after) recordings")
            while !Task.isCancelled {
                // Back off to 10 minutes while a live tile is playing
                // (review 2026-09-11 section 6 proposal 5): the 2-minute
                // poll ran for the whole life of the app, including
                // through the 5-minute dead-tile window
                // (session.txt:3611-3614). The DVR tab refreshes on entry
                // (see the selectedTab handler), so a user looking at
                // recordings still sees them fresh.
                let livePlaying = PlayerSession.shared.mode == .multiview
                    && MultiviewStore.shared.tiles.contains { $0.kind == .live }
                try? await Task.sleep(for: .seconds(livePlaying ? 600 : 120))
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
                            .scaledFont(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.accent)
                    }
                }
            }
        }
        // tvOS renders search IN PLACE as tab content below the persistent
        // nav chrome (Logan 2026-08-12, third iteration of this ruling:
        // never a sheet, never a cover -- exactly Android TV's Search
        // screen). The overlay lives in the ZStack above; only iOS presents.
        #if os(iOS)
        .sheet(isPresented: $showSearch) {
            SearchView()
        }
        #endif
        // Leaving the current tab closes search, like Android's pill
        // selection does.
        #if os(tvOS)
        // Faster tab switch (Logan 2026-09-05): the system bar commits a
        // selection ~330 ms after a pill takes focus. The focus event itself
        // is immediate, so select from it after a 100 ms debounce (scrubbing
        // across pills must not mount every tab on the way).
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                  let view = ctx.nextFocusedItem as? UIView,
                  String(describing: type(of: view)) == "UITabBarButton" else { return }
            if !tvTabBarSeen {
                tvTabBarSeen = true
                debugLog("[FOCUS] nav circles mounted (tab bar holds focus)")
            }
            guard let label = view.accessibilityLabel,
                  let tab = AppTab.allCases.first(where: { $0.title == label }) else { return }
            tabFocusSelectTask?.cancel()
            tabFocusSelectTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, selectedTab != tab else { return }
                debugLog("[TAB] focus-select -> \(tab.rawValue)")
                selectedTab = tab
            }
        }
        #endif
        .onChange(of: selectedTab) { _, _ in
            if showSearch { showSearch = false }
        }
        #if os(tvOS)
        // Publish the overlay state so the guide's window-level hold
        // recognizers can disarm while search is up.
        .onChange(of: showSearch) { _, isUp in
            TVSearchOverlayState.shared.isUp = isUp
        }
        #endif
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
        .onReceive(NotificationCenter.default.publisher(for: .aerioTabMenuPassthrough)) { _ in
            debugLog("🎮 [MT-PASS] Menu forwarded by a tab's own handler")
            handleMenuPress()
        }
        .onPlayPauseCommand { handlePlayPauseCommand() }
        .onReceive(NotificationCenter.default.publisher(for: .stopPlaybackForBackground)) { _ in
            if nowPlaying.isActive {
                debugLog("🎮 Background: stopping playback")
                nowPlaying.stop()
                NowPlayingBridge.shared.teardown()
            }
            // Channel retention never ingests while backgrounded (same
            // policy as playback itself - the loopback engines suspend).
            LiveChannelRetention.shared.stopAll(reason: "app backgrounded")
        }
        // Top Shelf deep link for a channel → switch to Live TV tab.
        // ChannelListView itself handles starting playback once channels are loaded.
        .onReceive(NotificationCenter.default.publisher(for: .aerioOpenChannel)) { _ in
            debugLog("🔗 MainTabView: aerioOpenChannel → switch to Live TV tab")
            withAnimation { selectedTab = .liveTV }
        }
        // Top Shelf deep link for a VOD item → switch to the matching tab.
        .onReceive(NotificationCenter.default.publisher(for: .aerioOpenVOD)) { notif in
            guard let vodType = notif.userInfo?["vodType"] as? String else { return }
            let target: AppTab = vodType == "movie" ? .movies : .tvShows
            // A Top Shelf row or deep link can outlive the permission that
            // created it. Selecting a tag with no matching child is a no-op
            // in SwiftUI, so refuse the switch explicitly and stay put.
            guard isTabVisible(target) else {
                debugLog("🔗 MainTabView: aerioOpenVOD(\(vodType)) ignored, \(target.rawValue) tab is not available")
                return
            }
            debugLog("🔗 MainTabView: aerioOpenVOD(\(vodType)) → switch to \(target.rawValue) tab")
            withAnimation { selectedTab = target }
        }
        #endif
        // EPG search → jump to the program in the Live TV guide.
        // Cross-platform (the aerioOpenChannel switch above is
        // tvOS-only). ChannelListView forces guide mode and
        // EPGGuideView does the channel focus + timeline scroll.
        .onReceive(NotificationCenter.default.publisher(for: .aerioJumpToGuideProgram)) { _ in
            debugLog("🔗 MainTabView: aerioJumpToGuideProgram → switch to Live TV tab")
            withAnimation { selectedTab = .liveTV }
        }
    }

    /// Selects the Settings tab for a `aerio://settings/<page>` deep link.
    @MainActor
    private func selectSettingsTabForDeepLink() {
        debugLog("🔗 MainTabView: aerioOpenSettingsPage -> switch to Settings tab")
        withAnimation { selectedTab = .settings }
    }

    /// v1.6.13: Channel/EPG load orchestrator. Pulled out of the
    /// `.task(id: channelServerKey)` closure attached to body so the
    /// body's expression complexity stays under Swift's type-checker
    /// budget on tvOS x86_64. Behavior unchanged from the inline
    /// closure that lived here in v1.6.12.
    @MainActor
    private func runChannelServerTaskBody() async {
        let orchestratorStart = Date()
        // Reset the one-shot guide failover guard so each fresh server-key
        // change (server switch, credentials change, network transition)
        // gets exactly one LAN/WAN re-probe-and-retry attempt.
        didAttemptGuideFailover = false
        debugLog("🟢 [Orchestrator] BEGIN, servers=\(allServers.count)")
        // Rebuild On Demand for the new playlist FIRST, before anything else
        // runs. VOD is the last phase of this orchestrator (after channels,
        // EPG, DVR and a settle delay), so leaving the reset to the loaders
        // meant On Demand kept serving the previous playlist's library, and
        // its id-keyed detail caches, for the whole of that. Channels and the
        // guide already rebuild on a switch; this makes VOD behave the same.
        vodStore.beginDisplaying(
            server: allServers.first(where: { $0.isActive }) ?? allServers.first
        )
        debugLog("🔶 MainTabView.task(channelServerKey): firing, servers=\(allServers.count)")
        #if os(tvOS) && DEBUG
        // Task #254 instrumentation: dump the UIKit bar-adjacent hierarchy
        // around a server activation so a healthy-vs-broken diff shows
        // whether the TabView top bar goes hidden, zero-frame, or REMOVED.
        dumpBarHierarchy("serverKey+0s")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            dumpBarHierarchy("serverKey+3s")
            try? await Task.sleep(for: .seconds(5))
            dumpBarHierarchy("serverKey+8s")
        }
        #endif
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

        // VOD snapshot restore runs IN PARALLEL with the channel fetch
        // (Logan 2026-09-12: "the app launches quickly but loading EPG, DVR,
        // Movies and TV Shows is a different story").
        //
        // It is a pure disk read plus one publish per kind and needs nothing
        // from channels or the guide, yet it used to sit behind phase 1 + 2.
        // Field log session7.txt, the 14:19 launch: phase 1 (channels) took
        // until 14:19:35.965, phase 3 began at 14:19:35.968, and the cached
        // library only appeared at 14:19:39.856 (movies) and 14:19:43.837
        // (series) - 17 s after launch for 5044 movies and 3066 series that
        // were already on disk and marked "(launch, no network)". Kicking it
        // here makes On Demand populated by the time the tab can be reached.
        let vodRestoreHandle = Task { await vodStore.restoreSnapshots(servers: allServers) }

        // Wait for channels to finish loading.
        while channelStore.isLoading {
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Collect the parallel cache-load verdict. If the
        // channel fetch took longer than the SwiftData load
        // (the typical case — network RTT vs. local disk) this
        // await resolves immediately.
        let cacheIsFresh = await cacheLoadHandle.value

        debugLog("🟢 [Orchestrator] phase 1 done (channels), elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s, channels=\(channelStore.channels.count), rss=\(ProcessMetrics.residentSetSizeBytes() / 1_048_576) MB")
        refreshDispatcharrPermissions(reason: "cold launch", isColdLaunch: true)
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
            // `start > now` (not `end > now+30min`): a seeded still-airing
            // program has start <= now, so the old test treated a current-only
            // seed cache as "complete" and skipped the grid refetch, leaving
            // the guide showing only the now-playing program with the future
            // blank. See the matching comment in EPGGuideView.swift.
            let gateNow = Date()
            // Identity invariant: a cached program row only counts toward the
            // skip-network guards when its channel key matches a channel the
            // guide can actually display. Rows keyed to channels that no
            // longer exist (deleted server, changed id derivation) are
            // orphans; letting them satisfy freshness/coverage leaves the
            // user staring at a blank guide that the app believes is fresh.
            // A cache that does not match the current channel identity is
            // stale regardless of age.
            let liveChannelIDs = Set(channelStore.channels.map(\.id))
            let hasFuturePrograms = guideStore.programs.contains { channelID, progs in
                liveChannelIDs.contains(channelID) && progs.contains { $0.start > gateNow }
            }
            // v1.6.22: detect a "fresh but pathologically sparse"
            // cache and force a refetch.
            //
            // The trap this closes: if a previous run failed the
            // XMLTV pass (auth gate, timeout, parse error) AND the
            // bulk grid pass also failed/partially-failed, the
            // saveToCache step may persist EPG data for only a
            // handful of channels. Subsequent launches read that
            // partial cache, see it's recent enough to be "fresh",
            // and skip `loadAllEPG` entirely, leaving the user
            // permanently stuck with a near-empty guide. Freyguy1975
            // hit this with 8 of 333 channels (2.4%) cached from a
            // run where Dispatcharr's `/output/epg` returned 403.
            //
            // The 25% threshold is conservative: a real Dispatcharr
            // instance with healthy EPG covers >70% of channels
            // typically. M3U/Xtream paths populate the cache
            // differently (per-channel rather than bulk XMLTV) and
            // can land below 25% legitimately, but those servers
            // also benefit from a refetch attempt; the worst case
            // is one extra network round trip per cold launch on a
            // genuinely sparse dataset, which the existing
            // freshness window then catches on the next try.
            let totalChannels = max(channelStore.channels.count, 1)
            // Same identity rule as above: only channel keys present in the
            // current channel list count as covered. Orphaned keys must not
            // inflate coverage.
            let matchedChannelKeys = liveChannelIDs.intersection(guideStore.programs.keys).count
            let coverageRatio = Double(matchedChannelKeys) / Double(totalChannels)
            // Huge playlists (Xtream panels with tens of thousands of channels,
            // most of which never carry EPG): coverage against ALL channels is
            // always "sparse", and the forced refetch parsed the provider's
            // 315k-programme XMLTV on top of the cache every launch, taking the
            // Apple TV past its memory line (2026-09-03). Treat a fresh cache
            // as good enough there; the scheduled refresh still runs.
            let cacheCoverageOK = coverageRatio >= 0.25 || totalChannels > GuideStore.largePlaylistChannels
            if cacheIsFresh && hasFuturePrograms && cacheCoverageOK {
                debugLog("🟢 [Orchestrator] phase 2 EPG: cache fresh, seeding only (no network), elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s")
                // Seed EPGCache from GuideStore.programs so the
                // List view has per-channel EPG data. Awaited so
                // the cover doesn't dismiss before EPGCache has
                // the entries it needs.
                await guideStore.seedEPGCache(channels: channelStore.channels, server: activeServer)
                channelStore.isEPGLoading = false

                // v1.7.x: even when the cache is fresh, fire a
                // non-blocking grid refresh on Dispatcharr so the
                // now-airing program slice gets re-enriched with
                // categories and `programID`s. Two reasons this
                // matters even with a fresh-cache hit:
                //   1. The bulk `/api/epg/grid/` endpoint strips
                //      categories server-side. The cache hit gives
                //      us program structure (title, time, desc) but
                //      whatever categories were there came from
                //      enrichment in a PRIOR session — they're now
                //      stale for any program the user opens
                //      Program Info on.
                //   2. Cached rows from pre-v1.7.x builds were
                //      persisted before the `programID` column
                //      existed, so loadFromCache returns programs
                //      with `programID = nil`. ProgramInfoView's
                //      lazy-load needs that ID to call
                //      `/api/epg/programs/<id>/`; without it, the
                //      modal renders zero pills regardless of how
                //      good the cache is. Re-running fetchUpcoming
                //      repopulates `programID` on every program in
                //      the live window from the fresh grid response.
                // Fire-and-forget: completes in 5–30s in the
                // background, depending on EPG size. The user sees
                // the cached guide instantly; categories tint in
                // progressively as enrichment results land.
                if let activeServer, activeServer.type == .dispatcharrAPI {
                    debugLog("🟢 [Orchestrator] phase 2 EPG: firing background fetchUpcoming on Dispatcharr (cache fresh — refresh categories + repopulate programIDs)")
                    // GuideStore.fetchUpcoming is @MainActor-isolated
                    // (it mutates @Published `programs` and writes
                    // through ChannelStore.shared), so the background
                    // refresh runs on main with non-blocking awaits
                    // for the actual network I/O. `Task { }` (not
                    // `Task.detached`) keeps the body MainActor-bound
                    // and sidesteps the Sendable wrap on the SwiftData
                    // `ServerConnection` array we'd otherwise have to
                    // marshal across an actor boundary.
                    Task { @MainActor [allServers] in
                        // Cold-load yields to playback (2026-06-29): the EPG cache is
                        // already fresh, so this refresh is NON-ESSENTIAL cosmetic
                        // enrichment (category tints + programID backfill). Its ~30k-row
                        // grid decode runs HERE on the main actor; when it overlaps the
                        // cold start while a live stream is playing it starves the
                        // heaviest live decoder on the SAME main thread — measured on a
                        // 4K HDR feed as cache->0.1s plus a watchdog-reload storm that
                        // then leaks memory. Hold this refresh until playback settles
                        // (tiles drain) or a 60s ceiling, whichever first, so it lands
                        // after the decoder has filled its cache. No hold when idle.
                        var heldSec = 0
                        while !MultiviewStore.shared.tiles.isEmpty, heldSec < 60 {
                            try? await Task.sleep(for: .seconds(5))
                            heldSec += 5
                        }
                        if heldSec > 0 {
                            debugLog("🟢 [Orchestrator] phase 2 EPG: held background fetchUpcoming \(heldSec)s for active playback")
                        }
                        // Wait for the app to settle before spending the
                        // launch on a refresh nobody asked for (2026-09-12).
                        // The tile check above only holds while a stream is
                        // playing, so on a plain relaunch this ran straight
                        // away and landed on top of the guide's first paint.
                        // Apple TV log atvlogs/session5.txt: the app launched
                        // at 02:25:06.978 and the guide rendered at
                        // 02:25:11.633, and this refresh then pulled 4.9 MB of
                        // epgdata (02:25:13.765) plus the grid and republished
                        // the entire programme map at 02:25:14.697, taking RSS
                        // from 56 MB to 156 MB while the user was trying to
                        // press a button. Nothing here is load-bearing: the
                        // cache is fresh, and this pass only refreshes
                        // category tints and backfills programIDs. The settle
                        // gate is the same one the VOD and DVR sweeps use, so
                        // all three quiet passes now start after the guide is
                        // on screen rather than across it.
                        await AppSettleGate.shared.awaitSettled(reason: "EPG cache-fresh refresh")
                        let fetchStart = Date()
                        let didRefresh = await guideStore.fetchUpcoming(
                            channels: channelStore.channels,
                            servers: allServers,
                            replaceExisting: false
                        )
                        let elapsed = Int(Date().timeIntervalSince(fetchStart))
                        debugLog("🟢 [Orchestrator] background fetchUpcoming COMPLETE — didRefresh=\(didRefresh), elapsed=\(elapsed)s (cache-fresh refresh, held \(heldSec)s)")
                    }
                }
            } else {
                let coveragePct = Int(coverageRatio * 100)
                if cacheIsFresh && hasFuturePrograms && !cacheCoverageOK {
                    debugLog("🟢 [Orchestrator] phase 2 EPG: cache fresh but sparse, only \(guideStore.programs.count)/\(totalChannels) channels (\(coveragePct)%) covered. Forcing refetch via loadAllEPG.")
                } else {
                    debugLog("🟢 [Orchestrator] phase 2 EPG: starting loadAllEPG (cache stale, fresh=\(cacheIsFresh), hasFuture=\(hasFuturePrograms), coverage=\(coveragePct)%), elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s")
                }
                await channelStore.loadAllEPG()
            }
        } else {
            // Channel load failed (auth, server down, or LAN host
            // unreachable after travelling off the home network). Before
            // surfacing the error, try ONE LAN/WAN failover: re-run the
            // probe (which re-points effectiveBaseURL to whichever of
            // LAN/WAN is reachable now) and refresh against it. Guarded so
            // each fresh server-key change attempts this at most once; the
            // probe is cheap and fast (sub-second at home, 3s timeout off
            // the LAN) so it never blocks the error path for long.
            if !didAttemptGuideFailover, !allServers.isEmpty {
                didAttemptGuideFailover = true
                let after = await TVLANProbe.shared.reprobeAndWait()
                debugLog("🟠 [Orchestrator] guide failover reprobe -> LAN=\(after)")
                channelStore.refresh(servers: allServers)
                while channelStore.isLoading { try? await Task.sleep(for: .milliseconds(200)) }
                if !channelStore.channels.isEmpty { await channelStore.loadAllEPG() }
            }
            // Reset the flag we pre-set above so the cover can
            // dismiss via the error path — otherwise the user
            // would be stuck staring at "Setting Up …" with
            // no way out.
            channelStore.isEPGLoading = false
        }
        debugLog("🟢 [Orchestrator] phase 2 done (EPG), elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s, rss=\(ProcessMetrics.residentSetSizeBytes() / 1_048_576) MB")

        // v1.6.21: VOD phases run sequentially after channels + EPG.
        // Movies first, then series, both awaitable so we observe
        // their completion deterministically (the fire-and-forget
        // `refreshMovies`/`refreshSeries` path used to leave a
        // race where the orchestrator's wait loops on
        // `isRefillingMovies` / `isRefillingSeries` could fall
        // through before `loadMovies`/`loadSeries` had time to
        // flip those flags). Keeping channels and EPG ahead of
        // VOD in the order means Live TV is fully usable before
        // we start hitting the slower paginated VOD endpoints,
        // which on a large library can take minutes against
        // small Dispatcharr deployments.
        guard !allServers.isEmpty else {
            debugLog("🟢 [Orchestrator] BAILED: no servers, total elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s")
            return
        }
        // The guide has rendered (from cache or from the network): that is one
        // of the three conditions the shared settle gate waits on before any
        // quiet background refresh may start (Logan 2026-09-12).
        AppSettleGate.shared.noteGuideRendered()
        // Recordings are NOT reconciled here any more. The DVR list is restored
        // from its persisted store at launch and its first network refresh runs
        // in the background after the settle point, the same rule VOD follows
        // below (the dvrReconcileKey task owns that).
        // (Historical note, kept because it explains the settle rule: the tvOS 26.5 SwiftUI
        // AttributeGraph "different namespace" crash fires when SELECT events
        // flood the guide's display list WHILE VOD is publishing its @Published
        // storm. Phase 2 (EPG) just finished, which dismisses the "Setting Up"
        // cover and drops the user onto the freshly-interactive guide, so
        // starting VOD immediately overlaps its churn with the user's first
        // interaction. Holding VOD briefly lets the guide's display list settle
        // (and any cold-start frustration-mashing subside) before VOD mutates
        // @Published state again. VOD is rarely the first tab opened and On
        // Demand shows its own spinner, so the delay is invisible in practice.
        debugLog("🟢 [Orchestrator] phase 3 BEGIN: VOD snapshot restore, elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s")
        // Started alongside phase 1 above; this normally resolves immediately.
        // The call is idempotent (each kind is guarded on `isEmpty`), so a
        // second restore would be harmless anyway.
        await vodRestoreHandle.value
        debugLog("🟢 [Orchestrator] phase 3 done (restore), elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s, movies=\(vodStore.moviesCount), series=\(vodStore.seriesCount), rss=\(ProcessMetrics.residentSetSizeBytes() / 1_048_576) MB")
        // Phase 4 is no longer a foreground sweep: the snapshots above are what
        // the tabs show, and the network walk is a quiet background pass that
        // starts once the app has settled (guide rendered, any tune past first
        // frame, ~20 s in). The 3 s settle delay that used to guard the tvOS
        // AttributeGraph crash is subsumed by the settle gate's 20 s.
        vodStore.scheduleBackgroundSweep(servers: allServers, reason: "launch")
        debugLog("🟢 [Orchestrator] END, total elapsed=\(Int(Date().timeIntervalSince(orchestratorStart)))s")
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
            // Settings tab: the mini stashes at the trailing edge unless
            // the user tapped the sliver to peek it back out.
            let stashed = minimized && selectedTab == .settings && !settingsMiniPeek
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
                                if stashed {
                                    settingsMiniPeek = true
                                } else {
                                    withAnimation(.spring(response: 0.35)) {
                                        nowPlaying.expand()
                                    }
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
                .modifier(MiniPlayerSettingsStash(stashed: stashed, travel: miniW + 24 - MiniPlayerSettingsStash.sliver))
            }
            .ignoresSafeArea()
            // AirPlay handoff: the receiver shows the picture, the mini
            // would only be a black box; hidden in place, still mounted
            // because its tile feeds the receiver.
            .opacity(airPlay.hostsHeadless ? 0 : 1)
            .allowsHitTesting(!airPlay.hostsHeadless)
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
            //
            // Minimized = foreground PiP (the only iPhone minimize): the
            // container used to stay laid out full screen with its opaque
            // black background and live hit-testing, covering the whole app
            // (device 2026-09-14, a751992). Hide it in place instead: opacity
            // 0 and no hit-testing, still mounted and at its fullscreen frame
            // so the AVPlayerLayer stays in the window for PiP and restore
            // animates back into the right rect. `hidesHost` covers the gap
            // before isMinimized and the close teardown after it.
            // AirPlay handoff (device test 2026-09-25): same hide-in-place
            // while the receiver plays, the tile keeps serving it.
            let hidden = nowPlaying.isMinimized || foregroundPiP.hidesHost || airPlay.hostsHeadless
            MultiviewContainerView()
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)
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
            // Settings tab: the mini stashes at the trailing edge unless
            // the user tapped the sliver to peek it back out.
            let stashed = minimized && selectedTab == .settings && !settingsMiniPeek
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
                        programSubtitle: PlayerInfoCardSettings.liveEpisodeTitle(forChannelID: item.id),
                        programDescription: PlayerInfoCardSettings.liveSynopsis(
                            forChannelID: item.id,
                            itemDescription: item.currentProgramDescription),
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
                                if stashed {
                                    settingsMiniPeek = true
                                } else {
                                    withAnimation(.spring(response: 0.35)) {
                                        nowPlaying.expand()
                                    }
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
                .modifier(MiniPlayerSettingsStash(stashed: stashed, travel: miniW + 24 - MiniPlayerSettingsStash.sliver))
            }
            .ignoresSafeArea()
            .zIndex(2)
        } else {
            let hiddenForPiP = nowPlaying.isMinimized || foregroundPiP.hidesHost
            GeometryReader { _ in
                PlayerView(
                    urls: item.streamURLs,
                    title: item.name,
                    headers: nowPlaying.playingHeaders,
                    isLive: nowPlaying.isLive,
                    subtitle: item.currentProgram,
                    subtitleStart: item.currentProgramStart,
                    subtitleEnd: item.currentProgramEnd,
                    programSubtitle: PlayerInfoCardSettings.liveEpisodeTitle(forChannelID: item.id),
                    programDescription: PlayerInfoCardSettings.liveSynopsis(
                        forChannelID: item.id,
                        itemDescription: item.currentProgramDescription),
                    artworkURL: item.logoURL,
                    onMinimize: { nowPlaying.minimize() },
                    onClose: { nowPlaying.stop() }
                )
                .id(item.id)
                .ignoresSafeArea()
                // Same hidden-in-place treatment as the unified iPhone host
                // (foreground PiP is the only iPhone minimize).
                .opacity(hiddenForPiP ? 0 : 1)
                .allowsHitTesting(!hiddenForPiP)
                .accessibilityHidden(hiddenForPiP)
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
    #if os(tvOS)
    #endif

    /// Play/Pause handler, pulled out of the `.onPlayPauseCommand` closure for
    /// exactly the reason `handleMenuPress` below was: inline, it trips Swift's
    /// type-inference budget ("unable to type-check this expression in
    /// reasonable time"). Xcode 27's checker accepts it, 26.6's does not - and
    /// App Store builds have to come from the RELEASE toolchain, so this has to
    /// compile on 26.6. A plain method gets its own scope and the budget resets.
    private func handlePlayPauseCommand() {
        #if os(tvOS)
        // Remote Control #196: the guide-context playPause slot
        // (default resumePlayer = expand the corner mini). A remap
        // dispatches its action; Do Nothing suppresses the press.
        guard nowPlaying.isMinimized else { return }
        let action = RemoteControlStore.shared.guideAction(.playPause)
        if action == .resumePlayer {
            debugLog("🎮 Play/Pause pressed: expand mini player to full screen")
            withAnimation(.spring(response: 0.35)) { nowPlaying.expand() }
        } else {
            GuideRemoteDispatch.perform(action)
        }
        #else
        guard nowPlaying.isMinimized else { return }
        debugLog("🎮 Play/Pause pressed: expand mini player to full screen")
        withAnimation(.spring(response: 0.35)) { nowPlaying.expand() }
        #endif
    }

    private func handleMenuPress() {
        debugLog("🎮 [HMP] handleMenuPress | isActive=\(nowPlaying.isActive) isMinimized=\(nowPlaying.isMinimized) isVODDetailPushed=\(isVODDetailPushed) isSettingsSubviewPushed=\(isSettingsSubviewPushed) selectedTab=\(selectedTab.rawValue) playerSession.mode=\(playerSession.mode)")
        // TEST (branch test/avplayer-hls-engine): if this handler runs
        // while the native AVPlayer cover is presented, focus is stuck
        // on the guide BEHIND the video (mode stays .idle on the native
        // path, so no other branch knows playback is active). Menu must
        // mean "close the player", not "navigate tabs behind it".
        if playerSession.nativeHLSItem != nil {
            debugLog("🎮 [HMP]   → branch: native player presented → dismissing it")
            playerSession.nativeHLSItem = nil
            return
        }
        #if os(tvOS)
        // The group drawer is the topmost surface while open: Back closes
        // it (reverting a previewed group), never the mini or a tab hop.
        if TVGuideSidebarState.shared.isOpen {
            debugLog("\u{1F3AE} [HMP]   \u{2192} branch: group drawer open \u{2192} closing it")
            NotificationCenter.default.post(name: .guideCloseGroupSidebar, object: nil)
            return
        }
        // In-place search is the topmost surface when up; Menu leaves it and
        // returns to the tab content, like Android's Back from Search.
        if showSearch {
            debugLog("\u{1F3AE} [HMP]   \u{2192} branch: in-place search up \u{2192} closing it")
            withAnimation(.easeOut(duration: 0.2)) { showSearch = false }
            return
        }
        #endif
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
        } else if isVODDetailPushed {
            // #42 fix: a pushed navigation submenu (VOD detail / Settings
            // subview) must pop BEFORE the mini-player Menu handling below —
            // otherwise, with a mini active, the mini's single/double-Back
            // debounce eats the press and you can't back out of the submenu.
            // Pop programmatically because `.onExitCommand` consumes Menu
            // before NavigationStack can handle it.
            debugLog("🎮 Menu pressed: VOD detail pushed → popping to browse list")
            isVODDetailPushed = false
            vodNavPopRequested = true
        } else if isSettingsSubviewPushed {
            // Same as VOD: pop the innermost pushed Settings level before the
            // mini-player handling. Our `.onExitCommand` intercepts Menu before
            // SettingsView's NavigationStack can pop, so signal SettingsView to
            // pop — classic stack first (ServerDetailView, MyRecordingsView),
            // then navPath (Appearance, Guide Display, Network, DVR, Developer,
            // Edit Server). SettingsView resets the flag.
            debugLog("🎮 Menu pressed: Settings subview pushed → popping")
            settingsPopRequested = true
        } else if nowPlaying.isActive && nowPlaying.isMinimized
                    && selectedTab != .liveTV {
            // Logan 2026-08-26: Back on another tab's ROOT (e.g. Settings)
            // with a mini playing must first return to the Live TV tab -
            // expanding immediately put the fullscreen player ON TOP of
            // Settings. The NEXT Back, now on Live TV, runs the expand
            // branch below. Same focus re-seat as the no-mini tab hop.
            debugLog("🎮 [HMP]   → branch: mini on \(selectedTab.rawValue) tab → switch to Live TV first")
            selectedTab = .liveTV
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .forceGuideFocus, object: nil)
            }
        } else if nowPlaying.isActive && nowPlaying.isMinimized {
            // #42 Part 3: with a mini-player active, a SINGLE Back restores it to
            // fullscreen; a DOUBLE Back jumps to the top channel (the long-press
            // route isn't viable — tvOS owns a held Menu). Debounce ~0.3s: the
            // expand is DEFERRED so the mini stays minimized during the window,
            // letting a quick second press land here and bump the count to 2.
            // Checked AFTER pushed navigation submenus (above) so Back can back
            // out of Settings/VOD while a mini plays. (Stopping playback now
            // lives only on the explicit close control.)
            nowPlaying.menuMiniPressCount += 1
            nowPlaying.menuMiniDebounce?.cancel()
            nowPlaying.menuMiniDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let isDouble = nowPlaying.menuMiniPressCount >= 2
                nowPlaying.menuMiniPressCount = 0
                if isDouble {
                    debugLog("🎮 [HMP]   → mini DOUBLE-Back → jump to top channel (#42 P3)")
                    NotificationCenter.default.post(name: .guideScrollToTop, object: nil)
                } else {
                    debugLog("🎮 [HMP]   → mini SINGLE-Back → expand to fullscreen (#42 P3)")
                    withAnimation(.spring(response: 0.35)) { nowPlaying.expand() }
                }
            }
        } else if selectedTab == .liveTV {
            // Menu on the guide (nothing playing, no mini) =
            // "take me back to the top of the list". Matches the
            // Apple TV / Music convention for long lists. Posted
            // as a notification so ChannelListView can scroll its
            // internal ScrollViewReader without HomeView having
            // to hold a binding through the tab view hierarchy.
            debugLog("🎮 Menu pressed: Live TV tab → scroll guide to top")
            NotificationCenter.default.post(name: .guideScrollToTop, object: nil)
        } else if tabBarScrollState.isHidden {
            // Movies & TV redesign: the tab scrolled its bar away. Menu
            // means "back to the top" there, same as the guide's
            // scroll-to-top above; the tab handles the notification.
            // Device log 2026-09-03: the tab's own .onExitCommand only
            // received the press the first time, so the decision lives
            // here, where every press arrives.
            debugLog("🎮 Menu pressed: " + selectedTab.rawValue + " tab scrolled → scroll to top")
            NotificationCenter.default.post(name: .aerioTabScrollToTop, object: nil,
                                            userInfo: ["tab": selectedTab.rawValue])
        } else if selectedTab.isMediaCenter {
            // Movies, TV Shows, DVR: Menu with the bar visible is "back to the top of
            // this tab" (close search, focus the hero), never a tab switch
            // (Logan 2026-09-04: Menu on the Search circle jumped to Live TV).
            debugLog("🎮 Menu pressed: " + selectedTab.rawValue + " tab at top → hero")
            NotificationCenter.default.post(name: .aerioTabScrollToTop, object: nil,
                                            userInfo: ["tab": selectedTab.rawValue])
        } else {
            let tabName = selectedTab.rawValue
            debugLog("🎮 Menu pressed: " + tabName + " tab → switch to Live TV")
            selectedTab = .liveTV
            // tvOS: switching tabs programmatically while focus is buried
            // in the outgoing tab's content strands focus in the Guide
            // with no path back up to the (auto-hidden) tab bar, so Up goes
            // dead, only Down works. Entering Live TV by selecting the tab
            // doesn't strand it because focus passes through the tab bar
            // on the way down. Re-post the guide's own focus claim so
            // ChannelListView / EPGGuideView run resetFocus(in:
            // guideFocusNS) and re-seat focus cleanly, which restores the
            // up-path to the tab bar. Deferred so the tab switch and the
            // guide's appearance settle before the focus reset fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .forceGuideFocus, object: nil)
            }
        }
    }
    #endif

    private func configureTabBarAppearance() {
        debugLog("🔶 MainTabView.configureTabBarAppearance: thread=\(Thread.current)")
#if os(iOS)
        // iOS 26: the system Liquid Glass bar owns its own backdrop. The
        // opaque pre-26 appearance below keeps PAINTING the bar's strip
        // after the system minimize shrinks the bar (user report
        // 2026-07-12: solid band left behind when scrolling), so never
        // install it there - content shows through / under the floating
        // bar exactly like the Android pill. TabView's .tint keeps the
        // selected item on the theme accent.
        if #available(iOS 26.0, *) { return }
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
    // #42 Part 4: gate the "Up/Down changes channels" hint on the same Settings
    // toggle that enables that gesture (default on).
    @AppStorage("appBehaviorsAppleTVChannelFlip") private var appleTVChannelFlip = true

    /// Local 5s window that opens on every `streamStartedToken`
    /// bump. Lets the banner appear on a Siri Remote channel-flip
    /// without dragging chrome up with it (chrome stays hidden so
    /// the next up/down keeps flipping channels instead of walking
    /// the bottom pills).
    @State private var bannerWindowActive: Bool = false
    /// Wall-clock timestamp of the most recent stream-start.
    /// Belt-and-suspenders against `bannerWindowActive` getting
    /// stranded `true` if the auto-hide Task is cancelled at an
    /// unfortunate moment (Apple TV report 2026-05-08: banner
    /// occasionally stuck visible until Menu/Back interaction).
    /// `shouldRender` reads this and a wall-clock comparison so
    /// the banner can never outlive the budget regardless of
    /// Task state.
    @State private var bannerOpenedAt: Date?

    /// Renders ONLY inside the wall-clock-capped window that opens on
    /// each stream start (`streamStartedToken`, bumped for every live
    /// start: cold-launch, row-tap, and Siri Remote flip). Suppressed
    /// in multi-tile multiview, when the player isn't actively
    /// fullscreen (minimized to the corner mini or stopped), and while
    /// the Stream Info overlay is open (on iPhone the two overlays share
    /// the top-left corner and would overlap).
    ///
    /// v1.7.3 dropped the `chromeIsVisible ||` coupling because that flag
    /// could stick `true` on an Apple TV cold-launch / auto-resume chrome
    /// desync and strand the banner visible for minutes (only Menu/Back,
    /// which re-toggled the flag, cleared it).
    ///
    /// #42 restores the coupling (so Select re-summons the card + hints
    /// alongside the chrome), but hardens the flag against the original
    /// stranding so it can't recur:
    ///   - `NowPlayingManager.stop()` / `minimize()` now reset it to false
    ///     (the .onChange mirrors only ever *set* it; they don't fire
    ///     `false` when their views unmount).
    ///   - the MultiviewContainerView mirror uses `.onChange(initial: true)`
    ///     so a fresh mount force-clears any value left stranded by the
    ///     previous mount (the cold-launch / resume desync above).
    /// The wall-clock `bannerWindowFresh` term still independently caps the
    /// tune-in appearance, so the banner is never worse off than v1.7.3.
    private var shouldRender: Bool {
        let isSingleStream = multiviewStore.tiles.count <= 1
        let isFullscreenActive = nowPlaying.isActive && !nowPlaying.isMinimized
        let bannerWindowFresh: Bool = {
            guard bannerWindowActive else { return false }
            guard let openedAt = bannerOpenedAt else { return false }
            return Date().timeIntervalSince(openedAt) < Self.bannerWindowSeconds
        }()
        // #42 Part 4: also show the card + hints whenever the chrome is summoned
        // via Select (not just the tune-in window). chromeIsVisible mirrors the
        // chrome's own 5s auto-fade, so the banner fades out together with it.
        return (bannerWindowFresh || nowPlaying.chromeIsVisible)
            && isSingleStream
            && isFullscreenActive
            && !nowPlaying.streamInfoIsVisible
    }

    /// 5-second budget for the post-stream-start banner window.
    /// Single source of truth: used by both the SwiftUI `.task(id:)`
    /// fader below and the wall-clock freshness check in
    /// `shouldRender`.
    private static let bannerWindowSeconds: TimeInterval = 5.0

    /// Resolve current program for this channel. First the
    /// lightweight `ChannelDisplayItem.currentProgram*` fields
    /// (cheap, populated for Xtream + Dispatcharr current-programs
    /// cache); fall back to `GuideStore.programs[id].first(where:
    /// \.isLive)` for the bulk-EPG path. Same two-source pattern
    /// `ChannelListView` uses for row subtitles. Returns nil when
    /// neither source has data — the banner then shows just channel
    /// number + name.
    // Settings > App Behaviors > Player Info Card (2026-09-15). Which
    // rows this card draws. Card-only: the guide, channel list, mini
    // player, Now Playing metadata and cast UI are untouched. All
    // default ON; @AppStorage so a flip re-renders live.
    @AppStorage(PlayerInfoCardSettings.channelLogoKey) private var showCardLogo = true
    @AppStorage(PlayerInfoCardSettings.channelNameKey) private var showCardChannelName = true
    @AppStorage(PlayerInfoCardSettings.programNameKey) private var showCardProgramName = true
    @AppStorage(PlayerInfoCardSettings.programTimeKey) private var showCardProgramTime = true
    @AppStorage(PlayerInfoCardSettings.programSubtitleKey) private var showCardProgramSubtitle = true
    @AppStorage(PlayerInfoCardSettings.programDescriptionKey) private var showCardProgramDescription = true

    private func liveProgram(for item: ChannelDisplayItem) -> (title: String, start: Date, end: Date)? {
        if let title = item.currentProgram, !title.isEmpty,
           let start = item.currentProgramStart,
           let end = item.currentProgramEnd {
            return (title, start, end)
        }
        if let p = guideStore.liveProgram(for: item.id) {
            return (p.title, p.start, p.end)
        }
        return nil
    }

    /// Episode title + synopsis for the live program (Android parity,
    /// 2026-09-15). `ChannelDisplayItem` carries a description but no
    /// episode title, so the subtitle always comes from the bulk-EPG
    /// store; the description prefers the item field (Xtream +
    /// Dispatcharr current-programs cache) and falls back to the store.
    /// Both are pre-trimmed, and a subtitle that just restates the
    /// title or the synopsis is dropped the way the guide drops it.
    private func liveProgramDetail(for item: ChannelDisplayItem)
        -> (subTitle: String, description: String) {
        let sub = PlayerInfoCardSettings.liveEpisodeTitle(forChannelID: item.id) ?? ""
        let desc = PlayerInfoCardSettings.liveSynopsis(
            forChannelID: item.id,
            itemDescription: item.currentProgramDescription) ?? ""
        return (sub, desc)
    }


    /// False when every Player Info Card row the user left on has
    /// nothing to draw, otherwise the card would render as an empty
    /// black pill. Missing data alone never suppresses the card (the
    /// channel row still carries number + name).
    private func hasCardContent(for item: ChannelDisplayItem) -> Bool {
        if showCardLogo, item.logoURL != nil { return true }
        if showCardChannelName || !item.number.isEmpty { return true }
        guard let prog = liveProgram(for: item) else { return false }
        if showCardProgramName { return true }
        if showCardProgramTime,
           airingTimeAndDuration(start: prog.start, end: prog.end) != nil { return true }
        let detail = liveProgramDetail(for: item)
        if showCardProgramSubtitle, !detail.subTitle.isEmpty { return true }
        if showCardProgramDescription, !detail.description.isEmpty { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shouldRender, let item = nowPlaying.playingItem, nowPlaying.isLive,
               hasCardContent(for: item) {
                VStack(alignment: .leading, spacing: 10) {
                    bannerContent(for: item)
                    // The legacy gesture hint chip stack that used to sit
                    // under this card is GONE (Logan 2026-09-11): the
                    // remote hint strip in the player chrome replaces it.
                }
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
        //
        // v1.7.x: replaced an `.onChange(of: streamStartedToken)`
        // with a manual Task by `.task(id:)` because Apple TV users
        // reported the banner occasionally getting stranded visible
        // (2026-05-08) — the manual Task could be cancelled mid-
        // window without its replacement running, leaving
        // `bannerWindowActive` stuck at `true` forever. SwiftUI's
        // `.task(id:)` is bound to view lifecycle and re-runs
        // deterministically when the id changes; combined with the
        // wall-clock freshness check in `shouldRender` (which uses
        // `bannerOpenedAt`), the banner can no longer outlive its
        // budget regardless of Task state.
        .task(id: nowPlaying.streamStartedToken) {
            guard nowPlaying.streamStartedToken != nil else { return }
            bannerOpenedAt = Date()
            bannerWindowActive = true
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.bannerWindowSeconds * 1_000_000_000))
                bannerWindowActive = false
            } catch {
                // Cancelled — view torn down or token changed.
                // The wall-clock check in `shouldRender` is the
                // backstop.
            }
        }
        .animation(.easeInOut(duration: 0.3), value: bannerWindowActive)
        .animation(.easeInOut(duration: 0.3), value: multiviewStore.tiles.count)
        // #42: when the chrome is summoned/dismissed via Select, fade the card
        // + hints in/out with it instead of popping. Same 0.3s curve as the
        // other two so overlapping triggers don't interleave into a stutter.
        .animation(.easeInOut(duration: 0.3), value: nowPlaying.chromeIsVisible)
    }

    @ViewBuilder
    private func bannerContent(for item: ChannelDisplayItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if item.logoURL != nil, showCardLogo {
                // v1.6.23: route through CachedLogoImage so the
                // active server's auth headers are applied (fixes
                // Dispatcharr-API logo 401 → blank-logo regression).
                // The info card itself is a 14pt continuous rounded rect,
                // so the logo takes 14 rather than its old fixed 6.
                CachedLogoImage(url: item.logoURL, width: logoSize, height: logoSize,
                                containerRadius: 14)
            }

            VStack(alignment: .leading, spacing: 3) {
                // The channel number rides with the name row: with
                // Channel Name off and no number there is nothing to
                // draw, so the whole row (and its VStack gap) goes.
                if showCardChannelName || !item.number.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if !item.number.isEmpty {
                            Text(item.number)
                                .scaledFont(channelNumberFont)
                                .foregroundColor(.white.opacity(0.55))
                        }
                        if showCardChannelName {
                            Text(item.name)
                                .scaledFont(channelNameFont)
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                    }
                }

                if let prog = liveProgram(for: item) {
                    if showCardProgramName {
                        Text(prog.title)
                            .scaledFont(programFont)
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                    }

                    if showCardProgramTime,
                       let timeAndDuration = airingTimeAndDuration(start: prog.start, end: prog.end) {
                        Text(timeAndDuration)
                            .scaledFont(timeFont)
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }

                    // Episode title + synopsis (Android parity). Each is
                    // its own toggle and is skipped entirely when the feed
                    // has nothing, so the card never grows a blank gap.
                    let detail = liveProgramDetail(for: item)
                    if showCardProgramSubtitle, !detail.subTitle.isEmpty {
                        Text(detail.subTitle)
                            .scaledFont(subtitleFont)
                            .italic()
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    if showCardProgramDescription, !detail.description.isEmpty {
                        Text(detail.description)
                            .scaledFont(descriptionFont)
                            .foregroundColor(.white.opacity(0.62))
                            .lineLimit(descriptionLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
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
        let f = ClockFormat.short()
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
    private var channelNumberFont: AerioFont {
        #if os(tvOS)
        return .system(size: 26, weight: .medium)
        #else
        return .system(size: 15, weight: .medium)
        #endif
    }
    private var channelNameFont: AerioFont {
        #if os(tvOS)
        return .system(size: 28, weight: .semibold)
        #else
        return .system(size: 16, weight: .semibold)
        #endif
    }
    private var programFont: AerioFont {
        #if os(tvOS)
        return .system(size: 22)
        #else
        return .system(size: 14)
        #endif
    }
    private var timeFont: AerioFont {
        #if os(tvOS)
        return .system(size: 18)
        #else
        return .system(size: 12)
        #endif
    }
    /// Episode title: subtext-scaled + italic, the app's convention for
    /// episode titles in the guide and the Program Info sheet.
    private var subtitleFont: AerioFont {
        #if os(tvOS)
        return .system(size: 20, weight: .medium).subtext()
        #else
        return .system(size: 13, weight: .medium).subtext()
        #endif
    }
    /// Synopsis: the smallest row on the card.
    private var descriptionFont: AerioFont {
        #if os(tvOS)
        return .system(size: 17).subtext()
        #else
        return .system(size: 11).subtext()
        #endif
    }
    private var descriptionLineLimit: Int {
        #if os(tvOS)
        return 3
        #else
        return 2
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

#endif

// MARK: - Tab bar auto-hide (GH #20) platform split

extension View {
    /// iOS 26+: turn the system's Liquid Glass minimize-on-scroll OFF for
    /// the tab bar so the manual scroll-away toggle can own it - see
    /// `scrollAwayTabBar(collapsed:)`. No-op on tvOS and on iOS 18-25.
    @ViewBuilder
    func aerioTabBarAutoMinimize() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // .never (2026-07-12, user request): no minimized pill at all.
            // This also disengages the system minimize state machine, which
            // was the second owner of the bar that made the manual
            // hidden/visible toggle stick at hidden (field report
            // 2026-07-11). With minimize off, the toolbarVisibility toggle
            // in scrollAwayTabBar is the bar's sole authority and restores
            // reliably - full Android behavior: bar hides on scroll down,
            // full bar returns on any scroll up.
            // 2026-09-09 trial (Logan, iPhone scroll "catch" on the first
            // scroll up after a deep dive): the manual hidden/visible toggle
            // changes the scroll view's bottom inset when the bar returns,
            // which reflows the grid mid-gesture. The system minimize keeps
            // the inset constant, so the bar shrinks and grows with no
            // content movement. scrollAwayTabBar is a no-op while this is
            // on; revert both if the minimized pill is not wanted.
            // 2026-09-09 (Logan, verified on a bare TabView through iPhone
            // Mirroring): the system minimize only re-expands at the top of
            // the content on this iOS build, so the bar is ours again: the
            // tabs' scroll trackers feed TabBarCollapseState (hide after 48 pt
            // down, show after 12 pt up, like Android) and this modifier
            // toggles the bar; MinimizedTabButton draws the corner pill.
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// Scroll-driven tab bar hide used by ChannelListView / EPGGuideView /
    /// MoviesView / TVShowsView. Two states only, like the Android bottom
    /// nav: full bar or no bar.
    ///
    /// History: on iOS 26 this used to be a no-op because the manual toggle
    /// fought the system minimize behavior - with `.onScrollDown` active,
    /// `.hidden` collapsed the bar into the minimize machinery and the
    /// subsequent `.visible` could never re-expand it (field report
    /// 2026-07-11), while `.visible` also pinned a blank layout band
    /// (2026-07-12). Since `aerioTabBarAutoMinimize` now sets
    /// `.tabBarMinimizeBehavior(.never)`, that second owner is gone and
    /// this toggle is the bar's SOLE authority on 26+, so it hides and
    /// restores reliably. `toolbarVisibility` is the sanctioned iOS 26
    /// spelling; 18-25 keep the original `toolbar` call. No-op on tvOS
    /// (no call sites; the tvOS tab bar is system-managed at the top).
    @ViewBuilder
    func scrollAwayTabBar(collapsed: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // System minimize owns the bar on 26+ (aerioTabBarAutoMinimize);
            // toggling visibility here changed the bottom inset and reflowed
            // the content on every show (2026-09-09). The collapsed flag
            // still feeds TabBarCollapseState so the Control-a-TV button can
            // drop level with the minimized pill (Logan 2026-09-09).
            self.onChange(of: collapsed, initial: true) { _, c in TabBarCollapseState.shared.set(c) }
        } else {
            self.toolbar(collapsed ? .hidden : .visible, for: .tabBar)
        }
        #else
        self
        #endif
    }

    /// iOS 26: keep scroll content visible all the way to the display's
    /// bottom edge under the floating tab bar. The system's automatic
    /// bottom scroll-edge effect resolves to the HARD style on these
    /// screens (an opaque platter in the scroll background color), which
    /// paints OVER the rows in the bar region - UIKit lays the cells out
    /// (verified on device: visible cell maxY past the window bottom) but
    /// the effect covers them, reading as a dead band above the home
    /// indicator (GH #20 follow-up, user report 2026-07-12). Hiding the
    /// bottom effect lets rows show through, matching the Android pill.
    /// No-op pre-26 and on tvOS.
    /// iOS 26: no hairline where content scrolls under the status bar
    /// (Logan 2026-09-05: the line above Continue Watching once the
    /// navigation bar was gone). No-op pre-26 and on tvOS.
    @ViewBuilder
    func aerioNoTopScrollEdge() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func aerioContentUnderTabBar() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Direction tracker for the scroll-away tab bar (2026-07-12, Android
/// parity): the bar hides after ~48pt of deliberate downward scrolling and
/// the FULL bar returns after ~12pt of ANY upward scrolling, mirroring the
/// Android MainScaffold NestedScrollConnection thresholds. This replaces
/// the old position-based 80/20 rule for the BAR (the group pills keep it),
/// which only restored the bar near the top of the list instead of on any
/// upward scroll. A direction flip resets the opposite accumulator so slow
/// jittery drags near a threshold can't oscillate the bar. Guards: a hide
/// only triggers past 48pt of content offset so the settle-back from a
/// rubber-band overscroll (pull-to-refresh) can't count as a hide, and
/// resting near the top always reveals. Reference type on purpose: the
/// accumulators are gesture bookkeeping, not display state, so mutating
/// them must not re-render the view.
extension View {
    /// Observing overload: the flag is read inside the modifier's OWN body,
    /// so a scroll that tucks the bar away does not invalidate the list that
    /// owns the state (Logan 2026-09-16, iPhone flick hiccup).
    func scrollAwayTabBar(observing chrome: ListScrollChrome) -> some View {
        modifier(ScrollAwayTabBarModifier(chrome: chrome))
    }
}

/// Reads `ListScrollChrome.isTabBarAway` in its own body, so only this
/// modifier re-renders when the bar tucks away. See `scrollAwayTabBar`.
private struct ScrollAwayTabBarModifier: ViewModifier {
    let chrome: ListScrollChrome

    func body(content: Content) -> some View {
        content.scrollAwayTabBar(collapsed: chrome.isTabBarAway)
    }
}

final class TabBarScrollTracker {
    private var hideDistance: CGFloat = 0
    private var showDistance: CGFloat = 0
    private var lastFlip = Date.distantPast

    /// Feed consecutive scroll offsets from onScrollGeometryChange.
    /// Returns the new hidden state when it should change, nil otherwise.
    ///
    /// Hiding or showing the bar changes the scroll view's insets, which
    /// moves contentOffset by itself; read as a scroll in the opposite
    /// direction that flipped the bar straight back, and with the phone's
    /// navigation bar gone the two toggles fed each other every frame
    /// (Movies froze, profiler 2026-09-05 16:44). Offsets are ignored while
    /// a toggle settles, and a jump far larger than a finger moves in one
    /// frame is treated as programmatic.
    func update(oldY: CGFloat, newY: CGFloat, hidden: Bool) -> Bool? {
        let now = Date()
        if now.timeIntervalSince(lastFlip) < 0.45 { return nil }
        let dy = newY - oldY
        if abs(dy) > 120 {
            hideDistance = 0; showDistance = 0
            return nil
        }
        var result: Bool? = nil
        if dy > 0.5 {
            hideDistance += dy
            showDistance = 0
            if !hidden && hideDistance > 48 && newY > 48 { result = true }
        } else if dy < -0.5 {
            showDistance += -dy
            hideDistance = 0
            if hidden && showDistance > 12 { result = false }
        }
        if result == nil, hidden, newY < 20 { result = false }
        if let result {
            lastFlip = now
            hideDistance = 0; showDistance = 0
            debugLog("[TABBAR] auto-hide -> \(result ? "hidden" : "shown") y=\(Int(newY)) dy=\(Int(dy))")
        }
        return result
    }
}
#endif

#if os(iOS)
/// Whether the scrolling tab has collapsed the tab bar (iOS 26 minimizes it
/// to a small pill at the leading edge). Observed ONLY by the Control-a-TV
/// dock below, never by the tab views, so the per-scroll publish cannot
/// re-render a tab body (see the scroll-churn rule).
@MainActor
final class TabBarCollapseState: ObservableObject {
    static let shared = TabBarCollapseState()
    @Published private(set) var collapsed = false
    func set(_ value: Bool) {
        guard collapsed != value else { return }
        collapsed = value
        applyToSystemBar()
    }

    /// Slides the UIKit tab bar off screen instead of hiding it through the
    /// toolbar API: hiding it changed the tabs' scroll container by 49 pt on
    /// every toggle ([JUMP] log 2026-09-09, container 873 <-> 922), which read
    /// as a scroll jump. A transform leaves layout and insets untouched.
    private func applyToSystemBar() {
        let bars = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .flatMap { Self.tabBars(in: $0) }
        let hide = collapsed
        for bar in bars {
            guard let window = bar.window, let superview = bar.superview else { continue }
            // Mini button: 48 pt at x 28, bottom 6 pt below the safe-area
            // edge (MinimizedTabButton). The bar collapses right-to-left
            // INTO it (Logan 2026-09-09): anchor the bar on the button's
            // centre, then scale toward that anchor while the far end fades.
            let frame = superview.convert(bar.frame, to: window)
            let target = CGPoint(x: 28 + 24,
                                 y: window.bounds.height - window.safeAreaInsets.bottom + 6 - 24)
            if hide {
                let ax = ((target.x - frame.minX) / max(frame.width, 1)).clamped(to: 0...1)
                let ay = ((target.y - frame.minY) / max(frame.height, 1)).clamped(to: 0...1)
                Self.setAnchor(bar, CGPoint(x: ax, y: ay))
                let sx = 48 / max(frame.width, 1), sy = 48 / max(frame.height, 1)
                UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                    bar.transform = CGAffineTransform(scaleX: sx, y: sy)
                }
                UIView.animate(withDuration: 0.14, delay: 0.16, options: [.curveEaseIn, .beginFromCurrentState]) {
                    bar.alpha = 0
                }
            } else {
                UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
                    bar.transform = .identity
                }, completion: { _ in
                    if !self.collapsed { Self.setAnchor(bar, CGPoint(x: 0.5, y: 0.5)) }
                })
                UIView.animate(withDuration: 0.14, delay: 0.02, options: [.curveEaseOut, .beginFromCurrentState]) {
                    bar.alpha = 1
                }
            }
        }
    }

    /// Moves the layer anchor without moving the view on screen.
    private static func setAnchor(_ v: UIView, _ anchor: CGPoint) {
        let old = v.layer.anchorPoint
        guard old != anchor else { return }
        let size = v.bounds.size
        let dx = (anchor.x - old.x) * size.width, dy = (anchor.y - old.y) * size.height
        let t = v.transform
        v.transform = .identity
        v.layer.anchorPoint = anchor
        v.center = CGPoint(x: v.center.x + dx, y: v.center.y + dy)
        v.transform = t
    }

    private static func tabBars(in root: UIView) -> [UITabBar] {
        var out: [UITabBar] = []
        func walk(_ v: UIView) {
            if let bar = v as? UITabBar { out.append(bar); return }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }
}

/// Geometry for the remote-session (cast) card, measured from the LIVE view
/// hierarchy instead of guessed. The card used to ride a `safeAreaInset` on the
/// outer ZStack, which the UITabBarController-backed TabView ignores (it puts
/// its bar at the bottom of its own bounds) and which every tab's
/// `ignoresSafeArea(.container, edges: .bottom)` scroll view ignores too, so the
/// card landed ON the tab labels (Logan's iPhone, iOS 27, 2026-09-12).
@MainActor
final class RemoteSessionCardMetrics: ObservableObject {
    static let shared = RemoteSessionCardMetrics()

    /// Clearance between the card and the tab bar (Logan 2026-09-12): a small
    /// 6 pt gap, matching the Android card, not a void.
    static let gap: CGFloat = 6

    /// Top edge of the system tab bar in WINDOW coordinates, 0 until measured.
    @Published private(set) var tabBarTopInWindow: CGFloat = 0

    /// Card height including its own margins, for the tabs' bottom content
    /// inset so the last row can scroll clear of the card.
    @Published private(set) var contentInset: CGFloat = 0

    private var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    /// Reads the bar's UNTRANSFORMED top edge: `TabBarCollapseState` collapses
    /// the bar with a layer transform AND moves its anchor point, so `frame`
    /// and `center` both lie while it is minimized. Deriving the origin from
    /// `layer.position` and `layer.anchorPoint` keeps the card still during a
    /// collapse instead of sliding it down with the shrinking bar.
    func measureTabBar() {
        guard let window,
              let bar = Self.firstTabBar(in: window),
              let superview = bar.superview,
              bar.bounds.height > 0 else { return }
        let layer = bar.layer
        let originY = layer.position.y - layer.anchorPoint.y * bar.bounds.height
        let top = superview.convert(CGPoint(x: 0, y: originY), to: window).y
        guard top > 0 else { return }
        if abs(top - tabBarTopInWindow) > 0.5 { tabBarTopInWindow = top }
    }

    func setCardHeight(_ height: CGFloat) {
        let value = height > 1 ? height : 0
        if abs(value - contentInset) > 0.5 { contentInset = value }
    }

    private static func firstTabBar(in root: UIView) -> UITabBar? {
        if let bar = root as? UITabBar { return bar }
        for sub in root.subviews {
            if let bar = firstTabBar(in: sub) { return bar }
        }
        return nil
    }
}

/// Pins the cast card 8 pt above the measured tab bar on every tab. A
/// `GeometryReader` gives the dock's own bottom edge in window coordinates, so
/// the lift is `(dock bottom - bar top) + 8` and needs no assumption about
/// whether the container is safe-area inset.
private struct RemoteSessionCardDock<Content: View>: View {
    @ObservedObject private var metrics = RemoteSessionCardMetrics.shared
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            let dockBottom = geo.frame(in: .global).maxY
            let barTop = metrics.tabBarTopInWindow
            // Not measured yet: fall back to the stock 49 pt bar plus the home
            // indicator so the first frame is never ON the bar.
            let lift = barTop > 0
                ? max(RemoteSessionCardMetrics.gap, dockBottom - barTop + RemoteSessionCardMetrics.gap)
                : 49 + geo.safeAreaInsets.bottom + RemoteSessionCardMetrics.gap
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        RemoteSessionCardMetrics.shared.setCardHeight(height)
                    }
                    .padding(.bottom, lift)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .onAppear { metrics.measureTabBar() }
            .onChange(of: geo.size) { _, _ in metrics.measureTabBar() }
            .task {
                // The bar may not be in the hierarchy yet on the first frame.
                metrics.measureTabBar()
                try? await Task.sleep(nanoseconds: 400_000_000)
                metrics.measureTabBar()
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(true)
    }
}

/// Bottom content inset the cast card needs so a list's last row can scroll
/// clear of it. Applied ONCE on the TabView: `contentMargins` rides the
/// environment, so every tab's scroll view picks it up, and it is 0 whenever no
/// card is showing (no behavior change without a session).
private struct RemoteCardContentInset: ViewModifier {
    @ObservedObject private var metrics = RemoteSessionCardMetrics.shared
    func body(content: Content) -> some View {
        content.contentMargins(.bottom, metrics.contentInset, for: .scrollContent)
    }
}

extension View {
    func aerioRemoteCardContentInset() -> some View {
        modifier(RemoteCardContentInset())
    }
}

/// Our own minimized tab button: the 48 pt glass circle the system used to
/// draw (measured 2026-09-09: x 28, bottom 6 pt below the safe-area edge),
/// carrying the selected tab's icon. Tap to bring the bar back.
private struct MinimizedTabButton: View {
    @ObservedObject private var collapse = TabBarCollapseState.shared
    @ObservedObject private var theme: ThemeManager = .shared
    let tab: AppTab
    var body: some View {
        if #available(iOS 26.0, *) {
            Button { TabBarCollapseState.shared.set(false) } label: {
                Image(systemName: tab.icon)
                    .font(.system(size: 19, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                    .foregroundStyle(theme.accent)
                    .frame(width: 48, height: 48)
            }
            .glassEffect(.regular, in: Circle())
            .padding(.leading, 28)
            .padding(.bottom, -6)
            .opacity(collapse.collapsed ? 1 : 0)
            .scaleEffect(collapse.collapsed ? 1 : 0.6)
            .allowsHitTesting(collapse.collapsed)
            .animation(.easeInOut(duration: 0.2), value: collapse.collapsed)
            .accessibilityLabel("Show tab bar")
        }
    }
}

/// Hosts the Control-a-TV FAB above the right end of the full tab bar and,
/// once the bar has minimized, level with the minimized pill on the left so
/// the two corners match (Logan 2026-09-09).
private struct CompanionControlFABDock: View {
    @ObservedObject private var collapse = TabBarCollapseState.shared
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    var body: some View {
        CompanionControlFAB(action: action)
            // Minimized system button measured from the view hierarchy
            // ([TABBAR] dump 2026-09-09): 48 pt circle at x 28, bottom edge
            // 6 pt below the safe-area edge. Mirror it on the trailing side.
            .padding(.trailing, collapse.collapsed ? 28 : 20)
            .padding(.bottom, collapse.collapsed ? -6 : 52)
            .animation(.easeInOut(duration: 0.2), value: collapse.collapsed)
    }
}
#endif


private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

/// Slides the floating corner mini player (tvOS, iPad) mostly off the trailing
/// edge while the Settings tab is selected, leaving a sliver so it reads as
/// stashed rather than gone. Playback is untouched; only the offset changes.
/// Reduce Motion swaps the slide for a quick fade in at the new position.
struct MiniPlayerSettingsStash: ViewModifier {
    /// Width of the video left on screen while stashed.
    static let sliver: CGFloat = 32

    let stashed: Bool
    /// Distance to slide right: mini width + trailing inset - sliver.
    let travel: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fadeOpacity: Double = 1

    func body(content: Content) -> some View {
        content
            .offset(x: stashed ? travel : 0)
            .opacity(fadeOpacity)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86), value: stashed)
            .onChange(of: stashed) { _, _ in
                guard reduceMotion else { return }
                var jump = Transaction()
                jump.disablesAnimations = true
                withTransaction(jump) { fadeOpacity = 0 }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) { fadeOpacity = 1 }
                }
            }
    }
}
