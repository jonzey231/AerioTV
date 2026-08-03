# AerioTV Settings UI Redesign
## Adaptive, form-factor-native Settings for iOS, iPadOS, tvOS, Android phone, Android tablet, and Android TV

Date: 2026-07-30
Status: Plan only. No code changes have been made.
Revision 2 (2026-07-30): adversarial review pass. Every audit claim in section 2 was re-verified against both trees and held exactly. Design amendments from the review are integrated inline below and marked "Rev 2". Two canon amendments (approved): a Set Active row is added to Playlist Detail on all form factors, and the TV playlist hint copy changes accordingly; root-inline sections moving into panes on two-pane form factors is ruled "layout only". The Remote Control settings submenu (Apple: `RemoteControlSettingsView.swift`, currently only on `wip/fix-pack-2026-07-24`; Android: `RemoteControlSettingsScreen.kt`, on main) is explicitly in scope; see A3a and the per-screen tables.

---

# 1. Context and goals

Users report that the TV apps' Settings feel like blown-up mobile apps, and that the iPad app does not take advantage of the additional screen real estate. A full audit of both codebases confirms the reports:

**Apple side** (`/Users/loganjones/Documents/xcode/iOSDev`, source under `Aerio/`):
- iPad renders the identical iPhone code path: a `List(.insetGrouped)` inside a `NavigationStack` with zero size-class checks, no width caps, no `readableContentGuide`, and no `NavigationSplitView` anywhere in the entire app. On a 1024 to 1366pt wide screen this is one column of 44pt rows with a very long measure.
- On tvOS, only 3 of 12 settings screens received the v1.7.5 1200pt centered reading column (Network, EditServerPage, ServerDetailView). Every other screen spans roughly 1760 to 1840pt at 1920. The code comment at `SettingsView.swift:3363-3372` literally records the field report that tvOS settings "look like stretched out iPhone/iPad screens." The fix was started and never finished.
- `SettingsView.swift` is a 4,385-line god file holding the root screen, every tvOS row component, the playlist detail screen, both playlist editors, the Network screen, the iOS category color editors, and the tvOS dismiss machinery.

**Android side** (`/Users/loganjones/Documents/androidstudio/AerioTV`):
- One shared composable tree serves phone, tablet, and TV, differentiated only by inline `isTv` branches. The sole adaptivity is a width cap (600dp on Medium, 700dp on Expanded and TV) applied by `Modifier.adaptiveFormWidth()` plus a hand-rolled centering Box, and the Developer screen is missing it entirely (renders edge to edge on tablet and TV).
- There is no two-pane layout anywhere in Settings on any form factor.
- The settings design system is fragmented into at least six parallel implementations: the shared `TvSettingsRows.kt` set used by sub-screens, a private incompatible set on the root screen with visibly weaker focus treatment, plus private re-implementations inside Appearance, DVR, Developer, Network, PlaylistDetail, and EditPlaylist.

**Goals:**
1. TV apps (tvOS and Android TV): a proper 10-foot two-pane Settings with a persistent left rail of categories and a detail pane on the right.
2. iPad and expanded-width Android tablet: a sidebar plus detail split view that collapses to stacked navigation when narrow.
3. Phones: unchanged navigation, with only consolidation-level polish. Visually near-frozen.
4. The July 2026 cross-platform settings unification is FROZEN: section order, grouping, and copy stay identical on all platforms. Only layout and presentation change.
5. The Apple plan and the Android plan are separate but structurally matching, so users who run both feel at home.
6. House rules: no em dashes anywhere; no third-party IPTV app names in any copy or source.

**Scope includes** the playlist detail screen, the edit playlist flow, the playlists management list, and the Manage Groups surface, in addition to every preference sub-screen. Rev 2: scope explicitly includes the Remote Control settings submenu on both stacks, including its slot-choice sub-pages (Apple `TVSlotChoiceListView`) and slot-choice dialogs (Android `TvActionMenuDialog` pickers).

**Rev 2 canon amendments (approved 2026-07-30):**
1. **Playlist activation on rail and sidebar form factors.** Today Android's root list activates a playlist on OK/tap while Apple's root opens the detail and activates via a secondary action. The rail model makes focus/selection show the detail, so OK-to-activate cannot survive on the TV rail. Ruling: a **Set Active** row becomes the FIRST row of the existing Actions section on the Playlist Detail page on ALL form factors and BOTH platforms (disabled with a checkmark state when already active, mirroring the tvOS root action that already exists at `SettingsView.swift:801-809`). Rail and sidebar playlist rows uniformly enter the detail. Phone roots keep their current tap semantics unchanged (Android tap-to-activate stays on the phone root list). The Android TV hint copy "Press OK on a playlist to make it active" changes on TV ONLY to reflect enter-detail semantics; phone copy is untouched.
2. **Root-inline sections.** The root screens carry inline controls (Apple: iCloud Sync toggles, About rows; Android: the playlist summary block, About rows). On two-pane form factors these move INTO panes: Sync toggles into a Sync pane (see A3), About rows into the About pane, the Android playlist summary to the top of the Playlists pane (B3, unchanged). This is ruled a layout-only change: copy, ordering within each group, and grouping names are identical; only the hosting surface changes. Phone roots are untouched.

---

# 2. Audit summary (what exists today)

## 2.1 Apple

