//  ProfileDataStore.swift
//  Aerio
//
//  Profiles part 3: per-profile user data, mirroring Android ProfileScope.
//
//  Android keys every piece of user state by the active profile: the legacy
//  keys and rows ARE the default profile (token ""), a non-default profile
//  writes Room rows with its profileScope and preference keys with the
//  suffix "@prof:<profileId>" (core/profiles/ProfileScope.kt), and the
//  Dispatcharr Sync session restarts per token and pulls into that scope.
//  A new profile starts empty; removing one deletes its scope
//  (ProfileManager.deleteLocal).
//
//  Apple reads these stores straight from UserDefaults and SwiftData in many
//  places, so (like ProfileSettingsStore) the live keys and rows hold the
//  ACTIVE profile's data and every other profile has a saved slot that a
//  switch swaps in and out. The default profile's existing data is the live
//  data until the first switch away, which saves it as the default profile's
//  slot: that is the one-time migration, and nothing moves before it.
//
//  ProfileOverlay is the request-side half: the active non-default profile's
//  API key and Channel Profile assignment, read by ServerConnection
//  (effectiveApiKey, dispatcharrProfileIDList) so channel, guide, VOD, and
//  DVR loads run as that profile's Dispatcharr user.

import Foundation
import SwiftData

/// The active non-default profile per playlist (Android ProfileScope.Overlay). Thread safe.
final class ProfileOverlay: @unchecked Sendable {
    struct Values: Equatable, Sendable {
        let profileId: String
        let apiKey: String
        let channelProfileIds: [Int]
    }

    private static let shared = ProfileOverlay()
    private let lock = NSLock()
    private var map: [String: Values] = [:]

    /// The overlay for [playlistId], or nil (the default profile is active).
    static func values(_ playlistId: String) -> Values? {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.map[playlistId]
    }

    /// Replace every overlay. True when something changed.
    @discardableResult
    static func set(_ next: [String: Values]) -> Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        if shared.map == next { return false }
        shared.map = next
        return true
    }

    /// Cache key suffix for [playlistId]: "" for the default profile, else "@<profileId>".
    static func cacheSuffix(_ playlistId: String) -> String {
        values(playlistId).map { "@\($0.profileId)" } ?? ""
    }
}

/// The active non-default profile's own permissions (Android: DVR, catch-up,
/// VOD, and series follow the active profile's /api/accounts/users/me/), read
/// by ServerConnection.dispatcharrCapabilities. nil = the default profile,
/// whose snapshot lives on the playlist row. Thread safe, like ProfileOverlay.
final class ProfileCapsOverlay: @unchecked Sendable {
    struct Values: Equatable, Sendable {
        let userLevel: Int
        let isStaff: Bool
        let isSuperuser: Bool
        /// The profile's custom_properties JSON from its own /me/.
        let customProperties: String
        /// nil = never read: every capability stays unknown (the server decides).
        let fetchedAt: Date?
    }

    private static let shared = ProfileCapsOverlay()
    private let lock = NSLock()
    private var map: [String: Values] = [:]

    static func values(_ playlistId: String) -> Values? {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.map[playlistId]
    }

    /// Replace every overlay. True when something changed.
    @discardableResult
    static func set(_ next: [String: Values]) -> Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        if shared.map == next { return false }
        shared.map = next
        return true
    }
}

@MainActor
final class ProfileDataStore {

    /// UserDefaults keys that are per profile, whole (Android: favorites,
    /// collections, hidden titles, hidden groups, reminders). Recents are per
    /// playlist and added per swap. Group order and Radio Mode by Default are
    /// settings and swap with ProfileSettingsStore.
    static let DEFAULTS_KEYS: [String] = [
        "favoriteChannelIDs", FavoritesStore.orderKey,
        "channelCollections",
        HiddenVODStore.storageKey,
        DsyncLocal.hiddenGroupKeys.0, DsyncLocal.hiddenGroupKeys.1, DsyncLocal.hiddenGroupKeys.2,
        ReminderManager.defaultsKey,
    ]

    static func recentsKey(_ playlistId: String) -> String { "aerio.recent.channels.v1.\(playlistId)" }

    private let defaults: UserDefaults
    private let dir: URL

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // tvOS Application Support is not writable: AppCacheDirectory picks Caches there.
        dir = AppCacheDirectory.url.appendingPathComponent("profiledata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ profileId: String) -> URL {
        let safe = profileId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return dir.appendingPathComponent("\(safe).plist")
    }

    // MARK: Snapshots of the SwiftData rows

    struct ProgressSnap: Codable {
        var vodID: String, title: String, positionMs: Int32, durationMs: Int32, posterURL: String?
        var vodType: String, updatedAt: Date, isFinished: Bool, streamURL: String?, serverID: String?
        var seriesID: String?, seasonNumber: Int, episodeNumber: Int, upNextQueue: String?
    }

    struct WatchlistSnap: Codable {
        var vodID: String, title: String, posterURL: String?, vodType: String, serverID: String?
        var releaseYear: String, rating: String, addedAt: Date
    }

    private func progressLive(_ playlistId: String) -> [WatchProgress] {
        guard let ctx = WatchProgressManager.modelContext else { return [] }
        return ((try? ctx.fetch(FetchDescriptor<WatchProgress>())) ?? []).filter { $0.serverID == playlistId }
    }

    private func watchlistLive(_ playlistId: String) -> [WatchlistEntry] {
        guard let ctx = WatchlistManager.modelContext else { return [] }
        return ((try? ctx.fetch(FetchDescriptor<WatchlistEntry>())) ?? []).filter { $0.serverID == playlistId }
    }

