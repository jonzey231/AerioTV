//
//  DispatcharrKeyRejectedPrompt.swift
//  Aerio
//
//  "Sign-in not accepted": shown once per rejection when the server refused
//  a playlist's API key and AerioTV holds every API call for it locally
//  (DispatcharrRequestGate). Android twin: feature/settings/
//  ApiKeyRejectedPrompt.kt (fd145f3d). Buttons and copy: KeySignInCopy.
//  iPhone and iPad: Sign In (preferred, the sign-in form), Edit Playlist
//  (for THAT playlist), Not Now. Apple TV: "Update from Phone" (preferred,
//  default focus; Fix Login, docs/DeviceSetupHandoff.md), "Sign In with
//  Remote" (the same sign-in form), and "Not Now".
//
//  A platform alert (UIAlertController) on the topmost presented controller
//  rather than a SwiftUI `.alert`: the rejection usually lands while a sheet
//  is closing (Add Playlist's Save, measured on the simulator 2026-11-10),
//  and a SwiftUI alert whose presentation is blocked at that moment is never
//  shown. This one waits for the presentation to settle and retries.
//

import SwiftUI
import SwiftData
import UIKit

@MainActor
final class DispatcharrKeyPromptModel: ObservableObject {
    static let shared = DispatcharrKeyPromptModel()

    @Published private(set) var prompt: DispatcharrRequestGate.Prompt?
    private weak var shown: UIAlertController?
    /// Fix Login (Apple TV): the receive screen while it is up.
    private weak var fixHost: UIViewController?
    private var shownPrompt: DispatcharrRequestGate.Prompt?
    private var retry: Task<Void, Never>?

    private init() {
        prompt = DispatcharrRequestGate.shared.prompt
        // Read the gate's CURRENT prompt on the main actor instead of the
        // value the callback carried: callbacks from different threads may
        // land out of order, the gate's state never does.
        DispatcharrRequestGate.shared.onPromptChange = { _ in
            Task { @MainActor in DispatcharrKeyPromptModel.shared.sync() }
        }
    }

    /// Touch once at launch so the gate's callback is wired before any 401.
    func install() { sync() }

    private func sync() {
        let now = DispatcharrRequestGate.shared.prompt
        if prompt != now { prompt = now }
        guard let now else {
            // Cleared elsewhere (an edit, a passing key check, a re-check).
            retry?.cancel()
            if let a = shown, a.presentingViewController != nil { a.dismiss(animated: true) }
            shown = nil
            shownPrompt = nil
            return
        }
        if shownPrompt == now, shown?.presentingViewController != nil { return }
        present(now, attempt: 0)
    }

