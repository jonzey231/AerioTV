//  ReceiveSetupView.swift
//  Aerio
//
//  "Set up from another device" (docs/DeviceSetupHandoff.md; port of Android
//  feature/devicesetup/TvSetupScreen.kt). Every platform receives: Welcome on
//  iPhone, iPad, and Apple TV, and Add Playlist on iPhone and iPad. Offers a
//  one-time code and key over the LAN, then applies the sealed payload with
//  no typing: the playlist through the Add Playlist save path, profiles
//  through the roster add path, and Dispatcharr Sync when it was sent.

import SwiftUI
import SwiftData
import CoreImage
import CoreImage.CIFilterBuiltins

@MainActor
final class SetupApplyModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case offering(SetupReceiver.Offer)
        case noNetwork
        case expired
        case applying(String)
        case failed(String)
        case done
        /// User QR request: waiting for Send on the device showing the code.
        case requesting(String)
        case requestFailed(String)
    }

    @Published private(set) var phase: Phase = .starting
    private let receiver = SetupReceiver()
    private var timeout: Task<Void, Never>?
    private var pending: SetupProtocol.Payload?
    private var offerSink: Task<Void, Never>?
    var modelContext: ModelContext?
    /// Set for "Copy entire setup from this device" after a User QR scan.
    var request: UserQrSourceRequest?
    private var asked = false

    private var isOfferish: Bool {
        switch phase { case .starting, .offering, .requesting: return true; default: return false }
    }

    func start() {
        receiver.onPayload = { [weak self] p in Task { @MainActor in await self?.apply(p) } }
        Task {
            guard await receiver.start(advertise: request == nil) else { phase = .noNetwork; return }
            offerSink?.cancel()
            offerSink = Task { [weak self] in
                guard let self else { return }
                for await o in self.receiver.$offer.values {
                    guard let o, self.isOfferish else { continue }
                    if let r = self.request { self.ask(r, link: o.link) } else { self.phase = .offering(o) }
                }
            }
        }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SetupProtocol.windowSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isOfferish else { return }
            self.stop()
            self.phase = .expired
        }
    }

    /// Sends this receiver's link to the device showing the User QR Code, once.
    private func ask(_ r: UserQrSourceRequest, link: String) {
        if case .requesting = phase { return }
        guard !asked else { return }
        asked = true
        phase = .requesting(r.device.name)
        Task { [weak self] in
            let out = await UserQrRequest.ask(r.device, link: link, apiKey: r.apiKey)
            guard let self, out != .ok, case .requesting = self.phase else { return }
            self.stop()
            self.phase = .requestFailed(out == .network ? UserQrRequest.unreachableMessage : "\(r.device.name) did not send its setup.")
        }
    }

    func restart() {
        stop()
        asked = false
        phase = .starting
        start()
    }

    func stop() {
        timeout?.cancel()
        offerSink?.cancel()
        receiver.stop()
    }

    func retry() {
        guard let p = pending else { restart(); return }
        Task { await apply(p) }
    }

    private func apply(_ p: SetupProtocol.Payload) async {
        pending = p
        stop()
        guard let ctx = modelContext else { phase = .failed("Setup is not ready. Try again."); return }
        phase = .applying("Connecting to your server")
        let pl = p.playlist
        let cred = pl.credential
        let vm = ServerConnectionViewModel()
        vm.name = pl.name
        vm.baseURL = pl.url
        vm.localURL = pl.localUrl ?? ""
        vm.vodEnabled = pl.vodEnabled
        vm.epgRetentionDays = pl.guideDays
        switch pl.type {
        case "dispatcharr":
            vm.serverType = .dispatcharrAPI
            vm.dispatcharrXMLTVURL = pl.xmltvUrl ?? ""
            if let k = cred?.apiKey, !k.isEmpty {
                vm.dispatcharrCredentialType = .apiKey
                vm.apiKey = k
            } else {
                vm.dispatcharrCredentialType = .usernamePassword
            }
            vm.username = cred?.username ?? ""
            vm.password = cred?.password ?? ""
        case "xtream":
            vm.serverType = .xtreamCodes
            vm.xtreamXMLTVURL = pl.xmltvUrl ?? ""
            vm.username = cred?.username ?? ""
            vm.password = cred?.password ?? ""
        default:
            vm.serverType = .m3uPlaylist
            vm.epgURL = pl.xmltvUrl ?? ""
        }
        await vm.verifyConnection()
        guard vm.verificationSuccess else {
            debugLog("[SETUP] receiver: playlist connect failed")
            phase = .failed(vm.verificationError ?? "Could not connect to your server.")
            return
        }
        // The Add Playlist save path (AddServerView.saveServer).
        let existing = (try? ctx.fetch(FetchDescriptor<ServerConnection>())) ?? []
        for s in existing { s.isActive = false }
        let server = vm.buildServerConnection()
        server.isActive = true
        server.isVerified = true
        server.lastConnected = Date()
        let isD = server.type == .dispatcharrAPI
        if isD {
            server.defaultRecordingDestination = server.dispatcharrCanRecordToServer ? server.defaultRecordingDestination : .local
            if let ua = pl.userAgent, !ua.isEmpty { server.customUserAgent = ua }
            if server.dispatcharrChannelProfileIDs.isEmpty && !pl.channelProfileIds.isEmpty {
                server.dispatcharrChannelProfileIDs = pl.channelProfileIds.map(String.init).joined(separator: ",")
            }
        }
        ctx.insert(server)
        try? ctx.save()
        SyncManager.shared.saveCredentialsSynced(for: server)
        if server.type != .m3uPlaylist {
            UserDefaults.standard.set(pl.catchupOffsetMinutes, forKey: CatchupSupport.timeOffsetKey(serverID: server.id))
        }
        let pid = server.id.uuidString
        var skipped = 0
        if isD && !p.profiles.isEmpty {
            phase = .applying("Adding profiles")
            // Default first (its PIN may be the Admin PIN a Child row needs), then Admins, then the rest.
            let ordered = p.profiles.sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                if (a.role == "child") != (b.role == "child") { return b.role == "child" }
                return (a.order < 0 ? Int.max : a.order) < (b.order < 0 ? Int.max : b.order)
            }
            for pp in ordered {
                let row = ProfileRow(userId: 0, username: pp.username, displayName: pp.displayName,
                                     pinType: pp.pinType, pinHash: pp.pinHash, pinSalt: pp.pinSalt, role: pp.role,
                                     avatar: pp.avatar.map { AvatarSpec(icon: $0.icon, color: $0.color) }, order: pp.order)
                do {
                    try await ProfileManager.shared.applySetupProfile(pid, row: row, isDefault: pp.isDefault,
                                                                      password: pp.credential?.password, apiKey: pp.credential?.apiKey)
                } catch {
                    skipped += 1
                    debugLog("[SETUP] receiver: a profile was not added (\(type(of: error)))")
                }
            }
        }
        if isD, let sync = p.sync, sync.enabled, sync.provider == "dispatcharr" {
            phase = .applying("Syncing")
            DispatcharrSyncManager.shared.setEnabled(true)
            debugLog("[DSYNC] enabled from another device's setup")
            _ = await DispatcharrSyncManager.shared.awaitFirstPull()
        }
        pending = nil
        debugLog("[SETUP] receiver: applied (\(p.profiles.count - skipped) profiles, skipped \(skipped))")
        phase = .done
    }
}

