import SwiftUI
import SwiftData

struct SettingsView: View {
    #if os(tvOS)
    @Binding var selectedTab: AppTab
    #endif
    @Query private var servers: [ServerConnection]
    @Environment(\.modelContext) private var modelContext
    @State private var showAddServer = false
    @State private var serverToDelete: ServerConnection? = nil
    @State private var serverToEdit: ServerConnection? = nil
    @State private var showDeleteAlert = false
    // Tracks whether the one-time swipe-hint peek has been shown.
    @State private var copiedAbout = false
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("syncLastDate") private var syncLastDate: Double = 0
    #if os(tvOS)
    @State private var navPath = NavigationPath()
    #endif

    var body: some View {
        #if os(tvOS)
        // Attach .onExitCommand directly to SettingsView. tvOS dispatches
        // Menu-button events to the innermost .onExitCommand in the focus
        // path, so this handler runs BEFORE MainTabView's outer handler
        // whenever focus is anywhere inside Settings (including pushed
        // detail pages like EditServerPage, Appearance, Network, etc.).
        // When the nav stack is non-empty we pop directly here — no
        // ping-pong through @Binding, no dependence on SwiftUI update
        // ordering. When the nav stack is empty, we fall through to
        // MainTabView's default "return to Live TV" behavior by switching
        // the selected tab ourselves.
        settingsNavigationStack
            .onExitCommand {
                if !navPath.isEmpty {
                    debugLog("🎮 Menu (Settings): popping nav stack")
                    navPath.removeLast()
                } else {
                    debugLog("🎮 Menu (Settings): at root → switch to Live TV")
                    selectedTab = .liveTV
                }
            }
        #else
        settingsNavigationStack
        #endif
    }

