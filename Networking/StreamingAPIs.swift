import Foundation

// MARK: - Stream Format Classification
/// Classifies a stream URL as HLS, MPEG-TS, or unknown to decide which player engine to use.
enum StreamFormat {
    case hls
    case mpegTS
    case unknown
}

/// Inspects a URL's path/extension to determine the likely stream format.
/// Conservative: only classifies as HLS when the extension is literally `.m3u8`
/// or the URL explicitly requests Dispatcharr's HLS output. Path-based
/// heuristics (e.g. "/proxy/hls/") are unreliable because many servers
/// return raw MPEG-TS from those endpoints despite the name.
func classifyStreamURL(_ url: URL) -> StreamFormat {
    let ext  = url.pathExtension.lowercased()
    // HLS — only trust the file extension, not the path
    if ext == "m3u8" {
        return .hls
    }
    // TEST (branch test/avplayer-hls-engine): Dispatcharr's native HLS
    // output is requested via an explicit query parameter; only the app
    // itself appends it (after a capability probe), so it is as
    // trustworthy as the extension.
    if let query = url.query,
       query.contains("output_format=hls") || query.contains("output=hls") {
        return .hls
    }
    // MPEG-TS
    if ext == "ts" || url.path.lowercased().contains("/proxy/ts/") {
        return .mpegTS
    }
    return .unknown
}

/// TEST (branch test/avplayer-hls-engine): the same URL rewritten to
/// request Dispatcharr's native server-side HLS output. REPLACES any
/// existing output_format/output value: the app bakes
/// `?output_format=mpegts` into Dispatcharr stream URLs for the mpv
/// path, and an earlier defer-to-existing guard here made the probe
/// ask for TS, caching "no native HLS" against capable servers.
func appendingHLSOutputFormat(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url
    }
    var items = (components.queryItems ?? []).filter {
        $0.name != "output_format" && $0.name != "output"
    }
    items.append(URLQueryItem(name: "output_format", value: "hls"))
    components.queryItems = items
    return components.url ?? url
}

/// GH #33 basic cast: Dispatcharr's fMP4 output profile id that transcodes to
/// H.264 + AAC ("Web Player (AAC Audio)" on the user's server). The Cast web
/// receiver can only DECODE AAC-family audio (AC-3 is passthrough-only and
/// silent on most devices), so the cast URL must pin this profile.
/// TODO(shared with Android): auto-detect the AAC profile id per server via
/// /hdhr/output_profile/<id>/lineup.json instead of hardcoding 2.
let castWebOutputProfileID = "2"

/// GH #33 basic cast: rewrite a Dispatcharr LIVE proxy URL into the directly
/// playable form the custom web receiver (app 76DC0564) loads:
/// `?output_format=fmp4&output_profile=2` = fragmented MP4 (MSE-valid) with
/// H.264+AAC. Returns nil for anything that is not a Dispatcharr /proxy/ts/
/// stream (XC / M3U direct sources have no server-side repackager, so they
/// cannot be basic-cast; callers hide the cast affordance instead of loading
/// an unplayable URL -- the Android review found that black-screens the TV).
func webCastStreamURL(_ url: URL?) -> URL? {
    guard let url, url.path.contains("/proxy/ts/stream/"),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    var items = (components.queryItems ?? []).filter {
        $0.name != "output_format" && $0.name != "output" && $0.name != "output_profile"
    }
    items.append(URLQueryItem(name: "output_format", value: "fmp4"))
    items.append(URLQueryItem(name: "output_profile", value: castWebOutputProfileID))
    components.queryItems = items
    return components.url
}

/// TEST (branch test/avplayer-hls-engine): per-host capability cache for
/// Dispatcharr's native HLS output. Probes a real stream URL with
/// `output_format=hls` WITHOUT following redirects: a 302 means the
/// server segments HLS natively (the new feature), a 200 with raw TS
/// means an older server that ignored the parameter. Results persist
/// across launches (the answer rarely changes) and are re-verified in
/// the background once per session, so the first-ever play on a server
/// uses the fallback path and every later session routes directly.
@MainActor
final class HLSCapabilityStore: NSObject {
    static let shared = HLSCapabilityStore()

    private static let defaultsKey = "playback.hlsCapableHosts"
    private var capable: Set<String>
    private var probedThisSession: Set<String> = []
    private var inFlight: Set<String> = []

    private override init() {
        capable = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
        super.init()
    }

    private func hostKey(_ url: URL) -> String? {
        guard let host = url.host else { return nil }
        return "\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    func isCapable(_ url: URL) -> Bool {
        guard let key = hostKey(url) else { return false }
        return capable.contains(key)
    }

    /// Fire-and-forget probe using the channel URL the user just played.
    /// Cheap on the server: the connection is cancelled at the response
    /// HEADERS (a non-capable server would otherwise stream endless TS),
    /// and any briefly-started channel is reaped by the ghost window.
    func probeIfNeeded(streamURL: URL, headers: [String: String]) {
        guard let key = hostKey(streamURL),
              !probedThisSession.contains(key),
              !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let probeURL = appendingHLSOutputFormat(streamURL)
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = 6
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let delegate = ProbeDelegate { [weak self] status in
            Task { @MainActor [weak self] in
                self?.record(status: status, for: key)
            }
        }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: delegate,
                                 delegateQueue: nil)
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()
    }

    /// Thread-safe one-shot holder for the blocking probe's status. The
    /// semaphore orders the background write before the main-thread read;
    /// the lock guards against a late/duplicate delegate callback.
    private final class ProbeStatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func store(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func load() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Synchronous, time-boxed capability probe for the engine-lock path.
    /// `resolveEngine` locks the session engine synchronously (it runs
    /// inside `enterMultiview`), so it must know HLS capability BEFORE it
    /// returns. The async `probeIfNeeded` cannot do that: it fires the
    /// probe and reads the cache the same instant, so the first play of an
    /// HLS-capable server is decided from an empty cache and routes to the
    /// remux path (which dead-ends on HEVC) instead of direct AVPlayer.
    /// This variant returns instantly when the host is already cached or
    /// was probed this session (no network, no block); otherwise it runs
    /// the SAME probe and waits up to `timeout` for the answer. The
    /// semaphore is signalled from the URLSession's OWN background delegate
    /// queue, never `@MainActor`, so a blocked main thread cannot starve
    /// the signal: no deadlock. A timeout leaves the host un-probed so a
    /// later play retries, and never blocks beyond the cap. On a LAN server
    /// the 302 returns in milliseconds.
    func probeBlocking(streamURL: URL, headers: [String: String], timeout: TimeInterval = 1.5) -> Bool {
        guard let key = hostKey(streamURL) else { return false }
        if probedThisSession.contains(key) || capable.contains(key) {
            return capable.contains(key)
        }
        guard !inFlight.contains(key) else { return capable.contains(key) }
        inFlight.insert(key)

        let probeURL = appendingHLSOutputFormat(streamURL)
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let sem = DispatchSemaphore(value: 0)
        let box = ProbeStatusBox()
        let delegate = ProbeDelegate { status in
            box.store(status)
            sem.signal()
        }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: delegate,
                                 delegateQueue: nil)
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()

        let waited = sem.wait(timeout: .now() + timeout)
        let status = box.load()
        if waited == .success, status != 0 {
            record(status: status, for: key)   // real answer: cache + persist
        } else {
            // Timed out / no answer: do not poison the session; allow a
            // later play to retry. A late delegate callback only touches
            // the local box/semaphore, never the store's state.
            inFlight.remove(key)
        }
        return capable.contains(key)
    }

    private func record(status: Int, for key: String) {
        inFlight.remove(key)
        probedThisSession.insert(key)
        let wasCapable = capable.contains(key)
        if status == 302 || status == 301 {
            capable.insert(key)
        } else if status != 0 {
            // Definitive non-redirect answer: not capable.
            capable.remove(key)
        }
        // status == 0 (network error): keep the cached answer.
        if capable.contains(key) != wasCapable {
            UserDefaults.standard.set(Array(capable), forKey: Self.defaultsKey)
        }
        debugLog("[HLS-CAP] \(key) -> \(capable.contains(key) ? "HLS capable" : "no native HLS") (status \(status))")
    }

    /// Captures the FIRST status the server gives and stops there:
    /// refuses the redirect (so a capable server's 302 is observable)
    /// and cancels the body (so a non-capable server's endless TS
    /// stream never flows). Reports exactly once.
    ///
    /// @unchecked Sendable: URLSession delegates must be Sendable on
    /// current SDKs; `reported` is only touched from the session's
    /// serial delegate queue, so access is serialized by construction.
    private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let onStatus: @Sendable (Int) -> Void
        private var reported = false
        init(onStatus: @escaping @Sendable (Int) -> Void) { self.onStatus = onStatus }

        private func report(_ status: Int) {
            guard !reported else { return }
            reported = true
            onStatus(status)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            report(response.statusCode)
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            report((response as? HTTPURLResponse)?.statusCode ?? 0)
            completionHandler(.cancel)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            // Network failure before any response: report unknown.
            report(0)
        }
    }
}

// MARK: - Shared Date Parser
/// Cached Xtream date parser — avoids creating a DateFormatter per call.
enum XtreamDateParser {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func parse(_ s: String) -> Date? {
        if let ts = Double(s) {
            return ts > 2_000_000_000_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }
        return formatter.date(from: s)
    }
}

// MARK: - API Error
enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case decodingError(Error)
    case networkError(Error)
    case invalidResponse
    case timeout
    /// A 2xx that carried nothing. Distinct from `.invalidResponse` because
    /// the request succeeded at the HTTP level and the failure is entirely on
    /// the server side, so the advice the user needs is different.
    ///
    /// Discord (di5cord20 + Matschi, 2026-08-09): a tuliprox Xtream Codes
    /// playlist connects, verifies, saves and then shows ZERO channels, on
    /// two different boxes, surviving force-close / cache clear / reboot,
    /// while the same credentials load fully elsewhere. tuliprox answers ANY
    /// m3u failure with an empty 204 (`backend/src/api/endpoints/m3u_api.rs`
    /// maps its whole `Err` arm to `StatusCode::NO_CONTENT`), and 204 is
    /// inside `200...299`, so the empty download read as a successful fetch
    /// of an empty playlist. Nothing in the app could tell the user anything.
    case emptyResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid server URL"
        case .unauthorized:         return "Invalid credentials — your API key was not found on the server. Go to Settings → your server → Admin API Key and verify it matches an Admin user's API Key in Dispatcharr → System → Users → Edit User → API & XC."
        case .serverError(let c):
            switch c {
            case 404: return "Endpoint not found (404) — verify your server URL"
            case 429: return "Rate limited (429) — too many requests, try again shortly"
            case 500: return "Internal server error (500) — check your server logs"
            case 502: return "Bad gateway (502) — your server's reverse proxy is failing"
            case 503: return "Server temporarily unavailable (503) — your server may be starting up or restarting. Tap Try Again in a moment."
            case 504: return "Gateway timeout (504) — your server is not responding in time"
            default:  return "Server error (\(c))"
            }
        case .decodingError(let e):
            // Include underlying decoding details when available (trimmed).
            let msg = e.localizedDescription
            if msg.isEmpty { return "Failed to parse server response" }
            let trimmed = String(msg.prefix(500))
            return "Failed to parse server response: \(trimmed)"
        case .networkError(let e):  return "Network error: \(e.localizedDescription)"
        case .invalidResponse:      return "Unexpected response from server"
        case .emptyResponse(let c):
            if c == 204 {
                return "The server accepted the request but returned no data (HTTP 204). That usually means it could not build the playlist for these credentials: check the username and password, and that this device is allowed to connect."
            }
            return "The server returned an empty response (HTTP \(c))"
        case .timeout:              return "Connection timed out"
        }
    }
}

// MARK: - Xtream Codes API
struct XtreamCodesAPI {
    let baseURL: String
    let username: String
    let password: String

    // Shared session — reused across all calls (avoid creating a new URLSession per request).
    // 20s per-request idle timeout: a dead Docker container / unreachable host
    // should surface an error well inside 20 seconds, not the 60s Apple default.
    // 300s resource timeout covers legitimately-large EPG / VOD payloads for
    // servers with 10K+ channels.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // NO total-resource cap. timeoutIntervalForResource budgets the ENTIRE
        // transfer, so on a provider-sized payload it silently becomes a
        // MINIMUM BANDWIDTH requirement rather than a liveness check. Measured
        // 2026-08-10 on a real panel: get_live_streams is 23.7MB (53.6k
        // channels), and a panel a few times larger is ordinary. The 20s
        // timeoutIntervalForRequest above is the correct guard - it is an IDLE
        // timeout, so a dead host still fails in 20s while a slow-but-alive
        // link is allowed to finish. Same reasoning as PlaylistParsers.session,
        // which has always omitted the resource cap.
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()
    private static let largeLibrarySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // This session fetches the FULL VOD and series libraries. On the panel
        // measured 2026-08-10 those are 99MB (194k movies) and 65MB (44.7k
        // series); the old 180s cap demanded ~4.4 Mbit/s sustained or the
        // library download died part-way. Providers this size are normal for
        // anyone not running Dispatcharr, so the cap is removed here for the
        // same reason as above; the 30s idle timeout still fails a dead host.
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.session }

    /// Reusable decoder. v1.6.22: previously every decode call
    /// allocated a fresh `JSONDecoder()`. JSONDecoder is thread-safe
    /// for concurrent `decode(...)` so a single static instance is fine.
    private static let jsonDecoder = JSONDecoder()

    // MARK: - Account Info / Verify
    func verifyConnection() async throws -> XtreamAccountInfo {
        let url = try buildURL(path: "/player_api.php", params: ["action": ""])
        let (data, response) = try await loggedData(from: url)
        try validate(response: response, data: data)
        return try decode(XtreamAccountInfo.self, from: data)
    }

    // MARK: - Live TV Categories
    func getLiveCategories() async throws -> [XtreamCategory] {
        let url = try buildURL(path: "/player_api.php", params: ["action": "get_live_categories"])
        let (data, response) = try await loggedData(from: url)
        try validate(response: response)
        return try decode([XtreamCategory].self, from: data)
    }

    // MARK: - Live Streams
    func getLiveStreams(categoryID: String? = nil) async throws -> [XtreamStream] {
        var params: [String: String] = ["action": "get_live_streams"]
        if let id = categoryID { params["category_id"] = id }
        let url = try buildURL(path: "/player_api.php", params: params)
        let (data, response) = try await loggedData(from: url)
        try validate(response: response)
        return try decode([XtreamStream].self, from: data)
    }

    // MARK: - VOD Categories
    func getVODCategories() async throws -> [XtreamCategory] {
        let url = try buildURL(path: "/player_api.php", params: ["action": "get_vod_categories"])
        let (data, response) = try await loggedData(from: url)
        try validate(response: response)
        // Some panels return false/null/object for missing categories — treat as empty
        return (try? decode([XtreamCategory].self, from: data)) ?? []
    }

    // MARK: - VOD Streams
    func getVODStreams(categoryID: String? = nil) async throws -> [XtreamVODItem] {
        var params: [String: String] = ["action": "get_vod_streams"]
        if let id = categoryID { params["category_id"] = id }
        let url = try buildURL(path: "/player_api.php", params: params)
        // A full VOD library runs to tens of MB. Stream it to a temp file and
        // decode from a memory-mapped read so the whole body is never resident
        // in RAM at once (Android GH #26/#31 parity). v1.6.10: HTTPRouter so
        // HSTS-preloaded TLD HTTP URLs work.
        let (tempURL, response) = try await HTTPRouter.download(from: url, using: Self.largeLibrarySession)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try validate(response: response)
        let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)
        // Some panels return false/null/object for empty or unavailable VOD — treat as empty
        if let items = try? decode([XtreamVODItem].self, from: data) { return items }
        DebugLogger.shared.log("XC get_vod_streams: non-array response (\(data.count) bytes) — treating as empty",
                               category: "VOD", level: .warning)
        return []
    }

    // MARK: - VOD Stream URL
    func vodStreamURL(for vod: XtreamVODItem) -> URL? {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let ext = vod.containerExtension.isEmpty ? "mp4" : vod.containerExtension
        return URL(string: "\(base)/movie/\(username)/\(password)/\(vod.streamID).\(ext)")
    }


    // MARK: - Series Categories
    func getSeriesCategories() async throws -> [XtreamCategory] {
        let url = try buildURL(path: "/player_api.php", params: ["action": "get_series_categories"])
        let (data, response) = try await loggedData(from: url)
        try validate(response: response)
        // Some panels return false/null/object for missing categories — treat as empty
        return (try? decode([XtreamCategory].self, from: data)) ?? []
    }

    // MARK: - Series
    func getSeries(categoryID: String? = nil) async throws -> [XtreamSeriesItem] {
        var params: [String: String] = ["action": "get_series"]
        if let id = categoryID { params["category_id"] = id }
        let url = try buildURL(path: "/player_api.php", params: params)
        // A full series library runs to tens of MB. Stream it to a temp file
        // and decode from a memory-mapped read so the whole body is never
        // resident in RAM at once (Android GH #26/#31 parity). v1.6.10:
        // HTTPRouter so HSTS-preloaded TLD HTTP URLs work.
        let (tempURL, response) = try await HTTPRouter.download(from: url, using: Self.largeLibrarySession)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try validate(response: response)
        let data = try Data(contentsOf: tempURL, options: .mappedIfSafe)
        // Some panels return false/null/object for empty or unavailable series — treat as empty
        if let items = try? decode([XtreamSeriesItem].self, from: data) { return items }
        DebugLogger.shared.log("XC get_series: non-array response (\(data.count) bytes) — treating as empty",
                               category: "VOD", level: .warning)
        return []
    }

    // MARK: - EPG (short)
    func getEPG(streamID: String, limit: Int = 3) async throws -> XtreamEPGResponse {
        let url = try buildURL(path: "/player_api.php", params: [
            "action": "get_short_epg",
            "stream_id": streamID,
            "limit": String(limit)
        ])
        let (data, response) = try await loggedData(from: url)
        try validate(response: response)
        return try decode(XtreamEPGResponse.self, from: data)
    }

    // MARK: - M3U Playlist (contains real proxy stream URLs)
    // Dispatcharr and most Xtream panels serve the actual playable URLs in the M3U,
    // not in the /live/user/pass/id.ext format from the JSON API.
    // The M3U embeds URLs like /proxy/ts/stream/{uuid} for Dispatcharr.
    /// NOTE: currently has no callers - Apple loads XC live channels from
    /// `getLiveStreams()` (player_api.php JSON), which is why the Android-only
    /// get.php 404 below never affected iOS/tvOS. Kept (and kept correct) so a
    /// future M3U-based parity path can't inherit the bug.
    ///
    /// `output` is required by some panels: crx.watch returns a bare HTTP 404
    /// for `type=m3u_plus` with no `output`, and 200 for `output=ts`. Android
    /// omitted it and could not add that provider's playlist at all.
    func m3uURL() -> URL? {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(base)/get.php?username=\(username)&password=\(password)&type=m3u_plus&output=ts")
    }

    /// Standard Xtream Codes bulk XMLTV EPG feed — the full guide every
    /// other XC client consumes. The server renders programme names its
    /// own way here (dummy-EPG name settings, `<category>` tags, etc.),
    /// unlike the per-stream `get_short_epg` JSON. Routed through
    /// `buildURL` so username/password are query-encoded.
    func xmltvURL() -> URL? {
        try? buildURL(path: "/xmltv.php", params: [:])
    }

    // Removed the unused `fetchM3UStreamURLs()` (2026-07-13): it had zero
    // callers and was the one XC path that buffered the whole m3u_plus body
    // into a String before parsing (the Android GH #31 shape). The live-channel
    // list is served by `getLiveStreams()` (JSON); the raw m3u_plus is only
    // parsed via the streaming `M3UParser.fetchAndParse` disk path.

    /// Build ordered stream URL attempts for a channel.
    /// Xtream standard: /live/user/pass/stream_id.ext
    /// .ts first on BOTH platforms (GH #59 perf: 3-4s XC tunes vs near-instant
    /// Direct Connect). The old tvOS .m3u8-first order dated from the
    /// AVPlayer-only era: classifyStreamURL trusts the extension, so the .m3u8
    /// URL locked the AVPlayer-direct-HLS engine with NO probe - but
    /// Dispatcharr's XC endpoint serves raw MPEG-TS for .m3u8 requests, and
    /// every tvOS tune burned the ~4s AVPlayer stall watchdog before falling
    /// back to mpv. The .ts URL classifies .mpegTS, hits the cached per-host
    /// probe, and routes straight to mpv - Direct Connect speed. Genuine-HLS
    /// panels still play via the .m3u8 fallback in the retry ladder.
    /// Note: requires Dispatcharr stream profile set to "Redirect" to work correctly.
    func streamURLs(for stream: XtreamStream) -> [URL] {
        var urls: [URL] = []
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if let url = URL(string: "\(base)/live/\(username)/\(password)/\(stream.streamID).ts") {
            urls.append(url)
        }
        if let url = URL(string: "\(base)/live/\(username)/\(password)/\(stream.streamID).m3u8") {
            urls.append(url)
        }
        // direct_source field if server provides it
        if let direct = stream.directSource, !direct.isEmpty, let url = URL(string: direct) {
            urls.append(url)
        }
        return urls
    }

    // MARK: - Helpers

    /// Wraps the data fetch with DebugLogger timing and result logging.
    /// v1.6.10: routed through `HTTPRouter` so plain-HTTP requests against
    /// HSTS-preloaded TLDs (`.app`, `.dev`, etc.) bypass URLSession's
    /// HSTS layer via Network.framework. URLSession remains the path for
    /// HTTPS, IP literals, and non-preloaded TLDs.
    private func loggedData(from url: URL) async throws -> (Data, URLResponse) {
        let start = Date()
        do {
            let result = try await HTTPRouter.data(from: url, using: session)
            let status   = (result.1 as? HTTPURLResponse)?.statusCode
            let duration = Date().timeIntervalSince(start)
            // v1.6.8 (Codex D4): the manual `replacingOccurrences`
            // redaction that used to live here was fragile — it
            // missed percent-encoded passwords and leaked the
            // username regardless. `logNetwork` already routes
            // through `DebugLogger.sanitize()` which handles the
            // Xtream query-param pattern (`?username=X&password=Y`)
            // uniformly, so we hand the raw URL to the logger and
            // let the centralised sanitizer do the work.
            DebugLogger.shared.logNetwork(method: "GET", url: url.absoluteString, statusCode: status,
                                          duration: duration, bytesReceived: result.0.count)
            return result
        } catch {
            let duration = Date().timeIntervalSince(start)
            DebugLogger.shared.logNetwork(method: "GET", url: url.absoluteString,
                                          duration: duration, error: error)
            throw error
        }
    }

    private func buildURL(path: String, params: [String: String]) throws -> URL {
        guard var components = URLComponents(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        queryItems += params.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = queryItems
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    private func validate(response: URLResponse) throws {
        try validate(response: response, data: nil)
    }

    /// Body-aware validation. When `data` is provided we also detect the common
    /// "user typed a Dispatcharr/reverse-proxy URL by mistake" case: the server
    /// returns HTTP 200 with an HTML login page, which would otherwise fall
    /// through to JSON decoding and produce a wall-of-HTML error.
    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw APIError.unauthorized
        default: throw APIError.serverError(http.statusCode)
        }

        // HTML-sniffing: Content-Type header OR first few bytes of the body.
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let bodyLooksHTML: Bool = {
            guard let data, data.count > 0 else { return false }
            let prefix = data.prefix(64)
            guard let head = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
            return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<head")
        }()
        if contentType.contains("text/html") || bodyLooksHTML {
            // Show only scheme://host:port/path (no query, no userinfo) in this
            // user-facing message. The Xtream endpoint carries username and
            // password in the query string, and this error text can be
            // screenshotted or pasted into a bug report; host+path is what the
            // user needs to verify the endpoint (the common mistake is a wrong
            // port or path, not the credentials).
            let safeURL: String = {
                guard let u = http.url,
                      var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
                else { return "the URL" }
                comps.query = nil
                comps.fragment = nil
                comps.user = nil
                comps.password = nil
                return comps.string ?? "the URL"
            }()
            throw APIError.decodingError(NSError(
                domain: "XtreamCodesAPI",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey:
                    "The server returned a web page instead of Xtream Codes API data. Double-check the Server URL. It should point to the Xtream-compatible endpoint (often a different port than the web admin). Verify by opening \(safeURL) in a browser: you should see JSON, not a login page."
                ]
            ))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.jsonDecoder.decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func decodeDispatcharrServerInfo(from data: Data) throws -> DispatcharrServerInfo {
        let decoder = Self.jsonDecoder

        // Most common: { "version": "...", ... }
        if let direct = try? decoder.decode(DispatcharrServerInfo.self, from: data) {
            return direct
        }

        // Some deployments wrap responses: { "data": { ... } }
        struct Wrapper: Decodable { let data: DispatcharrServerInfo }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data) {
            return wrapped.data
        }

        // Last resort: surface the body for debugging.
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw APIError.decodingError(NSError(
            domain: "DispatcharrAPI",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Unrecognized /api/version/ response. Body: \(String(body.prefix(800)))"]
        ))
    }
}

