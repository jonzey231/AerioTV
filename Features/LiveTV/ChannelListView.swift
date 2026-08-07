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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    // #45: collection filter pills live in the group-pill row; observe the
    // store so the row updates when collections are created / deleted.
    @ObservedObject private var collectionsStore = ChannelCollectionsStore.shared
    // #45: collection whose pill is being managed (long-press → move / delete).
    // Drives the tvOS manage confirmationDialog; nil = none.
    @State private var managePillCollection: ChannelCollection?

    @Query private var servers: [ServerConnection]

    @State private var filteredChannels: [ChannelDisplayItem] = []
    @State private var searchText: String = ""
    @State private var selectedGroup: String = "All"
    @State private var prefetchTask: Task<Void, Never>? = nil
    @State private var hiddenGroups: Set<String> = []
    @State private var showManageGroups = false
    // "" = Automatic (form-factor default: List on iPhone, Guide on
    // iPad and Apple TV); "list" / "guide" are explicit overrides set
    // ONLY by Settings → App Behaviors → Default Live TV View. The
    // in-screen List / Guide toggle is session-only (showGuideView) and
    // never writes this key, so an explicit choice on one device no
    // longer clobbers another form factor's default.
    @AppStorage("defaultLiveTVView") private var defaultLiveTVView = ""
    @AppStorage("channelSortMode") private var sortModeRaw = "number"
    @State private var showGuideView = false
    /// True once the user flips the in-screen List / Guide toggle this
    /// session. Width-based re-seeds (fold / unfold, Split View resize,
    /// Plus / Max rotation, servers arriving) skip while this is set so a
    /// manual choice is not stomped. Reset when the Settings default changes.
    @State private var userDidToggleView = false
    #if os(iOS)
    /// Collapses the iPhone-only chrome (filter pills) when the user
    /// scrolls down in the channel list. Hysteresis (80 / 20) on the
    /// scroll-y trigger prevents jitter near the edges.
    @State private var isChromeCollapsed: Bool = false
    #if os(iOS)
    // Tab bar scroll-away (2026-07-12): its own flag, separate from
    // isChromeCollapsed. The pills stay position-based (only shown near
    // the top, like Android's chip row); the BAR is direction-based via
    // TabBarScrollTracker so any upward scroll brings it back mid-list.
    @State private var isTabBarScrolledAway: Bool = false
    @State private var tabBarTracker = TabBarScrollTracker()
    #endif
    /// GH #55 interactive group swipe: live horizontal offset the list
    /// renders at while a group drag is in flight, and the per-gesture
    /// dominance latch (nil until the first onChanged decides).
    @State private var groupDragOffset: CGFloat = 0
    @State private var groupDragIsHorizontal: Bool? = nil
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
    /// v1.6.13.x: Drives whether the iPad nav-bar search drawer is
    /// shown. Default `false` (hidden) — a magnifier toolbar button
    /// reveals it on demand. iPhone keeps the always-visible classic
    /// drawer and ignores this flag (its `.searchable` modifier
    /// doesn't bind to it). Reclaims ~50pt of vertical space, which
    /// matters now that the corner mini-player on iPad pushes the
    /// channel-group filter row down.
    @State private var iPadSearchPresented: Bool = false
    /// True only on actual iPhones AND when the Developer flag is on.
    /// iPad / Mac Catalyst always get the classic layout.
    private var isCompactChrome: Bool {
        compactChromeiPhone && UIDevice.current.userInterfaceIdiom == .phone
    }
    #endif

    /// v1.6.13.x: Captured absolute (`.global`-coordinate-space) top
    /// edge of the chip-row container, used by
    /// `miniPlayerTopInset(naturalTopAbsolute:)` to position the
    /// chip row dynamically below the corner mini regardless of
    /// device chrome (iPad Mini vs iPad Pro vs Mac Catalyst all
    /// expose different status-bar / nav-bar / TabView heights).
    ///
    /// We use `proxy.frame(in: .global).minY` rather than
    /// `safeAreaInsets.top` because a view inside a NavigationStack
    /// content area sees `safeAreaInsets.top == 0` (the chrome was
    /// already consumed by the nav bar / tab bar above it) — that
    /// returns the wrong value and the padding push overshoots by
    /// the chrome height. The frame's absolute Y is the true
    /// position we need to compare against the mini-player's
    /// absolute bottom edge.
    ///
    /// Populated via a `GeometryReader`-backed `.background` +
    /// `PreferenceKey` so the read doesn't disturb layout. Lives
    /// OUTSIDE the iOS-only `#if` because the tvOS Guide branch
    /// also references it for the same dynamic-push behavior.
    @State private var capturedNaturalTop: CGFloat = 0

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

    /// v1.6.13: When the corner mini-player is active, the channel-
    /// group filter row otherwise sits behind the mini's top-right
    /// corner and gets visually clipped. Push the filter row (and
    /// everything below it in the VStack) down so the pills are
    /// fully reachable.
    ///
    /// **Dynamic geometry (v1.6.13.x):** The mini player is
    /// positioned inside HomeView's outer GeometryReader which
    /// `.ignoresSafeArea()`, so its bottom edge in absolute (screen)
    /// coords is a fixed `(top-padding + height)` regardless of any
    /// chrome above (status bar, top-tab bar, nav bar). The chip
    /// row's natural top in screen coords, however, IS that chrome
    /// height — and varies by device (iPad Mini, iPad Pro, Mac
    /// Catalyst, etc). We read the chip row's natural top via a
    /// `GeometryReader` reading `proxy.frame(in: .global).minY` and
    /// compute push as `(mini_bottom_abs + gap) - natural_top_abs`,
    /// so the chip row always lands ~12pt below the mini regardless
    /// of device size.
    ///
    /// Returns 0 on iPhone (uses bottom MiniPlayerBar instead) or
    /// when no measurement has been published yet — both of those
    /// cases mean "no push, leave chip row at its natural top".
    ///
    /// v1.6.13.x: now driven by the ACTUAL mini-player bottom edge
    /// captured in HomeView's `iOSMultiviewWrapper` /
    /// `iOSLegacyPlayerWrapper` and republished via
    /// `NowPlayingManager.miniPlayerBottomAbs`. Earlier attempts
    /// computed mini bottom from constants (`24 + 225`) and the
    /// math was off on iPad iOS 18 — the TabView's top tab bar
    /// shifts the mini's effective frame down by an unknown
    /// amount that `.ignoresSafeArea()` doesn't penetrate. Using
    /// the geometry-observer reading guarantees the chip row
    /// lands exactly `gap` points below whatever the rendered
    /// mini's bottom edge actually is, on any device + size class.
    private func miniPlayerTopInset(naturalTopAbsolute: CGFloat) -> CGFloat {
        guard nowPlaying.isActive, nowPlaying.isMinimized else { return 0 }
        guard naturalTopAbsolute > 0 else { return 0 }
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return 0 }
        #endif
        let miniBottomAbs = nowPlaying.miniPlayerBottomAbs
        guard miniBottomAbs > 0 else { return 0 }  // not measured yet
        let gap: CGFloat = 12
        return max(0, miniBottomAbs + gap - naturalTopAbsolute)
    }

    #if os(iOS)
    /// Resolves the width-adaptive List / Guide default for the current
    /// horizontal size class. Single source of truth so every dispatch site
    /// (onAppear, servers-arrived, and fold / unfold) agrees.
    ///
    /// Compact (iPhone portrait, folded foldable): default List; only an
    /// explicit "guide" opts in. Regular (iPad, unfolded foldable, Plus / Max
    /// landscape): default Guide; only an explicit "list" opts out. A nil size
    /// class is treated as regular. Guide always needs EPG data to render, so a
    /// server without EPG stays on List regardless of the preference.
    private func resolvedGuideDefault(hasEPG: Bool) -> Bool {
        guard hasEPG else { return false }
        if sizeClass == .compact { return defaultLiveTVView == "guide" }
        return defaultLiveTVView != "list"
    }
    #endif

    // #42 Part 1: true while a guide Left is held past threshold; pins focus on
    // the "All" pill so the still-held press cannot overshoot the leading
    // controls. Unconditional (ChannelListView member) because the shared
    // group-filter-bar reads it to gate collection-pill focus; only the tvOS
    // Left-hold detector sets it true.
    @State private var leftHoldPinningAll = false

    // Docked group sidebar (Remote Control "Group Selection: Sidebar Menu",
    // default off). Declared UNCONDITIONALLY (the guide branch is shared with
    // the iPad guide); the tvOS-only behavior is gated inside the members below.
    @State private var guideSidebarOpen = false
    @State private var guideSidebarReturnProgramID: String?
    /// #196 sidebar preview: the group active when the sidebar OPENED, so
    /// Back can revert a live preview. Nil while the sidebar is closed.
    @State private var guideSidebarOriginalGroup: String?
    /// 90ms preview debounce (Android parity) so D-pad travel through the
    /// rail doesn't re-filter the grid on every row.
    @State private var guideSidebarPreviewTask: Task<Void, Never>?
    @ObservedObject private var remoteStore = RemoteControlStore.shared

    /// Sidebar-mode active (tvOS only): hides the pills row + arms short-Left
    /// on the now-airing column. Mutually exclusive with the group pills.
    private var guideSidebarSelectorActive: Bool {
        #if os(tvOS)
        return remoteStore.useGroupSidebar
        #else
        return false
        #endif
    }

    /// Close the docked group sidebar and restore focus to the guide grid. On
    /// tvOS, `.guideGroupSidebarDismissed` runs EPGGuideView's retry-assert
    /// focus loop so Right/Back land back on the origin cell (rebind:false) or
    /// the newly-filtered now-cell (rebind:true = group changed).
    private func closeGuideSidebar(rebind: Bool) {
        withAnimation(.easeOut(duration: 0.28)) { guideSidebarOpen = false }
        #if os(tvOS)
        NotificationCenter.default.post(
            name: .guideGroupSidebarDismissed,
            object: nil,
            userInfo: ["rebind": rebind, "returnID": guideSidebarReturnProgramID as Any]
        )
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
    // #42 Part 1: focus target for the group-filter pills (the "All" pill is the
    // jump target for a guide long-press Left).
    @FocusState private var groupPillFocused: String?
    // #42 Part 1: auto-clears the pin if the Left release event is missed.
    // (`leftHoldPinningAll` itself is declared unconditionally above — shared
    // group-filter-bar code reads it to gate collection-pill focus.)
    @State private var leftHoldSafetyTask: Task<Void, Never>?

    /// Explicit row that the next `resetFocus(in: guideFocusNS)` should
    /// land on, driving `.prefersDefaultFocus`. Set by the Menu/Back
    /// handlers right before they reset focus:
    ///   - `.guideScrollToTop` (Menu on the guide) sets it to the FIRST
    ///     channel, so Menu actually moves focus to the top row, not just
    ///     scrolls the list (which tvOS would snap back to the focused row).
    ///   - `.forceGuideFocus` (return from the player) sets it to the
    ///     channel that was playing, so focus lands where the user left off.
    /// Nil falls through to the playing/last-played/first heuristic.
    @State private var guideFocusTargetID: String?

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
    /// User-defined Live TV group display order + sort mode (Manage Groups).
    /// Order is a native [String] array (order-preserving iCloud path);
    /// mode is "default" / "alphabetical" / "manual". Empty order + default
    /// mode == server order.
    private let channelGroupOrderKey = "channelGroupOrder"
    private var channelGroupSortModeKey: String { channelGroupOrderKey + ".sortMode" }
    @State private var groupOrder: [String] = []
    @State private var groupSortMode: String = GroupSortMode.default.rawValue

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
                    // Guide view toggle: shown on all iOS width classes now
                    // that iPhone (and the folded foldable) can open the Guide.
                    // Session-only: toggling never writes defaultLiveTVView.
                    // (iPad search button moved into the chip row, see
                    // groupFilterBar's iPad branch.)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            userDidToggleView = true
                            withAnimation(.spring(response: 0.25)) { showGuideView.toggle() }
                        } label: {
                            Image(systemName: showGuideView ? "list.bullet" : "calendar")
                                .foregroundColor(.accentPrimary)
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
                // v1.6.13.x: iPhone keeps the classic always-visible
                // nav-bar drawer search field (collapsing under
                // compact chrome). iPad now omits `.searchable`
                // entirely — the search UX moved to a button +
                // inline TextField inside the chip row (see
                // `groupFilterBar`'s iPad branch). The earlier
                // attempt to use `.searchable(isPresented:)` to
                // hide the drawer didn't actually hide it on iOS 18
                // (placement-driven visibility wins over the binding
                // for `.navigationBarDrawer`), so we drop the modifier
                // on iPad rather than fight the system.
                .modifier(
                    PerIdiomSearchableModifier(
                        text: $searchText,
                        iPhoneDisplayMode: (isCompactChrome && hideSearchBarCompact) ? .automatic : .always
                    )
                )
                #endif
                .onChange(of: searchText)       { _, _ in filterChannels() }
                .onChange(of: selectedGroup)    { _, _ in filterChannels() }
                .onChange(of: sortModeRaw)      { _, _ in filterChannels() }
                // #45: re-filter when a collection's membership changes so a
                // collection view updates live as channels are added/removed.
                .onChange(of: collectionsStore.collections) { _, _ in filterChannels() }
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
                // EPG-search jump: force guide mode and clear any group
                // filter so the target channel is visible. EPGGuideView
                // consumes the pending target (UserDefaults) and scrolls.
                .onReceive(NotificationCenter.default.publisher(for: .aerioJumpToGuideProgram)) { _ in
                    if selectedGroup != "All" {
                        selectedGroup = "All"
                        filterChannels()
                    }
                    showGuideView = true
                }
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
                    // Width-adaptive default: compact (iPhone portrait, folded
                    // foldable) opens List unless the user explicitly chose
                    // Guide; regular (iPad, unfolded foldable, Plus / Max
                    // landscape) opens Guide unless the user explicitly chose
                    // List. See resolvedGuideDefault.
                    showGuideView = resolvedGuideDefault(hasEPG: hasEPG)
                    #endif
                    // EPG-search jump (cold path): if SearchView stashed a
                    // pending guide target, force guide mode so EPGGuideView
                    // can scroll to it once it mounts.
                    if UserDefaults.standard.object(forKey: "guideJumpChannelID") != nil {
                        showGuideView = true
                        if selectedGroup != "All" { selectedGroup = "All" }
                    }
                    hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                    groupOrder = GroupOrderStore.load(forKey: channelGroupOrderKey)
                    groupSortMode = GroupOrderStore.loadMode(forKey: channelGroupSortModeKey)
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
                        },
                        orderStorageKey: channelGroupOrderKey,
                        onConfigChanged: { mode, newOrder in
                            groupSortMode = mode
                            groupOrder = newOrder
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
                    // Upgrade-only: once EPG arrives, move to Guide if the
                    // width-adaptive default wants it, but ONLY if the user has
                    // not manually toggled the view this session. A manual List
                    // choice must survive a server arriving.
                    if !userDidToggleView && resolvedGuideDefault(hasEPG: hasEPG) && !showGuideView {
                        showGuideView = true
                    }
                    #endif
                }
                #if os(iOS)
                // Foldables flip the horizontal size class on fold / unfold
                // (also iPad Split View resize and Plus / Max rotation). Re-seed
                // the List / Guide default to the new width so a folded foldable
                // lands on List and an unfolded one lands on Guide, mirroring
                // Android re-seeding to the width default on a width-class
                // change. Skipped while a guide-jump is pending (so this does
                // not fight the EPG-search jump, which forces Guide and consumes
                // its own pending target) and skipped once the user has manually
                // toggled the view this session, so an explicit choice survives
                // fold / unfold, Split View resize, and rotation.
                .onChange(of: sizeClass) { _, _ in
                    guard UserDefaults.standard.object(forKey: "guideJumpChannelID") == nil else { return }
                    guard !userDidToggleView else { return }
                    let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                    let hasEPG: Bool = {
                        guard let s = activeServer else { return false }
                        if s.type == .m3uPlaylist { return !s.epgURL.isEmpty }
                        return true
                    }()
                    showGuideView = resolvedGuideDefault(hasEPG: hasEPG)
                }
                // Changing the Settings default is an explicit, deliberate
                // choice, so it wins over a stale session toggle: clear the
                // toggle flag and re-seed the view immediately from the new
                // default.
                .onChange(of: defaultLiveTVView) { _, _ in
                    userDidToggleView = false
                    let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
                    let hasEPG: Bool = {
                        guard let s = activeServer else { return false }
                        if s.type == .m3uPlaylist { return !s.epgURL.isEmpty }
                        return true
                    }()
                    showGuideView = resolvedGuideDefault(hasEPG: hasEPG)
                }
                #endif
                .onReceive(NotificationCenter.default.publisher(for: .syncManagerDidApplyPreferences)) { _ in
                    hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                    groupOrder = GroupOrderStore.load(forKey: channelGroupOrderKey)
                    groupSortMode = GroupOrderStore.loadMode(forKey: channelGroupSortModeKey)
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
                bodyContent
            }
            // GH #20 follow-up (user report 2026-07-12): this VStack consumed
            // the bottom safe area BEFORE the List inside could reach it, so
            // the scroll frame ended at the tab bar line - rows hard-clipped
            // there (the ignoresSafeArea on the List only stretched its
            // BACKGROUND, proven by the red-background debug build). Extend
            // the CONTAINER so the scroll view owns the full height; the
            // trailing spacer row provides the bottom content padding.
            // iOS-only: tvOS has no bottom bar.
            #if os(iOS)
            .ignoresSafeArea(.container, edges: .bottom)
            #endif
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
                action: { Task { await channelStore.forceRefresh(servers: servers, modelContext: modelContext) } },
                actionTitle: "Refresh"
            )
        } else if showGuideView {
            // v1.6.13.x: Outer VStack with a 0-height GHOST CAPTURE
            // POINT as its first child, then the actual padded VStack
            // as its second child. The ghost's position equals
            // bodyContent's natural top (= chip row's natural top
            // before any push). Padding the inner VStack stretches
            // the outer VStack DOWNWARD but doesn't move the ghost,
            // so the captured value is rock-stable. This is what
            // every prior attempt was trying to achieve via various
            // marker placements; this position is the one SwiftUI
            // actually honors.
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).minY
                    } action: { newValue in
                        capturedNaturalTop = newValue
                    }

                HStack(spacing: 0) {
                    #if os(tvOS)
                    // Docked group sidebar (Group Selection: Sidebar Menu). The
                    // guide shifts right beside it; Right/Back close it.
                    if guideSidebarOpen {
                        // #196 Android-parity semantics: focusing a row
                        // PREVIEWS its group live behind the pane (90ms
                        // debounce); OK or Right COMMITS and closes; Back
                        // reverts to the group the sidebar opened with.
                        GuideGroupSidebarPane(
                            groups: ["All"] + visibleGroups,
                            selectedToken: selectedGroup,
                            onSelect: { token in
                                guideSidebarPreviewTask?.cancel()
                                selectedGroup = token
                                closeGuideSidebar(
                                    rebind: token != guideSidebarOriginalGroup
                                )
                            },
                            onDismiss: {
                                guideSidebarPreviewTask?.cancel()
                                if let origin = guideSidebarOriginalGroup,
                                   origin != selectedGroup {
                                    selectedGroup = origin
                                }
                                closeGuideSidebar(rebind: false)
                            },
                            onPreview: { token in
                                guideSidebarPreviewTask?.cancel()
                                guideSidebarPreviewTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 90_000_000)
                                    guard !Task.isCancelled else { return }
                                    selectedGroup = token
                                }
                            },
                            onCommit: {
                                guideSidebarPreviewTask?.cancel()
                                closeGuideSidebar(
                                    rebind: selectedGroup != guideSidebarOriginalGroup
                                )
                            }
                        )
                        .transition(.move(edge: .leading))
                        .focusSection()
                    }
                    #endif
                    VStack(spacing: 0) {
                        // Compact-chrome honors the user's hide-filter preference even
                        // in the iPad Guide layout (iPad itself is gated by the flag,
                        // so this only activates on actual iPhones in landscape).
                        // Sidebar mode hides the pills (mutually exclusive selectors).
                        if (channelStore.orderedGroups.count > 1 || !hiddenGroups.isEmpty)
                            && !compactChromeHidesFilterBar
                            && !guideSidebarSelectorActive {
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
                            },
                            sidebarOpen: guideSidebarOpen,
                            onRequestGroupSidebar: { programID in
                                guideSidebarReturnProgramID = programID
                                // #196: remember the group for the Back-revert
                                // of a live preview.
                                guideSidebarOriginalGroup = selectedGroup
                                withAnimation(.easeOut(duration: 0.28)) { guideSidebarOpen = true }
                            }
                        )
                        #if os(tvOS)
                        .focusSection()
                        #endif
                    }
                }
                #if os(tvOS)
                .animation(.easeOut(duration: 0.28), value: guideSidebarOpen)
                #endif
                .padding(.top, miniPlayerTopInset(naturalTopAbsolute: capturedNaturalTop))
                .animation(.spring(response: 0.35), value: capturedNaturalTop)
                .animation(.spring(response: 0.35), value: nowPlaying.isMinimized)
                .animation(.spring(response: 0.35), value: nowPlaying.miniPlayerBottomAbs)
                // #42 Part 1: long-press Left anywhere in the guide jumps focus
                // to the "All" pill. The detector installs a window-level Left
                // long-press recognizer (mounted only while the guide is shown);
                // a short Left still scrolls the timeline via onMoveCommand.
                #if os(tvOS)
                .background(
                    GuideLongPressLeftDetector(
                        // Sidebar mode opens the group menu on this hold, so it
                        // gets the snappier ~0.32s threshold (Android twin's
                        // SIDEBAR_HOLD_OPEN_MS; the OS-style 0.5s read as a
                        // slow open on device, Logan 2026-08-06).
                        minimumPressDuration: guideSidebarSelectorActive ? 0.32 : 0.5,
                        onBegan: { NotificationCenter.default.post(name: .guideLeftHoldBegan, object: nil) },
                        onEnded: { NotificationCenter.default.post(name: .guideLeftHoldEnded, object: nil) }
                    )
                )
                // Hold Right: dispatched by the mapped guide rightLong action
                // (#196). The default (closeMiniPlayer) keeps the old arming
                // gate - only meaningful while a mini is minimized - so
                // ordinary Right navigation is untouched; any other mapped
                // action arms whenever the guide is up.
                .background(
                    GuideLongPressRightDetector(
                        isEnabled: {
                            let action = RemoteControlStore.shared.guideAction(.rightLong)
                            if action == .closeMiniPlayer {
                                return nowPlaying.isActive && nowPlaying.isMinimized
                            }
                            return action != .none
                        }(),
                        onBegan: {
                            NotificationCenter.default.post(name: .guideRightHoldBegan, object: nil)
                            GuideRemoteDispatch.perform(
                                RemoteControlStore.shared.guideAction(.rightLong)
                            )
                        },
                        onEnded: {
                            NotificationCenter.default.post(name: .guideRightHoldEnded, object: nil)
                        }
                    )
                )
                .onReceive(NotificationCenter.default.publisher(for: .guideLeftHoldBegan)) { _ in
                    // Sidebar mode owns hold-Left (Logan 2026-08-06, ported
                    // from the Android ruling): the hold opens the docked
                    // group menu and a single Left stays plain navigation so
                    // the EPG history left of "now" is reachable. The mapped
                    // leftLong action applies only in pills mode.
                    if guideSidebarSelectorActive {
                        if !guideSidebarOpen {
                            NotificationCenter.default.post(name: .guideOpenGroupSidebar, object: nil)
                        }
                        return
                    }
                    // #196: hold-Left dispatches by the mapped action. The
                    // focus-pin below runs for EVERY hold (not just
                    // focusGroupPills): whatever the action did, the
                    // still-held Left must not overshoot into the leading
                    // Guide/Search/List controls, and pinning "All" is the
                    // established parking spot for the press duration.
                    let action = RemoteControlStore.shared.guideAction(.leftLong)
                    GuideRemoteDispatch.perform(action)
                    // Timeline jumps keep the grid focused via
                    // retargetFocusToViewportColumn; only the pill action
                    // needs the focus pin.
                    if action == .focusGroupPills {
                        leftHoldPinningAll = true
                        groupPillFocused = "All"
                        leftHoldSafetyTask?.cancel()
                        leftHoldSafetyTask = Task { @MainActor in
                            // Backstop in case the release event is missed, so focus
                            // is never permanently locked on "All".
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            if !Task.isCancelled { leftHoldPinningAll = false }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .guideLeftHoldEnded)) { _ in
                    leftHoldPinningAll = false
                    leftHoldSafetyTask?.cancel()
                    leftHoldSafetyTask = nil
                }
                #endif
            }
        } else {
            channelListContent
        }
    }

    // MARK: - Channel List Content

    private var channelListContent: some View {
        VStack(spacing: 0) {
            // v1.6.18 — pills only live in the VStack on iPad and tvOS,
            // where they're always visible. The iPhone scroll-collapse
            // path moves the pills into `.safeAreaInset(.top)` on the
            // List itself (further down) — see the comment at that
            // attachment for the full rationale. Short version: pills
            // here in the VStack, conditionally rendered with the iPhone
            // `isChromeCollapsed` `if`, caused an infinite layout
            // oscillation at the snap-out threshold. Removing the pills
            // shrunk the VStack which shifted the List's frame, which
            // perturbed the scroll geometry, which re-triggered the
            // hysteresis check, which un-collapsed the pills, repeat.
            // Pulling the iPhone pills out of the VStack and into a
            // List-level safe area inset means show/hide changes the
            // List's TOP INSET only — the List's content offset and
            // outer frame are stable, so the feedback loop can't form.
            if (channelStore.orderedGroups.count > 1 || !hiddenGroups.isEmpty)
                && !compactChromeHidesFilterBar {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom != .phone {
                    groupFilterBar
                        .padding(.vertical, 10)
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

                        // Keyed by the channel id (Identifiable), not rowKey,
                        // because the tvOS focus + scroll-restore below targets
                        // rows by id (`focusedGuideRowID`, prefersDefaultFocus,
                        // proxy.scrollTo(valid)). The load-time dedup by stream
                        // URL keeps these ids unique, so no duplicate identity
                        // can reach this list.
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
                            // Marks the currently-playing row as the
                            // default-focus target for the guide
                            // scope. When `resetFocus(in:
                            // guideFocusNS)` fires from the
                            // `.forceGuideFocus` handler below, tvOS
                            // moves focus to whichever row has this
                            // flag set. Pre-1.6.18 we marked the
                            // top row — minimizing the player into
                            // the corner mini left focus on row 0
                            // regardless of what the user had been
                            // watching, which felt random and made
                            // the guide auto-scroll to the top
                            // for no apparent reason. v1.6.18:
                            // prefer the currently-playing channel's
                            // row when present, fall back to the
                            // top row only when no channel is
                            // playing (or it's not in the current
                            // filter). The corresponding scrollTo
                            // in the `.forceGuideFocus` handler
                            // makes sure the playing row is
                            // actually visible when focus lands.
                            .prefersDefaultFocus(
                                item.id == (guideFocusTargetID
                                            ?? nowPlaying.playingItem?.id
                                            ?? nowPlaying.lastPlayedChannelID
                                            ?? filteredChannels.first?.id),
                                in: guideFocusNS
                            )
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
                    // Menu on the guide = jump focus to the very top channel.
                    // resetFocus alone does not honor prefersDefaultFocus here
                    // (it lands on whatever row is topmost-realized after the
                    // scroll), so drive the @FocusState target directly: instant
                    // scroll the top row into view to realize it, then re-assert
                    // focusedGuideRowID until the engine accepts it (a single
                    // write is dropped while the row is still laying out).
                    Task { @MainActor in
                        let target = filteredChannels.first?.id
                        guideFocusTargetID = target
                        debugLog("🧭 [GuideFocus] scrollToTop(list) → target=\(target ?? "nil") count=\(filteredChannels.count)")
                        guard let target else { return }
                        for attempt in 0..<8 {
                            proxy.scrollTo("guide.top", anchor: .top)
                            focusedGuideRowID = target
                            try? await Task.sleep(nanoseconds: 70_000_000)
                            debugLog("🧭 [GuideFocus] assert(top) attempt=\(attempt) set=\(target) got=\(focusedGuideRowID ?? "nil")")
                            if focusedGuideRowID == target { break }
                        }
                        // Force the absolute top after the focus engine's
                        // reveal-scroll settles, so the first row is not left
                        // hidden just above the viewport.
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        proxy.scrollTo("guide.top", anchor: .top)
                        debugLog("🧭 [GuideFocus] scrollToTop(list) final force-top, focus=\(focusedGuideRowID ?? "nil")")
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .forceGuideFocus)
                ) { _ in
                    // Return-from-player: land focus on the channel the user was
                    // just watching. resetFocus pulls focus off the minimized
                    // mini tile into the guide scope but lands on the topmost
                    // realized row, not the watched channel, so after that we
                    // instant-scroll the target to center and re-assert
                    // focusedGuideRowID until the engine accepts it.
                    Task { @MainActor in
                        // TEST (branch test/avplayer-hls-engine): never
                        // steal focus from the presented native AVPlayer
                        // cover (PlayerSession.mode stays .idle there, so
                        // mode checks cannot catch this).
                        guard PlayerSession.shared.nativeHLSItem == nil else {
                            debugLog("[GuideFocus] forceGuideFocus suppressed (native player presented)")
                            return
                        }
                        try? await Task.sleep(nanoseconds: 400_000_000)  // minimize spring
                        let resolved = nowPlaying.playingItem?.id ?? nowPlaying.lastPlayedChannelID
                        let valid = resolved.flatMap { id in
                            filteredChannels.contains(where: { $0.id == id }) ? id : nil
                        }
                        guideFocusTargetID = valid
                        debugLog("🧭 [GuideFocus] forceGuideFocus(list) → playing=\(nowPlaying.playingItem?.id ?? "nil") last=\(nowPlaying.lastPlayedChannelID ?? "nil") valid=\(valid ?? "nil") count=\(filteredChannels.count)")
                        guard let valid else { resetFocus(in: guideFocusNS); return }
                        resetFocus(in: guideFocusNS)
                        for attempt in 0..<8 {
                            proxy.scrollTo(valid, anchor: .center)
                            focusedGuideRowID = valid
                            try? await Task.sleep(nanoseconds: 70_000_000)
                            debugLog("🧭 [GuideFocus] assert(return) attempt=\(attempt) set=\(valid) got=\(focusedGuideRowID ?? "nil")")
                            if focusedGuideRowID == valid { break }
                        }
                    }
                }
            }
            #else
            List {
                // Key rows by the unique stream URL, not the channel id,
                // so a provider that reuses one tvg-id across distinct
                // channels can't produce duplicate SwiftUI identities.
                ForEach(filteredChannels, id: \.rowKey) { item in
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
                // GH #20 follow-up: with the list frame extended under the
                // floating tab bar (ignoresSafeArea below), this spacer is
                // the bottom content padding that lets the last channel row
                // scroll clear of the bar + home indicator (the Android
                // LazyColumn's 104dp contentPadding analog; .contentMargins
                // leaked the margin to the top edge on iOS 26).
                Color.clear
                    .frame(height: 96)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .background(Color.appBackground)
            .scrollContentBackground(.hidden)
            // Apple GH #55 (jayegles): swiping left/right on the list cycles
            // the selected group pill (left = next, right = previous, clamped
            // at the ends). simultaneousGesture plus the horizontal-dominance
            // check keeps vertical scrolling, pull-to-refresh, and row taps
            // untouched. A collection filter isn't part of the cycle; the
            // first swipe from one lands on All. Mirrored on Android.
            //
            // 2026-07-12: interactive drag - the list follows the finger
            // (rubber-banded when there's no group on that side), and a
            // committed swipe pages the old list off-screen before the new
            // group's list slides in from the opposite edge, so it reads as
            // dragging between pages instead of an instant filter change.
            .offset(x: groupDragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 40)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        // Latch dominance once per gesture so a drag that
                        // starts vertical can never morph into a group drag
                        // mid-flight (and vice versa).
                        if groupDragIsHorizontal == nil {
                            groupDragIsHorizontal = abs(dx) > abs(dy) * 1.5
                        }
                        guard groupDragIsHorizontal == true else { return }
                        groupDragOffset = canCycleGroup(forward: dx < 0) ? dx : dx / 3
                    }
                    .onEnded { value in
                        let wasHorizontal = groupDragIsHorizontal == true
                        groupDragIsHorizontal = nil
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard wasHorizontal, abs(dx) > 70, abs(dx) > abs(dy) * 1.5,
                              canCycleGroup(forward: dx < 0) else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                groupDragOffset = 0
                            }
                            return
                        }
                        let forward = dx < 0
                        let width = UIScreen.main.bounds.width
                        withAnimation(.easeIn(duration: 0.12)) {
                            groupDragOffset = forward ? -width : width
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            cycleGroup(forward: forward)
                            // Re-enter from the opposite edge with the new group.
                            groupDragOffset = forward ? width : -width
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                groupDragOffset = 0
                            }
                        }
                    }
            )
            // v1.6.18 — iPhone pills moved here from the VStack
            // sibling above. When the user scrolls past 80pt the
            // pills tuck away to reclaim ~40% of vertical chrome;
            // expanding again near the top (< 20pt) brings them
            // back. By living in `.safeAreaInset(.top)` instead of
            // a VStack sibling, show/hide changes only the List's
            // top safe-area inset — the List's outer frame and
            // content offset stay stable across the transition,
            // so the layout-recalibration → re-trigger feedback
            // loop that produced the v1.6.17 oscillation can't
            // form. iPad / tvOS still render the pills above the
            // List in the VStack at the top of `channelListContent`.
            .safeAreaInset(edge: .top, spacing: 0) {
                if UIDevice.current.userInterfaceIdiom == .phone
                    && !isChromeCollapsed
                    && (channelStore.orderedGroups.count > 1 || !hiddenGroups.isEmpty)
                    && !compactChromeHidesFilterBar {
                    groupFilterBar
                        .padding(.vertical, 10)
                        .background(Color.appBackground)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .refreshable {
                await EPGCache.shared.invalidateAll()
                await channelStore.forceRefresh(servers: servers, modelContext: modelContext)
            }
            // iPhone-only: collapse the chrome (filter pills) when the
            // list scrolls past 80pt; expand again near the top (< 20pt).
            // Hysteresis prevents jitter at the boundary. iPad keeps the
            // chrome visible — it has plenty of vertical space.
            // The tab bar rides the same observer but with DIRECTION
            // tracking (2026-07-12, Android parity): hide on a deliberate
            // downward scroll, full bar back on any upward scroll.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldY, y in
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
                if let hidden = tabBarTracker.update(oldY: oldY, newY: y,
                                                     hidden: isTabBarScrolledAway) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTabBarScrolledAway = hidden
                    }
                }
            }
            // GH #20 (Android parity): tuck the tab bar away on scroll so
            // the list reclaims its height. Phone-only by construction:
            // the observer above never sets the flag on iPad.
            .scrollAwayTabBar(collapsed: isTabBarScrolledAway)
            // GH #20 follow-up (user report 2026-07-12): on iOS 26 the list's
            // frame stopped at the safe-area line above the tab bar, leaving
            // a dead band that stayed behind when the system minimized the
            // bar. Mirror the Android solution outright: extend the list's
            // frame to the physical bottom edge (rows show under/behind the
            // floating bar) and give the CONTENT a bottom margin so the last
            // row can scroll clear of the bar + home indicator.
            .ignoresSafeArea(.container, edges: .bottom)
            // ...and stop the iOS 26 bottom scroll-edge effect from painting
            // an opaque platter over the rows in the bar region (the actual
            // "dead band" - see aerioContentUnderTabBar).
            .aerioContentUnderTabBar()
            #endif
        }
        // v1.6.13: same mini push-down as the Guide branch above.
        // iOS-only in practice (tvOS uses Guide). Natural top is
        // captured by the sibling marker in `mainContent`.
        #if os(iOS)
        .padding(.top, miniPlayerTopInset(naturalTopAbsolute: capturedNaturalTop))
        .animation(.spring(response: 0.35), value: capturedNaturalTop)
        .animation(.spring(response: 0.35), value: nowPlaying.isMinimized)
        .animation(.spring(response: 0.35), value: nowPlaying.miniPlayerBottomAbs)
        #endif
    }

    // MARK: - Group Filter Bar

    private var groupFilterBar: some View {
        // ScrollViewReader so a group swipe on the list (GH #55) can glide
        // the pill row to the newly selected pill - the pills visibly follow
        // the swipe. iOS-only in effect: only the iOS pills carry the
        // "pill_" ids, so the tvOS scrollTo is a no-op and its focus-driven
        // scrolling stays untouched.
        ScrollViewReader { pillProxy in
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
                // #42 Part 1: leading controls go non-focusable while a guide
                // Left is held, so the hold stops at "All" instead of
                // overshooting into them. (TVGroupPill's custom style ignores
                // isEnabled, so .disabled removes focus without dimming.)
                .disabled(leftHoldPinningAll)

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
                .disabled(leftHoldPinningAll)   // #42 Part 1: see above

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
                // v1.6.13.x: iPad search button + inline TextField,
                // placed immediately to the right of Manage Groups
                // per user spec. Replaces the previous nav-bar
                // search drawer that wouldn't actually hide. The
                // TextField only renders when the toggle is on, so
                // the chip row keeps its original height by default.
                if UIDevice.current.userInterfaceIdiom == .pad {
                    // v1.6.23 (Codex UX P3): the search button used
                    // to clear `searchText` when the user collapsed
                    // the field, destroying their query along with
                    // the chrome. Hiding the control and clearing
                    // the user's intent are different actions; we
                    // now preserve the query when the field is
                    // hidden so re-opening restores the previous
                    // search. The button visual flips to a "filled"
                    // glyph when a search is active but hidden, so
                    // users can tell at a glance that a filter is
                    // still in effect.
                    let hasActiveSearch = !searchText.isEmpty
                    let buttonGlyph: String = {
                        if iPadSearchPresented {
                            return "magnifyingglass.circle.fill"
                        } else if hasActiveSearch {
                            return "magnifyingglass.circle"
                        } else {
                            return "magnifyingglass"
                        }
                    }()
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            iPadSearchPresented.toggle()
                            // Intentionally NOT clearing searchText
                            // on collapse. Users who want to clear
                            // the filter can do so by emptying the
                            // field (the existing clear-X inside
                            // the TextField, or backspace).
                        }
                    } label: {
                        Image(systemName: buttonGlyph)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(iPadSearchPresented ? .appBackground : (hasActiveSearch ? .accentPrimary : .textSecondary))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(iPadSearchPresented ? Color.accentPrimary : Color.elevatedBackground)
                            )
                    }
                    .accessibilityLabel(
                        iPadSearchPresented
                            ? "Hide Search"
                            : (hasActiveSearch ? "Search Channels (filter active)" : "Search Channels")
                    )

                    if iPadSearchPresented {
                        TextField("Search channels", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.labelMedium)
                            .foregroundColor(.textPrimary)
                            .frame(width: 240)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(Color.elevatedBackground)
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.accentPrimary.opacity(0.3), lineWidth: 1)
                                    )
                            )
                            .submitLabel(.search)
                    }
                }
                #else
                ManageGroupsButton(
                    action: { showManageGroups = true },
                    hiddenCount: hiddenGroups.count
                )
                .disabled(leftHoldPinningAll)   // #42 Part 1: see Guide toggle above
                #endif

                // #45: collections placed at the beginning sit before "All".
                // #42 Part 1: also non-focusable while a guide Left is held, so
                // the hold cannot land on a beginning collection before "All".
                ForEach(collectionsStore.beginningCollections) { c in
                    collectionPill(c, canFocus: !leftHoldPinningAll)
                }

                ForEach(["All"] + visibleGroups, id: \.self) { group in
                    #if os(tvOS)
                    TVGroupPill(
                        group: group,
                        isSelected: selectedGroup == group,
                        action: { withAnimation(.spring(response: 0.25)) { selectedGroup = group } }
                    )
                    // #42 Part 1: make the pills programmatic focus targets so a
                    // guide long-press Left can land focus on the "All" pill.
                    .focused($groupPillFocused, equals: group)
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
                    .id("pill_\(group)")
                    #endif
                }

                // #45: collections placed at the end sit after the last group.
                ForEach(collectionsStore.endCollections) { c in
                    collectionPill(c)
                }
            }
            .padding(.horizontal, 16)
            #if os(tvOS)
            // Vertical headroom so a focused pill's 1.05 scale + focus stroke
            // is not clipped by the horizontal ScrollView (which sizes its
            // height to the row). Previously the taller Manage Groups button
            // supplied this slack; the compact circle no longer does.
            .padding(.vertical, 6)
            #endif
        }
        // #45: manage a collection's pill (tvOS long-press → move / delete).
        // iOS uses .contextMenu on the pill instead (see collectionPill).
        #if os(tvOS)
        .confirmationDialog(
            managePillCollection?.name ?? "Collection",
            isPresented: Binding(
                get: { managePillCollection != nil },
                set: { if !$0 { managePillCollection = nil } }
            ),
            titleVisibility: .visible,
            presenting: managePillCollection
        ) { c in
            collectionManageActions(c)
            Button("Cancel", role: .cancel) { }
        }
        #endif
        .onChange(of: selectedGroup) { _, newValue in
            withAnimation(.spring(response: 0.3)) {
                pillProxy.scrollTo("pill_\(newValue)", anchor: .center)
            }
        }
        }
    }

    /// #45: one collection filter pill, matching the group-pill look. Selecting
    /// it sets `selectedGroup` to the `collection:<id>` sentinel that
    /// `filterChannels()` resolves to the collection's members.
    @ViewBuilder
    private func collectionPill(_ c: ChannelCollection, canFocus: Bool = true) -> some View {
        let token = "collection:\(c.id)"
        #if os(tvOS)
        CollectionPillTV(
            name: c.name,
            isSelected: selectedGroup == token,
            canFocus: canFocus,
            onTap: { withAnimation(.spring(response: 0.25)) { selectedGroup = token } },
            onLongPress: { managePillCollection = c }
        )
        #else
        Button {
            withAnimation(.spring(response: 0.25)) { selectedGroup = token }
        } label: {
            Text(c.name)
                .font(.labelMedium)
                .foregroundColor(selectedGroup == token ? .appBackground : .textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    selectedGroup == token
                        ? AnyView(Capsule().fill(Color.accentPrimary))
                        : AnyView(Capsule().fill(Color.elevatedBackground))
                )
        }
        .buttonStyle(.plain)
        .id("pill_\(token)")
        .contextMenu { collectionManageActions(c) }
        #endif
    }

    /// #45: pill long-press actions (tvOS confirmationDialog + iOS contextMenu):
    /// move the collection's pill front/back, or delete the collection.
    @ViewBuilder
    private func collectionManageActions(_ c: ChannelCollection) -> some View {
        if c.placement == .end {
            Button {
                ChannelCollectionsStore.shared.setPlacement(id: c.id, to: .beginning)
            } label: { Label("Move to Front", systemImage: "arrow.left.to.line") }
        } else {
            Button {
                ChannelCollectionsStore.shared.setPlacement(id: c.id, to: .end)
            } label: { Label("Move to Back", systemImage: "arrow.right.to.line") }
        }
        Button(role: .destructive) {
            // Mirror the hidden-group reset: if we're filtered to this
            // collection, drop back to All before its pill vanishes.
            if selectedGroup == "collection:\(c.id)" { selectedGroup = "All" }
            ChannelCollectionsStore.shared.delete(id: c.id)
        } label: { Label("Delete Collection", systemImage: "trash") }
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
                Task { await channelStore.forceRefresh(servers: servers, modelContext: modelContext) }
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
        GroupOrderStore.displayOrder(channelStore.orderedGroups, mode: groupSortMode, order: groupOrder)
            .filter { !hiddenGroups.contains($0) }
    }

    /// Apple GH #55: step the selected group pill from a horizontal list
    /// swipe. The cycle matches the pill row (All first, then the visible
    /// groups in display order) and clamps at both ends.
    private func cycleGroup(forward: Bool) {
        let cycle = ["All"] + visibleGroups
        guard cycle.count > 1 else { return }
        let current = cycle.firstIndex(of: selectedGroup) ?? 0
        let target = min(max(forward ? current + 1 : current - 1, 0), cycle.count - 1)
        guard cycle[target] != selectedGroup else { return }
        // NO withAnimation: this only runs mid swipe-commit, where the list
        // is already animating the page transition. Animating the content
        // diff at the same time made the slide-in visibly stutter (user
        // report vs the Android build); the pill row's follow-scroll is
        // animated separately by groupFilterBar's onChange.
        selectedGroup = cycle[target]
    }

    /// True when a swipe in that direction has a group to land on (the
    /// interactive drag rubber-bands instead of following at the ends).
    private func canCycleGroup(forward: Bool) -> Bool {
        let cycle = ["All"] + visibleGroups
        guard cycle.count > 1 else { return false }
        let current = cycle.firstIndex(of: selectedGroup) ?? 0
        let target = forward ? current + 1 : current - 1
        return target >= 0 && target < cycle.count
    }

    private func filterChannels() {
        var result = channelStore.channels
        if selectedGroup.hasPrefix("collection:") {
            // #45: collection filter — show exactly the curated members. The
            // user explicitly chose them, so hidden-group exclusion is bypassed.
            // If the collection was deleted, fall through to showing everything.
            let cid = String(selectedGroup.dropFirst("collection:".count))
            ChannelCollectionsStore.shared.activeFilterCollectionID = cid
            if let c = ChannelCollectionsStore.shared.collection(id: cid) {
                let memberSet = Set(c.memberIDs)
                result = result.filter { memberSet.contains($0.id) }
            }
        } else {
            ChannelCollectionsStore.shared.activeFilterCollectionID = nil
            // Exclude channels belonging to hidden groups
            if !hiddenGroups.isEmpty {
                result = result.filter { !hiddenGroups.contains($0.group) }
            }
            if selectedGroup != "All" {
                result = result.filter { $0.group == selectedGroup }
            }
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
        // Group ordering: when a non-default group order is chosen in
        // Manage Groups (A-Z or Manual), reorder channels so they are
        // grouped by that order. This is a STABLE re-sort, so the channel
        // sort applied above (number / name / favorites) is preserved as
        // the within-group order. Default group order leaves the global
        // channel sort untouched (pre-existing behavior). Drives both the
        // list and the guide, which both render `filteredChannels`.
        if (GroupSortMode(rawValue: groupSortMode) ?? .default) != .default {
            let ordered = GroupOrderStore.displayOrder(channelStore.orderedGroups, mode: groupSortMode, order: groupOrder)
            let rank = Dictionary(ordered.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            result = result.enumerated().sorted { lhs, rhs in
                let rl = rank[lhs.element.group] ?? Int.max
                let rr = rank[rhs.element.group] ?? Int.max
                if rl != rr { return rl < rr }
                return lhs.offset < rhs.offset
            }.map { $0.element }
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
        // "Play Channels In: Mini Player" (Remote Control settings, tvOS-only,
        // default off; Android #226 twin, AerioTV-Android 8cfddab). First
        // Select on a browse tune mounts the session ALREADY minimized (the
        // old begin-fullscreen-then-minimize-400ms flow flashed the full
        // player over the guide). A second Select on the channel already
        // playing in the corner promotes it to fullscreen instead of
        // re-tuning the same stream. Resume / deep-link / cast paths don't
        // route through here, so they stay fullscreen.
        #if os(tvOS)
        if RemoteControlStore.shared.tuneInMini {
            if nowPlaying.isMinimized, nowPlaying.playingItem?.id == item.id {
                nowPlaying.expand()
                return
            }
            nowPlaying.requestStartMinimized()
        }
        #endif
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
            // v1.6.20: per-server auth shape capture.
            let authMode = server.dispatcharrHeaderMode
            let userAgent = server.effectiveUserAgent
            // v1.7.x: capture identity + saved-username for the
            // silent api_key re-bootstrap path.
            let serverID = server.id
            let savedUsername: String? = server.dispatcharrCredentialType == .usernamePassword
                ? server.username : nil
            let cacheKey = "d_\(baseURL)_\(tvgID.isEmpty ? item.id : tvgID)"
            return {
                if let cached = await EPGCache.shared.get(cacheKey) { return cached }
                let dAPI = DispatcharrAPI(baseURL: baseURL, auth: .apiKey(apiKey),
                                          userAgent: userAgent, authMode: authMode,
                                          serverID: serverID, savedUsername: savedUsername)
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
                        // v1.7.x: thread Dispatcharr `programID` so the
                        // expanded panel's Program Info modal can
                        // lazy-load categories the bulk grid strips.
                        return EPGEntry(title: $0.title,
                                        description: desc,
                                        startTime: $0.startTime?.toDate(),
                                        endTime:   $0.endTime?.toDate(),
                                        programID: $0.programID,
                                        subTitle: $0.subTitle.isEmpty ? nil : $0.subTitle,
                                        season: $0.season, episode: $0.episode,
                                        isNew: $0.isNew, isLiveBroadcast: $0.isLiveBroadcast,
                                        isPremiere: $0.isPremiere, isFinale: $0.isFinale)
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
                                     category: $0.category,
                                     subTitle: $0.subTitle, season: $0.season,
                                     episode: $0.episode, isNew: $0.isNew,
                                     isLiveBroadcast: $0.isLiveBroadcast,
                                     isPremiere: $0.isPremiere, isFinale: $0.isFinale,
                                     isRepeat: $0.isRepeat)
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
    var streamURL: URL?
    var streamURLs: [URL]
    /// GH #59: the provider's own row position, when that ordering is more
    /// trustworthy than `number`.
    ///
    /// Set only for Xtream playlists served by a Dispatcharr backend. Its XC
    /// emulation cannot express decimal channel numbers, so it remaps them to
    /// collision-free integers server-side (`_xc_live_streams_setup` in
    /// `apps/output/views.py`): a lineup of 1.1/1.2/1.3/2/3/4 arrives as
    /// 1/5/6/2/3/4, and sorting on that scatters subchannels to the end of the
    /// list — the "subchannels are not appearing" report. Dispatcharr does
    /// emit the list `.order_by("effective_channel_number")` though, so the
    /// ROW ORDER still carries the truth the numbers lost.
    ///
    /// `nil` everywhere else, so real Xtream panels and M3U keep sorting by
    /// channel number exactly as before.
    var panelOrder: Int? = nil
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
    /// Dispatcharr-only: the channel's `epg_data_id` foreign-key
    /// integer (`Channel.epg_data_id` in Dispatcharr's models). v1.6.22
    /// uses this to bridge to `/api/epg/epgdata/`'s `tvg_id` value
    /// when matching the bulk grid response to channels. About 25%
    /// of real-world channels have `Channel.tvg_id !=
    /// EPGData.tvg_id` (EPGData is set at XMLTV ingest, Channel is
    /// user-configurable). Without this bridge, those channels
    /// render blank in the Live TV guide. `nil` for non-Dispatcharr
    /// providers, or for Dispatcharr channels with no linked EPG
    /// source.
    var dispatcharrEPGDataID: Int? = nil
    var currentProgram: String? = nil
    var currentProgramDescription: String? = nil
    var currentProgramStart: Date? = nil
    var currentProgramEnd: Date? = nil
    /// Raw XMLTV `<category>` (or Xtream `genre`) of the currently-airing
    /// program, if the EPG source provided one. Read by `CategoryColor.bucket(for:)`
    /// when the optional "Tint channel cards" toggle is on. Nil for sources that
    /// don't expose category data (Dispatcharr and Xtream Codes currently).
    var currentProgramCategory: String? = nil
    /// Catch-up (timeshift): how many days of already-aired programming
    /// this channel's provider archives. 0 = no catch-up. Dispatcharr:
    /// the server-side MAX across the channel's provider streams
    /// (`is_catchup`/`catchup_days` on /api/channels/channels/). Xtream
    /// Codes: get_live_streams `tv_archive`/`tv_archive_duration`.
    var catchupDays: Int = 0

    /// Stable SwiftUI list identity keyed by the channel's UNIQUE stream
    /// URL rather than `id`. A messy provider (large IPTV panels do this)
    /// can assign the SAME tvg-id to multiple DISTINCT channels, and any
    /// derived `id` that collapses onto tvg-id would then repeat across
    /// rows. SwiftUI's `ForEach`/`List` require unique identities; a
    /// duplicate drops rows, mis-animates, and logs "ID occurs multiple
    /// times" (the same messy-playlist case hard-crashes the equivalent
    /// LazyColumn on Android). The stream URL is unique per distinct
    /// channel, so it disambiguates channels that merely share a tvg-id.
    /// Falls back to `id` when a channel has no stream URL (Dispatcharr
    /// channels with a nil server UUID), keeping the key total and
    /// non-optional. Do NOT use this to replace `id` where scroll-to /
    /// focus / selection is keyed on the channel id (tvOS guide list, EPG
    /// guide grid): those stay on `id`, which the load-time dedup below
    /// keeps unique anyway.
    var rowKey: String { streamURL?.absoluteString ?? id }

    /// True when this channel has any catch-up archive at all.
    var hasCatchup: Bool { catchupDays > 0 }

    /// Whether a programme spanning [start, end] can be replayed from the
    /// channel's archive right now: it must have ENDED and still be inside
    /// the provider's retention window (capped at 30 days, matching the
    /// Dispatcharr server cap). Same gate drives the guide badge and the
    /// Watch action so the two can never disagree (AerioTV-Android parity).
    func canReplay(start: Date, end: Date, now: Date = Date()) -> Bool {
        guard hasCatchup else { return false }
        guard end <= now else { return false }
        let windowDays = min(catchupDays, 30)
        return now.timeIntervalSince(end) <= Double(windowDays) * 86_400
    }
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
    /// v1.7.x: Dispatcharr's `ProgramData.id` when known. Threaded
    /// through to `ProgramInfoView` so the modal can lazy-load
    /// `<category>` data via `/api/epg/programs/<id>/` whenever the
    /// row's `category` is empty (which happens for every non-airing
    /// Dispatcharr program because the bulk `/api/epg/grid/` endpoint
    /// strips category data server-side). Nil for XMLTV / Xtream
    /// sources whose feeds already include categories inline.
    let programID: Int?

    // EPG badge metadata (list-row + info-sheet badges). Defaults keep
    // the several call sites that don't carry this data compiling.
    let subTitle: String?
    let season: Int?
    let episode: Int?
    let isNew: Bool
    let isLiveBroadcast: Bool
    let isPremiere: Bool
    let isFinale: Bool
    let isRepeat: Bool

    init(title: String, description: String = "", startTime: Date?,
         endTime: Date?, category: String = "", programID: Int? = nil,
         subTitle: String? = nil, season: Int? = nil, episode: Int? = nil,
         isNew: Bool = false, isLiveBroadcast: Bool = false,
         isPremiere: Bool = false, isFinale: Bool = false, isRepeat: Bool = false) {
        self.title = title
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
        self.programID = programID
        self.subTitle = subTitle
        self.season = season
        self.episode = episode
        self.isNew = isNew
        self.isLiveBroadcast = isLiveBroadcast
        self.isPremiere = isPremiere
        self.isFinale = isFinale
        self.isRepeat = isRepeat
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

    /// Currently-airing program for this row, picking the best
    /// available source. v1.6.10: previously the row showed
    /// `item.currentProgram` and silently fell back to
    /// `item.group` (the channel's category, e.g. "Sports") when
    /// that was nil. On Dispatcharr that fallback was the common
    /// case — the heavy bulk current-program endpoint hadn't run
    /// yet, so every channel rendered as just its group name.
    /// Now we layer two sources:
    ///
    ///   1. `item.currentProgram*` — the lightweight per-item
    ///      payload populated by Xtream short-EPG and Dispatcharr's
    ///      current-programs cache when fresh. Cheapest source,
    ///      preferred when present.
    ///   2. `guideStore.programs[item.id]` filtered to `.isLive` —
    ///      the same dataset the Guide grid uses, populated by the
    ///      XMLTV parse and bulk EPG fetch. Reliable once the guide
    ///      has loaded.
    ///
    /// Returns nil when neither source has anything — the row's
    /// subtitle stays empty in that case (no more group-name
    /// fallback). Both the inline "now playing" line in the row
    /// and the progress bar consult this single tuple.
    private var liveProgram: (title: String, subTitle: String?, description: String?, start: Date, end: Date, flags: EPGFlags)? {
        if let title = item.currentProgram, !title.isEmpty,
           let start = item.currentProgramStart,
           let end = item.currentProgramEnd {
            // ChannelDisplayItem doesn't carry the feed badge flags or the
            // XMLTV <sub-title>; when GuideStore has the same now-airing
            // program, borrow both so the collapsed row can show LIVE/NEW and
            // the episode / sports-match name (GH #34).
            let liveGuideProg = guideStore.programs[item.id]?.first(where: { $0.isLive })
            let flags = liveGuideProg
                .map { EPGFlags(isNew: $0.isNew, isLiveBroadcast: $0.isLiveBroadcast,
                                isPremiere: $0.isPremiere, isFinale: $0.isFinale,
                                isRepeat: $0.isRepeat) } ?? EPGFlags()
            return (title, liveGuideProg?.subTitle, item.currentProgramDescription, start, end, flags)
        }
        if let p = guideStore.programs[item.id]?.first(where: { $0.isLive }) {
            return (p.title, p.subTitle, p.description, p.start, p.end,
                    EPGFlags(isNew: p.isNew, isLiveBroadcast: p.isLiveBroadcast,
                             isPremiere: p.isPremiere, isFinale: p.isFinale,
                             isRepeat: p.isRepeat))
        }
        return nil
    }

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

    /// Issue #28: when off, the channel logo is hidden so the channel name
    /// can use the full row width (the logo eats space and crops long names,
    /// especially on iPhone). Cross-platform; defaults on.
    @AppStorage("ui.showChannelLogos") private var showChannelLogos = true
    /// GH #19 (Android parity): when off, the channel-number column is
    /// hidden. Cross-platform; defaults on.
    @AppStorage("ui.showChannelNumbers") private var showChannelNumbers = true
    @AppStorage(epgBadgesVisibleKey) private var showEpgBadges = true
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
    /// Catch-up: the resolved timeshift playback presented full screen
    /// (recordings-pattern), or nil. Row-local: only the expanded row
    /// that launched a replay ever sets it.
    @State private var playingCatchup: CatchupPlayback? = nil
    /// Catch-up: user-facing resolve failure, shown as an alert.
    @State private var catchupErrorMessage: String? = nil
    /// Catch-up: whether the "Previously aired" history section is
    /// expanded. Collapsed by default so the panel lands on upcoming.
    @State private var showAiredPrograms = false
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

    // #45: per-channel "Add to Collection" picker + new-collection name alert.
    // Used by the iOS row (iOSRow) as well as tvOS, so these stay unconditional.
    // They were previously mis-scoped inside `#if os(tvOS)`, which left iOSRow
    // referencing undeclared state on iOS — masked until the iOSRow type-check
    // timeout was relieved by extracting the dialog builders.
    @State private var showCollectionPicker = false
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""

    #if os(tvOS)
    /// v1.7.5 (issue #34): confirm before REMOVING a favorite via the
    /// one-press star button. On Apple TV the star sits one D-pad-left
    /// from the channel, so a mis-aimed Select on an already-favorited
    /// channel silently dropped it from Favorites (reporter: ochaos).
    /// Adding a favorite stays immediate; only removal asks first.
    @State private var showRemoveFavoriteConfirmation = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            tvRow
                .alert("Remove Favorite?", isPresented: $showRemoveFavoriteConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Remove", role: .destructive) { favoritesStore.toggle(item) }
                } message: {
                    Text("Remove \"\(item.name)\" from Favorites?")
                }
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
            // SELECT adds a favorite immediately, but REMOVING one first
            // asks for confirmation (issue #34) so an accidental Select on
            // the star doesn't silently drop a channel from Favorites.
            Button {
                if favoritesStore.isFavorite(item.id) {
                    showRemoveFavoriteConfirmation = true
                } else {
                    favoritesStore.toggle(item)
                }
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
                    // GH #19: number column collapses when numbers are off.
                    if showChannelNumbers {
                        Text(item.number)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .foregroundColor(.textTertiary)
                            .frame(width: 42, alignment: .trailing)
                    }

                    if showChannelLogos {
                        CachedLogoImage(url: item.logoURL, width: 72, height: 48)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.textPrimary)
                                .lineLimit(1)
                            // Catch-up badge (2026-07-20, all-platform
                            // parity): history clock beside the name when
                            // the channel has a replayable archive.
                            if item.hasCatchup {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.textTertiary)
                            }
                        }

                        if let prog = liveProgram {
                            HStack(spacing: 8) {
                                MarqueeText(text: prog.title,
                                            font: .system(size: 22),
                                            color: .accentPrimary.opacity(0.85),
                                            isActive: isCardFocused)
                                    .frame(height: 28)
                                nowPlayingTimeRemaining(end: prog.end)
                                // Feed badges (LIVE/NEW/PREMIERE/...) for the
                                // now-airing program; renders nothing when none.
                                if showEpgBadges {
                                    EPGFlagsRow(flags: prog.flags.badges, compact: true)
                                }
                            }
                            // GH #34: XMLTV <sub-title> (match/episode name),
                            // guarded so a Dispatcharr promote-into-description
                            // program doesn't print it twice.
                            if let sub = prog.subTitle, !sub.isEmpty, sub != prog.title, sub != prog.description {
                                Text(sub)
                                    .font(.system(size: 18))
                                    .italic()
                                    .foregroundColor(.textSecondary)
                                    .lineLimit(1)
                            }
                            if let desc = prog.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 18))
                                    .foregroundColor(.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        // No fallback to group/category name — see
                        // `liveProgram` doc on ChannelRow.

                        if let prog = liveProgram {
                            nowPlayingProgressBar(start: prog.start, end: prog.end)
                                .padding(.top, 4)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 24)
                .padding(.leading, 8)
                .padding(.trailing, 4)
            }
            // The card already draws its own focused stroke (12pt, in the
            // row background); the style's 14pt ring nested a SECOND
            // rectangle around it. One highlight only.
            .buttonStyle(TVNoRingButtonStyle(drawsFocusRing: false))
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
            // GH #19: number column collapses when numbers are off.
            if showChannelNumbers {
                Text(item.number)
                    .font(.system(size: (isWide ? 17 : 13) * s, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .foregroundColor(.textTertiary)
                    .frame(width: (isWide ? 36 : 26) * s, alignment: .trailing)
            }

            if showChannelLogos {
                CachedLogoImage(
                    url: item.logoURL,
                    width: (isWide ? 50 : 38) * s,
                    height: (isWide ? 34 : 26) * s
                )
            }

            VStack(alignment: .leading, spacing: (isWide ? 4 : 2) * s) {
                HStack(spacing: 5 * s) {
                    Text(item.name)
                        .font(.system(size: (isWide ? 17 : 15) * s, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    // Catch-up badge (see tvOS row above).
                    if item.hasCatchup {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: (isWide ? 12 : 10) * s, weight: .semibold))
                            .foregroundColor(.textTertiary)
                    }
                }

                if let prog = liveProgram {
                    HStack(spacing: 8) {
                        MarqueeText(text: prog.title,
                                    font: .system(size: (isWide ? 15 : 11) * s),
                                    color: .accentPrimary.opacity(0.85),
                                    isActive: false)  // Static during scroll — saves GPU
                            .frame(height: (isWide ? 20 : 16) * s)
                        nowPlayingTimeRemaining(end: prog.end)
                        // Feed badges (LIVE/NEW/PREMIERE/...) for the
                        // now-airing program; renders nothing when none.
                        if showEpgBadges {
                            EPGFlagsRow(flags: prog.flags.badges, compact: true)
                        }
                    }
                    // GH #34: XMLTV <sub-title> (match/episode name), guarded
                    // against the Dispatcharr promote-into-description case.
                    if let sub = prog.subTitle, !sub.isEmpty, sub != prog.title, sub != prog.description {
                        Text(sub)
                            .font(.system(size: (isWide ? 12 : 10) * s))
                            .italic()
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)
                    }
                    if let desc = prog.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: (isWide ? 12 : 10) * s))
                            .foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                }
                // No fallback: when no program info is available the
                // subtitle slot stays empty rather than printing the
                // channel's group/category name. v1.6.10 — see
                // `liveProgram` doc.

                if let prog = liveProgram {
                    nowPlayingProgressBar(start: prog.start, end: prog.end)
                }
            }

            Spacer()

            // 2026-07-12 (user): the per-row ellipsis "More" button was
            // removed as redundant - long-pressing the row opens the same
            // menu. (History: the button was added in v1.6.23 for issues
            // #18/#35 long-press discoverability; the guide's tappable
            // favorite star now covers that affordance.)

            // -- Expand chevron --
            if item.currentProgram != nil || fetchUpcoming != nil {
                Button {
                    withAnimation(.spring(response: 0.25)) { isExpanded.toggle() }
                    // Skip the network fetch when GuideStore already has
                // programmes for this channel: the expanded panel
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
            cardMenuButtons
        }
        // #45: per-channel "Add to Collection" — toggle membership in any
        // existing collection (a checkmark marks current members) or create a
        // new one with this channel already in it.
        .confirmationDialog("Add to Collection", isPresented: $showCollectionPicker, titleVisibility: .visible) {
            collectionPickerButtons
        }
        .alert("New Collection", isPresented: $showNewCollectionAlert) {
            newCollectionAlertButtons
        } message: {
            Text("Name the collection and choose where its pill appears in the Live TV row.")
        }
    }

    // #49 follow-up: the card-menu / collection-picker / new-collection-alert
    // button builders are pulled out of `iOSRow` into their own @ViewBuilder
    // members. Inline (the #45 shape) they pushed the iOSRow body past the
    // Swift type-checker's expression budget ("unable to type-check in
    // reasonable time"), which only surfaced on the iOS build (tvOS uses the
    // separate, lighter `tvRow`). Behaviour is unchanged.
    @ViewBuilder
    private var cardMenuButtons: some View {
        let isFav = favoritesStore.isFavorite(item.id)
        Button(isFav ? "Remove from Favorites" : "Add to Favorites") {
            favoritesStore.toggle(item)
        }

        // #45: add/remove this channel from a user collection. Deferred so
        // this dialog fully dismisses before the picker presents (chained
        // confirmationDialogs race on tvOS otherwise).
        Button("Add to Collection…") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showCollectionPicker = true }
        }

        // #45: contextual remove. Viewing a collection -> remove from just
        // that one; otherwise (and only if it's in any) remove from all.
        if let cid = ChannelCollectionsStore.shared.activeFilterCollectionID,
           let coll = ChannelCollectionsStore.shared.collection(id: cid),
           coll.memberIDs.contains(item.id) {
            Button("Remove from \(coll.name)", role: .destructive) {
                ChannelCollectionsStore.shared.removeMember(channelID: item.id, in: cid)
            }
        } else if ChannelCollectionsStore.shared.activeFilterCollectionID == nil,
                  ChannelCollectionsStore.shared.isInAnyCollection(item.id) {
            Button("Remove from All Collections", role: .destructive) {
                ChannelCollectionsStore.shared.removeFromAllCollections(item.id)
            }
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
                // v1.7.x: pull programID from GuideStore if we
                // have it cached — lets the modal lazy-load any
                // category data the bulk enrichment hadn't reached
                // yet (rare for now-airing, common for all others).
                // Grab the whole now-airing GuideProgram (not just its
                // programID) so the modal carries the feed badges + episode
                // metadata for the currently-airing show. ChannelDisplayItem
                // itself doesn't carry these flags.
                let nowAiring = guideStore.programs[item.id]?
                    .first(where: { $0.start <= Date() && $0.end > Date() })
                activeSheet = .programInfo(
                    ProgramInfoTarget(
                        channelName: item.name,
                        title: program,
                        start: start,
                        end: end,
                        description: item.currentProgramDescription ?? "",
                        category: item.currentProgramCategory ?? "",
                        programID: nowAiring?.programID,
                        subTitle: nowAiring?.subTitle,
                        season: nowAiring?.season,
                        episode: nowAiring?.episode,
                        isNew: nowAiring?.isNew ?? false,
                        isLiveBroadcast: nowAiring?.isLiveBroadcast ?? false,
                        isPremiere: nowAiring?.isPremiere ?? false,
                        isFinale: nowAiring?.isFinale ?? false,
                        isRepeat: nowAiring?.isRepeat ?? false
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

    @ViewBuilder
    private var collectionPickerButtons: some View {
        ForEach(ChannelCollectionsStore.shared.collections) { c in
            Button((ChannelCollectionsStore.shared.contains(channelID: item.id, in: c.id) ? "✓ " : "") + c.name) {
                ChannelCollectionsStore.shared.toggleMember(channelID: item.id, in: c.id)
            }
        }
        Button("New Collection…") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showNewCollectionAlert = true }
        }
    }

    @ViewBuilder
    private var newCollectionAlertButtons: some View {
        TextField("Name", text: $newCollectionName)
        Button("Add at Beginning") {
            ChannelCollectionsStore.shared.create(name: newCollectionName, memberIDs: [item.id], placement: .beginning)
            newCollectionName = ""
        }
        Button("Add at End") {
            ChannelCollectionsStore.shared.create(name: newCollectionName, memberIDs: [item.id], placement: .end)
            newCollectionName = ""
        }
        Button("Cancel", role: .cancel) { newCollectionName = "" }
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
    /// Catch-up: this channel's ALREADY-AIRED programmes from the retained
    /// guide history, oldest first. Everything retained is listed (the
    /// per-server Guide History setting bounds the depth); the section
    /// renders collapsed so the panel still lands on the upcoming
    /// schedule, Android-parity semantics adapted to SwiftUI.
    private var airedPrograms: [EPGEntry] {
        let now = Date()
        let fromGuideStore = guideStore.programs[item.id] ?? []
        return fromGuideStore
            .filter { $0.end <= now }
            .sorted { $0.start < $1.start }
            .map {
                EPGEntry(title: $0.title, description: $0.description,
                         startTime: $0.start, endTime: $0.end,
                         category: $0.category, programID: $0.programID,
                         subTitle: $0.subTitle, season: $0.season,
                         episode: $0.episode, isNew: $0.isNew,
                         isLiveBroadcast: $0.isLiveBroadcast,
                         isPremiere: $0.isPremiere, isFinale: $0.isFinale,
                         isRepeat: $0.isRepeat)
            }
    }

    /// Catch-up: resolve an aired programme and present the player,
    /// silencing any live session first (recordings-pattern teardown).
    private func watchCatchup(_ entry: EPGEntry) {
        guard let server = ChannelStore.shared.activeServer,
              let start = entry.startTime, let end = entry.endTime else { return }
        Task { @MainActor in
            do {
                let pb = try await CatchupSupport.resolve(
                    server: server,
                    channel: item,
                    programTitle: entry.title,
                    programStart: start,
                    programEnd: end
                )
                #if os(tvOS)
                // Unified pipeline (task #147): catch-up plays in the
                // SAME container/chrome as live via a session mode
                // switch - no separate cover, no second player UI.
                PlayerSession.shared.beginCatchup(pb)
                #else
                PlayerSession.shared.exit()
                playingCatchup = pb
                #endif
            } catch {
                catchupErrorMessage = error.localizedDescription
            }
        }
    }

    private var futurePrograms: [EPGEntry] {
        let now = Date()
        let fromGuideStore = guideStore.programs[item.id] ?? []
        if !fromGuideStore.isEmpty {
            // v1.6.10: filter only by `end > now` so the currently-
            // airing program (start ≤ now < end) is included at the
            // top of the expanded list. Previously also required
            // `start > now`, which silently dropped the in-progress
            // show — users would expand a row at 12:47 PM and see
            // the first entry start at 2:00 PM, with no indication
            // of what was actually airing right now.
            return fromGuideStore
                .filter { $0.end > now }
                .sorted { $0.start < $1.start }
                .map {
                    // v1.7.x: thread `programID` so the resulting
                    // ProgramInfoTarget can lazy-load `<category>`
                    // via /api/epg/programs/<id>/ when the modal
                    // opens with an empty category — the bulk grid
                    // strips category data, so non-now-airing
                    // programs land here with category: "".
                    EPGEntry(title: $0.title, description: $0.description,
                             startTime: $0.start, endTime: $0.end,
                             category: $0.category, programID: $0.programID,
                             subTitle: $0.subTitle, season: $0.season,
                             episode: $0.episode, isNew: $0.isNew,
                             isLiveBroadcast: $0.isLiveBroadcast,
                             isPremiere: $0.isPremiere, isFinale: $0.isFinale,
                             isRepeat: $0.isRepeat)
                }
        }
        return upcomingPrograms.filter { entry in
            guard let end = entry.endTime else { return true }
            // Same fix on the legacy `fetchUpcoming` fallback path
            // (Xtream short-EPG, cold-launch pre-XMLTV). Drop only
            // programs that have already ended.
            return end > now
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
                                category: entry.category,
                                programID: entry.programID,
                                subTitle: entry.subTitle,
                                season: entry.season,
                                episode: entry.episode,
                                isNew: entry.isNew,
                                isLiveBroadcast: entry.isLiveBroadcast,
                                isPremiere: entry.isPremiere,
                                isFinale: entry.isFinale,
                                isRepeat: entry.isRepeat
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

    /// One aired programme row inside the "Previously aired" disclosure.
    /// Replayable entries (inside the channel's archive window) carry the
    /// rewind badge and tap straight into catch-up playback; the rest are
    /// dimmed reference rows.
    @ViewBuilder
    private func airedEntryRow(_ entry: EPGEntry) -> some View {
        let replayable: Bool = {
            guard let start = entry.startTime, let end = entry.endTime else { return false }
            return item.canReplay(start: start, end: end)
        }()
        Button {
            if replayable { watchCatchup(entry) }
        } label: {
            HStack(spacing: 6) {
                if replayable {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(.accentPrimary)
                }
                Text(entry.title)
                    .font(.labelSmall)
                    .foregroundColor(replayable ? .textPrimary : .textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let start = entry.startTime, let end = entry.endTime {
                    HStack(spacing: 3) {
                        Text(start, style: .time)
                        Text("-")
                        Text(end, style: .time)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!replayable)
    }

    @ViewBuilder
    private var guidePanel: some View {
        Divider()
            .background(Color.borderSubtle)
            .padding(.horizontal, 14)

        // Catch-up: retained history, collapsed by default so the panel
        // still lands on the upcoming schedule. Replayable entries tap
        // straight into playback; older-than-retention entries (or
        // channels with no archive) render as plain reference rows.
        // DisclosureGroup is unavailable on tvOS, so this is a manual
        // expander that renders identically on both platforms.
        if !airedPrograms.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAiredPrograms.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                        Text("Previously aired")
                            .font(.labelSmall)
                        Image(systemName: showAiredPrograms ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.textTertiary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAiredPrograms {
                    ForEach(airedPrograms) { entry in
                        airedEntryRow(entry)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .fullScreenCover(item: $playingCatchup) { pb in
                PlayerView(
                    urls: [pb.url],
                    title: pb.title,
                    headers: pb.headers,
                    isLive: false,
                    isDVR: false,
                    catchup: pb
                )
            }
            .alert("Catch-up Unavailable",
                   isPresented: Binding(
                        get: { catchupErrorMessage != nil },
                        set: { if !$0 { catchupErrorMessage = nil } })) {
                Button("OK", role: .cancel) { catchupErrorMessage = nil }
            } message: {
                Text(catchupErrorMessage ?? "")
            }
        }

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
                                    category: entry.category,
                                    programID: entry.programID,
                                    subTitle: entry.subTitle,
                                    season: entry.season,
                                    episode: entry.episode,
                                    isNew: entry.isNew,
                                    isLiveBroadcast: entry.isLiveBroadcast,
                                    isPremiere: entry.isPremiere,
                                    isFinale: entry.isFinale,
                                    isRepeat: entry.isRepeat
                                )
                            )
                        }
                        if let end = entry.endTime, end > Date() {
                            let isLive = (entry.startTime ?? Date()) <= Date()
                            // v1.7.x: a future program can only be
                            // recorded on the Dispatcharr server
                            // (IsAdmin-only). Hide Record for future
                            // programs when the active account isn't an
                            // admin (it would 403, with no local
                            // fallback for a future recording). Live
                            // recordings keep the button; the sheet
                            // falls back to local for any account.
                            let canOfferRecord = isLive
                                || (ChannelStore.shared.activeServer?.dispatcharrCanRecordToServer ?? true)
                            if canOfferRecord {
                                Button(isLive ? "Record from Now" : "Record") {
                                    activeSheet = .record(entry)
                                }
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

    /// Feed badges + season/episode line for an expanded-schedule row.
    /// Renders nothing when the program carries neither.
    @ViewBuilder
    private func epgEntryMetaRow(_ entry: EPGEntry) -> some View {
        let seLabel = seasonEpisodeLabel(season: entry.season, episode: entry.episode)
        let flags = epgFlagBadges(isLiveBroadcast: entry.isLiveBroadcast,
                                  isNew: entry.isNew, isPremiere: entry.isPremiere,
                                  isFinale: entry.isFinale, isRepeat: entry.isRepeat)
        if showEpgBadges, seLabel != nil || !flags.isEmpty {
            HStack(spacing: 6) {
                SeasonEpisodePill(label: seLabel, compact: true)
                EPGFlagsRow(flags: flags, compact: true)
            }
            .padding(.top, 1)
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
                    epgEntryMetaRow(entry)
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
                        message: "Tap the star on a channel in the guide, or a channel's actions button in the list, to add it here."
                    )
                } else {
                    List {
                        // Keyed by the unique stream URL (see rowKey) so two
                        // favorited channels sharing a tvg-id stay distinct rows.
                        ForEach(favoritesStore.favoriteItems, id: \.rowKey) { item in
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
            // #45: Favorites is not a collection view — clear the active
            // collection so the channel long-press menu offers "Remove from
            // All Collections" here rather than a stale "Remove from <name>".
            .onAppear { ChannelCollectionsStore.shared.activeFilterCollectionID = nil }
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
        // "Play Channels In: Mini Player" (Remote Control settings, tvOS-only,
        // default off; Android #226 twin, AerioTV-Android 8cfddab). First
        // Select on a browse tune mounts the session ALREADY minimized (the
        // old begin-fullscreen-then-minimize-400ms flow flashed the full
        // player over the guide). A second Select on the channel already
        // playing in the corner promotes it to fullscreen instead of
        // re-tuning the same stream. Resume / deep-link / cast paths don't
        // route through here, so they stay fullscreen.
        #if os(tvOS)
        if RemoteControlStore.shared.tuneInMini {
            if nowPlaying.isMinimized, nowPlaying.playingItem?.id == item.id {
                nowPlaying.expand()
                return
            }
            nowPlaying.requestStartMinimized()
        }
        #endif
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

struct TVGroupPillButtonStyle: ButtonStyle {
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

/// #45: a collection filter pill that supports BOTH tap (filter) and a
/// reliable long-press (manage). TVGroupPill is a Button, and a Button's
/// long-press on tvOS fires on release; so this renders the pill visual as a
/// plain (non-focusable) view styled to match TVGroupPillButtonStyle and lets
/// a TVPressOverlay own focus + dispatch tap vs long-press.
private struct CollectionPillTV: View {
    let name: String
    let isSelected: Bool
    var canFocus: Bool = true
    let onTap: () -> Void
    let onLongPress: () -> Void
    @State private var isFocused = false

    var body: some View {
        Text(name)
            .font(.system(size: 22, weight: .medium))
            .foregroundColor(isSelected ? .appBackground : (isFocused ? .white : .textSecondary))
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(
                Capsule().fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
            )
            .overlay(
                Capsule().stroke(isFocused && !isSelected ? Color.accentPrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .opacity(isFocused ? 1.0 : (isSelected ? 1.0 : 0.85))
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .overlay(
                TVPressOverlay(
                    minimumPressDuration: 0.5,
                    isFocused: $isFocused,
                    canFocus: canFocus,
                    onTap: onTap,
                    onLongPress: onLongPress
                )
            )
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

/// v1.6.23 — auth-aware logo fetcher. Dispatcharr-API channel logos
/// live behind `/api/channels/logos/<id>/cache/`, which requires the
/// server's `X-API-Key` (or `Authorization: ApiKey ...` / `Bearer`
/// per the per-server auth mode added in v1.6.20). The previous
/// implementation used a bare `URLSession.shared.data(from: url)`
/// with no headers, so every Dispatcharr-API logo fetch returned
/// 401/403, the image bytes were unparseable, and every channel
/// rendered the placeholder icon (jexhammer + Archie iPad sim repro,
/// v1.6.23 reports). The fix: detect URLs that match the active
/// server's host and inject `server.authHeaders`. Public CDN URLs
/// (TMDB, EPG-side logos baked into the M3U) don't match the host
/// and pass through unauthenticated, preserving today's behaviour.
enum LogoFetcher {
    /// Returns the auth headers to apply when fetching `url`, or
    /// `nil` when no server matches (CDN passthrough).
    @MainActor
    static func headers(for url: URL) -> [String: String]? {
        guard let host = url.host?.lowercased() else { return nil }
        guard let server = ChannelStore.shared.activeServer else { return nil }
        let candidates = [server.effectiveBaseURL, server.normalizedBaseURL, server.normalizedLocalURL]
        for raw in candidates {
            guard let candidateHost = URL(string: raw)?.host?.lowercased() else { continue }
            if candidateHost == host { return server.authHeaders }
        }
        return nil
    }

    /// SSRF gate for logo fetches. Channel logos come from untrusted feed
    /// data (M3U `tvg-logo`, Xtream `stream_icon`, Dispatcharr logo JSON),
    /// so a malicious playlist could point them at `127.0.0.1`, link-local
    /// `169.254.x`, or a LAN IP to probe the user's network. Allow the
    /// active server's own host(s) (LAN or WAN, the trust boundary) and
    /// otherwise defer to `VODService.validateAbsoluteURL` with no server
    /// host, which permits public hosts but rejects loopback / link-local
    /// / RFC-1918 targets. Mirrors the gate VOD posters already use.
    @MainActor
    static func isAllowedTarget(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let server = ChannelStore.shared.activeServer {
            let candidates = [server.effectiveBaseURL, server.normalizedBaseURL, server.normalizedLocalURL]
            for raw in candidates {
                if let candidateHost = URL(string: raw)?.host?.lowercased(), candidateHost == host {
                    return true
                }
            }
        }
        return VODService.validateAbsoluteURL(url, serverHost: nil) != nil
    }

    /// Fetch logo bytes with the right auth headers (if any).
    ///
    /// Uses `HTTPRouter` (not bare URLSession) so plain-HTTP servers
    /// like jexhammer's `http://dispatcharr.goip.de:59192` (which
    /// URLSession refuses with -1022 ATS) fall back to `NWHTTPClient`
    /// just like every other API call. Without that fallback, logos
    /// 404 silently for any user whose Dispatcharr lives on a
    /// non-IP-literal HTTP host (HSTS-preloaded TLDs, custom domains
    /// without TLS).
    static func fetch(_ url: URL) async throws -> Data {
        let (allowed, headers) = await MainActor.run {
            (Self.isAllowedTarget(url), Self.headers(for: url))
        }
        // Reject SSRF targets (loopback / link-local / non-server LAN IPs).
        // CachedLogoImage's catch shows the placeholder, same as any fetch
        // failure.
        guard allowed else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        let (data, _) = try await HTTPRouter.data(for: request)
        return data
    }
}

/// Drop-in replacement for AsyncImage that caches logos in memory.
struct CachedLogoImage: View {
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
                let data = try await LogoFetcher.fetch(url)
                // GH #61: decode accepts SVG logos in addition to bitmaps.
                if let img = AerioImageDecoding.decode(data) {
                    LogoCache.shared.store(img, for: key)
                    uiImage = img
                }
            } catch {}
        }
    }
}

/// v1.6.13.x: Captures the absolute Y of a view's frame top
/// (`proxy.frame(in: .global).minY`) from a `GeometryReader`
/// placed in a `.background` so the chip-row's mini-player
/// push-down inset can be computed dynamically (no per-device
/// hard-coded padding). The reduce keeps the latest value rather
/// than summing siblings — only one reader is in play at a time
/// within any given branch of the body.
///
/// We capture the absolute frame Y rather than `safeAreaInsets.top`
/// because the chip-row VStack lives inside a NavigationStack
/// content area — `safeAreaInsets.top` returns 0 in that context
/// (the chrome is consumed by the NavigationStack itself), but
/// the absolute frame Y correctly reports the screen-space
/// position to compare against the mini's `.ignoresSafeArea()`-
/// rooted bottom edge.
private struct NaturalTopPreference: PreferenceKey {
    // `static let` (not `var`) so Swift 6 strict-concurrency
    // doesn't flag the protocol-required `defaultValue` requirement
    // as nonisolated mutable shared state. The protocol asks for a
    // gettable property; an immutable `let` satisfies it.
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#if os(iOS)
/// v1.6.13.x: Per-idiom `.searchable` modifier so iPad gets the
/// new button-revealed drawer (`isPresented:` binding) while iPhone
/// keeps the classic always-visible drawer (no binding) — the
/// system needs the binding form to programmatically hide the
/// drawer, but iPhone's pull-down-to-reveal idiom doesn't apply
/// when a binding is present, so the two surfaces use distinct
/// modifier overloads.
private struct PerIdiomSearchableModifier: ViewModifier {
    @Binding var text: String
    let iPhoneDisplayMode: SearchFieldPlacement.NavigationBarDrawerDisplayMode

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // No-op on iPad — search is handled inline in the chip
            // row via a magnifier button + TextField, which gives
            // us a clean show/hide that the system's `.searchable`
            // placement wouldn't honor.
            content
        } else {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: iPhoneDisplayMode),
                prompt: "Search channels"
            )
        }
    }
}
#endif
