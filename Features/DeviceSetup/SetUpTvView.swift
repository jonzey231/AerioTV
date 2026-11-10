//  SetUpTvView.swift
//  Aerio
//
//  "Set up a TV" on iPhone and iPad (docs/DeviceSetupHandoff.md; port of
//  Android feature/devicesetup/SetUpTvScreen.kt and SetupTvDockCard.kt):
//  pick a TV found on the network (or arrive from its QR code), enter the
//  6-digit code it shows, choose what to send, and send it sealed to that
//  TV. Plus the dock card and the Settings root banner for an advertising TV.
//  Every string is Android's word for word.

#if os(iOS)
import SwiftUI
import SwiftData

struct SetUpTvView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    /// nil = the active playlist.
    var server: ServerConnection? = nil
    /// A scanned or system-camera aeriotv://setup link.
    var link: String? = nil
    /// Opened from the dock card or banner: that TV is preselected, the code is still required.
    var target: SetupTarget? = nil
    let onClose: () -> Void

    enum Step: Equatable {
        case pick
        /// First step for a target: copy everything, or this user only.
        case scope(SetupTarget, String?)
        /// "Import this user only" and the active profile has no sign-in saved here.
        case credential(SetupTarget, String?, DispatcharrProfile)
        case code(SetupTarget, String?)
        case choose(SetupTarget, String)
        /// Checking the key about to be sent; the line is the status (or a 429 countdown).
        case checking(String)
        /// The server refused the key that would be sent: nothing was sent.
        case keyRejected(UUID, Back)
        case sending
        case sent
        case error(String, Back)
    }

    /// Where Try Again goes.
    enum Back: Equatable { case pick, choose(SetupTarget, String) }

    @Query private var servers: [ServerConnection]
    @ObservedObject private var center = SetupTvOfferCenter.shared
    @State private var step: Step = .pick
    @State private var loaded = false
    @State private var picked: Set<String> = []
    @State private var sync = false
    @State private var codeText = ""
    @State private var userOnly = false
    /// Remote-session (Cast) sheet sizing: hug the content, full height for the
    /// code entry and sign-in steps (keyboard) or when the user drags it up.
    @State private var contentHeight: CGFloat = 320
    @State private var fitHeight: CGFloat = 320
    @State private var userLarge = false
    @State private var sheetInsets: CGFloat = 0
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    @Environment(\.horizontalSizeClass) private var hSize

    private static let noLongerWaiting = "The device is no longer waiting for setup. Start setup on the other device again."

    private var playlist: ServerConnection? { server ?? servers.first(where: \.isActive) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    VStack(alignment: .leading, spacing: 14) {
                        stepView
                        if step != .sent && step != .sending && !isChecking {
                            HStack(spacing: 12) {
                                if step != .pick { SetupSheetButton("Back", primary: false) { back() } }
                                SetupSheetButton("Cancel", primary: false) { onClose() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    let rounded = (h * 2).rounded() / 2
                    if abs(contentHeight - rounded) > 0.5 { contentHeight = rounded }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        // iPad form sheet: hug the measured step plus the safe-area insets
        // (keyboard on code entry), as the Add Playlist sheet does.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { h in
            if abs(h - sheetInsets) > 0.5 { sheetInsets = h }
        }
        .padSheetHeight(isPad ? fitHeight + sheetInsets : 0)
        .modifier(SetUpTvDetents(enabled: hSize == .compact && !isPad, fitHeight: fitHeight,
                                 forceLarge: needsKeyboard, userLarge: $userLarge))
        // Settle first: heights mid-transition overshoot and would flash the sheet taller.
        .task(id: contentHeight) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, fitHeight != contentHeight { fitHeight = contentHeight }
        }
        .onAppear(perform: load)
        .onChange(of: center.tvs) { _, tvs in invalidateIfStale(tvs) }
        // A camera link that arrives during the key check or the send is ignored.
        .onChange(of: isBusy, initial: true) { _, busy in center.sheetBusy = busy }
        .onDisappear { center.sheetBusy = false }
    }

    private var isBusy: Bool {
        switch step {
        case .checking, .sending: return true
        default: return false
        }
    }

    private var isChecking: Bool {
        if case .checking = step { return true }
        return false
    }

    private var needsKeyboard: Bool {
        switch step {
        case .code, .credential: return true
        default: return false
        }
    }

    private static var bottomInset: CGFloat {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
        return max(12, inset)
    }

    private var stepTarget: SetupTarget? {
        switch step {
        case .scope(let t, _), .credential(let t, _, _), .code(let t, _), .choose(let t, _): return t
        default: return nil
        }
    }

    /// The remote-session sheet header: accent glyph, bold title, accent device line.
    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: stepTarget?.kind.symbol ?? "tv")
                .font(.system(size: 40))  // glyph in a fixed box: not text, stays fixed
                .foregroundStyle(ThemeManager.shared.accent)
                .frame(height: 56)
            Text("Set up another device")
                .scaledFont(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let t = stepTarget {
                Text(t.name)
                    .scaledFont(.subheadline)
                    .foregroundStyle(Color.contrastText(ThemeManager.shared.accent))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .pick: pickStep
        case .scope(let t, let c): scopeStep(t, c)
        case .credential(let t, let c, let p):
            // The roster's credential prompt, word for word; cancel returns to the choice.
            CredentialStep(title: "Sign in as \(p.username)", username: p.username, confirmLabel: "Continue", onCancel: { step = .scope(t, c) }) { pw, key in
                do {
                    try await ProfileManager.shared.saveSignIn(p.playlistId, profileId: p.id, password: pw, apiKey: key)
                    step = c.map { .choose(t, $0) } ?? .code(t, nil)
                    return nil
                } catch { return error.localizedDescription }
            }
        case .code(let t, let err): codeStep(t, err)
        case .choose(let t, let c): chooseStep(t, c)
        case .checking(let line):
            HStack(spacing: 12) {
                ProgressView()
                Text(line).foregroundColor(.textPrimary)
            }
        case .keyRejected(let playlistID, _):
            Text(DispatcharrRateLimitCopy.setupKeyRejectedMessage)
                .scaledFont(.bodyLarge)
                .foregroundColor(.statusLive)
            SetupSheetButton("Edit Playlist") {
                onClose()
                SettingsDeepLink.openEditPlaylist(playlistID)
            }
        case .sending:
            HStack(spacing: 12) {
                ProgressView()
                Text("Sending to the other device").foregroundColor(.textPrimary)
            }
        case .sent:
            Text("Sent. The device is finishing setup now.")
                .scaledFont(.bodyLarge)
                .foregroundColor(.textPrimary)
            SetupSheetButton("Done") { onClose() }
        case .error(let msg, _):
            Text(msg)
                .scaledFont(.bodyLarge)
                .foregroundColor(.statusLive)
            SetupSheetButton("Try Again") { back() }
        }
    }

    // MARK: Pick

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On the other device, open AerioTV and choose Set up from another device. Then pick it below, or scan the code it shows.")
                .scaledFont(.bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
            if center.tvs.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices on this network").foregroundColor(Color.contrastText(.textSecondary))
                }
            }
            ForEach(center.tvs) { t in
                Button { pick(t) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.kind.symbol).foregroundColor(.accentPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).scaledFont(.headlineSmall).foregroundColor(.textPrimary)
                            Text("Check that the device shows \(t.fingerprint)")
                                .scaledFont(.bodySmall.subtext())
                                .foregroundColor(Color.contrastText(.textSecondary))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(Color.contrastText(.textTertiary))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            QrScanActions(
                prompt: "Point the camera at the code on the other device.",
                accept: { r in
                    switch r {
                    case .setupLink: return nil
                    case .userKey: return "This is a Dispatcharr user code. Scan the code shown on the other device."
                    case .invalid: return ScannedCode.invalidMessage
                    }
                },
                onResult: { r in if case .setupLink(let l) = r { useLink(l) } })
        }
    }

    // MARK: Scope

    private func scopeStep(_ t: SetupTarget, _ code: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The header already names the device.
            Text("What to send")
                .scaledFont(.caption)
                .foregroundColor(Color.contrastText(.textSecondary))
            VStack(spacing: 4) {
                ProfileChoiceRow(label: "Copy entire setup from this device", checked: !userOnly) { userOnly = false }
                ProfileChoiceRow(label: "Import this user only", checked: userOnly) { userOnly = true }
            }
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            SetupSheetButton("Continue") {
                if userOnly, let pl = playlist, let p = SetupSender.userOnlyMissingSignIn(pl) {
                    step = .credential(t, code, p)
                } else {
                    step = code.map { .choose(t, $0) } ?? .code(t, nil)
                }
            }
        }
    }

    /// Only a Dispatcharr playlist has profiles to choose between.
    private func firstStep(_ t: SetupTarget, _ code: String?) -> Step {
        if playlist?.type == .dispatcharrAPI { return .scope(t, code) }
        return code.map { .choose(t, $0) } ?? .code(t, nil)
    }

    // MARK: Code

    private func codeStep(_ t: SetupTarget, _ err: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the code shown on the other device.")
                .scaledFont(.bodyLarge)
                .foregroundColor(.textPrimary)
            AppTextField("6-digit code", placeholder: "000000", text: $codeText, icon: "number", keyboardType: .numberPad)
                .onChange(of: codeText) { _, v in
                    let d = String(v.filter(\.isNumber).prefix(6))
                    if d != v { codeText = d }
                }
            if let err {
                Text(err).scaledFont(.bodySmall).foregroundColor(.statusLive)
            }
            SetupSheetButton("Continue", isDisabled: codeText.count != 6) { submitCode(t) }
        }
    }

    // MARK: Choose

    @ViewBuilder
    private func chooseStep(_ t: SetupTarget, _ code: String) -> some View {
        if let pl = playlist {
            let source = SetupSender.source(pl)
            VStack(alignment: .leading, spacing: 12) {
                Text("Playlist: \(source.playlistName)").scaledFont(.bodyLarge).foregroundColor(.textPrimary)
                if source.isDispatcharr && !source.choices.isEmpty && !userOnly {
                    Text("Profiles").scaledFont(.headlineSmall).foregroundColor(.textPrimary)
                    ForEach(source.choices) { c in
                        let enabled = c.credentialLabel != nil && !c.isDefault
                        Button {
                            if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: picked.contains(c.id) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(.accentPrimary.opacity(enabled ? 1 : 0.5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.displayName).foregroundColor(.textPrimary)
                                    Text(c.isDefault ? "Signs in with the playlist login. Always sent."
                                         : (c.credentialLabel ?? "No saved sign-in on this device. Add it on the other device later."))
                                        .scaledFont(.bodySmall.subtext())
                                        .foregroundColor(Color.contrastText(.textSecondary))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                    }
                }
                if source.isDispatcharr {
                    Button { sync.toggle() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: sync ? "checkmark.square.fill" : "square").foregroundColor(.accentPrimary)
                            Text("Turn on Dispatcharr Sync on the other device").foregroundColor(.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                SetupSheetButton("Send") { send(t, code, pl) }
                    .padding(.top, 4)
                Text("Sent only to this device over your network, encrypted with its code. Nothing goes through your server.")
                    .scaledFont(.bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
            }
            .onAppear {
                if !loaded {
                    loaded = true
                    // Copy entire setup: every profile that has a sign-in saved here.
                    picked = Set(source.choices.filter { $0.credentialLabel != nil }.map(\.id))
                    sync = source.isDispatcharr
                }
            }
        } else {
            Text("There is no playlist on this device to send.").foregroundColor(.statusLive)
        }
    }

    // MARK: Flow

    private func load() {
        if let link, let l = SetupProtocol.parseLink(link) {
            step = firstStep(SetupTarget.fromLink(l), l.code)
        } else if let target {
            step = firstStep(target, nil)
        }
        center.discovery.start()
    }

    private func useLink(_ link: String) {
        guard let l = SetupProtocol.parseLink(link) else { return }
        step = firstStep(SetupTarget.fromLink(l), l.code)
    }

    private func pick(_ t: SetupTarget) {
        codeText = ""
        step = firstStep(t, t.code)
    }

    private func back() {
        switch step {
        case .choose(let t, let c):
            if t.code != nil { step = playlist?.type == .dispatcharrAPI ? .scope(t, c) : .pick } else { step = .code(t, nil) }
        case .code(let t, _): step = playlist?.type == .dispatcharrAPI ? .scope(t, nil) : .pick
        case .credential(let t, let c, _): step = .scope(t, c)
        case .error(_, let b), .keyRejected(_, let b):
            switch b {
            case .pick: step = .pick
            case .choose(let t, let c): step = .choose(t, c)
            }
        default: step = .pick
        }
    }

    private func submitCode(_ t: SetupTarget) {
        let c = codeText.filter(\.isNumber)
        guard c.count == 6 else { step = .code(t, "Enter the 6-digit code shown on the other device."); return }
        step = .choose(t, c)
    }

    private func send(_ t: SetupTarget, _ code: String, _ pl: ServerConnection) {
        // A Child profile, or an app behind the launch PIN, never sends (any path
        // into this sheet, the system-camera link included). Nothing is sent.
        guard SetupGate.canSend(pl) else {
            debugLog("[SETUP] send blocked for this profile")
            onClose()
            return
        }
        if t.isExpired {
            debugLog("[SETUP] target expired key=\(t.fingerprint)")
            step = .error(Self.noLongerWaiting, .pick)
            return
        }
        let payload = userOnly && pl.type == .dispatcharrAPI
            ? SetupSender.buildUserOnlyPayload(pl, turnOnSync: sync)
            : SetupSender.buildPayload(pl, profileIds: picked, turnOnSync: sync)
        step = .sending
        Task { @MainActor in
            // Never hand over a key the server refuses (2026-11-09, Android
            // db6aacb6): one authenticated request with exactly the key in
            // the payload (for "Import this user only", the profile's key).
            if payload.playlist.type == "dispatcharr", let key = payload.playlist.credential?.apiKey {
                step = .checking(DispatcharrRateLimitCopy.checkingLine)
                let verdict = await SetupKeySender.check(key: key, server: pl) { left, limited in
                    step = .checking(limited.map { DispatcharrRateLimitCopy.serverBusyCountdown(left, reason: $0) }
                                     ?? DispatcharrRateLimitCopy.checkingLine)
                }
                if verdict == .rejected {
                    step = .keyRejected(pl.id, .choose(t, code))
                    return
                }
                step = .sending
            }
            // Resolve again right before every send: the device may have started a
            // new session (new port and key) since the card or list last saw it.
            let t = await SetupDiscovery.fresh(t)
            // Again after the awaits: a profile switch or lock may have landed meanwhile.
            guard SetupGate.canSend(pl) else {
                debugLog("[SETUP] send blocked for this profile")
                onClose()
                return
            }
            switch await SetupSender.send(t, code: code, payload: payload) {
            case .ok:
                debugLog("[SETUP] sent, TV finishing setup key=\(t.fingerprint)")
                SetupTvOfferCenter.shared.completed(t)
                step = .sent
            case .wrongCode:
                var again = t
                again.code = nil
                codeText = ""
                step = .code(again, "The device did not accept that code. Check the code on the device and try again.")
            case .refused:
                step = .error(Self.noLongerWaiting, .pick)
            case .failed(let m):
                step = .error(m, .choose(t, code))
            }
        }
    }

    /// A discovered TV that left, or any TV whose key changed (new session),
    /// is no longer the one this flow is talking to: back to the list.
    private func invalidateIfStale(_ tvs: [SetupTarget]) {
        let current: SetupTarget?
        switch step {
        case .code(let t, _): current = t
        case .choose(let t, _): current = t
        case .scope(let t, _): current = t
        case .credential(let t, _, _): current = t
        default: current = nil
        }
        guard let t = current else { return }
        let rotated = tvs.contains { ($0.serviceName == t.serviceName && t.serviceName != nil || $0.host == t.host) && $0.pk != t.pk }
        // Measured 2026-11-06: every Scene inactive (Control Center, a notification) stops
        // discovery and empties the list, which read as gone and showed the error with no
        // send. Only a running browser that has heard results can report a device gone.
        let gone = center.discovery.heard && t.serviceName != nil && !tvs.contains { $0.serviceName == t.serviceName && $0.pk == t.pk }
        if rotated || gone {
            debugLog("[SETUP] target \(rotated ? "key changed" : "gone") key=\(t.fingerprint)")
            step = .error(Self.noLongerWaiting, .pick)
        }
    }
}

// MARK: - Dock card and Settings banner

/// The TV name, "Waiting for setup, key XXXX", Set up, and dismiss.
private struct SetupTvOfferContent: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let target: SetupTarget
    let onSetUp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSetUp) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25))
                        Image(systemName: target.kind.symbol)
                            .font(.system(size: 20))  // glyph in a fixed box: not text, stays fixed
                            .foregroundStyle(ThemeManager.shared.accent)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.name)
                            .scaledFont(.subheadline.weight(.bold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(setupWaitingLine(target))
                            .scaledFont(.caption)
                            .foregroundStyle(Color.contrastText(ThemeManager.shared.accent))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onSetUp) {
                Text("Set up")
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(ThemeManager.shared.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                    .foregroundStyle(Color.contrastText(.textSecondary))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }
}

/// Dock card directly above the tab bar while a TV is advertising: the same
/// capsule shell, 44 pt tile, and padding as the Kept Live dock card.
struct SetupTvDockCard: View {
    let target: SetupTarget
    let onSetUp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        SetupTvOfferContent(target: target, onSetUp: onSetUp, onDismiss: onDismiss)
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .modifier(DockCardSurface())
            .onAppear { debugLog("[SETUP] dock card show key=\(target.fingerprint)") }
    }
}

