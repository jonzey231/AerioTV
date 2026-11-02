//  CloudSnapshots.swift
//  Aerio
//
//  The iCloud snapshots of the shared categories, in the same JSON shape
//  (field names, units, optional fields) as the Android Drive snapshots
//  (core/sync/SyncSnapshots.kt), so a reader of either backup reads the
//  same semantics (docs/DispatcharrSyncSchema.md section 10a). The two
//  clouds are separate stores; the shape is shared so the rules and the
//  schema doc are one. Port of the pure parts of SyncSnapshots.kt, the
//  Drive side of DriveCanon.kt (enrichment, backup format, summary
//  categories), and the snapshot parts of dsync/DsyncHeld.kt.
//
//  Apple differences, by design:
//  1. Each snapshot is one iCloud key-value entry holding the JSON text
//     (CloudSnapshotSync), next to the older iCloud keys older builds read.
//  2. Local ids on a Dispatcharr Direct Connect playlist ARE the
//     Dispatcharr ids, so the canonical fields are filled from the local
//     rows directly (the app layer builds the id maps from Int(localId)).
//  3. The preferences snapshot carries settings under the schema names
//     (DsyncSettingsMap) in keys (lane v), tv, and mobile, plus the data
//     keys recents.v1, channelCollections.v1, hiddenGroups.v1,
//     hiddenMovieGroups.v1, hiddenSeriesGroups.v1, groupOrder.v1, and
//     groupSortMode.v1 in keys, the same names Android uses.
//  4. Progress rows carry an optional serverId (the playlist id); Android
//     readers ignore it.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

// MARK: - JSON helpers

private extension DsyncObject {
    func str(_ k: String) -> String? { self[k]?.asStr }
    func long(_ k: String) -> Int64? { self[k]?.asLong }
    func int(_ k: String) -> Int? { self[k]?.asLong.map { Int($0) } }
    func bool(_ k: String) -> Bool? { self[k]?.asBool }
    mutating func put(_ k: String, _ v: String?) { self[k] = v.map { .string($0) } ?? .null }
    mutating func put(_ k: String, _ v: Int64?) { self[k] = v.map { .long($0) } ?? .null }
    mutating func put(_ k: String, _ v: Int?) { self[k] = v.map { .int($0) } ?? .null }
}

private func stringMap(_ v: DsyncJSON?) -> [String: String] {
    guard let o = v?.asObject else { return [:] }
    var out: [String: String] = [:]
    for (k, x) in o where x.isPrimitive && x != .null { out[k] = x.content }
    return out
}

private func objectOf(_ m: [String: String]) -> DsyncJSON {
    .object(DsyncObject(m.sorted { $0.key < $1.key }.map { ($0.key, DsyncJSON.string($0.value)) }))
}

// MARK: - Envelope

/// Android SyncEnvelope. [format] 2 = written by a build that fills the canonical ids.
struct CloudEnvelope: Equatable, Sendable {
    var version: Int = 1
    var lastModified: Int64
    var device: String
    var syncProviders: SyncProvidersRecord? = nil
    var format: Int? = nil

    var json: DsyncJSON {
        var o = DsyncObject()
        o["version"] = .int(version)
        o["lastModified"] = .long(lastModified)
        o["device"] = .string(device)
        if let p = syncProviders { o["syncProviders"] = .object(SyncProvidersRules.toJson(p)) }
        if let f = format { o["format"] = .int(f) }
        return .object(o)
    }

    static func from(_ v: DsyncJSON?) -> CloudEnvelope? {
        guard let o = v?.asObject, let at = o.long("lastModified") else { return nil }
        return CloudEnvelope(version: o.int("version") ?? 1, lastModified: at, device: o.str("device") ?? "",
                             syncProviders: SyncProvidersRules.fromJson(o["syncProviders"]), format: o.int("format"))
    }
}

// MARK: - Entries

struct CloudFavoriteEntry: Equatable, Sendable {
    var channelId: String
    var channelName: String
    var displayOrder: Int64
    var addedAt: Int64
    var dispatcharrChannelId: Int? = nil

    var json: DsyncJSON {
        var o = DsyncObject()
        o["channelId"] = .string(channelId)
        o["channelName"] = .string(channelName)
        o["displayOrder"] = .long(displayOrder)
        o["addedAt"] = .long(addedAt)
        o.put("dispatcharrChannelId", dispatcharrChannelId)
        return .object(o)
    }

    static func from(_ v: DsyncJSON) -> CloudFavoriteEntry? {
        guard let o = v.asObject, let id = o.str("channelId") else { return nil }
        return CloudFavoriteEntry(channelId: id, channelName: o.str("channelName") ?? "", displayOrder: o.long("displayOrder") ?? 0,
                                  addedAt: o.long("addedAt") ?? 0, dispatcharrChannelId: o.int("dispatcharrChannelId"))
    }
}

struct CloudProgressEntry: Equatable, Sendable {
    var videoId: String
    var title: String
    var posterUrl: String? = nil
    var positionMs: Int64
    var durationMs: Int64
    var updatedAt: Int64
    var vodType: String = "movie"
    var seriesId: String? = nil
    var seasonNumber: Int = 0
    var episodeNumber: Int = 0
    var isFinished: Bool = false
    var dispatcharrVodId: Int? = nil
    /// Apple only: the playlist id the row belongs to (nil: unscoped). Android ignores it.
    var serverId: String? = nil