    private func present(_ p: DispatcharrRequestGate.Prompt, attempt: Int) {
        retry?.cancel()
        guard DispatcharrRequestGate.shared.prompt == p else { return }
        guard let top = Self.topController(), !top.isBeingDismissed, !top.isBeingPresented,
              !(top is UIAlertController) else {
            // Another presentation is settling (a sheet closing, another
            // alert up): try again shortly, for up to a minute.
            guard attempt < 120 else { return }
            retry = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled { self.present(p, attempt: attempt + 1) }
            }
            return
        }
        let alert = UIAlertController(
            title: DispatcharrRateLimitCopy.keyRejectedTitle,
            message: DispatcharrRateLimitCopy.keyRejectedPromptBody(playlistName: p.playlistName,
                                                                    passwordToo: p.passwordToo, noKey: p.noKey),
            preferredStyle: .alert)
        // Buttons per device (KeySignInCopy.promptActions): iPhone and iPad
        // Sign In (preferred), Edit Playlist, Not Now; Apple TV Update from
        // Phone (preferred, default focus), Sign In with Remote, Not Now.
        #if os(tvOS)
        let isTV = true
        #else
        let isTV = false
        #endif
        let actions = KeySignInCopy.promptActions(isTV: isTV, canSignIn: KeySignInGate.canOpen(playlistID: p.playlistID))
        for (i, a) in actions.enumerated() {
            let action = UIAlertAction(title: KeySignInCopy.label(a, isTV: isTV), style: a == .notNow ? .cancel : .default) { _ in
                Task { @MainActor in
                    let m = DispatcharrKeyPromptModel.shared
                    switch a {
                    case .signIn: m.signIn(p)
                    case .editPlaylist: m.editPlaylist(p)
                    case .updateFromPhone: m.updateFromPhone(p)
                    case .notNow: m.notNow()
                    }
                }
            }
            alert.addAction(action)
            if i == 0 { alert.preferredAction = action }
        }
        shown = alert
        shownPrompt = p
        debugLog("[AUTH] Sign-in not accepted prompt shown for \(p.playlistID.prefix(8))")
        top.present(alert, animated: true)
        watch(p, alert)
    }

    /// The controller it went up on can be torn down under it (the launch
    /// splash handing over to the main UI, measured 2026-11-10): while the
    /// prompt is still pending, check once a second that the alert is
    /// actually on screen and put it back up when it is not.
    private func watch(_ p: DispatcharrRequestGate.Prompt, _ alert: UIAlertController) {
        retry = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, DispatcharrRequestGate.shared.prompt == p, self.shown === alert else { return }
                if alert.viewIfLoaded?.window == nil, !alert.isBeingPresented {
                    debugLog("[AUTH] Sign-in not accepted prompt was not on screen; showing it again")
                    self.shown = nil
                    self.present(p, attempt: 0)
                    return
                }
            }
        }
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    func notNow() {
        debugLog("[AUTH] Sign-in not accepted prompt: Not Now")
        shown = nil
        shownPrompt = nil
        DispatcharrRequestGate.shared.consumePrompt()
        prompt = nil
    }

    /// Sign In / Sign In with Remote: the sign-in form for this playlist. The
    /// prompt is answered (once per rejection, as Not Now); a sign-in that
    /// works lifts the hold. Gated like Set up: never for a Child profile or
    /// behind the launch PIN.
    func signIn(_ p: DispatcharrRequestGate.Prompt) {
        shown = nil
        shownPrompt = nil
        guard KeySignInGate.canOpen(playlistID: p.playlistID) else {
            debugLog("[AUTH] sign-in form not opened: this profile cannot sign in here")
            return
        }
        debugLog("[AUTH] sign-in form opened for \(p.playlistID.prefix(8))")
        DispatcharrRequestGate.shared.consumePrompt()
        prompt = nil
        presentHosted(attempt: 0) { close in
            AnyView(KeySignInView(playlistID: p.playlistID, onClose: close))
        }
    }

    /// Apple TV: open the receive screen in Fix Login mode for this playlist.
    func updateFromPhone(_ p: DispatcharrRequestGate.Prompt) {
        debugLog("[SETUP] fix login screen opened from the rejected-key prompt for \(p.playlistID.prefix(8))")
        shown = nil
        shownPrompt = nil
        DispatcharrRequestGate.shared.consumePrompt()
        prompt = nil
        presentFixLogin(p.playlistID, attempt: 0)
    }

    /// The receive screen in Fix Login mode, presented like the prompt itself
    /// on the topmost controller (a SwiftUI cover at the root never showed:
    /// onboarding and the other root hosts present from there, measured on the
    /// simulator 2026-11-11). Waits for the alert to finish dismissing.
    private func presentFixLogin(_ playlistID: String, attempt: Int) {
        presentHosted(attempt: attempt, fullScreen: true) { close in
            AnyView(ReceiveSetupView(fixLoginPlaylistID: playlistID,
                                     onCancel: {
                                         debugLog("[SETUP] fix login screen closed")
                                         close()
                                     },
                                     onDone: {
                                         debugLog("[SETUP] fix login screen closed after sign-in")
                                         close()
                                     }))
        }
    }

    /// Presents a screen from the prompt on the topmost controller, once the
    /// alert has finished dismissing (up to 6 seconds). `make` receives the
    /// close action. Full screen for Fix Login; the sign-in form floats over
    /// a dimmed backdrop.
    private func presentHosted(attempt: Int, fullScreen: Bool = false,
                               make: @escaping (@escaping () -> Void) -> AnyView) {
        guard fixHost == nil else { return }
        guard let top = Self.topController(), !top.isBeingDismissed, !top.isBeingPresented,
              !(top is UIAlertController), let container = AerioApp.sharedContainer else {
            guard attempt < 40 else {
                debugLog("[AUTH] a screen from the rejected-key prompt could not be shown")
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.presentHosted(attempt: attempt + 1, fullScreen: fullScreen, make: make)
            }
            return
        }
        let close: () -> Void = { [weak self] in
            self?.fixHost?.dismiss(animated: true)
            self?.fixHost = nil
        }
        let host = UIHostingController(rootView: make(close).modelContainer(container))
        if fullScreen {
            host.modalPresentationStyle = .fullScreen
        } else {
            host.modalPresentationStyle = .overFullScreen
            host.view.backgroundColor = .clear
        }
        fixHost = host
        top.present(host, animated: true)
    }

    func editPlaylist(_ p: DispatcharrRequestGate.Prompt) {
        debugLog("[AUTH] Sign-in not accepted prompt: Edit Playlist for \(p.playlistID.prefix(8))")
        shown = nil
        shownPrompt = nil
        DispatcharrRequestGate.shared.consumePrompt()
        prompt = nil
        if let id = UUID(uuidString: p.playlistID) { SettingsDeepLink.openEditPlaylist(id) }
    }
}

