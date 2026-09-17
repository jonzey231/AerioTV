import SwiftUI

// MARK: - Appearance Settings View (full replacement for the inline one in SettingsView)
struct AppearanceSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    // Phase 1 regroup (2026-09-17): Appearance is now theme, text and
    // clock only. Channel List / Guide Presentation, Category Colors, the
    // palette editor and the Guide + Live TV List scale sliders moved to
    // Live TV; the Movies & Series slider moved to Movies & TV Shows.
    /// App-wide text multiplier (Settings > Appearance > Text Size).
    /// Read by every `.scaledFont` call site via the root environment;
    /// synced across devices. See `TextScale` in Typography.swift.
    @AppStorage(TextScale.key) private var textScale: Double = TextScale.defaultValue
    /// Secondary-text multiplier (Settings > Appearance > Subtext Size),
    /// stacked on Text Size for fonts marked `.subtext()`. Synced.
    @AppStorage(SubtextScale.key) private var subtextScale: Double = SubtextScale.defaultValue

    @AppStorage(ClockFormat.defaultsKey) private var timeFormat = "system"

    #if os(iOS)
    /// Measured width of this page, used to pick the Color Theme layout.
    /// The two-column tile grid needs real room: in a narrow Slide Over
    /// (about 400 pt) the tiles are so narrow that theme names break
    /// mid-word ("AerioT/V", "Monochro/me"), so the page falls back to
    /// the stacked single-column rows. Measured, not inferred from the
    /// size class, because an iPad Slide Over and an iPad Split View pane
    /// report the same compact class at very different widths.
    ///
    /// Written only from onAppear/onChange (never during body
    /// evaluation), and it feeds a layout CHOICE rather than a sibling's
    /// padding, so there is no measure-then-resize loop.
    @State private var pageWidth: CGFloat = 0
    /// Below this the theme tiles cannot hold their longest name.
    private static let themeGridMinWidth: CGFloat = 500
    private var useThemeTileGrid: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && pageWidth >= Self.themeGridMinWidth
    }
    #endif

    private static let timeFormatOptions: [(value: String, label: String, subtitle: String)] = [
        ("system", "System", "Follow the device's clock setting."),
        ("12", "12-hour", "7:30 PM"),
        ("24", "24-hour", "19:30"),
    ]

    // MARK: - Phase 3 shared option lists
    // One list per question, used by both platforms, so iOS and tvOS
    // cannot drift apart on titles, subtitles or order again.

    private static var timeFormatChoices: [SettingsChoice<String>] {
        timeFormatOptions.map { SettingsChoice($0.value, $0.label, subtitle: $0.subtitle, icon: "clock") }
    }

    private static let timeFormatFootnote = "System follows your device's clock setting. Applies to the Guide, program info, search, and recordings."

    private var appearanceModeChoices: [SettingsChoice<AppearanceMode>] {
        AppearanceMode.allCases.map { mode in
            SettingsChoice(mode, mode.displayName,
                           subtitle: appearanceModeSubtitle(mode),
                           icon: mode == .dark ? "moon.fill"
                                 : mode == .light ? "sun.max.fill"
                                 : "circle.lefthalf.filled")
        }
    }

    /// Writes through `ThemeManager` (never a raw property assignment)
    /// and keeps the immediate preference push the segmented control
    /// used to do from `.onChange`.
    private var appearanceModeSelection: Binding<AppearanceMode> {
        Binding(
            get: { theme.appearanceMode },
            set: { theme.setAppearanceMode($0) }
        )
    }

    private var liquidGlassChoices: [SettingsChoice<LiquidGlassStyle>] {
        LiquidGlassStyle.allCases.map {
            SettingsChoice($0, $0.displayName, subtitle: liquidGlassDescription($0))
        }
    }

    private var liquidGlassSelection: Binding<LiquidGlassStyle> {
        Binding(
            get: { theme.liquidGlassStyle },
            set: { theme.setLiquidGlassStyle($0) }
        )
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

                    // Appearance mode (Dark / Light / System). Phase 3:
                    // the shared picker, which stays inline on tvOS and
                    // mirrors the theme rows above. Orthogonal to the
                    // theme choice.
                    SettingsChoicePicker("Appearance",
                                         options: appearanceModeChoices,
                                         selection: appearanceModeSelection,
                                         onChange: { _ in
                                             SyncManager.shared.pushPreferencesImmediate()
                                         })

                    // Custom accent toggle
                    TVSettingsToggleRow(
                        icon: "paintpalette.fill", iconColor: theme.accent,
                        title: "Custom Accent Color",
                        subtitle: "Override the theme accent with a custom hex color",
                        isOn: $theme.useCustomAccent
                    ) { _ in }

                    if theme.useCustomAccent {
                        // Phase 3: the shared Settings field replaces the
                        // hand-styled trailing box, so the hex entry gets
                        // the same label, helper line and focus outline
                        // as every other field in Settings.
                        SettingsTextField("Hex Color",
                                          placeholder: "2DD4BF",
                                          text: $theme.customAccentHex,
                                          helper: "Six hex digits, for example 2DD4BF.",
                                          autocapitalization: .characters)
                            .padding(.horizontal, 20)
                    }
                }

                // Liquid Glass
                tvAppearanceSection("Glass Effect") {
                    // Phase 3: shared picker, inline on tvOS.
                    SettingsChoicePicker("Glass Effect",
                                         options: liquidGlassChoices,
                                         selection: liquidGlassSelection)
                }

                // Preview
                tvAppearanceSection("Preview") {
                    swatchPreview
                        .padding(.horizontal, 20)
                }

                // Text Size: scales every piece of text in the app.
                tvAppearanceSection("Text Size") {
                    textSizeRow_tvOS
                }

                // Subtext Size: secondary text only, on top of Text Size.
                tvAppearanceSection("Subtext Size") {
                    subtextSizeRow_tvOS
                }

                // Text Contrast: dimmed and accent text toward white/black.
                tvAppearanceSection("Text Contrast") {
                    textContrastRow_tvOS
                }

                // Time Format: every clock in the app (guide header, cell
                // ranges, program info, search, recordings).
                tvAppearanceSection("Time Format") {
                    // Phase 3: shared picker; the push moves onto the
                    // picker's onChange so the write and its side effect
                    // stay in one place.
                    SettingsChoicePicker("Time Format",
                                         options: Self.timeFormatChoices,
                                         selection: $timeFormat,
                                         footer: Self.timeFormatFootnote,
                                         icon: "clock",
                                         onChange: { _ in
                                             SyncManager.shared.pushPreferencesImmediate()
                                         })
                }

            }
            .padding(48)
        }
    }

    /// tvOS section header + grouped content. Rows inside already supply
    /// their own card background via `tvSettingsCardBG`, so the section
    /// wrapper only provides a section title — no outer card.
    private func tvAppearanceSection(_ title: String,
                                     footer: String? = nil,
                                     @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .scaledFont(.system(size: 22, weight: .bold))
                .foregroundColor(Color.contrastText(.textTertiary))
                .tracking(1)
                .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            if let footer, !footer.isEmpty {
                Text(footer)
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .padding(.leading, 20)
                    .padding(.trailing, 40)
            }
        }
    }

    /// tvOS Subtext Size row: same stepper layout as Text Size.
    private var subtextSizeRow_tvOS: some View {
        let steps = SubtextScale.steps
        let current = SubtextScale.clamp(subtextScale)
        let index = steps.firstIndex(where: { abs($0 - current) < 0.001 }) ?? 3
        let defaultIndex = steps.firstIndex(where: { abs($0 - SubtextScale.defaultValue) < 0.001 }) ?? 3
        return tvPercentStepperRow(
            title: "Subtext Size",
            percent: Int((current * 100).rounded()),
            isDefault: index == defaultIndex,
            decreaseLabel: "Smaller Subtext",
            increaseLabel: "Larger Subtext",
            decrease: { setSubtextScale(steps[max(0, index - 1)]) },
            increase: { setSubtextScale(steps[min(steps.count - 1, index + 1)]) },
            reset: { setSubtextScale(SubtextScale.defaultValue) }
        )
    }

    /// tvOS Text Contrast row: 0% to 100% in 10% steps.
    private var textContrastRow_tvOS: some View {
        let steps = TextContrast.steps
        let current = TextContrast.clamp(theme.textContrast)
        let index = steps.firstIndex(where: { abs($0 - current) < 0.001 }) ?? 0
        let apply: (Double) -> Void = { value in
            theme.setTextContrast(value)
            SyncManager.shared.pushPreferences()
        }
        return tvPercentStepperRow(
            title: "Text Contrast",
            percent: Int((current * 100).rounded()),
            isDefault: index == 0,
            decreaseLabel: "Less Contrast",
            increaseLabel: "More Contrast",
            decrease: { apply(steps[max(0, index - 1)]) },
            increase: { apply(steps[min(steps.count - 1, index + 1)]) },
            reset: { apply(TextContrast.defaultValue) }
        )
    }

    /// Shared tvOS minus / percent / plus / Reset row (TVSteppedSegmentStyle).
    private func tvPercentStepperRow(
        title: String,
        percent: Int,
        isDefault: Bool,
        decreaseLabel: String,
        increaseLabel: String,
        decrease: @escaping () -> Void,
        increase: @escaping () -> Void,
        reset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 24) {
            Text(title)
                .scaledFont(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
            Spacer()
            Button(action: decrease) {
                Image(systemName: "minus")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(minWidth: 28)
            }
            .buttonStyle(TVSteppedSegmentStyle(isSelected: false))
            .accessibilityLabel(decreaseLabel)

            Text("\(percent)%")
                .scaledFont(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundColor(Color.contrastText(theme.accent))
                .lineLimit(1)
                .frame(minWidth: 96)

            Button(action: increase) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(minWidth: 28)
            }
            .buttonStyle(TVSteppedSegmentStyle(isSelected: false))
            .accessibilityLabel(increaseLabel)

            Button(action: reset) {
                Text("Reset")
                    .scaledFont(.system(size: 22, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(TVSteppedSegmentStyle(isSelected: isDefault))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
        )
    }

    /// tvOS Text Size row. Fourteen 5% steps do not fit as chips, so the
    /// row is a stepper: a minus and a plus capsule (the shared
    /// `TVSteppedSegmentStyle`: accent ring when focused, never selected)
    /// around the live percent. Left/Right move focus between the two
    /// buttons; Select steps the value.
    private var textSizeRow_tvOS: some View {
        let current = TextScale.clamp(textScale)
        let index = TextScale.steps.firstIndex(where: { abs($0 - current) < 0.001 }) ?? 3
        return HStack(spacing: 24) {
            Text("Text Size")
                .scaledFont(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
            Spacer()
            Button {
                setTextScale(TextScale.steps[max(0, index - 1)])
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(minWidth: 28)
            }
            .buttonStyle(TVSteppedSegmentStyle(isSelected: false))
            .accessibilityLabel("Smaller Text")

            Text("\(Int((current * 100).rounded()))%")
                .scaledFont(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundColor(Color.contrastText(theme.accent))
                .lineLimit(1)
                .frame(minWidth: 96)

            Button {
                setTextScale(TextScale.steps[min(TextScale.steps.count - 1, index + 1)])
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(minWidth: 28)
            }
            .buttonStyle(TVSteppedSegmentStyle(isSelected: false))
            .accessibilityLabel("Larger Text")

            Button {
                setTextScale(TextScale.defaultValue)
            } label: {
                Text("Reset")
                    .scaledFont(.system(size: 22, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(TVSteppedSegmentStyle(isSelected: index == 3))
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
                // MARK: Color Theme
                Section {
                    // Phase 5 (plan A2 density): a wide iPad page shows the
                    // themes as a two-column tile grid; iPhone and any
                    // narrow page (Slide Over) keep the stacked rows.
                    if useThemeTileGrid {
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
                    if !useThemeTileGrid {
                        appearanceModeAndAccentRows
                    }
                } header: {
                    Text("Color Theme").sectionHeaderStyle()
                } footer: {
                    if !useThemeTileGrid {
                        Text("Colors used throughout the app.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .listSectionSeparator(.hidden)

                if useThemeTileGrid {
                    Section {
                        appearanceModeAndAccentRows
                    } footer: {
                        Text("Colors used throughout the app.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                    .listSectionSeparator(.hidden)
                }

                // MARK: Liquid Glass
                Section {
                    // Phase 3: four inline check rows collapse to one row
                    // that pushes the choice page, carrying the footnote.
                    SettingsChoicePicker("Glass Effect",
                                         options: liquidGlassChoices,
                                         selection: liquidGlassSelection,
                                         footer: liquidGlassFootnote)
                        .listRowBackground(Color.cardBackground)
                }
                // Phase 3: no Section header. The picker row already says
                // "Glass Effect"; a header repeating it read as two labels
                // for one control.
                .listSectionSeparator(.hidden)

                // MARK: Preview Swatch
                Section {
                    swatchPreview
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Preview").sectionHeaderStyle()
                }
                .listSectionSeparator(.hidden)

                // MARK: Text Size (app-wide text multiplier)
                Section {
                    textSizeRow_iOS
                } header: {
                    Text("Text Size").sectionHeaderStyle()
                } footer: {
                    Text("Scales all text in the app, from 85% to 150%. Applies live and syncs to your other devices.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }

                // MARK: Subtext Size (secondary text multiplier)
                Section {
                    percentSliderRow_iOS(
                        title: "Subtext Size",
                        value: SubtextScale.clamp(subtextScale),
                        range: SubtextScale.range,
                        step: SubtextScale.step,
                        smallerGlyph: "textformat.size.smaller",
                        largerGlyph: "textformat.size.larger",
                        set: setSubtextScale
                    )
                } header: {
                    Text("Subtext Size").sectionHeaderStyle()
                } footer: {
                    Text("Scales descriptions, subtitles, metadata and timestamps on top of Text Size, from 85% to 150%. Titles and buttons stay the same.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }

                // MARK: Text Contrast (dimmed + accent text toward white/black)
                Section {
                    percentSliderRow_iOS(
                        title: "Text Contrast",
                        value: TextContrast.clamp(theme.textContrast),
                        range: TextContrast.range,
                        step: TextContrast.step,
                        smallerGlyph: "circle.lefthalf.filled",
                        largerGlyph: "circle.fill",
                        set: { theme.setTextContrast($0); SyncManager.shared.pushPreferences() }
                    )
                } header: {
                    Text("Text Contrast").sectionHeaderStyle()
                } footer: {
                    Text("Makes dimmed and accent-colored text brighter in dark mode and darker in light mode. 0% keeps the theme colors, 100% uses plain white or black.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)

                // MARK: Time Format
                Section {
                    // Phase 3: one row that pushes the choice page; the
                    // Section footer moved onto the picker.
                    SettingsChoicePicker("Time Format",
                                         options: Self.timeFormatChoices,
                                         selection: $timeFormat,
                                         footer: Self.timeFormatFootnote,
                                         icon: "clock",
                                         onChange: { _ in
                                             SyncManager.shared.pushPreferencesImmediate()
                                         })
                        .listRowBackground(Color.cardBackground)
                }
                // Phase 3: no Section header, for the same reason as
                // Glass Effect above.
                .listSectionSeparator(.hidden)

            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { pageWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in pageWidth = width }
                }
            }
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
        // Phase 3: the segmented control becomes the shared picker row,
        // so Appearance asks its question the same way as every other
        // one-of-N setting (and the same way as tvOS and Android).
        SettingsChoicePicker("Appearance",
                             options: appearanceModeChoices,
                             selection: appearanceModeSelection,
                             onChange: { _ in
                                 SyncManager.shared.pushPreferencesImmediate()
                             })
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
                    .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
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
                    .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
            }
            .listRowBackground(Color.cardBackground)
            #endif

            // Hex field for power users who want to paste a specific
            // value. Phase 3: the shared Settings field; the filtering
            // and uppercasing binding is unchanged.
            SettingsTextField("Hex Color",
                              placeholder: "2DD4BF",
                              text: Binding(
                                get: { theme.customAccentHex },
                                set: { newValue in
                                    let allowed: Set<Character> = Set("0123456789ABCDEFabcdef")
                                    let cleaned = newValue.filter { allowed.contains($0) }.uppercased()
                                    theme.customAccentHex = String(cleaned.prefix(6))
                                }
                              ),
                              helper: "Six hex digits, for example 2DD4BF.",
                              autocapitalization: .characters)
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
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(themeSubtitle(t))
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }

            Spacer()

            if theme.selectedTheme == t {
                Image(systemName: "checkmark")
                    .scaledFont(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
        }
    }

    /// iOS Text Size row: 85% to 150% in 5% steps, live percent readout.
    private var textSizeRow_iOS: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Text Size")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int((TextScale.clamp(textScale) * 100).rounded()))%")
                    .scaledFont(.labelSmall.monospacedDigit().subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
            HStack(spacing: 12) {
                // Glyphs stay fixed so the slider's ends do not shift
                // while the user drags.
                Image(systemName: "textformat.size.smaller")
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 12))
                Slider(
                    value: Binding(
                        get: { TextScale.clamp(textScale) },
                        set: { setTextScale($0) }
                    ),
                    in: TextScale.range,
                    step: TextScale.step
                )
                .tint(theme.accent)
                Image(systemName: "textformat.size.larger")
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.cardBackground)
    }

    /// iOS percent slider row shared by Subtext Size and Text Contrast.
    private func percentSliderRow_iOS(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        smallerGlyph: String,
        largerGlyph: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .scaledFont(.labelSmall.monospacedDigit())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
            HStack(spacing: 12) {
                Image(systemName: smallerGlyph)
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 12))
                Slider(
                    value: Binding(get: { value }, set: { set($0) }),
                    in: range,
                    step: step
                )
                .tint(theme.accent)
                Image(systemName: largerGlyph)
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.cardBackground)
    }

    #endif

    private func setSubtextScale(_ value: Double) {
        let snapped = SubtextScale.clamp(value)
        guard abs(snapped - subtextScale) > 0.0001 else { return }
        subtextScale = snapped
        SyncManager.shared.pushPreferences()
    }

    private func setTextScale(_ value: Double) {
        let snapped = TextScale.clamp(value)
        guard abs(snapped - textScale) > 0.0001 else { return }
        textScale = snapped
        SyncManager.shared.pushPreferences()
    }

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
                    .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                Text("Applied across the entire app")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textSecondary))
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
