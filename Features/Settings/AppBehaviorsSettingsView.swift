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
    // Moved here from Appearance (2026-07 settings unification): the
    // landing tab and default Live TV layout are launch behavior, and
    // Android has always kept Default Tab on this page.
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    // Default Live TV View. "" = Automatic (form-factor default: List on
    // iPhone, Guide on iPad and Apple TV); "list" / "guide" are explicit
    // overrides. This Settings row is the ONLY writer of the key. The
    // in-screen List / Guide button switches the current view for the
    // session only and never persists here, so an explicit choice on one
    // device no longer clobbers another form factor's default.
    @AppStorage("defaultLiveTVView") private var defaultLiveTVView = ""

    // Live Rewind settings (redesigned 2026-07-11 per user directive
    // from the Z Fold field pass): depth + retention are SLIDER
    // ladders (segments on tvOS - no native Slider, and segments are
    // this app's established tvOS idiom, see Display Scale); the
    // Storage Limit setting was REMOVED in favor of storage estimates
    // under the retention control, with an invisible free-disk-space
    // floor in LiveRewindEngine as the seatbelt. The custom-retention
    // alert died with the redesign (the ladder covers the range;
    // legacy custom values snap to the nearest stop for display).
    @AppStorage("liveRewindEnabled") private var liveRewindEnabled = false
    @AppStorage("liveRewindDepthMinutes") private var liveRewindDepthMinutes = 30

    /// Keep Available ladder (2026-07-11 rework, user directive round
    /// 2: the user-meaningful knob is HOW FAR BACK you can rewind, not
    /// how long files persist - retention is now a fixed internal 1
    /// hour in LiveRewindEngine; liveRewindRetentionHours is dormant).
    private static let rewindDepthSteps = [15, 30, 60, 90, 120, 180]

    private func depthLabel(_ mins: Int) -> String {
        if mins < 60 { return "\(mins) minutes" }
        if mins == 60 { return "1 hour" }
        return mins % 60 == 0 ? "\(mins / 60) hours" : "\(mins / 60)h \(mins % 60)m"
    }

    // MARK: - Default Live TV View options

    /// Default Live TV View choices, in display order. "" = Automatic
    /// (form-factor default: List on iPhone, Guide on iPad and Apple TV);
    /// "list" / "guide" are explicit overrides written to the shared
    /// `defaultLiveTVView` key.
    private static let liveTVViewOptions: [String] = ["", "list", "guide"]

    private func liveTVViewLabel(_ value: String) -> String {
        switch value {
        case "list": return "List"
        case "guide": return "Guide"
        default: return "Automatic"
        }
    }

    private func liveTVViewIcon(_ value: String) -> String {
        switch value {
        case "list": return "list.bullet"
        case "guide": return "calendar"
        default: return "wand.and.stars"
        }
    }

    /// Storage estimate under the Keep Available slider: scales with
    /// the depth choice (which bounds live disk usage now that
    /// retention is a fixed short window) at typical stream bitrates -
    /// HD ~4 Mbps, FHD ~8, UHD ~20.
    private func depthEstimate(_ mins: Int) -> String {
        func gb(_ mbps: Double) -> String {
            let v = mbps * 7.5 * Double(mins) / 1024.0
            return v < 10 ? String(format: "~%.1f GB", v) : "~\(Int(v.rounded())) GB"
        }
        return "Uses up to \(gb(4)) in HD, \(gb(8)) in FHD, or \(gb(20)) in UHD while you watch."
    }

    @AppStorage("appBehaviorsSkipLoadingScreen")
    private var skipLoadingScreen = false

    #if os(iOS)
    /// Auto-Rotate (Logan 2026-08-07): follow the device orientation in
    /// the whole app. Default ON. When off, iPhone pins portrait and iPad
    /// freezes in its current orientation; the player's fullscreen button
    /// still forces landscape. Key read by `AppOrientationLock.base`;
    /// device-local like the sibling appBehaviors* keys.
    @AppStorage(AppOrientationLock.autoRotateKey)
    private var autoRotate = true
    #endif

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

    /// Extra behind-live buffer cushion (seconds) folded into the live
    /// mpv cache at tune-in to smooth jitter from any live source. Read
    /// live in `MPVPlayerView.setupMPV` from this same key. Default 0
    /// keeps the current low-latency tap-to-first-frame path
    /// byte-identical. Range 0...5s, step 0.5. Left UNSYNCED to match the
    /// sibling `appBehaviors*` keys.
    @AppStorage("appBehaviorsStreamBufferSeconds")
    private var streamBufferSeconds: Double = 0

    /// #37 kill-switch: when false, the player's frozen-stream auto-reload
    /// watchdogs (stale-frame + black-frame loadfile-replace) are disabled,
    /// so a live channel that restarts/stutters at commercial boundaries is
    /// left to recover on its own instead of being force-reloaded. Default
    /// true. Read live in `MPVPlayerView.setupMPV`. UNSYNCED, like the
    /// sibling `appBehaviors*` keys.
    @AppStorage("appBehaviorsAutoRecoverFrozenStreams")
    private var autoRecoverFrozenStreams = true

    /// Show the LIVE / NEW / season-episode pills on the guide, channel
    /// list, and program info. Default ON. Synced per device type (tv vs
    /// mobile) via `epgBadgesVisibleKey`, so an Apple TV preference and an
    /// iPhone/iPad preference are remembered independently but each syncs
    /// across that user's devices of the same kind.
    @AppStorage(epgBadgesVisibleKey) private var showEpgBadges = true

    // MARK: - TMDB program posters (opt-in, off by default)

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
        // Misses cached under the previous key (e.g. while a bad key was
        // returning 401s) must not survive a key change; positives
        // re-resolve cheaply on the next lookup.
        TMDBService.clearCache()
        // Confirm the write to the user: both bodies render tmdbStatusView,
        // which shows a green "Saved" check for this state. Resets to .idle
        // on the next keystroke (the field's onChange).
        tmdbTestState = .saved
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
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.labelSmall).foregroundColor(.green)
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

            // MARK: Orientation (Logan 2026-08-07)
            Section {
                Toggle(isOn: $autoRotate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-rotate")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text(UIDevice.current.userInterfaceIdiom == .pad
                             ? "Follow the device orientation. When off, AerioTV stays in its current orientation"
                             : "Follow the device orientation. When off, AerioTV stays portrait")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: autoRotate) { _, _ in
                    AppOrientationLock.refreshBase()
                }
            } header: {
                Text("Orientation").sectionHeaderStyle()
            } footer: {
                Text("The player's fullscreen button can still rotate into landscape either way.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)

            // MARK: Live Rewind
            Section {
                Toggle(isOn: $liveRewindEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause & rewind live TV")
                            .font(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Buffer fullscreen live playback on this device")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Live Rewind").sectionHeaderStyle()
            } footer: {
                Text("Buffers the channel you are watching so you can pause and rewind live TV. Uses device storage while you watch; buffered video is removed automatically.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)

            if liveRewindEnabled {
                Section {
                    steppedSliderRow_iOS(
                        title: "Rewind up to",
                        values: Self.rewindDepthSteps,
                        selection: $liveRewindDepthMinutes,
                        label: depthLabel
                    )
                } header: {
                    Text("Keep Available").sectionHeaderStyle()
                } footer: {
                    Text("How far back you can rewind the channel you are watching. Buffered video is removed about an hour after you leave a channel. \(depthEstimate(liveRewindDepthMinutes))")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
                .listSectionSeparator(.hidden)
            }

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

            // MARK: Default Live TV View
            // Shown on all iOS form factors now that iPhone (and the folded
            // foldable) can open the Guide. Automatic is width-adaptive, so
            // each device / posture keeps a sensible default; an explicit
            // choice here overrides it. Apple TV always uses Guide.
            Section {
                ForEach(Self.liveTVViewOptions, id: \.self) { option in
                    Button {
                        defaultLiveTVView = option
                    } label: {
                        HStack {
                            Image(systemName: liveTVViewIcon(option))
                                .font(.system(size: 15))
                                .foregroundColor(theme.accent)
                                .frame(width: 24)
                            Text(liveTVViewLabel(option))
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
                Text("The layout Live TV opens in. Automatic uses List on compact, portrait phones and Guide on regular width (unfolded foldable, iPad, Apple TV). You can still switch anytime with the List / Guide button; that switch lasts for the current session and does not change this default.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)

            // MARK: Guide badges
            Section {
                Toggle(isOn: $showEpgBadges) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show program badges")
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("LIVE, NEW, and season/episode pills on the guide")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Guide").sectionHeaderStyle()
            } footer: {
                Text("Show the LIVE, NEW, and season/episode pills on the guide, channel list, and program info. Remembered separately for iPhone/iPad and Apple TV, and synced across your devices of that kind.")
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

            // MARK: Stream Buffer
            Section {
                StreamBufferSlider(value: $streamBufferSeconds)
                    .listRowBackground(Color.cardBackground)
            } header: {
                Text("Stream Buffer").sectionHeaderStyle()
            } footer: {
                Text("Extra buffer to smooth jitter and stutter on live streams from any source. Higher is smoother but adds delay behind live. 0 keeps the lowest latency. Applies to the next channel you tune.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)

            // MARK: Auto-Recover Frozen Streams (#37)
            Section {
                Toggle(isOn: $autoRecoverFrozenStreams) {
                    Text("Auto-Recover Frozen Streams")
                        .font(.bodyMedium)
                        .foregroundColor(.textPrimary)
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
            } footer: {
                Text("If a live stream stops sending video, the player reloads it to recover. Turn this off if live channels restart or stutter during commercial breaks (a brief freeze may show instead). Applies to the next channel you tune.")
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
                                .foregroundColor(.textSecondary)
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
                Text("Program Posters").sectionHeaderStyle()
            } footer: {
                Text("If iCloud Sync is enabled, your key is saved to your iCloud Keychain and syncs to your other devices. Get a free key at themoviedb.org under Settings, then API; paste either the API Key or the Read Access Token. Posters appear in Program Info and on VOD with no provider art.")
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }

    /// Discrete-stop slider row over an Int ladder (2026-07-11 settings
    /// redesign): label left, current value right, stepped Slider below.
    /// Legacy/custom persisted values snap to the nearest stop for
    /// display; the pref is only rewritten when the user moves it.
    private func steppedSliderRow_iOS(
        title: String,
        values: [Int],
        selection: Binding<Int>,
        label: @escaping (Int) -> String
    ) -> some View {
        let idx = values.indices.min(by: {
            abs(values[$0] - selection.wrappedValue) < abs(values[$1] - selection.wrappedValue)
        }) ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(label(values[idx]))
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
            }
            Slider(
                value: Binding(
                    get: { Double(idx) },
                    set: { raw in
                        let i = min(max(Int(raw.rounded()), 0), values.count - 1)
                        if values[i] != selection.wrappedValue { selection.wrappedValue = values[i] }
                    }
                ),
                in: 0...Double(values.count - 1),
                step: 1
            )
            .tint(theme.accent)
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
                SettingsSection("Launch", style: .card) {
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

                // Default Tab
                SettingsSection("Default Landing Tab", style: .card) {
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

                // Default Live TV View. Apple TV always renders Guide, so
                // this control sets the shared cross-device default (which
                // iPad honors) via the same key; Automatic keeps each form
                // factor on its own default. The in-screen List / Guide pill
                // stays session-only and never writes here.
                SettingsSection("Default Live TV View", style: .card) {
                    ForEach(Self.liveTVViewOptions, id: \.self) { option in
                        TVSettingsSelectionRow(
                            icon: liveTVViewIcon(option),
                            iconColor: theme.accent,
                            label: liveTVViewLabel(option),
                            isSelected: defaultLiveTVView == option,
                            action: { defaultLiveTVView = option }
                        )
                    }
                }

                SettingsSection("Guide", style: .card) {
                    TVSettingsToggleRow(
                        icon: "tag",
                        iconColor: theme.accent,
                        title: "Show Program Badges",
                        subtitle: "LIVE, NEW, and season/episode pills on the guide",
                        isOn: $showEpgBadges
                    ) { _ in }

                    Text("Show the LIVE, NEW, and season/episode pills on the guide, channel list, and program info. Remembered separately for Apple TV and iPhone/iPad, and synced across your Apple TVs.")
                        .font(.system(size: 22))
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }

                SettingsSection("Live Rewind", style: .card) {
                    TVSettingsToggleRow(
                        icon: "gobackward.30",
                        iconColor: theme.accent,
                        title: "Pause & Rewind Live TV",
                        subtitle: "Buffer fullscreen live playback on this Apple TV",
                        isOn: $liveRewindEnabled
                    ) { _ in }
                    Text("Buffers the channel you are watching so you can pause and rewind live TV. Uses device storage while you watch; buffered video is removed automatically.")
                        .font(.system(size: 22))
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }

                if liveRewindEnabled {
                    SettingsSection("Keep Available", style: .card) {
                        tvSteppedSegmentsRow(
                            title: "Rewind up to",
                            values: Self.rewindDepthSteps,
                            selection: $liveRewindDepthMinutes,
                            segmentLabel: { m in
                                if m < 60 { return "\(m)m" }
                                return m % 60 == 0 ? "\(m / 60)h" : "\(m)m"
                            }
                        )
                        Text("How far back you can rewind the channel you are watching. Buffered video is removed about an hour after you leave a channel. \(depthEstimate(liveRewindDepthMinutes))")
                            .font(.system(size: 22))
                            .foregroundColor(.textTertiary)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                    }
                }

                SettingsSection("Channel Flip Gesture", style: .card) {
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

                SettingsSection("Stream Buffer", style: .card) {
                    StreamBufferSlider(value: $streamBufferSeconds)

                    Text("Extra buffer to smooth jitter and stutter on live streams from any source. Higher is smoother but adds delay behind live. 0 keeps the lowest latency. Applies to the next channel you tune. Press left or right on the Siri Remote to adjust.")
                        .font(.system(size: 22))
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }

                SettingsSection("Stream Recovery", style: .card) {
                    TVSettingsToggleRow(
                        icon: "arrow.clockwise.circle",
                        iconColor: theme.accent,
                        title: "Auto-Recover Frozen Streams",
                        subtitle: "If a live stream stops sending video, the player reloads it to recover. Turn this off if live channels restart or stutter during commercial breaks; a brief freeze may show instead.",
                        isOn: $autoRecoverFrozenStreams
                    ) { _ in }
                }

                SettingsSection("Program Posters", style: .card) {
                    TVSettingsToggleRow(
                        icon: "photo.on.rectangle.angled",
                        iconColor: theme.accent,
                        title: "Fetch Posters from TMDB",
                        subtitle: "Fill in program artwork your provider doesn't supply, using The Movie Database.",
                        isOn: $tmdbPostersEnabled
                    ) { _ in }

                    if tmdbPostersEnabled {
                        // Same field component as the onboarding password
                        // field (AddServerView) - types correctly on tvOS.
                        // revealWhenFocused shows the key in plaintext while
                        // the field is focused: the in-box eye button can't be
                        // reached by the Siri Remote once a UITextField holds
                        // focus (focus can't move sideways off it), so reveal-
                        // on-focus is the remote-friendly way to read it back.
                        AppTextField("TMDB API Key",
                                     placeholder: "API Key or Read Access Token",
                                     text: $tmdbKeyDraft,
                                     isSecure: true,
                                     revealWhenFocused: true)
                            .onChange(of: tmdbKeyDraft) { _, _ in tmdbTestState = .idle }

                        HStack(spacing: 24) {
                            // Not gated on an empty key: on tvOS the field
                            // only commits its text to the binding when focus
                            // LEAVES it, and the focus engine can't move onto
                            // a disabled button - so gating Test on the (still
                            // un-committed) draft created a deadlock. Test
                            // reads the committed value when pressed instead.
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

                        Text("If iCloud Sync is enabled, your key is saved to your iCloud Keychain and syncs to your other devices. Get a free key at themoviedb.org; paste either the API Key or the Read Access Token. Posters appear in Program Info and on VOD with no provider art.")
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

    /// tvOS discrete ladder row (2026-07-11 settings redesign): title
    /// left, one focusable segment per stop (the app's established tvOS
    /// slider idiom - see Appearance's Display Scale; tvOS has no
    /// native Slider and a custom focus-track slider risks the focus
    /// traps this codebase keeps re-learning). Snaps legacy/custom
    /// persisted values to the nearest stop for highlight.
    private func tvSteppedSegmentsRow(
        title: String,
        values: [Int],
        selection: Binding<Int>,
        segmentLabel: @escaping (Int) -> String
    ) -> some View {
        let current = values.min(by: {
            abs($0 - selection.wrappedValue) < abs($1 - selection.wrappedValue)
        }) ?? selection.wrappedValue
        return HStack(spacing: 24) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer()
            ForEach(values, id: \.self) { value in
                Button {
                    selection.wrappedValue = value
                } label: {
                    Text(segmentLabel(value))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(value == current ? theme.accent : .textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(value == current
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

// MARK: - Stream Buffer Slider (reusable, platform-split)

/// Reusable "Stream Buffer" control for Settings → App Behaviors.
///
/// Encapsulates the per-platform slider so both `iOSBody` and
/// `tvOSBody` can drop in `StreamBufferSlider(value:)`:
///   - iOS / iPadOS: a native `Slider` (0...5, step 0.5) with a
///     right-aligned "Off" / "X.Xs" value label, modeled on the
///     networkTimeout row in `SettingsView`.
///   - tvOS: a custom focusable track adjusted with the Siri Remote.
///     Left/right decrement/increment by 0.5 (clamped 0...5);
///     up/down are passed through so the focus engine still navigates
///     to adjacent rows.
struct StreamBufferSlider: View {
    @Binding var value: Double
    @ObservedObject private var theme = ThemeManager.shared

    private static let range: ClosedRange<Double> = 0...5
    private static let step: Double = 0.5

    /// "Off" at 0, otherwise "X.Xs".
    private var valueLabel: String {
        value <= 0 ? "Off" : String(format: "%.1fs", value)
    }

    #if os(iOS)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stream Buffer")
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(valueLabel)
                    .font(.monoSmall)
                    .foregroundColor(theme.accent)
            }
            Slider(value: $value, in: Self.range, step: Self.step)
                .tint(theme.accent)
        }
    }
    #else
    // tvOS: custom focusable track driven by the Siri Remote.
    @State private var isFocused = false

    private func clamp(_ v: Double) -> Double {
        min(max(v, Self.range.lowerBound), Self.range.upperBound)
    }

    private func adjust(by delta: Double) {
        withAnimation(.easeOut(duration: 0.12)) {
            value = clamp(value + delta)
        }
    }

    var body: some View {
        HStack(spacing: 24) {
            Text("Stream Buffer")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.textPrimary)
                .frame(width: 260, alignment: .leading)

            GeometryReader { geo in
                let trackWidth = geo.size.width
                let fraction = Self.range.upperBound > 0
                    ? value / Self.range.upperBound
                    : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.textTertiary.opacity(0.25))
                        .frame(height: 10)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: max(0, trackWidth * fraction), height: 10)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 44)

            Text(valueLabel)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundColor(isFocused ? theme.accent : .textSecondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFocused ? Color.accentPrimary.opacity(0.12) : Color.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentPrimary, lineWidth: isFocused ? 3 : 0)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .overlay(
            TVPressOverlay(
                isFocused: $isFocused,
                canFocus: true,
                interceptsDirectional: true,
                // Slider adjust mode: left/right change the value; up/down and
                // Menu fall through so the focus engine can navigate away.
                horizontalAdjustOnly: true,
                // Tap does nothing (a value slider, not a button).
                onTap: {},
                onLongPress: {},
                onMoveUp: {},
                onMoveDown: {},
                onMenu: {},
                // Left/right adjust the value, clamped 0...5.
                onMoveLeft: { adjust(by: -Self.step) },
                onMoveRight: { adjust(by: Self.step) }
            )
        )
        .accessibilityElement()
        .accessibilityLabel("Stream Buffer")
        .accessibilityValue(valueLabel)
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
