//
//  PlayerRelay.swift
//  Aerio
//
//  The loopback relay that lets a player play a source that needs the
//  playlist's sign-in without ever holding it.
//
//  AVPlayer sends its AVURLAsset header fields with every request it makes
//  for an asset, to every host it reaches (measured 2026-11-13, iOS 27 and
//  tvOS 27 simulators): a segment a playlist names on another host, a 302 to
//  another host, an fMP4 init, an AES key, every range of an MP4. FFmpeg
//  (mpv) does the same with http-header-fields. With a Redirect stream
//  profile, or any server or playlist pointing elsewhere, that handed the
//  user's Dispatcharr key to their IPTV provider, and AVFoundation gives the
//  app no hook on those requests (a resource loader cannot answer media
//  segments: CoreMedia -12881 "custom url not redirect", measured).
//
//  So the player opens http://127.0.0.1:<port>/r/<token>/<id>/<name> with
//  no sign-in, and this relay makes the upstream request: through
//  URLSession with RedirectAuthPolicy deciding every redirect hop, with the
//  key re-read for each request (StreamFetchAuth: a replaced key goes out
//  as its successor, a held one not at all), and only to the host and port
//  the rule allows (PlayerRelayPolicy.upstream). Every playlist it serves is
//  rewritten so each URI comes back here (HLSRelayPlaylist); anything else
//  streams through with Range passed both ways.
//
//  Loopback only: the listener requires the loopback interface, every
//  session has a 128-bit random token, and a player can only ask for the
//  resources the session's own playlists named (opaque ids, never an
//  upstream URL, so no key, provider credential, or upstream address is in
//  any URL the player holds). A session lives as long as its Handle; the
//  tile ties the Handle to the AVPlayer, so a Kept Live player keeps its
//  session and a released one closes it.
//

import AVFoundation
import Foundation
import Network
import SwiftData
#if os(iOS)
import UIKit
#endif

