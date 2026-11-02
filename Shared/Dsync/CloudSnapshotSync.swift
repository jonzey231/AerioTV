//  CloudSnapshotSync.swift
//  Aerio
//
//  The iCloud side of Dispatcharr Sync coexistence (docs/DispatcharrSyncSchema.md
//  section 10a, Rules 1, 4, and 5), the Apple counterpart of the Drive parts of
//  the Android core/sync/DriveSyncManager.kt, DriveIdLookup.kt, and
//  DriveSyncWorker.kt. The shared categories ride five iCloud key-value
//  entries, one snapshot per Android Drive file (CloudSnapshots), next to the
//  older iCloud keys (syncedPreferences, syncedWatchProgress, syncedReminders)
//  that SyncManager keeps writing and merging for older AerioTV builds.
//
//  Every snapshot write carries envelope.format 2 and the canonical
//  Dispatcharr ids (on Apple the local ids of a Dispatcharr Direct Connect
//  playlist already are those ids). A shared category whose iCloud copy is
//  only in the older keys, or whose snapshot has format null or below 2, is
//  an old-format backup: AerioTV offers the backup update (the prompt is
//  part 4; `backupUpdateOffer` is the state it observes).
//
//  Logs use [CLOUD] where Android says [DRIVE]; counts only, never ids,
//  keys, tokens, or URLs.

