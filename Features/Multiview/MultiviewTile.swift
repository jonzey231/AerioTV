import Foundation

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
/// into tile position 0 — no re-seed, no black flash. See the plan's
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

    /// The channel metadata — name, logo, number, EPG status.
    let item: ChannelDisplayItem

    /// Resolved playback URL (first entry of `item.streamURLs`). The
    /// list contains format fallbacks (`.m3u8` → `.ts` → direct);
    /// `streamURLs.first` is the platform-preferred entry already —
    /// see `XtreamCodesAPI.streamURLs(for:)` at
    /// `Networking/StreamingAPIs.swift:250`.
    let streamURL: URL

    /// Auth headers the stream request needs. For Dispatcharr:
    /// `Authorization: ApiKey <key>` + `X-API-Key` + `User-Agent`.
    /// For XC / M3U: `Accept: */*` (auth is encoded in the URL path).
    /// Snapshotted at add-time from `ServerConnection.authHeaders` at
    /// `Models/Models.swift:181`.
    ///
    /// SECURITY — do NOT log `MultiviewTile` wholesale (`print(tile)`,
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
}