final class PlayerRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = PlayerRelay()

    /// What a session plays, for the DVR playlist transform and the log.
    enum Purpose: Equatable, Sendable {
        /// On-demand: a Dispatcharr VOD session URL or another VOD source.
        case vod
        /// An in-progress recording's HLS. `transform`: apply
        /// DVRPlaylistTransform (leading DISCONTINUITY drop, EXT-X-START
        /// from `startOffset`) to every playlist.
        case dvr(startOffset: Double?, transform: Bool)
        /// A live HLS source that needs the sign-in.
        case live
        /// mpv (any stream it plays).
        case mpv

        var name: String {
            switch self {
            case .vod: return "vod"
            case .dvr: return "dvr"
            case .live: return "live"
            case .mpv: return "mpv"
            }
        }
    }

    /// The player's URL for a session. Releasing the last reference closes
    /// the session, so the owner keeps it exactly as long as its player.
    final class Handle: @unchecked Sendable {
        let url: URL
        let upstream: URL
        fileprivate let token: String
        private weak var relay: PlayerRelay?

        fileprivate init(url: URL, upstream: URL, token: String, relay: PlayerRelay) {
            self.url = url
            self.upstream = upstream
            self.token = token
            self.relay = relay
        }

        deinit { relay?.close(token: token) }
    }

    // MARK: State (touched only on `queue`)

    private let queue = DispatchQueue(label: "com.aerio.player-relay", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var listenerReady = false
    private var readyWaiters: [DispatchSemaphore] = []
    private var sessions: [String: Session] = [:]
    private var exchanges: [Int: Exchange] = [:]
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var urlSession: URLSession!
    private var proxyFallbackLogged = false

    /// Accepted player connections at once (AVPlayer opens several per
    /// item; a nine-tile Multiview of relayed sources stays well under).
    private static let maxConnections = 96
    /// Resources one session remembers. A long recording's EVENT playlist
    /// lists every segment on every reload (24 h of 2 s segments is 43,200),
    /// so the oldest ids are forgotten only past this; a forgotten id
    /// answers 404 and the player re-reads the playlist.
    private static let maxResources = 60_000
    /// A playlist larger than this is not a playlist.
    private static let maxPlaylistBytes = 16 * 1024 * 1024
    /// Bytes queued to a player before the upstream task is paused.
    private static let highWater = 4 * 1024 * 1024
    private static let lowWater = 1024 * 1024
    private static let idleTimeout: TimeInterval = 60

    private override init() {
        super.init()
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 16
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: ops)
    }

    // MARK: Sessions

    /// A relay session for `url`, played with `headers` (the sign-in
    /// included; the player itself gets none of it). Nil when the URL is not
    /// http(s) or the loopback listener cannot come up; the caller then
    /// plays without the key, never with it.
    func open(_ url: URL, headers: [String: String], purpose: Purpose) -> Handle? {
        guard HLSRelayPlaylist.isRelayable(url), let port = readyPort() else { return nil }
        let session = Session(origin: url, headers: headers, purpose: purpose)
        let id: Int = queue.sync {
            sessions[session.token] = session
            return session.register(url, keyed: session.keyed, kind: .other)
        }
        let name = PlayerRelayPolicy.resourceName(for: url)
        guard let relayURL = URL(string: "http://127.0.0.1:\(port)/r/\(session.token)/\(id)/\(name)") else {
            queue.async { self.sessions[session.token] = nil }
            return nil
        }
        debugLog("[RELAY] session \(session.tag) open purpose=\(purpose.name) signIn=\(session.keyed) upstream=\(url.scheme ?? "?")://\(url.host ?? "?")")
        return Handle(url: relayURL, upstream: url, token: session.token, relay: self)
    }

    fileprivate func close(token: String) {
        queue.async { [self] in
            guard let session = sessions.removeValue(forKey: token) else { return }
            // A request still in flight for a closed session ends with its
            // connection, so the player does not wait on it.
            for (id, ex) in exchanges where ex.session === session {
                ex.task?.cancel()
                exchanges[id] = nil
                ex.conn.close()
            }
            let mb = Double(session.bytesOut) / 1_000_000
            debugLog("[RELAY] session \(session.tag) closed after \(session.requests) request(s), \(String(format: "%.1f", mb)) MB")
        }
    }

    /// A system HTTP proxy or PAC: iOS sends loopback requests through it
    /// too (HLSDelivery), so a relay URL may never come back. VOD then
    /// plays without the key instead. Logged once, with no URL or key.
    func noteSystemProxyFallback() {
        queue.async { [self] in
            guard !proxyFallbackLogged else { return }
            proxyFallbackLogged = true
            debugLog("[RELAY] a system HTTP proxy or PAC is set: on-demand plays without the key instead of through the relay")
        }
    }

    // MARK: Listener

    /// The listener's port once it is ready, starting it when needed. Waits
    /// up to 2 s off the relay queue (the state callback runs on it).
    private func readyPort() -> UInt16? {
        let wait: DispatchSemaphore? = queue.sync {
            if listenerReady, listener != nil, port != 0 { return nil }
            if listener == nil { startListener() }
            let s = DispatchSemaphore(value: 0)
            readyWaiters.append(s)
            return s
        }
        if let wait, wait.wait(timeout: .now() + 2) == .timedOut {
            debugLog("[RELAY] loopback listener not ready within 2 s")
            return nil
        }
        return queue.sync { listenerReady && port != 0 ? port : nil }
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: the relay never serves the LAN. The 127.0.0.1 bind
        // is what refuses a connection made to the LAN address (measured
        // 2026-11-14 in the iOS 27 simulator: the interface requirement
        // alone still accepted one).
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params, on: .any) else {
            debugLog("[RELAY] loopback listener could not be created")
            wakeWaiters()
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.port = l.port?.rawValue ?? 0
                self.listenerReady = self.port != 0
                debugLog("[RELAY] loopback listener ready")
                self.wakeWaiters()
            case .failed, .cancelled:
                // A suspended app can lose its listening socket; the next
                // open starts a fresh listener, and players on the old port
                // fail into their own retry.
                debugLog("[RELAY] loopback listener ended (\(state)); the next open restarts it")
                self.listener = nil
                self.listenerReady = false
                self.port = 0
                l.cancel()
                self.wakeWaiters()
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    private func wakeWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.signal() }
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        guard connections.count < Self.maxConnections else {
            debugLog("[RELAY] connection cap (\(Self.maxConnections)) reached; refusing one")
            nw.cancel()
            return
        }
        let conn = Connection(nw: nw, relay: self)
        connections[ObjectIdentifier(conn)] = conn
        conn.start(on: queue)
    }

    fileprivate func connectionEnded(_ conn: Connection) {
        connections[ObjectIdentifier(conn)] = nil
        if let ex = conn.exchange, let task = ex.task {
            task.cancel()
            exchanges[task.taskIdentifier] = nil
        }
        conn.exchange = nil
    }

    /// One player request, on `queue`.
    fileprivate func handle(_ head: PlayerRelayPolicy.RequestHead, on conn: Connection) {
        guard head.method == "GET" || head.method == "HEAD" else {
            conn.respond(status: 405, contentType: "text/plain", body: Data("method not allowed".utf8),
                         keepAlive: false, headOnly: false, extra: "Allow: GET, HEAD\r\n")
            return
        }
        guard let route = PlayerRelayPolicy.parseRelayPath(head.path), let session = sessions[route.token],
              let resource = session.resource(route.id) else {
            conn.respond(status: 404, contentType: "text/plain", body: Data("not found".utf8),
                         keepAlive: head.keepAlive, headOnly: head.method == "HEAD", extra: "")
            return
        }
        session.requests += 1
        if session.requests == 1 {
            debugLog("[RELAY] session \(session.tag) first player request (\(resource.kind.rawValue))")
        }
        let upstreamURL = resource.kind == .playlist || route.id == 0
            ? PlayerRelayPolicy.forwardingHLSDirectives(fromPlayerQuery: head.query, to: resource.url)
            : resource.url
        var send = resource.keyed ? session.headers : RedirectAuthPolicy.withoutSignIn(session.headers)
        if resource.keyed {
            // Re-read the key for every request: a replaced key goes out as
            // its successor, a key held as rejected is never sent.
            guard let gated = StreamFetchAuth.headers(send, url: upstreamURL) else {
                conn.respond(status: 401, contentType: "text/plain", body: Data("HTTP 401".utf8),
                             keepAlive: head.keepAlive, headOnly: head.method == "HEAD", extra: "")
                return
            }
            send = gated
        }
        var request = URLRequest(url: upstreamURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = head.method
        for (name, value) in send where name.caseInsensitiveCompare("Range") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil, let ua = head.headers["user-agent"] {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        // Identity, so Content-Length and Range stay exact end to end.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = head.headers["range"] { request.setValue(range, forHTTPHeaderField: "Range") }
        let task = urlSession.dataTask(with: request)
        let ex = Exchange(conn: conn, session: session, resource: resource, task: task,
                          headOnly: head.method == "HEAD", keepAlive: head.keepAlive,
                          sentHeaders: send, upstreamURL: upstreamURL)
        conn.exchange = ex
        exchanges[task.taskIdentifier] = ex
        task.resume()
    }

    // MARK: URLSession delegate (on `queue`)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let next = RedirectAuthPolicy.redirect(request, previous: task.currentRequest, original: task.originalRequest)
        if let ex = exchanges[task.taskIdentifier], ex.resource.keyed,
           next == nil || !RedirectAuthPolicy.carriesSignIn(next, of: task.originalRequest) {
            ex.keyedAllTheWay = false
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let ex = exchanges[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        ex.status = http.statusCode
        ex.finalURL = dataTask.currentRequest?.url ?? http.url
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { ex.responseHeaders[k.lowercased()] = v }
        }
        ex.expectedLength = http.expectedContentLength
        if http.statusCode == 401, ex.resource.keyed {
            StreamFetchAuth.note401(ex.sentHeaders, url: ex.upstreamURL)
        }
        if http.statusCode >= 400, ex.session.errorsLogged < 5 {
            ex.session.errorsLogged += 1
            debugLog("[RELAY] session \(ex.session.tag) upstream \(ex.resource.kind.rawValue) HTTP \(http.statusCode)")
        }
        let type = ex.responseHeaders["content-type"]?.lowercased() ?? ""
        let path = ex.finalURL?.path.lowercased() ?? ""
        if type.contains("mpegurl") || path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") {
            ex.mode = .buffer
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let ex = exchanges[dataTask.taskIdentifier], !ex.conn.closed else { return }
        if ex.mode == .undecided {
            ex.mode = HLSRelayPlaylist.looksLikePlaylist(data) ? .buffer : .stream
        }
        if ex.mode == .buffer {
            ex.body.append(data)
            if ex.body.count > Self.maxPlaylistBytes {
                debugLog("[RELAY] session \(ex.session.tag) playlist over \(Self.maxPlaylistBytes / 1_048_576) MB; dropped")
                dataTask.cancel()
            }
            return
        }
        if !ex.headerSent { sendStreamHead(ex) }
        guard !ex.headOnly else { return }
        var chunk = Data()
        if ex.chunked {
            chunk.reserveCapacity(data.count + 16)
            chunk.append(Data((String(data.count, radix: 16) + "\r\n").utf8))
            chunk.append(data)
            chunk.append(Data("\r\n".utf8))
        } else {
            chunk = data
        }
        let n = chunk.count
        ex.outstanding += n
        ex.session.bytesOut += Int64(data.count)
        ex.conn.send(chunk) {
            ex.outstanding -= n
            if ex.suspended, ex.outstanding < Self.lowWater, !ex.conn.closed {
                ex.suspended = false
                ex.task?.resume()
            }
        }
        if ex.outstanding > Self.highWater, !ex.suspended {
            ex.suspended = true
            dataTask.suspend()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ex = exchanges.removeValue(forKey: task.taskIdentifier) else { return }
        guard !ex.conn.closed else { return }
        if let error, !ex.headerSent, ex.mode != .buffer || ex.status == 0 {
            if (error as NSError).code != NSURLErrorCancelled {
                debugLog("[RELAY] session \(ex.session.tag) upstream \(ex.resource.kind.rawValue) failed (\((error as NSError).domain) \((error as NSError).code))")
            }
            ex.conn.respond(status: 502, contentType: "text/plain", body: Data("upstream failed".utf8),
                            keepAlive: false, headOnly: ex.headOnly, extra: "")
            return
        }
        if ex.mode == .buffer {
            if error != nil {
                ex.conn.respond(status: 502, contentType: "text/plain", body: Data("upstream failed".utf8),
                                keepAlive: false, headOnly: ex.headOnly, extra: "")
                return
            }
            finishPlaylist(ex)
            return
        }
        if !ex.headerSent { sendStreamHead(ex) }
        if error != nil {
            // Mid-body: the player sees the connection end and retries.
            ex.conn.close()
            return
        }
        ex.conn.finishResponse(chunked: ex.chunked && !ex.headOnly, keepAlive: ex.keepAlive)
    }

    // MARK: Responses (on `queue`)

    private func sendStreamHead(_ ex: Exchange) {
        ex.headerSent = true
        var head = "HTTP/1.1 \(ex.status) \(Self.reason(ex.status))\r\n"
        head += "Content-Type: \(ex.responseHeaders["content-type"] ?? "application/octet-stream")\r\n"
        if let range = ex.responseHeaders["content-range"] { head += "Content-Range: \(range)\r\n" }
        if let ranges = ex.responseHeaders["accept-ranges"] { head += "Accept-Ranges: \(ranges)\r\n" }
        if let cache = ex.responseHeaders["cache-control"] { head += "Cache-Control: \(cache)\r\n" }
        let encoded = ex.responseHeaders["content-encoding"].map { $0.lowercased() != "identity" } ?? false
        if ex.expectedLength >= 0, !encoded {
            head += "Content-Length: \(ex.expectedLength)\r\n"
        } else if ex.headOnly {
            head += "Content-Length: 0\r\n"
        } else {
            ex.chunked = true
            head += "Transfer-Encoding: chunked\r\n"
        }
        head += ex.keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        ex.conn.send(Data(head.utf8)) {}
    }

    private func finishPlaylist(_ ex: Exchange) {
        let session = ex.session
        guard (200..<300).contains(ex.status), HLSRelayPlaylist.looksLikePlaylist(ex.body) else {
            // Not a playlist (a finished recording answering with the web
            // app's HTML, an error page): the player gets it as it came,
            // so it fails exactly as it did before.
            ex.conn.respond(status: ex.status, contentType: ex.responseHeaders["content-type"] ?? "application/octet-stream",
                            body: ex.body, keepAlive: ex.keepAlive, headOnly: ex.headOnly, extra: "")
            return
        }
        var text = String(decoding: ex.body, as: UTF8.self)
        if case .dvr(let startOffset, true) = session.purpose {
            let r = DVRPlaylistTransform.apply(text, startOffset: startOffset)
            text = r.text
            session.playlists += 1
            if session.playlists <= 2 || r.dropped != session.lastDropped {
                debugLog("[AVP-DVR] playlist rewrite #\(session.playlists): start=\(startOffset.map { String(format: "%.3f", $0) } ?? "server") dropped \(r.dropped) leading DISCONTINUITY, segments=\(r.segments), head=[\(r.head.joined(separator: " | "))]")
            }
            session.lastDropped = r.dropped
        }
        let base = ex.finalURL ?? ex.resource.url
        let keyedPlaylist = ex.resource.keyed && ex.keyedAllTheWay
        let port = self.port
        var keyed = 0
        var plain = 0
        text = HLSRelayPlaylist.rewrite(text, base: base) { uri, kind in
            let up = PlayerRelayPolicy.upstream(for: uri, playlist: base, playlistKeyed: keyedPlaylist, origin: session.origin)
            if up.keyed { keyed += 1 } else { plain += 1 }
            let id = session.register(up.url, keyed: up.keyed, kind: kind)
            return "http://127.0.0.1:\(port)/r/\(session.token)/\(id)/\(PlayerRelayPolicy.resourceName(for: up.url))"
        }
        if !session.loggedRewrite {
            session.loggedRewrite = true
            debugLog("[RELAY] session \(session.tag) playlist rewritten: \(keyed + plain) URI(s), \(keyed) with the sign-in, \(plain) without")
        }
        ex.conn.respond(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8),
                        keepAlive: ex.keepAlive, headOnly: ex.headOnly, extra: "Cache-Control: no-cache\r\n")
    }

    fileprivate static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301, 302, 303, 307, 308: return "Redirect"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 410: return "Gone"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }

    // MARK: Types

    /// Session, Exchange and Connection are touched only on `queue`.
    fileprivate final class Session: @unchecked Sendable {
        struct Resource { let url: URL; let keyed: Bool; let kind: HLSRelayPlaylist.Kind }

        let token: String
        let origin: URL
        let headers: [String: String]
        let purpose: Purpose
        let keyed: Bool
        var requests = 0
        var bytesOut: Int64 = 0
        var errorsLogged = 0
        var playlists = 0
        var lastDropped = -1
        var loggedRewrite = false
        private var resources: [Int: Resource] = [:]
        private var ids: [String: Int] = [:]
        private var order: [Int] = []
        private var orderHead = 0
        private var nextID = 0

        /// First 8 hex digits of the token, for the log (the token itself is
        /// the session's capability).
        var tag: String { String(token.prefix(8)) }

        init(origin: URL, headers: [String: String], purpose: Purpose) {
            var bytes = [UInt8](repeating: 0, count: 16)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                var g = SystemRandomNumberGenerator()
                bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }
            }
            token = bytes.map { String(format: "%02x", $0) }.joined()
            self.origin = origin
            // The in-process "watch from the beginning" marker is the
            // player's, never the server's.
            self.headers = headers.filter { $0.key.caseInsensitiveCompare("X-Aerio-Start-From-Beginning") != .orderedSame }
            self.purpose = purpose
            keyed = RedirectAuthPolicy.headersCarrySignIn(headers)
        }

        func register(_ url: URL, keyed: Bool, kind: HLSRelayPlaylist.Kind) -> Int {
            let key = (keyed ? "k|" : "o|") + url.absoluteString
            if let id = ids[key] { return id }
            let id = nextID
            nextID += 1
            resources[id] = Resource(url: url, keyed: keyed, kind: kind)
            ids[key] = id
            order.append(id)
            // Forget the oldest past the cap, never the entry (id 0).
            while resources.count > PlayerRelay.maxResources, orderHead < order.count {
                let old = order[orderHead]
                orderHead += 1
                guard old != 0, let r = resources.removeValue(forKey: old) else { continue }
                ids[(r.keyed ? "k|" : "o|") + r.url.absoluteString] = nil
            }
            if orderHead > 4096, orderHead * 2 > order.count {
                order.removeFirst(orderHead)
                orderHead = 0
            }
            return id
        }

        func resource(_ id: Int) -> Resource? { resources[id] }
    }

    fileprivate final class Exchange: @unchecked Sendable {
        enum Mode { case undecided, stream, buffer }

        let conn: Connection
        let session: Session
        let resource: Session.Resource
        var task: URLSessionDataTask?
        let headOnly: Bool
        let keepAlive: Bool
        let sentHeaders: [String: String]
        let upstreamURL: URL
        var status = 0
        var responseHeaders: [String: String] = [:]
        var expectedLength: Int64 = -1
        var mode = Mode.undecided
        var body = Data()
        var headerSent = false
        var chunked = false
        var outstanding = 0
        var suspended = false
        var finalURL: URL?
        var keyedAllTheWay = true

        init(conn: Connection, session: Session, resource: Session.Resource, task: URLSessionDataTask,
             headOnly: Bool, keepAlive: Bool, sentHeaders: [String: String], upstreamURL: URL) {
            self.conn = conn
            self.session = session
            self.resource = resource
            self.task = task
            self.headOnly = headOnly
            self.keepAlive = keepAlive
            self.sentHeaders = sentHeaders
            self.upstreamURL = upstreamURL
        }
    }

    /// One player connection: HTTP/1.1, keep-alive, one request at a time
    /// (pipelined requests wait in `buffer`). Everything on the relay queue.
    fileprivate final class Connection: @unchecked Sendable {
        let nw: NWConnection
        weak var relay: PlayerRelay?
        var exchange: Exchange?
        private(set) var closed = false
        private var buffer = Data()
        private var busy = false
        private var peerEOF = false
        private var idle: DispatchWorkItem?
        private var queue: DispatchQueue!

        init(nw: NWConnection, relay: PlayerRelay) {
            self.nw = nw
            self.relay = relay
        }

        func start(on queue: DispatchQueue) {
            self.queue = queue
            nw.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.ended()
                default: break
                }
            }
            nw.start(queue: queue)
            armIdle()
            receive()
        }

        private func ended() {
            guard !closed else { return }
            closed = true
            idle?.cancel()
            idle = nil
            relay?.connectionEnded(self)
        }

        func close() {
            guard !closed else { return }
            nw.cancel()
            ended()
        }

        private func receive() {
            nw.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.buffer.append(data) }
                if isComplete || error != nil {
                    self.peerEOF = true
                    if !self.busy { self.close() }
                    return
                }
                self.next()
                self.receive()
            }
        }

        private func next() {
            guard !busy, !closed else { return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16_384 { close() }
                return
            }
            let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            buffer.removeSubrange(..<end.upperBound)
            busy = true
            idle?.cancel()
            idle = nil
            guard let head = PlayerRelayPolicy.parseRequestHead(text) else {
                respond(status: 400, contentType: "text/plain", body: Data("bad request".utf8),
                        keepAlive: false, headOnly: false, extra: "")
                return
            }
            relay?.handle(head, on: self)
        }

        func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
            guard !closed else { return }
            nw.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if error != nil { self.close(); return }
                    completion()
                }
            })
        }

        /// A whole response at once (playlists, errors, held keys).
        func respond(status: Int, contentType: String, body: Data, keepAlive: Bool, headOnly: Bool, extra: String) {
            var head = "HTTP/1.1 \(status) \(PlayerRelay.reason(status))\r\n"
            head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" + extra
            head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
            var data = Data(head.utf8)
            if !headOnly { data.append(body) }
            send(data) { [weak self] in self?.responseDone(keepAlive: keepAlive) }
        }

        /// The end of a streamed response: the chunked terminator if needed.
        func finishResponse(chunked: Bool, keepAlive: Bool) {
            send(chunked ? Data("0\r\n\r\n".utf8) : Data()) { [weak self] in self?.responseDone(keepAlive: keepAlive) }
        }

        private func responseDone(keepAlive: Bool) {
            exchange = nil
            busy = false
            guard keepAlive, !peerEOF else { close(); return }
            armIdle()
            next()
        }

        private func armIdle() {
            idle?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.busy else { return }
                self.close()
            }
            idle = work
            queue.asyncAfter(deadline: .now() + PlayerRelay.idleTimeout, execute: work)
        }
    }
}

