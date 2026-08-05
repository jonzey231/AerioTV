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
    /// Drives the confirmation alert for the "Clear iCloud Data"
    /// destructive action in the iCloud Sync section.
    @State private var showClearICloudConfirm = false
    /// Optional confirmation toast shown after a successful Clear
    /// iCloud Data invocation. Auto-dismisses after a couple of
    /// seconds so the user gets feedback without an extra tap.
    @State private var clearICloudConfirmationVisible = false
    // Tracks whether the one-time swipe-hint peek has been shown.
    @State private var copiedAbout = false
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("syncLastDate") private var syncLastDate: Double = 0
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
                                        .font(.system(size: 28))
                                        .foregroundColor(.textTertiary)
                                    Text("No playlists added")
                                        .font(.bodyMedium)
                                        .foregroundColor(.textTertiary)
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
                                    .font(.system(size: 20))
                                    .foregroundStyle(LinearGradient.accentGradient)
                                Text("Add Playlist")
                                    .font(.bodyMedium)
                                    .foregroundColor(.accentPrimary)
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
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundColor(.textSecondary)
                                    #else
                                    .font(.labelSmall)
                                    .foregroundColor(.textTertiary)
                                    #endif
                                Label("Long press to edit or delete", systemImage: "hand.tap")
                                    #if os(tvOS)
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundColor(.textSecondary)
                                    #else
                                    .font(.labelSmall)
                                    .foregroundColor(.textTertiary)
                                    #endif
                                if servers.count > 1 {
                                    #if os(iOS)
                                    Label("Tap Edit to reorder", systemImage: "arrow.up.arrow.down")
                                        .font(.labelSmall)
                                        .foregroundColor(.textTertiary)
                                    #else
                                    Label("Use ▲ ▼ to reorder", systemImage: "arrow.up.arrow.down")
                                        .font(.system(size: 20, weight: .regular))
                                        .foregroundColor(.textSecondary)
                                    #endif
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif

                    Section {
                        NavigationLink(destination: AppearanceSettingsView()) {
                            SettingsRow(icon: "paintbrush.fill", iconColor: .accentPrimary,
                                        title: "Appearance", subtitle: "Theme, scale & category colors")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: AppBehaviorsSettingsView()) {
                            SettingsRow(icon: "switch.2", iconColor: .accentPrimary,
                                        title: "App Behaviors", subtitle: "Default tab, launch & gestures")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: MultiviewSettingsView()) {
                            SettingsRow(icon: "rectangle.split.2x2.fill", iconColor: .accentPrimary,
                                        title: "Multiview", subtitle: "Audio focus, tile spacing & corners")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: NetworkSettingsView()) {
                            SettingsRow(icon: "network", iconColor: .accentSecondary,
                                        title: "Network", subtitle: "Timeout, buffer & background refresh")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                    } header: {
                        Text("App Settings")
                            .sectionHeaderStyle()
                    }
                    .listRowBackground(Color.cardBackground)

                    // MARK: - iCloud Sync
                    Section {
                        Toggle(isOn: $iCloudSyncEnabled) {
                            SettingsRow(icon: "icloud.fill", iconColor: .accentPrimary,
                                        title: "iCloud Sync",
                                        subtitle: "Sync playlists, preferences, and watch progress")
                        }
                        .tint(ThemeManager.shared.accent)
                        .onChange(of: iCloudSyncEnabled) { _, enabled in
                            SyncManager.shared.syncSettingChanged(enabled: enabled)
                        }

                        if iCloudSyncEnabled {
                            Button {
                                debugLog("🔵 Sync Now tapped")
                                SyncManager.shared.pushServers(servers, immediate: true)
                                SyncManager.shared.pushPreferencesImmediate()
                                if let ctx = WatchProgressManager.modelContext,
                                   let all = try? ctx.fetch(FetchDescriptor<WatchProgress>()) {
                                    SyncManager.shared.pushWatchProgress(all, immediate: true)
                                }
                                // v1.6.17 — also push reminders so toggling
                                // a category back on can be followed by a
                                // one-tap "push everything" rather than
                                // waiting for the next reminder edit.
                                SyncManager.shared.pushReminders(immediate: true)
                            } label: {
                                SettingsRow(icon: "arrow.triangle.2.circlepath.icloud",
                                            iconColor: .accentPrimary,
                                            title: "Sync Now",
                                            subtitle: syncLastDate > 0
                                                ? "Last synced \(lastSyncedString)"
                                                : "Push all data to iCloud now")
                            }
                            #if os(iOS)
                            .buttonStyle(PressableButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                        }

                        // v1.6.17 — granular per-category sync controls.
                        // Stays accessible even when iCloudSyncEnabled is off
                        // so the Delete actions work for stale-state cleanup.
                        NavigationLink(destination: SyncCategoriesSettingsView()) {
                            SettingsRow(icon: "slider.horizontal.3",
                                        iconColor: .accentPrimary,
                                        title: "Sync Categories",
                                        subtitle: "Choose what syncs across your devices")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif

                        // v1.6.12: destructive action — wipe everything
                        // this app has parked in iCloud. Always offered
                        // (even when Sync is currently off) so a user
                        // who toggled Sync off can still purge stale
                        // cloud state without re-enabling first.
                        Button(role: .destructive) {
                            showClearICloudConfirm = true
                        } label: {
                            SettingsRow(icon: "trash.circle.fill",
                                        iconColor: .statusLive,
                                        title: "Clear iCloud Data",
                                        subtitle: "Wipe synced playlists, preferences, watch progress, and credentials from iCloud")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    } header: {
                        Text("Sync").sectionHeaderStyle()
                    } footer: {
                        Text("Playlists, preferences, and VOD watch progress sync across all devices signed into the same Apple ID. Credentials are stored securely in iCloud Keychain.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                    .listRowBackground(Color.cardBackground)
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif

                    // MARK: - DVR Section
                    Section {
                        NavigationLink(destination: DVRSettingsView()) {
                            SettingsRow(icon: "record.circle", iconColor: .red,
                                        title: "DVR",
                                        subtitle: "Recordings, buffers & storage")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        .listRowBackground(Color.cardBackground)
                    } header: {
                        Text("DVR")
                            .sectionHeaderStyle()
                    }
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif

                    // MARK: - Developer Section
                    Section {
                        NavigationLink(destination: DeveloperSettingsView()) {
                            SettingsRow(icon: "ladybug.fill", iconColor: .accentSecondary,
                                        title: "Developer",
                                        subtitle: "Debug logging & diagnostics")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        .listRowBackground(Color.cardBackground)
                    } header: {
                        Text("Developer")
                            .sectionHeaderStyle()
                    }
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif

                    // MARK: - About Section
                    Section {
                        infoRow("Device",          value: aboutDevice)
                            .listRowBackground(Color.cardBackground)
                        infoRow("System",          value: aboutSystem)
                            .listRowBackground(Color.cardBackground)
                        infoRow("App Version",     value: aboutVersion)
                            .listRowBackground(Color.cardBackground)
                        infoRow("First Installed", value: aboutInstallDate)
                            .listRowBackground(Color.cardBackground)
                        infoRow("Last Updated",    value: aboutUpdateDate)
                            .listRowBackground(Color.cardBackground)

                        Button {
                            #if os(iOS)
                            UIPasteboard.general.string = aboutCopyText
                            #endif
                            copiedAbout = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedAbout = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: copiedAbout ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(copiedAbout ? .accentPrimary : .textSecondary)
                                Text(copiedAbout ? "Copied!" : "Copy to Clipboard")
                                    .font(.bodyMedium)
                                    .foregroundColor(copiedAbout ? .accentPrimary : .textSecondary)
                                Spacer()
                            }
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        .listRowBackground(Color.cardBackground)

                        Link(destination: URL(string: "https://github.com/jonzey231/AerioTV")!) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.textSecondary)
                                Text("Developer Website")
                                    .font(.bodyMedium)
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textTertiary)
                            }
                        }
                        .listRowBackground(Color.cardBackground)

                        Link(destination: URL(string: "https://github.com/jonzey231/AerioTV/issues")!) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.bubble")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.textSecondary)
                                Text("Report an Issue")
                                    .font(.bodyMedium)
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textTertiary)
                            }
                        }
                        .listRowBackground(Color.cardBackground)

                    } header: {
                        Text("About")
                            .sectionHeaderStyle()
                    } footer: {
                        Text("In loving memory of Jesse Mann aka EPG Guru")
                            .font(.footnote)
                            .italic()
                            .foregroundColor(.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }
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
                case .category(.appearance):     AppearanceSettingsView()
                case .category(.appBehaviors):   AppBehaviorsSettingsView()
                case .category(.remoteControl):  RemoteControlSettingsView()
                case .category(.multiview):      MultiviewSettingsView()
                case .category(.network):        NetworkSettingsView()
                case .category(.dvr):            DVRSettingsView()
                case .category(.syncCategories): SyncCategoriesSettingsView()
                case .category(.developer):      DeveloperSettingsView()
                // Phase 3 pane hosts; nothing pushes these yet.
                case .category(.playlists), .category(.sync), .category(.about):
                    EmptyView()
                case .editServer(let id):
                    // The route carries the server id, so editing the SAME
                    // server twice in a row just pushes a fresh route value.
                    // This deletes the old serverToEdit onChange bridge and
                    // its onDisappear-reset re-push hack.
                    if let server = servers.first(where: { $0.id == id }) {
                        EditServerPage(server: server)
                    }
                case .server, .myRecordings:
                    // Rail/sidebar targets from Phase 3 on; ServerDetailView
                    // and MyRecordingsView remain classic pushes today.
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
            .alert("Clear iCloud Data?", isPresented: $showClearICloudConfirm) {
                Button("Clear", role: .destructive) {
                    debugLog("🔵 Clear iCloud Data confirmed")
                    SyncManager.shared.clearAllICloudData(localServers: servers)
                    clearICloudConfirmationVisible = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        await MainActor.run { clearICloudConfirmationVisible = false }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Wipes synced playlists, preferences, watch progress, and credentials from iCloud. This device's data is preserved. iCloud Sync stays enabled — your local state will replace whatever was on iCloud the next time the app pushes.")
            }
            .overlay(alignment: .bottom) {
                if clearICloudConfirmationVisible {
                    Text("iCloud data cleared")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: clearICloudConfirmationVisible)
    }

    // MARK: - Sync computed properties

    /// Human-readable "X minutes ago" string for the last sync timestamp.
    private var lastSyncedString: String {
        guard syncLastDate > 0 else { return "" }
        let interval = Date().timeIntervalSince1970 - syncLastDate
        switch interval {
        case ..<60:      return "just now"
        case ..<3600:    return "\(Int(interval / 60))m ago"
        case ..<86400:   return "\(Int(interval / 3600))h ago"
        default:         return "\(Int(interval / 86400))d ago"
        }
    }

    // MARK: - About computed properties

    private var aboutDevice: String { DeviceInfo.modelName }

    private var aboutSystem: String {
#if canImport(UIKit)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
#else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
#endif
    }

    private var aboutVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var aboutInstallDate: String { DeviceInfo.firstInstalledText }

    private var aboutUpdateDate: String { DeviceInfo.lastUpdatedText }

    private var aboutCopyText: String {
        [
            "AerioTV \(aboutVersion)",
            "Device: \(aboutDevice)",
            "System: \(aboutSystem)",
            "First Installed: \(aboutInstallDate)",
            "Last Updated: \(aboutUpdateDate)"
        ].joined(separator: "\n")
    }

    private func infoRow(_ label: String, value: String, isMonospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .font(isMonospaced ? .monoSmall : .bodyMedium)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

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
        // branch is mounted, so they never double-present). Candidate for
        // a shared modifier in Phase 5.
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
        .alert("Clear iCloud Data?", isPresented: $showClearICloudConfirm) {
            Button("Clear", role: .destructive) {
                debugLog("🔵 Clear iCloud Data confirmed")
                SyncManager.shared.clearAllICloudData(localServers: servers)
                clearICloudConfirmationVisible = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await MainActor.run { clearICloudConfirmationVisible = false }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes synced playlists, preferences, watch progress, and credentials from iCloud. This device's data is preserved. iCloud Sync stays enabled — your local state will replace whatever was on iCloud the next time the app pushes.")
        }
        .overlay(alignment: .bottom) {
            if clearICloudConfirmationVisible {
                Text("iCloud data cleared")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: clearICloudConfirmationVisible)
    }

    /// Sidebar: Playlists as an ordinary item (matching the tvOS rail
    /// ruling of 2026-08-04 and Android tablet, superseding the Rev 2
    /// embed-playlist-rows design), then the categories in the frozen
    /// order. Remote Control stays hidden until #195.
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
                    .font(.title2.weight(.bold))
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)

                padSidebarRow(.playlists, icon: "rectangle.stack.fill", iconColor: .accentPrimary,
                              title: "Playlists",
                              subtitle: servers.first(where: { $0.isActive })?.name)

                Text("App Settings")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                padSidebarRow(.appearance, icon: "paintbrush.fill", iconColor: .accentPrimary,
                              title: "Appearance", subtitle: "Theme, scale & category colors")
                padSidebarRow(.appBehaviors, icon: "switch.2", iconColor: .accentPrimary,
                              title: "App Behaviors", subtitle: "Default tab, launch & gestures")
                padSidebarRow(.multiview, icon: "rectangle.split.2x2.fill", iconColor: .accentPrimary,
                              title: "Multiview", subtitle: "Audio focus, tile spacing & corners")
                padSidebarRow(.network, icon: "network", iconColor: .accentSecondary,
                              title: "Network", subtitle: "Timeout, buffer & background refresh")

                Divider()
                    .background(Color.borderSubtle)
                    .padding(.vertical, 12)

                padSidebarRow(.sync, icon: "icloud.fill", iconColor: .accentPrimary,
                              title: "Sync", subtitle: "iCloud sync & categories")
                padSidebarRow(.dvr, icon: "record.circle", iconColor: .red,
                              title: "DVR", subtitle: "Recordings, buffers & storage")
                padSidebarRow(.developer, icon: "ladybug.fill", iconColor: .accentSecondary,
                              title: "Developer", subtitle: "Debug logging & diagnostics")
                padSidebarRow(.about, icon: "info.circle.fill", iconColor: .accentPrimary,
                              title: "About", subtitle: "Version & links")
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
        case .category(.appearance):     AppearanceSettingsView()
        case .category(.appBehaviors):   AppBehaviorsSettingsView()
        case .category(.multiview):      MultiviewSettingsView()
        case .category(.network):        NetworkSettingsView()
        case .category(.dvr):            DVRSettingsView()
        case .category(.syncCategories): SyncCategoriesSettingsView()
        case .category(.developer):      DeveloperSettingsView()
        case .category(.sync):           padSyncPane
        case .category(.about):          padAboutPane
        case .server(let id):
            if let server = servers.first(where: { $0.id == id }) {
                ServerDetailView(server: server)
            } else {
                Color.appBackground
            }
        case .category(.remoteControl), .editServer, .myRecordings:
            // RemoteControlSettingsView is tvOS-only (its sidebar row is
            // hidden until #195); the pushes never target a pane.
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
                                .font(.system(size: 28))
                                .foregroundColor(.textTertiary)
                            Text("No playlists added")
                                .font(.bodyMedium)
                                .foregroundColor(.textTertiary)
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
                            .font(.system(size: 20))
                            .foregroundStyle(LinearGradient.accentGradient)
                        Text("Add Playlist")
                            .font(.bodyMedium)
                            .foregroundColor(.accentPrimary)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .listRowBackground(Color.cardBackground)
            } footer: {
                if !servers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Tap ○ to set the active playlist", systemImage: "checkmark.circle")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                        Label("Long press to edit or delete", systemImage: "hand.tap")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                        if servers.count > 1 {
                            Label("Touch and hold, then drag to reorder", systemImage: "arrow.up.arrow.down")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
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

    /// Sync pane: the iPhone root's Sync section as a detail page
    /// (same rows, same copy).
    private var padSyncPane: some View {
        List {
            Section {
                Toggle(isOn: $iCloudSyncEnabled) {
                    SettingsRow(icon: "icloud.fill", iconColor: .accentPrimary,
                                title: "iCloud Sync",
                                subtitle: "Sync playlists, preferences, and watch progress")
                }
                .tint(ThemeManager.shared.accent)
                .onChange(of: iCloudSyncEnabled) { _, enabled in
                    SyncManager.shared.syncSettingChanged(enabled: enabled)
                }

                if iCloudSyncEnabled {
                    Button {
                        debugLog("🔵 Sync Now tapped")
                        SyncManager.shared.pushServers(servers, immediate: true)
                        SyncManager.shared.pushPreferencesImmediate()
                        if let ctx = WatchProgressManager.modelContext,
                           let all = try? ctx.fetch(FetchDescriptor<WatchProgress>()) {
                            SyncManager.shared.pushWatchProgress(all, immediate: true)
                        }
                        SyncManager.shared.pushReminders(immediate: true)
                    } label: {
                        SettingsRow(icon: "arrow.triangle.2.circlepath.icloud",
                                    iconColor: .accentPrimary,
                                    title: "Sync Now",
                                    subtitle: syncLastDate > 0
                                        ? "Last synced \(lastSyncedString)"
                                        : "Push all data to iCloud now")
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                NavigationLink(destination: SyncCategoriesSettingsView()) {
                    SettingsRow(icon: "slider.horizontal.3",
                                iconColor: .accentPrimary,
                                title: "Sync Categories",
                                subtitle: "Choose what syncs across your devices")
                }
                .buttonStyle(PressableButtonStyle())

                Button(role: .destructive) {
                    showClearICloudConfirm = true
                } label: {
                    SettingsRow(icon: "trash.circle.fill",
                                iconColor: .statusLive,
                                title: "Clear iCloud Data",
                                subtitle: "Wipe synced playlists, preferences, watch progress, and credentials from iCloud")
                }
                .buttonStyle(PressableButtonStyle())
            } footer: {
                Text("Playlists, preferences, and VOD watch progress sync across all devices signed into the same Apple ID. Credentials are stored securely in iCloud Keychain.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listRowBackground(Color.cardBackground)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// About pane: the iPhone root's About section as a detail page.
    private var padAboutPane: some View {
        List {
            Section {
                infoRow("Device",          value: aboutDevice)
                    .listRowBackground(Color.cardBackground)
                infoRow("System",          value: aboutSystem)
                    .listRowBackground(Color.cardBackground)
                infoRow("App Version",     value: aboutVersion)
                    .listRowBackground(Color.cardBackground)
                infoRow("First Installed", value: aboutInstallDate)
                    .listRowBackground(Color.cardBackground)
                infoRow("Last Updated",    value: aboutUpdateDate)
                    .listRowBackground(Color.cardBackground)

                Button {
                    UIPasteboard.general.string = aboutCopyText
                    copiedAbout = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedAbout = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: copiedAbout ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(copiedAbout ? .accentPrimary : .textSecondary)
                        Text(copiedAbout ? "Copied!" : "Copy to Clipboard")
                            .font(.bodyMedium)
                            .foregroundColor(copiedAbout ? .accentPrimary : .textSecondary)
                        Spacer()
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .listRowBackground(Color.cardBackground)

                Link(destination: URL(string: "https://github.com/jonzey231/AerioTV")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.textSecondary)
                        Text("Developer Website")
                            .font(.bodyMedium)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                            .foregroundColor(.textTertiary)
                    }
                }
                .listRowBackground(Color.cardBackground)

                Link(destination: URL(string: "https://github.com/jonzey231/AerioTV/issues")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.textSecondary)
                        Text("Report an Issue")
                            .font(.bodyMedium)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                            .foregroundColor(.textTertiary)
                    }
                }
                .listRowBackground(Color.cardBackground)
            } footer: {
                Text("In loving memory of Jesse Mann aka EPG Guru")
                    .font(.footnote)
                    .italic()
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
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
            id: "appearance", route: .category(.appearance), label: "Appearance",
            icon: "paintbrush.fill", iconColor: .accentPrimary, subtitle: "Theme, scale & category colors"))
        items.append(TVSettingsRailItem(
            id: "app-behaviors", route: .category(.appBehaviors), label: "App Behaviors",
            icon: "switch.2", iconColor: .accentPrimary, subtitle: "Default tab, launch & gestures"))
        // Remote Control: case exists, rail row stays hidden until #195
        // (mirrors the commented root entry it replaces).
        items.append(TVSettingsRailItem(
            id: "multiview", route: .category(.multiview), label: "Multiview",
            icon: "rectangle.split.2x2.fill", iconColor: .accentPrimary, subtitle: "Audio focus, tile spacing & corners"))
        items.append(TVSettingsRailItem(
            id: "network", route: .category(.network), label: "Network",
            icon: "network", iconColor: .accentSecondary, subtitle: "Timeout, buffer & background refresh"))
        items.append(TVSettingsRailItem(
            id: "sync", route: .category(.sync), label: "Sync",
            icon: "icloud.fill", iconColor: .accentPrimary, subtitle: "iCloud sync & categories"))
        items.append(TVSettingsRailItem(
            id: "dvr", route: .category(.dvr), label: "DVR",
            icon: "record.circle", iconColor: .red, subtitle: "Recordings, buffers & storage"))
        items.append(TVSettingsRailItem(
            id: "developer", route: .category(.developer), label: "Developer",
            icon: "ladybug.fill", iconColor: .accentSecondary, subtitle: "Debug logging & diagnostics"))
        items.append(TVSettingsRailItem(
            id: "about", route: .category(.about), label: "About",
            icon: "info.circle.fill", iconColor: .accentPrimary, subtitle: "Version & links"))
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
        case .category(.appearance):     AppearanceSettingsView()
        case .category(.appBehaviors):   AppBehaviorsSettingsView()
        case .category(.remoteControl):  RemoteControlSettingsView()
        case .category(.multiview):      MultiviewSettingsView()
        case .category(.network):        NetworkSettingsView()
        case .category(.dvr):            DVRSettingsView()
        case .category(.syncCategories): SyncCategoriesSettingsView()
        case .category(.developer):      DeveloperSettingsView()
        case .category(.sync):           tvSyncPane
        case .category(.about):          tvAboutPane
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
                                .font(.system(size: 36))
                                .foregroundColor(.textSecondary)
                            Text("No playlists added")
                                .font(.bodyMedium)
                                .foregroundColor(.textSecondary)
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
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.textPrimary.opacity(0.7))
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
    }

    /// The Sync pane: the root-inline iCloud toggles moved into a pane
    /// (Rev 2 canon amendment 2 — layout only, same copy and order),
    /// followed by the Sync Categories nav row exactly as the root had it.
    private var tvSyncPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsToggleRow(
                    icon: "icloud.fill",
                    iconColor: .accentPrimary,
                    title: "iCloud Sync",
                    subtitle: "Sync playlists, preferences, and watch progress",
                    isOn: $iCloudSyncEnabled
                ) { enabled in
                    SyncManager.shared.syncSettingChanged(enabled: enabled)
                }

                if iCloudSyncEnabled {
                    TVSettingsActionRow(
                        icon: "arrow.triangle.2.circlepath.icloud",
                        label: syncLastDate > 0
                            ? "Sync Now  ·  Last synced \(lastSyncedString)"
                            : "Sync Now"
                    ) {
                        SyncManager.shared.pushServers(servers, immediate: true)
                        SyncManager.shared.pushPreferencesImmediate()
                        if let ctx = WatchProgressManager.modelContext,
                           let all = try? ctx.fetch(FetchDescriptor<WatchProgress>()) {
                            SyncManager.shared.pushWatchProgress(all, immediate: true)
                        }
                        SyncManager.shared.pushReminders(immediate: true)
                    }
                }
                TVSettingsNavRow(destination: SyncCategoriesSettingsView().trackedAsClassicSettingsChild()) {
                    SettingsRow(icon: "slider.horizontal.3",
                                iconColor: .accentPrimary,
                                title: "Sync Categories",
                                subtitle: "Choose what syncs across your devices")
                }
                TVSettingsActionRow(
                    icon: "trash.circle.fill",
                    label: "Clear iCloud Data",
                    isDestructive: true
                ) {
                    showClearICloudConfirm = true
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
    }

    /// The About pane: the root About rows plus the memorial line
    /// (Rev 2 canon amendment 2 — layout only).
    private var tvAboutPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    tvAboutRow("Device",          value: aboutDevice)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("System",          value: aboutSystem)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("App Version",     value: aboutVersion)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("First Installed", value: aboutInstallDate)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("Last Updated",    value: aboutUpdateDate)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutLinkRow("Developer Website", urlString: "https://github.com/jonzey231/AerioTV")
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutLinkRow("Report an Issue",   urlString: "https://github.com/jonzey231/AerioTV/issues/new")
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cardBackground))
                .padding(.bottom, 8)

                Text("In loving memory of Jesse Mann aka EPG Guru")
                    .font(.system(size: 22))
                    .italic()
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
        .sheet(item: $tvQRLink) { link in
            TVQRLinkSheet(link: link)
        }
    }


    /// Non-nil presents the About-row QR sheet.
    @State private var tvQRLink: TVQRLink?

    private func tvAboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 26))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    /// External-link About row: focusable, presents the URL as a QR the
    /// user scans with a phone (Android parity P2; the row used to be
    /// inert text the user had to retype).
    private func tvAboutLinkRow(_ label: String, urlString: String) -> some View {
        Button {
            tvQRLink = TVQRLink(title: label, url: urlString)
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.textSecondary)
                Spacer()
                Image(systemName: "qrcode")
                    .font(.system(size: 24))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .buttonStyle(.plain)
    }
    #endif
}

#if os(tvOS)
/// A URL surfaced on tvOS as a scannable QR (Android parity:
/// TvQrLinkDialog). Non-nil state presents the sheet.
private struct TVQRLink: Identifiable {
    let title: String
    let url: String
    var id: String { url }
}

/// Centered QR sheet: title, caption, QR on a white quiet-zone card, the
/// URL as text fallback (typable when the code will not scan), Close.
/// Keeps the screen awake while visible; the user is fumbling for a
/// phone and aiming a camera at the TV.
private struct TVQRLinkSheet: View {
    let link: TVQRLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text(link.title)
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.textPrimary)
            Text("Scan with your phone to open this page.")
                .font(.system(size: 26))
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            if let qr = Self.qrCodeImage(from: link.url) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 280, height: 280)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                    )
                    .padding(.vertical, 8)
            }
            Text(link.url)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.elevatedBackground.opacity(0.55))
                )
            Button("Close") { dismiss() }
                .padding(.top, 10)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        // Route through the refcount helper rather than assigning
        // isIdleTimerDisabled directly: a direct write on dismiss would
        // clobber any concurrent holder (e.g. active playback).
        .onAppear { IdleTimerRefCount.increment(caller: "about-qr-sheet") }
        .onDisappear { IdleTimerRefCount.decrement(caller: "about-qr-sheet") }
    }

    private static func qrCodeImage(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // Error correction H: a phone camera reads a TV screen at an
        // angle through living-room lighting.
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
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
