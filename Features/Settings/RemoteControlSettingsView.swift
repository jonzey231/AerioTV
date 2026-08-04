import SwiftUI

#if os(tvOS)

/// Settings > App Settings > Remote Control (Apple TV only).
///
/// tvOS port of the Android `RemoteControlSettingsScreen.kt`. Lets the
/// user retarget each Siri Remote button per context (fullscreen player
/// vs. TV guide) and pick the two companion guide behaviours: where a
/// channel starts playing, and how channel groups are chosen. Every
/// control writes straight through `RemoteControlStore.shared`, which
/// persists the map and syncs it across the user's Apple TVs.
///
/// Design invariants inherited from the shared model (do not relax):
/// - Back / Menu is never a slot; Back semantics stay hardcoded and are
///   deliberately absent from every choice list.
/// - Guide SHORT arrows are focus navigation, never mappable, so the
///   guide section only offers hold-Select / hold-Left / hold-Right.
/// - Choice lists are CURATED to actions the tvOS executor can actually
///   run today (omit rather than advertise a dead button); these mirror
///   the Android curation exactly.
///
/// The section scaffold (`SettingsSection`, the `TVSettings*Row`
/// components) is copied from `AppBehaviorsSettingsView` so this page
/// matches the rest of tvOS Settings. Picking an action pushes a plain
/// `List` of selection rows rather than a native `Picker` wheel, which
/// focus-traps on tvOS.
struct RemoteControlSettingsView: View {
    @ObservedObject private var store = RemoteControlStore.shared
    @ObservedObject private var theme = ThemeManager.shared

    /// Drives the guarded Reset-to-Defaults confirmation alert.
    @State private var showResetConfirm = false

    // MARK: - Curated slot layouts

    /// Player slots offered while watching, in display order: Select and
    /// the four arrows, short + hold. Dedicated media / channel buttons
    /// live in their own "Additional Buttons" section below.
    private static let playerSlots: [RemoteSlot] = [
        .okShort, .okLong,
        .upShort, .upLong,
        .downShort, .downLong,
        .leftShort, .leftLong,
        .rightShort, .rightLong,
    ]

    /// Guide slots offered: hold-Select / hold-Left / hold-Right only.
    /// Short arrows always navigate; up/down hold are omitted until a
    /// guide long-press detector exists (omit rather than fake).
    private static let guideSlots: [RemoteSlot] = [
        .okLong, .leftLong, .rightLong,
    ]

    /// Dedicated playback / channel buttons some remotes expose. Task
    /// scope is the player context: these retarget what the button does
    /// while a channel is playing.
    private static let additionalPlayerSlots: [RemoteSlot] = [
        .playPause, .ffwd, .rewind, .channelUp, .channelDown,
    ]

    // MARK: - Curated action choices

    /// Player actions offered in every player-slot picker: only actions
    /// the tvOS executor can run today. Mirrors Android
    /// `PLAYER_ACTION_CHOICES` (`Back` and its fixed `stopPlayback`
    /// semantics are intentionally excluded).
    private static let playerActionChoices: [PlayerRemoteAction] = [
        .channelUp, .channelDown,
        .lastChannel, .recentChannels,
        .openSearch,
        .toggleControls, .showProgramInfo, .optionsMenu,
        .seekForward, .seekBackward,
        .minimizeToGuide, .channelList,
        .none,
    ]

