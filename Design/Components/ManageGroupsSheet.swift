import SwiftUI

// MARK: - Hidden Groups Persistence

/// Reads/writes a set of hidden group names to UserDefaults for a given key.
enum HiddenGroupsStore {
    static func load(forKey key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }

    static func save(_ groups: Set<String>, forKey key: String) {
        let data = try? JSONEncoder().encode(Array(groups).sorted())
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Group Sort Mode

/// How the Live TV group list is ordered. Stored as the raw string so it
/// rides SyncManager's plain-string iCloud path.
enum GroupSortMode: String, CaseIterable {
    case `default`
    case alphabetical
    case manual

    var label: String {
        switch self {
        case .default:      return "Default"
        case .alphabetical: return "A-Z"
        case .manual:       return "Manual"
        }
    }
}

// MARK: - Group Order Persistence

/// Reads/writes the user-defined group order + sort mode.
///
/// The manual order MUST preserve sequence, so it is stored as a native
/// `[String]` array (rides SyncManager.syncStringArrayKeys, the
/// order-preserving iCloud path used by `favoriteOrder` - NOT the
/// hidden-group path, which `.sorted()`s on apply). The mode is a plain
/// string (syncStringKeys).
enum GroupOrderStore {
    static func load(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ order: [String], forKey key: String) {
        UserDefaults.standard.set(order, forKey: key)
    }

    static func loadMode(forKey key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? GroupSortMode.default.rawValue
    }

    static func saveMode(_ mode: String, forKey key: String) {
        UserDefaults.standard.set(mode, forKey: key)
    }

    /// Apply a saved manual order to a fresh server-ordered group list:
    /// groups present in `order` come first (in saved order), then any
    /// groups not in `order` (new since the order was saved) appended in
    /// server order; entries in `order` no longer present are dropped.
    static func apply(_ groups: [String], order: [String]) -> [String] {
        guard !order.isEmpty else { return groups }
        let present = Set(groups)
        var result = order.filter { present.contains($0) }
        let placed = Set(result)
        result.append(contentsOf: groups.filter { !placed.contains($0) })
        return result
    }

    /// Resolve the effective display order for a sort mode.
    static func displayOrder(_ groups: [String], mode: String, order: [String]) -> [String] {
        switch GroupSortMode(rawValue: mode) ?? .default {
        case .alphabetical:
            return groups.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case .manual:
            return apply(groups, order: order)
        case .default:
            return groups
        }
    }
}

// MARK: - Manage Groups Sheet

/// A sheet that toggles group visibility and (when `orderStorageKey` is
/// supplied) orders the groups via a Default / A-Z / Manual selector.
struct ManageGroupsSheet: View {
    let title: String
    let allGroups: [String]
    let storageKey: String
    let onDismiss: (Set<String>) -> Void

    /// When non-nil, enables the Default/A-Z/Manual order selector and
    /// persists the manual order under this key (mode under
    /// `<key>.sortMode`). Nil keeps the sheet visibility-only (VOD).
    var orderStorageKey: String? = nil
    /// Reports (modeRawValue, manualOrder) whenever the order config
    /// changes so the host can re-render its group pills.
    var onConfigChanged: ((String, [String]) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var hiddenGroups: Set<String> = []
    @State private var sortMode: GroupSortMode = .default
    /// The reconciled full manual order (every current group, in saved
    /// sequence). Mutated by drag (iOS) / d-pad move (tvOS).
    @State private var manualOrder: [String] = []
    #if os(tvOS)
    /// The group currently picked up for d-pad reordering, or nil.
    @State private var grabbedGroup: String? = nil
    #endif

    #if os(iOS)
    @AppStorage("ui.iphone.compactChrome") private var compactChromeiPhone = false
    @AppStorage("ui.iphone.hideFilterBar") private var hideFilterBarCompact = false
    @AppStorage("ui.iphone.hideSearchBar") private var hideSearchBarCompact = false
    private var showsCompactLayoutSection: Bool {
        compactChromeiPhone && UIDevice.current.userInterfaceIdiom == .phone
    }
    #endif

    private var reorderEnabled: Bool { orderStorageKey != nil }
    private var modeKey: String? { orderStorageKey.map { $0 + ".sortMode" } }

    /// Groups in the order they should be displayed for the current mode.
    private var displayList: [String] {
        switch sortMode {
        case .alphabetical:
            return allGroups.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case .manual:
            return manualOrder.isEmpty ? allGroups : manualOrder
        case .default:
            return allGroups
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if allGroups.isEmpty {
                    Text("No groups available")
                        .font(.bodyMedium)
                        .foregroundColor(.textSecondary)
                } else {
                    #if os(tvOS)
                    tvGroupList
                    #else
                    iOSGroupList
                    #endif
                }
            }
            .navigationTitle(title)
            #if os(tvOS)
            .toolbar(.hidden)
            .onExitCommand {
                // While a group is grabbed the row consumes Menu (drop);
                // this only fires when nothing is grabbed -> dismiss.
                onDismiss(hiddenGroups)
                dismiss()
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if reorderEnabled && sortMode == .manual {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton().foregroundColor(.accentPrimary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDismiss(hiddenGroups)
                        dismiss()
                    }
                    .foregroundColor(.accentPrimary)
                }
            }
            #endif
        }
        .onAppear {
            hiddenGroups = HiddenGroupsStore.load(forKey: storageKey)
            if let key = orderStorageKey, let mKey = modeKey {
                sortMode = GroupSortMode(rawValue: GroupOrderStore.loadMode(forKey: mKey)) ?? .default
                manualOrder = GroupOrderStore.apply(allGroups, order: GroupOrderStore.load(forKey: key))
            } else {
                sortMode = .default
                manualOrder = allGroups
            }
        }
        .onChange(of: sortMode) { _, newMode in
            // Switching into Manual seeds the manual order from whatever is
            // currently visible so dragging starts from the same arrangement.
            if newMode == .manual {
                manualOrder = GroupOrderStore.apply(allGroups, order: manualOrder)
            }
            persistConfig()
        }
    }

    // MARK: - Mutations

    private func toggleHidden(_ group: String) {
        if hiddenGroups.contains(group) { hiddenGroups.remove(group) }
        else { hiddenGroups.insert(group) }
        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
    }

    private func persistConfig() {
        guard let key = orderStorageKey, let mKey = modeKey else { return }
        GroupOrderStore.saveMode(sortMode.rawValue, forKey: mKey)
        GroupOrderStore.save(manualOrder, forKey: key)
        onConfigChanged?(sortMode.rawValue, manualOrder)
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        guard sortMode == .manual else { return }
        manualOrder.move(fromOffsets: source, toOffset: destination)
        persistConfig()
    }

    #if os(tvOS)
    enum MoveDirection { case up, down }

    private func moveGrabbed(_ direction: MoveDirection) {
        guard let grabbed = grabbedGroup,
              let idx = manualOrder.firstIndex(of: grabbed) else { return }
        let target = direction == .up ? idx - 1 : idx + 1
        guard manualOrder.indices.contains(target) else { return }
        manualOrder.swapAt(idx, target)
        persistConfig()
    }
    #endif

    // MARK: non-tvOS layout - checkmark list
    #if !os(tvOS)
    private var iOSGroupList: some View {
        List {
            if showsCompactLayoutSection {
                Section {
                    Toggle(isOn: $hideFilterBarCompact) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Filter Bar")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text("Removes the group pills strip from Live TV.")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .tint(.accentPrimary)
                    .listRowBackground(Color.cardBackground)

                    Toggle(isOn: $hideSearchBarCompact) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Search Bar")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text("Collapses the always-visible search drawer. Pull down on the list to search.")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .tint(.accentPrimary)
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Layout")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                        .textCase(nil)
                }
            }

            // Order selector (Live TV only).
            if reorderEnabled {
                Section {
                    Picker("Order", selection: $sortMode) {
                        ForEach(GroupSortMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Order")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                        .textCase(nil)
                } footer: {
                    if sortMode == .manual {
                        Text("Tap Edit and/or long press, then drag to arrange groups.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                            .textCase(nil)
                    }
                }
            }

            Section {
                ForEach(displayList, id: \.self) { group in
                    Button {
                        toggleHidden(group)
                    } label: {
                        HStack {
                            Image(systemName: hiddenGroups.contains(group) ? "square" : "checkmark.square.fill")
                                .font(.system(size: 20))
                                .foregroundColor(hiddenGroups.contains(group) ? .textTertiary : .accentPrimary)
                                .frame(width: 28)

                            Text(group)
                                .font(.bodyMedium)
                                .foregroundColor(hiddenGroups.contains(group) ? .textTertiary : .textPrimary)

                            Spacer()
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                .onMove(perform: moveGroups)
            } header: {
                HStack {
                    Text("Check groups to show, uncheck to hide.")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                        .textCase(nil)
                    Spacer()
                    Button("All") {
                        hiddenGroups.removeAll()
                        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
                    }
                    .font(.labelSmall)
                    .foregroundColor(.accentPrimary)
                    .textCase(nil)
                    Text("·").foregroundColor(.textTertiary).textCase(nil)
                    Button("None") {
                        hiddenGroups = Set(allGroups)
                        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
                    }
                    .font(.labelSmall)
                    .foregroundColor(.accentPrimary)
                    .textCase(nil)
                }
            }
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #endif
    }
    #endif

    #if os(tvOS)
    // MARK: tvOS layout - custom focus-styled rows (no system white highlight)
    private var tvGroupList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(instructionText)
                    .font(.labelSmall)
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 48)
                    .padding(.top, 8)
                    .padding(.bottom, reorderEnabled ? 16 : 20)

                if reorderEnabled {
                    HStack(spacing: 12) {
                        ForEach(GroupSortMode.allCases, id: \.self) { mode in
                            TVModeChip(title: mode.label, selected: sortMode == mode) {
                                sortMode = mode
                            }
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.bottom, 16)
                    // Lock the mode selector out while a group is grabbed.
                    .disabled(grabbedGroup != nil)
                }

                ForEach(displayList, id: \.self) { group in
                    if reorderEnabled && sortMode == .manual {
                        TVReorderableGroupRow(
                            group: group,
                            isOn: !hiddenGroups.contains(group),
                            isGrabbed: grabbedGroup == group,
                            anyGrabbed: grabbedGroup != nil,
                            onToggle: {
                                if grabbedGroup == group { grabbedGroup = nil }
                                else if grabbedGroup == nil { toggleHidden(group) }
                            },
                            onGrab: { if grabbedGroup == nil { grabbedGroup = group } },
                            onMoveUp: { moveGrabbed(.up) },
                            onMoveDown: { moveGrabbed(.down) },
                            onFinish: { grabbedGroup = nil }
                        )
                    } else {
                        TVGroupToggleRow(
                            group: group,
                            isOn: !hiddenGroups.contains(group),
                            onToggle: { toggleHidden(group) }
                        )
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }

    private var instructionText: String {
        guard reorderEnabled else {
            return "Toggle groups on or off to show or hide them."
        }
        switch sortMode {
        case .manual:
            return "Hold Select on a group to pick it up, then press or swipe up and down to move it. Select or Menu to drop."
        default:
            return "Choose an order, or pick Manual to arrange groups yourself."
        }
    }
    #endif
}

// MARK: - Filter Bar Button

/// Small icon button shown in the filter bar to open the manage-groups sheet.
struct ManageGroupsButton: View {
    let action: () -> Void
    let hiddenCount: Int

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    #if os(tvOS)
                    // Color is owned by TVManageGroupsButtonStyle so focus
                    // tints it the same way the filter pills tint on focus.
                    .font(.system(size: 30, weight: .medium))
                    #else
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentPrimary)
                    #endif

                if hiddenCount > 0 {
                    Circle()
                        .fill(Color.statusWarning)
                        #if os(tvOS)
                        .frame(width: 10, height: 10)
                        .offset(x: 3, y: -3)
                        #else
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -2)
                        #endif
                }
            }
        }
        #if os(tvOS)
        .buttonStyle(TVManageGroupsButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }
}

#if os(tvOS)
// MARK: - tvOS Mode Chip (Default / A-Z / Manual)

private struct TVModeChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: .medium))
        }
        // Reuse the Live TV filter-pill style so the focus highlight is a
        // capsule matching the pill shape, not the squared system platter.
        .buttonStyle(TVGroupPillButtonStyle(isSelected: selected))
    }
}

// MARK: - tvOS Manage Groups Icon Button Style

/// Round-icon counterpart to `TVGroupPillButtonStyle`: same elevated fill +
/// accent focus stroke + scale, but a Circle so the Manage Groups icon
/// button's focus highlight matches the filter pills beside it instead of
/// the squared system focus platter.
private struct TVManageGroupsButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .foregroundColor(focused ? .white : .accentPrimary)
            // Compact circular icon button: padding hugs the glyph so the
            // focus ring sits right around the icon instead of a wide ring
            // with a big empty gap. strokeBorder keeps the ring inside the
            // footprint (plain .stroke straddles the edge and overshoots).
            .padding(7)
            .background(Circle().fill(Color.elevatedBackground))
            .overlay(
                Circle().strokeBorder(focused ? Color.accentPrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .opacity(focused ? 1.0 : 0.85)
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

// MARK: - tvOS Group Toggle Row (no reorder)

/// A single row in the tvOS ManageGroups list. Uses the app's own
/// focus-ring style (teal tinted card) instead of the system white highlight.
struct TVGroupToggleRow: View {
    let group: String
    let isOn: Bool
    let onToggle: () -> Void

    // @State (not @FocusState): the UIKit-backed TVPressOverlay owns focus
    // and reports it here. A plain SwiftUI Button draws the squared system
    // focus platter on tvOS; the overlay path (same as the Manual rows)
    // gives a clean rounded highlight instead.
    @State private var isFocused = false

    var body: some View {
        rowBody.overlay(
            TVPressOverlay(
                minimumPressDuration: 0.35,
                isFocused: $isFocused,
                onTap: onToggle,
                onLongPress: {}
            )
        )
    }

    private var rowBody: some View {
        HStack {
            Text(group)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(isFocused ? .white : .textPrimary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Color.accentPrimary : Color.textTertiary)
                    .frame(width: 8, height: 8)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(isOn
                        ? (isFocused ? .white : .accentPrimary)
                        : (isFocused ? .white : .textTertiary))
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? Color.accentPrimary.opacity(0.18) : Color.clear)
                .padding(.horizontal, 32)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? Color.accentPrimary : Color.clear, lineWidth: 3)
                .padding(.horizontal, 32)
        )
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - tvOS Reorderable Group Row (Manual mode)

/// Group row for Manual mode. Uses the UIKit-backed `TVPressOverlay` for a
/// reliable long-press grab; once grabbed it captures d-pad up/down in
/// place (via `interceptsDirectional`) and is the only focusable row
/// (`anyGrabbed` drops focus from the others), so focus stays pinned and
/// the list stays fully visible behind it. The grabbed row shows "Moving"
/// with a bright border instead of a centered modal.
private struct TVReorderableGroupRow: View {
    let group: String
    let isOn: Bool
    let isGrabbed: Bool
    let anyGrabbed: Bool
    let onToggle: () -> Void
    let onGrab: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onFinish: () -> Void

    @State private var isFocused = false

    private var highlighted: Bool { isFocused || isGrabbed }

    var body: some View {
        rowBody.overlay(
            TVPressOverlay(
                minimumPressDuration: 0.45,
                isFocused: $isFocused,
                canFocus: !anyGrabbed || isGrabbed,
                interceptsDirectional: isGrabbed,
                onTap: onToggle,
                onLongPress: onGrab,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onMenu: onFinish
            )
        )
    }

    private var rowBody: some View {
        HStack(spacing: 14) {
            if isGrabbed {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }

            Text(group)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(highlighted ? .white : .textPrimary)
                .lineLimit(1)

            Spacer()

            if isGrabbed {
                Text("Moving")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isOn ? Color.accentPrimary : Color.textTertiary)
                        .frame(width: 8, height: 8)
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(isOn
                            ? (isFocused ? .white : .accentPrimary)
                            : (isFocused ? .white : .textTertiary))
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isGrabbed
                    ? Color.accentPrimary.opacity(0.30)
                    : (isFocused ? Color.accentPrimary.opacity(0.18) : Color.clear))
                .padding(.horizontal, 32)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isGrabbed || isFocused ? Color.accentPrimary : Color.clear,
                              lineWidth: isGrabbed ? 4 : 3)
                .padding(.horizontal, 32)
        )
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .animation(.easeInOut(duration: 0.12), value: isGrabbed)
    }
}
#endif
