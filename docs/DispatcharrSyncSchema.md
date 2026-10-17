# Dispatcharr Sync schema (v1)

Status: draft, not yet implemented on either platform.

Shared by AerioTV for Apple (iOS, iPadOS, tvOS) and AerioTV for Android.
This file must be byte-identical in both repos at `docs/DispatcharrSyncSchema.md`.
Any change bumps the affected key's `schemaVersion` and lands in both repos in the same day.

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
| Limits | 25 keys per user, 32 KiB per key (compact UTF-8 JSON), 128 KiB total per user, depth 8, body cap about 33 KiB |
| Value | Must be a JSON object. PUT replaces the whole value. No PATCH, no ETag, no versioning |
| Concurrency | Last writer wins (server serializes with a row lock) |
| Visibility | Any admin can view and clear any user's data in the web UI |
| Errors | `{detail, code}`: 400 key_invalid, value_not_object, value_has_nul, value_too_deep; 413 value_too_large, total_too_large, body_too_large; 409 max_apps; 403 forbidden; 404 key_not_found |

## 2. Keys

Prefix: `app.molinete.aerio.` One key per category. All keys are written with the profile's own
token to `users/me/app-data/<key>/`.

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

Device-local, never synced here, and why:
- Kept Live / background Radio auto-start: tied to one device's power and network.
- Default Live TV view (List or Guide): form-factor specific (an iPhone's List would clobber a TV's Guide).
- Buffer size, network timeout, retries, LAN URL, home SSID, DVR folder, background refresh schedule: per-device network and storage.
- Active profile: per device by design.
- Channel profile selection: server-side state (admin assigns it per user).
- DVR recordings: server-side (Dispatcharr) or local files.
- EPG, logos, VOD catalog caches: rebuilt from the server.

Budget: 13 keys leaves 12 of 25 free for future categories.

## 3. Envelope (every key)

```json
{
  "schemaVersion": 1,
  "deviceId": "6F1C2A9E-4B7D-4C1E-9E1A-0D2B8C3F5A11",
  "platform": "ios",
  "appVersion": "1.8.44",
  "updatedAt": "2026-10-17T18:04:05Z",
  "data": { }
}
```

| Field | Type | Rule |
|---|---|---|
| `schemaVersion` | int | Per key. Starts at 1. Bump only on a breaking change to `data` |
| `deviceId` | string | Random UUID generated once per install, stored locally, never tied to hardware ids |
| `platform` | string | `"ios"` (iPhone, iPad, Mac), `"tvos"`, `"android"` (phone, tablet, TV) |
| `appVersion` | string | Diagnostics only |
| `updatedAt` | string | ISO 8601 UTC, second precision, `Z` suffix |
| `data` | object | The payload in section 4 |
| `extra` | object, optional | Fields a newer writer added within the same `schemaVersion` (section 6.2) |

Reader rules:
1. Missing envelope fields or wrong types: ignore the key, log `[DSYNC] malformed <key>`, do not overwrite it.
2. `schemaVersion` greater than the reader knows: ignore the key, log `[DSYNC] skip <key> v<n> > v<known>`, and do not write that key until the app updates (writing would downgrade it).
3. `schemaVersion` lower: upgrade in memory, write back at the current version on the next local change.

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
- VOD: the Dispatcharr movie, series, and episode UUIDs as strings (`"vodId"`, `seriesId`), byte for
  byte exactly as `/api/vod/...` returns them. Never a numeric id, never reformatted (no case change,
  no added or removed hyphens).
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
{"rows":[["8812","e",1834,2640,1760724245,0,"301",2,5,"The Pilot"]]}
```
Row positions:
| # | Field | Type | Notes |
|---|---|---|---|
| 0 | vodId | string | movie id or episode id |
| 1 | type | string | `"m"` movie, `"e"` episode |
| 2 | position | int | seconds |
| 3 | duration | int | seconds, 0 if unknown |
| 4 | updatedAt | int | Unix seconds |
| 5 | finished | int | 0 or 1 |
| 6 | seriesId | string or null | null for movies |
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
{"rows":[["5531","m",1760700000],["301","s",1760600000]]}
```
Row: `[vodId:string, type:"m"|"s", addedAt:int]`. Removal = absence (full replace replaces Android's
`removedAt` tombstones; see 6.3). Rows carry no title: the app fills title, poster, year, and rating
from the VOD catalog by `vodId`.

