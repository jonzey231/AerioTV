import Foundation
import SwiftData

/// Owns the "MediaCatalog" ModelContainer: a disposable, on-disk mirror of the
/// VOD catalog kept deliberately APART from the app's synced container.
///
/// Isolation is the whole point. Catalog ingest writes tens of thousands of
/// rows, and a SwiftData save invalidates @Query observers across its entire
/// container. Sharing the synced store would re-fire every WatchProgress and
/// ServerConnection observer in the app on every ingest batch, which is exactly
/// the failure mode this project already pays for elsewhere (the 30s watch
/// progress save cadence, the VODStore publish batching that keeps tvOS out of
/// AttributeGraph aborts).
///
/// Because the store is pure cache, there is no migration path: a schema
/// version mismatch (or an unreadable store) deletes the files and rebuilds
/// from the server. Nothing user-owned lives here.
enum MediaCatalogContainer {

    private static let versionKey = "mediaCatalog.schemaVersion"

    /// Built once at first use. `nil` only if even a fresh rebuild fails, in
    /// which case callers fall back to live fetching (the pre-catalog path).
    static let shared: ModelContainer? = make()

    private static func make() -> ModelContainer? {
        let schema = Schema([
            CachedVODMovie.self,
            CachedVODSeries.self,
            CachedVODEpisode.self,
            CachedVODCategory.self,
            CatalogSyncState.self,
        ])
        let url = storeURL()
        let stored = UserDefaults.standard.integer(forKey: versionKey)
        if stored != MediaCatalogSchema.version {
            // Version bump (or first run): start clean rather than migrate.
            destroyStore(at: url)
            UserDefaults.standard.set(MediaCatalogSchema.version, forKey: versionKey)
        }

        let config = ModelConfiguration("MediaCatalog", schema: schema, url: url)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A corrupt or unreadable cache must never be fatal: wipe and retry
            // once, then give up and let callers fetch live.
            debugLog("[MediaCatalog] open failed (\(error.localizedDescription)); rebuilding")
            destroyStore(at: url)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                debugLog("[MediaCatalog] rebuild FAILED: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static func storeURL() -> URL {
        // Application Support, not Documents: this is regenerable cache the
        // user should never see in Files, and tvOS denies Documents writes.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("MediaCatalog.store")
    }

    /// Removes the store and its SQLite sidecars.
    private static func destroyStore(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let path = URL(fileURLWithPath: url.path + suffix)
            try? fm.removeItem(at: path)
        }
    }

    /// Drop everything and start over (Settings "clear cache", or a server
    /// list change large enough that a rebuild beats reconciliation).
    static func wipe() {
        destroyStore(at: storeURL())
        UserDefaults.standard.removeObject(forKey: versionKey)
    }
}
