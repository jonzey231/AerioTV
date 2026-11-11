//
//  SyncRules.swift
//  Aerio
//
//  Ordering rules for iCloud sync. Logan 2026-11-10: pre-migration data
//  must never overwrite post-migration data; stale data never beats newer
//  data. Pure logic (Foundation only, no app singletons), so
//  Scripts/sync-tests/run.sh compiles it with swiftc and checks it.
//

import Foundation
import CryptoKit

// MARK: - Preferences clock

/// Fingerprints for the preferences payload (whole blob or one value).
enum PrefsSyncClock {
    /// Stable fingerprint of a preferences blob, so "unchanged" survives a
    /// relaunch: dictionary order, JSON key order inside data blobs, and
    /// NSNumber boxing do not change it. FNV-1a 64 over a canonical form.
    static func fingerprint(_ dict: [String: Any]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in canonical(dict).utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    static func canonical(_ value: Any) -> String {
        switch value {
        case let d as [String: Any]:
            return "{" + d.keys.sorted().map { "\(canonical($0))=\(canonical(d[$0]!))" }.joined(separator: ",") + "}"
        case let a as [Any]:
            return "[" + a.map { canonical($0) }.joined(separator: ",") + "]"
        case let s as String:
            return "s\(s.utf8.count):\(s)"
        case let data as Data:
            if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return "j" + canonical(obj)
            }
            return "d" + data.base64EncodedString()
        case let date as Date:
            return "t\(date.timeIntervalSince1970)"
        case let n as NSNumber:
            return "n\(n.stringValue)"
        case is NSNull:
            return "null"
        default:
            return "?\(value)"
        }
    }
}

// MARK: - Per item merge (Android DriveMerge port, 2026-11-10)

/// Shared constants and the snapshot merge. A push never replaces a whole
/// list: it re-reads iCloud and merges per item, the newest change time wins,
/// a tie keeps iCloud's copy, and deletions travel as deletion times
/// (tombstones) merged by the same rule.
enum SyncMerge {
    /// Deletion times older than this are dropped (Android TOMBSTONE_TTL_MS).
    static let tombstoneTTL: TimeInterval = 90 * 24 * 3600
    /// A reminder whose program ended this long ago is dropped.
    static let reminderGrace: TimeInterval = 24 * 3600

    /// Android DriveMerge.byStamp: newest `stamp` per `id` wins, a tie keeps
    /// the remote. Remote order first, then local-only items. Nothing is
    /// dropped: only a tombstone removes an item.
    static func byStamp<T>(remote: [T], local: [T], id: (T) -> String, stamp: (T) -> Int64,
                           onLocalWin: (T, T) -> T = { l, _ in l }) -> [T] {
        var localById: [String: T] = [:]
        var localOrder: [String] = []
        for l in local {
            let k = id(l)
            if localById[k] == nil { localOrder.append(k) }
            localById[k] = l
        }
        var out: [T] = []
        var seen = Set<String>()
        for r in remote {
            let k = id(r)
            guard seen.insert(k).inserted else { continue }
            if let l = localById[k], stamp(l) > stamp(r) { out.append(onLocalWin(l, r)) } else { out.append(r) }
        }
        for k in localOrder where seen.insert(k).inserted { out.append(localById[k]!) }
        return out
    }

    /// The merged file's change time: the newest item time it carries, never
    /// the push time, and never older than the remote's own.
    static func mergedTime(remote: Int64?, items: [Int64]) -> Int64 {
        max(remote ?? 0, items.max() ?? 0)
    }

    /// An existing file keeps its own format; a brand-new file is current.
    static func mergedFormat(remoteExists: Bool, remoteFormat: Int?, current: Int) -> Int? {
        remoteExists ? remoteFormat : current
    }

    /// Whether a merged item stays: a tombstone within its TTL, a live item always.
    static func keepTombstone(removedAt: Int64?, nowMs: Int64) -> Bool {
        guard let removedAt else { return true }
        return removedAt >= nowMs - Int64(tombstoneTTL * 1000)
    }

