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
    /// Came from the Welcome "Sync with Dispatcharr" card: turn on without asking.
    let autoEnable: Bool
    /// Set when the playlist was just signed in from a Dispatcharr user QR.
    var qrSignIn: QrImportBus.SignIn? = nil
    let onDone: () -> Void
    /// Cancel on the "Which setup" prompt.
    let onCancel: () -> Void

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
                        onDone()
                    }
                }
                Text("You can change this later in Settings > Sync.")
                    .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: tv ? 900 : 520)
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
            .frame(maxWidth: tv ? 900 : 520)
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Restore progress

/// Shown for the whole iCloud restore stretch; replaces Welcome so its cards are not focusable underneath.
struct OnboardingRestoreProgressView: View {
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
