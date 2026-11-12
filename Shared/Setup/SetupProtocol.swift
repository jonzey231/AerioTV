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
    /// Receiver form factor: phone, tablet, or tv. Absent (older builds) = tv.
    static let txtKind = "kind"
    /// Receiver mode. Absent = a normal setup receiver; `modeFixLogin` = a TV
    /// whose playlist's key is held as rejected, asking a phone for that
    /// playlist's sign-in only (FixLogin). Older builds never advertise it.
    static let txtMode = "mode"
    static let modeFixLogin = "fixlogin"
    /// With `modeFixLogin`: the playlist id (UUID, lowercase) whose sign-in is wanted. Not a secret.
    static let txtPlaylist = "pl"

    enum Kind: String, Sendable {
        case phone, tablet, tv
        /// Absent or unknown TXT value: older receivers were TVs only.
        static func fromTxt(_ s: String?) -> Kind { s.flatMap { Kind(rawValue: $0.lowercased()) } ?? .tv }
    }
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
        /// The sender's playlist id (2026-11-10): the receiver keeps it, so the
        /// same playlist has one id on every device. Absent from older senders.
        var id: String? = nil

        init(type: String, name: String, url: String, xmltvUrl: String? = nil, localUrl: String? = nil,
             userAgent: String? = nil, guideDays: Int = 7, catchupOffsetMinutes: Int = 0, vodEnabled: Bool = true,
             channelProfileIds: [Int] = [], credential: Credential? = nil, id: String? = nil) {
            self.type = type; self.name = name; self.url = url; self.xmltvUrl = xmltvUrl; self.localUrl = localUrl
            self.userAgent = userAgent; self.guideDays = guideDays; self.catchupOffsetMinutes = catchupOffsetMinutes
            self.vodEnabled = vodEnabled; self.channelProfileIds = channelProfileIds; self.credential = credential
            self.id = id
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
            id = try c.decodeIfPresent(String.self, forKey: .id)
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
        /// The sender's profile id (2026-11-10), kept by the receiver. Absent from older senders.
        var id: String? = nil

        init(username: String, displayName: String, role: String = "", avatar: Avatar? = nil, order: Int = -1,
             isDefault: Bool = false, credential: Credential? = nil, pinType: String = "none",
             pinHash: String = "", pinSalt: String = "", id: String? = nil) {
            self.username = username; self.displayName = displayName; self.role = role; self.avatar = avatar
            self.order = order; self.isDefault = isDefault; self.credential = credential
            self.pinType = pinType; self.pinHash = pinHash; self.pinSalt = pinSalt
            self.id = id
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
            id = try c.decodeIfPresent(String.self, forKey: .id)
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
        /// `modeFixLogin` = only the playlist's sign-in (no profiles, no sync
        /// choice); the receiver updates the sign-in of its playlist with
        /// `playlist.id` and nothing else. Absent (left out of the JSON) = a
        /// normal setup, which is what every sender before Fix Login sends.
        var mode: String? = nil

        init(playlist: PlaylistPart, profiles: [ProfilePart] = [], sync: SyncPart? = nil, mode: String? = nil) {
            self.playlist = playlist; self.profiles = profiles; self.sync = sync; self.mode = mode
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            playlist = try c.decode(PlaylistPart.self, forKey: .playlist)
            profiles = try c.decodeIfPresent([ProfilePart].self, forKey: .profiles) ?? []
            sync = try c.decodeIfPresent(SyncPart.self, forKey: .sync)
            mode = try c.decodeIfPresent(String.self, forKey: .mode)
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

// MARK: - Fix Login (update a TV's sign-in from a phone)

/// Fix Login (docs/DeviceSetupHandoff.md, "Fix Login"; Android
/// core/setup/FixLogin.kt): a phone updates a TV's sign-in when the server
/// rejected the TV's API key. Same receiver, sender, crypto, and envelope as
/// Set up another device; the TV advertises `mode=fixlogin` and
/// `pl=<playlist id>`, and the payload carries `mode: "fixlogin"` with one
/// playlist and its credential. Every user-facing string lives here, word for
/// word as Android, so a wording change is one edit. Pure, so
/// Scripts/setup-tests checks the advert, the card rule, and the apply rule.
enum FixLogin {
    /// Dock card and Settings banner button for a Fix Login advert.
    static let button = "Fix Login"
    /// Sender sheet title while fixing a TV's sign-in.
    static let sheetTitle = "Fix Login"
    /// Receive screen header on the TV.
    static let receiveTitle = "Update from your phone"
    /// Receive screen line on the TV.
    static let receiveLine = "On your phone, open AerioTV and tap Fix Login."
    /// TV progress line while the sign-in is written.
    static let applyingLine = "Signing in"
    /// TV confirmation before the receive screen closes.
    static let doneLine = "Signed in. Loading channels."
    /// How long the TV shows `doneLine` before the receive screen closes.
    static let doneSeconds: Double = 2
    /// TV error (under "Setup did not finish") when the sign-in is not for a playlist here.
    static let notHere = "The sign-in that was sent is not for a playlist on this device."
    /// Phone error when the playlist to send cannot be read.
    static let unreadable = "This playlist could not be read."

    // The rejected-key prompt's TV buttons live in KeySignInCopy
    // (Networking/DispatcharrRateLimitRetry.swift) with the rest of its copy.

    /// Phone line after a successful send.
    static func sentLine(_ deviceName: String) -> String {
        let n = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Sent. \(n.isEmpty ? "The device" : n) is signing in."
    }

    /// An advert's `mode`: nil for a normal setup receiver (absent or blank,
    /// every build before this key), `SetupProtocol.modeFixLogin`, or any other
    /// value as read (a mode this build does not know; never offered).
    static func normalizeMode(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty else { return nil }
        return t
    }

    /// An advert's `pl`: trimmed and lowercased, nil when absent or blank.
    static func normalizePlaylistID(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty else { return nil }
        return t
    }

    /// The TXT keys a Fix Login receiver adds for `playlistID` (none when blank).
    static func txt(playlistID: String?) -> [String: String] {
        guard let pl = normalizePlaylistID(playlistID) else { return [:] }
        return [SetupProtocol.txtMode: SetupProtocol.modeFixLogin, SetupProtocol.txtPlaylist: pl]
    }

    // MARK: Phone: is the card offered, and from which playlist

    /// One playlist on the phone, as the card rule sees it (never a key).
    struct Local: Equatable, Sendable {
        var id: String
        var isDispatcharr: Bool
        /// The username it signs in as, when known here.
        var account: String? = nil
        /// It has an API key or a password to send.
        var hasCredential: Bool
        /// This phone's own key for it is held as rejected.
        var keyHeld: Bool
    }

    /// The phone playlist a Fix Login advert for `pl` can be fixed from, or nil
    /// (no card). A Dispatcharr playlist whose id equals `pl` (ids compare
    /// without case), else, per the one-playlist identity rule, the one
    /// Dispatcharr playlist here that signs in as `learnedAccount` (the account
    /// sync reported for `pl`; two candidates are ambiguous and match
    /// nothing). The match must have a sign-in to send and its own key must
    /// not be held as rejected here.
    static func matchPlaylist(_ pl: String?, locals: [Local], learnedAccount: String?) -> Local? {
        guard let want = normalizePlaylistID(pl) else { return nil }
        let dispatcharr = locals.filter(\.isDispatcharr)
        var match = dispatcharr.first { $0.id.trimmingCharacters(in: .whitespaces).lowercased() == want }
        if match == nil, let acct = learnedAccount?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !acct.isEmpty {
            let same = dispatcharr.filter { ($0.account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") == acct }
            if same.count == 1 { match = same[0] }
        }
        guard let m = match, m.hasCredential, !m.keyHeld else { return nil }
        return m
    }

    /// Whether the Set up card and banner offer a device, and as what.
    enum Offer: Equatable, Sendable {
        case none
        /// Normal setup, from the active playlist.
        case setup
        /// Fix Login, sending this playlist's sign-in.
        case fix(String)
    }

    /// `fixLoginPlaylistID` is `matchPlaylist`'s answer for a Fix Login advert;
    /// `canSetUp` is the sender gate (Admin or default profile) for a playlist id.
    static func offer(mode: String?, activePlaylistID: String?, fixLoginPlaylistID: String?,
                      canSetUp: (String) -> Bool) -> Offer {
        switch mode {
        case nil:
            guard let a = activePlaylistID, canSetUp(a) else { return .none }
            return .setup
        case SetupProtocol.modeFixLogin?:
            guard let f = fixLoginPlaylistID, canSetUp(f) else { return .none }
            return .fix(f)
        default:
            return .none
        }
    }

    /// The button on the card and banner for an advert's mode.
    static func buttonLabel(_ mode: String?) -> String { mode == SetupProtocol.modeFixLogin ? button : "Set up" }

    /// The Fix Login payload from a full payload's playlist part: that playlist
    /// and its credential only, addressed to `receiverPlaylistID`. nil without
    /// a credential (nothing to fix with) or a receiver playlist id.
    static func payload(_ playlist: SetupProtocol.PlaylistPart, receiverPlaylistID: String?) -> SetupProtocol.Payload? {
        guard let cred = playlist.credential, cred.apiKey != nil || cred.password != nil,
              let id = receiverPlaylistID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        var p = playlist
        p.id = id
        p.credential = cred
        return SetupProtocol.Payload(playlist: p, profiles: [], sync: nil, mode: SetupProtocol.modeFixLogin)
    }

    // MARK: TV: which playlist a received payload updates, and with what

    /// True when a received payload is applied as a Fix Login: the screen was
    /// opened in Fix Login mode (whatever the sender sent, only the sign-in is
    /// taken), or the payload says `mode: "fixlogin"`.
    static func appliesAsFixLogin(screenPlaylistID: String?, payloadMode: String?) -> Bool {
        screenPlaylistID != nil || normalizeMode(payloadMode) == SetupProtocol.modeFixLogin
    }

    /// The local playlist id a Fix Login payload updates, or nil (the
    /// "not for a playlist on this device" error). The payload's `playlist.id`
    /// must name the playlist the screen was opened for (`screenPlaylistID`,
    /// nil outside Fix Login) and a playlist that exists here (`localIDs`);
    /// ids compare without case. A payload with no id never matches.
    static func receiverPlaylistID(screenPlaylistID: String?, payloadID: String?, localIDs: [String]) -> String? {
        guard let id = payloadID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { return nil }
        if let s = screenPlaylistID, s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != id { return nil }
        return localIDs.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == id }
    }

    /// The sign-in fields to write; the rest of the playlist never changes.
    struct SignIn: Equatable, Sendable {
        var apiKey: String?
        var username: String?
        var password: String?
        /// The username or password changed: cached sessions belong to the old sign-in.
        var accountChanged: Bool
    }

    /// Only the sign-in: the API key, and the username and password when the
    /// payload carries them. A field the payload leaves out (or sends blank)
    /// keeps the stored value. nil when the payload carries no sign-in at all.
    static func signInToWrite(oldKey: String?, oldUser: String?, oldPass: String?,
                              sent: SetupProtocol.Credential?) -> SignIn? {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let key = clean(sent?.apiKey)
        let user = clean(sent?.username)
        let pass = sent?.password.flatMap { $0.isEmpty ? nil : $0 }
        guard key != nil || user != nil || pass != nil else { return nil }
        let changed = (user != nil && user != clean(oldUser)) || (pass != nil && pass != oldPass)
        return SignIn(apiKey: key ?? oldKey, username: user ?? oldUser, password: pass ?? oldPass, accountChanged: changed)
    }
}

// MARK: - What to send (Set up another device, and after a User QR scan)

/// The sender's scope choice, one wording on both screens and both apps.
/// A setup carries the active playlist, its profiles, and preferences, never
/// every playlist (owner 2026-11-12: "Copy entire setup from this device" read
/// as every playlist).
enum SetupScopeCopy {
    static let playlistAndProfiles = "Copy this playlist and its profiles"
    static let userOnly = "Import this user only"

    /// The line under "Copy from {name}" after a User QR scan finds that device.
    static func userQrSubtitle(_ deviceName: String) -> String {
        "Copy the playlist and its profiles from \(deviceName), or add just the user in this code."
    }
}

// MARK: - User QR source (copy a setup from the device showing a User QR Code)

/// The device showing a User QR Code advertises `_aeriotv-setup._tcp` with
/// `role=source` and `uq` (no `pk`, so setup senders never list it). A device
/// that scans the code finds it by `uq` and asks it, with `proof`, to send its
/// setup to the scanner's own one-time receiver link. The QR payload is unchanged.
enum UserQrCrypto {
    static let txtRole = "role"
    static let roleSource = "source"
    static let txtUq = "uq"
    static let path = "/user-qr"
    static let maxBodyBytes = 8 * 1024

    /// Lowercase hex of the first 8 bytes of SHA-256("aeriotv-userqr-v1:" + apiKey).
    static func uq(apiKey: String) -> String {
        SHA256.hash(data: Data(("aeriotv-userqr-v1:" + apiKey).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Standard base64 of HMAC-SHA256(key = apiKey, message = link).
    static func proof(apiKey: String, link: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(link.utf8), using: SymmetricKey(data: Data(apiKey.utf8)))
        return Data(mac).base64EncodedString()
    }

    /// Constant-time check of a received proof.
    static func verify(apiKey: String, link: String, proof: String) -> Bool {
        guard let got = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(got, authenticating: Data(link.utf8), using: SymmetricKey(data: Data(apiKey.utf8)))
    }

    struct Request: Codable, Sendable {
        var v: Int = 1
        let link: String
        let proof: String
    }
}

// MARK: - Sender profile rules

/// The contract's profile rules for the sender (docs/DeviceSetupHandoff.md,
/// Android SetupSender.buildPayload and ProfileManager.canSetUpTv). Pure so
/// Scripts/setup-tests can check them without the app.
/// What an aeriotv://setup link from the system camera does (Android
/// SetupLinkRules and setupLinkMayReplace, c91a3ad4). Pure so
/// Scripts/setup-tests can check it.
enum SetupLinkRules {
    enum Action: Equatable, Sendable {
        /// Open the sender on it (a newer link replaces the open sheet's device).
        case open
        /// Keep it until the app is unlocked and the profile settled, then decide again.
        case hold
        /// A profile that may not set up another device: forget it without a word.
        case drop
        /// The same one-time session again while its sheet is open or held, or after it was sent.
        case ignoreSame
        /// The open sheet is checking the key or sending: the newer link is ignored.
        case ignoreBusy
    }

    /// - Parameters:
    ///   - sameAsLast: same code and key as the last link handled.
    ///   - lastStillLive: that link's sheet is open or held, or its payload went out.
    ///   - sheetBusy: a Set up sheet is running its key check or its send.
    ///   - locked: the launch PIN screen is up or a profile switch is landing.
    ///   - allowed: the active profile may set up another device.
    static func action(sameAsLast: Bool, lastStillLive: Bool, sheetBusy: Bool,
                       locked: Bool, allowed: Bool) -> Action {
        if sameAsLast && lastStillLive { return .ignoreSame }
        if sheetBusy { return .ignoreBusy }
        if locked { return .hold }
        return allowed ? .open : .drop
    }
}

// MARK: - Discovery timing

/// When the sender's `_aeriotv-setup._tcp` browser is refreshed and how a
/// resolve is retried (SetupDiscovery). Pure so Scripts/setup-tests can check it.
///
/// Measured 2026-11-11: a browser that had heard one advert never reported a
/// later session until a relaunch; a browser on a network with no adverts
/// never calls back at all, so the old "recreate every 5 s while silent" loop
/// ran 12 times a minute for as long as the app stayed open; and a resolve
/// connection sat in preparing for over 25 s without failing.
enum SetupDiscoveryRules {
    /// Gap before refresh number `done + 1` since discovery started: 5, 10,
    /// and 20 s, then every 30 s while discovery runs. The first comes fast
    /// for a browser that is deaf from the start; the steady pace costs one
    /// browse query burst every 30 s.
    static func refreshDelay(after done: Int) -> TimeInterval {
        switch done {
        case ..<1: return 5
        case 1: return 10
        case 2: return 20
        default: return 30
        }
    }

    enum RefreshStep: Equatable, Sendable {
        /// Nothing is listed, so nothing can flicker: cancel the browser and start a new one.
        case recreate
        /// Devices are listed: start a second browser beside the current one. It takes
        /// over on its first result, so the offer never blinks during a refresh.
        case startProbe
        /// The second browser stayed silent for a whole interval: replace it.
        case replaceProbe
        /// The second browser stayed silent again while the current one still lists
        /// devices: the current one has missed their goodbye, so the silent browser
        /// takes over and the listed devices count as gone.
        case probeTakesOver
    }

    /// Silent second browsers in a row before the listed devices count as gone.
    static let silentProbeLimit = 2

    /// - Parameters:
    ///   - currentLists: the current browser's last result set listed at least one advert.
    ///   - probeRunning: a second browser from the previous refresh is still silent.
    ///   - silentProbes: silent second browsers already replaced since the last takeover.
    static func refreshStep(currentLists: Bool, probeRunning: Bool, silentProbes: Int) -> RefreshStep {
        guard currentLists else { return .recreate }
        guard probeRunning else { return .startProbe }
        return silentProbes + 1 >= silentProbeLimit ? .probeTakesOver : .replaceProbe
    }

    /// A browser that just took over may report its adverts in pieces (the TXT
    /// record after the name): removals wait this long, then use its latest set.
    static let takeoverRemovalHold: TimeInterval = 2

    /// One resolve attempt (a short TCP connection to the advert) gives up after this.
    /// Measured resolves take 0.05 to 0.5 s.
    static let resolveTimeout: TimeInterval = 4
    /// Attempts per advert per browser; the next refresh tries again after the last.
    static let resolveAttempts = 3

    /// Wait before attempt `attempt + 1`: 1 s, then 2 s.
    static func resolveRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
        attempt <= 1 ? 1 : 2
    }
}

enum SetupProfileRules {
    /// One local profile of the playlist, in list order, with what this device stores for it.
    struct Source: Equatable, Sendable {
        var id: String
        var username: String
        var displayName: String
        /// "admin", "user", or "child" (the effective role).
        var role: String
        /// nil = never chosen (the receiver keeps its default avatar).
        var avatar: SetupProtocol.Avatar? = nil
        var isDefault = false
        /// The profile's own sign-in (ignored for the default profile).
        var apiKey: String? = nil
        var password: String? = nil
        /// The v2 synced PIN record; nil or a legacy (unsalted) PIN goes out as "none".
        var pinType: String? = nil
        var pinHash = ""
        var pinSalt = ""
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Who may send a TV this device's playlist: an Admin or Standard
    /// profile, or the default profile (no profiles yet counts as default).
    static func canSetUpTv(activeRole: String?, activeIsDefault: Bool?) -> Bool {
        (activeRole != nil && activeRole != "child") || activeIsDefault != false
    }

    /// "API key saved", "Password saved", or nil when nothing is stored here.
    static func credentialLabel(apiKey: String?, password: String?) -> String? {
        if nonEmpty(apiKey) != nil { return "API key saved" }
        if nonEmpty(password) != nil { return "Password saved" }
        return nil
    }

    /// The payload profiles: the default profile always (no credential of its
    /// own), plus the selected profiles that carry a sign-in. `order` is the
    /// list position among every local profile; a PIN goes out only as its
    /// v2 hash and salt.
    static func parts(_ sources: [Source], selected: Set<String>) -> [SetupProtocol.ProfilePart] {
        sources.enumerated().compactMap { index, s in
            guard s.isDefault || selected.contains(s.id) else { return nil }
            var cred: SetupProtocol.Credential? = nil
            if !s.isDefault {
                let c = SetupProtocol.Credential(apiKey: nonEmpty(s.apiKey), password: nonEmpty(s.password))
                guard !c.isEmpty else { return nil }
                cred = c
            }
            let pinOk = (s.pinType == "numbers" || s.pinType == "directions") && s.pinHash.count == 64 && s.pinSalt.count == 32
            return SetupProtocol.ProfilePart(
                username: s.username,
                displayName: s.displayName,
                role: s.role,
                avatar: s.avatar,
                order: index,
                isDefault: s.isDefault,
                credential: cred,
                pinType: pinOk ? s.pinType! : "none",
                pinHash: pinOk ? s.pinHash : "",
                pinSalt: pinOk ? s.pinSalt : "",
                id: s.id)
        }
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
/// hold AerioTV's main Dispatcharr Sync key? That is `<user>.aeriotv`
/// (DsyncKeyName), or the legacy `app.molinete.aerio` a not yet migrated
/// record still uses. Runs before the username is read, so any user name counts.
enum DsyncRestoreProbe {
    static let legacyKey = "app.molinete.aerio"
    static let suffix = ".aeriotv"

    static func isMainKey(_ key: String) -> Bool {
        key == legacyKey || (key.hasSuffix(suffix) && key.count > suffix.count)
    }

    static func listsMainKey(_ body: Data?) -> Bool {
        guard let body, let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let apps = root["apps"] as? [Any] else { return false }
        return apps.contains { ((($0 as? [String: Any])?["key"] as? String)).map(isMainKey) ?? false }
    }
}
