import Foundation

// MARK: - Server Snapshot
// Thread-safe value-type snapshot of ServerConnection properties.
// SwiftData models must only be accessed on the main actor; this struct
// captures everything needed so network calls can run freely on background
// threads without touching the model.

struct ServerSnapshot: Sendable {
    let id: UUID
    let type: ServerType
    let baseURL: String
    let username: String
    let password: String
    let apiKey: String
}

extension ServerConnection {
    /// Snapshot server properties on the MainActor for safe cross-isolation use.
    @MainActor var snapshot: ServerSnapshot {
        ServerSnapshot(
            id: id,
            type: type,
            baseURL: effectiveBaseURL,
            username: username,
            password: effectivePassword,
            apiKey: effectiveApiKey
        )
    }
}

// MARK: - VOD Service
// Unified interface to fetch VOD content from XC or Dispatcharr sources.

final class VODService {

    private static func resolveURL(_ raw: String, base: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let separator = raw.hasPrefix("/") ? "" : "/"
        return URL(string: base + separator + raw)
    }

    // MARK: - Movies

    static func fetchMovies(from server: ServerSnapshot) async throws -> ([VODMovie], [VODCategory]) {
        switch server.type {
        case .xtreamCodes:    return try await xcMovies(server: server)
        case .dispatcharrAPI: return try await dispatcharrMovies(server: server)
        case .m3uPlaylist:    return ([], [])
        }
    }

    // MARK: - Series

    static func fetchSeries(from server: ServerSnapshot) async throws -> ([VODSeries], [VODCategory]) {
        switch server.type {
        case .xtreamCodes:    return try await xcSeries(server: server)
        case .dispatcharrAPI: return try await dispatcharrSeries(server: server)
        case .m3uPlaylist:    return ([], [])
        }
    }

    static func fetchSeriesDetail(seriesID: String, from server: ServerSnapshot) async throws -> VODSeries? {
        switch server.type {
        case .xtreamCodes:    return try await xcSeriesDetail(seriesID: seriesID, server: server)
        case .dispatcharrAPI: return try await dispatcharrSeriesDetail(seriesID: seriesID, server: server)
        case .m3uPlaylist:    return nil
        }
    }

    // MARK: - Xtream Codes — Movies

    private static func xcMovies(server: ServerSnapshot) async throws -> ([VODMovie], [VODCategory]) {
        let api = XtreamCodesAPI(baseURL: server.baseURL,
                                  username: server.username, password: server.password)
        async let catsTask = api.getVODCategories()
        async let streamsTask = api.getVODStreams()

        let rawCats = (try? await catsTask) ?? []
        let streams = try await streamsTask

        let catMap = Dictionary(uniqueKeysWithValues: rawCats.map { ($0.id, $0.name) })
        var vodCats = rawCats.map { VODCategory(id: $0.id, name: $0.name) }

        let movies: [VODMovie] = streams.map { item in
            let catName = catMap[item.categoryID ?? ""] ?? "Uncategorized"
            let ext = item.containerExtension.isEmpty ? "mp4" : item.containerExtension
            let streamURL = URL(string: "\(server.baseURL)/movie/\(server.username)/\(server.password)/\(item.streamID).\(ext)")
            if let idx = vodCats.firstIndex(where: { $0.id == (item.categoryID ?? "") }) {
                vodCats[idx].itemCount += 1
            }
            return VODMovie(
                id: String(item.streamID), name: item.name,
                posterURL: item.streamIcon.flatMap { URL(string: $0) }, backdropURL: nil,
                rating: item.rating ?? "", plot: item.plot ?? "",
                genre: item.genre ?? "", releaseDate: item.releaseDate ?? "",
                duration: "", cast: item.cast ?? "", director: item.director ?? "", imdbID: "",
                categoryID: item.categoryID ?? "", categoryName: catName,
                streamURL: streamURL, containerExtension: ext, serverID: server.id
            )
        }
        return (movies, vodCats)
    }

    // MARK: - Xtream Codes — Series

