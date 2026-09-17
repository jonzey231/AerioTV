import SwiftUI
import SwiftData

struct SettingsView: View {
    #if os(tvOS)
    @Binding var selectedTab: AppTab
    /// Mirrors "is a Settings subview currently pushed" up to
    /// MainTabView so its outer `.onExitCommand` handler knows when
    /// to request a pop (`popRequested`) vs. when to fall through to
    /// its default behaviour (switch to Live TV).
    @Binding var isSubviewPushed: Bool
    /// MainTabView flips this to `true` on a Menu press while a
    /// Settings subview is pushed. We watch it via `.onChange` and
    /// pop the innermost level, then reset the binding.
    @Binding var popRequested: Bool
    #endif
    /// Observes ThemeManager so SettingsView's body re-evaluates on
    /// every `selectedTheme` / `useCustomAccent` / `customAccentHex`
    /// change. Without this, child rows that pass `iconColor: .accentPrimary`
    /// (a computed property that reads `ThemeManager.shared.accent`)
    /// keep the old Color value because SettingsView never invalidates
    /// — the rows are reconstructed only when SettingsView itself
    /// re-renders. v1.6.8 user report: switching themes left
    /// stale-coloured icons on App Settings + iCloud rows. Adding
    /// the observer fixes the cascade by forcing re-render on every
    /// theme mutation.
    @ObservedObject private var theme = ThemeManager.shared
    // v1.6.17: explicit sort order for the Playlists list. `sortOrder`
    // existed since the original model and rides iCloud sync (see
    // SyncManager line 795), but until now the @Query returned
    // SwiftData's insertion order — leaving the user with no way to
    // reorder. With the sort applied here, drag-to-reorder on iOS/iPad
    // and up/down arrows on tvOS write into `sortOrder` and the list
    // re-renders immediately. Tiebreaker on `createdAt` keeps legacy
    // servers (all `sortOrder == 0`) deterministic by add date.
    @Query(sort: [
        SortDescriptor(\ServerConnection.sortOrder, order: .forward),
        SortDescriptor(\ServerConnection.createdAt, order: .forward)
    ])
    private var servers: [ServerConnection]
    @Environment(\.modelContext) private var modelContext
    @State private var showAddServer = false
    @State private var serverToDelete: ServerConnection? = nil
    @State private var serverToEdit: ServerConnection? = nil
    @State private var showDeleteAlert = false
    /// Read-only here: the Sync row's value on the Settings root. The
    /// toggle itself lives on SyncSettingsView.
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    #if os(tvOS)
    @State private var navPath = NavigationPath()
    /// Tracks classic-`NavigationLink` pushes that bypass `navPath`
    /// (ServerDetailView, MyRecordingsView). Combined with `navPath`
    /// to compute `isSubviewPushed`.
    @StateObject private var dismissStack = SettingsDismissStack()
    #endif

    #if os(iOS)
    // Phase 4 (plan A2): iPad split-view state. Optional so a cleared
    // selection falls back to Playlists.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var padSelection: SettingsRoute? = .category(.playlists)
    #endif

    var body: some View {
        // Menu-button routing on tvOS:
        //
        // MainTabView's `.onExitCommand { handleMenuPress() }` on the
        // outer TabView intercepts every Menu press before the inner
        // NavigationStack — or any per-destination `.onExitCommand` —
        // can react. (Same constraint that drives the VOD
        // `isVODDetailPushed` pattern.) So we don't attach a handler
        // here; we let MainTabView detect the pushed state and drive
        // pops explicitly.
        //
        // Coordination:
        //   • `isSubviewPushed` (binding up to MainTabView) mirrors
        //     `navPath.count > 0 || dismissStack.depth > 0`.
        //   • MainTabView's `handleMenuPress()` sees `isSubviewPushed`
        //     and flips `popRequested` instead of switching tabs.
        //   • The `.onChange(of: popRequested)` in
        //     `settingsNavigationStack` pops the innermost level —
        //     classic dismiss stack first, then navPath — and resets
        //     the flag. Repeated Menu presses peel levels off one at
        //     a time until we're back at the Settings root, at which
        //     point MainTabView's fallthrough switches to Live TV.
        //
        // See also `SettingsDismissStack` and
        // `trackedAsClassicSettingsChild()` at the bottom of this file
        // for how classic-`NavigationLink(destination:)` pushes
        // (ServerDetailView, DVR → MyRecordingsView) opt into the
        // same pop mechanism despite bypassing `navPath`.
        settingsNavigationStack
    }

