//  DsyncManagerRules.swift
//  Aerio
//
//  Dispatcharr Sync, pure: the decisions the Android
//  core/sync/dsync/DispatcharrSyncManager.kt makes inline, pulled out so
//  Scripts/dsync-tests/run.sh can test them. The manager
//  (DispatcharrSyncManager.swift) calls these and does the I/O.
//    - timing constants (section 7 cadence, the Android companion object)
//    - the pulled-category decision (processCategory branch order)
//    - the bucket GET skip (shouldSkipBucketGet)
//    - the "status=unchanged" comparison (writeLocked)
//    - the local-change debounce gate (onLocalChange, schedule)
//    - the converge skip reasons (maybeConverge)
//    - the favorites apply plan (DsyncFavorites.kt) and the recents stamps
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

enum DsyncTiming {
    static let DEBOUNCE_MS: Int64 = 5_000
    static let FOREGROUND_PULL_MS: Int64 = 5 * 60 * 1000
    static let PERIODIC_PULL_MS: Int64 = 15 * 60 * 1000
    /// How often a session with keys deferred for an id cache checks the cache.
    static let CACHE_POLL_MS: Int64 = 5_000
    /// Profiles-lane push debounce.
    static let PEEK_PUSH_DEBOUNCE_MS: Int64 = 1_000
    static let SUPPRESS_MS: Int64 = 3_000
    static let BACKOFF_MS: [Int64] = [30_000, 120_000, 600_000]
    static let RECONNECT_MS: [Int64] = [2_000, 5_000, 15_000, 60_000]
    static let CHOICE_HOLD_MS: Int64 = 120_000
    /// Skip a bucket GET pulled moments ago with the same listed size.
    static let BUCKET_REFETCH_MIN_MS: Int64 = 60_000
    static let PROGRESS_LOCAL_WAIT_MS: Int64 = 45_000
    static let FIRST_PULL_WAIT_MS: Int64 = 20_000
    /// SetupSourceCoordinator: the Dispatcharr choice waits this long for the first pull.
    static let CHOICE_FIRST_PULL_WAIT_MS: Int64 = 120_000

    /// Retry delay after a failed send number [attempt] (0 based), or nil once the backoff is spent.
    static func backoff(_ attempt: Int) -> Int64? { attempt >= 0 && attempt < BACKOFF_MS.count ? BACKOFF_MS[attempt] : nil }

    /// Reconnect pull delay for try [i] (0 based): 2 s, 5 s, 15 s, then every 60 s.
    static func reconnect(_ i: Int) -> Int64 { RECONNECT_MS[min(max(i, 0), RECONNECT_MS.count - 1)] }
}

/// What one pulled category does (Android processCategory, same branch order).
enum DsyncPullAction: Equatable, Sendable {
    /// Rule 4: the user chose the cloud copy; the server copy is consumed, not applied, and local goes up.
    case forcedSkip
    /// Rule 2: first read of an empty server copy; local seeds the server.
    case seedFromLocal
    /// A newer server value against an unsent row-category change: row union, then apply.
    case merge
    /// Setup choice pull: apply even though the stamp is not newer.
    case choiceApply
    /// A newer whole value, but the local change is newer still.
    case keepLocal
    /// A newer server value: apply it.
    case apply
    /// Already consumed: keep the raw copy, retry held rows, self-heal.
    case notNewer
}

enum DsyncPullRules {
    /// The record vanished after this device already read it once (fpdone): never re-upload on
    /// our own. The owner decides (Upload Again or Turn Off). A first read of an absent record
    /// still seeds from local as before.
    static func recordMissingAfterFirstRead(hadFirstRead: Bool, anyBucketListed: Bool) -> Bool {
        hadFirstRead && !anyBucketListed
    }

    static func decide(_ key: DsyncKey, forced: Bool, consumedBefore: Bool, data: DsyncObject,
                       localAt: Int64, localDevice: String, remoteAt: Int64, remoteDevice: String,
                       dirty: Bool, dirtyAt: Int64, forceApply: Bool) -> DsyncPullAction {
        if forced { return .forcedSkip }
        if DsyncCoexistence.seedFromLocal(key, consumedBefore: consumedBefore, data: data) { return .seedFromLocal }
        let wins = DsyncEnvelopeCodec.remoteWins(localAt: localAt, localDevice: localDevice,
                                                 remoteAt: remoteAt, remoteDevice: remoteDevice)
        let decision: DsyncGate.DirtyPull = key == .profiles
            ? .merge : DsyncGate.onNewerPull(key, dirty: dirty, dirtyAt: dirtyAt, remoteAt: remoteAt)
        if key == .profiles || (wins && decision == .merge) { return .merge }
        if DsyncCoexistence.choiceApplies(remoteWins: wins, forceApply: forceApply, key: key, dirty: dirty) { return .choiceApply }
        if wins && decision == .keepLocal { return .keepLocal }
        if wins { return .apply }
        return .notNewer
    }

