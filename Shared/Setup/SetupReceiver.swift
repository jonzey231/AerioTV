//  SetupReceiver.swift
//  Aerio
//
//  Receiving side of "Set up from another device" (docs/DeviceSetupHandoff.md;
//  port of Android core/setup/SetupReceiver.kt). Every platform receives:
//  iPhone, iPad, and Apple TV. One NWListener on an ephemeral port serves
//  POST /setup (HTTP/1.1, one request per connection) and advertises
//  `_aeriotv-setup._tcp` with TXT v, name, pk, and kind. Exactly one sealed
//  payload is accepted per code.
//
//  Logs never carry the code, a key, the payload, or the QR text: only the
//  port, counts, HTTP status, and error kinds.

import Foundation
import Network
import CryptoKit
import Darwin
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SetupReceiver: ObservableObject {
    struct Offer: Equatable {
        let code: String
        let link: String
        let deviceName: String
        let ip: String
        let port: Int
        let fingerprint: String
    }

    @Published private(set) var offer: Offer?

    /// The public key this device is advertising, so its own sender never lists it.
    static var ownPk: Data?

    /// Called on the main actor with a verified payload.
    var onPayload: ((SetupProtocol.Payload) -> Void)?

    private var keys = Curve25519.KeyAgreement.PrivateKey()
    private var code = SetupCrypto.newCode()
    private var failures = 0
    private var used = false
    private var listener: NWListener?
    private var ip: String?
    private var port = 0
    private let queue = DispatchQueue(label: "aerio.setup.receiver")
    private var advertise = true

    /// This device's form factor for the TXT `kind` key.
    static var deviceKind: SetupProtocol.Kind {
        #if os(tvOS)
        return .tv
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return .tablet }
        return UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        #endif
    }

    static var deviceName: String { String(DeviceInfo.deviceNickname.prefix(60)) }

    /// Returns false when the device has no LAN address or the bind failed.
    /// `advertise` false skips the Bonjour advert (a User QR request hands the link over directly).
    func start(advertise: Bool = true) async -> Bool {
        guard listener == nil else { return true }
        guard let lan = Self.lanIPv4() else {
            debugLog("[SETUP] receiver: no LAN IPv4; cannot offer setup")
            return false
        }
        ip = lan
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: .any) else {
            debugLog("[SETUP] receiver: listener create failed")
            return false
        }
        self.advertise = advertise
        if advertise { l.service = service() }
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in self?.accept(c) }
        }
        let ready: Bool = await withCheckedContinuation { cont in
            let once = ResumeOnce()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { cont.resume(returning: true) }
                case .failed(let e):
                    debugLog("[SETUP] receiver: listener failed \(e.errorCode)")
                    if once.take() { cont.resume(returning: false) }
                case .cancelled:
                    if once.take() { cont.resume(returning: false) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        guard ready, let p = l.port?.rawValue else { l.cancel(); return false }
        listener = l
        port = Int(p)
        debugLog("[SETUP] receiver: listening port=\(port) kind=\(Self.deviceKind.rawValue)")
        publish()
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        offer = nil
        Self.ownPk = nil
    }

    /// New code and key pair (after 3 failures).
    func regenerate() {
        keys = Curve25519.KeyAgreement.PrivateKey()
        code = SetupCrypto.newCode()
        failures = 0
        used = false
        if advertise { listener?.service = service() }
        publish()
        debugLog("[SETUP] receiver: new code and key")
    }

    private func service() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt[SetupProtocol.txtVersion] = String(SetupProtocol.version)
        txt[SetupProtocol.txtName] = Self.deviceName
        txt[SetupProtocol.txtPk] = SetupCrypto.b64(keys.publicKey.rawRepresentation)
        txt[SetupProtocol.txtKind] = Self.deviceKind.rawValue
        return NWListener.Service(name: Self.deviceName, type: SetupProtocol.serviceType, domain: nil, txtRecord: txt)
    }

    private func publish() {
        guard let ip else { return }
        let pk = keys.publicKey.rawRepresentation
        let name = Self.deviceName
        Self.ownPk = pk
        offer = Offer(code: code, link: SetupProtocol.buildLink(ip: ip, port: port, code: code, pk: pk, name: name),
                      deviceName: name, ip: ip, port: port, fingerprint: SetupCrypto.keyFingerprint(pk))
    }

    /// First up, non-loopback, non-link-local IPv4 on an `en` interface (Wi-Fi or Ethernet), en0 preferred.
    nonisolated static func lanIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !ip.hasPrefix("169.254.") else { continue }
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    // MARK: HTTP

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        Self.readRequest(c, buffer: Data()) { [weak self] req in
            Task { @MainActor in self?.handle(c, req) }
        }
    }

    struct Request {
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var body = Data()
        var tooLarge = false
    }

    nonisolated static let headerEnd = Data("\r\n\r\n".utf8)

    /// Reads headers, then Content-Length bytes of body (capped at 256 KB).
    nonisolated static func readRequest(_ c: NWConnection, buffer: Data, done: @escaping (Request?) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: headerEnd) {
                guard var req = parseHead(buf.subdata(in: 0..<r.lowerBound)) else { done(nil); return }
                let len = Int(req.headers["content-length"] ?? "") ?? 0
                if len > SetupProtocol.maxBodyBytes { req.tooLarge = true; done(req); return }
                let have = buf.count - r.upperBound
                if have >= len {
                    req.body = buf.subdata(in: r.upperBound..<(r.upperBound + len))
                    done(req)
                    return
                }
                if complete || error != nil { done(nil); return }
                readRequest(c, buffer: buf, done: done)
                return
            }
            if buf.count > 32 * 1024 || complete || error != nil { done(nil); return }
            readRequest(c, buffer: buf, done: done)
        }
    }

    nonisolated static func parseHead(_ d: Data) -> Request? {
        guard let text = String(data: d, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var r = Request(method: String(parts[0]), path: String(parts[1]))
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            r.headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return r
    }

    private func handle(_ c: NWConnection, _ req: Request?) {
        guard let req else { reply(c, 400, "bad_request"); return }
        guard req.method == "POST", req.path.split(separator: "?").first.map(String.init) == SetupProtocol.path else {
            reply(c, 404, "bad_request"); return
        }
        // Browsers always send Origin on a cross-site POST; the AerioTV sender never does.
        if req.headers["origin"] != nil || used { reply(c, 403, "forbidden"); return }
        if req.tooLarge { reply(c, 413, "too_large"); return }
        switch SetupProtocol.openOnTv(req.body, tv: keys, code: code) {
        case .ok(let payload):
            used = true
            debugLog("[SETUP] receiver: payload accepted (\(payload.playlist.type), \(payload.profiles.count) profiles, sync=\(payload.sync?.enabled == true))")
            reply(c, 200, nil)
            listener?.service = nil
            onPayload?(payload)
        case .wrongCode:
            failures += 1
            debugLog("[SETUP] receiver: wrong code (\(failures) of \(SetupProtocol.maxFailures))")
            reply(c, 403, "wrong_code")
            if failures >= SetupProtocol.maxFailures { regenerate() }
        case .badRequest:
            reply(c, 400, "bad_request")
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ error: String?) {
        let body = error.map { "{\"ok\":false,\"error\":\"\($0)\"}" } ?? "{\"ok\":true}"
        let reason: String = {
            switch status {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 413: return "Payload Too Large"
            default: return "Error"
            }
        }()
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        if status != 200 { debugLog("[SETUP] receiver: reply \(status)") }
        c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}

/// One-shot guard for the listener's ready continuation (its handler runs on one serial queue).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
