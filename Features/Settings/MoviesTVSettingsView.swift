//
//  MoviesTVSettingsView.swift
//  Aerio
//
//  Settings redesign Phase 1 (regroup, 2026-09-17). The on-demand page:
//  how often the library re-sweeps, the TMDB poster fallback, and the
//  poster-grid scale. All three rows moved here from App Behaviors and
//  Appearance with their copy and their persisted keys unchanged.
//

import SwiftUI

struct MoviesTVSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared

    /// How often a launch re-sweeps the Movies and TV Shows libraries.
    @AppStorage(VODStore.refreshHoursKey)
    private var vodRefreshHours = 24
    private static let vodRefreshChoices: [(hours: Int, title: String)] = [
        (0, "Every Launch"), (24, "Daily"), (168, "Weekly")
    ]
    /// Shared explanation for the refresh choices, on both platforms.
    private static let vodRefreshFootnote = "Live TV channels refresh on every launch. Movies and TV Shows open from the saved library and re-sweep the provider on this schedule. Pull down on either tab to refresh right away."
    /// Phase 3: one option list for both platforms. The subtitles used
    /// to be tvOS-only; folding them into the shared choices means the
    /// iOS choice page finally explains what each interval does too.
    private static var vodRefreshOptions: [SettingsChoice<Int>] {
        vodRefreshChoices.map { choice in
            SettingsChoice(
                choice.hours,
                choice.title,
                subtitle: choice.hours == 0
                    ? "Re-sweep the provider library on every launch"
                    : "Open from the saved library; re-sweep the provider \(choice.hours == 24 ? "once a day" : "once a week")",
                icon: choice.hours == 0 ? "arrow.clockwise" : "calendar"
            )
        }
    }

    /// Master toggle for the TMDB-by-title poster fallback.
    @AppStorage(TMDBPosters.enabledDefaultsKey)
    private var tmdbPostersEnabled = false
    /// Editable draft of the API key; loaded from / saved to the
    /// Keychain (never persisted in @AppStorage).
    @State private var tmdbKeyDraft = ""
    @State private var tmdbTestState: TMDBKeyTestState = .idle

    enum TMDBKeyTestState: Equatable { case idle, testing, valid, invalid, saved }

    /// VOD (Movies / TV Shows) poster-grid scale multiplier. Storage key
    /// retained as `"uiScale"`.
    @AppStorage("uiScale") private var vodScale: Double = 1.0

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("Movies & TV Shows")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .onAppear {
            tmdbKeyDraft = TMDBPosters.loadAPIKey()
            // Logan 2026-09-18: the range is 85-125% on every platform now.
            // Anyone who saved 150% or 175% under the old range would get a
            // slider value outside its bounds, so fold it back on entry.
            let bounded = min(max(vodScale, 0.85), 1.5)
            if bounded != vodScale { vodScale = bounded }
        }
    }

    // MARK: - TMDB key actions

    @MainActor
    private func testTMDBKey() async {
        let key = tmdbKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { tmdbTestState = .invalid; return }
        tmdbTestState = .testing
        let ok = await TMDBService.validateKey(key)
        tmdbTestState = ok ? .valid : .invalid
    }

    private func saveTMDBKey() {
        TMDBPosters.saveAPIKey(tmdbKeyDraft)
        TMDBService.clearCache()
        tmdbTestState = .saved
    }

    @ViewBuilder
    private var tmdbStatusView: some View {
        switch tmdbTestState {
        case .idle, .testing:
            EmptyView()
        case .valid:
            Label("Valid key", systemImage: "checkmark.circle.fill")
                .scaledFont(.labelSmall).foregroundColor(.green)
        case .invalid:
            Label("Invalid key", systemImage: "xmark.circle.fill")
                .scaledFont(.labelSmall).foregroundColor(.red)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .scaledFont(.labelSmall).foregroundColor(.green)
        }
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            // MARK: Refresh Library
            Section {
                // Phase 3: the inline check list became one row that
                // pushes the choice page; its footer moved onto the
                // picker, so the Section footer would only repeat it.
                SettingsChoicePicker("Refresh Library",
                                     options: Self.vodRefreshOptions,
                                     selection: $vodRefreshHours,
                                     footer: Self.vodRefreshFootnote,
                                     icon: "arrow.clockwise")
                    .listRowBackground(Color.cardBackground)
            }
            // Phase 3: no Section header. The picker row already says
            // "Refresh Library".
            .listSectionSeparator(.hidden)

            // MARK: Posters
            Section {
                Toggle(isOn: $tmdbPostersEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fetch Posters from TMDB")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Fill in program artwork your provider doesn't supply, using The Movie Database.")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                if tmdbPostersEnabled {
                    // Phase 3: one shared field for both platforms. It
                    // owns the reveal eye, so the ad-hoc eye button and
                    // its visibility state are gone.
                    SettingsTextField("TMDB API Key",
                                      placeholder: "API Key or Read Access Token",
                                      text: $tmdbKeyDraft,
                                      isSecure: true)
                        .onChange(of: tmdbKeyDraft) { _, _ in tmdbTestState = .idle }
                        .listRowBackground(Color.cardBackground)

                    HStack(spacing: 12) {
                        Button {
                            Task { await testTMDBKey() }
                        } label: {
                            HStack(spacing: 6) {
                                if tmdbTestState == .testing {
                                    ProgressView().controlSize(.small)
                                }
                                Text("Test")
                            }
                        }
                        .buttonStyle(SettingsGhostButtonStyle(accent: theme.accent))
                        .disabled(tmdbKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                  || tmdbTestState == .testing)

                        tmdbStatusView

                        Spacer()

                        Button("Save") { saveTMDBKey() }
                            .buttonStyle(SettingsPrimaryButtonStyle(accent: theme.accent))
                            .disabled(tmdbTestState == .testing)
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Posters").sectionHeaderStyle()
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("If iCloud Sync is enabled, your key is saved to your iCloud Keychain and syncs to your other devices. Get a free key at themoviedb.org under Settings, then API; paste either the API Key or the Read Access Token. With a key, artwork and details for Movies and TV Shows come from TMDB first and your provider fills any gaps.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    TMDBAttributionView(style: .short)
                }
            }
            .listSectionSeparator(.hidden)

            // MARK: Display Scale
            // iPad / Mac only (Logan 2026-09-18): the phone grids use fixed
            // column counts and ignore `uiScale` entirely, so the slider did
            // nothing there. The row is hidden, not deleted, until the phone
            // layouts read the scale.
            if UIDevice.current.userInterfaceIdiom != .phone {
                Section {
                    scaleSliderRow_iOS(title: "Movies & Series", binding: $vodScale)
                } header: {
                    Text("Display Scale").sectionHeaderStyle()
                } footer: {
                    Text("Independent scale for Movies & Series. 100% matches the default; 85-150% lets you trade density for readability. Changes apply live, no restart needed.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        #endif
    }

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
                // Phase 3 item 6 (Logan 2026-09-19): this page was the only
                // tvOS Settings page using `.card` sections, so its headers
                // rendered as large white Title text and its rows sat
                // inside an outer card while each row already draws its own
                // card (card in card). `.plain` is what Live TV, Appearance,
                // DVR and Developer use: small uppercase eyebrow header,
                // bare content column.
                SettingsSection("Refresh Library", style: .plain) {
                    // Phase 3: same options and copy as iOS, still inline
                    // here because a push costs an extra Back press.
                    SettingsChoicePicker("Refresh Library",
                                         options: Self.vodRefreshOptions,
                                         selection: $vodRefreshHours,
                                         footer: Self.vodRefreshFootnote,
                                         icon: "arrow.clockwise")
                }

                SettingsSection("Posters", style: .plain) {
                    TVSettingsToggleRow(
                        icon: "photo.on.rectangle.angled",
                        iconColor: theme.accent,
                        title: "Fetch Posters from TMDB",
                        subtitle: "Fill in program artwork your provider doesn't supply, using The Movie Database.",
                        isOn: $tmdbPostersEnabled
                    ) { _ in }

                    if tmdbPostersEnabled {
                        // Phase 3: the same shared field the iOS page
                        // uses. It stays MASKED unless the user toggles the
                        // eye, focused or not (security fix 2026-09-19).
                        SettingsTextField("TMDB API Key",
                                          placeholder: "API Key or Read Access Token",
                                          text: $tmdbKeyDraft,
                                          isSecure: true)
                            .onChange(of: tmdbKeyDraft) { _, _ in tmdbTestState = .idle }
                            .padding(.horizontal, 20)

                        // Phase 3 item 7: Save is the accent-filled primary
                        // and Test the ghost, same pair the iPhone shows.
                        HStack(spacing: 24) {
                            // Not gated on an empty key: on tvOS the field only
                            // commits its text when focus LEAVES it, and the
                            // focus engine can't move onto a disabled button.
                            TVCompactButton(
                                title: tmdbTestState == .testing ? "Testing…" : "Test",
                                role: .ghost,
                                disabled: tmdbTestState == .testing
                            ) { Task { await testTMDBKey() } }

                            TVCompactButton(
                                title: "Save",
                                role: .primary,
                                disabled: tmdbTestState == .testing
                            ) { saveTMDBKey() }

                            tmdbStatusView
                            Spacer()
                        }
                        .padding(.horizontal, 20)

                        Text("If iCloud Sync is enabled, your key is saved to your iCloud Keychain and syncs to your other devices. Get a free key at themoviedb.org; paste either the API Key or the Read Access Token. With a key, artwork and details for Movies and TV Shows come from TMDB first and your provider fills any gaps.")
                            .scaledFont(.system(size: 22).subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                    }

                    TMDBAttributionView(style: .long)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                // Display Scale is hidden on tvOS (Logan 2026-09-18): the TV
                // Movies / TV Shows layouts never read `uiScale`, so the
                // control did nothing. `scaleSliderRow_tvOS` below is kept
                // for when they do.
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scaleSliderRow_tvOS(title: String, binding: Binding<Double>) -> some View {
        let steps: [Double] = [0.85, 1.0, 1.15, 1.25, 1.35, 1.5]
        let current = steps.min(by: { abs($0 - binding.wrappedValue) < abs($1 - binding.wrappedValue) }) ?? 1.0
        return HStack(spacing: 24) {
            Text(title)
                .scaledFont(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer()
            ForEach(steps, id: \.self) { step in
                // Shared Settings chip, not `.buttonStyle(.plain)` (which
                // drew the system white platter on focus).
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

#if os(iOS)
/// Shared geometry for the two Settings action-button styles below, so a
/// primary and a ghost button sitting side by side are the same height
/// and the same corner radius.
private enum SettingsActionButtonMetrics {
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 8
    static let minHeight: CGFloat = 34
    static let cornerRadius: CGFloat = 10
}

/// Filled primary action (Save). Phase 3 (Logan 2026-09-18): the system
/// `.borderedProminent` capsule resolved to a pale near-white glass pill
/// inside a Settings card, so the primary action draws its own accent
/// fill instead.
struct SettingsPrimaryButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(.bodyMedium.weight(.semibold))
            .foregroundColor(.appBackground)
            .padding(.horizontal, SettingsActionButtonMetrics.horizontalPadding)
            .padding(.vertical, SettingsActionButtonMetrics.verticalPadding)
            .frame(minHeight: SettingsActionButtonMetrics.minHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsActionButtonMetrics.cornerRadius,
                                 style: .continuous)
                    .fill(accent)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary / ghost action (Test): accent label on a hairline accent
/// outline, same height and radius as the primary button.
struct SettingsGhostButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(.bodyMedium.weight(.medium))
            .foregroundColor(Color.contrastText(accent))
            .tint(accent)
            .padding(.horizontal, SettingsActionButtonMetrics.horizontalPadding)
            .padding(.vertical, SettingsActionButtonMetrics.verticalPadding)
            .frame(minHeight: SettingsActionButtonMetrics.minHeight)
            .background(
                RoundedRectangle(cornerRadius: SettingsActionButtonMetrics.cornerRadius,
                                 style: .continuous)
                    .fill(accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsActionButtonMetrics.cornerRadius,
                                 style: .continuous)
                    .strokeBorder(accent.opacity(0.55), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
