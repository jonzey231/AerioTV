//  DsyncSchema.swift
//  Aerio
//
//  Dispatcharr Sync v1, the pure half: keys, envelope, payload codecs,
//  caps, merge rules, trim order, and size guards, exactly as
//  docs/DispatcharrSyncSchema.md defines them. Port of the Android
//  core/sync/dsync/DsyncSchema.kt (source of truth); identifiers keep the
//  Android names in Swift style so the two diff by eye. Android's
//  DriveCanon is CloudCanon here and driveFileFor is cloudFileFor, since
//  the Apple cloud provider is iCloud.
//
//  Pure: no UIKit, no SwiftData, no singletons (Scripts/dsync-tests).

import Foundation
import CryptoKit

enum DsyncKey: String, CaseIterable, Sendable {
    case favorites, recents, progress, reminders, watchlist, hiddenTitles, hiddenGroups, groupOrder,
         settings, remoteMap, radioDefault, collections, profiles, tmdbKey

    var suffix: String { rawValue }

    /// Which Sync Categories toggle gates this key; nil = always (profiles,
    /// and tmdbKey, which syncs whenever Dispatcharr Sync is on and never
    /// through iCloud or Drive: section 4.13).
    var category: DsyncCategory? {
        switch self {
        case .favorites, .recents, .collections: return .favorites
        case .progress: return .watchProgress
        case .reminders: return .reminders
        case .watchlist, .hiddenTitles: return .watchlist
        case .hiddenGroups, .groupOrder, .settings, .remoteMap, .radioDefault: return .preferences
        case .profiles, .tmdbKey: return nil
        }
    }

    var schemaVersion: Int { 1 }

    var wire: String { Self.PREFIX + suffix }

    static let PREFIX = "app.molinete.aerio."
    private static let KEY_PATTERN = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$")
    static func fromWire(_ name: String) -> DsyncKey? { allCases.first { $0.wire == name } }
    static func isValidKeyName(_ name: String) -> Bool { dsyncMatches(KEY_PATTERN, name) }
}

func dsyncMatches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// The platform string the envelope carries (schema section 3).
enum DsyncPlatform {
    #if os(tvOS)
    static let current = "tvos"
    #else
    static let current = "ios"
    #endif
}

enum DsyncLimits {
    // Dispatcharr dev c1920131 (2026-10-18): one DB row per (user, key); caps
    // 128 KiB per key and 1 MiB per user (apps/accounts/app_data.py). The
    // server answers 413 with value_too_large / total_too_large; trimming
    // stays 413-driven.
    static let KEY_BYTES = 128 * 1024
    static let TOTAL_BYTES = 1024 * 1024
    static let FAVORITES = 1000
    static let RECENTS = 50
    static let PROGRESS = 300
    static let REMINDERS = 200
    static let WATCHLIST = 500
    static let HIDDEN_TITLES = 500
    static let GROUP_NAMES = 500
    static let COLLECTIONS = 50
    static let COLLECTION_MEMBERS = 500
    static let PROFILES = 25
    static let PROGRESS_TITLE_BYTES = 40
    static let REMINDER_TITLE_BYTES = 60
    static let CHANNEL_NAME_BYTES = 40
    static let COLLECTION_NAME_BYTES = 40
    static let DISPLAY_NAME_BYTES = 40
    static let CUSTOM_CATEGORIES_BYTES = 4 * 1024
    static let FINISHED_MAX_AGE_S: Int64 = 30 * 24 * 3600
}

/// Envelope (section 3). [raw] is the whole stored object, kept for round-trip.
struct DsyncEnvelope: Equatable, Sendable {
    let schemaVersion: Int
    let deviceId: String
    let platform: String
    let appVersion: String
    /// Unix seconds parsed from the ISO 8601 `updatedAt`.
    let updatedAt: Int64
    let data: DsyncObject
    let extra: DsyncObject?
    let raw: DsyncObject
}

enum DsyncDecode: Equatable, Sendable {
    case ok(DsyncEnvelope)
    case malformed
    case tooNew(Int)

    var envelope: DsyncEnvelope? {
        if case .ok(let e) = self { return e }
        return nil
    }
}

