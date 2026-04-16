# Changelog

## v1.5.0 — 2026-04-16

### New

- **Commercial skip (Comskip).** Dispatcharr server-side users can enable
  commercial detection and removal when scheduling a recording. The toggle
  appears in the Record sheet whenever the destination is
  "Dispatcharr server"; processing runs on the server after the
  recording completes. Also exposes a new `applyComskip(id:)` API call
  for triggering it on existing recordings.
- **DVR auto-discovery.** Recordings scheduled from the Dispatcharr web
  UI (or from another device) now appear in AerioTV's DVR tab
  automatically. A reconciliation loop runs every 2 minutes at the
  tab-bar level, so the DVR tab lights up without the user having to
  open it first.
- **Recordings accessible via Files app (iOS).** Local recordings can
  now be browsed and exported from the iOS Files app under
  "On My iPhone → AerioTV".
- **Refreshed app icon** across all 15 sizes to match the current
  AerioTV branding.

### Fixed — iOS

- Long-pressing a channel card in the list view and selecting "Record
  from Now" now actually presents the record sheet. The presenter was
  previously scoped to the expanded guide panel only, so the sheet
  silently refused to appear when the card was collapsed.

### Fixed — tvOS (major UI overhaul)

- **Long-press in Guide / DVR / upcoming-schedule rows now fires
  precisely at 0.35s** via a new UIKit-backed press detector
  (`Shared/TVPressGesture.swift`). SwiftUI's `LongPressGesture` on tvOS
  fires on press release rather than at `minimumDuration`, which made
  the press feel sluggish at every threshold value.
- **Context-menu flash on EPG program cells and channel rows**
  replaced with a stable `.confirmationDialog` path. Rebuilding the
  `UIMenu` every time the cell re-rendered was causing a visible
  flash on each update.
- **Record sheet rebuilt for tvOS.** Presents via `.fullScreenCover`
  instead of the cramped centred `.sheet` modal, with a custom layout
  of pill buttons (Off / On, None / 5 min / 10 min / …) instead of
  the default Form rows whose oversized white focus halos obscured
  neighbouring controls.
- **DVR tab visuals unified.** Recording rows use the subtle accent-
  stroke + scale-bump focus treatment that matches the Live TV group
  filter bar and the rest of the app — no more system white halo.
- **Settings pages unified.** Network, DVR, Developer, and Appearance
  rewritten on top of the shared `TVSettings*` components
  (`TVSettingsNavRow`, `TVSettingsSelectionRow`, `TVSettingsToggleRow`,
  `TVSettingsActionRow`, `tvSettingsCardBG`). Focus treatment is now
  consistent across every Settings sub-page.
- **Guide-only on tvOS.** The Live TV tab always opens the Guide view;
  the List view is no longer offered.
- **CFBundleVersion warning resolved.** tvOS app's
  `CURRENT_PROJECT_VERSION` bumped to match the Top Shelf extension.
- **Console warning** `"Adding '_UIReplicantView' as a subview of
  UIHostingController.view is not supported"` resolved by wrapping
  the focusable press-detector UIView in a plain container.

### Notes

- New shared UIKit helper `Shared/TVPressGesture.swift` (`TVPressOverlay`,
  `PressCatcherView`) added to both the iOS and tvOS target sources in
  `Aerio.xcodeproj/project.pbxproj`.
- `DispatcharrAPI.Recording` gains a `comskip: Bool` field.
- `RecordingCoordinator.scheduleDispatcharrRecording(...)` and
  `DispatcharrAPI.createRecording(...)` each gain a
  `comskip: Bool = false` parameter.
- `reconcileDispatcharrRecordings(api:serverID:modelContext:)` now
  imports orphan remote recordings as new local rows (previously it
  only synced status or pruned deleted rows).
- All `TVSettings*` row components and `tvSettingsCardBG(_:)` promoted
  from `private` to internal so DVR / Developer / Appearance /
  Network Settings can share them.

---

## v1.4.0 — 2026-04-10

