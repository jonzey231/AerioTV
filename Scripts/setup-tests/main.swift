// Setup handoff and QR parser tests. Sections name the Android test they port
// (app/src/test/java/com/aeriotv/android/core/setup/SetupProtocolTest.kt and
// core/qr tests) or the RFC they check.

import Foundation
import CryptoKit

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL \(line): \(msg)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    check(a == b, "\(msg): expected \(b), got \(a)", line: line)
}

func hex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

func toHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

typealias KA = Curve25519.KeyAgreement

// MARK: - RFC 7748 section 6.1 (x25519MatchesRfc7748Vectors)

let alicePriv = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
let alicePub = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
let bobPriv = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
let bobPub = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
let sharedHex = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
do {
    let a = try KA.PrivateKey(rawRepresentation: alicePriv)
    let b = try KA.PrivateKey(rawRepresentation: bobPriv)
    eq(a.publicKey.rawRepresentation, alicePub, "alice public")
    eq(b.publicKey.rawRepresentation, bobPub, "bob public")
    let s1 = try a.sharedSecretFromKeyAgreement(with: KA.PublicKey(rawRepresentation: bobPub)).withUnsafeBytes { Data($0) }
    let s2 = try b.sharedSecretFromKeyAgreement(with: KA.PublicKey(rawRepresentation: alicePub)).withUnsafeBytes { Data($0) }
    eq(toHex(s1), sharedHex, "shared alice")
    eq(toHex(s2), sharedHex, "shared bob")
} catch { check(false, "rfc7748 threw \(error)") }

// MARK: - RFC 5869 test case 1 (hkdfMatchesRfc5869Case1)

do {
    let okm = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")),
        salt: hex("000102030405060708090a0b0c"),
        info: hex("f0f1f2f3f4f5f6f7f8f9"),
        outputByteCount: 42).withUnsafeBytes { Data($0) }
    eq(toHex(okm), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "hkdf okm")
}

// MARK: - Sealed envelope vector (Java port of Android SetupCrypto)
// Phone = RFC 7748 Alice, TV = RFC 7748 Bob, code 000123, nonce 00..0b.

let vecCode = "000123"
let vecNonce = hex("000102030405060708090a0b")
let vecPlain = #"{"playlist":{"type":"m3u","name":"Home","url":"http://192.168.1.10/a.m3u"}}"#
let vecInfo = "616572696f74762d73657475702d76318520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6ade9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
let vecKey = "c67b44c2c172f055781e716e52be98878d7263f336282f8951ce15527cc768d9"
let vecCtTag = "d9a33214923b572667e099f0ae1dc0a2cf6e6f66f3e88a0c5f4b3c76b8d57bcff44b41ca55b0c08d3ba82684750e03f29bd4636c8a27d82ad54bf228f64829b21ea3261385db98b65369955bd6eb023ecaeece7b4ebae015af615b"
let vecEnvelope = #"{"ciphertext":"2aMyFJI7VyZn4Jnwrh3Aos9ub2bz6IoMX0s8drjVe8/0S0HKVbDAjTuoJoR1DgPym9RjbIon2CrVS/Io9kgpsh6jJhOF25i2U2mVW9brAj7K7s57TrrgFa9hWw==","nonce":"AAECAwQFBgcICQoL","phonePk":"hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=","v":1}"#
do {
    let phone = try KA.PrivateKey(rawRepresentation: alicePriv)
    let tv = try KA.PrivateKey(rawRepresentation: bobPriv)
    var info = Data(SetupCrypto.infoPrefix.utf8); info.append(alicePub); info.append(bobPub)
    eq(toHex(info), vecInfo, "info bytes")
    let key = try SetupCrypto.deriveKey(own: phone, peerPublic: bobPub, code: vecCode, phonePk: alicePub, tvPk: bobPub)
    eq(key.withUnsafeBytes { toHex(Data($0)) }, vecKey, "derived key")
    let keyTv = try SetupCrypto.deriveKey(own: tv, peerPublic: alicePub, code: vecCode, phonePk: alicePub, tvPk: bobPub)
    eq(keyTv.withUnsafeBytes { toHex(Data($0)) }, vecKey, "derived key (TV side)")
    let env = try SetupProtocol.sealForTv(plaintext: Data(vecPlain.utf8), tvPk: bobPub, code: vecCode,
                                          phonePrivate: phone, nonce: vecNonce)
    eq(toHex(SetupCrypto.unb64(env.ciphertext)!), vecCtTag, "ciphertext || tag")
    eq(String(decoding: SetupProtocol.encodeEnvelope(env), as: UTF8.self), vecEnvelope, "envelope JSON")
    // The Android-produced envelope opens here (TV side of the next phase).
    switch SetupProtocol.openOnTv(Data(vecEnvelope.utf8), tv: tv, code: vecCode) {
    case .ok(let p): eq(p.playlist.name, "Home", "opened payload"); eq(p.playlist.guideDays, 7, "default guideDays")
    default: check(false, "vector envelope did not open")
    }
    eq(SetupProtocol.openOnTv(Data(vecEnvelope.utf8), tv: tv, code: "000124"), .wrongCode, "wrong code")
    eq(SetupProtocol.openOnTv(Data(vecEnvelope.utf8), tv: KA.PrivateKey(), code: vecCode), .wrongCode, "wrong TV key")
    var tampered = SetupCrypto.unb64(env.ciphertext)!
    tampered[tampered.count - 1] ^= 0x01
    let tEnv = SetupProtocol.Envelope(phonePk: env.phonePk, nonce: env.nonce, ciphertext: SetupCrypto.b64(tampered))
    eq(SetupProtocol.openOnTv(SetupProtocol.encodeEnvelope(tEnv), tv: tv, code: vecCode), .wrongCode, "tampered tag")
    eq(SetupProtocol.openOnTv(Data("{}".utf8), tv: tv, code: vecCode), .badRequest, "empty envelope")
    let v2 = #"{"v":2,"phonePk":"hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=","nonce":"AAECAwQFBgcICQoL","ciphertext":"AAAA"}"#
    eq(SetupProtocol.openOnTv(Data(v2.utf8), tv: tv, code: vecCode), .badRequest, "version 2")
    eq(SetupCrypto.keyFingerprint(bobPub), "YFH7", "fingerprint (Java reference)")
} catch { check(false, "vector threw \(error)") }