enum DsyncEnvelopeCodec {
    /// "2026-11-02T10:00:00Z" (ISO_INSTANT, whole seconds).
    static func isoSeconds(_ unixSeconds: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    /// Instant.parse: accepts whole or fractional seconds, Z or an offset.
    static func parseIso(_ s: String) -> Int64? {
        let a = ISO8601DateFormatter()
        a.formatOptions = [.withInternetDateTime]
        if let d = a.date(from: s) { return Int64(d.timeIntervalSince1970.rounded(.down)) }
        let b = ISO8601DateFormatter()
        b.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = b.date(from: s) { return Int64(d.timeIntervalSince1970.rounded(.down)) }
        return nil
    }

    /// Reader rules 1 and 2. A lower schemaVersion decodes (rule 3: upgrade in memory).
    static func decode(_ raw: DsyncObject, knownVersion: Int) -> DsyncDecode {
        guard let v = raw["schemaVersion"]?.asInt,
              let device = raw["deviceId"]?.asStr,
              let platform = raw["platform"]?.asStr,
              let app = raw["appVersion"]?.asStr,
              let at = raw["updatedAt"]?.asStr.flatMap(parseIso),
              let data = raw["data"]?.asObject else { return .malformed }
        var extra: DsyncObject?
        switch raw["extra"] {
        case nil, .null?: extra = nil
        case .object(let o)?: extra = o
        default: return .malformed
        }
        if v > knownVersion { return .tooNew(v) }
        return .ok(DsyncEnvelope(schemaVersion: v, deviceId: device, platform: platform, appVersion: app,
                                 updatedAt: at, data: data, extra: extra, raw: raw))
    }

    /// The value to PUT. Starts from [previous] so unknown envelope members
    /// and `extra` are re-emitted untouched.
    static func encode(key: DsyncKey, previous: DsyncObject?, deviceId: String, appVersion: String,
                       updatedAt: Int64, data: DsyncObject) -> DsyncObject {
        var out = DsyncObject()
        out["schemaVersion"] = .int(key.schemaVersion)
        out["deviceId"] = .string(deviceId)
        out["platform"] = .string(DsyncPlatform.current)
        out["appVersion"] = .string(appVersion)
        out["updatedAt"] = .string(isoSeconds(updatedAt))
        out["data"] = .object(data)
        for (k, v) in previous ?? DsyncObject() where !out.contains(k) { out[k] = v }
        return out
    }

    static func byteSize(_ value: DsyncObject) -> Int { DsyncJSONEncoder.byteSize(value) }

    /// Rule 6.1: remote wins when strictly newer; ties go to the higher deviceId.
    static func remoteWins(localAt: Int64, localDevice: String, remoteAt: Int64, remoteDevice: String) -> Bool {
        remoteAt > localAt || (remoteAt == localAt && remoteDevice > localDevice)
    }
}

/// Truncate to at most [maxBytes] UTF-8 bytes on a code point boundary.
func truncateUtf8(_ s: String, _ maxBytes: Int) -> String {
    if s.utf8.count <= maxBytes { return s }
    var out = String.UnicodeScalarView()
    var used = 0
    for u in s.unicodeScalars {
        let n = String(u).utf8.count
        if used + n > maxBytes { break }
        out.append(u)
        used += n
    }
    return String(out)
}

/// A decoded row: trailing positions a newer writer appended.
struct Tail: Equatable, Sendable {
    var extra: [DsyncJSON] = []
}

private func tailOf(_ row: [DsyncJSON], _ known: Int) -> Tail {
    row.count > known ? Tail(extra: Array(row[known...])) : Tail()
}

private func plusTail(_ a: [DsyncJSON], _ t: Tail) -> DsyncJSON { .array(a + t.extra) }

private extension Array where Element == DsyncJSON {
    func at(_ i: Int) -> DsyncJSON? { i < count ? self[i] : nil }
}

// MARK: - Payload models (section 4)

struct RecentRow: Equatable, Sendable {
    var channelId: Int
    var watchedAt: Int64
    var tail = Tail()
}

struct ProgressRow: Equatable, Sendable {
    /// Dispatcharr integer primary key of the movie or episode.
    var vodId: Int
    var type: String
    var position: Int64
    var duration: Int64
    var updatedAt: Int64
    var finished: Bool
    /// Dispatcharr integer series id; nil for movies.
    var seriesId: Int?
    var season: Int
    var episode: Int
    var title: String
    var tail = Tail()
}

struct ReminderRow: Equatable, Sendable {
    var channelId: Int
    var start: Int64
    var end: Int64
    var title: String
    var channelName: String
    var tail = Tail()
}

/// watchlist and hiddenTitles: `[vodId, "m"|"s", at]`.
struct VodMarkRow: Equatable, Sendable {
    var vodId: Int
    var type: String
    var at: Int64
    var tail = Tail()
}

struct CollectionRow: Equatable, Sendable {
    var id: String
    var name: String
    var placement: String
    var members: [Int]
    var tail = Tail()
}

/// Android core/profiles AvatarSpec.
struct AvatarSpec: Equatable, Sendable {
    /// One of AvatarCatalog.ICONS; "initial" draws the display name's first letter.
    var icon: String = AvatarCatalog.INITIAL
    /// One of AvatarCatalog.COLORS; "" = the username's default color.
    var color: String = ""
}

/// Android core/profiles AvatarCatalog (the parts the schema reads).
enum AvatarCatalog {
    static let INITIAL = "initial"
    static let ICONS = ["person", "face", "child", "paw", "cat", "fish",
                        "star", "rocket", "music", "soccer", "gamepad", "movie"]
    static let COLORS = ["teal", "blue", "orange", "ember", "green", "purple", "slate", "sea"]

    /// Normalize a pulled or picked spec: unknown ids fall back; all default = nil.
    static func normalize(_ spec: AvatarSpec?) -> AvatarSpec? {
        guard let spec else { return nil }
        let icon = ICONS.contains(spec.icon) ? spec.icon : INITIAL
        let color = COLORS.contains(spec.color) ? spec.color : ""
        return (icon == INITIAL && color.isEmpty) ? nil : AvatarSpec(icon: icon, color: color)
    }
}

struct ProfileRow: Equatable, Sendable {
    var userId: Int
    var username: String
    var displayName: String
    var pinType: String
    var pinHash: String
    var pinSalt: String
    /// "admin" | "user" | "child"; "" = absent (older writer), reader keeps its own.
    var role: String = ""
    /// Unix seconds of the last change to name, PIN, role, or avatar; 0 = absent.
    var updatedAt: Int64 = 0
    /// Position 8, `{"icon","color"}`; nil = absent (older writer).
    var avatar: AvatarSpec? = nil
    /// Position 9, list position (0 first); -1 = absent (insertion order).
    var order: Int = -1
    var tail = Tail()
}

/// A profile removal carried in the synced `profiles` payload (schema 4.12).
struct ProfileTombstone: Equatable, Sendable {
    /// Lowercased username.
    var username: String
    /// Unix seconds of the removal.
    var removedAt: Int64
    var userId: Int? = nil
}

/// Removal tombstones for `profiles` (schema 4.12).
enum ProfileTombstones {
    static let WINDOW_S: Int64 = 90 * 86_400

    /// Union by username; the newer removal wins.
    static func union(_ a: [ProfileTombstone], _ b: [ProfileTombstone]) -> [ProfileTombstone] {
        (a + b).groupedOrdered { $0.username.lowercased() }.map { u, l in
            var top = l.maxByFirst { $0.removedAt }!
            top.username = u
            top.userId = top.userId ?? l.compactMap(\.userId).first
            return top
        }
    }

    static func expire(_ t: [ProfileTombstone], now: Int64) -> [ProfileTombstone] { t.filter { now - $0.removedAt <= WINDOW_S } }

    static func find(_ t: [ProfileTombstone], _ username: String) -> ProfileTombstone? {
        t.first { $0.username.lowercased() == username.lowercased() }
    }

    /// True when a tombstone removes a row last changed at [updatedAt].
    static func kills(_ t: [ProfileTombstone], _ username: String, _ updatedAt: Int64) -> Bool {
        find(t, username).map { $0.removedAt >= updatedAt } == true
    }

    struct Resolved: Equatable, Sendable {
        let rows: [ProfileRow]
        let removed: [ProfileTombstone]
        let dropped: [ProfileRow]
    }

    /// Drop tombstoned rows; a row newer than its tombstone keeps the row and clears the tombstone.
    static func resolve(_ rows: [ProfileRow], _ removed: [ProfileTombstone]) -> Resolved {
        let dropped = rows.filter { kills(removed, $0.username, $0.updatedAt) }
        let kept = rows.filter { !kills(removed, $0.username, $0.updatedAt) }
        let revived = Set(kept.map { $0.username.lowercased() })
        return Resolved(rows: kept, removed: removed.filter { !revived.contains($0.username) }, dropped: dropped)
    }