    /// Reminders: a live one stays until its program ended a day ago.
    static func keepReminder(removedAt: Int64?, endMs: Int64, nowMs: Int64) -> Bool {
        if removedAt != nil { return keepTombstone(removedAt: removedAt, nowMs: nowMs) }
        return endMs >= nowMs - Int64(reminderGrace * 1000)
    }
}

/// The older iCloud preferences key (`syncedPreferences`) per key (Logan
/// 2026-11-10, Android DriveMerge prefs): every value carries the time it
/// last changed on a device ("v:key" for the shared map, "tv:key" and
/// "mobile:key" for the device lanes) in `_prefsTimes`; a push merges per key
/// (newest wins, a tie keeps iCloud's), a pull applies only the keys that
/// changed elsewhere after they changed here. A blob from an older build has
/// no times: its `_prefsModifiedAt` stands in for every key.
enum PrefsLaneMerge {
    static let timesKey = "_prefsTimes"

    /// "lane:key" values. `lanes`: blob key of a lane dict to its lane name.
    static func flatten(_ blob: [String: Any], lanes: [String: String], skip: Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in blob where !skip.contains(k) {
            if let lane = lanes[k] {
                for (sk, sv) in v as? [String: Any] ?? [:] { out["\(lane):\(sk)"] = sv }
            } else {
                out["v:\(k)"] = v
            }
        }
        return out
    }

    static func unflatten(_ flat: [String: Any], lanes: [String: String]) -> [String: Any] {
        var laneKey: [String: String] = [:]
        for (k, name) in lanes { laneKey[name] = k }
        var out: [String: Any] = [:]
        for (fk, v) in flat {
            guard let i = fk.firstIndex(of: ":") else { continue }
            let lane = String(fk[..<i])
            let k = String(fk[fk.index(after: i)...])
            if lane == "v" {
                out[k] = v
            } else if let lk = laneKey[lane] {
                var d = out[lk] as? [String: Any] ?? [:]
                d[k] = v
                out[lk] = d
            }
        }
        return out
    }

    static func valueID(_ v: Any) -> String { PrefsSyncClock.fingerprint(["v": v]) }

    /// Change times from what this device last saw: a key whose value
    /// differs changed now. No record yet (first run): record only, so
    /// today's values are of unknown age and never outrank iCloud's.
    static func observe(flat: [String: Any], seen: [String: String]?, times: [String: TimeInterval],
                        now: TimeInterval) -> (seen: [String: String], times: [String: TimeInterval]) {
        let ids = flat.mapValues(valueID)
        guard let seen else { return (ids, times) }
        var out = times
        for (k, id) in ids where seen[k] != id { out[k] = now }
        return (ids, out)
    }

    static func remoteTime(_ times: [String: TimeInterval], key: String, blobStamp: TimeInterval) -> TimeInterval {
        times[key] ?? (times.isEmpty ? blobStamp : 0)
    }

    /// Push: per key newest wins, a tie keeps iCloud's; keys only one side has
    /// are kept. `localNewer`: keys this device wins (nothing to write without).
    static func merge(local: [String: Any], localTimes: [String: TimeInterval], remote: [String: Any],
                      remoteTimes: [String: TimeInterval], remoteStamp: TimeInterval)
        -> (values: [String: Any], times: [String: TimeInterval], localNewer: [String], remoteNewer: [String]) {
        var values = remote
        var times: [String: TimeInterval] = [:]
        var localNewer: [String] = []
        var remoteNewer: [String] = []
        for k in remote.keys { times[k] = remoteTime(remoteTimes, key: k, blobStamp: remoteStamp) }
        for (k, lv) in local {
            let lt = localTimes[k] ?? 0
            if let rv = remote[k] {
                let rt = times[k] ?? 0
                if lt > rt {
                    values[k] = lv
                    times[k] = lt
                    if valueID(lv) != valueID(rv) { localNewer.append(k) }
                } else if rt > lt, valueID(lv) != valueID(rv) {
                    remoteNewer.append(k)
                }
            } else {
                values[k] = lv
                times[k] = lt
                localNewer.append(k)
            }
        }
        return (values, times, localNewer.sorted(), remoteNewer.sorted())
    }

