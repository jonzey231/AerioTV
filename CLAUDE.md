# CLAUDE.md

## 1. What this is
- AerioTV: native IPTV client for iOS, iPadOS, tvOS (and macOS via the iPad app). Live TV with EPG,
  movies and series (VOD), DVR, Multiview (up to 9), Cast, AirPlay, CarPlay audio, iCloud sync, Top
  Shelf extension.
- Backends: Dispatcharr (API key), Xtream Codes, M3U playlists plus XMLTV EPG.
- Naming: user-facing copy always says "AerioTV". Internals (targets, schemes, types, files, bundle
  ids) stay "Aerio".
- Sibling app: AerioTV Android (Kotlin/Compose). The two must stay at full parity (see section 6).
- License GPL-3.0-or-later (LICENSE, LICENSE-EXCEPTIONS.md). Changelog in CHANGELOG.md.

## 2. Build and run
- Always Xcode 27 (/Applications/Xcode.app). Open `Aerio.xcworkspace`, never the .xcodeproj
  (CocoaPods: Google Cast SDK via Podfile/Pods; SPM: MPVKit, SwiftDraw). Pods is checked in; run
  `pod install` only after editing Podfile. project.yml exists (XcodeGen spec);
  Config/Aerio.xcconfig holds build settings.
- Schemes (`xcodebuild -list -workspace Aerio.xcworkspace`): `Aerio_iOS`, `Aerio_tvOS`, `Aerio_iOS
  Dev`, `AerioTopShelf` (plus Pods/package schemes).
- `Aerio_iOS Dev` uses the Dev configuration, bundle id `app.molinete.aerio.dev`
  (SupportingFiles/AerioDev.entitlements), and installs beside the App Store build. Use it for
  day-to-day device work.
- Device build:
  ```
  xcodebuild -workspace Aerio.xcworkspace -scheme "Aerio_iOS Dev" -configuration Dev \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates build
  ```
  Product: `~/Library/Developer/Xcode/DerivedData/Aerio-*/Build/Products/Dev-iphoneos/Aerio.app`
- Install and launch:
  ```
  xcrun devicectl device install app --device <UDID> <path/to/Aerio.app>
  xcrun devicectl device process launch --device <UDID> app.molinete.aerio.dev
  ```
- Compile checks without a device: `-destination 'generic/platform=iOS Simulator'` (Aerio_iOS) and
  `'generic/platform=tvOS Simulator'` (Aerio_tvOS). Cast code is `#if os(iOS)` (no tvOS Cast
  sender), so check both platforms after touching shared files.
- Deleting DerivedData also wipes SPM checkouts; expect a package re-resolve.

## 3. Tests
- `./Scripts/cast-hls-proxy-tests/run.sh`: compiles the cast proxy sources (Networking/CastHLSProxy
  plus pure-logic App files such as TSLANAudioRewriter.swift) with swiftc together with main.swift
  and runs pure-logic tests. Must end with `ALL TESTS PASSED`. Run it after any change to the proxy,
  remuxers or audio rewriter; keep those files free of app singletons so the script can compile
  them.
- No unit test target. There is a UI test target `AerioTVUITests`
  (AerioTVUITests/AerioTVUITests.swift), not part of routine verification.
- Other scripts: Scripts/capture-appletv-logs.sh, Scripts/install-tunneld.sh.

## 4. Logs
- DebugLogger (App/DebugLogger.swift) writes `Library/Caches/aerio_debug_logs.txt`, rotating at 4 MB
  to `aerio_debug_logs.1.txt`.
- Pull from device:
  ```
  xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
    --domain-identifier app.molinete.aerio.dev --source Library/Caches/aerio_debug_logs.txt \
    --destination <file>
  ```
- The copy stalls while the app is serving a Cast or AirPlay receiver. Stop the session first, then
  pull.
- Key prefixes: `[Cast]` (sender, session, control), `[CAST-HLS]` (proxy ingest/segments/playlists),
  `[TS-REMUX]` (TSHLSRemuxer), `[AVP-AIRPLAY]` (AirPlay handoff), `[TABBAR]`, `[CHROME]` (player
  chrome). Also common: `[AVP-*]` AVPlayer paths, `[MPV-*]`, `[FAILOVER]`, `[SWITCH]`, `[MKV]`.
- Read the logs before editing on any bug report; a second report of the same bug means instrument,
  reproduce, measure first.

## 5. Architecture map
Top-level folders: App (app entry, player hosts, Cast/AirPlay, remuxers, logging), Features (DVR,
Home, LiveTV, Multiview, Onboarding, Player, Search, Settings, VOD), Networking, Models (SwiftData
models), Shared (session, sync, stores, remote control, view models), TopShelfExtension,
SupportingFiles, Design, docs (SettingsUIRedesign.md, research, recovery, PrivacyPolicy).

