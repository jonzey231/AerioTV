# AirPlay rebuild plan (AVP-AIRPLAY / TS-REMUX airplay-aac)

Derived from `2026-09-21-airplay-cast-rebuild.md` and the recovered phone log. Sequencing:
the Chromecast AC-3 -> AAC-LC transcode in `CastFMP4Remuxer` lands first; the airplay-aac
variant reuses it and must not fork it.

## 0. What exists today

| Piece | Where | Status |
|---|---|---|
| `AirPlayMonitor` (watches `isExternalPlaybackActive`, reads route name from `AVAudioSession`) | `App/AerioCastController.swift` ~3078 | Exists. Logs `[Cast] card show/hide (AirPlay)`. No receiver identification, no phases. |
| `RemoteSessionCard`, `.airPlay` card and sheet | `AerioCastController.swift` ~3166, `Features/Home/HomeView.swift` ~5999-6150 | Exists. Status always "Playing on \(device)". No connecting / select-a-channel state. |
| Remuxer server | `App/TSHLSRemuxer.swift`: `TSHLSRemuxer` (~226), `startServer` (~2008, `requiredInterfaceType = .loopback`), `serve(path:)` (~2078), ingest (~2170), `handlePacket` (~910) | Loopback only. Routes: `live.m3u8`, `init.mp4`, `/segN.ts`, `/segN.m4s`. |
| Tile `AVPlayerMultiviewTile` | `TSHLSRemuxer.swift` ~2968; `startPlayer` ~4921 calls `AirPlayMonitor.attach`; stall watchdog ~5228; `quiesceForBackground` ~4465; `syncPiP` ~5510 | Hooks go here. |
| Fullscreen AVPlayer engine | `App/PlayerView.swift` ~7367 (`allowsExternalPlayback = true`, `usesExternalPlaybackWhileExternalScreenIsActive = true`); `[AVP-FREEZE]` watchdog ~5527 | Keep. |
| Transcoder | `CastAudioTranscoder`, `CastFMP4Remuxer(allowAC3Passthrough:, transcoderFactory:)` | Being extended for AC-3 by the Cast work. Reuse. |
| Demuxed store | `CastHLSSegmentStore`: `setDemuxedInitSegments`, `videoPlaylistText`/`audioPlaylistText`, `demuxedMasterPlaylistText`, `awaitSegment(seq:rendition:)` | Reuse as is. |
| Keepalive | `CastHLSProxySession.swift` ~352-410 (private `AVAudioEngine` + `AudioSessionRefCount`) | Extract into a shared engine (§6). |
| Info.plist | `SupportingFiles/Info.plist` | Has `NSAllowsArbitraryLoads` only (keep), `NSLocalNetworkUsageDescription`, Bonjour `_googlecast._tcp`, `_46B79062._googlecast._tcp`, `_aeriotv._tcp`. `_airplay._tcp` missing. Background mode `audio` present. |

## 1. Settings: AirPlay audio mode
- New `Shared/AirPlayAudioMode.swift`: `enum AirPlayAudioMode: String, CaseIterable { case automatic, passthrough, stereo }`, `storageKey = "airPlayAudioMode"`, default `.automatic`, `logLabel` = raw value so the log reads `(mode: automatic)`.
- `Features/Settings/PlayerSettingsView.swift`: `@AppStorage` picker, iOS only. Labels: "Automatic (Apple TV keeps surround, others get stereo)", "Always passthrough", "Always stereo AAC". Footer carries the Roku constraint (§11).

## 2. Route detection and receiver identification
New `App/AirPlayReceiverResolver.swift` (iOS, `@MainActor final class`):
- `struct AirPlayReceiver { name; nameResolved; uidHash?; macPresent; model?; isApple }`
- Bonjour: `NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil))`, live cache `[name: TXT]`. TXT keys: `model` (`AppleTV14,1`, `Mac16,12`, `3941X2`), `deviceid` (MAC, "mac present"), `pi`/`psi` (hash into `uid#xxxxxxxx/NN`, NN = length).
- `isApple`: model prefix `AppleTV`, `AudioAccessory`, `Mac`, `iPad`, `iPhone`. Unknown model -> false (`model=unknown apple=false`).
- Match `AVAudioSession.currentRoute.outputs.first { $0.portType == .airPlay }` by `portName`, then `uid` vs `deviceid`. Names may carry a trailing space (`'Roku Express 4K '`): keep raw for display, trim for matching.
- Retry ladder: re-read route name at 0.25, 0.5, 1, 2, 4, 8 s. If still nil or "AirPlay": `[AVP-AIRPLAY] route name still UNRESOLVED after the retry ladder; card and lock screen stay on the generic label, receiver stays unknown` (log shows ~9-13 s after card show).
- Browser failure: `[AVP-AIRPLAY] receiver browse failed: \(code): \(name)` (e.g. `-65569: DefunctConnection`); cancel, restart once after 1 s; fall back to name-only.
- Receiver line, once per receiver change: `receiver '\(name)' (name resolved|name UNRESOLVED, uid#…, mac present) model=\(model ?? "unknown") apple=\(isApple) -> audio passthrough|audio AAC-LC stereo (mode: \(mode))`. Parenthetical omitted when no uid (Roku lines).
- Launch probe in `AerioApp` on scene active: `AVRouteDetector` (`isRouteDetectionEnabled = true`), wait 2 s, log `[AVP-AIRPLAY] airplay routes detected=\(multipleRoutesDetected) (window: launch)`.

