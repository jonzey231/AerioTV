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
    /// v1.7.3 (Issue #19): season + episode number for episode entries
    /// (0 for movies). Identifies the episode within its series.
    var seasonNumber: Int = 0
    var episodeNumber: Int = 0
    /// v1.7.3 (Issue #19): JSON `[UpNextEntry]` of the episodes that
    /// follow this one, captured from the loaded series at play time.
    /// When this episode finishes, the head is promoted into its own
    /// `WatchProgress` so Continue Watching advances to the next episode,
    /// and the remainder rides forward so a binge self-sustains without
    /// re-fetching the series. Local-only (deliberately not iCloud-synced).
    var upNextQueue: String?

    init(vodID: String, title: String, positionMs: Int32 = 0, durationMs: Int32 = 0,
         posterURL: String? = nil, vodType: String = "movie", updatedAt: Date = Date(),
         isFinished: Bool = false, streamURL: String? = nil, serverID: String? = nil,
         seriesID: String? = nil, seasonNumber: Int = 0, episodeNumber: Int = 0) {
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
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }
}

// MARK: - Up Next Queue Entry (Issue #19)

/// Lightweight Codable snapshot of an upcoming episode, stored as a
/// JSON array in `WatchProgress.upNextQueue`. Captured from the loaded
/// series when an episode starts playing so Continue Watching can
/// advance to the next episode on finish without a fresh series fetch.
struct UpNextEntry: Codable {
    let vodID: String
    let title: String
    let posterURL: String?
    let streamURL: String?
    let seasonNumber: Int
    let episodeNumber: Int
}

// MARK: - Watch Progress Manager

// MARK: - Watchlist

/// A title the user saved for later (Movies tab redesign, 2026-09-04).
/// One row per (vodID, serverID); uniqueness enforced in code by
/// `WatchlistManager`, same as WatchProgress.
@Model
final class WatchlistEntry {
    var vodID: String
    var title: String
    var posterURL: String?
    var vodType: String          // "movie" or "series"
    var serverID: String?
    var releaseYear: String
    var rating: String
    var addedAt: Date

    init(vodID: String, title: String, posterURL: String? = nil, vodType: String = "movie",
         serverID: String? = nil, releaseYear: String = "", rating: String = "", addedAt: Date = Date()) {
        self.vodID = vodID
        self.title = title
        self.posterURL = posterURL
        self.vodType = vodType
        self.serverID = serverID
        self.releaseYear = releaseYear
        self.rating = rating
        self.addedAt = addedAt
    }
}

@MainActor
enum WatchlistManager {
    /// Shared model context, set alongside WatchProgressManager's.
    static var modelContext: ModelContext?