Cast (iPhone/iPad only)
- App/AerioCastController.swift: Google Cast SDK sender. Receiver app id `46B79062` is a custom web
  receiver (receiver.html on the Android repo's gh-pages branch). The load URL is the phone-local
  proxy's demuxed master `http://<phone-lan-ip>:<port>/demuxed.m3u8`. Cast Connect launches the
  native Android TV app when the receiver has it; otherwise the web receiver plays. Also holds the
  AerioTV Remote companion transport (tvOS host advertises `_aeriotv._tcp`; iPhone client, Now
  Playing via Shared/CompanionNowPlaying.swift).
- Networking/CastHLSProxy: CastHLSProxySession (URLSession ingest of the channel's raw MPEG-TS, one
  channel at a time, listener survives flips), CastFMP4Remuxer (TS to fMP4/CMAF, port of the Android
  remuxer), CastHLSSegmentStore (segment ring, generations/discontinuities, playlists; pure logic),
  CastHLSProxyServer (NWListener HTTP/1.1: demuxed master, video/audio playlists, init and media
  segments), CastVideoTranscoder (VideoToolbox decode/encode on the phone when the receiver's
  capability answers say it cannot present the source, e.g. H.264 1080p50/60 on a Chromecast Ultra,
  HEVC on non-HEVC receivers; HDR kept or tone mapped), CastAudioTranscoder (AudioToolbox to AAC-LC
  stereo for MPEG audio, and AC-3/E-AC-3 when the receiver lacks it), CastAudioFrameParser.

AirPlay (iPhone/iPad)
- App/TSHLSRemuxer.swift: on-device TS-to-HLS remuxer (keyframe-cut, packet copy, no transcode)
  serving loopback for local AVPlayer and a LAN listener for AirPlay: muxed TS playlist `/live.m3u8`
  with a publication delay (hold-back).
- App/TSLANAudioRewriter.swift: for receivers that cannot decode AC-3/E-AC-3 (Roku) the LAN copy of
  each segment carries AAC-LC stereo muxed into the same TS segment. Pure logic, compiled by the
  test script.
- App/AirPlayTileDelivery.swift: moves a live tile between loopback and LAN delivery, suspends
  local-render watchdogs, keepalive, PiP.
- App/AirPlayMonitor.swift: AirPlay phase for the remote-session card;
  App/AirPlayReceiverResolver.swift picks the receiver class. Shared/AirPlayAudioMode.swift.
- Remote-session card and controls sheet must be identical for Cast, AirPlay and AerioTV Remote.

Players
- AVPlayer is the primary engine (App/PlayerView.swift, LiveFMP4Remuxer.swift, MKVFMP4Remuxer.swift
  for MKV VOD/DVR, HeadlessPlaybackController.swift, NowPlayingBridge.swift). mpv (MPVKit,
  App/MPVPlayerView.swift) remains as legacy and is slated for removal. Shared/PlayerSession.swift
  owns the active session. Multiview in Features/Multiview.

Backends and data
- Networking: DispatcharrDirectConnect.swift, StreamingAPIs.swift, MediaServerAPIs.swift,
  XtreamSeriesAPI.swift, VODService.swift, PlaylistParsers.swift (M3U/XMLTV), NWHTTPClient.swift,
  HTTPRouter.swift.
- EPG/guide: Features/LiveTV (EPGGuideView, ChannelListView, GuideJumpSheet, ProgramInfoView). DVR:
  Features/DVR plus Shared/RecordingCoordinator.swift, LocalRecordingSession.swift. VOD:
  Features/VOD plus Shared/VODCatalogStore.swift. Sync: Shared/SyncManager.swift. Credentials:
  Shared/KeychainHelper.swift.
- All media is scoped to the active playlist.

## 6. Standing rules for edits (from the owner)
- Never use em dashes (U+2014), anywhere: code, comments, copy, commits.
- No emojis in GitHub-facing content (commits, PRs, releases, issues, README).
- US spelling in user-facing copy: "program", never "programme" (XMLTV element names exempt).
- User-facing copy says AerioTV. No third-party IPTV app names in copy.
- No server-side (Dispatcharr) fixes or profile/setting changes as the fix. The app tolerates what
  the server sends.
- Full cross-platform parity with the Android app: identical menus, wording, cards, sheets,
  gestures. Platform-native controls only where the platform dictates. Every fix lands on all
  applicable platforms.
- Hard data only: never assume, never say the owner did something wrong or different. Measure the
  authoritative source first.
- The codec patent notice must stay in README.md (Patents), THIRD_PARTY_LICENSES.md (Decoders and
  patents) and the About/Licenses screen (OpenSourceLicensesView.patentNotice). No Dolby branding in
  UI.
- Platform encoders only (VideoToolbox, AudioToolbox). No bundled x265 or FFmpeg encoders.
- Never publish or sideload anything on a Roku.
- Never bundle playlist/EPG URLs, credentials or sample media.
- Commit messages explain why, and end with `Co-Authored-By: Claude Fable 5.1
  <noreply@anthropic.com>`. Every commit is pushed.
- Version bumps and releases only when the owner says. Flagged features stay on branches.

## 7. Devices and test infrastructure (no secrets here)
- Chromecast Ultra "Travel Chromecast": web receiver path (H.264 1080p tops out near 47 fps; drives
  the phone transcode).
- Google TV Streamers: Cast Connect into the AerioTV Android TV app.
- Roku Streaming Stick: AirPlay target (muxed TS only, AAC stereo audio, keep-alive HTTP required).
- Apple TV: tvOS app and AerioTV Remote host; AirPlay receiver.
- The receiver page lives in the Android repo's gh-pages branch and is edited live; changes there
  reach every Cast device immediately.
- Device UDIDs, server URLs and Cast console details live outside this repo; ask the owner.
