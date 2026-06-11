import Foundation
import Network
import SwiftUI
import AVFoundation

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
    /// Segments advertised in the live playlist window.
    private let liveWindowSegments = 6
    /// Segments retained in memory; old ones beyond this are dropped even
    /// if a slow client might still want them (live TV: it should not).
    private let maxBufferedSegments = 10
    /// Segments that must exist before `onReady` fires with the playlist
    /// URL. Two keeps startup low; AVPlayer refreshes the playlist as more
    /// land.
    private let readyThreshold = 2

    // MARK: Callbacks (delivered on the main queue, each at most once)

    var onReady: ((URL) -> Void)?
    var onError: ((RemuxError) -> Void)?

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

    // Segmenter state
    private var currentSegment = Data()
    private var currentStartPTS: Double?
    private var awaitingFirstKeyframe = true
    private var segments: [(seq: Int, data: Data, duration: Double)] = []
    private var nextSeq = 0
    private var readySignaled = false
    private var errorSignaled = false
    private var totalBytesIngested = 0

    init(sourceURL: URL, headers: [String: String]) {
        self.sourceURL = sourceURL
        self.headers = headers
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startServer()
            self.startIngest()
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
                let isKeyframe = packetStartsKeyframeAccessUnit(p)
                if awaitingFirstKeyframe {
                    if isKeyframe {
                        awaitingFirstKeyframe = false
                        beginSegment(at: pts)
                    }
                } else if isKeyframe,
                          let start = currentStartPTS {
                    var elapsed = pts - start
                    // 33-bit PTS wrap (~26.5h) or discontinuity: cut here.
                    if elapsed < 0 { elapsed = targetSegmentSeconds }
                    if elapsed >= targetSegmentSeconds {
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

        // The codec gate, per Apple's HLS authoring rules.
        if video.type != 0x1B {
            let name = video.type == 0x24 ? "HEVC (needs fMP4 segments)" : "MPEG-2 video"
            fail(.unsupportedCodec(name))
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

    private func closeSegment(endPTS: Double) {
        guard let start = currentStartPTS, !currentSegment.isEmpty else { return }
        var duration = endPTS - start
        if duration <= 0 || duration > 10 { duration = targetSegmentSeconds }
        segments.append((seq: nextSeq, data: currentSegment, duration: duration))
        nextSeq += 1
        if segments.count > maxBufferedSegments {
            segments.removeFirst(segments.count - maxBufferedSegments)
        }
        if segments.count == 1 || segments.count % 5 == 0 {
            debugLog("[TS-REMUX] segment \(nextSeq - 1) closed (\(String(format: "%.2f", duration))s, \(currentSegment.count / 1024) KB), buffered \(segments.count)")
        }
        if !readySignaled, segments.count >= readyThreshold, localPort != 0 {
            readySignaled = true
            let url = URL(string: "http://127.0.0.1:\(localPort)/live.m3u8")!
            debugLog("[TS-REMUX] READY -> \(url.absoluteString)")
            DispatchQueue.main.async { [weak self] in self?.onReady?(url) }
        }
    }

    private func playlistText() -> String {
        let window = segments.suffix(liveWindowSegments)
        guard let first = window.first else {
            return "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(targetSegmentSeconds.rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n"
        }
        let maxDur = window.map(\.duration).max() ?? targetSegmentSeconds
        var text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(maxDur.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:\(first.seq)

        """
        for segment in window {
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\nseg\(segment.seq).ts\n"
        }
        return text
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(connection, path: path)
            } else if buffer.count < 16_384 {
                self.receiveRequest(connection, buffer: buffer)
            } else {
                connection.cancel()
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
            } else if path.hasPrefix("/seg"), path.hasSuffix(".ts"),
                      let seq = Int(path.dropFirst(4).dropLast(3)),
                      let segment = self.segments.first(where: { $0.seq == seq }) {
                body = segment.data
                contentType = "video/mp2t"
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
/// Known evaluation limitations: the chrome scrubber and track pickers
/// bind to the mpv progress store, so they are inert while the audio
/// tile is AVPlayer-backed; play/pause via `shouldPause` works.
struct AVPlayerMultiviewTile: View {
    let streamURL: URL
    let headers: [String: String]
    let isAudioActive: Bool
    let shouldPause: Bool
    let channelName: String
    /// Parent flips this tile back to the mpv engine.
    let onEngineFallback: (String) -> Void

    @State private var player: AVPlayer?
    @State private var remuxer: TSHLSRemuxer?
    @State private var statusText: String?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                AVPlayerLayerView(player: player)
            }
            if let statusText {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
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
        .onChange(of: isAudioActive) { _, active in
            player?.isMuted = !active
        }
        .onChange(of: shouldPause) { _, paused in
            if paused { player?.pause() } else { player?.play() }
        }
        // In-place channel swap on the same tile id (the container
        // swaps `tile.streamURL` without changing tile identity).
        .onChange(of: streamURL) { _, _ in
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
            onEngineFallback("playback failed")
        }
    }

    private func start() {
        switch classifyStreamURL(streamURL) {
        case .hls:
            var direct: [String: String] = [:]
            if let ua = headers["User-Agent"] { direct["User-Agent"] = ua }
            startPlayer(url: streamURL, requestHeaders: direct)
            debugLog("[AVP-MV] tile playing direct HLS channel=\(channelName)")
        default:
            statusText = "Preparing..."
            let mux = TSHLSRemuxer(sourceURL: streamURL, headers: headers)
            mux.onReady = { url in
                statusText = nil
                startPlayer(url: url, requestHeaders: [:])
                debugLog("[AVP-MV] tile playing REMUXED channel=\(channelName)")
            }
            mux.onError = { error in
                debugLog("[AVP-MV] tile remux failed (\(error)) channel=\(channelName); falling back to mpv tile")
                onEngineFallback("\(error)")
            }
            remuxer = mux
            mux.start()
        }
    }

    private func startPlayer(url: URL, requestHeaders: [String: String]) {
        var options: [String: Any] = [:]
        if !requestHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = requestHeaders
        }
        let asset = AVURLAsset(url: url, options: options)
        let avPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        avPlayer.isMuted = !isAudioActive
        if !shouldPause { avPlayer.play() }
        player = avPlayer
    }

    private func stop() {
        player?.pause()
        player = nil
        remuxer?.stop()
        remuxer = nil
        statusText = nil
    }
}

/// Bare AVPlayerLayer host: video only, no system chrome, sized by
/// SwiftUI like any other tile content.
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class HostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}