// MARK: - Xtream Response Models
struct XtreamAccountInfo: Decodable {
    struct UserInfo: Decodable {
        let username: String
        let status: String
        let expDate: String?
        let maxConnections: String?
        let activeConnections: String?

        enum CodingKeys: String, CodingKey {
            case username, status
            case expDate = "exp_date"
            case maxConnections = "max_connections"
            case activeConnections = "active_connections"
        }
    }
    /// Catch-up (timeshift): the panel's server_info block. `timezone` is
    /// the zone the panel renders EPG times AND parses the timeshift URL's
    /// `start` segment in -- sending UTC to a non-UTC panel plays the wrong
    /// hour (the classic XC catch-up footgun).
    struct ServerInfo: Decodable {
        let timezone: String?
        enum CodingKeys: String, CodingKey { case timezone }
    }
    let userInfo: UserInfo
    let serverInfo: ServerInfo?
    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

struct XtreamCategory: Decodable, Identifiable {
    let id: String
    let name: String
    let parentID: Int?

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
        case parentID = "parent_id"
    }
}

struct XtreamStream: Decodable, Identifiable {
    let id: Int
    let streamID: Int
    let name: String
    let streamIcon: String?
    let epgChannelID: String?
    let added: String?
    let categoryID: String?
    /// GH #59: the panel's channel number, preserved VERBATIM as a string.
    /// Subchannels are decimal ("6.1", "18.2"); the old `num: Int?` decode
    /// nil'ed every one of them and the list-index fallback then hid the
    /// fact - same class of bug the M3U path fixed in d1ac87a.
    let channelNumber: String?
    let allowedOutputFormats: [String]?  // e.g. ["ts"], ["ts","m3u8"]
    let directSource: String?            // sometimes set to a direct HLS URL
    /// Catch-up: 1 when the provider archives this channel. Real panels
    /// send Int OR String ("1"), so this is parsed loosely in init.
    let tvArchive: Int
    /// Catch-up retention window in DAYS (mixed String/Int upstream).
    let tvArchiveDuration: Int

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case added
        case categoryID = "category_id"
        case num
        case allowedOutputFormats = "allowed_output_formats"
        case directSource = "direct_source"
        case tvArchive = "tv_archive"
        case tvArchiveDuration = "tv_archive_duration"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // stream_id and name can arrive as different types or be absent on malformed entries.
        if let intID = try? c.decode(Int.self, forKey: .streamID) {
            streamID = intID
        } else if let strID = try? c.decode(String.self, forKey: .streamID), let parsed = Int(strID) {
            streamID = parsed
        } else {
            streamID = 0
        }
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        streamIcon = try? c.decode(String.self, forKey: .streamIcon)
        epgChannelID = try? c.decode(String.self, forKey: .epgChannelID)
        added = try? c.decode(String.self, forKey: .added)
        categoryID = try? c.decode(String.self, forKey: .categoryID)
        // GH #59: tolerant `num` ladder (Double flattening whole numbers,
        // then Int, then trimmed String) so decimal subchannel numbers
        // survive. Panels send all three shapes.
        if let d = try? c.decode(Double.self, forKey: .num) {
            channelNumber = d == d.rounded() ? String(Int(d)) : String(d)
        } else if let i = try? c.decode(Int.self, forKey: .num) {
            channelNumber = String(i)
        } else if let s = try? c.decode(String.self, forKey: .num) {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            channelNumber = trimmed.isEmpty ? nil : trimmed
        } else {
            channelNumber = nil
        }
        allowedOutputFormats = try? c.decode([String].self, forKey: .allowedOutputFormats)
        directSource = try? c.decode(String.self, forKey: .directSource)
        if let i = try? c.decode(Int.self, forKey: .tvArchive) {
            tvArchive = i
        } else if let str = try? c.decode(String.self, forKey: .tvArchive) {
            tvArchive = Int(str) ?? 0
        } else {
            tvArchive = 0
        }
        if let i = try? c.decode(Int.self, forKey: .tvArchiveDuration) {
            tvArchiveDuration = i
        } else if let str = try? c.decode(String.self, forKey: .tvArchiveDuration) {
            tvArchiveDuration = Int(str) ?? 0
        } else {
            tvArchiveDuration = 0
        }
        // GH #59: identity is the panel's stream_id, never the channel
        // number - the old `num ?? streamID` mixed two ID spaces and could
        // collide Identifiable rows.
        id = streamID
    }


    /// Best format for iOS: always m3u8 (HLS) — AVPlayer handles it natively.
    var bestFormat: String { "m3u8" }
}

struct XtreamEPGResponse: Decodable {
    let epgListings: [XtreamEPGItem]
    enum CodingKeys: String, CodingKey { case epgListings = "epg_listings" }
}

struct XtreamEPGItem: Decodable {
    let title: String
    let description: String
    let start: String
    let end: String
    let channelID: String

    enum CodingKeys: String, CodingKey {
        case title, description, start, end
        case channelID = "channel_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // XC protocol Base64-encodes title and description in get_short_epg responses.
        let rawTitle = (try? c.decode(String.self, forKey: .title)) ?? ""
        let rawDesc  = (try? c.decode(String.self, forKey: .description)) ?? ""
        title       = Self.decodeBase64(rawTitle)
        description = Self.decodeBase64(rawDesc)
        start       = (try? c.decode(String.self, forKey: .start)) ?? ""
        end         = (try? c.decode(String.self, forKey: .end)) ?? ""
        channelID   = (try? c.decode(String.self, forKey: .channelID)) ?? ""
    }

    private static func decodeBase64(_ value: String) -> String {
        guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else { return value }
        return decoded
    }
}


// MARK: - Xtream VOD Item
struct XtreamVODItem: Decodable, Identifiable {
    let id: Int
    let streamID: Int
    let name: String
    let streamIcon: String?
    let categoryID: String?
    let containerExtension: String
    let rating: String?
    let plot: String?
    let cast: String?
    let director: String?
    let genre: String?
    let releaseDate: String?
    let youtubeTrailer: String?

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case categoryID = "category_id"
        case containerExtension = "container_extension"
        case rating
        case plot
        case cast
        case director
        case genre
        case releaseDate = "releasedate"
        case youtubeTrailer = "youtube_trailer"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // stream_id can arrive as Int or String depending on the provider.
        if let intID = try? c.decode(Int.self, forKey: .streamID) {
            streamID = intID
        } else if let strID = try? c.decode(String.self, forKey: .streamID), let parsed = Int(strID) {
            streamID = parsed
        } else {
            streamID = 0
        }
        // name can be missing or null on malformed entries; default to empty string so the
        // item is still included rather than blowing up the entire response decode.
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        streamIcon = try? c.decode(String.self, forKey: .streamIcon)
        categoryID = try? c.decode(String.self, forKey: .categoryID)
        containerExtension = (try? c.decode(String.self, forKey: .containerExtension)) ?? "mp4"
        rating = try? c.decode(String.self, forKey: .rating)
        plot = try? c.decode(String.self, forKey: .plot)
        // v0.26.0: tolerate array-shaped cast/director (joined).
        cast = c.decodeFlexibleString(forKey: .cast)
        director = c.decodeFlexibleString(forKey: .director)
        genre = try? c.decode(String.self, forKey: .genre)
        releaseDate = try? c.decode(String.self, forKey: .releaseDate)
        youtubeTrailer = try? c.decode(String.self, forKey: .youtubeTrailer)
        id = streamID
    }
}


// MARK: - Flexible string decoding (Dispatcharr v0.26.0)

