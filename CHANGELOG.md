# Changelog

## v1.6.18 — 2026-04-29

### Added

- **Stream Info overlay now pulls live server-side stats from
  Dispatcharr** *(Dispatcharr API playlists only)*. The overlay
  fetches `/api/channels/streams/{id}/` every 5 seconds while
  visible and surfaces Dispatcharr's authoritative
  `stream_stats` blob (resolution, source FPS, video codec,
  audio codec + channel layout, ffmpeg output bitrate) plus the
  current viewer count. Server-side values take precedence over
  mpv-derived client-side values when present — Dispatcharr
  analyzes the source feed directly, so its numbers reflect the
  upstream stream rather than the device's decoder pipeline. On
  XC / M3U servers (or for Dispatcharr streams Dispatcharr
  hasn't populated stats for yet) the overlay falls back to the
  mpv-derived values, so the same 5 fields always render
  consistently across server types.

- **Stream Info overlay redesigned to a clean 5-field layout.**
  Previously the overlay showed 6 rows of mixed-purpose data
  (cache duration, sync, dropped frames, hwdec mode) that read
  more like an mpv debug dump than a viewer-facing card. v1.6.18
  trims to Resolution / FPS / Video Codec / Audio Codec / Data
  Rate (per user spec for non-API playback), with an optional
  Viewers row when on Dispatcharr API. Same overlay shape on
  iPhone, iPad, and Apple TV; same render path for the legacy
  single-stream player and the unified multiview audio tile.

- **Swipe up/down to change channels on iPhone and iPad.** Mirrors
  the Apple TV up/down channel-flip on the Siri Remote, but for
  touch. To prevent accidental swipes during normal viewing, the
  gesture is gated on chrome being visible — tap once to summon
  the player chrome, then swipe up (next channel) / down (previous
  channel). Each flip refreshes the chrome fade timer so the
  Tap → Swipe → Swipe → Swipe flow keeps working without
  re-tapping. Live streams only (recordings and VOD don't have a
  channel concept). Single-stream playback only — multi-tile
  multiview keeps gestures for tile interaction. Vertical-bias
  threshold (≥ 40pt vertical movement, ≥ 1.5× dominance over
  horizontal) keeps iPad split-view drag-from-edge gestures from
  being misread as channel flips. Direction convention matches
  Apple TV: up = next channel (higher number), down = previous —
  per the IPTV remote idiom. Implemented in both the unified
  multiview path (`MultiviewContainerView`) and the legacy
  single-stream path (`PlayerView`) so users on either path get
  the feature.

### Fixed

- **Apple TV: returning to the guide after watching a channel
  now lands focus on the channel you were just watching.** The
  guide had been auto-focusing the first row in the visible
  filter regardless of which channel was minimized into the
  corner mini-player or just torn down via "Exit Multiview" —
  it felt random and made the guide auto-scroll for no apparent
  reason. v1.6.18 default-focuses the currently-playing channel
  when minimizing from single-stream playback, and falls back
  to the last audio-tile channel after a full multiview exit
  (captured before the multiview store is reset). Also scrolls
  that row into view at the same moment focus lands so the user
  doesn't see an apparently-arbitrary jump when the channel was
  offscreen.

- **iPhone portrait: Close / Options / Add buttons no longer sit
  too low.** v1.6.17's iPhone-only multiview safe-area carve-out
  (which fixed tile content sliding under the Dynamic Island)
  caused the chrome overlay's parent to start respecting safe area.
  The chrome's existing `dynamicTopInset` formula then double-
  counted the Dynamic Island clearance, floating the buttons
  ~130pt below the screen top instead of the intended ~71pt.
  Same root cause floated the channel info banner and Stream
  Info card too far down. Fixed by adding
  `.ignoresSafeArea(edges: .top)` to each of those three overlays
  so their `dynamicTopInset` formula measures from the literal
  screen top as it was originally designed. Landscape, iPad, and
  Apple TV were always fine — affected iPhone portrait only.

- **Channel info banner no longer covers the Stream Info card.**
  On iPhone the two overlays sit at the same top-left coordinates;
  the banner was rendering on top, hiding the stats the user just
  asked to see. v1.6.18 suppresses the banner while
  `showStreamInfo` is true via a new `streamInfoIsVisible` flag
  on `NowPlayingManager` that both the legacy PlayerView and the
  unified MultiviewContainerView publish to.

- **iPhone landscape: channel info banner now sits to the right of
  the Close button instead of below it.** Landscape has the
  horizontal room to share the row, so squeezing the banner into
  a second row underneath was wasted vertical real estate. iPhone
  PORTRAIT keeps the below-close-button layout because the close
  button column doesn't leave enough width for the banner. iPad
  and Apple TV unchanged.

- **Live channel audio no longer bleeds through when starting a
  recording or VOD playback.** Repro (Apple TV, reported by user
  NicolaiVdS): watching a live channel → press Back to minimize →
  navigate to DVR (or On Demand) → start playing a recording (or
  movie / TV episode). Pre-1.6.18 the recording's video would
  play correctly but the live channel's audio kept playing
  underneath — two simultaneous audio streams. Cause: Aerio's
  player overlay sits at the MainTabView level and persists
  across tab navigation (so a minimized live channel keeps
  playing while the user is in DVR / On Demand). The recording
  and VOD paths mount their player via `.fullScreenCover(item:)`,
  which layers a NEW player on top WITHOUT unmounting the live
  one — leaving two mpv instances both producing audio. Fixed by
  calling `NowPlayingManager.shared.stop()` immediately before
  setting the state that triggers `.fullScreenCover` in
  `MyRecordingsView.playRecording`,
  `MyRecordingsView.playServerRecording`, and
  `VODDetailView.resolveAndLaunch`. Stop() clears the live
  player's state → SwiftUI unmounts the live PlayerView →
  coordinator's mpv quit fires before the new player spins up.
  Cross-platform fix (iOS / iPadOS / tvOS); the bug had the same
  root cause on every platform.

- **Live TV List view on iPhone no longer jitters when scrolling
  to the group-pill snap-out threshold.** Repro: open Live TV →
  switch to List view → scroll down slightly to the threshold
  where the group filter pills are about to collapse. Pre-1.6.18
  the list would oscillate up and down indefinitely until the
  user scrolled past the boundary. Cause: pills lived in a VStack
  sibling above the List with a conditional `if !isChromeCollapsed`
  guard. Toggling the conditional removed pills from the VStack
  → VStack shrank → List's frame shifted → `.onScrollGeometryChange`
  re-fired with a different content offset reading → re-triggered
  the hysteresis check during the 0.2s collapse animation →
  oscillation. The 60pt hysteresis window (collapse at 80pt /
  expand at 20pt) wasn't wide enough to swallow the
  layout-shift-induced offset jitter. Fixed by moving the iPhone
  pills out of the VStack and into `.safeAreaInset(edge: .top)`
  on the List itself. Show/hide now changes only the List's top
  safe-area inset — the List's outer frame and content offset
  stay stable across the transition, so the layout-recalibration
  feedback loop that produced the oscillation can't form.
  iPad and Apple TV still render pills above the List in the
  VStack (always visible on those platforms, no scroll-collapse
  behavior).

## v1.6.17 — 2026-04-29

### Fixed

- **Multiview no longer leaves all tiles black after backgrounding
  with 9 streams active.** Repro: open a single channel, add 8 more
  for a 3×3 grid, switch to another app, switch back. Pre-1.6.17 the
  audio kept playing but every video tile rendered black until the
  user manually re-tapped each one. Two compounding causes:
  (1) `didEnterBackground` was returning early at the
  `pipAutoEligible` check on the audio tile — but iOS won't actually
  engage Picture-in-Picture for any of the multi-tile
  `AVSampleBufferDisplayLayer` instances because there are too many
  to disambiguate. So vid stayed alive on one tile and was disabled
  on the others, leaving them in an asymmetric state on return.
  (2) `AVSampleBufferDisplayLayer.sampleBufferRenderer` came back
  from background in `.failed` status; without an explicit `flush()`,
  mpv's frame writes were silently dropped. Fix: the
  `pipAutoEligible` early-return now gates on
  `MultiviewStore.tiles.count > 1`, so multi-tile multiview falls
  through to the symmetric pause-on-background path; and
  `willEnterForeground` calls `sampleBufferRenderer.flush()`
  synchronously before re-enabling video so the renderer is healthy
  by the time mpv starts pumping frames. Single-stream auto-PiP path
  is unchanged. Multiview-aware auto-PiP itself is still a known
  gap — out of scope here.

- **VOD On Demand tab now appears for users on stricter Dispatcharr
  builds.** Two compounding bugs that produced "VOD detected in logs
  but never shows up in the app":

  1. The `.task(id: vodServerKey)` in `MainTabView` only re-fires
     when `vodServerKey` changes, and `vodServerKey` hashed only
     `id|baseURL|isActive` — it did NOT include `vodEnabled` or
     `supportsVOD`. A user toggling Fetch VOD from this Playlist on
     would update SwiftData, but the task wouldn't refire and the
     VOD store stayed empty until app relaunch. Fixed by including
     both flags in `vodServerKey`.

  2. Pre-1.6.17 `loadMovies`/`loadSeries` iterated each enabled
     category and called `/api/vod/{movies,series}/?category=<name>`
     in a loop, deduping by uuid. That worked on lenient Dispatcharr
     instances where `?category=` was effectively ignored — every
     request returned the FULL library and the dedup made it look
     like per-category isolation. On stricter Dispatcharr builds
     (verified against
     `dispatcharr-freynas.frey-home.synology.me` on 2026-04-29 with
     a four-test curl matrix), the same query returns `count: 0`
     because the filter expects something the categories endpoint
     never tells us about. The Series and Movie OpenAPI schemas
     have NO top-level `category` field — the only place a VOD
     item's category appears in the list response is
     `custom_properties.category_id`, and even that's only populated
     for series. v1.6.17 switches to a single unfiltered paginated
     fetch and groups items client-side: series tag from
     `custom_properties.category_id`; movies (where Dispatcharr
     doesn't surface category attribution on the list endpoint)
     fall back to the first enabled category, matching the v1.6.16
     UX exactly while no longer returning empty on strict builds.

### Added

- **Granular iCloud Sync Categories.** Settings → iCloud Sync now
  exposes a new "Sync Categories" sub-page where you can opt out of
  syncing individual data types (Playlists & Servers, VOD Watch
  Progress, Reminders, App Preferences, Credentials) instead of the
  prior all-or-nothing master toggle. Each row also has a "Delete
  from iCloud" button that scrubs that category's KVS payload (or
  iCloud Keychain entries, for Credentials) without touching the
  rest. Local data on the device is preserved — only the cloud copy
  is removed. The toggle states themselves still ride iCloud sync,
  so flipping a category off on iPhone propagates to iPad. Master
  iCloud Sync toggle still gates everything; per-category toggles
  default ON so existing users see no change on upgrade.

- **Reorder Playlists in Settings.** The Playlists section now
  supports user-defined ordering. iOS / iPadOS: tap "Edit" in the
  navigation bar (appears when 2+ playlists exist) for drag-to-
  reorder handles. tvOS: long-press a playlist for the context menu
  → Move Up / Move Down. The order writes into the existing
  `sortOrder` model field, persists in SwiftData, and rides iCloud
  sync — reorder once on iPhone and your iPad / Apple TV pick up the
  same arrangement. Tiebreaker on `createdAt` keeps the legacy
  insertion-order behaviour stable for users who never reorder.

### Changed

- **Multiview on iPhone respects the notch and Dynamic Island.**
  Pre-1.6.17, multiview tiles extended edge-to-edge regardless of
  device, which slid video frames behind the notch / Dynamic Island
  / landscape speaker cutout — eating tile content the user couldn't
  recover. Now iPhone multiview renders the tile grid INSIDE the
  safe area, with the black background filling the corners around
  the cutouts. iPad keeps the legacy edge-to-edge look (its
  safe-area insets are zero in normal full-screen mode). tvOS is
  unchanged.

## v1.6.16 — 2026-04-28

### Fixed

- **VOD series episodes now load reliably on the first open.** A
  series detail's `.task` was being cancelled mid-fetch by ancestor
  re-renders (iCloud sync churn rebuilding the server list,
  back-out-and-reopen, VODStore refilling categories) — the
  cancellation propagated into the URLSession data task and aborted
  the episode-list request as `NSURLErrorCancelled (-999)`. The
  workaround pre-1.6.16 was to back out and re-open the series.
  Fix: spawn the fetch via `Task.detached` so it survives view
  cancellation, and cache successful results in a static dict
  (`SeriesDetailCache`) so subsequent opens hit the cache instantly.
  Bonus: the cache also de-dupes concurrent same-id fetches via an
  `inFlightTasks` map, so a double-tap can't kick two parallel
  requests.

- **Provider-info now runs before episodes.** Pre-1.6.16 ran
  `/api/vod/series/{id}/provider-info/` and
  `/api/vod/series/{id}/episodes/` concurrently via `async let`.
  The OpenAPI schema documents provider-info as
  *"Get detailed series information, refreshing from provider if
  needed"* — i.e. it's the lazy-scrape trigger. Concurrent
  execution raced the scrape, so for series Dispatcharr hadn't
  yet pulled episode metadata for, the episodes endpoint returned
  `[]` while provider-info was still populating the table. Now
  provider-info is awaited first; episodes runs second against the
  populated data.

- **Episode plot now displays correctly.** Decoder was looking for
  `plot` / `overview` keys, but the actual Dispatcharr response
  uses `description`. Pre-1.6.16 every episode row showed an
  empty plot. `description` is now the primary preference;
  `plot` / `overview` remain as fallbacks for forked builds.

- **Drop redundant `Authorization: ApiKey` header on Dispatcharr
  API calls.** Pre-1.6.16 sent both `X-API-Key` and `Authorization`
  "for compatibility." In practice the dual headers switched
  Dispatcharr from unrestricted API-key auth to a user-scoped
  session whose visibility was filtered to a subset of m3u_accounts.
  Some series had providers in accounts the session couldn't see,
  so the episodes endpoint returned `count=0` for them. Curl with
  X-API-Key alone returned the full list. Fixed by sending only
  `X-API-Key`. Verified no regression on `/api/vod/series/`,
  `/api/vod/movies/`, `/api/vod/series/{id}/episodes/`, or
  `/api/channels/channels/`.

- **Episode-list page fetch is now parallel.** `getVODSeriesEpisodes`
  walks pages by reading `count` from the first page and fanning
  out pages 2..N concurrently via `withThrowingTaskGroup`. For a
  1000+ episode series like One Piece on a typical LAN this drops
  from sequential ~2 minutes (10+ round-trips) to ~5–10 seconds.
  Sequential `next`-walk fallback retained for forks that strip
  `count`.

### Added

- **Episode rows now show rich metadata.** A new strip between the
  title and the plot summary displays *Duration · Air Date · ★
  Rating*. Each piece is independently optional — empty fields are
  skipped without leaving dangling separators. Mirrors what
  Dispatcharr's web UI shows in its episode row Duration / Date
  columns plus the per-episode TMDB rating.

- **Episode artwork.** `VODEpisode.posterURL` now reads from
  `custom_properties.movie_image` (the per-episode TMDB still
  URL Dispatcharr stores). Falls back to the parent series's poster
  when an episode has no per-episode metadata, so series with
  sparse Dispatcharr scrape data (Kroll Show, etc.) render the
  series poster across every row instead of blank rectangles.

- **Episode rich fields plumbed through.** `VODEpisode` gained
  `airDate`, `rating`, `tmdbID`, `imdbID`, and `crew` (per-episode
  director from `custom_properties.crew`). Computed `displayRating`
  and `displayAirDate` helpers match the existing VODMovie /
  VODSeries vocabulary. Static `DateFormatter` caching avoids
  per-row allocation on long episode lists.

- **`MovieDetailCache` parity with `SeriesDetailCache`.** Movie
  detail (provider-info enrichment) now uses the same
  `Task.detached` + cache + de-dupe pattern as series. Movies
  open instantly on second visit. Empty-result detection uses the
  no-op-fallback equality check (`result != existing`) so a
  transient enrichment failure doesn't poison the cache.

- **Empty-result safety.** Neither cache stores a result with no
  meaningful data — `SeriesDetailCache` requires non-empty seasons,
  `MovieDetailCache` requires the result to differ from the slim
  preview. A bad fetch never locks the user out of getting real
  data on the next open.

### Improved

- **Diagnostic logs for VOD load path.** New
  `[VOD-Series] fetchStart / fetchOK / fetchNIL / fetchFAIL`,
  `[VOD-Series-Cache] HIT / JOIN in-flight / MISS / STORED /
  NOT storing`, `[VOD-Episodes] start / page=N OK|FAIL /
  parallel fan-out / DONE`, and `[VOD-Movie-Cache]` lines trace
  every step of the fetch. DEBUG-only — compiled out of release
  builds. Combined with the existing `[REMOTE]`/`[MV-*]` log
  vocabulary, the next time anything misbehaves we can pinpoint
  the failure mode from the Xcode console alone.

## v1.6.15 — 2026-04-28

### Added

- **Apple TV: Siri Remote up/down changes channels.** While
  watching a single live stream full-screen, pressing Up on the
  Siri Remote tunes to the next channel (higher number) and Down
  tunes to the previous channel — the IPTV remote idiom users
  expect, inverse of the guide list's scroll direction.
  Multi-tile multiview is unaffected (up/down stays as tile-to-
  tile navigation there). Rapid presses are debounced over a
  300ms idle window so a burst of 5 presses collapses to one
  final stream load instead of cascading through five —
  prevents the red decode-error overlay that appeared when
  successive `loadfile` calls overlapped.
- **Channel info banner.** Brief HUD that appears in the top-
  left whenever a new live stream starts (cold-launch auto-
  resume, channel-row tap, Siri Remote up/down flip). Shows
  channel logo, channel number, channel name, current program
  title, and the airing window/duration when EPG data is
  available. Cross-platform — iPhone, iPad, and Apple TV all
  surface it. Suppressed during multi-tile multiview because
  the user is comparing streams and an overlaid banner would be
  noise.
- **Apple TV chrome lock.** When the player chrome is hidden,
  Up/Down channel-flips the stream. When chrome is summoned
  (Menu/Back), Up/Down switches to walking the chrome controls
  (Options, Record, Add Stream pills) — pressing Menu/Back
  again hides chrome and re-enables channel-flipping. The
  banner appears every stream start regardless; chrome only
  wakes on "fresh" starts (cold launch, row tap), not on
  channel-scroll, so a follow-up press keeps flipping channels
  instead of landing on the Record pill by surprise.

### Improved

- **"Must press down first" focus regression on Apple TV
  fixed.** After the unified-player refactor (1.6.1), expanding
  from the corner mini-player back to fullscreen left focus on
  the tab bar above the player — the first D-pad press just
  woke focus instead of registering as input. Container now
  re-asserts `focusedTileID` on every un-minimize and on every
  tile-id change (covers the channel-flip path that swaps tile
  identity), with a `Task.yield()` so the write lands after
  tvOS's own focus pass instead of being clobbered by it.
- **Thermal stutter instrumentation.** DEBUG-only logs at the
  two cold-launch hot spots — `[MPV-WARMUP]` lines now include
  `thermal=X→Y` (state at warmup entry / exit), and the
  `🎮 Auto-resume: starting…` log includes `thermal=X` at the
  moment playback kicks. Combined with the existing
  `[MV-Thermal]` transitions during multiview, a single grep
  across `nominal|fair|serious|critical` correlates the whole
  launch path. Lets a future stutter report be diagnosed from
  the Xcode console alone.

## v1.6.12 — 2026-04-27

### Added

- **VOD detail page now shows TMDB-rich metadata for Dispatcharr
  servers.** Cast, director, backdrop art, runtime, full release
  date, country, and the IMDB/TMDB IDs all flow into the detail
  page when the Dispatcharr server's upstream Xtream provider has
  populated them. Implementation reads the existing
  `/api/vod/movies/<id>/provider-info/` and
  `/api/vod/series/<id>/provider-info/` actions, with a two-phase
  render: list-time data (poster, title, year, plot, genre)
  appears instantly, the rich payload upgrades the view when the
  network call returns. The `provider-info` endpoint lazy-refreshes
  from the upstream provider on first call (24h server-side
  throttle), so a freshly-added server may take a few seconds per
  movie the first time it's opened. XC and M3U paths unchanged —
  XC was already returning rich metadata via `get_vod_info` /
  `get_series_info`.
- **Trailer and "View on TMDB" links on movie / series detail
  pages (iOS, Dispatcharr API only).** When a movie or series has
  a YouTube trailer key or TMDB ID, pill-style links appear under
  the plot. Trailer opens YouTube in Safari; TMDB opens
  `themoviedb.org/movie/<id>` or `/tv/<id>` depending on item type.
  tvOS hides the links since Apple TV has no system browser.
- **Multiview picker: filter by group, tap to deselect.** The Add
  to Multiview sheet now has a horizontal pill bar of group filters
  matching the Live TV List style. Filter applies to all sections
  (Favorites, Recent, All Channels). Tapping an already-added row
  also now removes the corresponding tile — was previously a no-op
  that forced users to dismiss the sheet, find the tile, and
  remove it from the per-tile menu.
- **Per-playlist VOD toggle in Edit Playlist.** New Content section
  with a "Fetch VOD from this playlist" switch. Lets users with a
  "main + sandbox" Dispatcharr setup keep Live TV from both
  servers but only ingest VOD from one — avoids the multi-minute
  serial fetch the second server would otherwise trigger and the
  cross-server duplicate-merge edge cases that come with it.
- **"Clear iCloud Data" button in Settings → Sync.** Wipes synced
  playlists, preferences, watch progress, and credentials from
  iCloud. Local state on this device is preserved and will replace
  whatever was on iCloud the next time the app pushes. Available
  on iOS and tvOS, with destructive confirmation alert and a
  bottom toast on success.
- **What's New pop-up on first launch after update.** Concise
  release-notes modal with bullet highlights and a link to the
  GitHub release. Two buttons: "Dismiss" (per-version) and
  "Never show again" (permanent per-device opt-out). Fresh
  installs skip the prompt; the upgrade-detection heuristic uses
  existing servers / completed onboarding as the "this device has
  run Aerio before" signal.

### Changed

- **Apple TV Back/Menu button now reveals stream chrome on the
  first press, minimizes on the second** (GH #11). Previous
  behavior either auto-hid chrome or skipped straight to mini
  depending on focus state, which surprised users expecting a
  consistent reveal-then-minimize cycle. Implementation uses a
  `.playerBackPress` notification relay so the outer
  `MainTabView.handleMenuPress` handler — which catches the press
  when focus is on the guide cell rather than inside the player —
  routes through the same chrome-cycle logic as the focused-player
  path. Both code paths converge on `MultiviewContainerView.handleMenuPress`,
  which is now the single source of truth for the Menu stack.
- **Adding a Dispatcharr server no longer hangs on "Loading VOD."**
  The Setting Up flow used to paginate the entire VOD library
  (700+ pages × 25 items on a 17k-movie server) just to display a
  count. Replaced with a single `?page_size=1` probe that reads
  the DRF wrapper's total-count field. Setting Up now finishes in
  ~0.5s regardless of library size. XC servers were never affected
  because their `get_vod_streams` endpoint returns the full list
  in a single round-trip.
- **Server Edit form: API key field renamed "Admin API Key"** with
  clearer footer guidance. The Dispatcharr API needs an admin-tier
  key, which was a frequent first-time-setup confusion.

### Fixed

- **Options panel on tvOS no longer escapes focus** (GH #11
  follow-up). D-pad past Stream Info used to migrate focus down
  into the Record button below; D-pad up could escape into the
  tile above. The chrome below and the tile above are now
  `.disabled(showTVOptions)` while the panel is open, giving the
  panel a true focus trap in every direction. The panel itself
  also got `.focusSection()` for matching parity with PlayerView's
  instance.
- **Options panel chrome stays visible while the panel is open.**
  Previously the 5s auto-fade timer fired regardless of the panel,
  which left the panel hovering over a fully-faded background.
  New `MultiviewChromeState.setPinned(true)` API suppresses the
  timer while the panel is up; releasing the pin on dismiss
  schedules a fresh fade clock from "now."
- **Stranded-panel rescue.** If the user does manage to get the
  panel into a state where its own `.onExitCommand` doesn't fire
  (rare with the focus trap in place, but defensive), Back at the
  outer level now also closes the panel before any other Menu
  branch runs.
- **Multiview first-tile decoder race.** Tapping a channel from
  the picker before libmpv's process-wide warmup completed would
  occasionally leave the first tile in a dropped-frames /
  no-decoder state. The multiview entry path now explicitly waits
  for `MPVLibraryWarmup.waitUntilComplete(timeout: 5.0)` before
  the first `loadfile`.
- **Audio briefly cuts during multiview tile rearrange.** Two
  defensive fixes: (1) `MultiviewLayoutView`'s animation key now
  uses `tiles.map(\.id)` (id-order only) instead of the full
  `tiles` array, so swapping a tile's metadata (e.g. current
  program updates) no longer triggers a spurious layout
  animation; (2) the per-tile `aid` and `mute` mpv writes are
  guarded by per-property caches so identical writes inside a
  debounce window are skipped, removing the audio device underrun
  spam that produced the audible bonk.
- **VODDetailView hero image no longer bleeds past the safe-area
  leading edge** when the backdrop loads. The
  `.aspectRatio(.fill)` + `.frame(maxWidth: .infinity)` chain was
  reporting the image's natural-aspect width (~498pt at 280pt
  height for a 16:9 backdrop) as the view's preferred width,
  which the parent VStack adopted and pushed the entire info
  section past the visible area — clipping the first letter off
  every text row. Hero is now wrapped in a `GeometryReader` that
  explicitly sizes the image to the proposed width.