/// Installs the prompt at the app root (RootView).
struct DispatcharrKeyRejectedPromptHost: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { DispatcharrKeyPromptModel.shared.install() }
    }
}

// MARK: - Sign in from the prompt (2026-11-11)

/// Who may open the sign-in form: the same gate as Set up another device
/// (an Admin or Standard profile, or the default profile; never a Child, and
/// never behind the launch PIN).
@MainActor
enum KeySignInGate {
    static func canOpen(playlistID: String) -> Bool {
        let pm = ProfileManager.shared
        guard pm.launchGate == nil else { return false }
        let active = pm.activeProfile(playlistID)
        return SetupProfileRules.canSetUpTv(activeRole: active?.effectiveRole.wire, activeIsDefault: active?.isDefault)
    }
}

/// Signs a playlist in with a Dispatcharr username and password: the normal
/// login (JWT token endpoint, with its throttle and 429 copy), then the
/// account's current API key from users/me (never a generated one). Only the
/// playlist's sign-in changes (key, username, password); the hold and its
/// prompt are lifted and the channels reload. Never logs the password or key.
@MainActor
enum KeySignInService {
    static func signIn(playlistID: String, username rawUser: String, password: String) async -> KeySignInCopy.Outcome {
        guard let container = AerioApp.sharedContainer, let uuid = UUID(uuidString: playlistID) else {
            return .failed(KeySignInCopy.wrongCredentials)
        }
        let ctx = container.mainContext
        let descriptor = FetchDescriptor<ServerConnection>(predicate: #Predicate { $0.id == uuid })
        guard let server = (try? ctx.fetch(descriptor))?.first, !server.isGone else {
            return .failed(KeySignInCopy.wrongCredentials)
        }
        let username = rawUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = server.effectiveBaseURL
        let ua = server.effectiveUserAgent
        do {
            let pair = try await DispatcharrAPI.login(baseURL: base, username: username, password: password, userAgent: ua)
            let user = try await DispatcharrAPI(baseURL: base, auth: .bearer(pair.access), userAgent: ua).fetchCurrentUser()
            let key = user.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                debugLog("[AUTH] sign-in from the prompt for \(playlistID.prefix(8)): the account has no API key")
                return .noAPIKey
            }
            guard !server.isGone else { return .failed(KeySignInCopy.wrongCredentials) }
            let oldKey = server.baseApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountChanged = username.lowercased() != server.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            DispatcharrTokenStore.shared.store(serverID: server.id, access: pair.access, refresh: pair.refresh)
            if accountChanged { CatchupSupport.invalidateCredentials(serverID: server.id) }
            // Credentials only: never profiles, settings, or other playlists.
            server.apiKey = key
            server.username = username
            server.password = password
            DispatcharrLoginGate.shared.clearRejected(serverID: server.id)
            DispatcharrRequestGate.shared.liftFixedLogin(playlistID: server.id.uuidString,
                                                         oldKey: oldKey.isEmpty ? nil : oldKey, newKey: key)
            SyncManager.shared.saveCredentialsSynced(for: server)
            try? ctx.save()
            debugLog("[AUTH] sign-in from the prompt for \(playlistID.prefix(8)): signed in, key \(key == oldKey ? "unchanged" : "replaced"); hold lifted")
            // The default profile's account (ProfileHostHold).
            ProfileManager.shared.noteDefaultUsersMe(server.id.uuidString, userId: user.id, username: user.username)
            DispatcharrKeyRecheck.shared.onRecovered?(server.id.uuidString)
            return .signedIn
        } catch {
            return outcome(for: error, log: "sign-in from the prompt for \(playlistID.prefix(8))")
        }
    }

