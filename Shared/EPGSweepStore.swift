//
//  EPGSweepStore.swift
//  Aerio
//
//  Cache side of the delta-only EPG background sweep (port of AerioTV-Android
//  bacd6d0e: EpgProgrammeDao rowsInSpanBlocking / applySweepDayBlocking, the
//  per-source plan, epgKeysForSources, and the resume persistence). The pure
//  rules live in EPGDayDiff.swift; this file reads and writes SwiftData,
//  UserDefaults, and /api/epg/epgdata/ (already a documented path).
//

import Foundation
import SwiftData

enum EPGSweepStore {

    /// Debug hook for measurement, like the Android
    /// `debug.aerio.epg_force_source`: `defaults write app.molinete.aerio
    /// debug.aerio.epg_force_source -int <source id>` (or simctl spawn
    /// defaults) treats that one source as refreshed even when its stamp did
    /// not move.
    static let forceSourceDefaultsKey = "debug.aerio.epg_force_source"

    static var forcedSourceID: Int? {
        let v = UserDefaults.standard.integer(forKey: forceSourceDefaultsKey)
        return v > 0 ? v : nil
    }

    /// Progress key: the target fingerprint, plus the forced source so a
    /// forced measurement run never marks the real fingerprint's days done.
    static func progressKey(fingerprint: String) -> String {
        fingerprint + (forcedSourceID.map { "|force:\($0)" } ?? "")
    }

    private static func progressDefaultsKey(_ serverID: String) -> String { "epgSweepProgress.\(serverID)" }

    /// Days a sweep toward `key` already applied, so an interrupted sweep
    /// resumes at the next day instead of day 1.
    static func progress(serverID: String, key: String) -> Set<Date> {
        EPGSweepPlanner.decodeProgress(UserDefaults.standard.string(forKey: progressDefaultsKey(serverID)), key: key)
    }

    static func saveProgress(serverID: String, key: String, days: Set<Date>) {
        UserDefaults.standard.set(EPGSweepPlanner.encodeProgress(key: key, days: days),
                                  forKey: progressDefaultsKey(serverID))
    }

    static func clearProgress(serverID: String) {
        UserDefaults.standard.removeObject(forKey: progressDefaultsKey(serverID))
    }

    /// Lowercased tvg-ids fed by `sourceIDs`, from /api/epg/epgdata/. nil when
    /// the list could not be read; the caller stops rather than widening the
    /// sweep to every channel.
    static func keysForSources(api: DispatcharrAPI, sourceIDs: Set<Int>) async -> Set<String>? {
        do {
            let rows = try await api.getAllEPGDataRows()
            let keys = EPGSweepPlanner.keys(rows: rows.map { ($0.tvgID, $0.epgSource) }, sourceIDs: sourceIDs)
            debugLog("[EPG grid window] sweep scope: \(keys.count) channel key(s) fed by source(s) \(sourceIDs.sorted())")
            return keys
        } catch {
            debugLog("[EPG grid window] epgdata unreadable (\(error.localizedDescription)); sweep waits for the next gate")
            return nil
        }
    }

    /// Channel ids (ChannelDisplayItem.id) in scope for `keys`, through the
    /// grid maps' tvg-id lookup.
    static func channelIDs(forKeys keys: Set<String>, tvgIDToChannelIDs: [String: [String]]) -> Set<String> {
        var out = Set<String>()
        for (tvg, ids) in tvgIDToChannelIDs where keys.contains(tvg.lowercased()) {
            out.formUnion(ids)
        }
        return out
    }

    static func diffRow(_ p: EPGProgram) -> EPGDiffRow {
        EPGDiffRow(rowID: p.id.uuidString, channelID: p.channelID, start: p.startTime, end: p.endTime,
                   title: p.title, description: p.programDescription, subTitle: p.subTitle,
                   season: p.season, episode: p.episode, isNew: p.isNew,
                   isLiveBroadcast: p.isLiveBroadcast, isPremiere: p.isPremiere,
                   isFinale: p.isFinale, isRepeat: p.isRepeat, iconURL: p.posterURL,
                   category: p.category, programID: p.programID)
    }