### New — DVR Recording
- **Schedule recordings from the EPG guide.** Long-press (or right-click on
  tvOS) any current or future program → "Record" to schedule with
  configurable pre-roll and post-roll buffers (None / 5 / 10 / 15 / 30 / 60
  min / Custom). Pre-roll is disabled for programs already in progress.
- **Dispatcharr server-side recording.** Dispatcharr API users can record
  directly on the server — recordings continue even when AerioTV is closed.
  Create, list, poll, stop, and delete recordings via the Dispatcharr REST API.
- **Local recording (foreground only).** XC, M3U, and Dispatcharr users can
  record to the device's local storage. Uses a dedicated URLSession with
  `.utility` QoS so playback of a separate stream is unaffected. Screen stays
  awake while recording. Warning: closing the app stops local recordings.
- **Download server recordings.** Long-press a completed Dispatcharr recording
  → "Save to Device" to download the file to local storage.
- **Delete server recordings.** Long-press a Dispatcharr recording → "Delete
  from Server" removes the recording and file from the Dispatcharr server.

### New — DVR Settings (Settings → DVR)
- Default pre-roll and post-roll buffers (applied to new recordings).
- Default recording destination per Dispatcharr server (server or local).
- Maximum local storage quota slider (1–200 GB, default 10 GB) with live
  usage bar (green → yellow at 80% → red at 95%).
- "Keep device awake during recording" toggle (default ON).
- Custom recordings folder picker (iOS/iPadOS only; tvOS uses
  Documents/Recordings/).
- My Recordings list with Scheduled / Recording / Completed segments,
  context menu actions (Play, Stop, Cancel, Delete, Save to Device).

### New — Custom User-Agent (Dispatcharr only)
- Dispatcharr users now send a `User-Agent` header on every API and stream
  request so the device appears by name in Dispatcharr's admin Stats panel.
- Default format: `AerioTV/1.4.0 (iOS; iPhone 15 Pro; Archie)`.
- Device nickname prompted during Dispatcharr onboarding (prefilled with
  device model, editable). Also editable per-server in Edit Playlist →
  User-Agent.
- Hidden entirely for XC / M3U servers (no surface consumes the UA).

### New — Onboarding improvements
- Dispatcharr onboarding now includes a device-name field and a recording
  destination picker ("Dispatcharr server" recommended, or "This device").

### Quota warnings
- **DVR Settings banner:** persistent warning when local usage ≥ 80%.
- **Schedule toast:** warning when scheduling a local recording near quota.
- **My Recordings toast:** banner when any recording is in failed state.

### Notes
- New SwiftData model `Recording` added — lightweight schema addition, no
  migration from v1.3.x required.
- `ServerConnection` gains `customUserAgent` and
  `defaultRecordingDestinationRaw` fields (both default to empty string /
  "dispatcharr_server" respectively — no migration needed).

---

## v1.3.4 — 2026-04-09

### Fixed
- **Live TV guide empty after switching server types.** Deleting an Xtream Codes
  (or M3U) server and re-adding the same source via Dispatcharr API would leave
  the EPG guide blank until a cache wipe. Root cause was three-fold and all
  three have been fixed:
  1. `loadFromCache` now filters `EPGProgram` rows by the active server's ID,
     so orphaned rows from a previous server can no longer leak into the guide.
  2. Deleting a server in Settings now cascade-deletes its `EPGProgram` rows
     instead of leaving them stranded in SwiftData.
  3. On launch, any `EPGProgram` rows whose `serverID` no longer matches an
     existing `ServerConnection` are pruned (one-time cleanup for users
     upgrading from a buggy build).

### Rebrand
- App display name, Info.plist usage strings, and all user-visible copy updated
  to **AerioTV** (previously a mix of "Aerio" / "Dispatcharr").
- About screen now shows accurate device model, last updated date, and first
  install date via a new `DeviceInfo` helper (previously hard-coded/placeholder).

### Notes
- No schema migration required — `EPGProgram.serverID` has existed since the
  model was introduced; existing rows simply had it populated as an empty
  string, which the orphan pruner cleans up automatically.
