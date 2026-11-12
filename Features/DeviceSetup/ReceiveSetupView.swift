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
        /// The received playlist matches one already on this device (existing name).
        case duplicate(String)
        /// Fix Login: this playlist's sign-in was written and its hold lifted;
        /// the screen confirms, then closes.
        case signedIn(UUID)
    }

    /// What to do with a received playlist that matches an existing one.
    enum DuplicateChoice: Equatable { case replace(UUID), add }
    private var choice: DuplicateChoice?
    private var duplicateID: UUID?

    @Published private(set) var phase: Phase = .starting
    /// The received setup had Dispatcharr Sync on: offer it here before closing.
    @Published var syncOffer = false
    private let receiver = SetupReceiver()
    private var timeout: Task<Void, Never>?
    private var pending: SetupProtocol.Payload?
    private var offerSink: Task<Void, Never>?
    var modelContext: ModelContext?
    /// Set for "Copy entire setup from this device" after a User QR scan.
    var request: UserQrSourceRequest?
    /// Fix Login (TVs, from the rejected-key prompt): the playlist whose
    /// sign-in this screen asks a phone for. nil = a normal setup.
    var fixLoginPlaylistID: String?
    private var asked = false
    private static var askedRequests: Set<UUID> = []

    private var isOfferish: Bool {
        switch phase { case .starting, .offering, .requesting: return true; default: return false }
    }

    func start() {
        receiver.onPayload = { [weak self] p in Task { @MainActor in await self?.apply(p) } }
        receiver.fixLoginPlaylistID = fixLoginPlaylistID
        Task {
            // Advertised in every mode, as on Welcome, so other devices show the waiting banner.
            guard await receiver.start() else { phase = .noNetwork; return }
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
        // Once per request, even if the view (and this model) is rebuilt mid-setup.
        guard !asked, !Self.askedRequests.contains(r.id) else { return }
        asked = true
        Self.askedRequests.insert(r.id)
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

    fileprivate func setPhase(_ p: Phase) { phase = p }
    fileprivate func clearPending() { pending = nil; choice = nil }

    /// Answer to the "This playlist already exists" prompt. nil = Cancel.
    func resolveDuplicate(replace: Bool?) {
        guard case .duplicate = phase, let p = pending else { return }
        guard let replace else {
            debugLog("[SETUP] receiver: duplicate playlist, user cancelled; received setup abandoned")
            pending = nil
            choice = nil
            onCancelled?()
            return
        }
        if replace, let id = duplicateID {
            debugLog("[SETUP] receiver: duplicate playlist, replacing the existing one")
            choice = .replace(id)
        } else {
            debugLog("[SETUP] receiver: duplicate playlist, adding as a second playlist")
            choice = .add
        }
        Task { await apply(p) }
    }

    /// Fired when the user cancels at the duplicate prompt.
    var onCancelled: (() -> Void)?

    private func apply(_ p: SetupProtocol.Payload) async {
        if FixLogin.appliesAsFixLogin(screenPlaylistID: fixLoginPlaylistID, payloadMode: p.mode) {
            await applyFixLogin(p)
            return
        }
        pending = p
        stop()
        guard let ctx = modelContext else { phase = .failed("Setup is not ready. Try again."); return }
        let pl = p.playlist
        let cred = pl.credential
        // The sender's playlist id (2026-11-10): a row here with that id IS this
        // playlist, so it is updated in place, never added a second time.
        let senderID = pl.id.flatMap { UUID(uuidString: $0) }
        if choice == nil, let senderID,
           ((try? ctx.fetch(FetchDescriptor<ServerConnection>())) ?? []).contains(where: { $0.id == senderID }) {
            debugLog("[SETUP] receiver: the received playlist is already here (same id); updating it in place")
            choice = .replace(senderID)
        }
        if choice == nil {
            let all = (try? ctx.fetch(FetchDescriptor<ServerConnection>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
            let incoming = SetupPlaylistMatch.Candidate(type: SetupPlaylistMatch.kind(payloadType: pl.type), url: pl.url,
                                                        username: cred?.username ?? "", apiKey: cred?.apiKey ?? "")
            if let match = all.first(where: { SetupPlaylistMatch.matches(incoming, SetupPlaylistMatch.candidate(for: $0)) }) {
                debugLog("[SETUP] receiver: received playlist matches an existing one; asking")
                duplicateID = match.id
                phase = .duplicate(match.name)
                return
            }
            choice = .add
        }
        let replaceID: UUID? = { if case .replace(let id) = choice { return id } else { return nil } }()
        let applyingLine = replaceID != nil ? "Updating your playlist" : "Connecting to your server"
        // An in-place update may move the playlist to a new address: from here
        // on, no users/me answer (the payload's verify below) is recorded as
        // the default profile's account (ProfileHostHold).
        if let id = replaceID { ProfileManager.shared.beginRouteChange(id.uuidString) }
        defer { if let id = replaceID { ProfileManager.shared.endRouteChange(id.uuidString) } }
        phase = .applying(applyingLine)
        // A device setup is an explicit save: lift any local "this key was
        // rejected" hold for the key it carries and the playlist it replaces.
        if let id = replaceID { DispatcharrRequestGate.shared.clearPlaylist(id.uuidString) }
        if let k = cred?.apiKey { DispatcharrRequestGate.shared.clearKey(k) }
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
        // A 429 (the server's API-key throttle, tripped by another client on
        // this network, 2026-11-09) counts down and tries again, twice, then
        // names the rate limit.
        await vm.verifyConnection(
            onCountdown: { [weak self] line, left in
                if left == DispatcharrRequestGate.maxRetryAfter || left % 10 == 0 {
                    debugLog("[SETUP] server rate-limited the playlist add; retrying in \(left)s")
                }
                self?.phase = .applying(line)
            },
            onRetry: { [weak self] in self?.phase = .applying(applyingLine) }
        )
        guard vm.verificationSuccess else {
            debugLog("[SETUP] receiver: playlist connect failed")
            phase = .failed(vm.verificationError ?? "Could not connect to your server.")
            return
        }
        // The Add Playlist save path (AddServerView.saveServer).
        let existing = (try? ctx.fetch(FetchDescriptor<ServerConnection>())) ?? []
        let incoming = vm.buildServerConnection()
        if case .replace(let id) = choice, let target = existing.first(where: { $0.id == id }), target.type == .dispatcharrAPI {
            // Before the new address is written: the other profiles' stored
            // sign-ins are held and a held active profile is left for the
            // default one (ProfileHostHold, review finding A-APP-1).
            await ProfileManager.shared.routeWillChange(target.id.uuidString, oldBase: target.baseURL, oldLocal: target.localURL,
                                                        newBase: incoming.baseURL, newLocal: incoming.localURL)
        }
        for s in existing { s.isActive = false }
        var replaced = false
        let server: ServerConnection
        if case .replace(let id) = choice, let target = existing.first(where: { $0.id == id }) {
            // Replace in place: same row id, so cached channels, EPG, and favorites stay.
            let jwt = vm.pendingJWTPair
            vm.pendingJWTPair = nil
            SetupPlaylistMatch.copy(from: incoming, into: target)
            if let jwt { DispatcharrTokenStore.shared.store(serverID: target.id, access: jwt.access, refresh: jwt.refresh) }
            server = target
            replaced = true
        } else {
            let jwt = vm.pendingJWTPair
            vm.pendingJWTPair = nil
            server = incoming
            // Keep the sender's id when no row here has it, so iCloud sees one
            // playlist on both devices (the sign-in token follows the id).
            if let senderID, !existing.contains(where: { $0.id == senderID }) {
                server.id = senderID
                debugLog("[SETUP] receiver: kept the sender's playlist id")
            }
            if let jwt { DispatcharrTokenStore.shared.store(serverID: server.id, access: jwt.access, refresh: jwt.refresh) }
        }
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
        if !replaced { ctx.insert(server) }
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
                                                                      password: pp.credential?.password, apiKey: pp.credential?.apiKey,
                                                                      profileId: pp.id)
                } catch {
                    skipped += 1
                    debugLog("[SETUP] receiver: a profile was not added (\(type(of: error)))")
                }
            }
        }
        // An in-place update to a new address: the same server lifts the profile hold at once.
        if isD && replaced { await ProfileManager.shared.recheckHostHold(pid) }
        if isD, let sync = p.sync, sync.enabled, sync.provider == "dispatcharr", !DispatcharrSyncManager.shared.isEnabled {
            // Never turned on silently: the owner answers the opt-in once the setup has applied.
            if DsyncUpgradeOfferStore.declined {
                debugLog("[DSYNC] setup carried sync: declined before, not offered")
            } else {
                syncOffer = true
                debugLog("[DSYNC] setup carried sync: offering")
            }
        }
        pending = nil
        choice = nil
        debugLog("[SETUP] receiver: applied (\(replaced ? "replaced existing playlist" : "new playlist"), \(p.profiles.count - skipped) profiles, skipped \(skipped))")
        // Fresh browse once set up: a browser started before Local Network
        // permission was granted may never deliver results.
        #if os(iOS)
        if SetupTvOfferCenter.shared.discovery.isRunning { SetupTvOfferCenter.shared.discovery.restart() }
        #endif
        phase = .done
    }
}

