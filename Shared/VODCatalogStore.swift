import Foundation
import SQLite3

// MARK: - Paged VOD catalog (GH #109 Apple parity)
//
// The persisted Movies / TV Shows catalog. Replaces the in-memory
// `[VODDisplayItem]` arrays and the per-kind JSON snapshot: the sweep writes
// each page here as it arrives, the grids read windows of rows, and the
// filter plus sort run in SQL. Memory no longer grows with the catalog, so a
// 350,000 title Dispatcharr library browses on an Apple TV HD.
//
// Why SQLite and not SwiftData: the app's SwiftData container holds user
// data (servers, watch progress, watchlist, recordings) and is backed by a
// store that must migrate cleanly on every upgrade. The VOD catalog is a
// REBUILDABLE CACHE, it is written a page at a time from a background sweep,
// and it needs keyset paging, per-column indexes and an ordered id scan of
// hundreds of thousands of rows without materializing a single model object.
// SwiftData gives none of those cheaply (its fetch-offset paging re-runs the
// sort, and every row comes back as a managed object). A standalone SQLite
// file is disposable, needs no migration plan for the user's real data, and
// lands under `AppCacheDirectory` which on tvOS is Caches: Application
// Support is not writable there.
//
// Threading: every write and every query runs off the main actor through
// `work`, a serial queue. The one exception is `loadWindow`, which reads
// about 180 rows by primary key on the calling thread when a window is
// missed; `VODWindowList` prefetches ahead of the scroll so that path is
// rare (a rail jump, the first frame of a new list).
final class VODCatalogStore: @unchecked Sendable {

    static let shared = VODCatalogStore()

    static let windowSize = 180
    static let windowBehind = 60
    static let rowCacheLimit = 2_400
    /// SQLite's default host-parameter ceiling is 999.
    static let maxBind = 900
    static let searchLimit = 500

    private let work = DispatchQueue(label: "app.molinete.aerio.vodcatalog", qos: .utility)
    private let prefetchQueue = DispatchQueue(label: "app.molinete.aerio.vodcatalog.prefetch", qos: .utility)
    private let dbLock = NSRecursiveLock()
    private var db: OpaquePointer?
    private var didOpen = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Open

    private var fileURL: URL { AppCacheDirectory.url.appendingPathComponent("vod-catalog.sqlite") }

