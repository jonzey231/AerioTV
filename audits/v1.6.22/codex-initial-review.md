# Aerio Code Review

Review date: 2026-05-02

## Scope

This review is based on the current authored Aerio codebase in:

- `App/`
- `Design/`
- `Features/`
- `Models/`
- `Networking/`
- `Shared/`
- `TopShelfExtension/`
- `SupportingFiles/`
- `project.yml`
- checked-in Xcode project metadata where relevant

I also re-checked the previously reported DVR, VOD progress, sync, and XMLTV issues so this writeup only carries forward problems that still appear to exist in the current code.

## Executive Summary

The earlier high-severity issues around:

- immediate local DVR start
- Dispatcharr channel ID fallback to `0`
- playback from `MyRecordings`
- watch-progress collisions on `vodID`
- missing `seriesID` in watch-progress sync
- XMLTV whitespace collapse

all appear to be addressed in the current code.

The most important remaining product bug is:

1. **Future local recordings are still offered in the UI but cannot actually begin.**

The main non-runtime concerns that still need deliberate cleanup are:

2. **The checked-in XcodeGen spec no longer matches the real Aerio project.**
3. **Signing/access-group configuration is still hardcoded to one developer identity.**
4. **ATS is still disabled globally, which is a significant security tradeoff.**
5. **The repo/app still has bloat and maintainability issues that increase future bug risk.**

The sections below are written to be implementation-friendly so Claude can address them directly.

---

## Finding 1

### [P1] Future local recordings are still impossible despite being offered in the UI
**Primary file:** `Features/LiveTV/RecordProgramSheet.swift`

### Summary

The current code correctly starts **immediate** local recordings, but it still does not provide a working path for **future** local recordings. The UI continues to let the user choose `This device` for a future Dispatcharr program, but the resulting scheduled row has no code path that can ever start the recording.

### Evidence in code

#### 1. The sheet still offers `This device` as a valid destination for Dispatcharr recordings
In `RecordProgramSheet`, the Dispatcharr destination picker includes:

- `Dispatcharr server`
- `This device`

Relevant area:
- `Features/LiveTV/RecordProgramSheet.swift`
- around the destination picker in the iOS form

#### 2. Future local recordings are intentionally left idle
In `scheduleRecording()`, the local-recording branch only starts the recording when:

```swift
if destination == .local && rec.effectiveStart <= Date()
```

So only immediate-start local recordings are launched. The surrounding comments explicitly say future local recordings are:

- left as `.scheduled`
- expected to stay idle
- waiting for either:
  - a future scheduler, or
  - a manual start path

Relevant area:
- [RecordProgramSheet.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/RecordProgramSheet.swift:599)

#### 3. There is no actual manual-start path in the DVR screen
The current `MyRecordingsView` actions for upcoming items still expose only:

- `Cancel`

There is no:

- `Start Now`
- `Begin Local Recording`
- `Record Locally Now`

And there is no other visible caller besides `RecordProgramSheet` that invokes:

```swift
RecordingCoordinator.startLocalRecording(...)
```

Relevant files:
- [MyRecordingsView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Settings/MyRecordingsView.swift:321)
- [RecordProgramSheet.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/RecordProgramSheet.swift:628)

### Why this is a real bug

This is not just an “unimplemented future enhancement” hidden from users. The app currently presents a workflow that looks legitimate:

1. User opens a future program on a Dispatcharr playlist.
2. User chooses destination = `This device`.
3. User taps `Record`.
4. App creates a scheduled recording row.

From the user’s perspective, that implies the app accepted the recording request.

But in reality:

- the row will never auto-start
- there is no exposed UI to start it manually later
- therefore the recording can never succeed

That is a correctness issue, not just missing polish.

### User-visible impact

- Users can believe a future local recording is scheduled successfully.
- The app will silently miss the recording.
- The scheduled row becomes misleading state in `MyRecordings`.
- This is especially confusing because the immediate local recording path now works, so users are likely to trust the destination.

### Root cause

The codebase currently supports:

- immediate local recording
- future Dispatcharr server-side recording

But it does **not** support:

- future local recording scheduling

The UI still exposes `This device` for cases where only one of those two models works.

### Recommended fix directions

Claude should choose one of these and implement it end to end:

#### Option A: Disallow future local recordings in the UI
Best if the product decision is “local recording only works for Record from Now.”

Concrete changes:
- In `RecordProgramSheet`, when `!isLive`, either:
  - hide `This device`, or
  - disable it with explicit explanatory copy.
- Ensure a future program cannot produce a `.scheduled` local recording row unless a real start path exists.
- Add user-facing messaging explaining that only Dispatcharr server-side recording supports scheduled future recordings.

#### Option B: Allow future local rows, but add a manual start path
Best if the intended behavior is “Aerio can hold the schedule, but the user must start it manually.”

Concrete changes:
- Add a `Start Now` action for upcoming local recordings in `MyRecordingsView`.
- That action must call `RecordingCoordinator.startLocalRecording(...)`.
- Decide whether starting manually should:
  - keep original `effectiveEnd`, or
  - recompute duration relative to “now.”
