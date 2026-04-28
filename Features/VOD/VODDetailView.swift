import SwiftUI
import SwiftData

// MARK: - VOD Detail View (Movie or Series)
struct VODDetailView: View {
    let item: VODDisplayItem
    @Query private var servers: [ServerConnection]
    /// Every episode-typed `WatchProgress` row. Filtered in memory by
    /// `seriesID == item.id` inside `progressByEpisodeID`. v1.6.8:
    /// drives the "Currently Watching" / "Watched" pill on each
    /// episode row so users arriving at the series detail page (for
    /// example from a tvOS Top Shelf deep-link after cross-device
    /// sync) can see at a glance which episode they were in the
    /// middle of. SwiftData `#Predicate` can capture primitives from
    /// the surrounding scope, but binding `seriesID` at query-init
    /// time would require a custom `init` just to reassign
    /// `_watchProgress`; the episode-count fits comfortably in
    /// memory so we take the simpler filter-on-read path.
    @Query(filter: #Predicate<WatchProgress> { $0.vodType == "episode" })
    private var allEpisodeProgress: [WatchProgress]
    @Environment(\.dismiss) private var dismiss

    @State private var fullMovie: VODMovie?
    @State private var fullSeries: VODSeries?
    @State private var selectedSeason: Int = 0
    @State private var playingURL: IdentifiableURL?
    @State private var playingTitle = ""
    @State private var playingHeaders: [String: String] = [:]
    @State private var playingVodID: String = ""       // movie.id or episode.id depending on context
    @State private var playingVodType: String = "movie" // "movie" or "episode"
    @State private var playingPosterURL: String?       // episode poster overrides series poster when playing an episode
    @State private var isLoadingDetail = false
    @State private var isResolvingURL = false
    @Binding var isPlaying: Bool

    private var server: ServerConnection? {
        servers.first { $0.id == item.serverID }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                // v1.6.12: explicit `.frame(maxWidth: .infinity, alignment: .leading)`
                // on this outer VStack clamps the column to the
                // ScrollView's content width. Without it, an
                // `.frame(maxWidth: .infinity)` on a deeper child
                // (e.g. metaRow's value Text) propagates up through
                // the leading-aligned VStack and bleeds the layout
                // past the safe-area's leading edge — which clipped
                // the first letter off every plot/genre/cast line
                // in the v1.6.12 enrichment work.
                VStack(alignment: .leading, spacing: 0) {
                    heroSection
                    infoSection
                    if item.type == .series {
                        episodeSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .task { await loadDetail() }
        .fullScreenCover(item: $playingURL) { wrapper in
            PlayerView(
                urls: [wrapper.url],
                title: playingTitle,
                headers: playingHeaders,
                isLive: false,
                artworkURL: (playingPosterURL.flatMap { URL(string: $0) }) ?? item.posterURL,
                vodID: playingVodID,
                vodPosterURL: playingPosterURL ?? item.posterURL?.absoluteString,
                vodServerID: item.serverID.uuidString,
                vodType: playingVodType
            )
            .onDisappear { isPlaying = false }
        }
    }

    // MARK: - Hero
    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop or poster as hero.
            //
            // v1.6.12: wrapped in `GeometryReader` so the image's
            // frame is **explicitly** clamped to the container's
            // proposed width. The previous chain
            // (`.aspectRatio(contentMode: .fill).frame(maxWidth: .infinity).frame(height: 280)`)
            // looked correct on a poster image (~0.67 aspect → 187pt
            // wide at 280pt tall, fits the screen) but the moment the
            // backdrop image loaded (~1.78 aspect → 498pt wide at
            // 280pt tall), `.aspectRatio(.fill)` reported that 498pt
            // as the view's preferred width. `.frame(maxWidth: .infinity)`
            // accepts up to infinity, so the frame became 498pt —
            // **wider than the iPhone viewport**. The parent VStack
            // adopted 498pt, and SwiftUI's positioning of a too-wide
            // leading-aligned frame inside a narrower ScrollView
            // viewport bled the entire infoSection past the safe-
            // area's leading edge, clipping the first letter of every
            // text row. Forcing `.frame(width: geo.size.width, …)`
            // here fully detaches the image's natural aspect from the
            // parent's width math: the frame is exactly the proposed
            // width, the `.aspectRatio(.fill)` content scales to
            // fill (overflowing internally), and `.clipped()` trims
            // the overflow. No upward width propagation, hero looks
            // identical, layout stays inside the safe area.
            let heroURL = (fullMovie?.backdropURL ?? fullSeries?.backdropURL) ?? item.posterURL
            GeometryReader { geo in
                AuthPosterImage(url: heroURL, headers: serverHeaders())
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: 280)
                    .clipped()
            }
            .frame(height: 280)
            .overlay(LinearGradient.heroOverlay)

            HStack(alignment: .bottom, spacing: 14) {
                // Small poster thumbnail
                AuthPosterImage(url: item.posterURL, headers: serverHeaders())
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.headlineLarge)
                        .foregroundColor(.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        // v1.6.12: prefer the full-detail year/rating
                        // when we have it (Dispatcharr now populates
                        // VODMovie.releaseDate and rating from
                        // custom_properties), falling back to the
                        // grid-time `item` snapshot for backwards
                        // compatibility with Xtream payloads.
                        let detailYear = (fullMovie?.releaseYear ?? fullSeries?.releaseYear) ?? ""
                        let displayYear = detailYear.isEmpty ? item.releaseYear : detailYear
                        if !displayYear.isEmpty {
                            Text(displayYear)
                                .font(.labelSmall).foregroundColor(.textSecondary)
                        }
                        if !item.rating.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.statusWarning)
                                Text(item.rating)
                                    .font(.labelSmall).foregroundColor(.textSecondary)
                            }
                        }
                        // v1.6.12: runtime when known (movies only —
                        // series carry per-episode durations on the
                        // episode rows, not at the show level).
                        if let movie = fullMovie, !movie.duration.isEmpty {
                            Text(movie.duration)
                                .font(.labelSmall).foregroundColor(.textSecondary)
                        }
                        if item.type == .movie {
                            Text("MOVIE")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.elevatedBackground)
                                .clipShape(Capsule())
                        }
                    }

                    if item.type == .movie, let movie = fullMovie ?? item.movie {
                        playButton(url: movie.streamURL, title: movie.name)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Info
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            let plot = fullMovie?.plot ?? fullSeries?.plot ?? ""
            if !plot.isEmpty {
                Text(plot)
                    .font(.bodyMedium)
                    .foregroundColor(.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // v1.6.12: external-link row. Surfaces the YouTube
            // trailer + a "View on TMDB" link when the underlying
            // VODMovie carries those identifiers (Dispatcharr's
            // /provider-info/ populates them; series don't have
            // either today). Hidden entirely on tvOS — the system
            // has no browser, and there's no in-app trailer player
            // yet, so the buttons would be no-ops on Apple TV.
            #if !os(tvOS)
            externalLinks
            #endif

            let genre = fullMovie?.genre ?? fullSeries?.genre ?? ""
            if !genre.isEmpty {
                metaRow(label: "Genre", value: genre)
            }
            let cast = fullMovie?.cast ?? fullSeries?.cast ?? ""
            if !cast.isEmpty {
                metaRow(label: "Cast", value: cast)
            }
            let director = fullMovie?.director ?? fullSeries?.director ?? ""
            if !director.isEmpty {
                metaRow(label: "Director", value: director)
            }
            let country = fullMovie?.country ?? fullSeries?.country ?? ""
            if !country.isEmpty {
                metaRow(label: "Country", value: country)
            }
        }
        // v1.6.12 (third pass): clamp infoSection to fill width
        // BEFORE padding so the .padding(.horizontal, 16) carves
        // 16pt margins out of the screen-wide column. Earlier
        // iterations applied `.padding(16)` to a VStack that was
        // sizing to its natural content width — the padding was
        // applied but produced an outer frame narrower than the
        // screen, then the parent leading-aligned VStack pinned
        // that narrow frame to x=0 of the screen, putting the
        // content at x=padding (which looks correct in isolation
        // but visually presents as a narrower column hugging the
        // left edge with no breathing room from the safe area).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - External links (Trailer + TMDB)

    /// Horizontal row of pill-shaped links opening the YouTube
    /// trailer and the TMDB movie/TV page in Safari. Hidden when
    /// neither identifier is present so the row doesn't stake out
    /// vertical space for two empty columns. iOS-only — see
    /// `infoSection` for the platform gate rationale.
    ///
    /// v1.6.12: now reads from `fullSeries` as a fallback so series
    /// detail pages get the same treatment as movies. The TMDB URL
    /// branches on `item.type` because TMDB uses `/movie/<id>` for
    /// films and `/tv/<id>` for shows — same `tmdb_id` namespace,
    /// different web path.
    #if !os(tvOS)
    @ViewBuilder
    private var externalLinks: some View {
        let rawTrailer = fullMovie?.youtubeTrailer
            ?? fullSeries?.youtubeTrailer
            ?? ""
        let rawTmdbID = fullMovie?.tmdbID
            ?? fullSeries?.tmdbID
            ?? ""
        let trailerURL = trailerURL(from: rawTrailer)
        let tmdbURL    = tmdbURL(from: rawTmdbID, type: item.type)

        if trailerURL != nil || tmdbURL != nil {
            HStack(spacing: 10) {
                if let url = trailerURL {
                    Link(destination: url) {
                        externalLinkLabel(icon: "play.rectangle.fill",
                                          text: "Trailer")
                    }
                }
                if let url = tmdbURL {
                    Link(destination: url) {
                        externalLinkLabel(icon: "info.circle.fill",
                                          text: "View on TMDB")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Pill-styled label for the external-link row — keeps the
    /// `Trailer` and `View on TMDB` chips visually consistent and
    /// centralises the styling so future links (IMDB, etc.) drop
    /// in with one extra `Link { externalLinkLabel(...) }` call.
    private func externalLinkLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.labelMedium)
        }
        .foregroundStyle(Color.accentPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(Color.elevatedBackground)
        )
    }

    /// Build a YouTube watch URL from whatever shape Dispatcharr
    /// stores `youtube_trailer` in. Most providers send just the
    /// 11-char video key (`dQw4w9WgXcQ`), but a stray full URL or
    /// `youtu.be/<key>` shows up occasionally — handle both rather
    /// than producing a malformed URL.
    private func trailerURL(from raw: String) -> URL? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if key.hasPrefix("http://") || key.hasPrefix("https://") {
            return URL(string: key)
        }
        if key.hasPrefix("youtu.be/") {
            return URL(string: "https://" + key)
        }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }

    /// Compose the TMDB page URL for a VOD item. `tmdbID` is the
    /// bare numeric ID Dispatcharr stores. TMDB uses different web
    /// paths for films vs. shows (`themoviedb.org/movie/<id>` and
    /// `themoviedb.org/tv/<id>`) even though both share a single
    /// numeric namespace, so we branch on `VODItemType`. Episodes
    /// fall back to the show's path — there's no per-episode TMDB
    /// page, and currently the episode rows aren't surfacing the
    /// link anyway.
    private func tmdbURL(from id: String, type: VODItemType) -> URL? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pathSegment: String = {
            switch type {
            case .movie:           return "movie"
            case .series, .episode: return "tv"
            }
        }()
        return URL(string: "https://www.themoviedb.org/\(pathSegment)/\(trimmed)")
    }
    #endif

    // MARK: - Episodes
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingDetail {
                HStack { Spacer(); ProgressView().tint(.accentPrimary); Spacer() }
                    .padding(32)
            } else if let series = fullSeries, !series.seasons.isEmpty {
                // Season picker
                if series.seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(series.seasons.enumerated()), id: \.offset) { idx, season in
                                Button {
                                    withAnimation(.spring(response: 0.25)) { selectedSeason = idx }
                                } label: {
                                    Text("Season \(season.seasonNumber)")
                                        .font(.labelMedium)
                                        .foregroundColor(selectedSeason == idx ? .appBackground : .textSecondary)
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(
                                            selectedSeason == idx
                                                ? AnyView(Capsule().fill(Color.accentPrimary))
                                                : AnyView(Capsule().fill(Color.elevatedBackground))
                                        )
                                }
                                #if os(tvOS)
                                .buttonStyle(TVNoHighlightButtonStyle())
                                #else
                                .buttonStyle(.plain)
                                #endif
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Episode list
                if selectedSeason < series.seasons.count {
                    let episodes = series.seasons[selectedSeason].episodes
                    ForEach(episodes) { ep in
                        episodeRow(ep)
                    }
                }
            }
        }
        .padding(.bottom, 32)
    }

    private func episodeRow(_ ep: VODEpisode) -> some View {
        TVEpisodeRowButton(
            ep: ep,
            headers: serverHeaders(),
            progress: progressByEpisodeID[ep.id]
        ) {
            playEpisode(ep)
        }
    }

    /// Lookup from `episode.id` → `WatchProgress` for episodes of
    /// this series. Only populated for series detail pages; a movie
    /// item never returns any rows because `allEpisodeProgress` is
    /// already filtered to `vodType == "episode"` and movies don't
    /// have a matching `seriesID`.
    private var progressByEpisodeID: [String: WatchProgress] {
        guard item.type == .series else { return [:] }
        let seriesID = item.id
        var map: [String: WatchProgress] = [:]
        for wp in allEpisodeProgress where wp.seriesID == seriesID {
            map[wp.vodID] = wp
        }
        return map
    }

    // MARK: - Helpers

    private func playButton(url: URL?, title: String) -> some View {
        TVPlayButton(isResolvingURL: isResolvingURL) {
            guard let url, !isResolvingURL else { return }
            Task { await resolveAndLaunch(url: url, title: title) }
        }
    }

    private func playEpisode(_ ep: VODEpisode) {
        guard let url = ep.streamURL else { return }
        // Stash the parent series ID into WatchProgress before playback starts.
        // The Top Shelf extension uses this to build a deep link that
        // navigates back to the series detail — the episode itself doesn't
        // have a standalone detail view to return to.
        // v1.6.8 (Codex A1): pass serverID through too so resume positions
        // don't collide across servers that share an episode ID.
        WatchProgressManager.save(
            vodID: ep.id,
            title: ep.title,
            positionMs: 0,
            durationMs: 0,
            posterURL: ep.posterURL?.absoluteString,
            vodType: "episode",
            serverID: ep.serverID.uuidString,
            seriesID: ep.seriesID
        )
        Task {
            await resolveAndLaunch(
                url: url,
                title: ep.title,
                vodID: ep.id,               // episode's own unique ID
                vodType: "episode",
                posterURL: ep.posterURL?.absoluteString
            )
        }
    }

    /// Resolves any redirects in the proxy URL with auth headers before handing off to the player.
    /// Dispatcharr's /proxy/vod/* endpoints often redirect to a session-based or provider URL.
    /// The player follows redirects but can drop custom headers; resolving first avoids that.
    @MainActor
    private func resolveAndLaunch(url: URL, title: String, vodID: String? = nil,
                                  vodType: String = "movie", posterURL: String? = nil) async {
        playingTitle = title
        playingHeaders = serverHeaders()
        playingVodID = vodID ?? item.id  // default to movie id
        playingVodType = vodType
        playingPosterURL = posterURL

        var resolvedURL = url
        if let server, server.type == .dispatcharrAPI {
            isResolvingURL = true
            let api = DispatcharrAPI(baseURL: server.effectiveBaseURL, auth: .apiKey(server.effectiveApiKey))
            resolvedURL = (try? await api.resolveFinalURLForPlayback(url)) ?? url
            isResolvingURL = false
        }

        playingURL = IdentifiableURL(url: resolvedURL)
        isPlaying = true
    }

    private func serverHeaders() -> [String: String] {
        guard let server else { return [:] }
        return server.authHeaders
    }

    private func metaRow(label: String, value: String) -> some View {
        // v1.6.12 (second pass): the previous fix used
        // `.frame(maxWidth: .infinity, alignment: .leading)` on the
        // value Text, which was the layout-cascade trigger — that
        // modifier propagates "ideal width = infinity" up through the
        // HStack → VStack → infoSection chain, and SwiftUI's eventual
        // clamp lands at a position that bleeds the leading edge past
        // the safe area. Solution: drop the maxWidth-infinity hint
        // entirely and rely on `.fixedSize(horizontal: false, vertical: true)`,
        // which lets the value Text accept whatever horizontal space
        // the HStack offers (no cascade) while still allowing it to
        // grow vertically for multi-line wrapping. Long cast lists
        // wrap correctly without any width hint upstream.
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.labelSmall).foregroundColor(.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.labelSmall).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadDetail() async {
        guard let server else { return }

        switch item.type {
        case .movie:
            // Two-phase render: show the slim list-time data
            // immediately, then upgrade fields when the rich
            // `/provider-info/` payload returns. Dispatcharr's
            // provider-info endpoint is server-side throttled to
            // 24h per movie, but the FIRST call for a movie that
            // hasn't been visited yet synchronously triggers an
            // upstream Xtream fetch (`refresh_movie_advanced_data`),
            // which can take several seconds. By rendering
            // `item.movie` first we keep the initial frame instant
            // and let SwiftUI animate the new fields in when they
            // arrive. Failure (network error, non-Dispatcharr
            // server) is silent: `fetchMovieDetail` falls back to
            // returning the existing movie unchanged.
            fullMovie = item.movie
            if let existing = item.movie {
                let snap = server.snapshot
                let enriched = await VODService.fetchMovieDetail(existing: existing, from: snap)
                // Only update if the fetch actually returned something
                // richer — equality on the merged model is fine since
                // the no-op fallback returns the same value object.
                if enriched != existing {
                    fullMovie = enriched
                }
            }
        case .series:
            guard fullSeries == nil else { return }
            // v1.6.12: render the slim list-time series instantly so
            // the user sees the basics (poster, title, year, plot,
            // genre) without waiting for the network. The detail
            // fetch then enriches with cast/director/backdrop/
            // trailer/TMDB-id, mirroring the movie two-phase render.
            // This also avoids the loading spinner flashing for
            // series that already have plenty of metadata at list
            // time — the spinner only takes the screen if we have
            // nothing to show yet (no `item.series`).
            if let preview = item.series {
                fullSeries = preview
            } else {
                isLoadingDetail = true
            }
            let snap = server.snapshot
            let enriched = try? await VODService.fetchSeriesDetail(seriesID: item.id,
                                                                    from: snap,
                                                                    existing: item.series)
            if let enriched {
                fullSeries = enriched
            }
            isLoadingDetail = false
            if let idx = fullSeries?.seasons.indices.first {
                selectedSeason = idx
            }
        case .episode:
            break
        }
    }
}

