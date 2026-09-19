import SwiftUI
import SwiftData

// MARK: - Sync Stage

/// Represents a loading step shown during server sync.
///
/// Marked internal (no `private` / `fileprivate`) so `MainTabView` can
/// build a stage list for `ServerSyncView`'s initial-launch mode. In
/// onboarding mode the view still builds its own stages; in
/// initial-launch mode the parent derives them from observable stores.
struct SyncStage: Identifiable, Equatable {
    let id: String
    let label: String
    var status: StageStatus = .pending

    enum StageStatus: Equatable {
        case pending
        case loading
        case done(String)   // detail text (e.g. "2,127 channels")
        case failed(String) // error text
    }

    var icon: String {
        switch status {
        case .pending:  return "circle"
        case .loading:  return "arrow.triangle.2.circlepath"
        case .done:     return "checkmark.circle.fill"
        case .failed:   return "exclamationmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch status {
        case .pending:  return .textTertiary
        case .loading:  return .accentPrimary
        case .done:     return .statusOnline
        case .failed:   return .statusLive
        }
    }
}

// MARK: - Server Sync View

/// Full-screen loading screen shown both after a server is manually
/// added AND during initial-launch hydration. Displays step-by-step
/// progress as channels, groups, EPG, VOD, DVR, and preferences load.
///
/// Two presentation modes are supported via `Mode`:
///
/// - `.onboarding(server:)` — the view drives its own fetches against
///   a newly-added `ServerConnection`, flipping stages as each phase
///   completes. The user dismisses via a "Continue to Live TV" button
///   once every stage is done.
///
/// - `.initialLaunch(stages:onContinueAnyway:)` — the parent
///   (`MainTabView`) derives stage states from its observable stores
///   and passes them in. This view runs no fetches itself; it simply
///   renders the provided stages and the long-wait banner if the
///   initial load stalls. The parent decides when to dismiss.
///
/// Using one view for both flows keeps the "Setting Up …" experience
/// visually identical whether the user reaches it via "Save Playlist"
/// in Settings or via a cold app launch that still needs to hydrate
/// channels / EPG / VOD / DVR from disk or network.
struct ServerSyncView: View {
    enum Mode {
        /// After the user manually adds or edits a server. The view
        /// drives its own fetches and owns the stage state.
        case onboarding(server: ServerConnection)

        /// After app launch, while `MainTabView`'s stores hydrate.
        /// The parent supplies pre-derived stages and an escape-hatch
        /// callback for the "Skip" button. v1.6.10: dropped the
        /// `serverName` parameter — the loading screen no longer
        /// renders the playlist name (the "Setting Up" headline is
        /// enough context, and the playlist label was visually noisy
        /// on multi-server installs where the displayed name was
        /// arbitrary anyway, just `allServers.first?.name`).
        case initialLaunch(
            stages: [SyncStage],
            onContinueAnyway: () -> Void
        )

        /// Edit Playlist > Save (2026-09-18, Android parity). Same screen,
        /// same rows, driven by `PlaylistSaveProgress` instead of by this
        /// view or by MainTabView's stores. There is no Skip and no
        /// dismissal: the cover owns the screen until the save resolves,
        /// so nothing in the form can be edited mid-save.
        case saving(stages: [SyncStage])
    }

    let mode: Mode
    /// Headline over the stage card. "Setting Up" for the add and launch
    /// flows; Edit Playlist passes "Saving Changes". Parameterized rather
    /// than forked into a second view so the two screens cannot drift.
    var title: String = "Setting Up"
    @Environment(\.dismiss) private var dismiss

    // MARK: Onboarding-only state