    var json: DsyncJSON {
        var o = DsyncObject()
        o["videoId"] = .string(videoId)
        o["title"] = .string(title)
        o.put("posterUrl", posterUrl)
        o["positionMs"] = .long(positionMs)
        o["durationMs"] = .long(durationMs)
        o["updatedAt"] = .long(updatedAt)
        o["vodType"] = .string(vodType)
        o.put("seriesId", seriesId)
        o["seasonNumber"] = .int(seasonNumber)
        o["episodeNumber"] = .int(episodeNumber)
        o["isFinished"] = .bool(isFinished)
        o.put("dispatcharrVodId", dispatcharrVodId)
        if let s = serverId { o["serverId"] = .string(s) }
        return .object(o)
    }

    static func from(_ v: DsyncJSON) -> CloudProgressEntry? {
        guard let o = v.asObject, let id = o.str("videoId") else { return nil }
        return CloudProgressEntry(videoId: id, title: o.str("title") ?? "", posterUrl: o.str("posterUrl"),
                                  positionMs: o.long("positionMs") ?? 0, durationMs: o.long("durationMs") ?? 0,
                                  updatedAt: o.long("updatedAt") ?? 0, vodType: o.str("vodType") ?? "movie",
                                  seriesId: o.str("seriesId"), seasonNumber: o.int("seasonNumber") ?? 0,
                                  episodeNumber: o.int("episodeNumber") ?? 0, isFinished: o.bool("isFinished") ?? false,
                                  dispatcharrVodId: o.int("dispatcharrVodId"), serverId: o.str("serverId"))
    }
}

struct CloudReminderEntry: Equatable, Sendable {
    var reminderKey: String
    var channelName: String
    var programTitle: String
    var startMillis: Int64
    var endMillis: Int64

    var json: DsyncJSON {
        .object(DsyncObject([("reminderKey", .string(reminderKey)), ("channelName", .string(channelName)),
                             ("programTitle", .string(programTitle)), ("startMillis", .long(startMillis)),
                             ("endMillis", .long(endMillis))]))
    }

    static func from(_ v: DsyncJSON) -> CloudReminderEntry? {
        guard let o = v.asObject, let k = o.str("reminderKey"), let s = o.long("startMillis") else { return nil }
        return CloudReminderEntry(reminderKey: k, channelName: o.str("channelName") ?? "", programTitle: o.str("programTitle") ?? "",
                                  startMillis: s, endMillis: o.long("endMillis") ?? s)
    }
}

struct CloudWatchlistEntry: Equatable, Sendable {
    var vodId: String
    var vodType: String = "movie"
    var title: String
    var posterUrl: String? = nil
    var releaseYear: String = ""
    var rating: String = ""
    var serverId: String? = nil
    var addedAt: Int64
    var removedAt: Int64? = nil
    var dispatcharrVodId: Int? = nil

    var isLive: Bool { removedAt == nil }

    var json: DsyncJSON {
        var o = DsyncObject()
        o["vodId"] = .string(vodId)
        o["vodType"] = .string(vodType)
        o["title"] = .string(title)
        o.put("posterUrl", posterUrl)
        o["releaseYear"] = .string(releaseYear)
        o["rating"] = .string(rating)
        o.put("serverId", serverId)
        o["addedAt"] = .long(addedAt)
        o.put("removedAt", removedAt)
        o.put("dispatcharrVodId", dispatcharrVodId)
        return .object(o)
    }

    static func from(_ v: DsyncJSON) -> CloudWatchlistEntry? {
        guard let o = v.asObject, let id = o.str("vodId") else { return nil }
        return CloudWatchlistEntry(vodId: id, vodType: o.str("vodType") ?? "movie", title: o.str("title") ?? "",
                                   posterUrl: o.str("posterUrl"), releaseYear: o.str("releaseYear") ?? "",
                                   rating: o.str("rating") ?? "", serverId: o.str("serverId"), addedAt: o.long("addedAt") ?? 0,
                                   removedAt: o.long("removedAt"), dispatcharrVodId: o.int("dispatcharrVodId"))
    }
}

struct CloudHiddenEntry: Equatable, Sendable {
    var vodId: String
    var vodType: String = "movie"
    var serverId: String? = nil
    var hiddenAt: Int64
    var unhiddenAt: Int64? = nil
    var dispatcharrVodId: Int? = nil

    var isLive: Bool { unhiddenAt == nil }

    var json: DsyncJSON {
        var o = DsyncObject()
        o["vodId"] = .string(vodId)
        o["vodType"] = .string(vodType)
        o.put("serverId", serverId)
        o["hiddenAt"] = .long(hiddenAt)
        o.put("unhiddenAt", unhiddenAt)
        o.put("dispatcharrVodId", dispatcharrVodId)
        return .object(o)
    }

    static func from(_ v: DsyncJSON) -> CloudHiddenEntry? {
        guard let o = v.asObject, let id = o.str("vodId") else { return nil }
        return CloudHiddenEntry(vodId: id, vodType: o.str("vodType") ?? "movie", serverId: o.str("serverId"),
                                hiddenAt: o.long("hiddenAt") ?? 0, unhiddenAt: o.long("unhiddenAt"),
                                dispatcharrVodId: o.int("dispatcharrVodId"))
    }
}

// MARK: - Snapshots

/// One shared snapshot file: envelope plus rows, encoded as Android writes it.
protocol CloudSnapshot: Equatable, Sendable {
    var envelope: CloudEnvelope { get set }
    var body: DsyncObject { get }
    static func decode(_ o: DsyncObject) -> Self?
}

