# AerioTV v1.6.22 Fix Report

Prepared for Codex review.
Branch from: v1.6.21 (shipped).
Build state at time of writing: iOS Debug + tvOS Debug both `BUILD SUCCEEDED`.
Em dashes added in diff: 0.

This report captures every change made between v1.6.21 and v1.6.22.
The work spans three threads:

1. **User-reported bugs** (Freyguy1975, jesmannstl, jexhammer).
2. **Architectural overhaul** of Dispatcharr-API EPG, driven by the
   discovery that `/output/epg` is LAN-restricted by default in
   Dispatcharr 0.23.0+.
3. **Codex review findings** from the 2026-05-02 review file
   (`CODEX_REVIEW_2026-05-02.md`).

The fixes are grouped by theme below. Each section includes the
problem statement, root cause, the fix, the files touched, and the
verification done.

---

## Section 1 - User-Reported Bugs

### Fix 1.1: Series tab empty on Dispatcharr servers without per-item categories

**Reporter:** Freyguy1975 (Synology Dispatcharr 0.23.0).

**Symptom:** Movies populated correctly (5,000 items via the v1.6.16
fallback path); Series tab showed "No Series" with the log line
`📺 VODStore.loadSeries: done, 0 series`.

**Root cause:** `VODStore.loadSeries` in `Features/Home/HomeView.swift`
required `custom_properties.category_id` on every series item to
bucket it into a user-visible category. Real-world Dispatcharr
deployments don't always populate that field; movies had a
fallback-to-first-enabled-category branch (added v1.6.16) but series
never got the same treatment.

**Fix:** Mirrored the movies fallback in `loadSeries`. When a series
item has no `category_id`, it bucks under the user's first enabled
series category. Per-category grouping becomes best-effort (one
bucket) but the user sees their content. Added counters
`taggedFromCategoryID` / `taggedFromFallback` to the done-log line
so future diagnoses are direct.

**File:** `Features/Home/HomeView.swift` (`VODStore.loadSeries`,
fallback block around the existing categoryID check).

**Verification:** Tested against Freyguy1975's server in iPad
simulator. Log shows `done, 4515 series (tagged via category_id=0,
via fallback=4515) across 19 enabled categories`.

---

### Fix 1.2: Refresh-loop on TVShowsView and MoviesView

**Symptom:** Logs from Freyguy1975 showed dozens of identical
`loadSeries: starting` / `done, 0 series` cycles burning CPU and
HTTP after the orchestrator had completed.

**Root cause:** Both `TVShowsView.onAppear` and `MoviesView.onAppear`
guarded with `series.isEmpty && !isLoadingSeries` (and the movies
equivalent). After a load that legitimately returned zero items, the
empty array satisfied the guard; SwiftUI re-fired `onAppear` on
every view rebuild and re-triggered the refresh forever.

**Fix:** Promoted `currentMoviesServerID` and `currentSeriesServerID`
to `@Published` properties on `VODStore`. Set the moment a load
begins; retained even when the load returns zero items. The
`onAppear` guard now compares `activeServer.id ==
currentMoviesServerID` (or `currentSeriesServerID`), so we
distinguish "fresh server we haven't tried yet" from "already tried
this server, returned zero items." Pull-to-refresh and the
empty-state Try Again button still bypass the guard since they call
`refreshMovies` / `refreshSeries` directly.

**Files:**
- `Features/Home/HomeView.swift` - `@Published` promotion +
  set-on-load-begin
- `Features/VOD/MoviesView.swift` - `onAppear` guard rewrite
- `Features/VOD/TVShowsView.swift` - same

**Verification:** Same Freyguy1975 server. Log no longer shows the
repeating cycle.

---

### Fix 1.3: Dispatcharr EPG missing on WAN-deployed servers

**Reporters:** Freyguy1975 (Synology QuickConnect),
jesmannstl (Cloudflare-tunneled Dispatcharr), jexhammer (DDNS
hostname). All three had channels rendering blank in the Live TV
guide despite EPG data being present in their Dispatcharr instances.