### 4.6 hiddenTitles (cap 500)
```json
{"rows":[["5531","m",1760700000]]}
```
Row: `[vodId:string, type:"m"|"s", hiddenAt:int]`.

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
{"v":{"selectedTheme":"Midnight","appearanceMode":"dark","trueBlack":true,"textScale":1.1}}
```
`v`: map of schema name to bool, int, double, or string. Only names in this allowlist are written:

| Schema name | Type | Apple key | Android key |
|---|---|---|---|
| selectedTheme | string | selectedTheme | selectedTheme |
| appearanceMode | string | appearanceMode | appearanceMode |
| trueBlack | bool | appearance.trueBlack | appearanceTrueBlack |
| useCustomAccent | bool | useCustomAccent | (Apple only) |
| customAccentHex | string | customAccentHex | (Apple only) |
| defaultTab | string | defaultTab | defaultTab |
| timeFormat | string | ClockFormat.defaultsKey | timeFormat |
| textScale | double | TextScale.key | textScale |
| subtextScale | double | SubtextScale.key | subtextScale |
| textContrast | double | TextContrast.key | textContrast |
| guideProgramInfoButton | string | guideProgramInfoButton | guideProgramInfoButton |
| programInfoButtonGuide | bool | guideProgramInfoButtonGuideView | programInfoButtonGuide |
| programInfoButtonList | bool | guideProgramInfoButtonListView | programInfoButtonList |
| showEpgBadgesTv | bool | showEpgBadges.tv | showEpgBadgesTv |
| showEpgBadgesMobile | bool | showEpgBadges.mobile | (Apple only) |
| showRemoteHints | bool | showRemoteHintsKey | showRemoteHints |
| guideGroupSelector | string | RemoteControlStore.groupSelectorKey | guideGroupSelector |
| guideSidebarLayout | string | RemoteControlStore.sidebarLayoutKey | guideSidebarLayout |
| guideTuneInMini | bool | RemoteControlStore.tuneInMiniKey | guideTuneInMini |
| defaultChannelGroup | string | defaultChannelGroup | (Apple only) |
| skipBack / skipForward | int | SkipIntervals.backKey / forwardKey | (Apple only) |
| enableCategoryColors, tintChannelCards | bool | same | (Apple only) |
| categoryColor.<bucket> | string | categoryColor.<bucket> | (Apple only) |
| categoryBucketEnabled.<bucket> | bool | same | (Apple only) |
| customCategories | string (JSON, max 4 KiB) | CategoryColor.customCategoriesKey | (Apple only) |
| logoCornersList / logoCornersGuide / logoCornersGuideCells | bool | LogoCorners.* | (Apple only) |
| playerInfoCard.<row> | bool | PlayerInfoCardSettings.allKeys | playerShowChannelInfoCard maps to showOnChannelChange |
| tmdbPostersEnabled | bool | TMDBPosters.enabledDefaultsKey | (Apple only) |
| phoneGroupSelector | string | (Android only) | phoneGroupSelector |
| liveTvEdgeSwipeOpensSidebar | bool | (Android only) | liveTvEdgeSwipeOpensSidebar |
| skipLoadingScreen | bool | (Android only) | skipLoadingScreen |
| appleTVChannelFlip | bool | (Android only) | appleTVChannelFlip |

Values (what Android writes; Apple maps to exactly these strings and numbers). On read, an unknown
value or a value of the wrong type is ignored and the local setting is left unchanged:
| Schema name | Values |
|---|---|
| selectedTheme | `"Aerio"`, `"Midnight"`, `"Sunset"`, `"Forest"`, `"Lavender"`, `"Monochrome"`, `"Light"` (Android AppTheme enum names, case sensitive) |
| appearanceMode | `"dark"` (default), `"light"`, `"system"` |
| defaultTab | `"LiveTV"`, `"DVR"`, `"Movies"`, `"TVShows"`, `"Settings"` (Android AppTab enum names); absent or `""` = Live TV |
| timeFormat | `"system"` (default), `"12"`, `"24"` |
| textScale, subtextScale | number 0.85 to 1.50 in 0.05 steps, default 1.0; readers clamp and snap |
| textContrast | number 0.0 to 1.0 in 0.1 steps, default 0.0; readers clamp and snap |
| guideProgramInfoButton | `"off"`, `"current"`, `"all"` |
| guideGroupSelector | `"pills"`, `"sidebar"` |
| phoneGroupSelector | `"sidebar"` (default), `"pills"` |
| guideSidebarLayout | `"overlay"` (default), `"shift"` |
| every bool row | JSON `true` or `false`, never a string |

Excluded from settings (own keys or device-local): `remoteControlMap`, `radioModeByDefault`,
`favoriteChannelIDs`, `favoriteOrder`, `channelGroupOrder*`, `hiddenChannelGroups` and siblings,
`defaultLiveTVView`, `streamBufferSize`, `networkTimeout`, `maxRetries`, `bgRefresh*`, `preferAVPlayer`.
Parity rule: an "(Apple only)" or "(Android only)" row is a parity gap to close, not a design choice;
until closed, the other platform round-trips it (6.2).

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
{"rows":[[1,"admin","Logan","none","",""],[7,"test1","Kids","directions","9f2c...64hex","b81e...32hex"]]}
```
Row: `[userId:int, username:string, displayName:string(max 40 B), pinType:"none"|"numbers"|"directions", pinHash:string, pinSalt:string, role:"admin"|"user"|"child"]`, cap 25 rows.
- `role` is the app-local role set by an Admin on the device (default: `"admin"` when the Dispatcharr user level is Admin, else `"user"`). `child` hides the switcher, the Profiles section, and every other profile name; leaving a child profile needs an Admin PIN.
- `pinHash` = lowercase hex SHA-256 of `pinSalt bytes || UTF-8 PIN` where the PIN is digits for
  numbers and the letters `U D L R` for directions (example `"UULR"`). Empty when `pinType` is `"none"`.
