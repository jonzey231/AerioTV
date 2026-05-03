# AerioTV v1.6.23 Pre-Public-Release Audit

Synthesis of a 12-agent parallel review of the entire codebase prior
to AerioTV's first public App Store submission. This report is
intended for cross-review by Codex, Gemini, and DeepSeek; the goal is
to surface every issue that should be addressed (or explicitly
deferred with rationale) before going public.

**Audit date:** 2026-05-02
**Build state:** v1.6.22 ready for archive
**Branch base:** v1.6.22

**Revision history:**
- 2026-05-02 v1: original 12-agent synthesis.
- 2026-05-02 v2: incorporates Codex's cross-review feedback
  (`CODEX_REVIEW_OF_CLAUDE_AUDIT_2026-05-02.md`). Four findings
  corrected (semaphore deadlock claim demoted, GuideStore race
  retracted, iOS entitlements re-diagnosed, mpv logging scope
  broadened).
- 2026-05-02 v3 (this revision): aligns Section 6 prioritization
  with Codex's full handoff (`CODEX_FULL_HANDOFF_ON_CLAUDE_AUDIT_2026-05-02.md`).
  Codex's Tier 1 / Tier 2 / Tier 3 framework supersedes my prior
  ordering. Substantive changes:
  - **mpv logging promoted to Tier 1** (was HIGH should-fix in v2,
    now alongside the other CRITICAL items). Codex argues the
    credential-leak fix needs to land before public release, not
    after.
  - **PrivacyInfo.xcprivacy promoted to Tier 1** (was HIGH
    should-fix in v2). App Review compliance bar.
  - **`loadAllEPG` reentrance, form validation, VoiceOver demoted**
    out of Tier 1/2 into v1.6.24+ polish. Codex's view: real
    correctness items but not release-blockers.
  - The four findings corrected in v2 (GuideStore, semaphore,
    entitlements, mpv) keep their corrected wording.

**Codex's recommended implementation order** (overrides my prior
Section 6):

1. Add origin check to `RedirectPreservingDelegate`.
2. Validate scheme + host on server-provided image URLs.
3. Add `PrivacyInfo.xcprivacy`.
4. Fix iOS entitlements configuration (file + `project.pbxproj`).
5. Sanitize all playback URL diagnostics (direct prints + mpv
   callback).
6. Decide whether `Recording` should sync (implement or document).
7. Harden Xtream EPG enrichment.
8. Then revisit the demoted concurrency cleanup items.

