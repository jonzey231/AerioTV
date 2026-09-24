# AirPlay and Chromecast work of 2026-09-21: what was lost and what the phone build tells us

The MacBook Pro that held the 09-21 commits went to Apple with its SSD wiped. The work was
never pushed. The only surviving artifact is the debug build **1.8.40 (1)** still installed on
Logan's iPhone, whose `aerio_debug_logs.txt` covers 09-18 through 09-24 and includes the entire
09-21 development day. Full log copy: `~/Documents/Development/Apple/Misc/AerioTV-recovery/`
(outside the repo, contains server URLs and device names).

Repo baseline for the rebuild: `feature/settings-phase3` @ 39228ed (09-19), same marketing
version 1.8.40 as the phone build.

## Timeline reconstructed from the log (09-21, local time)

| Time  | First appearance                                                     |
|-------|----------------------------------------------------------------------|
| 09:02 | `[Cast] card show (AirPlay)` — cast card now also drives AirPlay     |
| 09:08 | `receiver caps` / `audio plan` used live in a Cast session           |
| 10:10 | `[CAST-HLS] transcoding AC-3 stereo -> AAC-LC` (Chromecast AC-3 fix)  |
| 10:11 | `[AVP-AIRPLAY]` subsystem; LAN delivery; `demuxed master playlist`    |
| 10:26 | `airplay-aac` variant in TSHLSRemuxer; first Roku test               |
| 11:15 | `[KEEPALIVE]` background keepalive engine (+airplay-video)           |
| 11:24 | `[NOWPLAYING] publish remote session` for AirPlay and Cast           |
| 11:34 | Last Roku test of the day (working)                                  |
| 16:31 | Further sessions; 21:42 last long session                             |

## Chromecast fix (CAST-HLS)

Already in the 09-19 source: `CastHLSProxy/*` (server, session, segment store, FMP4 remuxer),
`CastAudioTranscoder` (AudioConverter based), `AerioCastController` with `receiver caps` and
`audio plan` logging.

New on 09-21, per log lines with no matching string in source:
- The AC-3 -> AAC-LC transcode path is actually wired into the proxy session:
  `transcoding AC-3 stereo 48000 Hz -> AAC-LC stereo (receiver cannot decode AC-3)`,
  `audio codecs up: decoder=AudioConverter(AC-3) encoder=AAC-LC stereo Nkbps @48000Hz`,
  `audio transcode active: AC-3 2ch 48000Hz -> AAC-LC stereo`.
- Audio plan output: `receiver=Chromecast caps=measured ac-3=no ec-3=no aac=yes -> ingest=plain audio=transcode-aac`.
- Demuxed master playlist served as two renditions (`video.m3u8` + `audio.m3u8`,
  `#EXT-X-MEDIA TYPE=AUDIO GROUP-ID="aud"`, `CODECS="avc1,mp4a.40.2"`) with `vinit/ainit` init
  segments and `vseg/aseg` media segments; `HOLD-BACK` in `EXT-X-SERVER-CONTROL`.
- Transcoded audio gating: `transcoded audio gated: N units dropped, pts below timeline base`
  then `resumed after N gated units` (drops audio that predates the video timeline base).
- Splice tail trimming: `splice tail: video end N audio end N trimmed N ms`.
- Failure surfaced to the user when transcode is impossible:
  `cast failure surfaced: This receiver cannot decode this channel's surround audio (AC-3).`
- Keepalive engine gained a `cast-hls-proxy` holder.

## AirPlay fix (AVP-AIRPLAY, TS-REMUX airplay-aac)

Nothing of this exists on any pushed branch. Design as evidenced by the log:

1. **Route detection.** `airplay routes detected=true (window: launch)`; `AVRoutePickerView`
   already used in PlayerView. Cast card shows for AirPlay too, with states
   `probing route`, `idle route`, `route lost`, `session ended`.