// MARK: - Episode Row with tvOS Focus

/// Extracted into its own view so it can own a @FocusState for per-row focus highlighting.
private struct TVEpisodeRowButton: View {
    let ep: VODEpisode
    let headers: [String: String]
    /// Optional resume/watched state. v1.6.8: lets the row surface a
    /// "Currently Watching" / "Watched" pill badge so users arriving
    /// at a series detail page (especially from a Top Shelf
    /// deep-link after cross-device sync) can see at a glance which
    /// episode they're in the middle of without scrubbing the list.
    let progress: WatchProgress?
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AuthPosterImage(url: ep.posterURL, headers: headers)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("E\(ep.episodeNumber) · \(ep.title)")
                        .font(.bodyMedium).foregroundColor(.textPrimary)
                        .lineLimit(1)
                    if !ep.plot.isEmpty {
                        Text(ep.plot)
                            .font(.labelSmall).foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                    // Progress pill + timeline — only rendered when
                    // there's a WatchProgress row for this episode.
                    // Finished episodes get a muted "Watched" chip
                    // (no timeline — the pill itself communicates
                    // completion); in-progress episodes get the
                    // accent "Currently Watching" chip plus a thin
                    // accent-tinted progress bar + percentage so
                    // users can tell how far in they were without
                    // resuming. Sizes are platform-specific —
                    // v1.6.8 feedback bumped the tvOS font +
                    // padding 50% larger for 10-foot readability.
                    if let progress {
                        #if os(tvOS)
                        let iconSize: CGFloat = 15
                        let textSize: CGFloat = 17
                        let hPadding: CGFloat = 12
                        let vPadding: CGFloat = 5
                        let barMaxWidth: CGFloat = 360
                        let barHeight: CGFloat = 5
                        let pctTextSize: CGFloat = 15
                        #else
                        let iconSize: CGFloat = 10
                        let textSize: CGFloat = 11
                        let hPadding: CGFloat = 8
                        let vPadding: CGFloat = 3
                        let barMaxWidth: CGFloat = 240
                        let barHeight: CGFloat = 3
                        let pctTextSize: CGFloat = 10
                        #endif

                        HStack(spacing: 4) {
                            Image(systemName: progress.isFinished
                                  ? "checkmark.circle.fill"
                                  : "play.circle.fill")
                                .font(.system(size: iconSize, weight: .semibold))
                            Text(progress.isFinished ? "Watched" : "Currently Watching")
                                .font(.system(size: textSize, weight: .semibold))
                        }
                        .foregroundColor(progress.isFinished ? .textSecondary : .white)
                        .padding(.horizontal, hPadding)
                        .padding(.vertical, vPadding)
                        .background(
                            Capsule().fill(progress.isFinished
                                           ? Color.elevatedBackground
                                           : Color.accentPrimary)
                        )

                        // Linear timeline. Shown only for in-progress
                        // episodes with a usable duration — some
                        // episode rows persist with `durationMs == 0`
                        // because playback was stopped before mpv
                        // reported a duration, and rendering a 0-based
                        // percentage would lie to the user.
                        if !progress.isFinished, progress.durationMs > 0 {
                            let pct = max(0.0, min(1.0,
                                Double(progress.positionMs) / Double(progress.durationMs)))
                            HStack(spacing: 8) {
                                ProgressView(value: pct)
                                    .progressViewStyle(.linear)
                                    .tint(.accentPrimary)
                                    .frame(maxWidth: barMaxWidth)
                                    .scaleEffect(x: 1.0, y: barHeight / 3.0, anchor: .center)
                                Text("\(Int(pct * 100))%")
                                    .font(.system(size: pctTextSize, weight: .semibold))
                                    .foregroundColor(.textSecondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentPrimary.opacity(0.7))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            #if os(tvOS)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? Color.elevatedBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary : .clear, lineWidth: 2)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Play Button with tvOS Focus

/// Extracted so it can own a @FocusState for clear focus highlighting on the Play CTA.
private struct TVPlayButton: View {
    let isResolvingURL: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isResolvingURL {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(isResolvingURL ? "Loading…" : "Play")
            }
            .font(.headlineSmall)
            .foregroundColor(.white)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(LinearGradient.accentGradient)
            .clipShape(Capsule())
            #if os(tvOS)
            .overlay(
                Capsule()
                    .stroke(isFocused ? Color.white : .clear, lineWidth: 2.5)
            )
            .shadow(color: isFocused ? Color.accentPrimary.opacity(0.6) : .clear, radius: 10, y: 4)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isResolvingURL)
    }
}

// MARK: - Identifiable URL wrapper (avoids global retroactive conformance on URL)
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
