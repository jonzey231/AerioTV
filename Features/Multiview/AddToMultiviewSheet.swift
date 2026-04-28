import SwiftUI

/// Channel picker presented from `MultiviewTransportBar`'s "Add Tile"
/// button. Three stacked sections:
/// - Favorites (from `FavoritesStore`)
/// - Recent (from `RecentChannelsStore`, most-recent first)
/// - All Channels (from `ChannelStore.channels`, grouped by category
///   / searchable on iPad)
///
/// Adds are routed through `MultiviewStore.add(_:server:bypassWarning:)`.
/// When the store returns `.needsWarning` the sheet shows a
/// confirmation alert; on Continue, it calls `add(...)` again with
/// `bypassWarning: true` and bumps `warningLastShownAt`.
///
/// On iPad: presented as a `.sheet` with two detents — fraction 0.45
/// for a peek (can still see the grid) and `.large` for full-screen
/// search. tvOS uses a full-screen cover via the parent (sheets on
/// tvOS are platform-styled differently and cover the whole screen
/// anyway).
///
/// The sheet stays open across multiple adds. Cancel / swipe-down
/// dismisses.
struct AddToMultiviewSheet: View {
    @Binding var isPresented: Bool

    @ObservedObject private var channelStore = ChannelStore.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @ObservedObject private var recentsStore = RecentChannelsStore.shared
    @ObservedObject private var multiviewStore = MultiviewStore.shared

    /// Search query on iPad. tvOS skips the search field — typing via
    /// Siri Remote is painful and the category grouping below is
    /// usually enough.
    @State private var searchText: String = ""

    /// Holds the `ChannelDisplayItem` that triggered a `.needsWarning`
    /// response. Non-nil while the performance-warning alert is
    /// showing; nil otherwise.
    @State private var pendingWarningItem: ChannelDisplayItem? = nil

    /// Non-nil when an add attempt produced a user-facing error
    /// (`.rejectedMax`, `.unresolvable`). Short inline toast.
    @State private var toastMessage: String? = nil

    /// v1.6.12: currently-selected group filter. `"All"` is the
    /// sentinel meaning "no filter". Mirrors the Live TV channel-list
    /// pattern (see `ChannelListView.selectedGroup`) so users get the
    /// same single-keystroke "narrow to Sports / News / Movies" flow
    /// they're used to from the main channel list, without having to
    /// type into the search field.
    @State private var selectedGroup: String = "All"

