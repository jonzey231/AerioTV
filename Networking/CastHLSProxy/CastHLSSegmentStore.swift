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

    /// Which rendition of a cut a request names.
    enum Rendition { case video, audio }

    private struct SegmentEntry {
        let seq: Int
        let generation: Int
        /// The video rendition's span in 90 kHz ticks, i.e. its EXTINF.
        let durationTicks: Int64
        let discontinuity: Bool
        /// The two renditions of the same cut, one sequence number. The
        /// audio one is nil for a video-only mux.
        let videoData: Data
        let audioData: Data?
        /// The audio rendition's own EXTINF; within one audio frame of
        /// `durationTicks`.
        let audioDurationTicks: Int64
    }

    /// Guards the store; also what held segment fetches wait on.
    private let condition = NSCondition()
    private var ring: [SegmentEntry] = []
    /// False after `close`; wakes and fails any held segment fetch.
    private var storeOpen = true
    /// Init segments per generation, one per rendition.
    private var videoInits: [Int: Data] = [:]
    private var audioInits: [Int: Data] = [:]
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
        videoInits.removeAll()
        audioInits.removeAll()
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
        let oldGen = generation
        generation += 1
        let newGen = generation
        let lastSeq = nextSeq - 1
        let firstNewSeq = nextSeq
        pendingDiscontinuity = !ring.isEmpty
        segmentsInGeneration = 0
        mediaTicksInGeneration = 0
        // Incident 2026-09-25: wake held live-edge fetches on a roll so each
        // re-checks against the new generation instead of sleeping out its
        // whole timeout on a condition nobody may signal soon (the
        // reconnect gap was 4.5 s against a 6 s hold).
        condition.broadcast()
        condition.unlock()
        // Logged OUTSIDE the lock (incident 2026-09-25): the log closure
        // is caller code, and the lock also gates every NWListener
        // request, so it must never run under it.
        if oldGen > 0 {
            log("splice oldGen=\(oldGen) newGen=\(newGen) lastSeq=\(lastSeq) firstNewSeq=\(firstNewSeq)")
        }
        return newGen
    }

    /// Init segments for `gen`. `audio` is nil for a video-only
    /// mux, in which case the demuxed master carries no audio rendition.
    func setDemuxedInitSegments(generation gen: Int, video: Data, audio: Data?) {
        condition.lock()
        videoInits[gen] = video
        if let audio { audioInits[gen] = audio } else { audioInits.removeValue(forKey: gen) }
        condition.unlock()
    }

    /// Returns the sequence number the playlist will advertise for this
    /// segment, or nil when a stale generation was gated out. The sender
    /// log's per-segment timeline line names it (see
    /// `CastHLSProxySession.startIngestLocked`), so the proxy log and the
    /// playlist can be lined up by seq instead of by guesswork.
    @discardableResult
    func addSegment(generation gen: Int, durationTicks: Int64,
                    videoData: Data, audioData: Data?,
                    audioDurationTicks: Int64? = nil) -> Int? {
        condition.lock()
        defer { condition.unlock() }
        guard gen == generation else { return nil } // stale ingest racing a channel change
        let entry = SegmentEntry(seq: nextSeq, generation: gen,
                                 durationTicks: durationTicks,
                                 discontinuity: pendingDiscontinuity,
                                 videoData: videoData, audioData: audioData,
                                 audioDurationTicks: audioDurationTicks ?? durationTicks)
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
                videoInits.removeValue(forKey: evicted.generation)
                audioInits.removeValue(forKey: evicted.generation)
            }
        }
        segmentsInGeneration += 1
        mediaTicksInGeneration += durationTicks
        // Wake any held fetch for the sequence just published.
        condition.broadcast()
        return publishedSeq
    }

    /// Published segments after `seq` (the receiver's newest video fetch)
    /// and their media seconds: the runway the receiver has not pulled
    /// yet (link line, device log 2026-09-25 17:04).
    func runwayAfter(seq: Int) -> (count: Int, seconds: Double) {
        condition.lock()
        defer { condition.unlock() }
        let ahead = ring.filter { $0.seq > seq }
        let ticks = ahead.reduce(Int64(0)) { $0 + $1.durationTicks }
        return (ahead.count, Double(ticks) / Double(CastFMP4Remuxer.ticksPerSecond))
    }

    /// Video init segment for `gen`, or nil when no longer retained.
    func videoInitSegment(generation gen: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return videoInits[gen]
    }

    func audioInitSegment(generation gen: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return audioInits[gen]
    }

    /// Segment `seq`'s bytes. A fetch naming a sequence the ingest has
    /// not published yet, up to `maxFutureSegments` past the newest one,
    /// is held up to `timeout` instead of 404ing; anything already
    /// evicted from the ring or further in the future fails immediately.
    func awaitSegment(seq: Int, rendition: Rendition,
                      timeout: TimeInterval = CastHLSSegmentStore.nextSegmentWait) -> Data? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let entry = ring.first(where: { $0.seq == seq }) {
                switch rendition {
                case .video: return entry.videoData
                case .audio: return entry.audioData
                }
            }
            guard storeOpen, seq >= nextSeq, seq <= nextSeq + Self.maxFutureSegments else { return nil }
            guard Date() < deadline else { return nil }
            if !condition.wait(until: deadline) { return nil }
        }
    }

    // MARK: playlists

    /// DEMUXED master playlist: the only URL the sender loads (see
    /// `CastHLSProxySession.startChannel`). Two renditions, one
    /// SourceBuffer each, so the audio can declare ac-3 / ec-3 honestly on
    /// a receiver that answers isTypeSupported false for any muxed
    /// video/mp4 carrying those codecs but TRUE for audio/mp4 with them
    /// (measured on the Google TV Streamer, 2026-09-12).
    ///
    /// The audio codec comes from the AUDIO init's own sample entry, so it
    /// can never disagree with the bytes, and falls back to the attribute
    /// the session set. CLOSED-CAPTIONS=NONE exists for exactly one
    /// reason: without it Shaka turns on closed-caption detection and runs
    /// Mp4CeaParser over every video segment, which dies with
    /// BUFFER_READ_OUT_OF_BOUNDS (Shaka Error 3000) tens of seconds in
    /// (device-verified on a Google TV Streamer).
    func demuxedMasterPlaylistText() -> String {
        condition.lock()
        let videoInit = videoInits[generation]
        let audioInit = audioInits[generation]
        let attribute = audioCodecsAttribute
        condition.unlock()
        let videoCodec = videoInit.flatMap { Self.avcCodecString(from: $0) } ?? "avc1.640028"
        let audioCodec = audioInit.flatMap { Self.audioCodecString(from: $0) } ?? attribute
        var text = "#EXTM3U\n"
        if audioCodec != nil {
            text += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Main\","
                + "DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n"
        }
        text += "#EXT-X-STREAM-INF:BANDWIDTH=12000000,CODECS=\"\(videoCodec)"
        if let audioCodec { text += ",\(audioCodec)" }
        text += "\""
        if audioCodec != nil { text += ",AUDIO=\"aud\"" }
        text += ",CLOSED-CAPTIONS=NONE\n"
        text += "video.m3u8\n"
        return text
    }

    /// RFC 6381 audio codec string from an init segment's audio sample
    /// entry: ac-3 / ec-3 for the passthrough paths, mp4a.40.2 for AAC-LC
    /// (the only AAC profile an ADTS IPTV mux carries in practice).
    static func audioCodecString(from initSegment: Data) -> String? {
        if contains(initSegment, "ac-3") { return "ac-3" }
        if contains(initSegment, "ec-3") { return "ec-3" }
        if contains(initSegment, "mp4a") { return "mp4a.40.2" }
        return nil
    }

    private static func contains(_ data: Data, _ type: String) -> Bool {
        let needle = [UInt8](type.utf8)
        let bytes = [UInt8](data)
        guard bytes.count >= needle.count else { return false }
        for i in 0...(bytes.count - needle.count) {
            var hit = true
            for j in 0..<needle.count where bytes[i + j] != needle[j] { hit = false; break }
            if hit { return true }
        }
        return false
    }

    /// Audio codec name for the demuxed master's CODECS attribute, set
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

    /// The video-only media playlist the demuxed master's STREAM-INF
    /// points at.
    func videoPlaylistText() -> String { mediaPlaylistText(.video) }

    /// The audio-only media playlist the demuxed master's EXT-X-MEDIA
    /// points at. Identical sequence numbering, target duration and
    /// discontinuity tags to `videoPlaylistText`; only the EXTINF values
    /// differ, by less than one audio frame.
    func audioPlaylistText() -> String { mediaPlaylistText(.audio) }

    private func mediaPlaylistText(_ rendition: Rendition) -> String {
        condition.lock()
        defer { condition.unlock() }
        let initPrefix: String
        let segPrefix: String
        switch rendition {
        case .video: initPrefix = "vinit"; segPrefix = "vseg"
        case .audio: initPrefix = "ainit"; segPrefix = "aseg"
        }
        let window = Array(ring.suffix(Self.windowSize))
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        // Deliberately the max over BOTH renditions' spans, so the two
        // demuxed playlists advertise the SAME target duration even though
        // their EXTINF values differ by up to an audio frame.
        let targetSeconds = window
            .map {
                Int((Double(max($0.durationTicks, $0.audioDurationTicks))
                    / Double(CastFMP4Remuxer.ticksPerSecond)).rounded(.up))
            }
            .max().map { max(1, $0) } ?? 4
        text += "#EXT-X-TARGETDURATION:\(targetSeconds)\n"
        // Explicit HOLD-BACK (2026-09-21) at the RFC 8216bis minimum of three
        // target durations, identical on both renditions, so the receiver's
        // live join point is stated by the playlist instead of left to each
        // player's default; CAN-BLOCK-RELOAD=NO because the proxy does not
        // implement blocking playlist reload (_HLS_msn).
        text += "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=NO,HOLD-BACK="
            + String(format: "%.3f", Double(targetSeconds * 3)) + "\n"
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
            // NO EXT-X-PROGRAM-DATE-TIME, deliberately (added a6a443f,
            // removed the same day). The anchor it was derived from was the
            // wall clock at the moment a segment was STORED, which is one
            // whole segment later than the media that segment begins with,
            // so every stamp ran a segment ahead of the media it described.
            // Shaka treats a PDT as the authority for segment POSITIONS
            // (hls_parser.js createSegments_ -> SegmentReference.syncAgainst
            // and setInitialProgramDateTime in determineDuration_), so its
            // live window slid a segment past the media in the buffer: the
            // receiver reported seek=[51.368-52.373] against
            // buffered=[46.537-51.593] with the playhead at 51.357, outside
            // its own seek range and permanently BUFFERING. Without the tag
            // Shaka positions segments by accumulated EXTINF from media time
            // 0, which is where our tfdt timestamps already put them, and
            // the same playlist reached PLAYING (session10).
            if seg.generation != lastGen {
                text += "#EXT-X-MAP:URI=\"\(initPrefix)\(seg.generation).mp4\"\n"
                lastGen = seg.generation
            }
            let ticks = rendition == .audio ? seg.audioDurationTicks : seg.durationTicks
            let seconds = Double(ticks) / Double(CastFMP4Remuxer.ticksPerSecond)
            text += "#EXTINF:\(String(format: "%.3f", seconds)),\n"
            text += "\(segPrefix)\(seg.seq).m4s\n"
        }
        // LIVE playlist: no EXT-X-ENDLIST, ever; the advancing
        // MEDIA-SEQUENCE is the manifest clock a progressive URL lacks.
        return text
    }
}

