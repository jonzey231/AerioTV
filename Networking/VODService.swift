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

    /// Hosts on the TMDB CDN that we know are safe to fetch directly
    /// without auth. These are anonymous public endpoints.
    private static let allowedExternalImageHosts: Set<String> = [
        "image.tmdb.org",
        "www.themoviedb.org",
        "themoviedb.org"
    ]

    /// v1.6.23: validates an absolute URL string before returning it,
    /// to defuse the SSRF risk a malicious server could exploit by
    /// emitting URLs that point at the user's LAN or localhost. The
    /// rule:
    ///
    /// - Only `http` / `https` schemes are accepted. Reject `file://`,
    ///   `data://`, `javascript:`, etc.
    /// - Same-host-as-server URLs are always allowed (the user's own
    ///   Dispatcharr / Xtream box is in the trust boundary by
    ///   definition).
    /// - Public CDNs in `allowedExternalImageHosts` are allowed
    ///   (TMDB image hosts).
    /// - Loopback (127/8, ::1) and link-local (169.254/16, fe80::/10)
    ///   are rejected even if the user's server happens to be on the
    ///   same machine, because we already covered "same host as
    ///   server" above.
    /// - RFC-1918 ranges (10/8, 172.16/12, 192.168/16) are allowed
    ///   ONLY when the host matches the user's configured server
    ///   host. This permits LAN-only Dispatcharr deployments while
    ///   blocking attacker-controlled servers from probing arbitrary
    ///   LAN IPs.
    ///
    /// Returns nil on rejection. Caller should fall back to a
    /// placeholder image or skip the fetch.
    static func validateAbsoluteURL(_ url: URL, serverHost: String?) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased() else { return nil }

        // Always allow the user's own server (LAN or public, doesn't
        // matter; same trust boundary).
        if let serverHost = serverHost?.lowercased(), host == serverHost {
            return url
        }
        // Always allow well-known public image CDNs.
        if allowedExternalImageHosts.contains(host) {
            return url
        }
        // Block loopback and link-local explicitly.
        if isLoopbackHost(host) || isLinkLocalHost(host) {
            return nil
        }
        // Block private network ranges. (RFC-1918 + IPv6 ULA.)
        if isPrivateNetworkHost(host) {
            return nil
        }
        // Public host that isn't in our explicit allow-list: permit.
        // We can't enumerate every legitimate CDN; the threat model
        // is server-side SSRF probing, which the loopback / private-
        // network blocks already handle.
        return url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host == "::1" { return true }
        if host.hasPrefix("127.") {
            return parseIPv4Octets(host) != nil
        }
        return false
    }

    private static func isLinkLocalHost(_ host: String) -> Bool {
        if host.hasPrefix("169.254.") {
            return parseIPv4Octets(host) != nil
        }
        if host.hasPrefix("fe80:") || host.hasPrefix("[fe80:") {
            return true
        }
        return false
    }

    private static func isPrivateNetworkHost(_ host: String) -> Bool {
        guard let octets = parseIPv4Octets(host) else {
            // IPv6 ULA fc00::/7
            if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("[fc") || host.hasPrefix("[fd") {
                return true
            }
            return false
        }
        // 10.0.0.0/8
        if octets[0] == 10 { return true }
        // 172.16.0.0/12
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        // 192.168.0.0/16
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }

    private static func parseIPv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let n = Int(part), (0...255).contains(n) else { return nil }
            octets.append(n)
        }
        return octets
    }

    private static func resolveURL(_ raw: String, base: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            // v1.6.23: server-provided absolute URL. Validate scheme
            // and host before trusting it. The server's own host is
            // extracted from the configured baseURL so LAN-only
            // Dispatcharr setups (192.168.x.x) work for their own
            // server's URLs but not for arbitrary LAN probes.
            guard let url = URL(string: raw) else { return nil }
            let serverHost = URL(string: base)?.host
            return validateAbsoluteURL(url, serverHost: serverHost)
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
    static func resolveImageURL(_ raw: String,
                                base: String,
                                size: String = "w1280") -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            // v1.6.23: validate absolute URLs against the trust
            // boundary. Same logic as `resolveURL`: only the user's
            // own server host or a known public CDN is trusted.
            // Loopback / link-local / RFC-1918 ranges are rejected
            // unless they match the configured server host.
            guard let url = URL(string: raw) else { return nil }
            let serverHost = URL(string: base)?.host
            return validateAbsoluteURL(url, serverHost: serverHost)
        }
        // TMDB heuristic: single-segment path with an image extension.
        // TMDB poster/backdrop paths are flat (`/abc.jpg`, never
        // `/some/subdir/abc.jpg`). A bare filename without leading `/`
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
            var movie = VODMovie(
                id: String(item.streamID), name: item.name,
                // resolveURL validates the server-provided image URL (rejects
                // loopback / link-local / private-network hosts that aren't the
                // user's own server) the same way the Dispatcharr path does,
                // closing the SSRF gap where the raw URL(string:) trusted it.
                posterURL: item.streamIcon.flatMap { resolveURL($0, base: server.baseURL) }, backdropURL: nil,
                rating: item.rating ?? "", plot: item.plot ?? "",
                genre: item.genre ?? "", releaseDate: item.releaseDate ?? "",
                duration: "", cast: item.cast ?? "", director: item.director ?? "", imdbID: "",
                categoryID: item.categoryID ?? "", categoryName: catName,
                streamURL: streamURL, containerExtension: ext, serverID: server.id
            )
            // v0.26.0: get_vod_streams now reliably carries the YouTube
            // trailer; surface it. It was decoded into XtreamVODItem but
            // never assigned here, so XC movies never showed a Trailer
            // button (Dispatcharr-native movies already got one).
            movie.youtubeTrailer = item.youtubeTrailer ?? ""
            return movie
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
                posterURL: item.cover.flatMap { resolveURL($0, base: server.baseURL) }, backdropURL: nil,
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
                    posterURL: ep.info?.movieImage.flatMap { resolveURL($0, base: server.baseURL) },
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
            posterURL: info?.cover.flatMap { resolveURL($0, base: server.baseURL) }, backdropURL: nil,
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
                // Route through resolveImageURL (same as the backdrops below)
                // so a TMDB path is rewritten and an absolute URL is validated
                // against the SSRF guard, instead of trusting raw URL(string:).
                if let img = ep.customProperties?.movieImage,
                   !img.isEmpty,
                   let url = resolveImageURL(img, base: base) {
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

// MARK: - TMDB program-poster config

/// Opt-in TMDB program-poster settings. OFF by default. The user
/// supplies their own free TMDB v3 API key (Settings > App Behaviors).
/// The key lives in the iCloud Keychain (synchronizable) so it follows
/// the user to their other devices, never in UserDefaults or git. When
/// disabled or unkeyed, the whole TMDB path is inert and only
/// server-provided posters show.
enum TMDBPosters {
    /// `@AppStorage` / UserDefaults key for the enable toggle (the
    /// toggle itself is per-device, like the other App Behaviors
    /// toggles; only the API key syncs).
    static let enabledDefaultsKey = "programPostersTMDBEnabled"
    /// Keychain item key for the user's TMDB API key.
    static let keychainKey = "tmdbAPIKey"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// The stored API key, or nil if absent/empty.
    static var apiKey: String? {
        let k = loadAPIKey()
        return k.isEmpty ? nil : k
    }

    /// Read the key, preferring the iCloud-synced copy and falling back
    /// to any legacy local-only copy.
    static func loadAPIKey() -> String {
        if let synced = KeychainHelper.load(key: keychainKey, synchronizable: true),
           !synced.isEmpty { return synced }
        return KeychainHelper.load(key: keychainKey, synchronizable: false) ?? ""
    }

    /// Persist (or clear) the key in the iCloud Keychain so it syncs
    /// across the user's devices; any stale local-only copy is removed
    /// so the synced one is authoritative.
    static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainHelper.delete(keychainKey, synchronizable: false)
        if trimmed.isEmpty {
            KeychainHelper.delete(keychainKey, synchronizable: true)
        } else {
            KeychainHelper.save(trimmed, for: keychainKey, synchronizable: true)
        }
    }
}

