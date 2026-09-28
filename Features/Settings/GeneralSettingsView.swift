//
//  GeneralSettingsView.swift
//  Aerio
//
//  Settings redesign Phase 1 (regroup, 2026-09-17). The device-level
//  behavior page: what the app does at launch, when it refreshes in the
//  background, and how it talks to the network.
//
//  This file is the former NetworkSettingsView.swift; the launch rows come
//  from App Behaviors, and Buffer Size moved to the Player page. No
//  persisted key changed in the move.
//

import SwiftUI
import SwiftData

struct GeneralSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Query private var servers: [ServerConnection]

    // MARK: Startup
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    @AppStorage("appBehaviorsSkipLoadingScreen")
    private var skipLoadingScreen = false
    @AppStorage("appBehaviorsAutoResumeLastChannel")
    private var autoResumeLastChannel = false
    #if os(iOS)
    @AppStorage(AppOrientationLock.autoRotateKey)
    private var autoRotate = true
    #endif

    /// Default Landing Tab choices, minus any tab the active Dispatcharr
    /// account is not permitted to see. UNKNOWN never removes a row.
    private var selectableTabs: [AppTab] {
        guard let active = servers.first(where: { $0.isActive }) ?? servers.first else {
            return AppTab.selectable
        }
        return AppTab.selectable.filter { tab in
            switch tab {
            case .dvr:     return active.dispatcharrCanViewDVR
            case .movies:  return active.dispatcharrCanViewVOD
            case .tvShows: return active.dispatcharrCanViewSeries
            default:       return true
            }
        }
    }

    // MARK: Refresh
    @AppStorage("bgRefreshEnabled")        private var bgRefreshEnabled    = false
    @AppStorage("bgRefreshType")           private var bgRefreshType       = "interval"  // "interval" or "time"
    @AppStorage("bgRefreshIntervalMins")   private var bgRefreshInterval   = 1440        // 24 hours
    @AppStorage("bgRefreshHour")           private var bgRefreshHour       = 8
    @AppStorage("bgRefreshMinute")         private var bgRefreshMinute     = 0

    // MARK: Network
    @AppStorage("networkTimeout")          private var networkTimeout      = 15.0
    @AppStorage("maxRetries")              private var maxRetries          = 3

    // MARK: Choice options
    // Shared by both platforms so the strings cannot drift apart.

    /// Background Refresh schedule kinds. Values are the stored
    /// bgRefreshType strings and must not change.
    private static let scheduleOptions: [SettingsChoice<String>] = [
        SettingsChoice("interval", "Interval", subtitle: "Repeat on a timer"),
        SettingsChoice("time", "Time of Day", subtitle: "Once a day at a set time")
    ]

    /// Background Refresh intervals, in minutes (bgRefreshIntervalMins).
    private static let intervalOptions: [SettingsChoice<Int>] = [
        SettingsChoice(15, "15 Minutes"),
        SettingsChoice(30, "30 Minutes"),
        SettingsChoice(60, "1 Hour"),
        SettingsChoice(120, "2 Hours"),
        SettingsChoice(240, "4 Hours"),
        SettingsChoice(480, "8 Hours"),
        SettingsChoice(720, "12 Hours"),
        SettingsChoice(1440, "24 Hours")
    ]

    /// Request timeout choices, in seconds (networkTimeout).
    private static let timeoutOptions: [SettingsChoice<Int>] = [
        SettingsChoice(5, "5 Seconds"),
        SettingsChoice(10, "10 Seconds"),
        SettingsChoice(15, "15 Seconds"),
        SettingsChoice(30, "30 Seconds"),
        SettingsChoice(60, "60 Seconds")
    ]

    /// networkTimeout is stored as a Double; the picker works in whole
    /// seconds. Same key, same stored value.
    private var networkTimeoutSeconds: Binding<Int> {
        Binding(
            get: { Int(networkTimeout) },
            set: { networkTimeout = Double($0) }
        )
    }

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
        .navigationTitle("General")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    // MARK: - tvOS Body

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                SettingsSection("Startup", style: .plain) {
                    // Phase 3, item 3: the hand-rolled tab list is now one
                    // SettingsChoicePicker so Startup asks its question the
                    // same way every other page does.
                    SettingsChoicePicker(
                        "Default Landing Tab",
                        options: selectableTabs.map {
                            SettingsChoice($0.rawValue, $0.title, icon: $0.icon)
                        },
                        selection: $defaultTabRaw,
                        footer: "The tab shown when the app first launches."
                    )

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

                SettingsSection("Network", style: .plain) {
                    // Phase 3, item A: the hand-rolled timeout list is now
                    // one SettingsChoicePicker. Key networkTimeout unchanged.
                    SettingsChoicePicker(
                        "Request Timeout",
                        options: Self.timeoutOptions,
                        selection: networkTimeoutSeconds,
                        footer: "Raise the timeout if you have a slow connection."
                    )
                }
            }
            // v1.7.5: centered 1200pt reading column (matches EditServerPage).
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(48)
            .frame(maxWidth: .infinity)
        }
    }
    #endif

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            // MARK: Startup
            Section {
                // Phase 3, item 3: one row that pushes the choice page
                // instead of a check list that pushed the toggles below it
                // off screen. The footer moved onto the pushed page.
                SettingsChoicePicker(
                    "Default Landing Tab",
                    options: selectableTabs.map {
                        SettingsChoice($0.rawValue, $0.title, icon: $0.icon)
                    },
                    selection: $defaultTabRaw,
                    footer: "The tab shown when the app first launches."
                )
                .listRowBackground(Color.cardBackground)

                Toggle(isOn: $skipLoadingScreen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip Loading Screen")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text("Land on Live TV instantly; data hydrates in the background")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Toggle(isOn: $autoResumeLastChannel) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resume last channel")
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text("Auto-start the last-played channel in the corner mini-player on launch")
                                .scaledFont(.labelSmall.subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                        }
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                }

                Toggle(isOn: $autoRotate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Rotate")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Text(UIDevice.current.userInterfaceIdiom == .pad
                             ? "Follow the device orientation. When off, AerioTV stays in its current orientation"
                             : "Follow the device orientation. When off, AerioTV stays portrait")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)
                .onChange(of: autoRotate) { _, _ in
                    AppOrientationLock.refreshBase()
                }
            } header: {
                Text("Startup").sectionHeaderStyle()
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    // Phase 3: the landing-tab line lives on the picker's
                    // pushed page now, so it is not repeated here.
                    Text(UIDevice.current.userInterfaceIdiom == .pad
                         ? "Skipping the loading screen may cause brief UI stutter while data loads. Resume picks up the last channel you watched in the corner mini-player; press Play/Pause to expand."
                         : "Skipping the loading screen may cause brief UI stutter while data loads.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    Text("The player's fullscreen button can still rotate into landscape either way.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
            }
            .listSectionSeparator(.hidden)

            // MARK: Refresh
            Section {
                Toggle(isOn: $bgRefreshEnabled) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(theme.accent)
                            .scaledFont(.system(size: 18))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Background Refresh")
                                .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                            Text("Update EPG & playlists automatically")
                                .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textSecondary))
                        }
                    }
                }
                .tint(theme.accent)
                .listRowBackground(Color.cardBackground)

                if bgRefreshEnabled {
                    // Phase 3, item A: the segmented control and the
                    // eight-row interval list became sub-page pickers,
                    // the same shape the rest of Settings uses. Keys
                    // (bgRefreshType, bgRefreshIntervalMins) unchanged.
                    SettingsChoicePicker(
                        "Schedule",
                        options: Self.scheduleOptions,
                        selection: $bgRefreshType,
                        footer: "Interval refreshes on a repeating timer. Time of Day refreshes once a day at the time you pick.",
                        iconColor: theme.accent
                    )
                    .listRowBackground(Color.cardBackground)

                    if bgRefreshType == "interval" {
                        SettingsChoicePicker(
                            "Interval",
                            options: Self.intervalOptions,
                            selection: $bgRefreshInterval,
                            footer: "How often AerioTV asks for fresh channel lists and guide data.",
                            iconColor: theme.accent
                        )
                        .listRowBackground(Color.cardBackground)
                    } else {
                        DatePicker(
                            "Refresh At",
                            selection: refreshTimeDateBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .tint(theme.accent)
                        .foregroundColor(.textPrimary)
                        .listRowBackground(Color.cardBackground)
                    }
                }
            } header: {
                Text("Refresh").sectionHeaderStyle()
            } footer: {
                if bgRefreshEnabled {
                    let desc = bgRefreshType == "interval"
                        ? "Refresh every \(intervalLabel(bgRefreshInterval))."
                        : "Refresh daily at \(timeLabel(hour: bgRefreshHour, minute: bgRefreshMinute))."
                    Text("\(desc) iOS may delay or skip background refreshes to preserve battery.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                } else {
                    Text("Automatically refresh channel lists and guide data while the app is in the background.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
            }
            .listSectionSeparator(.hidden)

            // MARK: Network
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Request Timeout")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Text("\(Int(networkTimeout))s")
                            .scaledFont(.monoSmall)
                            .foregroundColor(Color.contrastText(theme.accent))
                    }
                    Slider(value: $networkTimeout, in: 5...60, step: 5)
                        .tint(theme.accent)
                }
                .listRowBackground(Color.cardBackground)

                // Title left, value trailing in accent mono, exactly like
                // Request Timeout above it. The old "Max Retries: 3" label
                // was the only row in Settings that put its value inside
                // the title (Logan screenshots 2026-09-18).
                Stepper(value: $maxRetries, in: 0...10) {
                    HStack {
                        Text("Max Retries")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Text("\(maxRetries)")
                            .scaledFont(.monoSmall)
                            .foregroundColor(Color.contrastText(theme.accent))
                    }
                }
                .listRowBackground(Color.cardBackground)
            } header: {
                Text("Network").sectionHeaderStyle()
            } footer: {
                Text("Adjust timeouts if you have a slow connection.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)
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
