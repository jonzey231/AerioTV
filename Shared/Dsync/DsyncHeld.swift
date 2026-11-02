//  DsyncHeld.swift
//  Aerio
//
//  Held server rows (docs/DispatcharrSyncSchema.md section 10a). A
//  Dispatcharr Sync progress row this device cannot map to a local movie
//  or episode yet is held by its canonical id instead of being dropped;
//  the cloud snapshot carries it under a placeholder video id
//  ("dsync:<type>:<id>"), and a row neither side can represent here is
//  excluded from the Dispatcharr summary on this device. Port of the pure
//  parts of the Android core/sync/dsync/DsyncHeld.kt. The cloud snapshot
//  entry conversions (toEntry, fromEntry, withHeld, driveSnapshot) and the
//  per-playlist DsyncHeldStore need the iCloud snapshot types and storage,
//  and land in a later part.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

enum DsyncHeld {
    static let PREFIX = "dsync:"

    static func placeholder(_ type: String, _ id: Int) -> String { "\(PREFIX)\(type):\(id)" }

    static func isPlaceholder(_ videoId: String) -> Bool { videoId.hasPrefix(PREFIX) }

    /// Canonical item ("m|11") of a held row.
    static func item(_ r: ProgressRow) -> String { CloudCanon.vodItem(r.type, r.vodId) }

    /// Setup-choice ordering: the replace push builds the progress snapshot
    /// only once the pulled rows are local. True: build the snapshot now.
    static func progressSettled(heldRows: Int, catalogReady: Bool) -> Bool { heldRows == 0 || catalogReady }

    /// Counts only, for the snapshot line.
    static func snapshotLine(_ why: String, local: Int, canonical: Int, extra: Int, placeholders: Int) -> String {
        "[CLOUD] progress snapshot local=\(local) canonical=\(canonical) dsync=\(extra) placeholders=\(placeholders) (\(why))"
    }

    /// Held rows merged per canonical item, newest updatedAt wins.
    static func merge(_ a: [ProgressRow], _ b: [ProgressRow]) -> [ProgressRow] {
        (a + b).groupedOrdered(by: item).map { $0.1.maxByFirst { $0.updatedAt }! }
    }

    /// The VOD keys the representable filter applies to.
    static let VOD_KEYS: Set<DsyncKey> = [.progress, .watchlist, .hiddenTitles]

    /// One VOD category of the Dispatcharr copy restricted to the rows [keep]
    /// accepts (type, id). Returns the category and the excluded row count.
    static func vodCategory(_ key: DsyncKey, _ data: DsyncObject, updatedAtMs: Int64,
                            keep: (String, Int) -> Bool) -> (SetupSourceChoice.Category, Int) {
        if key == .progress {
            let all = (DsyncPayloads.decodeProgress(data) ?? []).distinctBy { "\($0.type)|\($0.vodId)" }
            let rows = all.filter { keep($0.type, $0.vodId) }
            return (SetupSourceChoice.Category(rows: rows.count, updatedAt: updatedAtMs, fingerprint: CloudCanon.dsyncProgress(rows)),
                    all.count - rows.count)
        }
        let all = (DsyncPayloads.decodeVodMarks(data) ?? []).distinctBy { "\($0.type)|\($0.vodId)" }
        let rows = all.filter { keep($0.type, $0.vodId) }
        return (SetupSourceChoice.Category(rows: rows.count, updatedAt: updatedAtMs, fingerprint: CloudCanon.dsyncMarks(rows)),
                all.count - rows.count)
    }

    /// Whether this device can represent a Dispatcharr row: series ids are
    /// local integers; a movie or episode resolves locally, is held, or is
    /// carried with a canonical id by the cloud copy. Recent channels: one
    /// this device's list maps, or the cloud copy carries; an unloaded
    /// channel list (nil or empty) excludes nothing.
    static func representable(_ type: String, _ id: Int, movies: Set<Int>, episodes: Set<Int>,
                              held: Set<String>, cloud: Set<String>, channels: Set<Int>? = nil) -> Bool {
        if type == "s" { return true }
        if type == CHANNEL { return (channels?.isEmpty ?? true) || channels!.contains(id) || cloud.contains(channelItem(id)) }
        if type == "m" && movies.contains(id) { return true }
        if type == "e" && episodes.contains(id) { return true }
        let it = CloudCanon.vodItem(type, id)
        return held.contains(it) || cloud.contains(it)
    }

    static let CHANNEL = "c"

    /// Canonical channel item for the representable sets ("c|<id>").
    static func channelItem(_ id: Int) -> String { CloudCanon.vodItem(CHANNEL, id) }

    /// The recents category restricted to channels [keep] accepts; returns the excluded count.
    static func recentsCategory(_ data: DsyncObject, updatedAtMs: Int64, keep: (String, Int) -> Bool) -> (SetupSourceChoice.Category, Int) {
        let all = (DsyncPayloads.decodeRecents(data) ?? []).distinctBy { $0.channelId }
        let rows = all.filter { keep(CHANNEL, $0.channelId) }
        return (SetupSourceChoice.Category(rows: rows.count, updatedAt: updatedAtMs, fingerprint: CloudCanon.dsyncRecents(rows)),
                all.count - rows.count)
    }

    static func excludeLine(_ name: String, rows: Int) -> String { "[SYNC] probe excludes \(name) rows=\(rows) (no local match)" }
}