// MARK: - TMDB client (poster-by-title + key validation)

/// Minimal TMDB v3 client used only to (a) validate the user's API key
/// and (b) look up a poster image for a program title. Public CDN
/// images, no auth beyond the user's own key. Results are cached by
/// title so opening several program-info popups doesn't re-query.
enum TMDBService {
    private static let apiBase = "https://api.themoviedb.org/3"
    private static let imageBase = "https://image.tmdb.org/t/p"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// title (lowercased) -> poster path ("" = confirmed no-poster miss,
    /// so we don't re-query a title TMDB has nothing for). NSCache is
    /// internally thread-safe, so the global is safe to share.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSString>()

    private struct SearchResponse: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let posterPath: String?
            let mediaType: String?
            let popularity: Double?
            let releaseDate: String?
            let firstAirDate: String?
            enum CodingKeys: String, CodingKey {
                case posterPath = "poster_path"
                case mediaType = "media_type"
                case popularity
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
            }
        }
    }

    /// TMDB accepts two credential shapes: the classic v3 API Key (sent
    /// as an `api_key` query param) and the newer v4 "Read Access Token",
    /// a JWT sent as an `Authorization: Bearer` header. The user may
    /// paste either (TMDB's settings page shows the token first), so we
    /// detect the JWT shape and route auth accordingly - otherwise a
    /// pasted v4 token would silently 401 as an api_key param.
    private static func isBearerToken(_ key: String) -> Bool {
        key.hasPrefix("eyJ") && key.filter { $0 == "." }.count == 2
    }

    /// Build an authorized GET request for `path`, attaching the user's
    /// credential as either a bearer header (v4 token) or an api_key
    /// query item (v3 key).
    private static func makeRequest(path: String, queryItems: [URLQueryItem] = [], key: String) -> URLRequest? {
        guard var comps = URLComponents(string: apiBase + path) else { return nil }
        let bearer = isBearerToken(key)
        var items = queryItems
        if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        comps.queryItems = items.isEmpty ? nil : items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if bearer { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Validate a credential by hitting `/configuration`. 200 = valid.
    static func validateKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let req = makeRequest(path: "/configuration", key: trimmed) else { return false }
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Look up a poster image URL for a program title via
    /// `/search/multi`. Returns an `image.tmdb.org` CDN URL or nil.
    /// `include_adult=false` per the app's fail-closed content policy.
    static func posterURL(forTitle title: String, apiKey: String, size: String = "w500") async -> URL? {
        let cacheKey = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cacheKey.isEmpty else { return nil }
        if let cached = cache.object(forKey: cacheKey as NSString) {
            let path = cached as String
            return path.isEmpty ? nil : URL(string: imageBase + "/\(size)" + path)
        }
        // Android-parity sanitation: split the trailing "(YYYY)" off the
        // query text (a year embedded in the query reliably misses on
        // /search/multi) and retry once with leading punctuation stripped.
        // /search/multi has no year parameter, so the year is re-applied to
        // the RESULTS as a preference tier, not a hard filter; a playlist
        // year disagreeing with TMDB still finds art.
        let (cleaned, year) = splitTitleYear(title)
        guard !cleaned.isEmpty else { return nil }
        var path: String?
        var sawResponse = false
        for attempt in searchAttempts(for: cleaned) {
            guard let req = makeRequest(path: "/search/multi", queryItems: [
                URLQueryItem(name: "query", value: attempt),
                URLQueryItem(name: "include_adult", value: "false")
            ], key: apiKey) else { continue }
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data)
            else { continue } // transport failure / non-200: never cached
            sawResponse = true
            let typedHits = decoded.results.filter {
                ($0.posterPath?.isEmpty == false) && ($0.mediaType == "movie" || $0.mediaType == "tv")
            }
            if let y = year,
               let hit = typedHits.first(where: { ($0.releaseDate ?? $0.firstAirDate ?? "").hasPrefix(y) }) {
                path = hit.posterPath
            } else if let hit = typedHits.first {
                path = hit.posterPath
            } else if let any = decoded.results.first(where: { $0.posterPath?.isEmpty == false }) {
                path = any.posterPath
            }
            if path != nil { break }
        }
        // Cache "" only when TMDB actually answered (confirmed miss);
        // keep transport failures retryable.
        if sawResponse {
            cache.setObject((path ?? "") as NSString, forKey: cacheKey as NSString)
        }
        let posterURL = (path?.isEmpty == false) ? URL(string: imageBase + "/\(size)" + path!) : nil
        // Verification breadcrumb: proves TMDB was queried and shows what
        // came back (the API key is never logged). Logs misses too, unlike
        // the ProgramInfo-only hit log, and this also covers the VOD path.
        debugLog("🎬 TMDB search '\(title)' -> \(posterURL?.absoluteString ?? "no match")")
        return posterURL
    }

    private struct DetailResponse: Decodable {
        let posterPath: String?
        enum CodingKeys: String, CodingKey { case posterPath = "poster_path" }
    }

    /// Poster by exact TMDB id (no fuzzy matching) - used for VOD items
    /// that already carry a tmdb_id. `isMovie` picks /movie vs /tv.
    static func posterURL(forTMDBID id: String, isMovie: Bool, apiKey: String, size: String = "w500") async -> URL? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cacheKey = "id:\(isMovie ? "movie" : "tv"):\(trimmed)"
        if let cached = cache.object(forKey: cacheKey as NSString) {
            let path = cached as String
            return path.isEmpty ? nil : URL(string: imageBase + "/\(size)" + path)
        }
        guard let req = makeRequest(path: "/\(isMovie ? "movie" : "tv")/\(trimmed)", key: apiKey) else { return nil }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(DetailResponse.self, from: data)
        else { return nil }
        cache.setObject((decoded.posterPath ?? "") as NSString, forKey: cacheKey as NSString)
        let posterURL = (decoded.posterPath?.isEmpty == false) ? URL(string: imageBase + "/\(size)" + decoded.posterPath!) : nil
        debugLog("🎬 TMDB id \(trimmed) (\(isMovie ? "movie" : "tv")) -> \(posterURL?.absoluteString ?? "no match")")
        return posterURL
    }
}