    /// Guide actions offered for a given slot. `closeMiniPlayer` and
    /// `programInfo` are only meaningful on their canonical slots (their
    /// teardown / program-menu paths are dispatched from there), matching
    /// the Android per-slot curation exactly.
    private static func guideActionChoices(for slot: RemoteSlot) -> [GuideRemoteAction] {
        var out: [GuideRemoteAction] = [
            .timelineBack, .timelineForward,
            .pageUp, .pageDown,
            .jumpToNow, .jumpToTop,
            .focusGroupPills, .resumePlayer,
        ]
        if slot == .rightLong { out.append(.closeMiniPlayer) }
        if slot == .okLong { out.append(.programInfo) }
        out.append(.none)
        return out
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Remote Control")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.textPrimary)

                playChannelsInSection
                groupSelectionSection
                whileWatchingSection
                inTheGuideSection
                additionalButtonsSection
                resetSection
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Remote Control")
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .alert("Reset Remote Controls?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { store.resetToDefault() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restore every button to the standard AerioTV scheme. Your customizations will be lost.")
        }
    }

    // MARK: - Sections

    /// 1. Where a channel starts playing (bound to `tuneInMini`).
    private var playChannelsInSection: some View {
        SettingsSection("Play Channels In", style: .card) {
            TVSettingsSelectionRow(
                label: "Full Screen",
                isSelected: !store.tuneInMini,
                action: { store.tuneInMini = false }
            )
            TVSettingsSelectionRow(
                label: "Mini Player",
                isSelected: store.tuneInMini,
                action: { store.tuneInMini = true }
            )
            sectionFooter("Where a channel starts playing when you press Select on it in Live TV. Mini Player keeps you browsing with the channel in the corner; press Select on it again to go full screen.")
        }
    }

    /// 2. How groups are picked in the guide (bound to `useGroupSidebar`).
    private var groupSelectionSection: some View {
        SettingsSection("Group Selection", style: .card) {
            TVSettingsSelectionRow(
                label: "Top Group Pills",
                isSelected: !store.useGroupSidebar,
                action: { store.useGroupSidebar = false }
            )
            TVSettingsSelectionRow(
                label: "Sidebar Menu",
                isSelected: store.useGroupSidebar,
                action: { store.useGroupSidebar = true }
            )
            sectionFooter("How channel groups are picked in the guide. Top Group Pills keep the group row above the grid; Sidebar Menu hides that row and opens with a Left press from the currently airing column. Only one is active at a time.")
        }
    }

    /// 3. One row per user-facing player slot.
    private var whileWatchingSection: some View {
        SettingsSection("While Watching", style: .card) {
            ForEach(Self.playerSlots, id: \.self) { slot in
                playerSlotRow(slot)
            }
            sectionFooter("What each button does while a channel is playing full screen. Changes apply immediately. Back always navigates and cannot be reassigned.")
        }
    }

    /// 4. Guide-context holds (short arrows are navigation, not shown).
    private var inTheGuideSection: some View {
        SettingsSection("In the TV Guide", style: .card) {
            ForEach(Self.guideSlots, id: \.self) { slot in
                guideSlotRow(slot)
            }
            sectionFooter("What each button does while browsing the guide. Short arrow presses always navigate.")
        }
    }

    /// 5. Dedicated remote buttons, player context.
    private var additionalButtonsSection: some View {
        SettingsSection("Additional Buttons", style: .card) {
            ForEach(Self.additionalPlayerSlots, id: \.self) { slot in
                playerSlotRow(slot)
            }
            sectionFooter("For remotes with dedicated playback and channel buttons. These retarget what the button does while a channel is playing.")
        }
    }

    /// 6. Guarded reset.
    private var resetSection: some View {
        SettingsSection("Reset", style: .card) {
            TVSettingsActionRow(
                icon: "arrow.counterclockwise",
                label: "Reset to Defaults",
                isDestructive: true
            ) {
                showResetConfirm = true
            }
            sectionFooter("Restore every button to the standard AerioTV scheme.")
        }
    }

    // MARK: - Slot rows

    /// A player-context slot row: friendly slot name on the left, its
    /// current action on the right, pushing the curated player choice
    /// list. Reads the live action through the observed store so the
    /// value label and pushed highlight both update after an edit.
    private func playerSlotRow(_ slot: RemoteSlot) -> some View {
        let current = store.playerAction(slot)
        return TVSettingsNavRow(
            destination: TVSlotChoiceListView(
                title: displayName(slot),
                choices: Self.playerActionChoices,
                current: current,
                displayName: { displayName($0) },
                onSelect: { store.setPlayerAction(slot, $0) }
            )
            .trackedAsClassicSettingsChild()
        ) {
            slotRowLabel(name: displayName(slot), value: displayName(current))
        }
    }

    /// A guide-context slot row: pushes the curated guide choice list for
    /// that specific slot.
    private func guideSlotRow(_ slot: RemoteSlot) -> some View {
        let current = store.guideAction(slot)
        return TVSettingsNavRow(
            destination: TVSlotChoiceListView(
                title: displayName(slot),
                choices: Self.guideActionChoices(for: slot),
                current: current,
                displayName: { displayName($0) },
                onSelect: { store.setGuideAction(slot, $0) }
            )
            .trackedAsClassicSettingsChild()
        ) {
            slotRowLabel(name: displayName(slot), value: displayName(current))
        }
    }

    private func slotRowLabel(name: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(name)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 24))
                .foregroundColor(.accentPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.textTertiary)
        }
    }

    // MARK: - Section scaffold (copied from AppBehaviorsSettingsView)

    /// Sections use the shared `SettingsSection(style: .card)` so
    /// this submenu visually matches the rest of tvOS Settings.

    /// Grey explanatory footer, styled like the description text in
    /// `AppBehaviorsSettingsView`'s tvOS sections.
    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22))
            .foregroundColor(.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }
}

