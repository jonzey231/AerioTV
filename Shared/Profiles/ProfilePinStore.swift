//  ProfilePinStore.swift
//  Aerio
//
//  Stored PIN records, ported from the Android core/profiles/ProfilePin.kt
//  ProfilePinStore. The record goes through the ProfileSecretBox (the
//  Keychain in the app); never the raw PIN, never in logs.
//
//  v2 (Dispatcharr Sync, docs/DispatcharrSyncSchema.md 4.12):
//  "TYPE:hash:salt" with hash = SHA-256(salt bytes || UTF-8 PIN) and a fresh
//  random 16-byte salt on every set or change, so the same record syncs and
//  verifies on every device.
//  v1 (phase 2a): "TYPE:hash" with the per-device salt. A v1 PIN still
//  verifies, and the first correct entry re-hashes it to v2.
//
//  The Device Admin PIN is a record under DevicePin.id(playlistId), a
//  reserved id that is never a profile id, so it never syncs.
//
//  Pure: Foundation only (compiled by Scripts/dsync-tests).

import Foundation

final class ProfilePinStore {
    private let defaults: UserDefaults
    private let secrets: ProfileSecretBox

    /// Bumps on every set, remove, migration, or synced import.
    private(set) var changes: Int64 = 0
    var onChange: (() -> Void)?

    init(defaults: UserDefaults, secrets: ProfileSecretBox) {
        self.defaults = defaults
        self.secrets = secrets
    }

    static let SALT_BYTES = 16
    static let KEY_SALT = "aerio.pin.salt"
    static let KEY_PIN = "aerio.pin.rec."
    static let KEY_BACKOFF = "aerio.pin.backoff."
    static let KEY_LEN = "aerio.pin.len."

    /// [salt] nil = legacy v1 record.
    struct Record: Equatable {
        var type: PinType
        var hash: String
        var salt: String?
    }

    private func bump() {
        changes += 1
        onChange?()
    }

    private func deviceSalt() -> Data {
        if let hex = secrets.get(Self.KEY_SALT), hex.count == Self.SALT_BYTES * 2, let d = Self.fromHex(hex) { return d }
        let fresh = PinRules.freshSaltHex()
        secrets.set(fresh, Self.KEY_SALT)
        return Self.fromHex(fresh) ?? Data()
    }

    static func fromHex(_ hex: String) -> Data? {
        var out = Data()
        var it = hex.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }

    private func record(_ profileId: String) -> Record? {
        guard let raw = secrets.get(Self.KEY_PIN + profileId) else { return nil }
        guard let type = PinType.allCases.first(where: { raw.hasPrefix($0.rawValue + ":") }) else { return nil }
        let parts = raw.dropFirst(type.rawValue.count + 1).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let h = parts.first else { return nil }
        let salt = parts.count > 1 && parts[1].count == Self.SALT_BYTES * 2 ? parts[1] : nil
        return Record(type: type, hash: h, salt: salt)
    }

    private func write(_ profileId: String, _ type: PinType, _ hash: String, _ salt: String) {
        secrets.set("\(type.rawValue):\(hash):\(salt)", Self.KEY_PIN + profileId)
    }

    func hasPin(_ profileId: String) -> Bool { record(profileId) != nil }
    func type(_ profileId: String) -> PinType? { record(profileId)?.type }

    /// The synced form of [profileId]'s PIN, or nil (no PIN, or a v1 record not yet re-hashed).
    func syncRecord(_ profileId: String) -> Record? { record(profileId).flatMap { $0.salt != nil ? $0 : nil } }

    /// True when the PIN is a v1 record that cannot sync until the next correct entry.
    func isLegacy(_ profileId: String) -> Bool { record(profileId).map { $0.salt == nil } ?? false }

    /// Adopt a synced record (another device set or changed it).
    func importSynced(_ profileId: String, _ type: PinType, hash: String, salt: String) {
        if let cur = record(profileId), cur.type == type, cur.hash == hash, cur.salt == salt { return }
        write(profileId, type, hash, salt)
        // A synced PIN's length is unknown here until the next correct entry.
        defaults.removeObject(forKey: Self.KEY_LEN + profileId)
        bump()
    }

    /// Stored PIN length (dots to show on entry); nil = unknown (older record).
    func length(_ profileId: String) -> Int? {
        guard record(profileId) != nil else { return nil }
        let n = defaults.integer(forKey: Self.KEY_LEN + profileId)
        return (PinRules.MIN_LENGTH...PinRules.MAX_LENGTH).contains(n) ? n : nil
    }

    private func saveLength(_ profileId: String, _ n: Int) {
        if defaults.integer(forKey: Self.KEY_LEN + profileId) != n { defaults.set(n, forKey: Self.KEY_LEN + profileId) }
    }

    /// False when [entries] is not a valid PIN of [type].
    @discardableResult
    func set(_ profileId: String, _ type: PinType, _ entries: [String]) -> Bool {
        guard let n = PinRules.normalize(type, entries) else { return false }
        let salt = PinRules.freshSaltHex()
        guard let h = PinRules.hashV2(saltHex: salt, normalized: n) else { return false }
        write(profileId, type, h, salt)
        defaults.removeObject(forKey: Self.KEY_BACKOFF + profileId)
        defaults.set(n.count, forKey: Self.KEY_LEN + profileId)
        bump()
        return true
    }

    func remove(_ profileId: String) {
        if record(profileId) == nil && defaults.string(forKey: Self.KEY_BACKOFF + profileId) == nil { return }
        secrets.set(nil, Self.KEY_PIN + profileId)
        defaults.removeObject(forKey: Self.KEY_BACKOFF + profileId)
        defaults.removeObject(forKey: Self.KEY_LEN + profileId)
        bump()
    }

    /// True when [entries] match (no PIN = true). A correct v1 entry migrates the record to v2.
    func check(_ profileId: String, _ entries: [String]) -> Bool {
        guard let r = record(profileId) else { return true }
        guard let n = PinRules.normalize(r.type, entries) else { return false }
        if let salt = r.salt {
            let ok = PinRules.hashV2(saltHex: salt, normalized: n).map { PinRules.matches($0, r.hash) } ?? false
            if ok { saveLength(profileId, n.count) }
            return ok
        }
        let ok = PinRules.matches(PinRules.hash(salt: deviceSalt(), profileId: profileId, type: r.type, normalized: n), r.hash)
        if ok {
            // One-time migration to the synced v2 form.
            let salt = PinRules.freshSaltHex()
            if let h = PinRules.hashV2(saltHex: salt, normalized: n) { write(profileId, r.type, h, salt) }
            saveLength(profileId, n.count)
            bump()
        }
        return ok
    }

    /// Test hook: write a v1 record the way phase 2a did (device salt).
    func writeLegacyForTesting(_ profileId: String, _ type: PinType, _ entries: [String]) {
        guard let n = PinRules.normalize(type, entries) else { return }
        secrets.set("\(type.rawValue):\(PinRules.hash(salt: deviceSalt(), profileId: profileId, type: type, normalized: n))", Self.KEY_PIN + profileId)
    }

    func backoff(_ profileId: String) -> PinBackoff { PinBackoff.decode(defaults.string(forKey: Self.KEY_BACKOFF + profileId)) }
    func saveBackoff(_ profileId: String, _ b: PinBackoff) { defaults.set(b.encode(), forKey: Self.KEY_BACKOFF + profileId) }
}