    // 4-stage progress: EPG (channels + guide), VOD (movies & series),
    // DVR (recordings — Dispatcharr only, else skipped in-place), and
    // Preferences (iCloud pull when sync is enabled, else skipped in-place).
    @State private var onboardingStages: [SyncStage] = [
        SyncStage(id: "epg",          label: "Loading EPG"),
        SyncStage(id: "vod",          label: "Loading VOD"),
        SyncStage(id: "dvr",          label: "Loading DVR"),
        SyncStage(id: "preferences",  label: "Loading preferences"),
    ]
    @State private var allDone = false
    @State private var syncTask: Task<Void, Never>?

    // MARK: Initial-launch-only state (long-wait banner)

    /// Wall-clock timestamp when the cover first appeared. Compared
    /// against `Date()` on every tick rather than incrementing a
    /// counter — a counter was susceptible to a double-fire bug if
    /// `onAppear` ran twice (two tick-timers → counter advanced at
    /// 2 Hz → banner appeared at wall-clock 5s instead of 10s).
    @State private var startedAt: Date? = nil
    /// Driven by the wall-clock check below. Separate from
    /// `startedAt` so body observes a simple @Published bool.
    @State private var isTakingTooLong: Bool = false
    /// 1 Hz tick used only to re-evaluate the wall-clock comparison —
    /// the tick's own count is not the source of truth.
    @State private var elapsedTimer: Timer?

    /// The cover stays silent for this long before surfacing the
    /// long-wait banner + Skip escape hatch. 30s is comfortably past
    /// a healthy Dispatcharr server's first complete XMLTV parse
    /// (logs show typical finishes under 12s) so users on normal
    /// networks never see the banner; users whose server is offline
    /// see it after a useful signal, not a panicked flash.
    private let longWaitThresholdSeconds: TimeInterval = 30

    // MARK: Mode-derived accessors

    private var currentStages: [SyncStage] {
        switch mode {
        case .onboarding:
            return onboardingStages
        case .initialLaunch(let stages, _):
            return stages
        case .saving(let stages):
            return stages
        }
    }

    private var interactiveDismissDisabled: Bool {
        switch mode {
        case .onboarding:     return !allDone
        case .initialLaunch:  return true
        case .saving:         return true
        }
    }

