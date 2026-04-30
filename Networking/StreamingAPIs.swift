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
    private var session: URLSession { Self.session }

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
        // VOD libraries can be very large — use a dedicated session with generous timeouts
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        let vodSession = URLSession(configuration: config)
        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        let (data, response) = try await HTTPRouter.data(from: url, using: vodSession)
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
        // Series libraries can be very large — use a dedicated session with generous timeouts
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        let seriesSession = URLSession(configuration: config)
        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        let (data, response) = try await HTTPRouter.data(from: url, using: seriesSession)
        try validate(response: response)
        // Some panels return false/null/object for empty or unavailable series — treat as empty
        if let items = try? decode([XtreamSeriesItem].self, from: data) { return items }
        DebugLogger.shared.log("XC get_series: non-array response (\(data.count) bytes) — treating as empty",
                               category: "VOD", level: .warning)
        return []
    }

    // MARK: - XMLTV EPG URL (for guide)
    func xmltvURL() -> URL? {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(base)/xmltv.php?username=\(username)&password=\(password)")
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
            throw APIError.decodingError(NSError(
                domain: "XtreamCodesAPI",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey:
                    "The server returned a web page instead of Xtream Codes API data. Double-check the Server URL — it should point to the Xtream-compatible endpoint (often a different port than the web admin). Verify by opening \(http.url?.absoluteString ?? "the URL") in a browser: you should see JSON, not a login page."
                ]
            ))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func decodeDispatcharrServerInfo(from data: Data) throws -> DispatcharrServerInfo {
        let decoder = JSONDecoder()

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
        cast = try? c.decode(String.self, forKey: .cast)
        director = try? c.decode(String.self, forKey: .director)
        genre = try? c.decode(String.self, forKey: .genre)
        releaseDate = try? c.decode(String.self, forKey: .releaseDate)
        youtubeTrailer = try? c.decode(String.self, forKey: .youtubeTrailer)
        id = streamID
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
        cast = try? c.decode(String.self, forKey: .cast)
        director = try? c.decode(String.self, forKey: .director)
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
        case bearer(String)
        case apiKey(String)
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

    init(baseURL: String, auth: Auth, userAgent: String = DeviceInfo.defaultUserAgent) {
        self.baseURL = baseURL
        self.auth = auth
        self.userAgent = userAgent
    }


    // Shared session — reused across all calls (avoid creating a new URLSession per request).
    // 20s per-request idle timeout mirrors XtreamCodesAPI's session: lets
    // error states (dead container, firewalled host, etc.) surface well
    // inside the 20s mark instead of the 60s Apple default that makes the
    // app feel "perpetually loading" to a user whose server is actually
    // down. Resource-wide 300s still covers large EPG/VOD payloads.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.session }

    private var headers: [String: String] {
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": userAgent
        ]
        switch auth {
        case .bearer(let token):
            h["Authorization"] = "Bearer \(token)"
        case .apiKey(let key):
            // v1.6.16.x: send X-API-Key alone for API-key auth.
            //
            // Pre-1.6.16.x sent BOTH `Authorization: ApiKey <key>`
            // AND `X-API-Key: <key>` "for compatibility". In
            // practice Dispatcharr's per-series episodes endpoint
            // returned `count=0` for some series with that
            // dual-header request even though X-API-Key alone (via
            // curl) returned the full episode list. Best guess:
            // adding the Authorization header switches Dispatcharr
            // from unrestricted API-key auth to a user-scoped
            // session whose visibility is filtered to a subset of
            // m3u_accounts; series whose providers fall outside
            // that subset come back empty. Series whose providers
            // happen to match the session's accounts work fine,
            // which is why this surfaced as an "intermittent"
            // 0-episodes bug — Spiral's providers included accounts
            // (#11, #22) the session couldn't see, while Lucky
            // Hank / Friends / Parks and Recreation were on
            // accounts the session could see. Dropping
            // Authorization here makes every endpoint route through
            // the same X-API-Key path.
            h["X-API-Key"] = key
        }
        return h
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
            "/api/version/",
            "/api/version"
        ]

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

        for path in candidatePaths {
            let url = try buildURL(path: path)
            lastURL = url
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

            let (data, response) = try await loggedData(for: request)

            if let http = response as? HTTPURLResponse {
                lastStatus = http.statusCode
                lastContentType = http.value(forHTTPHeaderField: "Content-Type")
            }

            // If it's not a 2xx, capture body snippet and try next.
            if (lastStatus ?? 0) < 200 || (lastStatus ?? 0) >= 300 {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                lastBodySnippet = String(body.prefix(800))
                attemptOutcomes.append(.httpError(lastStatus ?? 0))
                continue
            }

            // If it's HTML, it's almost certainly the web UI shell, not the API.
            if let ct = lastContentType?.lowercased(), ct.contains("text/html") {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                lastBodySnippet = String(body.prefix(800))
                attemptOutcomes.append(.html)
                continue
            }

            // Try decoding depending on endpoint.
            do {
                if path.contains("version") {
                    return try decodeDispatcharrServerInfo(from: data)
                } else if path.contains("channels/summary") {
                    _ = try decode([DispatcharrChannelSummary].self, from: data)
                    return DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                } else if path.contains("channels/channels") {
                    // Try paginated wrapper first (page_size=1), then flat array
                    if let _ = try? decode(DispatcharrResultsWrapper<DispatcharrChannel>.self, from: data) {
                        return DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                    }
                    _ = try decode([DispatcharrChannel].self, from: data)
                    return DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                } else if path.contains("channels/groups") {
                    // Try paginated wrapper first (page_size=1), then flat array
                    if let _ = try? decode(DispatcharrResultsWrapper<DispatcharrChannelGroup>.self, from: data) {
                        return DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                    }
                    _ = try decode([DispatcharrChannelGroup].self, from: data)
                    return DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                } else {
                    // /api/channels/ is an index document (links). Treat a JSON object with a "channels" key as valid.
                    let obj = try JSONSerialization.jsonObject(with: data)
                    if let dict = obj as? [String: Any], dict["channels"] != nil {
                        return DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                    }
                    throw APIError.decodingError(NSError(
                        domain: "DispatcharrAPI",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Expected channels index JSON object with a 'channels' key."]
                    ))
                }
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                lastBodySnippet = String(body.prefix(800))
                attemptOutcomes.append(.jsonDecodeFailed)
                continue
            }
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
        //   • 401/403 on every probe → authentication rejected.
        //   • Everything 4xx/5xx → server error.
        //   • Mixed/other → fall back to a generic "couldn't recognise
        //     the server response" message with the last body snippet
        //     as the final diagnostic breadcrumb.
        let urlString = lastURL?.absoluteString ?? "<unknown url>"
        // Relaxed from `all*` to `any*` because real-world
        // deployments routinely produce mixed outcomes — the
        // Dispatcharr SPA fallback returns 200 + HTML for unmatched
        // routes (e.g., `/api/version` on builds where that path
        // doesn't exist), so a wrong-API-key user sees 401 on the
        // five channel endpoints AND 200 HTML on `/api/version`.
        // The previous `all-or-nothing` test fell through to the
        // generic "couldn't recognise" message in that case, hiding
        // the much more useful "your API key is wrong" diagnosis.
        // 401/403 is the strongest signal we have so it wins over
        // an HTML fallback.
        let firstAuthErrorCode: Int? = attemptOutcomes.compactMap {
            if case .httpError(let s) = $0, s == 401 || s == 403 { return s }
            return nil
        }.first
        let anyHTML = attemptOutcomes.contains {
            if case .html = $0 { return true }
            return false
        }

        let message: String
        if let authCode = firstAuthErrorCode {
            message = """
                Dispatcharr rejected this request (HTTP \(authCode)). \
                Either the Admin API Key is empty/incorrect, or — more \
                often — the key belongs to a non-Admin user. Aerio needs \
                an Admin-level API key to list channels and groups, which \
                a user-scoped key can't do. In Dispatcharr, go to \
                System → Users → Edit User → API & XC, confirm the user \
                has Admin permissions, and copy that user's API Key into \
                the Admin API Key field above.
                """
        } else if anyHTML {
            message = """
                Dispatcharr returned the web UI instead of the API. This \
                usually means one of:
                  • Your Admin API Key is missing or incorrect. In \
                Dispatcharr, go to System → Users → Edit User → API & XC, \
                copy the API Key for an Admin user, and paste it into the \
                Admin API Key field above.
                  • The Server URL points at the web app but not at the API \
                (for example, a reverse proxy that strips or rewrites /api). \
                Verify the URL works by opening \(urlString) in a browser \
                while logged out — you should see a JSON error, not the \
                Dispatcharr login page.
                  • The URL is correct but the port is wrong. Confirm the \
                port matches the Dispatcharr API port on your server.
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

            if let list = try? JSONDecoder().decode([T].self, from: data) {
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

    // MARK: - Stream detail (Stream Info overlay) — v1.6.18

    /// Fetch a single stream's metadata + live `stream_stats` blob.
    /// Used by the Stream Info overlay on Dispatcharr API playback to
    /// surface server-side stats (resolution, FPS, codec, bitrate)
    /// alongside / in place of the mpv-derived client-side values.
    /// Returns `DispatcharrStreamDetail` whose `streamStats` is `nil`
    /// for streams Dispatcharr hasn't actively served yet.
    func getStreamDetail(streamID: Int) async throws -> DispatcharrStreamDetail {
        let url = try buildURL(path: "/api/channels/streams/\(streamID)/")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await HTTPRouter.data(for: request, using: URLSession.shared)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(DispatcharrStreamDetail.self, from: data)
        case 401, 403:
            throw APIError.unauthorized
        case 404:
            throw APIError.serverError(404)
        default:
            throw APIError.serverError(http.statusCode)
        }
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
        if let list = try? JSONDecoder().decode([DispatcharrCurrentProgram].self, from: data) {
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
        // 60s for the initial response headers + body start. Bumped
        // from 30s because large Dispatcharr instances (thousands of
        // channels × 25 hours of EPG) serialize a response big enough
        // that the database query + JSON encode genuinely needs more
        // time. Callers treat failure as non-fatal (per-cell prefetch
        // takes over), so false positives cost more UX pain than the
        // 30s extra worst case.
        request.timeoutInterval = 60
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // Use a dedicated session with generous timeout for this large response
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)

        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        let (data, response) = try await HTTPRouter.data(for: request, using: session)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Try {"data": [...]} wrapper (current Dispatcharr format)
        if let dataWrapper = try? JSONDecoder().decode(DispatcharrDataWrapper<DispatcharrCurrentProgram>.self, from: data) {
            return dataWrapper.data
        }
        // Try flat array
        if let list = try? JSONDecoder().decode([DispatcharrCurrentProgram].self, from: data) {
            return list
        }
        // Try {"results": [...]} DRF wrapper
        let wrapped = try decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: data)
        return wrapped.results
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
        // 5s fail-fast. The prior 10s tied up one uwsgi worker per
        // visible guide cell for 10 seconds when the server was
        // under duress, and per-cell prefetch is non-essential — the
        // bulk `getEPGGrid` path normally carries the data. Shorter
        // timeouts mean faster per-cell failure, which pairs with
        // the GuideStore circuit breaker to stop firing at all
        // once the server is proven unresponsive.
        var request = URLRequest(url: url, timeoutInterval: 5)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
        let (data, response) = try await HTTPRouter.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        var allItems: [DispatcharrCurrentProgram] = []
        if let list = try? JSONDecoder().decode([DispatcharrCurrentProgram].self, from: data) {
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
        let epgConfig = URLSessionConfiguration.default
        epgConfig.timeoutIntervalForRequest = 15
        epgConfig.timeoutIntervalForResource = 60
        let epgSession = URLSession(configuration: epgConfig)

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
            let (data, response) = try await HTTPRouter.data(for: request, using: epgSession)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { break }

            if let list = try? JSONDecoder().decode([DispatcharrCurrentProgram].self, from: data) {
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
        try await fetchAllPages(DispatcharrVODMovie.self, firstPath: "/api/vod/movies/?page_size=25")
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
        if let wrapped = try? JSONDecoder().decode(DispatcharrResultsWrapper<DispatcharrVODMovie>.self, from: data) {
            return wrapped.count ?? wrapped.results.count
        }
        if let list = try? JSONDecoder().decode([DispatcharrVODMovie].self, from: data) {
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
        if let wrapped = try? JSONDecoder().decode(DispatcharrResultsWrapper<DispatcharrVODSeries>.self, from: data) {
            return wrapped.count ?? wrapped.results.count
        }
        if let list = try? JSONDecoder().decode([DispatcharrVODSeries].self, from: data) {
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
        try await fetchAllPages(DispatcharrVODSeries.self, firstPath: "/api/vod/series/?page_size=25")
    }

    /// Fetches VOD categories from `/api/vod/categories/`.
    /// Each category has a name and type (movie/series).
    func getVODCategories() async throws -> [DispatcharrVODCategory] {
        try await fetchAllPages(DispatcharrVODCategory.self, firstPath: "/api/vod/categories/")
    }

    // MARK: - Progressive VOD streams
    // Yields one page at a time so the UI can display partial results immediately
    // instead of waiting for the entire library to load. Critical for large libraries
    // (e.g. 20 000+ movies ≈ 800 sequential API calls at page_size=25). The
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
            return "/api/vod/movies/?page_size=25"
        }
        let encoded = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        return "/api/vod/movies/?page_size=25&category=\(encoded)"
    }

    private static func seriesPath(category: String?) -> String {
        guard let category, !category.isEmpty else {
            return "/api/vod/series/?page_size=25"
        }
        let encoded = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        return "/api/vod/series/?page_size=25&category=\(encoded)"
    }

    /// Server-side search — uses DRF's ?search= filter so items not yet locally fetched are found.
    func searchVODMoviesStream(query: String) -> AsyncThrowingStream<[DispatcharrVODMovie], Error> {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return makePageStream(firstPath: "/api/vod/movies/?search=\(encoded)&page_size=25")
    }

    func searchVODSeriesStream(query: String) -> AsyncThrowingStream<[DispatcharrVODSeries], Error> {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return makePageStream(firstPath: "/api/vod/series/?search=\(encoded)&page_size=25")
    }

    /// Generic paginated stream — yields `[T]` for each DRF results page.
    private func makePageStream<T: Decodable & Sendable>(firstPath: String) -> AsyncThrowingStream<[T], Error> {
        // Capture value-type properties so the Task closure is @Sendable-safe.
        let capturedBase    = baseURL
        let capturedHeaders = headers
        return AsyncThrowingStream { continuation in
            Task {
                guard var nextURL = URL(string: capturedBase + firstPath) else {
                    continuation.finish(throwing: APIError.invalidURL)
                    return
                }
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest  = 30
                config.timeoutIntervalForResource = 120
                let sess = URLSession(configuration: config)
                while true {
                    var request = URLRequest(url: nextURL)
                    capturedHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    do {
                        // v1.6.10: HTTPRouter.data so HSTS-preloaded TLD HTTP URLs work.
                        let (data, response) = try await HTTPRouter.data(for: request, using: sess)
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
                        if let list = try? JSONDecoder().decode([T].self, from: data) {
                            if !list.isEmpty { continuation.yield(list) }
                            continuation.finish(); return
                        }
                        // DRF paginated wrapper
                        let wrapped = try JSONDecoder().decode(DispatcharrResultsWrapper<T>.self, from: data)
                        if !wrapped.results.isEmpty { continuation.yield(wrapped.results) }
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
        if let flat = try? JSONDecoder().decode([DispatcharrVODEpisode].self, from: data) {
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
        // Trailing slash improves routing consistency and reduces redirect edge cases.
        let urlString = baseURL + "/proxy/ts/stream/\(uuid)"
        return URL(string: urlString)
    }

    /// MPEG-TS stream by *channel UUID* (preferred for reliability + server-side failover).
    /// This keeps iOS tied to the channel container so Dispatcharr can fail over between providers/streams.
    func proxyTSChannelURL(channelUUID: String) -> URL? {
        let urlString = baseURL + "/proxy/ts/channel/\(channelUUID)"
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
    private func buildURL(path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
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

    /// Wraps the data fetch with DebugLogger timing and result logging.
    /// v1.6.10: routed through `HTTPRouter` so plain-HTTP requests against
    /// HSTS-preloaded TLDs (`.app`, `.dev`, etc.) bypass URLSession's
    /// HSTS layer via Network.framework. URLSession remains the path for
    /// HTTPS, IP literals, and non-preloaded TLDs.
    private func loggedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let urlStr = request.url?.absoluteString ?? "<unknown>"
        let start  = Date()
        do {
            let result   = try await HTTPRouter.data(for: request, using: session)
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
            return try JSONDecoder().decode(type, from: data)
        } catch {
            DebugLogger.shared.logDecodeError(type: String(describing: T.self), error: error,
                                              payloadSnippet: String(data: data, encoding: .utf8).map { String($0.prefix(200)) })
            throw APIError.decodingError(error)
        }
    }

    private func decodeDispatcharrServerInfo(from data: Data) throws -> DispatcharrServerInfo {
        let decoder = JSONDecoder()

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

// MARK: - Dispatcharr Response Models
struct DispatcharrServerInfo: Decodable {
    let version: String?
    /// Optional human-friendly server name (key varies by backend/version).
    let serverName: String?

    enum CodingKeys: String, CodingKey {
        case version
        case serverName = "server_name"
        case name
    }

    init(version: String? = nil, serverName: String? = nil) {
        self.version = version
        self.serverName = serverName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decode(String.self, forKey: .version)
        // Prefer explicit server_name, fall back to name.
        serverName = (try? c.decode(String.self, forKey: .serverName)) ?? (try? c.decode(String.self, forKey: .name))
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

/// Current program for a channel as returned by `/api/epg/current-programs/` or `/api/epg/programs/`.
/// Schema: ProgramData — fields include tvg_id, title, start_time, end_time, channel, channel_name.
struct DispatcharrCurrentProgram: Decodable, Identifiable {
    var id: String { "\(tvgID ?? channel.map(String.init) ?? "?")-\(title)-\(startTime?.toDate()?.timeIntervalSince1970 ?? 0)" }

    let tvgID: String?
    let channel: Int?        // Dispatcharr channel ID
    let channelName: String? // Channel display name (if returned)
    let title: String
    let description: String
    let subTitle: String
    let startTime: DispatcharrDateValue?
    let endTime: DispatcharrDateValue?

    enum CodingKeys: String, CodingKey {
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

    /// Dispatcharr returns `channel_number` as a number that is often encoded as a float (e.g. 11444.0).
    /// Keep it as Double to avoid decoding failures.
    let channelNumber: Double?

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

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case channelNumber = "channel_number"
        case uuid
        case logoID = "logo_id"
        case streams
        case tvgID = "tvg_id"
        case epgDataID = "epg_data_id"
        // channelGroupID handled in init(from:)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        channelNumber = try container.decodeIfPresent(Double.self, forKey: .channelNumber)
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

        // Try both "channel_group_id" and "channel_group" keys
        enum ExtraKeys: String, CodingKey {
            case channelGroupID = "channel_group_id"
            case channelGroup   = "channel_group"
        }
        let extra = try decoder.container(keyedBy: ExtraKeys.self)
        channelGroupID = try extra.decodeIfPresent(Int.self, forKey: .channelGroupID)
            ?? extra.decodeIfPresent(Int.self, forKey: .channelGroup)
    }

    /// Convenience for UI sorting/display when you want an integer channel number.
    var channelNumberInt: Int? {
        guard let n = channelNumber else { return nil }
        return Int(n.rounded())
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
        let castKey   = try? c.decode(String.self, forKey: .cast)
        let actorsKey = try? c.decode(String.self, forKey: .actors)
        cast = castKey ?? actorsKey

        director = try? c.decode(String.self, forKey: .director)

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
        crew         = try? c.decode(String.self, forKey: .crew)
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
        director       = try? c.decode(String.self, forKey: .director)
        actors         = try? c.decode(String.self, forKey: .actors)
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

// MARK: - Stream Stats (v1.6.18)
//
// Server-side stats Dispatcharr publishes for streams that have been
// played through its proxy at least once. The web UI shows these as
// the stack of pill badges in the channel-streams table (resolution,
// FPS, codec, bitrate). Aerio surfaces them in the Stream Info
// overlay when the active server is Dispatcharr API — augments
// (and where possible replaces) the mpv-derived client-side stats.
//
// Schema sourced from Dispatcharr's `apps/proxy/ts_proxy/services/
// channel_service.py:_update_stream_stats_in_db` and verified live
// against `192.168.50.163:9191/api/channels/streams/?search=ESPN`
// on 2026-04-29. All fields are optional because Dispatcharr only
// populates stats once a stream has been actively played, and even
// then some fields (e.g. `width`/`height`) may be absent on older
// builds — the JSON blob is `JSONField(null=True, blank=True)` on
// the Stream model.

/// Live stats Dispatcharr's TS proxy collects from each stream.
/// Decoded from `Stream.stream_stats` (a Postgres JSONB column).
struct DispatcharrStreamStats: Decodable, Equatable {
    /// Pre-formatted "WIDTHxHEIGHT" (e.g. "1920x1080"). Prefer this
    /// over `width` × `height` for display since it matches the
    /// upstream-reported aspect even when Dispatcharr re-encodes.
    let resolution: String?
    let width: Int?
    let height: Int?

    /// Source FPS as float (e.g. 29.97, 59.94, 30.0). Some streams
    /// only report `container-fps` shape so the value can be a clean
    /// integer like 30.0; format with up to 2 decimals on display.
    let sourceFps: Double?

    /// Lower-case codec slug ("h264", "hevc", "mpeg2video", "av1").
    /// UI uppercases for badge display.
    let videoCodec: String?

    /// Source video bitrate in **kbps** when known.
    let videoBitrate: Double?

    /// Pixel format ("yuv420p", "yuv420p10le"). Diagnostic — not
    /// shown in the v1.6.18 overlay layout but parsed for parity
    /// with Dispatcharr's web UI table.
    let pixelFormat: String?

    let audioCodec: String?
    /// "stereo", "mono", "5.1" — string, not numeric channel count.
    let audioChannels: String?
    /// Audio bitrate in **kbps**.
    let audioBitrate: Double?
    /// Audio sample rate in Hz (e.g. 48000).
    let sampleRate: Int?

    /// Container / transport ("mpegts", "hls", etc).
    let streamType: String?

    /// Output bitrate after Dispatcharr's ffmpeg processing, in
    /// **kbps**. This is the closest to the screenshot's "current
    /// Mbps" value when a stream is being actively transcoded.
    let ffmpegOutputBitrate: Double?

    enum CodingKeys: String, CodingKey {
        case resolution, width, height
        case sourceFps        = "source_fps"
        case videoCodec       = "video_codec"
        case videoBitrate     = "video_bitrate"
        case pixelFormat      = "pixel_format"
        case audioCodec       = "audio_codec"
        case audioChannels    = "audio_channels"
        case audioBitrate     = "audio_bitrate"
        case sampleRate       = "sample_rate"
        case streamType       = "stream_type"
        case ffmpegOutputBitrate = "ffmpeg_output_bitrate"
    }
}

/// Slim Stream record returned by `/api/channels/streams/{id}/`,
/// containing the fields Aerio uses for the Stream Info overlay.
/// The full Stream model has many more fields (logo_url, m3u_account,
/// channel_group, …) that Aerio doesn't need at the per-playback
/// stats level — keeping the decoder lean reduces the JSON parse
/// cost on every poll.
struct DispatcharrStreamDetail: Decodable {
    let id: Int
    let name: String?
    let streamStats: DispatcharrStreamStats?
    /// ISO-8601 timestamp of the most recent stats update. Used to
    /// detect stale stats on cold-fetch (no recent playback) so the
    /// UI can fall back to mpv-derived values gracefully.
    let streamStatsUpdatedAt: String?
    /// Active viewer count (number of clients currently consuming
    /// the proxied stream). Surfaced as the "viewers" badge in the
    /// overlay.
    let currentViewers: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case streamStats = "stream_stats"
        case streamStatsUpdatedAt = "stream_stats_updated_at"
        case currentViewers = "current_viewers"
    }
}
