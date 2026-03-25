import Foundation

// MARK: - Emby API
struct EmbyAPI {
    let baseURL: String
    let apiKey: String
    let userID: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.session }

    private var authHeader: String {
        "MediaBrowser Client=\"Aerio\", Device=\"iPhone\", DeviceId=\"aerio-ios\", Version=\"1.0\", Token=\"\(apiKey)\""
    }

    // MARK: - Verify / System Info
    func verifyConnection() async throws -> MediaServerInfo {
        let url = try buildURL(path: "/System/Info/Public")
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let info = try decode(EmbySystemInfo.self, from: data)
        return MediaServerInfo(serverName: info.serverName, version: info.version)
    }

    // MARK: - Fetch first admin user ID
    func fetchFirstUserID() async throws -> String {
        let url = try buildURL(path: "/Users", params: ["api_key": apiKey])
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let users = try decode([EmbyUser].self, from: data)
        guard let first = users.first else { throw APIError.unauthorized }
        return first.id
    }

    // MARK: - Live TV Channels (no userID required)
    func getLiveTVChannels() async throws -> [MediaChannel] {
        // Resolve user ID: use stored one or fetch first available
        let uid: String
        if let stored = userID {
            uid = stored
        } else {
            uid = try await fetchFirstUserID()
        }
        let params: [String: String] = [
            "UserId": uid,
            "Limit": "500",
            "api_key": apiKey
        ]
        let url = try buildURL(path: "/LiveTv/Channels", params: params)
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let result = try decode(EmbyChannelResult.self, from: data)
        return result.items.map { MediaChannel(from: $0, baseURL: baseURL, apiKey: apiKey) }
    }

    // MARK: - Library Items (Movies/TV/etc)
    func getLibraryItems(type: String = "Movie,Series") async throws -> [MediaChannel] {
        let uid: String
        if let stored = userID {
            uid = stored
        } else {
            uid = try await fetchFirstUserID()
        }
        let url = try buildURL(path: "/Users/\(uid)/Items", params: [
            "IncludeItemTypes": type,
            "Recursive": "true",
            "Limit": "200",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Fields": "Overview",
            "api_key": apiKey
        ])
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let result = try decode(EmbyChannelResult.self, from: data)
        return result.items.map { MediaChannel(from: $0, baseURL: baseURL, apiKey: apiKey) }
    }

    // MARK: - Helpers
    private func buildURL(path: String, params: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
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
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.decodingError(error) }
    }
}

// MARK: - Jellyfin API
struct JellyfinAPI {
    let baseURL: String
    let apiKey: String
    let userID: String?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.session }

    private var authHeader: String {
        "MediaBrowser Client=\"Aerio\", Device=\"iPhone\", DeviceId=\"aerio-ios\", Version=\"1.0\", Token=\"\(apiKey)\""
    }

    func verifyConnection() async throws -> MediaServerInfo {
        let url = try buildURL(path: "/System/Info/Public")
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let info = try decode(EmbySystemInfo.self, from: data)
        return MediaServerInfo(serverName: info.serverName, version: info.version)
    }

    func getLiveTVChannels() async throws -> [MediaChannel] {
        guard let uid = userID else { throw APIError.unauthorized }
        let url = try buildURL(path: "/LiveTv/Channels", params: ["UserId": uid, "Limit": "500"])
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let result = try decode(EmbyChannelResult.self, from: data)
        return result.items.map { MediaChannel(from: $0, baseURL: baseURL, apiKey: apiKey) }
    }
    
    // MARK: - Library Items (Movies/TV/etc)
    func getLibraryItems(type: String = "Movie,Series") async throws -> [MediaChannel] {
        guard let uid = userID else { throw APIError.unauthorized }
        let url = try buildURL(path: "/Users/\(uid)/Items", params: [
            "IncludeItemTypes": type,
            "Recursive": "true",
            "Limit": "200",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Fields": "Overview"
        ])
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let result = try decode(EmbyChannelResult.self, from: data)
        return result.items.map { MediaChannel(from: $0, baseURL: baseURL, apiKey: apiKey) }
    }

    private func buildURL(path: String, params: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
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
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.decodingError(error) }
    }
}

