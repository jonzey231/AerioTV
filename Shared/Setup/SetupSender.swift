//  SetupSender.swift
//  Aerio
//
//  Phone and tablet sender for "Set up a TV from your phone"
//  (docs/DeviceSetupHandoff.md; port of Android core/setup/SetupSender.kt,
//  feature/devicesetup/SetupTvDockCard.kt offer logic, core/qr/QrImportBus.kt).
//  Browses _aeriotv-setup._tcp with NWBrowser, builds the payload from this
//  device's playlist, seals it (SetupProtocol), and POSTs it to the TV.
//
//  Logs never carry a key, code, payload, QR text, or URL: only the TV's
//  fingerprint, counts, HTTP status, and error kinds.

import Foundation
import Network
#if os(iOS)
import Combine
import SwiftData

/// A TV offering setup: from discovery (key only) or from its QR link (code included).
struct SetupTarget: Identifiable, Equatable, Sendable {
    let name: String
    let host: String
    let port: Int
    let pk: Data
    /// The code itself, when it came from a QR link.
    var code: String? = nil
    /// Bonjour instance name when discovered (nil for a QR target).
    var serviceName: String? = nil
    /// When this advert (or QR) was first seen; the TV session lasts 10 minutes.
    var seenAt: Date = Date()
    /// TXT `kind`; a QR link carries none, so it reads as tv (the only receiver before kind).
    var kind: SetupProtocol.Kind = .tv

    /// Name plus key: a TV that rotates its key is a new target.
    var id: String { name + "|" + SetupCrypto.b64(pk) }
    /// Matches the 4 characters the TV shows next to its code.
    var fingerprint: String { SetupCrypto.keyFingerprint(pk) }
    var isExpired: Bool { Date().timeIntervalSince(seenAt) > SetupProtocol.windowSeconds }

    static func fromLink(_ l: SetupProtocol.Link) -> SetupTarget {
        SetupTarget(name: l.name.isEmpty ? "AerioTV" : l.name, host: l.ip, port: l.port, pk: l.pk, code: l.code)
    }

    static func == (a: SetupTarget, b: SetupTarget) -> Bool {
        a.id == b.id && a.host == b.host && a.port == b.port && a.code == b.code
    }
}

extension SetupProtocol.Kind {
    /// Device-type icon in the sender's list, the dock card, and the banner.
    var symbol: String {
        switch self { case .phone: return "iphone"; case .tablet: return "ipad"; case .tv: return "appletv" }
    }
}

// MARK: - Discovery

/// NWBrowser for `_aeriotv-setup._tcp`. Each advert is validated (TXT v=1,
/// 32-byte pk) and resolved to an IPv4 host and port through a short
/// NWConnection. A changed pk under the same instance replaces the row.
@MainActor
final class SetupDiscovery: ObservableObject {
    @Published private(set) var tvs: [SetupTarget] = []

    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    /// Instance name -> resolved target.
    private var byService: [String: SetupTarget] = [:]
    private let queue = DispatchQueue(label: "aerio.setup.discovery")

    var isRunning: Bool { browser != nil }
    /// True once the current browser has delivered a browse result set (even an empty one).
    /// A browser that only reports .ready can still be deaf for the whole session.
    /// True once the running browser delivered a result. Reset on start and stop, so a
    /// list emptied by stop() (scene inactive) is not read as the device leaving.
    private(set) var heard = false
    /// Recreations of a browser that reached ready but never delivered results.
    private var recreations = 0
    private var silentRestarts = 0
    private var watchdog: Task<Void, Never>?

    /// Cancels and recreates the browser. A browser started before Local
    /// Network permission was granted can stay silent for the whole session.
    func restart() {
        if browser != nil { stop() }
        start()
    }

