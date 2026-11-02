//  DsyncLocal.swift
//  Aerio
//
//  Dispatcharr Sync: the Apple stores behind each category, the
//  counterparts of the Android DAOs and AppPreferences calls the
//  DispatcharrSyncManager reads and writes. Every id the schema carries is
//  the Dispatcharr integer id; on Apple the Dispatcharr Direct Connect
//  stores already key by it (ChannelDisplayItem.id = String(channel id),
//  VODMovie.id and VODEpisode.id = String(movie or episode id)), so the
//  Android VodIdResolver collapses to Int(String) here. A movie row
//  "resolves" when the active playlist's VOD catalog holds it (title and
//  artwork for Continue Watching); an episode when its series id is known.
//
//  Category to Apple store:
//    favorites     FavoritesStore (UserDefaults favoriteChannelIDs, favoriteOrder)
//    recents       RecentChannelsStore (aerio.recent.channels.v1.<playlist>)
//    collections   ChannelCollectionsStore (channelCollections)
//    progress      SwiftData WatchProgress (serverID = playlist id)
//    reminders     ReminderManager (programReminders)
//    watchlist     SwiftData WatchlistEntry (serverID = playlist id)
//    hiddenTitles  HiddenVODStore (vod.hiddenTitles.v1, per playlist)
//    hiddenGroups  hiddenChannelGroups, hiddenMovieGroups, hiddenSeriesGroups
//    groupOrder    channelGroupOrder, channelGroupOrder.sortMode
//    radioDefault  radioModeByDefault
//    remoteMap     remoteControlMap.tv (tvOS writes and applies; phones round-trip)
//    settings      DsyncSettingsMap names to their Apple keys
//    profiles      nothing yet (the Profiles feature is a later batch)

import Foundation
import SwiftData

@MainActor
enum DsyncLocal {

    static var isTv: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Playlist and connection

    /// The active playlist when it is Dispatcharr Direct Connect: what the channel list is loaded from.
    static func activeDispatcharrPlaylist() -> ServerConnection? {
        guard let s = ChannelStore.shared.activeServer, s.type == .dispatcharrAPI else { return nil }
        return s
    }

    static func server(_ playlistId: String) -> ServerConnection? {
        guard let ctx = WatchProgressManager.modelContext, let id = UUID(uuidString: playlistId) else { return nil }
        let d = FetchDescriptor<ServerConnection>(predicate: #Predicate { $0.id == id })
        return (try? ctx.fetch(d))?.first
    }

    /// The App Data client for a playlist, with the same auth the rest of Direct Connect uses.
    static func client(_ server: ServerConnection) -> DispatcharrAppDataClient? {
        let key = server.effectiveApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let jwt = server.dispatcharrCredentialType == .usernamePassword
        guard jwt || !key.isEmpty else { return nil }
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode,
                                 serverID: server.id,
                                 savedUsername: jwt ? server.username : nil)
        return DispatcharrAppDataClient(api: api)
    }

    // MARK: - Sync Categories scopes

    /// Item id to scope, from the Apple Sync Categories choices (same ids as DsyncItemCatalog).
    static func scopes() -> [String: DsyncScope] {
        var out: [String: DsyncScope] = [:]
        for item in SyncItemCatalog.allItems { out[item.id] = DsyncScope(rawValue: item.scope.rawValue) ?? .all }
        return out
    }

    /// The scope of the item that carries a settings name (names no item carries are All devices).
    static func scopeForName(_ scopes: [String: DsyncScope], _ name: String) -> DsyncScope {
        guard let item = DsyncItemCatalog.itemForName(name) else { return .all }
        return scopes[item.id] ?? .all
    }

    // MARK: - Channel map (schema 4: Dispatcharr channel id)

    struct ChannelMap {
        var toInt: [String: Int] = [:]
        var toLocal: [Int: String] = [:]
        var nameOf: [Int: String] = [:]
        var intByName: [String: Int] = [:]
    }

