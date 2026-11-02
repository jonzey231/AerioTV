//  SetupProtocol.swift
//  Aerio
//
//  "Set up a TV from your phone" wire format, version 1, and the one parser
//  for the codes AerioTV reads (the Dispatcharr user QR and the
//  aeriotv://setup link). The contract is docs/DeviceSetupHandoff.md,
//  identical in the Android repo; this is the port of Android
//  core/setup/SetupProtocol.kt, SetupCrypto.kt and core/qr/ScannedCode.kt,
//  CodeTextImport.kt, DsyncRestoreProbe.kt.
//
//  Pure logic (Foundation, CryptoKit, Security only, no app singletons) so
//  Scripts/setup-tests compiles it with swiftc and runs the vectors. Never
//  log a key, code, payload, or link from here.

import Foundation
import CryptoKit
import Security

// MARK: - Crypto

enum SetupCrypto {
    static let infoPrefix = "aeriotv-setup-v1"
    static let nonceBytes = 12
    static let tagBytes = 16

    enum Failure: Error { case badKey, zeroSharedSecret, sealFailed }

    /// `count` bytes from the system CSPRNG.
    static func randomBytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }

    /// A fresh 6-digit code, zero padded (receiver side; the next phase uses it).
    static func newCode() -> String {
        // Rejection sampling keeps the distribution uniform.
        let limit = UInt32.max - (UInt32.max % 1_000_000)
        while true {
            let v = randomBytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if v < limit { return String(format: "%06u", v % 1_000_000) }
        }
    }

    /// 32 symbols with no 0/O or 1/I lookalikes.
    private static let fingerprintAlphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    /// "Key XXXX" characters: the first 20 bits of SHA-256(pk), 5 bits at a
    /// time, most significant first.
    static func keyFingerprint(_ pk: Data) -> String {
        let d = Array(SHA256.hash(data: pk))
        let bits = (Int(d[0]) << 12) | (Int(d[1]) << 4) | (Int(d[2]) >> 4)
        return String((0..<4).map { fingerprintAlphabet[(bits >> (15 - 5 * $0)) & 0x1f] })
    }

    /// HKDF-SHA256 over X25519(own priv, peer pub); salt = the six ASCII
    /// digits, info = "aeriotv-setup-v1" || phonePk || tvPk, 32 bytes.
    static func deriveKey(own: Curve25519.KeyAgreement.PrivateKey, peerPublic: Data, code: String,
                          phonePk: Data, tvPk: Data) throws -> SymmetricKey {
        guard peerPublic.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic) else { throw Failure.badKey }
        let shared: SharedSecret
        do { shared = try own.sharedSecretFromKeyAgreement(with: peer) } catch { throw Failure.zeroSharedSecret }
        let isZero = shared.withUnsafeBytes { raw in raw.allSatisfy { $0 == 0 } }
        if isZero { throw Failure.zeroSharedSecret }
        var info = Data(infoPrefix.utf8)
        info.append(phonePk)
        info.append(tvPk)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8), sharedInfo: info, outputByteCount: 32)
    }

    /// AES-256-GCM, no AAD. Returns the nonce and ciphertext || 16-byte tag.
    static func seal(key: SymmetricKey, plaintext: Data, nonce: Data? = nil) throws -> (nonce: Data, ciphertext: Data) {
        let n = nonce ?? randomBytes(nonceBytes)
        guard let gcmNonce = try? AES.GCM.Nonce(data: n),
              let box = try? AES.GCM.seal(plaintext, using: key, nonce: gcmNonce) else { throw Failure.sealFailed }
        return (n, box.ciphertext + box.tag)
    }

    /// Nil when the tag does not verify (wrong code, wrong key, or tampering).
    static func open(key: SymmetricKey, nonce: Data, ciphertext: Data) -> Data? {
        guard nonce.count == nonceBytes, ciphertext.count > tagBytes,
              let n = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.SealedBox(nonce: n, ciphertext: ciphertext.dropLast(tagBytes),
                                               tag: ciphertext.suffix(tagBytes)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func b64(_ d: Data) -> String { d.base64EncodedString() }

    static func b64Url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Standard or URL-safe base64, padded or not.
    static func unb64(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.hasSuffix("=") { t.removeLast() }
        if t.count % 4 == 1 { return nil }
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }
}

// MARK: - Wire format

enum SetupProtocol {
    static let version = 1
    static let serviceType = "_aeriotv-setup._tcp"
    static let path = "/setup"
    static let txtVersion = "v"
    static let txtName = "name"
    static let txtPk = "pk"
    static let windowSeconds: TimeInterval = 10 * 60
    static let maxFailures = 3
    /// Encoded POST body limit (the TV answers 413 above it).
    static let maxBodyBytes = 256 * 1024

    // MARK: QR / deep link

    struct Link: Equatable, Sendable {
        let ip: String
        let port: Int
        let code: String
        let pk: Data
        let name: String
    }

    static func buildLink(ip: String, port: Int, code: String, pk: Data, name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let n = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "aeriotv://setup?v=\(version)&ip=\(ip)&port=\(port)&code=\(code)&pk=\(SetupCrypto.b64Url(pk))&name=\(n)"
    }

    static func parseLink(_ raw: String) -> Link? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text),
              comps.scheme?.lowercased() == "aeriotv",
              comps.host?.lowercased() == "setup" else { return nil }
        // Query values: '+' is a space (as Android's URLDecoder), then percent decoding.
        var q: [String: String] = [:]
        for part in (comps.percentEncodedQuery ?? "").split(separator: "&") {
            guard let i = part.firstIndex(of: "="), i != part.startIndex else { continue }
            let k = String(part[..<i])
            let v = String(part[part.index(after: i)...]).replacingOccurrences(of: "+", with: " ")
            q[k] = v.removingPercentEncoding ?? v
        }
        guard Int(q["v"] ?? "") == version else { return nil }
        guard let code = q["code"], code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // A standard base64 '+' arrives as a space after the decode above.
        guard let pk = q["pk"].flatMap({ SetupCrypto.unb64($0.replacingOccurrences(of: " ", with: "+")) }), pk.count == 32 else { return nil }
        guard let port = Int(q["port"] ?? ""), (1...65535).contains(port) else { return nil }
        guard let ip = q["ip"]?.trimmingCharacters(in: .whitespaces), !ip.isEmpty else { return nil }
        return Link(ip: ip, port: port, code: code, pk: pk, name: q["name"] ?? "")
    }

    // MARK: Envelope (the POST body)

    struct Envelope: Codable, Equatable, Sendable {
        var v: Int = SetupProtocol.version
        let phonePk: String
        let nonce: String
        let ciphertext: String
    }

    struct Reply: Codable, Sendable {
        let ok: Bool
        var error: String? = nil
    }

    // MARK: Payload (the plaintext)

    struct Credential: Codable, Equatable, Sendable {
        var apiKey: String? = nil
        var username: String? = nil
        var password: String? = nil
        var isEmpty: Bool { apiKey == nil && username == nil && password == nil }
    }

    struct Avatar: Codable, Equatable, Sendable {
        var icon: String = "initial"
        var color: String = ""
        init(icon: String = "initial", color: String = "") { self.icon = icon; self.color = color }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "initial"
            color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        }
    }

    struct PlaylistPart: Codable, Equatable, Sendable {
        /// "dispatcharr", "xtream", or "m3u".
        var type: String
        var name: String
        var url: String
        var xmltvUrl: String? = nil
        var localUrl: String? = nil
        var userAgent: String? = nil
        var guideDays: Int = 7
        var catchupOffsetMinutes: Int = 0
        var vodEnabled: Bool = true
        var channelProfileIds: [Int] = []
        /// The playlist's own sign-in (the default profile on Dispatcharr; the XC login).
        var credential: Credential? = nil

        init(type: String, name: String, url: String, xmltvUrl: String? = nil, localUrl: String? = nil,
             userAgent: String? = nil, guideDays: Int = 7, catchupOffsetMinutes: Int = 0, vodEnabled: Bool = true,
             channelProfileIds: [Int] = [], credential: Credential? = nil) {
            self.type = type; self.name = name; self.url = url; self.xmltvUrl = xmltvUrl; self.localUrl = localUrl
            self.userAgent = userAgent; self.guideDays = guideDays; self.catchupOffsetMinutes = catchupOffsetMinutes
            self.vodEnabled = vodEnabled; self.channelProfileIds = channelProfileIds; self.credential = credential
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            name = try c.decode(String.self, forKey: .name)
            url = try c.decode(String.self, forKey: .url)
            xmltvUrl = try c.decodeIfPresent(String.self, forKey: .xmltvUrl)
            localUrl = try c.decodeIfPresent(String.self, forKey: .localUrl)
            userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
            guideDays = try c.decodeIfPresent(Int.self, forKey: .guideDays) ?? 7
            catchupOffsetMinutes = try c.decodeIfPresent(Int.self, forKey: .catchupOffsetMinutes) ?? 0
            vodEnabled = try c.decodeIfPresent(Bool.self, forKey: .vodEnabled) ?? true
            channelProfileIds = try c.decodeIfPresent([Int].self, forKey: .channelProfileIds) ?? []
            credential = try c.decodeIfPresent(Credential.self, forKey: .credential)
        }
    }

    struct ProfilePart: Codable, Equatable, Sendable {
        var username: String
        var displayName: String
        /// "admin", "user", or "child"; "" keeps the server-level default.
        var role: String = ""
        var avatar: Avatar? = nil
        var order: Int = -1
        /// True for the profile that signs in with the playlist credential.
        var isDefault: Bool = false
        /// Absent on the default profile (it uses playlist.credential).
        var credential: Credential? = nil
        /// "numbers", "directions", or "none".
        var pinType: String = "none"
        var pinHash: String = ""
        var pinSalt: String = ""

        init(username: String, displayName: String, role: String = "", avatar: Avatar? = nil, order: Int = -1,
             isDefault: Bool = false, credential: Credential? = nil, pinType: String = "none",
             pinHash: String = "", pinSalt: String = "") {
            self.username = username; self.displayName = displayName; self.role = role; self.avatar = avatar
            self.order = order; self.isDefault = isDefault; self.credential = credential
            self.pinType = pinType; self.pinHash = pinHash; self.pinSalt = pinSalt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            username = try c.decode(String.self, forKey: .username)
            displayName = try c.decode(String.self, forKey: .displayName)
            role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
            avatar = try c.decodeIfPresent(Avatar.self, forKey: .avatar)
            order = try c.decodeIfPresent(Int.self, forKey: .order) ?? -1
            isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            credential = try c.decodeIfPresent(Credential.self, forKey: .credential)
            pinType = try c.decodeIfPresent(String.self, forKey: .pinType) ?? "none"
            pinHash = try c.decodeIfPresent(String.self, forKey: .pinHash) ?? ""
            pinSalt = try c.decodeIfPresent(String.self, forKey: .pinSalt) ?? ""
        }
    }

    struct SyncPart: Codable, Equatable, Sendable {
        var provider: String = "dispatcharr"
        var enabled: Bool = true
        init(provider: String = "dispatcharr", enabled: Bool = true) { self.provider = provider; self.enabled = enabled }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "dispatcharr"
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    struct Payload: Codable, Equatable, Sendable {
        var playlist: PlaylistPart
        var profiles: [ProfilePart] = []
        var sync: SyncPart? = nil

        init(playlist: PlaylistPart, profiles: [ProfilePart] = [], sync: SyncPart? = nil) {
            self.playlist = playlist; self.profiles = profiles; self.sync = sync
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            playlist = try c.decode(PlaylistPart.self, forKey: .playlist)
            profiles = try c.decodeIfPresent([ProfilePart].self, forKey: .profiles) ?? []
            sync = try c.decodeIfPresent(SyncPart.self, forKey: .sync)
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }

    static func encodePayload(_ p: Payload) -> Data { (try? encoder().encode(p)) ?? Data() }

    static func decodePayload(_ d: Data) -> Payload? { try? JSONDecoder().decode(Payload.self, from: d) }

    static func encodeEnvelope(_ e: Envelope) -> Data { (try? encoder().encode(e)) ?? Data() }

    // MARK: Both halves of the exchange

    /// Phone side: seal `payload` for the TV whose public key is `tvPk`.
    /// A fresh X25519 pair per call; `phonePrivate` and `nonce` exist for the vectors.
    static func sealForTv(_ payload: Payload, tvPk: Data, code: String,
                          phonePrivate: Curve25519.KeyAgreement.PrivateKey = .init(),
                          nonce: Data? = nil) throws -> Envelope {
        try sealForTv(plaintext: encodePayload(payload), tvPk: tvPk, code: code, phonePrivate: phonePrivate, nonce: nonce)
    }

    static func sealForTv(plaintext: Data, tvPk: Data, code: String,
                          phonePrivate: Curve25519.KeyAgreement.PrivateKey = .init(),
                          nonce: Data? = nil) throws -> Envelope {
        let phonePk = phonePrivate.publicKey.rawRepresentation
        let key = try SetupCrypto.deriveKey(own: phonePrivate, peerPublic: tvPk, code: code, phonePk: phonePk, tvPk: tvPk)
        let sealed = try SetupCrypto.seal(key: key, plaintext: plaintext, nonce: nonce)
        return Envelope(phonePk: SetupCrypto.b64(phonePk), nonce: SetupCrypto.b64(sealed.nonce),
                        ciphertext: SetupCrypto.b64(sealed.ciphertext))
    }

    enum OpenResult: Equatable {
        case ok(Payload)
        /// Decrypt failed: wrong code (or key, or tampering). Counts as a failed attempt.
        case wrongCode
        /// Not a version 1 envelope or unparseable. Does not count.
        case badRequest
    }

    /// TV side: open an envelope with the TV key pair and the code on screen.
    static func openOnTv(_ body: Data, tv: Curve25519.KeyAgreement.PrivateKey, code: String) -> OpenResult {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: body), env.v == version,
              let phonePk = SetupCrypto.unb64(env.phonePk), phonePk.count == 32,
              let nonce = SetupCrypto.unb64(env.nonce), nonce.count == SetupCrypto.nonceBytes,
              let ct = SetupCrypto.unb64(env.ciphertext), ct.count > SetupCrypto.tagBytes,
              let key = try? SetupCrypto.deriveKey(own: tv, peerPublic: phonePk, code: code,
                                                  phonePk: phonePk, tvPk: tv.publicKey.rawRepresentation)
        else { return .badRequest }
        guard let plain = SetupCrypto.open(key: key, nonce: nonce, ciphertext: ct) else { return .wrongCode }
        return decodePayload(plain).map { .ok($0) } ?? .badRequest
    }
}

