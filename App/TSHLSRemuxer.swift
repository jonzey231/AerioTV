import Foundation
import Network
import SwiftUI
import AVFoundation
import AVKit
import CoreMedia
import Combine

// MARK: - TS-to-HLS remuxer (TEST, branch test/avplayer-hls-engine)

/// On-device MPEG-TS to HLS remuxer: ingests a continuous raw MPEG-TS HTTP
/// stream (Dispatcharr /proxy/ts/), cuts it into HLS segments on keyframe
/// boundaries WITHOUT transcoding (pure 188-byte packet copy), and serves a
/// rolling live playlist from 127.0.0.1 so AVPlayer can play it natively.
///
/// Why this exists: AVPlayer cannot play raw MPEG-TS over HTTP at all
/// (CoreMedia -12939); TS is only legal inside an HLS playlist. H.264 +
/// AC-3/AAC in TS segments is fully HLS-legal (RFC 8216 sec 3.2; Apple
/// authoring rules 1.2/2.5), so for those streams segmentation alone makes
/// them AVPlayer-playable, which buys the native HDR pipeline, Atmos
/// passthrough, and AirPlay.
///
/// Codec gate (checked from the PMT before anything is served):
/// - video MUST be H.264 (stream_type 0x1B). HEVC (0x24) needs fMP4
///   segments per Apple authoring rule 1.5 (a real repackager, out of
///   scope here); MPEG-2 (0x01/0x02) is not decodable by AVPlayer at all.
/// - audio entries must be AC-3 (0x81), E-AC-3 (0x87), or ADTS AAC (0x0F).
///   MP2 (0x03/0x04) is not in Apple's HLS codec list.
/// On a gate failure `onError` fires with the codec name and the caller
/// falls back to the mpv pipeline.
///
/// Latency expectation: AVPlayer joins a live playlist about three target
/// durations behind the newest segment, so with ~2s segments expect roughly
/// 4-8s tap-to-video and 6-10s behind the live edge (vs ~3.5s on mpv).
/// Segment length is ultimately dictated by the provider's GOP cadence
/// because segments must start on keyframes.
final class TSHLSRemuxer: NSObject, @unchecked Sendable {

    enum RemuxError: Error, CustomStringConvertible {
        case unsupportedCodec(String)
        case ingestFailed(String)
        case serverFailed

        var description: String {
            switch self {
            case .unsupportedCodec(let codec): return "unsupported codec: \(codec)"
            case .ingestFailed(let reason):    return "ingest failed: \(reason)"
            case .serverFailed:                return "local HLS server failed"
            }
        }
    }

    // MARK: Tunables

    /// Minimum seconds between segment cuts; the actual cut lands on the
    /// FIRST keyframe at or after this much elapsed PTS.
    private let targetSegmentSeconds = 2.0
    /// Startup ramp (2026-08-25 ESPN capture): the 6.15s tune-in was
    /// 1.9s connect + 4s of accumulating readyThreshold 2.0s segments.
    /// The first few segments therefore cut at the first keyframe after
    /// 1.0s instead, halving the accumulation phase wherever the feed's
    /// keyframe cadence is denser than 2s. On a 2s-GOP feed the cuts
    /// still land at 2s and this is a no-op, never a regression.
    private let startupRampSegments = 3
    private let startupSegmentSeconds = 1.0
    /// Segments advertised in the live playlist window. 8 (not 6): the
    /// same capture showed AVPlayer recovers from an upstream delivery
    /// gap by re-buffering deeper behind the edge; a 16s window gives
    /// that recovery room where 12s ran out during a 9.2s feed gap.
    private let liveWindowSegments = 8
    /// Segments retained in memory; old ones beyond this are dropped even
    /// if a slow client might still want them (live TV: it should not).
    private let maxBufferedSegments = 12
    /// Segments that must exist before `onReady` fires with the playlist
    /// URL. Two keeps startup low; AVPlayer refreshes the playlist as more
    /// land.
    private let readyThreshold = 2

    // MARK: Callbacks (delivered on the main queue, each at most once)

    var onReady: ((URL) -> Void)?
    var onError: ((RemuxError) -> Void)?
    /// Fires once with the stream's measured geometry / frame rate /
    /// 10-bit flag, from whichever arm is producing. The tile uses it to
    /// set AVDisplayManager.preferredDisplayCriteria: a bare
    /// AVPlayerLayer never triggers a display-mode match on its own
    /// (that is an AVPlayerViewController perk), so without this the
    /// panel stays at the home-screen 4K SDR 60 regardless of content.
    /// Width/height are 0 from the TS arm (it never parses the SPS);
    /// the tile falls back to a nominal geometry there.
    var onVideoParameters: ((_ width: Int, _ height: Int, _ fps: Double, _ is10Bit: Bool) -> Void)?

    // MARK: State

