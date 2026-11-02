//
//  SyncSettingsView.swift
//  Aerio
//
//  Settings > Sync. Sections in the Android SyncSettingsScreen order and
//  wording (Dispatcharr Sync port, part 4): iCloud (account line, iCloud
//  Sync, Push to iCloud, Pull from iCloud, Clear iCloud Data), Dispatcharr
//  Sync (toggle, Sync Now, Push to Dispatcharr, Pull from Dispatcharr,
//  Push to both), then Sync Categories. Android's Google Drive is iCloud
//  here. iCloud has no in-app sign-in, so there is no Sign Out row: the
//  account line reads the system iCloud account.
//
//  Rule 4: turning on the SECOND provider while both hold differing data
//  asks "Which setup should this device start from?" first; Cancel leaves
//  the switch off. Nothing here calls the server directly: every action
//  goes through DispatcharrSyncManager, SetupSourceCoordinator,
//  CloudSnapshotSync, or SyncManager.
//

import SwiftUI
import SwiftData

struct SyncSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var sync = SyncManager.shared
    @ObservedObject private var dsyncManager = DispatcharrSyncManager.shared
    @ObservedObject private var coordinator = SetupSourceCoordinator.shared
    @Query(sort: [
        SortDescriptor(\ServerConnection.sortOrder, order: .forward),
        SortDescriptor(\ServerConnection.createdAt, order: .forward)
    ])
    private var servers: [ServerConnection]

    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = iCloudSyncEnabledDefault
    @AppStorage("syncLastDate") private var syncLastDate: Double = 0
    @AppStorage(DispatcharrSyncManager.enabledKey) private var dsyncOn = false

    @State private var showClearICloudConfirm = false
    @State private var showPullConfirm = false
    @State private var showPushConfirm = false
    @State private var clearICloudConfirmationVisible = false

    // Dispatcharr Sync manual actions (Android SyncSettingsViewModel).
    @State private var dsyncPushConfirm = false
    @State private var dsyncPullConfirm = false
    @State private var bothPushConfirm = false
    @State private var dsyncPushStatus: SyncActionStatus = .idle
    @State private var dsyncPullStatus: SyncActionStatus = .idle
    @State private var bothPushStatus: SyncActionStatus = .idle

    /// Rule 4 prompt: the probe and whether iCloud (true) or Dispatcharr Sync (false) is being turned on.
    @State private var setupAsk: SetupAsk?
    @State private var setupProbing = false
    /// "Your backup needs an update": on open with iCloud Sync on, once per app session.
    @State private var backupUpdateKey: String?
    @State private var backupUpdateBusy = false

    struct SetupAsk: Identifiable {
        let probe: SetupSourceCoordinator.Probe
        let enablingCloud: Bool
        /// Opened from the coordinator's pending probe (no switch is being turned on).
        var fromPending = false
        var id: String { probe.playlistId + (enablingCloud ? "|cloud" : "|dsync") }
    }

    private var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    /// Dispatcharr Sync is offered only while the active playlist is Dispatcharr Direct Connect.
    private var dsyncAvailable: Bool {
        _ = servers.count
        return DsyncLocal.activeDispatcharrPlaylist() != nil
    }

    private var cloudSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    private var manualRows: DsyncManual.Rows {
        DsyncManual.rows(dispatcharrOn: dsyncOn, dispatcharrPlaylist: dsyncAvailable,
                         cloudOn: iCloudSyncEnabled, cloudSignedIn: cloudSignedIn)
    }

    private var manualRunning: Bool {
        dsyncManager.ui.running || dsyncPushStatus.isRunning || dsyncPullStatus.isRunning || bothPushStatus.isRunning
    }

    /// "X minutes ago" for a Unix-seconds stamp (Android lastSyncedAgo).
    private static func ago(_ seconds: Double) -> String {
        let interval = Date().timeIntervalSince1970 - seconds
        switch interval {
        case ..<60:      return "just now"
        case ..<3600:    return "\(Int(interval / 60))m ago"
        case ..<86400:   return "\(Int(interval / 3600))h ago"
        default:         return "\(Int(interval / 86400))d ago"
        }
    }

    private var lastSyncedString: String { syncLastDate > 0 ? Self.ago(syncLastDate) : "" }
    private var dsyncLast: Int64 { dsyncManager.ui.lastSyncAt }
    private var dsyncLastString: String { Self.ago(Double(dsyncLast) / 1000) }

    private var syncNowSubtitle: String {
        if !dsyncAvailable { return "Needs a Dispatcharr playlist" }
        if let m = dsyncManager.ui.message { return m }
        if dsyncManager.ui.running { return "Syncing" }
        if dsyncLast > 0 { return "Last synced \(dsyncLastString)" }
        return "Not synced yet"
    }

    /// Android footer: precedence line when both are on; the profile line otherwise (none on TV).
    private var dsyncFooter: String? {
        if dsyncOn && iCloudSyncEnabled {
            return "Dispatcharr Sync takes precedence for shared data on this server. iCloud keeps a backup."
        }
        if isTV { return nil }
        return "Each profile syncs as its own Dispatcharr user. Playlists and sign-in details never sync here. Admins on your Dispatcharr server can view synced data."
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

    // MARK: - Provider switches

    private func setCloud(_ on: Bool) {
        iCloudSyncEnabled = on
        SyncManager.shared.syncSettingChanged(enabled: on)
    }

    private func setDsync(_ on: Bool) {
        DispatcharrSyncManager.shared.setEnabled(on)
        debugLog("[DSYNC] \(on ? "enabled" : "disabled") from Settings")
    }

    private var cloudBinding: Binding<Bool> {
        Binding(get: { iCloudSyncEnabled }, set: { on in
            if on && dsyncOn { enableSecond(enablingCloud: true) { setCloud(true) } } else { setCloud(on) }
        })
    }

    private var dsyncBinding: Binding<Bool> {
        Binding(get: { dsyncOn }, set: { on in
            if on && iCloudSyncEnabled { enableSecond(enablingCloud: false) { setDsync(true) } } else { setDsync(on) }
        })
    }

    /// Rule 4: probe both sides first; Ask opens the prompt, a one-sided answer applies, nil is a plain switch.
    private func enableSecond(enablingCloud: Bool, plain: @escaping () -> Void) {
        guard !setupProbing else { return }
        setupProbing = true
        Task { @MainActor in
            let p = await coordinator.probe()
            setupProbing = false
            switch p?.decision {
            case .ask?: setupAsk = SetupAsk(probe: p!, enablingCloud: enablingCloud)
            case .useCloud?: applySetupSourceAndEnable(.cloud, p!.playlistId, enablingCloud: enablingCloud)
            case .useDispatcharr?: applySetupSourceAndEnable(.dispatcharr, p!.playlistId, enablingCloud: enablingCloud)
            case nil: plain()
            }
        }
    }

    /// Settings: the SECOND provider is being turned on and both hold data (Android applySetupSourceAndEnable).
    private func applySetupSourceAndEnable(_ source: SetupSourceChoice.Source, _ playlistId: String, enablingCloud: Bool) {
        Task { @MainActor in
            if enablingCloud {
                // Dispatcharr Sync already owns the shared data here, so an iCloud
                // choice applies the backup over it (ignoreOwnership).
                await coordinator.choose(source, playlistId: playlistId, ignoreOwnership: true)
                setCloud(true)
            } else {
                await coordinator.choose(source, playlistId: playlistId)
                setDsync(true)
            }
            coordinator.afterDispatcharrOn()
        }
    }

    // MARK: - Manual Dispatcharr actions

    private func runDispatcharrPush() {
        guard !manualRunning else { return }
        dsyncPushStatus = .running
        Task { @MainActor in
            let ok = await DispatcharrSyncManager.shared.manualPush()
            dsyncPushStatus = ok ? .success(DsyncManualCopy.PUSHED_TO_DISPATCHARR) : .failure(DsyncManualCopy.DISPATCHARR_UNREACHABLE)
        }
    }

    private func runDispatcharrPull() {
        guard !manualRunning else { return }
        dsyncPullStatus = .running
        Task { @MainActor in
            let ok = await DispatcharrSyncManager.shared.manualPull()
            dsyncPullStatus = ok ? .success(DsyncManualCopy.PULLED_FROM_DISPATCHARR) : .failure(DsyncManualCopy.DISPATCHARR_UNREACHABLE)
        }
    }

    private func runPushToBoth() {
        guard !manualRunning else { return }
        bothPushStatus = .running
        Task { @MainActor in
            let ok = await DispatcharrSyncManager.shared.manualPushToBoth {
                await CloudSnapshotSync.shared.replaceBackupNow()
            }
            bothPushStatus = ok ? .success(DsyncManualCopy.PUSHED_TO_BOTH) : .failure(DsyncManualCopy.DISPATCHARR_UNREACHABLE)
        }
    }

    // MARK: - Body

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
        .onAppear {
            backupUpdateKey = BackupUpdateOffer.offerForSettings(cloudOn: iCloudSyncEnabled)
            // Unknown-iCloud setup choice (section 10a): the probe decides here,
            // or opens the prompt when both sides differ.
            if dsyncOn && iCloudSyncEnabled && cloudSignedIn && coordinator.cloudUnknownPending() {
                enableSecond(enablingCloud: true) {}
            }
            if let p = coordinator.pending, setupAsk == nil {
                setupAsk = SetupAsk(probe: p, enablingCloud: false, fromPending: true)
            }
        }
        .onChange(of: coordinator.pending) { _, p in
            if let p, setupAsk == nil { setupAsk = SetupAsk(probe: p, enablingCloud: false, fromPending: true) }
        }
        // Point-in-time feedback: a stale result does not greet the next visit.
        .onDisappear {
            dsyncPushStatus = .idle
            dsyncPullStatus = .idle
            bothPushStatus = .idle
        }
        .sheet(item: $setupAsk) { ask in
            SetupSourcePromptView(
                cloud: ask.probe.cloud,
                dsync: ask.probe.dsync,
                onContinue: { source in
                    setupAsk = nil
                    if ask.fromPending {
                        Task { @MainActor in
                            await coordinator.choose(source, playlistId: ask.probe.playlistId, ignoreOwnership: source == .cloud)
                            coordinator.afterDispatcharrOn()
                        }
                    } else {
                        applySetupSourceAndEnable(source, ask.probe.playlistId, enablingCloud: ask.enablingCloud)
                    }
                },
                onCancel: {
                    setupAsk = nil
                    coordinator.cancelPrompt()
                }
            )
        }
        .sheet(isPresented: Binding(get: { backupUpdateKey != nil }, set: { if !$0 { backupUpdateKey = nil } })) {
            BackupUpdateStepView(
                busy: backupUpdateBusy,
                onUpdate: {
                    guard let key = backupUpdateKey else { return }
                    backupUpdateBusy = true
                    CloudSnapshotSync.shared.acceptIdUpdate(key)
                    backupUpdateBusy = false
                    backupUpdateKey = nil
                },
                onNotNow: {
                    if let key = backupUpdateKey { BackupUpdateOffer.decline(key) }
                    backupUpdateKey = nil
                },
                inDialog: true
            )
            .interactiveDismissDisabled(true)
            .presentationDetents([.medium, .large])
        }
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
            Text("This replaces this device's playlists, settings and watch progress with the copy in iCloud. Anything on this device that is not in iCloud is removed. If this device has the newest changes, push them up first.")
        }
        .alert("Push to iCloud?", isPresented: $showPushConfirm) {
            Button("Push") {
                debugLog("🔵 Push to iCloud confirmed")
                pushEverything()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the snapshot in iCloud with this device's playlists and settings.")
        }
        .alert("Push to Dispatcharr?", isPresented: $dsyncPushConfirm) {
            Button("Push") { runDispatcharrPush() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces the shared data on your Dispatcharr server with this device's copy for the categories you sync. Other devices receive it on their next sync.")
        }
        .alert("Pull from Dispatcharr?", isPresented: $dsyncPullConfirm) {
            Button("Pull") { runDispatcharrPull() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces this device's shared data with the copy on your Dispatcharr server for the categories you sync.")
        }
        .alert("Push to both?", isPresented: $bothPushConfirm) {
            Button("Push") { runPushToBoth() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces the shared data on your Dispatcharr server and in your iCloud backup with this device's copy for the categories you sync.")
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

    // MARK: - Account line (Android AccountRow)

    private var accountTitle: String { cloudSignedIn ? "Signed in to iCloud" : "Not signed in" }
    private var accountSubtitle: String { cloudSignedIn ? "Account connected" : "Sign in to start syncing across devices" }

    private var accountRow: some View {
        SettingsRow(icon: cloudSignedIn ? "person.crop.circle.fill" : "person.crop.circle",
                    iconColor: .accentPrimary,
                    title: accountTitle,
                    subtitle: accountSubtitle)
            .accessibilityElement(children: .combine)
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            Section {
                accountRow
                Toggle(isOn: cloudBinding) {
                    SettingsRow(icon: "icloud.fill", iconColor: .accentPrimary,
                                title: "iCloud Sync",
                                subtitle: "Sync playlists, preferences, and watch progress")
                }
                .tint(ThemeManager.shared.accent)

                if iCloudSyncEnabled && cloudSignedIn {
                    Button {
                        guard sync.activity == .idle else { return }
                        showPushConfirm = true
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

                    // REPLACES local state with the cloud copy, so it confirms first.
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

                    // Failure reason only; the in-flight spinner lives in the rows.
                    SyncActivityRow()
                }

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
            } header: {
                Text("iCloud").sectionHeaderStyle()
            } footer: {
                Text("Playlists, preferences, and VOD watch progress sync across all devices signed into the same Apple ID. Credentials are stored securely in iCloud Keychain.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listRowBackground(Color.cardBackground)
            .listSectionSeparator(.hidden)

            // Dispatcharr Sync: independent of iCloud Sync, both can be on.
            // Offered on a Dispatcharr Direct Connect playlist, or while on so it can be turned off.
            if dsyncAvailable || dsyncOn {
                Section {
                    Toggle(isOn: dsyncBinding) {
                        SettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .accentPrimary,
                                    title: "Dispatcharr Sync",
                                    subtitle: dsyncAvailable ? "Store sync data on your Dispatcharr server under each profile"
                                        : "Needs a Dispatcharr playlist")
                    }
                    .tint(ThemeManager.shared.accent)

                    if dsyncOn {
                        Button {
                            if dsyncAvailable && !dsyncManager.ui.running { DispatcharrSyncManager.shared.syncNow() }
                        } label: {
                            SettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .accentPrimary,
                                        title: "Sync Now", subtitle: syncNowSubtitle,
                                        isBusy: dsyncManager.ui.running)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                    if manualRows.pushPullDispatcharr {
                        VStack(spacing: 4) {
                            Button {
                                if !manualRunning { dsyncPushConfirm = true }
                            } label: {
                                SettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .accentPrimary,
                                            title: "Push to Dispatcharr",
                                            subtitle: dsyncLast > 0
                                                ? "Send this device's data up  ·  Last synced \(dsyncLastString)"
                                                : "Send this device's data up",
                                            isBusy: dsyncPushStatus.isRunning)
                            }
                            .buttonStyle(PressableButtonStyle())
                            SyncActionStatusLine(status: dsyncPushStatus)
                        }
                        VStack(spacing: 4) {
                            Button {
                                if !manualRunning { dsyncPullConfirm = true }
                            } label: {
                                SettingsRow(icon: "arrow.down.circle", iconColor: .accentPrimary,
                                            title: "Pull from Dispatcharr",
                                            subtitle: "Replace this device's data with the Dispatcharr copy",
                                            isBusy: dsyncPullStatus.isRunning)
                            }
                            .buttonStyle(PressableButtonStyle())
                            SyncActionStatusLine(status: dsyncPullStatus)
                        }
                    }
                    if manualRows.pushToBoth {
                        VStack(spacing: 4) {
                            Button {
                                if !manualRunning && sync.activity == .idle { bothPushConfirm = true }
                            } label: {
                                SettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .accentPrimary,
                                            title: "Push to both",
                                            subtitle: "Send this device's data to Dispatcharr and iCloud",
                                            isBusy: bothPushStatus.isRunning)
                            }
                            .buttonStyle(PressableButtonStyle())
                            SyncActionStatusLine(status: bothPushStatus)
                        }
                    }
                } header: {
                    Text("Dispatcharr Sync").sectionHeaderStyle()
                } footer: {
                    if let f = dsyncFooter {
                        Text(f).scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .listRowBackground(Color.cardBackground)
                .listSectionSeparator(.hidden)
            }

            // One shared Sync Categories list for both iCloud and Dispatcharr Sync.
            // Reachable with sync off: the Delete actions there work for stale-state cleanup.
            Section {
                NavigationLink(destination: SyncCategoriesSettingsView()) {
                    SettingsRow(icon: "slider.horizontal.3",
                                iconColor: .accentPrimary,
                                title: "Sync Categories",
                                subtitle: "Choose what syncs across your devices")
                }
                .buttonStyle(PressableButtonStyle())
            } header: {
                Text("Sync Categories").sectionHeaderStyle()
            }
            .listRowBackground(Color.cardBackground)
            .listSectionSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Floating tab bar parity: content runs under the bar and the last row clears it.
        .settingsPhoneTabBarChrome()
    }
    #endif

    // MARK: - tvOS Body

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                SettingsSection("iCloud", style: .compactCard) {
                    accountRow
                        .padding(.horizontal, 20)
                        .frame(minHeight: 80)
                    TVSettingsToggleRow(
                        icon: "icloud.fill",
                        iconColor: .accentPrimary,
                        title: "iCloud Sync",
                        subtitle: "Sync playlists, preferences, and watch progress",
                        isOn: cloudBinding
                    ) { _ in }

                    if iCloudSyncEnabled && cloudSignedIn {
                        // tvOS: single-line rows, the stamp rides the title.
                        TVSettingsActionRow(
                            icon: "arrow.triangle.2.circlepath.icloud",
                            label: syncLastDate > 0
                                ? "Push to iCloud  ·  Last synced \(lastSyncedString)"
                                : "Push to iCloud",
                            isBusy: sync.activity == .pushing
                        ) {
                            // tvOS rows are never `.disabled` (that would drop them
                            // out of the focus engine), so a run in flight swallows the press.
                            guard sync.activity == .idle else { return }
                            showPushConfirm = true
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
                    TVSettingsActionRow(
                        icon: "trash.circle.fill",
                        label: "Clear iCloud Data",
                        isDestructive: true
                    ) {
                        showClearICloudConfirm = true
                    }
                }

                if dsyncAvailable || dsyncOn {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSection("Dispatcharr Sync", style: .compactCard) {
                            TVSettingsToggleRow(
                                icon: "arrow.triangle.2.circlepath",
                                iconColor: .accentPrimary,
                                title: "Dispatcharr Sync",
                                subtitle: dsyncAvailable ? "Store sync data on your Dispatcharr server under each profile"
                                    : "Needs a Dispatcharr playlist",
                                isOn: dsyncBinding
                            ) { _ in }
                            if dsyncOn {
                                TVSettingsActionRow(
                                    icon: "arrow.triangle.2.circlepath",
                                    label: "Sync Now  ·  \(syncNowSubtitle)",
                                    isBusy: dsyncManager.ui.running
                                ) {
                                    if dsyncAvailable && !dsyncManager.ui.running { DispatcharrSyncManager.shared.syncNow() }
                                }
                            }
                            if manualRows.pushPullDispatcharr {
                                TVSettingsActionRow(
                                    icon: "arrow.triangle.2.circlepath",
                                    label: dsyncLast > 0
                                        ? "Push to Dispatcharr  ·  Last synced \(dsyncLastString)"
                                        : "Push to Dispatcharr",
                                    isBusy: dsyncPushStatus.isRunning
                                ) {
                                    if !manualRunning { dsyncPushConfirm = true }
                                }
                                SyncActionStatusLine(status: dsyncPushStatus)
                                TVSettingsActionRow(
                                    icon: "arrow.down.circle",
                                    label: "Pull from Dispatcharr",
                                    isBusy: dsyncPullStatus.isRunning
                                ) {
                                    if !manualRunning { dsyncPullConfirm = true }
                                }
                                SyncActionStatusLine(status: dsyncPullStatus)
                            }
                            if manualRows.pushToBoth {
                                TVSettingsActionRow(
                                    icon: "arrow.triangle.2.circlepath",
                                    label: "Push to both",
                                    isBusy: bothPushStatus.isRunning
                                ) {
                                    if !manualRunning && sync.activity == .idle { bothPushConfirm = true }
                                }
                                SyncActionStatusLine(status: bothPushStatus)
                            }
                        }
                        if let f = dsyncFooter {
                            Text(f)
                                .scaledFont(.footnote.subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                                .padding(.horizontal, 24)
                        }
                    }
                }

                SettingsSection("Sync Categories", style: .compactCard) {
                    TVSettingsNavRow(destination: SyncCategoriesSettingsView().trackedAsClassicSettingsChild("Sync Categories"),
                                     logTitle: "Sync Categories") {
                        SettingsRow(icon: "slider.horizontal.3",
                                    iconColor: .accentPrimary,
                                    title: "Sync Categories",
                                    subtitle: "Choose what syncs across your devices")
                    }
                }
            }
            .frame(maxWidth: SettingsMetrics.tvReadingColumnWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
    }
    #endif
}