// MARK: - Plex API
struct PlexAPI {
    let baseURL: String
    let plexToken: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.session }

    func verifyConnection() async throws -> MediaServerInfo {
        let url = try buildURL(path: "/")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let result = try decode(PlexServerResponse.self, from: data)
        return MediaServerInfo(
            serverName: result.mediaContainer.friendlyName,
            version: result.mediaContainer.version
        )
    }

    func getLiveTVChannels() async throws -> [MediaChannel] {
        let url = try buildURL(path: "/livetv/hubs/discover", params: ["includeStations": "1"])
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        // Plex live TV hub parsing — returns DVR channels
        let result = try decode(PlexLiveTVResponse.self, from: data)
        return result.mediaContainer.hub?
            .flatMap { $0.metadata ?? [] }
            .map { MediaChannel(from: $0, baseURL: baseURL, token: plexToken) } ?? []
    }

    private func buildURL(path: String, params: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        var queryItems = [URLQueryItem(name: "X-Plex-Token", value: plexToken)]
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
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.decodingError(error) }
    }
}

// MARK: - Shared Response Models

struct MediaServerInfo {
    let serverName: String
    let version: String
}

struct MediaChannel: Identifiable {
    let id: String
    let name: String
    let channelNumber: String
    let logoURL: URL?
    let streamURL: URL?

    // From Emby/Jellyfin item
    init(from item: EmbyChannelItem, baseURL: String, apiKey: String) {
        self.id = item.id
        self.name = item.name
        self.channelNumber = item.channelNumber.map { String($0) } ?? ""
        self.logoURL = item.imageTags?.primary != nil
            ? URL(string: "\(baseURL)/Items/\(item.id)/Images/Primary?api_key=\(apiKey)")
            : nil
        self.streamURL = URL(string: "\(baseURL)/LiveTv/stream/\(item.id)?api_key=\(apiKey)")
    }

    // From Plex metadata
    init(from metadata: PlexMetadata, baseURL: String, token: String) {
        self.id = metadata.ratingKey ?? UUID().uuidString
        self.name = metadata.title ?? "Unknown"
        self.channelNumber = metadata.index.map { String($0) } ?? ""
        self.logoURL = nil
        self.streamURL = nil
    }
}

// MARK: - Emby/Jellyfin Models
struct EmbySystemInfo: Decodable {
    let serverName: String
    let version: String
    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
    }
}

struct EmbyChannelResult: Decodable {
    let items: [EmbyChannelItem]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

struct EmbyChannelItem: Decodable, Identifiable {
    let id: String
    let name: String
    let channelNumber: Int?
    let imageTags: EmbyImageTags?
    let type: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case channelNumber = "ChannelNumber"
        case imageTags = "ImageTags"
        case type = "Type"
    }
}

struct EmbyImageTags: Decodable {
    let primary: String?
    enum CodingKeys: String, CodingKey { case primary = "Primary" }
}

struct EmbyUser: Decodable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

// MARK: - Plex Models
struct PlexServerResponse: Decodable {
    let mediaContainer: PlexServerContainer
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

struct PlexServerContainer: Decodable {
    let friendlyName: String
    let version: String
    enum CodingKeys: String, CodingKey {
        case friendlyName = "friendlyName"
        case version
    }
}

struct PlexLiveTVResponse: Decodable {
    let mediaContainer: PlexLiveTVContainer
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
}

struct PlexLiveTVContainer: Decodable {
    let hub: [PlexHub]?
}

struct PlexHub: Decodable {
    let metadata: [PlexMetadata]?
    enum CodingKeys: String, CodingKey { case metadata = "Metadata" }
}

struct PlexMetadata: Decodable {
    let ratingKey: String?
    let title: String?
    let index: Int?
}
