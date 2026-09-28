//
//  PlayerSettingsView.swift
//  Aerio
//
//  Settings redesign Phase 1 (regroup, 2026-09-17). Everything about
//  playback itself - the in-player info card, live rewind, the playback
//  knobs (skip intervals, buffers, auto-recovery), the in-player gestures
//  and the multiview tile appearance - now lives on one page.
//
//  This file is the former AppBehaviorsSettingsView.swift: launch and
//  refresh behavior moved to General, the guide rows to Live TV, the
//  poster rows to Movies & TV Shows. Shared controls (StreamBufferSlider,
//  TVSteppedSegmentStyle, TVCompactButton) moved to
//  Components/SettingsControls.swift.
//
//  No persisted key changed in the move.
//

import SwiftUI

/// Buffer Size choices, moved here from the old Network page with their
/// copy unchanged.
private struct BufferOption: Identifiable {
    let id: String
    let label: String
    let detail: String  // human-readable size
    let cachingMs: Int  // VLC :network-caching value in milliseconds
}
private let bufferOptions: [BufferOption] = [
    BufferOption(id: "small",   label: "Small",       detail: "300 ms: fast, stable networks",   cachingMs: 300),
    BufferOption(id: "default", label: "Default",     detail: "1 second: recommended",           cachingMs: 1_000),
    BufferOption(id: "large",   label: "Large",       detail: "3 seconds: unstable connections", cachingMs: 3_000),
    BufferOption(id: "xlarge",  label: "Extra Large", detail: "8 seconds: very poor networks",   cachingMs: 8_000),
]

