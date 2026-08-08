import Foundation

/// Pure row computation for the Movies & TV Home section.
///
/// Deliberately free of SwiftUI, SwiftData, and networking: every input is a
/// plain snapshot struct, so the whole Home layout is unit-testable without a
/// ModelContainer or a live server. `MediaHomeView` maps its `@Query` results
/// into these snapshots and renders whatever comes back.
///
/// Row order (dossier section 5.3), each row hidden when it would be empty:
///   1. Continue Watching  (in-progress movies + in-progress episodes merged,
///                          deduped per series, sorted by last activity)
///   2. Recently Added, one row per PERSONAL library
///   3. Recently Added, one row per provider catalog
enum HomeRowsBuilder {

    // MARK: - Inputs

    /// A watch-progress row reduced to what Home needs. Mapping from the
    /// SwiftData `WatchProgress` model happens at the call site so this file
    /// stays free of the persistence layer.
    struct ProgressSnapshot: Hashable {
        let videoID: String
        /// "movie" or "episode".
        let vodType: String
        /// Parent show identifier for episodes; nil for movies.
        let seriesID: String?
        let positionMs: Int32
        let durationMs: Int32
        let isFinished: Bool
        let updatedAt: Date

        init(videoID: String,
             vodType: String,
             seriesID: String?,
             positionMs: Int32,
             durationMs: Int32,
             isFinished: Bool,
             updatedAt: Date) {
            self.videoID = videoID
            self.vodType = vodType
            self.seriesID = seriesID
            self.positionMs = positionMs
            self.durationMs = durationMs
            self.isFinished = isFinished
            self.updatedAt = updatedAt
        }
    }

    /// A catalog item plus the library facts Home groups on.
    struct CatalogSnapshot {
        let item: VODDisplayItem
        let libraryKey: String
        let libraryDisplayName: String
        let isPersonalLibrary: Bool
        /// Server-reported add time. Items without one sort last within their
        /// row rather than being dropped: a missing timestamp is a metadata
        /// gap, not a reason to hide content the user owns.
        let createdAt: Date?
    }

    // MARK: - Outputs

    struct Shelf: Identifiable {
        let id: String
        let title: String
        let isPersonalLibrary: Bool
        let items: [VODDisplayItem]
    }

    struct Rows {
        /// Video IDs in Continue Watching order. The view resolves each back to
        /// its live WatchProgress row for playback, so this carries identity
        /// only and can never go stale against the store.
        let continueWatching: [String]
        let shelves: [Shelf]

        var isEmpty: Bool { continueWatching.isEmpty && shelves.isEmpty }
    }

    // MARK: - Build

    /// Default shelf depth. Deep enough to feel like a library, shallow enough
    /// that a 17k-item catalog still paints one screen of posters per row.
    static let defaultShelfLimit = 20

    static func build(progress: [ProgressSnapshot],
                      catalog: [CatalogSnapshot],
                      shelfLimit: Int = defaultShelfLimit) -> Rows {
        Rows(
            continueWatching: continueWatching(from: progress),
            shelves: recentlyAddedShelves(from: catalog, limit: shelfLimit)
        )
    }

    // MARK: - Continue Watching

    /// Merges in-progress movies and episodes into one ordered list.
    ///
    /// Two rules carry the weight:
    ///   - **Deduped per series.** A show that the user is midway through
    ///     appears exactly once, represented by its most recently touched
    ///     episode. Without this, binge-watching a season floods the row and
    ///     pushes every other title off screen. Movies are never deduped
    ///     against each other; they have no parent to collapse into.
    ///   - **Sorted by last activity**, newest first, across both types, so the
    ///     thing the user last watched is always the first card.
    ///
    /// Finished rows are excluded here as well as in the caller's query, since
    /// this function is also the one the tests exercise.
    static func continueWatching(from progress: [ProgressSnapshot]) -> [String] {
        let live = progress.filter { !$0.isFinished && $0.positionMs > 0 }
        let ordered = live.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            // Deterministic tie-break so the row never reshuffles between
            // renders when two rows share a timestamp (a sync import writes
            // many rows with the same updatedAt).
            return lhs.videoID < rhs.videoID
        }

        var seenSeries = Set<String>()
        var result: [String] = []
        result.reserveCapacity(ordered.count)

        for row in ordered {
            if row.vodType == "episode",
               let seriesID = row.seriesID,
               !seriesID.isEmpty {
                // Already ordered newest-first, so the first episode seen for a
                // show IS its most recent one.
                guard seenSeries.insert(seriesID).inserted else { continue }
            }
            result.append(row.videoID)
        }
        return result
    }

    // MARK: - Recently Added

    /// One shelf per library, personal libraries first.
    ///
    /// Within each group libraries are ordered by name so the Home layout is
    /// stable across launches: a set-iteration order would reshuffle rows every
    /// cold start, which reads as a bug even though the content is identical.
    static func recentlyAddedShelves(from catalog: [CatalogSnapshot],
                                     limit: Int = defaultShelfLimit) -> [Shelf] {
        guard limit > 0 else { return [] }

        var grouped: [String: [CatalogSnapshot]] = [:]
        for entry in catalog {
            grouped[entry.libraryKey, default: []].append(entry)
        }

        let shelves: [Shelf] = grouped.compactMap { key, entries in
            guard let first = entries.first else { return nil }
            let items = entries
                .sorted { lhs, rhs in
                    switch (lhs.createdAt, rhs.createdAt) {
                    case let (l?, r?):
                        if l != r { return l > r }
                    case (nil, _?):
                        return false        // undated sorts after dated
                    case (_?, nil):
                        return true
                    case (nil, nil):
                        break
                    }
                    return lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
                }
                .prefix(limit)
                .map(\.item)

            guard !items.isEmpty else { return nil }
            return Shelf(
                id: key,
                title: first.libraryDisplayName,
                isPersonalLibrary: first.isPersonalLibrary,
                items: Array(items)
            )
        }

        return shelves.sorted { lhs, rhs in
            if lhs.isPersonalLibrary != rhs.isPersonalLibrary {
                return lhs.isPersonalLibrary        // personal libraries first
            }
            let byName = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