    /// True while a save is in flight: the cover swallows Menu / Back and
    /// offers no dismissal affordance at all.
    private var isSavingMode: Bool {
        if case .saving = mode { return true }
        return false
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo + titles
                VStack(spacing: 12) {
                    Image("AerioLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .accentPrimary.opacity(0.3), radius: 20, y: 4)

                    Text(title)
                        .scaledFont(.headlineLarge)
                        .foregroundColor(.textPrimary)
                }

                // Progress stages
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(currentStages) { stage in
                        stageRow(stage)
                        if stage.id != currentStages.last?.id {
                            Rectangle()
                                .fill(Color.borderSubtle)
                                .frame(width: 1, height: 16)
                                .padding(.leading, 15)
                        }
                    }
                }
                .padding(20)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // On Apple TV the outer VStack is full-screen-width (~1920pt).
                // Letting the card stretch edge-to-edge with only 32pt padding
                // leaves the loading rows pinned far to the left on a big
                // display, visually disconnected from the centered logo + title
                // above. Constraining to a readable max width + letting the
                // outer VStack's default .center alignment position it keeps
                // the card visually aligned with the rest of the setup screen.
                // iPhone / iPad keep the existing 32pt padding — the screen
                // isn't wide enough there for the stretch to look wrong.
                #if os(tvOS)
                .frame(maxWidth: 720)
                #else
                .padding(.horizontal, 32)
                #endif
                .animation(.easeInOut(duration: 0.3), value: currentStages)

                Spacer()

                // Bottom actions — differ by mode
                bottomActions

                Spacer().frame(height: 20)
            }
        }
        .interactiveDismissDisabled(interactiveDismissDisabled)
        // While saving, Menu / Back must not tear the cover down and drop
        // the user back into a form that is being written through. The
        // modifier is applied ONLY in saving mode so the add and launch
        // covers keep whatever Menu behavior they have today.
        #if os(tvOS)
        .modifier(SwallowExitCommand(active: isSavingMode))
        #endif
        .task {
            await runOnboardingIfNeeded()
        }
        .onAppear {
            startLongWaitTimerIfNeeded()
        }
        .onDisappear {
            cleanupLongWaitTimer()
        }
    }

    // MARK: - Bottom Actions

    @ViewBuilder
    private var bottomActions: some View {
        switch mode {
        case .onboarding:
            if allDone {
                PrimaryButton("Continue to Live TV", icon: "play.tv") {
                    dismiss()
                }
                .padding(.horizontal, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                #if os(tvOS)
                TVSkipButton {
                    syncTask?.cancel()
                    dismiss()
                }
                #else
                Button("Skip") {
                    syncTask?.cancel()
                    dismiss()
                }
                .scaledFont(.bodyMedium)
                .foregroundColor(Color.contrastText(.textSecondary))
                #endif
            }

        case .initialLaunch(_, let onContinueAnyway):
            // Initial launch: banner fades in at 15s if the load
            // stalls; Skip button is always available so a user
            // on a dead server isn't trapped behind a spinner.
            VStack(spacing: 16) {
                if isTakingTooLong {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.statusWarning)
                        Text("This is taking longer than usual. If you have a large playlist or VOD library, this is expected behavior on a fresh install. If not, your server or IPTV source might be offline or unreachable.")
                            .scaledFont(.system(size: 14).subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                #if os(tvOS)
                TVSkipButton { onContinueAnyway() }
                #else
                Button("Skip") {
                    onContinueAnyway()
                }
                .scaledFont(.bodyMedium)
                .foregroundColor(Color.contrastText(.textSecondary))
                #endif
            }
            .animation(.easeInOut(duration: 0.25), value: isTakingTooLong)

        case .saving:
            // No Skip: abandoning a half-applied credential change is the
            // one outcome this screen exists to prevent.
            EmptyView()
        }
    }

    // MARK: - Stage Row

    private func stageRow(_ stage: SyncStage) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if case .loading = stage.status {
                    ProgressView()
                        .tint(.accentPrimary)
                        .scaleEffect(0.8)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: stage.icon)
                        .font(.system(size: 16, weight: .medium))  // glyph in a fixed box: not text, stays fixed
                        .foregroundColor(stage.iconColor)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.label)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(
                        stage.status == .pending ? .textTertiary : .textPrimary
                    )

                if case .done(let detail) = stage.status, !detail.isEmpty {
                    Text(detail)
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                }
                if case .failed(let err) = stage.status {
                    Text(err)
                        .scaledFont(.labelSmall)
                        .foregroundColor(.statusLive)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.3), value: stage.status)
    }

    // MARK: - Long-wait Timer (initial-launch only)

    private func startLongWaitTimerIfNeeded() {
        guard case .initialLaunch = mode else { return }
        // Invalidate any stale timer before creating a new one —
        // SwiftUI can fire `onAppear` more than once in a view's
        // lifetime and each fire would otherwise create a fresh
        // Timer while leaving the previous one running.
        elapsedTimer?.invalidate()

        // Record the wall-clock start once per mount. Preserving
        // it across `onAppear` fires prevents the long-wait banner
        // from getting reset if SwiftUI re-invokes `onAppear`.
        if startedAt == nil {
            startedAt = Date()
        }

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard !isTakingTooLong, let started = startedAt else { return }
                if Date().timeIntervalSince(started) >= longWaitThresholdSeconds {
                    isTakingTooLong = true
                }
            }
        }
    }

    private func cleanupLongWaitTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        isTakingTooLong = false
    }

    // MARK: - Onboarding Sync Logic

    /// Only runs in onboarding mode. Initial-launch mode has the
    /// parent view drive its own fetches through the shared stores.
    @MainActor
    private func runOnboardingIfNeeded() async {
        guard case .onboarding(let server) = mode else { return }
        let task = Task { await runSync(for: server) }
        syncTask = task
        await task.value
    }

    @MainActor
    private func runSync(for server: ServerConnection) async {
        let snap = server.snapshot
        let epgURLString = server.effectiveEPGURL

        // Stage 1: EPG (channels + guide — a live server is useless without channels,
        // so we roll the old "Connecting/Groups/Channels/EPG" stages together here).
        updateStage("epg", status: .loading)
        let channelCount = await loadChannels(snap: snap)
        guard !Task.isCancelled else { return }
        let epgCount = await loadEPG(snap: snap, epgURL: epgURLString)
        guard !Task.isCancelled else { return }
        let epgDetail: String = {
            switch (channelCount > 0, epgCount > 0) {
            case (true, true):   return "\(channelCount) channels · \(epgCount) programs"
            case (true, false):  return "\(channelCount) channels"
            case (false, true):  return "\(epgCount) programs"
            case (false, false): return ""
            }
        }()
        updateStage("epg", status: .done(epgDetail))

        // Stage 2: VOD. Permission-gated the same way Edit Playlist > Save
        // gates its Movies / TV Shows rows (2026-09-18): the row used to be
        // shown, and the library fetched, for every VOD-capable source even
        // when the account that was just added may not view movies OR series,
        // or when On Demand is turned off for the playlist. The capability
        // snapshot is taken first so the decision uses the NEW account's
        // flags, not whatever an earlier playlist left behind.
        if server.type == .dispatcharrAPI {
            await DispatcharrCapabilityProbe.refreshIfStale(server, reason: "Setting Up (VOD)")
        }
        let vodAllowed: Bool = {
            guard server.supportsVOD, server.vodEnabled else { return false }
            guard server.type == .dispatcharrAPI else { return true }
            return server.dispatcharrCanViewVOD || server.dispatcharrCanViewSeries
        }()
        updateStage("vod", status: .loading)
        if !vodAllowed {
            updateStage("vod", status: .done(
                snap.type == .m3uPlaylist
                    ? "M3U playlists don't expose VOD"
                    : (server.vodEnabled
                       ? "Not available for this account"
                       : "On Demand is off for this playlist")
            ))
        } else {
            let vodCount = await loadVOD(snap: snap)
            guard !Task.isCancelled else { return }
            updateStage("vod", status: .done(vodCount > 0 ? "\(vodCount) titles" : "No VOD available"))
        }

        // Stage 3: DVR — reconcile Dispatcharr recordings (server-side scheduler).
        // XC and M3U servers have no DVR API; mark the stage done with a note.
        updateStage("dvr", status: .loading)
        let dvrDetail = await loadDVR(server: server)
        guard !Task.isCancelled else { return }
        updateStage("dvr", status: .done(dvrDetail))

        // Stage 4: Preferences — iCloud Key-Value Store pull when sync is on.
        // When sync is off, complete in-place with "Sync off" so the user sees
        // an honest status instead of a silently-skipped stage.
        updateStage("preferences", status: .loading)
        let prefsDetail = await loadPreferences()
        guard !Task.isCancelled else { return }
        updateStage("preferences", status: .done(prefsDetail))

        // All done
        withAnimation(.spring(response: 0.4)) {
            allDone = true
        }
    }

    private func updateStage(_ id: String, status: SyncStage.StageStatus) {
        if let idx = onboardingStages.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                onboardingStages[idx].status = status
            }
        }
    }

    // MARK: - Data Loading (onboarding only)

    private func loadGroups(snap: ServerSnapshot) async -> Int {
        switch snap.type {
        case .dispatcharrAPI:
            let api = DispatcharrAPI(baseURL: snap.baseURL, auth: .apiKey(snap.apiKey), userAgent: snap.userAgent, authMode: snap.dispatcharrAuthMode)
            if let groups = try? await api.getChannelGroups() {
                return groups.count
            }
        case .xtreamCodes:
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            if let groups = try? await api.getLiveCategories() {
                return groups.count
            }
        case .m3uPlaylist:
            // M3U groups are parsed inline with channels
            return 0
        }
        return 0
    }

    private func loadChannels(snap: ServerSnapshot) async -> Int {
        switch snap.type {
        case .dispatcharrAPI:
            let api = DispatcharrAPI(baseURL: snap.baseURL, auth: .apiKey(snap.apiKey), userAgent: snap.userAgent, authMode: snap.dispatcharrAuthMode)
            if let channels = try? await api.getChannels() {
                return channels.count
            }
        case .xtreamCodes:
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            if let streams = try? await api.getLiveStreams() {
                return streams.count
            }
        case .m3uPlaylist:
            if let url = URL(string: snap.baseURL),
               let channels = try? await M3UParser.fetchAndParse(url: url) {
                return channels.count
            }
        }
        return 0
    }

    private func loadEPG(snap: ServerSnapshot, epgURL: String) async -> Int {
        switch snap.type {
        case .dispatcharrAPI:
            // Previously called `getCurrentPrograms()` here to count
            // programs for the onboarding stage detail. That endpoint
            // is extremely expensive on large Dispatcharr instances
            // (full-table scan over `epg_programs`) and routinely
            // pinned a uwsgi worker for 30-60+s during onboarding,
            // starving the server's pool while the user watched a
            // loading spinner. The Guide's `/api/epg/grid/` endpoint
            // covers the same data more cheaply and runs lazily when
            // the user opens the guide. Returning 0 here keeps the
            // onboarding moving; the stage renders as "N channels"
            // without a program count, matching the existing
            // (channelCount>0, epgCount==0) branch of `epgDetail`.
            return 0
        case .xtreamCodes:
            // Xtream EPG is per-channel; just verify the server is reachable.
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            if let _ = try? await api.verifyConnection() {
                return 1  // Server is accessible for EPG
            }
        case .m3uPlaylist:
            // EPG is optional for M3U
            if !epgURL.isEmpty, let url = URL(string: epgURL),
               let programs = try? await XMLTVParser.fetchAndParse(url: url) {
                return programs.count
            }
        }
        return 0
    }

    private func loadVOD(snap: ServerSnapshot) async -> Int {
        guard snap.type == .dispatcharrAPI || snap.type == .xtreamCodes else {
            return 0
        }
        switch snap.type {
        case .dispatcharrAPI:
            // v1.6.12: this stage used to call the full
            // `getVODMovies()` + `getVODSeries()`, which paginate the
            // entire library 25-items-per-page. On a server with
            // 10–20k movies that's hundreds of sequential HTTP calls
            // and 2–5 minutes of staring at "Loading VOD" — making
            // users think the second Dispatcharr server they added
            // had hung. Now we probe `?page_size=1` and read the
            // DRF wrapper's total-count field, which finishes in a
            // single round-trip regardless of library size. The
            // returned number is only used cosmetically for the
            // stage's done-detail label, so paginating the full
            // library here was always wasted work.
            let api = DispatcharrAPI(baseURL: snap.baseURL, auth: .apiKey(snap.apiKey), userAgent: snap.userAgent, authMode: snap.dispatcharrAuthMode)
            var count = 0
            if let movies = try? await api.getVODMovieCount() { count += movies }
            if let series = try? await api.getVODSeriesCount() { count += series }
            return count
        case .xtreamCodes:
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            var count = 0
            if let movies = try? await api.getVODStreams() { count += movies.count }
            if let series = try? await api.getSeries() { count += series.count }
            return count
        default:
            return 0
        }
    }

    /// DVR reconciliation for Dispatcharr servers. XC / M3U have no server-side
    /// DVR API so we complete the stage with an honest "Not available" note.
    @MainActor
    private func loadDVR(server: ServerConnection) async -> String {
        guard server.type == .dispatcharrAPI else {
            return "Not available for this server type"
        }
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        if let remote = try? await api.listRecordings() {
            return remote.isEmpty ? "No recordings scheduled" : "\(remote.count) recordings"
        }
        return ""
    }

    /// Preferences pull from iCloud KVS. When sync is off we complete the stage
    /// in-place so the user sees a consistent status row rather than a gap.
    @MainActor
    private func loadPreferences() async -> String {
        guard SyncManager.shared.isSyncEnabled else {
            return "iCloud Sync off"
        }
        // Trigger the pull; SyncManager handles its own throttling and merge
        // flag so this is safe to call even if a pull is already in-flight.
        SyncManager.shared.pullFromCloud()
        // Brief yield so the user sees the "loading" dot before the checkmark.
        try? await Task.sleep(nanoseconds: 600_000_000)
        return "Synced"
    }
}