| Fact | Evidence |
|---|---|
| Settings is the last tab of a `TabView`, owning its own `NavigationStack` | `HomeView.swift:4430, 4465-4475`; `SettingsView.swift:96-122` |
| iPad = identical iPhone path, no adaptivity | `SettingsView.swift:120-122` (`#else` arm is plain `NavigationStack`), zero `horizontalSizeClass` uses in any Settings file |
| Every sub-screen is two hand-written bodies: `#if os(tvOS) tvOSBody #else iOSBody` | e.g. `AppearanceSettingsView.swift:80-93`; same shape in all sub-screens |
| A local `tvSection` helper is redefined 8 separate times | AppBehaviors:778, Developer:804, DVR:449, Multiview:183, RemoteControl:268, SyncCategories:190, SettingsView:3383 and :3601 |
| tvOS navigation is a hybrid: `NavigationPath` string routes plus classic `NavigationLink`s tracked by a hand-rolled `SettingsDismissStack` | route switch at `SettingsView.swift:541-568`; dismiss stack at :4322-4385 with rationale comment :4293-4320; `popRequested`/`isSubviewPushed` bindings ride to `HomeView.swift:3186-3193, 5405` because `MainTabView.onExitCommand` swallows Menu presses |
| Only 3 of 12 tvOS screens have the 1200pt cap | `SettingsView.swift:3595` (Network), :3374 (EditServerPage), :1976 (ServerDetailView) |
| Root list identity is keyed on theme to force a UITableView teardown on theme change (resets scroll) | `SettingsView.swift:507` |
| iPad top tab capsule collision: the OnDemand tab compensates with a 72pt inset, Settings does not | `OnDemandView.swift:15-20, 129-149` |
| Existing precedents to reuse | idiom-scaled adaptive grid `MoviesView.swift:119-136`; size-class column width `EPGGuideView.swift:2379, 2479`; the tvOS docked left rail `Features/LiveTV/GroupSidebar.swift` (fitted width, left-to-open / right-to-exit focus contract); the one-component-two-bodies convention (`StreamBufferSlider`, `DVRSegmentPill`) |
| Remote Control screen is tvOS-only and currently unreachable (hidden for 1.8.4) | nav entry commented at `SettingsView.swift:880-885` |
| My Recordings is reachable both as a top-level tab and from DVR settings | `HomeView.swift:4447`; `DVRSettingsView.swift:233, 358` |
| Manage Groups is presented from the content tabs, not Settings, and has its own tvOS row set | `Design/Components/ManageGroupsSheet.swift` (668 lines), presented from `ChannelListView.swift:505`, `MoviesView.swift:237`, `TVShowsView.swift:159` |

## 2.2 Android

Paths relative to `app/src/main/java/com/aeriotv/android/`.

| Fact | Evidence |
|---|---|
| Settings is a tab; the whole navigator is `SettingsTabContent`: local `mutableStateOf` booleans plus a flat `when` dispatcher and a manual `BackHandler` whose ordering is load-bearing | `feature/main/MainScaffold.kt:1311-1456`; BackHandler :1344-1358 (LogViewer is checked before Developer) |
| Route model is `enum class SettingsSection` (title/subtitle/icon per entry) | `feature/settings/SettingsScreen.kt:751-801` |
| One composable tree for all form factors; only inline `isTv` branches | `rememberIsTvDevice()` at `feature/settings/TvSettingsRows.kt:406-411` |
| Adaptivity is a width cap only: Compact unlimited, Medium 600dp, Expanded and TV 700dp, centered by hand-rolled Boxes | `ui/adaptive/Adaptive.kt` (`rememberViewport`, `formMaxWidth`, `adaptiveFormWidth`) |
| Developer screen is missing the cap (edge-to-edge on tablet/TV); LogViewer too | `DeveloperSettingsScreen.kt:122`; `LogViewerScreen.kt:150` |
| Design-system fragmentation: shared `TvSettingsRows.kt` vs a private root-screen set with weak focus (wash only, no border or scale) vs 5 more private re-implementations | `TvSettingsRows.kt` (608 lines, full set); `SettingsScreen.kt:467 groupRowFocus`, :474, :502; `AppearanceSettingsScreen.kt:312`; `DvrSettingsScreen.kt:289`; `DeveloperSettingsScreen.kt:389`; `NetworkSettingsScreen.kt:208`; `PlaylistDetailScreen.kt:409`; `EditPlaylistScreen.kt:605` |
| androidx.tv.material is declared but has zero imports anywhere; everything is material3 plus hand-rolled focus modifiers | `build.gradle.kts:157`; no Kotlin import in `app/src/` |
| TV plumbing that must be preserved | `settingsContentFocus` FocusRequester (`MainScaffold.kt:1359-1391`, stops focus fallback landing on the Live TV nav pill); `TvMenuGuard` latched activation; `FormFactorModal` (TV centered dialog because the M3 bottom-sheet drag handle steals D-pad focus); `TvActionMenuDialog`; `TvQrLinkDialog`; `TvKeyboardOnOkHost` + `tvFormFieldInput` + `TvImeNoJitterBringIntoViewSpec` (`ui/tv/TvFocus.kt:191, 244`); TV typography globally scaled 0.9 (`ui/theme/Type.kt:37`) |
| Two-pane precedent | `feature/livetv/GroupSidebar.kt` `GroupSidebarPanel` (text-measured 160 to 340dp rail), used as a real leading pane in `feature/player/ChannelListOverlay.kt:97-103` |
| SettingsActionRow deliberately swallows clicks instead of disabling, because disabled clickables drop out of D-pad traversal | `TvSettingsRows.kt:279` |
| Manage Groups lives in Live TV / On Demand modals, not Settings | `feature/livetv/ManageGroupsSheet.kt` (561 lines), uses `FormFactorModal` |
| Platform gates | Remote Control row TV-only; App Updates sideload-flavor-only; Casting section phone-only; Display (refresh rate) section TV-only; Channel Flip footer phone-only |

## 2.3 Canonical content map (FROZEN, both platforms)

Root order: **Playlists** (inline list, Add, Manage), **App Settings** (Appearance, App Behaviors, Multiview, Network, plus Remote Control on TV and App Updates on sideload Android), **Sync**, **DVR**, **Developer**, **About** (with the memorial line).

Sub-screens: Appearance (theme, appearance/glass, preview, display scale, channel list, category colors, palette), App Behaviors, Network, DVR, Multiview, Sync (Android) / Sync section + Sync Categories (Apple), Developer (with Log Viewer), Remote Control (TV), Playlists list, Playlist Detail (Connection Details, Actions, EPG Cache, Full Refresh, Danger Zone), Edit Playlist (Connection, Local Network, Authentication, On Demand, Guide History, per-platform extras), Add More Categories, About.

None of this changes. Layout only.

---

# 3. Plan A: Apple (iOS / iPadOS / tvOS)

All builds with Xcode 27: `DEVELOPER_DIR=/Applications/Xcode-beta.app`.

## A1. Shared route model

New file `Aerio/Features/Settings/SettingsDestination.swift`:

```swift
// Rev 2: pane destinations ONLY. My Recordings is deliberately NOT a case here:
// it stays a classic full-screen push (and a top-level tab), and keeping it out
// of CaseIterable means no rail/sidebar builder can ever list it by accident.
enum SettingsDestination: String, Hashable, CaseIterable {
    case appearance    = "appearance"
    case appBehaviors  = "app-behaviors"
    case remoteControl = "remote-control"
    case multiview     = "multiview"
    case network       = "network"
    case dvr           = "dvr"
    case sync          = "sync"              // Rev 2: hosts the root Sync toggles; see A3
    case syncCategories = "sync-categories"
    case developer     = "developer"
    case about         = "about"
}

enum SettingsRoute: Hashable {
    case category(SettingsDestination)
    case server(ServerConnection.ID)
    case editServer(ServerConnection.ID)
    case myRecordings                        // Rev 2: classic push, never a pane
}
```