The 12 agents covered:
1. Dispatcharr-API endpoint compliance (exhaustive)
2. Xtream Codes correctness (M3U + EPG + VOD)
3. M3U playlist correctness (parser + EPG association)
4. Credential security (storage, transit, logs)
5. URL construction safety (injection, redirects, scheme validation)
6. Concurrency safety (Swift 6 strict concurrency, races, cancellation)
7. Memory and performance (large libraries, EPGCache, image cache)
8. Code quality and bloat (god files, duplication, leftover dev code)
9. Error handling (silent swallows, user surfacing)
10. SwiftData and iCloud sync correctness
11. App Store / App Review readiness
12. UX and accessibility
13. (Combined with #6) Network resilience

---

## Executive Verdict (revised after Codex full handoff)

**App is broadly release-ready. Five Tier-1 items to land before
public submission.** No agent flagged a defect that crashes the app
under normal use, and the architecture is sound. After Codex's
correction passes, the v1 audit's two CRITICAL concurrency findings
were demoted (one was a `@MainActor` false positive, one was a
speculative deadlock without a reproducer). The remaining must-fix
list aligns with Codex's Tier 1 framework:

**Tier 1 (must fix before public release):**

1. **BLOCKER: iOS entitlements configuration.** The iOS target
   actively references `SupportingFiles/Aerio.entitlements` via
   `CODE_SIGN_ENTITLEMENTS` (`project.pbxproj` lines 1168, 1297)
   and that file declares `aps-environment = development`. Fix
   requires file + build setting changes together.
2. **CRITICAL: Open redirect with credential preservation.**
   `RedirectPreservingDelegate` re-applies `Authorization` and
   `X-API-Key` on cross-origin redirects.
3. **CRITICAL: SSRF on server-provided image URLs.** Logo / poster
   URLs from Dispatcharr metadata flow into `URL(string:)`
   unvalidated.
4. **HIGH: MPV diagnostics leak credentials.** Direct
   `print("[MPV-DIAG] URL: ...")` AND the mpv log-message callback.
   Sanitize both paths.
5. **HIGH: `PrivacyInfo.xcprivacy` missing.** App Review compliance.

**Tier 2 (strongly recommended for v1.6.23):**

6. `Recording` sync decision (implement cross-device sync OR
   document as device-local).
7. Harden Xtream EPG enrichment (resilience, user-visible failure).
8. Improve onboarding form-validation clarity.

**Tier 3 (cleanup, reframe before fixing):**

9. Simplify the defer-task semaphore signal pattern. Was v1's #1
   CRITICAL but Codex correctly demoted to MEDIUM cleanup.
10. Drop or reframe the GuideStore breaker reset finding. Was v1's
    #2 CRITICAL but it's a `@MainActor` false positive; at most a
    logic/policy review.

**v1.6.24+ backlog:** everything in Section 4 (god-file extraction,
EPGData map persistence, dynamic type, reduce motion, accessibility
labels on custom cells, etc.) plus the demoted concurrency items.

Estimated work for Tier 1 + Tier 2: 12-18 hours. The corrected
order in Section 6 maps directly to Codex's recommended sequence.

---

## Section 1 - Endpoint Compliance (the v1.6.22 promise)

Each playlist type was independently audited.

### 1.1 Dispatcharr-API mode (Agent 1)

**VERDICT: PASS.**

Every code path that touches the network in `dispatcharrAPI` mode
hits `/api/*` (metadata) or `/proxy/*` (stream URLs) only. Zero leaks
to `/output/*`, `/xmltv.php`, `/get.php`, `/player_api.php`, or any
Xtream-style path. This was verified across:

- ChannelStore + VODStore + GuideStore + RecordingCoordinator
- MyRecordingsView playback URLs
- ServerSyncView onboarding probe
- SettingsView Test Connection
- TopShelfExtension (uses `aerio://` deep links, no direct API)
- Deep-link handlers
- Image URL resolvers (TMDB CDN passthrough is correct)

The user-set XMLTV override URL (Settings -> Custom XMLTV URL)
remains available for power users. It's the only path that can
reach `/output/epg`, and only when the user explicitly types the URL.

### 1.2 Xtream Codes mode (Agent 2)

**VERDICT: PASS with three gaps.**

Channel fetch (`/player_api.php?action=get_live_streams`), VOD
(`/player_api.php?action=get_vod_streams` + `/movie/<u>/<p>/<id>`),
series (`/player_api.php?action=get_series_info` +
`/series/<u>/<p>/<id>`), and EPG (XMLTV via `/xmltv.php` plus
per-channel `/player_api.php?action=get_short_epg`) all work
correctly. Credentials live in Keychain and are redacted in logs.

**Gaps to address (HIGH):**

- `enrichXtremEPG` (HomeView.swift:1446) has NO circuit breaker. On a
  slow Xtream server, fanning out 8 concurrent `get_short_epg` calls
  per batch with 20s timeouts could take 10+ minutes with no abort.
  Mirror the GuideStore prefetch breaker pattern.
- Xtream EPG enrichment doesn't set `currentProgramCategory` on
  channels, so the "Tint Channel Cards" feature doesn't work for
  Xtream sources. M3U and Dispatcharr both populate it.
- `getEPG(streamID:)` hardcodes `limit: 3`. No way to request a
  longer window for Guide grid display. Acceptable; XMLTV path
  carries the longer window.

### 1.3 M3U playlist mode (Agent 3)

**VERDICT: PASS with five gaps.**

Standard UTF-8 playlists with user-supplied EPG URLs work end-to-end.
Parser is robust, regex-based, runs off-main, handles 10k+ channels.

**Gaps to address (HIGH/MEDIUM):**

- **No gzip support for M3U or XMLTV** (HIGH). Some CDNs return
  `Content-Encoding: gzip` and Foundation auto-decompresses, but
  many providers serve `.m3u.gz` without the header. Already on the
  v1.6.21+ backlog per the user-memory note about `.xml.gz` EPG
  support; promote to v1.6.23.
- **No `url-tvg=` parsing from `#EXTM3U` header** (MEDIUM). M3U
  playlists commonly carry `#EXTM3U url-tvg="https://..."` to declare
  the EPG source. We ignore that and require the user to configure
  the EPG URL manually in Settings. Bad UX for the most common case.
- **No Content-Type validation** (MEDIUM). A misconfigured server
  returning HTTP 200 + HTML body parses to "no channels found" with
  no diagnostic.
- **UTF-8 only fallback in HomeView.fetchM3U** (LOW). PlaylistParsers
  has UTF-8 + ISO-Latin1 fallback; the HomeView path doesn't use it.
- **Embedded-credential URLs accepted silently** (LOW). M3U URLs of
  the form `http://user:pass@host/...` are accepted with no warning
  or sanitization in logs.

---

## Section 2 - Must-Fix Findings (Before Public Release)

### 2.1 Defer-task semaphore signal pattern (DOWNGRADED to MEDIUM)

**File:** `Networking/StreamingAPIs.swift` lines 1316 and 2440
**Severity:** MEDIUM (was CRITICAL in v1; corrected per Codex review)
**Reporter:** Concurrency audit agent

```swift
defer { Task { await semaphore.signal() } }
```

**Codex correction:** The original v1 framing claimed a "proven
CRITICAL deadlock under realistic network errors." That conclusion
was speculative. `AsyncSemaphore.signal()` is a synchronous,
actor-isolated method (verified at StreamingAPIs.swift:2511). The
spawned `Task { await semaphore.signal() }` is unstructured and
runs to completion regardless of the parent's cancellation; it
isn't a "fire and forget that may be dropped" the way the v1 text
implied. No reproducer was provided, no Swift task-lifecycle
analysis was given to support the deadlock claim.

**What's actually true:** the pattern is structurally weaker than
it should be. Permit lifetime isn't tightly paired with the
acquired work; release happens through a spawned task rather than
in-line. This is harder to reason about than necessary and worth
simplifying for robustness and clarity, but it isn't a confirmed
critical defect.

**Recommended action:** simplify the pattern for clearer permit
semantics. Options:

- Use a `Sendable` release-token struct whose `deinit` calls
  `signal()`. Acquired-released coupling becomes lexical.
- Restructure to await the signal directly without wrapping in
  `Task`. If `signal()` is actor-isolated and reachable from the
  current context, this works.
- Add an instrumented stress test (force network failure during
  cap-of-4 enrichment) before treating this as a real bug.

**Fix priority:** v1.6.23 cleanup or v1.6.24+. Not a release
blocker.

### 2.2 GuideStore breaker reset (DOWNGRADED to LOW)

**File:** `Features/LiveTV/EPGGuideView.swift` lines 1230 to 1237
**Severity:** LOW (was CRITICAL in v1; corrected per Codex review)
**Reporter:** Concurrency audit agent

**Codex correction:** the v1 framing claimed a non-atomic concurrent
write race. `GuideStore` is `@MainActor` (declared at
EPGGuideView.swift:27). All access to `consecutivePrefetchTimeouts`,
`prefetchCircuitBreakerTripped`, and `prefetchBreakerTrippedAt` is
serialized through the main actor. Two callers cannot literally
race writes to those properties; the writes are not exposed to
thread interleaving in the way the v1 text implied. The "atomic
reset" framing was incorrect.

**What might still be worth a logic review** (not a concurrency bug):

- Is the cooldown policy the right one (currently 30s)?
- Should `resetPrefetchCache()` reset breaker state for every
  caller it's currently exposed to?
- Should view re-entry count as a breaker reset opportunity at all?
- Is the breaker too sticky or not sticky enough from a UX
  perspective?

**Fix priority:** policy review, not a blocker. Defer to v1.6.24+
unless real-user reports indicate the current policy misbehaves.

### 2.3 Open redirect with credential preservation

**File:** `Networking/StreamingAPIs.swift` lines 2573 to 2607
**Severity:** CRITICAL
**Reporter:** Security + URL safety agents

`RedirectPreservingDelegate` re-applies `Authorization` and
`X-API-Key` headers on every redirect, including cross-origin. HTTP
standard requires stripping auth on cross-origin redirects. A
compromised Dispatcharr instance, malicious reverse-proxy
configuration, or even a server-side typo can issue HTTP 301 to
`https://attacker.com/...` and receive the user's API key in plain
text.

**Fix:** Compare the redirect target's host to the original
request's host. Strip auth headers when they differ. Allow only
same-origin redirects to preserve auth.

### 2.4 SSRF via server-provided image URLs

**File:** `Networking/VODService.swift` lines 50 to 99 (`resolveURL`,
`resolveImageURL`)
**Severity:** CRITICAL
**Reporter:** URL safety agent

Logo URLs, poster URLs, and backdrop URLs come from the Dispatcharr
server's response. We pass them straight to `URL(string:)` and fetch
without scheme/host validation. A malicious or compromised
Dispatcharr instance can inject `http://192.168.1.1/` (probe the
user's home network), `http://127.0.0.1:9191/` (probe localhost), or
`file://` URLs (if the underlying URLSession honors them).

**Mitigation present:** TMDB CDN paths are special-cased and
rewritten to `image.tmdb.org`. But arbitrary upstream URLs flow
through unchanged.

**Fix:** Validate scheme is http/https. Validate host is not RFC-1918
local IP space (10/8, 172.16/12, 192.168/16) or 127/8. Optionally,
restrict to a whitelist of expected CDN domains (TMDB, TheTVDB,
ScheduleDirect, the user's own server) and proxy everything else
through the user's Dispatcharr server (which already has the source
URL).

### 2.5 iOS entitlements actively configured with development aps-environment (RE-DIAGNOSED)

**File:** `SupportingFiles/Aerio.entitlements`,
`Aerio.xcodeproj/project.pbxproj` lines 1168 and 1297
**Severity:** BLOCKER
**Reporter:** App Store readiness agent + Codex correction

**Codex correction:** the v1 framing called this an "orphaned file"
hazard. That was wrong. The iOS target ACTIVELY references
`SupportingFiles/Aerio.entitlements` via
`CODE_SIGN_ENTITLEMENTS = SupportingFiles/Aerio.entitlements;` at
two sites in `project.pbxproj` (Debug and Release configurations).
That file currently declares:

```xml
<key>aps-environment</key>
<string>development</string>
```

So the iOS target's Release builds carry a development APS
environment in the entitlements they ship with. The tvOS target
points elsewhere (`Aerio_tvOS.entitlements`, which has
`production`) so this is iOS-target-only.

**Why this matters:** App Store Connect uploads with development
APS in entitlements are accepted but push registration on
production builds fails silently against the wrong APNs environment.
AerioTV doesn't currently register for push notifications, so the
mismatch is dormant but real. If push is added later (e.g., for
DVR completion alerts), it would silently break. Removing the
entitlement is also a path; we don't currently use APS at all.

**Fix options (pick one):**

1. **If push is intended later:** Set
   `<string>production</string>` in
   `SupportingFiles/Aerio.entitlements`. Confirm both Debug and
   Release `CODE_SIGN_ENTITLEMENTS` still resolve. Easiest fix.
2. **If push is not used:** Remove the `aps-environment` key from
   `SupportingFiles/Aerio.entitlements` entirely. Audit
   `Aerio_tvOS.entitlements` similarly so neither target carries an
   unused APS entitlement.
3. **If consolidation is preferred:** Repoint the iOS target's
   `CODE_SIGN_ENTITLEMENTS` to a unified entitlements file shared
   with tvOS. Requires updating both `project.pbxproj` references
   and verifying the merged file covers both platforms' needs
   (Top Shelf, app group, keychain access group, iCloud KVS).

**Do not** simply delete the file: the iOS target build will fail
because `CODE_SIGN_ENTITLEMENTS` would point at a missing path.
Build setting must change in lockstep with file changes.

---

## Section 3 - HIGH Priority (Strongly Recommend Before Public)

### 3.1 PrivacyInfo.xcprivacy missing

**Reporter:** App Store readiness agent

Apple increasingly expects every app submitted to the App Store to
include a `PrivacyInfo.xcprivacy` file declaring "Required Reason
API" usage (file timestamps, UserDefaults, system uptime, disk
space, keychain access). AerioTV uses several of these.

**Fix:** Add the file (Xcode: File -> New -> App Privacy File). Declare:
- `kSecAttrAccessibleAfterFirstUnlock` / iCloud Keychain
- File timestamps (playlist last-modified)
- System uptime (PlaybackDiagnostics)
- UserDefaults (extensive)
- Disk space (DVR quota)

### 3.2 MPV diagnostics leak credential-bearing playback URLs (SCOPE EXPANDED)

**Files:**
- `App/MPVPlayerView.swift:2508` (direct print of full URL)
- `App/MPVPlayerView.swift:2540, 2588` (mpv log-message callback)
**Severity:** HIGH
**Reporter:** Security audit agent + Codex correction

**Codex correction:** the v1 framing only covered the mpv
log-message callback path. That misses an easier and more obvious
leak. `MPVPlayerView` directly prints the resolved playback URL:

```swift
print("[MPV-DIAG] URL: \(url.absoluteString)")
```

For Xtream Codes streams, that URL is `/live/<username>/<password>/<id>.<ext>`
or the VOD/series equivalents, which embed credentials directly in
the path. Anyone sharing an Xcode console log (support request,
TestFlight feedback) leaks their full Xtream credentials in plain
text.

The mpv log-message callback (line 2540 onward) is a secondary
path; mpv's internal log strings can also include the URL when it
logs HTTP errors, redirects, demuxer init, etc.

DebugLogger.sanitize already has the right regex shapes
(`/movie/.../...` -> `/movie/.../***`, `?username=X&password=Y` ->
`?username=***&password=***`). It just needs to be applied to
both leak vectors.

**Fix scope (broadened):**

1. Route `[MPV-DIAG]` and similar direct prints through
   `DebugLogger.log(...)` so the existing sanitization applies.
   Alternative: pre-sanitize with `DebugLogger.sanitize(url.absoluteString)`
   before interpolating.
2. Wrap the mpv log-message callback to run incoming strings
   through the same sanitizer before printing.
3. Audit `MPVPlayerView.swift` for any other `print(...)` that
   interpolates `URL.absoluteString` or the resolved stream URL.
   Apply the same sanitization.
4. Consider a release-build `#if DEBUG` gate on `[MPV-DIAG]` so
   shipped builds never log full URLs at all.

### 3.3 Recording not synced via iCloud

**File:** `Models/Models.swift` line 563, `Shared/SyncManager.swift`
**Severity:** HIGH
**Reporter:** SwiftData / iCloud sync audit

The Recording model is persisted locally only. A user who schedules a
recording on iPhone, then opens the app on Apple TV, sees no record
of it; tapping Record again creates a duplicate on the Dispatcharr
server. Watch-progress, server connections, reminders, and
preferences all sync; recording does not.

**Fix:** Add Recording to SyncManager's payload. Sync only the local
fields (UUID, programTitle, scheduledStart/End, status,
remoteRecordingID); device-local fields (`localFilePath`,
`dispatcharrFileURL`) stay local. Conflict resolution: last-write
wins on `updatedAt`, with `remoteRecordingID` as the secondary
identity for matching.

### 3.4 LoadAllEPG reentrance not guarded

**File:** `Features/Home/HomeView.swift` line 1195
**Severity:** HIGH
**Reporter:** Concurrency audit

A rapid server switch can fire two concurrent `loadAllEPG` calls.
Both run their bulk grid fetches in parallel and then race to write
EPGCache. Outcome is non-deterministic.

**Fix:** Cancel the prior task before starting a new one (mirror the
VODStore.refreshMovies pattern at HomeView.swift line 109).

### 3.5 enrichXtremEPG no circuit breaker

**File:** `Features/Home/HomeView.swift` line 1446
**Severity:** HIGH
**Reporter:** Xtream audit

Per Section 1.2 above. Mirror the GuideStore prefetch breaker.

### 3.6 Multi-server failover missing

**File:** Architecture-wide
**Severity:** HIGH
**Reporter:** Network resilience audit

If a user's primary server is down, AerioTV shows errors instead of
falling back to a secondary server. Most users have only one server,
but power users have multiple, and the orchestrator could iterate.

**Fix:** Optional. The current behavior is "the active server is
down, show me an error" which is defensible. Consider for v1.6.23+.

### 3.7 KVS payload size approaching 1MB limit

**File:** `Shared/SyncManager.swift`
**Severity:** HIGH
**Reporter:** SwiftData / iCloud sync audit

NSUbiquitousKeyValueStore has a 1MB total payload limit. With many
servers + watch progress + reminders, we may approach this with no
telemetry. When exceeded, KVS fails silently; the user thinks their
data is synced, but it isn't.

**Fix:** Add `estimatePayloadSize()` before push. Log size. If above
~80% of cap, prompt the user to clear stale data (e.g., very old
watch progress entries).

### 3.8 Recording orphan cleanup missing on server delete

**File:** `App/AerioApp.swift` lines 1593 to 1603
**Severity:** HIGH
**Reporter:** SwiftData / iCloud sync audit

When a server is deleted (locally or via sync), its associated
Recordings are not cleaned up. They persist with stale
`remoteRecordingID`s pointing at deleted Dispatcharr objects.
Playback fails silently when a user taps an orphaned recording.

**Fix:** Add a cascade delete when a server is removed. Mirror the
`pruneOrphanedEPGPrograms` pattern.

### 3.9 Form validation feedback opaque in onboarding

**File:** `Features/Onboarding/AddServerView.swift`
**Severity:** HIGH
**Reporter:** UX audit

`isFormValid` greys out the Test Connection button when fields are
incomplete, but no inline field-level error explains why. New users
struggle through the first server setup.

**Fix:** Add red-text error labels under required fields as they're
edited. Validate URL syntax inline. Validate API key length inline.

### 3.10 Limited VoiceOver coverage on custom-drawn cells

**File:** `Features/LiveTV/ChannelListView.swift`,
`Features/LiveTV/EPGGuideView.swift`,
`Features/VOD/*.swift`
**Severity:** HIGH
**Reporter:** UX / accessibility audit

Custom-drawn UI (channel cards, guide cells, VOD posters) has
minimal `accessibilityLabel`/`accessibilityValue`/`accessibilityHint`.
VoiceOver users hear "Button" instead of "WGN 9 Chicago, 7:30 PM,
Jeopardy! Recording scheduled."

**Fix:** Add labels at every custom cell. Test with VoiceOver on iOS
and tvOS before submission. Apple does not block on accessibility
gaps for general apps but may flag in subsequent reviews.

---

## Section 4 - MEDIUM Priority (v1.6.23 Backlog)

### 4.1 Performance / memory

- **VOD URLSession allocations per call** (StreamingAPIs.swift:151-191).
  VOD methods create a fresh URLSessionConfiguration + URLSession per
  call. With paginated fetches running 1400+ calls on large
  libraries, this is wasteful. Move to the shared static session
  pattern that XtreamCodesAPI uses.
- **EPGData map fetched every launch** (HomeView.swift:1231 and
  EPGGuideView.swift:599). 19,500 rows on jesmannstl's setup.
  Persist with a 7-30 day TTL.
- **Per-program category enrichment refetched every launch**
  (HomeView.swift:1364). ~330 calls per launch for cards that don't
  change. Persist categories per program ID with a 24h TTL.
- **EPGCache TTL 30 min with full 97k program dict resident**
  (ChannelListView.swift:11). Memory peaks at 50-100MB sustained on
  large libraries. Implement LRU eviction or reduce TTL.
- **VODStore @Published storms** (HomeView.swift:14-40). 36+
  @Published fields. Per-category load fires invalidation cycles.
  Batch updates.
- **`.lowercased()` in EPG matching loop** (EPGGuideView.swift:615
  to 658). 300k+ string allocations on a 97k-program merge.
  Pre-lowercase keys once before the loop.
- **Streaming JSON parser for getEPGGrid** - on overloaded servers
  the response is 100MB+; we load all into memory before decode.

### 4.2 Code quality / bloat

- **Six god files** (>2000 lines each): HomeView (4,975),
  MPVPlayerView (3,898), SettingsView (3,664), StreamingAPIs (3,473),
  EPGGuideView (2,992), ChannelListView (2,827).
- **Duplicate EPGData bridge logic** in HomeView.loadAllEPG and
  EPGGuideView.fetchDispatcharr. Extract to `EPGBridgeBuilder`.
- **3-fallback JSON wrapper pattern** repeats 12+ times in
  StreamingAPIs. Extract `tryDecodeFlexible<T>(...)` helper.
- **Unguarded `print()`** statements in NowPlayingBridge.swift,
  AerioApp.swift, MPVPlayerView.swift. Wrap in `#if DEBUG` or route
  through debugLog.
- **Magic number constants** scattered: timeouts (30/60/180/300/600),
  page sizes (100/500), TTLs (1800/3600/86400). Extract to
  `NetworkConstants` and `CacheConstants` enums.
- **Naming inconsistencies**: `epgDataIDToTvgID` vs `epgDataMap` vs
  `bridgeMap`. Standardize on one name.

### 4.3 Error handling / UX

- **Silent recording schedule failure** (RecordProgramSheet.swift:618).
  Network/server error is `try?`'d. User taps Record, gets no
  feedback. Local row is orphaned.
- **VOD pagination silent on timeout** (StreamingAPIs.swift:1685-1702).
  Circuit breaker trips, pagination ends, user sees an incomplete
  movie list with no indication why.
- **Search result failures hidden** (HomeView.swift:192, 245).
  Catch-and-do-nothing during search pagination.
- **iCloud sync silent failures** (SyncManager.swift:465-503). User
  thinks data is synced; KVS quota or network failure leaves it
  local-only.

### 4.4 Concurrency / sync

- **VOD pagination cancellation incomplete** (HomeView.swift:114).
  Outer task cancels but inner withTaskGroup subtasks may not check
  cancellation between pages.
- **Prefetch chain not server-aware** (EPGGuideView.swift:1355-1370).
  In-flight requests against the previous server complete before
  the chain stops.
- **WatchProgress legacy nil-serverID rows not migrated** (per
  v1.6.8 Codex A1). Eternal orphans.
- **No timestamp tie-breaker** for last-write-wins watch-progress
  merge. Two devices saving simultaneously produces non-deterministic
  ordering.

### 4.5 Network resilience

- **Captive portal pre-auth not detected**. Hotel Wi-Fi login splash
  is misattributed to "server unreachable."
- **No persistent offline banner**. NWPathMonitor is observed but UI
  doesn't reflect it.
- **No queue-on-reconnect**. Tasks failed by network drop are not
  retried automatically when connectivity returns.

### 4.6 UX

- **Reduce Motion not honored**. AddServerView.swift uses unconditional
  spring animations.
- **Dynamic Type not honored**. Hardcoded font sizes in WelcomeView and
  several other places.
- **No timeout on loading spinners**. ChannelListView's "Loading
  channels..." can spin forever.
- **Disabled button contrast weak** (PrimaryButton.swift:136). Hard to
  tell if a button is enabled or not on dark backgrounds.
- **Custom theme colors not validated for WCAG**. User-picked accent
  could fail 4.5:1 contrast.
- **In-progress vs completed recording rows not visually distinct**
  enough.
- **"Watch Live" CTA on in-progress recordings is in context menu only**.
  New v1.6.22 feature won't be discovered.

---

## Section 5 - LOW Priority / Acceptable

These are documented but not actioned for v1.6.23:

- **iCloud Keychain credential sync** replicates credentials to all
  user's devices. Defensible because Keychain is E2E encrypted by
  Apple. Defense-in-depth would be a per-server iCloud-sync opt-out.
- **ATS broadly disabled**. Documented in code; required for IPTV
  interop. Apple generally accepts this for IPTV clients.
- **Xtream credentials in URL paths**. Inherent to the Xtream Codes
  API spec. DebugLogger sanitization redacts logs. No path forward
  without breaking compat.
- **Hardcoded developer team ID in pbxproj**. Personal-app pattern;
  project.yml leaves it blank for forks.
- **Singletons everywhere** (`.shared`). App-wide state is fine for
  the scope; no path to non-singleton architecture without a major
  refactor.
- **MPVLibraryWarmup benign race**. Documented and accepted in the
  comments; both calls hit the same library-wide init.
- **Nonisolated(unsafe) in SyncManager timestamp flags**. Read-heavy,
  rare writes, suppression heuristic only.

---

## Section 6 - Tier 1 / Tier 2 / Tier 3 Implementation Plan

This section adopts Codex's Tier 1/2/3 framework from
`CODEX_FULL_HANDOFF_ON_CLAUDE_AUDIT_2026-05-02.md`. The order and
acceptance criteria below map directly to Codex's prescribed
sequence.

### Tier 1: Must Fix Before Public Release

#### T1.1 Add origin check to `RedirectPreservingDelegate`

**Files:** `Networking/StreamingAPIs.swift:2573` and surrounding
delegate implementation.

**Goal:** stop preserving credential-bearing headers
(`Authorization`, `X-API-Key`) on cross-origin redirects.

**Acceptance:**
- Same-origin redirects keep current auth-preserving behavior
  (reverse-proxy host canonicalization still works).
- Cross-origin redirects do not forward auth-bearing headers.
- Add a debugLog line when auth is stripped so the redirect
  decision is visible during testing.

**Estimated effort:** 30-60 minutes.

#### T1.2 Restrict server-provided image URL resolution

**Files:** `Networking/VODService.swift:50-99` (`resolveURL`,
`resolveImageURL`).

**Goal:** validate scheme and host before fetching upstream image
URLs from Dispatcharr metadata.

**Acceptance:**
- Only `http` and `https` schemes accepted.
- Host policy is explicit: TMDB CDN passthrough remains; the
  user's configured server host is allowed; RFC-1918 ranges and
  127/8 are rejected (or restricted to the user's configured
  server host only).
- Failures are logged with enough detail to diagnose without
  leaking the rejected URL.

**Estimated effort:** 1-2 hours.

#### T1.3 Add `PrivacyInfo.xcprivacy`

**Files:** new file in the Aerio project + target membership.

**Goal:** declare Required Reason API usage for App Review.

**Acceptance:**
- File exists and is included in the iOS target.
- Declarations cover: UserDefaults, file timestamps, system
  uptime, disk space, Keychain access. Cross-check actual usage
  against the manifest before submission.

**Estimated effort:** 30-60 minutes.

#### T1.4 Fix iOS entitlements configuration

**Files:**
- `SupportingFiles/Aerio.entitlements:5`
- `Aerio.xcodeproj/project.pbxproj:1168, 1297`

**Goal:** correct the iOS target's `aps-environment` (or remove
the key entirely if push is not planned) without breaking the
`CODE_SIGN_ENTITLEMENTS` chain. See Section 2.5 for the
re-diagnosis.