    static func entry(vodID: String, serverID: String?) -> WatchlistEntry? {
        guard let context = modelContext else { return nil }
        let id = vodID
        let descriptor = FetchDescriptor<WatchlistEntry>(predicate: #Predicate { $0.vodID == id })
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.first { $0.serverID == serverID } ?? rows.first { $0.serverID == nil }
    }

    static func contains(_ item: VODDisplayItem) -> Bool {
        entry(vodID: item.id, serverID: item.serverID.uuidString) != nil
    }

    static func add(_ item: VODDisplayItem) {
        guard let context = modelContext,
              entry(vodID: item.id, serverID: item.serverID.uuidString) == nil else { return }
        context.insert(WatchlistEntry(
            vodID: item.id, title: item.name, posterURL: item.posterURL?.absoluteString,
            vodType: item.type == .series ? "series" : "movie",
            serverID: item.serverID.uuidString, releaseYear: item.releaseYear, rating: item.rating))
        try? context.save()
    }

    static func remove(vodID: String, serverID: String?) {
        guard let context = modelContext, let row = entry(vodID: vodID, serverID: serverID) else { return }
        context.delete(row)
        try? context.save()
    }

    static func toggle(_ item: VODDisplayItem) {
        if contains(item) {
            remove(vodID: item.id, serverID: item.serverID.uuidString)
        } else {
            add(item)
        }
    }
}

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
                     seriesID: String? = nil,
                     seasonNumber: Int? = nil, episodeNumber: Int? = nil,
                     upNextQueue: String? = nil) {
        guard let context = modelContext else { return }
        let matches = matchingProgress(context: context, vodID: vodID)
        let existing = pickMatch(matches, serverID: serverID, claimLegacy: true)

        if let existing {
            let wasFinished = existing.isFinished
            existing.positionMs = positionMs
            existing.durationMs = durationMs
            existing.updatedAt = Date()
            existing.isFinished = isFinished
            if let poster = posterURL { existing.posterURL = poster }
            if let url = streamURL { existing.streamURL = url }
            if let sid = serverID { existing.serverID = sid }
            if let ser = seriesID { existing.seriesID = ser }
            if let s = seasonNumber { existing.seasonNumber = s }
            if let e = episodeNumber { existing.episodeNumber = e }
            if let q = upNextQueue { existing.upNextQueue = q }
            // v1.7.3 (Issue #19): when an episode first crosses into
            // "finished", promote the next item in its up-next queue so
            // the series stays in Continue Watching pointing at the next
            // episode instead of disappearing.
            if !wasFinished, isFinished, existing.vodType == "episode" {
                advanceUpNext(from: existing, context: context)
            }
        } else {
            let progress = WatchProgress(vodID: vodID, title: title, positionMs: positionMs,
                                         durationMs: durationMs, posterURL: posterURL,
                                         vodType: vodType, isFinished: isFinished,
                                         streamURL: streamURL, serverID: serverID,
                                         seriesID: seriesID,
                                         seasonNumber: seasonNumber ?? 0,
                                         episodeNumber: episodeNumber ?? 0)
            progress.upNextQueue = upNextQueue
            context.insert(progress)
            if isFinished, vodType == "episode" {
                advanceUpNext(from: progress, context: context)
            }
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

    /// GH #75: saved position + duration + finished flag for a row, or
    /// nil when nothing was ever saved. Unlike `getResumePosition` this
    /// also reports finished rows so a list can render "Watched".
    struct Snapshot {
        let positionMs: Int32
        let durationMs: Int32
        let isFinished: Bool
        /// 0...1 fraction watched; nil when the duration is unknown.
        var fraction: Double? {
            guard durationMs > 0 else { return nil }
            return min(1, max(0, Double(positionMs) / Double(durationMs)))
        }
    }

    static func snapshot(vodID: String, serverID: String? = nil) -> Snapshot? {
        guard let context = modelContext else { return nil }
        let matches = matchingProgress(context: context, vodID: vodID)
        guard let progress = pickMatch(matches, serverID: serverID, claimLegacy: false) else { return nil }
        return Snapshot(positionMs: progress.positionMs, durationMs: progress.durationMs,
                        isFinished: progress.isFinished)
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

    // MARK: - Up Next (Issue #19)

    /// Promote the next unwatched episode from a just-finished episode's
    /// `upNextQueue` into its own `WatchProgress`, carrying the remaining
    /// queue forward so a binge keeps surfacing the next episode in
    /// Continue Watching without re-opening the series. Skips entries
    /// already finished (out-of-order viewing). No-op at the end of the
    /// queue, so the series then drops off Continue Watching as before.
    /// The caller saves the context.
    private static func advanceUpNext(from finished: WatchProgress, context: ModelContext) {
        guard let json = finished.upNextQueue,
              let data = json.data(using: .utf8),
              var queue = try? JSONDecoder().decode([UpNextEntry].self, from: data),
              !queue.isEmpty else { return }
        let serverID = finished.serverID
        let seriesID = finished.seriesID
        while !queue.isEmpty {
            let head = queue.removeFirst()
            let rows = matchingProgress(context: context, vodID: head.vodID)
                .filter { serverID == nil || $0.serverID == serverID || $0.serverID == nil }
            if let row = rows.first {
                // Already watched out of order: skip to the next entry.
                if row.isFinished { continue }
                // Already started or seeded: just refresh its forward queue.
                row.upNextQueue = encodeQueue(queue)
                return
            }
            let seeded = WatchProgress(
                vodID: head.vodID, title: head.title, positionMs: 0, durationMs: 0,
                posterURL: head.posterURL, vodType: "episode", isFinished: false,
                streamURL: head.streamURL, serverID: serverID, seriesID: seriesID,
                seasonNumber: head.seasonNumber, episodeNumber: head.episodeNumber)
            seeded.upNextQueue = encodeQueue(queue)
            context.insert(seeded)
            return
        }
    }

    private static func encodeQueue(_ queue: [UpNextEntry]) -> String? {
        guard !queue.isEmpty,
              let data = try? JSONEncoder().encode(queue) else { return nil }
        return String(data: data, encoding: .utf8)
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
    /// Active playlist scope (Logan 2026-08-12: everything media related is
    /// per playlist). Without it the row surfaced watch progress from EVERY
    /// playlist, and resuming an inactive playlist's item played THAT
    /// server's stream URL from under the active one. Rows with a nil
    /// serverID predate per-server progress and stay visible everywhere
    /// rather than vanishing after an update.
    var activeServerID: String? = nil
    var headers: [String: String] = [:]
    var onPlay: ((WatchProgress) -> Void)?
    /// Loaded series for the active server, used to resolve an episode's
    /// parent show artwork + title for the card. The stored progress row
    /// only carries the episode's own still + title, so the show poster
    /// and name come from here (looked up by `seriesID`).
    var series: [VODDisplayItem] = []
    /// Optional "View Series" action for episode cards. When provided,
    /// long-pressing an episode card offers View Series, which navigates
    /// to that show's detail page (all seasons and episodes), the same
    /// destination as selecting the series from the main grid. Movies and
    /// not-yet-loaded series do not surface the option.
    var onOpenSeries: ((VODDisplayItem) -> Void)?
    /// Loaded movies for the active server; drives the movie cards'
    /// long-press "View Movie" action (Logan 2026-08-26: jumping to the
    /// full detail page used to require finding the grid listing by
    /// search/scroll). Same lookup-by-id pattern as `series`.
    var movies: [VODDisplayItem] = []
    var onOpenMovie: ((VODDisplayItem) -> Void)?

    @Query(
        filter: #Predicate<WatchProgress> { !$0.isFinished },
        sort: \WatchProgress.updatedAt, order: .reverse
    ) private var allProgress: [WatchProgress]

    private var items: [WatchProgress] {
        allProgress.filter { progress in
            guard progress.vodType == vodType else { return false }
            guard let activeServerID else { return true }
            return progress.serverID == nil || progress.serverID == activeServerID
        }
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
                    .font(.headlineSmall)
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
                            let display = resolveDisplay(progress)
                            let fraction = progress.durationMs > 0
                                ? Double(progress.positionMs) / Double(progress.durationMs)
                                : 0
                            // Parent show for an episode card (nil for a
                            // movie, or until the series list has loaded).
                            // Drives the long-press "Open Series" action.
                            let parentSeries: VODDisplayItem? = progress.vodType == "episode"
                                ? series.first(where: { $0.id == progress.seriesID })
                                : nil
                            Button {
                                onPlay?(progress)
                            } label: {
                                ContinueWatchingCard(
                                    posterURLString: display.poster,
                                    title: display.title,
                                    subtitle: display.subtitle,
                                    fraction: fraction,
                                    headers: headers
                                )
                            }
                            #if os(tvOS)
                            .buttonStyle(TVCardButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .contextMenu {
                                // Episodes with a loaded parent series get a
                                // View Series action that jumps to the full
                                // show page, same as picking it from the grid.
                                if let parentSeries, let onOpenSeries {
                                    Button {
                                        onOpenSeries(parentSeries)
                                    } label: {
                                        Label("View Series", systemImage: "rectangle.stack")
                                    }
                                }
                                // Movies get the mirror: View Movie jumps to
                                // the detail page without hunting the grid.
                                // Catalog row preferred (full metadata);
                                // otherwise a minimal item synthesized from
                                // the progress row - the detail page loads
                                // providers/versions by numeric id anyway,
                                // so the option never depends on catalog
                                // load timing.
                                if progress.vodType == "movie", let onOpenMovie {
                                    let target = movies.first(where: { $0.id == progress.vodID })
                                        ?? Self.syntheticMovieItem(from: progress)
                                    let _ = debugLog("[CW-MENU] vodID=\(progress.vodID) moviesLoaded=\(movies.count) catalogMatch=\(movies.contains(where: { $0.id == progress.vodID })) synthesized=\(target != nil && !movies.contains(where: { $0.id == progress.vodID }))")
                                    if let target {
                                        Button {
                                            onOpenMovie(target)
                                        } label: {
                                            Label("View Movie", systemImage: "info.circle")
                                        }
                                    }
                                }
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
            #if os(tvOS)
            // Make the whole rail one focus section so D-pad Down from
            // the pills/header above lands on the first card here, rather
            // than skipping to a grid poster sitting directly below it.
            // tvOS focus weighs horizontal alignment heavily, so the
            // leftmost card would otherwise be passed over.
            .focusSection()
            #endif
        }
    }

    /// Minimal display item for a movie whose catalog row hasn't loaded
    /// (or whose id space drifted): enough for VODDetailView to render
    /// and to fetch providers/versions by the numeric id. Requires a
    /// serverID on the row - without one the detail page could not auth.
    private static func syntheticMovieItem(from p: WatchProgress) -> VODDisplayItem? {
        guard let sid = p.serverID, let serverUUID = UUID(uuidString: sid) else { return nil }
        let movie = VODMovie(
            id: p.vodID, name: p.title,
            posterURL: p.posterURL.flatMap { URL(string: $0) }, backdropURL: nil,
            rating: "", plot: "", genre: "", releaseDate: "", duration: "",
            cast: "", director: "", imdbID: "", categoryID: "", categoryName: "",
            streamURL: p.streamURL.flatMap { URL(string: $0) },
            containerExtension: "", serverID: serverUUID)
        return VODDisplayItem(movie: movie)
    }

    /// Resolve the card's artwork, title, and subtitle. For an episode we
    /// look up the parent series (by `seriesID`) so the card shows the
    /// show's poster + name with an "S1:E4 - Episode Title" subtitle,
    /// instead of the episode's own still + title. Movies render as-is.
    private func resolveDisplay(_ p: WatchProgress) -> (poster: String?, title: String, subtitle: String?) {
        // Landscape cards (2026-09): prefer the title's backdrop from the
        // loaded catalog; the progress row only stores the poster.
        if p.vodType == "episode" {
            let show = series.first { $0.id == p.seriesID }
            let poster = show?.series?.backdropURL?.absoluteString
                ?? show?.posterURL?.absoluteString ?? p.posterURL
            let label = episodeLabel(season: p.seasonNumber, episode: p.episodeNumber)
            if let show {
                let parts = [label, p.title].filter { !$0.isEmpty }
                return (poster, show.name, parts.isEmpty ? nil : parts.joined(separator: " - "))
            }
            // Series not loaded yet: keep the episode title up top, SxEy below.
            return (poster, p.title, label.isEmpty ? nil : label)
        }
        let backdrop = movies.first { $0.id == p.vodID }?.movie?.backdropURL?.absoluteString
        return (backdrop ?? p.posterURL, p.title, nil)
    }

    /// "S1:E4", or "E4" when the season is unknown, or "" when neither is set.
    private func episodeLabel(season: Int, episode: Int) -> String {
        if season > 0 && episode > 0 { return "S\(season):E\(episode)" }
        if episode > 0 { return "E\(episode)" }
        return ""
    }
}

// MARK: - Continue Watching Card (extracted for tvOS @Environment(\.isFocused) support)

private struct ContinueWatchingCard: View {
    let posterURLString: String?
    let title: String
    let subtitle: String?
    let fraction: Double
    var headers: [String: String] = [:]

    // Landscape 16:9 cards (Logan 2026-09-03): backdrop art with the
    // progress bar along the bottom edge, title and subtitle beneath.
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    private let cardWidth: CGFloat = 340
    private let cardHeight: CGFloat = 191
    #else
    private let cardWidth: CGFloat = 200
    private let cardHeight: CGFloat = 112
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottom) {
                // Poster (series poster for episodes, movie poster for movies)
                if let urlStr = posterURLString, let url = URL(string: urlStr) {
                    AuthPosterImage(url: url, headers: headers)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cardWidth, height: cardHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(height: barHeight)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentPrimary)
                                .frame(width: geo.size.width * CGFloat(min(fraction, 1.0)), height: barHeight)
                        }
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            #if os(tvOS)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary : .clear, lineWidth: 2.5)
            )
            #endif

            // Title line: series name for episodes, movie title for movies.
            Text(title)
                .font(titleFont)
                .foregroundColor(titleColor)
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)

            // Subtitle line: "S1:E4 - Episode Title" for episodes.
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(subtitleFont)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
    }

    #if os(tvOS)
    private var titleFont: Font { .labelSmall }
    private var subtitleFont: Font { .system(size: 16, weight: .medium) }
    private var titleColor: Color { isFocused ? .white : .textPrimary }
    private let barHeight: CGFloat = 5
    #else
    private var titleFont: Font { .system(size: 13, weight: .semibold) }
    private var subtitleFont: Font { .system(size: 11) }
    private var titleColor: Color { .textPrimary }
    private let barHeight: CGFloat = 3
    #endif
}

