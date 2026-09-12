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

    /// Bound on holding a segment GET that names a sequence the ingest
    /// has not published yet (the receiver racing the live edge);
    /// segments land every ~3 s, so 6 s covers a slow cut without
    /// pinning threads.
    static let nextSegmentWait: TimeInterval = 6.0

    /// How far past the newest published sequence a fetch may name and
    /// still be held rather than 404ed. A 404 is not a harmless retry for
    /// this receiver: Shaka drops the segment and re-syncs to the live
    /// edge, which SKIPS segments, and a skipped segment in MSE
    /// 'sequence' AppendMode leaves a hole in the buffered range too
    /// small for the gap jumper to notice and too large for the video
    /// renderer to cross (measured in Chromium: 0.147 s). Two segments of
    /// slack cost nothing and remove the trigger.
    static let maxFutureSegments = 2

    private struct SegmentEntry {
        let seq: Int
        let generation: Int
        let data: Data
        let durationTicks: Int64
        let discontinuity: Bool
        /// This segment's accumulated media START within its generation, in
        /// 90 kHz ticks (0 for the generation's first segment). Added
        /// 2026-09-12 so the playlist can carry an absolute
        /// EXT-X-PROGRAM-DATE-TIME per segment; see `mediaPlaylistText`.
        let mediaStartTicks: Int64
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

    /// Wall-clock anchor per generation: `Date()` captured when that
    /// generation's FIRST segment is stored. A generation's segment at
    /// media offset `mediaStartTicks` therefore sits at
    /// `anchor + mediaStartTicks / 90000` on an absolute clock, which is
    /// what EXT-X-PROGRAM-DATE-TIME advertises. Evicted alongside the
    /// generation's init segment.
    private var generationAnchors: [Int: Date] = [:]

    /// ISO-8601 with milliseconds and a UTC offset, the only shape HLS
    /// allows for EXT-X-PROGRAM-DATE-TIME (RFC 8216 section 4.3.2.6).
    /// nonisolated(unsafe): every read happens inside `mediaPlaylistText`,
    /// which holds `condition`, so the formatter is never touched
    /// concurrently.
    nonisolated(unsafe) private static let programDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    /// Segments committed since the last `beginGeneration`.
    private(set) var segmentsInGeneration = 0

    /// MEDIA DURATION committed since the last `beginGeneration`, in 90 kHz
    /// ticks. The load gate is a duration, not a segment count: our cuts
    /// land on keyframes, not on the 3 s target, and on a real broadcast
    /// feed the first three segments were 5.005 s, 4.338 s and 3.170 s
    /// (iPhone proxy log, 2026-09-12 14:22:19.361), so a 3-segment gate
    /// made the user wait 11.5 s for 12.5 s of media where 9 s would do.
    private(set) var mediaTicksInGeneration: Int64 = 0

    /// Both gate inputs read under one lock, so the count and the duration
    /// can never disagree about the same segment.
    var currentReadyState: (segments: Int, mediaTicks: Int64) {
        condition.lock()
        defer { condition.unlock() }
        return (segmentsInGeneration, mediaTicksInGeneration)
    }

    /// Fails any held live-edge fetch on session teardown.
    func close() {
        condition.lock()
        ring.removeAll()
        inits.removeAll()
        generationAnchors.removeAll()
        segmentsInGeneration = 0
        mediaTicksInGeneration = 0
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
        mediaTicksInGeneration = 0
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

    /// Returns the sequence number the playlist will advertise for this
    /// segment, or nil when a stale generation was gated out. The sender
    /// log's per-segment timeline line names it (see
    /// `CastHLSProxySession.startIngestLocked`), so the proxy log and the
    /// playlist can be lined up by seq instead of by guesswork.
    @discardableResult
    func addSegment(generation gen: Int, data: Data, durationTicks: Int64) -> Int? {
        condition.lock()
        defer { condition.unlock() }
        guard gen == generation else { return nil } // stale ingest racing a channel change
        // First segment of this generation: stamp the wall-clock anchor
        // every later segment's EXT-X-PROGRAM-DATE-TIME is derived from.
        if generationAnchors[gen] == nil { generationAnchors[gen] = Date() }
        // `mediaTicksInGeneration` is still the total BEFORE this segment,
        // which is exactly this segment's accumulated media start.
        let entry = SegmentEntry(seq: nextSeq, generation: gen, data: data,
                                 durationTicks: durationTicks,
                                 discontinuity: pendingDiscontinuity,
                                 mediaStartTicks: mediaTicksInGeneration)
        let publishedSeq = nextSeq
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
                // The anchor is only ever read for a segment still in the
                // window, so it dies with its generation's last segment.
                generationAnchors.removeValue(forKey: evicted.generation)
            }
        }
        segmentsInGeneration += 1
        mediaTicksInGeneration += durationTicks
        // Wake any held fetch for the sequence just published.
        condition.broadcast()
        return publishedSeq
    }

    /// Init segment for `gen`, or nil when no longer retained.
    func initSegment(generation gen: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return inits[gen]
    }

    /// Segment `seq`'s bytes. A fetch naming a sequence the ingest has
    /// not published yet, up to `maxFutureSegments` past the newest one,
    /// is held up to `timeout` instead of 404ing; anything already
    /// evicted from the ring or further in the future fails immediately.
    func awaitSegment(seq: Int, timeout: TimeInterval = CastHLSSegmentStore.nextSegmentWait) -> Data? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let entry = ring.first(where: { $0.seq == seq }) { return entry.data }
            guard storeOpen, seq >= nextSeq, seq <= nextSeq + Self.maxFutureSegments else { return nil }
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
        let audio = audioCodecsAttribute
        condition.unlock()
        var codecs = initData.flatMap { Self.avcCodecString(from: $0) } ?? "avc1.640028"
        // The audio codec MUST match what the segments carry (mp4a.40.2
        // for AAC, ac-3 / ec-3 for a passthrough) or the receiver picks
        // the wrong decoder and plays video with no sound.
        if let audio { codecs += ",\(audio)" }
        return "#EXTM3U\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=12000000,CODECS=\"\(codecs)\",CLOSED-CAPTIONS=NONE\n"
            + "live.m3u8\n"
    }

    /// Audio codec name for the master playlist's CODECS attribute, set
    /// by the session from the remuxer once the audio path is known
    /// ("mp4a.40.2", "ac-3", "ec-3", or nil for a video-only mux).
    /// Defaults to AAC: the passthrough remux is the exception, and a
    /// playlist fetched before the first init segment must still name a
    /// plausible codec.
    private var audioCodecsAttribute: String? = "mp4a.40.2"

    func setAudioCodecsAttribute(_ value: String?) {
        condition.lock()
        audioCodecsAttribute = value
        condition.unlock()
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
        for (index, seg) in window.enumerated() {
            // The tag stays attached to its segment for as long as the
            // segment is in the window; DISCONTINUITY-SEQUENCE above only
            // accounts for flagged segments that have rolled out.
            if seg.discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
            // EXT-X-PROGRAM-DATE-TIME on the window's first segment, and
            // again immediately after every discontinuity (each one
            // restarts the media timeline, so the following segment needs
            // its own generation's anchor).
            //
            // Why it exists (added 2026-09-12): with
            // manifest.hls.sequenceMode=false Shaka takes segment
            // TIMESTAMPS from the media (our tfdt boxes) and segment
            // POSITIONS from the playlist (accumulated EXTINF from 0), and
            // without an absolute clock nothing reconciles the two. On the
            // 15:10:03 Google TV Streamer session Shaka assumed the window
            // started at media time 0, chose a start position of 2.439 s
            // (11.311 s window minus the 9 s presentation delay) before a
            // single byte of media was appended, then had to relocate to
            // 0.016 s (the first audio sample's own time,
            // MediaGapJumped=1) and sat at -58 ms in BUFFERING for 45 s.
            // PROGRAM-DATE-TIME gives it the absolute clock that ties the
            // playlist position to the segments' own timestamps.
            if index == 0 || seg.discontinuity, let anchor = generationAnchors[seg.generation] {
                let offset = Double(seg.mediaStartTicks) / Double(CastFMP4Remuxer.ticksPerSecond)
                let stamp = Self.programDateFormatter.string(from: anchor.addingTimeInterval(offset))
                text += "#EXT-X-PROGRAM-DATE-TIME:\(stamp)\n"
            }
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
