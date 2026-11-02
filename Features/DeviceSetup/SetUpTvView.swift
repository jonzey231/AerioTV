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
    /// nil = the active playlist.
    var server: ServerConnection? = nil
    /// A scanned or system-camera aeriotv://setup link.
    var link: String? = nil
    /// Opened from the dock card or banner: that TV is preselected, the code is still required.
    var target: SetupTarget? = nil
    let onClose: () -> Void

    enum Step: Equatable {
        case pick
        case code(SetupTarget, String?)
        case choose(SetupTarget, String)
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

    private static let noLongerWaiting = "The TV is no longer waiting for setup. Start setup on the TV again."

    private var playlist: ServerConnection? { server ?? servers.first(where: \.isActive) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Set up a TV")
                        .scaledFont(.headlineLarge)
                        .foregroundColor(.textPrimary)
                    stepView
                    if step != .sent && step != .sending {
                        HStack(spacing: 12) {
                            if step != .pick { SecondaryButton("Back") { back() } }
                            SecondaryButton("Cancel") { onClose() }
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color.appBackground.ignoresSafeArea())
        }
        .onAppear(perform: load)
        .onChange(of: center.tvs) { _, tvs in invalidateIfStale(tvs) }
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .pick: pickStep
        case .code(let t, let err): codeStep(t, err)
        case .choose(let t, let c): chooseStep(t, c)
        case .sending:
            HStack(spacing: 12) {
                ProgressView()
                Text("Sending to the TV").foregroundColor(.textPrimary)
            }
        case .sent:
            Text("Sent. The TV is finishing setup now.")
                .scaledFont(.bodyLarge)
                .foregroundColor(.textPrimary)
            PrimaryButton("Done") { onClose() }
        case .error(let msg, _):
            Text(msg)
                .scaledFont(.bodyLarge)
                .foregroundColor(.statusLive)
            PrimaryButton("Try Again") { back() }
        }
    }

    // MARK: Pick

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On the TV, open AerioTV and choose Set up from your phone. Then pick the TV below, or scan the code on the TV.")
                .scaledFont(.bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
            if center.tvs.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Looking for TVs on this network").foregroundColor(Color.contrastText(.textSecondary))
                }
            }
            ForEach(center.tvs) { t in
                Button { pick(t) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tv").foregroundColor(.accentPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).scaledFont(.headlineSmall).foregroundColor(.textPrimary)
                            Text("Check that the TV shows \(t.fingerprint)")
                                .scaledFont(.bodySmall.subtext())
                                .foregroundColor(Color.contrastText(.textSecondary))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(Color.contrastText(.textTertiary))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            QrScanActions(
                prompt: "Point the camera at the code on the TV.",
                accept: { r in
                    switch r {
                    case .setupLink: return nil
                    case .userKey: return "This is a Dispatcharr user code. Scan the code shown on the TV."
                    case .invalid: return ScannedCode.invalidMessage
                    }
                },
                onResult: { r in if case .setupLink(let l) = r { useLink(l) } })
        }
    }

    // MARK: Code

    private func codeStep(_ t: SetupTarget, _ err: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the code shown on \(t.name).")
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
            PrimaryButton("Continue", isDisabled: codeText.count != 6) { submitCode(t) }
        }
    }

    // MARK: Choose

    @ViewBuilder
    private func chooseStep(_ t: SetupTarget, _ code: String) -> some View {
        if let pl = playlist {
            let source = SetupSender.source(pl)
            VStack(alignment: .leading, spacing: 12) {
                Text("Send to \(t.name)").scaledFont(.headlineSmall).foregroundColor(.textPrimary)
                Text("Playlist: \(source.playlistName)").scaledFont(.bodyLarge).foregroundColor(.textPrimary)
                if source.isDispatcharr && !source.choices.isEmpty {
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
                                         : (c.credentialLabel ?? "No saved sign-in on this device. Add it on the TV later."))
                                        .scaledFont(.bodySmall.subtext())
                                        .foregroundColor(Color.contrastText(.textSecondary))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                    }
                    Button { sync.toggle() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: sync ? "checkmark.square.fill" : "square").foregroundColor(.accentPrimary)
                            Text("Turn on Dispatcharr Sync on the TV").foregroundColor(.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                PrimaryButton("Send") { send(t, code, pl) }
                    .padding(.top, 4)
                Text("Sent only to this TV over your network, encrypted with its code. Nothing goes through your server.")
                    .scaledFont(.bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
            }
            .onAppear {
                if !loaded {
                    loaded = true
                    picked = Set(source.choices.filter { ($0.isDefault || $0.isCurrent) && $0.credentialLabel != nil }.map(\.id))
                    sync = source.isDispatcharr && source.syncOnHere
                }
            }
        } else {
            Text("There is no playlist on this device to send.").foregroundColor(.statusLive)
        }
    }

    // MARK: Flow

    private func load() {
        if let link, let l = SetupProtocol.parseLink(link) {
            step = .choose(SetupTarget.fromLink(l), l.code)
        } else if let target {
            step = .code(target, nil)
        }
        center.discovery.start()
    }

    private func useLink(_ link: String) {
        guard let l = SetupProtocol.parseLink(link) else { return }
        step = .choose(SetupTarget.fromLink(l), l.code)
    }

    private func pick(_ t: SetupTarget) {
        codeText = ""
        step = t.code.map { .choose(t, $0) } ?? .code(t, nil)
    }

    private func back() {
        switch step {
        case .choose(let t, _): step = t.code != nil ? .pick : .code(t, nil)
        case .error(_, let b):
            switch b {
            case .pick: step = .pick
            case .choose(let t, let c): step = .choose(t, c)
            }
        default: step = .pick
        }
    }

    private func submitCode(_ t: SetupTarget) {
        let c = codeText.filter(\.isNumber)
        guard c.count == 6 else { step = .code(t, "Enter the 6-digit code shown on the TV."); return }
        step = .choose(t, c)
    }

    private func send(_ t: SetupTarget, _ code: String, _ pl: ServerConnection) {
        if t.isExpired {
            debugLog("[SETUP] target expired key=\(t.fingerprint)")
            step = .error(Self.noLongerWaiting, .pick)
            return
        }
        let payload = SetupSender.buildPayload(pl, profileIds: picked, turnOnSync: sync)
        step = .sending
        Task { @MainActor in
            switch await SetupSender.send(t, code: code, payload: payload) {
            case .ok:
                debugLog("[SETUP] sent, TV finishing setup key=\(t.fingerprint)")
                step = .sent
            case .wrongCode:
                var again = t
                again.code = nil
                codeText = ""
                step = .code(again, "The TV did not accept that code. Check the code on the TV and try again.")
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
        default: current = nil
        }
        guard let t = current else { return }
        let rotated = tvs.contains { ($0.serviceName == t.serviceName && t.serviceName != nil || $0.host == t.host) && $0.pk != t.pk }
        let gone = t.serviceName != nil && !tvs.contains { $0.serviceName == t.serviceName && $0.pk == t.pk }
        if rotated || gone {
            debugLog("[SETUP] target \(rotated ? "key changed" : "gone") key=\(t.fingerprint)")
            step = .error(Self.noLongerWaiting, .pick)
        }
    }
}

// MARK: - Dock card and Settings banner

/// The TV name, "Waiting for setup, key XXXX", Set up, and dismiss.
private struct SetupTvOfferContent: View {
    let target: SetupTarget
    let onSetUp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSetUp) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25))
                        Image(systemName: "tv")
                            .font(.system(size: 20))  // glyph in a fixed box: not text, stays fixed
                            .foregroundStyle(ThemeManager.shared.accent)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.name)
                            .scaledFont(.subheadline.weight(.bold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        Text(setupWaitingLine(target))
                            .scaledFont(.caption)
                            .foregroundStyle(Color.contrastText(ThemeManager.shared.accent))
                            .lineLimit(1)
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
    let subtitle: String
    let action: () -> Void

    static let listSubtitle = "Send the active playlist to AerioTV on a TV. Nothing to type on the TV."
    static let detailSubtitle = "Send this playlist, your profiles, and sync to a TV on your network."

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "tv").foregroundColor(.accentPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up a TV").scaledFont(.bodyMedium.weight(.semibold)).foregroundColor(.textPrimary)
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
    @Environment(\.scenePhase) private var scenePhase
    @Query private var servers: [ServerConnection]

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in center.setForeground(phase == .active) }
            .onChange(of: servers.first(where: \.isActive)?.id, initial: true) { _, _ in
                center.canOffer = SetupGate.canSetUpTv(servers.first(where: \.isActive))
            }
            .onOpenURL { url in
                // aeriotv://setup from the system camera. Never log the URL.
                guard url.scheme?.lowercased() == "aeriotv", url.host?.lowercased() == "setup" else { return }
                center.openLink(url.absoluteString)
            }
            .sheet(item: Binding(get: { center.presentedTarget }, set: { center.presentedTarget = $0 })) { t in
                SetUpTvView(target: t) { center.presentedTarget = nil }
            }
            .sheet(item: Binding(get: { center.pendingLink }, set: { center.pendingLink = $0 })) { box in
                SetUpTvView(link: box.link) { center.pendingLink = nil }
            }
    }
}
#endif
