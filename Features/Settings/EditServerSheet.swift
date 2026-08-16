//
//  EditServerSheet.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

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

    // v1.7.x: Direct Connect "Refresh Session" button state.
    @State private var isRefreshingSession: Bool = false
    @State private var sessionRefreshMessage: String? = nil
    @State private var sessionRefreshSucceeded: Bool = false

    /// v1.7.x (Round 1 review): credential mode is staged in
    /// SwiftUI state instead of writing through to SwiftData
    /// immediately. Pre-fix the picker used a Binding that wrote
    /// `server.dispatcharrCredentialTypeRaw` directly, so flipping
    /// the picker and then tapping Cancel still persisted the new
    /// mode — leaving servers in a half-configured state if the
    /// user explored the picker without intending to commit.
    /// `nil` means "user hasn't touched the picker"; non-nil means
    /// "staged change pending Save". Persisted in `commitEdits()`.
    @State private var pendingCredentialType: DispatcharrCredentialType? = nil

    /// Oki's debug log (2026-08-16 12:51:54): the URL TextField bound
    /// `$server.baseURL` directly, so EVERY keystroke persisted to
    /// SwiftData, changed `channelServerKey`, and restarted MainTabView's
    /// `.task(id: orchestratorKey)` - a full channels + EPG + recordings +
    /// VOD reload against each half-typed host (`:919`, `:91`, `:9`, `:5`,
    /// `:56`, `:565` as he retyped a port), each hanging to an 8s timeout.
    /// Same staging pattern as `pendingCredentialType` above: the edit
    /// lives in @State until Save, so intermediate keystrokes never reach
    /// the model or its observers, and Cancel discards for free.
    @State private var pendingBaseURL: String? = nil

    /// Binds the URL TextField. Reads through to the model until the user
    /// types; writes stage into `pendingBaseURL` only.
    private var baseURLBinding: Binding<String> {
        Binding(
            get: { pendingBaseURL ?? server.baseURL },
            set: { pendingBaseURL = $0 }
        )
    }

    /// Apply the staged URL to the model. Called from Save, before the
    /// credential commit, so `saveCredentialsSynced` sees the final URL.
    private func commitBaseURLIfStaged() {
        guard let pending = pendingBaseURL else { return }
        server.baseURL = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBaseURL = nil
    }

    /// v1.7.x: read view of the credential mode that respects any
    /// staged change. Body switches on this so revealing the
    /// alternate fields is immediate while the model write is
    /// deferred to Save.
    private var effectiveCredentialType: DispatcharrCredentialType {
        pendingCredentialType ?? server.dispatcharrCredentialType
    }

    /// v1.7.x: binds the credential-mode segmented picker. Stages
    /// the pick into `pendingCredentialType`; the actual SwiftData
    /// write happens in `commitEdits()` if the user taps Save.
    /// Tapping Cancel discards the staged value because it's
    /// SwiftUI @State, not bound to the model.
    private var directConnectModeBinding: Binding<DispatcharrCredentialType> {
        Binding(
            get: { effectiveCredentialType },
            set: { newValue in
                pendingCredentialType = newValue
                // Clear the refresh-session message when the user
                // pivots so a stale "Refreshed at 12:34" pill
                // doesn't linger on the wrong mode.
                sessionRefreshMessage = nil
            }
        )
    }

    /// v1.7.x: apply staged credential-mode change to the model.
    /// Called from the Save action of the edit sheet. Keeps the
    /// SwiftData write in one place so the no-op default (`""`
    /// raw) is preserved when the user picks `.apiKey` (forward-
    /// compat with older AerioTV builds receiving this server via
    /// iCloud sync — they ignore unknown KVS keys).
    private func commitCredentialModeIfStaged() {
        guard let pending = pendingCredentialType else { return }
        server.dispatcharrCredentialTypeRaw = (pending == .apiKey) ? "" : pending.rawValue
        pendingCredentialType = nil
    }

    /// v1.7.x: render the cached api_key as `i_•••••cudvh13H1A`
    /// (first 2 chars + dots + last 8). Long enough to identify if
    /// it matches the one shown in Dispatcharr's admin UI; redacted
    /// enough that a screenshot doesn't leak it. Mirrors how
    /// 1Password and similar apps surface secrets.
    private func maskedAPIKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return String(repeating: "•", count: trimmed.count) }
        let prefix = trimmed.prefix(2)
        let suffix = trimmed.suffix(8)
        return "\(prefix)\(String(repeating: "•", count: 6))\(suffix)"
    }

    /// v1.7.x: force-refresh a Direct Connect server's JWT pair.
    /// Performs a fresh login against /api/accounts/token/, then
    /// re-fetches /api/accounts/users/me/ to update the cached
    /// api_key (covers the admin-rotated-the-key case where Aerio's
    /// Keychain copy is stale and downstream long-lived consumers
    /// like mpv stream playback would 401).
    @MainActor
    private func refreshDirectConnectSession() async {
        let username = server.username
        let password = server.effectivePassword
        // Staged-URL aware: if the user retyped the URL and taps Refresh
        // Session before Save, log in against the visible value.
        let baseURL  = pendingBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? server.effectiveBaseURL
        let userAgent = server.effectiveUserAgent
        let serverID = server.id
        guard !username.isEmpty, !password.isEmpty else {
            sessionRefreshMessage = "Username and password required."
            sessionRefreshSucceeded = false
            return
        }

        isRefreshingSession = true
        sessionRefreshMessage = nil
        defer { isRefreshingSession = false }

        do {
            let pair = try await DispatcharrAPI.login(
                baseURL: baseURL,
                username: username,
                password: password,
                userAgent: userAgent
            )
            DispatcharrTokenStore.shared.store(
                serverID: serverID,
                access: pair.access,
                refresh: pair.refresh
            )

            // Re-fetch the user record so we pick up any rotated
            // api_key. Update the SwiftData record + Keychain so
            // every downstream consumer sees the fresh value.
            // v1.7.x (Round 1 review): differentiate the success
            // message based on whether the api_key actually
            // changed. Pre-fix the message was the same regardless,
            // which made the button feel like a no-op even when it
            // actively rescued a stale-Keychain situation.
            let bearerAPI = DispatcharrAPI(baseURL: baseURL, auth: .bearer(pair.access))
            var apiKeyRotated = false
            if let user = try? await bearerAPI.fetchCurrentUser(),
               !user.apiKey.isEmpty,
               user.apiKey != server.effectiveApiKey {
                server.apiKey = user.apiKey
                SyncManager.shared.saveCredentialsSynced(for: server)
                apiKeyRotated = true
            }

            sessionRefreshSucceeded = true
            sessionRefreshMessage = apiKeyRotated
                ? "Session refreshed. Cached API key updated."
                : "Session refreshed. API key unchanged."
        } catch let error as DispatcharrDirectConnectError {
            sessionRefreshSucceeded = false
            sessionRefreshMessage = error.errorDescription ?? "Refresh failed."
        } catch {
            sessionRefreshSucceeded = false
            sessionRefreshMessage = error.localizedDescription
        }
    }

    var body: some View {
        // Guard against the server being deleted mid-edit by an iCloud sync merge
        // (SwiftData detached-model crash; same root cause as ServerDetailView).
        // Pop instead of reading @Persisted props off a detached model.
        Group {
            if server.modelContext == nil {
                Color.appBackground.ignoresSafeArea()
            } else {
                editContent
            }
        }
        .onChange(of: server.modelContext == nil) { _, deleted in
            if deleted { dismiss() }
        }
    }

    private var editContent: some View {
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
                        // v1.7.x (Round 1 review): commit any
                        // staged credential-mode change before
                        // persisting credentials. Cancel skips
                        // this step, so toggling the picker and
                        // backing out leaves the model unchanged.
                        commitBaseURLIfStaged()
                        commitCredentialModeIfStaged()
                        SyncManager.shared.saveCredentialsSynced(for: server)
                        dismiss()
                    }
                    .foregroundColor(.accentPrimary)
                    .fontWeight(.semibold)
                    .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              (pendingBaseURL ?? server.baseURL)
                                  .trimmingCharacters(in: .whitespaces).isEmpty)
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
                TextField("URL", text: baseURLBinding)
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
                Section {
                    TextField("Custom XMLTV URL (optional)",
                              text: $server.xtreamXMLTVURL,
                              prompt: Text(verbatim: "https://example.com/xmltv.xml"))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("EPG Source").sectionHeaderStyle()
                } footer: {
                    Text("Optional. Adds Sports/News/Movies/Kids color tints from this XMLTV feed's category tags. Xtream Codes doesn't expose categories on its own. Leave blank to skip.")
                }
            } else if server.type == .dispatcharrAPI {
                Section {
                    // v1.7.x: credential mode picker. Mirrors
                    // AddServerView's segmented control. Persists
                    // the user's choice to
                    // `dispatcharrCredentialTypeRaw` on the
                    // SwiftData record so it syncs cross-device
                    // via SyncManager.serialize.
                    Picker("Sign-in method", selection: directConnectModeBinding) {
                        Text("Username & Password").tag(DispatcharrCredentialType.usernamePassword)
                        Text("API Key").tag(DispatcharrCredentialType.apiKey)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.cardBackground)

                    switch effectiveCredentialType {
                    case .usernamePassword:
                        TextField("Username", text: $server.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .listRowBackground(Color.cardBackground)
                        SecureField("Password", text: $server.password)
                            .listRowBackground(Color.cardBackground)
                        // v1.7.x: same Dashboard-vs-XC password hint
                        // as the Add Server flow. Surface here too so
                        // existing servers being switched to
                        // Username & Password (or whose user just
                        // rotated their UI password) see the same
                        // guidance without having to retrace through
                        // onboarding.
                        Text("Use your Dispatcharr Dashboard password (System → Users → Account tab), not your Dispatcharr XC password.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                            .listRowBackground(Color.cardBackground)
                        // Show the cached API key (read-only) so the
                        // user can see it was fetched from
                        // /api/accounts/users/me/ and is keeping
                        // long-lived connections (mpv, logos)
                        // working. Hidden in this row when empty
                        // (e.g. server was just switched and warmup
                        // hasn't completed yet).
                        if !server.effectiveApiKey.isEmpty {
                            HStack {
                                Text("API Key (cached)")
                                    .foregroundColor(.textTertiary)
                                Spacer()
                                Text(maskedAPIKey(server.effectiveApiKey))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundColor(.textSecondary)
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                    case .apiKey:
                        SecureField("Admin API Key", text: $server.apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .listRowBackground(Color.cardBackground)
                    }

                    // Refresh Session button — only shown in
                    // Username & Password mode. Forces an immediate
                    // /api/accounts/token/ login to refresh the JWT
                    // pair AND re-fetches /api/accounts/users/me/
                    // to update the cached api_key (covers the
                    // server-side rotation case where an admin
                    // rolled the key and Aerio's cached copy is
                    // stale).
                    if effectiveCredentialType == .usernamePassword {
                        Button {
                            Task { await refreshDirectConnectSession() }
                        } label: {
                            HStack(spacing: 6) {
                                if isRefreshingSession {
                                    ProgressView().tint(.accentPrimary).scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(isRefreshingSession ? "Refreshing…" : "Refresh Session")
                            }
                            .font(.labelMedium.weight(.semibold))
                            .foregroundColor(.accentPrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(server.username.isEmpty
                                  || server.effectivePassword.isEmpty
                                  || isRefreshingSession)
                        .listRowBackground(Color.cardBackground)
                        if let msg = sessionRefreshMessage {
                            Text(msg)
                                .font(.labelSmall)
                                .foregroundColor(sessionRefreshSucceeded ? .statusOnline : .statusLive)
                                .listRowBackground(Color.cardBackground)
                        } else {
                            // v1.7.x (Round 1 review): caption
                            // explaining when to tap. Pre-fix the
                            // button was unlabeled and most users
                            // would never know what it did.
                            Text("Use if streaming or logos suddenly fail. Re-fetches the API key from your Dispatcharr account.")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                                .listRowBackground(Color.cardBackground)
                        }
                    }
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
                    Text("EPG is loaded via Dispatcharr's REST API by default. This optional override is reserved for environments where you want AerioTV to fetch a different XMLTV feed directly. Leave blank for normal use.")
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
                    Text("Used automatically whenever the server is reachable on your local network. No setup needed. Leave blank to always use the main URL.")
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
                    Toggle("Fetch On Demand from this playlist", isOn: $server.vodEnabled)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("On Demand").sectionHeaderStyle()
                } footer: {
                    Text("When off, this playlist's movies and TV shows aren't loaded into On Demand. Useful if you only want Live TV from this server, or if you have a second playlist that already provides On Demand.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }

            // Catch-up: how far back guide data is retained. Bounds the
            // "Previously aired" history in the List view and the
            // replay window shown in the Guide.
            Section {
                Picker("Guide History", selection: $server.epgRetentionDays) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days (default)").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Guide History").sectionHeaderStyle()
            } footer: {
                Text("How many days of already-aired guide data to keep for this playlist. Past shows on channels with catch-up can be replayed from the guide. Longer history means a larger guide cache.")
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
            }

            // Task #189 (Android parity): user-chosen Channel Profile.
            if server.type == .dispatcharrAPI {
                ChannelProfilePickerSection(server: server)
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
    // EditServerSheet is never presented on tvOS -- editing goes through
    // the pushed EditServerPage below. This stub only keeps the struct
    // compiling for the tvOS target.
    private var tvOSEditContent: some View { EmptyView() }
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
/// Task #189 (Android parity): "Channel Profile" section of the iOS/iPad
/// edit form. Lists the Dispatcharr server's Channel Profiles
/// (`/api/channels/profiles/`) and stores the user's pick on
/// `server.dispatcharrSelectedProfileID` (nil = All Channels). The filter
/// itself is applied fail-open at channel sync in
/// `ChannelStore.fetchDispatcharr`. Mirrors Android
/// EditPlaylistScreen's Channel Profile section.
private struct ChannelProfilePickerSection: View {
    @Bindable var server: ServerConnection
    @State private var profiles: [DispatcharrAPI.ChannelProfileSummary] = []
    @State private var loadFailed = false

    var body: some View {
        Section {
            Picker("Channel Profile", selection: $server.dispatcharrSelectedProfileID) {
                Text("All Channels").tag(Int?.none)
                ForEach(profiles) { profile in
                    Text("\(profile.name) (\(profile.channels.count) channels)")
                        .tag(Int?.some(profile.id))
                }
            }
            .listRowBackground(Color.cardBackground)
        } header: {
            Text("Channel Profile").sectionHeaderStyle()
        } footer: {
            Text(loadFailed
                 ? "Couldn't load this server's Channel Profiles. All Channels stays in effect; check the connection and reopen this page to retry."
                 : "Sync only the channels in a Dispatcharr Channel Profile. Changes apply on the next channel refresh.")
                .font(.labelSmall)
                .foregroundColor(.textTertiary)
        }
        .task { await loadProfiles() }
    }

    private func loadProfiles() async {
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        do {
            profiles = try await api.listChannelProfiles()
            loadFailed = false
        } catch {
            loadFailed = true
            debugLog("[PROFILE-PICKER] listChannelProfiles failed: \(error.localizedDescription)")
        }
    }
}


#if os(tvOS)
#endif  // Phase 1 split: closes a block that spanned the extraction cut
