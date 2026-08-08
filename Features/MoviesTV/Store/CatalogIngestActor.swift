import Foundation
import SwiftData

/// Writes fetched catalog data into the MediaCatalog store OFF the main actor.
///
/// Two invariants make this safe on tvOS, where the same workload previously
/// drove AttributeGraph aborts:
///
///  1. Every insert happens on this actor's own context, in the MediaCatalog
///     container. No @Query in the app observes that container's synced twin,
///     so bulk writes cannot invalidate unrelated views.
///  2. The only thing the UI observes is `MediaCatalogSignal.generation`, and
///     it advances at most once every `publishInterval` seconds no matter how
///     many batches land. Views re-run their FetchDescriptors on that tick,
///     which replaces the old "assign a 17,000-element @Published array"
///     pattern entirely.
@ModelActor
actor CatalogIngestActor {

    /// Rows per save. Large enough that a 17k library is ~34 saves, small
    /// enough that a single save never blocks for long.
    private static let batchSize = 500

    // MARK: - Movies

    /// Upsert a fetched movie list for one server. Returns the number of rows
    /// written. Existing rows are updated in place so watch-progress joins and
    /// SwiftData identity stay stable across refreshes.
    func ingestMovies(_ movies: [VODMovie],
                      serverID: String,
                      libraryByCategory: [String: LibraryDeriver.Library]) async throws -> Int {
        let now = Date()
        var existing = try existingMovieIndex(serverID: serverID)
        var written = 0

        for chunk in movies.chunked(into: Self.batchSize) {
            for m in chunk {
                let library = libraryByCategory[m.categoryName]
                if let row = existing[m.id] {
                    apply(m, to: row, library: library, seenAt: now)
                } else {
                    let row = CachedVODMovie(serverID: serverID, sourceItemID: m.id, title: m.name)
                    apply(m, to: row, library: library, seenAt: now)
                    modelContext.insert(row)
                    existing[m.id] = row
                }
                written += 1
            }
            try modelContext.save()
            await MainActor.run { MediaCatalogSignal.shared.noteBatchWritten() }
        }
        return written
    }

    private func apply(_ m: VODMovie,
                       to row: CachedVODMovie,
                       library: LibraryDeriver.Library?,
                       seenAt: Date) {
        row.title = m.name
        row.sortTitle = MediaSortTitle.make(from: m.name)
        row.posterURLString = m.posterURL?.absoluteString
        row.plot = m.plot
        row.genre = m.genre
        row.rating = m.rating
        row.releaseDate = m.releaseDate
        row.durationText = m.duration
        row.categoryID = m.categoryID
        row.categoryName = m.categoryName
        row.containerExtension = m.containerExtension
        row.tmdbID = m.tmdbID
        row.imdbID = m.imdbID
        row.youtubeTrailer = m.youtubeTrailer
        row.country = m.country
        row.director = m.director
        row.castList = m.cast
        row.libraryKey = library?.key ?? ""
        row.isPersonalLibrary = library?.isPersonal ?? false
        row.lastSeenAt = seenAt
    }

    // MARK: - Series

    func ingestSeries(_ series: [VODSeries],
                      serverID: String,
                      libraryByCategory: [String: LibraryDeriver.Library]) async throws -> Int {
        let now = Date()
        var existing = try existingSeriesIndex(serverID: serverID)
        var written = 0

        for chunk in series.chunked(into: Self.batchSize) {
            for s in chunk {
                let library = libraryByCategory[s.categoryName]
                let row = existing[s.id] ?? {
                    let fresh = CachedVODSeries(serverID: serverID, sourceItemID: s.id, title: s.name)
                    modelContext.insert(fresh)
                    existing[s.id] = fresh
                    return fresh
                }()
                row.title = s.name
                row.sortTitle = MediaSortTitle.make(from: s.name)
                row.posterURLString = s.posterURL?.absoluteString
                row.plot = s.plot
                row.genre = s.genre
                row.rating = s.rating
                row.releaseDate = s.releaseDate
                row.categoryID = s.categoryID
                row.categoryName = s.categoryName
                row.director = s.director
                row.castList = s.cast
                row.episodeCount = s.episodeCount
                row.libraryKey = library?.key ?? ""
                row.isPersonalLibrary = library?.isPersonal ?? false
                row.lastSeenAt = now
                written += 1
            }
            try modelContext.save()
            await MainActor.run { MediaCatalogSignal.shared.noteBatchWritten() }
        }
        return written
    }

    // MARK: - Categories

    func ingestCategories(_ categories: [VODCategory],
                          serverID: String,
                          categoryType: String,
                          libraries: [String: LibraryDeriver.Library]) throws {
        let now = Date()
        let descriptor = FetchDescriptor<CachedVODCategory>(
            predicate: #Predicate { $0.serverID == serverID && $0.categoryType == categoryType }
        )
        var existing: [String: CachedVODCategory] = [:]
        for row in try modelContext.fetch(descriptor) { existing[row.sourceCategoryID] = row }

        for c in categories {
            let library = libraries[c.name]
            let row = existing[c.id] ?? {
                let fresh = CachedVODCategory(serverID: serverID, sourceCategoryID: c.id,
                                              name: c.name, categoryType: categoryType)
                modelContext.insert(fresh)
                return fresh
            }()
            row.name = c.name
            row.itemCount = c.itemCount
            row.libraryKey = library?.key ?? ""
            row.librarySourceName = library?.sourceName ?? ""
            row.libraryName = library?.libraryName ?? c.name
            row.isPersonalLibrary = library?.isPersonal ?? false
            row.lastSeenAt = now
        }
        try modelContext.save()
    }

    // MARK: - Reconciliation

    /// Delete rows this server did not return during a completed full sweep.
    /// Only ever called after a sweep that finished, so an interrupted sync can
    /// never mistake "not fetched yet" for "deleted upstream".
    func pruneMovies(serverID: String, notSeenSince cutoff: Date) throws -> Int {
        let descriptor = FetchDescriptor<CachedVODMovie>(
            predicate: #Predicate { $0.serverID == serverID && $0.lastSeenAt < cutoff }
        )
        let stale = try modelContext.fetch(descriptor)
        stale.forEach { modelContext.delete($0) }
        if !stale.isEmpty { try modelContext.save() }
        return stale.count
    }

    func pruneSeries(serverID: String, notSeenSince cutoff: Date) throws -> Int {
        let descriptor = FetchDescriptor<CachedVODSeries>(
            predicate: #Predicate { $0.serverID == serverID && $0.lastSeenAt < cutoff }
        )
        let stale = try modelContext.fetch(descriptor)
        stale.forEach { modelContext.delete($0) }
        if !stale.isEmpty { try modelContext.save() }
        return stale.count
    }

    /// Drop everything belonging to a server (playlist deleted in Settings).
    /// Mirrors the cascade the pre-catalog `VODStore.clear()` path gave us.
    func deleteServer(_ serverID: String) throws {
        try modelContext.delete(model: CachedVODMovie.self,
                                where: #Predicate { $0.serverID == serverID })
        try modelContext.delete(model: CachedVODSeries.self,
                                where: #Predicate { $0.serverID == serverID })
        try modelContext.delete(model: CachedVODEpisode.self,
                                where: #Predicate { $0.serverID == serverID })
        try modelContext.delete(model: CachedVODCategory.self,
                                where: #Predicate { $0.serverID == serverID })
        try modelContext.delete(model: CatalogSyncState.self,
                                where: #Predicate { $0.serverID == serverID })
        try modelContext.save()
    }

    // MARK: - Sync state

    func syncState(serverID: String, mediaType: String) throws -> (localCount: Int, completed: Bool) {
        let state = try fetchOrCreateState(serverID: serverID, mediaType: mediaType)
        return (state.localCount, state.completedInitialSync)
    }

    func markSyncStarted(serverID: String, mediaType: String) throws {
        let state = try fetchOrCreateState(serverID: serverID, mediaType: mediaType)
        state.isSyncing = true
        try modelContext.save()
    }

    func markSyncFinished(serverID: String, mediaType: String, localCount: Int, full: Bool) throws {
        let state = try fetchOrCreateState(serverID: serverID, mediaType: mediaType)
        state.isSyncing = false
        state.localCount = localCount
        if full {
            state.lastFullSyncAt = Date()
            state.completedInitialSync = true
        }
        state.lastDeltaSyncAt = Date()
        try modelContext.save()
    }

    private func fetchOrCreateState(serverID: String, mediaType: String) throws -> CatalogSyncState {
        let descriptor = FetchDescriptor<CatalogSyncState>(
            predicate: #Predicate { $0.serverID == serverID && $0.mediaType == mediaType }
        )
        if let existing = try modelContext.fetch(descriptor).first { return existing }
        let fresh = CatalogSyncState(serverID: serverID, mediaType: mediaType)
        modelContext.insert(fresh)
        return fresh
    }

    // MARK: - Indexes

    private func existingMovieIndex(serverID: String) throws -> [String: CachedVODMovie] {
        let descriptor = FetchDescriptor<CachedVODMovie>(
            predicate: #Predicate { $0.serverID == serverID }
        )
        var index: [String: CachedVODMovie] = [:]
        for row in try modelContext.fetch(descriptor) { index[row.sourceItemID] = row }
        return index
    }

    private func existingSeriesIndex(serverID: String) throws -> [String: CachedVODSeries] {
        let descriptor = FetchDescriptor<CachedVODSeries>(
            predicate: #Predicate { $0.serverID == serverID }
        )
        var index: [String: CachedVODSeries] = [:]
        for row in try modelContext.fetch(descriptor) { index[row.sourceItemID] = row }
        return index
    }
}

/// The ONE thing views observe about the catalog: a generation counter that
/// ticks at most every `publishInterval` seconds regardless of ingest volume.
///
/// This is the direct descendant of the publish batching VODStore needed to
/// keep tvOS out of AttributeGraph aborts, kept at the same cadence. In DEBUG
/// an assertion fires if the interval is ever violated, so a future refactor
/// cannot quietly reintroduce a per-batch publish storm.
@MainActor
final class MediaCatalogSignal: ObservableObject {
    static let shared = MediaCatalogSignal()

    static let publishInterval: TimeInterval = 2.0

    /// Bumped when new catalog data may be visible. Views key FetchDescriptor
    /// re-runs off this.
    @Published private(set) var generation: Int = 0
    /// True while any server is ingesting, for the thin "Syncing library" hint.
    @Published private(set) var isSyncing: Bool = false

    private var pendingPublish = false
    private var lastPublish: Date = .distantPast

    private init() {}

    /// Called from the ingest actor after each batch save.
    func noteBatchWritten() {
        guard !pendingPublish else { return }
        let elapsed = Date().timeIntervalSince(lastPublish)
        if elapsed >= Self.publishInterval {
            publishNow()
        } else {
            pendingPublish = true
            let delay = Self.publishInterval - elapsed
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                self.pendingPublish = false
                self.publishNow()
            }
        }
    }

    private func publishNow() {
        #if DEBUG
        let since = Date().timeIntervalSince(lastPublish)
        assert(since >= Self.publishInterval - 0.1 || generation == 0,
               "MediaCatalogSignal published \(since)s apart; the 2s floor exists to keep tvOS out of AttributeGraph aborts")
        #endif
        lastPublish = Date()
        generation &+= 1
    }

    func setSyncing(_ syncing: Bool) {
        guard isSyncing != syncing else { return }
        isSyncing = syncing
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