#if os(tvOS)
/// Swallows the Menu / Back press while a save is applying. Applied
/// conditionally so only the `.saving` cover changes behavior.
private struct SwallowExitCommand: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.onExitCommand { /* ignored while saving */ }
        } else {
            content
        }
    }
}
#endif

// MARK: - Playlist Save Progress (Edit Playlist > Save)

/// One row of the "Saving Changes" screen.
///
/// Casing follows the rows the Add Playlist / launch cover already shows
/// ("Loading EPG", "Loading DVR", "Loading preferences"): sentence case,
/// no trailing ellipsis, so a user who added the playlist yesterday and
/// edits it today reads the same screen.
enum PlaylistSaveStep: String {
    case verify
    case channels
    case movies
    case tvShows
    case finish

    var label: String {
        switch self {
        case .verify:   return "Verifying credentials"
        case .channels: return "Loading channels"
        case .movies:   return "Loading movies"
        case .tvShows:  return "Loading TV shows"
        case .finish:   return "Finishing up"
        }
    }
}

/// Stage source for `ServerSyncView(.saving)`. Rows are APPENDED as the
/// save path reaches them, never pre-listed, so a row on screen always
/// means that work is really happening: the Movies / TV Shows rows, for
/// instance, are only added after the capability probe for the new
/// credentials has answered.
@MainActor
final class PlaylistSaveProgress: ObservableObject {
    @Published private(set) var stages: [SyncStage] = []

