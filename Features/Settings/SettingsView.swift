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
        NavigationStack { settingsContent }
        #endif
    }

    #if os(tvOS)
    /// Computes `isSubviewPushed` from both navPath and the classic
    /// dismiss stack and writes it through the binding only when the
    /// value actually changes (avoids invalidating MainTabView on
    /// every navPath mutation of the same emptiness).
    private func syncIsSubviewPushed() {
        let pushed = !navPath.isEmpty || dismissStack.depth > 0
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
        }
    }
    #endif

    @ViewBuilder
    private var settingsContent: some View {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                #if os(tvOS)
                tvOSContent
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
                        NavigationLink(destination: MultiviewSettingsView()) {
                            SettingsRow(icon: "rectangle.split.2x2.fill", iconColor: .accentPrimary,
                                        title: "Multiview", subtitle: "Audio focus, tile spacing & corners")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: NetworkSettingsView()) {
                            SettingsRow(icon: "network", iconColor: .accentSecondary,
                                        title: "Network", subtitle: "Timeout, buffer, home WiFi & refresh")
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
            .navigationDestination(for: String.self) { route in
                switch route {
                case "appearance":      AppearanceSettingsView()
                case "multiview":       MultiviewSettingsView()
                case "network":         NetworkSettingsView()
                case "dvr-settings": DVRSettingsView()
                case "sync-categories": SyncCategoriesSettingsView()
                case "developer":  DeveloperSettingsView()
                case "edit-server":
                    if let server = serverToEdit {
                        EditServerPage(server: server)
                    }
                default:           EmptyView()
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
                        let sid = server.id.uuidString
                        server.deleteCredentialsFromKeychain()
                        // Cascade: delete any EPGProgram rows scoped to this
                        // server so they don't orphan and get reused by a
                        // later server of a different type with different
                        // channel IDs. Without this, deleting an Xtream
                        // playlist and re-adding the same server via
                        // Dispatcharr API leaves stale XC EPG rows in
                        // SwiftData that loadFromCache would otherwise
                        // return, bypassing the network fetch and leaving
                        // the guide empty.
                        let epgDescriptor = FetchDescriptor<EPGProgram>(
                            predicate: #Predicate<EPGProgram> { $0.serverID == sid }
                        )
                        if let stale = try? modelContext.fetch(epgDescriptor) {
                            for p in stale { modelContext.delete(p) }
                            debugLog("🗑️ Deleted \(stale.count) orphaned EPGProgram rows for server \(sid)")
                        }
                        modelContext.delete(server)
                        try? modelContext.save()
                        // Push updated list to iCloud (server removed)
                        SyncManager.shared.pushServers(servers.filter { $0.id != server.id })
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \"\(serverToDelete?.name ?? "this playlist")\" from the app. Your server data will not be affected.")
            }
            #if os(tvOS)
            .onChange(of: serverToEdit) { _, server in
                if let server {
                    navPath.append("edit-server")
                }
            }
            #else
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
        for s in servers { s.isActive = false }
        server.isActive = true
        try? modelContext.save()
        SyncManager.shared.pushServers(servers)
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

    // MARK: - tvOS Settings Layout

    #if os(tvOS)
    private var tvOSContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Playlists
                tvSettingsHeader("Playlists")
                VStack(spacing: 8) {
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
                                // Only offer the "set active" radio when there's
                                // more than one playlist — with one playlist
                                // it's always the active one, so the circle is
                                // noise.
                                ServerListRow(server: server,
                                              onSetActive: servers.count > 1 ? { setActiveServer(server) } : nil)
                            }
                            .contextMenu {
                                // "Use This Playlist" — primary tvOS
                                // path for switching between playlists.
                                // The on-row "○ → ●" checkmark button
                                // exists but uses
                                // `TVNoHighlightButtonStyle()` and
                                // sits inside the outer
                                // `TVSettingsNavRow`'s
                                // `NavigationLink`, which consumes
                                // every tap to push the detail view —
                                // so tvOS focus never reaches the
                                // checkmark and users had no way to
                                // switch playlists from the list.
                                // Adding the action to the long-press
                                // context menu (which tvOS users
                                // already know to use for Edit /
                                // Delete) lets them activate without
                                // touching the row's primary tap
                                // behaviour.
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

                                    // v1.6.17 — Move Up / Move Down in
                                    // the tvOS context menu. The Siri
                                    // Remote can't drag rows, and the
                                    // existing context-menu pattern is
                                    // where users already go for Edit /
                                    // Delete, so reorder lives there too.
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
                    }
                    TVSettingsActionRow(icon: "plus.circle.fill",
                                        label: "Add Playlist",
                                        isAccent: true) {
                        showAddServer = true
                    }
                }
                if !servers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        // The "Tap ○" hint that used to live here was
                        // misleading on tvOS — the checkmark button
                        // is rendered but the focus engine can't
                        // reach it through the outer NavigationLink.
                        // Long-press is the actual path now (set
                        // active / edit / delete all live there).
                        Label("Long press for options: switch playlist, edit, or delete", systemImage: "hand.tap")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.textPrimary.opacity(0.7))
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                }

                // MARK: App Settings
                tvSettingsHeader("App Settings").padding(.top, 36)
                VStack(spacing: 8) {
                    TVSettingsNavButton(label: "Appearance", icon: "paintbrush.fill",
                                        iconColor: .accentPrimary, subtitle: "Theme, scale & category colors") {
                        navPath.append("appearance")
                    }
                    TVSettingsNavButton(label: "Multiview", icon: "rectangle.split.2x2.fill",
                                        iconColor: .accentPrimary, subtitle: "Audio focus, tile spacing & corners") {
                        navPath.append("multiview")
                    }
                    TVSettingsNavButton(label: "Network", icon: "network",
                                        iconColor: .accentSecondary, subtitle: "Timeout, buffer, home WiFi & refresh") {
                        navPath.append("network")
                    }
                }

                // MARK: Sync
                tvSettingsHeader("Sync").padding(.top, 36)
                VStack(spacing: 8) {
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
                            // v1.6.17 — also push reminders so toggling
                            // a category back on can be followed by a
                            // one-tap "push everything."
                            SyncManager.shared.pushReminders(immediate: true)
                        }
                    }
                    // v1.6.17 — granular per-category sync controls.
                    // Stays accessible even when iCloudSyncEnabled is off
                    // so the per-category Delete actions work for stale-
                    // state cleanup before re-enabling sync.
                    TVSettingsNavRow(destination: SyncCategoriesSettingsView().trackedAsClassicSettingsChild()) {
                        SettingsRow(icon: "slider.horizontal.3",
                                    iconColor: .accentPrimary,
                                    title: "Sync Categories",
                                    subtitle: "Choose what syncs across your devices")
                    }
                    // v1.6.12: destructive — wipe iCloud-side state.
                    // Always offered (even when Sync is currently off)
                    // so a user who toggled Sync off can still purge
                    // stale cloud state without re-enabling first.
                    TVSettingsActionRow(
                        icon: "trash.circle.fill",
                        label: "Clear iCloud Data",
                        isDestructive: true
                    ) {
                        showClearICloudConfirm = true
                    }
                }

                // MARK: DVR
                tvSettingsHeader("DVR").padding(.top, 36)
                TVSettingsNavButton(label: "DVR", icon: "record.circle",
                                    iconColor: .red, subtitle: "Recordings, buffers & storage") {
                    navPath.append("dvr-settings")
                }

                // MARK: Developer
                tvSettingsHeader("Developer").padding(.top, 36)
                TVSettingsNavButton(label: "Developer", icon: "ladybug.fill",
                                    iconColor: .accentSecondary, subtitle: "Debug logging & diagnostics") {
                    navPath.append("developer")
                }

                // MARK: About
                tvSettingsHeader("About").padding(.top, 36)
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
                    tvAboutRow("Developer Website", value: "github.com/jonzey231/AerioTV")
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("Report an Issue",   value: "github.com/jonzey231/AerioTV/issues")
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cardBackground))
                .padding(.bottom, 8)

            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }

    private func tvSettingsHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 30, weight: .semibold))
            .foregroundColor(.textPrimary)
            .padding(.bottom, 12)
    }

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
    #endif
}

// MARK: - tvOS Settings Row Components

#if os(tvOS)
/// NavigationLink wrapper that shows the teal-tinted card highlight on focus
/// instead of the system white row highlight.
/// NavigationLink row with teal card highlight on focus.
/// Uses .plain buttonStyle so the tvOS focus engine registers the link as focusable.
///
/// Internal (not private) so DVR / Developer / Appearance settings pages
/// can reuse the same focus treatment for uniform tvOS UI.
struct TVSettingsNavRow<Destination: View, Content: View>: View {
    let destination: Destination
    let content: Content
    @FocusState private var isFocused: Bool

    init(destination: Destination, @ViewBuilder content: () -> Content) {
        self.destination = destination
        self.content = content()
    }