// MARK: - Friendly display names

/// tvOS friendly label for a remote slot (Siri Remote terminology:
/// the click pad is "Select", holds read "X (hold)").
private func displayName(_ slot: RemoteSlot) -> String {
    switch slot {
    case .okShort:     return "Select"
    case .okLong:      return "Select (hold)"
    case .upShort:     return "Up"
    case .upLong:      return "Up (hold)"
    case .downShort:   return "Down"
    case .downLong:    return "Down (hold)"
    case .leftShort:   return "Left"
    case .leftLong:    return "Left (hold)"
    case .rightShort:  return "Right"
    case .rightLong:   return "Right (hold)"
    case .playPause:   return "Play/Pause"
    case .ffwd:        return "Fast Forward"
    case .rewind:      return "Rewind"
    case .channelUp:   return "Channel Up"
    case .channelDown: return "Channel Down"
    }
}

/// Friendly label for a player action. Exhaustive over the shared enum
/// so a future action is a compile error here rather than a blank row.
private func displayName(_ action: PlayerRemoteAction) -> String {
    switch action {
    case .channelUp:       return "Channel up"
    case .channelDown:     return "Channel down"
    case .lastChannel:     return "Previous channel"
    case .recentChannels:  return "Recently watched"
    case .toggleControls:  return "Show/hide controls"
    case .showProgramInfo: return "Show program info"
    case .optionsMenu:     return "Options menu"
    case .playPause:       return "Play/Pause"
    case .seekForward:     return "Seek forward"
    case .seekBackward:    return "Seek back"
    case .restartProgram:  return "Restart program"
    case .jumpToLive:      return "Jump to live"
    case .minimizeToGuide: return "Return to TV Guide"
    case .channelList:     return "Channel list"
    case .subtitles:       return "Subtitles"
    case .audioTracks:     return "Audio tracks"
    case .aspectRatio:     return "Aspect ratio"
    case .record:          return "Record"
    case .sleepTimer:      return "Sleep timer"
    case .openSearch:      return "Search"
    // Fixed hold-Back behavior; labeled for completeness but never
    // offered in the curated choice lists (Back semantics stay hardcoded).
    case .stopPlayback:    return "Stop playback"
    case .none:            return "Do nothing"
    }
}

/// Friendly label for a guide action. Exhaustive over the shared enum.
private func displayName(_ action: GuideRemoteAction) -> String {
    switch action {
    case .pageUp:          return "Page channels up"
    case .pageDown:        return "Page channels down"
    case .timelineBack:    return "Browse earlier programs"
    case .timelineForward: return "Browse later programs"
    case .jumpToNow:       return "Jump to now"
    case .jumpToTop:       return "Jump to top channel"
    case .focusGroupPills: return "Go to group pills"
    case .resumePlayer:    return "Return to player"
    case .closeMiniPlayer: return "Close mini player"
    case .programInfo:     return "Program menu"
    case .openSearch:      return "Search"
    case .none:            return "Do nothing"
    }
}

// MARK: - Pushed choice list

/// Pushed list of curated action choices for one remote slot. A plain
/// `List` of `TVSettingsSelectionRow`s (deliberately NOT a native
/// `Picker` wheel, which focus-traps on tvOS). Selecting an option
/// commits it through `onSelect` and pops back to the map.
///
/// Generic over the action enum so the same view backs both the player
/// and guide pickers; `Hashable` gives us `ForEach` identity plus the
/// `==` used to highlight the current choice.
private struct TVSlotChoiceListView<Action: Hashable>: View {
    let title: String
    let choices: [Action]
    let current: Action
    let displayName: (Action) -> String
    let onSelect: (Action) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 80)
                .padding(.top, 60)
                .padding(.bottom, 24)

            List {
                ForEach(choices, id: \.self) { action in
                    TVSettingsSelectionRow(
                        label: displayName(action),
                        isSelected: action == current,
                        action: {
                            onSelect(action)
                            dismiss()
                        }
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 80, bottom: 6, trailing: 80))
                }
            }
            .listStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }
}

#endif