    /// A profile whose sign-in is held after its playlist's server address
    /// changed (ProfileHostHold): the same login and users/me at the
    /// playlist's current address, as that profile's Dispatcharr user. A
    /// success replaces only that profile's key and password and lifts only
    /// its hold; the caller finishes the switch. Never logs the password or key.
    static func signInHeldProfile(playlistID: String, profileID: String,
                                  username rawUser: String, password: String) async -> KeySignInCopy.Outcome {
        let pm = ProfileManager.shared
        guard let profile = pm.store.byId(profileID), profile.playlistId == playlistID,
              let server = DsyncLocal.server(playlistID), !server.isGone else {
            return .failed(KeySignInCopy.wrongCredentials)
        }
        let tag = "sign-in for held profile \(profileID.prefix(8))"
        let username = rawUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = server.effectiveBaseURL
        let ua = server.effectiveUserAgent
        do {
            // The held sign-in form may reach a held playlist's address (ProfileHostHold).
            let pair = try await DispatcharrAPI.login(baseURL: base, username: username, password: password, userAgent: ua, heldCheck: true)
            var meApi = DispatcharrAPI(baseURL: base, auth: .bearer(pair.access), userAgent: ua)
            meApi.heldCheck = true
            let user = try await meApi.fetchCurrentUser()
            // The profile is one Dispatcharr user: another account's sign-in is not its sign-in.
            guard user.username.caseInsensitiveCompare(profile.username) == .orderedSame else {
                debugLog("[AUTH] \(tag): signed in as a different user than the profile's")
                return .wrongCredentials
            }
            let key = user.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                debugLog("[AUTH] \(tag): the account has no API key")
                return .noAPIKey
            }
            guard pm.store.byId(profileID) != nil else { return .failed(KeySignInCopy.wrongCredentials) }
            await pm.completeHeldSignIn(profileID, apiKey: key, password: password)
            debugLog("[AUTH] \(tag): signed in")
            return .signedIn
        } catch {
            return outcome(for: error, log: tag)
        }
    }

    /// What a failed login or users/me comes to on the form.
    private static func outcome(for error: Error, log: String) -> KeySignInCopy.Outcome {
        if let e = error as? DispatcharrDirectConnectError {
            switch e {
            case .invalidCredentials:
                debugLog("[AUTH] \(log): username or password not accepted")
                return .wrongCredentials
            case .noAPIKeyForAccount:
                debugLog("[AUTH] \(log): the account has no API key")
                return .noAPIKey
            case .transport:
                debugLog("[AUTH] \(log) failed: server not reachable")
                return .failed(DsyncManualCopy.DISPATCHARR_UNREACHABLE)
            default:
                // A rate limit keeps its own message (no automatic retry).
                debugLog("[AUTH] \(log) failed: \(type(of: e))")
                return .failed(DispatcharrDirectConnectError.userMessage(for: e, step: "sign-in"))
            }
        }
        if error is URLError {
            debugLog("[AUTH] \(log) failed: server not reachable")
            return .failed(DsyncManualCopy.DISPATCHARR_UNREACHABLE)
        }
        debugLog("[AUTH] \(log) failed: \(type(of: error))")
        return .failed(DispatcharrDirectConnectError.userMessage(for: error, step: "sign-in"))
    }

    /// The username the form starts with: the playlist's, else the account it signed in as.
    static func knownUsername(playlistID: String) -> String {
        guard let container = AerioApp.sharedContainer, let uuid = UUID(uuidString: playlistID) else { return "" }
        let descriptor = FetchDescriptor<ServerConnection>(predicate: #Predicate { $0.id == uuid })
        guard let s = (try? container.mainContext.fetch(descriptor))?.first, !s.isGone else { return "" }
        for candidate in [s.username,
                          DispatcharrAccountFactsStore.load(s.id).username,
                          ProfileManager.shared.profiles(s.id.uuidString).first(where: \.isDefault)?.username ?? ""] {
            let u = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !u.isEmpty { return u }
        }
        return ""
    }
}

