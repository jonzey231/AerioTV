//
//  CastHLSSegmentStore.swift
//  Aerio
//
//  Segment ring + playlist generation for the phone-local cast HLS proxy
//  (GH #33 web-receiver rework). Pure logic, no networking, so the
//  splice/eviction/playlist behavior is unit-testable off-device.
//

import Foundation

/// Thread-safe store of the last few CMAF segments plus their playlists.
///
/// Generations exist because a reconnect or channel change restarts the
/// remuxer: the new ingest gets a fresh init segment and its first
/// segment is flagged as a playlist discontinuity, so the receiver
/// resets its timeline instead of chasing a clock that jumped.
///
/// One channel at a time: `beginGeneration` (channel change or ingest
/// reconnect) keeps the ring, so the receiver's next playlist poll sees
/// a window that still lists the old-generation segments it was
/// promised, then a discontinuity into the new generation at the same
/// URL. Sequence numbers are claimed only at publish time, so a splice
/// can never leave a numbering gap (a gap means the receiver 404s and
/// Shaka fatals).
final class CastHLSSegmentStore: @unchecked Sendable {

    /// Segments advertised in the playlist.
    static let windowSize = 5

    /// Segments retained in memory; the extra tail past the window lets
    /// a receiver that is a poll behind still fetch what the previous
    /// playlist advertised.
    static let ringSize = 8

    /// Bound on holding a segment GET that names the imminent next
    /// sequence (the receiver racing the live edge); segments land every
    /// ~3 s, so 6 s covers a slow cut without pinning threads.
    static let nextSegmentWait: TimeInterval = 6.0

    private struct SegmentEntry {
        let seq: Int
        let generation: Int
        let data: Data
        let durationTicks: Int64
        let discontinuity: Bool
    }

    /// Guards the store; also what held segment fetches wait on.
    private let condition = NSCondition()
    private var ring: [SegmentEntry] = []
    /// False after `close`; wakes and fails any held segment fetch.
    private var storeOpen = true
    private var inits: [Int: Data] = [:]
    private var nextSeq = 0
    private var generation = 0
    /// First segment committed after `beginGeneration` gets the
    /// discontinuity flag (reconnect splice or channel change).
    private var pendingDiscontinuity = false
    /// EXT-X-DISCONTINUITY-SEQUENCE: count of flagged segments that have
    /// fully rolled out of the ring.
    private var discontinuitySequence = 0

    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    /// Segments committed since the last `beginGeneration`; the sender
    /// gates loadMedia on this reaching 2.
    private(set) var segmentsInGeneration = 0

    var currentSegmentsInGeneration: Int {
        condition.lock()
        defer { condition.unlock() }
        return segmentsInGeneration
    }

    /// Fails any held live-edge fetch on session teardown.
    func close() {
        condition.lock()
        ring.removeAll()
        inits.removeAll()
        segmentsInGeneration = 0
        storeOpen = false
        condition.broadcast()
        condition.unlock()
    }

    // MARK: store (called from the ingest queue)

    /// Start a new ingest generation (channel change or same-channel
    /// reconnect). The ring is deliberately NOT cleared: the receiver's
    /// cached playlist still promises the old-generation segments, and
    /// wiping them mid-splice is exactly the 404 -> Shaka fatal ->
    /// reload this proxy exists to avoid. Old segments (and their init)
    /// age out of the ring naturally; the discontinuity tag plus the new
    /// EXT-X-MAP cover the timeline and codec change, and `addSegment`'s
    /// generation gate keeps a stale ingest from ever claiming a
    /// sequence number, so numbering stays gap-free.
    @discardableResult
    func beginGeneration() -> Int {
        condition.lock()
        defer { condition.unlock() }
        let oldGen = generation
        generation += 1
        pendingDiscontinuity = !ring.isEmpty
        segmentsInGeneration = 0
        if oldGen > 0 {
            log("splice oldGen=\(oldGen) newGen=\(generation) lastSeq=\(nextSeq - 1) firstNewSeq=\(nextSeq)")
        }
        return generation
    }

    func setInitSegment(generation gen: Int, data: Data) {
        condition.lock()
        inits[gen] = data
        condition.unlock()
    }