nonisolated(unsafe) var playerRelayHandleKey: UInt8 = 0

extension AVPlayer {
    /// Keeps a relay session alive exactly as long as this player: a Kept
    /// Live player keeps its session, a released one closes it, and an item
    /// rebuilt on the same relay URL (the DVR no-media reload) still finds it.
    func retainRelay(_ handle: PlayerRelay.Handle?) {
        guard let handle else { return }
        objc_setAssociatedObject(self, &playerRelayHandleKey, handle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// The AirPlay format gate's answer (VODAirPlayFormatGate, iOS). Declared
/// for every platform so the tile's start path can carry it.
enum VODAirPlayVerdict {
    /// The receiver may have the item (or the gate does not apply).
    case handOff
    /// Kept on this device, paused, and the user told.
    case refused
    /// Kept off the receiver only: the version fallback is waiting for
    /// its switched copy's own item, so no pause and no message.
    case held
}

#if os(iOS)
/// AirPlay for an on-demand item the relay serves. In AirPlay video mode
/// AVPlayer hands the item URL to the receiver, which cannot reach
/// 127.0.0.1. When the receiver takes the item (external playback active)
/// or a video receiver appears on the route mid-play, the format gate
/// decides; a receiver that may have the title gets a fresh player built
/// for it (the tile restarts at the current position through the same
/// start-for-the-receiver path a movie started with the route up takes:
/// the server's own URL with no key, the URL the receiver was handed
/// before the relay existed). No running player's item is ever swapped:
/// that swap blocked the main thread 2 to 4.3 s inside AVFoundation every
/// time (device log 2026-11-17 08:32:16.986, 2927 ms). The receiver must
/// take the fresh player's item within `confirmTimeout`, or this phone
/// plays it with external playback held off until the user picks a
/// receiver again.
@MainActor
final class RelayVODAirPlayHandover {
    private enum State { case relay, deciding, awaitingTake, receiver }

    /// How long the receiver gets to take the server's URL, counted from
    /// the start. Device pass 2026-11-15: the takes that worked came 5.5 s
    /// (Apple TV, 17:32:54 to 17:32:59) and 5.7 s (Roku, 18:06:25 to
    /// 18:06:31) after the hand-off.
    static let confirmTimeout: TimeInterval = 15

    private weak var player: AVPlayer?
    private let upstream: URL
    private let relayURL: URL
    private let label: String
    private var state = State.relay
    private var externalObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    private var pickedObserver: NSObjectProtocol?
    /// The receiver did not take the item (or the gate kept it here) and
    /// this phone plays it with external playback held off. Only a new
    /// pick (our route sheet, or a receiver newly on the route) tries the
    /// receiver again.
    private var heldLocal = false

    /// The tile rebinds its stall watchdog to the item: suspended while
    /// the receiver plays (the local clock is not this phone's render).
    var onItemSwapped: ((_ item: AVPlayerItem, _ receiverPlays: Bool) -> Void)?
    /// The format gate refused the receiver: the tile records a user-style
    /// pause so no watchdog, retry, or nudge plays it again (owner
    /// 2026-11-16: the movie waits, paused, for the user's next move).
    var onRefused: (() -> Void)?
    /// Mid-play pick the receiver may play: the tile tears this player down
    /// and starts again at `positionSeconds` with a player built for the
    /// receiver (owner 2026-11-17: a fresh player instead of the swap).
    var onRestartForReceiver: ((_ positionSeconds: Double, _ why: String) -> Void)?
    /// Set only for a mid-play restart for the receiver: its take timed
    /// out, so the tile starts once more on this device through the relay
    /// (with the key) at `positionSeconds`, instead of playing the server's
    /// URL without the key for the rest of the title.
    var onTakeTimedOut: ((_ positionSeconds: Double) -> Void)?
    /// No background keepalive here (device log 2026-11-17 09:20:41): the
    /// silent AVAudioEngine started on the AirPlay route 100 ms before
    /// external playback dropped and the receiver showed its music screen.
    /// The receiver plays the server's URL itself; AVPlayer's external
    /// playback under the active .playback session keeps the app eligible
    /// to run in the background (UIBackgroundModes audio).
    /// The tile kept the movie playing for the receiver at background entry
    /// (for the foreground line).
    private var heldForBackground = false

    init(player: AVPlayer, upstream: URL, relayURL: URL, label: String) {
        self.player = player
        self.upstream = upstream
        self.relayURL = relayURL
        self.label = label
    }

    func attach() {
        guard let player else { return }
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor in if active { self?.handover("the receiver took the item") } }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let newDevice = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .newDeviceAvailable
            MainActor.assumeIsolated {
                guard AirPlayMonitor.shared.willServeReceiver else { return }
                // Held here after a receiver did not take the item: any
                // other route change (category, override, the same
                // receiver re-announced) would loop restart and fallback.
                if self?.heldLocal == true, !newDevice { return }
                self?.handover("an AirPlay video receiver is on the route")
            }
        }
        pickedObserver = NotificationCenter.default.addObserver(
            forName: .aerioAirPlayRoutePicked, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard AirPlayMonitor.shared.willServeReceiver else { return }
                self?.handover("the AirPlay route was picked again")
            }
        }
    }

    /// Headless start (owner 2026-11-17, device log the same day: the swap
    /// on a running player blocked the main thread 2 to 4.3 s inside
    /// AVFoundation every time). The verdict was taken before the player
    /// existed. `.handOff`: the tile built the player on the server's URL
    /// without the key, with external playback on and the route up, so the
    /// receiver gets it with no item swap; it must take it within
    /// `confirmTimeout`, else this phone plays it with external playback
    /// held off (live's fall-back). Otherwise the item stays on this device,
    /// held off, and only a new pick tries the receiver again.
    func attachStarted(verdict: VODAirPlayFormatGate.Verdict) {
        guard let player, let item = player.currentItem else { return }
        attach()
        guard verdict == .handOff else {
            heldLocal = true
            return
        }
        state = .awaitingTake
        let deadline = Date().addingTimeInterval(Self.confirmTimeout)
        Task { @MainActor [weak self, weak player] in
            let took = await Self.awaitTake({ player }, item: item, deadline: deadline)
            guard let self, let player = self.player, player.currentItem === item, let took else { return }
            if took {
                self.state = .receiver
                debugLog("[AVP-AIRPLAY] VOD \(self.label): external playback active (headless start, no item swap)")
                self.watchReceiver(item)
                return
            }
            AirPlayTileDelivery.holdExternalOff(player)
            self.heldLocal = true
            self.state = .relay
            self.onItemSwapped?(item, false)
            debugLog("[AVP-AIRPLAY] VOD \(self.label): the receiver did not take the movie within \(Int(Self.confirmTimeout)) s; playing on this device with external playback held off until a receiver is picked again")
            AirPlayMonitor.shared.headlessTuneFellBack(reason: "the receiver did not take the movie")
            if let back = self.onTakeTimedOut {
                self.onTakeTimedOut = nil
                let t = player.currentTime().seconds
                back(t.isFinite ? max(0, t) : 0)
            }
        }
    }

