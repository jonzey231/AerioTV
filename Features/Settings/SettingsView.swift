import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query private var servers: [ServerConnection]
    @Query private var playlists: [M3UPlaylist]
    @Query private var epgSources: [EPGSource]
    @Environment(\.modelContext) private var modelContext
    @State private var showAddServer = false
    @State private var showAddPlaylist = false
    @State private var showAddEPG = false
    @State private var serverToDelete: ServerConnection? = nil
    @State private var serverToEdit: ServerConnection? = nil
    @State private var showDeleteAlert = false
    @State private var playlistToEdit: M3UPlaylist? = nil
    @State private var playlistToDelete: M3UPlaylist? = nil
    @State private var showPlaylistDeleteAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                List {
                    // MARK: - Servers Section
                    Section {
                        if servers.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "server.rack")
                                        .font(.system(size: 28))
                                        .foregroundColor(.textTertiary)
                                    Text("No servers added")
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
                                    ServerListRow(server: server)
                                }
                                .listRowBackground(Color.cardBackground)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        serverToEdit = server
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.accentPrimary)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                                Text("Add Server")
                                    .font(.bodyMedium)
                                    .foregroundColor(.accentPrimary)
                            }
                        }
                        .listRowBackground(Color.cardBackground)

                    } header: {
                        Text("Servers")
                            .sectionHeaderStyle()
                    }
                    .listSectionSeparator(.hidden)

                    // MARK: - Playlists Section
                    Section {
                        if playlists.isEmpty {
                            HStack {
                                Spacer()
                                Text("No playlists added")
                                    .font(.bodySmall)
                                    .foregroundColor(.textTertiary)
                                    .padding(.vertical, 12)
                                Spacer()
                            }
                            .listRowBackground(Color.cardBackground)
                        } else {
                            ForEach(playlists) { playlist in
                                PlaylistListRow(playlist: playlist)
                                    .listRowBackground(Color.cardBackground)
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            playlistToEdit = playlist
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.accentPrimary)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            playlistToDelete = playlist
                                            showPlaylistDeleteAlert = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        Button {
                            showAddPlaylist = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.accentPrimary)
                                Text("Import M3U Playlist")
                                    .font(.bodyMedium)
                                    .foregroundColor(.accentPrimary)
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    } header: {
                        Text("M3U Playlists")
                            .sectionHeaderStyle()
                    }
                    .listSectionSeparator(.hidden)

                    // MARK: - EPG Sources Section
                    Section {
                        if epgSources.isEmpty {
                            HStack {
                                Spacer()
                                Text("No EPG sources added")
                                    .font(.bodySmall)
                                    .foregroundColor(.textTertiary)
                                    .padding(.vertical, 12)
                                Spacer()
                            }
                            .listRowBackground(Color.cardBackground)
                        } else {
                            ForEach(epgSources) { source in
                                EPGSourceListRow(source: source)
                                    .listRowBackground(Color.cardBackground)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            modelContext.delete(source)
                                            try? modelContext.save()
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        Button {
                            showAddEPG = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.accentSecondary)
                                Text("Import EPG Guide")
                                    .font(.bodyMedium)
                                    .foregroundColor(.accentSecondary)
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    } header: {
                        Text("EPG Guides")
                            .sectionHeaderStyle()
                    }
                    .listSectionSeparator(.hidden)
                    Section {
                        NavigationLink(destination: AppearanceSettingsView()) {
                            SettingsRow(icon: "paintbrush.fill", iconColor: .accentPrimary,
                                        title: "Appearance", subtitle: "Theme & display options")
                        }
                        NavigationLink(destination: NotificationSettingsView()) {
                            SettingsRow(icon: "bell.fill", iconColor: .statusLive,
                                        title: "Notifications", subtitle: "Show reminders")
                        }
                        NavigationLink(destination: NetworkSettingsView()) {
                            SettingsRow(icon: "network", iconColor: .accentSecondary,
                                        title: "Network", subtitle: "Timeout & retry settings")
                        }
                    } header: {
                        Text("App Settings")
                            .sectionHeaderStyle()
                    }
                    .listRowBackground(Color.cardBackground)
                    .listSectionSeparator(.hidden)

                    // MARK: - About Section
                    Section {
                        HStack {
                            Text("Version")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Text("1.0.0")
                                .font(.monoSmall)
                                .foregroundColor(.textTertiary)
                        }
                        .listRowBackground(Color.cardBackground)

                        Link(destination: URL(string: "https://github.com/Dispatcharr/Dispatcharr")!) {
                            SettingsRow(icon: "arrow.up.right.square.fill", iconColor: .textSecondary,
                                        title: "GitHub Repository", subtitle: "View source on GitHub")
                        }
                        .listRowBackground(Color.cardBackground)

                        Link(destination: URL(string: "https://discord.gg/Sp45V5BcxU")!) {
                            SettingsRow(icon: "bubble.left.and.bubble.right.fill", iconColor: .accentPrimary,
                                        title: "Discord Community", subtitle: "Get help & share feedback")
                        }
                        .listRowBackground(Color.cardBackground)

                    } header: {
                        Text("About")
                            .sectionHeaderStyle()
                    }
                    .listSectionSeparator(.hidden)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .sheet(isPresented: $showAddServer) {
                NavigationStack { AddServerView() }
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
            .sheet(isPresented: $showAddPlaylist) {
                M3UImportView()
            }
            .sheet(isPresented: $showAddEPG) {
                EPGImportView()
            }
            .alert("Delete Server?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let server = serverToDelete {
                        modelContext.delete(server)
                        try? modelContext.save()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \"\(serverToDelete?.name ?? "this server")\" from the app. Your server data will not be affected.")
            }
            .alert("Delete Playlist?", isPresented: $showPlaylistDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let playlist = playlistToDelete {
                        modelContext.delete(playlist)
                        try? modelContext.save()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \"\(playlistToDelete?.name ?? "this playlist")\"? This cannot be undone.")
            }
            .sheet(item: $playlistToEdit) { playlist in
                EditPlaylistSheet(playlist: playlist)
            }
            .sheet(item: $serverToEdit) { server in
                EditServerSheet(server: server)
            }
        }
    }
}