    /// Stale-device guard (schema 4.12).
    static func staleLocal(_ row: ProfileRow, serverRows: [ProfileRow], serverUpdatedAt: Int64,
                           localNewest: Int64, lastPushedAt: Int64) -> Bool {
        if serverRows.isEmpty { return false }
        if serverRows.contains(where: { $0.username.lowercased() == row.username.lowercased() }) { return false }
        if row.updatedAt > lastPushedAt { return false }
        let serverNewest = serverRows.map(\.updatedAt).max()!
        return row.updatedAt < serverUpdatedAt || serverNewest - localNewest > WINDOW_S
    }
}

/// Codecs. Each `decodeX` returns nil on a wrong shape (the caller logs
/// malformed and leaves the key alone). Each `encodeX` replaces only the
/// members it owns in [base] (the last pulled `data`, rule 6.2).
enum DsyncPayloads {

    private static func rows(_ data: DsyncObject) -> [DsyncJSON]? {
        guard let r = data["rows"] else { return [] }
        return r.asArray
    }

    /// Decodes every element of [rows] as an array row, or nil on the first bad one.
    private static func mapRows<T>(_ data: DsyncObject, _ f: ([DsyncJSON]) -> T?) -> [T]? {
        guard let rs = rows(data) else { return nil }
        var out: [T] = []
        for el in rs {
            guard let r = el.asArray, let t = f(r) else { return nil }
            out.append(t)
        }
        return out
    }

    // favorites
    static func decodeFavorites(_ data: DsyncObject) -> [Int]? {
        guard let el = data["ids"] else { return [] }
        guard let arr = el.asArray else { return nil }
        var out: [Int] = []
        for e in arr { guard let i = e.asInt else { return nil }; out.append(i) }
        return out
    }
    static func encodeFavorites(_ base: DsyncObject?, _ ids: [Int]) -> DsyncObject {
        base.with(("ids", .array(ids.distinctOrdered().prefix(DsyncLimits.FAVORITES).map { .int($0) })))
    }

    // recents
    static func decodeRecents(_ data: DsyncObject) -> [RecentRow]? {
        mapRows(data) { r in
            guard let c = r.at(0)?.asInt, let w = r.at(1)?.asLong else { return nil }
            return RecentRow(channelId: c, watchedAt: w, tail: tailOf(r, 2))
        }
    }
    static func encodeRecents(_ base: DsyncObject?, _ rows: [RecentRow]) -> DsyncObject {
        base.with(("rows", .array(capRecents(rows).map { plusTail([.int($0.channelId), .long($0.watchedAt)], $0.tail) })))
    }
    static func capRecents(_ rows: [RecentRow], cap: Int = DsyncLimits.RECENTS) -> [RecentRow] {
        Array(rows.groupedOrdered { $0.channelId }.map { $0.1.maxByFirst { $0.watchedAt }! }
            .stableSorted(by: { $0.watchedAt }, descending: true).prefix(cap))
    }

    // progress
    static func decodeProgress(_ data: DsyncObject) -> [ProgressRow]? {
        mapRows(data) { r in
            guard let id = r.at(0)?.asInt, let type = r.at(1)?.asStr,
                  let pos = r.at(2)?.asLong, let at = r.at(4)?.asLong else { return nil }
            return ProgressRow(
                vodId: id, type: type, position: pos, duration: r.at(3)?.asLong ?? 0, updatedAt: at,
                finished: (r.at(5)?.asInt ?? 0) == 1, seriesId: r.at(6)?.asInt,
                season: r.at(7)?.asInt ?? 0, episode: r.at(8)?.asInt ?? 0, title: r.at(9)?.asStr ?? "",
                tail: tailOf(r, 10))
        }
    }
    static func progressRowJson(_ p: ProgressRow, titleBytes: Int = DsyncLimits.PROGRESS_TITLE_BYTES) -> DsyncJSON {
        plusTail([
            .int(p.vodId), .string(p.type), .long(p.position), .long(p.duration),
            .long(p.updatedAt), .int(p.finished ? 1 : 0),
            p.seriesId.map { .int($0) } ?? .null,
            .int(p.season), .int(p.episode), .string(truncateUtf8(p.title, titleBytes)),
        ], p.tail)
    }
    static func encodeProgress(_ base: DsyncObject?, _ rows: [ProgressRow], now: Int64) -> DsyncObject {
        base.with(("rows", .array(capProgress(rows, now: now).map { progressRowJson($0) })))
    }
    /// Finished rows older than 30 days go first, then the 300 newest by updatedAt stay.
    static func capProgress(_ rows: [ProgressRow], now: Int64, cap: Int = DsyncLimits.PROGRESS) -> [ProgressRow] {
        Array(rows.groupedOrdered { "\($0.type)|\($0.vodId)" }.map { $0.1.maxByFirst { $0.updatedAt }! }
            .filter { !($0.finished && now - $0.updatedAt > DsyncLimits.FINISHED_MAX_AGE_S) }
            .stableSorted(by: { $0.updatedAt }, descending: true).prefix(cap))
    }

    // reminders
    static func decodeReminders(_ data: DsyncObject) -> [ReminderRow]? {
        mapRows(data) { r in
            guard let c = r.at(0)?.asInt, let s = r.at(1)?.asLong, let e = r.at(2)?.asLong else { return nil }
            return ReminderRow(channelId: c, start: s, end: e, title: r.at(3)?.asStr ?? "",
                               channelName: r.at(4)?.asStr ?? "", tail: tailOf(r, 5))
        }
    }
    static func encodeReminders(_ base: DsyncObject?, _ rows: [ReminderRow], now: Int64) -> DsyncObject {
        base.with(("rows", .array(capReminders(rows, now: now).map {
            plusTail([
                .int($0.channelId), .long($0.start), .long($0.end),
                .string(truncateUtf8($0.title, DsyncLimits.REMINDER_TITLE_BYTES)),
                .string(truncateUtf8($0.channelName, DsyncLimits.CHANNEL_NAME_BYTES)),
            ], $0.tail)
        })))
    }
    /// Future only (end not in the past), soonest first, cap 200.
    static func capReminders(_ rows: [ReminderRow], now: Int64, cap: Int = DsyncLimits.REMINDERS) -> [ReminderRow] {
        Array(rows.filter { $0.end >= now }.distinctBy { "\($0.channelId)|\($0.start)" }
            .stableSorted(by: { $0.start }).prefix(cap))
    }

