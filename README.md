# AerioTV

AerioTV is a native IPTV streaming application for iOS, iPadOS, tvOS, and macOS (using the iPad app). It connects to Dispatcharr, Xtream Codes, and M3U playlist servers to deliver live TV, movies, and series with a full electronic program guide (EPG).

[Download on the App Store](https://apps.apple.com/us/app/aeriotv/id6760727974) (tvOS only. Pending App Store approval for iOS and iPadOS.)

## Features

**Live TV**

Stream live channels with MPV-powered playback. Browse channels in a scrollable list or a full EPG guide view with program titles, descriptions, and time slots. Minimize playback to a floating mini player while browsing other content. Sort channels by number, name, or favorites.

**Electronic Program Guide**

Grid and list views on tvOS and iPad, list view on iPhone. Program data is cached locally and configurable from 6 hours to the full available window. Channels without guide data are still selectable from the grid.

**Movies and Series**

Browse and filter on-demand content by category. Categories are pulled from the server's VOD library and can be toggled on or off through the filter menu. Resume playback from where you left off with Continue Watching.

**Continue Watching**

VOD watch progress is tracked automatically. Resume movies and episodes from the Continue Watching section on the Movies or Series tabs. Long-press to remove items. Progress syncs across all your devices via iCloud.

**Audio and Subtitle Selection**

Switch between audio tracks and subtitle tracks during playback. Available tracks are detected automatically from the stream.

**Playback Speed**

Cycle through playback speeds (0.5x to 2x) for VOD content.

**Picture-in-Picture (iOS)**

Swipe home during playback and the stream continues in a floating PiP window. Supports AirPlay video output.

**iCloud Sync**

Server configurations, preferences, and VOD watch progress sync across devices using iCloud Key-Value Storage. Set up once on one device and all your Apple devices pick up the same servers and resume positions.

**Apple TV Optimized**

Full Siri Remote support with hold-to-scrub seeking on the timeline, accelerating seek speed, play/pause, speed cycling, and subtitle toggling. D-pad control hints appear when the overlay is visible. Channels and logos are sized for living room viewing. LAN detection probes the local server URL automatically (no SSID configuration needed on tvOS).

**tvOS Floating Player**

Press Menu to minimize live TV to a floating corner player. Press Menu again to stop playback. Browse channels, movies, or settings while the stream continues.

**Top Shelf (tvOS)**

The Top Shelf extension shows your 6 most-watched channels with the currently airing program.

## Supported Server Types

1. **[Dispatcharr](https://github.com/Dispatcharr/Dispatcharr)** (native API with API key authentication). See the [Dispatcharr GitHub repository](https://github.com/Dispatcharr/Dispatcharr) for more information about the API integration.
2. **Xtream Codes** (Provider URL + username & password authentication)
3. **M3U Playlist** (direct URL + optional XMLTV EPG)

## Requirements

Xcode 15 or later. iOS 18.0+, iPadOS 18.0+, tvOS 18.0+, macOS 15.0+ (using the iPad app). The project uses CocoaPods for dependency management.

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

The project uses Swift Package Manager for dependency management. The `Pods/` directory (if present from legacy builds) is excluded from version control.

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

On first launch the app presents an onboarding flow where you add your server. You can also import server configurations from another device through iCloud sync.

EPG data is downloaded once and cached locally. The default window is 36 hours ahead. This can be changed in Settings under Network. On a fresh install the app will show a loading screen until the initial EPG download completes.

## Sideloading

Pre-built .ipa files for iOS and tvOS are available on the [Releases](https://github.com/jonzey231/AerioTV/releases) page. Download the .ipa for your platform and install using your preferred sideloading method (AltStore, Sideloadly, etc.).

## Building for Release

Import this repository into Xcode. Select the appropriate scheme (`Aerio_iOS` or `Aerio_tvOS`), set the destination to your preferred device, then build and/or run it. You can generate your own .ipa file by creating an archive in Xcode at Product > Archive.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Support

To report bugs or request features, open an issue at [github.com/jonzey231/AerioTV/issues](https://github.com/jonzey231/AerioTV/issues).
