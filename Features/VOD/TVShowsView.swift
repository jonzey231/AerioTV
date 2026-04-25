import SwiftUI
import SwiftData

// MARK: - TV Shows View
struct TVShowsView: View {
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

    private let hiddenGroupsKey = "hiddenSeriesGroups"

    /// User-tunable UI scale (0.85–1.25). iPhone + tvOS ignore the value;
    /// iPad / Mac Catalyst stretch the poster minimum so the grid reads
    /// comfortably on wider displays (see AppearanceSettingsView).
    @AppStorage("uiScale") private var uiScale: Double = 1.0

    #if os(tvOS)
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 32)]
    }
    private let gridRowSpacing: CGFloat = 48
    #else
    private var columns: [GridItem] {
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

    private var filteredShows: [VODDisplayItem] {
        if !searchText.isEmpty {
            var combined = vodStore.series.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            let localIDs = Set(combined.map { $0.id })
            combined += vodStore.seriesSearchResults.filter { !localIDs.contains($0.id) }
            return combined
        }
        var result = vodStore.series
        if !hiddenGroups.isEmpty {
            result = result.filter { item in
                guard let cat = item.series?.categoryName else { return true }
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

                if vodStore.isLoadingSeries && vodStore.series.isEmpty {
                    LoadingView(message: "Loading series…")
                } else if let err = vodStore.seriesError, vodStore.series.isEmpty {
                    errorView(err)
                } else if vodStore.series.isEmpty {
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
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search series")
            #endif
            .onAppear {
                hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                if vodStore.series.isEmpty && !vodStore.isLoadingSeries {
                    vodStore.refreshSeries(servers: servers)
                }
            }
            .sheet(isPresented: $showManageGroups) {
                ManageGroupsSheet(
                    title: "Manage Groups",
                    allGroups: vodStore.seriesCategories.map(\.name),
                    storageKey: hiddenGroupsKey,
                    onDismiss: { updated in
                        hiddenGroups = updated
                    }
                )
            }
            .refreshable {
                vodStore.refreshSeries(servers: servers)
                // Allow the task one tick to start so isLoadingSeries flips to true first.
                try? await Task.sleep(for: .milliseconds(50))
                while vodStore.isLoadingSeries {
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            .onChange(of: searchText) { _, query in
                vodStore.searchSeries(query: query, servers: servers)
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
                hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
            }
            #if os(tvOS)
            // Top Shelf deep link for a series → navigate to its detail view.
            // The extension constructs `aerio://vod/series/<seriesID>` for
            // episode-type Continue Watching entries, so vodType == "series"
            // here matches both "tapped a series directly" and "tapped an
            // episode whose parent series we've navigated to".
            .onReceive(NotificationCenter.default.publisher(for: .aerioOpenVOD)) { notif in
                guard let vodType = notif.userInfo?["vodType"] as? String, vodType == "series",
                      let vodID = notif.userInfo?["vodID"] as? String else { return }
                tryHandleSeriesDeepLink(id: vodID, from: vodStore.series)
            }
            .onChange(of: vodStore.series) { _, series in
                // Cold-launch path: deep link came in before the series list
                // had loaded; try to resolve it now that the data is here.
                guard UserDefaults.standard.string(forKey: "launchVODType") == "series",
                      let pendingID = UserDefaults.standard.string(forKey: "launchVODID") else { return }
                tryHandleSeriesDeepLink(id: pendingID, from: series)
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
                    vodType: "episode",
                    resumePositionMs: resumePositionMs
                )
                .onDisappear { isPlaying = false }
            }
        }
    }

    #if os(tvOS)
    /// Looks up a series by ID in the given list and pushes its detail view
    /// onto the nav stack. Clears any existing detail first so repeated
    /// deep links don't stack.
    private func tryHandleSeriesDeepLink(id: String, from series: [VODDisplayItem]) {
        guard let item = series.first(where: { $0.id == id }) else { return }
        UserDefaults.standard.removeObject(forKey: "launchVODID")
        UserDefaults.standard.removeObject(forKey: "launchVODType")
        UserDefaults.standard.removeObject(forKey: "launchOnSeries")
        debugLog("🔗 TVShowsView: deep link → pushing \(item.name)")
        navPath = NavigationPath()
        navPath.append(item)
    }
    #endif

    private func resumeFromContinueWatching(_ progress: WatchProgress) {
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
        // Fallback: find the series in the store and push to its detail view
        if let item = vodStore.series.first(where: { $0.id == progress.vodID }) {
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
                    TextField("Search series", text: $searchText)
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

            if !searchText.isEmpty && vodStore.isSearchingSeries && filteredShows.isEmpty {
                ProgressView("Searching server…")
                    .tint(.accentPrimary)
                    .padding(.top, 60)
                Spacer()
            } else {
                ScrollView {
                    // Continue Watching section
                    ContinueWatchingSection(
                        vodType: "episode",
                        headers: dispatcharrHeaders,
                        onPlay: { progress in resumeFromContinueWatching(progress) }
                    )

                    LazyVGrid(columns: columns, spacing: gridRowSpacing) {
                        ForEach(filteredShows) { item in
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
                icon: "tv",
                title: "No Series",
                message: "Add an Xtream Codes or Dispatcharr server to browse TV shows."
            )
        } else if servers.first(where: { $0.isActive })?.supportsVOD == false {
            EmptyStateView(
                icon: "tv",
                title: "Series Unavailable",
                message: "M3U playlists do not include VOD content. Switch to an Xtream Codes or Dispatcharr API playlist in Settings > Playlists to browse TV shows."
            )
        } else {
            EmptyStateView(
                icon: "tv",
                title: "No Series",
                message: serverContext("No series were returned by"),
                action: { vodStore.refreshSeries(servers: servers) },
                actionTitle: "Retry"
            )
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundColor(.statusWarning)
            Text("Failed to load TV shows")
                .font(.headlineLarge).foregroundColor(.textPrimary)
            if let serverName = vodStore.lastSeriesServerName {
                Text("Server: \(serverName)")
                    .font(.labelMedium).foregroundColor(.textSecondary)
            }
            Text(msg)
                .font(.bodyMedium).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton("Try Again") { vodStore.refreshSeries(servers: servers) }
                .frame(maxWidth: 200)
        }
        .padding(32)
    }

    private func serverContext(_ prefix: String) -> String {
        if let name = vodStore.lastSeriesServerName {
            return "\(prefix) \(name). Pull down to retry or tap the refresh button."
        }
        return "The server returned no series. Pull down to retry or tap the refresh button."
    }
}

// TVCategoryPill is defined in Components.swift