    func start() {
        guard browser == nil else { return }
        recreations = 0
        makeBrowser()
        debugLog("[SETUP] discovery started")
        watchdog?.cancel()
        // While no results callback has fired, recreate the browser every 5 s for as long as
        // discovery runs. Measured: a browser sat at ready with zero results for over 2 minutes
        // while the advert resolved on the LAN; a relaunch always fixed it. Once results arrive
        // the loop ends; a browse that later returns to empty is normal. stop() cancels it, and
        // everything here runs on the main actor, so it cannot interleave with stop() or start().
        watchdog = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, let old = self.browser else { return }
                if self.heard { return }
                self.recreations += 1
                let n = self.recreations
                if n <= 3 || n % 5 == 0 { debugLog("[SETUP] discovery recreated (ready, no results) n=\(n)") }
                old.cancel()
                self.makeBrowser()
            }
        }
    }

    private func makeBrowser() {
        heard = false
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: SetupProtocol.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self, weak b] state in
            // Only a browse result counts as heard; .ready alone does not.
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                switch state {
                case .ready:
                    debugLog("[SETUP] discovery ready")
                case .setup:
                    debugLog("[SETUP] discovery state setup")
                case .cancelled:
                    debugLog("[SETUP] discovery state cancelled")
                case .failed(let e):
                    debugLog("[SETUP] discovery failed \(e.errorCode)")
                    self.restartAfterError(b, reason: "failed")
                case .waiting(let e):
                    // Local network permission off reads as waiting with a policy error.
                    debugLog("[SETUP] discovery waiting \(e.errorCode)")
                    self.restartAfterError(b, reason: "waiting")
                @unknown default:
                    debugLog("[SETUP] discovery state unknown")
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            var drops: [String] = []
            let snapshot = results.compactMap { r -> (String, Data, String, NWEndpoint)? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                guard case let .bonjour(txt) = r.metadata else { drops.append("\(name): no TXT"); return nil }
                if txt[UserQrCrypto.txtRole] == UserQrCrypto.roleSource { return nil }
                guard txt[SetupProtocol.txtVersion] == String(SetupProtocol.version) else {
                    drops.append("\(name): version \(txt[SetupProtocol.txtVersion] ?? "none")"); return nil
                }
                guard let pk = txt[SetupProtocol.txtPk].flatMap(SetupCrypto.unb64), pk.count == 32 else {
                    drops.append("\(name): bad public key"); return nil
                }
                let shown = DeviceInfo.friendlyName(advertised: txt[SetupProtocol.txtName].flatMap { $0.isEmpty ? nil : $0 } ?? name)
                let kind = SetupProtocol.Kind.fromTxt(txt[SetupProtocol.txtKind])
                return (name, pk, shown + "\u{1F}" + kind.rawValue, r.endpoint)
            }
            // Every browse change is logged (names and kinds only) so a device that never
            // shows the offer can be told apart: not seen, dropped by validation, or unresolved.
            let seen = snapshot.map { "\($0.0) (\($0.2.split(separator: "\u{1F}").last ?? ""))" }
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                self.heard = true
                debugLog("[SETUP] browse adverts=\(results.count) valid=[\(seen.joined(separator: ", "))] dropped=[\(drops.joined(separator: ", "))]")
                self.apply(snapshot)
            }
        }
        browser = b
        b.start(queue: queue)
    }

    /// Restarts a browser that reported failed or waiting, sharing the silent-restart budget.
    private func restartAfterError(_ b: NWBrowser?, reason: String) {
        guard let b, browser === b, silentRestarts < 5 else { return }
        silentRestarts += 1
        debugLog("[SETUP] discovery restarted (\(reason)) attempt=\(silentRestarts)")
        restart()
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
        byService.removeAll()
        heard = false
        if !tvs.isEmpty { tvs = [] }
        debugLog("[SETUP] discovery stopped")
    }

    private func apply(_ snapshot: [(String, Data, String, NWEndpoint)]) {
        let live = Set(snapshot.map(\.0))
        // Gone adverts (the TV left the screen, expired, or was set up).
        for gone in byService.keys where !live.contains(gone) {
            if let t = byService.removeValue(forKey: gone) { debugLog("[SETUP] tv gone key=\(t.fingerprint)") }
        }
        for gone in resolving.keys where !live.contains(gone) {
            resolving.removeValue(forKey: gone)?.cancel()
        }
        for (service, pk, shownKind, endpoint) in snapshot {
            // This device's own receiver (Add Playlist open while the banner runs) is never offered.
            if pk == SetupReceiver.ownPk { continue }
            let shown = String(shownKind.split(separator: "\u{1F}", omittingEmptySubsequences: false).first ?? "")
            let kind = SetupProtocol.Kind.fromTxt(shownKind.split(separator: "\u{1F}").last.map(String.init))
            if let existing = byService[service], existing.pk == pk, existing.name == shown { continue }
            if let existing = byService[service], existing.pk != pk {
                // Key rotation: the stale target is dropped until the new one resolves.
                debugLog("[SETUP] tv key changed old=\(existing.fingerprint) new=\(SetupCrypto.keyFingerprint(pk))")
                byService.removeValue(forKey: service)
            }
            resolve(service: service, pk: pk, shown: shown, kind: kind, endpoint: endpoint)
        }
        publish()
    }

    private func resolve(service: String, pk: Data, shown: String, kind: SetupProtocol.Kind, endpoint: NWEndpoint) {
        resolving.removeValue(forKey: service)?.cancel()
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolving[service] = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            switch state {
            case .ready:
                let remote = c?.currentPath?.remoteEndpoint
                c?.cancel()
                guard case let .hostPort(host, port)? = remote else { return }
                let hostString: String
                switch host {
                case .ipv4(let a): hostString = "\(a)"
                case .ipv6(let a): hostString = "\(a)"
                case .name(let n, _): hostString = n
                @unknown default: return
                }
                let clean = hostString.split(separator: "%").first.map(String.init) ?? hostString
                let t = SetupTarget(name: shown, host: clean, port: Int(port.rawValue), pk: pk, serviceName: service, kind: kind)
                Task { @MainActor in self?.resolved(service: service, target: t) }
            case .failed(let e), .waiting(let e):
                c?.cancel()
                Task { @MainActor in
                    debugLog("[SETUP] resolve failed \(shown) (\(kind.rawValue)): \(e.errorCode)")
                    self?.resolving.removeValue(forKey: service)
                }
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func resolved(service: String, target: SetupTarget) {
        resolving.removeValue(forKey: service)
        guard browser != nil else { return }
        byService[service] = target
        debugLog("[SETUP] tv found key=\(target.fingerprint)")
        publish()
    }

    private func publish() {
        let next = byService.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        if next != tvs { tvs = next }
    }
}

extension SetupDiscovery {
    /// Resolves a discovered device again right before a send, so a device that
    /// started a new session (new port and key) is reached at its current
    /// advert. Waits up to `timeout` for the same instance name; keeps the old
    /// target when the device is not seen (a QR target is returned as is).
    static func fresh(_ t: SetupTarget, timeout: TimeInterval = 3) async -> SetupTarget {
        guard let service = t.serviceName else { return t }
        let d = SetupDiscovery()
        d.start()
        defer { d.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if var live = d.tvs.first(where: { $0.serviceName == service }) {
                live.code = t.code
                if live.pk != t.pk || live.port != t.port {
                    debugLog("[SETUP] send target refreshed old=\(t.fingerprint) new=\(live.fingerprint) port \(t.port) -> \(live.port)")
                } else {
                    debugLog("[SETUP] send target confirmed key=\(live.fingerprint)")
                }
                return live
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        debugLog("[SETUP] send target not re-resolved in \(Int(timeout)) s, using last advert key=\(t.fingerprint)")
        return t
    }
}

// MARK: - Shared offer (dock card + Settings banner)

/// One discovery, one gate, and one dismissal set for the dock card and the
/// Settings root banner, so both always show the same TV. Discovery runs
/// while the app is in the foreground.
@MainActor
final class SetupTvOfferCenter: ObservableObject {
    static let shared = SetupTvOfferCenter()

    let discovery = SetupDiscovery()
    @Published private(set) var tvs: [SetupTarget] = []
    /// TVs dismissed by name and key until the app restarts; a new key shows again.
    @Published private(set) var dismissed: Set<String> = []
    /// The TV whose setup sheet is open from the dock card or banner.
    @Published var presentedTarget: SetupTarget?
    /// A scanned or system-camera aeriotv://setup link waiting for the sheet.
    @Published var pendingLink: LinkBox?
    /// Set by the app root from the active playlist and the profile gate.
    @Published var canOffer = false

    struct LinkBox: Identifiable { let id = UUID(); let link: String }

    private var bag: AnyCancellable?

    private init() {
        bag = discovery.$tvs.sink { [weak self] list in self?.tvs = list }
    }

    func setForeground(_ active: Bool) {
        // A fresh browser on every return to the foreground.
        if active { discovery.restart() } else { discovery.stop() }
    }

    /// The TV on offer: the first advertising TV not dismissed, hidden while
    /// its setup sheet is open. Phones and tablets, Admin or default profile.
    var offer: SetupTarget? {
        guard canOffer, presentedTarget == nil, pendingLink == nil else { return nil }
        return tvs.first { !dismissed.contains($0.id) }
    }

    func dismiss(_ t: SetupTarget) {
        dismissed.insert(t.id)
        debugLog("[SETUP] offer dismissed key=\(t.fingerprint)")
    }

    /// A device that accepted the payload is never offered again under that key,
    /// even when its advert goodbye never reaches this browser. A new session
    /// (new key) shows again.
    func completed(_ t: SetupTarget) {
        dismissed.insert(t.id)
        if t.pk == lastLink?.pk { lastLinkSent = true }
        debugLog("[SETUP] offer cleared after send key=\(t.fingerprint)")
    }

    func setUp(_ t: SetupTarget) { presentedTarget = t }

    /// A link that arrived behind the launch PIN screen or during a profile
    /// switch. Opened afterwards only when the profile then active may set up
    /// another device.
    private var heldLink: String?

    /// The one-time session (code and key) of the last camera link, in memory
    /// only, so nothing outlives the process. The same link again is ignored
    /// while its sheet is open or held, or once its payload went out (the
    /// other device's session is used up); after Cancel a rescan opens it.
    private var lastLink: (code: String, pk: Data)?
    private var lastLinkSent = false

    /// Set by an open Set up sheet while its key check or send runs: a newer
    /// camera link is ignored then (Android parity), and replaces the
    /// pending device otherwise.
    var sheetBusy = false

    /// aeriotv://setup from the system camera. `allowed` is SetupGate.canSetUpTv
    /// for the active playlist: a profile that cannot set up another device
    /// (a Child) drops the link silently, as Android does. Never logs the link.
    func openLink(_ link: String, allowed: Bool, locked: Bool) {
        guard let parsed = SetupProtocol.parseLink(link) else {
            debugLog("[SETUP] link rejected")
            return
        }
        let same = lastLink.map { $0.code == parsed.code && $0.pk == parsed.pk } ?? false
        let action = SetupLinkRules.action(
            sameAsLast: same,
            lastStillLive: pendingLink != nil || heldLink != nil || lastLinkSent,
            sheetBusy: sheetBusy, locked: locked, allowed: allowed)
        switch action {
        case .ignoreSame:
            debugLog("[SETUP] same link again, ignored (\(lastLinkSent ? "already sent" : "already open"))")
            return
        case .ignoreBusy:
            debugLog("[SETUP] newer link ignored: a key check or send is under way")
            return
        case .hold, .drop, .open:
            break
        }
        lastLink = (parsed.code, parsed.pk)
        lastLinkSent = false
        switch action {
        case .hold:
            heldLink = link
            debugLog("[SETUP] link held until the app is unlocked and the profile settled")
        case .drop:
            debugLog("[SETUP] link dropped: this profile cannot set up another device")
        default:
            debugLog(pendingLink == nil ? "[SETUP] link opened" : "[SETUP] newer link replaced the pending device")
            pendingLink = LinkBox(link: link)
        }
    }

    /// Unlocked and settled: open a held link only for a profile that may set up another device.
    func unlocked(allowed: Bool) {
        guard let link = heldLink else { return }
        heldLink = nil
        guard allowed else {
            debugLog("[SETUP] held link dropped: this profile cannot set up another device")
            return
        }
        debugLog("[SETUP] held link opened after unlock")
        pendingLink = LinkBox(link: link)
    }
}

/// Who may send a TV this device's playlist: an Admin or Standard profile,
/// or the default profile (Android ProfileManager.canSetUpTv). Non-Dispatcharr
/// playlists have no profiles, so the device user is the default.
enum SetupGate {
    @MainActor
    static func canSetUpTv(_ server: ServerConnection?) -> Bool {
        guard let server else { return false }
        guard server.type == .dispatcharrAPI else { return true }
        let pid = server.id.uuidString
        let pm = ProfileManager.shared
        let active = pm.activeProfile(pid)
        return SetupProfileRules.canSetUpTv(activeRole: active?.effectiveRole.wire, activeIsDefault: active?.isDefault)
    }

    /// The launch PIN screen covers the app: nothing may be sent from behind it.
    @MainActor
    static var isLocked: Bool { ProfileManager.shared.launchGate != nil }

    /// Checked right before a payload leaves this device, on every send path
    /// (the Set up another device sheet, a system-camera link, a User QR
    /// source): unlocked, and the active profile may set up another device.
    @MainActor
    static func canSend(_ server: ServerConnection?) -> Bool {
        !isLocked && canSetUpTv(server)
    }
}

// MARK: - Payload and send

enum SetupSender {
    struct ProfileChoice: Identifiable, Equatable {
        let id: String
        let displayName: String
        let isDefault: Bool
        let isCurrent: Bool
        /// "API key saved", "Password saved", or nil when none is stored here.
        let credentialLabel: String?
    }

    struct Source {
        let playlistName: String
        let isDispatcharr: Bool
        let choices: [ProfileChoice]
        let syncOnHere: Bool
    }

    private static func wireType(_ t: ServerType) -> String {
        switch t {
        case .dispatcharrAPI: return "dispatcharr"
        case .xtreamCodes: return "xtream"
        case .m3uPlaylist: return "m3u"
        }
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    @MainActor
    static func source(_ server: ServerConnection) -> Source {
        let isD = server.type == .dispatcharrAPI
        var choices: [ProfileChoice] = []
        if isD {
            let sources = profileSources(server)
            let currentId = ProfileManager.shared.activeProfile(server.id.uuidString)?.id
            choices = sources.map { s in
                // The default profile signs in with the playlist login and is always sent.
                let label = s.isDefault
                    ? SetupProfileRules.credentialLabel(apiKey: server.baseApiKey, password: server.effectivePassword)
                    : SetupProfileRules.credentialLabel(apiKey: s.apiKey, password: s.password)
                return ProfileChoice(id: s.id, displayName: s.displayName, isDefault: s.isDefault,
                                     isCurrent: s.id == currentId || (currentId == nil && s.isDefault), credentialLabel: label)
            }
        }
        return Source(playlistName: server.name, isDispatcharr: isD, choices: choices,
                      syncOnHere: isD && DispatcharrSyncManager.shared.isEnabled)
    }

    private static func defaultDisplayName(_ s: ServerConnection) -> String {
        nonEmpty(s.username) ?? s.name
    }

    /// The playlist's local profiles in list order, with what this device
    /// stores for each (Android ProfileManager.setupSources). No profiles yet
    /// (the manager has not created the default): the default from the row.
    @MainActor
    private static func profileSources(_ server: ServerConnection) -> [SetupProfileRules.Source] {
        let pm = ProfileManager.shared
        let list = pm.profiles(server.id.uuidString)
        guard !list.isEmpty else {
            return [.init(id: "default", username: nonEmpty(server.username) ?? "", displayName: defaultDisplayName(server),
                          role: "", isDefault: true)]
        }
        return list.map { p in
            let pin = pm.pinStore.syncRecord(p.id)
            return SetupProfileRules.Source(
                id: p.id, username: p.username,
                displayName: p.displayName.isEmpty ? (p.isDefault ? defaultDisplayName(server) : p.username) : p.displayName,
                role: p.effectiveRole.wire,
                avatar: p.avatar.map { SetupProtocol.Avatar(icon: $0.icon, color: $0.color) },
                isDefault: p.isDefault,
                apiKey: p.isDefault ? nil : pm.store.apiKey(p.id),
                password: p.isDefault ? nil : pm.store.password(p.id),
                pinType: pin.map { PinRules.wireType($0.type) },
                pinHash: pin?.hash ?? "",
                pinSalt: pin?.salt ?? "")
        }
    }

    /// "Import this user only": the playlist signs in as the active profile, which
    /// goes out as the payload's one (default) profile. Wire format unchanged.
    /// The active profile when "Import this user only" needs a sign-in first: not
    /// the default (it uses the playlist login) and nothing saved here.
    @MainActor
    static func userOnlyMissingSignIn(_ server: ServerConnection) -> DispatcharrProfile? {
        guard server.type == .dispatcharrAPI else { return nil }
        let pm = ProfileManager.shared
        guard let p = pm.activeProfile(server.id.uuidString), !p.isDefault else { return nil }
        let has = (pm.store.apiKey(p.id) ?? "").isEmpty == false || (pm.store.password(p.id) ?? "").isEmpty == false
        return has ? nil : p
    }

    @MainActor
    static func buildUserOnlyPayload(_ server: ServerConnection, turnOnSync: Bool) -> SetupProtocol.Payload {
        var full = buildPayload(server, profileIds: [], turnOnSync: turnOnSync)
        guard server.type == .dispatcharrAPI else { return full }
        let sources = profileSources(server)
        let activeId = ProfileManager.shared.activeProfileIdNow(server.id.uuidString)
        guard let s = sources.first(where: { $0.id == activeId }) ?? sources.first(where: \.isDefault) else { return full }
        if !s.isDefault {
            let c = SetupProtocol.Credential(apiKey: s.apiKey.flatMap(nonEmpty), username: nonEmpty(s.username),
                                             password: s.password.flatMap(nonEmpty))
            if c.apiKey != nil || c.password != nil {
                full.playlist.credential = c
                // A different server account: not the same playlist, so not its id.
                full.playlist.id = nil
            }
        }
        var only = SetupProfileRules.parts([s], selected: [s.id]).first
            ?? SetupProtocol.ProfilePart(username: s.username, displayName: s.displayName, role: s.role, avatar: s.avatar, id: s.id)
        // A non-default profile imported alone is a different account: no ids at all.
        if !s.isDefault {
            full.playlist.id = nil
            only.id = nil
        }
        only.isDefault = true
        only.credential = nil
        only.order = 0
        full.profiles = [only]
        debugLog("[SETUP] payload user only, sync=\(turnOnSync)")
        return full
    }

    @MainActor
    static func buildPayload(_ server: ServerConnection, profileIds: Set<String>, turnOnSync: Bool) -> SetupProtocol.Payload {
        let type = wireType(server.type)
        let xmltv: String? = {
            switch server.type {
            case .m3uPlaylist: return nonEmpty(server.epgURL)
            case .xtreamCodes: return nonEmpty(server.xtreamXMLTVURL)
            case .dispatcharrAPI: return nonEmpty(server.dispatcharrXMLTVURL)
            }
        }()
        let cred = SetupProtocol.Credential(
            apiKey: server.type == .dispatcharrAPI ? nonEmpty(server.baseApiKey) : nil,
            username: server.type == .m3uPlaylist ? nil : nonEmpty(server.username),
            password: server.type == .m3uPlaylist ? nil : nonEmpty(server.effectivePassword))
        let playlist = SetupProtocol.PlaylistPart(
            type: type,
            name: server.name,
            url: server.baseURL,
            xmltvUrl: xmltv,
            localUrl: nonEmpty(server.localURL),
            userAgent: nonEmpty(server.customUserAgent),
            guideDays: server.epgRetentionDays,
            catchupOffsetMinutes: CatchupSupport.timeOffsetMinutes(serverID: server.id),
            vodEnabled: server.vodEnabled,
            channelProfileIds: server.type == .dispatcharrAPI ? server.dispatcharrProfileIDList : [],
            credential: cred.isEmpty ? nil : cred,
            // The receiver keeps this id: one playlist, one id on every device.
            id: server.id.uuidString)
        // Xtream Codes and M3U send the playlist only.
        guard server.type == .dispatcharrAPI else { return SetupProtocol.Payload(playlist: playlist) }
        // The default profile always, then the chosen profiles that carry a sign-in
        // (docs/DeviceSetupHandoff.md; Android SetupSender.buildPayload).
        let parts = SetupProfileRules.parts(profileSources(server), selected: profileIds)
        debugLog("[SETUP] payload profiles=\(parts.count) sync=\(turnOnSync)")
        return SetupProtocol.Payload(playlist: playlist, profiles: parts,
                                     sync: turnOnSync ? SetupProtocol.SyncPart() : nil)
    }

    enum SendResult: Equatable {
        case ok
        case wrongCode
        case refused
        case failed(String)
    }

    static let unreachableMessage = "The device could not be reached. Check that both devices are on the same network."

    /// POST the sealed envelope once. Never retried here: a wrong code spends
    /// one of the TV's three attempts, and a timeout after the body went out
    /// is ambiguous (the TV may have accepted), so it is reported as a
    /// failure and the user decides.
    static func send(_ target: SetupTarget, code: String, payload: SetupProtocol.Payload) async -> SendResult {
        let body: Data
        do {
            body = SetupProtocol.encodeEnvelope(try SetupProtocol.sealForTv(payload, tvPk: target.pk, code: code))
        } catch {
            debugLog("[SETUP] seal failed key=\(target.fingerprint)")
            return .failed("This playlist could not be read.")
        }
        guard body.count <= SetupProtocol.maxBodyBytes else {
            debugLog("[SETUP] body too large bytes=\(body.count)")
            return .failed("The setup is too large to send.")
        }
        let hostPart = target.host.contains(":") ? "[\(target.host)]" : target.host
        guard let url = URL(string: "http://\(hostPart):\(target.port)\(SetupProtocol.path)") else {
            return .failed(unreachableMessage)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        debugLog("[SETUP] send key=\(target.fingerprint) bytes=\(body.count)")
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let reply = try? JSONDecoder().decode(SetupProtocol.Reply.self, from: data)
            debugLog("[SETUP] send -> HTTP \(status) \(reply?.error ?? "")")
            switch (status, reply?.ok, reply?.error) {
            case (200, true?, _): return .ok
            case (403, _, "wrong_code"?): return .wrongCode
            case (403, _, _): return .refused
            default: return .failed("The device answered HTTP \(status).")
            }
        } catch let e as URLError where e.code == .timedOut {
            // Ambiguous: never claim success, never resend on our own.
            debugLog("[SETUP] send failed: timeout (outcome unknown)")
            return .failed(unreachableMessage)
        } catch let e as URLError {
            debugLog("[SETUP] send failed: URLError \(e.code.rawValue)")
            return .failed(unreachableMessage)
        } catch {
            debugLog("[SETUP] send failed: \(type(of: error))")
            return .failed(unreachableMessage)
        }
    }
}

// MARK: - Key check before a send (2026-11-09, Android db6aacb6)

/// The sender once handed over a key the server had already rejected, and
/// the other device failed with HTTP 429 (the server's failed-key throttle,
/// tripped by the retries) and then 401. Before a Dispatcharr payload with
/// an API key goes out, one authenticated GET of /api/accounts/users/me/
/// with exactly that key, to the sender's effective base URL (LAN when
/// reachable). 401/403, or a key the local gate already holds: nothing is
/// sent. A 429 counts down its Retry-After; a network error waits 3 s; up
/// to two re-checks, then the send goes ahead (the receiver has its own 429
/// retry).
enum SetupKeySender {
    @MainActor
    static func check(key: String, server: ServerConnection,
                      onCountdown: (_ secondsLeft: Int, _ rateLimit: RateLimitReason?) -> Void) async -> SetupKeyVerdict {
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL, auth: .apiKey(key),
                                 userAgent: server.effectiveUserAgent, authMode: server.dispatcharrHeaderMode)
        let verdict = await SetupKeyPreflight.run(check: { await api.checkSetupKey() }, onCountdown: onCountdown)
        debugLog("[SETUP] key check before send: \(verdict == .send ? "send" : "rejected, nothing sent")")
        return verdict
    }
}

// MARK: - User QR source (the device showing a User QR Code)

/// While "Show User QR Code" is on screen this device advertises itself as a
/// setup source (`role=source`, `uq`) and answers `POST /user-qr` from a device
/// that scanned the code. The request holds open until the user taps Send or
/// Don't send here (120 s limit); Send runs the normal setup send to the
/// scanner's one-time link. docs/DeviceSetupHandoff.md.
@MainActor
final class UserQrSource: ObservableObject {
    enum Phase: Equatable {
        case idle
        case confirm(String)
        case sending(String)
        case sent(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var apiKey = ""
    private var playlistId = ""
    private var listener: NWListener?
    private var pending: (conn: NWConnection, link: SetupProtocol.Link)?
    private var timeout: Task<Void, Never>?
    private let queue = DispatchQueue(label: "aerio.userqr.source")

    func start(apiKey: String, playlistId: String) {
        guard listener == nil, !apiKey.isEmpty else { return }
        self.apiKey = apiKey
        self.playlistId = playlistId
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: .any) else {
            debugLog("[SETUP] user QR source: listener create failed")
            return
        }
        var txt = NWTXTRecord()
        txt[SetupProtocol.txtVersion] = String(SetupProtocol.version)
        txt[SetupProtocol.txtName] = SetupReceiver.deviceName
        txt[SetupProtocol.txtKind] = SetupReceiver.deviceKind.rawValue
        txt[UserQrCrypto.txtRole] = UserQrCrypto.roleSource
        txt[UserQrCrypto.txtUq] = UserQrCrypto.uq(apiKey: apiKey)
        l.service = NWListener.Service(name: SetupReceiver.deviceName, type: SetupProtocol.serviceType, domain: nil, txtRecord: txt)
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: Task { @MainActor in debugLog("[SETUP] user QR source: listener ready") }
            case .waiting(let e): Task { @MainActor in debugLog("[SETUP] user QR source: listener waiting \(e.errorCode)") }
            case .failed(let e): Task { @MainActor in debugLog("[SETUP] user QR source failed \(e.errorCode)") }
            default: break
            }
        }
        l.serviceRegistrationUpdateHandler = { change in
            switch change {
            case .add: Task { @MainActor in debugLog("[SETUP] user QR source: advert registered") }
            case .remove: Task { @MainActor in debugLog("[SETUP] user QR source: advert removed") }
            @unknown default: break
            }
        }
        listener = l
        l.start(queue: queue)
        debugLog("[SETUP] user QR source: advertising")
    }

    func stop() {
        decline()
        listener?.cancel()
        listener = nil
        apiKey = ""
        phase = .idle
    }

    /// Don't send (or the screen closed, or 120 s passed).
    func decline() {
        timeout?.cancel()
        if let p = pending {
            pending = nil
            debugLog("[SETUP] user QR source: declined")
            Self.reply(p.conn, 403, "declined")
        }
        if case .confirm = phase { phase = .idle }
    }

    func send() {
        guard let p = pending, case .confirm(let name) = phase else { return }
        // Same gate as Set up another device: unlocked, and a profile that may send.
        guard SetupGate.canSend(DsyncLocal.server(playlistId)) else {
            debugLog("[SETUP] user QR source: send blocked for this profile")
            decline()
            return
        }
        timeout?.cancel()
        phase = .sending(name)
        Task {
            /// nil: blocked by the profile gate, answered like Don't send.
            let result: SetupSender.SendResult?
            if let server = DsyncLocal.server(playlistId) {
                let source = SetupSender.source(server)
                let ids = Set(source.choices.filter { !$0.isDefault && $0.credentialLabel != nil }.map(\.id))
                let payload = SetupSender.buildPayload(server, profileIds: ids, turnOnSync: source.syncOnHere)
                // Same key check as the Set up another device sheet: never
                // hand over a key the server refuses.
                if payload.playlist.type == "dispatcharr", let key = payload.playlist.credential?.apiKey,
                   await SetupKeySender.check(key: key, server: server, onCountdown: { _, _ in }) == .rejected {
                    result = .failed(DispatcharrRateLimitCopy.setupKeyRejectedMessage)
                } else if !SetupGate.canSend(server) {
                    // The profile changed or the app locked during the key check.
                    debugLog("[SETUP] user QR source: send blocked for this profile")
                    result = nil
                } else {
                    result = await SetupSender.send(SetupTarget.fromLink(p.link), code: p.link.code, payload: payload)
                }
            } else {
                result = .failed("This playlist could not be read.")
            }
            guard pending?.conn === p.conn else { return }
            pending = nil
            guard let result else {
                Self.reply(p.conn, 403, "declined")
                phase = .idle
                return
            }
            switch result {
            case .ok:
                Self.reply(p.conn, 200, nil)
                phase = .sent(name)
            case .wrongCode:
                Self.reply(p.conn, 502, "send_failed")
                phase = .failed("The device did not accept that code. Check the code on the device and try again.")
            case .refused:
                Self.reply(p.conn, 502, "send_failed")
                phase = .failed("The device is no longer waiting for setup. Start setup on the other device again.")
            case .failed(let m):
                Self.reply(p.conn, 502, "send_failed")
                phase = .failed(m)
            }
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        SetupReceiver.readRequest(c, buffer: Data()) { [weak self] req in
            Task { @MainActor in self?.handle(c, req) }
        }
    }

    private func handle(_ c: NWConnection, _ req: SetupReceiver.Request?) {
        guard let req else { Self.reply(c, 400, "bad_request"); return }
        guard req.method == "POST", req.path.split(separator: "?").first.map(String.init) == UserQrCrypto.path else {
            Self.reply(c, 404, "bad_request"); return
        }
        if req.headers["origin"] != nil { Self.reply(c, 403, "forbidden"); return }
        if req.tooLarge || req.body.count > UserQrCrypto.maxBodyBytes { Self.reply(c, 413, "too_large"); return }
        guard let r = try? JSONDecoder().decode(UserQrCrypto.Request.self, from: req.body), r.v == 1,
              let link = SetupProtocol.parseLink(r.link) else { Self.reply(c, 400, "bad_request"); return }
        guard !apiKey.isEmpty, UserQrCrypto.verify(apiKey: apiKey, link: r.link, proof: r.proof) else {
            debugLog("[SETUP] user QR source: proof rejected")
            Self.reply(c, 403, "forbidden"); return
        }
        if pending != nil { Self.reply(c, 409, "busy"); return }
        guard SetupGate.canSetUpTv(DsyncLocal.server(playlistId)) else { Self.reply(c, 403, "not_allowed"); return }
        let name = link.name.isEmpty ? "AerioTV" : link.name
        pending = (c, link)
        phase = .confirm(name)
        debugLog("[SETUP] user QR source: request waiting for Send key=\(SetupCrypto.keyFingerprint(link.pk))")
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { self?.decline() }
        }
    }

    nonisolated private static func reply(_ c: NWConnection, _ status: Int, _ error: String?) {
        let body = error.map { "{\"ok\":false,\"error\":\"\($0)\"}" } ?? "{\"ok\":true}"
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                      413: "Payload Too Large", 502: "Bad Gateway"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}

#endif

// MARK: - User QR request (the device that scanned a User QR Code)

/// The device showing the scanned code, found on the LAN.
struct UserQrSourceDevice: Equatable, Sendable {
    let name: String
    let host: String
    let port: Int
}

/// What the scanner hands the receive screen for "Copy entire setup from this device".
struct UserQrSourceRequest: Identifiable, Equatable {
    let id = UUID()
    let device: UserQrSourceDevice
    let apiKey: String
    let userKey: ScannedCode.UserKey
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

enum UserQrRequest {
    static let unreachableMessage = "The device could not be reached. Check that both devices are on the same network."
    enum Outcome: Equatable { case ok, declined, network }

    /// Browses up to `seconds` for the source advertising this key's `uq`.
    @MainActor
    static func find(apiKey: String, seconds: Double = 3) async -> UserQrSourceDevice? {
        let want = UserQrCrypto.uq(apiKey: apiKey)
        let queue = DispatchQueue(label: "aerio.userqr.find")
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SetupProtocol.serviceType, domain: nil), using: params)
        let stats = FindStats()
        let found: UserQrSourceDevice? = await withCheckedContinuation { cont in
            let once = FindOnce(cont)
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let e): stats.note("browser failed \(e.errorCode)")
                case .waiting(let e): stats.note("browser waiting \(e.errorCode)")
                default: break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                stats.adverts = results.count
                for r in results {
                    guard case .bonjour(let txt) = r.metadata, txt[UserQrCrypto.txtRole] == UserQrCrypto.roleSource else { continue }
                    stats.sources += 1
                    guard txt[UserQrCrypto.txtUq] == want, txt[SetupProtocol.txtVersion] == String(SetupProtocol.version) else {
                        stats.mismatched += 1
                        continue
                    }
                    var named = txt[SetupProtocol.txtName] ?? ""
                    if named.isEmpty, case let .service(n, _, _, _) = r.endpoint { named = n }
                    resolve(r.endpoint, name: named.isEmpty ? "AerioTV" : DeviceInfo.friendlyName(advertised: named), v4Only: true, queue: queue, once: once, stats: stats)
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) { once.finish(nil) }
        }
        browser.cancel()
        // Counts only: never the key, the uq, or an address.
        debugLog(found == nil
                 ? "[SETUP] user QR: no source on the LAN (adverts=\(stats.adverts) sources=\(stats.sources) other codes=\(stats.mismatched) resolves=\(stats.resolves) \(stats.notes))"
                 : "[SETUP] user QR: source found (resolves=\(stats.resolves))")
        return found
    }

    /// Endpoint to host and port through a short connection. A refused or waiting
    /// attempt (the advert can lead the listener, or IPv4 is not up yet) retries
    /// every 250 ms, alternating IPv4 only and any family, until the probe ends.
    nonisolated private static func resolve(_ endpoint: NWEndpoint, name: String, v4Only: Bool, queue: DispatchQueue,
                                            once: FindOnce, stats: FindStats) {
        guard !once.isDone else { return }
        stats.resolves += 1
        let tcp = NWParameters.tcp
        if v4Only, let ip = tcp.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: tcp)
        c.stateUpdateHandler = { [weak c] state in
            switch state {
            case .ready:
                let remote = c?.currentPath?.remoteEndpoint
                c?.cancel()
                guard case let .hostPort(host, port)? = remote else { return }
                var h: String
                switch host {
                case .ipv4(let a): h = "\(a)"
                case .ipv6(let a): h = "\(a)"
                case .name(let n, _): h = n
                @unknown default: return
                }
                h = h.split(separator: "%").first.map(String.init) ?? h
                once.finish(UserQrSourceDevice(name: name, host: h, port: Int(port.rawValue)))
            case .failed(let e), .waiting(let e):
                c?.stateUpdateHandler = nil
                c?.cancel()
                stats.note("resolve \(e.errorCode)")
                queue.asyncAfter(deadline: .now() + 0.25) {
                    resolve(endpoint, name: name, v4Only: !v4Only, queue: queue, once: once, stats: stats)
                }
            default: break
            }
        }
        c.start(queue: queue)
    }

    /// POST the receiver link with proof; waits for Send or Don't send on the other device.
    static func ask(_ d: UserQrSourceDevice, link: String, apiKey: String) async -> Outcome {
        let hostPart = d.host.contains(":") ? "[\(d.host)]" : d.host
        guard let url = URL(string: "http://\(hostPart):\(d.port)\(UserQrCrypto.path)") else { return .network }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 150)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(UserQrCrypto.Request(link: link, proof: UserQrCrypto.proof(apiKey: apiKey, link: link)))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 150
        cfg.timeoutIntervalForResource = 160
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let reply = try? JSONDecoder().decode(SetupProtocol.Reply.self, from: data)
            debugLog("[SETUP] user QR request -> HTTP \(status) \(reply?.error ?? "")")
            return status == 200 && reply?.ok == true ? .ok : .declined
        } catch {
            debugLog("[SETUP] user QR request failed: \(type(of: error))")
            return .network
        }
    }
}

