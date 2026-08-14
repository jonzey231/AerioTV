//
//  CastHLSProxySession.swift
//  Aerio
//
//  Phone-side cast HLS proxy session (GH #33 web-receiver rework): owns
//  the URLSession ingest of a live channel's raw MPEG-TS stream, feeds
//  CastFMP4Remuxer, and publishes the output through CastHLSProxyServer
//  as sliding-window live HLS the web receiver can actually pace (a
//  progressive fMP4 URL stutters every 10-15 s for want of a manifest
//  clock; device-verified on the Android build of this same design).
//
//  One channel at a time: `startChannel` tears down the previous ingest
//  and (via the store's generation machinery) rolls a playlist
//  discontinuity; the listening socket and URL survive channel flips, so
//  the receiver keeps polling the same playlist. A fresh cast session
//  gets a fresh server + store (new port, sequence reset).
//

import Foundation
#if os(iOS)
import AVFoundation
#endif

enum CastHLSProxyError: Error, CustomStringConvertible {
    /// The phone has no Wi-Fi/LAN IPv4 address to serve on (a Chromecast
    /// cannot fetch from a cellular interface).
    case noLANAddress
    /// The listening socket never became ready.
    case serverFailed
    /// The ingest gave up after consecutive connect failures.
    case ingestUnreachable
    /// Segments never materialized inside the ready window.
    case timedOut

    var description: String {
        switch self {
        case .noLANAddress: return "no Wi-Fi LAN address to serve the cast proxy on"
        case .serverFailed: return "local HTTP server failed to start"
        case .ingestUnreachable: return "stream unreachable"
        case .timedOut: return "the stream never started"
        }
    }
}

/// Not MainActor: the sender calls `startChannel` from its MainActor
/// context, but all the work (socket bind, ingest, waits) runs off it.
final class CastHLSProxySession: @unchecked Sendable {

    static let shared = CastHLSProxySession()

    /// loadMedia is gated on this many segments so the receiver's first
    /// playlist fetch always has something playable (an empty live
    /// playlist is a hard receiver error, not a retry).
    private static let readySegments = 2

    /// Bound on the wait for `readySegments`: two ~3 s segments plus
    /// provider join latency; past this the channel is declared
    /// uncastable and the user told. First terminal error wins.
    private static let readyTimeout: TimeInterval = 25.0

    /// A slow provider can eat the whole `readyTimeout` in one failed
    /// connect (15 s request timeout + backoff) and then recover on the
    /// reconnect; the timeout exists to catch channels that NEVER start,
    /// not ones that just healed. Every (re)connect therefore guarantees
    /// at least this much runway from the moment bytes start flowing
    /// (two ~4 s segments + remux latency).
    private static let postConnectGrace: TimeInterval = 15.0

    /// Consecutive failed (re)connects before the ingest gives up.
    /// Backoff 1/2/4/8/8 s; the receiver stalls at the live edge in the
    /// meantime, which is the honest presentation of the outage.
    private static let maxConsecutiveFailures = 5

    /// Per-8-segments log rollup cadence.
    private static let logEverySegments = 8

    /// Serializes control (start/stop/reconnect bookkeeping) and ingest
    /// data; the remuxer is single-caller on this queue.
    private let queue = DispatchQueue(label: "com.aerio.casthls.session")

    private var server: CastHLSProxyServer?
    private var store: CastHLSSegmentStore?
    private var ingest: IngestConnection?
    private var remuxer: CastFMP4Remuxer?
    /// Terminal ingest failure (unsupported codec, connect exhaustion),
    /// observed by `startChannel`'s ready wait. First error wins.
    private var terminalError: Error?
    private var activeURL: URL?
    private var currentGeneration = 0
    private var consecutiveFailures = 0
    private var everConnected = false
    /// Most recent ingest (re)connect; extends `startChannel`'s ready
    /// wait by `postConnectGrace` so a slow first connect + healthy
    /// reconnect is not misreported as "never started".
    private var lastIngestConnectAt: Date?
    /// Monotonic token; a scheduled reconnect from a superseded channel
    /// or a stopped session must not fire.
    private var ingestEpoch = 0

