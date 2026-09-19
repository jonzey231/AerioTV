//
//  LiveTVSettingsView.swift
//  Aerio
//
//  Settings redesign Phase 1 (regroup, 2026-09-17). Everything that
//  describes the Live TV surfaces - the guide's channel column, the List
//  view, group selection, program badges, guide scale and the category
//  palette - now lives on one page instead of being split across
//  Appearance, App Behaviors and Remote Control.
//
//  No persisted key changed in the move, and every control kept its type
//  and its copy.
//

import SwiftUI

struct LiveTVSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared

    // MARK: Guide presentation
    @AppStorage("ui.showChannelLogos")     private var showChannelLogos = true
    @AppStorage("ui.showChannelNumbers")   private var showChannelNumbers = true
    @AppStorage("ui.showChannelNames")     private var showChannelNames = true
    @AppStorage("ui.showProgramSubtitles") private var showProgramSubtitles = true
    @AppStorage(LogoCorners.listKey)  private var roundedLogoCorners = LogoCorners.listDefault
    @AppStorage(LogoCorners.guideKey) private var roundedGuideCorners = LogoCorners.guideDefault

    // MARK: List view / layout
    @AppStorage("defaultLiveTVView") private var defaultLiveTVView = ""
    #if os(tvOS)
    /// tvOS Live TV layout: "basic" (full cells) or "preview" (focused
    /// program banner above the guide, slim cells). Per device.
    @AppStorage("liveTVLayout") private var liveTVLayout = "basic"
    @ObservedObject private var remote = RemoteControlStore.shared
    #endif
    #if os(iOS)
    @AppStorage(phoneGroupSelectorKey) private var phoneGroupSelector = "sidebar"
    #endif

    // MARK: Badges
    @AppStorage(epgBadgesVisibleKey) private var showEpgBadges = true
    @AppStorage("ui.hiddenEpgBadges") private var hiddenEpgBadgesRaw = ""

    // MARK: Display scale
    @AppStorage("guideScale") private var guideScale: Double = 1.0
    @AppStorage("listScale")  private var listScale: Double = 1.0

    // MARK: Colors
    @AppStorage(CategoryColor.enabledKey) private var enableCategoryColors = true
    @AppStorage("tintChannelCards")       private var tintChannelCards = false

    private static let liveTVViewOptions: [String] = ["", "list", "guide"]

    private func liveTVViewLabel(_ value: String) -> String {
        switch value {
        case "list": return "List"
        case "guide": return "Guide"
        default: return "Automatic"
        }
    }

    private func liveTVViewIcon(_ value: String) -> String {
        switch value {
        case "list": return "list.bullet"
        case "guide": return "calendar"
        default: return "wand.and.stars"
        }
    }

    private static let badgeKinds = ["NEW", "REPEAT", "LIVE", "PREMIERE", "FINALE"]

    private static func badgeTitle(_ label: String) -> String {
        label.prefix(1) + label.dropFirst().lowercased() + " Badge"
    }

    private func badgeShownBinding(_ label: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenEpgBadgesRaw.split(separator: "\n").map(String.init).contains(label) },
            set: { on in
                var set = Set(hiddenEpgBadgesRaw.split(separator: "\n").map(String.init))
                if on { set.remove(label) } else { set.insert(label) }
                hiddenEpgBadgesRaw = set.sorted().joined(separator: "\n")
            }
        )
    }

    /// Phase 3 item 4: what the five badge sub-toggles currently add up to
    /// ("All 5" / "3 of 5" / "None"), so the master row says the state
    /// without the reader opening it. Same string on iOS, tvOS and Android.
    private var badgesSummary: String {
        let hidden = Set(hiddenEpgBadgesRaw.split(separator: "\n").map(String.init))
        let shown = Self.badgeKinds.filter { !hidden.contains($0) }.count
        return SettingsSummary.count(on: shown, of: Self.badgeKinds.count)
    }

    /// Summary text for the "Add more categories" disclosure row.
    fileprivate var moreCategoriesSummary: String {
        let extraOn = CategoryColor.additionalBuckets.filter { CategoryColor.isBucketEnabled($0) }.count
        let customCount = CategoryColor.loadCustomCategories().count
        switch (extraOn, customCount) {
        case (0, 0): return "Off"
        case (let e, 0): return "\(e) extra"
        case (0, let c): return "\(c) custom"
        case (let e, let c): return "\(e) extra · \(c) custom"
        }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("Live TV")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .onAppear {
            // Logan 2026-09-18: Live TV scales cap at 150% like Movies.
            // A value saved under the old 175% range would sit outside the
            // slider's bounds, so fold it back on entry (the layout sites
            // clamp on read as well).
            let g = min(max(guideScale, 0.85), 1.5)
            if g != guideScale { guideScale = g }
            let l = min(max(listScale, 0.85), 1.5)
            if l != listScale { listScale = l }
        }
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            // MARK: Guide Presentation
            Section {
                Toggle(isOn: $showChannelLogos) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Channel Logos")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Turn off to hide channel logos so longer channel names get the full row width.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: showChannelLogos) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }
                Toggle(isOn: $showChannelNumbers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Channel Numbers")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Turn off to hide channel numbers in the Live TV list and Guide.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: showChannelNumbers) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }
                Toggle(isOn: $showChannelNames) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Channel Names")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Turn off to hide channel names in the Live TV list and the Guide's channel column.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: showChannelNames) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }
                Toggle(isOn: $showProgramSubtitles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Program Subtitles")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Turn off to hide the episode or match name under each program title in the Guide and Live TV list, for EPGs that repeat the description there.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: showProgramSubtitles) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }
                Toggle(isOn: $roundedGuideCorners) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rounded Corners in Guide View")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Rounds channel logos in the Guide's channel column.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: roundedGuideCorners) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }
            } header: {
                Text("Guide Presentation").sectionHeaderStyle()
            }
            .listSectionSeparator(.hidden)

            // MARK: List view
            Section {
                Toggle(isOn: $roundedLogoCorners) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rounded Corners in List View")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Rounds channel logos and program artwork in the Live TV list and on the app's cards.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: roundedLogoCorners) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }

                // Phase 3 item 3: one row that pushes the choice page,
                // instead of three inline check rows. The old section
                // footer moved into the picker, which is where it is now
                // read.
                SettingsChoicePicker(
                    "Default Live TV View",
                    options: Self.liveTVViewOptions.map {
                        SettingsChoice($0, liveTVViewLabel($0), icon: liveTVViewIcon($0))
                    },
                    selection: $defaultLiveTVView,
                    footer: "The layout Live TV opens in. Automatic uses List on compact, portrait phones and Guide on regular width (unfolded foldable, iPad, Apple TV). You can still switch anytime with the List / Guide button; that switch lasts for the current session and does not change this default.",
                    icon: "rectangle.grid.1x2"
                )
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("List view").sectionHeaderStyle()
            }
            .listSectionSeparator(.hidden)

            // MARK: Group Selection
            // Logan 2026-09-17: the Default Group picker is gone. The
            // default group is set by LONG PRESSING the group itself, in
            // the tvOS group sidebar or the iOS group pills; Settings does
            // not need a second place to set it. The "defaultChannelGroup"
            // key is untouched.
            //
            // Group Selection is the only row left, and it describes the
            // phone's header drawer vs pill row, so the whole section is
            // phone only again and takes the row's name.
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    SettingsChoicePicker(
                        "Group Selection",
                        options: [
                            SettingsChoice("sidebar", "Sidebar Menu", icon: "sidebar.leading"),
                            SettingsChoice("pills", "Top Group Pills", icon: "capsule.lefthalf.filled")
                        ],
                        selection: $phoneGroupSelector,
                        footer: "How channel groups are picked in Live TV. Sidebar Menu opens a drawer from the header, where a long press also reorders groups. Top Group Pills put the group row at the top instead.",
                        icon: "sidebar.leading"
                    )
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Group Selection").sectionHeaderStyle()
                }
                .listSectionSeparator(.hidden)
            }

            // MARK: Badges
            Section {
                Toggle(isOn: $showEpgBadges) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Program Badges")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("LIVE, NEW, and season/episode pills on the guide")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                if showEpgBadges {
                    // Phase 3 item 4: the five per-kind switches fold into
                    // one master row that reports the count. Storage blob
                    // and bindings are untouched.
                    SettingsSubgroup("Badge Types",
                                     summary: badgesSummary,
                                     icon: "tag",
                                     footer: "Which badges appear. Turning one off hides it everywhere badges are shown.") {
                        ForEach(Self.badgeKinds, id: \.self) { kind in
                            Toggle(isOn: badgeShownBinding(kind)) {
                                Text(Self.badgeTitle(kind))
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                            }
                            .tint(theme.accent)
                            .listRowBackground(Color.cardBackground)
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Badges").sectionHeaderStyle()
            } footer: {
                Text("Show the LIVE, NEW, and season/episode pills on the guide, channel list, and program info. Remembered separately for iPhone/iPad and Apple TV, and synced across your devices of that kind.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)

            // MARK: Display Scale
            Section {
                if UIDevice.current.userInterfaceIdiom != .phone {
                    scaleSliderRow_iOS(title: "Guide", binding: $guideScale)
                }
                scaleSliderRow_iOS(title: "Live TV List", binding: $listScale)
            } header: {
                Text("Display Scale").sectionHeaderStyle()
            } footer: {
                Text(UIDevice.current.userInterfaceIdiom == .phone
                     ? "Independent scale for the Live TV List. 100% matches the default; 85-150% lets you trade density for readability. Changes apply live, no restart needed."
                     : "Independent scale for the Guide grid and the Live TV List. 100% matches the default; 85-150% lets you trade density for readability. Changes apply live, no restart needed."
                )
                .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)

            // MARK: Colors
            Section {
                Toggle(isOn: $enableCategoryColors) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Color Programs by Category")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text(UIDevice.current.userInterfaceIdiom == .phone
                             ? "Unlocks category-based coloring. On iPhone this drives the Tint Channel Cards stripe below."
                             : "Tint guide cells by program type - tap any color below to customize.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: enableCategoryColors) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }

                Toggle(isOn: $tintChannelCards) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tint Channel Cards")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Adds a colored stripe to Live TV channel cards (list view) based on what's currently airing.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .disabled(!enableCategoryColors)
                .opacity(enableCategoryColors ? 1.0 : 0.4)
                .onChange(of: tintChannelCards) { _, _ in
                    SyncManager.shared.pushPreferencesImmediate()
                }

                if UIDevice.current.userInterfaceIdiom == .pad {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)],
                              spacing: 10) {
                        ForEach(CategoryColor.defaultBuckets, id: \.rawValue) { cat in
                            CategoryColorPickerRow(category: cat)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.cardBackground))
                                .disabled(!enableCategoryColors)
                                .opacity(enableCategoryColors ? 1.0 : 0.4)
                        }
                    }
                    .padding(6)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(CategoryColor.defaultBuckets, id: \.rawValue) { cat in
                        CategoryColorPickerRow(category: cat)
                            .listRowBackground(Color.cardBackground)
                            .disabled(!enableCategoryColors)
                            .opacity(enableCategoryColors ? 1.0 : 0.4)
                    }
                }

                NavigationLink {
                    MoreCategoriesView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .scaledFont(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.accent)
                        Text("Add more categories")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Text(moreCategoriesSummary)
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .listRowBackground(Color.cardBackground)
                .disabled(!enableCategoryColors)
                .opacity(enableCategoryColors ? 1.0 : 0.4)

                Button(role: .destructive) {
                    CategoryColor.resetPaletteToDefaults()
                    SyncManager.shared.pushPreferencesImmediate()
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                            .scaledFont(.system(size: 14, weight: .semibold))
                        Text("Reset Colors to Defaults").scaledFont(.bodyMedium)
                    }
                    // Phase 3: same danger color as the DVR Danger Zone.
                    .foregroundColor(.red)
                }
                .listRowBackground(Color.cardBackground)
                .disabled(!enableCategoryColors)
                .opacity(enableCategoryColors ? 1.0 : 0.4)
            } header: {
                Text("Colors").sectionHeaderStyle()
            } footer: {
                Text("Tap a swatch to customize the color used for that program bucket. Kids > Sports > News > Movie priority when a program matches multiple.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        #endif
        // See SettingsView's identically-purposed `.id(...)` - keys the
        // List's identity to the active theme so cell-cache staleness on
        // theme switches doesn't leak accent colors across the rebuild.
        .id("livetv-list-\(theme.selectedTheme.rawValue)-\(theme.useCustomAccent ? theme.customAccentHex : "preset")")
    }

    /// iOS scale-slider row, unchanged from Appearance's Display Scale.
    private func scaleSliderRow_iOS(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int((binding.wrappedValue * 100).rounded()))%")
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
            HStack(spacing: 12) {
                Image(systemName: "textformat.size.smaller")
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .scaledFont(.system(size: 12))
                Slider(value: binding, in: 0.85...1.5, step: 0.05)
                    .tint(theme.accent)
                Image(systemName: "textformat.size.larger")
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .scaledFont(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.cardBackground)
    }
    #endif

    // MARK: - tvOS Body

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // MARK: Guide Presentation
                SettingsSection("Guide Presentation", style: .plain) {
                    TVSettingsToggleRow(
                        icon: "tv.fill",
                        iconColor: .accentPrimary,
                        title: "Show Channel Logos",
                        subtitle: TVListView.enabled
                            ? "Turn off to hide channel logos so longer channel names get the full row width."
                            : "Display each channel's logo in the Guide's channel column.",
                        isOn: $showChannelLogos,
                        onChange: { _ in }
                    )
                    TVSettingsToggleRow(
                        icon: "number",
                        iconColor: .accentPrimary,
                        title: "Show Channel Numbers",
                        subtitle: TVListView.enabled
                            ? "Turn off to hide channel numbers in the Live TV list and Guide."
                            : "Display each channel's number in the Guide's channel column.",
                        isOn: $showChannelNumbers,
                        onChange: { _ in }
                    )
                    TVSettingsToggleRow(
                        icon: "textformat",
                        iconColor: .accentPrimary,
                        title: "Show Channel Names",
                        subtitle: TVListView.enabled
                            ? "Turn off to hide channel names in the Live TV list and the Guide's channel column."
                            : "Turn off to hide channel names in the Guide's channel column.",
                        isOn: $showChannelNames,
                        onChange: { _ in }
                    )
                    TVSettingsToggleRow(
                        icon: "text.alignleft",
                        iconColor: .accentPrimary,
                        title: "Show Program Subtitles",
                        subtitle: TVListView.enabled
                            ? "Turn off to hide the episode or match name under each program title in the Guide and Live TV list, for EPGs that repeat the description there."
                            : "Turn off to hide the episode or match name under each program title in the Guide, for EPGs that repeat the description there.",
                        isOn: $showProgramSubtitles,
                        onChange: { _ in }
                    )
                    TVSettingsToggleRow(
                        icon: "square.grid.3x3",
                        iconColor: .accentPrimary,
                        title: "Rounded Corners in Guide View",
                        subtitle: "Rounds channel logos in the Guide's channel column.",
                        isOn: $roundedGuideCorners,
                        onChange: { _ in SyncManager.shared.pushPreferencesImmediate() }
                    )
                    tvFooter("Turn logos or numbers off to give long channel names more room in the Guide's channel column.")
                }

                // MARK: List view
                // Hidden on Apple TV while the List view is removed from the
                // tvOS UI (Logan 2026-09-16). The code and the persisted keys
                // are untouched, so flipping TVListView.enabled brings the
                // section and the user's stored choice straight back.
                if TVListView.enabled {
                    SettingsSection("List view", style: .plain) {
                        TVSettingsToggleRow(
                            icon: "square.on.square",
                            iconColor: .accentPrimary,
                            title: "Rounded Corners in List View",
                            subtitle: "Rounds channel logos and program artwork in the Live TV list and on the app's cards.",
                            isOn: $roundedLogoCorners,
                            onChange: { _ in SyncManager.shared.pushPreferencesImmediate() }
                        )
                        // Phase 3 item 3: same inline rows, now built by the
                        // shared picker so tvOS and iOS offer one control.
                        SettingsChoicePicker(
                            "Default Live TV View",
                            options: Self.liveTVViewOptions.map {
                                SettingsChoice($0, liveTVViewLabel($0), icon: liveTVViewIcon($0))
                            },
                            selection: $defaultLiveTVView
                        )
                    }
                }

                // MARK: Guide Layout
                SettingsSection("Guide Layout", style: .plain) {
                    TVSettingsSelectionRow(
                        icon: "rectangle.grid.1x2",
                        iconColor: theme.accent,
                        label: "Basic",
                        subtitle: "Full program details in every guide cell",
                        isSelected: liveTVLayout != "preview",
                        action: { liveTVLayout = "basic" }
                    )
                    TVSettingsSelectionRow(
                        icon: "rectangle.topthird.inset.filled",
                        iconColor: theme.accent,
                        label: "Channel Preview",
                        subtitle: "A banner shows the highlighted program; cells keep the title and tags",
                        isSelected: liveTVLayout == "preview",
                        action: { liveTVLayout = "preview" }
                    )
                }

                // MARK: Group Selection
                // Logan 2026-09-17: Default Group removed here too; it is
                // set in Manage Groups. Group Selection is the only row
                // left, so the section takes its name.
                SettingsSection("Group Selection", style: .plain) {
                    // Phase 3 item 3. The tvOS binding stays the remote
                    // store's Bool; only the rows are shared now.
                    SettingsChoicePicker(
                        "Group Selection",
                        options: [
                            SettingsChoice(false, "Top Group Pills"),
                            SettingsChoice(true, "Sidebar Menu")
                        ],
                        selection: $remote.useGroupSidebar,
                        footer: "How channel groups are picked in the guide. Top Group Pills keep the group row above the grid; Sidebar Menu hides that row and opens when you hold Left in the guide (or from whichever button you set to Open sidebar in Remote Control). Only one is active at a time.",
                        icon: "sidebar.left"
                    )
                }

                // MARK: Badges
                SettingsSection("Badges", style: .plain) {
                    TVSettingsToggleRow(
                        icon: "tag",
                        iconColor: theme.accent,
                        title: "Show Program Badges",
                        subtitle: "LIVE, NEW, and season/episode pills on the guide",
                        isOn: $showEpgBadges
                    ) { _ in }

                    if showEpgBadges {
                        // Phase 3 item 4: same five toggles, now under a
                        // master row carrying the same summary string the
                        // phone shows.
                        // Multi-select pop-up on tvOS: the checkmarks are
                        // these toggles, the sheet stays open while they
                        // are flipped, Menu closes it.
                        SettingsSubgroup("Badge Types",
                                         summary: badgesSummary,
                                         icon: "tag",
                                         iconColor: theme.accent,
                                         footer: "Which badges appear. Turning one off hides it everywhere badges are shown.",
                                         optionsOnly: true) {
                            ForEach(Self.badgeKinds, id: \.self) { kind in
                                TVSettingsToggleRow(
                                    icon: "tag",
                                    iconColor: theme.accent,
                                    title: Self.badgeTitle(kind),
                                    subtitle: "",
                                    isOn: badgeShownBinding(kind)
                                ) { _ in }
                            }
                        }
                    }

                    tvFooter("Show the LIVE, NEW, and season/episode pills on the guide, channel list, and program info. Remembered separately for Apple TV and iPhone/iPad, and synced across your Apple TVs.")
                }

                // MARK: Display Scale
                SettingsSection("Display Scale", style: .plain) {
                    scaleSliderRow_tvOS(title: "Guide", binding: $guideScale)
                }

                // MARK: Colors
                SettingsSection("Colors", style: .plain) {
                    TVSettingsToggleRow(
                        icon: "paintpalette.fill",
                        iconColor: .accentPrimary,
                        title: "Color Programs by Category",
                        subtitle: "Tint guide cells by program type. Customize the palette on iPhone or iPad in Settings > Live TV.",
                        isOn: $enableCategoryColors,
                        onChange: { _ in }
                    )
                    TVSettingsToggleRow(
                        icon: "tv.fill",
                        iconColor: .accentPrimary,
                        title: "Tint Channel Cards",
                        subtitle: "Adds a colored gradient to Live TV channel cards based on what's airing now.",
                        isOn: $tintChannelCards,
                        onChange: { _ in }
                    )
                    .disabled(!enableCategoryColors)
                    .opacity(enableCategoryColors ? 1.0 : 0.4)
                }
            }
            .padding(48)
        }
    }

    private func tvFooter(_ text: String) -> some View {
        Text(text)
            .scaledFont(.system(size: 22).subtext())
            .foregroundColor(Color.contrastText(.textTertiary))
            .padding(.horizontal, 20)
            .padding(.top, 4)
    }

    /// tvOS scale-slider row, unchanged from Appearance's Display Scale.
    private func scaleSliderRow_tvOS(title: String, binding: Binding<Double>) -> some View {
        let steps: [Double] = [0.85, 0.92, 1.0, 1.15, 1.25, 1.5]
        let current = steps.min(by: { abs($0 - binding.wrappedValue) < abs($1 - binding.wrappedValue) }) ?? 1.0
        return HStack(spacing: 24) {
            Text(title)
                .scaledFont(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer()
            ForEach(steps, id: \.self) { step in
                // `.rounded()` before the Int cast: 1.15 * 100 is
                // 114.99999999999999 in binary floating point, and a
                // plain truncating cast printed "114%" on the Apple TV
                // (Logan 2026-09-19). Every step is exact after rounding.
                //
                // These used `.buttonStyle(.plain)`, so the focused pill
                // came up as the system's white platter with grey text
                // floating above the row (Logan 2026-09-19). They are now
                // the shared Settings chip: accent fill when selected,
                // accent 2pt ring when focused.
                TVSettingsPill("\(Int((step * 100).rounded()))%",
                               isSelected: step == current) {
                    binding.wrappedValue = step
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
        )
    }
    #endif
}
