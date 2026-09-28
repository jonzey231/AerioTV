//
//  CastHLSProxyServer.swift
//  Aerio
//
//  Minimal HTTP/1.1 server for the phone-local cast HLS proxy (GH #33
//  web-receiver rework). NWListener, no dependencies: the only client is
//  the Cast device's Chromium page on the same LAN, fetching the DEMUXED
//  resource shapes:
//
//    /demuxed.m3u8   master: EXT-X-MEDIA audio rendition + EXT-X-STREAM-INF
//    /video.m3u8     video-only media playlist (vinit / vseg)
//    /audio.m3u8     audio-only media playlist (ainit / aseg)
//    /vinit<G>.mp4   video-only moov for ingest generation G
//    /ainit<G>.mp4   audio-only moov for generation G
//    /vseg<N>.m4s    video traf only, monotonic sequence N
//    /aseg<N>.m4s    audio traf only, sequence N
//
//  Why demuxed: measured on the Google TV Streamer's Cast runtime,
//  isTypeSupported("video/mp4; codecs=\"avc1.64002A,ac-3\"") is false and
//  so is isTypeSupported("video/mp4; codecs=\"ac-3\""), but
//  isTypeSupported("audio/mp4; codecs=\"ac-3\"") is TRUE. A single muxed
//  rendition could therefore only ever declare AAC, which is what forced
//  the server-side AAC output profile; a separate audio rendition appended
//  into its own SourceBuffer is how Emby's web receiver reaches its
//  hardware audio decoder. The muxed endpoints were removed 2026-09-13.
//
//  Every response carries `Access-Control-Allow-Origin: *` because the
//  receiver page's origin is Google's, not ours, and Chromium enforces
//  CORS on MSE fetches. Mixed content (https receiver page fetching
//  http LAN URLs) is warning-only on cast hardware.
//

import Foundation
import Network

/// Serves a `CastHLSSegmentStore` over HTTP on an ephemeral port bound
/// to all interfaces (the URL handed to the receiver carries the Wi-Fi
/// LAN IP; binding only that IP would break if the system re-ranks
/// interfaces mid-session).
final class CastHLSProxyServer: @unchecked Sendable {

    private static let mimePlaylist = "application/vnd.apple.mpegurl"
    private static let mimeMP4 = "video/mp4"
    private static let mimeAudioMP4 = "audio/mp4"
    private static let mimeSegment = "video/iso.segment"

    private let store: CastHLSSegmentStore
    private let log: (String) -> Void
    private var listener: NWListener?
    /// Live-edge segment holds block for up to ~6 s; a concurrent queue
    /// keeps a held fetch from stalling the playlist poll next to it.
    private let serveQueue = DispatchQueue(label: "com.aerio.casthls.serve", attributes: .concurrent)
    /// Diagnostic: log the receiver's FIRST playlist fetch loudly; it is
    /// the proof the Cast device reached the phone at all.
    private let firstPlaylistServed = OSAllocatedUnfairLockFlag()
    /// Diagnostic: dump the master and media playlist TEXT once each, so
    /// a failing cast can be read back from the log without the device.
    private let demuxedMasterTextLogged = OSAllocatedUnfairLockFlag()
    private let videoPlaylistTextLogged = OSAllocatedUnfairLockFlag()
    private let audioPlaylistTextLogged = OSAllocatedUnfairLockFlag()
    /// Requests served this session, for the log rate limit below.
    private let requestCounter = AtomicRequestCounter()

    /// Requests logged verbatim at the start of a session before the rate
    /// limit kicks in (enough to cover the master, both media playlists,
    /// both inits and the first handful of segments, which is the whole
    /// startup handshake a failed cast has to be diagnosed from).
    private static let verboseRequests = 12

    /// After `verboseRequests`, only non-200 responses and every Nth
    /// request are logged, so a long cast does not flood.
    private static let requestLogEvery = 50

    private(set) var boundPort: UInt16 = 0

    /// Link counters (device log 2026-09-25 17:04): bytes sent, the last
    /// peer and the newest video segment the receiver fetched.
    private let linkLock = NSLock()
    private var servedBytesTotal: Int64 = 0
    private var lastPeer: String?
    private var highestVideoSeq = -1

    /// Playlist / segment request counts since the last accepted load
    /// (stale-receiver check, incident 2026-09-25 15:26).
    let requestCounters = CastHLSRequestCounters()

    var linkCounters: (servedBytes: Int64, peer: String?, highestVideoSeq: Int) {
        linkLock.lock(); defer { linkLock.unlock() }
        return (servedBytesTotal, lastPeer, highestVideoSeq)
    }

    init(store: CastHLSSegmentStore, log: @escaping (String) -> Void) {
        self.store = store
        self.log = log
    }

