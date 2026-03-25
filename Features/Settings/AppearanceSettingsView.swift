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
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif

                // MARK: Default Live TV View (iPad & tvOS only — iPhone always uses list)
                #if os(tvOS)
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
                #else
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
                #endif

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
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif

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
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif

                // MARK: Playback
                #if os(iOS)
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
                #endif

                // MARK: Preview Swatch
                Section {
                    swatchPreview
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Preview").sectionHeaderStyle()
                }
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            #else
            .listStyle(.plain)
            #endif
        }
        .navigationTitle("Appearance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
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