    var body: some View {
        NavigationLink(destination: destination) {
            content
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(tvSettingsCardBG(isFocused))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Button-based nav row that pushes onto a NavigationPath instead of using NavigationLink.
/// This ensures the TabView's .onExitCommand can properly manage back navigation.
struct TVSettingsNavButton: View {
    let label: String
    let icon: String
    let iconColor: Color
    let subtitle: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            SettingsRow(icon: icon, iconColor: iconColor, title: label, subtitle: subtitle)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(tvSettingsCardBG(isFocused))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Plain action row (Add Playlist, Copy to Clipboard, etc.)
/// with the same teal card highlight on focus.
struct TVSettingsActionRow: View {
    let icon: String
    let label: String
    var isAccent: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var tint: Color {
        if isDestructive { return .red }
        if isAccent { return .accentPrimary }
        return .textPrimary
    }

    private var iconTint: Color {
        if isDestructive { return .red }
        if isAccent { return .accentPrimary }
        return .textSecondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(iconTint)
                Text(label)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(tint)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(tvSettingsCardBG(isFocused))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Selection row for "pick one of many" settings lists (Color Theme,
/// Default Tab, buffer pickers, etc.) — shows an accent checkmark on
/// the selected option and uses the same teal card highlight on focus.
/// Supports an optional icon, leading badge (e.g. theme swatch), and
/// subtitle.
struct TVSettingsSelectionRow<Leading: View>: View {
    let label: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 20))
                            .foregroundColor(.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.accentPrimary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(tvSettingsCardBG(isFocused))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

extension TVSettingsSelectionRow where Leading == EmptyView {
    init(label: String, subtitle: String? = nil,
         isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
        self.leading = { EmptyView() }
    }
}

/// Convenience initializer that takes a leading SF Symbol string instead
/// of a custom view (covers the common case).
extension TVSettingsSelectionRow where Leading == AnyView {
    init(icon: String, iconColor: Color = .accentPrimary,
         label: String, subtitle: String? = nil,
         isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
        self.leading = {
            AnyView(
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                    .frame(width: 32)
            )
        }
    }
}

/// Toggle row for tvOS — renders as a Button that flips a Bool on select,
/// showing an "On / Off" indicator. Consistent with TVGroupToggleRow in ManageGroupsSheet.
struct TVSettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let onChange: (Bool) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
            onChange(isOn)
        } label: {
            HStack(spacing: 0) {
                SettingsRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // On/Off indicator — mirrors TVGroupToggleRow style
                HStack(spacing: 8) {
                    Circle()
                        .fill(isOn ? iconColor : Color.textTertiary)
                        .frame(width: 10, height: 10)
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(isOn
                            ? (isFocused ? .white : iconColor)
                            : (isFocused ? .white : .textTertiary))
                }
                .padding(.leading, 16)
            }
            .frame(minHeight: 80)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(tvSettingsCardBG(isFocused))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Teal-tinted card background shared by all tvOS settings row components.
/// Internal so DVR / Developer / Appearance settings pages can reuse it.
func tvSettingsCardBG(_ focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(focused ? Color.accentPrimary.opacity(0.18) : Color.cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentPrimary.opacity(focused ? 0.65 : 0.10),
                        lineWidth: focused ? 2.5 : 1)
        }
}
#endif

// MARK: - Server List Row
struct ServerListRow: View {
    let server: ServerConnection
    var onSetActive: (() -> Void)? = nil
    #if os(iOS)
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    #endif

    private var hasLANConfigured: Bool {
        server.type != .m3uPlaylist && !server.localURL.isEmpty && !server.homeSSIDs.isEmpty
    }

    private var isOnLAN: Bool {
        hasLANConfigured && server.effectiveBaseURL != server.normalizedBaseURL
    }

    #if os(tvOS)
    private let checkmarkSize: CGFloat = 28
    private let iconBoxSize: CGFloat = 48
    private let iconFontSize: CGFloat = 22
    private let statusDotSize: CGFloat = 12
    #else
    private let checkmarkSize: CGFloat = 22
    private let iconBoxSize: CGFloat = 36
    private let iconFontSize: CGFloat = 16
    private let statusDotSize: CGFloat = 8
    #endif

    var body: some View {
        HStack(spacing: 14) {
            // Active server indicator — tapping sets this server as the active one
            if let onSetActive {
                Button(action: onSetActive) {
                    Image(systemName: server.isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: checkmarkSize))
                        .foregroundColor(server.isActive ? .accentPrimary : .textTertiary)
                }
                #if os(tvOS)
                .buttonStyle(TVNoHighlightButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(server.type.color.opacity(0.2))
                    .frame(width: iconBoxSize, height: iconBoxSize)
                Image(systemName: server.type.systemIcon)
                    .font(.system(size: iconFontSize, weight: .medium))
                    .foregroundColor(server.type.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                HStack(spacing: 6) {
                    ServerTypeBadge(type: server.type)
                    if hasLANConfigured {
                        LANWANBadge(isLAN: isOnLAN)
                    }
                    Text(server.effectiveBaseURL)
                        .font(.monoSmall)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Circle()
                .fill(server.isVerified ? Color.statusOnline : Color.textTertiary)
                .frame(width: statusDotSize, height: statusDotSize)
        }
        #if os(tvOS)
        .padding(.vertical, 16)
        #else
        .padding(.vertical, 4)
        #endif
    }
}

// MARK: - LAN / WAN Badge
struct LANWANBadge: View {
    let isLAN: Bool

    #if os(tvOS)
    private let iconSize: CGFloat = 14
    private let textSize: CGFloat = 16
    private let hPad: CGFloat = 8
    private let vPad: CGFloat = 4
    #else
    private let iconSize: CGFloat = 8
    private let textSize: CGFloat = 9
    private let hPad: CGFloat = 5
    private let vPad: CGFloat = 2
    #endif

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isLAN ? "wifi" : "globe")
                .font(.system(size: iconSize, weight: .semibold))
            Text(isLAN ? "LAN" : "WAN")
                .font(.system(size: textSize, weight: .bold))
        }
        .foregroundColor(isLAN ? .statusOnline : .accentSecondary)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(
            Capsule()
                .fill(isLAN ? Color.statusOnline.opacity(0.15) : Color.accentSecondary.opacity(0.15))
        )
    }
}

// MARK: - Settings Row
struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    /// Observe ThemeManager so the subtitle's `.textSecondary`
    /// (computed as `theme.accent.opacity(0.65)`) re-evaluates on
    /// theme changes. v1.6.8: parent SettingsView observes
    /// ThemeManager too, but SwiftUI's List + UITableView cell
    /// diff skips re-rendering a row's body unless one of its
    /// observed inputs changes — and Settings rows are
    /// constructed with the same prop values across themes
    /// (icon name + title + subtitle string). Subscribing the
    /// row directly forces a body refresh on every theme push,
    /// which is what makes `.textSecondary` actually pick up the
    /// new opacity-tinted accent.
    @ObservedObject private var theme = ThemeManager.shared

    #if os(tvOS)
    private let iconBoxSize: CGFloat = 48
    private let iconFontSize: CGFloat = 22
    private let cornerRadius: CGFloat = 10
    #else
    private let iconBoxSize: CGFloat = 32
    private let iconFontSize: CGFloat = 14
    private let cornerRadius: CGFloat = 7
    #endif

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(iconColor.opacity(0.2))
                    .frame(width: iconBoxSize, height: iconBoxSize)
                Image(systemName: icon)
                    .font(.system(size: iconFontSize, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.bodySmall)
                        .foregroundColor(.textSecondary)
                }
            }
        }
        #if os(tvOS)
        .padding(.vertical, 14)
        #else
        .padding(.vertical, 2)
        #endif
    }
}

// MARK: - Server Detail View
struct ServerDetailView: View {
    let server: ServerConnection
    /// See SettingsView for the rationale — observing ThemeManager
    /// makes every accent-tinted row in this detail page reactive to
    /// theme changes (icons, status pills, action buttons).
    @ObservedObject private var theme = ThemeManager.shared
    @Query private var servers: [ServerConnection]
    /// Used by the per-playlist "Refresh EPG Data" action so the
    /// detached delete can grab a `ModelContainer` from this context.
    @Environment(\.modelContext) private var modelContext
    @State private var isTestingConnection = false
    @State private var connectionResult: String? = nil
    @State private var connectionSuccess = false
    /// Per-playlist EPG-purge UX. v1.6.8: replaces the global
    /// "Refresh EPG Data" action that used to live on
    /// `AppearanceSettingsView`. Each playlist now owns its own
    /// EPG-purge action so users with multiple servers can fix one
    /// playlist's corrupted cache without nuking the others.
    @State private var showPurgeConfirmation = false
    @State private var isPurgingEPG = false
    #if os(iOS)
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var ssidRefreshed = false
    #endif
    /// Cross-platform LAN-probe observer. `TVLANProbe` is the
    /// (legacy-named) cross-platform reachability checker — see
    /// `AerioApp.swift` for the v1.6.8 rationale. Observing the
    /// singleton lets ServerDetailView surface the last probe
    /// result on every platform so users on Ethernet / Mac Catalyst
    /// (where SSID detection is broken) can still see WHY the app
    /// thinks it's on LAN, plus drive the "Refresh LAN Detection"
    /// button.
    @ObservedObject private var tvLANProbe = TVLANProbe.shared
    @State private var lanRefreshAcked = false

    private var hasLANConfigured: Bool {
        // v1.6.8: dropped the iOS-only `!homeSSIDs.isEmpty` guard.
        // LAN now means "we have a localURL we can probe" on every
        // platform — Ethernet users on iPad / Mac Catalyst have no
        // SSID to configure but still want LAN routing when the
        // probe succeeds.
        return server.type != .m3uPlaylist && !server.localURL.isEmpty
    }

    private var isOnLAN: Bool {
        hasLANConfigured && server.effectiveBaseURL != server.normalizedBaseURL
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            List {
                Section {
                    infoRow("Type", value: server.type.displayName)
                    infoRow("Remote URL", value: server.normalizedBaseURL, isMonospaced: true)
                    if !server.username.isEmpty {
                        infoRow("Username", value: server.username)
                    }
                    infoRow("Status", value: server.isVerified ? "Verified" : "Unverified")
                    if let last = server.lastConnected {
                        infoRow("Last Connected", value: last.formatted(.relative(presentation: .named)))
                    }
                } header: {
                    Text("Connection Details").sectionHeaderStyle()
                }
                .listRowBackground(Color.cardBackground)

                if hasLANConfigured {
                    Section {
                        HStack {
                            Text("Mode")
                                .font(.bodyMedium)
                                .foregroundColor(.textSecondary)
                            Spacer()
                            LANWANBadge(isLAN: isOnLAN)
                            Text(isOnLAN ? "Local (LAN)" : "Remote (WAN)")
                                .font(.bodyMedium)
                                .foregroundColor(isOnLAN ? .statusOnline : .accentSecondary)
                        }
                        .listRowBackground(Color.cardBackground)

                        infoRow("Active URL", value: server.effectiveBaseURL, isMonospaced: true)

                        // Detected SSID diagnostic row
                        #if os(iOS)
                        HStack {
                            Text("Detected SSID")
                                .font(.bodyMedium)
                                .foregroundColor(.textSecondary)
                            Spacer()
                            if let ssid = networkMonitor.currentSSID {
                                Text(ssid)
                                    .font(.monoSmall)
                                    .foregroundColor(.textPrimary)
                            } else {
                                Text("Not detected")
                                    .font(.labelSmall)
                                    .foregroundColor(.statusWarning)
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                        #endif

                        // Show all configured SSIDs, highlighting the matched one
                        ForEach(server.homeSSIDs, id: \.self) { ssid in
                            HStack {
                                Text(ssid)
                                    .font(.monoSmall)
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                if server.activeHomeSSID == ssid {
                                    Label("Connected", systemImage: "checkmark.circle.fill")
                                        .font(.labelSmall)
                                        .foregroundColor(.statusOnline)
                                } else {
                                    Text("Not connected")
                                        .font(.labelSmall)
                                        .foregroundColor(.textTertiary)
                                }
                            }
                            .listRowBackground(Color.cardBackground)
                        }

                        // Manual SSID refresh
                        #if os(iOS)
                        Button {
                            ssidRefreshed = false
                            NetworkMonitor.shared.refresh(force: true)
                        } label: {
                            HStack(spacing: 8) {
                                if networkMonitor.isRefreshing {
                                    ProgressView().tint(.accentPrimary).scaleEffect(0.8)
                                } else {
                                    Image(systemName: ssidRefreshed ? "checkmark.circle.fill" : "wifi.circle")
                                        .foregroundColor(ssidRefreshed ? .statusOnline : .accentPrimary)
                                }
                                Text(networkMonitor.isRefreshing ? "Detecting…"
                                     : ssidRefreshed ? "Up to date"
                                     : "Refresh SSID Detection")
                                    .foregroundColor(networkMonitor.isRefreshing ? .textSecondary
                                                     : ssidRefreshed ? .statusOnline : .accentPrimary)
                            }
                        }
                        .disabled(networkMonitor.isRefreshing)
                        .listRowBackground(Color.cardBackground)
                        .onChange(of: networkMonitor.isRefreshing) { _, nowRefreshing in
                            if !nowRefreshing {
                                ssidRefreshed = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    ssidRefreshed = false
                                }
                            }
                        }
                        #endif

                        // Cross-platform LAN probe rows. v1.6.8 promoted
                        // `TVLANProbe` from tvOS-only to all platforms,
                        // so these surface on iOS / iPad / Mac Catalyst
                        // too. Two reasons it matters on iOS:
                        //   • Ethernet has no SSID — the SSID rows
                        //     above are useless on a wired iPad / Mac.
                        //   • Mac Catalyst's NEHotspotNetwork is broken
                        //     (returns nil even with wifi-info +
                        //     Location); the probe is the actual
                        //     source of truth there.
                        // The "Refresh LAN Detection" button kicks a
                        // fresh probe of every server's localURL —
                        // matches the tvOS pattern, and the global
                        // `tvosLANDetected` UserDefaults flag means a
                        // refresh on one server's detail page picks
                        // up the result for all of them.
                        if let host = tvLANProbe.lastHost, tvLANProbe.lastDetected {
                            infoRow("Last Probe Host", value: host, isMonospaced: true)
                        }
                        if let ms = tvLANProbe.lastLatencyMs, tvLANProbe.lastDetected {
                            infoRow("Last Probe Latency", value: "\(ms) ms")
                        }
                        if let ts = tvLANProbe.lastTimestamp {
                            infoRow(
                                "Last Checked",
                                value: ts.formatted(.relative(presentation: .named))
                            )
                        }
                        Button {
                            tvLANProbe.probe(servers: Array(servers))
                        } label: {
                            HStack(spacing: 8) {
                                if tvLANProbe.isProbing {
                                    ProgressView().tint(.accentPrimary).scaleEffect(0.8)
                                } else {
                                    Image(systemName: lanRefreshAcked ? "checkmark.circle.fill" : "wifi.circle")
                                        .foregroundColor(lanRefreshAcked ? .statusOnline : .accentPrimary)
                                }
                                Text(tvLANProbe.isProbing ? "Probing…"
                                     : lanRefreshAcked ? "Up to date"
                                     : "Refresh LAN Detection")
                                    .foregroundColor(tvLANProbe.isProbing ? .textSecondary
                                                     : lanRefreshAcked ? .statusOnline : .accentPrimary)
                            }
                        }
                        .disabled(tvLANProbe.isProbing)
                        .listRowBackground(Color.cardBackground)
                        .onChange(of: tvLANProbe.isProbing) { _, nowProbing in
                            if !nowProbing {
                                lanRefreshAcked = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    lanRefreshAcked = false
                                }
                            }
                        }
                    } header: {
                        Text("Active Connection").sectionHeaderStyle()
                    } footer: {
                        #if os(iOS)
                        if networkMonitor.currentSSID == nil && networkMonitor.isOnWifi {
                            // On WiFi but SSID is nil — almost always because
                            // the user hasn't granted Location access. The
                            // entitlement + Info.plist string ship with the
                            // app; iOS additionally requires the user to
                            // grant Location (Precise) before
                            // NEHotspotNetwork.fetchCurrent will return the
                            // SSID. Direct the user to the iOS Settings
                            // path rather than surfacing Xcode jargon.
                            Text("⚠️ Wi-Fi detected but SSID is unknown. To detect your network, grant Aerio Location access: open the iOS Settings app → Privacy & Security → Location Services → Aerio → choose \"While Using the App\" and enable Precise Location.")
                                .font(.labelSmall)
                                .foregroundColor(.statusWarning)
                        } else if let matched = server.activeHomeSSID {
                            Text("Connected to \"\(matched)\" — using local URL.")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        } else {
                            Text("Not on a configured home WiFi network — using remote URL.")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        }
                        #endif
                        #if os(tvOS)
                        // tvOS equivalent of the iOS footer's plain-
                        // English explanation. We cannot show "which
                        // SSID" because tvOS has no SSID API; instead
                        // we point the user at the probe as the
                        // source of truth, with a nudge toward the
                        // Refresh button when it's stale.
                        if tvLANProbe.lastDetected {
                            Text("Local server reachable — streams will use local URL.")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        } else {
                            Text("Local server not reachable — streams will use remote URL. Tap Refresh LAN Detection after a network change.")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        }
                        #endif
                    }
                    .listRowBackground(Color.cardBackground)
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView().tint(.accentPrimary)
                            } else {
                                Image(systemName: "network")
                                    .foregroundColor(.accentPrimary)
                            }
                            Text(isTestingConnection ? "Testing..." : "Test Connection")
                                .foregroundColor(.accentPrimary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)

                    if let result = connectionResult {
                        HStack(spacing: 8) {
                            Image(systemName: connectionSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(connectionSuccess ? .statusOnline : .statusLive)
                            Text(result)
                                .font(.bodySmall)
                                .foregroundColor(connectionSuccess ? .statusOnline : .statusLive)
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("Actions").sectionHeaderStyle()
                }

                // MARK: EPG Cache (per-playlist)
                //
                // Per-playlist "nuke + re-fetch" action. Lives here
                // (instead of a single global toggle in Appearance)
                // so users with multiple playlists can scrub one
                // playlist's corrupted guide data without touching
                // the others. The SwiftData delete is filtered by
                // `EPGProgram.serverID == server.id`, and we only
                // call `ChannelStore.forceRefresh` when the purged
                // playlist is the active one — purging a non-active
                // playlist just clears the cache, and the next time
                // the user activates it the normal load path will
                // refetch fresh EPG data.
                Section {
                    Button(role: .destructive) {
                        showPurgeConfirmation = true
                    } label: {
                        HStack(spacing: 10) {
                            if isPurgingEPG {
                                ProgressView().scaleEffect(0.8)
                                    .frame(width: 14)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isPurgingEPG ? "Refreshing EPG Data…" : "Refresh EPG Data")
                                .font(.bodyMedium)
                            Spacer()
                        }
                        .foregroundColor(isPurgingEPG ? .textSecondary : .statusWarning)
                    }
                    .listRowBackground(Color.cardBackground)
                    .disabled(isPurgingEPG)
                } header: {
                    Text("EPG Cache").sectionHeaderStyle()
                } footer: {
                    Text(server.isActive
                         ? "Clears this playlist's cached guide data and downloads it fresh from the server. Use this if program cells look wrong or are missing. Takes a few minutes on large playlists."
                         : "Clears this playlist's cached guide data. The fresh fetch will run automatically the next time you make this playlist active.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            #else
            .listStyle(.plain)
            #endif
        }
        .navigationTitle(server.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        // Per-playlist EPG-purge confirmation. The action handler:
        //   1. Always calls `GuideStore.shared.purgePrograms(for:…)`
        //      to delete this playlist's EPGProgram rows on a
        //      background context.
        //   2. Only triggers `ChannelStore.shared.forceRefresh(...)`
        //      when this playlist is the active one — refreshing a
        //      non-active server would either no-op (forceRefresh
        //      bails on non-active first(where:isActive)) or, worse,
        //      hijack the user's currently-loaded data with a
        //      different server's payload. For non-active purges we
        //      just clear the cache and let the next activation
        //      refetch normally.
        .alert("Refresh EPG Data?", isPresented: $showPurgeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Refresh", role: .destructive) {
                Task {
                    isPurgingEPG = true
                    await GuideStore.shared.purgePrograms(
                        for: server.id.uuidString,
                        isActiveServer: server.isActive,
                        modelContext: modelContext
                    )
                    if server.isActive {
                        await ChannelStore.shared.forceRefresh(servers: Array(servers))
                    }
                    isPurgingEPG = false
                }
            }
        } message: {
            Text(server.isActive
                 ? "All cached guide data for \"\(server.name)\" will be cleared and reloaded from the server. This may take a few minutes on large playlists."
                 : "All cached guide data for \"\(server.name)\" will be cleared. The next time you make this playlist active, fresh guide data will load automatically.")
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

    private func testConnection() async {
        isTestingConnection = true
        connectionResult = nil
        do {
            switch server.type {
            case .xtreamCodes:
                let api = XtreamCodesAPI(baseURL: server.effectiveBaseURL, username: server.username, password: server.effectivePassword)
                _ = try await api.verifyConnection()
            case .dispatcharrAPI:
                // Re-verify with the persisted auth mode as the
                // starting hint — verifyConnection auto-falls-back if
                // the server now wants a different shape (e.g. user
                // upgraded Dispatcharr to a build with stricter auth).
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                         auth: .apiKey(server.effectiveApiKey),
                                         userAgent: server.effectiveUserAgent,
                                         authMode: server.dispatcharrHeaderMode)
                let info = try await api.verifyConnection()
                // v1.6.20: persist the discovered auth shape so
                // subsequent API calls and stream playback use it.
                if let mode = info.discoveredAuthMode,
                   mode.rawValue != server.dispatcharrAuthMode {
                    server.dispatcharrAuthMode = mode.rawValue
                    debugLog("SettingsView Test Connection: persisting auth mode .\(mode.rawValue) for \(server.name)")
                    // Immediate cross-device push so other devices on
                    // the same iCloud account inherit the working
                    // shape without waiting for the next debounce.
                    SyncManager.shared.pushServers(servers, immediate: true)
                }
            case .m3uPlaylist:
                guard let url = URL(string: server.baseURL) else { throw APIError.invalidURL }
                let (_, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
            }
            connectionSuccess = true
            connectionResult = "Connection successful"
        } catch let error as APIError {
            connectionSuccess = false
            connectionResult = error.errorDescription ?? "Unknown error"
        } catch {
            connectionSuccess = false
            connectionResult = error.localizedDescription
        }
        isTestingConnection = false
    }
}

// MARK: - Playlist List Row
struct PlaylistListRow: View {
    let playlist: M3UPlaylist

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentPrimary.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: playlist.sourceType == .url ? "link" : "doc.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.accentPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                HStack(spacing: 6) {
                    Text("\(playlist.channelCount) channels")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                    if let refreshed = playlist.lastRefreshed {
                        Text("·")
                            .foregroundColor(.textTertiary)
                        Text(refreshed, style: .relative)
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            Spacer()

            Circle()
                .fill(Color.statusOnline)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }
}

// AppearanceSettingsView is defined in AppearanceSettingsView.swift

// MARK: - Edit Playlist Sheet
struct EditPlaylistSheet: View {
    @Bindable var playlist: M3UPlaylist
    @Environment(\.dismiss) private var dismiss
    /// See SettingsView for rationale.
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                Form {
                    Section {
                        TextField("Name", text: $playlist.name)
                            .listRowBackground(Color.cardBackground)
                        if playlist.sourceType == .url {
                            TextField("URL", text: $playlist.urlString)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .listRowBackground(Color.cardBackground)
                        } else {
                            HStack {
                                Text("Source")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Text("Local file")
                                    .foregroundColor(.textTertiary)
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                    } header: {
                        Text("Playlist Details").sectionHeaderStyle()
                    }
                }
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
            }
            .navigationTitle("Edit Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.accentPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { dismiss() }
                        .foregroundColor(.accentPrimary)
                        .fontWeight(.semibold)
                        .disabled(playlist.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Edit Server Sheet
struct EditServerSheet: View {
    @Bindable var server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    /// See SettingsView for rationale.
    @ObservedObject private var theme = ThemeManager.shared

    // XMLTV validation state for the Dispatcharr EPG Source row. Mirrors
    // AddServerView's XMLTVTestState so the edit flow can also validate
    // before save.
    @State private var xmltvTestState: XMLTVEditTestState = .idle

    enum XMLTVEditTestState: Equatable {
        case idle
        case testing
        case success(Int)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                #if os(tvOS)
                tvOSEditContent
                #else
                iOSEditForm
                #endif
            }
            .navigationTitle("Edit Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.accentPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        SyncManager.shared.saveCredentialsSynced(for: server)
                        dismiss()
                    }
                    .foregroundColor(.accentPrimary)
                    .fontWeight(.semibold)
                    .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              server.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - iOS Form
    #if os(iOS)
    private var iOSEditForm: some View {
        Form {
            Section {
                TextField("Name", text: $server.name)
                    .listRowBackground(Color.cardBackground)
                TextField("URL", text: $server.baseURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .listRowBackground(Color.cardBackground)
            } header: {
                Text("Connection").sectionHeaderStyle()
            }

            if server.type == .xtreamCodes {
                Section {
                    TextField("Username", text: $server.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                    SecureField("Password", text: $server.password)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Credentials").sectionHeaderStyle()
                }
            } else if server.type == .dispatcharrAPI {
                Section {
                    SecureField("Admin API Key", text: $server.apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Authentication").sectionHeaderStyle()
                }
                Section {
                    // `Text(verbatim:)` (not the implicit
                    // `LocalizedStringKey` initializer) so the
                    // placeholder URL renders as plain gray
                    // placeholder text instead of getting
                    // Markdown-auto-linkified into a blue
                    // underlined hyperlink. The default
                    // `Text("https://...")` initializer parses
                    // its argument as a localized markdown
                    // string and SwiftUI's data-detector turns
                    // bare URL patterns into clickable
                    // `[autolink]` references — same on iOS
                    // and Mac Catalyst (user-reported v1.6.8).
                    TextField("Custom XMLTV URL (optional)",
                              text: $server.dispatcharrXMLTVURL,
                              prompt: Text(verbatim: "https://example.com/xmltv.xml"))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                        .onChange(of: server.dispatcharrXMLTVURL) { _, _ in
                            // Reset test result whenever the URL changes so
                            // a stale "Valid" pill doesn't mislead the user.
                            xmltvTestState = .idle
                        }

                    // Test button + status. Mirrors AddServerView's validation
                    // affordance so editing a server feels consistent with
                    // adding one.
                    HStack(spacing: 10) {
                        Button {
                            Task { await testEditXMLTVURL() }
                        } label: {
                            HStack(spacing: 6) {
                                if case .testing = xmltvTestState {
                                    ProgressView().tint(.accentPrimary).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "checkmark.seal")
                                }
                                Text("Test XMLTV URL")
                            }
                            .font(.labelMedium.weight(.semibold))
                            .foregroundColor(.accentPrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(editXMLTVTrimmed.isEmpty ||
                                  { if case .testing = xmltvTestState { return true } else { return false } }())

                        xmltvEditStatusPill

                        Spacer(minLength: 0)
                    }
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("EPG Source").sectionHeaderStyle()
                } footer: {
                    Text("Override the XMLTV source AerioTV pulls EPG from. Leave blank to use Dispatcharr's own XMLTV output at /output/epg (the default). Set only if you want to bypass Dispatcharr and fetch XMLTV straight from your upstream provider.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            } else if server.type == .m3uPlaylist {
                Section {
                    TextField("EPG URL (optional)", text: $server.epgURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("EPG Guide").sectionHeaderStyle()
                }
            }

            if server.type != .m3uPlaylist {
                Section {
                    TextField("Local URL", text: $server.localURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Local Network").sectionHeaderStyle()
                } footer: {
                    Text("Used when connected to a home WiFi network. Add your home network SSIDs in Settings → Network → Home WiFi. Leave blank to always use the main URL.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }

            if server.type == .dispatcharrAPI {
                Section {
                    TextField("User-Agent", text: $server.customUserAgent,
                              prompt: Text(DeviceInfo.defaultUserAgent))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                    Button("Reset to Default") {
                        server.customUserAgent = ""
                    }
                    .foregroundColor(.accentPrimary)
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("User-Agent").sectionHeaderStyle()
                } footer: {
                    Text("Shown in Dispatcharr's admin Stats panel to identify this device. Default: \(DeviceInfo.defaultUserAgent)")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }

            // v1.6.12: per-server VOD toggle. Only shown for server
            // types that actually support VOD — M3U-only playlists
            // don't carry it.
            if server.supportsVOD {
                Section {
                    Toggle("Fetch VOD from this playlist", isOn: $server.vodEnabled)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Content").sectionHeaderStyle()
                } footer: {
                    Text("When off, this playlist's movies and TV shows aren't loaded into the On Demand tab. Useful when you have a \"sandbox\" playlist for testing — keep its Live TV channels but skip the (sometimes massive) VOD library.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }

            Section {
                HStack {
                    Text("Type")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(server.type.displayName)
                        .foregroundColor(.textTertiary)
                }
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Info").sectionHeaderStyle()
            }
        }
        .scrollContentBackground(.hidden)
    }
    #endif

    // MARK: - tvOS Layout
    #if os(tvOS)
    private var tvOSEditContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Connection
                tvEditSection("Connection") {
                    tvEditField("Name", text: $server.name)
                    tvEditField("URL", text: $server.baseURL)
                }

                // Credentials
                if server.type == .xtreamCodes {
                    tvEditSection("Credentials") {
                        tvEditField("Username", text: $server.username)
                        tvEditField("Password", text: $server.password, isSecure: true)
                    }
                } else if server.type == .dispatcharrAPI {
                    Group {
                        tvEditSection("Authentication") {
                            tvEditField("Admin API Key", text: $server.apiKey, isSecure: true)
                        }
                        tvEditSection("EPG Source") {
                            tvEditField("Custom XMLTV URL (optional)", text: $server.dispatcharrXMLTVURL)
                            Text("Override the XMLTV source AerioTV pulls EPG from. Leave blank to use Dispatcharr's own XMLTV output at /output/epg (the default, with category data).")
                                .font(.system(size: 22))
                                .foregroundColor(.textTertiary)
                                .padding(.top, 4)
                        }
                    }
                } else if server.type == .m3uPlaylist {
                    tvEditSection("EPG Guide") {
                        tvEditField("EPG URL (optional)", text: $server.epgURL)
                    }
                }

                // Local Network
                if server.type != .m3uPlaylist {
                    tvEditSection("Local Network") {
                        tvEditField("Local URL", text: $server.localURL)
                        Text("Used when the Apple TV detects the local server is reachable. Leave blank to always use the main URL.")
                            .font(.system(size: 22))
                            .foregroundColor(.textTertiary)
                            .padding(.top, 4)
                    }
                }

                // User-Agent (Dispatcharr only)
                if server.type == .dispatcharrAPI {
                    tvEditSection("User-Agent") {
                        tvEditField("User-Agent", text: $server.customUserAgent)
                        Text("Shown in Dispatcharr's admin Stats panel. Leave blank for default: \(DeviceInfo.defaultUserAgent)")
                            .font(.system(size: 22))
                            .foregroundColor(.textTertiary)
                            .padding(.top, 4)
                    }
                }

                // v1.6.12: per-server VOD toggle. Mirrors the iOS
                // edit form's "Content" section. Hidden for M3U-only
                // playlists since they don't carry VOD anyway.
                if server.supportsVOD {
                    tvEditSection("Content") {
                        Toggle("Fetch VOD from this playlist", isOn: $server.vodEnabled)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.textPrimary)
                            .padding(.vertical, 4)
                        Text("When off, this playlist's movies and TV shows aren't loaded into the On Demand tab. Useful when you have a \"sandbox\" playlist for testing — keep its Live TV channels but skip the (sometimes massive) VOD library.")
                            .font(.system(size: 22))
                            .foregroundColor(.textTertiary)
                            .padding(.top, 4)
                    }
                }

                // Info
                tvEditSection("Info") {
                    HStack {
                        Text("Type")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text(server.type.displayName)
                            .font(.system(size: 28))
                            .foregroundColor(.textTertiary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(48)
        }
    }

    private func tvEditSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textTertiary)
                .tracking(1)
            VStack(spacing: 16) {
                content()
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cardBackground)
            )
        }
    }

    private func tvEditField(_ placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(placeholder)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.textTertiary)
            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28))
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.elevatedBackground)
                    )
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28))
                    .foregroundColor(.textPrimary)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.elevatedBackground)
                    )
            }
        }
    }
    #endif

    // MARK: - XMLTV Edit Test Helpers (iOS only — tvOS editor omits the button)

    #if os(iOS)
    private var editXMLTVTrimmed: String {
        server.dispatcharrXMLTVURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var xmltvEditStatusPill: some View {
        switch xmltvTestState {
        case .idle, .testing:
            EmptyView()
        case .success(let count):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.statusOnline)
                Text(count > 0 ? "Valid — \(count) programs" : "Valid XMLTV")
                    .font(.labelSmall.weight(.semibold))
                    .foregroundColor(.statusOnline)
                    .lineLimit(1)
            }
        case .failure(let err):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.statusLive)
                Text(err)
                    .font(.labelSmall)
                    .foregroundColor(.statusLive)
                    .lineLimit(2)
            }
        }
    }

    @MainActor
    private func testEditXMLTVURL() async {
        let urlString = editXMLTVTrimmed
        guard !urlString.isEmpty else { return }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            xmltvTestState = .failure("URL must start with http:// or https://")
            return
        }
        xmltvTestState = .testing
        do {
            let programs = try await XMLTVParser.fetchAndParse(url: url)
            xmltvTestState = .success(programs.count)
        } catch {
            let raw = error.localizedDescription
            let trimmed = raw.count > 120 ? String(raw.prefix(120)) + "…" : raw
            xmltvTestState = .failure(trimmed.isEmpty ? "Couldn't parse as XMLTV" : trimmed)
        }
    }
    #endif
}


// MARK: - tvOS Edit Server (full page, no modal)
#if os(tvOS)
struct EditServerPage: View {
    @Bindable var server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    /// See SettingsView. Tvos edit page uses accent-tinted Save
    /// button + form field underlines; without this they freeze at
    /// whichever theme was active when the page was first pushed.
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    // Connection
                    tvSection("Connection") {
                        tvField("Name", text: $server.name)
                        tvField("URL", text: $server.baseURL)
                    }

                    // Credentials
                    if server.type == .xtreamCodes {
                        tvSection("Credentials") {
                            tvField("Username", text: $server.username)
                            tvField("Password", text: $server.password, isSecure: true)
                        }
                    } else if server.type == .dispatcharrAPI {
                        Group {
                            tvSection("Authentication") {
                                tvField("Admin API Key", text: $server.apiKey, isSecure: true)
                            }
                            tvSection("EPG Source") {
                                tvField("Custom XMLTV URL (optional)", text: $server.dispatcharrXMLTVURL)
                                Text("Override the XMLTV source AerioTV pulls EPG from. Leave blank to use Dispatcharr's own XMLTV output at /output/epg (the default, with category data).")
                                    .font(.system(size: 22))
                                    .foregroundColor(.textTertiary)
                                    .padding(.top, 4)
                            }
                        }
                    } else if server.type == .m3uPlaylist {
                        tvSection("EPG Guide") {
                            tvField("EPG URL (optional)", text: $server.epgURL)
                        }
                    }

                    // Local Network
                    if server.type != .m3uPlaylist {
                        tvSection("Local Network") {
                            tvField("Local URL", text: $server.localURL)
                            Text("Used when the Apple TV detects the local server is reachable. Leave blank to always use the main URL.")
                                .font(.system(size: 22))
                                .foregroundColor(.textTertiary)
                                .padding(.top, 4)
                        }
                    }

                    // Info
                    tvSection("Info") {
                        HStack {
                            Text("Type")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Text(server.type.displayName)
                                .font(.system(size: 28))
                                .foregroundColor(.textTertiary)
                        }
                        .padding(.vertical, 8)
                    }

                    // Save
                    HStack {
                        Spacer()
                        Button {
                            SyncManager.shared.saveCredentialsSynced(for: server)
                            dismiss()
                        } label: {
                            Text("Save Changes")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 14)
                                .background(LinearGradient.accentGradient)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(TVNoHighlightButtonStyle())
                        .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  server.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                    }
                    .padding(.top, 16)
                }
                .padding(48)
            }
        }
        .navigationTitle("Edit Playlist")
        .toolbar(.hidden, for: .navigationBar)
    }

    private func tvSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textTertiary)
                .tracking(1)
            VStack(spacing: 16) {
                content()
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cardBackground)
            )
        }
    }

