import SwiftUI
import SwiftData

struct AddServerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = ServerConnectionViewModel()
    @State private var showServerTypePicker = false

    var onSave: ((ServerConnection) -> Void)? = nil

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    serverTypeSelector
                    serverForm
                    verifySection

                    if viewModel.verificationSuccess {
                        PrimaryButton("Save Server", icon: "checkmark") {
                            saveServer()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Spacer(minLength: 40)
                }
                .padding(20)
            }
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .sheet(isPresented: $showServerTypePicker) {
            ServerTypePickerSheet(selectedType: $viewModel.serverType)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.verificationSuccess)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.serverType)
    }

    // MARK: - Server Type Selector
    private var serverTypeSelector: some View {
        Button { showServerTypePicker = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(viewModel.serverType.color.opacity(0.2))
                        .frame(width: 46, height: 46)
                    Image(systemName: viewModel.serverType.systemIcon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(viewModel.serverType.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.serverType.displayName)
                        .font(.headlineMedium)
                        .foregroundColor(.textPrimary)
                    Text(viewModel.serverType.description)
                        .font(.bodySmall)
                        .foregroundColor(.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textTertiary)
            }
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(viewModel.serverType.color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dynamic Form
    private var serverForm: some View {
        VStack(spacing: 16) {
            AppTextField("Name", placeholder: "My IPTV Server",
                         text: $viewModel.name, icon: "tag.fill")

            switch viewModel.serverType {
            case .m3uPlaylist:
                AppTextField("M3U URL", placeholder: "https://example.com/playlist.m3u",
                             text: $viewModel.baseURL, icon: "link",
                             keyboardType: .URL)
                AppTextField("EPG URL (optional)", placeholder: "https://example.com/epg.xml",
                             text: $viewModel.epgURL, icon: "calendar",
                             keyboardType: .URL)
                infoBox(icon: "info.circle.fill",
                        message: "Paste your M3U playlist URL. Works with Dispatcharr's /output/m3u, any IPTV provider, or a direct .m3u file link.")

            case .xtreamCodes:
                AppTextField("Server URL", placeholder: "http://your-server.com:8080",
                             text: $viewModel.baseURL, icon: "link",
                             keyboardType: .URL)
                    .overlay(alignment: .bottomTrailing) {
                        if !viewModel.baseURL.isEmpty {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(viewModel.baseURL.lowercased().hasPrefix("https") ? Color.statusOnline : Color.statusWarning)
                                    .frame(width: 6, height: 6)
                                Text(viewModel.baseURL.lowercased().hasPrefix("https") ? "HTTPS" : "HTTP")
                                    .font(.monoSmall)
                                    .foregroundColor(viewModel.baseURL.lowercased().hasPrefix("https") ? .statusOnline : .statusWarning)
                            }
                            .padding(8)
                        }
                    }
                AppTextField("Username", placeholder: "Dispatcharr XC Username",
                             text: $viewModel.username, icon: "person.fill")
                AppTextField("Password", placeholder: "Dispatcharr XC Password",
                             text: $viewModel.password, icon: "lock.fill", isSecure: true)
                infoBox(icon: "info.circle.fill",
                        message: "Enter your Xtream Codes server URL and credentials. Dispatcharr users: use your Dispatcharr URL with the Xtream Codes username and password from Dispatcharr's Users tab.")

            case .dispatcharrAPI:
                AppTextField("Server URL", placeholder: "http://your-dispatcharr-server:9191",
                             text: $viewModel.baseURL, icon: "link",
                             keyboardType: .URL)
                    .overlay(alignment: .bottomTrailing) {
                        if !viewModel.baseURL.isEmpty {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(viewModel.baseURL.lowercased().hasPrefix("https") ? Color.statusOnline : Color.statusWarning)
                                    .frame(width: 6, height: 6)
                                Text(viewModel.baseURL.lowercased().hasPrefix("https") ? "HTTPS" : "HTTP")
                                    .font(.monoSmall)
                                    .foregroundColor(viewModel.baseURL.lowercased().hasPrefix("https") ? .statusOnline : .statusWarning)
                            }
                            .padding(8)
                        }
                    }

                AppTextField("API Key", placeholder: "••••••••••••••••",
                             text: $viewModel.apiKey, icon: "key.fill", isSecure: true)

                infoBox(icon: "info.circle.fill",
                        message: "Use a Dispatcharr API key (Settings → API keys). This enables native Dispatcharr endpoints for Live TV, Guide, Movies, and TV Shows.")
            }
        }
    }

    // MARK: - Verify Section
    private var verifySection: some View {
        VStack(spacing: 12) {
            PrimaryButton(
                viewModel.isVerifying ? "Verifying..." : "Test Connection",
                icon: viewModel.verificationSuccess ? "checkmark.circle.fill" : "network",
                isLoading: viewModel.isVerifying,
                isDisabled: !viewModel.isFormValid
            ) {
                Task { await viewModel.verifyConnection() }
            }

            if viewModel.verificationSuccess {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.statusOnline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected successfully")
                            .font(.headlineSmall)
                            .foregroundColor(.statusOnline)
                        if let name = viewModel.verifiedServerName {
                            Text(name)
                                .font(.bodySmall)
                                .foregroundColor(.textSecondary)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.statusOnline.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error = viewModel.verificationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.statusLive)
                    Text(error)
                        .font(.bodySmall)
                        .foregroundColor(.statusLive)
                }
                .padding(14)
                .background(Color.statusLive.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func infoBox(icon: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentPrimary)
                .padding(.top, 1)
            Text(message)
                .font(.bodySmall)
                .foregroundColor(.textSecondary)
        }
        .padding(12)
        .background(Color.accentPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func saveServer() {
        let server = viewModel.buildServerConnection()
        server.isVerified = true
        server.lastConnected = Date()
        modelContext.insert(server)
        try? modelContext.save()
        onSave?(server)
        dismiss()
    }
}

// MARK: - Server Type Picker Sheet
struct ServerTypePickerSheet: View {
    @Binding var selectedType: ServerType
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                VStack(spacing: 12) {
                    ForEach(ServerType.allCases, id: \.self) { type in
                        Button {
                            selectedType = type
                            dismiss()
                        } label: {
                            HStack(spacing: 16) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(type.color.opacity(0.15))
                                        .frame(width: 52, height: 52)
                                    Image(systemName: type.systemIcon)
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundColor(type.color)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(type.displayName)
                                        .font(.headlineMedium)
                                        .foregroundColor(.textPrimary)
                                    Text(type.description)
                                        .font(.bodySmall)
                                        .foregroundColor(.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if selectedType == type {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(LinearGradient.accentGradient)
                                }
                            }
                            .padding(16)
                            .background(selectedType == type ? type.color.opacity(0.08) : Color.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(selectedType == type ? type.color.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Source Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.headlineSmall)
                        .foregroundColor(.accentPrimary)
                }
            }
            .toolbarBackground(Color.appBackground, for: .navigationBar)
        }
    }
}