- **iCloud KVS no longer stores playlist credentials in plaintext.**
  Pre-v1.6.12 servers had passwords / API keys mirrored in iCloud
  KVS for cross-device sync. v1.6.8 introduced iCloud Keychain
  (synchronizable=true) as the proper storage; v1.6.12 stops the
  KVS writes and runs a one-shot launch task to purge any existing
  plaintext entries, leaving Keychain as the only credential-sync
  path. Reads still tolerate legacy KVS entries during the
  migration window.

## v1.6.11 — 2026-04-27

### Fixed

- **App no longer crashes during iCloud sync when the same VOD ID
  exists on more than one server.** v1.6.8 dropped the global
  uniqueness constraint on `WatchProgress.vodID` so two servers
  could keep independent resume positions for content that
  happens to share an ID — but the iCloud KVS merge path was
  never updated to match. It still keyed both the remote and
  local lookups by `vodID` alone via
  `Dictionary(uniqueKeysWithValues:)`, which traps on duplicate
  keys. The first iCloud pull where the user had resume progress
  on the same `vodID` across two servers (very common with two
  Dispatcharr instances pulling from overlapping providers) hit a
  hard crash inside `SyncManager.pullFromCloud` immediately on
  launch — the crash report fingered
  `Dictionary.init(uniqueKeysWithValues:)` →
  `_NativeDictionary.merge` → `_assertionFailure`. Keys are now
  composite (`serverID|vodID`) and dictionary construction uses
  `uniquingKeysWith:` so neither path can ever trap on a duplicate
  again. If two payloads share a composite key (corrupted state
  from a double-push race), the most recently updated wins.
