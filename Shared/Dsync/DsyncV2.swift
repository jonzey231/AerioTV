//  DsyncV2.swift
//  Aerio
//
//  Dispatcharr Sync schema v3 (docs/DispatcharrSyncSchema.md): ONE App
//  Data key, `<username>.aeriotv` (DsyncKeyName), so AerioTV uses 1 of a user's 25. It
//  keeps the envelope and holds one sub-object per category under
//  `categories`, each with its own `updatedAt`, `deviceId`, `data`, and
//  optional `extra`. Port of the Android core/sync/dsync/DsyncV2.kt.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

enum DsyncBucket: String, CaseIterable, Sendable {
    /// Schema v3: ONE key holds every category. The raw value names the
    /// device-local cache only; the server key is `wire(user)`.
    case main = "app.molinete.aerio"

    func wire(_ userKey: String) -> String { userKey }
    var keys: [DsyncKey] { DsyncKey.allCases }

    static func of(_ key: DsyncKey) -> DsyncBucket { .main }
}

/// Dispatcharr App Data key names (schema section 2.1, 2026-11-05). The key is
/// `<user>.aeriotv`, where <user> is the signed-in Dispatcharr username:
/// ASCII A-Z lowercased; a-z, 0-9, `_`, `.`, and `-` kept; every other UTF-8
/// byte written as `-` plus two lowercase hex digits (percent-encoding with
/// `-` in place of `%`, which the server key pattern rejects); a `u` prefix
/// when the result does not start with a letter or digit; cut to 46
/// characters so `<user>.aeriotv.favorites` stays within the 64 the server
/// allows. Collisions cannot mix data: App Data is stored per user.
/// Android core/sync/dsync/DsyncV2.kt DsyncKeyName is identical.
enum DsyncKeyName {
    /// The key every release before 2026-11-05 used, plus its `.`-suffixed v1 and v2 keys.
    static let LEGACY_MAIN = "app.molinete.aerio"
    static let SUFFIX = ".aeriotv"
    static let MAX_USER = 64 - ".aeriotv.favorites".count

    static func user(_ username: String) -> String? {
        if username.isEmpty { return nil }
        let hex = Array("0123456789abcdef")
        var out = ""
        for b in username.utf8 {
            switch b {
            case 0x41...0x5A: out.append(Character(UnicodeScalar(b + 32)))
            case 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F: out.append(Character(UnicodeScalar(b)))
            default:
                out.append("-")
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
            }
        }
        if let f = out.unicodeScalars.first, !(("a"..."z").contains(f) || ("0"..."9").contains(f)) { out = "u" + out }
        return String(out.prefix(MAX_USER))
    }

    /// The main key for [username]; nil when the username is unknown.
    static func main(_ username: String) -> String? { user(username).map { $0 + SUFFIX } }
    /// The v2 three-key layout under the new name (never written by v3).
    static func v2Wires(_ main: String) -> Set<String> { [main, main + ".favorites", main + ".progress"] }
    static func isLegacy(_ name: String) -> Bool { name == LEGACY_MAIN || name.hasPrefix(LEGACY_MAIN + ".") }
    /// Any user's main key (the restore probe, which runs before the username is read).
    static func isMain(_ name: String) -> Bool { name.hasSuffix(SUFFIX) && name.count > SUFFIX.count && DsyncKey.isValidKeyName(name) }

    /// Legacy keys to move under [main]: every `app.molinete.aerio*` key, sorted,
    /// when [main] is absent from the list; empty when there is nothing to move.
    static func renamePlan(listed: [String], main: String) -> [String] {
        if listed.contains(main) { return [] }
        return listed.filter(isLegacy).sorted()
    }

    /// The value to PUT under the new key from the legacy keys' values: the
    /// legacy main key (v2 or v3) and its v1 and v2 sibling keys merge per
    /// category by updatedAt (DsyncV2.migrate). Nil when nothing decodes.
    static func renameValue(_ values: [(String, DsyncObject)], deviceId: String, appVersion: String, now: Int64) -> DsyncObject? {
        var v1: [(DsyncKey, DsyncEnvelope)] = []
        var v2: [DsyncV2.Bucket] = []
        var v3: DsyncObject?
        for (name, raw) in values {
            if name == LEGACY_MAIN {
                if let b = DsyncV2.decode(raw, min: DsyncV2.MIN_SUBOBJECT_SCHEMA).bucket {
                    if b.schemaVersion >= DsyncV2.SCHEMA { v3 = raw } else { v2.append(b) }
                }
                continue
            }
            if let k1 = DsyncKey.fromWire(name), let e = DsyncEnvelopeCodec.decode(raw, knownVersion: 1).envelope {
                v1.append((k1, e))
                continue
            }
            if let b = DsyncV2.decode(raw, min: DsyncV2.MIN_SUBOBJECT_SCHEMA).bucket { v2.append(b) }
        }
        return DsyncV2.migrate(v1: v1, v2: v2, v3: v3, deviceId: deviceId, appVersion: appVersion, now: now) ?? v3
    }
}

