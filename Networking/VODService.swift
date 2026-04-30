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
    /// v1.6.20: per-server Dispatcharr auth header shape, captured from
    /// `ServerConnection.dispatcharrHeaderMode`. Lets background-thread
    /// network code construct DispatcharrAPI clients with the auto-
    /// detected header shape instead of falling back to the default
    /// (which would 401 on Dispatcharr builds that require dual headers).
    let dispatcharrAuthMode: DispatcharrAuthHeaderMode
    /// v1.6.20: effective per-server User-Agent. Captured here so the
    /// snapshot-based DispatcharrAPI constructions surface the right
    /// device label in the admin Stats panel without round-tripping
    /// back to the model on a background thread.
    let userAgent: String
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
            apiKey: effectiveApiKey,
            dispatcharrAuthMode: dispatcharrHeaderMode,
            userAgent: effectiveUserAgent
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

    /// v1.6.12: image-aware variant of `resolveURL` that recognises
    /// raw TMDB image paths (e.g. `/9wF...PUw.jpg`) and rewrites them
    /// to the public TMDB CDN at `image.tmdb.org`. Three input shapes
    /// are accepted:
    ///
    /// - **Full URL** (`http(s)://…`) — passed through unchanged.
    /// - **Bare TMDB path** (single-segment leading slash, common
    ///   image extension) — prepended with `https://image.tmdb.org/t/p/<size>`.
    /// - **Anything else** — treated as Dispatcharr-relative and joined
    ///   with the server `base`, mirroring `resolveURL`.
    ///
    /// The TMDB CDN is anonymous and CORS-open; no API key needed for
    /// image fetches, which is why this path bypasses the auth
    /// headers Aerio uses for the Dispatcharr proxy.
    ///
    /// `size` defaults to `w1280` (TMDB's "1280-pixel-wide" preset),
    /// the right size for backdrops on iPad/Apple TV. Callers
    /// rendering smaller artwork (square posters, list rows) can pass
    /// `w500` or `w342` to save bandwidth.
    private static func resolveImageURL(_ raw: String,
                                        base: String,
                                        size: String = "w1280") -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        // TMDB heuristic: single-segment path with an image extension.
        // TMDB poster/backdrop paths are flat — `/abc.jpg`, never
        // `/some/subdir/abc.jpg`. A bare filename without leading `/`
        // is also a TMDB candidate (some serializers strip the slash).
        let leading = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        let isImageExt = leading.hasSuffix(".jpg")
            || leading.hasSuffix(".jpeg")
            || leading.hasSuffix(".png")
            || leading.hasSuffix(".webp")
        if isImageExt && !leading.contains("/") {
            return URL(string: "https://image.tmdb.org/t/p/\(size)/\(leading)")
        }
        let separator = raw.hasPrefix("/") ? "" : "/"
        return URL(string: base + separator + raw)
    }

    /// Format `duration_secs` into the "1h 45m" / "45m" string the
    /// VOD detail view expects. Returns empty when the input is nil
    /// or non-positive so the view's `if !duration.isEmpty` guard
    /// keeps the row hidden.
    private static func formatDuration(seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "" }
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if hours > 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Best-available release date string for a Dispatcharr VOD item.
    /// Tries (in order): `customProperties.releaseDate`,
    /// `customProperties.firstAirDate`, then the typed `year` column
    /// stringified. Empty when nothing usable is present — the detail
    /// view's `releaseYear` computed property handles that gracefully.
    private static func bestReleaseDate(custom: DispatcharrVODCustomProperties?,
                                        year: Int?) -> String {
        if let d = custom?.releaseDate, !d.isEmpty { return d }
        if let d = custom?.firstAirDate, !d.isEmpty { return d }
        if let y = year, y > 0 { return String(y) }
        return ""
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

    /// `existing` is the slim list-time `VODSeries` from
    /// `VODDisplayItem.series`. Dispatcharr's path uses it as the
    /// fallback for fields not in `provider-info` (or when the
    /// network call fails); Xtream / M3U ignore it. Optional with a
    /// `nil` default so legacy callers keep compiling unchanged.
    static func fetchSeriesDetail(seriesID: String,
                                   from server: ServerSnapshot,
                                   existing: VODSeries? = nil) async throws -> VODSeries? {
        switch server.type {
        case .xtreamCodes:    return try await xcSeriesDetail(seriesID: seriesID, server: server)
        case .dispatcharrAPI: return try await dispatcharrSeriesDetail(seriesID: seriesID,
                                                                       server: server,
                                                                       existing: existing)
        case .m3uPlaylist:    return nil
        }
    }

    /// v1.6.12: per-movie metadata enrichment. The list endpoint
    /// returns slim typed columns; the rich data (cast, director,
    /// backdrop, full release date, runtime) only comes from
    /// Dispatcharr's `provider-info` action, which lazily refreshes
    /// from the upstream Xtream provider on first call. Returns a
    /// new `VODMovie` with the rich fields layered on top of the
    /// existing one. Caller is expected to render `existing` first
    /// (instant) and replace it with this when the network fetch
    /// returns.
    ///
    /// Xtream is a no-op — it already populates everything from
    /// `getVODInfo`. M3U returns the existing movie unchanged.
    static func fetchMovieDetail(existing: VODMovie, from server: ServerSnapshot) async -> VODMovie {
        switch server.type {
        case .dispatcharrAPI:
            return (try? await dispatcharrMovieDetail(existing: existing, server: server)) ?? existing
        case .xtreamCodes, .m3uPlaylist:
            return existing
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
        let api = DispatcharrAPI(baseURL: server.baseURL, auth: .apiKey(server.apiKey), userAgent: server.userAgent, authMode: server.dispatcharrAuthMode)
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

            // v1.6.12: surface TMDB-derived metadata that previously
            // got dropped on the floor. `customProperties` is the
            // grab-bag keyed by Dispatcharr's `tasks.py` (cast,
            // director, backdrops, dates). The first usable backdrop
            // path (typically a TMDB CDN slug) becomes the hero
            // image; if the upstream provider only sent a poster, we
            // still get one via the existing `logo` path.
            let cp = m.customProperties
            let backdropPath = cp?.backdropPath?.first(where: { !$0.isEmpty })
            let backdropURL = backdropPath.flatMap { resolveImageURL($0, base: base) }

            var movie = VODMovie(
                id: String(m.id), name: m.title,
                posterURL: m.posterURL.flatMap { resolveURL($0, base: base) },
                backdropURL: backdropURL,
                rating: m.rating ?? "", plot: m.plot ?? "",
                genre: genre,
                releaseDate: bestReleaseDate(custom: cp, year: m.year),
                duration: formatDuration(seconds: m.durationSecs),
                cast: cp?.cast ?? "",
                director: cp?.director ?? "",
                imdbID: m.imdbID ?? "",
                categoryID: primaryCat, categoryName: primaryCat,
                streamURL: streamURL, containerExtension: "mp4", serverID: server.id
            )
            // v1.6.12: TMDB ID is a typed column at list time, so we
            // can wire the "View on TMDB" link before the user even
            // taps into the detail. `youtubeTrailer` and `country`
            // only land via /provider-info/, so list-time leaves them
            // empty (filled later in fetchMovieDetail).
            movie.tmdbID = m.tmdbID ?? ""
            movie.country = cp?.country ?? ""
            return movie
        }
        let cats = genreCounts.sorted { $0.key < $1.key }.map { VODCategory(id: $0.key, name: $0.key, itemCount: $0.value) }
        return (movies, cats.isEmpty ? [VODCategory(id: "movies", name: "Movies", itemCount: raw.count)] : cats)
    }

    // MARK: - Dispatcharr — Series

    private static func dispatcharrSeries(server: ServerSnapshot) async throws -> ([VODSeries], [VODCategory]) {
        let api = DispatcharrAPI(baseURL: server.baseURL, auth: .apiKey(server.apiKey), userAgent: server.userAgent, authMode: server.dispatcharrAuthMode)
        let raw = try await api.getVODSeries()
        let base = server.baseURL

        var genreCounts: [String: Int] = [:]
        let series: [VODSeries] = raw.map { s in
            let genre = s.genre ?? ""
            let catName = genre.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let primaryCat = catName.isEmpty ? "Uncategorized" : catName
            let allGenres = genre.isEmpty ? ["Uncategorized"] : genre.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for g in allGenres { genreCounts[g, default: 0] += 1 }

            // v1.6.12: same TMDB enrichment story as movies — pull
            // backdrop / cast / director / date from custom_properties.
            let cp = s.customProperties
            let backdropPath = cp?.backdropPath?.first(where: { !$0.isEmpty })
            let backdropURL = backdropPath.flatMap { resolveImageURL($0, base: base) }

            var show = VODSeries(
                id: String(s.id), name: s.name,
                posterURL: s.posterURL.flatMap { resolveURL($0, base: base) },
                backdropURL: backdropURL,
                rating: s.rating ?? "", plot: s.plot ?? "",
                genre: genre,
                releaseDate: bestReleaseDate(custom: cp, year: s.year),
                cast: cp?.cast ?? "",
                director: cp?.director ?? "",
                categoryID: primaryCat, categoryName: primaryCat,
                serverID: server.id, seasons: [], episodeCount: 0
            )
            // v1.6.12: surface tmdbID + country at list time so the
            // grid → detail transition can show the "View on TMDB"
            // pill instantly (before the provider-info async fetch
            // returns). `youtubeTrailer` only lands via provider-info
            // for series (typed columns don't carry it).
            show.tmdbID = s.tmdbID ?? ""
            show.country = cp?.country ?? ""
            return show
        }
        let cats = genreCounts.sorted { $0.key < $1.key }.map { VODCategory(id: $0.key, name: $0.key, itemCount: $0.value) }
        return (series, cats.isEmpty ? [VODCategory(id: "shows", name: "TV Shows", itemCount: raw.count)] : cats)
    }

    /// v1.6.12: enrich an existing `VODMovie` with data from
    /// Dispatcharr's `provider-info` action. The list endpoint
    /// (`/api/vod/movies/`) is intentionally slim — `description`,
    /// `genre`, `duration_secs`, and `custom_properties` are all
    /// frequently empty/null even when the admin UI shows full data
    /// for the same movie. The rich data lives behind a per-movie
    /// detail action that lazily refreshes from the upstream Xtream
    /// provider on first call (24h server-side throttle).
    ///
    /// Merge policy: prefer provider-info values when non-empty,
    /// otherwise keep the existing list-time values. This preserves
    /// the immediate render path: VODDetailView shows `item.movie`
    /// instantly, then upgrades when this returns. Network failure
    /// → caller falls back to `existing`, no user-visible regression.
    private static func dispatcharrMovieDetail(existing: VODMovie,
                                                server: ServerSnapshot) async throws -> VODMovie {
        guard let movieID = Int(existing.id) else { return existing }
        let api = DispatcharrAPI(baseURL: server.baseURL, auth: .apiKey(server.apiKey), userAgent: server.userAgent, authMode: server.dispatcharrAuthMode)
        let info = try await api.getMovieProviderInfo(movieID: movieID)
        let base = server.baseURL

        // Backdrop: prefer provider-info's first non-empty backdrop_path
        // entry (TMDB CDN slug), fall back to the list-time backdrop
        // (which would only be set if list-time custom_properties was
        // already populated — rarely true but possible).
        let backdropPath = info.backdropPath?.first(where: { !$0.isEmpty })
        let resolvedBackdrop = backdropPath.flatMap { resolveImageURL($0, base: base) }
        let backdropURL = resolvedBackdrop ?? existing.backdropURL

        // Plot prefers provider-info's `plot` then `description`. The
        // list endpoint's typed `description` column is often empty
        // even for enriched movies; provider-info is canonical.
        let plot: String = {
            if let p = info.plot, !p.isEmpty { return p }
            if let d = info.description, !d.isEmpty { return d }
            return existing.plot
        }()

        // Release date: provider-info `release_date` is the full
        // YYYY-MM-DD string; existing `releaseDate` may be a
        // year-only stringified Int from list-time fallback.
        let releaseDate: String = {
            if let rd = info.releaseDate, !rd.isEmpty { return rd }
            if let y = info.year, y > 0 { return String(y) }
            return existing.releaseDate
        }()

        // Genre: prefer provider-info, fall back to list-time genre
        // (which is the typed column).
        let genre: String = {
            if let g = info.genre, !g.isEmpty { return g }
            return existing.genre
        }()

        // Cast — provider-info uses `actors` (Xtream-style key).
        let cast: String = {
            if let a = info.actors, !a.isEmpty { return a }
            return existing.cast
        }()

        let director: String = {
            if let d = info.director, !d.isEmpty { return d }
            return existing.director
        }()

        let rating: String = {
            if let r = info.rating, !r.isEmpty, r != "0", r != "0.0" { return r }
            return existing.rating
        }()

        let duration = formatDuration(seconds: info.durationSecs ?? 0)
        let displayDuration = duration.isEmpty ? existing.duration : duration

        let imdbID: String = {
            if let i = info.imdbID, !i.isEmpty { return i }
            return existing.imdbID
        }()

        var enriched = VODMovie(
            id: existing.id,
            name: existing.name,
            posterURL: existing.posterURL,
            backdropURL: backdropURL,
            rating: rating,
            plot: plot,
            genre: genre,
            releaseDate: releaseDate,
            duration: displayDuration,
            cast: cast,
            director: director,
            imdbID: imdbID,
            categoryID: existing.categoryID,
            categoryName: existing.categoryName,
            streamURL: existing.streamURL,
            containerExtension: existing.containerExtension,
            serverID: existing.serverID
        )

        // v1.6.12 external-link payload. `tmdbID` and `country` may
        // already be set on `existing` from the list endpoint; prefer
        // provider-info values when non-empty since /provider-info/
        // is the canonical merge of typed columns + relation blobs.
        // `youtubeTrailer` only lands here — it's not part of the
        // list shape.
        enriched.tmdbID = {
            if let id = info.tmdbID, !id.isEmpty { return id }
            return existing.tmdbID
        }()
        enriched.youtubeTrailer = {
            if let t = info.youtubeTrailer, !t.isEmpty { return t }
            return existing.youtubeTrailer
        }()
        enriched.country = {
            if let c = info.country, !c.isEmpty { return c }
            return existing.country
        }()
        return enriched
    }

    /// v1.6.12: series detail now mirrors the movie path — fetch
    /// `/provider-info/` for rich metadata, fetch episodes, merge
    /// everything onto the list-time `existing` series so empty
    /// fields don't blow away values we already had.
    ///
    /// Pre-v1.6.12 this method returned a `VODSeries` with literally
    /// empty strings for every metadata field, on the assumption
    /// that the UI would `??`-fall-back to `item.series`. That was
    /// wrong — `VODDetailView` reads `fullSeries?.cast`, which
    /// returned the empty string (not nil), short-circuiting the
    /// `??` chain. The new approach explicitly merges the
    /// provider-info payload onto `existing`, then attaches
    /// episodes, returning a fully-populated series.
    ///
    /// `existing` is the slim list-time `VODSeries` from
    /// `VODDisplayItem.series`. `nil` is tolerated for legacy
    /// callers but produces a series with empty strings for
    /// every field provider-info doesn't supply.
    ///
    /// **Latency note:** the same first-call provider-info
    /// throttle as movies — first call against a cold series can
    /// take several seconds while Dispatcharr fetches metadata
    /// from the upstream Xtream provider, then 24h cached.
    private static func dispatcharrSeriesDetail(seriesID: String,
                                                server: ServerSnapshot,
                                                existing: VODSeries?) async throws -> VODSeries? {
        let api = DispatcharrAPI(baseURL: server.baseURL, auth: .apiKey(server.apiKey), userAgent: server.userAgent, authMode: server.dispatcharrAuthMode)
        guard let sid = Int(seriesID) else { return nil }
        let base = server.baseURL

        // v1.6.16.x: provider-info FIRST, episodes SECOND.
        //
        // Pre-1.6.16.x ran these concurrently with `async let` —
        // worked fine for series whose episodes were already
        // cached server-side, but for series Dispatcharr hadn't
        // scraped yet (Spiral, Theodosia, Adults), the episodes
        // call returned `[]` because it raced the scrape.
        //
        // The OpenAPI schema is explicit about why: `/api/vod/
        // series/{id}/provider-info/` is described as "Get
        // detailed series information, refreshing from provider
        // if needed" — that's the lazy-scrape trigger. Without
        // calling it first, the episodes endpoint returns an
        // empty array because Dispatcharr's per-series episode
        // table hasn't been populated from the upstream Xtream
        // provider yet.
        //
        // Sequential cost: ~one extra network round-trip per
        // first-open of an unscraped series. Acceptable. Already-
        // scraped series still complete in the same total time
        // because both endpoints hit the warm cache fast.
        // Subsequent opens use `SeriesDetailCache` so the cost is
        // paid once.
        let info: DispatcharrVODSeriesProviderInfo?
        do {
            info = try await api.getSeriesProviderInfo(seriesID: sid)
        } catch {
            info = nil
        }
        let episodes = try await api.getVODSeriesEpisodes(seriesID: sid)

        // Build season map from episodes. v1.6.12 also surfaces
        // episode runtime via `duration_secs` (was always blank
        // pre-1.6.12 because the typed column wasn't decoded).
        var seasonMap: [Int: [VODEpisode]] = [:]
        for ep in episodes {
            let season = ep.seasonNumber ?? 1
            // v1.6.16.x: surface per-episode artwork from
            // `custom_properties.movie_image`. Dispatcharr stores
            // the TMDB still URL there for each episode (typically
            // a w185 path on `image.tmdb.org`). Pre-1.6.16.x we
            // hardcoded `posterURL: nil` because the field was
            // unreliable — but that was an artifact of the
            // concurrent-fetch race causing `episodes` to return
            // empty arrays. Now that provider-info runs first and
            // primes the per-episode cache, `movie_image` is
            // populated and we can render real episode thumbnails
            // in the row instead of a blank placeholder.
            // v1.6.16.x: episode poster with series-poster fallback.
            // Some series (e.g. Kroll Show on the test server)
            // have `custom_properties: null` on every episode —
            // Dispatcharr's TMDB scraper hasn't fetched per-episode
            // stills for that title, even though the series-level
            // metadata is fully populated. Pre-fallback the episode
            // rows rendered as a stack of identical empty
            // rectangles, which read as "AerioTV is broken." Now
            // the rows fall back to the series poster (already on
            // hand from `existing`), so a sparse-metadata series
            // shows a uniform poster across every episode row
            // instead of blanks. Empty-string `movieImage` is
            // treated as missing (`URL(string: "")` returns nil
            // anyway, but the explicit non-empty check is more
            // defensive).
            let episodePoster: URL? = {
                if let img = ep.customProperties?.movieImage,
                   !img.isEmpty,
                   let url = URL(string: img) {
                    return url
                }
                return existing?.posterURL
            }()
            // v1.6.16.x: per-episode rich metadata. Now that the
            // provider-info-first ordering populates the per-episode
            // table, the schema fields (`air_date`, `rating`,
            // `tmdb_id`, `imdb_id`) and `custom_properties.crew`
            // are reliably set, so we plumb them through to the
            // display model. Fields default to "" when absent so
            // the row UI's existing empty-skip logic just works.
            var vodEp = VODEpisode(
                id: String(ep.id), seriesID: seriesID,
                title: ep.title,
                seasonNumber: season, episodeNumber: ep.episodeNumber ?? 0,
                plot: ep.plot ?? "",
                duration: formatDuration(seconds: ep.durationSecs),
                posterURL: episodePoster,
                streamURL: api.proxyEpisodeURL(uuid: ep.uuid,
                                                  preferredStreamID: ep.streams?.first?.streamID),
                containerExtension: "mp4", serverID: server.id
            )
            vodEp.airDate = ep.airDate ?? ""
            vodEp.rating  = ep.rating ?? ""
            vodEp.tmdbID  = ep.tmdbID ?? ""
            vodEp.imdbID  = ep.imdbID ?? ""
            vodEp.crew    = ep.customProperties?.crew ?? ""
            seasonMap[season, default: []].append(vodEp)
        }
        let seasons: [VODSeason] = seasonMap.map { (num, eps) in
            VODSeason(id: "\(seriesID)-s\(num)", seasonNumber: num,
                      episodes: eps.sorted { $0.episodeNumber < $1.episodeNumber })
        }.sorted { $0.seasonNumber < $1.seasonNumber }

        // Merge metadata: provider-info wins where non-empty, else
        // fall back to `existing`'s list-time values.
        let cp = info?.customProperties

        let mergedName: String = {
            if let n = info?.name, !n.isEmpty { return n }
            return existing?.name ?? ""
        }()

        let mergedPlot: String = {
            if let d = info?.description, !d.isEmpty { return d }
            return existing?.plot ?? ""
        }()

        let mergedGenre: String = {
            if let g = info?.genre, !g.isEmpty { return g }
            return existing?.genre ?? ""
        }()

        let mergedRating: String = {
            if let r = info?.rating, !r.isEmpty, r != "0", r != "0.0" { return r }
            return existing?.rating ?? ""
        }()

        let mergedReleaseDate: String = {
            // Provider-info doesn't expose a top-level release date
            // for series; try custom_properties first (where
            // `releaseDate` / `first_air_date` may live), then year.
            if let d = cp?.releaseDate, !d.isEmpty { return d }
            if let d = cp?.firstAirDate, !d.isEmpty { return d }
            if let y = info?.year, y > 0 { return String(y) }
            return existing?.releaseDate ?? ""
        }()

        let mergedCast: String = {
            if let c = cp?.cast, !c.isEmpty { return c }
            return existing?.cast ?? ""
        }()

        let mergedDirector: String = {
            if let d = cp?.director, !d.isEmpty { return d }
            return existing?.director ?? ""
        }()

        let mergedCountry: String = {
            if let c = cp?.country, !c.isEmpty { return c }
            return existing?.country ?? ""
        }()

        let mergedTmdbID: String = {
            if let id = info?.tmdbID, !id.isEmpty { return id }
            return existing?.tmdbID ?? ""
        }()

        let mergedYoutubeTrailer: String = {
            if let t = cp?.youtubeTrailer, !t.isEmpty { return t }
            if let t = cp?.trailer, !t.isEmpty { return t }
            return existing?.youtubeTrailer ?? ""
        }()

        // Backdrop: prefer provider-info first non-empty backdrop_path
        // (resolved through TMDB CDN if it's a bare slug), else
        // fall back to existing's list-time backdrop.
        let backdropPath = cp?.backdropPath?.first(where: { !$0.isEmpty })
        let mergedBackdropURL: URL? = backdropPath.flatMap { resolveImageURL($0, base: base) }
            ?? existing?.backdropURL

        // Poster: use the provider-info `cover.url` if present (it's
        // the same TMDB CDN poster the list endpoint exposes via
        // `logo.url`), else keep existing's poster URL.
        let mergedPosterURL: URL? = {
            if let raw = info?.cover?.url, !raw.isEmpty,
               let url = resolveURL(raw, base: base) {
                return url
            }
            return existing?.posterURL
        }()

        var enriched = VODSeries(
            id: seriesID,
            name: mergedName,
            posterURL: mergedPosterURL,
            backdropURL: mergedBackdropURL,
            rating: mergedRating,
            plot: mergedPlot,
            genre: mergedGenre,
            releaseDate: mergedReleaseDate,
            cast: mergedCast,
            director: mergedDirector,
            categoryID: existing?.categoryID ?? "",
            categoryName: existing?.categoryName ?? "",
            serverID: server.id,
            seasons: seasons,
            episodeCount: episodes.count
        )
        enriched.tmdbID = mergedTmdbID
        enriched.youtubeTrailer = mergedYoutubeTrailer
        enriched.country = mergedCountry
        return enriched
    }
}
