//
//  CastHLSProxyServer.swift
//  Aerio
//
//  Minimal HTTP/1.1 server for the phone-local cast HLS proxy (GH #33
//  web-receiver rework). NWListener, no dependencies: the only client is
//  the Cast device's Chromium page on the same LAN, fetching three
//  resource shapes:
//
//    /master.m3u8    variant wrapper (CODECS + CLOSED-CAPTIONS=NONE)
//    /live.m3u8      sliding-window live playlist
//    /init<G>.mp4    fMP4 init segment for ingest generation G
//    /seg<N>.m4s     CMAF media segment, monotonic sequence N
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

    private(set) var boundPort: UInt16 = 0

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
        let body: Data?
        let mime: String
        switch path {
        case "/master.m3u8":
            body = Data(store.masterPlaylistText().utf8)
            mime = Self.mimePlaylist
        case "/live.m3u8":
            body = Data(store.mediaPlaylistText().utf8)
            mime = Self.mimePlaylist
            if firstPlaylistServed.trySet() {
                log("receiver fetched the playlist for the first time (\(Self.host(of: peer)))")
            }
        case let p where p.hasPrefix("/init") && p.hasSuffix(".mp4"):
            let gen = Int(p.dropFirst(5).dropLast(4))
            body = gen.flatMap { store.initSegment(generation: $0) }
            mime = Self.mimeMP4
        case let p where p.hasPrefix("/seg") && p.hasSuffix(".m4s"):
            let seq = Int(p.dropFirst(4).dropLast(4))
            // Concurrent serve queue, so holding the live-edge fetch here
            // blocks nobody else.
            body = seq.flatMap { store.awaitSegment(seq: $0) }
            mime = Self.mimeSegment
        default:
            body = nil
            mime = "text/plain"
        }
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

    private static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "unknown"
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
