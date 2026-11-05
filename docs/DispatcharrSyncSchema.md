# Dispatcharr Sync schema (v3)

Status: draft, not yet implemented on either platform.

Shared by AerioTV for Apple (iOS, iPadOS, tvOS) and AerioTV for Android.
This file must be byte-identical in both repos at `docs/DispatcharrSyncSchema.md`.
Any change bumps the affected key's `schemaVersion` and lands in both repos in the same day.
v3 (2026-10-18): ONE App Data key, `app.molinete.aerio`, holds every category (section 2), at the
request of Dispatcharr's maintainer, so AerioTV uses 1 of a user's 25 keys. v1 used 13 keys and v2
used three; both migrate (section 6.4). Payloads (section 4), caps, and merges are unchanged.
v3 note (2026-10-27): `profiles` rows gain position 9, `order` (section 4.12). Appended position,
so `schemaVersion` stays 3: older readers ignore it, and a row without it keeps insertion order.
v3 note (2026-10-27): `settings` gains the full allowlist (section 4.9, every setting iCloud or Drive
backs up), optional `tv` and `mobile` lanes beside `v`, and per-item scopes chosen in Sync
Categories. All optional, so `schemaVersion` stays 3: older readers read `v` and round-trip the rest.
v3 note (2026-10-29): new category `syncProviders` (section 10b): which sync providers the device
owner runs. A new category inside the key is not breaking (writers re-emit unknown categories, section
3), so `schemaVersion` stays 3; bumping it would make every older reader skip the whole key (reader
rule 2).

## 1. What it is

"Dispatcharr Sync" is a third sync provider next to iCloud (Apple) and Google Drive (Android).
It stores per-user AerioTV data in Dispatcharr's App Data API (Dispatcharr PR 1824), so an
iPhone, an Apple TV, an Android phone, and a Google TV signed in as the same Dispatcharr user
see the same favorites, progress, and reminders.

- Scope: one Dispatcharr server (playlist) and one Dispatcharr user. Each AerioTV profile is a
  Dispatcharr user and syncs under its own token through `users/me/app-data/`. The admin is just
  another user. A profile signing in alone on another device gets the same data.
- Only Dispatcharr playlists use this provider. Xtream Codes and M3U stay on iCloud or Drive.
- Playlist definitions and credentials are NEVER stored here (section 9).

### 1.1 Server facts this design depends on
| Fact | Value |
|---|---|
| Endpoints | `GET/PUT/DELETE /api/accounts/users/me/app-data/<key>/`, `GET /api/accounts/users/me/app-data/` (list keys and sizes) |
| Admin cross-user | `/api/accounts/users/<id>/app-data/<key>/` (user_level >= 10). AerioTV does not use it for writes in v1 |
| Key pattern | `^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$` |
| Limits | 25 keys per user, 128 KiB per key (compact UTF-8 JSON), 1 MiB total per user, depth 8 (Dispatcharr dev c1920131, 2026-10-18; one database row per key). Servers before that commit cap at 32 KiB per key and 128 KiB per user and answer 413 the same way |
| Value | Must be a JSON object. PUT replaces the whole value. No PATCH, no ETag, no versioning |
| Concurrency | Last writer wins (server serializes with a row lock) |
| Visibility | Any admin can view and clear any user's data in the web UI |
| Errors | `{detail, code}`: 400 key_invalid, value_not_object, value_has_nul, value_too_deep; 413 value_too_large, total_too_large, body_too_large; 409 max_apps; 403 forbidden; 404 key_not_found |

## 2. Keys

ONE App Data key, `app.molinete.aerio`, holds every category as a sub-object (section 3): settings,
profiles, reminders, watchlist, hiddenTitles, hiddenGroups, groupOrder, collections, remoteMap,
radioDefault, favorites, recents, progress, and syncProviders (section 10b). It is written with the profile's own token to
`users/me/app-data/app.molinete.aerio/`.

Categories (the "Key" column below is the v1 key name; in v2 the category name is the part after
`app.molinete.aerio.`, for example `hiddenTitles`):

| Key | Category | Synced? | Default | Why |
|---|---|---|---|---|
| `app.molinete.aerio.favorites` | Favorite channels, in order | Yes | On | Core cross-device data |
| `app.molinete.aerio.recents` | Recently watched channels | Yes | On | Small, useful on a new device |
| `app.molinete.aerio.progress` | VOD resume points (Continue Watching) | Yes | On | Core cross-device data |
| `app.molinete.aerio.reminders` | Program reminders | Yes | On | Each device schedules its own local notification or alarm |
| `app.molinete.aerio.watchlist` | My List (movies, series) | Yes | On | Android has it today; Apple adopts it |
| `app.molinete.aerio.hiddenTitles` | Hidden VOD titles | Yes | On | Same lane as My List on Android |
| `app.molinete.aerio.hiddenGroups` | Hidden channel, movie, and series groups | Yes | On | Per-user taste, server-agnostic names |
| `app.molinete.aerio.groupOrder` | Live TV group sort mode and manual order | Yes | On | Same |
| `app.molinete.aerio.settings` | Settings allowlist (section 4.9) | Yes | On | App-wide look and behavior only |
| `app.molinete.aerio.remoteMap` | TV remote button map | Yes | On | TV only reads and writes it; phones round-trip it |
| `app.molinete.aerio.radioDefault` | Radio Mode by Default | Yes | Off | Per-device listening choice unless the user opts in (matches iCloud default) |
| `app.molinete.aerio.collections` | Channel Collections (named channel sets shown as Live TV filter pills) | Yes | On | Exists on both platforms (Apple ChannelCollectionsStore in Features/Home/FavoritesStore.swift, Android `channel_collections` in AppPreferences); device-local today on both |
| `app.molinete.aerio.profiles` | Profile list (admin only) | Yes | On | Device pickers (section 5) |

Device-local, never synced here (nor through iCloud or Drive), and why:
- Kept Live / background Radio auto-start: tied to one device's power and network.
- Buffer size, network timeout, max retries, LAN URL, home SSID, background refresh schedule: per-device network.
- Display matching (Match Content Resolution, Match Frame Rate, Startup Refresh Rate), Surround Sound Passthrough, Auto-Rotate: per-device display and audio hardware.
- DVR storage cap, DVR storage folder, Keep Device Awake: per-device storage.
- Learned remote buttons: tied to one physical remote.
- Debug and developer options, update checks: per install.
- Playlist URLs and credentials: Drive and iCloud Keychain only, never Dispatcharr (section 10).
- TMDB API key: a secret; Drive stopped carrying it in cleartext on 2026-10-27 (section 10.2).
- The Drive Sync and Dispatcharr Sync switches, Sync Categories choices (`syncScope.<item>`, `syncItem.<item>`), and the active profile: per device by design.
- Channel profile selection: server-side state (admin assigns it per user).
- DVR recordings: server-side (Dispatcharr) or local files.
- EPG, logos, VOD catalog caches: rebuilt from the server.

Default Live TV view (List or Guide) syncs since 2026-10-27 (owner decision); a device that wants its
own form-factor default sets that item to its class lane or Off (section 4.9).

Per-item choices: every synced option is its own row in Settings > Sync > Sync Categories, shared by
Drive and Dispatcharr Sync. Settings rows take a scope (section 4.9 lanes); data rows (favorites,
recents, collections, progress, reminders, watchlist, hiddenTitles, hiddenGroups, groupOrder,
profiles, remoteMap, radioDefault) take a plain on/off. A data row that is off neither writes nor
applies its category. The old category toggles remain the defaults and the group-level All devices
and Off mapping, so an upgrade changes nothing until the user picks.

Budget: 1 key leaves 24 of 25 free for the user's other apps. New categories go inside the key, never
into new keys.

## 3. Envelope (every key) and category sub-objects

```json
{
  "schemaVersion": 3,
  "deviceId": "6F1C2A9E-4B7D-4C1E-9E1A-0D2B8C3F5A11",
  "platform": "ios",
  "appVersion": "1.8.44",
  "updatedAt": "2026-10-17T18:04:05Z",
  "categories": {
    "favorites": {"updatedAt": "2026-10-17T18:04:05Z", "deviceId": "6F1C...5A11", "data": {"ids": [1042, 77]}},
    "recents": {"updatedAt": "2026-10-17T17:50:00Z", "deviceId": "A2B9...0C44", "data": {"rows": [[1042, 1760724245]]}},
    "settings": {"updatedAt": "2026-10-17T18:04:05Z", "deviceId": "6F1C...5A11", "data": {"v": {"selectedTheme": "Midnight"}, "tv": {"textScale": 1.3}, "mobile": {"textScale": 1.0}}}
  }
}
```

The envelope fields describe the last write of the whole key. Each category is a sub-object under
`categories` with its own `updatedAt` (ISO 8601, same rule as below), `deviceId` (the device that last
wrote THAT category), `data` (section 4), and optional `extra`. Merge, round-trip, and caps apply per
category exactly as in v1 (section 6): the envelope fields of v1 map to the sub-object's
`updatedAt`/`deviceId`/`data`/`extra`.

A write of a key re-emits every category it holds: it reads the key first (section 7.4a), replaces
only the categories it rebuilt, and round-trips every other category (including ones this device has
not read, has turned off, or does not know) untouched.

| Field | Type | Rule |
|---|---|---|
| `schemaVersion` | int | 3 for the single-key layout (2 was the three-key layout, 1 one key per category). Bump only on a breaking change |
| `deviceId` | string | Random UUID generated once per install, stored locally, never tied to hardware ids |
| `platform` | string | `"ios"` (iPhone, iPad, Mac), `"tvos"`, `"android"` (phone, tablet, TV) |
| `appVersion` | string | Diagnostics only |
| `updatedAt` | string | ISO 8601 UTC, second precision, `Z` suffix |
| `categories` | object | Category name to sub-object (`updatedAt`, `deviceId`, `data`, optional `extra`) |
| `extra` (in a sub-object) | object, optional | Fields a newer writer added within the same `schemaVersion` (section 6.2) |

Reader rules:
1. Missing envelope fields or wrong types: ignore the key, log `[DSYNC] malformed <key>`, do not overwrite it. A sub-object missing `updatedAt` or `data` is ignored the same way, alone.
2. `schemaVersion` greater than the reader knows: ignore the key, log `[DSYNC] skip <key> v<n> > v<known>`, and do not write that key until the app updates (writing would downgrade it).
3. `schemaVersion` lower: upgrade in memory, write back at the current version on the next local change. Older builds read the v3 key as a higher `schemaVersion` and skip it (rule 2).

Encoding: compact JSON (no spaces), UTF-8, no NUL characters, max nesting depth 4 in practice.
Timestamps inside `data` are integer Unix seconds (UTC) to save bytes; only the envelope uses ISO 8601.

