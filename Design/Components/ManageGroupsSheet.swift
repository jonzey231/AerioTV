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

// MARK: - Group Order Persistence

/// Reads/writes a user-defined group display order to UserDefaults.
///
/// Unlike `HiddenGroupsStore` (a Set, stored sorted-as-JSON), order MUST
/// be preserved, so this stores a native `[String]` array. That also lets
/// it ride `SyncManager.syncStringArrayKeys` (the order-preserving iCloud
/// path used by `favoriteOrder`) rather than the hidden-group path, which
/// `.sorted()`s on apply and would destroy the order.
enum GroupOrderStore {
    static func load(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ order: [String], forKey key: String) {
        UserDefaults.standard.set(order, forKey: key)
    }

    static func clear(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Apply a saved custom order to a fresh server-ordered group list.
    /// Groups present in `order` come first (in saved order); any groups
    /// not in `order` (new since the order was saved) are appended in
    /// their original server order; entries in `order` no longer present
    /// are dropped. An empty `order` means "use the server default".
    static func apply(_ groups: [String], order: [String]) -> [String] {
        guard !order.isEmpty else { return groups }
        let present = Set(groups)
        var result = order.filter { present.contains($0) }
        let placed = Set(result)
        result.append(contentsOf: groups.filter { !placed.contains($0) })
        return result
    }
}

// MARK: - Manage Groups Sheet

/// A sheet that lets users toggle visibility of individual groups, and
/// (when `orderStorageKey` is supplied) reorder them alphabetically or
/// manually. Hidden groups persist via `storageKey`; the custom order
/// persists via `orderStorageKey`.
struct ManageGroupsSheet: View {
    let title: String
    let allGroups: [String]
    let storageKey: String
    let onDismiss: (Set<String>) -> Void

