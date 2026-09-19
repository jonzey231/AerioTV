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
                        .scaledFont(.system(size: 28, weight: .medium))
                } else {
                    Text(name)
                        .scaledFont(.system(size: 28, weight: .medium))
                }
                Spacer()
                if server.dispatcharrSelectedProfileID == id {
                    Image(systemName: "checkmark")
                        .scaledFont(.system(size: 24, weight: .semibold))
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

    /// Oki's debug log (2026-08-16 12:51:54): binding the URL field
    /// straight to `$server.baseURL` persisted every keystroke, and each
    /// write restarted MainTabView's `.task(id: orchestratorKey)` full
    /// reload against the half-typed host. Staged in @State until Save,
    /// same pattern as `pendingCredentialType`. Mirrors EditServerSheet.
    @State private var pendingBaseURL: String? = nil

    /// Which account this playlist was connected as when the page opened.
    /// Save diffs against it so a credential swap triggers a full
    /// re-authentication while a rename or an EPG-URL edit costs nothing.
    /// See `ServerCredentialChange` for what a swap has to invalidate.
    @State private var originalCredentials: DispatcharrCredentialSnapshot? = nil

    /// See `EditServerSheet.saveEdits` for the rationale: Save verifies a
    /// credential change before persisting anything, shows "Saving…", and
    /// stays on the page with the typed values when the server rejects it.
    @State private var isSaving = false
    @State private var saveErrorMessage: String? = nil

    /// Stage source for the "Saving Changes" cover, the same staged screen
    /// the Add Playlist flow shows. See `PlaylistSaveRunner`.
    @StateObject private var saveProgress = PlaylistSaveProgress()

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { pendingBaseURL ?? server.baseURL },
            set: { pendingBaseURL = $0 }
        )
    }

    private func commitBaseURLIfStaged() {
        guard let pending = pendingBaseURL else { return }
        server.baseURL = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBaseURL = nil
    }
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

    /// Save Playlist (tvOS). Mirrors `EditServerSheet.saveEdits`.
    @MainActor
    private func saveEdits() async {
        guard !isSaving else { return }
        saveErrorMessage = nil
        // Raises the "Saving Changes" cover. Cleared explicitly rather than
        // in a `defer` so it is down before the page pops on success.
        isSaving = true

        let typedBaseURL = (pendingBaseURL ?? server.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = effectiveCredentialType
        let message = await PlaylistSaveRunner.run(
            server: server,
            typedBaseURL: typedBaseURL,
            credentialType: mode,
            originalCredentials: originalCredentials,
            progress: saveProgress,
            commitStaged: {
                commitBaseURLIfStaged()
                commitCredentialModeIfStaged()
            }
        )
        isSaving = false
        if let message {
            // Straight back to the form with the typed values intact. The
            // "Save Failed" section sits directly above the Save button, so
            // it is on screen where focus already is.
            saveErrorMessage = message
            return
        }
        originalCredentials = DispatcharrCredentialSnapshot.capture(from: server)
        dismiss()
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
        // Use what the user just TYPED, not the Keychain copy:
        // `effectivePassword` is Keychain-first, so validating with it
        // would test the OLD password on a sheet where the user is
        // replacing it -- reporting success for credentials that are on
        // their way out, or failure for correct new ones.
        let password = server.password.isEmpty ? server.effectivePassword : server.password
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
        .onAppear {
            guard server.modelContext != nil, originalCredentials == nil else { return }
            originalCredentials = DispatcharrCredentialSnapshot.capture(from: server)
        }
    }

    private var editContent: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    // Connection
                    SettingsSection("Connection", style: .eyebrowCard) {
                        // Phase 3 item 2: every Settings field is now the
                        // shared SettingsTextField, so label placement,
                        // helper copy and focus outline match iOS and
                        // Android exactly.
                        SettingsTextField("Name", text: $server.name)
                        SettingsTextField("URL", text: baseURLBinding,
                                          keyboardType: .URL)
                    }

                    // Credentials
                    if server.type == .xtreamCodes {
                        SettingsSection("Credentials", style: .eyebrowCard) {
                            SettingsTextField("Username", text: $server.username)
                            SettingsTextField("Password", text: $server.password,
                                              isSecure: true)
                        }
                        SettingsSection("EPG Source", style: .eyebrowCard) {
                            // Phase 3 item 2: the old section footer described
                            // this one field, so it became the field's helper.
                            // Same string as iOS and Android.
                            SettingsTextField("Custom XMLTV URL (optional)",
                                              placeholder: "https://example.com/xmltv.xml",
                                              text: $server.xtreamXMLTVURL,
                                              helper: "Optional. Adds Sports/News/Movies/Kids color tints from this XMLTV feed's category tags. Xtream Codes doesn't expose categories on its own. Leave blank to skip.",
                                              keyboardType: .URL)
                        }
                    } else if server.type == .dispatcharrAPI {
                        Group {
                            SettingsSection("Authentication", style: .eyebrowCard) {
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
                                    SettingsTextField("Username", text: $server.username)
                                    // Phase 3 item 2: the Dashboard-vs-XC hint
                                    // belongs to the password field alone, so
                                    // it is the field's helper now instead of a
                                    // loose caption under the section.
                                    SettingsTextField("Password", text: $server.password,
                                                      helper: "Use your Dispatcharr Dashboard password (System → Users → Account tab), not your Dispatcharr XC password.",
                                                      isSecure: true)
                                    if !server.effectiveApiKey.isEmpty {
                                        HStack {
                                            Text("API Key (cached)")
                                                .scaledFont(.system(size: 28, weight: .medium).subtext())
                                                .foregroundColor(Color.contrastText(.textSecondary))
                                            Spacer()
                                            Text(maskedAPIKey(server.effectiveApiKey))
                                                .scaledFont(.system(size: 22, design: .monospaced).subtext())
                                                .foregroundColor(Color.contrastText(.textTertiary))
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
                                        .scaledFont(.system(size: 26, weight: .semibold))
                                    }
                                    .disabled(server.username.isEmpty
                                              || server.effectivePassword.isEmpty
                                              || isRefreshingSession)
                                    .padding(.top, 6)
                                    if let msg = sessionRefreshMessage {
                                        Text(msg)
                                            .scaledFont(.system(size: 22))
                                            .foregroundColor(sessionRefreshSucceeded ? .statusOnline : .statusLive)
                                            .padding(.top, 2)
                                    } else {
                                        Text("Use if streaming or logos suddenly fail. Re-fetches the API key from your Dispatcharr account.")
                                            .scaledFont(.system(size: 22).subtext())
                                            .foregroundColor(Color.contrastText(.textTertiary))
                                            .padding(.top, 2)
                                    }
                                case .apiKey:
                                    SettingsTextField("Admin API Key", text: $server.apiKey,
                                                      isSecure: true)
                                }
                            }
                            SettingsSection("EPG Source", style: .eyebrowCard) {
                                // Phase 3 item 2: footer copy folded into the
                                // field it describes; matches iOS and Android.
                                SettingsTextField("Custom XMLTV URL (optional)",
                                                  placeholder: "https://example.com/xmltv.xml",
                                                  text: $server.dispatcharrXMLTVURL,
                                                  helper: "EPG is loaded via Dispatcharr's REST API by default. This optional override is reserved for environments where you want AerioTV to fetch a different XMLTV feed directly. Leave blank for normal use.",
                                                  keyboardType: .URL)
                            }
                        }
                    } else if server.type == .m3uPlaylist {
                        SettingsSection("EPG Guide", style: .eyebrowCard) {
                            SettingsTextField("EPG URL (optional)", text: $server.epgURL,
                                              keyboardType: .URL)
                        }
                    }

                    // Local Network
                    if server.type != .m3uPlaylist {
                        SettingsSection("Local Network", style: .eyebrowCard) {
                            // Phase 3 item 2: tvOS used to say "when the Apple
                            // TV detects"; the helper is now the one shared
                            // device-neutral string used on iOS and Android.
                            SettingsTextField("Local URL", text: $server.localURL,
                                              helper: "Used automatically whenever the server is reachable on your local network. No setup needed. Leave blank to always use the main URL.",
                                              keyboardType: .URL)
                        }
                    }

                    // User-Agent (Dispatcharr only) -- parity with the
                    // iOS edit sheet.
                    if server.type == .dispatcharrAPI {
                        SettingsSection("User-Agent", style: .eyebrowCard) {
                            SettingsTextField("User-Agent",
                                              placeholder: DeviceInfo.defaultUserAgent,
                                              text: $server.customUserAgent,
                                              helper: "Shown in Dispatcharr's admin Stats panel to identify this device. Leave blank for default: \(DeviceInfo.defaultUserAgent)")
                        }
                    }

                    // On Demand (per-server VOD toggle). Previously this
                    // and Guide History only existed on the iOS edit
                    // sheet; Apple TV users had no way to change them.
                    if server.supportsVOD {
                        SettingsSection("On Demand", style: .eyebrowCard) {
                            Toggle("Fetch On Demand from this playlist", isOn: $server.vodEnabled)
                                .scaledFont(.system(size: 28, weight: .medium))
                                .foregroundColor(.textPrimary)
                                .padding(.vertical, 4)
                            Text("When off, this playlist's movies and TV shows aren't loaded into On Demand. Useful if you only want Live TV from this server, or if you have a second playlist that already provides On Demand.")
                                .scaledFont(.system(size: 22).subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                                .padding(.top, 4)
                        }
                    }

                    // Guide Days (window back AND ahead; Logan 2026-09-11)
                    SettingsSection("Guide Days", style: .eyebrowCard) {
                        Picker("Guide Days", selection: $server.epgRetentionDays) {
                            Text("1 day").tag(1)
                            Text("3 days").tag(3)
                            Text("7 days (default)").tag(7)
                            Text("14 days").tag(14)
                            Text("All Available").tag(0)
                        }
                        .pickerStyle(.segmented)
                        Text("How many days of guide data to load, back and ahead. Dispatcharr only; other sources show what their guide carries.")
                            .scaledFont(.system(size: 22).subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                            .padding(.top, 4)
                    }

                    // Task #189 (Android parity): user-chosen Channel
                    // Profile. Radio-style rows (like Android's picker);
                    // a segmented control can't hold N variable-length
                    // profile names on tvOS.
                    if server.type == .dispatcharrAPI {
                        SettingsSection("Channel Profile", style: .eyebrowCard) {
                            channelProfileRow(name: "All Channels", count: nil, id: nil)
                            ForEach(channelProfiles) { profile in
                                channelProfileRow(name: profile.name,
                                                  count: profile.channels.count,
                                                  id: profile.id)
                            }
                            Text(channelProfilesLoadFailed
                                 ? "Couldn't load this server's Channel Profiles. All Channels stays in effect; check the connection and reopen this page to retry."
                                 : "Sync only the channels in a Dispatcharr Channel Profile. Changes apply on the next channel refresh.")
                                .scaledFont(.system(size: 22).subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                                .padding(.top, 4)
                        }
                        .task { await loadChannelProfiles() }
                    }

                    // Info
                    SettingsSection("Info", style: .eyebrowCard) {
                        HStack {
                            Text("Type")
                                .scaledFont(.system(size: 28, weight: .medium).subtext())
                                .foregroundColor(Color.contrastText(.textSecondary))
                            Spacer()
                            Text(server.type.displayName)
                                .scaledFont(.system(size: 28).subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                        }
                        .padding(.vertical, 8)
                    }

                    // Save Failed: the server rejected the new credentials
                    // (or the verification fetch failed). Same section
                    // chrome as the rest of the page.
                    if let saveErrorMessage {
                        SettingsSection("Save Failed", style: .eyebrowCard) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.statusLive)
                                Text(saveErrorMessage)
                                    .scaledFont(.system(size: 24))
                                    .foregroundColor(.statusLive)
                            }
                            .padding(.vertical, 4)
                            Text("Your entries are still here. Fix them and select Save Changes again.")
                                .scaledFont(.system(size: 22).subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                                .padding(.top, 4)
                        }
                    }

                    // Save
                    HStack {
                        Spacer()
                        Button {
                            Task { await saveEdits() }
                        } label: {
                            Text(isSaving ? "Saving…" : "Save Changes")
                                .scaledFont(.system(size: 28, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 48)
                                .padding(.vertical, 14)
                                .background(LinearGradient.accentGradient)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(TVNoHighlightButtonStyle(settingsStyle: true))
                        .tvFocusRingShape(.capsule)
                        .disabled(isSaving ||
                                  server.name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  (pendingBaseURL ?? server.baseURL)
                                      .trimmingCharacters(in: .whitespaces).isEmpty)
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
        // The staged screen the Add Playlist flow shows, titled "Saving
        // Changes". Covers the page so nothing is focusable mid-save and
        // swallows Menu so Back cannot abandon a half-applied change.
        .fullScreenCover(isPresented: $isSaving) {
            ServerSyncView(mode: .saving(stages: saveProgress.stages),
                           title: "Saving Changes")
        }
    }

    // Phase 3 item 2: `tvField` (a hand-drawn label over TVSettingsTextField)
    // is gone. Every field on this page is SettingsTextField, which owns the
    // label, the helper line, the accent focus outline and the reveal eye.
}

// MARK: - Shared tvOS settings text field (history)
//
// Phase 3 item 2 retired this page's `tvField` in favour of
// SettingsTextField; the note below is kept because it records WHY the
// field has to be a UIKit dark-focus field rather than a plain TextField,
// which is still true of the AppTextField that SettingsTextField wraps.
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