    /// Opens (and creates) the database. Safe to call from anywhere; the
    /// first call does the work, the rest return immediately.
    @discardableResult
    private func ensureOpen() -> OpaquePointer? {
        dbLock.lock()
        defer { dbLock.unlock() }
        if didOpen { return db }
        didOpen = true
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            debugLog("[VOD-CAT] could not open the catalog database at \(fileURL.lastPathComponent)")
            db = nil
            return nil
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA temp_store=MEMORY;")
        // Bounded page cache: the point of this store is flat memory, so the
        // database is not allowed to grow its own cache without limit.
        exec("PRAGMA cache_size=-4000;")
        createSchema()
        return db
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS vod_title (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            playlistKey TEXT NOT NULL,
            kind TEXT NOT NULL,
            itemKey TEXT NOT NULL,
            title TEXT NOT NULL,
            sortKey TEXT NOT NULL,
            bucket TEXT NOT NULL,
            year INTEGER,
            ratingValue REAL,
            addedAt REAL,
            category TEXT,
            tmdbId TEXT,
            normTitle TEXT NOT NULL,
            cleanTitle TEXT NOT NULL,
            searchText TEXT NOT NULL,
            payload BLOB NOT NULL,
            generation INTEGER NOT NULL
        );
        """)
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_vod_title_item ON vod_title(playlistKey, kind, itemKey);")
        exec("CREATE INDEX IF NOT EXISTS idx_vod_title_sort ON vod_title(playlistKey, kind, sortKey);")
        exec("CREATE INDEX IF NOT EXISTS idx_vod_title_gen ON vod_title(playlistKey, kind, generation);")
        exec("CREATE INDEX IF NOT EXISTS idx_vod_title_added ON vod_title(playlistKey, kind, addedAt);")
        exec("CREATE INDEX IF NOT EXISTS idx_vod_title_tmdb ON vod_title(playlistKey, kind, tmdbId);")
        exec("CREATE INDEX IF NOT EXISTS idx_vod_title_norm ON vod_title(playlistKey, kind, normTitle);")
        exec("CREATE INDEX IF NOT EXISTS idx_vod_title_clean ON vod_title(playlistKey, kind, cleanTitle);")
        exec("CREATE INDEX IF NOT EXISTS idx_vod_title_cat ON vod_title(playlistKey, kind, category);")
        exec("""
        CREATE TABLE IF NOT EXISTS vod_sweep_state (
            playlistKey TEXT NOT NULL,
            kind TEXT NOT NULL,
            generation INTEGER NOT NULL,
            open INTEGER NOT NULL,
            startedAt REAL NOT NULL,
            completedAt REAL,
            remoteCount INTEGER,
            remoteNewest TEXT,
            PRIMARY KEY (playlistKey, kind)
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS vod_sweep_lane (
            playlistKey TEXT NOT NULL,
            kind TEXT NOT NULL,
            lane TEXT NOT NULL,
            generation INTEGER NOT NULL,
            nextPage INTEGER NOT NULL,
            done INTEGER NOT NULL,
            PRIMARY KEY (playlistKey, kind, lane)
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS vod_category (
            playlistKey TEXT NOT NULL,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            catId TEXT NOT NULL,
            providerIDs TEXT NOT NULL,
            ord INTEGER NOT NULL,
            PRIMARY KEY (playlistKey, kind, name)
        );
        """)
    }

    // MARK: - Tiny SQLite helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            debugLog("[VOD-CAT] sql failed: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// One bound value. Kept as an enum so statements bind uniformly.
    enum Bound {
        case text(String)
        case int(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Bound]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s):   sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let n):    sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .blob(let d):   _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), Self.transient) }
            case .null:          sqlite3_bind_null(stmt, idx)
            }
        }
    }

    /// Prepare, bind, step to completion. For statements with no rows.
    @discardableResult
    private func run(_ sql: String, _ values: [Bound] = []) -> Int32 {
        guard let db else { return SQLITE_ERROR }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            debugLog("[VOD-CAT] prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return SQLITE_ERROR
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            debugLog("[VOD-CAT] step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return rc
    }

    /// Prepare, bind, and call `row` for every result row.
    private func query(_ sql: String, _ values: [Bound] = [], row: (OpaquePointer) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            debugLog("[VOD-CAT] prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }

    private func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    private func kindCode(_ kind: VODItemType) -> String { kind == .series ? "s" : "m" }

    /// Hops onto the catalog's serial queue. Every public entry point that
    /// touches the database goes through this, so nothing runs on the main
    /// actor (the Onn main-thread starvation rule applies here too).
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            work.async { cont.resume(returning: body()) }
        }
    }

    // MARK: - Row shaping

    /// The folded sort key the old in-memory `MoviesView.sortItems` built,
    /// so SQL orders titles exactly the way Swift did.
    nonisolated static func sortKey(for name: String) -> String {
        String(AlphabetRail.stripQualityPrefix(name))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Fold a display name for loose matching: strip one trailing "(YYYY)",
    /// lowercase. Mirrors the Known For matcher.
    nonisolated static func normalized(_ raw: String) -> String {
        let stripped = VODDisplayItem.strippingTrailingYears(raw)
        return (stripped.isEmpty ? raw : stripped).lowercased()
    }

    private func rowValues(_ item: VODDisplayItem, playlistKey: String,
                           kind: VODItemType, generation: Int64) -> [Bound]? {
        guard let payload = try? encoder.encode(item) else { return nil }
        let year = Int64(item.releaseYear)
        let ratingValue = Double(item.rating)
        let searchText = [item.name, item.castText, item.directorText]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tmdb = item.movie?.tmdbID ?? item.series?.tmdbID ?? ""
        return [
            .text(playlistKey), .text(kindCode(kind)), .text(item.id),
            .text(item.name), .text(Self.sortKey(for: item.name)),
            .text(AlphabetRail.bucket(for: item.name)),
            year.map { Bound.int($0) } ?? .null,
            ratingValue.map { Bound.double($0) } ?? .null,
            item.addedAt.map { Bound.double($0.timeIntervalSince1970) } ?? .null,
            (item.categoryName?.isEmpty == false) ? .text(item.categoryName!) : .null,
            tmdb.isEmpty ? .null : .text(tmdb),
            .text(Self.normalized(item.name)),
            .text(LibraryMatcher.cleanTitle(item.name).lowercased()),
            .text(searchText),
            .blob(payload),
            .int(generation),
        ]
    }

    private func decodeRow(_ stmt: OpaquePointer, _ col: Int32) -> VODDisplayItem? {
        guard let data = blob(stmt, col) else { return nil }
        return try? decoder.decode(VODDisplayItem.self, from: data)
    }

    // MARK: - Writes

    /// Write one page of titles for `generation`.
    ///
    /// A row an older generation wrote is refreshed; a row this generation
    /// already holds is left alone, so the FIRST category to deliver a title
    /// keeps its group stamp (what the old in-memory `seenUUIDs` set did);
    /// a new title is inserted. Returns how many rows were new or refreshed.
    @discardableResult
    func writePage(_ items: [VODDisplayItem], playlistKey: String,
                   kind: VODItemType, generation: Int64) async -> Int {
        guard !items.isEmpty else { return 0 }
        return await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return 0 }
            let columns = "playlistKey, kind, itemKey, title, sortKey, bucket, year, ratingValue, "
                + "addedAt, category, tmdbId, normTitle, cleanTitle, searchText, payload, generation"
            let insertSQL = "INSERT OR IGNORE INTO vod_title (\(columns)) VALUES (\(Self.placeholders(16)))"
            let updateSQL = """
            UPDATE vod_title SET title = ?, sortKey = ?, bucket = ?, year = ?, ratingValue = ?,
                addedAt = ?, category = ?, tmdbId = ?, normTitle = ?, cleanTitle = ?,
                searchText = ?, payload = ?, generation = ?
            WHERE playlistKey = ? AND kind = ? AND itemKey = ? AND generation <> ?
            """
            var touched = 0
            self.run("BEGIN IMMEDIATE;")
            for item in items {
                guard let values = self.rowValues(item, playlistKey: playlistKey,
                                                  kind: kind, generation: generation) else { continue }
                // Refresh an older generation's row first.
                let updateValues = Array(values[3...]) + [values[0], values[1], values[2], .int(generation)]
                self.run(updateSQL, updateValues)
                if sqlite3_changes(self.db) > 0 { touched += 1; continue }
                self.run(insertSQL, values)
                if sqlite3_changes(self.db) > 0 { touched += 1 }
            }
            self.run("COMMIT;")
            return touched
        }
    }

    // MARK: - Sweep bookkeeping

    /// Open, or resume, a sweep of `kind` over `lanes`.
    ///
    /// An OPEN generation left by an interrupted or failed run is resumed:
    /// lanes keep their saved page, lanes the server no longer offers are
    /// dropped, new ones start at page 1. Otherwise the generation advances
    /// and every lane starts from its first page.
    func beginSweep(playlistKey: String, kind: VODItemType, lanes: [String]) async -> VODSweepPlan {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else {
                return VODSweepPlan(generation: 1, resumed: false, nextPage: [:], done: [])
            }
            let k = self.kindCode(kind)
            let wanted = Set(lanes)
            var plan = VODSweepPlan(generation: 1, resumed: false, nextPage: [:], done: [])
            self.run("BEGIN IMMEDIATE;")
            var generation: Int64 = 0
            var isOpen = false
            var completedAt: Double? = nil
            var remoteCount: Int? = nil
            var remoteNewest: String? = nil
            self.query("SELECT generation, open, completedAt, remoteCount, remoteNewest FROM vod_sweep_state "
                       + "WHERE playlistKey = ? AND kind = ?",
                       [.text(playlistKey), .text(k)]) { stmt in
                generation = sqlite3_column_int64(stmt, 0)
                isOpen = sqlite3_column_int(stmt, 1) != 0
                if sqlite3_column_type(stmt, 2) != SQLITE_NULL { completedAt = sqlite3_column_double(stmt, 2) }
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL { remoteCount = Int(sqlite3_column_int64(stmt, 3)) }
                remoteNewest = self.text(stmt, 4)
            }
            if isOpen, generation > 0 {
                var saved: [String: (Int, Bool)] = [:]
                self.query("SELECT lane, nextPage, done FROM vod_sweep_lane "
                           + "WHERE playlistKey = ? AND kind = ? AND generation = ?",
                           [.text(playlistKey), .text(k), .int(generation)]) { stmt in
                    guard let lane = self.text(stmt, 0) else { return }
                    saved[lane] = (Int(sqlite3_column_int64(stmt, 1)), sqlite3_column_int(stmt, 2) != 0)
                }
                for lane in saved.keys where !wanted.contains(lane) {
                    self.run("DELETE FROM vod_sweep_lane WHERE playlistKey = ? AND kind = ? AND lane = ?",
                             [.text(playlistKey), .text(k), .text(lane)])
                }
                for lane in lanes {
                    let entry = saved[lane] ?? (1, false)
                    plan.nextPage[lane] = entry.0
                    if entry.1 { plan.done.insert(lane) }
                }
                plan.generation = generation
                plan.resumed = !plan.done.isEmpty || plan.nextPage.values.contains { $0 > 1 }
            } else {
                let next = generation + 1
                self.run("INSERT OR REPLACE INTO vod_sweep_state "
                         + "(playlistKey, kind, generation, open, startedAt, completedAt, remoteCount, remoteNewest) "
                         + "VALUES (?, ?, ?, 1, ?, ?, ?, ?)",
                         [.text(playlistKey), .text(k), .int(next), .double(Date().timeIntervalSince1970),
                          completedAt.map { Bound.double($0) } ?? .null,
                          remoteCount.map { Bound.int(Int64($0)) } ?? .null,
                          remoteNewest.map { Bound.text($0) } ?? .null])
                self.run("DELETE FROM vod_sweep_lane WHERE playlistKey = ? AND kind = ?",
                         [.text(playlistKey), .text(k)])
                plan.generation = next
                for lane in lanes { plan.nextPage[lane] = 1 }
            }
            self.run("COMMIT;")
            return plan
        }
    }

    /// Save one lane's position after a page landed (or failed). Cheap: the
    /// sweep calls this every few pages, exactly as the old position file was
    /// written, and it is now transactional with the rows it describes.
    func saveLanes(playlistKey: String, kind: VODItemType, generation: Int64,
                   nextPage: [String: Int], done: Set<String>) async {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return }
            let k = self.kindCode(kind)
            self.run("BEGIN IMMEDIATE;")
            for (lane, page) in nextPage {
                self.run("INSERT OR REPLACE INTO vod_sweep_lane (playlistKey, kind, lane, generation, nextPage, done) "
                         + "VALUES (?, ?, ?, ?, ?, ?)",
                         [.text(playlistKey), .text(k), .text(lane), .int(generation),
                          .int(Int64(page)), .int(done.contains(lane) ? 1 : 0)])
            }
            self.run("COMMIT;")
        }
    }

    /// Close a sweep that walked every lane: delete titles older generations
    /// wrote and this one never re-confirmed. Refuses (and returns -1) when
    /// the generation wrote nothing, so a transient all-empty answer can
    /// never wipe a good library. `keepCategories` are groups whose lane
    /// failed, whose titles must not vanish because of that failure.
    @discardableResult
    func finishSweep(playlistKey: String, kind: VODItemType, generation: Int64,
                     keepCategories: [String] = [],
                     remoteCount: Int? = nil, remoteNewest: String? = nil) async -> Int {
        let deleted = await offMain { [weak self] () -> Int in
            guard let self, self.ensureOpen() != nil else { return -1 }
            let k = self.kindCode(kind)
            self.run("BEGIN IMMEDIATE;")
            var written = 0
            self.query("SELECT COUNT(*) FROM vod_title WHERE playlistKey = ? AND kind = ? AND generation = ?",
                       [.text(playlistKey), .text(k), .int(generation)]) { stmt in
                written = Int(sqlite3_column_int64(stmt, 0))
            }
            if written == 0 {
                // Abandon: close the generation without deleting anything so
                // the next sweep opens a fresh one instead of resuming an
                // empty one forever.
                self.run("UPDATE vod_sweep_state SET open = 0 WHERE playlistKey = ? AND kind = ?",
                         [.text(playlistKey), .text(k)])
                self.run("DELETE FROM vod_sweep_lane WHERE playlistKey = ? AND kind = ?",
                         [.text(playlistKey), .text(k)])
                self.run("COMMIT;")
                return -1
            }
            let keep = Array(keepCategories.prefix(Self.maxBind))
            var sql = "DELETE FROM vod_title WHERE playlistKey = ? AND kind = ? AND generation < ?"
            var args: [Bound] = [.text(playlistKey), .text(k), .int(generation)]
            if !keep.isEmpty {
                sql += " AND (category IS NULL OR category NOT IN (\(Self.placeholders(keep.count))))"
                args += keep.map { Bound.text($0) }
            }
            self.run(sql, args)
            let removed = Int(sqlite3_changes(self.db))
            self.run("UPDATE vod_sweep_state SET open = 0, completedAt = ?, remoteCount = ?, remoteNewest = ? "
                     + "WHERE playlistKey = ? AND kind = ?",
                     [.double(Date().timeIntervalSince1970),
                      remoteCount.map { Bound.int(Int64($0)) } ?? .null,
                      remoteNewest.map { Bound.text($0) } ?? .null,
                      .text(playlistKey), .text(k)])
            self.run("DELETE FROM vod_sweep_lane WHERE playlistKey = ? AND kind = ?",
                     [.text(playlistKey), .text(k)])
            self.run("COMMIT;")
            return removed
        }
        clearRowCache()
        return deleted
    }

    func sweepState(playlistKey: String, kind: VODItemType) async -> VODSweepState? {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return nil }
            var out: VODSweepState?
            self.query("SELECT generation, open, completedAt, remoteCount, remoteNewest FROM vod_sweep_state "
                       + "WHERE playlistKey = ? AND kind = ?",
                       [.text(playlistKey), .text(self.kindCode(kind))]) { stmt in
                out = VODSweepState(
                    generation: sqlite3_column_int64(stmt, 0),
                    isOpen: sqlite3_column_int(stmt, 1) != 0,
                    completedAt: sqlite3_column_type(stmt, 2) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    remoteCount: sqlite3_column_type(stmt, 3) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(stmt, 3)),
                    remoteNewest: self.text(stmt, 4))
            }
            return out
        }
    }

    // MARK: - Categories

    func saveCategories(_ categories: [VODCategory], playlistKey: String, kind: VODItemType) async {
        guard !categories.isEmpty else { return }
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return }
            let k = self.kindCode(kind)
            self.run("BEGIN IMMEDIATE;")
            self.run("DELETE FROM vod_category WHERE playlistKey = ? AND kind = ?", [.text(playlistKey), .text(k)])
            for (i, c) in categories.enumerated() {
                self.run("INSERT OR REPLACE INTO vod_category (playlistKey, kind, name, catId, providerIDs, ord) "
                         + "VALUES (?, ?, ?, ?, ?, ?)",
                         [.text(playlistKey), .text(k), .text(c.name), .text(c.id),
                          .text(c.providerIDs.map(String.init).joined(separator: ",")), .int(Int64(i))])
            }
            self.run("COMMIT;")
        }
    }

    func categories(playlistKey: String, kind: VODItemType) async -> [VODCategory] {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [] }
            var out: [VODCategory] = []
            self.query("SELECT name, catId, providerIDs FROM vod_category WHERE playlistKey = ? AND kind = ? ORDER BY ord",
                       [.text(playlistKey), .text(self.kindCode(kind))]) { stmt in
                guard let name = self.text(stmt, 0) else { return }
                let ids = (self.text(stmt, 2) ?? "").split(separator: ",").compactMap { Int($0) }
                out.append(VODCategory(id: self.text(stmt, 1) ?? name, name: name, providerIDs: ids))
            }
            return out
        }
    }

    // MARK: - Counts and deletes

    func count(playlistKey: String, kind: VODItemType) async -> Int {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return 0 }
            var n = 0
            self.query("SELECT COUNT(*) FROM vod_title WHERE playlistKey = ? AND kind = ?",
                       [.text(playlistKey), .text(self.kindCode(kind))]) { stmt in
                n = Int(sqlite3_column_int64(stmt, 0))
            }
            return n
        }
    }

    /// Drop one kind's catalog for one playlist (a Dispatcharr account that
    /// lost `vod_movies_enabled` / `vod_series_enabled`).
    func deleteKind(playlistKey: String, kind: VODItemType) async {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return }
            let k = self.kindCode(kind)
            self.run("BEGIN IMMEDIATE;")
            self.run("DELETE FROM vod_title WHERE playlistKey = ? AND kind = ?", [.text(playlistKey), .text(k)])
            self.run("DELETE FROM vod_sweep_state WHERE playlistKey = ? AND kind = ?", [.text(playlistKey), .text(k)])
            self.run("DELETE FROM vod_sweep_lane WHERE playlistKey = ? AND kind = ?", [.text(playlistKey), .text(k)])
            self.run("DELETE FROM vod_category WHERE playlistKey = ? AND kind = ?", [.text(playlistKey), .text(k)])
            self.run("COMMIT;")
        }
        clearRowCache()
    }

    /// Drop every catalog row a playlist owns, across ALL of its identities
    /// (a URL or account change mints a new key for the same server id).
    ///
    /// Called from the playlist DELETE path and from Refresh Everything. A
    /// playlist SWITCH must never call this: the previous playlist's catalog
    /// is what makes switching back instant.
    func deleteServer(serverID: UUID) async {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return }
            let like = "%|\(serverID.uuidString)|%"
            self.run("BEGIN IMMEDIATE;")
            for table in ["vod_title", "vod_sweep_state", "vod_sweep_lane", "vod_category"] {
                self.run("DELETE FROM \(table) WHERE playlistKey LIKE ?", [.text(like)])
            }
            self.run("COMMIT;")
            self.run("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        clearRowCache()
    }

    // MARK: - Legacy import

    /// One-time import of the pre-catalog JSON snapshot so an upgrade opens
    /// with the library it already had and re-downloads nothing.
    ///
    /// Written as generation 0 and closed with the snapshot's own timestamp
    /// and change probe, so the launch cadence gate behaves exactly as it
    /// did with the file. The first real sweep (generation 1) refreshes every
    /// imported row and removes the ones the provider dropped.
    /// Returns how many rows were imported.
    @discardableResult
    func importLegacySnapshot(kind: VODItemType, playlistKey: String,
                              snapshot: VODLibraryCache.Snapshot) async -> Int {
        guard !snapshot.items.isEmpty else { return 0 }
        guard await count(playlistKey: playlistKey, kind: kind) == 0 else { return 0 }
        var written = 0
        for chunk in stride(from: 0, to: snapshot.items.count, by: 500) {
            let slice = Array(snapshot.items[chunk..<min(chunk + 500, snapshot.items.count)])
            written += await writePage(slice, playlistKey: playlistKey, kind: kind, generation: 0)
        }
        await saveCategories(snapshot.categories, playlistKey: playlistKey, kind: kind)
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return }
            self.run("INSERT OR REPLACE INTO vod_sweep_state "
                     + "(playlistKey, kind, generation, open, startedAt, completedAt, remoteCount, remoteNewest) "
                     + "VALUES (?, ?, 0, 0, 0, ?, ?, ?)",
                     [.text(playlistKey), .text(self.kindCode(kind)),
                      .double(snapshot.at.timeIntervalSince1970),
                      snapshot.remoteCount.map { Bound.int(Int64($0)) } ?? .null,
                      snapshot.remoteNewest.map { Bound.text($0) } ?? .null])
        }
        return written
    }

    // MARK: - The grid's library

    /// Run `q` and return the row ids in display order plus each row's rail
    /// bucket. About 9 bytes per title, so a 350,000 title library costs
    /// roughly 3 MB here instead of the gigabytes the mapped item array
    /// needed. Always off the main actor.
    func buildLibrary(_ q: VODCatalogQuery) async -> VODWindowList {
        let list = await offMain { [weak self] () -> VODWindowList in
            guard let self, self.ensureOpen() != nil else { return VODWindowList.empty }
            let k = self.kindCode(q.kind)
            var sql = "SELECT id, bucket FROM vod_title WHERE playlistKey = ? AND kind = ?"
            var args: [Bound] = [.text(q.playlistKey), .text(k)]
            // Hidden titles. `HiddenVODStore` keys are "<type>:<id>"; the set
            // is a handful of rows in practice, so it binds directly.
            let prefix = (q.kind == .series ? "series" : "movie") + "|"
            let hiddenIDs = q.hiddenTitleKeys
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
                .prefix(Self.maxBind)
            if q.onlyHidden {
                guard !hiddenIDs.isEmpty else { return VODWindowList.empty }
                sql += " AND itemKey IN (\(Self.placeholders(hiddenIDs.count)))"
                args += hiddenIDs.map { Bound.text($0) }
            } else if !hiddenIDs.isEmpty {
                sql += " AND itemKey NOT IN (\(Self.placeholders(hiddenIDs.count)))"
                args += hiddenIDs.map { Bound.text($0) }
            }
            if !q.hiddenGroups.isEmpty {
                let groups = Array(q.hiddenGroups.prefix(Self.maxBind))
                sql += " AND (category IS NULL OR category NOT IN (\(Self.placeholders(groups.count))))"
                args += groups.map { Bound.text($0) }
            }
            if !q.onlyHidden, let genre = q.genre {
                sql += " AND category = ?"
                args.append(.text(genre))
            }
            sql += " ORDER BY " + Self.orderClause(q.sortRaw)
            var ids: [Int64] = []
            var buckets: [UInt8] = []
            ids.reserveCapacity(4096)
            buckets.reserveCapacity(4096)
            self.query(sql, args) { stmt in
                ids.append(sqlite3_column_int64(stmt, 0))
                let b = self.text(stmt, 1)?.utf8.first ?? UInt8(ascii: "#")
                buckets.append(b)
            }
            return VODWindowList(store: self, rowIDs: ids, buckets: buckets)
        }
        // Warm the first screens so the first frame never reads on main.
        if !list.isEmpty { await offMain { [weak self] in self?.loadWindow(rowIDs: list.rowIDs, around: 0) } }
        return list
    }

    private static func orderClause(_ sortRaw: String) -> String {
        switch MoviesSortOrder(rawValue: sortRaw) ?? .titleAZ {
        case .titleAZ:       return "sortKey ASC, id ASC"
        case .titleZA:       return "sortKey DESC, id ASC"
        case .yearNewest:    return "(year IS NULL) ASC, year DESC, sortKey ASC"
        case .yearOldest:    return "(year IS NULL) ASC, year ASC, sortKey ASC"
        case .ratingHigh:    return "COALESCE(ratingValue, -1.0) DESC, sortKey ASC"
        case .recentlyAdded: return "(addedAt IS NULL) ASC, addedAt DESC, sortKey ASC"
        }
    }

    /// The Recently Added shelf: at most `limit` newest titles that carry a
    /// source add time. A bounded query, never a sort of the whole catalog.
    func recentlyAdded(playlistKey: String, kind: VODItemType,
                       hiddenGroups: Set<String>, hiddenTitleKeys: Set<String>,
                       limit: Int = 20) async -> [VODDisplayItem] {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [] }
            var sql = "SELECT payload FROM vod_title WHERE playlistKey = ? AND kind = ? AND addedAt IS NOT NULL"
            var args: [Bound] = [.text(playlistKey), .text(self.kindCode(kind))]
            if !hiddenGroups.isEmpty {
                let groups = Array(hiddenGroups.prefix(Self.maxBind))
                sql += " AND (category IS NULL OR category NOT IN (\(Self.placeholders(groups.count))))"
                args += groups.map { Bound.text($0) }
            }
            sql += " ORDER BY addedAt DESC, sortKey ASC LIMIT ?"
            args.append(.int(Int64(limit * 2)))
            var out: [VODDisplayItem] = []
            self.query(sql, args) { stmt in
                guard let item = self.decodeRow(stmt, 0) else { return }
                out.append(item)
            }
            let prefix = (kind == .series ? "series" : "movie") + "|"
            let hidden = Set(hiddenTitleKeys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            return Array(out.filter { !hidden.contains($0.id) }.prefix(limit))
        }
    }

    /// Group names present in the stored catalog, for sources that do not
    /// publish a category list of their own.
    func distinctCategories(playlistKey: String, kind: VODItemType) async -> [String] {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [] }
            var out: [String] = []
            self.query("SELECT DISTINCT category FROM vod_title WHERE playlistKey = ? AND kind = ? "
                       + "AND category IS NOT NULL ORDER BY category",
                       [.text(playlistKey), .text(self.kindCode(kind))]) { stmt in
                if let name = self.text(stmt, 0) { out.append(name) }
            }
            return out
        }
    }

    // MARK: - Lookups

    /// Titles by their provider id, for the Continue Watching hero, the
    /// Watchlist shelf and deep links: a bounded indexed read instead of a
    /// linear walk of the whole library on every body pass.
    func items(playlistKey: String, kind: VODItemType, ids: [String]) async -> [String: VODDisplayItem] {
        guard !ids.isEmpty else { return [:] }
        return await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [:] }
            var out: [String: VODDisplayItem] = [:]
            for chunk in stride(from: 0, to: ids.count, by: Self.maxBind) {
                let slice = Array(ids[chunk..<min(chunk + Self.maxBind, ids.count)])
                let sql = "SELECT payload FROM vod_title WHERE playlistKey = ? AND kind = ? "
                    + "AND itemKey IN (\(Self.placeholders(slice.count)))"
                self.query(sql, [.text(playlistKey), .text(self.kindCode(kind))] + slice.map { Bound.text($0) }) { stmt in
                    if let item = self.decodeRow(stmt, 0) { out[item.id] = item }
                }
            }
            return out
        }
    }

    /// Titles by TMDB id (Related strip, Known For deep links).
    func itemsByTMDBID(playlistKey: String, kind: VODItemType, tmdbIDs: [String]) async -> [String: VODDisplayItem] {
        guard !tmdbIDs.isEmpty else { return [:] }
        return await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [:] }
            var out: [String: VODDisplayItem] = [:]
            for chunk in stride(from: 0, to: tmdbIDs.count, by: Self.maxBind) {
                let slice = Array(tmdbIDs[chunk..<min(chunk + Self.maxBind, tmdbIDs.count)])
                let sql = "SELECT tmdbId, payload FROM vod_title WHERE playlistKey = ? AND kind = ? "
                    + "AND tmdbId IN (\(Self.placeholders(slice.count)))"
                self.query(sql, [.text(playlistKey), .text(self.kindCode(kind))] + slice.map { Bound.text($0) }) { stmt in
                    guard let key = self.text(stmt, 0), let item = self.decodeRow(stmt, 1) else { return }
                    if out[key] == nil { out[key] = item }
                }
            }
            return out
        }
    }

    /// Titles by normalized name, for rows that carry NO TMDB id. The strict
    /// id tier runs first, so a same-named remake cannot hijack a match.
    func itemsByNormalizedTitle(playlistKey: String, kind: VODItemType,
                                titles: [String], requireNoTMDBID: Bool) async -> [String: VODDisplayItem] {
        guard !titles.isEmpty else { return [:] }
        return await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [:] }
            var out: [String: VODDisplayItem] = [:]
            for chunk in stride(from: 0, to: titles.count, by: Self.maxBind) {
                let slice = Array(titles[chunk..<min(chunk + Self.maxBind, titles.count)])
                var sql = "SELECT normTitle, payload FROM vod_title WHERE playlistKey = ? AND kind = ?"
                if requireNoTMDBID { sql += " AND (tmdbId IS NULL OR tmdbId = '')" }
                sql += " AND normTitle IN (\(Self.placeholders(slice.count)))"
                self.query(sql, [.text(playlistKey), .text(self.kindCode(kind))] + slice.map { Bound.text($0) }) { stmt in
                    guard let key = self.text(stmt, 0), let item = self.decodeRow(stmt, 1) else { return }
                    if out[key] == nil { out[key] = item }
                }
            }
            return out
        }
    }

    /// Titles by the DVR art matcher's cleaned title.
    func itemsByCleanTitle(playlistKey: String, kind: VODItemType, cleanTitle: String, limit: Int = 5) async -> [VODDisplayItem] {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [] }
            var out: [VODDisplayItem] = []
            self.query("SELECT payload FROM vod_title WHERE playlistKey = ? AND kind = ? AND cleanTitle = ? LIMIT ?",
                       [.text(playlistKey), .text(self.kindCode(kind)), .text(cleanTitle), .int(Int64(limit))]) { stmt in
                if let item = self.decodeRow(stmt, 0) { out.append(item) }
            }
            return out
        }
    }

    /// Per-keystroke search, as a database query. `searchText` is the folded
    /// name plus cast plus director, so one LIKE covers what the old
    /// in-memory triple `localizedCaseInsensitiveContains` covered.
    func search(playlistKey: String, kind: VODItemType, query text: String,
                hiddenTitleKeys: Set<String> = [], limit: Int = searchLimit) async -> [VODDisplayItem] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !folded.isEmpty else { return [] }
        return await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return [] }
            let escaped = folded
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            var out: [VODDisplayItem] = []
            self.query("SELECT payload FROM vod_title WHERE playlistKey = ? AND kind = ? "
                       + "AND searchText LIKE ? ESCAPE '\\' ORDER BY sortKey LIMIT ?",
                       [.text(playlistKey), .text(self.kindCode(kind)), .text("%\(escaped)%"), .int(Int64(limit))]) { stmt in
                if let item = self.decodeRow(stmt, 0) { out.append(item) }
            }
            let prefix = (kind == .series ? "series" : "movie") + "|"
            let hidden = Set(hiddenTitleKeys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            return hidden.isEmpty ? out : out.filter { !hidden.contains($0.id) }
        }
    }

    /// One keyset page for the background TMDB art pass, so enrichment walks
    /// the catalog a few hundred rows at a time instead of holding it all.
    func artPage(playlistKey: String, kind: VODItemType, afterID: Int64, limit: Int) async -> (rows: [VODDisplayItem], lastID: Int64) {
        await offMain { [weak self] in
            guard let self, self.ensureOpen() != nil else { return ([], afterID) }
            var out: [VODDisplayItem] = []
            var last = afterID
            self.query("SELECT id, payload FROM vod_title WHERE playlistKey = ? AND kind = ? AND id > ? ORDER BY id LIMIT ?",
                       [.text(playlistKey), .text(self.kindCode(kind)), .int(afterID), .int(Int64(limit))]) { stmt in
                last = sqlite3_column_int64(stmt, 0)
                if let item = self.decodeRow(stmt, 1) { out.append(item) }
            }
            return (out, last)
        }
    }

    // MARK: - The window cache

    private let cacheLock = NSLock()
    private var rowCache: [Int64: VODDisplayItem] = [:]
    /// Insertion order, so the cache evicts the oldest window first.
    private var cacheOrder: [Int64] = []
    private var inFlightWindows: Set<Int> = []

    func cachedRow(_ id: Int64) -> VODDisplayItem? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return rowCache[id]
    }

    /// Forget every cached row. A finished sweep may have changed titles,
    /// categories or art.
    func clearRowCache() {
        cacheLock.lock()
        rowCache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        cacheLock.unlock()
    }

    /// Read the window holding `index` into the row cache, synchronously.
    /// Called on the scrolling thread only when the prefetch lost the race.
    func loadWindow(rowIDs: [Int64], around index: Int) {
        guard !rowIDs.isEmpty else { return }
        let start = max(0, index - Self.windowBehind)
        let end = min(start + Self.windowSize, rowIDs.count)
        guard start < end else { return }
        cacheLock.lock()
        let want = (start..<end).map { rowIDs[$0] }.filter { rowCache[$0] == nil }
        cacheLock.unlock()
        guard !want.isEmpty, ensureOpen() != nil else { return }
        var fetched: [(Int64, VODDisplayItem)] = []
        fetched.reserveCapacity(want.count)
        let sql = "SELECT id, payload FROM vod_title WHERE id IN (\(Self.placeholders(want.count)))"
        query(sql, want.map { Bound.int($0) }) { stmt in
            guard let item = self.decodeRow(stmt, 1) else { return }
            fetched.append((sqlite3_column_int64(stmt, 0), item))
        }
        guard !fetched.isEmpty else { return }
        cacheLock.lock()
        for (id, item) in fetched where rowCache[id] == nil {
            rowCache[id] = item
            cacheOrder.append(id)
        }
        // Bounded: about 2,400 rows, a few MB, regardless of catalog size.
        if cacheOrder.count > Self.rowCacheLimit {
            let drop = cacheOrder.count - Self.rowCacheLimit
            for id in cacheOrder.prefix(drop) { rowCache.removeValue(forKey: id) }
            cacheOrder.removeFirst(drop)
        }
        cacheLock.unlock()
    }

    /// Read the windows on either side of `index` in the background when
    /// they are not cached yet, so the scroll never waits on the database.
    func prefetchWindow(rowIDs: [Int64], around index: Int) {
        guard !rowIDs.isEmpty else { return }
        let ahead = min(index + Self.windowSize - Self.windowBehind, rowIDs.count - 1)
        let behind = max(index - Self.windowBehind, 0)
        for probe in [ahead, behind] where probe >= 0 {
            if cachedRow(rowIDs[probe]) != nil { continue }
            let bucket = probe / Self.windowSize
            cacheLock.lock()
            let claimed = inFlightWindows.insert(bucket).inserted
            cacheLock.unlock()
            guard claimed else { continue }
            prefetchQueue.async { [weak self] in
                guard let self else { return }
                self.loadWindow(rowIDs: rowIDs, around: probe)
                self.cacheLock.lock()
                self.inFlightWindows.remove(bucket)
                self.cacheLock.unlock()
            }
        }
    }
}