Extend `AirPlayMonitor` (prefer moving it to new `App/AirPlayMonitor.swift`):
- `@Published var phase: AirPlayPhase` with `enum AirPlayPhase { none, probing(routeName:), idleRoute(String?), active, routeLost, ended }`.
- Route change (`AVAudioSession.routeChangeNotification`):
  - AirPlay output present, no player external: `.probing` if a tile is loading else `.idleRoute`. Log `[Cast] card show (AirPlay, probing route \(name ?? "?"))` / `card show (AirPlay idle route \(name ?? "unresolved"))`.
  - Output disappears while `.active`: `[Cast] card hide (AirPlay route lost); playback continues on this device`.
  - `.idleRoute` goes away: `card hide (AirPlay idle route)`.
- `stop()`: `card hide (AirPlay, session ended)`.
- `receiver: AirPlayReceiver?` set by the resolver; `deviceName` from `receiver?.name` when resolved.

## 3. Audio plan (per tile when the external route comes up)
In the tile near `startPlayer`: `airPlayAudioPlan(sourceCodec:receiver:mode:) -> AirPlayAudioPlan { passthrough, aacStereo, passthroughDecoderUnavailable }`:
1. `[AVP-AIRPLAY] item audio codec=\(AC-3|E-AC-3|AAC|unknown) channel=\(channelName)`. Codec from the remuxer's PMT stream type (`handlePacket`); expose `remuxer.sourceAudioCodec`.
2. Receiver line (§2).
3. Plan: `.passthrough` mode, Apple receiver, or already-AAC -> passthrough. Else if AC-3/E-AC-3/MP2 and transcoder available: `[AVP-AIRPLAY] audio: source AC-3 stereo -> AAC stereo for AirPlay` (real channel label, e.g. `5.1`). Else `[AVP-AIRPLAY] audio: passthrough (decoder unavailable)`. Unknown codec: passthrough.

## 4. LAN delivery in `TSHLSRemuxer`
Listener (`startServer`):
- Keep loopback listener. Add `startLANDelivery() -> (ip, port)?` and `stopLANDelivery()`: a second `NWListener`, `requiredInterfaceType = .wifi` (fallback `.wiredEthernet`), port `.any`. Log evidence: loopback 56323 then LAN 56324.
- LAN IPv4 via `getifaddrs` on `en0`/`en1`, `AF_INET`, not link-local. None: `[AVP-AIRPLAY] no LAN address for the remux server; starting on loopback`.
- Stop: `[TS-REMUX] LAN delivery stopped (loopback only)`.
- Peer filter: accept only RFC1918 / link-local peers, else 403 (the stream now leaves the device).
- In-process delivery (`inProcessDelivery == true`) cannot be AirPlayed; that case and listener failure log `[AVP-AIRPLAY] LAN delivery unavailable; leaving the loopback item in place`.

Routes in `serve(path:)`, before existing branches, all mapped onto `AirPlayAACVariant` (§4b):
- `/aac/master.m3u8` -> `demuxedMasterPlaylistText()`
- `/aac/video.m3u8`, `/aac/audio.m3u8` -> `videoPlaylistText()` / `audioPlaylistText()`
- `/aac/vinitN.mp4`, `/aac/ainitN.mp4` -> init segments by generation
- `/aac/vsegN.m4s`, `/aac/asegN.m4s` -> `awaitSegment(seq:rendition:)`
- Log every `/aac` request: `[AVP-AIRPLAY] GET \(path) -> \(status) \(kind) seq \(n) \(bytes) B` (kind: master, video, audio, vinit, ainit, vseg, aseg; playlists `seq -1`). Count per kind for `served`.

