# Dispatcharr Sync schema (v3)

Status: implemented on both platforms. Corrected to match the Apple and Android code on 2026-11-11
(Apple `d75589d`, Android `44a76a7d`; profiles, merge, reader rules, cadence, and errors); where the
two apps still differ, the text says so. Sections 4.12 and 6.2 describe these after this release's
fixes: the manual add of a roster user and its onboarding undo (Apple `6be95f7`, Android
`8936375e`), Android's no-session push (Android `7e98feca`), the undo of every other roster add
(Apple `8d7a23e`, Android `ccf1ef42`), the `profiles` pause while a profile is held (Apple
`866e593`, with its refinements in `807f3bd`; Android `81c746c7`), the undo of an add made during
that pause (Apple `cf59027`, Android `ccf1ef42`; after the pause, of one that took its roster row:
Apple `90d6006`, Android `c59716ce`), the hold of every non-default profile, keyless ones included
(Apple `4ecddec`, Android `ab45038e`), Cancel on "PIN Required" removing only the add that opened
it (Apple `cf59027`, Android `0839476b`), Android's onboarding PIN step right after each add or
batch (Android `db467674`), and the saved server copy discarded on a server address change
(section 6.2; Apple `0d67843`, Android `c48fbef9`).

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
v3 note (2026-11-05): the key is named for the signed-in Dispatcharr user, `<user>.aeriotv`
(section 2.1), instead of `app.molinete.aerio`. The value is unchanged, so `schemaVersion` stays 3.
The first device on the new release moves the record once (section 6.5).

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
| Endpoints | `GET/PUT/DELETE /api/accounts/users/me/app-data/<key>/`, `GET /api/accounts/users/me/app-data/` (list keys and sizes: `{"limits":{...},"total_bytes":N,"apps":[{"key","bytes"}]}`) |
| Methods | GET of a missing key: 404 `key_not_found`. PUT: the raw JSON object as the body with `Content-Type: application/json` (other content types get 415); 200 with the stored value on create and on replace. DELETE: 204, also for a key that does not exist |
| Admin cross-user | `/api/accounts/users/<id>/app-data/<key>/` (user_level >= 10, or the user's own id). Server admins can read and write any user's keys through it, roster PIN hashes included. AerioTV never uses it |
| Key pattern | `^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$` |
| Limits | 25 keys per user, 128 KiB per key (compact UTF-8 JSON), 1 MiB total per user, depth 8 (Dispatcharr dev c1920131, 2026-10-18; one database row per key). A Content-Length over 132,096 bytes (128 KiB plus 1024) gets 413 `body_too_large` first. Servers before that commit cap at 32 KiB per key and 128 KiB per user and answer 413 the same way |
| Value | Must be a JSON object. PUT replaces the whole value. No PATCH, no ETag, no versioning |
| Concurrency | Last writer wins (server serializes with a row lock) |
| Visibility | Any credential of a user can read every key of that user; any admin can view and clear any user's data in the web UI |
| Errors | `{detail, code}`: 400 key_invalid, value_not_object, value_has_nul, value_too_deep, value_not_serializable, invalid_content_length; 413 value_too_large, total_too_large, body_too_large; 409 max_apps; 403 forbidden; 404 key_not_found (GET only), user_not_found (admin path). Plain `{detail}` without `code` for 401, 405, 415, and malformed JSON |
| Auth throttles | Failed API-key attempts: 10 per minute per client IP (sliding window). After that every API-key request from that IP gets 429 with `Retry-After`, valid keys included, until the oldest failure is a minute old. Password logins (`/api/accounts/token/`): 3 per minute per IP, successes included. JWT auth runs before API-key auth, so a request must not carry a Bearer header and a key together |

## 2. Keys

ONE App Data key, `<user>.aeriotv` (section 2.1), holds every category as a sub-object (section 3): settings,
profiles, reminders, watchlist, hiddenTitles, hiddenGroups, groupOrder, collections, remoteMap,
radioDefault, tmdbKey, favorites, recents, progress, and syncProviders (section 10b). It is written with the profile's own token to
`users/me/app-data/<user>.aeriotv/`. Before 2026-11-05 the key was `app.molinete.aerio` (the
legacy key, moved by section 6.5); the v1 and v2 key names below keep that legacy prefix.

### 2.1 Key name
`<user>` comes from the signed-in Dispatcharr username, read once per sync session with
`GET /api/accounts/users/me/` using the same credential as the App Data calls (the base user's or
the active profile's own key). The rule, identical on both platforms:

1. Take the username's UTF-8 bytes.
2. ASCII `A` to `Z` become lowercase. `a` to `z`, `0` to `9`, `_`, `.`, and `-` stay.
3. Every other byte becomes `-` plus two lowercase hex digits (percent-encoding with `-` in place of
   `%`, because the server key pattern `^[A-Za-z0-9][A-Za-z0-9._-]{7,63}$` rejects `%`).
4. If the result does not start with a letter or digit, prefix `u`.
5. Cut to 46 characters, so `<user>.aeriotv.favorites` fits the 64 the server allows.
6. Append `.aeriotv`. An empty username has no key; sync waits for the next attempt.

Two usernames that map to one name cannot mix data: App Data is stored per user. The v2 three-key
layout under the new name would be `<user>.aeriotv`, `<user>.aeriotv.favorites`, and
`<user>.aeriotv.progress`; v3 writes only `<user>.aeriotv`.

Test vectors (Apple `Scripts/dsync-tests`, Android `DsyncV2Test.userKeyDerivation`; the suites use another mixed-case name where this table has `alice`):

| Username | Key |
|---|---|
| `alice` | `alice.aeriotv` |
| `ADMIN` | `admin.aeriotv` |
| `john.doe-1_x` | `john.doe-1_x.aeriotv` |
| `a@b.com` | `a-40b.com.aeriotv` |
| `first+tag` | `first-2btag.aeriotv` |
| `_admin` | `u_admin.aeriotv` |
| `José` | `jos-c3-a9.aeriotv` |
| 60 x `a` | 46 x `a` then `.aeriotv` |
| empty | none |

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
| `app.molinete.aerio.profiles` | Profile roster (written by Admin and Standard profiles, section 4.12) | Yes | On | Device pickers (section 5) |
| `tmdbKey` (v3 only, no v1 key) | TMDB API key (section 4.13) | Yes | On, no Sync Categories row | Owner exception (2026-11-13): the one secret synced here, so a user's key reaches all their devices |

Device-local, never synced here (nor through iCloud or Drive), and why:
- Kept Live / background Radio auto-start: tied to one device's power and network.
- Buffer size, network timeout, max retries, LAN URL, home SSID, background refresh schedule: per-device network.
- Display matching (Match Content Resolution, Match Frame Rate, Startup Refresh Rate), Surround Sound Passthrough, Auto-Rotate: per-device display and audio hardware.
- DVR storage cap, DVR storage folder, Keep Device Awake: per-device storage.
- Learned remote buttons: tied to one physical remote.
- Debug and developer options, update checks: per install.
- Playlist URLs and credentials: Drive and iCloud Keychain only, never Dispatcharr (section 10).
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
applies its category (one exception: Apple still applies a pulled `profiles` category while its row
is Off, section 4.12). The old category toggles remain the defaults and the group-level All devices
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

When a device rebuilds a category it writes that sub-object's `updatedAt` as now and `deviceId` as
its own (the `profiles` stale-device rule in 4.12 reads it).

Reader rules:
1. Missing envelope fields or wrong types: the key is malformed; log `[DSYNC] malformed <key>` and do not apply it. A sub-object missing `updatedAt` or `data`, or with a non-object `extra`, is malformed the same way, alone; a missing sub-object `deviceId` falls back to the envelope's. Before a PUT (section 7, item 4a) both apps treat a malformed server value like an absent one and write over it from their last good copy (a copy read from the same server: a server address change discards it, section 6.2); Apple also builds its next `profiles` write with no server rows, which drops the rows of users it has no local profile for. A writer that emits a wrong type therefore costs other devices' data.
2. `schemaVersion` greater than the reader knows: ignore the key, log `[DSYNC] skip <key> v<n> > v<known>`, and do not write that key until the app updates (writing would downgrade it). The scalar envelope checks (`schemaVersion`, `deviceId`, `platform`, `appVersion`, `updatedAt`) run first, so a too-new value whose scalar members changed reads as malformed; `categories` is checked after the version, so a too-new value without it reads as too new.
3. `schemaVersion` lower than 3 under `<user>.aeriotv`: malformed (rule 1), not upgraded. The older layouts (v1 per-category keys, the v2 three-key layout, and v2 or v3 values under the legacy `app.molinete.aerio`) are read only by the migration (sections 6.4 and 6.5). Older builds read the v3 key as a higher `schemaVersion` and skip it (rule 2).

Wire types (both apps parse numbers from the literal text):
1. Every number in the envelope and in `data` is a JSON integer literal. `3.0` or `1.79e9` reads as
   absent, and fields read as 32-bit integers (`schemaVersion`, ids, `order`) must fit 32 bits.
   Only settings values (section 4.9) may be doubles.
2. Envelope: integer `schemaVersion`; string `deviceId`, `platform`, and `appVersion`; ISO
   `updatedAt`; object `categories`. All required.
3. Sub-object: ISO `updatedAt` and object `data` required; string `deviceId` and object `extra`
   optional.
4. Object member names are case sensitive (`schemaVersion`, not `schemaversion`).

Encoding: compact JSON (no spaces), UTF-8, no NUL characters, max nesting depth 7 in practice
(`profiles` avatars and `collections` members) against the server's limit of 8: a new category must
not nest deeper than the existing ones.
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
{"rows":[[1042,1760731200,1760734800,"Program Title","Channel Name"]]}
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
| selectedTheme | `"Aerio"`, `"Midnight"`, `"Sunset"`, `"Forest"`, `"Lavender"`, `"Monochrome"`, `"Light"`, `"Custom"` (Android AppTheme enum names, case sensitive). Since 2026-11-05 the UI shows `"Light"` as Slate; the wire value stays `"Light"` |
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
storage, learned remote buttons, debug and update options, `tmdbApiKey` (its own category, `tmdbKey`,
section 4.13), `preferAVPlayer`.
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

### 4.12 profiles (Admin and Standard profiles)
Read and written by any session whose active profile is Admin or Standard, under that profile's own
user (`users/me/`), so each full-access user's key carries its own copy of the roster. A Child
session fetches the key with every other category but never applies or writes `profiles`; it
round-trips it. A device whose Sync Categories item Profiles is Off does not write it; Android does
not apply it either, while Apple still applies pulled rows and tombstones. The rows list the
writer's local profiles it can match to a server user id: from `GET /api/accounts/users/` when
the base login and the active profile are server admins, otherwise from the local profiles' own user
ids (read from `/me/` as each user); a profile with no known user id is left out. When the users
list call fails, Apple falls back to the local ids and Android writes no roster that time. While any
profile on a playlist is held after a server address change (every non-default profile of the
playlist, with or without a stored sign-in, until a same-server check passes or the profile signs in
again; Apple `4ecddec`, Android `ab45038e` for the profiles with none), both apps pause `profiles`
for that playlist in both directions: no local rows or tombstones are pushed (a PUT carries the
server's `profiles` value unchanged, or leaves it out when the server had none), and no pulled rows,
tombstones, or suggestions are applied. Every other category syncs as usual. Such a PUT does not
clear the roster's pending mark. Removing a held profile writes no tombstone. A profile added while
paused is a plain add that takes its username's roster row, if any, with that row's stamp, at the
first pull after the pause ends (a row with no valid PIN leaves a PIN set on the device after the
add in place); undoing such an add, on any path, writes no tombstone, as for a roster add, because
the device could not see the roster. That first pull ends the mark (a pull that applies no roster
keeps it): one that took its row still undoes as a roster add, and one with no row undoes as a
plain add (Apple `90d6006`, Android `c59716ce`). The pause ends when nothing on that playlist is
held.
```json
{"rows":[[1,"alice","Alice","none","","","admin",1760724245,{},0],[7,"sam","Sam","directions","9f2c...64hex","b81e...32hex","child",1760730000,{"icon":"paw","color":"orange"},1]],"removed":[["lee",1760800000,8]]}
```
Row: `[userId:int, username:string, displayName:string(max 40 B), pinType:"none"|"numbers"|"directions", pinHash:string, pinSalt:string, role:"admin"|"user"|"child", updatedAt:int, avatar:object, order:int]`, cap 25 rows.
- Encoding: rows dedupe by `userId`; matching a row to a local profile, tombstones, and suggestions
  use the lowercased username. `displayName` is cut to 40 UTF-8 bytes on a code point boundary.
  `pinHash` and `pinSalt` are `""` when `pinType` is `none`. An unknown local role is written as
  `user`. Trailing positions after 9 are carried over from the previous server row with the same
  `userId`. Rows for users this device has no profile for are re-emitted re-encoded: an older
  writer's absent order becomes 0, absent avatar `{}`, and absent role `user`.
- Decoding: `userId` (integer) and `username` (string) are required, and a row that is not an
  array or lacks them makes the whole category malformed. An unknown `pinType` reads as `none`; an
  unknown or absent `role` reads as `""` (keep the local role); an absent or non-integer
  `updatedAt` reads as 0; an absent or negative `order` reads as -1.
- `updatedAt` = Unix seconds of the last change to that row on the writing device: rename, avatar,
  role (including a role that follows a server level change), PIN set, change, remove, or reset,
  order, an Add Profile (a roster add keeps the source row's stamp instead, below; creating the
  default profile and onboarding's Child choice do not stamp), remove (with its tombstone), a setup
  apply (both apps stamp the profiles it adds; Android also stamps the default entry), and a
  stripped-row repair. A v1-to-v2 PIN re-hash and a synced PIN import change the PIN without a
  stamp. A roster add keeps the source row's stamp (now when it is 0). A manual add (username and
  password, or an API key) of a user who has a roster row finishes as a roster add: it applies the
  row and keeps its stamp. Writes carry each row's stored stamp, never now; a row with no stored
  stamp takes the server row's stamp, else now. Absent (older writer) reads as 0.
- `order` = the profile's list position, 0 first, set by an Admin or Standard profile (picker Move
  Left, Move Right, and Move to Front; Settings Move Up and Move Down on phones and tablets, and a
  hold-Select pick-up on TVs). Every list of profiles (pickers, switcher, Settings) uses it; the
  default profile moves like any other. Writers always write the current list index (never -1,
  never absent; an index can skip a profile that has no known user id). Absent or negative (older
  writer) = keep the local position; a profile never moved sorts after moved ones in insertion
  order (default first). A move rewrites every local position and stamps `updatedAt` on every row
  whose stored order changed, which includes never-moved rows (stored -1), so the first move stamps
  every row; the per-row merge applies it.
- `avatar` = `{"icon":string, "color":string}`, either member optional; `{}` = the default. App
  defined (Dispatcharr's `avatar_config` has no defined shape, the web UI ignores it, and
  `PATCH /api/accounts/users/me/` drops it, so it is not used).
  - `icon`: `person`, `face`, `child`, `paw`, `cat`, `fish`, `star`, `rocket`, `music`, `soccer`,
    `gamepad`, `movie`. Absent or unknown = the display name's first letter.
  - `color`: `teal` #1AC4D8, `blue` #3B82F6, `orange` #FB923C, `ember` #C2410C, `green` #22C55E,
    `purple` #8B5CF6, `slate` #94A3B8, `sea` #2B7A86 (theme palette). Absent or unknown = the
    default: index (sum of the UTF-16 code units of the trimmed, lowercased username) mod 8 in this
    order (Android trims all whitespace, Apple spaces and tabs).
  - Position absent (older writer) = keep the local avatar. An Admin or Standard profile edits any
    profile's avatar; a Child edits its own.
- `removed` (optional; absent = none) = removal tombstones: `[username:string (lowercased),
  removedAt:int (Unix seconds), userId:int (optional)]`, one per username. A removal stamps a local
  tombstone and the next write adds it to `removed`. Both apps write their own tombstones without
  `userId`; a `userId` is carried forward only when a server entry already had one. An entry whose
  `removedAt` is not a positive integer is dropped on read. Every writer carries the union of the server
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
- Merge is PER ROW, not last writer wins for the whole key: on every pull (and on the read-merge
  before every write), a pulled row replaces the local displayName (when not blank), role
  (resolved against the local server level), avatar (when present), order (when 0 or more), and
  PIN only when its `updatedAt` is STRICTLY newer than the local row's stamp; the local stamp then
  becomes that row's `updatedAt`. Otherwise the local row stays and goes back up on the next write.
  PIN from a newer row: `numbers` or `directions` with a 64-character hash and a 32-character salt
  replaces the local PIN; a wrong hash or salt length leaves the local PIN alone; `none` (or an
  unknown type, which reads as `none`) removes the local PIN unless it is a v1 record not yet
  re-hashed. A writer keeps rows it does not have locally unless a tombstone covers them.
- Name and avatar claim: only an explicit local rename or avatar change claims displayName and
  avatar, so a profile created by onboarding, a QR login, or any other path that never customized
  them takes the server row's displayName and avatar on the next pull whatever the stamps say (logs
  `[DSYNC] profiles: adopted synced name/avatar for <user>`), unless the server row itself looks
  stripped, and its writes keep the server's values; with no server row it keeps its username as
  the display name. "Stripped" = a blank displayName or one equal to the username ignoring case,
  with an absent or default avatar. Three guards: for 60 s after a roster add, an outgoing row that
  would be stripped keeps the server row's name, avatar, and order when the server row is not
  stripped; when the server row looks stripped, the local row is not, and the server row is at most
  600 s newer, the device re-stamps and re-sends its local row (a repair); and when the local row is
  stripped, the server row is not, and the local stamp is at or above the server row's, the server
  row applies in full (displayName, role, order, avatar, and PIN) and the local stamp becomes the
  server row's `updatedAt`, even when that lowers it.
- Undo in onboarding's Add Profiles step: undoing a roster add (a profile added from a roster
  suggestion, or a typed add that finished as a roster add because that user has a roster row)
  removes it on this device only (no tombstone, no push, stamps cleared), and the row stays offered
  as a suggestion; undoing a plain add made in that step (a user with no roster row) is a normal
  removal and writes a tombstone. Cancel on the "PIN Required" step after an add while a Child
  exists follows the same rule, and removes only the profile or profiles added by the action that
  opened that step; every other profile still waiting for a PIN stays as it was (Apple `cf59027`,
  Android `0839476b`). An add made during a roster pause undoes like a roster add, with no
  tombstone (Apple `cf59027`, Android `ccf1ef42`), and still does after the first pull once the
  pause has ended when it took its roster row there; one with no row then undoes like a plain add
  (Apple `90d6006`, Android `c59716ce`). A remove from Settings writes a tombstone, except for a
  profile held after a server address change (the pause, at the top of 4.12).
