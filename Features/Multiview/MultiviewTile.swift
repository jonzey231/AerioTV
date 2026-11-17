import Foundation

/// What a multiview tile is playing. Drives `isLive` / `isDVR` on the
/// player and whether resume / continue-watching applies. Defaults to
/// `.live`, so every existing channel-tile construction is unchanged.
enum TilePlaybackKind: Equatable {
    case live
    case vod
    case dvr
    /// Server-archive replay of an aired programme (timeshift URL).
    /// Unified-pipeline mode: same container and chrome as live, with
    /// a position/duration band and no live-only cells (task #147).
    case catchup
}

/// One tile inside the multiview grid.
///
/// A `MultiviewTile` captures everything needed to instantiate a single
/// `MPVPlayerView` for one of the concurrently-playing channels:
/// the `ChannelDisplayItem` (for metadata like name, logo, number),
/// the resolved playback URL, the auth headers the server needs on
/// stream requests, and a stable identity.
///
/// **Identity**: for the very first tile seeded when the user enters
/// multiview from a single stream already playing, `id` is set to
/// `item.id` (the channel ID). This pins the tile's SwiftUI identity
/// to the existing channel so SwiftUI diffs the same `MPVPlayerView`
/// instance (and its Coordinator, which owns the running mpv handle)
/// into tile position 0, no re-seed, no black flash. See the plan's
/// "Entering multiview from single" section.
///
/// For every subsequent tile added via the channel picker, `id` is a
/// fresh `UUID().uuidString` so a given channel can appear in multiple
/// tiles if the user genuinely wants two copies (edge case but
/// allowed). The `MultiviewStore.add` dedup check keys on
/// `item.id == existingTile.item.id` to block common-case duplicates
/// and can be bypassed with a future `allowDuplicates` flag.
struct MultiviewTile: Identifiable, Equatable {
    /// Stable identity used by `ForEach(\.id)` to preserve SwiftUI
    /// view identity across layout changes. Pinned to `item.id` for
    /// tile 0 on seed-from-single; fresh UUID otherwise.
    let id: String

    /// The channel metadata, name, logo, number, EPG status.
    let item: ChannelDisplayItem

    /// Resolved playback URL (first entry of `item.streamURLs`). The
    /// list contains format fallbacks (`.m3u8` → `.ts` → direct);
    /// `streamURLs.first` is the platform-preferred entry already,
    /// see `XtreamCodesAPI.streamURLs(for:)` at
    /// `Networking/StreamingAPIs.swift:250`.
    let streamURL: URL

    /// Auth headers the stream request needs. For Dispatcharr:
    /// `Authorization: ApiKey <key>` + `X-API-Key` + `User-Agent`.
    /// For XC / M3U: `Accept: */*` (auth is encoded in the URL path).
    /// Snapshotted at add-time from `ServerConnection.authHeaders` at
    /// `Models/Models.swift:181`.
    ///
    /// SECURITY, do NOT log `MultiviewTile` wholesale (`print(tile)`,
    /// `NSLog("%@", tile)`, crash-log captures, SwiftUI debug
    /// previews). These headers can contain API keys. Log `tile.id` or
    /// `tile.item.name` if you need to identify a tile in diagnostics.
    /// There's no automated redaction on the type because `Equatable`
    /// + value-semantics trump a wrapper; review caller sites instead.
    let headers: [String: String]

    /// When the user added this tile. Used to pick the default
    /// audio-focused tile (most-recently-added) and to animate
    /// newcomers distinctly from existing tiles.
    let addedAt: Date

    /// What this tile is playing. `.live` (the default, so every
    /// existing construction compiles unchanged) for channels; `.vod`
    /// for movies / episodes; `.dvr` for in-progress server recordings
    /// played via HLS. Read by `MultiviewTileView` to pass
    /// `isLive` / `isDVR` to the shared player.
    var kind: TilePlaybackKind = .live