    @ViewBuilder
    private var settingsNavigationStack: some View {
        #if os(tvOS)
        NavigationStack(path: $navPath) { settingsContent }
            // Expose the dismiss stack to any classic-pushed destination
            // that opts in via `.trackedAsClassicSettingsChild()`.
            .environmentObject(dismissStack)
            // Mirror "is any subview pushed" up to MainTabView. Both
            // sources update independently: navPath via SwiftUI state
            // change, dismissStack.depth via its own @Published.
            .onChange(of: navPath.count) { _, _ in
                syncIsSubviewPushed()
            }
            .onChange(of: tvFocusInDetail) { _, _ in
                syncIsSubviewPushed()
            }
            .onReceive(dismissStack.$depth) { _ in
                syncIsSubviewPushed()
            }
            // MainTabView's Menu handler flips `popRequested` true
            // when a Settings subview is pushed. Pop the innermost
            // level — classic stack first (LIFO), then navPath.
            .onChange(of: popRequested) { _, requested in
                guard requested else { return }
                performOnePop()
                popRequested = false
            }
        #else
        // Phase 4 (plan A2): explicit idiom fork rather than trusting
        // NavigationSplitView's collapse heuristics, so the iPhone view
        // tree stays byte-identical.
        if UIDevice.current.userInterfaceIdiom == .pad && hSizeClass == .regular {
            padSplitRoot
        } else {
            NavigationStack { settingsContent }
        }
        #endif
    }

    #if os(tvOS)
    /// Computes `isSubviewPushed` from both navPath and the classic
    /// dismiss stack and writes it through the binding only when the
    /// value actually changes (avoids invalidating MainTabView on
    /// every navPath mutation of the same emptiness).
    private func syncIsSubviewPushed() {
        // Phase 3: focus sitting in the detail pane counts as "pushed" so
        // MainTabView routes Menu here; performOnePop then returns focus to
        // the rail instead of popping navigation. The Menu-swallow contract
        // with MainTabView is preserved, not replaced (plan A3).
        let pushed = !navPath.isEmpty || dismissStack.depth > 0 || tvFocusInDetail
        if isSubviewPushed != pushed {
            isSubviewPushed = pushed
        }
    }

    /// Pops one level. Classic stack takes priority so nested
    /// scenarios (DVR navPath → MyRecordings classic) peel off the
    /// innermost view first, matching user expectation.
    private func performOnePop() {
        if dismissStack.depth > 0 {
            dismissStack.popTop()
        } else if !navPath.isEmpty {
            navPath.removeLast()
        } else if tvFocusInDetail {
            // Nothing pushed: Menu in the detail pane returns focus to the
            // rail. Menu in the rail keeps falling through to MainTabView's
            // default (exit toward the tab bar).
            railReturnToken += 1
        }
    }
    #endif

