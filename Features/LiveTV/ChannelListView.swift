import SwiftUI
import SwiftData

// MARK: - EPG Cache
// Actor-isolated in-memory cache. Keyed by a server+channel string so different
// servers never collide. TTL = 5 minutes; invalidated on pull-to-refresh.
actor EPGCache {
    static let shared = EPGCache()
    private struct Entry { let programs: [EPGEntry]; let fetchedAt: Date }
    private var cache: [String: Entry] = [:]
    private let ttl: TimeInterval = 1800  // 30 minutes — EPG loaded upfront on launch

    func get(_ key: String) -> [EPGEntry]? {
        guard let e = cache[key], Date().timeIntervalSince(e.fetchedAt) < ttl else { return nil }
        return e.programs
    }
    func set(_ programs: [EPGEntry], for key: String) {
        cache[key] = Entry(programs: programs, fetchedAt: Date())
    }
    func invalidateAll() { cache.removeAll() }
}

// MARK: - Channel List View
// Reads pre-loaded channel data from the shared ChannelStore (owned by MainTabView).
// The store begins fetching as soon as any server is configured, so this view is
// typically ready instantly when the user switches to the Live TV tab.
struct ChannelListView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingManager
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var channelStore: ChannelStore
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query private var servers: [ServerConnection]

    @State private var filteredChannels: [ChannelDisplayItem] = []
    @State private var searchText: String = ""
    @State private var selectedGroup: String = "All"
    @State private var prefetchTask: Task<Void, Never>? = nil
    @State private var hiddenGroups: Set<String> = []
    @State private var showManageGroups = false
    @AppStorage("defaultLiveTVView") private var defaultLiveTVView = "guide"
    @AppStorage("channelSortMode") private var sortModeRaw = "number"
    @State private var showGuideView = false
    #if os(tvOS)
    @State private var showSearchField = false
    #endif

    private let hiddenGroupsKey = "hiddenChannelGroups"

    var body: some View {
        NavigationStack {
            mainContent
                #if os(iOS)
                .navigationTitle("Live TV")
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbarBackground(Color.appBackground, for: .navigationBar)
                #if os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .toolbar {
                    // Sort menu (iOS + tvOS)
                    ToolbarItem(placement: {
                        #if os(iOS)
                        .navigationBarTrailing
                        #else
                        .automatic
                        #endif
                    }()) {
                        Menu {
                            Button {
                                sortModeRaw = "number"
                            } label: {
                                if sortModeRaw == "number" { Label("By Number", systemImage: "checkmark") } else { Text("By Number") }
                            }
                            Button {
                                sortModeRaw = "name"
                            } label: {
                                if sortModeRaw == "name" { Label("By Name", systemImage: "checkmark") } else { Text("By Name") }
                            }
                            Button {
                                sortModeRaw = "favorites"
                            } label: {
                                if sortModeRaw == "favorites" { Label("Favorites First", systemImage: "checkmark") } else { Text("Favorites First") }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                                .foregroundColor(.accentPrimary)
                        }
                    }
                    #if os(iOS)
                    // Guide view toggle — iPad only (iPhone always uses list)
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                withAnimation(.spring(response: 0.25)) { showGuideView.toggle() }
                            } label: {
                                Image(systemName: showGuideView ? "list.bullet" : "calendar")
                                    .foregroundColor(.accentPrimary)
                            }
                        }
                    }
                    #endif
                }
                #if os(iOS)
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search channels")
                #endif
                .onChange(of: searchText)       { _, _ in filterChannels() }
                .onChange(of: selectedGroup)    { _, _ in filterChannels() }
                .onChange(of: sortModeRaw)      { _, _ in filterChannels() }
                // Sync filtered list whenever the store delivers new data.
                .onChange(of: channelStore.channels) { _, items in
                    filterChannels()
                    favoritesStore.register(items: items)
                    #if os(tvOS)
                    // Cold-launch deep link: channels just finished loading and
                    // we have a pending channel ID from a Top Shelf click.
                    tryHandlePendingChannelDeepLink(from: items)
                    #endif
                }
                #if os(tvOS)
                // Warm-launch deep link: the app was already running, channels
                // are already loaded, and a Top Shelf click posted an
                // aerioOpenChannel notification. Start playback immediately.
                .onReceive(NotificationCenter.default.publisher(for: .aerioOpenChannel)) { notif in
                    guard let channelID = notif.userInfo?["channelID"] as? String else { return }
                    if let channel = channelStore.channels.first(where: { $0.id == channelID }),
                       !channel.streamURLs.isEmpty {
                        debugLog("🔗 ChannelListView: warm deep link → playing \(channel.name)")
                        UserDefaults.standard.removeObject(forKey: "launchChannelID")
                        nowPlaying.startPlaying(channel, headers: playerHeaders())
                    } else {
                        // Channels not yet loaded — leave launchChannelID set so
                        // the cold-path handler picks it up when they arrive.
                        debugLog("🔗 ChannelListView: warm deep link received but channel not loaded yet")
                    }
                }
                #endif
                .onAppear {
                    debugLog("🔷 ChannelListView.onAppear: channels=\(channelStore.channels.count), isLoading=\(channelStore.isLoading), thread=\(Thread.current)")
                    // Pull iCloud data while the user waits for channels/EPG to load
                    // (runs concurrently, doesn't block channel startup).
                    SyncManager.shared.pullFromCloud()
                    // Default to guide view if the active server has EPG data.
                    // M3U without EPG → default to list view (no guide data to show).
                    let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                    let hasEPG: Bool = {
                        guard let s = activeServer else { return false }
                        if s.type == .m3uPlaylist { return !s.epgURL.isEmpty }
                        return true
                    }()

                    #if os(tvOS)
                    showGuideView = hasEPG && defaultLiveTVView == "guide"
                    #else
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        showGuideView = hasEPG && defaultLiveTVView == "guide"
                    } else {
                        showGuideView = false
                    }
                    #endif
                    hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                    filterChannels()
                    favoritesStore.register(items: channelStore.channels)
                    #if os(tvOS)
                    // If channels are already loaded when this view appears
                    // (e.g. warm launch via Top Shelf deep link or tab switch),
                    // handle any pending deep link now since onChange won't fire.
                    if !channelStore.channels.isEmpty {
                        tryHandlePendingChannelDeepLink(from: channelStore.channels)
                    }
                    #endif
                    debugLog("🔷 ChannelListView.onAppear: done")
                }
                .onDisappear {
                    prefetchTask?.cancel()
                    prefetchTask = nil
                }
                .sheet(isPresented: $showManageGroups) {
                    ManageGroupsSheet(
                        title: "Manage Groups",
                        allGroups: channelStore.orderedGroups,
                        storageKey: hiddenGroupsKey,
                        onDismiss: { updated in
                            hiddenGroups = updated
                            // Reset selection if the current group was hidden
                            if selectedGroup != "All" && hiddenGroups.contains(selectedGroup) {
                                selectedGroup = "All"
                            }
                            filterChannels()
                        }
                    )
                }
                .onChange(of: servers.count) { _, _ in
                    // Re-evaluate guide view default when servers arrive (e.g., fresh install + iCloud sync)
                    let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                    let hasEPG: Bool = {
                        guard let s = activeServer else { return false }
                        if s.type == .m3uPlaylist { return !s.epgURL.isEmpty }
                        return true
                    }()
                    #if os(tvOS)
                    if hasEPG && defaultLiveTVView == "guide" && !showGuideView {
                        showGuideView = true
                    }
                    #else
                    if UIDevice.current.userInterfaceIdiom == .pad && hasEPG && defaultLiveTVView == "guide" && !showGuideView {
                        showGuideView = true
                    }
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: .syncManagerDidApplyPreferences)) { _ in
                    hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                    if selectedGroup != "All" && hiddenGroups.contains(selectedGroup) {
                        selectedGroup = "All"
                    }
                    filterChannels()
                }
                // Cancel EPG prefetch the moment playback starts — network requests
                // compete with the IPTV stream and cause buffering / stutter.
                .onChange(of: nowPlaying.isActive) { _, active in
                    if active {
                        prefetchTask?.cancel()
                        prefetchTask = nil
                        debugLog("📺 EPG prefetch: cancelled — playback started")
                    }
                }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if servers.isEmpty {
                EmptyStateView(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "No Servers",
                    message: "Add a server in Settings to browse Live TV channels."
                )
            } else if channelStore.isLoading && channelStore.channels.isEmpty {
                LoadingView(message: "Loading channels…")
            } else if let error = channelStore.error, channelStore.channels.isEmpty {
                errorView(error)
            } else if channelStore.channels.isEmpty {
                EmptyStateView(
                    icon: "tv",
                    title: "No Channels",
                    message: "No channels found on the active server.",
                    action: { Task { await channelStore.forceRefresh(servers: servers) } },
                    actionTitle: "Refresh"
                )
            } else if showGuideView {
                VStack(spacing: 0) {
                    if channelStore.orderedGroups.count > 1 || !hiddenGroups.isEmpty {
                        groupFilterBar
                            .padding(.vertical, 10)
                            #if os(tvOS)
                            .focusSection()
                            #endif
                    }
                    EPGGuideView(
                        channels: filteredChannels,
                        servers: Array(servers),
                        onSelectChannel: { item in
                            if !item.streamURLs.isEmpty {
                                nowPlaying.startPlaying(item, headers: playerHeaders())
                            }
                        }
                    )
                    #if os(tvOS)
                    .focusSection()
                    #endif
                }
            } else {
                channelListContent
            }
        }
    }

    // MARK: - Channel List Content

    private var channelListContent: some View {
        VStack(spacing: 0) {
            if channelStore.orderedGroups.count > 1 || !hiddenGroups.isEmpty {
                groupFilterBar
                    .padding(.vertical, 10)
                    #if os(tvOS)
                    .focusSection()
                    .focusEffectDisabled()
                    #endif
            }

            #if os(tvOS)
            // On tvOS, List draws a white highlight over any focused row —
            // ScrollView + LazyVStack gives us full visual control.
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredChannels) { item in
                        ChannelRow(
                            item: item,
                            onTap: {
                                if !item.streamURLs.isEmpty {
                                    nowPlaying.startPlaying(item, headers: playerHeaders())
                                }
                            },
                            fetchUpcoming: makeFetchUpcoming(for: item)
                        )
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color.appBackground)
            .focusSection()
            #else
            List {
                ForEach(filteredChannels) { item in
                    ChannelRow(
                        item: item,
                        onTap: {
                            if !item.streamURLs.isEmpty {
                                nowPlaying.startPlaying(item, headers: playerHeaders())
                            }
                        },
                        fetchUpcoming: makeFetchUpcoming(for: item)
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(
                        top: sizeClass == .regular ? 5 : 3,
                        leading: sizeClass == .regular ? 24 : 16,
                        bottom: sizeClass == .regular ? 5 : 3,
                        trailing: sizeClass == .regular ? 24 : 16
                    ))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .background(Color.appBackground)
            .scrollContentBackground(.hidden)
            .refreshable {
                await EPGCache.shared.invalidateAll()
                await channelStore.forceRefresh(servers: servers)
            }
            #endif
        }
    }

    // MARK: - Group Filter Bar

    private var groupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Guide toggle button (tvOS only — iOS uses the nav bar toolbar button)
                #if os(tvOS)
                TVGroupPill(
                    group: showGuideView ? "List" : "Guide",
                    isSelected: false,
                    action: { withAnimation(.spring(response: 0.25)) { showGuideView.toggle() } },
                    systemImage: showGuideView ? "list.bullet" : "calendar"
                )

                // Search toggle
                TVGroupPill(
                    group: "",
                    isSelected: showSearchField,
                    action: {
                        withAnimation(.spring(response: 0.25)) {
                            showSearchField.toggle()
                            if !showSearchField { searchText = "" }
                        }
                    },
                    systemImage: "magnifyingglass"
                )

                if showSearchField {
                    TextField("Search channels", text: $searchText)
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
                }
                #endif

                ManageGroupsButton(
                    action: { showManageGroups = true },
                    hiddenCount: hiddenGroups.count
                )

                ForEach(["All"] + visibleGroups, id: \.self) { group in
                    #if os(tvOS)
                    TVGroupPill(
                        group: group,
                        isSelected: selectedGroup == group,
                        action: { withAnimation(.spring(response: 0.25)) { selectedGroup = group } }
                    )
                    #else
                    Button {
                        withAnimation(.spring(response: 0.25)) { selectedGroup = group }
                    } label: {
                        Text(group)
                            .font(.labelMedium)
                            .foregroundColor(selectedGroup == group ? .appBackground : .textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedGroup == group
                                    ? AnyView(Capsule().fill(Color.accentPrimary))
                                    : AnyView(Capsule().fill(Color.elevatedBackground))
                            )
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.statusWarning)
            Text("Connection Error")
                .font(.headlineLarge)
                .foregroundColor(.textPrimary)
            Text(message)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton("Try Again") {
                Task { await channelStore.forceRefresh(servers: servers) }
            }
            .frame(maxWidth: 200)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: - Filtering

    private var visibleGroups: [String] {
        channelStore.orderedGroups.filter { !hiddenGroups.contains($0) }
    }

    private func filterChannels() {
        var result = channelStore.channels
        // Exclude channels belonging to hidden groups
        if !hiddenGroups.isEmpty {
            result = result.filter { !hiddenGroups.contains($0.group) }
        }
        if selectedGroup != "All" {
            result = result.filter { $0.group == selectedGroup }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        // Apply sort
        switch sortModeRaw {
        case "name":
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "favorites":
            result.sort {
                let fav0 = favoritesStore.isFavorite($0.id)
                let fav1 = favoritesStore.isFavorite($1.id)
                if fav0 != fav1 { return fav0 }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        default: // "number"
            break // Channels arrive in number order from ChannelStore
        }
        filteredChannels = result
        prefetchEPGForVisibleChannels(result)
    }

    /// Pre-warm the EPG cache for the first 20 visible channels so cards open instantly.
    /// Skipped entirely when playback is active — network requests compete with the
    /// IPTV stream and cause visible stuttering / rebuffer events.
    private func prefetchEPGForVisibleChannels(_ channels: [ChannelDisplayItem]) {
        prefetchTask?.cancel()
        // Don't fetch EPG while a stream is playing — bandwidth contention causes stutter.
        guard !nowPlaying.isActive else {
            debugLog("📺 EPG prefetch: skipped — playback active")
            return
        }
        prefetchTask = Task(priority: .utility) {
            for item in channels.prefix(20) {
                guard !Task.isCancelled else { return }
                guard let fetch = makeFetchUpcoming(for: item) else { continue }
                _ = await fetch()
            }
        }
    }

    // MARK: - Player Headers

    private func playerHeaders() -> [String: String] {
        guard let server = channelStore.activeServer ?? servers.first(where: { $0.isActive }) ?? servers.first else {
            return ["Accept": "*/*"]
        }
        return server.authHeaders
    }

    // MARK: - Deep Link Handler

    #if os(tvOS)
    /// If `launchChannelID` is set in UserDefaults (from a Top Shelf deep
    /// link that arrived before channels were loaded), look it up in the
    /// freshly loaded channel list and start playback. No-op if no pending
    /// ID or the channel isn't found.
    private func tryHandlePendingChannelDeepLink(from items: [ChannelDisplayItem]) {
        guard let channelID = UserDefaults.standard.string(forKey: "launchChannelID"),
              let channel = items.first(where: { $0.id == channelID }),
              !channel.streamURLs.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "launchChannelID")
        debugLog("🔗 ChannelListView: cold deep link → playing \(channel.name)")
        nowPlaying.startPlaying(channel, headers: playerHeaders())
    }
    #endif

    // MARK: - Upcoming EPG Closure Factory

    private func makeFetchUpcoming(for item: ChannelDisplayItem) -> (() async -> [EPGEntry])? {
        guard let server = channelStore.activeServer ?? servers.first(where: { $0.isActive }) ?? servers.first else { return nil }
        switch server.type {
        case .dispatcharrAPI:
            let tvgID    = item.tvgID ?? ""
            let channelID = Int(item.id)
            // Need at least one identifier to query EPG
            guard !tvgID.isEmpty || channelID != nil else { return nil }
            let baseURL  = server.effectiveBaseURL
            let apiKey   = server.effectiveApiKey
            let cacheKey = "d_\(baseURL)_\(tvgID.isEmpty ? item.id : tvgID)"
            return {
                if let cached = await EPGCache.shared.get(cacheKey) { return cached }
                let dAPI = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey))
                do {
                    let identifier = tvgID.isEmpty ? "channelID=\(channelID ?? 0)" : "tvgID=\(tvgID)"
                    debugLog("📺 EPG fetch: \(identifier)")
                    let programs = try await dAPI.getUpcomingPrograms(
                        tvgIDs: tvgID.isEmpty ? nil : [tvgID],
                        channelIDs: tvgID.isEmpty ? (channelID.map { [$0] }) : nil
                    )
                    debugLog("📺 EPG result: \(identifier) → \(programs.count) upcoming programs")
                    let entries = programs.map {
                        let desc = $0.description.isEmpty ? $0.subTitle : $0.description
                        return EPGEntry(title: $0.title,
                                        description: desc,
                                        startTime: $0.startTime?.toDate(),
                                        endTime:   $0.endTime?.toDate())
                    }
                    await EPGCache.shared.set(entries, for: cacheKey)
                    return entries
                } catch {
                    let identifier = tvgID.isEmpty ? "channelID=\(channelID ?? 0)" : "tvgID=\(tvgID)"
                    debugLog("📺 EPG fetch FAILED: \(identifier) — \(error.localizedDescription)")
                    DebugLogger.shared.logEPG(event: "getUpcomingPrograms failed",
                                             channelID: tvgID.isEmpty ? item.id : tvgID, error: error)
                    return []
                }
            }
        case .xtreamCodes:
            let baseURL   = server.effectiveBaseURL
            let username  = server.username
            let password  = server.effectivePassword
            let streamID  = item.id
            let cacheKey  = "x_\(baseURL)_\(streamID)"
            return {
                if let cached = await EPGCache.shared.get(cacheKey) { return cached }
                let xAPI = XtreamCodesAPI(baseURL: baseURL, username: username, password: password)
                guard let epg = try? await xAPI.getEPG(streamID: streamID, limit: 48) else { return [] }
                let now = Date()
                let entries = epg.epgListings.compactMap { listing -> EPGEntry? in
                    let start = XtreamDateParser.parse(listing.start)
                    let end   = XtreamDateParser.parse(listing.end)
                    if let e = end, now >= e { return nil }
                    if let s = start, let e = end, now >= s && now < e { return nil }
                    return EPGEntry(title: listing.title, description: listing.description, startTime: start, endTime: end)
                }
                await EPGCache.shared.set(entries, for: cacheKey)
                return entries
            }
        case .m3uPlaylist:
            let epgURL   = server.effectiveEPGURL
            // No EPG URL → no schedule data to fetch
            guard !epgURL.isEmpty else { return nil }
            guard let tvgID = item.tvgID, !tvgID.isEmpty else { return nil }
            let cacheKey = "m3u_\(tvgID)"
            return {
                if let cached = await EPGCache.shared.get(cacheKey) { return cached }
                // Cache miss — re-fetch and re-index the full XMLTV feed.
                guard !epgURL.isEmpty, let epgURLParsed = URL(string: epgURL),
                      let programs = try? await XMLTVParser.fetchAndParse(url: epgURLParsed)
                else { return [] }
                let now = Date()
                var byChannel: [String: [ParsedEPGProgram]] = [:]
                for prog in programs { byChannel[prog.channelID, default: []].append(prog) }
                // Repopulate cache for all channels in the feed.
                for (channelID, progs) in byChannel {
                    let upcoming = progs
                        .filter { $0.endTime > now }
                        .sorted { $0.startTime < $1.startTime }
                        .map { EPGEntry(title: $0.title, description: $0.description, startTime: $0.startTime, endTime: $0.endTime) }
                    if !upcoming.isEmpty {
                        await EPGCache.shared.set(upcoming, for: "m3u_\(channelID)")
                    }
                }
                return await EPGCache.shared.get(cacheKey) ?? []
            }
        }
    }
}