extension CloudSnapshot {
    var text: String {
        var o = DsyncObject()
        o["envelope"] = envelope.json
        for (k, v) in body { o[k] = v }
        return DsyncJSONEncoder.encode(o)
    }

    static func decode(text: String) -> Self? { DsyncJSONParser.parseObject(text).flatMap(decode) }
}

struct CloudFavorites: CloudSnapshot {
    var envelope: CloudEnvelope
    var entries: [CloudFavoriteEntry]

    var body: DsyncObject { DsyncObject([("entries", .array(entries.map(\.json)))]) }

    static func decode(_ o: DsyncObject) -> CloudFavorites? {
        guard let e = CloudEnvelope.from(o["envelope"]) else { return nil }
        return CloudFavorites(envelope: e, entries: (o["entries"]?.asArray ?? []).compactMap(CloudFavoriteEntry.from))
    }
}

struct CloudProgress: CloudSnapshot {
    var envelope: CloudEnvelope
    var entries: [CloudProgressEntry]

    var body: DsyncObject { DsyncObject([("entries", .array(entries.map(\.json)))]) }

    static func decode(_ o: DsyncObject) -> CloudProgress? {
        guard let e = CloudEnvelope.from(o["envelope"]) else { return nil }
        return CloudProgress(envelope: e, entries: (o["entries"]?.asArray ?? []).compactMap(CloudProgressEntry.from))
    }
}

struct CloudReminders: CloudSnapshot {
    var envelope: CloudEnvelope
    var entries: [CloudReminderEntry]

    var body: DsyncObject { DsyncObject([("entries", .array(entries.map(\.json)))]) }

    static func decode(_ o: DsyncObject) -> CloudReminders? {
        guard let e = CloudEnvelope.from(o["envelope"]) else { return nil }
        return CloudReminders(envelope: e, entries: (o["entries"]?.asArray ?? []).compactMap(CloudReminderEntry.from))
    }
}

struct CloudWatchlist: CloudSnapshot {
    var envelope: CloudEnvelope
    var entries: [CloudWatchlistEntry]
    var hidden: [CloudHiddenEntry] = []

    var body: DsyncObject {
        DsyncObject([("entries", .array(entries.map(\.json))), ("hidden", .array(hidden.map(\.json)))])
    }

    static func decode(_ o: DsyncObject) -> CloudWatchlist? {
        guard let e = CloudEnvelope.from(o["envelope"]) else { return nil }
        return CloudWatchlist(envelope: e, entries: (o["entries"]?.asArray ?? []).compactMap(CloudWatchlistEntry.from),
                              hidden: (o["hidden"]?.asArray ?? []).compactMap(CloudHiddenEntry.from))
    }
}

struct CloudPreferences: CloudSnapshot {
    var envelope: CloudEnvelope
    /// Lane v (every device class) plus the data keys (CloudCanon.K_*).
    var keys: [String: String]
    var tv: [String: String] = [:]
    var mobile: [String: String] = [:]
    /// Local channel id to Dispatcharr channel id for every channel recents and collections reference.
    var dispatcharrChannelIds: [String: Int]? = nil

    var body: DsyncObject {
        var o = DsyncObject()
        o["keys"] = objectOf(keys)
        o["tv"] = objectOf(tv)
        o["mobile"] = objectOf(mobile)
        if let m = dispatcharrChannelIds {
            o["dispatcharrChannelIds"] = .object(DsyncObject(m.sorted { $0.key < $1.key }.map { ($0.key, DsyncJSON.int($0.value)) }))
        } else {
            o["dispatcharrChannelIds"] = .null
        }
        return o
    }

    static func decode(_ o: DsyncObject) -> CloudPreferences? {
        guard let e = CloudEnvelope.from(o["envelope"]) else { return nil }
        var ids: [String: Int]?
        if let m = o["dispatcharrChannelIds"]?.asObject {
            var out: [String: Int] = [:]
            for (k, v) in m { if let i = v.asLong { out[k] = Int(i) } }
            ids = out
        }
        return CloudPreferences(envelope: e, keys: stringMap(o["keys"]), tv: stringMap(o["tv"]), mobile: stringMap(o["mobile"]),
                                dispatcharrChannelIds: ids)
    }

    /// The settings lanes (schema names only), the data keys left out.
    var settingsLanes: [String: [String: String]] {
        [DsyncScope.LANE_ALL: keys.filter { !CloudCanon.DATA_KEYS.contains($0.key) },
         DsyncScope.LANE_TV: tv, DsyncScope.LANE_MOBILE: mobile]
    }
}

// MARK: - Drive side of DriveCanon (snapshot rules)

extension CloudCanon {
    /// Local id to Dispatcharr id. A missing key is an id that did not resolve.
    struct Ids: Equatable, Sendable {
        var channels: [String: Int] = [:]
        var movies: [String: Int] = [:]
        var episodes: [String: Int] = [:]
        func channel(_ local: String) -> Int? { channels[local] }
    }

    static let K_RECENTS = "recents.v1"
    static let K_COLLECTIONS = "channelCollections.v1"
    static let K_HIDDEN_LIVE = "hiddenGroups.v1"
    static let K_HIDDEN_MOVIES = "hiddenMovieGroups.v1"
    static let K_HIDDEN_SERIES = "hiddenSeriesGroups.v1"
    static let K_ORDER = "groupOrder.v1"
    static let K_SORT_MODE = "groupSortMode.v1"
    static let DATA_KEYS: Set<String> = [K_RECENTS, K_COLLECTIONS, K_HIDDEN_LIVE, K_HIDDEN_MOVIES, K_HIDDEN_SERIES, K_ORDER, K_SORT_MODE]