// MARK: - VOD Item Type
enum VODItemType {
    case movie
    case series
    case episode
}

// MARK: - VOD stream descriptor formatting (v1.8.17)

/// Shared formatting for MEASURED stream properties, so a copy described by
/// the server and one measured during playback read identically.
enum VODStreamFormatting {
    /// Resolution bucket from the real frame size. An upscaled file sold as
    /// "4K" that is actually 1920 wide reads as 1080p here, which is the
    /// entire point of preferring measurements over provider titles.
    static func resolutionLabel(width: Int?, height: Int?) -> String? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        switch max(w, h) {
        case 3200...: return "4K"
        case 2400..<3200: return "1440p"
        case 1800..<2400: return "1080p"
        case 1200..<1800: return "720p"
        case 900..<1200: return "576p"
        default: return "480p"
        }
    }

    /// Codec strings arrive in wildly different forms depending on the
    /// source: a bare ffprobe name from the server ("hevc"), or mpv's full
    /// human description ("h265 / hevc (High Efficiency Video Coding)").
    /// Scan for a known codec anywhere in the string rather than matching the
    /// whole thing, so the picker always shows a short tag instead of a
    /// sentence that pushes the rest of the row off screen.
    private static func normalize(_ raw: String, _ table: [(String, String)]) -> String {
        let hay = raw.lowercased()
        for (needle, label) in table where hay.contains(needle) { return label }
        // Unknown codec: keep the leading token only, never the description.
        let head = hay.split(whereSeparator: { " /(,".contains($0) }).first.map(String.init) ?? hay
        return head.uppercased()
    }

    static func videoCodecLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return normalize(raw, [
            ("hevc", "HEVC"), ("h265", "HEVC"), ("h.265", "HEVC"),
            ("x265", "HEVC"), ("hvc1", "HEVC"), ("hev1", "HEVC"),
            ("av01", "AV1"), ("av1", "AV1"),
            ("vp9", "VP9"),
            ("avc", "H.264"), ("h264", "H.264"), ("h.264", "H.264"),
            ("x264", "H.264"), ("mpeg-4 part 10", "H.264"),
            ("mpeg2", "MPEG-2"), ("mpeg-2", "MPEG-2"),
        ])
    }

    static func audioLabel(codec: String?, channels: Int?) -> String? {
        guard let codec, !codec.isEmpty else { return nil }
        let name = normalize(codec, [
            ("truehd", "TrueHD"),
            ("eac3", "E-AC-3"), ("ec-3", "E-AC-3"), ("e-ac-3", "E-AC-3"),
            ("dolby digital plus", "E-AC-3"),
            ("ac3", "AC-3"), ("ac-3", "AC-3"),
            ("dts", "DTS"),
            ("aac", "AAC"), ("mp4a", "AAC"),
            ("opus", "Opus"),
            ("mp3", "MP3"), ("flac", "FLAC"),
        ])
        switch channels {
        case 8: return "\(name) 7.1"
        case 6: return "\(name) 5.1"
        case 2: return "\(name) 2.0"
        default: return name
        }
    }

    static func bitrateLabel(kbps: Int?) -> String? {
        guard let kbps, kbps > 0 else { return nil }
        return kbps >= 1000
            ? String(format: "%.1f Mbps", Double(kbps) / 1000)
            : "\(kbps) kbps"
    }
}