// MARK: - Scanned or imported codes

/// What a scanned, picked, or imported code means to AerioTV: the Dispatcharr
/// user API-key QR (web UI User modal, Dispatcharr dev commit 52bdb33e) or a
/// TV's setup link. Never log `apiKey`; `description` redacts it.
enum ScannedCode {
    static let invalidMessage = "This is not a Dispatcharr user code or an AerioTV setup code."
    static let noQRInImage = "No QR code found in that image."
    static let userKeyType = "user_api_key"
    static let userKeyVersion = 1

    struct UserKey: Equatable, Sendable, CustomStringConvertible {
        let apiKey: String
        let baseUrl: String?
        let username: String?
        var description: String { "UserKey(baseUrl: \(baseUrl != nil), username: \(username != nil), apiKey: <redacted>)" }
    }

    enum Result: Equatable, Sendable {
        case userKey(UserKey)
        case setupLink(String)
        case invalid
    }

    static func parse(_ raw: String?) -> Result {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .invalid }
        if text.lowercased().hasPrefix("aeriotv:") {
            return SetupProtocol.parseLink(text) != nil ? .setupLink(text) : .invalid
        }
        return parseUserKey(text).map { .userKey($0) } ?? .invalid
    }

    static func parseUserKey(_ text: String) -> UserKey? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard str("type") == userKeyType else { return nil }
        // v must be the JSON number 1 (not a string, not a bool).
        guard let v = obj["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.doubleValue == 1 else { return nil }
        guard let apiKey = str("api_key"), !apiKey.isEmpty else { return nil }
        var rawBase = str("base_url") ?? ""
        while rawBase.hasSuffix("/") { rawBase.removeLast() }
        let baseUrl: String?
        let lower = rawBase.lowercased()
        if rawBase.isEmpty { baseUrl = nil }
        else if lower.hasPrefix("http://") || lower.hasPrefix("https://") { baseUrl = rawBase }
        else { return nil }
        let user = str("username").flatMap { $0.isEmpty ? nil : $0 }
        return UserKey(apiKey: apiKey, baseUrl: baseUrl, username: user)
    }
}