enum DsyncV2 {
    static let SCHEMA = 3
    /// The v2 sub-object shape is the same; only the key layout differed.
    static let MIN_SUBOBJECT_SCHEMA = 2
    static let CATEGORIES = "categories"

    /// A decoded key: envelope fields, raw category sub-objects by name, and the whole raw value.
    struct Bucket: Equatable, Sendable {
        let schemaVersion: Int
        let deviceId: String
        let platform: String
        let appVersion: String
        let updatedAt: Int64
        let categories: [String: DsyncObject]
        let raw: DsyncObject
    }

    enum Decode: Equatable, Sendable {
        case ok(Bucket)
        case malformed
        case tooNew(Int)

        var bucket: Bucket? {
            if case .ok(let b) = self { return b }
            return nil
        }
    }

    static func decode(_ raw: DsyncObject, known: Int = SCHEMA, min: Int = SCHEMA) -> Decode {
        guard let v = raw["schemaVersion"]?.asInt,
              let device = raw["deviceId"]?.asStr,
              let platform = raw["platform"]?.asStr,
              let app = raw["appVersion"]?.asStr,
              let at = raw["updatedAt"]?.asStr.flatMap(DsyncEnvelopeCodec.parseIso) else { return .malformed }
        if v > known { return .tooNew(v) }
        if v < min { return .malformed }
        guard let cats = raw[CATEGORIES]?.asObject else { return .malformed }
        var subs: [String: DsyncObject] = [:]
        for (k, e) in cats { if let o = e.asObject { subs[k] = o } }
        return .ok(Bucket(schemaVersion: v, deviceId: device, platform: platform, appVersion: app,
                          updatedAt: at, categories: subs, raw: raw))
    }

    /// One category as an envelope, so the v1 per-category logic runs as is.
    /// Nil when the category is absent; .malformed when it lacks `updatedAt` or `data`.
    static func category(_ b: Bucket, _ key: DsyncKey) -> DsyncDecode? {
        guard let sub = b.categories[key.suffix] else { return nil }
        guard let at = sub["updatedAt"]?.asStr.flatMap(DsyncEnvelopeCodec.parseIso),
              let data = sub["data"]?.asObject else { return .malformed }
        let dev = sub["deviceId"]?.asStr ?? b.deviceId
        var extra: DsyncObject?
        switch sub["extra"] {
        case nil, .null?: extra = nil
        case .object(let o)?: extra = o
        default: return .malformed
        }
        return .ok(DsyncEnvelope(schemaVersion: b.schemaVersion, deviceId: dev, platform: b.platform,
                                 appVersion: b.appVersion, updatedAt: at, data: data, extra: extra, raw: sub))
    }

    /// A category sub-object; unknown members and `extra` of [previous] are re-emitted.
    static func encodeCategory(_ previous: DsyncObject?, deviceId: String, updatedAt: Int64, data: DsyncObject) -> DsyncObject {
        var out = DsyncObject()
        out["updatedAt"] = .string(DsyncEnvelopeCodec.isoSeconds(updatedAt))
        out["deviceId"] = .string(deviceId)
        out["data"] = .object(data)
        for (k, v) in previous ?? DsyncObject() where !out.contains(k) { out[k] = v }
        return out
    }

    /// The value to PUT for one key. Starts from [previous] so categories this
    /// device did not touch, unknown categories, and unknown envelope members
    /// round-trip; [replace] swaps in the categories this device rebuilt.
    static func encodeBucket(_ previous: DsyncObject?, deviceId: String, appVersion: String, updatedAt: Int64,
                             replace: [(DsyncKey, DsyncObject)]) -> DsyncObject {
        var cats = previous?[CATEGORIES]?.asObject ?? DsyncObject()
        for (k, v) in replace { cats[k.suffix] = .object(v) }
        var out = DsyncObject()
        out["schemaVersion"] = .int(SCHEMA)
        out["deviceId"] = .string(deviceId)
        out["platform"] = .string(DsyncPlatform.current)
        out["appVersion"] = .string(appVersion)
        out["updatedAt"] = .string(DsyncEnvelopeCodec.isoSeconds(updatedAt))
        out[CATEGORIES] = .object(cats)
        for (k, v) in previous ?? DsyncObject() where !out.contains(k) { out[k] = v }
        return out
    }

