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
            Section {
                ForEach(playerInfoCardRows, id: \.key) { row in
                    Toggle(isOn: row.binding) {
                        Text(PlayerInfoCardSettings.title(row.key))
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Info Card").sectionHeaderStyle()
            } footer: {
                Text(Self.playerInfoCardFooter)
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)

            // MARK: Live Rewind
            Section {
                Toggle(isOn: $liveRewindEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause & rewind live TV")
                            .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        Text("Buffer fullscreen live playback on this device")
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Live Rewind").sectionHeaderStyle()
            } footer: {
                Text("Buffers the channel you are watching so you can pause and rewind live TV. Uses device storage while you watch; buffered video is removed automatically.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
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
                    Text("How far back you can rewind the channel you are watching. Buffered video is released as soon as you leave the channel. \(depthEstimate(liveRewindDepthMinutes))")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)

                Section {
                    Toggle(isOn: $liveRewindRetainChannels) {
                        Text("Keep Recent Channels Live")
                    }
                    if liveRewindRetainChannels {
                        steppedSliderRow_iOS(
                            title: "Channels to keep",
                            values: [1, 2, 3, 4, 5],
                            selection: $liveRewindRetainCount,
                            label: { "\($0)" }
                        )
                    }
                } header: {
                    Text("Channel Retention").sectionHeaderStyle()
                } footer: {
                    Text("Keeps recently watched channels buffering after you flip away, so returning brings the full rewind timeline back. Each kept channel holds an extra stream connection and uses bandwidth while it runs. Opening a channel beyond the limit drops the oldest.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)
            }

            // MARK: Playback
            Section {
                steppedSliderRow_iOS(
                    title: "Skip back",
                    values: SkipIntervals.choices,
                    selection: $skipBackSeconds,
                    label: { "\($0) seconds" }
                )
                steppedSliderRow_iOS(
                    title: "Skip forward",
                    values: SkipIntervals.choices,
                    selection: $skipForwardSeconds,
                    label: { "\($0) seconds" }
                )

                StreamBufferSlider(value: $streamBufferSeconds)
                    .listRowBackground(Color.cardBackground)

                ForEach(bufferOptions) { opt in
                    Button {
                        streamBufferSize = opt.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.label)
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Text(opt.detail)
                                    .scaledFont(.labelSmall.subtext())
                                    .foregroundColor(Color.contrastText(.textSecondary))
                            }
                            Spacer()
                            if streamBufferSize == opt.id {
                                Image(systemName: "checkmark")
                                    .scaledFont(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.accent)
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }

                Toggle(isOn: $autoRecoverFrozenStreams) {
                    Text("Auto-Recover Frozen Streams")
                        .scaledFont(.bodyMedium)
                        .foregroundColor(.textPrimary)
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Playback").sectionHeaderStyle()
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How far the skip buttons move in live rewind, catch-up, recordings, movies, and TV shows, including the cast remote and the Lock Screen controls.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    Text("Stream Buffer adds extra buffer to smooth jitter and stutter on live streams from any source. Higher is smoother but adds delay behind live. 0 keeps the lowest latency. Buffer Size controls how much stream data is pre-loaded. Larger buffers reduce stuttering on poor connections but add startup delay.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    Text("If a live stream stops sending video, the player reloads it to recover. Turn Auto-Recover off if live channels restart or stutter during commercial breaks (a brief freeze may show instead). Applies to the next channel you tune.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
            }
            .listSectionSeparator(.hidden)

            // MARK: Gestures
            Section {
                Toggle(isOn: $appleTVChannelFlip) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up / Down channel change")
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
                        Text("Edge slide for brightness")
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
                        Text("Edge slide for volume")
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
                ForEach(MultiviewAudioFocusStyle.allCases) { style in
                    Button {
                        audioFocusStyleRaw = style.rawValue
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(style.displayName)
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Text(style.subtitle)
                                    .scaledFont(.labelSmall.subtext())
                                    .foregroundColor(Color.contrastText(.textTertiary))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if selectedStyle == style {
                                Image(systemName: "checkmark")
                                    .scaledFont(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.accent)
                                    .padding(.top, 2)
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }

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

                Picker("Tile Corners", selection: $cornersRounded) {
                    Text("Square").tag(false)
                    Text("Rounded").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Multiview").sectionHeaderStyle()
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Choose how Aerio marks the tile that currently owns audio when watching multiple streams at once.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    Text("Square keeps the cinema-grid look; rounded softens each tile with a 12pt radius.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
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
                SettingsSection("Info Card", style: .card) {
                    ForEach(playerInfoCardRows, id: \.key) { row in
                        TVSettingsToggleRow(
                            icon: "info.circle",
                            iconColor: theme.accent,
                            title: PlayerInfoCardSettings.title(row.key),
                            subtitle: "",
                            isOn: row.binding
                        ) { _ in }
                    }

                    tvFooter(Self.playerInfoCardFooter)
                }

                SettingsSection("Live Rewind", style: .card) {
                    TVSettingsToggleRow(
                        icon: "gobackward.30",
                        iconColor: theme.accent,
                        title: "Pause & Rewind Live TV",
                        subtitle: "Buffer fullscreen live playback on this Apple TV",
                        isOn: $liveRewindEnabled
                    ) { _ in }
                    tvFooter("Buffers the channel you are watching so you can pause and rewind live TV. Uses device storage while you watch; buffered video is removed automatically.")
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
                        tvFooter("How far back you can rewind the channel you are watching. Buffered video is released as soon as you leave the channel. \(depthEstimate(liveRewindDepthMinutes))")
                    }

                    SettingsSection("Channel Retention", style: .card) {
                        TVSettingsToggleRow(
                            icon: "rectangle.stack.badge.play",
                            iconColor: theme.accent,
                            title: "Keep Recent Channels Live",
                            subtitle: "Flipped-away channels keep buffering so their rewind timeline survives",
                            isOn: $liveRewindRetainChannels
                        ) { _ in }
                        if liveRewindRetainChannels {
                            tvSteppedSegmentsRow(
                                title: "Channels to keep",
                                values: [1, 2, 3, 4, 5],
                                selection: $liveRewindRetainCount,
                                segmentLabel: { "\($0)" }
                            )
                        }
                        tvFooter("Each kept channel holds an extra stream connection and uses bandwidth while it runs. Opening a channel beyond the limit drops the oldest.")
                    }
                }

                SettingsSection("Playback", style: .card) {
                    tvSteppedSegmentsRow(
                        title: "Skip back",
                        values: SkipIntervals.choices,
                        selection: $skipBackSeconds,
                        segmentLabel: { "\($0)s" }
                    )
                    tvSteppedSegmentsRow(
                        title: "Skip forward",
                        values: SkipIntervals.choices,
                        selection: $skipForwardSeconds,
                        segmentLabel: { "\($0)s" }
                    )
                    tvFooter("How far the skip buttons and a single left or right press move in live rewind, catch-up, recordings, movies, and TV shows. Holding left or right still scrubs faster the longer you hold.")

                    StreamBufferSlider(value: $streamBufferSeconds)
                    tvFooter("Extra buffer to smooth jitter and stutter on live streams from any source. Higher is smoother but adds delay behind live. 0 keeps the lowest latency. Applies to the next channel you tune. Press left or right on the Siri Remote to adjust.")

                    ForEach(bufferOptions) { opt in
                        TVSettingsSelectionRow(
                            label: opt.label,
                            subtitle: opt.detail,
                            isSelected: streamBufferSize == opt.id,
                            action: { streamBufferSize = opt.id }
                        )
                    }
                    tvFooter("Buffer Size controls how much stream data is pre-loaded. Larger buffers reduce stuttering on poor connections but add startup delay.")

                    TVSettingsToggleRow(
                        icon: "arrow.clockwise.circle",
                        iconColor: theme.accent,
                        title: "Auto-Recover Frozen Streams",
                        subtitle: "If a live stream stops sending video, the player reloads it to recover. Turn this off if live channels restart or stutter during commercial breaks; a brief freeze may show instead.",
                        isOn: $autoRecoverFrozenStreams
                    ) { _ in }
                }

                SettingsSection("Gestures", style: .card) {
                    TVSettingsToggleRow(
                        icon: "arrow.up.and.down",
                        iconColor: theme.accent,
                        title: "Up / Down Channel Change",
                        subtitle: "Press up on the Siri Remote for the next channel, down for the previous. Live single-stream playback only.",
                        isOn: $appleTVChannelFlip
                    ) { _ in }

                    tvFooter("Turn off if accidental D-pad presses are flipping channels during playback. iPhone & iPad use the matching swipe-up / swipe-down gesture on the same toggle.")
                }

                SettingsSection("Multiview", style: .card) {
                    ForEach(MultiviewAudioFocusStyle.allCases) { style in
                        TVSettingsSelectionRow(
                            label: style.displayName,
                            subtitle: style.subtitle,
                            isSelected: selectedStyle == style,
                            action: { audioFocusStyleRaw = style.rawValue }
                        )
                    }

                    TVSettingsToggleRow(
                        icon: "rectangle.split.2x1",
                        iconColor: theme.accent,
                        title: "Padding Between Tiles",
                        subtitle: "Insert a small gap between tiles so each stream stands on its own.",
                        isOn: $paddingEnabled,
                        onChange: { _ in }
                    )

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
                Button {
                    selection.wrappedValue = value
                } label: {
                    Text(segmentLabel(value))
                        .scaledFont(.system(size: 22, weight: .medium))
                }
                .buttonStyle(TVSteppedSegmentStyle(isSelected: value == current))
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
