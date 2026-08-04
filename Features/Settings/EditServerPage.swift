//
//  EditServerPage.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

#if os(tvOS)  // Phase 1 split: re-opened, block spanned the extraction cut
struct EditServerPage: View {
    @Bindable var server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    /// Task #189: Channel Profile picker state (Dispatcharr only).
    @State private var channelProfiles: [DispatcharrAPI.ChannelProfileSummary] = []
    @State private var channelProfilesLoadFailed = false

    /// Task #189: one radio-style row of the Channel Profile picker.
    /// id == nil is the "All Channels" row.
    @ViewBuilder
    private func channelProfileRow(name: String, count: Int?, id: Int?) -> some View {
        Button {
            server.dispatcharrSelectedProfileID = id
        } label: {
            HStack {
                if let count {
                    Text("\(name) (\(count) channels)")
                        .font(.system(size: 28, weight: .medium))
                } else {
                    Text(name)
                        .font(.system(size: 28, weight: .medium))
                }
                Spacer()
                if server.dispatcharrSelectedProfileID == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.accentPrimary)
                }
            }
        }
    }

    /// Task #189: load the server's Channel Profiles for the picker.
    private func loadChannelProfiles() async {
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        do {
            channelProfiles = try await api.listChannelProfiles()
            channelProfilesLoadFailed = false
        } catch {
            channelProfilesLoadFailed = true
            debugLog("[PROFILE-PICKER] tvOS listChannelProfiles failed: \(error.localizedDescription)")
        }
    }
    /// See SettingsView. Tvos edit page uses accent-tinted Save
    /// button + form field underlines; without this they freeze at
    /// whichever theme was active when the page was first pushed.
    @ObservedObject private var theme = ThemeManager.shared

    // 2026-07 unification: the EPG Cache / Full Refresh actions moved
    // to the playlist detail page (ServerDetailView), which tvOS now
    // reaches the same way iOS does. This page is purely the edit form.

    // v1.7.x: Direct Connect mode picker + Refresh Session button
    // state. Mirrors EditServerSheet's iOS Form path so Apple TV
    // users can switch credential modes after server creation
    // without going to a different device. See `EditServerSheet`
    // for the per-property doc.
    @State private var pendingCredentialType: DispatcharrCredentialType? = nil
    @State private var isRefreshingSession: Bool = false
    @State private var sessionRefreshMessage: String? = nil
    @State private var sessionRefreshSucceeded: Bool = false

    private var effectiveCredentialType: DispatcharrCredentialType {
        pendingCredentialType ?? server.dispatcharrCredentialType
    }

    private var directConnectModeBinding: Binding<DispatcharrCredentialType> {
        Binding(
            get: { effectiveCredentialType },
            set: { newValue in
                pendingCredentialType = newValue
                sessionRefreshMessage = nil
            }
        )
    }

    private func commitCredentialModeIfStaged() {
        guard let pending = pendingCredentialType else { return }
        server.dispatcharrCredentialTypeRaw = (pending == .apiKey) ? "" : pending.rawValue
        pendingCredentialType = nil
    }

    private func maskedAPIKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return String(repeating: "•", count: trimmed.count) }
        let prefix = trimmed.prefix(2)
        let suffix = trimmed.suffix(8)
        return "\(prefix)\(String(repeating: "•", count: 6))\(suffix)"
    }

    @MainActor
    private func refreshDirectConnectSession() async {
        let username = server.username
        let password = server.effectivePassword
        let baseURL  = server.effectiveBaseURL
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
                        tvSection("EPG Source") {
                            tvField("Custom XMLTV URL (optional)", text: $server.xtreamXMLTVURL)
                            Text("Optional. Adds Sports/News/Movies/Kids color tints from this XMLTV feed's category tags. Xtream Codes doesn't expose categories on its own.")
                                .font(.system(size: 22))
                                .foregroundColor(.textTertiary)
                                .padding(.top, 4)
                        }
                    } else if server.type == .dispatcharrAPI {
                        Group {
                            tvSection("Authentication") {
                                // v1.7.x: credential mode picker on
                                // tvOS Edit Server. The Apple TV
                                // typing-burden is the primary reason
                                // Direct Connect exists; the edit
                                // screen needs to support switching
                                // modes here too so users don't have
                                // to go to a different device.
                                Picker("Sign-in method", selection: directConnectModeBinding) {
                                    Text("Username & Password").tag(DispatcharrCredentialType.usernamePassword)
                                    Text("API Key").tag(DispatcharrCredentialType.apiKey)
                                }
                                .pickerStyle(.segmented)
                                .padding(.vertical, 8)

                                switch effectiveCredentialType {
                                case .usernamePassword:
                                    tvField("Username", text: $server.username)
                                    tvField("Password", text: $server.password, isSecure: true)
                                    // v1.7.x: Dashboard-vs-XC password
                                    // hint mirrored on tvOS Edit Server
                                    // (the legacy ScrollView+VStack path).
                                    Text("Use your Dispatcharr Dashboard password (System → Users → Account tab), not your Dispatcharr XC password.")
                                        .font(.system(size: 22))
                                        .foregroundColor(.textTertiary)
                                        .padding(.top, 4)
                                    if !server.effectiveApiKey.isEmpty {
                                        HStack {
                                            Text("API Key (cached)")
                                                .font(.system(size: 28, weight: .medium))
                                                .foregroundColor(.textSecondary)
                                            Spacer()
                                            Text(maskedAPIKey(server.effectiveApiKey))
                                                .font(.system(size: 22, design: .monospaced))
                                                .foregroundColor(.textTertiary)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    Button {
                                        Task { await refreshDirectConnectSession() }
                                    } label: {
                                        HStack(spacing: 8) {
                                            if isRefreshingSession {
                                                ProgressView().scaleEffect(0.8)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                            }
                                            Text(isRefreshingSession ? "Refreshing…" : "Refresh Session")
                                        }
                                        .font(.system(size: 26, weight: .semibold))
                                    }
                                    .disabled(server.username.isEmpty
                                              || server.effectivePassword.isEmpty
                                              || isRefreshingSession)
                                    .padding(.top, 6)
                                    if let msg = sessionRefreshMessage {
                                        Text(msg)
                                            .font(.system(size: 22))
                                            .foregroundColor(sessionRefreshSucceeded ? .statusOnline : .statusLive)
                                            .padding(.top, 2)
                                    } else {
                                        Text("Use if streaming or logos suddenly fail. Re-fetches the API key from your Dispatcharr account.")
                                            .font(.system(size: 22))
                                            .foregroundColor(.textTertiary)
                                            .padding(.top, 2)
                                    }
                                case .apiKey:
                                    tvField("Admin API Key", text: $server.apiKey, isSecure: true)
                                }
                            }
                            tvSection("EPG Source") {
                                tvField("Custom XMLTV URL (optional)", text: $server.dispatcharrXMLTVURL)
                                Text("EPG is loaded via Dispatcharr's REST API by default. This optional override is reserved for environments where you want AerioTV to fetch a different XMLTV feed directly. Leave blank for normal use.")
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

                    // User-Agent (Dispatcharr only) -- parity with the
                    // iOS edit sheet.
                    if server.type == .dispatcharrAPI {
                        tvSection("User-Agent") {
                            tvField("User-Agent", text: $server.customUserAgent)
                            Text("Shown in Dispatcharr's admin Stats panel to identify this device. Leave blank for default: \(DeviceInfo.defaultUserAgent)")
                                .font(.system(size: 22))
                                .foregroundColor(.textTertiary)
                                .padding(.top, 4)
                        }
                    }

                    // On Demand (per-server VOD toggle). Previously this
                    // and Guide History only existed on the iOS edit
                    // sheet; Apple TV users had no way to change them.
                    if server.supportsVOD {
                        tvSection("On Demand") {
                            Toggle("Fetch On Demand from this playlist", isOn: $server.vodEnabled)
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(.textPrimary)
                                .padding(.vertical, 4)
                            Text("When off, this playlist's movies and TV shows aren't loaded into On Demand. Useful if you only want Live TV from this server, or if you have a second playlist that already provides On Demand.")
                                .font(.system(size: 22))
                                .foregroundColor(.textTertiary)
                                .padding(.top, 4)
                        }
                    }

                    // Guide History (catch-up retention)
                    tvSection("Guide History") {
                        Picker("Guide History", selection: $server.epgRetentionDays) {
                            Text("1 day").tag(1)
                            Text("3 days").tag(3)
                            Text("7 days (default)").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                        }
                        .pickerStyle(.segmented)
                        Text("How many days of already-aired guide data to keep for this playlist. Past shows on channels with catch-up can be replayed from the guide. Longer history means a larger guide cache.")
                            .font(.system(size: 22))
                            .foregroundColor(.textTertiary)
                            .padding(.top, 4)
                    }

                    // Task #189 (Android parity): user-chosen Channel
                    // Profile. Radio-style rows (like Android's picker);
                    // a segmented control can't hold N variable-length
                    // profile names on tvOS.
                    if server.type == .dispatcharrAPI {
                        tvSection("Channel Profile") {
                            channelProfileRow(name: "All Channels", count: nil, id: nil)
                            ForEach(channelProfiles) { profile in
                                channelProfileRow(name: profile.name,
                                                  count: profile.channels.count,
                                                  id: profile.id)
                            }
                            Text(channelProfilesLoadFailed
                                 ? "Couldn't load this server's Channel Profiles. All Channels stays in effect; check the connection and reopen this page to retry."
                                 : "Sync only the channels in a Dispatcharr Channel Profile. Changes apply on the next channel refresh.")
                                .font(.system(size: 22))
                                .foregroundColor(.textTertiary)
                                .padding(.top, 4)
                        }
                        .task { await loadChannelProfiles() }
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
                            // v1.7.x (Round 1 review): commit any
                            // staged credential-mode change before
                            // persisting credentials. tvOS edit
                            // surface mirrors iOS Save behavior.
                            commitCredentialModeIfStaged()
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
                // v1.7.5: cap the content to a centered reading column
                // instead of letting every row span the full 1920pt TV
                // width (Archie field report: tvOS settings "look like
                // stretched out iPhone/iPad screens"). 1200pt keeps the
                // 28pt form text comfortably readable at couch distance
                // with generous side margins, the conventional tvOS form
                // proportion. The inner cap is left-aligned; the outer
                // infinity-width frame centers that capped column.
                .frame(maxWidth: 1200, alignment: .leading)
                .padding(48)
                .frame(maxWidth: .infinity)
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
            TVSettingsTextField(placeholder: placeholder, text: text, isSecure: isSecure)
        }
    }
}

// MARK: - Shared tvOS settings text field
//
// v1.7.5 (Archie field screenshot): the tvOS settings field helpers
// (tvField / tvEditField) rolled their own bare TextField that forced a
// light `.textPrimary` colour at all times. tvOS fills a FOCUSED TextField
// with a solid white "platter" and expects dark text inside it, so our
// light text became white-on-white and unreadable on the focused field.
//
// The app's standard field component, AppTextField, already solved this
// exact bug in v1.6.21 and documented (see its tvOS notes) that the white
// fill CANNOT be cleanly removed in pure SwiftUI - that needs a
// UIViewRepresentable UITextField with custom focused-appearance overrides.
// So rather than fight the system fill, we match AppTextField: switch the
// text to dark when focused (readable against the white fill) and keep the
// light colour when unfocused (readable against the dark elevatedBackground),
// plus an accent border so the focused field is obvious. Every settings
// field helper routes through this, so the fix lands on every server
// add/edit screen at once and stays consistent with the onboarding fields.
#endif  // Phase 1 split: closes a block that spanned the extraction cut