    @ViewBuilder
    private var settingsContent: some View {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                #if os(tvOS)
                tvSplitRoot
                #else
                List {
                    // MARK: - Playlists Section
                    Section {
                        if servers.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "list.and.film")
                                        .scaledFont(.system(size: 28))
                                        .foregroundColor(Color.contrastText(.textTertiary))
                                    Text("No playlists added")
                                        .scaledFont(.bodyMedium.subtext())
                                        .foregroundColor(Color.contrastText(.textTertiary))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 20)
                            .listRowBackground(Color.cardBackground)
                        } else {
                            ForEach(servers) { server in
                                NavigationLink(destination: ServerDetailView(server: server)) {
                                    ServerListRow(server: server,
                                                  onSetActive: servers.count > 1 ? { setActiveServer(server) } : nil)
                                }
                                #if os(iOS)
                                .buttonStyle(PressableButtonStyle())
                                #endif
                                .listRowBackground(Color.cardBackground)
                                .contextMenu {
                                    Button { serverToEdit = server } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        serverToDelete = server
                                        showDeleteAlert = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            #if os(iOS)
                            // v1.6.17 — drag-to-reorder for iOS/iPadOS.
                            // Wired into `moveServers` which renumbers
                            // every visible server's `sortOrder` so the
                            // result rides iCloud sync as a single push.
                            .onMove(perform: moveServers)
                            #endif
                        }

                        Button {
                            showAddServer = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .scaledFont(.system(size: 20))
                                    .foregroundStyle(LinearGradient.accentGradient)
                                Text("Add Playlist")
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(Color.contrastText(.accentPrimary))
                            }
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        .listRowBackground(Color.cardBackground)

                    } header: {
                        Text("Playlists")
                            .sectionHeaderStyle()
                    } footer: {
                        if !servers.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Tap ○ to set the active playlist", systemImage: "checkmark.circle")
                                    #if os(tvOS)
                                    .scaledFont(.system(size: 20, weight: .regular).subtext())
                                    .foregroundColor(Color.contrastText(.textSecondary))
                                    #else
                                    .scaledFont(.labelSmall.subtext())
                                    .foregroundColor(Color.contrastText(.textTertiary))
                                    #endif
                                Label("Long press to edit or delete", systemImage: "hand.tap")
                                    #if os(tvOS)
                                    .scaledFont(.system(size: 20, weight: .regular).subtext())
                                    .foregroundColor(Color.contrastText(.textSecondary))
                                    #else
                                    .scaledFont(.labelSmall.subtext())
                                    .foregroundColor(Color.contrastText(.textTertiary))
                                    #endif
                                if servers.count > 1 {
                                    #if os(iOS)
                                    Label("Tap Edit to reorder", systemImage: "arrow.up.arrow.down")
                                        .scaledFont(.labelSmall.subtext())
                                        .foregroundColor(Color.contrastText(.textTertiary))
                                    #else
                                    Label("Use ▲ ▼ to reorder", systemImage: "arrow.up.arrow.down")
                                        .scaledFont(.system(size: 20, weight: .regular).subtext())
                                        .foregroundColor(Color.contrastText(.textSecondary))
                                    #endif
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif

                    // MARK: - App
                    Section {
                        NavigationLink(destination: LiveTVSettingsView()) {
                            SettingsRow(icon: "tv.fill", iconColor: .accentPrimary,
                                        title: "Live TV", subtitle: "Guide, groups, badges, colors")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: PlayerSettingsView()) {
                            SettingsRow(icon: "play.rectangle.fill", iconColor: .accentPrimary,
                                        title: "Player", subtitle: "Info card, rewind, gestures, multiview")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: MoviesTVSettingsView()) {
                            SettingsRow(icon: "film.fill", iconColor: .accentPrimary,
                                        title: "Movies & TV Shows", subtitle: "Library refresh, posters")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: DVRSettingsView()) {
                            SettingsRow(icon: "record.circle", iconColor: .red,
                                        title: "DVR", subtitle: "Recordings, buffers, storage")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                    } header: {
                        Text("App")
                            .sectionHeaderStyle()
                    }
                    .listRowBackground(Color.cardBackground)
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif

                    // MARK: - Device
                    Section {
                        NavigationLink(destination: AppearanceSettingsView()) {
                            SettingsRow(icon: "paintbrush.fill", iconColor: .accentPrimary,
                                        title: "Appearance", subtitle: "Theme, text size, time format")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: GeneralSettingsView()) {
                            SettingsRow(icon: "switch.2", iconColor: .accentPrimary,
                                        title: "General", subtitle: "Startup, refresh, network")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: SyncSettingsView()) {
                            SettingsRow(icon: "icloud.fill", iconColor: .accentPrimary,
                                        title: "Sync", subtitle: syncValueLabel)
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                    } header: {
                        Text("Device")
                            .sectionHeaderStyle()
                    }
                    .listRowBackground(Color.cardBackground)
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif

                    // MARK: - Developer & About
                    Section {
                        NavigationLink(destination: DeveloperSettingsView()) {
                            SettingsRow(icon: "ladybug.fill", iconColor: .accentSecondary,
                                        title: "Developer",
                                        subtitle: "Debug logging & diagnostics")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: AboutSettingsView()) {
                            SettingsRow(icon: "info.circle.fill", iconColor: .accentPrimary,
                                        title: "About", subtitle: AboutInfo.version)
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                    }
                    .listRowBackground(Color.cardBackground)
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                // v1.6.8 fix: SwiftUI's List on Mac Catalyst (and to a
                // lesser extent iPad) caches cell content rendering at
                // the UIKit (UITableView) layer. When the theme
                // changes, parent view body re-evaluation isn't enough
                // to force every cell — particularly section headers,
                // footers, and `SettingsRow` subtitle text — to pick
                // up the new accent-derived `Color.textSecondary` /
                // `.textTertiary`. Keying the List's identity on the
                // active theme name forces a full teardown + rebuild
                // on theme switches, guaranteeing every cell renders
                // with the new palette. Trade-off is scroll position
                // resets to top, which is acceptable for Settings.
                .id("settings-list-\(theme.selectedTheme.rawValue)-\(theme.useCustomAccent ? theme.customAccentHex : "preset")")
                #endif
            }
            #if os(iOS)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            // v1.6.17 — drag-to-reorder for the Playlists list. The
            // EditButton toggles List editMode; while active the user
            // gets reorder handles on every server row. NavigationLinks
            // are intentionally disabled by SwiftUI in edit mode (the
            // user taps "Done" first to navigate). Only surfaces with
            // 2+ servers since reordering one item is meaningless.
            .toolbar {
                if servers.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                            .tint(theme.accent)
                    }
                }
            }
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            #if os(tvOS)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .category(.liveTV):         LiveTVSettingsView()
                case .category(.player):         PlayerSettingsView()
                case .category(.moviesTV):       MoviesTVSettingsView()
                case .category(.dvr):            DVRSettingsView()
                case .category(.appearance):     AppearanceSettingsView()
                case .category(.general):        GeneralSettingsView()
                case .category(.remoteControl):  RemoteControlSettingsView()
                case .category(.sync):           SyncSettingsView()
                case .category(.syncCategories): SyncCategoriesSettingsView()
                case .category(.developer):      DeveloperSettingsView()
                case .category(.about):          AboutSettingsView()
                // Pane host; nothing pushes this.
                case .category(.playlists):
                    EmptyView()
                case .editServer(let id):
                    // The route carries the server id, so editing the SAME
                    // server twice in a row just pushes a fresh route value.
                    if let server = servers.first(where: { $0.id == id }) {
                        EditServerPage(server: server)
                    }
                case .server, .myRecordings:
                    // Rail/sidebar targets; ServerDetailView and
                    // MyRecordingsView remain classic pushes today.
                    EmptyView()
                }
            }
            #endif
            .sheet(isPresented: $showAddServer) {
                NavigationStack { AddServerView(onSave: { _ in }) }
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .frame(width: 36, height: 5)
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
            }
            .alert("Delete Playlist?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let server = serverToDelete {
                        performServerCascadeDelete(server, servers: Array(servers), modelContext: modelContext)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \"\(serverToDelete?.name ?? "this playlist")\" from the app. Your server data will not be affected.")
            }
            #if !os(tvOS)
            .sheet(item: $serverToEdit) { server in
                EditServerSheet(server: server)
            }
            #endif
    }

    // MARK: - Root row values

    /// The Sync row's value: the whole page is behind one row now, so the
    /// root still says whether iCloud Sync is on.
    private var syncValueLabel: String { iCloudSyncEnabled ? "On" : "Off" }

    // MARK: - Active Server

    private func setActiveServer(_ server: ServerConnection) {
        // Delegates to the shared routine (ServerDetailView.swift) so the
        // root activation and the detail page's Set Active row stay in
        // lockstep (GH #22 stop-old-source behavior included).
        performSetActiveServer(server, servers: Array(servers), modelContext: modelContext)
    }

    // MARK: - Reorder helpers (v1.6.17)

    /// iOS/iPadOS drag-to-reorder hook. Renumbers every server's
    /// `sortOrder` to match the new visual order and pushes the
    /// updated list to iCloud as a single batch.
    private func moveServers(from source: IndexSet, to destination: Int) {
        var working = Array(servers)
        working.move(fromOffsets: source, toOffset: destination)
        renumberAndPersist(working)
    }

    /// tvOS up/down button hook. Moves the server at `index` by
    /// `delta` positions (-1 = up, +1 = down) and persists.
    private func moveServer(from index: Int, by delta: Int) {
        let target = index + delta
        guard target >= 0, target < servers.count, target != index else { return }
        var working = Array(servers)
        let item = working.remove(at: index)
        working.insert(item, at: target)
        renumberAndPersist(working)
    }

    /// Walks the new visual order and writes monotonic `sortOrder`
    /// values (10, 20, 30, …) so future inserts have room to slot
    /// in between without renumbering everyone. Saves SwiftData and
    /// pushes the updated list to iCloud.
    private func renumberAndPersist(_ ordered: [ServerConnection]) {
        for (i, server) in ordered.enumerated() {
            let newOrder = (i + 1) * 10
            if server.sortOrder != newOrder {
                server.sortOrder = newOrder
            }
        }
        try? modelContext.save()
        SyncManager.shared.pushServers(ordered)
    }

    // MARK: - iPad split root (Phase 4, plan A2)

    #if os(iOS)
    private var padSplitRoot: some View {
        // Hand-rolled split (plan A2 risk R4 fallback): NavigationSplitView
        // on the iOS 27 SDK proposes the SCREEN width to its detail column
        // inside a TabView, so List-backed panes overflowed the column and
        // clipped at the right edge (verified on the iPad Pro; a frame cap
        // and spacer centering both failed the same way). The HStack gives
        // the detail column its true width, like the tvOS rail.
        HStack(spacing: 0) {
            padSidebar
                .frame(width: 340)
            NavigationStack {
                padDetail(for: padSelection ?? .category(.playlists))
                    .background(Color.appBackground.ignoresSafeArea())
            }
            // Rekey the stack on selection change so pages pushed from a
            // pane (playlist detail, Sync Categories) pop when the user
            // picks another sidebar item; otherwise the push stays on top
            // of the swapped pane (observed on device).
            .id(padSelection)
        }
        .background(Color.appBackground.ignoresSafeArea())
        // Presentations duplicated from the iPhone chain (only one idiom
        // branch is mounted, so they never double-present).
        .sheet(isPresented: $showAddServer) {
            NavigationStack { AddServerView(onSave: { _ in }) }
        }
        .sheet(item: $serverToEdit) { server in
            EditServerSheet(server: server)
        }
        .alert("Delete Playlist?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let server = serverToDelete {
                    performServerCascadeDelete(server, servers: Array(servers), modelContext: modelContext)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(serverToDelete?.name ?? "this playlist")\" from the app. Your server data will not be affected.")
        }
    }

    /// Sidebar: Playlists as an ordinary item (matching the tvOS rail
    /// ruling of 2026-08-04 and Android tablet, superseding the Rev 2
    /// embed-playlist-rows design), then the categories in the frozen
    /// order. Remote Control stays tvOS-only.
    /// One sidebar row: the selectionContrast flag flips the row to
    /// white-on-accent while it sits on the selection pill (Logan's
    /// feedback 2026-08-04: the accent-tinted subtitle was unreadable
    /// on the accent fill).
    private func padSidebarRow(_ dest: SettingsDestination, icon: String,
                               iconColor: Color, title: String,
                               subtitle: String?) -> some View {
        let selected = padSelection == .category(dest)
        return Button {
            padSelection = .category(dest)
        } label: {
            SettingsRow(icon: icon, iconColor: iconColor,
                        title: title, subtitle: subtitle,
                        selectionContrast: selected)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? theme.accent : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var padSidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .scaledFont(.title2.weight(.bold))
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)

                padSidebarRow(.playlists, icon: "rectangle.stack.fill", iconColor: .accentPrimary,
                              title: "Playlists",
                              subtitle: servers.first(where: { $0.isActive })?.name)

                Text("App")
                    .scaledFont(.title3.weight(.semibold))
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                padSidebarRow(.liveTV, icon: "tv.fill", iconColor: .accentPrimary,
                              title: "Live TV", subtitle: "Guide, groups, badges, colors")
                padSidebarRow(.player, icon: "play.rectangle.fill", iconColor: .accentPrimary,
                              title: "Player", subtitle: "Info card, rewind, gestures, multiview")
                padSidebarRow(.moviesTV, icon: "film.fill", iconColor: .accentPrimary,
                              title: "Movies & TV Shows", subtitle: "Library refresh, posters")
                padSidebarRow(.dvr, icon: "record.circle", iconColor: .red,
                              title: "DVR", subtitle: "Recordings, buffers, storage")

                Text("Device")
                    .scaledFont(.title3.weight(.semibold))
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                padSidebarRow(.appearance, icon: "paintbrush.fill", iconColor: .accentPrimary,
                              title: "Appearance", subtitle: "Theme, text size, time format")
                padSidebarRow(.general, icon: "switch.2", iconColor: .accentPrimary,
                              title: "General", subtitle: "Startup, refresh, network")
                padSidebarRow(.sync, icon: "icloud.fill", iconColor: .accentPrimary,
                              title: "Sync", subtitle: syncValueLabel)

                Divider()
                    .background(Color.borderSubtle)
                    .padding(.vertical, 12)

                padSidebarRow(.developer, icon: "ladybug.fill", iconColor: .accentSecondary,
                              title: "Developer", subtitle: "Debug logging & diagnostics")
                padSidebarRow(.about, icon: "info.circle.fill", iconColor: .accentPrimary,
                              title: "About", subtitle: AboutInfo.version)
            }
            .padding(.horizontal, 12)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        // Logan's ruling 2026-08-04: no gray panel behind the sidebar.
        // Plain scrollable column on the app background, with a hairline
        // break at the trailing edge marking where the sidebar ends.
        .background(Color.appBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func padDetail(for route: SettingsRoute) -> some View {
        switch route {
        case .category(.playlists):      padPlaylistsPane
        case .category(.liveTV):         LiveTVSettingsView()
        case .category(.player):         PlayerSettingsView()
        case .category(.moviesTV):       MoviesTVSettingsView()
        case .category(.dvr):            DVRSettingsView()
        case .category(.appearance):     AppearanceSettingsView()
        case .category(.general):        GeneralSettingsView()
        case .category(.sync):           SyncSettingsView()
        case .category(.syncCategories): SyncCategoriesSettingsView()
        case .category(.developer):      DeveloperSettingsView()
        case .category(.about):          AboutSettingsView()
        case .server(let id):
            if let server = servers.first(where: { $0.id == id }) {
                ServerDetailView(server: server)
            } else {
                Color.appBackground
            }
        case .category(.remoteControl), .editServer, .myRecordings:
            // RemoteControlSettingsView is tvOS-only; the pushes never
            // target a pane.
            Color.appBackground
        }
    }

    /// Playlists pane: the iPhone root's playlist section as a detail
    /// page. Rows push ServerDetailView on the detail stack.
    private var padPlaylistsPane: some View {
        List {
            Section {
                if servers.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "list.and.film")
                                .scaledFont(.system(size: 28))
                                .foregroundColor(Color.contrastText(.textTertiary))
                            Text("No playlists added")
                                .scaledFont(.bodyMedium.subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 20)
                    .listRowBackground(Color.cardBackground)
                } else {
                    ForEach(servers) { server in
                        NavigationLink(destination: ServerDetailView(server: server)) {
                            ServerListRow(server: server,
                                          onSetActive: servers.count > 1 ? { setActiveServer(server) } : nil)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .listRowBackground(Color.cardBackground)
                        .contextMenu {
                            Button { serverToEdit = server } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                serverToDelete = server
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveServers)
                }

                Button {
                    showAddServer = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .scaledFont(.system(size: 20))
                            .foregroundStyle(LinearGradient.accentGradient)
                        Text("Add Playlist")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(Color.contrastText(.accentPrimary))
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .listRowBackground(Color.cardBackground)
            } footer: {
                if !servers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Tap ○ to set the active playlist", systemImage: "checkmark.circle")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                        Label("Long press to edit or delete", systemImage: "hand.tap")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                        if servers.count > 1 {
                            Label("Touch and hold, then drag to reorder", systemImage: "arrow.up.arrow.down")
                                .scaledFont(.labelSmall.subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        // No EditButton (Logan's ruling 2026-08-04): long-press covers
        // edit/delete via the context menu, and long-press drag reorders
        // directly through .onMove without edit mode.
    }

    #endif

    // MARK: - tvOS Settings Layout

    #if os(tvOS)
    // MARK: - Phase 3 two-pane root (rail + detail)

    /// Pane selection for the rail. Defaults to Appearance until onAppear
    /// promotes the first playlist (plan: the detail pane is never empty).
    @State private var tvSelection: SettingsRoute = .category(.playlists)
    /// True while focus is in the detail pane; drives the Menu semantics.
    @State private var tvFocusInDetail = false
    /// Incremented to order the split view to put focus back on the rail.
    @State private var railReturnToken = 0
    private var tvRailItems: [TVSettingsRailItem] {
        var items: [TVSettingsRailItem] = []
        // Playlists is an ordinary tab: its pane lists the playlists like
        // every other category (user ruling 2026-08-04, replacing the
        // short-lived in-rail disclosure group). The subtitle surfaces
        // the active playlist without entering the pane.
        items.append(TVSettingsRailItem(
            id: "playlists",
            route: .category(.playlists),
            label: "Playlists",
            icon: "rectangle.stack.fill",
            iconColor: .accentPrimary,
            subtitle: servers.first(where: { $0.isActive })?.name))
        items.append(TVSettingsRailItem(
            id: "live-tv", route: .category(.liveTV), label: "Live TV",
            icon: "tv.fill", iconColor: .accentPrimary, subtitle: "Guide, groups, badges, colors"))
        items.append(TVSettingsRailItem(
            id: "player", route: .category(.player), label: "Player",
            icon: "play.rectangle.fill", iconColor: .accentPrimary, subtitle: "Info card, rewind, gestures, multiview"))
        items.append(TVSettingsRailItem(
            id: "movies-tv", route: .category(.moviesTV), label: "Movies & TV Shows",
            icon: "film.fill", iconColor: .accentPrimary, subtitle: "Library refresh, posters"))
        items.append(TVSettingsRailItem(
            id: "dvr", route: .category(.dvr), label: "DVR",
            icon: "record.circle", iconColor: .red, subtitle: "Recordings, buffers, storage"))
        items.append(TVSettingsRailItem(
            id: "appearance", route: .category(.appearance), label: "Appearance",
            icon: "paintbrush.fill", iconColor: .accentPrimary, subtitle: "Theme, text size, time format"))
        items.append(TVSettingsRailItem(
            id: "general", route: .category(.general), label: "General",
            icon: "switch.2", iconColor: .accentPrimary, subtitle: "Startup, refresh, network"))
        // Remote Control (#195/#196): live now that the player executor,
        // overlays, and guide dispatch all run the map.
        items.append(TVSettingsRailItem(
            id: "remote-control", route: .category(.remoteControl), label: "Remote Control",
            icon: "av.remote", iconColor: .accentPrimary, subtitle: "Customize remote buttons"))
        items.append(TVSettingsRailItem(
            id: "sync", route: .category(.sync), label: "Sync",
            icon: "icloud.fill", iconColor: .accentPrimary, subtitle: syncValueLabel))
        items.append(TVSettingsRailItem(
            id: "developer", route: .category(.developer), label: "Developer",
            icon: "ladybug.fill", iconColor: .accentSecondary, subtitle: "Debug logging & diagnostics"))
        items.append(TVSettingsRailItem(
            id: "about", route: .category(.about), label: "About",
            icon: "info.circle.fill", iconColor: .accentPrimary, subtitle: AboutInfo.version))
        return items
    }

    private var tvSplitRoot: some View {
        TVSettingsSplitView(
            items: tvRailItems,
            selection: $tvSelection,
            focusInDetail: $tvFocusInDetail,
            railReturnToken: railReturnToken
        ) { route in
            tvDetailPane(for: route)
        }
    }

    @ViewBuilder
    private func tvDetailPane(for route: SettingsRoute) -> some View {
        switch route {
        case .server(let id):
            if let server = servers.first(where: { $0.id == id }) {
                ServerDetailView(server: server)
            } else {
                // Playlist was deleted out from under the selection.
                Color.appBackground
            }
        case .category(.playlists):      tvPlaylistsPane
        case .category(.liveTV):         LiveTVSettingsView()
        case .category(.player):         PlayerSettingsView()
        case .category(.moviesTV):       MoviesTVSettingsView()
        case .category(.dvr):            DVRSettingsView()
        case .category(.appearance):     AppearanceSettingsView()
        case .category(.general):        GeneralSettingsView()
        case .category(.remoteControl):  RemoteControlSettingsView()
        case .category(.sync):           SyncSettingsView()
        case .category(.syncCategories): SyncCategoriesSettingsView()
        case .category(.developer):      DeveloperSettingsView()
        case .category(.about):          AboutSettingsView()
        case .editServer, .myRecordings: Color.appBackground
        }
    }

    /// The Playlists pane: the legacy root's playlist section as a detail
    /// pane. Rows push ServerDetailView (classic push); the long-press
    /// context menu keeps switch/reorder/edit/delete.
    private var tvPlaylistsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if servers.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "list.and.film")
                                .scaledFont(.system(size: 36))
                                .foregroundColor(Color.contrastText(.textSecondary))
                            Text("No playlists added")
                                .scaledFont(.bodyMedium.subtext())
                                .foregroundColor(Color.contrastText(.textSecondary))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 28)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.cardBackground))
                } else {
                    ForEach(servers) { server in
                        TVSettingsNavRow(destination: ServerDetailView(server: server).trackedAsClassicSettingsChild()) {
                            ServerListRow(server: server,
                                          onSetActive: servers.count > 1 ? { setActiveServer(server) } : nil)
                        }
                        .contextMenu {
                            if servers.count > 1 {
                                Button {
                                    setActiveServer(server)
                                } label: {
                                    if server.isActive {
                                        Label("Active Playlist", systemImage: "checkmark.circle.fill")
                                    } else {
                                        Label("Use This Playlist", systemImage: "checkmark.circle")
                                    }
                                }
                                .disabled(server.isActive)

                                let idx = servers.firstIndex(where: { $0.id == server.id }) ?? 0
                                if idx > 0 {
                                    Button {
                                        moveServer(from: idx, by: -1)
                                    } label: {
                                        Label("Move Up", systemImage: "arrow.up")
                                    }
                                }
                                if idx < servers.count - 1 {
                                    Button {
                                        moveServer(from: idx, by: 1)
                                    } label: {
                                        Label("Move Down", systemImage: "arrow.down")
                                    }
                                }
                            }
                            Button { navPath.append(SettingsRoute.editServer(server.id)) } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                serverToDelete = server
                                showDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                TVSettingsActionRow(icon: "plus.circle.fill",
                                    label: "Add Playlist",
                                    isAccent: true) {
                    showAddServer = true
                }
                if !servers.isEmpty {
                    Label("Long press for options: switch playlist, edit, or delete", systemImage: "hand.tap")
                        .scaledFont(.system(size: 24, weight: .medium))
                        .foregroundColor(.textPrimary.opacity(0.7))
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
    }

    #endif
}

#if os(tvOS)
/// A URL surfaced on tvOS as a scannable QR (Android parity:
/// TvQrLinkDialog). Non-nil state presents the sheet.
#endif

// MARK: - tvOS Settings Row Components

#if os(tvOS)
/// NavigationLink wrapper that shows the teal-tinted card highlight on focus
/// instead of the system white row highlight.
/// NavigationLink row with teal card highlight on focus.
/// Uses .plain buttonStyle so the tvOS focus engine registers the link as focusable.
///
/// Internal (not private) so DVR / Developer / Appearance settings pages
/// can reuse the same focus treatment for uniform tvOS UI.
#endif  // Phase 1 split: closes a block that spanned the extraction cut