    /// True once `player` plays `item` externally, false at `deadline`, nil
    /// when the player or its item went away first.
    static func awaitTake(_ player: () -> AVPlayer?, item: AVPlayerItem, deadline: Date) async -> Bool? {
        while true {
            guard let p = player(), p.currentItem === item else { return nil }
            if p.isExternalPlaybackActive { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func detach() {
        releaseHold()
        heldForBackground = false
        externalObservation = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let pickedObserver { NotificationCenter.default.removeObserver(pickedObserver) }
        routeObserver = nil
        pickedObserver = nil
        player = nil
    }

    /// Mid-play: the gate decides on the running item, then either the
    /// tile restarts for the receiver (fresh player, no item swap) or the
    /// movie stays here with external playback held off.
    private func handover(_ why: String) {
        guard state == .relay, let player, let old = player.currentItem,
              let url = (old.asset as? AVURLAsset)?.url else { return }
        // The server's URL already playing on the receiver needs nothing.
        if url == upstream, player.isExternalPlaybackActive { return }
        guard url == relayURL || url == upstream else { return }
        state = .deciding
        // A known non-Apple receiver (Roku) cannot play every MP4 (device
        // pass 2026-11-16: HEVC + AC-3 froze on a music logo), so decide
        // before handing it the server's URL.
        Task { @MainActor [weak self] in
            let verdict = await VODAirPlayFormatGate.blocks(item: old, mkvRemux: false, source: self?.upstream,
                                                            label: self?.label ?? "")
            guard let self else { return }
            guard let player = self.player, player.currentItem === old else { self.state = .relay; return }
            let t = old.currentTime().seconds
            let position = t.isFinite ? max(0, t) : 0
            let verdictText: String = {
                switch verdict {
                case .handOff: return "hand-off"
                case .refused: return "refused"
                case .held: return "held"
                }
            }()
            if verdict != .handOff {
                AirPlayTileDelivery.holdExternalOff(player)
                self.heldLocal = true
                self.state = .relay
                let refused = verdict == .refused
                if refused {
                    player.pause()
                    self.onRefused?()
                }
                debugLog(String(format: "[AVP-AIRPLAY] VOD %@: mid-play decision (%@) at %.1fs: verdict=%@ path=this device%@, external playback held off until a receiver is picked again",
                                self.label, why, position, verdictText,
                                refused ? ", paused" : " (not paused: the version fallback waits on its own copy)"))
                return
            }
            guard let restart = self.onRestartForReceiver else {
                // Never expected: the tile always wires it. No swap.
                AirPlayTileDelivery.holdExternalOff(player)
                self.heldLocal = true
                self.state = .relay
                debugLog(String(format: "[AVP-AIRPLAY] VOD %@: mid-play decision (%@) at %.1fs: verdict=hand-off but no restart hook; kept on this device, external playback held off",
                                self.label, why, position))
                return
            }
            debugLog(String(format: "[AVP-AIRPLAY] VOD %@: mid-play decision (%@) at %.1fs: verdict=hand-off path=restart for the receiver (fresh player on the server's URL without the key, no item swap)",
                            self.label, why, position))
            restart(position, why)
        }
    }

    /// Background entry (the tile's grace and quiesce paths): true when the
    /// receiver is playing the item, so the tile must neither pause nor
    /// quiesce. `userPaused`: the user paused it; that movie keeps the usual
    /// background handling.
    func handleBackgroundEntry(userPaused: Bool) -> Bool {
        guard state == .receiver, let player, player.isExternalPlaybackActive, !userPaused,
              player.timeControlStatus != .paused || player.rate != 0 else { return false }
        if !heldForBackground {
            heldForBackground = true
            let t = player.currentTime().seconds
            debugLog(String(format: "[AVP-AIRPLAY] VOD %@: background entry: kept playing for the receiver at %.1fs (control=%@); tile pause and quiesce skipped",
                            label, t.isFinite ? t : 0, AirPlayMonitor.playerStatusText(player)))
        }
        return true
    }

    /// Foreground return: one line when the movie was held for the receiver.
    func handleForegroundReturn() {
        guard heldForBackground else { return }
        heldForBackground = false
        let t = player?.currentTime().seconds ?? -1
        debugLog(String(format: "[AVP-AIRPLAY] VOD %@: foreground: still on the receiver (external=%@ control=%@ t=%.1fs), no rebuild",
                        label, player?.isExternalPlaybackActive == true ? "yes" : "no",
                        AirPlayMonitor.playerStatusText(player), t.isFinite ? t : -1))
    }

    /// Ends the hold taken when the receiver did not take the item.
    private func releaseHold() {
        guard heldLocal else { return }
        heldLocal = false
        if let player { AirPlayTileDelivery.releaseExternalHold(player) }
    }

    // MARK: Diagnostics (2026-11-16, Roku movie AirPlay spins)

    /// What the receiver is doing with the server's URL, as far as this
    /// phone can see: the asset's formats once, then every 5 s for 90 s the
    /// item and player state, the error log, and the access log.
    private func watchReceiver(_ item: AVPlayerItem) {
        let label = self.label
        Task { @MainActor [weak self] in
            if let tracks = try? await item.asset.load(.tracks) {
                var parts: [String] = []
                for t in tracks {
                    let descs = (try? await t.load(.formatDescriptions)) ?? []
                    for d in descs {
                        let sub = CMFormatDescriptionGetMediaSubType(d)
                        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xFF) }, encoding: .ascii) ?? "\(sub)"
                        var extra = ""
                        if t.mediaType == .audio, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                            extra = " ch=\(asbd.mChannelsPerFrame) rate=\(Int(asbd.mSampleRate))"
                        } else if t.mediaType == .video {
                            let dims = CMVideoFormatDescriptionGetDimensions(d)
                            extra = " \(dims.width)x\(dims.height)"
                        }
                        parts.append("\(t.mediaType.rawValue)=\(fourCC)\(extra)")
                    }
                }
                debugLog("[AVP-AIRPLAY] VOD \(label): receiver item formats: \(parts.joined(separator: ", "))")
            }
            for tick in 1...18 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let player = self.player, player.currentItem === item else { return }
                let t = item.currentTime().seconds
                let loaded = item.loadedTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds } ?? -1
                let errs = item.errorLog()?.events ?? []
                let lastErr = errs.last.map { "\($0.errorDomain) \($0.errorStatusCode) '\($0.errorComment ?? "")'" } ?? "none"
                let access = item.accessLog()?.events.last
                let bytes = access?.numberOfBytesTransferred ?? -1
                let status: String = {
                    switch player.timeControlStatus {
                    case .paused: return "paused"
                    case .playing: return "playing"
                    case .waitingToPlayAtSpecifiedRate: return "waiting(\(player.reasonForWaitingToPlay?.rawValue ?? "nil"))"
                    @unknown default: return "unknown"
                    }
                }()
                debugLog(String(format: "[AVP-AIRPLAY] VOD %@: receiver watch %lds: item=%ld control=%@ external=%@ t=%.1f loadedEnd=%.1f rate=%.2f errors=%ld last=%@ accessEvents=%ld bytes=%lld itemError=%@",
                                label, tick * 5, item.status.rawValue, status, player.isExternalPlaybackActive ? "yes" : "no",
                                t.isFinite ? t : -1, loaded.isFinite ? loaded : -1, player.rate, errs.count, lastErr,
                                item.accessLog()?.events.count ?? 0, bytes,
                                item.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "none"))
            }
        }
    }
}

/// Whether a movie or episode may go to the AirPlay receiver on the route.
/// Only a receiver KNOWN to be non-Apple (TXT model resolved, not Apple, not
/// audio-only) is ever refused; Apple and unresolved receivers keep the
/// hand-off they always had. Device pass 2026-11-16 (Roku 3840R): H.264 +
/// AAC plays, HEVC + AC-3 sits on a music logo with no error on the phone,
/// and the MKV remux is served on 127.0.0.1, which a receiver cannot reach.
@MainActor
enum VODAirPlayFormatGate {
    /// One message per pick: a pick can arrive as both a route change and
    /// our route sheet's notification, a few seconds apart.
    private static var lastShown: (key: String, at: Date)?
    private static let messageWindow: TimeInterval = 10

    typealias Verdict = VODAirPlayVerdict

    /// Whether the item may go to the receiver; shows the message when not.
    /// `source`: the tile URL the item plays (the version fallback counts a
    /// refusal only against the copy it belongs to).
    static func blocks(item: AVPlayerItem, mkvRemux: Bool, source: URL?, label: String) async -> Verdict {
        let receiver = await resolvedReceiver()
        let (video, audio) = await codecs(of: item)
        return decide(receiver: receiver, video: video, audio: audio, mkvRemux: mkvRemux,
                      source: source, label: label, readFrom: "item")
    }

    /// A movie or episode started with the AirPlay video route already up
    /// (headless start): the verdict before any player exists. Formats are
    /// read only for a known non-Apple receiver, from the server's URL
    /// without the key (what the receiver would fetch), time boxed; the MKV
    /// remux needs none (loopback, refused there). Same rule, version
    /// fallback, and message as `blocks`.
    static func startVerdict(url: URL, headers: [String: String], mkvRemux: Bool,
                             label: String) async -> Verdict {
        let receiver = await resolvedReceiver()
        let knownNonApple = receiver.model != nil && !receiver.isApple && !receiver.isAudioOnly
        var video: [String] = []
        var audio: [String] = []
        var readFrom = "not read (receiver not known non-Apple)"
        if knownNonApple, mkvRemux {
            readFrom = "not read (MKV remux)"
        } else if knownNonApple {
            let probed = await AirPlayVersionFallback.timed(AirPlayVersionFallback.perVersion) {
                await AirPlayVersionFallback.probe(url, headers: headers)
            }
            if let probed {
                video = probed.video
                audio = probed.audio
                readFrom = "phone probe"
            } else {
                readFrom = "phone probe, unreadable"
            }
        }
        return decide(receiver: receiver, video: video, audio: audio, mkvRemux: mkvRemux,
                      source: url, label: label, readFrom: readFrom)
    }

