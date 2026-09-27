# How other apps deliver 1080p60 / 4K to Chromecast (research, 2026-09-26)

Internal doc. Problem: phone remuxes MPEG-TS (H.264/HEVC + AC-3) to demuxed fMP4 HLS, custom CAF receiver on Shaka/MSE; 1080p59.94 H.264 decodes at ~40 fps on a Chromecast Ultra.

## Comparison

| App | Source handled | Sends to Ultra for 1080p60 H.264 | Pipeline | Capability probe | 4K | Notes |
|---|---|---|---|---|---|---|
| Jellyfin (jellyfin-chromecast) | Anything server-side | Direct play if container is mp4/m4v/webm; else HLS, fMP4 preferred, TS fallback (for AC-3/E-AC-3/MP3 copy) [1] | Custom CAF receiver, CAF default player for HLS (Shaka as of the Nov 2025 CAF default switch [5]) | `castContext.canDisplayType(mime, codecs, w, h)` sweeps: max 16:9 resolution, H.264 levels 1.0 to 6.2, HEVC levels [2]. No model table, no frame rate probe [2] | Yes if canDisplayType reports HEVC 4K | AAC capped to 2 ch [1]. Users report 1080p60 transcodes stutter every second [6]; Ultra misdetected as 720p max in one report [7] |
| VLC (sout chromecast) | Any local/network input | H.264/VP8/VP9 passthrough, remuxed into a single progressive Matroska (or WebM) HTTP stream; transcodes to H.264 only if codec unsupported, audio to MP3 as last resort; AC-3/E-AC-3 passed if passthrough enabled [3] | Default Media Receiver, one progressive file, not segmented HLS [3] | Codec lists in code; no resolution/fps limits [3] | Only via passthrough HEVC/VP9 | Progressive MKV goes to the device's native media path, no JS segment appends |
| Plex | Server-side | Direct play when codec/level fits, otherwise server transcode (commonly reported). UNVERIFIED: exact container/profile not in public docs I could fetch | Plex custom receiver | UNVERIFIED | Ultra direct play of HEVC 4K reported by users (UNVERIFIED) | Community threads show Ultra stutter even at 10 Mbps direct play on wired Ethernet [8] |
| Emby | Server-side | UNVERIFIED (no primary source fetched); receiver is a fork lineage shared with Jellyfin, so likely similar HLS/transcode profile | Custom receiver | UNVERIFIED | UNVERIFIED | |
| Google (spec) | n/a | Ultra: H.264 High up to level 4.2 (1080p60), HEVC Main/Main10 up to 5.1 (4K60) [4] | CAF: MPL legacy, Shaka is recommended/default for HLS; MPL cannot play fMP4 HLS [5][9] | canDisplayType / isTypeSupported | CCwGTV and Streamer HEVC/VP9/AV1 4K per [4] | Ultra picks 60 Hz output unless "video smoothness" is off [10] |

## Frame rate gotchas found
- Chromecast outputs 50 or 59.94 Hz, not 60.000 or 24.000; mismatched rates cause periodic judder [6]. Our 59.94 source is the good case, so the 40 fps number is a decode/pipeline limit, not a cadence one.
- Shaka appends one blob per segment, so the MSE buffer grows in jumps; reported to cause frame drops at 1080p+ on constrained devices (hevc.js issue, not Cast specific) [11].

## Approaches most likely to give full rate

1. **Progressive single-file stream to the Default Media Receiver / native path (VLC model).** VLC is the only studied project that casts arbitrary live sources without a server, and it does so by remuxing to one progressive Matroska HTTP stream, avoiding HLS and MSE entirely [3]. Test: serve the live remux as chunked `video/mp4` (fragmented, single stream, muxed A/V) or MKV to a receiver that sets `media.src` directly, and measure fps on the Ultra. Evidence for the fps gain is inferential (no MSE/JS path), UNVERIFIED by any published benchmark.
2. **Keep HLS but muxed MPEG-TS, not demuxed fMP4.** Jellyfin's TS fallback path is its long-running compatibility route [1]. Worth an A/B: TS HLS (Shaka transmux cost vs MPL if still selectable) and muxed fMP4 (one SourceBuffer pair less contention). Also try smaller segments / partial appends to avoid the burst-append pattern [11].
3. **Capability-driven fallback like Jellyfin.** Probe with `canDisplayType` (level, width, height, and a `framerate` param which CAF accepts) [2]; if the Ultra cannot sustain 1080p60 in our pipeline, fall back to 1080p30 or 720p60 via Dispatcharr output profile. Note project rule: no server-side changes, so this only covers existing profiles. For 4K on CCwGTV/Streamer, HEVC passthrough in fMP4 per canDisplayType is what Jellyfin does [1][2].

## Sources
1. https://github.com/jellyfin/jellyfin-chromecast/blob/master/src/components/deviceprofileBuilder.ts
2. https://github.com/jellyfin/jellyfin-chromecast/blob/master/src/components/codecSupportHelper.ts
3. https://github.com/videolan/vlc/blob/master/modules/stream_out/chromecast/cast.cpp
4. https://developers.google.com/cast/docs/media
5. https://developers.google.com/cast/docs/web_receiver/shaka_migration
6. https://github.com/jellyfin/jellyfin-chromecast/issues/363 and https://github.com/jellyfin/jellyfin-chromecast/issues/401
7. https://github.com/jellyfin/jellyfin-chromecast/issues/743
8. https://www.truenas.com/community/threads/choppy-play-with-plex-chromecast.92119/
9. https://community.bitmovin.com/t/how-to-play-hls-streams-with-fmp4-container-in-chromecast-cafv3-receivers/2335
10. https://support.google.com/chromecast/answer/7186055?hl=en
11. https://github.com/lid-labs/hevc.js/issues/126
