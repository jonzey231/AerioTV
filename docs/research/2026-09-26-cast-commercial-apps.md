# How commercial apps get 1080p60 / 4K onto Chromecast (2026-09-26)

Problem: our CAF web receiver (Shaka + MSE, demuxed fMP4 HLS from the phone) decodes 1080p59.94 H.264 at about 40 fps on a Chromecast Ultra.
Legend: [V] = verified from the cited page this session. [U] = unverified (search snippet, secondhand, or not found).

## Device decode ceilings (Google's own table)
Source: https://developers.google.com/cast/docs/media [V]
- Chromecast Ultra: H.264 High up to L4.2 (1080p60); HEVC Main/Main10 L5.1 (4K60); VP9 Profile 0/2 L5.1 (4K60); VP8 4K30.
- Chromecast with Google TV: H.264 up to L5.1 (4K30); HEVC L5.1 4K60; VP9 Profile 2 4K60.
- Google TV Streamer: H.264 up to L5.2 (4K60); HEVC 4K60; VP9 P2 4K60; AV1 L5.1 4K60.
- Chromecast 3rd gen: H.264 L4.2 (1080p60).
- "HEVC is not supported on Transport Stream containers." No web receiver or MSE frame-rate ceiling is documented on that page [V]; I found no Google statement of a separate web receiver decode ceiling [U].

## App table
| App | Device | Codec/container for 1080p60 / 4K | Delivery path | Source |
|---|---|---|---|---|
| YouTube | Ultra | VP9 for 4K (YouTube encodes 4K as VP9); H.264 1080p60 use on Ultra not documented | Google's own receiver | https://antmedia.io/vp9-codec/ [U, third party]; https://developers.google.com/cast/docs/media [V caps] |
| YouTube | Gen 1/2 Chromecast | 60 fps content stutters / capped at 720p60 | Web receiver | https://www.googlenestcommunity.com/t5/Streaming/1080p-60fps-YouTube-content-stutters-on-Gen-1-Chromecast/m-p/39192 [U]; https://xdaforums.com/t/60fps-on-chromecast-2015-for-youtube-videos.3216988/ [U] |
| YouTube TV | Ultra | Not published; no statement found that H.264 1080p60 is or is not used | Web receiver | not found [U] |
| Twitch | Ultra | H.264 1080p60 reported to play from the app's cast (not tab cast); older reports of 1080p60 stutter via third-party TwitchCast | Custom web receiver | https://community.nightdev.com/t/twitchcast-audio-studdering-at-1080p/9319 [U] |
| Any app (Cast Connect) | CCwGTV / Streamer | Native decoder via the Android TV app (ExoPlayer/MediaCodec) | Cast Connect: cast launches the installed Android TV app | https://developers.google.com/cast/docs/android_tv_receiver [V]; https://9to5google.com/2020/08/05/android-tv-cast-connect/ [V] |
| NFL+, FuboTV, Sling, Hulu Live, Peacock, ESPN, Paramount+, DirecTV Stream | Ultra / CCwGTV | No published 1080p60 codec detail found; all ship Android TV apps, so Cast Connect on Google TV devices is likely | Web receiver on Ultra; likely Cast Connect on Google TV | not found [U] |
| OTT Navigator | any Chromecast | Cannot cast MPEG-TS streams; FAQ tells users to use VLC to transcode TS to HLS | Default/stock receiver with the raw URL | https://ottnav.github.io/faq.html [U, snippet] |
| IPTV Smarters | any | Advertises Chromecast; format handling unpublished | Likely raw URL to Default Media Receiver | https://play.google.com/store/apps/details?id=com.poster.iptv.android [U] |
| TiviMate, Televizo, GSE, Kodi add-ons | any | No 1080p60 Chromecast evidence found | Unknown | not found [U] |
| Chromecast Ultra (system) | Ultra | Picks 1080p60 output if the TV cannot do 4K60 ("video smoothness") | HDMI output mode | https://support.google.com/chromecast/answer/7186055 [U, snippet] |

No Google issue tracker thread or Cast Debug Logger guidance about 60 fps H.264 through MSE on the Ultra was found [U].

## Conclusion
- Nothing we found shows a commercial app getting H.264 1080p60 through a custom MSE web receiver on the Ultra. On paper the hardware supports it (L4.2). In practice, 60 fps problems through web receivers show up again and again (YouTube Gen 1/2, TwitchCast).
- The big services avoid the web receiver's limits in two ways. (1) Codec: YouTube uses VP9 for high resolutions, which the Ultra decodes up to 4K60 [U for 1080p60 specifically]. (2) Cast Connect: on Google TV devices, casting hands off to the native Android TV app, which uses hardware MediaCodec [V mechanism].
- For 4K the table is plain: CCwGTV H.264 stops at 4K30, so 4K60 on it needs HEVC or VP9. The Streamer allows H.264 4K60 [V].

## Implications for AerioTV
1. Google TV devices (CCwGTV, Streamer): add Cast Connect to the existing Android TV app. Casting then launches the ExoPlayer app with hardware decode, and the web receiver is skipped entirely. This is the best-supported path.
2. Ultra, 1080p60: test without our Shaka pipeline first: pass the raw URL (TS or muxed HLS) to the stock or Styled Media Receiver's MPL and measure fps. If the Ultra drops frames on MSE either way, the fallbacks are 1080p30 or 720p60 for 60 fps sources, or a VP9 transcode (no transcode on the phone per the Android rule, so this is likely not viable).
3. 4K: HEVC works on all 4K devices but not in TS, so it needs fMP4. H.264 4K60 works only on the Streamer.
