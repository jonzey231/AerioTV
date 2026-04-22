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

// MARK: - Manage Groups Sheet

/// A sheet that lets users toggle visibility of individual groups.
/// Hidden groups are persisted via the given `storageKey`.
struct ManageGroupsSheet: View {
    let title: String
    let allGroups: [String]
    let storageKey: String
    let onDismiss: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hiddenGroups: Set<String> = []

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
            // Hide the toolbar to avoid the white system pill button.
            .toolbar(.hidden)
            .onExitCommand {
                onDismiss(hiddenGroups)
                dismiss()
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        }
    }

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

            Section {
                ForEach(allGroups, id: \.self) { group in
                    Button {
                        if hiddenGroups.contains(group) { hiddenGroups.remove(group) }
                        else { hiddenGroups.insert(group) }
                        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Toggle groups on or off to show or hide them.")
                    .font(.labelSmall)
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 48)
                    .padding(.top, 8)
                    .padding(.bottom, 20)

                ForEach(allGroups, id: \.self) { group in
                    TVGroupToggleRow(
                        group: group,
                        isOn: !hiddenGroups.contains(group),
                        onToggle: {
                            if hiddenGroups.contains(group) { hiddenGroups.remove(group) }
                            else                            { hiddenGroups.insert(group) }
                            HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
                        }
                    )
                }
            }
            .padding(.vertical, 16)
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
#endif