    private static func resolvedReceiver() async -> AirPlayReceiver {
        let receiver = AirPlayReceiverResolver.shared.resolveNow() ?? .unknown
        if receiver.model != nil { return receiver }
        return await AirPlayReceiverResolver.shared.resolveForHandoff()
    }

    private static func decide(receiver: AirPlayReceiver, video: [String], audio: [String], mkvRemux: Bool,
                               source: URL?, label: String, readFrom: String) -> Verdict {
        let videoText = video.isEmpty ? "none" : video.joined(separator: "+")
        let audioText = audio.isEmpty ? "none" : audio.joined(separator: "+")
        let path = mkvRemux ? "mkv-remux" : "direct-mp4"
        let knownNonApple = receiver.model != nil && !receiver.isApple && !receiver.isAudioOnly
        let blocked: Bool
        if !knownNonApple {
            blocked = false
        } else if mkvRemux {
            blocked = true
        } else {
            // Unreadable formats (nil): no grounds to refuse.
            blocked = !(receiverPlays(video: video, audio: audio) ?? true)
        }
        debugLog("[AVP-AIRPLAY] VOD \(label): format gate receiver='\(receiver.name)' model=\(receiver.model ?? "unknown") apple=\(receiver.isApple) audioOnly=\(receiver.isAudioOnly) video=\(videoText) audio=\(audioText) (\(readFrom)) path=\(path) -> \(blocked ? "kept on this device" : "hand-off as before")")
        if blocked {
            // Another version of the title may play there (owner
            // 2026-11-16); the fallback owns the message when it searches.
            switch AirPlayVersionFallback.shared.refused(receiver: receiver, label: label,
                                                         source: source, mkvRemux: mkvRemux) {
            case .notHandled: showMessage(receiver: receiver, label: label)
            case .handled: break
            case .ignored: return .held
            }
            return .refused
        } else if knownNonApple {
            AirPlayVersionFallback.shared.accepted(label: label, source: source)
        }
        return .handOff
    }

    /// The rule for a known non-Apple video receiver: H.264 video with AAC
    /// or MP3 audio (Roku 3840R device pass 2026-11-16). Takes the item's
    /// four-character codes or the server's measured codec names. Nil when
    /// nothing was read, so the caller decides what unknown means.
    static func receiverPlays(video: [String], audio: [String]) -> Bool? {
        if video.isEmpty && audio.isEmpty { return nil }
        let videoOK = video.allSatisfy { ["avc1", "avc3", "h264"].contains($0.lowercased()) }
        let audioOK = audio.isEmpty || audio.contains {
            let a = $0.lowercased()
            return a.hasPrefix("aac") || a == ".mp3" || a == "mp3"
        }
        return videoOK && audioOK
    }

    /// Codec four-character codes of the item's video and audio tracks.
    private static func codecs(of item: AVPlayerItem) async -> (video: [String], audio: [String]) {
        var tracks = item.tracks.compactMap(\.assetTrack)
        if tracks.isEmpty { tracks = (try? await item.asset.load(.tracks)) ?? [] }
        return await codecs(of: tracks)
    }

    /// Same as above for a bare asset (the version probe).
    static func codecs(of asset: AVAsset) async -> (video: [String], audio: [String]) {
        await codecs(of: (try? await asset.load(.tracks)) ?? [])
    }

    private static func codecs(of tracks: [AVAssetTrack]) async -> (video: [String], audio: [String]) {
        var video: [String] = []
        var audio: [String] = []
        for t in tracks where t.mediaType == .video || t.mediaType == .audio {
            let descs = (try? await t.load(.formatDescriptions)) ?? []
            for d in descs {
                let sub = CMFormatDescriptionGetMediaSubType(d)
                let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xFF) }, encoding: .ascii) ?? "\(sub)"
                if t.mediaType == .video { video.append(fourCC) } else { audio.append(fourCC) }
            }
        }
        return (video, audio)
    }

    static func receiverName(_ receiver: AirPlayReceiver) -> String {
        receiver.displayName?.trimmingCharacters(in: .whitespaces) ?? "this TV"
    }

    static func showMessage(receiver: AirPlayReceiver, label: String, message custom: String? = nil) {
        let name = receiverName(receiver)
        let key = "\(label)|\(receiver.name)"
        if let last = lastShown, last.key == key, Date().timeIntervalSince(last.at) < messageWindow { return }
        lastShown = (key, Date())
        let message = custom ?? "This video's format can't play on \(name) over AirPlay."
        debugLog("[AVP-AIRPLAY] VOD \(label): message shown: \(message)")
        AerioCastController.presentAlert(title: "AirPlay", message: message)
    }
}

/// AirPlay for an MKV movie or episode, which plays from the phone's
/// loopback remux (MKVVODServer). AirPlayMonitor turns external playback
/// on for every attached player, so a picked non-Apple receiver is handed
/// 127.0.0.1 and cannot play it; this pulls it back to the phone with
/// external playback held off and tells the user. Apple and unresolved
/// receivers are left exactly as before.
@MainActor
final class MKVVODAirPlayGate {
    private weak var player: AVPlayer?
    private let label: String
    /// The tile URL this remux plays (AirPlayVersionFallback matches on it).
    private let source: URL
    private var held = false
    /// A decision (refusal, hold, or a take that never came) keeps the item
    /// here: only a newly picked receiver is worth another look. The hold
    /// taken at creation is not one; it waits for the first decision.
    private var keptHere = false
    private var deciding = false
    private var externalObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    private var pickedObserver: NSObjectProtocol?
    /// Same as RelayVODAirPlayHandover.onRefused: a user-style pause.
    var onRefused: (() -> Void)?

    init(player: AVPlayer, source: URL, label: String) {
        self.player = player
        self.source = source
        self.label = label
    }

    /// `startVerdict`: a headless start already decided (the tile held
    /// external playback off for anything but `.handOff`); no second gate
    /// run. `.handOff` (Apple or unresolved receiver, as before) gets the
    /// same take deadline as the direct path, then this phone.
    /// `heldAtCreation`: the tile held external playback off before
    /// AirPlayMonitor.attach (a mid-play pick would otherwise flip the
    /// loopback item to the receiver before this gate decides); a hand-off
    /// verdict releases it.
    func attach(startVerdict: VODAirPlayFormatGate.Verdict? = nil, heldAtCreation: Bool = false) {
        guard let player else { return }
        if heldAtCreation { held = true }
        if let startVerdict {
            if startVerdict != .handOff {
                held = true
                keptHere = true
            } else if let item = player.currentItem {
                let deadline = Date().addingTimeInterval(RelayVODAirPlayHandover.confirmTimeout)
                Task { @MainActor [weak self, weak player] in
                    let took = await RelayVODAirPlayHandover.awaitTake({ player }, item: item, deadline: deadline)
                    guard let self, let took else { return }
                    if took {
                        debugLog("[AVP-AIRPLAY] VOD \(self.label): external playback active (headless start, MKV remux)")
                        return
                    }
                    guard let player = self.player else { return }
                    AirPlayTileDelivery.holdExternalOff(player)
                    self.held = true
                    self.keptHere = true
                    debugLog("[AVP-AIRPLAY] VOD \(self.label): the receiver did not take the MKV remux within \(Int(RelayVODAirPlayHandover.confirmTimeout)) s; playing on this device with external playback held off")
                    AirPlayMonitor.shared.headlessTuneFellBack(reason: "the receiver did not take the movie")
                }
            }
        }
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor in if active { self?.evaluate("the receiver took the item") } }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let newDevice = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .newDeviceAvailable
            MainActor.assumeIsolated {
                guard AirPlayMonitor.shared.willServeReceiver else { return }
                // Kept here: only a newly picked receiver is worth another look.
                if self?.keptHere == true, !newDevice { return }
                self?.evaluate("an AirPlay video receiver is on the route")
            }
        }
        pickedObserver = NotificationCenter.default.addObserver(
            forName: .aerioAirPlayRoutePicked, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard AirPlayMonitor.shared.willServeReceiver else { return }
                self?.evaluate("the AirPlay route was picked again")
            }
        }
        // AirPlayMonitor.attach already enabled external playback for a
        // route that was up before this tile.
        if startVerdict == nil, AirPlayMonitor.shared.willServeReceiver { evaluate("an AirPlay route was already up") }
    }

    func detach() {
        if held, let player { AirPlayTileDelivery.releaseExternalHold(player) }
        held = false
        keptHere = false
        externalObservation = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let pickedObserver { NotificationCenter.default.removeObserver(pickedObserver) }
        routeObserver = nil
        pickedObserver = nil
        player = nil
    }

    private func evaluate(_ why: String) {
        guard !deciding, let player, let item = player.currentItem else { return }
        deciding = true
        Task { @MainActor [weak self] in
            let verdict = await VODAirPlayFormatGate.blocks(item: item, mkvRemux: true, source: self?.source,
                                                            label: self?.label ?? "")
            guard let self else { return }
            self.deciding = false
            guard let player = self.player else { return }
            if verdict != .handOff {
                // Held either way: the receiver cannot reach the loopback
                // remux. Only a refusal of this copy pauses it.
                AirPlayTileDelivery.holdExternalOff(player)
                self.held = true
                self.keptHere = true
                let refused = verdict == .refused
                if refused {
                    player.pause()
                    self.onRefused?()
                }
                let at = player.currentTime().seconds
                debugLog(String(format: "[AVP-AIRPLAY] VOD %@: %@; MKV remux kept on this device%@ at %.1fs, external playback held off until a receiver is picked again",
                                self.label, why, refused ? ", paused" : " (not paused: the version fallback waits on its own copy)",
                                at.isFinite ? at : 0))
            } else if self.held {
                // A different receiver was picked: back to what
                // AirPlayMonitor does for every player.
                self.held = false
                self.keptHere = false
                AirPlayTileDelivery.releaseExternalHold(player)
                AirPlayMonitor.enableExternalPlayback(on: player)
                debugLog("[AVP-AIRPLAY] VOD \(self.label): \(why); hold released, external playback back on")
            }
        }
    }
}

