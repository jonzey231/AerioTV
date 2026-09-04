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
    /// Longest side, in pixels, the decoded bitmap is downsampled to. Grid
    /// posters draw at a few hundred points; decoding a 2000px file for
    /// each on the main thread was a scroll stutter (Logan 2026-09-03).
    var maxPixel: CGFloat = 1024

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
            guard let (data, _) = try? await URLSession.shared.data(for: req) else { return }
            let limit = maxPixel
            // Decode, downsample, and force-decompress OFF the main thread:
            // UIImage(data:) is lazy and would otherwise decode on first
            // draw, mid-scroll. GH #61: SVG artwork still decodes here.
            let prepared: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let raw = AerioImageDecoding.decode(data) else { return nil }
                let longest = max(raw.size.width, raw.size.height) * raw.scale
                if longest > limit {
                    let f = limit / longest
                    let target = CGSize(width: raw.size.width * raw.scale * f,
                                        height: raw.size.height * raw.scale * f)
                    if let thumb = await raw.byPreparingThumbnail(ofSize: target) { return thumb }
                }
                return await raw.byPreparingForDisplay() ?? raw
            }.value
            guard let img = prepared else { return }
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
    /// tvOS: like heroFocusRequest, but lands on the hero button that had
    /// focus last (Up from Play from Beginning returned to Resume, Logan
    /// 2026-09-04). Declared unguarded: the carousel binding is built in
    /// shared code.
    @State private var heroRestoreRequest = false

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
    /// Rail handoff (same catcher pattern as the hero carousel): a thin
    /// focusable strip on the grid's left edge takes Left from the first
    /// column and forwards focus to the rail; Right from the rail lands on
    /// it and goes back to the last focused poster.
    @FocusState private var gridFocus: String?
    /// Set to move focus onto the hero's Resume (scroll-to-top landing).
    @State private var heroFocusRequest = false
    /// True while a hero button has focus: shows the fixed tab-bar guide.
    @State private var heroHasFocus = false
    /// Whether the Movies pill is currently on screen. The TabView slides
    /// the whole bar above the top edge once content scrolls; a focus
    /// guide whose target is off screen is ignored by the engine (trace
    /// 2026-09-04 14:06: pill at y -301, guide at y 0, Up did nothing).
    @State private var tabBarOnScreen = true
    #if os(tvOS)
    @FocusState private var topCatcherFocused: Bool
    #endif
    @State private var lastGridFocus: String?
    @State private var railHadFocus = false
    @State private var railFocusRequest: String?
    #endif
    /// Re-sorted library waiting until the user is back at the top: applying
    /// it mid-scroll reordered the grid under the focused poster.
    @State private var pendingDerived: LibraryDerived?
    /// Rail top edge. Written only while the rail rides with the grid; once
    /// parked the value stops changing, so scrolling the grid costs no
    /// body re-evaluation. nil until the grid is first measured.
    @State private var railTop: CGFloat?
    /// Scroll geometry for the rail jump, kept OUT of view state so the
    /// per-frame writes never re-evaluate the body. Row pitch and the
    /// grid's content-space top let a click scroll to an absolute offset:
    /// ScrollViewReader.scrollTo(id) silently no-ops for lazy grid rows
    /// that have not been built yet (device log 2026-09-03).
    private final class ScrollGeometryBox {
        var contentOffsetY: CGFloat = 0
        var gridTopVisible: CGFloat = 0
        var rowPitch: CGFloat = 0
        var gridWidth: CGFloat = 0
    var watchlistShelfHeight: CGFloat = 0
    }
    @State private var geometryBox = ScrollGeometryBox()
    @State private var scrollPosition = ScrollPosition()
    #if os(tvOS)
    @FocusState private var railCatcherFocused: Bool
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
    /// Watchlist, newest first; scoped to the active playlist below.
    @Query(sort: \WatchlistEntry.addedAt, order: .reverse)
    private var watchlistEntries: [WatchlistEntry]
    @AppStorage("moviesSortOrder") private var sortOrderRaw = MoviesSortOrder.titleAZ.rawValue
    /// Genre pill selection; nil = All. Not persisted: a filter that
    /// silently survives a relaunch reads as "my movies vanished".
    @State private var selectedGenre: String? = nil
    /// Library grid's top edge in scroll-view coordinates. The alphabet
    /// rail rides with it, then sticks once it reaches the top inset.
    /// Grid top edge reaches the rail through a layout preference (not
    /// @State): a state write per scroll frame re-evaluated this whole
    /// body, 5k grid rows included (Logan 2026-09-03: still not smooth).
    private struct GridTopKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            if let v = nextValue() { value = v }
        }
    }
    #if os(tvOS)
    /// tvOS: the tab bar hides once the library scrolls past the top so
    /// the grid gets the whole screen; it returns near the top.
    @State private var tvTabBarHidden = false
    @State private var wantsTabBarHidden = false
    /// True from a scroll-to-top request until the bar is back on screen.
    /// Rapid Up presses during the animation each restarted it (video +
    /// trace 2026-09-04 15:39), so while it is in flight the top strip is
    /// unmounted and further hero-focus scroll requests are ignored.
    @State private var scrollToTopInFlight = false
    @State private var scrollIsIdle = true
    #endif

    /// User-tunable UI scale (0.85–1.25). Only consumed on iPad / Mac Catalyst
    /// where the default 120 px minimum can feel cramped on wide displays;
    /// iPhone grids stay at their designed minimums (user scale is a no-op in
    /// the ternary below), and tvOS ignores the setting entirely.
    @AppStorage("uiScale") private var uiScale: Double = 1.0

    #if os(tvOS)
    private var columns: [GridItem] {
        // Seven columns, tiles flex to fill (Logan 2026-09-04).
        Array(repeating: GridItem(.flexible(), spacing: tvGridColumnSpacing), count: tvGridColumns)
    }
    private let gridRowSpacing: CGFloat = 48
    private let tvGridColumns = 7
    private let tvGridColumnSpacing: CGFloat = 24
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
    /// Cached: `authHeaders` reads the Keychain (API key) and sysctl
    /// (default User-Agent) every call, and every poster cell asked for it
    /// on every layout pass (Time Profiler 2026-09-04: a third of main
    /// thread time during the scroll).
    @State private var dispatcharrHeaders: [String: String] = [:]

    private var dispatcharrHeadersKey: String {
        servers.map { "\($0.id)|\($0.isActive)|\($0.supportsVOD)|\($0.type)" }.joined(separator: ",")
    }

    private func refreshDispatcharrHeaders() {
        guard let s = servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI && $0.isActive })
                   ?? servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI })
        else { dispatcharrHeaders = [:]; return }
        dispatcharrHeaders = s.authHeaders
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
                    // Nested pushes (Related, Known For) append to THIS path.
                    // A detail's own navigationDestination(item:) pushing a
                    // value already in the path wedged the stack (Logan
                    // 2026-09-04 16:11/16:14: A -> Related B -> Related A hung).
                    .environment(\.vodPushHandler) { pushed in navPath.append(pushed) }
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
            // Also hidden while a detail is pushed: the detail's own
            // .toolbar(.hidden) did not win over this root assertion on
            // tvOS 27 (bar stayed on the movie page, Logan 2026-09-04).
            .toolbar((tvTabBarHidden || !navPath.isEmpty) ? .hidden : .visible, for: .tabBar)
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
            .task(id: libraryKey) {
                let movies = vodStore.movies
                let hidden = hiddenGroups
                let genre = selectedGenre
                let sort = sortOrder
                let result = await Task.detached(priority: .userInitiated) {
                    MoviesView.computeDerived(movies: movies, hidden: hidden, genre: genre, sort: sort)
                }.value
                guard !Task.isCancelled else { return }
                #if os(tvOS)
                // Held while the bar is hidden OR the scroll is moving: the
                // library sweep republishes every 5 s and each rebuild of a
                // multi-thousand-item grid mid-scroll read as stutter (Time
                // Profiler + log 2026-09-04 15:18, test ran during the sweep).
                if (tvTabBarHidden || !scrollIsIdle) && !derived.library.isEmpty {
                    pendingDerived = result
                } else {
                    derived = result
                    pendingDerived = nil
                }
                #else
                derived = result
                #endif
            }
            #if os(tvOS)
            .onAppear { MoviesFocusTracer.shared.start() }
            .onDisappear { MoviesFocusTracer.shared.stop() }
            #endif
            .onAppear { refreshDispatcharrHeaders(); refreshHeroPages() }
            .onChange(of: heroPagesKey) { _, _ in refreshHeroPages() }
            .onChange(of: dispatcharrHeadersKey) { _, _ in refreshDispatcharrHeaders() }
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
        MoviesView.visible(vodStore.movies, hidden: hiddenGroups)
    }

    nonisolated private static func visible(_ movies: [VODDisplayItem], hidden: Set<String>) -> [VODDisplayItem] {
        guard !hidden.isEmpty else { return movies }
        return movies.filter { item in
            guard let cat = item.movie?.categoryName else { return true }
            return !hidden.contains(cat)
        }
    }

    // Perf (Logan 2026-09-03: 4 fps scrolling the grid): these used to be
    // computed properties, so every body evaluation (every focus move and
    // every scroll frame that updates gridTopY) re-sorted all ~5k titles
    // with a localized compare, several times over. They are now computed
    // once per input change, off the main thread, into `derived`.
    struct LibraryDerived: Equatable {
        var library: [VODDisplayItem] = []
        var recentlyAdded: [VODDisplayItem] = []
        var railLetters: Set<String> = []
        /// First grid row id per rail letter.
        var firstGridID: [String: String] = [:]
    }
    @State private var derived = LibraryDerived()

    private struct LibraryKey: Hashable {
        let count: Int
        let firstID: String?
        let lastID: String?
        let hidden: Set<String>
        let genre: String?
        let sort: String
    }
    private var libraryKey: LibraryKey {
        LibraryKey(count: vodStore.movies.count,
                   firstID: vodStore.movies.first?.id,
                   lastID: vodStore.movies.last?.id,
                   hidden: hiddenGroups, genre: selectedGenre, sort: sortOrderRaw)
    }

    nonisolated private static func computeDerived(movies: [VODDisplayItem], hidden: Set<String>,
                                       genre: String?, sort: MoviesSortOrder) -> LibraryDerived {
        let visible = Self.visible(movies, hidden: hidden)

        let dated = visible.filter { $0.movie?.addedAt != nil }
        let recent: [VODDisplayItem] = dated.isEmpty ? [] : Array(dated.sorted {
            let a = $0.movie?.addedAt ?? .distantPast
            let b = $1.movie?.addedAt ?? .distantPast
            if a != b { return a > b }
            return $0.id < $1.id
        }.prefix(20))

        var library = visible
        if let g = genre { library = library.filter { $0.movie?.categoryName == g } }
        // Precomputed folded keys: one localized fold per title instead of
        // one localized compare per comparison.
        // Same stripped title the rail buckets on, so a rail jump lands on
        // the sorted run for that letter ("4K: Thor" sorts under T).
        let keys = Dictionary(uniqueKeysWithValues: library.map {
            ($0.id, String(AlphabetRail.stripQualityPrefix($0.name))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        })
        func byTitle(_ a: VODDisplayItem, _ b: VODDisplayItem) -> Bool {
            let ka = keys[a.id] ?? "", kb = keys[b.id] ?? ""
            if ka != kb { return ka < kb }
            return a.id < b.id
        }
        switch sort {
        case .titleAZ:    library.sort(by: byTitle)
        case .titleZA:    library.sort { byTitle($1, $0) }
        case .yearNewest:
            library.sort {
                if $0.releaseYear != $1.releaseYear { return $0.releaseYear > $1.releaseYear }
                return byTitle($0, $1)
            }
        case .recentlyAdded:
            library.sort {
                let a = $0.movie?.addedAt ?? .distantPast
                let b = $1.movie?.addedAt ?? .distantPast
                if a != b { return a > b }
                return byTitle($0, $1)
            }
        }

        var letters: Set<String> = []
        var firstID: [String: String] = [:]
        for item in library {
            let bucket = AlphabetRail.bucket(for: item.name)
            if firstID[bucket] == nil { firstID[bucket] = "grid-\(item.id)" }
            letters.insert(bucket)
        }
        return LibraryDerived(library: library, recentlyAdded: recent,
                              railLetters: letters, firstGridID: firstID)
    }

    /// Up to 20 newest titles by source add time (cached).
    private var recentlyAdded: [VODDisplayItem] { derived.recentlyAdded }

    /// Hero pages: every Continue Watching title (newest first, up to 12),
    /// or, with nothing in progress, the newest addition or first title.
    /// Cached hero pages. The old computed form ran a linear search over
    /// the whole library for each resume row on EVERY body pass, and a
    /// tvOS focus move re-evaluates the body (Time Profiler 2026-09-04
    /// 15:24: a third of main thread time while stepping rows).
    @State private var heroPages: [MoviesHeroPage] = []

    private var heroPagesKey: String {
        let progress = movieProgress.prefix(12).map { "\($0.vodID)|\($0.positionMs)" }.joined(separator: ",")
        return "\(progress)#\(vodStore.movies.count)#\(recentlyAdded.first?.id ?? "")#\(hiddenGroups.count)"
    }

    private func refreshHeroPages() {
        let progress = Array(movieProgress.prefix(12))
        var byID: [String: VODDisplayItem] = [:]
        if !progress.isEmpty {
            let wanted = Set(progress.map(\.vodID))
            for m in vodStore.movies where wanted.contains(m.id) && byID[m.id] == nil { byID[m.id] = m }
        }
        let resumes: [MoviesHeroPage] = progress.compactMap { p in
            let item = byID[p.vodID] ?? MoviesView.syntheticItem(from: p)
            return item.map { MoviesHeroPage(item: $0, progress: p) }
        }
        if !resumes.isEmpty { heroPages = resumes; return }
        if let single = recentlyAdded.first ?? visibleMovies.first {
            heroPages = [MoviesHeroPage(item: single, progress: nil)]
        } else {
            heroPages = []
        }
    }

    /// Genre pills: the visible categories, in store order, "All" first.
    private var genrePills: [String] {
        vodStore.movieCategories.map(\.name).filter { !hiddenGroups.contains($0) }
    }

    /// The library grid: visible movies, genre-filtered, sorted (cached).
    private var libraryMovies: [VODDisplayItem] { derived.library }

    private func cycleSort() {
        let all = MoviesSortOrder.allCases
        let idx = all.firstIndex(of: sortOrder) ?? 0
        sortOrderRaw = all[(idx + 1) % all.count].rawValue
    }

    /// Minimal item for a resume row whose catalog entry is not loaded
    /// (same shape ContinueWatchingSection synthesizes for View Movie).
    /// Watchlist rows for the active playlist, resolved against the loaded
    /// library (so the card carries the full movie) with a synthetic
    /// fallback so a saved title still shows before the sweep reaches it.
    private var watchlistItems: [VODDisplayItem] {
        let sid = activeServerIDString
        let rows = watchlistEntries.filter { e in
            guard e.vodType == "movie" else { return false }
            guard let sid else { return true }
            return e.serverID == nil || e.serverID == sid
        }
        guard !rows.isEmpty else { return [] }
        let wanted = Set(rows.map(\.vodID))
        var byID: [String: VODDisplayItem] = [:]
        for m in vodStore.movies where wanted.contains(m.id) && byID[m.id] == nil { byID[m.id] = m }
        return rows.compactMap { e in byID[e.vodID] ?? MoviesView.syntheticItem(from: e) }
    }

    private static func syntheticItem(from e: WatchlistEntry) -> VODDisplayItem? {
        guard let sid = e.serverID, let serverUUID = UUID(uuidString: sid) else { return nil }
        let movie = VODMovie(
            id: e.vodID, name: e.title,
            posterURL: e.posterURL.flatMap { URL(string: $0) }, backdropURL: nil,
            rating: e.rating, plot: "", genre: "", releaseDate: e.releaseYear, duration: "",
            cast: "", director: "", imdbID: "", categoryID: "", categoryName: "",
            streamURL: nil, containerExtension: "", serverID: serverUUID)
        return VODDisplayItem(movie: movie)
    }

    /// Long-press menu on a poster: Details, then Add to / Remove from
    /// Watchlist.
    @ViewBuilder
    private func watchlistMenuButton(_ item: VODDisplayItem) -> some View {
        let saved = watchlistEntries.contains { $0.vodID == item.id
            && ($0.serverID == nil || $0.serverID == item.serverID.uuidString) }
        Button {
            navPath.append(item)
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        Button {
            WatchlistManager.toggle(item)
        } label: {
            Label(saved ? "Remove from Watchlist" : "Add to Watchlist",
                  systemImage: saved ? "bookmark.slash" : "bookmark")
        }
    }

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
    private func heroPrimary(_ page: MoviesHeroPage) {
        let item = page.item
        if let p = page.progress {
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
                title: item.displayName,
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
            // While a server search is in flight the header (with the
            // field) stays put here so it does not vanish under the spinner.
            if !searchText.isEmpty && vodStore.isSearchingMovies && filteredMovies.isEmpty {
                libraryHeader(title: "Results", count: 0, showPills: false)
                    .padding(.leading, contentLeadingInset)
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
                ZStack(alignment: .topLeading) {
                ScrollView {
                    Color.clear.frame(height: 0).id("movies-top")
                    #if os(tvOS)
                    // The tab bar's reserved top inset as plain content (the
                    // ScrollView ignores the top safe area). FIXED height:
                    // animating it to zero when the bar hid shifted the whole
                    // content and re-laid out the grid on every frame of that
                    // animation, exactly while the focus engine was scrolling
                    // from the carousel to the tiles (Logan 2026-09-03:
                    // "that small section stutters"). Content scrolls under
                    // the bar region regardless, so nothing is lost.
                    Color.clear.frame(height: outer.safeAreaInsets.top)
                    #endif
                    if !searchText.isEmpty {
                        // Search: results grid only, no hero or shelves.
                        VStack(alignment: .leading, spacing: sectionSpacing) {
                            libraryHeader(title: "Results", count: filteredMovies.count, showPills: false)
                                .padding(.leading, contentLeadingInset)
                            posterGrid(filteredMovies)
                                .padding(.leading, contentLeadingInset)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: sectionSpacing) {
                            #if os(iOS)
                            iOSTitleRow
                            #endif
                            // Continue Watching IS the hero: one page per title
                            // in progress (Logan 2026-09-03), so the separate
                            // poster row is gone from this tab.
                            let pages = heroPages
                            if !pages.isEmpty {
                                MoviesHeroCarousel(
                                    pages: pages,
                                    headers: dispatcharrHeaders,
                                    focusRequest: heroFocusRequestBinding,
                                    restoreRequest: Binding(get: { heroRestoreRequest },
                                                            set: { heroRestoreRequest = $0 }),
                                    onUpWhileScrolled: {
                                        #if os(tvOS)
                                        if tvTabBarHidden { scrollMoviesToTop(proxy) }
                                        #endif
                                    },
                                    onHeroFocusChange: { focused in
                                        #if os(tvOS)
                                        heroHasFocus = focused
                                        guard focused else { return }
                                        tabBarOnScreen = TVFocusBridge.isTabBarOnScreen(preferredTitle: "Movies")
                                        // Any hero button gaining focus while the
                                        // page is scrolled brings the page back to
                                        // the top, focus staying on that button
                                        // (Logan 2026-09-04: Up from Search should
                                        // scroll up AND land on the hero button).
                                        if !tabBarOnScreen, !scrollToTopInFlight {
                                            debugLog("[FOCUS] hero focused while scrolled: scrolling to top")
                                            scrollToTopInFlight = true
                                            withAnimation(.smooth(duration: 0.45)) {
                                                scrollPosition.scrollTo(y: 0)
                                            }
                                            // Bar back at once: waiting for the
                                            // scroll left a 0.6 s window where a
                                            // quick second Up was swallowed by the
                                            // top strip (trace 2026-09-04 15:12).
                                            tvTabBarHidden = false
                                            focusTabBarWhenOnScreen(attempt: 0)
                                        }
                                        #endif
                                    },
                                    onPrimary: { heroPrimary($0) },
                                    onPlayFromStart: { playMovie($0.item, resumePositionMs: 0) },
                                    onDetails: { navPath.append($0.item) },
                                    onRemove: { page in
                                        guard let p = page.progress else { return }
                                        WatchProgressManager.delete(vodID: p.vodID, serverID: p.serverID)
                                    },
                                    isOnWatchlist: { page in
                                        watchlistEntries.contains { $0.vodID == page.item.id
                                            && ($0.serverID == nil || $0.serverID == page.item.serverID.uuidString) }
                                    },
                                    onToggleWatchlist: { page in WatchlistManager.toggle(page.item) }
                                )
                                #if os(tvOS)
                                .focusSection()
                                #endif
                            }

                            let watchlist = watchlistItems
                            if !watchlist.isEmpty {
                                posterShelf(title: "Watchlist", items: watchlist)
                                    .padding(.leading, contentLeadingInset)
                                    .background(GeometryReader { g in
                                        Color.clear.onAppear { geometryBox.watchlistShelfHeight = g.size.height }
                                            .onChange(of: g.size.height) { _, h in geometryBox.watchlistShelfHeight = h }
                                    })
                            }
                            if !recentlyAdded.isEmpty {
                                posterShelf(title: "Recently Added", items: recentlyAdded)
                                    .padding(.leading, contentLeadingInset)
                            }

                            libraryHeader(title: "All Movies", count: libraryMovies.count, showPills: true)
                                .padding(.leading, contentLeadingInset)
                            railCatcherAndGrid(libraryMovies)
                                .background(GeometryReader { g in
                                    Color.clear.preference(
                                        key: GridTopKey.self,
                                        value: g.frame(in: .named("moviesScroll")).minY.rounded())
                                })
                        }
                    }

                    #if os(iOS)
                    Color.clear.frame(height: 96)
                    #endif
                }
                // Alphabet rail: pinned to the leading edge, jumps the
                // library grid to the first title for a letter.
                .coordinateSpace(name: "moviesScroll")
                .scrollPosition($scrollPosition)
                .onPreferenceChange(GridTopKey.self) { gridTopY in
                    guard let gridTopY else { return }
                    geometryBox.gridTopVisible = gridTopY
                    let top = max(railCenteredTop(in: outer.size.height + outer.safeAreaInsets.top),
                                  gridTopY + railGridOffset)
                    if railTop != top { railTop = top }
                }
                #if os(tvOS)
                // Menu while the tab bar is hidden: back to the top and
                // bring the bar back, instead of the TabView's default
                // handling (which landed on the default tab). With the bar
                // showing, Menu is left alone so it focuses the bar as usual.
                // Always attached: toggling the handler on and off let a
                // later press reach BOTH this and the TabView's handler
                // (scrolled to top, then switched to Live TV). When there
                // is nothing to scroll, the press is forwarded to the
                // tab-level routing by notification.
                .onExitCommand {
                    debugLog("[MOVIES-EXIT] hidden=\(tvTabBarHidden)")
                    if tvTabBarHidden {
                        scrollMoviesToTop(proxy)
                    } else {
                        NotificationCenter.default.post(name: .aerioTabMenuPassthrough, object: nil)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .aerioTabScrollToTop)) { _ in
                    guard tvTabBarHidden else { return }
                    scrollMoviesToTop(proxy)
                }
                // The Watchlist shelf appearing above the grid pushed the
                // page content down under a fixed offset, which read as an
                // auto-scroll up (Logan 2026-09-04). Offset by the shelf's
                // height so the focused poster stays put.
                .onChange(of: watchlistItems.isEmpty) { wasEmpty, isEmpty in
                    guard wasEmpty, !isEmpty, geometryBox.contentOffsetY > 0 else { return }
                    DispatchQueue.main.async {
                        let h = geometryBox.watchlistShelfHeight
                        guard h > 0 else { return }
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) {
                            scrollPosition.scrollTo(y: geometryBox.contentOffsetY + h)
                        }
                    }
                }
                // Player dismissed at the top of the tab: tvOS was re-seating
                // focus on the rail's # with no way out. Put it on the hero.
                .onChange(of: isPlaying) { _, playing in
                    guard !playing, !tvTabBarHidden, navPath.isEmpty else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        heroFocusRequest = true
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { _, y in
                    geometryBox.contentOffsetY = y
                    // Hide as soon as the content moves so the bar, its
                    // reserved inset, and the nav circles leave together
                    // (Logan 2026-09-03: the circles lagged behind the bar).
                    // Hide only once the hero has scrolled away (header and
                    // grid): while the hero is on screen the bar stays, so Up
                    // from any hero button reaches the Movies pill directly
                    // (a hidden bar was unreachable from two of the three
                    // buttons, Logan 2026-09-03). 560 = top inset + hero.
                    // Hiding re-lays out the TabView; doing that while the
                    // focus-driven scroll is still moving read as jitter
                    // (Logan 2026-09-04), so the hide waits for the scroll
                    // to settle. Showing is immediate (the top strip and
                    // hero focus handle their own sequencing).
                    let hide = y > 560
                    wantsTabBarHidden = hide
                    // Flag the intent at once: HomeView's parked-bar heal
                    // (2.5 s after a tab switch) remounted the TabView
                    // while the hide was still deferred (trace 2026-09-04
                    // 15:16, "forced back up to the Movies tab").
                    // Assign only on change: a @Published write fires
                    // objectWillChange even for an equal value, and this
                    // ran per scroll frame, re-rendering HomeView's TabView
                    // and every guide cell (Time Profiler 2026-09-04 15:48:
                    // main thread saturated by GuideProgramButton.body
                    // while scrolling posters).
                    let wantHidden = hide || tvTabBarHidden
                    if TVTabBarScrollState.shared.isHidden != wantHidden {
                        TVTabBarScrollState.shared.isHidden = wantHidden
                    }
                    if !hide, tvTabBarHidden {
                        tvTabBarHidden = false
                    } else if hide, !tvTabBarHidden, scrollIsIdle {
                        tvTabBarHidden = true
                    }
                }
                .onScrollPhaseChange { _, phase in
                    scrollIsIdle = phase == .idle
                    if phase == .idle, wantsTabBarHidden, !tvTabBarHidden {
                        tvTabBarHidden = true
                    }
                    if phase == .idle, !tvTabBarHidden, let p = pendingDerived {
                        derived = p
                        pendingDerived = nil
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .onChange(of: tvTabBarHidden) { _, hidden in
                    let wantHidden = hidden || wantsTabBarHidden
                    if TVTabBarScrollState.shared.isHidden != wantHidden {
                        TVTabBarScrollState.shared.isHidden = wantHidden
                    }
                    if !hidden, let p = pendingDerived {
                        derived = p
                        pendingDerived = nil
                    }
                }
                .onChange(of: gridFocus) { _, id in
                    if let id { lastGridFocus = id }
                    debugLog("[FOCUS] grid title focus -> \(id ?? "nil")")
                }

                .onDisappear { TVTabBarScrollState.shared.isHidden = false }
                #endif

                #if os(tvOS)
                // Fixed strip at the very top of the screen while a hero
                // button has focus: Up from ANY hero button, at any scroll
                // position, hits this guide and is redirected to the Movies
                // pill (tvOS expands the collapsed bar as it takes focus).
                // Stays mounted while the catcher itself holds focus: the
                // strip vanished mid-handoff (hero focus already nil), focus
                // went to nil and tvOS re-seated it on the rail (trace
                // 2026-09-04 14:10).
                // Only while a hero button has focus AND the TabView has slid
                // its bar off screen (content scrolled). With the bar on
                // screen tvOS reaches it natively from every hero button
                // (first test 2026-09-04); anything placed above the hero in
                // that state broke the native hop (trace 14:21). Off screen,
                // nothing above can take focus, so this strip catches Up,
                // scrolls the page to the top and lands on Resume; the next
                // Up is native. Stays mounted while it holds focus.
                if (heroHasFocus && !tabBarOnScreen && !scrollToTopInFlight) || topCatcherFocused {
                    Color.clear
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                        .ignoresSafeArea(.container, edges: .top)
                        .focusable(true)
                        .focused($topCatcherFocused)
                        .onChange(of: topCatcherFocused) { _, focused in
                            guard focused else { return }
                            debugLog("[FOCUS] top catcher: bar off screen, scrolling to top")
                            scrollToTopInFlight = true
                            withAnimation(.smooth(duration: 0.45)) {
                                scrollPosition.scrollTo(y: 0)
                            }
                            tvTabBarHidden = false
                            focusTabBarWhenOnScreen(attempt: 0)
                            // Restore at once: holding focus here for
                            // 0.5 s while the bar slid in read as the
                            // Movies pill taking focus and losing it again
                            // (Logan 2026-09-04).
                            heroRestoreRequest = true
                            // Once the bar has slid back on screen, hand
                            // focus to the Movies pill; the earlier
                            // requestFocusUpdate attempts ran while the bar
                            // was still off screen.
                            focusTabBarWhenOnScreen(attempt: 0)
                        }
                }
                #endif

                // Rail: a sibling of the ScrollView, not an overlay on it and
                // not in its content, so focusing it never scrolls the grid.
                if searchText.isEmpty, let railTop {
                    ZStack(alignment: .topLeading) {
                        #if os(tvOS)
                        // Invisible catcher under the letters: if the focus
                        // engine reaches this instead of a letter, focus is
                        // forwarded to #.
                        // Starts at the rail's top, not the screen top: a
                        // catcher above the letters caught Up from # and
                        // forwarded it back to # (trace 2026-09-04 14:11,
                        // an endless loop). Up from # now finds nothing and
                        // the rail's own exit takes focus to the hero.
                        // Padding goes OUTSIDE the focusable: with it
                        // inside, the focus item's frame started at the
                        // screen top (trace 2026-09-04 14:39, @80,0 72x1020)
                        // and Up from any hero button landed here.
                        Color.clear
                            .frame(width: railWidth,
                                   height: max(0, outer.size.height + outer.safeAreaInsets.top - railTop))
                            .focusable(true)
                            .focused($railCatcherFocused)
                            .onChange(of: railCatcherFocused) { _, focused in
                                if focused { railFocusRequest = "#" }
                            }
                            .padding(.top, railTop)
                        #endif
                        AlphabetRail(
                            available: railLetters,
                            focusRequest: railFocusRequestBinding,
                            onFocusChange: { hasFocus in
                                #if os(tvOS)
                                if hasFocus { railHadFocus = true }
                                #endif
                            },
                            onExitRight: {
                                #if os(tvOS)
                                railHadFocus = false
                                // A lazy row that is not built cannot take
                                // focus (stuck-on-# after playback, Logan
                                // 2026-09-03), so with no poster to return
                                // to, land on the hero instead.
                                if let last = lastGridFocus {
                                    gridFocus = last
                                } else {
                                    heroFocusRequest = true
                                }
                                #endif
                            },
                            onExitUp: {
                                #if os(tvOS)
                                railHadFocus = false
                                heroFocusRequest = true
                                #endif
                            }
                        ) { letter in
                            let found = firstGridID(for: letter)
                            debugLog("[RAIL] click \(letter) -> \(found ?? "nil") (letters=\(railLetters.count), library=\(libraryMovies.count))")
                            guard let id = found else { return }
                            let itemID = String(id.dropFirst("grid-".count))
                            if let index = libraryMovies.firstIndex(where: { $0.id == itemID }),
                               geometryBox.rowPitch > 0, geometryBox.gridWidth > 0 {
                                // Adaptive columns: floor((W + spacing) / (min + spacing)).
                                let cols = tvGridColumns
                                let row = index / cols
                                let gridTopContent = geometryBox.gridTopVisible + geometryBox.contentOffsetY
                                let y = gridTopContent + 16 + CGFloat(row) * geometryBox.rowPitch - 24
                                debugLog("[RAIL] jump row=\(row) cols=\(cols) y=\(y) pitch=\(geometryBox.rowPitch)")
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    scrollPosition.scrollTo(y: max(0, y))
                                }
                            } else {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                            #if os(tvOS)
                            // Once the row is on screen, put focus on that
                            // title so the click lands the user in the grid.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                railHadFocus = false
                                gridFocus = itemID
                            }
                            #endif
                        }
                        .frame(width: railWidth)
                        .padding(.top, railTop)
                    }
                    #if os(tvOS)
                    .ignoresSafeArea(.container, edges: [.top, .leading])
                    #else
                    .ignoresSafeArea(.container, edges: .top)
                    #endif
                }
                }
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

    /// Where the rail parks once the grid has scrolled under it: centered
    /// vertically in the scroll area.
    private func railCenteredTop(in height: CGFloat) -> CGFloat {
        // Sits a little below true center (Logan 2026-09-03): the eye reads
        // the rail against the poster rows, which start below the top edge.
        #if os(tvOS)
        return max(8, (height - AlphabetRail.totalHeight) / 2 + 80)
        #else
        return max(8, (height - AlphabetRail.totalHeight) / 2)
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

    /// Leading inset for shelves, header and grid. tvOS: 0, the rail lives
    /// in the 80 pt safe-area margin so the content lines up with the hero
    /// card's left edge (Logan 2026-09-04). iOS keeps the rail's width.
    private var contentLeadingInset: CGFloat {
        #if os(tvOS)
        // Lines the shelves, header and grid up with the hero COPY (Resume
        // button), not the faded card edge: hero inset 16 + copy inset 44,
        // minus the 16 each section already pads (Logan 2026-09-04).
        return 44
        #else
        return railWidth
        #endif
    }

    /// Letters that have at least one title in the library grid (cached).
    private var railLetters: Set<String> { derived.railLetters }

    /// Grid row id of the first title in this letter's bucket (cached).
    private func firstGridID(for letter: String) -> String? {
        derived.firstGridID[letter]
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        return 28
        #else
        return 18
        #endif
    }

    #if os(tvOS)
    private var railFocusRequestBinding: Binding<String?> {
        Binding(get: { railFocusRequest }, set: { railFocusRequest = $0 })
    }

    private var heroFocusRequestBinding: Binding<Bool> {
        Binding(get: { heroFocusRequest }, set: { heroFocusRequest = $0 })
    }

    private func focusTabBarWhenOnScreen(attempt: Int) {
        guard attempt < 15 else {
            debugLog("[HERO-FOCUS] bar never came on screen; focus stays on hero")
            scrollToTopInFlight = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if TVFocusBridge.isTabBarOnScreen(preferredTitle: "Movies") {
                // requestFocusUpdate(to: pill) returns moved=false even
                // with the bar on screen (trace 2026-09-04 14:46), so the
                // pill is reached natively: drop the catcher strip and let
                // the next Up travel from the hero button to the bar.
                tabBarOnScreen = true
                scrollToTopInFlight = false
                debugLog("[HERO-FOCUS] bar on screen after \(attempt + 1) polls; catcher unmounted")
            } else {
                focusTabBarWhenOnScreen(attempt: attempt + 1)
            }
        }
    }

    private func scrollMoviesToTop(_ proxy: ScrollViewProxy) {
        // Near the top (hero / header): ease up so it reads as a scroll.
        // Deep in the grid: jump, because an animated scroll crawled up
        // through every row (Logan 2026-09-03, both directions of that ask).
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) {
            proxy.scrollTo("movies-top", anchor: .top)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            tvTabBarHidden = false
        }
        // Device log 2026-09-03 18:28:48: a press was routed here and the
        // grid stayed put (the next press two seconds later found the bar
        // still hidden). tvOS keeps the focused poster on screen, so the
        // scroll to top was undone. Move focus onto the hero once the
        // top is in view so nothing off-screen pulls the scroll back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            heroFocusRequest = true
        }
    }

    /// Search field (when open) and the Search, Sort, Manage Groups circles.
    /// Lives in the library header now (Logan 2026-09-03).
    private var tvHeaderControls: some View {
        HStack(spacing: 14) {
            if showSearchField {
                // Same UIKit-backed field Settings uses: transparent, never
                // paints the system white focus platter. The box below is
                // the resting shape and the accent ring is the focus state.
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
        // Native tvOS action list, same surface as the multiview tile menus.
        .confirmationDialog("Sort Movies", isPresented: $showSortMenu, titleVisibility: .visible) {
            ForEach(MoviesSortOrder.allCases, id: \.self) { order in
                Button(order == sortOrder ? "\(order.label)  \u{2713}" : order.label) {
                    sortOrderRaw = order.rawValue
                }
            }
            Button("Cancel", role: .cancel) {}
        }
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
    }

    private func railCatcherAndGrid(_ items: [VODDisplayItem]) -> some View {
        posterGrid(items).padding(.leading, contentLeadingInset)
    }
    #else
    private var railFocusRequestBinding: Binding<String?> { .constant(nil) }
    private var heroFocusRequestBinding: Binding<Bool> { .constant(false) }

    private func railCatcherAndGrid(_ items: [VODDisplayItem]) -> some View {
        posterGrid(items).padding(.leading, contentLeadingInset)
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

    /// "All Movies · N" with the genre pills and, on tvOS, the search /
    /// sort / filter controls on the right.
    private func libraryHeader(title: String, count: Int, showPills: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.headlineSmall)
                    .foregroundColor(.textPrimary)
                Text("\(count)")
                    .font(.labelMedium)
                    .foregroundColor(.textTertiary)
                #if os(tvOS)
                // Directly beside the title (Logan 2026-09-03), not
                // pushed to the far right.
                tvHeaderControls
                    .padding(.leading, 12)
                Spacer()
                #else
                Spacer()
                Text(sortOrder.label)
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
                #endif
            }
            .padding(.horizontal, 16)
            #if os(tvOS)
            .focusSection()
            #endif

            if showPills && !genrePills.isEmpty {
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
                        .buttonStyle(MoviesPosterFocusStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .contextMenu { watchlistMenuButton(item) }
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
        return tvGridColumnSpacing
        #else
        return 12
        #endif
    }
    private var shelfCardWidth: CGFloat {
        #if os(tvOS)
        // Match the grid's adaptive tile width (min 200, spacing 32) so
        // shelf posters line up with the library columns (Logan 2026-09-04).
        let w = geometryBox.gridWidth
        guard w > 0 else { return 200 }
        return (w - CGFloat(tvGridColumns - 1) * tvGridColumnSpacing) / CGFloat(tvGridColumns)
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
                .buttonStyle(MoviesPosterFocusStyle())
                .focused($gridFocus, equals: item.id)
                #else
                .buttonStyle(.plain)
                #endif
                .contextMenu { watchlistMenuButton(item) }
                .id("grid-\(item.id)")
                .background(GeometryReader { g in
                    Color.clear.onAppear {
                        if item.id == items.first?.id {
                            geometryBox.rowPitch = g.size.height + gridRowSpacing
                        }
                    }
                })
            }
        }
        .padding(16)
        .background(GeometryReader { g in
            Color.clear.onAppear { geometryBox.gridWidth = g.size.width - 32 }
                .onChange(of: g.size.width) { _, w in geometryBox.gridWidth = w - 32 }
        })
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
            // Fill the cell: a fixed 200x300 poster left every wider grid
            // cell as empty gap (Logan 2026-09-04, "too spread out").
            .aspectRatio(2/3, contentMode: .fit)
            .frame(maxWidth: .infinity)
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
                Text(item.displayName)
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
/// One hero page: a title plus its resume row when it is in progress.
struct MoviesHeroPage: Identifiable {
    let item: VODDisplayItem
    let progress: WatchProgress?
    var id: String { item.id }
}

/// Paged hero: one full-width MoviesHero per Continue Watching title. On
/// tvOS, focus moving right off a page's last button lands on the next
/// page's first button and the banner slides over; on iOS it swipes.
struct MoviesHeroCarousel: View {
    let pages: [MoviesHeroPage]
    var headers: [String: String] = [:]
    /// Owner sets true to put focus on the aligned page's Resume; reset here.
    var focusRequest: Binding<Bool> = .constant(false)
    /// tvOS: Up from a hero button while the tab bar is hidden (page
    /// scrolled). The owner snaps to the top and shows the bar; the next
    /// Up then reaches the bar normally. The focus engine found the hidden
    /// bar from Resume but not from the other buttons (Logan 2026-09-03).
    /// tvOS: set true to put focus back on the hero button that held it
    /// last (falls back to Resume).
    var restoreRequest: Binding<Bool> = .constant(false)
    var onUpWhileScrolled: (() -> Void)? = nil
    /// tvOS: true while any hero button has focus (owner shows the fixed
    /// tab-bar focus guide).
    var onHeroFocusChange: ((Bool) -> Void)? = nil
    let onPrimary: (MoviesHeroPage) -> Void
    let onPlayFromStart: (MoviesHeroPage) -> Void
    let onDetails: (MoviesHeroPage) -> Void
    let onRemove: (MoviesHeroPage) -> Void
    /// Long press on the primary button: Add to / Remove from Watchlist.
    var isOnWatchlist: ((MoviesHeroPage) -> Bool)? = nil
    var onToggleWatchlist: ((MoviesHeroPage) -> Void)? = nil

    /// tvOS: focus arriving from above is forwarded to the aligned page's
    /// Resume (geometry alone landed on the page peeking in on the right).
    /// The catcher exists only while focus is outside the hero, so Up from
    /// a hero button goes straight to the tab bar.
    @State private var currentID: String?
    #if os(tvOS)
    /// "<page id>|primary|start|details" of the focused hero button.
    @FocusState private var heroFocus: String?
    @FocusState private var catcherFocused: Bool
    @State private var heroWasFocused = false
    @State private var lastHeroButton: String?
    @ObservedObject private var barState = TVTabBarScrollState.shared
    private var primaryFocusID: String { "\(currentID ?? pages.first?.id ?? "")|primary" }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            // Two different strips share the slot above the hero:
            // - no hero button focused: a SwiftUI catcher, so Down from the
            //   bar lands here and is forwarded to Resume;
            // - a hero button focused: a UIKit focus guide preferring the
            //   Movies tab pill, so Up from ANY hero button is redirected by
            //   the engine itself onto the pill. Device log 2026-09-04: the
            //   engine found the pill only from Resume, and
            //   requestFocusUpdate(to: pill) from a catcher never moved.
            // No hero button focused: a catcher so Down from the bar lands
            // here and is forwarded to Resume. While a hero button HAS
            // focus, the owner shows a fixed focus guide at the top of the
            // screen (outside the scroll content: in the scrolled state the
            // hero's top edge is above the screen, so anything placed here
            // is off screen and Up has no target; screenshots 2026-09-04).
            if heroFocus == nil {
                Color.clear
                    .frame(height: 8)
                    .frame(maxWidth: .infinity)
                    .focusable(true)
                    .focused($catcherFocused)
                    .onChange(of: catcherFocused) { _, focused in
                        debugLog("[FOCUS] hero catcher focused=\(focused) barHidden=\(barState.isHidden)")
                        guard focused else { return }
                        heroFocus = primaryFocusID
                    }
            } else {
                Color.clear.frame(height: 8)
            }
            #endif
            carousel
                #if os(tvOS)
                .onChange(of: heroFocus) { _, id in
                    if id != nil { heroWasFocused = true; lastHeroButton = id }
                    onHeroFocusChange?(id != nil)
                    debugLog("[FOCUS] hero button focus -> \(id ?? "nil")")
                    if id != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            TVFocusBridge.logFocusability(preferredTitle: "Movies")
                        }
                    }
                }
                .onChange(of: focusRequest.wrappedValue) { _, wanted in
                    guard wanted else { return }
                    heroFocus = primaryFocusID
                    focusRequest.wrappedValue = false
                }
                .onChange(of: restoreRequest.wrappedValue) { _, wanted in
                    guard wanted else { return }
                    heroFocus = lastHeroButton ?? primaryFocusID
                    restoreRequest.wrappedValue = false
                }
                #endif
        }
    }

    private var carousel: some View {
        GeometryReader { geo in
            // Pages are narrower than the row so the next title peeks in
            // (Logan 2026-09-03); view-aligned snapping keeps one page
            // leading. Single page keeps the full width.
            let pageWidth = pages.count > 1 ? geo.size.width * pageFraction : geo.size.width
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: pageSpacing) {
                    ForEach(pages) { page in
                        MoviesHero(
                            item: page.item,
                            progress: page.progress,
                            headers: headers,
                            onPrimary: { onPrimary(page) },
                            onPlayFromStart: { onPlayFromStart(page) },
                            onDetails: { onDetails(page) },
                            onRemove: page.progress != nil ? { onRemove(page) } : nil,
                            isOnWatchlist: isOnWatchlist?(page) ?? false,
                            onToggleWatchlist: onToggleWatchlist.map { toggle in { toggle(page) } },
                            primaryFocusID: page.id
                        )
                        .frame(width: pageWidth)
                        .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)
            .scrollClipDisabled()
            #if os(tvOS)
            .focusedHeroPage($heroFocus)
            #endif
            .overlay(alignment: .bottomTrailing) {
                if pages.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(pages) { page in
                            Circle()
                                .fill(page.id == (currentID ?? pages.first?.id)
                                      ? Color.accentPrimary : Color.textTertiary.opacity(0.5))
                                .frame(width: dot, height: dot)
                        }
                    }
                    .padding(.trailing, dotInset)
                    .padding(.bottom, dotInset)
                }
            }
        }
        .frame(height: heroHeight)
    }

    #if os(tvOS)
    private let heroHeight: CGFloat = 420
    private let dot: CGFloat = 10
    private let dotInset: CGFloat = 40
    private let pageFraction: CGFloat = 0.62
    private let pageSpacing: CGFloat = 8
    #else
    private let heroHeight: CGFloat = 220
    private let dot: CGFloat = 6
    private let dotInset: CGFloat = 28
    private let pageFraction: CGFloat = 0.86
    private let pageSpacing: CGFloat = 4
    #endif
}

struct MoviesHero: View {
    let item: VODDisplayItem
    let progress: WatchProgress?
    var headers: [String: String] = [:]
    let onPrimary: () -> Void
    let onPlayFromStart: () -> Void
    let onDetails: () -> Void
    /// Long press on Resume: Remove from Continue Watching. nil when the
    /// page is not a resume row.
    var onRemove: (() -> Void)? = nil
    var isOnWatchlist: Bool = false
    var onToggleWatchlist: (() -> Void)? = nil
    /// tvOS: base id the carousel uses to focus this page's buttons
    /// ("<id>|primary", "<id>|start", "<id>|details").
    var primaryFocusID: String? = nil
    #if os(tvOS)
    @Environment(\.heroFocusBinding) private var heroFocusBinding
    #endif

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
                AuthPosterImage(url: url, headers: headers, placeholder: .clear, maxPixel: 1920)
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
            // No eyebrow (Logan 2026-09-03): the carousel is Continue
            // Watching, the label was redundant.
            Text(item.displayName)
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
                    .frame(maxWidth: 560, alignment: .leading)
            }
            #endif
            actions
        }
        .padding(copyInset)
        #if os(tvOS)
        .frame(maxWidth: 720, alignment: .leading)
        #else
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            primaryButton
                .contextMenu {
                    if let onToggleWatchlist {
                        Button(action: onToggleWatchlist) {
                            Label(isOnWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                                  systemImage: isOnWatchlist ? "bookmark.slash" : "bookmark")
                        }
                    }
                    if let onRemove {
                        Button(role: .destructive, action: onRemove) {
                            Label("Remove from Continue Watching", systemImage: "trash")
                        }
                    }
                }
            #if os(tvOS)
            if progress != nil {
                heroFocusable(MoviesHeroButton(title: "Play from Beginning", systemImage: "gobackward",
                                               isPrimary: false, action: onPlayFromStart), role: "start")
            }
            heroFocusable(MoviesHeroButton(title: "Details", systemImage: "info.circle",
                                           isPrimary: false, action: onDetails), role: "details")
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
        #if os(tvOS)
        // One focus section for the row: Up from ANY button is resolved
        // from the row's frame, the frame Resume already reaches the
        // (system-collapsed) tab bar from (Logan 2026-09-03: Up from Play
        // from Beginning went nowhere at that scroll position).
        .focusSection()
        #endif
    }

    @ViewBuilder
    private var primaryButton: some View {
        heroFocusable(MoviesHeroButton(
            title: progress != nil ? "Resume" : "Play",
            systemImage: "play.fill", isPrimary: true, action: onPrimary), role: "primary")
    }

    /// tvOS: binds a hero button to the carousel's focus state under
    /// "<page id>|<role>" so the carousel knows when ANY hero button has
    /// focus (its Up catcher must not exist then; tracking only Resume
    /// left Up from Details bouncing back to Resume, Logan 2026-09-03).
    @ViewBuilder
    private func heroFocusable<V: View>(_ view: V, role: String) -> some View {
        #if os(tvOS)
        if let binding = heroFocusBinding, let primaryFocusID {
            view.focused(binding, equals: "\(primaryFocusID)|\(role)")
        } else {
            view
        }
        #else
        view
        #endif
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
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
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
    /// Set by the owner to move focus onto a letter (tvOS); cleared here.
    var focusRequest: Binding<String?> = .constant(nil)
    var onFocusChange: ((Bool) -> Void)? = nil
    /// tvOS: Right on a letter leaves the rail (the owner puts focus back
    /// on the grid). Moves are handled here because the focus engine did
    /// not cross between the rail and the scroll content on its own.
    var onExitRight: (() -> Void)? = nil
    /// tvOS: Up from # leaves the rail upward (owner focuses the hero).
    var onExitUp: (() -> Void)? = nil
    let onSelect: (String) -> Void

    nonisolated static let letters: [String] = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }

    /// Full column height (27 cells), for centering the parked rail.
    static var totalHeight: CGFloat {
        #if os(tvOS)
        return 27 * 32
        #else
        return 27 * 15
        #endif
    }

    /// Rail bucket for a title: its first letter, folded to A to Z, or #
    /// for anything else (digits, symbols, leading articles kept as-is).
    nonisolated static func bucket(for name: String) -> String {
        guard let first = stripQualityPrefix(name).first else { return "#" }
        let folded = String(first).folding(options: .diacriticInsensitive, locale: nil).uppercased()
        guard let c = folded.first, c.isLetter, c.isASCII else { return "#" }
        return String(c)
    }

    /// Provider quality tags in front of the real title ("4K: Thor",
    /// "[HD] Alien", "UHD - Dune", "FHD | Heat") are dropped so the rail
    /// buckets on the title itself (Logan 2026-09-03).
    nonisolated static func stripQualityPrefix(_ name: String) -> Substring {
        var s = Substring(name.trimmingCharacters(in: .whitespaces))
        while true {
            var t = s
            if t.first == "[" || t.first == "(" { t = t.dropFirst() }
            guard let tag = ["UHD", "FHD", "4K", "HD", "SD"].first(where: {
                t.uppercased().hasPrefix($0)
            }) else { break }
            t = t.dropFirst(tag.count)
            if t.first == "]" || t.first == ")" { t = t.dropFirst() }
            // Require a separator (or space) after the tag so "Hidden" is
            // not mistaken for an HD tag.
            guard let sep = t.first, sep == ":" || sep == "-" || sep == "|" || sep == " " else { break }
            while let c = t.first, c == ":" || c == "-" || c == "|" || c == " " { t = t.dropFirst() }
            guard !t.isEmpty, t != s else { break }
            s = t
        }
        return s
    }

    #if os(tvOS)
    @FocusState private var focused: String?
    #endif

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Self.letters, id: \.self) { letter in
                let enabled = available.contains(letter)
                Button {
                    if let target = nearestAvailable(to: letter) { onSelect(target) }
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
                // App-owned focus visual (the circle above); the system
                // platter .plain draws on tvOS is the big white pill.
                #if os(tvOS)
                .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
                #else
                .buttonStyle(.plain)
                #endif
                // Every letter stays focusable (Logan 2026-09-03: on a panel
                // where most titles start with a digit, only # was enabled
                // and the rail could not take focus). Unavailable letters
                // are dimmed and resolve to the nearest one with titles.
                #if os(tvOS)
                .focused($focused, equals: letter)
                #endif
            }
        }
        .padding(.leading, leadingInset)
        #if os(tvOS)
        .focusSection()
        .onChange(of: focused) { old, letter in
            debugLog("[FOCUS] rail letter focus \(old ?? "nil") -> \(letter ?? "nil")")
            onFocusChange?(letter != nil)
            // Entering from outside lands on # (Logan 2026-09-03); moving
            // within the rail is left alone. Focus alone never moves the
            // grid; only a click does.
            if old == nil, let letter, letter != "#" {
                focused = "#"
            }
        }
        .onChange(of: focusRequest.wrappedValue) { _, letter in
            guard let letter else { return }
            focused = letter
            focusRequest.wrappedValue = nil
        }
        // Only Right is handled; the focus engine steps letters on its own
        // (handling Up/Down here too moved two letters per swipe).
        .onMoveCommand { direction in
            switch direction {
            case .right: onExitRight?()
            case .up: if focused == Self.letters.first { onExitUp?() }
            default: break
            }
        }
        #endif
    }

    /// The letter itself when it has titles, else the closest one after
    /// it, else the closest one before it.
    private func nearestAvailable(to letter: String) -> String? {
        if available.contains(letter) { return letter }
        guard let idx = Self.letters.firstIndex(of: letter) else { return nil }
        if let after = Self.letters[idx...].first(where: { available.contains($0) }) { return after }
        return Self.letters[..<idx].last(where: { available.contains($0) })
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
    private let fontSize: CGFloat = 21
    private let cell: CGFloat = 32
    private let leadingInset: CGFloat = 20
    #else
    private let spacing: CGFloat = 0
    private let fontSize: CGFloat = 10
    private let cell: CGFloat = 15
    private let leadingInset: CGFloat = 6
    #endif
}