extension KeyedDecodingContainer {
    /// Decode a field a provider may send as EITHER a JSON string
    /// ("Actor A, Actor B") OR a JSON array (["Actor A", "Actor B"]).
    /// Dispatcharr v0.26.0 began returning cast / actors / director as
    /// full lists (the "no longer truncated to first name" fix, #1228).
    /// A plain `decode(String.self)` throws on the array shape, so the
    /// value would silently vanish from the UI; this joins arrays with
    /// ", " to match the single-string display the app already renders.
    /// Returns nil when the key is absent, null, or resolves to empty.
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let s = try? decode(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let arr = try? decode([String].self, forKey: key) {
            let joined = arr
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Decode a value Dispatcharr/DRF may serialize as EITHER a JSON
    /// number or a JSON string, returning it as a String. Returns nil for
    /// missing / null / empty. Used by `DispatcharrStream.StreamStats`
    /// numeric fields (`source_fps`, `ffmpeg_output_bitrate`), which arrive
    /// inconsistently typed — the same DRF quirk that forced
    /// `DispatcharrChannel.channelNumber` to a tolerant decode. Tries
    /// String first (covers "1080", "59.94"), then Double (drops a
    /// trailing .0 for whole numbers), then Int.
    func decodeStringOrNumber(forKey key: Key) -> String? {
        if let s = try? decode(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let d = try? decode(Double.self, forKey: key) {
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        if let i = try? decode(Int.self, forKey: key) {
            return String(i)
        }
        return nil
    }
}

// MARK: - Xtream Series Item
struct XtreamSeriesItem: Decodable, Identifiable {
    let id: Int
    let seriesID: Int
    let name: String
    let cover: String?
    let plot: String?
    let cast: String?
    let director: String?
    let genre: String?
    let releaseDate: String?
    let rating: String?
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case name
        case cover
        case plot
        case cast
        case director
        case genre
        case releaseDate = "releaseDate"
        case rating
        case categoryID = "category_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // series_id can arrive as Int or String depending on the provider.
        if let intID = try? c.decode(Int.self, forKey: .seriesID) {
            seriesID = intID
        } else if let strID = try? c.decode(String.self, forKey: .seriesID), let parsed = Int(strID) {
            seriesID = parsed
        } else {
            seriesID = 0
        }
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        cover = try? c.decode(String.self, forKey: .cover)
        plot = try? c.decode(String.self, forKey: .plot)
        // v0.26.0: tolerate array-shaped cast/director (joined).
        cast = c.decodeFlexibleString(forKey: .cast)
        director = c.decodeFlexibleString(forKey: .director)
        genre = try? c.decode(String.self, forKey: .genre)
        releaseDate = try? c.decode(String.self, forKey: .releaseDate)
        rating = try? c.decode(String.self, forKey: .rating)
        categoryID = try? c.decode(String.self, forKey: .categoryID)
        id = seriesID
    }
}

// MARK: - Dispatcharr Native API
struct DispatcharrAPI {
    enum Auth {
        /// Bearer-with-API-key — the "bearer" shape inside
        /// `DispatcharrAuthHeaderMode.bearer`. Sends
        /// `Authorization: Bearer <api-key>`. Auth value is fixed
        /// for the lifetime of the API instance.
        case bearer(String)
        /// X-API-Key (or `ApiKey ...`, per `authMode`). Auth value
        /// is fixed for the lifetime of the API instance.
        case apiKey(String)
        /// v1.7 Direct Connect — looks up a live JWT access token
        /// from `DispatcharrTokenStore.shared` keyed by server ID at
        /// every request. Tokens are short-lived (30 min access, 24h
        /// refresh) and rotate as they expire, which is why the API
        /// instance can't hold the value directly. Retry-on-401 with
        /// silent refresh is wired in `dataWithJWTRetry`.
        case jwtSession(serverID: UUID)
    }

    let baseURL: String
    let auth: Auth
    /// User-Agent string sent on every request. Dispatcharr reads this from
    /// the standard HTTP header and surfaces it in the admin Stats panel
    /// so users can identify which device is connected. Callers with a
    /// `ServerConnection` should pass `server.effectiveUserAgent` here;
    /// legacy callsites that don't have a server reference fall back to
    /// the app-wide default.
    let userAgent: String
    /// v1.6.20: per-server auth header shape, persisted on the
    /// `ServerConnection` after Test Connection auto-detects what the
    /// server accepts. Default `.xapikey` matches v1.6.16+ behavior
    /// (preferred — full VOD episode visibility); `verifyConnection`
    /// auto-falls-back to `.both` then `.bearer` on HTTP 401 so users
    /// on Dispatcharr builds that reject X-API-Key alone get connected
    /// without intervention. Bearer auth (`auth == .bearer`) ignores
    /// this field — that path is unambiguous.
    let authMode: DispatcharrAuthHeaderMode

    /// v1.7.x: identifies which `ServerConnection` this API instance
    /// belongs to, so `dataWithJWTRetry` can drive the silent api_key
    /// re-bootstrap path (Save Credentials Option 1). Optional because
    /// static helpers like `login()` and `refreshAccessToken()` don't
    /// have a server context, and pre-v1.7.x call sites that pass auth
    /// directly from a primitive api_key string keep working unchanged.
    let serverID: UUID?

    /// v1.7.x: saved Dispatcharr admin username for silent re-auth
    /// when the api_key 401s. Sourced from `ServerConnection.username`
    /// at construction time. Only populated for `.apiKey` instances
    /// whose owning server is in Username & Password mode (saved
    /// credentials present); empty / nil for API-Key-only servers
    /// disables the silent rebootstrap path so we never call
    /// `/api/accounts/token/` against a server whose user never
    /// agreed to credential-based auth.
    let savedUsername: String?

    init(baseURL: String,
         auth: Auth,
         userAgent: String = DeviceInfo.defaultUserAgent,
         authMode: DispatcharrAuthHeaderMode = .xapikey,
         serverID: UUID? = nil,
         savedUsername: String? = nil) {
        self.baseURL = baseURL
        self.auth = auth
        self.userAgent = userAgent
        self.authMode = authMode
        self.serverID = serverID
        self.savedUsername = savedUsername
    }


    // Shared session — reused across all calls (avoid creating a new URLSession per request).
    // 20s per-request idle timeout mirrors XtreamCodesAPI's session: lets
    // error states (dead container, firewalled host, etc.) surface well
    // inside the 20s mark instead of the 60s Apple default that makes the
    // app feel "perpetually loading" to a user whose server is actually
    // down. Resource-wide 300s still covers large EPG/VOD payloads.
    //
    // v1.6.20: a `RedirectPreservingDelegate` is wired here so URLSession
    // re-applies our auth headers across HTTP 301/302/307/308 redirects.
    // Apple's URLSession default-strips custom headers (including
    // `X-API-Key` and `Authorization`) when a redirect crosses origin —
    // a real-world hit for Dispatcharr deployments behind a reverse
    // proxy that 301s `/api` → `/api/`. Without re-applying, the
    // follow-up request lands at the auth wall stripped of credentials
    // and 401s; the user blames the API key. The delegate copies our
    // X-API-Key, Authorization, Accept, and User-Agent fields onto the
    // redirected request before letting URLSession proceed.
    private static let redirectDelegate = RedirectPreservingDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // v1.6.21: bumped from 20s/300s to 60s/600s. Real-world
        // probing of a self-hosted Dispatcharr 0.23.0 with a large
        // library showed `/api/epg/grid/` returning 24.3 MB JSON in
        // 30.6 seconds (single bulk fetch). The previous 20s
        // per-request timeout cut that off mid-stream, surfacing as
        // "Bulk EPG failed: cannot parse response, falling back
        // to lazy loading" in user logs. 60s comfortably covers
        // the EPG grid plus headroom for slower deployments;
        // 600s resource-wide handles the rare case where mpv-
        // adjacent endpoints stream multi-MB payloads. Combined
        // with the 4-concurrent gate above, this doesn't risk
        // amplifying load: slower requests still queue politely
        // through the semaphore.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config,
                          delegate: redirectDelegate,
                          delegateQueue: nil)
    }()
    private static let bulkEPGSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config,
                          delegate: redirectDelegate,
                          delegateQueue: nil)
    }()
    private var session: URLSession { Self.session }

    /// Reusable decoder. v1.6.22: previously every decode site
    /// (~18 in this class) constructed a fresh `JSONDecoder()`,
    /// which is wasteful on the initial-sync hot path. JSONDecoder
    /// is thread-safe for concurrent `decode(...)` calls so a
    /// single static instance is fine. No custom strategies are
    /// configured anywhere in DispatcharrAPI (key strategies and
    /// date strategies are explicit per-model via CodingKeys +
    /// per-field type juggling), so a default decoder suffices.
    private static let jsonDecoder = JSONDecoder()
    private var decoder: JSONDecoder { Self.jsonDecoder }

    /// Headers for the current `authMode`. All other DispatcharrAPI
    /// methods read this — only `verifyConnection` overrides it during
    /// auth-shape discovery (see `headers(for:)`).
    private var headers: [String: String] { headers(for: authMode) }

    /// Auth + UA headers only, no JSON content negotiation.
    ///
    /// Use this when calling Dispatcharr endpoints that don't return
    /// JSON, notably `/output/epg` (XMLTV stream). Locked-down
    /// deployments require the same X-API-Key / Authorization that
    /// `/api/*` does, but adding `Accept: application/json` to a
    /// non-JSON endpoint can trip content-type middleware on some
    /// builds. Stripped here to keep the request minimal.
    /// v1.6.22: Freyguy1975's Synology setup returned 403 on the
    /// XMLTV stream until headers were attached.
    var streamAuthHeaders: [String: String] {
        var h = headers
        h.removeValue(forKey: "Content-Type")
        h.removeValue(forKey: "Accept")
        return h
    }

    /// Builds the request header dictionary for an explicit auth mode.
    /// Used by `verifyConnection` to iterate header shapes against a
    /// Dispatcharr instance whose auth requirements aren't yet known
    /// (different builds reject different shapes — see the
    /// `DispatcharrAuthHeaderMode` doc comment for the rationale).
    private func headers(for mode: DispatcharrAuthHeaderMode) -> [String: String] {
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": userAgent
        ]
        switch auth {
        case .bearer(let token):
            // Bearer-token auth ignores `mode` — the header shape is
            // unambiguous regardless of which Dispatcharr build we're
            // talking to.
            h["Authorization"] = "Bearer \(token)"
        case .apiKey(let key):
            switch mode {
            case .xapikey:
                // v1.6.16+ default. Preferred when the server accepts
                // it — Dispatcharr's per-series episodes endpoint
                // returns the full episode list under X-API-Key alone,
                // whereas adding `Authorization` can route the request
                // through user-scoped session auth that filters
                // visibility to a subset of m3u_accounts.
                h["X-API-Key"] = key
            case .both:
                // Pre-1.6.16 shape. Some Dispatcharr builds REQUIRE
                // the `Authorization` header and reject X-API-Key
                // alone with HTTP 401 — that's the bug three users
                // hit in v1.6.19, regardless of API key validity.
                // This shape gets those deployments connected. Cost:
                // the same VOD-episode filtering that v1.6.16 was
                // chasing may resurface for series whose upstream
                // providers fall outside the session's m3u_accounts
                // view. Acceptable trade — partial VOD beats no
                // connection at all.
                h["Authorization"] = "ApiKey \(key)"
                h["X-API-Key"] = key
            case .bearer:
                // Rare — reserved for token-based deployments that
                // don't speak ApiKey at all.
                h["Authorization"] = "Bearer \(key)"
            }
        case .jwtSession(let serverID):
            // v1.7 Direct Connect — read the current access token from
            // the store. If unset (e.g. cold launch before initial
            // login completes), we still emit Accept + UA so the
            // request shape is otherwise correct; the eventual 401
            // triggers `dataWithJWTRetry` to log in and replay.
            if let access = DispatcharrTokenStore.shared.accessToken(for: serverID) {
                h["Authorization"] = "Bearer \(access)"
            }
        }
        return h
    }

    // MARK: - JWT-aware request wrapper

    /// v1.7.x: drop-in wrapper for `HTTPRouter.data(for:using:)` that
    /// transparently refreshes the JWT access token on HTTP 401 and
    /// retries the request once. No-op for `.apiKey` / `.bearer` auth
    /// modes — those return the original response unchanged. Migrate
    /// hot-path call sites (verifyConnection, getEPGGrid,
    /// enrichCategories, getAllEPGData) to this wrapper so that a
    /// session that's been idle past the 30-min access-token TTL
    /// recovers silently instead of erroring out.
    ///
    /// The retry only fires when:
    ///   1. Auth mode is `.jwtSession`
    ///   2. The response status is exactly 401
    ///   3. A refresh token is cached in the store
    ///   4. The refresh call succeeds
    ///
    /// On any failure of those conditions, the original (401)
    /// response is returned to the caller so existing error
    /// handling stays intact. The token store is cleared on
    /// `.refreshExpired` so the next request goes through the
    /// session-warmup path (re-login from Keychain credentials).
    func dataWithJWTRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await HTTPRouter.data(for: request, using: session)

        // Fast path: not 401. Return verbatim. Both .jwtSession and
        // .apiKey share the same 401-recovery dispatch table below.
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 401 else {
            return (data, response)
        }

        switch auth {
        case .jwtSession(let serverID):
            // Need a refresh token to even attempt recovery.
            guard let refreshTok = DispatcharrTokenStore.shared.refreshToken(for: serverID) else {
                return (data, response)
            }

            // Refresh the access token. If the refresh has itself
            // expired (>24h idle), clear the store entry so the next
            // session-warmup tick re-logs in from Keychain credentials,
            // and surface the original 401 to the caller.
            let newAccess: String
            do {
                newAccess = try await Self.refreshAccessToken(
                    baseURL: baseURL,
                    refresh: refreshTok,
                    userAgent: userAgent
                )
            } catch DispatcharrDirectConnectError.refreshExpired {
                DispatcharrTokenStore.shared.clear(serverID: serverID)
                return (data, response)
            } catch {
                return (data, response)
            }
            DispatcharrTokenStore.shared.storeRefreshedAccess(serverID: serverID, access: newAccess)

            // Replay the original request with the refreshed Bearer
            // header. Preserve all other headers (Accept, User-Agent,
            // X-API-Key fallback if present) so we don't lose anything
            // the original call emitted.
            var retry = request
            retry.setValue("Bearer \(newAccess)", forHTTPHeaderField: "Authorization")
            return try await HTTPRouter.data(for: retry, using: session)

        case .apiKey:
            // v1.7.x: silent api_key re-bootstrap. Only fires when:
            //   1. The instance was built with a serverID (production
            //      callers via ServerConnection — static helpers like
            //      login() never have one).
            //   2. The server has a saved username (i.e. it was
            //      onboarded in Username & Password mode and creds
            //      are sitting in Keychain).
            //
            // Both gates need to pass before we attempt re-auth, so
            // pure API-Key-mode users never see a `/api/accounts/token/`
            // call against a server whose user didn't agree to
            // credential-based auth. Surfaces the original 401 on
            // any failure so existing error-handling paths stay
            // intact.
            guard let sid = serverID,
                  let username = savedUsername,
                  !username.isEmpty else {
                return (data, response)
            }
            guard let newKey = await Self.silentRebootstrapApiKey(
                serverID: sid,
                baseURL: baseURL,
                username: username,
                userAgent: userAgent
            ) else {
                return (data, response)
            }
            // Replay with the fresh api_key in whichever header
            // shape the server's auto-detected `authMode` expects.
            // Mirrors `headers(for:)` so the retry ends up
            // byte-identical to a fresh call after a normal
            // settings-driven api_key swap.
            var retry = request
            switch authMode {
            case .xapikey:
                retry.setValue(newKey, forHTTPHeaderField: "X-API-Key")
            case .both:
                retry.setValue("ApiKey \(newKey)", forHTTPHeaderField: "Authorization")
                retry.setValue(newKey, forHTTPHeaderField: "X-API-Key")
            case .bearer:
                retry.setValue("Bearer \(newKey)", forHTTPHeaderField: "Authorization")
            }
            return try await HTTPRouter.data(for: retry, using: session)

        case .bearer:
            // Fixed-bearer mode (Test Connection / one-shot probe).
            // No persistence to refresh against — surface the 401.
            return (data, response)
        }
    }

    // MARK: - Verify
    func verifyConnection() async throws -> DispatcharrServerInfo {
        // Dispatcharr doesn't currently document a /api/version endpoint in the changelog,
        // and some deployments return the SPA index.html for unknown routes.
        // So we try a few lightweight endpoints and consider it "verified" if we get JSON back.

        let candidatePaths = [
            "/api/channels/groups/?page_size=1",   // lightweight — just 1 group to prove auth works
            "/api/channels/summary/",              // lightweight summary
            "/api/channels/channels/?page_size=1", // just 1 channel to prove auth works
            "/api/channels/",                      // index document (links) — allow as last resort
            "/api/core/version/",                  // v0.23.0+ moved version under /api/core/
            "/api/core/version",
            "/api/version/",                       // legacy path kept for older Dispatcharr builds
            "/api/version"
        ]

        // v1.6.20: iterate over auth header shapes when the configured
        // `authMode` is rejected. Some Dispatcharr builds reject
        // `X-API-Key`-alone (v1.6.16+ default) with HTTP 401 even with
        // a perfectly valid Admin API key — they require the legacy
        // `Authorization: ApiKey <key>` header that pre-1.6.16 sent
        // alongside it. Three users on private deployments hit this
        // in v1.6.19. The fix: try the configured mode first, then
        // fall back to other shapes when 401/403 surfaces, and report
        // the working shape back to the caller so it can be persisted
        // on `ServerConnection.dispatcharrAuthMode` for subsequent
        // requests.
        let candidateModes: [DispatcharrAuthHeaderMode] = {
            switch auth {
            case .bearer:
                // Bearer token auth doesn't have a header-shape choice.
                return [.bearer]
            case .apiKey:
                // Try the configured mode first, then the others, deduplicated.
                var modes: [DispatcharrAuthHeaderMode] = [authMode]
                for m in [DispatcharrAuthHeaderMode.xapikey, .both, .bearer] {
                    if !modes.contains(m) { modes.append(m) }
                }
                return modes
            case .jwtSession:
                // v1.7 Direct Connect: Bearer-only header shape, no
                // X-API-Key fallback. The JWT IS the credential, so
                // there's nothing to iterate against.
                return [.bearer]
            }
        }()

        /// Per-attempt outcome used to diagnose a failed verify. Tracking
        /// this lets us give the user an actionable error ("API key is
        /// wrong", "server unreachable", "server is running but didn't
        /// route to the API") instead of dumping a raw HTML body.
        enum AttemptOutcome {
            case html                 // 200 text/html — SPA shell, auth likely missing/invalid
            case httpError(Int)       // 4xx/5xx
            case jsonDecodeFailed     // 200 JSON but shape didn't match any expected schema
            case other                // e.g., 2xx with non-JSON, non-HTML body
        }
        var attemptOutcomes: [AttemptOutcome] = []
        var lastBodySnippet: String = ""
        var lastStatus: Int?
        var lastContentType: String?
        var lastURL: URL?
        // Tracks whether we ever saw the URL produce non-API content
        // (HTML, redirects, etc.) — distinguishes "wrong URL" from
        // "wrong header shape" in the diagnostic message.
        var sawNonAPIResponse = false

        modeLoop: for mode in candidateModes {
            // Per-mode tally — we only escalate to the next header
            // shape when this mode emitted at least one auth-style
            // failure (401/403). If the mode produced 200 HTML for
            // every probe, the URL points at the SPA, not the API,
            // and re-trying with different headers won't help.
            var modeAuthRejected = false
            var modeNonAuthFailures = 0

            for path in candidatePaths {
                let url = try buildURL(path: path)
                lastURL = url
                var request = URLRequest(url: url)
                headers(for: mode).forEach { request.setValue($1, forHTTPHeaderField: $0) }

                let (data, response) = try await loggedData(for: request)

                if let http = response as? HTTPURLResponse {
                    lastStatus = http.statusCode
                    lastContentType = http.value(forHTTPHeaderField: "Content-Type")
                }

                // If it's not a 2xx, capture body snippet and try next.
                if (lastStatus ?? 0) < 200 || (lastStatus ?? 0) >= 300 {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    lastBodySnippet = String(body.prefix(800))
                    let s = lastStatus ?? 0
                    attemptOutcomes.append(.httpError(s))
                    if s == 401 || s == 403 {
                        modeAuthRejected = true
                    } else {
                        modeNonAuthFailures += 1
                    }
                    continue
                }

                // If it's HTML, it's almost certainly the web UI shell, not the API.
                if let ct = lastContentType?.lowercased(), ct.contains("text/html") {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    lastBodySnippet = String(body.prefix(800))
                    attemptOutcomes.append(.html)
                    sawNonAPIResponse = true
                    continue
                }

                // Try decoding depending on endpoint.
                do {
                    let info: DispatcharrServerInfo
                    if path.contains("version") {
                        info = try decodeDispatcharrServerInfo(from: data)
                    } else if path.contains("channels/summary") {
                        _ = try decode([DispatcharrChannelSummary].self, from: data)
                        info = DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                    } else if path.contains("channels/channels") {
                        // Try paginated wrapper first (page_size=1), then flat array
                        if let _ = try? decode(DispatcharrResultsWrapper<DispatcharrChannel>.self, from: data) {
                            info = DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                        } else {
                            _ = try decode([DispatcharrChannel].self, from: data)
                            info = DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                        }
                    } else if path.contains("channels/groups") {
                        // Try paginated wrapper first (page_size=1), then flat array
                        if let _ = try? decode(DispatcharrResultsWrapper<DispatcharrChannelGroup>.self, from: data) {
                            info = DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                        } else {
                            _ = try decode([DispatcharrChannelGroup].self, from: data)
                            info = DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                        }
                    } else {
                        // /api/channels/ is an index document (links). Treat a JSON object with a "channels" key as valid.
                        let obj = try JSONSerialization.jsonObject(with: data)
                        if let dict = obj as? [String: Any], dict["channels"] != nil {
                            info = DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                        } else {
                            throw APIError.decodingError(NSError(
                                domain: "DispatcharrAPI",
                                code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Expected channels index JSON object with a 'channels' key."]
                            ))
                        }
                    }
                    // Success — embed the working header shape so the
                    // caller can persist it on the server.
                    var enriched = info
                    enriched.discoveredAuthMode = mode
                    debugLog("DispatcharrAPI verify: success with auth mode .\(mode.rawValue) on \(path)")
                    return enriched
                } catch {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    lastBodySnippet = String(body.prefix(800))
                    attemptOutcomes.append(.jsonDecodeFailed)
                    modeNonAuthFailures += 1
                    continue
                }
            }

            // Decide whether to try the next mode. Only iterate when
            // this mode's failure mode was auth-shaped — otherwise
            // (URL pointing at SPA, 5xx, decoding mismatch, network
            // issue) the next mode is just going to repeat the same
            // outcome and waste round-trips against the user's server.
            if !modeAuthRejected {
                debugLog("DispatcharrAPI verify: mode .\(mode.rawValue) failed without auth-error signal — stopping mode iteration")
                break modeLoop
            }
            debugLog("DispatcharrAPI verify: mode .\(mode.rawValue) was auth-rejected — trying next shape")
            _ = modeNonAuthFailures  // silence unused-variable warning when we did break
        }

        // Summarise the attempts into a user-actionable message. The
        // previous version dumped the raw HTML body into the error,
        // which (a) buried the actual cause in a wall of markup and
        // (b) didn't tell the user what to try. The most common real
        // failure modes are:
        //   • Every probe came back as HTML (SPA shell). This almost
        //     always means the API key is missing/wrong (Dispatcharr's
        //     front-door routes unauthenticated requests to the login
        //     SPA) OR the URL points at the web port but not through
        //     the `/api` prefix (e.g., a reverse proxy that strips
        //     `/api`).
        //   • 401/403 on every probe → authentication rejected (and
        //     we already auto-tried every supported header shape, so
        //     the API key itself is the most likely cause).
        //   • Everything 4xx/5xx → server error.
        //   • Mixed/other → fall back to a generic "couldn't recognise
        //     the server response" message with the last body snippet
        //     as the final diagnostic breadcrumb.
        let urlString = lastURL?.absoluteString ?? "<unknown url>"
        let firstAuthErrorCode: Int? = attemptOutcomes.compactMap {
            if case .httpError(let s) = $0, s == 401 || s == 403 { return s }
            return nil
        }.first
        let anyHTML = sawNonAPIResponse || attemptOutcomes.contains {
            if case .html = $0 { return true }
            return false
        }
        // Detect "every single probe was 401/403" — strongest possible
        // wrong-API-key signal. v1.6.20 split this from the looser
        // "any auth error" path so we can distinguish "every shape we
        // tried got rejected" (almost certainly an invalid/non-admin
        // key) from "one shape worked partially and others didn't"
        // (more likely a header-shape edge case worth surfacing
        // separately, though our auto-fallback should have caught
        // those).
        let allAuth: Bool = {
            guard !attemptOutcomes.isEmpty else { return false }
            return attemptOutcomes.allSatisfy {
                if case .httpError(let s) = $0, s == 401 || s == 403 { return true }
                return false
            }
        }()

        let message: String
        if allAuth, let authCode = firstAuthErrorCode {
            message = """
                Dispatcharr rejected every authentication shape AerioTV \
                tried (HTTP \(authCode)). The server is reachable, but \
                it won't accept this Admin API Key. Most common causes:
                  • The key belongs to a user without sufficient \
                permissions. On Dispatcharr 0.23.0+ most API endpoints \
                require Admin-tier access. In Dispatcharr open User \
                Settings, check the Permissions tab to confirm the \
                user is set to Admin, then copy the key from the API \
                & XC tab.
                  • The key was rotated or deleted on the server. \
                Generate a fresh API Key from User Settings → API & XC \
                and paste it in.
                  • The Server URL is reaching a different Dispatcharr \
                instance than the one whose API Key you copied (for \
                example, a public URL routed through a different vhost \
                than the LAN URL). Verify \(urlString) points at the \
                correct deployment.
                """
        } else if let authCode = firstAuthErrorCode {
            // Mixed outcome — some auth errors, some not. Could be a
            // misconfigured reverse proxy answering some routes and
            // not others, or a deployment quirk our auto-fallback
            // didn't anticipate. Surface what we saw.
            message = """
                Dispatcharr returned HTTP \(authCode) on the API probe \
                (\(urlString)). AerioTV auto-tried every supported \
                authentication header shape (X-API-Key, Authorization: \
                ApiKey, Authorization: Bearer); every shape was \
                rejected. Either the API Key is incorrect, the user \
                lacks Admin permissions on Dispatcharr 0.23.0+, or \
                this server requires a header shape AerioTV doesn't \
                yet know about. Confirm the key is from User Settings \
                → API & XC and the user is set to Admin in the \
                Permissions tab, and that the Server URL reaches the \
                same Dispatcharr deployment.
                """
        } else if anyHTML {
            message = """
                Dispatcharr returned the web UI instead of the API. \
                This usually means one of:
                  • Your API Key is missing or incorrect. In \
                Dispatcharr open User Settings → API & XC, copy the \
                API Key, and paste it into the Admin API Key field \
                above.
                  • The Server URL points at the web app but not at \
                the API (for example, a reverse proxy that strips or \
                rewrites /api). Verify the URL works by opening \
                \(urlString) in a browser while logged out. You \
                should see a JSON error, not the Dispatcharr login \
                page.
                  • The URL is correct but the port is wrong. Confirm \
                the port matches the Dispatcharr API port on your \
                server (the default is the same port as the web UI).
                """
        } else if Self.isCloudflareTunnelError(status: lastStatus, body: lastBodySnippet) {
            // v1.6.21: Cloudflare Tunnel / origin-unreachable errors.
            // When Dispatcharr sits behind a Cloudflare Tunnel (or
            // any Cloudflare proxy) and the origin container is
            // down, Cloudflare's edge returns HTTP 5xx (commonly
            // 530 / 521 / 522 / 523) with a body describing the
            // upstream failure. The user sees this as "AerioTV
            // can't connect" but the cause is on the server side,
            // not in the API key or AerioTV. Tell them to check
            // the origin container and the Tunnel daemon.
            let statusString = lastStatus.map(String.init) ?? "<unknown status>"
            message = """
                Cloudflare can't reach your Dispatcharr server (HTTP \
                \(statusString), Cloudflare error 1033 / Tunnel \
                error). The server URL and API Key are fine; the \
                issue is between Cloudflare and your origin. Most \
                common causes:
                  • Your Dispatcharr container is stopped or \
                unresponsive. Check `docker ps` and restart if \
                needed.
                  • Your `cloudflared` (Cloudflare Tunnel) daemon \
                stopped. Restart the tunnel service.
                  • Your origin host is offline or behind a firewall \
                that's blocking Cloudflare's connector.
                AerioTV can't fix this from the client side.
                """
        } else {
            // Genuine "other" outcome — non-HTML, non-auth-error,
            // non-JSON. Surface enough detail to diagnose without
            // pasting the entire HTML body.
            let ctString = lastContentType ?? "<unknown content-type>"
            let statusString = lastStatus.map(String.init) ?? "<unknown status>"
            let snippet = lastBodySnippet.isEmpty
                ? ""
                : " Body preview: \(lastBodySnippet.prefix(160))…"
            message = """
                Couldn't recognise the server response while verifying the \
                connection. Last attempted URL: \(urlString) \
                (status: \(statusString), content-type: \(ctString)).\(snippet)
                """
        }

        throw APIError.decodingError(NSError(
            domain: "DispatcharrAPI",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    /// SSRF guard for SERVER-SUPPLIED absolute URLs (pagination `next`,
    /// redirect `Location`) that we then re-issue with the user's auth
    /// headers attached. Without it a compromised/malicious Dispatcharr could
    /// paginate / 30x our API key to a loopback, RFC-1918, or cloud-metadata
    /// host (confused-deputy SSRF + credential delivery). Reuses the in-tree
    /// artwork validator (#53); the configured server host is always allowed
    /// (LAN-only Dispatcharr included). Returns nil to reject — which also
    /// cleanly ends the pagination loops (same as an absent `next`).
    private func validatedServerSuppliedURL(_ raw: String?) -> URL? {
        guard let raw, let parsed = URL(string: raw) else { return nil }
        return VODService.validateAbsoluteURL(parsed, serverHost: URL(string: baseURL)?.host)
    }

    // MARK: - Pagination helper
    private func fetchAllPages<T: Decodable>(_ type: T.Type, firstPath: String) async throws -> [T] {
        var allItems: [T] = []
        var nextURL: URL? = try buildURL(path: firstPath)
        while let url = nextURL {
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await loggedData(for: request)
            try validate(response: response, data: data)

            if let list = try? Self.jsonDecoder.decode([T].self, from: data) {
                allItems += list
                break
            }
            let wrapped = try decode(DispatcharrResultsWrapper<T>.self, from: data)
            allItems += wrapped.results
            if let next = validatedServerSuppliedURL(wrapped.next) {
                nextURL = next
            } else {
                nextURL = nil
            }
        }
        return allItems
    }

    // MARK: - Channels
    func getChannels() async throws -> [DispatcharrChannel] {
        // Dispatcharr's ChannelViewSet disables pagination when no `page` query param is present,
        // returning ALL channels in a single flat JSON array. This is faster than paginated requests
        // for large channel lists (2000+). fetchAllPages handles both flat array and paginated wrapper.
        try await fetchAllPages(DispatcharrChannel.self, firstPath: "/api/channels/channels/")
    }

    /// Fetches the channel ids that belong to a single Channel Profile.
    /// A Channel Profile is a curated subset of channels (e.g. a "Kids"
    /// profile with only age-appropriate channels). The REST endpoint
    /// `/api/channels/channels/` returns ALL channels regardless of the
    /// connected user's profile, so AerioTV filters the loaded list down
    /// to the union of the user's assigned profiles' memberships. This
    /// is a child-safety filter, so the caller fails open only on a
    /// fetch/decode error (logging a warning) and never silently widens
    /// the set on a successful-but-empty response.
    ///
    /// `/api/channels/profiles/<id>/` returns
    /// `{ id, name, channels: [<enabled channel ids>] }` where each
    /// entry matches `DispatcharrChannel.id`.
    func fetchChannelProfileChannelIDs(profileID: Int) async throws -> [Int] {
        /// Slim view of the profile detail response. Only `channels`
        /// (the enabled channel ids) is consumed; the rest is discarded.
        struct ProfileChannels: Decodable { let channels: [Int] }
        let url = try buildURL(path: "/api/channels/profiles/\(profileID)/")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decode(ProfileChannels.self, from: data).channels
    }

    /// One entry from `/api/channels/profiles/` -- a server-defined
    /// Channel Profile the user can choose to sync (Task #189, Android
    /// parity: `DispatcharrClient.listProfiles`). `channels` carries the
    /// member channel ids; the picker only shows its count.
    struct ChannelProfileSummary: Decodable, Identifiable {
        let id: Int
        let name: String
        let channels: [Int]
    }

    /// Lists the server's Channel Profiles for the Edit Playlist picker.
    /// Plain (non-paginated) array response, same shape Android's
    /// `listProfiles` consumes in production.
    func listChannelProfiles() async throws -> [ChannelProfileSummary] {
        let url = try buildURL(path: "/api/channels/profiles/")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decode([ChannelProfileSummary].self, from: data)
    }

    // MARK: - Lightweight channel summary (fast guide UI)
    func getChannelSummaries() async throws -> [DispatcharrChannelSummary] {
        try await fetchAllPages(DispatcharrChannelSummary.self, firstPath: "/api/channels/summary/")
    }

    // MARK: - EPG current programs (batch)
    /// Fetches current programs. Pass `channelUUIDs` to filter by specific channels, or nil for all.
    /// Note: the Dispatcharr endpoint expects `channel_uuids` (UUID strings), not integer IDs.
    func getCurrentPrograms(channelUUIDs: [String]? = nil) async throws -> [DispatcharrCurrentProgram] {
        // This endpoint only accepts POST — GET returns 405.
        let url = try buildURL(path: "/api/epg/current-programs/")
        // Explicit 20s timeout rather than URLSession's 60s default.
        // On large Dispatcharr instances this endpoint does a
        // full-scan of epg_programs to find each channel's currently-
        // airing row, which can take 30-60+s. The client had been
        // holding the connection open the entire time; when it
        // finally gave up and closed, the server-side uwsgi worker
        // stayed pinned trying to write the response into a dead
        // socket (the "broken pipe" log lines on the user's server).
        // 20s fails fast so the worker's kill-after-client-timeout
        // fires quickly too, freeing pool capacity for other
        // requests. Callers already treat failure as non-fatal.
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let uuids = channelUUIDs {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_uuids": uuids])
        } else {
            // Empty body = fetch current program for all channels.
            request.httpBody = try JSONSerialization.data(withJSONObject: [:])
        }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response)
        if let list = try? Self.jsonDecoder.decode([DispatcharrCurrentProgram].self, from: data) {
            return list
        }
        let wrapped = try decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: data)
        return wrapped.results
    }

    // MARK: - EPG Grid (guide view)
    /// Fetches the EPG grid from `/api/epg/grid/` — returns -1h to +24h of programs.
    /// The response is `{"data": [...]}` with program objects containing tvg_id, title,
    /// start_time, end_time, etc. One request replaces the multi-step approach.
    func getEPGGrid() async throws -> [DispatcharrCurrentProgram] {
        let url = try buildURL(path: "/api/epg/grid/")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // v1.6.22: bumped 60s → 180s for the request, 180s → 600s
        // for the resource. jesmannstl's 2,186-channel Dispatcharr
        // instance with 19,500+ EPGData rows serializes a grid
        // response so large that the upstream uWSGI worker needs
        // 90+ seconds to assemble it; the prior 60s fail-fast was
        // too aggressive. We also see `NSURLError -1017 cannot
        // parse response` when the reverse proxy gives up on the
        // upstream and returns a truncated body. Longer timeouts
        // give the server room to finish; the client-side cost of
        // a false-positive timeout is paying it once per launch
        // (the call is non-fatal: bulk grid failure falls through
        // to lazy per-cell on the Guide tab).
        request.timeoutInterval = 180
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        // v1.7.x: dataWithJWTRetry transparently refreshes the JWT
        // access token on 401 + retries once when in `.jwtSession`
        // auth mode. No-op for `.apiKey` / `.bearer` modes. The
        // dedicated 180s/600s session that previously lived here
        // (added v1.6.21 for slow Dispatcharr deployments) was
        // redundant after the dataWithJWTRetry migration: the
        // request's own `timeoutInterval = 180` (set above) covers
        // the per-request budget, and `Self.session` already has
        // `timeoutIntervalForResource = 600`. Removed the unused
        // local session in v1.7.x.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataWithJWTRetry(for: request)
        } catch let err as URLError where err.code.rawValue == -1017 {
            // v1.6.22: NSURLError -1017 "cannot parse response"
            // means the reverse proxy in front of Dispatcharr
            // (typically nginx) gave up on the upstream uWSGI
            // worker mid-response and returned a truncated body.
            // Surface a more actionable message than Foundation's
            // default. The user's server is overloaded; their
            // worker pool can't serialize the full 25-hour grid
            // in time. Retrying won't help unless they restart /
            // upgrade the container.
            debugLog("📺 getEPGGrid: HTTP -1017 (cannot parse response). Reverse proxy truncated the upstream response, almost always means the Dispatcharr container is overloaded and worker pool can't serialize the full grid. Retry won't help client-side; user needs to restart or scale their server.")
            throw err
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Try {"data": [...]} wrapper (current Dispatcharr format)
        if let dataWrapper = try? Self.jsonDecoder.decode(DispatcharrDataWrapper<DispatcharrCurrentProgram>.self, from: data) {
            return dataWrapper.data
        }
        // Try flat array
        if let list = try? Self.jsonDecoder.decode([DispatcharrCurrentProgram].self, from: data) {
            return list
        }
        // Try {"results": [...]} DRF wrapper
        let wrapped = try decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: data)
        return wrapped.results
    }

    /// Fetches every `EPGData` row from `/api/epg/epgdata/` and
    /// returns a map from the row's primary key to its `tvg_id`.
    ///
    /// Why this exists: `/api/epg/grid/` programs are keyed by the
    /// EPGData row's `tvg_id`, NOT by the channel's `tvg_id`.
    /// Channels link to EPGData via the `epg_data_id` integer FK,
    /// and on real instances 25% of channels have a `tvg_id` that
    /// disagrees with the EPGData row they point to (EPGData is
    /// set at XMLTV ingest time; Channel.tvg_id is
    /// user-configurable). Without resolving channels through
    /// `epg_data_id → EPGData.tvg_id`, those channels show up as
    /// blank rows in the guide because the grid lookup misses.
    /// ECM (Enhanced Channel Manager) uses this same pattern.
    ///
    /// EPGData can be very large (40k+ rows on a Schedules Direct
    /// + multi-source setup), so this paginates via fetchAllPages.
    /// Callers should cache the result for the life of the EPG
    /// fetch (it doesn't change between bulk grid calls).
    func getAllEPGData() async throws -> [Int: String] {
        var map: [Int: String] = [:]
        let rows = try await getAllEPGDataRows()
        map.reserveCapacity(rows.count)
        for row in rows where !row.tvgID.isEmpty {
            map[row.id] = row.tvgID
        }
        return map
    }

    /// The same rows, unreduced. GH #53 needs each row's `epg_source`
    /// as well as its `tvg_id`: an upstream XMLTV feed may only supply
    /// programmes for the channels Dispatcharr actually sourced FROM
    /// that feed, and `tvg_id` values (broadcaster strings, not GUIDs)
    /// collide freely across unrelated providers.
    func getAllEPGDataRows() async throws -> [DispatcharrEPGData] {
        try await fetchAllPages(DispatcharrEPGData.self,
                                firstPath: "/api/epg/epgdata/?page_size=500")
    }

    /// Fetches one program's rich detail (categories, rating, etc.)
    /// from `/api/epg/programs/<id>/`. v1.6.22 uses this to recover
    /// the `<category>` data that `/api/epg/grid/` deliberately
    /// strips, so the Live-TV "Tint Channel Cards" stripe and Guide
    /// grid cell tinting work on Dispatcharr-API mode without any
    /// XMLTV-stream dependency. API-only path. ~40ms per call on a
    /// typical Dispatcharr instance, so fanning out N=300+ for
    /// currently-airing programs at cap-of-4 concurrency completes
    /// in a few seconds in the background.
    func getProgramDetail(id: Int) async throws -> DispatcharrProgramDetail {
        let url = try buildURL(path: "/api/epg/programs/\(id)/")
        // v1.6.22: bumped 8s → 30s. The fan-out runs after a
        // successful bulk grid (which itself can take 90s+ on
        // overloaded servers). 8s was misaligned with that regime
        // and silently failed enrichment exactly when the grid
        // was already proving the server is responsive but slow.
        // 30s gives slow-but-alive servers room while still failing
        // fast enough on a truly dead one.
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        // v1.7.x: dataWithJWTRetry handles JWT refresh on 401.
        let (data, response) = try await dataWithJWTRetry(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try Self.jsonDecoder.decode(DispatcharrProgramDetail.self, from: data)
    }

    /// Bulk category enrichment: takes a set of program IDs and
    /// returns `[programID: categoriesString]`. Categories are
    /// joined with commas (matches the format `applyXMLTVCategories`
    /// expects). Throttled at cap-of-4 concurrency by an internal
    /// AsyncSemaphore so we don't hammer the upstream Dispatcharr
    /// uWSGI / Daphne pool. Errors per program are swallowed (we
    /// just skip enrichment for that one) so a single 5xx can't
    /// block the whole batch.
    func enrichCategories(programIDs: [Int]) async -> [Int: String] {
        guard !programIDs.isEmpty else { return [:] }
        let semaphore = AsyncSemaphore(value: 4)
        var results: [Int: String] = [:]
        await withTaskGroup(of: (Int, String?).self) { group in
            for pid in programIDs {
                group.addTask { [self] in
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    do {
                        let detail = try await getProgramDetail(id: pid)
                        let cats = detail.categories.joined(separator: ",")
                        return (pid, cats.isEmpty ? nil : cats)
                    } catch {
                        return (pid, nil)
                    }
                }
            }
            for await (pid, cats) in group {
                if let cats = cats { results[pid] = cats }
            }
        }
        return results
    }

    // MARK: - Upcoming programs (next N programs after the current one)
    // Per-channel fetch for on-demand use (e.g. user expands a single channel card).
    func getUpcomingPrograms(tvgIDs: [String]? = nil, channelIDs: [Int]? = nil, limit: Int = .max) async throws -> [DispatcharrCurrentProgram] {
        let tvgID = tvgIDs?.first ?? ""
        let channelID = channelIDs?.first

        let queryPath: String
        if !tvgID.isEmpty {
            let encoded = tvgID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tvgID
            queryPath = "/api/epg/programs/?tvg_id=\(encoded)&page_size=20"
        } else if let chID = channelID {
            queryPath = "/api/epg/programs/?channel=\(chID)&page_size=20"
        } else {
            return []
        }

        let url = try buildURL(path: queryPath)
        // v1.6.22: bumped 5s → 15s. The prior fail-fast was set
        // when per-cell prefetch raced the bulk grid on the same
        // worker pool; jesmannstl's overloaded server failed every
        // 5s call, tripping the circuit breaker before the bulk
        // grid even started. Now that `prefetchIfNeeded` waits for
        // `isLoading == false` (so it never races the bulk grid),
        // the per-cell budget can be more generous. 15s is short
        // enough to fail fast on a truly dead server and pair with
        // the circuit breaker, but long enough to succeed on a
        // slow-but-alive Dispatcharr that needs a few seconds per
        // channel-filtered programs query.
        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        let (data, response) = try await HTTPRouter.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        var allItems: [DispatcharrCurrentProgram] = []
        if let list = try? Self.jsonDecoder.decode([DispatcharrCurrentProgram].self, from: data) {
            allItems = list
        } else if let wrapped = try? decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: data) {
            allItems = wrapped.results
            var nextURL = validatedServerSuppliedURL(wrapped.next)
            var pagesLeft = 2
            while let pageURL = nextURL, pagesLeft > 0 {
                pagesLeft -= 1
                var req = URLRequest(url: pageURL)
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
                guard let (pageData, pageResp) = try? await HTTPRouter.data(for: req),
                      let pageHttp = pageResp as? HTTPURLResponse,
                      (200..<300).contains(pageHttp.statusCode) else { break }
                let page = try decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: pageData)
                allItems += page.results
                nextURL = validatedServerSuppliedURL(page.next)
            }
        }

        let now = Date()
        let upcoming = allItems.filter {
            if !tvgID.isEmpty {
                let progTvgID = $0.tvgID ?? ""
                if progTvgID.caseInsensitiveCompare(tvgID) != .orderedSame { return false }
            }
            if let chID = channelID {
                if let progChannel = $0.channel, progChannel != chID { return false }
            }
            guard let _ = $0.startTime?.toDate(),
                  let end = $0.endTime?.toDate() else { return false }
            // Include currently-airing programs (end > now), not just future ones
            return end > now
        }
        return limit == .max ? upcoming : Array(upcoming.prefix(limit))
    }

    // MARK: - Bulk upcoming programs (all channels at once)
    // Fetches ALL programs from /api/epg/programs/ in a time window using large pages.
    // This replaces 40+ per-channel requests with ~3–5 paginated requests.
    func getBulkUpcomingPrograms(maxPages: Int = 10) async throws -> [DispatcharrCurrentProgram] {
        // Fetch all programs with a large page size — no per-channel filter.
        // The server returns programs sorted by start_time by default.
        var allItems: [DispatcharrCurrentProgram] = []
        var nextURL: URL? = try buildURL(path: "/api/epg/programs/?page_size=1000")
        var pagesLeft = maxPages

        while let url = nextURL, pagesLeft > 0 {
            pagesLeft -= 1
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
            let (data, response) = try await HTTPRouter.data(for: request, using: Self.bulkEPGSession)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { break }

            if let list = try? Self.jsonDecoder.decode([DispatcharrCurrentProgram].self, from: data) {
                allItems += list
                break // flat array = no pagination
            } else if let wrapped = try? decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: data) {
                allItems += wrapped.results
                debugLog("📺 BulkEPG: page fetched, got \(wrapped.results.count) programs (total: \(allItems.count), hasNext: \(wrapped.next != nil))")
                if let next = validatedServerSuppliedURL(wrapped.next) {
                    nextURL = next
                } else {
                    nextURL = nil
                }
            } else {
                break
            }
        }

        debugLog("📺 BulkEPG: finished with \(allItems.count) total programs from \(maxPages - pagesLeft) pages")
        return allItems
    }

    // MARK: - VOD
    // Do NOT use ?no_pagination=true: some Dispatcharr builds preserve that param in every
    // DRF "next" link, causing fetchAllPages to loop through the full library while always
    // appending no_pagination=true. Rely on the next-link loop instead (same as getChannels).
    //
    // page_size: 25. Previously 100 — but on large VOD libraries
    // (tens of thousands of entries), Dispatcharr's per-page
    // serialization was slow enough that individual requests timed
    // out client-side while uwsgi workers stayed pinned serializing
    // into a closed socket (see broken-pipe logs on the testing
    // server). Smaller pages = faster per-request serialization =
    // workers freed quicker. More round trips, but each is cheap.
    func getVODMovies() async throws -> [DispatcharrVODMovie] {
        try await fetchAllPages(DispatcharrVODMovie.self, firstPath: "/api/vod/movies/?page_size=100")
    }

    /// v1.6.12: cheap library-size probe used by the AddServer
    /// "Setting Up" stage. Hits `/api/vod/movies/?page_size=1` and
    /// reads the DRF wrapper's `count` field (total library size)
    /// instead of paginating the whole thing. The previous Setting
    /// Up flow called `getVODMovies()` which paginates 25/page —
    /// for a 17 000-movie Dispatcharr library that's ~700
    /// sequential HTTP calls and 2–5 minutes of staring at "Loading
    /// VOD". XC's equivalent (`get_vod_streams`) returns the full
    /// list in one call, which is why XC users never saw this hang.
    /// Returns 0 if the count field is missing — a non-zero return
    /// Fetches the EPG sources configured on the Dispatcharr server
    /// from `/api/epg/sources/` (list permission is IsStandardUser,
    /// so any API key can read it). Catch-up depth: Dispatcharr's
    /// own grid only retains a couple of days of history, but the
    /// upstream XMLTV feeds it ingests usually carry a much deeper
    /// past window, so GuideStore fetches those URLs directly and
    /// layers them on the grid the same way the manual Custom XMLTV
    /// URL override is layered.
    func getEPGSources() async throws -> [DispatcharrEPGSource] {
        try await fetchAllPages(DispatcharrEPGSource.self, firstPath: "/api/epg/sources/")
    }

    /// value here is only used cosmetically to render the stage's
    /// "Loaded N movies" detail line.
    func getVODMovieCount() async throws -> Int {
        let url = try buildURL(path: "/api/vod/movies/?page_size=1")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        // DRF paginated wrapper carries `count` even when results is
        // [...one item...]. Tolerate flat-array responses too — some
        // older Dispatcharr builds return an unwrapped list, in which
        // case we fall back to `.count` of whatever we can decode
        // (defensive only — the modern API always wraps).
        if let wrapped = try? Self.jsonDecoder.decode(DispatcharrResultsWrapper<DispatcharrVODMovie>.self, from: data) {
            return wrapped.count ?? wrapped.results.count
        }
        if let list = try? Self.jsonDecoder.decode([DispatcharrVODMovie].self, from: data) {
            return list.count
        }
        return 0
    }

    /// Series counterpart to `getVODMovieCount`. Same rationale, same
    /// wrapper fallback.
    func getVODSeriesCount() async throws -> Int {
        let url = try buildURL(path: "/api/vod/series/?page_size=1")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        if let wrapped = try? Self.jsonDecoder.decode(DispatcharrResultsWrapper<DispatcharrVODSeries>.self, from: data) {
            return wrapped.count ?? wrapped.results.count
        }
        if let list = try? Self.jsonDecoder.decode([DispatcharrVODSeries].self, from: data) {
            return list.count
        }
        return 0
    }

    /// v1.6.12: per-movie rich-metadata fetch.
    /// Hits Dispatcharr's `/api/vod/movies/<id>/provider-info/` action,
    /// which is the only endpoint that returns cast/director/backdrop/
    /// runtime/full release-date for a movie. The list endpoint is
    /// deliberately slim (just typed columns) so a 1000-movie library
    /// doesn't ship a megabyte of TMDB blobs per page.
    ///
    /// **Latency note:** this endpoint is server-side throttled to 24h
    /// per movie. The first call for a movie that's never been
    /// visited synchronously triggers `refresh_movie_advanced_data`
    /// upstream — that contacts the Xtream provider for the metadata
    /// dictionary, which can take several seconds. Subsequent calls
    /// within 24h read the cached refresh and return immediately.
    /// Callers should treat this as best-effort enrichment: render
    /// whatever's available immediately, then upgrade fields when
    /// this returns.
    func getMovieProviderInfo(movieID: Int) async throws -> DispatcharrVODMovieProviderInfo {
        let url = try buildURL(path: "/api/vod/movies/\(movieID)/provider-info/")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decode(DispatcharrVODMovieProviderInfo.self, from: data)
    }

    /// v1.6.12: same lazy-refresh contract as `getMovieProviderInfo`,
    /// but for series. Hits `/api/vod/series/<id>/provider-info/`,
    /// which Dispatcharr names internally as `series_info()`. Same
    /// 24h server-side throttle, same first-call latency caveat —
    /// the FIRST call for a series that's never been visited
    /// triggers an upstream Xtream fetch via
    /// `refresh_series_advanced_data` and can take several seconds.
    func getSeriesProviderInfo(seriesID: Int) async throws -> DispatcharrVODSeriesProviderInfo {
        let url = try buildURL(path: "/api/vod/series/\(seriesID)/provider-info/")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decode(DispatcharrVODSeriesProviderInfo.self, from: data)
    }

    func getVODSeries() async throws -> [DispatcharrVODSeries] {
        try await fetchAllPages(DispatcharrVODSeries.self, firstPath: "/api/vod/series/?page_size=100")
    }

    /// Fetches VOD categories from `/api/vod/categories/`.
    /// Each category has a name and type (movie/series).
    func getVODCategories() async throws -> [DispatcharrVODCategory] {
        try await fetchAllPages(DispatcharrVODCategory.self, firstPath: "/api/vod/categories/")
    }

    // MARK: - Progressive VOD streams
    // Yields one page at a time so the UI can display partial results immediately
    // instead of waiting for the entire library to load. Critical for large libraries
    // (e.g. 20 000+ movies = 200 sequential API calls at page_size=100). The
    // smaller page size trades more round-trips for shorter per-worker hold time
    // on the Dispatcharr side — a single page_size=100 request was slow enough
    // on big libraries to pin a uwsgi worker for 10+ seconds, which under
    // concurrent load would saturate Dispatcharr's pool and freeze the
    // container.

    /// Paginated movie stream. When `category` is non-nil, appends
    /// `&category=<url-encoded-name>` so Dispatcharr returns only
    /// movies tagged with that category. Confirmed in the API schema
    /// that `/api/vod/movies/` accepts `category` as a name filter
    /// (the value is the category NAME, not its id — IDs are silently
    /// ignored). Used by `VODStore` to fetch one stream per
    /// user-enabled category and tag each movie with its real
    /// Dispatcharr category name at ingest time — fixes GH #1 where
    /// `categoryName` was previously parsed from the movie's `genre`
    /// string and therefore never matched the category picker.
    /// `itemCap` overrides the default per-stream `vodPaginationItemCap`.
    /// VODStore passes a per-category fair share so one big category can't
    /// drain the whole memory budget and starve later enabled categories.
    func getVODMoviesStream(category: String? = nil, itemCap: Int? = nil) -> AsyncThrowingStream<[DispatcharrVODMovie], Error> {
        makePageStream(firstPath: Self.moviesPath(category: category), itemCap: itemCap)
    }

    func getVODSeriesStream(category: String? = nil, itemCap: Int? = nil) -> AsyncThrowingStream<[DispatcharrVODSeries], Error> {
        makePageStream(firstPath: Self.seriesPath(category: category), itemCap: itemCap)
    }

    private static func moviesPath(category: String?) -> String {
        guard let category, !category.isEmpty else {
            return "/api/vod/movies/?page_size=100"
        }
        // Dispatcharr's MovieFilter.filter_category matches
        // `m3u_relations__category__name` AND `category_type` when the
        // value is `name|type`. A bare name is ambiguous (the same name
        // can exist for both a movie and a series category, unique only
        // on name+type), so pin the movie type. The `|`
        // percent-encodes to %7C inside the query value.
        let typed = category.contains("|") ? category : "\(category)|movie"
        let encoded = typed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? typed
        return "/api/vod/movies/?page_size=100&category=\(encoded)"
    }

    private static func seriesPath(category: String?) -> String {
        guard let category, !category.isEmpty else {
            return "/api/vod/series/?page_size=100"
        }
        // Same name|type filter as movies; pin the series type.
        let typed = category.contains("|") ? category : "\(category)|series"
        let encoded = typed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? typed
        return "/api/vod/series/?page_size=100&category=\(encoded)"
    }

    /// Query-VALUE-safe percent encoding. `.urlQueryAllowed` describes the
    /// whole query STRING, so it leaves "&" and "+" bare; a title like
    /// "Law & Order" then truncates the DRF ?search= value server-side and
    /// the search silently misses.
    private static func encodeQueryValue(_ raw: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// Server-side search — uses DRF's ?search= filter so items not yet locally fetched are found.
    func searchVODMoviesStream(query: String) -> AsyncThrowingStream<[DispatcharrVODMovie], Error> {
        let encoded = Self.encodeQueryValue(query)
        return makePageStream(firstPath: "/api/vod/movies/?search=\(encoded)&page_size=100")
    }

    func searchVODSeriesStream(query: String) -> AsyncThrowingStream<[DispatcharrVODSeries], Error> {
        let encoded = Self.encodeQueryValue(query)
        return makePageStream(firstPath: "/api/vod/series/?search=\(encoded)&page_size=100")
    }

    /// Hard cap on total items returned by a single paginated stream.
    /// v1.6.21: real-world probing of a self-hosted Dispatcharr 0.23.0
    /// found a VOD library with `count: 351,644` movies and 85,446
    /// series. Paginating the full library at 25 items/page = 14k+
    /// sequential pages = many hours of HTTP work, and any sustained
    /// load stalls the server's worker pool. Most users have well
    /// under 5k VOD items per type; this cap protects against
    /// pathological setups while keeping the typical experience
    /// unchanged. The cap is per-call, so per-category fetches each
    /// get their own 5,000-item budget.
    static let vodPaginationItemCap = 5_000

    /// Generic paginated stream — yields `[T]` for each DRF results page.
    ///
    /// **v1.6.21 changes:**
    ///
    /// - **Concurrency gate.** Previously this method created its own
    ///   `URLSession` (with a 30s request timeout), which bypassed the
    ///   shared `Self.session` and therefore the v1.6.21
    ///   `concurrencyGate` semaphore. On a Dispatcharr instance with a
    ///   large library, two paginated streams (movies + series) would
    ///   independently hammer the server with their own connection
    ///   pools. We now route through the shared session via
    ///   `loggedData(for:)` so every paginated request counts against
    ///   the global 4-concurrent cap.
    ///
    /// - **Circuit breaker.** When a page fetch times out, stop the
    ///   stream and surface a clear timeout error rather than burning
    ///   the full per-request timeout × N pages waiting on a server
    ///   that's already overwhelmed. Non-timeout errors (4xx, decoding
    ///   failures) terminate immediately as before.
    ///
    /// - **Item cap.** Stops paginating after `vodPaginationItemCap`
    ///   items have been yielded. Real-world repro on a 351k-movie
    ///   server: even with 4-concurrent gating, the full library
    ///   would take 12+ hours to enumerate, and the user would never
    ///   actually scroll through that many entries. The cap surfaces
    ///   a usable subset immediately. When the cap is hit, the
    ///   stream finishes successfully (not as an error) so the UI
    ///   shows what we did fetch.
    private func makePageStream<T: Decodable & Sendable>(firstPath: String, itemCap: Int? = nil) -> AsyncThrowingStream<[T], Error> {
        return AsyncThrowingStream { [self] continuation in
            Task {
                let pageItemCap = itemCap ?? Self.vodPaginationItemCap
                guard var nextURL = try? buildURL(path: firstPath) else {
                    continuation.finish(throwing: APIError.invalidURL)
                    return
                }
                /// Consecutive timeout count for the circuit breaker.
                /// Resets on any successful page; trips at 3.
                var consecutiveTimeouts = 0
                let timeoutBreakerLimit = 3
                /// Running total of items yielded so far. Compared
                /// against `vodPaginationItemCap` after every page
                /// to gate the next iteration.
                var totalYielded = 0
                while true {
                    var request = URLRequest(url: nextURL)
                    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    let (data, response): (Data, URLResponse)
                    do {
                        // Routes through the shared session +
                        // concurrencyGate via loggedData(for:).
                        (data, response) = try await loggedData(for: request)
                    } catch let err {
                        if Self.isTimeoutError(err) {
                            consecutiveTimeouts += 1
                            if consecutiveTimeouts >= timeoutBreakerLimit {
                                debugLog("📺 VOD pagination: CIRCUIT BREAKER tripped after \(timeoutBreakerLimit) consecutive timeouts on \(firstPath)")
                                continuation.finish(throwing: err)
                                return
                            }
                            // Skip this page, advance via the same URL?
                            // Without a `next` link we can't progress, so
                            // bail. The breaker prevents this turning
                            // into an infinite retry loop. One timeout
                            // here means we lose at most 3 pages of data.
                            debugLog("📺 VOD pagination: timeout \(consecutiveTimeouts)/\(timeoutBreakerLimit) on \(firstPath), aborting")
                            continuation.finish(throwing: err)
                            return
                        }
                        continuation.finish(throwing: err)
                        return
                    }

                    consecutiveTimeouts = 0

                    do {
                        guard let http = response as? HTTPURLResponse else {
                            continuation.finish(throwing: APIError.invalidResponse); return
                        }
                        switch http.statusCode {
                        case 200...299: break
                        case 401, 403:
                            continuation.finish(throwing: APIError.unauthorized); return
                        case 404:
                            if let text = String(data: data, encoding: .utf8),
                               text.contains("No User matches") {
                                continuation.finish(throwing: APIError.unauthorized)
                            } else {
                                continuation.finish(throwing: APIError.serverError(404))
                            }
                            return
                        default:
                            continuation.finish(throwing: APIError.serverError(http.statusCode)); return
                        }

                        // Flat array (non-paginated response)
                        if let list = try? Self.jsonDecoder.decode([T].self, from: data) {
                            if !list.isEmpty { continuation.yield(list) }
                            continuation.finish(); return
                        }
                        // DRF paginated wrapper
                        let wrapped = try Self.jsonDecoder.decode(DispatcharrResultsWrapper<T>.self, from: data)
                        if !wrapped.results.isEmpty {
                            continuation.yield(wrapped.results)
                            totalYielded += wrapped.results.count
                        }
                        // v1.6.21 item cap: stop paginating once we've
                        // yielded enough items for the typical user.
                        // The library may have many more, but enumerating
                        // every page costs hours on pathological setups
                        // and the user wouldn't scroll through them
                        // anyway. Finishes the stream cleanly so the
                        // already-yielded items show up in the UI.
                        if totalYielded >= pageItemCap {
                            let serverTotal = wrapped.count.map { "\($0)" } ?? "unknown"
                            debugLog("📺 VOD pagination: hit item cap \(pageItemCap) for \(firstPath) (server reported total: \(serverTotal))")
                            continuation.finish()
                            return
                        }
                        if let next = validatedServerSuppliedURL(wrapped.next) {
                            nextURL = next
                        } else {
                            continuation.finish(); return
                        }
                    } catch let err as APIError {
                        continuation.finish(throwing: err); return
                    } catch {
                        continuation.finish(throwing: error); return
                    }
                }
            }
        }
    }

    /// v1.6.21: detects Cloudflare Tunnel / origin-unreachable
    /// responses (HTTP 5xx with a body that names a Cloudflare
    /// 1xxx error code). When Dispatcharr sits behind Cloudflare
    /// and the origin is dead, the user sees a generic "couldn't
    /// recognise the response" message that buries the real
    /// cause; surfacing the Cloudflare angle saves them
    /// debugging the wrong layer.
    ///
    /// Detection signals (any one is sufficient):
    ///  - Status 530 with body containing "cloudflare-1xxx"
    ///  - Body contains "Error 1033" / "Error 1016" / "Error 521"
    ///    / "Error 522" / "Error 523" / "Error 524" (the canonical
    ///    Cloudflare origin-failure codes)
    ///  - Body contains "cloudflare.com/support/troubleshooting/
    ///    http-status-codes"
    private static func isCloudflareTunnelError(status: Int?, body: String) -> Bool {
        guard let status, status >= 500 else { return false }
        let lower = body.lowercased()
        if lower.contains("cloudflare-1xxx") { return true }
        if lower.contains("cloudflare.com/support/troubleshooting/http-status-codes") { return true }
        for code in ["1033", "1016", "521", "522", "523", "524"] {
            if lower.contains("error \(code)") || lower.contains("error-\(code)") {
                return true
            }
        }
        return false
    }

    /// True if an error is a request timeout (URLError.timedOut /
    /// NSURLErrorTimedOut). Used by the v1.6.21 VOD pagination
    /// circuit breaker so it only trips on server-unresponsive
    /// signals and keeps going through transient 4xx/5xx-style
    /// failures (which it doesn't see anyway because those are
    /// surfaced as APIError).
    fileprivate static func isTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        return false
    }

    func getVODSeriesEpisodes(seriesID: Int) async throws -> [DispatcharrVODEpisode] {
        // v1.6.16: parallel page fetch. Pre-1.6.16 this used the
        // sequential `fetchAllPages` helper which walks `next` URLs
        // one at a time — fine for a 75-episode series (1 page) but
        // a disaster for One Piece (1000+ episodes, 10+ pages, 2+
        // minutes of round-trips). Dispatcharr's wrapper exposes
        // `count` on every page, so after the first page we know
        // exactly how many more pages exist and can fetch them
        // concurrently via TaskGroup.
        //
        // Falls back to sequential `next`-walking when `count` is
        // missing (older Dispatcharr versions or cursor pagination).
        let started = Date()
        let pageSize = 100
        debugLog("[VOD-Episodes] start seriesID=\(seriesID) pageSize=\(pageSize)")
        let firstPage: DispatcharrResultsWrapper<DispatcharrVODEpisode>
        do {
            firstPage = try await fetchEpisodesPage(seriesID: seriesID,
                                                     page: 1,
                                                     pageSize: pageSize)
        } catch {
            debugLog("[VOD-Episodes] page=1 FAIL seriesID=\(seriesID) error=\(error)")
            throw error
        }
        var allItems = firstPage.results
        debugLog("[VOD-Episodes] page=1 OK seriesID=\(seriesID) results=\(firstPage.results.count) reportedCount=\(firstPage.count.map(String.init) ?? "nil") next=\(firstPage.next != nil)")

        // Dispatcharr's pagination wrapper includes `count` (total
        // items) — preferred path: compute the page count and fan
        // out concurrent requests for pages 2..N.
        if let total = firstPage.count, total > allItems.count {
            let totalPages = Int(ceil(Double(total) / Double(pageSize)))
            if totalPages > 1 {
                debugLog("[VOD-Episodes] parallel fan-out seriesID=\(seriesID) total=\(total) totalPages=\(totalPages)")
                let extras: [(Int, [DispatcharrVODEpisode])]
                do {
                    extras = try await withThrowingTaskGroup(of: (Int, [DispatcharrVODEpisode]).self) { group -> [(Int, [DispatcharrVODEpisode])] in
                        for page in 2...totalPages {
                            group.addTask {
                                do {
                                    let p = try await self.fetchEpisodesPage(seriesID: seriesID,
                                                                               page: page,
                                                                               pageSize: pageSize)
                                    debugLog("[VOD-Episodes] page=\(page) OK seriesID=\(seriesID) results=\(p.results.count)")
                                    return (page, p.results)
                                } catch {
                                    debugLog("[VOD-Episodes] page=\(page) FAIL seriesID=\(seriesID) error=\(error)")
                                    throw error
                                }
                            }
                        }
                        var collected: [(Int, [DispatcharrVODEpisode])] = []
                        for try await pair in group { collected.append(pair) }
                        // Re-sort by page index so caller-side seasonNumber
                        // / episodeNumber sorts stay deterministic.
                        return collected.sorted { $0.0 < $1.0 }
                    }
                } catch {
                    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                    debugLog("[VOD-Episodes] FAN-OUT FAIL seriesID=\(seriesID) elapsed=\(elapsed)ms error=\(error)")
                    throw error
                }
                for (_, results) in extras {
                    allItems.append(contentsOf: results)
                }
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            debugLog("[VOD-Episodes] DONE (parallel) seriesID=\(seriesID) episodes=\(allItems.count) elapsed=\(elapsed)ms")
            return allItems
        }

        // Compatibility path: no `count` field — walk `next` URLs
        // sequentially. This is the original `fetchAllPages` flow
        // preserved for older Dispatcharr versions that may strip
        // `count` from the response wrapper.
        debugLog("[VOD-Episodes] no count — falling back to sequential next-walk seriesID=\(seriesID)")
        var nextURLString = firstPage.next
        var pageIdx = 2
        while let nextURL = validatedServerSuppliedURL(nextURLString) {
            do {
                var request = URLRequest(url: nextURL)
                headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                let (data, response) = try await loggedData(for: request)
                try validate(response: response, data: data)
                let wrapped = try decode(DispatcharrResultsWrapper<DispatcharrVODEpisode>.self, from: data)
                debugLog("[VOD-Episodes] page=\(pageIdx) OK (sequential) seriesID=\(seriesID) results=\(wrapped.results.count)")
                allItems.append(contentsOf: wrapped.results)
                nextURLString = wrapped.next
                pageIdx += 1
            } catch {
                debugLog("[VOD-Episodes] page=\(pageIdx) FAIL (sequential) seriesID=\(seriesID) error=\(error)")
                throw error
            }
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        debugLog("[VOD-Episodes] DONE (sequential) seriesID=\(seriesID) episodes=\(allItems.count) elapsed=\(elapsed)ms")
        return allItems
    }

    /// Helper for `getVODSeriesEpisodes` — fetch a specific
    /// numbered page and return the raw wrapper. Kept private here
    /// because the parallel-fan-out logic is specific to the
    /// episodes endpoint; other paginated endpoints still use the
    /// sequential `fetchAllPages` helper.
    private func fetchEpisodesPage(seriesID: Int,
                                    page: Int,
                                    pageSize: Int) async throws -> DispatcharrResultsWrapper<DispatcharrVODEpisode> {
        let path = "/api/vod/series/\(seriesID)/episodes/?page=\(page)&page_size=\(pageSize)"
        let url = try buildURL(path: path)
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        // Some endpoints return a flat array when there's only one
        // page worth of items. Normalise to the wrapper shape so
        // the caller can branch on `count` uniformly.
        if let flat = try? Self.jsonDecoder.decode([DispatcharrVODEpisode].self, from: data) {
            return DispatcharrResultsWrapper(results: flat, next: nil, count: flat.count)
        }
        return try decode(DispatcharrResultsWrapper<DispatcharrVODEpisode>.self, from: data)
    }

    // MARK: - Proxy stream URLs
    func proxyMovieURL(uuid: String, preferredStreamID: Int? = nil) -> URL? {
        // Trailing slash helps Django/DRF route matching and avoids extra redirects in some setups.
        var urlString = baseURL + "/proxy/vod/movie/\(uuid)"
        if let sid = preferredStreamID {
            urlString += "?stream_id=\(sid)"
        }
        return URL(string: urlString)
    }

    func proxyEpisodeURL(uuid: String, preferredStreamID: Int? = nil) -> URL? {
        // Dispatcharr commonly redirects this to a session URL: /proxy/vod/episode/<uuid>/<session>
        var urlString = baseURL + "/proxy/vod/episode/\(uuid)"
        if let sid = preferredStreamID {
            urlString += "?stream_id=\(sid)"
        }
        return URL(string: urlString)
    }

    // MARK: - Live TV proxy URLs (FFmpeg)

    /// MPEG-TS stream by *stream UUID* (works for direct playback; may bypass Dispatcharr failover logic).
    func proxyTSStreamURL(uuid: String) -> URL? {
        // v1.7.x: pin `?output_format=mpegts` so an admin-set per-user /
        // server fmp4 default can't change the container under our
        // libmpv TS path (Dispatcharr v0.25.0+). Harmless on older servers.
        let urlString = baseURL + "/proxy/ts/stream/\(uuid)?output_format=mpegts"
        return URL(string: urlString)
    }

    /// MPEG-TS stream by *channel UUID* (preferred for reliability + server-side failover).
    /// This keeps iOS tied to the channel container so Dispatcharr can fail over between providers/streams.
    func proxyTSChannelURL(channelUUID: String) -> URL? {
        // v1.7.x: same `output_format=mpegts` pin as proxyTSStreamURL.
        let urlString = baseURL + "/proxy/ts/channel/\(channelUUID)?output_format=mpegts"
        return URL(string: urlString)
    }

    /// Build ordered live-stream URL attempts for a Dispatcharr channel.
    /// HLS first (adaptive bitrate, better buffering), then TS as fallback.
    /// The /proxy/ts/channel/ endpoint doesn't exist in Dispatcharr — skip it.
    func liveProxyURLAttempts(for channel: DispatcharrChannel) -> [URL] {
        guard let uuid = channel.uuid, !uuid.isEmpty else { return [] }
        var out: [URL] = []
        // HLS preferred — adaptive bitrate handles network jitter better than raw TS
        if let u = URL(string: baseURL + "/proxy/hls/stream/\(uuid).m3u8") { out.append(u) }
        if let u = URL(string: baseURL + "/proxy/hls/stream/\(uuid)") { out.append(u) }
        // TS fallback — direct MPEG-TS stream
        if let u = proxyTSStreamURL(uuid: uuid) { out.append(u) }
        return out
    }

    /// True when [url] points at one of the user's OWN server hosts (the
    /// fetch-time base plus every configured server's public + LAN host).
    /// The auth boundary for playback URLs: Dispatcharr's 301 hands back a
    /// one-time session URL that needs no further auth, so anything that
    /// resolved OFF the server's own hosts must never receive the API key
    /// (Android parity: AerioTV-Android ee06e17, audit finding #38 - a
    /// hostile server response or cleartext-LAN MITM could otherwise
    /// bounce the key to an arbitrary public third-party host, which
    /// `validateAbsoluteURL` deliberately permits for playback).
    func isOwnHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let own = URL(string: baseURL)?.host?.lowercased(), host == own {
            return true
        }
        return VODService.knownOwnHosts().contains(host)
    }

    /// Resolve Dispatcharr proxy URLs that redirect to a session-based path.
    /// Some media players (and some CDN/proxy setups) behave better when given the final URL up-front.
    func resolveFinalURLForPlayback(_ url: URL) async throws -> URL {
        var current = url
        var redirects = 0

        while redirects < 5 {
            var req = URLRequest(url: current)
            // Use a tiny ranged GET so servers that don’t support HEAD still respond quickly.
            req.httpMethod = "GET"
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            // Auth rides only to the server's own hosts; a foreign hop
            // (already vetted against private/loopback ranges below) gets
            // an anonymous probe - session URLs need no auth, and the API
            // key must never be replayed off-origin.
            if isOwnHost(current) {
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            } else {
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }

            // Prevent URLSession from auto-following so we can capture the redirected Location.
            let (data, response) = try await session.data(for: req, delegate: RedirectBlocker())
            guard let http = response as? HTTPURLResponse else { return current }

            if (300...399).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: loc, relativeTo: current)?.absoluteURL,
               let safeNext = VODService.validateAbsoluteURL(next, serverHost: URL(string: baseURL)?.host) {
                // SSRF guard: never follow a redirect to a loopback/private/
                // metadata host with the API key attached. A rejected 3xx falls
                // through to `return response.url ?? current` (last-good URL).
                current = safeNext
                redirects += 1
                continue
            }

            // If we got a playable 2xx/206 response, use the final request URL.
            if (200...299).contains(http.statusCode) {
                // Some servers may return an empty body for the first ranged request; that’s fine.
                _ = data
                return response.url ?? current
            }

            // Auth failures should still surface clearly.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.unauthorized
            }

            // Any other status: bail with the current URL.
            return response.url ?? current
        }

        return current
    }

    /// URLSession delegate that blocks automatic redirects so we can inspect Location.
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: - Channel Groups
    func getChannelGroups() async throws -> [DispatcharrChannelGroup] {
        // Omit page param — Dispatcharr returns all groups unpaginated when no page param is present.
        // fetchAllPages handles both flat-array and paginated responses transparently.
        try await fetchAllPages(DispatcharrChannelGroup.self, firstPath: "/api/channels/groups/")
    }

    // MARK: - M3U Export URL
    func m3uURL(userID: Int? = nil) -> URL? {
        var path = "/output/m3u"
        if let id = userID { path += "?user_id=\(id)" }
        return URL(string: baseURL + path)
    }

    // MARK: - Recordings / DVR
    //
    // Dispatcharr DVR maps to `apps/channels/api_urls.py` — recordings
    // ViewSet at `/api/channels/recordings/`. Schedule with a POST, poll
    // with a GET, stop in-flight with POST /{id}/stop/, cancel or delete
    // with DELETE /{id}/, stream the file via GET /{id}/file/ (AllowAny,
    // HTTP Range — safe to hand straight to MPV).
    //
    // **Pre/post-roll gotcha:** If the POST body includes
    // `custom_properties.program` (a dict), Dispatcharr's serializer
    // applies the server's *global* pre/post offset on top. When the user
    // picks a per-recording buffer in AerioTV, we must ALREADY have
    // adjusted `start_time`/`end_time` on the client AND omit the
    // `program` key (we still set title/description as flat keys so the
    // admin UI shows metadata). Callers should honor that by calling
    // `createRecording` with `applyServerOffsets: false` when the user
    // has chosen a custom buffer.

    /// Dispatcharr-native recording object. Only the fields we actually
    /// consume are exposed here — `custom_properties` is a free-form
    /// JSON dict, so we parse it via JSONSerialization on a per-instance
    /// basis rather than defining a rigid Codable shape that would
    /// break when the server adds new keys.
    struct Recording: Sendable {
        let id: Int
        let channel: Int
        let startTime: Date
        let endTime: Date
        let taskID: String?
        let status: String?
        let filePath: String?
        let fileName: String?
        /// Server-provided playback URL (relative path, e.g.
        /// `/api/channels/recordings/<id>/file/` for completed
        /// recordings, or `/api/channels/recordings/<id>/hls/index.m3u8`
        /// for in-progress ones once the new DVR pipeline is enabled
        /// on the server). v1.6.22: replaced our hardcoded
        /// `/file/` URL with this server-provided value so we can
        /// hand mpv the right URL whether the recording is still
        /// being captured or already finalized. Nil on older
        /// Dispatcharr deployments that don't emit this field;
        /// callers should fall back to the constructed `/file/`
        /// path in that case.
        let fileURL: String?
        let programTitle: String?
        let programDescription: String?
        let comskip: Bool

        /// Parses a single recording out of an already-deserialized JSON
        /// object. Returns nil if required fields are missing.
        init?(dict: [String: Any]) {
            guard let id = dict["id"] as? Int,
                  let channel = dict["channel"] as? Int,
                  let startStr = dict["start_time"] as? String,
                  let endStr = dict["end_time"] as? String else {
                return nil
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            func parseDate(_ s: String) -> Date? {
                iso.date(from: s) ?? isoPlain.date(from: s)
            }
            guard let start = parseDate(startStr), let end = parseDate(endStr) else {
                return nil
            }
            self.id = id
            self.channel = channel
            self.startTime = start
            self.endTime = end
            self.taskID = dict["task_id"] as? String

            let props = dict["custom_properties"] as? [String: Any] ?? [:]
            self.status = props["status"] as? String
            self.filePath = props["file_path"] as? String
            self.fileName = props["file_name"] as? String
            // v1.6.22: prefer `output_file_url` if present (the
            // remuxed final file for completed recordings). Both
            // are populated by the new DVR pipeline; for in-progress
            // recordings only `file_url` is set and points at the
            // HLS playlist. Older Dispatcharr builds emit only
            // `file_url`, also fine.
            self.fileURL = (props["output_file_url"] as? String)
                ?? (props["file_url"] as? String)
            if let program = props["program"] as? [String: Any] {
                self.programTitle = program["title"] as? String
                self.programDescription = program["description"] as? String
            } else {
                self.programTitle = props["title"] as? String
                self.programDescription = props["description"] as? String
            }
            self.comskip = (props["comskip"] as? Bool) ?? false
        }
    }

    /// Schedules a new recording on the Dispatcharr server.
    ///
    /// - Parameters:
    ///   - channelID: Dispatcharr integer channel ID (NOT the UUID some
    ///     other code paths use — the DRF serializer rejects UUIDs).
    ///   - startTime: Effective start. If `applyServerOffsets` is false
    ///     this should already include the user's pre-roll adjustment.
    ///   - endTime: Effective end. Same rule for post-roll.
    ///   - title: Program title (written into `custom_properties`).
    ///   - description: Program description.
    ///   - applyServerOffsets: When true, the `program` subdict is sent
    ///     and Dispatcharr applies its global pre/post offsets on top.
    ///     When false, we flatten title/description and omit `program`
    ///     so the server leaves our start/end alone.
    /// - Returns: The created `Recording`.
    func createRecording(channelID: Int,
                         startTime: Date,
                         endTime: Date,
                         title: String,
                         description: String,
                         applyServerOffsets: Bool,
                         comskip: Bool = false) async throws -> Recording {
        let url = try buildURL(path: "/api/channels/recordings/")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var customProps: [String: Any] = [:]
        if applyServerOffsets {
            // Server will read program.start_time/end_time and apply its
            // configured DVR offsets. We pass our own start/end as the
            // program window so the server's math lines up.
            customProps["program"] = [
                "title": title,
                "description": description,
                "start_time": iso.string(from: startTime),
                "end_time": iso.string(from: endTime)
            ]
        } else {
            // We've already adjusted start/end on the client; omit the
            // `program` key so Dispatcharr doesn't double-apply offsets.
            // Flatten title/description so the admin UI still shows them.
            customProps["title"] = title
            customProps["description"] = description
        }
        if comskip {
            customProps["comskip"] = true
        }

        let body: [String: Any] = [
            "channel": channelID,
            "start_time": iso.string(from: startTime),
            "end_time": iso.string(from: endTime),
            "custom_properties": customProps
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decodeRecording(from: data)
    }

    /// Lists all recordings on the server. Filter client-side on status.
    func listRecordings() async throws -> [Recording] {
        let url = try buildURL(path: "/api/channels/recordings/")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decodeRecordingArray(from: data)
    }

    /// Fetches a single recording by ID — used for polling status during
    /// an in-progress recording.
    func getRecording(id: Int) async throws -> Recording {
        let url = try buildURL(path: "/api/channels/recordings/\(id)/")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decodeRecording(from: data)
    }

    /// Stops an in-flight recording early, keeping the partial file on
    /// disk. If the user wants the partial gone, follow up with
    /// `deleteRecording`.
    func stopRecording(id: Int) async throws {
        let url = try buildURL(path: "/api/channels/recordings/\(id)/stop/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
    }

    /// Deletes a recording. For scheduled rows this is a plain cancel;
    /// for completed rows Dispatcharr also removes the file from disk,
    /// so there is no "keep but unschedule" path — the file is gone
    /// after this call.
    func deleteRecording(id: Int) async throws {
        let url = try buildURL(path: "/api/channels/recordings/\(id)/")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
    }

    // MARK: - Switch Stream

    /// Lists a channel's member streams, highest priority first, keyed by
    /// the channel's INTEGER pk (`DispatcharrChannel.id`, NOT the uuid).
    /// Dispatcharr returns a plain JSON array; we also tolerate a paginated
    /// `{ "results": [...] }` envelope in case the server pages this route.
    func getChannelStreams(channelID: Int) async throws -> [DispatcharrStream] {
        let url = try buildURL(path: "/api/channels/channels/\(channelID)/streams/")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        if let arr = try? Self.jsonDecoder.decode([DispatcharrStream].self, from: data) {
            return arr
        }
        return try decode(DispatcharrResultsWrapper<DispatcharrStream>.self, from: data).results
    }

    /// Switches the channel's active upstream. Keyed by the channel UUID
    /// (the same `<uuid>` used in `/proxy/ts/stream/<uuid>`). Server-side
    /// `@permission_classes([IsAdmin])` — a non-admin account gets 403.
    /// Dispatcharr swaps the upstream in place behind the unchanged proxy
    /// connection (a mid-stream TS discontinuity, no EOF); libmpv follows
    /// it on its own, so the caller does NOT reload the player after this.
    @discardableResult
    func changeStream(channelUUID: String, streamID: Int) async throws -> String? {
        let url = try buildURL(path: "/proxy/ts/change_stream/\(channelUUID)")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["stream_id": streamID])
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        // The response carries the resolved upstream `url` Dispatcharr switched
        // to plus an `owner` flag. We confirm the switch by polling /status.url
        // against the url (the event-path bug leaves stream_id stale, so url is
        // the only trustworthy signal). `owner` tells us whether this request
        // hit the channel's owner worker — only then does Dispatcharr rewrite
        // the stream_id its Stats card reads, so we log it to explain any
        // lingering Stats staleness. Best-effort decode; nil just skips the gate.
        let decoded = try? Self.jsonDecoder.decode(DispatcharrChangeStreamResponse.self, from: data)
        let ownerStr = decoded?.owner.map(String.init) ?? "unknown"
        debugLog("[SwitchStream] change_stream stream_id=\(streamID) owner=\(ownerStr) (owner=true → Stats reflects; owner=false → Stats stays stale until re-tune)")
        return decoded?.url
    }

    /// Reads `/proxy/ts/status/<uuid>` for the channel's live upstream.
    /// `url` is reliably updated on a stream switch; `streamID` is NOT (the
    /// owner:false event path never rewrites it, so it stays stale ~20s) —
    /// use it only to seed the current-stream mark before any in-session
    /// switch, never to confirm one.
    func getChannelStatus(channelUUID: String) async throws -> DispatcharrChannelStatus {
        let url = try buildURL(path: "/proxy/ts/status/\(channelUUID)")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        return try decode(DispatcharrChannelStatus.self, from: data)
    }

    /// Lists the server's M3U source accounts so a stream's `m3u_account`
    /// integer id can be resolved to a display name (the source label the
    /// Dispatcharr WebUI shows). Admin endpoint; tolerates a `results`
    /// envelope as well as a plain array.
    func getM3UAccounts() async throws -> [DispatcharrM3UAccount] {
        let url = try buildURL(path: "/api/m3u/accounts/")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
        if let arr = try? Self.jsonDecoder.decode([DispatcharrM3UAccount].self, from: data) {
            return arr
        }
        return try decode(DispatcharrResultsWrapper<DispatcharrM3UAccount>.self, from: data).results
    }

    /// Triggers comskip (commercial detection/removal) on a completed
    /// recording. Dispatcharr handles the processing server-side.
    func applyComskip(id: Int) async throws {
        let url = try buildURL(path: "/api/channels/recordings/\(id)/comskip/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await loggedData(for: request)
        try validate(response: response, data: data)
    }

    /// Playback URL for a completed recording. The endpoint is
    /// `AllowAny` on the server (no auth), supports HTTP Range, and
    /// serves the raw media file — safe to hand directly to MPV.
    func recordingPlaybackURL(id: Int) -> URL? {
        URL(string: baseURL + "/api/channels/recordings/\(id)/file/")
    }

    private func decodeRecording(from data: Data) throws -> Recording {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any], let rec = Recording(dict: dict) else {
            let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "<non-utf8>"
            DebugLogger.shared.log("DispatcharrAPI.Recording decode failed — payload: \(snippet)",
                                   category: "Network", level: .error)
            throw APIError.decodingError(NSError(domain: "DispatcharrAPI",
                                                 code: -4,
                                                 userInfo: [NSLocalizedDescriptionKey: "Malformed recording response"]))
        }
        return rec
    }

    private func decodeRecordingArray(from data: Data) throws -> [Recording] {
        let obj = try JSONSerialization.jsonObject(with: data)
        // Accept either a flat array or a paginated {results: [...]} wrapper.
        let rawArray: [[String: Any]]
        if let arr = obj as? [[String: Any]] {
            rawArray = arr
        } else if let dict = obj as? [String: Any], let arr = dict["results"] as? [[String: Any]] {
            rawArray = arr
        } else {
            let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "<non-utf8>"
            DebugLogger.shared.log("DispatcharrAPI.listRecordings decode failed — payload: \(snippet)",
                                   category: "Network", level: .error)
            throw APIError.decodingError(NSError(domain: "DispatcharrAPI",
                                                 code: -5,
                                                 userInfo: [NSLocalizedDescriptionKey: "Malformed recordings list"]))
        }
        return rawArray.compactMap { Recording(dict: $0) }
    }

    // MARK: - Helpers
    /// Builds the full request URL from the server's baseURL and a path
    /// like `/api/channels/groups/?page_size=1`. Uses URLComponents so
    /// non-default ports, IPv6 host literals, and pre-existing baseURL
    /// path components survive the join (the previous string-concat
    /// approach was correct for the common case but fragile around
    /// trailing slashes and userinfo). Treats anything after the first
    /// `?` in `path` as the query so the caller can keep the
    /// pre-encoded `?key=value&...` shape it ships with today.
    ///
    /// v1.6.20: pulled in alongside the auth-mode auto-detect work
    /// because one of the affected users runs Dispatcharr at
    /// `http://dispatchar.domain.com:9191` — port preservation is the
    /// kind of thing URLComponents handles correctly by definition,
    /// whereas `URL(string: a + b)` only happens to do so today.
    private func buildURL(path: String) throws -> URL {
        // Split path from any query string. We assume Dispatcharr
        // paths never carry a fragment (`#`) so we don't bother
        // splitting on that.
        let pathOnly: String
        let queryOnly: String?
        if let qIdx = path.firstIndex(of: "?") {
            pathOnly = String(path[..<qIdx])
            queryOnly = String(path[path.index(after: qIdx)...])
        } else {
            pathOnly = path
            queryOnly = nil
        }

        // Parse the baseURL into its parts (scheme, host, port, any
        // pre-existing path). Fall back to the legacy string-concat
        // path if URLComponents can't make sense of the input — keeps
        // us no worse than v1.6.19 for genuinely malformed URLs.
        guard var components = URLComponents(string: baseURL) else {
            guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
            return url
        }

        // Strip a trailing `/` from baseURL's path so the join
        // doesn't produce `//api/...`. The empty case is fine
        // (`""` + `"/api/..."` = `"/api/..."`).
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath = String(basePath.dropLast()) }
        let joined = basePath + (pathOnly.hasPrefix("/") ? pathOnly : "/" + pathOnly)
        components.path = joined
        // The path strings sprinkled through DispatcharrAPI carry
        // already-encoded queries (`?page_size=1`, `?ids=1,2`, etc.).
        // Round-tripping through `query` would re-percent-encode the
        // commas, so we set the percent-encoded form directly.
        components.percentEncodedQuery = queryOnly

        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    private func validate(response: URLResponse) throws {
        try validate(response: response, data: nil)
    }

    /// Body-aware validation: promotes Dispatcharr's auth-failure 404s
    /// ("No User matches the given query") to `.unauthorized` so callers
    /// can surface the correct "check your API key" message.
    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw APIError.unauthorized
        case 404:
            // Dispatcharr returns HTTP 404 + {"detail":"No User matches…"} when
            // the API key doesn't exist in the database — this is an auth failure,
            // not a missing endpoint.
            if let body = data,
               let text = String(data: body, encoding: .utf8),
               text.contains("No User matches") {
                throw APIError.unauthorized
            }
            throw APIError.serverError(http.statusCode)
        default: throw APIError.serverError(http.statusCode)
        }
    }

    /// Global cap on concurrent in-flight DispatcharrAPI requests.
    ///
    /// **Why this exists.** v1.6.20 logs from a real Apple TV repro
    /// showed AerioTV firing channels + VOD movies + VOD series + EPG
    /// fetches in parallel during initial sync, each with their own
    /// pagination fanout. Against a Dispatcharr instance with a
    /// large library (3,640 channel groups, 1,574 VOD categories,
    /// 2,174 channels in the captured case), the resulting burst
    /// of concurrent HTTP requests overwhelmed the upstream
    /// uwsgi/Daphne worker pool, EPG prefetches timed out, the
    /// container locked up, and a force-restart was required.
    ///
    /// **Why 2 instead of 4.** A v1.6.21 follow-up test showed even
    /// a 4-concurrent cap could overwhelm a particularly fragile
    /// Dispatcharr 0.23.0 deployment serving a 351k-movie library.
    /// The XMLTV bulk fetch (24+ MB) ties up one worker for 30+
    /// seconds on its own; combined with 3-4 per-cell EPG prefetches
    /// at the same time, we'd routinely hit 4-5 simultaneous
    /// long-running requests, and the smallest worker-pool deployments
    /// (default uwsgi: 4 workers in some Docker images) wedged.
    /// Lowering to 2 gives the server breathing room without
    /// noticeably slowing sync on healthy servers (each phase is
    /// still effectively parallel-of-2, and individual endpoints
    /// dominate latency anyway). XMLTV is a separate code path
    /// outside this gate (`XMLTVParser` has its own URLSession),
    /// so peak in-flight is `cap + 1` = 3 simultaneous requests
    /// against the server during EPG phase.
    ///
    /// Global rather than per-host because the typical user has
    /// one Dispatcharr server. Users with multiple servers still
    /// share the cap, which is fine: total in-flight stays bounded
    /// regardless of how many servers are syncing simultaneously.
    private static let concurrencyGate = AsyncSemaphore(value: 2)

    /// Wraps the data fetch with DebugLogger timing, result logging,
    /// and the v1.6.21 concurrency gate. The gate cap (4 in-flight
    /// requests across all DispatcharrAPI instances) prevents the
    /// initial-sync request burst from overwhelming small Dispatcharr
    /// deployments. See `concurrencyGate` doc for the rationale.
    ///
    /// v1.6.10: routed through `HTTPRouter` so plain-HTTP requests
    /// against HSTS-preloaded TLDs (`.app`, `.dev`, etc.) bypass
    /// URLSession's HSTS layer via Network.framework. URLSession
    /// remains the path for HTTPS, IP literals, and non-preloaded
    /// TLDs.
    private func loggedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        await Self.concurrencyGate.wait()
        defer {
            // `defer` can't `await`, so signal in a fire-and-forget
            // task. Ordering doesn't matter for a counting semaphore.
            Task { await Self.concurrencyGate.signal() }
        }
        let method = request.httpMethod ?? "GET"
        let urlStr = request.url?.absoluteString ?? "<unknown>"
        let start  = Date()
        do {
            // v1.7.x: route through dataWithJWTRetry instead of
            // HTTPRouter.data directly. No-op for `.apiKey` and
            // `.bearer` auth modes; for `.jwtSession` it transparently
            // refreshes the JWT access token on 401 and replays the
            // request once. Every authed Dispatcharr API call lands
            // here (fetchAllPages, validate-and-decode wrappers,
            // recording playback resolution, VOD pagination), so this
            // single migration covers the entire surface.
            let result   = try await dataWithJWTRetry(for: request)
            let status   = (result.1 as? HTTPURLResponse)?.statusCode
            let duration = Date().timeIntervalSince(start)
            DebugLogger.shared.logNetwork(method: method, url: urlStr, statusCode: status,
                                          duration: duration, bytesReceived: result.0.count)
            return result
        } catch {
            let duration = Date().timeIntervalSince(start)
            DebugLogger.shared.logNetwork(method: method, url: urlStr, duration: duration, error: error)
            throw error
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.jsonDecoder.decode(type, from: data)
        } catch {
            DebugLogger.shared.logDecodeError(type: String(describing: T.self), error: error,
                                              payloadSnippet: String(data: data, encoding: .utf8).map { String($0.prefix(200)) })
            throw APIError.decodingError(error)
        }
    }

    private func decodeDispatcharrServerInfo(from data: Data) throws -> DispatcharrServerInfo {
        let decoder = Self.jsonDecoder

        // Most common: { "version": "...", ... }
        if let direct = try? decoder.decode(DispatcharrServerInfo.self, from: data) {
            return direct
        }

        // Some deployments wrap responses: { "data": { ... } }
        struct Wrapper: Decodable { let data: DispatcharrServerInfo }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data) {
            return wrapped.data
        }

        // Last resort: surface the body for debugging.
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw APIError.decodingError(NSError(
            domain: "DispatcharrAPI",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Unrecognized /api/version/ response. Body: \(String(body.prefix(800)))"]
        ))
    }
}

