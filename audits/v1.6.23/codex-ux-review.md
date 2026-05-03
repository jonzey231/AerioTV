# Codex UX Review for Claude

Date: 2026-05-02

Scope:

- UX and UI review of Aerio from the codebase side
- intended as a handoff for Claude
- focused on user-facing behavior, discoverability, interaction clarity, and flow quality
- not a visual design critique in the abstract

Important correction up front:

- I am **not** carrying forward the earlier "initial loading screen blocks Live TV too long" item as a UX bug.
- After rechecking the code and your product intent, that behavior is clearly deliberate and user-escapable.
- There is both an in-flow `Skip` path and a `Skip Loading Screen` setting, so that should be treated as an intentional product tradeoff, not an accidental UX flaw.

Relevant references for that intentional behavior:

- [HomeView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Home/HomeView.swift:3632)
- [HomeView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Home/HomeView.swift:3707)
- [ServerSyncView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Onboarding/ServerSyncView.swift:245)
- [AerioApp.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/App/AerioApp.swift:947)

So the real UX handoff below focuses on the remaining issues that still look actionable.

---

## Executive Summary

Aerio's UX is already more thoughtful than most IPTV apps in a few important ways:

- onboarding has gotten meaningfully clearer
- platform-specific behavior is being handled deliberately rather than forcing one UI across iPhone, iPad, and tvOS
- the app makes serious attempts to avoid half-broken states during first-run setup and background sync
- there is visible care around guide behavior, mini-player behavior, and multiview ergonomics

The biggest remaining UX issues are not broad "the app is confusing" problems. They are narrower but important:

1. Some key actions are still hidden behind discovery-heavy gestures.
2. Certain secondary controls behave in a way that destroys user context unexpectedly.
3. A few valuable workflows exist in the product, but the UI does not advertise them strongly enough for real users to find them.

The most important theme is this:

> Aerio often has the capability already, but some of the value is trapped behind long-press, context menu, or hidden-state interactions that many users will never discover.

That is a UX clarity problem more than a feature-completeness problem.

---

## Intentional Tradeoff, Not a UX Bug

Before the actual findings, it is worth explicitly documenting one item that should **not** be treated as a bug.

### Initial loading screen behavior is intentional

The initial launch experience is intentionally designed to keep the setup/loading cover visible until multiple startup tasks are done, but users are not trapped:

- `ServerSyncView` exposes a `Skip` action on initial launch
  - [ServerSyncView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Onboarding/ServerSyncView.swift:245)
- `MainTabView` wires an `onContinueAnyway` escape hatch
  - [HomeView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Home/HomeView.swift:3707)
- there is also a `Skip Loading Screen` user preference
  - [AerioApp.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/App/AerioApp.swift:947)

That means this is not "the app accidentally blocks people too long." It is a deliberate product choice with a user escape hatch and a persistent preference.

Claude should not spend time "fixing" this unless the product owner wants a different onboarding philosophy.

---

## Findings

### 1. iPhone channel actions are hidden behind long-press with no visible affordance

**Severity**

- UX severity: High

**Primary file**

- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:1787)

**What the code does today**

On iPhone/iOS channel rows behave like this:

- tap the row: starts playback
- long-press the row: opens a confirmation dialog with secondary actions

The long-press dialog is triggered here:

- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:1788)
- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:1793)

The dialog contains actions such as:

- add/remove favorite
- program info
- likely recording- or program-related actions depending on state

But in the visible row UI there is no obvious sign that these actions exist.

**Why this is a real UX issue**

This is not just a preference about where to place actions. It is a discoverability failure.

Most iPhone users will infer:

- row tap = play
- that's the entire interaction model

Very few mainstream users reliably discover long-press on list rows unless:

- the platform strongly trains them to expect it
- there is a visible `...`, chevron, swipe hint, or menu icon
- or the action is common enough in the ecosystem to be expected

For a channel list, long-press is not a sufficiently obvious home for:

