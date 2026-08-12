import Foundation

// MARK: - Xtream Codes Series Detail Extension
// Adds getSeriesInfo() and associated response models.

private enum XtreamSeriesInfoSession {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
}

extension XtreamCodesAPI {
    /// Fetch full series detail including seasons and episodes.
    func getSeriesInfo(seriesID: String) async throws -> XtreamSeriesDetail {
        guard var components = URLComponents(string: baseURL + "/player_api.php") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "action", value: "get_series_info"),
            URLQueryItem(name: "series_id", value: seriesID)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await HTTPRouter.data(from: url, using: XtreamSeriesInfoSession.session)

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401: throw APIError.unauthorized
        case 403:
            // Same split as the main XC validator: `.unauthorized` renders
            // Dispatcharr Admin-API-Key advice, which is nonsense on a plain
            // Xtream panel — a 403 here is typically the provider's edge
            // (rate limit, bot protection, IP ban) and the plain-text body
            // says so. Surface the server's own words instead.
            var reason: String? = nil
            if !data.isEmpty,
               let body = String(data: data.prefix(200), encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty, !body.hasPrefix("<") {
                reason = String(body.prefix(160))
            }
            throw APIError.forbidden(reason)
        default: throw APIError.serverError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(XtreamSeriesDetail.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}

// MARK: - Series Detail Response Models

struct XtreamSeriesDetail: Decodable {
    let info: XtreamSeriesInfo?
    let episodes: [String: [XtreamEpisode]]?
}

struct XtreamSeriesInfo: Decodable {
    let name: String?
    let cover: String?
    let plot: String?
    let cast: String?
    let director: String?
    let genre: String?
    let rating: String?
    let firstAirDate: String?
    let categoryID: String?

    enum CodingKeys: String, CodingKey {
        case name, cover, plot, cast, director, genre, rating
        case firstAirDate = "first_air_date"
        case categoryID = "category_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name         = try? c.decode(String.self, forKey: .name)
        cover        = try? c.decode(String.self, forKey: .cover)
        plot         = try? c.decode(String.self, forKey: .plot)
        // v0.26.0: cast/director may arrive as arrays (joined). A plain
        // synthesized decode would throw on the array shape and fail the
        // whole series-info decode, so handle both explicitly.
        cast         = c.decodeFlexibleString(forKey: .cast)
        director     = c.decodeFlexibleString(forKey: .director)
        genre        = try? c.decode(String.self, forKey: .genre)
        rating       = try? c.decode(String.self, forKey: .rating)
        firstAirDate = try? c.decode(String.self, forKey: .firstAirDate)
        categoryID   = try? c.decode(String.self, forKey: .categoryID)
    }
}

struct XtreamEpisode: Decodable {
    let id: Int
    let episodeNum: Int?
    let title: String?
    let containerExtension: String?
    let info: XtreamEpisodeInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case episodeNum = "episode_num"
        case title
        case containerExtension = "container_extension"
        case info
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
        episodeNum = try? c.decode(Int.self, forKey: .episodeNum)
        title = try? c.decode(String.self, forKey: .title)
        containerExtension = try? c.decode(String.self, forKey: .containerExtension)
        info = try? c.decode(XtreamEpisodeInfo.self, forKey: .info)
    }
}

struct XtreamEpisodeInfo: Decodable {
    let movieImage: String?
    let plot: String?
    let duration: String?

    enum CodingKeys: String, CodingKey {
        case movieImage = "movie_image"
        case plot, duration
    }
}