**Acceptance:**
- iOS target builds (Debug + Release) with valid entitlements.
- `aps-environment` is correct for production OR the key is
  removed and a comment notes the rationale.
- No stale duplicate entitlements file remains behind.
- Test push registration if the key is kept; smoke-test sign-in
  if removed.

**Estimated effort:** 15-30 minutes including verification.

#### T1.5 Sanitize all playback URL diagnostics

**Files:**
- `App/MPVPlayerView.swift:2508` (direct `print("[MPV-DIAG] URL: ...")`)
- `App/MPVPlayerView.swift:2540, 2588` (mpv log-message callback)
- Any other site in `MPVPlayerView` that interpolates
  `url.absoluteString`.

**Goal:** prevent Xtream credentials and other URL-embedded auth
from reaching the console.

**Acceptance:**
- Direct URL prints are removed in release builds (gate behind
  `#if DEBUG`) OR pre-sanitized through `DebugLogger.sanitize`.
- mpv callback strings are sanitized before printing.
- Verify no `[MPV-*]` line in a release-build console contains a
  bare Xtream `/live/<u>/<p>/<id>` segment or `?username=&password=`
  query.

**Estimated effort:** 1-2 hours.

### Tier 2: Strongly Recommended for v1.6.23

#### T2.1 Decide whether `Recording` should sync across devices