- **Defensive: same crash class fixed in two more places.** The
  channel-sort helper and the favorites-order index were also
  using `Dictionary(uniqueKeysWithValues:)` against data that
  could realistically duplicate (group names from server data,
  favorite IDs persisted in UserDefaults). Both switched to
  `uniquingKeysWith: { first, _ in first }` so a duplicate just
  collapses to the first occurrence's display position instead
  of crashing.

## v1.6.10 — 2026-04-27

### Fixed

- **Plain-HTTP server URLs that iOS refuses to send finally just
  work.** The single biggest fix in this release. Adds a transport
  router (`HTTPRouter` + `NWHTTPClient`) sitting in front of every
  URLSession call. URLSession is still the default — for HTTPS, IP
  literals, and TLDs not on the HSTS preload list. When URLSession
  refuses with a transport-level failure (`-1022`
  ATS-required-secure, `-1004` cannot-connect, `-1200`
  secure-connection-failed, plus a handful of cert codes), we
  silently retry the same request via Network.framework's
  `NWConnection`. Per Apple Developer Technical Support, ATS only
  governs URLSession; Network.framework is explicitly outside that
  enforcement, so the connection actually reaches the server.
  Result: HTTP-only IPTV panels — including ones on
  `.app` / `.dev` / `.page` (HSTS-preloaded gTLDs Google baked into
  Chromium and Apple inherits) and ones URLSession's dynamic ATS
  heuristic blocks for opaque reasons — verify, load channels, fetch
  EPG, and serve VOD without the user ever knowing the bypass
  happened. v1.6.9's auto-HTTPS-upgrade is still in place as a
  separate layer for servers that genuinely prefer HTTPS.