// MARK: - AsyncSemaphore
/// Minimal counting semaphore for bounded async concurrency.
///
/// Used by `DispatcharrAPI.concurrencyGate` to cap concurrent
/// in-flight HTTP requests against Dispatcharr so initial-sync
/// fanout (channels + EPG + VOD movies + VOD series, each
/// paginated) doesn't overwhelm the upstream uwsgi/Daphne worker
/// pool of a self-hosted deployment. See the
/// `DispatcharrAPI.concurrencyGate` doc comment for the v1.6.21
/// real-world repro that motivated this gate.
///
/// Implementation notes:
///  - `actor` isolation guarantees `wait()` and `signal()` mutate
///    `available` and `waiters` race-free.
///  - `withCheckedContinuation` parks the calling Task without
///    blocking a thread; resumption goes through Swift Concurrency's
///    cooperative pool.
///  - Strict FIFO order on `waiters` so callers don't starve.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        precondition(value > 0, "AsyncSemaphore initial value must be > 0")
        self.available = value
    }

    /// Blocks (asynchronously) until a slot is available, then takes it.
    /// Pair with a matching `signal()` to release the slot.
    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    /// Releases a slot. Resumes the oldest waiter if any are queued,
    /// otherwise increments the available count.
    func signal() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}

// MARK: - URLSession Redirect Delegate
/// Re-applies our auth + identity headers to redirected requests so
/// they survive `301`/`302`/`307`/`308` hops.
///
/// **Why this exists.** URLSession's default redirect handler strips
/// the `Authorization` header on cross-origin redirects (intentional —
/// otherwise a malicious server could `301` to attacker-controlled
/// hosts and exfiltrate the credential). It also occasionally drops
/// non-standard headers like `X-API-Key` depending on the redirect
/// type. For Dispatcharr deployments behind a reverse proxy that
/// rewrites paths (e.g., `/api` → `/api/`, or HTTP → HTTPS upgrade
/// via `301`), this manifests as: the first request includes the API
/// key, gets `301`'d, the redirected request lands at the auth wall
/// without credentials, server returns `401`, and the user sees
/// "Dispatcharr rejected this request" even though the key is valid.
///
/// This delegate is wired onto the shared `DispatcharrAPI.session`
/// so every API call inherits the behavior. The redirect target
/// inherits the auth-relevant headers from `task.originalRequest`;
/// non-auth headers (e.g., `Cookie`, `Referer`) are left to URLSession's
/// default handling.
///
/// v1.6.20 (Aerio): added as part of the auth-fallback work after
/// three users on private Dispatcharr deployments hit HTTP 401 on
/// Test Connection. We can't be certain redirects were the trigger
/// for those specific reports — header-shape was the smoking gun —
/// but a stripped-on-redirect API key would produce indistinguishable
/// symptoms, so this is belt-and-suspenders against the same class
/// of failure.
final class RedirectPreservingDelegate: NSObject, URLSessionTaskDelegate {