## 4. Payloads

IDs:
- Channel: Dispatcharr channel `id` (int). Not the UUID, not the channel number. favorites, recents,
  collections, and reminders all use it. Android keys channels locally as `"disp:<uuid>"` and
  translates them through its channel cache (the Dispatcharr channel id stored per cached channel)
  in both directions. A local key or a remote id it cannot translate (cache not built yet, channel
  gone) is never deleted: it is left out of the translation and kept as is on both sides. Apple
  follows the same rule.
- VOD: the Dispatcharr INTEGER primary keys (the `id` field `/api/vod/...` returns for movies,
  episodes, and series) as JSON ints in `vodId` and `seriesId` (Dispatcharr maintainer's request).
  Never the UUID. Apple must use the same integer ids. Each app maps them to whatever it keys local
  rows by (Android: movie and episode UUIDs locally, resolved through its VOD catalog and the series
  episode lists); a local row it cannot resolve yet stays on that device and is not written, and a
  pulled id it cannot resolve is skipped (never deleted on either side).
- Program: XMLTV programme id is not stable across EPG refreshes, so reminders key on `channelId` plus `start` (Unix seconds). That pair is the identity on both platforms.
- Group: group name (string), as the server sends it.
- Rows are compact arrays (positional). Position meanings are fixed per `schemaVersion`; new positions may only be appended (readers ignore extra trailing positions).

### 4.1 favorites (cap 1000)
```json
{"ids":[1042,77,903]}
```
`ids`: int[], in display order, no duplicates. Membership and order in one array.

### 4.2 recents (cap 50, newest first)
```json
{"rows":[[1042,1760724245],[77,1760720000]]}
```
Row: `[channelId:int, watchedAt:int]`.

### 4.3 progress (cap 300, newest `updatedAt` first)
```json
{"rows":[[8812,"e",1834,2640,1760724245,0,301,2,5,"The Pilot"]]}
```
Row positions:
| # | Field | Type | Notes |
|---|---|---|---|
| 0 | vodId | int | Dispatcharr movie id or episode id |
| 1 | type | string | `"m"` movie, `"e"` episode |
| 2 | position | int | seconds |
| 3 | duration | int | seconds, 0 if unknown |
| 4 | updatedAt | int | Unix seconds |
| 5 | finished | int | 0 or 1 |
| 6 | seriesId | int or null | Dispatcharr series id; null for movies |
| 7 | season | int | 0 if unknown or movie |
| 8 | episode | int | 0 if unknown or movie |
| 9 | title | string | max 40 UTF-8 bytes, truncated on a character boundary |

Poster URLs and stream URLs are NOT synced: readers resolve them from the VOD catalog by id.
Finished entries older than 30 days are dropped before the cap is applied.

### 4.4 reminders (future only, cap 200)
```json
{"rows":[[1042,1760731200,1760734800,"Monday Night Football","ESPN"]]}
```
Row: `[channelId:int, start:int, end:int, title:string(max 60 B), channelName:string(max 40 B)]`.
Writers drop rows whose `end` is in the past.
Channel rule (both platforms): write `channelId` when the local reminder knows it. Android today
resolves it from the reminder's channel name through the channel cache; a local reminder whose
channel cannot be resolved is not written. On read, a row whose `channelId` does not resolve to a
local channel is kept in the payload (re-emitted on the next write) but not scheduled. Readers schedule a local notification (Apple) or
alarm (Android) 5 minutes before `start`, and cancel local reminders absent from the payload.

### 4.5 watchlist (cap 500, newest first)
```json
{"rows":[[5531,"m",1760700000],[301,"s",1760600000]]}
```
Row: `[vodId:int, type:"m"|"s", addedAt:int]` (movie id or series id). Removal = absence (full replace replaces Android's
`removedAt` tombstones; see 6.3). Rows carry no title: the app fills title, poster, year, and rating
from the VOD catalog by `vodId`.

### 4.6 hiddenTitles (cap 500)
```json
{"rows":[[5531,"m",1760700000]]}
```
Row: `[vodId:int, type:"m"|"s", hiddenAt:int]`.

### 4.7 hiddenGroups
```json
{"live":["Adult","Spanish"],"movies":[],"series":["Kids"]}
```
string[] each, cap 500 names each.

### 4.8 groupOrder
```json
{"mode":"manual","order":["Sports","News","Movies"]}
```
`mode`: `"default"`, `"alphabetical"`, or `"manual"`. `order`: string[], cap 500, used when manual.

### 4.9 settings
```json
{"v":{"selectedTheme":"Midnight","appearanceMode":"dark","trueBlack":true},"tv":{"textScale":1.3},"mobile":{"textScale":1.0}}
```
`v`, `tv`, `mobile`: maps of schema name to bool, int, double, or string. Only names in this
allowlist are written; `tv` and `mobile` are optional, and unknown lanes round-trip.

Lanes and scopes. Each Sync Categories row has a per-device scope (`syncScope.<item>`, device-local,
never synced itself):
1. A device offers only its own class. A TV shows All devices, TVs only, and Off; a phone or tablet
   shows All devices, Phones and tablets only, and Off. A stored scope for the other class (for example
   after a restore onto a different device class) is treated as All devices.
2. A device writes only to `v` or its own class lane (`tv` on a TV, `mobile` on a phone or tablet),
   and reads only `v` or its own class lane.
3. All devices writes and reads `v`. TVs only / Phones and tablets only writes and reads the class
   lane. Changing an item from All devices to the class lane seeds the class lane from the CURRENT
   LOCAL value on the next push, and from then on that device ignores `v` for the item; changing back
   to All devices pushes the local value to `v`.
4. Precedence is scope only: no merging across lanes, and no fallback from the class lane to `v` or
   back. A name missing from the lane this device reads is simply not applied.
5. Off writes nothing and reads nothing; the value already stored in any lane is left untouched.
6. A group row (for example Appearance) shows the same class-filtered choices, reads "Mixed" when
   its items differ, and picking a value sets every item in the group.
7. Names a device does not write (other items, other lanes, other platforms' names) round-trip (6.2).
The Drive preferences snapshot carries the same lanes (`keys` is `v`, plus `tv` and `mobile`) with the
same rules.

Allowlist. Item = the Sync Categories row (same ids and labels on both platforms). Dispatcharr names
are canonical; the Drive column lists Drive's wire name where it differs (kept for backward
compatibility):

| Schema name | Type | Item | Apple key | Android key | Drive name |
|---|---|---|---|---|---|
| selectedTheme | string | selectedTheme | selectedTheme | selected_theme | |
| customThemeHex | string | selectedTheme | customThemeHex | custom_theme_hex | |
| appearanceMode | string | appearanceMode | appearanceMode | appearance_mode | |
| trueBlack | bool | trueBlack | appearance.trueBlack | appearance_true_black | appearanceTrueBlack |
| useCustomAccent | bool | customAccent | useCustomAccent | use_custom_accent | |
| customAccentHex | string | customAccent | customAccentHex | custom_accent_hex | |
| liquidGlassStyle | string | glassEffect | liquidGlassStyle | (Apple only: round-trip) | |
| textScale, subtextScale, textContrast | double | textScale, subtextScale, textContrast | TextScale.key, SubtextScale.key, TextContrast.key | text_scale, subtext_scale, text_contrast | |
| timeFormat | string | timeFormat | ClockFormat.defaultsKey | ui_time_format | |
| defaultTab | string | defaultTab | defaultTab | default_tab | |
| skipLoadingScreen | bool | skipLoadingScreen | appBehaviorsSkipLoadingScreen | app_behaviors_skip_loading_screen | |
| autoResumeLastChannel | bool | resumeLastChannel | appBehaviorsAutoResumeLastChannel | app_behaviors_auto_resume_last_channel | |
| defaultLiveTvView | string | defaultLiveTVView | defaultLiveTVView | default_live_tv_view | |
| guideLayout | string | guideLayout | liveTVLayout | live_tv_layout | |
| guideGroupSelector, phoneGroupSelector, guideSidebarLayout | string | groupSelection | RemoteControlStore keys, phoneGroupSelector | guide_group_selector, phone_group_selector, guide_sidebar_layout | |
| liveTvEdgeSwipeOpensSidebar | bool | edgeSwipeSidebar | liveTVEdgeSwipeOpensSidebar | live_tv_edge_swipe_opens_sidebar | |
| channelListShowLogos, channelListShowNumbers, channelListShowNames, channelListShowProgramSubtitles | bool | showChannelLogos, showChannelNumbers, showChannelNames, showProgramSubtitles | ui.showChannelLogos, ui.showChannelNumbers, ui.showChannelNames, ui.showProgramSubtitles | ui_show_channel_logos, ui_show_channel_numbers, ui_show_channel_names, ui_show_program_subtitles | |
| channelLogoSize | int | logoSize | ui.channelLogoSize | ui_channel_logo_size_tenths | |
| showEpgBadgesTv, showEpgBadgesMobile | bool | programBadges | showEpgBadges.tv, showEpgBadges.mobile | ui_show_epg_badges_tv, ui_show_epg_badges_mobile | |
| hiddenEpgBadges | string | programBadges | ui.hiddenEpgBadges | ui_hidden_epg_badges | |
| guideProgramInfoButton | string | programInfoButton | guideProgramInfoButton | guideProgramInfoButton | |
| programInfoButtonGuide, programInfoButtonList | bool | programInfoButton | guideProgramInfoButtonGuideView, guideProgramInfoButtonListView | programInfoButtonGuide, programInfoButtonList | |
| logoCornersGuide | bool | roundedGuideLogos | LogoCorners.guideKey | ui_rounded_artwork_guide | |
| logoCornersGuideCells | bool | roundedProgramCells | LogoCorners.guideCellsKey | guide_rounded_program_cells | |
| logoCornersList | bool | roundedListLogos | LogoCorners.listKey | ui_rounded_artwork | |
| displayScaleLiveTv, displayScaleGuide | double | liveTVDisplayScale | listScale, guideScale | display_scale_live_tv, guide_scale | |
| enableCategoryColors | bool | categoryColors | enableCategoryColors | category master key | |
| categoryColor.<bucket> | string | categoryColors | categoryColor.<bucket> | categoryColor.<bucket> | |
| categoryBucketEnabled.<bucket> | bool | categoryColors | categoryBucketEnabled.<bucket> | categoryBucketEnabled.<bucket> | |
| customCategories | string (JSON, max 4 KiB) | categoryColors | CategoryColor.customCategoriesKey | category custom JSON key | customCategoryColors.v1 |
| tintChannelCards | bool | tintChannelCards | tintChannelCards | (Apple only: round-trip) | |
| playerInfoCard.showOnChannelChange | bool | infoCard | playerShowChannelInfoCard | playerShowChannelInfoCard | playerShowChannelInfoCard |
| playerInfoCard.channelLogo, .channelName, .programName, .programTime, .programSubtitle, .programDescription | bool | infoCard | playerInfoCardChannelLogo (and siblings) | player_card_show_channel_logo (and siblings) | |
| liveRewindEnabled, liveRewindKeepRecent | bool | liveRewind | liveRewindEnabled, liveRewindRetainChannels | live_rewind_enabled, live_rewind_keep_recent | |
| liveRewindDepthMinutes, liveRewindKeepCount | int | liveRewind | liveRewindDepthMinutes, liveRewindRetainCount | live_rewind_depth_minutes, live_rewind_keep_count | |
| liveRewindRetentionHours, liveRewindBudgetGb | int | liveRewind | (Android only) | live_rewind_retention_hours, live_rewind_budget_gb | |
| skipBack, skipForward | int | skipIntervals | skipBackSeconds, skipForwardSeconds | skip_back_seconds, skip_forward_seconds | skipBackSeconds, skipForwardSeconds |
| skipWithoutControls | bool | skipWithoutControls | player.skipWithoutControls | skip_without_controls | |
| autoRecoverFrozenStreams | bool | autoRecover | appBehaviorsAutoRecoverFrozenStreams | app_behaviors_auto_recover_frozen_streams | |
| appleTVChannelFlip | bool | channelFlip | appBehaviorsAppleTVChannelFlip | app_behaviors_apple_tv_channel_flip | |
| edgeBrightnessGesture, brightnessEdge | bool, string | edgeBrightness | appBehaviorsEdgeBrightnessGesture, appBehaviorsBrightnessEdge | in_player_gesture_brightness, in_player_gesture_brightness_edge | |
| edgeVolumeGesture | bool | edgeVolume | appBehaviorsEdgeVolumeGesture | in_player_gesture_volume | |
| multiview.audioFocusStyle | string | multiviewAudioFocus | multiviewAudioFocusStyle | multiview_audio_focus_style | |
| multiview.tilePadding | bool | multiviewPadding | multiviewTilePadding | multiview_tile_padding | |
| multiview.tileCornersRounded | bool | multiviewCorners | multiviewTileCornersRounded | multiview_tile_corners_rounded | |
| multiview.showLogos, multiview.logoPosition, multiview.logoSize | bool, string, int | multiviewLogos | multiview.showLogos, multiview.logoPosition, multiview.logoSize | multiview_show_logos, multiview_logo_position, multiview_logo_size | |
| multiview.pickerShowSubtitles, multiview.pickerShowDescriptions | bool | multiviewSubtitles, multiviewDescriptions | multiviewPickerShowSubtitles, multiviewPickerShowDescriptions | multiview_picker_show_subtitles, multiview_picker_show_descriptions | |
| vodLibraryRefreshHours | int | refreshLibrary | vodLibraryRefreshHours | vod_library_refresh_hours | |
| tmdbPostersEnabled | bool | tmdb | TMDBPosters.enabledDefaultsKey | app_behaviors_program_posters_tmdb_enabled | programPostersTmdbEnabled |
| displayScaleMovies | double | vodDisplayScale | uiScale | display_scale_movies | |
| moviesSortOrder, seriesSortOrder | string | vodSortOrder | moviesSortOrder, seriesSortOrder | movies_sort_order, series_sort_order | |
| dvrPreRollMins, dvrPostRollMins | int | preRoll, postRoll | dvrDefaultPreRollMins, dvrDefaultPostRollMins | dvr_default_pre_roll_mins, dvr_default_post_roll_mins | |
| dvrDefaultDestination | string | defaultDestination | (Android only) | dvr_default_destination | |
| dvrSortOrder | string | dvrSortOrder | dvrSortOrder | dvr_sort_order | |
| showRemoteHints | bool | remoteHints | showRemoteHintsKey | show_remote_hints | |
| exitDialogFocusExit | bool | exitFocus | (Android only) | exit_dialog_focus_exit | |
| guideTuneInMini | bool | playChannelsIn | RemoteControlStore.tuneInMiniKey | guide_tune_in_mini | |
| defaultGroup | string | groupOrder | defaultChannelGroup | default_group_token_<playlistId> | defaultGroup (JSON object, playlist id to token) |
| lastGroup | string | groupOrder | (Android only) | live_group_token_<playlistId> | lastGroup (JSON object) |
| recentGroupVisible | bool | groupOrder | (Android only) | recent_group_visible_<playlistId> | recentGroupVisible (JSON object) |

`defaultChannelGroup` (Apple's key) and `defaultGroup` are one setting; the schema name is
`defaultGroup`. The three per-playlist names carry the session's playlist only on Dispatcharr (its data
is already per profile and per playlist) and follow the Group Order data row, not a scope.

Values (Apple maps to exactly these strings and numbers). On read, an unknown value or a value of the
wrong type is ignored and the local setting is left unchanged:
| Schema name | Values |
|---|---|
| selectedTheme | `"Aerio"`, `"Midnight"`, `"Sunset"`, `"Forest"`, `"Lavender"`, `"Monochrome"`, `"Light"`, `"Custom"` (Android AppTheme enum names, case sensitive) |
| appearanceMode | `"dark"` (default), `"light"`, `"system"` |
| defaultTab | `"LiveTV"`, `"DVR"`, `"Movies"`, `"TVShows"`, `"Settings"` (Android AppTab enum names); absent or `""` = Live TV |
| timeFormat | `"system"` (default), `"12"`, `"24"` |
| textScale, subtextScale, displayScaleLiveTv, displayScaleMovies | number 0.85 to 1.50, default 1.0; text scales snap to 0.05 steps |
| displayScaleGuide | number 0.5 to 2.0, default 1.0 |
| textContrast | number 0.0 to 1.0 in 0.1 steps, default 0.0; readers clamp and snap |
| guideProgramInfoButton | `"off"`, `"current"`, `"all"` |
| guideGroupSelector | `"pills"`, `"sidebar"` |
| phoneGroupSelector | `"sidebar"` (default), `"pills"` |
| guideSidebarLayout | `"overlay"` (default), `"shift"` |
| guideLayout | `"basic"` (default), `"preview"` |
| defaultLiveTvView | the Android wire value as stored, up to 20 characters; `""` = the device's form-factor default |
| customAccentHex, categoryColor.<bucket> | `"RRGGBB"` hex, an optional leading `#` accepted; customAccentHex `""` = the theme's accent |
| customThemeHex | `"RRGGBB"` hex, an optional leading `#` accepted; the Custom theme's base color (the whole Custom palette and its matching accent derive from it) |
| appearanceMode, trueBlack | Unchanged on the wire. Since 2026-11-05 the UI shows one Mode choice (System, Light, Dark, True Black): True Black is written as appearanceMode `"dark"` plus trueBlack `true`, and every other choice writes trueBlack `false`. Readers honor trueBlack only with `"dark"`, so a received System or Light with trueBlack `true` renders as plain System or Light |
| hiddenEpgBadges | one string, badge ids separated by commas (no spaces), up to 1024 characters; `""` = none hidden |
| customCategories | JSON array string, up to 4 KiB |
| skipBack, skipForward | int seconds, one of 5, 10, 15, 30, 60 |
| channelLogoSize | int 25 to 250 (Android tenths, 100 = default size) |
| dvrPreRollMins, dvrPostRollMins | int minutes 0 to 240 |
| dvrDefaultDestination | `"server"` (default), `"local"` |
| vodLibraryRefreshHours | int hours 0 to 720 |
| liveRewindDepthMinutes | int minutes 1 to 1440 |
| liveRewindKeepCount | int 1 to 5 |
| liveRewindRetentionHours | int 1 to 720 |
| liveRewindBudgetGb | int 1 to 500 |
| brightnessEdge | `"left"` (default), `"right"` |
| multiview.logoSize | int 5 to 25 |
| moviesSortOrder, seriesSortOrder, dvrSortOrder, multiview.audioFocusStyle, multiview.logoPosition | the Android wire value, up to 40 characters; an unknown value falls back to the default |
| defaultGroup, lastGroup | the active playlist's group token exactly as stored, any string up to 200 characters; `""` = none. An unknown group is stored as is and the launch falls back |
| every bool row | JSON `true` or `false`, never a string |

Excluded from settings (own keys or device-local, section 2): `remoteControlMap`, `radioModeByDefault`,
`favoriteChannelIDs`, `favoriteOrder`, `channelGroupOrder*`, `hiddenChannelGroups` and siblings,
`streamBufferSize`, `networkTimeout`, `maxRetries`, `bgRefresh*`, display matching, passthrough, DVR
storage, learned remote buttons, debug and update options, `tmdbApiKey`, `preferAVPlayer`.
Parity rule: an "(Apple only)" or "(Android only)" row is a parity gap to close, not a design choice;
until closed, the other platform round-trips it (6.2).

Settings are per profile on both platforms: a pulled `settings` applies to the profile whose token
made the request, never to another profile on the device.

### 4.10 remoteMap
```json
{"tv":{"version":1,"preset":"custom","guideKeys":2,"player":{"okShort":"toggleControls","upLong":"recentChannels"},"guide":{"ffwd":"pageDown","okLong":"programMenu"}}}
```
`tv` is a nested object, exactly the Android RemoteControlMap JSON (core/remote/RemoteControlMap.kt):
| Field | Type | Values |
|---|---|---|
| version | int | 1 |
| preset | string | `"default"` (track the app's standard scheme; stored slots are ignored) or `"custom"` (slots are authoritative). Any other preset discards the map |
| guideKeys | int | 2. Marks a map written after the guide Select, Left, and Right slots became honored; absent means an older map that the reader migrates |
| player | object | slot name to player action name |
| guide | object | slot name to guide action name |

Slot names: `okShort`, `okLong`, `upShort`, `upLong`, `downShort`, `downLong`, `leftShort`,
`leftLong`, `rightShort`, `rightLong`, `playPause`, `ffwd`, `rewind`, `channelUp`, `channelDown`,
`backShort`, `backLong` (the two Back slots are guide only; a reader drops them from `player`).

Player actions: `channelUp`, `channelDown`, `lastChannel`, `recentChannels`, `toggleControls`,
`showProgramInfo`, `optionsMenu`, `playPause`, `seekForward`, `seekBackward`, `restartProgram`,
`jumpToLive`, `minimizeToGuide`, `channelList`, `subtitles`, `audioTracks`, `aspectRatio`, `record`,
`sleepTimer`, `openSearch`, `stopPlayback`, `none`.

Guide actions: `pageUp`, `pageDown`, `timelineBack`, `timelineForward`, `jumpToNow`, `jumpToTop`,
`jumpToDay`, `focusGroupPills`, `resumePlayer`, `closeMiniPlayer`, `programInfo`, `openSearch`,
`programMenu`, `play`, `record`, `navigate`, `backLadder`, `none`.

Readers ignore unknown slots and actions; a missing slot falls back to the app default at resolve
time; `none` is an explicit unassigned slot. When a press repeats inside one context, the first
value wins. Apple writes and reads this same shape. Phones and tablets never edit it and round-trip
it untouched.

### 4.11 radioDefault
```json
{"on":false}
```

### 4.11a collections (cap 50 collections, 500 members each)
```json
{"rows":[["3F2A9C1E-7B44-4D0A-9A61-2C5E8F1B7D30","Sunday Football","b",[1042,77,903]]]}
```
Row: `[id:string, name:string(max 40 B), placement:"b"|"e", members:int[]]`, rows in display order.
- `id`: the collection's existing UUID string (both platforms already generate one); keeps identity across renames.
- `placement`: `"b"` = beginning, `"e"` = end of the group pills (both platforms' `placement`).
- `members`: Dispatcharr channel ids in collection order. Stale ids (channel gone) stay, as both stores keep them today.
- The active collection filter (`selectedGroup` = `collection:<id>`) is device-local and not synced.

### 4.12 profiles (admin user only)
Written only by a device signed in as the admin profile, under the admin's own `me` key.
```json
{"rows":[[1,"admin","Logan","none","","","admin",1760724245,{},0],[7,"test1","Kids","directions","9f2c...64hex","b81e...32hex","child",1760730000,{"icon":"paw","color":"orange"},1]],"removed":[["test2",1760800000,8]]}
```
Row: `[userId:int, username:string, displayName:string(max 40 B), pinType:"none"|"numbers"|"directions", pinHash:string, pinSalt:string, role:"admin"|"user"|"child", updatedAt:int, avatar:object, order:int]`, cap 25 rows.
- `updatedAt` = Unix seconds of the last change to that row's displayName, PIN, role, avatar, or
  order on the writing device. Absent (older writer) reads as 0.
- `order` = the profile's list position, 0 first, set by an Admin (picker Move Left, Move Right,
  and Move to Front; Settings Move Up and Move Down). Every list of profiles (pickers, switcher,
  Settings) uses it; the default profile moves like any other. Absent (older writer) = keep the
  local position; a profile never moved sorts after moved ones in insertion order (default first).
  A move stamps `updatedAt` on every row whose position changed, and the per-row merge applies it.
- `avatar` = `{"icon":string, "color":string}`, either member optional; `{}` = the default. App
  defined (Dispatcharr's `avatar_config` has no defined shape, the web UI ignores it, and
  `PATCH /api/accounts/users/me/` drops it, so it is not used).
  - `icon`: `person`, `face`, `child`, `paw`, `cat`, `fish`, `star`, `rocket`, `music`, `soccer`,
    `gamepad`, `movie`. Absent or unknown = the display name's first letter.
  - `color`: `teal` #1AC4D8, `blue` #3B82F6, `orange` #FB923C, `ember` #C2410C, `green` #22C55E,
    `purple` #8B5CF6, `slate` #94A3B8, `sea` #2B7A86 (theme palette). Absent or unknown = the
    default: index (sum of the lowercased username's character codes) mod 8 in this order.
  - Position absent (older writer) = keep the local avatar. Admin edits any profile's avatar; a
    User or Child edits its own.
- `removed` (optional; absent = none) = removal tombstones: `[username:string (lowercased),
  removedAt:int (Unix seconds), userId:int (optional)]`, one per username. A removal stamps a local
  tombstone and the next write adds it to `removed`. Every writer carries the union of the server
  `removed` list and its local stamps (newest `removedAt` per username) and drops a tombstone 90
  days after its `removedAt`. Tombstones live in the payload because a device-local stamp cannot
  stop a third device with a stale roster from writing the row back.
- Tombstone rule, on every pull and on the read-merge before every write: a row (server or local)
  whose username has a tombstone with `removedAt >= updatedAt` is removed. A server row is dropped;
  a local profile is deleted with the same local cleanup as a user remove (no PIN prompt, no new
  tombstone) and is never re-sent. A row edited after the tombstone (`updatedAt > removedAt`) wins:
  it stays and the tombstone leaves `removed` (an intentional re-add). The default profile is never
  removed. The local stamp is a cache for the window with no session; it clears once a write that
  carries it in `removed` gets a 200 (or the server copy already carries it), a newer row
  supersedes it, or it expires.
- Merge is PER ROW, not last writer wins for the whole key: on every pull, a pulled row replaces the
  local displayName, role, avatar, order, pinType, pinHash, and pinSalt only when its `updatedAt` is newer than the
  local row's; otherwise the local row stays and goes back up on the next write. A writer keeps
  rows it does not have locally unless a tombstone covers them.
- Name and avatar claim: only an explicit local rename or avatar change claims displayName and
  avatar, so a profile created by onboarding, a QR login, or any other path that never customized
  them takes the server row's displayName and avatar on the next pull whatever the stamps say (logs
  `[DSYNC] profiles: adopted synced name/avatar for <user>`), and its writes keep the server's
  values; with no server row it keeps its username as the display name.
- Catalog semantics: the rows are the profiles AVAILABLE to devices, not a mandate. A pull never
  creates a local profile. Metadata (displayName, role, avatar, order, PIN) merges only into
  profiles already present on the device; rows for users with no local profile are offered as
  suggestions under "From your other devices" (onboarding Add Profiles step, after the Dispatcharr
  Sync step has pulled, and Settings > Playlists > (playlist) > Add Profile) and are added only by
  an explicit choice on that device. Adding one uses the normal credential path (admin-listed
  `api_key`, else a typed password or API key) and then applies the row's role, PIN, avatar,
  displayName, and order. A Child row needs every Admin and Standard profile on the device to hold a PIN first. Tombstones apply on
  every device. Each pull logs `[DSYNC] profiles: N roster rows available, not added (opt-in)`.
- Stale-device rule: a writer does not send a local row the server list lacks when that row has no
  unsent local change (its `updatedAt` is at or before this device's last acknowledged write) and
  either its `updatedAt` is older than the server `profiles` sub-object's `updatedAt`, or every local
  row is older than the server's newest row by more than the 90-day tombstone window. The writer
  logs `[DSYNC] profiles: local row <user> older than server roster, not re-sent` and adopts the
  server list; the local profile stays on that device until a tombstone or the user removes it.
- `role` is the app-local role and follows the user's Dispatcharr access (owner rule 2026-10-29): a Dispatcharr admin (superuser, staff, or user_level 10) is always `"admin"` and is never offered a role picker; any other user is `"user"` (shown as Standard) or `"child"`, chosen by an Admin or Standard profile, and is never offered Admin. When a refresh of `/api/accounts/users/me/` reports a changed level the role follows it (demotion: Admin to Standard; promotion: Standard or Child to Admin) and logs `[PROFILES] server role changed for <username>: <old> -> <new>`. Inside AerioTV `admin` and `user` (shown as Standard) are identical (owner rule 2026-10-29): the label only reflects the user's Dispatcharr access, and both can add, remove, and reorder profiles, change roles, reset other profiles' PINs, and write this key. Only actions that call Dispatcharr admin endpoints (Channel Profiles, Enable API access, the server users list) check the server admin flag. `child` hides the switcher, the Profiles section, and every other profile name; leaving a child profile needs a PIN from an Admin or Standard profile.
- While any profile is a Child, every Admin and Standard profile holds a PIN (Numbers or Directions): setting a role to Child first walks the acting profile through each missing PIN (its own first, then a temporary PIN per other profile); an Admin or Standard profile added while a Child exists sets its PIN right after the add (cancel undoes the add); removing such a PIN is denied ("While a Child profile exists, Admin and Standard profiles keep a PIN."), and a reset sets a temporary PIN instead of clearing it.
- `pinHash` = lowercase hex SHA-256 of `pinSalt bytes || UTF-8 PIN` where the PIN is digits for
  numbers and the letters `U D L R` for directions (example `"UULR"`). Empty when `pinType` is `"none"`.
- `pinSalt` = 16 random bytes from the platform CSPRNG, lowercase hex, regenerated on every PIN set
  or change, unique per user.
- Non-admin devices never read this key (they cannot reach it through `me`). A profile signed in
  alone has no picker and no PIN prompt for itself on that device.
- Device Admin PIN (device-local, never synced, not in this key): when onboarding signs in as a
  Standard Dispatcharr user, "Who is this profile for?" offers Standard (default; wire value `user`) or Child. Child sets a
  Device Admin PIN (Numbers or Directions) tied to no profile, and the profile becomes a Child: a
  kid-only device. Every "Enter a PIN from an Admin or Standard profile" gate (leaving a Child, Manage Profiles, Add Profile,
  role changes, removing a Child) accepts the Device Admin PIN as well as any Admin or Standard profile's PIN,
  and it stays valid after an Admin profile is added. It is changed or removed in Settings >
  Playlists > Profiles (Admin and Standard profiles) or Manage Profiles behind the PIN, both needing the current
  Device Admin PIN; it stays while any profile is a Child and no Admin or Standard profile has a PIN.

## 5. Profiles flow

1. Admin device: lists server users, adds profiles, writes `profiles` under the admin.
2. A second device signed in as the admin pulls `profiles` and offers its rows as suggestions;
   for each one the user picks, it reads the admin user list (`GET /api/accounts/users/`, which
   returns each user's `api_key`) and adds that profile without typing anything. Nothing is added
   without a choice. Only a device signed in as a non-admin user needs that user's password
   or API key typed. Credentials are still never written to App Data.
3. Each profile's own data lives under its own user. The device switches tokens on profile switch.
4. Wrong-PIN backoff (5 tries, then 30 s doubling) is device-local state and is not synced.

## 6. Merge, round-trip, and versioning

### 6.1 Merge rule
Last writer wins per key, by envelope `updatedAt`. On pull, if remote `updatedAt` is newer than the
local copy's last-applied `updatedAt`, apply remote as a full replace of that category. Ties: higher
`deviceId` string wins (deterministic). No field-level merge in v1.

Exception, progress and recents: before writing, merge local rows with the last pulled remote rows
by id, keep the newer row per id (row `updatedAt` or `watchedAt`), then apply caps. This keeps two
devices watching different titles from erasing each other.

### 6.2 Round-trip (PUT is a full replace)
Each platform stores the raw last-pulled JSON for every key and, on write:
1. Starts from that raw object.
2. Replaces only the fields it owns (the `data` members and rows this document defines and it supports).
3. Re-emits untouched: unknown top-level `data` members, unknown settings names in `settings.v`,
   trailing row positions it does not know, the whole `remoteMap` on phones, and the envelope `extra`.
Settings rows it does not support (for example Android today for `categoryColor.*`) are therefore
preserved byte for byte.

### 6.4 Migration from v1 and v2
On the first v3 session, if any other `app.molinete.aerio.*` key exists (the 13 v1 keys, or the v2
`app.molinete.aerio.favorites` and `app.molinete.aerio.progress` keys) or `app.molinete.aerio` still
holds a v2 value, the app reads all of them and merges PER CATEGORY by `updatedAt` (ties: higher
`deviceId`) into the single key; each category keeps its `updatedAt`, `deviceId`, `data`, and
`extra`. It PUTs the single key, then DELETEs every other `app.molinete.aerio.*` key. Log
`[DSYNC] migrated to the single key (N keys removed)`. If the PUT fails, the old keys stay and
migration runs again on the next pull.

### 6.3 Removals
Removal is absence from the array. There are no tombstones in v1. Android's local `removedAt` and
`unhiddenAt` fields stay local.

## 7. Cadence and errors

1. Pull all enabled categories: on launch, on profile switch, on return to foreground after 5 minutes or more, and every 15 minutes while foregrounded. One `GET users/me/app-data/` lists sizes first; then one GET of `app.molinete.aerio` when present. A category absent from the key counts as read (empty).
2. Never write a key not read since launch (or since profile switch). A 404 `key_not_found` counts as read (empty).
3. Debounce writes: 5 s after the last local change per key; flush pending writes on background.
4. Skip a PUT whose compact JSON equals the last pushed body.
4a. Every PUT first GETs the key: row categories (favorites, recents, progress, collections, reminders) merge the server rows into local state, whole-value categories keep the newer side, and all other categories are re-emitted at their server value. An unsent local change is never overwritten by a pull without that merge.
5. No app-side byte guard: the full value is sent. On 413 (`value_too_large`, `body_too_large`, or `total_too_large`), apply the next trim step of section 8 (one step per retry, log each) and PUT again. After the last step still fails, stop writing until the next local change and show "Sync data too large" on the Dispatcharr Sync row in Settings.
6. 409 `max_apps`: do not create new keys; show "Sync storage on the server is full". Existing keys keep syncing.
7. 401 or 403: refresh the token per existing login flow; if it still fails, pause Dispatcharr Sync for that profile and show "Sign in again to sync".
8. 5xx or network errors: retry with backoff 30 s, 2 min, 10 min; keep the pending write.
9. Log with prefix `[DSYNC]` (key, bytes, status). Never log values, PIN hashes, or salts.

## 8. Size budget (heavy user)

Heavy user: 600 favorites, 10 collections of 40 channels, 300 progress entries, 100 reminders, 50 recents, 200 My List, 50 hidden
titles, 40 hidden groups, 60 ordered groups, 6 profiles. One envelope about 160 B, about 90 B per
category sub-object (13 x 90 B = 1.2 KB).

| Key | Contents | Total |
|---|---|---|
| `app.molinete.aerio` | every category below plus sub-objects | about 60 KB (worst case about 63 KB) |

The server's per-key limit is 128 KiB (1 MiB per user) since Dispatcharr dev c1920131, so the heavy
user above fits with room to spare. On an older server (32 KiB per key, 128 KiB per user) a large value
gets a 413 and the trim order below runs one step per retry; the client never assumes the new caps.

Per-category estimates (unchanged from v1):

| Category | Row estimate | Total | Alone under 32 KiB (old cap) |
|---|---|---|---|
| favorites | 600 x 5 B (4-digit id plus comma) | 3.2 KB | Yes |
| recents | 50 x 19 B | 1.1 KB | Yes |
| progress | 300 x 75 B (integer ids, ints, 30 B title) | 22.5 KB | Yes |
| progress worst case | 300 x 85 B (40 B titles, 7-digit ids) | 25.5 KB | Yes |
| reminders | 100 x 95 B | 9.7 KB | Yes |
| watchlist | 200 x 16 B | 3.2 KB | Yes |
| hiddenTitles | 50 x 16 B | 0.8 KB | Yes |
| hiddenGroups | 40 x 14 B | 0.7 KB | Yes |
| groupOrder | 60 x 14 B | 1.0 KB | Yes |
| settings | about 110 names x 35 B in `v`, up to 40 names in each of `tv` and `mobile`, plus customCategories up to 4 KiB | 10.7 KB | Yes |
| remoteMap | about 20 entries | 0.8 KB | Yes |
| radioDefault | | 0.2 KB | Yes |
| profiles | 6 x 130 B rows plus up to 25 x 30 B `removed` tombstones | 1.8 KB | Yes |
| collections | 10 collections x (60 B header + 40 members x 5 B) | 2.8 KB | Yes |
| Total | | about 59 KB (worst case about 62 KB) | Under 128 KiB (new per-key cap) |

Trim order on a 413, one step per retry (no trimming before the first PUT):
1. progress: oldest rows down to 200, then down to 100.
2. recents: down to 25.
3. watchlist and hiddenTitles: oldest first down to 300 each, then down to 150 each.
4. favorites: down to 500 (from the end of the list).
Reminders, settings, collections, hiddenGroups, groupOrder, profiles, remoteMap, and radioDefault are
never trimmed. After the last step still fails: "Sync data too large".

## 9. Security

- Nothing secret is stored. Admins can read every key in the Dispatcharr web UI.
- Never stored: passwords, API keys, JWTs, refresh tokens, TMDB keys, playlist URLs, LAN URLs, SSIDs, raw PINs.
- PIN: SHA-256 with a per-user random 16-byte salt (section 4.12). This deters casual viewing
  only: a 4 to 6 digit or direction PIN is brute-forceable offline, so a PIN gates profiles in the
  app, never protects data. Copy in Settings states that admins can view synced data.
- Local PIN storage on each device keeps using the encrypted local store; the synced salt replaces
  the per-device salt so a PIN set on one device works on all.
- All requests use the playlist's configured base URL and TLS when the server offers it.

## 10. Mapping from existing sync

### 10.1 Apple (SyncManager.swift, iCloud KVS)
| Apple today | Schema | Notes |
|---|---|---|
| `favoriteChannelIDs` [String] + `favoriteOrder` [String] | favorites.ids | Parse to Int; non-numeric ids (M3U) never apply to Dispatcharr Sync |
| (none) | recents | Apple adds recents to this lane |
| `syncedWatchProgress` rows: vodID, title, positionMs, durationMs, vodType, updatedAt, isFinished, seriesID | progress row 0, 9, 2, 3, 1, 4, 5, 6 | ms to s; vodType `movie`/`episode` to `m`/`e`; posterURL, streamURL, serverID dropped; season/episode written 0 until Apple tracks them, and round-tripped when present |
| `syncedReminders`: key `channelName|title|refDateSeconds`, programTitle, channelName, startTime | reminders row | Apple must add channelId and end; its key uses the 2001 reference date, the schema uses Unix seconds |
| (none) | watchlist, hiddenTitles | Apple round-trips until My List ships |
| ChannelCollection id, name, memberIDs, placement (local, not in iCloud) | collections row | memberIDs parsed to Int; placement `beginning`/`end` to `b`/`e` |
| `hiddenChannelGroups`, `hiddenMovieGroups`, `hiddenSeriesGroups` | hiddenGroups.live/movies/series | |
| `channelGroupOrder.sortMode`, `channelGroupOrder` | groupOrder.mode, order | |
| prefs dictionary allowlist | settings.v | Table 4.9 |
| `RemoteControlStore.mapKey` | remoteMap.tv | Must match the 4.10 shape exactly |
| `RadioModeSession.byDefaultKey` | radioDefault.on | |
| servers, credentials categories | not synced here | Stay on iCloud |

### 10.2 Android (DriveSyncManager.kt, SyncSnapshots.kt)
| Android today | Schema | Notes |
|---|---|---|
| `SyncEnvelope{version, lastModified, device}` | envelope schemaVersion, updatedAt, deviceId | millis to ISO 8601; `device` name replaced by the install UUID |
| FavoriteSnapshotEntry channelId, displayOrder | favorites.ids (sorted by displayOrder) | channelName, addedAt dropped (name comes from the channel list) |
| (recents table) | recents | Android adds recents to this lane |
| WatchProgressSnapshotEntry videoId, title, positionMs, durationMs, updatedAt, vodType, seriesId, seasonNumber, episodeNumber, isFinished | progress row | ms to s; posterUrl dropped |
| ReminderSnapshotEntry reminderKey, channelName, programTitle, startMillis, endMillis | reminders row | Android must add channelId; reminderKey is rebuilt locally from channelId and start |
| WatchlistSnapshotEntry vodId, vodType, addedAt, removedAt | watchlist row | Rows with removedAt are omitted; title, poster, year, rating, serverId dropped |
| HiddenTitleSnapshotEntry vodId, vodType, hiddenAt, unhiddenAt | hiddenTitles row | Same |
| PreferencesSnapshot.keys (string-encoded) | settings.v typed | Decode to real types; `remoteControlMap`, `radioModeByDefault` move to their own keys |
| PreferencesSnapshot.tv, .mobile (2026-10-27) | settings.tv, settings.mobile | Same lanes and scope rules as section 4.9; absent in older files |
| PreferencesSnapshot `recents.v1`, `channelCollections.v1`, `hiddenMovieGroups.v1`, `hiddenSeriesGroups.v1`, `lastGroup`, `recentGroupVisible` (2026-10-27) | recents, collections, hiddenGroups, settings | Drive gaps closed; raw stored strings, default profile only |
| PreferencesSnapshot `tmdbApiKey` | not synced | No longer written (it was cleartext); still read for one version so an older snapshot restores it, then dropped |
| ChannelCollection id, name, memberIds, placement (AppPreferences `channel_collections`, in Drive as `channelCollections.v1` since 2026-10-27) | collections row | Same conversion as Apple |
| Playlists, Credentials | not synced here | Stay on Drive |

## 10a. Coexistence with Drive and iCloud

Google Drive sync (Android) and iCloud sync (Apple) can be on at the same time as Dispatcharr Sync. Apple applies the same rules with iCloud in place of Drive.

Two independent switches (owner decision 2026-10-29), no single-choice "sync provider":
1. Drive Sync (iCloud on Apple): one device-local switch, Settings > Sync > Google Drive.
2. Dispatcharr Sync: one device-local switch per base user (profile-scoped), Settings > Sync > Dispatcharr Sync.
3. Turning either one on or off never changes the other: not in Settings, the Welcome "Sync with Dispatcharr" path, the onboarding Dispatcharr Sync step, the Drive restore path, or the providers offer (section 10b).
4. With both on, Settings shows under the Dispatcharr Sync section: "Dispatcharr Sync takes precedence for shared data on this server. Google Drive keeps a backup." Sync Categories is one shared list for both.
5. Migration from the old single choice (Android key `sync_provider`): `dispatcharr` reads as Dispatcharr Sync on; `drive`, `off`, or unset read as off. Drive Sync keeps its own stored value in every case. The old key is dropped the first time the Dispatcharr switch is written.

Rule 1, precedence. For a Dispatcharr playlist whose active user has Dispatcharr Sync on, Dispatcharr Sync takes precedence for every category both providers carry: favorites, recents, collections, watch progress, reminders, watchlist, hidden titles, hidden groups, group order, radio default, remote map, and settings. Drive (or iCloud) keeps owning playlists and credentials, and every category for non-Dispatcharr playlists. Drive keeps pushing its full snapshot as a backup; a Drive pull does not apply a Dispatcharr-owned category.

Ownership predicate (Android `DispatcharrSyncManager.ownsCategory`, pure rule `DsyncCoexistence.owns`): true when all of these hold:

1. the Drive category carries at least one key of this schema (Favorites, Watch Progress, Reminders, Watchlist, App Preferences; never Playlists or Credentials),
2. the active playlist is Dispatcharr,
3. Dispatcharr Sync is on for that playlist's active user, and
4. this device has completed at least one Dispatcharr pull for that user (persisted per playlist and profile).

Until condition 4 holds, a Drive pull still applies its categories, so restoring from Drive and then turning on Dispatcharr Sync leaves the Drive data on the device, and the first Dispatcharr push seeds it to the server. Each skipped category logs one line:

```
[DRIVE] pull <category> skipped: Dispatcharr Sync owns it
```

Per-item Sync Categories still apply: an item that is Off neither pushes nor applies on any provider.

Rule 2, first-pull seeding. An empty or missing server copy never overwrites what a user already has when they turn on Dispatcharr Sync:

1. Missing (bucket 404, absent from the list, or category absent inside the bucket): the key is marked read and not present, and the post-pull flush pushes local up. This was already the behavior.
2. Present with empty data (no ids, rows, names, or lanes; `groupOrder` with mode `default` and no order) on the first read of that key for this user on this device (no server stamp ever consumed here): the envelope is recorded as consumed without applying it, the key is marked dirty, and local is pushed up. Log line: `[DSYNC] pull <key> bytes=<n> empty on server, first pull: seeding from local`. Primitive values (for example `radioDefault.on=false`) are real choices and apply as usual. An empty copy seen after the first read is a real change from another device and applies as usual. `profiles` merges per row and is exempt.

Rule 3 (id cache readiness, 2026-10-30). Keys translated through the
channel map (favorites, recents, reminders, collections) are not written
until the session's channel snapshot has Dispatcharr channel ids. Keys
translated through the VOD catalog (progress, watchlist, hiddenTitles) are
not written while the movie catalog has not completed a sweep and a local
row could not be translated. A deferred key stays dirty and is re-pushed
when the cache is ready, so an empty list never goes up over local rows
that exist but could not be translated. After the cache is built, a row
that still cannot be translated is a real miss and stays on the device.
Drive snapshots carry local ids and need no translation.

Rule 4: choosing a source when both hold data (2026-10-30). When Google
Drive and Dispatcharr Sync both hold data for the signed-in Dispatcharr user
(the base profile; sub-profiles never take part) and they differ, the user
picks which setup the device starts from, and the other side is replaced
with it. It runs in onboarding (both providers selected, or Drive only when
the restored playlist is Dispatcharr and the user then turns Dispatcharr
Sync on) and in Settings > Sync when the second provider is turned on.

Probe before apply: with both selected in onboarding, the Drive restore
applies Playlists and Credentials only (Dispatcharr never holds them and the
probe needs them); the shared categories are held, neither pulled nor
pushed, until the choice (the hold expires after 30 minutes). Each held
pull or push logs `[DRIVE] pull <category> held: waiting for the setup
choice` (or `push`); that line is the fresh-setup state before the choice. The probe
reads the Drive files and the user's App Data key (`GET` on the existing
app-data path, no new server path) without applying either, and summarizes
per shared category (favorites, recents, collections, progress, reminders,
watchlist, hiddenTitles, hiddenGroups, groupOrder, settings): row count,
`updatedAt`, and a content fingerprint over canonical row identities. The
channel categories favorites and recents count canonical-id rows only
(2026-11-01): distinct Dispatcharr channel ids, recents capped at 50 after
the dedupe, exactly what the Dispatcharr build carries and
`DsyncCoexistence.rowCount` counts; a local channel with no Dispatcharr id
(another playlist, not in the channel list) is neither counted nor compared.
One row definition per category serves the forced push row count, the
probe summary, the Drive summary and push line, and the converge
fingerprint (`ConvergeRoundTripTest.pushRowCountEqualsProbeCountForEveryCategory`).
A failed channel lookup fails the probe (no choice) instead of undercounting.
A collection whose members cannot all be resolved has no fingerprint and
counts as different when non-empty on either side. The VOD categories
(progress, watchlist, hidden titles) follow the canonical-id requirement
below.

Canonical-id requirement for VOD rows (2026-11-01). A progress, watchlist,
or hidden title row counts only when it carries a canonical Dispatcharr VOD
id: the snapshot's `dispatcharrVodId`, else the id resolved from the local
catalog or episode map at probe time. Both summaries apply it (the Drive
summary in `DriveCanon.progress`, `watchlist`, and `hiddenTitles`; the
Dispatcharr rows always carry one, counted as distinct type plus id). A row
with no canonical id (a title deleted from the server, a row from another
server, a URL-keyed row) cannot live on Dispatcharr Sync: it stays in Drive
and on the device, is never force pushed, never converged, and never
counted, so the fingerprints agree on the rows both sides can hold. Field
run 2026-11-01: Drive progress=8 against Dispatcharr progress=1 with seven
untranslatable rows asked on every Drive off/on; both now read 1.

Representable rows and held rows (2026-11-01, second field run). The
decision compares only rows this device can represent on both providers.
A Dispatcharr progress row the pull cannot map to a local uuid (movie
catalog sweep not there yet, episode not in the saved episode map) is no
longer dropped: it is held by its canonical id (`DsyncHeldStore`, base user,
per playlist) and logged counts only as `[DSYNC] progress in held=<n>
movies=<n> episodes=<n> catalogReady=<bool>`. The Drive WatchProgress
snapshot carries each held row as a placeholder row (`videoId`
`dsync:<m|e>:<id>` with `dispatcharrVodId`), so the Drive summary and push
count it by that id even when the local catalog cannot resolve it. A Drive
apply never writes a placeholder as a local row; it holds it (replacing the
held set when the user chose Google Drive), and the forced Dispatcharr push
includes held rows. Every later progress pull ("not newer" included)
retries the held rows against the catalog and episode map and turns the
ones that resolve into local rows. Symmetrically, the Dispatcharr summary
on this device (setup probe, fresh-device order, converge) keeps a
progress, watchlist, or hidden title row only when it resolves here, is
held, or the Drive copy carries it with a canonical id; the others are
excluded with `[SYNC] probe excludes <category> rows=<n> (no local match)`.
Held rows that resolve log `[DSYNC] progress held rows resolved=<n>` and
queue the Drive follow push. A converge mark (this Dispatcharr state was
pushed once and Drive still differs) stands only while this device's push
would still carry what Drive holds; when the local copy changed since, the
mark is cleared (`[SYNC] converge mark cleared <category> (local copy
changed)`) and converge pushes again. So `converge skip <category>
reason=untranslatable` can only follow rows that cannot exist on this
device, and those are in neither summary. Field
run: `[DSYNC] setup probe progress=1` against `[DRIVE] setup probe
progress=0` with `push WatchProgress rows=0` after a Dispatcharr choice,
because the one server row was skipped by the pull
(`HeldProgressTest`). The Apple copy of this section must mirror it.

Translation order for a forced push (2026-11-01). Every Drive apply of
watch progress and watchlist records the snapshot's canonical ids into the
Dispatcharr Sync id map (`[DRIVE] canonical ids progress movies=<n>
episodes=<n> without=<n>`), so a forced push translates those rows from
the snapshot first and the local catalog or episode list second, without
waiting for the movie sweep or for the user to open Movies or TV Shows.
Episode ids need no series catalog sweep: they come from the snapshot, the
saved episode map, or one episode-list load per series (retried on a later
build when it failed). A forced key that ends without a PUT, because the
server already holds the same copy, logs `[DSYNC] put <bucket> (<key>)
status=unchanged rows=<n>`. Rows still untranslated log `[DSYNC] progress
drops untranslated: movies=<n> episodes=<n> other=<n>` (counts only).

Canonical ids and the Drive id migration (2026-10-30). The canonical
identity of each shared category is the one Dispatcharr Sync puts on the
wire: Dispatcharr channel ids for favorites, recents, and collection
members; the type plus the Dispatcharr VOD id for progress, watchlist, and
hidden titles; channel name and start second for reminders; group names for
hidden groups and group order; and schema setting names with their values
for settings (blank values left out on both sides). Drive snapshots keep
their local ids and gain nullable fields beside them, filled on every Drive
push when the active playlist is Dispatcharr and the id resolves (an
unresolved id stays null and never holds a push): `dispatcharrChannelId` on
favorites entries, `dispatcharrVodId` on watch progress, watchlist, and
hidden title entries, and `dispatcharrChannelIds` (local channel id to
Dispatcharr channel id) on the preferences snapshot for the channels that
recents and collections reference. Older files decode unchanged and the
envelope version stays 1; instead the envelope gains `format`, and every
push from this build writes `format` 2. The probe falls back to resolving
local ids for rows written before these fields existed. When a Drive
restore (onboarding, or Settings > Sync with Drive on) finds any shared
file whose envelope `format` is missing or below 2, AerioTV offers "Your
backup needs an update" with "Update backup" and "Not now", for every
playlist type. Nothing is rewritten without "Update backup", which rewrites
each shared Drive file once at `format` 2, keeping its envelope time and
every other field, gated per base user and category by a saved flag. With
an active Dispatcharr playlist the Dispatcharr ids are filled where they
resolve; the channel categories wait for the channel list and the VOD
categories wait for the movie catalog, flag unset, and finish on a later
sync. Any other playlist type rewrites at once with the ids left null.
"Not now" keeps the old format and the prompt-when-unsure behavior;
onboarding does not show the offer again that app session, and Settings
offers it at most once per app session.

Format rule (2026-11-01). Every Drive write of every shared file carries
envelope `format` 2: each push builds its envelope in one place
(`DriveCanon.writerEnvelope`), and the accepted update rewrites every
shared file (favorites, progress, reminders, watchlist, preferences) whether
or not its Sync Category is on and whatever its row count. When the id
fill has to wait (channel list or movie catalog) or the file does not
decode as a current snapshot, the update still stamps `format` 2 at once,
keeping every other field as written, logged `[DRIVE] id migration:
<category> format stamped ok=<bool> (<why>)`; its flag stays unset and the
ids fill on a later sync. The update is not held by the setup-choice hold
(it carries the Drive file's own rows, never this device's data), so
"Update backup" on the welcome flow takes effect at once. The offer check
logs which files are old format: `[DRIVE] backup update needed:
categories=<names>`. A device on a build older than format 2 can still
write an old file; the offer then returns, which is the intended signal.

| Drive | Dispatcharr | Result |
| --- | --- | --- |
| empty | empty | Dispatcharr (nothing to replace) |
| has data | empty | Google Drive, no prompt |
| empty | has data | Dispatcharr, no prompt |
| has data | has data, every category provably equal | Dispatcharr, no prompt |
| has data | has data, any category differs or cannot be proven equal | Ask |

The prompt: "Which setup should this device start from?", two cards
("Dispatcharr" and "Google Drive", each "Updated <relative time>" and up to
four non-zero counts, then "and more"), the line "The other will be
replaced with the setup you choose.", and Continue or Cancel. Dispatcharr
is always preselected when it opens, whichever side is newer (2026-11-01):
the prompt only appears with Dispatcharr Sync on for the active playlist,
so there is no newer-side rule. The Apple app mirrors this.
Cancel in onboarding returns to Welcome with the selections kept; in
Settings it leaves the switch off.

Google Drive chosen: the Drive snapshot applies (ignoring Rule 1 ownership
in Settings, where Dispatcharr already owns the data), then every shared key
of the base user is pushed whole from this device. A persisted per-key force
flag makes the pull record the server copy as consumed without applying it
(no `remoteWins`, no consumed-stamp check, no self-heal) and makes the PUT
skip the merge in the read-before-put; row categories build from local only
(no server rows merged or kept). Rule 3 still applies: a key whose cache is
not ready stays dirty and forced until it is sent. A key with no local
rows is written empty, so the server mirrors Google Drive exactly and the
two sides compare equal afterward (2026-10-30; before this the server copy
was kept and the prompt came back). In the other direction, choosing
Dispatcharr makes the next Drive push write every enabled file, empty ones
included. While the Drive backup applies, Dispatcharr Sync neither pulls
nor pushes the shared keys (a hold of at most 2 minutes), and the forced
replace is armed per category only after that category's Drive backup
applied (a missing Drive file counts as applied with no rows). When the
apply fails, that category's keys are not armed (any earlier flag clears),
the server copy stays, and the prompt shows again next time, logged as `[SYNC] forced
replace cancelled: Drive backup did not apply (<category>)`. The flag
clears per key on a successful PUT. Log lines:
`[DSYNC] force push <key> rows=<n> (user chose Google Drive)` and, for an
empty key, `[DSYNC] force push <key> rows=0 (empty, mirrors Google Drive)`.
Profiles, remoteMap, and radioDefault are not forced.

Mirror details (2026-11-01). Every shared Drive file applies with replace
semantics for this choice. Preferences: a setting, recents list,
collection, hidden group, or group order the Drive copy does not carry
goes back to its default, so local holds the Drive key set. Row files:
the backup rows apply, then a local row the backup does not carry is
removed (favorites and progress rows deleted, reminders deleted with their
alarm cancelled, watchlist and hidden title rows tombstoned so the removal
travels; a watchlist or hidden title identity the backup carries takes the
backup row, its tombstone included). Only rows inside the comparison the
setup probe makes are candidates; rows its filters exclude are counted by
neither side and are kept: progress rows that are URL keyed, not a movie
or episode, finished more than 30 days ago, or beyond the 300 newest;
reminders that already ended; watchlist and hidden title rows of another
playlist scope (a host other than the active playlist's). Hidden titles
follow only while their Sync Categories item is on. A missing Drive file
replaces nothing (local rows stay; the next Drive push writes them). One
counts-only line per category: `[DRIVE] replace <category> local=<n>
backup=<m> removed=<k>` (local and backup counted with the probe filters;
preferences counts keys across lanes with removed 0). The
forced `settings` push sends exactly the Drive lanes just applied (`v`,
`tv`, and `mobile`, the same names and non-blank count the setup probe
reads from Drive); the server's previous lanes are not merged in. Log
line: `[DSYNC] force push settings rows=<n> (mirrors Google Drive)`. A
forced key that defers on its id cache (Rule 3, for example progress while
the movie catalog sweep runs) stays armed and dirty until a PUT succeeds,
and a pull keeps skipping it meanwhile. It is retried when the catalog is
ready (the 5 s cache poll, and the catalog page signal after a quiet
period of `PAGE_RECHECK_MS`, the hook the Drive id migration retry uses)
and on every regular sync cycle, logged as `[DSYNC] force push <key> retry
(catalog|cycle) rows=<n>`. The choice hold may expire first; the armed flag
is what protects the key. Rows still untranslated once the catalog is built
are left out of the push, logged once with counts only: `[DSYNC] force push
<key> drops untranslated=<n> sent=<m> (not in this catalog)`. The Apple
copy of this document and the Apple app must mirror these rules.

Dispatcharr chosen: the held Drive categories are never applied; the normal
first pull applies the server copy; then Drive's backup is replaced in the
same app session, right after that first pull (or its 120 s limit), not at
the next scheduled push (2026-11-01). Every enabled shared Drive file is
pushed at once and logs its own line, counts only: `[DRIVE] next push
replaces backup (user chose Dispatcharr)`, then `[DRIVE] push <Category>
rows=<n> (replace)` per file (the Preferences line adds its per-category
counts, for example `recents=9 groupOrder=4`). Rule 1 precedence holds
afterward in both cases.

Fresh-device order (2026-11-01, Dispatcharr chosen, prompt or automatic
UseDispatcharr). The choice arms a persisted wait on every shared Drive
file before any hold is released. The first Drive push of a file (replace,
follow, worker, or converge) goes out only when, for every shared category
it carries that this device syncs, the Dispatcharr pull of that key has
completed on this device this session (applied, merged, kept local, not
newer, seeded from local, or absent on the server). A completed pull
releases the file whatever the row counts say: after it, local is the
Dispatcharr copy (2026-11-01 revision; the earlier count check held a phone
that was set up all along forever, because its local count left settings
out). Otherwise the file is not pushed and logs `[DRIVE] push <Category>
held: <category> not pulled yet|Dispatcharr pull not done (fresh-device
order)`; the pull's Drive follow pushes it once the pull completes. So a
fresh device never overwrites a populated backup before it has the
Dispatcharr copy. The wait clears per file on its first push, on a Google
Drive choice, or when Dispatcharr Sync is off. A converge push of a
waiting file is not remembered as pushed, so the next converge retries it.

Unknown Drive (2026-11-01). A Drive read that fails (HTTP 401, any other
HTTP error, network, or Drive needing sign-in) is unknown, never empty:
the listing throws instead of returning no files, and a failed file
lookup never leads to a create. The setup probe logs `[DRIVE] setup probe
failed: <reason class> (treated as unknown, not empty)` and the decide
rules do not decide: no UseDispatcharr with replace, no forced replace,
no converge push, and no "next push replaces backup". Log: `[SYNC] setup
source drive=unknown dsync=<n> rows decision=none (retry when Drive
works)`. The flow continues on Dispatcharr Sync alone; shared Drive files
are neither pushed nor pulled (`[DRIVE] push <Category> held: Drive state
unknown (setup probe failed)`), persisted across restarts. The probe runs
again after each complete Dispatcharr pull (Rule 5 entry) and when the
Sync screen sees Drive signed in; a readable Drive then decides as usual
(Ask waits for the prompt on the Sync screen). Converge skips with
`[SYNC] converge skipped: Drive unreadable (unknown, not empty)` when its
own Drive read fails.

Drive token (2026-11-01). Every Drive call that gets a 401 refreshes the
access token once (clearing it from the platform token cache first, since
the cached token would otherwise come back unchanged) and retries once.
If the refresh fails or the retry gets a 401 too, Drive is marked as
needing sign-in (persisted): no further Drive call goes out, the Sync
screen shows "Sign in to Google Drive again" as one line under the Drive
section with the sign-in and Sign Out controls, and signing in again
clears it. The in-memory token honors the same expiry as the saved one.

Rule 5: convergence (2026-11-01). With Google Drive and Dispatcharr Sync
both on, the shared categories stay equal on both sides on every device,
so a device signing in later decides "equal, use Dispatcharr" with no
prompt from either source. It never replaces or answers a prompt: "Your
backup needs an update", "Which setup should this device start from?",
and "Turn on Dispatcharr Sync?" stay exactly as they are, and a mismatch
found before the setup choice is settled is left to them.

1. Drive follows Dispatcharr Sync in the same foreground session. A shared
   key applied from a Dispatcharr pull (applied, merged, or self-healed),
   or changed on this device, queues the one-shot Drive push (15 s
   debounce, REPLACE), base user only, Drive Sync on, and the key's Sync
   Categories item on. Log: `[SYNC] drive follow <key> (pull|local)`.
   The follow is noted on the Drive FILE that carries the key
   (`DsyncCoexistence.driveFileFor`): recents and collections ride in
   Preferences although their Sync Categories toggle is Favorites; a key
   with no Drive file fails a unit test instead of falling through.
   A Drive pull of a Drive-owned category (Playlists, Credentials, any
   category of a non-Dispatcharr playlist) has no Dispatcharr key, so
   nothing goes to Dispatcharr Sync.
2. Self-heal after every complete Dispatcharr pull, when all hold: base
   user, Drive Sync on and signed in, a Drive pull completed on this
   install, Rule 1 ownership (Dispatcharr Sync on, Dispatcharr playlist,
   first pull done), no Rule 4 hold, no armed forced key, and no setup
   prompt open or unanswered this app session. The Dispatcharr side is
   the bucket this pull just read (no extra server read); the Drive side
   is one read of the shared files. Both are summarized with the Rule 4
   probe (same fingerprints). A category with an unsent local change is
   not compared (the follow push carries it). Every differing category
   pushes its Drive file from this device, which holds the Dispatcharr
   copy: Dispatcharr is the source of truth, Drive is never pulled over
   Dispatcharr-owned data. Log, counts only:
   `[SYNC] converge <category> drive=<fp>/<rows> dsync=<fp>/<rows> -> push drive`,
   or `[SYNC] converge equal categories=<n> skipped=<n>` (skipped counts only categories that logged a skip line; Off items are not compared or counted). Converge and the
   Rule 4 probe use the same summaries (`DriveSyncManager.readSharedSummary`
   and `DsyncCoexistence.summarize`), so "equal" is logged only when the
   probe would not ask. Every differing category it does not push is named:
   `[SYNC] converge skip <category> reason=<armed|deferred|dirty|unread|untranslatable> drive=<n> dsync=<n>`,
   then `[SYNC] converge nothing pushed categories=<n> differing=<n>`. A key
   dirty only because untranslatable rows stayed local is compared, not
   skipped. The follow push logs each followed file:
   `[DRIVE] push <Category> rows=<n> (follow <key> <reason>)`. Every
   converge push logs `[DRIVE] push <Category> rows=<n> (converge)`, and the
   next converge reads equal unless a row cannot be translated. A key
   skipped as dirty with no write queued gets its write queued: the build is
   compared with the server copy just fetched (never an older saved copy),
   so a key the server already equals ends as `status=unchanged` and clears,
   and converge runs again once those writes settle. A truly unsent local
   change stays a valid skip until its write goes out.
3. No ping-pong: a category pushed once for a given Dispatcharr state
   (rows plus fingerprint, saved per playlist) is not pushed again until
   the Dispatcharr copy changes, even when the next compare still differs
   (a row this device could not translate).
4. Same inputs on both sides, for the Rule 4 decision and Rule 5 alike:
   a category whose Sync Categories item is Off on this device is left out
   of both summaries, so it is never compared, converged, or replaced
   here; settings drop the names whose item is Off. Drive settings are
   typed into the wire form a push sends before they are fingerprinted,
   and every setting value is compared in one spelling (booleans
   lowercase, whole numbers without ".0", color hex uppercase without
   "#"). The group sort mode reads as a known mode or "default" on both
   sides.

Single snapshot builder, pull before replace, and atomic category commit
(2026-11-01, third field run on the phone):

1. One builder. Exactly one function builds the Drive WatchProgress
   snapshot (`DriveSyncManager.driveProgressSnapshot`, pure rule
   `DsyncHeld.driveSnapshot`). Every caller uses it: replace, converge,
   follow local, follow pull, the periodic and one-shot worker, Push to
   Drive, and the converge mark check. It merges the local rows with the
   held rows and the progress rows of the Dispatcharr copy this device
   last read (the active base-user session; held rows only when the user
   chose Google Drive or progress is off). A resolved local row wins over
   the placeholder for the same item; a local row whose canonical lookup
   returned nothing takes the id from the Dispatcharr row whose saved
   reverse id is its uuid. So a lookup that fails in one run never drops a
   row from Drive (field run: the movie row existed, the push counted 0).
   Each push logs counts only: `[DRIVE] progress snapshot local=<n>
   canonical=<n> dsync=<n> placeholders=<n> (<why>)`.
   What emptied the snapshot on the phone: every Drive worker run pulls
   Playlists after its push, and the playlist write used SQLite REPLACE,
   which deletes the playlist row before inserting it, so ON DELETE CASCADE
   removed every watch progress (and reminder and local recording) row of
   that playlist (`progress snapshot local=2`, then `local=0` right after
   the pull). Playlist writes are now an in-place upsert (Room `@Upsert`).
   The Apple copy must check its own playlist writes for the same cascade.
2. Progress heal. A progress pull that is "not newer" writes every server
   row this device lacks (or holds older) when it resolves, and holds the
   rest, unless a local change is unsent. The server copy is a per-row
   union, so this never writes anything a later push would undo.
3. Pull before replace. Choosing Dispatcharr runs a full Dispatcharr pull
   first with the stamp check forced (a shared key that is "not newer" is
   applied anyway unless it has an unsent local change;
   `DsyncCoexistence.choiceApplies`), and only then replaces the Drive
   backup. The pull logs `[DSYNC] setup choice pull ok=<bool>` and each
   forced key `[DSYNC] pull <key> bytes=<n> applied (setup choice, stamp
   not newer)`. Progress rows the pull held (movie catalog not built yet)
   are written locally before the replace push (bounded wait, 45 s;
   `[DSYNC] progress before replace resolved=<n> held=<n>`), so the first
   `[DRIVE] progress snapshot` already counts them as local. If the list, the bucket, or a forced apply fails, Drive is
   not replaced: `[DRIVE] replace deferred: Dispatcharr pull failed`, the
   shared Drive pushes are held (`[DRIVE] push <Category> held: replace
   deferred until the Dispatcharr pull applies`), and the next Dispatcharr
   cycle (converge) retries pull then replace. Recents follow the same
   representable rule as the VOD keys: the Dispatcharr summary on this
   device keeps a recent channel only when this device's channel list maps
   it or the Drive copy carries it (`[SYNC] probe excludes recents rows=<n>
   (no local match)`); an unloaded channel list excludes nothing. Field run
   after the first fix: server recents 14, one channel absent here, so the
   apply could never write it and every probe read 14 against 13.
4. Atomic category commit. Once a category's upload starts, the upload,
   the follow bookkeeping, and its push line run under NonCancellable;
   turning Drive off stops the push only between categories (`[DRIVE] push
   stopped before <Category>: sync cancelled (Drive turned off)`). Tests:
   `DriveSnapshotRulesTest`. The Apple copy must mirror all four rules
   (iCloud in place of Drive).

Apple mirrors Rule 5 with iCloud in place of Drive (pending in the Apple
copy of this document). The Apple copy must also mirror the canonical-id
requirement for VOD rows and the forced-push translation order above, and
(2026-11-01) the canonical-id rule for favorites and recents, the immediate
backup replace on a Dispatcharr choice, and the fresh-device order. The
Apple copy must mirror the unknown-Drive rule (unknown iCloud: a failed
read is never empty, nothing is decided) and the hold release rule (a
completed pull releases the fresh-device hold regardless of counts).

Manual push and pull (owner decision 2026-11-02). Settings > Sync, under
the Dispatcharr Sync section and only while Dispatcharr Sync is on for the
active Dispatcharr playlist, shows "Push to Dispatcharr" (with its "Last
synced" line) and "Pull from Dispatcharr" after Sync Now, which is
unchanged. With Google Drive also on (and signed in), "Push to both"
follows. Each asks first (Push or Pull, and Cancel). The keys covered are
the forced-replace keys (`DsyncCoexistence.FORCE_KEYS`) whose Sync
Categories item is not Off (`DsyncManual.keys`); Profiles, remoteMap, and
radioDefault are never forced, and an Off item neither pushes nor pulls.
1. Push to Dispatcharr: the forced replace (Rule 4 semantics, empty keys
   included, no server rows merged) for the base user, sent at once. Log
   `[DSYNC] manual push <key> rows=<n>` then the put status line. A key
   that cannot be sent stays armed and dirty for a later cycle; the row
   reads "Could not reach your Dispatcharr server".
2. Pull from Dispatcharr: the setup-choice pull (`pullForChoice` path,
   stamp check forced) applies the server copy for every covered key, no
   prompt; applied keys queue the Drive follow pushes (Rule 5). Log
   `[DSYNC] manual pull <key> rows=<n>`.
3. Push to both: step 1, then the Drive `replaceBackupNow`. Log
   `[SYNC] manual push to both`.
Results: "Pushed to Dispatcharr", "Pulled from Dispatcharr", "Pushed to
both", or "Could not reach your Dispatcharr server" as the row's status
line. Rows, order, and wording are identical on phone, tablet, and TV. The
Apple app mirrors this with iCloud in place of Google Drive.

## 10b. Sync providers record (`syncProviders`)

Every backup carries which sync providers the device owner runs, so a new device can offer the same ones.

```json
{"dispatcharr":true,"googleDrive":true,"icloud":false,"updatedAt":1761700000000,"deviceId":"6F1C...5A11"}
```

`updatedAt` is Unix milliseconds (the one exception to the seconds rule inside `data`). Where it lives:

1. Dispatcharr Sync: the `data` of category `syncProviders` in the single key (section 3), with the usual sub-object `updatedAt` (ISO, the record's time) and `deviceId`.
2. Google Drive (Android): `envelope.syncProviders` in every snapshot file (`SyncEnvelope`), optional.
3. iCloud (Apple): the same object in the iCloud payload; Apple writes `icloud`.

Readers tolerate its absence; missing booleans read false, a record without `updatedAt` is ignored.

Scope (owner rule, 2026-10-29): the record describes the user who set up the device, never another profile.
1. Dispatcharr copy: written and read only by a session of the BASE (signed-in) profile, under that user's own key. A sub-profile session round-trips the category untouched and never folds it locally. Local copies are kept per playlist, never merged across profiles.
2. Drive copy: belongs to the Google account that owns the backup; every flag is computed from the base profile's state only. `dispatcharr` there means the owner uses Dispatcharr Sync for their own user.

Union rule (both providers, same pure rule, Android `SyncProvidersRules`):
1. Pull: keep the newer record whole (`updatedAt`, ties: higher `deviceId`).
2. Push: stored flags OR this device's own, each from its own switch (`dispatcharr` = Dispatcharr Sync on for the base user, `googleDrive` = Drive Sync on, `icloud` = iCloud on; Android never sets `icloud` but preserves it).
3. A flag goes from true to false only when this device reported it true before and the provider is now off here: it writes `false` with a newer `updatedAt` once, then stops forcing it, so a device that still runs the provider sets it true again on its next push.
4. `updatedAt` and `deviceId` change only when a flag changes.
5. Best effort: a device pushing a stale Drive copy can re-raise a flag; the next union settles it.

Prompt rule:
1. Armed only by onboarding's first Drive restore or first Dispatcharr Sync pull, with the base profile active. Never when a sub-profile is added or switched to.
2. Offers each provider the owner's records (Drive copy, and the base user's Dispatcharr copy for the active playlist) mark true that is off on this device. Dispatcharr is offered only when the active playlist is Dispatcharr Direct Connect. iCloud is never offered on Android; Apple offers iCloud and Dispatcharr the same way.
3. One themed dialog, once per playlist (persisted): title "Keep your devices in sync", text "Your other devices also use <Google Drive / Dispatcharr Sync / Google Drive and Dispatcharr Sync>. Turn it on here too?", buttons "Turn on" (focused on TV) and "Not now".
4. Turn on: Drive runs the Welcome card path (Google sign-in, Drive scope, master on); Dispatcharr turns Dispatcharr Sync on for the active user. Neither turns the other provider off.

No new server paths: the record rides the existing App Data key and Drive files.

## 11. README rows (both repos, same commit as the code)

Pangolin rules table: already covered by the existing `/api/accounts/*` prefix rule; no new row.

"Every Dispatcharr API path AerioTV uses" table:
| Path | Why AerioTV calls it |
|---|---|
| `/api/accounts/users/me/app-data/` | Lists AerioTV's synced data keys and sizes for the signed-in profile (Dispatcharr Sync) |
| `/api/accounts/users/me/app-data/<key>/` | Reads, saves, and clears one Dispatcharr Sync category (keys start with `app.molinete.aerio.`) |
