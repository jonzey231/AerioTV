import SwiftUI

// MARK: - Appearance Settings View (full replacement for the inline one in SettingsView)
struct AppearanceSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    @AppStorage("defaultLiveTVView") private var defaultLiveTVView = "guide"
    @AppStorage("pipEnabled") private var pipEnabled = true

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
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Default Tab
                tvAppearanceSection("Default Landing Tab") {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        tvOptionRow(icon: tab.icon, label: tab.title,
                                    isSelected: defaultTabRaw == tab.rawValue) {
                            defaultTabRaw = tab.rawValue
                        }
                    }
                }

                // Default Live TV View
                tvAppearanceSection("Default Live TV View") {
                    ForEach(["list", "guide"], id: \.self) { option in
                        tvOptionRow(icon: option == "list" ? "list.bullet" : "calendar",
                                    label: option == "list" ? "List" : "Guide",
                                    isSelected: defaultLiveTVView == option) {
                            defaultLiveTVView = option
                        }
                    }
                }

                // Color Theme
                tvAppearanceSection("Color Theme") {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        Button { theme.setTheme(t) } label: {
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(t.accentPrimary)
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.borderMedium, lineWidth: 1))
                                Text(t.displayName)
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                if theme.selectedTheme == t {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(TVNoHighlightButtonStyle())
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
                    }
                }

                // Liquid Glass
                tvAppearanceSection("Glass Effect") {
                    ForEach(LiquidGlassStyle.allCases, id: \.self) { style in
                        tvOptionRow(label: style.displayName,
                                    subtitle: liquidGlassDescription(style),
                                    isSelected: theme.liquidGlassStyle == style) {
                            theme.setLiquidGlassStyle(style)
                        }
                    }
                }

                // Preview
                tvAppearanceSection("Preview") {
                    swatchPreview
                }
            }
            .padding(48)
        }
    }

    private func tvAppearanceSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textTertiary)
                .tracking(1)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cardBackground)
            )
        }
    }

    private func tvOptionRow(icon: String? = nil, label: String, subtitle: String? = nil,
                              isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundColor(theme.accent)
                        .frame(width: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 20))
                            .foregroundColor(.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(TVNoHighlightButtonStyle())
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
                            TextField("2DD4BF", text: $theme.customAccentHex)
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

                // MARK: Playback
                Section {
                    Toggle(isOn: $pipEnabled) {
                        HStack(spacing: 10) {
                            Image(systemName: "pip.fill")
                                .font(.system(size: 15))
                                .foregroundColor(theme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Picture-in-Picture")
                                    .font(.bodyMedium).foregroundColor(.textPrimary)
                                Text("Continue watching in a floating window")
                                    .font(.labelSmall).foregroundColor(.textSecondary)
                            }
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)

                } header: {
                    Text("Playback").sectionHeaderStyle()
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