    // Per-generation log rollup state.
    private var segmentsLogged = 0
    private var rollupBytes = 0
    private var rollupTicks: Int64 = 0

    // Stats surface for the cast Options sheet (task #267): the latest
    // completed per-8-segment rollup is STORED, not just logged, plus a
    // per-channel segment total and the codec descriptions.
    private var totalSegmentsProduced = 0
    private var lastRollupKbps: Int?
    private var lastRollupAvgSegmentSeconds: Double?
    private var videoCodecDescription: String?
    /// Last non-nil remuxer audio path, so the card doesn't blank for
    /// the sub-second PMT re-parse window on every reconnect splice.
    private var audioPathCache: String?

    /// Point-in-time proxy stats for the cast Options sheet's Stream
    /// Info card. Value-typed so it crosses to the MainActor reader.
    struct Stats: Sendable {
        let ingestHost: String
        let port: UInt16
        let generation: Int
        let segmentsProduced: Int
        let videoCodec: String?
        let audioPath: String?
        let lastRollupKbps: Int?
        let lastRollupAvgSegmentSeconds: Double?
    }

    /// Snapshot for the cast Options sheet; nil when no proxy session is
    /// up. Cheap: one hop onto the session queue.
    func statsSnapshot() -> Stats? {
        queue.sync {
            guard let server, let url = activeURL else { return nil }
            if let path = remuxer?.audioPathDescription { audioPathCache = path }
            return Stats(
                ingestHost: URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? "?",
                port: server.boundPort,
                generation: currentGeneration,
                segmentsProduced: totalSegmentsProduced,
                videoCodec: videoCodecDescription,
                audioPath: audioPathCache,
                lastRollupKbps: lastRollupKbps,
                lastRollupAvgSegmentSeconds: lastRollupAvgSegmentSeconds)
        }
    }

    private func log(_ message: String) {
        debugLog("[CAST-HLS] \(message)")
    }