    private var runStart = CFAbsoluteTimeGetCurrent()
    private var stepStart: [String: CFAbsoluteTime] = [:]

    func reset() {
        stages = []
        stepStart = [:]
        runStart = CFAbsoluteTimeGetCurrent()
        debugLog("[SAVE] begin")
    }

    /// Add a row without starting it. Used for the Movies / TV Shows pair
    /// so both appear as soon as the gate allows them.
    func show(_ steps: [PlaylistSaveStep]) {
        for step in steps where !stages.contains(where: { $0.id == step.rawValue }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                stages.append(SyncStage(id: step.rawValue, label: step.label))
            }
        }
    }

    func begin(_ step: PlaylistSaveStep) {
        show([step])
        stepStart[step.rawValue] = CFAbsoluteTimeGetCurrent()
        set(step, .loading)
        debugLog("[SAVE] \(step.rawValue) start +\(sinceStart())ms")
    }

    func finish(_ step: PlaylistSaveStep, detail: String = "") {
        set(step, .done(detail))
        debugLog("[SAVE] \(step.rawValue) done in \(sinceStep(step))ms (+\(sinceStart())ms)"
                 + (detail.isEmpty ? "" : ": \(detail)"))
    }

    func fail(_ step: PlaylistSaveStep, message: String) {
        set(step, .failed(message))
        debugLog("[SAVE] \(step.rawValue) FAILED after \(sinceStep(step))ms (+\(sinceStart())ms)")
    }

    /// Why a row is NOT on screen. Log only, no row.
    func skip(_ step: PlaylistSaveStep, _ why: String) {
        debugLog("[SAVE] \(step.rawValue) skipped (\(why)) +\(sinceStart())ms")
    }

    private func set(_ step: PlaylistSaveStep, _ status: SyncStage.StageStatus) {
        guard let idx = stages.firstIndex(where: { $0.id == step.rawValue }) else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            stages[idx].status = status
        }
    }

    private func sinceStart() -> Int {
        Int((CFAbsoluteTimeGetCurrent() - runStart) * 1000)
    }

    private func sinceStep(_ step: PlaylistSaveStep) -> Int {
        guard let t = stepStart[step.rawValue] else { return 0 }
        return Int((CFAbsoluteTimeGetCurrent() - t) * 1000)
    }
}