    // watchlist / hiddenTitles
    static func decodeVodMarks(_ data: DsyncObject) -> [VodMarkRow]? {
        mapRows(data) { r in
            guard let id = r.at(0)?.asInt, let t = r.at(1)?.asStr else { return nil }
            return VodMarkRow(vodId: id, type: t, at: r.at(2)?.asLong ?? 0, tail: tailOf(r, 3))
        }
    }
    static func encodeVodMarks(_ base: DsyncObject?, _ rows: [VodMarkRow], cap: Int) -> DsyncObject {
        base.with(("rows", .array(capVodMarks(rows, cap: cap).map { plusTail([.int($0.vodId), .string($0.type), .long($0.at)], $0.tail) })))
    }
    static func capVodMarks(_ rows: [VodMarkRow], cap: Int) -> [VodMarkRow] {
        Array(rows.distinctBy { "\($0.type)|\($0.vodId)" }.stableSorted(by: { $0.at }, descending: true).prefix(cap))
    }

    // hiddenGroups
    struct HiddenGroups: Equatable, Sendable {
        var live: [String]
        var movies: [String]
        var series: [String]
    }
    private static func stringList(_ el: DsyncJSON?) -> [String]? {
        guard let el else { return [] }
        guard let arr = el.asArray else { return nil }
        var out: [String] = []
        for e in arr { guard let s = e.asStr else { return nil }; out.append(s) }
        return out
    }
    static func decodeHiddenGroups(_ data: DsyncObject) -> HiddenGroups? {
        guard let l = stringList(data["live"]), let m = stringList(data["movies"]), let s = stringList(data["series"]) else { return nil }
        return HiddenGroups(live: l, movies: m, series: s)
    }
    static func encodeHiddenGroups(_ base: DsyncObject?, _ g: HiddenGroups) -> DsyncObject {
        func arr(_ l: [String]) -> DsyncJSON { .array(l.distinctOrdered().prefix(DsyncLimits.GROUP_NAMES).map { .string($0) }) }
        return base.with(("live", arr(g.live)), ("movies", arr(g.movies)), ("series", arr(g.series)))
    }

    // groupOrder
    struct GroupOrder: Equatable, Sendable {
        var mode: String
        var order: [String]
    }
    static let GROUP_MODES: Set<String> = ["default", "alphabetical", "manual"]
    static func decodeGroupOrder(_ data: DsyncObject) -> GroupOrder? {
        var mode = "default"
        if let m = data["mode"] { guard let s = m.asStr else { return nil }; mode = s }
        guard let order = stringList(data["order"]) else { return nil }
        return GroupOrder(mode: mode, order: order)
    }
    static func encodeGroupOrder(_ base: DsyncObject?, _ g: GroupOrder) -> DsyncObject {
        base.with(("mode", .string(g.mode)),
                  ("order", .array(g.order.distinctOrdered().prefix(DsyncLimits.GROUP_NAMES).map { .string($0) })))
    }

    // settings
    private static func primitives(_ o: DsyncObject) -> [String: DsyncJSON] {
        var out: [String: DsyncJSON] = [:]
        for (k, e) in o where e.isPrimitive && e != .null { out[k] = e }
        return out
    }
    static func decodeSettings(_ data: DsyncObject) -> [String: DsyncJSON]? {
        guard let v = data["v"] else { return [:] }
        guard let obj = v.asObject else { return nil }
        return primitives(obj)
    }
    /// `settings` lanes (4.9): `v` (all devices), `tv`, and `mobile`. Absent
    /// lanes decode as empty (left out); a lane that is not an object is malformed.
    static func decodeSettingsLanes(_ data: DsyncObject) -> [String: [String: DsyncJSON]]? {
        var out: [String: [String: DsyncJSON]] = [:]
        for lane in SETTINGS_LANES {
            guard let e = data[lane] else { continue }
            guard let obj = e.asObject else { return nil }
            out[lane] = primitives(obj)
        }
        return out
    }

    /// Writes [lanes] over [base]'s lanes; every name not written round-trips untouched (rule 7).
    static func encodeSettingsLanes(_ base: DsyncObject?, _ lanes: [String: [String: DsyncJSON]]) -> DsyncObject {
        var out = base ?? DsyncObject()
        for lane in SETTINGS_LANES {
            let mine = lanes[lane] ?? [:]
            let prev = base?[lane]?.asObject
            if mine.isEmpty && prev == nil { continue }
            var m = prev ?? DsyncObject()
            for k in mine.keys.sorted() { m[k] = mine[k] }
            out[lane] = .object(m)
        }
        return out
    }

    static let SETTINGS_LANES = ["v", "tv", "mobile"]

    static func encodeSettings(_ base: DsyncObject?, owned: Set<String>, values: [String: DsyncJSON]) -> DsyncObject {
        var m = base?["v"]?.asObject ?? DsyncObject()
        for k in values.keys.sorted() where owned.contains(k) { m[k] = values[k] }
        return base.with(("v", .object(m)))
    }

    // remoteMap: `tv` is opaque to this codec.
    static func decodeRemoteMap(_ data: DsyncObject) -> DsyncObject? {
        guard let tv = data["tv"] else { return DsyncObject() }
        return tv.asObject
    }
    static func encodeRemoteMap(_ base: DsyncObject?, _ tv: DsyncObject) -> DsyncObject { base.with(("tv", .object(tv))) }

    // radioDefault
    static func decodeRadioDefault(_ data: DsyncObject) -> Bool? {
        guard let on = data["on"] else { return false }
        return on.asBool
    }
    static func encodeRadioDefault(_ base: DsyncObject?, _ on: Bool) -> DsyncObject { base.with(("on", .bool(on))) }