// MARK: - TMDB rich data models (Android parity: TMDBService.kt)

/// Display-ready detail fields backfilled from TMDB when the server and
/// provider-info leave them blank. Every field optional; blank strings are
/// stripped to nil at parse.
struct TMDBDetails: Sendable {
    let overview: String?
    let genres: String?
    let castTop: String?
    let director: String?
    let year: String?
    let voteAverage: String?
    let posterPath: String?
}

/// One cast or crew member. `id` stays a String even though TMDB sends an
/// Int, because every consumer round-trips it into the /person/{id} path.
/// `role` is the character name for cast, "Director"/"Creator" for crew.
struct TMDBPerson: Identifiable, Sendable {
    let id: String
    let name: String
    let role: String?
    let profilePath: String?
}

struct TMDBCredits: Sendable {
    let cast: [TMDBPerson]
    let directors: [TMDBPerson]
}

/// A Known For tile. `posterPath` is required (entries without art are
/// filtered before display); `isMovie` routes the deep-link.
struct TMDBKnownForItem: Identifiable, Sendable {
    let id: String
    let title: String
    let posterPath: String
    let isMovie: Bool
}

struct TMDBPersonBio: Sendable {
    let name: String
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let profilePath: String?
    let knownFor: [TMDBKnownForItem]
}