**Files:**
- `Shared/SyncManager.swift:26` (sync key inventory)
- `Models/Models.swift:563` (Recording model)

**Goal:** product decision + implementation OR explicit
documentation.

**Acceptance:**
- If implementing: payload identity (`remoteRecordingID` for
  Dispatcharr, deterministic UUID for local), conflict resolution
  (last-write-wins on `updatedAt` with `remoteRecordingID` as
  secondary key), orphan cleanup on server delete.
- If not implementing: README + onboarding copy clarify
  recordings are device-local; duplicate-scheduling risk
  acknowledged or mitigated in the UX.

**Estimated effort:** 3-4 hours if implementing; 30 minutes if
documenting.

#### T2.2 Harden Xtream EPG enrichment

**Files:** `Features/Home/HomeView.swift:1424-1481`
(`enrichXtreamEPG`).

**Goal:** make Xtream enrichment failures controlled and
diagnosable; do not silently stall the UX.

**Acceptance:**
- Slow / unavailable Xtream servers do not loop forever or stall
  initial sync indefinitely.
- Failure strategy is explicit (timeout budget, max retries,
  user-visible error if appropriate).
- Match the resilience bar of the Dispatcharr enrichment path
  (cap-of-N concurrency, per-call timeout, circuit breaker on
  consecutive failures).