    /// User-hidden groups loaded from the same `UserDefaults` key
    /// `ChannelListView` uses (`hiddenChannelGroups`). The picker
    /// honours this list so a user who hid a group in the main
    /// channel list doesn't see it resurface in the add-tile picker.
    /// Loaded on appear; not observed for live updates because
    /// hidden-groups edits happen in a separate sheet that's never
    /// presented over this one.
    @State private var hiddenGroups: Set<String> = []

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iPadOSBody
        #endif
    }

    // MARK: - iPadOS body (NavigationStack + List + detents)

    #if !os(tvOS)
    @ViewBuilder
    private var iPadOSBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // v1.6.12: group filter pill bar — same vocabulary as
                // Live TV's filter row. Placed above the List (not in
                // the toolbar) so the chips stay visible while the
                // search bar is focused; collapsed entirely when there
                // are 0–1 visible groups so a single-group provider
                // doesn't get a lonely "All" chip eating vertical room.
                if groupChips.count > 1 {
                    iPadGroupFilterBar
                }

                List {
                    if !favoriteChannels.isEmpty {
                        section(title: "Favorites", items: favoriteChannels)
                    }
                    if !recentChannels.isEmpty {
                        section(title: "Recent", items: recentChannels)
                    }
                    section(title: "All Channels", items: allChannelsFiltered)
                }
                .listStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search channels")
            .navigationTitle("Add to Multiview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .onAppear { loadHiddenGroups() }
            .modifier(SharedSheetModifiers(
                pendingWarningItem: $pendingWarningItem,
                toastMessage: $toastMessage,
                softLimit: multiviewStore.softLimit,
                onContinueWarning: { item in
                    pendingWarningItem = nil
                    commitAdd(item, bypassWarning: true)
                },
                onCancelWarning: { pendingWarningItem = nil }
            ))
        }
    }

    /// Horizontal scrolling row of group-filter chips for iPad.
    /// Visual lifted from `ChannelListView`'s inline filter row so
    /// the picker matches the channel list at a glance: accent fill
    /// for selected, elevated background for unselected, capsule
    /// shape, single-tap select. Spring animation softens the
    /// selection swap.
    @ViewBuilder
    private var iPadGroupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groupChips, id: \.self) { group in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedGroup = group
                        }
                    } label: {
                        Text(group)
                            .font(.labelMedium)
                            .foregroundColor(selectedGroup == group
                                             ? .appBackground
                                             : .textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedGroup == group
                                    ? AnyView(Capsule().fill(Color.accentPrimary))
                                    : AnyView(Capsule().fill(Color.elevatedBackground))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter: \(group)")
                    .accessibilityAddTraits(selectedGroup == group ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    #endif

    // MARK: - tvOS body (full-screen, couch-readable)

    #if os(tvOS)
    /// Full-screen tvOS picker. Built from scratch (no
    /// `NavigationStack`, no `List`) because SwiftUI's default sheet
    /// on tvOS renders small + centred — titles truncate, rows
    /// cram, and the whole thing looks like an iPad form sheet
    /// stranded on a 4K TV. This layout uses the entire screen:
    /// big title, a prominent Close button top-right, a
    /// `ScrollView` + `LazyVStack` for the sections so the content
    /// can be as wide and spacious as we want.
    ///
    /// Dismissal paths:
    /// - Focus → Close button → Select
    /// - Menu (Siri Remote Back) → `.onExitCommand`
    @ViewBuilder
    private var tvOSBody: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 80)
                    .padding(.top, 40)
                    .padding(.bottom, 20)

                // v1.6.12: group filter pill bar. Sits between the
                // header and the channel scroll so the focus engine's
                // natural top-to-bottom traversal lands on filter
                // chips before the (much longer) channel list, mirroring
                // Live TV's tvOS layout. `.focusSection()` keeps focus
                // grouped here when the user moves up from the channels
                // — without it, swiping up jumps straight to the Close
                // button instead of the chips.
                if groupChips.count > 1 {
                    tvGroupFilterBar
                        .padding(.horizontal, 80)
                        .padding(.bottom, 12)
                        .focusSection()
                }

                ScrollView {
                    // Rows are direct children of `LazyVStack` so
                    // SwiftUI can lazily materialise them as the
                    // user scrolls. A previous revision grouped
                    // each section into a `VStack` child, which
                    // defeated lazy-loading entirely — the parent
                    // `LazyVStack` saw each section as a single
                    // opaque child and instantiated all 700+
                    // `CompactChannelRow`s up-front, each with its
                    // own eager `AsyncImage` decode. That's what
                    // caused the "scroll 4-5 channels → crash"
                    // behaviour: RSS blew past the tvOS foreground
                    // process cap before the system could reap
                    // off-screen rows.
                    //
                    // Now section headers + rows are flat siblings
                    // in a single `LazyVStack`. `spacing: 12` keeps
                    // the row rhythm; the header `.padding(.top, 20)`
                    // reinstates the visual gap between sections
                    // without costing lazy-load.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // Each `ForEach` id is namespaced by section name
                        // ("fav:<id>", "recent:<id>", "all:<id>") because
                        // the same channel can appear in multiple sections
                        // (a favorited channel is also in All Channels),
                        // and SwiftUI's `LazyVStack` emits
                        // "ID used by multiple child views" warnings + real
                        // rendering glitches when two siblings share an
                        // `explicitID`. Composite keys keep each row's
                        // identity unique within the flat list.
                        if !favoriteChannels.isEmpty {
                            tvSectionHeader("Favorites")
                            ForEach(favoriteChannels, id: \.favSectionID) { item in
                                tvChannelRow(item)
                            }
                        }
                        if !recentChannels.isEmpty {
                            tvSectionHeader("Recent")
                            ForEach(recentChannels, id: \.recentSectionID) { item in
                                tvChannelRow(item)
                            }
                        }
                        tvSectionHeader("All Channels")
                        ForEach(allChannelsFiltered, id: \.allSectionID) { item in
                            tvChannelRow(item)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 60)
                }
            }
        }
        .onExitCommand { isPresented = false }
        .onAppear { loadHiddenGroups() }
        .modifier(SharedSheetModifiers(
            pendingWarningItem: $pendingWarningItem,
            toastMessage: $toastMessage,
            softLimit: multiviewStore.softLimit,
            onContinueWarning: { item in
                pendingWarningItem = nil
                commitAdd(item, bypassWarning: true)
            },
            onCancelWarning: { pendingWarningItem = nil }
        ))
    }

    /// Horizontal scrolling row of group-filter chips for tvOS.
    /// Larger type and padding than the iPad bar (couch-readable),
    /// and uses `PickerGroupPillButtonStyle` (defined at the bottom
    /// of this file) so focus halo + scale match the rest of the
    /// tvOS multiview vocabulary.
    @ViewBuilder
    private var tvGroupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(groupChips, id: \.self) { group in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedGroup = group
                        }
                    } label: {
                        Text(group)
                            .font(.system(size: 22, weight: .medium))
                    }
                    .buttonStyle(PickerGroupPillButtonStyle(
                        isSelected: selectedGroup == group
                    ))
                    .accessibilityLabel("Filter: \(group)")
                    .accessibilityAddTraits(selectedGroup == group ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Header: title on the left, big Close button on the right.
    /// Close uses `TransportButtonStyle`-style focus chrome
    /// (defined locally below) so its focus state matches the rest
    /// of the multiview UI vocabulary.
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to Multiview")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(multiviewStore.count) of \(multiviewStore.maxTiles) tiles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Text("Close")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 160, minHeight: 60)
                    .padding(.horizontal, 24)
            }
            .buttonStyle(AddSheetCloseButtonStyle())
            .accessibilityLabel("Close picker")
        }
    }
    #endif

    // MARK: - Sections

    #if os(tvOS)
    /// Section header used inside the flat `LazyVStack` — rendered
    /// as a single `Text` so lazy loading isn't defeated by wrapping
    /// it in a container. The `.padding(.top, 20)` reinstates the
    /// visual gap between sections that the old 32pt `LazyVStack`
    /// spacing used to provide.
    private func tvSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    /// Row factory — each returned view is a direct child of the
    /// flat `LazyVStack`, so SwiftUI can lazy-materialise them.
    private func tvChannelRow(_ item: ChannelDisplayItem) -> some View {
        CompactChannelRow(
            item: item,
            isAlreadyAdded: alreadyAdded(item),
            isDisabled: multiviewStore.isAtMax
        ) {
            tap(item)
        }
    }
    #else
    private func section(title: String, items: [ChannelDisplayItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                CompactChannelRow(
                    item: item,
                    isAlreadyAdded: alreadyAdded(item),
                    isDisabled: multiviewStore.isAtMax
                ) {
                    tap(item)
                }
            }
        }
    }
    #endif

    /// Tap dispatcher. v1.6.12: a tap on an already-added row now
    /// removes the corresponding tile from multiview (deselect)
    /// rather than being a no-op. Pre-v1.6.12 the user had to
    /// dismiss the picker, find the tile in the grid, and remove it
    /// from the per-tile menu — confusingly indirect for what is
    /// just "I changed my mind." Now the picker is a true toggle:
    /// tap to add, tap again to remove.
    ///
    /// No toast on remove — the row's trailing icon flips from green
    /// check back to the `+` and the live tile count in the header
    /// drops by one, both immediately visible and far less noisy than
    /// a transient capsule. Adds still show their own error/warning
    /// toasts via `commitAdd`.
    private func tap(_ item: ChannelDisplayItem) {
        if alreadyAdded(item) {
            multiviewStore.remove(id: item.id)
        } else {
            tryAdd(item)
        }
    }

    // MARK: - Data

    private var favoriteChannels: [ChannelDisplayItem] {
        applyFilters(favoritesStore.favoriteItems)
    }

    private var recentChannels: [ChannelDisplayItem] {
        applyFilters(recentsStore.resolved)
    }

    private var allChannelsFiltered: [ChannelDisplayItem] {
        applyFilters(channelStore.channels)
    }

    /// Groups eligible to appear in the filter pill bar — the
    /// store-ordered list with user-hidden groups removed. A group
    /// only shows if at least one channel in `channelStore.channels`
    /// belongs to it; `orderedGroups` is already maintained that way
    /// upstream.
    private var visibleGroups: [String] {
        channelStore.orderedGroups.filter { !hiddenGroups.contains($0) }
    }

    /// Pills shown in the filter bar — leading "All" sentinel plus
    /// every visible group. Computed (not stored) so the bar updates
    /// automatically when the channel store finishes its initial
    /// load while the picker is open (Dispatcharr cold launch can
    /// take a couple of seconds).
    private var groupChips: [String] {
        ["All"] + visibleGroups
    }

    /// Apply the current group + search filters. Group filter runs
    /// first because it's the cheaper predicate (`==` vs three
    /// substring comparisons) and prunes the working set before the
    /// substring scan. `selectedGroup == "All"` short-circuits past
    /// the group step.
    ///
    /// Matches across name / group / channel number, case-insensitive.
    /// `String.contains` is a literal substring match — no regex
    /// injection surface even though `searchText` is user input.
    private func applyFilters(_ items: [ChannelDisplayItem]) -> [ChannelDisplayItem] {
        var result = items
        if selectedGroup != "All" {
            result = result.filter { $0.group == selectedGroup }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { item in
                item.name.lowercased().contains(q)
                    || item.group.lowercased().contains(q)
                    || item.number.lowercased().contains(q)
            }
        }
        return result
    }

    /// One-shot loader for the user's hidden-groups set. Called from
    /// each body's `.onAppear`. If the previously-selected group is
    /// now hidden (because the user hid it elsewhere between picker
    /// presentations), snap back to "All" so the filter doesn't get
    /// stuck pointing at an invisible chip.
    private func loadHiddenGroups() {
        hiddenGroups = HiddenGroupsStore.load(forKey: "hiddenChannelGroups")
        if selectedGroup != "All" && hiddenGroups.contains(selectedGroup) {
            selectedGroup = "All"
        }
    }

    private func alreadyAdded(_ item: ChannelDisplayItem) -> Bool {
        multiviewStore.tiles.contains { $0.item.id == item.id }
    }

    // MARK: - Add flow

    private func tryAdd(_ item: ChannelDisplayItem) {
        // Thermal refusal — the container banner is the primary
        // signal; this toast gives the immediate feedback at the
        // moment of the blocked tap. Threshold is `.critical` only
        // (matches `isThermallyStressed`); `.serious` is warning-not-
        // blocking per the plan.
        if multiviewStore.isThermallyStressed {
            DebugLogger.shared.log(
                "[MV-Thermal] add refused: critical",
                category: "Playback", level: .warning
            )
            showToast("Device is too hot to add more streams")
            return
        }
        commitAdd(item, bypassWarning: false)
    }

    private func commitAdd(_ item: ChannelDisplayItem, bypassWarning: Bool) {
        // Auto-seed when this sheet was presented from single-mode
        // `PlayerView` (tile list is empty, `PlayerSession.mode` is
        // not yet `.multiview`). Seeding tile 0 here — at commit time,
        // *after* the user has picked — is the whole point of the
        // sheet-first flow: the current stream keeps playing under
        // the sheet while the user browses, and the mode flip / view
        // swap happens exactly once in response to a deliberate pick
        // rather than at button-tap.
        //
        // Idempotent: `enterMultiview(seeding:server:)` only seeds if
        // `tiles.isEmpty`, and we guard on that here too. If the
        // sheet is already open from inside `MultiviewContainerView`
        // (the transport-bar `+`), this branch is a no-op and we
        // fall straight through to `add(...)`.
        if multiviewStore.tiles.isEmpty,
           PlayerSession.shared.mode != .multiview,
           let currentItem = NowPlayingManager.shared.playingItem,
           let server = channelStore.activeServer {
            DebugLogger.shared.log(
                "[MV-Mode] commitAdd from single — seeding tile 0 with current=\(currentItem.name) before picked=\(item.name)",
                category: "Playback", level: .info
            )
            PlayerSession.shared.enterMultiview(seeding: currentItem, server: server)
        }

        let result = multiviewStore.add(
            item,
            server: channelStore.activeServer,
            bypassWarning: bypassWarning
        )
        switch result {
        case .added:
            // Push into recents so the next add-sheet open shows it
            // near the top. Keeps the "frequently-added" set warm
            // without a dedicated "most-added" heuristic.
            recentsStore.push(item)
        case .needsWarning:
            DebugLogger.shared.log(
                "[MV-Tile] perf warning shown (count=\(multiviewStore.count))",
                category: "Playback", level: .info
            )
            pendingWarningItem = item
            multiviewStore.warningLastShownAt = Date()
        case .rejectedMax:
            showToast("Maximum \(multiviewStore.maxTiles) streams reached")
        case .alreadyPresent:
            showToast("Already added")
        case .unresolvable:
            showToast("This channel has no playable stream")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            #if os(tvOS)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            #else
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #endif
            .foregroundStyle(.white)
            .background(
                Capsule().fill(Color.black.opacity(0.85))
            )
            .accessibilityLabel(text)
    }
}

