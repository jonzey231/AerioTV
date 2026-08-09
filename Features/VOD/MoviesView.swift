import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

// MARK: - Authenticated Poster Image
// AsyncImage can't send auth headers. Dispatcharr's /media/ endpoints are protected,
// so we fetch with URLSession + the server's API key and cache in NSCache.

/// Two-level poster cache: an in-memory NSCache in front of a disk cache.
///
/// The memory tier was 300 images against libraries of 17,000+, so scrolling a
/// grid evicted covers faster than it could show them and every scroll-back
/// re-fetched over the network. Movies & TV leans much harder on posters (Home
/// shelves plus grids plus detail heroes), so both tiers grow: 2,000 entries
/// with a byte-cost ceiling in memory, and a write-through disk tier so covers
/// survive relaunch entirely.
///
/// Nothing here changes WHICH requests are made or what headers they carry: the
/// SSRF host gate in `AuthPosterImage` is untouched, and the disk tier only ever
/// stores bytes that gate already allowed.
final class AuthImageCache: @unchecked Sendable {
    static let shared = AuthImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let diskQueue = DispatchQueue(label: "app.molinete.aerio.postercache", qos: .utility)
    private let directory: URL?

    /// Roughly 192MB of decoded images; NSCache evicts by cost under pressure.
    private static let memoryCostLimit = 192 * 1024 * 1024
    private static let diskBudgetBytes: UInt64 = 512 * 1024 * 1024

    private init() {
        cache.countLimit = 2_000
        cache.totalCostLimit = Self.memoryCostLimit

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("PosterCache", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        directory = dir
        // One prune per launch is enough: the budget is a ceiling, not a target.
        diskQueue.asyncAfter(deadline: .now() + 20) { [weak self] in self?.pruneDisk() }
    }

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    /// Memory hit only. Callers that miss should try `diskImage` before the
    /// network, off the main actor.
    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    /// Disk lookup, safe to call from any thread. Populates the memory tier on
    /// a hit so the next scroll pass is instant.
    func diskImage(for key: String) -> UIImage? {
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url),
              let img = AerioImageDecoding.decode(data) else { return nil }
        store(img, for: key)
        // Touch so the LRU prune keeps what is actually being looked at.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return img
    }

    /// Write-through. Fire-and-forget on a utility queue; a failed write just
    /// means the next launch refetches.
    func storeOnDisk(_ data: Data, for key: String) {
        guard let url = fileURL(for: key) else { return }
        diskQueue.async { try? data.write(to: url, options: .atomic) }
    }

    /// Wipe both tiers (Settings cache clear).
    func clear() {
        cache.removeAllObjects()
        guard let directory else { return }
        diskQueue.async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func cost(of image: UIImage) -> Int {
        let scale = image.scale
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }

    /// Filename derived from the URL, not the URL itself: poster URLs can carry
    /// query credentials, and those must never become a filename on disk.
    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return directory.appendingPathComponent(String(format: "%016llx", hash))
    }

    /// Oldest-first deletion until the directory fits the budget.
    private func pruneDisk() {
        guard let directory else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var total: UInt64 = 0
        var items: [(url: URL, date: Date, size: UInt64)] = []
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = values.fileSize else { continue }
            let date = values.contentModificationDate ?? .distantPast
            total += UInt64(size)
            items.append((url, date, UInt64(size)))
        }
        guard total > Self.diskBudgetBytes else { return }

        for item in items.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: item.url)
            total -= min(total, item.size)
            if total <= Self.diskBudgetBytes { break }
        }
        debugLog("[PosterCache] pruned disk cache to \(total / 1024 / 1024)MB")
    }
}

struct AuthPosterImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    /// GH #53: reports the loaded image's pixel size so callers that
    /// frame the poster (Program Info) can follow the REAL aspect ratio
    /// instead of hard-cropping landscape EPG art into a 2:3 portrait
    /// frame. nil callers (grids with uniform poster cells) are unchanged.
    var onImageLoaded: ((CGSize) -> Void)? = nil

    @State private var uiImage: UIImage? = nil

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img).resizable()
            } else {
                Color.cardBackground
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
            // Disk tier before the network: a relaunch should paint covers from
            // local bytes instead of re-fetching the whole visible grid. Read
            // off-main so a cold scroll never blocks a frame on file I/O.
            if let fromDisk = await Task.detached(priority: .userInitiated, operation: {
                AuthImageCache.shared.diskImage(for: key)
            }).value {
                guard !Task.isCancelled else { return }
                uiImage = fromDisk
                onImageLoaded?(fromDisk.size)
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
            AuthImageCache.shared.storeOnDisk(data, for: key)
            guard !Task.isCancelled else { return }
            uiImage = img
            onImageLoaded?(img.size)
        }
    }
}