// MARK: - Server List Row
struct ServerListRow: View {
    let server: ServerConnection

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(server.type.color.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: server.type.systemIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(server.type.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                HStack(spacing: 4) {
                    ServerTypeBadge(type: server.type)
                    Text(server.normalizedBaseURL)
                        .font(.monoSmall)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Circle()
                .fill(server.isVerified ? Color.statusOnline : Color.textTertiary)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Row
struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 1) {
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
        .padding(.vertical, 2)
    }
}

// MARK: - Server Detail View
struct ServerDetailView: View {
    let server: ServerConnection
    @State private var isTestingConnection = false
    @State private var connectionResult: String? = nil
    @State private var connectionSuccess = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            List {
                Section {
                    infoRow("Type", value: server.type.displayName)
                    infoRow("URL", value: server.normalizedBaseURL, isMonospaced: true)
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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
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
                let api = XtreamCodesAPI(baseURL: server.normalizedBaseURL, username: server.username, password: server.password)
                _ = try await api.verifyConnection()
            case .dispatcharrAPI:
                let api = DispatcharrAPI(baseURL: server.normalizedBaseURL, auth: .apiKey(server.apiKey))
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

// MARK: - EPG Source List Row
struct EPGSourceListRow: View {
    let source: EPGSource

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentSecondary.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: source.sourceType == .url ? "calendar.badge.clock" : "doc.text.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.accentSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                HStack(spacing: 6) {
                    Text("\(source.programCount) programmes")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                    if let refreshed = source.lastRefreshed {
                        Text("·")
                            .foregroundColor(.textTertiary)
                        Text(refreshed, style: .relative)
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            Spacer()
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
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
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
                        Text("Server Details").sectionHeaderStyle()
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
            .navigationTitle("Edit Server")
            .navigationBarTitleDisplayMode(.inline)
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
                        .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  server.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct NotificationSettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("programReminders") private var programReminders = false
    @AppStorage("reminderMinutes") private var reminderMinutes = 15
    
    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            List {
                Section {
                    Toggle("Enable Notifications", isOn: $notificationsEnabled)
                        .listRowBackground(Color.cardBackground)
                    
                    if notificationsEnabled {
                        Toggle("Program Reminders", isOn: $programReminders)
                            .listRowBackground(Color.cardBackground)
                        
                        if programReminders {
                            Picker("Remind Me", selection: $reminderMinutes) {
                                Text("5 minutes before").tag(5)
                                Text("15 minutes before").tag(15)
                                Text("30 minutes before").tag(30)
                                Text("1 hour before").tag(60)
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                    }
                } header: {
                    Text("Notifications").sectionHeaderStyle()
                } footer: {
                    Text("Get notified when your favorite programs are about to start")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }
}

struct NetworkSettingsView: View {
    @AppStorage("networkTimeout") private var networkTimeout = 15.0
    @AppStorage("maxRetries") private var maxRetries = 3
    @AppStorage("streamBufferSize") private var streamBufferSize = "default"
    
    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Request Timeout")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Text("\(Int(networkTimeout))s")
                                .font(.monoSmall)
                                .foregroundColor(.accentPrimary)
                        }
                        Slider(value: $networkTimeout, in: 5...60, step: 5)
                            .tint(.accentPrimary)
                    }
                    .listRowBackground(Color.cardBackground)
                    
                    Stepper("Max Retries: \(maxRetries)", value: $maxRetries, in: 0...10)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Connection").sectionHeaderStyle()
                } footer: {
                    Text("Adjust timeouts if you have a slow connection")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
                
                Section {
                    Picker("Buffer Size", selection: $streamBufferSize) {
                        Text("Small").tag("small")
                        Text("Default").tag("default")
                        Text("Large").tag("large")
                    }
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Streaming").sectionHeaderStyle()
                } footer: {
                    Text("Larger buffers may improve playback on unstable connections")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }
}