    /// Headers re-applied across same-origin redirects. Strictly
    /// auth-bearing headers (`Authorization`, `X-API-Key`) are
    /// stripped on cross-origin redirects per HTTP standard;
    /// non-credential headers (`Accept`, `Content-Type`,
    /// `User-Agent`) are safe to forward regardless.
    private static let credentialHeaders: Set<String> = [
        "X-API-Key",
        "Authorization"
    ]
    private static let nonCredentialHeaders: [String] = [
        "Accept",
        "Content-Type",
        "User-Agent"
    ]

    /// True when redirect target's host (and scheme + port) matches
    /// the original request's, accounting for nil values on either
    /// side. v1.6.23: gate credential reapplication on this check
    /// so a malicious or misconfigured server can't issue HTTP 301
    /// to attacker.example.com and harvest the user's API key in
    /// plain text. Same-origin redirects (reverse-proxy
    /// canonicalization, http -> https upgrade by an explicit
    /// scheme bump on the same host) keep working.
    private static func isSameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = a, let b = b else { return false }
        guard let aHost = a.host?.lowercased(),
              let bHost = b.host?.lowercased(),
              aHost == bHost else { return false }
        guard a.scheme?.lowercased() == b.scheme?.lowercased() else { return false }
        // Compare effective ports (default port if unset).
        let aPort = a.port ?? defaultPort(forScheme: a.scheme)
        let bPort = b.port ?? defaultPort(forScheme: b.scheme)
        return aPort == bPort
    }

    private static func defaultPort(forScheme scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var modified = request
        if let original = task.originalRequest {
            let sameOrigin = Self.isSameOrigin(original.url, request.url)
            // Always forward non-credential headers.
            for name in Self.nonCredentialHeaders {
                if let value = original.value(forHTTPHeaderField: name) {
                    modified.setValue(value, forHTTPHeaderField: name)
                }
            }
            // Auth headers ONLY on same-origin redirects.
            if sameOrigin {
                for name in Self.credentialHeaders {
                    if let value = original.value(forHTTPHeaderField: name) {
                        modified.setValue(value, forHTTPHeaderField: name)
                    }
                }
            } else {
                // Defense in depth: explicitly strip any auth
                // header URLSession may have copied automatically.
                for name in Self.credentialHeaders {
                    modified.setValue(nil, forHTTPHeaderField: name)
                }
            }
            #if DEBUG
            // One-line audit so a misbehaving reverse-proxy redirect
            // shows up in the debug log without needing a packet
            // capture. Note whether auth was preserved or stripped.
            let from = original.url?.absoluteString ?? "<unknown>"
            let to   = request.url?.absoluteString ?? "<unknown>"
            let authNote = sameOrigin ? "auth preserved (same-origin)" : "AUTH STRIPPED (cross-origin)"
            debugLog("DispatcharrAPI redirect: \(response.statusCode) \(from) -> \(to) (\(authNote))")
            #endif
        }
        completionHandler(modified)
    }
}

