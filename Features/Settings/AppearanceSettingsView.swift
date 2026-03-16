import SwiftUI

// MARK: - Appearance Settings View (full replacement for the inline one in SettingsView)
struct AppearanceSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue

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
                            Text("Custom Accent Color")
                                .font(.bodyMedium).foregroundColor(.textPrimary)
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)

                    if theme.useCustomAccent {
                        HStack {
                            Text("Hex Color")
                                .font(.bodyMedium).foregroundColor(.textSecondary)
                            Spacer()
                            TextField("#2DD4BF", text: $theme.customAccentHex)
                                .font(.monoSmall)
                                .foregroundColor(.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
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
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    private var swatchPreview: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.selectedTheme.displayName + " · " + theme.liquidGlassStyle.displayName)
                    .font(.bodyMedium).foregroundColor(.textPrimary)
                Text("Accent color preview")
                    .font(.labelSmall).foregroundColor(.textSecondary)
            }
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