// MARK: - Learned stream measurements (v1.8.17)

/// What the PLAYER measured while actually playing one provider copy. The
/// upstream panels only publish ffprobe output for some copies (verified on a
/// live server: several report a bitrate and nothing else), so anything we
/// play gets measured on-device and remembered for the picker.
struct VODLearnedStream: Codable, Equatable {
    var width: Int?
    var height: Int?
    var videoCodec: String?
    var audioCodec: String?
    var audioChannels: Int?

    var isEmpty: Bool {
        width == nil && videoCodec == nil && audioCodec == nil
    }
}

/// Remembers per-copy measurements across launches, keyed by the picker's
/// option id (the Dispatcharr relation pk for movies, which is stable and
/// globally unique). Small, disposable cache: losing it only means the
/// picker falls back to whatever the server reported.
enum VODVersionMeasurementStore {
    private static let key = "vod.versionMeasurements.v1"
    private static let maxEntries = 400

    private struct Entry: Codable {
        var stream: VODLearnedStream
        var updatedAt: Date
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    static func lookup(optionID: Int) -> VODLearnedStream? {
        load()[String(optionID)]?.stream
    }

    static func record(optionID: Int, stream: VODLearnedStream) {
        guard !stream.isEmpty else { return }
        var all = load()
        // Nothing new to write: avoid a UserDefaults round trip on every
        // stream-info refresh tick.
        if all[String(optionID)]?.stream == stream { return }
        all[String(optionID)] = Entry(stream: stream, updatedAt: Date())
        if all.count > maxEntries {
            let keep = all.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxEntries)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Remembered version choice (v1.8.17)

/// Remembers which provider copy the user pinned for a title, so reopening it
/// does not silently fall back to Auto. Keyed by server + item so the same
/// movie on two Dispatcharr servers keeps separate choices, and stores the
/// relation id, which is validated against the current provider list on load
/// (a copy the provider dropped falls back to Auto rather than failing to
/// play).
enum VODVersionSelectionStore {
    private static let key = "vod.versionSelections.v1"
    private static let maxEntries = 500

    private struct Entry: Codable {
        var relationID: Int
        var updatedAt: Date
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ all: [String: Entry]) {
        var all = all
        if all.count > maxEntries {
            let keep = all.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxEntries)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func storageKey(serverID: UUID, itemType: String, itemID: String) -> String {
        "\(serverID.uuidString)|\(itemType)|\(itemID)"
    }

    static func selection(forKey key: String) -> Int? {
        load()[key]?.relationID
    }

    /// Pass nil to clear (the user chose Auto).
    static func setSelection(_ relationID: Int?, forKey key: String) {
        var all = load()
        if let relationID {
            all[key] = Entry(relationID: relationID, updatedAt: Date())
        } else {
            all.removeValue(forKey: key)
        }
        save(all)
    }
}

// MARK: - VOD version option (v1.8.17, Dispatcharr Direct Connect only)
/// One playable provider copy of a VOD item, pre-resolved to a proxy URL
/// so the player's Options menu can switch without any API knowledge.
struct VODVersionOption: Identifiable, Equatable, Hashable {
    let id: Int          // provider relation pk (movies) or m3u account id (episodes)
    let label: String    // "Provider · 1080p"
    let url: URL
}

/// AVPlayer-engine playability notes for the Version picker. Only
/// DEFINITIVE facts get a note - container extension the server recorded,
/// or a MEASURED video codec - never anything inferred from the
/// provider's advertised title (the "4K:" copy that measured 1080p is why
/// that rule exists). Returns nil when the AVPlayer engine is off: on the
/// mpv engine everything here plays and the note would be noise.
enum AVPlayerSupportNote {
    /// Human-facing note like "AVI isn't supported by AVPlayer", or nil
    /// when nothing definitive disqualifies the copy.
    static func note(containerExtension: String?, videoCodec: String?) -> String? {
        guard PlaybackFeatureFlags.avPlayerRemuxTS else { return nil }
        if let ext = containerExtension?.lowercased(), !ext.isEmpty {
            switch ext {
            case "avi", "divx": return "AVI isn't supported by AVPlayer"
            case "wmv", "asf": return "WMV isn't supported by AVPlayer"
            case "flv": return "FLV isn't supported by AVPlayer"
            case "mpg", "mpeg": return "MPEG-PS isn't supported by AVPlayer"
            default: break
            }
        }
        // Measured codec strings vary by source: server ffprobe gives
        // "mpeg4"; the mpv learn-cache gives full descriptions. Match by
        // substring, and check the more specific names first (a plain
        // "mpeg4" test would also catch "mpeg4/ISO AVC" style strings).
        if let codec = videoCodec?.lowercased(), !codec.isEmpty {
            if codec.contains("avc") || codec.contains("h264") || codec.contains("264")
                || codec.contains("hevc") || codec.contains("h265") || codec.contains("265") {
                return nil
            }
            if codec.contains("mpeg2") || codec.contains("mpeg-2") {
                return "MPEG-2 video isn't supported by AVPlayer"
            }
            if codec.contains("mpeg4") || codec.contains("xvid") || codec.contains("divx")
                || codec.contains("msmpeg4") {
                return "MPEG-4 ASP video isn't supported by AVPlayer"
            }
            if codec.contains("vc1") || codec.contains("vc-1") {
                return "VC-1 video isn't supported by AVPlayer"
            }
            if codec.contains("av1") || codec.contains("av01") {
                // Hardware-dependent (A17 Pro/M-class decode it); the MKV
                // engine passes AV1 through so the device gets to vote.
                return "AV1 may not play on this device"
            }
        }
        return nil
    }
}

/// One label pipeline for EVERY version picker (detail page and the
/// in-player Switch Version rows): account + container, then whatever was
/// MEASURED for that copy (server ffprobe merged with this device's
/// learn-cache), then the AVPlayer support note. Collisions get a
/// positional "(n)". Extracted 2026-08-26: the resume-cover path built
/// its own bare "Account · 4K" labels, so the player rows lacked the
/// quality info the detail picker shows.
enum VODVersionLabeler {
    static func labels(providers: [DispatcharrVODProviderRelation],
                       media: [Int: DispatcharrVODProviderMedia],
                       learned: [Int: VODLearnedStream]) -> [Int: String] {
        func base(_ rel: DispatcharrVODProviderRelation) -> String {
            let l = learned[rel.id]
            let measured = media[rel.id]?.descriptors(mergedWith: l)
                ?? DispatcharrVODProviderMedia.descriptorsForLearnedOnly(l)
            var parts = measured.isEmpty ? [rel.displayLabel] : [rel.displayLabel] + measured
            if let note = AVPlayerSupportNote.note(
                containerExtension: rel.containerExtension,
                videoCodec: media[rel.id]?.videoCodec) {
                parts.append("⚠️ \(note)")
            }
            return parts.joined(separator: " · ")
        }
        var counts: [String: Int] = [:]
        for rel in providers { counts[base(rel), default: 0] += 1 }
        var used: [String: Int] = [:]
        var out: [Int: String] = [:]
        for rel in providers {
            let b = base(rel)
            if counts[b, default: 0] > 1 {
                let n = used[b, default: 0] + 1
                used[b] = n
                out[rel.id] = "\(b) (\(n))"
            } else {
                out[rel.id] = b
            }
        }
        return out
    }
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

    // v1.8.17 VOD version switching: the Dispatcharr Movie uuid, needed
    // to rebuild /proxy/vod/movie/<uuid>?m3u_account_id=N for a chosen
    // provider copy. Empty for XC/M3U sources (feature hidden there).
    // Default empty so existing initializers don't need updating.
    var dispatcharrUUID: String = ""

    /// Movies tab (2026-09): when the source added this title (XC `added`,
    /// Dispatcharr `created_at`). nil when the source has no such field;
    /// Recently Added hides itself when nothing carries one.
    var addedAt: Date? = nil

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
    /// Ingest time when the source reports one (Dispatcharr created_at).
    var addedAt: Date? = nil

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

    // v1.6.16.x: rich per-episode metadata. All default empty so
    // existing initializers don't need updating; populated by
    // `dispatcharrSeriesDetail(...)` from the Dispatcharr Episode
    // schema fields (`air_date`, `rating`, `tmdb_id`, `imdb_id`)
    // plus `custom_properties.crew` (the per-episode director).
    var airDate: String = ""
    var rating: String = ""
    var tmdbID: String = ""
    var imdbID: String = ""
    var crew: String = ""

    // v1.8.17 VOD version switching: Dispatcharr Episode uuid for
    // /proxy/vod/episode/<uuid>?m3u_account_id=N. Empty for XC sources.
    var dispatcharrUUID: String = ""

    /// Provider episode titles are usually the show's name plus tags
    /// ("A Knight of the Seven Kingdoms (2026) S01E01"). Strips the show
    /// name, season/episode markers and tags; empty when nothing is left,
    /// so the caller can fall back to TMDB's episode name.
    func cleanedTitle(showName: String) -> String {
        var t = VODDisplayItem.strippingQualityPrefix(title)
        let show = VODDisplayItem.cleanDisplayName(showName)
        if !show.isEmpty, t.lowercased().hasPrefix(show.lowercased()) {
            t = String(t.dropFirst(show.count))
        }
        // Whatever follows the show name: "(2026) - S01E01 - Title",
        // "1x01 Title", "- Episode 3: Title". Strip year groups, season /
        // episode markers and separators wherever they sit, then tidy.
        for pattern in [#"\((19|20)\d{2}\)"#, #"(?i)\bS\d{1,2}\s*E\d{1,3}\b"#, #"(?i)\b\d{1,2}x\d{1,3}\b"#,
                        #"(?i)\bepisode\s*\d{1,3}\b"#, #"(?i)\bseason\s*\d{1,2}\b"#] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: #"^[\s\-:·|)(\[\]]+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\s\-:·|(\[]+$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return VODDisplayItem.strippingTrailingYears(t).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "8.0" / "" for nil-or-zero. Same convention as VODMovie /
    /// VODSeries — the UI's empty-rating skip logic stays portable
    /// across all three.
    var displayRating: String {
        guard !rating.isEmpty, let r = Double(rating), r > 0 else { return "" }
        return String(format: "%.1f", r)
    }

    /// Episode air date as locale-short for the row UI. Falls
    /// back to the raw `airDate` string when the input doesn't
    /// parse as `yyyy-MM-dd`. Returns empty when the field is
    /// missing — callers should skip rendering rather than show
    /// a placeholder. v1.6.16.x: formatters are static so a
    /// 1000-episode series doesn't allocate two new
    /// `DateFormatter` instances per row on every SwiftUI body
    /// re-evaluation.
    var displayAirDate: String {
        guard !airDate.isEmpty else { return "" }
        guard let date = Self.airDateParser.date(from: airDate) else { return airDate }
        return Self.airDateDisplay.string(from: date)
    }

    /// Parser for the wire format Dispatcharr emits
    /// (ISO 8601 date, `yyyy-MM-dd`). Pinned to POSIX + UTC so
    /// the parse is deterministic regardless of device locale.
    private static let airDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// User-facing display formatter. Locale-aware (`.short`
    /// style respects `Locale.current` so US users see
    /// `M/d/yyyy`, UK users see `dd/MM/yyyy`, etc.).
    private static let airDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        return f
    }()
}

// MARK: - VOD Category
struct VODCategory: Identifiable, Hashable {
    let id: String
    let name: String
    var itemCount: Int = 0
    /// Dispatcharr: M3U account ids this category is enabled on (from
    /// `/api/vod/categories/` m3u_accounts[]). Empty for other sources.
    /// Drives the Filter page's provider tab (Logan 2026-09-04).
    var providerIDs: [Int] = []
}

// MARK: - Library matcher (TMDB title lists -> library rows)

/// Matches TMDB rows (id + title) to library items. Built once off the main
/// thread, then looked up per candidate. Every row is indexed by BOTH its
/// TMDB id (when present) and a cleaned title, so an id-less or mis-id'd
/// row still matches by name. The cleaned title drops quality prefixes
/// ("4K:"), trailing "(YYYY)" groups, punctuation and diacritics: "4K:
/// Deadpool 2 (2018)" and "Deadpool 2" collide (Logan 2026-09-04: Ryan
/// Reynolds matched 2 of 106 credits).
struct LibraryMatcher: Sendable {
    private var byTMDB: [String: VODDisplayItem] = [:]
    private var byTitle: [String: VODDisplayItem] = [:]
    private(set) var idCount = 0

    nonisolated init(_ library: [VODDisplayItem]) {
        for m in library {
            let id = m.movie?.tmdbID ?? m.series?.tmdbID ?? ""
            if !id.isEmpty {
                if byTMDB[id] == nil { byTMDB[id] = m }
                idCount += 1
            }
            let key = LibraryMatcher.cleanTitle(m.name)
            if !key.isEmpty, byTitle[key] == nil { byTitle[key] = m }
        }
    }

    nonisolated func match(tmdbID: String, title: String) -> VODDisplayItem? {
        if !tmdbID.isEmpty, let hit = byTMDB[tmdbID] { return hit }
        return byTitle[LibraryMatcher.cleanTitle(title)]
    }

    nonisolated static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading quality tags: "4K:", "[HD] ", "UHD - ".
        while true {
            var t = Substring(s)
            if t.first == "[" || t.first == "(" { t = t.dropFirst() }
            guard let tag = ["UHD", "FHD", "4K", "HD", "SD"].first(where: { t.uppercased().hasPrefix($0) }) else { break }
            t = t.dropFirst(tag.count)
            if t.first == "]" || t.first == ")" { t = t.dropFirst() }
            guard let sep = t.first, sep == ":" || sep == "-" || sep == "|" || sep == " " else { break }
            s = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        s = VODDisplayItem.strippingTrailingYears(s)
        s = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        s = s.replacingOccurrences(of: "&", with: " and ")
        let scalars = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
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

    /// Name for display: provider names often carry one or more trailing
    /// "(YYYY)" groups ("#Horror (2015) (2015)"), and the UI shows the year
    /// on its own meta line, so every trailing year is dropped (Logan
    /// 2026-09-04). The raw `name` stays for matching and search.
    var displayName: String { VODDisplayItem.cleanDisplayName(name) }

    /// Provider names carry a leading language code ("EN - Title"), trailing
    /// "(YYYY)", region/language groups "(GB)", "(ES)", "(DUAL/ES)",
    /// "(MULTI)" and quality brackets "[1080p]" (Logan 2026-09-04). All of
    /// it is dropped for display; the language tags surface on Details.
    nonisolated static func cleanDisplayName(_ raw: String) -> String {
        var s = strippingQualityPrefix(raw)
        // "EN - ", "EN: ", "EN | " (2-3 uppercase letters, then a separator).
        if let r = s.range(of: #"^[A-Z]{2,3}\s*[-:|]\s+"#, options: .regularExpression) {
            let rest = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { s = rest }
        }
        // Trailing tag groups, repeated: (2026) (GB) (DUAL/ES) (MULTI) [1080p] [4K].
        while let r = s.range(of: #"\s*(\((19|20)\d{2}\)|\([A-Z]{2,3}(/[A-Z]{2,3})*\)|\((DUAL|MULTI)(/[A-Z]{2,3})*\)|\[[^\]]{1,12}\])\s*$"#,
                                options: .regularExpression) {
            let head = s[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { break }
            s = head
        }
        return s
    }

    /// Language names from the provider name's tags: the leading code and
    /// the trailing "(XX)" / "(DUAL/XX)" groups. Region-looking codes that
    /// are not languages ("GB") are kept as given. Empty when the name has
    /// no tags.
    var languageTags: [String] {
        var codes: [String] = []
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = raw.range(of: #"^[A-Z]{2,3}(?=\s*[-:|]\s+)"#, options: .regularExpression) {
            codes.append(String(raw[r]))
        }
        for m in VODDisplayItem.tagRegex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let g = Range(m.range(at: 1), in: raw) else { continue }
            for part in raw[g].split(separator: "/") {
                let c = String(part)
                if c == "DUAL" || c == "MULTI" { codes.append("Multiple") } else { codes.append(c) }
            }
        }
        var seen = Set<String>()
        return codes.compactMap { c -> String? in
            guard seen.insert(c).inserted else { return nil }
            if c == "Multiple" { return "Multiple audio tracks" }
            let named = Locale.current.localizedString(forLanguageCode: c.lowercased())
            return (named?.isEmpty == false && named!.lowercased() != c.lowercased()) ? named! : c
        }
    }

    nonisolated private static let tagRegex = try! NSRegularExpression(pattern: #"\(([A-Z]{2,5}(?:/[A-Z]{2,5})*)\)"#)

    // Kind-neutral accessors so one library view serves movies and series.
    var categoryName: String? { movie?.categoryName ?? series?.categoryName }
    var addedAt: Date? { movie?.addedAt ?? series?.addedAt }
    var castText: String { movie?.cast ?? series?.cast ?? "" }
    var directorText: String { movie?.director ?? series?.director ?? "" }
    var plotText: String { movie?.plot ?? series?.plot ?? "" }
    var genreText: String { movie?.genre ?? series?.genre ?? "" }
    var durationText: String { movie?.duration ?? "" }
    var backdropURL: URL? { movie?.backdropURL ?? series?.backdropURL }

    /// Drops leading quality tags ("4K:", "[HD] ", "UHD - ") from a
    /// provider name (Logan 2026-09-04). Case of the rest is untouched.
    nonisolated static func strippingQualityPrefix(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            var t = Substring(s)
            if t.first == "[" || t.first == "(" { t = t.dropFirst() }
            guard let tag = ["UHD", "FHD", "4K", "HD", "SD"].first(where: { t.uppercased().hasPrefix($0) }) else { break }
            t = t.dropFirst(tag.count)
            if t.first == "]" || t.first == ")" { t = t.dropFirst() }
            guard let sep = t.first, sep == ":" || sep == "-" || sep == "|" || sep == " " else { break }
            let rest = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { break }
            s = rest
        }
        return s
    }

    nonisolated static func strippingTrailingYears(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let r = s.range(of: #"\s*\((19|20)\d{2}\)\s*$"#, options: .regularExpression) {
            let head = s[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { break }
            s = head
        }
        return s
    }

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