    /// The backup format this build writes on every iCloud snapshot (envelope.format).
    static let FORMAT = 2

    /// The envelope every iCloud write carries: always [FORMAT].
    static func writerEnvelope(nowMs: Int64, device: String, providers: SyncProvidersRecord?) -> CloudEnvelope {
        CloudEnvelope(lastModified: nowMs, device: device, syncProviders: providers, format: FORMAT)
    }

    /// A file is old format when its envelope format is missing or below [FORMAT].
    static func isOldFormat(_ format: Int?) -> Bool { format.map { $0 < FORMAT } ?? true }

    /// Old format backup: any shared file present (non-nil entry) is old format. Absent files do not count.
    static func backupOutdated(_ fileFormats: [Int?]) -> Bool { fileFormats.contains(where: isOldFormat) }

    /// Names (category to envelope format) that are old format, in the given order, for the offer log.
    static func oldFormatNames(_ formats: [(String, Int?)]) -> [String] { formats.filter { isOldFormat($0.1) }.map(\.0) }

    /// Categories the accepted backup update still has to rewrite (none when not accepted).
    static func pendingCategories<C: Equatable>(accepted: Bool, all: [C], done: (C) -> Bool) -> [C] {
        accepted ? all.filter { !done($0) } : []
    }

    /// The format stamp alone: [body] with envelope.format set to [FORMAT], every other field kept.
    static func stampFormat(_ body: String) -> String? {
        guard var o = DsyncJSONParser.parseObject(body), var env = o["envelope"]?.asObject else { return nil }
        env["format"] = .int(FORMAT)
        o["envelope"] = .object(env)
        return DsyncJSONEncoder.encode(o)
    }

    /// envelope.format of a snapshot body; nil when absent or unreadable.
    static func envelopeFormat(_ body: String) -> Int? {
        DsyncJSONParser.parseObject(body)?["envelope"]?.asObject?["format"]?.asLong.map { Int($0) }
    }

    // ---- enrichment (every push and the accepted backup update) ----

    static func enrichFavorites(_ s: CloudFavorites, _ ids: Ids) -> (CloudFavorites, Int) {
        var n = 0
        var out = s
        out.entries = s.entries.map { r in
            guard r.dispatcharrChannelId == nil, let id = ids.channel(r.channelId) else { return r }
            n += 1
            var c = r; c.dispatcharrChannelId = id; return c
        }
        return (out, n)
    }

    static func enrichProgress(_ s: CloudProgress, _ ids: Ids) -> (CloudProgress, Int) {
        var n = 0
        var out = s
        out.entries = s.entries.map { r in
            guard r.dispatcharrVodId == nil, let id = progressId(r, ids) else { return r }
            n += 1
            var c = r; c.dispatcharrVodId = id; return c
        }
        return (out, n)
    }

    /// Returns the snapshot, watchlist rows filled, and hidden rows filled.
    static func enrichWatchlist(_ s: CloudWatchlist, _ ids: Ids) -> (CloudWatchlist, Int, Int) {
        var w = 0
        var h = 0
        var out = s
        out.entries = s.entries.map { r in
            guard r.dispatcharrVodId == nil, let id = markId(r.vodType, r.vodId, ids) else { return r }
            w += 1
            var c = r; c.dispatcharrVodId = id; return c
        }
        out.hidden = s.hidden.map { r in
            guard r.dispatcharrVodId == nil, let id = markId(r.vodType, r.vodId, ids) else { return r }
            h += 1
            var c = r; c.dispatcharrVodId = id; return c
        }
        return (out, w, h)
    }

    /// Fills dispatcharrChannelIds for the recents and collection channels. Returns channels added.
    static func enrichPreferences(_ s: CloudPreferences, _ ids: Ids) -> (CloudPreferences, Int) {
        let have = s.dispatcharrChannelIds ?? [:]
        var add: [String: Int] = [:]
        for l in referencedChannels(s) where have[l] == nil { if let id = ids.channel(l) { add[l] = id } }
        if add.isEmpty { return (s, 0) }
        var out = s
        out.dispatcharrChannelIds = have.merging(add) { a, _ in a }
        return (out, add.count)
    }

    static func referencedChannels(_ s: CloudPreferences) -> Set<String> {
        Set(recents(s) + collections(s).flatMap(\.memberIds))
    }

    private static func progressId(_ r: CloudProgressEntry, _ ids: Ids) -> Int? {
        if r.videoId.contains("://") { return nil }
        switch r.vodType {
        case "movie": return ids.movies[r.videoId]
        case "episode": return ids.episodes[r.videoId]
        default: return nil
        }
    }

    private static func markId(_ vodType: String, _ vodId: String, _ ids: Ids) -> Int? {
        vodType == "series" ? Int(vodId) : ids.movies[vodId]
    }

    // ---- summary categories (what Dispatcharr Sync would carry) ----

    private static func fpItems(_ items: [String]) -> String { SetupSourceChoice.fingerprint(items) }

    static func progressCandidates(_ s: CloudProgress) -> [CloudProgressEntry] {
        s.entries.filter { !$0.videoId.contains("://") && ($0.vodType == "movie" || $0.vodType == "episode") }
    }

