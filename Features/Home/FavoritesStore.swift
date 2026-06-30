import Foundation
import SwiftUI

// MARK: - Favorites Store
//
// v1.7.3: peeled out of the oversized HomeView.swift (god-file
// reduction). Pure move, no behavior change. See
// `project_aerio_god_files.md`.

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    @Published private(set) var favoriteItems: [ChannelDisplayItem] = []
    private var favoriteIDs: Set<String>

    /// App Group suite name, retained for reference / historical reasons.
    /// We no longer write to `UserDefaults(suiteName:)` on tvOS because
    /// the sandbox denies writes to every app-group container with EPERM
    /// on this project's Apple TV. See `TopShelfDataManager` doc below.
    /// The value writes go through `TopShelfKeychain` instead.
    static let appGroupID = "group.app.molinete.aerio.topshelf"

    /// UserDefaults key persisting the user's manually-chosen favorite ordering.
    /// Mirrored to iCloud KVS via `SyncManager` so the order rides along
    /// with the membership set.
    static let orderKey = "favoriteOrder"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "favoriteChannelIDs") ?? []
        self.favoriteIDs = Set(saved)
    }

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    /// True when the user has saved at least one favorite channel ID
    /// (persisted under `favoriteChannelIDs`), independent of whether the
    /// channel list has been hydrated into `favoriteItems` yet. CarPlay
    /// reads this at connect to decide whether a Favorites tab is worth
    /// showing, so the decision is correct even on a cold connect where
    /// channels are still loading and `favoriteItems` is momentarily empty.
    var hasFavorites: Bool { !favoriteIDs.isEmpty }

    func toggle(_ item: ChannelDisplayItem) {
        if favoriteIDs.contains(item.id) {
            favoriteIDs.remove(item.id)
            favoriteItems.removeAll { $0.id == item.id }
        } else {
            favoriteIDs.insert(item.id)
            // Append at the end so newly-favorited channels show up after the
            // user's manually-ordered list rather than getting alphabetically
            // shuffled into the middle.
            favoriteItems.append(item)
        }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "favoriteChannelIDs")
        persistOrder()
        syncToSharedDefaults()
        // Favorites are a deliberate user action, so push to iCloud KVS
        // immediately instead of the normal 60s debounced preference push.
        // Fixes GitHub issue #2 (Veldmuus): removing a favorite then force-
        // closing the app within 60s would let the next launch's
        // pullFromCloud() restore the stale favorite from KVS.
        SyncManager.shared.pushPreferencesImmediate()
    }

    /// Reorder favorites in response to a SwiftUI `.onMove` from the
    /// iOS Favorites tab. Persists the new order to UserDefaults under
    /// `favoriteOrder` (and SyncManager mirrors that key to iCloud KVS
    /// so the manual order syncs across devices, not just the membership
    /// set under `favoriteChannelIDs`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        favoriteItems.move(fromOffsets: source, toOffset: destination)
        persistOrder()
        syncToSharedDefaults()
        // Same rationale as toggle(): deliberate user action, push now.
        SyncManager.shared.pushPreferencesImmediate()
    }

    /// Called when channels load. Hydrates in-memory favorites from fresh item data.
    func register(items: [ChannelDisplayItem]) {
        let filtered = items.filter { favoriteIDs.contains($0.id) }
        let orderedIDs = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        // `uniquingKeysWith: { first, _ in first }` so a corrupted
        // saved order array (duplicate IDs from a reorder race or
        // older bad write) sorts deterministically instead of
        // crashing. First occurrence's index wins.
        let orderIndex = Dictionary(orderedIDs.enumerated().map { ($1, $0) },
                                    uniquingKeysWith: { first, _ in first })
        favoriteItems = filtered.sorted { (a, b) in
            // Items present in the saved order honor that order. Anything not
            // yet ordered (newly favorited on another device, or pre-existing
            // favorites from before this feature shipped) falls through to a
            // stable alphabetical tail so the list isn't randomly shuffled.
            let ai = orderIndex[a.id]
            let bi = orderIndex[b.id]
            switch (ai, bi) {
            case let (a?, b?):
                return a < b
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        // Refresh the persisted order so the next launch sees the merged list
        // (any newly-arrived favorite IDs are now appended in alphabetical
        // order, while previously-ordered IDs keep their position).
        persistOrder()
        syncToSharedDefaults()
    }

    /// Writes the current ordered favorite IDs to UserDefaults under
    /// `favoriteOrder`. SyncManager mirrors this key to iCloud KVS so
    /// the manual order syncs across devices.
    private func persistOrder() {
        let orderedIDs = favoriteItems.map { $0.id }
        UserDefaults.standard.set(orderedIDs, forKey: Self.orderKey)
    }

    /// Writes favorite channel info to shared storage for the Top Shelf
    /// extension. Uses `TopShelfKeychain` (same as `topChannels` and
    /// `continueWatching`) rather than `UserDefaults(suiteName:)` because
    /// the tvOS sandbox denies app-group container writes with EPERM on
    /// this project, which also triggered a noisy CFPrefsPlistSource
    /// cfprefsd warning on launch.
    private func syncToSharedDefaults() {
        #if os(tvOS)
        let entries: [[String: String]] = favoriteItems.map { item in
            var entry: [String: String] = [
                "id": item.id,
                "name": item.name,
                "number": item.number
            ]
            if let logo = item.logoURL?.absoluteString { entry["logoURL"] = logo }
            return entry
        }
        TopShelfKeychain.write(array: entries, key: "favorites")
        #endif
    }
}

// MARK: - Channel Collections (issue #45)
//
// User-created, named groupings of channels — like Favorites, but you can
// have many of them and rename them. Built on the same lightweight
// UserDefaults persistence as `FavoritesStore` (no SwiftData): each
// collection is just a name + an ordered list of channel IDs, and the whole
// array is JSON-encoded under one key. Device-local for v1 (not yet mirrored
// to iCloud KVS); collections surface as filter pills in Live TV alongside
// All / Favorites / server groups.

/// One named collection: a stable id, a user-editable name, and an ordered
/// set of member channel IDs (the same `ChannelDisplayItem.id` Favorites uses).
struct ChannelCollection: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    /// Ordered for a stable display order; membership tests use `contains`.
    var memberIDs: [String]

    init(id: String = UUID().uuidString, name: String, memberIDs: [String] = []) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
    }
}