// MARK: - TMDB rich data endpoints (details / credits / person bio)

extension TMDBService {

    /// TMDB ids arrive as JSON Ints but some proxies stringify them;
    /// decode either shape and keep the String (it round-trips into URL
    /// paths).
    private struct FlexID: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = String(i) }
            else if let s = try? c.decode(String.self) { value = s.isEmpty ? nil : s }
            else { value = nil }
        }
    }

    /// Int-or-String tolerant integer (episode_count / order).
    private struct FlexInt: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i }
            else if let s = try? c.decode(String.self) { value = Int(s) }
            else { value = nil }
        }
    }

    private struct DetailsCreditsResponse: Decodable {
        let overview: String?
        let genres: [Genre]?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let posterPath: String?
        let createdBy: [CreatedBy]?
        let credits: CreditsBlock?
        struct Genre: Decodable { let name: String? }
        struct CreatedBy: Decodable {
            let id: FlexID?
            let name: String?
            let profilePath: String?
            enum CodingKeys: String, CodingKey {
                case id, name
                case profilePath = "profile_path"
            }
        }
        struct CreditsBlock: Decodable {
            let cast: [CastEntry]?
            let crew: [CrewEntry]?
        }
        struct CastEntry: Decodable {
            let id: FlexID?
            let name: String?
            let character: String?
            let profilePath: String?
            enum CodingKeys: String, CodingKey {
                case id, name, character
                case profilePath = "profile_path"
            }
        }
        struct CrewEntry: Decodable {
            let id: FlexID?
            let name: String?
            let job: String?
            let profilePath: String?
            enum CodingKeys: String, CodingKey {
                case id, name, job
                case profilePath = "profile_path"
            }
        }
        enum CodingKeys: String, CodingKey {
            case overview, genres, credits
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
            case voteAverage = "vote_average"
            case posterPath = "poster_path"
            case createdBy = "created_by"
        }
    }

    private struct PersonResponse: Decodable {
        let name: String?
        let biography: String?
        let birthday: String?
        let deathday: String?
        let placeOfBirth: String?
        let profilePath: String?
        let combinedCredits: CombinedCredits?
        struct CombinedCredits: Decodable { let cast: [Entry]? }
        struct Entry: Decodable {
            let id: FlexID?
            let title: String?
            let name: String?
            let posterPath: String?
            let mediaType: String?
            let genreIds: [Int]?
            let character: String?
            let episodeCount: FlexInt?
            let order: FlexInt?
            let popularity: Double?
            enum CodingKeys: String, CodingKey {
                case id, title, name, character, order, popularity
                case posterPath = "poster_path"
                case mediaType = "media_type"
                case genreIds = "genre_ids"
                case episodeCount = "episode_count"
            }
        }
        enum CodingKeys: String, CodingKey {
            case name, biography, birthday, deathday
            case placeOfBirth = "place_of_birth"
            case profilePath = "profile_path"
            case combinedCredits = "combined_credits"
        }
    }

    private struct TypedSearchResponse: Decodable {
        let results: [Entry]?
        struct Entry: Decodable { let id: FlexID? }
    }

    /// NSCache stores classes; tiny box for the struct payloads. All four
    /// rich caches are success-only (a transport failure or non-200 is
    /// never cached so it stays retryable; see the dossier gotcha about a
    /// bad-key period poisoning titles forever).
    private final class Box<T>: NSObject {
        let value: T
        init(_ value: T) { self.value = value }
    }

    nonisolated(unsafe) private static let detailsCache = NSCache<NSString, Box<TMDBDetails>>()
    nonisolated(unsafe) private static let creditsCache = NSCache<NSString, Box<TMDBCredits>>()
    nonisolated(unsafe) private static let personBioCache = NSCache<NSString, Box<TMDBPersonBio>>()

    /// Drop ALL caches. Called when the user saves a new API key: misses
    /// cached under the previous key (e.g. while a bad key 401ed) must not
    /// survive a key change; positives re-resolve cheaply on next lookup.
    static func clearCache() {
        cache.removeAllObjects()
        detailsCache.removeAllObjects()
        creditsCache.removeAllObjects()
        personBioCache.removeAllObjects()
    }

    /// Shared blank-stripping helper.
    private static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: Title sanitation (typed search)

    /// Trailing "(YYYY)" where YYYY is 19xx/20xx.
    private static let trailingYearRegex =
        try! NSRegularExpression(pattern: #"\(((?:19|20)\d{2})\)\s*$"#)

    /// Split a trailing year off a playlist title. A name that is ONLY
    /// "(2010)" keeps its original text with year nil rather than sending
    /// an empty query.
    static func splitTitleYear(_ raw: String) -> (title: String, year: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = trailingYearRegex.firstMatch(in: trimmed, range: range),
              let whole = Range(m.range, in: trimmed),
              let yearRange = Range(m.range(at: 1), in: trimmed) else {
            return (trimmed, nil)
        }
        let cleaned = String(trimmed[..<whole.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return (trimmed, nil) }
        return (cleaned, String(trimmed[yearRange]))
    }

    /// Query attempts in order: the cleaned title, then the title with
    /// leading non-alphanumerics stripped (TMDB search trips on a leading
    /// "#" etc.), filtered non-empty and deduplicated.
    private static func searchAttempts(for cleaned: String) -> [String] {
        var attempts = [cleaned]
        let stripped = String(cleaned.drop { !$0.isLetter && !$0.isNumber })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty { attempts.append(stripped) }
        var seen = Set<String>()
        return attempts.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Title -> id resolution (typed search, year-aware)

    /// Resolve a TMDB id for a title via the TYPED search endpoint
    /// (/search/movie or /search/tv), which accepts a year filter that
    /// /search/multi lacks. Attempt order: each searchAttempts entry WITH
    /// the year; then, only when a year was actually extracted, one final
    /// no-year attempt (playlist years sometimes disagree with TMDB).
    /// Cached in the shared cache under "details-id:<kind>:<orig lower>";
    /// "" is a confirmed miss. Failed requests are never cached.
    static func resolveID(forTitle title: String, isMovie: Bool, apiKey: String) async -> String? {
        let kind = isMovie ? "movie" : "tv"
        let cacheKey = "details-id:\(kind):\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        if let cached = cache.object(forKey: cacheKey as NSString) {
            let s = cached as String
            return s.isEmpty ? nil : s
        }
        let (cleaned, year) = splitTitleYear(title)
        guard !cleaned.isEmpty else { return nil }
        let yearParam = isMovie ? "year" : "first_air_date_year"

        var plans: [(query: String, year: String?)] = searchAttempts(for: cleaned).map { ($0, year) }
        if year != nil { plans.append((cleaned, nil)) }

        var sawConfirmedMiss = false
        for plan in plans {
            var items = [
                URLQueryItem(name: "query", value: plan.query),
                URLQueryItem(name: "include_adult", value: "false")
            ]
            if let y = plan.year { items.append(URLQueryItem(name: yearParam, value: y)) }
            guard let req = makeRequest(path: "/search/\(kind)", queryItems: items, key: apiKey) else { continue }
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(TypedSearchResponse.self, from: data) else {
                // Transport failure / non-200: never cache, stays retryable.
                continue
            }
            sawConfirmedMiss = true
            if let id = decoded.results?.first?.id?.value, !id.isEmpty {
                cache.setObject(id as NSString, forKey: cacheKey as NSString)
                debugLog("🎬 TMDB resolve '\(title)' (\(kind)) -> id \(id)")
                return id
            }
        }
        if sawConfirmedMiss {
            cache.setObject("" as NSString, forKey: cacheKey as NSString)
            debugLog("🎬 TMDB resolve '\(title)' (\(kind)) -> no match")
        }
        return nil
    }

    // MARK: Details (metadata backfill)

    /// Detail fields by exact TMDB id. One request carries details AND
    /// credits via append_to_response; details and credits still cache
    /// independently (the second hit is cheap, mirrors Android).
    static func details(forTMDBID id: String, isMovie: Bool, apiKey: String) async -> TMDBDetails? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let kind = isMovie ? "movie" : "tv"
        let cacheKey = "details:\(kind):\(trimmed)" as NSString
        if let boxed = detailsCache.object(forKey: cacheKey) { return boxed.value }
        guard let req = makeRequest(path: "/\(kind)/\(trimmed)",
                                    queryItems: [URLQueryItem(name: "append_to_response", value: "credits")],
                                    key: apiKey) else { return nil }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(DetailsCreditsResponse.self, from: data)
        else { return nil }

        let genres = decoded.genres?.compactMap { nonBlank($0.name) }.joined(separator: ", ")
        // Filter THEN cap: an invalid row among the first 6 should backfill
        // from later entries instead of shrinking the list.
        let castTop = decoded.credits?.cast?.compactMap { nonBlank($0.name) }.prefix(6).joined(separator: ", ")
        let director: String?
        if isMovie {
            director = decoded.credits?.crew?
                .filter { $0.job == "Director" }
                .compactMap { nonBlank($0.name) }
                .joined(separator: ", ")
        } else {
            director = decoded.createdBy?.compactMap { nonBlank($0.name) }.joined(separator: ", ")
        }
        let dateStr = isMovie ? decoded.releaseDate : decoded.firstAirDate
        let year = nonBlank(dateStr).map { String($0.prefix(4)) }
        // vote_average 0.0 means unrated on TMDB; drop it.
        let vote: String? = (decoded.voteAverage ?? 0) > 0 ? String(format: "%.1f", decoded.voteAverage!) : nil

        let details = TMDBDetails(
            overview: nonBlank(decoded.overview),
            genres: nonBlank(genres),
            castTop: nonBlank(castTop),
            director: nonBlank(director),
            year: year,
            voteAverage: vote,
            posterPath: nonBlank(decoded.posterPath)
        )
        detailsCache.setObject(Box(details), forKey: cacheKey)
        debugLog("🎬 TMDB details id \(trimmed) (\(kind)) -> ok")
        return details
    }

    static func details(forTitle title: String, isMovie: Bool, apiKey: String) async -> TMDBDetails? {
        guard let id = await resolveID(forTitle: title, isMovie: isMovie, apiKey: apiKey) else { return nil }
        return await details(forTMDBID: id, isMovie: isMovie, apiKey: apiKey)
    }

    // MARK: Structured credits

    private static func parsePerson(id: FlexID?, name: String?, role: String?, profilePath: String?) -> TMDBPerson? {
        // Rows missing a name or id can neither render nor deep-link.
        guard let pid = id?.value, !pid.isEmpty, let n = nonBlank(name) else { return nil }
        return TMDBPerson(id: pid, name: n, role: nonBlank(role), profilePath: nonBlank(profilePath))
    }

    /// Structured cast (first 20) + directors. Movies: crew rows with
    /// job=="Director" (role "Director"). TV: top-level created_by (role
    /// "Creator"); TMDB tv has no per-series Director job.
    static func credits(forTMDBID id: String, isMovie: Bool, apiKey: String) async -> TMDBCredits? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let kind = isMovie ? "movie" : "tv"
        let cacheKey = "credits:\(kind):\(trimmed)" as NSString
        if let boxed = creditsCache.object(forKey: cacheKey) { return boxed.value }
        guard let req = makeRequest(path: "/\(kind)/\(trimmed)",
                                    queryItems: [URLQueryItem(name: "append_to_response", value: "credits")],
                                    key: apiKey) else { return nil }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(DetailsCreditsResponse.self, from: data)
        else { return nil }

        // Filter THEN cap (same rationale as castTop above).
        let cast = (decoded.credits?.cast ?? []).compactMap {
            parsePerson(id: $0.id, name: $0.name, role: $0.character, profilePath: $0.profilePath)
        }.prefix(20)
        let directors: [TMDBPerson]
        if isMovie {
            directors = (decoded.credits?.crew ?? [])
                .filter { $0.job == "Director" }
                .compactMap { parsePerson(id: $0.id, name: $0.name, role: "Director", profilePath: $0.profilePath) }
        } else {
            directors = (decoded.createdBy ?? [])
                .compactMap { parsePerson(id: $0.id, name: $0.name, role: "Creator", profilePath: $0.profilePath) }
        }
        let credits = TMDBCredits(cast: Array(cast), directors: directors)
        creditsCache.setObject(Box(credits), forKey: cacheKey)
        debugLog("🎬 TMDB credits id \(trimmed) (\(kind)) -> cast \(credits.cast.count), directors \(credits.directors.count)")
        return credits
    }

    static func credits(forTitle title: String, isMovie: Bool, apiKey: String) async -> TMDBCredits? {
        guard let id = await resolveID(forTitle: title, isMovie: isMovie, apiKey: apiKey) else { return nil }
        return await credits(forTMDBID: id, isMovie: isMovie, apiKey: apiKey)
    }

    // MARK: Person bio + Known For

    /// Known For cameo filter (mirrors the Android heuristic, which itself
    /// reproduces TMDB's own person-page intent): a row survives only when
    /// it has id+title+poster, is not Talk(10767)/News(10763)/Reality(10764),
    /// is not the person playing themselves, has episode_count >= 3 when
    /// present, order <= 8 when present, and media_type is exactly movie
    /// or tv. Survivors sort by popularity desc, dedupe by id (most
    /// popular duplicate wins), cap 8.
    private static func parseKnownFor(_ entries: [PersonResponse.Entry]?) -> [TMDBKnownForItem] {
        guard let entries else { return [] }
        let excludedGenres: Set<Int> = [10767, 10763, 10764]
        let survivors: [(item: TMDBKnownForItem, popularity: Double)] = entries.compactMap { e in
            guard let id = e.id?.value, !id.isEmpty,
                  let title = nonBlank(e.title ?? e.name),
                  let poster = nonBlank(e.posterPath) else { return nil }
            if let gids = e.genreIds, gids.contains(where: { excludedGenres.contains($0) }) { return nil }
            if let ch = e.character?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if ch == "self" || ch.hasPrefix("self ") || ch == "herself" || ch == "himself" { return nil }
            }
            if let epCount = e.episodeCount?.value, epCount < 3 { return nil }
            if let order = e.order?.value, order > 8 { return nil }
            guard e.mediaType == "movie" || e.mediaType == "tv" else { return nil }
            return (TMDBKnownForItem(id: id, title: title, posterPath: poster, isMovie: e.mediaType == "movie"),
                    e.popularity ?? 0)
        }
        var seen = Set<String>()
        return survivors
            .sorted { $0.popularity > $1.popularity }
            .filter { seen.insert($0.item.id).inserted }
            .prefix(8)
            .map(\.item)
    }

    /// Person bio with Known For riding the same response via
    /// append_to_response=combined_credits. A missing name fails the whole
    /// parse; a missing combined_credits block just yields empty knownFor.
    static func personBio(forID id: String, apiKey: String) async -> TMDBPersonBio? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cacheKey = "person:\(trimmed)" as NSString
        if let boxed = personBioCache.object(forKey: cacheKey) { return boxed.value }
        guard let req = makeRequest(path: "/person/\(trimmed)",
                                    queryItems: [URLQueryItem(name: "append_to_response", value: "combined_credits")],
                                    key: apiKey) else { return nil }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(PersonResponse.self, from: data),
              let name = nonBlank(decoded.name)
        else { return nil }

        let bio = TMDBPersonBio(
            name: name,
            biography: nonBlank(decoded.biography),
            birthday: nonBlank(decoded.birthday),
            deathday: nonBlank(decoded.deathday),
            placeOfBirth: nonBlank(decoded.placeOfBirth),
            profilePath: nonBlank(decoded.profilePath),
            knownFor: parseKnownFor(decoded.combinedCredits?.cast)
        )
        personBioCache.setObject(Box(bio), forKey: cacheKey)
        debugLog("🎬 TMDB person \(trimmed) -> ok, knownFor \(bio.knownFor.count)")
        return bio
    }

    /// Pure string concatenation, no network and no gating. TMDB omits
    /// profile_path for most minor cast; nil/blank-safe.
    /// Sizes used: w185 strip headshots and Known For tiles, w342 bio
    /// headshot, w500 posters.
    static func profileImageURL(path: String?, size: String = "w185") -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(p)")
    }
}