    /// Point the proxy at `rawTSURL` (the SAME URL + headers the local
    /// player would use) and wait until the playlist has two segments.
    /// Returns the MASTER playlist URL to hand to the cast load (its
    /// CLOSED-CAPTIONS=NONE keeps Shaka's caption parser away from the
    /// muxed segments; loading live.m3u8 directly is a known fatal).
    ///
    /// Throws `CastUnsupportedCodecError` for a mux the proxy cannot
    /// serve and `CastHLSProxyError` for infrastructure failures.
    func startChannel(rawTSURL: URL, headers: [String: String]) async throws -> URL {
        // The Chromecast fetches over the LAN; 127.0.0.1 would only ever
        // work for the phone itself.
        guard let lanIP = Self.wifiLANAddress() else {
            log("start refused: no Wi-Fi LAN address")
            throw CastHLSProxyError.noLANAddress
        }
        let (port, isChannelChange): (UInt16, Bool) = try queue.sync {
            let store: CastHLSSegmentStore
            let server: CastHLSProxyServer
            if let existingStore = self.store, let existingServer = self.server, existingServer.boundPort != 0 {
                // Channel change / reconnect reuses server + port + ring:
                // the receiver's cached playlist still promises the old
                // channel's last segments, so they stay fetchable until
                // ring eviction, and the new generation splices in behind
                // a discontinuity with no sequence gap.
                store = existingStore
                server = existingServer
            } else {
                store = CastHLSSegmentStore(log: { [weak self] in self?.log($0) })
                server = CastHLSProxyServer(store: store, log: { [weak self] in self?.log($0) })
                _ = try server.start()
                self.store = store
                self.server = server
            }
            let isChannelChange = self.activeURL != nil
            self.stopIngestLocked()
            self.activeURL = rawTSURL
            self.terminalError = nil
            self.consecutiveFailures = 0
            self.everConnected = false
            self.lastIngestConnectAt = nil
            self.currentGeneration = store.beginGeneration()
            self.totalSegmentsProduced = 0
            self.lastRollupKbps = nil
            self.lastRollupAvgSegmentSeconds = nil
            self.videoCodecDescription = nil
            self.audioPathCache = nil
            self.log("server on \(lanIP):\(server.boundPort); "
                + "\(isChannelChange ? "channel change" : "session start") "
                + "gen=\(self.currentGeneration) ingest=\(Self.sanitize(rawTSURL))")
            self.beginBackgroundKeepaliveIfNeeded()
            self.startIngestLocked(url: rawTSURL, headers: headers)
            return (server.boundPort, isChannelChange)
        }
        _ = isChannelChange

        // Ready wait: first terminal error wins; otherwise poll for the
        // segment gate. 100 ms granularity is invisible next to ~3 s
        // segment cadence.
        let deadline = Date(timeIntervalSinceNow: Self.readyTimeout)
        while true {
            // A superseding channel flip cancels this task; the flip's own
            // startChannel already re-pointed the ingest, so just leave.
            if Task.isCancelled { throw CancellationError() }
            let (err, count, connectedAt): (Error?, Int, Date?) = queue.sync {
                (terminalError, store?.currentSegmentsInGeneration ?? 0, lastIngestConnectAt)
            }
            // A (re)connect is progress: guarantee `postConnectGrace` of
            // runway from the moment bytes started flowing, else a slow
            // first connect eats the whole budget and a healthy reconnect
            // gets killed as "never started" (seen live 2026-08-14).
            let effectiveDeadline = max(deadline,
                connectedAt.map { $0.addingTimeInterval(Self.postConnectGrace) } ?? deadline)
            if Date() >= effectiveDeadline { break }
            if let err {
                stopIfStillActive(rawTSURL)
                throw err
            }
            if count >= Self.readySegments {
                return URL(string: "http://\(lanIP):\(port)/master.m3u8")!
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // A channel that cannot start must not leave a dead ingest
        // pinning the provider connection.
        stopIfStillActive(rawTSURL)
        throw CastHLSProxyError.timedOut
    }

    /// Full teardown: ingest, ring, server socket, background keepalive.
    /// Called when the cast session ends (or a start fails).
    func stop() {
        queue.sync {
            let hadSession = activeURL != nil || server != nil
            activeURL = nil
            stopIngestLocked()
            store?.close()
            store = nil
            server?.stop()
            server = nil
            endBackgroundKeepaliveIfNeeded()
            if hadSession { log("proxy stopped") }
        }
    }

    private func stopIfStillActive(_ url: URL) {
        let stillActive = queue.sync { activeURL == url }
        if stillActive { stop() }
    }

    // MARK: background keepalive

    /// Casting users pocket the phone; the proxy is the receiver's media
    /// server and must outlive the app's foreground time. The codebase's
    /// existing mechanism is the audio background mode plus the
    /// AudioSessionRefCount guard, so the proxy holds a refcount for its
    /// lifetime (the cast sender also disables the SDK's
    /// suspend-on-background). Device verification of long background
    /// runs is part of the P2 checklist.
    private var keepaliveHeld = false
    #if os(iOS)
    /// A configured-but-silent audio session is NOT enough: iOS suspends a
    /// backgrounded process that renders no audio, which froze the receiver
    /// mid-cast within minutes (device-verified 2026-08-13, iPhone 17 Pro
    /// Max: proxy port unreachable after backgrounding while the TV starved).
    /// Only an ACTIVE render keeps the process scheduled, so the keepalive
    /// runs an AVAudioEngine whose output is silence (player node with no
    /// scheduled buffers; mainMixer volume 0 as a belt-and-braces mute).
    private var keepaliveEngine: AVAudioEngine?
    #endif

    private func beginBackgroundKeepaliveIfNeeded() {
        #if os(iOS)
        guard !keepaliveHeld else { return }
        keepaliveHeld = true
        AudioSessionRefCount.increment(caller: "cast-hls-proxy")
        let engine = AVAudioEngine()
        // The engine must have a source attached for some route
        // configurations to start; a player node with nothing scheduled
        // renders silence.
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
            keepaliveEngine = engine
            log("background keepalive engine running")
        } catch {
            // Backgrounding will then suspend the proxy; surfaced so the
            // field log explains a frozen receiver.
            log("background keepalive engine FAILED: \(error)")
        }
        #endif
    }

    private func endBackgroundKeepaliveIfNeeded() {
        #if os(iOS)
        guard keepaliveHeld else { return }
        keepaliveHeld = false
        keepaliveEngine?.stop()
        keepaliveEngine = nil
        AudioSessionRefCount.decrement(caller: "cast-hls-proxy")
        #endif
    }

    // MARK: ingest

    private func stopIngestLocked() {
        ingestEpoch += 1
        ingest?.cancel()
        ingest = nil
        remuxer?.release()
        remuxer = nil
    }

    /// Runs on `queue`. Builds a fresh remuxer per connection: a TS join
    /// lands mid-GOP with an unknown clock phase, so the remuxer
    /// realigns (sync scan, wait for SPS/PPS + keyframe) and the store
    /// presents the restart as a playlist discontinuity.
    private func startIngestLocked(url: URL, headers: [String: String]) {
        let epoch = ingestEpoch
        let gen = currentGeneration
        segmentsLogged = 0
        rollupBytes = 0
        rollupTicks = 0

        let remuxer = CastFMP4Remuxer(log: { [weak self] in self?.log($0) })
        remuxer.onInitSegment = { [weak self] data in
            guard let self, self.ingestEpoch == epoch else { return }
            self.store?.setInitSegment(generation: gen, data: data)
            if let avc = CastHLSSegmentStore.avcCodecString(from: data) {
                self.videoCodecDescription = "H.264 (\(avc))"
            }
            self.log("init segment ready gen=\(gen) (\(data.count) B)")
        }
        remuxer.onMediaSegment = { [weak self] data, durationTicks in
            guard let self, self.ingestEpoch == epoch else { return }
            // The store's generation gate is the authority; this epoch
            // check just spares dead work after a teardown race.
            self.store?.addSegment(generation: gen, data: data, durationTicks: durationTicks)
            self.segmentsLogged += 1
            self.totalSegmentsProduced += 1
            self.rollupBytes += data.count
            self.rollupTicks += durationTicks
            if self.segmentsLogged % Self.logEverySegments == 0 {
                let seconds = Double(self.rollupTicks) / Double(CastFMP4Remuxer.ticksPerSecond)
                let kbps = seconds > 0 ? Int(Double(self.rollupBytes) * 8 / seconds / 1000) : 0
                self.lastRollupKbps = kbps
                self.lastRollupAvgSegmentSeconds = seconds / Double(Self.logEverySegments)
                self.log("segments=\(self.segmentsLogged) last\(Self.logEverySegments): "
                    + "avgDur=\(String(format: "%.2f", seconds / Double(Self.logEverySegments)))s "
                    + "bytes=\(self.rollupBytes) bitrate=\(kbps)kbps")
                self.rollupBytes = 0
                self.rollupTicks = 0
            }
        }
        self.remuxer = remuxer

        let connection = IngestConnection(
            url: url,
            headers: headers,
            queue: queue,
            onConnected: { [weak self] in
                guard let self, self.ingestEpoch == epoch else { return }
                if self.everConnected {
                    self.log("ingest reconnected (attempt \(self.consecutiveFailures + 1))")
                } else {
                    self.log("ingest connected")
                }
                self.everConnected = true
                self.consecutiveFailures = 0
                self.lastIngestConnectAt = Date()
            },
            onData: { [weak self] data in
                guard let self, self.ingestEpoch == epoch, let remuxer = self.remuxer else { return }
                do {
                    try remuxer.feed(data)
                } catch let error as CastUnsupportedCodecError {
                    // Terminal by design: video is never re-encoded and
                    // the audio transcode covers AC-3/E-AC-3/MP2 only
                    // (and needs a platform decoder). Surfaced to the
                    // sender's ready wait as the cast failure.
                    self.log("unsupported codec, refusing to cast: \(error.codecName)")
                    self.terminalError = error
                    self.stopIngestLocked()
                } catch {
                    // Mid-stream codec failure (e.g. the audio converter
                    // choking on garbage): reconnect with a fresh remuxer
                    // and transcoder rather than killing the proxy.
                    self.log("ingest stream error: \(error)")
                    self.scheduleReconnectLocked(url: url, headers: headers, closingEpoch: epoch)
                }
            },
            onFinished: { [weak self] failureReason in
                guard let self, self.ingestEpoch == epoch else { return }
                if let failureReason { self.log("ingest ended: \(failureReason)") }
                self.scheduleReconnectLocked(url: url, headers: headers, closingEpoch: epoch)
            })
        ingest = connection
        connection.start()
    }

    /// Runs on `queue`. Bounded backoff, then a NEW generation: the
    /// reconnected stream's clock will not line up with the old one, so
    /// the playlist declares the splice instead of hiding it.
    private func scheduleReconnectLocked(url: URL, headers: [String: String], closingEpoch: Int) {
        guard ingestEpoch == closingEpoch, terminalError == nil else { return }
        stopIngestLocked() // bumps ingestEpoch; also releases the transcoder codecs
        let reconnectEpoch = ingestEpoch
        consecutiveFailures += 1
        if consecutiveFailures >= Self.maxConsecutiveFailures {
            log("ingest gave up after \(consecutiveFailures) consecutive failures")
            terminalError = CastHLSProxyError.ingestUnreachable
            return
        }
        let backoff = min(8.0, pow(2.0, Double(consecutiveFailures - 1)))
        log("ingest reconnect in \(Int(backoff * 1000))ms")
        queue.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, self.ingestEpoch == reconnectEpoch, self.activeURL == url else { return }
            guard let store = self.store else { return }
            self.currentGeneration = store.beginGeneration()
            self.startIngestLocked(url: url, headers: headers)
        }
    }