// MARK: - Dispatcharr Response Models
struct DispatcharrServerInfo: Decodable {
    let version: String?
    /// Optional human-friendly server name (key varies by backend/version).
    let serverName: String?
    /// v1.6.20: the auth header shape that successfully reached the API
    /// during `verifyConnection`. Persisted on the `ServerConnection`
    /// model so subsequent API calls and stream playback use the same
    /// shape without re-detecting on every cold start. `nil` means the
    /// caller didn't run discovery (e.g., decoding from a JSON body
    /// directly), in which case the caller should keep whatever was
    /// previously persisted.
    var discoveredAuthMode: DispatcharrAuthHeaderMode?

    enum CodingKeys: String, CodingKey {
        case version
        case serverName = "server_name"
        case name
    }

    init(version: String? = nil, serverName: String? = nil,
         discoveredAuthMode: DispatcharrAuthHeaderMode? = nil) {
        self.version = version
        self.serverName = serverName
        self.discoveredAuthMode = discoveredAuthMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decode(String.self, forKey: .version)
        // Prefer explicit server_name, fall back to name.
        serverName = (try? c.decode(String.self, forKey: .serverName)) ?? (try? c.decode(String.self, forKey: .name))
        discoveredAuthMode = nil
    }
}

// Generic DRF wrapper
struct DispatcharrResultsWrapper<T: Decodable>: Decodable {
    let results: [T]
    let next: String?
    let count: Int?
}

// Wrapper for endpoints that return {"data": [...]} (e.g. /api/epg/grid/)
struct DispatcharrDataWrapper<T: Decodable>: Decodable {
    let data: [T]
}

struct DispatcharrChannelSummary: Decodable, Identifiable {
    let id: Int
    let name: String
    let logoURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case logoURL = "logo_url"
    }
}

/// One row from `/api/epg/epgdata/`. Provides the bridge between
/// `Channel.epg_data_id` (FK integer on Channel) and the `tvg_id`
/// the bulk EPG grid keys programs by. v1.6.22: 25% of channels
/// on a real Dispatcharr instance have `Channel.tvg_id !=
/// EPGData.tvg_id` (EPGData is set at XMLTV ingest time, Channel is
/// user-configurable). Without this lookup, those channels miss
/// the bulk grid match and render as blank rows in the Live TV
/// guide. ECM (Enhanced Channel Manager) uses the same pattern.
struct DispatcharrEPGData: Decodable, Identifiable {
    let id: Int
    let tvgID: String
    let name: String
    let iconURL: String?
    let epgSource: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case tvgID = "tvg_id"
        case iconURL = "icon_url"
        case epgSource = "epg_source"
    }
}

/// Current program for a channel as returned by `/api/epg/current-programs/` or `/api/epg/programs/`.
/// Schema: ProgramData — fields include tvg_id, title, start_time, end_time, channel, channel_name.
struct DispatcharrCurrentProgram: Decodable, Identifiable {
    var id: String { "\(tvgID ?? channel.map(String.init) ?? "?")-\(title)-\(startTime?.toDate()?.timeIntervalSince1970 ?? 0)" }

    /// Dispatcharr's server-side primary key for this `ProgramData`
    /// row. Required to call `/api/epg/programs/<id>/` for the rich
    /// detail (categories, rating, credits, icons) the bulk grid
    /// strips. v1.6.22 introduced this field; the synthetic `id`
    /// computed property above stays for backwards compat with any
    /// caller that needs a stable identity for diffing.
    let programID: Int?
    let tvgID: String?
    let channel: Int?        // Dispatcharr channel ID
    let channelName: String? // Channel display name (if returned)
    let title: String
    let description: String
    let subTitle: String
    let startTime: DispatcharrDateValue?
    let endTime: DispatcharrDateValue?

    // EPG badge metadata. On the wire in `/api/epg/grid/` and the
    // current/upcoming endpoints; older servers omit them, so all decode
    // with `decodeIfPresent` + false/nil fallbacks. Dispatcharr has no
    // repeat field, so REPEAT stays false on this path.
    let season: Int?
    let episode: Int?
    let isNew: Bool
    let isLiveBroadcast: Bool
    let isPremiere: Bool
    let isFinale: Bool

    enum CodingKeys: String, CodingKey {
        case programID = "id"
        case tvgID = "tvg_id"
        case channel
        case channelName = "channel_name"
        case title
        case description
        case subTitle = "sub_title"
        case startTime = "start_time"
        case endTime = "end_time"
        case season
        case episode
        case isNew = "is_new"
        case isLiveBroadcast = "is_live"
        case isPremiere = "is_premiere"
        case isFinale = "is_finale"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Server returns id as Int; some legacy/dummy entries use a
        // string ("dummy-custom-..."). Try Int first, fall back to
        // nil for non-numeric ids (the detail endpoint won't accept
        // them anyway, so we just skip enrichment for those).
        programID = try? c.decode(Int.self, forKey: .programID)
        tvgID = try? c.decode(String.self, forKey: .tvgID)
        channel = try? c.decode(Int.self, forKey: .channel)
        channelName = try? c.decode(String.self, forKey: .channelName)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        subTitle = (try? c.decode(String.self, forKey: .subTitle)) ?? ""
        startTime = try? c.decode(DispatcharrDateValue.self, forKey: .startTime)
        endTime = try? c.decode(DispatcharrDateValue.self, forKey: .endTime)
        season = try? c.decodeIfPresent(Int.self, forKey: .season)
        episode = try? c.decodeIfPresent(Int.self, forKey: .episode)
        isNew = (try? c.decodeIfPresent(Bool.self, forKey: .isNew)) ?? false
        isLiveBroadcast = (try? c.decodeIfPresent(Bool.self, forKey: .isLiveBroadcast)) ?? false
        isPremiere = (try? c.decodeIfPresent(Bool.self, forKey: .isPremiere)) ?? false
        isFinale = (try? c.decodeIfPresent(Bool.self, forKey: .isFinale)) ?? false
    }
}

/// Rich program data from `/api/epg/programs/<id>/`: the only REST
/// endpoint that returns the `categories` array, rating, credits,
/// and program artwork. v1.6.22 uses this for category enrichment
/// (Tint Channel Cards) on Dispatcharr-API mode, where the bulk
/// `/api/epg/grid/` deliberately strips category data via the
/// server's hand-rolled serializer (`apps/epg/api_views.py`'s
/// `EPGGridAPIView.get`). API-only path; no XMLTV stream involved.
struct DispatcharrProgramDetail: Decodable {
    let id: Int
    let categories: [String]
    let rating: String?
    /// Per-programme artwork the detail endpoint surfaces (the grid
    /// strips all of these). `icon` is the XMLTV `<programme><icon>`,
    /// `imageURL` the first of the XMLTV `<image>` list, `posterURL`
    /// the absolute Schedules-Direct poster proxy URL (SD sources
    /// only), and `tmdbID` the TMDB id when the server has one.
    let icon: String?
    let imageURL: String?
    let posterURL: String?
    let tmdbID: String?

    private struct ImageEntry: Decodable { let url: String? }

    enum CodingKeys: String, CodingKey {
        case id, categories, rating
        case icon, images
        case posterURL = "poster_url"
        case tmdbID = "tmdb_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        categories = (try? c.decode([String].self, forKey: .categories)) ?? []
        rating = try? c.decode(String.self, forKey: .rating)
        icon = try? c.decode(String.self, forKey: .icon)
        imageURL = (try? c.decode([ImageEntry].self, forKey: .images))?
            .compactMap { $0.url }.first
        posterURL = try? c.decode(String.self, forKey: .posterURL)
        // tmdb_id can be Int or String depending on source.
        if let s = try? c.decode(String.self, forKey: .tmdbID) {
            tmdbID = s
        } else if let i = try? c.decode(Int.self, forKey: .tmdbID) {
            tmdbID = String(i)
        } else {
            tmdbID = nil
        }
    }

    /// Best server-provided poster path/URL, preferring the SD proxy,
    /// then an XMLTV `<image>`, then the `<icon>`. nil when the
    /// programme carries no artwork (the TMDB-by-title fallback then
    /// applies, if enabled).
    var bestPosterString: String? {
        for candidate in [posterURL, imageURL, icon] {
            if let c = candidate, !c.isEmpty { return c }
        }
        return nil
    }
}

enum DispatcharrDateValue: Decodable {
    case iso(String)
    case unix(Double)

    // Cached formatters — creating DateFormatter is expensive; reuse across all calls.
    // nonisolated(unsafe) required because ISO8601DateFormatter/DateFormatter are not Sendable in Swift 6.
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()
    private static let djangoMicrosFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return df
    }()
    private static let djangoFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return df
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .iso(s)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .unix(d)
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .unix(Double(i))
            return
        }
        throw DecodingError.typeMismatch(
            DispatcharrDateValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported date value")
        )
    }

    func toDate() -> Date? {
        switch self {
        case .unix(let ts):
            // Backend timestamps can be seconds or milliseconds.
            if ts > 2_000_000_000_000 { return Date(timeIntervalSince1970: ts / 1000.0) }
            return Date(timeIntervalSince1970: ts)
        case .iso(let s):
            // Try RFC3339 / ISO8601
            if let d = Self.iso8601Formatter.date(from: s) { return d }
            // Fall back to common Django formats
            if let d = Self.djangoMicrosFormatter.date(from: s) { return d }
            return Self.djangoFormatter.date(from: s)
        }
    }
}

/// One EPG source from `/api/epg/sources/`. `sourceType` is "xmltv",
/// "schedules_direct", or "dummy"; only active xmltv sources with an
/// http(s) URL are fetchable by the app. `hasChannels` is a server-side
/// annotation (does any channel's EPGData point at this source); it is
/// optional because older Dispatcharr builds may not include it.
struct DispatcharrEPGSource: Decodable, Identifiable {
    let id: Int
    let name: String?
    let sourceType: String?
    let url: String?
    let isActive: Bool?
    let hasChannels: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case sourceType = "source_type"
        case isActive = "is_active"
        case hasChannels = "has_channels"
    }
}

struct DispatcharrChannel: Decodable, Identifiable {
    let id: Int
    let name: String

    /// Dispatcharr's channel number, normalised to a display-ready
    /// string. v1.7.x: stored as `String?` (was `Double?`) so ATSC
    /// over-the-air `major.minor` numbers like "2.1" / "5.1" survive
    /// the round trip from Dispatcharr's API into the channel-list
    /// UI.
    ///
    /// Why this had to change: Dispatcharr's underlying column is a
    /// decimal type, and Django REST Framework's `DecimalField`
    /// defaults to `coerce_to_string=True` so the field is serialized
    /// as a JSON string ("2.1"), not a JSON number. The old
    /// `decodeIfPresent(Double.self, …)` path either threw
    /// `typeMismatch` and dropped the channel (some builds) or
    /// silently fell through to `nil` (others), which downstream
    /// turned into the 1-based-index fallback in the channel-list
    /// builder. Field report from "the Moterator" (Discord
    /// 2026-05-11): "2.1 is 2, 2.2 is 3, 5.1 is 7" matched the
    /// fallback pattern exactly.
    ///
    /// The custom decoder accepts JSON Double, JSON Int, and JSON
    /// String in that order. Whole-number doubles ("11.0") get
    /// flattened to their integer string ("11") so existing
    /// integer-numbered lineups render unchanged. Empty / null /
    /// absent yields `nil` so callers fall through to their own
    /// fallback.
    let channelNumber: String?