    /// Pull: the keys whose iCloud value changed after this device's did.
    static func newerRemote(local: [String: Any], localTimes: [String: TimeInterval], remote: [String: Any],
                            remoteTimes: [String: TimeInterval], remoteStamp: TimeInterval) -> [String] {
        remote.compactMap { k, rv in
            let rt = remoteTime(remoteTimes, key: k, blobStamp: remoteStamp)
            guard rt > (localTimes[k] ?? 0) else { return nil }
            if let lv = local[k], valueID(lv) == valueID(rv) { return nil }
            return k
        }.sorted()
    }
}

/// Per-key preference times (Android DriveMerge prefs), keys "lane:key".
enum PrefKeyMerge {
    struct State: Equatable {
        var v: [String: String]
        var tv: [String: String]
        var mobile: [String: String]
        var times: [String: Int64]
        func lane(_ name: String) -> [String: String] { name == "tv" ? tv : name == "mobile" ? mobile : v }
    }
    static let lanes = ["v", "tv", "mobile"]

    /// The remote time of `lane:key`: its own, else the envelope time for an
    /// older file that carries none.
    static func remoteTime(_ times: [String: Int64], lane: String, key: String, envelope: Int64) -> Int64 {
        times["\(lane):\(key)"] ?? (times.isEmpty ? envelope : 0)
    }

    /// Per key newest wins; a tie keeps the remote; keys only one side has are kept.
    static func merge(remote: State?, remoteEnvelope: Int64, local: State) -> State {
        var out: [String: [String: String]] = ["v": [:], "tv": [:], "mobile": [:]]
        var times: [String: Int64] = [:]
        for lane in lanes {
            let rl = remote?.lane(lane) ?? [:]
            let ll = local.lane(lane)
            for (k, rv) in rl {
                let rt = remoteTime(remote?.times ?? [:], lane: lane, key: k, envelope: remoteEnvelope)
                let lt = local.times["\(lane):\(k)"] ?? 0
                if let lv = ll[k], lt > rt { out[lane]![k] = lv; times["\(lane):\(k)"] = lt }
                else { out[lane]![k] = rv; times["\(lane):\(k)"] = rt }
            }
            for (k, lv) in ll where rl[k] == nil {
                out[lane]![k] = lv
                times["\(lane):\(k)"] = local.times["\(lane):\(k)"] ?? 0
            }
        }
        return State(v: out["v"]!, tv: out["tv"]!, mobile: out["mobile"]!, times: times)
    }

    /// Local change times from the values last synced (`baseline`, "lane:key"
    /// to value): a key whose value differs changed here, now. No baseline
    /// yet (first run): nothing is stamped; those values never outrank iCloud's.
    static func localTimes(_ local: State, baseline: [String: String]?, previous: [String: Int64], nowMs: Int64) -> [String: Int64] {
        guard let baseline else { return previous }
        var out = previous
        for lane in lanes {
            for (k, v) in local.lane(lane) where baseline["\(lane):\(k)"] != v { out["\(lane):\(k)"] = nowMs }
        }
        return out
    }

    static func flat(_ s: State) -> [String: String] {
        var out: [String: String] = [:]
        for lane in lanes { for (k, v) in s.lane(lane) { out["\(lane):\(k)"] = v } }
        return out
    }
}