- Update copy in the sheet and DVR screen so the user understands the behavior.

#### Option C: Implement a real future local scheduler
Best if the intended product is true scheduled local DVR.

Concrete changes:
- Add a scheduling mechanism that triggers at `effectiveStart`.
- Handle app foreground/background limitations explicitly.
- Add failure states for:
  - app not running
  - app backgrounded
  - no stream URL available
- Update UI copy to reflect actual guarantees.

### Acceptance criteria

Claude’s fix should make one of these true:

- The user can no longer schedule an impossible future local recording.
- Or the user can manually start that local recording later from the UI.
- Or the app truly auto-starts it at the scheduled time.

Today, none of those are fully true.

---

## Finding 2

### [P2] XcodeGen spec still no longer represents the Aerio app
**Primary file:** `project.yml`

### Summary

The checked-in `project.yml` still describes an older `Dispatcharr`-branded project instead of the actual Aerio app state. Anyone regenerating the project from XcodeGen would get the wrong app identity, wrong resources, and wrong sharing configuration.

### Evidence in code

The current `project.yml` still contains stale values such as:

- `name: Dispatcharr`
- target named `Dispatcharr`
- `App/DispatcharrSplash.mp4`
- `CFBundleIdentifier: app.molinete.Dispatcharr`
- app-group values for `group.app.molinete.Dispatcharr`
- Top Shelf bundle ids under `Dispatcharr.TopShelf`

Relevant file:
- [project.yml](/Users/loganjones/Documents/xcode/iOSDev/Aerio/project.yml:1)

### Why this matters

This is a tooling/infrastructure bug, not a runtime crash, but it is still meaningful:

- contributors cannot trust project generation
- CI or automation based on XcodeGen would generate the wrong project
- onboarding becomes confusing because the checked-in Xcode project and XcodeGen spec disagree
- any future “regenerate project” maintenance step becomes risky

### Risk profile

This can cause:

- accidental rebranding regressions
- broken resources
- mismatched bundle identifiers
- mismatched entitlements/app-group settings

### Root cause

The repo has evolved, but `project.yml` did not get updated in lockstep with the real Xcode project.

### Recommended fix

Claude should fully reconcile `project.yml` with the checked-in Aerio project.

Concrete tasks:

1. Rename the project/target metadata from `Dispatcharr` to the actual Aerio naming.
2. Replace stale bundle identifiers with current ones.
3. Replace stale app-group references with current ones.
4. Fix the splash resource path.
5. Compare the generated shape against the current `.xcodeproj` and make sure the spec is actually authoritative again.

### Acceptance criteria

- Running XcodeGen should reproduce the current Aerio project structure closely enough to be trusted.
- No stale `Dispatcharr`-only identifiers should remain in `project.yml` unless intentionally preserved for migration.

---

## Finding 3

### [P2] Signing and keychain sharing are still hardcoded to one developer identity
**Primary files:**
- `Aerio_tvOS.entitlements`
- `TopShelfExtension/AerioTopShelf.entitlements`
- `Aerio.xcodeproj/project.pbxproj`

### Summary

The app, tvOS target, and Top Shelf extension still hardcode a specific team/developer identity into signing and keychain-sharing configuration.

### Evidence in code

Examples still present:

- `47DTJ3Q67T`
- `47DTJ3Q67T.aerio.topshelf.shared`
- checked-in `DEVELOPMENT_TEAM = 47DTJ3Q67T`

Relevant files:
- [Aerio_tvOS.entitlements](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Aerio_tvOS.entitlements:27)
- [AerioTopShelf.entitlements](/Users/loganjones/Documents/xcode/iOSDev/Aerio/TopShelfExtension/AerioTopShelf.entitlements:5)
- [project.pbxproj](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Aerio.xcodeproj/project.pbxproj:1117)

### Why this matters

This makes the codebase brittle outside the original signing environment:

- other developers cannot easily sign the app under a different team
- forks and open-source reuse are harder
- keychain sharing is coupled to one fixed access-group identity
- CI under another account becomes more fragile

### Security/privacy angle

This is not a direct secret leak, but it is still security-relevant because:

- access-group behavior is security-sensitive
- hardcoding one identity makes it harder to audit and parameterize sharing behavior
- accidental mismatch can break shared keychain access in ways that are hard to diagnose

### Root cause

The project appears to have grown around a working personal/team signing setup and never fully generalized that configuration.

### Recommended fix

Claude should make signing/share configuration more portable.

Concrete tasks:

1. Move `DEVELOPMENT_TEAM` out of checked-in hardcoded project state if practical.
2. Parameterize keychain access groups and related identifiers using build settings where possible.
3. Ensure entitlements derive from build variables instead of fixed literals when Apple allows it.
4. Document what values must remain fixed versus which can become configurable.

### Acceptance criteria

- A different developer/team should be able to sign the project with minimal manual surgery.
- Shared-keychain behavior should remain correct after parameterization.

---

## Finding 4

### [P2] ATS remains fully disabled for all domains, web content, and media
**Primary file:** `SupportingFiles/Info.plist`

### Summary

The app still opts out of App Transport Security as broadly as possible:

- `NSAllowsArbitraryLoads`
- `NSAllowsArbitraryLoadsInWebContent`
- `NSAllowsArbitraryLoadsForMedia`
- `NSAllowsLocalNetworking`

The comments are explicit about why this was done, but it is still a material security decision and should be treated as such.

### Evidence in code

Relevant section:
- [Info.plist](/Users/loganjones/Documents/xcode/iOSDev/Aerio/SupportingFiles/Info.plist:44)

The comments explicitly say there is “no upside to a narrower ATS policy in this app.”

### Why this matters

For a generic IPTV client, this may indeed be operationally convenient. But the tradeoff is real:

- any arbitrary HTTP endpoint can be loaded
- web content gets the same broad exception
- media paths get the same broad exception
- users are more exposed to insecure transport, interception, and downgrade scenarios

### Important nuance

This may be a deliberate product decision rather than a bug.

Still, Claude should treat it as a security/privacy finding because:

- it broadens the app’s trust boundary dramatically
- it affects every networked feature, not just stream playback
- the current configuration is the broadest exemption shape available

### Recommended fix options

Claude does not necessarily need to remove this, but should at least make the choice explicit and defensible.

Possible directions:

#### Option A: Keep the broad ATS exemption, but document it better
- Document this as a product/security tradeoff in `README` or build docs.
- Separate “required for IPTV interoperability” from “nice to have.”
- Be clear that this is intentional, not accidental drift.

#### Option B: Narrow the exemption scope
- Keep local-network support.
- Keep media exceptions if truly needed.
- Remove web-content/global exceptions if not actually exercised.
- Use per-domain exceptions where feasible.

#### Option C: Split behavior by subsystem
- Constrain web content separately from media and API requests.
- Let the IPTV playback surface stay broad if necessary, while tightening unrelated paths.

### Acceptance criteria

At minimum:

- the team should be able to explain exactly which ATS exceptions are still required and why

Ideally:

- the current exemption set is narrower than “everything everywhere”

---

## Secondary Observations

These are not current primary findings, but they are still worth tracking.

### 1. The repo/app still has bloat and maintainability pressure

Several authored files are very large, including:

- `Features/Home/HomeView.swift`
- `App/MPVPlayerView.swift`
- `Features/Settings/SettingsView.swift`
- `Networking/StreamingAPIs.swift`
- `Features/LiveTV/EPGGuideView.swift`
- `Features/LiveTV/ChannelListView.swift`

Why this matters:

- more cross-cutting state in one file
- harder review and debugging
- higher regression risk when editing unrelated behavior

This is not a single bug, but it increases the probability of future bugs.

### 2. Shared build/workspace state likely still causes local bloat

Even when excluded from the code review itself, the workspace still appears to carry a lot of generated/build state in-tree. That makes the project heavier to search, sync, and maintain.

### 3. Automated test coverage still appears limited

I still do not see visible XCTest/Swift Testing coverage in the authored Aerio tree.

The most valuable places for tests remain:

- DVR scheduling behavior
- watch-progress merge and lookup rules
- sync migration behavior
- XMLTV parser correctness
- deep-link routing

---

## Previously Reported Issues That Now Look Fixed

I’m listing these explicitly so Claude does not waste time re-fixing them blindly.

### Fixed or largely addressed

1. **Immediate local recordings never start**
   - now appears fixed for `Record from Now`

2. **Dispatcharr recordings use `Int(channelID) ?? 0`**
   - now replaced with a real `dispatcharrChannelID` path plus guarded fallback

3. **Completed recordings cannot be played from My Recordings**
   - playback funnel now exists through `playingRecording`

4. **Watch progress collides across servers**
   - `vodID` is no longer globally unique in SwiftData
   - logic now uses `(vodID, serverID)` semantics

5. **`seriesID` drops during sync**
   - now serialized/deserialized/merged

6. **XMLTV parser collapses spaces**
   - now accumulates raw text and trims at close

These should still be regression-tested, but they do not appear to be active findings in the current state.

---

## Recommended Fix Order

1. Resolve the future-local-recording dead-end.
2. Reconcile `project.yml` with the actual Aerio project.
3. Parameterize signing/access-group configuration where possible.
4. Reassess the current ATS policy and decide whether it remains intentionally broad.
5. Start paying down maintainability risk in the largest files.
6. Add focused tests around DVR/sync/parser behavior so these issues stay fixed.

---

## Claude Action Checklist

If Claude is going to address these findings directly, this is the shortest useful implementation checklist:

### Future local recordings
- Decide product behavior:
  - disable future local recordings, or
  - add manual start in DVR, or
  - build a scheduler
- Make UI and behavior match
- Ensure no impossible scheduled local rows can be created silently

### XcodeGen drift
- Update `project.yml` to match Aerio
- Remove stale `Dispatcharr` values
- Verify generated project shape against current checked-in project

### Hardcoded signing/access groups
- Parameterize team/access-group configuration where Apple tooling allows
- Reduce direct literals in project and entitlement files
- Verify app + Top Shelf extension sharing still works

### ATS posture
- Audit which exceptions are truly required
- Either tighten them or explicitly document/justify keeping them
