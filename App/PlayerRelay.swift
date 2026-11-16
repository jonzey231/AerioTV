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

#if os(iOS)
/// AirPlay for an on-demand item the relay serves. In AirPlay video mode
/// AVPlayer hands the item URL to the receiver, which cannot reach
/// 127.0.0.1, so when the receiver takes the item (external playback
/// active) or a video receiver appears on the route, the item is swapped
/// at its current position for the server's own URL with no key, the URL
/// the receiver was handed before the relay existed (the TV fetches from
/// the server; Dispatcharr VOD answers anonymously). The receiver must take
/// the swapped item within `confirmTimeout` of the swap, or the relay item
/// comes back and this phone plays it, with external playback held off
/// (the receiver cannot reach 127.0.0.1) until the user picks a receiver
/// again. Once the receiver has it the item stays as it is for the rest of
/// the play.
@MainActor
final class RelayVODAirPlayHandover {
    private enum State { case relay, swapping, receiver }

    /// How long the receiver gets to take the server's URL, counted from
    /// the swap. Device pass 2026-11-15: the takes that worked came 5.5 s
    /// (Apple TV, 17:32:54 to 17:32:59) and 5.7 s (Roku, 18:06:25 to
    /// 18:06:31) after the swap; they passed the 5 s live-tile window only
    /// because that window started when the confirm task first ran.
    static let confirmTimeout: TimeInterval = 15

    private weak var player: AVPlayer?
    private let upstream: URL
    private let relayURL: URL
    private let options: [String: Any]
    private let label: String
    private var state = State.relay
    private var externalObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    private var pickedObserver: NSObjectProtocol?
    /// The receiver did not take the item and this phone plays the relay
    /// item with external playback held off. Only a new pick (our route
    /// sheet, or a receiver newly on the route) tries the receiver again.
    private var heldLocal = false

    /// The tile rebinds its stall watchdog to the new item: suspended while
    /// the receiver plays (the local clock is not this phone's render).
    var onItemSwapped: ((_ item: AVPlayerItem, _ receiverPlays: Bool) -> Void)?
    /// The format gate refused the receiver: the tile records a user-style
    /// pause so no watchdog, retry, or nudge plays it again (owner
    /// 2026-11-16: the movie waits, paused, for the user's next move).
    var onRefused: (() -> Void)?
    /// Started with the route up: the tile did not start playback, so an
    /// accepted hand-off plays it on the receiver.
    private var playAfterDecision = false
    /// The start decision waits for the item to be ready, so the queued
    /// resume seek has landed before the position is read for the swap.
    private var startDecision = false

    init(player: AVPlayer, upstream: URL, relayURL: URL, options: [String: Any], label: String) {
        self.player = player
        self.upstream = upstream
        self.relayURL = relayURL
        self.options = options
        self.label = label
    }