/// "Sign in to Dispatcharr": the themed profile dialog with Username and
/// Password, Sign In and Cancel, the footnote, and the inline error line.
/// With `heldProfile` it signs that profile in again after its playlist's
/// server address changed (ProfileHostHold): its username prefilled and the
/// line above the fields; a success calls `onSignedIn` to finish the switch.
struct KeySignInView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistID: String
    /// A profile whose sign-in is held: sign in as that profile, not the playlist.
    var heldProfile: DispatcharrProfile? = nil
    /// False inside a surface that already dims the screen (the profile switch flows).
    var hosted = true
    let onClose: () -> Void
    /// A held profile signed in again (nil: close).
    var onSignedIn: (() -> Void)? = nil
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var loaded = false
    @State private var playlistName = ""
    private enum Field: Hashable { case username, password }
    @FocusState private var focus: Field?

    var body: some View {
        Group {
            if hosted { ProfileDialogHost { card } } else { card }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let heldProfile {
                username = heldProfile.username
                playlistName = DsyncLocal.server(playlistID)?.name ?? ""
            } else {
                username = KeySignInService.knownUsername(playlistID: playlistID)
            }
            #if os(tvOS)
            // A known username: start in Password, so the keyboard's Done signs in.
            if !username.isEmpty { focus = .password }
            #endif
        }
    }

    private var card: some View {
        let ready = !busy && KeySignInCopy.canSubmit(username: username, password: password)
        // The profile dialogs' chrome (title, pills, card), sized to the form:
        // no inner scroll view, so the card hugs the fields on every platform.
        return VStack(alignment: .leading, spacing: ProfileUI.s(12, 22)) {
            Text(KeySignInCopy.formTitle)
                .scaledFont(ProfileUI.title)
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if heldProfile != nil {
                Text(KeySignInCopy.hostChanged(playlistName: playlistName))
                    .scaledFont(ProfileUI.body)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field(KeySignInCopy.username, .username) {
                TextField("", text: $username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
            }
            field(KeySignInCopy.password, .password) {
                // The keyboard's Done (Return) signs in.
                SecureField("", text: $password)
                    .submitLabel(.done)
                    .onSubmit { submit() }
            }
            Text(KeySignInCopy.footnote)
                .scaledFont(ProfileUI.small)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if busy { ProgressView().tint(.accentPrimary) }
            if let error {
                Text(error)
                    .scaledFont(ProfileUI.small)
                    .foregroundColor(ProfileUI.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: ProfileUI.s(12, 24)) {
                Spacer(minLength: 0)
                Button(KeySignInCopy.cancel) { cancel() }
                    .buttonStyle(ProfilePillStyle(filled: false))
                // Never disabled (a disabled focused TV button drops focus); dimmed and inert instead.
                Button(KeySignInCopy.submit) { if ready { submit() } }
                    .buttonStyle(ProfilePillStyle(destructive: false))
                    .opacity(ready ? 1 : 0.45)
            }
        }
        .padding(ProfileUI.s(20, 48))
        .frame(maxWidth: ProfileUI.s(520, 1000))
        .background(RoundedRectangle(cornerRadius: ProfileUI.s(20, 28), style: .continuous).fill(Color.cardBackground))
        .padding(ProfileUI.s(16, 60))
        #if os(tvOS)
        .onExitCommand { cancel() }
        #endif
    }

    /// One labeled field, styled like the profile dialogs' fields (profileFieldBox).
    private func field<F: View>(_ label: String, _ which: Field, @ViewBuilder _ input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).scaledFont(ProfileUI.label).foregroundColor(.textSecondary)
            input()
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .scaledFont(ProfileUI.body)
                .profileFieldBox()
                .accessibilityLabel(label)
                .focused($focus, equals: which)
        }
    }

    private func cancel() {
        debugLog("[AUTH] sign-in form cancelled")
        onClose()
    }

    private func submit() {
        guard !busy, KeySignInCopy.canSubmit(username: username, password: password) else { return }
        busy = true
        error = nil
        Task { @MainActor in
            let outcome = if let heldProfile {
                await KeySignInService.signInHeldProfile(playlistID: playlistID, profileID: heldProfile.id,
                                                         username: username, password: password)
            } else {
                await KeySignInService.signIn(playlistID: playlistID, username: username, password: password)
            }
            busy = false
            if let line = KeySignInCopy.message(outcome) {
                error = line
                password = ""
            } else if heldProfile != nil, let onSignedIn {
                onSignedIn()
            } else {
                onClose()
            }
        }
    }
}