/// Settings root banner for the same TV as the dock card.
struct SetupTvSettingsBanner: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let target: SetupTarget
    let onSetUp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        SetupTvOfferContent(target: target, onSetUp: onSetUp, onDismiss: onDismiss)
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 12)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Set up a TV" row for Settings > Playlists (list and playlist detail).
struct SetUpTvSettingsRow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let subtitle: String
    let action: () -> Void

    static let listSubtitle = "Send the active playlist to AerioTV on another device. Nothing to type there."
    static let detailSubtitle = "Send this playlist, your profiles, and sync to another device on your network."

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right").foregroundColor(.accentPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up another device").scaledFont(.bodyMedium.weight(.semibold)).foregroundColor(.textPrimary)
                    Text(subtitle).scaledFont(.bodySmall.subtext()).foregroundColor(Color.contrastText(.textSecondary))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(Color.contrastText(.textTertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Same as the other dock cards: iPad tab-pill capsule, iPhone glass capsule.
private struct DockCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        if PadTabPill.isActive {
            content.modifier(PadPillSurface(shape: Capsule()))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule()).clipShape(Capsule())
        }
    }
}

// MARK: - App root wiring

/// Runs the shared discovery while the app is in the foreground, gates the
/// offer on the active playlist, and presents Set up a TV for the dock card,
/// the banner, and aeriotv://setup links. Mounted once at the app root.
struct SetupHandoffRoot: ViewModifier {
    @ObservedObject private var center = SetupTvOfferCenter.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Query private var servers: [ServerConnection]

