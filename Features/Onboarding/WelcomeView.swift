import SwiftUI
import SwiftData

/// Welcome screen (onboarding redesign, approved 2026-10-29).
///
/// Why the redesign: the old screen led with a logo, a tagline, and a list
/// of source types that were not tappable, so the first real decision (where
/// does your content live) sat below the fold. The new screen asks that
/// question first, splits "start here" from "keep your devices in sync", and
/// puts Skip one step after the last row so it is never hunted for.
///
/// Layout follows size classes only. Compact width (iPhone, and the outer
/// display of a foldable) is a single column with the phone headline;
/// regular width (iPad, Mac, and a foldable's inner display) is two columns,
/// brand left and cards right, with the tablet headline. No device-specific
/// branching: the system's own bars are respected through the safe area.
struct WelcomeView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = iCloudSyncEnabledDefault
    @ObservedObject private var syncManager = SyncManager.shared
    @ObservedObject private var hold = OnboardingHold.shared
    @Query private var servers: [ServerConnection]

    /// Where the Welcome chain is (WelcomeSyncChain). Each stage replaces Welcome
    /// entirely, so Welcome's cards are never focusable underneath on tvOS.
    private enum Stage: Equatable {
        case welcome
        /// "Setting Up" between Connect and the first chain step (Android shows its
        /// Setting Up card there), so Welcome is never visible in between.
        case settingUp
        case restoring
        case backupUpdate(String)
        case dispatcharrSync(auto: Bool)
        case cloudOffer
        /// "Who is this profile for?" (Standard server login only), before the sync step.
        case roleStep(String, auto: Bool)
        /// "Who watches on this iPhone?" closes the Dispatcharr chain.
        case addProfiles(String)
    }
    @State private var stage: Stage = .welcome

    /// Welcome card selections (Android: the cards toggle selection; Continue runs the chain).
    /// A Cancel on the setup prompt comes back with the last selections kept.
    @State private var cloudSelected = WelcomeSyncChain.kept?.cloud ?? false
    @State private var dispatcharrSelected = WelcomeSyncChain.kept?.dispatcharr ?? false
    /// Continue with Dispatcharr selected alongside iCloud: the Dispatcharr part runs after the restore.
    @State private var chainDispatcharr = false
    /// Connect a Server pushed from Welcome (nil type: the picker; Dispatcharr: the sync card).
    @State private var showConnect = false
    @State private var connectType: ServerType?
    /// Dispatcharr Sync on after the connect (the "Sync with Dispatcharr" card).
    @State private var enableAfterConnect = false
    /// The last Dispatcharr sign-in made from a user QR, for the restore offer.
    @State private var qrSignIn: QrImportBus.SignIn?
    @State private var backupBusy = false
    @State private var cloudOfferBusy = false
    /// The role step made this a kid-only device: Add Profiles is skipped.
    @State private var childOnly = false
    /// "Set up a TV with this playlist" from Add Profiles (iPhone and iPad).
    @State private var setUpTvFor: ServerConnection?

    /// Discord (Glitzbr): he turned iCloud sync on during setup and a
    /// customised remote map from a different-generation Apple TV landed on
    /// this one. By the time he found the Sync Categories screen the data had
    /// already arrived, so the choice has to be offered BEFORE the first pull
    /// - which is what this sheet does. Logan 2026-08-10.
    @State private var showCategoryChooser = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    #if os(tvOS)
    private enum Field: Hashable { case connect, cloudSync, dispatcharr, proceed, skip }
    @FocusState private var focus: Field?
    #endif

    private var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    private var isRegularWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    // MARK: Copy

    private var headline: String {
        // Android WelcomeScreen.kt: two-line headline, no body paragraph.
        if isTV { return "Welcome.\nLet's get your TV connected." }
        return isRegularWidth ? "Welcome.\nLet's get connected." : "Welcome.\nLet's set up your content."
    }

    private var connectDetail: String {
        isTV
            ? "Enter the details yourself. Dispatcharr, Xtream Codes, or an M3U playlist with an optional EPG."
            : "Dispatcharr, Xtream Codes, or an M3U playlist with an optional EPG."
    }

    private var cloudSyncDetail: String {
        isTV
            ? "Turns on sync from here on. If you already have a backup, it restores it too."
            : "Turns on sync. Restores a backup if you have one."
    }

    private var dispatcharrDetail: String {
        isTV
            ? "Connects your server and turns on sync for favorites, progress, and settings."
            : "Connects your server and turns on sync."
    }

    private var skipFootnote: String {
        isTV
            ? "Look around first. You can connect a server any time from Settings."
            : "You can connect a server any time from Settings."
    }

    // MARK: Body

    var body: some View {
        stageView
            .navigationDestination(isPresented: $showConnect) {
                AddServerView(initialType: connectType, isOnboarding: true)
            }
            .onChange(of: servers.count) { old, new in
                // The playlist saved under Connect: cover Welcome before the pop reveals it.
                if new > old && showConnect && hold.holding && stage == .welcome {
                    debugLog("[SYNC] chain: setting up (playlist saved)")
                    stage = .settingUp
                }
            }
            .onChange(of: showConnect) { _, shown in
                if !shown { Task { @MainActor in await afterConnect() } }
            }
            .onAppear {
                if WelcomeSyncChain.consumeReturnedFromChoice() {
                    debugLog("[SYNC] welcome: back from the setup prompt, selections kept")
                }
            }
    }

    @ViewBuilder
    private var stageView: some View {
        switch stage {
        case .welcome:
            welcomeBody
        case .settingUp:
            OnboardingSettingUpView()
        case .restoring:
            OnboardingRestoreProgressView()
        case .backupUpdate(let key):
            BackupUpdateStepView(
                busy: backupBusy,
                onUpdate: {
                    guard !backupBusy else { return }
                    backupBusy = true
                    CloudSnapshotSync.shared.acceptIdUpdate(key)
                    backupBusy = false
                    Task { @MainActor in await afterRestoreSteps() }
                },
                onNotNow: {
                    BackupUpdateOffer.decline(key)
                    Task { @MainActor in await afterRestoreSteps() }
                }
            )
            .navigationBarHidden(true)
        case .dispatcharrSync(let auto):
            DispatcharrSyncStepView(
                autoEnable: auto,
                qrSignIn: qrSignIn,
                onDone: { afterDispatcharrStep() },
                onCancel: {
                    // Rule 4 prompt Cancel: back to Welcome, selections kept.
                    WelcomeSyncChain.markReturnedFromChoice()
                    chainDispatcharr = false
                    enableAfterConnect = false
                    stage = .welcome
                }
            )
        case .cloudOffer:
            CloudBackupOfferStepView(
                busy: cloudOfferBusy,
                onTurnOn: {
                    cloudOfferBusy = true
                    iCloudSyncEnabled = true
                    SyncManager.shared.syncSettingChanged(enabled: true)
                    debugLog("[CLOUD] enabled from onboarding (backup offer)")
                    cloudOfferBusy = false
                    toAddProfiles("cloud offer on")
                },
                onNotNow: { toAddProfiles("cloud offer not now") }
            )
        case .roleStep(let pid, let auto):
            ProfileRoleStepView(playlistId: pid) { child in
                childOnly = child
                debugLog("[SYNC] chain: Dispatcharr Sync step (childOnly=\(child))")
                stage = .dispatcharrSync(auto: auto)
            }
        case .addProfiles(let pid):
            AddProfilesStepView(playlistId: pid, onboarding: true, onSetUpTv: setUpTvAction(pid)) {
                finish("add profiles done")
            }
            #if os(iOS)
            .sheet(item: $setUpTvFor) { s in SetUpTvView(server: s) { setUpTvFor = nil } }
            #endif
        }
    }

    /// iPhone and iPad only; Apple TV receives a setup, it never sends one.
    private func setUpTvAction(_ pid: String) -> (() -> Void)? {
        #if os(iOS)
        return { setUpTvFor = DsyncLocal.server(pid) }
        #else
        return nil
        #endif
    }

    /// After the sync step and the iCloud offer: Add Profiles, unless the role
    /// step made this a kid-only device (Android afterDriveOffer).
    private func toAddProfiles(_ why: String) {
        if !childOnly, let d = DsyncLocal.activeDispatcharrPlaylist() {
            debugLog("[SYNC] chain: Add Profiles (\(why))")
            stage = .addProfiles(d.id.uuidString)
            return
        }
        finish(why)
    }

    private var welcomeBody: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            GeometryReader { geo in
                // Android WelcomeScreen.kt: two columns only when the window
                // is wider than tall (screenWidthDp >= 720 and height < 720);
                // tablet portrait uses the single centered column (max 560).
                // iPad is regular/regular in both orientations, so the
                // geometry decides. iPhone (compact) and tvOS keep their
                // existing layout; iPad content is vertically centered.
                let iPad = !isTV && isRegularWidth
                let twoColumn = isTV || (iPad && geo.size.width > geo.size.height)
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if twoColumn {
                            HStack(alignment: iPad ? .center : .top, spacing: isTV ? 80 : 48) {
                                brandColumn
                                    .frame(maxWidth: .infinity, alignment: iPad ? .center : .leading)
                                choicesColumn
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: isTV ? 1600 : 1000)
                        } else {
                            VStack(alignment: .leading, spacing: 28) {
                                brandColumn
                                choicesColumn
                            }
                            .frame(maxWidth: 560)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, isTV ? 80 : (iPad ? 48 : 20))
                    .padding(.vertical, isTV ? 60 : 24)
                    .frame(minHeight: iPad ? geo.size.height : nil)
                }
            }
        }
        .navigationBarHidden(true)
        #if os(tvOS)
        .defaultFocus($focus, .connect)
        // Menu at the top of setup never closes the app.
        .onExitCommand { }
        #endif
        .sheet(isPresented: $showCategoryChooser) {
            OnboardingSyncCategoryChooser(
                onContinue: {
                    showCategoryChooser = false
                    // Only NOW does anything come down: the categories the
                    // user just chose are already written, and
                    // syncSettingChanged is what kicks off the first pull.
                    // Sync stays on from here whether or not a backup exists.
                    Task { @MainActor in await runCloudRestore() }
                },
                onCancel: {
                    showCategoryChooser = false
                    // Backing out leaves sync off entirely - nothing was
                    // pulled, so there is nothing to undo.
                    chainDispatcharr = false
                    hold.end("category chooser cancelled")
                }
            )
        }
    }

    private var brandColumn: some View {
        VStack(alignment: .leading, spacing: isTV ? 20 : 12) {
            // The logo with the name sits centered over the headline
            // (Android WelcomeLogo). On iPad it is larger and lifted a little.
            VStack(alignment: .center, spacing: isTV ? 20 : (isRegularWidth ? 20 : 12)) {
                HStack(spacing: isTV ? 16 : (isRegularWidth ? 16 : 10)) {
                    Image("AerioLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: isTV ? 64 : (isRegularWidth ? 96 : 44))
                    Text("AerioTV")
                        .scaledFont(.system(size: isTV ? 44 : (isRegularWidth ? 56 : 28), weight: .bold))
                        .foregroundColor(.textPrimary)
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: isRegularWidth && !isTV ? nil : .infinity)
                .padding(.vertical, isRegularWidth && !isTV ? 0 : 12)
                Text(headline)
                    .scaledFont(.system(size: isTV ? 56 : (isRegularWidth ? 40 : 30), weight: .bold))
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: isRegularWidth && !isTV, vertical: true)
            }
            if isTV {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                    Text("Back returns to the previous step at any time")
                }
                .scaledFont(.system(size: 20).subtext())
                .foregroundColor(Color.contrastText(.textTertiary))
                .padding(.top, 24)
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var choicesColumn: some View {
        VStack(alignment: .leading, spacing: isTV ? 16 : 10) {
            OnboardingSectionLabel("Start here")

            OnboardingActionCard(
                icon: "server.rack",
                title: "Connect a Server",
                detail: connectDetail,
                highlighted: true
            ) {
                startConnect(type: nil, enableSync: false)
            }
            #if os(tvOS)
            .focused($focus, equals: .connect)
            #endif

            OnboardingSectionLabel("Keep your devices in sync")
                .padding(.top, isTV ? 20 : 14)
            Text("Pick one or both, then Continue.")
                .scaledFont(isTV ? .system(size: 20).subtext() : .bodySmall.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))

            // Dispatcharr first, iCloud second (Android order).
            OnboardingActionCard(
                icon: "key.fill",
                title: "Sync with Dispatcharr",
                detail: dispatcharrDetail,
                isOn: dispatcharrSelected
            ) {
                dispatcharrSelected.toggle()
            }
            .accessibilityAddTraits(dispatcharrSelected ? .isSelected : [])
            #if os(tvOS)
            .focused($focus, equals: .dispatcharr)
            #endif

            OnboardingActionCard(
                icon: "icloud.fill",
                title: "Sync with iCloud",
                detail: cloudSyncDetail,
                isOn: cloudSelected,
                isBusy: syncManager.isImporting
            ) {
                guard !syncManager.isImporting else { return }
                cloudSelected.toggle()
            }
            .accessibilityAddTraits(cloudSelected ? .isSelected : [])
            #if os(tvOS)
            .focused($focus, equals: .cloudSync)
            #endif

            // Directly under the sync rows: one press down from the last row.
            // Continue replaces Skip while a card is selected.
            if cloudSelected || dispatcharrSelected {
                OnboardingPillButton(title: "Continue", filled: true, fullWidth: true) {
                    continueSync(cloud: cloudSelected, dispatcharr: dispatcharrSelected)
                }
                #if os(tvOS)
                .focused($focus, equals: .proceed)
                #endif
                .padding(.top, isTV ? 16 : 10)
            } else {
                // Phone and tablet center Skip and its line; TV keeps them
                // leading (Android SkipPill centered = !isTv).
                VStack(alignment: isTV ? .leading : .center, spacing: 8) {
                    OnboardingPillButton(title: "Skip for now", filled: false) {
                        Task { @MainActor in await SetupSourceCoordinator.shared.releaseHeld() }
                        hold.end("skip")
                        hasCompletedOnboarding = true
                    }
                    #if os(tvOS)
                    .focused($focus, equals: .skip)
                    #endif
                    Text(skipFootnote)
                        .scaledFont(isTV ? .system(size: 20).subtext() : .bodySmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                        .multilineTextAlignment(isTV ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: isTV ? .leading : .center)
                .padding(.top, isTV ? 16 : 10)
            }
        }
    }

    // MARK: - Welcome chain (WelcomeSyncChain)

    /// Continue: iCloud first (chooser, then restore), then the Dispatcharr part.
    private func continueSync(cloud: Bool, dispatcharr: Bool) {
        guard !syncManager.isImporting else { return }
        if cloud { WelcomeSyncChain.markAnswered(SyncProvidersRules.ICLOUD) }
        if dispatcharr { WelcomeSyncChain.markAnswered(SyncProvidersRules.DISPATCHARR) }
        WelcomeSyncChain.keepSelection(cloud: cloud, dispatcharr: dispatcharr)
        debugLog("[SYNC] welcome continue plan=\(WelcomeSyncChain.plan(cloud: cloud, dispatcharr: dispatcharr, restoredIsDispatcharr: false, cloudAvailable: cloudAvailable).map(\.rawValue).joined(separator: ","))")
        hold.begin("welcome continue")
        // Rule 4: with both selected, iCloud restores playlists and credentials
        // first; shared data waits for the setup choice.
        if cloud && dispatcharr { SetupSourceCoordinator.shared.holdShared() }
        if !cloud {
            // Same flow as Connect a Server > Dispatcharr (Scan QR code or Enter
            // details), with Dispatcharr Sync turned on after the connect (Android 7d16d839).
            startConnect(type: nil, enableSync: true)
            return
        }
        chainDispatcharr = dispatcharr
        // Ask what should come in BEFORE any of it does.
        showCategoryChooser = true
    }

    private var cloudAvailable: Bool { CloudAccount.isAvailable }

    private func startConnect(type: ServerType?, enableSync: Bool) {
        hold.begin(enableSync ? "connect for Dispatcharr Sync" : "connect a server")
        connectType = type
        enableAfterConnect = enableSync
        showConnect = true
    }

    /// iCloud Sync on, then wait for the restore; the playlist arrives first.
    private func runCloudRestore() async {
        stage = .restoring
        iCloudSyncEnabled = true
        SyncManager.shared.syncSettingChanged(enabled: true)
        debugLog("[CLOUD] enabled from onboarding (sync card), restoring")
        // syncSettingChanged sets isImporting at once and clears it when the
        // import lands or its own 12 s timeout fires.
        let end = Date().addingTimeInterval(20)
        try? await Task.sleep(nanoseconds: 300_000_000)
        while syncManager.isImporting && Date() < end { try? await Task.sleep(nanoseconds: 250_000_000) }
        let restored = await waitForActivePlaylist(seconds: servers.isEmpty ? 3 : 10)
        SyncProvidersOfferStore.arm("onboarding iCloud restore")
        debugLog("[CLOUD] onboarding restore done playlists=\(servers.count) activated=\(restored)")
        if restored, let key = BackupUpdateOffer.offerAfterRestore(),
           WelcomeSyncChain.showBackupUpdate(cloud: true, backupNeedsUpdate: true) {
            stage = .backupUpdate(key)
            return
        }
        await afterRestoreSteps()
    }

    /// After the restore (and the backup update step): Connect a Server, the sync
    /// step on the restored playlist, Main, or back to Welcome when nothing came in.
    private func afterRestoreSteps() async {
        backupBusy = false
        let restoredIsD = DsyncLocal.activeDispatcharrPlaylist() != nil
        if WelcomeSyncChain.connectAfterRestore(dispatcharr: chainDispatcharr, restoredIsDispatcharr: restoredIsD) {
            chainDispatcharr = false
            stage = .welcome
            startConnect(type: .dispatcharrAPI, enableSync: true)
            return
        }
        if restoredIsD && !DispatcharrSyncManager.shared.isEnabled {
            // Both selected: the step turns on without another tap. iCloud only: it asks.
            let auto = chainDispatcharr
            chainDispatcharr = false
            stage = .dispatcharrSync(auto: auto)
            return
        }
        chainDispatcharr = false
        if !servers.isEmpty {
            finish("restore done")
        } else {
            // Nothing to restore: back on Welcome with iCloud Sync on, as Android.
            stage = .welcome
            cloudSelected = false
            hold.end("no backup")
        }
    }

    /// Back from Connect a Server: a Dispatcharr Direct Connect playlist goes to the sync step.
    private func afterConnect() async {
        guard hold.holding, stage == .welcome || stage == .settingUp else {
            debugLog("[SYNC] after connect: skipped (holding=\(hold.holding))")
            return
        }
        debugLog("[SYNC] after connect: playlists=\(servers.count)")
        if !servers.isEmpty && stage != .settingUp {
            debugLog("[SYNC] chain: setting up")
            stage = .settingUp
        }
        if servers.isEmpty {
            enableAfterConnect = false
            stage = .welcome
            hold.end("connect backed out")
            return
        }
        if await waitForActivePlaylist(seconds: 10), let d = DsyncLocal.activeDispatcharrPlaylist() {
            // Signed in from a Dispatcharr user QR (iPhone and iPad): the step checks for a restore.
            qrSignIn = QrImportBus.takeSignIn(savedApiKey: d.baseApiKey)
            childOnly = false
            debugLog("[SYNC] chain: role step (auto=\(enableAfterConnect))")
            stage = .roleStep(d.id.uuidString, auto: enableAfterConnect)
            enableAfterConnect = false
            return
        }
        enableAfterConnect = false
        finish("connected")
    }

    /// The active playlist loads under the cover (MainTabView); wait for it (bounded).
    private func waitForActivePlaylist(seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if ChannelStore.shared.activeServer != nil && !servers.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return ChannelStore.shared.activeServer != nil && !servers.isEmpty
    }

    private func afterDispatcharrStep() {
        if WelcomeSyncChain.showCloudOffer(cloudOn: iCloudSyncEnabled, cloudAvailable: cloudAvailable) {
            WelcomeSyncChain.markAnswered(SyncProvidersRules.ICLOUD)
            stage = .cloudOffer
            return
        }
        toAddProfiles("dispatcharr step done")
    }

    private func finish(_ why: String) {
        debugLog("[SYNC] chain: finish onboarding (\(why))")
        hold.end(why)
        hasCompletedOnboarding = true
    }

}

// MARK: - Shared onboarding components

private var onboardingIsTV: Bool {
    #if os(tvOS)
    return true
    #else
    return false
    #endif
}

/// Small uppercase section label ("START HERE").
struct OnboardingSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .scaledFont(.system(size: onboardingIsTV ? 20 : 12, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(Color.contrastText(.textTertiary))
    }
}

/// The inside of every onboarding card: icon tile, title, detail, trailing.
struct OnboardingCardContent: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let icon: String
    let title: String
    let detail: String
    var trailing: Trailing = .chevron
    var isFocused: Bool = false

    enum Trailing { case chevron, toggle(Bool), busy, none, symbol(String) }

    var body: some View {
        let tv = onboardingIsTV
        HStack(spacing: tv ? 20 : 14) {
            ZStack {
                RoundedRectangle(cornerRadius: tv ? 12 : 10, style: .continuous)
                    .fill(Color.accentPrimary.opacity(0.15))
                    .frame(width: tv ? 56 : 40, height: tv ? 56 : 40)
                Image(systemName: icon)
                    .scaledFont(.system(size: tv ? 24 : 17, weight: .medium))
                    .foregroundColor(.accentPrimary)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: tv ? 6 : 3) {
                Text(title)
                    .scaledFont(tv ? .system(size: 26, weight: .semibold) : .headlineSmall)
                    .foregroundColor(.textPrimary)
                Text(detail)
                    .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: tv ? 20 : 14, weight: .semibold))
                    .foregroundColor(isFocused ? .accentPrimary : Color.contrastText(.textTertiary))
            case .toggle(let on):
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .scaledFont(.system(size: tv ? 28 : 20))
                    .foregroundColor(on ? .accentPrimary : Color.contrastText(.textTertiary))
            case .busy:
                ProgressView().tint(.accentPrimary)
            case .symbol(let name):
                Image(systemName: name)
                    .scaledFont(.system(size: tv ? 20 : 14, weight: .semibold))
                    .foregroundColor(.accentPrimary)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, tv ? 24 : 14)
        .padding(.vertical, tv ? 20 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Card surface: quiet border, accent border when highlighted or on.
struct OnboardingCardBackground: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    var highlighted: Bool = false
    var radius: CGFloat = onboardingIsTV ? 18 : 14

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentPrimary : Color.borderSubtle,
                                  lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

/// Card that pushes a destination.
struct OnboardingNavCard<Destination: View>: View {
    let destination: Destination
    let icon: String
    let title: String
    let detail: String
    var highlighted: Bool = false
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        NavigationLink(destination: destination) {
            #if os(tvOS)
            OnboardingCardContent(icon: icon, title: title, detail: detail, isFocused: isFocused)
                .background(OnboardingCardBackground(highlighted: highlighted))
            #else
            OnboardingCardContent(icon: icon, title: title, detail: detail)
                .background(OnboardingCardBackground(highlighted: highlighted))
            #endif
        }
        #if os(tvOS)
        // A highlighted card already wears an accent border: ring it white.
        .buttonStyle(TVNoHighlightButtonStyle(isSelected: highlighted))
        .focused($isFocused)
        .tvFocusRingShape(.rounded(18))
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// Card that runs an action (on/off rows).
struct OnboardingActionCard: View {
    let icon: String
    let title: String
    let detail: String
    var highlighted: Bool = false
    var isOn: Bool? = nil
    var isBusy: Bool = false
    /// Expandable cards: chevron.up / chevron.down in place of the chevron.
    var trailingSymbol: String? = nil
    let action: () -> Void
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    init(icon: String, title: String, detail: String, highlighted: Bool = false,
         isOn: Bool? = nil, isBusy: Bool = false, trailingSymbol: String? = nil, action: @escaping () -> Void) {
        self.icon = icon; self.title = title; self.detail = detail
        self.highlighted = highlighted; self.isOn = isOn; self.isBusy = isBusy
        self.trailingSymbol = trailingSymbol
        self.action = action
    }

    private var trailing: OnboardingCardContent.Trailing {
        if isBusy { return .busy }
        if let trailingSymbol { return .symbol(trailingSymbol) }
        if let isOn { return .toggle(isOn) }
        return .chevron
    }

    var body: some View {
        Button(action: action) {
            #if os(tvOS)
            OnboardingCardContent(icon: icon, title: title, detail: detail,
                                  trailing: trailing, isFocused: isFocused)
                .background(OnboardingCardBackground(highlighted: highlighted || isOn == true))
            #else
            OnboardingCardContent(icon: icon, title: title, detail: detail, trailing: trailing)
                .background(OnboardingCardBackground(highlighted: highlighted || isOn == true))
            #endif
        }
        #if os(tvOS)
        // A selected (on) card already wears an accent border: ring it white
        // so focus shows on it (Android 9095b1b4).
        .buttonStyle(TVNoHighlightButtonStyle(isSelected: highlighted || isOn == true))
        .focused($isFocused)
        .tvFocusRingShape(.rounded(18))
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// Capsule pill button: filled (primary) or outlined.
struct OnboardingPillButton: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let title: String
    var filled: Bool = false
    var fullWidth: Bool = false
    /// Optional leading SF Symbol (Android icon + 8 dp + label).
    var systemImage: String? = nil
    /// Overrides the default minimum height (44 pt, 60 on TV).
    var minHeight: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        let tv = onboardingIsTV
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: tv ? 22 : 17, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
                .scaledFont(.system(size: tv ? 24 : 16, weight: .semibold))
                .foregroundColor(filled ? .white : .textPrimary)
                .padding(.horizontal, tv ? 36 : 22)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(minHeight: minHeight ?? (tv ? 60 : 44))
                .background {
                    if filled {
                        Capsule(style: .continuous).fill(LinearGradient.accentGradient)
                    } else {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.borderSubtle, lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        #if os(tvOS)
        // Android 9095b1b4: an accent ring vanishes on the accent fill, so a
        // filled pill rings in white and grows 1.04.
        .buttonStyle(TVNoHighlightButtonStyle(isSelected: filled, scalesOnFocus: filled))
        .tvFocusRingShape(.capsule)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// Step indicator dots ("Step 1 of 3").
struct OnboardingStepDots: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let current: Int
    let total: Int

    var body: some View {
        let tv = onboardingIsTV
        HStack(spacing: tv ? 10 : 6) {
            ForEach(1...total, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.accentPrimary : Color.borderSubtle)
                    .frame(width: step == current ? (tv ? 28 : 18) : (tv ? 10 : 6),
                           height: tv ? 10 : 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

// MARK: - tvOS Onboarding Components
#if os(tvOS)

/// Shared teal-tinted card background, matches the Settings pattern.
private func tvOnboardingCardBG(_ focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(focused ? Color.accentPrimary.opacity(0.18) : Color.cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentPrimary.opacity(focused ? 0.65 : 0.10),
                        lineWidth: focused ? 2.5 : 1)
        }
}

/// One category row in the onboarding "what should come in" sheet.
///
/// Deliberately NOT a raw SwiftUI `Toggle`. On tvOS a Toggle draws the
/// system focus platter - a pale slab that washed out both the white title
/// and the accent-tinted subtitle, so the focused row was the HARDEST one
/// to read (Logan 2026-08-10, from Apple TV screenshots). It also centers
/// its label's text, which is why the subtitles were centre-aligned under
/// left-aligned titles.
///
/// Same shape as `TVOnboardingImportButton` above: own the focus visual via
/// `tvOnboardingCardBG`, keep the text block left-aligned, and light the
/// On/Off indicator white while focused so it reads against the fill.
private struct TVOnboardingCategoryRow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let category: SyncCategory
    @Binding var isOn: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: category.icon)
                        .scaledFont(.system(size: 20, weight: .medium))
                        .foregroundColor(.accentPrimary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.displayName)
                        .scaledFont(.system(size: 24, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(category.briefSubtitle)
                        .scaledFont(.system(size: 18).subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Circle()
                        .fill(isOn ? Color.accentPrimary : Color.textTertiary)
                        .frame(width: 10, height: 10)
                    Text(isOn ? "On" : "Off")
                        .scaledFont(.system(size: 24, weight: .semibold))
                        .foregroundColor(isOn
                            ? (isFocused ? .white : .accentPrimary)
                            : (isFocused ? .white : .textTertiary))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .background(tvOnboardingCardBG(isFocused))
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Filled primary CTA for onboarding sheets. `.buttonStyle(.plain)` leaves
/// tvOS free to stack its own pale platter behind the gradient; this owns
/// the focus visual instead - the fill stays put and focus reads as a white
/// border plus a small grow, so the white label never loses contrast.
private struct TVOnboardingPrimaryButton: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let title: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledFont(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 64)
                .background(LinearGradient.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0),
                                      lineWidth: 3)
                }
        }
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Secondary text button ("Not now"). Same treatment as
/// `TVOnboardingSkipButton` - tint on focus rather than letting tvOS drop a
/// light pill behind dim grey text, which is what made it unreadable
/// exactly when it was selected.
private struct TVOnboardingTextButton: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let title: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(title, action: action)
            .scaledFont(.system(size: 22))
            .foregroundColor(isFocused ? .accentPrimary : .textTertiary)
            .buttonStyle(TVNoHighlightButtonStyle())
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// "Skip for now" text button with subtle focus highlight.
private struct TVOnboardingSkipButton: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button("Skip for now", action: action)
            .scaledFont(.system(size: 22))
            .foregroundColor(isFocused ? .accentPrimary : .textTertiary)
            .buttonStyle(TVNoHighlightButtonStyle())
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

#endif

// MARK: - Onboarding Sync Category Chooser

/// Shown the moment the user opts into iCloud sync during setup, BEFORE the
/// first pull runs.
///
/// Discord (Glitzbr, 2026-08-10): he enabled sync on a second Apple TV and a
/// remote button map customised for a different-generation remote came down
/// with everything else. The per-category controls already existed, but they
/// live in Settings, and by the time you go looking for them the data has
/// already landed. Logan's call: ask during onboarding, when the answer still
/// changes the outcome.
///
/// Everything defaults ON, so the common case is one press. The toggles write
/// the same `syncEnabled.<rawValue>` defaults keys the Settings screen binds
/// to - one source of truth, and a choice made here shows up there.
struct OnboardingSyncCategoryChooser: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let onContinue: () -> Void
    let onCancel: () -> Void

    /// Local until Continue, so backing out cannot leave a half-applied set.
    @State private var selection: [SyncCategory: Bool] = Dictionary(
        uniqueKeysWithValues: SyncCategory.allCases.map { ($0, $0.defaultEnabled) }
    )

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What should come in from iCloud?")
                            .scaledFont(.headlineLarge)
                            .foregroundColor(.textPrimary)
                        Text("You can change any of this later in Settings, and each device chooses for itself.")
                            .scaledFont(.bodySmall.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                    }

                    // Rows sit directly on the sheet, each carrying its own
                    // card. They used to be dividers inside ANOTHER rounded
                    // card, which read as pills nested in a pill.
                    VStack(spacing: 8) {
                        ForEach(SyncCategory.allCases) { category in
                            let binding = Binding(
                                get: { selection[category] ?? category.defaultEnabled },
                                set: { selection[category] = $0 }
                            )
                            #if os(tvOS)
                            TVOnboardingCategoryRow(category: category, isOn: binding)
                            #else
                            Toggle(isOn: binding) {
                                SettingsRow(icon: category.icon,
                                            iconColor: .accentPrimary,
                                            title: category.displayName,
                                            subtitle: category.briefSubtitle)
                            }
                            .tint(.accentPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.elevatedBackground)
                            )
                            #endif
                        }
                    }

                    VStack(spacing: 10) {
                        let commit = {
                            // Commit BEFORE the caller starts the pull.
                            for (category, isOn) in selection {
                                UserDefaults.standard.set(isOn, forKey: category.defaultsKey)
                            }
                            onContinue()
                        }
                        #if os(tvOS)
                        TVOnboardingPrimaryButton(title: "Turn On iCloud Sync", action: commit)
                        TVOnboardingTextButton(title: "Not now", action: onCancel)
                        #else
                        Button(action: commit) {
                            Text("Turn On iCloud Sync")
                                .scaledFont(.headlineMedium)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 48)
                                .background(LinearGradient.accentGradient)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Not now", action: onCancel)
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textTertiary)
                        #endif
                    }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }
}
