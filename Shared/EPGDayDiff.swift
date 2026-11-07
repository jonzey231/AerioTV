//
//  EPGDayDiff.swift
//  Aerio
//
//  One day of the background EPG sweep, fetched rows against the cached rows,
//  reduced to the writes that actually change something. Port of the Android
//  EpgDayDiff (AerioTV-Android bacd6d0e).
//
//  Identity is (channel, start). A fetched row whose pair is not cached is
//  ADDED. A cached pair the fetch still carries is UNCHANGED when every stored
//  field matches, and CHANGED otherwise (a game that ends early keeps its start
//  and moves its end). A cached row is REMOVED when its channel is in scope,
//  the fetch carried that channel this day, the row starts inside the span the
//  fetch covered for that channel and not before now (already-aired rows are
//  the catch-up archive), and the fetch no longer carries its pair.
//
//  Rows outside the scope (channels fed by EPG sources that did not change) are
//  never written. An unchanged day costs zero writes.
//
//  Pure: no SwiftData, no clock, no app singletons, so
//  Scripts/epg-diff-tests/run.sh compiles and tests it with swiftc.
//

import Foundation

/// One program row in cache shape. `rowID` is the cache's own handle for the
/// row (opaque to the diff); fetched rows leave it nil.
struct EPGDiffRow: Equatable, Sendable {
    var rowID: String? = nil
    var channelID: String
    var start: Date
    var end: Date
    var title: String
    var description: String = ""
    var subTitle: String? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var isNew: Bool = false
    var isLiveBroadcast: Bool = false
    var isPremiere: Bool = false
    var isFinale: Bool = false
    var isRepeat: Bool = false
    var iconURL: String = ""
    var category: String = ""
    var programID: Int? = nil
}

enum EPGDayDiff {

    struct Result: Sendable {
        /// Added and changed rows. The writer replaces on (channel, start).
        var upserts: [EPGDiffRow]
        /// Cache handles of removed rows.
        var deleteIDs: [String]
        /// (row handle, new program id) for rows whose content is identical and
        /// only the server's program id moved. A Dispatcharr source refresh
        /// re-creates its programs wholesale, so every program gets a new id
        /// even when nothing changed; the id still drives Program Info and
        /// category lookups, so it is updated in place, never by a rewrite.
        var programIDUpdates: [(rowID: String, programID: Int?)]
        var fetchedInScope: Int
        var unchanged: Int
        var added: Int
        var changed: Int
        var removed: Int

        /// Rows deleted or inserted. Program id updates are counted apart.
        var writes: Int { upserts.count + deleteIDs.count }
        var remapped: Int { programIDUpdates.count }
    }

    /// Same floor the cache merge applies: shorter rows are feed noise.
    static let minDrawable: TimeInterval = 30

    private struct Key: Hashable {
        let channelID: String
        let start: Date
    }

    /// - Parameters:
    ///   - fetched: the day's fetched rows, already in cache shape.
    ///   - cached: the cached rows overlapping the same day.
    ///   - inScope: channels this sweep may write; nil means every channel.
    ///   - now: removals never reach back before this instant.
    static func compute(fetched: [EPGDiffRow],
                        cached: [EPGDiffRow],
                        inScope: ((String) -> Bool)?,
                        now: Date) -> Result {
        var cachedByKey: [Key: EPGDiffRow] = [:]
        cachedByKey.reserveCapacity(cached.count)
        for c in cached { cachedByKey[Key(channelID: c.channelID, start: c.start)] = c }

        // Last fetched row wins on a duplicated pair, like a REPLACE insert.
        var fetchedByKey: [Key: EPGDiffRow] = [:]
        var order: [Key] = []
        var spanByChannel: [String: (start: Date, end: Date)] = [:]
        for f in fetched {
            if f.end.timeIntervalSince(f.start) < minDrawable { continue }
            if let inScope, !inScope(f.channelID) { continue }
            let key = Key(channelID: f.channelID, start: f.start)
            if fetchedByKey.updateValue(f, forKey: key) == nil { order.append(key) }
            if let span = spanByChannel[f.channelID] {
                spanByChannel[f.channelID] = (min(span.start, f.start), max(span.end, f.end))
            } else {
                spanByChannel[f.channelID] = (f.start, f.end)
            }
        }

        var upserts: [EPGDiffRow] = []
        var idUpdates: [(rowID: String, programID: Int?)] = []
        var unchanged = 0, added = 0, changed = 0
        for key in order {
            guard let f = fetchedByKey[key] else { continue }
            if let c = cachedByKey[key] {
                if sameContent(c, f) {
                    unchanged += 1
                    if c.programID != f.programID, let rowID = c.rowID {
                        idUpdates.append((rowID, f.programID))
                    }
                } else {
                    changed += 1
                    upserts.append(f)
                }
            } else {
                added += 1
                upserts.append(f)
            }
        }

        var deleteIDs: [String] = []
        for c in cached {
            guard let span = spanByChannel[c.channelID], let rowID = c.rowID else { continue }
            if c.start < max(now, span.start) || c.start >= span.end { continue }
            if fetchedByKey[Key(channelID: c.channelID, start: c.start)] != nil { continue }
            deleteIDs.append(rowID)
        }

        return Result(upserts: upserts, deleteIDs: deleteIDs, programIDUpdates: idUpdates,
                      fetchedInScope: fetchedByKey.count, unchanged: unchanged,
                      added: added, changed: changed, removed: deleteIDs.count)
    }