**Estimated effort:** 1-2 hours.

#### T2.3 Improve onboarding validation clarity

**Files:** `Features/Onboarding/AddServerView.swift`
(form section + Test Connection logic).

**Goal:** make invalid form state visible instead of just
greying out the action button.

**Acceptance:**
- Required-field errors surface inline as the user edits.
- URL-syntax mistakes are diagnosable without tapping submit.
- Dispatcharr / Xtream / M3U expectations are clearer in the
  form copy.

**Estimated effort:** 2-3 hours.

### Tier 3: Reframed Cleanup (Lower Priority)

#### T3.1 Simplify the defer-task semaphore signal pattern

**Files:** `Networking/StreamingAPIs.swift:1316, 2440, 2511`.

**Goal:** make permit lifetime explicit. Not a proven deadlock;
this is a code-quality cleanup.

**Acceptance:**
- Permit acquisition / release is paired without a spawned task,
  OR a `Sendable` release-token pattern with `deinit` signal.
- Optional: instrumented stress test under cancellation if the
  team wants the deadlock concern formally closed out.

**Estimated effort:** 1 hour.

#### T3.2 Reframe or drop the GuideStore breaker reset finding

**Files:** `Features/LiveTV/EPGGuideView.swift:1215, 1230-1237`.

**Goal:** any remaining concern is framed as logic/policy, not
thread safety. `@MainActor` already serializes the state.

