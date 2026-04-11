# AerioTV

AerioTV is a native IPTV streaming application for iOS, iPadOS, tvOS, and macOS (using the iPad app). It connects to Dispatcharr via API Key, Xtream Codes, and M3U playlist servers to deliver live TV, movies, and series with a full electronic program guide (EPG) when supplied by the user.

[Download via Apple App Store](https://apps.apple.com/us/app/aeriotv/id6760727974) 
- This will always be behind the TestFlight version.

[Download via Apple TestFlight](https://testflight.apple.com/join/JfszBGQP) 
- This version may have bugs but will alwats be the latest. 

## Features

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
- Long-press future programs to set reminders or (coming soon) schedule recordings

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

1. **[Dispatcharr](https://github.com/Dispatcharr/Dispatcharr)** — Native API with API key authentication. See the [Dispatcharr GitHub repository](https://github.com/Dispatcharr/Dispatcharr) for more information.
2. **Xtream Codes** — Provider URL + username & password authentication.
3. **M3U Playlist** — Direct URL + optional XMLTV EPG.

## Requirements

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
