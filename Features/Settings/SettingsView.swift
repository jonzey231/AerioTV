import SwiftUI
import SwiftData

struct SettingsView: View {
    #if os(tvOS)
    @Binding var selectedTab: AppTab
    @Binding var isSubPushed: Bool
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
        settingsNavigationStack
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
                case "appearance": AppearanceSettingsView()
                case "network":    NetworkSettingsView()
                case "developer":  DeveloperSettingsView()
                case "edit-server":
                    if let server = serverToEdit {
                        EditServerPage(server: server)
                    }
                default:           EmptyView()
                }
            }
            .onChange(of: navPath) { _, path in
                isSubPushed = !path.isEmpty
            }
            .onChange(of: isSubPushed) { _, pushed in
                if !pushed && !navPath.isEmpty {
                    navPath.removeLast()
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
                        server.deleteCredentialsFromKeychain()
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

    private var aboutDevice: String {
#if canImport(UIKit)
        return UIDevice.current.model
#else
        return "Mac"
#endif
    }

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

    private var aboutInstallDate: String {
        guard let docs  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let attrs = try? FileManager.default.attributesOfItem(atPath: docs.deletingLastPathComponent().path),
              let date  = attrs[.creationDate] as? Date else { return "—" }
        return date.formatted(date: .long, time: .omitted)
    }

    private var aboutUpdateDate: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
              let date  = attrs[.modificationDate] as? Date else { return "—" }
        return date.formatted(date: .long, time: .omitted)
    }

    private var aboutCopyText: String {
        [
            "Aerio \(aboutVersion)",
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
                                ServerListRow(server: server,
                                              onSetActive: { setActiveServer(server) })
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
private struct TVSettingsNavRow<Destination: View, Content: View>: View {
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
private struct TVSettingsNavButton: View {
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
private struct TVSettingsActionRow: View {
    let icon: String
    let label: String
    var isAccent: Bool = false
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(isAccent ? .accentPrimary : .textSecondary)
                Text(label)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(isAccent ? .accentPrimary : .textPrimary)
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
private func tvSettingsCardBG(_ focused: Bool) -> some View {
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
                            // On WiFi but SSID is nil — entitlement is almost certainly missing.
                            Text("⚠️ Wi-Fi detected but SSID is unknown. Add the \"Access WiFi Information\" capability in Xcode → Signing & Capabilities, and set the entitlements file in Build Settings → Code Signing Entitlements.")
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

    private var aboutDevice: String {
#if canImport(UIKit)
        return UIDevice.current.model
#else
        return "Mac"
#endif
    }

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

    private var aboutInstallDate: String {
        // The app sandbox container's creation date is set when the app is first installed.
        guard let docs  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let attrs = try? FileManager.default.attributesOfItem(atPath: docs.deletingLastPathComponent().path),
              let date  = attrs[.creationDate] as? Date else { return "—" }
        return date.formatted(date: .long, time: .omitted)
    }

    private var aboutUpdateDate: String {
        // The app bundle's modification date changes when the app is updated.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
              let date  = attrs[.modificationDate] as? Date else { return "—" }
        return date.formatted(date: .long, time: .omitted)
    }

    private var aboutCopyText: String {
        [
            "Aerio \(aboutVersion)",
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
                    tvEditSection("Authentication") {
                        tvEditField("API Key", text: $server.apiKey, isSecure: true)
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
                        tvSection("Authentication") {
                            tvField("API Key", text: $server.apiKey, isSecure: true)
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
                        #if os(iOS)
                        Slider(value: $networkTimeout, in: 5...60, step: 5)
                            .tint(theme.accent)
                        #endif
                    }
                    .listRowBackground(Color.cardBackground)

                    #if os(iOS)
                    Stepper("Max Retries: \(maxRetries)", value: $maxRetries, in: 0...10)
                        .listRowBackground(Color.cardBackground)
                    #endif
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
                        Text("⚠️ Wi-Fi detected but network name unavailable. Verify the \"Access WiFi Information\" capability is enabled in Xcode → Signing & Capabilities.")
                            .font(.labelSmall).foregroundColor(.statusWarning)
                    } else {
                        Text("When connected to any of these networks, Aerio uses each server's local URL instead of its remote URL. Set each server's local URL in Settings → Playlists → [server] → Edit.")
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
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            #else
            .listStyle(.plain)
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
            NetworkMonitor.shared.refresh(force: true)
            let stored = UserDefaults.standard.string(forKey: "globalHomeSSIDs") ?? ""
            let parsed = stored.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            ssidEntries = parsed.isEmpty ? [""] : parsed
        }
        #endif
    }

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