    /// Bucket GET skip: no HEAD or ETag on App Data, so the list `bytes` is the
    /// only change signal; the same size within a minute of the last pull skips.
    static func shouldSkipBucketGet(lastPullAt: Int64, now: Int64, fetchedBytes: Int64?, listedBytes: Int64?) -> Bool {
        guard lastPullAt > 0, let f = fetchedBytes, let l = listedBytes else { return false }
        let age = now - lastPullAt
        return age >= 0 && age < DsyncTiming.BUCKET_REFETCH_MIN_MS && f == l
    }

    /// Dirty keys resent after these pull reasons are logged as "retry after offline".
    static func resendReason(_ reason: String) -> Bool { reason == "reconnect" || reason == "launch" || reason == "profile" }

    /// refreshBeforePut: the server copy is the one this device last consumed (no merge, no take).
    static func sameAsConsumed(remoteAt: Int64, remoteDevice: String, remoteData: DsyncObject,
                               localAt: Int64, localDevice: String, localData: DsyncObject?) -> Bool {
        remoteAt == localAt && remoteDevice == localDevice && localData == remoteData
    }
}

enum DsyncPushRules {
    /// No PUT when the server already holds exactly this copy. [serverData] is
    /// the copy refreshBeforePut just fetched; [lastData] the copy this device
    /// last saved (used only when the fetch had no copy of the category).
    /// Compact text equality, as Android compares `data.toString()`.
    static func unchanged(built: DsyncObject, serverData: DsyncObject?, lastData: DsyncObject?, present: Bool) -> Bool {
        guard present, let held = serverData ?? lastData else { return false }
        return DsyncJSONEncoder.encode(built) == DsyncJSONEncoder.encode(held)
    }

    /// The "status=unchanged" line is logged for a forced key and for a dirty shared key.
    static func logsUnchanged(force: Bool, dirty: Bool, key: DsyncKey) -> Bool {
        force || (dirty && DsyncCoexistence.FORCE_KEYS.contains(key))
    }

    /// Debounce for a local change: the profiles lane goes out fast.
    static func debounceMs(_ key: DsyncKey) -> Int64 {
        key == .profiles ? DsyncTiming.PEEK_PUSH_DEBOUNCE_MS : DsyncTiming.DEBOUNCE_MS
    }

    /// onLocalChange gate: only the live session, never inside the window
    /// right after a pull applied this key (the apply's own echo).
    static func acceptLocalChange(sessionLive: Bool, suppressUntilMs: Int64?, nowMs: Int64) -> Bool {
        sessionLive && (suppressUntilMs ?? 0) <= nowMs
    }

    /// Converge skip reason for one shared key, or nil when it is compared.
    static func convergeSkip(forced: Bool, awaiting: Bool, pending: Bool, read: Bool, dirty: Bool, partial: Bool) -> String? {
        if forced { return "armed" }
        if awaiting { return "deferred" }
        if pending { return "dirty" }
        if !read { return "unread" }
        if dirty && !partial { return "dirty" }
        return nil
    }

    /// maybeConverge gate: base user, no setup hold, nothing armed, not already running, no prompt pending.
    static func convergeAllowed(isBase: Bool, choiceHeld: Bool, running: Bool, anyForced: Bool, choicePending: Bool) -> Bool {
        isBase && !choiceHeld && !running && !anyForced && !choicePending
    }
}

/// DsyncFavorites.kt: the server's integer ids onto this device's channel list.
enum DsyncFavoritesRules {
    struct Plan: Equatable, Sendable {
        /// Local channel ids the server ids map to, in server order.
        let wanted: [String]
        /// Local favorites the server list dropped (only channels this list maps).
        let deletes: [String]
        /// The resulting ordered favorites: wanted first, then kept unmapped locals in their order.
        let order: [String]
    }

    /// A local favorite whose channel is not in the list ([toInt] has no entry)
    /// is kept: this device cannot tell whether the server meant to drop it.
    static func plan(ids: [Int], toLocal: [Int: String], toInt: [String: Int], local: [String]) -> Plan {
        let wanted = ids.compactMap { toLocal[$0] }.distinctOrdered()
        let wantedSet = Set(wanted)
        let deletes = local.filter { toInt[$0] != nil && !wantedSet.contains($0) }
        let kept = local.filter { toInt[$0] == nil && !wantedSet.contains($0) }
        return Plan(wanted: wanted, deletes: deletes, order: (wanted + kept).distinctOrdered())
    }

    static func logLine(_ dir: String, ids: Int, mapped: Int, written: Int, scope: String, playlistId: String) -> String {
        "[DSYNC] favorites \(dir): \(ids) ids, \(mapped) mapped, \(written) written, "
            + "scope=\(scope.isEmpty ? "default" : String(scope.prefix(8))), playlist=\(playlistId.prefix(8))"
    }
}