    /// The loaded channel list of [playlistId], or an empty map while it is not loaded.
    static func channelMap(_ playlistId: String) -> ChannelMap {
        var m = ChannelMap()
        guard ChannelStore.shared.activeServer?.id.uuidString == playlistId else { return m }
        for c in ChannelStore.shared.channels {
            guard let id = c.dispatcharrChannelID ?? Int(c.id) else { continue }
            m.toInt[c.id] = id
            if m.toLocal[id] == nil { m.toLocal[id] = c.id }
            if m.nameOf[id] == nil { m.nameOf[id] = c.name }
            if m.intByName[c.name] == nil { m.intByName[c.name] = id }
        }
        return m
    }

    // MARK: - VOD catalog readiness

    /// True once the playlist's movie catalog finished a sweep (or VOD is off, so none will come).
    static func moviesReady(_ server: ServerConnection) async -> Bool {
        if !server.vodEnabled { return true }
        let key = VODLibraryCache.identity(for: server)
        return await VODCatalogStore.shared.sweepState(playlistKey: key, kind: .movie)?.completedAt != nil
    }

    /// Catalog items for ids, from the active playlist's catalog only.
    static func catalog(_ server: ServerConnection, kind: VODItemType, ids: [Int]) async -> [Int: VODDisplayItem] {
        guard !ids.isEmpty else { return [:] }
        let key = VODLibraryCache.identity(for: server)
        let found = await VODCatalogStore.shared.items(playlistKey: key, kind: kind, ids: ids.map(String.init))
        var out: [Int: VODDisplayItem] = [:]
        for (k, v) in found { if let i = Int(k) { out[i] = v } }
        return out
    }

    // MARK: - Favorites

    static func favorites() -> [String] {
        let ud = UserDefaults.standard
        let members = ud.stringArray(forKey: "favoriteChannelIDs") ?? []
        let set = Set(members)
        let ordered = (ud.stringArray(forKey: FavoritesStore.orderKey) ?? []).filter { set.contains($0) }.distinctOrdered()
        let placed = Set(ordered)
        return ordered + members.filter { !placed.contains($0) }.sorted()
    }

    static func setFavorites(_ order: [String]) {
        FavoritesStore.shared.applySynced(order: order, items: ChannelStore.shared.channels)
    }

    // MARK: - Recents