**Acceptance:**
- Audit language corrected (already done in v2 of this report).
- If a behavior issue with the breaker policy is discovered in
  real use, address as a UX/policy fix not a concurrency fix.

**Estimated effort:** zero (already reframed in audit).

### v1.6.24+ Backlog

Everything in Section 4 (MEDIUM polish):
- God-file extraction (HomeView, MPVPlayerView, SettingsView,
  StreamingAPIs, EPGGuideView, ChannelListView).
- EPGData map persistence across launches.
- Per-program category cache across launches.
- VOD URLSession sharing.
- LRU eviction on EPGCache.
- Streaming JSON parser for getEPGGrid.
- Dynamic Type / Reduce Motion / VoiceOver coverage on custom
  cells.
- Reduce Motion in onboarding animations.
- `loadAllEPG` reentrance guard (correctness, not blocker; demoted
  by Codex from v2's HIGH list).
- Deeper UX polish (loading-spinner timeouts, empty-state CTAs,
  in-progress-vs-completed recording visual distinction, "Watch
  Live" CTA discoverability).

### Total Estimated Effort

- **Tier 1:** 4-6 hours (5 items).
- **Tier 2:** 4-6 hours if recording sync is implemented; 2-3
  hours if recording stays device-local.
- **Tier 3:** 1 hour.
- **Total v1.6.23:** 9-13 hours best case, 12-18 hours if
  recording sync ships.

The MEDIUM and LOW items in Section 4 are appropriate backlog
material for v1.6.24+.

---

## Section 7 - Open Questions for Codex / Gemini / DeepSeek

Specific questions where a second opinion would be most valuable:

1. **Defer-task signal pattern fix**: my proposed fix (synchronous
   signal in defer) requires AsyncSemaphore.signal() to be callable
   without await. Is there a cleaner pattern using a Sendable
   release-token (struct with a single-use flag + deinit signal) that
   also handles cancellation correctly?

2. **Cross-origin redirect policy**: should we strip ALL auth on
   cross-origin redirect (HTTP standard), or allow same-second-level-
   domain (e.g., `dispatcharr.example.com` -> `cdn.example.com`)?
   The strict standard interpretation breaks some legitimate
   reverse-proxy setups.

3. **SSRF on image URLs**: blocking RFC-1918 hosts breaks LAN-only
   Dispatcharr setups (where the user's `192.168.1.10` server
   legitimately serves logos). Should we whitelist the user's
   configured server's host as the only acceptable LAN target?

4. **Recording sync conflict resolution**: same-device recordings can
   be matched by `remoteRecordingID`. But what about local
   recordings (no remote ID)? Match by `(scheduledStart, channelID,
   programTitle)` triple? Risk of false positives.

5. **Privacy manifest scope**: which "Required Reason API" categories
   does AerioTV trip? File timestamps from playlist last-modified
   checks? UserDefaults across the app? System uptime in
   PlaybackDiagnostics? Default categories I'm missing?

6. **mpv log sanitization**: mpv's log callback fires from a non-Swift
   thread. Routing through DebugLogger.sanitize requires marshaling.
   Is there a lighter-weight string-prefix-based sanitizer that can
   run inline without allocation overhead?

7. **EPGData map persistence**: caching the 19,500-row map for 7-30
   days is the obvious optimization, but what's the right TTL? When
   does Dispatcharr typically refresh its EPGData rows?

8. **Multi-server failover**: do we add it? Most users have one
   server. But some have a primary + secondary for redundancy. The
   architecture allows it (active-server flag), but the orchestrator
   doesn't iterate.

9. **KVS payload telemetry**: the threshold for "warn the user"
   should be what fraction of 1MB? 80%? 95%? And how do we surface
   it without being annoying?

10. **Bloat extraction priority**: HomeView.swift is 4,975 lines.
    Top three candidate extractions are (1) VODStore -> separate
    file, (2) ChannelOrchestrator (the runChannelServerTaskBody
    method), (3) MainTabView body breakdowns. Order matters; which
    gives the biggest readability win for the smallest risk?

---

## Section 8 - Appendix: Per-Agent Findings

The 12 individual agent reports contain more detail than this
synthesis. The full reports cite file:line for every finding. This
synthesis distills to the highest-leverage items.

**Agents and their verdicts:**

1. **Dispatcharr-API endpoint compliance**: ZERO VIOLATIONS.
2. **Xtream Codes correctness**: PASS with three gaps (3.5).
3. **M3U correctness**: PASS with five gaps (1.3).
4. **Credential security**: NO SHOW-STOPPERS, but mpv stderr/stdout
   sanitization is HIGH.
5. **URL construction safety**: TWO CRITICAL (open redirect, SSRF).
6. **Concurrency safety**: TWO CRITICAL (defer-task races,
   circuit-breaker reset).
7. **Memory and performance**: SEVERAL HIGH (URLSession allocations,
   EPGData map persistence).
8. **Code quality and bloat**: AS EXPECTED, six god files.
9. **Error handling**: SEVERAL HIGH (silent failures in recording,
   VOD search, iCloud sync).
10. **SwiftData / iCloud sync**: SEVERAL HIGH (Recording not synced,
    KVS quota, recording orphans).
11. **App Store readiness**: ONE BLOCKER (orphaned entitlements),
    ONE MEDIUM (PrivacyInfo.xcprivacy).
12. **UX and accessibility**: SEVERAL HIGH (form validation,
    VoiceOver, dynamic type).
13. **Network resilience**: GENERALLY GOOD with several MEDIUM
    polish items.

Combined: NO CRASH-LEVEL BUGS detected. Five must-fix items before
public release. About 15-20 hours of work to reach public-ready
state.

---

End of audit report. v1.6.23 should land the five must-fix items
plus the highest-leverage HIGH items. Hand this report to Codex,
Gemini, and DeepSeek for cross-review before starting the v1.6.23
fix cycle.