#if os(tvOS)
// MARK: - Hero focus plumbing (tvOS)

/// Hands the carousel's FocusState binding down to each page so its Resume
/// button can be focused programmatically.
private struct HeroFocusBindingKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: FocusState<String?>.Binding? = nil
}

extension EnvironmentValues {
    var heroFocusBinding: FocusState<String?>.Binding? {
        get { self[HeroFocusBindingKey.self] }
        set { self[HeroFocusBindingKey.self] = newValue }
    }
}

extension View {
    func focusedHeroPage(_ binding: FocusState<String?>.Binding) -> some View {
        environment(\.heroFocusBinding, binding)
    }
}
#endif

extension Notification.Name {
    /// A tab handled Menu itself and found nothing to do; MainTabView runs
    /// its normal Menu routing (switch to Live TV, etc.).
    static let aerioTabMenuPassthrough = Notification.Name("aerioTabMenuPassthrough")
    /// MainTabView got Menu while the current tab had scrolled its bar
    /// away: the tab scrolls back to the top and shows the bar.
    static let aerioTabScrollToTop = Notification.Name("aerioTabScrollToTop")
}

#if os(tvOS)
/// Poster focus for the Movies tab: scale only. TVCardButtonStyle adds a
/// 12pt drop shadow on focus, which re-rasterizes the whole scaling card
/// every frame of the focus animation; with the scroll animating at the
/// same time (pills -> first tile row) that was the remaining stutter
/// (Time Profiler 2026-09-03: main thread idle, so rendering cost). The
/// accent ring on the poster itself is the focus indicator.
struct MoviesPosterFocusStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif

