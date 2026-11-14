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