- Rev 2: raw values are EXPLICIT because today's route strings are hyphenated ("app-behaviors") and Swift's derived raw values would not match. They matter only during the mechanical conversion of the `navigationDestination(for: String.self)` switch at `SettingsView.swift:541-568`; nothing else persists these strings.
- Carrying the server ID inside `.editServer` eliminates the `serverToEdit` state plus `onDisappear { serverToEdit = nil }` re-push hack at :552-565.

## A2. iPhone and iPad

**Explicit idiom fork** in `settingsNavigationStack` (`SettingsView.swift:96-122`):

```swift
if UIDevice.current.userInterfaceIdiom == .pad {
    splitBody                              // NavigationSplitView
} else {
    NavigationStack { settingsContent }    // untouched iPhone path
}
```

The fork, rather than trusting NavigationSplitView's automatic collapse heuristics on iPhone, guarantees the iPhone view tree is byte-identical.

**iPad split view:**
- `NavigationSplitView(columnVisibility: $columnVisibility)` with a `@State` initialized to `.all` (Rev 2: not `.constant(.all)`, which would kill the standard sidebar toggle affordance users expect on iPadOS).
- Sidebar = the existing root List content in the frozen order (Playlists, App Settings, Sync, DVR, Developer, About), using `List(selection: $selectedRoute)` so rows get the standard iPadOS selected tint pill. Detail = the selected page. Rev 2: the inline Sync toggles and About rows leave the sidebar for their panes per the canon amendment; the sidebar holds playlist rows and nav rows only (a List sidebar with embedded toggles fights the selection model).
- Default selection: the first playlist if any exist, otherwise Appearance, so the detail pane is never empty (matches platform convention). Rev 2: this deliberately DIVERGES from Android tablet's initial Playlists page (B3). The iPad sidebar embeds playlist rows directly (Apple convention), so there is no Playlists list page to land on; forcing one for symmetry would be scope creep. Documented as an accepted divergence in section 5.
- In compact widths (portrait Split View, Slide Over) NavigationSplitView collapses to stacked navigation on its own; rows are `NavigationLink(value:)` so one row definition serves both modes.
- Playlist rows select `SettingsRoute.server(id)`; `ServerDetailView` becomes a detail-pane page on iPad (remains a push on iPhone). `EditServerSheet` stays a sheet on both, presented at form width on iPad.
- Fix the iPad top tab capsule collision: apply the 72pt top inset (the `OnDemandView.swift` pattern, gated on `.pad` and regular width) once at the Settings tab root container, not per column. Extract the constant into shared metrics (A4) so OnDemand and Settings share it. Verify empirically that NavigationSplitView does not already inset under the capsule; remove any double inset. Rev 2: `OnDemandView`'s own comment dates this constant to the "iPadOS 18 floating-TabView top-padding fix", and the app now builds against the iOS 26 SDK. Before extracting it into SettingsMetrics, re-measure the capsule geometry on iOS 26 IN ONDEMAND TOO; treat 72pt as provisional, not a spec.
- Density: Appearance theme swatches and the category color palette become two-column `LazyVGrid`s (reusing the idiom-scaled grid pattern from `MoviesView.swift:119-136`); detail content is capped at about 700pt readable width, centered.

**Theme rekey:** keep the `.id(...)` workaround (`SettingsView.swift:507`) but scope it to the sidebar List only (the stale-cell issue it fixes is List/UITableView specific). Verify each detail pane for stale theme colors after a theme switch and add per-screen `.id` only where actually observed. Selection (`selectedRoute`) is external state and must survive the rekey; verified in testing.

## A3. tvOS rail and detail

New file `Aerio/Features/Settings/TVSettingsSplitView.swift`, replacing `tvOSContent` (`SettingsView.swift:747-1005`) as the tvOS root body:

```
HStack(spacing: 0) {
    TVSettingsRail(selection: $selectedRoute)    // fixed ~430pt, .focusSection()
    TVSettingsDetailHost(route: selectedRoute)   // remaining width, .focusSection()
}
```

- **Rail contents**, frozen order: each playlist, then Appearance, App Behaviors, Multiview, Network, **Sync** (Rev 2: not Sync Categories), DVR, Developer, About. Remote Control keeps its enum case and detail body but its rail row stays hidden, mirroring the commented entry at :880-885, so un-hiding it later is a one-line change. Rail rows reuse the consolidated nav row at rail density (minHeight 80, focus scale 1.02, accent 0.18 fill on focus).
- Rev 2, **Sync pane**: the root-inline iCloud Sync toggles (`SettingsView.swift:299` iOS, the tvOS toggle rows in `tvOSContent`) move into the Sync pane, followed by a nav row that pushes Sync Categories exactly as the root does today. Same copy, same order, new host; covered by canon amendment 2.
- Rev 2, **playlist rows**: focusing a playlist rail row shows its ServerDetailView pane; click/right enters the pane. Activation happens via the new Set Active row at the top of the detail's Actions section (canon amendment 1). The existing root-level activate affordance disappears WITH the root on tvOS; nothing is lost because the pane action replaces it one focus-move away.
- **Focus contract**, adapted from `GroupSidebar.swift` (the proven in-app tvOS rail):
  - Browse-by-focus: focusing a rail row selects it and swaps the detail pane, with roughly a 150ms debounce so fast scrolling does not thrash detail rebuilds.
  - Rev 2, **debounce flush rule**: any movement of focus INTO the detail pane (swipe right, click) synchronously applies a pending debounced selection FIRST, so focus can never land in a pane the debounce is about to replace. The right-move handler flushes, then moves.
  - Swipe right or click moves focus into the detail pane; `defaultFocus` lands on the detail's first interactive row.
  - Swipe left from the detail's leading column returns to the rail. focusSection adjacency provides most of this; add an `onMoveCommand(.left)` fallback on detail leading rows the way `GroupSidebar.swift:246` does.
  - Rev 2, **focus bookkeeping is explicit, not inferred**: a single `@FocusState private var focusedPane: Pane?` (`case rail, detail`) bound with `.focused($focusedPane, equals:)` on the two focusSections is the ONE source of truth for `focusIsInDetail`. It must be re-asserted when a full-screen classic push pops back (set `.rail` in the pop restoration path). This bookkeeping is a Phase 3 entry gate: it gets built and manually verified (print-debug on device) BEFORE the Menu semantics below are wired to it.