// MARK: - All-zero shared secret is rejected

do {
    let phone = KA.PrivateKey()
    let zeroPk = Data(count: 32)
    var threw = false
    do { _ = try SetupCrypto.deriveKey(own: phone, peerPublic: zeroPk, code: "000000", phonePk: phone.publicKey.rawRepresentation, tvPk: zeroPk) }
    catch { threw = true }
    check(threw, "all-zero peer key must be rejected")
}

// MARK: - payloadRoundTrips / sealOpenRoundTripAndWrongCode

let payload = SetupProtocol.Payload(
    playlist: .init(type: "dispatcharr", name: "Home", url: "https://tv.example.com",
                    localUrl: "http://192.168.1.10:9191", guideDays: 3, catchupOffsetMinutes: -60,
                    channelProfileIds: [2], credential: .init(apiKey: "k1")),
    profiles: [
        .init(username: "admin", displayName: "Admin", role: "admin", order: 0, isDefault: true),
        .init(username: "kid", displayName: "Kid", role: "child", avatar: .init(icon: "star", color: "blue"), order: 1,
              credential: .init(password: "pw"), pinType: "numbers",
              pinHash: String(repeating: "a", count: 64), pinSalt: String(repeating: "b", count: 32)),
    ],
    sync: .init())
eq(SetupProtocol.decodePayload(SetupProtocol.encodePayload(payload)), payload, "payload round trip")
check(SetupProtocol.decodePayload(Data("not json".utf8)) == nil, "bad payload json")
check(!String(decoding: SetupProtocol.encodePayload(.init(playlist: .init(type: "m3u", name: "a", url: "b"))), as: UTF8.self).contains("null"),
      "absent optionals are omitted, never null")
