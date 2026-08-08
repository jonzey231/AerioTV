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