struct ReceiveSetupView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SetupApplyModel()
    var request: UserQrSourceRequest? = nil
    /// "Import this user only" after a failed User QR request.
    var onUserOnly: (() -> Void)? = nil
    let onCancel: () -> Void
    let onDone: () -> Void

    static let title = "Set up from another device"
    static let instructions = "Open AerioTV on your other device, then Settings > Playlists > open your playlist > Set up another device, or scan this code."

    private var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, isTV ? 80 : 20)
                    .padding(.vertical, isTV ? 60 : 32)
            }
        }
        .onAppear {
            model.modelContext = modelContext
            model.request = request
            model.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { _, p in if p == .done { onDone() } }
        #if os(tvOS)
        .onExitCommand { if !applying { cancel() } }
        #endif
        .interactiveDismissDisabled(applying)
    }

    private var applying: Bool { if case .applying = model.phase { return true }; return false }

    private func cancel() { model.stop(); onCancel() }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting, .done:
            ProgressView()
        case .offering(let o):
            offering(o)
        case .noNetwork:
            message(title: "This device is not on a network",
                    body: "Connect this device to the same network as your other device, then try again.",
                    primary: ("Try Again", { model.restart() }))
        case .expired:
            message(title: "The setup code expired",
                    body: "Codes last 10 minutes. Get a new code to try again.",
                    primary: ("New Code", { model.restart() }))
        case .applying(let step):
            VStack(spacing: 20) {
                ProgressView()
                Text(step).scaledFont(.headlineMedium).foregroundColor(.textPrimary)
            }
        case .failed(let msg):
            message(title: "Setup did not finish", body: msg, primary: ("Retry", { model.retry() }))
        case .requesting(let name):
            VStack(spacing: 12) {
                ProgressView()
                Text("Waiting for \(name)")
                    .scaledFont(isTV ? .system(size: 40, weight: .bold) : .headlineLarge)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Tap Send on \(name) to copy its setup to this device.")
                    .scaledFont(isTV ? .system(size: 24).subtext() : .bodyMedium.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                OnboardingPillButton(title: "Cancel", filled: false) { cancel() }
                    .padding(.top, 12)
            }
            .frame(maxWidth: 640)
        case .requestFailed(let msg):
            message(title: "Setup did not finish", body: msg,
                    primary: ("Import this user only", { model.stop(); onUserOnly?() }))
        }
    }

    private func offering(_ o: SetupReceiver.Offer) -> some View {
        let qr = SetupQR.image(o.link)
        let qrBox = ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white)
            if let qr { Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().padding(12) }
        }
        .frame(width: isTV ? 360 : 240, height: isTV ? 360 : 240)
        .accessibilityLabel("Setup QR code")
        let details = VStack(alignment: isTV ? .leading : .center, spacing: 12) {
            Text(Self.title)
                .scaledFont(isTV ? .system(size: 44, weight: .bold) : .headlineLarge)
                .foregroundColor(.textPrimary)
            Text(Self.instructions)
                .scaledFont(isTV ? .system(size: 24).subtext() : .bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .multilineTextAlignment(isTV ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
            Text(o.code.prefix(3) + " " + o.code.suffix(3))
                .font(.system(size: isTV ? 72 : 48, weight: .bold, design: .monospaced))
                .foregroundColor(.accentPrimary)
            Text("Key \(o.fingerprint)")
                .font(.system(size: isTV ? 28 : 20, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
            Text(o.deviceName)
                .scaledFont(.bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
            OnboardingPillButton(title: "Cancel", filled: false) { cancel() }
                .padding(.top, 12)
        }
        return Group {
            if isTV {
                HStack(spacing: 60) { qrBox; details.frame(maxWidth: 700, alignment: .leading) }
            } else {
                VStack(spacing: 24) { qrBox; details }.frame(maxWidth: 560)
            }
        }
    }

    private func message(title: String, body: String, primary: (String, () -> Void)) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .scaledFont(isTV ? .system(size: 40, weight: .bold) : .headlineLarge)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
            Text(body)
                .scaledFont(isTV ? .system(size: 24).subtext() : .bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                OnboardingPillButton(title: primary.0, filled: true) { primary.1() }
                OnboardingPillButton(title: "Cancel", filled: false) { cancel() }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: 640)
    }
}

/// QR images for the setup link and the Dispatcharr user code (error correction H).
enum SetupQR {
    static func image(_ text: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext(options: nil).createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Share of the QR image's width the white logo plate covers. Level H restores up to
    /// 30 percent of codewords, so a 20 percent plate leaves ample margin. Android matches.
    static let logoPlateFraction: CGFloat = 0.20
    /// Logo inset inside the plate, as a share of the plate side.
    static let logoMarginFraction: CGFloat = 0.12

    /// [image] with the AerioTV mark centered on a rounded white plate. Same payload, same
    /// level H code; the plate masks the modules under it so the mark reads cleanly.
    static func imageWithLogo(_ text: String, scale: CGFloat = 10) -> UIImage? {
        guard let qr = image(text, scale: scale)?.cgImage else { return nil }
        guard let logo = UIImage(named: "AerioLogo")?.cgImage else { return UIImage(cgImage: qr) }
        return composite(qr: qr, logo: logo).map { UIImage(cgImage: $0) } ?? UIImage(cgImage: qr)
    }

    /// Pure CoreGraphics so a script can render and decode the exact same image.
    static func composite(qr: CGImage, logo: CGImage) -> CGImage? {
        let w = qr.width, h = qr.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(qr, in: CGRect(x: 0, y: 0, width: w, height: h))
        let side = (CGFloat(min(w, h)) * logoPlateFraction).rounded()
        let plate = CGRect(x: (CGFloat(w) - side) / 2, y: (CGFloat(h) - side) / 2, width: side, height: side)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil))
        ctx.fillPath()
        ctx.interpolationQuality = .high
        ctx.draw(logo, in: plate.insetBy(dx: side * logoMarginFraction, dy: side * logoMarginFraction))
        return ctx.makeImage()
    }
}