    /// Canonical VOD items a cloud copy carries with an id, for the representable filter (10a).
    static func carriedItems(_ p: CloudProgress?, _ w: CloudWatchlist?, _ ids: Ids = Ids()) -> Set<String> {
        var out = Set<String>()
        if let p {
            for r in progressCandidates(p) {
                if let id = r.dispatcharrVodId ?? progressId(r, ids) { out.insert(vodItem(r.vodType == "episode" ? "e" : "m", id)) }
            }
        }
        if let w {
            let pairs = w.entries.map { ($0.vodType, $0.dispatcharrVodId ?? markId($0.vodType, $0.vodId, ids)) } +
                w.hidden.map { ($0.vodType, $0.dispatcharrVodId ?? markId($0.vodType, $0.vodId, ids)) }
            for (t, id) in pairs { if let id { out.insert(vodItem(t == "series" ? "s" : "m", id)) } }
        }
        return out
    }

    /// Canonical-id rows only (distinct Dispatcharr channel ids).
    static func favorites(_ s: CloudFavorites, _ ids: Ids) -> SetupSourceChoice.Category {
        let c = s.entries.compactMap { $0.dispatcharrChannelId ?? ids.channel($0.channelId) }.distinctOrdered()
        return SetupSourceChoice.Category(rows: c.count, updatedAt: s.envelope.lastModified, fingerprint: fpItems(c.map(channelItem)))
    }

    /// Progress rows the probe counts: movie and episode ids, finished rows within 30 days, the 300 newest.
    static func progressCounted(_ rows: [CloudProgressEntry], nowMs: Int64) -> [CloudProgressEntry] {
        let nowS = nowMs / 1000
        return rows.filter { !$0.videoId.contains("://") && ($0.vodType == "movie" || $0.vodType == "episode") }
            .filter { !($0.isFinished && nowS - $0.updatedAt / 1000 > DsyncLimits.FINISHED_MAX_AGE_S) }
            .stableSorted(by: { $0.updatedAt }, descending: true)
            .prefix(DsyncLimits.PROGRESS).map { $0 }
    }

    /// Mirrors the Dispatcharr cap: finished rows older than 30 days drop, then the 300 newest; canonical ids only.
    static func progress(_ s: CloudProgress, _ ids: Ids, nowMs: Int64) -> SetupSourceChoice.Category {
        let items = progressCounted(s.entries, nowMs: nowMs).compactMap { r in
            (r.dispatcharrVodId ?? progressId(r, ids)).map { vodItem(r.vodType == "episode" ? "e" : "m", $0) }
        }.distinctOrdered()
        return SetupSourceChoice.Category(rows: items.count, updatedAt: s.envelope.lastModified, fingerprint: fpItems(items))
    }

    /// Future reminders only, as Dispatcharr Sync carries.
    static func reminders(_ s: CloudReminders, nowMs: Int64) -> SetupSourceChoice.Category {
        let rows = s.entries.filter { $0.endMillis >= nowMs }.distinctBy { "\($0.channelName)|\($0.startMillis / 1000)" }
        return SetupSourceChoice.Category(rows: rows.count, updatedAt: s.envelope.lastModified,
                                          fingerprint: fpItems(rows.map { reminderItem($0.channelName, $0.startMillis / 1000) }))
    }

    /// Live rows of this playlist's scope ([host], or unscoped).
    static func watchlist(_ s: CloudWatchlist, _ ids: Ids, host: String?) -> SetupSourceChoice.Category {
        let items = s.entries.filter { $0.isLive && ($0.serverId == nil || $0.serverId == host) }.compactMap { r in
            (r.dispatcharrVodId ?? markId(r.vodType, r.vodId, ids)).map { vodItem(r.vodType == "series" ? "s" : "m", $0) }
        }.distinctOrdered()
        return SetupSourceChoice.Category(rows: items.count, updatedAt: s.envelope.lastModified, fingerprint: fpItems(items))
    }

    static func hiddenTitles(_ s: CloudWatchlist, _ ids: Ids, host: String?) -> SetupSourceChoice.Category {
        let items = s.hidden.filter { $0.isLive && ($0.serverId == nil || $0.serverId == host) }.compactMap { r in
            (r.dispatcharrVodId ?? markId(r.vodType, r.vodId, ids)).map { vodItem(r.vodType == "series" ? "s" : "m", $0) }
        }.distinctOrdered()
        return SetupSourceChoice.Category(rows: items.count, updatedAt: s.envelope.lastModified, fingerprint: fpItems(items))
    }

