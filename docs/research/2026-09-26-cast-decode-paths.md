# Cast decode paths for 1080p60 and 4K (research, 2026-09-26)

Sources: [S1] https://developers.google.com/cast/docs/media , [S2] https://developers.google.com/cast/docs/web_receiver/shaka_migration , [S3] https://developers.google.com/cast/docs/reference/web_receiver/cast.framework.CastReceiverContext , [S4] https://developers.google.com/cast/docs/reference/web_receiver/cast.framework.system , [S5] https://github.com/shaka-project/shaka-player/issues/5776 , [S6] https://issuetracker.google.com/issues/139175785 , [S7] https://support.google.com/chromecast/answer/7186055 , [S8] https://developers.google.com/cast/docs/release-notes

## 1. Official codec limits (all from S1)

| Device | H.264 | HEVC | VP9 | AV1 |
|---|---|---|---|---|
| Chromecast 3rd gen | High up to L4.2 (1080p60) | no | not listed | no |
| Chromecast Ultra | High up to L4.2 (1080p60); no 4K H.264 | Main/Main10 up to L5.1 (4K60) | Profile 0 and 2 up to L5.1 (4K60) | no |
| Chromecast with Google TV (4K) | High up to L5.1 (4Kx2K 30fps) | Main/Main10 up to L5.1 (4K60) | Profile 2 up to 4K60 | no |
| Google TV Streamer | High up to L5.2 (4Kx2K 60fps) | Main/Main10 up to L5.1 (4K60) | Profile 2 up to 4K60 | Main up to L5.1 (4K60) |

S1 caution: "HEVC is not supported on Transport Stream containers" (so 4K HEVC must be fMP4/CMAF). H.264 4K: none on Ultra; 4K30 only on CCwGTV; 4K60 only on Streamer.

## 2. CAF pipelines and capability APIs
- HLS runs either on Shaka Player or the legacy Media Player Library (MPL), selected by `CastReceiverOptions.useShakaForHls` evaluated at `CastReceiverContext.start()`. Default flipped from false to true on 2026-05-18; set it to `false` to opt back into MPL (S2). S2 recommends Shaka >= 4.15.56 (what the Ultra reports). MPL "will no longer receive critical updates" (S2).
- `useLegacyDashSupport` selects MPL for DASH (unverified here; present in the SDK typings, not re-fetched). `PlaybackConfig.shakaConfig` passes Shaka config (unverified detail).
- Whether MPL uses a different decoder path than MSE: unverified. Both run inside the Cast Chrome runtime; MPL is also believed to be MSE-based (unverified), so the hardware decoder should be the same.
- `canDisplayType(mimeType, codecs, width, height, framerate)` checks "if the given media params ... are supported by the platform" (S3). It is the Cast-specific query that takes resolution and frame rate; `MediaSource.isTypeSupported` only sees the MIME/codec string. Shaka on Cast routes capability checks through `canDisplayType`, and there are reports of it returning false for streams the device plays, e.g. a 3rd gen reporting it cannot display 1080p30 avc1.640028 (S5).
- No public report found specifically of `isTypeSupported` false for avc1.64002A on Ultra (unverified; our measurement is the only evidence). Since S1 lists L4.2 for Ultra, this looks like a platform string check gap, not a decoder limit.
- `getDeviceCapabilities()` keys relevant to 4K/HDR: `IS_HDR_SUPPORTED`, `IS_DV_SUPPORTED`, `DISPLAY_SUPPORTED`, `IS_DOLBY_ATMOS_SUPPORTED` (S4). There is no 4K key; probe 4K with `canDisplayType('video/mp4','hev1.2.4.L153.B0',3840,2160,60)` style calls (pattern unverified, API per S3).

## 3. Known slow/judder reports
- Google's own Ultra help page on smoothness (S7) concerns TV frame-rate matching, not decode rate.
- Issue tracker report of an m3u8 "kind of" freezing CAF while hls.js plays it (S6).
- No authoritative report found of 1080p60 H.264 running at ~0.66x on Ultra. Cause hypotheses below are unverified: (a) Shaka mislabels/rejects the level and the runtime picks a slower path, (b) demuxed AC-3 audio is the clock master and the audio sink (passthrough vs decode) throttles video, (c) the presented 39.7 fps with 0 dropped frames means the pipeline is being fed slowly, not dropping, which points at clock/audio or feeding, not raw decode.

## 4. Experiments on the Ultra (ranked)
1. Mute test: same stream with the audio playlist removed (video-only master). Measure playbackRate-equivalent (media time vs wall clock) and presented fps. If 1x, AC-3 path is the throttle; then try AAC ("Web Player (AAC Audio)" profile the app already requests for Cast).
2. MPL: set `useShakaForHls = false` (S2). Measure the same numbers. Tests whether Shaka's feeding/level handling is the cause.
3. Level string: keep avc1.640028 vs try avc1.4D402A / avc1.640032 in the master; log `canDisplayType('video/mp4','avc1.64002A',1920,1080,60)` and `...,30)`. Measure which labels load and rate.
4. Muxed segments: serve one muxed fMP4 (video+audio) rendition. Measure rate. Checks demuxed-sync overhead.
5. Segment packaging: check sample durations/`tfdt` continuity and that fragments are keyframe-aligned; try 2 s segments. Measure `getVideoPlaybackQuality()` totals and buffer level over 60 s.
6. Default Media Receiver (app id CC1AD845) with the same URL: baseline of Google's own receiver (unverified whether it uses Shaka or MPL today). If it also plays 0.66x, the stream is the problem, not our receiver.

## 5. Alternative paths
Default Media Receiver and Styled Media Receiver are still CAF web receivers on the same runtime (S1/S2 family docs), so they do not bypass MSE; native apps exist only on Google TV devices (Cast Connect to an Android TV app, which is what the Android app already does), not on the Ultra. DIAL is not a path for Ultra. So on the Ultra the fix must be inside the web receiver.

## 6. 4K plan implications
- Ultra and CCwGTV: 4K requires HEVC Main/Main10 (fMP4, never TS) or VP9 Profile 2 (S1). H.264 4K is not possible on Ultra and only 30 fps on CCwGTV.
- Streamer: H.264 up to 4K60, plus HEVC and AV1 (S1). Cast Connect to the Android TV app is preferable there.
- Gate by `canDisplayType` with width/height/framerate, plus `IS_HDR_SUPPORTED` for Main10/HDR (S3, S4); fall back to 1080p.