    /// Every field the grid supplies. Not compared: the row handle (cache
    /// bookkeeping), the server program id (see `programIDUpdates`), and the
    /// category when the fetched one is empty (the grid omits it and the lazy
    /// enrichment fills it in later, so an empty fetched category is not a
    /// change).
    static func sameContent(_ c: EPGDiffRow, _ f: EPGDiffRow) -> Bool {
        c.end == f.end &&
            c.title == f.title &&
            c.description == f.description &&
            c.subTitle == f.subTitle &&
            c.season == f.season &&
            c.episode == f.episode &&
            c.isNew == f.isNew &&
            c.isLiveBroadcast == f.isLiveBroadcast &&
            c.isPremiere == f.isPremiere &&
            c.isFinale == f.isFinale &&
            c.isRepeat == f.isRepeat &&
            c.iconURL == f.iconURL &&
            (f.category.isEmpty || c.category == f.category)
    }
}

/// The gate's per-source comparison and the resume bookkeeping, both pure.
enum EPGSweepPlanner {

    struct Plan: Equatable, Sendable {
        /// The full fingerprint the sweep adopts once its last day lands.
        let fingerprint: String
        /// Sources whose (id, last-updated) pair is not in the stored set.
        let changedSourceIDs: Set<Int>
        /// True on a first sweep (nothing stored) or a grid decoder revision
        /// bump: every channel is in scope.
        let allChannels: Bool
    }

    /// Pairs of a stored or fresh fingerprint ("id:stamp,id:stamp").
    static func pairs(_ fingerprint: String?) -> Set<String> {
        guard let fingerprint else { return [] }
        return Set(fingerprint.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// nil when nothing changed (and nothing is forced).
    static func plan(fresh: String, stored: String?, forcedSourceID: Int? = nil) -> Plan? {
        let storedPairs = pairs(stored)
        let newPairs = fresh.split(separator: ",").map(String.init)
            .filter { !$0.isEmpty && !storedPairs.contains($0) }
        var changed = Set(newPairs.compactMap { pair -> Int? in
            Int(pair.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "")
        })
        if let forcedSourceID { changed.insert(forcedSourceID) }
        let allChannels = (stored?.isEmpty ?? true) || newPairs.contains { $0.hasPrefix("grid-decoder:") }
        if changed.isEmpty && !allChannels { return nil }
        return Plan(fingerprint: fresh, changedSourceIDs: changed, allChannels: allChannels)
    }

    /// Lowercased tvg-ids fed by `sourceIDs`, from /api/epg/epgdata/ rows.
    static func keys(rows: [(tvgID: String, source: Int?)], sourceIDs: Set<Int>) -> Set<String> {
        var out = Set<String>()
        for r in rows {
            guard let s = r.source, sourceIDs.contains(s) else { continue }
            let k = r.tvgID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !k.isEmpty { out.insert(k) }
        }
        return out
    }

    /// Resume record: "<progress key>\n<day,day,...>" with days as whole Unix
    /// seconds of each day's start.
    static func encodeProgress(key: String, days: Set<Date>) -> String {
        key + "\n" + days.map { String(Int64($0.timeIntervalSince1970)) }.sorted().joined(separator: ",")
    }

    /// Days already applied toward `key`; empty when the record belongs to
    /// another target fingerprint.
    static func decodeProgress(_ raw: String?, key: String) -> Set<Date> {
        guard let raw, let nl = raw.firstIndex(of: "\n") else { return [] }
        guard String(raw[..<nl]) == key else { return [] }
        return Set(raw[raw.index(after: nl)...].split(separator: ",").compactMap {
            Int64($0).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        })
    }
}
