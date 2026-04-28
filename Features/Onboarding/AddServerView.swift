import SwiftUI
import SwiftData

struct AddServerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = ServerConnectionViewModel()
    /// false = type picker shown first; true = form fields revealed
    @State private var typeChosen = false
    /// LAN/SSID section is optional — collapsed by default
    @State private var lanExpanded = false

    // Home WiFi SSID configuration (global, stored in UserDefaults).
    // Shown inline during setup so the user doesn't have to visit Settings.
    #if os(iOS)
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var ssidEntries: [String] = [""]
    #endif

    var onSave: ((ServerConnection) -> Void)? = nil

    /// Server that was just saved — triggers the sync loading screen.
    @State private var savedServer: ServerConnection?

    // DVR onboarding (Dispatcharr only)
    @State private var deviceNickname: String = DeviceInfo.modelName
    @State private var dvrDestination: RecordingDestination = .dispatcharrServer

    // Advanced: External XMLTV (Dispatcharr only). Collapsed by default unless
    // the user has already populated a URL, in which case we auto-expand so
    // they can see what's set.
    @State private var xmltvAdvancedExpanded: Bool = false
    @State private var xmltvTestState: XMLTVTestState = .idle

    enum XMLTVTestState: Equatable {
        case idle
        case testing
        case success(Int)    // program count
        case failure(String) // user-facing error
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    if !typeChosen {
                        typePickerSection
                    } else {
                        chosenTypeHeader
                        serverForm
                        lanWANSection
                        verifySection

                        // DVR & identity onboarding (Dispatcharr only)
                        if viewModel.verificationSuccess && viewModel.serverType == .dispatcharrAPI {
                            dispatcharrOnboardingSection
                        }

                        if viewModel.verificationSuccess {
                            PrimaryButton("Save Playlist", icon: "checkmark") {
                                saveServer()
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    Spacer(minLength: 40)
                }
                .padding(20)
            }
        }
        .navigationTitle(typeChosen ? "Configure" : "Add Playlist")
        .navigationBarBackButtonHidden(typeChosen)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbar {
            if typeChosen {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            typeChosen = false
                            viewModel.reset()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Choose Server Type")
                        }
                        .foregroundColor(.accentPrimary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: typeChosen)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.verificationSuccess)
        #if os(iOS)
        .task {
            // Load existing SSIDs from UserDefaults so user sees what's already saved.
            let stored = UserDefaults.standard.string(forKey: "globalHomeSSIDs") ?? ""
            let parsed = stored.split(separator: ",").map { String($0) }
            ssidEntries = parsed.isEmpty ? [""] : parsed
            // Intentionally NOT auto-calling `NetworkMonitor.refresh(force: true)`
            // here — doing so was the cause of the Location-permission
            // prompt that fired immediately when a first-run user opened
            // "Add Server" (before they'd added a LAN URL or typed a
            // single character). Users interpreted the double prompt
            // (Location + Local Network) as the app over-reaching.
            //
            // The "current WiFi" badge below reads `networkMonitor.currentSSID`
            // from cache, and the adjacent refresh button still lets
            // the user trigger a live fetch (which prompts for Location
            // with context). That's the opt-in flow Aerio's Welcome
            // screen already uses with its "Detect Home WiFi" card.
        }
        #endif
        .fullScreenCover(item: $savedServer) { server in
            ServerSyncView(mode: .onboarding(server: server))
                .onDisappear {
                    // When the sync screen is dismissed, also dismiss AddServerView.
                    dismiss()
                }
        }
    }

    // MARK: - Type Picker (Step 1)

    private var typePickerSection: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Choose Source Type")
                    .font(.headlineLarge)
                    .foregroundColor(.textPrimary)
                Text("Select how you want to connect to your media source.")
                    .font(.bodyMedium)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            ForEach(ServerType.allCases, id: \.self) { type in
                Button {
                    viewModel.serverType = type
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        typeChosen = true
                    }
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
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.textTertiary)
                    }
                    .padding(16)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.borderSubtle, lineWidth: 1)
                    )
                }
                #if os(tvOS)
                .buttonStyle(TVNoHighlightButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
            }
        }
    }

    // MARK: - Chosen Type Header (Step 2)

    private var chosenTypeHeader: some View {
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
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(viewModel.serverType.color.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Dynamic Form (Step 2)

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
                            urlProtocolBadge(url: viewModel.baseURL).padding(8)
                        }
                    }
                AppTextField("Username", placeholder: "XC Username",
                             text: $viewModel.username, icon: "person.fill")
                AppTextField("Password", placeholder: "XC Password",
                             text: $viewModel.password, icon: "lock.fill", isSecure: true)
                infoBox(icon: "info.circle.fill",
                        message: "Enter your Xtream Codes server URL and credentials. Dispatcharr users: use your Dispatcharr URL with the Xtream Codes username and password from Dispatcharr's User settings.")

            case .dispatcharrAPI:
                AppTextField("Server URL", placeholder: "http://your-dispatcharr-server:9191",
                             text: $viewModel.baseURL, icon: "link",
                             keyboardType: .URL)
                    .overlay(alignment: .bottomTrailing) {
                        if !viewModel.baseURL.isEmpty {
                            urlProtocolBadge(url: viewModel.baseURL).padding(8)
                        }
                    }
                AppTextField("Admin API Key", placeholder: "••••••••••••••••",
                             text: $viewModel.apiKey, icon: "key.fill", isSecure: true)
                infoBox(icon: "info.circle.fill",
                        message: "Use a Dispatcharr Admin API Key (System → Users → Edit User → API & XC). This enables native Dispatcharr endpoints for Live TV, Guide, Movies, and TV Shows.")

                advancedXMLTVSection
            }
        }
    }

    // MARK: - Advanced XMLTV Section (Dispatcharr only)

    /// Collapsible disclosure for the optional external-XMLTV override.
    /// Auto-expands when a URL is already set, so returning users see
    /// what's configured rather than having to hunt for a tucked-away
    /// field. Includes a Test button that fetches a small prefix and
    /// runs it through `XMLTVParser` before the user commits.
    @ViewBuilder
    private var advancedXMLTVSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — the disclosure toggle
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    xmltvAdvancedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced: External XMLTV")
                            .font(.headlineSmall)
                            .foregroundColor(.textPrimary)
                        Text("Recommended for CPU-constrained Dispatcharr hosts.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    if !viewModel.dispatcharrXMLTVURL
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Configured")
                            .font(.labelSmall.weight(.semibold))
                            .foregroundColor(.statusOnline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.statusOnline.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textTertiary)
                        .rotationEffect(.degrees(xmltvAdvancedExpanded ? 90 : 0))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8),
                                   value: xmltvAdvancedExpanded)
                }
                .padding(16)
            }
            #if os(tvOS)
            .buttonStyle(TVNoHighlightButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif

            if xmltvAdvancedExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                        .background(Color.borderSubtle)
                        .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 16) {
                        AppTextField(
                            "Custom XMLTV URL",
                            placeholder: "https://example.com/xmltv.xml",
                            text: $viewModel.dispatcharrXMLTVURL,
                            icon: "calendar",
                            keyboardType: .URL
                        )

                        // Test button + status pill. Disabled when empty so
                        // the user can't burn a fetch on whitespace.
                        HStack(spacing: 10) {
                            Button {
                                Task { await testXMLTVURL() }
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
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.accentPrimary.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            #if os(tvOS)
                            .buttonStyle(TVNoHighlightButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .disabled(xmltvTrimmed.isEmpty ||
                                      { if case .testing = xmltvTestState { return true } else { return false } }())

                            xmltvStatusPill
                            Spacer(minLength: 0)
                        }

                        infoBox(
                            icon: "bolt.fill",
                            message: "Override the XMLTV source AerioTV pulls EPG from. Leave blank to use Dispatcharr's own XMLTV output at /output/epg (the default — category data and all). Set only if you want to bypass Dispatcharr and fetch XMLTV straight from your upstream provider."
                        )
                    }
                    .padding([.horizontal, .bottom], 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentSecondary.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            // Auto-expand when returning to a server that already has a URL
            // so the configured value is immediately visible.
            if !xmltvTrimmed.isEmpty {
                xmltvAdvancedExpanded = true
            }
        }
    }

    private var xmltvTrimmed: String {
        viewModel.dispatcharrXMLTVURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var xmltvStatusPill: some View {
        switch xmltvTestState {
        case .idle:
            EmptyView()
        case .testing:
            EmptyView()  // spinner already shown inside the button
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

    /// Fetches the user's XMLTV URL and runs it through XMLTVParser so we
    /// can tell them whether it's valid BEFORE save. Caps the download at
    /// ~5 MB by cancelling after a short timeout — we only need to prove
    /// the response parses as XMLTV with at least one programme.
    @MainActor
    private func testXMLTVURL() async {
        let urlString = xmltvTrimmed
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
            // Strip anything implementation-y from the error so the banner
            // stays short and readable in the small pill.
            let raw = error.localizedDescription
            let trimmed = raw.count > 120 ? String(raw.prefix(120)) + "…" : raw
            xmltvTestState = .failure(trimmed.isEmpty ? "Couldn't parse as XMLTV" : trimmed)
        }
    }

    // MARK: - LAN / WAN Section

    @ViewBuilder
    private var lanWANSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible header — always visible
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    lanExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentSecondary)
                    Text("Local Network (Optional)")
                        .font(.headlineSmall)
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textTertiary)
                        .rotationEffect(.degrees(lanExpanded ? 90 : 0))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: lanExpanded)
                }
                .padding(16)
            }
            #if os(tvOS)
            .buttonStyle(TVNoHighlightButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif

            // Expandable content
            if lanExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                        .background(Color.borderSubtle)
                        .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 16) {
                        let isM3U = viewModel.serverType == .m3uPlaylist
                        AppTextField(
                            isM3U ? "Local M3U URL" : "Local URL",
                            placeholder: isM3U
                                ? "http://192.168.1.10:9191/m3u/playlist?..."
                                : "http://192.168.1.10:9191",
                            text: $viewModel.localURL,
                            icon: "house.fill",
                            keyboardType: .URL
                        )

                        if isM3U {
                            AppTextField(
                                "Local EPG URL",
                                placeholder: "http://192.168.1.10:9191/epg.xml",
                                text: $viewModel.localEPGURL,
                                icon: "calendar",
                                keyboardType: .URL
                            )
                        }

                        #if os(iOS)
                        homeWiFiSection
                        #endif

                        infoBox(
                            icon: "arrow.triangle.2.circlepath",
                            message: isM3U
                                ? "When connected to a home WiFi network, Aerio uses the local M3U and EPG URLs above for faster LAN speeds. These networks apply to all sources."
                                : "When connected to a home WiFi network, Aerio automatically uses the local URL above for faster LAN speeds. These networks apply to all servers."
                        )
                    }
                    .padding([.horizontal, .bottom], 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentSecondary.opacity(0.25), lineWidth: 1)
        )
    }

    #if os(iOS)
    // MARK: - Home WiFi SSID Sub-section

    private var homeWiFiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Sub-header
            HStack(spacing: 6) {
                Image(systemName: "house.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textTertiary)
                Text("Home WiFi Networks")
                    .font(.labelMedium)
                    .foregroundColor(.textTertiary)
            }

            // Detected network row
            HStack(spacing: 8) {
                if networkMonitor.isRefreshing {
                    ProgressView().tint(.accentPrimary).scaleEffect(0.75)
                } else if let ssid = networkMonitor.currentSSID {
                    Image(systemName: "wifi")
                        .font(.system(size: 13))
                        .foregroundColor(.statusOnline)
                    Text(ssid)
                        .font(.monoSmall)
                        .foregroundColor(.statusOnline)
                } else if networkMonitor.isOnWifi {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 13))
                        .foregroundColor(.statusWarning)
                    Text("Unknown network")
                        .font(.labelSmall)
                        .foregroundColor(.statusWarning)
                } else {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 13))
                        .foregroundColor(.textTertiary)
                    Text("Not on WiFi")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
                Spacer()
                Button {
                    // Explicit user tap → always query, same rationale as the
                    // Refresh button in the Settings Home WiFi section.
                    NetworkMonitor.shared.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.accentPrimary)
                }
                .buttonStyle(.plain)
                .disabled(networkMonitor.isRefreshing)
            }
            .padding(10)
            .background(Color.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // On WiFi but SSID is nil → user hasn't granted Location (Precise).
            // Surface a one-tap Settings deep-link instead of only text so users
            // don't have to hunt through Privacy → Location Services manually.
            if networkMonitor.isOnWifi && networkMonitor.currentSSID == nil && !networkMonitor.isRefreshing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 13))
                            .foregroundColor(.statusWarning)
                            .padding(.top, 1)
                        Text("Allow Location (Precise) so AerioTV can read your WiFi name and auto-switch to the local URL at home.")
                            .font(.labelSmall)
                            .foregroundColor(.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                            Text("Open Settings")
                        }
                        .font(.labelMedium.weight(.semibold))
                        .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.statusWarning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // SSID entries
            ForEach(ssidEntries.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Image(systemName: !ssidEntries[index].isEmpty && networkMonitor.currentSSID == ssidEntries[index]
                          ? "checkmark.circle.fill" : "wifi")
                        .font(.system(size: 14))
                        .foregroundColor(!ssidEntries[index].isEmpty && networkMonitor.currentSSID == ssidEntries[index]
                                         ? .statusOnline : .textTertiary)
                    TextField("Home WiFi SSID \(index + 1)", text: $ssidEntries[index])
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if ssidEntries.count > 1 {
                        Button {
                            ssidEntries.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 18))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Add network buttons
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
                        HStack(spacing: 6) {
                            Image(systemName: "wifi.circle.fill")
                            Text("Add \"\(currentSSID)\"")
                        }
                        .font(.labelMedium)
                        .foregroundColor(.statusOnline)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    ssidEntries.append("")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Network Manually")
                    }
                    .font(.labelMedium)
                    .foregroundColor(.accentPrimary)
                }
                .buttonStyle(.plain)
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
    }
    #endif

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

    // MARK: - Helpers

    private func urlProtocolBadge(url: String) -> some View {
        let isHTTPS = url.lowercased().hasPrefix("https")
        return HStack(spacing: 4) {
            Circle()
                .fill(isHTTPS ? Color.statusOnline : Color.statusWarning)
                .frame(width: 6, height: 6)
            Text(isHTTPS ? "HTTPS" : "HTTP")
                .font(.monoSmall)
                .foregroundColor(isHTTPS ? .statusOnline : .statusWarning)
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

    // MARK: - Dispatcharr Onboarding

    @ViewBuilder
    private var dispatcharrOnboardingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Device Identity")
                .font(.headline)
                .foregroundColor(.textPrimary)
            Text("This name identifies your device in Dispatcharr's admin panel.")
                .font(.subheadline)
                .foregroundColor(.textSecondary)
            AppTextField("Device Name", placeholder: DeviceInfo.modelName,
                         text: $deviceNickname, icon: "iphone")

            Divider().padding(.vertical, 8)

            Text("Default Recording Destination")
                .font(.headline)
                .foregroundColor(.textPrimary)
            Text("Where should recordings be saved by default? Server-side is recommended — recordings continue even when AerioTV is closed.")
                .font(.subheadline)
                .foregroundColor(.textSecondary)

            Picker("Destination", selection: $dvrDestination) {
                Text("Dispatcharr server (recommended)").tag(RecordingDestination.dispatcharrServer)
                Text("This device").tag(RecordingDestination.local)
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .background(Color.cardBackground.cornerRadius(12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func saveServer() {
        // Deactivate all existing servers so only the newly added one is active.
        let existing = (try? modelContext.fetch(FetchDescriptor<ServerConnection>())) ?? []
        for s in existing { s.isActive = false }
        let server = viewModel.buildServerConnection()
        server.isVerified = true
        server.lastConnected = Date()
        // Dispatcharr onboarding extras
        if server.type == .dispatcharrAPI {
            server.defaultRecordingDestination = dvrDestination
            DeviceInfo.deviceNickname = deviceNickname
        }
        modelContext.insert(server)
        try? modelContext.save()
        onSave?(server)
        // Defer credential sync to next run loop to avoid freezing during view transition
        DispatchQueue.main.async {
            SyncManager.shared.saveCredentialsSynced(for: server)
        }
        // Show the sync loading screen when adding from Settings (onSave != nil).
        // During onboarding, skip the sync view — the app root auto-detects the new server
        // and transitions to MainTabView, which handles initial data loading itself.
        if onSave != nil {
            savedServer = server
        } else {
            dismiss()
        }
    }
}