2. **Receiver identification** via Bonjour browse:
   `receiver 'Living Room Apple TV' (name resolved, uid#…, mac present) model=AppleTV14,1 apple=true -> audio passthrough (mode: automatic)`
   `receiver 'Roku Express 4K' model=… apple=false -> audio AAC-LC stereo (mode: automatic)`
   with a retry ladder: `route name still UNRESOLVED after the retry ladder; card and lock
   screen stay on the generic label, receiver stays unknown`. `receiver browse failed:
   DefunctConnection` handled. "mode: automatic" implies a user setting (auto / passthrough / stereo).
3. **Audio plan.** Apple receivers get passthrough (AC-3 untouched). Non-Apple (Roku) get
   `audio: source AC-3 stereo -> AAC stereo for AirPlay` via an `airplay-aac` variant in
   TSHLSRemuxer that reuses the Cast transcoder: `airplay-aac variant started`, `audio codecs
   up`, `video init/audio init: mehd`, `init ready`, `primed from …`, `audio census`,
   `audio pts discontinuity`, gating and resume identical to CAST-HLS. Fallback:
   `audio: passthrough (decoder unavailable)`.
4. **LAN delivery.** The remuxer's NWListener, previously loopback only
   (`delivery: loopback (no system proxy)`), serves on the LAN while external playback is
   active: `external playback active: serving on LAN 192.168.x.x:port, watchdogs suspended`;
   `AirPlay route already selected: starting on LAN …`; on end `back to loopback delivery,
   watchdogs re-armed`; `LAN delivery unavailable; leaving the loopback item in place`;
   `no LAN address for the remux server; starting on loopback`.
   Paths served: `/aac/master.m3u8`, `/aac/video.m3u8`, `/aac/audio.m3u8`, `/aac/vinit*.mp4`,
   `/aac/ainit*.mp4`, `/aac/vseg*.m4s`, `/aac/aseg*.m4s`. Ring window logged as
   `variant serving: window seq A…B (n of N ring, target Ns, hold-back Ns, live edge Ns)`.
5. **Join point.** `join offset left to the variant playlist's HOLD-BACK (primary offset not applied)`.
6. **Watchdogs.** Local render watchdogs (freeze/hang detectors) suspended per tile while
   external playback is active: `tile ESPN HD: external playback active, local-render watchdogs suspended`.
7. **Background.** `background entry: keepalive=on holders=airplay-video; still running:
   AVPlayer external playback, TSHLSRemuxer ingest URLSession, remuxer NWListener (loopback +
   LAN delivery), AAC transcode for the receiver; tile background quiesce suppressed for this
   session` and `background: pipeline NOT quiesced, the receiver is being served from this phone`.
8. **PiP** auto-start from inline is disarmed during AirPlay and re-armed after.
9. **Now Playing.** `publish remote session kind=airplay|cast channel=… program=… device=AirPlay · Living Room Apple TV`
   and `cleared`. Lock screen and card show the resolved receiver name.

## UI (from screenshots 09-24)

- "Cast to" sheet: sections *AerioTV on TV* (companion, "no phone processing, full quality"),
  *Google Cast* device list with connecting spinner, *AirPlay* row ("Choose a TV, then start a channel").
- Collapsed banner above the tab bar: icon, channel name, "Casting to X" / "Connecting to AirPlay" /
  "Playing on AirPlay", pause and close buttons. Pre-channel state: "Connected. Select a channel
  to start." with Disconnect / Change AirPlay Device.
- Expanded sheet: channel logo, name, "Casting to X" / "Playing on AirPlay", program title with
  LIVE badge and progress, Channel Down / Channel Up, Back 5s / Pause / Forward 60s (Cast only;
  AirPlay shows Pause only), Options, Stop Casting / Stop AirPlay.

## Constraint

Roku's AirPlay receiver does not accept AC-3/E-AC-3, so surround over AirPlay to Roku is
impossible; the 09-21 build downmixed to AAC stereo. Apple TV keeps passthrough.
