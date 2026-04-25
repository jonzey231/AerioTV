import SwiftUI

/// Settings → Multiview submenu. Surfaces the three v1.6.8 multiview
/// appearance preferences (audio-focus indicator style, tile padding,
/// tile corner shape). All three are `@AppStorage`-backed so flipping
/// a value while a multiview session is on screen elsewhere updates
/// the rendering live, without requiring a session restart.
struct MultiviewSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared

    /// Audio-focus indicator style. Default `.centerIcon` matches
    /// pre-v1.6.8 behaviour so existing users see no change unless
    /// they explicitly pick a new style.
    @AppStorage(MultiviewAudioFocusStyle.storageKey)
    private var audioFocusStyleRaw: String = MultiviewAudioFocusStyle.centerIcon.rawValue

    /// Padding between tiles — `false` keeps the flush look that's
    /// shipped since multiview launched.
    @AppStorage(multiviewTilePaddingKey)
    private var paddingEnabled: Bool = false

    /// Rounded tile corners — `false` keeps the square-edge default.
    @AppStorage(multiviewTileCornersRoundedKey)
    private var cornersRounded: Bool = false

    private var selectedStyle: MultiviewAudioFocusStyle {
        MultiviewAudioFocusStyle(rawValue: audioFocusStyleRaw) ?? .centerIcon
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
        .navigationTitle("Multiview")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            // MARK: Audio Focus Indicator
            Section {
                ForEach(MultiviewAudioFocusStyle.allCases) { style in
                    Button {
                        audioFocusStyleRaw = style.rawValue
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(style.displayName)
                                    .font(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Text(style.subtitle)
                                    .font(.labelSmall)
                                    .foregroundColor(.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if selectedStyle == style {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.accent)
                                    .padding(.top, 2)
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Audio Focus Indicator").sectionHeaderStyle()
            } footer: {
                Text("Choose how Aerio marks the tile that currently owns audio when watching multiple streams at once.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)

            // MARK: Padding Between Tiles
            Section {
                Toggle(isOn: $paddingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Padding Between Tiles")
                            .font(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Insert a small gap between tiles so each stream stands on its own. Off keeps adjacent tiles meeting flush.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Spacing").sectionHeaderStyle()
            }
            .listSectionSeparator(.hidden)

            // MARK: Tile Corners
            Section {
                Picker("Tile Corners", selection: $cornersRounded) {
                    Text("Square").tag(false)
                    Text("Rounded").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Tile Corners").sectionHeaderStyle()
            } footer: {
                Text("Square keeps the cinema-grid look; rounded softens each tile with a 12pt radius.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // See SettingsView's identically-purposed `.id(...)` — keys
        // the List's identity to the active theme so cell-cache
        // staleness on theme switches doesn't leak teal/accent
        // colours across the rebuild.
        .id("multiview-list-\(theme.selectedTheme.rawValue)-\(theme.useCustomAccent ? theme.customAccentHex : "preset")")
    }
    #endif

    // MARK: - tvOS Body

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Audio Focus Indicator
                tvSection("Audio Focus Indicator") {
                    ForEach(MultiviewAudioFocusStyle.allCases) { style in
                        TVSettingsSelectionRow(
                            label: style.displayName,
                            subtitle: style.subtitle,
                            isSelected: selectedStyle == style,
                            action: { audioFocusStyleRaw = style.rawValue }
                        )
                    }
                }

                // Padding Between Tiles
                tvSection("Spacing") {
                    TVSettingsToggleRow(
                        icon: "rectangle.split.2x1",
                        iconColor: theme.accent,
                        title: "Padding Between Tiles",
                        subtitle: "Insert a small gap between tiles so each stream stands on its own.",
                        isOn: $paddingEnabled,
                        onChange: { _ in }
                    )
                }

                // Tile Corners
                tvSection("Tile Corners") {
                    TVSettingsSelectionRow(
                        icon: "square",
                        iconColor: theme.accent,
                        label: "Square",
                        isSelected: !cornersRounded,
                        action: { cornersRounded = false }
                    )
                    TVSettingsSelectionRow(
                        icon: "square.dashed",
                        iconColor: theme.accent,
                        label: "Rounded",
                        isSelected: cornersRounded,
                        action: { cornersRounded = true }
                    )
                }
            }
            .padding(48)
        }
    }

    private func tvSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
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
    #endif
}
