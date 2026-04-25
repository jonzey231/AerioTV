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
    #if os(iOS)
    /// Collapses the iPhone-only chrome (filter pills) when the user
    /// scrolls down in the channel list. Hysteresis (80 / 20) on the
    /// scroll-y trigger prevents jitter near the edges.
    @State private var isChromeCollapsed: Bool = false
    /// Surfaces NetworkMonitor.localServerUnreachable as a Live TV banner —
    /// the user is on a configured home SSID but the server's local URL
    /// failed a probe (most often due to a VPN blocking LAN traffic).
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    /// Experimental "compact chrome" layout flag, owned by Developer
    /// Settings. When on (iPhone only), the Manage Groups button moves
    /// to the nav-bar trailing edge and the filter/search bars become
    /// hideable via two companion toggles below. Default OFF so the
    /// main user base is unaffected.
    @AppStorage("ui.iphone.compactChrome") private var compactChromeiPhone = false
    /// Hide the group-pill row entirely. Only honored when compact chrome
    /// is ON — otherwise ignored so the classic layout stays untouched.
    @AppStorage("ui.iphone.hideFilterBar") private var hideFilterBarCompact = false
    /// Collapse the always-visible nav-bar search drawer into an
    /// on-demand pull-down. Only honored when compact chrome is ON.
    @AppStorage("ui.iphone.hideSearchBar") private var hideSearchBarCompact = false
    /// True only on actual iPhones AND when the Developer flag is on.
    /// iPad / Mac Catalyst always get the classic layout.
    private var isCompactChrome: Bool {
        compactChromeiPhone && UIDevice.current.userInterfaceIdiom == .phone
    }
    #endif

    /// Cross-platform accessor used by the shared body content. Always
    /// returns `false` on tvOS (compact chrome is iPhone-only) so the
    /// tvOS build still compiles without referencing iOS-only storage.
    private var compactChromeHidesFilterBar: Bool {
        #if os(iOS)
        return isCompactChrome && hideFilterBarCompact
        #else
        return false
        #endif
    }
    #if os(tvOS)
    @State private var showSearchField = false
    /// tvOS guide focus target. Normally `nil` so the focus engine
    /// handles D-pad navigation naturally; programmatically set to
    /// a channel id in response to `.forceGuideFocus` (posted when
    /// the single-stream player minimizes to the corner) so focus
    /// lands on an actual guide row instead of staying trapped in
    /// the disabled mini player. Cleared back to nil immediately
    /// after the claim so subsequent D-pad navigation isn't pinned.
    @FocusState private var focusedGuideRowID: String?

    /// Namespace for imperative focus reset. Used together with
    /// `resetFocus(in:)` and `.prefersDefaultFocus(...)` on the top
    /// channel row — when the mini-player minimizes and the
    /// `.forceGuideFocus` notification fires, calling
    /// `resetFocus(in: guideFocusNS)` forcibly moves focus back into
    /// the guide and lands it on the row marked as the default. The
    /// plain `@FocusState` write alone wasn't strong enough — tvOS's
    /// focus engine had already committed to the mini tile
    /// (spatial-search nearest focusable) by the time the write
    /// landed, and treated our claim as a rejected request.
    @Namespace private var guideFocusNS
    @Environment(\.resetFocus) private var resetFocus
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
                    // Compact-chrome mode: surface the Manage Groups button in
                    // the nav bar since the inline pill-bar copy is hidden.
                    // Badge mirrors the inline button's count so users keep
                    // visibility into how many groups are hidden.
                    if isCompactChrome {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showManageGroups = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                        .foregroundColor(.accentPrimary)
                                    if hiddenGroups.count > 0 {
                                        Text("\(hiddenGroups.count)")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.statusWarning)
                                            .clipShape(Capsule())
                                            .offset(x: 8, y: -6)
                                    }
                                }
                            }
                            .accessibilityLabel("Manage Groups")
                        }
                    }
                    #endif
                }
                #if os(iOS)
                // When compact chrome + "Hide Search" is on, drop to
                // `.automatic` so the search drawer only appears when the
                // user pulls down — reclaims the ~50 pt the always-visible
                // drawer otherwise eats on iPhone landscape. Classic layout
                // keeps `.always` so today's users see no change.
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(
                                displayMode: (isCompactChrome && hideSearchBarCompact) ? .automatic : .always
                            ),
                            prompt: "Search channels")
                #endif
                .onChange(of: searchText)       { _, _ in filterChannels() }
                .onChange(of: selectedGroup)    { _, _ in filterChannels() }
                .onChange(of: sortModeRaw)      { _, _ in filterChannels() }
                // Re-sort when favorites change so the Favorites-First mode
                // drops newly-unfavorited rows back into the number-sorted
                // section below without waiting for the user to switch
                // tabs or groups. `.count` is a cheap membership-change
                // signal: add and remove both bump it, while drag-reorder
                // inside the Favorites tab (which doesn't affect this
                // view's sort) leaves it unchanged.
                .onChange(of: favoritesStore.favoriteItems.count) { _, _ in
                    filterChannels()
                }
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
                        startPlayback(channel)
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
                    // tvOS always uses Guide view — list view is not offered.
                    showGuideView = true
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
                    // tvOS always uses Guide view.
                    if !showGuideView { showGuideView = true }
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

            VStack(spacing: 0) {
                #if os(iOS)
                // SSID-detected-but-LAN-unreachable banner. NetworkMonitor.shared
                // sets `localServerUnreachable` true when the user is on a
                // configured home SSID but a 3-second probe of the server's
                // localURL fails — usually because a VPN is blocking LAN.
                if networkMonitor.localServerUnreachable {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.statusWarning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SSID recognized but can't connect to LAN address")
                                .font(.labelSmall.weight(.semibold))
                                .foregroundColor(.textPrimary)
                            Text("You're on your home WiFi, but the server's local URL didn't respond. This is usually an active VPN blocking LAN traffic, a mistyped Local URL, or the server being off. Check Settings → Playlists → [server] → Edit.")
                                .font(.labelSmall)
                                .foregroundColor(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.statusWarning.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                #endif

                bodyContent
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
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
                // Compact-chrome honors the user's hide-filter preference even
                // in the iPad Guide layout (iPad itself is gated by the flag,
                // so this only activates on actual iPhones in landscape).
                if (channelStore.orderedGroups.count > 1 || !hiddenGroups.isEmpty)
                    && !compactChromeHidesFilterBar {
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
                        startPlayback(item)
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

    // MARK: - Channel List Content

    private var channelListContent: some View {
        VStack(spacing: 0) {
            if (channelStore.orderedGroups.count > 1 || !hiddenGroups.isEmpty)
                && !compactChromeHidesFilterBar {
                #if os(iOS)
                // iPhone collapses the filter pills when the user scrolls
                // down in the list to reclaim ~40% of the screen otherwise
                // taken by chrome. iPad always shows the pills.
                if !(UIDevice.current.userInterfaceIdiom == .phone && isChromeCollapsed) {
                    groupFilterBar
                        .padding(.vertical, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                #else
                groupFilterBar
                    .padding(.vertical, 10)
                    .focusSection()
                    .focusEffectDisabled()
                #endif
            }

            #if os(tvOS)
            // On tvOS, List draws a white highlight over any focused row —
            // ScrollView + LazyVStack gives us full visual control.
            //
            // Wrapped in `ScrollViewReader` so a Menu-button press on
            // the Live-TV tab (posted via `.guideScrollToTop` from
            // HomeView) can jump the list back to the first channel.
            // Matches Apple's TV / Music "Menu = back to top" pattern
            // for long lists.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        // Invisible top anchor so we always have a
                        // scroll target even if the filtered list is
                        // empty or still loading.
                        Color.clear
                            .frame(height: 0)
                            .id("guide.top")

                        ForEach(filteredChannels) { item in
                            ChannelRow(
                                item: item,
                                onTap: { startPlayback(item) },
                                fetchUpcoming: makeFetchUpcoming(for: item)
                            )
                            .padding(.horizontal, 24)
                            // Bind each row to `focusedGuideRowID`.
                            // Normally the focus engine drives the
                            // binding (D-pad moves focus among
                            // rows). Programmatically set in the
                            // `.forceGuideFocus` handler below to
                            // yank focus from a minimized mini
                            // player.
                            .focused($focusedGuideRowID, equals: item.id)
                            // Marks the top row as the default-focus
                            // target for the guide scope. When
                            // `resetFocus(in: guideFocusNS)` fires
                            // from the `.forceGuideFocus` handler
                            // below, tvOS moves focus to whichever
                            // row has this flag set — which is the
                            // top row by construction.
                            .prefersDefaultFocus(item.id == filteredChannels.first?.id, in: guideFocusNS)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color.appBackground)
                .focusSection()
                .focusScope(guideFocusNS)
                .onReceive(
                    NotificationCenter.default.publisher(for: .guideScrollToTop)
                ) { _ in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("guide.top", anchor: .top)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .forceGuideFocus)
                ) { _ in
                    // Reclaim focus from the minimized mini player
                    // via Apple's documented imperative focus-reset
                    // hook. `resetFocus(in:)` is the ONLY reliable
                    // way to move focus when tvOS's engine has
                    // already committed to another focusable view
                    // (the mini tile): a plain `@FocusState` write
                    // is treated as a request that the engine may
                    // reject. `resetFocus` forces a re-evaluation
                    // within the scope and lands on the row with
                    // `.prefersDefaultFocus(true, in: ...)` — i.e.
                    // the top channel row.
                    //
                    // The 400ms delay covers the 350ms minimize
                    // spring animation. Triggering during the
                    // animation lets tvOS ignore the reset because
                    // the mini tile's frame is still in flux; waiting
                    // until after the animation commits is what makes
                    // the reset stick.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        resetFocus(in: guideFocusNS)
                    }
                }
            }
            #else
            List {
                ForEach(filteredChannels) { item in
                    ChannelRow(
                        item: item,
                        onTap: { startPlayback(item) },
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
            // iPhone-only: collapse the chrome (filter pills) when the
            // list scrolls past 80pt; expand again near the top (< 20pt).
            // Hysteresis prevents jitter at the boundary. iPad keeps the
            // chrome visible — it has plenty of vertical space.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, y in
                guard UIDevice.current.userInterfaceIdiom == .phone else { return }
                if y > 80 && !isChromeCollapsed {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isChromeCollapsed = true
                    }
                } else if y < 20 && isChromeCollapsed {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isChromeCollapsed = false
                    }
                }
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

                // Compact-chrome mode hoists Manage Groups into the nav bar
                // (see the toolbar block above), so we drop it from the pill
                // row here to avoid a duplicate button. Classic layout
                // keeps the inline button exactly where it was.
                #if os(iOS)
                if !isCompactChrome {
                    ManageGroupsButton(
                        action: { showManageGroups = true },
                        hiddenCount: hiddenGroups.count
                    )
                }
                #else
                ManageGroupsButton(
                    action: { showManageGroups = true },
                    hiddenCount: hiddenGroups.count
                )
                #endif

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
            // Partition preserves the original order within each bucket
            // (channels arrive from ChannelStore in number order), so
            // favorites appear first in number order and non-favorites
            // follow in number order. The previous implementation used
            // `.sort` with a localizedCaseInsensitiveCompare tiebreaker,
            // which silently switched non-favorites to alphabetical even
            // though the user never asked for "By Name" — that was the
            // bug the user reported.
            let favs = result.filter { favoritesStore.isFavorite($0.id) }
            let nonFavs = result.filter { !favoritesStore.isFavorite($0.id) }
            result = favs + nonFavs
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
            // Circuit breaker: if the server is slow/down, three
            // consecutive 5s timeouts chew up 15 seconds of a uwsgi
            // worker AND delay everything queued behind us in the
            // serial loop. Bail early so we stop hammering a server
            // we've already proven unresponsive. Threshold of 4.5s
            // sits comfortably below `getUpcomingPrograms`'s 5s
            // timeout and well above any realistic success latency
            // (successes normally land in 100–500ms on a healthy
            // server). Makes this independent of GuideStore's own
            // breaker so either path alone is enough to protect
            // Dispatcharr.
            var consecutiveSlow = 0
            let slowThreshold: TimeInterval = 4.5
            let maxConsecutiveSlow = 3
            for (idx, item) in channels.prefix(20).enumerated() {
                guard !Task.isCancelled else { return }
                if consecutiveSlow >= maxConsecutiveSlow {
                    debugLog("📺 EPG prefetch: CIRCUIT BREAKER tripped — \(maxConsecutiveSlow) consecutive slow fetches, aborting after \(idx)/20 channels")
                    return
                }
                guard let fetch = makeFetchUpcoming(for: item) else { continue }
                let start = Date()
                _ = await fetch()
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= slowThreshold {
                    consecutiveSlow += 1
                } else {
                    consecutiveSlow = 0
                }
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

    // MARK: - Playback entry helper (Phase B)

    /// Unified entry point for channel taps / deep-links / EPG picks.
    /// Routes through the new `PlayerSession.begin(...)` API when the
    /// `"playback.unified"` feature flag is on; falls back to the
    /// legacy `NowPlayingManager.startPlaying(...)` path otherwise.
    ///
    /// Both paths get the same guard (`!streamURLs.isEmpty`) so the
    /// call sites can just be `startPlayback(item)`. The server
    /// lookup mirrors `playerHeaders()` so header semantics are
    /// identical across both paths.
    ///
    /// Phase D deletes the flag-gate and this helper keeps calling
    /// `begin(...)` directly.
    private func startPlayback(_ item: ChannelDisplayItem) {
        guard !item.streamURLs.isEmpty else { return }
        if PlaybackFeatureFlags.useUnifiedPlayback {
            let server = channelStore.activeServer
                ?? servers.first(where: { $0.isActive })
                ?? servers.first
            _ = PlayerSession.shared.begin(item: item, server: server)
        } else {
            nowPlaying.startPlaying(item, headers: playerHeaders())
        }
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
        startPlayback(channel)
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
                        .map {
                            // M3U EPG comes from XMLTV, which DOES
                            // have `<category>` tags. Passing it
                            // through keeps List view's expanded
                            // schedule tinted on M3U sources the
                            // same as on Dispatcharr sources.
                            EPGEntry(title: $0.title, description: $0.description,
                                     startTime: $0.startTime, endTime: $0.endTime,
                                     category: $0.category)
                        }
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
    /// Dispatcharr-only: the channel's server-side UUID string.
    /// Needed as an EPG-matching key because Dispatcharr's Dummy
    /// EPG feature (see `apps/epg/api_views.py` in the Dispatcharr
    /// repo — `EPGGridAPIView`) tags synthesized dummy program
    /// entries with `tvg_id = str(channel.uuid)`. Without this
    /// field, channels that rely on Dummy EPG (rather than an
    /// uploaded XMLTV source) appear blank in the guide even
    /// though Dispatcharr's own web UI shows them. `nil` for XC
    /// and M3U where there's no server-side UUID concept.
    var uuid: String? = nil
    /// Dispatcharr-only: the channel's numeric server-side ID
    /// (`DispatcharrChannel.id`). v1.6.8 (Codex A2): added so
    /// `RecordProgramSheet` can pass an explicit, type-safe int
    /// to `RecordingCoordinator.scheduleDispatcharrRecording`
    /// instead of doing `Int(channelID) ?? 0` against the string
    /// `id`. The previous approach worked by accident — Dispatcharr's
    /// `ChannelDisplayItem.id` happens to be `String(ch.id)` — but
    /// returned a silent `0` for any provider whose `id` is a UUID
    /// (M3U) or any future format change. `nil` for non-Dispatcharr
    /// providers; record-to-server is gated on this being non-nil.
    var dispatcharrChannelID: Int? = nil
    var currentProgram: String? = nil
    var currentProgramDescription: String? = nil
    var currentProgramStart: Date? = nil
    var currentProgramEnd: Date? = nil
    /// Raw XMLTV `<category>` (or Xtream `genre`) of the currently-airing
    /// program, if the EPG source provided one. Read by `CategoryColor.bucket(for:)`
    /// when the optional "Tint channel cards" toggle is on. Nil for sources that
    /// don't expose category data (Dispatcharr and Xtream Codes currently).
    var currentProgramCategory: String? = nil
}

// MARK: - EPG Entry (for upcoming schedule)
struct EPGEntry: Identifiable, Equatable {
    /// Stable id incorporating start AND end time. Including end time
    /// guards against malformed EPG feeds where two adjacent programs
    /// share the same title and start timestamp — without it, ForEach
    /// would treat them as the same row and SwiftUI's contextMenu /
    /// preview pair could bind to the wrong program (the long-pressed
    /// row showed one title but the context-menu preview showed
    /// another). See ChannelListView guidePanel for the consumer.
    var id: String {
        let s = startTime?.timeIntervalSinceReferenceDate ?? 0
        let e = endTime?.timeIntervalSinceReferenceDate ?? 0
        return "\(title)-\(s)-\(e)"
    }
    let title: String
    let description: String
    let startTime: Date?
    let endTime: Date?
    /// XMLTV `<category>` tag (or empty when the EPG source doesn't
    /// expose one — e.g., Dispatcharr's JSON API or Xtream Codes).
    /// Drives the per-program gradient tint on the List-view
    /// expanded-schedule rows, mirroring what the Guide view already
    /// shows via `GuideProgram.category`. Both views now read from
    /// `GuideStore.programs` (via `seedEPGCache`) so they stay in
    /// sync rather than each re-deriving category from scratch.
    let category: String

    init(title: String, description: String = "", startTime: Date?, endTime: Date?, category: String = "") {
        self.title = title
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
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
    /// Observe `GuideStore.programs` so the expanded-schedule
    /// panel can read category-enriched programmes DIRECTLY
    /// from the same dataset the Guide view already uses — no
    /// intermediate `EPGCache` / `fetchUpcoming` hop. Two prior
    /// rounds of debugging tried to fix the "expanded rows
    /// don't tint" bug by patching the cache layer; both times
    /// a different key-mismatch or timing race surfaced.
    /// Reading from GuideStore eliminates the whole class of
    /// problems: if the Guide view can tint it, so can we.
    @ObservedObject private var guideStore = GuideStore.shared
    /// Opt-in sub-toggle nested under Settings → Guide Display →
    /// "Color Programs by Category". When on AND the currently-airing
    /// program's category matches one of the four buckets, a thin
    /// colored stripe is drawn on the leading edge of the row.
    /// Default off so existing users don't see a surprise visual change.
    @AppStorage("tintChannelCards") private var tintChannelCards: Bool = false

    /// Per-view scale slider (#21) read by the iOS channel-row text
    /// and padding. tvOS rows keep their fixed Emby metrics since
    /// they're already tuned for 10-foot viewing. 0.85–1.25 matches
    /// the slider range in Settings → Appearance → Display Scale.
    #if !os(tvOS)
    @AppStorage("listScale") private var listScale: Double = 1.0
    /// Clamp to the slider range so a corrupted UserDefaults value
    /// (e.g., imported from an older build) can't blow up the row
    /// layout. The 1e-3 margin is cosmetic — avoids reading exactly
    /// 0.85 as "slightly below 0.85" when the floating-point step
    /// lands on a binary-exact value.
    private var listScaleClamped: CGFloat {
        CGFloat(max(0.85, min(1.25, listScale)))
    }
    #endif
    @State private var upcomingPrograms: [EPGEntry] = []
    @State private var isLoadingUpcoming = false
    @State private var reminderTarget: EPGEntry?
    @State private var showReminderDialog = false
    /// Unified sheet/cover driver for this channel row. Replaces the
    /// previous triple of `recordTarget: EPGEntry?` +
    /// `showRecordSheet: Bool` + `programInfoTarget:
    /// ProgramInfoTarget?` plus two `.sheet` / `.fullScreenCover`
    /// modifiers on the row body.
    ///
    /// Why: chaining multiple `.sheet(...)` modifiers on the same
    /// view causes SwiftUI to rebuild the hierarchy while the
    /// *other* sheet's binding is observed, which cascaded back
    /// into the contextMenu / confirmationDialog presentation and
    /// visibly flashed those on iPad when the user long-pressed a
    /// program row. One `.sheet(item:)` driven by an enum payload
    /// removes the cross-modifier invalidation path entirely.
    fileprivate enum ChannelRowSheet: Identifiable {
        case record(EPGEntry)
        case programInfo(ProgramInfoTarget)
        var id: String {
            switch self {
            case .record(let e):      return "record-\(e.id)"
            case .programInfo(let t): return "info-\(t.id)"
            }
        }
    }
    @State private var activeSheet: ChannelRowSheet? = nil
    /// Tracks which upcoming-program row currently owns the popover
    /// shown in response to a long-press. `EPGEntry.id` is
    /// deterministic (title + start + end) so the binding is stable
    /// across renders. Only one popover is visible at a time per
    /// channel card; setting this to a new id is what presents it.
    #if !os(tvOS)
    @State private var activePopoverEntryID: String?
    #endif
    #if os(tvOS)
    /// tvOS uses onLongPressGesture + confirmationDialog instead of
    /// .contextMenu on upcoming-program rows (.contextMenu flashes the
    /// row highlight on tvOS each time SwiftUI rebuilds the UIMenu).
    @State private var ctxDialogEntry: EPGEntry?
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

    @State private var showCardMenu = false

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
        // When the XMLTV parse lands and EPGCache is re-seeded
        // with category data, re-fetch our upcoming list so the
        // per-program gradient tint picks up the new data. Only
        // fires work when this card is actually expanded — a
        // collapsed card has no rows to re-tint and would just
        // be burning a fetch. Posted by
        // `ChannelStore.primeXMLTVFromURL` after `seedEPGCache`.
        .onReceive(NotificationCenter.default.publisher(for: .epgCategoriesDidUpdate)) { _ in
            guard isExpanded, let fetch = fetchUpcoming else { return }
            Task {
                upcomingPrograms = await fetch()
            }
        }
        // Clip to the same rounded shape as the background so
        // expanded rows that now extend full-width (no horizontal
        // outer padding, fixes the category-tint bleed on the
        // sides) don't poke past the card's rounded bottom corners.
        // tvOS does the same so both platforms render identically.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                // Category tint — a linear gradient that fades from ~30%
                // opacity on the leading edge down to 0 by the card's
                // midline. This replaces the earlier 5 pt stripe, which
                // users found visually cramped ("just a colored bar on
                // the side" — #22 feedback). The fade keeps the right-
                // hand 60% of the card completely uncolored, so the
                // channel name, program title, progress bar, and the
                // chevron all stay legible against their original
                // background.
                //
                // Opt-in via Settings → Guide Display → "Tint Channel
                // Cards". Stays transparent when either the master
                // toggle or the channel-card variant is off, or when
                // the current program's category doesn't match a bucket.
                .overlay {
                    if tintChannelCards,
                       CategoryColor.isEnabled,
                       let raw = item.currentProgramCategory,
                       let bucket = CategoryColor.bucket(for: raw) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: bucket.baseColor.opacity(0.30), location: 0.0),
                                        .init(color: bucket.baseColor.opacity(0.18), location: 0.22),
                                        .init(color: bucket.baseColor.opacity(0.06), location: 0.45),
                                        .init(color: .clear,                          location: 0.65),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .accessibilityHidden(true)
                    }
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
        // tvOS: single .fullScreenCover(item:) — see `ChannelRowSheet`
        // doc for why we consolidated away from the dual-modifier
        // setup.
        .fullScreenCover(item: $activeSheet) { sheet in
            switch sheet {
            case .record(let entry):
                RecordProgramSheet(
                    programTitle: entry.title,
                    programDescription: entry.description,
                    channelID: item.id,
                    channelName: item.name,
                    scheduledStart: entry.startTime ?? Date(),
                    scheduledEnd: entry.endTime ?? Date().addingTimeInterval(3600),
                    isLive: (entry.startTime ?? Date()) <= Date(),
                    dispatcharrChannelID: item.dispatcharrChannelID,
                    streamURL: item.streamURL
                )
            case .programInfo(let target):
                ProgramInfoView(target: target)
            }
        }
        #else
        // iOS: attached at the outer body so this works whether the
        // card is collapsed (long-press dialog trigger) or expanded
        // (tap on an upcoming-schedule row trigger). Single
        // `.sheet(item:)` to keep the contextMenu / popover from
        // flickering during presentation (see `ChannelRowSheet` doc).
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .record(let entry):
                RecordProgramSheet(
                    programTitle: entry.title,
                    programDescription: entry.description,
                    channelID: item.id,
                    channelName: item.name,
                    scheduledStart: entry.startTime ?? Date(),
                    scheduledEnd: entry.endTime ?? Date().addingTimeInterval(3600),
                    isLive: (entry.startTime ?? Date()) <= Date(),
                    dispatcharrChannelID: item.dispatcharrChannelID,
                    streamURL: item.streamURL
                )
            case .programInfo(let target):
                ProgramInfoView(target: target)
            }
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
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
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
                // Skip the network fetch when GuideStore already has
                // programmes for this channel — the expanded panel
                // now prefers GuideStore, so the fetch would be
                // redundant work. Still fires for Xtream + cold-
                // launch-before-XMLTV cases (GuideStore empty).
                if isExpanded, futurePrograms.isEmpty, fetchUpcoming != nil {
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
    private var iOSRow: some View {
        // `s` is the Live TV List scale slider (Appearance → Display
        // Scale → Live TV List). Sizes multiply by `s` so dragging
        // the slider resizes the row live. `isWide` still drives the
        // iPad vs. iPhone branch before scale is applied.
        let s = listScaleClamped
        return HStack(spacing: (isWide ? 14 : 10) * s) {
            Text(item.number)
                .font(.system(size: (isWide ? 17 : 13) * s, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .foregroundColor(.textTertiary)
                .frame(width: (isWide ? 36 : 26) * s, alignment: .trailing)

            CachedLogoImage(
                url: item.logoURL,
                width: (isWide ? 50 : 38) * s,
                height: (isWide ? 34 : 26) * s
            )

            VStack(alignment: .leading, spacing: (isWide ? 4 : 2) * s) {
                Text(item.name)
                    .font(.system(size: (isWide ? 17 : 15) * s, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)

                if let program = item.currentProgram, !program.isEmpty {
                    HStack(spacing: 8) {
                        MarqueeText(text: program,
                                    font: .system(size: (isWide ? 15 : 11) * s),
                                    color: .accentPrimary.opacity(0.85),
                                    isActive: false)  // Static during scroll — saves GPU
                            .frame(height: (isWide ? 20 : 16) * s)
                        if let end = item.currentProgramEnd {
                            nowPlayingTimeRemaining(end: end)
                        }
                    }
                    if let desc = item.currentProgramDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: (isWide ? 12 : 10) * s))
                            .foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(item.group)
                        .font(.system(size: (isWide ? 15 : 11) * s))
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
                    // Skip the network fetch when GuideStore already has
                // programmes for this channel — the expanded panel
                // now prefers GuideStore, so the fetch would be
                // redundant work. Still fires for Xtream + cold-
                // launch-before-XMLTV cases (GuideStore empty).
                if isExpanded, futurePrograms.isEmpty, fetchUpcoming != nil {
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
        .padding(.vertical, (isWide ? 18 : 13) * s)
        .padding(.horizontal, (isWide ? 18 : 14) * s)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.5) {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            showCardMenu = true
        }
        .confirmationDialog(
            item.currentProgram ?? item.name,
            isPresented: $showCardMenu,
            titleVisibility: .visible
        ) {
            let isFav = favoritesStore.isFavorite(item.id)
            Button(isFav ? "Remove from Favorites" : "Add to Favorites") {
                favoritesStore.toggle(item)
            }

            // Program Info — surface the current program's full
            // description + category metadata in a modal. Only shown
            // when we actually have a current program to describe;
            // otherwise this button would be misleading (it would
            // open an info sheet with a blank title).
            if let program = item.currentProgram,
               let start = item.currentProgramStart,
               let end = item.currentProgramEnd {
                Button("Program Info") {
                    activeSheet = .programInfo(
                        ProgramInfoTarget(
                            channelName: item.name,
                            title: program,
                            start: start,
                            end: end,
                            description: item.currentProgramDescription ?? "",
                            category: item.currentProgramCategory ?? ""
                        )
                    )
                }
            }

            // Record the currently-airing program. v1.6.8 (B1 Phase 1):
            // dropped the `currentProgram != nil && end > now` gate.
            // For Dispatcharr playlists, `ChannelDisplayItem.currentProgram`
            // is never populated at load time (the load path leaves
            // EPG enrichment to the Guide view's per-cell prefetch),
            // so the gate hid the Record action permanently for users
            // who hadn't visited the Guide first. Now we always offer
            // "Record" — when EPG is missing we fall back to a generic
            // title + a 60-minute default duration that the user can
            // override in `RecordProgramSheet`.
            if item.streamURL != nil {
                let hasEPG = (item.currentProgram?.isEmpty == false)
                Button(hasEPG ? "Record from Now" : "Record") {
                    let now = Date()
                    let title = item.currentProgram ?? "\(item.name) live recording"
                    let start = item.currentProgramStart ?? now
                    let end = (item.currentProgramEnd.flatMap { $0 > now ? $0 : nil })
                        ?? now.addingTimeInterval(3600)
                    activeSheet = .record(
                        EPGEntry(
                            title: title,
                            description: item.currentProgramDescription ?? "",
                            startTime: start,
                            endTime: end
                        )
                    )
                }
            }
        }
    }
    #endif

    // MARK: - Guide Panel (shared iOS + tvOS)

    /// Upcoming programs filtered to exclude the currently-airing
    /// program (already shown in the channel card header).
    ///
    /// **Primary source: `GuideStore.programs[item.id]`**. Same
    /// dataset the Guide view reads from. XMLTV populates it on
    /// all platforms via `ChannelStore.primeXMLTVFromURL`, so
    /// categories are guaranteed present on Dispatcharr + M3U
    /// when the feed has them. No cache-layer round-trip.
    ///
    /// **Fallback: `upcomingPrograms`** from the legacy
    /// `fetchUpcoming` closure. Primarily covers Xtream Codes,
    /// which does per-channel EPG fetches that never populate
    /// GuideStore. Also catches the transient window on a first
    /// cold launch where a channel exists but XMLTV hasn't
    /// parsed yet — in that case we still show SOMETHING rather
    /// than an empty panel.
    private var futurePrograms: [EPGEntry] {
        let now = Date()
        let fromGuideStore = guideStore.programs[item.id] ?? []
        if !fromGuideStore.isEmpty {
            return fromGuideStore
                .filter { $0.end > now && $0.start > now }
                .sorted { $0.start < $1.start }
                .map {
                    EPGEntry(title: $0.title, description: $0.description,
                             startTime: $0.start, endTime: $0.end,
                             category: $0.category)
                }
        }
        return upcomingPrograms.filter { entry in
            guard let end = entry.endTime else { return true }
            return end > now && (entry.startTime ?? now) > now
        }
    }

    #if !os(tvOS)
    /// Small summary + action popover shown when the user long-presses
    /// an upcoming-program row. Replaces the SwiftUI `.contextMenu` that
    /// kept docking at the screen bottom on iPhone (#23 feedback).
    ///
    /// Structured as a tiny VStack — header (title + time range) then
    /// one or two actions (Set / Cancel Reminder, Record). `.buttonStyle(.plain)`
    /// + explicit padding match the visual weight of an iOS context
    /// menu without relying on the system-provided one. Dismissed by
    /// tapping any action (which sets `activePopoverEntryID = nil`)
    /// or by tapping outside the popover (SwiftUI default).
    @ViewBuilder
    private func programActionPopover(for entry: EPGEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — program title + time range. Mirrors the old
            // context-menu preview's data without the extra padding
            // that made it look like a second card when docked at
            // the bottom.
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                if let start = entry.startTime {
                    HStack(spacing: 4) {
                        Text(start, style: .time)
                        if let end = entry.endTime {
                            Text("–")
                            Text(end, style: .time)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            // Actions — info + reminder + record. Program Info is
            // always available (unlike reminder/record which gate on
            // future/live state) so it's the first button; users can
            // inspect a past-aired program's metadata too.
            VStack(spacing: 0) {
                popoverActionButton(
                    title: "Program Info",
                    systemImage: "info.circle",
                    isDestructive: false
                ) {
                    let start = entry.startTime ?? Date()
                    let end = entry.endTime ?? start.addingTimeInterval(3600)
                    activePopoverEntryID = nil
                    // Slight delay so the popover dismiss animation
                    // finishes before the sheet presents — iOS
                    // sometimes swallows the sheet without this,
                    // matching the pattern used for Record below.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        activeSheet = .programInfo(
                            ProgramInfoTarget(
                                channelName: item.name,
                                title: entry.title,
                                start: start,
                                end: end,
                                description: entry.description,
                                category: entry.category
                            )
                        )
                    }
                }
                if let start = entry.startTime, start > Date() {
                    let key = ReminderManager.programKey(
                        channelName: item.name,
                        title: entry.title,
                        start: start
                    )
                    if ReminderManager.shared.hasReminder(forKey: key) {
                        popoverActionButton(
                            title: "Cancel Reminder",
                            systemImage: "bell.slash",
                            isDestructive: true
                        ) {
                            ReminderManager.shared.cancelReminder(forKey: key)
                            activePopoverEntryID = nil
                        }
                    } else {
                        popoverActionButton(
                            title: "Set Reminder",
                            systemImage: "bell.badge",
                            isDestructive: false
                        ) {
                            ReminderManager.shared.scheduleReminder(
                                programTitle: entry.title,
                                channelName: item.name,
                                startTime: start
                            )
                            activePopoverEntryID = nil
                        }
                    }
                }
                if let end = entry.endTime, end > Date() {
                    popoverActionButton(
                        title: "Record",
                        systemImage: "record.circle",
                        isDestructive: false
                    ) {
                        activePopoverEntryID = nil
                        // Slight delay so the popover dismiss animation
                        // finishes before the sheet presents — without
                        // this iOS sometimes swallows the sheet.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            activeSheet = .record(entry)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
    }

    /// One row inside `programActionPopover`. Full-width tap target
    /// with icon + label, matching the visual rhythm of a system
    /// context-menu row (system uses UITableView cells internally;
    /// this is the SwiftUI approximation).
    private func popoverActionButton(
        title: String,
        systemImage: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                Spacer()
            }
            .foregroundColor(isDestructive ? .statusLive : .accentPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

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
                #if os(iOS)
                // iOS: No inner ScrollView — nesting vertical scrolls traps
                // the gesture inside the expanded card and prevents the
                // outer channel list from scrolling. Let the outer list
                // handle all vertical scrolling.
                VStack(spacing: 0) {
                    ForEach(futurePrograms) { entry in
                        // Rebind to a local constant so SwiftUI's ForEach
                        // diffing can't swap the captured reference between
                        // when the user starts a long-press and when the
                        // contextMenu/preview closures are evaluated.
                        // Without this, the preview occasionally rendered a
                        // different program than the one the user pressed
                        // (e.g. user long-pressed "Moeder Natuur 07:10" but
                        // the dialog previewed "Timmy tijd 06:05–06:10").
                        let rowEntry = entry
                        // Long-press + popover replaces `.contextMenu` here
                        // because SwiftUI's `.contextMenu(menuItems:preview:)`
                        // on iPhone has a documented "docks the preview +
                        // menu at the screen bottom" failure mode when the
                        // source view is inside a nested scroll container
                        // (our expanded guidePanel inside a ChannelRow
                        // inside a List). Research turned up no SwiftUI
                        // API that controls the context-menu preview
                        // position — Apple's own apps use UIKit
                        // `UIContextMenuInteraction` directly. `.popover`
                        // with `.presentationCompactAdaptation(.popover)`
                        // gives us the native popover on iPhone (iOS 16.4+)
                        // and always anchors to the attached view via
                        // `attachmentAnchor: .rect(.bounds)` — which is
                        // exactly "where the user long-pressed" per #23
                        // feedback.
                        epgEntryRow(entry: rowEntry, isLast: rowEntry.id == futurePrograms.last?.id)
                            // No horizontal outer padding — rows now
                            // extend to the card's inner edge, so the
                            // parent card's category gradient can't
                            // "bleed" through the gaps between rows
                            // (#22 feedback: "I can see my category
                            // color between future programs at the
                            // edges which looks unfinished"). Rows
                            // still get 2 pt vertical breathing room
                            // so they read as individual cards rather
                            // than one run-on block.
                            .padding(.vertical, 2)
                            .background(
                                // ZStack layering — the previous
                                // version used two chained `.background`
                                // modifiers to stack solid-fill + gradient.
                                // That was a SwiftUI ordering bug: stacked
                                // `.background` modifiers each go further
                                // back than the previous, so the "solid
                                // fill to block parent gradient bleed"
                                // modifier ended up IN FRONT of the per-
                                // program gradient — hiding it completely.
                                // Three rounds of debugging chased the
                                // data layer for something that was a
                                // render ordering bug. ZStack has
                                // unambiguous paint order: first child at
                                // the back, last child at the front.
                                ZStack {
                                    Rectangle()
                                        .fill(Color.cardBackground)
                                    if tintChannelCards,
                                       CategoryColor.isEnabled,
                                       !rowEntry.category.isEmpty,
                                       let bucket = CategoryColor.bucket(for: rowEntry.category) {
                                        LinearGradient(
                                            stops: [
                                                .init(color: bucket.baseColor.opacity(0.30), location: 0.0),
                                                .init(color: bucket.baseColor.opacity(0.18), location: 0.22),
                                                .init(color: bucket.baseColor.opacity(0.06), location: 0.45),
                                                .init(color: .clear,                          location: 0.65),
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    }
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { /* no-op; prevents accidental parent-scroll triggers */ }
                            .onLongPressGesture(minimumDuration: 0.4) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                activePopoverEntryID = rowEntry.id
                            }
                            .popover(
                                isPresented: Binding(
                                    get: { activePopoverEntryID == rowEntry.id },
                                    set: { if !$0 { activePopoverEntryID = nil } }
                                ),
                                attachmentAnchor: .rect(.bounds)
                            ) {
                                programActionPopover(for: rowEntry)
                                    .presentationCompactAdaptation(.popover)
                            }
                    }
                }
                .padding(.bottom, 4)
                #else
                // tvOS: keep the nested ScrollView (needed for focus
                // mechanics) and chain `.confirmationDialog` directly
                // onto it. Previously the `.confirmationDialog` was
                // inside a separate `#if os(tvOS) ... #endif` block
                // AFTER the iOS/tvOS `#if/#else/#endif` branching —
                // the `#if` boundary broke the modifier chain (a
                // free-floating `.modifier(...)` isn't a valid
                // top-level ViewBuilder expression), so the tvOS
                // build errored with "'()' cannot conform to 'View'"
                // on line ~1287. Attaching the dialog to the tvOS
                // branch keeps the chain continuous.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(futurePrograms) { entry in
                            // UIKit-backed overlay because SwiftUI's tvOS
                            // long-press fires on release, not at threshold
                            // (see Shared/TVPressGesture.swift).
                            epgEntryRow(entry: entry, isLast: entry.id == futurePrograms.last?.id)
                                .overlay(
                                    TVPressOverlay(
                                        minimumPressDuration: 0.35,
                                        onLongPress: { ctxDialogEntry = entry }
                                    )
                                )
                        }
                    }
                }
                .frame(maxHeight: upcomingScrollMaxHeight)
                .focusSection()
                .padding(.bottom, 4)
                .confirmationDialog(
                    ctxDialogEntry?.title ?? "",
                    isPresented: Binding(
                        get: { ctxDialogEntry != nil },
                        set: { if !$0 { ctxDialogEntry = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let entry = ctxDialogEntry {
                        Button("Program Info") {
                            let start = entry.startTime ?? Date()
                            let end = entry.endTime ?? start.addingTimeInterval(3600)
                            activeSheet = .programInfo(
                                ProgramInfoTarget(
                                    channelName: item.name,
                                    title: entry.title,
                                    start: start,
                                    end: end,
                                    description: entry.description,
                                    category: entry.category
                                )
                            )
                        }
                        if let end = entry.endTime, end > Date() {
                            let isLive = (entry.startTime ?? Date()) <= Date()
                            Button(isLive ? "Record from Now" : "Record") {
                                activeSheet = .record(entry)
                            }
                        }
                        if let start = entry.startTime, start > Date() {
                            let key = ReminderManager.programKey(
                                channelName: item.name,
                                title: entry.title,
                                start: start
                            )
                            if ReminderManager.shared.hasReminder(forKey: key) {
                                Button("Cancel Reminder", role: .destructive) {
                                    ReminderManager.shared.cancelReminder(forKey: key)
                                }
                            } else {
                                Button("Set Reminder") {
                                    ReminderManager.shared.scheduleReminder(
                                        programTitle: entry.title,
                                        channelName: item.name,
                                        startTime: start
                                    )
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
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
                                startPlayback(item)
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            #if os(iOS)
                            .listRowSeparator(.hidden)
                            // Remove from within the Favorites tab itself —
                            // swipe-left reveals a red Remove action. Users
                            // previously had to hunt for the channel in Live
                            // TV list view to un-star it.
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    favoritesStore.toggle(item)
                                } label: {
                                    Label("Remove", systemImage: "star.slash")
                                }
                            }
                            // Mirrors the swipe action for discoverability —
                            // iPhone users often long-press before swiping.
                            .contextMenu {
                                Button(role: .destructive) {
                                    favoritesStore.toggle(item)
                                } label: {
                                    Label("Remove from Favorites", systemImage: "star.slash")
                                }
                            }
                            #endif
                        }
                        // tvOS Siri Remote can't drag-reorder, so the .onMove
                        // hook is iOS-only. The Edit-mode toolbar button below
                        // is also gated to iOS.
                        #if os(iOS)
                        .onMove { source, destination in
                            favoritesStore.move(fromOffsets: source, toOffset: destination)
                        }
                        #endif
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
            .toolbar {
                // EditButton flips the List into Edit mode so the drag
                // handles appear. Hidden when there are no favorites.
                if !favoritesStore.favoriteItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
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

    /// Same `startPlayback(_:)` helper as on `ChannelListView` — see
    /// its doc comment for rationale. Duplicated here because
    /// `FavoritesView` is a separate struct with its own
    /// `playerHeaders()` / `nowPlaying` / `channelStore` environment
    /// objects; a shared extension would require relocating these
    /// properties into a protocol.
    private func startPlayback(_ item: ChannelDisplayItem) {
        guard !item.streamURLs.isEmpty else { return }
        if PlaybackFeatureFlags.useUnifiedPlayback {
            let server = channelStore.activeServer
                ?? servers.first(where: { $0.isActive })
                ?? servers.first
            _ = PlayerSession.shared.begin(item: item, server: server)
        } else {
            nowPlaying.startPlaying(item, headers: playerHeaders())
        }
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
/// tvOS group filter pill. Uses Button + ButtonStyle (not bare
/// .focusable + .onTapGesture) to avoid the `_UIReplicantView`
/// warning UIKit prints when a focus replicant is inserted into
/// SwiftUI's UIHostingController.view.
private struct TVGroupPill: View {
    let group: String
    let isSelected: Bool
    let action: () -> Void
    var systemImage: String? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let img = systemImage {
                    Image(systemName: img)
                        .font(.system(size: 18, weight: .medium))
                }
                Text(group)
                    .font(.system(size: 22, weight: .medium))
            }
        }
        .buttonStyle(TVGroupPillButtonStyle(isSelected: isSelected))
    }
}

private struct TVGroupPillButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .foregroundColor(isSelected ? .appBackground : (focused ? .white : .textSecondary))
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
            )
            .overlay(
                Capsule()
                    .stroke(focused && !isSelected ? Color.accentPrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .opacity(focused ? 1.0 : (isSelected ? 1.0 : 0.85))
            .animation(.easeInOut(duration: 0.15), value: focused)
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
