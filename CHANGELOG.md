# Changelog

## v1.8.28 - 2026-09-03

Playback fix release for the AVPlayer engine.

### Fixed

- Live channels on a Dispatcharr Redirect stream profile failed on the
  native engine with "the server is not correctly configured". The HLS
  capability probe took any redirect as native HLS output, but a Redirect
  profile answers the same way, straight to the raw upstream stream. The
  probe now only trusts a redirect that points at a playlist, and a
  channel that still fails this way re-tunes once through the on-device
  remux instead of stopping.
- Apple TV stayed in HDR after leaving a movie that was exited within
  the first seconds: the preparation still running after the player
  closed applied the display mode with nothing left to reset it.
- Live streams are given at least 30 seconds to deliver their first
  bytes before the app reports a failure, so slow providers no longer
  trip the timeout at tune.

## v1.8.27 - 2026-09-03

Seventh AVPlayer-engine beta, and the first one going to every TestFlight
tester. Xtream Codes accounts now work on the native engine.

### Added

- Channels without guide data show the channel name as the programme, with
  the start time parsed out of the name when it carries one (Xtream event
  feeds name their dynamic channels after the event).
- Live playback backs the live edge off a little further after each stall,
  up to 18 seconds, so a bursty stream stops re-buffering; a steady stream
  never pays the extra latency.

### Fixed

- Xtream Codes channels failed on the AVPlayer engine: the app applied a
  Dispatcharr-only HLS upgrade to them, and App Transport Security refused
  the plain-http edge servers Xtream panels redirect to. Both fixed; Xtream
  live and VOD play on the native engine.
- Apple TV crashed on very large playlists (tens of thousands of channels):
  the guide cache was read and written as a single block of managed
  objects, a sparse-coverage rule forced a full XMLTV refetch on every
  launch, and the empty-row label was rebuilt on every render. Cache reads
  are paged, saves are batched and skipped when unchanged, huge playlists
  keep six hours of aired programming in memory, and labels are cached.
  Memory now holds around 300 MB where it reached 1.7 GB before.
- Scrolling the guide's group sidebar on a huge playlist no longer hangs:
  a group is previewed only after a short pause.

## v1.8.26 - 2026-09-03 (TestFlight beta)

Sixth AVPlayer-engine beta, shipped alongside AerioTV for Android 0.4.24.

### Added

- Manage Groups has a pinned All Channels row: uncheck it and the guide,
  the channel list and the in-player channel list start on your first
  visible group, which keeps very large playlists quick to open.
- Channel number entry from a keyboard or a remote with digit keys
  (Apple TV with a Bluetooth keyboard, iPad with a hardware keyboard):
  type the number and press Return to jump the guide to that channel or
  change channel while watching. An entry left alone for six seconds
  clears.
- Recordings resume where you left off, on every device: playback position
  for DVR recordings is saved and synced over iCloud, and the recordings
  list shows the progress.
- iPhone: lock screen and Control Center controls while controlling an
  AerioTV TV with the companion remote (program, channel and TV name,
  channel logo, play/pause, skip 30, next/previous channel).

### Fixed

- Program subtitles that only repeat the start of the description in
  square brackets (some Schedules Direct lineups) are hidden.
- Long-running series load every season again; episodes are paged from
  Dispatcharr instead of loaded in one request that timed out.

## v1.8.25 - 2026-09-02 (TestFlight beta)

Fifth AVPlayer-engine beta: two new Appearance settings and a player
channel-list focus fix, shipped alongside the same changes on Android.

### Added

- Settings > Appearance > Time Format: System, 12-hour or 24-hour for every
  clock in the app (guide header and cell times, program info, search,
  recordings). Synced across your devices.
- Settings > Appearance > Channel List > Show Program Subtitles: turn off to
  hide the episode or match name under each program title, for EPG feeds
  that repeat the description there.

### Fixed

- Apple TV: the player's channel list (Left while watching) now opens with
  focus on the channel you are watching instead of the top of the list.


## v1.8.24 - 2026-09-02 (TestFlight beta)

Fourth AVPlayer-engine beta: Apple TV multiview and guide polish from the
third round of tester feedback, plus a stream-start fix for busy servers.

### Fixed

- Apple TV multiview: the tile hold menu now lists Remove, Move Tile,
  Playback, Switch Stream, Change Channel, Add Channel, Full-Screen,
  Spotlight and the Layout choices in that order, and every option fits
  on screen.
- Apple TV multiview: the tile hold menu no longer flickers or rebuilds
  every few seconds while it is open.
- Apple TV guide: a short press of Right steps one slot on release while
  hold-Right (close the mini player) is armed, instead of being swallowed.
- A channel that answers HTTP 502/503 at stream start (a server slot still
  tearing down) is retried with an increasing back-off before an error is
  shown, instead of failing after three one-second attempts.
- VOD prepare on HTTP 503 now says the server refused the request rather
  than reporting a stalled connection.


## v1.8.23 - 2026-09-01 (TestFlight beta)

Third AVPlayer-engine beta: OTA channel handling and touch-scrubbing
polish from the second round of tester feedback.

### Added

- Over-the-air (MPEG-2) channels now show a clear "Channel Not
  Supported" message explaining the format and pointing at the OTA /
  HDHomeRun section of the GitHub README, which documents a validated
  Dispatcharr Stream Profile that transcodes these channels for native
  playback.

### Fixed

- Dragging the VOD/DVR timeline no longer rubber-bands back to the old
  position before jumping forward: the scrubber holds at the released
  spot until the seek actually lands.
- Error cards no longer show the "mpv engine disabled (Developer
  setting)" internal note.


## v1.8.22 - 2026-08-31 (TestFlight beta)

Second AVPlayer-engine beta. Fixes for everything raised in the first
round of tester feedback (VOD/DVR scanning, DVR Watch from Beginning,
the scrubbing crash, and mid-file VOD failures).

### Added

- Completed recordings now offer "Watch from Beginning" in the
  long-press menu (previously only in-progress recordings had it).

### Fixed

- Scanning through a VOD or DVR recording no longer jumps back to the
  previous position: consecutive scrubs now chain from the seek target
  while the engine is still reopening the stream at the new spot.
- "Watch from Beginning" on an in-progress recording actually starts at
  the beginning instead of the live edge (the start seek is re-issued
  once the player is ready, when it sticks).
- Fixed a crash when rapidly scanning through high-bitrate VOD files:
  the engine now drops its stale read-ahead caches on every seek, and
  the periodic guide refresh no longer runs during active playback.
- A VOD file that fails mid-play with a decoder error now retries once
  just past the failing spot instead of stopping with an error card,
  and logs precise diagnostics for the failing copy.


## v1.8.21 - 2026-08-31 (TestFlight beta)

AVPlayer-engine beta: every playback path (live TV, VOD, DVR, catch-up,
Live Rewind, multiview) now runs on the native AVPlayer engine with the
mpv engine fully disabled. This build is for the AVPlayer-only test
group.

### Added

- **Stream Buffer for live TV** now applies to the native engine: the
  App Behaviors setting adds its seconds behind the live edge, smoothing
  channels whose feeds arrive in bursts (event streams).
- **Channel list freshness.** The guide now refreshes itself during long
  foreground sessions (every 5 minutes past the 30-minute staleness
  window), so event channels appear and disappear without relaunching.
- Multiview tile menu: native long-press menu with Playback submenu
  (RW 60s / Pause / FF 60s / Return to Live), Add Channel, Change
  Channel, and per-tile Switch Stream on Dispatcharr.

### Fixed

- Returning from the background no longer shows a playback error; the
  player rebuilds its pipeline silently (live returns at the edge, VOD
  at position, catch-up in place).
- Picture in Picture works on the native engine (auto-starts on swipe
  home; solo playback only).
- 4K UHD MKV remuxes with oversized codec headers no longer fail with a
  bare error at start.
- Playback survives the server switching provider copies mid-stream
  (silent retry budget instead of an immediate error card).
- Live channels removed on the server (finished event streams) now show
  a clear "Channel Unavailable" message and refresh the guide instead of
  a generic error.


## v1.8.5 - 2026-08-08

### Added

- **Customizable Remote Control (Apple TV).** Remap what each Siri Remote
  button and hold does in the player and the guide, with per-context maps
  and on-screen hints that follow your mapping. Settings > Remote Control.
- **Redesigned Settings.** Sidebar layout on Apple TV, split view on iPad,
  and a cleaner detail and edit flow everywhere.
- **Guide group sidebar.** Hold Left in the TV guide to open a docked
  channel-group menu with live preview while you browse.
- **Channels overlay exit model.** In the live player, Left opens the
  channel list and Left again opens groups; Right steps back out one
  layer per press; Back closes the whole overlay.
- **Mini-tune from the guide.** Selecting a channel tunes it in the corner
  mini-player first; press Select again for fullscreen.
- **Recording and reminder markers in the guide.** Red dot on cells with a
  scheduled or in-progress recording, bell on cells with a reminder.
- **Unified output picker (iPhone and iPad).** One button for AerioTV
  Remote, Google Cast, and AirPlay, shown only when each is available.
- **Dispatcharr Channel Profile picker** on playlist edit.
- **Auto-rotate toggle** in App Behaviors (iPhone and iPad), default on.

### Fixed

- 4K HEVC live channels could permanently drop to software decode after a
  mid-stream join; hardware decode now recovers automatically.
- Frame-rate matching on Apple TV now actually switches the panel mode, so
  50fps content no longer judders on a 60Hz mode with Match Content on.
