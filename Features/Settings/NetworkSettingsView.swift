//
//  NetworkSettingsView.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

private struct BufferOption: Identifiable {
    let id: String
    let label: String
    let detail: String  // human-readable size
    let cachingMs: Int  // VLC :network-caching value in milliseconds
}
private let bufferOptions: [BufferOption] = [
    BufferOption(id: "small",   label: "Small",       detail: "300 ms — fast, stable networks",   cachingMs: 300),
    BufferOption(id: "default", label: "Default",     detail: "1 second — recommended",           cachingMs: 1_000),
    BufferOption(id: "large",   label: "Large",       detail: "3 seconds — unstable connections", cachingMs: 3_000),
    BufferOption(id: "xlarge",  label: "Extra Large", detail: "8 seconds — very poor networks",   cachingMs: 8_000),
]


struct NetworkSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("networkTimeout")          private var networkTimeout      = 15.0
    @AppStorage("maxRetries")              private var maxRetries          = 3
    @AppStorage("streamBufferSize")        private var streamBufferSize    = "default"
    @AppStorage("epgWindowHours")           private var epgWindowHours      = 36          // default 36 hours
    /// Tint EPG program cells by their category (Sports / Movies /
    /// Kids / News). Mirrors the `CategoryColor.enabledKey` constant
    /// — default `true`, so the category palette is on out of the box
    /// and users who prefer the flat neutral cells can disable it here.
    @AppStorage(CategoryColor.enabledKey)   private var enableCategoryColors = true
    /// Companion toggle that extends the category palette from the EPG
    /// guide cells to the Live TV channel cards. Opt-in and default off
    /// so existing users don't suddenly see colored stripes appear on every row.
    @AppStorage("tintChannelCards")         private var tintChannelCards     = false
    /// User-controllable scale factor applied to the EPG grid layout
    /// (cell width, row height, header height, pixels-per-hour, and
    /// per-cell font sizes). Range 0.75…1.5 in 0.05 increments,
    /// default 1.0 (today's "100%" sizing). Read by `EPGGuideView` and
    /// `GuideProgramButton` via the same `"guideScale"` key. Only
    /// surfaced on iPad and Mac — iPhone uses the list view, tvOS uses
    /// the Siri Remote which makes a slider awkward.
    @AppStorage("guideScale")              private var guideScale          = 1.0
    @AppStorage("bgRefreshEnabled")        private var bgRefreshEnabled    = false
    @AppStorage("bgRefreshType")           private var bgRefreshType       = "interval"  // "interval" or "time"
    @AppStorage("bgRefreshIntervalMins")   private var bgRefreshInterval   = 1440        // 24 hours
    @AppStorage("bgRefreshHour")           private var bgRefreshHour       = 8
    @AppStorage("bgRefreshMinute")         private var bgRefreshMinute     = 0

    // Converts stored hour/minute back to a Date for DatePicker binding
    private var refreshTimeDateBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour   = bgRefreshHour
                comps.minute = bgRefreshMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                let comps      = Calendar.current.dateComponents([.hour, .minute], from: date)
                bgRefreshHour   = comps.hour   ?? 8
                bgRefreshMinute = comps.minute ?? 0
            }
        )
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
        .navigationTitle("Network")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    // MARK: - tvOS Body
    // Uses the shared TVSettings* components so focus highlights match
    // Appearance / DVR / Developer / top-level Settings uniformly. The
    // previous implementation was a bare List + Button rows which on
    // tvOS only rendered the default thin system focus ring.
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvSection("Request Timeout") {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { secs in
                        TVSettingsSelectionRow(
                            label: "\(secs) seconds",
                            isSelected: Int(networkTimeout) == secs,
                            action: { networkTimeout = Double(secs) }
                        )
                    }
                }

                tvSection("Buffer Size") {
                    ForEach(bufferOptions) { opt in
                        TVSettingsSelectionRow(
                            label: opt.label,
                            subtitle: opt.detail,
                            isSelected: streamBufferSize == opt.id,
                            action: { streamBufferSize = opt.id }
                        )
                    }
                }

                tvSection("EPG Window") {
                    let options: [(label: String, hours: Int)] = [
                        ("6 hours",  6),
                        ("12 hours", 12),
                        ("24 hours", 24),
                        ("36 hours", 36),
                        ("48 hours", 48),
                        ("72 hours", 72),
                        ("All available", 0),
                    ]
                    ForEach(options, id: \.hours) { opt in
                        TVSettingsSelectionRow(
                            label: opt.label,
                            isSelected: epgWindowHours == opt.hours,
                            action: { epgWindowHours = opt.hours }
                        )
                    }
                }

                // Category-colour palette + EPG cache controls moved
                // to `AppearanceSettingsView` in v1.6.8 — Settings →
                // App Settings → Appearance — alongside the theme +
                // scale sliders, since they're all visual concerns.
            }
            // v1.7.5: centered 1200pt reading column (matches EditServerPage).
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(48)
            .frame(maxWidth: .infinity)
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

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
                // MARK: Connection
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Request Timeout")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Text("\(Int(networkTimeout))s")
                                .font(.monoSmall)
                                .foregroundColor(theme.accent)
                        }
                        Slider(value: $networkTimeout, in: 5...60, step: 5)
                            .tint(theme.accent)
                    }
                    .listRowBackground(Color.cardBackground)

                    Stepper("Max Retries: \(maxRetries)", value: $maxRetries, in: 0...10)
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Connection").sectionHeaderStyle()
                } footer: {
                    Text("Adjust timeouts if you have a slow connection.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }

                // MARK: Buffer Size
                Section {
                    ForEach(bufferOptions) { opt in
                        Button {
                            streamBufferSize = opt.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.label)
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    Text(opt.detail)
                                        .font(.labelSmall)
                                        .foregroundColor(.textSecondary)
                                }
                                Spacer()
                                if streamBufferSize == opt.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("Buffer Size").sectionHeaderStyle()
                } footer: {
                    Text("Controls how much stream data is pre-loaded. Larger buffers reduce stuttering on poor connections but add startup delay.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }

                // MARK: EPG Window
                Section {
                    let options: [(label: String, hours: Int)] = [
                        ("6 hours",  6),
                        ("12 hours", 12),
                        ("24 hours", 24),
                        ("36 hours", 36),
                        ("48 hours", 48),
                        ("72 hours", 72),
                        ("All available", 0),
                    ]
                    ForEach(options, id: \.hours) { opt in
                        Button {
                            epgWindowHours = opt.hours
                        } label: {
                            HStack {
                                Text(opt.label)
                                    .font(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                if epgWindowHours == opt.hours {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text("EPG Window").sectionHeaderStyle()
                } footer: {
                    Text("How far ahead to download program guide data. Larger windows take longer to download but show more upcoming programs.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }

                // Category-colour palette + EPG cache controls moved
                // to `AppearanceSettingsView` in v1.6.8 — Settings →
                // App Settings → Appearance. They were originally
                // here under Network, then briefly had their own
                // top-level "Guide Display" page; consolidating into
                // Appearance removes the duplication and matches the
                // user's mental model (visual customisation in one
                // place).

                // MARK: Background Refresh
                Section {
                    Toggle(isOn: $bgRefreshEnabled) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundColor(theme.accent)
                                .font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Background Refresh")
                                    .font(.bodyMedium).foregroundColor(.textPrimary)
                                Text("Update EPG & playlists automatically")
                                    .font(.labelSmall).foregroundColor(.textSecondary)
                            }
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)

                    if bgRefreshEnabled {
                        // Refresh type picker
                        Picker("Refresh by", selection: $bgRefreshType) {
                            Text("Every…").tag("interval")
                            Text("At time").tag("time")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.cardBackground)

                        if bgRefreshType == "interval" {
                            // Interval picker
                            let intervals: [(label: String, mins: Int)] = [
                                ("15 minutes", 15), ("30 minutes", 30),
                                ("1 hour", 60),     ("2 hours", 120),
                                ("4 hours", 240),   ("8 hours", 480),
                                ("12 hours", 720),  ("24 hours", 1440),
                            ]
                            ForEach(intervals, id: \.mins) { item in
                                Button {
                                    bgRefreshInterval = item.mins
                                } label: {
                                    HStack {
                                        Text(item.label)
                                            .font(.bodyMedium).foregroundColor(.textPrimary)
                                        Spacer()
                                        if bgRefreshInterval == item.mins {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(theme.accent)
                                                .font(.system(size: 14, weight: .semibold))
                                        }
                                    }
                                }
                                .listRowBackground(Color.cardBackground)
                            }
                        } else {
                            // Specific time picker (12-hour format with AM/PM)
                            #if os(iOS)
                            DatePicker(
                                "Refresh at",
                                selection: refreshTimeDateBinding,
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.graphical)
                            .environment(\.locale, Locale(identifier: "en_US"))
                            .tint(theme.accent)
                            .foregroundColor(.textPrimary)
                            .listRowBackground(Color.cardBackground)
                            #endif
                        }
                    }
                } header: {
                    Text("Background Refresh").sectionHeaderStyle()
                } footer: {
                    if bgRefreshEnabled {
                        let desc = bgRefreshType == "interval"
                            ? "Refresh every \(intervalLabel(bgRefreshInterval))."
                            : "Refresh daily at \(timeLabel(hour: bgRefreshHour, minute: bgRefreshMinute))."
                        Text("\(desc) iOS may delay or skip background refreshes to preserve battery.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    } else {
                        Text("Automatically refresh channel lists and guide data while the app is in the background.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
    }
    #endif

    private func intervalLabel(_ mins: Int) -> String {
        if mins < 60 { return "\(mins) minutes" }
        let h = mins / 60
        return h == 1 ? "1 hour" : "\(h) hours"
    }

    private func timeLabel(hour: Int, minute: Int) -> String {
        let h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let ampm = hour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h12, minute, ampm)
    }
}

// MARK: - Category Color Picker Row (iOS only)
//
// One row in Settings → Appearance (Palette section) that binds a SwiftUI
// `ColorPicker` to the hex-string stored at the bucket's
// `storageKey`. The binding converts between `Color` (what
// ColorPicker speaks) and the hex string (what UserDefaults
// persists). `@AppStorage` observes the underlying key, so any
// open guide view re-renders its cells the moment the user lifts
// their finger off the ColorPicker's eyedropper — no apply
// button needed.
//
// tvOS is intentionally excluded: the system ColorPicker on tvOS
// is awkward (two-axis hue/saturation grid with Siri Remote
// trackpad). We surface only the on/off toggle there and point
// users to iPhone/iPad for palette customisation.
#if os(iOS)
#endif  // Phase 1 split: closes a block that spanned the extraction cut
