# AerioTV

AerioTV is a native IPTV streaming application for iOS, iPadOS, tvOS, and macOS (using the iPad app). It connects to Dispatcharr via API Key, Xtream Codes, and M3U playlist servers to deliver live TV, movies, and series with a full electronic program guide (EPG) when supplied by the user.

[Download via Apple App Store](https://apps.apple.com/us/app/aeriotv/id6760727974) 
- This will usually lag behind the TestFlight version.

[Download via Apple TestFlight](https://testflight.apple.com/join/JfszBGQP) 
- This version may have bugs but will always be the latest.

Sideload using your preferred method using the .ipa from [Releases](https://github.com/jonzey231/AerioTV/releases).
- This version will occasionally be ahead of the Apple Testflight version.

## Features

A native Apple-platform IPTV client. Stream live TV with full EPG,
browse on-demand movies and series, schedule recordings to a
Dispatcharr server or to your device, and watch up to 9 channels
at once with Multiview — across iPhone, iPad, Apple TV, and macOS
(running the iPad app), with iCloud sync stitching it all
together.

Click each section for the full list:

<details>
<summary><strong>Live TV & Guide</strong> — MPV-powered playback, list + grid views, EPG, reminders.</summary>

- MPV-powered, GPU-accelerated playback
- List view + full EPG guide (grid on iPad/tvOS, list on iPhone)
- Program titles, descriptions, and time slots
- Channel info banner identifies the channel + program when a stream starts
- Sort channels by number, name, or favorites
- Tap to play, long-press for favorites
- Long-press an upcoming program to set a reminder or schedule a recording
- EPG reminders fire 5 minutes before the program starts; sync via iCloud
- EPG window configurable from 6 hours up to the full available window
- Channels without guide data still selectable from the grid

</details>

<details>
<summary><strong>Multiview</strong> <em>(v1.6.0)</em> — up to 9 streams at once.</summary>

- Watch up to 9 live channels at once in a dynamically-sized grid
- Enter from any playing channel: tap the grid button (iPad) or
  Options → Enter Multiview (tvOS)
- Layouts adapt to tile count: 1, 2, 3 asymmetric, 2×2, 5
  asymmetric, 3×2, 7 centered, 3×3 with center gap, full 3×3
- Only the most recently added stream plays audio; tap any tile
  (iPad) or Select (Siri Remote) to move audio focus
- Long-press menu on every tile: Make Audio / Full-Screen in
  Grid / Audio Track / Subtitle Track / Move Tile / Remove
- Move Mode for rearranging tiles (long-press → "Move Tile")
- Picture-in-Picture from multiview on iPad — only the audio
  tile continues; other tiles pause to conserve resources
- Performance warning at the 5th tile (2-hour throttle); hard
  cap at 9 tiles; thermal watchdog stops new tiles at
  `.critical` device temp

</details>

<details>
<summary><strong>DVR Recording</strong> <em>(v1.5.0)</em> — server-side on Dispatcharr, local on every server type.</summary>

- Schedule live or upcoming programs from the Live TV guide
- **Dispatcharr server-side recording** — continues even when
  AerioTV is closed (the server runs the recording); ideal for
  unattended recordings
- **Local recording on this device** — records to
  `Documents/Recordings` (or a user-chosen folder on iOS).
  Available for Dispatcharr, Xtream Codes, and M3U
- Per-recording pre-roll (start early) and post-roll (end late)
  buffers: None / 5 / 10 / 15 / 30 / 60 min or custom
- **Remove Commercials (Comskip)** — server-side processing on
  Dispatcharr; toggle at schedule time or run post-recording
- DVR tab appears automatically when there's at least one
  recording, with Scheduled / Recording / Completed segments
- Auto-discovery of recordings scheduled outside the app
  (Dispatcharr web UI) — they show up in AerioTV within ~2 min
- Download completed server recordings to local storage
- Local storage quota with live usage bar (1–200 GB,
  default 10 GB) and low-storage warnings
- iOS Files app access ("On My iPhone → AerioTV")
- Keep-device-awake toggle so a local recording isn't
  interrupted by display sleep

</details>

<details>
<summary><strong>Movies & TV Shows</strong> <em>(Dispatcharr & Xtream Codes)</em> — VOD library, Continue Watching, TMDB-rich metadata.</summary>

- Browse and filter on-demand content by category
- TMDB-rich metadata on Dispatcharr (backdrop, plot, cast,
  director, year, rating, runtime; per-episode air dates,
  ratings, IMDB IDs, and per-episode artwork)
- Provider-supplied metadata on Xtream Codes (poster, title,
  one-line plot)
- Continue Watching — resume movies and episodes; progress
  syncs across devices via iCloud
- Long-press to remove items from Continue Watching
- Per-playlist VOD toggle in Settings → Edit Playlist
- Series and movie detail caches make second-opens instant

</details>

<details>
<summary><strong>Player</strong> — chrome, Stream Info, Sleep Timer, AirPlay, PiP, swipe channel-flip.</summary>

- Tap to summon chrome; auto-fade after 5s of inactivity
- Single overflow menu (iOS) / Options panel (tvOS) for all
  secondary controls
- Audio track + subtitle track selection
- Playback speed (0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×) for VOD —
  not available on live streams
- Sleep Timer (30 / 60 / 90 / 120 min), with a countdown in the
  overflow menu
- Audio Only mode
- AirPlay
- Picture-in-Picture on iOS — swipe home during playback and
  the stream continues in a floating window
- **Stream Info overlay** — codec, resolution, FPS, pixel
  format, hardware decode status, audio codec + sample rate +
  channel count, cache duration, bitrate, A/V sync, and
  dropped-frame count. Sourced from mpv on every server type
  (Dispatcharr, Xtream Codes, M3U) so you see what the device
  is actually decoding, not what the upstream server reports
- **Channel-flip gestures** — Up/Down on the Siri Remote
  (Apple TV) or swipe up/down with chrome visible (iPhone /
  iPad) to flip channels in single-stream playback

</details>

<details>
<summary><strong>iCloud Sync</strong> — granular categories, scoped delete, set-up-once.</summary>

- Server configurations, preferences, VOD watch progress, EPG
  reminders, and per-playlist sort order sync across all your
  Apple devices
- Uses iCloud Key-Value Storage
- Granular per-category sync controls in Settings *(v1.6.17+)*
  — opt out of any category individually
- Per-category "Delete from iCloud" actions for scrubbing stale
  state without affecting local data
- Set up once on one device and your other devices pick up the
  same data on launch

</details>

<details>
<summary><strong>Apple TV</strong> — Siri Remote, Top Shelf, floating player, LAN detection.</summary>

- Full Siri Remote support with d-pad navigation
- Options panel for audio, subtitles, speed, sleep timer, and
  stream info
- Up/down on the Siri Remote changes channels during
  single-stream live playback
- Press Menu to minimize live TV to a floating corner player;
  press Menu again to stop
- Channels and logos sized for living-room viewing
- LAN detection probes local server URLs automatically — no
  SSID configuration needed
- **Top Shelf** — your 6 most-watched channels (with the
  current program), plus a Continue Watching row of movie and
  episode posters. Populates as soon as AerioTV is on the top
  row of the Apple TV Home screen — no setup

</details>

<details>
<summary><strong>iPhone & iPad polish</strong> — gestures, layouts, mini-player, multiview safe-area carve-outs.</summary>

- Mini-player (iPhone bottom bar / iPad top-right corner) keeps
  the stream alive while you browse the guide, settings, or
  on-demand library
- Pinch-to-zoom-out shrinks the iPad player to the corner mini
  *(v1.6.13+)*
- Swipe down to dismiss / minimize the player on iPhone
- iPhone multiview respects the notch and Dynamic Island —
  tiles render inside the safe area, black background fills
  the corners around the cutout *(v1.6.17+)*
- iPad / Mac Catalyst use the iPad app as-is; macOS gets the
  full iPad experience including multiview

</details>

## Supported Server Types

AerioTV connects to three different playlist types. Each unlocks a
different set of features. If you're choosing between them, the
short version is:

Click each type for the full breakdown:

<details>
<summary><strong>Dispatcharr API</strong> <em>(Recommended)</em> — Native API with API key authentication. <em>Most full-featured option.</em></summary>

[Dispatcharr](https://github.com/Dispatcharr/Dispatcharr) is a
self-hosted IPTV middleware that gives users control over their IPTV services.
See the linked GitHub.

**Benefits Dispatcharr is uniquely good at**

- **Server-side DVR** — schedule recordings that continue running
  even when AerioTV is closed or the device is asleep. (Local
  recording to the device works on every server type, but Dispatcharr
  is the only one where the server itself can run the recording.)
- **Comskip (commercial-skip)** — toggle when scheduling a server-side
  recording or run it post-recording from the DVR tab. Comskip runs
  on the Dispatcharr server, so it's only available for server-side
  recordings.
- **Server-side recording playback** — stream completed server
  recordings directly with HTTP Range support, no auth headers
  needed.
- **Server-side stream failover via channel UUID** — when a primary
  stream dies mid-playback, Dispatcharr swaps to a backup provider
  transparently. The player doesn't even hiccup. (Xtream Codes has
  client-side URL fallback — Aerio tries `.m3u8` then `.ts` — but
  the server can't swap to a different provider on its own.)
- **TMDB-enriched VOD metadata** — backdrops, plots, cast, director,
  year, rating, runtime, plus per-episode air dates, TMDB ratings,
  IMDB IDs, and per-episode artwork. Pulled in by Dispatcharr's
  TMDB scraper. (Xtream Codes also has VOD, but its metadata is
  whatever the provider supplies — usually poster + title +
  one-line plot, not TMDB-grade.)
- **Bulk EPG fetch** — one network call returns -1h to +24h for
  every channel via `/api/epg/grid/`. Xtream Codes uses per-stream
  EPG calls; M3U pulls XMLTV from a separate URL.
- **Per-server custom User-Agent override** — set in Settings →
  Edit Playlist. Sent on every Dispatcharr API request and to mpv
  on playback so the value shows up in Dispatcharr's admin Stats
  panel. Not currently exposed for XC or M3U.
- **External XMLTV URL override** *(advanced)* — point the EPG at
  a third-party XMLTV source while keeping channels from
  Dispatcharr's API. (M3U has its own EPG URL field — it's the
  primary EPG source there, not an override.)
- **Auto-discovery of recordings scheduled outside the app** —
  recordings you scheduled from the Dispatcharr web UI appear in
  AerioTV's DVR tab within ~2 minutes. XC / M3U don't have a
  server-side scheduler to discover from.

**Drawbacks**

- **Requires self-hosting.** You need to run Dispatcharr (Docker,
  NAS, home server) — there's no SaaS offering. If you just want
  to paste a provider URL and watch, M3U or Xtream Codes is faster
  to get going.
- **Initial scrape time.** Adding a Dispatcharr server with a
  large upstream provider can take a few minutes to populate the
  channel list, EPG, and VOD library on the first launch.
- **You're on the hook for keeping it running.** Server-side DVR
  is great until the server is down at recording time.

</details>

<details>
<summary><strong>Xtream Codes</strong> — IPTV Source URL + username & password authentication. <em>No self-hosting required.</em></summary>

The Xtream Codes API is what most IPTV providers natively expose.
You log in with the username / password your provider gave you and
AerioTV pulls live TV, movies, and series.

**Benefits**

- **No self-hosting.** Most IPTV providers expose an Xtream Codes
  endpoint by default — paste the URL, type your credentials, done.
- **Live TV + VOD library.** Movies and series come from the same
  login as live channels — no separate EPG / VOD URLs to manage.
- **Per-playlist VOD toggle.** Settings → Edit Playlist exposes
  the same "Fetch VOD from this playlist" switch Dispatcharr does,
  so you can keep a sandbox / secondary playlist's Live TV
  without loading its VOD library every launch.
- **Local DVR with pre-roll / post-roll.** Recordings on this
  device, with the same buffer pickers (None / 5 / 10 / 15 / 30 /
  60 min or custom) Dispatcharr server-side recordings get.
  Recordings continue while the app stays running.
- **EPG via TVG ID matching** — most provider EPGs key to
  Xtream's `tvg_id` field automatically.
- **Client-side stream URL fallback** — Aerio tries `.m3u8` first,
  then `.ts`, so a transient HLS hiccup doesn't kill playback
  outright.
- **Familiar auth model** — single username and password.

**Drawbacks**

- **VOD metadata is provider-supplied, not TMDB-enriched.** You
  typically get the poster, title, and one-line plot. Per-episode
  air dates, TMDB ratings, and per-episode artwork are not
  available.
- **No server-side DVR.** Recordings are local-only — must keep
  AerioTV running for the recording duration. No comskip
  (Dispatcharr-only).
- **No server-side stream failover.** When a stream dies your
  client-side `.m3u8` → `.ts` fallback is the only failover layer
  — the provider has to fix anything beyond that.
- **EPG depth varies by provider** — some give you a few days,
  some give you a few hours.
- **No custom User-Agent or external XMLTV URL override.**

</details>

<details>
<summary><strong>M3U Playlist</strong> — Direct URL + optional XMLTV EPG. <em>Universal compatibility, simplest setup.</em></summary>

A plain M3U playlist is just a list of stream URLs in a text file.
Works with literally any IPTV provider that gives you a playlist
URL — including providers that don't support the Xtream Codes API.

**Benefits**

- **Universal compatibility.** If a provider hands you any URL
  ending in `.m3u` / `.m3u8`, AerioTV can play it.
- **Fastest setup.** Paste the URL → done. No credentials, no
  server, no scrape time.
- **No self-hosting.**
- **Local DVR with pre-roll / post-roll.** Recordings on this
  device, with the same buffer pickers Xtream and Dispatcharr
  recordings get. Recordings continue while the app stays
  running.
- **Optional separate XMLTV URL** for EPG. Bring your own EPG
  source if your provider doesn't include one.
- **Compressed `.xml.gz` EPG** — *coming in a future release*.

**Drawbacks**

- **No VOD library.** M3U is live TV only — no movies or series.
  If your provider has VOD, you'll need their Xtream Codes
  endpoint (or a Dispatcharr instance pointed at them) to access
  it.
- **No server-side DVR.** Recordings are local-only — AerioTV
  has to be running for the recording to capture. No comskip
  (Dispatcharr-only).
- **EPG depends on a separate XMLTV source.** You set the URL
  yourself, and EPG quality is whatever that source provides.
- **No stream failover at all.** When a stream URL stops working,
  the provider has to fix the playlist — there's no `.m3u8`/`.ts`
  client fallback like XC has, and no server-side swap like
  Dispatcharr has.
- **No custom User-Agent override.**
- **Large M3U files can be slow to parse** on first launch — a
  20,000-channel playlist takes a noticeable beat to ingest.

</details>

## Requirements for Development

- Xcode 15 or later
- iOS 18.0+, iPadOS 18.0+, tvOS 18.0+, macOS 15.0+ (using the iPad app)
- Swift Package Manager for dependency management

## Getting Started

Clone the repository and install dependencies:

```
git clone https://github.com/jonzey231/AerioTV.git
cd AerioTV
pod install
```

Open the workspace (not the project file) in Xcode:

```
open Aerio.xcworkspace
```

Select either the `Aerio_iOS` or `Aerio_tvOS` scheme and build to a simulator or device.

## Dependencies

- Swift Package Manager for dependency management
- The `Pods/` directory (if present from legacy builds) is excluded from version control

## Project Structure

```
App/                    Application entry point, player, splash screen, Now Playing integration
Design/                 Colors, typography, shared UI components
Features/
    Home/               Main tab view, VOD store, Now Playing manager
    LiveTV/             Channel list, EPG guide, channel store
    Movies/             Movie browsing and detail views
    Series/             TV series browsing and detail views
    Settings/           App settings, network settings, appearance
    Onboarding/         Welcome flow, server setup, iCloud sync
Models/                 SwiftData models for servers, channels, EPG programs
Networking/             Dispatcharr API, Xtream Codes API, M3U/XMLTV parsing
Shared/                 Keychain helper, sync manager, reminder manager
SupportingFiles/        Info.plist, entitlements, asset catalogs
TopShelfExtension/      Apple TV Top Shelf content provider
```

## Configuration

- On first launch the app presents an onboarding flow where you add your server
- Server configurations can be imported from another device through iCloud sync
- EPG data is downloaded once and cached locally
- Default EPG window is 36 hours ahead (configurable in Settings > Network)
- Fresh install shows a loading screen until the initial EPG download completes

## Sideloading

- Pre-built .ipa files for iOS and tvOS are available on the [Releases](https://github.com/jonzey231/AerioTV/releases) page
- Download the .ipa for your platform
- Install using your preferred sideloading method (AltStore, Sideloadly, etc.)

## Building for Release

- Import this repository into Xcode
- Select the appropriate scheme (`Aerio_iOS` or `Aerio_tvOS`)
- Set the destination to your preferred device
- Build and/or run, or generate a .ipa via Product > Archive

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Support

To report bugs or request features, open an issue at [github.com/jonzey231/AerioTV/issues](https://github.com/jonzey231/AerioTV/issues).
