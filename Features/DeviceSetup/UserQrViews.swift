//  UserQrViews.swift
//  Aerio
//
//  "Show User QR Code" (iPhone and iPad): renders a profile's
//  Dispatcharr sign-in as the same JSON QR the Dispatcharr web UI emits
//  (type=user_api_key, docs/DeviceSetupHandoff.md), so another device's
//  Scan QR code or Choose from Photos accepts it unchanged.
//
//  Why so guarded: the code is a working sign-in. A Device Admin PIN or the
//  profile's own PIN (when either exists) must be entered first; the code is
//  blurred until tapped, hides again after 60 seconds or when the app leaves
//  the foreground, and is blanked while the screen is recorded or mirrored.
//  The payload is never logged, copied, saved to Photos, or shared.

#if os(iOS)
import SwiftUI
import UIKit

enum UserQrPayload {
    struct Code: Equatable {
        let json: String
        let username: String
        let apiKey: String
    }

    /// JSON in the web UI's field order. Encoded per value so any character escapes correctly.
    static func json(apiKey: String, baseUrl: String, username: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        func q(_ s: String) -> String { (try? enc.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\"" }
        return "{\"v\":1,\"type\":\"\(ScannedCode.userKeyType)\",\"api_key\":\(q(apiKey)),\"base_url\":\(q(baseUrl)),"
            + "\"username\":\(q(username)),\"first_name\":\"\",\"last_name\":\"\",\"email\":\"\"}"
    }

    /// What Show User QR Code shows for a profile.
    enum Outcome: Equatable {
        case code(Code)
        /// A key is saved here, but the address the code would name is not
        /// proven after a server address change (StoredSecretRules): no code,
        /// the refusal line instead.
        case addressUnproven
        /// No key saved here: nothing to show.
        case none
    }

    /// [profileId]'s code on [playlistId]; nil unless the code may show.
    @MainActor
    static func code(playlistId: String, profileId: String) -> Code? {
        if case .code(let c) = outcome(playlistId: playlistId, profileId: profileId) { return c }
        return nil
    }

    @MainActor
    static func outcome(playlistId: String, profileId: String) -> Outcome {
        guard let server = DsyncLocal.server(playlistId), server.type == .dispatcharrAPI else { return .none }
        let pm = ProfileManager.shared
        guard let p = pm.store.byId(profileId) ?? pm.profiles(playlistId).first(where: { $0.id == profileId }) else { return .none }
        let stored = (p.isDefault ? server.baseApiKey : (pm.store.apiKey(p.id) ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return .none }
        // The device that scans the code signs in with the key at the code's
        // address: never one that is unproven after a server address change.
        // Another profile's key held after such a change reads as none here.
        let held = !p.isDefault && pm.signIns.apiKey(p.id, for: .setupPayload) == nil
        guard !held, pm.userQrMayCarryStoredKey(playlistId) else { return .addressUnproven }
        var base = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let user = p.username.isEmpty ? server.username : p.username
        let text = json(apiKey: stored, baseUrl: base, username: user)
        // Must read back exactly as a scan on another device would.
        guard let back = ScannedCode.parseUserKey(text), back.apiKey == stored else { return .none }
        return .code(Code(json: text, username: user, apiKey: stored))
    }

    /// The active Dispatcharr playlist's active profile, when it has a key
    /// here (shown, or refused while its address is unproven).
    @MainActor
    static func activeTarget() -> (playlistId: String, profileId: String)? {
        guard let server = DsyncLocal.activeDispatcharrPlaylist() else { return nil }
        let pid = server.id.uuidString
        guard let id = ProfileManager.shared.activeProfileIdNow(pid), outcome(playlistId: pid, profileId: id) != .none else { return nil }
        return (pid, id)
    }
}

/// The PIN step (when a Device Admin PIN or the profile's PIN exists), then the code.
struct UserQrFlow: View {
    let playlistId: String
    let profileId: String
    let onClose: () -> Void
    @State private var unlocked = false

    private var pm: ProfileManager { .shared }
    private var deviceId: String { pm.deviceAdminPinId(playlistId) }
    private var needsPin: Bool { pm.hasPin(profileId) || pm.hasDeviceAdminPin(playlistId) }

    var body: some View {
        if unlocked || !needsPin {
            UserQrCard(playlistId: playlistId, profileId: profileId, onClose: onClose)
        } else {
            ProfilePinEntry(
                title: PinCopy.userQr(pm.store.byId(profileId)?.displayName ?? ""),
                type: pm.pinType(profileId) ?? pm.deviceAdminPinType(playlistId) ?? .numbers,
                // Either the profile's PIN or the Device Admin PIN unlocks it, so
                // there is no single length: dots appear as digits are typed
                // (PinRules.dotCount), as on Android (2026-11-12).
                pinLength: nil,
                lockSeconds: {
                    [pm.hasPin(profileId) ? pm.pinLockSeconds(profileId) : nil,
                     pm.hasDeviceAdminPin(playlistId) ? pm.pinLockSeconds(deviceId) : nil].compactMap { $0 }.min() ?? 0
                },
                onDismiss: onClose,
                onEntered: { seq in
                    var last: ProfileManager.PinCheck = .wrong
                    if pm.hasPin(profileId) {
                        last = pm.verifyPin(profileId, seq)
                        if last == .ok { unlocked = true; return nil }
                    }
                    if pm.hasDeviceAdminPin(playlistId) {
                        let r = pm.verifyPin(deviceId, seq)
                        if r == .ok { unlocked = true; return nil }
                        if case .locked = last {} else { last = r }
                    }
                    return ProfileCopy.pinCheckMessage(last)
                }
            )
        }
    }
}

/// The code itself: blurred until tapped, hidden after 60 s, on background, and while captured.
private struct UserQrCard: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let profileId: String
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false
    @State private var captured = UIScreen.main.isCaptured
    @State private var revealToken = 0
    @State private var code: UserQrPayload.Code?
    @State private var image: UIImage?
    /// The address the code would name is unproven: this line, no code.
    @State private var refusal: String?
    /// Advertises this device while the code is up, so a device that scans it can copy the whole setup.
    @StateObject private var source = UserQrSource()

    var body: some View {
        VStack(spacing: 16) {
            Text("User QR Code")
                .scaledFont(.headlineMedium)
                .foregroundColor(.textPrimary)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white)
                if let refusal {
                    Text(refusal)
                        .scaledFont(.bodyMedium)
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                        .padding(20)
                } else if captured {
                    Text("Hidden while the screen is being recorded or shared.")
                        .scaledFont(.bodyMedium)
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                        .padding(20)
                } else if let image {
                    Image(uiImage: image)
                        .interpolation(.high)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .blur(radius: revealed ? 0 : 18)
                        .accessibilityHidden(true)
                    if !revealed {
                        Text("Tap to show")
                            .scaledFont(.headlineSmall)
                            .foregroundColor(.black)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.9)))
                    }
                }
            }
            .frame(width: 260, height: 260)
            .privacySensitive()
            .contentShape(Rectangle())
            .onTapGesture {
                guard !captured, image != nil, !revealed else { return }
                revealed = true
                revealToken += 1
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(refusal ?? (revealed ? "User QR code" : "Tap to show"))
            .accessibilityAddTraits(refusal == nil ? .isButton : [])
            if let code {
                Text("Anyone who scans this code can sign in as \(code.username). It hides after 60 seconds.")
                    .scaledFont(.bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sourceCard
            SecondaryButton("Done") { close() }
        }
        .padding(24)
        .frame(maxWidth: 380)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.cardBackground))
        .padding(16)
        .onAppear {
            switch UserQrPayload.outcome(playlistId: playlistId, profileId: profileId) {
            case .code(let c):
                code = c
                image = SetupQR.imageWithLogo(c.json)
                source.start(apiKey: c.apiKey, playlistId: playlistId)
            case .addressUnproven:
                ProfileManager.shared.noteStoredSecretRefused(playlistId, .userQrCode)
                refusal = StoredSecretCopy.fixLoginNewAddress
            case .none:
                onClose()
            }
        }
        .task(id: revealToken) {
            guard revealed else { return }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled { revealed = false }
        }
        .onChange(of: scenePhase) { _, p in if p != .active { revealed = false } }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
            if captured { revealed = false }
        }
        .onDisappear { close(dismiss: false) }
    }

    /// A device that scanned this code asks for the whole setup.
    @ViewBuilder
    private var sourceCard: some View {
        switch source.phase {
        case .idle:
            EmptyView()
        case .confirm(let name):
            VStack(spacing: 10) {
                Text("Send setup to \(name)?")
                    .scaledFont(.headlineSmall)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                Text("This copies this device's playlist, profiles, and preferences to \(name).")
                    .scaledFont(.bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton("Send") { source.send() }
                SecondaryButton("Don't send") { source.decline() }
            }
        case .sending(let name):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Sending setup to \(name)").scaledFont(.bodyMedium).foregroundColor(.textPrimary)
            }
        case .sent(let name):
            Text("Setup sent to \(name).").scaledFont(.bodyMedium).foregroundColor(.textPrimary)
        case .failed(let msg):
            Text(msg).scaledFont(.bodySmall).foregroundColor(.statusLive).multilineTextAlignment(.center)
        }
    }

    private func close(dismiss: Bool = true) {
        source.stop()
        revealed = false
        image = nil
        code = nil
        if dismiss { onClose() }
    }
}

/// Full-screen host for QrScanActions: the same dim backdrop as the profile dialogs.
struct UserQrCover: View {
    let playlistId: String
    let profileId: String
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            UserQrFlow(playlistId: playlistId, profileId: profileId, onClose: onClose)
        }
    }
}
#endif