extension SetupApplyModel {
    /// Fix Login (docs/DeviceSetupHandoff.md): only the sign-in of the playlist
    /// this screen was opened for (or, for a `mode: "fixlogin"` payload on a
    /// normal screen, the playlist it names) is written: the API key, and the
    /// username and password when sent. Profiles, settings, and other
    /// playlists are never touched, whatever else the payload carries. Then
    /// the hold and its prompt are lifted and the channels reload. Not for a
    /// playlist here: "Setup did not finish" and the screen stays open (Retry
    /// offers a new code).
    fileprivate func applyFixLogin(_ p: SetupProtocol.Payload) async {
        stop()
        // A failed fix never re-applies the same payload: Retry starts a new code.
        clearPending()
        setPhase(.applying(FixLogin.applyingLine))
        guard let ctx = modelContext else { setPhase(.failed(FixLogin.notHere)); return }
        let all = (try? ctx.fetch(FetchDescriptor<ServerConnection>())) ?? []
        guard let pid = FixLogin.receiverPlaylistID(screenPlaylistID: fixLoginPlaylistID, payloadID: p.playlist.id,
                                                    localIDs: all.map(\.id.uuidString)),
              let server = all.first(where: { $0.id.uuidString == pid }) else {
            debugLog("[SETUP] fix login: the sign-in is not for \(fixLoginPlaylistID != nil ? "the playlist this screen asked for" : "a playlist here")")
            setPhase(.failed(FixLogin.notHere))
            return
        }
        let oldKey = server.baseApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let next = FixLogin.signInToWrite(oldKey: oldKey, oldUser: server.username,
                                                oldPass: server.effectivePassword, sent: p.playlist.credential) else {
            debugLog("[SETUP] fix login: no sign-in was sent")
            setPhase(.failed(FixLogin.notHere))
            return
        }
        // Only the playlist's current account (follow-up 11): verify the sent sign-in at the
        // playlist's address and compare users/me before anything is written.
        guard await fixLoginAccountAccepted(server, sent: p.playlist.credential, username: next.username) else {
            debugLog("[SETUP] fix login: the sent sign-in is not this playlist's account (or did not verify); nothing written")
            setPhase(.failed(FixLogin.notHere))
            return
        }
        guard !server.isGone else { setPhase(.failed(FixLogin.notHere)); return }
        // Only the sign-in fields; the credentials go to the Keychain as on any save.
        if let k = next.apiKey { server.apiKey = k }
        if let u = next.username { server.username = u }
        if let pw = next.password { server.password = pw }
        if next.accountChanged {
            // Sessions minted for the old sign-in belong to it.
            DispatcharrTokenStore.shared.clear(serverID: server.id)
            CatchupSupport.invalidateCredentials(serverID: server.id)
        }
        let newKey = next.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Lift the hold first so the credential save below treats the new key as good.
        DispatcharrRequestGate.shared.liftFixedLogin(playlistID: server.id.uuidString,
                                                     oldKey: oldKey.isEmpty ? nil : oldKey, newKey: newKey)
        SyncManager.shared.saveCredentialsSynced(for: server)
        try? ctx.save()
        debugLog("[SETUP] fix login applied to \(server.id.uuidString.prefix(8)): key \(newKey != nil && newKey != oldKey ? "replaced" : "unchanged")"
                 + (next.accountChanged ? ", username or password updated" : "") + "; hold lifted")
        // The same reload as a held key that proves good again: channels, guide, On Demand.
        DispatcharrKeyRecheck.shared.onRecovered?(server.id.uuidString)
        setPhase(.signedIn(server.id))
    }