@MainActor
final class ChannelCollectionsStore: ObservableObject {
    static let shared = ChannelCollectionsStore()

    @Published private(set) var collections: [ChannelCollection] = []

    private static let storageKey = "channelCollections"

    init() { load() }

    var isEmpty: Bool { collections.isEmpty }

    func collection(id: String) -> ChannelCollection? {
        collections.first { $0.id == id }
    }

    /// Members of a collection resolved against the current channel list,
    /// in the collection's stored order. Unknown IDs (channels not in the
    /// active server) are dropped, mirroring how Favorites filters.
    func items(in collectionID: String, from allItems: [ChannelDisplayItem]) -> [ChannelDisplayItem] {
        guard let c = collection(id: collectionID) else { return [] }
        let byID = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return c.memberIDs.compactMap { byID[$0] }
    }

    func contains(channelID: String, in collectionID: String) -> Bool {
        collection(id: collectionID)?.memberIDs.contains(channelID) ?? false
    }

    // MARK: Mutations (each persists immediately)

    @discardableResult
    func create(name: String, memberIDs: [String] = []) -> ChannelCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = ChannelCollection(name: trimmed.isEmpty ? "New Collection" : trimmed,
                                           memberIDs: memberIDs)
        collections.append(collection)
        persist()
        return collection
    }

    func rename(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].name = trimmed
        persist()
    }

    func delete(id: String) {
        collections.removeAll { $0.id == id }
        persist()
    }

    /// Add or remove a channel from a collection (the per-channel toggle the
    /// "Add to Collection" menu drives).
    func toggleMember(channelID: String, in collectionID: String) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if let m = collections[i].memberIDs.firstIndex(of: channelID) {
            collections[i].memberIDs.remove(at: m)
        } else {
            collections[i].memberIDs.append(channelID)
        }
        persist()
    }

    /// Reorder the collections themselves (Manage Collections drag/d-pad move).
    func moveCollections(fromOffsets source: IndexSet, toOffset destination: Int) {
        collections.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Reorder members within a collection.
    func moveMembers(in collectionID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let i = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[i].memberIDs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ChannelCollection].self, from: data) else { return }
        collections = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