/// Owner decision 2026-11-16: when the format gate refuses a known
/// non-Apple receiver, try the title's other provider copies (the Switch
/// Version options) before giving up. Each candidate is judged from the
/// server's measured codecs, else from a one-at-a-time probe on this
/// phone; the first that passes the gate's rule plays from the same
/// position and becomes the title's selected version, exactly as a pick
/// in Switch Version (owner decision 2026-11-17), and the gate runs again
/// on it. Nothing qualifies: the alert, paused.
@MainActor
final class AirPlayVersionFallback {
    static let shared = AirPlayVersionFallback()

    static let perVersion: TimeInterval = 8
    private static let overall: TimeInterval = 25
    /// A switched copy the gate never ruled on (the tile took a path with
    /// no gate) does not keep the session alive forever.
    private static let sessionLifetime: TimeInterval = 120

    @MainActor
    private final class Session {
        let tileID: String
        /// The tile's `addedAt`: a tile id can come back for the same title
        /// (a seeded tile's id is the title's), and a session must not
        /// outlive the tile it searched for.
        let tileAddedAt: Date
        let vodID: String
        let receiverName: String
        let displayName: String
        let label: String
        let started = Date()
        var deadline: Date
        var tried = Set<Int>()
        var switchedTo: Int?
        /// The switched copy's URL: only a refusal of an item playing it,
        /// on its own direct path, counts against it.
        var switchedURL: URL?
        var task: Task<Void, Never>?
        var watcher: Task<Void, Never>?
        var cancelled = false
        /// Refused at a headless start (the player still minimized behind
        /// the card): the search keeps it there, and a search that ends
        /// with nothing playing on the receiver tears it down, never
        /// opening the player here (owner 2026-11-17).
        var headless = false
        /// The player was handed no versions (the entry point passed none):
        /// the search loads the title's provider copies first.
        var loadsVersions = false
        /// The movie relations that load fetched, reused for the containers.
        var loadedProviders: [DispatcharrVODProviderRelation]?

        init(tileID: String, tileAddedAt: Date, vodID: String, receiver: AirPlayReceiver, label: String) {
            self.tileID = tileID
            self.tileAddedAt = tileAddedAt
            self.vodID = vodID
            self.receiverName = receiver.name
            self.displayName = VODAirPlayFormatGate.receiverName(receiver)
            self.label = label
            self.deadline = Date().addingTimeInterval(AirPlayVersionFallback.overall)
        }
    }

    private var session: Session?
    /// A tile whose provider copies were loaded and came to fewer than two:
    /// later refusals of it decline at once instead of fetching again.
    /// Keyed by the tile's id and `addedAt`, so a closed and reopened title
    /// is looked up again.
    private var loadedTooFew: (tileID: String, addedAt: Date, count: Int)?
    /// The search notice on screen (the tile's top capsule), kept up until
    /// the search ends (device recordings 2026-11-17: a fixed 6 s capsule
    /// set while the system route picker still covered the player was in
    /// no frame).
    private var noticeText: String?
    private var noticeCap: Task<Void, Never>?
    /// The tile whose capsule carries the notice (a version switch restarts
    /// that tile in place; the notice is re-asserted on whatever progress
    /// store it registers).
    private var noticeTileID: String?
    /// Shown while covered (the scene not active, or the system route
    /// picker up): the notice must then stay on screen for
    /// `minVisibleSeconds` of uncovered time, even past the end of the
    /// search (device run 2026-11-17 11:31:40 to 11:31:42: the search and
    /// the switch were done while the picker still covered the player).
    private var noticeNeedsVisibleTime = false
    /// When the notice first became uncovered (nil: not yet).
    private var noticeVisibleSince: Date?
    /// The search ended while the visible-time minimum still runs: the
    /// clear reason, applied once the minimum is met.
    private var noticePendingClear: String?
    private var noticeHold: Task<Void, Never>?
    private static let minVisibleSeconds: TimeInterval = 4
    /// Longest a notice stays up if no verdict ever ends the session: the
    /// search budget plus one switched copy's start verdict, with slack.
    private static let noticeCapSeconds: TimeInterval = 45
    private var noticeObservers: [NSObjectProtocol] = []