- Live Rewind could suddenly jump playback back 30 minutes once its buffer
  filled (GH #67); rewind reconnect splices also no longer feed duplicated
  data to the decoder.
- Security: VOD session URLs that resolve to a different host than your
  server no longer receive your API key.
- Stream Info's drops readout now reflects real presentation drops instead
  of an internal counter that overcounted.
- Guide polish: hint pills no longer overlap the corner clock, the player
  hint text no longer truncates, and guide badge pills no longer clip at
  the bottom edge of cells.

## v1.7.11 - 2026-07-12

### Added

- **Live Rewind.** Pause and rewind live TV, with a "Keep Available" setting
  for how far back you can go.
- **Catch-up TV.** Replay already-aired programs straight from the guide on
  supported servers (Dispatcharr and Xtream Codes with archive), with a
  scrubbable timeline and native Dispatcharr catch-up sessions.
- **Unified Apple TV player.** One player for live, rewind, and catch-up -
  hold left/right on the remote to scrub with smooth acceleration.
- **Retry in the player controls.** When a stream drops, the controls appear
  with a focusable Retry, auto-reconnect runs every 5 seconds, and the error
  card shows what actually went wrong.

### Changed

- iPhone: swipe between channel groups with a fluid drag animation, the group
  pills follow along, and the channel list fills the whole screen beneath the
  tab bar (iOS 26).
- Settings pages unified across iPhone, iPad, and Apple TV.
- Faster dead-stream detection on live TV (seconds instead of a minute).

### Fixed

- No audio on some Dolby Atmos receivers (32-channel spatial HDMI layouts).
- Silent audio when the receiver negotiated 44.1kHz.
- Catch-up playback reliability on Apple TV (connection handling reworked).
- Recorded playback stability improvements.


## v1.7.10 - 2026-06-30

### Added

- **Channel Collections.** Group your channels into your own named collections
  and filter the Live TV list to them with quick pills.
- **More multiview layouts.** Pick from additional grid and spotlight
  arrangements in the multiview layout picker.

### Changed

- **Xtream Codes guide uses the full standard EPG.** Xtream connections now pull
  the server's complete XMLTV guide the same way other clients do, so you get
  more program data, accurate dummy-EPG titles, and category colors instead of
  just the now and next slivers.
- **Apple TV guide and mini-player gestures.** Smoother Live TV navigation: hold
  Left in the guide to jump to the All group, a single Back restores the
  mini-player while a double Back jumps to the top channel, and a single Back
  minimizes a full-screen channel in one press.
- **Apple TV: refreshed player controls.** The Live TV player controls now use a
  cleaner, native-style layout (frosted circular buttons for Record, Add Stream,
  and Options).

### Fixed

- **Recorded playback no longer restarts at commercial breaks.** Saved DVR
  recordings play straight through instead of looping back when the broadcast
  splices a different encode at an ad break.
- **The multiview performance warning can be dismissed for good** with a "Don't
  show again" option.
- **Apple TV: the player Options button stays responsive after a stream
  re-tune.** A background re-tune could leave it unresponsive; it now works.
- **Apple TV: Back exits Settings sub-pages while a channel is minimized.** With
  a mini-player playing, Back inside a Settings sub-page now goes back a level
  instead of acting on the mini-player.

## v1.7.9 - 2026-06-30

### Fixed

- **DVR downloads are reliable.** Saving a completed recording to the device is
  now authenticated and checks the server's response first, so a secured or
  erroring server can no longer leave behind a broken file.

### Changed

- **Lower memory use on Apple TV.** The guide now releases programs that have
  already aired instead of holding the entire schedule in memory for the whole
  session, easing memory pressure during long viewing sessions.
- **Security and privacy hardening.** Account credentials are kept strictly
  scoped to your own server (never forwarded to redirected or third-party
  hosts), and EPG parsing is hardened against malformed feeds.

## v1.7.8 - 2026-06-29

### Fixed

- **4K / UHD playback is far more stable.** Fixed a memory buildup that could
  garble audio or, during a long session on a demanding UHD channel, cause the
  app to run out of memory. The player now releases the old video pipeline
  before it reloads a stream, so memory stays flat instead of climbing.
- **No stalls right after launch on UHD channels.** The first-run catalog and
  guide sync no longer competes with live video for the same resources, so a 4K
  stream keeps playing smoothly while On Demand and the guide load in the
  background.

## v1.7.7 - 2026-06-29

### Added

- **Switch Stream (Dispatcharr).** On a Dispatcharr server connected with an
  admin Direct Connect account, pick which upstream a channel pulls from
  straight from the player's Options menu, so you can move off a source that is
  buffering or down without leaving the channel. The picker lists each stream
  with its quality, marks the one that is currently active, and confirms the
  switch took effect before the player reloads onto it.
- **Stream Buffer setting.** A configurable live cushion that holds a little
  more video ahead to smooth out stutter on bursty streams.

### Fixed

- **Apple TV: player controls appear and hide reliably.** The Options / Record
  / Add Stream bar now focuses on the first Menu press, can be summoned with
  Select as well as Menu, draws its focus highlight to match the rounded pill
  shape, and fades on its own after you back out of the Options or Switch
  Stream panel.
- **Apple TV: On Demand focus and navigation.** Fixed focus climbing from the
  cast row to Play, the tab bar not restoring after you leave a title, a
  Settings submenu that could stall, blank future guide data, and a TMDB
  toggle that did not sync.
- **Live TV: no reload loop at commercial breaks.** The stream watchdog no
  longer repeatedly reloads when an over-the-air channel briefly changes format
  at an ad break.

### Changed

- **Debug log redaction.** Additional M3U credential formats are stripped from
  the debug log sanitizer so they never appear in diagnostic logs.

## v1.7.6 - 2026-06-17

### Added

- **Automatic local/remote switching.** AerioTV now connects to a server's
  local (LAN) URL whenever it is reachable and falls back to the remote URL
  otherwise, deciding purely by a fast reachability check. If you move between
  networks while watching (for example leaving home WiFi for cellular),
  playback re-tunes to the reachable URL on its own. This replaces the old
  Home WiFi / SSID setup, and the location permission has been removed entirely.
- **iPhone: rotate-to-fullscreen-landscape button.** A new control in the
  player rotates video into landscape fullscreen even when the device's
  rotation lock is on, and returns to the natural orientation when you exit.
- **Favorites from the guide.** Tap the star on any channel in the guide to
  favorite it, and the channel actions button now appears on iPad as well, so
  adding favorites no longer requires a hidden long-press.
- **Live TV group sorting.** Sort your channel groups Default, A-Z, or in a
  manual order you arrange yourself (drag on iPhone, long-press then d-pad on
  Apple TV). The channels inside each group follow the chosen order.
- **AVPlayer playback engine for HLS (experimental, off by default).** Behind
  Settings > Developer, HLS-capable servers can play through Apple's AVPlayer
  for HEVC and HDR, with automatic fallback to the mpv engine.
- **Richer On Demand metadata (TMDB).** Cast and crew with photos, person bios
  and Known For, posters extended to On Demand, and View on TMDB QR codes on
  Apple TV.
- **On Demand category filter** now fetches per category so every enabled
  category is represented, not just the first page of results.
- **EPG search** results jump straight to the matching program in the Live TV
  guide.
- **Developer: Delete All Logs.**

### Changed

- Removed the location permission and the Home WiFi / SSID configuration
  entirely (see automatic switching above). Local network access is still
  requested, since reaching a server on your own network requires it.
- Apple TV: removing a favorite via the star button now asks for confirmation.
- Clearer Developer playback-engine labels.

### Fixed

- **Apple TV: fixed a crash when scrolling the Live TV guide** under load on
  recent tvOS, traced to the pinned guide time-header.
- **Apple TV: fixed no audio when Dolby Atmos is enabled** in tvOS Settings.
- **Recording a currently-airing program** now lands in the Recording section
  instead of Scheduled, and recordings show full program details.
- HEVC channels that AVPlayer cannot render now fall back to the mpv engine
  automatically.
- Various Apple TV focus and text-field polish.

## v1.7.5 - 2026-06-05

### Fixed

- **Playback stutter on standard (SDR) channels.** The HDR color
  correction added in 1.7.3 was being applied to every channel, including
  standard-range ones, which forced the renderer through extra work each
  frame and produced a visible stutter on Apple TV, most noticeable around
  30fps content. The correction is now applied only to channels that are
  actually HDR (BT.2020 / PQ / HLG), so SDR channels play smoothly again
  while HDR channels keep their corrected colors.
- **Live streams that froze after an audio glitch now recover on their
  own.** After an audio underrun a live stream could wedge in one of two
  ways: the picture went black, or it stuck on the last frame with no new
  frames. Both are now detected and the stream re-primes itself in place
  instead of staying frozen until you change channels.
- **Apple TV: multi-second freeze right after launch.** The Top Shelf
  data sync was writing to the keychain on the main thread during launch,
  which could block the interface for several seconds. The keychain writes
  now happen off the main thread, so the app is responsive immediately.
- **Apple TV: debug logging now works.** Enabling Debug Logging (Settings
  > Developer) now actually writes the log to disk, and a Share Log File
  option serves it over your local network so you can open it on a phone
  or laptop and send it in for support.

## v1.7.4 - 2026-06-02

### Added

- **Watch in-progress recordings from the beginning.** A program that is
  still recording can now be started from the top instead of the live
  edge. AerioTV plays the recording's HLS from segment 0 and drives a real
  DVR window that grows toward the live edge as the recording continues,
  so you can pause and rewind everything captured so far.
- **Aspect-ratio control in the player.** Switch between Fit (the whole
  frame, letterboxed) and Fill (cropped to fill the screen) from the
  player menu, on iOS and Apple TV.
- **Spotlight a Multiview tile.** Promote any tile to a large panel with
  the remaining tiles stacked beside it, and toggle back to the even grid.
  The transition keeps each tile's identity so streams grow and shrink in
  place rather than reshuffling.
- **Multiview tile padding, on by default.** The standard Multiview grid
  now shows an 8pt gutter between tiles so each stream stands on its own.
  Toggle it in Settings > Multiview ("Padding Between Tiles"); the flush
  layout is still one switch away.
- **iPhone full-screen button.** A control in the player rotates into
  landscape for an edge-to-edge view.
- **Hide channel logos.** A Settings > Appearance toggle drops the logos
  for a denser, more compact channel list.
- **Refresh Everything.** A playlist's settings gained a full data-rebuild
  action that discards cached channels, guide, and On Demand and re-fetches
  from scratch.

### Changed

- **The guide refreshes itself when stale.** Returning to the app with an
  out-of-date EPG now kicks off a background refresh instead of waiting for
  the next manual reload.
- **Apple TV guide focus restore.** Pressing Menu jumps to the top channel,
  and returning from a stream puts focus back on the channel you were
  watching rather than the top of the list.
- **Smoother On Demand and DVR scrubbing.** The scrub bar holds the
  playhead at the target until the player catches up, buffers back faster
  after a seek, and reads out the position more clearly.
- **Deleting a playlist clears its On Demand library** from this device
  along with its channels and guide data.

### Fixed

- **Launch crash on duplicate category/group IDs.** Servers that returned
  duplicate category or group identifiers could crash the app on launch
  while it built its lookup tables. The tables now tolerate duplicates.
- **Local recording corruption.** Captured stream chunks could be written
  to disk out of order, producing a file the player could not read. Chunks
  are now appended in arrival order on a serial writer.
- **Edit Server no-op on Apple TV.** Opening the same server in Edit Server
  twice in a row did nothing the second time; the edit screen now resets
  correctly between visits.
- **Freeze leaving an in-progress recording.** Leaving a still-recording
  stream could briefly hang the main thread; teardown now quits the player
  engine asynchronously.
- **Player controls no longer freeze the UI on a stalled stream.** Play,
  pause, scrub, and track selection run their player calls off the main
  thread, so they stay responsive even while a stream is buffering.

### Security

- Credentials (Xtream username/password, API keys, tokens) are scrubbed
  from debug logs and from a user-facing connection-error message.
- Server-provided image URLs (Xtream and Dispatcharr poster/backdrop art)
  are validated against the SSRF guard instead of being trusted verbatim.
- Keychain saves are atomic, so a failed write can no longer drop saved
  credentials.
- iCloud key-value reads run on the main actor, removing a data race in the
  sync path.

## v1.7.3 - 2026-05-29

### Added

- **Compressed XMLTV (`.xml.gz`) guide support.** AerioTV can now
  ingest gzipped XMLTV EPG feeds, including large Gracenote-style
  guides that are impractical uncompressed. The feed is downloaded,
  stream-decompressed through Apple's Compression framework, and
  parsed off an InputStream so the multi-hundred-MB (or multi-GB)
  decompressed payload never materializes in memory. Gzip is detected
  by the `.gz` extension, an `application/x-gzip` / `application/gzip`
  content type, or the `1f 8b` magic bytes. A filter-during-parse
  pass keeps only the programs for channels you actually have.
- **Xtream Codes: optional custom XMLTV URL for category tints.**
  Xtream Codes' API exposes no per-program category, so XC channels
  never got the Sports / News / Movies / Kids color tints Dispatcharr
  users have had since v1.6.4. A new optional per-server "Custom XMLTV
  URL" field (on the Add and Edit Server screens, iOS and Apple TV)
  lets you point at an XMLTV feed whose `<category>` tags drive the
  tints. The feed is matched to your channels by `epg_channel_id` and
  reuses the existing tint pipeline. Stored per server; not synced,
  since XMLTV URLs can carry credentials.
- **Continue Watching advances to the next episode.** When you finish
  an episode of a series, Continue Watching (in-app and on the Apple TV
  Top Shelf) now surfaces the next unwatched episode instead of dropping
  the series, so you can keep going without searching for the show
  again. The upcoming-episode list is captured from the series when
  playback starts, so advancing needs no extra network fetch. The
  existing long-press "Remove from Continue Watching" still clears a
  show from the row. Reported by jdfrey1 (Issue #19).
- **Apple TV: open a series from Continue Watching.** Press and hold
  Select on a series card in the Continue Watching row for an "Open
  Series" action that jumps to the full show page with every season and
  episode, the same destination as picking it from the grid.

### Changed

- **Smoother channel-flipping.** Channel changes now swap the stream
  into the existing player in place (mpv `loadfile`) instead of
  tearing down and rebuilding the whole player, removing the brief
  30-then-60 fps wobble after a flip.

### Fixed

- **M3U playlist favorites now survive a playlist reload.** M3U
  channels were keyed by a random UUID regenerated on every parse, so
  favoriting a channel never stuck across a refresh. Channel ids are
  now derived deterministically from the stream URL (hashed, so no
  credentials are stored), and favorites, now-playing restore, and
  Multiview tile identity all persist. Xtream Codes and Dispatcharr
  were unaffected (stable server ids).
- **Apple TV: returning to the Guide focuses the channel you were
  watching** instead of the top of the list (community PR #17).
- **Channels that share an EPG ID (tvg-id) now all show their guide
  data.** Previously only the first channel with a given tvg-id got
  programs and the rest fell back to stale info. The match map now
  fans one tvg-id out to every channel that uses it (relevant to
  Teamarr-style multi-channel-per-event setups).
- **Multiview staging from the Guide gained a Play button, and the
  Done button is now reachable on Apple TV.** The staging banner now
  sits in the spatial focus hierarchy on tvOS, so D-pad-up from the
  guide rows reaches both buttons.
- **Server addresses can be entered without a scheme.** The Add
  Server screen now accepts a bare host like `dispatcharr.example.com`
  in addition to a full `https://` URL.
- **HDR channels no longer render green and washed out on Apple TV.**
  HDR (BT.2020 PQ or HLG) live channels are now tone-mapped to correct
  SDR instead of being drawn with the wrong gamut and transfer
  function. SDR channels are unaffected.
- **Apple TV: the focused guide cell is always clearly marked.** On
  category-tinted and currently-airing cells the focus highlight was
  only a faint same-color shift and could look lost while scrolling
  down; focused cells now get a clear outline so you can always tell
  where you are, on any tint.
- **Apple TV: the top navigation bar no longer gets stranded.**
  Pressing Menu to leave On Demand, the DVR, or Settings could drop you
  into the guide with the tab bar hidden and no way to move back up to
  it; focus is now restored so the bar is reachable again.
- **Apple TV: pressing Down from the Movies / Series selector lands on
  Continue Watching** instead of skipping past it to a poster further
  down the page.
- **Apple TV: the focused episode row in a series shows a single
  highlight** instead of two nested outlines.

## v1.7.2 - 2026-05-11

### Added

- **Build a Multiview pile directly from the Guide.** Long-press any
  channel cell and the existing context menu (Favorites, Program
  Info, Record from Now, Reminder) now offers an "Add to Multiview"
  action alongside them. Tapping it for the first time wipes any
  pre-existing Multiview tiles, switches the Guide into staging
  mode, adds the channel, and pins a banner at the top of the Guide
  reading "N tiles staged for Multiview" with a Done button. While
  staging mode is active, single-tapping any other channel cell
  adds it (or removes it if already staged) instead of starting
  playback. Each add or remove confirms with a brief toast.
  Tapping Done leaves the staged tiles in place so the user can
  switch to the Multiview tab to play them. Hitting the 9-tile
  hard cap auto-exits staging. The long-press menu label flips
  between "Add to Multiview" and "Remove from Multiview" based on
  the channel's current presence in the pile.
  - Implementation surfaces: new `@Published isStagingFromGuide`,
    `clearAll()`, and `tile(forChannelID:)` on `MultiviewStore`;
    new top-edge banner via `safeAreaInset` plus floating toast on
    `EPGGuideView`; new `handleMultiviewIntent(channel:)` owns
    wipe-on-entry, toggle, soft-cap warning bypass, hard-cap exit,
    and toast wiring; new `onMultiviewIntent` closure threaded down
    to `GuideProgramButton` which observes the store so the tap
    path picks between `onSelect` (normal play) and the staging
    toggle, and the context menu label flips accordingly.
  - Field-requested by Freyguy1975 (Discord 2026-05-11) for the
    "build a Multiview before pressing play on anything" workflow.

### Fixed

- **Apple TV: pressing Menu or Back during playback now focuses
  the "+" Add Stream pill directly.** Spatial focus routing on
  tvOS previously landed the next D-pad-down from a left-positioned
  tile on Options (the leftmost pill), forcing an additional
  arrow-right traversal to reach "+". `MultiviewContainerView`'s
  `focusedChrome` `@FocusState` had a fade-out clearer at
  `.onChange(of: chromeState.isVisible)` but the documented
  symmetric fade-in setter was never written; this release adds it
  targeting `.addStream`. Options and Record stay reachable via
  D-pad-left from the "+" landing position. Reported by
  Freyguy1975 (Discord 2026-05-11).
- **Decimal channel numbers from Dispatcharr and M3U now display
  correctly.** ATSC over-the-air major.minor numbers (2.1 CBS-HD,
  5.1 ABC-HD, etc.) were collapsing to a 1-based-list-index
  fallback because both provider decoders were narrowing the
  channel-number value to a type that couldn't carry a decimal:
    - `DispatcharrChannel.channelNumber` was declared `Double?`
      and decoded as JSON Number only, but Dispatcharr's underlying
      column is a decimal type and Django REST Framework's
      `DecimalField` defaults to `coerce_to_string=True`, so the
      field arrives as a JSON String ("2.1"). The old decoder
      threw `typeMismatch` on the string path.
    - `M3UChannel.channelNumber` was declared `Int?` and parsed
      via `Int($0)` against the raw `tvg-chno` attribute value.
      Any decimal value returned `nil`.
    - The downstream channel-list builder substituted
      `String(i + 1)` whenever `channelNumber` was nil, which is
      exactly the "2.1 → 2, 2.2 → 3, 5.1 → 7" symptom pattern
      "the Moterator" (Discord 2026-05-11) reported.
  Both fields are now `String?`. The Dispatcharr decoder accepts
  JSON Double / Int / String (in that order), flattens whole-number
  doubles to integer form ("11.0" → "11") so existing integer
  lineups stay clean, and falls through to nil on null / missing /
  empty. The M3U parser preserves `tvg-chno` verbatim (trimmed,
  empty becomes nil). Behavior-preserving for integer-numbered
  lineups across Dispatcharr, M3U, and Xtream Codes.

## v1.7.1 - 2026-05-10

### Fixed

- **Adding a second Dispatcharr Direct Connect server now reliably
  saves credentials when iCloud sync is enabled.** A 2-second push
  debounce in `SyncManager.pushServers` opened a window where the
  bounce-back guard's `lastPushTime` was stale (from the previous
  successful push, potentially minutes earlier). A foreign
  `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
  arriving in that window caused `mergeRemoteServers` to run against
  KVS contents that didn't yet contain the just-added local server,
  and the "delete local servers not in remote" branch tore the new
  SwiftData row plus its Keychain entries out before
  `saveCredentialsSynced` could persist them. Symptom: the new
  server appeared on receiving devices with empty credentials
  (`hasCreds=false`) and produced a "Connection Error / Invalid
  credentials" overlay when activated. Fixed with two layered
  guards: (1) `pushServers` now stamps `lastPushTime` immediately
  at schedule time so the bounce-back guard correctly suppresses
  notifications during the debounce window; (2) the
  delete-not-in-remote branch in `mergeRemoteServers` now skips
  servers whose `createdAt` is within the last 10 seconds,
  regardless of (1). Forensic instrumentation: both branches
  (skip-young and actually-delete) emit file-backed
  `DebugLogger.shared.log` lines with server age and remote count,
  so any future occurrence appears cleanly in user-exported
  diagnostic logs.

### Changed

- **Deleting a server now cascades to its watch progress and
  server-side recordings.** Previously orphaned `WatchProgress`
  rows persisted in SwiftData (and survived the iCloud sync push)
  and server-side Dispatcharr `Recording` rows stayed in the local
  list even though they pointed at a server that no longer existed.
  Both are now scrubbed via `FetchDescriptor` + `#Predicate`
  lookups in the Settings, Delete Playlist alert handler. Local
  recordings (`localFilePath != nil`) are preserved because they
  are user-generated content and the user may want to keep them
  after disconnecting from the recording server. EPG rows already
  cascaded since v1.3.4.

## v1.7.0 - 2026-05-08

### Added

- **Dispatcharr Direct Connect.** New sign-in mode for Dispatcharr
  servers: enter your admin username and password instead of pasting
  a 32-character API key. Equivalent to how Teamarr and Enhanced
  Channel Manager authenticate, and the same auth flow the
  Dispatcharr web UI uses. The Apple-TV typing-burden was the driver
  (a 32-char API key on the Siri Remote on-screen keyboard is
  genuinely painful), but it's a quality-of-life win on every
  platform. Endpoint contract verified against Dispatcharr 0.23.0
  testbench (both LAN HTTP and public HTTPS hostnames):
    - `POST /api/accounts/token/` body `{ username, password }`
      returns `{ access, refresh }` JWT pair. Access TTL 30 min,
      refresh TTL 24 hour. Refresh response only emits a new access
      token (refresh is NOT rotated), which sidesteps concurrent-
      refresh races entirely.
    - `GET /api/accounts/users/me/` with `Authorization: Bearer
      <access>` returns the user object including the `api_key`
      field. Aerio reads it during Test Connection and persists it
      into the same Keychain slot the legacy API-key flow uses, so
      every downstream consumer (mpv stream playback, logo fetcher,
      recording playback, the v1.6.20 dispatcharrAuthMode
      auto-discovery) keeps working with a durable credential and
      doesn't have to refresh-token mid-stream.
    - `POST /api/accounts/token/refresh/` body `{ refresh }` returns
      `{ access }`.
- **AddServerView credential picker.** When the user selects
  Dispatcharr as the server type, a segmented control reveals two
  options: "Username & Password" (Direct Connect, the new path) and
  "API Key" (the legacy path, still available for power users who
  rotate credentials per-device). The picker writes
  `ServerConnectionViewModel.dispatcharrCredentialType`; the type's
  selected value gates which fields render below (Username + Password
  vs Admin API Key) and which validation rules
  `validationErrors()` enforces. Default selection is `.apiKey` to
  match every existing v1.6.x install.

### Fixed

- **Dispatcharr List view rows now show the currently-airing
  program under each channel as soon as the guide loads.**
  Pre-v1.7 the bulk EPG path (`HomeView.loadAllEPG` after
  `/api/epg/grid/`) wrote programs into `EPGCache` keyed by
  tvg_id but never populated `ChannelDisplayItem.currentProgram*`
  on `ChannelStore.channels`. The List view's `liveProgram`
  lookup reads those fields first, falling back to
  `guideStore.programs[item.id]` second. Until the user opened
  the Guide tab (which runs `EPGGuideView.fetchDispatcharr` and
  populates `GuideStore.programs`), the lookup found no data
  and List rows rendered with just the channel name. Same
  symptom regardless of whether the user signed in via API
  Key or Direct Connect; not a v1.7 regression. Fixed in two
  places: (1) new `ChannelStore.applyCurrentPrograms` method
  takes a `[channel.id: snapshot]` map and writes the title /
  description / start / end fields onto the SwiftUI-observed
  `channels` array with one batched @Published fire; (2) the
  bulk EPG iteration in `HomeView.loadAllEPG` now builds that
  map alongside the per-channel cache writes, covering all
  three matching keys (direct tvg_id, epg_data_id bridge for
  the 25% mismatch case, AND channel UUID for Dummy EPG
  entries). Same three-key strategy `EPGGuideView.fetchDispatcharr`
  has used since v1.6.x; the cold-launch bulk path now matches it.
- **Bulk EPG path now matches Dummy EPG entries via channel
  UUID.** Side benefit of the List-view fix above. Dispatcharr's
  `/api/epg/grid/` emits synthetic placeholder programs for
  channels with no real EPG data, tagged with `tvg_id ==
  str(channel.uuid)`. The bulk path used to fall through to an
  empty fallback for those (`filled 472 empty fallbacks` was
  the typical log line on a 683-channel deployment). Now those
  channels get their dummy entries cached at the reader's key
  and surface in List view rows. The existing per-cell prefetch
  no longer fires post-loading network calls for them either.
  Field repro on a 683-channel deployment confirmed: pre-v1.7
  bridged 1, filled 472 empty; post-v1.7 bridged 1, matched
  496 via Dummy EPG UUID, filled 0 empty fallbacks.
- **Expanded channel cards on Dispatcharr now show category
  tints on upcoming programs.** Pre-v1.7 the expanded schedule
  panel rendered every future program as plain text on
  Dispatcharr-API mode because `/api/epg/grid/` strips
  `<category>` tags server-side and the existing category
  enrichment only fetched per-program detail for the currently-
  airing program (one per channel). v1.7 propagates the
  enriched now-airing category to every entry in that
  channel's `EPGCache` after the enrichment fan-out lands.
  Heuristic: a channel's content is largely the same genre,
  so treating ESPN HD's Sports category as the tint for every
  SportsCenter / NHL Hockey / NFL entry is correct >90% of
  the time. For variety channels this over-tints; the
  alternative (per-program detail fetches for all 7000+
  programs at one HTTP each) is cost-prohibitive on most
  Dispatcharr deployments. The Guide tab's existing
  per-program tint stays unchanged because it reads from
  `GuideStore.programs` which carries categories directly
  from the enrichment fan-out's primary path.
- **UHD HEVC HDR black flashes during live playback fixed.**
  Live MPEG-TS streams in the Sky Sports Main Event UHD class
  (3840x2160 p010 BT.2020 over `videotoolbox-copy`) occasionally
  produced single-VSync black flashes during otherwise smooth
  playback. SwiftUI overlays stayed drawn while the
  AVSampleBufferDisplayLayer area went pitch black for one
  display tick, ~1 per 4-12 seconds depending on stream class
  and device. Root cause: producer/consumer race on a single
  shared IOSurface. mpv's GL render pass and AVSBDL's
  compositor both touched the same backing store, and mpv's
  `glClear` at the start of each frame briefly left the
  IOSurface zero. If AVSBDL composed during that
  sub-millisecond window the layer rendered black for that
  VSync. Fix: triple-buffered FBO ring (3 IOSurface-backed
  CVPixelBuffers + matching GL textures + matching FBOs,
  advanced round-robin per render pass). By the time mpv
  comes back to a slot after writing two other slots, AVSBDL
  has long since composed and released its reference. No race.
- **Live-stream startup characterization improved for UHD
  HEVC.** Previous low-latency demuxer probe settings
  (`analyzeduration=0.1s`, `probesize=32KB`,
  `probe-info=nostreams`) were calibrated for H.264 SD/HD and
  gave libavformat too little data to characterize UHD HEVC
  Main10 BT.2020 MPEG-TS streams cleanly. Symptoms included
  `fps_detected=0.0` for the entire playback session, a
  `Skipping invalid undecodable NALU: 39` warning at startup,
  and a `0×0 ?` initial state followed by a playback-restart
  reconfig once mpv had enough data. Tuned to
  `analyzeduration=1.5s`, `probesize=1MB`, `probe-info=auto`
  for live streams. Trade-off: tap-to-first-frame latency
  increases by approximately 1-1.5 seconds in exchange for
  stable cadence detection and a libavformat that can identify
  HEVC parameter sets without falling through to its 5MB
  default. Pre-init and post-init runtime overrides reconciled
  to the same values (the old code set them differently in the
  two phases, with runtime winning, which made the pre-init
  values dead code).
- **Multiview "Decoder unavailable" red overlay on tile add.**
  Adding a tile to a multiview occasionally surfaced the red
  "Decoder unavailable / Playback error: unrecognized file
  format" card on the new tile, the existing tile, or both,
  even though the underlying streams were fine. The visible
  message mapped to `MPV_ERROR_UNKNOWN_FORMAT` (-17), but the
  existing exponential-backoff retry path only caught
  `MPV_ERROR_LOADING_FAILED` (-13). UNKNOWN_FORMAT fell
  straight through to the fatal-error path with no retry, the
  warmup-retry guard didn't fire because we never got past
  start-file, and the overlay painted permanently. Both error
  codes now trip the same retry policy: 3 retries for live
  (1s/2s/4s with 0-600ms jitter), 5 retries for recording URLs
  (3s/6s/12s/24s/48s).
- **Multiview audio silent on 2nd tile after switching focus.**
  Adding a 2nd tile to a multiview, then switching audio focus
  to that tile, occasionally left the new tile silent.
  Switching audio back to the 1st tile worked normally. Pre-
  init audio strategy in `setupMPV` was hardcoded to the
  decoder-off path (`aid=no`) regardless of tile count, but
  the runtime path uses mute-only at `tiles.count <= 6`.
  Mismatch: a tile created when `count=2` had its audio
  decoder permanently dark because `aid=no` told the demuxer
  to skip audio packets entirely. Switching focus later wrote
  `aid=auto` LATE on a running stream, which couldn't reliably
  cold-start the decoder. Pre-init now reads the tile count
  snapshotted at Representable construction time on the main
  actor and picks the matching strategy.
- **Apple TV: program-info banner occasionally stuck visible
  on stream start.** The channel + program banner that
  appears in the top-left when a stream starts sometimes
  failed to auto-fade after its 5-second budget; pressing
  Menu/Back to summon chrome made it disappear with chrome's
  own auto-fade. The auto-hide timer was a manual `Task`
  cancellation inside `.onChange(of: streamStartedToken)` that
  could race with SwiftUI's view lifecycle on tvOS, leaving
  the activation flag stuck `true`. Replaced with SwiftUI's
  `.task(id:)` modifier (lifecycle-bound, deterministic re-run
  on id change) plus a wall-clock freshness backstop in the
  `shouldRender` computation so the banner can never outlive
  its budget regardless of Task state.

### Changed

- **Renamed "Dispatcharr API" to "Dispatcharr Direct Connect" in
  user-facing copy.** Settings, the type picker, and onboarding
  reflect the new name. The SwiftData enum case stays
  `dispatcharrAPI` / raw `"dispatcharr_api"` for migration
  stability. Only the user-facing string changed.
- **`ServerConnection.authHeaders` is now gated on api_key presence,
  not credential type.** Subtle invariant change with a back-compat
  motive: every existing user has an api_key in their Keychain and
  `dispatcharrCredentialTypeRaw == ""` (resolves to `.apiKey`), so
  they emit exactly the same headers as before v1.7. New Direct
  Connect users also have an api_key in Keychain because the login
  flow fetches it from `/api/accounts/users/me/` during Test
  Connection. The JWT path layers `Authorization: Bearer <jwt>` on
  top via the per-request `headers(for:)` lookup; Dispatcharr
  prefers Bearer when both are sent. Net effect: legacy users see
  zero behavior change; Direct Connect users get JWT auth when the
  token store is populated and seamless X-API-Key fallback when
  it's not.

### Internal

- New `Networking/DispatcharrDirectConnect.swift` houses the JWT
  plumbing: `DispatcharrTokenStore` (NSLock-guarded
  process-scoped cache keyed by server UUID), `DispatcharrUser`
  decodable, `DispatcharrJWTPair` decodable, and extensions on
  `DispatcharrAPI` for `login`, `refreshAccessToken`, and
  `fetchCurrentUser`. Kept separate from `StreamingAPIs.swift`
  (already on the god-files watchlist) so the new feature doesn't
  inflate that file further.
- Added `Auth.jwtSession(serverID: UUID)` case to
  `DispatcharrAPI.Auth`. The case looks up the current access
  token from `DispatcharrTokenStore.shared` at every header
  emission rather than holding a stale value. `headers(for:)` and
  `verifyConnection`'s candidate-mode iterator both handle the
  new case.
- `ServerConnection` gains `dispatcharrCredentialTypeRaw: String =
  ""` (SwiftData migration-safe; empty default resolves to
  `.apiKey` via the `dispatcharrCredentialType` accessor).
- `SyncManager.serialize/deserialize` round-trip the new field
  via the `dispatcharrCredentialType` KVS key. Empty value
  (legacy default) is omitted from the dict so older clients see
  no unfamiliar key. `mergeRemoteServers` in `AerioApp.swift`
  copies the field on both update and insert paths.
- `ServerConnectionViewModel` gains `dispatcharrCredentialType`
  and `pendingJWTPair` properties. The Direct Connect verify
  branch in `runVerifyAttempt` calls login, then fetches the
  user object and writes the api_key into the ViewModel so the
  Save handler picks it up for Keychain persistence, then runs
  the standard API-key verifyConnection so the
  `dispatcharrAuthMode` auto-discovery still happens.
  `buildServerConnection` writes the credential-type raw onto the
  new `ServerConnection` and hands the JWT pair to the token
  store keyed by the new server's UUID.
- New triple-buffered FBO ring in `MPVPlayerView.swift`. New
  `FBOSlot` private struct holds `{pixelBuffer, texture, fbo}`.
  `fboPoolSize=3`. `renderBufferIndex` advances round-robin per
  render pass. Replaces the previous single-buffer architecture
  that exposed a producer/consumer race on the shared
  IOSurface. Memory cost ~99MB per single-stream UHD instance;
  multiview tiles render at smaller resolutions (~640-960
  wide) so per-tile cost is approximately 5-10MB total.
- New backpressure gate at `renderAndPresent` entry. Skips the
  entire render pass when
  `sampleBufferRenderer.isReadyForMoreMediaData == false`.
  Defensive in practice (AVSBDL's queue is large enough that
  ready=false is rare during normal playback) but keeps the
  policy explicit and unifies it with the watchdog's identical
  guard.
- New diagnostic surface for cadence + sync analysis on UHD
  HEVC live MPEG-TS. `MPV-PERF` shows
  `fps: estimated=X/container=X/display=X` instead of a single
  fps value. `MPV-AUDIO` surfaces sign-explicit
  `avsync=±X.XXXXs(positive=video_behind, mpv-internal)` plus
  `audio_reconfigs=N`. `MPV-CALLBACK-GAP` log lines snapshot
  `audio_pts` and `since_audio_reconfig=Nms` at the moment of
  the gap so recurring stalls can be correlated with AC3
  reconfigs. Cumulative gap-class counters
  `gaps=N/N/N(mild/mod/sev)` in FRAME and STREAM SUMMARY.
  `demuxer-cache-state/raw-input-rate` read fixed
  (`MPV_FORMAT_DOUBLE`, was silent-failing as
  `MPV_FORMAT_INT64`).
- New 16x16 stratified luma-probe black-frame detector with
  surround check. Fires when
  `avg<10 && std<8 && prev_avg>25 && prev_prev_avg>20`.
  Belt-and-suspenders against partial-corruption frames the
  triple-buffer ring can't reach (those are libmpv-side codec
  artefacts in the source data, not presentation race).
- New CADisplayLink watchdog at 30ms stale threshold.
  Re-enqueues the cached last-good `CMSampleBuffer` with
  `kCMSampleAttachmentKey_DisplayImmediately` when libmpv has
  an internal stall longer than a display refresh tick, so the
  layer stays alive instead of going blank.
- `ChannelInfoBanner` auto-hide rewritten from
  `.onChange(of:) + manual Task` to `.task(id:)` + wall-clock
  freshness check. SwiftUI's `.task(id:)` is bound to view
  lifecycle and re-runs deterministically on id change, which
  the manual cancellation pattern didn't fully handle on tvOS.
  Single source of truth for the 5s window:
  `Self.bannerWindowSeconds` static, used by both the sleep
  duration and the wall-clock comparison so they can never
  drift.
- `MPVPlayerViewRepresentable` gains
  `initialTileCount: Int = 1` snapshotted at SwiftUI
  construction time on the main actor. Threaded through to the
  `Coordinator` init so `setupMPV` (background queue) can pick
  the matching audio strategy without an actor-isolation
  violation reading `MultiviewStore.shared.tiles.count`
  directly.
- `framedrop=vo` and `video-sync=audio` shipped via the
  pre-init option block (live streams). `framedrop=decoder+vo`
  shipped via the runtime override (intentionally more
  aggressive than pre-init for stall recovery). Pre-init and
  runtime values for the demuxer probe options are now
  reconciled so the runtime override no longer silently
  re-aggressives values the pre-init block softened.

### Back-compat invariants (verified)

- Existing API-key servers continue working **unchanged**: identical
  auth headers, identical Test Connection behaviour, identical
  iCloud sync shape (the new `dispatcharrCredentialType` KVS key is
  omitted when its raw is empty).
- Older AerioTV builds receiving a v1.7-synced Direct Connect
  server via iCloud see the server appear with the api_key from
  `/api/accounts/users/me/` already populated in the Keychain
  payload (the v1.6.23 KVS plaintext fallback covers
  iCloud-Keychain-disabled devices). They treat it as a regular
  Dispatcharr API server and connect successfully.
- New Direct Connect servers also have an api_key in Keychain so
  downstream consumers (mpv, logos, recording playback) keep
  working even if the JWT layer is unavailable for any reason
  (cold launch before token store is populated, network blip
  during refresh, etc.).

### Contributors

Thanks to [@JCBird1012](https://github.com/JCBird1012) for two PRs that landed in v1.7.0:

- [#15](https://github.com/jonzey231/AerioTV/pull/15) `perf(network): reuse fetch sessions and preserve NW fallback timeouts` — replaces ad-hoc per-call URLSession instances with long-lived shared sessions for the large Xtream / Dispatcharr / XMLTV / Xtream series-detail fetches, and preserves request and session timeout intent when `HTTPRouter` falls back to `NWHTTPClient` so large HSTS-bypass requests no longer silently drop to the transport default timeout.
- [#16](https://github.com/jonzey231/AerioTV/pull/16) `fix(mpv): serialize shared playback state access` — moves the mpv handle and related lifecycle flags behind a lock-backed `PlaybackState` and routes cross-queue access through atomic helper methods. Fixes shutdown, background, and `hwdec`-fallback races; keeps the background auto-pause ownership checks consistent; and fixes the `autoPausedOnBackground` comment so it matches both background pause paths. Follow-on cleanup to PR #14.

## v1.6.23 - 2026-05-02

### Security

- **Stripped auth headers on cross-origin redirects.**
  `RedirectPreservingDelegate` previously re-applied `Authorization`
  and `X-API-Key` on every redirect, including cross-origin ones.
  HTTP standard requires stripping auth on cross-origin to prevent
  malicious or misconfigured servers from exfiltrating credentials
  via HTTP 301 to attacker-controlled hosts. New `isSameOrigin`
  check compares scheme + host + effective port; auth headers are
  preserved only when those match. Same-origin redirects (reverse-
  proxy canonicalization) keep working. The DEBUG audit log line
  now notes `auth preserved` vs `AUTH STRIPPED` per redirect for
  diagnostics.
- **Validated server-provided image URLs against an SSRF allow-list.**
  Logo / poster / backdrop URLs from Dispatcharr metadata used to
  flow straight into `URL(string:)` and fetch unconditionally. A
  malicious or compromised server could inject `http://192.168.1.1/`,
  `http://127.0.0.1:9191/`, or `file://` URLs and use AerioTV as
  a probe of the user's home network. New `validateAbsoluteURL`
  in `VODService.swift` enforces: only http/https schemes; the
  user's configured server host is allowed; TMDB CDN is allowed;
  loopback (127/8, ::1, localhost), link-local (169.254/16,
  fe80::/10), and RFC-1918 private ranges (10/8, 172.16/12,
  192.168/16, fc00::/7) are rejected unless they match the
  configured server host. Public hosts outside that list are
  allowed (we can't enumerate every legitimate CDN, and the
  threat model is server-side internal-network probing which the
  loopback / private blocks already handle).
- **Sanitized playback URL diagnostics.** The
  `print("[MPV-DIAG] URL: ...")` site at `MPVPlayerView.swift:2510`
  used to log the full playback URL, which for Xtream Codes
  servers embeds username/password directly in the path
  (`/live/<u>/<p>/<id>`). User console logs shared for support
  could leak credentials in plain text. v1.6.23 routes the URL
  through `DebugLogger.sanitize` before printing (existing
  redaction regex covers Xtream path-credentials and query-param
  forms). The mpv log-message callback path (also at
  `MPVPlayerView.swift:2594`) gets the same treatment so HTTP
  redirects and demuxer init lines from libmpv are sanitized
  before reaching the console.
- **Removed `aps-environment = development` from
  `SupportingFiles/Aerio.entitlements`.** AerioTV doesn't currently
  register for push notifications. Shipping a development APS
  environment in a Release build would silently break push
  registration if the feature were ever added. Entitlement is
  removed entirely; restoring with `production` is the right move
  if push is wired up later.
- **Added `PrivacyInfo.xcprivacy`.** Declares Required Reason API
  usage for App Review compliance: UserDefaults (CA92.1), file
  timestamps (C617.1), disk space (85F4.1), system uptime
  (35F9.1). Declares no tracking domains, no collected data
  types. **Action required:** the new file needs to be added to
  both iOS and tvOS target memberships in Xcode (drag into the
  project navigator, check both targets). Once that's done,
  `xcodebuild` will bundle it into the app on archive.

### Changed

- **Xtream EPG enrichment now has a circuit breaker.**
  `enrichXtreamEPG` previously fanned out 8 concurrent
  `get_short_epg` calls per batch with no abort signal. On a slow
  or rate-limited Xtream server, this could grind through every
  channel making failing requests for minutes. v1.6.23 mirrors
  the GuideStore prefetch breaker pattern: after 3 consecutive
  empty batches (where every channel either fails or returns no
  currently-airing program), enrichment aborts the remaining
  batches and accepts partial coverage for this launch. Logs
  include enriched count + batches processed + batches aborted
  so the failure mode is visible.
- **Inline form validation feedback in onboarding.** The Add
  Server flow used to grey out the "Test Connection" button
  when the form was incomplete with no indication of why. New
  `validationErrors()` method on `ServerConnectionViewModel`
  enumerates per-field problems (missing name, malformed URL,
  missing API key, etc.). The verify section in `AddServerView`
  now displays the first outstanding error inline above the
  button, with a count of additional issues if any. URLs are
  validated for `http://` or `https://` prefix and a non-empty
  host so common typos surface during entry rather than at
  submit time.

### Fixed

- **Channel logos now load on Dispatcharr-API playlists.**
  Logo URLs (`/api/channels/logos/<id>/cache/`) require the
  server's `X-API-Key` (or `Authorization: ApiKey ...` per the
  per-server auth mode added in v1.6.20), but every render site
  used either bare `AsyncImage` or `URLSession.shared.data(from:)`
  with no headers. Result: 401 on every fetch, blank placeholder
  on every channel. Reproduced on a Dispatcharr 0.23.0 Docker AIO
  deployment and on the iPad simulator (v1.6.22 field reports). Fixed
  by adding `LogoFetcher` (auth-header injection keyed on the
  active server's host) and routing every channel-logo fetch
  through it: `CachedLogoImage` (channel rows + EPG guide),
  replaced direct `AsyncImage` usage in `EPGGuideView`,
  `HomeView` banner + mini-player chrome, `CompactChannelRow`,
  `NowPlayingBridge.loadArtwork` (lockscreen artwork), and
  `CarPlaySceneDelegate.makeChannelItem`. Routes through
  `HTTPRouter` so plain-HTTP servers like
  `http://dispatcharr.goip.de:59192` get the same NWHTTPClient
  fallback every other API call uses.
- **Live TV no longer keeps streaming when you start a movie,
  TV episode, or recording.** `NowPlayingManager.shared.stop()`
  only clears single-stream state (`playingItem`, `isMinimized`).
  When the active session is `.multiview` (including a
  minimized one-tile multiview, which is what powers the
  mini-player), the `MultiviewStore` tiles and their mpv
  coordinators stayed mounted under the VOD `fullScreenCover`
  and kept decoding in the background. Field repro
  (v1.6.22 / v1.6.23): a live tile kept producing frames for 3+
  minutes after VOD started, with visible black-screen flickers
  in the VOD playback (GPU contention from the orphan live mpv).
  Fixed by routing `VODDetailView.resolveAndLaunch`
  and both `MyRecordingsView` playback launchers through
  `PlayerSession.shared.exit()` instead, which resets the tile
  store, flips `mode = .idle`, tears down `NowPlayingBridge`,
  and also calls `NowPlayingManager.shared.stop()` at the end
  so the single-stream case is still handled. Safe in
  single-stream mode: the multiview-specific branches inside
  `exit()` are guarded by `if let audioID = store.audioTileID`.
- **Servers added on a second device via iCloud sync now
  authenticate.** v1.6.12 stopped writing `_password` /
  `_apiKey` to the iCloud KVS payload on the assumption that
  iCloud Keychain (kSecAttrSynchronizable) would carry
  credentials cross-device. That assumption broke for any user
  who hadn't enabled iCloud Keychain on the receiving device,
  most commonly an Apple TV. The server metadata synced via
  KVS, the playlist rendered, every API call returned 401, and
  there was no UX recovery short of re-typing the API key on
  every device. Field repro (v1.6.22): user added a Dispatcharr
  playlist on iPad, enabled iCloud sync, opened AerioTV on
  Apple TV. The Apple TV saw the playlist but immediately
  showed "Connection Error: Invalid credentials". Fixed in
  `SyncManager.serialize` by re-including `_password` /
  `_apiKey` in the KVS dict, gated on
  `SyncCategory.credentials.isEnabled` so users who explicitly
  opted credentials out of sync don't get them shipped via KVS
  either. The Keychain write in `saveCredentialsSynced` stays
  the primary persistence; KVS is now the *transport* fallback
  for the no-iCloud-Keychain case. Renamed
  `purgeKVSPlaintextCredentialsIfNeeded` to
  `republishServersWithCredentialsIfNeeded`; on a new flag
  (`kvsCredentialRepublishDoneV1_6_23`) it forces an immediate
  non-debounced push so the legacy credential-stripped payload
  in KVS is overwritten with the v1.6.23 shape on first launch
  for existing multi-device users.
- **Skip on the Setting Up screen now actually dismisses it.**
  Field report (v1.6.22): "Skip did nothing" on the
  initial-launch loading cover. The Skip handler does set
  `showInitialEPGLoading = false`, but downstream `onChange(of:
  allServers.count)` and `.onAppear` triggers immediately
  re-fired `tryShowInitialLoading()` which re-presented the
  cover, so visually the dismissal was a no-op. Fixed by adding
  a session-level `userDismissedInitialLoading` flag.
  `tryShowInitialLoading()` early-returns when the user
  explicitly dismissed; the flag resets on cold launch so the
  next session re-evaluates whether the cover should appear.
- **Recording sync model documented.** The pre-release audit
  flagged "Recording not synced via iCloud" as a HIGH item. After
  re-checking the architecture: Dispatcharr-server recordings
  ARE already cross-device coherent because each device's
  `RecordingCoordinator.reconcileDispatcharrRecordings` fetches
  the canonical list from the server's `/api/channels/recordings/`
  endpoint and reconciles local SwiftData rows against it. Local
  recordings (LocalRecordingSession capturing to disk) are
  device-bound by definition since the file lives on the
  recording device. So no iCloud sync of Recording rows is
  needed; the audit finding has been retired with this rationale
  recorded in the model's comments.

### UX

- **Visible secondary-action button on iPhone channel rows.**
  Codex's UX review flagged that favorites and program info were
  reachable only through long-press, which most users never
  discover. iPhone Live TV rows now carry a visible
  `ellipsis.circle` button on the trailing edge that opens the
  same actions dialog the long-press already triggered. Tap-to-
  play is unchanged; long-press still works for power users.
  iPad rows keep their existing visible "Schedule" capsule and
  long-press; the wider iPad row would have crowded with another
  affordance.
- **Visible "Watch Live" pill on in-progress recording rows.**
  Tap-to-play already worked for in-progress Dispatcharr
  recordings on the new HLS DVR pipeline (v1.6.22), but the
  capability was invisible: users assumed in-progress rows were
  stop-only and the only path to live playback was the
  "Watch Live" context menu item. The recording row now shows a
  red "Watch Live" pill next to the "Server" label whenever
  `recording.status == .recording` and the server emitted a
  `dispatcharrFileURL` (which signals the new pipeline is
  available). Stop / cancel / delete remain in the context menu.
- **iPad channel search no longer destroys your query when you
  collapse the search field.** Hiding the search button used to
  clear `searchText`, which meant a user reclaiming chip-row
  space lost their filter as a side effect. v1.6.23 preserves
  the query: re-opening the field shows the previous search
  text. The collapsed search button visually indicates an active
  filter (filled glyph + accent color) so users can tell at a
  glance that the list is still filtered.



### Fixed

- **Series tab now populates on Dispatcharr servers that don't
  tag VOD items with `custom_properties.category_id`.** Real-world
  repro on a Synology Dispatcharr 0.23.0 deployment with 16,357
  movies and a configured Series library: movies populated fine
  (5,000 displayed via the v1.6.16 fallback path), but Series
  showed "No Series" because every series item lacked
  `category_id` and the per-item category filter rejected all of
  them. Series now mirrors the long-standing Movies behavior:
  when `category_id` is missing, the item is bucketed under the
  user's first enabled series category. Per-category grouping
  for series on these servers becomes best-effort (one bucket),
  but the user sees their content. Added the same
  `taggedFromCategoryID` / `taggedFromFallback` counters to the
  done log line so future diagnoses are easy.
- **Stopped the VOD refresh-loop on the Series and Movies tabs.**
  `TVShowsView.onAppear` and `MoviesView.onAppear` had a guard
  of `series.isEmpty && !isLoadingSeries` (and the movies
  equivalent) that re-fired `refreshSeries` every time SwiftUI
  rebuilt the view after a load that legitimately returned zero
  items. The field repro showed dozens of identical
  `loadSeries: starting` / `done, 0 series` cycles burning CPU
  and HTTP requests after the orchestrator had already
  completed. The guard now compares the active server's id to
  `currentSeriesServerID` (set the moment a load begins, retained
  even when the load returns zero items) so we tell "fresh
  server we haven't tried yet" from "already tried, server has
  no series." Pull-to-refresh and the empty-state Try Again
  button still bypass the guard since they call
  `refreshSeries` / `refreshMovies` directly. Same fix applied
  to `MoviesView.onAppear`.
- **Dispatcharr EPG: API-only path with EPGData bridge for
  mismatched tvg_ids.** This is the big one. Two compounding
  problems were causing channels to render blank in the Live TV
  guide on Dispatcharr-API mode for any user with a public-facing
  hostname (Cloudflare, Synology QuickConnect, port-forward).

  Problem 1: We followed the JSON bulk grid with a second pass
  against `{baseURL}/output/epg?tvg_id_source=tvg_id` to pick up
  `<category>` tags. That endpoint is not part of Dispatcharr's
  REST API, and Dispatcharr 0.23.0 (commit 3c55649, 2026-02-01)
  made it LAN-only by default via
  `network_access_allowed("M3U_EPG")`. Verified directly: the
  same API key returns 200 on a LAN URL and 403 on the public
  hostname of the same instance. We fell back to the bulk grid
  silently and the user never knew anything went wrong.

  Problem 2: The bulk grid keys programs by `EPGData.tvg_id`
  (the value Dispatcharr's XMLTV parser stamped at ingest), but
  our channel-side lookup keyed by `Channel.tvg_id` (the value
  the user can edit in Dispatcharr's web UI). On a real
  instance, 25% of channels with EPG data have these two
  fields disagreeing (verified by sampling the first 80 channels
  with `epg_data_id` set). Those channels missed the lookup and
  rendered blank, even with `/output/epg` working.

  v1.6.22 fixes both at once. `/output/epg` is dropped entirely
  from the Dispatcharr-API code path: `ChannelStore.loadAllEPG`
  and `GuideStore.fetchDispatcharr` now use only `/api/epg/grid/`
  (which works on every deployment regardless of network
  policy). To resolve the tvg_id mismatch, both paths first call
  the new `DispatcharrAPI.getAllEPGData()` (paginated
  `/api/epg/epgdata/?page_size=500`) to build an
  `epg_data_id → EPGData.tvg_id` lookup map, then bridge each
  channel's `epg_data_id` field to the correct grid key. A new
  `dispatcharrEPGDataID` field on `ChannelDisplayItem` carries
  the FK from the channel fetch through to the EPG match site.
  Net effect on tested instances: 100% bulk-grid coverage where
  the data exists; channels that previously appeared blank now
  populate. The pattern matches what Enhanced Channel Manager
  (an established Dispatcharr admin tool) uses for the same
  problem.

  Audited every Dispatcharr-mode code path (VOD, channels, EPG,
  playback) by spawning four read-only agents in parallel and
  one large-scale comparison against Dispatcharr/Teamarr/ECM
  upstream sources: confirmed the iOS app now uses **only**
  `/api/*` for metadata and `/proxy/*` for stream URLs. No
  `/output/epg`, `/output/m3u`, `/xmltv.php`, `/get.php`, or
  `/player_api.php` calls remain in `dispatcharrAPI` mode.

  Settings copy was updated to remove the now-stale
  `/output/epg` references.
- **Category enrichment via `/api/epg/programs/<id>/`.** The
  bulk `/api/epg/grid/` deliberately strips category data via
  the server's hand-rolled serializer (`EPGGridAPIView`). The
  per-program detail endpoint is the only REST path that
  returns the `categories` array. v1.6.22 fans out detail
  fetches for the currently-airing program of each channel
  after the bulk grid completes, throttled at cap-of-4 via
  AsyncSemaphore (~330 calls at 41ms each = ~3-7s in the
  background on a typical instance). Results are applied to
  both `ChannelStore.applyXMLTVCategories` (Live-TV channel
  card stripe) and the matching airing `GuideProgram.category`
  in `programs[cid]` (Guide-grid cell tinting). Two new
  models: `DispatcharrProgramDetail` (id, categories, rating)
  and a `programID: Int?` field on `DispatcharrCurrentProgram`
  parsed from the bulk grid's `id` field. Detached fan-out so
  initial sync isn't blocked; categories tint progressively as
  responses land.
- **Watch in-progress Dispatcharr recordings** via the
  server's new DVR pipeline
  (`/api/channels/recordings/<id>/hls/{seg_path}`).
  Dispatcharr's `custom_properties.file_url` field carries
  either a direct file URL (completed) or an HLS playlist
  (in-progress) for each recording; we now mirror that field
  into a new `dispatcharrFileURL: String?` on the SwiftData
  `Recording` model and use it in `MyRecordingsView.playServerRecording`.
  Falls back to the legacy hardcoded `/file/` URL on older
  Dispatcharr builds without the pipeline. Tap-to-play on a
  `.recording` row is now allowed when the file_url is
  present; a new "Watch Live" context menu item is gated the
  same way. Auth headers (`server.authHeaders`) propagate to
  mpv via `http-header-fields`, and the HLS playlist's segment
  URLs route through the same wrapper endpoint so auth
  carries through.
- **Faster VOD loading on large libraries.** Bumped
  `/api/vod/movies/` and `/api/vod/series/` paginated calls
  from `page_size=25` to `page_size=100` (Dispatcharr's hard
  cap, verified by probing). 4x reduction in HTTP volume per
  load. For a 16,357-movie library that's 654 paginated calls
  reduced to 164. Applied to every list/category/search call
  site.
- **Future local recordings no longer schedulable as an
  impossible state** (Codex P1). The Record Program sheet
  used to offer "This device" as a destination for future
  Dispatcharr programs, but the row could never start (no iOS
  background scheduler, no manual-start UI). Three layers of
  defense in `RecordProgramSheet.swift`: `.onAppear` forces
  destination to `.dispatcharrServer` when `!isLive`; the
  destination picker is hidden entirely for future programs
  (only one valid choice); `scheduleRecording()` coerces
  belt-and-suspenders if any future call site bypasses the
  UI gates. Live programs ("Record from Now") still allow
  both destinations because the recording starts immediately
  while the app is foregrounded.
- **EPG performance on overloaded servers.** Three changes
  driven by a 2,186-channel Cloudflare-tunneled Dispatcharr
  deployment where the bulk grid response was getting
  truncated (`NSURLError -1017 cannot parse response`):
    - `prefetchIfNeeded` now gated on `!isLoading`; per-cell
      prefetch no longer races the bulk grid for the same
      uWSGI worker pool. Twenty visible cells each timing out
      at 5s used to trip the circuit breaker before the grid
      even started.
    - `getEPGGrid` request timeout bumped 60s -> 180s,
      resource 180s -> 600s. Slow-but-alive servers serializing
      a 2,000+ channel grid need the headroom.
    - Per-cell `getUpcomingPrograms` timeout bumped 5s -> 15s
      now that it no longer races the bulk grid.
    - New diagnostic for `NSURLError -1017`: logs that the
      reverse proxy truncated the upstream response (server
      worker pool saturated; client-side retry won't help).
- **`/api/epg/programs/<id>/` timeout aligned with slow-server
  regime.** Bumped 8s -> 30s. The fan-out runs after the bulk
  grid succeeds, which on overloaded servers can take 90s+;
  8s was misaligned with that regime and silently failed
  enrichment exactly when the grid was already proving the
  server is responsive but slow.
- **Self-healing cache for stuck-sparse states.** A second-order
  bug surfaced during the XMLTV-removal investigation: when an
  EPG fetch wrote programs for only a handful of channels (8 of
  333 in a field capture), `GuideStore.saveToCache`
  persisted that partial dataset and `loadFromCache`'s 24h
  freshness check treated it as canonical on every subsequent
  launch. Pull-to-refresh worked, but no one knows to do that.
  The orchestrator (`HomeView` phase 2 EPG) now also checks
  coverage ratio: if `cacheIsFresh && hasFuturePrograms` BUT
  `guideStore.programs.count < channelStore.channels.count *
  0.25`, it logs the sparseness explicitly and forces
  `loadAllEPG` to run anyway. Healthy Dispatcharr instances
  cover >70% so the override only fires on genuinely broken
  cache states.
- **Diagnostic logging on the (now M3U-only) XMLTV fetch path.**
  Replaced the `try?` swallow in `performXMLTVFetch` with a
  logged do/catch that surfaces the HTTP status code, so M3U
  XMLTV failures (which still go through this function) are
  diagnosable from the log without curl-probing.
  `XMLTVParser.fetchAndParse` now accepts an optional `headers`
  dictionary for callers that need to authenticate to a private
  XMLTV URL (infrastructure kept for future use; the Dispatcharr
  call sites that previously passed Dispatcharr auth are
  retired).

### Changed

- `currentMoviesServerID` and `currentSeriesServerID` on
  `VODStore` promoted from `private` to
  `@Published private(set)` so the views' onAppear guards can
  read them.
- `EPGGuideView.fetchDispatcharr` enrichment fan-out detached
  so the Guide tab opens immediately on grid completion;
  category tints land progressively as detail responses
  arrive.
- `DispatcharrAPI` and `XtreamCodesAPI` now share a single
  static `JSONDecoder` instance instead of allocating one per
  call. Replaces ~18 per-call instantiations across the
  initial-sync hot path.

### Infrastructure

- **`project.yml` (XcodeGen) reconciled with the actual
  project** (Codex P2). Was still describing an older
  `Dispatcharr`-branded ancestor that would have produced an
  unsignable project shape if anyone regenerated from it.
  Renamed to Aerio, replaced bundle IDs
  (`app.molinete.Dispatcharr` -> `app.molinete.aerio`),
  app-group identifiers
  (`group.app.molinete.Dispatcharr` ->
  `group.app.molinete.aerio.topshelf`), splash resource path
  (`App/DispatcharrSplash.mp4` -> `App/AerioSplash.mp4`),
  Top Shelf bundle (`Dispatcharr.TopShelf` ->
  `aerio.TopShelf`), and version markers (1.6.4 -> 1.6.22).
  Added a header comment noting the file is informational,
  not authoritative; `.xcodeproj` remains canonical.

### Removed

- Dead `XtreamCodesAPI.xmltvURL()` helper. Audit confirmed
  zero callers; constructed credentials in a query string,
  bad smell. Per-stream EPG enrichment via
  `getEPG(streamID:)` is the active path for Xtream EPG.

## v1.6.21 - 2026-05-01

### Fixed

- **Plain-HTTP Dispatcharr connections no longer fail with auth
  errors.** `NWHTTPClient` (the Network.framework client used for
  HTTP requests that URLSession rejects under ATS) built its request
  lines from Foundation's `URL.path`, which drops the trailing slash
  whenever a query string is present. So
  `/api/channels/groups/?page_size=1` was silently rewritten to
  `/api/channels/groups?page_size=1`. Django/DRF requires the
  trailing slash; without it, the request misses the channel-groups
  view, falls through to a catch-all that returns 401 or 404, and
  AerioTV's verify code treats the response as auth-rejected.
  v1.6.21 switches `NWHTTPClient.buildRequestBytes` to
  `URLComponents.percentEncodedPath` + `percentEncodedQuery`, which
  preserve the original URL exactly. Affects anyone running AerioTV
  against a plain-HTTP Dispatcharr URL whose TLD is on iOS's HSTS
  preload list, or any HTTP URL that hit URLSession's -1022 ATS
  fallback path.
- **Adding a Dispatcharr server with a large library no longer
  freezes the server during initial sync.** A real-world repro on
  Apple TV against a server with 3,640 channel groups, 1,574 VOD
  categories, and 2,174 channels showed AerioTV firing channels +
  VOD movies + VOD series + EPG fetches in parallel during initial
  sync. The combined paginated request burst exhausted the upstream
  uwsgi/Daphne worker pool, EPG prefetches timed out, the container
  locked up, and a force-restart was required. Multiple coordinated
  fixes:
  - **Concurrency cap of 2**: a new `AsyncSemaphore` actor caps
    in-flight DispatcharrAPI requests at 2 across the entire app.
    Routed every paginated stream through the shared session so it
    counts against the cap (VOD pagination previously created its
    own URLSession and bypassed any throttle). The cap stays well
    under a typical self-hosted Dispatcharr's 4-to-8 worker pool.
    XMLTV runs through a separate session so peak in-flight is
    cap+1 = 3 simultaneous requests during EPG phase.
  - **Single orchestrator task**: replaces two parallel `.task(id:)`
    blocks. The original split sequenced across `channelServerKey`
    and `vodServerKey`, but SwiftUI starts those blocks in
    non-deterministic order, so the VOD task could fire first,
    observe `channelStore.isLoading == false` before the channel
    task had even called `refresh()`, and fall straight through to
    fan VOD movies + VOD series in parallel with channels and EPG.
    Collapsing into one orchestrator on a combined key
    (`channel || vod`) removes the race. Sequencing is now
    enforced by `await`, not by polling shared state.
  - **Sequenced initial sync**: phases run strictly in order:
    channels, then EPG, then VOD movies, then VOD series. Live TV
    List populates first (a few seconds), then the guide fills in,
    then VOD which the user is least likely to be staring at on
    first launch.
  - **VOD pagination item cap (5,000 per type)**: real-world
    probing of a self-hosted Dispatcharr 0.23.0 found a server
    with 351,644 movies and 85,446 series. Even with the cap of 2
    in flight, paginating the entire library at 25 items per page
    would take 14,000+ sequential pages and 12+ hours of HTTP
    work. AerioTV now stops after 5,000 items per type. Most users
    have well under 5,000 VOD items per type, so the typical
    experience is unchanged; this protects against pathological
    setups.
  - **VOD pagination circuit breaker**: mirrors the EPG breaker.
    Three consecutive page-fetch timeouts abort the stream with a
    clear error rather than burning the full 60s per page on a
    server that's already overloaded.
  - **Skip secondary XMLTV when bulk EPG fails**: if `/api/epg/grid/`
    returns an error, AerioTV no longer follows up with the XMLTV
    bulk download (which would tie up another server worker for
    30+ seconds chasing data the server can't provide). Falls back
    to lazy per-cell loading instead.
  - **Request timeout bumped from 20s to 60s**:
    `URLSessionConfiguration.timeoutIntervalForRequest` was 20s,
    which cut off `/api/epg/grid/` mid-stream on the same large
    server (24.3 MB JSON, ~30s download). 60s comfortably covers
    the EPG grid plus headroom for slower deployments.
- **iCloud Keychain credential sync no longer leaves a stale local
  Keychain entry winning over the freshly synced value.** Adding a
  Dispatcharr server on one device and syncing it to a second device
  could leave Test Connection failing on the second device with HTTP
  401 because a stale local-only Keychain entry shadowed the
  iCloud Keychain copy. `effectivePassword` and `effectiveApiKey`
  now prefer the iCloud Keychain copy when credential sync is
  enabled, falling back to the local copy for offline-first
  semantics when sync is off. The save path also now prefers
  in-memory edits over cached Keychain values so a user can rotate
  credentials on this device even when an older value is still
  present locally or in iCloud Keychain.
- **tvOS Configure-screen text fields no longer hide typed text.**
  When a `TextField` is focused on tvOS the system fills it white
  and expects dark text, but our explicit `.foregroundColor(.textPrimary)`
  (light) was overriding that and leaving the typed text invisible
  on the white fill. On tvOS, `AppTextField` now switches to
  `.black` foreground when focused so typed text contrasts.
- **tvOS Configure-screen text not vertically centered when
  focused.** The focused `TVTextField` paints typed text top-aligned
  within the 52pt field height, leaving it visually misaligned with
  the leading icon. `.frame(maxHeight: .infinity, alignment: .center)`
  on the inner field tells SwiftUI to expand and center the text.

### Added

- **`/api/core/version/` to verify candidate paths.** Dispatcharr
  v0.23.0+ moved the version endpoint from `/api/version/` to
  `/api/core/version/`. Legacy paths stay in the candidate list for
  older builds.
- **Cloudflare Tunnel / origin-unreachable error detection in the
  verify error message.** When the response is an HTTP 5xx with a
  body that names a Cloudflare 1xxx error (1033, 1016, 521, 522,
  523, 524) or contains "cloudflare-1xxx", AerioTV now tells the
  user the issue is between Cloudflare and their origin (container
  stopped, `cloudflared` daemon stopped, origin offline) instead of
  burying it in the generic "couldn't recognise the response"
  message.
- **Bookend phase logs in the initial-sync orchestrator.** Each
  phase boundary now prints `🟢 [Orchestrator] phase N BEGIN/done`
  with elapsed seconds, so a freeze can be pinpointed to the exact
  await that's parked.

### Changed

- **Verify error message updated for Dispatcharr v0.23.0+ UI.**
  References the redesigned User Settings tabs (Account,
  Permissions, EPG Defaults, API & XC) instead of the pre-0.23.0
  "System -> Users -> Edit User -> API & XC" path. Calls out the
  v0.23.0 Admin tier requirement (`user_level >= 10`) introduced
  by PR #1190 (Hardening) when an API key authenticates but every
  probe is rejected.
- **tvOS focus styling cleaned up across onboarding and Configure
  screens.** Removed the scale-up, brightness bump, and accent
  shadow from `TVNoHighlightButtonStyle`. The 2pt accent stroke
  ring on focus is now the only focus indicator; the previous
  pop-out feedback was distracting and pushed text too close to
  row borders. Same change applied to onboarding picker rows,
  Sync via iCloud card, and the Configure screen's Test
  Connection / Save Playlist buttons.
- **Connect a Server now matches Sync via iCloud as a card row.**
  Previously a filled-gradient primary CTA pill, now an outlined
  card with leading icon tile + label + chevron, sharing the
  `tvOnboardingCardBG` background with Sync via iCloud so the
  welcome screen reads as a column of matching siblings.

### Contributors

Thanks to [@JCBird1012](https://github.com/JCBird1012) for [#12](https://github.com/jonzey231/AerioTV/pull/12), fixing a Dispatcharr API authentication issue where playlists weren't syncing properly across multiple devices.

## v1.6.20 — 2026-04-29

### Fixed

- **Dispatcharr server recording playback no longer fails with
  HTTP 503.** The `/api/channels/recordings/<id>/file/` endpoint
  was originally documented as `AllowAny` (no auth required), but
  newer Dispatcharr builds tightened the route to require the
  same auth headers as the rest of the API. AerioTV was passing
  `headers: [:]` when handing the URL to mpv, so the request
  arrived with no credentials and the server rejected it.
  `MyRecordingsView.playServerRecording` now plumbs
  `server.authHeaders` (honouring the auto-detected
  `dispatcharrHeaderMode`) through `PlayingRecording` to
  `PlayerView`'s `headers` parameter, which feeds
  `mpv_set_option_string("http-header-fields", …)`. Harmless on
  builds still serving `/file/` as AllowAny (the extra headers
  are ignored), required on builds that have tightened the route.
- **Tap a completed recording row to play it on iPhone / iPad.**
  Previously, iOS list rows in My Recordings only responded to
  long-press → context menu → Play. Now the standard interaction
  pattern applies: tap to play (gated to `completed` /
  `stopped` rows so scheduled / in-progress rows still ignore
  taps), long-press for the full context menu (Play, Stop /
  Cancel, Delete, Download, Apply Comskip; whatever applies to
  the row's status), swipe left for swipe actions. `contentShape`
  makes the whole row the tap target so users don't have to
  land precisely on the title text. tvOS already had tap-to-play
  via `TVRecordingRow.onSelect`.
- **Dispatcharr Test Connection no longer 401s on deployments
  that require dual auth headers.** Three users on private
  Dispatcharr instances (one of them at
  `http://dispatchar.domain.com:9191`) reported HTTP 401 on
  Test Connection in v1.6.19 with valid Admin API keys. Root
  cause: v1.6.16's "X-API-Key alone" change (which fixed a VOD
  episodes filtering bug on the user's main server) is rejected
  by some Dispatcharr builds — they require the legacy
  `Authorization: ApiKey <key>` header that pre-1.6.16 sent
  alongside it. v1.6.20 auto-detects the working header shape:
  on Test Connection, AerioTV tries X-API-Key alone first
  (preferred — preserves full VOD episode visibility), falls
  back to dual headers (`Authorization: ApiKey` + `X-API-Key`)
  on HTTP 401, then to bearer-token auth as a final fallback.
  The discovered shape is persisted on the per-server
  `dispatcharrAuthMode` field (synced via iCloud) so subsequent
  API calls and stream playback skip re-discovery and
  immediately speak the right shape.

### Added

- **Silent auto-discovery on app launch.** Closes the upgrade
  window where a user who installed v1.6.20 but didn't manually
  re-tap Test Connection was left with the back-compat default
  (`.both` / dual headers), which could briefly resurface the
  v1.6.16 VOD-episodes-empty bug for some series. The launch-time
  hook in `AerioApp` (`discoverDispatcharrAuthModeIfNeeded`)
  scans every Dispatcharr server with `isVerified == true` and an
  empty `dispatcharrAuthMode`, fires a detached background
  `verifyConnection` against each, persists the discovered shape
  through a fresh main-actor `ModelContext`, and triggers an
  immediate iCloud push so every device on the user's Apple ID
  inherits without each having to re-discover. Re-runs after
  iCloud sync delivers fresh remote servers (catches the case
  where a server was added on a pre-v1.6.20 device that never
  knew to discover). No-op once every server has a persisted
  shape; silent on failure (next launch retries).
- **Per-server `dispatcharrAuthMode` SwiftData field** —
  `""` / `"xapikey"` / `"both"` / `"bearer"`. Auto-populated
  during Test Connection. Synced across devices via
  `SyncManager` so once one device discovers the working shape,
  every other device on the same iCloud account inherits it.
  Empty string (no detection yet) falls through to `.both` for
  back-compat with stream-playback header construction —
  matches what shipped pre-v1.6.16 so existing installs don't
  regress on upgrade.
- **`DispatcharrAuthHeaderMode` enum** in `Models/Models.swift`
  exposing the three shapes as a type-safe value with raw-string
  bridging for SwiftData stability.
- **`RedirectPreservingDelegate` on `DispatcharrAPI.session`** —
  re-applies `X-API-Key`, `Authorization`, `Accept`,
  `Content-Type`, and `User-Agent` to redirected requests so
  HTTP 301/302/307/308 hops behind a reverse proxy don't strip
  the credentials and produce a misleading 401. Belt-and-
  suspenders against the same class of failure as the auth-
  shape mismatch — different root cause, same symptom.
- **`discoveredAuthMode: DispatcharrAuthHeaderMode?` on
  `DispatcharrServerInfo`** — the working shape returned from
  `verifyConnection` so the caller can persist it on the
  `ServerConnection` model.
- **`discoveredDispatcharrAuthMode` on `ServerConnectionViewModel`**
  + persistence into `buildServerConnection` so adding a server
  through Settings → Add Server captures and saves the working
  shape on save.

### Changed

- **`ServerConnection.authHeaders`** now consults the per-server
  `dispatcharrHeaderMode` instead of always emitting dual
  headers. Stream playback (which uses these headers via mpv's
  `--http-header-fields` plumbing) inherits the auto-detected
  shape so stream URLs that need a specific shape work after
  Test Connection runs. Empty/unknown mode falls back to
  `.both` (the historical pre-v1.6.16 shape) so users who
  haven't re-tested their connection on v1.6.20 keep working.
- **`DispatcharrAPI` initializer** gained an `authMode:` parameter
  (default `.xapikey` to preserve the v1.6.16+ VOD-episode
  behavior). `headers` factored into `headers(for:)` so
  `verifyConnection` can iterate header shapes locally without
  mutating the struct.
- **`DispatcharrAPI.buildURL`** migrated from naive string
  concatenation to URLComponents, preserving non-default
  ports, IPv6 host literals, and pre-existing baseURL path
  components correctly. Pulled in alongside the auth work
  because one of the affected users runs at
  `http://dispatchar.domain.com:9191` — port preservation is
  the kind of thing URLComponents handles by definition.
- **Dispatcharr Test Connection error messages** rewritten to
  distinguish "every shape rejected (likely wrong key or non-
  Admin user)" from "mixed auth/non-auth failure (URL or
  reverse-proxy quirk)" from "got the SPA shell instead of
  the API" from "couldn't recognise the response at all". The
  v1.6.19 single message dumped the raw HTML body for everything
  and didn't tell users what to try.
- **Construction sites updated** — every `DispatcharrAPI(...)`
  callsite that has a `ServerConnection` reference (or
  `ServerSnapshot`) now passes the per-server `authMode` and
  `userAgent` so off-main-thread API calls use the right shape:
  `VODService` (4 sites), `MyRecordingsView` (2),
  `SettingsView` Test Connection, `HomeView` (7),
  `EPGGuideView` (2), `ChannelListView`, `VODDetailView`,
  `RecordProgramSheet`, `ServerSyncView` (4),
  `ServerConnectionViewModel` verify path. The verify call
  intentionally keeps the default `.xapikey` so discovery
  always starts from the preferred shape.
- **`ServerSnapshot`** gained `dispatcharrAuthMode` and
  `userAgent` fields so background-thread VOD / channel /
  EPG fetches construct DispatcharrAPI clients with the
  per-server shape instead of falling back to the hard-coded
  default.

## v1.6.19 — 2026-04-29

### Reverted

- **Stream Info no longer pulls Dispatcharr server-side stats.**
  v1.6.18 added a 5-second polling Task that hit
  `/api/channels/streams/{id}/` and rendered Dispatcharr's
  `stream_stats` blob (resolution, FPS, codec, ffmpeg output
  bitrate, viewer count) when the active server was Dispatcharr
  API. v1.6.19 reverts that path entirely. Reasoning: those
  numbers describe what the SERVER is doing, not what the
  device is actually decoding — users open Stream Info to see
  whether their playback is healthy on this device, so
  mpv-derived stats are the more useful and more honest
  source. Same numbers everywhere also means consistent UX
  across server types and one less moving part to maintain.

### Changed

- **Stream Info overlay layout restored to the original 6-row
  format.** The v1.6.18 5-field redesign (RES / FPS / VIDEO /
  AUDIO / RATE) read too small and dropped fields users
  actually wanted (pixel format, hwdec mode, A/V sync,
  dropped-frame counter, cache duration). v1.6.19 brings back
  VIDEO / "" / "" / AUDIO / CACHE / SYNC — codec + dimensions,
  fps + pixel format, hwdec, audio codec + sample rate +
  channel count, cache duration + bitrate, A/V sync + drops.
  Identical card on iPhone, iPad, and Apple TV; identical card
  on every server type.

### Removed

- `DispatcharrStreamStats`, `DispatcharrStreamDetail`, and
  `DispatcharrAPI.getStreamDetail(streamID:)` in
  `Networking/StreamingAPIs.swift` — no longer needed once the
  Stream Info overlay stopped fetching server-side stats.
- `dispatcharrStreamIDs: [Int]?` on `ChannelDisplayItem` and the
  matching assignment in HomeView's `fetchDispatcharr` — the
  field existed only to feed the polling Task.
- `serverSideStats` / `serverSideViewers` on `PlayerProgressStore`.
- `serverStatsPollTask` State + `startServerStatsPoll` /
  `stopServerStatsPoll` / `fetchOnce` helpers from both
  `PlayerView` and `MultiviewContainerView`.

### Kept from v1.6.18

- `streamInfoIsVisible` flag on `NowPlayingManager` (drives the
  channel info banner suppression while Stream Info is open) —
  retained.
- `.ignoresSafeArea(edges: .top)` on the chrome / banner /
  Stream Info overlays (fixes the v1.6.17 iPhone-portrait
  safe-area double-count) — retained.

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
