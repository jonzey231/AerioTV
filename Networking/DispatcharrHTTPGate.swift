//
//  DispatcharrHTTPGate.swift
//  Aerio
//
//  Applies `DispatcharrRequestGate` to every request `HTTPRouter` sends
//  (Android twin: core/network/DispatcharrGatePlugin.kt, 289112b4 and
//  fd145f3d):
//   - a request carrying an API key the server already rejected fails
//     locally with `DispatcharrGateError.keyRejected` and is never sent,
//     unless it is an explicit key check (`markKeyCheck`);
//   - while a server is paused after a 429, Dispatcharr API requests to it
//     fail locally with `DispatcharrGateError.rateLimited`;
//   - a 429 answer is logged (method, path, Retry-After, Server header,
//     first 200 bytes of the body; never a key or Authorization), pauses
//     the server, and is thrown as `rateLimited` so no caller turns it into
//     "HTTP 429" or "returned the web UI".
//  The login and token refresh endpoints are left to DispatcharrLoginGate.
//

import Foundation

enum DispatcharrHTTPGate {
    /// Marker header for an explicit key check (Test Connection on a form,
    /// the held-key re-check). Stripped before the request goes out.
    private static let keyCheckHeader = "X-Aerio-Key-Check"

    /// Let this request through the rejected-key gate on purpose.
    static func markKeyCheck(_ request: inout URLRequest) {
        request.setValue("1", forHTTPHeaderField: keyCheckHeader)
    }

    /// Gate `request` before it is sent. Returns the request to send (the
    /// marker header removed) or throws without touching the network.
    static func prepare(_ request: URLRequest) throws -> URLRequest {
        var req = request
        let bypass = req.value(forHTTPHeaderField: keyCheckHeader) != nil
        if bypass { req.setValue(nil, forHTTPHeaderField: keyCheckHeader) }
        guard let url = req.url else { return req }
        let method = req.httpMethod ?? "GET"
        let gate = DispatcharrRequestGate.shared
        // A key the silent re-login already replaced goes out as its successor.
        if let swapped = gate.rewritingReplacedKey(xApiKey: req.value(forHTTPHeaderField: "X-API-Key"),
                                                   authorization: req.value(forHTTPHeaderField: "Authorization")) {
            req.setValue(swapped.xApiKey, forHTTPHeaderField: "X-API-Key")
            req.setValue(swapped.authorization, forHTTPHeaderField: "Authorization")
        }
        if !bypass,
           let key = DispatcharrRequestGate.requestApiKey(xApiKey: req.value(forHTTPHeaderField: "X-API-Key"),
                                                          authorization: req.value(forHTTPHeaderField: "Authorization")),
           gate.isKeyRejected(key) {
            SkipLog.note("[AUTH] skipped \(method) \(url.path): this API key was rejected by the server; waiting for Edit Playlist",
                         bucket: "auth|\(DispatcharrRequestGate.serverKey(url.absoluteString))")
            throw DispatcharrGateError.keyRejected
        }
        if DispatcharrRequestGate.isPausedPath(url.path) {
            let server = DispatcharrRequestGate.serverKey(url.absoluteString)
            let left = gate.pausedSeconds(server)
            if left > 0 {
                SkipLog.note("[RATE] skipped \(method) \(url.path): server paused after a 429, \(left)s left",
                             bucket: "rate|\(server)")
                throw DispatcharrGateError.rateLimited(seconds: left, reason: gate.pausedReason(server))
            }
        }
        return req
    }

    /// Inspect the answer to a gated request. Throws `rateLimited` on a 429
    /// from a Dispatcharr API path (after pausing the server).
    static func inspect(_ request: URLRequest, response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 429,
              let url = request.url ?? http.url,
              DispatcharrRequestGate.isPausedPath(url.path) else { return }
        let raw = http.value(forHTTPHeaderField: "Retry-After")
        let secs = DispatcharrRequestGate.parseRetryAfter(raw)
        // The server's reason (stream-429-spec.md UPDATE): named in every 429 message.
        let reason: RateLimitReason = {
            if case .rateLimited(let r, _) = Dispatcharr429.classify(body: body, retryAfter: raw) { return r }
            return .other
        }()
        let serverHeader = http.value(forHTTPHeaderField: "Server")
        let snippet = body.map { String(decoding: $0.prefix(200), as: UTF8.self) } ?? ""
        let flat = snippet.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        debugLog("[RATE] HTTP 429 for \(request.httpMethod ?? "GET") \(url.path): Retry-After=\(raw ?? "none") "
                 + "(waiting \(secs)s) Server=\(serverHeader ?? "none") body=\(DebugLogger.sanitize(flat))")
        DispatcharrRequestGate.shared.pause(DispatcharrRequestGate.serverKey(url.absoluteString), seconds: secs, reason: reason)
        debugLog("[RATE] 429 reason=\(reason.rawValue) for \(request.httpMethod ?? "GET") \(url.path)")
        throw DispatcharrGateError.rateLimited(seconds: secs, reason: reason)
    }

    /// Stream and logo headers: a key the server already rejected is left
    /// off (each open or logo would otherwise count against its failed-key
    /// throttle). Every other header is kept.
    static func strippingRejectedKey(_ headers: [String: String]) -> [String: String] {
        let x = headers.first { $0.key.caseInsensitiveCompare("X-API-Key") == .orderedSame }?.value
        let a = headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
        guard let key = DispatcharrRequestGate.requestApiKey(xApiKey: x, authorization: a),
              DispatcharrRequestGate.shared.isKeyRejected(key) else { return headers }
        return headers.filter {
            $0.key.caseInsensitiveCompare("X-API-Key") != .orderedSame
                && $0.key.caseInsensitiveCompare("Authorization") != .orderedSame
        }
    }

    /// The 429 wait anywhere in `error`, including inside an `APIError.networkError`.
    static func rateLimitSeconds(in error: Error) -> Int? {
        rateLimit(in: error)?.seconds
    }

    /// The 429 wait and the server's reason anywhere in `error`, including
    /// inside an `APIError.networkError`.
    static func rateLimit(in error: Error) -> (seconds: Int, reason: RateLimitReason)? {
        if let limit = DispatcharrGateError.rateLimit(error) { return limit }
        if case APIError.networkError(let inner)? = error as? APIError {
            return DispatcharrGateError.rateLimit(inner)
        }
        return nil
    }

    /// True when `error` is one of the gate's own local failures.
    static func isGateStop(_ error: Error) -> Bool {
        error is DispatcharrGateError
    }

    /// Skipped-request logging, at most one line per bucket per 5 s, with a
    /// count of the lines folded into it. A paused server can have a
    /// hundred callers fail locally in a second (guide category fetches);
    /// one line says it as well as a hundred.
    private enum SkipLog {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var last: [String: (at: Date, folded: Int)] = [:]

        static func note(_ line: @autoclosure () -> String, bucket: String) {
            lock.lock()
            let nowDate = Date()
            if let prev = last[bucket], nowDate.timeIntervalSince(prev.at) < 5 {
                last[bucket] = (prev.at, prev.folded + 1)
                lock.unlock()
                return
            }
            let folded = last[bucket]?.folded ?? 0
            last[bucket] = (nowDate, 0)
            lock.unlock()
            debugLog(folded > 0 ? "\(line()) (+\(folded) more skipped)" : line())
        }
    }
}
