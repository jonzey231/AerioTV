// iCloud sync ordering rules (Shared/SyncRules.swift). Logan 2026-11-10:
// pre-migration data must never overwrite post-migration data; stale data
// never beats newer data.

import Foundation

extension PlaylistIdentity.Row {
    func withUser(_ u: String) -> PlaylistIdentity.Row { var r = self; r.username = u; return r }
}

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL \(line): \(msg)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    check(a == b, "\(msg): expected \(b), got \(a)", line: line)
}

// MARK: - Preference stamps

// The older preferences key, per key.
do {
    let lanes = ["prefs.tv": "tv", "prefs.mobile": "mobile"]
    let blob: [String: Any] = ["a": 1, "b": "x", "prefs.tv": ["t": true], "_prefsModifiedAt": 5.0, "favoriteChannelIDs": ["c"]]
    let flat = PrefsLaneMerge.flatten(blob, lanes: lanes, skip: ["_prefsModifiedAt", "favoriteChannelIDs"])
    eq(Set(flat.keys), ["v:a", "v:b", "tv:t"], "flatten: shared map, lanes, skipped keys left out")
    let back = PrefsLaneMerge.unflatten(flat, lanes: lanes)
    eq((back["prefs.tv"] as? [String: Any])?["t"] as? Bool, true, "unflatten restores the lane")
    eq(back["b"] as? String, "x", "unflatten restores the shared map")

    let first = PrefsLaneMerge.observe(flat: ["v:a": 1], seen: nil, times: [:], now: 100)
    check(first.times.isEmpty, "first run: nothing stamped (unknown age)")
    let second = PrefsLaneMerge.observe(flat: ["v:a": 2, "v:b": "x"], seen: first.seen, times: first.times, now: 200)
    eq(second.times["v:a"], 200, "a changed value is stamped when seen")
    eq(second.times["v:b"], 200, "a new key is stamped when seen")
    let third = PrefsLaneMerge.observe(flat: ["v:a": 2, "v:b": "x"], seen: second.seen, times: second.times, now: 300)
    eq(third.times["v:a"], 200, "an unchanged value keeps its time (never moved forward)")

    // Different settings changed on each device both survive.
    let m = PrefsLaneMerge.merge(local: ["v:x": "mine", "v:y": "old"], localTimes: ["v:x": 500, "v:y": 100],
                                 remote: ["v:x": "old", "v:y": "theirs"], remoteTimes: ["v:x": 100, "v:y": 600], remoteStamp: 600)
    eq(m.values["v:x"] as? String, "mine", "the setting changed here wins its key")
    eq(m.values["v:y"] as? String, "theirs", "the setting changed elsewhere wins its key")
    eq(m.localNewer, ["v:x"], "only the newer local key counts as newer")
    eq(m.remoteNewer, ["v:y"], "the newer remote key is reported")
    let tie = PrefsLaneMerge.merge(local: ["v:x": "mine"], localTimes: ["v:x": 500], remote: ["v:x": "theirs"],
                                   remoteTimes: ["v:x": 500], remoteStamp: 500)
    eq(tie.values["v:x"] as? String, "theirs", "a tie keeps iCloud's value")
    check(tie.localNewer.isEmpty, "a tie is nothing newer to write")
    let stale = PrefsLaneMerge.merge(local: ["v:x": "stale"], localTimes: [:], remote: ["v:x": "new"], remoteTimes: ["v:x": 50],
                                     remoteStamp: 50)
    eq(stale.values["v:x"] as? String, "new", "an unknown-age value never beats a timed one")
    check(stale.localNewer.isEmpty, "a stale device has nothing newer to write")
    let older = PrefsLaneMerge.merge(local: ["v:x": "mine"], localTimes: ["v:x": 400], remote: ["v:x": "theirs"],
                                     remoteTimes: [:], remoteStamp: 700)
    eq(older.values["v:x"] as? String, "theirs", "an older build's blob: its stamp stands in for every key")
    let onlyHere = PrefsLaneMerge.merge(local: ["v:z": 1], localTimes: [:], remote: [:], remoteTimes: [:], remoteStamp: 0)
    eq(onlyHere.localNewer, ["v:z"], "a key iCloud lacks is written")
    let pull = PrefsLaneMerge.newerRemote(local: ["v:x": "a", "v:y": "b"], localTimes: ["v:x": 500, "v:y": 100],
                                          remote: ["v:x": "c", "v:y": "d", "v:w": "e"], remoteTimes: ["v:x": 400, "v:y": 600, "v:w": 10],
                                          remoteStamp: 600)
    eq(pull, ["v:w", "v:y"], "pull applies only keys that changed elsewhere later")
    let samePull = PrefsLaneMerge.newerRemote(local: ["v:x": "a"], localTimes: [:], remote: ["v:x": "a"], remoteTimes: ["v:x": 9],
                                              remoteStamp: 9)
    check(samePull.isEmpty, "an equal value is not re-applied")
}