    /// Bind and start accepting. Returns the bound port once listening.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: serveQueue)
        _ = ready.wait(timeout: .now() + 5)
        guard boundPort != 0 else {
            listener.cancel()
            throw CastHLSProxyError.serverFailed
        }
        return boundPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = 0
    }

    // MARK: HTTP

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serveQueue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
                let method = parts.first.map(String.init) ?? "GET"
                let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : "/"
                self.serveQueue.async { self.respond(connection, method: method, path: path,
                                                    peer: connection.endpoint) }
            } else if buffer.count < 16_384 {
                self.receiveRequest(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, method: String, path: String, peer: NWEndpoint) {
        if method == "OPTIONS" {
            send(connection, status: "204 No Content", contentType: nil, body: Data())
            return
        }
        guard method == "GET" || method == "HEAD" else {
            send(connection, status: "405 Method Not Allowed", contentType: nil, body: Data())
            return
        }
        requestCounters.record(path: path)
        let body: Data?
        let mime: String
        // Wait time is only meaningful for a segment fetch that was held
        // at the live edge; it is the single most useful number when the
        // receiver errors out (a long wait means the ingest, not the
        // receiver, is the problem).
        var waitMs = -1
        switch path {
        case "/demuxed.m3u8":
            let text = store.demuxedMasterPlaylistText()
            body = Data(text.utf8)
            mime = Self.mimePlaylist
            if demuxedMasterTextLogged.trySet() { log("demuxed master playlist: \(Self.escaped(text))") }
        case "/video.m3u8":
            let text = store.videoPlaylistText()
            body = Data(text.utf8)
            mime = Self.mimePlaylist
            if firstPlaylistServed.trySet() {
                log("receiver fetched the playlist for the first time (\(Self.host(of: peer)))")
            }
            if videoPlaylistTextLogged.trySet() { log("video playlist: \(Self.escaped(text))") }
        case "/audio.m3u8":
            let text = store.audioPlaylistText()
            body = Data(text.utf8)
            mime = Self.mimePlaylist
            if audioPlaylistTextLogged.trySet() { log("audio playlist: \(Self.escaped(text))") }
        case let p where p.hasPrefix("/vinit") && p.hasSuffix(".mp4"):
            let gen = Int(p.dropFirst(6).dropLast(4))
            body = gen.flatMap { store.videoInitSegment(generation: $0) }
            mime = Self.mimeMP4
        case let p where p.hasPrefix("/ainit") && p.hasSuffix(".mp4"):
            let gen = Int(p.dropFirst(6).dropLast(4))
            body = gen.flatMap { store.audioInitSegment(generation: $0) }
            mime = Self.mimeAudioMP4
        case let p where p.hasPrefix("/vseg") && p.hasSuffix(".m4s"):
            let seq = Int(p.dropFirst(5).dropLast(4))
            // Concurrent serve queue, so holding the live-edge fetch here
            // blocks nobody else.
            let began = Date()
            body = seq.flatMap { store.awaitSegment(seq: $0, rendition: .video) }
            waitMs = Int(Date().timeIntervalSince(began) * 1000)
            if let seq, body != nil {
                linkLock.lock(); highestVideoSeq = max(highestVideoSeq, seq); linkLock.unlock()
            }
            mime = Self.mimeSegment
        case let p where p.hasPrefix("/aseg") && p.hasSuffix(".m4s"):
            let seq = Int(p.dropFirst(5).dropLast(4))
            let began = Date()
            body = seq.flatMap { store.awaitSegment(seq: $0, rendition: .audio) }
            waitMs = Int(Date().timeIntervalSince(began) * 1000)
            mime = Self.mimeSegment
        default:
            body = nil
            mime = "text/plain"
        }
        logRequest(method: method, path: path, status: body == nil ? 404 : 200,
                   bytes: body?.count ?? 0, waitMs: waitMs)
        linkLock.lock()
        servedBytesTotal += Int64(method == "HEAD" ? 0 : (body?.count ?? 0))
        lastPeer = Self.host(of: peer)
        linkLock.unlock()
        if let body {
            send(connection, status: "200 OK", contentType: mime,
                 body: method == "HEAD" ? Data() : body, declaredLength: body.count)
        } else {
            send(connection, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    private func send(_ connection: NWConnection, status: String, contentType: String?,
                      body: Data, declaredLength: Int? = nil) {
        var header = "HTTP/1.1 \(status)\r\n"
        if let contentType { header += "Content-Type: \(contentType)\r\n" }
        header += "Content-Length: \(declaredLength ?? body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: *\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// One line per request: the only record of what the Cast receiver
    /// actually asked for and got. Added 2026-09-12 after an iPhone cast
    /// froze on a Google TV Streamer and the phone log could not say
    /// whether the receiver had fetched a segment at all, while the
    /// Android proxy's identical log made the answer obvious (it had
    /// fetched seg0, seg1, then seg4, then nothing).
    ///
    /// Rate limit: the first `verboseRequests` of a session verbatim
    /// (master, playlists, inits, the opening segments), then only non-200s
    /// and every `requestLogEvery`th request.
    private func logRequest(method: String, path: String, status: Int, bytes: Int, waitMs: Int) {
        let n = requestCounter.next()
        guard n <= Self.verboseRequests || status != 200 || n % Self.requestLogEvery == 0 else { return }
        let wait = waitMs > 0 ? " wait=\(waitMs)ms" : ""
        log("\(method) \(path) \(status) \(bytes) B\(wait)")
    }

    /// Playlist text on ONE log line: newlines escaped so the log keeps
    /// it as a single readable record.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "unknown"
    }
}

/// Monotonic request counter for the serve queue's log rate limit.
private final class AtomicRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// One-shot flag with the tiny lock discipline this file needs (the
/// serve queue is concurrent).
private final class OSAllocatedUnfairLockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Returns true exactly once, for the first caller.
    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
