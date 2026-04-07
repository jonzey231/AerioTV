import Foundation
import SwiftUI
import SwiftData

// MARK: - Watch Progress (VOD resume tracking)

@Model
final class WatchProgress {
    @Attribute(.unique) var vodID: String
    var title: String
    var positionMs: Int32
    var durationMs: Int32
    var posterURL: String?
    var vodType: String          // "movie" or "episode"
    var updatedAt: Date
    var isFinished: Bool
    var streamURL: String?       // Resolved stream URL for resume playback
    var serverID: String?        // Server UUID for auth headers

    init(vodID: String, title: String, positionMs: Int32 = 0, durationMs: Int32 = 0,
         posterURL: String? = nil, vodType: String = "movie", updatedAt: Date = Date(),
         isFinished: Bool = false, streamURL: String? = nil, serverID: String? = nil) {
        self.vodID = vodID
        self.title = title
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.posterURL = posterURL
        self.vodType = vodType
        self.updatedAt = updatedAt
        self.isFinished = isFinished
        self.streamURL = streamURL
        self.serverID = serverID
    }
}

// MARK: - Watch Progress Manager

@MainActor
enum WatchProgressManager {
    /// Shared model context — set by the app on launch from the SwiftUI model container.
    static var modelContext: ModelContext?

    /// Save or update watch progress. Call from main thread.
    static func save(vodID: String, title: String, positionMs: Int32, durationMs: Int32,
                     posterURL: String? = nil, vodType: String = "movie", isFinished: Bool = false,
                     streamURL: String? = nil, serverID: String? = nil) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.vodID == vodID })
        if let existing = try? context.fetch(descriptor).first {
            existing.positionMs = positionMs
            existing.durationMs = durationMs
            existing.updatedAt = Date()
            existing.isFinished = isFinished
            if let poster = posterURL { existing.posterURL = poster }
            if let url = streamURL { existing.streamURL = url }
            if let sid = serverID { existing.serverID = sid }
        } else {
            let progress = WatchProgress(vodID: vodID, title: title, positionMs: positionMs,
                                         durationMs: durationMs, posterURL: posterURL,
                                         vodType: vodType, isFinished: isFinished,
                                         streamURL: streamURL, serverID: serverID)
            context.insert(progress)
        }
        try? context.save()
        NotificationCenter.default.post(name: .watchProgressDidChange, object: nil)
    }

    /// Get saved position for a VOD item. Returns nil if no progress or already finished.
    static func getResumePosition(vodID: String) -> Int32? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.vodID == vodID })
        guard let progress = try? context.fetch(descriptor).first,
              !progress.isFinished, progress.positionMs > 0 else { return nil }
        return progress.positionMs
    }

    /// Delete a specific watch progress entry.
    static func delete(vodID: String) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.vodID == vodID })
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
            try? context.save()
            NotificationCenter.default.post(name: .watchProgressDidChange, object: nil)
        }
    }
}

// MARK: - Continue Watching Section (SwiftUI)

struct ContinueWatchingSection: View {
    let vodType: String   // "movie" or "episode"
    var headers: [String: String] = [:]
    var onPlay: ((WatchProgress) -> Void)?

    @Query(
        filter: #Predicate<WatchProgress> { !$0.isFinished },
        sort: \WatchProgress.updatedAt, order: .reverse
    ) private var allProgress: [WatchProgress]

