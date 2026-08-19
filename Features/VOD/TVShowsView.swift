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
    // Provider copies for the resumed episode, so Switch Version works from
    // Continue Watching the same as it does from the series page (the movie
    // half of this shipped in 1.8.19; Logan flagged the episode gap 2026-08-19).
    @State private var resumeVersionOptions: [VODVersionOption] = []
    @State private var resumeVersionSelectionKey: String = ""

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
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search series")
            #endif
            .onAppear {
                hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                // v1.6.22: only auto-refresh when we genuinely have
                // no data for the active server. The previous
                // `series.isEmpty && !isLoadingSeries` guard re-fired
                // every time SwiftUI rebuilt this view after a load
                // that legitimately returned zero series, producing
                // an infinite refresh loop on servers whose API
                // returns empty (Freyguy1975's Synology Dispatcharr
                // repro). Comparing the active server's id against
                // `currentSeriesServerID` (set the moment a load
                // begins) lets us tell "fresh server we haven't
                // tried yet" from "already loaded, nothing came
                // back". Pull-to-refresh and the empty-state
                // Try Again button still bypass this guard since
                // they call `refreshSeries` directly.
                let activeServerID = (servers.first(where: { $0.isActive }) ?? servers.first)?.id
                let alreadyTriedThisServer = activeServerID != nil
                    && vodStore.currentSeriesServerID == activeServerID
                if vodStore.series.isEmpty
                    && !vodStore.isLoadingSeries
                    && !alreadyTriedThisServer {
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
            // ATV log 2026-08-17: same defect as MoviesView's resume path -
            // mounting the cover directly skipped the teardown VODDetailView
            // does, so a minimized live channel kept decoding (and playing
            // audio) underneath the episode.
            PlayerSession.shared.exit()
            // Same second symptom as MoviesView's resume: no version options
            // meant Switch Version was empty in the player even when the
            // series page shows several sources. Best-effort; never gates
            // playback. The selection key is the SERIES key (itemType
            // "series", series id) - identical to VODDetailView's, so a pin
            // made on the series page and one made mid-play in this resume
            // read and write the same stored choice.
            resumeVersionOptions = []
            let resumeServer: ServerConnection? = progress.serverID
                .flatMap(UUID.init(uuidString:))
                .flatMap { uuid in servers.first(where: { $0.id == uuid }) }
            if let serverUUID = progress.serverID.flatMap(UUID.init(uuidString:)),
               let seriesID = progress.seriesID {
                resumeVersionSelectionKey = VODVersionSelectionStore
                    .storageKey(serverID: serverUUID,
                                itemType: "series",
                                itemID: seriesID)
            } else {
                resumeVersionSelectionKey = ""
            }
            loadResumeVersionOptions(progress: progress, resumeURL: url, server: resumeServer)
            resumePlayingURL = IdentifiableURL(url: url)
            isPlaying = true
            return
        }
        // Fallback: find the series in the store and push to its detail view
        if let item = vodStore.series.first(where: { $0.id == progress.vodID }) {
            navPath.append(item)
        }
    }

    /// Fetch the parent series' provider copies so the resumed episode can
    /// offer Switch Version. Mirrors MoviesView.loadResumeVersionOptions with
    /// the episode differences from VODDetailView.buildVersionOptions:
    /// providers come from the SERIES id (progress.seriesID - an episode
    /// progress row's vodID is the episode's own id), episodes pin by
    /// m3u_account_id only (a series relation id does not address an episode
    /// row), so options dedupe to one per distinct account with the ACCOUNT
    /// id as the option id, and labels are the plain account name.
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
              let seriesID = progress.seriesID, let numericID = Int(seriesID) else {
            debugLog("[VOD-VERSION] episode resume skipped: no dispatcharr server or series id (vodID=\(progress.vodID))")
            return
        }
        // The episode's Dispatcharr UUID comes straight out of the resume URL
        // (/proxy/vod/episode/<uuid>[/<session>]), same lesson as the movie
        // path: the catalog may not hold this episode yet (mid-sync, or a
        // synced row from another device), but the URL is always present
        // because it is what we are about to play.
        let comps = resumeURL.pathComponents
        let uuid = comps.firstIndex(of: "episode")
            .flatMap { i in i + 1 < comps.count ? comps[i + 1] : nil } ?? ""
        guard !uuid.isEmpty else {
            debugLog("[VOD-VERSION] episode resume skipped: no uuid in \(resumeURL.path)")
            return
        }
        let server = resolved
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        Task { @MainActor in
            guard let providers = try? await api.getSeriesProviders(seriesID: numericID) else {
                debugLog("[VOD-VERSION] episode resume \(progress.vodID): providers fetch failed")
                return
            }
            var seen = Set<Int>()
            let options: [VODVersionOption] = providers.compactMap { rel in
                guard seen.insert(rel.account.id).inserted,
                      let url = api.proxyEpisodeURL(uuid: uuid,
                                                    m3uAccountID: rel.account.id) else { return nil }
                return VODVersionOption(id: rel.account.id,
                                        label: rel.account.name ?? "Source \(rel.account.id)",
                                        url: url)
            }
            guard options.count > 1 else {
                debugLog("[VOD-VERSION] episode resume \(progress.vodID): \(options.count) distinct account(s), no picker")
                return
            }
            resumeVersionOptions = options
            debugLog("[VOD-VERSION] episode resume \(progress.vodID): \(options.count) provider accounts")
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
                        activeServerID: (servers.first(where: { $0.isActive }) ?? servers.first)?.id.uuidString,
                        headers: dispatcharrHeaders,
                        onPlay: { progress in resumeFromContinueWatching(progress) },
                        series: vodStore.series,
                        onOpenSeries: { item in navPath.append(item) }
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
                // shows behind/below it instead of a dead band.
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
            return "\(prefix) \(name). Tap the retry button to try again."
        }
        return "The server returned no series. Tap the retry button to try again."
    }
}

// TVCategoryPill is defined in Components.swift