// MARK: - Channel Display Item
struct ChannelDisplayItem: Identifiable, Equatable {
    let id: String
    let name: String
    let number: String
    let logoURL: URL?
    let group: String
    let categoryOrder: Int
    let streamURL: URL?
    let streamURLs: [URL]
    var tvgID: String? = nil
    var currentProgram: String? = nil
    var currentProgramDescription: String? = nil
    var currentProgramStart: Date? = nil
    var currentProgramEnd: Date? = nil
}

// MARK: - EPG Entry (for upcoming schedule)
struct EPGEntry: Identifiable, Equatable {
    var id: String { "\(title)-\(startTime?.timeIntervalSinceReferenceDate ?? 0)" }
    let title: String
    let description: String
    let startTime: Date?
    let endTime: Date?

    init(title: String, description: String = "", startTime: Date?, endTime: Date?) {
        self.title = title
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - Channel Row
struct ChannelRow: View {
    let item: ChannelDisplayItem
    let onTap: () -> Void
    var fetchUpcoming: (() async -> [EPGEntry])? = nil
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isExpanded = false
    @State private var upcomingPrograms: [EPGEntry] = []
    @State private var isLoadingUpcoming = false
    @State private var reminderTarget: EPGEntry?
    @State private var showReminderDialog = false
    #if os(tvOS)
    /// Tracks which part of the row has focus.
    /// Navigation: D-pad LEFT → star, D-pad RIGHT → expand/guide.
    @FocusState private var mainFocused: Bool
    @FocusState private var starFocused: Bool
    private var isCardFocused: Bool { mainFocused || starFocused || expandFocused }
    #endif

    #if os(tvOS)
    private let upcomingScrollMaxHeight: CGFloat = 480
    #else
    private let upcomingScrollMaxHeight: CGFloat = 260
    #endif

    /// True when running on a wider display (iPad / macOS).
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            tvRow
            #else
            iOSRow
            #endif

            if isExpanded {
                guidePanel
            }
        }
        .background {
            #if os(tvOS)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCardFocused ? Color.accentPrimary.opacity(0.18) : Color.cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            Color.accentPrimary.opacity(isCardFocused ? 0.65 : 0.10),
                            lineWidth: isCardFocused ? 2.5 : 1
                        )
                }
            #else
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentPrimary.opacity(0.10), lineWidth: 1)
                }
            #endif
        }
        #if os(tvOS)
        .conditionalExitCommand(isActive: isExpanded) {
            debugLog("🎮 Back pressed: collapsing expanded card for \(item.name)")
            withAnimation(.spring(response: 0.25)) { isExpanded = false }
        }
        #endif
    }

    // MARK: - tvOS Row
    // Three focusable elements side-by-side:
    //   ★  ← star button (D-pad LEFT from main)
    //      → channel info button (SELECT plays)
    //   ›  → expand button (D-pad RIGHT from main, toggles guide panel)
    #if os(tvOS)
    @FocusState private var expandFocused: Bool

    @ViewBuilder
    private var tvRow: some View {
        HStack(spacing: 0) {

            // ── Star button ───────────────────────────────────────────────
            // Reachable by pressing LEFT on the D-pad from the main content.
            // SELECT toggles the favorite.
            Button {
                favoritesStore.toggle(item)
            } label: {
                let isFav = favoritesStore.isFavorite(item.id)
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(
                        starFocused ? .white
                        : isFav     ? .statusWarning
                                    : .textTertiary.opacity(0.35)
                    )
                    .frame(width: 72)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background(
                        Circle()
                            .fill(starFocused
                                  ? (favoritesStore.isFavorite(item.id)
                                     ? Color.statusWarning.opacity(0.22)
                                     : Color.accentPrimary.opacity(0.18))
                                  : Color.clear)
                            .frame(width: 52, height: 52)
                    )
                    .scaleEffect(starFocused ? 1.18 : 1.0)
                    .animation(.easeInOut(duration: 0.13), value: starFocused)
            }
            .buttonStyle(TVNoRingButtonStyle())
            .focused($starFocused)

            // ── Main channel button ───────────────────────────────────────
            // SELECT plays the channel.
            Button {
                debugLog("🎮 Channel tap: \(item.name) (id=\(item.id))")
                onTap()
            } label: {
                HStack(spacing: 14) {
                    Text(item.number)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .foregroundColor(.textTertiary)
                        .frame(width: 42, alignment: .trailing)

                    CachedLogoImage(url: item.logoURL, width: 72, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)

                        if let program = item.currentProgram, !program.isEmpty {
                            HStack(spacing: 8) {
                                MarqueeText(text: program,
                                            font: .system(size: 22),
                                            color: .accentPrimary.opacity(0.85),
                                            isActive: isCardFocused)
                                    .frame(height: 28)
                                if let end = item.currentProgramEnd {
                                    nowPlayingTimeRemaining(end: end)
                                }
                            }
                            if let desc = item.currentProgramDescription, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 18))
                                    .foregroundColor(.textSecondary)
                                    .lineLimit(2)
                            }
                        } else {
                            Text(item.group)
                                .font(.system(size: 22))
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }

                        if let start = item.currentProgramStart,
                           let end   = item.currentProgramEnd,
                           item.currentProgram != nil {
                            nowPlayingProgressBar(start: start, end: end)
                                .padding(.top, 4)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 24)
                .padding(.leading, 8)
                .padding(.trailing, 4)
            }
            .buttonStyle(TVNoRingButtonStyle())
            .focused($mainFocused)
            .animation(.easeInOut(duration: 0.15), value: mainFocused)

            // ── Expand button ─────────────────────────────────────────────
            // Reachable by pressing RIGHT on the D-pad from the main content.
            // SELECT toggles the inline guide panel.
            Button {
                debugLog("🎮 Channel expand: \(item.name) — toggling schedule (expanded=\(!isExpanded))")
                withAnimation(.spring(response: 0.25)) { isExpanded.toggle() }
                if isExpanded && upcomingPrograms.isEmpty, fetchUpcoming != nil {
                    isLoadingUpcoming = true
                    Task {
                        upcomingPrograms = await fetchUpcoming?() ?? []
                        isLoadingUpcoming = false
                    }
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(
                        expandFocused ? .white
                        : isExpanded  ? .accentPrimary
                                      : .textTertiary.opacity(0.4)
                    )
                    .frame(width: 64)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background(
                        Circle()
                            .fill(expandFocused
                                  ? Color.accentPrimary.opacity(0.18)
                                  : Color.clear)
                            .frame(width: 48, height: 48)
                    )
                    .scaleEffect(expandFocused ? 1.18 : 1.0)
                    .animation(.easeInOut(duration: 0.13), value: expandFocused)
            }
            .buttonStyle(TVNoRingButtonStyle())
            .focused($expandFocused)
        }
    }
    #endif

    // MARK: - iOS / iPadOS Row (unchanged)
    #if !os(tvOS)
    @ViewBuilder
    private var iOSRow: some View {
        Button(action: onTap) {
            HStack(spacing: isWide ? 14 : 10) {
                Text(item.number)
                    .font(isWide ? .body.monospaced() : .monoSmall)
                    .lineLimit(1)
                    .foregroundColor(.textTertiary)
                    .frame(width: isWide ? 36 : 26, alignment: .trailing)

                CachedLogoImage(
                    url: item.logoURL,
                    width: isWide ? 50 : 38,
                    height: isWide ? 34 : 26
                )

                VStack(alignment: .leading, spacing: isWide ? 4 : 2) {
                    Text(item.name)
                        .font(isWide ? .body.weight(.medium) : .bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)

                    if let program = item.currentProgram, !program.isEmpty {
                        HStack(spacing: 8) {
                            MarqueeText(text: program,
                                        font: isWide ? .subheadline : .labelSmall,
                                        color: .accentPrimary.opacity(0.85),
                                        isActive: false)  // Static during scroll — saves GPU
                                .frame(height: isWide ? 20 : 16)
                            if let end = item.currentProgramEnd {
                                nowPlayingTimeRemaining(end: end)
                            }
                        }
                        if let desc = item.currentProgramDescription, !desc.isEmpty {
                            Text(desc)
                                .font(isWide ? .caption : .system(size: 10))
                                .foregroundColor(.textSecondary)
                                .lineLimit(2)
                        }
                    } else {
                        Text(item.group)
                            .font(isWide ? .subheadline : .labelSmall)
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)
                    }

                    if let start = item.currentProgramStart,
                       let end   = item.currentProgramEnd,
                       item.currentProgram != nil {
                        nowPlayingProgressBar(start: start, end: end)
                    }
                }

                Spacer()

                // ── Expand chevron (only action button remaining) ──
                if item.currentProgram != nil || fetchUpcoming != nil {
                    Button {
                        withAnimation(.spring(response: 0.25)) { isExpanded.toggle() }
                        if isExpanded && upcomingPrograms.isEmpty, fetchUpcoming != nil {
                            isLoadingUpcoming = true
                            Task {
                                upcomingPrograms = await fetchUpcoming?() ?? []
                                isLoadingUpcoming = false
                            }
                        }
                    } label: {
                        if isWide {
                            HStack(spacing: 5) {
                                Image(systemName: isExpanded ? "chevron.up" : "list.bullet")
                                    .font(.system(size: 11, weight: .medium))
                                Text(isExpanded ? "Hide Schedule" : "Schedule")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundColor(.accentPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.accentPrimary.opacity(0.12)))
                            .contentShape(Capsule())
                        } else {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.textTertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, isWide ? 18 : 13)
            .padding(.horizontal, isWide ? 18 : 14)
            .contentShape(Rectangle())  // Ensure entire row area is tappable
        }
        .buttonStyle(.plain)
        .contextMenu {
            let isFav = favoritesStore.isFavorite(item.id)
            Button {
                favoritesStore.toggle(item)
            } label: {
                Label(
                    isFav ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFav ? "star.slash" : "star.fill"
                )
            }
        }
    }
    #endif

    // MARK: - Guide Panel (shared iOS + tvOS)

    /// Upcoming programs filtered to exclude the currently-airing program
    /// (already shown in the channel card header).
    private var futurePrograms: [EPGEntry] {
        let now = Date()
        return upcomingPrograms.filter { entry in
            guard let end = entry.endTime else { return true }
            return end > now && (entry.startTime ?? now) > now
        }
    }

    @ViewBuilder
    private var guidePanel: some View {
        Divider()
            .background(Color.borderSubtle)
            .padding(.horizontal, 14)

        if fetchUpcoming != nil {
            if isLoadingUpcoming {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading schedule…")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else if futurePrograms.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundColor(.textTertiary)
                    Text("No upcoming schedule available")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(futurePrograms) { entry in
                            #if os(tvOS)
                            Button(action: {}) {
                                epgEntryRow(entry: entry, isLast: entry.id == futurePrograms.last?.id)
                            }
                            .buttonStyle(EPGRowButtonStyle())
                            .contextMenu { reminderMenu(for: entry) }
                            #else
                            PressableEPGRow(
                                entry: entry,
                                isLast: entry.id == futurePrograms.last?.id,
                                isFuture: entry.startTime.map { $0 > Date() } ?? false,
                                channelName: item.name,
                                rowContent: { epgEntryRow(entry: entry, isLast: entry.id == futurePrograms.last?.id) },
                                onLongPress: {
                                    reminderTarget = entry
                                    showReminderDialog = true
                                }
                            )
                            #endif
                        }
                    }
                }
                .frame(maxHeight: upcomingScrollMaxHeight)
                #if os(tvOS)
                .focusSection()
                #endif
                .padding(.bottom, 4)
                #if os(iOS)
                .confirmationDialog(
                    reminderTarget.flatMap { entry in
                        entry.startTime.map { start in
                            ReminderManager.shared.hasReminder(
                                forKey: ReminderManager.programKey(channelName: item.name, title: entry.title, start: start)
                            ) ? "Cancel Reminder" : "Set Reminder"
                        }
                    } ?? "Set Reminder",
                    isPresented: $showReminderDialog,
                    titleVisibility: .visible
                ) {
                    if let entry = reminderTarget, let start = entry.startTime {
                        let key = ReminderManager.programKey(channelName: item.name, title: entry.title, start: start)
                        if ReminderManager.shared.hasReminder(forKey: key) {
                            Button("Cancel Reminder", role: .destructive) {
                                ReminderManager.shared.cancelReminder(forKey: key)
                            }
                        } else {
                            Button("Remind Me 5 Min Before") {
                                ReminderManager.shared.scheduleReminder(
                                    programTitle: entry.title,
                                    channelName: item.name,
                                    startTime: start
                                )
                            }
                        }
                    }
                } message: {
                    if let entry = reminderTarget {
                        Text(entry.title)
                    }
                }
                #endif
            }
        }
    }

    // MARK: - Now Playing Helpers

    /// Compact time-remaining badge shown beside the current program title.
    /// Uses a plain Date() snapshot — accurate when the row appears, no per-row
    /// TimelineView overhead that causes batch re-renders during scroll.
    private func nowPlayingTimeRemaining(end: Date) -> some View {
        let remaining = max(0, end.timeIntervalSince(Date()))
        let mins = Int(remaining / 60)
        let label = mins < 60 ? "\(mins)m" : "\(mins / 60)h\(mins % 60 > 0 ? " \(mins % 60)m" : "")"
        return Text(label)
            #if os(tvOS)
            .font(.system(size: 18, weight: .medium, design: .monospaced))
            #else
            .font(.system(size: isWide ? 11 : 9, weight: .medium, design: .monospaced))
            #endif
            .foregroundColor(.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// Thin progress bar showing how far through the current program we are.
    private func nowPlayingProgressBar(start: Date, end: Date) -> some View {
        let total = end.timeIntervalSince(start)
        let elapsed = Date().timeIntervalSince(start)
        let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 0

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentPrimary.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentPrimary.opacity(0.7))
                    .frame(width: geo.size.width * fraction)
            }
        }
        #if os(tvOS)
        .frame(height: 5)
        #else
        .frame(height: 3)
        #endif
    }

    // MARK: - EPG Entry Row
    /// Shared row used inside the guide ScrollView (direct on iOS, wrapped in focusable Button on tvOS).
    @ViewBuilder
    private func reminderMenu(for entry: EPGEntry) -> some View {
        if let start = entry.startTime, start > Date() {
            let key = ReminderManager.programKey(channelName: item.name, title: entry.title, start: start)
            if ReminderManager.shared.hasReminder(forKey: key) {
                Button(role: .destructive) {
                    ReminderManager.shared.cancelReminder(forKey: key)
                } label: {
                    Label("Cancel Reminder", systemImage: "bell.slash")
                }
            } else {
                Button {
                    ReminderManager.shared.scheduleReminder(
                        programTitle: entry.title,
                        channelName: item.name,
                        startTime: start
                    )
                } label: {
                    Label("Set Reminder", systemImage: "bell")
                }
            }
        }
    }

    private func epgEntryRow(entry: EPGEntry, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.borderSubtle)
                    #if os(tvOS)
                    .frame(width: 3)
                    #else
                    .frame(width: 2)
                    #endif
                    .cornerRadius(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        #if os(tvOS)
                        .font(.system(size: 24, weight: .semibold))
                        #else
                        .font(.bodySmall)
                        #endif
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    if !entry.description.isEmpty {
                        Text(entry.description)
                            #if os(tvOS)
                            .font(.system(size: 18))
                            #else
                            .font(.labelSmall)
                            #endif
                            .foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                    if let start = entry.startTime {
                        HStack(spacing: 4) {
                            Text(start, style: .time)
                            if let end = entry.endTime {
                                Text("–")
                                Text(end, style: .time)
                            }
                        }
                        #if os(tvOS)
                        .font(.system(size: 17))
                        .foregroundColor(.textTertiary)
                        #else
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                        #endif
                    }
                }
                Spacer()

                // Bell indicator for programs with active reminders
                if let start = entry.startTime, start > Date(),
                   ReminderManager.shared.hasReminder(
                       forKey: ReminderManager.programKey(channelName: item.name, title: entry.title, start: start)
                   ) {
                    Image(systemName: "bell.fill")
                        #if os(tvOS)
                        .font(.system(size: 18))
                        #else
                        .font(.system(size: 12))
                        #endif
                        .foregroundColor(.accentPrimary)
                        .padding(.trailing, 4)
                }
            }
            #if os(tvOS)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            #else
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            #endif

            if !isLast {
                Divider()
                    .background(Color.borderSubtle.opacity(0.5))
                    .padding(.leading, 42)
            }
        }
    }
}

