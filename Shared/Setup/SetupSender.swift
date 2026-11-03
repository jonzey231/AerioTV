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
#if os(iOS)
import Network
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

/// Second line of the dock card and the Settings banner.
func setupWaitingLine(_ t: SetupTarget) -> String { "Waiting for setup, key \(t.fingerprint)" }

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

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: SetupProtocol.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { state in
            if case .failed(let e) = state {
                Task { @MainActor in debugLog("[SETUP] discovery failed \(e.errorCode)") }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let snapshot = results.compactMap { r -> (String, Data, String, NWEndpoint)? in
                guard case let .service(name, _, _, _) = r.endpoint,
                      case let .bonjour(txt) = r.metadata else { return nil }
                guard txt[SetupProtocol.txtVersion] == String(SetupProtocol.version),
                      let pk = txt[SetupProtocol.txtPk].flatMap(SetupCrypto.unb64), pk.count == 32 else { return nil }
                let shown = txt[SetupProtocol.txtName].flatMap { $0.isEmpty ? nil : $0 } ?? name
                let kind = SetupProtocol.Kind.fromTxt(txt[SetupProtocol.txtKind])
                return (name, pk, shown + "\u{1F}" + kind.rawValue, r.endpoint)
            }
            Task { @MainActor in self?.apply(snapshot) }
        }
        browser = b
        b.start(queue: queue)
        debugLog("[SETUP] discovery started")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
        byService.removeAll()
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
            case .failed, .waiting:
                c?.cancel()
                Task { @MainActor in self?.resolving.removeValue(forKey: service) }
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
        if active { discovery.start() } else { discovery.stop() }
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

    func setUp(_ t: SetupTarget) { presentedTarget = t }

    /// aeriotv://setup from the system camera or a scan outside Set up a TV.
    func openLink(_ link: String) {
        guard SetupProtocol.parseLink(link) != nil else {
            debugLog("[SETUP] link rejected")
            return
        }
        debugLog("[SETUP] link opened")
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
            if c.apiKey != nil || c.password != nil { full.playlist.credential = c }
        }
        var only = SetupProfileRules.parts([s], selected: [s.id]).first
            ?? SetupProtocol.ProfilePart(username: s.username, displayName: s.displayName, role: s.role, avatar: s.avatar)
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
            credential: cred.isEmpty ? nil : cred)
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

#endif

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
