import Foundation
import SwiftUI
import SwiftData

// MARK: - Watch Progress (VOD resume tracking)

@Model
final class WatchProgress {
    /// VOD identifier (movie / episode ID). v1.6.8 (Codex A1):
    /// dropped the `@Attribute(.unique)` constraint so the same
    /// `vodID` can coexist for different `serverID`s — two
    /// Dispatcharr servers will routinely use overlapping numeric
    /// IDs for unrelated content, and the prior global-uniqueness
    /// constraint was silently overwriting one server's resume
    /// progress whenever the other server happened to use the
    /// same ID. Uniqueness is now enforced in code by
    /// `WatchProgressManager` via `(vodID, serverID)` lookups.
    /// Removing the constraint is a SwiftData lightweight migration
    /// — existing data is preserved, the underlying SQLite index
    /// is just relaxed.
    var vodID: String
    var title: String
    var positionMs: Int32
    var durationMs: Int32
    var posterURL: String?
    var vodType: String          // "movie" or "episode"
    var updatedAt: Date
    var isFinished: Bool
    var streamURL: String?       // Resolved stream URL for resume playback
    var serverID: String?        // Server UUID for auth headers
    /// Parent series ID for episode-type progress entries. nil for movies.
    /// Used by the Top Shelf extension to build a `aerio://vod/series/<id>`
    /// deep link that navigates to the series detail (not the episode,
    /// which has no standalone detail view of its own).
    var seriesID: String?

    init(vodID: String, title: String, positionMs: Int32 = 0, durationMs: Int32 = 0,
         posterURL: String? = nil, vodType: String = "movie", updatedAt: Date = Date(),
         isFinished: Bool = false, streamURL: String? = nil, serverID: String? = nil,
         seriesID: String? = nil) {
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
        self.seriesID = seriesID
    }
}

// MARK: - Watch Progress Manager

@MainActor
enum WatchProgressManager {
    /// Shared model context — set by the app on launch from the SwiftUI model container.
    static var modelContext: ModelContext?

    /// Save or update watch progress. Call from main thread.
    ///
    /// Merge semantics: optional fields (posterURL, streamURL, serverID,
    /// seriesID) only overwrite existing values when they are non-nil, so
    /// periodic save calls from the player don't stomp on the seriesID
    /// that was set once from the detail view when playback started.
    ///
    /// v1.6.8 (Codex A1): uniqueness is now enforced in code by the
    /// `(vodID, serverID)` lookup below rather than the SwiftData
    /// `@Attribute(.unique)` constraint. Two servers can have
    /// independent resume positions for the same `vodID`. Legacy
    /// rows from before A1 (no `serverID` populated) are adopted by
    /// the first save that supplies a `serverID` — the same row gets
    /// its `serverID` field set rather than a duplicate being
    /// inserted.
    static func save(vodID: String, title: String, positionMs: Int32, durationMs: Int32,
                     posterURL: String? = nil, vodType: String = "movie", isFinished: Bool = false,
                     streamURL: String? = nil, serverID: String? = nil,
                     seriesID: String? = nil) {
        guard let context = modelContext else { return }
        let matches = matchingProgress(context: context, vodID: vodID)
        let existing = pickMatch(matches, serverID: serverID, claimLegacy: true)

        if let existing {
            existing.positionMs = positionMs
            existing.durationMs = durationMs
            existing.updatedAt = Date()
            existing.isFinished = isFinished
            if let poster = posterURL { existing.posterURL = poster }
            if let url = streamURL { existing.streamURL = url }
            if let sid = serverID { existing.serverID = sid }
            if let ser = seriesID { existing.seriesID = ser }
        } else {
            let progress = WatchProgress(vodID: vodID, title: title, positionMs: positionMs,
                                         durationMs: durationMs, posterURL: posterURL,
                                         vodType: vodType, isFinished: isFinished,
                                         streamURL: streamURL, serverID: serverID,
                                         seriesID: seriesID)
            context.insert(progress)
        }
        try? context.save()
        NotificationCenter.default.post(name: .watchProgressDidChange, object: nil)
    }