    private let sourceURL: URL
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "com.aerio.tsremux")
    private var urlSession: URLSession?
    private var ingestTask: URLSessionDataTask?
    private var listener: NWListener?
    private var localPort: UInt16 = 0
    private var stopped = false

    // TS demux state
    private var pending = Data()
    private var pmtPID = -1
    private var videoPID = -1
    private var patPacket: Data?
    private var pmtPacket: Data?
    private var codecGatePassed = false
    /// Non-nil after the PMT declared HEVC: the fMP4 arm (Apple HLS rule
    /// 1.5 - HEVC only rides fMP4 segments; the TS passthrough below is
    /// the H.264 arm). Bytes route to it INSTEAD of the TS segmenter, the
    /// playlist grows EXT-X-MAP/VERSION 7, and the loopback serves
    /// init.mp4 + .m4s. Audio passes through (AC-3/E-AC-3/AAC), which is
    /// what hands the system pipeline its 5.1/Atmos bitstream.
    private var fmp4: LiveFMP4Remuxer?
    private var fmp4InitSegment: Data?
    /// TS-arm frame-rate measurement: successive video PES PTS deltas.
    /// The median of ~60 access units nails 25/30/50/59.94 without
    /// parsing the SPS.
    private var videoPTSDeltas: [Double] = []
    private var lastVideoAUPTS: Double = -1
    private var videoParamsSent = false

    // Segmenter state
    private var currentSegment = Data()
    private var currentStartPTS: Double?
    private var awaitingFirstKeyframe = true
    private var segments: [(seq: Int, data: Data, duration: Double)] = []
    private var nextSeq = 0
    private var readySignaled = false
    private var errorSignaled = false
    private var totalBytesIngested = 0

    // Live Rewind window (task #145): when > 0, every closed segment is
    // also spilled to disk and the playlist advertises the WHOLE spilled
    // window instead of the last `liveWindowSegments`. AVPlayer's own
    // seekableTimeRanges then spans the rewind depth, so native
    // pause/scrub IS the rewind UI. Memory stays bounded by
    // `maxBufferedSegments`; scrubbed-back requests read from disk.
    // Fullscreen single-stream only; multiview tiles pass 0.
    private let rewindWindowSeconds: Double
    private var spillDir: URL?
    private var spilled: [(seq: Int, url: URL, duration: Double)] = []

    init(sourceURL: URL, headers: [String: String], rewindWindowSeconds: Double = 0) {
        self.sourceURL = sourceURL
        self.headers = headers
        self.rewindWindowSeconds = rewindWindowSeconds
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.rewindWindowSeconds > 0 {
                self.setupSpillDir()
            }
            self.startServer()
            self.startIngest()
        }
    }

    /// Spill lives under the same LiveRewind root the mpv-path engine
    /// uses, so the retention reaper's stale-directory sweep collects
    /// abandoned sessions (e.g. after a crash) on the next launch.
    private func setupSpillDir() {
        // Same platform split as LiveRewindEngine.rootDir: tvOS denies
        // Application Support writes on device; Caches is the only option.
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
        let dir = base
            .appendingPathComponent("LiveRewind", isDirectory: true)
            .appendingPathComponent("avp_sess_\(Int64(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(values)
            spillDir = dir
            debugLog("[TS-REMUX] rewind spill dir ready (window \(Int(rewindWindowSeconds))s): \(dir.lastPathComponent)")
        } catch {
            // No disk window: degrade to the classic 6-segment live edge.
            spillDir = nil
            debugLog("[TS-REMUX] rewind spill dir FAILED (\(error)); classic live window only")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.ingestTask?.cancel()
            self.urlSession?.invalidateAndCancel()
            self.listener?.cancel()
            self.segments.removeAll()
            self.currentSegment.removeAll()
            // Assign a fresh Data rather than removeAll(): the latter keeps
            // the backing allocation, so a stopped-but-still-retained remuxer
            // would hold its whole dead buffer (Apple #74).
            self.pending = Data()
            self.spilled.removeAll()
            if let dir = self.spillDir {
                try? FileManager.default.removeItem(at: dir)
                self.spillDir = nil
            }
            debugLog("[TS-REMUX] stopped (ingested \(self.totalBytesIngested / 1_048_576) MB)")
        }
    }

    private func fail(_ error: RemuxError) {
        guard !errorSignaled else { return }
        errorSignaled = true
        debugLog("[TS-REMUX] ERROR: \(error)")
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    // MARK: Ingest

    private func startIngest() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        // A live stream never "completes"; rely on data flow.
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session
        var request = URLRequest(url: sourceURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.dataTask(with: request)
        ingestTask = task
        task.resume()
        debugLog("[TS-REMUX] ingest started (headers: \(headers.keys.sorted().joined(separator: ",")))")
    }

    // MARK: TS packet walk

    private func consume(_ data: Data) {
        guard !stopped, !errorSignaled else { return }
        totalBytesIngested += data.count
        if let fmp4 {
            // HEVC arm: the sub-remuxer does its own sync/PSI/PES walk.
            // It re-acquires PAT/PMT from their in-stream repetition, so
            // the partial chunk consumed before the switch costs nothing.
            fmp4.feed(data)
            return
        }
        pending.append(data)

        // Resync to 0x47 if alignment was lost (provider hiccup).
        while pending.count >= 188 {
            if pending[pending.startIndex] != 0x47 {
                if let sync = pending.firstIndex(of: 0x47) {
                    pending.removeSubrange(pending.startIndex..<sync)
                    continue
                } else {
                    pending.removeAll()
                    break
                }
            }
            // Require the NEXT packet to also start with 0x47 (or be the
            // tail) so a stray 0x47 inside payload does not fake a sync.
            if pending.count >= 189, pending[pending.index(pending.startIndex, offsetBy: 188)] != 0x47 {
                pending.removeFirst(1)
                continue
            }
            let packet = pending.prefix(188)
            pending.removeFirst(188)
            handlePacket(Data(packet))
        }

        // Apple #74. Foundation's Data is a __DataStorage reference plus a
        // Range, and removeFirst/removeSubrange at the FRONT only advance the
        // range's lower bound: the tail is never memmoved down and the
        // allocation is never compacted, while append keeps extending the far
        // end. So this buffer retains EVERY byte ever ingested and stays
        // dirty-resident until the remuxer deallocates, even though
        // `pending.count` reads back under 188 on every pass and the
        // "buffered N" segment counter stays honestly pinned at 10. Nothing
        // the app logs could see it.
        //
        // Measured against this exact loop: 218 MB ingested cost +220.1 MB of
        // phys_footprint (1.0096 bytes resident per byte in) with startIndex
        // equal to the total consumed; re-seating holds it at +0.1 MB for the
        // same input and the same packet count. That 1:1 slope is what walked
        // ochaos's Apple TV from ~450 MB to the ~2 GB jetsam ceiling in under
        // an hour on a single channel, and why time-to-crash tracked the
        // channel's bitrate rather than anything the user did.
        //
        // The surviving tail is at most one TS packet, so the copy is free.
        // Placed after the loop so it also covers the `break` out of the
        // resync path above.
        pending = pending.isEmpty ? Data() : Data(pending)
    }

    private func handlePacket(_ p: Data) {
        guard p.count == 188 else { return }
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let pusi = (p[1] & 0x40) != 0

        if pid == 0 {
            patPacket = p
            parsePAT(p)
        } else if pid == pmtPID {
            pmtPacket = p
            parsePMT(p)
        }

        guard codecGatePassed else { return }

        // Keyframe-aligned cuts: only video PES starts can open segments.
        if pid == videoPID, pusi {
            if let pts = extractPTS(p) {
                if !videoParamsSent {
                    if lastVideoAUPTS >= 0 {
                        let d = pts - lastVideoAUPTS
                        if d > 0.005, d < 0.1 { videoPTSDeltas.append(d) }
                    }
                    lastVideoAUPTS = pts
                    if videoPTSDeltas.count >= 60 {
                        videoParamsSent = true
                        let median = videoPTSDeltas.sorted()[videoPTSDeltas.count / 2]
                        let fps = 1.0 / median
                        debugLog("[TS-REMUX] video: measured \(String(format: "%.2f", fps))fps (H.264 arm)")
                        let cb = onVideoParameters
                        DispatchQueue.main.async { cb?(0, 0, fps, false) }
                    }
                }
                let isKeyframe = packetStartsKeyframeAccessUnit(p)
                if awaitingFirstKeyframe {
                    if isKeyframe {
                        awaitingFirstKeyframe = false
                        beginSegment(at: pts)
                    }
                } else if isKeyframe,
                          let start = currentStartPTS {
                    var elapsed = pts - start
                    let cutAt = nextSeq < startupRampSegments
                        ? startupSegmentSeconds : targetSegmentSeconds
                    // 33-bit PTS wrap (~26.5h) or discontinuity: cut here.
                    if elapsed < 0 { elapsed = cutAt }
                    if elapsed >= cutAt {
                        closeSegment(endPTS: pts)
                        beginSegment(at: pts)
                    }
                }
            }
        }

        guard !awaitingFirstKeyframe else { return }
        currentSegment.append(p)
    }

    // MARK: PSI parsing

    private func payloadStart(_ p: Data) -> Int? {
        let afc = (p[3] >> 4) & 0x03
        switch afc {
        case 0x01: return 4                              // payload only
        case 0x03:
            let afLen = Int(p[4])
            let start = 5 + afLen
            return start < 188 ? start : nil             // adaptation + payload
        default: return nil                              // no payload
        }
    }

    private func parsePAT(_ p: Data) {
        guard pmtPID < 0, let base = payloadStart(p), base + 1 < 188 else { return }
        let pointer = Int(p[base])
        let section = base + 1 + pointer
        // table_id(1) section_length(2) tsid(2) ver(1) sec(1) last(1) = 8,
        // then program entries of 4 bytes each.
        var offset = section + 8
        while offset + 3 < 188 {
            let programNumber = (Int(p[offset]) << 8) | Int(p[offset + 1])
            let pidValue = (Int(p[offset + 2] & 0x1F) << 8) | Int(p[offset + 3])
            if programNumber != 0 {
                pmtPID = pidValue
                debugLog("[TS-REMUX] PAT: program \(programNumber) -> PMT PID \(pmtPID)")
                return
            }
            offset += 4
        }
    }

    private func parsePMT(_ p: Data) {
        guard videoPID < 0, let base = payloadStart(p), base + 1 < 188 else { return }
        let pointer = Int(p[base])
        let section = base + 1 + pointer
        guard section + 12 < 188 else { return }
        let sectionLength = (Int(p[section + 1] & 0x0F) << 8) | Int(p[section + 2])
        let programInfoLength = (Int(p[section + 10] & 0x0F) << 8) | Int(p[section + 11])
        var offset = section + 12 + programInfoLength
        let sectionEnd = min(section + 3 + sectionLength - 4, 187) // minus CRC32

        var foundVideo: (pid: Int, type: UInt8)?
        var audioTypes: [UInt8] = []

        while offset + 4 < sectionEnd {
            let streamType = p[offset]
            let esPID = (Int(p[offset + 1] & 0x1F) << 8) | Int(p[offset + 2])
            let esInfoLength = (Int(p[offset + 3] & 0x0F) << 8) | Int(p[offset + 4])
            switch streamType {
            case 0x1B, 0x24, 0x01, 0x02:           // H.264 / HEVC / MPEG-1/2 video
                if foundVideo == nil { foundVideo = (esPID, streamType) }
            case 0x81, 0x87, 0x0F, 0x03, 0x04, 0x11: // AC-3 / E-AC-3 / AAC / MP2 / LATM
                audioTypes.append(streamType)
            default:
                break
            }
            offset += 5 + esInfoLength
        }

        guard let video = foundVideo else { return }
        videoPID = video.pid

        // The codec gate, per Apple's HLS authoring rules. H.264 stays on
        // the TS passthrough below; HEVC switches to the fMP4 arm (rule
        // 1.5); MPEG-2 has no decoder on this platform at all.
        if video.type == 0x24 {
            startFMP4Pipeline()
            return
        }
        if video.type != 0x1B {
            fail(.unsupportedCodec("MPEG-2 video"))
            return
        }
        if audioTypes.contains(where: { $0 == 0x03 || $0 == 0x04 }) {
            fail(.unsupportedCodec("MP2 audio"))
            return
        }
        codecGatePassed = true
        let audioDesc = audioTypes.map { String(format: "0x%02X", $0) }.joined(separator: ",")
        debugLog("[TS-REMUX] PMT: H.264 video PID \(videoPID), audio types [\(audioDesc)] -> codec gate PASSED")
    }

    // MARK: PES / NAL inspection

    /// PTS (seconds) from a PES header at the start of this packet's
    /// payload, when present.
    private func extractPTS(_ p: Data) -> Double? {
        guard let base = payloadStart(p), base + 13 < 188 else { return nil }
        // PES start code 00 00 01
        guard p[base] == 0x00, p[base + 1] == 0x00, p[base + 2] == 0x01 else { return nil }
        let flags = p[base + 7]
        guard (flags & 0x80) != 0 else { return nil }    // PTS present
        let b0 = UInt64(p[base + 9]), b1 = UInt64(p[base + 10]), b2 = UInt64(p[base + 11])
        let b3 = UInt64(p[base + 12]), b4 = UInt64(p[base + 13])
        let pts: UInt64 = ((b0 >> 1) & 0x07) << 30
            | b1 << 22
            | ((b2 >> 1) & 0x7F) << 15
            | b3 << 7
            | (b4 >> 1)
        return Double(pts) / 90_000.0
    }

    /// Does this PUSI packet's payload open a keyframe access unit? Scans
    /// the visible NAL start codes for SPS (7) or IDR (5); encoders emit
    /// SPS/PPS immediately before each IDR, so SPS in the first packet is
    /// a reliable keyframe marker even when the IDR NAL itself starts in
    /// a later packet of the same PES.
    private func packetStartsKeyframeAccessUnit(_ p: Data) -> Bool {
        guard let base = payloadStart(p), base + 9 < 188 else { return false }
        let headerLen = Int(p[base + 8])
        var i = base + 9 + headerLen
        let end = 188 - 4
        while i < end {
            if p[i] == 0x00, p[i + 1] == 0x00 {
                var nalStart = -1
                if p[i + 2] == 0x01 { nalStart = i + 3 }
                else if p[i + 2] == 0x00, i + 3 < end, p[i + 3] == 0x01 { nalStart = i + 4 }
                if nalStart > 0, nalStart < 188 {
                    let nalType = p[nalStart] & 0x1F
                    if nalType == 5 || nalType == 7 { return true }
                    i = nalStart
                    continue
                }
            }
            i += 1
        }
        return false
    }

    // MARK: Segmenter

    private func beginSegment(at pts: Double) {
        currentSegment = Data()
        // Every segment must lead with PAT + PMT so a client can join at
        // any segment. The cached packets carry stale continuity counters;
        // AVPlayer tolerates that on PSI PIDs.
        if let pat = patPacket { currentSegment.append(pat) }
        if let pmt = pmtPacket { currentSegment.append(pmt) }
        currentStartPTS = pts
    }

    /// Switch this remuxer into fMP4 mode for an HEVC mux. Storage,
    /// playlist window, READY gating, ramp, spill and jitter telemetry
    /// are all shared with the TS arm; only production differs.
    private func startFMP4Pipeline() {
        guard fmp4 == nil else { return }
        let mux = LiveFMP4Remuxer(
            targetSegmentSeconds: targetSegmentSeconds,
            rampSegmentSeconds: startupSegmentSeconds,
            rampSegments: startupRampSegments,
            log: { debugLog("[TS-REMUX] \($0)") })
        mux.onPMT = { desc in
            debugLog("[TS-REMUX] PMT: \(desc) -> fMP4 arm ENGAGED")
        }
        mux.onInitSegment = { [weak self] data in
            self?.fmp4InitSegment = data
        }
        mux.onMediaSegment = { [weak self] data, duration in
            self?.storeSegment(data: data, duration: duration)
        }
        mux.onError = { [weak self] error in
            self?.fail(.unsupportedCodec(error.codecName))
        }
        mux.onVideoParameters = { [weak self] w, h, fps, tenBit in
            let cb = self?.onVideoParameters
            DispatchQueue.main.async { cb?(w, h, fps, tenBit) }
        }
        fmp4 = mux
        codecGatePassed = true
        // Bytes already sitting in the TS arm's buffer belong to the new
        // arm; hand them over before the next network chunk arrives.
        if !pending.isEmpty {
            mux.feed(Data(pending))
            pending.removeAll()
        }
    }

    private func closeSegment(endPTS: Double) {
        guard let start = currentStartPTS, !currentSegment.isEmpty else { return }
        var duration = endPTS - start
        if duration <= 0 || duration > 10 { duration = targetSegmentSeconds }
        storeSegment(data: currentSegment, duration: duration)
    }

    /// Shared segment store for BOTH arms (TS passthrough and fMP4):
    /// window buffering, rewind spill, READY gating, and the feed-jitter
    /// telemetry all behave identically regardless of who produced the
    /// bytes.
    private func storeSegment(data: Data, duration: Double) {
        // Upstream delivery jitter telemetry (2026-08-25 capture: 174 of
        // 940 closures arrived >2.6s apart, worst 9.2s, and the two
        // AVPlayer stalls line up with the worst gaps). Wall-clock gap
        // between closures minus the media duration ~= feed starvation.
        let nowWall = Date()
        if let lastWall = lastSegmentCloseWall {
            let gap = nowWall.timeIntervalSince(lastWall)
            if gap > duration + 0.6 {
                starvedClosures += 1
                worstClosureGap = max(worstClosureGap, gap)
            }
        }
        lastSegmentCloseWall = nowWall
        if nextSeq > 0, nextSeq % 150 == 0 {
            debugLog("[TS-REMUX] feed-jitter: \(starvedClosures) starved closures so far, worst gap \(String(format: "%.1f", worstClosureGap))s")
        }
        segments.append((seq: nextSeq, data: data, duration: duration))
        spillSegment(seq: nextSeq, data: data, duration: duration)
        nextSeq += 1
        if segments.count > maxBufferedSegments {
            segments.removeFirst(segments.count - maxBufferedSegments)
        }
        // nextSeq, not segments.count: the count pins at maxBufferedSegments
        // once the window fills, and 12 % 5 != 0 silenced every close after
        // the first ten seconds of the 2026-08-25 UHD soak.
        if nextSeq == 1 || nextSeq % 5 == 0 {
            debugLog("[TS-REMUX] segment \(nextSeq - 1) closed (\(String(format: "%.2f", duration))s, \(data.count / 1024) KB), buffered \(segments.count)")
        }
        if !readySignaled, segments.count >= readyThreshold, localPort != 0,
           fmp4 == nil || fmp4InitSegment != nil {
            readySignaled = true
            let url = URL(string: "http://127.0.0.1:\(localPort)/live.m3u8")!
            debugLog("[TS-REMUX] READY -> \(url.absoluteString)")
            DispatchQueue.main.async { [weak self] in self?.onReady?(url) }
        }
    }

    /// Write the closed segment into the rewind spill window, then ring
    /// it by total duration so the playlist never exceeds the depth.
    private func spillSegment(seq: Int, data: Data, duration: Double) {
        guard rewindWindowSeconds > 0, let dir = spillDir else { return }
        let url = dir.appendingPathComponent("seg\(seq).\(segmentFileExtension)")
        do {
            try data.write(to: url)
        } catch {
            debugLog("[TS-REMUX] spill write failed (\(error)); dropping disk window")
            spillDir = nil
            spilled.removeAll()
            return
        }
        spilled.append((seq: seq, url: url, duration: duration))
        var total = spilled.reduce(0) { $0 + $1.duration }
        while total > rewindWindowSeconds, spilled.count > liveWindowSegments {
            let oldest = spilled.removeFirst()
            total -= oldest.duration
            try? FileManager.default.removeItem(at: oldest.url)
        }
    }

    // MARK: Feed-jitter telemetry (read the [TS-REMUX] feed-jitter lines)
    private var lastSegmentCloseWall: Date?
    private var starvedClosures = 0
    private var worstClosureGap = 0.0

    /// See playlistText: monotonic, never shrinks, seeded at the target.
    private var pinnedTargetDuration = 2.0

    private func playlistText() -> String {
        // Rewind mode: advertise the whole disk window; AVPlayer's
        // seekable range then IS the rewind window. Every spilled entry
        // also existed in memory when written, so seq numbering is one
        // continuous run either way.
        let window: [(seq: Int, duration: Double)] = (spillDir != nil && !spilled.isEmpty)
            ? spilled.map { (seq: $0.seq, duration: $0.duration) }
            : segments.suffix(liveWindowSegments).map { (seq: $0.seq, duration: $0.duration) }
        guard let first = window.first else {
            return "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(pinnedTargetDuration.rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n"
        }
        // RFC 8216 4.3.3.1: TARGETDURATION MUST NOT change between playlist
        // reloads. The old `window.max()` recomputation could report 1 during
        // the startup ramp and grow to 2 (or beyond, after a long-GOP cut)
        // later, which is exactly the heuristic CoreMedia's -12888 staleness
        // check keys off. Pin it monotonically, seeded at the steady-state
        // target.
        pinnedTargetDuration = max(pinnedTargetDuration,
                                   window.map(\.duration).max() ?? targetSegmentSeconds)
        // fMP4 arm: EXT-X-MAP requires protocol version 6+; 7 matches
        // Apple's own fMP4 playlists. The TS arm stays at 3.
        let version = fmp4 != nil ? 7 : 3
        var text = """
        #EXTM3U
        #EXT-X-VERSION:\(version)
        #EXT-X-TARGETDURATION:\(Int(pinnedTargetDuration.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:\(first.seq)

        """
        if fmp4 != nil {
            text += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        }
        for segment in window {
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\nseg\(segment.seq).\(segmentFileExtension)\n"
        }
        return text
    }

    /// Media-segment URI extension per arm. Cosmetic to AVPlayer (the
    /// playlist context decides), load-bearing for a human reading a
    /// packet capture.
    private var segmentFileExtension: String { fmp4 != nil ? "m4s" : "ts" }

    /// Memory-first (live edge), disk-fallback (scrubbed back into the
    /// rewind window). Called on `queue`.
    private func segmentData(seq: Int) -> Data? {
        if let segment = segments.first(where: { $0.seq == seq }) {
            return segment.data
        }
        if let entry = spilled.first(where: { $0.seq == seq }) {
            return try? Data(contentsOf: entry.url)
        }
        return nil
    }

    // MARK: Loopback HTTP server

    private func startServer() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only; never expose the stream on the LAN.
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.queue.async {
                        self.localPort = listener.port?.rawValue ?? 0
                        debugLog("[TS-REMUX] loopback server ready on port \(self.localPort)")
                    }
                case .failed:
                    self.queue.async { self.fail(.serverFailed) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            fail(.serverFailed)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                // Parse BEFORE honouring isComplete: a legal request whose
                // last bytes arrive with FIN piggybacked must still be served.
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(connection, path: path)
            } else if isComplete || buffer.count >= 16_384 {
                // EOF before a complete request, or an oversized head. Without
                // the isComplete arm a cleanly half-closed peer returns
                // (nil, true, nil) forever and this re-armed on every one.
                connection.cancel()
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        queue.async { [weak self] in
            guard let self else { connection.cancel(); return }
            let body: Data
            let contentType: String
            var status = "200 OK"

            if path.hasSuffix("live.m3u8") {
                body = Data(self.playlistText().utf8)
                contentType = "application/vnd.apple.mpegurl"
            } else if path.hasSuffix("init.mp4"), let initSeg = self.fmp4InitSegment {
                body = initSeg
                contentType = "video/mp4"
            } else if path.hasPrefix("/seg"), path.hasSuffix(".ts"),
                      let seq = Int(path.dropFirst(4).dropLast(3)),
                      let data = self.segmentData(seq: seq) {
                body = data
                contentType = "video/mp2t"
            } else if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
                      let seq = Int(path.dropFirst(4).dropLast(4)),
                      let data = self.segmentData(seq: seq) {
                body = data
                contentType = "video/iso.segment"
            } else {
                body = Data("not found".utf8)
                contentType = "text/plain"
                status = "404 Not Found"
            }

            let header = "HTTP/1.1 \(status)\r\n"
                + "Content-Type: \(contentType)\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Connection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

// MARK: - URLSessionDataDelegate (ingest)

extension TSHLSRemuxer: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            queue.async { [weak self] in self?.fail(.ingestFailed("HTTP \(http.statusCode)")) }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in self?.consume(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        queue.async { [weak self] in self?.fail(.ingestFailed(error.localizedDescription)) }
    }
}

// MARK: - AVPlayer multiview tile (TEST, branch test/avplayer-hls-engine)

/// AVPlayer-backed video surface for ONE multiview tile, the per-tile
/// engine-swap counterpart of `MPVPlayerViewRepresentable`. Multiview's
/// features (layouts, spotlight, relocate, audio routing, staging,
/// chrome, focus) all live in the container and store and are
/// tile-agnostic, so swapping the video view per tile is all that
/// AVPlayer multiview requires; nothing else is duplicated.
///
/// Direct HLS URLs play as-is; raw TS rides a per-tile TSHLSRemuxer
/// instance (each binds its own loopback port, so N concurrent tiles
/// remux independently). On any remux/codec-gate/playback failure the
/// tile reports back and the parent swaps it to an mpv tile, so
/// mixed-engine grids (e.g. an HEVC UHD channel on mpv next to H.264
/// channels on AVPlayer) are the normal failure mode, not an error.
///
/// Self-rescheduling stall/freeze watchdog for a live AVPlayer item. Polls
/// every `interval` while `player.currentItem === item`; calls `onDead(reason)`
/// exactly once and stops when the item fails, never becomes ready, renders no
/// video, or freezes (clock not advancing while the player is trying to play).
/// The one-shot +Ns "no renderable video" check it replaces could be
/// permanently disarmed by a single rendered frame; this keeps watching, so a
/// mid-stream server wedge (a rejected reload, a stuck live edge) self-heals to
/// the mpv engine instead of stranding the viewer on a frozen frame. Store the
/// instance and `cancel()` it on teardown / channel swap.
///
/// Uses DispatchQueue.main.asyncAfter (not Timer, whose @Sendable block rejects
/// the non-Sendable AVPlayer/closure captures) and MainActor.assumeIsolated on
/// each fire, matching the codebase's main-queue-callback idiom.
@MainActor
final class AVPStallWatchdog {
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private let label: String
    private let interval: TimeInterval
    private let onDead: (String) -> Void
    private var lastTime = -1.0
    private var stuckPolls = 0     // consecutive polls with a frozen clock
    private var unknownPolls = 0   // consecutive polls stuck at .unknown
    private var cancelled = false
    private var fired = false      // onDead is strictly one-shot

    /// Media-byte progress probe (MKV VOD tiles): the engine's total
    /// received bytes. A stream that is still ADVANCING is a slow link,
    /// not a wedge - a resumed 4K title's first segment build is ~190MB,
    /// nearly a minute at 30Mbps Wi-Fi, and the fixed 12s no-ready kill
    /// was exactly why iPhone UHD VOD "would not play at all"
    /// (2026-08-26; the watchdog's own retry cancelled every healthy
    /// build mid-flight). nil = no probe (live/direct), old behavior.
    private let mediaBytes: (() -> Int64)?
    private var lastMediaBytes: Int64 = -1

    init(player: AVPlayer, item: AVPlayerItem, label: String,
         interval: TimeInterval = 4.0,
         mediaBytes: (() -> Int64)? = nil,
         onDead: @escaping (String) -> Void) {
        self.player = player
        self.item = item
        self.label = label
        self.interval = interval
        self.mediaBytes = mediaBytes
        self.onDead = onDead
    }

    /// True when the media stream received bytes since the last poll.
    /// Call at most once per poll (it advances the baseline).
    private func pollStreamingProgress() -> Bool {
        guard let mediaBytes else { return false }
        let now = mediaBytes()
        defer { lastMediaBytes = now }
        return now > lastMediaBytes
    }

    func start() { schedule() }
    func cancel() { cancelled = true }

    private func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard !cancelled, !fired else { return }
        guard let player, let item, player.currentItem === item else { return }
        func die(_ reason: String) {
            fired = true
            debugLog("[AVP-WATCHDOG] \(label): \(reason); falling back to mpv")
            onDead(reason)
        }
        let progressing = pollStreamingProgress()
        switch item.status {
        case .failed:
            die("item failed (\(item.error.map { "\($0)" } ?? "unknown error"))")
            return
        case .unknown:
            unknownPolls += 1
            if unknownPolls >= 15 {
                die("never became ready (~\(Int(interval * 15))s, stream \(progressing ? "still advancing" : "stalled"))")
                return
            }
            if unknownPolls >= 3 {
                if progressing {
                    debugLog("[AVP-WATCHDOG] \(label): .unknown ~\(Int(interval) * unknownPolls)s but media stream advancing (slow link); waiting")
                } else {
                    die("never became ready (~\(Int(interval * 3))s at .unknown)")
                    return
                }
            }
        case .readyToPlay:
            unknownPolls = 0
            let size = item.presentationSize
            if size.width == 0 && size.height == 0 {
                die("ready but no renderable video (audio-only / undecodable video)")
                return
            }
            // Frozen clock: only count when the player claims to be
            // PLAYING with a stuck playhead (a true wedge), or when it is
            // waiting AND the media stream has stopped advancing. A
            // waiting player whose stream is still receiving bytes is a
            // slow-link rebuffer (UHD seek at 30Mbps takes ~a minute) and
            // must be left alone.
            let status = player.timeControlStatus
            if status == .playing
                || (status == .waitingToPlayAtSpecifiedRate && !progressing) {
                let t = CMTimeGetSeconds(item.currentTime())
                // abs(): a SEEK moves the clock in either direction and is
                // never a wedge. The signed test read every backward jump
                // (rewind-30 spam) as "stuck" - two rewinds inside ~8s
                // killed a perfectly healthy VOD session (field find
                // 2026-08-26, #7 Seventhdary while rewinding).
                if t.isFinite, lastTime >= 0, abs(t - lastTime) < 0.25 {
                    stuckPolls += 1
                    // A PLAYING player with a stuck clock is a wedge in
                    // ~2 polls. A WAITING one gets a longer fuse (4): a
                    // flow-control-suspended stream can look idle for a
                    // poll while the pipeline is healthy.
                    if stuckPolls >= (status == .playing ? 2 : 4) {
                        die(String(format: "playback frozen (clock stuck at %.2fs while not paused)", t))
                        return
                    }
                } else {
                    stuckPolls = 0
                }
                if t.isFinite { lastTime = t }
            } else {
                stuckPolls = 0   // user paused: never accumulate
            }
        @unknown default:
            break
        }
        schedule()
    }
}

#if os(tvOS)
/// Debounces display-criteria teardown across tile generations. A tile
/// stop used to clear the criteria immediately, and a session that
/// started 160ms later set new ones (2026-08-25 log, 72 HOURS): the
/// panel gets told "revert to SDR 60" and "switch to HDR 24" back to
/// back, risking two HDMI re-handshakes where one (or zero, when the
/// formats match) would do. The clear now waits 3s and a new apply
/// cancels it, so movie-to-movie and channel-zap transitions hand the
/// panel one coherent instruction.
@MainActor
enum DisplayCriteriaCoordinator {
    private static var pendingClear: DispatchWorkItem?

    static func apply(_ criteria: AVDisplayCriteria, to dm: AVDisplayManager) {
        pendingClear?.cancel()
        pendingClear = nil
        dm.preferredDisplayCriteria = criteria
    }

    static func scheduleClear(_ dm: AVDisplayManager) {
        pendingClear?.cancel()
        let work = DispatchWorkItem {
            dm.preferredDisplayCriteria = nil
            debugLog("[AVP-DISPLAY] display criteria cleared (debounced; panel returns to default mode)")
        }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
#endif

/// Known evaluation limitations: the chrome scrubber and track pickers
/// bind to the mpv progress store, so they are inert while the audio
/// tile is AVPlayer-backed; play/pause via `shouldPause` works.
/// Accumulates subtitle cues harvested by the MKV engine's A/V builds
/// and answers "what text is on screen at time T". Rendering is our own
/// overlay (mpv also drew its own subs): native VTT renditions were
/// measured unusable - AVPlayer prefetches subtitle segments ~2 minutes
/// ahead, each costing a 3-span media fetch on a UHD remux. Harvested
/// cues instead ride the spans the A/V build already parsed, so
/// coverage always leads the playhead by the forward buffer for free.
@MainActor final class AVPSubtitleCueStore: ObservableObject {
    struct Cue { let startMs: Int64; let endMs: Int64; let text: String }
    private(set) var tracks: [(number: Int, name: String, language: String)] = []
    private var cuesByTrack: [Int: [Cue]] = [:]
    /// MKV track number of the enabled subtitle track; nil = off.
    @Published var activeTrack: Int?

    func setTracks(_ t: [(number: Int, name: String, language: String)]) { tracks = t }

    func add(track: Int, newCues: [MKVFMP4Remuxer.SubtitleCue]) {
        cuesByTrack[track, default: []].append(contentsOf: newCues.map {
            Cue(startMs: $0.ptsTicks / 90,
                endMs: ($0.ptsTicks + $0.durTicks) / 90,
                text: Self.displayText($0.text))
        })
    }

    /// Linear scan is fine: a feature film carries ~1-2k cues per track
    /// and this runs 4x/second.
    func text(atMs ms: Int64) -> String? {
        guard let t = activeTrack, let list = cuesByTrack[t] else { return nil }
        var lines: [String] = []
        for cue in list where ms >= cue.startMs && ms < cue.endMs {
            lines.append(cue.text)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func reset() {
        tracks = []
        cuesByTrack = [:]
        activeTrack = nil
    }

    /// SRT markup (<i>, <font ...>) means nothing to a Text view; strip
    /// every angle-bracket tag for display.
    private static func displayText(_ raw: String) -> String {
        guard raw.contains("<") else { return raw }
        var out = ""
        var depth = 0
        for c in raw {
            if c == "<" { depth += 1 }
            else if c == ">" { if depth > 0 { depth -= 1 } }
            else if depth == 0 { out.append(c) }
        }
        return out
    }
}

/// Bottom-center subtitle text over an AVPlayer tile, driven by a 4Hz
/// clock against the harvested-cue store. Hidden entirely while no
/// track is enabled.
struct AVPSubtitleOverlay: View {
    @ObservedObject var store: AVPSubtitleCueStore
    let timeMs: () -> Int64
    @State private var text: String?
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    #if os(tvOS)
    private var fontSize: CGFloat { 38 }
    private var bottomInset: CGFloat { 90 }
    #else
    private var fontSize: CGFloat { 18 }
    private var bottomInset: CGFloat { 44 }
    #endif

    var body: some View {
        VStack {
            Spacer()
            if let text, store.activeTrack != nil {
                Text(text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, bottomInset)
                    .padding(.horizontal, 40)
            }
        }
        .allowsHitTesting(false)
        .onReceive(tick) { _ in
            let now = store.activeTrack == nil ? nil : store.text(atMs: timeMs())
            if now != text { text = now }
        }
    }
}

struct AVPlayerMultiviewTile: View {
    /// The owning tile's id; mute state derives from comparing this to
    /// the store's audioTileID LIVE (never from a captured snapshot,
    /// see the audio note below).
    let tileID: String
    let streamURL: URL
    let headers: [String: String]
    let shouldPause: Bool
    let channelName: String
    /// VOD tile: route MP4 direct / MKV through MKVVODServer, apply the
    /// resume offset, and never treat the URL as a live TS stream.
    var isVOD: Bool = false
    /// The per-tile store the container chrome binds to (scrubber,
    /// play-pause, track pickers, stream info). AVPlayerProgressDriver
    /// feeds it from this tile's AVPlayer, so the unified chrome works
    /// identically over an AVPlayer tile as over an mpv tile.
    let progressStore: PlayerProgressStore
    /// Parent flips this tile back to the mpv engine.
    let onEngineFallback: (String) -> Void

    @State private var player: AVPlayer?
    @State private var driver: AVPlayerProgressDriver?
    @State private var remuxer: TSHLSRemuxer?
    @State private var mkvServer: MKVVODServer?
    @State private var statusText: String?
    /// Terminal playback failure shown when mpv is disabled: a plain
    /// English explanation plus the raw internal reason in small print
    /// (users report bugs with screenshots - the diagnostic line is the
    /// iteration hook). Distinct from statusText, which means loading.
    struct TileError {
        let title: String
        let message: String
        /// Which provider copy was playing ("#1 Primary · 8.0 Mbps"),
        /// nil outside a version-switching session. Field ask
        /// 2026-08-26: the card must say WHICH version failed.
        let version: String?
        let diagnostic: String
    }
    @State private var tileError: TileError?
    /// One silent re-index retry per stream URL for index/media
    /// mismatches (provider rotating the file behind the URL). Reset on
    /// URL change so every copy gets its own retry.
    @State private var mismatchAutoRetried = false
    /// Harvested-cue subtitle state for MKV VOD playback (see
    /// AVPSubtitleCueStore). A class ref, so the server callbacks can
    /// capture it directly without the stale-struct hazard below.
    @StateObject private var subtitleStore = AVPSubtitleCueStore()
    /// AUDIO CORRECTNESS: the remuxer's onReady closure captures this
    /// view struct BY VALUE at start() time. Adding tiles moves
    /// audioTileID to the newest tile while older tiles' remuxers are
    /// still spinning up, so a closure that calls startPlayer directly
    /// would create the player from a STALE "I own audio" snapshot,
    /// unmuted. Multiple unmuted tiles was the audible result on
    /// device. Routing READY through @State (shared storage across
    /// struct copies) makes startPlayer run from onChange on the FRESH
    /// struct, and the mute decision reads the store at that moment.
    @State private var readyLocalURL: URL?
    /// KVO on the item's presentationSize; registers the tile's real
    /// video aspect with the store so the focus border hugs the video.
    @State private var sizeObservation: AnyCancellable?
    /// Fires a few seconds after start: if the item became ready but never
    /// reported a video size, the stream is audio-only to AVFoundation
    /// (e.g. HEVC carried in MPEG-TS HLS) and we fall the tile back to mpv.
    @State private var stallWatchdog: AVPStallWatchdog?
    #if os(tvOS)
    /// The display manager our criteria landed on, for teardown. Mirrors
    /// the mpv path's clearDisplayCriteria bookkeeping.
    @State private var appliedDisplayManager: AVDisplayManager?
    #endif

    var body: some View {
        ZStack {
            Color.black
            if let player {
                AVPlayerLayerView(player: player)
                AVPSubtitleOverlay(store: subtitleStore, timeMs: {
                    let s = player.currentTime().seconds
                    return s.isFinite ? Int64(s * 1000) : 0
                })
            }
            if let statusText, tileError == nil {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            if let tileError {
                VStack(spacing: 10) {
                    Image(systemName: "play.slash.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Text(tileError.title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(tileError.message)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    if let version = tileError.version {
                        Text("Version: \(version)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Text(tileError.diagnostic)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(36)
            }
        }
        .onAppear {
            AudioSessionRefCount.increment(caller: "avp-tile")
            start()
        }
        .onDisappear {
            stop()
            AudioSessionRefCount.decrement(caller: "avp-tile")
        }
        // Remux READY lands here with fresh property values.
        .onChange(of: readyLocalURL) { _, url in
            guard let url else { return }
            statusText = nil
            startPlayer(url: url, requestHeaders: [:])
            debugLog("[AVP-MV] tile playing REMUXED channel=\(channelName) muted=\(player?.isMuted == true)")
        }
        // Clear the VOD "Buffering..." spinner the moment the playhead
        // actually advances (the driver's periodic observer writes
        // currentMs for VOD only, so live is untouched).
        .onReceive(progressStore.$currentMs) { ms in
            if ms > 0, statusText == "Buffering..." { statusText = nil }
        }
        // Mute follows the store's published audio owner directly:
        // independent of SwiftUI prop diffing, fires for every change,
        // and uses the EMITTED value (the store property itself is
        // willSet-old inside this handler).
        .onReceive(MultiviewStore.shared.$audioTileID) { newAudioID in
            player?.isMuted = (newAudioID != tileID)
        }
        .onChange(of: shouldPause) { _, paused in
            if paused { player?.pause() } else { player?.play() }
        }
        // In-place channel swap on the same tile id (the container
        // swaps `tile.streamURL` without changing tile identity).
        .onChange(of: streamURL) { _, _ in
            mismatchAutoRetried = false
            stop()
            start()
        }
        // Direct-HLS playback failures have no remuxer to report them;
        // catch the item-level failure and fall back to mpv.
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let failed = note.object as? AVPlayerItem,
                  failed === player?.currentItem else { return }
            debugLog("[AVP-MV] tile playback failed channel=\(channelName); falling back to mpv tile")
            failOrFallback("playback failed")
        }
    }

    /// Every mpv-fallback trigger routes through here. With the mpv
    /// engine disabled (test flag, see PlaybackFeatureFlags), the
    /// failure stays ON SCREEN instead of being silently rescued - the
    /// whole point of the no-mpv field test is to see what breaks.
    private func failOrFallback(_ reason: String) {
        // One silent full-chain retry per stream URL for the transient
        // classes, BEFORE any mpv fallback or error card: provider
        // mid-rotation mismatches and the wedges they cause downstream
        // (the 13:33 field freeze was a dead upstream connection
        // starving the buffer - the watchdog's 'playback frozen'
        // never passed the old server.onError retry). A fresh start
        // re-indexes and reconnects; a second failure proceeds below.
        let retryable = reason.contains("file changed upstream")
            || reason.contains("no video samples")
            || reason.contains("segment build failures")
            || reason.contains("playback frozen")
            || reason.contains("playback failed")
            || reason.contains("never became ready")
            || reason.contains("range fetch HTTP 5")
            || reason.contains("persistent fetch error")
            || (reason.contains("span") && reason.contains("unreadable"))
        // LIVE included (2026-08-26 field: Sky Sports UHD died with
        // 'persistent fetch error -12888 x3' after 8 healthy minutes -
        // a one-shot re-tune is what any viewer would do before giving
        // up; the old mpv downgrade used to absorb exactly this class).
        if retryable, !mismatchAutoRetried, tileError == nil {
            mismatchAutoRetried = true
            debugLog("[AVP-MV] recoverable failure (\(reason)); auto-retrying with a fresh pipeline title=\(channelName)")
            if isVOD, progressStore.currentMs > 2_000 {
                progressStore.explicitResumeMs = progressStore.currentMs
            }
            stop()
            // A beat before the fresh start: a version switch's outgoing
            // AVPlayer drops its provider connections ASYNCHRONOUSLY, and
            // the incoming prepare landing ~250ms later can hit the
            // provider's connection cap (field find 2026-08-26, Her
            // Private Hell #7: 'range fetch HTTP 503' on every switch to
            // it). One second lets the old connections die first.
            statusText = "Retrying..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                start()
            }
            return
        }
        if PlaybackFeatureFlags.mpvEngineEnabled {
            onEngineFallback(reason)
            return
        }
        // Which provider copy was playing, for the card and the log
        // (field ask: "Stream Mismatch on WHICH version?"). Nil when
        // this session has no version context (single-copy titles,
        // live).
        let store = MultiviewStore.shared
        let versionLabel: String? = {
            guard isVOD, !store.vodVersionOptions.isEmpty else { return nil }
            guard let id = store.vodCurrentVersionID else { return "Auto" }
            return store.vodVersionOptions.first(where: { $0.id == id })?.label
        }()
        // One line with everything an iteration needs: what, where,
        // which copy, which file (sanitized), how far in, which chain.
        debugLog("[AVP-NO-MPV] FAILED \(isVOD ? "VOD" : "live") '\(channelName)' "
            + "version=\(versionLabel ?? "-") reason=\(reason) pos=\(progressStore.currentMs)ms "
            + "engine=\(mkvServer != nil ? "mkv-remux" : (remuxer != nil ? "ts-remux" : "direct")) "
            + "url=\(DebugLogger.sanitize(streamURL.absoluteString))")
        // FIRST error wins the card: the root failure (e.g. Stream
        // Mismatch with its census) must not be papered over by the
        // startup watchdog firing a generic "never became ready" a few
        // seconds later (field find, 2026-08-26: two cards back to
        // back, the informative one lost).
        guard tileError == nil else { return }
        player?.pause()
        statusText = nil
        // Terminal for this tile: stop the engines so AVPlayer's retry
        // loop can't keep hammering dead segment builds every 5s.
        mkvServer?.stop()
        remuxer?.stop()
        let friendly = Self.userFacingError(reason)
        tileError = TileError(title: friendly.title,
                              message: friendly.message,
                              version: versionLabel,
                              diagnostic: "\(reason) · mpv engine disabled (Developer setting)")
    }

    /// Map internal failure reasons to something a viewer can act on.
    /// The raw reason still shows in the small diagnostic line.
    private static func userFacingError(_ reason: String) -> (title: String, message: String) {
        let r = reason.lowercased()
        func codecName(_ marker: String) -> String {
            // "audio codec A_DTS" / "video codec V_MS/VFW/FOURCC"
            guard let range = reason.range(of: marker, options: .caseInsensitive) else { return "" }
            let raw = reason[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return raw.replacingOccurrences(of: "A_", with: "")
                .replacingOccurrences(of: "V_", with: "")
                .replacingOccurrences(of: "MPEGH/ISO/", with: "")
                .replacingOccurrences(of: "MPEG4/ISO/", with: "")
        }
        if r.contains("audio codec") {
            let codec = codecName("audio codec ")
            return ("Audio Not Supported",
                    "This copy's audio format (\(codec)) can't be decoded by this device's native player. Try another version if one is available.")
        }
        if r.contains("video codec") {
            let codec = codecName("video codec ")
            return ("Video Not Supported",
                    "This copy's video format (\(codec)) can't be decoded by this device's native player. Try another version if one is available.")
        }
        if r.contains("no cues") || r.contains("empty cues") {
            return ("File Can't Be Streamed",
                    "This copy is missing its seek index, so it can't be streamed. Try another version if one is available.")
        }
        if r.contains("contentencodings") {
            return ("File Can't Be Streamed",
                    "This copy uses compressed or encrypted tracks that can't be streamed. Try another version if one is available.")
        }
        if r.contains("file changed upstream") {
            return ("Stream Changed",
                    "The provider replaced this file while it was playing. Play again to pick up the new copy, or try another version.")
        }
        if r.contains("no video samples") || r.contains("segment build failures") {
            return ("Stream Mismatch",
                    "The provider is sending media that doesn't match this copy's index (it may be failing over between sources). Try another version or play again.")
        }
        if r.contains("playback frozen") {
            return ("Playback Stalled",
                    "Playback stopped advancing and couldn't recover. Play again, or try another version if one is available.")
        }
        if r.contains("timed out") || r.contains("stream failed")
            || r.contains("stream cancelled") || r.contains("range fetch http")
            || r.contains("persistent fetch error") {
            return ("Connection Problem",
                    "The connection to the provider stalled. Check the source and try again.")
        }
        if r.contains("never became ready") || r.contains("no video size") {
            return ("Playback Didn't Start",
                    "The stream loaded but never produced playable video. Try again, or try another version if one is available.")
        }
        return ("Unable to Play",
                "This stream couldn't be played by the native engine.")
    }

    private func start() {
        tileError = nil
        if isVOD {
            startVOD()
            return
        }
        switch classifyStreamURL(streamURL) {
        case .hls:
            // Full headers, not just UA: server-side HLS upgrades hit the
            // same Dispatcharr endpoints as the TS path and expect the
            // same auth.
            startPlayer(url: streamURL, requestHeaders: headers)
            debugLog("[AVP-MV] tile playing direct HLS channel=\(channelName)")
        default:
            statusText = "Preparing..."
            let mux = TSHLSRemuxer(sourceURL: streamURL, headers: headers)
            mux.onReady = { url in
                // @State write only; the fresh-struct onChange handler
                // does the actual player start (see readyLocalURL doc).
                readyLocalURL = url
            }
            mux.onError = { error in
                debugLog("[AVP-MV] tile remux failed (\(error)) channel=\(channelName)")
                failOrFallback("\(error)")
            }
            mux.onVideoParameters = { w, h, fps, tenBit in
                applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
            }
            remuxer = mux
            mux.start()
        }
    }

    /// VOD chain: MP4-family plays direct; everything else attempts the
    /// MKV cue-indexed remux, and a non-Matroska file gets one direct
    /// try (Dispatcharr's extensionless proxy URL can front an MP4)
    /// before the tile falls back to mpv.
    private func startVOD() {
        let ext = streamURL.pathExtension.lowercased()
        if ["mp4", "m4v", "mov"].contains(ext) {
            startPlayer(url: streamURL, requestHeaders: headers)
            // Truthful badge: the generic session label says "Remux TS",
            // which is a live-arm name; VOD is direct-play or MKV remux
            // and the dev badge should say which (field ask, 2026-08-25).
            MultiviewStore.shared.registerEngine("AVPlayer · Direct", for: tileID)
            debugLog("[AVP-MV] VOD playing direct \(ext.uppercased()) title=\(channelName)")
            return
        }
        statusText = "Preparing..."
        let server = MKVVODServer(url: streamURL, headers: headers)
        server.onReady = { url in
            readyLocalURL = url
            MultiviewStore.shared.registerEngine("AVPlayer · MKV Remux", for: tileID)
        }
        server.onVideoParameters = { w, h, fps, tenBit in
            applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
        }
        // Class ref captured directly - safe across view-struct copies
        // (unlike @State value snapshots, see AUDIO CORRECTNESS above).
        let subStore = subtitleStore
        server.onSubtitleTracks = { tracks in
            subStore.setTracks(tracks)
            debugLog("[AVP-MV] subtitle tracks: \(tracks.map(\.name).joined(separator: ", "))")
        }
        server.onSubtitleCues = { track, cues in
            subStore.add(track: track, newCues: cues)
        }
        server.onError = { reason in
            if reason.contains("not an EBML") {
                debugLog("[AVP-MV] VOD not Matroska; trying direct AVPlayer title=\(channelName)")
                // Clear the loading text: only the remux-READY path did,
                // so the direct fallback played underneath a permanent
                // "Preparing..." (field find 2026-08-26, Her Private
                // Hell - the provider had rotated the 'MKV' copies to
                // MP4s, making direct the common path for that title).
                statusText = nil
                startPlayer(url: streamURL, requestHeaders: headers)
            } else {
                // failOrFallback owns the one-shot auto-retry for the
                // transient mismatch/wedge classes.
                debugLog("[AVP-MV] VOD remux failed (\(reason)) title=\(channelName)")
                failOrFallback(reason)
            }
        }
        mkvServer = server
        server.start()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak server] _ in
            server?.purgeOnMemoryWarning()
        }
    }

    private func startPlayer(url: URL, requestHeaders: [String: String]) {
        var options: [String: Any] = [:]
        if !requestHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = requestHeaders
        }
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        // Live-edge point: trust the server, do not force an offset. The
        // Dispatcharr HLS output now pins the join point itself, correctly for
        // each mode: #EXT-X-START ~3 target durations back on the standard
        // output (safe, no CoreMedia -16832 stall-danger), and PART-HOLD-BACK
        // ~1.5s on the Low-Latency output. A hard-coded configuredTimeOffsetFromLive
        // would override both and, on the LL path, pin latency at our guess
        // instead of riding the live edge. Preserve whatever start point the
        // server hands us across stalls. (mpv never needs this: it reads a
        // continuous MPEG-TS stream with no live edge to ride.) Deliberately no
        // fallback configuredTimeOffsetFromLive when EXT-X-START is absent:
        // AVPlayer's own PART-HOLD-BACK / 3x-TARGETDURATION default is safe, an
        // override would pin LL latency, and a server that joins us into an
        // unservable edge is recovered by the stall watchdog below.
        playerItem.automaticallyPreservesTimeOffsetFromLive = true
        // Forward buffer: left at AVPlayer's automatic default (0). A device
        // capture DISPROVED the idea that a forced preferredForwardBufferDuration
        // does not gate first frame: forcing 12s gated tune-in to ~11.8s on a
        // bandwidth-limited (WAN/cellular) path, because
        // automaticallyWaitsToMinimizeStalling (default true) waits to fill that
        // buffer and a ~1x-realtime link needs ~12s to do so (Apple's own caveat
        // that a large value delays start). On LAN the same 12s filled instantly
        // (343ms first frame, zero stalls over a long run), so the cushion was
        // invisible there but pure downside off-LAN, and it did NOT prevent the
        // one WAN stall anyway. Automatic adapts per link: near-instant on LAN
        // (huge headroom keeps it stall-free), fastest-safe off-LAN. The 9s
        // offset above stays as the only explicit live-edge lever; the real
        // low-latency-AND-no-stall fix off-LAN is server-side LL-HLS.
        // EXCEPTION (2026-08-26 jetsam, second event): the MKV-remux VOD
        // path serves from loopback, where AVPlayer observes ~1.9 Gbps
        // and its automatic forward buffer balloons - on a ~65 Mbps UHD
        // remux that alone is hundreds of MB, and the app died at 1.19GB
        // footprint DURING SMOOTH PLAYBACK (rss hit 808MB within 90s of
        // start). Localhost refills 15s in ~1s, so a bounded buffer
        // costs nothing there; the WAN caveat above does not apply
        // because the slow hop (provider -> engine) has its own
        // flow-controlled buffer ahead of the loopback server.
        let isLoopbackVOD = isVOD && (url.host == "127.0.0.1" || url.host == "localhost")
        if isLoopbackVOD { playerItem.preferredForwardBufferDuration = 15 }
        debugLog("[AVP-MV] live offset=server fwdBuf=\(isLoopbackVOD ? "15s (loopback VOD)" : "automatic") channel=\(channelName)")
        let avPlayer = AVPlayer(playerItem: playerItem)
        // Live truth at this instant, never a captured snapshot.
        avPlayer.isMuted = (MultiviewStore.shared.audioTileID != tileID)
        // VOD resume (Continue Watching): the store carries the offset
        // the container preloaded; AVPlayer queues the seek until the
        // item is ready, so firing it here is safe and race-free.
        if isVOD, let ms = progressStore.explicitResumeMs, ms > 2_000 {
            let t = CMTime(value: CMTimeValue(ms), timescale: 1_000)
            // EXACT seek: infinite tolerance snapped to the nearest
            // segment boundary - up to ~6s drift per version switch with
            // 6s cue segments, which read as "doesn't pick back up at
            // the same time" when A/B-ing copies (field find
            // 2026-08-26). Exact costs one keyframe-to-target decode.
            avPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            debugLog("[AVP-MV] VOD resume seek to \(ms / 1000)s (exact) title=\(channelName)")
        }
        if !shouldPause { avPlayer.play() }
        // Loopback VOD: keep a spinner up until the clock actually
        // moves. The first segment build on a resumed 4K title over
        // slow Wi-Fi can take close to a minute, and the screen was
        // pure black the whole time (2026-08-26 iPhone find). Cleared
        // by the currentMs observer below the body.
        if isLoopbackVOD { statusText = "Buffering..." }
        player = avPlayer
        // Bridge this tile's AVPlayer into the chrome's store. When this
        // tile is the audio tile, the container chrome's scrubber /
        // play-pause / track pickers / stream info now drive it (they
        // were inert over an AVPlayer tile before). Tear any prior one
        // down first (channel swap reuses the tile).
        driver?.teardown()
        // isLive must be truthful: the driver's duration/position
        // observers all guard on it, so a VOD tile driven as live gets
        // durationMs 0 and the chrome renders the scrubber-less live
        // layout (field find: "can't scrub at all", Speak No Evil).
        driver = AVPlayerProgressDriver(
            player: avPlayer, store: progressStore, isLive: !isVOD, applyGravity: { _ in })
        // MKV subtitle picker: the overlay store owns subtitle state, so
        // the store's subtitle fields are OURS, not the driver's (the
        // legible group is empty - subs never ride the HLS master, see
        // AVPSubtitleCueStore). Must come AFTER the driver init above:
        // wireCommands just reassigned setSubtitleTrackAction.
        if isVOD, mkvServer != nil, !subtitleStore.tracks.isEmpty {
            let subStore = subtitleStore
            let store = progressStore
            store.externalSubtitleControl = true
            store.subtitleTracks = subStore.tracks.map {
                MediaTrack(id: $0.number, type: "sub", title: $0.name,
                           lang: $0.language, codec: "", isDefault: false)
            }
            store.currentSubtitleTrackID = 0
            store.setSubtitleTrackAction = { id in
                subStore.activeTrack = id == 0 ? nil : id
                store.currentSubtitleTrackID = id
                debugLog("[AVP-MV] subtitle track -> \(id == 0 ? "off" : String(id))")
            }
        }
        // Fast path: AVFoundation's own diagnosis of a rejected playlist / failed
        // reload arrives as an errorLog entry; escalate the fatal codes straight
        // to the mpv engine instead of logging and stranding the tile.
        driver?.onUnrecoverable = { failOrFallback($0) }
        // Report the real video aspect once decode knows it, so the
        // focus border can trace the picture instead of the tile frame.
        // presentationSize fires repeatedly (often with the SAME size) as the
        // pipeline settles; each distinct value writes @Published
        // tileVideoAspects, which re-lays out the whole container. removeDuplicates()
        // collapses the redundant fires so the aspect (and its layout pass) lands
        // once instead of on every KVO tick during the first-frame window. The
        // timing log tells us, from the next device run, whether that layout pass
        // is the ~650ms first-frame hang or whether the cost is inside
        // AVFoundation's own first-frame decode (in which case it isn't ours to fix).
        sizeObservation = playerItem.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { size in
                guard size.width > 0, size.height > 0 else { return }
                let t0 = Date()
                MultiviewStore.shared.registerVideoAspect(size.width / size.height, for: tileID)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if ms > 50 {
                    debugLog("[AVP-MV] registerVideoAspect relayout took \(ms)ms (size=\(Int(size.width))x\(Int(size.height)))")
                }
            }

        // Stall/freeze watchdog. Covers the old audio-only/no-renderable-video
        // case (HEVC-in-TS reaches readyToPlay with presentationSize 0x0) AND,
        // unlike the previous one-shot +4s check, keeps watching so a mid-stream
        // wedge (a rejected LL reload, a stuck live edge) that arrives AFTER the
        // first frame still self-heals to the mpv engine. Self-invalidates on
        // channel swap (currentItem changes); stop() invalidates it on teardown.
        stallWatchdog?.cancel()
        let progressServer = mkvServer
        let watchdog = AVPStallWatchdog(
            player: avPlayer, item: playerItem, label: "tile \(channelName)",
            mediaBytes: progressServer.map { s in { s.mediaBytesStreamed } },
            onDead: { failOrFallback($0) })
        watchdog.start()
        stallWatchdog = watchdog
    }

    private func stop() {
        driver?.teardown()
        driver = nil
        player?.pause()
        player = nil
        remuxer?.stop()
        remuxer = nil
        mkvServer?.stop()
        mkvServer = nil
        statusText = nil
        tileError = nil
        readyLocalURL = nil
        sizeObservation = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        subtitleStore.reset()
        progressStore.externalSubtitleControl = false
        MultiviewStore.shared.unregisterVideoAspect(for: tileID)
        #if os(tvOS)
        if let dm = appliedDisplayManager {
            appliedDisplayManager = nil
            DispatchQueue.main.async { DisplayCriteriaCoordinator.scheduleClear(dm) }
        }
        #endif
    }

    /// tvOS display-mode match for the AVPlayer tile. A bare
    /// AVPlayerLayer never triggers Match Content on its own (that is an
    /// AVPlayerViewController behavior), so the panel would stay at the
    /// home-screen 4K SDR 60 no matter what plays - the 2026-08-25 field
    /// report for the fMP4 arm's first run (HDR did not engage, TV stayed
    /// at 60Hz). Mirrors MPVPlayerView.applyMetalHDRDisplayCriteria: a
    /// distinctive-shape CMVideoFormatDescription, BT.2020/PQ extensions
    /// when the mux is 10-bit, at the measured refresh rate. The system
    /// converts HLG under an HDR10 HDMI mode, same as the mpv Metal path.
    private func applyDisplayCriteria(width: Int, height: Int, fps: Double, is10Bit: Bool) {
        #if os(tvOS)
        guard fps > 10, fps < 130 else { return }
        let window: UIWindow? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow
        guard let window else {
            debugLog("[AVP-DISPLAY] display criteria skipped: no window available")
            return
        }
        var extensions: [CFString: Any]?
        if is10Bit {
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        }
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: is10Bit ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: width > 0 ? Int32(width) : 1920,
            height: height > 0 ? Int32(height) : 1080,
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &formatDesc)
        guard status == noErr, let formatDesc else {
            debugLog("[AVP-DISPLAY] CMVideoFormatDescriptionCreate failed: \(status)")
            return
        }
        let dm = window.avDisplayManager
        appliedDisplayManager = dm
        DisplayCriteriaCoordinator.apply(
            AVDisplayCriteria(refreshRate: Float(fps), formatDescription: formatDesc), to: dm)
        debugLog("[AVP-DISPLAY] display criteria set: \(width)x\(height) " +
                 "\(is10Bit ? "bt.2020/PQ" : "SDR") @ \(String(format: "%.2f", fps))Hz " +
                 "(matchingEnabled=\(dm.isDisplayCriteriaMatchingEnabled))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak window] in
            guard let screen = window?.screen else { return }
            debugLog("[AVP-DISPLAY] panel reports \(screen.maximumFramesPerSecond)Hz 3s after criteria request")
        }
        #endif
    }
}

/// Bare AVPlayerLayer host: video only, no system chrome, sized by
/// SwiftUI like any other tile content.
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Sizing mode for the video inside the layer. Defaults to the
    /// previous hardcoded letterbox so existing call sites (multiview
    /// tiles) are unaffected; the unified player chrome drives it from
    /// the shared aspect setting.
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    final class HostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
    }
}