- **HSTS-preloaded TLD panels reach the server on the first
  attempt.** The router hard-routes `http://<host on preloaded
  TLD>` straight to NWConnection (URLSession would always fail
  -1022 on those). Covers the gTLDs Google preloaded as a set —
  `.app`, `.dev`, `.page`, `.new`, `.day`, `.foo`, `.gle`, `.zip`,
  `.mov`, `.bank`, `.insurance`, plus a handful of Google /
  Microsoft / Amazon brand TLDs.
- **Channel list no longer gets stuck on "Connection Error" when
  the actual API calls succeed.** The cold-launch reachability
  probe in `HomeView` was hitting URLSession directly, getting -1022
  on `.pro` / `.xyz` HTTP URLs, and stopping the channel load even
  though every other request was succeeding via the
  router-NWConnection fallback. Probe now goes through the same
  router as the rest, so the probe's verdict matches reality.
- **Series + VOD payloads above 50 MB now load.** Some Xtream
  resellers return ~52 MB on `get_series` (full library, all
  metadata). The NWConnection client's body cap was 50 MB, so those
  fetches failed with `bodyTooLarge`. Raised to 200 MB — comfortably
  covers the worst-case payloads observed while still protecting
  the device from a runaway chunked stream.
- **Recordings now scoped to the active playlist.** "My Recordings"
  used to show every recording in the local database, including
  Dispatcharr server-side recordings from servers the user wasn't
  even using. Now the list, the segment counts, and the
  reconciliation API calls are all keyed off the currently-active
  server (`isActive`). Switch playlists, see different recordings.
  Mirrors how Live TV / On Demand already scope content.
- **DVR tab disappears when the active playlist has nothing to
  show.** Previously the DVR tab appeared whenever *any* server in
  the user's library had recordings — a user on an Xtream Codes
  playlist with a separate (idle) Dispatcharr server registered
  would still see DVR. The tab is now visible only when the
  active server has at least one recording (local or server-side,
  scheduled / recording / completed). Schedule one from Live TV →
  Record and the tab appears; delete the last one and it
  disappears. Switch active playlists and the tab toggles to
  match the new playlist's recordings.
- **Live TV List rows show the currently-airing program, not the
  channel's category.** The row subtitle used to fall back to
  `channel.group` (e.g. "Sports") whenever the lightweight
  per-item `currentProgram` field was nil — which on Dispatcharr
  was the common case before the bulk current-programs API had
  finished its first call. Now the row pulls a live program from
  GuideStore (the same dataset the Guide grid uses) when the
  per-item field is empty, and shows nothing rather than the
  group name when neither source has data.
- **Expanding a channel row now starts with the program currently
  airing.** The "next programs" list filtered out anything whose
  start time was in the past, including the in-progress show — so a
  row expanded mid-program would show the next program over an hour
  in the future with no indication of what was actually on right
  now. The filter now only drops programs that have already ended,
  so the row expands to "what's on now → what's next → what's after
  that".

### Under the hood

- Disabled TCP Fast Open in the NWConnection client. TFO requires
  both client and server kernel support, and several intermediate
  firewalls drop SYN+data packets — exactly the silent-stall pattern
  early v1.6.10 builds exhibited as "Connection timed out" 20s after
  every API call.
- Removed the playlist name from the "Setting Up" loading screen on
  initial launch. Showing `allServers.first?.name` was misleading
  on multi-server installs (the displayed playlist was arbitrary)
  and adds nothing the "Setting Up" headline doesn't already
  convey. The `serverName` parameter on `ServerSyncView.Mode` was
  also dropped along with it.

## v1.6.9 — 2026-04-27

### Fixed

- **Adding an Xtream Codes server with an `http://` domain URL now
  works.** Multiple users reported that Test Connection failed with
  "The resource could not be loaded because the App Transport
  Security policy requires the use of a secure connection" against
  domain-based HTTP URLs (e.g. `http://reseller.example.pro`),
  while IP-literal HTTP URLs (e.g. `http://192.168.1.10:9191`)
  worked fine. Root cause: iOS bakes Chromium's HSTS preload list
  into every release, and HSTS-preloaded domains get force-upgraded
  to HTTPS at the OS layer **regardless** of the app's
  `NSAllowsArbitraryLoads` exemption — Apple won't let an app
  override HSTS via Info.plist. IP literals don't match HSTS rules
  (which are domain-scoped) so they connected as typed.
  Two fixes layered together:
  1. **Comprehensive ATS exemption** in Info.plist —
     `NSAllowsArbitraryLoadsInWebContent` and
     `NSAllowsArbitraryLoadsForMedia` added on top of the existing
     `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`. This
     closes any auxiliary path that was being gated separately
     from the global flag.
  2. **Auto-HTTPS-upgrade on verify** — when Test Connection gets
     `NSURLErrorAppTransportSecurityRequiresSecureConnection`
     (-1022) against an `http://<domain>` URL, the verify path
     transparently retries with `https://`. Most reseller backends
     serve both schemes (Cloudflare front-ends, automatic Let's
     Encrypt) so the HTTPS retry succeeds. On success the upgraded
     scheme persists to `baseURL` so every subsequent request —
     channels, EPG, VOD, playback — uses the working scheme. IP
     literals are deliberately exempted from the upgrade so
     local-only servers that only serve HTTP keep working.
  Covers Xtream Codes, Dispatcharr, and M3U playlist verification.

### Under the hood

- Cleaned up an unused `hasEPG` local variable in the multiview
  record-sheet path that was generating a build warning. No
  behavioural change.

## v1.6.8 — 2026-04-25

### New

- **Local DVR — "Record from Now" on every platform.** Tap Record on
  any currently-airing program (Live TV list long-press, EPG cell
  long-press, or the Record pill in the player overflow) and Aerio
  starts capturing the stream to local storage immediately. Recording
  auto-stops at the program's end time, lands in **Settings → DVR →
  My Recordings** under "Completed", and plays back from disk by
  tapping the row. Works on iPhone, iPad, Mac Catalyst, and Apple TV.
  Local DVR is foreground-only by design — Aerio doesn't run
  background tasks for recording, so the existing yellow "Keep AerioTV
  open" warning still applies. Future-scheduled recordings continue
  to route to Dispatcharr server (always running, always reliable).
- **Server recording playback in My Recordings.** Tapping a completed
  Dispatcharr server-side recording now plays it back via the
  `/api/channels/recordings/<id>/file/` endpoint with full scrubbing
  + transport controls. Previously the row was tappable but a no-op.
- **Settings → Multiview submenu** with three new preferences:
  - **Audio Focus Indicator** — choose how the audio-active tile is
    marked: a center speaker icon (default, current behavior), a
    persistent muted-gray border around the active tile, or an
    accent-colored border that fades with the rest of the chrome
    after 5 s of inactivity.
  - **Padding Between Tiles** — toggle an 8 pt gap between tiles for
    a cards-on-a-grid look. Off by default keeps the legacy flush
    layout.
  - **Tile Corners** — Square (default) or Rounded (12 pt). Pairs
    nicely with padding-on for a polished card aesthetic.
- **"Currently Watching" / "Watched" pill on series episode rows.**
  When you've started or finished an episode of a series, the row in
  the series detail view now shows a clear status pill plus a thin
  progress timeline showing how far in you were. Saves a guess-and-
  check trip into the player to find your spot. iPhone / iPad pills
  are subtle; Apple TV pills are 50 % larger so they're legible from
  10 ft. Synced across devices via iCloud — start an episode on
  iPhone, pick it up on Apple TV from the Top Shelf or the series
  detail page.
- **Per-playlist EPG cache refresh.** Each playlist's detail page
  (Settings → tap a playlist) now has a "Refresh EPG Data" action
  that clears just that playlist's cached guide data and reloads it
  from the server. Solves the rare "guide cells render as 1-pixel
  slivers" symptom from a corrupted cache without affecting your
  other playlists. Removed the global EPG-purge action that briefly
  lived in Appearance after the Guide Display merge.