**Root cause (verified by direct probe):**
`{baseURL}/output/epg?tvg_id_source=tvg_id` is gated by
`network_access_allowed(request, "M3U_EPG")` which defaults to
LAN-only CIDRs in Dispatcharr commit `3c55649` (2026-02-01). On a
public hostname, every WAN client gets HTTP 403 with body
`{"error": "Forbidden"}`. AerioTV's previous `try?` swallow on the
fetch hid this completely.

Reproduced directly:
```
HTTP localhost (LAN):    /output/epg → 200 OK (20MB XML)
HTTPS public hostname:   /output/epg → 403 Forbidden
                         /api/* :    → 200 OK on every endpoint
```

This is the smoking gun behind much of the EPG mess in v1.6.20-21.

**Fix:** Architecturally reworked Dispatcharr-API EPG to use only
`/api/*`. Documented in detail in Section 2 below (it's the
backbone of the v1.6.22 release).

---

### Fix 1.4: Stuck-sparse cache trap

**Symptom:** After a v1.6.21 user hit the 403 above, AerioTV's
`GuideStore.saveToCache` persisted whatever partial dataset
per-cell prefetch had managed to grab (8 of 333 channels in
Freyguy1975's capture). The 24h freshness check on
`loadFromCache` then treated that bad cache as canonical on every
subsequent launch. Pull-to-refresh worked, but no one knows to do
that. Users were permanently stuck.

**Root cause:** The freshness check in `loadFromCache`
(`EPGGuideView.swift`, around line 167) compared timestamps only.
Coverage ratio was never validated.

**Fix:** Added a coverage check at the orchestrator level
(`HomeView.swift` phase 2 EPG, around line 3815). If
`cacheIsFresh && hasFuturePrograms` BUT
`guideStore.programs.count < channelStore.channels.count * 0.25`,
the orchestrator logs the sparseness explicitly and forces
`loadAllEPG` to run anyway. Healthy Dispatcharr instances cover
>70% of channels, so the override only fires on genuinely broken
cache states.

**File:** `Features/Home/HomeView.swift` (orchestrator phase 2 logic).

**Verification:** Captured before/after on Freyguy1975's iPad
simulator with the trap state. Log now shows
`cache fresh but sparse, only 8/333 channels (2%) covered. Forcing
refetch via loadAllEPG.`

---

## Section 2 - Dispatcharr API-Only Architecture

This is the bulk of v1.6.22. Drove by the realization that
`/output/epg` is unreliable on WAN deployments.

### Fix 2.1: Drop `/output/epg` from Dispatcharr-API mode

**Decision rationale:** Confirmed via 6 parallel agents reading the
upstream Dispatcharr GitHub source plus the swagger spec on a real
instance:

- `/output/epg` is the only XMLTV emitter that includes
  `<category>` tags. Default LAN-only since Feb 2026.
- `/api/epg/grid/` returns programs without categories
  (deliberate server-side serializer omission - `EPGGridAPIView`
  reads `custom_properties` but skips category emission).
- `/api/epg/programs/<id>/` is the only REST endpoint that
  returns the `categories` array per program. Useful for
  enrichment, expensive at scale.
- Teamarr and Enhanced Channel Manager (the two main third-party
  Dispatcharr admin tools) confirmed: there is no batch REST
  endpoint that returns categories.
- `/xmltv.php?username=&password=` exists with allow-all default,
  but requires Dispatcharr user credentials we don't typically
  have plumbed.

**Fix:** Removed all auto-derived `/output/epg` calls from
Dispatcharr-API mode:

- `ChannelStore.loadAllEPG` Dispatcharr branch - removed the
  `primeXMLTVFromURL(...)` call that auto-built the URL from
  `effectiveBaseURL`.
- `GuideStore.fetchDispatcharr` - removed the unconditional
  XMLTV branch that returned before reaching the bulk-grid
  fallback.
- `dispatcharrXMLTVURL(override:)` helper - refactored to return
  nil when override is empty, instead of auto-deriving.

User-set XMLTV override URLs (`server.dispatcharrXMLTVURL`) are
still honored as opt-in. Power users with a reachable XMLTV source
can paste any URL into Settings → Custom XMLTV URL and AerioTV
will fetch it (with auth headers when appropriate). The override
is layered ON TOP of the REST data, not a replacement.

**Files:**
- `Features/Home/HomeView.swift` - `loadAllEPG` Dispatcharr branch
  + `dispatcharrXMLTVURL` helper
- `Features/LiveTV/EPGGuideView.swift` - `GuideStore.fetchDispatcharr`
  reorganization
- `Features/Settings/SettingsView.swift` - settings copy updated
- `Features/Onboarding/AddServerView.swift` - onboarding copy updated

**Verification:** All 11 `/api/*` endpoints return 200 on both
Archie's HTTP testbench (LAN) and HTTPS public instance. No
`/output/epg` calls remain in Dispatcharr-API code paths
(grep-verified).

---

### Fix 2.2: EPGData bridge for `Channel.tvg_id ≠ EPGData.tvg_id`

**Symptom:** Even after Fix 2.1, channels with bad data still
rendered blank. Probed Archie's testbench: 25% of channels with
`epg_data_id` set had `Channel.tvg_id != EPGData.tvg_id`. Verified
in the wild: jesmannstl's instance has 86% mismatch (1,891 of
2,186 channels need bridging).

