import Foundation
import SwiftData

// MARK: - Media catalog (Movies & TV)
//
// A DISPOSABLE, on-disk mirror of every VOD server's catalog, living in its
// own ModelContainer ("MediaCatalog") that is deliberately separate from the
// app's synced container (WatchProgress, ServerConnection, ...).
//
// Why a second container: bulk catalog ingest writes tens of thousands of rows,
// and every SwiftData save re-fires @Query observers across the WHOLE container.
// That is the documented cause of the app-wide invalidation storms this project
// already works around (the 30s watch-progress save cadence, the tvOS
// AttributeGraph batching in VODStore). Keeping the catalog in its own store
// means a 17k-row sync cannot touch a single synced-data observer, and the
// synced store is never migrated for catalog reasons.
//
// Because it is a pure cache, a schema change does not need a migration: bump
// `MediaCatalogSchema.version`, and the container is deleted and rebuilt from
// the server on next launch (see MediaCatalogContainer).

enum MediaCatalogSchema {
    /// Bump on ANY shape change below. A mismatch wipes and rebuilds the store.
    static let version = 1
}

/// A movie row. `sourceItemID` is the server's own id; uniqueness is
/// (serverID, sourceItemID), enforced in code the way WatchProgressManager
/// enforces (vodID, serverID) - SwiftData's @Attribute(.unique) is global and
/// would collide across servers that reuse numeric ids.
@Model
final class CachedVODMovie {
    var serverID: String = ""
    var sourceItemID: String = ""
    var title: String = ""
    /// Case-folded, article-stripped title. Precomputed so Title sort and the
    /// tvOS alpha-jump rail are pure index reads instead of per-row work.
    var sortTitle: String = ""
    var posterURLString: String?
    var plot: String = ""
    var genre: String = ""
    var rating: String = ""
    var releaseDate: String = ""
    var durationText: String = ""
    var categoryID: String = ""
    var categoryName: String = ""
    var containerExtension: String = ""
    var tmdbID: String = ""
    var imdbID: String = ""
    var youtubeTrailer: String = ""
    var country: String = ""
    var director: String = ""
    var castList: String = ""
    /// Server-side creation timestamp, the ordering key for Recently Added and
    /// for delta refresh (`ordering=-created_at`).
    var createdAt: Date?
    /// Library this item belongs to; see LibraryDeriver. Empty for provider
    /// catalogs, "{source} - {library}" style for personal libraries.
    var libraryKey: String = ""
    var isPersonalLibrary: Bool = false
    /// Refreshed on every sighting; drives deletion reconciliation sweeps.
    var lastSeenAt: Date = Date()

    init(serverID: String, sourceItemID: String, title: String) {
        self.serverID = serverID
        self.sourceItemID = sourceItemID
        self.title = title
        self.sortTitle = MediaSortTitle.make(from: title)
    }
}

@Model
final class CachedVODSeries {
    var serverID: String = ""
    var sourceItemID: String = ""
    var title: String = ""
    var sortTitle: String = ""
    var posterURLString: String?
    var plot: String = ""
    var genre: String = ""
    var rating: String = ""
    var releaseDate: String = ""
    var categoryID: String = ""
    var categoryName: String = ""
    var tmdbID: String = ""
    var director: String = ""
    var castList: String = ""
    var episodeCount: Int = 0
    var createdAt: Date?
    var libraryKey: String = ""
    var isPersonalLibrary: Bool = false
    var lastSeenAt: Date = Date()

    init(serverID: String, sourceItemID: String, title: String) {
        self.serverID = serverID
        self.sourceItemID = sourceItemID
        self.title = title
        self.sortTitle = MediaSortTitle.make(from: title)
    }
}

/// An episode. There is no seasons model on the server (only
/// `Episode.season_number`), so seasons are synthesized by grouping these.
@Model
final class CachedVODEpisode {
    var serverID: String = ""
    var sourceItemID: String = ""
    var seriesSourceID: String = ""
    var seasonNumber: Int = 0
    var episodeNumber: Int = 0
    var title: String = ""
    var plot: String = ""
    var airDate: String = ""
    var durationText: String = ""
    var stillURLString: String?
    var containerExtension: String = ""
    var lastSeenAt: Date = Date()

    init(serverID: String, sourceItemID: String, seriesSourceID: String) {
        self.serverID = serverID
        self.sourceItemID = sourceItemID
        self.seriesSourceID = seriesSourceID
    }
}

@Model
final class CachedVODCategory {
    var serverID: String = ""
    var sourceCategoryID: String = ""
    var name: String = ""
    /// "movie" or "series", matching the server's category_type.
    var categoryType: String = ""
    var itemCount: Int = 0
    /// Derived library facets (LibraryDeriver); empty for provider catalogs.
    var libraryKey: String = ""
    var librarySourceName: String = ""
    var libraryName: String = ""
    var isPersonalLibrary: Bool = false
    var lastSeenAt: Date = Date()

    init(serverID: String, sourceCategoryID: String, name: String, categoryType: String) {
        self.serverID = serverID
        self.sourceCategoryID = sourceCategoryID
        self.name = name
        self.categoryType = categoryType
    }
}

/// Per-server, per-type sync bookkeeping. Drives delta refresh (where the last
/// walk stopped), the "Syncing library" indicator, and the count-drift check
/// that triggers a deletion-reconciliation sweep.
@Model
final class CatalogSyncState {
    var serverID: String = ""
    /// "movie" or "series".
    var mediaType: String = ""
    var lastFullSyncAt: Date?
    var lastDeltaSyncAt: Date?
    var lastKnownServerCount: Int = 0
    var localCount: Int = 0
    var isSyncing: Bool = false
    /// Set when a walk is interrupted (app killed mid-sync) so the next launch
    /// knows the catalog is incomplete and keeps server-side search available.
    var completedInitialSync: Bool = false

    init(serverID: String, mediaType: String) {
        self.serverID = serverID
        self.mediaType = mediaType
    }
}

// MARK: - Sort title

enum MediaSortTitle {
    private static let leadingArticles = ["the ", "a ", "an "]

    /// Case-folded, diacritic-insensitive, leading-article-stripped form used
    /// for Title sort and for alpha-jump bucketing. Titles that start with a
    /// non-letter keep their first character so they bucket under "#".
    static func make(from title: String) -> String {
        var t = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for article in leadingArticles where t.hasPrefix(article) {
            t = String(t.dropFirst(article.count))
            break
        }
        return t
    }

    /// The A-Z bucket for the jump rail; everything non-alphabetic is "#".
    static func bucket(for sortTitle: String) -> String {
        guard let first = sortTitle.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}