- `pinSalt` = 16 random bytes from the platform CSPRNG, lowercase hex, regenerated on every PIN set
  or change, unique per user.
- Non-admin devices never read this key (they cannot reach it through `me`). A profile signed in
  alone has no picker and no PIN prompt for itself on that device.

## 5. Profiles flow

1. Admin device: lists server users, adds profiles, writes `profiles` under the admin.
2. A second device signed in as the admin pulls `profiles`, then reads the admin user list
   (`GET /api/accounts/users/`, which returns each user's `api_key`) and adds the same profiles
   without typing anything. Only a device signed in as a non-admin user needs that user's password
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

### 6.3 Removals
Removal is absence from the array. There are no tombstones in v1. Android's local `removedAt` and
`unhiddenAt` fields stay local.

## 7. Cadence and errors

1. Pull all enabled keys: on launch, on profile switch, on return to foreground after 5 minutes or more, and every 15 minutes while foregrounded. One `GET users/me/app-data/` lists sizes first; only keys present are fetched.
2. Never write a key not read since launch (or since profile switch). A 404 `key_not_found` counts as read (empty).
3. Debounce writes: 5 s after the last local change per key; flush pending writes on background.
4. Skip a PUT whose compact JSON equals the last pushed body.
5. 413 `value_too_large` or `total_too_large`: trim by the order in section 8, retry once. If it fails again, stop writing that key until the next local change and show "Sync data too large" on the Dispatcharr Sync row in Settings.
6. 409 `max_apps`: do not create new keys; show "Sync storage on the server is full". Existing keys keep syncing.
7. 401 or 403: refresh the token per existing login flow; if it still fails, pause Dispatcharr Sync for that profile and show "Sign in again to sync".
8. 5xx or network errors: retry with backoff 30 s, 2 min, 10 min; keep the pending write.
9. Log with prefix `[DSYNC]` (key, bytes, status). Never log values, PIN hashes, or salts.

## 8. Size budget (heavy user)

Heavy user: 600 favorites, 10 collections of 40 channels, 300 progress entries, 100 reminders, 50 recents, 200 My List, 50 hidden
titles, 40 hidden groups, 60 ordered groups, 6 profiles. Envelope about 160 B per key.

| Key | Row estimate | Total | Under 32 KiB |
|---|---|---|---|
| favorites | 600 x 5 B (4-digit id plus comma) | 3.2 KB | Yes |
| recents | 50 x 19 B | 1.1 KB | Yes |
| progress | 300 x 85 B (ids 6 B each, ints, 30 B title) | 25.7 KB | Yes, about 6 KiB margin |
| progress worst case | 300 x 100 B (40 B titles, long ids) | 30.2 KB | Yes, tight |
| reminders | 100 x 95 B | 9.7 KB | Yes |
| watchlist | 200 x 24 B | 5.0 KB | Yes |
| hiddenTitles | 50 x 24 B | 1.4 KB | Yes |
| hiddenGroups | 40 x 14 B | 0.7 KB | Yes |
| groupOrder | 60 x 14 B | 1.0 KB | Yes |
| settings | about 60 names x 35 B, plus customCategories up to 4 KiB | 6.3 KB | Yes |
| remoteMap | about 20 entries | 0.8 KB | Yes |
| radioDefault | | 0.2 KB | Yes |
| profiles | 6 x 130 B | 1.0 KB | Yes |
| collections | 10 collections x (60 B header + 40 members x 5 B) | 2.8 KB | Yes |
| Total | | about 59 KB (worst case about 64 KB) | Under 128 KiB |

Trim order when a write would exceed a limit (applied per key, then across keys for total):
1. progress: drop finished rows, then oldest rows down to 200, then shorten titles to 20 B.
2. reminders: drop rows starting more than 14 days out.
3. recents: down to 25.
4. watchlist and hiddenTitles: oldest first down to 300 each.
5. settings: drop `customCategories`.
Favorites, collections, hiddenGroups, groupOrder, and profiles are never trimmed; at 1000 favorites
the key is still about 6 KB, and the collections caps (50 x 500 members) bound that key near 26 KB.

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
| ChannelCollection id, name, memberIds, placement (AppPreferences `channel_collections`, not in Drive) | collections row | Same conversion as Apple |
| Playlists, Credentials | not synced here | Stay on Drive |

## 11. README rows (both repos, same commit as the code)

Pangolin rules table: already covered by the existing `/api/accounts/*` prefix rule; no new row.

"Every Dispatcharr API path AerioTV uses" table:
| Path | Why AerioTV calls it |
|---|---|
| `/api/accounts/users/me/app-data/` | Lists AerioTV's synced data keys and sizes for the signed-in profile (Dispatcharr Sync) |
| `/api/accounts/users/me/app-data/<key>/` | Reads, saves, and clears one Dispatcharr Sync category (keys start with `app.molinete.aerio.`) |