    static func lines(_ v: String?) -> [String] {
        (v ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.distinctOrdered()
    }

    static func recents(_ s: CloudPreferences) -> [String] { Array(lines(s.keys[K_RECENTS]).prefix(DsyncLimits.RECENTS)) }

    /// The channelCollections.v1 shape (Android ChannelCollection).
    struct Collection: Equatable, Sendable {
        var id: String
        var name: String
        var memberIds: [String]
        var placement: String
    }

    static func collections(_ s: CloudPreferences) -> [Collection] {
        guard let t = s.keys[K_COLLECTIONS], let a = DsyncJSONParser.parse(t)?.asArray else { return [] }
        return a.compactMap { v in
            guard let o = v.asObject, let id = o["id"]?.asStr else { return nil }
            return Collection(id: id, name: o["name"]?.asStr ?? "", memberIds: (o["memberIds"]?.asArray ?? []).compactMap(\.asStr),
                              placement: o["placement"]?.asStr ?? "end")
        }
    }

    static func encodeCollections(_ cs: [Collection]) -> String {
        DsyncJSONEncoder.encode(.array(cs.map { c in
            .object(DsyncObject([("id", .string(c.id)), ("name", .string(c.name)),
                                 ("memberIds", .array(c.memberIds.map { .string($0) })), ("placement", .string(c.placement))]))
        }))
    }

    private static func channelOf(_ s: CloudPreferences, _ ids: Ids, _ local: String) -> Int? {
        s.dispatcharrChannelIds?[local] ?? ids.channel(local)
    }

    /// Canonical channel items ("c|<id>") the recents carry, for the representable filter.
    static func recentChannelItems(_ s: CloudPreferences, _ ids: Ids) -> Set<String> {
        Set(lines(s.keys[K_RECENTS]).compactMap { channelOf(s, ids, $0) }.map { vodItem("c", $0) })
    }

    /// Canonical-id rows only: distinct ids, then the 50 cap.
    static func recentsCategory(_ s: CloudPreferences, _ ids: Ids) -> SetupSourceChoice.Category {
        let c = Array(lines(s.keys[K_RECENTS]).compactMap { channelOf(s, ids, $0) }.distinctOrdered().prefix(DsyncLimits.RECENTS))
        return SetupSourceChoice.Category(rows: c.count, updatedAt: s.envelope.lastModified, fingerprint: fpItems(c.map(channelItem)))
    }

    /// A member that does not resolve leaves the fingerprint nil.
    static func collectionsCategory(_ s: CloudPreferences, _ ids: Ids) -> SetupSourceChoice.Category {
        let cs = collections(s)
        var unsure = false
        let items = cs.map { c -> String in
            let m = c.memberIds.map { channelOf(s, ids, $0) }
            if m.contains(where: { $0 == nil }) { unsure = true }
            return collectionItem(c.id, c.name, c.placement == "beginning" ? "b" : "e", m.compactMap { $0 })
        }
        return SetupSourceChoice.Category(rows: cs.count, updatedAt: s.envelope.lastModified, fingerprint: unsure ? nil : fpItems(items))
    }

    static func hiddenGroupsCategory(_ s: CloudPreferences) -> SetupSourceChoice.Category {
        let items = (lines(s.keys[K_HIDDEN_LIVE]).map { groupItem("live", $0) } + lines(s.keys[K_HIDDEN_MOVIES]).map { groupItem("movies", $0) } +
            lines(s.keys[K_HIDDEN_SERIES]).map { groupItem("series", $0) }).distinctOrdered()
        return SetupSourceChoice.Category(rows: items.count, updatedAt: s.envelope.lastModified, fingerprint: fpItems(items))
    }

    static func groupOrderCategory(_ s: CloudPreferences) -> SetupSourceChoice.Category {
        let mode = groupMode(s.keys[K_SORT_MODE])
        let order = lines(s.keys[K_ORDER])
        let items = order.distinctOrdered().enumerated().map { "\($0.offset)|\($0.element)" } + ["mode|\(mode)"]
        return SetupSourceChoice.Category(rows: groupOrderRows(mode, order), updatedAt: s.envelope.lastModified, fingerprint: fpItems(items))
    }

    /// Settings of a preferences snapshot, the names this device has Off left out.
    static func settingsOf(_ s: CloudPreferences, nameOff: (String) -> Bool) -> SetupSourceChoice.Category {
        settingsCategory(lanesOn(s.settingsLanes, off: nameOff), updatedAt: s.envelope.lastModified)
    }

    // ---- held progress rows in the cloud snapshot (DsyncHeld) ----

    static func heldEntry(_ r: ProgressRow) -> CloudProgressEntry {
        CloudProgressEntry(videoId: DsyncHeld.placeholder(r.type, r.vodId), title: r.title, posterUrl: nil,
                           positionMs: r.position * 1000, durationMs: r.duration * 1000, updatedAt: r.updatedAt * 1000,
                           vodType: r.type == "e" ? "episode" : "movie", seriesId: r.seriesId.map(String.init),
                           seasonNumber: r.season, episodeNumber: r.episode, isFinished: r.finished, dispatcharrVodId: r.vodId)
    }

    /// A placeholder entry back to a held row; nil for real local rows or rows without an id.
    static func heldRow(_ e: CloudProgressEntry) -> ProgressRow? {
        guard DsyncHeld.isPlaceholder(e.videoId), let id = e.dispatcharrVodId else { return nil }
        let ep = e.vodType == "episode"
        return ProgressRow(vodId: id, type: ep ? "e" : "m", position: e.positionMs / 1000, duration: e.durationMs / 1000,
                           updatedAt: e.updatedAt / 1000, finished: e.isFinished, seriesId: ep ? e.seriesId.flatMap { Int($0) } : nil,
                           season: e.seasonNumber, episode: e.episodeNumber, title: e.title)
    }

    /// THE cloud progress snapshot rule (section 10a, single builder): local rows plus every
    /// Dispatcharr row this device holds or last read ([extra]).
    /// 1. A local row without a canonical id takes it from an [extra] row whose saved reverse id
    ///    ([uuidOf]) is that row's id.
    /// 2. A resolved local row wins over the placeholder for the same item.
    /// 3. Any other [extra] row rides as a placeholder ("dsync:<type>:<id>").
    /// Placeholder rows already in [s] are replaced by the current set.
    static func progressSnapshot(_ s: CloudProgress, extra: [ProgressRow],
                                 uuidOf: (String, Int) -> String? = { _, _ in nil }) -> CloudProgress {
        let rows = extra.groupedOrdered(by: DsyncHeld.item).map { $0.1.maxByFirst { $0.updatedAt }! }
        var byUuid: [String: ProgressRow] = [:]
        for r in rows { if let u = uuidOf(r.type, r.vodId), !u.isEmpty { byUuid[u] = r } }
        let real = s.entries.filter { !DsyncHeld.isPlaceholder($0.videoId) }.map { e -> CloudProgressEntry in
            if e.dispatcharrVodId != nil || (e.vodType != "movie" && e.vodType != "episode") { return e }
            guard let r = byUuid[e.videoId], (r.type == "e") == (e.vodType == "episode") else { return e }
            var c = e; c.dispatcharrVodId = r.vodId; return c
        }
        let have = Set(real.compactMap { e in e.dispatcharrVodId.map { vodItem(e.vodType == "episode" ? "e" : "m", $0) } })
        var out = s
        out.entries = real + rows.filter { !have.contains(DsyncHeld.item($0)) }.map(heldEntry)
        return out
    }

    // ---- log lines (counts only) ----

    /// The single migration log line: counts only, never ids.
    static func migrationLine(_ category: String, rows: Int) -> String { "[CLOUD] id migration: \(category) \(rows) rows enriched" }

    /// "[CLOUD] push <Category> rows=N (replace)" or "(follow recents local, recents pull)".
    static func pushLine(_ file: String, rows: Int, shared: [(String, Int)], label: String?, follows: [String], ok: Bool) -> String {
        let why = [label, follows.isEmpty ? nil : "follow " + follows.joined(separator: ", ")].compactMap { $0 }.joined(separator: "; ")
        let detail = shared.count > 1 ? " " + shared.map { "\($0.0)=\($0.1)" }.joined(separator: " ") : ""
        return "[CLOUD] push \(file) rows=\(rows)\(detail) (\(why))\(ok ? "" : " failed")"
    }

    /// Log name of a cloud file (Android SyncCategory names).
    static func fileName(_ c: DsyncCategory) -> String {
        switch c {
        case .playlists: return "Playlists"
        case .watchProgress: return "WatchProgress"
        case .reminders: return "Reminders"
        case .favorites: return "Favorites"
        case .watchlist: return "Watchlist"
        case .preferences: return "Preferences"
        case .credentials: return "Credentials"
        }
    }

    /// The shared cloud files, in Android's update order.
    static let SHARED_FILES: [DsyncCategory] = [.favorites, .watchProgress, .reminders, .watchlist, .preferences]
}

// MARK: - Rule 4 replace (the user chose the iCloud backup)
//
// The device starts from the iCloud copy: a local row the backup does not
// carry is removed. Only rows inside the comparison the setup probe makes
// are candidates (the filters of progress, reminders, watchlist, and
// hiddenTitles above); a row those filters exclude is counted by neither
// side and is kept (section 10a). A missing cloud file replaces nothing.

extension CloudCanon {
    /// Progress video ids to delete: counted locally and absent from the backup.
    static func progressReplaceDeletes(_ local: [CloudProgressEntry], _ backup: CloudProgress, nowMs: Int64) -> [String] {
        let keep = Set(backup.entries.map(\.videoId))
        return progressCounted(local, nowMs: nowMs).map(\.videoId).filter { !keep.contains($0) }.distinctOrdered()
    }