    /// These are present in the channels payload you posted.
    /// Some Dispatcharr versions use `channel_group_id`, others use `channel_group`.
    let channelGroupID: Int?
    /// UUID used by Dispatcharr proxy endpoints (commonly treated as the channel UUID).
    /// The iOS app should prefer `/proxy/ts/channel/<uuid>/` so Dispatcharr can apply failover.
    let uuid: String?
    let logoID: Int?
    let streams: [Int]?
    let tvgID: String?

    /// Optional fields that may exist on some deployments / endpoints.
    let epgDataID: Int?
    /// Dispatcharr's server-computed *effective* EPG link. When the
    /// server auto-maps a channel to an EPGData record, this can
    /// diverge from the raw `epg_data_id` and is the more authoritative
    /// key for bridging `Channel → EPGData.tvg_id`. Absent on older
    /// servers, in which case callers fall back to `epgDataID`.
    /// Mirrors the AerioTV-Android EPG bridge.
    let effectiveEpgDataID: Int?

    /// Catch-up (timeshift) capability, rolled up server-side from the
    /// channel's provider streams (Dispatcharr dev, PR #1242): true when
    /// ANY active stream's XC provider reports tv_archive=1.
    let isCatchup: Bool
    /// Retention window in days, the MAX across the channel's catch-up
    /// streams (server caps at 30). 0 when not catch-up capable.
    let catchupDays: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case channelNumber = "channel_number"
        case uuid
        case logoID = "logo_id"
        case streams
        case tvgID = "tvg_id"
        case epgDataID = "epg_data_id"
        case effectiveEpgDataID = "effective_epg_data_id"
        case isCatchup = "is_catchup"
        case catchupDays = "catchup_days"
        // channelGroupID handled in init(from:)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // v1.7.x: accept Double, Int, or String for channel_number.
        // See the `channelNumber` doc comment for the rationale.
        // Order matters: try numeric types first (Double covers the
        // common "11444.0" float case AND any Int-valued numbers),
        // then String (Django REST DecimalField default shape).
        // Note: `try?` on a throwing `T?`-returning function flattens
        // throw-into-nil so the result is a single `T?`, not `T??`.
        if let d = try? container.decodeIfPresent(Double.self, forKey: .channelNumber) {
            // Whole-number doubles flatten to "11" instead of "11.0"
            // so integer-numbered lineups stay clean.
            channelNumber = d.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(d))
                : String(d)
        } else if let i = try? container.decodeIfPresent(Int.self, forKey: .channelNumber) {
            channelNumber = String(i)
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .channelNumber) {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            channelNumber = trimmed.isEmpty ? nil : trimmed
        } else {
            channelNumber = nil
        }
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        logoID = try container.decodeIfPresent(Int.self, forKey: .logoID)
        streams = try container.decodeIfPresent([Int].self, forKey: .streams)
        tvgID = try container.decodeIfPresent(String.self, forKey: .tvgID)
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: .epgDataID) {
            epgDataID = intVal
        } else if let strVal = try? container.decodeIfPresent(String.self, forKey: .epgDataID) {
            epgDataID = Int(strVal)
        } else {
            epgDataID = nil
        }
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: .effectiveEpgDataID) {
            effectiveEpgDataID = intVal
        } else if let strVal = try? container.decodeIfPresent(String.self, forKey: .effectiveEpgDataID) {
            effectiveEpgDataID = Int(strVal)
        } else {
            effectiveEpgDataID = nil
        }
        // Absent on pre-catch-up servers: default to not-capable. One
        // coalesce covers both throw and key-absent (try? flattens the
        // double optional).
        isCatchup = (try? container.decodeIfPresent(Bool.self, forKey: .isCatchup)) ?? false
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: .catchupDays) {
            catchupDays = intVal
        } else if let strVal = try? container.decodeIfPresent(String.self, forKey: .catchupDays) {
            catchupDays = Int(strVal) ?? 0
        } else {
            catchupDays = 0
        }

        // Try both "channel_group_id" and "channel_group" keys
        enum ExtraKeys: String, CodingKey {
            case channelGroupID = "channel_group_id"
            case channelGroup   = "channel_group"
        }
        let extra = try decoder.container(keyedBy: ExtraKeys.self)
        channelGroupID = try extra.decodeIfPresent(Int.self, forKey: .channelGroupID)
            ?? extra.decodeIfPresent(Int.self, forKey: .channelGroup)
    }

}

// MARK: - Switch Stream (Dispatcharr member streams)

/// One member stream of a Dispatcharr channel, from
/// `GET /api/channels/channels/{id}/streams/` (highest priority first).
/// `id` is the Stream pk POSTed to `change_stream`; `m3uAccount` is the
/// source M3U account id resolved to a name via `getM3UAccounts()`.
/// `streamStats` is `null` until Dispatcharr has probed that source, so
/// a never-played stream degrades to name + source only.
struct DispatcharrStream: Decodable, Identifiable {
    let id: Int
    let name: String?
    let m3uAccount: Int?
    let streamStats: StreamStats?

    enum CodingKeys: String, CodingKey {
        case id, name
        case m3uAccount = "m3u_account"
        case streamStats = "stream_stats"
    }

    /// Quality stats Dispatcharr reports for a probed stream. Numeric
    /// fields decode through `decodeStringOrNumber` because DRF can emit
    /// them as JSON strings or numbers; codecs/resolution use the existing
    /// flexible-string decode. All optional — any field can be absent.
    struct StreamStats: Decodable {
        let resolution: String?     // e.g. "1920x1080"
        let sourceFPS: String?      // number-or-string
        let videoCodec: String?     // e.g. "h264", "hevc"
        let outputBitrate: String?  // kbps, number-or-string
        let audioCodec: String?     // e.g. "aac", "ac3"

        enum CodingKeys: String, CodingKey {
            case resolution
            case sourceFPS = "source_fps"
            case videoCodec = "video_codec"
            case outputBitrate = "ffmpeg_output_bitrate"
            case audioCodec = "audio_codec"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            resolution = c.decodeFlexibleString(forKey: .resolution)
            sourceFPS = c.decodeStringOrNumber(forKey: .sourceFPS)
            videoCodec = c.decodeFlexibleString(forKey: .videoCodec)
            outputBitrate = c.decodeStringOrNumber(forKey: .outputBitrate)
            audioCodec = c.decodeFlexibleString(forKey: .audioCodec)
        }
    }
}

/// A Dispatcharr M3U source account from `GET /api/m3u/accounts/`. Used to
/// resolve a stream's `m3u_account` integer id to a display name (the
/// source label the Dispatcharr WebUI shows). Distinct from
/// `DispatcharrCategoryM3UAccount` (the VOD category->account join row).
struct DispatcharrM3UAccount: Decodable, Identifiable {
    let id: Int
    let name: String?
}

/// Response of `POST /proxy/ts/change_stream/<uuid>`. We only need `url`
/// (the resolved upstream the server switched to) for the confirm gate.
struct DispatcharrChangeStreamResponse: Decodable {
    let url: String?
    /// True when the request landed on the channel's OWNER worker. Only the
    /// owner path rewrites the Redis `stream_id` the Dispatcharr Stats card
    /// reads (`channel_service.change_stream_url` → `_update_channel_metadata`);
    /// on a non-owner worker the switch still applies for playback but the
    /// Stats card stays stale. Sourced from `result['direct_update']` server-side.
    let owner: Bool?
}

/// Subset of `GET /proxy/ts/status/<uuid>`. `url` is the live upstream
/// (reliable across switches); `streamID` is the active stream pk (goes
/// stale on the event path — seed-only, never a confirm signal). Both
/// decode tolerantly (DRF may string-encode the id).
struct DispatcharrChannelStatus: Decodable {
    let url: String?
    let streamID: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case streamID = "stream_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.decodeFlexibleString(forKey: .url)
        if let s = c.decodeStringOrNumber(forKey: .streamID) {
            streamID = Int(s)
        } else {
            streamID = nil
        }
    }
}

// MARK: - Dispatcharr VOD

struct DispatcharrVODStreamOption: Decodable {
    let streamID: Int?
    let providerID: Int?

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case providerID = "provider_id"
    }
}

// Dispatcharr embeds artwork as a nested "logo" object on every VOD item.
// url  — full absolute URL (TMDB CDN or external); no auth required.
// cacheURL — proxied through this Dispatcharr instance; requires ApiKey auth.
struct DispatcharrVODLogo: Decodable {
    let url: String?
    let cacheURL: String?

    enum CodingKeys: String, CodingKey {
        case url
        case cacheURL = "cache_url"
    }
}

/// v1.6.12: lean view onto Dispatcharr's `custom_properties` JSON
/// blob. Dispatcharr stores TMDB-derived metadata (cast, director,
/// trailers, backdrops, dates, etc.) under arbitrary keys inside this
/// field on Movie / Series / Episode rows — see Dispatcharr's
/// `apps/vod/tasks.py` (`refresh_movie_advanced_data`,
/// `process_series_batch`). Only the keys we surface in the UI are
/// decoded here; the giant `detailed_info` / `movie_data` sub-dicts
/// are deliberately ignored to keep the per-item decode cheap when
/// the list endpoints return 25+ items at a time.
///
/// Fields are all `Optional` and decoded with `try?` so a malformed
/// or missing key never poisons the parent decode. Two fields
/// (`backdropPath`, `episodeRunTime`) accept either an array or a
/// scalar because Xtream-shaped payloads use both shapes
/// interchangeably depending on the upstream provider.
struct DispatcharrVODCustomProperties: Decodable {
    let youtubeTrailer: String?
    let trailer: String?
    let backdropPath: [String]?
    let posterPath: String?
    /// Comma-separated cast list — sometimes under `cast`, sometimes
    /// under `actors`. Whichever is non-nil, that's the one we keep.
    let cast: String?
    let director: String?
    /// Episode runtime in **minutes** when present.
    let episodeRunTime: Int?
    let firstAirDate: String?
    let lastAirDate: String?
    let releaseDate: String?
    let originalName: String?
    let country: String?
    let language: String?
    /// v1.6.16.x: per-episode TMDB still URL. Dispatcharr stores
    /// it under `custom_properties.movie_image` for episodes (a
    /// w185-sized still on `image.tmdb.org`). The same key is also
    /// surfaced by movie-provider-info; we add it here so the
    /// shared custom-properties decoder can populate it for both
    /// movie and episode contexts.
    let movieImage: String?
    /// v1.6.16.x: per-episode crew/director string. Dispatcharr
    /// stores the episode's director under `custom_properties.crew`
    /// (e.g. `"Philippe Triboit"`). Series-level `director` lives
    /// in the parent series's custom_properties, so this is the
    /// per-episode-specific value.
    let crew: String?

    /// v1.6.17 — per-item category id (string in JSON, integer-shaped
    /// in practice, e.g. "1136"). The Series model has no top-level
    /// `category` field in Dispatcharr's schema; the only place a
    /// VOD item's category appears in the list response is here, in
    /// `custom_properties.category_id`. We use it to group items
    /// client-side after a single unfiltered fetch — see the rationale
    /// in `VODStore.loadMovies` / `loadSeries` for why we abandoned
    /// the documented `?category=` query parameter.
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case youtubeTrailer = "youtube_trailer"
        case trailer
        case backdropPath = "backdrop_path"
        case posterPath   = "poster_path"
        case cast
        case actors
        case director
        case episodeRunTime = "episode_run_time"
        case firstAirDate   = "first_air_date"
        case lastAirDate    = "last_air_date"
        case releaseDate
        case originalName   = "original_name"
        case country
        case language
        case movieImage     = "movie_image"
        case crew
        case categoryID     = "category_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        youtubeTrailer = try? c.decode(String.self, forKey: .youtubeTrailer)
        trailer        = try? c.decode(String.self, forKey: .trailer)

        // backdrop_path: prefer array shape; tolerate scalar.
        if let arr = try? c.decode([String].self, forKey: .backdropPath) {
            backdropPath = arr.filter { !$0.isEmpty }
        } else if let single = try? c.decode(String.self, forKey: .backdropPath),
                  !single.isEmpty {
            backdropPath = [single]
        } else {
            backdropPath = nil
        }

        posterPath = try? c.decode(String.self, forKey: .posterPath)

        // Cast can come from either key; whichever is non-nil wins.
        // v0.26.0: cast / actors may now arrive as a JSON array (the
        // "no longer truncated to first name" fix), so decode either a
        // string or an array (joined) rather than dropping the array.
        cast = c.decodeFlexibleString(forKey: .cast) ?? c.decodeFlexibleString(forKey: .actors)

        director = c.decodeFlexibleString(forKey: .director)

        // episode_run_time: int or string — accept both.
        if let i = try? c.decode(Int.self, forKey: .episodeRunTime) {
            episodeRunTime = i
        } else if let s = try? c.decode(String.self, forKey: .episodeRunTime),
                  let parsed = Int(s) {
            episodeRunTime = parsed
        } else {
            episodeRunTime = nil
        }

        firstAirDate = try? c.decode(String.self, forKey: .firstAirDate)
        lastAirDate  = try? c.decode(String.self, forKey: .lastAirDate)
        releaseDate  = try? c.decode(String.self, forKey: .releaseDate)
        originalName = try? c.decode(String.self, forKey: .originalName)
        country      = try? c.decode(String.self, forKey: .country)
        language     = try? c.decode(String.self, forKey: .language)
        movieImage   = try? c.decode(String.self, forKey: .movieImage)
        // crew (per-episode director) may also arrive as an array.
        crew         = c.decodeFlexibleString(forKey: .crew)
        // category_id can come through as String ("1136") or Int (1136)
        // depending on the Dispatcharr version; normalise to String.
        if let s = try? c.decode(String.self, forKey: .categoryID) {
            categoryID = s
        } else if let i = try? c.decode(Int.self, forKey: .categoryID) {
            categoryID = String(i)
        } else {
            categoryID = nil
        }
    }
}

struct DispatcharrVODCategory: Decodable, Identifiable {
    let id: Int
    let name: String
    let categoryType: String   // "movie" or "series"
    /// Per-M3U-account enable state. Dispatcharr's `/api/vod/categories/`
    /// endpoint returns ALL categories discovered from the provider —
    /// including ones the user has toggled off in the M3U Group Filter
    /// admin UI. The `enabled` bit inside each `m3u_accounts[]` entry
    /// tells us whether this category was selected for ingest on that
    /// particular account. A category is considered "user-enabled"
    /// iff ANY of its `m3u_accounts[]` entries has `enabled == true`.
    /// Orphaned categories (empty `m3u_accounts[]`) have no ingest path
    /// and never carry content, so we treat them as disabled.
    let m3uAccounts: [DispatcharrCategoryM3UAccount]

    enum CodingKeys: String, CodingKey {
        case id, name
        case categoryType = "category_type"
        case m3uAccounts = "m3u_accounts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        categoryType = try c.decode(String.self, forKey: .categoryType)
        // Missing / null → empty array. Old Dispatcharr builds may not
        // include the field at all.
        m3uAccounts = (try? c.decode([DispatcharrCategoryM3UAccount].self, forKey: .m3uAccounts)) ?? []
    }

    /// True when the user has this category enabled on at least one
    /// of their M3U accounts. The gate Aerio uses to hide categories
    /// that carry no ingested content.
    var isEnabledOnAnyAccount: Bool {
        m3uAccounts.contains { $0.enabled }
    }
}

/// Per-M3U-account link inside `DispatcharrVODCategory.m3u_accounts`.
/// `category` and `m3u_account` are the foreign-key ids on the join
/// row; `enabled` is the per-account M3U Group Filter toggle from the
/// Dispatcharr admin UI.
struct DispatcharrCategoryM3UAccount: Decodable {
    let category: Int
    let m3uAccount: Int
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case category, enabled
        case m3uAccount = "m3u_account"
    }
}

struct DispatcharrVODMovie: Decodable, Identifiable {
    let id: Int
    let uuid: String
    let title: String
    let logo: DispatcharrVODLogo?
    let plot: String?
    let genre: String?
    let rating: String?
    let streams: [DispatcharrVODStreamOption]?

    // v1.6.12: TMDB-derived metadata. `tmdbID`/`imdbID` are typed
    // columns on the Dispatcharr Movie model; `year`/`durationSecs`
    // mirror columns it populates from the upstream Xtream payload.
    // `customProperties` is the JSON blob that holds everything else
    // (cast, director, backdrops, trailer key, dates).
    let year: Int?
    let durationSecs: Int?
    let tmdbID: String?
    let imdbID: String?
    let customProperties: DispatcharrVODCustomProperties?

    // posterURL is the logo's direct URL (no auth needed — TMDB CDN or similar).
    var posterURL: String? { logo?.url }

    enum CodingKeys: String, CodingKey {
        case id, uuid, title, name
        case logo
        case description, plot, overview
        case genre, rating, streams
        case year
        case durationSecs    = "duration_secs"
        case tmdbID          = "tmdb_id"
        case imdbID          = "imdb_id"
        case customProperties = "custom_properties"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decode(Int.self, forKey: .id) {
            id = intID
        } else if let strID = try? c.decode(String.self, forKey: .id), let parsed = Int(strID) {
            id = parsed
        } else {
            id = 0
        }
        uuid   = (try? c.decode(String.self, forKey: .uuid)) ?? ""
        title  = (try? c.decode(String.self, forKey: .title)) ?? (try? c.decode(String.self, forKey: .name)) ?? ""
        logo   = try? c.decode(DispatcharrVODLogo.self, forKey: .logo)
        let p1 = try? c.decode(String.self, forKey: .plot)
        let p2 = try? c.decode(String.self, forKey: .overview)
        let p3 = try? c.decode(String.self, forKey: .description)
        plot   = p1 ?? p2 ?? p3
        genre  = try? c.decode(String.self, forKey: .genre)
        rating = try? c.decode(String.self, forKey: .rating)
        streams = try? c.decode([DispatcharrVODStreamOption].self, forKey: .streams)

        // v1.6.12 additions — defensive decode so a stale Dispatcharr
        // build that omits any of these doesn't fail the whole row.
        year             = try? c.decode(Int.self, forKey: .year)
        durationSecs     = try? c.decode(Int.self, forKey: .durationSecs)
        tmdbID           = try? c.decode(String.self, forKey: .tmdbID)
        imdbID           = try? c.decode(String.self, forKey: .imdbID)
        customProperties = try? c.decode(DispatcharrVODCustomProperties.self,
                                         forKey: .customProperties)
    }
}

struct DispatcharrVODSeries: Decodable, Identifiable {
    let id: Int
    let uuid: String
    let name: String
    let logo: DispatcharrVODLogo?
    let plot: String?
    let genre: String?
    let rating: String?

    // v1.6.12: TMDB-derived metadata mirrored from
    // `apps/vod/models.py.Series`. Series doesn't have
    // `duration_secs` (per-episode runtime is tracked elsewhere),
    // but `episodeRunTime` lives in `customProperties`.
    let year: Int?
    let tmdbID: String?
    let imdbID: String?
    let customProperties: DispatcharrVODCustomProperties?

    var posterURL: String? { logo?.url }

    enum CodingKeys: String, CodingKey {
        case id, uuid, name, title
        case logo
        case description, plot, overview
        case genre, rating
        case year
        case tmdbID = "tmdb_id"
        case imdbID = "imdb_id"
        case customProperties = "custom_properties"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decode(Int.self, forKey: .id) {
            id = intID
        } else if let strID = try? c.decode(String.self, forKey: .id), let parsed = Int(strID) {
            id = parsed
        } else {
            id = 0
        }
        uuid   = (try? c.decode(String.self, forKey: .uuid)) ?? ""
        name   = (try? c.decode(String.self, forKey: .name)) ?? (try? c.decode(String.self, forKey: .title)) ?? ""
        logo   = try? c.decode(DispatcharrVODLogo.self, forKey: .logo)
        let p1 = try? c.decode(String.self, forKey: .plot)
        let p2 = try? c.decode(String.self, forKey: .overview)
        let p3 = try? c.decode(String.self, forKey: .description)
        plot   = p1 ?? p2 ?? p3
        genre  = try? c.decode(String.self, forKey: .genre)
        rating = try? c.decode(String.self, forKey: .rating)

        year             = try? c.decode(Int.self, forKey: .year)
        tmdbID           = try? c.decode(String.self, forKey: .tmdbID)
        imdbID           = try? c.decode(String.self, forKey: .imdbID)
        customProperties = try? c.decode(DispatcharrVODCustomProperties.self,
                                         forKey: .customProperties)
    }
}

/// v1.6.12: response shape for `/api/vod/movies/<id>/provider-info/`.
/// Unlike the list endpoint (which returns slim typed columns and a
/// possibly-null `custom_properties`), this action flattens the
/// per-relation `detailed_info` blob plus the per-movie
/// `custom_properties` plus the typed columns into a single dict —
/// see Dispatcharr's `apps/vod/api_views.py` `MovieViewSet.provider_info`.
///
/// All fields are `Optional` and decoded with `try?` so an
/// older/leaner Dispatcharr build that omits any of them doesn't
/// fail the whole decode. `backdropPath` and `rating` accept either
/// scalar or array/string-vs-int because the upstream Xtream
/// providers send both shapes interchangeably.
struct DispatcharrVODMovieProviderInfo: Decodable {
    let description: String?
    let plot: String?
    let year: Int?
    let releaseDate: String?
    let genre: String?
    let director: String?
    let actors: String?
    let country: String?
    let rating: String?
    let tmdbID: String?
    let imdbID: String?
    let youtubeTrailer: String?
    let durationSecs: Int?
    let age: String?
    let backdropPath: [String]?
    let cover: String?
    let coverBig: String?
    let movieImage: String?

    enum CodingKeys: String, CodingKey {
        case description, plot, year, genre, director, actors, country, age, cover
        case releaseDate     = "release_date"
        case rating
        case tmdbID          = "tmdb_id"
        case imdbID          = "imdb_id"
        case youtubeTrailer  = "youtube_trailer"
        case durationSecs    = "duration_secs"
        case backdropPath    = "backdrop_path"
        case coverBig        = "cover_big"
        case movieImage      = "movie_image"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description    = try? c.decode(String.self, forKey: .description)
        plot           = try? c.decode(String.self, forKey: .plot)
        year           = try? c.decode(Int.self, forKey: .year)
        releaseDate    = try? c.decode(String.self, forKey: .releaseDate)
        genre          = try? c.decode(String.self, forKey: .genre)
        // v0.26.0: director/actors may arrive as arrays (joined).
        director       = c.decodeFlexibleString(forKey: .director)
        actors         = c.decodeFlexibleString(forKey: .actors)
        country        = try? c.decode(String.self, forKey: .country)

        // rating: Dispatcharr can send either "7.5" (string) or 7.5
        // (number). The serializer falls back to `0` when nothing is
        // set, which we treat as nil here so the UI's
        // empty-rating skip logic still works.
        if let s = try? c.decode(String.self, forKey: .rating) {
            rating = s
        } else if let d = try? c.decode(Double.self, forKey: .rating), d > 0 {
            rating = String(d)
        } else {
            rating = nil
        }

        tmdbID         = try? c.decode(String.self, forKey: .tmdbID)
        imdbID         = try? c.decode(String.self, forKey: .imdbID)
        youtubeTrailer = try? c.decode(String.self, forKey: .youtubeTrailer)
        durationSecs   = try? c.decode(Int.self, forKey: .durationSecs)
        age            = try? c.decode(String.self, forKey: .age)

        // backdrop_path: array shape preferred (Dispatcharr stores
        // them as lists); tolerate scalar in case an upstream provider
        // sends a single string.
        if let arr = try? c.decode([String].self, forKey: .backdropPath) {
            backdropPath = arr.filter { !$0.isEmpty }
        } else if let single = try? c.decode(String.self, forKey: .backdropPath),
                  !single.isEmpty {
            backdropPath = [single]
        } else {
            backdropPath = nil
        }

        cover     = try? c.decode(String.self, forKey: .cover)
        coverBig  = try? c.decode(String.self, forKey: .coverBig)
        movieImage = try? c.decode(String.self, forKey: .movieImage)
    }
}