    private static func xcSeries(server: ServerSnapshot) async throws -> ([VODSeries], [VODCategory]) {
        let api = XtreamCodesAPI(baseURL: server.baseURL,
                                  username: server.username, password: server.password)
        async let catsTask = api.getSeriesCategories()
        async let seriesTask = api.getSeries()

        let rawCats = (try? await catsTask) ?? []
        let rawSeries = try await seriesTask

        let catMap = Dictionary(uniqueKeysWithValues: rawCats.map { ($0.id, $0.name) })
        var vodCats = rawCats.map { VODCategory(id: $0.id, name: $0.name) }

        let series: [VODSeries] = rawSeries.map { item in
            let catName = catMap[item.categoryID ?? ""] ?? "Uncategorized"
            if let idx = vodCats.firstIndex(where: { $0.id == (item.categoryID ?? "") }) {
                vodCats[idx].itemCount += 1
            }
            return VODSeries(
                id: String(item.seriesID), name: item.name,
                posterURL: item.cover.flatMap { URL(string: $0) }, backdropURL: nil,
                rating: item.rating ?? "", plot: item.plot ?? "",
                genre: item.genre ?? "", releaseDate: item.releaseDate ?? "",
                cast: item.cast ?? "", director: item.director ?? "",
                categoryID: item.categoryID ?? "", categoryName: catName,
                serverID: server.id, seasons: [], episodeCount: 0
            )
        }
        return (series, vodCats)
    }

    private static func xcSeriesDetail(seriesID: String, server: ServerSnapshot) async throws -> VODSeries? {
        let api = XtreamCodesAPI(baseURL: server.baseURL,
                                  username: server.username, password: server.password)
        let detail = try await api.getSeriesInfo(seriesID: seriesID)

        var seasonMap: [Int: [VODEpisode]] = [:]
        for (seasonNumStr, episodes) in (detail.episodes ?? [:]) {
            let seasonNum = Int(seasonNumStr) ?? 0
            for ep in episodes {
                let ext = ep.containerExtension ?? "mp4"
                let urlStr = "\(server.baseURL)/series/\(server.username)/\(server.password)/\(ep.id).\(ext)"
                let vodEp = VODEpisode(
                    id: String(ep.id), seriesID: seriesID,
                    title: ep.title ?? "Episode \(ep.episodeNum ?? 0)",
                    seasonNumber: seasonNum, episodeNumber: ep.episodeNum ?? 0,
                    plot: ep.info?.plot ?? "", duration: ep.info?.duration ?? "",
                    posterURL: ep.info?.movieImage.flatMap { URL(string: $0) },
                    streamURL: URL(string: urlStr),
                    containerExtension: ext, serverID: server.id
                )
                seasonMap[seasonNum, default: []].append(vodEp)
            }
        }

        let seasons: [VODSeason] = seasonMap.map { (num, eps) in
            VODSeason(id: "\(seriesID)-s\(num)", seasonNumber: num,
                      episodes: eps.sorted { $0.episodeNumber < $1.episodeNumber })
        }.sorted { $0.seasonNumber < $1.seasonNumber }

        let info = detail.info
        return VODSeries(
            id: seriesID, name: info?.name ?? "Unknown",
            posterURL: info?.cover.flatMap { URL(string: $0) }, backdropURL: nil,
            rating: info?.rating ?? "", plot: info?.plot ?? "",
            genre: info?.genre ?? "", releaseDate: info?.firstAirDate ?? "",
            cast: info?.cast ?? "", director: info?.director ?? "",
            categoryID: info?.categoryID ?? "", categoryName: "",
            serverID: server.id, seasons: seasons,
            episodeCount: seasons.flatMap(\.episodes).count
        )
    }

    // MARK: - Dispatcharr — Movies