    /// When non-nil, enables alphabetical + manual reordering and persists
    /// the order under this key. Nil keeps the sheet visibility-only (the
    /// VOD movie/series group sheets pass nil today).
    var orderStorageKey: String? = nil
    /// Reports the effective custom order whenever it changes (empty array
    /// after a reset-to-default) so the host can re-render its group pills.
    /// Only meaningful when `orderStorageKey` is set.
    var onOrderChanged: (([String]) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var hiddenGroups: Set<String> = []
    /// Working display order. Initialised from the saved order (or
    /// `allGroups` when reorder is disabled) in `.onAppear`.
    @State private var orderedLocal: [String] = []
    #if os(tvOS)
    /// The group currently "grabbed" for d-pad reordering, or nil.
    @State private var grabbedGroup: String? = nil
    #endif

    #if os(iOS)
    /// Mirrors the Developer-Settings flag. When ON on an iPhone, the sheet
    /// exposes a Layout section with two companion toggles below so the
    /// user can hide the filter pills + search bar on Live TV.
    @AppStorage("ui.iphone.compactChrome") private var compactChromeiPhone = false
    @AppStorage("ui.iphone.hideFilterBar") private var hideFilterBarCompact = false
    @AppStorage("ui.iphone.hideSearchBar") private var hideSearchBarCompact = false
    private var showsCompactLayoutSection: Bool {
        compactChromeiPhone && UIDevice.current.userInterfaceIdiom == .phone
    }
    #endif

    private var reorderEnabled: Bool { orderStorageKey != nil }

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
            // On tvOS the Menu/Back button is the natural dismiss gesture.
            // Hide the toolbar to avoid the white system pill button. When a
            // group is grabbed the move controller owns Menu (cancel grab);
            // otherwise Menu dismisses the sheet.
            .toolbar(.hidden)
            .onExitCommand {
                onDismiss(hiddenGroups)
                dismiss()
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if reorderEnabled {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                            .foregroundColor(.accentPrimary)
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
            if let key = orderStorageKey {
                orderedLocal = GroupOrderStore.apply(allGroups, order: GroupOrderStore.load(forKey: key))
            } else {
                orderedLocal = allGroups
            }
        }
    }

    // MARK: - Mutations

    private func toggleHidden(_ group: String) {
        if hiddenGroups.contains(group) { hiddenGroups.remove(group) }
        else { hiddenGroups.insert(group) }
        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
    }

    private func persistOrder() {
        guard let key = orderStorageKey else { return }
        GroupOrderStore.save(orderedLocal, forKey: key)
        onOrderChanged?(orderedLocal)
    }

    private func sortAlphabetically() {
        orderedLocal.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persistOrder()
    }

    private func resetOrder() {
        guard let key = orderStorageKey else { return }
        GroupOrderStore.clear(forKey: key)
        orderedLocal = allGroups
        onOrderChanged?([])
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        guard reorderEnabled else { return }
        orderedLocal.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    #if os(tvOS)
    private func moveGrabbed(_ direction: MoveCommandDirection) {
        guard let grabbed = grabbedGroup,
              let idx = orderedLocal.firstIndex(of: grabbed) else { return }
        let target: Int
        switch direction {
        case .up:   target = idx - 1
        case .down: target = idx + 1
        default:    return
        }
        guard orderedLocal.indices.contains(target) else { return }
        orderedLocal.swapAt(idx, target)
        persistOrder()
    }
    #endif

    // MARK: non-tvOS layout — checkmark list
    #if !os(tvOS)
    private var iOSGroupList: some View {
        List {
            // Compact-chrome layout controls. Only appears when the Developer
            // flag is ON and we're on an iPhone — gives users one place to
            // hide the filter pills + search bar in Live TV. Mirrors Veldmuus's
            // Discord proposal; kept opt-in so the main user base isn't
            // affected until we promote the flag.
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

            // Order controls (Live TV only). Alphabetical sort + reset; the
            // manual drag-to-reorder happens in the groups list below once
            // the user taps Edit.
            if reorderEnabled {
                Section {
                    Button {
                        sortAlphabetically()
                    } label: {
                        Label("Sort Alphabetically (A-Z)", systemImage: "textformat")
                            .font(.bodyMedium)
                            .foregroundColor(.accentPrimary)
                    }
                    .listRowBackground(Color.cardBackground)

                    Button {
                        resetOrder()
                    } label: {
                        Label("Reset to Default Order", systemImage: "arrow.uturn.backward")
                            .font(.bodyMedium)
                            .foregroundColor(.accentPrimary)
                    }
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Order")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                        .textCase(nil)
                } footer: {
                    Text("Tap Edit, then drag the handles to arrange groups. This order drives the group filter in Live TV.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                        .textCase(nil)
                }
            }

            Section {
                ForEach(orderedLocal, id: \.self) { group in
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
    // MARK: tvOS layout — custom focus-styled rows (no system white highlight)
    private var tvGroupList: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(reorderEnabled
                         ? "Toggle groups on or off. Hold Select on a group to pick it up, then swipe up or down to move it."
                         : "Toggle groups on or off to show or hide them.")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 48)
                        .padding(.top, 8)
                        .padding(.bottom, reorderEnabled ? 16 : 20)

                    if reorderEnabled {
                        HStack(spacing: 16) {
                            TVActionChip(title: "Sort A-Z", systemImage: "textformat") {
                                sortAlphabetically()
                            }
                            TVActionChip(title: "Reset Order", systemImage: "arrow.uturn.backward") {
                                resetOrder()
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.bottom, 16)
                    }

                    ForEach(orderedLocal, id: \.self) { group in
                        if reorderEnabled {
                            TVReorderableGroupRow(
                                group: group,
                                isOn: !hiddenGroups.contains(group),
                                isGrabbed: grabbedGroup == group,
                                reorderActive: grabbedGroup != nil,
                                onToggle: { toggleHidden(group) },
                                onGrab: { grabbedGroup = group }
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

            // Move controller: shown while a group is grabbed. It is the
            // ONLY focusable element during a grab (the rows drop their
            // press overlays via `reorderActive`), so d-pad up/down has no
            // focus target to move to and reliably fires `.onMoveCommand`.
            if let grabbed = grabbedGroup {
                TVMoveController(
                    groupName: grabbed,
                    onMove: { moveGrabbed($0) },
                    onDrop: { grabbedGroup = nil },
                    onCancel: { grabbedGroup = nil }
                )
            }
        }
    }
    #endif
}

// MARK: - Filter Bar Button

/// Small icon button shown in the filter bar to open the manage-groups sheet.
struct ManageGroupsButton: View {
    let action: () -> Void
    let hiddenCount: Int

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    #if os(tvOS)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(isFocused ? .white : .accentPrimary)
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
        .buttonStyle(TVNoRingButtonStyle())
        .focused($isFocused)
        .padding(16)
        .background(
            Circle()
                .fill(isFocused ? Color.accentPrimary.opacity(0.30) : Color.elevatedBackground)
        )
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.easeInOut(duration: 0.13), value: isFocused)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

#if os(tvOS)
// MARK: - tvOS Group Toggle Row

/// A single row in the tvOS ManageGroups list. Uses the app's own
/// focus-ring style (teal tinted card) instead of the system white highlight.
struct TVGroupToggleRow: View {
    let group: String
    let isOn: Bool
    let onToggle: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Text(group)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(isFocused ? .white : .textPrimary)
                    .lineLimit(1)

                Spacer()

                // State indicator — matches the filter-bar pill style
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
                    .fill(isFocused
                        ? Color.accentPrimary.opacity(0.18)
                        : Color.clear)
                    .padding(.horizontal, 32)
            )
        }
        .buttonStyle(TVNoRingButtonStyle())
        .focused($isFocused)
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - tvOS Reorderable Group Row

/// Group row used when reordering is enabled. Mirrors `TVGroupToggleRow`'s
/// look but uses the UIKit-backed `TVPressOverlay` for a reliable tvOS
/// long-press (Select = toggle visibility, hold Select = grab for move).
/// While any group is grabbed (`reorderActive`) it drops the overlay so it
/// is no longer focusable, handing focus to the `TVMoveController`.
private struct TVReorderableGroupRow: View {
    let group: String
    let isOn: Bool
    let isGrabbed: Bool
    let reorderActive: Bool
    let onToggle: () -> Void
    let onGrab: () -> Void

    @State private var isFocused = false

    var body: some View {
        if reorderActive {
            rowBody
        } else {
            rowBody.overlay(
                TVPressOverlay(
                    minimumPressDuration: 0.5,
                    isFocused: $isFocused,
                    onTap: onToggle,
                    onLongPress: onGrab
                )
            )
        }
    }

    private var highlighted: Bool { isFocused || isGrabbed }

    private var rowBody: some View {
        HStack {
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

            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Color.accentPrimary : Color.textTertiary)
                    .frame(width: 8, height: 8)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(isOn
                        ? (highlighted ? .white : .accentPrimary)
                        : (highlighted ? .white : .textTertiary))
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isGrabbed
                    ? Color.accentPrimary.opacity(0.55)
                    : (isFocused ? Color.accentPrimary.opacity(0.18) : Color.clear))
                .padding(.horizontal, 32)
        )
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .animation(.easeInOut(duration: 0.12), value: isGrabbed)
    }
}

// MARK: - tvOS Action Chip (Sort / Reset)

private struct TVActionChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFocused ? Color.accentPrimary.opacity(0.30) : Color.elevatedBackground)
                )
                .foregroundColor(isFocused ? .white : .accentPrimary)
        }
        .buttonStyle(TVNoRingButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - tvOS Move Controller

/// Modal-ish overlay shown while a group is grabbed. The single focusable
/// Button captures Select (drop) and Menu (cancel); `.onMoveCommand`
/// captures d-pad up/down to reposition the grabbed group live in the list
/// behind it.
private struct TVMoveController: View {
    let groupName: String
    let onMove: (MoveCommandDirection) -> Void
    let onDrop: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            Button(action: onDrop) {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.system(size: 56))
                    Text("Moving \(groupName)")
                        .font(.system(size: 30, weight: .bold))
                    Text("Swipe up or down to reposition. Press to drop. Menu to cancel.")
                        .font(.system(size: 22))
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)
                }
                .foregroundColor(.white)
                .padding(48)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.elevatedBackground)
                )
                .scaleEffect(isFocused ? 1.03 : 1.0)
            }
            .buttonStyle(TVNoRingButtonStyle())
            .focused($isFocused)
            .onMoveCommand { direction in onMove(direction) }
            .onExitCommand { onCancel() }
        }
        .onAppear { isFocused = true }
    }
}
#endif