import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class CloudSnapshotSync: ObservableObject {
    static let shared = CloudSnapshotSync()

    /// The base user key (active playlist id) when the backup is old format and the update was
    /// not accepted yet: the part 4 "Update backup" offer observes this. Nil: nothing to offer.
    @Published private(set) var backupUpdateOffer: String?

    private let kvs = NSUbiquitousKeyValueStore.default
    private let state = DsyncStateStore.shared
    private var dsync: DispatcharrSyncManager { DispatcharrSyncManager.shared }
    private var started = false
    private var catalogRetry: Task<Void, Never>?

    private init() {}

    // MARK: - Keys and gates

    /// The iCloud key of one shared snapshot (the Android Drive file name, prefixed).
    static func kvsKey(_ c: DsyncCategory) -> String {
        switch c {
        case .favorites: return "snapshot.favorites.v1.json"
        case .watchProgress: return "snapshot.watch_progress.v1.json"
        case .reminders: return "snapshot.reminders.v1.json"
        case .watchlist: return "snapshot.watchlist.v1.json"
        case .preferences: return "snapshot.preferences.v1.json"
        case .playlists: return "snapshot.playlists.v1.json"
        case .credentials: return "snapshot.credentials.v1.json"
        }
    }

    /// The older iCloud keys a shared file's rows lived in before snapshots.
    private static let legacyPrefs = "syncedPreferences"
    private static let legacyProgress = "syncedWatchProgress"
    private static let legacyReminders = "syncedReminders"

    var cloudOn: Bool { SyncManager.shared.isSyncEnabled }

    /// The Apple Sync category that gates a shared file (favorites, watchlist, and the settings ride App Preferences).
    func fileEnabled(_ c: DsyncCategory) -> Bool {
        switch c {
        case .watchProgress: return SyncCategory.watchProgress.isEnabled
        case .reminders: return SyncCategory.reminders.isEnabled
        case .favorites, .watchlist, .preferences: return SyncCategory.preferences.isEnabled
        case .playlists, .credentials: return false
        }
    }

    private var device: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    // MARK: - Storage

    func readSnapshot(_ c: DsyncCategory) -> String? { kvs.string(forKey: Self.kvsKey(c)) }

    /// Writes on the literal main dispatch queue, as every KVS write in SyncManager does.
    private func writeSnapshot(_ c: DsyncCategory, _ text: String) {
        let key = Self.kvsKey(c)
        DispatchQueue.main.async { NSUbiquitousKeyValueStore.default.set(text, forKey: key) }
    }

    /// The older payload of a shared file is present in iCloud (no snapshot written yet).
    private func legacyPresent(_ c: DsyncCategory) -> Bool {
        switch c {
        case .watchProgress: return kvs.array(forKey: Self.legacyProgress) != nil
        case .reminders: return kvs.array(forKey: Self.legacyReminders) != nil
        case .favorites, .watchlist, .preferences: return kvs.dictionary(forKey: Self.legacyPrefs) != nil
        case .playlists, .credentials: return false
        }
    }

    // MARK: - Id lookup (Android DriveIdLookup)

    /// The active Dispatcharr playlist id, its watchlist scope, and the id maps.
    /// Channels: the loaded channel list (empty while it loads). VOD: on Apple the local id of a
    /// Dispatcharr row is the Dispatcharr id, so the maps are Int(localId) for in-scope ids.
    private struct Lookup {
        let pid: String?
        let ids: CloudCanon.Ids
    }

    private func lookup(movieIds: [String] = [], episodeIds: [String] = []) -> Lookup {
        guard let row = DsyncLocal.activeDispatcharrPlaylist() else { return Lookup(pid: nil, ids: .init()) }
        let pid = row.id.uuidString
        var movies: [String: Int] = [:]
        for m in movieIds { if let i = Int(m) { movies[m] = i } }
        var episodes: [String: Int] = [:]
        for e in episodeIds { if let i = Int(e) { episodes[e] = i } }
        return Lookup(pid: pid, ids: .init(channels: DsyncLocal.channelMap(pid).toInt, movies: movies, episodes: episodes))
    }

    /// The base user key for the offer and update flags: the active playlist id, any type.
    private var activeKey: String { ChannelStore.shared.activeServer?.id.uuidString ?? "none" }

    // MARK: - Snapshot builders (one per shared file, used by every write path)

    private func envelope() -> CloudEnvelope {
        CloudCanon.writerEnvelope(nowMs: Self.nowMs(), device: device, providers: providersForPush())
    }

    /// The providers record every file of a push carries (section 10b): this device sets
    /// icloud and dispatcharr, googleDrive is preserved. Apple has no profiles: always the base user.
    func providersForPush() -> SyncProvidersRecord? {
        SyncProvidersStore.forPush(SyncProvidersStore.ICLOUD, dispatcharrOn: dsync.isEnabled && DsyncLocal.activeDispatcharrPlaylist() != nil,
                                   icloudOn: cloudOn, deviceId: dsync.deviceId)
    }

    /// Pull fold: the newest record any iCloud snapshot carries.
    func foldProviders() {
        for c in CloudCanon.SHARED_FILES {
            if let t = readSnapshot(c) { SyncProvidersStore.fold(SyncProvidersStore.ICLOUD, SyncProvidersRules.fromBody(t)) }
        }
    }

    /// "Keep your devices in sync" (part 4 shows it): providers the owner's records mark on that are off here.
    func providerOffers() -> [String] {
        let active = DsyncLocal.activeDispatcharrPlaylist()
        let dsyncRec = active.flatMap { SyncProvidersStore.record(SyncProvidersStore.dsyncScope($0.id.uuidString)) }
        let rec = SyncProvidersRules.newer(SyncProvidersStore.record(SyncProvidersStore.ICLOUD), dsyncRec)
        return SyncProvidersRules.offers(rec, icloudOnHere: cloudOn, dispatcharrOnHere: dsync.isEnabled, activeIsDispatcharr: active != nil)
    }

    /// A source of the preference-lane values: this device's UserDefaults, or an older iCloud payload.
    private struct PrefSource {
        let get: (String) -> Any?
        let isCloud: Bool
        var allKeys: [String] = []
    }

    private static let localPrefs = PrefSource(get: { UserDefaults.standard.object(forKey: $0) }, isCloud: false)

    private func favoritesFrom(_ src: PrefSource) -> [String] {
        let members = src.get("favoriteChannelIDs") as? [String] ?? []
        let set = Set(members)
        let ordered = (src.get(FavoritesStore.orderKey) as? [String] ?? []).filter { set.contains($0) }.distinctOrdered()
        let placed = Set(ordered)
        return ordered + members.filter { !placed.contains($0) }.sorted()
    }

    func buildFavorites() -> CloudFavorites { favoritesSnapshot(favoritesFrom(Self.localPrefs)) }

    private func favoritesSnapshot(_ ids: [String]) -> CloudFavorites {
        var names: [String: String] = [:]
        for c in ChannelStore.shared.channels where names[c.id] == nil { names[c.id] = c.name }
        let entries = ids.enumerated().map {
            CloudFavoriteEntry(channelId: $0.element, channelName: names[$0.element] ?? "", displayOrder: Int64($0.offset), addedAt: 0)
        }
        let s = CloudFavorites(envelope: envelope(), entries: entries)
        guard lookup().pid != nil else { return s }
        return CloudCanon.enrichFavorites(s, lookup().ids).0
    }

    private func progressEntry(_ p: WatchProgress) -> CloudProgressEntry {
        CloudProgressEntry(videoId: p.vodID, title: p.title, posterUrl: p.posterURL, positionMs: Int64(p.positionMs),
                           durationMs: Int64(p.durationMs), updatedAt: Int64(p.updatedAt.timeIntervalSince1970 * 1000),
                           vodType: p.vodType, seriesId: p.seriesID, seasonNumber: p.seasonNumber, episodeNumber: p.episodeNumber,
                           isFinished: p.isFinished, serverId: p.serverID)
    }

    /// Canonical ids for the rows of the active Dispatcharr playlist (or unscoped rows).
    private func enrichProgress(_ s: CloudProgress) -> CloudProgress {
        let l0 = lookup()
        guard let pid = l0.pid else { return s }
        let scoped = CloudCanon.progressCandidates(s).filter { ($0.serverId == nil || $0.serverId == pid) && !DsyncHeld.isPlaceholder($0.videoId) }
        let l = lookup(movieIds: scoped.filter { $0.vodType == "movie" }.map(\.videoId),
                       episodeIds: scoped.filter { $0.vodType == "episode" }.map(\.videoId))
        var out = s
        out.entries = s.entries.map { e in
            guard e.serverId == nil || e.serverId == pid else { return e }
            return CloudCanon.enrichProgress(CloudProgress(envelope: s.envelope, entries: [e]), l.ids).0.entries[0]
        }
        return out
    }

    /// THE iCloud WatchProgress snapshot (section 10a, single builder): every push entry point
    /// (replace, converge, follow, the accepted update) and the converge mark check build it here,
    /// so held placeholder rows and the Dispatcharr rows this device last read ride with the local rows.
    func buildProgress(_ why: String?) -> CloudProgress {
        let rows = (try? WatchProgressManager.modelContext?.fetch(FetchDescriptor<WatchProgress>())) ?? []
        // URL-keyed rows never leave the device (hosts, file paths).
        let local = CloudProgress(envelope: envelope(), entries: rows.filter { !$0.vodID.contains("://") }.map(progressEntry))
        let enriched = enrichProgress(local)
        let (pid, extra) = dsync.cloudProgressRows()
        let active = DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString
        let held = pid != nil && (active == nil || active == pid) ? extra : []
        let out = CloudCanon.progressSnapshot(enriched, extra: held) { t, id in self.dsync.cachedUuid(t, id) }
        if let why {
            let canonical = CloudCanon.progress(out, .init(), nowMs: Self.nowMs()).rows
            let ph = out.entries.filter { DsyncHeld.isPlaceholder($0.videoId) }.count
            debugLog(DsyncHeld.snapshotLine(why, local: local.entries.count, canonical: canonical, extra: held.count, placeholders: ph))
        }
        return out
    }

    func buildReminders() -> CloudReminders {
        let entries = DsyncLocal.reminders().map { e -> CloudReminderEntry in
            let start = Int64(e.info.startTime.timeIntervalSince1970 * 1000)
            // Apple reminders carry no end time: the start stands in (as the Dispatcharr build does).
            return CloudReminderEntry(reminderKey: e.key, channelName: e.info.channelName, programTitle: e.info.programTitle,
                                      startMillis: start, endMillis: start)
        }
        return CloudReminders(envelope: envelope(), entries: entries)
    }

    private func hiddenEntries(_ map: [String: [String: (hidden: Bool, at: Date)]]) -> [CloudHiddenEntry] {
        var out: [CloudHiddenEntry] = []
        for (server, m) in map.sorted(by: { $0.key < $1.key }) {
            for (k, e) in m.sorted(by: { $0.key < $1.key }) {
                let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let at = Int64(e.at.timeIntervalSince1970 * 1000)
                out.append(CloudHiddenEntry(vodId: parts[1], vodType: parts[0] == "series" ? "series" : "movie", serverId: server,
                                            hiddenAt: at, unhiddenAt: e.hidden ? nil : at))
            }
        }
        return out
    }

    private func enrichWatchlist(_ s: CloudWatchlist) -> CloudWatchlist {
        guard let pid = lookup().pid else { return s }
        let movies = (s.entries.filter { $0.vodType != "series" && ($0.serverId == nil || $0.serverId == pid) }.map(\.vodId) +
            s.hidden.filter { $0.vodType != "series" && ($0.serverId == nil || $0.serverId == pid) }.map(\.vodId))
        let l = lookup(movieIds: movies)
        var out = s
        out.entries = s.entries.map { e in
            guard e.serverId == nil || e.serverId == pid else { return e }
            return CloudCanon.enrichWatchlist(CloudWatchlist(envelope: s.envelope, entries: [e]), l.ids).0.entries[0]
        }
        out.hidden = s.hidden.map { e in
            guard e.serverId == nil || e.serverId == pid else { return e }
            return CloudCanon.enrichWatchlist(CloudWatchlist(envelope: s.envelope, entries: [], hidden: [e]), l.ids).0.hidden[0]
        }
        return out
    }

    func buildWatchlist() -> CloudWatchlist {
        let rows = (try? WatchlistManager.modelContext?.fetch(FetchDescriptor<WatchlistEntry>())) ?? []
        let entries = rows.map {
            CloudWatchlistEntry(vodId: $0.vodID, vodType: $0.vodType == "series" ? "series" : "movie", title: $0.title,
                                posterUrl: $0.posterURL, releaseYear: $0.releaseYear, rating: $0.rating, serverId: $0.serverID,
                                addedAt: Int64($0.addedAt.timeIntervalSince1970 * 1000))
        }.sorted { ($0.serverId ?? "", $0.vodId) < ($1.serverId ?? "", $1.vodId) }
        // Hidden Titles off in Sync Categories: send none (readers keep theirs).
        var hidden: [CloudHiddenEntry] = []
        if SyncItemCatalog.isEnabled(SyncItemCatalog.hiddenTitlesID) {
            hidden = hiddenEntries(HiddenVODStore.shared.entries.mapValues { $0.mapValues { ($0.hidden, $0.updatedAt) } })
        }
        return enrichWatchlist(CloudWatchlist(envelope: envelope(), entries: entries, hidden: hidden))
    }

    /// The data keys and settings lanes of a preferences snapshot, from [src].
    private func preferencesFrom(_ src: PrefSource, recents: [String]) -> CloudPreferences {
        var keys: [String: String] = [:]
        keys[CloudCanon.K_RECENTS] = recents.joined(separator: "\n")
        var collections: [ChannelCollection] = []
        if let data = src.get("channelCollections") as? Data { collections = (try? JSONDecoder().decode([ChannelCollection].self, from: data)) ?? [] }
        keys[CloudCanon.K_COLLECTIONS] = CloudCanon.encodeCollections(collections.map {
            .init(id: $0.id, name: $0.name, memberIds: $0.memberIDs, placement: $0.placement.rawValue)
        })
        func groups(_ k: String) -> [String] {
            if let a = src.get(k) as? [String] { return a.sorted() }
            if let d = src.get(k) as? Data { return ((try? JSONDecoder().decode([String].self, from: d)) ?? []).sorted() }
            return []
        }
        keys[CloudCanon.K_HIDDEN_LIVE] = groups(DsyncLocal.hiddenGroupKeys.0).joined(separator: "\n")
        keys[CloudCanon.K_HIDDEN_MOVIES] = groups(DsyncLocal.hiddenGroupKeys.1).joined(separator: "\n")
        keys[CloudCanon.K_HIDDEN_SERIES] = groups(DsyncLocal.hiddenGroupKeys.2).joined(separator: "\n")
        keys[CloudCanon.K_ORDER] = (src.get(DsyncLocal.groupOrderKey) as? [String] ?? []).joined(separator: "\n")
        keys[CloudCanon.K_SORT_MODE] = CloudCanon.groupMode(src.get(DsyncLocal.groupModeKey) as? String)
        var tv: [String: String] = [:]
        var mobile: [String: String] = [:]
        if src.isCloud {
            // Older payload: shared map values are lane v, the device lanes ride their own dicts.
            let tvDict = src.get(SyncScope.tvLaneKey) as? [String: Any] ?? [:]
            let mobileDict = src.get(SyncScope.mobileLaneKey) as? [String: Any] ?? [:]
            let fam = (src.allKeys + Array(tvDict.keys) + Array(mobileDict.keys)).filter {
                $0.hasPrefix(DsyncSettingsValidator.COLOR_PREFIX) || $0.hasPrefix(DsyncSettingsValidator.BUCKET_PREFIX)
            }
            for name in Set(DsyncSettingsMap.ENTRIES.map(\.name) + fam).sorted() {
                guard let e = DsyncSettingsMap.entry(name) else { continue }
                if let v = DsyncSettingsMap.fromApple(e, src.get(e.appleKey)) { keys[name] = v.content }
                if let v = DsyncSettingsMap.fromApple(e, tvDict[e.appleKey]) { tv[name] = v.content }
                if let v = DsyncSettingsMap.fromApple(e, mobileDict[e.appleKey]) { mobile[name] = v.content }
            }
        } else {
            let scopes = DsyncLocal.scopes()
            let lanes = laneValues(DsyncLocal.settingsValues(), scopeOf: { DsyncLocal.scopeForName(scopes, $0) }, isTv: DsyncLocal.isTv)
            for (n, v) in lanes[DsyncScope.LANE_ALL] ?? [:] { keys[n] = v.content }
            for (n, v) in lanes[DsyncScope.LANE_TV] ?? [:] { tv[n] = v.content }
            for (n, v) in lanes[DsyncScope.LANE_MOBILE] ?? [:] { mobile[n] = v.content }
        }
        return CloudPreferences(envelope: envelope(), keys: keys, tv: tv, mobile: mobile)
    }

    private func enrichPreferences(_ s: CloudPreferences) -> CloudPreferences {
        guard lookup().pid != nil else { return s }
        return CloudCanon.enrichPreferences(s, lookup().ids).0
    }

    func buildPreferences() -> CloudPreferences {
        let pid = ChannelStore.shared.activeServer?.id.uuidString
        var p = preferencesFrom(Self.localPrefs, recents: pid.map { DsyncLocal.recents($0) } ?? [])
        // The other device class's lane is not this device's to write: keep the backup's.
        if let cur = readSnapshot(.preferences).flatMap(CloudPreferences.decode(text:)) {
            if DsyncLocal.isTv { p.mobile = cur.mobile } else { p.tv = cur.tv }
        }
        return enrichPreferences(p)
    }

    /// The text a push of [c] uploads now.
    func payload(_ c: DsyncCategory, _ why: String?) -> String? {
        switch c {
        case .favorites: return buildFavorites().text
        case .watchProgress: return buildProgress(why).text
        case .reminders: return buildReminders().text
        case .watchlist: return buildWatchlist().text
        case .preferences: return buildPreferences().text
        case .playlists, .credentials: return nil
        }
    }

    // MARK: - Older iCloud payloads as snapshots (the backup's own rows, for the update)

    private struct LegacyWatchlistRow: Decodable {
        var vodID: String
        var title: String
        var posterURL: String?
        var vodType: String
        var serverID: String?
        var releaseYear: String
        var rating: String
        var addedAt: Date
    }

    private struct LegacyWatchlistBlob: Decodable {
        var rows: [LegacyWatchlistRow]
    }

    private struct LegacyHidden: Decodable {
        var hidden: Bool
        var updatedAt: Date
    }

    /// The older iCloud copy of [c] in the snapshot shape (envelope without format), or nil when absent.
    private func legacySnapshot(_ c: DsyncCategory) -> String? {
        let env = CloudEnvelope(lastModified: Self.nowMs(), device: "", format: nil)
        switch c {
        case .watchProgress:
            guard let arr = kvs.array(forKey: Self.legacyProgress) as? [[String: Any]] else { return nil }
            let entries = arr.compactMap { d -> CloudProgressEntry? in
                guard let id = d["vodID"] as? String, let ts = d["updatedAt"] as? TimeInterval, !id.contains("://") else { return nil }
                return CloudProgressEntry(videoId: id, title: d["title"] as? String ?? "", posterUrl: d["posterURL"] as? String,
                                          positionMs: Int64(d["positionMs"] as? Int ?? 0), durationMs: Int64(d["durationMs"] as? Int ?? 0),
                                          updatedAt: Int64(ts * 1000), vodType: d["vodType"] as? String ?? "movie",
                                          seriesId: d["seriesID"] as? String, isFinished: d["isFinished"] as? Bool ?? false,
                                          serverId: d["serverID"] as? String)
            }
            return CloudProgress(envelope: env, entries: entries).text
        case .reminders:
            guard let arr = kvs.array(forKey: Self.legacyReminders) as? [[String: Any]] else { return nil }
            let entries = arr.compactMap { d -> CloudReminderEntry? in
                guard let k = d["key"] as? String, let s = d["startTime"] as? TimeInterval else { return nil }
                return CloudReminderEntry(reminderKey: k, channelName: d["channelName"] as? String ?? "",
                                          programTitle: d["programTitle"] as? String ?? "", startMillis: Int64(s * 1000), endMillis: Int64(s * 1000))
            }
            return CloudReminders(envelope: env, entries: entries).text
        case .favorites:
            guard let d = kvs.dictionary(forKey: Self.legacyPrefs) else { return nil }
            var s = favoritesSnapshot(favoritesFrom(PrefSource(get: { d[$0] }, isCloud: true)))
            s.envelope = env
            return s.text
        case .watchlist:
            guard let d = kvs.dictionary(forKey: Self.legacyPrefs) else { return nil }
            var entries: [CloudWatchlistEntry] = []
            if let data = d["watchlist.sync.v1"] as? Data, let blob = try? JSONDecoder().decode(LegacyWatchlistBlob.self, from: data) {
                entries = blob.rows.map {
                    CloudWatchlistEntry(vodId: $0.vodID, vodType: $0.vodType == "series" ? "series" : "movie", title: $0.title,
                                        posterUrl: $0.posterURL, releaseYear: $0.releaseYear, rating: $0.rating, serverId: $0.serverID,
                                        addedAt: Int64($0.addedAt.timeIntervalSince1970 * 1000))
                }
            }
            var hidden: [CloudHiddenEntry] = []
            if let data = d[HiddenVODStore.syncKey] as? Data,
               let map = try? JSONDecoder().decode([String: [String: LegacyHidden]].self, from: data) {
                hidden = hiddenEntries(map.mapValues { $0.mapValues { ($0.hidden, $0.updatedAt) } })
            }
            return CloudWatchlist(envelope: env, entries: entries, hidden: hidden).text
        case .preferences:
            guard let d = kvs.dictionary(forKey: Self.legacyPrefs) else { return nil }
            let pid = ChannelStore.shared.activeServer?.id.uuidString ?? ""
            let recents = (d["recentChannels.sync.v1"] as? [String: [String]])?[pid] ?? []
            var p = preferencesFrom(PrefSource(get: { d[$0] }, isCloud: true, allKeys: Array(d.keys)), recents: recents)
            p.envelope = env
            return p.text
        case .playlists, .credentials:
            return nil
        }
    }

    /// The backup's copy of a shared file: the snapshot, else the older payload in snapshot shape.
    func backupBody(_ c: DsyncCategory) -> String? { readSnapshot(c) ?? legacySnapshot(c) }

    // MARK: - Push (one category, committed whole)

    /// Uploads [c] and logs the push line when there is a reason to (label or follows).
    @discardableResult
    func commit(_ c: DsyncCategory, _ text: String, why: String?, follows: [String] = []) -> Bool {
        writeSnapshot(c, text)
        if why != nil || !follows.isEmpty {
            let shared = sharedRows(c, text)
            let rows = shared.count == 1 ? shared[0].1 : snapshotRows(c, text)
            debugLog(CloudCanon.pushLine(CloudCanon.fileName(c), rows: rows, shared: shared, label: why, follows: follows, ok: true))
        }
        return true
    }

    /// Canonical rows per shared category in a payload: the probe's definition, Off items left out.
    func sharedCategories(_ c: DsyncCategory, _ text: String) -> [(String, SetupSourceChoice.Category)] {
        let now = Self.nowMs()
        let scopes = DsyncLocal.scopes()
        var out: [(String, SetupSourceChoice.Category)] = []
        let host = DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString
        switch c {
        case .favorites: if let s = CloudFavorites.decode(text: text) { out.append(("favorites", CloudCanon.favorites(s, .init()))) }
        case .watchProgress: if let s = CloudProgress.decode(text: text) { out.append(("progress", CloudCanon.progress(s, .init(), nowMs: now))) }
        case .reminders: if let s = CloudReminders.decode(text: text) { out.append(("reminders", CloudCanon.reminders(s, nowMs: now))) }
        case .watchlist:
            if let s = CloudWatchlist.decode(text: text) {
                out.append(("watchlist", CloudCanon.watchlist(s, .init(), host: host)))
                out.append(("hiddenTitles", CloudCanon.hiddenTitles(s, .init(), host: host)))
            }
        case .preferences:
            if let s = CloudPreferences.decode(text: text) {
                out.append(("recents", CloudCanon.recentsCategory(s, .init())))
                out.append(("collections", CloudCanon.collectionsCategory(s, .init())))
                out.append(("hiddenGroups", CloudCanon.hiddenGroupsCategory(s)))
                out.append(("groupOrder", CloudCanon.groupOrderCategory(s)))
                out.append(("settings", CloudCanon.settingsOf(s) { SetupSourceChoice.nameOff(scopes, $0) }))
            }
        case .playlists, .credentials: break
        }
        return out.filter { n, _ in SetupSourceChoice.itemId(n).map { !SetupSourceChoice.itemOff(scopes, $0) } ?? true }
    }

    private func sharedRows(_ c: DsyncCategory, _ text: String) -> [(String, Int)] { sharedCategories(c, text).map { ($0.0, $0.1.rows) } }

    private func snapshotRows(_ c: DsyncCategory, _ text: String) -> Int {
        switch c {
        case .favorites: return CloudFavorites.decode(text: text)?.entries.count ?? -1
        case .watchProgress: return CloudProgress.decode(text: text)?.entries.count ?? -1
        case .reminders: return CloudReminders.decode(text: text)?.entries.count ?? -1
        case .watchlist: return CloudWatchlist.decode(text: text).map { $0.entries.count + $0.hidden.count } ?? -1
        case .preferences: return CloudPreferences.decode(text: text).map { $0.keys.count + $0.tv.count + $0.mobile.count } ?? -1
        case .playlists, .credentials: return -1
        }
    }

    // MARK: - Push pipeline (holds, fresh-device order, atomic file commit)

    private var follows = CloudFollowQueue()
    private var followTask: Task<Void, Never>?
    private var pushGeneration = 0

    /// Pushes one file unless a Rule 4 hold applies. True when written or deliberately held.
    @discardableResult
    func pushCategory(_ c: DsyncCategory, _ label: String? = nil) async -> Bool {
        let shared = CloudCanon.SHARED_FILES.contains(c)
        let file = CloudCanon.fileName(c)
        // iCloud backs up the default profile only (Android Drive sync runs under defaultOnly).
        if shared && ProfileManager.shared.nonDefaultActive() {
            debugLog("[CLOUD] push \(file) held: a non-default profile is active")
            return true
        }
        // Rule 4: never push this device's (not yet chosen) shared data over the backup.
        if let why = CloudPushRules.hold(shared: shared, choiceHeld: sharedHeld(), unknown: cloudUnknown(), deferred: replaceDeferred()) {
            debugLog(CloudPushRules.heldLine(file, why))
            return true
        }
        // Fresh-device order (Rule 4, Dispatcharr chosen): the first push of each shared file waits
        // until the Dispatcharr pull applied its categories here, whatever they count.
        let waiting = shared && replaceWaiting(c)
        if waiting {
            if !dsync.isEnabled {
                clearReplaceWait(c)
            } else {
                let st = await dsync.cloudOrderState()
                let scopes = DsyncLocal.scopes()
                let names = SetupSourceChoice.namesInFile(c).filter { n in SetupSourceChoice.itemId(n).map { !SetupSourceChoice.itemOff(scopes, $0) } ?? true }
                if let hold = SetupSourceChoice.freshDeviceHold(names, read: st?.read) {
                    debugLog(CloudPushRules.heldLine(file, "\(hold) (fresh-device order)"))
                    return true
                }
                clearReplaceWait(c)
            }
        }
        guard let text = payload(c, label ?? (waiting ? "replace" : (follows.pending.contains(c) ? "follow" : nil))) else { return false }
        // Atomic file commit: the write, the follow bookkeeping, and the push line run together,
        // with no suspension point in between; turning iCloud off stops only the next file.
        return commit(c, text, why: label ?? (waiting ? "replace" : nil), follows: follows.take(c))
    }

    /// Pushes [files] in order; a newer push or iCloud turned off stops before the next file.
    func pushFiles(_ files: [DsyncCategory], _ label: String? = nil) async {
        pushGeneration += 1
        let gen = pushGeneration
        for c in files {
            if let why = CloudPushRules.stopReason(cloudOn: cloudOn, superseded: gen != pushGeneration) {
                debugLog(CloudPushRules.stoppedLine(CloudCanon.fileName(c), why))
                break
            }
            await pushCategory(c, label)
        }
    }

    /// Rule 5 follow: a local change, or a Dispatcharr pull that applied a shared key, pushes the
    /// file to iCloud within 15 s (debounced, one push for every file waiting).
    func follow(_ c: DsyncCategory, _ why: String) {
        guard cloudOn, CloudCanon.SHARED_FILES.contains(c), fileEnabled(c) else { return }
        follows.note(c, why)
        followTask?.cancel()
        followTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CloudFollowQueue.DELAY_MS) * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.pushFiles(self.follows.pending)
        }
    }

    /// The user chose Dispatcharr: overwrite the iCloud backup with this device's copy of every
    /// shared file now; a file still waiting (fresh-device order) goes out with the next follow.
    func replaceBackupNow() async {
        debugLog("[CLOUD] next push replaces backup (user chose Dispatcharr)")
        guard cloudOn else { return }
        await pushFiles(CloudCanon.SHARED_FILES.filter(fileEnabled), "replace")
    }

    // MARK: - Rule 5 converge (Dispatcharr is the source of truth)

    private func convergeKey(_ pid: String, _ name: String) -> String { "cloud.conv|\(pid)|\(name)" }

    /// After each complete Dispatcharr pull: compare per category and push the differing files to
    /// iCloud. Never prompts, never pulls iCloud. A category pushed once for a given Dispatcharr
    /// state is not pushed again until that state changes (no ping-pong).
    func converge(_ pid: String, _ dsyncSummary: SetupSourceChoice.Summary, _ skipReasons: [String: String]) async {
        let coordinator = SetupSourceCoordinator.shared
        if replaceDeferred() {
            coordinator.retryDeferredReplace()
            return
        }
        if coordinator.setupChoicePending || sharedHeld() { return }
        guard cloudOn, dsync.ownsCategory(.favorites) else { return }
        if cloudUnknown() {
            await coordinator.retryUnknownCloud()
            return
        }
        guard let d = readSharedSummary() else {
            debugLog("[SYNC] converge skipped: iCloud unreadable (unknown, not empty)")
            return
        }
        var marked: [String: String] = [:]
        for n in SetupSourceChoice.SHARED { if let v = state.string(convergeKey(pid, n)) { marked[n] = v } }
        let plan = CloudConverge.plan(cloud: d, dsync: dsyncSummary, skipReasons: skipReasons, marked: marked) { n in
            guard let file = SetupSourceChoice.cloudFile(n), let text = self.payload(file, nil) else { return false }
            guard let now = self.sharedCategories(file, text).first(where: { $0.0 == n })?.1 else { return false }
            return !SetupSourceChoice.categoryEqual(now, d.categories[n])
        }
        for n in plan.cleared { debugLog("[SYNC] converge mark cleared \(n) (local copy changed)") }
        for (n, why) in plan.skipped { debugLog(SetupSourceChoice.convergeSkipLine(n, reason: why, cloud: d.categories[n], dsync: dsyncSummary.categories[n])) }
        if plan.push.isEmpty {
            let n = CloudConverge.known(d, dsyncSummary)
            if plan.skipped.isEmpty { debugLog(SetupSourceChoice.convergeEqualLine(categories: n, skipped: plan.skipped)) }
            else { debugLog("[SYNC] converge nothing pushed categories=\(n) differing=\(plan.skipped.count)") }
            return
        }
        for n in plan.push { debugLog(SetupSourceChoice.convergeLine(n, cloud: d.categories[n], dsync: dsyncSummary.categories[n])) }
        let files = plan.push.compactMap { SetupSourceChoice.cloudFile($0) }.distinctOrdered().filter(fileEnabled)
        var ok: [DsyncCategory: Bool] = [:]
        for c in files {
            // A file still waiting (fresh-device order) is not marked pushed, so the next converge retries it.
            let pushed = await pushCategory(c, "converge")
            ok[c] = pushed && !replaceWaiting(c) && !sharedHeld() && !cloudUnknown() && !replaceDeferred()
        }
        for n in plan.push where ok[SetupSourceChoice.cloudFile(n) ?? .playlists] == true {
            state.set(convergeKey(pid, n), SetupSourceChoice.convergeMark(dsyncSummary.categories[n]))
        }
    }

    // MARK: - Backup update (Rule 4 canonical ids; Android migrateCanonicalIds)

    private func acceptedKey(_ key: String) -> String { "cloud.idmig_ok|\(key)|default" }
    private func doneKey(_ key: String, _ c: DsyncCategory) -> String { "cloud.idmig|\(key)|default|\(c.rawValue)" }

    func idUpdateAccepted(_ key: String) -> Bool { state.bool(acceptedKey(key)) }

    /// Envelope format per shared file present in iCloud (an older payload alone reads as nil).
    private func fileFormats() -> [(String, Int?)] {
        CloudCanon.SHARED_FILES.compactMap { c in
            if let t = readSnapshot(c) { return (CloudCanon.fileName(c), CloudCanon.envelopeFormat(t)) }
            return legacyPresent(c) ? (CloudCanon.fileName(c), nil) : nil
        }
    }

    /// Whether any shared iCloud file is old format. Read only.
    func backupOutdated() -> Bool {
        let formats = fileFormats()
        let old = CloudCanon.oldFormatNames(formats)
        if !old.isEmpty { debugLog("[CLOUD] backup update needed: categories=\(old.joined(separator: ","))") }
        return CloudCanon.backupOutdated(formats.map(\.1))
    }

    /// Offer check: refreshes `backupUpdateOffer` (the key when old format and not accepted).
    @discardableResult
    func refreshUpdateOffer() -> String? {
        let key = activeKey
        let offer: String? = cloudOn && !idUpdateAccepted(key) && backupOutdated() ? key : nil
        if backupUpdateOffer != offer { backupUpdateOffer = offer }
        return offer
    }

    /// The user chose "Update backup": remember it (waiting files finish later) and run now.
    func acceptIdUpdate(_ key: String) {
        state.set(acceptedKey(key), true)
        debugLog("[CLOUD] backup update accepted")
        if backupUpdateOffer != nil { backupUpdateOffer = nil }
        migrateCanonicalIds()
    }

    /// Files still waiting after "Update backup" (none when not accepted).
    func pendingIdUpdate() -> [DsyncCategory] {
        let key = activeKey
        return CloudCanon.pendingCategories(accepted: idUpdateAccepted(key), all: CloudCanon.SHARED_FILES) { self.state.bool(self.doneKey(key, $0)) }
    }

    /// Rewrite each shared iCloud file once at format 2 from the backup's own rows, every file
    /// whatever its row count, Sync Category on or off. Ids fill where they resolve; the channel
    /// categories wait for the channel list, but the format is stamped now so no old file remains.
    func migrateCanonicalIds() {
        guard cloudOn else { return }
        let key = activeKey
        for c in pendingIdUpdate() where migrateCategory(c) { state.set(doneKey(key, c), true) }
    }

    /// True when done for good (written, already current, or no file); false to try again later.
    private func migrateCategory(_ c: DsyncCategory) -> Bool {
        guard let body = backupBody(c) else { return true }
        let wasOld = CloudCanon.isOldFormat(CloudCanon.envelopeFormat(body))
        func stampOnly(_ why: String) -> Bool {
            if wasOld {
                let stamped = CloudCanon.stampFormat(body)
                if let stamped { writeSnapshot(c, stamped) }
                debugLog("[CLOUD] id migration: \(CloudCanon.fileName(c)) format stamped ok=\(stamped != nil) (\(why))")
            }
            return false
        }
        guard let r = migratedPayload(c, body) else { return stampOnly("ids waiting") }
        guard let pair = r else { return stampOnly("decode failed") }
        let (text, filled) = pair
        if !wasOld && filled == 0 { return true }
        writeSnapshot(c, text)
        return true
    }

    /// The rewritten file and rows filled; .none when the id fill has to wait, .some(nil) when it does not decode.
    private func migratedPayload(_ c: DsyncCategory, _ body: String) -> (String, Int)?? {
        let active = lookup().pid != nil
        func v2(_ e: CloudEnvelope) -> CloudEnvelope { var x = e; x.format = CloudCanon.FORMAT; return x }
        switch c {
        case .favorites:
            guard let f = CloudFavorites.decode(text: body) else { return .some(nil) }
            let l = lookup()
            // Channel ids wait for the channel list, as Dispatcharr Sync does.
            if active && l.ids.channels.isEmpty && !f.entries.isEmpty { return nil }
            var (s, n) = CloudCanon.enrichFavorites(f, l.ids)
            if active { debugLog(CloudCanon.migrationLine("favorites", rows: n)) }
            s.envelope = v2(s.envelope)
            return .some((s.text, n))
        case .watchProgress:
            guard let w = CloudProgress.decode(text: body) else { return .some(nil) }
            var (s, n) = (w, 0)
            if active { let e = enrichProgress(w); n = zip(e.entries, w.entries).filter { $0.dispatcharrVodId != $1.dispatcharrVodId }.count; s = e }
            if active { debugLog(CloudCanon.migrationLine("progress", rows: n)) }
            s.envelope = v2(s.envelope)
            return .some((s.text, n))
        case .reminders:
            guard var r = CloudReminders.decode(text: body) else { return .some(nil) }
            r.envelope = v2(r.envelope)
            return .some((r.text, 0))
        case .watchlist:
            guard let w = CloudWatchlist.decode(text: body) else { return .some(nil) }
            var s = w
            var (nw, nh) = (0, 0)
            if active {
                s = enrichWatchlist(w)
                nw = zip(s.entries, w.entries).filter { $0.dispatcharrVodId != $1.dispatcharrVodId }.count
                nh = zip(s.hidden, w.hidden).filter { $0.dispatcharrVodId != $1.dispatcharrVodId }.count
                debugLog(CloudCanon.migrationLine("watchlist", rows: nw))
                debugLog(CloudCanon.migrationLine("hiddenTitles", rows: nh))
            }
            s.envelope = v2(s.envelope)
            return .some((s.text, nw + nh))
        case .preferences:
            guard let p = CloudPreferences.decode(text: body) else { return .some(nil) }
            let l = lookup()
            if active && l.ids.channels.isEmpty && !CloudCanon.referencedChannels(p).isEmpty { return nil }
            var (s, n) = CloudCanon.enrichPreferences(p, l.ids)
            if active { debugLog(CloudCanon.migrationLine("recents and collections", rows: n)) }
            s.envelope = v2(s.envelope)
            return .some((s.text, n))
        case .playlists, .credentials:
            return .some(nil)
        }
    }

    /// Retries a waiting backup update: at launch and once the VOD catalog sweep goes quiet.
    func retryIdUpdate(_ reason: String) {
        guard cloudOn, !pendingIdUpdate().isEmpty else { return }
        debugLog("[CLOUD] id migration retry (\(reason))")
        migrateCanonicalIds()
    }

    /// The VOD catalog wrote a page: retry the update 3 s after the sweep goes quiet.
    func noteCatalogPage() {
        catalogRetry?.cancel()
        catalogRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DsyncReadiness.PAGE_RECHECK_MS) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.retryIdUpdate("catalog")
        }
    }

    // MARK: - Rule 4 setup state (Android setupState)

    private static let HOLD_TTL_MS: Int64 = 30 * 60 * 1000

    /// Onboarding with both providers: hold the shared categories (pull and push) until the choice.
    func holdShared() {
        state.set("cloud.holdShared", Self.nowMs())
        debugLog("[CLOUD] shared categories held until the setup choice")
    }

    func sharedHeld() -> Bool {
        let at = state.long("cloud.holdShared")
        return at > 0 && Self.nowMs() - at < Self.HOLD_TTL_MS
    }

    func releaseHold() {
        guard state.contains("cloud.holdShared") else { return }
        state.remove("cloud.holdShared")
        debugLog("[CLOUD] setup hold released")
    }

    func markCloudUnknown() {
        if cloudUnknown() { return }
        state.set("cloud.unknown", true)
        debugLog("[CLOUD] iCloud state unknown: shared files wait for a working setup probe")
    }

    func cloudUnknown() -> Bool { state.bool("cloud.unknown") }

    func clearCloudUnknown() {
        guard cloudUnknown() else { return }
        state.remove("cloud.unknown")
        debugLog("[CLOUD] iCloud state known again")
    }

    func markReplaceDeferred() { state.set("cloud.replaceDeferred", true) }
    func clearReplaceDeferred() { state.remove("cloud.replaceDeferred") }
    func replaceDeferred() -> Bool { state.bool("cloud.replaceDeferred") }

    private func waitKey(_ c: DsyncCategory) -> String { "cloud.replaceWait|\(c.rawValue)" }
    func replaceWaiting(_ c: DsyncCategory) -> Bool { state.bool(waitKey(c)) }
    func clearReplaceWait(_ c: DsyncCategory) { state.remove(waitKey(c)) }

    /// The user chose Dispatcharr: every shared iCloud file waits for its Dispatcharr pull before its first push.
    func armReplaceWait() { for c in CloudCanon.SHARED_FILES { state.set(waitKey(c), true) } }

    /// The user chose iCloud: nothing waits on Dispatcharr.
    func clearReplaceWaits() { for c in CloudCanon.SHARED_FILES { clearReplaceWait(c) } }

    /// iCloud is usable on this device: Sync with iCloud on and an iCloud account signed in.
    var available: Bool { cloudOn && FileManager.default.ubiquityIdentityToken != nil }

    // MARK: - Probe (read only)

    /// The iCloud copy's shared categories, summarized with the Dispatcharr probe's fingerprints
    /// and filters (canonical-id rows only, Off categories left out). Nil when iCloud could not be
    /// read: unknown, never empty. Nothing is applied.
    func readSharedSummary() -> SetupSourceChoice.Summary? {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            debugLog(CloudCanon.probeFailedLine("NoAccount"))
            return nil
        }
        let now = Self.nowMs()
        let scopes = DsyncLocal.scopes()
        let pid = DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString
        var out: [String: SetupSourceChoice.Category] = [:]
        var carriedP: CloudProgress?
        var carriedW: CloudWatchlist?
        var ids = lookup().ids
        func fail(_ c: DsyncCategory) -> SetupSourceChoice.Summary? {
            debugLog(CloudCanon.probeFailedLine("Decode\(CloudCanon.fileName(c))"))
            return nil
        }
        if let b = backupBody(.favorites) {
            guard let f = CloudFavorites.decode(text: b) else { return fail(.favorites) }
            out["favorites"] = CloudCanon.favorites(f, ids)
        }
        if let b = backupBody(.watchProgress) {
            guard let w0 = CloudProgress.decode(text: b) else { return fail(.watchProgress) }
            let w = CloudCanon.progressInScope(w0, host: pid)
            // Snapshots older than the update resolve their local ids here.
            let c = CloudCanon.progressCandidates(w).filter { !DsyncHeld.isPlaceholder($0.videoId) }
            let l = lookup(movieIds: c.filter { $0.vodType == "movie" }.map(\.videoId), episodeIds: c.filter { $0.vodType == "episode" }.map(\.videoId))
            ids.movies.merge(l.ids.movies) { a, _ in a }
            ids.episodes = l.ids.episodes
            out["progress"] = CloudCanon.progress(w, ids, nowMs: now)
            carriedP = w
        }
        if let b = backupBody(.reminders) {
            guard let r = CloudReminders.decode(text: b) else { return fail(.reminders) }
            out["reminders"] = CloudCanon.reminders(r, nowMs: now)
        }
        if let b = backupBody(.watchlist) {
            guard let w = CloudWatchlist.decode(text: b) else { return fail(.watchlist) }
            let movies = (w.entries.filter { $0.vodType != "series" && ($0.serverId == nil || $0.serverId == pid) }.map(\.vodId) +
                w.hidden.filter { $0.vodType != "series" && ($0.serverId == nil || $0.serverId == pid) }.map(\.vodId))
            ids.movies.merge(lookup(movieIds: movies).ids.movies) { a, _ in a }
            out["watchlist"] = CloudCanon.watchlist(w, ids, host: pid)
            out["hiddenTitles"] = CloudCanon.hiddenTitles(w, ids, host: pid)
            carriedW = w
        }
        var carried = CloudCanon.carriedItems(carriedP, carriedW, ids)
        if let b = backupBody(.preferences) {
            guard let p = CloudPreferences.decode(text: b) else { return fail(.preferences) }
            out["recents"] = CloudCanon.recentsCategory(p, ids)
            carried.formUnion(CloudCanon.recentChannelItems(p, ids))
            out["collections"] = CloudCanon.collectionsCategory(p, ids)
            out["hiddenGroups"] = CloudCanon.hiddenGroupsCategory(p)
            out["groupOrder"] = CloudCanon.groupOrderCategory(p)
            out["settings"] = CloudCanon.settingsOf(p) { SetupSourceChoice.nameOff(scopes, $0) }
        }
        // Section 10a: rows the iCloud copy carries with a canonical id are representable here.
        if let pid { dsync.noteCloudItems(pid, carried) }
        let kept = SetupSourceChoice.forDevice(SetupSourceChoice.Summary(categories: out)) { SetupSourceChoice.itemOff(scopes, $0) }.categories
        let line = kept.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rows)" }.joined(separator: ", ")
        debugLog("[CLOUD] setup probe \(line.isEmpty ? "empty" : line)")
        return SetupSourceChoice.Summary(categories: kept, lastWrite: kept.values.map(\.updatedAt).max())
    }

    // MARK: - Rule 4 replace (the user chose the iCloud backup)

    /// The settings lanes the last replace applied (Rule 4 mirror for the forced Dispatcharr push).
    private var mirrorLanes: (String, [String: [String: DsyncJSON]])?

    /// Applies every shared iCloud category as a true replace. Per category: true when the backup
    /// applied or had no file (a missing file replaces nothing), false when it failed or did not run.
    func applySharedForReplace(_ ignoreOwnership: Bool) async -> [DsyncCategory: Bool] {
        let wanted = CloudCanon.SHARED_FILES.filter(fileEnabled)
        debugLog("[CLOUD] applying backup (user chose iCloud) categories=\(wanted.map { CloudCanon.fileName($0) })")
        guard let server = DsyncLocal.activeDispatcharrPlaylist() else { return [:] }
        var out: [DsyncCategory: Bool] = [:]
        for c in wanted {
            guard let body = backupBody(c) else { out[c] = true; continue }
            out[c] = await replace(c, body, server)
        }
        return out
    }

    private func replace(_ c: DsyncCategory, _ body: String, _ server: ServerConnection) async -> Bool {
        let pid = server.id.uuidString
        let now = Self.nowMs()
        switch c {
        case .favorites:
            guard let s = CloudFavorites.decode(text: body) else { return false }
            let local = DsyncLocal.favorites()
            let m = DsyncLocal.channelMap(pid)
            let order = s.entries.sorted { $0.displayOrder < $1.displayOrder }
                .map { e in e.dispatcharrChannelId.flatMap { m.toLocal[$0] } ?? e.channelId }.distinctOrdered()
            let gone = CloudCanon.favoriteReplaceDeletes(local, s)
            DsyncLocal.setFavorites(order)
            debugLog(CloudCanon.replaceLine("favorites", local: local.count, backup: s.entries.count, removed: gone.count))
            return true
        case .watchProgress:
            guard let s0 = CloudProgress.decode(text: body) else { return false }
            let s = CloudCanon.progressInScope(s0, host: pid)
            let held = s.entries.compactMap(CloudCanon.heldRow)
            let rows = s.entries.compactMap { e -> ProgressRow? in
                guard !DsyncHeld.isPlaceholder(e.videoId), let id = e.dispatcharrVodId ?? Int(e.videoId),
                      e.vodType == "movie" || e.vodType == "episode" else { return nil }
                return ProgressRow(vodId: id, type: e.vodType == "episode" ? "e" : "m", position: e.positionMs / 1000,
                                   duration: e.durationMs / 1000, updatedAt: e.updatedAt / 1000, finished: e.isFinished,
                                   seriesId: e.vodType == "episode" ? e.seriesId.flatMap { Int($0) } : nil,
                                   season: e.seasonNumber, episode: e.episodeNumber, title: e.title)
            }
            var written = 0
            let left = await DsyncLocal.applyProgress(server, rows, written: &written)
            dsync.holdFromCloud(pid, DsyncHeld.merge(held, left), replace: true)
            debugLog("[CLOUD] held progress rows=\(held.count + left.count) (replace)")
            let localRows = DsyncLocal.progressRows(pid)
            let local = localRows.map(progressEntry)
            let gone = Set(CloudCanon.progressReplaceDeletes(local, s, nowMs: now))
            if let ctx = WatchProgressManager.modelContext, !gone.isEmpty {
                for r in localRows where gone.contains(r.vodID) { ctx.delete(r) }
                do { try ctx.save() } catch { debugLog("[CLOUD] progress replace save failed: \(type(of: error))") }
                NotificationCenter.default.post(name: .syncManagerDidUpdateWatchProgress, object: nil)
            }
            debugLog(CloudCanon.replaceLine("progress", local: CloudCanon.progressCounted(local, nowMs: now).count,
                                            backup: CloudCanon.progress(s, .init(), nowMs: now).rows, removed: gone.count))
            return true
        case .reminders:
            guard let s = CloudReminders.decode(text: body) else { return false }
            let cur = ReminderManager.shared.syncableReminders
            let local = cur.map { k, r in
                CloudReminderEntry(reminderKey: k, channelName: r.channelName, programTitle: r.programTitle,
                                   startMillis: Int64(r.startTime.timeIntervalSince1970 * 1000), endMillis: Int64(r.startTime.timeIntervalSince1970 * 1000))
            }
            let gone = Set(CloudCanon.reminderReplaceDeletes(local, s, nowMs: now))
            // mergeRemote cancels the alarm of every key the map lacks and schedules the new ones.
            var next: [String: SyncableReminder] = cur.filter { !gone.contains($0.key) }
            let have = Set(next.values.map { CloudCanon.reminderItem($0.channelName, Int64($0.startTime.timeIntervalSince1970)) })
            for e in s.entries where next[e.reminderKey] == nil && !have.contains(CloudCanon.reminderItem(e.channelName, e.startMillis / 1000)) {
                next[e.reminderKey] = SyncableReminder(programTitle: e.programTitle, channelName: e.channelName,
                                                       startTime: Date(timeIntervalSince1970: TimeInterval(e.startMillis) / 1000),
                                                       updatedAt: Date(timeIntervalSince1970: 0))
            }
            ReminderManager.shared.mergeRemote(next)
            debugLog(CloudCanon.replaceLine("reminders", local: local.filter { $0.endMillis >= now }.count,
                                            backup: CloudCanon.reminders(s, nowMs: now).rows, removed: gone.count))
            return true
        case .watchlist:
            guard let s = CloudWatchlist.decode(text: body) else { return false }
            replaceWatchlist(s, pid)
            if SyncItemCatalog.isEnabled(SyncItemCatalog.hiddenTitlesID) { replaceHidden(s, pid) }
            return true
        case .preferences:
            guard let s = CloudPreferences.decode(text: body) else { return false }
            replacePreferences(s, pid)
            return true
        case .playlists, .credentials:
            return false
        }
    }

    private func replaceWatchlist(_ s: CloudWatchlist, _ pid: String) {
        guard let ctx = WatchlistManager.modelContext else { return }
        let rows = (try? ctx.fetch(FetchDescriptor<WatchlistEntry>())) ?? []
        let now = Self.nowMs()
        let local = rows.map {
            CloudWatchlistEntry(vodId: $0.vodID, vodType: $0.vodType == "series" ? "series" : "movie", title: $0.title,
                                posterUrl: $0.posterURL, releaseYear: $0.releaseYear, rating: $0.rating, serverId: $0.serverID,
                                addedAt: Int64($0.addedAt.timeIntervalSince1970 * 1000))
        }
        func id(_ e: CloudWatchlistEntry) -> String { "\(e.vodType)|\(e.vodId)|\(e.serverId ?? "")" }
        let inScope = { (e: CloudWatchlistEntry) in e.serverId == nil || e.serverId == pid }
        let localLive = CloudCanon.liveInScope(local, live: { $0.isLive }, inScope: inScope)
        let result = CloudCanon.replaceMarks(local, s.entries, identity: id, live: { $0.isLive }, inScope: inScope,
                                             tombstone: { var e = $0; e.removedAt = now; return e })
        let haveLocal = Set(local.map(id))
        let wantLive = Dictionary(result.filter(\.isLive).map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        var removed = 0
        for r in rows {
            let k = "\(r.vodType == "series" ? "series" : "movie")|\(r.vodID)|\(r.serverID ?? "")"
            if wantLive[k] == nil { ctx.delete(r); removed += 1 }
        }
        for (k, e) in wantLive where !haveLocal.contains(k) {
            ctx.insert(WatchlistEntry(vodID: e.vodId, title: e.title, posterURL: e.posterUrl, vodType: e.vodType, serverID: e.serverId,
                                      releaseYear: e.releaseYear, rating: e.rating,
                                      addedAt: Date(timeIntervalSince1970: TimeInterval(e.addedAt) / 1000)))
        }
        do { try ctx.save() } catch { debugLog("[CLOUD] watchlist replace save failed: \(type(of: error))") }
        debugLog(CloudCanon.replaceLine("watchlist", local: localLive, backup: CloudCanon.watchlist(s, .init(), host: pid).rows, removed: removed))
    }

    private func replaceHidden(_ s: CloudWatchlist, _ pid: String) {
        let now = Self.nowMs()
        let local = hiddenEntries(HiddenVODStore.shared.entries.mapValues { $0.mapValues { ($0.hidden, $0.updatedAt) } })
        func id(_ e: CloudHiddenEntry) -> String { "\(e.vodType)|\(e.vodId)|\(e.serverId ?? "")" }
        let inScope = { (e: CloudHiddenEntry) in e.serverId == nil || e.serverId == pid }
        let localLive = CloudCanon.liveInScope(local, live: { $0.isLive }, inScope: inScope)
        let result = CloudCanon.replaceMarks(local, s.hidden, identity: id, live: { $0.isLive }, inScope: inScope,
                                             tombstone: { var e = $0; e.unhiddenAt = now; return e })
        let before = Dictionary(local.map { (id($0), $0.isLive) }, uniquingKeysWith: { a, _ in a })
        var removed = 0
        for e in result where before[id(e)] != e.isLive && (before[id(e)] != nil || e.isLive) {
            if before[id(e)] == true && !e.isLive { removed += 1 }
            // Unscoped rows have no playlist bucket on Apple: they apply to the active playlist.
            HiddenVODStore.shared.setHidden(e.isLive, type: e.vodType, id: e.vodId, serverID: e.serverId ?? pid)
        }
        debugLog(CloudCanon.replaceLine("hiddenTitles", local: localLive, backup: CloudCanon.hiddenTitles(s, .init(), host: pid).rows, removed: removed))
    }

    /// Typed wire value of a snapshot string for one schema name.
    private static func typed(_ name: String, _ v: String) -> DsyncJSON {
        switch DsyncSettingsMap.entry(name)?.kind {
        case .bool: return .bool(v.lowercased() == "true")
        case .int, .double: return .number(v)
        default: return .string(v)
        }
    }

    private func replacePreferences(_ s: CloudPreferences, _ pid: String) {
        let localSettings = DsyncLocal.settingsValues().count
        let m = DsyncLocal.channelMap(pid)
        func local(_ id: String) -> String { s.dispatcharrChannelIds?[id].flatMap { m.toLocal[$0] } ?? id }
        DsyncLocal.setRecents(pid, CloudCanon.recents(s).map(local))
        DsyncLocal.setCollections(CloudCanon.collections(s).map {
            ChannelCollection(id: $0.id, name: $0.name, memberIDs: $0.memberIds.map(local),
                              placement: CollectionPlacement(rawValue: $0.placement) ?? .end)
        })
        DsyncLocal.setHiddenGroups(DsyncPayloads.HiddenGroups(live: CloudCanon.lines(s.keys[CloudCanon.K_HIDDEN_LIVE]),
                                                              movies: CloudCanon.lines(s.keys[CloudCanon.K_HIDDEN_MOVIES]),
                                                              series: CloudCanon.lines(s.keys[CloudCanon.K_HIDDEN_SERIES])))
        DsyncLocal.setGroupOrder(DsyncPayloads.GroupOrder(mode: CloudCanon.groupMode(s.keys[CloudCanon.K_SORT_MODE]),
                                                          order: CloudCanon.lines(s.keys[CloudCanon.K_ORDER])))
        // Settings replace: each name read from the lane its scope picks here; a mapped name the
        // backup lacks returns to its default.
        let scopes = DsyncLocal.scopes()
        var lanes: [String: [String: DsyncJSON]] = [:]
        for (lane, vals) in s.settingsLanes { lanes[lane] = vals.reduce(into: [:]) { $0[$1.key] = Self.typed($1.key, $1.value) } }
        let picked = pickFromLanes(lanes, names: [], scopeOf: { DsyncLocal.scopeForName(scopes, $0) }, isTv: DsyncLocal.isTv)
        let r = DsyncSettingsValidator.filter(picked.filter { DsyncSettingsValidator.isOwned($0.key) })
        for e in DsyncSettingsMap.ENTRIES where r.accepted[e.name] == nil && DsyncLocal.scopeForName(scopes, e.name) != .off {
            UserDefaults.standard.removeObject(forKey: e.appleKey)
        }
        DsyncLocal.applySettings(r.accepted)
        mirrorLanes = (pid, CloudCanon.lanesOn(lanes) { SetupSourceChoice.nameOff(scopes, $0) })
        debugLog(CloudCanon.replaceLine("preferences", local: localSettings, backup: s.keys.count + s.tv.count + s.mobile.count, removed: 0))
    }

    /// No choice was needed: apply whatever iCloud held (a merge, as before).
    func applySharedNow(_ ignoreOwnership: Bool) {
        debugLog("[CLOUD] applying backup (held shared categories released)")
        SyncManager.shared.pullFromCloud(force: true, ignoreOwnership: ignoreOwnership)
    }

    // MARK: - Lifecycle

    /// Registers the iCloud side with Dispatcharr Sync and the coordinator, then the launch retry.
    func start() {
        guard !started else { return }
        started = true
        dsync.cloudCatalogPage = { [weak self] in self?.noteCatalogPage() }
        dsync.cloudMirrorLanes = { [weak self] pid in
            guard let m = self?.mirrorLanes, m.0 == pid else { return [:] }
            return m.1
        }
        dsync.cloudFollow = { [weak self] key, why in
            guard let c = key.category else { return }
            self?.follow(c, "\(key.suffix) \(why)")
        }
        dsync.cloudConverge = { [weak self] pid, summary, skip in await self?.converge(pid, summary, skip) }
        registerHooks()
        retryIdUpdate("launch")
        refreshUpdateOffer()
    }

    /// The coordinator's iCloud hooks (Android DriveSyncManager calls).
    private func registerHooks() {
        var h = DsyncCloudHooks()
        h.accountPresent = { FileManager.default.ubiquityIdentityToken != nil }
        h.readSharedSummary = { CloudSnapshotSync.shared.readSharedSummary() }
        h.markUnknown = { CloudSnapshotSync.shared.markCloudUnknown() }
        h.clearUnknown = { CloudSnapshotSync.shared.clearCloudUnknown() }
        h.isUnknown = { CloudSnapshotSync.shared.cloudUnknown() }
        h.releaseHold = { CloudSnapshotSync.shared.releaseHold() }
        h.holdShared = { CloudSnapshotSync.shared.holdShared() }
        h.sharedHeld = { CloudSnapshotSync.shared.sharedHeld() }
        h.applySharedForReplace = { await CloudSnapshotSync.shared.applySharedForReplace($0) }
        h.applySharedNow = { CloudSnapshotSync.shared.applySharedNow($0) }
        h.clearReplaceWaits = { CloudSnapshotSync.shared.clearReplaceWaits() }
        h.armReplaceWait = { CloudSnapshotSync.shared.armReplaceWait() }
        h.replaceBackupNow = { await CloudSnapshotSync.shared.replaceBackupNow() }
        h.markReplaceDeferred = { CloudSnapshotSync.shared.markReplaceDeferred() }
        h.clearReplaceDeferred = { CloudSnapshotSync.shared.clearReplaceDeferred() }
        h.replaceDeferred = { CloudSnapshotSync.shared.replaceDeferred() }
        SetupSourceCoordinator.shared.cloud = h
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// Which sync providers the owner runs, per scope (Android SyncProvidersStore): "icloud" for the
/// iCloud copy, "dsync|<playlist>" for the base user's Dispatcharr copy.
@MainActor
enum SyncProvidersStore {
    static let ICLOUD = "icloud"
    static func dsyncScope(_ playlistId: String) -> String { "dsync|\(playlistId)" }

    private static var state: DsyncStateStore { DsyncStateStore.shared }

    static func record(_ scope: String) -> SyncProvidersRecord? {
        state.string("providers.rec|\(scope)").flatMap { DsyncJSONParser.parse($0) }.flatMap { SyncProvidersRules.fromJson($0) }
    }

    private static func save(_ scope: String, _ r: SyncProvidersRecord) {
        state.set("providers.rec|\(scope)", DsyncJSONEncoder.encode(SyncProvidersRules.toJson(r)))
    }

    /// Pull: keep the newer of the stored and the incoming record.
    static func fold(_ scope: String, _ incoming: SyncProvidersRecord?) {
        guard let incoming, let next = SyncProvidersRules.newer(record(scope), incoming), next != record(scope) else { return }
        save(scope, next)
    }

    /// Push: the record to write for [scope] (nil = nothing to write).
    static func forPush(_ scope: String, dispatcharrOn: Bool, icloudOn: Bool, deviceId: String) -> SyncProvidersRecord? {
        let reported = Set((state.string("providers.rep|\(scope)") ?? "").split(separator: ",").map(String.init))
        let p = SyncProvidersRules.forPush(stored: record(scope), isBaseProfile: true, dispatcharrOn: dispatcharrOn, icloudOn: icloudOn,
                                           reported: reported, deviceId: deviceId, nowMs: CloudSnapshotSync.nowMs())
        state.set("providers.rep|\(scope)", p.reported.sorted().joined(separator: ","))
        if let r = p.record { save(scope, r) }
        return p.record
    }
}