    // tmdbKey (section 4.13): the user's TMDB API key or read access token,
    // trimmed; "" (or a missing member) = no key, so clearing syncs too.
    // A non-string apiKey is malformed.
    static func decodeTMDBKey(_ data: DsyncObject) -> String? {
        guard let v = data["apiKey"] else { return "" }
        return v.asStr?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func encodeTMDBKey(_ base: DsyncObject?, _ key: String) -> DsyncObject {
        base.with(("apiKey", .string(key.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    /// Newest edit wins for the TMDB key, checked when a newer remote value
    /// arrives (section 4.13): true = keep this device's key and send it.
    /// [localEditedAt] is when the key was last set or cleared on this
    /// device by its user, or applied from the server (Unix seconds; 0 =
    /// unknown: set before this build, or arrived through iCloud Keychain).
    /// With an unknown time a key beats a clear, so a stale clear on the
    /// server never wipes a key (a Keychain delete would spread to every
    /// Apple device).
    static func tmdbKeepsLocal(local: String, remote: String, localEditedAt: Int64, remoteAt: Int64) -> Bool {
        if local == remote { return false }
        if localEditedAt > 0 { return localEditedAt > remoteAt }
        return remote.isEmpty && !local.isEmpty
    }

    // collections
    static func decodeCollections(_ data: DsyncObject) -> [CollectionRow]? {
        mapRows(data) { r in
            guard let id = r.at(0)?.asStr else { return nil }
            var members: [Int] = []
            if let arr = r.at(3)?.asArray {
                for m in arr { guard let i = m.asInt else { return nil }; members.append(i) }
            }
            return CollectionRow(id: id, name: r.at(1)?.asStr ?? "", placement: r.at(2)?.asStr ?? "e",
                                 members: members, tail: tailOf(r, 4))
        }
    }
    static func encodeCollections(_ base: DsyncObject?, _ rows: [CollectionRow]) -> DsyncObject {
        base.with(("rows", .array(rows.distinctBy { $0.id }.prefix(DsyncLimits.COLLECTIONS).map {
            plusTail([
                .string($0.id),
                .string(truncateUtf8($0.name, DsyncLimits.COLLECTION_NAME_BYTES)),
                .string($0.placement == "b" ? "b" : "e"),
                .array($0.members.prefix(DsyncLimits.COLLECTION_MEMBERS).map { .int($0) }),
            ], $0.tail)
        })))
    }

    // profiles
    static let PIN_TYPES: Set<String> = ["none", "numbers", "directions"]
    static let ROLES: Set<String> = ["admin", "user", "child"]
    static func decodeProfiles(_ data: DsyncObject) -> [ProfileRow]? {
        mapRows(data) { r in
            guard let uid = r.at(0)?.asInt, let user = r.at(1)?.asStr else { return nil }
            return ProfileRow(
                userId: uid, username: user, displayName: r.at(2)?.asStr ?? "",
                pinType: r.at(3)?.asStr.flatMap { PIN_TYPES.contains($0) ? $0 : nil } ?? "none",
                pinHash: r.at(4)?.asStr ?? "", pinSalt: r.at(5)?.asStr ?? "",
                role: r.at(6)?.asStr.flatMap { ROLES.contains($0) ? $0 : nil } ?? "",
                updatedAt: r.at(7)?.asLong ?? 0,
                avatar: decodeAvatar(r.at(8)),
                order: r.at(9)?.asInt.flatMap { $0 >= 0 ? $0 : nil } ?? -1,
                tail: tailOf(r, 10))
        }
    }
    /// `removed` (schema 4.12): `[[usernameLowercase, removedAt, userId?], ...]`; absent = none.
    static func decodeProfileTombstones(_ data: DsyncObject?) -> [ProfileTombstone] {
        (data?["removed"]?.asArray ?? []).compactMap { el in
            guard let r = el.asArray,
                  let u = r.at(0)?.asStr?.lowercased(), !u.isEmpty,
                  let at = r.at(1)?.asLong, at > 0 else { return nil }
            return ProfileTombstone(username: u, removedAt: at, userId: r.at(2)?.asInt.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// encodeProfiles plus the `removed` list; an empty list drops the member.
    static func encodeProfiles(_ base: DsyncObject?, _ rows: [ProfileRow], removed: [ProfileTombstone]) -> DsyncObject {
        var m = encodeProfiles(base, rows)
        m["removed"] = nil
        if !removed.isEmpty {
            m["removed"] = .array(removed.distinctBy { $0.username }.map {
                .array([.string($0.username), .long($0.removedAt)] + ($0.userId.map { [DsyncJSON.int($0)] } ?? []))
            })
        }
        return m
    }

    static func encodeProfiles(_ base: DsyncObject?, _ rows: [ProfileRow]) -> DsyncObject {
        base.with(("rows", .array(rows.distinctBy { $0.userId }.prefix(DsyncLimits.PROFILES).map {
            let none = $0.pinType == "none"
            return plusTail([
                .int($0.userId), .string($0.username),
                .string(truncateUtf8($0.displayName, DsyncLimits.DISPLAY_NAME_BYTES)),
                .string($0.pinType),
                .string(none ? "" : $0.pinHash),
                .string(none ? "" : $0.pinSalt),
                .string(ROLES.contains($0.role) ? $0.role : "user"),
                .long($0.updatedAt),
                .object(encodeAvatar($0.avatar)),
                .int(max($0.order, 0)),
            ], $0.tail)
        })))
    }

    /// `{}` or a non-object reads as the default; unknown ids fall back per field.
    static func decodeAvatar(_ el: DsyncJSON?) -> AvatarSpec? {
        guard let el, el != .null else { return nil }
        guard let o = el.asObject else { return AvatarSpec() }
        return AvatarSpec(
            icon: o["icon"]?.asStr.flatMap { AvatarCatalog.ICONS.contains($0) ? $0 : nil } ?? AvatarCatalog.INITIAL,
            color: o["color"]?.asStr.flatMap { AvatarCatalog.COLORS.contains($0) ? $0 : nil } ?? "")
    }

    static func encodeAvatar(_ a: AvatarSpec?) -> DsyncObject {
        guard let n = AvatarCatalog.normalize(a) else { return DsyncObject() }
        var o = DsyncObject()
        if n.icon != AvatarCatalog.INITIAL { o["icon"] = .string(n.icon) }
        if !n.color.isEmpty { o["color"] = .string(n.color) }
        return o
    }

    /// Carry trailing positions from the last pulled rows onto our rebuilt rows (rule 6.2).
    static func carryTails<T>(_ ours: [T], _ remote: [T]?, id: (T) -> AnyHashable, tail: (T) -> Tail,
                              withTail: (T, Tail) -> T) -> [T] {
        guard let remote, !remote.isEmpty else { return ours }
        var byId: [AnyHashable: T] = [:]
        for r in remote { byId[id(r)] = r }
        return ours.map { o in
            if let r = byId[id(o)], tail(o).extra.isEmpty, !tail(r).extra.isEmpty { return withTail(o, tail(r)) }
            return o
        }
    }
}

/// Section 6.1 exception: row merge for progress and recents before writing.
enum DsyncMerge {
    static func progress(_ local: [ProgressRow], _ remote: [ProgressRow]) -> [ProgressRow] {
        var out = DsyncOrderedMap<String, ProgressRow>()
        for r in remote + local {
            let k = "\(r.type)|\(r.vodId)"
            let cur = out[k]
            if cur == nil || r.updatedAt >= cur!.updatedAt {
                var n = r
                if let cur, r.tail.extra.isEmpty { n.tail = cur.tail }
                out[k] = n
            }
        }
        return out.values.stableSorted(by: { $0.updatedAt }, descending: true)
    }

    static func recents(_ local: [RecentRow], _ remote: [RecentRow]) -> [RecentRow] {
        var out = DsyncOrderedMap<Int, RecentRow>()
        for r in remote + local {
            let cur = out[r.channelId]
            if cur == nil || r.watchedAt >= cur!.watchedAt { out[r.channelId] = r }
        }
        return out.values.stableSorted(by: { $0.watchedAt }, descending: true)
    }
}

/// Pending-write and dirty-key rules (section 7).
enum DsyncGate {
    /// Keys merged row by row with the server copy when this device has an unsent change.
    static let ROW_MERGE_KEYS: Set<DsyncKey> = [.favorites, .recents, .progress, .collections, .reminders]

    /// Reminders union by identity (channelId, start); local row first.
    static func remindersUnion(_ local: [ReminderRow], _ remote: [ReminderRow]) -> [ReminderRow] {
        (local + remote).distinctBy { "\($0.channelId)|\($0.start)" }
    }

    /// A write queued by a session may go out only under that session's own
    /// profile token, after that session's first pull, for a key it has read.
    static func mayWrite(sessionToken: String, currentToken: String, firstPullDone: Bool, keyRead: Bool) -> Bool {
        sessionToken == currentToken && firstPullDone && keyRead
    }

    enum DirtyPull: Sendable { case takeRemote, merge, keepLocal }

    /// A newer pulled value against this device's unsent change ([dirtyAt], Unix seconds).
    static func onNewerPull(_ key: DsyncKey, dirty: Bool, dirtyAt: Int64, remoteAt: Int64) -> DirtyPull {
        if !dirty { return .takeRemote }
        if ROW_MERGE_KEYS.contains(key) { return .merge }
        if dirtyAt > remoteAt { return .keepLocal }
        return .takeRemote
    }

    /// Favorites union: local order first, then server ids this device lacks.
    static func favoritesUnion(_ local: [Int], _ remote: [Int]) -> [Int] { (local + remote).distinctOrdered() }

    /// Collections union by id; members of a shared collection are the union too.
    static func collectionsUnion(_ local: [CollectionRow], _ remote: [CollectionRow]) -> [CollectionRow] {
        var r: [String: CollectionRow] = [:]
        for c in remote where r[c.id] == nil { r[c.id] = c }
        let merged = local.map { l -> CollectionRow in
            guard let x = r[l.id] else { return l }
            var m = l
            m.members = (l.members + x.members).distinctOrdered()
            return m
        }
        let have = Set(local.map(\.id))
        return merged + remote.filter { !have.contains($0.id) }
    }

    /// Profiles merge per row: a pulled row replaces local fields only when strictly newer.
    static func profileRowWins(localUpdatedAt: Int64, remote: ProfileRow) -> Bool { remote.updatedAt > localUpdatedAt }
}

/// Section 8 trim order (v1 layout). Each step rewrites one key's `data`.
enum DsyncTrim {
    struct Step: Sendable {
        let key: DsyncKey
        let label: String
        let apply: @Sendable (DsyncObject, Int64) -> DsyncObject
    }

    private static func withRows(_ d: DsyncObject, _ rows: [DsyncJSON]) -> DsyncObject { d.with(("rows", .array(rows))) }

    private static func rowArrays(_ d: DsyncObject) -> [[DsyncJSON]] { d["rows"]?.asArray?.compactMap(\.asArray) ?? [] }

    static let STEPS: [Step] = [
        Step(key: .progress, label: "progress: drop finished") { d, _ in
            withRows(d, rowArrays(d).filter { $0.at(5)?.asInt != 1 }.map { .array($0) })
        },
        Step(key: .progress, label: "progress: oldest down to 200") { d, _ in
            withRows(d, rowArrays(d).stableSorted(by: { $0.at(4)?.asLong ?? 0 }, descending: true).prefix(200).map { .array($0) })
        },
        Step(key: .progress, label: "progress: titles to 20 B") { d, _ in
            withRows(d, rowArrays(d).map { r in
                guard let t = r.at(9)?.asStr else { return .array(r) }
                var m = r
                m[9] = .string(truncateUtf8(t, 20))
                return .array(m)
            })
        },
        Step(key: .reminders, label: "reminders: drop rows starting more than 14 days out") { d, now in
            withRows(d, rowArrays(d).filter { ($0.at(1)?.asLong ?? 0) <= now + 14 * 24 * 3600 }.map { .array($0) })
        },
        Step(key: .recents, label: "recents: down to 25") { d, _ in
            withRows(d, rowArrays(d).stableSorted(by: { $0.at(1)?.asLong ?? 0 }, descending: true).prefix(25).map { .array($0) })
        },
        Step(key: .watchlist, label: "watchlist: oldest down to 300") { d, _ in
            withRows(d, rowArrays(d).stableSorted(by: { $0.at(2)?.asLong ?? 0 }, descending: true).prefix(300).map { .array($0) })
        },
        Step(key: .hiddenTitles, label: "hiddenTitles: oldest down to 300") { d, _ in
            withRows(d, rowArrays(d).stableSorted(by: { $0.at(2)?.asLong ?? 0 }, descending: true).prefix(300).map { .array($0) })
        },
        Step(key: .settings, label: "settings: drop customCategories") { d, _ in
            guard let v = d["v"]?.asObject else { return d }
            return d.with(("v", .object(v.filterKeys { $0 != "customCategories" })))
        },
    ]

    static func stepsFor(_ key: DsyncKey) -> [Step] { STEPS.filter { $0.key == key } }

    /// Fit one key under 128 KiB; nil when every step ran and it still does not fit.
    static func fitKey(_ key: DsyncKey, _ data: DsyncObject, now: Int64, force: Bool = false,
                       wrap: (DsyncObject) -> DsyncObject) -> DsyncObject? {
        var d = data
        if !force && DsyncEnvelopeCodec.byteSize(wrap(d)) <= DsyncLimits.KEY_BYTES { return d }
        for s in stepsFor(key) {
            d = s.apply(d, now)
            if !force && DsyncEnvelopeCodec.byteSize(wrap(d)) <= DsyncLimits.KEY_BYTES { return d }
        }
        return DsyncEnvelopeCodec.byteSize(wrap(d)) <= DsyncLimits.KEY_BYTES ? d : nil
    }

    /// Fit the user total under 1 MiB, steps in the global order across keys.
    static func fitTotal(_ datas: [(DsyncKey, DsyncObject)], otherBytes: Int64, now: Int64,
                         wrap: (DsyncKey, DsyncObject) -> DsyncObject) -> [(DsyncKey, DsyncObject)]? {
        var m = DsyncOrderedMap<DsyncKey, DsyncObject>()
        for (k, d) in datas { m[k] = d }
        func total() -> Int64 { otherBytes + m.entries.reduce(0) { $0 + Int64(DsyncEnvelopeCodec.byteSize(wrap($1.0, $1.1))) } }
        if total() <= Int64(DsyncLimits.TOTAL_BYTES) { return m.entries }
        for s in STEPS {
            guard let d = m[s.key] else { continue }
            m[s.key] = s.apply(d, now)
            if total() <= Int64(DsyncLimits.TOTAL_BYTES) { return m.entries }
        }
        return nil
    }
}

/// Section 4.12 PIN hash: lowercase hex SHA-256 of `salt bytes || UTF-8 PIN`.
/// Android throws on odd or invalid hex; this returns nil instead.
enum DsyncPinHash {
    static func hash(saltHex: String, normalizedPin: String) -> String? {
        guard let salt = hexToBytes(saltHex) else { return nil }
        var h = SHA256()
        h.update(data: salt)
        h.update(data: Data(normalizedPin.utf8))
        return toHex(Data(h.finalize()))
    }

    static func toHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func hexToBytes(_ hex: String) -> Data? {
        let u = Array(hex.utf8)
        guard u.count % 2 == 0 else { return nil }
        var out = Data(capacity: u.count / 2)
        var i = 0
        while i < u.count {
            guard let s = String(bytes: u[i..<(i + 2)], encoding: .ascii), let b = UInt8(s, radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }
}

/// Coexistence with the cloud backup (Google Drive on Android, iCloud
/// here; docs/DispatcharrSyncSchema.md "Coexistence with Drive and iCloud").
enum DsyncCoexistence {
    /// Categories that carry at least one Dispatcharr Sync key (Playlists and Credentials never do).
    static let SHARED_CATEGORIES: Set<DsyncCategory> = Set(DsyncKey.allCases.compactMap(\.category))

    /// Rule 1: Dispatcharr Sync owns [category] when the active playlist is
    /// Dispatcharr, Dispatcharr Sync is on for its active user, and this
    /// device has completed at least one Dispatcharr pull for that user.
    static func owns(_ category: DsyncCategory, activeIsDispatcharr: Bool, dispatcharrSyncOn: Bool,
                     firstPullDoneForUser: Bool) -> Bool {
        SHARED_CATEGORIES.contains(category) && activeIsDispatcharr && dispatcharrSyncOn && firstPullDoneForUser
    }

    /// Rule 2: on the first pull of [key] for a user on this device, an empty
    /// server envelope is not applied; local seeds the server instead.
    static func seedFromLocal(_ key: DsyncKey, consumedBefore: Bool, data: DsyncObject) -> Bool {
        key != .profiles && !consumedBefore && isEmptyData(key, data)
    }

    /// No rows, ids, names, or lanes. A primitive is a real value, except groupOrder mode "default" with no order.
    static func isEmptyData(_ key: DsyncKey, _ data: DsyncObject) -> Bool {
        if key == .groupOrder {
            let mode = data["mode"]?.asStr ?? "default"
            return mode == "default" && data.filterKeys { $0 != "mode" }.values.allSatisfy(emptyElement)
        }
        return data.values.allSatisfy(emptyElement)
    }

    /// Pull before replace (section 10a): during the setup choice pull a
    /// shared key the stamp check calls "not newer" is applied anyway,
    /// unless this device holds an unsent change for it.
    static func choiceApplies(remoteWins: Bool, forceApply: Bool, key: DsyncKey, dirty: Bool) -> Bool {
        !remoteWins && forceApply && key != .profiles && FORCE_KEYS.contains(key) && !dirty
    }

    static let FORCE_KEYS: [DsyncKey] = [
        .favorites, .recents, .collections, .progress, .reminders,
        .watchlist, .hiddenTitles, .hiddenGroups, .groupOrder, .settings,
    ]

    /// Rule 4 forced replace: every FORCE_KEYS category is written, an empty one included.
    static func forcedWritesEmpty(force: Bool, key: DsyncKey) -> Bool { force && FORCE_KEYS.contains(key) }

    /// Rule 4 guard: the forced keys to disarm because their category did not apply.
    static func cancelledForceKeys(_ applied: [DsyncCategory: Bool]) -> [DsyncKey] {
        FORCE_KEYS.filter { k in k.category.flatMap { applied[$0] } != true }
    }

    /// The forced keys to arm after the cloud apply: those whose category applied.
    static func armedForceKeys(_ applied: [DsyncCategory: Bool]) -> [DsyncKey] {
        let c = Set(cancelledForceKeys(applied))
        return FORCE_KEYS.filter { !c.contains($0) }
    }

    /// Rule 4 mirror: every shared category replaces local instead of merging.
    static func replaceOnForcedApply(_ category: DsyncCategory) -> Bool { SHARED_CATEGORIES.contains(category) }

    /// Rule 4: retry a deferred forced key now (armed, waiting, id cache built).
    static func forcedRetryDue(armed: Bool, awaiting: Bool, cacheReady: Bool) -> Bool { armed && awaiting && cacheReady }

    /// The Rule 4 apply hold is on until [until] (0 = off).
    static func choiceHeld(until: Int64, now: Int64) -> Bool { until > 0 && now < until }

    /// The cloud file that carries [key] (Android driveFileFor). Recents and
    /// collections live in the Preferences file although their toggle is
    /// Favorites, so DsyncKey.category is the wrong lookup here. Every key
    /// with a category maps; an unmapped one traps, never a default.
    static func cloudFileFor(_ key: DsyncKey) -> DsyncCategory? {
        switch key {
        case .profiles, .tmdbKey: return nil
        case .remoteMap, .radioDefault: return .preferences
        default:
            guard let f = SetupSourceChoice.cloudFile(key.suffix) else { preconditionFailure("no cloud file for \(key.suffix)") }
            return f
        }
    }

    /// Row categories whose forced build drops the server rows (no merge, no kept ids).
    static let FORCE_ROW_KEYS: Set<DsyncKey> = [.favorites, .recents, .collections, .progress, .reminders, .watchlist, .hiddenTitles]

    /// Rows (or names) one category's data holds, for the setup prompt and the force-push log.
    static func rowCount(_ key: DsyncKey, _ data: DsyncObject) -> Int {
        switch key {
        case .favorites: return DsyncPayloads.decodeFavorites(data)?.distinctOrdered().count ?? 0
        case .recents: return DsyncPayloads.decodeRecents(data)?.distinctBy { $0.channelId }.count ?? 0
        case .progress: return DsyncPayloads.decodeProgress(data)?.distinctBy { "\($0.type)|\($0.vodId)" }.count ?? 0
        case .reminders: return DsyncPayloads.decodeReminders(data)?.count ?? 0
        case .watchlist, .hiddenTitles: return DsyncPayloads.decodeVodMarks(data)?.distinctBy { "\($0.type)|\($0.vodId)" }.count ?? 0
        case .collections: return DsyncPayloads.decodeCollections(data)?.count ?? 0
        case .hiddenGroups: return DsyncPayloads.decodeHiddenGroups(data).map { $0.live.count + $0.movies.count + $0.series.count } ?? 0
        case .groupOrder:
            return DsyncPayloads.decodeGroupOrder(data).map { CloudCanon.groupOrderRows(CloudCanon.groupMode($0.mode), $0.order) } ?? 0
        case .settings: return DsyncPayloads.decodeSettingsLanes(data).map { CloudCanon.dsyncSettings($0).0 } ?? 0
        default: return isEmptyData(key, data) ? 0 : 1
        }
    }

    /// A content fingerprint over the canonical row identities (CloudCanon).
    static func fingerprint(_ key: DsyncKey, _ data: DsyncObject) -> String? {
        let c = CloudCanon.self
        switch key {
        case .favorites: return DsyncPayloads.decodeFavorites(data).map(c.dsyncFavorites)
        case .recents: return DsyncPayloads.decodeRecents(data).map(c.dsyncRecents)
        case .progress: return DsyncPayloads.decodeProgress(data).map(c.dsyncProgress)
        case .reminders: return DsyncPayloads.decodeReminders(data).map(c.dsyncReminders)
        case .watchlist, .hiddenTitles: return DsyncPayloads.decodeVodMarks(data).map(c.dsyncMarks)
        case .collections: return DsyncPayloads.decodeCollections(data).map(c.dsyncCollections)
        case .hiddenGroups: return DsyncPayloads.decodeHiddenGroups(data).map(c.dsyncHiddenGroups)
        case .groupOrder: return DsyncPayloads.decodeGroupOrder(data).map(c.dsyncGroupOrder)
        case .settings: return DsyncPayloads.decodeSettingsLanes(data).map { c.dsyncSettings($0).1 }
        default: return nil
        }
    }

    /// The shared categories of one decoded bucket, summarized for Rule 4
    /// (setup probe) and Rule 5 (converge). [excluded] collects the rows the
    /// representable filter [keep] dropped, per category.
    static func summarize(_ bucket: DsyncV2.Bucket, scopes: [String: DsyncScope],
                          keep: ((String, Int) -> Bool)? = nil,
                          excluded: inout [String: Int]) -> SetupSourceChoice.Summary {
        var out: [String: SetupSourceChoice.Category] = [:]
        for key in FORCE_KEYS {
            guard let env = DsyncV2.category(bucket, key)?.envelope else { continue }
            let atMs = env.updatedAt * 1000
            if key == .settings {
                let lanes = DsyncPayloads.decodeSettingsLanes(env.data).map {
                    CloudCanon.lanesOn($0) { n in SetupSourceChoice.nameOff(scopes, n) }
                }
                let (n, f): (Int, String?) = lanes.map { let r = CloudCanon.dsyncSettings($0); return (r.0, r.1) } ?? (0, nil)
                out[key.suffix] = SetupSourceChoice.Category(rows: n, updatedAt: atMs, fingerprint: f)
            } else if let keep, DsyncHeld.VOD_KEYS.contains(key) {
                // Section 10a: only rows this device can represent on both providers.
                let (c, gone) = DsyncHeld.vodCategory(key, env.data, updatedAtMs: atMs, keep: keep)
                if gone > 0 { excluded[key.suffix] = gone }
                out[key.suffix] = c
            } else if let keep, key == .recents {
                let (c, gone) = DsyncHeld.recentsCategory(env.data, updatedAtMs: atMs, keep: keep)
                if gone > 0 { excluded[key.suffix] = gone }
                out[key.suffix] = c
            } else {
                out[key.suffix] = SetupSourceChoice.Category(rows: rowCount(key, env.data), updatedAt: atMs,
                                                             fingerprint: fingerprint(key, env.data))
            }
        }
        return SetupSourceChoice.forDevice(SetupSourceChoice.Summary(categories: out)) { SetupSourceChoice.itemOff(scopes, $0) }
    }

    static func summarize(_ bucket: DsyncV2.Bucket, scopes: [String: DsyncScope],
                          keep: ((String, Int) -> Bool)? = nil) -> SetupSourceChoice.Summary {
        var ignored: [String: Int] = [:]
        return summarize(bucket, scopes: scopes, keep: keep, excluded: &ignored)
    }

    private static func emptyElement(_ e: DsyncJSON) -> Bool {
        switch e {
        case .null: return true
        case .array(let a): return a.isEmpty
        case .object(let o): return o.values.allSatisfy(emptyElement)
        default: return false
        }
    }
}

/// Settings > Sync manual actions (section 10a, "Manual push and pull").
enum DsyncManual {
    /// Which manual rows Settings > Sync shows. [pushToBoth] needs the
    /// cloud provider (Drive on Android, iCloud here) on and signed in.
    struct Rows: Equatable, Sendable {
        let pushPullDispatcharr: Bool
        let pushToBoth: Bool
    }

    static func rows(dispatcharrOn: Bool, dispatcharrPlaylist: Bool, cloudOn: Bool, cloudSignedIn: Bool) -> Rows {
        let d = dispatcharrOn && dispatcharrPlaylist
        return Rows(pushPullDispatcharr: d, pushToBoth: d && cloudOn && cloudSignedIn)
    }

    /// The shared keys a manual push or pull covers: every forced-replace key
    /// whose Sync Categories item is not Off; `settings` always (gated per name).
    static func keys(_ scopes: [String: DsyncScope]) -> [DsyncKey] {
        DsyncCoexistence.FORCE_KEYS.filter { key in
            if key == .settings { return true }
            guard let item = DsyncItemCatalog.itemForDsync(key.suffix) else { return true }
            return scopes[item.id] != .off
        }
    }
}