/// The Edit Playlist save, shared by the iOS sheet and the tvOS page so
/// the two cannot drift. Verifies first, then applies, then does the work
/// each visible row claims. Returns nil on success, or the server's own
/// message for the form's "Save Failed" section.
@MainActor
enum PlaylistSaveRunner {

    static func run(server: ServerConnection,
                    typedBaseURL: String,
                    credentialType: DispatcharrCredentialType,
                    originalCredentials: DispatcharrCredentialSnapshot?,
                    progress: PlaylistSaveProgress,
                    commitStaged: () -> Void) async -> String? {
        progress.reset()

        let credentialsChanged = ServerCredentialChange.credentialsChanged(
            server: server,
            previous: originalCredentials,
            credentialType: credentialType
        )
        let urlChanged = typedBaseURL != server.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A rename, a User-Agent edit or a Guide Days change costs no login
        // round trip at all, only a credential swap or a new URL does.
        let needsVerify = credentialsChanged || (urlChanged && server.type != .m3uPlaylist)

        if needsVerify {
            if let message = await ServerCredentialChange.verify(
                server: server,
                baseURL: typedBaseURL,
                credentialType: credentialType,
                onStep: { progress.begin($0) }
            ) {
                progress.fail(.verify, message: message)
                return message
            }
            progress.finish(.verify)
        } else {
            progress.skip(.verify, "no credential or URL change")
        }

        commitStaged()

        if credentialsChanged {
            // Drops the old account's cached identity, re-mints the api_key
            // and takes a FRESH capability snapshot before anything below
            // decides which rows to show.
            if let message = await ServerCredentialChange.applyChange(
                server: server,
                // The row is already on screen and done when a verify ran
                // (a credential change always verifies first); re-beginning
                // it would bounce it back to a spinner.
                onStep: needsVerify ? nil : { progress.begin($0) }
            ) {
                progress.fail(.verify, message: message)
                return message
            }
        } else if urlChanged, server.type == .dispatcharrAPI {
            // Same panel, new address: permissions still have to be re-read
            // before the Movies / TV Shows rows are decided.
            await DispatcharrCapabilityProbe.refresh(server, reason: "playlist URL change")
        }
        SyncManager.shared.saveCredentialsSynced(for: server)

        let identityChanged = credentialsChanged || urlChanged
        let servers = allServers(around: server)

        // Channels: only the ACTIVE playlist has any on screen, and only a
        // new identity or address invalidates them.
        if identityChanged, server.isActive {
            progress.begin(.channels)
            await ChannelStore.shared.reloadChannelsAndWait(servers: servers)
            let n = ChannelStore.shared.channels.count
            progress.finish(.channels, detail: n > 0 ? "\(n) channels" : "")
        } else {
            progress.skip(.channels, identityChanged ? "inactive playlist" : "no identity change")
        }

        await runVODStagesIfNeeded(server: server,
                                   servers: servers,
                                   identityChanged: identityChanged,
                                   progress: progress)

        // Finishing up: push the edited row (and its credentials) to iCloud
        // and tell every capability-gated surface to re-read the snapshot.
        progress.begin(.finish)
        SyncManager.shared.pushServers(servers, immediate: true)
        NotificationCenter.default.post(name: .dispatcharrCapabilitiesDidChange, object: nil)
        progress.finish(.finish)
        return nil
    }

