import Foundation

// MARK: - Xtream Codes Series Detail Extension
// Adds getSeriesInfo() and associated response models.

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

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        let sess = URLSession(configuration: config)
        let (data, response) = try await sess.data(from: url)

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw APIError.unauthorized
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