    /// Get saved position for a VOD item. Returns nil if no progress or already finished.
    ///
    /// v1.6.8 (Codex A1): pass `serverID` so cross-server collisions
    /// resolve to the right progress entry. Calls without a
    /// `serverID` fall back to the first matching `vodID` row, which
    /// covers legacy code paths and pre-A1 rows where `serverID` was
    /// never populated.
    static func getResumePosition(vodID: String, serverID: String? = nil) -> Int32? {
        guard let context = modelContext else { return nil }
        let matches = matchingProgress(context: context, vodID: vodID)
        guard let progress = pickMatch(matches, serverID: serverID, claimLegacy: false),
              !progress.isFinished, progress.positionMs > 0 else { return nil }
        return progress.positionMs
    }

    /// Delete a specific watch progress entry.
    ///
    /// v1.6.8 (Codex A1): pass `serverID` to delete only that
    /// server's row. Without `serverID`, every `vodID`-matching row
    /// is removed (legacy behaviour preserved for callers that
    /// haven't been updated). When `serverID` is supplied the
    /// matching row plus any pre-A1 legacy nil-`serverID` row are
    /// removed together so old rows don't linger after the user
    /// clears progress on the same item.
    static func delete(vodID: String, serverID: String? = nil) {
        guard let context = modelContext else { return }
        let matches = matchingProgress(context: context, vodID: vodID)
        let toDelete: [WatchProgress] = {
            if let serverID {
                return matches.filter { $0.serverID == serverID || $0.serverID == nil }
            }
            return matches
        }()
        guard !toDelete.isEmpty else { return }
        for row in toDelete { context.delete(row) }
        try? context.save()
        NotificationCenter.default.post(name: .watchProgressDidChange, object: nil)
    }

    // MARK: - Private helpers

    /// Fetch every `WatchProgress` row matching `vodID`. With the
    /// post-A1 schema this can return more than one row (one per
    /// server). `pickMatch` narrows to the right one.
    private static func matchingProgress(context: ModelContext, vodID: String) -> [WatchProgress] {
        let descriptor = FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.vodID == vodID })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Resolve the right row out of a `vodID`-matching set using
    /// `serverID`. Preference order:
    ///   1. Exact `serverID` match.
    ///   2. Legacy nil-`serverID` row (pre-A1 data) — when
    ///      `claimLegacy` is true the caller is responsible for
    ///      setting the row's `serverID` so it stops being legacy
    ///      on subsequent reads.
    ///   3. When the caller passed no `serverID`, fall back to the
    ///      first row regardless of its `serverID` (legacy callers).
    private static func pickMatch(_ rows: [WatchProgress],
                                  serverID: String?,
                                  claimLegacy: Bool) -> WatchProgress? {
        guard let serverID else { return rows.first }
        if let exact = rows.first(where: { $0.serverID == serverID }) { return exact }
        if claimLegacy, let legacy = rows.first(where: { $0.serverID == nil }) {
            return legacy
        }
        return nil
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
                                    // v1.6.8 (Codex A1): pass serverID so we
                                    // delete only this server's row when the
                                    // user has progress on the same vodID
                                    // from another playlist.
                                    WatchProgressManager.delete(
                                        vodID: progress.vodID,
                                        serverID: progress.serverID
                                    )
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

    // v1.6.12: optional metadata used by VODDetailView's external
    // links + a Country meta row. All default empty so existing
    // initializers don't need updating; populated by the Dispatcharr
    // provider-info path in `VODService`.
    var tmdbID: String = ""
    var youtubeTrailer: String = ""
    var country: String = ""

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

    // v1.6.12: same TMDB-derived metadata vocabulary as VODMovie —
    // tmdbID drives the "View on TMDB" deep-link, youtubeTrailer
    // drives the trailer button, country shows up in the meta row.
    // Default empty so existing initializers don't need updating;
    // populated by `dispatcharrSeries(...)` (list time) and
    // `dispatcharrSeriesDetail(...)` (provider-info enrichment).
    var tmdbID: String = ""
    var youtubeTrailer: String = ""
    var country: String = ""

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