**Root cause:** The bulk grid keys programs by `EPGData.tvg_id`
(set at XMLTV ingest); the channel-side lookup keyed by
`Channel.tvg_id` (user-editable). For mismatched channels, the
program lookup misses entirely.

**Fix:** Added `DispatcharrAPI.getAllEPGData()` which paginates
`/api/epg/epgdata/?page_size=500` and returns
`[Int: String]` map (`epg_data_id → EPGData.tvg_id`). Both
Dispatcharr fetch paths now use this map to bridge channels with
mismatched IDs:

- `loadAllEPG` (Live TV List view EPGCache): walks the
  `channelSnapshot`; if direct tvg_id lookup misses but
  `channel.dispatcharrEPGDataID` resolves to a tvg_id with
  programs, copies the program list to the channel's reader-key.
- `fetchDispatcharr` (Guide grid `programs` dict): adds bridged
  entries directly to the `tvgIDToChannelID` lookup map so the
  existing program-iteration loop catches mismatched channels via
  the same dictionary.

**Plumbing:** Added `dispatcharrEPGDataID: Int?` field to
`ChannelDisplayItem`. Populated at channel-fetch time from
`DispatcharrChannel.epgDataID`.

**Files:**
- `Networking/StreamingAPIs.swift` - `DispatcharrEPGData` model,
  `getAllEPGData()`
- `Features/LiveTV/ChannelListView.swift` - `dispatcharrEPGDataID`
  on `ChannelDisplayItem`
- `Features/Home/HomeView.swift` - `fetchDispatcharr` plumbs
  `epgDataID` through; `loadAllEPG` builds bridge map and uses it
- `Features/LiveTV/EPGGuideView.swift` - `fetchDispatcharr` builds
  bridge map and adds bridged entries to lookup dict

**Verification:** Live test on jesmannstl's server logged
`bridged 1891 channels via epg_data_id → EPGData.tvg_id`.

---

### Fix 2.3: Per-program category enrichment via `/api/epg/programs/<id>/`

**Why:** Dropping `/output/epg` cost us category data, which drives
the Live-TV "Tint Channel Cards" feature and Guide-grid cell
tinting. The `/api/epg/grid/` bulk response strips categories. The
per-program detail endpoint is the only REST path that returns them.

**Fix:** Two new methods on `DispatcharrAPI`:

```swift
func getProgramDetail(id: Int) async throws -> DispatcharrProgramDetail
func enrichCategories(programIDs: [Int]) async -> [Int: String]
```

`enrichCategories` fans out at cap-of-4 concurrency via
`AsyncSemaphore` and swallows per-program errors so a single 5xx
doesn't drown the batch.

Wired into both fetch paths:

- `loadAllEPG` Dispatcharr branch: after the bulk grid completes,
  fires a background `Task.detached(priority: .utility)` that
  identifies the currently-airing program per channel
  (~330 calls on Freyguy1975's setup) and applies the resulting
  categories via `ChannelStore.applyXMLTVCategories(...)`. Cards
  tint progressively as detail responses land.
- `EPGGuideView.fetchDispatcharr`: same pattern. `enrichDispatcharrCategories`
  helper writes both to `ChannelStore.applyXMLTVCategories` (for
  cards) and to the matching airing `GuideProgram.category` field
  in `programs[cid]` (for Guide cell tinting). Detached so the
  Guide tab opens immediately on grid completion.

**Plumbing:** Added `programID: Int?` field to
`DispatcharrCurrentProgram`, parsed from the bulk grid's `id`
field. Required for the detail-by-PK lookup.

**Files:**
- `Networking/StreamingAPIs.swift` - `programID` on
  `DispatcharrCurrentProgram`, `DispatcharrProgramDetail` model,
  `getProgramDetail`, `enrichCategories`
- `Features/Home/HomeView.swift` - fan-out in `loadAllEPG`
- `Features/LiveTV/EPGGuideView.swift` -
  `enrichDispatcharrCategories` helper + detached invocation

**Performance:** Probed live latency at 41ms per detail call. 333
calls at cap-of-4 = ~3.5 seconds background work. Acceptable.

---

### Fix 2.4: VOD pagination optimization

**Reporter:** jesmannstl. The Dispatcharr lead dev's Discord
feedback: *"As long as you aren't hitting individual vods/series
it should be fine. You'd want to pull the list of vod/series
instead."*

**Symptom:** AerioTV's load-in hammered jesmannstl's Dispatcharr
container into HTTP 502. He has 16,357 movies; AerioTV's
`page_size=25` meant 654 paginated calls just for movies.

**Verification probe:** Hit Dispatcharr's hard cap by trying
larger page_size values:
- `page_size=50` → 50 returned
- `page_size=100` → 100 returned
- `page_size=200` → 100 returned (clamped)
- `page_size=500` → 100 returned (clamped)
- `page_size=1000` → 100 returned (clamped)

So 100 is the server's hard cap.

**Fix:** Bumped `page_size=25` → `page_size=100` at every VOD list
call site. 4× reduction in HTTP volume for the same data:

- `getVODMovies()` paginated stream
- `getVODSeries()` paginated stream
- `getVODMoviesStream(category:)` and series equivalent
- `searchVODMoviesStream(query:)` and series equivalent

For jesmannstl's library: 654 pages → 164 pages. Hits the existing
5,000-item ceiling sooner, so effective pagination cap is 50 pages
not 200. Order-of-magnitude reduction in pressure.

**File:** `Networking/StreamingAPIs.swift` (six call sites).

**Verification:** Builds clean, endpoint shape unchanged on both
test servers.

---

## Section 3 - DVR Pipeline (Dispatcharr Dev Recommendation)

### Fix 3.1: Watch in-progress recordings via HLS

**Reporter:** Dispatcharr lead dev (Discord): *"Oooh, have you
tried the new DVR pipeline yet that allows you to watch in
progress recordings?"*

**Discovery:** Probed swagger and found
`/api/channels/recordings/{id}/hls/{seg_path}` with description:
*"Serve HLS playlist and segment files for an in-progress (or
completed) recording. Clients connecting during recording should
use the m3u8 URL returned in custom_properties.file_url."*

**Fix:** Three-layer plumbing of the server-provided URL:

1. **`DispatcharrAPI.Recording`** - added `fileURL: String?`
   parsed from `custom_properties.output_file_url` (preferred) or
   `custom_properties.file_url`.
2. **SwiftData `Recording` model** - added `dispatcharrFileURL:
   String?` field. Populated by `RecordingCoordinator.reconcileDispatcharrRecordings`
   on every reconcile cycle (URL flips from HLS → file URL when
   status flips from `.recording` → `.completed`).
3. **`MyRecordingsView.playServerRecording`** - uses
   `rec.dispatcharrFileURL` resolved against `server.effectiveBaseURL`
   when present, falls back to the legacy hardcoded
   `/file/` URL for older Dispatcharr builds without the HLS
   pipeline. Logs `source=server-hls`, `server-file`, or
   `legacy-file` for diagnostics.