    /// One 413 trim step on one category's `data`.
    struct Trim: Sendable {
        let key: DsyncKey
        let label: String
        let apply: @Sendable (DsyncObject) -> DsyncObject
    }

    private static func keepNewest(_ d: DsyncObject, _ atPos: Int, _ n: Int) -> DsyncObject {
        let rows = d["rows"]?.asArray?.compactMap(\.asArray) ?? []
        let kept = rows.stableSorted(by: { $0.count > atPos ? ($0[atPos].asLong ?? 0) : 0 }, descending: true).prefix(n)
        return d.with(("rows", .array(kept.map { .array($0) })))
    }

    /// The 413 trim sequence (schema v3, section 8), one step per retry.
    static let TRIMS: [Trim] = [
        Trim(key: .progress, label: "progress: oldest down to 200") { keepNewest($0, 4, 200) },
        Trim(key: .progress, label: "progress: oldest down to 100") { keepNewest($0, 4, 100) },
        Trim(key: .recents, label: "recents: down to 25") { keepNewest($0, 1, 25) },
        Trim(key: .watchlist, label: "watchlist: oldest down to 300") { keepNewest($0, 2, 300) },
        Trim(key: .hiddenTitles, label: "hiddenTitles: oldest down to 300") { keepNewest($0, 2, 300) },
        Trim(key: .watchlist, label: "watchlist: oldest down to 150") { keepNewest($0, 2, 150) },
        Trim(key: .hiddenTitles, label: "hiddenTitles: oldest down to 150") { keepNewest($0, 2, 150) },
        Trim(key: .favorites, label: "favorites: down to 500") { d in
            guard let ids = d["ids"]?.asArray else { return d }
            return d.with(("ids", .array(Array(ids.prefix(500)))))
        },
    ]

    /// Apply trim [step] to [value]; nil when that category is absent (skip to the next step).
    static func applyTrim(_ value: DsyncObject, _ step: Int) -> DsyncObject? {
        guard step >= 0, step < TRIMS.count else { return nil }
        let t = TRIMS[step]
        guard let cats = value[CATEGORIES]?.asObject,
              let sub = cats[t.key.suffix]?.asObject,
              let data = sub["data"]?.asObject else { return nil }
        let newSub = sub.with(("data", .object(t.apply(data))))
        return value.with((CATEGORIES, .object(cats.with((t.key.suffix, .object(newSub))))))
    }

    /// A category from a v1 envelope as a v3 sub-object (keeps updatedAt, deviceId, data, extra).
    static func subFromV1(_ e: DsyncEnvelope) -> DsyncObject {
        var sub = DsyncObject()
        sub["updatedAt"] = .string(DsyncEnvelopeCodec.isoSeconds(e.updatedAt))
        sub["deviceId"] = .string(e.deviceId)
        sub["data"] = .object(e.data)
        if let x = e.extra { sub["extra"] = .object(x) }
        return sub
    }

    /// Migration to the single key: every category from the v1 keys, the v2
    /// keys, and an existing v3 value merges per category by updatedAt (ties:
    /// higher deviceId). Nil when there is nothing to migrate.
    static func migrate(v1: [(DsyncKey, DsyncEnvelope)], v2: [Bucket], v3: DsyncObject?,
                        deviceId: String, appVersion: String, now: Int64) -> DsyncObject? {
        if v1.isEmpty && v2.isEmpty { return nil }
        var best = DsyncOrderedMap<String, (DsyncEnvelope, DsyncObject)>()
        func offer(_ name: String, _ e: DsyncEnvelope, _ sub: DsyncObject) {
            if let cur = best[name] {
                if DsyncEnvelopeCodec.remoteWins(localAt: cur.0.updatedAt, localDevice: cur.0.deviceId,
                                                 remoteAt: e.updatedAt, remoteDevice: e.deviceId) { best[name] = (e, sub) }
            } else {
                best[name] = (e, sub)
            }
        }
        for (k, e) in v1 { offer(k.suffix, e, subFromV1(e)) }
        for b in v2 {
            for k in DsyncKey.allCases { if let e = category(b, k)?.envelope { offer(k.suffix, e, e.raw) } }
        }
        if let v3b = v3.flatMap({ decode($0).bucket }) {
            for k in DsyncKey.allCases { if let e = category(v3b, k)?.envelope { offer(k.suffix, e, e.raw) } }
        }
        var replace: [(DsyncKey, DsyncObject)] = []
        for (name, p) in best.entries { if let k = DsyncKey(rawValue: name) { replace.append((k, p.1)) } }
        return encodeBucket(v3, deviceId: deviceId, appVersion: appVersion, updatedAt: now, replace: replace)
    }
}