/// The keyed lists SyncManager keeps in iCloud's older keys (watch progress,
/// reminders, playlists, favorites). Live rows ride the list older AerioTV
/// builds read; deletion times ride a side key they ignore. Older builds
/// still delete by leaving a row out, so `base` (what this device last saw
/// in iCloud) lets an absence count as a deletion, but only once a pull has
/// recorded it: with no record (first launch after this update) nothing is
/// deleted for being absent.
enum LaneMerge {
    struct Side: Equatable {
        var live: [String: TimeInterval]
        var removed: [String: TimeInterval]
        init(live: [String: TimeInterval] = [:], removed: [String: TimeInterval] = [:]) {
            self.live = live
            self.removed = removed
        }
    }

    enum Pick: Equatable {
        /// This device's live row.
        case local
        /// iCloud's live row.
        case remote
        /// Deleted at this time (the tombstone travels on).
        case removed(TimeInterval)
        /// Deleted by an older build (left out of iCloud's list): no tombstone.
        case gone
    }

    private enum Event { case live(TimeInterval), removed(TimeInterval) }

    private static func event(_ s: Side, _ k: String) -> Event? {
        switch (s.live[k], s.removed[k]) {
        case let (l?, r?): return l >= r ? .live(l) : .removed(r)
        case let (l?, nil): return .live(l)
        case let (nil, r?): return .removed(r)
        default: return nil
        }
    }

    private static func time(_ e: Event) -> TimeInterval {
        switch e { case .live(let t), .removed(let t): return t }
    }

    static func plan(local: Side, remote: Side, base: [String: TimeInterval]?, now: TimeInterval,
                     ttl: TimeInterval = SyncMerge.tombstoneTTL) -> [String: Pick] {
        var out: [String: Pick] = [:]
        let keys = Set(local.live.keys).union(local.removed.keys).union(remote.live.keys).union(remote.removed.keys)
        for k in keys {
            let pick: Pick
            switch (event(local, k), event(remote, k)) {
            case let (l?, r?):
                // Newest wins; a tie keeps iCloud's copy.
                if time(r) >= time(l) {
                    if case .removed(let t) = r { pick = .removed(t) } else { pick = .remote }
                } else {
                    if case .removed(let t) = l { pick = .removed(t) } else { pick = .local }
                }
            case let (l?, nil):
                switch l {
                case .removed(let t): pick = .removed(t)
                case .live(let t):
                    if let seen = base?[k], t <= seen { pick = .gone } else { pick = .local }
                }
            case let (nil, r?):
                switch r {
                case .removed(let t): pick = .removed(t)
                case .live(let t):
                    if let seen = base?[k], t <= seen { pick = .gone } else { pick = .remote }
                }
            case (nil, nil):
                continue
            }
            if case .removed(let t) = pick, t < now - ttl { continue }
            out[k] = pick
        }
        return out
    }

    /// The record after a push: keys this device holds live. A row kept from
    /// iCloud that is not here yet is left out so the next pull inserts it.
    static func baseAfterPush(local: Side, remote: Side, base: [String: TimeInterval]?,
                              plan: [String: Pick]) -> [String: TimeInterval] {
        var out: [String: TimeInterval] = [:]
        for (k, l) in local.live {
            switch plan[k] {
            case .local?: out[k] = l
            case .remote?: out[k] = remote.live[k] ?? l
            default: if let seen = base?[k] { out[k] = seen }
            }
        }
        return out
    }

    /// A push of a dictionary-row list: live rows to write, tombstones to
    /// write, the new record, and counts for the log.
    static func forPush(local: [String: [String: Any]], localRemoved: [String: TimeInterval],
                        remote: [String: [String: Any]], remoteRemoved: [String: TimeInterval],
                        base: [String: TimeInterval]?, stamp: ([String: Any]) -> TimeInterval, now: TimeInterval)
        -> (rows: [[String: Any]], removed: [String: TimeInterval], base: [String: TimeInterval], keptFromCloud: Int) {
        let l = Side(live: local.mapValues(stamp), removed: localRemoved)
        let r = Side(live: remote.mapValues(stamp), removed: remoteRemoved)
        let plan = Self.plan(local: l, remote: r, base: base, now: now)
        var rows: [(String, [String: Any])] = []
        var removed: [String: TimeInterval] = [:]
        var kept = 0
        for (k, p) in plan {
            switch p {
            case .local: if let e = local[k] { rows.append((k, e)) }
            case .remote:
                if let e = remote[k] { rows.append((k, e)) }
                if local[k] == nil { kept += 1 }
            case .removed(let t): removed[k] = t
            case .gone: break
            }
        }
        rows.sort { stamp($0.1) != stamp($1.1) ? stamp($0.1) > stamp($1.1) : $0.0 < $1.0 }
        return (rows.map(\.1), removed, baseAfterPush(local: l, remote: r, base: base, plan: plan), kept)
    }
}