/// The same codes arriving as a file (Import file): the user_api_key JSON, or
/// a setup link that may sit among other text.
enum CodeTextImport {
    static let maxBytes = 64 * 1024
    static let fileInvalidMessage = "That file is not a Dispatcharr user code or an AerioTV setup code."

    /// UTF-8 of at most `maxBytes`; nil when larger (rejected, never parsed from a prefix).
    static func decodeLimited(_ data: Data) -> String? {
        guard data.count <= maxBytes else { return nil }
        var s = String(decoding: data, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    /// The whole text as a code; then a setup link anywhere in it; then the
    /// outermost `{...}` as the user code JSON.
    static func parse(_ text: String?) -> ScannedCode.Result {
        var t = text ?? ""
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .invalid }
        let whole = ScannedCode.parse(t)
        if whole != .invalid { return whole }
        if let r = t.range(of: #"aeriotv://setup\?[^\s"'<>]+"#, options: [.regularExpression, .caseInsensitive]) {
            var link = String(t[r])
            while let last = link.last, ".,)];".contains(last) { link.removeLast() }
            let l = ScannedCode.parse(link)
            if l != .invalid { return l }
        }
        if let open = t.firstIndex(of: "{"), let close = t.lastIndex(of: "}"), open < close,
           let k = ScannedCode.parseUserKey(String(t[open...close])) {
            return .userKey(k)
        }
        return .invalid
    }

    static func parse(data: Data) -> ScannedCode.Result {
        guard let s = decodeLimited(data) else { return .invalid }
        return parse(s)
    }
}

/// Restore offer after a QR sign-in: does the App Data list
/// (GET /api/accounts/users/me/app-data/, {"apps":[{"key":...,"bytes":...}]})
/// hold AerioTV's main Dispatcharr Sync key?
enum DsyncRestoreProbe {
    static let mainKey = "app.molinete.aerio"

    static func listsMainKey(_ body: Data?) -> Bool {
        guard let body, let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let apps = root["apps"] as? [Any] else { return false }
        return apps.contains { (($0 as? [String: Any])?["key"] as? String) == mainKey }
    }
}