#if os(tvOS)
/// Programmatic focus moves the SwiftUI focus engine cannot express.
enum TVFocusBridge {
    /// Asks UIKit to focus the TabView's bar container (expanding it when
    /// collapsed). Returns false when no bar view is in the window.
    /// True when the tab pill titled `preferredTitle` is within the window
    /// (the TabView slides the bar above the top edge once content scrolls).
    @MainActor
    static func isTabBarOnScreen(preferredTitle: String) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return true }
        var pill: UIView?
        func walk(_ v: UIView) {
            if pill != nil { return }
            if String(describing: type(of: v)) == "UITabBarButton",
               (v.accessibilityLabel ?? "") == preferredTitle { pill = v; return }
            for s in v.subviews { walk(s) }
        }
        walk(window)
        guard let pill else { return true }
        let f = pill.convert(pill.bounds, to: nil)
        let on = f.minY >= 0 && !pill.isHidden && pill.alpha > 0
        debugLog("[HERO-FOCUS] pill on screen=\(on) y=\(Int(f.minY))")
        return on
    }

    /// Diagnostic: what the focus system thinks of the tab pill and of the
    /// currently focused item (UIFocusDebugger, tvOS 15+).
    @MainActor
    static func logFocusability(preferredTitle: String) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return }
        var buttons: [UIView] = []
        var guides: [UIView] = []
        func walk(_ v: UIView) {
            let n = String(describing: type(of: v))
            if n == "UITabBarButton" { buttons.append(v) }
            if n.contains("GuideHostView") { guides.append(v) }
            for s in v.subviews { walk(s) }
        }
        walk(window)
        if let pill = buttons.first(where: { ($0.accessibilityLabel ?? "") == preferredTitle }) {
            // No UIFocusDebugger calls here: status() raises when invoked
            // from the app (crash 2026-09-04 14:00).
            debugLog("[FOCUS-DBG] pill \(preferredTitle) window=\(pill.convert(pill.bounds, to: nil)) hidden=\(pill.isHidden) alpha=\(pill.alpha) canBecomeFocused=\(pill.canBecomeFocused) userInteraction=\(pill.isUserInteractionEnabled)")
        } else {
            debugLog("[FOCUS-DBG] pill \(preferredTitle) not in window")
        }
        for g in guides {
            debugLog("[FOCUS-DBG] guide host frame=\(g.convert(g.bounds, to: nil)) hidden=\(g.isHidden) alpha=\(g.alpha) layoutGuides=\(g.layoutGuides.count)")
        }
        if let item = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView {
            debugLog("[FOCUS-DBG] focused item frame(window)=\(item.convert(item.bounds, to: nil)) type=\(String(describing: type(of: item)))")
        }
    }

    /// Device log 2026-09-04 13:36: asking for the CONTAINER did nothing
    /// (it is not a focus item; focus stayed on the catcher, i.e. on
    /// nothing visible). The tab pill itself (UITabBarButton) is the
    /// item. Prefer the pill titled `preferredTitle` (the current tab),
    /// else any pill. Returns true only when focus actually moved.
    @MainActor
    static func focusTabBar(preferredTitle: String) -> Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return false }
        var buttons: [UIView] = []
        func walk(_ v: UIView) {
            if String(describing: type(of: v)) == "UITabBarButton" { buttons.append(v) }
            for s in v.subviews { walk(s) }
        }
        walk(window)
        let target = buttons.first { ($0.accessibilityLabel ?? "") == preferredTitle } ?? buttons.first
        guard let target else {
            debugLog("[HERO-FOCUS] no UITabBarButton in window")
            return false
        }
        guard let system = UIFocusSystem.focusSystem(for: target) else { return false }
        system.requestFocusUpdate(to: target)
        system.updateFocusIfNeeded()
        let moved = system.focusedItem === target
        debugLog("[HERO-FOCUS] requested focus on UITabBarButton(\(target.accessibilityLabel ?? "?")) frame=\(target.frame); moved=\(moved)")
        return moved
    }
}
#endif