    // MARK: Capture and restore

    private func keys(_ playlistId: String) -> [String] { Self.DEFAULTS_KEYS + [Self.recentsKey(playlistId)] }

    /// The live data of [playlistId] as a property list slot.
    private func capture(_ playlistId: String) -> [String: Any] {
        var d: [String: Any] = [:]
        for k in keys(playlistId) { if let v = defaults.object(forKey: k) { d[k] = v } }
        let enc = JSONEncoder()
        let p = progressLive(playlistId).map {
            ProgressSnap(vodID: $0.vodID, title: $0.title, positionMs: $0.positionMs, durationMs: $0.durationMs,
                         posterURL: $0.posterURL, vodType: $0.vodType, updatedAt: $0.updatedAt, isFinished: $0.isFinished,
                         streamURL: $0.streamURL, serverID: $0.serverID, seriesID: $0.seriesID,
                         seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber, upNextQueue: $0.upNextQueue)
        }
        let w = watchlistLive(playlistId).map {
            WatchlistSnap(vodID: $0.vodID, title: $0.title, posterURL: $0.posterURL, vodType: $0.vodType,
                          serverID: $0.serverID, releaseYear: $0.releaseYear, rating: $0.rating, addedAt: $0.addedAt)
        }
        return ["playlistId": playlistId, "defaults": d,
                "progress": (try? enc.encode(p)) ?? Data(), "watchlist": (try? enc.encode(w)) ?? Data()]
    }

    private func save(_ slot: [String: Any], _ profileId: String) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: slot, format: .binary, options: 0) else { return false }
        do { try data.write(to: file(profileId), options: .atomic); return true } catch { return false }
    }

    private func load(_ profileId: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file(profileId)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Make [slot] the live data of [playlistId]; nil = a profile with no data yet (Android: an empty scope).
    private func restore(_ slot: [String: Any]?, _ playlistId: String) -> (progress: Int, watchlist: Int) {
        let d = slot?["defaults"] as? [String: Any] ?? [:]
        for k in keys(playlistId) {
            if let v = d[k] { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) }
        }
        let dec = JSONDecoder()
        let p = (slot?["progress"] as? Data).flatMap { try? dec.decode([ProgressSnap].self, from: $0) } ?? []
        let w = (slot?["watchlist"] as? Data).flatMap { try? dec.decode([WatchlistSnap].self, from: $0) } ?? []
        if let ctx = WatchProgressManager.modelContext {
            for row in progressLive(playlistId) { ctx.delete(row) }
            for s in p {
                let row = WatchProgress(vodID: s.vodID, title: s.title, positionMs: s.positionMs, durationMs: s.durationMs,
                                        posterURL: s.posterURL, vodType: s.vodType, updatedAt: s.updatedAt,
                                        isFinished: s.isFinished, streamURL: s.streamURL, serverID: playlistId,
                                        seriesID: s.seriesID, seasonNumber: s.seasonNumber, episodeNumber: s.episodeNumber)
                row.upNextQueue = s.upNextQueue
                ctx.insert(row)
            }
        }
        if let ctx = WatchlistManager.modelContext {
            for row in watchlistLive(playlistId) { ctx.delete(row) }
            for s in w {
                ctx.insert(WatchlistEntry(vodID: s.vodID, title: s.title, posterURL: s.posterURL, vodType: s.vodType,
                                          serverID: playlistId, releaseYear: s.releaseYear, rating: s.rating, addedAt: s.addedAt))
            }
        }
        do { try WatchProgressManager.modelContext?.save() } catch { debugLog("[PROFILE] data swap: progress save failed: \(type(of: error))") }
        if WatchlistManager.modelContext !== WatchProgressManager.modelContext {
            do { try WatchlistManager.modelContext?.save() } catch { debugLog("[PROFILE] data swap: watchlist save failed: \(type(of: error))") }
        }
        return (p.count, w.count)
    }

    /// The in-memory stores re-read what the swap wrote.
    private func reloadStores(_ playlistId: String) {
        FavoritesStore.shared.applySynced(order: DsyncLocal.favorites(), items: ChannelStore.shared.channels)
        RecentChannelsStore.applySyncSnapshot([playlistId: DsyncLocal.recents(playlistId)], replace: false)
        ChannelCollectionsStore.shared.reloadFromDefaults()
        HiddenVODStore.shared.reloadFromDefaults()
        ReminderManager.shared.reloadFromDefaults()
    }

    /// A switch on [playlistId] from [from] to [to]: the outgoing data is kept
    /// in its slot, the incoming slot goes live (empty when it has none).
    /// The outgoing slot is written first; when that fails nothing changes.
    func swap(_ playlistId: String, from: String?, to: String) {
        guard from != to else { return }
        if let from {
            guard save(capture(playlistId), from) else {
                debugLog("[PROFILE] data swap: could not save the outgoing slot; data left in place")
                return
            }
        }
        let slot = load(to)
        let n = restore(slot, playlistId)
        reloadStores(playlistId)
        debugLog("[PROFILE] data swap \(from.map { String($0.prefix(8)) } ?? "?") -> \(to.prefix(8)) slot=\(slot != nil) progress=\(n.progress) watchlist=\(n.watchlist)")
    }

    /// Android deleteScope: a removed profile's data goes.
    func deleteScope(_ profileId: String) {
        try? FileManager.default.removeItem(at: file(profileId))
    }
}
