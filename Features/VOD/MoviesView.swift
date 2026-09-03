import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

// MARK: - Authenticated Poster Image
// AsyncImage can't send auth headers. Dispatcharr's /media/ endpoints are protected,
// so we fetch with URLSession + the server's API key and cache in NSCache.

private final class AuthImageCache: @unchecked Sendable {
    static let shared = AuthImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 300 }
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

struct AuthPosterImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    /// GH #53: reports the loaded image's pixel size so callers that
    /// frame the poster (Program Info) can follow the REAL aspect ratio
    /// instead of hard-cropping landscape EPG art into a 2:3 portrait
    /// frame. nil callers (grids with uniform poster cells) are unchanged.
    var onImageLoaded: ((CGSize) -> Void)? = nil
    /// Painted until the image arrives. The Movies hero passes .clear so
    /// nothing shows through its fade while the backdrop loads.
    var placeholder: Color = .cardBackground

    @State private var uiImage: UIImage? = nil

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img).resizable()
            } else {
                placeholder
            }
        }
        // Keyed on url + the active effective host so a LAN/WAN probe flip
        // re-attempts covers that failed under the previous routing.
        .task(id: (url?.absoluteString ?? "") + "|" + (ChannelStore.shared.activeServer?.effectiveBaseURL ?? "")) {
            guard let url else { return }
            let key = url.absoluteString
            if let cached = AuthImageCache.shared.image(for: key) {
                uiImage = cached
                onImageLoaded?(cached.size)
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 20)
            // SECURITY: attach the server's credential headers ONLY when the
            // image is on one of the configured server's OWN hosts (public
            // base + LAN local). A malicious backend can return a poster URL
            // pointing at an attacker host; without this gate the Dispatcharr
            // X-API-Key / Authorization would be sent there and harvested.
            // Foreign posters (TMDB / CDN) are public and load with no
            // headers. v1.7.9 regression fix: the old check compared against
            // the SINGLE `effectiveBaseURL` host at render time, but poster
            // URLs are built at fetch time and the effective host flips
            // between local/public per TVLANProbe - dual-URL setups routinely
            // diverged, headers were withheld, and every cover 401'd blank.
            let allowedHosts = ChannelStore.shared.activeServer?.ownHosts ?? []
            VODService.registerOwnHosts(allowedHosts)
            if let host = url.host?.lowercased(), allowedHosts.contains(host) {
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            } else if !headers.isEmpty {
                // Diagnostics for the next covers report: one grep-able line
                // that says exactly why credentials were withheld.
                debugLog("🖼️ AuthPosterImage: headers WITHHELD host=\(url.host?.lowercased() ?? "nil") trusted=\(allowedHosts.sorted().joined(separator: ","))")
            }
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  // GH #61: decode accepts SVG artwork in addition to bitmaps.
                  let img = AerioImageDecoding.decode(data) else { return }
            AuthImageCache.shared.store(img, for: key)
            guard !Task.isCancelled else { return }
            uiImage = img
            onImageLoaded?(img.size)
        }
    }
}

// MARK: - Movies View
struct MoviesView: View {
    @ObservedObject var vodStore: VODStore
    @Query private var servers: [ServerConnection]
    @Binding var isPlaying: Bool
    @Binding var isDetailPushed: Bool
    @Binding var popRequested: Bool

    @State private var searchText = ""
    @State private var hiddenGroups: Set<String> = []
    @State private var showManageGroups = false
    #if os(iOS)
    /// GH #20 (Android parity): auto-hide the iPhone tab bar while the
    /// poster grid scrolls down; any upward scroll reveals it
    /// (TabBarScrollTracker). Phone-gated in the observer, so iPad
    /// keeps its bar.
    @State private var gridTabBarHidden = false
    @State private var tabBarTracker = TabBarScrollTracker()
    #endif
    @State private var navPath = NavigationPath()
    #if os(tvOS)
    @State private var showSearchField = false
    @State private var showSortMenu = false
    @State private var showFilterMenu = false
    @State private var searchFieldFocused = false
    #endif
    @State private var resumePlayingURL: IdentifiableURL?
    @State private var resumePlayingTitle = ""
    @State private var resumePlayingHeaders: [String: String] = [:]
    @State private var resumeVodID: String?
    @State private var resumePosterURL: String?
    @State private var resumeServerID: String?
    @State private var resumePositionMs: Int32 = 0
    /// Continue Watching version switching (ATV log 2026-08-17). Populated
    /// best-effort as the resume cover mounts so the in-player Switch Version
    /// list matches what the detail page offers for the same title.
    @State private var resumeVersionOptions: [VODVersionOption] = []
    @State private var resumeVersionSelectionKey: String = ""

    private let hiddenGroupsKey = "hiddenMovieGroups"

    // Movies tab redesign (2026-09): hero + shelves + library grid.
    /// Unfinished watch progress, newest first; filtered to movies on the
    /// active playlist below. Same query ContinueWatchingSection runs, held
    /// here too so the hero can lead with the newest resume point.
    @Query(
        filter: #Predicate<WatchProgress> { !$0.isFinished },
        sort: \WatchProgress.updatedAt, order: .reverse
    ) private var allProgress: [WatchProgress]
    @AppStorage("moviesSortOrder") private var sortOrderRaw = MoviesSortOrder.titleAZ.rawValue
    /// Genre pill selection; nil = All. Not persisted: a filter that
    /// silently survives a relaunch reads as "my movies vanished".
    @State private var selectedGenre: String? = nil
    /// Library grid's top edge in scroll-view coordinates. The alphabet
    /// rail rides with it, then sticks once it reaches the top inset.
    /// nil until the first measurement: the rail stays hidden until then so
    /// it cannot flash at the top of the tab for a frame on tab switch.
    @State private var gridTopY: CGFloat? = nil
    #if os(tvOS)
    /// tvOS: the tab bar hides once the library scrolls past the top so
    /// the grid gets the whole screen; it returns near the top.
    @State private var tvTabBarHidden = false
    #endif

    /// User-tunable UI scale (0.85–1.25). Only consumed on iPad / Mac Catalyst
    /// where the default 120 px minimum can feel cramped on wide displays;
    /// iPhone grids stay at their designed minimums (user scale is a no-op in
    /// the ternary below), and tvOS ignores the setting entirely.
    @AppStorage("uiScale") private var uiScale: Double = 1.0

    #if os(tvOS)
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 32)]
    }
    private let gridRowSpacing: CGFloat = 48
    #else
    private var columns: [GridItem] {
        // On iPhone the phone-sized minimum is always used. On iPad / Mac the
        // user's uiScale slider stretches the minimum so posters read larger.
        let clamped = max(0.85, min(1.25, uiScale))
        let isRegular = UIDevice.current.userInterfaceIdiom != .phone
        let minimum: CGFloat = isRegular ? 120 * clamped : 120
        let maximum: CGFloat = isRegular ? 160 * clamped : 160
        return [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: 12)]
    }
    private let gridRowSpacing: CGFloat = 16
    #endif

    /// Auth headers for the active Dispatcharr server — used by AuthPosterImage.
    private var dispatcharrHeaders: [String: String] {
        guard let s = servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI && $0.isActive })
                   ?? servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI })
        else { return [:] }
        return s.authHeaders
    }

    private var filteredMovies: [VODDisplayItem] {
        if !searchText.isEmpty {
            var combined = vodStore.movies.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            let localIDs = Set(combined.map { $0.id })
            combined += vodStore.movieSearchResults.filter { !localIDs.contains($0.id) }
            return combined
        }
        var result = vodStore.movies
        // Exclude movies belonging to hidden groups
        if !hiddenGroups.isEmpty {
            result = result.filter { item in
                guard let cat = item.movie?.categoryName else { return true }
                return !hiddenGroups.contains(cat)
            }
        }
        return result
    }

    /// Whether the navigation stack is at root (no detail pushed).
    var isAtRoot: Bool { navPath.isEmpty }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if vodStore.isLoadingMovies && vodStore.movies.isEmpty {
                    LoadingView(message: "Loading movies…")
                } else if let err = vodStore.moviesError, vodStore.movies.isEmpty {
                    errorView(err)
                } else if vodStore.movies.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationDestination(for: VODDisplayItem.self) { item in
                VODDetailView(item: item, isPlaying: $isPlaying)
            }
            #if os(iOS)
            // No .navigationTitle on iOS — OnDemandView hosts the
            // Movies / Series pill selector above this view and the
            // pills serve as the section identifier. A title here
            // would duplicate the header.
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            #if os(tvOS)
            // Assert the tab bar visible at the grid root so popping a pushed
            // VODDetailView (which hides it) restores it on tvOS 27. Hidden
            // while the library is scrolled down (Logan 2026-09-03: the grid
            // gets the whole screen); scrolling back near the top restores it.
            .toolbar(tvTabBarHidden ? .hidden : .visible, for: .tabBar)
            #endif
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showManageGroups = true
                    } label: {
                        Text("Filter")
                            .font(.headlineSmall)
                            .foregroundColor(.accentPrimary)
                    }
                }
            }
            #endif
            #if os(iOS)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search movies")
            #endif
            .onAppear {
                hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                // v1.6.22: same guard as TVShowsView.onAppear. The
                // previous `movies.isEmpty && !isLoadingMovies`
                // check re-fired refreshMovies every time SwiftUI
                // rebuilt the view after a legitimately-empty load,
                // producing a refresh loop. Compare the active
                // server's id to `currentMoviesServerID` (set when
                // a load begins) so we tell "fresh server" from
                // "already tried this server, server has no
                // movies". Pull-to-refresh and the Try Again
                // button still bypass this guard.
                let activeServerID = (servers.first(where: { $0.isActive }) ?? servers.first)?.id
                let alreadyTriedThisServer = activeServerID != nil
                    && vodStore.currentMoviesServerID == activeServerID
                if vodStore.movies.isEmpty
                    && !vodStore.isLoadingMovies
                    && !alreadyTriedThisServer {
                    vodStore.refreshMovies(servers: servers)
                }
            }
            .sheet(isPresented: $showManageGroups) {
                ManageGroupsSheet(
                    title: "Manage Groups",
                    allGroups: vodStore.movieCategories.map(\.name),
                    storageKey: hiddenGroupsKey,
                    onDismiss: { updated in
                        hiddenGroups = updated
                    }
                )
            }
            .refreshable {
                vodStore.refreshMovies(servers: servers)
                // Allow the task one tick to start so isLoadingMovies flips to true first.
                try? await Task.sleep(for: .milliseconds(50))
                while vodStore.isLoadingMovies {
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            .onChange(of: searchText) { _, query in
                // Fire server-side search so items not yet locally fetched are found.
                vodStore.searchMovies(query: query, servers: servers)
            }
            .onChange(of: navPath) { _, path in
                isDetailPushed = !path.isEmpty
            }
            .onChange(of: popRequested) { _, pop in
                if pop && !navPath.isEmpty {
                    navPath.removeLast()
                    popRequested = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .syncManagerDidApplyPreferences)) { _ in
                // Reload hidden groups from UserDefaults after an iCloud sync applies remote prefs.
                hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
            }
            #if os(tvOS)
            // Top Shelf deep link for a movie → navigate to its detail view.
            // Warm-launch path: app is already in memory, movies are loaded,
            // notification fires. Cold-launch path below (in onChange) catches
            // the case where movies arrive AFTER the deep link was received.
            .onReceive(NotificationCenter.default.publisher(for: .aerioOpenVOD)) { notif in
                guard let vodType = notif.userInfo?["vodType"] as? String, vodType == "movie",
                      let vodID = notif.userInfo?["vodID"] as? String else { return }
                tryHandleMovieDeepLink(id: vodID, from: vodStore.movies)
            }
            .onChange(of: vodStore.movies) { _, movies in
                // Cold-launch path: deep link stored launchVODID in UserDefaults,
                // and now the movies list just finished loading.
                guard UserDefaults.standard.string(forKey: "launchVODType") == "movie",
                      let pendingID = UserDefaults.standard.string(forKey: "launchVODID") else { return }
                tryHandleMovieDeepLink(id: pendingID, from: movies)
            }
            #endif
            .fullScreenCover(item: $resumePlayingURL) { wrapper in
                PlayerView(
                    urls: [wrapper.url],
                    title: resumePlayingTitle,
                    headers: resumePlayingHeaders,
                    isLive: false,
                    artworkURL: resumePosterURL.flatMap { URL(string: $0) },
                    vodID: resumeVodID,
                    vodPosterURL: resumePosterURL,
                    vodServerID: resumeServerID,
                    vodType: "movie",
                    resumePositionMs: resumePositionMs,
                    vodVersionOptions: resumeVersionOptions,
                    vodSelectedVersionID: VODVersionSelectionStore
                        .selection(forKey: resumeVersionSelectionKey),
                    vodVersionSelectionKey: resumeVersionSelectionKey
                )
                .onDisappear { isPlaying = false }
            }
        }
    }

    #if os(tvOS)
    /// Looks up a movie by ID in the given list and pushes its detail view
    /// onto the nav stack. Clears any existing detail first so repeated
    /// deep links don't stack. Clears the UserDefaults deep-link markers
    /// on success so the cold-launch handler doesn't re-fire later.
    private func tryHandleMovieDeepLink(id: String, from movies: [VODDisplayItem]) {
        guard let item = movies.first(where: { $0.id == id }) else { return }
        UserDefaults.standard.removeObject(forKey: "launchVODID")
        UserDefaults.standard.removeObject(forKey: "launchVODType")
        UserDefaults.standard.removeObject(forKey: "launchOnMovies")
        debugLog("🔗 MoviesView: deep link → pushing \(item.name)")
        navPath = NavigationPath()
        navPath.append(item)
    }
    #endif

    private func resumeFromContinueWatching(_ progress: WatchProgress) {
        // If we have a stored stream URL, launch playback directly with the saved position
        if let urlStr = progress.streamURL, let url = URL(string: urlStr) {
            resumePlayingTitle = progress.title
            resumeVodID = progress.vodID
            resumePosterURL = progress.posterURL
            resumeServerID = progress.serverID
            resumePositionMs = progress.positionMs
            let resumeServer: ServerConnection? = progress.serverID
                .flatMap(UUID.init(uuidString:))
                .flatMap { uuid in servers.first(where: { $0.id == uuid }) }
            resumePlayingHeaders = resumeServer?.authHeaders ?? dispatcharrHeaders
            // ATV log 2026-08-17 (Logan): this fast path mounted the player
            // cover directly, skipping the teardown VODDetailView does before
            // its own cover. A minimized live channel therefore kept decoding
            // UNDER the movie - two mpv instances, both audible - until the
            // user stopped the live stream by hand. Same call, same reason as
            // the v1.6.23 fix in VODDetailView.startPlayback.
            PlayerSession.shared.exit()
            // Same log, second symptom: Continue Watching passed no version
            // options, so Switch Version was empty in the player even for a
            // title that shows several copies when opened from Movies. Load
            // them for this resume so the two entry points behave alike; the
            // fetch is best-effort and never gates playback starting.
            resumeVersionOptions = []
            resumeVersionSelectionKey = progress.serverID
                .flatMap(UUID.init(uuidString:))
                .map { uuid in
                    VODVersionSelectionStore.storageKey(serverID: uuid,
                                                        itemType: "movie",
                                                        itemID: progress.vodID)
                } ?? ""
            loadResumeVersionOptions(progress: progress, resumeURL: url, server: resumeServer)
            // TEST (AVPlayer VOD): unified container first; false = engine
            // off or non-VOD shape, legacy cover mounts unchanged.
            if PlayerSession.shared.beginVOD(
                title: progress.title,
                streamURL: url,
                headers: resumePlayingHeaders,
                posterURL: progress.posterURL.flatMap { URL(string: $0) },
                vodID: progress.vodID,
                serverID: progress.serverID,
                vodType: "movie",
                resumePositionMs: progress.positionMs,
                versionSelectionKey: resumeVersionSelectionKey.isEmpty ? nil : resumeVersionSelectionKey) {
                isPlaying = true
                return
            }
            resumePlayingURL = IdentifiableURL(url: url)
            isPlaying = true
            return
        }
        // Fallback: find the movie in the store and push to its detail view
        if let item = vodStore.movies.first(where: { $0.id == progress.vodID }) {
            navPath.append(item)
        }
    }

    /// Fetch this title's provider copies so the resume player can offer
    /// Switch Version. Mirrors VODDetailView.loadVersionProviders +
    /// buildVersionOptions for the movie case; failures are silent (older
    /// Dispatcharr builds lack /provider-info/, and a missing list just
    /// means the player shows no version row, exactly as before).
    private func loadResumeVersionOptions(progress: WatchProgress,
                                          resumeURL: URL,
                                          server: ServerConnection?) {
        // Fall back to the active Dispatcharr server: a watch-progress row
        // synced from another device can carry a serverID this install does
        // not have, and the resume itself already falls back the same way.
        let resolved = server ?? servers.first(where: {
            $0.isActive && $0.type == .dispatcharrAPI
        }) ?? servers.first(where: { $0.type == .dispatcharrAPI })
        guard let resolved, resolved.type == .dispatcharrAPI,
              let numericID = Int(progress.vodID) else {
            debugLog("[VOD-VERSION] resume skipped: no dispatcharr server or non-numeric id \(progress.vodID)")
            return
        }
        // Take the movie's Dispatcharr UUID straight out of the resume URL
        // (/proxy/vod/movie/<uuid>[/<session>]) rather than looking the title
        // up in vodStore.movies. The first attempt did the catalog lookup and
        // silently found nothing on device (ATV retest 2026-08-17) - the row
        // may not be loaded yet during the 2.5-minute VOD sync, and a synced
        // progress row can name a title this device never fetched. The URL is
        // always present because it is what we are about to play.
        let comps = resumeURL.pathComponents
        let uuid = comps.firstIndex(of: "movie")
            .flatMap { i in i + 1 < comps.count ? comps[i + 1] : nil } ?? ""
        guard !uuid.isEmpty else {
            debugLog("[VOD-VERSION] resume skipped: no uuid in \(resumeURL.path)")
            return
        }
        let server = resolved
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        Task { @MainActor in
            guard let providers = try? await api.getMovieProviders(movieID: numericID) else {
                debugLog("[VOD-VERSION] resume \(progress.vodID): providers fetch failed")
                return
            }
            guard providers.count > 1 else {
                debugLog("[VOD-VERSION] resume \(progress.vodID): \(providers.count) copy, no picker")
                return
            }
            // Same label pipeline as the detail page's picker (Logan
            // 2026-08-26: the in-player rows must show the same measured
            // quality info): account + container, then measured
            // descriptors, then the AVPlayer support note. Learn-cache
            // fills in immediately; server measurements land in a second
            // context push below.
            var learned: [Int: VODLearnedStream] = [:]
            for rel in providers {
                if let l = VODVersionMeasurementStore.lookup(optionID: rel.id) {
                    learned[rel.id] = l
                }
            }
            var media: [Int: DispatcharrVODProviderMedia] = [:]
            // Local funcs are nonisolated by default even inside a
            // @MainActor Task closure; annotate or the store call fails
            // to compile under strict concurrency.
            @MainActor func pushOptions() {
                let labels = VODVersionLabeler.labels(providers: providers,
                                                      media: media, learned: learned)
                resumeVersionOptions = providers.compactMap { rel in
                    guard let url = api.proxyMovieURL(uuid: uuid,
                                                      preferredStreamID: rel.streamID.flatMap(Int.init),
                                                      m3uAccountID: rel.account.id) else { return nil }
                    return VODVersionOption(id: rel.id,
                                            label: labels[rel.id] ?? rel.displayLabel,
                                            url: url)
                }
                // Container path (beginVOD): the options resolved AFTER the
                // launch; hand them to the session so Switch Version works
                // there too. No-op when the legacy cover is playing.
                MultiviewStore.shared.updateVODVersionContext(
                    vodID: progress.vodID,
                    options: resumeVersionOptions,
                    selectedID: VODVersionSelectionStore.selection(forKey: resumeVersionSelectionKey),
                    selectionKey: resumeVersionSelectionKey.isEmpty ? nil : resumeVersionSelectionKey)
            }
            pushOptions()
            debugLog("[VOD-VERSION] resume \(progress.vodID): \(resumeVersionOptions.count) provider copies")
            // Measured stream properties, capped at 3 concurrent fetches
            // (mirrors VODDetailView.loadVersionMedia): a copy the server
            // has not inspected yet costs an upstream round trip.
            let relationIDs = providers.map(\.id)
            await withTaskGroup(of: (Int, DispatcharrVODProviderMedia?).self) { group in
                var next = 0
                func addTask() {
                    guard next < relationIDs.count else { return }
                    let relationID = relationIDs[next]
                    next += 1
                    group.addTask {
                        (relationID, try? await api.getMovieProviderMedia(movieID: numericID,
                                                                          relationID: relationID))
                    }
                }
                for _ in 0..<min(3, relationIDs.count) { addTask() }
                for await (relationID, m) in group {
                    if let m, m.hasAnyMeasurement { media[relationID] = m }
                    addTask()
                }
            }
            if !media.isEmpty { pushOptions() }
        }
    }

    // MARK: - Derived data (redesign)

    private var sortOrder: MoviesSortOrder {
        MoviesSortOrder(rawValue: sortOrderRaw) ?? .titleAZ
    }

    private var activeServerIDString: String? {
        (servers.first(where: { $0.isActive }) ?? servers.first)?.id.uuidString
    }

    /// Movie progress rows scoped to the active playlist (rows with no
    /// serverID predate per-server progress and stay visible everywhere).
    private var movieProgress: [WatchProgress] {
        allProgress.filter { p in
            guard p.vodType == "movie" else { return false }
            guard let sid = activeServerIDString else { return true }
            return p.serverID == nil || p.serverID == sid
        }
    }

    /// Newest resume point, if any. The hero leads with it.
    private var heroProgress: WatchProgress? { movieProgress.first }

    /// Library minus hidden groups, before genre and sort.
    private var visibleMovies: [VODDisplayItem] {
        guard !hiddenGroups.isEmpty else { return vodStore.movies }
        return vodStore.movies.filter { item in
            guard let cat = item.movie?.categoryName else { return true }
            return !hiddenGroups.contains(cat)
        }
    }

    /// Up to 20 newest titles by source add time. Empty (shelf hidden)
    /// when the source carries no add dates at all.
    private var recentlyAdded: [VODDisplayItem] {
        let dated = visibleMovies.filter { $0.movie?.addedAt != nil }
        guard !dated.isEmpty else { return [] }
        return Array(dated.sorted {
            let a = $0.movie?.addedAt ?? .distantPast
            let b = $1.movie?.addedAt ?? .distantPast
            if a != b { return a > b }
            return $0.id < $1.id
        }.prefix(20))
    }

    /// What the hero shows: the resume title when there is one, else the
    /// newest addition, else the first library title.
    private var heroItem: VODDisplayItem? {
        if let p = heroProgress {
            if let match = vodStore.movies.first(where: { $0.id == p.vodID }) { return match }
            return MoviesView.syntheticItem(from: p)
        }
        return recentlyAdded.first ?? visibleMovies.first
    }

    /// Genre pills: the visible categories, in store order, "All" first.
    private var genrePills: [String] {
        vodStore.movieCategories.map(\.name).filter { !hiddenGroups.contains($0) }
    }

    /// The library grid: visible movies, genre-filtered, sorted.
    private var libraryMovies: [VODDisplayItem] {
        var result = visibleMovies
        if let g = selectedGenre {
            result = result.filter { $0.movie?.categoryName == g }
        }
        switch sortOrder {
        case .titleAZ:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .titleZA:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .yearNewest:
            result.sort {
                if $0.releaseYear != $1.releaseYear { return $0.releaseYear > $1.releaseYear }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .recentlyAdded:
            result.sort {
                let a = $0.movie?.addedAt ?? .distantPast
                let b = $1.movie?.addedAt ?? .distantPast
                if a != b { return a > b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return result
    }

    private func cycleSort() {
        let all = MoviesSortOrder.allCases
        let idx = all.firstIndex(of: sortOrder) ?? 0
        sortOrderRaw = all[(idx + 1) % all.count].rawValue
    }

    /// Minimal item for a resume row whose catalog entry is not loaded
    /// (same shape ContinueWatchingSection synthesizes for View Movie).
    private static func syntheticItem(from p: WatchProgress) -> VODDisplayItem? {
        guard let sid = p.serverID, let serverUUID = UUID(uuidString: sid) else { return nil }
        let movie = VODMovie(
            id: p.vodID, name: p.title,
            posterURL: p.posterURL.flatMap { URL(string: $0) }, backdropURL: nil,
            rating: "", plot: "", genre: "", releaseDate: "", duration: "",
            cast: "", director: "", imdbID: "", categoryID: "", categoryName: "",
            streamURL: p.streamURL.flatMap { URL(string: $0) },
            containerExtension: "", serverID: serverUUID)
        return VODDisplayItem(movie: movie)
    }

    // MARK: - Hero playback

    /// Hero primary action: resume when there is progress, else play.
    private func heroPrimary(_ item: VODDisplayItem) {
        if let p = heroProgress, p.vodID == item.id {
            resumeFromContinueWatching(p)
        } else {
            playMovie(item, resumePositionMs: WatchProgressManager.getResumePosition(
                vodID: item.id, serverID: item.serverID.uuidString) ?? 0)
        }
    }

    /// Direct play, the same steps VODDetailView.startPlayback takes for a
    /// movie: resolve the Dispatcharr session URL, drop the API key when
    /// the session lives off-host, tear down live playback, then the
    /// unified container first and the legacy cover as fallback.
    private func playMovie(_ item: VODDisplayItem, resumePositionMs startAt: Int32) {
        guard let movie = item.movie, let url = movie.streamURL else {
            navPath.append(item)
            return
        }
        let server = servers.first(where: { $0.id == item.serverID })
        var headers = server?.authHeaders ?? [:]
        let key = VODVersionSelectionStore.storageKey(serverID: item.serverID,
                                                      itemType: "movie", itemID: item.id)
        Task { @MainActor in
            var resolved = url
            if let server, server.type == .dispatcharrAPI {
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                         auth: .apiKey(server.effectiveApiKey),
                                         userAgent: server.effectiveUserAgent,
                                         authMode: server.dispatcharrHeaderMode)
                resolved = (try? await api.resolveFinalURLForPlayback(url)) ?? url
                if !api.isOwnHost(resolved) {
                    headers = headers.filter {
                        $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
                    }
                }
            }
            PlayerSession.shared.exit()
            if PlayerSession.shared.beginVOD(
                title: item.name,
                streamURL: resolved,
                headers: headers,
                posterURL: item.posterURL,
                vodID: item.id,
                serverID: item.serverID.uuidString,
                vodType: "movie",
                resumePositionMs: startAt,
                versionSelectionKey: key) {
                isPlaying = true
                return
            }
            resumePlayingTitle = item.name
            resumeVodID = item.id
            resumePosterURL = item.posterURL?.absoluteString
            resumeServerID = item.serverID.uuidString
            resumePositionMs = startAt
            resumePlayingHeaders = headers
            resumeVersionOptions = []
            resumeVersionSelectionKey = key
            resumePlayingURL = IdentifiableURL(url: resolved)
            isPlaying = true
        }
    }

    // MARK: - Content
    private var content: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            // Search + sort + filter row scrolls with the content (below);
            // while a server search is in flight it stays put here so the
            // field does not vanish under the spinner.
            if !searchText.isEmpty && vodStore.isSearchingMovies && filteredMovies.isEmpty {
                tvHeaderRow
            }
            #endif

            // Hidden groups indicator
            if !hiddenGroups.isEmpty && searchText.isEmpty {
                HStack(spacing: 6) {
                    Text("\(hiddenGroups.count) group\(hiddenGroups.count == 1 ? "" : "s") hidden")
                        .font(.labelMedium)
                        .foregroundColor(.textSecondary)
                    Button {
                        hiddenGroups.removeAll()
                        HiddenGroupsStore.save(hiddenGroups, forKey: hiddenGroupsKey)
                    } label: {
                        Text("Show All")
                            .font(.labelMedium)
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                #if os(tvOS)
                .focusSection()
                #endif
            }

            if !searchText.isEmpty && vodStore.isSearchingMovies && filteredMovies.isEmpty {
                ProgressView("Searching server…")
                    .tint(.accentPrimary)
                    .padding(.top, 60)
                Spacer()
            } else {
                GeometryReader { outer in
                ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("movies-top")
                    #if os(tvOS)
                    // The tab bar's reserved top inset, owned here so it can
                    // collapse when the bar hides and the grid gets the whole
                    // screen (the ScrollView ignores the top safe area).
                    Color.clear.frame(height: tvTabBarHidden ? 0 : outer.safeAreaInsets.top)
                    tvHeaderRow
                    #endif
                    if !searchText.isEmpty {
                        // Search: results grid only, no hero or shelves.
                        posterGrid(filteredMovies)
                    } else {
                        VStack(alignment: .leading, spacing: sectionSpacing) {
                            #if os(iOS)
                            iOSTitleRow
                            #endif
                            if let hero = heroItem {
                                MoviesHero(
                                    item: hero,
                                    progress: heroProgress.flatMap { $0.vodID == hero.id ? $0 : nil },
                                    headers: dispatcharrHeaders,
                                    onPrimary: { heroPrimary(hero) },
                                    onPlayFromStart: { playMovie(hero, resumePositionMs: 0) },
                                    onDetails: { navPath.append(hero) }
                                )
                                #if os(tvOS)
                                .focusSection()
                                #endif
                            }

                            ContinueWatchingSection(
                                vodType: "movie",
                                activeServerID: activeServerIDString,
                                headers: dispatcharrHeaders,
                                onPlay: { progress in resumeFromContinueWatching(progress) },
                                movies: vodStore.movies,
                                onOpenMovie: { item in navPath.append(item) }
                            )

                            if !recentlyAdded.isEmpty {
                                posterShelf(title: "Recently Added", items: recentlyAdded)
                            }

                            libraryHeader
                                .padding(.leading, railWidth)
                            posterGrid(libraryMovies)
                                .padding(.leading, railWidth)
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.frame(in: .named("moviesScroll")).minY
                                } action: { y in
                                    gridTopY = y
                                }
                        }
                    }

                    #if os(iOS)
                    Color.clear.frame(height: 96)
                    #endif
                }
                // Alphabet rail: pinned to the leading edge, jumps the
                // library grid to the first title for a letter.
                .coordinateSpace(name: "moviesScroll")
                .overlay(alignment: .topLeading) {
                    if searchText.isEmpty, let gridTopY {
                        AlphabetRail(available: railLetters) { letter in
                            if let id = firstGridID(for: letter) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .frame(width: railWidth)
                        .padding(.top, max(railStickyTop, gridTopY + railGridOffset))
                    }
                }
                #if os(tvOS)
                // Menu while the tab bar is hidden: back to the top and
                // bring the bar back, instead of the TabView's default
                // handling (which landed on the default tab). With the bar
                // showing, Menu is left alone so it focuses the bar as usual.
                .onExitCommand(perform: tvTabBarHidden ? {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("movies-top", anchor: .top)
                        tvTabBarHidden = false
                    }
                } : nil)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { _, y in
                    // Hide as soon as the content moves so the bar, its
                    // reserved inset, and the nav circles leave together
                    // (Logan 2026-09-03: the circles lagged behind the bar).
                    let hide = y > 40
                    if hide != tvTabBarHidden {
                        withAnimation(.easeInOut(duration: 0.2)) { tvTabBarHidden = hide }
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .onChange(of: tvTabBarHidden) { _, hidden in
                    TVTabBarScrollState.shared.isHidden = hidden
                }
                .onDisappear { TVTabBarScrollState.shared.isHidden = false }
                #endif
                }
                }
                #if os(iOS)
                .onScrollGeometryChange(for: CGFloat.self) { scrollGeo in
                    scrollGeo.contentOffset.y
                } action: { oldY, y in
                    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
                    if let hidden = tabBarTracker.update(oldY: oldY, newY: y,
                                                         hidden: gridTabBarHidden) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            gridTabBarHidden = hidden
                        }
                    }
                }
                .scrollAwayTabBar(collapsed: gridTabBarHidden)
                .ignoresSafeArea(.container, edges: .bottom)
                .aerioContentUnderTabBar()
                #endif
            }
        }
    }

    /// Where the rail parks once the grid has scrolled under it.
    private var railStickyTop: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 8
        #endif
    }

    /// Grid padding (16) plus the card style's own inset so the first
    /// letter lines up with the first poster's top edge.
    private var railGridOffset: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 16
        #endif
    }

    private var railWidth: CGFloat {
        #if os(tvOS)
        return 72
        #else
        return 34
        #endif
    }

    /// Letters that have at least one title in the library grid.
    private var railLetters: Set<String> {
        Set(libraryMovies.map { AlphabetRail.bucket(for: $0.name) })
    }

    /// Grid row id of the first title in this letter's bucket.
    private func firstGridID(for letter: String) -> String? {
        libraryMovies.first { AlphabetRail.bucket(for: $0.name) == letter }
            .map { "grid-\($0.id)" }
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        return 28
        #else
        return 18
        #endif
    }

    #if os(tvOS)
    /// Search circle + inline field on the left, filter and sort circles
    /// on the right. Same round platters as the nav bar's Refresh/Search.
    private var tvHeaderRow: some View {
        HStack(spacing: 14) {
            Spacer()

            if showSearchField {
                // Same UIKit-backed field Settings uses: transparent, never
                // paints the system white focus platter. The capsule below
                // is the resting box and the accent ring is the focus state.
                DarkFocusTextFieldRepresentable(
                    text: $searchText,
                    placeholder: "Search movies",
                    isSecure: false,
                    fontSize: 24,
                    onFocusChange: { searchFieldFocused = $0 }
                )
                .frame(width: 380, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.elevatedBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentPrimary, lineWidth: searchFieldFocused ? 3 : 0)
                        .animation(.easeInOut(duration: 0.15), value: searchFieldFocused)
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            TVNavActionCircle(systemImage: "magnifyingglass", label: "Search",
                              isSelected: showSearchField) {
                withAnimation(.spring(response: 0.25)) {
                    showSearchField.toggle()
                    if !showSearchField { searchText = "" }
                }
            }
            TVNavActionCircle(systemImage: "arrow.up.arrow.down", label: "Sort") {
                showSortMenu = true
            }
            TVNavActionCircle(systemImage: "line.3.horizontal.decrease",
                              label: "Manage Groups",
                              isSelected: !hiddenGroups.isEmpty) {
                showFilterMenu = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .focusSection()
        // Filter: same native action list as Sort. Each group toggles
        // between shown (check) and hidden; the list closes on each pick.
        .confirmationDialog("Show Groups", isPresented: $showFilterMenu, titleVisibility: .visible) {
            if !hiddenGroups.isEmpty {
                Button("Show All Groups") {
                    hiddenGroups.removeAll()
                    HiddenGroupsStore.save(hiddenGroups, forKey: hiddenGroupsKey)
                }
            }
            ForEach(vodStore.movieCategories.map(\.name), id: \.self) { name in
                let visible = !hiddenGroups.contains(name)
                Button(visible ? "\(name)  \u{2713}" : name) {
                    if visible { hiddenGroups.insert(name) } else { hiddenGroups.remove(name) }
                    HiddenGroupsStore.save(hiddenGroups, forKey: hiddenGroupsKey)
                    if visible, selectedGenre == name { selectedGenre = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Native tvOS action list, same surface as the multiview tile menus.
        .confirmationDialog("Sort Movies", isPresented: $showSortMenu, titleVisibility: .visible) {
            ForEach(MoviesSortOrder.allCases, id: \.self) { order in
                Button(order == sortOrder ? "\(order.label)  \u{2713}" : order.label) {
                    sortOrderRaw = order.rawValue
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    #endif

    #if os(iOS)
    /// Large title with the sort menu and filter beside it. Search stays
    /// in the navigation bar drawer.
    private var iOSTitleRow: some View {
        HStack(alignment: .center) {
            Text("Movies")
                .font(.displayMedium)
                .foregroundColor(.textPrimary)
            Spacer()
            Menu {
                ForEach(MoviesSortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrderRaw = order.rawValue
                    } label: {
                        if order == sortOrder {
                            Label(order.label, systemImage: "checkmark")
                        } else {
                            Text(order.label)
                        }
                    }
                }
            } label: {
                iOSCircle("arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort")
            Button { showManageGroups = true } label: {
                iOSCircle("line.3.horizontal.decrease")
            }
            .accessibilityLabel("Manage Groups")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func iOSCircle(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.accentPrimary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.elevatedBackground))
    }
    #endif

    /// "All Movies · N" with the genre pills.
    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("All Movies")
                    .font(.headlineSmall)
                    .foregroundColor(.textPrimary)
                Text("\(libraryMovies.count)")
                    .font(.labelMedium)
                    .foregroundColor(.textTertiary)
                #if os(iOS)
                Spacer()
                Text(sortOrder.label)
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
                #endif
            }
            .padding(.horizontal, 16)

            if !genrePills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: pillSpacing) {
                        genrePill("All", isSelected: selectedGenre == nil) { selectedGenre = nil }
                        ForEach(genrePills, id: \.self) { g in
                            genrePill(g, isSelected: selectedGenre == g) {
                                selectedGenre = (selectedGenre == g) ? nil : g
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    #if os(tvOS)
                    .padding(.vertical, 12)
                    #endif
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }

    private var pillSpacing: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 8
        #endif
    }

    @ViewBuilder
    private func genrePill(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        // Same capsule + focus treatment as the guide's group pills (the
        // shared TVCategoryPill draws the squared ring on focus).
        Button(action: action) {
            Text(label).font(.system(size: 22, weight: .medium))
        }
        .buttonStyle(TVGroupPillButtonStyle(isSelected: isSelected))
        #else
        DVRSegmentPill(label: label, isSelected: isSelected, action: action)
        #endif
    }

    /// Horizontal poster rail (Recently Added).
    private func posterShelf(title: String, items: [VODDisplayItem]) -> some View {
        VStack(alignment: .leading, spacing: shelfTitleSpacing) {
            Text(title)
                .font(.headlineSmall)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: shelfCardSpacing) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            VODPosterCard(item: item, headers: dispatcharrHeaders)
                                .frame(width: shelfCardWidth)
                        }
                        #if os(tvOS)
                        .buttonStyle(TVCardButtonStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal, 16)
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var shelfTitleSpacing: CGFloat {
        #if os(tvOS)
        return 8
        #else
        return 8
        #endif
    }
    private var shelfCardSpacing: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 12
        #endif
    }
    private var shelfCardWidth: CGFloat {
        #if os(tvOS)
        return 200
        #else
        return 120
        #endif
    }

    /// The library grid (also the search results grid).
    private func posterGrid(_ items: [VODDisplayItem]) -> some View {
        LazyVGrid(columns: columns, spacing: gridRowSpacing) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    VODPosterCard(item: item, headers: dispatcharrHeaders)
                }
                #if os(tvOS)
                .buttonStyle(TVCardButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
                .id("grid-\(item.id)")
            }
        }
        .padding(16)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: - Empty / Error
    @ViewBuilder
    private var emptyState: some View {
        if servers.isEmpty {
            EmptyStateView(
                icon: "film.stack",
                title: "No Movies",
                message: "Add an Xtream Codes or Dispatcharr server to browse movies."
            )
        } else if servers.first(where: { $0.isActive })?.supportsVOD == false {
            EmptyStateView(
                icon: "film.stack",
                title: "Movies Unavailable",
                message: "M3U playlists do not include VOD content. Switch to an Xtream Codes or Dispatcharr API playlist in Settings > Playlists to browse movies."
            )
        } else {
            EmptyStateView(
                icon: "film.stack",
                title: "No Movies",
                message: serverContext("No movies were returned by"),
                action: { vodStore.refreshMovies(servers: servers) },
                actionTitle: "Retry"
            )
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundColor(.statusWarning)
            Text("Failed to load movies")
                .font(.headlineLarge).foregroundColor(.textPrimary)
            if let serverName = vodStore.lastMoviesServerName {
                Text("Server: \(serverName)")
                    .font(.labelMedium).foregroundColor(.textSecondary)
            }
            Text(msg)
                .font(.bodyMedium).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton("Try Again") { vodStore.refreshMovies(servers: servers) }
                .frame(maxWidth: 200)
        }
        .padding(32)
    }

    private func serverContext(_ prefix: String) -> String {
        if let name = vodStore.lastMoviesServerName {
            return "\(prefix) \(name). Tap the retry button to try again."
        }
        return "Tap the retry button to try again."
    }
}

// MARK: - VOD Poster Card
struct VODPosterCard: View {
    let item: VODDisplayItem
    var headers: [String: String] = [:]

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Poster image — uses authenticated fetch so Dispatcharr /media/ images load correctly
            ZStack {
                if item.posterURL != nil {
                    AuthPosterImage(url: item.posterURL, headers: headers)
                        .aspectRatio(2/3, contentMode: .fill)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.cardBackground)
                        .aspectRatio(2/3, contentMode: .fit)
                        .overlay {
                            NoPosterPlaceholder()
                        }
                }
            }
            #if os(tvOS)
            .frame(width: 200, height: 300)
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            #if os(tvOS)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary : .clear, lineWidth: 2.5)
            )
            #endif
            .overlay(alignment: .bottomTrailing) {
                if !item.rating.isEmpty {
                    Text(item.rating)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
            }

            // Text footer — fixed height so every card in the grid row is the same total
            // height regardless of title length or whether a year is present.
            VStack(alignment: .leading, spacing: 2) {
                // Title: reserves exactly 2-line height via a fixed frame so all cards
                // in the same grid row align regardless of actual title length.
                Text(item.name)
                    .font(.labelSmall)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    #if os(tvOS)
                    .frame(height: 44) // 2 lines at labelSmall (18pt) on tvOS
                    #else
                    .frame(height: 32) // 2 lines at labelSmall on iOS
                    #endif

                // Year: always rendered (non-breaking space when absent) so every
                // card reserves the same vertical space for this line.
                Text(item.releaseYear.isEmpty ? "\u{00A0}" : item.releaseYear)
                    #if os(tvOS)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(item.releaseYear.isEmpty ? .clear : .textSecondary)
                    #else
                    .font(.system(size: 10))
                    .foregroundColor(item.releaseYear.isEmpty ? .clear : .textTertiary)
                    #endif
            }
            .padding(.bottom, 4)
        }
    }
}

// TVCategoryPill is defined in Components.swift

// MARK: - Movies tab redesign: sort order

enum MoviesSortOrder: String, CaseIterable {
    case titleAZ, titleZA, yearNewest, recentlyAdded

    var label: String {
        switch self {
        case .titleAZ:       return "Title · A to Z"
        case .titleZA:       return "Title · Z to A"
        case .yearNewest:    return "Year · Newest"
        case .recentlyAdded: return "Recently Added"
        }
    }
}

// MARK: - Movies tab redesign: hero

/// Featured title at the top of the Movies tab: backdrop (poster when the
/// source has no backdrop), title, metadata line, plot, and the action
/// row. Leads with the newest resume point when there is one.
struct MoviesHero: View {
    let item: VODDisplayItem
    let progress: WatchProgress?
    var headers: [String: String] = [:]
    let onPrimary: () -> Void
    let onPlayFromStart: () -> Void
    let onDetails: () -> Void

    private var movie: VODMovie? { item.movie }

    private var eyebrow: String {
        progress != nil ? "Continue watching" : (movie?.addedAt != nil ? "Recently added" : "Featured")
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if !item.releaseYear.isEmpty { parts.append(item.releaseYear) }
        if let d = movie?.duration, !d.isEmpty { parts.append(d) }
        if let g = movie?.genre.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces), !g.isEmpty { parts.append(g) }
        return parts
    }

    private var remainingLabel: String? {
        guard let p = progress, p.durationMs > 0 else { return nil }
        let leftMin = max(0, Int((p.durationMs - p.positionMs) / 60_000))
        if leftMin >= 60 { return "\(leftMin / 60) h \(leftMin % 60) min left" }
        return "\(leftMin) min left"
    }

    private var fraction: Double {
        guard let p = progress, p.durationMs > 0 else { return 0 }
        return Double(p.positionMs) / Double(p.durationMs)
    }

    private var artworkURL: URL? { movie?.backdropURL ?? item.posterURL }

    #if os(tvOS)
    private let heroHeight: CGFloat = 420
    private let corner: CGFloat = 24
    #else
    private let heroHeight: CGFloat = 220
    private let corner: CGFloat = 16
    #endif

    var body: some View {
        #if os(tvOS)
        // Full bleed on TV: the art fades into the page background on the
        // left and bottom, so there is no card edge to see (Logan
        // 2026-09-03: a clipped card showed a faint boundary).
        // Only the ART is clipped to the rounded shape; the fades and copy
        // are drawn unclipped over it. Clipping the whole stack rasterized
        // it as its own layer and left a faint seam along the corner even
        // where the fade matched the page background (Logan 2026-09-03).
        ZStack(alignment: .leading) {
            artwork
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            gradient
            LinearGradient(
                stops: [
                    .init(color: Color.appBackground.opacity(0), location: 0.55),
                    .init(color: Color.appBackground, location: 1)
                ],
                startPoint: .top, endPoint: .bottom)
            copy
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        #else
        ZStack(alignment: .leading) {
            artwork
            gradient
            copy
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .padding(.horizontal, 16)
        #endif
    }

    @ViewBuilder
    private var artwork: some View {
        GeometryReader { geo in
            if let url = artworkURL {
                AuthPosterImage(url: url, headers: headers, placeholder: .clear)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Color.clear
            }
        }
    }

    private var gradient: some View {
        #if os(tvOS)
        LinearGradient(
            stops: [
                // Fully opaque through the leading band so the rounded
                // corners on that side never show an edge against the page.
                .init(color: Color.appBackground, location: 0),
                .init(color: Color.appBackground, location: 0.12),
                .init(color: Color.appBackground.opacity(0.92), location: 0.38),
                .init(color: Color.appBackground.opacity(0.35), location: 0.7),
                .init(color: Color.appBackground.opacity(0.05), location: 1)
            ],
            startPoint: .leading, endPoint: .trailing)
        #else
        LinearGradient(
            stops: [
                .init(color: Color.appBackground.opacity(0.05), location: 0),
                .init(color: Color.appBackground.opacity(0.92), location: 1)
            ],
            startPoint: .top, endPoint: .bottom)
        #endif
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: copySpacing) {
            Text(eyebrow.uppercased())
                .font(.system(size: eyebrowSize, weight: .bold))
                .tracking(1.2)
                .foregroundColor(.accentPrimary)
            Text(item.name)
                .font(titleFont)
                .foregroundColor(.textPrimary)
                .lineLimit(2)
            if !metaParts.isEmpty || !item.rating.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(metaParts.enumerated()), id: \.offset) { idx, part in
                        if idx > 0 { Text("·").foregroundColor(.textTertiary) }
                        Text(part)
                    }
                    if !item.rating.isEmpty {
                        if !metaParts.isEmpty { Text("·").foregroundColor(.textTertiary) }
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.system(size: metaSize - 4))
                            Text(item.rating)
                        }
                        .foregroundColor(.accentPrimary)
                    }
                }
                .font(.system(size: metaSize, weight: .medium))
                .foregroundColor(.textSecondary)
            }
            #if os(tvOS)
            if let plot = movie?.plot, !plot.isEmpty {
                Text(plot)
                    .font(.bodySmall)
                    .foregroundColor(.textPrimary.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: 680, alignment: .leading)
            }
            #endif
            actions
        }
        .padding(copyInset)
        #if os(tvOS)
        .frame(maxWidth: 1000, alignment: .leading)
        #else
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            MoviesHeroButton(
                title: progress != nil ? "Resume" : "Play",
                systemImage: "play.fill", isPrimary: true, action: onPrimary)
            #if os(tvOS)
            if progress != nil {
                MoviesHeroButton(title: "Play from Beginning", systemImage: "gobackward",
                                 isPrimary: false, action: onPlayFromStart)
            }
            MoviesHeroButton(title: "Details", systemImage: "info.circle",
                             isPrimary: false, action: onDetails)
            #else
            if progress != nil {
                MoviesHeroButton(title: "", systemImage: "gobackward",
                                 isPrimary: false, action: onPlayFromStart)
            }
            MoviesHeroButton(title: "", systemImage: "info.circle",
                             isPrimary: false, action: onDetails)
            if let remainingLabel {
                Text(remainingLabel)
                    .font(.labelSmall)
                    .foregroundColor(.textSecondary)
            }
            #endif
        }
        .padding(.top, 4)
    }

    #if os(tvOS)
    private let copySpacing: CGFloat = 12
    private let copyInset: CGFloat = 44
    private let eyebrowSize: CGFloat = 16
    private let metaSize: CGFloat = 20
    private var titleFont: Font { .displayLarge }
    #else
    private let copySpacing: CGFloat = 6
    private let copyInset: CGFloat = 16
    private let eyebrowSize: CGFloat = 11
    private let metaSize: CGFloat = 13
    private var titleFont: Font { .displayMedium }
    #endif
}

/// Hero action: accent-filled primary, elevated secondary. tvOS focus is a
/// white ring on the primary (an accent ring would vanish on the accent
/// fill) and the usual accent ring on secondaries.
struct MoviesHeroButton: View {
    let title: String
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: textSize, weight: .semibold))
                }
            }
            .foregroundColor(isPrimary ? .appBackground : .textPrimary)
            .padding(.horizontal, title.isEmpty ? 14 : hPad)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isPrimary ? Color.accentPrimary : Color.elevatedBackground)
            )
        }
        .buttonStyle(MoviesHeroButtonStyle(isPrimary: isPrimary))
    }

    #if os(tvOS)
    private let iconSize: CGFloat = 22
    private let textSize: CGFloat = 22
    private let hPad: CGFloat = 26
    private let height: CGFloat = 60
    #else
    private let iconSize: CGFloat = 15
    private let textSize: CGFloat = 15
    private let hPad: CGFloat = 18
    private let height: CGFloat = 40
    #endif
}

private struct MoviesHeroButtonStyle: ButtonStyle {
    let isPrimary: Bool
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isPrimary ? Color.white : Color.accentPrimary,
                            lineWidth: isFocused ? 3 : 0)
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        #else
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
        #endif
    }
}

// MARK: - Movies tab redesign: alphabet rail