// MARK: - Namespaced ID helpers

private extension ChannelDisplayItem {
    /// Section-namespaced identity used as a SwiftUI `ForEach` id
    /// when the same item appears in multiple sections of the same
    /// `LazyVStack`. SwiftUI emits "ID is used by multiple child
    /// views" runtime warnings when two siblings share an
    /// `explicitID`; prefixing with a section name restores
    /// uniqueness without allocating a whole wrapper type per row.
    ///
    /// Exposed as three computed properties (rather than a single
    /// `func namespacedID(_:)`) because `ForEach(_:id:)` requires a
    /// `KeyPath<Element, ID>`, and Swift key paths can reference
    /// computed properties but not functions with arguments.
    var favSectionID: String { "fav:\(id)" }
    var recentSectionID: String { "recent:\(id)" }
    var allSectionID: String { "all:\(id)" }
}

// MARK: - Shared sheet modifiers

/// Bundles the perf-warning alert + toast overlay + animation
/// modifiers so both the iPad and tvOS body paths apply them
/// identically without duplicating 30 lines of code. The caller
/// passes in the bindings and closures it owns; the modifier
/// attaches the SwiftUI side.
private struct SharedSheetModifiers: ViewModifier {
    @Binding var pendingWarningItem: ChannelDisplayItem?
    @Binding var toastMessage: String?
    let softLimit: Int
    let onContinueWarning: (ChannelDisplayItem) -> Void
    let onCancelWarning: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Performance may degrade",
                isPresented: Binding(
                    get: { pendingWarningItem != nil },
                    set: { if !$0 { pendingWarningItem = nil } }
                ),
                presenting: pendingWarningItem
            ) { item in
                Button("Continue", role: .destructive) {
                    onContinueWarning(item)
                }
                Button("Cancel", role: .cancel) {
                    onCancelWarning()
                }
            } message: { _ in
                Text("Adding more than \(softLimit) streams may cause audio drops, buffering, or overheating on some devices.")
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    toast(toastMessage)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            #if os(tvOS)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            #else
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #endif
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .accessibilityLabel(text)
    }
}