### 4b. New `App/AirPlayAACVariant.swift`
- Owns `CastFMP4Remuxer(targetSegmentTicks: ~5s, allowAC3Passthrough: false, log: { debugLog("[TS-REMUX] airplay-aac \($0)") })` and a `CastHLSSegmentStore`.
- Feed: `TSHLSRemuxer.handlePacket` tees raw TS bytes into `variant.feed(_:)` on the remux queue. No second ingest.
- Start: `[TS-REMUX] airplay-aac variant started (source AC-3)`; prime from buffered TS segments: `primed from N buffered segments (seq a...b, B B)`; after ~5 s `audio census: …`. The remuxer emits the transcoder lines (transcoding…, audio transcode active…, audio codecs up…, video init: mehd 24h…, init ready…, gated/resumed, audio pts discontinuity (Nms), flushing transcode codecs, splice tail) which the prefix turns into the logged `airplay-aac …` forms.
- Stop: `variant stopped`.
- Readiness gate before handing AVPlayer the URL: ≥3 segments or hold-back met, then `[AVP-AIRPLAY] variant ready: window seq A...B (n of N ring, target Ts[, window Ws, hold-back Hs of Hs wanted, live edge Es]) video end …s audio end …s delta …s, audio-bearing N, backlog v= a= units= emitted …s, served none`.
- Serving log every 5 s: same template with `variant serving:` and `served ainit=… aseg=… audio=… master=… video=… vinit=… vseg=…`. Use the later template with window and hold-back (09-24 log).
- Ring: 8 segments ("5 of 8 ring").

### 4c. Handoff (tile)
`beginExternalDelivery()` / `endExternalDelivery()`, driven by KVO on `avPlayer.isExternalPlaybackActive` (per-tile observer in addition to the monitor).

Route becomes active mid-play:
1. Audio plan (§3). For AAC, start variant and wait for readiness.
2. `startLANDelivery()`.
3. URL `http://<ip>:<port>/live.m3u8` (passthrough) or `/aac/master.m3u8` (AAC).
4. `avPlayer.replaceCurrentItem(with: AVPlayerItem(url: lanURL))` with the same forward-buffer settings.
5. `[AVP-AIRPLAY] external playback active: serving on LAN \(ip):\(port), watchdogs suspended`.
6. Suspend watchdogs (§6), keepalive on (§6), PiP disarm (§7), Now Playing (§8).

AVPlayer in AirPlay video mode hands the item URL to the receiver; a `127.0.0.1` URL is unreachable from it, so the LAN URL is required.

Already selected at start: in `startPlayer`, if `AVAudioSession.currentRoute` already has an `.airPlay` output (or monitor phase is `.probing`), go straight to LAN: `AirPlay route already selected: starting on LAN ip:port, watchdogs suspended` (~2 s after `loopback server ready`), skipping the loopback item.

End: swap back to loopback URL, stop variant and LAN listener, `external playback ended: back to loopback delivery, watchdogs re-armed`.