- **Menu semantics**: Menu while focus is in the detail pane returns focus to the rail. Menu while focus is in the rail exits to the tab bar. Implementation: keep the existing `isSubviewPushed` binding to `HomeView.swift:3186-3193` but redefine it as `focusIsInDetail || !navPath.isEmpty || dismissStack.depth > 0`, and give `performOnePop()` a first branch that moves focus back to the rail when nothing is pushed. The MainTabView Menu-swallow contract is preserved, not replaced. `SettingsDismissStack` survives unchanged for the classic pushes.
- **Deep flows still push full-screen** over the whole two-pane root via the existing `NavigationStack(path:)`: `EditServerPage`, the category color editors, `MyRecordingsView`. `ServerDetailView` becomes a detail-pane page (rail selection = playlist).
- **Width**: extend the v1.7.5 1200pt reading column to every detail page. Inside a roughly 1330pt pane it effectively becomes fill-with-margins, which is the desired look.

## A3a. Remote Control submenu (Rev 2)

The customizable remote-controls submenu is explicitly covered. Apple's `RemoteControlSettingsView.swift` (424 lines) currently exists ONLY on `wip/fix-pack-2026-07-24`; the redesign branches from post-1.8.4 main so it is present. Structure today: six `tvSection` groups (Play Channels In, Group Selection, While Watching, In the TV Guide, Additional Buttons, Reset) plus a generic `TVSlotChoiceListView` picker pushed via classic NavigationLink (:216, :234).

