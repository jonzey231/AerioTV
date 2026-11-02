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

    /// The providers record every file of a push carries (part 4 of this port fills it; nil until then).
    func providersForPush() -> SyncProvidersRecord? { nil }

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

    // MARK: - Lifecycle

    /// Registers the iCloud side with Dispatcharr Sync and the coordinator, then the launch retry.
    func start() {
        guard !started else { return }
        started = true
        dsync.cloudCatalogPage = { [weak self] in self?.noteCatalogPage() }
        retryIdUpdate("launch")
        refreshUpdateOffer()
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
