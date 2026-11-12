//  OnboardingSyncSteps.swift
//  Aerio
//
//  The onboarding sync steps the Welcome chain walks (Dispatcharr Sync port,
//  part 4): "Turn on Dispatcharr Sync?" (Android DispatcharrSyncStepScreen.kt),
//  "Also back up to iCloud?" (Android DriveBackupOfferStepScreen.kt, iCloud in
//  place of Google Drive), and the restore progress screen. Every string is
//  Android's word for word except where iCloud replaces Google Drive. Buttons
//  are never disabled mid-flow (tvOS focus); taps are ignored while busy.
//  Nothing here calls the server: the coordinator and the manager do.

import SwiftUI

// MARK: - "Turn on Dispatcharr Sync?"

struct DispatcharrSyncStepView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    /// Came from the Welcome "Sync with Dispatcharr" card: turn on without asking.
    let autoEnable: Bool
    /// Set when the playlist was just signed in from a Dispatcharr user QR.
    var qrSignIn: QrImportBus.SignIn? = nil
    let onDone: () -> Void
    /// Cancel on the "Which setup" prompt.
    let onCancel: () -> Void
    /// Skip tapped (the upgrade offer remembers it); onDone still follows.
    var onSkip: (() -> Void)? = nil

    @ObservedObject private var coordinator = SetupSourceCoordinator.shared
    @State private var ready = false
    @State private var busy = false
    @State private var ask: SetupSourceCoordinator.Probe?
    @State private var started = false
    /// The server already holds this user's AerioTV data: lead with the restore copy.
    @State private var restore = false
    #if os(tvOS)
    @FocusState private var turnOnFocused: Bool
    #endif

    var body: some View {
        Group {
            if ready {
                content
            } else {
                SyncStepFrame {
                    ProgressView()
                        .tint(.accentPrimary)
                        .accessibilityLabel("Turning on Dispatcharr Sync")
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            guard !started else { return }
            started = true
            // The onboarding step asked about Dispatcharr Sync: the providers offer leaves it out.
            WelcomeSyncChain.markAnswered(SyncProvidersRules.DISPATCHARR)
            if DispatcharrSyncManager.shared.isEnabled {
                // Already on (for example a second Dispatcharr playlist): nothing to ask.
                onDone()
            } else if autoEnable {
                await runTurnOn(fromCard: true)
            } else {
                if let qrSignIn { restore = await QrImportBus.serverHasData(qrSignIn) }
                ready = true
            }
        }
        .sheet(item: Binding(get: { ask.map(AskBox.init) }, set: { if $0 == nil { ask = nil } })) { box in
            SetupSourcePromptView(
                cloud: box.probe.cloud,
                dsync: box.probe.dsync,
                onContinue: { source in
                    // Dismiss at once; the step's progress view shows while the choice applies.
                    ask = nil
                    ready = false
                    Task { @MainActor in
                        await coordinator.choose(source, playlistId: box.probe.playlistId)
                        await turnOn(fromCard: autoEnable)
                        onDone()
                    }
                },
                onCancel: {
                    ask = nil
                    busy = false
                    coordinator.cancelPrompt()
                    onCancel()
                }
            )
        }
    }

    private struct AskBox: Identifiable {
        let probe: SetupSourceCoordinator.Probe
        var id: String { probe.playlistId }
    }

    private var content: some View {
        let tv: Bool = {
            #if os(tvOS)
            return true
            #else
            return false
            #endif
        }()
        return SyncStepFrame {
            VStack(spacing: tv ? 20 : 12) {
                Text("Turn on Dispatcharr Sync?")
                    .scaledFont(tv ? .system(size: 38, weight: .semibold) : .headlineLarge)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if restore {
                    Text("Restore your favorites, progress, and settings from your server.")
                        .scaledFont(tv ? .system(size: 26) : .bodyLarge)
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Your favorites, watch progress, reminders, and preferences are stored on your Dispatcharr server under each profile and follow you to every device. Admins on the server can view this data.")
                    .scaledFont(tv ? .system(size: 24).subtext() : .bodyMedium.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                SyncStepPrimaryButton(title: "Turn On", busy: busy) {
                    guard !busy else { return }
                    busy = true
                    Task { @MainActor in await runTurnOn(fromCard: false) }
                }
                #if os(tvOS)
                .focused($turnOnFocused)
                #endif
                .padding(.top, 8)
                SyncStepSecondaryButton(title: "Skip") {
                    guard !busy else { return }
                    Task { @MainActor in
                        await coordinator.releaseHeld()
                        debugLog("[DSYNC] onboarding step skipped")
                        onSkip?()
                        onDone()
                    }
                }
                Text("You can change this later in Settings > Sync.")
                    .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .multilineTextAlignment(.center)
            }
            .onboardingPadWidth(560, other: tv ? 900 : 520)
        }
        #if os(tvOS)
        .onAppear { turnOnFocused = true }
        .onExitCommand { }
        #endif
    }

    /// Rule 4: both iCloud and Dispatcharr hold data for this user? The prompt decides before Turn On.
    private func runTurnOn(fromCard: Bool) async {
        let p = await coordinator.probe()
        switch p?.decision {
        case .ask?:
            ready = true
            ask = p
        case .useCloud?:
            await coordinator.choose(.cloud, playlistId: p!.playlistId)
            await turnOn(fromCard: fromCard)
            onDone()
        case .useDispatcharr?:
            await coordinator.choose(.dispatcharr, playlistId: p!.playlistId)
            await turnOn(fromCard: fromCard)
            onDone()
        case nil:
            await coordinator.releaseHeld()
            await turnOn(fromCard: fromCard)
            onDone()
        }
    }

    /// Turns Dispatcharr Sync on (iCloud Sync is independent) and waits for the first pull,
    /// so the guide opens with restored data.
    private func turnOn(fromCard: Bool) async {
        DispatcharrSyncManager.shared.setEnabled(true)
        debugLog(fromCard ? "[DSYNC] enabled from onboarding (sync card)" : "[DSYNC] enabled from onboarding")
        let ok = await DispatcharrSyncManager.shared.awaitFirstPull()
        debugLog("[DSYNC] onboarding first pull \(ok ? "done" : "not finished; continuing")")
        SyncProvidersOfferStore.arm("onboarding first pull")
        coordinator.afterDispatcharrOn()
    }
}

// MARK: - "Also back up to iCloud?"

struct CloudBackupOfferStepView: View {
    let busy: Bool
    let onTurnOn: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        let tv: Bool = {
            #if os(tvOS)
            return true
            #else
            return false
            #endif
        }()
        SyncStepFrame {
            VStack(spacing: tv ? 20 : 12) {
                Text("Also back up to iCloud?")
                    .scaledFont(tv ? .system(size: 38, weight: .semibold) : .headlineLarge)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("iCloud keeps a backup of your playlists and settings for a new phone or TV. Dispatcharr Sync stays in charge of your favorites, progress, and reminders.")
                    .scaledFont(tv ? .system(size: 24).subtext() : .bodyMedium.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                SyncStepPrimaryButton(title: "Turn On iCloud Sync", busy: busy) { if !busy { onTurnOn() } }
                    .padding(.top, 8)
                SyncStepSecondaryButton(title: "Not now") { if !busy { onNotNow() } }
            }
            .onboardingPadWidth(560, other: tv ? 900 : 520)
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Restore progress

/// Shown for the whole iCloud restore stretch; replaces Welcome so its cards are not focusable underneath.
/// "Setting Up" after Connect while the playlist loads and the chain picks its first step.
struct OnboardingSettingUpView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    var body: some View {
        SyncStepFrame {
            VStack(spacing: 16) {
                ProgressView().tint(.accentPrimary)
                Text("Setting Up")
                    .scaledFont(.headlineSmall)
                    .foregroundColor(.textPrimary)
                Text("Loading your playlist.")
                    .scaledFont(.bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
            }
            .accessibilityElement(children: .combine)
        }
        .navigationBarHidden(true)
        #if os(tvOS)
        .onExitCommand { }
        #endif
    }
}

struct OnboardingRestoreProgressView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    var body: some View {
        SyncStepFrame {
            VStack(spacing: 16) {
                ProgressView().tint(.accentPrimary)
                Text("Importing from iCloud...")
                    .scaledFont(.headlineSmall)
                    .foregroundColor(.textPrimary)
                Text("Looking for an existing configuration.")
                    .scaledFont(.bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
            }
            .accessibilityElement(children: .combine)
        }
        .navigationBarHidden(true)
        #if os(tvOS)
        .onExitCommand { }
        #endif
    }
}

// MARK: - Providers offer arming (Android SyncProvidersStore.arm/offerShown)

/// The one-time "Keep your devices in sync" offer: armed after onboarding's first
/// iCloud restore or first Dispatcharr Sync pull, evaluated once in Main, shown once per playlist.
@MainActor
enum SyncProvidersOfferStore {
    private static let shownKey = "syncProvidersOfferShown"
    static var armed = false

    static func arm(_ why: String) {
        armed = true
        debugLog("[SYNC] providers offer armed (\(why))")
    }

    static func disarm() { armed = false }

    static func offerShown(_ playlistId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: shownKey) ?? []).contains(playlistId)
    }

    static func markOfferShown(_ playlistId: String) {
        var s = UserDefaults.standard.stringArray(forKey: shownKey) ?? []
        if !s.contains(playlistId) { s.append(playlistId) }
        UserDefaults.standard.set(s, forKey: shownKey)
    }
}

// MARK: - "Keep your devices in sync" one-time offer (Android SyncProvidersOffer.kt)

/// Schema section 10b: after onboarding's first iCloud restore or first Dispatcharr Sync
/// pull, offer ONCE per playlist the providers the owner's other devices use.
/// Evaluated when onboarding closes; Google Drive is never offered on Apple.
struct SyncProvidersOfferHost: ViewModifier {
    /// The onboarding cover's visibility: the offer is evaluated once it is down.
    let onboardingVisible: Bool
    @State private var offer: [String]?

    func body(content: Content) -> some View {
        content
            .onChange(of: onboardingVisible) { _, visible in
                if !visible { evaluateSoon() }
            }
            .onAppear { if !onboardingVisible { evaluateSoon() } }
            .alert("Keep your devices in sync",
                   isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
                   presenting: offer) { providers in
                Button("Turn on") {
                    offer = nil
                    if providers.contains(SyncProvidersRules.DISPATCHARR) {
                        DispatcharrSyncManager.shared.setEnabled(true)
                        debugLog("[DSYNC] enabled from sync providers offer")
                    }
                    if providers.contains(SyncProvidersRules.ICLOUD) {
                        UserDefaults.standard.set(true, forKey: "iCloudSyncEnabled")
                        SyncManager.shared.syncSettingChanged(enabled: true)
                        debugLog("[CLOUD] enabled from sync providers offer")
                    }
                }
                Button("Not now", role: .cancel) { offer = nil }
            } message: { providers in
                Text(SyncProvidersRules.offerText(providers))
            }
    }

    private func evaluateSoon() {
        guard SyncProvidersOfferStore.armed else { return }
        Task { @MainActor in
            // Let the cover finish closing so the alert has a window to present on.
            try? await Task.sleep(nanoseconds: 800_000_000)
            // The offer waits for the launch PIN gate (security fix 2026-11-12).
            while ProfileManager.shared.launchLocked { try? await Task.sleep(nanoseconds: 500_000_000) }
            offer = evaluate()
        }
    }

    /// Nil: nothing to offer (disarms). The owner's records only: never while
    /// a non-default profile is active (Android evaluate, ProfileScope token).
    @MainActor private func evaluate() -> [String]? {
        guard SyncProvidersOfferStore.armed else { return nil }
        if ProfileManager.shared.nonDefaultActive() { return nil }
        SyncProvidersOfferStore.disarm()
        guard let pid = ChannelStore.shared.activeServer?.id.uuidString else { return nil }
        let raw = SyncProvidersOfferStore.offerShown(pid) ? [] : CloudSnapshotSync.shared.providerOffers()
        // Providers the user already selected or answered in onboarding are never re-offered.
        let offers = WelcomeSyncChain.filterOffers(raw)
        if offers.isEmpty {
            debugLog("[SYNC] offer providers=none")
            return nil
        }
        SyncProvidersOfferStore.markOfferShown(pid)
        debugLog("[SYNC] offer providers=\(offers)")
        return offers
    }
}

// MARK: - One-time Dispatcharr Sync offer after an app update

/// Persisted state for the upgrade offer: the app version last evaluated and the per-device
/// Not Now. A failed probe writes nothing, so the next launch tries again.
@MainActor
enum DsyncUpgradeOfferStore {
    static let offeredVersionKey = "dsyncUpgradeOfferVersion"
    static let declinedKey = "dsyncUpgradeOfferDeclined"
    /// DEBUG only: "found" or "missing" stands in for the server read (simulator checks).
    static let simulateKey = "dsyncUpgradeOfferSimulate"

    #if DEBUG
    static var simulating: Bool {
        ["found", "missing"].contains(UserDefaults.standard.string(forKey: simulateKey) ?? "")
    }
    #endif

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var due: Bool { UserDefaults.standard.string(forKey: offeredVersionKey) != currentVersion }
    static func markEvaluated() { UserDefaults.standard.set(currentVersion, forKey: offeredVersionKey) }
    static var declined: Bool { UserDefaults.standard.bool(forKey: declinedKey) }
    static func decline() { UserDefaults.standard.set(true, forKey: declinedKey) }

    static func log(record: String, decision: String) {
        debugLog("[DSYNC] upgrade offer: record=\(record) decision=\(decision)")
    }
}

/// First foreground launch after an update: when the active playlist is Dispatcharr and
/// Dispatcharr Sync is off, read (only) whether the account already has a record and offer
/// the matching flow once. Never during onboarding, the PIN gate, or playback.
struct DsyncUpgradeOfferHost: ViewModifier {
    let onboardingVisible: Bool
    /// True when onboarding ran in this launch: it already asked about Dispatcharr Sync.
    let onboardingRanThisLaunch: Bool
    let blocked: Bool

    enum Offer: String, Identifiable { case optIn, migrate; var id: String { rawValue } }
    @State private var offer: Offer?
    @State private var started = false
    /// Live copies: the long-running task reads these, not the values captured at its start.
    @State private var liveOnboarding = true
    @State private var liveBlocked = true
    @State private var liveRan = false

    func body(content: Content) -> some View {
        content
            .onAppear { liveOnboarding = onboardingVisible; liveBlocked = blocked; liveRan = onboardingRanThisLaunch }
            .onChange(of: onboardingVisible) { _, v in liveOnboarding = v }
            .onChange(of: blocked) { _, v in liveBlocked = v }
            .onChange(of: onboardingRanThisLaunch) { _, v in liveRan = v }
            .task {
                guard !started else { return }
                started = true
                await run()
            }
            #if os(tvOS)
            .fullScreenCover(item: $offer) { o in sheet(o) }
            #else
            .sheet(item: $offer) { o in sheet(o).environment(\.syncStepFitsPadSheet, true) }
            #endif
    }

    @ViewBuilder private func sheet(_ o: Offer) -> some View {
        switch o {
        case .optIn:
            DsyncUpgradeOptInView(
                iCloudOn: UserDefaults.standard.bool(forKey: "iCloudSyncEnabled"),
                onTurnOn: {
                    offer = nil
                    // The first device already migrated: adopt the server record through the
                    // normal merge path, no comparison prompt. The legacy key move runs in the first cycle.
                    DispatcharrSyncManager.shared.setEnabled(true)
                    debugLog("[DSYNC] enabled from upgrade offer")
                },
                onNotNow: {
                    DsyncUpgradeOfferStore.decline()
                    debugLog("[DSYNC] upgrade offer declined")
                    offer = nil
                })
        case .migrate:
            DispatcharrSyncStepView(
                autoEnable: false,
                onDone: { offer = nil },
                onCancel: { offer = nil },
                onSkip: {
                    DsyncUpgradeOfferStore.decline()
                    debugLog("[DSYNC] upgrade offer declined")
                })
        }
    }

    @MainActor private var gatesOpen: Bool {
        if liveOnboarding || liveBlocked { return false }
        #if DEBUG
        // Simulator checks run without a Dispatcharr playlist: skip the playlist gates.
        if DsyncUpgradeOfferStore.simulating { return true }
        #endif
        let pm = ProfileManager.shared
        if pm.launchGate != nil || pm.launchPicker != nil || pm.switching { return false }
        if PlayerSession.shared.mode != .idle || !MultiviewStore.shared.tiles.isEmpty { return false }
        let cs = ChannelStore.shared
        return !cs.isLoading && !cs.channels.isEmpty
    }

    @MainActor private func run() async {
        guard DsyncUpgradeOfferStore.due else { return }
        // Wait for the playlist and every gate; the next idle moment, up to ten minutes.
        var waited = 0
        while !gatesOpen {
            if waited >= 600 { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard gatesOpen else { return }
        if liveRan {
            DsyncUpgradeOfferStore.markEvaluated()
            return
        }
        #if DEBUG
        if DsyncUpgradeOfferStore.simulating {
            let found = UserDefaults.standard.string(forKey: DsyncUpgradeOfferStore.simulateKey) == "found"
            offer = found ? .optIn : .migrate
            return
        }
        #endif
        guard let pid = DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString else {
            DsyncUpgradeOfferStore.log(record: "error", decision: "not-dispatcharr")
            DsyncUpgradeOfferStore.markEvaluated()
            return
        }
        if DispatcharrSyncManager.shared.isEnabled {
            DsyncUpgradeOfferStore.log(record: "error", decision: "already-on")
            DsyncUpgradeOfferStore.markEvaluated()
            return
        }
        if DsyncUpgradeOfferStore.declined {
            DsyncUpgradeOfferStore.log(record: "error", decision: "declined-before")
            DsyncUpgradeOfferStore.markEvaluated()
            return
        }
        if ProfileManager.shared.nonDefaultActive() { return }
        var present: Bool?
        #if DEBUG
        switch UserDefaults.standard.string(forKey: DsyncUpgradeOfferStore.simulateKey) {
        case "found"?: present = true
        case "missing"?: present = false
        default: present = await DispatcharrSyncManager.shared.accountRecordPresent(pid)
        }
        #else
        present = await DispatcharrSyncManager.shared.accountRecordPresent(pid)
        #endif
        guard let present else {
            // Server unreadable: nothing shown, nothing remembered; the next launch tries again.
            DsyncUpgradeOfferStore.log(record: "error", decision: "none")
            return
        }
        // The read can take a while: never rise over playback or a gate that opened meanwhile.
        while !gatesOpen { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        DsyncUpgradeOfferStore.markEvaluated()
        DsyncUpgradeOfferStore.log(record: present ? "found" : "missing",
                                   decision: present ? "shown-optin" : "shown-migrate")
        offer = present ? .optIn : .migrate
    }
}

/// "Dispatcharr Sync is on for this account": another device already syncs this account.
struct DsyncUpgradeOptInView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let iCloudOn: Bool
    let onTurnOn: () -> Void
    let onNotNow: () -> Void
    #if os(tvOS)
    @FocusState private var turnOnFocused: Bool
    #endif

    static func body(iCloudOn: Bool) -> String {
        "Another device already syncs this account through Dispatcharr. "
            + (iCloudOn ? "Turn it on here too, alongside iCloud?" : "Turn it on here too?")
    }

    var body: some View {
        let tv: Bool = {
            #if os(tvOS)
            return true
            #else
            return false
            #endif
        }()
        SyncStepFrame {
            VStack(spacing: tv ? 20 : 12) {
                Text("Dispatcharr Sync is on for this account")
                    .scaledFont(tv ? .system(size: 38, weight: .semibold) : .headlineLarge)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.body(iCloudOn: iCloudOn))
                    .scaledFont(tv ? .system(size: 24).subtext() : .bodyMedium.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                SyncStepPrimaryButton(title: "Turn On") { onTurnOn() }
                #if os(tvOS)
                .focused($turnOnFocused)
                #endif
                .padding(.top, 8)
                SyncStepSecondaryButton(title: "Not Now") { onNotNow() }
                Text("You can change this later in Settings > Sync.")
                    .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .multilineTextAlignment(.center)
            }
            .onboardingPadWidth(560, other: tv ? 900 : 520)
        }
        #if os(tvOS)
        .onAppear { turnOnFocused = true }
        .onExitCommand { onNotNow() }
        #endif
    }
}

// MARK: - "Dispatcharr Sync data is missing"

/// The record vanished after this device's first read: the cycle is paused and nothing is
/// written until the owner answers. Waits while a player or Multiview is up.
struct DsyncRecordMissingHost: ViewModifier {
    let onboardingVisible: Bool
    @ObservedObject private var dsync = DispatcharrSyncManager.shared
    @ObservedObject private var player = PlayerSession.shared
    @ObservedObject private var multiview = MultiviewStore.shared
    @ObservedObject private var profiles = ProfileManager.shared

    private var showing: Bool {
        // Waits for the launch PIN gate too (security fix 2026-11-12).
        (dsync.recordMissingPrompt || simulated) && !onboardingVisible && player.mode == .idle && multiview.tiles.isEmpty
            && !profiles.launchLocked
    }

    /// DEBUG only: `-dsyncMissingRecordSimulate YES` shows the prompt for simulator checks;
    /// either answer only dismisses it and touches no sync state.
    @State private var simulated: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "dsyncMissingRecordSimulate")
        #else
        return false
        #endif
    }()

    func body(content: Content) -> some View {
        let binding = Binding(get: { showing }, set: { _ in })
        content
            #if os(tvOS)
            .fullScreenCover(isPresented: binding) { prompt }
            #else
            .sheet(isPresented: binding) {
                prompt.interactiveDismissDisabled().environment(\.syncStepFitsPadSheet, true)
            }
            #endif
    }

    private var prompt: some View {
        DsyncRecordMissingView(
            onUploadAgain: {
                if simulated { simulated = false; return }
                DispatcharrSyncManager.shared.resolveMissingRecord(uploadAgain: true)
            },
            onTurnOff: {
                if simulated { simulated = false; return }
                DispatcharrSyncManager.shared.resolveMissingRecord(uploadAgain: false)
            })
    }
}

struct DsyncRecordMissingView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let onUploadAgain: () -> Void
    let onTurnOff: () -> Void
    #if os(tvOS)
    @FocusState private var uploadFocused: Bool
    #endif

    var body: some View {
        let tv: Bool = {
            #if os(tvOS)
            return true
            #else
            return false
            #endif
        }()
        SyncStepFrame {
            VStack(spacing: tv ? 20 : 12) {
                Text("Dispatcharr Sync data is missing")
                    .scaledFont(tv ? .system(size: 38, weight: .semibold) : .headlineLarge)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("The sync data for this account is no longer on your Dispatcharr server. Upload this device's data again, or leave the server alone and turn Dispatcharr Sync off on this device?")
                    .scaledFont(tv ? .system(size: 24).subtext() : .bodyMedium.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                SyncStepPrimaryButton(title: "Upload Again") { onUploadAgain() }
                #if os(tvOS)
                .focused($uploadFocused)
                #endif
                .padding(.top, 8)
                SyncStepSecondaryButton(title: "Turn Off") { onTurnOff() }
            }
            .onboardingPadWidth(560, other: tv ? 900 : 520)
        }
        #if os(tvOS)
        .onAppear { uploadFocused = true }
        .onExitCommand { }
        #endif
    }
}