/// The watch-progress payload (`syncedWatchProgress`) rows.
enum WatchProgressSyncMerge {
    /// `serverID|vodID`, the composite identity SyncManager merges on.
    static func key(_ entry: [String: Any]) -> String? {
        guard let vodID = entry["vodID"] as? String else { return nil }
        return "\(entry["serverID"] as? String ?? "")|\(vodID)"
    }

    static func stamp(_ entry: [String: Any]) -> TimeInterval {
        entry["updatedAt"] as? TimeInterval ?? 0
    }

    /// One row per key, the newest when a list repeats one.
    static func byKey(_ list: [[String: Any]], key: ([String: Any]) -> String?,
                      stamp: ([String: Any]) -> TimeInterval) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for entry in list {
            guard let k = key(entry) else { continue }
            if let old = out[k], stamp(old) >= stamp(entry) { continue }
            out[k] = entry
        }
        return out
    }
}

/// Favorites ride the preferences payload: the member list and order older
/// builds read, plus `favorites.sync.v1` (change times, deletion times, the
/// order's time) they ignore. Merged per favorite like the keyed lists.
enum FavoritesSyncMerge {
    struct State: Equatable {
        var side: LaneMerge.Side
        var order: [String]
        var orderAt: TimeInterval
    }

    /// The favorites a preferences payload carries; nil when it has none.
    static func state(from d: [String: Any], idsKey: String = "favoriteChannelIDs", orderKey: String = "favoriteOrder",
                      blobKey: String = "favorites.sync.v1") -> State? {
        let blob = d[blobKey] as? [String: Any]
        guard let ids = d[idsKey] as? [String] ?? (blob != nil ? [] : nil) else { return nil }
        let touched = blob?["touched"] as? [String: TimeInterval] ?? [:]
        var live: [String: TimeInterval] = [:]
        for id in ids { live[id] = touched[id] ?? 0 }
        return State(side: .init(live: live, removed: blob?["removed"] as? [String: TimeInterval] ?? [:]),
                     order: d[orderKey] as? [String] ?? [], orderAt: blob?["orderAt"] as? TimeInterval ?? 0)
    }

    static func blob(_ s: State) -> [String: Any] {
        ["touched": s.side.live.filter { $0.value > 0 }, "removed": s.side.removed, "orderAt": s.orderAt]
    }

    /// Whether the favorites both lists hold changed their relative order.
    static func reordered(_ old: [String], _ new: [String]) -> Bool {
        let common = Set(old).intersection(new)
        return old.filter(common.contains) != new.filter(common.contains)
    }

    /// The merged favorites: members (in order), the merged times, and the plan.
    /// The newer order wins (a tie keeps iCloud's); members it lacks follow.
    /// With no favorites in iCloud nothing is deleted for being absent.
    static func merge(local: State, remote: State?, base: [String: TimeInterval]?, now: TimeInterval)
        -> (order: [String], state: State, plan: [String: LaneMerge.Pick]) {
        let r = remote ?? State(side: .init(), order: [], orderAt: 0)
        let plan = LaneMerge.plan(local: local.side, remote: r.side, base: remote == nil ? nil : base, now: now)
        var live: [String: TimeInterval] = [:]
        var removed: [String: TimeInterval] = [:]
        for (k, p) in plan {
            switch p {
            case .local: live[k] = local.side.live[k] ?? 0
            case .remote: live[k] = r.side.live[k] ?? 0
            case .removed(let t): removed[k] = t
            case .gone: break
            }
        }
        let remoteFirst = r.orderAt >= local.orderAt
        let lists = remoteFirst ? [r.order, local.order] : [local.order, r.order]
        var order: [String] = []
        var placed = Set<String>()
        for id in lists[0] + lists[1] + live.keys.sorted() where live[id] != nil && placed.insert(id).inserted {
            order.append(id)
        }
        return (order, State(side: .init(live: live, removed: removed), order: order, orderAt: max(r.orderAt, local.orderAt)), plan)
    }
}