    /// Future reminders only (ended ones are not compared). Matched by key, or by channel name and start second.
    static func reminderReplaceDeletes(_ local: [CloudReminderEntry], _ backup: CloudReminders, nowMs: Int64) -> [String] {
        let keys = Set(backup.entries.map(\.reminderKey))
        let ids = Set(backup.entries.map { reminderItem($0.channelName, $0.startMillis / 1000) })
        return local.filter { $0.endMillis >= nowMs }
            .filter { !keys.contains($0.reminderKey) && !ids.contains(reminderItem($0.channelName, $0.startMillis / 1000)) }
            .map(\.reminderKey)
    }

    /// Favorites carry no scope: every local favorite the backup lacks goes.
    static func favoriteReplaceDeletes(_ local: [String], _ backup: CloudFavorites) -> [String] {
        let keep = Set(backup.entries.map(\.channelId))
        return local.filter { !keep.contains($0) }.distinctOrdered()
    }

    /// Watchlist and hidden titles (tombstoned): a row whose identity the backup carries becomes the
    /// backup row (tombstone included); a live local row in scope the backup lacks is tombstoned;
    /// every other row is kept; backup rows new here are added.
    static func replaceMarks<E, I: Hashable>(_ local: [E], _ remote: [E], identity: (E) -> I, live: (E) -> Bool,
                                             inScope: (E) -> Bool, tombstone: (E) -> E) -> [E] {
        var byId: [I: E] = [:]
        for r in remote where byId[identity(r)] == nil { byId[identity(r)] = r }
        var seen = Set<I>()
        var out: [E] = local.map { l in
            let id = identity(l)
            if let r = byId[id] { seen.insert(id); return r }
            return live(l) && inScope(l) ? tombstone(l) : l
        }
        for r in remote where !seen.contains(identity(r)) {
            seen.insert(identity(r))
            out.append(r)
        }
        return out
    }

    /// Live rows in [inScope], for the counts line.
    static func liveInScope<E>(_ rows: [E], live: (E) -> Bool, inScope: (E) -> Bool) -> Int { rows.filter { live($0) && inScope($0) }.count }

