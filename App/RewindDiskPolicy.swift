// RewindDiskPolicy.swift
// Pure arithmetic for the Live Rewind and catch-up spool disk caps.
//
// Field report 2026-11-08: the macOS (iPad app) container reached 43.64 GB
// and dropped to 55 MB on relaunch, because Live Rewind session folders
// orphaned by a window close or force quit piled up between launches and
// the only "budget" was current usage plus free space above 2 GB, which
// never trims on a large disk. These rules give the buffer a real ceiling.
//
// No app singletons, no UIKit: Scripts/cast-hls-proxy-tests compiles this
// file directly and tests it.

import Foundation

enum RewindDiskPolicy {
    static let gib: Int64 = 1024 * 1024 * 1024

    /// Fixed ceiling across every rewind session on disk.
    static var platformCeilingBytes: Int64 {
        #if os(tvOS)
        return 8 * gib
        #else
        return 16 * gib
        #endif
    }

    /// Catch-up spool ceiling (all spool files together).
    static let spoolCeilingBytes: Int64 = 4 * gib

    /// Free-space floor kept on the volume (the old seatbelt, now an
    /// additional limit rather than the only one).
    static let freeSpaceFloorBytes: Int64 = 2 * gib

    /// Most channels that can roll a rewind window at once (the playing
    /// one plus Keep Recent Channels Live, capped at 5).
    static let maxChannels: Int64 = 5

    /// Allowance used before any bitrate is measured: 10 Mbps.
    static let defaultBytesPerSecond: Double = 10_000_000 / 8
    /// Headroom over the measured peak bitrate (VBR bursts).
    static let bitrateHeadroom: Double = 1.25

    /// Bytes per second budgeted per channel, from the highest bitrate
    /// measured across the running sessions (nil or 0 = not yet measured).
    static func allowanceBytesPerSecond(measuredPeak: Double?) -> Double {
        guard let m = measuredPeak, m > 0, m.isFinite else { return defaultBytesPerSecond }
        return m * bitrateHeadroom
    }

    /// The total cap: the smaller of depth x channels x allowance and the
    /// platform ceiling, further limited by the free-space floor when the
    /// free space is known (usage counts as reclaimable).
    static func capBytes(depthSeconds: Double,
                         allowanceBytesPerSecond: Double,
                         ceilingBytes: Int64 = platformCeilingBytes,
                         usageBytes: Int64,
                         freeBytes: Int64?,
                         floorBytes: Int64 = freeSpaceFloorBytes) -> Int64 {
        let depth = max(0, depthSeconds)
        let byDepthD = depth * Double(maxChannels) * max(0, allowanceBytesPerSecond)
        let byDepth = byDepthD >= Double(Int64.max) ? Int64.max : Int64(byDepthD)
        var cap = min(byDepth, ceilingBytes)
        if let free = freeBytes {
            cap = min(cap, max(0, usageBytes) + max(0, free - floorBytes))
        }
        return max(0, cap)
    }

    /// One rewind session as the trimmer sees it.
    struct Session: Equatable {
        var id: String
        /// Creation time (ms); older sessions are trimmed first.
        var createdMs: Int64
        /// True for the session the viewer is watching; retained (Keep
        /// Recent Channels Live) and orphaned sessions are non-active.
        var active: Bool
        /// Segment sizes, oldest first.
        var segmentBytes: [Int64]
        /// Segments that must survive trimming (the live window).
        /// Orphaned sessions use 0.
        var keepMin: Int
        var totalBytes: Int64 { segmentBytes.reduce(0, +) }
    }

    /// How many oldest segments to drop from each session (by id) to get
    /// the total under `capBytes`. Order: oldest non-active session first,
    /// oldest segment first; then active sessions (oldest first), never
    /// below their `keepMin`. Sessions not listed need nothing dropped.
    static func planTrim(sessions: [Session], capBytes: Int64) -> [String: Int] {
        var total = sessions.reduce(Int64(0)) { $0 + $1.totalBytes }
        var plan: [String: Int] = [:]
        guard total > capBytes else { return plan }
        let ordered = sessions.filter { !$0.active }.sorted { $0.createdMs < $1.createdMs }
            + sessions.filter { $0.active }.sorted { $0.createdMs < $1.createdMs }
        for s in ordered {
            if total <= capBytes { break }
            let droppable = max(0, s.segmentBytes.count - max(0, s.keepMin))
            var n = 0
            while n < droppable, total > capBytes {
                total -= s.segmentBytes[n]
                n += 1
            }
            if n > 0 { plan[s.id] = n }
        }
        return plan
    }

    /// Bytes the active spool may still accept, given the other spool
    /// files on disk and the ceiling.
    static func spoolRoom(written: Int64, otherSpoolBytes: Int64,
                          ceilingBytes: Int64 = spoolCeilingBytes) -> Int64 {
        max(0, ceilingBytes - max(0, otherSpoolBytes) - max(0, written))
    }

    /// One spool file for the leftover trim.
    struct SpoolFile: Equatable {
        var name: String
        var mtimeMs: Int64
        var bytes: Int64
        var owned: Bool
    }

    /// Spool files to delete: every unowned file (no process but this one
    /// can be reading it), then owned files oldest first until the total
    /// fits the ceiling. The newest owned file is never selected.
    static func spoolDeletions(files: [SpoolFile], ceilingBytes: Int64 = spoolCeilingBytes) -> [String] {
        var out: [String] = []
        var total: Int64 = 0
        var owned: [SpoolFile] = []
        for f in files {
            if f.owned { owned.append(f); total += f.bytes } else { out.append(f.name) }
        }
        let sorted = owned.sorted { $0.mtimeMs < $1.mtimeMs }
        for f in sorted.dropLast() where total > ceilingBytes {
            out.append(f.name)
            total -= f.bytes
        }
        return out
    }

    /// Launch / runtime sweep selection: every entry not owned by this
    /// process goes, regardless of age (sessions never survive a process).
    static func orphans(names: [String], owned: Set<String>) -> [String] {
        names.filter { !owned.contains($0) }
    }
}