// MARK: - EPG Row Button Style (tvOS only)
#if os(tvOS)
/// Plain-looking ButtonStyle that gives each EPG row focusability
/// without adding a visible press effect or focus ring.
private struct EPGRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocused
                          ? Color.accentPrimary.opacity(0.18)
                          : configuration.isPressed
                              ? Color.accentPrimary.opacity(0.08)
                              : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

// Conditionally attaches .onExitCommand only when `isActive` is true.
// When inactive, the modifier is not applied, so the exit event passes
// through to parent handlers (e.g., HomeView's exit confirmation).
private struct ConditionalExitCommandModifier: ViewModifier {
    let isActive: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            content.onExitCommand(perform: action)
        } else {
            content
        }
    }
}

extension View {
    func conditionalExitCommand(isActive: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(ConditionalExitCommandModifier(isActive: isActive, action: action))
    }
}
#endif

// MARK: - Pressable EPG Row (iOS only)
// Wraps an EPG entry row with a short long-press gesture (0.35s) and
// visual press feedback (dimming + slight scale). Replaces .contextMenu
// which doesn't reliably trigger inside nested ScrollViews.
#if os(iOS)
private struct PressableEPGRow<Row: View>: View {
    let entry: EPGEntry
    let isLast: Bool
    let isFuture: Bool
    let channelName: String
    @ViewBuilder let rowContent: () -> Row
    let onLongPress: () -> Void