    /// VOD / recording identity, set only for `.vod` / `.dvr` tiles.
    /// These seed the per-tile `PlayerProgressStore` so the shared
    /// player coordinator resumes from the saved position and saves
    /// WatchProgress every 10s (mirrors the `progressStore.vod*` fields
    /// PlayerView sets in `startPlayback`). All nil / default for live
    /// tiles. A nil `vodID` means no continue-watching for this tile
    /// (used for server recordings, matching the single-player path).
    var vodID: String? = nil
    var vodServerID: String? = nil
    var vodType: String = "movie"

    /// Optional forced resume position. Nil lets the coordinator look
    /// the position up from `WatchProgress` via `vodID` / `vodServerID`;
    /// set it to 0 for a deliberate "watch from the beginning".
    var resumePositionMs: Int32? = nil

    /// Catch-up replay payload, set only for `.catchup` tiles. Flows
    /// into the shared player's `catchup` param (window re-tune seek
    /// model, aeriocu relay, pinned duration).
    var catchup: CatchupPlayback? = nil

    /// `.dvr` tiles only: when the recording is scheduled to stop
    /// (Recording.effectiveEnd, i.e. scheduledEnd + post-roll). Drives
    /// the proactive "Recording Ending" prompt for a viewer at the live
    /// edge; nil for tiles that don't know (prompt simply never shows
    /// and the finalize migration handles the end reactively).
    var dvrScheduledEnd: Date? = nil
    /// `.dvr` tiles only: the guide channel id the recording captures,
    /// for the prompt's "Continue on Live TV" hand-off (posted as an
    /// aerioOpenChannel deep link after session exit).
    var dvrChannelID: String? = nil

    /// `.vod` episode tiles: the series name, season, episode number, and
    /// episode title as separate fields, so the remote-session card and
    /// sheet can split them across their lines (owner 2026-11-17). nil for
    /// movies, recordings, and live tiles.
    var episodeInfo: OnDemandEpisodeInfo? = nil
}

/// What an episode is, field by field. `item.name` on the tile keeps the
/// combined label ("Severance S01E02 Half Loop") the player already uses.
struct OnDemandEpisodeInfo: Equatable {
    var seriesName: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var episodeTitle: String?

    /// The title line: the series name, else the label the player has.
    func titleLine(fallback: String) -> String {
        let name = seriesName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback : name
    }

    /// The program line: "S1 E2 · Half Loop" (the "S1 E2" style Continue
    /// Watching and DVR use), "S1 E2" without a title, the title alone
    /// without numbers, nil with neither.
    var programLine: String? {
        var code: String? = nil
        if let s = seasonNumber, let e = episodeNumber, s > 0, e > 0 { code = "S\(s) E\(e)" }
        let title = episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (code, title.isEmpty) {
        case let (code?, false): return "\(code) · \(title)"
        case let (code?, true): return code
        case (nil, false): return title
        case (nil, true): return nil
        }
    }

    /// A Continue Watching row, which keeps season and episode as fields
    /// but only the combined label for the names. The label is the one
    /// VODDetailView.episodeLaunchTitle builds ("<series> S01E02 <title>"),
    /// so it is cut at that exact code from the row's own numbers; a row
    /// whose label lacks the code (one Up Next seeded) keeps the numbers
    /// and no names.
    static func fromProgress(title: String, seasonNumber: Int, episodeNumber: Int) -> OnDemandEpisodeInfo {
        var info = OnDemandEpisodeInfo(seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        guard seasonNumber > 0, episodeNumber > 0 else { return info }
        let code = " " + String(format: "S%02dE%02d", seasonNumber, episodeNumber)
        guard let range = title.range(of: code) else { return info }
        let series = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        info.seriesName = series.isEmpty ? nil : series
        // "Episode N" is the launch label's stand-in for a missing title.
        info.episodeTitle = (rest.isEmpty || rest == "Episode \(episodeNumber)") ? nil : rest
        return info
    }
}
