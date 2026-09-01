import Foundation
import Network
import SwiftData
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
    /// Channel retention: while this remuxer ingests DETACHED (no tile
    /// playing it), keep only a couple of segments in RAM - the disk
    /// spill holds the window, and a retained UHD channel at 12 in-RAM
    /// segments would be ~350MB of dead weight (jetsam bait on tvOS).
    /// Restored to the full buffer on adoption.
    private var retainedRAMCap: Int?
    /// Catch-up: the upstream killed (or finished) the ingest but the
    /// downloaded window is intact on disk. Marking complete finalizes
    /// the playlist with EXT-X-ENDLIST so AVPlayer treats the window as
    /// a finished VOD - smooth playback to the end, no stale-playlist
    /// escalation - and the tile re-tunes only when the playhead gets
    /// there.
    private var playlistComplete = false
    /// Catch-up: declare the playlist EXT-X-PLAYLIST-TYPE:EVENT
    /// (append-only, nothing ever removed - true under full spill).
    /// Players START event playlists at the BEGINNING, which kills the
    /// join-at-edge -> seek-back-to-zero dance outright (play() was
    /// committing to the edge before the queued zero-seek applied:
    /// double buffering, a frozen edge frame, audio-before-video).
    /// NEVER set for Live Rewind - live joins want the edge.
    var eventPlaylist = false

    func markComplete() {
        queue.async {
            // Close any partial segment so its media is in the window.
            if !self.currentSegment.isEmpty, let start = self.currentStartPTS {
                self.closeSegment(endPTS: start + self.targetSegmentSeconds)
            }
            self.playlistComplete = true
        }
    }

    func setRetained(_ on: Bool) {
        queue.async {
            self.retainedRAMCap = on ? 2 : nil
            if on, self.segments.count > 2 {
                self.segments.removeFirst(self.segments.count - 2)
            }
        }
    }
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
        var p = p
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let pusi = (p[1] & 0x40) != 0

        // Catch-up (event) streams from the archive carry MALFORMED
        // IDR access units: the mux orders them SPS,PPS,AUD,SEI,slice -
        // the AUD sits mid-AU instead of leading it. ffmpeg/mpv shrug;
        // VideoToolbox's AU assembler REFUSES the track (AVFoundation
        // 'Cannot Open' -12430; on HLS the symptom was ~10s of audio
        // before any video). Non-IDR AUs are already conformant
        // (AUD,SEI,slice). Fix = length-preserving byte ROTATION inside
        // the packet: move the AUD block in front of the SPS. Bench-
        // verified: first video frame went from pos 10.3s to 0.00s.
        // Gated to eventPlaylist so the proven live path is untouched,
        // and to PES-start packets: the malformed pattern only occurs at
        // IDR AU starts, which begin a PES - scanning EVERY video packet
        // (~86k/s at line rate) fell behind ingest and ballooned the
        // pending buffer past 1GB (field 2026-08-28: stall at 5s,
        // fp=1061MB, playlist stopped growing).
        if eventPlaylist, pid == videoPID, pusi {
            fixAUDOrder(&p)
        }

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
                        var fps = 1.0 / median
                        // Snap to the nearest broadcast rate; B-pyramid PTS
                        // ordering can skew the median (a catch-up archive
                        // measured 20.00 on a 60fps feed and Match Content
                        // asked the panel for it - 5-10s of frozen video
                        // while HDMI resynced, 2026-08-28). Implausible
                        // rates never reach the display.
                        let standards: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
                        if let snap = standards.min(by: { abs($0 - fps) < abs($1 - fps) }),
                           abs(snap - fps) / snap < 0.05 {
                            fps = snap
                        }
                        if fps >= 23, fps <= 61 {
                            debugLog("[TS-REMUX] video: measured \(String(format: "%.2f", fps))fps (H.264 arm)")
                            let cb = onVideoParameters
                            DispatchQueue.main.async { cb?(0, 0, fps, false) }
                        } else {
                            debugLog("[TS-REMUX] video: measured \(String(format: "%.2f", fps))fps implausible; NOT driving display criteria")
                        }
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

    /// Rotate a malformed IDR AU's AUD in front of its SPS/PPS, in
    /// place (details at the call site). Both NALs must sit in the same
    /// TS packet - true in practice: the mux emits SPS,PPS,AUD
    /// adjacently at each PES start. A straddling case is skipped
    /// (that one AU stays malformed; VT tolerates isolated ones once
    /// the stream has opened).
    private func fixAUDOrder(_ p: inout Data) {
        guard let off = payloadStart(p), off < p.count else { return }
        var bytes = [UInt8](p)
        func find(_ pattern: [UInt8], from: Int) -> Int? {
            guard bytes.count >= pattern.count, from >= 0 else { return nil }
            var i = from
            while i <= bytes.count - pattern.count {
                if bytes[i] == pattern[0], bytes[i+1] == pattern[1],
                   bytes[i+2] == pattern[2], bytes[i+3] == pattern[3] { return i }
                i += 1
            }
            return nil
        }
        guard let sps = find([0, 0, 1, 0x67], from: off),
              let aud = find([0, 0, 1, 0x09], from: sps + 4) else { return }
        let aStart = (aud > off && bytes[aud - 1] == 0) ? aud - 1 : aud
        let aLen = (aud - aStart) + 5   // startcode(3|4) + type + payload byte
        guard aStart + aLen <= bytes.count else { return }
        let sStart = (sps > off && bytes[sps - 1] == 0) ? sps - 1 : sps
        let audBlock = Array(bytes[aStart..<(aStart + aLen)])
        let midBlock = Array(bytes[sStart..<aStart])
        bytes.replaceSubrange(sStart..<(aStart + aLen), with: audBlock + midBlock)
        p = Data(bytes)
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
        let ramCap = retainedRAMCap ?? maxBufferedSegments
        if segments.count > ramCap {
            segments.removeFirst(segments.count - ramCap)
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
        if eventPlaylist {
            text += "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        }
        if fmp4 != nil {
            text += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        }
        for segment in window {
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\nseg\(segment.seq).\(segmentFileExtension)\n"
        }
        if playlistComplete {
            text += "#EXT-X-ENDLIST\n"
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
        guard let error, (error as NSError).code != NSURLErrorCancelled else {
            // Clean EOF. For event (catch-up / local-file) playlists this
            // IS the happy ending: finalize with ENDLIST so AVPlayer gets
            // a finite VOD instead of a forever-stale live playlist (the
            // old behavior wedged the end of a fully-downloaded catch-up
            // programme into the stale-escalation path).
            if eventPlaylist {
                debugLog("[TS-REMUX] ingest complete (clean EOF); finalizing event playlist")
                markComplete()
            }
            return
        }
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
    /// The playing video's aspect ratio (width/height) when known, so
    /// the cue text anchors to the VIDEO's bottom edge, not the tile's.
    /// iPhone portrait letterboxes a 16:9 movie mid-screen, and a
    /// tile-anchored cue sat way below the picture (field find
    /// 2026-08-26). nil = assume 16:9.
    var videoAspect: () -> CGFloat? = { nil }
    @State private var text: String?
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    #if os(tvOS)
    private var fontSize: CGFloat { 38 }
    private var baseInset: CGFloat { 90 }
    #else
    private var fontSize: CGFloat { 18 }
    private var baseInset: CGFloat { 24 }
    #endif

    private func bottomInset(_ geo: GeometryProxy) -> CGFloat {
        let aspect = max(0.2, videoAspect() ?? (16.0 / 9.0))
        let videoHeight = min(geo.size.height, geo.size.width / aspect)
        return (geo.size.height - videoHeight) / 2 + baseInset
    }

    var body: some View {
        GeometryReader { geo in
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
                        .padding(.bottom, bottomInset(geo))
                        .padding(.horizontal, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .onReceive(tick) { _ in
            let now = store.activeTrack == nil ? nil : store.text(atMs: timeMs())
            if now != text { text = now }
        }
    }
}

// MARK: - Live channel retention (Logan 2026-08-27, Option B)
//
// With "Keep Recent Channels Live" on, flipping away from a live channel
// hands its still-ingesting remuxer (and its rewind spill window) to this
// manager instead of stopping it. Tuning the channel again ADOPTS the
// running remuxer, so the rewind timeline is complete - including the
// minutes spent away. Costs one concurrent upstream connection per
// retained channel, which is why it is opt-in and capped at 5.
@MainActor
final class LiveChannelRetention: ObservableObject {
    static let shared = LiveChannelRetention()

    struct Entry {
        let key: String            // resolved stream URL - the channel identity
        let channelID: String      // guide channel id (solo tile id) - the Jump target
        let channelName: String
        let remuxer: TSHLSRemuxer
        let localURL: URL          // loopback playlist URL (already READY)
        var lastActiveAt: Date
        var videoParams: (width: Int, height: Int, fps: Double, tenBit: Bool)?
    }
    @Published private(set) var entries: [Entry] = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
            Task { @MainActor in
                LiveChannelRetention.shared.stopAll(reason: "memory warning")
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "liveRewindEnabled")
            && UserDefaults.standard.bool(forKey: "liveRewindRetainChannels")
    }
    /// User-facing "channels to keep going" INCLUDING the one playing.
    static var maxChannels: Int {
        let v = UserDefaults.standard.integer(forKey: "liveRewindRetainCount")
        return min(5, max(1, v == 0 ? 2 : v))
    }

    /// Take over a still-running remuxer from a tile that is going away.
    func retain(key: String, channelID: String, channelName: String, remuxer: TSHLSRemuxer, localURL: URL) {
        guard Self.isEnabled else { remuxer.stop(); return }
        // Replace a stale entry for the same channel outright.
        if let idx = entries.firstIndex(where: { $0.key == key || $0.channelID == channelID }) {
            entries[idx].remuxer.stop()
            entries.remove(at: idx)
        }
        remuxer.setRetained(true)
        remuxer.onReady = nil
        remuxer.onError = { [weak self] error in
            Task { @MainActor in
                DebugLogger.shared.log(
                    "[AVP-RETAIN] retained '\(channelName)' died (\(error)); dropping",
                    category: "Playback", level: .warning)
                self?.drop(key: key)
            }
        }
        let entry = Entry(key: key, channelID: channelID, channelName: channelName, remuxer: remuxer,
                          localURL: localURL, lastActiveAt: Date(), videoParams: nil)
        remuxer.onVideoParameters = { [weak self] w, h, fps, tenBit in
            Task { @MainActor in
                guard let self, let idx = self.entries.firstIndex(where: { $0.key == key }) else { return }
                self.entries[idx].videoParams = (w, h, fps, tenBit)
            }
        }
        entries.append(entry)
        DebugLogger.shared.log(
            "[AVP-RETAIN] keeping '\(channelName)' live in background (\(entries.count) retained, cap \(Self.maxChannels - 1))",
            category: "Playback", level: .info)
    }

    /// A tile tuning this channel takes the running remuxer back, if
    /// kept. Channel id is the PRIMARY match: the URL key can drift
    /// between the flip-away snapshot and a fresh tune's resolution,
    /// and a missed adopt leaves a stale duplicate ingesting upstream
    /// (field find 2026-08-27: ESPNU playing AND listed as retained).
    func adopt(key: String, channelID: String) -> Entry? {
        guard let idx = entries.firstIndex(where: { $0.channelID == channelID || $0.key == key }) else { return nil }
        var e = entries.remove(at: idx)
        e.lastActiveAt = Date()
        e.remuxer.setRetained(false)
        DebugLogger.shared.log(
            "[AVP-RETAIN] adopting '\(e.channelName)' (window intact; \(entries.count) still retained)",
            category: "Playback", level: .info)
        return e
    }

    /// A NEW channel is starting fresh: the active session takes one of
    /// the user's N slots, so retained entries shrink to N-1, oldest out
    /// ("open a 6th, the first drops off").
    func evictForNewActive(activeChannelID: String? = nil) {
        guard Self.isEnabled else { stopAll(reason: "retention disabled"); return }
        // Any entry for the channel being tuned is stale by definition
        // (the tile adopts BEFORE this runs; reaching here means adopt
        // missed or a duplicate survived) - kill it before it double-
        // ingests alongside the fresh session.
        if let id = activeChannelID, let idx = entries.firstIndex(where: { $0.channelID == id }) {
            let e = entries.remove(at: idx)
            e.remuxer.stop()
            DebugLogger.shared.log(
                "[AVP-RETAIN] dropped stale entry for now-active '\(e.channelName)'",
                category: "Playback", level: .warning)
        }
        let keep = Self.maxChannels - 1
        while entries.count > keep {
            if let idx = entries.indices.min(by: { entries[$0].lastActiveAt < entries[$1].lastActiveAt }) {
                let e = entries.remove(at: idx)
                e.remuxer.stop()
                DebugLogger.shared.log(
                    "[AVP-RETAIN] evicted oldest '\(e.channelName)' (over cap)",
                    category: "Playback", level: .info)
            } else { break }
        }
    }

    func drop(key: String) {
        guard let idx = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[idx].remuxer.stop()
        entries.remove(at: idx)
    }

    func stopAll(reason: String) {
        guard !entries.isEmpty else { return }
        DebugLogger.shared.log(
            "[AVP-RETAIN] stopping all \(entries.count) retained channels (\(reason))",
            category: "Playback", level: .info)
        entries.forEach { $0.remuxer.stop() }
        entries.removeAll()
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
    /// The GUIDE channel id (tile.item.id). NOT tileID: a tile's id is
    /// pinned at seed and survives in-place channel flips, so it names
    /// the ORIGINAL channel forever - keying retention on it made the
    /// first flip adopt the just-retained old channel back (black
    /// screen, 2026-08-27). This is the retention identity and the
    /// Jump-to-Channel deep-link target.
    var channelID: String = ""

    /// VOD tile: route MP4 direct / MKV through MKVVODServer, apply the
    /// resume offset, and never treat the URL as a live TS stream.
    var isVOD: Bool = false
    /// In-progress server recording over its live-style HLS playlist.
    /// Plays direct (AVPlayer speaks HLS natively - no remuxer, no MKV
    /// server) with the driver in DVR-window mode: growing scrubber,
    /// live-edge default, exact seeks anywhere in the recorded window.
    var isDVR: Bool = false
    /// Resume offset handed straight from tile.resumePositionMs. The
    /// progress-store copy (explicitResumeMs) is applied by the PARENT
    /// view's onAppear, which fires AFTER this child's - so a player
    /// started synchronously in start() (direct HLS/MP4) read nil and
    /// never seeked (field find 2026-08-27: DVR resume landed at the
    /// live edge). The store copy still wins when present (version
    /// switches update it mid-session); this is the launch fallback.
    var resumePositionMs: Int32? = nil
    /// Catch-up replay payload (.catchup tiles): archive TS window with
    /// the mpv-parity re-tune seek model. The remuxer's single plain GET
    /// is exactly the transport contract the archive needs (one session,
    /// no range probes, no duration probe).
    var catchup: CatchupPlayback? = nil
    /// The per-tile store the container chrome binds to (scrubber,
    /// play-pause, track pickers, stream info). AVPlayerProgressDriver
    /// feeds it from this tile's AVPlayer, so the unified chrome works
    /// identically over an AVPlayer tile as over an mpv tile.
    let progressStore: PlayerProgressStore
    /// Solo/fullscreen tile: arm Picture in Picture on the video layer
    /// (grid tiles never PiP, mpv-path parity). Passed by the parent as
    /// isSoleTile so the flag tracks tile-count changes.
    var pipEnabled: Bool = false
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
    /// Budget 2 (was a one-shot): Dispatcharr's per-connection VOD
    /// failover can serve a DIFFERENT provider copy under the same URL
    /// mid-session, so a fresh re-index can land on a copy whose cues
    /// disagree with the next connection's media again (field
    /// 2026-08-29, Thor #6: first mismatch retried at 1min, second at
    /// 3.6min went straight to the card). Two fresh pipelines before
    /// giving up absorbs a one-time flip AND a flip-back.
    @State private var mismatchAutoRetries = 0
    /// Live Rewind armed for this tile: the remuxer was created with a
    /// spill window (solo live + setting on), so the driver runs in
    /// rewind-window mode and LiveRewindEngine mirrors the window for
    /// the chrome. Dropped when a second tile joins (grid chrome has no
    /// scrubber; the spill ring keeps running, disk-bounded).
    @State private var liveRewindArmed = false
    /// Identity of the session THIS tile is actually running, snapshotted
    /// at start(). stop() retains under these - NEVER under the struct's
    /// current streamURL/channelID, which a channel-flip onChange has
    /// already advanced to the INCOMING channel (two field black-screens
    /// from exactly that trap, 2026-08-27).
    @State private var sessionRetainKey: String?
    @State private var sessionRetainChannelID: String?
    @State private var sessionRetainName: String?
    /// Catch-up: programme-relative ms offset of the CURRENT window and
    /// the (re-minted/rebuilt) URL serving it. streamURL stays the
    /// original programme-start URL.
    @State private var catchupBaseMs: Int32 = 0
    @State private var catchupURL: URL?
    @State private var catchupMintInFlight = false
    @State private var lastCatchupReportAt = Date.distantPast
    /// Position of the last dead-pipeline reconnect; a fresh reconnect
    /// is allowed only after 15s of real progress past it.
    @State private var lastCatchupReconnectMs: Int32 = -1
    /// The pipeline was quiesced by didEnterBackground (PiP inactive):
    /// ingest + loopback sockets die under app suspension anyway, so the
    /// tile tears down CLEANLY on the way out (freeing the provider
    /// slot) instead of waking up to "ingest failed: The request timed
    /// out." + a -12888 stale playlist and the error card (field
    /// 2026-08-29). willEnterForeground rebuilds the pipeline.
    @State private var backgroundSuspended = false
    /// Position saved at quiesce for kinds that can resume in place.
    @State private var backgroundResumeMs: Int32 = 0
    /// Previous isPiPActive, to catch "PiP closed while the app is
    /// still backgrounded" - the ONE path where suspension arrives with
    /// no didEnterBackground left to quiesce for it.
    @State private var pipWasActive = false
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
                AVPlayerLayerView(player: player,
                                  pipStore: pipEnabled ? progressStore : nil)
                AVPSubtitleOverlay(store: subtitleStore, timeMs: {
                    let s = player.currentTime().seconds
                    return s.isFinite ? Int64(s * 1000) : 0
                }, videoAspect: { [tileID] in
                    MultiviewStore.shared.tileVideoAspects[tileID]
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
            // Final teardown of a native catch-up session frees its
            // provider slot server-side (seek re-tunes revoke their own
            // predecessors; this covers the last window).
            if let cu = catchup, cu.nativeChannelUUID != nil {
                CatchupSupport.revokeNative(playback: cu, currentURL: catchupURL ?? streamURL)
            }
            AudioSessionRefCount.decrement(caller: "avp-tile")
        }
        #if os(iOS)
        // Background lifecycle (field 2026-08-29): quiesce cleanly on the
        // way out, rebuild on the way back. PiP-active sessions skip both
        // (iOS keeps the process running and the pipeline healthy).
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in
            quiesceForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            resumeFromBackground()
        }
        // PiP closed while still backgrounded: suspension follows with no
        // further lifecycle callback, so quiesce right here.
        .onReceive(progressStore.$isPiPActive) { active in
            if pipWasActive, !active,
               UIApplication.shared.applicationState == .background {
                debugLog("[AVP-PIP] closed while backgrounded; quiescing pipeline")
                quiesceForBackground()
            }
            pipWasActive = active
        }
        #endif
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
            // Native catch-up sessions want periodic position reports
            // (server-side resume + session keepalive), mpv parity 20s.
            if let cu = catchup, cu.nativeChannelUUID != nil, ms > 0,
               Date().timeIntervalSince(lastCatchupReportAt) >= 20 {
                lastCatchupReportAt = Date()
                let url = catchupURL ?? streamURL
                let paused = progressStore.isPaused
                Task {
                    _ = await CatchupSupport.reportNativePosition(
                        playback: cu, currentURL: url,
                        positionSecs: Double(ms) / 1000.0, paused: paused)
                }
            }
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
            mismatchAutoRetries = 0
            stop()
            start()
        }
        // A second tile joining drops the rewind UI (grid chrome has no
        // scrubber; mpv parity - its relay falls back to direct too).
        .onReceive(NotificationCenter.default.publisher(for: .aerioLiveRewindDropRelay)) { _ in
            guard liveRewindArmed else { return }
            liveRewindArmed = false
            driver?.liveRewindWindowActive = false
            LiveRewindEngine.shared.endExternalWindow(owner: tileID)
            debugLog("[AVP-REWIND] window dropped (second tile)")
        }
        // Catch-up: EOF of the finalized downloaded window with programme
        // left = re-tune a fresh session at the playhead. A real
        // programme end (within 30s of the pinned duration) just stops.
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let cu = catchup,
                  let ended = note.object as? AVPlayerItem,
                  ended === player?.currentItem else { return }
            let pos = progressStore.currentMs
            if pos < cu.programDurationMs - 30_000 {
                debugLog("[AVP-CU] downloaded window exhausted at \(pos / 1000)s; re-tuning for the next window")
                statusText = "Loading..."
                retuneCatchupWindow(pos, cu)
            } else {
                debugLog("[AVP-CU] programme complete at \(pos / 1000)s")
            }
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
        #if os(iOS)
        // Quiesced (or mid-quiesce) for background: any error racing the
        // teardown is noise from the pipeline we are already stopping;
        // foreground rebuilds fresh. Same for an error arriving while
        // suspended-adjacent (state .background with PiP inactive) - the
        // resume handler owns recovery, not the card.
        if backgroundSuspended { return }
        if UIApplication.shared.applicationState == .background,
           !progressStore.isPiPActive {
            debugLog("[AVP-MV] failure while backgrounded (\(reason)); deferring to foreground rebuild channel=\(channelName)")
            quiesceForBackground()
            return
        }
        #endif
        // MKV master-playlist rejection (field 2026-08-29, -12927 on a
        // UHD remux whose SPS carries custom scaling lists): CoreMedia's
        // MULTIVARIANT loader parses the init's parameter sets with a
        // stricter reader than the plain media-playlist path, and fails
        // the item before the first segment. The server is healthy -
        // re-point the SAME session at its bare vod.m3u8 (alternate
        // audio renditions are lost, playback is not). One-shot by
        // construction: the retry flips readyLocalURL off master.m3u8.
        if reason.contains("-12927"), mkvServer != nil,
           let ready = readyLocalURL, ready.lastPathComponent == "master.m3u8" {
            let media = ready.deletingLastPathComponent().appendingPathComponent("vod.m3u8")
            debugLog("[AVP-MV] master playlist rejected (-12927); retrying on plain media playlist (alternate audio dropped) title=\(channelName)")
            readyLocalURL = media
            statusText = "Buffering..."
            startPlayer(url: media, requestHeaders: [:])
            return
        }
        // In-progress DVR: ANY terminal error most likely means the
        // recording just finished (Dispatcharr finalizes and the /hls/
        // playlist route starts serving the SPA's HTML -> -12646
        // "Playlist parse error"; a stop without finalize just starves
        // the edge into the stale-playlist escalation). Runs BEFORE the
        // generic auto-retry: re-tuning a finalized playlist just flashes
        // "Retrying..." and fails again (field find 2026-08-27). One shot:
        // migrate the tile onto the completed /file/ endpoint at the
        // current position. The store swap changes streamURL, which the
        // onChange restart picks up; a false return (unexpected URL
        // shape) falls through to the normal card.
        if isDVR, tileError == nil {
            let pos = progressStore.currentMs
            debugLog("[AVP-MV] DVR terminal (\(reason)); attempting completed-file migration at \(pos)ms title=\(channelName)")
            if MultiviewStore.shared.migrateDVRTileToCompletedFile(tileID: tileID, positionMs: pos) {
                statusText = "Recording finished. Reloading..."
                stop()
                return
            }
        }

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
            // A fresh live ingest can 500 while the proxy is still
            // tearing down the previous connection for the same channel
            // (fast swap-back; field 2026-08-28 ESPN at pos=0). Same
            // transient class as the version-switch 503 - the 1s-delayed
            // one-shot retry lets the teardown drain.
            || reason.contains("ingest failed: HTTP 5")
            // Suspension-adjacent socket death that slipped past the
            // background quiesce (notification shade dwell, brief app
            // switch): the connection is simply gone, and a fresh
            // pipeline is what any viewer would try (field 2026-08-29).
            // NOT for catch-up tiles: their session-bound URL must go
            // through the position-preserving re-mint branch below, not
            // a generic programme-start restart.
            || (catchup == nil && (reason.contains("timed out")
                    || reason.contains("network connection was lost")))
            || reason.contains("persistent fetch error")
            || (reason.contains("span") && reason.contains("unreadable"))
        // LIVE included (2026-08-26 field: Sky Sports UHD died with
        // 'persistent fetch error -12888 x3' after 8 healthy minutes -
        // a one-shot re-tune is what any viewer would do before giving
        // up; the old mpv downgrade used to absorb exactly this class).
        // Deterministic mid-file CoreMedia decode failure on the MKV remux
        // path (tester 2026-08-31: Code=-4 at exactly 63813ms on two
        // separate attempts of the same 20Mbps title): one cluster in this
        // copy remuxes into something CoreMedia refuses. A plain retry at
        // the same position dies identically, so retry once skipping 3s
        // past the poisonous sample -- and log the segment/byte range so
        // the copy can be fetched and benched offline. Bounded by the same
        // retry budget as the generic path.
        if reason.contains("Code=-4"), isVOD, let srv = mkvServer,
           mismatchAutoRetries < 2, tileError == nil {
            let pos = max(progressStore.currentMs, 0)
            mismatchAutoRetries += 1
            debugLog("[AVP-MV] CoreMedia -4 at \(pos)ms (\(srv.diagnostics(forMs: pos))); "
                + "retrying 3s past the failing sample title=\(channelName)")
            progressStore.explicitResumeMs = pos + 3_000
            stop()
            statusText = "Retrying..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                start()
            }
            return
        }
        if retryable, mismatchAutoRetries < 2, tileError == nil {
            mismatchAutoRetries += 1
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
        // Catch-up: the archive session is single-use and the upstream
        // KILLS greedy connections (field 2026-08-28: 2GB in ~2min,
        // then 'network connection was lost'). A generic retry would
        // replay the dead session URL; re-mint/rebuild at the current
        // position instead. Allowed again each time playback has
        // advanced 15s+ since the last reconnect - repeated failures
        // at the same spot fall through to the card.
        if let cu = catchup, tileError == nil {
            let pos = progressStore.currentMs
            if pos > lastCatchupReconnectMs + 15_000 || lastCatchupReconnectMs < 0 {
                lastCatchupReconnectMs = max(pos, 0)
                debugLog("[AVP-CU] pipeline died (\(reason)); reconnecting at \(pos / 1000)s title=\(channelName)")
                statusText = "Reconnecting..."
                retuneCatchupWindow(max(pos, 0), cu)
                return
            }
        }
        if PlaybackFeatureFlags.mpvEngineEnabled {
            onEngineFallback(reason)
            return
        }
        // Live ingest 404: the channel's stream UUID is GONE server-side
        // (Dispatcharr removed or rotated the channel - PGA/event
        // streams are torn down when coverage ends, and the app's
        // channel row keeps the stale UUID until the next playlist
        // sync). Playback cannot be saved, but kick a channel refresh
        // so the guide corrects itself while the user reads the card
        // (field 2026-08-30: three PGA event channels 404'd in a row).
        if !isVOD, !isDVR, catchup == nil, reason.contains("ingest failed: HTTP 404") {
            Task { @MainActor in
                guard let container = AerioApp.sharedContainer else { return }
                let servers = (try? ModelContext(container).fetch(FetchDescriptor<ServerConnection>())) ?? []
                guard !servers.isEmpty else { return }
                debugLog("[AVP-MV] live ingest 404; kicking channel refresh to re-resolve the stale channel list")
                ChannelStore.shared.refresh(servers: servers)
            }
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
        // A paused AVPlayer still reloads a live playlist (field log
        // 2026-08-27: ~10s of -12646 spam AFTER the card went up).
        // Dropping the item ends the loading session outright; Retry
        // rebuilds a fresh player from streamURL anyway.
        player?.replaceCurrentItem(with: nil)
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
        if r.contains("unsupported codec: mpeg-2") {
            // OTA/ATSC broadcast channels (field 2026-08-31, second tester:
            // every OTA channel failed with a generic card). Apple silicon
            // has no MPEG-2 decoder; name the real constraint instead of
            // implying the channel is broken.
            return ("Channel Not Supported",
                    "This channel broadcasts MPEG-2 video (over-the-air TV), "
                    + "which this device can't decode natively. See the "
                    + "OTA / HDHomeRun section of the AerioTV GitHub README "
                    + "for a Dispatcharr Stream Profile that fixes this.")
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
        if r.contains("ingest failed: http 404") {
            return ("Channel Unavailable",
                    "The server no longer offers this stream. Event channels disappear when their coverage ends; the channel list is refreshing now, so check the guide again in a moment.")
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

    #if os(iOS)
    /// didEnterBackground with PiP inactive: the process is about to be
    /// suspended, which kills the ingest connection and the loopback
    /// server's sockets no matter what we do - so tear the pipeline down
    /// CLEANLY now (freeing the provider slot for the whole background
    /// stay) and remember to rebuild on foreground. Without this, the
    /// wake-up delivered "ingest failed: The request timed out." plus a
    /// -12888 stale-playlist error and the terminal card (field log
    /// 2026-08-29, Clippers game).
    private func quiesceForBackground() {
        guard !progressStore.isPiPActive else { return }
        guard tileError == nil, player != nil || statusText != nil else { return }
        backgroundResumeMs = progressStore.currentMs
        if isVOD, progressStore.currentMs > 2_000 {
            progressStore.explicitResumeMs = progressStore.currentMs
        }
        // Never hand the remuxer to LiveChannelRetention from here: the
        // app is leaving the screen and retention's own app-background
        // policy stops every kept session anyway. Clearing the retain
        // snapshot makes stop() release instead of retain.
        sessionRetainKey = nil
        sessionRetainChannelID = nil
        stop()
        backgroundSuspended = true
        debugLog("[AVP-MV] pipeline quiesced for background channel=\(channelName) pos=\(backgroundResumeMs)ms")
    }

    /// willEnterForeground after a quiesce: rebuild the pipeline. Live
    /// returns at the live edge, VOD resumes via explicitResumeMs, DVR
    /// returns at its live edge, catch-up re-tunes its window at the
    /// saved position (the dead-pipeline reconnect path).
    private func resumeFromBackground() {
        guard backgroundSuspended else { return }
        backgroundSuspended = false
        // Each background cycle earns fresh silent retries; without the
        // reset the second background trip went straight to the card.
        mismatchAutoRetries = 0
        statusText = "Reconnecting..."
        debugLog("[AVP-MV] rebuilding pipeline after background channel=\(channelName)")
        if let cu = catchup, backgroundResumeMs > 0 {
            lastCatchupReconnectMs = backgroundResumeMs
            retuneCatchupWindow(backgroundResumeMs, cu)
        } else {
            start()
        }
    }
    #endif

    private func start() {
        tileError = nil
        if let cu = catchup {
            startCatchup(cu)
            return
        }
        if isDVR {
            // Growing HLS window from the server's DVR pipeline: direct
            // play, no remux chain. The driver (DVR-window mode via
            // progressStore.isDVRWindow) owns the timeline.
            startPlayer(url: streamURL, requestHeaders: headers)
            MultiviewStore.shared.registerEngine("AVPlayer · DVR HLS", for: tileID)
            debugLog("[AVP-MV] DVR tile playing direct HLS title=\(channelName)")
            return
        }
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
            // Live Rewind (task #145, AVPlayer port 2026-08-27): solo
            // live sessions spill every closed segment to disk and the
            // playlist advertises the whole window - AVPlayer native
            // seek IS the rewind. Both arms spill (TS .ts / fMP4 .m4s).
            let rewindSeconds: Double = {
                guard MultiviewStore.shared.tiles.count == 1,
                      UserDefaults.standard.bool(forKey: "liveRewindEnabled") else { return 0 }
                let mins = UserDefaults.standard.integer(forKey: "liveRewindDepthMinutes")
                return Double(mins > 0 ? mins : 30) * 60
            }()
            liveRewindArmed = rewindSeconds > 0
            sessionRetainKey = streamURL.absoluteString
            sessionRetainChannelID = channelID
            sessionRetainName = channelName
            if liveRewindArmed {
                debugLog("[AVP-REWIND] armed: \(Int(rewindSeconds))s spill window channel=\(channelName)")
                // Channel retention: if this channel's remuxer is still
                // ingesting from a recent flip, adopt it - the rewind
                // window (including the time away) comes back intact.
                if let entry = LiveChannelRetention.shared.adopt(key: streamURL.absoluteString,
                                                                 channelID: channelID) {
                    let mux = entry.remuxer
                    mux.onError = { error in
                        debugLog("[AVP-MV] tile remux failed (\(error)) channel=\(channelName)")
                        failOrFallback("\(error)")
                    }
                    mux.onVideoParameters = { w, h, fps, tenBit in
                        applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
                    }
                    if let vp = entry.videoParams {
                        applyDisplayCriteria(width: vp.width, height: vp.height,
                                             fps: vp.fps, is10Bit: vp.tenBit)
                    }
                    remuxer = mux
                    statusText = nil
                    // The onChange(readyLocalURL) handler starts the player.
                    // With retain keys correct this always sees a real value
                    // change (fresh tile: nil -> URL; flip-back: other
                    // channel's port -> this one's), so no direct start here
                    // - that would double-start the player.
                    readyLocalURL = entry.localURL
                    debugLog("[AVP-RETAIN] tile resuming adopted window channel=\(channelName)")
                    return
                }
                // Fresh live session takes one of the N retention slots.
                LiveChannelRetention.shared.evictForNewActive(activeChannelID: channelID)
            }
            let mux = TSHLSRemuxer(sourceURL: streamURL, headers: headers,
                                   rewindWindowSeconds: rewindSeconds)
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

    /// Catch-up: ingest the archive TS window through the live remux arm
    /// (ONE plain GET - the exact transport contract the single-use
    /// session needs) and pin the chrome timeline to the EPG duration.
    /// Seeks are window re-tunes (mpv parity): rebuild/re-mint the URL
    /// at the target offset and restart the pipeline.
    private func startCatchup(_ cu: CatchupPlayback) {
        statusText = "Loading..."
        progressStore.durationMs = cu.programDurationMs
        progressStore.currentMs = catchupBaseMs
        let source = catchupURL ?? streamURL
        // Spill the WHOLE window to disk: archive servers deliver at
        // line rate, not realtime (the reason mpv's relay spooled to
        // disk and tailed at playback speed). Without spill the live
        // arm's 12-segment RAM ring rolls segments off faster than the
        // player consumes them - stutter, then a dead pipeline (field,
        // 2026-08-28 First Take). With it, nothing rolls off and
        // in-window seeks are native.
        let windowSecs = Double(max(60_000, cu.programDurationMs)) / 1000.0 + 300
        let mux = TSHLSRemuxer(sourceURL: source, headers: headers,
                               rewindWindowSeconds: windowSecs)
        mux.eventPlaylist = true
        mux.onReady = { url in
            readyLocalURL = url
            MultiviewStore.shared.registerEngine("AVPlayer · Catch-up", for: tileID)
        }
        mux.onError = { [weak mux] error in
            let reason = "\(error)"
            // The upstream kills greedy line-rate connections every ~2min
            // with 20+ min of content already spilled. Ingest death is
            // NOT playback death: finalize the playlist (ENDLIST) and
            // keep playing the downloaded window; the EOF handler
            // re-tunes when the playhead reaches its end. Only a death
            // BEFORE anything played falls through to the error path.
            if reason.contains("ingest failed"), progressStore.currentMs > 0 || readyLocalURL != nil {
                debugLog("[AVP-CU] ingest died (\(reason)); window finalized, playback continues title=\(channelName)")
                mux?.markComplete()
                return
            }
            debugLog("[AVP-CU] remux failed (\(reason)) title=\(channelName)")
            failOrFallback(reason)
        }
        mux.onVideoParameters = { w, h, fps, tenBit in
            applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
        }
        remuxer = mux
        mux.start()
        debugLog("[AVP-CU] ingest start base=\(catchupBaseMs / 1000)s title=\(channelName)")
    }

    /// Chrome seekAction in catch-up mode: target is programme-relative
    /// ms. Native Dispatcharr sessions re-mint (full-second precision,
    /// old session revoked); XC-shaped rebuilds the timeshift URL floored
    /// to the minute. Both restart the remux pipeline at the new window.
    private func performCatchupSeek(_ targetMs: Int32, _ cu: CatchupPlayback) {
        let dur = max(0, cu.programDurationMs)
        let clamped = min(max(targetMs, 0), max(0, dur - 5_000))
        // In-window fast path: the whole window spills to disk and the
        // ingest runs at line rate, so most targets are ALREADY local -
        // seek the player natively instead of burning a server re-tune
        // (and, on native sessions, a mint/revoke round trip).
        if let item = player?.currentItem,
           let range = item.seekableTimeRanges.last?.timeRangeValue {
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            let rel = Double(clamped - catchupBaseMs) / 1000.0
            if start.isFinite, end.isFinite, rel >= start, rel <= end - 2 {
                debugLog("[AVP-CU] in-window seek -> \(clamped / 1000)s (local)")
                player?.seek(to: CMTime(seconds: rel, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
                progressStore.currentMs = clamped
                if player?.timeControlStatus == .paused { player?.play() }
                return
            }
        }
        retuneCatchupWindow(clamped, cu)
    }

    /// The actual window re-tune (server round trip + pipeline restart),
    /// shared by out-of-window seeks and dead-pipeline reconnects (which
    /// must NOT take the in-window fast path - the loopback is dead).
    private func retuneCatchupWindow(_ clamped: Int32, _ cu: CatchupPlayback) {
        if cu.nativeChannelUUID != nil {
            guard !catchupMintInFlight else {
                debugLog("[AVP-CU] seek dropped (mint in flight)")
                return
            }
            catchupMintInFlight = true
            statusText = "Loading..."
            progressStore.currentMs = clamped   // optimistic, mpv parity
            let previous = catchupURL ?? streamURL
            debugLog("[AVP-CU] native re-tune -> \(clamped / 1000)s title=\(channelName)")
            Task { @MainActor in
                defer { catchupMintInFlight = false }
                guard let newURL = await CatchupSupport.remintNative(
                    playback: cu, currentURL: previous,
                    offsetSeconds: Double(clamped) / 1000.0) else {
                    debugLog("[AVP-CU] native re-mint failed; keeping current window")
                    statusText = nil
                    return
                }
                CatchupSupport.revokeNative(playback: cu, currentURL: previous)
                catchupURL = newURL
                catchupBaseMs = clamped
                stop()
                start()
            }
        } else {
            let flooredSecs = Double((Int(clamped) / 60_000) * 60)
            guard let newURL = CatchupSupport.rebuildForOffset(
                url: catchupURL ?? streamURL,
                panelTimeZoneID: cu.panelTimeZoneID,
                programStart: cu.programStart, programEnd: cu.programEnd,
                offsetSeconds: flooredSecs) else {
                debugLog("[AVP-CU] XC rebuild failed; keeping current window")
                return
            }
            catchupURL = newURL
            catchupBaseMs = Int32(flooredSecs * 1000)
            progressStore.currentMs = catchupBaseMs
            statusText = "Loading..."
            debugLog("[AVP-CU] XC re-tune -> \(Int(flooredSecs))s (minute-floored) title=\(channelName)")
            stop()
            start()
        }
    }

    /// VOD chain: MP4-family plays direct; everything else attempts the
    /// MKV cue-indexed remux, and a non-Matroska file gets one direct
    /// try (Dispatcharr's extensionless proxy URL can front an MP4)
    /// before the tile falls back to mpv.
    private func startVOD() {
        let ext = streamURL.pathExtension.lowercased()
        if streamURL.isFileURL || ext == "ts" {
            // Local-file recordings (and any raw .ts VOD): AVPlayer can't
            // open bare TS, so ingest through the live remux arm as an
            // event playlist - disk-speed ingest finalizes with ENDLIST
            // within seconds and the file plays as normal seekable VOD.
            // The spill window temporarily duplicates the file next to
            // the LiveRewind spill (same budget sweeper bounds it).
            statusText = "Preparing..."
            let mux = TSHLSRemuxer(sourceURL: streamURL, headers: headers,
                                   rewindWindowSeconds: 21_600)
            mux.eventPlaylist = true
            mux.onReady = { url in
                readyLocalURL = url
                MultiviewStore.shared.registerEngine("AVPlayer · TS Remux", for: tileID)
            }
            mux.onError = { error in
                debugLog("[AVP-MV] TS-file remux failed (\(error)) title=\(channelName)")
                failOrFallback("\(error)")
            }
            mux.onVideoParameters = { w, h, fps, tenBit in
                applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
            }
            remuxer = mux
            mux.start()
            debugLog("[AVP-MV] VOD via TS ingest (\(streamURL.isFileURL ? "local file" : "raw ts")) title=\(channelName)")
            return
        }
        if ext == "m3u8" {
            // HLS-fronted VOD (e.g. a finished server recording exposed
            // as a playlist): native AVPlayer territory, never the MKV
            // chain (the magic-bytes probe would just bounce it anyway).
            startPlayer(url: streamURL, requestHeaders: headers)
            MultiviewStore.shared.registerEngine("AVPlayer · Direct HLS", for: tileID)
            debugLog("[AVP-MV] VOD playing direct HLS title=\(channelName)")
            return
        }
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
        // Stream Buffer (Settings > App Behaviors), AVPlayer-live parity
        // with mpv's cache-secs: a bursty upstream (field 2026-08-30, MLS
        // event feed arriving at 0.8x realtime for ~25s stretches, then
        // catching up in bursts) starves a player holding only the
        // default ~3-target-duration edge distance - one ~2s stall per
        // window. The user's chosen seconds ride ON TOP of that default
        // so 0 stays byte-identical to today's low-latency join, and a
        // 3-5s setting absorbs the deficit at the cost of that much
        // added latency. Live tiles only: VOD/DVR/catch-up have no edge.
        let streamBufferSeconds = UserDefaults.standard.double(forKey: "appBehaviorsStreamBufferSeconds")
        if !isVOD, !isDVR, catchup == nil, streamBufferSeconds > 0 {
            playerItem.configuredTimeOffsetFromLive =
                CMTime(seconds: 6 + streamBufferSeconds, preferredTimescale: 600)
            debugLog("[AVP-MV] live edge offset raised to \(6 + streamBufferSeconds)s (Stream Buffer setting) channel=\(channelName)")
        }
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
        let isLoopback = (url.host == "127.0.0.1" || url.host == "localhost")
        let isLoopbackVOD = isVOD && isLoopback
        // Catch-up loopback too: line-rate ingest leaves an hours-deep
        // "live" window that automatic buffering gorges on at ~3Gbps
        // during startup - churn that lets audio start while video
        // decode lags seconds behind (field 2026-08-28). 15s bounds it;
        // the disk window makes deeper buffering pointless anyway.
        if isLoopbackVOD || (catchup != nil && isLoopback) {
            playerItem.preferredForwardBufferDuration = 15
        }
        debugLog("[AVP-MV] live offset=server fwdBuf=\(isLoopbackVOD ? "15s (loopback VOD)" : "automatic") channel=\(channelName)")
        let avPlayer = AVPlayer(playerItem: playerItem)
        // Live truth at this instant, never a captured snapshot.
        avPlayer.isMuted = (MultiviewStore.shared.audioTileID != tileID)
        // VOD resume (Continue Watching): the store carries the offset
        // the container preloaded; AVPlayer queues the seek until the
        // item is ready, so firing it here is safe and race-free.
        let resumeMs = progressStore.explicitResumeMs ?? resumePositionMs
        if isDVR, resumeMs == 0 {
            // "Watch from Beginning" on an in-progress recording: without
            // a seek, a live-shaped playlist starts at the live edge.
            // The pre-ready queued seek alone is NOT enough: when the item
            // reaches readyToPlay, AVPlayer's live-edge positioning for a
            // live-shaped playlist stomps it, and playback lands at the
            // edge anyway (tester 2026-08-31: "Watch from Beginning went
            // to Live"; log showed the queued seek then edge=-7.0s). So
            // re-issue the seek at readiness, when it sticks. The DVR
            // playlist never rolls anything off, so position 0 is always
            // in the window.
            avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            var readyObs: NSKeyValueObservation?
            readyObs = playerItem.observe(\.status, options: [.new]) { item, _ in
                guard item.status != .unknown else { return }
                if item.status == .readyToPlay {
                    avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    debugLog("[AVP-MV] DVR from-beginning seek re-issued at readyToPlay")
                }
                readyObs?.invalidate()
                readyObs = nil
            }
            debugLog("[AVP-MV] DVR from-beginning seek queued title=\(channelName)")
        }
        if isVOD || isDVR, let ms = resumeMs, ms > 2_000 {
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
            player: avPlayer, store: progressStore,
            isLive: !(isVOD || isDVR || catchup != nil), applyGravity: { _ in })
        if let cu = catchup {
            // Pinned EPG duration + base-offset position composition; the
            // chrome's seekAction becomes the window re-tune (must come
            // AFTER driver init - wireCommands just installed the plain
            // seek).
            driver?.catchupBaseMs = catchupBaseMs
            progressStore.durationMs = cu.programDurationMs
            progressStore.seekAction = { target in performCatchupSeek(target, cu) }
        }
        if liveRewindArmed, !isVOD, !isDVR {
            driver?.liveRewindWindowActive = true
            LiveRewindEngine.shared.beginExternalWindow(owner: tileID)
        }
        // MKV-remux tiles: tell the loopback server about every user seek
        // so it can drop the old neighbourhood's span/segment caches
        // (~200MB of stale Data on a high-bitrate title). Wrap must come
        // AFTER driver init (wireCommands just installed the plain seek)
        // and stays out of the catch-up branch (mutually exclusive with
        // mkvServer, but ordering here keeps that obvious).
        if isVOD, let srv = mkvServer {
            let baseSeek = progressStore.seekAction
            progressStore.seekAction = { [weak srv] target in
                srv?.noteSeek()
                baseSeek?(target)
            }
        }
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
        if liveRewindArmed {
            LiveRewindEngine.shared.endExternalWindow(owner: tileID)
            // Channel retention: hand a HEALTHY rewind session to the
            // manager instead of stopping it, so flipping back resumes
            // the full window. Errored tiles stop as before.
            if LiveChannelRetention.isEnabled, tileError == nil,
               let mux = remuxer, let url = readyLocalURL,
               let key = sessionRetainKey, let chID = sessionRetainChannelID {
                LiveChannelRetention.shared.retain(
                    key: key, channelID: chID,
                    channelName: sessionRetainName ?? channelName,
                    remuxer: mux, localURL: url)
                remuxer = nil
            }
            sessionRetainKey = nil
            sessionRetainChannelID = nil
        }
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
    /// Non-nil arms Picture in Picture on THIS layer (solo/fullscreen
    /// hosts only; grid tiles pass nil). PiP under the AVPlayer engine
    /// is a plain AVPlayerLayer controller - the mpv path's sample-
    /// buffer PiP never applied here, which is why swipe-home produced
    /// no PiP window at all on the remux engine (field 2026-08-29).
    /// Auto-start from inline only, matching the mpv policy; the
    /// delegate mirrors active state into the store so the tile's
    /// background handler knows iOS is driving the window.
    var pipStore: PlayerProgressStore? = nil

    final class HostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        /// Diagnostic: when the video plane ACTUALLY has a frame to
        /// show, vs the item clock/audio (audio-before-video hunts).
        var readyObservation: NSKeyValueObservation?
        var attachedAt = Date()
    }

    final class PiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
        var controller: AVPictureInPictureController?
        weak var store: PlayerProgressStore?

        func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            // Synchronous, and iOS fires it BEFORE didEnterBackground -
            // the tile's background quiesce reads this flag to stand
            // down while PiP owns playback (mpv-path parity).
            store?.isPiPActive = true
            debugLog("[AVP-PIP] will start")
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            store?.isPiPActive = false
            debugLog("[AVP-PIP] did stop")
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        failedToStartPictureInPictureWithError error: Error) {
            store?.isPiPActive = false
            debugLog("[AVP-PIP] failed to start: \(error.localizedDescription)")
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                        completionHandler: @escaping (Bool) -> Void) {
            // The hosting SwiftUI screen stays mounted through PiP, so
            // there is nothing to rebuild - just confirm.
            completionHandler(true)
        }
    }

    func makeCoordinator() -> PiPCoordinator { PiPCoordinator() }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.attachedAt = Date()
        view.readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            let ms = Int(Date().timeIntervalSince(view.attachedAt) * 1000)
            debugLog("[AVP-LAYER] isReadyForDisplay=\(layer.isReadyForDisplay) at +\(ms)ms from layer attach")
        }
        syncPiP(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
        syncPiP(view, context.coordinator)
    }

    /// Arm or disarm the PiP controller to match [pipStore]. The
    /// controller binds to the LAYER, so player swaps on the same host
    /// view (retry, version switch) keep the same controller.
    private func syncPiP(_ view: HostView, _ coordinator: PiPCoordinator) {
        #if os(iOS)
        if let store = pipStore {
            coordinator.store = store
            if coordinator.controller == nil,
               AVPictureInPictureController.isPictureInPictureSupported() {
                if let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
                    pip.delegate = coordinator
                    pip.canStartPictureInPictureAutomaticallyFromInline = true
                    coordinator.controller = pip
                    debugLog("[AVP-PIP] controller armed (auto-start from inline)")
                }
            }
        } else if let existing = coordinator.controller {
            // Tile count grew past solo: PiP is a fullscreen-only
            // affordance, mirror the mpv policy and drop it.
            existing.delegate = nil
            coordinator.controller = nil
            coordinator.store?.isPiPActive = false
            debugLog("[AVP-PIP] controller disarmed (no longer solo)")
        }
        #endif
    }
}