/// Probe counters for the log (touched only on the probe's serial queue).
private final class FindStats: @unchecked Sendable {
    var adverts = 0, sources = 0, mismatched = 0, resolves = 0
    private(set) var notes = ""
    func note(_ s: String) { if !notes.contains(s) { notes += (notes.isEmpty ? "" : ", ") + s } }
}

private final class FindOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<UserQrSourceDevice?, Never>?
    init(_ c: CheckedContinuation<UserQrSourceDevice?, Never>) { cont = c }
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return cont == nil }
    func finish(_ v: UserQrSourceDevice?) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: v)
    }
}

// MARK: - QR sign-in hand-off

/// Hand-off from the Dispatcharr connect form to the step after it, in
/// memory only (Android QrImportBus): the last sign-in made from a user QR,
/// so the next step can ask the server for existing AerioTV sync data.
enum QrImportBus {
    struct SignIn: Identifiable, CustomStringConvertible {
        let id = UUID()
        let apiKey: String
        let baseUrl: String
        let username: String?
        var description: String { "SignIn(username: \(username != nil), apiKey: <redacted>)" }
    }

    @MainActor private static var last: SignIn?

    @MainActor static func noteSignIn(_ s: SignIn) { last = s }

    /// Taken once; only a match on the key the playlist actually saved counts.
    @MainActor static func takeSignIn(savedApiKey: String?) -> SignIn? {
        let s = last
        last = nil
        guard let s, let k = savedApiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty, s.apiKey == k else { return nil }
        return s
    }

    /// Does this user already have AerioTV sync data on the server? One call
    /// to the App Data list with the scanned key; any failure counts as none.
    static func serverHasData(_ s: SignIn) async -> Bool {
        let api = DispatcharrAPI(baseURL: s.baseUrl, auth: .apiKey(s.apiKey))
        let r = await DispatcharrAppDataClient(api: api).appDataList()
        let found = r?.ok == true && DsyncRestoreProbe.listsMainKey(r?.body)
        debugLog(found ? "[DSYNC] server data found, offering restore" : "[DSYNC] server data none")
        return found
    }
}