/// Recently Watched stamps (Android stampRecents and the recents apply).
enum DsyncRecentsRules {
    /// The head moved or is new: it was just watched; every other id keeps its
    /// stamp or gets `now - index`. Stamps for ids no longer listed drop.
    static func stamp(ids: [String], previousHead: String?, stamps: [String: Int64], now: Int64) -> (stamps: [String: Int64], head: String?) {
        guard let head = ids.first else { return (stamps, previousHead) }
        var s = stamps
        if previousHead != head || s[head] == nil { s[head] = now }
        for (i, id) in ids.enumerated() where s[id] == nil { s[id] = now - Int64(i) }
        let keep = Set(ids)
        return (s.filter { keep.contains($0.key) }, head)
    }

    /// Local rows with Dispatcharr ids, stamped (ids this list cannot map are left out).
    static func localRows(ids: [String], toInt: [String: Int], stamps: [String: Int64], now: Int64) -> [RecentRow] {
        ids.enumerated().compactMap { i, id in
            toInt[id].map { RecentRow(channelId: $0, watchedAt: stamps[id] ?? (now - Int64(i))) }
        }
    }

    /// Apply: merged rows mapped back, then the local ids this list cannot map, in their order.
    static func applied(local: [RecentRow], remote: [RecentRow], ids: [String], toInt: [String: Int],
                        toLocal: [Int: String]) -> (ids: [String], stamps: [(String, Int64)]) {
        let merged = DsyncMerge.recents(local, remote).compactMap { r in toLocal[r.channelId].map { ($0, r.watchedAt) } }
        let others = ids.filter { toInt[$0] == nil }
        return (merged.map(\.0) + others, merged)
    }
}

/// Reminders apply plan (Android applyReminders): wanted rows by (channel, start),
/// expired rows dropped, unresolvable local rows never removed.
enum DsyncRemindersRules {
    struct LocalRow: Equatable, Sendable {
        let key: String
        let channelName: String
        let startS: Int64
    }

    struct Plan: Equatable, Sendable {
        let removeKeys: [String]
        let add: [ReminderRow]
    }

    static func plan(rows: [ReminderRow], nowMs: Int64, local: [LocalRow], intByName: [String: Int], toLocal: [Int: String]) -> Plan {
        var wanted = DsyncOrderedMap<String, ReminderRow>()
        for r in rows where r.end * 1000 >= nowMs {
            let k = "\(r.channelId)|\(r.start)"
            if wanted[k] == nil { wanted[k] = r }
        }
        var have = Set<String>()
        var remove: [String] = []
        for l in local {
            guard let cid = intByName[l.channelName] else { continue }
            let id = "\(cid)|\(l.startS)"
            if wanted[id] != nil { have.insert(id) } else { remove.append(l.key) }
        }
        let add = wanted.entries.filter { !have.contains($0.0) && toLocal[$0.1.channelId] != nil }.map(\.1)
        return Plan(removeKeys: remove, add: add)
    }
}

/// Profile-list sync while a profile of the playlist is held after a server
/// address change (ProfileHostHold; follow-up B13, 2026-11-11). The `profiles`
/// category pauses in both directions until nothing on the playlist is held:
/// the local roster (names, roles, avatars, PIN hashes) never goes to the new
/// server, and that server's rows and tombstones never apply here (a
/// tombstone could delete a held profile). Every other category syncs as usual.
enum DsyncRosterPause {
    /// Pull: pulled `profiles` rows and tombstones apply, and are offered as suggestions, only when not paused.
    static func appliesPulledProfiles(paused: Bool) -> Bool { !paused }

    /// Push: the `profiles` category itself is not written while paused (the change stays pending).
    static func writes(_ key: DsyncKey, paused: Bool) -> Bool { !(paused && key == .profiles) }

    /// A successful PUT clears the roster's pending (dirty) mark only when it
    /// wrote `profiles` outside a pause; edits made while paused go out with
    /// the first PUT after it ends.
    static func clearsRosterPending(afterPutOf key: DsyncKey, paused: Bool) -> Bool { key == .profiles && !paused }

    /// The bucket a PUT of another category starts from. While paused,
    /// `profiles` goes out exactly as the server has it: [previous] is the
    /// copy this PUT's refresh just read when [serverHasBucket]; otherwise
    /// [previous] is an older local copy, and `profiles` is left out.
    static func base(_ previous: DsyncObject?, serverHasBucket: Bool, paused: Bool) -> DsyncObject? {
        guard paused, !serverHasBucket, var out = previous,
              var cats = out[DsyncV2.CATEGORIES]?.asObject, cats[DsyncKey.profiles.suffix] != nil else { return previous }
        cats[DsyncKey.profiles.suffix] = nil
        out[DsyncV2.CATEGORIES] = .object(cats)
        return out
    }
}
