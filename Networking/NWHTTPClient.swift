//
//  NWHTTPClient.swift
//  Aerio
//
//  v1.6.10 — Network.framework-based HTTP/1.1 client used to bypass iOS's
//  built-in HSTS preload list for IPTV reseller domains on TLDs Google
//  baked into Chromium (`.app`, `.dev`, `.page`, `.new`, …). Apple's ATS
//  posture only governs URLSession / NSURLSession; CFNetwork and the
//  Network framework are explicitly out of scope per Apple DTS guidance.
//  See https://developer.apple.com/forums/thread/100936 (Quinn).
//
//  Why this exists:
//    Multiple users run Xtream / Dispatcharr panels on domains
//    under HSTS-preloaded TLDs (`http://example.app:8080`).
//    URLSession refuses these regardless of `NSAllowsArbitraryLoads`
//    because HSTS preload lives one layer below ATS in URLSession's
//    own resolver. Other clients handle the URL format because they
//    don't use URLSession for that fetch — they go straight to BSD
//    sockets or, on Apple platforms, NWConnection.
//
//  Design constraints:
//    • Drop-in `data(for:)` / `data(from:)` API matching URLSession's
//      shape so the existing `loggedData` helpers in StreamingAPIs.swift
//      can swap dispatcher with a one-line change.
//    • HTTP/1.1 only — sufficient for every Xtream-Codes / Dispatcharr
//      panel we've seen. Servers that strictly require HTTP/2 are
//      vanishingly rare in this market and overwhelmingly serve TLS
//      (which URLSession handles natively, no NWConnection needed).
//    • Supports plain HTTP and TLS. When TLS is requested the
//      framework's default options apply — full cert validation; we
//      don't pin or bypass.
//    • Follows 301/302/303/307/308 redirects up to 5. Most panels
//      chain through one or two reverse-proxy 302s before delivering
//      JSON.
//    • Decodes both Content-Length-framed and chunked transfer
//      encoding bodies. Modern panels behind nginx default to
//      chunked; legacy panels still use Content-Length.
//    • Caps body at 50 MB. Large XMLTV EPG payloads for big
//      providers can approach that — anything bigger is almost
//      certainly a misconfiguration and we'd rather error than
//      OOM the device.
//

import Foundation
import Network

/// Errors specific to the NWConnection HTTP path. Callers bridge to
/// APIError at the call site; we keep this layer pure so it can be
/// reused outside StreamingAPIs.
enum NWHTTPError: LocalizedError {
    case invalidURL
    case connectionFailed(Error)
    case timedOut
    case malformedResponse(String)
    case bodyTooLarge(Int)
    case tooManyRedirects
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:                 return "Invalid URL"
        case .connectionFailed(let e):    return "Connection failed: \(e.localizedDescription)"
        case .timedOut:                   return "Connection timed out"
        case .malformedResponse(let s):   return "Malformed HTTP response: \(s)"
        case .bodyTooLarge(let n):        return "Response body too large (\(n) bytes)"
        case .tooManyRedirects:           return "Too many redirects"
        case .cancelled:                  return "Request cancelled"
        }
    }
}

/// HTTP/1.1 client built on `NWConnection`. Public surface is shaped
/// like `URLSession.data(...)` so call sites in StreamingAPIs can swap
/// dispatcher without touching their own logging / timing logic.
enum NWHTTPClient {

    /// Per-request soft deadline. Mirrors URLSessionConfiguration's
    /// `timeoutIntervalForRequest = 20` used by the Xtream/Dispatcharr
    /// shared session — same UX the user is used to.
    static let defaultTimeout: TimeInterval = 20

    /// Hard cap on response body size. v1.6.10 raised from 50 MB to
    /// 200 MB after Xtream `get_series` payloads from large resellers
    /// were observed at ~52 MB (full-library all-fields response).
    /// 200 MB still protects the device from a runaway chunked stream
    /// while comfortably covering the worst-case Xtream / XMLTV
    /// payloads on consumer hardware.
    static let maxBodyBytes: Int = 200 * 1024 * 1024

    static let maxRedirects: Int = 5

