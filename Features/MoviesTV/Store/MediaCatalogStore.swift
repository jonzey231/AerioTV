import Foundation
import SwiftData

/// Drives catalog refreshes: pick the adapter for each server, fetch, derive
/// libraries, hand everything to the ingest actor, reconcile deletions.
///
/// Deliberately thin and main-actor: all the expensive work happens inside the
/// adapters (network) and the ingest actor (disk). This type only sequences it
/// and owns the "is anything syncing" flag.
@MainActor
final class MediaCatalogStore {
    static let shared = MediaCatalogStore()

    private var ingest: CatalogIngestActor?
    /// One refresh per server at a time; a second request while one is in
    /// flight is dropped rather than queued (the next launch or pull-to-refresh
    /// will pick up anything missed).
    private var inFlight: Set<String> = []

    private init() {
        if let container = MediaCatalogContainer.shared {
            ingest = CatalogIngestActor(modelContainer: container)
        }
    }

    /// True when the catalog is unavailable (container failed to open), in
    /// which case callers must keep using the live-fetch path.
    var isAvailable: Bool { ingest != nil }

    // MARK: - Ingest already-fetched data

    /// Persist what VODStore JUST fetched, with no additional network calls.
    ///
    /// This is the orchestrator's path, and it exists because the obvious
    /// alternative is wrong: calling `refresh(server:)` after the VOD phases
    /// re-fetches the entire library a second time. On the real 4,787-movie /
    /// 2,437-series library that doubled the launch fetch and timed out
    /// (measured on the tvOS simulator, 2026-08-08). The data is already in
    /// memory and already correct, so the catalog just mirrors it.
    ///
    /// Items are grouped by their own serverID, so a multi-server setup lands
    /// in the right per-server rows even though VODStore aggregates them.
    /// Categories are derived from the grouped items rather than VODStore's
    /// global category list, which would otherwise leak one server's category
    /// names onto another.
    func ingestFetched(movies: [VODDisplayItem], series: [VODDisplayItem]) async {
        guard let ingest else { return }
        guard !movies.isEmpty || !series.isEmpty else {
            // Say so explicitly. Silence here is indistinguishable from "the
            // catalog never ran", which cost a diagnosis cycle when the VOD
            // fetch itself failed upstream and left both arrays empty.
            debugLog("[MediaCatalog] nothing to mirror (VOD fetch returned no items)")
            return
        }
        MediaCatalogSignal.shared.setSyncing(true)
        defer { if inFlight.isEmpty { MediaCatalogSignal.shared.setSyncing(false) } }

        let moviesByServer = Dictionary(grouping: movies.compactMap(\.movie), by: { $0.serverID })
        for (serverID, group) in moviesByServer {
            let key = serverID.uuidString
            let libraries = librariesFromItems(group.map(\.categoryName), type: "movie", serverID: key)
            do {
                let count = try await ingest.ingestMovies(group, serverID: key,
                                                          libraryByCategory: libraries)
                try await ingest.markSyncFinished(serverID: key, mediaType: "movie",
                                                  localCount: count, full: true)
                debugLog("[MediaCatalog] mirrored \(count) movies for server \(key.prefix(8))")
            } catch {
                debugLog("[MediaCatalog] movie mirror failed: \(error.localizedDescription)")
            }
        }

        let seriesByServer = Dictionary(grouping: series.compactMap(\.series), by: { $0.serverID })
        for (serverID, group) in seriesByServer {
            let key = serverID.uuidString
            let libraries = librariesFromItems(group.map(\.categoryName), type: "series", serverID: key)
            do {
                let count = try await ingest.ingestSeries(group, serverID: key,
                                                          libraryByCategory: libraries)
                try await ingest.markSyncFinished(serverID: key, mediaType: "series",
                                                  localCount: count, full: true)
                debugLog("[MediaCatalog] mirrored \(count) series for server \(key.prefix(8))")
            } catch {
                debugLog("[MediaCatalog] series mirror failed: \(error.localizedDescription)")
            }
        }
    }

    private func librariesFromItems(_ categoryNames: [String],
                                    type: String,
                                    serverID: String) -> [String: LibraryDeriver.Library] {
        var map: [String: LibraryDeriver.Library] = [:]
        for name in Set(categoryNames) {
            map[name] = LibraryDeriver.parse(categoryName: name,
                                             categoryType: type,
                                             serverID: serverID,
                                             isPersonal: false)
        }
        return map
    }

    // MARK: - Refresh

