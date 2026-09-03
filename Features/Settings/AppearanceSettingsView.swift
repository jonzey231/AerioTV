import SwiftUI

// MARK: - Appearance Settings View (full replacement for the inline one in SettingsView)
struct AppearanceSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    // "Default Landing Tab" and "Default Live TV View" moved to App
    // Behaviors (2026-07 settings unification): they are launch
    // behavior, not appearance, and Android keeps them there.
    /// VOD (Movies / TV Shows) poster-grid scale multiplier. Storage
    /// key retained as `"uiScale"` so existing users' settings carry
    /// forward when we split the single "UI Scale" slider into three
    /// view-specific sliders per #21.
    @AppStorage("uiScale") private var vodScale: Double = 1.0

    /// EPG Guide scale multiplier — already read by `EPGGuideView`
    /// (rowHeight, channelColumnWidth, pixelsPerHour) and by its
    /// `GuideProgramButton` font sizes. Previously had no slider in
    /// Settings; users had to edit UserDefaults by hand.
    @AppStorage("guideScale") private var guideScale: Double = 1.0

    /// Channel-list scale multiplier. New in #21 — read by
    /// `ChannelListView`'s iOS row for font + padding sizes. tvOS
    /// keeps its fixed list metrics because tvOS rows are already
    /// Emby-sized for 10-foot viewing; per user's specification the
    /// list slider is only shown to iPhone / iPad / Mac users.
    @AppStorage("listScale") private var listScale: Double = 1.0

    // MARK: Guide Display state — folded in from the former
    // standalone `Settings → Guide Display` page in v1.6.8. The page
    // shipped two related concerns (category colour palette, channel
    // card tint) that overlapped with Appearance's existing theme +
    // scale section enough that splitting them confused users —
    // they'd flip the master "Color Programs by Category" toggle in
    // Guide Display, then head to Appearance looking for a way to
    // change the palette colour and not find it. Consolidating into
    // one screen keeps every visual customisation in one place. The
    // duplicate guideScale slider that used to live in Guide Display
    // is dropped here — the existing Display Scale section below
    // already exposes it. The EPG Cache "Refresh EPG Data" action
    // also briefly lived on this page after the merge, but moved
    // again in v1.6.8 (later iteration) to per-playlist surfaces in
    // `ServerDetailView` so users can refresh one playlist without
    // nuking every server's cached guide data.
    @AppStorage(CategoryColor.enabledKey) private var enableCategoryColors = true
    @AppStorage("tintChannelCards")       private var tintChannelCards = false
    // Issue #28: hide channel logos so the channel name uses the full row width.
    @AppStorage("ui.showChannelLogos")    private var showChannelLogos = true
    // GH #19 (Android parity): hide channel numbers in the List and Guide.
    @AppStorage("ui.showChannelNumbers")  private var showChannelNumbers = true
    @AppStorage("ui.showChannelNames")    private var showChannelNames = true
    @AppStorage("ui.showProgramSubtitles") private var showProgramSubtitles = true
    @AppStorage(ClockFormat.defaultsKey) private var timeFormat = "system"

    private static let timeFormatOptions: [(value: String, label: String, subtitle: String)] = [
        ("system", "System", "Follow the device's clock setting."),
        ("12", "12-hour", "7:30 PM"),
        ("24", "24-hour", "19:30"),
    ]

    // MARK: - App Behaviors (moved)
    //
    // The "App Behaviors" subsection (Skip Loading Screen, Resume
    // Last Channel) lived inline here from v1.6.13 through v1.7.x.
    // It's now a top-level Settings entry. See
    // `AppBehaviorsSettingsView.swift`. The keys
    // (`appBehaviorsSkipLoadingScreen`,
    // `appBehaviorsAutoResumeLastChannel`) are unchanged so existing
    // users carry their preferences forward without any migration.
    // v1.7.x also added an "Up / Down channel flip" toggle alongside
    // them; that's the reason for the promotion (Appearance was
    // never the right home for d-pad behaviour).

    /// Summary text for the "Add more categories" disclosure row —
    /// shows "Off", "3 extra", "Custom", or "5 extra + Custom" so
    /// the user can see at a glance whether they've enabled
    /// anything beyond the four default buckets.
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
        .navigationTitle("Appearance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    // MARK: - tvOS Body
    // Every row uses one of the shared TVSettings* components so focus
    // highlight (accent-tinted card + stroke + scale bump) matches the
    // rest of the tvOS UI uniformly. Previously rows used only
    // TVNoHighlightButtonStyle without the card background, so focus
    // was almost invisible inside a section.
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // App Behaviors moved to its own top-level Settings
                // entry in v1.7.x. See `AppBehaviorsSettingsView`.

                // Color Theme
                tvAppearanceSection("Color Theme") {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        TVSettingsSelectionRow(
                            label: t.displayName,
                            subtitle: themeSubtitle(t),
                            isSelected: theme.selectedTheme == t,
                            action: { theme.setTheme(t) },
                            leading: {
                                Circle()
                                    .fill(t.accentPrimary)
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.borderMedium, lineWidth: 1))
                            }
                        )
                    }

                    // Appearance mode (Dark / Light / System). No segmented
                    // idiom on the remote, so three selection rows mirroring
                    // the theme rows above. Orthogonal to the theme choice.
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        TVSettingsSelectionRow(
                            label: mode.displayName,
                            subtitle: appearanceModeSubtitle(mode),
                            isSelected: theme.appearanceMode == mode,
                            action: { theme.setAppearanceMode(mode) },
                            leading: {
                                Image(systemName: mode == .dark ? "moon.fill"
                                      : mode == .light ? "sun.max.fill"
                                      : "circle.lefthalf.filled")
                                    .font(.system(size: 24))
                                    .foregroundColor(theme.accent)
                                    .frame(width: 28, height: 28)
                            }
                        )
                    }

                    // Custom accent toggle
                    TVSettingsToggleRow(
                        icon: "paintpalette.fill", iconColor: theme.accent,
                        title: "Custom Accent Color",
                        subtitle: "Override the theme accent with a custom hex color",
                        isOn: $theme.useCustomAccent
                    ) { _ in }

                    if theme.useCustomAccent {
                        HStack {
                            Text("Hex")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("2DD4BF", text: $theme.customAccentHex)
                                .textFieldStyle(.plain)
                                .font(.system(size: 26, design: .monospaced))
                                .foregroundColor(.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 200)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.elevatedBackground)
                                )
                        }
                        .padding(.horizontal, 20)
                    }
                }

                // Liquid Glass
                tvAppearanceSection("Glass Effect") {
                    ForEach(LiquidGlassStyle.allCases, id: \.self) { style in
                        TVSettingsSelectionRow(
                            label: style.displayName,
                            subtitle: liquidGlassDescription(style),
                            isSelected: theme.liquidGlassStyle == style,
                            action: { theme.setLiquidGlassStyle(style) }
                        )
                    }
                }

                // Preview
                tvAppearanceSection("Preview") {
                    swatchPreview
                        .padding(.horizontal, 20)
                }

                // Display Scale — two sliders on tvOS (List view is
                // not used on tvOS; guide grid and VOD posters are).
                tvAppearanceSection("Display Scale") {
                    scaleSliderRow_tvOS(title: "Movies & Series", binding: $vodScale)
                    scaleSliderRow_tvOS(title: "Guide", binding: $guideScale)
                }

                // Time Format: every clock in the app (guide header, cell
                // ranges, program info, search, recordings).
                tvAppearanceSection("Time Format") {
                    ForEach(Self.timeFormatOptions, id: \.value) { option in
                        TVSettingsSelectionRow(
                            icon: "clock",
                            iconColor: .accentPrimary,
                            label: option.label,
                            subtitle: option.subtitle,
                            isSelected: timeFormat == option.value,
                            action: {
                                timeFormat = option.value
                                SyncManager.shared.pushPreferencesImmediate()
                            }
                        )
                    }
                }

                // Channel List (issue #28 logos + GH #19 numbers)
                tvAppearanceSection("Channel List") {
                    TVSettingsToggleRow(
                        icon: "tv.fill",
                        iconColor: .accentPrimary,
                        title: "Show Channel Logos",
                        subtitle: "Turn off to hide channel logos so longer channel names get the full row width.",
                        isOn: $showChannelLogos,
                        onChange: { _ in }
                    )
                    TVSettingsToggleRow(
                        icon: "number",
                        iconColor: .accentPrimary,
                        title: "Show Channel Numbers",
                        subtitle: "Turn off to hide channel numbers in the Live TV list and Guide.",
                        isOn: $showChannelNumbers,
                        onChange: { _ in }
                    )
                    // GH #73 (Android parity).
                    TVSettingsToggleRow(
                        icon: "textformat",
                        iconColor: .accentPrimary,
                        title: "Show Channel Names",
                        subtitle: "Turn off to hide channel names in the Guide's channel column.",
                        isOn: $showChannelNames,
                        onChange: { _ in }
                    )
                    // Tester report (2026-09-02): some EPG feeds repeat the
                    // description in the sub-title line.
                    TVSettingsToggleRow(
                        icon: "text.alignleft",
                        iconColor: .accentPrimary,
                        title: "Show Program Subtitles",
                        subtitle: "Turn off to hide the episode or match name under each program title in the Guide and Live TV list, for EPGs that repeat the description there.",
                        isOn: $showProgramSubtitles,
                        onChange: { _ in }
                    )
                }

                // Category Colors — folded in from the former
                // standalone Guide Display page (v1.6.8). The tvOS
                // page never offered a palette editor (palette
                // tweaks are iPhone / iPad only because they need a
                // colour picker keyboard) so we just expose the
                // master toggle + the channel-card stripe toggle.
                tvAppearanceSection("Category Colors") {
                    TVSettingsToggleRow(
                        icon: "paintpalette.fill",
                        iconColor: .accentPrimary,
                        title: "Color Programs by Category",
                        subtitle: "Tint guide cells by program type. Customise the palette on iPhone / iPad — Settings → Appearance.",
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

    /// tvOS section header + grouped content. Rows inside already supply
    /// their own card background via `tvSettingsCardBG`, so the section
    /// wrapper only provides a section title — no outer card.
    private func tvAppearanceSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textTertiary)
                .tracking(1)
                .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    /// tvOS scale-slider row. Apple TV users don't have a touch
    /// `Slider` equivalent for the remote, so we expose discrete
    /// steps via left/right D-pad buttons, matching the iOS slider's
    /// range (iCloud KVS keeps them in sync when enabled). 150/175%
    /// are the GH #25 readability steps ("even at 125% the guide is
    /// hard to see" from across the room): fewer, larger items.
    private func scaleSliderRow_tvOS(title: String, binding: Binding<Double>) -> some View {
        let steps: [Double] = [0.85, 0.92, 1.0, 1.15, 1.25, 1.5, 1.75]
        // Snap the current value to the nearest known step so the
        // row's selection state stays coherent even if the user
        // edited UserDefaults directly.
        let current = steps.min(by: { abs($0 - binding.wrappedValue) < abs($1 - binding.wrappedValue) }) ?? 1.0
        return HStack(spacing: 24) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer()
            ForEach(steps, id: \.self) { step in
                Button {
                    binding.wrappedValue = step
                } label: {
                    Text("\(Int(step * 100))%")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(step == current ? theme.accent : .textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(step == current
                                      ? theme.accent.opacity(0.18)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
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

    /// One-line palette description per theme, matching the Android
    /// theme picker so the copy reads identically across platforms.
    private func themeSubtitle(_ t: AppTheme) -> String {
        switch t {
        case .aerio:      return "Cyan on deep navy (default)"
        case .midnight:   return "Cool blue on near-black"
        case .sunset:     return "Warm orange on near-black"
        case .forest:     return "Green on near-black"
        case .lavender:   return "Purple on near-black"
        case .monochrome: return "Greyscale on near-black"
        case .light:      return "Neutral teal-grey that reads on white"
        }
    }

    /// One-line description per appearance mode, shown under the
    /// Dark / Light / System selection rows on tvOS.
    private func appearanceModeSubtitle(_ mode: AppearanceMode) -> String {
        switch mode {
        case .dark:   return "Dark surfaces (default)"
        case .light:  return "Light surfaces"
        case .system: return "Follow the system setting"
        }
    }

    // MARK: - iOS Body
    #if os(iOS)
    private var iOSBody: some View {
        List {
                // App Behaviors moved to its own top-level Settings
                // entry in v1.7.x. See `AppBehaviorsSettingsView`.

                // MARK: Color Theme
                Section {
                    // Phase 5 (plan A2 density): iPad shows the themes as a
                    // two-column tile grid; iPhone keeps the stacked rows.
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)],
                                  spacing: 10) {
                            ForEach(AppTheme.allCases, id: \.self) { t in
                                Button {
                                    theme.setTheme(t)
                                } label: {
                                    themeRowLabel(t)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.cardBackground))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // Keep outer tiles clear of the List's section
                        // corner mask, which otherwise re-rounds the last
                        // row's corner tiles (Logan's report: Light tile
                        // corners uneven).
                        .padding(6)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(AppTheme.allCases, id: \.self) { t in
                            Button {
                                theme.setTheme(t)
                            } label: {
                                themeRowLabel(t)
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                    }

                    // iPhone keeps the mode/accent rows in this section
                    // (shipped canon). iPad moves them to their own section
                    // below so the last theme tile ends its own pill
                    // instead of visually fusing with the Appearance card
                    // (Logan's report 2026-08-04).
                    if UIDevice.current.userInterfaceIdiom != .pad {
                        appearanceModeAndAccentRows
                    }
                } header: {
                    Text("Color Theme").sectionHeaderStyle()
                } footer: {
                    if UIDevice.current.userInterfaceIdiom != .pad {
                        Text("Colors used throughout the app.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .listSectionSeparator(.hidden)

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section {
                        appearanceModeAndAccentRows
                    } footer: {
                        Text("Colors used throughout the app.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                    .listSectionSeparator(.hidden)
                }

                // MARK: Liquid Glass
                Section {
                    ForEach(LiquidGlassStyle.allCases, id: \.self) { style in
                        Button {
                            theme.setLiquidGlassStyle(style)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.displayName)
                                        .font(.bodyMedium).foregroundColor(.textPrimary)
                                    Text(liquidGlassDescription(style))
                                        .font(.labelSmall).foregroundColor(.textSecondary)
                                }
                                Spacer()
                                if theme.liquidGlassStyle == style {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("Glass Effect").sectionHeaderStyle()
                } footer: {
                    Text(liquidGlassFootnote)
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)

                // MARK: Preview Swatch
                Section {
                    swatchPreview
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Preview").sectionHeaderStyle()
                }
                .listSectionSeparator(.hidden)

                // MARK: Display Scale — per-view sliders (#21)
                //
                // Split from the previous single "UI Scale" slider
                // (which only affected VOD on iPad/Mac). Each slider
                // governs one view family so users can independently
                // tune poster density, Guide cell text, and channel-
                // list text sizes.
                //
                // iPhone only renders the Guide view on iPad (the
                // Live TV tab always uses List view on a phone — see
                // ChannelListView.swift line ~252 where showGuideView
                // is pinned to false on .phone idiom). Showing the
                // Guide slider on iPhone was cargo-culted from iPad
                // and confused users — feedback pass flagged it as
                // "iPhone shouldn't have a scale slider for Guide
                // view." Pad + Mac Catalyst still get all three.
                Section {
                    scaleSliderRow_iOS(
                        title: "Movies & Series",
                        binding: $vodScale
                    )
                    if UIDevice.current.userInterfaceIdiom != .phone {
                        scaleSliderRow_iOS(
                            title: "Guide",
                            binding: $guideScale
                        )
                    }
                    scaleSliderRow_iOS(
                        title: "Live TV List",
                        binding: $listScale
                    )
                } header: {
                    Text("Display Scale").sectionHeaderStyle()
                } footer: {
                    Text(UIDevice.current.userInterfaceIdiom == .phone
                         ? "Independent scale for Movies & Series and Live TV List. 100% matches the default; 85–125% lets you trade density for readability. Changes apply live — no restart needed."
                         : "Independent scale for Movies & Series, the Guide grid, and the Live TV List. 100% matches the default; 85–125% lets you trade density for readability. Changes apply live — no restart needed."
                    )
                    .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)

                // MARK: Time Format
                Section {
                    ForEach(Self.timeFormatOptions, id: \.value) { option in
                        Button {
                            timeFormat = option.value
                            SyncManager.shared.pushPreferencesImmediate()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.bodyMedium).foregroundColor(.textPrimary)
                                    Text(option.subtitle)
                                        .font(.labelSmall).foregroundColor(.textTertiary)
                                }
                                Spacer()
                                if timeFormat == option.value {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("Time Format").sectionHeaderStyle()
                } footer: {
                    Text("System follows your device's clock setting. Applies to the Guide, program info, search, and recordings.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)

                // MARK: Channel List (issue #28)
                Section {
                    Toggle(isOn: $showChannelLogos) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Channel Logos")
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Turn off to hide channel logos so longer channel names get the full row width.")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                    .onChange(of: showChannelLogos) { _, _ in
                        SyncManager.shared.pushPreferencesImmediate()
                    }
                    // GH #19 (Android parity): hide channel numbers too.
                    Toggle(isOn: $showChannelNumbers) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Channel Numbers")
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Turn off to hide channel numbers in the Live TV list and Guide.")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                    .onChange(of: showChannelNumbers) { _, _ in
                        SyncManager.shared.pushPreferencesImmediate()
                    }
                    // GH #73 (Android parity): hide channel names in the Guide rail.
                    Toggle(isOn: $showChannelNames) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Channel Names")
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Turn off to hide channel names in the Guide's channel column.")
                                .font(.labelSmall).foregroundColor(.textTertiary)
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
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Turn off to hide the episode or match name under each program title in the Guide and Live TV list, for EPGs that repeat the description there.")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                    .onChange(of: showProgramSubtitles) { _, _ in
                        SyncManager.shared.pushPreferencesImmediate()
                    }
                } header: {
                    Text("Channel List").sectionHeaderStyle()
                }
                .listSectionSeparator(.hidden)

                // MARK: Category Colors (formerly Settings → Guide Display)
                //
                // Master toggle + channel-card companion toggle.
                //
                // iPhone's Live TV tab is List-only (Guide view is iPad /
                // Mac / Apple TV). The master toggle still matters on
                // iPhone because it unlocks the "Tint Channel Cards"
                // feature below — but "tint guide cells" was misleading
                // copy that made iPhone testers think nothing happens
                // when they flip it (they looked for a Guide view that
                // doesn't exist). Device-aware text resolves that.
                Section {
                    Toggle(isOn: $enableCategoryColors) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Color Programs by Category")
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                            Text(UIDevice.current.userInterfaceIdiom == .phone
                                 ? "Unlocks category-based coloring. On iPhone this drives the Tint Channel Cards stripe below."
                                 : "Tint guide cells by program type — tap any color below to customise.")
                                .font(.labelSmall).foregroundColor(.textTertiary)
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
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Adds a colored stripe to Live TV channel cards (list view) based on what's currently airing.")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                    .disabled(!enableCategoryColors)
                    .opacity(enableCategoryColors ? 1.0 : 0.4)
                    .onChange(of: tintChannelCards) { _, _ in
                        SyncManager.shared.pushPreferencesImmediate()
                    }
                } header: {
                    Text("Category Colors").sectionHeaderStyle()
                } footer: {
                    Text(UIDevice.current.userInterfaceIdiom == .phone
                         ? "iPhone's Live TV tab only renders the List view. Cards tint with a gradient that fades from the leading edge toward the center — based on the currently-airing program on the main row, and the individual program on each expanded schedule row. Dispatcharr and M3U+XMLTV work out of the box; Xtream Codes doesn't expose category data."
                         : "Programs with a category tag in the EPG source get a leading-edge gradient — on channel cards in the List view (using the currently-airing program), on each row in the expanded schedule (using that program's own category), and on cells in the Guide grid. Dispatcharr and M3U+XMLTV work out of the box; Xtream Codes doesn't expose category data.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)

                // MARK: Palette (formerly Settings → Guide Display)
                //
                // Default palette — the four buckets that have shipped
                // since v1.0. Always visible; the "Add more
                // categories" row below progressively discloses the
                // extra buckets + a Custom editor without cluttering
                // the default Settings view.
                Section {
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
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(theme.accent)
                            Text("Add more categories")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Text(moreCategoriesSummary)
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
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
                                .font(.system(size: 14, weight: .semibold))
                            Text("Reset Colors to Defaults").font(.bodyMedium)
                        }
                        .foregroundColor(.statusWarning)
                    }
                    .listRowBackground(Color.cardBackground)
                    .disabled(!enableCategoryColors)
                    .opacity(enableCategoryColors ? 1.0 : 0.4)
                } header: {
                    Text("Palette").sectionHeaderStyle()
                } footer: {
                    Text("Tap a swatch to customise the color used for that program bucket. Kids > Sports > News > Movie priority when a program matches multiple.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // See SettingsView for rationale — SwiftUI List cells
            // cache their rendered content even when the parent
            // re-renders, leaving accent-derived text colors
            // (.textSecondary, .textTertiary) and section header
            // tints stuck on the previous theme. Keying the List
            // identity to the active theme forces a clean rebuild.
            .id("appearance-list-\(theme.selectedTheme.rawValue)-\(theme.appearanceMode.rawValue)-\(theme.useCustomAccent ? theme.customAccentHex : "preset")")
    }

    /// Appearance mode (Dark / Light / System) + custom accent rows.
    /// One definition, hosted inline in the Color Theme section on
    /// iPhone and in a standalone section on iPad.
    @ViewBuilder
    private var appearanceModeAndAccentRows: some View {
        // Appearance mode — a surface luminance axis orthogonal to the
        // hue/identity themes. Defaults to Dark; selecting a theme never
        // changes the mode, and vice versa.
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance")
                .font(.bodyMedium).foregroundColor(.textPrimary)
            Picker("Appearance", selection: Binding(
                get: { theme.appearanceMode },
                set: { theme.setAppearanceMode($0) }
            )) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: theme.appearanceMode) { _, _ in
                SyncManager.shared.pushPreferencesImmediate()
            }
        }
        .tint(theme.accent)
        .listRowBackground(Color.cardBackground)

        // Custom accent color toggle
        Toggle(isOn: $theme.useCustomAccent) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hex: theme.customAccentHex))
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.borderMedium, lineWidth: 1)
                    )
                Text("Custom Accent Color")
                    .font(.bodyMedium).foregroundColor(.textPrimary)
            }
        }
        .tint(theme.accent)
        .listRowBackground(Color.cardBackground)

        if theme.useCustomAccent {
            // Native system color picker — tap the swatch to open the full picker
            #if os(iOS)
            ColorPicker(
                selection: Binding(
                    get: { Color(hex: theme.customAccentHex) },
                    set: { theme.customAccentHex = $0.toHex() }
                ),
                supportsOpacity: false
            ) {
                Text("Accent Color")
                    .font(.bodyMedium).foregroundColor(.textPrimary)
            }
            .listRowBackground(Color.cardBackground)
            #endif

            // Hex field for power users who want to paste a specific value
            HStack {
                Text("Hex")
                    .font(.bodyMedium).foregroundColor(.textSecondary)
                Spacer()
                TextField("2DD4BF", text: Binding(
                    get: { theme.customAccentHex },
                    set: { newValue in
                        let allowed: Set<Character> = Set("0123456789ABCDEFabcdef")
                        let cleaned = newValue.filter { allowed.contains($0) }.uppercased()
                        theme.customAccentHex = String(cleaned.prefix(6))
                    }
                ))
                    .font(.monoSmall)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    /// The theme row content shared by the iPhone stacked rows and the
    /// iPad tile grid (Phase 5).
    private func themeRowLabel(_ t: AppTheme) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(t.accentPrimary)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.borderMedium, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(t.displayName)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(themeSubtitle(t))
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
            }

            Spacer()

            if theme.selectedTheme == t {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
        }
    }

    /// iOS scale-slider row. Single horizontal HStack shared by the
    /// three sliders in `Display Scale`. Range 85%–125% in 5%
    /// increments mirrors the legacy single-slider UX so users'
    /// tactile "how much do I drag" intuition carries forward.
    private func scaleSliderRow_iOS(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int(binding.wrappedValue * 100))%")
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
            }
            HStack(spacing: 12) {
                Image(systemName: "textformat.size.smaller")
                    .foregroundColor(.textTertiary)
                    .font(.system(size: 12))
                // GH #25: range extended past 125% for TV-across-the-room
                // readability (fewer, larger items at 150%+).
                Slider(value: binding, in: 0.85...1.75, step: 0.05)
                    .tint(theme.accent)
                Image(systemName: "textformat.size.larger")
                    .foregroundColor(.textTertiary)
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.cardBackground)
    }
    #endif

    private var swatchPreview: some View {
        HStack(spacing: 14) {
            // Live accent swatch
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.accent.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: theme.accent.opacity(0.4), radius: 6, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                let themeLabel = theme.useCustomAccent
                    ? "Custom #\(theme.customAccentHex.uppercased())"
                    : theme.selectedTheme.displayName
                Text(themeLabel + " · " + theme.liquidGlassStyle.displayName)
                    .font(.bodyMedium).foregroundColor(.textPrimary)
                Text("Applied across the entire app")
                    .font(.labelSmall).foregroundColor(.textSecondary)
            }

            Spacer()

            // Mini accent gradient pill
            Capsule()
                .fill(LinearGradient(
                    colors: [theme.accent, theme.accentSecondary],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: 48, height: 6)
        }
        .padding(.vertical, 6)
    }

    private func liquidGlassDescription(_ style: LiquidGlassStyle) -> String {
        switch style {
        case .full:     return "Native Apple Liquid Glass (iOS 26+)"
        case .tinted:   return "Frosted glass with accent color tint"
        case .minimal:  return "Subtle ultra-thin material"
        case .disabled: return "Solid card backgrounds, no glass"
        }
    }

    private var liquidGlassFootnote: String {
        if #available(iOS 26.0, *) {
            return "Full Liquid Glass requires iOS 26 or later and is available on this device."
        } else {
            return "Full Liquid Glass requires iOS 26. Tinted glass is used as a fallback."
        }
    }
}