    static func recents(_ playlistId: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "aerio.recent.channels.v1.\(playlistId)") ?? []
    }

    static func setRecents(_ playlistId: String, _ ids: [String]) {
        RecentChannelsStore.applySyncSnapshot([playlistId: ids], replace: false)
    }

    // MARK: - Collections

    static func collections() -> [ChannelCollection] { ChannelCollectionsStore.shared.collections }

    static func setCollections(_ c: [ChannelCollection]) {
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "channelCollections") }
        ChannelCollectionsStore.shared.reloadFromDefaults()
    }

    // MARK: - Watch progress (SwiftData)

    static func progressRows(_ playlistId: String) -> [WatchProgress] {
        guard let ctx = WatchProgressManager.modelContext else { return [] }
        let all = (try? ctx.fetch(FetchDescriptor<WatchProgress>())) ?? []
        return all.filter { ($0.serverID == nil || $0.serverID == playlistId) && !$0.vodID.contains("://")
            && ($0.vodType == "movie" || $0.vodType == "episode") }
    }

    /// One local row as a schema row, or nil when its id is not a Dispatcharr integer id.
    static func progressRow(_ p: WatchProgress) -> ProgressRow? {
        guard !DsyncHeld.isPlaceholder(p.vodID), let id = Int(p.vodID) else { return nil }
        let ep = p.vodType == "episode"
        return ProgressRow(vodId: id, type: ep ? "e" : "m",
                           position: Int64(p.positionMs) / 1000, duration: Int64(p.durationMs) / 1000,
                           updatedAt: Int64(p.updatedAt.timeIntervalSince1970), finished: p.isFinished,
                           seriesId: ep ? p.seriesID.flatMap { Int($0) } : nil,
                           season: ep ? p.seasonNumber : 0, episode: ep ? p.episodeNumber : 0, title: p.title)
    }

    /// Server rows into SwiftData. Returns the rows this device cannot resolve yet (held, section 10a).
    @discardableResult
    static func applyProgress(_ server: ServerConnection, _ rows: [ProgressRow], written: inout Int) async -> [ProgressRow] {
        guard let ctx = WatchProgressManager.modelContext else { return rows }
        let pid = server.id.uuidString
        let movies = await catalog(server, kind: .movie, ids: rows.filter { $0.type == "m" }.map(\.vodId))
        var unresolved: [ProgressRow] = []
        let local = progressRows(pid)
        for r in rows {
            let resolved = r.type == "e" ? r.seriesId != nil : movies[r.vodId] != nil
            if !resolved { unresolved.append(r); continue }
            let vid = String(r.vodId)
            let ep = r.type == "e"
            let cur = local.first { $0.vodID == vid && $0.serverID == pid } ?? local.first { $0.vodID == vid && $0.serverID == nil }
            let at = Date(timeIntervalSince1970: TimeInterval(r.updatedAt))
            if let cur, at <= cur.updatedAt { continue }
            let pos = Int32(clamping: r.position * 1000)
            let dur = Int32(clamping: r.duration * 1000)
            if let cur {
                if !(cur.title.count > r.title.count && cur.title.hasPrefix(r.title)) { cur.title = r.title }
                cur.positionMs = pos
                if r.duration > 0 { cur.durationMs = dur }
                cur.updatedAt = at
                cur.vodType = ep ? "episode" : "movie"
                if let s = r.seriesId { cur.seriesID = String(s) }
                if r.season > 0 { cur.seasonNumber = r.season }
                if r.episode > 0 { cur.episodeNumber = r.episode }
                cur.isFinished = r.finished
                if cur.serverID == nil { cur.serverID = pid }
            } else {
                let item = movies[r.vodId]
                let p = WatchProgress(vodID: vid, title: item?.name ?? r.title, positionMs: pos, durationMs: dur,
                                      posterURL: item?.posterURL?.absoluteString, vodType: ep ? "episode" : "movie",
                                      updatedAt: at, isFinished: r.finished, serverID: pid,
                                      seriesID: r.seriesId.map(String.init), seasonNumber: r.season, episodeNumber: r.episode)
                ctx.insert(p)
            }
            written += 1
        }
        if written > 0 {
            do { try ctx.save() } catch { debugLog("[DSYNC] progress save failed: \(type(of: error))") }
        }
        return unresolved
    }

    // MARK: - Watchlist (SwiftData) and Hidden Titles

    static func watchlist(_ playlistId: String) -> [WatchlistEntry] {
        guard let ctx = WatchlistManager.modelContext else { return [] }
        let all = (try? ctx.fetch(FetchDescriptor<WatchlistEntry>())) ?? []
        return all.filter { $0.serverID == nil || $0.serverID == playlistId }
    }

    /// A local (type, id) as a schema row, or nil when the id is not an integer.
    static func markRow(type: String, id: String, at: Date) -> VodMarkRow? {
        guard let i = Int(id) else { return nil }
        switch type {
        case "movie": return VodMarkRow(vodId: i, type: "m", at: Int64(at.timeIntervalSince1970))
        case "series": return VodMarkRow(vodId: i, type: "s", at: Int64(at.timeIntervalSince1970))
        default: return nil
        }
    }

    /// Replace the playlist's watchlist with [rows]; movies this catalog lacks are skipped, local
    /// rows without an integer id are kept.
    static func applyWatchlist(_ server: ServerConnection, _ rows: [VodMarkRow]) async {
        guard let ctx = WatchlistManager.modelContext else { return }
        let pid = server.id.uuidString
        let movies = await catalog(server, kind: .movie, ids: rows.filter { $0.type == "m" }.map(\.vodId))
        let series = await catalog(server, kind: .series, ids: rows.filter { $0.type == "s" }.map(\.vodId))
        var wanted: [String: VodMarkRow] = [:]
        for r in rows where r.type == "s" || movies[r.vodId] != nil { wanted["\(r.type)|\(r.vodId)"] = r }
        var have = Set<String>()
        for e in watchlist(pid) {
            guard let m = markRow(type: e.vodType, id: e.vodID, at: e.addedAt) else { continue }
            let k = "\(m.type)|\(m.vodId)"
            if wanted[k] != nil { have.insert(k) } else if e.serverID == pid || e.serverID == nil { ctx.delete(e) }
        }
        for (k, r) in wanted where !have.contains(k) {
            let item = r.type == "m" ? movies[r.vodId] : series[r.vodId]
            ctx.insert(WatchlistEntry(vodID: String(r.vodId), title: item?.name ?? "", posterURL: item?.posterURL?.absoluteString,
                                      vodType: r.type == "m" ? "movie" : "series", serverID: pid,
                                      releaseYear: item?.releaseYear ?? "", rating: item?.rating ?? "",
                                      addedAt: Date(timeIntervalSince1970: TimeInterval(r.at))))
        }
        do { try ctx.save() } catch { debugLog("[DSYNC] watchlist save failed: \(type(of: error))") }
    }

    /// Hidden titles of the playlist: (type, id, hiddenAt).
    static func hiddenTitles(_ playlistId: String) -> [(String, String, Date)] {
        (HiddenVODStore.shared.entries[playlistId] ?? [:]).compactMap { k, e in
            guard e.hidden else { return nil }
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1], e.updatedAt) : nil
        }.sorted { $0.2 > $1.2 }
    }

    static func applyHiddenTitles(_ server: ServerConnection, _ rows: [VodMarkRow]) async {
        let pid = server.id.uuidString
        let movies = await catalog(server, kind: .movie, ids: rows.filter { $0.type == "m" }.map(\.vodId))
        var wanted = Set<String>()
        for r in rows where r.type == "s" || movies[r.vodId] != nil {
            wanted.insert(HiddenVODStore.entryKey(type: r.type == "m" ? "movie" : "series", id: String(r.vodId)))
        }
        for (t, id, _) in hiddenTitles(pid) where Int(id) != nil {
            if !wanted.contains(HiddenVODStore.entryKey(type: t, id: id)) { HiddenVODStore.shared.setHidden(false, type: t, id: id, serverID: pid) }
        }
        let have = Set(hiddenTitles(pid).map { HiddenVODStore.entryKey(type: $0.0, id: $0.1) })
        for k in wanted where !have.contains(k) {
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            HiddenVODStore.shared.setHidden(true, type: parts[0], id: parts[1], serverID: pid)
        }
    }

    // MARK: - Reminders

    static func reminders() -> [(key: String, info: SyncableReminder)] {
        ReminderManager.shared.syncableReminders.map { ($0.key, $0.value) }.sorted { $0.info.startTime < $1.info.startTime }
    }

    // MARK: - Groups, radio default, remote map

    static let hiddenGroupKeys = ("hiddenChannelGroups", "hiddenMovieGroups", "hiddenSeriesGroups")
    static let groupOrderKey = "channelGroupOrder"
    static let groupModeKey = "channelGroupOrder.sortMode"

    static func hiddenGroups() -> DsyncPayloads.HiddenGroups {
        DsyncPayloads.HiddenGroups(live: HiddenGroupsStore.load(forKey: hiddenGroupKeys.0).sorted(),
                                   movies: HiddenGroupsStore.load(forKey: hiddenGroupKeys.1).sorted(),
                                   series: HiddenGroupsStore.load(forKey: hiddenGroupKeys.2).sorted())
    }

    static func setHiddenGroups(_ g: DsyncPayloads.HiddenGroups) {
        HiddenGroupsStore.save(Set(g.live), forKey: hiddenGroupKeys.0)
        HiddenGroupsStore.save(Set(g.movies), forKey: hiddenGroupKeys.1)
        HiddenGroupsStore.save(Set(g.series), forKey: hiddenGroupKeys.2)
    }

    static func groupOrder() -> DsyncPayloads.GroupOrder {
        let mode = GroupOrderStore.loadMode(forKey: groupModeKey).lowercased()
        return DsyncPayloads.GroupOrder(mode: DsyncPayloads.GROUP_MODES.contains(mode) ? mode : "default",
                                        order: GroupOrderStore.load(forKey: groupOrderKey))
    }

    static func setGroupOrder(_ g: DsyncPayloads.GroupOrder) {
        GroupOrderStore.saveMode(GroupSortMode(rawValue: g.mode)?.rawValue ?? GroupSortMode.default.rawValue, forKey: groupModeKey)
        GroupOrderStore.save(g.order, forKey: groupOrderKey)
    }

    static func radioDefault() -> Bool { UserDefaults.standard.bool(forKey: RadioModeSession.byDefaultKey) }

    static func setRadioDefault(_ on: Bool) { UserDefaults.standard.set(on, forKey: RadioModeSession.byDefaultKey) }

    /// The TV map as stored (nil when the stored value does not parse).
    static func remoteMap() -> DsyncObject? {
        guard let data = UserDefaults.standard.data(forKey: RemoteControlStore.mapKey) else { return DsyncObject() }
        return DsyncJSONParser.parse(data)?.asObject
    }

    static func setRemoteMap(_ tv: DsyncObject) {
        if tv.isEmpty { UserDefaults.standard.removeObject(forKey: RemoteControlStore.mapKey) }
        else { UserDefaults.standard.set(Data(DsyncJSONEncoder.encode(tv).utf8), forKey: RemoteControlStore.mapKey) }
    }

    // MARK: - Settings

    /// The category color keys the Apple item carries (prefix families, no defaults scan).
    private static var familyKeys: [String] {
        SyncItemCatalog.allItems.first { $0.id == "categoryColors" }?.keys.filter {
            $0.hasPrefix(DsyncSettingsValidator.COLOR_PREFIX) || $0.hasPrefix(DsyncSettingsValidator.BUCKET_PREFIX)
        } ?? []
    }

    /// This device's values for the mapped schema names, in name order.
    static func settingsValues() -> [(String, DsyncJSON)] {
        let ud = UserDefaults.standard
        var out: [(String, DsyncJSON)] = []
        let names = DsyncSettingsMap.ENTRIES.map(\.name) + familyKeys
        for name in names.sorted() {
            guard let e = DsyncSettingsMap.entry(name), let v = DsyncSettingsMap.fromApple(e, ud.object(forKey: e.appleKey)) else { continue }
            out.append((name, v))
        }
        return out
    }

    /// Writes accepted values to their Apple keys; returns how many were written.
    @discardableResult
    static func applySettings(_ accepted: [String: DsyncJSON]) -> Int {
        let ud = UserDefaults.standard
        var n = 0
        for (name, v) in accepted.sorted(by: { $0.key < $1.key }) {
            guard let e = DsyncSettingsMap.entry(name), let a = DsyncSettingsMap.toApple(e, v) else { continue }
            ud.set(a, forKey: e.appleKey)
            n += 1
        }
        if n > 0 { NotificationCenter.default.post(name: .syncManagerDidApplyPreferences, object: nil) }
        return n
    }

    // MARK: - Change detection (the Android per-key source flows)

    /// A cheap fingerprint of the local data one key is built from; a change
    /// between two reads is a local change (Android sourceFor + distinctUntilChanged).
    static func signature(_ key: DsyncKey, _ playlistId: String) -> String {
        switch key {
        case .favorites: return favorites().joined(separator: ",")
        case .recents: return recents(playlistId).joined(separator: ",")
        case .progress:
            return progressRows(playlistId).map { "\($0.vodID)|\($0.positionMs)|\($0.updatedAt.timeIntervalSince1970)|\($0.isFinished)" }
                .sorted().joined(separator: ",")
        case .reminders: return reminders().map(\.key).joined(separator: ",")
        case .watchlist: return watchlist(playlistId).map { "\($0.vodType)|\($0.vodID)|\($0.serverID ?? "")" }.sorted().joined(separator: ",")
        case .hiddenTitles: return hiddenTitles(playlistId).map { "\($0.0)|\($0.1)" }.sorted().joined(separator: ",")
        case .hiddenGroups: let g = hiddenGroups(); return "\(g.live)|\(g.movies)|\(g.series)"
        case .groupOrder: let g = groupOrder(); return "\(g.mode)|\(g.order)"
        case .settings:
            return settingsValues().map { "\($0.0)=\($0.1.compact)" }.joined(separator: ",") + "|" +
                scopes().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ",")
        case .remoteMap: return remoteMap().map(DsyncJSONEncoder.encode) ?? "?"
        case .radioDefault: return radioDefault() ? "1" : "0"
        case .collections: return collections().map { "\($0.id)|\($0.name)|\($0.placement.rawValue)|\($0.memberIDs)" }.joined(separator: ",")
        case .profiles: return ""
        }
    }
}