// Fingerprint: unchanged data stays unchanged across a relaunch.
let a: [String: Any] = ["b": 1, "a": "x", "lane": ["k": true, "j": 2.5],
                        "blob": Data(#"{"z":1,"a":[1,2]}"#.utf8), "list": ["p", "q"]]
let b: [String: Any] = ["lane": ["j": 2.5, "k": true], "list": ["p", "q"], "a": "x",
                        "blob": Data(#"{"a":[1,2],"z":1}"#.utf8), "b": NSNumber(value: 1)]
eq(PrefsSyncClock.fingerprint(a), PrefsSyncClock.fingerprint(b), "key order and JSON key order do not change the fingerprint")
var c = a; c["a"] = "y"
check(PrefsSyncClock.fingerprint(a) != PrefsSyncClock.fingerprint(c), "a changed value changes the fingerprint")
var d = a; d["list"] = ["q", "p"]
check(PrefsSyncClock.fingerprint(a) != PrefsSyncClock.fingerprint(d), "list order is data")
var e = a; e["blob"] = Data(#"{"a":[1,2],"z":2}"#.utf8)
check(PrefsSyncClock.fingerprint(a) != PrefsSyncClock.fingerprint(e), "a changed blob changes the fingerprint")
check(PrefsSyncClock.fingerprint(["s": "1"]) != PrefsSyncClock.fingerprint(["s": 1]), "string and number differ")

// MARK: - Keyed lists (older iCloud keys: watch progress, reminders, playlists, favorites)

func wp(_ vod: String, _ t: TimeInterval, server: String = "S", pos: Int = 0) -> [String: Any] {
    ["vodID": vod, "serverID": server, "updatedAt": t, "positionMs": pos, "title": vod]
}
func rows(_ list: [[String: Any]]) -> [String: [String: Any]] {
    WatchProgressSyncMerge.byKey(list, key: WatchProgressSyncMerge.key, stamp: WatchProgressSyncMerge.stamp)
}
func push(_ local: [[String: Any]], _ remote: [[String: Any]], localRemoved: [String: TimeInterval] = [:],
          remoteRemoved: [String: TimeInterval] = [:], base: [String: TimeInterval]?, now: TimeInterval = 10_000)
    -> (rows: [[String: Any]], removed: [String: TimeInterval], base: [String: TimeInterval], keptFromCloud: Int) {
    LaneMerge.forPush(local: rows(local), localRemoved: localRemoved, remote: rows(remote), remoteRemoved: remoteRemoved,
                      base: base, stamp: WatchProgressSyncMerge.stamp, now: now)
}
func keys(_ list: [[String: Any]]) -> Set<String> { Set(list.compactMap { $0["vodID"] as? String }) }
func pos(_ list: [[String: Any]], _ vod: String) -> Int? {
    list.first { ($0["vodID"] as? String) == vod }?["positionMs"] as? Int
}

// Nothing that arrived from another device in between is dropped.
do {
    let r = push([wp("m1", 100), wp("m2", 200)], [wp("m1", 100), wp("m3", 300)], base: ["S|m1": 100])
    eq(keys(r.rows), ["m1", "m2", "m3"], "entry that arrived in between is kept")
    eq(r.keptFromCloud, 1, "one kept from iCloud")
    check(r.base["S|m3"] == nil, "kept-from-iCloud entry is not marked seen, so the next pull inserts it")
}
// Newest per entry; a tie keeps iCloud's copy (Android byStamp).
do {
    eq(pos(push([wp("m1", 100, pos: 1)], [wp("m1", 500, pos: 9)], base: nil).rows, "m1"), 9, "newer iCloud row is not overwritten")
    eq(pos(push([wp("m1", 600, pos: 7)], [wp("m1", 500, pos: 9)], base: nil).rows, "m1"), 7, "newer local row wins")
    eq(pos(push([wp("m1", 500, pos: 7)], [wp("m1", 500, pos: 9)], base: nil).rows, "m1"), 9, "tie keeps iCloud's copy")
}
// Deletion times.
do {
    let r = push([wp("m1", 100)], [wp("m1", 100), wp("m2", 200)], localRemoved: ["S|m2": 300], base: nil)
    eq(keys(r.rows), ["m1"], "deleted here: dropped from the list")
    eq(r.removed["S|m2"], 300, "deletion time travels in the side key")
    let r2 = push([], [wp("m2", 900)], localRemoved: ["S|m2": 300], base: nil)
    eq(keys(r2.rows), ["m2"], "an edit made elsewhere after the delete wins")
    check(r2.removed.isEmpty, "and the tombstone is gone")
    let r3 = push([wp("m2", 200)], [], remoteRemoved: ["S|m2": 300], base: nil)
    eq(keys(r3.rows), [], "deleted elsewhere after the last change here: not brought back")
    eq(r3.removed["S|m2"], 300, "remote tombstone kept")
    let r4 = push([wp("m2", 800)], [], remoteRemoved: ["S|m2": 300], base: nil)
    eq(keys(r4.rows), ["m2"], "watched further here after the delete elsewhere: kept")
    let r5 = push([wp("m2", 300)], [], remoteRemoved: ["S|m2": 300], base: nil)
    eq(keys(r5.rows), [], "tie between a row and a tombstone keeps iCloud's (the tombstone)")
    let old = push([], [], localRemoved: ["S|m9": 10_000 - SyncMerge.tombstoneTTL - 1], base: nil)
    check(old.removed.isEmpty, "a deletion time past 90 days is pruned")
}
// First launch after the update (no record): nothing is deleted for being absent.
do {
    let r = push([wp("m1", 100)], [wp("m2", 200)], base: nil)
    eq(keys(r.rows), ["m1", "m2"], "no record: union, nothing dropped")
    let plan = LaneMerge.plan(local: .init(live: ["S|m1": 100, "S|m9": 50]), remote: .init(live: ["S|m1": 100]), base: nil, now: 1_000)
    eq(plan["S|m9"], .local, "no record: a local entry iCloud lacks is kept")
}
// After a pull recorded what iCloud had: an older build's absence deletes.
do {
    let plan = LaneMerge.plan(local: .init(live: ["S|m1": 100, "S|m2": 200]), remote: .init(live: ["S|m1": 100]),
                              base: ["S|m1": 100, "S|m2": 200], now: 1_000)
    eq(plan["S|m2"], .gone, "seen in iCloud, unchanged here, now absent: deleted by an older build")
    let plan2 = LaneMerge.plan(local: .init(live: ["S|m2": 900]), remote: .init(), base: ["S|m2": 200], now: 1_000)
    eq(plan2["S|m2"], .local, "changed here after it was seen: kept")
    let plan3 = LaneMerge.plan(local: .init(live: ["S|new": 400]), remote: .init(), base: ["S|m1": 100], now: 1_000)
    eq(plan3["S|new"], .local, "never seen in iCloud (new here): kept")
}
// Same vodID on two servers stays two entries.
eq(push([wp("7", 100, server: "A")], [wp("7", 200, server: "B")], base: nil).rows.count, 2, "composite key keeps both servers' rows")

// MARK: - Snapshot merge (byStamp)

struct Fav: Equatable { let id: String; let t: Int64; let removed: Bool }
do {
    let remote = [Fav(id: "a", t: 100, removed: false), Fav(id: "b", t: 300, removed: false)]
    let local = [Fav(id: "b", t: 200, removed: false), Fav(id: "a", t: 150, removed: true), Fav(id: "c", t: 50, removed: false)]
    let m = SyncMerge.byStamp(remote: remote, local: local, id: { $0.id }, stamp: { $0.t })
    eq(m.map(\.id), ["a", "b", "c"], "remote order first, then local-only")
    eq(m[0], Fav(id: "a", t: 150, removed: true), "newer local tombstone wins")
    eq(m[1], Fav(id: "b", t: 300, removed: false), "newer remote row wins")
    let tie = SyncMerge.byStamp(remote: [Fav(id: "a", t: 100, removed: false)], local: [Fav(id: "a", t: 100, removed: true)],
                                id: { $0.id }, stamp: { $0.t })
    eq(tie[0].removed, false, "tie keeps iCloud's copy")
}
eq(SyncMerge.mergedTime(remote: 500, items: [100, 900, 300]), 900, "envelope time is the newest item time")
eq(SyncMerge.mergedTime(remote: 1_000, items: [100]), 1_000, "never older than iCloud's own time")
eq(SyncMerge.mergedTime(remote: nil, items: []), 0, "no items: no time (never the push time)")
eq(SyncMerge.mergedFormat(remoteExists: true, remoteFormat: nil, current: 2), nil, "an existing file keeps its format")
eq(SyncMerge.mergedFormat(remoteExists: false, remoteFormat: nil, current: 2), 2, "a new file is current")
do {
    let now: Int64 = 10_000_000_000
    check(SyncMerge.keepReminder(removedAt: nil, endMs: now - 3_600_000, nowMs: now), "reminder that ended an hour ago stays")
    check(!SyncMerge.keepReminder(removedAt: nil, endMs: now - 25 * 3_600_000, nowMs: now), "reminder that ended over a day ago drops")
    check(SyncMerge.keepTombstone(removedAt: now - 89 * 86_400_000, nowMs: now), "tombstone within 90 days stays")
    check(!SyncMerge.keepTombstone(removedAt: now - 91 * 86_400_000, nowMs: now), "tombstone past 90 days drops")
}

// MARK: - Preferences per key

do {
    let remote = PrefKeyMerge.State(v: ["a": "r", "b": "r"], tv: [:], mobile: [:], times: ["v:a": 500, "v:b": 100])
    let local = PrefKeyMerge.State(v: ["a": "l", "b": "l", "c": "l"], tv: [:], mobile: [:], times: ["v:a": 400, "v:b": 200])
    let m = PrefKeyMerge.merge(remote: remote, remoteEnvelope: 0, local: local)
    eq(m.v["a"], "r", "newer remote key wins")
    eq(m.v["b"], "l", "newer local key wins")
    eq(m.v["c"], "l", "local-only key kept")
    let tie = PrefKeyMerge.merge(remote: PrefKeyMerge.State(v: ["a": "r"], tv: [:], mobile: [:], times: ["v:a": 5]), remoteEnvelope: 0,
                                 local: PrefKeyMerge.State(v: ["a": "l"], tv: [:], mobile: [:], times: ["v:a": 5]))
    eq(tie.v["a"], "r", "tie keeps iCloud's value")
    let older = PrefKeyMerge.merge(remote: PrefKeyMerge.State(v: ["a": "r"], tv: [:], mobile: [:], times: [:]), remoteEnvelope: 700,
                                   local: PrefKeyMerge.State(v: ["a": "l"], tv: [:], mobile: [:], times: ["v:a": 600]))
    eq(older.v["a"], "r", "older file without times: its envelope time stands in")
    let first = PrefKeyMerge.localTimes(local, baseline: nil, previous: [:], nowMs: 999)
    check(first.isEmpty, "first run (no baseline): nothing stamped, values of unknown age")
    let later = PrefKeyMerge.localTimes(local, baseline: ["v:a": "l", "v:b": "old"], previous: ["v:a": 400], nowMs: 999)
    eq(later["v:a"], 400, "unchanged key keeps its time")
    eq(later["v:b"], 999, "changed key is stamped now")
}

// MARK: - Favorites (inside the preferences payload)

do {
    let local = FavoritesSyncMerge.State(side: .init(live: ["a": 0, "b": 0, "c": 500], removed: ["d": 400]), order: ["b", "a", "c"], orderAt: 300)
    let remoteDict: [String: Any] = ["favoriteChannelIDs": ["a", "b", "d", "e"], "favoriteOrder": ["a", "b", "d", "e"],
                                     "favorites.sync.v1": ["touched": ["d": 100.0, "e": 600.0], "removed": [String: Double](), "orderAt": 200.0]]
    let remote = FavoritesSyncMerge.state(from: remoteDict)!
    let m = FavoritesSyncMerge.merge(local: local, remote: remote, base: nil, now: 1_000)
    eq(Set(m.order), ["a", "b", "c", "e"], "added elsewhere kept, added here kept, removed here (newer) dropped")
    eq(Array(m.order.prefix(2)), ["b", "a"], "the newer order (here) wins")
    eq(m.state.side.removed["d"], 400, "the removal travels on")
    let older = FavoritesSyncMerge.merge(local: .init(side: .init(live: [:], removed: ["e": 500]), order: [], orderAt: 0),
                                         remote: remote, base: nil, now: 1_000)
    check(older.order.contains("e"), "re-added elsewhere after the removal here: kept")
    let legacy = FavoritesSyncMerge.state(from: ["favoriteChannelIDs": ["x"]])!
    eq(legacy.side.live["x"], 0, "an older build's list: members of unknown age")
    check(FavoritesSyncMerge.state(from: ["other": 1]) == nil, "a payload without favorites has none")
    let none = FavoritesSyncMerge.merge(local: .init(side: .init(live: ["a": 0]), order: ["a"], orderAt: 0), remote: nil,
                                        base: ["a": 0], now: 1_000)
    eq(none.order, ["a"], "no favorites in iCloud: nothing deleted for being absent")
    let gone = FavoritesSyncMerge.merge(local: .init(side: .init(live: ["a": 0, "b": 0]), order: ["a", "b"], orderAt: 0),
                                        remote: FavoritesSyncMerge.state(from: ["favoriteChannelIDs": ["a"]]),
                                        base: ["a": 0, "b": 0], now: 1_000)
    eq(gone.order, ["a"], "after a recorded pull, an older build's removal (absence) applies")
    check(FavoritesSyncMerge.reordered(["a", "b", "c"], ["b", "a", "c", "z"]), "a swap is a reorder")
    check(!FavoritesSyncMerge.reordered(["a", "b"], ["a", "b", "z"]), "an appended member is not a reorder")
}

// MARK: - Local change records

do {
    let suite = "sync-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    let s = SyncStamps("t", defaults: d)
    s.observe(live: ["a", "b"], now: 100)
    check(s.removed.isEmpty && s.touched.isEmpty, "first look only records (nothing inferred)")
    s.observe(live: ["a", "c"], now: 200)
    eq(s.removed["b"], 200, "a key gone since the last look was removed now")
    eq(s.touched["c"], 200, "a new key was added now")
    s.observe(live: ["a", "b", "c"], now: 300)
    check(s.removed["b"] == nil, "re-added clears the removal")
    // A merge settles what it applied: no local change is inferred from it.
    s.settle(live: ["a", "b", "c", "d"], touched: ["d": 250])
    s.observe(live: ["a", "b", "c", "d"], now: 400)
    eq(s.touched["d"], 250, "merge-applied row keeps the remote time")
    s.settle(live: ["a", "c", "d"], removed: ["b": 350])
    eq(s.removed["b"], 350, "merge-applied deletion keeps the remote time")
    let reloaded = SyncStamps("t", defaults: d)
    eq(reloaded.removed["b"], 350, "records persist")
    eq(reloaded.known, ["a", "c", "d"], "known keys persist")
    reloaded.prune(now: 350 + SyncMerge.tombstoneTTL + 1)
    check(reloaded.removed.isEmpty, "prune drops old deletion times")
    d.removePersistentDomain(forName: suite)
}

// MARK: - First download

eq(FirstDownloadGate.state(alreadyDone: false, deliveredFromCloud: false, cloudHasData: false, syncedBefore: false), .waiting,
   "fresh device, nothing from iCloud yet: wait")
eq(FirstDownloadGate.state(alreadyDone: false, deliveredFromCloud: true, cloudHasData: false, syncedBefore: false), .done,
   "iCloud delivered a change: done")
eq(FirstDownloadGate.state(alreadyDone: false, deliveredFromCloud: false, cloudHasData: true, syncedBefore: false), .done,
   "iCloud's copy already here: done")
eq(FirstDownloadGate.state(alreadyDone: false, deliveredFromCloud: false, cloudHasData: false, syncedBefore: true), .done,
   "a device that synced before: done")
eq(FirstDownloadGate.state(alreadyDone: false, deliveredFromCloud: false, cloudHasData: false, syncedBefore: false, probeSurvived: true),
   .done, "iCloud empty (the probe survived a relaunch): done")
check(!FirstDownloadGate.probeSurvived(written: "p1", writtenInLaunch: "L1", currentLaunch: "L1", readBack: "p1"),
      "probe read back in the same launch proves nothing (it may still be discarded)")
check(FirstDownloadGate.probeSurvived(written: "p1", writtenInLaunch: "L1", currentLaunch: "L2", readBack: "p1"),
      "probe still there after a relaunch: the write was accepted")
check(!FirstDownloadGate.probeSurvived(written: "p1", writtenInLaunch: "L1", currentLaunch: "L2", readBack: nil),
      "probe gone after a relaunch: discarded, still waiting")

// MARK: - One playlist across devices

do {
    let n = PlaylistIdentity.normalizedURL
    eq(n("HTTPS://Server.Example.com:443/", false), "https://server.example.com", "default https port, case, and trailing slash dropped")
    eq(n("server.example.com:80", false), "http://server.example.com", "no scheme: http, default port dropped")
    eq(n("http://server.example.com:9191//", false), "http://server.example.com:9191", "a real port stays")
    eq(n("http://h/list.m3u?a=1", true), "http://h/list.m3u?a=1", "M3U keeps its query")
    check(n("  ", false) == nil, "blank: nil")
    let fp = PlaylistIdentity.keyFingerprint("abc")
    eq(fp.count, 16, "fingerprint: 8 bytes hex")
    check(fp != "abc" && !fp.contains("abc"), "fingerprint never carries the key")
    eq(PlaylistIdentity.keyFingerprint(" abc "), fp, "fingerprint ignores surrounding space")
    eq(PlaylistIdentity.keyFingerprint(""), "", "blank key: no fingerprint")

    typealias R = PlaylistIdentity.Row
    let a = R(id: "B-ID", type: "dispatcharr", url: "https://d.example.com/", username: "", apiKeyFP: fp, changedAt: 0)
    let b = R(id: "a-id", type: "dispatcharr", url: "https://D.example.com", username: "", apiKeyFP: fp, changedAt: 0)
    check(PlaylistIdentity.sameAccount(a, b), "same server and key: one playlist")
    let c = R(id: "c", type: "dispatcharr", url: "https://d.example.com", username: "Logan", apiKeyFP: "")
    let d = R(id: "d", type: "dispatcharr", url: "https://d.example.com", username: "logan", apiKeyFP: "x")
    check(PlaylistIdentity.sameAccount(c, d), "same Dispatcharr username (any case): one playlist")
    let e = R(id: "e", type: "dispatcharr", url: "https://d.example.com", username: "kid", apiKeyFP: fp)
    check(!PlaylistIdentity.sameAccount(a.withUser("logan"), e), "different users on one server: two playlists")
    check(!PlaylistIdentity.sameAccount(a, R(id: "f", type: "dispatcharr", url: "https://other.example.com", apiKeyFP: fp)),
          "different server: two playlists")
    check(!PlaylistIdentity.sameAccount(a, R(id: "g", type: "xtream", url: "https://d.example.com", username: "u")), "different type")
    check(PlaylistIdentity.sameAccount(R(id: "x1", type: "xtream", url: "http://xc", username: "u"),
                                       R(id: "x2", type: "xtream", url: "http://xc/", username: "u")), "XC: same username")
    check(!PlaylistIdentity.sameAccount(R(id: "m1", type: "m3u", url: "http://h/a.m3u?u=1"),
                                        R(id: "m2", type: "m3u", url: "http://h/a.m3u?u=2")), "M3U: different query, two playlists")

    // Winner: newest change time, then the smaller lowercase id; every device agrees.
    eq(PlaylistIdentity.losers([a, b]), ["B-ID": "a-id"], "tie: the smaller lowercase id wins")
    eq(PlaylistIdentity.losers([b, a]), ["B-ID": "a-id"], "order of rows does not matter")
    var newer = a; newer.changedAt = 500
    eq(PlaylistIdentity.losers([newer, b]), ["a-id": "B-ID"], "newest change time wins")
    eq(PlaylistIdentity.losers([a, R(id: "z", type: "m3u", url: "http://h/x")]), [:], "no duplicates: nothing to do")
    // Equal change times: the older creation time (the original) wins, before the id rule.
    var original = a; original.createdAt = 1_000
    var copy = b; copy.createdAt = 9_000
    eq(PlaylistIdentity.losers([original, copy]), ["a-id": "B-ID"], "equal change times: the older playlist wins over a later copy")
    var unknownCreated = b; unknownCreated.createdAt = 0
    eq(PlaylistIdentity.losers([original, unknownCreated]), ["B-ID": "a-id"], "creation time unknown on one side: the id rule")
    eq(PlaylistIdentity.losers([R(id: "ABC", type: "m3u", url: "http://h/x"), R(id: "abd", type: "m3u", url: "http://h/x")]),
       ["abd": "ABC"], "ids compare case-insensitively")
    check(!PlaylistIdentity.sameAccount(R(id: "x1", type: "xtream", url: "http://xc", username: "User"),
                                        R(id: "x2", type: "xtream", url: "http://xc", username: "user")), "XC usernames are case-sensitive")
    let three = PlaylistIdentity.losers([a, b, R(id: "0", type: "dispatcharr", url: "https://d.example.com", apiKeyFP: fp)])
    eq(three, ["B-ID": "0", "a-id": "0"], "three copies collapse into one")

    // Data-move plan.
    typealias F = PlaylistMergePlan.Facts
    let p1 = PlaylistMergePlan.plan(loser: F(active: true, apiKey: "good", catchupOffset: 30, recordingDestination: "server"),
                                    winner: F(active: false, apiKey: "", catchupOffset: nil, recordingDestination: "local"),
                                    defaultDestination: "local")
    eq(p1, .init(makeWinnerActive: true, copyApiKey: true, copyPassword: false, copyCatchupOffset: true, copyRecordingDestination: true),
       "loser active with a working key: the winner becomes active and keeps the working key")
    let p2 = PlaylistMergePlan.plan(loser: F(apiKey: "bad", apiKeyRejected: true), winner: F(apiKey: "good"), defaultDestination: "local")
    check(!p2.copyApiKey, "a rejected key never replaces the winner's")
    let p3 = PlaylistMergePlan.plan(loser: F(apiKey: "good"), winner: F(apiKey: "old", apiKeyRejected: true), defaultDestination: "local")
    check(p3.copyApiKey, "a working key replaces the winner's rejected one")
    let p4 = PlaylistMergePlan.plan(loser: F(apiKey: "", password: ""), winner: F(apiKey: "k", password: "p"), defaultDestination: "local")
    check(!p4.copyApiKey && !p4.copyPassword, "empty values never blank the winner's")
    let p5 = PlaylistMergePlan.plan(loser: F(active: true, apiKey: "inuse"), winner: F(active: false, apiKey: "other"), defaultDestination: "local")
    check(p5.copyApiKey, "two working keys: the one this device is using is kept")
    let p6 = PlaylistMergePlan.plan(loser: F(apiKey: "newer", apiKeyChangedAt: 900), winner: F(apiKey: "older", apiKeyChangedAt: 100),
                                    defaultDestination: "local")
    check(p6.copyApiKey, "two working keys, neither in use: the newer is kept")
    let p7 = PlaylistMergePlan.plan(loser: F(apiKey: "older", apiKeyChangedAt: 100), winner: F(apiKey: "newer", apiKeyChangedAt: 900),
                                    defaultDestination: "local")
    check(!p7.copyApiKey, "the winner's newer key stays")
    let r = PlaylistMergePlan.rows(loser: ["m1": 100, "m2": 500, "m3": 50], winner: ["m2": 400, "m3": 50, "m9": 1])
    eq(r.move, ["m1"], "rows only the loser has move")
    eq(r.loserNewer, ["m2"], "the newer copy wins a shared row")
    eq(r.winnerKeeps, ["m3"], "a tie keeps the winner's row")
}

// MARK: - Credentials

func adopt(_ remote: String, _ rs: TimeInterval, _ local: String, _ ls: TimeInterval,
           legacyNewer: Bool = true, replace: Bool = false, rejected: Bool = false,
           localRejected: Bool = false) -> Bool {
    CredentialSyncRule.adoptRemote(remote: remote, remoteStamp: rs, local: local, localStamp: ls,
                                   legacyRemoteNewer: legacyNewer, replace: replace, rejected: rejected,
                                   localRejected: localRejected)
}
check(!adopt("", 900, "old", 100), "an empty credential is never written")
check(!adopt("bad", 900, "old", 100, rejected: true), "a key held as rejected is never adopted")
check(!adopt("same", 900, "same", 100), "equal value: no write")
check(adopt("new", 0, "", 0, legacyNewer: false), "fills in a missing credential")
check(!adopt("old", 100, "new", 900), "an older credential never overwrites a newer one")
check(!adopt("old", 100, "new", 900, replace: true), "not even on a Replace")
check(adopt("new", 900, "old", 100, legacyNewer: false), "a newer credential wins even when the playlist record is older")
check(!adopt("old", 0, "new", 900), "unstamped (older client) credential never overwrites a stamped one")
check(adopt("new", 900, "old", 0, legacyNewer: false), "stamped credential replaces an unstamped one")
check(adopt("new", 0, "old", 0, legacyNewer: true), "neither stamped: shipped rule, newer playlist record")
check(!adopt("new", 0, "old", 0, legacyNewer: false), "neither stamped: older playlist record keeps local")
check(adopt("new", 0, "old", 0, legacyNewer: false, replace: true), "neither stamped: Replace adopts")
check(adopt("cloud", 0, "dead", 0, legacyNewer: false, localRejected: true), "a rejected local key yields to iCloud's (neither stamped)")
check(adopt("cloud", 100, "dead", 900, localRejected: true), "a rejected local key yields even when its change time is newer")
check(!adopt("cloud", 0, "dead", 0, rejected: true, localRejected: true), "both rejected: nothing written")
check(!adopt("", 900, "dead", 0, localRejected: true), "a rejected local key never yields to an empty one")

// MARK: - One active playlist (owner 2026-11-12)
do {
    func e(_ id: String, _ name: String, _ t: Double, active: Bool = false) -> ActivePlaylistRule.Entry {
        ActivePlaylistRule.Entry(id: id, name: name, createdAt: Date(timeIntervalSince1970: t), isActive: active)
    }
    let list = [e("C", "dispatcharr.molinete.app", 30), e("A", "Test1 Playlist", 10), e("B", "Backup 10", 20), e("D", "Backup 9", 40)]
    eq(ActivePlaylistRule.heal(list), "D", "none active: the first in the Settings list (numbers by value: Backup 9 before Backup 10)")
    eq(ActivePlaylistRule.heal([e("C", "dispatcharr.molinete.app", 30)]), "C", "the only remaining playlist becomes active (the iPhone 21:49 case)")
    eq(ActivePlaylistRule.heal(list + [e("E", "Zed", 1, active: true)]), nil, "one already active: nothing changes")
    eq(ActivePlaylistRule.heal([]), nil, "no playlists: nothing to activate")
    eq(ActivePlaylistRule.heal([e("Y", "Home", 20), e("X", "Home", 10)]), "X", "same name: the older one")
    eq(ActivePlaylistRule.heal([e("b", "Home", 10), e("a", "Home", 10)]), "a", "same name and age: by id")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