    /// `startHeld`: the tile held external playback off because a known
    /// non-Apple receiver was already on the route at start; the decision
    /// (keep here with the message, or the usual swap) runs now.
    func attach(startHeld: Bool = false, playIfAccepted: Bool = true) {
        guard let player else { return }
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor in if active { self?.handover("the receiver took the item") } }
        }
        if startHeld {
            heldLocal = true
            playAfterDecision = playIfAccepted
            startDecision = true
            handover("an AirPlay route was already up at start")
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
                // receiver re-announced) would loop swap and fallback.
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

    func detach() {
        releaseHold()
        externalObservation = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let pickedObserver { NotificationCenter.default.removeObserver(pickedObserver) }
        routeObserver = nil
        pickedObserver = nil
        player = nil
    }

    private func handover(_ why: String) {
        guard state == .relay, let player, let old = player.currentItem,
              (old.asset as? AVURLAsset)?.url == relayURL else { return }
        state = .swapping
        // A known non-Apple receiver (Roku) cannot play every MP4 (device
        // pass 2026-11-16: HEVC + AC-3 froze on a music logo), so decide
        // before handing it the server's URL.
        let waitForReady = startDecision
        startDecision = false
        Task { @MainActor [weak self] in
            if waitForReady {
                let readyBy = Date().addingTimeInterval(10)
                while old.status == .unknown, Date() < readyBy {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let blocked = await VODAirPlayFormatGate.blocks(item: old, mkvRemux: false, label: self?.label ?? "")
            guard let self else { return }
            guard let player = self.player, player.currentItem === old else { self.state = .relay; return }
            let playAfter = self.playAfterDecision
            self.playAfterDecision = false
            if blocked {
                AirPlayTileDelivery.holdExternalOff(player)
                self.heldLocal = true
                self.state = .relay
                player.pause()
                self.onRefused?()
                debugLog(String(format: "[AVP-AIRPLAY] VOD %@: %@; kept on this device, paused at %.1fs, external playback held off until a receiver is picked again",
                                self.label, why, old.currentTime().seconds.isFinite ? old.currentTime().seconds : 0))
                return
            }
            self.swap(why, player: player, old: old, forcePlay: playAfter)
        }
    }

    private func swap(_ why: String, player: AVPlayer, old: AVPlayerItem, forcePlay: Bool = false) {
        let position = old.currentTime()
        let wasPlaying = forcePlay || player.timeControlStatus != .paused || player.rate != 0
        releaseHold()
        AirPlayMonitor.enableExternalPlayback(on: player)
        let item = makeItem(upstream, copying: old)
        player.replaceCurrentItem(with: item)
        if position.isValid, position.seconds > 0 {
            player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying { player.play() }
        onItemSwapped?(item, true)
        debugLog(String(format: "[AVP-AIRPLAY] VOD %@: %@; the receiver gets the server's URL without the key at %.1fs",
                        label, why, position.seconds.isFinite ? position.seconds : 0))
        // Counted from the swap, not from when this task first runs (device
        // pass 2026-11-15 17:35:25: the main thread was blocked 12.6 s right
        // after the swap, so a 5 s window measured from the task's start
        // ended 12.7 s after it).
        let deadline = Date().addingTimeInterval(Self.confirmTimeout)
        Task { @MainActor [weak self] in
            while Date() < deadline {
                guard let self, let player = self.player, player.currentItem === item else { return }
                if player.isExternalPlaybackActive { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self, let player = self.player, player.currentItem === item else { return }
            if player.isExternalPlaybackActive {
                self.state = .receiver
                debugLog("[AVP-AIRPLAY] VOD \(self.label): external playback active on the server's URL")
                self.watchReceiver(item)
                return
            }
            // The receiver never took it: back to the relay, played here.
            // External playback goes off first (device pass 2026-11-15
            // 17:35:38: with it still on and the Roku still the route, the
            // relay item went to the receiver, which cannot reach
            // 127.0.0.1, and the phone sat on a black 0:00).
            let here = item.currentTime()
            let resumeAt = (here.isValid && here.seconds > 0) ? here : position
            let playing = player.timeControlStatus != .paused || player.rate != 0
            AirPlayTileDelivery.holdExternalOff(player)
            self.heldLocal = true
            let back = self.makeItem(self.relayURL, copying: item)
            player.replaceCurrentItem(with: back)
            if resumeAt.isValid, resumeAt.seconds > 0 {
                player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }
            if playing { player.play() }
            self.state = .relay
            self.onItemSwapped?(back, false)
            debugLog("[AVP-AIRPLAY] VOD \(self.label): the receiver did not take the item within \(Int(Self.confirmTimeout)) s; back on the relay, playing on this device with external playback held off until a receiver is picked again")
        }
    }

    /// Ends the hold taken when the receiver did not take the item.
    private func releaseHold() {
        guard heldLocal else { return }
        heldLocal = false
        if let player { AirPlayTileDelivery.releaseExternalHold(player) }
    }

    private func makeItem(_ url: URL, copying old: AVPlayerItem) -> AVPlayerItem {
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = old.preferredForwardBufferDuration
        return item
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

    /// True when the item must stay on this device; shows the message.
    static func blocks(item: AVPlayerItem, mkvRemux: Bool, label: String) async -> Bool {
        var receiver = AirPlayReceiverResolver.shared.resolveNow() ?? .unknown
        if receiver.model == nil {
            receiver = await AirPlayReceiverResolver.shared.resolveForHandoff()
        }
        let (video, audio) = await codecs(of: item)
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
        debugLog("[AVP-AIRPLAY] VOD \(label): format gate receiver='\(receiver.name)' model=\(receiver.model ?? "unknown") apple=\(receiver.isApple) audioOnly=\(receiver.isAudioOnly) video=\(videoText) audio=\(audioText) path=\(path) -> \(blocked ? "kept on this device" : "hand-off as before")")
        if blocked {
            // Another version of the title may play there (owner
            // 2026-11-16); the fallback owns the message when it searches.
            if !AirPlayVersionFallback.shared.refused(receiver: receiver, label: label) {
                showMessage(receiver: receiver, label: label)
            }
        } else if knownNonApple {
            AirPlayVersionFallback.shared.accepted(label: label)
        }
        return blocked
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
    private var held = false
    private var deciding = false
    private var externalObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    private var pickedObserver: NSObjectProtocol?
    /// Same as RelayVODAirPlayHandover.onRefused: a user-style pause.
    var onRefused: (() -> Void)?

    init(player: AVPlayer, label: String) {
        self.player = player
        self.label = label
    }

    func attach() {
        guard let player else { return }
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
                // Held: only a newly picked receiver is worth another look.
                if self?.held == true, !newDevice { return }
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
        if AirPlayMonitor.shared.willServeReceiver { evaluate("an AirPlay route was already up") }
    }

    func detach() {
        if held, let player { AirPlayTileDelivery.releaseExternalHold(player) }
        held = false
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
            let blocked = await VODAirPlayFormatGate.blocks(item: item, mkvRemux: true, label: self?.label ?? "")
            guard let self else { return }
            self.deciding = false
            guard let player = self.player else { return }
            if blocked {
                AirPlayTileDelivery.holdExternalOff(player)
                self.held = true
                player.pause()
                self.onRefused?()
                let at = player.currentTime().seconds
                debugLog(String(format: "[AVP-AIRPLAY] VOD %@: %@; MKV remux kept on this device, paused at %.1fs, external playback held off until a receiver is picked again",
                                self.label, why, at.isFinite ? at : 0))
            } else if self.held {
                // A different receiver was picked: back to what
                // AirPlayMonitor does for every player.
                self.held = false
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
/// position for this AirPlay session only (the saved pick is untouched),
/// and the gate runs again on it. Nothing qualifies: the alert, paused.
@MainActor
final class AirPlayVersionFallback {
    static let shared = AirPlayVersionFallback()

    private static let perVersion: TimeInterval = 8
    private static let overall: TimeInterval = 25
    /// A switched copy the gate never ruled on (the tile took a path with
    /// no gate) does not keep the session alive forever.
    private static let sessionLifetime: TimeInterval = 120

    @MainActor
    private final class Session {
        let tileID: String
        let vodID: String
        let receiverName: String
        let displayName: String
        let label: String
        let started = Date()
        var deadline: Date
        var tried = Set<Int>()
        var switchedTo: Int?
        var task: Task<Void, Never>?
        var watcher: Task<Void, Never>?
        var cancelled = false

        init(tileID: String, vodID: String, receiver: AirPlayReceiver, label: String) {
            self.tileID = tileID
            self.vodID = vodID
            self.receiverName = receiver.name
            self.displayName = VODAirPlayFormatGate.receiverName(receiver)
            self.label = label
            self.deadline = Date().addingTimeInterval(AirPlayVersionFallback.overall)
        }
    }

    private var session: Session?

    /// The gate refused `receiver`. True when a search runs (or continues)
    /// and owns the message; false leaves today's alert to the gate.
    func refused(receiver: AirPlayReceiver, label: String) -> Bool {
        let store = MultiviewStore.shared
        guard let tile = store.vodSoloTile, tile.kind == .vod, let vodID = tile.vodID,
              tile.vodType == "movie" || tile.vodType == "episode",
              store.vodVersionOptions.count > 1 else {
            if let s = session { end(s, "the title has no other versions") }
            return false
        }
        if let s = session, s.tileID == tile.id, s.vodID == vodID, s.receiverName == receiver.name,
           Date().timeIntervalSince(s.started) < Self.sessionLifetime {
            // A second notification of the same pick while searching.
            if s.task != nil { return true }
            if let switched = s.switchedTo {
                // The copy picked from measurements was refused on its own
                // item: never retry it, go on with the rest.
                s.switchedTo = nil
                s.tried.insert(switched)
                s.deadline = Date().addingTimeInterval(Self.overall)
                debugLog("[AVP-AIRPLAY] VOD \(label): version fallback: relation \(switched) refused by the gate after the switch; trying the next version")
                run(s)
                return true
            }
        }
        if let s = session { end(s, "a new refusal replaced it") }
        let s = Session(tileID: tile.id, vodID: vodID, receiver: receiver, label: label)
        if let current = store.vodCurrentVersionID { s.tried.insert(current) }
        session = s
        let notice = "This version can't play on \(s.displayName) over AirPlay. Trying other versions of this title."
        debugLog("[AVP-AIRPLAY] VOD \(label): version fallback: versions found=\(store.vodVersionOptions.count) current=\(store.vodCurrentVersionID.map(String.init) ?? "auto"); notice shown")
        showNotice(notice)
        run(s)
        return true
    }

    /// The gate let an item through: a switched copy reached the receiver.
    func accepted(label: String) {
        guard let s = session, s.task == nil, let switched = s.switchedTo else { return }
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
        if session === s { session = nil }
    }

    /// Still the same title, tile, and receiver. Checked between steps and
    /// by the watcher, which cancels a probe in flight.
    private func stillValid(_ s: Session) -> Bool {
        guard !s.cancelled, session === s else { return false }
        let store = MultiviewStore.shared
        guard let tile = store.vodSoloTile, tile.id == s.tileID, tile.vodID == s.vodID else { return false }
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
            let providers = await Self.timed(min(Self.perVersion, s.deadline.timeIntervalSinceNow)) {
                try? await made.getMovieProviders(movieID: id)
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
            s.task = nil
            s.watcher?.cancel()
            s.watcher = nil
            debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: switching to relation \(option.id) at the same position (this AirPlay session only)")
            store.switchVODVersion(option, remember: false)
            return
        }
        guard stillValid(s), !Task.isCancelled else {
            end(s, "canceled (movie stopped, another route, or the receiver left)")
            return
        }
        let message = "No version of this title can play on \(s.displayName) over AirPlay."
        debugLog("[AVP-AIRPLAY] VOD \(s.label): version fallback: no version qualifies (\(s.tried.count) of \(options.count) tried); kept on this device, paused")
        end(s, nil)
        VODAirPlayFormatGate.showMessage(receiver: AirPlayReceiverResolver.shared.resolveNow() ?? .unknown,
                                         label: s.label, message: message)
    }

    /// The gate's own notice spot: the tile's top capsule.
    private func showNotice(_ text: String) {
        guard let progress = MultiviewStore.shared.audioProgressStore else { return }
        progress.liveResumeNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak progress] in
            if progress?.liveResumeNotice == text { progress?.liveResumeNotice = nil }
        }
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

    private struct Codecs: Sendable {
        let video: [String]
        let audio: [String]
    }

    /// Reads one copy's tracks the way the player would open it (no sign-in,
    /// as the receiver will fetch it). One provider connection; released by
    /// cancelLoading when the time box ends, and dropped on return.
    private static func probe(_ url: URL, headers: [String: String]) async -> Codecs? {
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
    private static func timed<T: Sendable>(_ seconds: TimeInterval,
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