do {
    let tv = KA.PrivateKey()
    let env = try SetupProtocol.sealForTv(payload, tvPk: tv.publicKey.rawRepresentation, code: "042917")
    let body = SetupProtocol.encodeEnvelope(env)
    eq(SetupProtocol.openOnTv(body, tv: tv, code: "042917"), .ok(payload), "seal/open round trip")
    eq(SetupProtocol.openOnTv(body, tv: tv, code: "042918"), .wrongCode, "round trip wrong code")
    eq(SetupProtocol.openOnTv(body, tv: KA.PrivateKey(), code: "042917"), .wrongCode, "round trip wrong key")
    eq(SetupCrypto.unb64(env.nonce)?.count, 12, "12-byte nonce")
    let env2 = try SetupProtocol.sealForTv(payload, tvPk: tv.publicKey.rawRepresentation, code: "042917")
    check(env.phonePk != env2.phonePk, "fresh phone key pair per send")
    check(env.nonce != env2.nonce, "fresh nonce per send")
    check(body.count < SetupProtocol.maxBodyBytes, "normal body under the limit")
    // Oversized: a payload whose encoded body passes 256 KiB is caught before sending.
    var big = payload
    big.playlist.name = String(repeating: "x", count: 300 * 1024)
    let bigBody = SetupProtocol.encodeEnvelope(try SetupProtocol.sealForTv(big, tvPk: tv.publicKey.rawRepresentation, code: "042917"))
    check(bigBody.count > SetupProtocol.maxBodyBytes, "oversized body detected")
} catch { check(false, "round trip threw \(error)") }

// MARK: - linkRoundTrips and base64 variants

do {
    let pk = KA.PrivateKey().publicKey.rawRepresentation
    let url = SetupProtocol.buildLink(ip: "192.168.1.20", port: 41234, code: "000123", pk: pk, name: "Living Room TV")
    let link = SetupProtocol.parseLink(url)
    eq(link?.ip, "192.168.1.20", "link ip")
    eq(link?.port, 41234, "link port")
    eq(link?.code, "000123", "link code keeps leading zeros")
    eq(link?.name, "Living Room TV", "link name")
    eq(link?.pk, pk, "link pk")
    check(SetupProtocol.parseLink("aeriotv://setup?v=2&ip=1&port=1&code=000000&pk=x") == nil, "v=2 rejected")
    // Every base64 spelling of the same key.
    let std = SetupCrypto.b64(pk)
    let stdNoPad = std.replacingOccurrences(of: "=", with: "")
    let url64 = SetupCrypto.b64Url(pk)
    let urlPad = url64 + "="
    for (label, enc) in [("standard", std), ("standard unpadded", stdNoPad), ("url-safe", url64), ("url-safe padded", urlPad)] {
        eq(SetupCrypto.unb64(enc), pk, "unb64 \(label)")
        let pct = enc.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? enc
        let l = SetupProtocol.parseLink("aeriotv://setup?v=1&ip=10.0.0.2&port=5000&code=123456&pk=\(pct)&name=TV")
        eq(l?.pk, pk, "link pk \(label) percent-encoded")
        let raw = SetupProtocol.parseLink("aeriotv://setup?v=1&ip=10.0.0.2&port=5000&code=123456&pk=\(enc)&name=TV")
        eq(raw?.pk, pk, "link pk \(label) raw")
    }
    check(SetupProtocol.parseLink("aeriotv://setup?v=1&ip=10.0.0.2&port=5000&code=12345&pk=\(url64)") == nil, "5-digit code")
    check(SetupProtocol.parseLink("aeriotv://setup?v=1&ip=10.0.0.2&port=0&code=123456&pk=\(url64)") == nil, "port 0")
    check(SetupProtocol.parseLink("aeriotv://setup?v=1&ip=10.0.0.2&port=5000&code=123456&pk=AAAA") == nil, "short pk")
    check(SetupProtocol.parseLink("aeriotv://other?v=1&ip=10.0.0.2&port=5000&code=123456&pk=\(url64)") == nil, "wrong host")
    check(SetupProtocol.parseLink("AerioTV://SETUP?v=1&ip=10.0.0.2&port=5000&code=123456&pk=\(url64)") != nil, "scheme and host case")
    eq(SetupProtocol.parseLink("aeriotv://setup?v=1&ip=10.0.0.2&port=5000&code=123456&pk=\(url64)&name=Den+TV")?.name, "Den TV", "plus is space")
}

// MARK: - newCodeIsSixDigits

for _ in 0..<50 {
    let c = SetupCrypto.newCode()
    check(c.count == 6 && c.allSatisfy(\.isNumber), "six digits: \(c)")
}

// MARK: - ScannedCode (Dispatcharr user QR)

