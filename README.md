# AerioTV

AerioTV is a native IPTV streaming application for iOS, iPadOS, tvOS, and macOS (using the iPad app). It connects to Dispatcharr via API Key, Xtream Codes, and M3U playlist servers to deliver live TV, movies, and series with a full electronic program guide (EPG) when supplied by the user.

[Download via Apple App Store](https://apps.apple.com/us/app/aeriotv/id6760727974) 
- This will usually lag behind the TestFlight version.

[Download via Apple TestFlight](https://testflight.apple.com/join/JfszBGQP) 
- This version may have bugs but will always be the latest.

Sideload using your preferred method using the .ipa from [Releases](https://github.com/jonzey231/AerioTV/releases).
- This version will occasionally be ahead of the Apple Testflight version.

## Features

**Multiview** *(new in v1.6.0; unified playback engine in v1.6.1)*

- Watch up to **9 live channels at once** in a dynamically-sized grid
- Enter from any playing channel: tap the grid button in the player
  top bar (iPad) or **Options → Enter Multiview** (tvOS)
- Add channels one at a time from a Favorites / Recent / All
  Channels picker — the grid re-lays out automatically
- Layouts adapt to tile count: 1, 2, 3 asymmetric, 2×2, 5 asymmetric,
  3×2, 7 centered, 3×3 with center gap, full 3×3
- **Only the most recently added stream plays audio**; every other
  tile stays muted with a small speaker badge marking the audio tile
- Tap any tile (iPad) or click Select (Siri Remote) to move audio
  focus to that tile
- **Rearrange tiles** via a dedicated Move Mode. On iPad, long-press
  a tile → "Move Tile" → tap any other tile to swap positions, or
  tap the source tile again to cancel. On tvOS, long-press Select
  → "Move Tile" → the Siri Remote arrows swap with the physical
  neighbor and Select commits.
- **Long-press menu** on every tile with Make Audio / Full-Screen
  in Grid / Audio Track / Subtitle Track / Move Tile / Remove
  actions, shared between iPad and tvOS
- **Picture-in-Picture from multiview (iPad)** — only the audio tile
  continues in PiP; all other tiles pause to conserve resources
- **Performance warning at the 5th tile** with a 2-hour throttle;
  hard cap at 9 tiles
- **Thermal watchdog** — stops new tile additions when the device
  reaches `.critical` thermal state

**Live TV**

- Stream live channels with MPV-powered, GPU-accelerated playback
- Browse channels in a scrollable list or full EPG guide view
- Program titles, descriptions, and time slots in the guide
- Minimize playback to a floating mini player while browsing
- Sort channels by number, name, or favorites
- Tap a channel to play, long-press to add to favorites

**Electronic Program Guide**

- Grid and list views on tvOS and iPad, list view on iPhone
- Program data cached locally and configurable from 6 hours to full available window
- Channels without guide data still selectable from the grid
- Long-press future programs to set reminders or schedule recordings

**DVR Recording** *(new in v1.5.0)*

- Schedule live or upcoming programs to record from the Live TV guide
- **Dispatcharr server-side recording** — continues even when AerioTV is closed; ideal for unattended recordings and recordings that need to survive app background / device sleep
- **Local recording on this device** — records straight to `Documents/Recordings` (or a user-chosen folder on iOS) for XC, M3U, and Dispatcharr users
- Per-recording **pre-roll** (start early) and **post-roll** (end late) buffers: None / 5 / 10 / 15 / 30 / 60 min or a custom value, to catch overruns in live sports and news
- Optional **Remove Commercials (Comskip)** — toggle at schedule time, or trigger post-recording from the DVR tab's context menu. Processes server-side on Dispatcharr
- **DVR tab** appears automatically when there's at least one recording (local or on the server), with Scheduled / Recording / Completed segments and live status updates
- **Auto-discovery** — recordings scheduled from the Dispatcharr web UI (or another device) appear in AerioTV's DVR tab within ~2 minutes
- **Download server recordings** — long-press a completed Dispatcharr recording → Save to Device
- **Local storage quota** with live usage bar (1–200 GB, default 10 GB) and low-storage warnings
- **iOS Files app access** — local recordings browsable and exportable under "On My iPhone → AerioTV"
- Keep-device-awake toggle so a local recording isn't interrupted by display sleep

**Movies and Series**

- Browse and filter on-demand content by category
- Categories pulled from the server's VOD library
- Toggle categories on or off through the filter menu
- Resume playback from where you left off with Continue Watching

**Continue Watching**

- VOD watch progress tracked automatically
- Resume movies and episodes from the Continue Watching section
- Long-press to remove items
- Progress syncs across all your devices via iCloud

**Player Controls**

- All secondary controls accessible from a single overflow menu (iOS) or Options panel (tvOS)
- Audio track selection, subtitle selection, playback speed
- Sleep timer, stream info overlay, audio-only mode
- Picture-in-Picture (iOS), AirPlay

**Sleep Timer**

- Set a timer for 30, 60, 90, or 120 minutes
- Playback pauses automatically when the timer expires
- Countdown displayed in the overflow menu / Options panel

**Stream Info Overlay**

- Real-time overlay showing video codec, resolution, FPS, pixel format, hardware decode status
- Audio codec, sample rate, channel count
- Cache duration, bitrate, A/V sync, dropped frames
- Draggable anywhere on iOS, fixed top-center on tvOS

**EPG Reminders**

- Long-press an upcoming program in the channel list (iOS) or guide (tvOS)
- Notification fires 5 minutes before the program starts
- In-app banner appears when the app is in the foreground
- Reminders sync across devices via iCloud

**Audio and Subtitle Selection**

- Switch between audio tracks and subtitle tracks during playback
- Available tracks detected automatically from the stream
- Current selection shown with checkmark in the menu

**Playback Speed**

- Cycle through playback speeds: 0.5x, 0.75x, 1x, 1.25x, 1.5x, 2x
- Available for VOD content (not live streams)

**Picture-in-Picture (iOS)**

- Swipe home during playback and the stream continues in a floating PiP window
- Supports AirPlay video output
- Full playback controls in PiP mode

**iCloud Sync**

- Server configurations, preferences, VOD watch progress, and EPG reminders sync across devices
- Uses iCloud Key-Value Storage
- Set up once on one device and all your Apple devices pick up the same data
- Data pulled automatically on every app launch

**Apple TV Optimized**

- Full Siri Remote support with d-pad navigation
- Options panel for audio, subtitles, speed, sleep timer, and stream info
- Channels and logos sized for living room viewing
- LAN detection probes local server URL automatically (no SSID configuration needed)

**tvOS Floating Player**

- Press Menu to minimize live TV to a floating corner player
- Press Menu again to stop playback
- Browse channels, movies, or settings while the stream continues

**Top Shelf (tvOS)**

- Shows your 6 most-watched channels with currently airing program
- Continue Watching row with posters for movies and episodes you haven't finished
- Click a channel card to instantly start playing it in AerioTV
- Click a movie card to jump straight to its detail view
- Click an episode card to jump to its parent series detail view
- Populates as soon as AerioTV is on the top row of the Home screen — no extra setup

## Supported Server Types

AerioTV connects to three different playlist types. Each unlocks a
different set of features. If you're choosing between them, the
short version is:

- **Dispatcharr API** *(Recommended)* — most powerful (server-side
  DVR, rich VOD, comskip, live stream stats), but you have to run
  it yourself.
- **Xtream Codes** — middle ground. Live TV + VOD with no
  self-hosting, but DVR is local-only and VOD metadata is sparser.
- **M3U Playlist** — simplest. Works with any IPTV provider that
  hands you a URL, but it's live TV only — no VOD library, no
  server-side DVR.

Click each type for the full breakdown:

<details>
<summary><strong>Dispatcharr API</strong> <em>(Recommended)</em> — Native API with API key authentication. <em>Most full-featured option.</em></summary>

[Dispatcharr](https://github.com/Dispatcharr/Dispatcharr) is a
self-hosted Python/Postgres server that proxies upstream IPTV feeds
and adds DVR, EPG, VOD, and a TMDB metadata scraper on top.
AerioTV's deepest integration.

**Benefits**

- ✅ **Server-side DVR.** Schedule recordings that continue running
  even when AerioTV is closed or the device is asleep. Local
  recording (to the device) is also available.
- ✅ **Comskip (commercial-skip)** — toggle when scheduling a server
  recording or run it post-recording from the DVR tab.
- ✅ **Server-side recording playback** — stream completed
  recordings directly from the server with HTTP Range support.
- ✅ **Pre-roll / post-roll buffers** — start a recording early and
  end late so live sports running long don't get cut off.
- ✅ **TMDB-rich VOD metadata** — backdrop, plot, cast, director,
  year, rating, runtime for movies and series, plus per-episode
  air date, TMDB rating, IMDB ID, and per-episode artwork.
- ✅ **Channel UUID with server-side stream failover.** When a
  primary stream dies mid-playback, Dispatcharr can swap to a backup
  provider transparently — the player doesn't even hiccup.
- ✅ **Bulk EPG fetch** — one network call returns -1h to +24h for
  every channel. Faster than per-channel XMLTV walks.
- ✅ **Live server-side Stream Info** *(v1.6.18+)* — resolution,
  FPS, video / audio codec, output bitrate, and current viewer
  count, pulled from Dispatcharr every 5s while the overlay is
  visible. More authoritative than mpv-derived numbers because
  Dispatcharr analyzes the source feed directly.
- ✅ **Per-server custom User-Agent** — set in Settings → Edit
  Playlist; sent on every request and on mpv playback so the value
  shows up in Dispatcharr's admin Stats panel.
- ✅ **External XMLTV URL override** *(advanced)* — point EPG at a
  third-party XMLTV source while keeping channels from Dispatcharr.
- ✅ **Per-playlist VOD toggle** — disable VOD on a sandbox /
  secondary Dispatcharr server while keeping its Live TV channels.
- ✅ **Auto-discovery of recordings** scheduled from the Dispatcharr
  web UI or another device — they appear in AerioTV's DVR tab
  within ~2 minutes.

**Drawbacks**

- ⚠️ **Requires self-hosting.** You need to run Dispatcharr (Docker,
  NAS, home server) — there's no SaaS offering. If you just want to
  paste a provider URL and watch, M3U or Xtream Codes is faster.
- ⚠️ **Initial scrape time.** Adding a Dispatcharr server with a
  large upstream provider can take a few minutes to populate the
  channel list, EPG, and VOD library on the first launch.
- ⚠️ **You're on the hook for keeping it running.** Server-side DVR
  is great until the server is down at recording time.

</details>

<details>
<summary><strong>Xtream Codes</strong> — IPTV Source URL + username & password authentication. <em>No self-hosting required.</em></summary>

The Xtream Codes API is what most IPTV providers natively expose.
You log in with the username / password your provider gave you and
AerioTV pulls live TV, movies, and series.

**Benefits**

- ✅ **No self-hosting.** Most IPTV providers expose an Xtream Codes
  endpoint by default — paste the URL, type your credentials, done.
- ✅ **Live TV + VOD.** Movies and series come from the same login
  as live channels, no separate EPG / VOD URLs to manage.
- ✅ **EPG via TVG ID matching** — most provider EPGs are keyed to
  match Xtream's `tvg_id` field automatically.
- ✅ **Familiar auth model** — a single username and password.

**Drawbacks**

- ⚠️ **VOD metadata is sparse** — no TMDB enrichment, no
  per-episode air dates, no per-episode artwork. You get the
  poster, title, and (sometimes) a one-line plot from the
  provider's data.
- ⚠️ **No server-side DVR.** Recordings are local-only — must keep
  AerioTV running for the duration. No comskip.
- ⚠️ **No channel UUID failover.** When a stream dies it just dies;
  the provider has to fix it on their end.
- ⚠️ **Stream Info shows mpv-derived stats only** — what your
  device's decoder reports, not what the source feed actually is.
- ⚠️ **EPG depth varies by provider** — some give you a few days,
  some give you a few hours.

</details>

<details>
<summary><strong>M3U Playlist</strong> — Direct URL + optional XMLTV EPG. <em>Universal compatibility, simplest setup.</em></summary>

A plain M3U playlist is just a list of stream URLs in a text file.
Works with literally any IPTV provider that gives you a playlist
URL — including providers that don't support Xtream Codes API.

**Benefits**

- ✅ **Universal compatibility.** If a provider hands you any URL
  ending in `.m3u` / `.m3u8`, AerioTV can play it.
- ✅ **Fastest setup.** Paste the URL → done. No credentials, no
  server, no scrape time.
- ✅ **No self-hosting.**
- ✅ **Optional separate XMLTV URL** for EPG. Bring your own EPG
  source if your provider doesn't include one.
- ✅ **Compressed `.xml.gz` EPG** — *coming in a future release*.

**Drawbacks**

- ⚠️ **No VOD library.** M3U is live TV only — no movies or series.
  If your provider has VOD, you'll need their Xtream Codes endpoint
  (or a Dispatcharr instance pointed at them) to access it.
- ⚠️ **No server-side DVR.** Recordings are local-only — AerioTV
  has to be running for the recording to capture. No comskip.
- ⚠️ **EPG depends on a separate XMLTV source.** You set the URL
  yourself, and EPG quality is whatever that source provides.
- ⚠️ **No stream failover.** When a stream URL stops working, the
  provider has to fix the playlist; AerioTV can't transparently
  swap to a backup.
- ⚠️ **No live stream stats from any server.** Stream Info shows
  mpv-derived numbers only.
- ⚠️ **Large M3U files can be slow to parse** on first launch — a
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
