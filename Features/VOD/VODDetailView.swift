import SwiftUI
import SwiftData

// MARK: - VOD Detail View (Movie or Series)
struct VODDetailView: View {
    let item: VODDisplayItem
    @Query private var servers: [ServerConnection]
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
                VStack(alignment: .leading, spacing: 0) {
                    heroSection
                    infoSection
                    if item.type == .series {
                        episodeSection
                    }
                }
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
            // Backdrop or poster as hero
            let heroURL = (fullMovie?.backdropURL ?? fullSeries?.backdropURL) ?? item.posterURL
            AuthPosterImage(url: heroURL, headers: serverHeaders())
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .clipped()
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
                        if !item.releaseYear.isEmpty {
                            Text(item.releaseYear)
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
            }

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
        }
        .padding(16)
    }

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
        TVEpisodeRowButton(ep: ep, headers: serverHeaders()) {
            playEpisode(ep)
        }
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
        WatchProgressManager.save(
            vodID: ep.id,
            title: ep.title,
            positionMs: 0,
            durationMs: 0,
            posterURL: ep.posterURL?.absoluteString,
            vodType: "episode",
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
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.labelSmall).foregroundColor(.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.labelSmall).foregroundColor(.textSecondary)
                .lineLimit(2)
        }
    }

    private func loadDetail() async {
        guard let server else { return }

        switch item.type {
        case .movie:
            fullMovie = item.movie
        case .series:
            guard fullSeries == nil else { return }
            isLoadingDetail = true
            defer { isLoadingDetail = false }
            let snap = server.snapshot
            fullSeries = try? await VODService.fetchSeriesDetail(seriesID: item.id, from: snap)
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