    /// users/me with the sent key, else a login with the sent password, at the
    /// playlist's address; then the same account check as the sign-in form.
    private func fixLoginAccountAccepted(_ server: ServerConnection, sent: SetupProtocol.Credential?, username: String?) async -> Bool {
        let base = server.effectiveBaseURL
        let ua = server.effectiveUserAgent
        let key = sent?.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = sent?.password ?? ""
        let user = (sent?.username ?? username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let me: DispatcharrUser?
        if !key.isEmpty {
            me = try? await DispatcharrAPI(baseURL: base, auth: .apiKey(key), userAgent: ua, authMode: server.dispatcharrHeaderMode).fetchCurrentUser()
        } else if !password.isEmpty, !user.isEmpty,
                  let pair = try? await DispatcharrAPI.login(baseURL: base, username: user, password: password, userAgent: ua) {
            me = try? await DispatcharrAPI(baseURL: base, auth: .bearer(pair.access), userAgent: ua).fetchCurrentUser()
        } else {
            me = nil
        }
        guard let me else { return false }
        return KeySignInService.accountAccepted(server, userId: me.id, username: me.username)
    }
}

struct ReceiveSetupView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SetupApplyModel()
    @State private var showSyncOffer = false
    var request: UserQrSourceRequest? = nil
    /// "Import this user only" after a failed User QR request.
    var onUserOnly: (() -> Void)? = nil
    /// Fix Login (TVs, from the rejected-key prompt): ask a phone for this
    /// playlist's sign-in only. The advert carries `mode=fixlogin` and `pl`.
    var fixLoginPlaylistID: String? = nil
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
            // iPad: centered vertically, as in the Welcome flow.
            .onboardingPadCentered()
        }
        .onAppear {
            model.modelContext = modelContext
            model.request = request
            model.fixLoginPlaylistID = fixLoginPlaylistID
            model.onCancelled = { onCancel() }
            model.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { _, p in
            if p == .done {
                if model.syncOffer { showSyncOffer = true } else { onDone() }
            }
        }
        // Fix Login: the reload is under way; show the confirmation briefly, then close.
        .task(id: model.phase) {
            guard case .signedIn = model.phase else { return }
            try? await Task.sleep(nanoseconds: UInt64(FixLogin.doneSeconds * 1_000_000_000))
            if !Task.isCancelled { onDone() }
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showSyncOffer) { syncOfferView }
        #else
        .sheet(isPresented: $showSyncOffer) { syncOfferView.interactiveDismissDisabled() }
        #endif
        #if os(tvOS)
        .onExitCommand { if !applying { cancel() } }
        #endif
        .interactiveDismissDisabled(applying)
    }

    /// Same prompt and copy as the upgrade offer's "record found" case ("Turn it on here too?").
    private var syncOfferView: some View {
        DsyncUpgradeOptInView(
            iCloudOn: false,
            onTurnOn: {
                WelcomeSyncChain.markAnswered(SyncProvidersRules.DISPATCHARR)
                DispatcharrSyncManager.shared.setEnabled(true)
                debugLog("[DSYNC] enabled from another device's setup (opt-in)")
                finishSyncOffer()
            },
            onNotNow: {
                WelcomeSyncChain.markAnswered(SyncProvidersRules.DISPATCHARR)
                DsyncUpgradeOfferStore.decline()
                debugLog("[DSYNC] setup sync offer declined")
                finishSyncOffer()
            })
    }

    private func finishSyncOffer() {
        model.syncOffer = false
        showSyncOffer = false
        onDone()
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
        case .duplicate(let name):
            duplicatePrompt(name)
        case .signedIn:
            VStack(spacing: 20) {
                ProgressView()
                Text(FixLogin.doneLine).scaledFont(.headlineMedium).foregroundColor(.textPrimary)
            }
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
            Text(fixLoginPlaylistID != nil ? FixLogin.receiveTitle : Self.title)
                .scaledFont(isTV ? .system(size: 44, weight: .bold) : .headlineLarge)
                .foregroundColor(.textPrimary)
            Text(fixLoginPlaylistID != nil ? FixLogin.receiveLine : Self.instructions)
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

    static let duplicateTitle = "This playlist already exists"
    static func duplicateBody(_ name: String) -> String {
        "\(name) uses the same server and account. Replace it with the incoming setup, or add it as a second playlist?"
    }

    private enum DupFocus: Hashable { case cancel, add, replace }
    @FocusState private var dupFocus: DupFocus?

    /// Cancel, Add Anyway, Replace (primary, focused on TV). Matches Android.
    private func duplicatePrompt(_ name: String) -> some View {
        VStack(spacing: 12) {
            Text(Self.duplicateTitle)
                .scaledFont(isTV ? .system(size: 40, weight: .bold) : .headlineLarge)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
            Text(Self.duplicateBody(name))
                .scaledFont(isTV ? .system(size: 24).subtext() : .bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                OnboardingPillButton(title: "Cancel", filled: false) { model.resolveDuplicate(replace: nil) }
                    .focused($dupFocus, equals: .cancel)
                OnboardingPillButton(title: "Add Anyway", filled: false) { model.resolveDuplicate(replace: false) }
                    .focused($dupFocus, equals: .add)
                OnboardingPillButton(title: "Replace", filled: true) { model.resolveDuplicate(replace: true) }
                    .focused($dupFocus, equals: .replace)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: 640)
        .defaultFocus($dupFocus, .replace)
        .onAppear { if isTV { dupFocus = .replace } }
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

/// Does a received playlist match one already on this device? Same source
/// type, same normalized server URL (scheme, host, port, path; host case
/// insensitive; trailing slash ignored), and the same account: username
/// (Xtream), API key or Dispatcharr user (Dispatcharr), or the same playlist
/// URL including its query (M3U). Pure logic; Android matches.
enum SetupPlaylistMatch {
    enum Kind: Equatable { case dispatcharr, xtream, m3u }
    struct Candidate: Equatable {
        var type: Kind
        var url: String
        var username: String
        var apiKey: String
    }

    static func kind(payloadType: String) -> Kind {
        switch payloadType { case "dispatcharr": return .dispatcharr; case "xtream": return .xtream; default: return .m3u }
    }

    static func candidate(for s: ServerConnection) -> Candidate {
        let k: Kind = s.type == .dispatcharrAPI ? .dispatcharr : (s.type == .xtreamCodes ? .xtream : .m3u)
        var user = s.username
        if k == .dispatcharr, user.trimmingCharacters(in: .whitespaces).isEmpty {
            user = DispatcharrAccountFactsStore.load(s.id).username
        }
        return Candidate(type: k, url: s.baseURL, username: user, apiKey: k == .dispatcharr ? s.baseApiKey : "")
    }

    /// Normalized "scheme://host:port/path" (plus "?query" when asked). nil when unparsable.
    static func normalizedURL(_ raw: String, keepQuery: Bool = false) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "http://" + t }
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : -1))
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        var out = "\(scheme)://\(host):\(port)\(path)"
        if keepQuery, let q = c.query, !q.isEmpty { out += "?" + q }
        return out
    }

    static func matches(_ a: Candidate, _ b: Candidate) -> Bool {
        guard a.type == b.type else { return false }
        let keepQuery = a.type == .m3u
        guard let ua = normalizedURL(a.url, keepQuery: keepQuery), ua == normalizedURL(b.url, keepQuery: keepQuery) else { return false }
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch a.type {
        case .m3u:
            return true
        case .xtream:
            return !t(a.username).isEmpty && t(a.username) == t(b.username)
        case .dispatcharr:
            if !t(a.apiKey).isEmpty && t(a.apiKey) == t(b.apiKey) { return true }
            return !t(a.username).isEmpty && t(a.username).lowercased() == t(b.username).lowercased()
        }
    }

    /// Replace in place: copies the verified incoming connection's settings
    /// onto the existing row, keeping its id (and so its cached data).
    @MainActor
    static func copy(from n: ServerConnection, into s: ServerConnection) {
        s.name = n.name
        s.baseURL = n.baseURL
        s.username = n.username
        s.password = n.password
        s.apiKey = n.apiKey
        s.epgURL = n.epgURL
        s.localURL = n.localURL
        s.localEPGURL = n.localEPGURL
        s.dispatcharrXMLTVURL = n.dispatcharrXMLTVURL
        s.xtreamXMLTVURL = n.xtreamXMLTVURL
        s.vodEnabled = n.vodEnabled
        s.epgRetentionDays = n.epgRetentionDays
        guard s.type == .dispatcharrAPI else { return }
        if !n.dispatcharrAuthMode.isEmpty { s.dispatcharrAuthMode = n.dispatcharrAuthMode }
        s.dispatcharrCredentialTypeRaw = n.dispatcharrCredentialTypeRaw
        s.dispatcharrUserLevel = n.dispatcharrUserLevel
        s.dispatcharrChannelProfileIDs = n.dispatcharrChannelProfileIDs
        s.dispatcharrDVRAccess = n.dispatcharrDVRAccess
        s.dispatcharrCatchupEnabled = n.dispatcharrCatchupEnabled
        s.dispatcharrVODMoviesEnabled = n.dispatcharrVODMoviesEnabled
        s.dispatcharrVODSeriesEnabled = n.dispatcharrVODSeriesEnabled
        s.dispatcharrIsStaff = n.dispatcharrIsStaff
        s.dispatcharrIsSuperuser = n.dispatcharrIsSuperuser
        s.dispatcharrSystemCatchupEnabled = n.dispatcharrSystemCatchupEnabled
        if !n.dispatcharrCustomPropertiesJSON.isEmpty {
            s.dispatcharrCustomPropertiesJSON = n.dispatcharrCustomPropertiesJSON
            s.dispatcharrCapabilitiesSchema = n.dispatcharrCapabilitiesSchema
            s.dispatcharrPermissionsFetchedAt = n.dispatcharrPermissionsFetchedAt
        }
        if !n.dispatcharrServerVersion.isEmpty { s.dispatcharrServerVersion = n.dispatcharrServerVersion }
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
