# AerioTV

AerioTV is a native IPTV streaming application for iOS, iPadOS, tvOS, and macOS (via iPad app). It connects to Dispatcharr, Xtream Codes, and M3U playlist servers to deliver live TV, movies, and series with a full electronic program guide.

[Download on the App Store](https://apps.apple.com/us/app/aeriotv/id6760727974)

## Features

**Live TV**
Stream live channels with VLC-powered playback. Browse channels in a scrollable list or a full EPG guide view with program titles, descriptions, and time slots. Minimize playback to a picture-in-picture style mini player while browsing other content.

**Electronic Program Guide**
A grid-style guide similar to Emby and other media center applications. Program data is cached locally and configurable from 6 hours to the full available window. The guide shares its cache with the channel list so expanding a channel card shows upcoming programs instantly.

**Movies and Series**
Browse and filter on-demand content by category. Categories are pulled from the server's VOD library and can be toggled on or off through the filter menu.

**iCloud Sync**
Server configurations and preferences sync across devices using iCloud Key-Value Storage. Set up once on your iPhone and your Apple TV will pick up the same servers automatically.

**Apple TV Optimized**
Full support for the Siri Remote with directional navigation, focus management, and context menus. The guide view extends edge to edge and text is sized for the living room viewing distance.

## Supported Server Types

1. **[Dispatcharr](https://github.com/Dispatcharr/Dispatcharr)** (native API with API key authentication)
2. **Xtream Codes** (username/password authentication)
3. **M3U Playlist** (direct URL with optional XMLTV EPG source)

## Requirements

Xcode 15 or later, iOS/iPadOS 18.0+, tvOS 18.0+, macOS 15.0+ (Designed for iPad). The project uses CocoaPods for dependency management.

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

The project uses CocoaPods with the following libraries:

| Library | Platform | Purpose |
|---------|----------|---------|
| MobileVLCKit | iOS | VLC media playback engine |
| TVVLCKit | tvOS | VLC media playback engine |

Run `pod install` after cloning to download these dependencies. The `Pods/` directory is excluded from version control.

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

Select the appropriate scheme (`Aerio_iOS` or `Aerio_tvOS`), set the destination to "Any iOS Device" or "Any tvOS Device", then go to Product and Archive. The archive can be uploaded to App Store Connect or exported as an IPA for sideloading.

## License

This project is provided as-is for personal use. See the repository for any additional licensing information.

## Support

To report bugs or request features, open an issue at [github.com/jonzey231/AerioTV/issues](https://github.com/jonzey231/AerioTV/issues).