    func addSegment(generation gen: Int, data: Data, durationTicks: Int64) {
        condition.lock()
        defer { condition.unlock() }
        guard gen == generation else { return } // stale ingest racing a channel change
        let entry = SegmentEntry(seq: nextSeq, generation: gen, data: data,
                                 durationTicks: durationTicks,
                                 discontinuity: pendingDiscontinuity)
        nextSeq += 1
        pendingDiscontinuity = false
        ring.append(entry)
        while ring.count > Self.ringSize {
            let evicted = ring.removeFirst()
            if evicted.discontinuity { discontinuitySequence += 1 }
            // Drop init segments no ring entry references any more.
            if !ring.contains(where: { $0.generation == evicted.generation }),
               evicted.generation != generation {
                inits.removeValue(forKey: evicted.generation)
            }
        }
        segmentsInGeneration += 1
        // Wake any held fetch for the sequence just published.
        condition.broadcast()
    }

    /// Init segment for `gen`, or nil when no longer retained.
    func initSegment(generation gen: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return inits[gen]
    }

    /// Segment `seq`'s bytes. A fetch naming the imminent NEXT sequence
    /// (newest+1, the receiver racing the live edge) is held up to
    /// `timeout` for the ingest to publish it instead of 404ing;
    /// anything already evicted from the ring or further in the future
    /// fails immediately.
    func awaitSegment(seq: Int, timeout: TimeInterval = CastHLSSegmentStore.nextSegmentWait) -> Data? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let entry = ring.first(where: { $0.seq == seq }) { return entry.data }
            guard storeOpen, seq == nextSeq else { return nil }
            guard Date() < deadline else { return nil }
            if !condition.wait(until: deadline) { return nil }
        }
    }

    // MARK: playlists

    /// Master playlist wrapping the media playlist. Exists for exactly
    /// one reason: CLOSED-CAPTIONS=NONE. With a media-only playlist
    /// Shaka turns on closed-caption detection and runs Mp4CeaParser
    /// over every video segment; that parser walks our muxed two-traf
    /// segments as if the whole mdat were video NALs and dies with
    /// BUFFER_READ_OUT_OF_BOUNDS (Shaka Error 3000), killing playback
    /// tens of seconds in (device-verified on a Google TV Streamer).
    /// NONE disables the detection entirely. The sender must load THIS
    /// URL, never live.m3u8 directly.
    func masterPlaylistText() -> String {
        condition.lock()
        let initData = inits[generation]
        condition.unlock()
        let codecs = initData.flatMap { Self.avcCodecString(from: $0) } ?? "avc1.640028"
        return "#EXTM3U\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=12000000,CODECS=\"\(codecs),mp4a.40.2\",CLOSED-CAPTIONS=NONE\n"
            + "live.m3u8\n"
    }

    /// avc1.PPCCLL from the avcC box inside an init segment (profile,
    /// constraint flags, level right after the configuration version).
    static func avcCodecString(from initSegment: Data) -> String? {
        let bytes = [UInt8](initSegment)
        guard bytes.count >= 8 else { return nil }
        for i in 0...(bytes.count - 8) where bytes[i] == 0x61 && bytes[i + 1] == 0x76
            && bytes[i + 2] == 0x63 && bytes[i + 3] == 0x43 {
            guard i + 8 < bytes.count else { return nil }
            return String(format: "avc1.%02X%02X%02X", bytes[i + 5], bytes[i + 6], bytes[i + 7])
        }
        return nil
    }

    func mediaPlaylistText() -> String {
        condition.lock()
        defer { condition.unlock() }
        let window = Array(ring.suffix(Self.windowSize))
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        let targetSeconds = window
            .map { Int((Double($0.durationTicks) / Double(CastFMP4Remuxer.ticksPerSecond)).rounded(.up)) }
            .max().map { max(1, $0) } ?? 4
        text += "#EXT-X-TARGETDURATION:\(targetSeconds)\n"
        text += "#EXT-X-MEDIA-SEQUENCE:\(window.first?.seq ?? nextSeq)\n"
        if discontinuitySequence > 0 {
            text += "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)\n"
        }
        var lastGen = -1
        for seg in window {
            // The tag stays attached to its segment for as long as the
            // segment is in the window; DISCONTINUITY-SEQUENCE above only
            // accounts for flagged segments that have rolled out.
            if seg.discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
            if seg.generation != lastGen {
                text += "#EXT-X-MAP:URI=\"init\(seg.generation).mp4\"\n"
                lastGen = seg.generation
            }
            let seconds = Double(seg.durationTicks) / Double(CastFMP4Remuxer.ticksPerSecond)
            text += "#EXTINF:\(String(format: "%.3f", seconds)),\n"
            text += "seg\(seg.seq).m4s\n"
        }
        // LIVE playlist: no EXT-X-ENDLIST, ever; the advancing
        // MEDIA-SEQUENCE is the manifest clock a progressive URL lacks.
        return text
    }
}
