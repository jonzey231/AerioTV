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

    @State private var uiImage: UIImage? = nil

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img).resizable()
            } else {
                Color.cardBackground
            }
        }
        .task(id: url?.absoluteString) {
            guard let url else { return }
            let key = url.absoluteString
            if let cached = AuthImageCache.shared.image(for: key) {
                uiImage = cached
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 20)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let img = UIImage(data: data) else { return }
            AuthImageCache.shared.store(img, for: key)
            guard !Task.isCancelled else { return }
            uiImage = img
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

    #if os(tvOS)
    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 32)
    ]
    private let gridRowSpacing: CGFloat = 48
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
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
            .navigationTitle("Movies")
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
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
                if vodStore.movies.isEmpty && !vodStore.isLoadingMovies {
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
            // Rebase URL onto current effectiveBaseURL for LAN↔WAN switching
            var resolvedURL = url
            if let sid = progress.serverID,
               let serverUUID = UUID(uuidString: sid),
               let server = servers.first(where: { $0.id == serverUUID }) {
                resumePlayingHeaders = server.authHeaders
                if server.type == .dispatcharrAPI,
                   let proxyRange = urlStr.range(of: "/proxy/") {
                    let base = server.effectiveBaseURL.hasSuffix("/")
                        ? String(server.effectiveBaseURL.dropLast())
                        : server.effectiveBaseURL
                    resolvedURL = URL(string: base + String(urlStr[proxyRange.lowerBound...])) ?? url
                }
            } else {
                resumePlayingHeaders = dispatcharrHeaders
            }
            resumePlayingURL = IdentifiableURL(url: resolvedURL)
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
            }

            if !searchText.isEmpty && vodStore.isSearchingMovies && filteredMovies.isEmpty {
                ProgressView("Searching server…")
                    .tint(.accentPrimary)
                    .padding(.top, 60)
                Spacer()
            } else {
                ScrollView {
                    // Continue Watching section
                    ContinueWatchingSection(
                        vodType: "movie",
                        headers: dispatcharrHeaders,
                        onPlay: { progress in resumeFromContinueWatching(progress) }
                    )

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
                }
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
            return "\(prefix) \(name). Pull down to retry or tap the refresh button."
        }
        return "The server returned no movies. Pull down to retry or tap the refresh button."
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