**UI:**
- `playIfCompleted` extended to allow tap-to-play on `.recording`
  rows when `dispatcharrFileURL` is set.
- Context menu: new "Watch Live" item on in-progress server
  recordings, gated on the file_url being present so old servers
  don't see a non-functional button.

**mpv handling:** Auth headers (`server.authHeaders`) are passed
via `http-header-fields` to mpv as before. The HLS playlist's
internal segment URLs route through the same wrapper endpoint, so
the auth carries through.

**Files:**
- `Networking/StreamingAPIs.swift` - `Recording.fileURL`
- `Models/Models.swift` - `Recording.dispatcharrFileURL` SwiftData
  field
- `Shared/RecordingCoordinator.swift` - fileURL plumbed through
  reconcile + import paths
- `Features/Settings/MyRecordingsView.swift` - playback path,
  resolveRecordingURL helper, "Watch Live" menu item

---

## Section 4 - EPG Performance Fixes (jesmannstl's overloaded server)

### Fix 4.1: Per-cell prefetch racing the bulk grid

**Symptom:** jesmannstl's iPad log:
```
[EPG source=dispatcharr-api grid] server=Jesmannstl's...
EPG fetch: channelID=10679        ← per-cell, fired in parallel
EPG fetch FAILED: channelID=10679 - The request timed out.
EPG fetch FAILED: tvgID=WSILDT - The request timed out.
EPG fetch FAILED: tvgID=KFVSDT - The request timed out.
EPG prefetch: CIRCUIT BREAKER tripped - 3 consecutive slow fetches
```

The bulk grid request and 20 visible-cell prefetch requests
competed for jesmannstl's uWSGI worker pool. Per-cell timed out
at 5s each before the grid even started, tripping the circuit
breaker.

**Fix:** Gated `GuideStore.prefetchIfNeeded` on `!isLoading`. The
bulk fetch runs through `fetchUpcoming()` which sets
`isLoading = true` for its duration. Per-cell prefetch defers
until bulk completes (success or fail). After success, cells
already have data and prefetch is a no-op anyway.

**File:** `Features/LiveTV/EPGGuideView.swift` (`prefetchIfNeeded`
guard added).

---

### Fix 4.2: Grid timeouts realigned to slow-server regime

**Symptom:** jesmannstl's grid took 90+ seconds to return; the
60s `timeoutInterval` killed it before completion.

**Fix:** Bumped `getEPGGrid` timeouts:
- Request: 60s → 180s
- Resource: 180s → 600s

The call is non-fatal (per-cell prefetch takes over on failure),
so a false-positive timeout cost is paid once per launch in the
worst case.

**File:** `Networking/StreamingAPIs.swift` (`getEPGGrid`).

---

### Fix 4.3: Per-cell prefetch timeout realigned

**Fix:** With `prefetchIfNeeded` no longer racing the bulk grid,
the 5s per-cell timeout was unnecessarily aggressive. Bumped to
15s - short enough to fail fast on a truly dead server, long
enough to succeed on slow-but-alive Dispatcharr.

**File:** `Networking/StreamingAPIs.swift` (`getUpcomingPrograms`).

---

### Fix 4.4: Diagnostic for `NSURLError -1017 cannot parse response`