struct PlayerSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared

    // MARK: - Player Info Card (Logan 2026-09-15, Android parity)
    @AppStorage(PlayerInfoCardSettings.channelLogoKey)
    private var infoCardChannelLogo = true
    @AppStorage(PlayerInfoCardSettings.channelNameKey)
    private var infoCardChannelName = true
    @AppStorage(PlayerInfoCardSettings.programNameKey)
    private var infoCardProgramName = true
    @AppStorage(PlayerInfoCardSettings.programTimeKey)
    private var infoCardProgramTime = true
    @AppStorage(PlayerInfoCardSettings.programSubtitleKey)
    private var infoCardProgramSubtitle = true
    @AppStorage(PlayerInfoCardSettings.programDescriptionKey)
    private var infoCardProgramDescription = true

    /// The six rows in display order, paired with their bindings.
    private var playerInfoCardRows: [(key: String, binding: Binding<Bool>)] {
        [
            (PlayerInfoCardSettings.channelLogoKey, $infoCardChannelLogo),
            (PlayerInfoCardSettings.channelNameKey, $infoCardChannelName),
            (PlayerInfoCardSettings.programNameKey, $infoCardProgramName),
            (PlayerInfoCardSettings.programTimeKey, $infoCardProgramTime),
            (PlayerInfoCardSettings.programSubtitleKey, $infoCardProgramSubtitle),
            (PlayerInfoCardSettings.programDescriptionKey, $infoCardProgramDescription)
        ]
    }

    private static let playerInfoCardFooter =
        "Choose what appears on the program info card in the player while the controls are showing."

    /// Phase 3, item 4: the master row's subtitle. WHICH lines show
    /// matters more than how many, so this lists them rather than
    /// counting ("All 6", "Logo, name, time", "None"). Built from the
    /// same ordered array the rows come from, so iOS and tvOS read
    /// identically.
    private var playerInfoCardSummary: String {
        let enabled = playerInfoCardRows
            .filter { $0.binding.wrappedValue }
            .map { PlayerInfoCardSettings.title($0.key) }
        return SettingsSummary.list(enabled, of: playerInfoCardRows.count)
    }

    // MARK: - Live Rewind
    @AppStorage("liveRewindEnabled") private var liveRewindEnabled = false
    @AppStorage("liveRewindDepthMinutes") private var liveRewindDepthMinutes = 30
    @AppStorage("liveRewindRetainChannels") private var liveRewindRetainChannels = false
    @AppStorage("liveRewindRetainCount") private var liveRewindRetainCount = 2

    private static let rewindDepthSteps = [15, 30, 60, 90, 120, 180]

    private func depthLabel(_ mins: Int) -> String {
        if mins < 60 { return "\(mins) minutes" }
        if mins == 60 { return "1 hour" }
        return mins % 60 == 0 ? "\(mins / 60) hours" : "\(mins / 60)h \(mins % 60)m"
    }

    private func depthEstimate(_ mins: Int) -> String {
        func gb(_ mbps: Double) -> String {
            let v = mbps * 7.5 * Double(mins) / 1024.0
            return v < 10 ? String(format: "~%.1f GB", v) : "~\(Int(v.rounded())) GB"
        }
        return "Uses up to \(gb(4)) in HD, \(gb(8)) in FHD, or \(gb(20)) in UHD while you watch."
    }

    /// Phase 3, item 3: one option list for "Rewind Up To" on both
    /// platforms. tvOS used to print its own "15m" / "1h" segments while
    /// iOS said "15 minutes" / "1 hour"; both now go through
    /// `depthLabel`, so the wording finally agrees.
    private var rewindDepthOptions: [SettingsChoice<Int>] {
        Self.rewindDepthSteps.map { SettingsChoice($0, depthLabel($0)) }
    }

    /// Phase 3, item 4: subtitle for the Live Rewind subgroup card.
    private var liveRewindSummary: String {
        liveRewindEnabled ? depthLabel(liveRewindDepthMinutes) : "Off"
    }

    /// Phase 3, item 3: Buffer Size as a single pushed choice on iOS and
    /// an inline check list on tvOS. Same copy as before, same
    /// "streamBufferSize" key.
    private var bufferSizeOptions: [SettingsChoice<String>] {
        bufferOptions.map { SettingsChoice($0.id, $0.label, subtitle: $0.detail) }
    }

    /// Phase 3, item 3: the multiview audio focus marker.
    private var audioFocusOptions: [SettingsChoice<String>] {
        MultiviewAudioFocusStyle.allCases.map {
            SettingsChoice($0.rawValue, $0.displayName, subtitle: $0.subtitle)
        }
    }

    /// Phase 3, item 3: Tile Corners. The tvOS icons now ride along on
    /// iOS too, so the choice page matches the TV list.
    private var tileCornerOptions: [SettingsChoice<Bool>] {
        [
            SettingsChoice(false, "Square", icon: "square"),
            SettingsChoice(true, "Rounded", icon: "square.dashed")
        ]
    }

    // MARK: - Playback
    @AppStorage(SkipIntervals.backKey) private var skipBackSeconds = SkipIntervals.defaultBack
    @AppStorage(SkipIntervals.forwardKey) private var skipForwardSeconds = SkipIntervals.defaultForward
    @AppStorage("appBehaviorsStreamBufferSeconds")
    private var streamBufferSeconds: Double = 0
    @AppStorage("streamBufferSize") private var streamBufferSize = "default"
    @AppStorage("appBehaviorsAutoRecoverFrozenStreams")
    private var autoRecoverFrozenStreams = true

    // MARK: - Gestures
    /// Storage-key name kept as `appBehaviorsAppleTVChannelFlip` for
    /// back-compat: it gates both the Apple TV d-pad flip and the
    /// iPhone / iPad swipe.
    @AppStorage("appBehaviorsAppleTVChannelFlip")
    private var appleTVChannelFlip = true

    #if os(iOS)
    /// AirPlay audio for the receiver (2026-09-21 rebuild): automatic,
    /// passthrough, or stereo AAC. iOS only; tvOS has no AirPlay sender.
    @AppStorage(AirPlayAudioMode.storageKey)
    private var airPlayAudioMode: String = AirPlayAudioMode.defaultMode.rawValue
    @AppStorage(InPlayerEdgeGestures.brightnessKey)
    private var edgeBrightnessGesture = false
    @AppStorage(InPlayerEdgeGestures.volumeKey)
    private var edgeVolumeGesture = false
    /// Which edge owns brightness; volume always takes the other.
    @AppStorage(InPlayerEdgeGestures.brightnessEdgeKey)
    private var brightnessEdge = InPlayerEdgeGestures.defaultBrightnessEdge

    private static let brightnessEdgeChoices: [(value: String, title: String, other: String, icon: String)] = [
        ("left", "Left", "right", "arrow.left.to.line"),
        ("right", "Right", "left", "arrow.right.to.line")
    ]
    #endif

    // MARK: - Multiview
    @AppStorage(MultiviewAudioFocusStyle.storageKey)
    private var audioFocusStyleRaw: String = MultiviewAudioFocusStyle.centerIcon.rawValue
    @AppStorage(multiviewTilePaddingKey)
    private var paddingEnabled: Bool = true
    @AppStorage(multiviewTileCornersRoundedKey)
    private var cornersRounded: Bool = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("Player")
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
            // MARK: Info Card
            // Phase 3, item 4: six bare switches became one master row
            // that says what the card currently shows. The section
            // header is gone because the subgroup row carries the title.
            Section {
                SettingsSubgroup("Info Card",
                                 summary: playerInfoCardSummary,
                                 icon: "rectangle.on.rectangle",
                                 iconColor: theme.accent,
                                 footer: Self.playerInfoCardFooter) {
                    ForEach(playerInfoCardRows, id: \.key) { row in
                        Toggle(isOn: row.binding) {
                            Text(PlayerInfoCardSettings.title(row.key))
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                        }
                        .tint(theme.accent)
                        .listRowBackground(Color.cardBackground)
                    }
                }
                .listRowBackground(Color.cardBackground)
            } header: {
                // Phase 3, item B: the card used to float with no header
                // while every other section on this page had one. The
                // header names the group without repeating the row's own
                // "Info Card" title.
                Text("On-Screen Display").sectionHeaderStyle()
            } footer: {
                Text(Self.playerInfoCardFooter)
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)

            // MARK: Live Rewind
            Section {
                Toggle(isOn: $liveRewindEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause & Rewind Live TV")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Buffer fullscreen live playback on this device")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                // Phase 3, item 4: depth and channel retention used to be
                // two more top-level sections. They are settings ABOUT
                // Live Rewind, so they now sit under one subgroup inside
                // the same card. Every gate and key is unchanged.
                if liveRewindEnabled {
                    SettingsSubgroup("Live Rewind",
                                     summary: liveRewindSummary,
                                     icon: "gobackward.30",
                                     iconColor: theme.accent,
                                     footer: "How far back you can rewind the channel you are watching. Buffered video is released as soon as you leave the channel. Keeping recent channels live holds an extra stream connection per channel; opening a channel beyond the limit drops the oldest.") {
                        SettingsChoicePicker(
                            "Rewind Up To",
                            options: rewindDepthOptions,
                            selection: $liveRewindDepthMinutes,
                            footer: "How far back you can rewind the channel you are watching. Buffered video is released as soon as you leave the channel. \(depthEstimate(liveRewindDepthMinutes))",
                            iconColor: theme.accent
                        )
                        .listRowBackground(Color.cardBackground)

                        Toggle(isOn: $liveRewindRetainChannels) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep Recent Channels Live")
                                    .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                                Text("Flipped-away channels keep buffering so their rewind timeline survives")
                                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                            }
                        }
                        .tint(theme.accent)
                        .listRowBackground(Color.cardBackground)

                        if liveRewindRetainChannels {
                            steppedSliderRow_iOS(
                                title: "Channels to Keep",
                                values: [1, 2, 3, 4, 5],
                                selection: $liveRewindRetainCount,
                                label: { "\($0)" }
                            )
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Live Rewind").sectionHeaderStyle()
            } footer: {
                Text("Buffers the channel you are watching so you can pause and rewind live TV. Uses device storage while you watch; buffered video is removed automatically.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)

            // MARK: Playback
            Section {
                steppedSliderRow_iOS(
                    title: "Skip Back",
                    values: SkipIntervals.choices,
                    selection: $skipBackSeconds,
                    label: { "\($0) seconds" }
                )
                steppedSliderRow_iOS(
                    title: "Skip Forward",
                    values: SkipIntervals.choices,
                    selection: $skipForwardSeconds,
                    label: { "\($0) seconds" }
                )

                StreamBufferSlider(value: $streamBufferSeconds)
                    .listRowBackground(Color.cardBackground)

                // Phase 3, item 3: four inline check rows became one row.
                SettingsChoicePicker(
                    "Buffer Size",
                    options: bufferSizeOptions,
                    selection: $streamBufferSize,
                    footer: "Buffer Size controls how much stream data is pre-loaded. Larger buffers reduce stuttering on poor connections but add startup delay.",
                    iconColor: theme.accent
                )
                .listRowBackground(Color.cardBackground)

                Toggle(isOn: $autoRecoverFrozenStreams) {
                    Text("Auto-Recover Frozen Streams")
                        .scaledFont(.bodyMedium)
                        .foregroundColor(.textPrimary)
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                // AirPlay audio (2026-09-21 rebuild). The Roku constraint
                // lives on the picker's own page footer.
                SettingsChoicePicker(
                    "AirPlay Audio",
                    options: AirPlayAudioMode.allCases.map {
                        SettingsChoice($0.rawValue, $0.displayName, subtitle: $0.subtitle)
                    },
                    selection: $airPlayAudioMode,
                    footer: AirPlayAudioMode.footer,
                    iconColor: theme.accent
                )
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Playback").sectionHeaderStyle()
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How far the skip buttons move in live rewind, catch-up, recordings, movies, and TV shows, including the cast remote and the Lock Screen controls.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    // Phase 3: the Buffer Size sentence moved onto the
                    // picker's own page, so it is not repeated here.
                    Text("Stream Buffer adds extra buffer to smooth jitter and stutter on live streams from any source. Higher is smoother but adds delay behind live. 0 keeps the lowest latency.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    Text("If a live stream stops sending video, the player reloads it to recover. Turn Auto-Recover off if live channels restart or stutter during commercial breaks (a brief freeze may show instead). Applies to the next channel you tune.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    // Short picker labels fit the row; the explanation
                    // lives here (2026-09-25).
                    Text("AirPlay Audio: Automatic keeps surround on Apple TV and Mac receivers and sends AAC stereo to Roku and other TVs. Passthrough sends the original audio; Stereo AAC downmixes for every receiver.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
            }
            .listSectionSeparator(.hidden)

            // MARK: Gestures
            Section {
                Toggle(isOn: $appleTVChannelFlip) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up / Down Channel Change")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("On iPhone & iPad, swipe up on the player for the next channel, swipe down for the previous. On Apple TV, press up or down on the Siri Remote. Live single-stream playback only.")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                Toggle(isOn: $edgeBrightnessGesture) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edge Slide for Brightness")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Slide a finger up or down along one edge of the fullscreen player to change screen brightness.")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                Toggle(isOn: $edgeVolumeGesture) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edge Slide for Volume")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Slide a finger up or down along the other edge of the fullscreen player to change volume.")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                if edgeBrightnessGesture || edgeVolumeGesture {
                    ForEach(Self.brightnessEdgeChoices, id: \.value) { choice in
                        Button {
                            brightnessEdge = choice.value
                        } label: {
                            HStack {
                                Image(systemName: choice.icon)
                                    .scaledFont(.system(size: 15))
                                    .foregroundColor(theme.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Brightness: \(choice.title), Volume: \(choice.other.capitalized)")
                                        .scaledFont(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                }
                                Spacer()
                                if brightnessEdge == choice.value {
                                    Image(systemName: "checkmark")
                                        .scaledFont(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                }
            } header: {
                Text("Gestures").sectionHeaderStyle()
            } footer: {
                Text("Turn the channel flip off if accidental swipes or D-pad presses are flipping channels during playback. The brightness and volume slides are recognized only in a narrow band at the very edge of the screen, so they do not interfere with swiping down for Picture in Picture or with seeking.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)

            // MARK: Multiview
            Section {
                // Phase 3, item 3.
                SettingsChoicePicker(
                    "Audio Focus Indicator",
                    options: audioFocusOptions,
                    selection: $audioFocusStyleRaw,
                    footer: "Choose how Aerio marks the tile that currently owns audio when watching multiple streams at once.",
                    iconColor: theme.accent
                )
                .listRowBackground(Color.cardBackground)

                Toggle(isOn: $paddingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Padding Between Tiles")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Insert a small gap between tiles so each stream stands on its own. Off keeps adjacent tiles meeting flush.")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                // Phase 3, item 3: the last .segmented Picker on this
                // page becomes the same row shape as every other choice.
                SettingsChoicePicker(
                    "Tile Corners",
                    options: tileCornerOptions,
                    selection: $cornersRounded,
                    footer: "Square keeps the cinema-grid look; rounded softens each tile with a 12pt radius.",
                    iconColor: theme.accent
                )
                .listRowBackground(Color.cardBackground)
            } header: {
                // Phase 3: the audio focus and tile corner copy now lives
                // on those pickers' own pages, so the section footer that
                // only restated them is gone.
                Text("Multiview").sectionHeaderStyle()
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        #if os(iOS)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        #endif
        .listStyle(.insetGrouped)
        .id("player-list-\(theme.selectedTheme.rawValue)-\(theme.useCustomAccent ? theme.customAccentHex : "preset")")
    }

    /// Discrete-stop slider row over an Int ladder: label left, current
    /// value right, stepped Slider below.
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
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(label(values[idx]))
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
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
                // Phase 3, item 4: the six info-card switches now sit
                // under a master row that summarizes them, same strings
                // as iOS.
                // No SettingsSection wrapper: the subgroup's master row
                // already says "Info Card", so a section header above it
                // labeled the same group twice. The subgroup draws the
                // card itself.
                // Same "On-Screen Display" eyebrow the phone uses, so the page
                // does not open on a headerless card.
                SettingsSection("On-Screen Display", style: .plain) {
                    SettingsSubgroup("Info Card",
                                     summary: playerInfoCardSummary,
                                     icon: "rectangle.on.rectangle",
                                     iconColor: theme.accent,
                                     footer: Self.playerInfoCardFooter,
                                     drawsCard: false,
                                     optionsOnly: true) {
                            ForEach(playerInfoCardRows, id: \.key) { row in
                                TVSettingsToggleRow(
                                    icon: "info.circle",
                                    iconColor: theme.accent,
                                    title: PlayerInfoCardSettings.title(row.key),
                                    subtitle: "",
                                    isOn: row.binding
                                ) { _ in }
                        }
                    }
                }

                // Phase 3, item 4: "Keep Available" and "Channel
                // Retention" were two more cards for settings that only
                // exist because Live Rewind is on. One card now.
                SettingsSection("Live Rewind", style: .plain) {
                    TVSettingsToggleRow(
                        icon: "gobackward.30",
                        iconColor: theme.accent,
                        title: "Pause & Rewind Live TV",
                        subtitle: "Buffer fullscreen live playback on this Apple TV",
                        isOn: $liveRewindEnabled
                    ) { _ in }
                    tvFooter("Buffers the channel you are watching so you can pause and rewind live TV. Uses device storage while you watch; buffered video is removed automatically.")

                    if liveRewindEnabled {
                        // No master row here: the section header and the
                        // toggle above it already say "Live Rewind", and a
                        // third label for the same group is noise on a TV.
                        // iPhone still pushes a page titled "Live Rewind".
                        SettingsSubgroup("Live Rewind",
                                         summary: liveRewindSummary,
                                         icon: "gobackward.30",
                                         iconColor: theme.accent,
                                         showsMasterRow: false) {
                            SettingsChoicePicker(
                                "Rewind Up To",
                                options: rewindDepthOptions,
                                selection: $liveRewindDepthMinutes,
                                footer: "How far back you can rewind the channel you are watching. Buffered video is released as soon as you leave the channel. \(depthEstimate(liveRewindDepthMinutes))"
                            )

                            TVSettingsToggleRow(
                                icon: "rectangle.stack.badge.play",
                                iconColor: theme.accent,
                                title: "Keep Recent Channels Live",
                                subtitle: "Flipped-away channels keep buffering so their rewind timeline survives",
                                isOn: $liveRewindRetainChannels
                            ) { _ in }
                            if liveRewindRetainChannels {
                                tvSteppedSegmentsRow(
                                    title: "Channels to Keep",
                                    values: [1, 2, 3, 4, 5],
                                    selection: $liveRewindRetainCount,
                                    segmentLabel: { "\($0)" }
                                )
                            }
                            tvFooter("Each kept channel holds an extra stream connection and uses bandwidth while it runs. Opening a channel beyond the limit drops the oldest.")
                        }
                    }
                }

                SettingsSection("Playback", style: .plain) {
                    tvSteppedSegmentsRow(
                        title: "Skip Back",
                        values: SkipIntervals.choices,
                        selection: $skipBackSeconds,
                        segmentLabel: { "\($0)s" }
                    )
                    tvSteppedSegmentsRow(
                        title: "Skip Forward",
                        values: SkipIntervals.choices,
                        selection: $skipForwardSeconds,
                        segmentLabel: { "\($0)s" }
                    )
                    tvFooter("How far the skip buttons and a single left or right press move in live rewind, catch-up, recordings, movies, and TV shows. Holding left or right still scrubs faster the longer you hold.")

                    StreamBufferSlider(value: $streamBufferSeconds)
                    tvFooter("Extra buffer to smooth jitter and stutter on live streams from any source. Higher is smoother but adds delay behind live. 0 keeps the lowest latency. Applies to the next channel you tune. Press left or right on the Siri Remote to adjust.")

                    // Phase 3, item 3: same option list as iOS.
                    SettingsChoicePicker(
                        "Buffer Size",
                        options: bufferSizeOptions,
                        selection: $streamBufferSize,
                        footer: "Buffer Size controls how much stream data is pre-loaded. Larger buffers reduce stuttering on poor connections but add startup delay."
                    )

                    TVSettingsToggleRow(
                        icon: "arrow.clockwise.circle",
                        iconColor: theme.accent,
                        title: "Auto-Recover Frozen Streams",
                        subtitle: "If a live stream stops sending video, the player reloads it to recover. Turn this off if live channels restart or stutter during commercial breaks; a brief freeze may show instead.",
                        isOn: $autoRecoverFrozenStreams
                    ) { _ in }
                }

                SettingsSection("Gestures", style: .plain) {
                    TVSettingsToggleRow(
                        icon: "arrow.up.and.down",
                        iconColor: theme.accent,
                        title: "Up / Down Channel Change",
                        subtitle: "Press up on the Siri Remote for the next channel, down for the previous. Live single-stream playback only.",
                        isOn: $appleTVChannelFlip
                    ) { _ in }

                    tvFooter("Turn off if accidental D-pad presses are flipping channels during playback. iPhone & iPad use the matching swipe-up / swipe-down gesture on the same toggle.")
                }

                SettingsSection("Multiview", style: .plain) {
                    // Phase 3, item 3.
                    SettingsChoicePicker(
                        "Audio Focus Indicator",
                        options: audioFocusOptions,
                        selection: $audioFocusStyleRaw,
                        footer: "Choose how Aerio marks the tile that currently owns audio when watching multiple streams at once."
                    )

                    TVSettingsToggleRow(
                        icon: "rectangle.split.2x1",
                        iconColor: theme.accent,
                        title: "Padding Between Tiles",
                        subtitle: "Insert a small gap between tiles so each stream stands on its own.",
                        isOn: $paddingEnabled,
                        onChange: { _ in }
                    )

                    // Phase 3, item 3.
                    SettingsChoicePicker(
                        "Tile Corners",
                        options: tileCornerOptions,
                        selection: $cornersRounded,
                        footer: "Square keeps the cinema-grid look; rounded softens each tile with a 12pt radius."
                    )
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tvFooter(_ text: String) -> some View {
        Text(text)
            .scaledFont(.system(size: 22).subtext())
            .foregroundColor(Color.contrastText(.textTertiary))
            .padding(.horizontal, 20)
            .padding(.top, 4)
    }

    /// tvOS discrete ladder row: title left, one focusable segment per
    /// stop. Snaps legacy/custom persisted values to the nearest stop.
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
                .scaledFont(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer()
            ForEach(values, id: \.self) { value in
                TVSettingsPill(segmentLabel(value),
                               isSelected: value == current) {
                    selection.wrappedValue = value
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
