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
    /// Optional "Open Series" action for episode cards. When provided,
    /// long-pressing an episode card offers Open Series, which navigates
    /// to that show's detail page (all seasons and episodes), the same
    /// destination as selecting the series from the main grid. Movies and
    /// not-yet-loaded series do not surface the option.
    var onOpenSeries: ((VODDisplayItem) -> Void)?

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
                                // Episodes with a loaded parent series get an
                                // Open Series action that jumps to the full
                                // show page, same as picking it from the grid.
                                if let parentSeries, let onOpenSeries {
                                    Button {
                                        onOpenSeries(parentSeries)
                                    } label: {
                                        Label("Open Series", systemImage: "rectangle.stack")
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

    /// Resolve the card's artwork, title, and subtitle. For an episode we
    /// look up the parent series (by `seriesID`) so the card shows the
    /// show's poster + name with an "S1:E4 - Episode Title" subtitle,
    /// instead of the episode's own still + title. Movies render as-is.
    private func resolveDisplay(_ p: WatchProgress) -> (poster: String?, title: String, subtitle: String?) {
        if p.vodType == "episode" {
            let show = series.first { $0.id == p.seriesID }
            let poster = show?.posterURL?.absoluteString ?? p.posterURL
            let label = episodeLabel(season: p.seasonNumber, episode: p.episodeNumber)
            if let show {
                let parts = [label, p.title].filter { !$0.isEmpty }
                return (poster, show.name, parts.isEmpty ? nil : parts.joined(separator: " - "))
            }
            // Series not loaded yet: keep the episode title up top, SxEy below.
            return (poster, p.title, label.isEmpty ? nil : label)
        }
        return (p.posterURL, p.title, nil)
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
                // Poster (series poster for episodes, movie poster for movies)
                if let urlStr = posterURLString, let url = URL(string: urlStr) {
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
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentPrimary)
                                .frame(width: geo.size.width * CGFloat(min(fraction, 1.0)), height: 3)
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

            // Title line: series name for episodes, movie title for movies.
            Text(title)
                .font(.caption)
                .foregroundColor(.textSecondary)
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)

            // Subtitle line: "S1:E4 - Episode Title" for episodes.
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
    }
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