/// Receiver request counters for the stale-receiver check (iOS incident
/// 2026-09-25 15:26: a Cast session attached to a receiver page that fetched
/// the master and both rendition playlists once, two segments, and then
/// nothing while the proxy kept producing). The sender marks each accepted
/// load and reads the counts 10 s later; a playlist with no segment means
/// the page is stale and the load is re-issued once. Thread-safe (the serve
/// queue is concurrent). Android parity: CastHlsProxyServer's
/// playlistFetches / segmentFetches (963e5ed6).
final class CastHLSRequestCounters: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var generation: Int
        var playlists: Int
        var videoSegments: Int
        var audioSegments: Int
        /// Time of the first segment request since the mark, nil if none.
        var firstSegmentAt: Date?
        /// Time of the most recent segment request since the mark.
        var lastSegmentAt: Date?
        var markedAt: Date
        var segments: Int { videoSegments + audioSegments }
    }

    enum Kind { case playlist, videoSegment, audioSegment, other }

    private let lock = NSLock()
    private var current: Snapshot

    init(now: Date = Date()) {
        current = Snapshot(generation: 0, playlists: 0, videoSegments: 0, audioSegments: 0,
                           firstSegmentAt: nil, lastSegmentAt: nil, markedAt: now)
    }

    /// Classify a request path the way the server routes it.
    static func kind(of path: String) -> Kind {
        if path.hasSuffix(".m3u8") { return .playlist }
        if path.hasPrefix("/vseg") && path.hasSuffix(".m4s") { return .videoSegment }
        if path.hasPrefix("/aseg") && path.hasSuffix(".m4s") { return .audioSegment }
        return .other
    }

    /// Count one request (called when it arrives, before any live-edge hold).
    func record(path: String, now: Date = Date()) {
        let kind = Self.kind(of: path)
        guard kind != .other else { return }
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .playlist: current.playlists += 1
        case .videoSegment: current.videoSegments += 1
        case .audioSegment: current.audioSegments += 1
        case .other: break
        }
        if kind != .playlist {
            if current.firstSegmentAt == nil { current.firstSegmentAt = now }
            current.lastSegmentAt = now
        }
    }

    /// Reset the counts at an accepted load for `generation`.
    func mark(generation: Int, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        current = Snapshot(generation: generation, playlists: 0, videoSegments: 0, audioSegments: 0,
                           firstSegmentAt: nil, lastSegmentAt: nil, markedAt: now)
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}
