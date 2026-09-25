//
//  AirPlayAACVariant.swift
//  Aerio
//
//  The `airplay-aac` variant of a live TSHLSRemuxer session (rebuilt
//  2026-09-24 from the 2026-09-21 phone log). Pure logic plus the shared
//  Cast remux/transcode classes, no networking and no app singletons, so
//  the CLI harness in Scripts/cast-hls-proxy-tests compiles it as is.
//

import Foundation

/// A demuxed fMP4 HLS rendition pair of the SAME live ingest a
/// `TSHLSRemuxer` is already serving, with the audio re-encoded to AAC-LC
/// stereo, for AirPlay receivers that cannot decode AC-3 / E-AC-3 (Roku).
///
/// Nothing here opens a second upstream connection: the remuxer tees the
/// raw TS it ingests into `feed(_:)` (and primes the variant from the TS
/// segments it has buffered), and this class runs it through the Cast
/// proxy's `CastFMP4Remuxer` with `transcodeAC3` into a
/// `CastHLSSegmentStore`. The Cast classes are reused as is, never forked:
/// the transcoder log lines ("transcoding ...", "audio codecs up ...",
/// "audio census ...", "splice tail ...") reach the device log through
/// the `airplay-aac` prefix the owner's log closure adds.
///
/// Served under `/aac/` on the remuxer's LAN listener: `master.m3u8`,
/// `video.m3u8`, `audio.m3u8`, `vinitN.mp4`, `ainitN.mp4`, `vsegN.m4s`,
/// `asegN.m4s`.
///
/// Threading: `feed`, `prime`, `stop` hop onto the variant's own serial
/// queue (the transcode never runs on the ingest queue). `serve` may block
/// up to `CastHLSSegmentStore.nextSegmentWait` on a live-edge segment and
/// must be called off every serial queue that matters.
final class AirPlayAACVariant: @unchecked Sendable {

    /// ~5 s segments (plan open question 7); cuts land on keyframes, so
    /// the playlist target reads 5-7 s in practice.
    static let targetSegmentSeconds: Int64 = 5
    /// Segments that must exist before the player is pointed at the
    /// variant, unless the hold-back is already covered.
    static let readySegments = 3

    /// "AC-3", "E-AC-3": what the TS arm's PMT declared.
    let sourceCodecName: String

    private let queue = DispatchQueue(label: "com.aerio.airplay-aac")
    private let log: (String) -> Void
    private let store: CastHLSSegmentStore
    private var remuxer: CastFMP4Remuxer?
    private var generation = 0
    private var stopped = false
    private var failed = false

    /// Mirror of the store's ring (same size, same eviction), for the
    /// readiness gate and the status line.
    private struct Entry {
        let seq: Int
        let videoTicks: Int64
        let audioTicks: Int64
        let audioSamples: Int
    }
    private let stateLock = NSLock()
    private var ring: [Entry] = []
    private var pendingComposition: (video: Int, audio: Int)?
    private var lastComposition: (video: Int, audio: Int) = (0, 0)
    private var emittedVideoTicks: Int64 = 0
    private var emittedAudioTicks: Int64 = 0
    private var audioUnits = 0
    private var served: [String: Int] = [:]
    private var audioPath: String?
    private var servingTimer: DispatchSourceTimer?

