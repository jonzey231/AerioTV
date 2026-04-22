import SwiftUI

// MARK: - Appearance Settings View (full replacement for the inline one in SettingsView)
struct AppearanceSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    @AppStorage("defaultLiveTVView") private var defaultLiveTVView = "guide"
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
                // Default Tab
                tvAppearanceSection("Default Landing Tab") {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        TVSettingsSelectionRow(
                            icon: tab.icon,
                            iconColor: theme.accent,
                            label: tab.title,
                            isSelected: defaultTabRaw == tab.rawValue,
                            action: { defaultTabRaw = tab.rawValue }
                        )
                    }
                }

                // Default Live TV View
                tvAppearanceSection("Default Live TV View") {
                    ForEach(["list", "guide"], id: \.self) { option in
                        TVSettingsSelectionRow(
                            icon: option == "list" ? "list.bullet" : "calendar",
                            iconColor: theme.accent,
                            label: option == "list" ? "List" : "Guide",
                            isSelected: defaultLiveTVView == option,
                            action: { defaultLiveTVView = option }
                        )
                    }
                }

                // Color Theme
                tvAppearanceSection("Color Theme") {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        TVSettingsSelectionRow(
                            label: t.displayName,
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

                // Display Scale — two sliders on tvOS (List view is
                // not used on tvOS; guide grid and VOD posters are).
                tvAppearanceSection("Display Scale") {
                    scaleSliderRow_tvOS(title: "Movies & Series", binding: $vodScale)
                    scaleSliderRow_tvOS(title: "Guide", binding: $guideScale)
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
    /// `Slider` equivalent for the remote, so we expose five
    /// discrete steps via left/right D-pad buttons. 85 / 92 / 100 /
    /// 115 / 125% matches the iOS slider's range and keeps the user
    /// in sync across platforms via iCloud KVS when enabled.
    private func scaleSliderRow_tvOS(title: String, binding: Binding<Double>) -> some View {
        let steps: [Double] = [0.85, 0.92, 1.0, 1.15, 1.25]
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

    // MARK: - iOS Body
    #if os(iOS)
    private var iOSBody: some View {
        List {
                // MARK: Default Tab
                Section {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        Button {
                            defaultTabRaw = tab.rawValue
                        } label: {
                            HStack {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 15))
                                    .foregroundColor(theme.accent)
                                    .frame(width: 24)
                                Text(tab.title)
                                    .font(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                if defaultTabRaw == tab.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("Default Landing Tab").sectionHeaderStyle()
                } footer: {
                    Text("The tab shown when the app first launches.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)

                // MARK: Default Live TV View (iPad only — iPhone always uses list)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section {
                        ForEach(["list", "guide"], id: \.self) { option in
                            Button {
                                defaultLiveTVView = option
                            } label: {
                                HStack {
                                    Image(systemName: option == "list" ? "list.bullet" : "calendar")
                                        .font(.system(size: 15))
                                        .foregroundColor(theme.accent)
                                        .frame(width: 24)
                                    Text(option == "list" ? "List" : "Guide")
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    Spacer()
                                    if defaultLiveTVView == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(theme.accent)
                                    }
                                }
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                    } header: {
                        Text("Default Live TV View").sectionHeaderStyle()
                    } footer: {
                        Text("The layout shown when you open the Live TV tab.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                    .listSectionSeparator(.hidden)
                }

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

                // MARK: Color Theme
                Section {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        Button {
                            theme.setTheme(t)
                        } label: {
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(t.accentPrimary)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.borderMedium, lineWidth: 1))

                                Text(t.displayName)
                                    .font(.bodyMedium)
                                    .foregroundColor(.textPrimary)

                                Spacer()

                                if theme.selectedTheme == t {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }

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

                } header: {
                    Text("Color Theme").sectionHeaderStyle()
                } footer: {
                    Text("Colors used throughout the app.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)

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
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
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
                Slider(value: binding, in: 0.85...1.25, step: 0.05)
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
