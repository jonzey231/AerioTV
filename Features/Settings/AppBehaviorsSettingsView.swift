import SwiftUI

/// Settings → App Behaviors. Surfaces user-toggleable behaviors that
/// change how the app reacts to launch lifecycle, remote input, and
/// other ambient interactions.
///
/// History: this content lived as a "App Behaviors" subsection inside
/// `AppearanceSettingsView` from v1.6.13 through v1.7.x. It outgrew
/// that home — Skip Loading Screen and Resume Last Channel are about
/// app lifecycle, not visual appearance, and the v1.7.x addition of
/// the Apple TV Channel Flip toggle made the misnomer obvious. v1.7.x
/// promotes this group to its own top-level Settings entry.
///
/// All toggles are `@AppStorage`-backed so flipping any value updates
/// the relevant runtime path immediately without a relaunch. The
/// `appBehaviors*` key prefix matches the original v1.6.13 naming so
/// existing users carry their preferences forward unchanged.
struct AppBehaviorsSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared

    // MARK: - Toggles

    /// Dismiss the "Setting Up" cover immediately on launch and let
    /// channels / EPG / VOD hydrate in the background instead of
    /// behind a blocking modal. The cost is brief UI stutter or
    /// empty-state flicker during the first ~30 s while data
    /// streams in. Default OFF — the cover is the safe path.
    @AppStorage("appBehaviorsSkipLoadingScreen")
    private var skipLoadingScreen = false

    /// Auto-start the last-played channel in the corner mini-player
    /// on launch (iPad / tvOS only — iPhone keeps the bottom-sheet
    /// MiniPlayerBar paradigm without a corner box). Default OFF.
    @AppStorage("appBehaviorsAutoResumeLastChannel")
    private var autoResumeLastChannel = false

    /// v1.7.x: gate the Apple TV up/down d-pad channel-flip on
    /// single-stream live playback. Default ON to preserve the
    /// behaviour shipped since v1.6.15 (tvOS) / v1.6.18 (iOS).
    /// Covers both input paths via the same storage key:
    ///   - Apple TV Siri Remote up/down d-pad
    ///     (PlayerView.onMoveCommand,
    ///     MultiviewContainerView.onMoveCommand at N=1).
    ///   - iPhone / iPad swipe up/down on the chrome-visible
    ///     player (PlayerView's DragGesture `.onEnded` branch).
    /// Some users prefer the gesture to do nothing during playback
    /// (cat-on-couch flips on tvOS, thumb-bumps on iPhone). When
    /// off, both input paths no-op for channel switching while
    /// leaving every other behaviour (chrome reveal, Options pill
    /// nav, minimize swipe-down) intact.
    ///
    /// Storage-key name kept as `appBehaviorsAppleTVChannelFlip`
    /// for back-compat with v1.7.x's first ship that only covered
    /// the Apple TV path. The toggle's user-facing copy was
    /// rewritten in v1.7.x to include iOS gestures.
    @AppStorage("appBehaviorsAppleTVChannelFlip")
    private var appleTVChannelFlip = true

    // MARK: - TMDB program posters (opt-in, off by default)

    /// Master toggle for the TMDB-by-title poster fallback.
    @AppStorage(TMDBPosters.enabledDefaultsKey)
    private var tmdbPostersEnabled = false
    /// Editable draft of the API key; loaded from / saved to the
    /// Keychain (never persisted in @AppStorage).
    @State private var tmdbKeyDraft = ""
    @State private var tmdbTestState: TMDBKeyTestState = .idle

    enum TMDBKeyTestState: Equatable { case idle, testing, valid, invalid }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("App Behaviors")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .onAppear {
            tmdbKeyDraft = KeychainHelper.load(key: TMDBPosters.keychainKey) ?? ""
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
        let key = tmdbKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            _ = KeychainHelper.delete(TMDBPosters.keychainKey)
        } else {
            _ = KeychainHelper.save(key, for: TMDBPosters.keychainKey)
        }
    }

    @ViewBuilder
    private var tmdbStatusView: some View {
        switch tmdbTestState {
        case .idle, .testing:
            EmptyView()
        case .valid:
            Label("Valid key", systemImage: "checkmark.circle.fill")
                .font(.labelSmall).foregroundColor(.green)
        case .invalid:
            Label("Invalid key", systemImage: "xmark.circle.fill")
                .font(.labelSmall).foregroundColor(.red)
        }
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            // MARK: Launch Behavior
            Section {
                Toggle(isOn: $skipLoadingScreen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip loading screen")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Land on Live TV instantly; data hydrates in the background")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Toggle(isOn: $autoResumeLastChannel) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resume last channel")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text("Auto-start the last-played channel in the corner mini-player on launch")
                                .font(.labelSmall)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Launch").sectionHeaderStyle()
            } footer: {
                Text(UIDevice.current.userInterfaceIdiom == .pad
                     ? "Skipping the loading screen may cause brief UI stutter while data loads. Resume picks up the last channel you watched in the corner mini-player; press Play/Pause to expand."
                     : "Skipping the loading screen may cause brief UI stutter while data loads.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)

            // MARK: Channel Flip Gesture
            //
            // Single toggle that gates both input paths (Apple TV
            // d-pad + iPhone/iPad swipe) on the same storage key.
            // Surfaced on every platform so the user has one
            // canonical preference no matter which device they're
            // configuring from.
            Section {
                Toggle(isOn: $appleTVChannelFlip) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up / Down channel change")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("On iPhone & iPad, swipe up on the player for the next channel, swipe down for the previous. On Apple TV, press up or down on the Siri Remote. Live single-stream playback only.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Channel Flip Gesture").sectionHeaderStyle()
            } footer: {
                Text("Turn off if accidental swipes or D-pad presses are flipping channels during playback.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)

            // MARK: Program Posters (TMDB)
            Section {
                Toggle(isOn: $tmdbPostersEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fetch posters from TMDB")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Fill in program artwork your provider doesn't supply, using The Movie Database.")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                if tmdbPostersEnabled {
                    SecureField("TMDB API Key", text: $tmdbKeyDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
                Text("Program Posters").sectionHeaderStyle()
            } footer: {
                Text("Your key stays on this device (Keychain). Get a free key at themoviedb.org, then Settings, then API. Posters appear in Program Info.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }
    #endif

    // MARK: - tvOS Body

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvSection("Launch") {
                    TVSettingsToggleRow(
                        icon: "bolt.horizontal",
                        iconColor: theme.accent,
                        title: "Skip Loading Screen",
                        subtitle: "Land on Live TV instantly; data hydrates in the background",
                        isOn: $skipLoadingScreen
                    ) { _ in }

                    TVSettingsToggleRow(
                        icon: "play.tv",
                        iconColor: theme.accent,
                        title: "Resume Last Channel",
                        subtitle: "Auto-start the last-played channel in the corner mini-player on launch",
                        isOn: $autoResumeLastChannel
                    ) { _ in }
                }

                tvSection("Channel Flip Gesture") {
                    TVSettingsToggleRow(
                        icon: "arrow.up.and.down",
                        iconColor: theme.accent,
                        title: "Up / Down Channel Change",
                        subtitle: "Press up on the Siri Remote for the next channel, down for the previous. Live single-stream playback only.",
                        isOn: $appleTVChannelFlip
                    ) { _ in }

                    Text("Turn off if accidental D-pad presses are flipping channels during playback. iPhone & iPad use the matching swipe-up / swipe-down gesture on the same toggle.")
                        .font(.system(size: 22))
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }

                tvSection("Program Posters") {
                    TVSettingsToggleRow(
                        icon: "photo.on.rectangle.angled",
                        iconColor: theme.accent,
                        title: "Fetch Posters from TMDB",
                        subtitle: "Fill in program artwork your provider doesn't supply, using The Movie Database.",
                        isOn: $tmdbPostersEnabled
                    ) { _ in }

                    if tmdbPostersEnabled {
                        TVSettingsTextField(placeholder: "TMDB API Key",
                                            text: $tmdbKeyDraft,
                                            isSecure: true)
                            .onChange(of: tmdbKeyDraft) { _, _ in tmdbTestState = .idle }

                        HStack(spacing: 24) {
                            TVCompactButton(
                                title: tmdbTestState == .testing ? "Testing…" : "Test",
                                disabled: tmdbKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                          || tmdbTestState == .testing
                            ) { Task { await testTMDBKey() } }

                            TVCompactButton(
                                title: "Save",
                                disabled: tmdbTestState == .testing
                            ) { saveTMDBKey() }

                            tmdbStatusView
                            Spacer()
                        }

                        Text("Your key stays on this device. Get a free key at themoviedb.org. Posters appear in Program Info.")
                            .font(.system(size: 22))
                            .foregroundColor(.textTertiary)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Section wrapper matching `AppearanceSettingsView.tvAppearanceSection`
    /// shape so this submenu visually matches the rest of tvOS Settings.
    @ViewBuilder
    private func tvSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.textPrimary)
            VStack(spacing: 12) {
                content()
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.cardBackground)
            )
        }
    }
    #endif
}

#if os(tvOS)
/// Compact tvOS action button that renders its label correctly when
/// focused. The default tvOS button style fills with the accent and
/// hides the label inside a hand-built (non-List) settings card, so we
/// suppress it with TVNoHighlightButtonStyle and draw our own focus
/// border + fill (mirroring TVSettingsActionRow's approach).
private struct TVCompactButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(disabled ? .textTertiary : .accentPrimary)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(minWidth: 160)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFocused ? Color.accentPrimary.opacity(0.20) : Color.elevatedBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentPrimary, lineWidth: isFocused ? 3 : 0)
                )
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .disabled(disabled)
    }
}
#endif
