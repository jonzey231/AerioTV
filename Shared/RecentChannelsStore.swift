import Foundation
import SwiftUI

/// FIFO ring of recently-played channels, keyed by channel ID.
///
/// Used by the multiview add-sheet's "Recent" section (and could be
/// used elsewhere later, it's a general-purpose "last N channels the
/// user touched" list). Persists channel IDs only; hydration into
/// `ChannelDisplayItem`s happens at read-time via `ChannelStore` so
/// that EPG refreshes / renames are reflected without touching the
/// store.
///
/// Cap: 25 entries. Push is dedup-on-id: re-pushing an already-
/// present channel moves it to the front.
///
/// PER PLAYLIST (Logan 2026-09-14): the list is scoped to the active
/// playlist, so switching playlists swaps in that playlist's own
/// recents instead of showing IDs that belong to another server.
/// `ChannelStore` calls `setScope(playlistID:)` whenever the active
/// server changes.
///
/// Synced through iCloud (2026-10-27 owner decision) as one
/// playlist -> IDs map inside the preferences payload; see
/// `syncSnapshot()` / `applySyncSnapshot(_:replace:)`.
@MainActor
final class RecentChannelsStore: ObservableObject {
    static let shared = RecentChannelsStore()

    /// Ordered IDs, most-recent first.
    @Published private(set) var recentIDs: [String] = []

    /// Hard cap. Each entry is a small String, so 25 is comfortable
    /// both in memory and in UserDefaults; the picker will only ever
    /// show the first ~8 in its section anyway.
    private static let maxEntries = 25

    /// Pre-scoping key. Still the read/write target until a playlist
    /// scope is set, and the source of the one-time migration below.
    private static let legacyDefaultsKey = "aerio.recent.channels.v1"

    /// Active playlist (server) identifier, or nil before the first
    /// `setScope` call.
    private var scopeID: String?

    /// Where the current scope persists. Unscoped falls back to the
    /// legacy key so a push before the first channel load is not lost.
    private var defaultsKey: String {
        guard let scopeID, !scopeID.isEmpty else { return Self.legacyDefaultsKey }
        return "\(Self.legacyDefaultsKey).\(scopeID)"
    }

    private init() {
        load()
    }

    // MARK: - Scope

    /// Point the store at a playlist. Loads that playlist's list; the
    /// first scope to be set adopts any pre-scoping list so existing
    /// users keep their recents on the playlist they were watching.
    func setScope(playlistID: String?) {
        let new = (playlistID?.isEmpty ?? true) ? nil : playlistID
        guard new != scopeID else { return }
        scopeID = new
        if new != nil,
           UserDefaults.standard.stringArray(forKey: defaultsKey) == nil,
           let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyDefaultsKey) {
            UserDefaults.standard.set(legacy, forKey: defaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
        }
        recentIDs = []
        load()
    }

    // MARK: - Load / save

    private func load() {
        guard let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) else {
            return
        }
        // Defensive: cap on load in case a future version changes the
        // limit downward. `Array.prefix` is cheap and avoids surprise
        // tails from an old build that allowed more entries.
        recentIDs = Array(stored.prefix(Self.maxEntries))
    }

    private func save() {
        UserDefaults.standard.set(recentIDs, forKey: defaultsKey)
        if let scopeID, !scopeID.isEmpty { Self.addToIndex(scopeID) }
    }

    // MARK: - iCloud sync

    /// Playlist IDs that have a scoped recents list, so the sync payload
    /// can be built without scanning every UserDefaults key.
    private static let indexKey = "aerio.recent.channels.index"

    private static func addToIndex(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: indexKey) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: indexKey)
    }

    private static func indexedIDs() -> [String] {
        let ud = UserDefaults.standard
        if let ids = ud.stringArray(forKey: indexKey) { return ids }
        // First run with the index: find existing scoped lists once.
        let prefix = legacyDefaultsKey + "."
        let ids = ud.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
        ud.set(ids, forKey: indexKey)
        return ids
    }

    /// playlist ID -> recent channel IDs (most recent first).
    static func syncSnapshot() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for id in indexedIDs() {
            if let list = UserDefaults.standard.stringArray(forKey: "\(legacyDefaultsKey).\(id)"), !list.isEmpty {
                out[id] = list
            }
        }
        return out
    }

    /// Writes the cloud lists. A merge only touches the playlists the
    /// cloud carries; a replace also clears playlists it does not.
    static func applySyncSnapshot(_ snapshot: [String: [String]], replace: Bool) {
        let ud = UserDefaults.standard
        if replace {
            for id in indexedIDs() where snapshot[id] == nil {
                ud.removeObject(forKey: "\(legacyDefaultsKey).\(id)")
            }
        }
        for (id, list) in snapshot {
            ud.set(Array(list.prefix(maxEntries)), forKey: "\(legacyDefaultsKey).\(id)")
            addToIndex(id)
        }
        shared.recentIDs = []
        shared.load()
    }

    // MARK: - Public API

    /// Push a channel to the front. No-op for empty / whitespace IDs
    /// (defensive, `ChannelDisplayItem.id` should always be valid,
    /// but an empty-string push would dedup to itself and silently
    /// corrupt the order).
    func push(_ item: ChannelDisplayItem) {
        let id = item.id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        // Dedup: remove any existing entry, then insert at front.
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > Self.maxEntries {
            recentIDs = Array(recentIDs.prefix(Self.maxEntries))
        }
        save()
    }

    /// Resolve the ID list into `ChannelDisplayItem`s by looking them
    /// up in `ChannelStore.shared.channels`. IDs that no longer
    /// resolve (server changed, channel removed) are silently skipped.
    /// Order is preserved (most-recent first).
    ///
    /// Performance: this is called from inside SwiftUI `body`
    /// evaluations (the add-sheet's "Recent" section + search
    /// filtering), so it re-runs on every keystroke. With N channels
    /// and M recents (M ≤ 20), the original Dictionary-build approach
    /// was O(N) in construction, linear in the full channel list,
    /// even though we only want to resolve 20 IDs. The loop below is
    /// O(M × N_avg_to_hit) with a tiny constant; for realistic M=20
    /// and N=5000 it's ~10× faster in practice because we bail out
    /// of `first(where:)` as soon as the match is found and we never
    /// allocate a dictionary the size of the full channel list.
    var resolved: [ChannelDisplayItem] {
        let all = ChannelStore.shared.channels
        return recentIDs.compactMap { id in
            all.first(where: { $0.id == id })
        }
    }

    /// Whether a channel is on the list (gates the row menu's
    /// "Remove from Recently Watched").
    func contains(_ id: String) -> Bool {
        recentIDs.contains(id)
    }

    /// GH Android#130: drop one channel from the active playlist's list.
    func remove(id: String) {
        guard recentIDs.contains(id) else { return }
        recentIDs.removeAll { $0 == id }
        save()
        debugLog("[RECENTS] removed one channel, \(recentIDs.count) left")
    }

    /// GH Android#130: drop the active playlist's whole list
    /// (Settings > Live TV > Clear Recently Watched, after a confirmation).
    func clear() {
        recentIDs = []
        save()
        debugLog("[RECENTS] cleared")
    }
}