do {
    let full = #"{"v":1,"type":"user_api_key","api_key":" abc123 ","base_url":"https://tv.example.com/","username":"alex","first_name":"","last_name":"","email":""}"#
    eq(ScannedCode.parse(full), .userKey(.init(apiKey: "abc123", baseUrl: "https://tv.example.com", username: "alex")), "full user QR")
    let trimmed = #"{"v":1,"type":"user_api_key","api_key":"k","base_url":"http://10.0.0.5:9191"}"#
    eq(ScannedCode.parse(trimmed), .userKey(.init(apiKey: "k", baseUrl: "http://10.0.0.5:9191", username: nil)), "trimmed user QR")
    eq(ScannedCode.parse(#"{"v":1,"type":"user_api_key","api_key":"k"}"#), .userKey(.init(apiKey: "k", baseUrl: nil, username: nil)), "no base_url")
    eq(ScannedCode.parse(#"{"v":2,"type":"user_api_key","api_key":"k"}"#), .invalid, "v 2")
    eq(ScannedCode.parse(#"{"v":"1","type":"user_api_key","api_key":"k"}"#), .invalid, "v as string")
    eq(ScannedCode.parse(#"{"v":true,"type":"user_api_key","api_key":"k"}"#), .invalid, "v as bool")
    eq(ScannedCode.parse(#"{"v":1,"type":"other","api_key":"k"}"#), .invalid, "other type")
    eq(ScannedCode.parse(#"{"v":1,"type":"user_api_key","api_key":""}"#), .invalid, "empty key")
    eq(ScannedCode.parse(#"{"v":1,"type":"user_api_key","api_key":"k","base_url":"ftp://x"}"#), .invalid, "non-http base")
    eq(ScannedCode.parse("https://example.com"), .invalid, "plain URL")
    eq(ScannedCode.parse(""), .invalid, "empty")
    eq(ScannedCode.parse("aeriotv://setup?v=1"), .invalid, "broken setup link")
    let pk = SetupCrypto.b64Url(KA.PrivateKey().publicKey.rawRepresentation)
    let link = "aeriotv://setup?v=1&ip=10.0.0.2&port=5000&code=000001&pk=\(pk)&name=TV"
    eq(ScannedCode.parse(link), .setupLink(link), "setup link")
    check(!"\(ScannedCode.UserKey(apiKey: "SECRET", baseUrl: nil, username: nil))".contains("SECRET"), "description redacts the key")
    eq(ScannedCode.invalidMessage, "This is not a Dispatcharr user code or an AerioTV setup code.", "invalid copy")

    // MARK: CodeTextImport (Import file)
    eq(CodeTextImport.parse("\u{FEFF}" + trimmed + "\n"), .userKey(.init(apiKey: "k", baseUrl: "http://10.0.0.5:9191", username: nil)), "BOM and newline")
    eq(CodeTextImport.parse("Scan this: \(link).\nThanks"), .setupLink(link), "link among text")
    eq(CodeTextImport.parse("note\n" + trimmed + "\nend"), .userKey(.init(apiKey: "k", baseUrl: "http://10.0.0.5:9191", username: nil)), "JSON among text")
    eq(CodeTextImport.parse("hello world"), .invalid, "plain text")
    eq(CodeTextImport.parse(data: Data(repeating: 0x20, count: CodeTextImport.maxBytes + 1)), .invalid, "over 64 KiB")
    eq(CodeTextImport.parse(data: Data(trimmed.utf8)), .userKey(.init(apiKey: "k", baseUrl: "http://10.0.0.5:9191", username: nil)), "file data")
    eq(CodeTextImport.fileInvalidMessage, "That file is not a Dispatcharr user code or an AerioTV setup code.", "file invalid copy")

    // MARK: DsyncRestoreProbe
    check(DsyncRestoreProbe.listsMainKey(Data(#"{"apps":[{"key":"other","bytes":2},{"key":"app.molinete.aerio","bytes":10}]}"#.utf8)), "main key listed")
    check(!DsyncRestoreProbe.listsMainKey(Data(#"{"apps":[{"key":"app.molinete.aerio.p.x","bytes":10}]}"#.utf8)), "profile key only")
    check(DsyncRestoreProbe.listsMainKey(Data(#"{"apps":[{"key":"logan.aeriotv","bytes":10}]}"#.utf8)), "user key listed")
    check(!DsyncRestoreProbe.listsMainKey(Data(#"{"apps":[{"key":".aeriotv","bytes":10},{"key":"logan.aeriotv.favorites","bytes":1}]}"#.utf8)), "bare suffix and v2 key only")
    check(!DsyncRestoreProbe.listsMainKey(Data("nope".utf8)), "bad body")
    check(!DsyncRestoreProbe.listsMainKey(nil), "nil body")
}

// MARK: Sender profile rules (Dispatcharr payload with profiles; synthetic data only)
do {
    typealias R = SetupProfileRules
    let salt = String(repeating: "a", count: 32), hash = String(repeating: "b", count: 64)
    let sources: [R.Source] = [
        .init(id: "d", username: "owner", displayName: "Owner", role: "admin", isDefault: true,
              apiKey: "base-key-not-sent", pinType: "numbers", pinHash: hash, pinSalt: salt),
        .init(id: "k", username: "kid", displayName: "Kid", role: "child",
              avatar: .init(icon: "rocket", color: "teal"), apiKey: "kid-key"),
        .init(id: "g", username: "guest", displayName: "Guest", role: "user", password: "pw",
              pinType: "directions", pinHash: hash, pinSalt: ""),
        .init(id: "n", username: "nokey", displayName: "No Key", role: "user"),
    ]
    let all = R.parts(sources, selected: ["k", "g", "n"])
    eq(all.map(\.username), ["owner", "kid", "guest"], "default always, no-credential row dropped")
    eq(all.map(\.order), [0, 1, 2], "order is the list position")
    check(all[0].isDefault && all[0].credential == nil, "default carries no credential")
    eq(all[0].pinType, "numbers", "default v2 PIN sent")
    eq(all[0].pinHash, hash, "default PIN hash")
    eq(all[1].credential, SetupProtocol.Credential(apiKey: "kid-key"), "api key only")
    eq(all[1].role, "child", "role wire")
    eq(all[1].avatar, SetupProtocol.Avatar(icon: "rocket", color: "teal"), "avatar")
    eq(all[1].pinType, "none", "no PIN")
    eq(all[2].credential, SetupProtocol.Credential(password: "pw"), "password only")
    eq(all[2].pinType, "none", "legacy PIN (no salt) sent as none")
    eq(all[2].pinHash, "", "legacy PIN hash empty")
    eq(R.parts(sources, selected: []).map(\.username), ["owner"], "nothing selected: default only")
    eq(R.parts(sources, selected: ["g"]).map(\.order), [0, 2], "order kept when a row is skipped")
    eq(R.credentialLabel(apiKey: " k ", password: "p"), "API key saved", "key label first")
    eq(R.credentialLabel(apiKey: "", password: "p"), "Password saved", "password label")
    eq(R.credentialLabel(apiKey: nil, password: "  "), nil, "no label")
    check(R.canSetUpTv(activeRole: "admin", activeIsDefault: false), "admin may send")
    check(R.canSetUpTv(activeRole: "user", activeIsDefault: false), "standard may send")
    check(!R.canSetUpTv(activeRole: "child", activeIsDefault: false), "child profile may not send")
    check(R.canSetUpTv(activeRole: "child", activeIsDefault: true), "default profile may send")
    check(R.canSetUpTv(activeRole: nil, activeIsDefault: nil), "no profiles yet: the default")
    // Full Dispatcharr payload round trip with profiles.
    let payload = SetupProtocol.Payload(
        playlist: .init(type: "dispatcharr", name: "Home", url: "http://192.0.2.10:9191",
                        channelProfileIds: [2], credential: .init(apiKey: "base-key")),
        profiles: all, sync: SetupProtocol.SyncPart())
    let back = SetupProtocol.decodePayload(SetupProtocol.encodePayload(payload))
    eq(back, payload, "payload with profiles round trips")
    eq(back?.profiles.count, 3, "three profiles decoded")
}

// User QR source: vectors shared with Android UserQrCryptoTest.
do {
    let link = "aeriotv://setup?v=1&ip=192.168.1.20&port=5000&code=123456&pk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&name=iPad"
    eq(UserQrCrypto.uq(apiKey: "test-key-123"), "d66eadb6a1fff42c", "user QR uq vector")
    eq(UserQrCrypto.proof(apiKey: "test-key-123", link: link), "WjHdnpPuNCR8MJeEQP4quCIAynNokhPPygG2+VGcyNk=", "user QR proof vector")
    check(UserQrCrypto.verify(apiKey: "test-key-123", link: link, proof: UserQrCrypto.proof(apiKey: "test-key-123", link: link)), "proof verifies")
    check(!UserQrCrypto.verify(apiKey: "other", link: link, proof: UserQrCrypto.proof(apiKey: "test-key-123", link: link)), "wrong key fails")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