// MARK: - Local change records

/// This device's own change and removal times per item, per category
/// (Android SyncStamps). Removals are found by comparing the live keys with
/// the ones seen last time; a merge settles what it applied so it never
/// reads as a local change.
final class SyncStamps {
    let category: String
    private let defaults: UserDefaults
    private var key: String { "syncStamps.\(category).v1" }

    private(set) var touched: [String: TimeInterval] = [:]
    private(set) var removed: [String: TimeInterval] = [:]
    /// Live keys at the last look; nil before the first (nothing inferred then).
    private(set) var known: Set<String>?

    init(_ category: String, defaults: UserDefaults = .standard) {
        self.category = category
        self.defaults = defaults
        if let d = defaults.dictionary(forKey: key) {
            touched = d["touched"] as? [String: TimeInterval] ?? [:]
            removed = d["removed"] as? [String: TimeInterval] ?? [:]
            if let k = d["known"] as? [String] { known = Set(k) }
        }
    }

    private func save() {
        var d: [String: Any] = ["touched": touched, "removed": removed]
        if let known { d["known"] = known.sorted() }
        defaults.set(d, forKey: key)
    }

    /// This device's live keys now. A key gone since the last look was
    /// removed here now; a key that appeared was added here now (clearing an
    /// older removal). The first look only records.
    func observe(live: Set<String>, now: TimeInterval) {
        // Nothing changed: no write (callers run on every preferences build).
        guard known != live else { return }
        defer { known = live; save() }
        guard let known else { return }
        for k in known.subtracting(live) {
            removed[k] = max(removed[k] ?? 0, now)
            touched[k] = nil
        }
        for k in live.subtracting(known) {
            removed[k] = nil
            touched[k] = now
        }
    }

    func touch(_ k: String, at t: TimeInterval) {
        guard touched[k] != t else { return }
        touched[k] = t
        save()
    }

    /// After a merge: what it applied is the synced state, not a local change.
    func settle(live: Set<String>, removed applied: [String: TimeInterval] = [:], touched t: [String: TimeInterval] = [:]) {
        for (k, at) in applied { removed[k] = max(removed[k] ?? 0, at); touched[k] = nil }
        for (k, at) in t { touched[k] = at; if let r = removed[k], r <= at { removed[k] = nil } }
        known = live
        save()
    }

    /// Drops deletion times older than the TTL.
    func prune(now: TimeInterval, ttl: TimeInterval = SyncMerge.tombstoneTTL) {
        let before = removed.count
        removed = removed.filter { $0.value >= now - ttl }
        if removed.count != before { save() }
    }

    func reset() {
        touched = [:]
        removed = [:]
        known = nil
        defaults.removeObject(forKey: key)
    }
}

// MARK: - First download

/// A fresh device never writes to iCloud before iCloud's copy has reached
/// it (or iCloud reported none). The key-value store gives no "empty"
/// answer, so the signals are: a change delivered from iCloud, any synced
/// key already in the local copy, or this device having synced before.
/// Until one arrives pushes wait; the timeout only logs and keeps waiting.
enum FirstDownloadGate {
    enum State: Equatable { case done, waiting }