## 5. Join point
For a LAN/AAC item skip the tile's primary live-edge offset (`[AVP-MV] live edge offset …` / `[AVP-HOLDBACK] join offset raised`), leave `configuredTimeOffsetFromLive` unset, let `EXT-X-SERVER-CONTROL:HOLD-BACK` decide. Log `[AVP-AIRPLAY] join offset left to the variant playlist's HOLD-BACK (primary offset not applied) channel=\(channelName)`.

## 6. Watchdogs, keepalive, background
- Watchdogs: add `suspended: Bool` to `AVPStallWatchdog` (~2307), tick returns early while suspended, resume resets baseline. Same for the fullscreen `[AVP-FREEZE]` clock (`PlayerView.swift` ~5520). Tile logs `[AVP-AIRPLAY] tile \(channelName): external playback active, local-render watchdogs suspended` / `tile \(channelName): external playback ended, watchdogs re-armed`. Skip `[AVP-LAYER] isReadyForDisplay` escalation while external.
- New `Shared/BackgroundKeepalive.swift`: `@MainActor enum BackgroundKeepalive { hold(_ id:), release(_ id:), holders }`. First holder starts the silent `AVAudioEngine` (moved from `CastHLSProxySession.swift` ~370-405) and `AudioSessionRefCount.increment(caller: "keepalive")`. Logs `[KEEPALIVE] background keepalive engine running (+\(id))` / `… stopped (-\(id))`. Cast proxy migrates to `hold("cast-hls-proxy")`. Tile calls `hold("airplay-video")` / `release` and logs `[AVP-AIRPLAY] background keepalive on|off`.
- Background (tile `didEnterBackground` ~3287, before `quiesceForBackground`): if external active, log `[AVP-AIRPLAY] background entry: keepalive=on holders=\(holders.joined(",")); still running: AVPlayer external playback, TSHLSRemuxer ingest URLSession, remuxer NWListener (loopback + LAN delivery)[, AAC transcode for the receiver]; tile background quiesce suppressed for this session` then `background: pipeline NOT quiesced, the receiver is being served from this phone channel=\(channelName)` and return. Guard `!isExternalPlaybackActive` inside `quiesceForBackground`. `LiveChannelRetention.stopAll` on app background must skip the external session.

## 7. PiP
In `syncPiP`: `pip.canStartPictureInPictureAutomaticallyFromInline = !AirPlayMonitor.shared.isExternal`. Log `controller armed (auto-start from inline: on)` / `(auto-start from inline: disarmed, AirPlay external)`; tile logs `[AVP-PIP] auto-start from inline disarmed (AirPlay external)` / `auto-start from inline re-armed`.

## 8. Now Playing
New `App/RemoteSessionNowPlaying.swift` (or `NowPlayingBridge` extension): `publish(kind: .airplay|.cast, channel:, program:, device:)`. Logs `[NOWPLAYING] publish remote session kind=\(kind) channel=\(ch) program=\(prog ?? "-") device=\(device)` and `[NOWPLAYING] cleared`. `device` = `"AirPlay · \(receiver.name)"` when resolved, plain `"AirPlay"` otherwise (treat generic name "AirPlay" as unresolved to avoid `AirPlay · AirPlay`). Trigger on external active and EPG program change; `stop()` / route loss -> cleared. Cast side (`device=Casting to X`) calls the same API.

## 9. Card and sheet (`HomeView.swift` ~5999-6150, `RemoteSessionCard`)
- `activeRemoteTransport` returns `.airPlay` when phase is `.probing`, `.idleRoute` or `.active`.

| Phase | Title | Status | Transport | Buttons |
|---|---|---|---|---|
| probing | channel or "AirPlay" | "Connecting to AirPlay" | hidden | |
| active | channel | "Playing on AirPlay" / "Playing on \(name)" when resolved | shown | |
| idleRoute | "Connected. Select a channel to start." | "Select a Channel" | hidden | Disconnect, Change AirPlay Device |

- `.idleRoute` sheet: Disconnect (`AirPlayMonitor.stop()`, sets `allowsExternalPlayback=false` for the session) and Change AirPlay Device (`AirPlayMenuTrigger.present()`, `PlayerView.swift` ~4659).
- Sheet: Channel Up/Down (`nowPlaying.changeChannel`), "Stop AirPlay", no skip closures so only Pause shows, plus a "Change AirPlay Device" row.
- `RemoteControlScreen`: optional `onSkipBack`/`onSkipForward`, hidden when nil.
- "Cast to" picker AirPlay row ("Choose a TV, then start a channel") calls `AirPlayMenuTrigger.present()` (`CastPickerSheet` ~2824).
- Replace deprecated `showsRouteButton` (PlayerView ~388) with `AVRoutePickerView.prioritizesVideoDevices = true`; relabel "AirPlay (Audio Only)" (~4167).

## 10. Info.plist
- Add `_airplay._tcp` to `NSBonjourServices` (else `NWBrowser` fails with -65555 NoAuth).
- Update `NSLocalNetworkUsageDescription` to mention AirPlay and Cast receivers.
- Leave ATS alone (comment at line ~50: adding `NSAllowsLocalNetworking` disables `NSAllowsArbitraryLoads`).

## 11. Constraint
Roku's AirPlay receiver accepts neither AC-3 nor E-AC-3. Non-Apple receivers get AAC-LC stereo 160 kbps 48 kHz. Apple TV and Mac receivers keep AC-3 passthrough. `passthrough` mode on a Roku gives no audio; the settings footer must say so.

## Verification (device, grep the debug log per template)
1. Apple TV: pick route first, then channel. Expect "already selected", then `GET /live.m3u8` from the receiver IP.
2. Roku: full `/aac` GET sequence, then `variant serving` every 5 s.
3. Route change mid-play.
4. Background 5 min; receiver must not starve.
5. Route loss: card hide line, local playback continues.
6. Wi-Fi off: "no LAN address".
7. Force in-process delivery: "LAN delivery unavailable".

## Open questions (highest risk first), recommended defaults
1. AVPlayer handoff mechanism: no item-swap line in the log; "external playback active" follows the receiver line by 6 ms. Default: `replaceCurrentItem` with the LAN URL, keep loopback item warm for rollback.
2. Mid-play route change to a Roku shows "active" before "variant ready". Default: swap only after `variant ready`, 6 s timeout, then passthrough plus "LAN delivery unavailable".
3. Listener binding: separate ports prove two listeners. Default: second listener with RFC1918 peer filter.
4. Keepalive extraction touches `CastHLSProxySession`. Default: add `BackgroundKeepalive` now, migrate Cast proxy after.
5. `isApple`: MacBook Air was `apple=true`. Default: prefix list in §2.
6. `stereo` mode on Apple receivers: force AAC.
7. Ring/target: targets 5 s and 7 s seen, 8-segment ring. Default: 5 s target, ring 8, hold-back 3× target.
8. Idle-route card on launch (seen at 12:43 for Living Room Apple TV). Default: only when the route has a video-capable AirPlay output and no Cast/companion session is active.
9. Retry ladder timings: only the end result is logged. Default: 0.25, 0.5, 1, 2, 4, 8 s.