- favorites
- metadata/program info
- extra playback-adjacent actions

Those are important actions, not obscure admin tools.

**User impact**

The practical user impact is:

- users miss the existence of favorites entirely, or discover them very late
- users may assume program info simply does not exist
- users may perceive the Live TV list as "play-only" even though the app supports richer interaction
- feature adoption stays low not because the feature is bad, but because the UI hides it

This is particularly costly because favorites are one of the highest-value retention features in a live-TV app.

**Why the current implementation probably happened**

From the code, this looks like a reasonable engineering compromise:

- tap already has an unambiguous primary action: play
- the row is information-dense
- adding more visible affordances risks clutter
- the confirmation dialog is technically clean and works well enough once discovered

So this is understandable. But it still leaves the user with hidden capability.

**What I would recommend**

Claude should preserve tap-to-play as the primary behavior.

The UX improvement should focus on making secondary actions discoverable without overloading the row.

Good options:

1. Add a visible trailing accessory button on iPhone.
   - A small `ellipsis.circle`, `info.circle`, or `star` affordance is enough.
   - Tapping it can open the same action dialog the long-press currently uses.

2. Surface favorites directly in-row.
   - A visible star toggle is especially defensible because favorites are a high-frequency action.
   - Even if program info remains in a secondary menu, favorites probably deserve first-class visibility.

3. Keep long-press as a power-user shortcut, but do not make it the only path.

**What not to do**

- Do not remove tap-to-play.
- Do not make the row itself open a menu first; that would slow down the core task.
- Do not add too many visible buttons on iPhone rows; that would swing too far toward clutter.

**Acceptance criteria**

Claude's fix should be considered good if:

- a first-time iPhone user can discover favorites without guessing long-press
- program info or additional actions have an obvious visible entry point
- tap-to-play remains fast and unchanged
- the row still feels clean, not overloaded

**Suggested implementation direction**

Likely file:

- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:1691)

The cleanest implementation is probably:

- add a trailing visible accessory in `iOSRow`
- keep existing long-press dialog behavior as backup
- route the accessory into the same dialog logic already used by `showCardMenu`

---

### 2. "Watch Live" for in-progress recordings is buried in a context menu

**Severity**

- UX severity: High

**Primary file**

- [MyRecordingsView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Settings/MyRecordingsView.swift:313)

**What the code does today**

When a Dispatcharr recording is in progress and has a playable live HLS URL, the code exposes `Watch Live` here:

- [MyRecordingsView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Settings/MyRecordingsView.swift:323)
- [MyRecordingsView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Settings/MyRecordingsView.swift:326)

But that action exists only inside the context menu.

The recording row itself does not visibly advertise:

- that in-progress viewing exists
- that this row is playable right now
- that the recording can be watched while still being captured

**Why this is a real UX issue**

This is one of the strongest UX issues in the current app because the feature is valuable and non-obvious.

"Watch while recording" is not a minor secondary function. For many DVR users, it is one of the most attractive behaviors in the entire feature set.

If the app hides that inside a context menu, most users will never know it exists.

That is especially costly because:

- it makes the DVR feel more passive than it actually is
- it undersells the sophistication of the recording system
- it turns a potentially delightful capability into an expert-only discovery

**User impact**

Users with active recordings are likely to assume:

- the row is only informational
- the only thing they can do while recording is stop it
- playback becomes available only after completion

That is the wrong mental model for a system that already supports live playback of in-progress recordings.

**Why the current implementation probably happened**

The current implementation is understandable from a code-organization standpoint:

- completed recordings already had menu-driven actions
- in-progress recordings got additional menu options appended
- context menu avoids clutter in a segmented recordings list

That is reasonable technically, but not ideal from a product-experience standpoint.

**What I would recommend**

The in-progress recording row should expose a direct primary CTA when live playback is possible.

Examples:

- a visible `Watch Live` button in the row
- row tap for in-progress Dispatcharr recordings could open live playback, if that matches the mental model better than using tap only for completed items
- a compact trailing play badge or pill

The important thing is not the exact visual. The important thing is:

- the affordance should be visible without long-press or context menu discovery

**Preferred UX behavior**

A good pattern would be:

- Completed local/server recordings: tap to play
- In-progress recordings with live stream available: tap to watch live, or show a visible `Watch Live` CTA
- Secondary destructive/admin actions remain in the context menu

That keeps primary actions visible and secondary actions tucked away.

**What not to do**

- Do not remove the context menu; it still makes sense for stop/delete/admin paths.
- Do not make the user guess whether live playback is available from status text alone.

**Acceptance criteria**

Claude's fix is successful if:

- a user can tell from the row itself that an in-progress recording is watchable
- the path to playback is visible
- stop/cancel/delete remain available without cluttering the primary interaction

**Suggested implementation direction**

Likely file:

- [MyRecordingsView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Settings/MyRecordingsView.swift:134)

The fix likely belongs in:

- the visible row rendering for in-progress recordings
- not only in `contextMenuItems(for:)`

---

### 3. Hiding iPad channel search destroys the active query

**Severity**

- UX severity: Medium

**Primary file**

- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:835)

**What the code does today**

In the iPad chip row, the search button toggles `iPadSearchPresented`.

When search is turned off, the code also clears the query:

```swift
if !iPadSearchPresented { searchText = "" }
```

Reference:

- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:835)
- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:838)

**Why this is a real UX issue**

Collapsing UI chrome and clearing user intent are two different actions.

Right now, Aerio treats them as the same thing.

That means a user who:

- searches for a set of channels
- wants to temporarily reclaim vertical space
- hides the search control

also loses the active filter immediately.

That feels destructive and surprising.

Most users will expect:

- hiding the control hides the control
- clearing the query is a separate action

**User impact**

This is not catastrophic, but it creates friction during exploration:

- users lose filtered state accidentally
- the UI feels less forgiving
- repeated searches become more annoying than they need to be
- it discourages using search as a lightweight temporary lens

On iPad especially, preserving temporary working context usually feels better than aggressively resetting it.

**Why the current implementation probably happened**

This was likely done to keep the hidden state semantically "clean":

- if the search UI is hidden, maybe the list should not still be filtered invisibly

That is a valid concern. Invisible active filters can also be confusing.

So there is a real design tradeoff here:

- preserve search state when hiding the field
- or avoid hidden filter state

But the current behavior chooses the more destructive path.

**Better UX options**

There are two reasonable approaches.

### Option A: Preserve the query and show subtle active-filter feedback

This is my preferred direction.

Behavior:

- hiding the search field does not clear the query
- if a query is active while search UI is hidden, the search icon can stay filled/highlighted
- optional small badge/dot could indicate filtered state

That preserves user intent while still avoiding invisible-state confusion.

### Option B: Keep current clearing behavior, but make it explicit

If product strongly wants "hidden search means no active filter," then the clearing should be a deliberate user action, not an automatic side effect.

For example:

- tapping the active search button when text exists could show a small "Clear search and hide?" confirmation
- or provide a dedicated clear action inside the search field

**What I recommend**

Use Option A:

- preserve `searchText`
- make the search button visually indicate that a filter remains active

That gives the best balance of:

- preserving user work
- keeping state understandable

**Acceptance criteria**

Claude's fix is successful if:

- hiding the iPad search UI does not automatically destroy the current query
- users can still tell when a search filter is active
- restoring the field brings back the previous query text

---

## Positive UX Notes Worth Preserving

This section is here so Claude does not interpret the review as "rewrite everything."

There are several UX decisions in Aerio that are already good and should be preserved.

### 1. Onboarding validation is much better than before

The inline validation block in `verifySection` is a meaningful improvement:

- [AddServerView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Onboarding/AddServerView.swift:719)

Why it works:

- the user is no longer left staring at a disabled verify button with no explanation
- the first missing issue is surfaced directly
- the message count hints that more remains without overwhelming the screen

This is good product thinking and should stay.

### 2. Home WiFi / local URL onboarding is thoughtful

The local-network setup section in onboarding is one of the more user-considerate parts of the app:

- [AddServerView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Onboarding/AddServerView.swift:554)
- [AddServerView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Onboarding/AddServerView.swift:612)

Strong points:

- it avoids surprise permission prompting on first view open
- it gives the user an explicit refresh button
- it explains why Location/Precise matters
- it provides a one-tap Settings deep link instead of just a warning

That is a good example of respecting permission fatigue while still teaching the feature.

### 3. Loading-screen behavior is a deliberate product choice with escape hatches

As noted above, this should stay framed as intentional:

- [ServerSyncView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Onboarding/ServerSyncView.swift:245)
- [HomeView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Home/HomeView.swift:3707)

The important product takeaway is:

- users are not trapped
- power users can opt out

So Claude should avoid "fixing" this unless asked to change the product philosophy.

---

## Recommended Fix Order for UX

If Claude is addressing UX issues next, I would prioritize them in this order:

### Priority 1

- Make iPhone channel secondary actions visibly discoverable.

Reason:

- affects core daily navigation
- impacts favorites adoption
- likely affects a large share of users

### Priority 2

- Surface `Watch Live` directly for in-progress recordings.

Reason:

- high-value DVR capability
- currently hidden behind a low-discoverability path
- good payoff relative to likely implementation size

### Priority 3

- Preserve iPad search query when collapsing search UI, with visible active-filter feedback.

Reason:

- smaller issue
- lower stakes than the first two
- still a meaningful polish improvement

---

## Implementation Notes for Claude

This section is intentionally practical.

### For the iPhone channel actions issue

Candidate area:

- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:1691)

Recommended shape:

- keep row tap as play
- add one visible secondary affordance
- route that affordance into the existing action dialog/menu logic
- optionally surface favorite as a dedicated visible toggle

### For the in-progress recording issue

Candidate area:

- [MyRecordingsView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/Settings/MyRecordingsView.swift:134)

Recommended shape:

- add a visible in-row CTA when `rec.isInProgress` and `dispatcharrFileURL != nil`
- keep stop/delete/admin actions in the context menu
- consider making row tap open live playback if that matches the broader recordings interaction model

### For the iPad search issue

Candidate area:

- [ChannelListView.swift](/Users/loganjones/Documents/xcode/iOSDev/Aerio/Features/LiveTV/ChannelListView.swift:835)

Recommended shape:

- remove automatic `searchText = ""` on collapse
- indicate active search state visually even while field is hidden
- preserve text when the field is shown again

---

## Verification Checklist

Claude should verify the UX fixes with actual interaction thinking, not just compile success.

### For channel-row discoverability

- Can a first-time iPhone user find favorites without guessing long-press?
- Can a user see there is "more" available from a row?
- Does tap-to-play still feel immediate?

### For in-progress recording playback

- Is it visually obvious that an active recording can be watched now?
- Is the primary playback action visible?
- Are destructive/admin actions still available but not overexposed?

### For iPad search preservation

- Does hiding search preserve the current filter?
- Can the user still tell the list is filtered?
- Does re-showing search restore the previous query cleanly?

---

## Bottom Line

The remaining UX issues in Aerio are mostly not about missing features. They are about **discoverability and interaction clarity**.

The app already has more capability than it visibly communicates in a few key areas:

- Live TV row actions
- in-progress DVR playback
- iPad search state behavior

That is good news, because these are often high-leverage fixes:

- relatively smaller than architecture work
- directly felt by users
- likely to increase feature adoption and perceived polish quickly

If Claude addresses only three UX items next, they should be:

1. visible iPhone channel secondary actions
2. visible `Watch Live` for in-progress recordings
3. non-destructive iPad search collapse behavior