- **Cross-platform LAN switching.** Aerio now does direct local-
  server reachability probing on every platform (formerly Apple TV
  only). On Mac Catalyst — where Apple's Wi-Fi SSID API doesn't
  return reliable values even with full entitlements — and on
  Ethernet-connected iPad / Mac (where there's no SSID at all),
  the LAN-vs-WAN switch now works correctly without requiring SSID
  detection. CoreWLAN fallback added for true Mac Catalyst builds.
- **Bolder channel numbers** in both Live TV List and Guide views,
  iPhone / iPad / Apple TV / Mac. Easier to read at a glance,
  especially in dense lists.

### Changed

- **Settings → Guide Display merged into Settings → Appearance.**
  Category-color toggles, palette picker, and the master "Color
  Programs by Category" switch all now live alongside Theme and
  Display Scale in one consolidated visual-customization page. The
  separate Guide Display page is gone — every setting it had now
  lives in Appearance instead.
- **Multi-server VOD watch progress no longer collides.** When you
  use the same Dispatcharr movie/episode ID on two servers (e.g.
  two Dispatcharr instances that happen to share a numeric ID),
  resume positions are now tracked independently per server.
  Previously, watching the same vodID on a second server silently
  overwrote the first server's saved position. Composite uniqueness
  enforced via `(vodID, serverID)`. Existing data preserved — first
  save with a server ID adopts pre-v1.6.8 rows.
- **Top Shelf episode deep-links work cross-device.** Synced
  WatchProgress entries now carry their parent `seriesID` across the
  iCloud-sync boundary, so an episode you started on iPhone surfaces
  on the Apple TV Top Shelf and tapping it lands on the series
  detail page (not a dead-end episode URL).
- **iCloud Keychain credential migration.** Server passwords and API
  keys now sync via iCloud Keychain (end-to-end encrypted) instead
  of iCloud KVS plaintext. Silent migration on first launch — no
  re-auth prompts, no setup change. v1.6.7 devices stay working
  during the cross-version window because v1.6.8 still pushes
  plaintext to KVS for backward compatibility (scheduled for
  removal in a future release).
- **Theme switching now updates everything reliably.** Switching
  between themes used to leave stale-colored elements (subtitles,
  section headers, info-row labels) behind on List-backed Settings
  pages until you closed and reopened them. Resolved with theme-keyed
  `.id()` on the Settings list + reactive `sectionHeaderStyle` +
  observing `ThemeManager` from every Settings sub-page. iOS, iPad,
  Mac Catalyst, Apple TV.
- **Tappable Settings → Playlist row on Apple TV** now offers "Use
  This Playlist" alongside Edit / Delete in the long-press menu so
  you can switch active playlists without going through Edit.
- **Privacy hardening for debug logs.** The credential sanitizer that
  redacts secrets in debug-log output now covers more vectors:
  Xtream `?username=…&password=…` query params, `Authorization` /
  `X-API-Key` / `X-Plex-Token` headers, JWT tokens in JSON response
  bodies, and Emby `Token="…"` fragments. Routed through every log
  path, not just the network logger.
- **Forks / open-source builds:** team ID and bundle-ID prefix
  extracted into a dedicated `Config/Aerio.xcconfig` file. Edit one
  file to fork; no more pbxproj surgery. Existing build is
  byte-identical to before the change.

### Fixed

- **App stops wasting battery during locked-screen playback.** When
  the iPhone screen locked during live playback, the hardware video
  decoder lost its session, the AVSampleBufferDisplayLayer flipped
  to FAILED, and the render loop continued shipping ~50 frames per
  second into a dead pipeline for the entire duration of the lock
  — burning CPU + battery for nothing. Fix: detect the FAILED state
  in the render loop while in background, auto-pause mpv, let the
  existing foreground handler flush + resume on unlock. Audio in
  background follows your existing policy (Audio Only / AirPlay / PiP
  modes are unaffected).
- **Channel placeholder URLs no longer auto-linkify.** The "EPG
  Source" field in Edit Playlist showed `https://example.com/xmltv.xml`
  as a clickable blue underlined link on iOS and Mac Catalyst because
  SwiftUI's default `Text` initializer parses arguments as
  Markdown. Switched to `Text(verbatim:)` so it renders as
  ordinary placeholder text.
- **`MPMediaItemArtwork` deprecation warning silenced properly.**
  Wrapped the legacy `init(image:)` call in an Objective-C shim
  with `#pragma clang diagnostic` markers, eliminating the warning
  without resorting to the closure-based init that triggered
  `_dispatch_assert_queue_fail` on lockscreen artwork updates.
- **Apple TV: Syncing-indicator focus halo no longer screams white.**
  The top-left "Syncing… · select for info" badge previously got
  the default tvOS bright-white focus chrome, which dominated the
  screen while focused. Now uses the same gentle accent-tinted
  scale + shadow as every other tvOS row.
- **Categories no longer concatenate on Program Info pills.** The
  XMLTV parser correctly splits multiple `<category>` tags into
  distinct tokens (was rendering as e.g. "EpisodeSeriesRealityLaw").
  Also picks up Codex's whitespace-trim fix.
- **Channel numbers on the parent List view tile now appear** for
  Dispatcharr playlists even before visiting the Guide. Same fix
  also surfaces the Record action in the long-press menu and the
  player overflow menu, both of which previously hid until EPG
  metadata had been loaded by the Guide view.

### Under the hood

- Cleaned `build/` directory: 63 GB → 1.5 GB by deleting 28
  redundant `DerivedData_*` directories and stale staging dirs from
  earlier agent runs. All shipped IPAs and dSYM-bearing xcarchives
  preserved.

## v1.6.5 — 2026-04-22

### Fixed

- **Apple TV: Menu button in a Settings subview now pops back to the
  Settings root instead of dumping to the Live TV tab.** Affected
  every pushed subview — Appearance, Guide Display, Network, DVR,
  Developer, the per-playlist detail page, and DVR → My Recordings.
  Root cause: MainTabView's `.onExitCommand` on the outer TabView
  consumes Menu before the inner NavigationStack — or any per-
  destination `.onExitCommand` — can react, so the Menu handler fell
  through to its "switch to Live TV" fallback regardless of how deep
  the user was inside Settings. Fixed with the same state-binding
  pattern the VOD detail view uses: SettingsView mirrors
  `navPath.count > 0 || classicPushStack.depth > 0` up to MainTabView
  via `isSettingsSubviewPushed`, MainTabView flips
  `settingsPopRequested` on Menu, and SettingsView pops the innermost
  level (classic stack first, LIFO; then navPath). Repeated Menu
  presses peel the Settings hierarchy off one level at a time;
  Menu at the Settings root falls through to the existing "switch to
  Live TV" behaviour. Classic `NavigationLink(destination:)` pushes
  (playlist detail, DVR → My Recordings) opt into the pop via a new
  `.trackedAsClassicSettingsChild()` modifier so they behave
  identically to the navPath-based pushes.

## v1.6.4 — 2026-04-18

### New — EPG category colors (Jellyfin-style)

- **Guide cells now tint by program category** — Sports gets indigo,
  Movies gets deep purple, Kids gets light blue, News gets green,
  matching the Material Design 600 palette Jellyfin uses for its
  own live-TV guide. Focused and currently-airing cells get a
  brighter tint of the same hue so the "now playing" signal stays
  readable; unmatched categories fall back to the existing neutral
  white/accent tint.
- **Settings → Network → Guide Display toggle** ("Color Programs by
  Category") lets users turn the feature off and go back to the
  flat neutral look. Default: on.
- The category matcher handles real-world messy EPG strings —
  splits on `/ , ;`, casefolds, matches substrings against aliases
  that cover English plus common German / Spanish / French terms
  ("Fußball", "Noticias", "Jeunesse", etc.). Multi-category
  programs like "Sports / Football" resolve via a Kids → Sports →
  News → Movie priority order, matching Jellyfin's behaviour.
- Currently active for **M3U + XMLTV** playlists, which are the
  only EPG source type whose responses Aerio already parses the
  `<category>` element from. Dispatcharr and Xtream Codes don't
  currently surface categories in their EPG API responses;
  support for Xtream's `genre` field is tracked as a follow-up.

### Fixed

- **Dispatcharr Dummy EPG entries now appear in the guide.**
  Dispatcharr's built-in Dummy EPG feature (regex-driven synthetic
  program entries for channels without real EPG data) tags every
  generated program with `tvg_id = str(channel.uuid)`. Aerio was
  previously matching incoming EPG programs to channels by
  `tvg_id` (string) or `channel` (integer ID) only, so Dummy EPG
  programs were silently dropped for every channel — those
  channels appeared blank in the guide even though Dispatcharr's
  own web UI showed them. Fix: added a third matching key,
  `channel UUID string → display ID`, which routes Dummy EPG
  programs into the right row. `ChannelDisplayItem` grew a
  matching `uuid: String?` field that's populated for Dispatcharr
  channels and left `nil` for XC / M3U (which have no
  server-side UUID concept).
- **"Failed to parse server response" error during Test Connection**
  now produces an actionable message instead of dumping the raw
  HTML body of the Dispatcharr login page. When every verification
  probe comes back as `text/html`, the message explicitly calls
  out the three real-world causes: (1) API key missing or wrong,
  (2) URL points at the web port but not through `/api` (e.g., a
  reverse proxy stripping the prefix), (3) wrong port. A
  401/403-only case gets its own "API key was rejected" message,
  and mixed failures get a compact one-line diagnostic with the
  last status + content-type + a 160-character body preview
  (rather than ~800 characters of `<!doctype html>`).
- **Home WiFi warning on iOS** now tells the user what to do
  rather than asking them to open Xcode. Previous text:
  "Verify the 'Access WiFi Information' capability is enabled in
  Xcode → Signing & Capabilities." New text: "To detect your
  Home WiFi, grant Aerio Location access: open the iOS Settings
  app → Privacy & Security → Location Services → Aerio → choose
  'While Using the App' and enable Precise Location." The
  capability and the `NSLocationWhenInUseUsageDescription` string
  both ship with the app — the missing piece on the user side is
  always Location permission, which the iOS system requires on
  top of the capability before `NEHotspotNetwork.fetchCurrent`
  will return the SSID.
- **Auto-PiP on swipe-home restored (GH #4).** Single-stream
  playback: swiping home now re-engages Picture-in-Picture
  automatically, matching v1.6.0 behaviour. The v1.6.1 Unified
  Player refactor silently dropped this — the PiP controller
  was only built lazily on the first manual tap and
  `canStartPictureInPictureAutomaticallyFromInline` was never
  set. Fix: solo-tile paths eagerly build the
  `AVPictureInPictureController` in `makeUIViewController` and
  opt into automatic engagement. A `pipAutoEligible` Coordinator
  flag guards against the `vid=no` GPU-safeguard firing mid-
  engagement and starving iOS of frames.
- **Return-to-app after PiP no longer leaves a black screen
  (GH #4).** The background-entry `vid=no` safeguard wasn't
  paired with a matching `vid=auto` on foreground entry, so
  mpv came back with video decoding disabled and the user had
  to restart the channel. `willEnterForeground` now explicitly
  re-enables video and undoes the defensive pause only when
  this app owned it.
- **Background-audio discipline.** Audio now keeps playing with
  the app closed only when the user picked Audio Only, PiP is
  engaged, or AirPlay is routing audio to another device.
  Everything else pauses mpv cleanly on swipe-home so the app
  stops making sound when the user has just navigated away.
- **Audio Only mode now populates the lockscreen and Dynamic
  Island with the channel name and logo.** Flipping Audio Only
  and swiping home previously left the lockscreen blank — the
  `AudioSessionRefCount` 0→1 activation could silently fail on
  cold launch (OSStatus -50) and never be retried, and iOS
  won't publish `MPNowPlayingInfoCenter` info unless the
  session is in `.playback` at publish time.
  `NowPlayingBridge.configure()` now defensively re-applies
  the category + `setActive(true)` and registers remote-
  control events synchronously before writing the now-playing
  dict. Channel artwork is pre-decoded to a 512-pt thumbnail
  and published via the deprecated `MPMediaItemArtwork(image:)`
  init — the modern closure-based init crashes with
  `_dispatch_assert_queue_fail` inside iOS's Media framework
  on full-resolution source images; the thumbnail + no-closure
  combination sidesteps the crash.
- **VOD group filter now reflects Dispatcharr's enabled
  categories and actually filters (GH #1).** Two bugs in one
  fix. Before: the Manage Groups sheet listed every one of
  the ~467 categories Dispatcharr had ever seen from the
  provider, including disabled / orphaned / foreign-language
  buckets that carry no fetchable content; and the filter
  predicate compared selected categories against each movie's
  `categoryName`, which was comma-split from the `genre`
  string and therefore almost never matched a real category
  name — so toggling a group either did nothing or hid
  everything. After: the Manage Groups sheet filters by
  `m3u_accounts[].enabled == true` so only groups you've
  enabled in Dispatcharr's admin UI appear; each VOD title is
  fetched per-enabled-category via Dispatcharr's
  `?category=<name>` filter and tagged with its real
  Dispatcharr category name; first-enabled-category-wins
  dedupes titles that belong to multiple enabled categories.
  Covers Movies and Series. Xtream Codes path unchanged.
- **Setting-up loading stages now center on Apple TV.** The
  progress card on the onboarding / initial-launch sync
  screen was stretching edge-to-edge on the ~1920pt tvOS
  display, leaving the "Loading EPG / VOD / DVR / preferences"
  rows pinned to the far left and visually disconnected from
  the centered logo and title above. Constrained to 720pt
  max width on tvOS so the card centers cleanly. iPhone /
  iPad unchanged — their screen isn't wide enough for the
  stretch to look wrong.
- **Apple TV: focus now returns to the guide after
  minimizing a live stream to the corner mini-player.**
  Previously, pressing Menu on the full-screen player shrunk
  playback to the corner but focus stayed stuck on the mini
  tile, so D-pad wouldn't navigate the guide until the user
  mashed a direction to nudge focus across. The
  `.forceGuideFocus` notification handler was writing
  `@FocusState = firstChannel.id`, which tvOS routinely
  rejected because its focus engine had already committed
  to the mini tile (spatial-search nearest focusable target)
  by the time the write landed. Replaced with Apple's
  documented imperative focus-reset API:
  `@Environment(\.resetFocus)` + `@Namespace` on the guide
  scope, `.prefersDefaultFocus(true, in: ...)` on the top
  channel row, and `resetFocus(in: ...)` called from the
  notification handler after a 400ms delay (covers the
  350ms minimize spring animation). Both the list-style
  guide and the grid-style EPG view got the same
  treatment.

### Changed

- **Picture-in-Picture is now auto-only.** The overflow-menu
  PiP button has been removed. Swipe home to engage PiP; tap
  the ⤢ maximize icon on the floating window to return.
  Removing the toggle eliminates a footgun where users turned
  it off and then wondered why swipe-home killed their stream,
  and also matches v1.6.0's default behaviour.
- **On Demand tab now hides dynamically.** A server that returns
  zero movies and zero series (e.g., a pure live-TV M3U, or a
  Dispatcharr instance with no VOD ingested) no longer shows a
  permanently empty On Demand tab. The tab animates in the
  moment the VOD library loads and out the moment it empties,
  matching the behaviour of the Favorites and DVR tabs. If the
  user is on the On Demand tab when the library drains (e.g.,
  they switch to a live-only server), focus redirects to Live TV
  so they aren't stranded on a missing tab.

## v1.6.3 — 2026-04-18

### Fixed

- **tvOS Siri Remote D-pad could not focus certain program cells
  in the EPG guide.** Specific cells (a small set on certain
  channels at certain times) rendered correctly but were
  permanently skipped by the focus engine, making them
  unreachable. Root cause: each
  program cell had both a `TVPressOverlay` (UIKit-backed
  `PressCatcherView` that is the primary focusable element) AND a
  SwiftUI `.focused($focusedProgramID, equals: prog.id)` binding.
  The `TVPressOverlay` docstring (`Shared/TVPressGesture.swift`)
  explicitly warns against this: "the overlay UIView is the
  focusable element — having both would create two competing
  focus targets." With two focus candidates per cell, the tvOS
  focus engine routed inconsistently depending on layout position,
  scroll offset, and ZStack order — which is why the symptom was
  specific cells rather than all or none. The fix removes the
  redundant `.focused(...)` binding on each cell, leaving
  `TVPressOverlay` as the sole focusable element on tvOS (matching
  the working pattern already used in `ChannelListView`).
- **iPadOS / macOS guide grid click routing on cells that
  overlapped the channel column.** The guide row was a `ZStack`
  with `programRow` extended to the full timeline width and the
  channel column drawn on top at `zIndex(0.5)` with an opaque
  background. Program cells clamped to `windowStart` had their
  UIView frames extending *behind* the opaque channel column,
  which caused hit-test routing inconsistencies — some cells
  worked, others did not. Restructured to an `HStack` layout with
  the channel column and program area as siblings (mirroring the
  pinned time-header structure). Program cells can no longer
  extend into the channel column's UIView bounds.

### Changed

- **`.forceGuideFocus` notification (fired when the mini-player
  minimizes)** now routes to `focusedChannelID` (first channel)
  and lets tvOS's spatial focus search pick the nearest program
  cell. Previously it set `focusedProgramID` directly to the
  first channel's live program; that path was removed alongside
  the dual-focus-target cleanup. The user lands within one D-pad
  press of the live cell, which is close enough that the prior
  precision isn't missed.

## v1.6.2 — 2026-04-18

### Fixed

- **EPG prefetch no longer hammers the server on the guide grid
  view.** The per-row prefetch path in `EPGGuideView`
  (`prefetchIfNeeded`, fired from every guide row's `.onAppear`)
  was bypassing the cache populated by the bulk
  `/api/epg/grid/` request and firing one redundant per-channel
  `/api/epg/programs/?tvg_id=X` request per row. On a Dispatcharr
  host with 150 channels, opening the guide once produced a
  single bulk call followed by ~150 API-key-authenticated
  per-channel calls in parallel. The fix adds a memory-cache
  check at the top of `prefetchIfNeeded`: if the channel already
  has any program ending more than 30 minutes in the future, the
  network call is skipped and the channel is marked as fetched
  so it won't re-check on subsequent `.onAppear`s. Net effect:
  Dispatcharr guide mounts drop from `1 + channelCount` requests
  to `1`. Channels with no tvg_id match still fall through to
  the existing per-row fetch. Applies equally to Xtream Codes
  (per-channel prefetch now also skips after the initial batched
  bulk pass). Only the guide view was affected — `ChannelListView`
  already had cache-aware prefetch via `EPGCache.shared.get` and
  is unchanged. Issue surfaced most visibly when running the iPad
  app on macOS because macOS defaults to the guide grid rather
  than the list view that iPhone users see.

## v1.6.1 — 2026-04-18

### New — Unified Playback

- **One playback path for single-stream and multiview.** Single-stream
  is now `tiles.count == 1` inside the same container used for
  multiview. Tapping `+` to add a second stream no longer unmounts
  the player and rebuilds a fresh mpv handle; the existing stream
  keeps decoding while the new tile comes up. Eliminates the 1.5–6s
  main-thread stall that previously happened on the N=1→N=2 swap
  (worst case on tvOS with thermal state `.serious`) along with the
  memory doubling that followed.
- **tvOS Mini Player restored on the unified path.** Press Menu
  twice during single-stream playback to shrink to a 400×225 corner
  window. The stream keeps playing; D-pad navigates the guide
  underneath; Play/Pause expands back to full-screen; Menu on the
  guide stops playback cleanly.
- **iPad Move Mode for tile rearrangement.** Long-press a tile →
  "Move Tile" → orange ring appears + banner prompts for a target
  → tap another tile to swap, or tap the source tile again to
  cancel. Replaces the drag-and-drop gesture, which was silently
  starving the long-press context menu on iPad via UIKit's
  `UIDragInteraction` requireToFail relationships.
- **Record from the player chrome.** A dedicated Record button in
  the chrome overlay presents the DVR schedule sheet pre-populated
  with the audio tile's currently airing program. Available on
  iPad and tvOS chrome.
- **Focus indicator redesign on tvOS multiview.** Focused tiles now
  show a center speaker icon plus a channel-name pill instead of
  the previous ring + big scale combination. The audio tile is
  always highlighted; other tiles highlight on focus. Reads more
  clearly on the living-room couch and no longer fights the system
  focus halo.
- **Double-press Select for fullscreen-in-grid on tvOS.** One
  Select takes audio on that tile (existing behaviour). Two
  presses within 400ms promote the tile to fill the grid area
  while every other tile freezes. Menu collapses back to the grid.
- **Menu on the Live-TV tab scrolls the guide to top** when there's
  nothing playing — same for the EPG grid view. Previously Menu on
  an idle Live-TV tab did nothing.

### Fixed — Performance and Stability

- **Cold-launch first-channel latency.** `MPVLibraryWarmup` creates
  and destroys a throwaway mpv handle during app startup, and the
  EAGL context is pre-warmed in the same pass. Tap-to-first-frame
  on a freshly launched process dropped from ~2.1s to comparable-to-
  warm times on LAN. Instrumented via `[MPV-WARMUP]` log lines.
- **503 / `MPV_ERROR_LOADING_FAILED` retry storm** when opening
  multiview with multiple channels from the same origin. Each tile
  now retries with exponential backoff plus jitter so nine
  concurrent tile initializations don't line up and stampede the
  upstream.
- **Unpause snaps to the live edge.** Live streams that had been
  paused (e.g. while the channel picker was open) now issue a
  `loadfile replace` on resume instead of continuing from the
  frozen position. Matches user expectation for live TV.
- **Spurious "Decoder unavailable" overlays eliminated.**
  `MPV_END_FILE_REASON_STOP` from our own reload (the live-edge
  snap above) was being caught by the premature-EOF path and
  triggering a retry cascade that ended in `onFatalError`. Now
  guarded at the top of `handleEndFile`.
- **2×2 multiview right-swap now lands on the bottom-right tile**
  instead of the top-right. `MultiviewGridMath.physicalNeighbor`
  uses a strict >1pt perpendicular overlap check so tiles that
  only share an edge don't register as overlapping.
- **Audio focus indicator at N=9** was regressing to no visible
  feedback. Root cause was `.focusable(Bool)` on the tile Button
  disrupting `@Environment(\.isFocused)` propagation into
  `MultiviewTileButtonStyle`. Modifier removed; focus reads through
  correctly across all grid sizes.
- **iPad player chrome clearance from the status-bar clock.** The
  top bar now applies 48pt of top padding. `.safeAreaPadding` and
  `.safeAreaInset` both returned zero insets because the parent
  `MultiviewContainerView` calls `.ignoresSafeArea()` at mount,
  zeroing safe-area values for descendants.
- **Per-tile `×` close removed on iPad.** The inline button was too
  easy to hit during audio-focus taps; Remove is now a long-press
  menu action instead, matching tvOS.
- **Menu-button double-press correctly exits the mini-player** and
  fully stops the session. Previously the mini path could leave a
  decoding mpv handle behind because the `.disabled` gate on the
  tab content view blocked focus from escaping to the guide.

### Fixed — Guide and Navigation

- **EPG grid now respects the "EPG Window" Settings picker** on all
  platforms. The grid had been hardcoded to 3 hours forward
  regardless of what the user selected; it now reads the same
  `epgWindowHours` UserDefault that the EPG fetch layer uses, so
  36/48/72/All picks show the full range.
- **Horizontal scroll restored on the iPad EPG grid.** The previous
  UIKit pan-gesture bridge (`HorizontalPanGestureView` with a
  passthrough view returning `nil` from `hitTest`) had been
  silently broken — UIKit only routes touches to gesture
  recognizers whose attached view hit-tests to the touch. Replaced
  with a SwiftUI `.simultaneousGesture(DragGesture())` that
  coexists correctly with the outer vertical `ScrollView`.
- **On Demand Movies/Series pill no longer overlaps the iPadOS 18
  floating TabView capsule.** The pill row used to be attached via
  `.safeAreaInset(edge: .top)` on the inner MoviesView, which
  placed it behind the translucent floating tab bar on iPad. It's
  now a VStack sibling of the media grid with a size-class-aware
  72pt top padding that only applies on full-width iPad.
- **iPad long-press context menu on multiview tiles fires reliably.**
  The coexisting `.onDrag` installed a `UIDragInteraction` whose
  built-in long-press recognizer was winning the gesture race. Drag
  removed; a dedicated Move Mode action replaces it (see above).

### Developer experience

- **Live Apple TV log capture** via `Scripts/capture-appletv-logs.sh`.
  Pipes `xcrun devicectl device process launch --console` stdout to
  `~/Library/Logs/AppleTV-Aerio.log` through a `script(1)` PTY wrap
  so `--console` actually captures app stdio. Preserves the Xcode
  Cmd+R workflow unchanged.
- **Per-phase mpv timing** emitted as `[MPV-PHASE]` and `[MV-TIMING]`
  log lines. Covers `mpv_create`, `mpv_initialize`, EAGL context
  creation, render-context creation, and post-init property apply
  times. Paired with a one-line per-tile summary including process
  RSS, fd count, thermal state, and low-power-mode flag.
- **Playback Engine toggle** in Developer Settings. Unified
  Playback is now the default; the legacy PlayerView path remains
  as an opt-in fallback for testing.
- **`PlaybackDiagnostics`**, **`ProcessMetrics`**, and
  **`RemoteInputLogger`** utility modules added for ongoing freeze
  / resource-pressure / focus-event observation.

## v1.6.0 — 2026-04-16

### New — Multiview (iPadOS and tvOS)

- **Watch up to 9 live channels simultaneously.** Enter multiview from
  any playing channel — on iPad, tap the new `rectangle.split.2x2`
  button in the player top bar (next to AirPlay); on tvOS, open the
  Options panel and select "Enter Multiview". The currently-playing
  channel becomes the seed tile, and further channels are added one
  at a time from a Favorites / Recent / All Channels picker.
- **Dynamic grid layouts** adapt as tiles are added — 1 full, 2-across,
  3 asymmetric (1 big + 2 stacked), 2×2, 5 asymmetric (1 big + 4
  small), 3×2, 7 with centered bottom tile, 3×3 with bottom-center
  gap, full 3×3. No static grid picker — just keep adding.
- **Audio follows content, not position.** Only the most recently
  added tile produces sound; all other tiles stay muted. Tap (iPad)
  or Select (Siri Remote) any tile to move audio to it. The audio
  tile is marked with a small speaker badge in the top-left corner.
- **Drag-to-rearrange.** iPad supports long-press + drag between
  tiles; tvOS offers a "Move Tile" action in the per-tile menu that
  enters a relocate mode (amber ring) where the Siri Remote arrows
  swap the tile with its physical neighbor and Select commits.
- **Per-tile close.** iPad shows a small `×` in the top-right of each
  tile; tvOS users long-press Select to open the per-tile menu with
  a "Remove" action.
- **Per-tile full-screen within grid** — promote any tile to fill the
  grid area while the others keep decoding in the background. Menu
  button / Esc collapses back to the grid.
- **Per-tile audio and subtitle track menus** when the stream has
  multiple tracks.
- **Picture-in-Picture inside multiview (iPad).** Only the audio tile
  continues playing in the PiP window; all other tiles pause via
  mpv's `pause` property to conserve CPU, GPU, and network.
  Returning to the grid resumes all tiles within a couple of seconds.
- **Performance warning at the 5th tile.** First attempt to add a
  5th tile surfaces a one-off "performance may degrade" confirmation;
  thereafter the warning is throttled for 2 hours so frequent users
  aren't nagged.
- **Hard cap at 9 tiles** with a "max" pill in the transport bar and
  a greyed-out Add button.
- **Thermal watchdog.** When `ProcessInfo.thermalState` reaches
  `.critical`, a banner appears at the top of the grid and new tile
  additions are refused until the device cools.
- **iPad keyboard shortcuts.** ⌘1..⌘9 move audio to tile N, ⌘N opens
  the add sheet, ⌘F toggles fullscreen on the audio tile, ⌘W exits
  multiview entirely.
- **Per-tile decode-error overlay.** If mpv's failover chain
  exhausts on a specific tile, a red "Decoder unavailable" card
  replaces that tile's video with a Remove button — the other tiles
  keep playing.
- **Slim transport bar.** Bottom strip uses a flat black background
  with a compact `N / 9` counter, `+` to add, and `×` to exit — no
  wasted vertical space.
- **VoiceOver labels** on every tile, badge, and transport control.

### Fixed — Multiview plumbing

- **Audio-session ref-counting.** A process-wide refcount wraps
  `AVAudioSession.setActive(...)` so multiple concurrent mpv
  coordinators (multiview tiles, or a primary player + PiP) don't
  race on the shared session. `setActive(true)` only fires on 0→1
  and `setActive(false)` only on N→0.
- **Idle-timer ref-counting.** Same treatment for
  `UIApplication.isIdleTimerDisabled` so the screen doesn't fall
  asleep while any mpv coordinator is alive.
- **NowPlayingBridge gating.** Only the authoritative coordinator
  (single-stream player, or the audio tile in multiview) writes to
  `MPNowPlayingInfoCenter` — prevents multiview tiles from
  overwriting each other's lockscreen metadata.
- **URL scheme allowlist** on stream resolution — only `http`,
  `https`, `rtmp`, `rtmps`, and `rtsp` reach mpv. Defends against a
  malicious M3U entry pointing at `file://` or other local/exotic
  schemes.
- **`Text(verbatim:)` hardening** on every server-controlled string
  rendered by multiview UI (channel names in dialogs, mpv error
  bodies, audio/subtitle track labels) so Markdown-style injection
  like `[Click](evil://)` cannot render as a tappable link.
- **Mode-transition audio bounce** eliminated via a 250ms refcount
  float during `enterMultiview`, which keeps the audio session
  active through SwiftUI's swap from single-mode PlayerView to
  MultiviewContainerView.

### Added — infrastructure

- `MultiviewStore`, `MultiviewTile`, `PlayerSession`, plus
  `MultiviewGridMath` with pure rect-shape math per N (unit-testable).
- `AudioSessionRefCount`, `IdleTimerRefCount` serialised helpers.
- `RecentChannelsStore` — FIFO ring (max 20) of recently-played
  channels, persisted to UserDefaults, powers the "Recent" section
  of the add-channel sheet.
- Extensive `[MV-*]`-prefixed DebugLogger trace points for
  diagnosing issues on device (filter Console by `[MV-` to isolate
  multiview events; redaction rules ensure URLs and auth headers
  are never logged).

## v1.5.0 — 2026-04-16

### New

- **Commercial skip (Comskip).** Dispatcharr server-side users can enable
  commercial detection and removal when scheduling a recording. The toggle
  appears in the Record sheet whenever the destination is
  "Dispatcharr server"; processing runs on the server after the
  recording completes. Also exposes a new `applyComskip(id:)` API call
  for triggering it on existing recordings.
- **DVR auto-discovery.** Recordings scheduled from the Dispatcharr web
  UI (or from another device) now appear in AerioTV's DVR tab
  automatically. A reconciliation loop runs every 2 minutes at the
  tab-bar level, so the DVR tab lights up without the user having to
  open it first.
- **Recordings accessible via Files app (iOS).** Local recordings can
  now be browsed and exported from the iOS Files app under
  "On My iPhone → AerioTV".
- **Refreshed app icon** across all 15 sizes to match the current
  AerioTV branding.

### Fixed — iOS

- Long-pressing a channel card in the list view and selecting "Record
  from Now" now actually presents the record sheet. The presenter was
  previously scoped to the expanded guide panel only, so the sheet
  silently refused to appear when the card was collapsed.

### Fixed — tvOS (major UI overhaul)

- **Long-press in Guide / DVR / upcoming-schedule rows now fires
  precisely at 0.35s** via a new UIKit-backed press detector
  (`Shared/TVPressGesture.swift`). SwiftUI's `LongPressGesture` on tvOS
  fires on press release rather than at `minimumDuration`, which made
  the press feel sluggish at every threshold value.
- **Context-menu flash on EPG program cells and channel rows**
  replaced with a stable `.confirmationDialog` path. Rebuilding the
  `UIMenu` every time the cell re-rendered was causing a visible
  flash on each update.
- **Record sheet rebuilt for tvOS.** Presents via `.fullScreenCover`
  instead of the cramped centred `.sheet` modal, with a custom layout
  of pill buttons (Off / On, None / 5 min / 10 min / …) instead of
  the default Form rows whose oversized white focus halos obscured
  neighbouring controls.
- **DVR tab visuals unified.** Recording rows use the subtle accent-
  stroke + scale-bump focus treatment that matches the Live TV group
  filter bar and the rest of the app — no more system white halo.
- **Settings pages unified.** Network, DVR, Developer, and Appearance
  rewritten on top of the shared `TVSettings*` components
  (`TVSettingsNavRow`, `TVSettingsSelectionRow`, `TVSettingsToggleRow`,
  `TVSettingsActionRow`, `tvSettingsCardBG`). Focus treatment is now
  consistent across every Settings sub-page.
- **Guide-only on tvOS.** The Live TV tab always opens the Guide view;
  the List view is no longer offered.
- **CFBundleVersion warning resolved.** tvOS app's
  `CURRENT_PROJECT_VERSION` bumped to match the Top Shelf extension.
- **Console warning** `"Adding '_UIReplicantView' as a subview of
  UIHostingController.view is not supported"` resolved by wrapping
  the focusable press-detector UIView in a plain container.

### Notes

- New shared UIKit helper `Shared/TVPressGesture.swift` (`TVPressOverlay`,
  `PressCatcherView`) added to both the iOS and tvOS target sources in
  `Aerio.xcodeproj/project.pbxproj`.
- `DispatcharrAPI.Recording` gains a `comskip: Bool` field.
- `RecordingCoordinator.scheduleDispatcharrRecording(...)` and
  `DispatcharrAPI.createRecording(...)` each gain a
  `comskip: Bool = false` parameter.
- `reconcileDispatcharrRecordings(api:serverID:modelContext:)` now
  imports orphan remote recordings as new local rows (previously it
  only synced status or pruned deleted rows).
- All `TVSettings*` row components and `tvSettingsCardBG(_:)` promoted
  from `private` to internal so DVR / Developer / Appearance /
  Network Settings can share them.

---

## v1.4.0 — 2026-04-10

### New — DVR Recording
- **Schedule recordings from the EPG guide.** Long-press (or right-click on
  tvOS) any current or future program → "Record" to schedule with
  configurable pre-roll and post-roll buffers (None / 5 / 10 / 15 / 30 / 60
  min / Custom). Pre-roll is disabled for programs already in progress.
- **Dispatcharr server-side recording.** Dispatcharr API users can record
  directly on the server — recordings continue even when AerioTV is closed.
  Create, list, poll, stop, and delete recordings via the Dispatcharr REST API.
- **Local recording (foreground only).** XC, M3U, and Dispatcharr users can
  record to the device's local storage. Uses a dedicated URLSession with
  `.utility` QoS so playback of a separate stream is unaffected. Screen stays
  awake while recording. Warning: closing the app stops local recordings.
- **Download server recordings.** Long-press a completed Dispatcharr recording
  → "Save to Device" to download the file to local storage.
- **Delete server recordings.** Long-press a Dispatcharr recording → "Delete
  from Server" removes the recording and file from the Dispatcharr server.

### New — DVR Settings (Settings → DVR)
- Default pre-roll and post-roll buffers (applied to new recordings).
- Default recording destination per Dispatcharr server (server or local).
- Maximum local storage quota slider (1–200 GB, default 10 GB) with live
  usage bar (green → yellow at 80% → red at 95%).
- "Keep device awake during recording" toggle (default ON).
- Custom recordings folder picker (iOS/iPadOS only; tvOS uses
  Documents/Recordings/).
- My Recordings list with Scheduled / Recording / Completed segments,
  context menu actions (Play, Stop, Cancel, Delete, Save to Device).

### New — Custom User-Agent (Dispatcharr only)
- Dispatcharr users now send a `User-Agent` header on every API and stream
  request so the device appears by name in Dispatcharr's admin Stats panel.
- Default format: `AerioTV/1.4.0 (iOS; iPhone 15 Pro; Archie)`.
- Device nickname prompted during Dispatcharr onboarding (prefilled with
  device model, editable). Also editable per-server in Edit Playlist →
  User-Agent.
- Hidden entirely for XC / M3U servers (no surface consumes the UA).

### New — Onboarding improvements
- Dispatcharr onboarding now includes a device-name field and a recording
  destination picker ("Dispatcharr server" recommended, or "This device").

### Quota warnings
- **DVR Settings banner:** persistent warning when local usage ≥ 80%.
- **Schedule toast:** warning when scheduling a local recording near quota.
- **My Recordings toast:** banner when any recording is in failed state.

### Notes
- New SwiftData model `Recording` added — lightweight schema addition, no
  migration from v1.3.x required.
- `ServerConnection` gains `customUserAgent` and
  `defaultRecordingDestinationRaw` fields (both default to empty string /
  "dispatcharr_server" respectively — no migration needed).

---

## v1.3.4 — 2026-04-09

### Fixed
- **Live TV guide empty after switching server types.** Deleting an Xtream Codes
  (or M3U) server and re-adding the same source via Dispatcharr API would leave
  the EPG guide blank until a cache wipe. Root cause was three-fold and all
  three have been fixed:
  1. `loadFromCache` now filters `EPGProgram` rows by the active server's ID,
     so orphaned rows from a previous server can no longer leak into the guide.
  2. Deleting a server in Settings now cascade-deletes its `EPGProgram` rows
     instead of leaving them stranded in SwiftData.
  3. On launch, any `EPGProgram` rows whose `serverID` no longer matches an
     existing `ServerConnection` are pruned (one-time cleanup for users
     upgrading from a buggy build).

### Rebrand
- App display name, Info.plist usage strings, and all user-visible copy updated
  to **AerioTV** (previously a mix of "Aerio").
- About screen now shows accurate device model, last updated date, and first
  install date via a new `DeviceInfo` helper (previously hard-coded/placeholder).

### Notes
- No schema migration required — `EPGProgram.serverID` has existed since the
  model was introduced; existing rows simply had it populated as an empty
  string, which the orphan pruner cleans up automatically.