    // MARK: LAN address

    /// The device's Wi-Fi IPv4 address (en0 on iPhone/iPad; any other
    /// non-loopback en* interface covers Ethernet adapters). The active
    /// route may be cellular while Wi-Fi is still up, and the Chromecast
    /// can only reach the Wi-Fi side, so this walks interfaces instead
    /// of asking for the default route's address.
    static func wifiLANAddress() -> String? {
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let first = ifaddrs else { return nil }
        defer { freeifaddrs(ifaddrs) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                            as: UTF8.self)
            guard !ip.hasPrefix("169.254.") else { continue } // link-local
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    /// Strip credentials/query from a URL for the log (house rule: no
    /// identifiers or secrets in shareable logs; DebugLogger's sanitizer
    /// is the second line of defence).
    static func sanitize(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else { return url.path }
        let port = components.port ?? (components.scheme == "https" ? 443 : 80)
        return "\(components.scheme ?? "http")://\(host):\(port)\(components.path)"
    }

    // MARK: ingest connection

    /// One HTTP connection reading a live TS stream. The in-flight task
    /// is cancelled EXPLICITLY on stop: a live body read only returns
    /// once the socket is torn down, and holding it open pins the
    /// provider connection (fatal on single-connection accounts).
    private final class IngestConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let url: URL
        private let headers: [String: String]
        private let queue: DispatchQueue
        private let onConnected: () -> Void
        private let onData: (Data) -> Void
        private let onFinished: (String?) -> Void
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var cancelled = false
        private var connectedSignalled = false

        init(url: URL, headers: [String: String], queue: DispatchQueue,
             onConnected: @escaping () -> Void,
             onData: @escaping (Data) -> Void,
             onFinished: @escaping (String?) -> Void) {
            self.url = url
            self.headers = headers
            self.queue = queue
            self.onConnected = onConnected
            self.onData = onData
            self.onFinished = onFinished
        }

        func start() {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            // A live stream never "completes"; rely on data flow.
            config.timeoutIntervalForResource = .infinity
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }

        func cancel() {
            cancelled = true
            task?.cancel()
            session?.invalidateAndCancel()
            task = nil
            session = nil
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let code = http.statusCode
                queue.async { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.onFinished("http=\(code)")
                }
                completionHandler(.cancel)
                return
            }
            queue.async { [weak self] in
                guard let self, !self.cancelled, !self.connectedSignalled else { return }
                self.connectedSignalled = true
                self.onConnected()
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            queue.async { [weak self] in
                guard let self, !self.cancelled else { return }
                self.onData(data)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            queue.async { [weak self] in
                guard let self, !self.cancelled else { return }
                if let error, (error as NSError).code == NSURLErrorCancelled { return }
                self.onFinished(error.map { $0.localizedDescription } ?? "stream ended")
            }
        }
    }
}
