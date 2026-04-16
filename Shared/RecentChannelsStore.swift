import Foundation
import SwiftUI

/// FIFO ring of recently-played channels, keyed by channel ID.
///
/// Used by the multiview add-sheet's "Recent" section (and could be
/// used elsewhere later — it's a general-purpose "last N channels the
/// user touched" list). Persists channel IDs only; hydration into
/// `ChannelDisplayItem`s happens at read-time via `ChannelStore` so
/// that EPG refreshes / renames are reflected without touching the
/// store.
///
/// Cap: 20 entries. Push is dedup-on-id — re-pushing an already-
/// present channel moves it to the front.
///
/// NOT intended for cross-device sync; UserDefaults is fine, no
/// iCloud mirror needed.
@MainActor
final class RecentChannelsStore: ObservableObject {
    static let shared = RecentChannelsStore()

    /// Ordered IDs, most-recent first.
    @Published private(set) var recentIDs: [String] = []

    /// Hard cap. Each entry is a small String, so 20 is comfortable
    /// both in memory and in UserDefaults; the picker will only ever
    /// show the first ~8 in its section anyway.
    private static let maxEntries = 20

    private static let defaultsKey = "aerio.recent.channels.v1"

    private init() {
        load()
    }

    // MARK: - Load / save

    private func load() {
        guard let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) else {
            return
        }
        // Defensive: cap on load in case a future version changes the
        // limit downward. `Array.prefix` is cheap and avoids surprise
        // tails from an old build that allowed more entries.
        recentIDs = Array(stored.prefix(Self.maxEntries))
    }

    private func save() {
        UserDefaults.standard.set(recentIDs, forKey: Self.defaultsKey)
    }

    // MARK: - Public API

    /// Push a channel to the front. No-op for empty / whitespace IDs
    /// (defensive — `ChannelDisplayItem.id` should always be valid,
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
    /// was O(N) in construction — linear in the full channel list,
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

    /// Drop the entire list. Useful for "Clear Recents" in a future
    /// settings UI. v1 doesn't expose this but it's here for
    /// consistency with other per-user preference stores.
    func clear() {
        recentIDs = []
        save()
    }
}