    /// Refresh one server's movies and series into the catalog.
    ///
    /// `full` runs deletion reconciliation afterwards; delta refreshes skip it
    /// because a partial view of the library must never be read as deletions.
    ///
    /// NOTE (A1): this ingests the adapters' complete fetch, which is what the
    /// existing VODService path produces. The newest-first incremental page
    /// walk described in the design (ordering=-created_at, stop when a page is
    /// fully known) lands with the browse UI in a later phase, where a
    /// half-filled catalog is actually visible to the user and the early stop
    /// pays for itself. The ingest side below is already written for it:
    /// upserts are keyed and idempotent, so partial walks are safe.
    func refresh(server: ServerSnapshot, full: Bool = true) async {
        guard let ingest, let adapter = VODSourceAdapterFactory.adapter(for: server) else { return }
        let serverKey = server.id.uuidString
        // Host only, never the full URL: base URLs can carry credentials.
        let serverLabel = URL(string: server.baseURL)?.host ?? "server"
        guard !inFlight.contains(serverKey) else { return }
        inFlight.insert(serverKey)
        MediaCatalogSignal.shared.setSyncing(true)
        defer {
            inFlight.remove(serverKey)
            if inFlight.isEmpty { MediaCatalogSignal.shared.setSyncing(false) }
        }

        let sweepStarted = Date()

        do {
            try await ingest.markSyncStarted(serverID: serverKey, mediaType: "movie")
            let (movies, movieCategories) = try await adapter.fetchMovies(from: server)
            let movieLibraries = libraries(for: movieCategories, type: "movie", serverID: serverKey)
            try await ingest.ingestCategories(movieCategories, serverID: serverKey,
                                              categoryType: "movie", libraries: movieLibraries)
            let movieCount = try await ingest.ingestMovies(movies, serverID: serverKey,
                                                           libraryByCategory: movieLibraries)
            try await ingest.markSyncFinished(serverID: serverKey, mediaType: "movie",
                                              localCount: movieCount, full: full)
            debugLog("[MediaCatalog] \(serverLabel): ingested \(movieCount) movies")
        } catch {
            debugLog("[MediaCatalog] \(serverLabel): movie ingest failed: \(error.localizedDescription)")
        }

        do {
            try await ingest.markSyncStarted(serverID: serverKey, mediaType: "series")
            let (series, seriesCategories) = try await adapter.fetchSeries(from: server)
            let seriesLibraries = libraries(for: seriesCategories, type: "series", serverID: serverKey)
            try await ingest.ingestCategories(seriesCategories, serverID: serverKey,
                                              categoryType: "series", libraries: seriesLibraries)
            let seriesCount = try await ingest.ingestSeries(series, serverID: serverKey,
                                                            libraryByCategory: seriesLibraries)
            try await ingest.markSyncFinished(serverID: serverKey, mediaType: "series",
                                              localCount: seriesCount, full: full)
            debugLog("[MediaCatalog] \(serverLabel): ingested \(seriesCount) series")
        } catch {
            debugLog("[MediaCatalog] \(serverLabel): series ingest failed: \(error.localizedDescription)")
        }

        // Reconcile deletions only after a sweep that actually completed.
        if full {
            do {
                let prunedMovies = try await ingest.pruneMovies(serverID: serverKey, notSeenSince: sweepStarted)
                let prunedSeries = try await ingest.pruneSeries(serverID: serverKey, notSeenSince: sweepStarted)
                if prunedMovies + prunedSeries > 0 {
                    debugLog("[MediaCatalog] \(serverLabel): pruned \(prunedMovies) movies / \(prunedSeries) series no longer on the server")
                }
            } catch {
                debugLog("[MediaCatalog] prune failed: \(error.localizedDescription)")
            }
        }
    }

    /// A playlist was deleted in Settings: drop its catalog rows so the cache
    /// cannot outlive the server it came from.
    func removeServer(_ serverID: UUID) async {
        guard let ingest else { return }
        do {
            try await ingest.deleteServer(serverID.uuidString)
            debugLog("[MediaCatalog] cleared catalog for removed server")
        } catch {
            debugLog("[MediaCatalog] clear failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Libraries

    /// Category name -> derived library. Personal-library detection needs the
    /// provider relation marker, which the current fetch path does not surface;
    /// until the marker plumbing lands with the media-library phase, categories
    /// derive as provider catalogs, which is exactly the stock-server behaviour
    /// and therefore correct today.
    private func libraries(for categories: [VODCategory],
                           type: String,
                           serverID: String) -> [String: LibraryDeriver.Library] {
        var map: [String: LibraryDeriver.Library] = [:]
        for c in categories {
            map[c.name] = LibraryDeriver.parse(categoryName: c.name,
                                               categoryType: type,
                                               serverID: serverID,
                                               isPersonal: false)
        }
        return map
    }
}