- Timing: a profile mutation marks the key dirty and PUTs after a 1 s debounce (other keys 5 s). A
  playlist-level pending mark survives a relaunch and a session that cannot write, and clears only
  after a successful PUT (or an unchanged acknowledgement). Opening "Who is watching?", the
  switcher, or Add Profile (and returning to the foreground) runs a pull of `profiles` only, at most
  once per 30 s per playlist, then sends a pending local change. With a live session both apps
  re-read 2 s later. With no live session the picker pull is read only: Android peeks and re-reads
  2 s later, Apple peeks once, and neither pushes from it. A profile change made while no session
  exists is pushed by Android after the 1 s debounce under the last-active profile, only when a
  list call made in that push succeeds and shows no legacy `app.molinete.aerio` or
  `app.molinete.aerio.*` key (then a GET and merge first; otherwise the change stays pending for
  the next session's move, section 6.5); Apple leaves it to the next session.
- Catalog semantics: the rows are the profiles AVAILABLE to devices, not a mandate. A pull never
  creates a local profile. Metadata (displayName, role, avatar, order, PIN) merges only into
  profiles already present on the device; rows for users with no local profile are offered as
  suggestions under "From your other devices" (onboarding Add Profiles step, after the Dispatcharr
  Sync step has pulled, and Settings > Playlists > (playlist) > Add Profile) and are added only by
  an explicit choice on that device. Adding one uses the normal credential path (admin-listed
  `api_key`, else a typed password or API key) and then applies the row's role, PIN, avatar,
  displayName, and order. A Child row needs every Admin and Standard profile on the device to hold a PIN first. Tombstones apply on
  every device. Each pull logs `[DSYNC] profiles: N roster rows available, not added (opt-in)`.
- Stale-device rule (only when the server row list is not empty): a writer does not send a local
  row the server list lacks when that row has no unsent local change (its `updatedAt` is at or
  before the newest local row stamp recorded when this device's last PUT, or an unchanged
  acknowledgement, landed) and either its `updatedAt` is older than the server `profiles`
  sub-object's `updatedAt`, or every local row is older than the server's newest row by more than
  the 90-day tombstone window. The writer logs
  `[DSYNC] profiles: local row <user> older than server roster, not re-sent` (Apple leaves out the
  username) and adopts the server list; the local profile stays on that device until a tombstone or
  the user removes it.
- `role` is the app-local role and follows the user's Dispatcharr access (owner rule 2026-10-29): a Dispatcharr admin (superuser, staff, or user_level 10) is always `"admin"` and is never offered a role picker; any other user is `"user"` (shown as Standard) or `"child"`, chosen by an Admin or Standard profile, and is never offered Admin. When a refresh of `/api/accounts/users/me/` reports a changed level the role follows it (demotion: Admin to Standard; promotion: Standard or Child to Admin) and logs `[PROFILES] server role changed for <username>: <old> -> <new>`. Inside AerioTV `admin` and `user` (shown as Standard) are identical (owner rule 2026-10-29): the label only reflects the user's Dispatcharr access, and both can add, remove, and reorder profiles, change roles, reset other profiles' PINs, and write this key. Only actions that call Dispatcharr admin endpoints (Channel Profiles, Enable API access, the server users list) check the server admin flag. `child` hides the switcher, the Profiles section, and every other profile name; leaving a child profile needs a PIN from an Admin or Standard profile.
- While any profile is a Child, every Admin and Standard profile holds a PIN (Numbers or Directions): setting a role to Child first walks the acting profile through each missing PIN (its own first, then a temporary PIN per other profile); an Admin or Standard profile added while a Child exists sets its PIN right after the add, or right after an onboarding "Add selected" batch, and onboarding's Continue asks for no adds (Android `db467674`; cancel undoes only the add that opened the step, Apple `cf59027`, Android `0839476b`; a roster add's or a pause add's undo follows the Undo bullet); removing such a PIN is denied ("While a Child profile exists, Admin and Standard profiles keep a PIN."), and a reset sets a temporary PIN instead of clearing it.
- `pinHash` = lowercase hex SHA-256 of `pinSalt bytes || UTF-8 PIN` where the PIN is digits for
  numbers and the letters `U D L R` for directions (example `"UULR"`). Empty when `pinType` is `"none"`.
- `pinSalt` = 16 random bytes from the platform CSPRNG, lowercase hex, regenerated on every PIN set
  or change, unique per user.
- A Child session never applies this category (see the top of 4.12). Each user's key holds only
  the roster its own Admin or Standard sessions wrote. A profile signed in alone has no picker and
  no PIN prompt for itself on that device.
- Device Admin PIN (device-local, never synced, not in this key): when onboarding signs in as a
  Standard Dispatcharr user, "Who is this profile for?" offers Standard (default; wire value `user`) or Child. Child sets a
  Device Admin PIN (Numbers or Directions) tied to no profile, and the profile becomes a Child: a
  kid-only device. Every "Enter a PIN from an Admin or Standard profile" gate (leaving a Child, Manage Profiles, Add Profile,
  role changes, removing a Child) accepts the Device Admin PIN as well as any Admin or Standard profile's PIN,
  and it stays valid after an Admin profile is added. It is changed or removed in Settings >
  Playlists > Profiles (Admin and Standard profiles) or Manage Profiles behind the PIN, both needing the current
  Device Admin PIN; it stays while any profile is a Child and no Admin or Standard profile has a PIN.

### 4.13 tmdbKey (owner exception, 2026-11-13)
```json
{"apiKey":"0123456789abcdef0123456789abcdef"}
```
- `apiKey`: the user's TMDB credential as entered, trimmed (a v3 API key or a v4 read access token);
  `""` = no key. A missing `apiKey` reads as `""`; any other type is malformed.
- The one secret Dispatcharr Sync carries. Every password, Dispatcharr API key, token, and other
  secret stays out (section 9).
- Gate: syncs whenever Dispatcharr Sync is on, for every profile role. No Sync Categories row. Never
  in the iCloud or Drive snapshots (Apple keeps the key in the iCloud Keychain; Drive does not carry
  it, section 10.2), never forced, never trimmed.
- Writes: a device writes the category when its user saves or clears the key on that device, and
  seeds an absent category from its own key. A device with no key never creates the category: a fresh
  `""` would read as a clear newer than every other device's key. A key that reaches an Apple device
  through iCloud Keychain is not an edit there; the device that edited it sends it.
- Merge: newest edit wins (section 6.1, rule 3, by the category's `updatedAt`). When a newer remote
  value differs from the device's key, the device keeps and sends its own value if its last local
  edit time (the last save, clear, or applied pull, in Unix seconds) is later than that `updatedAt`.
  With no known local edit time, a key beats a remote clear, and otherwise the remote value applies.
  Applying `""` clears the key on the device; applying a pull records its `updatedAt` as the local
  edit time.
- One key per device: on a device with several profiles, the key in use is the one last saved or
  applied there, and a profile whose user has no `tmdbKey` yet is seeded from it.
- Logs never carry the key: `[DSYNC] tmdbKey: set from the server`, `cleared from the server`, or
  `kept this device's key (newer than the server's clear); sending it`.
- The saved server copies on the device (section 6.2) never hold the key: `apiKey` is stored as
  `apiKeySha256`, its lowercase hex SHA-256, in the member's place, and copies saved before this
  rule are rewritten at startup. A read puts the device's own key back when the digest matches;
  otherwise the copy reads without `apiKey`, and a bucket copy without the `tmdbKey` category, so a
  digest is never written to the server. A write re-emits the other categories from the bucket as
  this session last read or wrote it, held in memory, so another device's newer key round-trips.

## 5. Profiles flow

1. An Admin or Standard device adds profiles (from the server users list when its base login and
   active profile are server admins, otherwise by typed credentials) and writes `profiles` under its
   active user's own key.
2. A second device signed in as that user pulls `profiles` and offers its rows as suggestions;
   for each one the user picks, it reads the admin user list (`GET /api/accounts/users/`, which
   returns each user's `api_key`) and adds that profile without typing anything. Nothing is added
   without a choice. Only a device signed in as a non-admin user needs that user's password
   or API key typed. Credentials are still never written to App Data.
3. Each profile's own data lives under its own user. The device switches tokens on profile switch.
4. Wrong-PIN backoff (5 tries, then 30 s doubling) is device-local state and is not synced.

## 6. Merge, round-trip, and versioning

### 6.1 Merge rule
Per category, by the category sub-object's `updatedAt` (section 3), never by the envelope's.

1. On pull, the remote category is newer when its `updatedAt` is later than the local copy's
   last-applied `updatedAt`, or equal with a higher `deviceId` string (deterministic).
2. Newer remote, no unsent local change: apply remote as a full replace of that category.
3. Newer remote with an unsent local change: the row categories (favorites, recents, progress,
   collections, reminders) merge (favorites: local order first, then server ids this device lacks;
   collections and reminders: union by identity; progress and recents: the newer row per id by row
   `updatedAt` or `watchedAt`), then caps apply. Every other category keeps the local change when
   it is newer than the remote `updatedAt` (`kept local`), else takes remote.
4. The same row merge runs in the read before every write (section 7, item 4a). This keeps two
   devices watching different titles from erasing each other.
5. `profiles`: merged per row on every pull, by each row's own `updatedAt`, with tombstones
   (section 4.12).

### 6.2 Round-trip (PUT is a full replace)
Each platform stores the raw last-pulled JSON for every key and, on write:
1. Starts from that raw object.
2. Replaces only the fields it owns (the `data` members and rows this document defines and it supports).
3. Re-emits untouched: unknown top-level `data` members, unknown settings names in `settings.v`,
   trailing row positions it does not know, the whole `remoteMap` on phones, and the envelope `extra`.
Settings rows it does not support (for example Android today for `categoryColor.*`) are therefore
preserved unchanged in value and type.

The saved copy belongs to the server it was read from. When a playlist's server address changes
(the scheme, host, or port of its server URL or local URL, on every path that changes them), both
apps discard the saved copy for every profile of that playlist before anything is sent to the new
address (Apple `0d67843`, Android `c48fbef9`), and log `[PROFILE-HOST] sync
copy discarded playlist=<id>`. The first write there follows section 7, item 4a: a successful read
rebuilds the copy from that server, and a 404 means the PUT carries only this device's own data. A
path-only change keeps the copy, and local data and settings are never discarded.

### 6.4 Migration from v1 and v2
On the first v3 session, if any other `app.molinete.aerio.*` key exists (the 13 v1 keys, or the v2
`app.molinete.aerio.favorites` and `app.molinete.aerio.progress` keys) or `app.molinete.aerio` still
holds a v2 value, the app reads all of them and merges PER CATEGORY by `updatedAt` (ties: higher
`deviceId`) into the single key; each category keeps its `updatedAt`, `deviceId`, `data`, and
`extra`. It PUTs the single key, then DELETEs every other `app.molinete.aerio.*` key. If the PUT
fails, the old keys stay and migration runs again on the next pull. Since 2026-11-05 this merge is
part of the key rename (section 6.5), writes `<user>.aeriotv`, and logs the 6.5 line.

### 6.5 Key rename to `<user>.aeriotv` (2026-11-05)
After the list call, if `<user>.aeriotv` is not listed and any legacy key is (`app.molinete.aerio`
or any `app.molinete.aerio.*`), the app GETs every legacy key, merges them as in section 6.4 (a
legacy v3 value alone moves unchanged), PUTs the result to `<user>.aeriotv` (413 walks the section 8
trims), then DELETEs every legacy key (404 counts as gone). Log
`[DSYNC] migrated key (R read, D of N old keys removed)`, never a value, key, token, or URL. A
5xx or network failure stops the pull and the rename runs again next time; a PUT refused for
another reason keeps the old keys. When no legacy value decodes (every one malformed or too new),
nothing is PUT and the legacy keys are still deleted. Once `<user>.aeriotv` is listed the rename
never runs again, so whichever device syncs first moves the record once and every other device
reads the new key. It follows that no client may create `<user>.aeriotv` while legacy keys it has
not merged are listed, and no client writes any `app.molinete.aerio*` key any more.
Every write goes to `<user>.aeriotv`. The setup probe reads `<user>.aeriotv` and falls back to the
legacy key while it is absent; the QR restore offer counts either key as present. The API calls
are unchanged: the same `users/me/app-data/` endpoints, plus the `users/me/` read the app already
makes; only the key in the path differs.

### 6.3 Removals
Removal is absence from the array, except `profiles`, which carries removal tombstones in its
`removed` list (section 4.12). Android's local `removedAt` and `unhiddenAt` fields stay local.

## 7. Cadence and errors

1. Pull all enabled categories: on launch, on profile switch, on return to foreground after 5 minutes or more, every 15 minutes while foregrounded, and after the network comes back. Each sync session first reads the username (`GET users/me/`, section 2.1), then one `GET users/me/app-data/` lists sizes, then one GET of `<user>.aeriotv` when present. That GET is skipped when the listed byte size equals the size last fetched and the last pull was under 60 s ago. A category absent from the key counts as read (empty). The `profiles` picker-open pull is in section 4.12.
2. Never write a key not read since launch (or since profile switch). A 404 `key_not_found` counts as read (empty).
3. Debounce writes: 5 s after the last local change per key (1 s for `profiles`); flush pending writes on background and before a profile switch.
4. Skip a PUT when the category's `data` equals the server copy fetched just before it (item 4a); the log reads `status=unchanged` and the write counts as acknowledged.
4a. Every PUT first GETs the key: row categories (favorites, recents, progress, collections, reminders) merge the server rows into local state, whole-value categories keep the newer side, `profiles` merges per row, and all other categories are re-emitted at their server value. An unsent local change is never overwritten by a pull without that merge. A malformed server value is treated as absent and written over (section 3, reader rule 1).
5. No app-side byte guard: the full value is sent. On 413 (`value_too_large`, `body_too_large`, or `total_too_large`), apply the next trim step of section 8 (one step per retry, log each) and PUT again. After the last step still fails, stop writing until the next local change and show "Sync data too large" on the Dispatcharr Sync row in Settings.
6. 409 `max_apps`: do not create new keys; show "Sync storage on the server is full". Existing keys keep syncing.
7. 401 or 403:
   1. On the username read (`users/me/`), which comes first: the attempt ends quietly and sync waits for the next one. A revoked key therefore never reaches the pause below; the app's rejected-key prompt (item 10) covers it.
   2. On the list call: pause Dispatcharr Sync for this session (in memory) and show "Sign in again to sync". The next good list call clears the pause.
   3. On a PUT: pause the same way. Android first re-reads the stored key and retries once when it changed.
   4. On a key GET: a failed read, not a pause.
8. 5xx or network errors: retry with backoff 30 s, 2 min, 10 min; keep the pending write.
9. Log with prefix `[DSYNC]` (key, bytes, status). Never log values, PIN hashes, or salts.
10. HTTP 429 and rejected API keys are handled below sync, by the request gate in front of every Dispatcharr call. A 429 parks the server (host and port) until `Retry-After` passes (default 60 s, cap 120 s), and every request fails locally meanwhile. A key the server rejected (`Invalid API key` or `User inactive`) is held: every request carrying it fails locally until the key changes or a slow re-check (1, 5, and 15 minutes, then every 30 minutes) succeeds. Sync sees both as network failures: the pull stops, or the PUT backs off. Reason: the server allows 10 failed API-key attempts per minute per client IP and then refuses every key from that IP (section 1.1).

## 8. Size budget (heavy user)

Heavy user: 600 favorites, 10 collections of 40 channels, 300 progress entries, 100 reminders, 50 recents, 200 My List, 50 hidden
titles, 40 hidden groups, 60 ordered groups, 6 profiles. One envelope about 160 B, about 90 B per
category sub-object (13 x 90 B = 1.2 KB).

| Key | Contents | Total |
|---|---|---|
| `<user>.aeriotv` | every category below plus sub-objects | about 60 KB (worst case about 63 KB) |

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
| tmdbKey | one key (32 characters, or a token of about 250) | 0.4 KB | Yes |
| profiles | 6 x 130 B rows plus up to 25 x 30 B `removed` tombstones | 1.8 KB | Yes |
| collections | 10 collections x (60 B header + 40 members x 5 B) | 2.8 KB | Yes |
| Total | | about 59 KB (worst case about 62 KB) | Under 128 KiB (new per-key cap) |

Trim order on a 413, one step per retry (no trimming before the first PUT):
1. progress: oldest rows down to 200, then down to 100.
2. recents: down to 25.
3. watchlist and hiddenTitles: oldest first down to 300 each, then down to 150 each.
4. favorites: down to 500 (from the end of the list).
Reminders, settings, collections, hiddenGroups, groupOrder, profiles, remoteMap, radioDefault, and
tmdbKey are never trimmed. After the last step still fails: "Sync data too large".

## 9. Security

- Nothing secret is stored but the TMDB API key (section 4.13, owner exception 2026-11-13). Admins can
  read every key in the Dispatcharr web UI and through `/api/accounts/users/<id>/app-data/<key>/`, and
  any credential of a user can read all of that user's keys. That is why credentials are never stored
  here, by decision (2026-11-10).
- Never stored: passwords, Dispatcharr API keys, JWTs, refresh tokens, playlist URLs, LAN URLs, SSIDs, raw PINs, or any other secret.
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
| Keychain `tmdbAPIKey` (iCloud Keychain) | tmdbKey.apiKey | Not in iCloud KVS; `tmdbAPIKeyEditedAt` (UserDefaults, Unix seconds) holds the last local edit time |
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
2. Dispatcharr Sync: one device-wide switch (stored as `dispatcharr_sync_enabled` on both platforms), Settings > Sync > Dispatcharr Sync. It applies to whichever profile is active; each profile still syncs under its own user.
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
Profiles, remoteMap, radioDefault, and tmdbKey are not forced.

Mirror details (2026-11-01). Every shared Drive file applies with replace
semantics for this choice. Preferences: a setting, recents list,
collection, hidden group, or group order the Drive copy does not carry
goes back to its default, so local holds the Drive key set. Row files:
the backup rows apply, then a local row the backup does not carry is
removed (favorites and progress rows deleted, reminders deleted with their
alarm canceled, watchlist and hidden title rows tombstoned so the removal
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
Categories item is not Off (`DsyncManual.keys`); Profiles, remoteMap,
radioDefault, and tmdbKey are never forced, and an Off item neither pushes nor pulls.
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
| `/api/accounts/users/me/app-data/<key>/` | Reads, saves, and clears one Dispatcharr Sync category (the key is `<username>.aeriotv`; older releases used `app.molinete.aerio`, moved once) |