    /// Movies / TV Shows. A row appears only when that catalog is really
    /// being rebuilt: the playlist is active, its identity changed, On
    /// Demand is on for it, and (Direct Connect) the NEW account may view
    /// that kind. The on-disk catalog belongs to the OLD account, so it is
    /// wiped and a foreground sweep started; the row completes on the first
    /// stored page (or a zero answer) and the sweep then finishes in the
    /// background exactly as it does after Add Playlist.
    private static func runVODStagesIfNeeded(server: ServerConnection,
                                             servers: [ServerConnection],
                                             identityChanged: Bool,
                                             progress: PlaylistSaveProgress) async {
        guard identityChanged, server.isActive else {
            progress.skip(.movies, identityChanged ? "inactive playlist" : "no identity change")
            progress.skip(.tvShows, identityChanged ? "inactive playlist" : "no identity change")
            return
        }
        guard server.supportsVOD else {
            progress.skip(.movies, "source has no VOD"); progress.skip(.tvShows, "source has no VOD")
            return
        }
        guard server.vodEnabled else {
            progress.skip(.movies, "On Demand off for this playlist")
            progress.skip(.tvShows, "On Demand off for this playlist")
            return
        }
        let isDirect = server.type == .dispatcharrAPI
        let wantMovies = !isDirect || server.dispatcharrCanViewVOD
        let wantSeries = !isDirect || server.dispatcharrCanViewSeries
        if !wantMovies { progress.skip(.movies, "account may not view movies") }
        if !wantSeries { progress.skip(.tvShows, "account may not view TV shows") }
        guard wantMovies || wantSeries else { return }

        if wantMovies { progress.show([.movies]) }
        if wantSeries { progress.show([.tvShows]) }

        // The stored rows, the legacy snapshot and the saved sweep positions
        // were all written as the old account. Nothing of it may survive.
        let store = VODStore.shared
        store.clear()
        await store.deleteCatalog(for: server)

        if wantMovies {
            progress.begin(.movies)
            store.armFirstVODPage([.movie])
            store.refreshMovies(servers: servers)
            let n = await store.awaitFirstVODPage(.movie)
            progress.finish(.movies, detail: n > 0 ? "\(n) titles" : "No movies available")
        }
        if wantSeries {
            progress.begin(.tvShows)
            store.armFirstVODPage([.series])
            store.refreshSeries(servers: servers)
            let n = await store.awaitFirstVODPage(.series)
            progress.finish(.tvShows, detail: n > 0 ? "\(n) titles" : "No TV shows available")
        }
    }

