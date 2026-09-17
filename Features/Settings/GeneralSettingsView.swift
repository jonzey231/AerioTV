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
                    ForEach(selectableTabs, id: \.self) { tab in
                        TVSettingsSelectionRow(
                            icon: tab.icon,
                            iconColor: theme.accent,
                            label: tab.title,
                            isSelected: defaultTabRaw == tab.rawValue,
                            action: { defaultTabRaw = tab.rawValue }
                        )
                    }

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
                    ForEach([5, 10, 15, 30, 60], id: \.self) { secs in
                        TVSettingsSelectionRow(
                            label: "\(secs) seconds",
                            isSelected: Int(networkTimeout) == secs,
                            action: { networkTimeout = Double(secs) }
                        )
                    }
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
                ForEach(selectableTabs, id: \.self) { tab in
                    Button {
                        defaultTabRaw = tab.rawValue
                    } label: {
                        HStack {
                            Image(systemName: tab.icon)
                                .scaledFont(.system(size: 15))
                                .foregroundColor(theme.accent)
                                .frame(width: 24)
                            Text(tab.title)
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            if defaultTabRaw == tab.rawValue {
                                Image(systemName: "checkmark")
                                    .scaledFont(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.accent)
                            }
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }

                Toggle(isOn: $skipLoadingScreen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip loading screen")
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
                        Text("Auto-rotate")
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
                    Text("The tab shown when the app first launches.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
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
                    Picker("Refresh by", selection: $bgRefreshType) {
                        Text("Every…").tag("interval")
                        Text("At time").tag("time")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.cardBackground)

                    if bgRefreshType == "interval" {
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
                                        .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                                    Spacer()
                                    if bgRefreshInterval == item.mins {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(theme.accent)
                                            .scaledFont(.system(size: 14, weight: .semibold))
                                    }
                                }
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                    } else {
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

                Stepper("Max Retries: \(maxRetries)", value: $maxRetries, in: 0...10)
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