    @State private var isPressed = false

    var body: some View {
        rowContent()
            .contentShape(Rectangle())
            .opacity(isPressed ? 0.5 : 1.0)
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isPressed)
            .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
                if isFuture {
                    isPressed = pressing
                }
            }, perform: {
                guard isFuture else { return }
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                onLongPress()
            })
    }
}
#endif

// MARK: - Favorites View
struct FavoritesView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingManager
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @EnvironmentObject private var channelStore: ChannelStore
    @Query private var servers: [ServerConnection]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                if favoritesStore.favoriteItems.isEmpty {
                    EmptyStateView(
                        icon: "star",
                        title: "No Favorites",
                        message: "Tap the star on any channel in Live TV to add it here."
                    )
                } else {
                    List {
                        ForEach(favoritesStore.favoriteItems) { item in
                            ChannelRow(item: item) {
                                if !item.streamURLs.isEmpty {
                                    nowPlaying.startPlaying(item, headers: playerHeaders())
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            #if os(iOS)
                            .listRowSeparator(.hidden)
                            #endif
                        }
                    }
                    .listStyle(.plain)
                    .background(Color.appBackground)
                    #if os(iOS)
                    .scrollContentBackground(.hidden)
                    #endif
                }
            }
            .navigationTitle("Favorites")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
        }
    }

    private func playerHeaders() -> [String: String] {
        guard let server = channelStore.activeServer ?? servers.first(where: { $0.isActive }) ?? servers.first else {
            return ["Accept": "*/*"]
        }
        return server.authHeaders
    }
}