    @ViewBuilder
    private var settingsNavigationStack: some View {
        #if os(tvOS)
        NavigationStack(path: $navPath) { settingsContent }
        #else
        NavigationStack { settingsContent }
        #endif
    }

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
                                        title: "Appearance", subtitle: "Theme & display options")
                        }
                        #if os(iOS)
                        .buttonStyle(PressableButtonStyle())
                        #endif
                        NavigationLink(destination: GuideDisplaySettingsView()) {
                            SettingsRow(icon: "calendar", iconColor: .accentPrimary,
                                        title: "Guide Display", subtitle: "Category colors, channel stripe & guide size")
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
                #endif
            }
            #if os(iOS)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            #if os(tvOS)
            .navigationDestination(for: String.self) { route in
                switch route {
                case "appearance":      AppearanceSettingsView()
                case "guide-display":   GuideDisplaySettingsView()
                case "network":         NetworkSettingsView()
                case "dvr-settings": DVRSettingsView()
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
                            TVSettingsNavRow(destination: ServerDetailView(server: server)) {
                                // Only offer the "set active" radio when there's
                                // more than one playlist — with one playlist
                                // it's always the active one, so the circle is
                                // noise.
                                ServerListRow(server: server,
                                              onSetActive: servers.count > 1 ? { setActiveServer(server) } : nil)
                            }
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
                    }
                    TVSettingsActionRow(icon: "plus.circle.fill",
                                        label: "Add Playlist",
                                        isAccent: true) {
                        showAddServer = true
                    }
                }
                if !servers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Tap ○ to set the active playlist", systemImage: "checkmark.circle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.textPrimary.opacity(0.7))
                        Label("Long press to edit or delete", systemImage: "hand.tap")
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
                                        iconColor: .accentPrimary, subtitle: "Theme & display options") {
                        navPath.append("appearance")
                    }
                    TVSettingsNavButton(label: "Guide Display", icon: "calendar",
                                        iconColor: .accentPrimary, subtitle: "Category colors, channel stripe & guide size") {
                        navPath.append("guide-display")
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
                        }
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
    @State private var isTestingConnection = false
    @State private var connectionResult: String? = nil
    @State private var connectionSuccess = false
    #if os(iOS)
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var ssidRefreshed = false
    #endif

    private var hasLANConfigured: Bool {
        server.type != .m3uPlaylist && !server.localURL.isEmpty && !server.homeSSIDs.isEmpty
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
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL, auth: .apiKey(server.effectiveApiKey))
                _ = try await api.verifyConnection()
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
                    SecureField("API Key", text: $server.apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Authentication").sectionHeaderStyle()
                }
                Section {
                    TextField("Custom XMLTV URL (optional)",
                              text: $server.dispatcharrXMLTVURL,
                              prompt: Text("https://example.com/xmltv.xml"))
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
                            tvEditField("API Key", text: $server.apiKey, isSecure: true)
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
                                tvField("API Key", text: $server.apiKey, isSecure: true)
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

                // Guide Display moved to its own top-level page —
                // `GuideDisplaySettingsView`, reachable from the
                // main Settings → App Settings section.
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

                // Guide Display moved to its own top-level page —
                // `GuideDisplaySettingsView`, reachable from the main
                // Settings → App Settings section. Reason: users
                // couldn't find category colours here buried under
                // Network; and "Guide Display" isn't really a
                // networking concern anyway.

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
// One row in Settings → Guide Display that binds a SwiftUI
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
private struct CategoryColorPickerRow: View {
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

// MARK: - Guide Display Settings
//
// Standalone top-level settings page for guide-related visual controls:
// the program-category colour palette, the channel-card stripe toggle,
// per-bucket colour overrides (iOS), and the Guide Size slider.
//
// Previously these lived as a Section inside NetworkSettingsView, which
// users couldn't find — category colours aren't really a networking
// concern, and burying them two levels deep behind "Network" made the
// feature effectively invisible. Lifting it to its own page at the
// App Settings level (alongside Appearance / Network / DVR) matches the
// user's mental model.
struct GuideDisplaySettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage(CategoryColor.enabledKey) private var enableCategoryColors = true
    @AppStorage("tintChannelCards")       private var tintChannelCards = false
    @AppStorage("guideScale")             private var guideScale: Double = 1.0

    /// Summary text for the "Add more categories" disclosure row —
    /// shows "Off", "3 extra", "Custom", or "5 extra + Custom" so
    /// the user can see at a glance whether they've enabled
    /// anything beyond the four default buckets.
    fileprivate var moreCategoriesSummary: String {
        let extraOn = CategoryColor.additionalBuckets.filter { CategoryColor.isBucketEnabled($0) }.count
        let customCount = CategoryColor.loadCustomCategories().count
        switch (extraOn, customCount) {
        case (0, 0): return "Off"
        case (let e, 0): return "\(e) extra"
        case (0, let c): return "\(c) custom"
        case (let e, let c): return "\(e) extra · \(c) custom"
        }
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
        .navigationTitle("Guide Display")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    // MARK: - iOS Body
    #if !os(tvOS)
    private var iOSBody: some View {
        List {
            // Master toggle + channel-card companion toggle.
            //
            // iPhone's Live TV tab is List-only (Guide view is iPad /
            // Mac / Apple TV). The master toggle still matters on
            // iPhone because it unlocks the "Tint Channel Cards"
            // feature below — but "tint guide cells" was misleading
            // copy that made iPhone testers think nothing happens
            // when they flip it (they looked for a Guide view that
            // doesn't exist). Device-aware text resolves that.
            Section {
                Toggle(isOn: $enableCategoryColors) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Color Programs by Category")
                            .font(.bodyMedium).foregroundColor(.textPrimary)
                        Text(UIDevice.current.userInterfaceIdiom == .phone
                             ? "Unlocks category-based coloring. On iPhone this drives the Tint Channel Cards stripe below."
                             : "Tint guide cells by program type — tap any color below to customise.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: enableCategoryColors) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }

                Toggle(isOn: $tintChannelCards) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tint Channel Cards")
                            .font(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Adds a colored stripe to Live TV channel cards (list view) based on what's currently airing.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .disabled(!enableCategoryColors)
                .opacity(enableCategoryColors ? 1.0 : 0.4)
                .onChange(of: tintChannelCards) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }
            } header: {
                Text("Category Colors").sectionHeaderStyle()
            } footer: {
                Text(UIDevice.current.userInterfaceIdiom == .phone
                     ? "iPhone's Live TV tab only renders the List view. Cards tint with a gradient that fades from the leading edge toward the center — based on the currently-airing program on the main row, and the individual program on each expanded schedule row. Dispatcharr and M3U+XMLTV work out of the box; Xtream Codes doesn't expose category data."
                     : "Programs with a category tag in the EPG source get a leading-edge gradient — on channel cards in the List view (using the currently-airing program), on each row in the expanded schedule (using that program's own category), and on cells in the Guide grid. Dispatcharr and M3U+XMLTV work out of the box; Xtream Codes doesn't expose category data.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }

            // Default palette — the four buckets that have shipped
            // since v1.0. Always visible; the new "Add more
            // categories" row below progressively discloses the
            // extra buckets + a Custom editor without cluttering
            // the default Settings view.
            Section {
                ForEach(CategoryColor.defaultBuckets, id: \.rawValue) { cat in
                    CategoryColorPickerRow(category: cat)
                        .listRowBackground(Color.cardBackground)
                        .disabled(!enableCategoryColors)
                        .opacity(enableCategoryColors ? 1.0 : 0.4)
                }

                NavigationLink {
                    MoreCategoriesView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentPrimary)
                        Text("Add more categories")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Text(moreCategoriesSummary)
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
                .listRowBackground(Color.cardBackground)
                .disabled(!enableCategoryColors)
                .opacity(enableCategoryColors ? 1.0 : 0.4)

                Button(role: .destructive) {
                    CategoryColor.resetPaletteToDefaults()
                    // Palette reset is a user action — push immediately
                    // so other devices don't keep showing the old
                    // custom colours for up to 60 seconds.
                    SyncManager.shared.pushPreferencesImmediate()
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Reset Colors to Defaults").font(.bodyMedium)
                    }
                    .foregroundColor(.statusWarning)
                }
                .listRowBackground(Color.cardBackground)
                .disabled(!enableCategoryColors)
                .opacity(enableCategoryColors ? 1.0 : 0.4)
            } header: {
                Text("Palette").sectionHeaderStyle()
            } footer: {
                Text("Tap a swatch to customise the color used for that program bucket. Kids > Sports > News > Movie priority when a program matches multiple.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }

            // Guide size slider — iPad + Mac only (iPhone uses the list
            // view; no grid to scale). Writes through the shared
            // `guideScale` AppStorage key that EPGGuideView observes, so
            // dragging resizes the live guide instantly.
            if UIDevice.current.userInterfaceIdiom != .phone {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Guide Size")
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                            Spacer()
                            Text("\(Int(guideScale * 100))%")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "textformat.size.smaller")
                                .foregroundColor(.textTertiary)
                                .font(.system(size: 12))
                            Slider(value: $guideScale, in: 0.75...1.5, step: 0.05)
                                .tint(theme.accent)
                            Image(systemName: "textformat.size.larger")
                                .foregroundColor(.textTertiary)
                                .font(.system(size: 14))
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Guide Size").sectionHeaderStyle()
                } footer: {
                    Text("Scale the guide grid on iPad and Mac.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
    #endif

    // MARK: - tvOS Body
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvSection("Category Colors") {
                    TVSettingsToggleRow(
                        icon: "paintpalette.fill",
                        iconColor: .accentPrimary,
                        title: "Color Programs by Category",
                        subtitle: "Tint guide cells by program type. Customise the palette on iPhone / iPad — Settings → Guide Display.",
                        isOn: $enableCategoryColors,
                        onChange: { _ in }
                    )
                    TVSettingsToggleRow(
                        icon: "tv.fill",
                        iconColor: .accentPrimary,
                        title: "Tint Channel Cards",
                        subtitle: "Adds a colored stripe to Live TV channel cards based on what's airing now.",
                        isOn: $tintChannelCards,
                        onChange: { _ in }
                    )
                    .disabled(!enableCategoryColors)
                    .opacity(enableCategoryColors ? 1.0 : 0.4)
                }
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
}

// MARK: - More Categories View
//
// Disclosure target for "Add more categories" on the Guide Display
// settings screen. Presents the seven additional built-in buckets
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


