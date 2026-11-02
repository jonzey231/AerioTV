//  DsyncStores.swift
//  Aerio
//
//  Dispatcharr Sync persisted state, the Apple counterpart of the Android
//  "aerio_dsync" and "aerio_dsync_held" SharedPreferences files:
//    - DsyncStateStore: per (playlist, profile, key) stamps, dirty flags,
//      forced-replace arms, and the raw server copies. Small values live in
//      UserDefaults under the same key shapes Android uses ("at|<pid>|<profile>|<suffix>"),
//      prefixed "aerio_dsync|" so they never collide with app settings. The
//      raw JSON copies (one bucket can be tens of KB) live in files under
//      AppCacheDirectory/dsync, because tvOS caps UserDefaults and has no
//      writable Application Support. A lost raw copy only costs a re-fetch.
//    - DsyncHeldStore: held progress rows by canonical id (section 10a), per
//      playlist, plus the canonical items the last cloud read carried.
//
//  Never logs values (counts only, by the callers).

import Foundation

@MainActor
final class DsyncStateStore {
    static let shared = DsyncStateStore()

    private let ud = UserDefaults.standard
    private let prefix = "aerio_dsync|"
    private lazy var dir: URL = {
        let d = AppCacheDirectory.url.appendingPathComponent("dsync", isDirectory: true)
        do { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) } catch {
            debugLog("[DSYNC] state directory create failed: \(type(of: error))")
        }
        return d
    }()

    // ---- scalars ----

    func bool(_ k: String) -> Bool { ud.bool(forKey: prefix + k) }
    func long(_ k: String) -> Int64 { Int64(ud.integer(forKey: prefix + k)) }
    func string(_ k: String) -> String? { ud.string(forKey: prefix + k) }
    func contains(_ k: String) -> Bool { ud.object(forKey: prefix + k) != nil }
    func set(_ k: String, _ v: Bool) { ud.set(v, forKey: prefix + k) }
    func set(_ k: String, _ v: Int64) { ud.set(Int(v), forKey: prefix + k) }
    func set(_ k: String, _ v: String) { ud.set(v, forKey: prefix + k) }
    func remove(_ k: String) { ud.removeObject(forKey: prefix + k) }
    /// Every scalar key starting with [p] (the store prefix stripped), for the per-row profile stamps.
    func keys(withPrefix p: String) -> [String] {
        let full = prefix + p
        return ud.dictionaryRepresentation().keys.filter { $0.hasPrefix(full) }.map { String($0.dropFirst(prefix.count)) }
    }

    // ---- JSON blobs (files) ----

    private func file(_ k: String) -> URL {
        // Key shapes carry "|" and playlist UUIDs; keep the name filesystem safe.
        let safe = k.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".json")
    }

    func object(_ k: String) -> DsyncObject? {
        guard let data = try? Data(contentsOf: file(k)) else { return nil }
        return DsyncJSONParser.parse(data)?.asObject
    }

    func setObject(_ k: String, _ o: DsyncObject?) {
        let url = file(k)
        guard let o else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do { try Data(DsyncJSONEncoder.encode(o).utf8).write(to: url, options: .atomic) } catch {
            debugLog("[DSYNC] state write failed: \(type(of: error))")
        }
    }

    /// Random install id (section 3), never tied to hardware ids.
    var deviceId: String {
        if let id = string("deviceId") { return id }
        let id = UUID().uuidString.uppercased()
        set("deviceId", id)
        return id
    }
}

@MainActor
final class DsyncHeldStore {
    static let shared = DsyncHeldStore()

    private let state = DsyncStateStore.shared
    /// Canonical VOD items ("m|11", "e|22", "s|3") the last cloud read carried with an id, by playlist.
    private var cloudItems: [String: Set<String>] = [:]

    private func key(_ playlistId: String) -> String { "held|progress|\(playlistId)" }

    /// True once a pull wrote the held set for [playlistId] (empty included).
    func has(_ playlistId: String) -> Bool { state.contains(key(playlistId) + "|set") }

    func progress(_ playlistId: String) -> [ProgressRow] {
        state.object(key(playlistId)).flatMap { DsyncPayloads.decodeProgress($0) } ?? []
    }

    func setProgress(_ playlistId: String, _ rows: [ProgressRow]) {
        let now = Int64(Date().timeIntervalSince1970)
        state.setObject(key(playlistId), DsyncPayloads.encodeProgress(nil, rows, now: now))
        state.set(key(playlistId) + "|set", true)
    }

    func items(_ playlistId: String) -> Set<String> { Set(progress(playlistId).map(DsyncHeld.item)) }

    func noteCloudItems(_ playlistId: String, _ items: Set<String>) { cloudItems[playlistId] = items }

    func cloudItems(_ playlistId: String) -> Set<String> { cloudItems[playlistId] ?? [] }
}

/// A MainActor async mutex: the Android session Mutex (pull and write never interleave).
@MainActor
final class DsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isLocked: Bool { locked }

    func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