/// v1.6.12: response shape for `/api/vod/series/<id>/provider-info/`.
/// Mirrors the movie provider-info action but keeps `custom_properties`
/// nested (Dispatcharr's `series_info()` endpoint doesn't flatten the
/// dict the way `MovieViewSet.provider_info` does — see
/// `apps/vod/api_views.py.SeriesViewSet.series_info`). The nested
/// blob carries the same TMDB-derived keys we already decode for
/// movies (cast, director, backdrop_path, youtube_trailer, country,
/// release dates), so we reuse `DispatcharrVODCustomProperties`
/// here.
///
/// Series typically populate `cast` (not `actors`) inside
/// `custom_properties` per Dispatcharr's `process_series_batch()`
/// in `tasks.py`. The shared decoder accepts either key, so this
/// is transparent.
struct DispatcharrVODSeriesProviderInfo: Decodable {
    let name: String?
    let description: String?
    let year: Int?
    let genre: String?
    let rating: String?
    let tmdbID: String?
    let imdbID: String?
    let cover: DispatcharrVODLogo?
    let customProperties: DispatcharrVODCustomProperties?

    enum CodingKeys: String, CodingKey {
        case name, description, year, genre, cover
        case rating
        case tmdbID = "tmdb_id"
        case imdbID = "imdb_id"
        case customProperties = "custom_properties"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name        = try? c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
        year        = try? c.decode(Int.self, forKey: .year)
        genre       = try? c.decode(String.self, forKey: .genre)
        // rating: same string-or-number tolerance as movie info.
        if let s = try? c.decode(String.self, forKey: .rating) {
            rating = s
        } else if let d = try? c.decode(Double.self, forKey: .rating), d > 0 {
            rating = String(d)
        } else {
            rating = nil
        }
        tmdbID           = try? c.decode(String.self, forKey: .tmdbID)
        imdbID           = try? c.decode(String.self, forKey: .imdbID)
        cover            = try? c.decode(DispatcharrVODLogo.self, forKey: .cover)
        customProperties = try? c.decode(DispatcharrVODCustomProperties.self,
                                         forKey: .customProperties)
    }
}

struct DispatcharrVODEpisode: Decodable, Identifiable {
    let id: Int
    let uuid: String
    let title: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let plot: String?
    let streams: [DispatcharrVODStreamOption]?

    // v1.6.12: episode-specific TMDB columns + custom_properties.
    // The episode `customProperties` shape is leaner than movie's
    // (just `info`, `crew`, `movie_image`, `backdrop_path`,
    // `season_number`) — we reuse the same struct because all of its
    // fields are optional and the keys we care about (backdrop) are
    // a superset.
    let airDate: String?
    let rating: String?
    let durationSecs: Int?
    let tmdbID: String?
    let imdbID: String?
    let customProperties: DispatcharrVODCustomProperties?

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case title
        case name
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case plot
        case overview
        case description
        case streams
        case airDate          = "air_date"
        case rating
        case durationSecs     = "duration_secs"
        case tmdbID           = "tmdb_id"
        case imdbID           = "imdb_id"
        case customProperties = "custom_properties"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? c.decode(Int.self, forKey: .id) {
            id = intID
        } else if let strID = try? c.decode(String.self, forKey: .id), let parsed = Int(strID) {
            id = parsed
        } else {
            id = 0
        }
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? (try? c.decode(String.self, forKey: .name)) ?? ""
        seasonNumber = try? c.decode(Int.self, forKey: .seasonNumber)
        episodeNumber = try? c.decode(Int.self, forKey: .episodeNumber)
        // v1.6.16.x: real-API verification (Dispatcharr 0.7.x via
        // /api/vod/series/{id}/episodes/) showed the plot field is
        // sent as `description`, not `plot`/`overview`. The
        // existing fallback chain pre-1.6.16.x silently dropped
        // every episode plot. Adding `description` as the first
        // preference reflects the actual response shape; `plot`
        // and `overview` are kept as fallbacks for older or
        // forked Dispatcharr builds that may still emit them.
        plot = (try? c.decode(String.self, forKey: .description))
            ?? (try? c.decode(String.self, forKey: .plot))
            ?? (try? c.decode(String.self, forKey: .overview))
        // v1.6.16.x: Dispatcharr's actual response uses a `providers`
        // array, not `streams` — the field names match
        // `DispatcharrVODStreamOption` won't apply directly because
        // the wire shape nests differently (each provider object
        // has `id`, `episode`, `m3u_account`, no top-level
        // `stream_id`). API verification confirms the legacy
        // `streams` key never appears in current Dispatcharr
        // builds. We accept the nil here — `proxyEpisodeURL`
        // happily generates a working stream URL without
        // `preferredStreamID` (Dispatcharr picks the default
        // provider server-side). If a forked Dispatcharr build
        // still emits the legacy `streams` array this `try?`
        // path picks it up.
        streams = try? c.decode([DispatcharrVODStreamOption].self, forKey: .streams)

        airDate          = try? c.decode(String.self, forKey: .airDate)
        rating           = try? c.decode(String.self, forKey: .rating)
        durationSecs     = try? c.decode(Int.self, forKey: .durationSecs)
        tmdbID           = try? c.decode(String.self, forKey: .tmdbID)
        imdbID           = try? c.decode(String.self, forKey: .imdbID)
        customProperties = try? c.decode(DispatcharrVODCustomProperties.self,
                                         forKey: .customProperties)
    }
}

struct DispatcharrChannelGroup: Decodable, Identifiable {
    let id: Int
    let name: String
    let channelCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case channelCount = "channel_count"
    }
}


// MARK: - Catch-up (timeshift) support

/// A resolved, playable catch-up request: the timeshift URL for the
/// programme plus everything the player needs to REBUILD that URL when the
/// user scrubs (the timeshift protocol's only random access is the start
/// time encoded in the URL path).
struct CatchupPlayback: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
    /// IANA zone the panel parses the URL's start segment in
    /// (Dispatcharr = "UTC"; a raw XC panel advertises its own).
    let panelTimeZoneID: String
    let programStart: Date
    let programEnd: Date
    let title: String
    let headers: [String: String]
    /// Task #149: non-nil only on the NATIVE Dispatcharr sessions path
    /// (dev PR #1432). Seeks then re-mint a session at
    /// programmeStart+offset instead of rebuilding an XC wall-clock URL,
    /// and teardown revokes the session (frees the per-session provider
    /// slot ahead of its 10-minute idle TTL).
    var nativeChannelUUID: String? = nil
    /// API auth headers for native session mint/revoke calls (the
    /// playback URL itself needs none). Empty on the XC paths.
    var nativeAuthHeaders: [String: String] = [:]

    var programDurationMs: Int32 {
        Int32(max(0, programEnd.timeIntervalSince(programStart)) * 1000)
    }
}

enum CatchupError: LocalizedError {
    case notCatchup
    case missingXCPassword
    case unsupportedServer
    case badURL

    var errorDescription: String? {
        switch self {
        case .notCatchup:
            return "This channel has no catch-up archive."
        case .missingXCPassword:
            return "Catch-up needs an XC password on your Dispatcharr user. Ask an admin to set one under Users in Dispatcharr."
        case .unsupportedServer:
            return "Catch-up is available on Dispatcharr and Xtream Codes servers."
        case .badURL:
            return "Could not build a catch-up URL for this programme."
        }
    }
}

/// Builds and resolves XC/Dispatcharr timeshift URLs. Mirrors the shipped
/// AerioTV-Android implementation (CatchupUrlBuilder + CatchupPlaybackResolver)
/// so the two platforms speak the identical protocol:
///
///   {base}/timeshift/{user}/{pass}/{durationMinutes}/{YYYY-MM-DD:HH-MM}/{streamID}.ts
///
/// THE FOOTGUN is the start segment: the panel parses it as wall-clock time
/// in ITS OWN timezone (server_info.timezone), NOT UTC and NOT device-local.
/// Dispatcharr pins its zone to UTC; a raw XC panel's zone is fetched from
/// the player_api handshake. Two device-verified Dispatcharr behaviors are
/// baked in: (1) never pre-resolve the 301 that appends ?session_id= (the
/// session is bound to the request that created it; a probe SPENDS it and
/// the player's real open 404s); (2) the response advertises an ESTIMATED
/// Content-Length, so the player must not trust it for end-seeks -- seeks
/// re-tune by rebuilding the URL instead.
@MainActor
enum CatchupSupport {

    /// Per-server-id memo of Dispatcharr XC credentials (username, xc_password).
    private static var xcCredsCache: [UUID: (String, String)] = [:]
    /// Per-server-id memo of the XC panel's advertised timezone.
    private static var panelTzCache: [UUID: String] = [:]
    /// Task #149: whether a Dispatcharr base supports the native catch-up
    /// sessions API (POST /api/catchup/sessions/, dev PR #1432). false is
    /// cached after a 404 so stable-tag servers pay the probe once per
    /// process; absent = not probed yet.
    private static var nativeSupportCache: [String: Bool] = [:]

    /// Native session mint outcome. `.unsupported` = the endpoint 404ed
    /// (stable-tag server or unknown channel uuid) - fall back to XC.
    enum NativeMintResult: Sendable {
        case created(URL)
        case unsupported
        case error
    }

    /// Task #149: POST /api/catchup/sessions/ {channel_uuid, start}. The
    /// response's playback_url is server-relative and header-free (the
    /// session rides its query string); this returns it absolutized
    /// against `base`. `start` renders as ISO-8601 UTC seconds - one of
    /// the server's accepted shapes - and selects WHICH archived show
    /// (or programmeStart+offset for the floored-minute seek model).
    ///
    /// Task #183: `durationMinutes` is our guide's programme length. The
    /// server (dev 14bfd25d) prefers it over ITS EPG-derived duration and
    /// adds its own provider-lag buffer, so send the exact length - do not
    /// pre-pad. Older servers ignore unknown fields, so this is safe to
    /// send unconditionally.
    nonisolated static func mintNativeSession(base: String,
                                              authHeaders: [String: String],
                                              channelUUID: String,
                                              start: Date,
                                              durationMinutes: Int? = nil) async -> NativeMintResult {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(trimmedBase)/api/catchup/sessions/") else { return .error }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in authHeaders { request.setValue(v, forHTTPHeaderField: k) }
        var body: [String: Any] = [
            "channel_uuid": channelUUID,
            "start": iso.string(from: start),
        ]
        if let minutes = durationMinutes, minutes >= 1 { body["duration"] = minutes }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await HTTPRouter.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .error }
        if status == 404 { return .unsupported }
        guard (200...299).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playbackPath = obj["playback_url"] as? String,
              let playbackURL = URL(string: trimmedBase + playbackPath) else {
            return .error
        }
        debugLog("[CATCHUP] native session minted host=\(playbackURL.host ?? "?") start=\(iso.string(from: start))")
        return .created(playbackURL)
    }

    /// Task #149: mint a fresh native session for a seek re-tune at
    /// programmeStart+offset. Base host is taken from the playback's
    /// CURRENT URL so LAN/WAN routing follows the original mint. nil on
    /// any failure (the caller keeps the current window playing).
    nonisolated static func remintNative(playback: CatchupPlayback,
                                         currentURL: URL,
                                         offsetSeconds: Double) async -> URL? {
        guard let uuid = playback.nativeChannelUUID,
              let scheme = currentURL.scheme, let host = currentURL.host else { return nil }
        let port = currentURL.port.map { ":\($0)" } ?? ""
        let base = "\(scheme)://\(host)\(port)"
        let start = playback.programStart.addingTimeInterval(max(0, offsetSeconds))
        // Task #183: window the re-minted session to the REMAINING length
        // (start is mid-programme). Full length would overshoot into the
        // next show by the seek offset; nil past the end lets the server
        // fall back to its default window.
        let remainingSecs = playback.programEnd.timeIntervalSince(start)
        let remainingMinutes = remainingSecs > 0 ? max(1, Int((remainingSecs / 60).rounded(.up))) : nil
        if case .created(let url) = await mintNativeSession(base: base,
                                                            authHeaders: playback.nativeAuthHeaders,
                                                            channelUUID: uuid,
                                                            start: start,
                                                            durationMinutes: remainingMinutes) {
            return url
        }
        return nil
    }

    /// Task #149: best-effort revoke of the session embedded in a native
    /// playback URL (frees the per-session provider slot ahead of the
    /// idle TTL). The route needs the TRAILING SLASH - Django
    /// redirects/404s without it. No-op on XC-shaped URLs.
    nonisolated static func revokeNative(playback: CatchupPlayback, currentURL: URL) {
        guard playback.nativeChannelUUID != nil,
              let scheme = currentURL.scheme, let host = currentURL.host,
              let comps = URLComponents(url: currentURL, resolvingAgainstBaseURL: false),
              let sessionID = comps.queryItems?.first(where: { $0.name == "session_id" })?.value,
              !sessionID.isEmpty else { return }
        let port = currentURL.port.map { ":\($0)" } ?? ""
        guard let url = URL(string: "\(scheme)://\(host)\(port)/api/catchup/sessions/\(sessionID)/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        for (k, v) in playback.nativeAuthHeaders { request.setValue(v, forHTTPHeaderField: k) }
        Task { _ = try? await HTTPRouter.data(for: request) }
    }

    /// Task #183: report the local playhead / pause state for a native
    /// catch-up session (POST /api/catchup/sessions/<id>/position/, dev
    /// 6f62d807). Keeps the server's admin stats aligned with what the
    /// viewer actually sees after local pause/scrub AND refreshes the
    /// session's idle TTL - which protects a long-paused session from
    /// expiring. Does NOT seek the stream.
    ///
    /// Returns false ONLY when the endpoint is absent (404 - stable-tag
    /// server): the caller should stop reporting for this playback.
    /// Transient failures return true so reporting continues.
    nonisolated static func reportNativePosition(playback: CatchupPlayback,
                                                 currentURL: URL,
                                                 positionSecs: Double,
                                                 paused: Bool) async -> Bool {
        guard playback.nativeChannelUUID != nil,
              let scheme = currentURL.scheme, let host = currentURL.host,
              let comps = URLComponents(url: currentURL, resolvingAgainstBaseURL: false),
              let sessionID = comps.queryItems?.first(where: { $0.name == "session_id" })?.value,
              !sessionID.isEmpty else { return true }
        let port = currentURL.port.map { ":\($0)" } ?? ""
        // Trailing slash required - Django redirects/404s without it.
        guard let url = URL(string: "\(scheme)://\(host)\(port)/api/catchup/sessions/\(sessionID)/position/") else { return true }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in playback.nativeAuthHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "position_secs": max(0, positionSecs),
            "paused": paused,
        ])
        guard let (_, response) = try? await HTTPRouter.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return true }
        if status == 404 {
            debugLog("[CATCHUP] position endpoint absent (404) - disabling reports for this playback")
            return false
        }
        return true
    }

    /// Channel UUID from a Dispatcharr live proxy URL
    /// (/proxy/ts/stream/<uuid>); nil for any other shape.
    nonisolated static func dispatcharrChannelUUID(fromStreamURL url: URL?) -> String? {
        guard let str = url?.absoluteString,
              let r = str.range(of: "/proxy/ts/stream/") else { return nil }
        let tail = String(str[r.upperBound...])
        let uuid = tail.split(separator: "?").first.map(String.init)?
            .split(separator: "/").first.map(String.init)
        return (uuid?.isEmpty == false) ? uuid : nil
    }

    /// Render an epoch date in the panel's zone as the canonical XC start
    /// shape `YYYY-MM-DD:HH-MM` (iPlayTV / TiviMate colon-dash form).
    nonisolated static func formatStart(_ date: Date, panelTimeZoneID: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd:HH-mm"
        fmt.timeZone = TimeZone(identifier: panelTimeZoneID) ?? TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    /// Build the timeshift URL for the programme [start, end).
    nonisolated static func buildTimeshiftURL(base: String,
                                  username: String,
                                  password: String,
                                  streamID: String,
                                  programStart: Date,
                                  programEnd: Date,
                                  panelTimeZoneID: String) -> URL? {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let durationMin = max(1, Int(ceil(programEnd.timeIntervalSince(programStart) / 60.0)))
        let start = formatStart(programStart, panelTimeZoneID: panelTimeZoneID)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        return URL(string: "\(trimmedBase)/timeshift/\(user)/\(pass)/\(durationMin)/\(start)/\(streamID).ts")
    }

    /// Rebuild an existing timeshift URL to start `offsetSeconds` into the
    /// programme -- the scrub/seek primitive. Credentials, host, and stream
    /// id are reused verbatim; only the {durationMin}/{start} path segments
    /// are replaced. The start segment has MINUTE granularity, so callers
    /// floor the offset to the minute and seek the residual in-stream.
    nonisolated static func rebuildForOffset(url: URL,
                                 panelTimeZoneID: String,
                                 programStart: Date,
                                 programEnd: Date,
                                 offsetSeconds: Double) -> URL? {
        let str = url.absoluteString
        guard let regex = try? NSRegularExpression(
            pattern: "/timeshift/([^/]+)/([^/]+)/(\\d+)/([^/]+)/") else { return nil }
        let range = NSRange(str.startIndex..., in: str)
        guard let m = regex.firstMatch(in: str, range: range),
              let full = Range(m.range, in: str),
              let userR = Range(m.range(at: 1), in: str),
              let passR = Range(m.range(at: 2), in: str) else { return nil }
        let newStartDate = programStart.addingTimeInterval(max(0, offsetSeconds))
        let durationMin = max(1, Int(ceil(programEnd.timeIntervalSince(newStartDate) / 60.0)))
        let start = formatStart(newStartDate, panelTimeZoneID: panelTimeZoneID)
        let replacement = "/timeshift/\(str[userR])/\(str[passR])/\(durationMin)/\(start)/"
        return URL(string: str.replacingCharacters(in: full, with: replacement))
    }

    /// Derive the Dispatcharr base (scheme://host:port) from a live proxy
    /// stream URL so catch-up follows the SAME LAN/WAN host the live stream
    /// resolved to. nil when the URL isn't a recognizable proxy URL.
    nonisolated static func dispatcharrBase(fromStreamURL url: URL?) -> String? {
        guard let str = url?.absoluteString, let r = str.range(of: "/proxy/") else { return nil }
        return String(str[..<r.lowerBound])
    }

    /// Resolve a past programme on a catch-up channel into a playable
    /// timeshift request for the given server. Throws CatchupError with a
    /// user-facing message on the known failure shapes.
    static func resolve(server: ServerConnection,
                        channel: ChannelDisplayItem,
                        programTitle: String,
                        programStart: Date,
                        programEnd: Date) async throws -> CatchupPlayback {
        guard channel.hasCatchup else { throw CatchupError.notCatchup }
        switch server.type {
        case .dispatcharrAPI:
            // Task #149: prefer the native sessions API (normal auth on
            // the mint, header-free playback URL, per-session provider
            // slot, no xc_password dependency). One 404 marks the base
            // legacy for the process and we fall through to the XC
            // /timeshift/ path below - which also remains THE protocol
            // for genuine Xtream Codes servers (next case), forever.
            let nativeBase = dispatcharrBase(fromStreamURL: channel.streamURL) ?? server.effectiveBaseURL
            if let channelUUID = dispatcharrChannelUUID(fromStreamURL: channel.streamURL),
               nativeSupportCache[nativeBase] != false {
                let key = server.effectiveApiKey
                var authHeaders: [String: String] = [:]
                if !key.isEmpty {
                    authHeaders["X-API-Key"] = key
                    authHeaders["Authorization"] = "ApiKey \(key)"
                }
                let ua = server.effectiveUserAgent
                if !ua.isEmpty { authHeaders["User-Agent"] = ua }
                let programSecs = programEnd.timeIntervalSince(programStart)
                let programMinutes = programSecs > 0 ? max(1, Int((programSecs / 60).rounded())) : nil
                switch await mintNativeSession(base: nativeBase,
                                               authHeaders: authHeaders,
                                               channelUUID: channelUUID,
                                               start: programStart,
                                               durationMinutes: programMinutes) {
                case .created(let playbackURL):
                    nativeSupportCache[nativeBase] = true
                    var headers: [String: String] = [:]
                    if !ua.isEmpty { headers["User-Agent"] = ua }
                    return CatchupPlayback(url: playbackURL,
                                           panelTimeZoneID: "UTC",
                                           programStart: programStart,
                                           programEnd: programEnd,
                                           title: programTitle,
                                           headers: headers,
                                           nativeChannelUUID: channelUUID,
                                           nativeAuthHeaders: authHeaders)
                case .unsupported:
                    nativeSupportCache[nativeBase] = false
                case .error:
                    // Transient (5xx/transport): fall back to XC for THIS
                    // attempt without caching a verdict.
                    break
                }
            }
            // The /timeshift/ endpoint takes PATH-embedded XC creds only
            // (no JWT/ApiKey), readable by the authenticated user from
            // /api/accounts/users/me/. Memoized per server.
            let creds: (String, String)
            if let cached = xcCredsCache[server.id] {
                creds = cached
            } else {
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                         auth: .apiKey(server.effectiveApiKey),
                                         userAgent: server.effectiveUserAgent,
                                         authMode: server.dispatcharrHeaderMode,
                                         serverID: server.id,
                                         savedUsername: server.username.isEmpty ? nil : server.username)
                let user = try await api.fetchCurrentUser()
                guard let xcPass = user.xcPassword else { throw CatchupError.missingXCPassword }
                creds = (user.username, xcPass)
                xcCredsCache[server.id] = creds
            }
            // Follow the live stream's host (LAN/WAN-aware) when possible.
            let base = dispatcharrBase(fromStreamURL: channel.streamURL) ?? server.effectiveBaseURL
            guard let streamID = channel.dispatcharrChannelID.map(String.init) ?? Optional(channel.id),
                  let url = buildTimeshiftURL(base: base,
                                              username: creds.0,
                                              password: creds.1,
                                              streamID: streamID,
                                              programStart: programStart,
                                              programEnd: programEnd,
                                              panelTimeZoneID: "UTC") else {
                throw CatchupError.badURL
            }
            var headers: [String: String] = [:]
            let ua = server.effectiveUserAgent
            if !ua.isEmpty { headers["User-Agent"] = ua }
            // Creds live in the URL path; log only the shape, never the URL.
            debugLog("[CATCHUP] resolved Dispatcharr timeshift host=\(url.host ?? "?") stream=\(streamID) start=\(formatStart(programStart, panelTimeZoneID: "UTC")) durMin=\(Int(programEnd.timeIntervalSince(programStart) / 60))")
            return CatchupPlayback(url: url,
                                   panelTimeZoneID: "UTC",
                                   programStart: programStart,
                                   programEnd: programEnd,
                                   title: programTitle,
                                   headers: headers)
        case .xtreamCodes:
            let tz: String
            if let cached = panelTzCache[server.id] {
                tz = cached
            } else {
                let api = XtreamCodesAPI(baseURL: server.effectiveBaseURL,
                                         username: server.username,
                                         password: server.effectivePassword)
                let info = try? await api.verifyConnection()
                tz = info?.serverInfo?.timezone ?? "UTC"
                // Memoize only a REAL answer: caching the UTC fallback
                // after one transient handshake failure poisoned every
                // later catch-up on a non-UTC panel for the whole run
                // (Android deliberately caches on success only).
                if info?.serverInfo?.timezone != nil {
                    panelTzCache[server.id] = tz
                }
            }
            guard let url = buildTimeshiftURL(base: server.effectiveBaseURL,
                                              username: server.username,
                                              password: server.effectivePassword,
                                              streamID: channel.id,
                                              programStart: programStart,
                                              programEnd: programEnd,
                                              panelTimeZoneID: tz) else {
                throw CatchupError.badURL
            }
            var headers: [String: String] = [:]
            let ua = server.effectiveUserAgent
            if !ua.isEmpty { headers["User-Agent"] = ua }
            // Creds live in the URL path; log only the shape, never the URL.
            debugLog("[CATCHUP] resolved XC timeshift host=\(url.host ?? "?") stream=\(channel.id) tz=\(tz) start=\(formatStart(programStart, panelTimeZoneID: tz)) durMin=\(Int(programEnd.timeIntervalSince(programStart) / 60))")
            return CatchupPlayback(url: url,
                                   panelTimeZoneID: tz,
                                   programStart: programStart,
                                   programEnd: programEnd,
                                   title: programTitle,
                                   headers: headers)
        default:
            throw CatchupError.unsupportedServer
        }
    }
}
