//
//  CategoryColorEditors.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

#if os(iOS)  // Phase 1 split: re-opened, block spanned the extraction cut
struct CategoryColorPickerRow: View {
    let category: ProgramCategory

    /// Bound to the UserDefaults-backed hex string via
    /// `@AppStorage`. When the user picks a new colour in the
    /// system picker, SwiftUI writes it here (as hex), which in
    /// turn triggers every observer of the same key to re-render
    /// — including every `GuideProgramButton.cellBackground`
    /// via the existing `@AppStorage` wiring on the cell.
    @AppStorage private var storedHex: String

    init(category: ProgramCategory) {
        self.category = category
        // Seed the @AppStorage with the category's default hex
        // when the key is missing, so the ColorPicker shows the
        // current effective colour on first render. Writing the
        // default here is fine because `.onChange` is idempotent
        // and `resetPaletteToDefaults()` removes the key
        // explicitly.
        self._storedHex = AppStorage(
            wrappedValue: category.defaultHex,
            category.storageKey
        )
    }

    /// Two-way bridge between the hex string (persistence) and
    /// `Color` (ColorPicker's required binding type).
    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: storedHex) },
            set: { newColor in
                let hex = newColor.toHex()
                // Skip no-op writes to avoid a pointless
                // UserDefaults change notification that would
                // still trigger observers.
                if hex != storedHex { storedHex = hex }
            }
        )
    }

    var body: some View {
        ColorPicker(selection: colorBinding, supportsOpacity: false) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: storedHex).opacity(0.22))
                        .frame(width: 36, height: 36)
                    Image(systemName: category.sfSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: storedHex))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.displayName)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                    Text("Default: #\(category.defaultHex)")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
            }
        }
        // Palette picks are deliberate user actions — push to iCloud
        // right away instead of waiting for the 60-second debounced
        // preferences push. Same rationale as FavoritesStore: force-
        // quitting the app inside the debounce window would otherwise
        // drop the change on the floor and the next launch would
        // re-import the stale palette from KVS.
        .onChange(of: storedHex) { _, _ in
            SyncManager.shared.pushPreferencesImmediate()
        }
    }
}
#endif

// MARK: - More Categories View
//
// Disclosure target for "Add more categories" in the Appearance
// settings screen (Palette section). Presents the seven additional
// built-in buckets
// (Documentary / Drama / Comedy / Reality / Educational / Sci-Fi /
// Music) with an enable toggle + color picker on each row, plus a
// "Custom" navigation link for user-defined category → color
// mappings. Default buckets stay on the parent screen.
#if os(iOS)
struct MoreCategoriesView: View {
    @ObservedObject private var theme = ThemeManager.shared
    /// Bumped whenever a toggle flips so SwiftUI re-renders the
    /// disabled-state opacity + the upstream summary row. Writes
    /// to UserDefaults go through `CategoryColor.setBucketEnabled`
    /// which doesn't fire an @AppStorage notification (the key is
    /// dynamic), so we nudge the view manually.
    @State private var enabledRevision: Int = 0