    private func tvField(_ placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(placeholder)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.textTertiary)
            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28))
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.elevatedBackground)
                    )
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28))
                    .foregroundColor(.textPrimary)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.elevatedBackground)
                    )
            }
        }
    }
}
#endif

// MARK: - Buffer size options
private struct BufferOption: Identifiable {
    let id: String
    let label: String
    let detail: String  // human-readable size
    let cachingMs: Int  // VLC :network-caching value in milliseconds
}
private let bufferOptions: [BufferOption] = [
    BufferOption(id: "small",   label: "Small",       detail: "300 ms — fast, stable networks",   cachingMs: 300),
    BufferOption(id: "default", label: "Default",     detail: "1 second — recommended",           cachingMs: 1_000),
    BufferOption(id: "large",   label: "Large",       detail: "3 seconds — unstable connections", cachingMs: 3_000),
    BufferOption(id: "xlarge",  label: "Extra Large", detail: "8 seconds — very poor networks",   cachingMs: 8_000),
]


struct NetworkSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    #if os(iOS)
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var ssidEntries: [String] = []
    @State private var ssidRefreshed = false
    #endif
    @AppStorage("networkTimeout")          private var networkTimeout      = 15.0
    @AppStorage("maxRetries")              private var maxRetries          = 3
    @AppStorage("streamBufferSize")        private var streamBufferSize    = "default"
    @AppStorage("epgWindowHours")           private var epgWindowHours      = 36          // default 36 hours
    /// Tint EPG program cells by their category (Sports / Movies /
    /// Kids / News). Mirrors the `CategoryColor.enabledKey` constant
    /// — default `true`, so the category palette is on out of the box
    /// and users who prefer the flat neutral cells can disable it here.
    @AppStorage(CategoryColor.enabledKey)   private var enableCategoryColors = true
    /// Companion toggle that extends the category palette from the EPG
    /// guide cells to the Live TV channel cards. Opt-in and default off
    /// so existing users don't suddenly see colored stripes appear on every row.
    @AppStorage("tintChannelCards")         private var tintChannelCards     = false
    /// User-controllable scale factor applied to the EPG grid layout
    /// (cell width, row height, header height, pixels-per-hour, and
    /// per-cell font sizes). Range 0.75…1.5 in 0.05 increments,
    /// default 1.0 (today's "100%" sizing). Read by `EPGGuideView` and
    /// `GuideProgramButton` via the same `"guideScale"` key. Only
    /// surfaced on iPad and Mac — iPhone uses the list view, tvOS uses
    /// the Siri Remote which makes a slider awkward.
    @AppStorage("guideScale")              private var guideScale          = 1.0
    @AppStorage("bgRefreshEnabled")        private var bgRefreshEnabled    = false
    @AppStorage("bgRefreshType")           private var bgRefreshType       = "interval"  // "interval" or "time"
    @AppStorage("bgRefreshIntervalMins")   private var bgRefreshInterval   = 1440        // 24 hours
    @AppStorage("bgRefreshHour")           private var bgRefreshHour       = 8
    @AppStorage("bgRefreshMinute")         private var bgRefreshMinute     = 0

    // Converts stored hour/minute back to a Date for DatePicker binding
    private var refreshTimeDateBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour   = bgRefreshHour
                comps.minute = bgRefreshMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                let comps      = Calendar.current.dateComponents([.hour, .minute], from: date)
                bgRefreshHour   = comps.hour   ?? 8
                bgRefreshMinute = comps.minute ?? 0
            }
        )
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("Network")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        #if os(iOS)
        .task {
            // Intentionally NOT auto-calling `NetworkMonitor.refresh(force: true)`
            // here — a user opening Network Settings shouldn't trigger
            // an iOS Location prompt on their way to toggling a setting
            // that may have nothing to do with WiFi. The "Refresh SSID
            // Detection" button below is the explicit, context-aware
            // way to ask for Location. Cached SSID (if any) still
            // renders via `networkMonitor.currentSSID`.
            let stored = UserDefaults.standard.string(forKey: "globalHomeSSIDs") ?? ""
            let parsed = stored.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            ssidEntries = parsed.isEmpty ? [""] : parsed
        }
        #endif
    }

    // MARK: - tvOS Body
    // Uses the shared TVSettings* components so focus highlights match
    // Appearance / DVR / Developer / top-level Settings uniformly. The
    // previous implementation was a bare List + Button rows which on
    // tvOS only rendered the default thin system focus ring.
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvSection("Request Timeout") {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { secs in
                        TVSettingsSelectionRow(
                            label: "\(secs) seconds",
                            isSelected: Int(networkTimeout) == secs,
                            action: { networkTimeout = Double(secs) }
                        )
                    }
                }

                tvSection("Buffer Size") {
                    ForEach(bufferOptions) { opt in
                        TVSettingsSelectionRow(
                            label: opt.label,
                            subtitle: opt.detail,
                            isSelected: streamBufferSize == opt.id,
                            action: { streamBufferSize = opt.id }
                        )
                    }
                }

                tvSection("EPG Window") {
                    let options: [(label: String, hours: Int)] = [
                        ("6 hours",  6),
                        ("12 hours", 12),
                        ("24 hours", 24),
                        ("36 hours", 36),
                        ("48 hours", 48),
                        ("72 hours", 72),
                        ("All available", 0),
                    ]
                    ForEach(options, id: \.hours) { opt in
                        TVSettingsSelectionRow(
                            label: opt.label,
                            isSelected: epgWindowHours == opt.hours,
                            action: { epgWindowHours = opt.hours }
                        )
                    }
                }

                // Category-colour palette + EPG cache controls moved
                // to `AppearanceSettingsView` in v1.6.8 — Settings →
                // App Settings → Appearance — alongside the theme +
                // scale sliders, since they're all visual concerns.
            }
            .padding(48)
        }
    }

    private func tvSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textTertiary)
                .tracking(1)
                .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }
    #endif

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
                // MARK: Connection
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Request Timeout")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Text("\(Int(networkTimeout))s")
                                .font(.monoSmall)
                                .foregroundColor(theme.accent)
                        }
                        Slider(value: $networkTimeout, in: 5...60, step: 5)
                            .tint(theme.accent)
                    }
                    .listRowBackground(Color.cardBackground)

                    Stepper("Max Retries: \(maxRetries)", value: $maxRetries, in: 0...10)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Connection").sectionHeaderStyle()
                } footer: {
                    Text("Adjust timeouts if you have a slow connection.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }

                // MARK: Buffer Size
                Section {
                    ForEach(bufferOptions) { opt in
                        Button {
                            streamBufferSize = opt.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.label)
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    Text(opt.detail)
                                        .font(.labelSmall)
                                        .foregroundColor(.textSecondary)
                                }
                                Spacer()
                                if streamBufferSize == opt.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("Buffer Size").sectionHeaderStyle()
                } footer: {
                    Text("Controls how much stream data is pre-loaded. Larger buffers reduce stuttering on poor connections but add startup delay.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }

                // MARK: EPG Window
                Section {
                    let options: [(label: String, hours: Int)] = [
                        ("6 hours",  6),
                        ("12 hours", 12),
                        ("24 hours", 24),
                        ("36 hours", 36),
                        ("48 hours", 48),
                        ("72 hours", 72),
                        ("All available", 0),
                    ]
                    ForEach(options, id: \.hours) { opt in
                        Button {
                            epgWindowHours = opt.hours
                        } label: {
                            HStack {
                                Text(opt.label)
                                    .font(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                if epgWindowHours == opt.hours {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("EPG Window").sectionHeaderStyle()
                } footer: {
                    Text("How far ahead to download program guide data. Larger windows take longer to download but show more upcoming programs.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }

                // Category-colour palette + EPG cache controls moved
                // to `AppearanceSettingsView` in v1.6.8 — Settings →
                // App Settings → Appearance. They were originally
                // here under Network, then briefly had their own
                // top-level "Guide Display" page; consolidating into
                // Appearance removes the duplication and matches the
                // user's mental model (visual customisation in one
                // place).

                // MARK: Home WiFi (LAN Switching)
                #if os(iOS)
                Section {
                    // Detected network status
                    HStack {
                        Text("Detected Network")
                            .font(.bodyMedium)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        if networkMonitor.isRefreshing {
                            ProgressView().tint(.accentPrimary).scaleEffect(0.8)
                        } else if let ssid = networkMonitor.currentSSID {
                            Label(ssid, systemImage: "wifi")
                                .font(.monoSmall)
                                .foregroundColor(.statusOnline)
                        } else if networkMonitor.isOnWifi {
                            Label("Unknown", systemImage: "wifi.exclamationmark")
                                .font(.labelSmall)
                                .foregroundColor(.statusWarning)
                        } else {
                            Text("Not on WiFi")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)

                    // Refresh button
                    Button {
                        ssidRefreshed = false
                        NetworkMonitor.shared.refresh(force: true)
                    } label: {
                        HStack(spacing: 8) {
                            if networkMonitor.isRefreshing {
                                ProgressView().tint(.accentPrimary).scaleEffect(0.8)
                            } else {
                                Image(systemName: ssidRefreshed ? "checkmark.circle.fill" : "wifi.circle")
                                    .foregroundColor(ssidRefreshed ? .statusOnline : .accentPrimary)
                            }
                            Text(networkMonitor.isRefreshing ? "Detecting…"
                                 : ssidRefreshed ? "Up to date"
                                 : "Refresh Detection")
                                .foregroundColor(networkMonitor.isRefreshing ? .textSecondary
                                                 : ssidRefreshed ? .statusOnline : .accentPrimary)
                        }
                    }
                    .disabled(networkMonitor.isRefreshing)
                    .listRowBackground(Color.cardBackground)
                    .onChange(of: networkMonitor.isRefreshing) { _, nowRefreshing in
                        if !nowRefreshing {
                            ssidRefreshed = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                ssidRefreshed = false
                            }
                        }
                    }

                    // When the device is on WiFi but SSID came back nil, the
                    // user almost certainly hasn't granted Location (Precise).
                    // Surface a one-tap deep-link to iOS Settings so they don't
                    // have to hand-walk Privacy → Location Services → Aerio.
                    if networkMonitor.isOnWifi && networkMonitor.currentSSID == nil && !networkMonitor.isRefreshing {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Grant Location Access in Settings", systemImage: "location.circle")
                                .foregroundColor(.accentPrimary)
                        }
                        .listRowBackground(Color.cardBackground)
                    }

                    // SSID list
                    ForEach(ssidEntries.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            Image(systemName: !ssidEntries[index].isEmpty && networkMonitor.currentSSID == ssidEntries[index]
                                  ? "checkmark.circle.fill" : "wifi")
                                .foregroundColor(!ssidEntries[index].isEmpty && networkMonitor.currentSSID == ssidEntries[index]
                                                 ? .statusOnline : .textTertiary)
                                .font(.system(size: 16))
                            TextField("Home WiFi SSID \(index + 1)", text: $ssidEntries[index])
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if ssidEntries.count > 1 {
                                Button {
                                    ssidEntries.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.system(size: 20))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }

                    if ssidEntries.count < 5 {
                        if let currentSSID = networkMonitor.currentSSID,
                           !ssidEntries.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == currentSSID }) {
                            Button {
                                if let emptyIndex = ssidEntries.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                                    ssidEntries[emptyIndex] = currentSSID
                                } else {
                                    ssidEntries.append(currentSSID)
                                }
                            } label: {
                                Label("Add \"\(currentSSID)\"", systemImage: "wifi.circle.fill")
                                    .foregroundColor(.statusOnline)
                            }
                            .listRowBackground(Color.cardBackground)
                        }

                        Button {
                            ssidEntries.append("")
                        } label: {
                            Label("Add Network Manually", systemImage: "plus.circle.fill")
                                .foregroundColor(.accentPrimary)
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("Home WiFi (LAN Switching)").sectionHeaderStyle()
                } footer: {
                    if networkMonitor.isOnWifi && networkMonitor.currentSSID == nil {
                        Text("⚠️ Wi-Fi detected but network name unavailable. To detect your Home WiFi, grant Aerio Location access: open the iOS Settings app → Privacy & Security → Location Services → Aerio → choose \"While Using the App\" and enable Precise Location.")
                            .font(.labelSmall).foregroundColor(.statusWarning)
                    } else {
                        Text("When connected to any of these networks, AerioTV uses each server's local URL instead of its remote URL. Set each server's local URL in Settings → Playlists → [server] → Edit.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
                .onChange(of: ssidEntries) { _, new in
                    UserDefaults.standard.set(
                        new.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                           .filter { !$0.isEmpty }
                           .joined(separator: ","),
                        forKey: "globalHomeSSIDs"
                    )
                }
                #endif

                // MARK: Background Refresh
                Section {
                    Toggle(isOn: $bgRefreshEnabled) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundColor(theme.accent)
                                .font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Background Refresh")
                                    .font(.bodyMedium).foregroundColor(.textPrimary)
                                Text("Update EPG & playlists automatically")
                                    .font(.labelSmall).foregroundColor(.textSecondary)
                            }
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)

                    if bgRefreshEnabled {
                        // Refresh type picker
                        Picker("Refresh by", selection: $bgRefreshType) {
                            Text("Every…").tag("interval")
                            Text("At time").tag("time")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.cardBackground)

                        if bgRefreshType == "interval" {
                            // Interval picker
                            let intervals: [(label: String, mins: Int)] = [
                                ("15 minutes", 15), ("30 minutes", 30),
                                ("1 hour", 60),     ("2 hours", 120),
                                ("4 hours", 240),   ("8 hours", 480),
                                ("12 hours", 720),  ("24 hours", 1440),
                            ]
                            ForEach(intervals, id: \.mins) { item in
                                Button {
                                    bgRefreshInterval = item.mins
                                } label: {
                                    HStack {
                                        Text(item.label)
                                            .font(.bodyMedium).foregroundColor(.textPrimary)
                                        Spacer()
                                        if bgRefreshInterval == item.mins {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(theme.accent)
                                                .font(.system(size: 14, weight: .semibold))
                                        }
                                    }
                                }
                                .listRowBackground(Color.cardBackground)
                            }
                        } else {
                            // Specific time picker (12-hour format with AM/PM)
                            #if os(iOS)
                            DatePicker(
                                "Refresh at",
                                selection: refreshTimeDateBinding,
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.graphical)
                            .environment(\.locale, Locale(identifier: "en_US"))
                            .tint(theme.accent)
                            .foregroundColor(.textPrimary)
                            .listRowBackground(Color.cardBackground)
                            #endif
                        }
                    }
                } header: {
                    Text("Background Refresh").sectionHeaderStyle()
                } footer: {
                    if bgRefreshEnabled {
                        let desc = bgRefreshType == "interval"
                            ? "Refresh every \(intervalLabel(bgRefreshInterval))."
                            : "Refresh daily at \(timeLabel(hour: bgRefreshHour, minute: bgRefreshMinute))."
                        Text("\(desc) iOS may delay or skip background refreshes to preserve battery.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    } else {
                        Text("Automatically refresh channel lists and guide data while the app is in the background.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
    }
    #endif

    private func intervalLabel(_ mins: Int) -> String {
        if mins < 60 { return "\(mins) minutes" }
        let h = mins / 60
        return h == 1 ? "1 hour" : "\(h) hours"
    }

    private func timeLabel(hour: Int, minute: Int) -> String {
        let h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let ampm = hour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h12, minute, ampm)
    }
}

// MARK: - Category Color Picker Row (iOS only)
//
// One row in Settings → Appearance (Palette section) that binds a SwiftUI
// `ColorPicker` to the hex-string stored at the bucket's
// `storageKey`. The binding converts between `Color` (what
// ColorPicker speaks) and the hex string (what UserDefaults
// persists). `@AppStorage` observes the underlying key, so any
// open guide view re-renders its cells the moment the user lifts
// their finger off the ColorPicker's eyedropper — no apply
// button needed.
//
// tvOS is intentionally excluded: the system ColorPicker on tvOS
// is awkward (two-axis hue/saturation grid with Siri Remote
// trackpad). We surface only the on/off toggle there and point
// users to iPhone/iPad for palette customisation.
#if os(iOS)
struct CategoryColorPickerRow: View {
    let category: ProgramCategory

    /// Bound to the UserDefaults-backed hex string via
    /// `@AppStorage`. When the user picks a new colour in the
    /// system picker, SwiftUI writes it here (as hex), which in
    /// turn triggers every observer of the same key to re-render
    /// — including every `GuideProgramButton.cellBackground`
    /// via the existing `@AppStorage` wiring on the cell.
    @AppStorage private var storedHex: String

    init(category: ProgramCategory) {
        self.category = category
        // Seed the @AppStorage with the category's default hex
        // when the key is missing, so the ColorPicker shows the
        // current effective colour on first render. Writing the
        // default here is fine because `.onChange` is idempotent
        // and `resetPaletteToDefaults()` removes the key
        // explicitly.
        self._storedHex = AppStorage(
            wrappedValue: category.defaultHex,
            category.storageKey
        )
    }

    /// Two-way bridge between the hex string (persistence) and
    /// `Color` (ColorPicker's required binding type).
    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: storedHex) },
            set: { newColor in
                let hex = newColor.toHex()
                // Skip no-op writes to avoid a pointless
                // UserDefaults change notification that would
                // still trigger observers.
                if hex != storedHex { storedHex = hex }
            }
        )
    }

    var body: some View {
        ColorPicker(selection: colorBinding, supportsOpacity: false) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: storedHex).opacity(0.22))
                        .frame(width: 36, height: 36)
                    Image(systemName: category.sfSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: storedHex))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.displayName)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                    Text("Default: #\(category.defaultHex)")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }
        }
        // Palette picks are deliberate user actions — push to iCloud
        // right away instead of waiting for the 60-second debounced
        // preferences push. Same rationale as FavoritesStore: force-
        // quitting the app inside the debounce window would otherwise
        // drop the change on the floor and the next launch would
        // re-import the stale palette from KVS.
        .onChange(of: storedHex) { _, _ in
            SyncManager.shared.pushPreferencesImmediate()
        }
    }
}
#endif

// MARK: - More Categories View
//
// Disclosure target for "Add more categories" in the Appearance
// settings screen (Palette section). Presents the seven additional
// built-in buckets
// (Documentary / Drama / Comedy / Reality / Educational / Sci-Fi /
// Music) with an enable toggle + color picker on each row, plus a
// "Custom" navigation link for user-defined category → color
// mappings. Default buckets stay on the parent screen.
#if os(iOS)
struct MoreCategoriesView: View {
    @ObservedObject private var theme = ThemeManager.shared
    /// Bumped whenever a toggle flips so SwiftUI re-renders the
    /// disabled-state opacity + the upstream summary row. Writes
    /// to UserDefaults go through `CategoryColor.setBucketEnabled`
    /// which doesn't fire an @AppStorage notification (the key is
    /// dynamic), so we nudge the view manually.
    @State private var enabledRevision: Int = 0

    var body: some View {
        List {
            Section {
                ForEach(CategoryColor.additionalBuckets, id: \.rawValue) { cat in
                    additionalBucketRow(cat)
                        .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Additional Buckets").sectionHeaderStyle()
            } footer: {
                Text("Toggle a bucket on to include its aliases in the matcher. Defaults cover Sports, Movies, Kids, and News — these are extras for feeds that heavily tag Documentary, Drama, Sitcoms, etc.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }

            Section {
                NavigationLink {
                    CustomCategoriesView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paintbrush.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom").font(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Define your own category strings and colors")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                        }
                        Spacer()
                        Text("\(CategoryColor.loadCustomCategories().count)")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("User-Defined").sectionHeaderStyle()
            } footer: {
                Text("Custom entries are checked before the built-in buckets, so you can override a match like \"Horror\" or \"Cooking\" with your own color even if a built-in bucket would have caught it.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("More Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    @ViewBuilder
    private func additionalBucketRow(_ cat: ProgramCategory) -> some View {
        let isOn = Binding(
            get: { CategoryColor.isBucketEnabled(cat) },
            set: { newValue in
                CategoryColor.setBucketEnabled(cat, newValue)
                enabledRevision &+= 1
                SyncManager.shared.pushPreferencesImmediate()
            }
        )
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(cat.baseColor.opacity(isOn.wrappedValue ? 0.8 : 0.3))
                        .frame(width: 28, height: 28)
                    Image(systemName: cat.sfSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.displayName)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                    // "Customize color" shown regardless of toggle
                    // state — the user reported that hiding it on
                    // off made the nav-link feel like it "disappeared"
                    // after flipping the toggle off. Users are free
                    // to edit the color even when the bucket isn't
                    // actively matching; this just pre-stages the
                    // color for when they eventually enable it.
                    NavigationLink {
                        SingleCategoryColorEditor(category: cat)
                    } label: {
                        Text("Customize color")
                            .font(.labelSmall)
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(theme.accent)
    }
}

// MARK: - Single Category Color Editor
//
// Standalone color picker for one additional bucket, reached via
// the "Customize color" label inside MoreCategoriesView. Mirrors
// the CategoryColorPickerRow behaviour — same hex + color well +
// reset + sync — but in its own screen so the toggles list above
// stays scannable.
struct SingleCategoryColorEditor: View {
    let category: ProgramCategory
    @State private var storedHex: String = ""

    private var currentColor: Binding<Color> {
        Binding(
            get: { Color(hex: storedHex.isEmpty ? category.defaultHex : storedHex) },
            set: { newColor in
                let hex = newColor.toHex()
                storedHex = hex
                category.setCustomHex(hex)
                SyncManager.shared.pushPreferencesImmediate()
            }
        )
    }

    var body: some View {
        List {
            Section {
                ColorPicker(category.displayName, selection: currentColor, supportsOpacity: false)
                    .listRowBackground(Color.cardBackground)
                HStack {
                    Text("Hex")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(storedHex.isEmpty ? category.defaultHex : storedHex)
                        .font(.monoSmall)
                        .foregroundColor(.textTertiary)
                }
                .listRowBackground(Color.cardBackground)

                Button(role: .destructive) {
                    category.setCustomHex(nil)
                    storedHex = ""
                    SyncManager.shared.pushPreferencesImmediate()
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Reset to Default")
                    }
                    .foregroundColor(.statusWarning)
                }
                .listRowBackground(Color.cardBackground)
            } footer: {
                Text("Applies wherever a program's category matches one of this bucket's aliases in the EPG (see alias list in CategoryColor.swift).")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(category.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .onAppear {
            storedHex = UserDefaults.standard.string(forKey: category.storageKey) ?? ""
        }
    }
}

// MARK: - Custom Categories View
//
// User-defined string → color mappings. Each entry is a case-
// insensitive substring matched against the program's raw
// `<category>` value, with its own hex. Custom entries win over
// built-in buckets (see `CategoryColor.customHex(for:)`). Stored
// as a JSON array in UserDefaults under
// `CategoryColor.customCategoriesKey` and mirrored via SyncManager.
struct CustomCategoriesView: View {
    @State private var entries: [CategoryColor.CustomCategory] = []
    @State private var showAddSheet = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No custom categories yet")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Tap + above to add a match string (e.g. \"Horror\") and pick a color. Custom entries win over the built-in buckets.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.cardBackground)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink {
                            CustomCategoryEditor(
                                entry: entry,
                                onSave: { updated in
                                    if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
                                        entries[idx] = updated
                                        persist()
                                    }
                                },
                                onDelete: {
                                    entries.removeAll { $0.id == entry.id }
                                    persist()
                                }
                            )
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(hex: entry.hex))
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.match)
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    Text(entry.hex)
                                        .font(.monoSmall)
                                        .foregroundColor(.textTertiary)
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                    .onDelete { indexSet in
                        entries.remove(atOffsets: indexSet)
                        persist()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Custom Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                CustomCategoryEditor(
                    entry: CategoryColor.CustomCategory(match: "", hex: "FF5722"),
                    isNew: true,
                    onSave: { new in
                        entries.append(new)
                        persist()
                        showAddSheet = false
                    },
                    onDelete: { showAddSheet = false }
                )
            }
        }
        .onAppear {
            entries = CategoryColor.loadCustomCategories()
        }
    }

    private func persist() {
        CategoryColor.saveCustomCategories(entries)
        SyncManager.shared.pushPreferencesImmediate()
    }
}

// MARK: - Custom Category Editor
//
// Used both for adding a new entry (presented as a sheet from the
// "+" toolbar button) and editing an existing one (pushed as a
// nav link). Validates the match string is non-empty before save;
// hex is always valid because it comes from ColorPicker.
struct CustomCategoryEditor: View {
    @State var entry: CategoryColor.CustomCategory
    var isNew: Bool = false
    let onSave: (CategoryColor.CustomCategory) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: entry.hex) },
            set: { entry.hex = $0.toHex() }
        )
    }

    var body: some View {
        List {
            Section {
                TextField("Match string (e.g. Horror)", text: $entry.match)
                    .listRowBackground(Color.cardBackground)
                    .autocorrectionDisabled()
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .listRowBackground(Color.cardBackground)
                HStack {
                    Text("Hex")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(entry.hex)
                        .font(.monoSmall)
                        .foregroundColor(.textTertiary)
                }
                .listRowBackground(Color.cardBackground)
            } footer: {
                Text("Matching is case-insensitive and uses `contains` — entering \"Horror\" will colour any program whose XMLTV category includes the word horror.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }

            if !isNew {
                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .foregroundColor(.statusLive)
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(isNew ? "New Custom Category" : "Edit Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isNew ? "Add" : "Save") {
                    let trimmed = entry.match.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    var saved = entry
                    saved.match = trimmed
                    onSave(saved)
                    dismiss()
                }
                .disabled(entry.match.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
#endif

#if os(tvOS)
// MARK: - tvOS Menu-button pop support
//
// MainTabView's `.onExitCommand { handleMenuPress() }` on the outer
// TabView intercepts every Menu press before the inner NavigationStack
// (or any per-destination `.onExitCommand`) can react. That's the
// documented behaviour on tvOS and the reason
// `isVODDetailPushed`/`vodNavPopRequested` exist for the VOD detail
// pane. Settings needs the same pattern: MainTabView must know when a
// Settings subview is pushed, and it must have a way to request a pop
// from the outside. We expose both via bindings (see SettingsView's
// `isSubviewPushed` / `popRequested`).
//
// Pop sources we have to cover:
//   1. `navPath` pushes — Appearance, Network, DVR, Developer,
//      Edit Server. `navPath.count > 0` detects these;
//      `navPath.removeLast()` pops them.
//   2. Classic `NavigationLink(destination:)` pushes — ServerDetailView
//      (from the Settings root via TVSettingsNavRow) and
//      MyRecordingsView (pushed from inside DVRSettingsView via
//      TVSettingsNavRow). These bypass `navPath` entirely, so we track
//      them with a LIFO stack of dismiss actions registered on appear
//      and unregistered on disappear.
//
// When MainTabView sets `popRequested = true`, SettingsView prefers
// popping the classic stack first (LIFO, innermost wins) and falls
// back to `navPath.removeLast()` when the classic stack is empty.

@MainActor
final class SettingsDismissStack: ObservableObject {
    /// LIFO stack of registered classic-pushed destinations. Keyed by
    /// a per-view UUID so we can unregister reliably even if appears
    /// and disappears interleave during a transition.
    private var entries: [(id: UUID, dismiss: () -> Void)] = []

    /// Mirrors `entries.count`. Published so SettingsView can react
    /// via `.onReceive`.
    @Published fileprivate(set) var depth: Int = 0

    func register(id: UUID, dismiss: @escaping () -> Void) {
        // Replace any existing entry for this id so re-registrations
        // (e.g. onAppear firing again after a view re-mount) don't
        // duplicate. Keep stack order stable by leaving the position.
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = (id, dismiss)
        } else {
            entries.append((id, dismiss))
        }
        depth = entries.count
    }

    func unregister(id: UUID) {
        entries.removeAll { $0.id == id }
        depth = entries.count
    }

    /// Pops the innermost registered destination (LIFO). Safe no-op
    /// when empty.
    func popTop() {
        guard let last = entries.last else { return }
        last.dismiss()
    }
}

/// Registers the view with the parent SettingsView's
/// `SettingsDismissStack` on appear so the Menu-button handler can
/// pop it even though it was pushed via classic `NavigationLink`
/// (which bypasses `navPath`).
struct TrackClassicSettingsChild: ViewModifier {
    @EnvironmentObject var stack: SettingsDismissStack
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                stack.register(id: id) { dismiss() }
            }
            .onDisappear {
                stack.unregister(id: id)
            }
    }
}

extension View {
    /// Attach to a classic-`NavigationLink(destination:)` destination
    /// pushed within SettingsView's tvOS NavigationStack so the Menu
    /// button can pop it via the `popRequested` binding.
    func trackedAsClassicSettingsChild() -> some View {
        modifier(TrackClassicSettingsChild())
    }
}
#endif