**Why:** jesmannstl's grid fetch failed with `cannot parse
response`. That's Foundation's signal that the server returned a
malformed/truncated HTTP body - typically nginx giving up on the
upstream uWSGI worker mid-stream.

**Fix:** Added a do/catch around the URLSession call in
`getEPGGrid`. On `URLError(rawValue: -1017)`, log:

> "HTTP -1017 (cannot parse response). Reverse proxy truncated
> the upstream response, almost always means the Dispatcharr
> container is overloaded and worker pool can't serialize the
> full grid. Retry won't help client-side; user needs to restart
> or scale their server."

So next time a user hits this, the diagnosis is in the log.

**File:** `Networking/StreamingAPIs.swift` (`getEPGGrid`).

---

## Section 5 - Audit-Driven Cleanup (10-agent review)

### Fix 5.1: getProgramDetail timeout

The category enrichment fan-out fires AFTER the bulk grid succeeds.
The grid succeeded means the server is responsive but slow; an 8s
budget for detail calls was misaligned with that regime. Bumped to
30s.

**File:** `Networking/StreamingAPIs.swift` (`getProgramDetail`).

---

### Fix 5.2: Detached enrichDispatcharrCategories

The enrichment runs ~300 detail fetches synchronously inside the
Guide tab's `.task`. That blocked the Guide tab from becoming
interactive. Wrapped the call in `Task { ... }` so the Guide grid
renders immediately and tints fill in progressively.

**File:** `Features/LiveTV/EPGGuideView.swift` (`fetchDispatcharr`).

---

### Fix 5.3: Reuse JSONDecoder

18+ per-call `JSONDecoder()` allocations in `DispatcharrAPI`. Added
`private static let jsonDecoder = JSONDecoder()` to both
`DispatcharrAPI` and `XtreamCodesAPI`, replaced `JSONDecoder()`
calls with `Self.jsonDecoder`. JSONDecoder is thread-safe so the
single instance is shared safely.

**File:** `Networking/StreamingAPIs.swift`.

---

### Fix 5.4: Removed dead `XtreamCodesAPI.xmltvURL()` helper

Agent confirmed zero callers. Returned a string-concatenated
URL with credentials in the query - bad smell anyway. Removed.

**File:** `Networking/StreamingAPIs.swift`.

---

## Section 6 - Codex Findings (2026-05-02 Review)

### Codex Finding 1 (P1): Future-local-recording dead-end

**Codex's analysis:** `RecordProgramSheet` lets users pick
"This device" as the destination for a future Dispatcharr program.
The save logic only auto-starts local recordings when
`effectiveStart <= Date()`. There's no manual-start UI. Net
result: row is created, never starts, user thinks it's scheduled.

**Decision:** Picked Option A from Codex's recommendations
(disable future-local in the UI). Building a real future-local
scheduler runs into iOS background-execution constraints we can't
reliably solve without push-notification infrastructure.

**Three-layer defense:**

1. **`.onAppear` (line ~74)** - `destination = .dispatcharrServer`
   when `!isLive`, overriding any saved server-default that might
   pre-select `.local`.
2. **iOS Form picker (line ~141)** - gated `if isDispatcharr &&
   isLive`. The picker is hidden entirely for future programs;
   only one valid destination remains.
3. **tvOS layout (line ~291)** - same gate; only the comskip row
   shows for future Dispatcharr recordings.
4. **`scheduleRecording()` belt-and-suspenders (line ~562)** -
   coerces `destination = .dispatcharrServer` if any future call
   site bypasses the UI gates, with a warning log.

For live programs (`Record from Now`), both destinations remain
valid because the recording starts immediately while the app is
foregrounded - that path was already working.

**File:** `Features/LiveTV/RecordProgramSheet.swift`.

---

### Codex Finding 2 (P2): project.yml drift

**Codex's analysis:** The checked-in `project.yml` still
described the older `Dispatcharr`-branded project. Anyone
regenerating from XcodeGen would get the wrong app identity,
wrong resources, wrong sharing configuration.

**Fix:** Rewrote `project.yml` from scratch to match the actual
checked-in `Aerio.xcodeproj`:

| Field | Before | After |
|-|-|-|
| name | Dispatcharr | Aerio |
| target | Dispatcharr | Aerio |
| Splash | App/DispatcharrSplash.mp4 | App/AerioSplash.mp4 |
| Bundle ID | app.molinete.Dispatcharr | app.molinete.aerio |
| Top Shelf bundle | Dispatcharr.TopShelf | aerio.TopShelf |
| App group | group.app.molinete.Dispatcharr | group.app.molinete.aerio.topshelf |
| Marketing version | 1.6.4 | 1.6.22 |

Added a header comment noting the file is informational, not
authoritative - `.xcodeproj` remains canonical. `DEVELOPMENT_TEAM`
left blank so a fork can sign under its own team without editing.

**File:** `project.yml`.

---

### Codex Finding 3 (P2): Hardcoded signing - DEFERRED

**Codex's analysis:** `DEVELOPMENT_TEAM = 47DTJ3Q67T` and the
matching access-group identifier are hardcoded in entitlements
and `project.pbxproj`. Other developers can't easily sign without
editing.

**Decision:** Defer. Reasoning:
- AerioTV is Archie's actively-maintained personal app, not a
  shared project. Hardcoded team is correct for the maintained
  build.
- Forks already have a path: `project.yml` leaves
  `DEVELOPMENT_TEAM` blank so a regenerated project picks up the
  forker's team automatically.
- Editing the live `.pbxproj` to parameterize would force Archie
  to re-sign locally on every pull from his own repo.

If AerioTV ever opens up to broader contribution, this should be
revisited.

---

### Codex Finding 4 (P2): ATS posture - DEFERRED

**Codex's analysis:** ATS is broadly disabled
(`NSAllowsArbitraryLoads`, plus per-domain exemptions for web
content, media, and local networking). Codex flags it for
awareness; not necessarily a bug.

**Decision:** Defer. The exemptions are intentional and required
for IPTV interop:
- IPTV providers commonly serve over plain HTTP.
- Cloudflare-tunneled Dispatcharr may serve mixed-content media.
- LAN auto-discovery requires `NSAllowsLocalNetworking`.

The existing `Info.plist` comments already say "no upside to a
narrower ATS policy in this app." If the product ever pivots away
from generic IPTV, narrow the exemption set then.

---

## Section 7 - Verification & Build State

### Endpoint compliance

10 parallel agents independently audited every Dispatcharr-mode
code path (VOD, channels, EPG, playback, DVR, dead code,
concurrency, caching, memory/JSON, cross-cutting consistency).

**Verdict:** Dispatcharr-API mode uses `/api/*` (metadata) and
`/proxy/*` (playback) ONLY. Zero leaks to `/output/*`,
`/xmltv.php`, `/get.php`, `/player_api.php`, or any Xtream-style
path.

### Live-server probe (both servers, all endpoints)

```
HTTP testbench (LAN):    192.168.50.163:9191
HTTPS public:            dispatcharr.molinete.app

Endpoint                                  HTTP  HTTPS
/api/core/version/                        200   200
/api/channels/channels/?page_size=1       200   200
/api/channels/groups/?page_size=1         200   200
/api/channels/logos/?page_size=1          200   200
/api/epg/grid/                            200   200
/api/epg/epgdata/?page_size=1             200   200
/api/epg/programs/?page_size=1            200   200
/api/vod/movies/?page_size=1              200   200
/api/vod/series/?page_size=1              200   200
/api/vod/categories/?page_size=1          200   200
/api/channels/recordings/?page_size=1     200   200

/output/epg                               200   403   ← the v1.6.22 root cause
```

### Build state

- iOS Debug: `BUILD SUCCEEDED`
- tvOS Debug: `BUILD SUCCEEDED`
- Em dashes added in diff (per Archie's no-em-dashes rule): 0
- MARKETING_VERSION: 1.6.22 (6 entries in pbxproj)

---

## Section 8 - Files Modified (v1.6.21 → v1.6.22)

```
M Aerio.xcodeproj/project.pbxproj                       (version bump)
M Aerio.xcodeproj/xcshareddata/xcschemes/Aerio_iOS.xcscheme
M App/WhatsNew.swift                                    (3 release-note bullets)
M CHANGELOG.md                                          (v1.6.22 section)
M Features/Home/HomeView.swift                          (loadAllEPG, EPGData bridge,
                                                         category enrichment, override path,
                                                         orchestrator coverage check, VODStore
                                                         server-id tracking)
M Features/LiveTV/ChannelListView.swift                 (dispatcharrEPGDataID field)
M Features/LiveTV/EPGGuideView.swift                    (fetchDispatcharr REST-only,
                                                         EPGData bridge, category enrichment,
                                                         prefetch gate, parse-error logging)
M Features/LiveTV/RecordProgramSheet.swift              (Codex P1 fix)
M Features/Onboarding/AddServerView.swift               (settings copy)
M Features/Settings/MyRecordingsView.swift              (in-progress recording playback)
M Features/Settings/SettingsView.swift                  (settings copy)
M Features/VOD/MoviesView.swift                         (refresh-loop guard)
M Features/VOD/TVShowsView.swift                        (refresh-loop guard)
M Models/Models.swift                                   (Recording.dispatcharrFileURL field)
M Networking/PlaylistParsers.swift                      (XMLTVParser headers param,
                                                         status-code surfacing)
M Networking/StreamingAPIs.swift                        (DispatcharrEPGData,
                                                         DispatcharrProgramDetail,
                                                         getAllEPGData, getProgramDetail,
                                                         enrichCategories, Recording.fileURL,
                                                         programID, JSONDecoder reuse,
                                                         removed XtreamCodesAPI.xmltvURL,
                                                         VOD page_size 100, timeout bumps,
                                                         -1017 diagnostic)
M Shared/RecordingCoordinator.swift                     (fileURL reconcile + import)
M project.yml                                           (Codex P2 #2 fix)
```

18 source files modified (excluding scheme + xml metadata).

---

## Section 9 - Deferred / Backlog (Not in v1.6.22)

These are documented for future work but not actioned in v1.6.22:

1. **Codex P2 #3 (signing)** - keep hardcoded for the maintained
   build; project.yml leaves `DEVELOPMENT_TEAM` blank for forks.
2. **Codex P2 #4 (ATS)** - intentional broad exemption for IPTV
   interop.
3. **Bloat in big files** - ongoing watchlist in
   `project_aerio_god_files.md`. Opportunistic peel-off during
   feature work.
4. **Test coverage** - DVR, watch-progress merge, sync migration,
   XMLTV parser, deep-link routing.
5. **Cache `getAllEPGData()` across launches** - currently
   re-fetched every cold launch (19,500 rows on jesmannstl's setup).
   Could persist to UserDefaults with 7-30-day TTL. (From caching
   audit agent, deferred for v1.6.23.)
6. **Persist enriched categories per program ID** - saves the
   ~330-call fan-out on every cold launch. Same audit agent.
7. **VOD movies+series parallel** - currently serial in the
   orchestrator; could fan out via TaskGroup. Concurrency audit
   agent flagged it.
8. **MainActor hop in detached task** - minor. Audit agent #5.
9. **EPGData bridge atomic invalidation** - race-condition risk
   between sync invalidation and detached save in `loadFromCache`.
   Caching audit agent.
10. **Logo persistence** - channel logos re-downloaded on every
    cold launch.
11. **Streaming JSON parser for getEPGGrid** - currently loads full
    response into memory before decoding. On 100MB+ payloads this
    matters. Memory audit agent.
12. **Unified EPG pipeline abstraction** - M3U vs Xtream vs
    Dispatcharr each invent their own EPG flow. Bloat audit agent.

---

## Section 10 - Open Questions for Codex

1. **Is the future-local-recording defense sufficient?** Three
   layers (init coercion + UI gate + scheduleRecording coercion)
   should make the impossible state unreachable, but Codex may see
   a path I missed.
2. **Should the user-set XMLTV override be retired?** It's still
   functional for power users who paste a working URL, but adds
   surface area. Could be considered for v1.6.23 cleanup.
3. **Project.yml authority status.** I marked it informational
   rather than authoritative because the live `.pbxproj` carries
   things XcodeGen can't fully express (tvOS-specific build
   settings, scheme tweaks, etc.). Is that the right call?
4. **DVR HLS auth header propagation through segment fetches.**
   The HLS playlist's segments are at
   `/api/channels/recordings/<id>/hls/<seg_path>`. mpv's
   `http-header-fields` should carry through to segment requests
   per HLS spec. If Codex sees a way the headers could drop, please
   flag.
5. **Coverage threshold for the sparse-cache override.** I picked
   25%. Healthy Dispatcharr instances cover >70%; M3U/Xtream paths
   may legitimately land lower than 25% on a sparse playlist. If a
   user has a genuinely-sparse setup, the override would force a
   refetch every launch. Acceptable cost? Or should the threshold
   be lower (10% or 5%)?
