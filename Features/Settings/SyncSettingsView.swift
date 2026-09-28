//
//  SyncSettingsView.swift
//  Aerio
//
//  Settings redesign Phase 1 (regroup, 2026-09-17). The iCloud Sync
//  toggle, Push, Pull, the activity row, Sync Categories and Clear iCloud
//  Data all moved off the Settings root onto this page; the root keeps a
//  single Sync row whose value reads On or Off.
//
//  The rows, their copy and their confirmation alerts are unchanged; they
//  were lifted from SettingsView's root section and its iPad / tvOS panes,
//  which this one view now replaces on every platform.
//

import SwiftUI
import SwiftData

struct SyncSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var sync = SyncManager.shared
    @Query(sort: [
        SortDescriptor(\ServerConnection.sortOrder, order: .forward),
        SortDescriptor(\ServerConnection.createdAt, order: .forward)
    ])
    private var servers: [ServerConnection]

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("syncLastDate") private var syncLastDate: Double = 0

    @State private var showClearICloudConfirm = false
    @State private var showPullConfirm = false
    @State private var clearICloudConfirmationVisible = false

    /// Human-readable "X minutes ago" string for the last sync timestamp.
    private var lastSyncedString: String {
        guard syncLastDate > 0 else { return "" }
        let interval = Date().timeIntervalSince1970 - syncLastDate
        switch interval {
        case ..<60:      return "just now"
        case ..<3600:    return "\(Int(interval / 60))m ago"
        case ..<86400:   return "\(Int(interval / 3600))h ago"
        default:         return "\(Int(interval / 86400))d ago"
        }
    }

    private func pushEverything() {
        guard sync.activity == .idle else { return }
        debugLog("🔵 Sync Now tapped")
        SyncManager.shared.pushServers(servers, immediate: true)
        SyncManager.shared.pushPreferencesImmediate()
        if let ctx = WatchProgressManager.modelContext,
           let all = try? ctx.fetch(FetchDescriptor<WatchProgress>()) {
            SyncManager.shared.pushWatchProgress(all, immediate: true)
        }
        SyncManager.shared.pushReminders(immediate: true)
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
        .navigationTitle("Sync")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .alert("Clear iCloud Data?", isPresented: $showClearICloudConfirm) {
            Button("Clear", role: .destructive) {
                debugLog("🔵 Clear iCloud Data confirmed")
                SyncManager.shared.clearAllICloudData(localServers: servers)
                clearICloudConfirmationVisible = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    await MainActor.run { clearICloudConfirmationVisible = false }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes synced playlists, preferences, watch progress, and credentials from iCloud. This device's data is preserved. iCloud Sync stays enabled, so your local state will replace whatever was on iCloud the next time the app pushes.")
        }
        .alert("Pull from iCloud?", isPresented: $showPullConfirm) {
            Button("Replace This Device", role: .destructive) {
                debugLog("🔵 Pull from iCloud confirmed (replace)")
                SyncManager.shared.pullFromCloud(force: true, replace: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces this device's playlists and watch progress with the copy in iCloud. Playlists or progress on this device that are not in iCloud are removed. Preferences merge normally. If this device has the newest changes, push them up first.")
        }
        .overlay(alignment: .bottom) {
            if clearICloudConfirmationVisible {
                Text("iCloud data cleared")
                    .scaledFont(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: clearICloudConfirmationVisible)
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            Section {
                Toggle(isOn: $iCloudSyncEnabled) {
                    SettingsRow(icon: "icloud.fill", iconColor: .accentPrimary,
                                title: "iCloud Sync",
                                subtitle: "Sync playlists, preferences, and watch progress")
                }
                .tint(ThemeManager.shared.accent)
                .onChange(of: iCloudSyncEnabled) { _, enabled in
                    SyncManager.shared.syncSettingChanged(enabled: enabled)
                }

                if iCloudSyncEnabled {
                    Button {
                        pushEverything()
                    } label: {
                        SettingsRow(icon: "arrow.triangle.2.circlepath.icloud",
                                    iconColor: .accentPrimary,
                                    title: "Push to iCloud",
                                    subtitle: syncLastDate > 0
                                        ? "Send this device's data up  ·  Last synced \(lastSyncedString)"
                                        : "Send this device's playlists, preferences and progress up",
                                    isBusy: sync.activity == .pushing)
                    }
                    .buttonStyle(PressableButtonStyle())
                    // Both directions are locked out while either one runs so
                    // a double tap cannot stack operations on each other.
                    .disabled(sync.activity != .idle)

                    // The other direction. This REPLACES local state with the
                    // cloud copy, matching Android's "Pull Config from Drive",
                    // so it confirms first and the alert carries the note.
                    Button {
                        guard sync.activity == .idle else { return }
                        showPullConfirm = true
                    } label: {
                        SettingsRow(icon: "icloud.and.arrow.down",
                                    iconColor: .accentPrimary,
                                    title: "Pull from iCloud",
                                    subtitle: "Replace this device's data with the iCloud copy",
                                    isBusy: sync.activity == .pulling)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(sync.activity != .idle)

                    // Failure reason only; the in-flight spinner lives in the
                    // Push / Pull rows themselves.
                    SyncActivityRow()
                }

                // Granular per-category sync controls. Stays accessible even
                // when iCloudSyncEnabled is off so the Delete actions work for
                // stale-state cleanup.
                NavigationLink(destination: SyncCategoriesSettingsView()) {
                    SettingsRow(icon: "slider.horizontal.3",
                                iconColor: .accentPrimary,
                                title: "Sync Categories",
                                subtitle: "Choose what syncs across your devices")
                }
                .buttonStyle(PressableButtonStyle())

                // Destructive: wipe everything this app has parked in iCloud.
                // Always offered, even when Sync is currently off.
                Button(role: .destructive) {
                    showClearICloudConfirm = true
                } label: {
                    SettingsRow(icon: "trash.circle.fill",
                                iconColor: .statusLive,
                                title: "Clear iCloud Data",
                                subtitle: "Wipe synced playlists, preferences, watch progress, and credentials from iCloud")
                }
                .buttonStyle(PressableButtonStyle())
            } footer: {
                Text("Playlists, preferences, and VOD watch progress sync across all devices signed into the same Apple ID. Credentials are stored securely in iCloud Keychain.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listRowBackground(Color.cardBackground)
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

    // MARK: - tvOS Body

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsToggleRow(
                    icon: "icloud.fill",
                    iconColor: .accentPrimary,
                    title: "iCloud Sync",
                    subtitle: "Sync playlists, preferences, and watch progress",
                    isOn: $iCloudSyncEnabled
                ) { enabled in
                    SyncManager.shared.syncSettingChanged(enabled: enabled)
                }

                if iCloudSyncEnabled {
                    // Named directions plus a real Pull: on an Apple TV a
                    // generic "Sync Now" pushed the TV's older state up and
                    // clobbered what the phone had just added.
                    TVSettingsActionRow(
                        icon: "arrow.triangle.2.circlepath.icloud",
                        label: syncLastDate > 0
                            ? "Push to iCloud  ·  Last synced \(lastSyncedString)"
                            : "Push to iCloud",
                        isBusy: sync.activity == .pushing
                    ) {
                        // tvOS rows are never `.disabled` (that would drop them
                        // out of the focus engine), so a run in flight swallows
                        // the press instead.
                        pushEverything()
                    }
                    TVSettingsActionRow(
                        icon: "icloud.and.arrow.down",
                        label: "Pull from iCloud",
                        isBusy: sync.activity == .pulling
                    ) {
                        guard sync.activity == .idle else { return }
                        showPullConfirm = true
                    }

                    SyncActivityRow()
                }
                TVSettingsNavRow(destination: SyncCategoriesSettingsView().trackedAsClassicSettingsChild()) {
                    SettingsRow(icon: "slider.horizontal.3",
                                iconColor: .accentPrimary,
                                title: "Sync Categories",
                                subtitle: "Choose what syncs across your devices")
                }
                TVSettingsActionRow(
                    icon: "trash.circle.fill",
                    label: "Clear iCloud Data",
                    isDestructive: true
                ) {
                    showClearICloudConfirm = true
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
    }
    #endif
}