- Phase 1 deletes its local `tvSection` copy (:268, already counted among the 8) in favor of `SettingsSection`.
- In the rail model its body becomes the (hidden until #195) Remote Control detail pane.
- `TVSlotChoiceListView` joins the classic full-screen push set AND gets the 1200pt reading column (it is currently uncapped, i.e. one of the "stretched" screens).
- Android's `RemoteControlSettingsScreen.kt` (393 lines, on main) already uses the shared `SettingsSection` rows, `adaptiveFormWidth`, and `TvActionMenuDialog` slot pickers: Phase 1 is a near no-op for it, the pane model applies via its existing TV-only `SettingsSection` enum entry, and the slot-picker dialogs float over the pane unchanged.
- The un-hiding of the Remote Control entries still rides the remote-nav overhaul (#195), not this work.

## A4. Component consolidation (god-file peel-off)

New directory `Aerio/Features/Settings/Components/`:

| New file | Source | Notes |
|---|---|---|
| `TVSettingsRows.swift` | `SettingsView.swift:1140-1460` + `TVSettingsTextField` :3428 | Verbatim move first; API unification after |
| `SettingsSection.swift` | new | One `SettingsSection(title:footer:)` container: renders `Section` on iOS, the card VStack on tvOS. Deletes all 8 duplicated `tvSection` helpers |
| `SettingsRow.swift` | :1490 | The shared iOS row primitive, moved as-is (keep its ThemeManager observation comment) |
| `SettingsMetrics.swift` | new | tvOS type ladder (30/26/24/22/20) as named tokens; 1200pt cap; rail width; iPad 72pt inset shared with OnDemandView |
| `SettingsDismissStack.swift` | :4322-4385 | Verbatim move, keep the rationale comment |

Feature extractions from `SettingsView.swift` (mechanical, no behavior change): `ServerDetailView.swift` (:1650-2339), `EditServerSheet.swift` (:2340-2977), `EditServerPage.swift` (:2978-3475), `NetworkSettingsView.swift` (:3476-3838), `CategoryColorEditors.swift` (:3839-4291, iOS-only). SettingsView.swift lands near 600 to 800 lines (root plus routing). This aligns with the standing god-file peel-off watchlist.

Sub-screens keep the `#if os(tvOS)` two-body convention. Each tvOS body: (a) deletes its local `tvSection`, (b) drops its hand-drawn title when hosted in the detail pane (the pane host draws a standard title), (c) removes nav-bar-hidden workarounds tied to the old push model.

## A5. Per-screen treatment

| Screen | tvOS | iPad | iPhone |
|---|---|---|---|
| Root sections | Rail | Sidebar | Unchanged |
| Appearance | Detail pane; swatch grid | Detail; two-column swatch and palette grids; 700pt cap | Unchanged |
| App Behaviors, Multiview, Network, DVR, Developer, Sync Categories | Detail pane, 1200pt cap | Detail, 700pt cap | Unchanged |
| ServerDetailView (playlist detail) | Detail pane (rail selects the playlist) | Detail pane | Unchanged push |
| EditServerPage / EditServerSheet | Full-screen push (unchanged) | Sheet at form width | Unchanged sheet |
| Category color editors | iOS-only today, stays iOS-only | Push within the detail column | Unchanged |
| MyRecordings | Full-screen classic push from DVR (unchanged; still a top-level tab) | Push within the detail column | Unchanged |
| Remote Control | Hidden rail case + detail body, ready for un-hiding; slot pickers = capped classic pushes (A3a) | Same | Same |
| Sync (Rev 2) | Detail pane: root toggles + Sync Categories nav row | Detail pane, same content | Unchanged root-inline |
| About (Rev 2) | Detail pane hosting the About rows + memorial line | Detail pane | Unchanged root-inline |
| Playlist Detail Actions (Rev 2) | Set Active as first Actions row (canon amendment 1) | Same | Same (new row, all platforms) |
| ManageGroupsSheet | Unchanged entry points | Form-width presentation polish | Unchanged |

## A6. Phasing

Each phase is independently shippable.

Rev 2: implementation branches from post-1.8.4 main (so the Remote Control submenu, currently only on `wip/fix-pack-2026-07-24`, is present). The line anchors in this document were verified exact on 2026-07-30 but WILL drift once 1.8.4 merges; re-anchor by symbol name (the extraction table already names every struct), never by line number.

1. **Extraction and shared components** (no visual change). Create `Components/`, extract the five feature files, introduce `SettingsSection`, delete the 8 tvSection duplicates, add `SettingsMetrics`. Effort M (1 to 2 days).
2. **Route enum.** Replace string routes with `SettingsRoute`, remove the serverToEdit hack. Effort S (0.5 day).
3. **tvOS rail and detail.** `TVSettingsSplitView`, rail focus contract, Menu semantics, 1200pt cap everywhere. Effort L (3 to 5 days; focus tuning dominates).
4. **iPad split view.** Idiom fork, sidebar selection styling, 700pt caps, top-inset fix, two-column Appearance grids. Effort M to L (2 to 3 days).
5. **Polish.** Detail-swap crossfade on tvOS, focus ring and typography token sweep, ManageGroups iPad width. Effort S to M (1 to 2 days).

## A7. Risks

- **R1 (tvOS, highest): focus stranding at pane boundaries.** Mitigate with per-page `defaultFocus`, a left-escape `onMoveCommand` on every detail leading column, and the full Menu-path test matrix below.
- **R2 (tvOS): browse-by-focus rebuilding heavy detail views** (Developer, Network) on each rail move. Mitigate with the 150ms debounce and a lazy detail host.
- **R3 (tvOS): the redefined `isSubviewPushed`** could make MainTabView swallow Menu when the user expects app-level back. Test every Menu path, including My Recordings as a top-level tab (it reads separate bindings at `HomeView.swift:5405` and must be unaffected).
- **R4 (iPad): NavigationSplitView inside a TabView tab on iOS 18** has known layout quirks with the top tab capsule. Prototype first in Phase 4; the fallback is a hand-rolled HStack sidebar like the tvOS one.
- **R5 (iPad): the sidebar theme rekey** must not clear `selectedRoute` or column visibility. If it does, snapshot and restore around the rekey.
- **R6 (iPhone): drift.** The idiom fork plus per-phase screenshot diffs keep iPhone pixel-identical.

---

# 4. Plan B: Android (phone / tablet / Android TV)

Gradle requires `JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home`. Paths relative to `app/src/main/java/com/aeriotv/android/`.

## B1. Architecture: keep the enum navigator, hand-roll the two-pane host

Deliberate decision: do NOT adopt Navigation Compose for Settings and do NOT adopt `androidx.compose.material3.adaptive` (`ListDetailPaneScaffold` / `NavigableListDetailPaneScaffold`). Reasons:
- material3-adaptive is not in the dependency catalog today; its D-pad focus behavior on TV is unproven; its navigator/back-stack model conflicts with the load-bearing manual `BackHandler` ordering; and it would still require a separate TV path. Two navigation systems for one screen is worse than one hand-rolled one.
- The repo already contains a proven two-pane pattern with correct D-pad behavior: `GroupSidebarPanel` used as a real leading pane in the player channel-list overlay.
- Similarly, keep `androidx.tv.material` unused. Mixing component trees is a known focus hazard, and the current material3-plus-custom-focus approach works.

**New `feature/settings/SettingsRoute.kt`:**

```kotlin
sealed interface SettingsRoute {
    data object Root : SettingsRoute                        // phone stacked only
    data class Section(val section: SettingsSection) : SettingsRoute
    data object Playlists : SettingsRoute
    data class PlaylistDetail(val playlistId: String) : SettingsRoute   // Rev 2: carries the id
    data object About : SettingsRoute                       // synthetic; NOT a new SettingsSection enum entry
    data class EditPlaylist(val playlistId: String) : SettingsRoute     // Rev 2: carries the id
    data class AddPlaylist(val step: AddPlaylistStep) : SettingsRoute
    data object LogViewer : SettingsRoute
    data object AddMoreCategories : SettingsRoute
}
```

- A `SnapshotStateList<SettingsRoute>` back stack in a `SettingsNavState` remember-holder replaces the six `mutableStateOf` booleans in `SettingsTabContent` (`MainScaffold.kt:1311-1456`). One `BackHandler` pops the stack; today's ordering semantics (LogViewer above Developer, AddPlaylist Configure then ChooseType then None) fall out naturally from stack order instead of `when`-branch order.
- The stack is `rememberSaveable` with a custom Saver (routes are value-like) so rotation, fold posture changes, and process death restore position. Rev 2: `PlaylistDetail` and `EditPlaylist` carry the playlist id IN THE ROUTE (matching Apple's `.server(id)`); restoration must not depend on unsaved view-model selection state, or the fold and process-death tests in section 6 fail by design.
- Rev 2, **selection is not the stack**: in two-pane mode the pane selection lives in a separate `rememberSaveable` `selectedSection` value; the back stack holds ONLY pushes above the pane baseline. Rail or sidebar browsing mutates `selectedSection` and NEVER pushes, so Back cannot replay browse history. Posture mapping (B3) translates between the two: two-pane to stacked synthesizes `[Root, Section(selected)]` plus any existing pushes; stacked to two-pane pops the top `Section(x)` into `selectedSection` and keeps deeper pushes.

**New `feature/settings/SettingsHost.kt`**, called from `SettingsTabContent`. Reads `rememberLiveTvFormFactor()` (`feature/livetv/LiveTVViewMode.kt:63`) once and renders one of three layouts. Two-pane rule: `formFactor == Tv`, OR touch Expanded (width >= 840dp) AND not height-short. Add `Viewport.isTwoPaneEligible` to `ui/adaptive/Adaptive.kt` with a height guard (roughly `heightDp >= 480`) so a landscape phone at about 997x450dp stays stacked. Compact and Medium stay stacked (today's tree).

## B2. Android TV rail and detail

- **Rail**: fixed ~300dp plus 48dp overscan-safe start padding and consistent vertical safe padding. Items: Playlists, then the visible sections in canonical order, then About. Gating reuses a new shared helper `visibleSettingsSections(isTv, isSideload)` extracted verbatim from the root screen's current expressions (Remote Control TV-only, App Updates sideload-flavor-only) so the rail and the phone root list can never diverge.
- **Focus model**: focus-follows-selection. Rev 2: swaps use the SAME roughly 150ms debounce as tvOS (A3) with the same flush-on-enter rule (DPAD_RIGHT applies a pending selection before moving focus), so the two TV apps feel identical and heavy panes get the same insurance. Rows that trigger flows (Add Playlist, About external links) commit on OK only.
- Rev 2, **playlist rows on the rail**: OK enters the detail pane like every other row; activation is the Set Active row at the top of the Playlist Detail Actions section (canon amendment 1). The TV hint copy updates to match; the phone root list keeps tap-to-activate unchanged.
- Rev 2, **focused-pane bookkeeping**: a `focusedPane` state (rail or detail) maintained by `onFocusChanged` on the rail rows and the detail container is the single input for the Back discrimination below, mirroring the Apple `@FocusState` contract.
- **Pane boundary**: DPAD_RIGHT from the rail moves focus to the detail pane's first row. Back while detail-focused returns focus to the same rail row (does not exit Settings). Back while rail-focused bubbles to the tab bar per existing behavior. Implemented with `railFocusRequester` and `detailFocusRequester` plus `focusProperties { right / left }` on the boundary, reusing `GroupSidebarPanel`'s auto-scroll and focus-restore pattern.
- **Preserve the `settingsContentFocus` contract** (`MainScaffold.kt:1359-1391`): rekey it on `backStack.lastOrNull()` and fire it only for full-screen takeovers entering or exiting. Pane swaps do not remove the focused rail row, so the original focus-fallback bug cannot occur for rail navigation. Guard detail top rows with `focusProperties { up }` where they could otherwise escape to the top tab bar.
- **Full-screen takeovers on TV**: EditPlaylist, the AddPlaylist wizard (ChooseType and Configure), LogViewer, AddMoreCategories. These replace the whole two-pane host exactly like today's screens, so `TvKeyboardOnOkHost`, `tvFormFieldInput`, and `TvImeNoJitterBringIntoViewSpec` plumbing is untouched. `TvMenuGuard`, `TvActionMenuDialog`, `TvQrLinkDialog`, and `FormFactorModal` are all unchanged.
- **Detail width**: cap content at about 640dp inside the pane via the pane-aware modifier (B4).
- TV typography is globally scaled 0.9 (`ui/theme/Type.kt:37`); rail text sizes are chosen against the scaled values and verified on the Streamer.

## B3. Tablet list-detail

- Same host with a touch-styled 320dp sidebar: selected-tonal rows with group headers in the frozen order (Playlists, App Settings, Sync, DVR, Developer, About). Selection by tap.
- Initial detail = Playlists (canon says Playlists is first). The root screen's inline playlist summary block moves to the top of the Playlists detail page on expanded widths. Rev 2: this deliberately diverges from iPad's first-playlist default (A2); the two sidebars are structurally different by platform convention (iPad embeds playlist rows, Android has a Playlists item). Accepted divergence, recorded in section 5.
- EditPlaylist, AddPlaylist, and AddMoreCategories render in the detail pane on tablet (the forms fit 600dp). LogViewer remains a full-screen takeover (log lines benefit from width). PlaylistDetail is a pane-local push above Playlists (an extra route on the same stack; the host decides pane vs takeover per route per form factor).
- Resize and fold mapping is a pure re-render of the layout-agnostic stack: stacked to two-pane with stack == [Root] selects Playlists; two-pane to stacked maps a pane selection `Section(x)` to Root plus a push.

## B4. Component consolidation

New package `ui/settings/`, promoting `TvSettingsRows.kt` (the richest set) as the base:

- `SettingsRows.kt`: relocated `SettingsSection`, `SettingsSectionHeader/Footer`, `SettingsRowContainer`, `SettingsSelectionRow`, `SettingsToggleRow`, `SettingsActionRow`, `SettingsInfoRow`, `settingsRowCard`, `dpadFocusWash`, `dpadFocusRing`, `SettingsDialogTextButton`. Fix `SettingsActionRow` disabled semantics: keep it focusable on TV (a truly disabled clickable drops out of D-pad traversal) but render 0.38-alpha content and `semantics { disabled() }` instead of silently swallowing clicks.
- `SettingsNavRow.kt`: the root screen's `SectionNavRow` promoted with the full focus treatment (border plus scale plus wash from `settingsRowCard`), replacing the weak `groupRowFocus`. Adds a `selected` tonal state (`secondaryContainer`) distinct from focus, for rail and sidebar use.
- `SettingsPane.kt`: `SettingsPaneContent(maxWidth)`, a pane-aware replacement for `Modifier.adaptiveFormWidth()`. Uses `BoxWithConstraints` so it caps relative to the pane, not the window, and centers. Retires the hand-rolled centering Boxes and the unused `AdaptiveCenteredContent`.
- `SettingsDetailTopBar.kt`: promoted; static pane header without a back arrow on TV and tablet detail panes, back arrow on phone.
- Migrate all private re-implementations onto this system: `AppearanceSettingsScreen.kt:312 settingsCard`, `DvrSettingsScreen.kt:289`, `DeveloperSettingsScreen.kt:389 DevSectionGroup`, `NetworkSettingsScreen.kt:208`, `PlaylistDetailScreen.kt:409`, `EditPlaylistScreen.kt:605` (keep `SegmentedToggle`, move it to `ui/settings/`), and the root screen's About rows.
- Bug fixes rolled into Phase 1: the Developer screen's missing width cap; the root screen's weak focus treatment.

## B5. Density and polish

- Tablet Appearance: theme swatch grid at doubled density, category palette in two columns, the two display-scale sliders side by side when the pane is at least 560dp.
- Playlists: denser two-line rows on tablet.
- Motion: about 150ms crossfade on pane content swaps; no shared-element transitions.
- ManageGroupsSheet: width-capped (about 640dp) `FormFactorModal` sheet on tablet; the TV centered-dialog path is already correct and stays.

## B6. Phasing

1. **Design-system consolidation** (zero layout change): `ui/settings/`, migrate the private row sets, root focus upgrade, Developer width fix, ActionRow semantics. Effort M (2 to 3 days).
2. **Route model**: `SettingsRoute`, back stack, `SettingsHost` rendering only the stacked layout everywhere. Behavior-identical by design. Effort M (1 to 2 days).
3. **Tablet list-detail**: two-pane touch host, sidebar, pane width modifier, resize mapping, Saver. Effort M to L (about 3 days).
4. **TV rail and detail**: rail, focus-follows-selection, boundary focusProperties, takeover set, overscan. Rev 2, resolved: `baseline-prof.txt`'s app rule is the whole-tree glob `HSPLcom/aeriotv/android/**` (verified 2026-07-30), so the new `ui/settings/` package is covered automatically; no glob work needed. Effort L (4 to 5 days).
5. **Density polish** (B5). Effort S to M (about 2 days).
6. **ManageGroups adaptive pass and cleanup** (retire `AdaptiveCenteredContent`, docs). Effort S (about 1 day).

## B7. Risks

- **TV focus regressions** are the top risk; the concrete checklist is in the testing section below and runs on every Streamer pass.
- **Focus-follows-selection recomposition cost**: each rail focus change recomposes the detail pane. Section pages are cheap state reads; profile on a release build and reach for `movableContentOf` only if jank shows.
- **material3-adaptive avoided**, so no library-maturity risk; the cost is the hand-rolled host. Rev 2: budget several hundred lines once the Saver, posture mapping, and per-route pane-vs-takeover policy are included, not the optimistic 200. The decision stands either way.
- **Phone visual freeze**: Phase 1's row migration is the only phone-visible change; screenshot-diff key screens before and after.
- **Frozen canon**: no string or ordering edits anywhere; the `visibleSettingsSections` helper is extracted verbatim.

---

# 5. Cross-platform alignment

- TV on both stacks: rail plus detail, browse-by-focus, right enters the detail, Back returns focus to the rail before exiting Settings.
- Tablet and iPad: sidebar plus detail, collapsing to stacked when narrow; initial selection never leaves an empty pane.
- Phones: unchanged push navigation on both.
- Same takeover set on TV on both stacks: edit playlist, the add-playlist flow, the log viewer, and the extra category editors.
- Content canon identical everywhere; per-platform feature gates stay exactly as they are (Glass and User-Agent Apple-only, Casting phone-only, refresh-rate Display TV-only, App Updates sideload-only, Remote Control TV-only and hidden).
- Rev 2, **uniform activation model**: on every rail and sidebar form factor, selecting a playlist shows its detail; Set Active lives in the detail's Actions section on all six form factors. Phone roots keep their existing per-platform tap semantics.
- Rev 2, **accepted divergences** (deliberate, per platform convention): iPad sidebar embeds playlist rows and defaults to the first playlist's detail; Android tablet sidebar has a Playlists item and defaults to the Playlists page. Everything else in the sidebar structure matches.
- Deferred, unchanged by this work: un-hiding the Remote Control screens (rides the remote-nav overhaul), My Recordings dual entry, Manage Groups entry points.

---

# 6. In-depth testing instructions

General rules that apply to every pass:
- Apple builds always use Xcode 27 (`DEVELOPER_DIR=/Applications/Xcode-beta.app`). iOS device installs go to Logan's iPhone only.
- Android device passes on the Google TV Streamer use a RELEASE build (`./gradlew :app:assembleGithubRelease` with the Android Studio JBR as JAVA_HOME, then `adb install -r`), taps only, and a screenshot verification after every step (no blind D-pad sequences). Check the install output for "Success". Run `adb devices -l` first; the Streamer is often on USB.
- Android emulator work follows the standing auto rebuild, reinstall, relaunch practice after every change.
- Any release cut gates on Logan's device confirmation, never on machine checks alone.

## 6.1 Phase-by-phase verification

### Apple Phase 1 (extraction, no visual change)
1. Build the iOS scheme and the tvOS scheme; both must compile clean.
2. Screenshot-diff before/after on: Settings root, Appearance, App Behaviors, Network, DVR, Developer, Multiview, Sync Categories, playlist detail, edit playlist. iPhone simulator and tvOS simulator. Expect zero pixel drift.
3. tvOS simulator: walk into each sub-screen and back with Menu; confirm the dismiss order is unchanged (especially My Recordings pushed from DVR, then Menu pops it, then Menu pops DVR).
4. Theme switch on each platform: confirm accent recolors settings rows (the SettingsRow ThemeManager observation must survive the move).

### Apple Phase 2 (route enum)
1. tvOS: push every route from the root ("appearance" through "developer"), Menu-pop each.
2. Regression case from the removed hack: open Edit Playlist for server A, save, immediately open Edit Playlist for server B, then for server A again. The editor must show the correct server every time.
3. iOS: confirm every NavigationLink still lands on the right screen and back works.

### Apple Phase 3 (tvOS rail and detail), on the physical Apple TV
1. Open Settings from the tab bar; focus lands in the rail on the first item; the detail pane shows the default selection.
2. Scroll the rail slowly end to end: every focus change swaps the detail pane; the highlight never skips or strands; the debounce means no visible lag or flicker at normal speed.
3. Scroll the rail as fast as the remote allows: no dropped frames, no detail pane showing a stale category.
4. Swipe right from each rail row: focus enters the detail's first interactive row. Swipe left from that row: focus returns to the SAME rail row.
5. Menu with focus in a detail pane: focus returns to the rail, Settings stays open. Menu again: exits to the tab bar.
6. Deep pushes: from the playlist detail pane open Edit Playlist (full-screen). Menu pops back to the two-pane view with focus restored. Same for My Recordings from DVR and, on iOS-only editors, confirm they simply do not appear on tvOS.
7. Toggles and pickers in every detail pane: changing a value must not reset the pane or move focus unexpectedly.
8. The My Recordings top-level tab must be completely unaffected by the Settings Menu changes: enter it, play with filters, Menu back to the tab bar.
9. Empty state: remove all playlists ON THE TVOS SIMULATOR (Rev 2: never on the physical Apple TV, which carries the real config), confirm the rail shows the empty affordance plus Add Playlist, and Add still presents its sheet and returns focus sanely on dismiss.
12. Rev 2: Set Active row in each playlist's detail pane Actions: activates, shows the checked/disabled state on the active playlist, and the rail reflects the active marker immediately.
13. Rev 2 (dev-only until #195): temporarily un-hide the Remote Control rail row on a local build; its pane renders inside the reading column, slot pickers push full-screen WITH the 1200pt cap, Menu pops back to the pane with focus restored. Re-hide before merging.
10. Theme switch from Appearance in the pane: rail, detail, and focus chrome all recolor; selection is retained.
11. Every detail pane renders inside the reading column: nothing spans the full 1920pt.

### Apple Phase 4 (iPad split view), iPad simulator plus a device pass if convenient
1. Landscape full screen: sidebar plus detail, both visible; selecting each sidebar row swaps the detail; the selected row shows the tint pill.
2. Portrait: verify the chosen collapse behavior; navigation must remain coherent (no dead ends, back always available).
3. Split View at 1/3 and 1/2, and Slide Over: the layout collapses to stacked; rows push; nothing overlaps the top tab capsule (the 72pt inset fix); return to full screen restores the split with the selection intact. Rev 2: repeat at two or three Stage Manager window sizes across the compact/regular boundary.
4. Theme switch while a detail page is open: sidebar rekeys, selection and detail survive, no blank pane.
5. Playlist reorder via EditButton works in the sidebar in both split and collapsed modes.
6. Edit Playlist presents as a form-width sheet; category color editors push inside the detail column and back-chevron correctly.
7. Appearance: theme swatches and palette render two-column; tapping swatches updates the preview live.
8. iPhone regression: full screenshot-diff of every settings screen against Phase 2. Must be identical.
9. Rotation mid-navigation: rotate while deep in a pushed editor; state must survive.

### Apple Phase 5 (polish)
1. tvOS: detail swap crossfade present, no flash of empty pane.
2. Type token sweep: compare the tvOS ladder before/after; sizes unchanged (tokens are a refactor, not a redesign).
3. ManageGroups on iPad: form width, dismisses correctly from all three entry points (Live TV, Movies, Series).

### Android Phase 1 (design-system consolidation)
1. Phone emulator: screenshot-diff Settings root plus all sub-screens before/after. The ONLY intended diffs: the root rows' focus treatment (visible only under D-pad), the Developer screen now width-capped on wide windows, and disabled action rows now dimmed.
2. Streamer: D-pad over every sub-screen; every row shows the full focus treatment (border, scale, wash); the root screen rows now match sub-screen rows under focus.
3. Streamer: a running/disabled action row (e.g. a refresh in flight) is still reachable by D-pad, renders dimmed, and does nothing on OK.
4. Theme switch: all migrated rows recolor.

### Android Phase 2 (route model)
1. Phone: every navigation path in and out of Settings; system Back at every depth. Specifically: open Developer, open Log Viewer, Back returns to Developer (the old ordering-sensitive case); AddPlaylist Configure, Back returns to ChooseType, Back returns to Settings.
2. Streamer: enter Settings from the top tab bar; focus lands in content, never on the Live TV pill (the `settingsContentFocus` contract); enter and exit every sub-screen and confirm focus restoration.
3. Rotate the phone at every depth; position restores (the Saver).
4. Process death test: enable "Don't keep activities", navigate deep, background and return; the stack restores.

### Android Phase 3 (tablet list-detail)
1. Pixel Tablet emulator, landscape: sidebar plus detail; initial detail is Playlists with the summary block at top; each sidebar row swaps the detail with the selected tonal state.
2. Tablet portrait (Medium band): stacked layout, unchanged from phone behavior with width caps.
3. Z Fold 5 (physical): cover screen = stacked; unfold mid-navigation with a section open = the same section appears as the pane selection; fold back = maps to Root plus push with Back working; repeat while inside EditPlaylist (pane on tablet-width) and confirm no state loss.
4. Landscape phone (about 997dp wide): must stay STACKED (the height guard). Verify on a regular phone emulator in landscape.
5. Resize a freeform/desktop window across the 840dp boundary if available: layout swaps without losing position.
6. Pane-local push: Playlists then a playlist's detail then Back returns to Playlists inside the pane, not out of Settings.

### Android Phase 4 (TV rail and detail), on the Streamer, release build, tap-and-screenshot protocol
Run the full TV focus checklist:
1. From the top tab pill, DPAD_DOWN lands in the rail.
2. Focusing each rail row swaps the detail pane; screenshot each swap; no focus loss, no stale pane.
3. DPAD_RIGHT enters the detail's first row; DPAD_LEFT and Back both return to the SAME rail row.
4. No bounce to the Live TV pill on any pane swap (the original selection-follows-focus bug).
5. Toggles and selection rows commit without a pane reset or focus jump.
6. Takeovers (EditPlaylist, AddPlaylist, LogViewer, AddMoreCategories): enter, exit, focus restores to the rail row that launched them.
7. EditPlaylist TV keyboard flows unchanged: OK opens the keyboard, no IME jitter, field-to-field navigation works.
8. `FormFactorModal` dialogs and `TvActionMenuDialog` long-press menus still trap focus and dismiss correctly (playlist long-press menu in the Playlists pane).
9. Overscan: nothing clipped at any screen edge on the Streamer's output; rail start padding respected.
10. About links open the QR dialog, not a browser intent.
11. Remote Control appears in the rail on TV only; App Updates appears only on the sideload flavor (check both flavors).
11a. Rev 2: playlist activation on the rail: OK on a playlist row enters its detail pane; Set Active (first Actions row) activates it, the row shows the checked state, the rail marks the active playlist, and the updated TV hint copy renders. Switch back the same way.
11b. Rev 2: Remote Control pane on TV: sections render inside the pane cap, slot-choice `TvActionMenuDialog`s trap focus and dismiss correctly (same protocol as the FormFactorModal checks).
12. Perf: with the release build, hold DPAD_DOWN through the rail; no visible jank. If the baseline profile is path-scoped, confirm the new package is covered (INSTALL_PROFILE validation per the standing perf practice). Remember adb-injected input inflates jank readings; judge with the remote, not just adb.

### Android Phase 5 and 6 (density polish, ManageGroups)
1. Tablet Appearance: swatch grid and two-column palette render and wrap correctly at 840dp exactly, at 1000dp, and at the Fold's inner width; sliders sit side by side only when the pane is at least 560dp.
2. Pane crossfade present, about 150ms, no double-flash.
3. ManageGroups on tablet: sheet capped near 640dp, drag to dismiss works, contents unchanged; on the Streamer the centered dialog is unchanged and still traps focus.

## 6.2 Cross-platform consistency pass (final, both stacks together)

Sit the devices side by side (Apple TV plus Streamer; iPad plus a tablet or the Fold unfolded; iPhone plus a phone):
1. Walk the rail/sidebar top to bottom on each pair: identical order, identical titles and subtitles, identical section contents (allowing the documented per-platform gates).
2. Playlist journey on each pair: root to playlist to detail to edit to save to back. The same number of steps and the same structure everywhere. Rev 2: include activation in the journey (Set Active from the detail Actions section on rail and sidebar form factors; existing root semantics on phones), and verify the updated Android TV hint copy appears on TV only while phone copy is byte-identical to today.
3. Verify no copy drifted: spot-check the footers that were unified in July (LAN/WAN auto-switch, Guide History, EPG Window) on all six form factors.
4. Confirm no em dashes and no third-party app names slipped into any new or moved copy.

## 6.3 Regression watchlist (things this work must not break)

- Apple: the Menu-press swallow contract in MainTabView; My Recordings as a top-level tab; iCloud sync toggles and the Clear iCloud flow (alerts present over the split view correctly); the theme rekey behavior; Add Playlist onboarding sheet.
- Android: the `settingsContentFocus` guarantee; `TvMenuGuard` latched OK handling (no spurious activations when opening menus); Drive sync sign-in flows and their four confirm dialogs; the sideload updater flow; playlist activate-vs-detail tap semantics on the root screen (unchanged canon).
- Both: playlist cascade delete from both the list and the detail; EPG cache and full refresh actions from the playlist detail; Developer log share (QR/LAN server on TV).

---

# 7. Effort summary

| Phase | Apple | Android |
|---|---|---|
| 1. Consolidation (no visual change) | 1-2 days | 2-3 days |
| 2. Route model | 0.5 day | 1-2 days |
| 3. First split layout | tvOS rail: 3-5 days | Tablet: ~3 days |
| 4. Second split layout | iPad: 2-3 days | TV rail: 4-5 days |
| 5. Polish | 1-2 days | ~2 days |
| 6. Cleanup | (in 5) | ~1 day |

Roughly two working weeks per platform, each phase shippable on its own so the work can ride normal release trains.