    // MARK: - Public API (URLSession-shaped)

    static func data(from url: URL,
                     timeout: TimeInterval = defaultTimeout) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await data(for: req, timeout: timeout)
    }

    static func data(for request: URLRequest,
                     timeout: TimeInterval = defaultTimeout) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw NWHTTPError.invalidURL }
        return try await perform(request: request,
                                 currentURL: url,
                                 redirectsLeft: maxRedirects,
                                 timeout: timeout)
    }

    // MARK: - Core exchange

    private static func perform(request originalRequest: URLRequest,
                                currentURL: URL,
                                redirectsLeft: Int,
                                timeout: TimeInterval) async throws -> (Data, URLResponse) {
        guard let scheme = currentURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = currentURL.host, !host.isEmpty else {
            throw NWHTTPError.invalidURL
        }
        let port = UInt16(currentURL.port ?? (scheme == "https" ? 443 : 80))
        let useTLS = (scheme == "https")

        let requestBytes = buildRequestBytes(method: originalRequest.httpMethod ?? "GET",
                                             url: currentURL,
                                             headers: originalRequest.allHTTPHeaderFields ?? [:],
                                             body: originalRequest.httpBody)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? (useTLS ? .https : .http)
        )

        // Build TCP options explicitly. We deliberately leave
        // `enableFastOpen` at its default (false) — TFO requires both
        // client and server kernel support and intermediate firewalls
        // sometimes drop SYN+data packets, leading to silent stalls
        // that look exactly like the "connection timed out" symptom.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(timeout)
        tcpOptions.noDelay = true   // small request, want it on the wire now

        let parameters: NWParameters
        if useTLS {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }

        debugLog("NWHTTP → \(scheme)://\(host):\(port)\(currentURL.path) (TLS=\(useTLS), redirects-left=\(redirectsLeft))")

        // Dedicated background queue per request. Keeps NWConnection
        // callbacks off .main and prevents one slow request from
        // serializing behind another.
        let queue = DispatchQueue(label: "app.molinete.aerio.nwhttp", qos: .userInitiated)

        let connection = NWConnection(to: endpoint, using: parameters)

        let (data, http): (Data, HTTPURLResponse) = try await withTaskCancellationHandler {
            try await runExchange(connection: connection,
                                  queue: queue,
                                  url: currentURL,
                                  requestBytes: requestBytes,
                                  timeout: timeout)
        } onCancel: {
            connection.cancel()
        }

        // Handle redirects in the same fashion URLSession does by default.
        let status = http.statusCode
        if (300...399).contains(status),
           let location = http.value(forHTTPHeaderField: "Location"),
           let nextURL = redirectURL(from: location, base: currentURL) {
            guard redirectsLeft > 0 else { throw NWHTTPError.tooManyRedirects }
            // Per RFC 7231: 301/302/303 may swap method to GET when the
            // original was non-GET/HEAD. 307/308 preserve method+body.
            // Mirrors URLSession's default behavior.
            var nextRequest = originalRequest
            nextRequest.url = nextURL
            if status == 301 || status == 302 || status == 303 {
                let method = (nextRequest.httpMethod ?? "GET").uppercased()
                if method != "GET" && method != "HEAD" {
                    nextRequest.httpMethod = "GET"
                    nextRequest.httpBody = nil
                }
            }
            return try await perform(request: nextRequest,
                                     currentURL: nextURL,
                                     redirectsLeft: redirectsLeft - 1,
                                     timeout: timeout)
        }

        return (data, http)
    }

    /// One full TCP/TLS exchange: open, send request, read headers,
    /// drain body, close. Returns body + synthesized HTTPURLResponse so
    /// callers see the same shape they'd get from URLSession.
    private static func runExchange(connection: NWConnection,
                                    queue: DispatchQueue,
                                    url: URL,
                                    requestBytes: Data,
                                    timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let state = State()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            // Soft deadline. If the exchange doesn't complete within
            // `timeout` seconds, cancel — the receive loop sees the
            // cancellation and resumes with .timedOut.
            let timeoutTask = Task { [weak connection] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled {
                    debugLog("NWHTTP \(url.host ?? "?") TIMEOUT → cancelling (state.statusLineParsed=\(state.statusLineParsed), bodyBuffer=\(state.bodyBuffer.count) bytes)")
                    connection?.cancel()
                }
            }

            // `@Sendable` so we can pass it into NWConnection's
            // background-queue callbacks under Swift 6 strict
            // concurrency. Captures: `state` (@unchecked Sendable
            // class), `cont` (Sendable), `timeoutTask` (Sendable),
            // `connection` (Sendable). All safe.
            @Sendable func resumeOnce(_ result: Result<(Data, HTTPURLResponse), Error>) {
                queue.async {
                    if state.resumed { return }
                    state.resumed = true
                    timeoutTask.cancel()
                    connection.cancel()
                    cont.resume(with: result)
                }
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .setup:
                    debugLog("NWHTTP \(url.host ?? "?") state=setup")
                case .preparing:
                    debugLog("NWHTTP \(url.host ?? "?") state=preparing (DNS/TCP handshake)")
                case .ready:
                    debugLog("NWHTTP \(url.host ?? "?") state=ready → sending \(requestBytes.count) bytes")
                    connection.send(content: requestBytes, completion: .contentProcessed { error in
                        if let error {
                            debugLog("NWHTTP \(url.host ?? "?") send FAILED: \(error)")
                            resumeOnce(.failure(NWHTTPError.connectionFailed(error)))
                            return
                        }
                        debugLog("NWHTTP \(url.host ?? "?") send OK → receive loop start")
                        receiveMore(connection: connection,
                                    queue: queue,
                                    url: url,
                                    state: state,
                                    resumeOnce: resumeOnce)
                    })
                case .failed(let error):
                    debugLog("NWHTTP \(url.host ?? "?") state=failed: \(error)")
                    resumeOnce(.failure(NWHTTPError.connectionFailed(error)))
                case .cancelled:
                    // .cancelled fires both on success-after-finish and
                    // on timeout-driven cancel. resumeOnce's `resumed`
                    // guard makes the success path a no-op; only the
                    // timeout reaches the .timedOut resume below.
                    debugLog("NWHTTP \(url.host ?? "?") state=cancelled (resumed=\(state.resumed))")
                    if !state.resumed {
                        resumeOnce(.failure(NWHTTPError.timedOut))
                    }
                case .waiting(let error):
                    // .waiting fires when the connection can't open
                    // immediately — DNS still in flight, no route, etc.
                    // Most reasons resolve themselves; surface as a
                    // failure only after a few seconds so we don't kill
                    // a connection that would have worked. The 20s soft
                    // timeout still bounds the worst case.
                    debugLog("NWHTTP \(url.host ?? "?") state=waiting: \(error)")
                @unknown default:
                    debugLog("NWHTTP \(url.host ?? "?") state=unknown")
                }
            }

            connection.start(queue: queue)
        }
    }

    /// Pumps `connection.receive` in a loop. Parses headers first, then
    /// dispatches body bytes to the framing-appropriate decoder. Calls
    /// `resumeOnce` with success once the body is fully received.
    private static func receiveMore(connection: NWConnection,
                                    queue: DispatchQueue,
                                    url: URL,
                                    state: State,
                                    resumeOnce: @escaping @Sendable (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        // 64 KB receive chunks balance syscall overhead with memory.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                debugLog("NWHTTP \(url.host ?? "?") receive FAILED: \(error)")
                resumeOnce(.failure(NWHTTPError.connectionFailed(error)))
                return
            }

            if let data, !data.isEmpty {
                // Only log the very first chunk (pre-header-parse).
                // Logging every 64 KB chunk on a 50 MB body produces
                // ~800 lines of console spam per request. The DONE
                // line at the end carries the final body size, which
                // is the only number we actually need for triage.
                if !state.statusLineParsed {
                    debugLog("NWHTTP \(url.host ?? "?") recv \(data.count) bytes (isComplete=\(isComplete), parsing headers)")
                }
                if !state.statusLineParsed {
                    state.headerBuffer.append(data)
                    if let headerEnd = rangeOfDoubleCRLF(in: state.headerBuffer) {
                        let headerPart = state.headerBuffer.prefix(headerEnd.lowerBound)
                        let bodyPart   = state.headerBuffer.suffix(from: headerEnd.upperBound)
                        do {
                            try parseHead(into: state, headerBytes: Data(headerPart))
                            debugLog("NWHTTP \(url.host ?? "?") parsed status=\(state.statusCode) framing=\(state.framing)")
                        } catch {
                            debugLog("NWHTTP \(url.host ?? "?") parseHead FAILED: \(error)")
                            resumeOnce(.failure(error))
                            return
                        }
                        state.headerBuffer.removeAll(keepingCapacity: false)
                        if !bodyPart.isEmpty {
                            do {
                                if try ingestBody(into: state, bytes: Data(bodyPart)) {
                                    finish(state: state, url: url, resumeOnce: resumeOnce)
                                    return
                                }
                            } catch {
                                resumeOnce(.failure(error))
                                return
                            }
                        }
                    }
                } else {
                    do {
                        if try ingestBody(into: state, bytes: data) {
                            finish(state: state, url: url, resumeOnce: resumeOnce)
                            return
                        }
                    } catch {
                        resumeOnce(.failure(error))
                        return
                    }
                }
            }

            if isComplete {
                // Server closed the connection. If body framing was
                // .untilClose we now have the whole payload; if it was
                // .contentLength we'd already have finished above; if
                // .chunked we expect a 0-length chunk before close, but
                // some panels close abruptly on the terminator — accept
                // what we have.
                finish(state: state, url: url, resumeOnce: resumeOnce)
                return
            }

            // Keep reading.
            receiveMore(connection: connection, queue: queue, url: url, state: state, resumeOnce: resumeOnce)
        }
    }

    private static func finish(state: State,
                               url: URL,
                               resumeOnce: @escaping @Sendable (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        guard state.statusLineParsed else {
            debugLog("NWHTTP \(url.host ?? "?") finish: connection closed before status line (header buffer=\(state.headerBuffer.count) bytes)")
            resumeOnce(.failure(NWHTTPError.malformedResponse("connection closed before status line")))
            return
        }
        guard let response = HTTPURLResponse(url: url,
                                             statusCode: state.statusCode,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: state.headerFields) else {
            resumeOnce(.failure(NWHTTPError.malformedResponse("could not synthesize HTTPURLResponse")))
            return
        }
        debugLog("NWHTTP \(url.host ?? "?") DONE status=\(state.statusCode) body=\(state.bodyBuffer.count) bytes")
        resumeOnce(.success((state.bodyBuffer, response)))
    }

    // MARK: - Wire-format helpers

    private static func buildRequestBytes(method: String,
                                          url: URL,
                                          headers: [String: String],
                                          body: Data?) -> Data {
        // Path + query for the request line. NWConnection talks to the
        // origin server directly, so we use the path-only form (not
        // the absolute form a forward proxy would expect).
        let pathPart: String = {
            var pq = url.path.isEmpty ? "/" : url.path
            if let q = url.query, !q.isEmpty { pq += "?" + q }
            return pq
        }()

        var lines: [String] = []
        lines.append("\(method) \(pathPart) HTTP/1.1")

        // Host header — required by RFC, and reverse proxies route on
        // it. Include port when non-default.
        let hostHeader: String = {
            guard let host = url.host else { return "" }
            if let port = url.port {
                let scheme = url.scheme?.lowercased() ?? "http"
                let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
                return isDefault ? host : "\(host):\(port)"
            }
            return host
        }()
        lines.append("Host: \(hostHeader)")

        // Sensible defaults; user-supplied headers override.
        var merged: [String: String] = [
            "User-Agent": userAgent(),
            "Accept": "*/*",
            "Accept-Encoding": "identity",   // no gzip — keeps decoder simple
            "Connection": "close"            // one-shot per request
        ]
        for (k, v) in headers { merged[k] = v }

        // If a body is present and Content-Length wasn't set, add it.
        if let body, merged["Content-Length"] == nil {
            merged["Content-Length"] = String(body.count)
        }

        for (k, v) in merged {
            lines.append("\(k): \(v)")
        }
        let head = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }

    /// Locate `\r\n\r\n` separating headers from body.
    private static func rangeOfDoubleCRLF(in data: Data) -> Range<Data.Index>? {
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        return data.firstRange(of: needle)
    }

    /// Parses the status line + header lines into the state box.
    /// `headerBytes` does not include the terminating `\r\n\r\n`.
    private static func parseHead(into state: State, headerBytes: Data) throws {
        guard let text = String(data: headerBytes, encoding: .isoLatin1) else {
            throw NWHTTPError.malformedResponse("non-ascii header")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw NWHTTPError.malformedResponse("empty header section")
        }
        // "HTTP/1.1 200 OK"
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2,
              let code = Int(statusParts[1]) else {
            throw NWHTTPError.malformedResponse("bad status line: \(statusLine)")
        }
        state.statusCode = code
        state.statusReason = statusParts.count >= 3 ? String(statusParts[2]) : ""

        var headers: [String: String] = [:]
        for raw in lines.dropFirst() {
            if raw.isEmpty { continue }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Combine duplicate headers (e.g. multi-Set-Cookie) so we
            // don't drop information. Costs nothing for the panels we
            // talk to, and matches HTTPURLResponse behaviour.
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        state.headerFields = headers
        state.statusLineParsed = true

        // Decide framing. RFC 7230 §3.3: Transfer-Encoding wins over
        // Content-Length when both are present.
        if let te = headerValue(headers, "Transfer-Encoding")?.lowercased(), te.contains("chunked") {
            state.framing = .chunked
            state.inChunkSize = true
            state.chunkedRemaining = 0
        } else if let cl = headerValue(headers, "Content-Length"), let n = Int(cl) {
            state.framing = .contentLength(n)
        } else {
            // 1xx/204/304 carry no body. Anything else without framing
            // is "until close" per HTTP/1.1 — sometimes seen on legacy
            // panels.
            if state.statusCode == 204 || state.statusCode == 304 || (100...199).contains(state.statusCode) {
                state.framing = .contentLength(0)
            } else {
                state.framing = .untilClose
            }
        }
    }

    private static func headerValue(_ headers: [String: String], _ name: String) -> String? {
        if let v = headers[name] { return v }
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower { return v }
        return nil
    }

    /// Feeds `bytes` into the body buffer per current framing. Returns
    /// `true` when the body is fully received and the caller should
    /// finalize the response.
    @discardableResult
    private static func ingestBody(into state: State, bytes: Data) throws -> Bool {
        switch state.framing {
        case .contentLength(let total):
            try appendBody(state: state, bytes: bytes)
            return state.bodyBuffer.count >= total

        case .untilClose:
            try appendBody(state: state, bytes: bytes)
            return false

        case .chunked:
            try ingestChunked(into: state, bytes: bytes)
            // The chunked decoder marks completion by rewriting framing
            // to .contentLength(bodyBuffer.count) once it sees the
            // 0-length terminator chunk.
            if case .contentLength(let total) = state.framing {
                return state.bodyBuffer.count >= total
            }
            return false

        case .unknown:
            throw NWHTTPError.malformedResponse("body before head")
        }
    }

    private static func appendBody(state: State, bytes: Data) throws {
        if state.bodyBuffer.count + bytes.count > maxBodyBytes {
            throw NWHTTPError.bodyTooLarge(state.bodyBuffer.count + bytes.count)
        }
        state.bodyBuffer.append(bytes)
    }

    /// Streaming chunked-transfer-encoding decoder. `bytes` is the next
    /// arbitrary slice of wire bytes; we drain through `chunkBuffer`
    /// alternating between size-line and chunk-data states.
    private static func ingestChunked(into state: State, bytes: Data) throws {
        state.chunkBuffer.append(bytes)

        while !state.chunkBuffer.isEmpty {
            if state.inChunkSize {
                // Need the next \r\n to read the chunk size.
                let crlf: [UInt8] = [0x0D, 0x0A]
                guard let r = state.chunkBuffer.firstRange(of: crlf) else { return }
                let lineData = state.chunkBuffer.prefix(r.lowerBound)
                guard let line = String(data: Data(lineData), encoding: .isoLatin1) else {
                    throw NWHTTPError.malformedResponse("non-ascii chunk size line")
                }
                // Strip optional chunk extensions (";name=val")
                let sizePart = line.split(separator: ";").first.map(String.init) ?? line
                guard let size = Int(sizePart.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    throw NWHTTPError.malformedResponse("bad chunk size: \(line)")
                }
                state.chunkBuffer.removeSubrange(0..<r.upperBound)
                if size == 0 {
                    // Terminator chunk. Skip optional trailers up to the
                    // next \r\n\r\n; we don't surface trailers to callers.
                    if let endRange = rangeOfDoubleCRLF(in: state.chunkBuffer) {
                        state.chunkBuffer.removeSubrange(0..<endRange.upperBound)
                    }
                    // Mark "done" by rewriting framing to a fixed length
                    // matching what we already buffered. Caller's
                    // bodyBuffer.count >= total check returns true.
                    state.framing = .contentLength(state.bodyBuffer.count)
                    return
                }
                state.chunkedRemaining = size
                state.inChunkSize = false
            } else {
                // Inside a chunk's data section. Consume up to
                // `chunkedRemaining`, then expect a trailing \r\n.
                if state.chunkedRemaining > 0 {
                    let take = min(state.chunkedRemaining, state.chunkBuffer.count)
                    if take == 0 { return }
                    let slice = state.chunkBuffer.prefix(take)
                    try appendBody(state: state, bytes: Data(slice))
                    state.chunkBuffer.removeSubrange(0..<take)
                    state.chunkedRemaining -= take
                    if state.chunkedRemaining > 0 { return }
                }
                // chunkedRemaining is 0 — drain the trailing \r\n.
                if state.chunkBuffer.count < 2 { return }
                let crlf = state.chunkBuffer.prefix(2)
                guard crlf == Data([0x0D, 0x0A]) else {
                    throw NWHTTPError.malformedResponse("missing chunk CRLF")
                }
                state.chunkBuffer.removeSubrange(0..<2)
                state.inChunkSize = true
            }
        }
    }

    // MARK: - Redirects

    private static func redirectURL(from location: String, base: URL) -> URL? {
        if let abs = URL(string: location), abs.scheme != nil { return abs }
        return URL(string: location, relativeTo: base)?.absoluteURL
    }

    // MARK: - User agent

    /// Match the URLSession default UA shape so reseller WAFs don't
    /// fingerprint us as a bot. Some panels gate on UA presence.
    private static func userAgent() -> String {
        let bundle = Bundle.main
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Aerio"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build   = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        #if os(tvOS)
        let platform = "tvOS"
        #elseif os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "Apple"
        #endif
        return "\(appName)/\(version).\(build) (\(platform))"
    }

    // MARK: - State box

    /// Reference type holding per-request mutable state across async
    /// callbacks. Class (not struct) so the receive callbacks can
    /// mutate without value-semantics gymnastics.
    ///
    /// `@unchecked Sendable`: we hand-coordinate access through the
    /// per-request `DispatchQueue` (every state mutation either runs
    /// inside an `NWConnection` callback — which the framework
    /// serializes on that queue — or inside our own `queue.async`
    /// block in `resumeOnce`). The compiler can't verify this, but
    /// it's a stronger guarantee than typical Sendable structs.
    fileprivate final class State: @unchecked Sendable {
        var resumed = false
        var headerBuffer = Data()
        var bodyBuffer = Data()
        var statusLineParsed = false
        var statusCode: Int = 0
        var statusReason: String = ""
        var headerFields: [String: String] = [:]
        enum BodyFraming { case unknown, contentLength(Int), chunked, untilClose }
        var framing: BodyFraming = .unknown
        // Chunked decoder
        var chunkBuffer = Data()
        var chunkedRemaining: Int = 0
        var inChunkSize = true
    }
}