/// # then A to Z down the leading edge. Letters with no titles are dimmed
/// and inert. On tvOS a letter jumps as soon as it takes focus (and on
/// click); on iOS a tap jumps.
struct AlphabetRail: View {
    let available: Set<String>
    let onSelect: (String) -> Void

    static let letters: [String] = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }

    /// Rail bucket for a title: its first letter, folded to A to Z, or #
    /// for anything else (digits, symbols, leading articles kept as-is).
    static func bucket(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let folded = String(first).folding(options: .diacriticInsensitive, locale: nil).uppercased()
        guard let c = folded.first, c.isLetter, c.isASCII else { return "#" }
        return String(c)
    }

    #if os(tvOS)
    @FocusState private var focused: String?
    #endif

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Self.letters, id: \.self) { letter in
                let enabled = available.contains(letter)
                Button {
                    onSelect(letter)
                } label: {
                    Text(letter)
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                        .foregroundColor(letterColor(letter, enabled: enabled))
                        .frame(width: cell, height: cell)
                        #if os(tvOS)
                        .background(
                            Circle().fill(focused == letter ? Color.accentPrimary.opacity(0.25) : .clear)
                        )
                        .overlay(
                            Circle().stroke(Color.white, lineWidth: focused == letter ? 2 : 0)
                        )
                        #endif
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                #if os(tvOS)
                .focused($focused, equals: letter)
                #endif
            }
        }
        .padding(.leading, leadingInset)
        #if os(tvOS)
        .focusSection()
        .onChange(of: focused) { _, letter in
            if let letter, available.contains(letter) { onSelect(letter) }
        }
        #endif
    }

    private func letterColor(_ letter: String, enabled: Bool) -> Color {
        #if os(tvOS)
        if focused == letter { return .white }
        #endif
        return enabled ? .textSecondary : .textTertiary.opacity(0.35)
    }

    // Condensed (Logan 2026-09-03): 27 cells at these sizes run ~700pt on
    // TV and ~400pt on phone, so the whole column fits with room to spare.
    #if os(tvOS)
    private let spacing: CGFloat = 0
    private let fontSize: CGFloat = 17
    private let cell: CGFloat = 26
    private let leadingInset: CGFloat = 20
    #else
    private let spacing: CGFloat = 0
    private let fontSize: CGFloat = 10
    private let cell: CGFloat = 15
    private let leadingInset: CGFloat = 6
    #endif
}