// MARK: - tvOS group filter pill style

#if os(tvOS)
/// Pill style for the picker's group-filter chips. Mirrors the
/// `TVGroupPillButtonStyle` used by `ChannelListView`'s tvOS group
/// row (which is `private` to that file, hence this duplicate) so
/// the picker reads as a sibling to the main channel list rather
/// than its own visual dialect.
///
/// - Selected: accent fill, dark foreground (high-contrast against
///   the brand color).
/// - Focused-not-selected: accent ring + 1.05 scale, label switches
///   to white so it's legible against the elevated background.
/// - Resting: elevated background, secondary-text label, slight
///   opacity dip so the focused chip clearly leads.
struct PickerGroupPillButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .foregroundColor(isSelected
                             ? .appBackground
                             : (focused ? .white : .textSecondary))
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
            )
            .overlay(
                Capsule()
                    .stroke(focused && !isSelected ? Color.accentPrimary : Color.clear,
                            lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .opacity(focused ? 1.0 : (isSelected ? 1.0 : 0.85))
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif

// MARK: - tvOS close button style

#if os(tvOS)
/// Capsule-shaped focus chrome for the sheet's Close button.
/// Shares the same design language as
/// `MultiviewTransportBar.TransportButtonStyle`: default subtle
/// white fill, focused state gets a heavy white ring + 1.08 scale
/// + accent shadow. Reads `@Environment(\.isFocused)` so SwiftUI
/// focus state drives the visual without an external binding.
struct AddSheetCloseButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(
                    isFocused ? Color.white.opacity(0.28) : Color.white.opacity(0.10)
                )
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(0.18),
                    lineWidth: isFocused ? 4 : 1
                )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: isFocused ? .black.opacity(0.55) : .clear,
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif
