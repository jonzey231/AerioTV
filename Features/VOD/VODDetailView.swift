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
    @State private var playingURL: URL?
    @State private var playingTitle = ""
    @State private var playingHeaders: [String: String] = [:]
    @State private var isLoadingDetail = false
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .task { await loadDetail() }
        .fullScreenCover(item: $playingURL) { url in
            PlayerView(
                urls: [url],
                title: playingTitle,
                headers: playingHeaders
            )
            .onDisappear { isPlaying = false }
        }
    }

    // MARK: - Hero
    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop or poster as hero
            AsyncImage(url: (fullMovie?.backdropURL ?? fullSeries?.backdropURL) ?? item.posterURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(Color.cardBackground)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .clipped()
            .overlay(LinearGradient.heroOverlay)

            HStack(alignment: .bottom, spacing: 14) {
                // Small poster thumbnail
                AsyncImage(url: item.posterURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.cardBackground)
                            .frame(width: 80, height: 120)
                    }
                }

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
                                .buttonStyle(.plain)
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
        Button {
            if let url = ep.streamURL {
                playEpisode(url: url, title: ep.title)
            }
        } label: {
            HStack(spacing: 14) {
                // Thumbnail
                AsyncImage(url: ep.posterURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.cardBackground)
                            .frame(width: 96, height: 54)
                            .overlay(Image(systemName: "play.tv.fill").foregroundColor(.textTertiary))
                    }
                }

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
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func playButton(url: URL?, title: String) -> some View {
        Button {
            guard let url else { return }
            playingURL = url
            playingTitle = title
            playingHeaders = serverHeaders()
            isPlaying = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text("Play")
            }
            .font(.headlineSmall)
            .foregroundColor(.white)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(LinearGradient.accentGradient)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func playEpisode(url: URL, title: String) {
        playingURL = url
        playingTitle = title
        playingHeaders = serverHeaders()
        isPlaying = true
    }

    private func serverHeaders() -> [String: String] {
        guard let server else { return [:] }
        if server.type == .dispatcharrAPI {
            let key = server.apiKey
            return ["Authorization": "ApiKey \(key)", "X-API-Key": key, "Accept": "*/*"]
        }
        return ["Accept": "*/*"]
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
            nonisolated(unsafe) let serverRef = server
            fullSeries = try? await VODService.fetchSeriesDetail(seriesID: item.id, from: serverRef)
            if let idx = fullSeries?.seasons.indices.first {
                selectedSeason = idx
            }
        case .episode:
            break
        }
    }
}

// MARK: - URL Identifiable wrapper
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