    struct DayOutcome: Sendable {
        let fetchedInScope: Int, unchanged: Int, added: Int, changed: Int, removed: Int
        let writes: Int, idOnly: Int, diffMs: Int
    }

    /// Diff one day against the cached rows of the same span and write ONLY
    /// the additions, removals, and changes, plus in-place program id updates,
    /// in one save. Unchanged programs are never touched. Call off the main
    /// actor (inside EPGCacheWriteGate). nil when the save failed.
    static func applyDay(container: ModelContainer, serverID: String,
                         fetched: [EPGDiffRow], day: Date, dayEnd: Date,
                         inScope: ((String) -> Bool)?, now: Date,
                         channelIDs: Set<String>? = nil) -> DayOutcome? {
        let t0 = Date()
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        // `channelIDs` bounds the read (and so the diff) to a batch of
        // channels, for the launch save over a large resident map.
        let descriptor: FetchDescriptor<EPGProgram>
        if let channelIDs {
            descriptor = FetchDescriptor<EPGProgram>(predicate: #Predicate<EPGProgram> {
                $0.serverID == serverID && $0.endTime > day && $0.startTime < dayEnd
                    && channelIDs.contains($0.channelID)
            })
        } else {
            descriptor = FetchDescriptor<EPGProgram>(predicate: #Predicate<EPGProgram> {
                $0.serverID == serverID && $0.endTime > day && $0.startTime < dayEnd
            })
        }
        guard let cachedModels = try? ctx.fetch(descriptor) else { return nil }
        let cached = cachedModels.map(diffRow)
        let diff = EPGDayDiff.compute(fetched: fetched, cached: cached, inScope: inScope, now: now)
        if diff.writes > 0 || diff.remapped > 0 {
            var byID: [String: EPGProgram] = [:]
            byID.reserveCapacity(cachedModels.count)
            for m in cachedModels { byID[m.id.uuidString] = m }
            var byKey: [String: EPGProgram] = [:]
            for m in cachedModels { byKey["\(m.channelID)|\(m.startTime.timeIntervalSince1970)"] = m }
            for id in diff.deleteIDs { if let m = byID[id] { ctx.delete(m) } }
            for u in diff.programIDUpdates { byID[u.rowID]?.programID = u.programID }
            for r in diff.upserts {
                // Replace on (channel, start): a changed row updates in place.
                if let m = byKey["\(r.channelID)|\(r.start.timeIntervalSince1970)"] {
                    m.endTime = r.end; m.title = r.title; m.programDescription = r.description
                    m.subTitle = r.subTitle; m.season = r.season; m.episode = r.episode
                    m.isNew = r.isNew; m.isLiveBroadcast = r.isLiveBroadcast
                    m.isPremiere = r.isPremiere; m.isFinale = r.isFinale; m.isRepeat = r.isRepeat
                    m.posterURL = r.iconURL; m.programID = r.programID; m.fetchedAt = now
                    if !r.category.isEmpty { m.category = r.category }
                } else {
                    ctx.insert(EPGProgram(channelID: r.channelID, title: r.title, description: r.description,
                                          startTime: r.start, endTime: r.end, category: r.category,
                                          posterURL: r.iconURL, serverID: serverID, fetchedAt: now,
                                          programID: r.programID, subTitle: r.subTitle,
                                          season: r.season, episode: r.episode, isNew: r.isNew,
                                          isLiveBroadcast: r.isLiveBroadcast, isPremiere: r.isPremiere,
                                          isFinale: r.isFinale, isRepeat: r.isRepeat))
                }
            }
            do { try ctx.save() } catch {
                debugLog("[EPG grid window] sweep day write failed (\(error.localizedDescription)); stopping")
                return nil
            }
        }
        return DayOutcome(fetchedInScope: diff.fetchedInScope, unchanged: diff.unchanged,
                          added: diff.added, changed: diff.changed, removed: diff.removed,
                          writes: diff.writes, idOnly: diff.remapped,
                          diffMs: Int(Date().timeIntervalSince(t0) * 1000))
    }
}