#if os(tvOS)
/// Debug: logs every tvOS focus move while the Movies tab is on screen, with
/// the previous item, the next item, and the heading, so a "focus vanished"
/// report can be read from the device log instead of guessed at.
@MainActor
final class MoviesFocusTracer {
    static let shared = MoviesFocusTracer()
    private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        Self.installPressLogging()
        token = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
        ) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            func desc(_ item: UIFocusItem?) -> String {
                guard let item else { return "nil" }
                let name = String(describing: type(of: item))
                // Every focus item has a frame in its container's space;
                // convert to window space when it is a view.
                var f = item.frame
                var label = ""
                if let v = item as? UIView {
                    f = v.convert(v.bounds, to: nil)
                    label = v.accessibilityLabel ?? (v as? UIButton)?.currentTitle ?? ""
                } else if let container = item.parentFocusEnvironment as? UIView {
                    f = container.convert(item.frame, to: nil)
                }
                return "\(name)\(label.isEmpty ? "" : "(\(label))") @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            }
            let heading: String
            switch ctx.focusHeading {
            case .up: heading = "UP"
            case .down: heading = "DOWN"
            case .left: heading = "LEFT"
            case .right: heading = "RIGHT"
            case .next: heading = "NEXT"
            case .previous: heading = "PREV"
            default: heading = "none"
            }
            debugLog("[FOCUS] \(heading): \(desc(ctx.previouslyFocusedItem)) -> \(desc(ctx.nextFocusedItem))")
        }
        debugLog("[FOCUS] tracer on")
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        debugLog("[FOCUS] tracer off")
    }

    /// Logs every remote press the app receives (swizzled
    /// UIApplication.sendEvent), so a press that moved no focus still
    /// shows up. Installed once; only logs while the tracer is on.
    static var pressLoggingInstalled = false
    static func installPressLogging() {
        guard !pressLoggingInstalled else { return }
        pressLoggingInstalled = true
        let cls: AnyClass = UIApplication.self
        guard let original = class_getInstanceMethod(cls, #selector(UIApplication.sendEvent(_:))),
              let swizzled = class_getInstanceMethod(cls, #selector(UIApplication.aerio_sendEvent(_:))) else { return }
        method_exchangeImplementations(original, swizzled)
    }
    var isOn: Bool { token != nil }
}

extension UIApplication {
    @objc func aerio_sendEvent(_ event: UIEvent) {
        if event.type == .presses, let presses = (event as? UIPressesEvent)?.allPresses, MoviesFocusTracer.shared.isOn {
            for press in presses where press.phase == .began || press.phase == .ended {
                let name: String
                switch press.type {
                case .upArrow: name = "UP"
                case .downArrow: name = "DOWN"
                case .leftArrow: name = "LEFT"
                case .rightArrow: name = "RIGHT"
                case .select: name = "SELECT"
                case .menu: name = "MENU"
                case .playPause: name = "PLAY/PAUSE"
                default: name = "type=\(press.type.rawValue)"
                }
                let env = UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                let focused = env.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
                let f = focused.map { String(describing: type(of: $0)) } ?? "nil"
                debugLog("[PRESS] \(name) \(press.phase == .began ? "began" : "ended") focused=\(f)")
            }
        }
        aerio_sendEvent(event)
    }
}
#endif

#if os(tvOS)
/// A UIFocusGuide hosted in SwiftUI: a region the tvOS focus engine treats
/// as a target and then redirects to `preferredFocusEnvironments`. Here it
/// sits above the hero and prefers the tab pill titled `preferredTitle`,
/// re-resolved on every layout pass (the pill view is recreated by the
/// TabView).
struct TabBarFocusGuide: UIViewRepresentable {
    let preferredTitle: String

    func makeUIView(context: Context) -> GuideHostView { GuideHostView(preferredTitle: preferredTitle) }
    func updateUIView(_ uiView: GuideHostView, context: Context) { uiView.refreshTarget() }

    final class GuideHostView: UIView {
        private let guide = UIFocusGuide()
        private let preferredTitle: String

        init(preferredTitle: String) {
            self.preferredTitle = preferredTitle
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            addLayoutGuide(guide)
            NSLayoutConstraint.activate([
                guide.leadingAnchor.constraint(equalTo: leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: trailingAnchor),
                guide.topAnchor.constraint(equalTo: topAnchor),
                guide.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() { super.didMoveToWindow(); refreshTarget() }
        override func layoutSubviews() { super.layoutSubviews(); refreshTarget() }

        func refreshTarget() {
            guard let window else { return }
            var buttons: [UIView] = []
            var container: UIView?
            func walk(_ v: UIView) {
                let n = String(describing: type(of: v))
                if n == "UITabBarButton" { buttons.append(v) }
                if container == nil, n.contains("TabBarContainerView") || v is UITabBar { container = v }
                for s in v.subviews { walk(s) }
            }
            walk(window)
            let pill = buttons.first { ($0.accessibilityLabel ?? "") == preferredTitle } ?? buttons.first
            // The bar's CONTAINER environment first: a pill refuses focus
            // arriving from outside its bar (trace 2026-09-04 14:15, the
            // guide's redirect to the pill failed and tvOS re-seated focus
            // on the rail); the container resolves its own preferred pill.
            var envs: [UIFocusEnvironment] = []
            if let container { envs.append(container) }
            if let pill { envs.append(pill) }
            if guide.preferredFocusEnvironments.first !== envs.first {
                guide.preferredFocusEnvironments = envs
                debugLog("[HERO-FOCUS] focus guide -> \(envs.map { String(describing: type(of: $0)) })")
            }
        }
    }
}
#endif