    /// `transcoderFactory` is for the CLI tests only; production builds
    /// the real AudioToolbox transcoder.
    init(sourceCodecName: String,
         log: @escaping (String) -> Void,
         transcoderFactory: ((CastAudioSourceCodec,
                              @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
                              @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void) -> CastAudioTranscoding)? = nil) {
        self.sourceCodecName = sourceCodecName
        self.log = log
        self.store = CastHLSSegmentStore(log: log)
        let remuxer = CastFMP4Remuxer(
            targetSegmentTicks: Self.targetSegmentSeconds * CastFMP4Remuxer.ticksPerSecond,
            allowAC3Passthrough: false,
            transcodeAC3: true,
            log: log,
            transcoderFactory: transcoderFactory)
        self.remuxer = remuxer
        generation = store.beginGeneration()
        let gen = generation
        remuxer.onDemuxedInitSegments = { [weak self, weak remuxer] video, audio in
            guard let self else { return }
            self.store.setDemuxedInitSegments(generation: gen, video: video, audio: audio)
            self.store.setAudioCodecsAttribute(remuxer?.audioCodecsAttribute)
            let path = remuxer?.audioPathDescription ?? "\(self.sourceCodecName) -> AAC stereo"
            self.stateLock.lock(); self.audioPath = path; self.stateLock.unlock()
            self.log("init ready (\(path))")
        }
        remuxer.onSegmentComposition = { [weak self] video, audio, _, _, _, _ in
            self?.pendingComposition = (video, audio)
        }
        remuxer.onDemuxedMediaSegments = { [weak self] video, audio, videoTicks, audioTicks in
            guard let self else { return }
            let composition = self.pendingComposition ?? (0, 0)
            self.pendingComposition = nil
            guard let seq = self.store.addSegment(generation: gen, durationTicks: videoTicks,
                                                  videoData: video, audioData: audio,
                                                  audioDurationTicks: audioTicks) else { return }
            self.stateLock.lock()
            self.ring.append(Entry(seq: seq, videoTicks: videoTicks, audioTicks: audioTicks,
                                   audioSamples: composition.audio))
            while self.ring.count > CastHLSSegmentStore.ringSize { self.ring.removeFirst() }
            self.lastComposition = composition
            self.emittedVideoTicks += videoTicks
            self.emittedAudioTicks += audioTicks
            self.audioUnits += composition.audio
            self.stateLock.unlock()
        }
    }

    // MARK: Lifecycle (any thread)

    /// `variant started (source AC-3)`, then the buffered TS window so the
    /// receiver does not wait a whole hold-back for fresh media.
    /// `segments` are the remuxer's closed TS segments (each opens on a
    /// keyframe with PAT/PMT), oldest first; `tail` is the open segment
    /// plus any withheld audio packets, fed right after them.
    func start(primeSegments segments: [(seq: Int, data: Data)], tail: Data) {
        log("variant started (source \(sourceCodecName))")
        queue.async {
            guard !self.stopped else { return }
            let bytes = segments.reduce(0) { $0 + $1.data.count }
            for s in segments { self.feedLocked(s.data) }
            if !tail.isEmpty { self.feedLocked(tail) }
            if let first = segments.first?.seq, let last = segments.last?.seq {
                self.log("primed from \(segments.count) buffered segments (seq \(first)...\(last), \(bytes) B)")
            }
        }
    }

    /// Live bytes, teed by the remuxer from its ingest (same order).
    func feed(_ data: Data) {
        queue.async { self.feedLocked(data) }
    }

    private func feedLocked(_ data: Data) {
        guard !stopped, !failed, let remuxer else { return }
        do {
            try remuxer.feed(data)
        } catch {
            failed = true
            log("variant failed: \(error)")
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.servingTimer?.cancel()
            self.servingTimer = nil
            self.remuxer?.release()
            self.remuxer = nil
            self.store.close()
            self.log("variant stopped")
        }
    }

    /// True once the transcode could not run (decoder refused, codec error).
    var hasFailed: Bool { queue.sync { failed } }

    /// "AC-3 5.1": the source side of the audio path once the transcoder
    /// saw its first frame, else the PMT codec name.
    var sourceAudioLabel: String {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let path = audioPath, let arrow = path.range(of: " -> ") else { return sourceCodecName }
        return String(path[..<arrow.lowerBound])
    }

    // MARK: Readiness and status

    /// Plan section 4b: at least `readySegments` cuts, or the window
    /// already covers the hold-back the playlist wants.
    var isReady: Bool {
        let s = snapshot()
        guard s.hasInit else { return false }
        return s.segmentsInGeneration >= Self.readySegments || s.windowSeconds >= s.holdBackWanted + Double(s.target)
    }