    /// Every configured playlist, read off the edited row's own context.
    /// The stores need the whole list to pick the active one.
    private static func allServers(around server: ServerConnection) -> [ServerConnection] {
        guard let context = server.modelContext else { return [server] }
        let all = (try? context.fetch(FetchDescriptor<ServerConnection>())) ?? []
        return all.isEmpty ? [server] : all
    }
}

#if os(tvOS)
/// Skip on the Setting Up screen. Owns its focus platter (Logan
/// 2026-09-05: the default ring hugged the bare text and the button was
/// too small to read from the couch); same shape as Settings' compact
/// buttons.
private struct TVSkipButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text("Skip")
                .scaledFont(.system(size: 26, weight: .semibold))
                .foregroundColor(isFocused ? .textPrimary : Color.contrastText(.textSecondary))
                .padding(.horizontal, 40)
                .padding(.vertical, 14)
                .frame(minWidth: 180)
                .background(
                    Capsule()
                        .fill(isFocused ? Color.accentPrimary.opacity(0.20) : Color.elevatedBackground.opacity(0.6))
                )
        }
        // Ring comes from the shared style, traced as a capsule so it
        // matches the button's own pill exactly (Logan 2026-09-15: the
        // style's fixed 14pt rounded rect sat proud of the pill).
        .buttonStyle(TVNoHighlightButtonStyle())
        .tvFocusRingShape(.capsule)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif
