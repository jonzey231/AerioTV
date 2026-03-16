# Dispatcharr — Build & Deploy Guide

## Prerequisites

- **Mac** with macOS 15+ (Sequoia or later)
- **Xcode 16+** — download from Mac App Store or [developer.apple.com/xcode](https://developer.apple.com/xcode)
- **CocoaPods** — `sudo gem install cocoapods`
- **Apple ID** (free) — required for signing, even for personal use
- **iPhone/iPad** on iOS 18+ or Apple TV on tvOS 18+
- **XcodeGen** (optional but recommended) — simplifies project regeneration

---

## Project Structure

```
Dispatcharr/
├── App/
│   ├── DispatcharrApp.swift        # App entry point + ThemeManager injection
│   ├── PlayerView.swift            # VLC player (MobileVLCKit) + AirPlay + audio-only
│   └── SplashView.swift
├── Design/
│   ├── Colors.swift                # Color tokens (appBackground, cardBackground, etc.)
│   ├── Typography.swift            # Font styles + sectionHeaderStyle modifier
│   ├── ThemeManager.swift          # AppTheme, LiquidGlassStyle, ThemeManager singleton
│   ├── LiquidGlass.swift           # liquidGlass() modifier + liquidGlassTabBar()
│   └── Components/                 # PrimaryButton, EmptyStateView, LoadingView, VODPosterCard
├── Models/
│   ├── Models.swift                # ServerConnection (SwiftData), EPGProgram, etc.
│   ├── PlaylistModels.swift        # M3U channel models
│   └── VODModels.swift             # VODMovie, VODSeries, VODEpisode, VODDisplayItem
├── Networking/
│   ├── XtreamAndDispatcharrAPI.swift  # Full XC + Dispatcharr API implementations
│   ├── XtreamSeriesAPI.swift          # XC series detail extension
│   ├── VODService.swift               # Unified VOD routing (movies + series)
│   ├── MediaServerAPIs.swift
│   └── PlaylistParsers.swift
├── Features/
│   ├── Home/
│   │   └── HomeView.swift          # AppTab enum + MainTabView (4 tabs)
│   ├── LiveTV/
│   │   └── ChannelListView.swift   # Channel grid, group filters, VLC playback
│   ├── VOD/
│   │   ├── MoviesView.swift        # Movie poster grid
│   │   ├── TVShowsView.swift       # TV series poster grid
│   │   ├── VODDetailView.swift     # Movie/series detail + episode picker
│   │   └── SearchView.swift        # Global search (VOD + EPG, 300ms debounce)
│   ├── Settings/
│   │   ├── SettingsView.swift
│   │   └── AppearanceSettingsView.swift  # Theme, tab, Liquid Glass settings
│   └── Onboarding/
├── Shared/ViewModels/
└── SupportingFiles/Info.plist
```

---

## Features

| Feature | Status |
|---|---|
| Xtream Codes login (live, VOD, series, EPG) | ✅ |
| Dispatcharr API key login | ✅ |
| Multiple accounts (XC + Dispatcharr) | ✅ |
| Live TV channel list + group filters | ✅ |
| VLC playback (MobileVLCKit, LGPL 2.1) | ✅ |
| HLS/TS fallback chain | ✅ |
| Audio-only mode (music streams) | ✅ |
| AirPlay route picker | ✅ |
| VOD movies grid + detail | ✅ |
| VOD TV shows + episode picker | ✅ |
| Global search (VOD + EPG) | ✅ |
| 4-tab navigation (Live TV / Movies / TV / Settings) | ✅ |
| Adjustable default tab | ✅ |
| 6 color themes + custom hex accent | ✅ |
| Liquid Glass (iOS 26 native + fallbacks) | ✅ |
| Google Cast (OpenCastSwift) | 🔧 stub — see below |
| tvOS VLC playback (TVVLCKit) | 🔧 stub |
| Source merge mode (multi-server) | 🔧 partial |

---

## Method 1: XcodeGen + CocoaPods (Recommended)

### 1. Install tools

```bash
brew install xcodegen
sudo gem install cocoapods
```

### 2. Generate the Xcode project

```bash
cd ~/path/to/Dispatcharr
xcodegen generate
```

### 3. Install CocoaPods dependencies

```bash
pod install
```

This installs **MobileVLCKit** (the VLC video player). After this step, always open `Dispatcharr.xcworkspace` — **not** `Dispatcharr.xcodeproj`.

### 4. Open the workspace

```bash
open Dispatcharr.xcworkspace
```

---

## Method 2: Manual Xcode Project Setup

If you prefer not to use XcodeGen:

### Step 1 — Create a new Xcode project

1. Open Xcode → **File → New → Project**
2. Choose **Multiplatform → App**
3. Set:
   - **Product Name:** `Dispatcharr`
   - **Organization Identifier:** `app.molinete`
   - **Bundle ID:** `app.molinete.Dispatcharr`
   - **Testing System:** Swift Testing
   - **Storage:** SwiftData
4. Save it **into** (not alongside) your `Dispatcharr` folder

### Step 2 — Add all source files

1. In Xcode's file navigator, right-click the `Dispatcharr` group → **Add Files to "Dispatcharr"**
2. Select these folders — **"Copy items if needed" OFF**, **"Create groups" ON**:
   - `App/`
   - `Design/`
   - `Models/`
   - `Networking/`
   - `Features/`
   - `Shared/`
3. Delete any auto-generated `ContentView.swift` or `Item.swift`

### Step 3 — Add MobileVLCKit via CocoaPods

```bash
cd ~/path/to/Dispatcharr
pod install
```

Then close `Dispatcharr.xcodeproj` and open `Dispatcharr.xcworkspace`.

### Step 4 — Info.plist settings

If Xcode didn't use your `SupportingFiles/Info.plist`, add manually:
1. Select target → **Info** tab
2. `NSAppTransportSecurity` → `NSAllowsArbitraryLoads` = `YES`, `NSAllowsLocalNetworking` = `YES`
3. `UIBackgroundModes` → `audio`

---

## Enabling Google Cast (OpenCastSwift)

Google Cast is stubbed. To activate:

1. In `Podfile`, uncomment:
   ```ruby
   # pod 'OpenCastSwift', :git => 'https://github.com/mhmiles/OpenCastSwift.git'
   ```
2. Run `pod install`
3. In `PlayerView.swift`, search for `TODO: OpenCastSwift` and implement device discovery + session management

---

## Signing & Team Setup

### Personal testing (free Apple ID)

1. Select the **Dispatcharr** target → **Signing & Capabilities**
2. Under **Team**, select your **Personal Team**
3. Xcode auto-manages provisioning profiles
4. If `app.molinete.Dispatcharr` is taken, change to `com.YOUR-NAME.Dispatcharr`

> **Free account:** Apps expire after **7 days** and must be re-deployed. Paid Apple Developer account ($99/year) needed for longer validity.

---

## Deploy to iPhone

1. Connect iPhone via USB
2. Select your iPhone in Xcode's device picker
3. Press **⌘R**
4. On iPhone: **Settings → General → VPN & Device Management** → trust the developer cert

### Wireless debugging (optional)

After first wired deploy: **Window → Devices and Simulators** → check **"Connect via Network"**

---

## Deploy to Apple TV

1. Connect Apple TV via USB-C or ensure same Wi-Fi
2. On Apple TV: **Settings → Remotes and Devices → Remote App and Devices** → pair
3. Select Apple TV in Xcode → press **⌘R**

> **Note:** The tvOS scheme uses a stub player (VLC not available). To enable VLC on tvOS, add `TVVLCKit` to the Podfile and add `#if os(tvOS)` conditional code in `PlayerView.swift`.

---

## tvOS Splash Screen

`UIViewRepresentable` is iOS-only. Wrap with conditional compilation in `SplashView.swift`:

```swift
#if os(iOS)
// existing VideoPlayerView UIViewRepresentable code
#elseif os(tvOS)
import AVKit
struct VideoPlayerView: View {
    let player: AVPlayer
    var body: some View {
        VideoPlayer(player: player).disabled(true)
    }
}
#endif
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Untrusted Developer" on iPhone | Settings → General → VPN & Device Management → trust cert |
| Build fails: module not found | Run `pod install`, open `.xcworkspace` not `.xcodeproj` |
| `NSAllowsArbitraryLoads` warning | Expected — required for HTTP IPTV stream connections |
| Video splash doesn't play | Confirm `DispatcharrSplash.mp4` is in **Copy Bundle Resources** |
| SwiftData migration error | Delete app from device, reinstall |
| 7-day expiry (free account) | Re-run **⌘R** from Xcode while connected |
| Liquid Glass not showing | Requires iOS 26+; earlier iOS uses tinted material fallback |
| VLC not found at build time | Check `Pods/` exists; re-run `pod install` if missing |

---

## Updating the App

After code changes, press **⌘R** in Xcode. SwiftData persists between installs unless the schema changes significantly (in which case, delete and reinstall).

---

*Happy streaming! 🎬*