    /// `probeSurvived`: a key this install wrote while waiting is still in
    /// iCloud's copy after a relaunch. The store discards writes made before
    /// its first download, so a surviving probe means the download happened
    /// and iCloud simply had nothing: the "iCloud reports empty" signal.
    static func state(alreadyDone: Bool, deliveredFromCloud: Bool, cloudHasData: Bool, syncedBefore: Bool,
                      probeSurvived: Bool = false) -> State {
        alreadyDone || deliveredFromCloud || cloudHasData || syncedBefore || probeSurvived ? .done : .waiting
    }

    /// The probe counts only when written in an earlier launch and read back unchanged.
    static func probeSurvived(written: String?, writtenInLaunch: String?, currentLaunch: String, readBack: String?) -> Bool {
        guard let written, let writtenInLaunch, writtenInLaunch != currentLaunch else { return false }
        return readBack == written
    }

    /// How long a push waits before the wait is logged (it keeps waiting).
    static let timeout: TimeInterval = 30
}

// MARK: - One playlist across devices (2026-11-10)

/// One server account is one playlist (shared spec playlist-identity-spec.md).
/// Identity: source type + normalized URL + account (the username when
/// known, else a fingerprint of the API key; never the key). M3U: type +
/// normalized playlist URL with its query.
enum PlaylistIdentity {
    struct Row: Equatable {
        var id: String
        /// "dispatcharr", "xtream", or "m3u".
        var type: String
        var url: String
        var username: String = ""
        var apiKeyFP: String = ""
        /// The playlist's known change time (0 unknown).
        var changedAt: TimeInterval = 0
        /// When the playlist was first added (0 unknown).
        var createdAt: TimeInterval = 0
    }