// MARK: - Movies View
struct MoviesView: View {
    @ObservedObject var vodStore: VODStore
    /// Shared with the pinned Sort pill in MoviesTVRootView, which lives
    /// outside this view's NavigationStack.
    @ObservedObject var browse: MediaBrowseModel
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
    #endif
    @State private var resumePlayingURL: IdentifiableURL?
    @State private var resumePlayingTitle = ""
    @State private var resumePlayingHeaders: [String: String] = [:]
    @State private var resumeVodID: String?
    @State private var resumePosterURL: String?
    @State private var resumeServerID: String?
    @State private var resumePositionMs: Int32 = 0

    private let hiddenGroupsKey = "hiddenMovieGroups"

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
            // Search results keep relevance order (local matches first, then
            // server hits): re-sorting them alphabetically would bury the thing
            // the user just typed the name of.
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
        return MediaGridQuery.apply(sort: browse.sort, to: result, seed: browse.randomSeed)
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
            // VODDetailView (which hides it) restores it on tvOS 27.
            .toolbar(.visible, for: .tabBar)
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
                    resumePositionMs: resumePositionMs
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
            if let sid = progress.serverID,
               let serverUUID = UUID(uuidString: sid),
               let server = servers.first(where: { $0.id == serverUUID }) {
                resumePlayingHeaders = server.authHeaders
            } else {
                resumePlayingHeaders = dispatcharrHeaders
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

    // MARK: - Content
    private var content: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            // tvOS: search toggle + inline text field (replaces .searchable keyboard)
            HStack(spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        showSearchField.toggle()
                        if !showSearchField { searchText = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(showSearchField ? .accentPrimary : .textSecondary)
                        .frame(width: 56, height: 56)
                        .background(
                            Circle()
                                .fill(showSearchField ? Color.accentPrimary.opacity(0.15) : Color.elevatedBackground)
                        )
                }
                .buttonStyle(TVNoHighlightButtonStyle())

                if showSearchField {
                    TextField("Search movies", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24))
                        .foregroundColor(.textPrimary)
                        .frame(width: 400)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.elevatedBackground)
                                .overlay(
                                    Capsule()
                                        .stroke(Color.accentPrimary.opacity(0.3), lineWidth: 1)
                                )
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Spacer()

                Button {
                    showManageGroups = true
                } label: {
                    Text("Filter")
                        .font(.headlineSmall)
                        .foregroundColor(.accentPrimary)
                }
                .buttonStyle(TVNoHighlightButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // Search + Filter are their own focus section so Down from
            // the Movies/Series pills lands here and Up from the rows
            // below returns here, instead of the tvOS focus engine
            // resolving geometrically and skipping the whole bar.
            .focusSection()
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
                // Its own focus section so "Show All" is a reachable
                // stop between the Search/Filter bar and Continue
                // Watching, instead of being skipped in both directions.
                .focusSection()
                #endif
            }

            if !searchText.isEmpty && vodStore.isSearchingMovies && filteredMovies.isEmpty {
                ProgressView("Searching server…")
                    .tint(.accentPrimary)
                    .padding(.top, 60)
                Spacer()
            } else {
                ScrollView {
                    // Continue Watching lives on the Home section now, as one
                    // merged rail across movies and episodes (dossier 5.3).
                    // Keeping a second copy here would show the same cards in
                    // two places and split the user's resume point between them.

                    LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                        ForEach(filteredMovies) { item in
                            NavigationLink(value: item) {
                                VODPosterCard(item: item, headers: dispatcharrHeaders)
                            }
                            #if os(tvOS)
                            .buttonStyle(TVCardButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(16)
                    #if os(tvOS)
                    // Grid is its own focus section so Down from the
                    // Continue Watching rail lands here cleanly and Up
                    // returns to the rail, rather than geometric jumps.
                    .focusSection()
                    #endif

                    #if os(iOS)
                    // Bottom content padding for the under-bar extension
                    // (ignoresSafeArea below) - last poster row scrolls
                    // clear of the floating tab bar + home indicator.
                    Color.clear.frame(height: 96)
                    #endif
                }
                #if os(iOS)
                // GH #20 (Android parity): auto-hide the iPhone tab bar on
                // grid scroll. Direction-based (2026-07-12): hide on a
                // deliberate downward scroll, full bar back on any upward
                // scroll. Same tracker + phone gate as Live TV.
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
                // GH #20 follow-up (see ChannelListView's twin): extend the
                // grid's frame under the floating iOS 26 tab bar so content
                // shows behind/below it instead of a dead band; the spacer
                // inside the ScrollView is the bottom content padding.
                .ignoresSafeArea(.container, edges: .bottom)
                // ...and keep the iOS 26 bottom scroll-edge effect from
                // painting an opaque platter over that region.
                .aerioContentUnderTabBar()
                #endif
            }
        }
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