// MARK: - Marquee Text
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    /// When false, text is static (truncated). Saves CPU/GPU during scroll.
    var isActive: Bool = true

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.onAppear {
                            textWidth = textGeo.size.width
                            containerWidth = geo.size.width
                        }
                    }
                )
                .offset(x: offset)
        }
        .clipped()
        .onChange(of: text) { _, _ in offset = 0; textWidth = 0 }
        .onChange(of: isActive) { _, active in
            if !active { withAnimation(.easeInOut(duration: 0.2)) { offset = 0 } }
        }
        .task(id: isActive ? textWidth : -1) {
            guard isActive else { return }
            await runMarquee()
        }
    }

    @MainActor
    private func runMarquee() async {
        offset = 0
        let dist = textWidth - containerWidth
        guard dist > 8 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: Double(dist) / 40)) { offset = -dist }
            try? await Task.sleep(for: .seconds(Double(dist) / 40 + 0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) { offset = 0 }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

// MARK: - tvOS Group Pill
// Each pill owns its own @FocusState so it can apply a scale+glow effect
// instead of the system's default white focus ring.
#if os(tvOS)
private struct TVGroupPill: View {
    let group: String
    let isSelected: Bool
    let action: () -> Void
    var systemImage: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let img = systemImage {
                Image(systemName: img)
                    .font(.system(size: 18, weight: .medium))
            }
            Text(group)
                .font(.system(size: 22, weight: .medium))
        }
        .foregroundColor(isSelected ? .appBackground : (isFocused ? .white : .textSecondary))
        .padding(.horizontal, 26)
        .padding(.vertical, 13)
        .background(
            Capsule()
                .fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
        )
        .overlay(
            Capsule()
                .stroke(isFocused && !isSelected ? Color.accentPrimary : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .opacity(isFocused ? 1.0 : (isSelected ? 1.0 : 0.85))
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .focusable(interactions: .activate)
        .focused($isFocused)
        .onTapGesture { action() }
    }
}

// MARK: - tvOS No-Ring Button Style
#endif

// MARK: - Cached Channel Logo Image

/// In-memory logo cache — prevents AsyncImage from re-fetching on every scroll.
private final class LogoCache: @unchecked Sendable {
    static let shared = LogoCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 500 }
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ img: UIImage, for key: String) { cache.setObject(img, forKey: key as NSString) }
}

/// Drop-in replacement for AsyncImage that caches logos in memory.
private struct CachedLogoImage: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img).resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.12))
                        .frame(width: width, height: height)
                    NoPosterPlaceholder(compact: true)
                }
            }
        }
        .task(id: url?.absoluteString) {
            guard let url else { return }
            let key = url.absoluteString
            if let cached = LogoCache.shared.image(for: key) {
                uiImage = cached
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let img = UIImage(data: data) {
                    LogoCache.shared.store(img, for: key)
                    uiImage = img
                }
            } catch {}
        }
    }
}