    private var items: [WatchProgress] {
        allProgress.filter { $0.vodType == vodType }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: {
                #if os(tvOS)
                return CGFloat(20)
                #else
                return CGFloat(8)
                #endif
            }()) {
                Text("Continue Watching")
                    .font(.headline)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 16)
                    .zIndex(0)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: {
                        #if os(tvOS)
                        return CGFloat(24)
                        #else
                        return CGFloat(12)
                        #endif
                    }()) {
                        ForEach(items) { progress in
                            Button {
                                onPlay?(progress)
                            } label: {
                                ContinueWatchingCard(progress: progress, headers: headers)
                            }
                            #if os(tvOS)
                            .buttonStyle(TVCardButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .contextMenu {
                                Button(role: .destructive) {
                                    WatchProgressManager.delete(vodID: progress.vodID)
                                } label: {
                                    Label("Remove from Continue Watching", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    #if os(tvOS)
                    .padding(.vertical, 20)
                    #endif
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

}

// MARK: - Continue Watching Card (extracted for tvOS @Environment(\.isFocused) support)

private struct ContinueWatchingCard: View {
    let progress: WatchProgress
    var headers: [String: String] = [:]

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    private let cardWidth: CGFloat = 200
    private let cardHeight: CGFloat = 300
    #else
    private let cardWidth: CGFloat = 120
    private let cardHeight: CGFloat = 180
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                // Poster
                if let urlStr = progress.posterURL, let url = URL(string: urlStr) {
                    AuthPosterImage(url: url, headers: headers)
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(width: cardWidth, height: cardHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.cardBackground)
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay {
                            Image(systemName: "film")
                                .font(.title2)
                                .foregroundColor(.textTertiary)
                        }
                }

                // Progress bar
                GeometryReader { geo in
                    let fraction = progress.durationMs > 0
                        ? CGFloat(progress.positionMs) / CGFloat(progress.durationMs)
                        : 0
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentPrimary)
                                .frame(width: geo.size.width * min(fraction, 1.0), height: 3)
                        }
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            #if os(tvOS)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary : .clear, lineWidth: 2.5)
            )
            #endif

            Text(progress.title)
                .font(.caption)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)
        }
    }
}

// MARK: - VOD Item Type
enum VODItemType {
    case movie
    case series
    case episode
}

// MARK: - VOD Movie (display model — not persisted, fetched on demand)
struct VODMovie: Identifiable, Hashable {
    let id: String
    let name: String
    let posterURL: URL?
    let backdropURL: URL?
    let rating: String
    let plot: String
    let genre: String
    let releaseDate: String
    let duration: String
    let cast: String
    let director: String
    let imdbID: String
    let categoryID: String
    let categoryName: String
    let streamURL: URL?
    let containerExtension: String
    let serverID: UUID

    // Computed
    var displayRating: String {
        guard !rating.isEmpty, let r = Double(rating), r > 0 else { return "" }
        return String(format: "%.1f", r)
    }

    var releaseYear: String {
        guard !releaseDate.isEmpty else { return "" }
        return String(releaseDate.prefix(4))
    }
}

// MARK: - VOD Series (display model)
struct VODSeries: Identifiable, Hashable {
    let id: String
    let name: String
    let posterURL: URL?
    let backdropURL: URL?
    let rating: String
    let plot: String
    let genre: String
    let releaseDate: String
    let cast: String
    let director: String
    let categoryID: String
    let categoryName: String
    let serverID: UUID
    var seasons: [VODSeason]
    let episodeCount: Int

    var displayRating: String {
        guard !rating.isEmpty, let r = Double(rating), r > 0 else { return "" }
        return String(format: "%.1f", r)
    }

    var releaseYear: String {
        guard !releaseDate.isEmpty else { return "" }
        return String(releaseDate.prefix(4))
    }
}

// MARK: - VOD Season
struct VODSeason: Identifiable, Hashable {
    let id: String
    let seasonNumber: Int
    var episodes: [VODEpisode]
}

// MARK: - VOD Episode
struct VODEpisode: Identifiable, Hashable {
    let id: String
    let seriesID: String
    let title: String
    let seasonNumber: Int
    let episodeNumber: Int
    let plot: String
    let duration: String
    let posterURL: URL?
    let streamURL: URL?
    let containerExtension: String
    let serverID: UUID
}

// MARK: - VOD Category
struct VODCategory: Identifiable, Hashable {
    let id: String
    let name: String
    var itemCount: Int = 0
}

// MARK: - VOD Display Item (unified for search/grid)
struct VODDisplayItem: Identifiable, Hashable {
    let id: String
    let name: String
    let posterURL: URL?
    let rating: String
    let releaseYear: String
    let type: VODItemType
    let serverID: UUID
    // Carry the full model for detail navigation
    let movie: VODMovie?
    let series: VODSeries?

    init(movie: VODMovie) {
        self.id = movie.id
        self.name = movie.name
        self.posterURL = movie.posterURL
        self.rating = movie.displayRating
        self.releaseYear = movie.releaseYear
        self.type = .movie
        self.serverID = movie.serverID
        self.movie = movie
        self.series = nil
    }

    init(series: VODSeries) {
        self.id = series.id
        self.name = series.name
        self.posterURL = series.posterURL
        self.rating = series.displayRating
        self.releaseYear = series.releaseYear
        self.type = .series
        self.serverID = series.serverID
        self.movie = nil
        self.series = series
    }
}