    /// Emits `variant serving: ...` every `interval` seconds until stop.
    func startServingLog(interval: TimeInterval = 5, emit: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.servingTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                emit(self.statusLine("variant serving"))
            }
            self.servingTimer = t
            t.resume()
        }
    }

    struct Snapshot {
        var windowFirst = -1
        var windowLast = -1
        var windowCount = 0
        var ringCount = 0
        var target = 0
        var windowSeconds = 0.0
        var holdBack = 0.0
        var holdBackWanted = 0.0
        var videoEnd = 0.0
        var audioEnd = 0.0
        var audioBearing = 0
        var backlogVideo = 0
        var backlogAudio = 0
        var units = 0
        var segmentsInGeneration = 0
        var hasInit = false
        var served: [String: Int] = [:]
    }

    func snapshot() -> Snapshot {
        let ready = store.currentReadyState
        let hasInit = store.videoInitSegment(generation: generation) != nil
        stateLock.lock(); defer { stateLock.unlock() }
        var s = Snapshot()
        let window = Array(ring.suffix(CastHLSSegmentStore.windowSize))
        let ticks = Double(CastFMP4Remuxer.ticksPerSecond)
        s.windowFirst = window.first?.seq ?? -1
        s.windowLast = window.last?.seq ?? -1
        s.windowCount = window.count
        s.ringCount = ring.count
        // Same rounding as CastHLSSegmentStore.mediaPlaylistText.
        s.target = window.map { Int((Double(max($0.videoTicks, $0.audioTicks)) / ticks).rounded(.up)) }
            .max().map { max(1, $0) } ?? 0
        s.windowSeconds = window.reduce(0.0) { $0 + Double($1.videoTicks) / ticks }
        (s.holdBack, s.holdBackWanted) = Self.holdBack(target: s.target, windowSeconds: s.windowSeconds)
        s.videoEnd = Double(emittedVideoTicks) / ticks
        s.audioEnd = Double(emittedAudioTicks) / ticks
        s.audioBearing = window.filter { $0.audioSamples > 0 }.count
        s.backlogVideo = lastComposition.video
        s.backlogAudio = lastComposition.audio
        s.units = audioUnits
        s.segmentsInGeneration = ready.segments
        s.hasInit = hasInit
        s.served = served
        return s
    }

    /// The HOLD-BACK the variant playlists state: three target durations
    /// (the RFC 8216bis minimum, what the Cast store states), but never so
    /// deep that the join point would fall off the front of the window,
    /// which keeps one full target duration in front of it.
    static func holdBack(target: Int, windowSeconds: Double) -> (stated: Double, wanted: Double) {
        let wanted = Double(3 * target)
        guard target > 0 else { return (0, 0) }
        let room = windowSeconds - Double(target)
        let stated = min(wanted, max(Double(target), (room * 10).rounded(.down) / 10))
        return (stated, wanted)
    }

    /// `window seq A...B (n of N ring, target Ts, window Ws, hold-back Hs of
    /// Ws wanted, live edge Es) video end Vs audio end As delta Ds,
    /// audio-bearing N, backlog v= a= units= emitted Es, served ...`
    /// (the 2026-09-24 template). backlog v/a are the newest cut's video
    /// and audio sample counts; units counts AAC frames emitted so far.
    func statusLine(_ label: String) -> String {
        let s = snapshot()
        let liveEdge = min(s.videoEnd, s.audioEnd > 0 ? s.audioEnd : s.videoEnd)
        var line = "\(label): window seq \(s.windowFirst)...\(s.windowLast) "
        line += "(\(s.windowCount) of \(s.ringCount) ring, target \(s.target)s, "
        line += String(format: "window %.1fs, hold-back %.1fs of %.1fs wanted, live edge %.3fs) ",
                       s.windowSeconds, s.holdBack, s.holdBackWanted, liveEdge)
        line += String(format: "video end %.3fs audio end %.3fs delta %.3fs, ",
                       s.videoEnd, s.audioEnd, s.audioEnd - s.videoEnd)
        line += "audio-bearing \(s.audioBearing), backlog v=\(s.backlogVideo) a=\(s.backlogAudio) "
        line += "units=\(s.units) emitted \(String(format: "%.1f", s.videoEnd))s, "
        line += "served \(Self.servedSummary(s.served))"
        return line
    }

    /// `ainit=1 aseg=4 master=2` sorted by kind; `none` before any GET.
    static func servedSummary(_ served: [String: Int]) -> String {
        let parts = served.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }

    // MARK: Serving

    struct Response {
        let status: Int
        let body: Data
        let contentType: String
        /// master, video, audio, vinit, ainit, vseg, aseg ("unknown" on 404).
        let kind: String
        /// Segment / init generation; -1 for playlists.
        let seq: Int
    }

    /// Resolve one `/aac/...` request. Blocks up to the store's live-edge
    /// wait for a segment one poll ahead of the newest.
    func serve(path: String) -> Response {
        let name = path.hasPrefix("/aac/") ? String(path.dropFirst(5)) : path
        let playlist = "application/vnd.apple.mpegurl"
        func number(_ prefix: String, _ suffix: String) -> Int? {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            return Int(name.dropFirst(prefix.count).dropLast(suffix.count))
        }
        let r: Response
        if name == "master.m3u8" {
            r = Response(status: 200, body: Data(store.demuxedMasterPlaylistText().utf8),
                         contentType: playlist, kind: "master", seq: -1)
        } else if name == "video.m3u8" {
            r = Response(status: 200, body: Data(restateHoldBack(store.videoPlaylistText()).utf8),
                         contentType: playlist, kind: "video", seq: -1)
        } else if name == "audio.m3u8" {
            r = Response(status: 200, body: Data(restateHoldBack(store.audioPlaylistText()).utf8),
                         contentType: playlist, kind: "audio", seq: -1)
        } else if let gen = number("vinit", ".mp4") {
            r = Self.found(store.videoInitSegment(generation: gen), "video/mp4", "vinit", gen)
        } else if let gen = number("ainit", ".mp4") {
            r = Self.found(store.audioInitSegment(generation: gen), "audio/mp4", "ainit", gen)
        } else if let seq = number("vseg", ".m4s") {
            r = Self.found(store.awaitSegment(seq: seq, rendition: .video), "video/iso.segment", "vseg", seq)
        } else if let seq = number("aseg", ".m4s") {
            r = Self.found(store.awaitSegment(seq: seq, rendition: .audio), "audio/iso.segment", "aseg", seq)
        } else {
            r = Response(status: 404, body: Data("not found".utf8), contentType: "text/plain",
                         kind: "unknown", seq: -1)
        }
        if r.status == 200 {
            stateLock.lock(); served[r.kind, default: 0] += 1; stateLock.unlock()
        }
        return r
    }

    private static func found(_ data: Data?, _ type: String, _ kind: String, _ seq: Int) -> Response {
        guard let data else {
            return Response(status: 404, body: Data("not found".utf8), contentType: "text/plain", kind: kind, seq: seq)
        }
        return Response(status: 200, body: data, contentType: type, kind: kind, seq: seq)
    }

    /// The store states HOLD-BACK = 3 x target for the Cast receiver; the
    /// variant states `holdBack(target:windowSeconds:)` instead so
    /// AVPlayer's join point (plan section 5: no configured offset for the
    /// LAN item) always lands inside the window.
    func restateHoldBack(_ text: String) -> String {
        let s = snapshot()
        guard s.target > 0,
              let range = text.range(of: "HOLD-BACK=[0-9.]+", options: .regularExpression) else { return text }
        var out = text
        out.replaceSubrange(range, with: "HOLD-BACK=" + String(format: "%.3f", s.holdBack))
        return out
    }
}