    /// scheme://host[:port]/path, host and scheme lowercased, the default
    /// port and trailing slashes dropped; the query only when asked (M3U).
    static func normalizedURL(_ raw: String, keepQuery: Bool = false) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "http://" + t }
        guard let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port = c.port.flatMap { $0 == defaultPort ? nil : $0 }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        var out = "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")\(path)"
        if keepQuery, let q = c.query, !q.isEmpty { out += "?" + q }
        return out
    }

    /// SHA-256 of the key, first 8 bytes in hex; "" for a blank key.
    static func keyFingerprint(_ key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return "" }
        return SHA256.hash(data: Data(k.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The same server account: same type and URL, then the usernames when
    /// both are known, else the key fingerprints when both are known.
    static func sameAccount(_ a: Row, _ b: Row) -> Bool {
        guard a.type == b.type else { return false }
        let m3u = a.type == "m3u"
        guard let ua = normalizedURL(a.url, keepQuery: m3u), ua == normalizedURL(b.url, keepQuery: m3u) else { return false }
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch a.type {
        case "m3u":
            return true
        case "xtream":
            return !t(a.username).isEmpty && t(a.username) == t(b.username)
        default:
            if !t(a.username).isEmpty, !t(b.username).isEmpty { return t(a.username).lowercased() == t(b.username).lowercased() }
            return !a.apiKeyFP.isEmpty && a.apiKeyFP == b.apiKeyFP
        }
    }

    /// Every device picks the same winner: the newest change time; on equal
    /// change times the OLDER creation time (the original, not a later copy)
    /// when both are known; then the smaller lowercase id (ids compare
    /// case-insensitively: Apple writes uppercase UUIDs).
    static func winner(_ a: Row, _ b: Row) -> Row {
        if a.changedAt != b.changedAt { return a.changedAt > b.changedAt ? a : b }
        if a.createdAt > 0, b.createdAt > 0, a.createdAt != b.createdAt { return a.createdAt < b.createdAt ? a : b }
        return a.id.lowercased() <= b.id.lowercased() ? a : b
    }

    /// Rows that are one playlist: loser id to winner id (empty when none).
    static func losers(_ rows: [Row]) -> [String: String] {
        var parent = Array(rows.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in rows.indices { for j in rows.indices where j > i && sameAccount(rows[i], rows[j]) {
            let a = find(i), b = find(j)
            if a != b { parent[b] = a }
        } }
        var groups: [Int: [Row]] = [:]
        for i in rows.indices { groups[find(i), default: []].append(rows[i]) }
        var out: [String: String] = [:]
        for group in groups.values where group.count > 1 {
            let w = group.dropFirst().reduce(group[0]) { winner($0, $1) }
            for r in group where r.id.lowercased() != w.id.lowercased() { out[r.id] = w.id }
        }
        return out
    }
}

/// What a device holding a losing row moves to the winner before deleting it.
enum PlaylistMergePlan {
    struct Facts: Equatable {
        var active = false
        var apiKey = ""
        var apiKeyRejected = false
        var password = ""
        var catchupOffset: Int? = nil
        var recordingDestination = ""
        /// When this device last changed the key (0 unknown).
        var apiKeyChangedAt: TimeInterval = 0
    }

    struct Plan: Equatable {
        var makeWinnerActive = false
        var copyApiKey = false
        var copyPassword = false
        var copyCatchupOffset = false
        var copyRecordingDestination = false
    }

    static func plan(loser: Facts, winner: Facts, defaultDestination: String) -> Plan {
        Plan(
            makeWinnerActive: loser.active && !winner.active,
            // Keep the working sign-in: a working key on the loser replaces a
            // rejected or missing one; between two working keys, the one this
            // device is using (the active row), then the newer. Never blanks one.
            copyApiKey: !loser.apiKey.isEmpty && !loser.apiKeyRejected && loser.apiKey != winner.apiKey
                && (winner.apiKey.isEmpty || winner.apiKeyRejected
                    || (loser.active && !winner.active)
                    || (loser.active == winner.active && loser.apiKeyChangedAt > winner.apiKeyChangedAt)),
            copyPassword: !loser.password.isEmpty && winner.password.isEmpty,
            copyCatchupOffset: loser.catchupOffset != nil && winner.catchupOffset == nil,
            copyRecordingDestination: winner.recordingDestination == defaultDestination
                && !loser.recordingDestination.isEmpty && loser.recordingDestination != defaultDestination)
    }

    /// Per-row data (watch progress, My List) keyed the same on both rows:
    /// rows only the loser has move over; a row both have keeps the newer
    /// copy (a tie keeps the winner's).
    static func rows(loser: [String: TimeInterval], winner: [String: TimeInterval])
        -> (move: [String], loserNewer: [String], winnerKeeps: [String]) {
        var move: [String] = []
        var newer: [String] = []
        var keeps: [String] = []
        for (k, lt) in loser {
            if let wt = winner[k] { if lt > wt { newer.append(k) } else { keeps.append(k) } } else { move.append(k) }
        }
        return (move.sorted(), newer.sorted(), keeps.sorted())
    }
}

// MARK: - Credentials

/// Whether a credential carried by the iCloud server list replaces this
/// device's. Stamps are the time each device last changed that credential
/// (0 when unknown: older clients, or set before this rule shipped).
enum CredentialSyncRule {
    static func adoptRemote(remote: String, remoteStamp: TimeInterval,
                            local: String, localStamp: TimeInterval,
                            legacyRemoteNewer: Bool, replace: Bool, rejected: Bool,
                            localRejected: Bool = false) -> Bool {
        // Never empty, never a key the server refused, nothing to do when equal.
        guard !remote.isEmpty, !rejected, remote != local else { return false }
        // Fill in a credential this device does not have.
        if local.isEmpty { return true }
        // A key the server refused never beats one it has not (real-iCloud
        // test 2026-11-10: an Apple TV kept its rejected key over iCloud's
        // because neither copy carried a change time).
        if localRejected { return true }
        // Known change times: only a newer one wins, even on a Replace.
        if remoteStamp > 0 || localStamp > 0 { return remoteStamp > localStamp }
        // Neither side stamped: the shipped rule (newer playlist record).
        return replace || legacyRemoteNewer
    }
}