    /// The counts-only replace line.
    static func replaceLine(_ category: String, local: Int, backup: Int, removed: Int) -> String {
        "[CLOUD] replace \(category) local=\(local) backup=\(backup) removed=\(removed)"
    }

    /// The probe failure line: a failed read is unknown, never empty.
    static func probeFailedLine(_ reason: String) -> String { "[CLOUD] setup probe failed: \(reason) (treated as unknown, not empty)" }

    /// Progress rows of one playlist's scope (its id, or unscoped), placeholders included.
    static func progressInScope(_ s: CloudProgress, host: String?) -> CloudProgress {
        var out = s
        out.entries = s.entries.filter { $0.serverId == nil || $0.serverId == host || DsyncHeld.isPlaceholder($0.videoId) }
        return out
    }
}

// MARK: - Sync providers record (section 10b; Android SyncProviders.kt)

struct SyncProvidersRecord: Equatable, Sendable {
    var dispatcharr = false
    var googleDrive = false
    var icloud = false
    /// Unix milliseconds of the last flag change.
    var updatedAt: Int64 = 0
    var deviceId = ""
}

enum SyncProvidersRules {
    static let DISPATCHARR = "dispatcharr"
    static let GOOGLE_DRIVE = "googleDrive"
    static let ICLOUD = "icloud"
    static let DSYNC_CATEGORY = "syncProviders"

    /// Pull fold: the newer record wins whole (ties: higher deviceId); nil never replaces.
    static func newer(_ a: SyncProvidersRecord?, _ b: SyncProvidersRecord?) -> SyncProvidersRecord? {
        guard let a else { return b }
        guard let b else { return a }
        if b.updatedAt > a.updatedAt { return b }
        if b.updatedAt == a.updatedAt && b.deviceId > a.deviceId { return b }
        return a
    }

    struct Push: Equatable, Sendable {
        let record: SyncProvidersRecord?
        let reported: Set<String>
    }

    /// The record to write on a push (Apple: this device sets dispatcharr and icloud; googleDrive
    /// is preserved). Union with the stored flags; a flag goes back to false only when this device
    /// reported it true before and it is off now. updatedAt and deviceId move only on a change.
    static func forPush(stored: SyncProvidersRecord?, isBaseProfile: Bool, dispatcharrOn: Bool, icloudOn: Bool,
                        reported: Set<String>, deviceId: String, nowMs: Int64) -> Push {
        if !isBaseProfile { return Push(record: stored, reported: reported) }
        var rep = reported
        func flag(_ id: String, _ remote: Bool, _ on: Bool) -> Bool {
            if on { rep.insert(id); return true }
            if reported.contains(id) { rep.remove(id); return false }
            return remote
        }
        let d = flag(DISPATCHARR, stored?.dispatcharr == true, dispatcharrOn)
        let i = flag(ICLOUD, stored?.icloud == true, icloudOn)
        let g = stored?.googleDrive == true
        let changed = stored == nil || d != stored!.dispatcharr || i != stored!.icloud
        let rec = changed ? SyncProvidersRecord(dispatcharr: d, googleDrive: g, icloud: i, updatedAt: nowMs, deviceId: deviceId) : stored
        return Push(record: rec, reported: rep)
    }

    /// Providers to offer here: the record says the owner runs it and it is off here.
    /// Dispatcharr only when the active playlist is Dispatcharr Direct Connect. Google Drive never on Apple.
    static func offers(_ record: SyncProvidersRecord?, icloudOnHere: Bool, dispatcharrOnHere: Bool, activeIsDispatcharr: Bool) -> [String] {
        guard let r = record else { return [] }
        var out: [String] = []
        if r.icloud && !icloudOnHere { out.append(ICLOUD) }
        if r.dispatcharr && !dispatcharrOnHere && activeIsDispatcharr { out.append(DISPATCHARR) }
        return out
    }

    /// "iCloud", "Dispatcharr Sync", or "iCloud and Dispatcharr Sync".
    static func offerNames(_ offers: [String]) -> String {
        offers.compactMap { $0 == ICLOUD ? "iCloud" : $0 == DISPATCHARR ? "Dispatcharr Sync" : nil }.joined(separator: " and ")
    }

    static func offerText(_ offers: [String]) -> String {
        "Your other devices also use \(offerNames(offers)). Turn it on here too?"
    }

    static func toJson(_ r: SyncProvidersRecord) -> DsyncObject {
        DsyncObject([("dispatcharr", .bool(r.dispatcharr)), ("googleDrive", .bool(r.googleDrive)), ("icloud", .bool(r.icloud)),
                     ("updatedAt", .long(r.updatedAt)), ("deviceId", .string(r.deviceId))])
    }

    /// Tolerant: missing booleans read false; a non-object or missing updatedAt reads nil.
    static func fromJson(_ v: DsyncJSON?) -> SyncProvidersRecord? {
        guard let o = v?.asObject, let at = o["updatedAt"]?.asLong else { return nil }
        return SyncProvidersRecord(dispatcharr: o["dispatcharr"]?.asBool ?? false, googleDrive: o["googleDrive"]?.asBool ?? false,
                                   icloud: o["icloud"]?.asBool ?? false, updatedAt: at, deviceId: o["deviceId"]?.asStr ?? "")
    }

    /// The record inside a snapshot body (envelope.syncProviders), or nil.
    static func fromBody(_ body: String) -> SyncProvidersRecord? {
        fromJson(DsyncJSONParser.parseObject(body)?["envelope"]?.asObject?["syncProviders"])
    }
}