    private init() {
        // Shown while the route picker covered the player: present it again
        // once the picker closes or the scene is active again.
        let center = NotificationCenter.default
        noticeObservers.append(center.addObserver(forName: .aerioAirPlayRoutePickerClosed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AirPlayVersionFallback.shared.representNotice("the route picker closed") }
        })
        noticeObservers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AirPlayVersionFallback.shared.representNotice("the scene is active again") }
        })
    }

    /// A headless start refused (or held) while a search for it runs: the
    /// tile stays behind the card instead of expanding (owner 2026-11-17).
    var holdsHeadlessStart: Bool {
        guard let s = session, !s.cancelled else { return false }
        return s.headless
    }

    enum Refusal {
        /// No search: the gate shows today's alert.
        case notHandled
        /// A search runs (or continues) and owns the message.
        case handled
        /// Not the switched copy's own item (device log 2026-11-17 08:20:47:
        /// the switched MP4's extensionless URL opened on the MKV remux path
        /// first). Kept off the receiver, not paused, no message.
        case ignored
    }

    /// The gate refused `receiver` for an item playing `source`.
    func refused(receiver: AirPlayReceiver, label: String, source: URL?, mkvRemux: Bool) -> Refusal {
        let store = MultiviewStore.shared
        if let why = declineReason(store) {
            // Never silent again (device log 2026-11-17 11:46:51: a Movies
            // hero start handed the player no versions and nothing said so).
            debugLog("[AVP-AIRPLAY] VOD \(label): version fallback declined: \(why)")
            if let s = session { end(s, "the title has no other versions") }
            return .notHandled
        }
        guard let tile = store.vodSoloTile, let vodID = tile.vodID else { return .notHandled }
        if let s = session, s.tileID == tile.id, s.tileAddedAt == tile.addedAt, s.vodID == vodID,
           s.receiverName == receiver.name,
           Date().timeIntervalSince(s.started) < Self.sessionLifetime {
            // A second notification of the same pick while searching.
            if s.task != nil { return .handled }
            if let switched = s.switchedTo {
                // The switch was judged on the copy's direct formats; a
                // remux of it, or an item of another URL, says nothing
                // about them. Wait for its own direct item.
                guard !mkvRemux, let source, source == s.switchedURL else {
                    let what = source != nil && source == s.switchedURL ? "its MKV remux path" : "an item of another URL"
                    debugLog("[AVP-AIRPLAY] VOD \(label): version fallback: refusal on \(what), not relation \(switched)'s direct item; ignored, still waiting for its own verdict")
                    return .ignored
                }
                // The copy picked from measurements was refused on its own
                // item: never retry it, go on with the rest.
                s.switchedTo = nil
                s.switchedURL = nil
                s.tried.insert(switched)
                s.deadline = Date().addingTimeInterval(Self.overall)
                debugLog("[AVP-AIRPLAY] VOD \(label): version fallback: relation \(switched) refused by the gate after the switch; trying the next version")
                noticeSearchingAgain(s)
                run(s)
                return .handled
            }
        }
        if let s = session { end(s, "a new refusal replaced it") }
        let s = Session(tileID: tile.id, tileAddedAt: tile.addedAt, vodID: vodID, receiver: receiver, label: label)
        s.headless = AirPlayMonitor.shared.isHeadlessTuning
        session = s
        if store.vodVersionOptions.count > 1 {
            if let current = store.vodCurrentVersionID { s.tried.insert(current) }
            announce(s)
        } else {
            // Started from a surface that hands the player no versions
            // (Movies hero Play and Play from Beginning, for example): the
            // search loads them first, within its own time budget.
            s.loadsVersions = true
            debugLog("[AVP-AIRPLAY] VOD \(label): version fallback: the player was handed \(store.vodVersionOptions.count) version(s); loading the title's provider copies")
            // The card carries the search from the start, not only once the
            // versions are in (up to `perVersion`).
            if s.headless { AirPlayMonitor.shared.noteConnectingStatus(Self.cardStatus) }
        }
        run(s)
        return .handled
    }

    /// Why the fallback cannot search for the playing tile, or nil.
    private func declineReason(_ store: MultiviewStore) -> String? {
        guard let tile = store.vodSoloTile else { return "no single movie or episode tile is playing" }
        guard tile.kind == .vod else { return "the tile is not a movie or episode (kind \(tile.kind))" }
        guard let vodID = tile.vodID, !vodID.isEmpty else { return "the tile carries no title id" }
        guard tile.vodType == "movie" || tile.vodType == "episode" else {
            return "type \(tile.vodType) has no versions"
        }
        if store.vodVersionOptions.count > 1 { return nil }
        if let loaded = loadedTooFew, loaded.tileID == tile.id, loaded.addedAt == tile.addedAt {
            return "the title's provider copies were loaded for this tile already: \(loaded.count) version(s)"
        }
        guard Self.api(serverID: tile.vodServerID) != nil else {
            return "the player was handed \(store.vodVersionOptions.count) version(s) and the title is not on a Dispatcharr server, so none can be loaded"
        }
        return nil
    }

    /// The search starts with versions in hand: log, notice, card line.
    private func announce(_ s: Session) {
        let store = MultiviewStore.shared
        debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: versions found=\(store.vodVersionOptions.count) current=\(store.vodCurrentVersionID.map(String.init) ?? "auto"); notice shown")
        showNotice(Self.searchingText(s), tileID: s.tileID, headless: s.headless)
        // The capsule is in the minimized tile, out of sight: the card
        // carries the search.
        if s.headless { AirPlayMonitor.shared.noteConnectingStatus(Self.cardStatus) }
    }

    /// The gate let an item through: a switched copy reached the receiver.
    func accepted(label: String, source: URL?) {
        guard let s = session, s.task == nil, let switched = s.switchedTo,
              let source, source == s.switchedURL else { return }
        debugLog("[AVP-AIRPLAY] VOD \(label): version fallback: relation \(switched) passed the gate; handed to the receiver")
        end(s, nil)
    }

    private func end(_ s: Session, _ why: String?) {
        if let why { debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback ended: \(why)") }
        s.cancelled = true
        s.task?.cancel()
        s.watcher?.cancel()
        s.task = nil
        s.watcher = nil
        if session === s {
            session = nil
            clearNotice(why ?? "the search ended")
        }
        if s.headless, AirPlayMonitor.shared.connectingStatus == Self.cardStatus {
            AirPlayMonitor.shared.noteConnectingStatus(nil)
        }
    }

    /// The card's line while a headless start searches (one line, the
    /// length of "Connecting to AirPlay").
    static let cardStatus = "Trying other versions"

    /// A headless start whose search ended with nothing on the receiver
    /// (owner 2026-11-17): the title is not started and no player opens on
    /// this device; the card returns to the route's idle state. Only for
    /// the tile this search held, and not when a newer search for it took
    /// over (`replaced`).
    private func notStartedHeadless(_ s: Session, _ reason: String, replaced: Bool) {
        guard s.headless, !replaced else { return }
        let store = MultiviewStore.shared
        guard let tile = store.vodSoloTile, tile.id == s.tileID, tile.addedAt == s.tileAddedAt,
              tile.vodID == s.vodID else { return }
        AirPlayMonitor.shared.headlessStartNotStarted(label: s.label, reason: "version fallback: \(reason)",
                                                      searchEnded: true)
    }

    /// Still the same title, tile, and receiver. Checked between steps and
    /// by the watcher, which cancels a probe in flight.
    private func stillValid(_ s: Session) -> Bool {
        guard !s.cancelled, session === s else { return false }
        let store = MultiviewStore.shared
        guard let tile = store.vodSoloTile, tile.id == s.tileID, tile.addedAt == s.tileAddedAt,
              tile.vodID == s.vodID else { return false }
        guard AirPlayMonitor.shared.willServeReceiver else { return false }
        if let now = AirPlayReceiverResolver.shared.resolveNow(), now.name != s.receiverName { return false }
        return true
    }

    private func run(_ s: Session) {
        s.task = Task { @MainActor [weak self] in
            await self?.search(s)
        }
        s.watcher?.cancel()
        s.watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !s.cancelled, s.task != nil else { return }
                if !self.stillValid(s) {
                    // Stopped, another route, or the receiver left.
                    s.task?.cancel()
                    return
                }
            }
        }
    }

    private func search(_ s: Session) async {
        let store = MultiviewStore.shared
        if s.loadsVersions {
            s.loadsVersions = false
            let loaded = await loadVersions(s)
            guard stillValid(s), !Task.isCancelled else {
                searchCanceled(s)
                return
            }
            guard loaded.options.count > 1 else {
                let why = loaded.failure ?? "the title has \(loaded.options.count) version(s)"
                if loaded.failure == nil { loadedTooFew = (s.tileID, s.tileAddedAt, loaded.options.count) }
                debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback declined after loading: \(why)\(s.headless ? "" : "; kept on this device, paused")")
                end(s, nil)
                VODAirPlayFormatGate.showMessage(receiver: AirPlayReceiverResolver.shared.resolveNow() ?? .unknown,
                                                 label: s.label)
                notStartedHeadless(s, "the title has no other versions", replaced: false)
                return
            }
            store.adoptLoadedVODVersionOptions(vodID: s.vodID, options: loaded.options,
                                               selectedID: loaded.current, selectionKey: loaded.key)
            if let current = store.vodCurrentVersionID { s.tried.insert(current) }
            announce(s)
        }
        let options = store.vodVersionOptions
        let tile = store.vodSoloTile
        let headers = RedirectAuthPolicy.withoutSignIn(tile?.headers ?? [:])
        let isMovie = tile?.vodType == "movie"
        // Movies: the server's container and measured codecs per relation.
        // Episode copies are per account with no measurements, so they go
        // straight to the phone probe.
        var api: DispatcharrAPI?
        var movieID: Int?
        var containers: [Int: String] = [:]
        if isMovie, let id = Int(s.vodID), let made = Self.api(serverID: tile?.vodServerID) {
            api = made
            movieID = id
            var providers = s.loadedProviders
            if providers == nil {
                providers = await Self.timed(min(Self.perVersion, s.deadline.timeIntervalSinceNow)) {
                    try? await made.getMovieProviders(movieID: id)
                }
            }
            for rel in providers ?? [] {
                if let ext = rel.containerExtension { containers[rel.id] = ext.lowercased() }
            }
        }
        for option in options where !s.tried.contains(option.id) {
            guard stillValid(s), !Task.isCancelled else { break }
            guard s.deadline.timeIntervalSinceNow > 1 else {
                debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: \(Int(Self.overall)) s budget spent")
                break
            }
            s.tried.insert(option.id)
            let container = containers[option.id] ?? "unknown"
            if container == "mkv" {
                // Remuxed on loopback, which no receiver can reach.
                debugLog("[AVP-AIRPLAY] VOD \(s.label): version candidate relation=\(option.id) container=mkv codecs=- source=container verdict=skip")
                continue
            }
            let versionDeadline = min(Date().addingTimeInterval(Self.perVersion), s.deadline)
            var video: [String] = []
            var audio: [String] = []
            var source = "none"
            if let api, let movieID {
                let media = await Self.timed(versionDeadline.timeIntervalSinceNow) {
                    try? await api.getMovieProviderMedia(movieID: movieID, relationID: option.id)
                }
                if let media, media.videoCodec != nil || media.audioCodec != nil {
                    video = media.videoCodec.map { [$0] } ?? []
                    audio = media.audioCodec.map { [$0] } ?? []
                    source = "server"
                }
            }
            if source == "none", stillValid(s), !Task.isCancelled, versionDeadline.timeIntervalSinceNow > 0.5 {
                let url = option.url
                let probed = await Self.timed(versionDeadline.timeIntervalSinceNow) {
                    await Self.probe(url, headers: headers)
                }
                if let probed {
                    video = probed.video
                    audio = probed.audio
                    source = "phone probe"
                }
            }
            let plays = VODAirPlayFormatGate.receiverPlays(video: video, audio: audio)
            let codecs = "video=\(video.isEmpty ? "none" : video.joined(separator: "+")) audio=\(audio.isEmpty ? "none" : audio.joined(separator: "+"))"
            // Unknown is not a pass here: switching to a copy nothing could
            // read would only trade one refusal for a guess.
            let verdict = plays == true ? "qualifies" : (plays == false ? "refused" : "unknown, skipped")
            debugLog("[AVP-AIRPLAY] VOD \(s.label): version candidate relation=\(option.id) container=\(container) \(codecs) source=\(source) verdict=\(verdict)")
            guard plays == true else { continue }
            guard stillValid(s), !Task.isCancelled else { break }
            s.switchedTo = option.id
            s.switchedURL = option.url
            s.task = nil
            s.watcher?.cancel()
            s.watcher = nil
            // The server's container, when it names a direct-play one,
            // spares the extensionless URL the MKV remux attempt.
            let directHint = ["mp4", "m4v", "mov"].contains(container)
            if directHint { store.setVODDirectContainerHint(url: option.url, ext: container) }
            debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: switching to relation \(option.id) at the same position (saved as the title's version\(directHint ? ", direct \(container)" : ""))")
            noticeSwitched(s)
            store.switchVODVersion(option)
            return
        }
        guard stillValid(s), !Task.isCancelled else {
            searchCanceled(s)
            return
        }
        let message = "No version of this title can play on \(s.displayName) over AirPlay."
        debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: no version qualifies (\(s.tried.count) of \(options.count) tried)\(s.headless ? "" : "; kept on this device, paused")")
        // The alert says it all: no visible-time hold for the search notice.
        if session === s { clearNotice("nothing qualifies, the alert takes over", force: true) }
        end(s, nil)
        VODAirPlayFormatGate.showMessage(receiver: AirPlayReceiverResolver.shared.resolveNow() ?? .unknown,
                                         label: s.label, message: message)
        notStartedHeadless(s, "no version of this title plays on the receiver", replaced: false)
    }

    private func searchCanceled(_ s: Session) {
        let replaced = session != nil && session !== s
        if session === s { clearNotice("the search was canceled", force: true) }
        end(s, "canceled (movie stopped, another route, or the receiver left)")
        // Quietly: no player, no alert (owner 2026-11-17).
        notStartedHeadless(s, "version search canceled", replaced: replaced)
    }

    struct LoadedVersions {
        var options: [VODVersionOption] = []
        /// The option playing now (by the tile URL's pins, else the stored
        /// choice), excluded from the search.
        var current: Int?
        var key: String?
        /// Why nothing could be loaded (nil: loaded, `options` is the answer).
        var failure: String?
    }

    /// The playing title's provider copies, built with the same builder the
    /// detail page uses, for a player that was handed none. Within the
    /// session's budget (one provider-list request, `perVersion` at most).
    private func loadVersions(_ s: Session) async -> LoadedVersions {
        var out = LoadedVersions()
        let store = MultiviewStore.shared
        guard let tile = store.vodSoloTile, tile.id == s.tileID, tile.addedAt == s.tileAddedAt else {
            out.failure = "the tile changed"
            return out
        }
        guard let api = Self.api(serverID: tile.vodServerID) else {
            out.failure = "no Dispatcharr server for the title"
            return out
        }
        let serverUUID = tile.vodServerID.flatMap(UUID.init(uuidString:))
        // The tile's URL first; the progress store's copy of it otherwise.
        let urls = [tile.streamURL, store.audioProgressStore?.vodStreamURL.flatMap(URL.init(string:))]
            .compactMap { $0 }
        let budget = min(Self.perVersion, s.deadline.timeIntervalSinceNow)
        let playing = VODVersionSelectionStore.pins(in: tile.streamURL)
        let hasPins = playing.streamID != nil || playing.accountID != nil
        let started = Date()
        if tile.vodType == "movie" {
            guard let id = Int(s.vodID) else {
                out.failure = "non-numeric movie id \(s.vodID)"
                return out
            }
            guard let uuid = urls.lazy.compactMap({ VODVersionOption.proxyUUID(in: $0, kind: "movie") }).first else {
                out.failure = "the playing URL is not a Dispatcharr movie URL"
                return out
            }
            guard let providers = await Self.timed(budget, { try? await api.getMovieProviders(movieID: id) }) else {
                out.failure = "the provider list did not load within \(Int(budget)) s"
                return out
            }
            s.loadedProviders = providers
            var learned: [Int: VODLearnedStream] = [:]
            for rel in providers {
                if let l = VODVersionMeasurementStore.lookup(optionID: rel.id) { learned[rel.id] = l }
            }
            let labels = VODVersionLabeler.labels(providers: providers, media: [:], learned: learned)
            out.options = VODVersionOption.movieOptions(providers: providers, movieUUID: uuid, api: api,
                                                        label: { labels[$0.id] ?? $0.displayLabel })
            out.key = serverUUID.map {
                VODVersionSelectionStore.storageKey(serverID: $0, itemType: "movie", itemID: s.vodID)
            }
            let key = store.vodVersionSelectionKey ?? out.key
            let byPins = hasPins
                ? out.options.first { VODVersionSelectionStore.pins(in: $0.url) == playing }?.id : nil
            let stored = key.flatMap(VODVersionSelectionStore.selection(forKey:))
                .flatMap { id in out.options.contains { $0.id == id } ? id : nil }
            out.current = byPins ?? stored
        } else {
            guard let seriesID = WatchProgressManager.seriesID(vodID: s.vodID, serverID: tile.vodServerID),
                  let numericSeries = Int(seriesID) else {
                out.failure = "no series id saved for episode \(s.vodID)"
                return out
            }
            guard let uuid = urls.lazy.compactMap({ VODVersionOption.proxyUUID(in: $0, kind: "episode") }).first else {
                out.failure = "the playing URL is not a Dispatcharr episode URL"
                return out
            }
            guard let providers = await Self.timed(budget, { try? await api.getSeriesProviders(seriesID: numericSeries) }) else {
                out.failure = "the provider list did not load within \(Int(budget)) s"
                return out
            }
            out.options = VODVersionOption.episodeOptions(providers: providers, episodeUUID: uuid, api: api)
            out.key = serverUUID.map {
                VODVersionSelectionStore.storageKey(serverID: $0, itemType: "series", itemID: seriesID)
            }
            let key = store.vodVersionSelectionKey ?? out.key
            // Episode options are keyed by account.
            let byPins = playing.accountID.flatMap { account in out.options.contains { $0.id == account } ? account : nil }
            let stored = key.flatMap(VODVersionSelectionStore.accountPin(forKey:))
                .flatMap { id in out.options.contains { $0.id == id } ? id : nil }
            out.current = byPins ?? stored
        }
        debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: loaded \(out.options.count) version(s) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, current=\(out.current.map(String.init) ?? "auto")")
        return out
    }

    /// The gate's own notice spot: the tile's top capsule. It stays up
    /// until the search ends (a verdict on the switched copy, nothing
    /// qualifies, or the search canceled), capped at `noticeCapSeconds`.
    private func showNotice(_ text: String, tileID: String, headless: Bool) {
        // A new search replaces whatever an older one still held.
        noticeHold?.cancel()
        noticeHold = nil
        noticePendingClear = nil
        noticeText = text
        noticeTileID = tileID
        // Headless starts carry the search on the card (unchanged); a
        // notice shown while covered owes the user visible time.
        let covered = !Self.noticeUncovered
        noticeNeedsVisibleTime = !headless && covered
        noticeVisibleSince = nil
        if noticeNeedsVisibleTime {
            debugLog("[AVP-AIRPLAY] version fallback: notice shown while covered (\(Self.coverDescription)); it stays \(Int(Self.minVisibleSeconds)) s once uncovered")
        }
        noticeCap?.cancel()
        noticeCap = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeCapSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearNotice("\(Int(Self.noticeCapSeconds)) s cap", force: true)
        }
        guard let progress = MultiviewStore.shared.audioProgressStore else { return }
        progress.liveResumeNotice = text
    }

    /// The search succeeded and the switch began: the notice says what is
    /// happening now (owner 2026-11-17), wherever it is in its life.
    private func noticeSwitched(_ s: Session) {
        setNoticeText("This version can't play on \(s.displayName) over AirPlay. Playing another version.",
                      s, what: "Playing another version")
    }

    /// The switched copy was refused and the search goes on: back to the
    /// searching wording.
    private func noticeSearchingAgain(_ s: Session) {
        setNoticeText(Self.searchingText(s), s, what: "Trying other versions")
    }

    private static func searchingText(_ s: Session) -> String {
        "This version can't play on \(s.displayName) over AirPlay. Trying other versions of this title."
    }

    private func setNoticeText(_ text: String, _ s: Session, what: String) {
        guard noticeText != nil, noticeTileID == s.tileID, noticeText != text else { return }
        let old = noticeText
        noticeText = text
        if let progress = MultiviewStore.shared.audioProgressStore,
           progress.liveResumeNotice == old || progress.liveResumeNotice == nil {
            progress.liveResumeNotice = text
        }
        debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: notice now reads \(what)")
    }

    /// Neither the scene inactive (the system picker, Control Center, a
    /// call) nor the AirPlay route picker up.
    private static var noticeUncovered: Bool {
        UIApplication.shared.applicationState == .active
            && !AirPlayRoutePickerDelegate.shared.isPresenting
    }

    private static var coverDescription: String {
        var parts: [String] = []
        if UIApplication.shared.applicationState != .active { parts.append("scene not active") }
        if AirPlayRoutePickerDelegate.shared.isPresenting { parts.append("route picker open") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    /// The route picker closed or the scene came back: the notice is put
    /// up again if anything took it down, and a notice shown while covered
    /// starts counting its visible time.
    private func representNotice(_ why: String) {
        guard let text = noticeText else { return }
        if noticePendingClear == nil {
            // Still searching (or switched, awaiting the verdict): only the
            // session that owns the notice re-shows it.
            guard let s = session, !s.cancelled, !s.headless else { return }
        }
        guard Self.noticeOnTile(), let progress = MultiviewStore.shared.audioProgressStore else { return }
        let wasUp = progress.liveResumeNotice == text
        if !wasUp { progress.liveResumeNotice = text }
        debugLog("[AVP-AIRPLAY] version fallback: notice \(wasUp ? "still up" : "re-shown") (\(why))")
        startVisibleClockIfUncovered(why)
    }

    /// The notice's tile is still the playing solo VOD tile.
    private static func noticeOnTile() -> Bool {
        let shared = AirPlayVersionFallback.shared
        guard let id = shared.noticeTileID, let tile = MultiviewStore.shared.vodSoloTile else { return false }
        return tile.id == id
    }

    private func startVisibleClockIfUncovered(_ why: String) {
        guard noticeNeedsVisibleTime, noticeVisibleSince == nil, Self.noticeUncovered else { return }
        noticeVisibleSince = Date()
        debugLog("[AVP-AIRPLAY] version fallback: notice uncovered (\(why)); \(Int(Self.minVisibleSeconds)) s of visible time starts")
        ensureNoticeHold()
    }

    /// While the visible-time minimum runs: re-assert the capsule on the
    /// tile's progress store (a switch restarts the tile in place), let it
    /// go with the player when the player closes to the card or the tile
    /// leaves, and apply a pending clear once the minimum is met.
    private func ensureNoticeHold() {
        guard noticeHold == nil else { return }
        noticeHold = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, let text = self.noticeText else { return }
                if !Self.noticeOnTile() {
                    self.clearNotice("the movie stopped", force: true)
                    return
                }
                if NowPlayingManager.shared.isMinimized {
                    self.clearNotice("the player closed to the card", force: true)
                    return
                }
                if self.noticeVisibleSince == nil { self.startVisibleClockIfUncovered("checked") }
                if let progress = MultiviewStore.shared.audioProgressStore,
                   progress.liveResumeNotice == nil {
                    progress.liveResumeNotice = text
                    debugLog("[AVP-AIRPLAY] version fallback: notice re-shown on the restarted tile")
                }
                if let pending = self.noticePendingClear, self.visibleTimeMet {
                    self.clearNotice(pending + ", after \(Int(Self.minVisibleSeconds)) s on screen", force: true)
                    return
                }
            }
        }
    }

    private var visibleTimeMet: Bool {
        guard let since = noticeVisibleSince else { return false }
        return Date().timeIntervalSince(since) >= Self.minVisibleSeconds
    }

    /// `force`: the cap, the movie stopping, or the player closing to the
    /// card. Otherwise a notice still owed visible time stays up until it
    /// has had it.
    private func clearNotice(_ why: String, force: Bool = false) {
        guard let text = noticeText else {
            noticeCap?.cancel()
            noticeCap = nil
            return
        }
        if !force, noticeNeedsVisibleTime, !visibleTimeMet, Self.noticeOnTile(),
           !NowPlayingManager.shared.isMinimized {
            noticePendingClear = why
            debugLog("[AVP-AIRPLAY] version fallback: search ended (\(why)); notice held for its visible time (\(noticeVisibleSince.map { String(format: "%.1f s shown", Date().timeIntervalSince($0)) } ?? "still covered"))")
            ensureNoticeHold()
            return
        }
        noticeCap?.cancel()
        noticeCap = nil
        noticeHold?.cancel()
        noticeHold = nil
        noticePendingClear = nil
        noticeNeedsVisibleTime = false
        noticeVisibleSince = nil
        noticeText = nil
        noticeTileID = nil
        if let progress = MultiviewStore.shared.audioProgressStore, progress.liveResumeNotice == text {
            progress.liveResumeNotice = nil
        }
        debugLog("[AVP-AIRPLAY] version fallback: notice cleared (\(why))")
    }

    private static func api(serverID: String?) -> DispatcharrAPI? {
        guard let serverID, let container = AerioApp.sharedContainer else { return nil }
        let servers = (try? ModelContext(container).fetch(FetchDescriptor<ServerConnection>())) ?? []
        guard let server = servers.first(where: { $0.id.uuidString == serverID }),
              server.type == .dispatcharrAPI else { return nil }
        return DispatcharrAPI(baseURL: server.effectiveBaseURL,
                              auth: .apiKey(server.effectiveApiKey),
                              userAgent: server.effectiveUserAgent,
                              authMode: server.dispatcharrHeaderMode)
    }

    struct Codecs: Sendable {
        let video: [String]
        let audio: [String]
    }

    /// Reads one copy's tracks the way the player would open it (no sign-in,
    /// as the receiver will fetch it). One provider connection; released by
    /// cancelLoading when the time box ends, and dropped on return.
    static func probe(_ url: URL, headers: [String: String]) async -> Codecs? {
        var options: [String: Any] = [:]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let asset = AVURLAsset(url: url, options: options)
        let result = await withTaskCancellationHandler {
            await VODAirPlayFormatGate.codecs(of: asset)
        } onCancel: {
            asset.cancelLoading()
        }
        asset.cancelLoading()
        if Task.isCancelled || (result.video.isEmpty && result.audio.isEmpty) { return nil }
        return Codecs(video: result.video, audio: result.audio)
    }

    /// Runs `work`, canceled after `seconds` (and when the caller is).
    static func timed<T: Sendable>(_ seconds: TimeInterval,
                                           _ work: @escaping @MainActor () async -> T?) async -> T? {
        guard seconds > 0 else { return nil }
        let task = Task { @MainActor in await work() }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.cancel()
        }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        timer.cancel()
        return value
    }
}
#endif
