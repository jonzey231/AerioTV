import Foundation

// MARK: - Stream Format Classification
/// Classifies a stream URL as HLS, MPEG-TS, or unknown to decide which player engine to use.
enum StreamFormat {
    case hls
    case mpegTS
    case unknown
}

/// Inspects a URL's path/extension to determine the likely stream format.
/// Conservative: only classifies as HLS when the extension is literally `.m3u8`.
/// Path-based heuristics (e.g. "/proxy/hls/") are unreliable because many
/// servers return raw MPEG-TS from those endpoints despite the name.
func classifyStreamURL(_ url: URL) -> StreamFormat {
    let ext  = url.pathExtension.lowercased()
    // HLS — only trust the file extension, not the path
    if ext == "m3u8" {
        return .hls
    }
    // MPEG-TS
    if ext == "ts" || url.path.lowercased().contains("/proxy/ts/") {
        return .mpegTS
    }
    return .unknown
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
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    private static let largeLibrarySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
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
        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        let (data, response) = try await HTTPRouter.data(from: url, using: Self.largeLibrarySession)
        try validate(response: response)
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
        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        let (data, response) = try await HTTPRouter.data(from: url, using: Self.largeLibrarySession)
        try validate(response: response)
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
    func m3uURL() -> URL? {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(base)/get.php?username=\(username)&password=\(password)&type=m3u_plus")
    }

    /// Fetch the M3U and return a dict of [streamName: streamURL] for URL lookup.
    /// Also keyed by tvg-id for EPG matching.
    func fetchM3UStreamURLs() async throws -> [String: URL] {
        guard let url = m3uURL() else { throw APIError.invalidURL }
        let (data, response) = try await loggedData(from: url)
        try validate(response: response)
        guard let content = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError(NSError(domain: "M3U", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode M3U as UTF-8"]))
        }
        let channels = M3UParser.parse(content: content)
        var dict: [String: URL] = [:]
        for ch in channels {
            guard let streamURL = URL(string: ch.url) else { continue }
            // Key by name (lowercased for matching)
            dict[ch.name.lowercased()] = streamURL
            // Also key by tvg-id if present
            if !ch.tvgID.isEmpty {
                dict["tvgid:\(ch.tvgID.lowercased())"] = streamURL
            }
            // Also key by tvg-name if present
            if !ch.tvgName.isEmpty {
                dict["tvgname:\(ch.tvgName.lowercased())"] = streamURL
            }
        }
        return dict
    }

    /// Build ordered stream URL attempts for a channel.
    /// Xtream standard: /live/user/pass/stream_id.ext
    /// tvOS: .m3u8 first (AVPlayer needs HLS). iOS: .ts first (MPV handles it natively).
    /// Note: requires Dispatcharr stream profile set to "Redirect" to work correctly.
    func streamURLs(for stream: XtreamStream) -> [URL] {
        var urls: [URL] = []
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        #if os(tvOS)
        // HLS first — AVPlayer (only engine on tvOS) needs .m3u8
        if let url = URL(string: "\(base)/live/\(username)/\(password)/\(stream.streamID).m3u8") {
            urls.append(url)
        }
        if let url = URL(string: "\(base)/live/\(username)/\(password)/\(stream.streamID).ts") {
            urls.append(url)
        }
        #else
        // MPEG-TS first — MPV (primary engine on iOS) handles .ts natively
        if let url = URL(string: "\(base)/live/\(username)/\(password)/\(stream.streamID).ts") {
            urls.append(url)
        }
        if let url = URL(string: "\(base)/live/\(username)/\(password)/\(stream.streamID).m3u8") {
            urls.append(url)
        }
        #endif
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
    let userInfo: UserInfo
    enum CodingKeys: String, CodingKey { case userInfo = "user_info" }
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
    let num: Int?
    let allowedOutputFormats: [String]?  // e.g. ["ts"], ["ts","m3u8"]
    let directSource: String?            // sometimes set to a direct HLS URL

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
        num = try? c.decode(Int.self, forKey: .num)
        allowedOutputFormats = try? c.decode([String].self, forKey: .allowedOutputFormats)
        directSource = try? c.decode(String.self, forKey: .directSource)
        id = num ?? streamID
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
            if let nextStr = wrapped.next, let next = URL(string: nextStr) {
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
        let rows = try await fetchAllPages(DispatcharrEPGData.self,
                                            firstPath: "/api/epg/epgdata/?page_size=500")
        var map: [Int: String] = [:]
        map.reserveCapacity(rows.count)
        for row in rows where !row.tvgID.isEmpty {
            map[row.id] = row.tvgID
        }
        return map
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
            var nextURL = wrapped.next.flatMap { URL(string: $0) }
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
                nextURL = page.next.flatMap { URL(string: $0) }
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
                if let nextStr = wrapped.next, let next = URL(string: nextStr) {
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
    func getVODMoviesStream(category: String? = nil) -> AsyncThrowingStream<[DispatcharrVODMovie], Error> {
        makePageStream(firstPath: Self.moviesPath(category: category))
    }

    func getVODSeriesStream(category: String? = nil) -> AsyncThrowingStream<[DispatcharrVODSeries], Error> {
        makePageStream(firstPath: Self.seriesPath(category: category))
    }

    private static func moviesPath(category: String?) -> String {
        guard let category, !category.isEmpty else {
            return "/api/vod/movies/?page_size=100"
        }
        let encoded = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        return "/api/vod/movies/?page_size=100&category=\(encoded)"
    }

    private static func seriesPath(category: String?) -> String {
        guard let category, !category.isEmpty else {
            return "/api/vod/series/?page_size=100"
        }
        let encoded = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        return "/api/vod/series/?page_size=100&category=\(encoded)"
    }

    /// Server-side search — uses DRF's ?search= filter so items not yet locally fetched are found.
    func searchVODMoviesStream(query: String) -> AsyncThrowingStream<[DispatcharrVODMovie], Error> {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return makePageStream(firstPath: "/api/vod/movies/?search=\(encoded)&page_size=100")
    }

    func searchVODSeriesStream(query: String) -> AsyncThrowingStream<[DispatcharrVODSeries], Error> {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
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
    private func makePageStream<T: Decodable & Sendable>(firstPath: String) -> AsyncThrowingStream<[T], Error> {
        return AsyncThrowingStream { [self] continuation in
            Task {
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
                        if totalYielded >= Self.vodPaginationItemCap {
                            let serverTotal = wrapped.count.map { "\($0)" } ?? "unknown"
                            debugLog("📺 VOD pagination: hit item cap \(Self.vodPaginationItemCap) for \(firstPath) (server reported total: \(serverTotal))")
                            continuation.finish()
                            return
                        }
                        if let nextStr = wrapped.next, let next = URL(string: nextStr) {
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
        while let nextStr = nextURLString, let nextURL = URL(string: nextStr) {
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
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

            // Prevent URLSession from auto-following so we can capture the redirected Location.
            let (data, response) = try await session.data(for: req, delegate: RedirectBlocker())
            guard let http = response as? HTTPURLResponse else { return current }

            if (300...399).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: loc, relativeTo: current)?.absoluteURL {
                current = next
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

    enum CodingKeys: String, CodingKey {
        case id, categories, rating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        categories = (try? c.decode([String].self, forKey: .categories)) ?? []
        rating = try? c.decode(String.self, forKey: .rating)
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
