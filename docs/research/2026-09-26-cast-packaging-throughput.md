# Cast packaging vs. receiver decode throughput (2026-09-26)

Symptom: Chromecast Ultra, custom CAF receiver (Shaka 4.15.56), 1080p59.94 H.264 High 4.2 presents 39.7 fps, 0 dropped, media advances at 0.66x with a full buffer. 720p59.94 plays at 1x.

## 1. How we package video (both platforms are the same design)

| Item | What we write | Where |
|---|---|---|
| Fragments | ONE `moof`+`mdat` per segment per rendition, all samples of the segment in one `trun` (not per frame, not per GOP) | iOS `CastFMP4Remuxer.swift:1494-1507`, Android `TsToFmp4Remuxer.kt:1148-1161` |
| Segment cut | First IDR (NAL type 5) at or after 3 s (`targetSegmentTicks` default 3 s), so ~4 s with a 2 s GOP; segment always opens on the IDR; leading non-IDR dropped at join | iOS `:203`, `:739-741`; Android `:72`, `:605-622` |
| `trun` | version 1, flags 0x000F01 (data-offset, duration, size, flags, CTO per sample); signed CTO = pts - dts, so B-frames get real composition offsets; no `ctts` | iOS `:1575-1585`; Android `:1239-1252` |
| Sample flags | IDR 0x02000000 (depends_on=2, sync); others 0x01010000 (depends_on=1, non-sync) | same |
| `tfhd` / `tfdt` | tfhd 0x020000 default-base-is-moof; tfdt v1 = first DTS minus generation base | iOS `:1524-1525`; Android `:1186-1187` |
| `trex` default | video 0x00010000 (non-sync), overridden per sample | Android `:1616` |
| Timescale | 90 kHz for mvhd/mdhd and all fragments; `mehd` v1 declares 24 h (keeps Chromium in "recorded" liveness) | Android `:1272-1287`, `:1614`; iOS `:1602-1623` |
| NAL format | 4-byte length prefix (avcC lengthSizeMinusOne=3), 1 SPS + 1 PPS in avcC, AND SPS/PPS/AUD/SEI kept in-band in every IDR sample | iOS `:743-752`, `:1635-1645`; Android `:624-631` |

Nothing in this depends on resolution: 720p60 and 1080p60 produce the same box count (one moof per ~4 s), and the per-segment box parsing cost is trivial at either rate. The only resolution-dependent quantity is bytes per sample. Conclusion: box structure is very unlikely to be the throttle; per-frame moofs, which would double parse rate at 60 fps, are NOT what we do.

## 2. What the platforms want

- Apple HLS authoring spec (https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices): fMP4 segments should start with an IDR, 6 s recommended segments, CODECS must be accurate; one moof per segment is normal. We comply, except we cap CODECS to 4.0 on receivers that answer no to 4.2 (Android `CastHlsProxyServer.kt:496-525`), which is a label, not a decoder config.
- Google Cast supported media (https://developers.google.com/cast/docs/media): Chromecast Ultra lists H.264 High up to level 4.2 and 1080p60 is inside that. So the codec config is nominally supported; 0.66x means the decoder or its input path cannot sustain 60 fps at 1080p for THIS bitstream.
- Chromium clocking: with an audio track, media time follows the audio renderer; when the video renderer cannot produce frames on time it reports underflow and the pipeline enters buffering rather than silently dropping (https://source.chromium.org/chromium/chromium/src/+/main:media/renderers/video_renderer_impl.cc). A smooth 0.66x with 0 drops is not that pattern; it fits the Cast CMA backend pacing the clock to the hardware decoder (chromecast/media/cma, https://source.chromium.org/chromium/chromium/src/+/main:chromecast/media/). Treat as hypothesis until measured.
- I did not find (and did not verify online, no web fetch in this pass) a Shaka issue that ties demuxed SourceBuffers or trun layout to sub-1x playback on Chromecast; do not cite one until found.

## 3. Audio rendition

AC-3 passthrough goes in a separate `audio/mp4` SourceBuffer because the Ultra answers no to `video/mp4; codecs="avc1.64002A,ac-3"` but yes to `audio/mp4; codecs="ac-3"` (iOS `CastHLSProxyServer.swift:19-21`). One moof per segment, trun v0 flags 0x000301 (duration+size), tfhd default flags 0x02000000 (all sync) (iOS `:1553`, `:1588-1597`; Android `:1199-1216`, `:1255-1267`). iOS writes a fixed per-frame duration, Android writes each frame's own duration (E-AC-3 block counts). Demuxed appends are independent; a stalled audio append would stall time entirely, not produce a steady 0.66x. The fact that 720p with the same audio plays at 1x argues against audio.

## 4. Experiments, ranked

1. **Check interlace/field coding (most likely packaging bug if present).** Broadcast "1080p59.94" is often 1080i with field pictures (PAFF), each field its own PES. We make every PES one sample (`onVideoAccessUnit`, iOS `~:700-752`, Android `:590-640`), so two fields become two MP4 samples, which ISO BMFF forbids. Parse SPS `frame_mbs_only_flag` and slice `field_pic_flag` in the remuxer log. Measure: decoded frames/s from `getVideoPlaybackQuality().totalVideoFrames` delta vs. sample count per segment. Fix if confirmed: merge the two field PES into one sample.
2. **Hardware ceiling test, no packaging change.** Cast a known clean 1080p60 H.264 High 4.2 fMP4 (e.g., a Shaka demo asset) to the same receiver page. Measure `currentTime` delta / wall delta over 30 s. If it is also ~0.66x, packaging is exonerated and the fix is a downscale/fps policy.
3. **Strip in-band SPS/PPS/AUD/SEI from samples** (keep them only in avcC; new init on change). Change the NAL loop in `onVideoAccessUnit` (both files). Measure rate and `droppedVideoFrames`; some hardware decoders reconfigure on every repeated SPS.
4. **Muxed TS via the MPL/HLS-TS path** (skip fMP4 entirely, serve the proxy's TS segments). Change the master playlist writer (Android `CastHlsProxyServer.kt:525-535`, iOS `CastHLSSegmentStore.swift`). Measure rate; if 1x, the regression is in our fMP4 or MSE path.
5. **Muxed single fMP4 with AAC audio** (transcode path already exists, `CastAudioTranscoder.swift`). Removes the two-SourceBuffer variable. Measure rate.
6. **2 s segments** (`targetSegmentTicks: 2 * ticksPerSecond` at iOS `CastHLSProxySession.swift:558`, Android `CastHlsProxySession.kt:486`). Measure rate and buffered-range length; expected no change, which itself rules out append-size effects.
7. **CODECS label `avc1.640029` (4.1) or honest `avc1.64002A`.** Master playlist writer (Android `CastHlsProxyServer.kt:507-525`). Measure rate; label only affects Shaka's choice of SourceBuffer, so low odds.

For every run, sample every 1 s over DevTools (http://192.168.50.40:9222): `v.currentTime`, `performance.now()`, `v.getVideoPlaybackQuality()` (total, dropped), `v.buffered` end minus currentTime, and log segment sample counts from the proxy. Pass criterion: rate >= 0.99 for 60 s with dropped < 1%.