    /// A setup link waits while the launch PIN screen is up or a profile switch
    /// is landing: the profile that will be active is not settled yet.
    private var linkHeld: Bool { SetupGate.isLocked || profiles.switching }

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in center.setForeground(phase == .active) }
            .onChange(of: servers.first(where: \.isActive)?.id, initial: true) { _, _ in
                center.canOffer = SetupGate.canSetUpTv(servers.first(where: \.isActive))
            }
            // Admin or default profile only: a switch to a Child profile hides the offer.
            .onChange(of: profiles.activeRoleNow) { _, _ in
                center.canOffer = SetupGate.canSetUpTv(servers.first(where: \.isActive))
            }
            .onChange(of: profiles.activeProfileIds) { _, _ in
                center.canOffer = SetupGate.canSetUpTv(servers.first(where: \.isActive))
            }
            .onOpenURL { url in
                // aeriotv://setup from the system camera. Never log the URL.
                guard url.scheme?.lowercased() == "aeriotv" else { return }
                guard url.host?.lowercased() == "setup" else {
                    debugLog("[SETUP] aeriotv link ignored (not setup)")
                    return
                }
                // Same gate as Set up in Settings: a Child profile drops the link;
                // behind the launch PIN, or while a profile switch lands, it waits
                // and is checked again for the profile then active (Android parity).
                center.openLink(url.absoluteString,
                                allowed: SetupGate.canSetUpTv(servers.first(where: \.isActive)),
                                locked: linkHeld)
            }
            .onChange(of: linkHeld) { _, held in
                if !held { center.unlocked(allowed: SetupGate.canSetUpTv(servers.first(where: \.isActive))) }
            }
            .sheet(item: Binding(get: { center.presentedTarget }, set: { center.presentedTarget = $0 })) { t in
                SetUpTvView(target: t) { center.presentedTarget = nil }
            }
            .sheet(item: Binding(get: { center.pendingLink }, set: { center.pendingLink = $0 })) { box in
                SetUpTvView(link: box.link) { center.pendingLink = nil }
            }
    }
}
/// iPhone only: the remote-session (Cast) sheet's detents, a content-hugging
/// height plus .large. The iPad form sheet keeps its own presentation.
private struct SetUpTvDetents: ViewModifier {
    let enabled: Bool
    let fitHeight: CGFloat
    let forceLarge: Bool
    @Binding var userLarge: Bool
    func body(content: Content) -> some View {
        if enabled {
            let fit = PresentationDetent.height(fitHeight)
            content
                .presentationDetents([fit, .large], selection: Binding(
                    get: { forceLarge || userLarge ? .large : fit },
                    set: { userLarge = $0 == .large }))
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.sheetBackground)
        } else {
            content.presentationBackground(Color.sheetBackground)
        }
    }
}

/// The remote-session sheet's wide button: 14 pt corners, semibold label;
/// primary on the accent, secondary on 12% white.
private struct SetupSheetButton: View {
    @ObservedObject private var themeLive = ThemeManager.shared
    let title: String
    var primary = true
    var isDisabled = false
    let action: () -> Void
    init(_ title: String, primary: Bool = true, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.primary = primary; self.isDisabled = isDisabled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledFont(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(primary ? ThemeManager.shared.accent : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}
#endif
