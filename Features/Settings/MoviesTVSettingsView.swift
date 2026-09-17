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

    /// Master toggle for the TMDB-by-title poster fallback.
    @AppStorage(TMDBPosters.enabledDefaultsKey)
    private var tmdbPostersEnabled = false
    /// Editable draft of the API key; loaded from / saved to the
    /// Keychain (never persisted in @AppStorage).
    @State private var tmdbKeyDraft = ""
    @State private var tmdbTestState: TMDBKeyTestState = .idle
    /// Eye toggle to reveal the entered key (masked by default).
    @State private var tmdbKeyVisible = false

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
            // MARK: Refresh library
            Section {
                ForEach(Self.vodRefreshChoices, id: \.hours) { choice in
                    Button {
                        vodRefreshHours = choice.hours
                    } label: {
                        HStack {
                            Text(choice.title)
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            if vodRefreshHours == choice.hours {
                                Image(systemName: "checkmark")
                                    .scaledFont(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.accent)
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Refresh library").sectionHeaderStyle()
            } footer: {
                Text("Live TV channels refresh on every launch. Movies and TV Shows open from the saved library and re-sweep the provider on this schedule. Pull down on either tab to refresh right away.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)

            // MARK: Posters
            Section {
                Toggle(isOn: $tmdbPostersEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fetch posters from TMDB")
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
                    HStack(spacing: 8) {
                        Group {
                            if tmdbKeyVisible {
                                TextField("TMDB API Key", text: $tmdbKeyDraft)
                            } else {
                                SecureField("TMDB API Key", text: $tmdbKeyDraft)
                            }
                        }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: tmdbKeyDraft) { _, _ in tmdbTestState = .idle }

                        Button {
                            tmdbKeyVisible.toggle()
                        } label: {
                            Image(systemName: tmdbKeyVisible ? "eye.slash" : "eye")
                                .foregroundColor(Color.contrastText(.textSecondary))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tmdbKeyVisible ? "Hide key" : "Show key")
                    }
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
                        .buttonStyle(.bordered)
                        .tint(theme.accent)
                        .disabled(tmdbKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                  || tmdbTestState == .testing)

                        tmdbStatusView

                        Spacer()

                        Button("Save") { saveTMDBKey() }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accent)
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
            Section {
                scaleSliderRow_iOS(title: "Movies & Series", binding: $vodScale)
            } header: {
                Text("Display Scale").sectionHeaderStyle()
            } footer: {
                Text("Independent scale for Movies & Series. 100% matches the default; 85-125% lets you trade density for readability. Changes apply live, no restart needed.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func scaleSliderRow_iOS(title: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int(binding.wrappedValue * 100))%")
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
            HStack(spacing: 12) {
                Image(systemName: "textformat.size.smaller")
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .scaledFont(.system(size: 12))
                Slider(value: binding, in: 0.85...1.75, step: 0.05)
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
                SettingsSection("Refresh library", style: .card) {
                    ForEach(Self.vodRefreshChoices, id: \.hours) { choice in
                        TVSettingsSelectionRow(
                            icon: choice.hours == 0 ? "arrow.clockwise" : "calendar",
                            iconColor: theme.accent,
                            label: choice.title,
                            subtitle: choice.hours == 0
                                ? "Re-sweep the provider library on every launch"
                                : "Open from the saved library; re-sweep the provider \(choice.hours == 24 ? "once a day" : "once a week")",
                            isSelected: vodRefreshHours == choice.hours,
                            action: { vodRefreshHours = choice.hours }
                        )
                    }
                }

                SettingsSection("Posters", style: .card) {
                    TVSettingsToggleRow(
                        icon: "photo.on.rectangle.angled",
                        iconColor: theme.accent,
                        title: "Fetch Posters from TMDB",
                        subtitle: "Fill in program artwork your provider doesn't supply, using The Movie Database.",
                        isOn: $tmdbPostersEnabled
                    ) { _ in }

                    if tmdbPostersEnabled {
                        // Same field component as the onboarding password
                        // field (AddServerView): types correctly on tvOS, and
                        // revealWhenFocused shows the key while focused since
                        // the in-box eye button can't be reached by the remote.
                        AppTextField("TMDB API Key",
                                     placeholder: "API Key or Read Access Token",
                                     text: $tmdbKeyDraft,
                                     isSecure: true,
                                     revealWhenFocused: true)
                            .onChange(of: tmdbKeyDraft) { _, _ in tmdbTestState = .idle }

                        HStack(spacing: 24) {
                            // Not gated on an empty key: on tvOS the field only
                            // commits its text when focus LEAVES it, and the
                            // focus engine can't move onto a disabled button.
                            TVCompactButton(
                                title: tmdbTestState == .testing ? "Testing…" : "Test",
                                disabled: tmdbTestState == .testing
                            ) { Task { await testTMDBKey() } }

                            TVCompactButton(
                                title: "Save",
                                disabled: tmdbTestState == .testing
                            ) { saveTMDBKey() }

                            tmdbStatusView
                            Spacer()
                        }

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

                SettingsSection("Display Scale", style: .card) {
                    scaleSliderRow_tvOS(title: "Movies & Series", binding: $vodScale)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scaleSliderRow_tvOS(title: String, binding: Binding<Double>) -> some View {
        let steps: [Double] = [0.85, 0.92, 1.0, 1.15, 1.25, 1.5, 1.75]
        let current = steps.min(by: { abs($0 - binding.wrappedValue) < abs($1 - binding.wrappedValue) }) ?? 1.0
        return HStack(spacing: 24) {
            Text(title)
                .scaledFont(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer()
            ForEach(steps, id: \.self) { step in
                Button {
                    binding.wrappedValue = step
                } label: {
                    Text("\(Int(step * 100))%")
                        .scaledFont(.system(size: 22, weight: .medium))
                        .foregroundColor(step == current ? Color.contrastText(theme.accent) : Color.contrastText(.textSecondary))
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
}