    private static func dispatcharrMovies(server: ServerSnapshot) async throws -> ([VODMovie], [VODCategory]) {
        let api = DispatcharrAPI(baseURL: server.baseURL, auth: .apiKey(server.apiKey))
        let raw = try await api.getVODMovies()
        let base = server.baseURL

        var genreCounts: [String: Int] = [:]
        let movies: [VODMovie] = raw.map { m in
            let streamURL = URL(string: "\(base)/proxy/vod/movie/\(m.uuid)/")
            let genre = m.genre ?? ""
            let catName = genre.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let primaryCat = catName.isEmpty ? "Uncategorized" : catName
            // Count all genres for category list
            let allGenres = genre.isEmpty ? ["Uncategorized"] : genre.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for g in allGenres { genreCounts[g, default: 0] += 1 }
            return VODMovie(
                id: String(m.id), name: m.title,
                posterURL: m.posterURL.flatMap { resolveURL($0, base: base) }, backdropURL: nil,
                rating: m.rating ?? "", plot: m.plot ?? "",
                genre: genre, releaseDate: "", duration: "",
                cast: "", director: "", imdbID: "",
                categoryID: primaryCat, categoryName: primaryCat,
                streamURL: streamURL, containerExtension: "mp4", serverID: server.id
            )
        }
        let cats = genreCounts.sorted { $0.key < $1.key }.map { VODCategory(id: $0.key, name: $0.key, itemCount: $0.value) }
        return (movies, cats.isEmpty ? [VODCategory(id: "movies", name: "Movies", itemCount: raw.count)] : cats)
    }

    // MARK: - Dispatcharr — Series

    private static func dispatcharrSeries(server: ServerSnapshot) async throws -> ([VODSeries], [VODCategory]) {
        let api = DispatcharrAPI(baseURL: server.baseURL, auth: .apiKey(server.apiKey))
        let raw = try await api.getVODSeries()
        let base = server.baseURL

        var genreCounts: [String: Int] = [:]
        let series: [VODSeries] = raw.map { s in
            let genre = s.genre ?? ""
            let catName = genre.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let primaryCat = catName.isEmpty ? "Uncategorized" : catName
            let allGenres = genre.isEmpty ? ["Uncategorized"] : genre.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for g in allGenres { genreCounts[g, default: 0] += 1 }
            return VODSeries(
                id: String(s.id), name: s.name,
                posterURL: s.posterURL.flatMap { resolveURL($0, base: base) }, backdropURL: nil,
                rating: s.rating ?? "", plot: s.plot ?? "",
                genre: genre, releaseDate: "",
                cast: "", director: "",
                categoryID: primaryCat, categoryName: primaryCat,
                serverID: server.id, seasons: [], episodeCount: 0
            )
        }
        let cats = genreCounts.sorted { $0.key < $1.key }.map { VODCategory(id: $0.key, name: $0.key, itemCount: $0.value) }
        return (series, cats.isEmpty ? [VODCategory(id: "shows", name: "TV Shows", itemCount: raw.count)] : cats)
    }

    private static func dispatcharrSeriesDetail(seriesID: String, server: ServerSnapshot) async throws -> VODSeries? {
        let api = DispatcharrAPI(baseURL: server.baseURL, auth: .apiKey(server.apiKey))
        guard let sid = Int(seriesID) else { return nil }
        let episodes = try await api.getVODSeriesEpisodes(seriesID: sid)

        var seasonMap: [Int: [VODEpisode]] = [:]
        for ep in episodes {
            let season = ep.seasonNumber ?? 1
            let vodEp = VODEpisode(
                id: String(ep.id), seriesID: seriesID,
                title: ep.title,
                seasonNumber: season, episodeNumber: ep.episodeNumber ?? 0,
                plot: ep.plot ?? "", duration: "", posterURL: nil,
                streamURL: api.proxyEpisodeURL(uuid: ep.uuid,
                                                  preferredStreamID: ep.streams?.first?.streamID),
                containerExtension: "mp4", serverID: server.id
            )
            seasonMap[season, default: []].append(vodEp)
        }

        let seasons: [VODSeason] = seasonMap.map { (num, eps) in
            VODSeason(id: "\(seriesID)-s\(num)", seasonNumber: num,
                      episodes: eps.sorted { $0.episodeNumber < $1.episodeNumber })
        }.sorted { $0.seasonNumber < $1.seasonNumber }

        return VODSeries(
            id: seriesID, name: "",
            posterURL: nil, backdropURL: nil,
            rating: "", plot: "", genre: "", releaseDate: "",
            cast: "", director: "", categoryID: "", categoryName: "",
            serverID: server.id, seasons: seasons,
            episodeCount: episodes.count
        )
    }
}
