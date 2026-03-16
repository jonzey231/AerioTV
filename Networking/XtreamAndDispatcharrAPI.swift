import Foundation

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
        case .unauthorized:         return "Invalid credentials"
        case .serverError(let c):   return "Server error (\(c))"
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

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    // MARK: - Account Info / Verify
    func verifyConnection() async throws -> XtreamAccountInfo {
        let url = try buildURL(path: "/player_api.php", params: ["action": ""])
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try decode(XtreamAccountInfo.self, from: data)
    }

    // MARK: - Live TV Categories
    func getLiveCategories() async throws -> [XtreamCategory] {
        let url = try buildURL(path: "/player_api.php", params: ["action": "get_live_categories"])
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try decode([XtreamCategory].self, from: data)
    }

    // MARK: - Live Streams
    func getLiveStreams(categoryID: String? = nil) async throws -> [XtreamStream] {
        var params: [String: String] = ["action": "get_live_streams"]
        if let id = categoryID { params["category_id"] = id }
        let url = try buildURL(path: "/player_api.php", params: params)
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try decode([XtreamStream].self, from: data)
    }

    // MARK: - VOD Categories
    func getVODCategories() async throws -> [XtreamCategory] {
        let url = try buildURL(path: "/player_api.php", params: ["action": "get_vod_categories"])
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try decode([XtreamCategory].self, from: data)
    }

    // MARK: - VOD Streams
    func getVODStreams(categoryID: String? = nil) async throws -> [XtreamVODItem] {
        var params: [String: String] = ["action": "get_vod_streams"]
        if let id = categoryID { params["category_id"] = id }
        let url = try buildURL(path: "/player_api.php", params: params)
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try decode([XtreamVODItem].self, from: data)
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
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try decode([XtreamCategory].self, from: data)
    }

    // MARK: - Series
    func getSeries(categoryID: String? = nil) async throws -> [XtreamSeriesItem] {
        var params: [String: String] = ["action": "get_series"]
        if let id = categoryID { params["category_id"] = id }
        let url = try buildURL(path: "/player_api.php", params: params)
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try decode([XtreamSeriesItem].self, from: data)
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
        let (data, response) = try await session.data(from: url)
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
        let (data, response) = try await session.data(from: url)
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
    /// Order: .ts first (standard Xtream default), then .m3u8 (HLS variant).
    /// Note: requires Dispatcharr stream profile set to "Redirect" to work correctly.
    func streamURLs(for stream: XtreamStream) -> [URL] {
        var urls: [URL] = []
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        // MPEG-TS — Xtream standard, most panels support this
        if let url = URL(string: "\(base)/live/\(username)/\(password)/\(stream.streamID).ts") {
            urls.append(url)
        }
        // HLS variant — some panels serve this format
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
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw APIError.unauthorized
        default: throw APIError.serverError(http.statusCode)
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
        streamID = try c.decode(Int.self, forKey: .streamID)
        name = try c.decode(String.self, forKey: .name)
        streamIcon = try? c.decode(String.self, forKey: .streamIcon)
        epgChannelID = try? c.decode(String.self, forKey: .epgChannelID)
        added = try? c.decode(String.self, forKey: .added)
        categoryID = try? c.decode(String.self, forKey: .categoryID)
        num = try? c.decode(Int.self, forKey: .num)
        allowedOutputFormats = try? c.decode([String].self, forKey: .allowedOutputFormats)
        directSource = try? c.decode(String.self, forKey: .directSource)
        id = num ?? streamID
    }


    /// Best format for iOS: m3u8 (HLS) preferred, ts as fallback.
    var bestFormat: String {
        let formats = allowedOutputFormats ?? []
        if formats.contains("m3u8") { return "m3u8" }
        if formats.contains("hls")  { return "m3u8" }
        // If only ts or unknown, still try m3u8 — Dispatcharr/most panels support it
        return "m3u8"
    }
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
        streamID = try c.decode(Int.self, forKey: .streamID)
        name = try c.decode(String.self, forKey: .name)
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
        seriesID = try c.decode(Int.self, forKey: .seriesID)
        name = try c.decode(String.self, forKey: .name)
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

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }

    private var headers: [String: String] {
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]
        switch auth {
        case .bearer(let token):
            h["Authorization"] = "Bearer \(token)"
        case .apiKey(let key):
            // Dispatcharr supports either header style; sending both improves compatibility.
            h["Authorization"] = "ApiKey \(key)"
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
            "/api/channels/channels/",   // real protected channels list
            "/api/channels/groups/",     // real groups list
            "/api/channels/summary/",    // lightweight summary
            "/api/channels/",            // index document (links) — allow as last resort
            "/api/version/",
            "/api/version"
        ]

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

            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse {
                lastStatus = http.statusCode
                lastContentType = http.value(forHTTPHeaderField: "Content-Type")
            }

            // If it's not a 2xx, capture body snippet and try next.
            if (lastStatus ?? 0) < 200 || (lastStatus ?? 0) >= 300 {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                lastBodySnippet = String(body.prefix(800))
                continue
            }

            // If it's HTML, it's almost certainly the web UI shell, not the API.
            if let ct = lastContentType?.lowercased(), ct.contains("text/html") {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                lastBodySnippet = String(body.prefix(800))
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
                    _ = try decode([DispatcharrChannel].self, from: data)
                    return DispatcharrServerInfo(version: nil, serverName: "Dispatcharr")
                } else if path.contains("channels/groups") {
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
                continue
            }
        }

        let urlString = lastURL?.absoluteString ?? "<unknown url>"
        let ctString = lastContentType ?? "<unknown content-type>"
        let statusString = lastStatus.map(String.init) ?? "<unknown status>"

        throw APIError.decodingError(NSError(
            domain: "DispatcharrAPI",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey:
                "Unrecognized API response while verifying connection. URL: \(urlString) Status: \(statusString) Content-Type: \(ctString). Body: \(lastBodySnippet)"
            ]
        ))
    }

    // MARK: - Pagination helper
    private func fetchAllPages<T: Decodable>(_ type: T.Type, firstPath: String) async throws -> [T] {
        var allItems: [T] = []
        var nextURL: URL? = try buildURL(path: firstPath)
        while let url = nextURL {
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await session.data(for: request)
            try validate(response: response)
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
        // Do NOT use ?no_pagination=true: some Dispatcharr builds return a capped flat array
        // for that param, causing fetchAllPages to break early. Rely on the next-link loop instead.
        try await fetchAllPages(DispatcharrChannel.self, firstPath: "/api/channels/channels/")
    }

    // MARK: - Lightweight channel summary (fast guide UI)
    func getChannelSummaries() async throws -> [DispatcharrChannelSummary] {
        try await fetchAllPages(DispatcharrChannelSummary.self, firstPath: "/api/channels/summary/")
    }

    // MARK: - EPG current programs (batch)
    func getCurrentPrograms(channelIDs: [Int]? = nil) async throws -> [DispatcharrCurrentProgram] {
        // This endpoint only accepts POST — GET returns 405.
        let url = try buildURL(path: "/api/epg/current-programs/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let ids = channelIDs {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_ids": ids])
        } else {
            // Empty body = fetch current program for all channels.
            request.httpBody = try JSONSerialization.data(withJSONObject: [:])
        }
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        if let list = try? JSONDecoder().decode([DispatcharrCurrentProgram].self, from: data) {
            return list
        }
        let wrapped = try decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: data)
        return wrapped.results
    }

    // MARK: - Upcoming programs (next N programs after the current one)
    func getUpcomingPrograms(tvgIDs: [String]? = nil, limit: Int = 3) async throws -> [DispatcharrCurrentProgram] {
        let url = try buildURL(path: "/api/epg/upcoming-programs/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        var body: [String: Any] = ["limit": limit]
        if let ids = tvgIDs { body["tvg_ids"] = ids }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        if let list = try? JSONDecoder().decode([DispatcharrCurrentProgram].self, from: data) {
            return list
        }
        let wrapped = try decode(DispatcharrResultsWrapper<DispatcharrCurrentProgram>.self, from: data)
        return wrapped.results
    }

    // MARK: - VOD
    func getVODMovies() async throws -> [DispatcharrVODMovie] {
        try await fetchAllPages(DispatcharrVODMovie.self, firstPath: "/api/vod/movies/?no_pagination=true")
    }

    func getVODSeries() async throws -> [DispatcharrVODSeries] {
        try await fetchAllPages(DispatcharrVODSeries.self, firstPath: "/api/vod/series/?no_pagination=true")
    }

    func getVODSeriesEpisodes(seriesID: Int) async throws -> [DispatcharrVODEpisode] {
        try await fetchAllPages(DispatcharrVODEpisode.self, firstPath: "/api/vod/series/\(seriesID)/episodes/?no_pagination=true")
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
    /// Order: channel container first (preserves failover), then stream UUID fallback if present.
    func liveProxyURLAttempts(for channel: DispatcharrChannel) -> [URL] {
        var out: [URL] = []
        if let uuid = channel.uuid, !uuid.isEmpty, let u = proxyTSChannelURL(channelUUID: uuid) {
            out.append(u)
        }
        // Some servers expose a per-stream UUID in M3U (preferred for some clients), but the REST channel payload
        // does not always include it. If `uuid` is actually a stream uuid in your backend, the channel URL above
        // will still 404 and the fallback below can be used by passing that uuid as `channel.uuid`.
        if let uuid = channel.uuid, !uuid.isEmpty, let u = proxyTSStreamURL(uuid: uuid) {
            // Avoid duplicate if both builders produce the same URL.
            if out.first?.absoluteString != u.absoluteString {
                out.append(u)
            }
        }
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
        let url = try buildURL(path: "/api/channels/groups/")
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try decode([DispatcharrChannelGroup].self, from: data)
    }

    // MARK: - M3U Export URL
    func m3uURL(userID: Int? = nil) -> URL? {
        var path = "/output/m3u"
        if let id = userID { path += "?user_id=\(id)" }
        return URL(string: baseURL + path)
    }

    // MARK: - Helpers
    private func buildURL(path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        return url
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw APIError.unauthorized
        default: throw APIError.serverError(http.statusCode)
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

struct DispatcharrChannelSummary: Decodable, Identifiable {
    let id: Int
    let name: String
    let logoURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case logoURL = "logo_url"
    }
}

/// Current program for a channel as returned by `/api/epg/current-programs/`.
/// Schema: ProgramData — fields are tvg_id, title, start_time, end_time.
struct DispatcharrCurrentProgram: Decodable, Identifiable {
    var id: String { "\(tvgID ?? "?")-\(title)" }

    let tvgID: String?
    let title: String
    let startTime: DispatcharrDateValue?
    let endTime: DispatcharrDateValue?

    enum CodingKeys: String, CodingKey {
        case tvgID = "tvg_id"
        case title
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tvgID = try? c.decode(String.self, forKey: .tvgID)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        startTime = try? c.decode(DispatcharrDateValue.self, forKey: .startTime)
        endTime = try? c.decode(DispatcharrDateValue.self, forKey: .endTime)
    }
}

enum DispatcharrDateValue: Decodable {
    case iso(String)
    case unix(Double)

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
            let f = ISO8601DateFormatter()
            if let d = f.date(from: s) { return d }
            // Fall back to common Django formats
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
            if let d = df.date(from: s) { return d }
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            return df.date(from: s)
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
        case channelGroupID = "channel_group_id"
        case uuid
        case logoID = "logo_id"
        case streams
        case tvgID = "tvg_id"
        case epgDataID = "epg_data_id"
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

struct DispatcharrVODMovie: Decodable, Identifiable {
    let id: Int
    let uuid: String
    let title: String
    let posterURL: String?
    let plot: String?
    let genre: String?
    let rating: String?
    let streams: [DispatcharrVODStreamOption]?

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case title
        case name
        case posterURL = "poster_url"
        case poster
        case cover
        case plot
        case overview
        case genre
        case rating
        case streams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? ""
        // title can appear under different names
        title = (try? c.decode(String.self, forKey: .title)) ?? (try? c.decode(String.self, forKey: .name)) ?? ""
        posterURL = (try? c.decode(String.self, forKey: .posterURL))
            ?? (try? c.decode(String.self, forKey: .poster))
            ?? (try? c.decode(String.self, forKey: .cover))
        plot = (try? c.decode(String.self, forKey: .plot)) ?? (try? c.decode(String.self, forKey: .overview))
        genre = try? c.decode(String.self, forKey: .genre)
        rating = try? c.decode(String.self, forKey: .rating)
        streams = try? c.decode([DispatcharrVODStreamOption].self, forKey: .streams)
    }
}

struct DispatcharrVODSeries: Decodable, Identifiable {
    let id: Int
    let uuid: String
    let name: String
    let posterURL: String?
    let plot: String?
    let genre: String?
    let rating: String?

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case name
        case title
        case posterURL = "poster_url"
        case poster
        case cover
        case plot
        case overview
        case genre
        case rating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? (try? c.decode(String.self, forKey: .title)) ?? ""
        posterURL = (try? c.decode(String.self, forKey: .posterURL))
            ?? (try? c.decode(String.self, forKey: .poster))
            ?? (try? c.decode(String.self, forKey: .cover))
        plot = (try? c.decode(String.self, forKey: .plot)) ?? (try? c.decode(String.self, forKey: .overview))
        genre = try? c.decode(String.self, forKey: .genre)
        rating = try? c.decode(String.self, forKey: .rating)
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

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case title
        case name
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case plot
        case overview
        case streams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        uuid = (try? c.decode(String.self, forKey: .uuid)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? (try? c.decode(String.self, forKey: .name)) ?? ""
        seasonNumber = try? c.decode(Int.self, forKey: .seasonNumber)
        episodeNumber = try? c.decode(Int.self, forKey: .episodeNumber)
        plot = (try? c.decode(String.self, forKey: .plot)) ?? (try? c.decode(String.self, forKey: .overview))
        streams = try? c.decode([DispatcharrVODStreamOption].self, forKey: .streams)
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