    var body: some View {
        List {
            Section {
                ForEach(CategoryColor.additionalBuckets, id: \.rawValue) { cat in
                    additionalBucketRow(cat)
                        .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Additional Buckets").sectionHeaderStyle()
            } footer: {
                Text("Toggle a bucket on to include its aliases in the matcher. Defaults cover Sports, Movies, Kids, and News — these are extras for feeds that heavily tag Documentary, Drama, Sitcoms, etc.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }

            Section {
                NavigationLink {
                    CustomCategoriesView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paintbrush.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom").font(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Define your own category strings and colors")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                        }
                        Spacer()
                        Text("\(CategoryColor.loadCustomCategories().count)")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("User-Defined").sectionHeaderStyle()
            } footer: {
                Text("Custom entries are checked before the built-in buckets, so you can override a match like \"Horror\" or \"Cooking\" with your own color even if a built-in bucket would have caught it.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("More Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    @ViewBuilder
    private func additionalBucketRow(_ cat: ProgramCategory) -> some View {
        let isOn = Binding(
            get: { CategoryColor.isBucketEnabled(cat) },
            set: { newValue in
                CategoryColor.setBucketEnabled(cat, newValue)
                enabledRevision &+= 1
                SyncManager.shared.pushPreferencesImmediate()
            }
        )
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(cat.baseColor.opacity(isOn.wrappedValue ? 0.8 : 0.3))
                        .frame(width: 28, height: 28)
                    Image(systemName: cat.sfSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.displayName)
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                    // "Customize color" shown regardless of toggle
                    // state — the user reported that hiding it on
                    // off made the nav-link feel like it "disappeared"
                    // after flipping the toggle off. Users are free
                    // to edit the color even when the bucket isn't
                    // actively matching; this just pre-stages the
                    // color for when they eventually enable it.
                    NavigationLink {
                        SingleCategoryColorEditor(category: cat)
                    } label: {
                        Text("Customize color")
                            .font(.labelSmall)
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(theme.accent)
    }
}

// MARK: - Single Category Color Editor
//
// Standalone color picker for one additional bucket, reached via
// the "Customize color" label inside MoreCategoriesView. Mirrors
// the CategoryColorPickerRow behaviour — same hex + color well +
// reset + sync — but in its own screen so the toggles list above
// stays scannable.
struct SingleCategoryColorEditor: View {
    let category: ProgramCategory
    @State private var storedHex: String = ""

    private var currentColor: Binding<Color> {
        Binding(
            get: { Color(hex: storedHex.isEmpty ? category.defaultHex : storedHex) },
            set: { newColor in
                let hex = newColor.toHex()
                storedHex = hex
                category.setCustomHex(hex)
                SyncManager.shared.pushPreferencesImmediate()
            }
        )
    }

    var body: some View {
        List {
            Section {
                ColorPicker(category.displayName, selection: currentColor, supportsOpacity: false)
                    .listRowBackground(Color.cardBackground)
                HStack {
                    Text("Hex")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(storedHex.isEmpty ? category.defaultHex : storedHex)
                        .font(.monoSmall)
                        .foregroundColor(.textTertiary)
                }
                .listRowBackground(Color.cardBackground)

                Button(role: .destructive) {
                    category.setCustomHex(nil)
                    storedHex = ""
                    SyncManager.shared.pushPreferencesImmediate()
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Reset to Default")
                    }
                    .foregroundColor(.statusWarning)
                }
                .listRowBackground(Color.cardBackground)
            } footer: {
                Text("Applies wherever a program's category matches one of this bucket's aliases in the EPG (see alias list in CategoryColor.swift).")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(category.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .onAppear {
            storedHex = UserDefaults.standard.string(forKey: category.storageKey) ?? ""
        }
    }
}

// MARK: - Custom Categories View
//
// User-defined string → color mappings. Each entry is a case-
// insensitive substring matched against the program's raw
// `<category>` value, with its own hex. Custom entries win over
// built-in buckets (see `CategoryColor.customHex(for:)`). Stored
// as a JSON array in UserDefaults under
// `CategoryColor.customCategoriesKey` and mirrored via SyncManager.
struct CustomCategoriesView: View {
    @State private var entries: [CategoryColor.CustomCategory] = []
    @State private var showAddSheet = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No custom categories yet")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Tap + above to add a match string (e.g. \"Horror\") and pick a color. Custom entries win over the built-in buckets.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.cardBackground)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink {
                            CustomCategoryEditor(
                                entry: entry,
                                onSave: { updated in
                                    if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
                                        entries[idx] = updated
                                        persist()
                                    }
                                },
                                onDelete: {
                                    entries.removeAll { $0.id == entry.id }
                                    persist()
                                }
                            )
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(hex: entry.hex))
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.match)
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    Text(entry.hex)
                                        .font(.monoSmall)
                                        .foregroundColor(.textTertiary)
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                    .onDelete { indexSet in
                        entries.remove(atOffsets: indexSet)
                        persist()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Custom Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                CustomCategoryEditor(
                    entry: CategoryColor.CustomCategory(match: "", hex: "FF5722"),
                    isNew: true,
                    onSave: { new in
                        entries.append(new)
                        persist()
                        showAddSheet = false
                    },
                    onDelete: { showAddSheet = false }
                )
            }
        }
        .onAppear {
            entries = CategoryColor.loadCustomCategories()
        }
    }

    private func persist() {
        CategoryColor.saveCustomCategories(entries)
        SyncManager.shared.pushPreferencesImmediate()
    }
}

// MARK: - Custom Category Editor
//
// Used both for adding a new entry (presented as a sheet from the
// "+" toolbar button) and editing an existing one (pushed as a
// nav link). Validates the match string is non-empty before save;
// hex is always valid because it comes from ColorPicker.
struct CustomCategoryEditor: View {
    @State var entry: CategoryColor.CustomCategory
    var isNew: Bool = false
    let onSave: (CategoryColor.CustomCategory) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: entry.hex) },
            set: { entry.hex = $0.toHex() }
        )
    }

    var body: some View {
        List {
            Section {
                TextField("Match string (e.g. Horror)", text: $entry.match)
                    .listRowBackground(Color.cardBackground)
                    .autocorrectionDisabled()
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .listRowBackground(Color.cardBackground)
                HStack {
                    Text("Hex")
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(entry.hex)
                        .font(.monoSmall)
                        .foregroundColor(.textTertiary)
                }
                .listRowBackground(Color.cardBackground)
            } footer: {
                Text("Matching is case-insensitive and uses `contains` — entering \"Horror\" will colour any program whose XMLTV category includes the word horror.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }

            if !isNew {
                Section {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .foregroundColor(.statusLive)
                    }
                    .listRowBackground(Color.cardBackground)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle(isNew ? "New Custom Category" : "Edit Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isNew ? "Add" : "Save") {
                    let trimmed = entry.match.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    var saved = entry
                    saved.match = trimmed
                    onSave(saved)
                    dismiss()
                }
                .disabled(entry.match.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
#endif

#if os(tvOS)
// MARK: - tvOS Menu-button pop support
//
// MainTabView's `.onExitCommand { handleMenuPress() }` on the outer
// TabView intercepts every Menu press before the inner NavigationStack
// (or any per-destination `.onExitCommand`) can react. That's the
// documented behaviour on tvOS and the reason
// `isVODDetailPushed`/`vodNavPopRequested` exist for the VOD detail
// pane. Settings needs the same pattern: MainTabView must know when a
// Settings subview is pushed, and it must have a way to request a pop
// from the outside. We expose both via bindings (see SettingsView's
// `isSubviewPushed` / `popRequested`).
//
// Pop sources we have to cover:
//   1. `navPath` pushes — Appearance, Network, DVR, Developer,
//      Edit Server. `navPath.count > 0` detects these;
//      `navPath.removeLast()` pops them.
//   2. Classic `NavigationLink(destination:)` pushes — ServerDetailView
//      (from the Settings root via TVSettingsNavRow) and
//      MyRecordingsView (pushed from inside DVRSettingsView via
//      TVSettingsNavRow). These bypass `navPath` entirely, so we track
//      them with a LIFO stack of dismiss actions registered on appear
//      and unregistered on disappear.
//
// When MainTabView sets `popRequested = true`, SettingsView prefers
// popping the classic stack first (LIFO, innermost wins) and falls
// back to `navPath.removeLast()` when the classic stack is empty.

#endif  // Phase 1 split: closes a block that spanned the extraction cut
