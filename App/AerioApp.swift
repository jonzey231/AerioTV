import SwiftUI
import SwiftData
#if os(iOS)
import NetworkExtension
import Network
import CoreLocation
#endif

// MARK: - Main Thread Watchdog (DEBUG)
/// Periodically pings the main thread from a background thread.
/// Logs warnings at 50ms (slow), 500ms (hang), and 3s (frozen).
#if DEBUG
private final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private var timer: DispatchSourceTimer?
    private var consecutiveSlowPings = 0

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        t.schedule(deadline: .now() + 2, repeating: 0.5)
        t.setEventHandler { [weak self] in
            self?.ping()
        }
        t.resume()
        timer = t
        print("[WATCHDOG] Started — pinging main thread every 0.5s")
    }

    private var pingCount = 0

    private func ping() {
        pingCount += 1
        let n = pingCount
        let start = CFAbsoluteTimeGetCurrent()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            sem.signal()
        }
        let result = sem.wait(timeout: .now() + 5.0)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        if result == .timedOut {
            consecutiveSlowPings += 1
            print("[WATCHDOG] 🚨🚨🚨 MAIN THREAD FROZEN >5s! ping#\(n) — UI is completely unresponsive")
            logMainThreadBacktrace()
        } else if elapsed > 0.2 {
            consecutiveSlowPings += 1
            print("[WATCHDOG] 🔴 HANG: ping#\(n) took \(String(format: "%.1f", elapsed * 1000))ms — UI visibly stuck")
            logMainThreadBacktrace()
        } else if elapsed > 0.05 {
            consecutiveSlowPings += 1
            print("[WATCHDOG] 🟡 Slow: ping#\(n) took \(String(format: "%.0f", elapsed * 1000))ms (\(consecutiveSlowPings) consecutive)")
        } else {
            if consecutiveSlowPings > 0 {
                print("[WATCHDOG] ✅ Recovered after \(consecutiveSlowPings) slow ping(s) — ping#\(n): \(String(format: "%.1f", elapsed * 1000))ms")
            }
            consecutiveSlowPings = 0
        }
    }

    nonisolated(unsafe) static var lastStackTrace: [String] = []

    private func logMainThreadBacktrace() {
        // Capture main thread stack once it unblocks
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainThreadWatchdog.lastStackTrace = Thread.callStackSymbols
            sem.signal()
        }
        if sem.wait(timeout: .now() + 2.0) == .success {
            let trace = MainThreadWatchdog.lastStackTrace
            if !trace.isEmpty {
                print("[WATCHDOG] Main thread stack (post-unblock):")
                for (i, frame) in trace.prefix(15).enumerated() {
                    print("[WATCHDOG]   \(i): \(frame)")
                }
            }
        } else {
            print("[WATCHDOG] Main thread still blocked — could not capture stack")
        }
    }
}
#endif

@main
struct AerioApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Ensure the Application Support directory exists before SwiftData/CoreData
        // tries to create the SQLite store there. On a fresh install the directory
        // may not exist, causing noisy (but auto-recovered) CoreData errors.
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            if !fm.fileExists(atPath: appSupport.path) {
                try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            AppEntryView()
                .environmentObject(ThemeManager.shared)
                .onAppear {
                    DebugLogger.shared.logLifecycle("App launched")
                    #if DEBUG
                    MainThreadWatchdog.shared.start()
                    #endif
                    // Playback diagnostics — memory-warning subscriber
                    // logs a snapshot of tile state + process metrics
                    // when iOS sends a pressure notification. Runs in
                    // both DEBUG and release so feedback reports have
                    // the same signal as developer loops.
                    #if canImport(UIKit)
                    PlaybackDiagnostics.installMemoryWarningHook()
                    #endif
                }
                #if os(tvOS)
                .onOpenURL { url in
                    // Handle Top Shelf deep links:
                    //   aerio://channel/<id>            → play live channel
                    //   aerio://vod/movie/<movieID>     → navigate to movie detail
                    //   aerio://vod/series/<seriesID>   → navigate to series detail
                    //
                    // We set UserDefaults (so a cold launch can pick up the
                    // deep link on first onAppear) AND post a notification (so
                    // a warm launch where the app is already in memory can
                    // react immediately without waiting for an onAppear that
                    // will never come).
                    guard url.scheme == "aerio" else { return }
                    debugLog("🔗 Deep link received: \(url.absoluteString)")
                    switch url.host {
                    case "channel":
                        guard let channelID = url.pathComponents.last, !channelID.isEmpty else { return }
                        UserDefaults.standard.set(channelID, forKey: "launchChannelID")
                        UserDefaults.standard.set(true, forKey: "launchOnLiveTV")
                        NotificationCenter.default.post(
                            name: .aerioOpenChannel,
                            object: nil,
                            userInfo: ["channelID": channelID]
                        )
                    case "vod":
                        // pathComponents for "aerio://vod/movie/abc" is
                        // ["/", "movie", "abc"]. Strip leading "/" separators.
                        let parts = url.pathComponents.filter { $0 != "/" }
                        guard parts.count >= 2 else { return }
                        let vodType = parts[0]   // "movie" or "series"
                        let vodID = parts[1]
                        let targetTab = (vodType == "series") ? "launchOnSeries" : "launchOnMovies"
                        UserDefaults.standard.set(vodID, forKey: "launchVODID")
                        UserDefaults.standard.set(vodType, forKey: "launchVODType")
                        UserDefaults.standard.set(true, forKey: targetTab)
                        NotificationCenter.default.post(
                            name: .aerioOpenVOD,
                            object: nil,
                            userInfo: ["vodID": vodID, "vodType": vodType]
                        )
                    default:
                        break
                    }
                }
                #endif
        }
        .modelContainer(for: [
            ServerConnection.self,
            ChannelGroup.self,
            Channel.self,
            EPGProgram.self,
            M3UPlaylist.self,
            EPGSource.self,
            WatchProgress.self,
            Recording.self
        ])
        #if os(iOS)
        // iPad keyboard shortcuts for the multiview grid. No-ops on
        // tvOS (no keyboard) and on iPhone (multiview excluded). The
        // commands are always installed but each one guards on
        // `PlayerSession.shared.mode == .multiview` so a hotkey press
        // during single playback or guide browsing does nothing.
        //
        // Shortcuts (plan Phase 7):
        //  ⌘1..⌘9  — take audio of tile N (1-indexed)
        //  ⌘W     — exit multiview (clean teardown, stops playback)
        //  ⌘N     — open the add-channel sheet
        //  ⌘F     — toggle fullscreen-in-grid on the audio tile
        //
        // The add-sheet and fullscreen toggle use the same store APIs
        // as the on-screen buttons, so behavior stays consistent with
        // tap/click.
        .commands {
            MultiviewCommands()
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                DebugLogger.shared.logLifecycle("Scene → active (foreground)")
                // Always refresh the cached SSID when foregrounding so LAN/WAN
                // switching reacts immediately after the user toggles Wi-Fi.
                #if os(iOS)
                NetworkMonitor.shared.refresh()
                #endif
                // Start iCloud sync if enabled (pull happens during EPG loading)
                SyncManager.shared.startObserving()
                #if os(tvOS)
                // Re-probe LAN on every foreground so switching networks is detected
                // (servers read from SwiftData in RootView, probed there on change)
                #endif
            case .inactive:    DebugLogger.shared.logLifecycle("Scene → inactive")
            case .background:
                DebugLogger.shared.logLifecycle("Scene → background")
                // Flush any pending debounced iCloud pushes before the OS
                // suspends us. Without this, preference changes (favorites,
                // theme, etc.) made in the last 60 seconds get dropped when
                // the user force-closes the app — the push is still sitting
                // on the main queue waiting out its asyncAfter debounce. See
                // GitHub issue #2.
                SyncManager.shared.pushPreferencesImmediate()
                #if os(tvOS)
                // Stop playback so audio doesn't continue in the background.
                // tvOS has no PiP or background audio entitlement for IPTV streams.
                //
                // Previously posted `.stopPlaybackForBackground` which HomeView
                // handled via `nowPlaying.stop()` — that path only stopped the
                // NowPlayingManager's single-stream state and left MultiviewStore
                // tiles running, so multiview audio kept playing after a Home-press
                // (user-reported regression; reproduces on both single and
                // multiview on Apple TV).
                //
                // Fire the notification AND directly call `PlayerSession.exit()`
                // — the unified teardown path that resets MultiviewStore, flips
                // mode to `.idle`, clears NowPlayingInfoCenter, and stops the
                // single-stream NowPlayingManager. The notification is kept so any
                // other listeners (e.g., HomeView) still get a chance to tear down
                // their own state cleanly before PlayerSession wipes the shared
                // stores.
                NotificationCenter.default.post(name: .stopPlaybackForBackground, object: nil)
                Task { @MainActor in
                    PlayerSession.shared.exit()
                }
                #endif
                // Stop all active local recordings — iOS suspends URLSession
                // data tasks within ~30s of backgrounding, so the recording
                // would fail silently. Better to stop cleanly. The model
                // context update happens inside RootView's own onChange.
                Task { @MainActor in
                    RecordingCoordinator.shared.stopAllSessionsOnBackground()
                }
            @unknown default:  break
            }
        }
    }
}

// MARK: - Network Monitor (iOS only)
// Detects the current WiFi SSID via NEHotspotNetwork and caches it in UserDefaults
// so ServerConnection.effectiveBaseURL can read it synchronously.
//
// Requires:
//  1. "Access WiFi Information" capability (com.apple.developer.networking.wifi-info)
//  2. Location authorization (NEHotspotNetwork.fetchCurrent returns nil without it)
//  3. NSLocationWhenInUseUsageDescription in Info.plist

#if os(iOS)
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// The SSID of the currently connected WiFi network, or nil if unknown / off WiFi.
    @Published private(set) var currentSSID: String? = {
        UserDefaults.standard.string(forKey: "cachedCurrentSSID")
    }()

    /// True while an SSID fetch is in progress.
    @Published private(set) var isRefreshing = false

    /// True when the device has an active WiFi interface.
    @Published private(set) var isOnWifi = false

    /// Current Location authorization status, republished from the
    /// underlying CLLocationManager delegate so any SwiftUI view can
    /// drive its UI from this single source of truth. Used by the
    /// onboarding "Enable Home WiFi Detection" card so it can show
    /// "✓ Enabled", "Allow", or "Denied" without each view needing
    /// its own CLLocationManager.
    @Published private(set) var locationAuthStatus: CLAuthorizationStatus

    /// True when on a matched home SSID AND the configured localURL
    /// failed a reachability probe. Most commonly caused by an active
    /// VPN that blocks LAN traffic. Surfaced by the Live TV banner.
    @Published private(set) var localServerUnreachable: Bool = false

    private let pathMonitor = NWPathMonitor()
    private var lastWifiState = false
    private let locationDelegate = LocationDelegate()

    private init() {
        // Seed the published auth status from the delegate's manager
        // before any view observes us.
        self.locationAuthStatus = locationDelegate.manager.authorizationStatus
        // Subscribe to EVERY authorization change (including the
        // `.notDetermined → .authorizedWhenInUse` transition that
        // happens when the user accepts the prompt) so the
        // onboarding UI and Settings footers can react live. The
        // one-shot `onPendingResolution` callback remains separate
        // so `ensureLocationAuthorization` can still resume a
        // pending SSID fetch once.
        locationDelegate.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in
                guard let self else { return }
                let wasAuthorized = self.locationAuthStatus == .authorizedWhenInUse
                    || self.locationAuthStatus == .authorizedAlways
                let isAuthorizedNow = newStatus == .authorizedWhenInUse
                    || newStatus == .authorizedAlways
                self.locationAuthStatus = newStatus
                // User just granted Location (typically by returning
                // from iOS Settings after the onboarding "Unknown
                // network" warning). Kick off the SSID fetch directly
                // without going through `refresh()`'s hasHomeSSIDs
                // guard — the whole point of the warning was that the
                // user doesn't have any home SSIDs yet and needs to
                // see their current one to configure one.
                if !wasAuthorized, isAuthorizedNow {
                    DebugLogger.shared.log(
                        "NetworkMonitor: location just granted — kicking off SSID fetch",
                        category: "Network", level: .info)
                    self.fetchSSID()
                }
            }
        }
        startPathMonitor()
    }

    // MARK: - Public (onboarding / Settings)

    /// Prompt the user for Location (When In Use) authorization. Safe
    /// to call in any state — if already authorized, the completion
    /// fires immediately with `true`; if already denied, fires with
    /// `false` (the user must grant it via iOS Settings); if not yet
    /// determined, presents the system prompt and fires when the
    /// user responds.
    ///
    /// Used by the onboarding Home WiFi card so the user can grant
    /// the permission up-front with context, rather than stumbling
    /// into the "network name unavailable" warning deep in Settings.
    func requestLocationAuthorization(completion: (@MainActor (Bool) -> Void)? = nil) {
        ensureLocationAuthorization { granted in
            completion?(granted)
        }
    }

    // MARK: - Public

    /// Fetch the current SSID and update the cache.
    /// Called automatically when the WiFi interface connects or changes.
    ///
    /// Skips the `NEHotspotNetwork.fetchCurrent()` call when no home SSIDs
    /// are configured, avoiding the iOS location-services indicator that
    /// appears whenever WiFi-info APIs are used.
    /// Fetch the current SSID.
    /// - Parameter force: When `true`, always queries NEHotspotNetwork even if no
    ///   home SSIDs are configured (used by Settings UI so the user can see
    ///   their network before configuring). Auto-triggered refreshes pass `false`
    ///   to avoid the location-services indicator when it's not needed.
    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }

        if !force {
            // Only query WiFi SSID when home-network switching is configured.
            let homeCSV = UserDefaults.standard.string(forKey: "globalHomeSSIDs") ?? ""
            let hasHomeSSIDs = !homeCSV
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .isEmpty

            guard hasHomeSSIDs else {
                // No home SSIDs → clear stale cache so effectiveBaseURL always
                // returns the primary URL without triggering location services.
                if currentSSID != nil {
                    currentSSID = nil
                    UserDefaults.standard.removeObject(forKey: "cachedCurrentSSID")
                    DebugLogger.shared.log(
                        "NetworkMonitor: skipped SSID fetch (no home SSIDs configured)",
                        category: "Network", level: .info)
                }
                return
            }
        }

        // NEHotspotNetwork.fetchCurrent() requires location authorization.
        ensureLocationAuthorization { [weak self] authorized in
            guard authorized else {
                DebugLogger.shared.log(
                    "NetworkMonitor: location not authorized — cannot fetch SSID",
                    category: "Network", level: .warning)
                return
            }
            self?.fetchSSID()
        }
    }

    // MARK: - Private

    private func fetchSSID() {
        isRefreshing = true
        Task { @MainActor in
            let ssid = await NEHotspotNetwork.fetchCurrent()?.ssid
            self.currentSSID = ssid
            UserDefaults.standard.set(ssid, forKey: "cachedCurrentSSID")
            self.isRefreshing = false
            DebugLogger.shared.log(
                "NetworkMonitor: SSID = \(ssid ?? "<nil>")",
                category: "Network", level: .info)

            // If the resolved SSID matches a configured home SSID,
            // probe the active server's local URL. A VPN that blocks
            // LAN traffic will fail the probe and surface a banner
            // in Live TV so the user can disable the VPN.
            if let ssid, Self.isHomeSSID(ssid) {
                let localURL = ChannelStore.shared.activeServer?.localURL ?? ""
                Task { await self.probeLocalServer(localURL: localURL) }
            } else {
                self.localServerUnreachable = false
            }
        }
    }

    /// Returns true if the given SSID is listed in `globalHomeSSIDs`
    /// (comma-separated, whitespace-trimmed).
    private static func isHomeSSID(_ ssid: String) -> Bool {
        let homeCSV = UserDefaults.standard.string(forKey: "globalHomeSSIDs") ?? ""
        let homeSSIDs = homeCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return homeSSIDs.contains(ssid)
    }

    /// HEAD-probes the configured local URL with a 3-second timeout.
    /// Any 2xx–4xx response means "server is reachable on the LAN"
    /// (even a 401/403 from an auth-required endpoint proves the TCP
    /// path is alive). 5xx, network errors, or timeouts flip the
    /// `localServerUnreachable` flag true so the Live TV banner can
    /// warn the user — usually about an active LAN-blocking VPN.
    func probeLocalServer(localURL: String) async {
        guard !localURL.isEmpty, let url = URL(string: localURL) else {
            await MainActor.run { self.localServerUnreachable = false }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                await MainActor.run { self.localServerUnreachable = false }
                return
            }
            await MainActor.run { self.localServerUnreachable = true }
        } catch {
            await MainActor.run { self.localServerUnreachable = true }
        }
    }

    private func ensureLocationAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        let status = locationDelegate.manager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            completion(true)
        case .notDetermined:
            locationDelegate.onPendingResolution = { newStatus in
                Task { @MainActor in
                    completion(newStatus == .authorizedWhenInUse || newStatus == .authorizedAlways)
                }
            }
            locationDelegate.manager.requestWhenInUseAuthorization()
        default:
            completion(false)
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let onWifi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnWifi = onWifi
                // Refresh SSID only when we connect to (or switch) Wi-Fi networks.
                if onWifi && !self.lastWifiState {
                    self.refresh()
                    // VPN toggles often surface as a WiFi transition
                    // without the SSID actually changing. Re-probe the
                    // local URL so the banner can update even when
                    // `fetchSSID` returns the same value as before.
                    if let ssid = self.currentSSID, Self.isHomeSSID(ssid) {
                        let localURL = ChannelStore.shared.activeServer?.localURL ?? ""
                        Task { await self.probeLocalServer(localURL: localURL) }
                    }
                } else if !onWifi {
                    // Left WiFi — clear SSID so we don't use a stale LAN URL.
                    self.currentSSID = nil
                    UserDefaults.standard.removeObject(forKey: "cachedCurrentSSID")
                    self.localServerUnreachable = false
                }
                self.lastWifiState = onWifi
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}

/// CLLocationManager delegate that exposes two distinct callbacks:
/// a persistent `onStatusChange` (fires on every authorization
/// update so `NetworkMonitor.locationAuthStatus` stays in sync with
/// the live system state), and a one-shot `onPendingResolution`
/// used internally by `NetworkMonitor.ensureLocationAuthorization`
/// to resume a pending SSID fetch once the user responds to the
/// system prompt. Split into two because the previous single
/// `onAuthChange` was one-shot + self-clearing, which can't serve
/// a persistent observer at the same time.
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    /// Fires on EVERY authorization change, including the initial
    /// `.notDetermined` state. The SwiftUI-facing observer
    /// (`NetworkMonitor.locationAuthStatus`) wires into this.
    var onStatusChange: ((CLAuthorizationStatus) -> Void)?
    /// One-shot callback — set by `ensureLocationAuthorization`
    /// when kicking off `requestWhenInUseAuthorization()`, fires
    /// once the user responds with a determined status, then
    /// clears itself. Guarded against firing for `.notDetermined`
    /// so a passing pre-prompt notification can't wake a pending
    /// SSID fetch early.
    var onPendingResolution: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        onStatusChange?(status)
        guard status != .notDetermined else { return }
        onPendingResolution?(status)
        onPendingResolution = nil
    }
}
#endif

// MARK: - tvOS LAN Probe
// tvOS has no SSID detection API. Instead, we probe the local URL at startup —
// if it responds, the device is on the home network.
#if os(tvOS)
@MainActor
enum TVLANProbe {
    /// Probes each server's localURL. If ANY responds within 2s, sets tvosLANDetected = true.
    static func probe(servers: [ServerConnection]) {
        let serversWithoutLocal = servers.filter { $0.localURL.isEmpty }.count
        let candidates = servers.compactMap { s -> URL? in
            guard !s.localURL.isEmpty else { return nil }
            var url = s.localURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix("/") { url = String(url.dropLast()) }
            if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "http://" + url }
            return URL(string: url)
        }
        guard !candidates.isEmpty else {
            // No `localURL` configured on any server. `effectiveBaseURL`
            // will always return the external URL — this is a CONFIG
            // issue, not a network issue. Log visibly so the user can
            // see why their Ethernet-connected Apple TV is going
            // through WAN even when the server is on the LAN.
            UserDefaults.standard.set(false, forKey: "tvosLANDetected")
            print("📡 tvOS LAN probe: SKIPPED — no local URL configured on any server (\(serversWithoutLocal) server(s) missing `localURL`). Set Settings → Server → Local URL to enable LAN routing.")
            return
        }
        print("📡 tvOS LAN probe: starting — \(candidates.count) candidate local URL(s), \(serversWithoutLocal) server(s) without local URL")
        Task {
            var detected = false
            var attemptedLog: [String] = []
            for baseURL in candidates {
                // Quick HEAD request with short timeout. Bumped
                // from 2s → 3s because some home routers respond
                // slowly to the first connection to a host the ARP
                // table doesn't know yet (observed on Ubiquiti
                // setups when the TV just came off standby).
                var request = URLRequest(url: baseURL, timeoutInterval: 3.0)
                request.httpMethod = "HEAD"
                do {
                    let start = Date()
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                        attemptedLog.append("\(baseURL.host ?? baseURL.absoluteString)=\(http.statusCode)/\(ms)ms ✓")
                        detected = true
                        break
                    } else if let http = response as? HTTPURLResponse {
                        attemptedLog.append("\(baseURL.host ?? baseURL.absoluteString)=\(http.statusCode)/\(ms)ms ✗")
                    }
                } catch {
                    // Short error tag — `.timedOut`, `.cannotConnectToHost`, etc.
                    let nsErr = error as NSError
                    attemptedLog.append("\(baseURL.host ?? baseURL.absoluteString)=err(\(nsErr.code))")
                }
            }
            UserDefaults.standard.set(detected, forKey: "tvosLANDetected")
            print("📡 tvOS LAN probe: detected=\(detected) results=[\(attemptedLog.joined(separator: ", "))]. LAN routing \(detected ? "ENABLED — streams will use local URL" : "DISABLED — streams will use external URL")")
        }
    }
}
#endif

// MARK: - App Entry View (Splash → Root)
// splashFinished is @State (in-memory only), so it resets to false on every
// cold launch (force-close + reopen or first install). When the user simply
// backgrounds and foregrounds the app the process stays alive, @State keeps
// its true value, and the splash is not replayed. No persistence needed.
struct AppEntryView: View {
    @State private var splashFinished = false

    var body: some View {
        ZStack {
            if splashFinished {
                RootView()
                    .transition(.opacity)
            } else {
                SplashView(isFinished: $splashFinished)
                    .transition(.opacity)
            }
        }
        .animation(.easeIn(duration: 0.3), value: splashFinished)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Root View (Handles Onboarding)
struct RootView: View {
    @Query private var servers: [ServerConnection]
    @Query private var playlists: [M3UPlaylist]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedInitialEPG") private var hasCompletedInitialEPG = false

    /// Guards against the re-entrant loop: merge → save → servers.count onChange → push → bounce → merge.
    @State private var isMergingRemote = false

    /// Controls the onboarding full-screen cover.
    /// Using fullScreenCover instead of a Group { if/else } view swap avoids
    /// destroying the UITabBarController/UINavigationController hierarchy,
    /// which previously left the UIKit responder chain and tvOS focus engine
    /// in a dead state after iCloud sync.
    @State private var showOnboarding = false

    private var hasAnySource: Bool {
        !servers.isEmpty || !playlists.isEmpty
    }

    var body: some View {
        MainTabView()
            .preferredColorScheme(.dark)
            .fullScreenCover(isPresented: $showOnboarding) {
                NavigationStack {
                    WelcomeView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
                .preferredColorScheme(.dark)
            }
            .onAppear {
                debugLog("🟣 RootView.onAppear: hasCompletedOnboarding=\(hasCompletedOnboarding), hasAnySource=\(hasAnySource), servers=\(servers.count)")

                // Kick off libmpv one-time process-wide init on a
                // background queue. The 2 s `mpv_initialize` cost
                // that used to hit the user on their first channel
                // tap happens here instead, while the splash /
                // channel list is already loading. By the time the
                // user picks a channel, libmpv is warm and
                // `setupMPV` falls into the cheap ~15 ms fast path.
                // Idempotent; safe to call on every render pass.
                // Guarded by `canImport(Libmpv)` because the whole
                // MPV subsystem (and this enum's declaration) lives
                // inside that conditional in MPVPlayerView.swift.
                #if canImport(Libmpv)
                MPVLibraryWarmup.warmUp()
                #endif

                // DEBUG-only: log every Siri Remote button press / dpad
                // movement with a `[REMOTE]` prefix so the devicectl
                // --console log capture can stream remote-input events
                // alongside app lifecycle + MPV timing. No-op on iOS
                // and in release builds.
                RemoteInputLogger.install()

                // Share model context with WatchProgressManager for VOD resume tracking
                WatchProgressManager.modelContext = modelContext
                if !hasCompletedOnboarding && !hasAnySource {
                    showOnboarding = true
                }
                // One-time cleanup: purge EPGProgram rows belonging to any
                // server that no longer exists. Fixes historical damage
                // from an earlier build where server deletion didn't
                // cascade EPG rows — users who deleted a server type and
                // re-added the same server via a different type would end
                // up with orphaned EPG data that left the guide empty.
                pruneOrphanedEPGPrograms()
                #if os(tvOS)
                TVLANProbe.probe(servers: servers)
                // If the user has no server configured (fresh install,
                // uninstall+reinstall, or manually cleared), wipe any
                // stale Top Shelf data from a previous install. Keychain
                // items survive app deletion on iOS/tvOS, so without this
                // the Top Shelf keeps showing old channels/Continue
                // Watching until the user reconfigures a server.
                if !hasAnySource {
                    TopShelfDataManager.clearAll()
                }
                // Initial Top Shelf sync for Continue Watching
                if let all = try? modelContext.fetch(FetchDescriptor<WatchProgress>()) {
                    TopShelfDataManager.syncContinueWatching(all)
                }
                #endif
            }
            .onChange(of: hasCompletedOnboarding) { _, done in
                if done && showOnboarding {
                    showOnboarding = false
                }
            }
            .onChange(of: hasAnySource) { _, has in
                if has && showOnboarding {
                    showOnboarding = false
                    if !hasCompletedOnboarding {
                        hasCompletedOnboarding = true
                    }
                }
            }
            .onChange(of: servers.count) { _, count in
                debugLog("🟡 RootView.onChange(servers.count): count=\(count), isMergingRemote=\(isMergingRemote)")
                #if os(tvOS)
                // Re-probe LAN whenever servers change (e.g., iCloud sync delivers a server with localURL)
                TVLANProbe.probe(servers: servers)
                #endif
                guard !isMergingRemote else {
                    debugLog("🟡 RootView.onChange(servers.count): SKIPPED (isMergingRemote)")
                    return
                }
                SyncManager.shared.pushServers(servers)
            }
            // Listen for remote server changes from iCloud
            .onReceive(NotificationCenter.default.publisher(for: .syncManagerDidReceiveRemoteServers)) { notification in
                guard let remoteServers = notification.userInfo?["servers"] as? [SyncedServer] else { return }
                let isInitial = notification.userInfo?["isInitial"] as? Bool ?? false
                debugLog("🟢 RootView: received \(remoteServers.count) servers, isInitial=\(isInitial)")
                isMergingRemote = true
                mergeRemoteServers(remoteServers, isInitial: isInitial)
                debugLog("🟢 RootView: merge done. servers=\(servers.count)")

                if isInitial && !remoteServers.isEmpty {
                    UserDefaults.standard.set(true, forKey: "launchOnLiveTV")
                }

                // Release merge guard on next run-loop iteration so any remaining
                // SwiftUI @Query side-effects from the save() are fully processed.
                DispatchQueue.main.async {
                    debugLog("🟢 RootView: releasing isMergingRemote")
                    isMergingRemote = false
                }
            }
            // SyncManager asks the app to push current servers (first-device scenario)
            .onReceive(NotificationCenter.default.publisher(for: .syncManagerNeedsPush)) { notification in
                let immediate = notification.userInfo?["immediate"] as? Bool ?? false
                SyncManager.shared.pushServers(servers, immediate: immediate)
                // Also push watch progress on initial sync
                if let ctx = WatchProgressManager.modelContext,
                   let all = try? ctx.fetch(FetchDescriptor<WatchProgress>()) {
                    SyncManager.shared.pushWatchProgress(all, immediate: immediate)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchProgressDidChange)) { _ in
                guard !isMergingRemote else { return }
                if let ctx = WatchProgressManager.modelContext,
                   let all = try? ctx.fetch(FetchDescriptor<WatchProgress>()) {
                    SyncManager.shared.pushWatchProgress(all)
                    #if os(tvOS)
                    TopShelfDataManager.syncContinueWatching(all)
                    #endif
                }
            }
    }

    // MARK: - Orphaned EPG Cleanup

    /// One-time cleanup that deletes any `EPGProgram` rows whose `serverID`
    /// doesn't match an existing `ServerConnection`. Runs on every launch
    /// but is effectively a no-op after the first successful run unless
    /// the user's SwiftData is corrupted again.
    ///
    /// Why this exists: in builds prior to v1.3.4, deleting a
    /// `ServerConnection` from Settings did not cascade-delete the
    /// `EPGProgram` rows associated with that server. Users who (for
    /// example) deleted their Xtream Codes playlist and added the same
    /// server back via Dispatcharr API would see an empty Live TV guide
    /// because `loadFromCache` would find the orphaned XC rows, compute
    /// them as "fresh" (they were recent), skip the network fetch, and
    /// try to render a guide keyed by XC channel IDs that don't match
    /// the new Dispatcharr channel IDs.
    ///
    /// v1.3.4 fixes the root cause by cascade-deleting on server removal,
    /// AND scoping `loadFromCache` to the active server so orphaned rows
    /// can't leak in. This function handles users who are UPGRADING from
    /// a buggy build and still have orphans sitting in their storage.
    private func pruneOrphanedEPGPrograms() {
        let liveServerIDs = Set(servers.map { $0.id.uuidString })
        let descriptor = FetchDescriptor<EPGProgram>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        var pruned = 0
        for ep in all where !liveServerIDs.contains(ep.serverID) {
            modelContext.delete(ep)
            pruned += 1
        }
        if pruned > 0 {
            try? modelContext.save()
            debugLog("🗑️ Pruned \(pruned) orphaned EPGProgram rows (no matching ServerConnection)")
        }
    }

    // MARK: - Merge Remote Servers

    /// Merges servers received from iCloud into local SwiftData.
    /// Conflict resolution: most recent `lastConnected` wins.
    /// On initial import (fresh install, no local servers), `isActive` from the
    /// remote is respected so the previously-active server is ready to use immediately.
    private func mergeRemoteServers(_ remoteServers: [SyncedServer], isInitial: Bool = false) {
        let localByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let wasEmpty = servers.isEmpty

        // Collect credentials to save to Keychain asynchronously after the merge,
        // keeping the main-thread work (SwiftData insert) fast.
        var pendingCredentials: [(key: String, value: String)] = []

        for remote in remoteServers {
            if let local = localByID[remote.id] {
                // Existing server — update if remote is newer
                let localDate = local.lastConnected ?? local.createdAt
                let remoteDate = remote.lastConnected ?? remote.createdAt
                if remoteDate > localDate {
                    local.name = remote.name
                    local.baseURL = remote.baseURL
                    local.username = remote.username
                    local.epgURL = remote.epgURL
                    local.sortOrder = remote.sortOrder
                    local.isVerified = remote.isVerified
                    local.localURL = remote.localURL
                    local.localEPGURL = remote.localEPGURL
                    local.homeSSID = remote.homeSSID
                    local.lastConnected = remote.lastConnected
                    // Queue credential writes for after the merge
                    if !remote.password.isEmpty {
                        pendingCredentials.append(("password_\(remote.id.uuidString)", remote.password))
                    }
                    if !remote.apiKey.isEmpty {
                        pendingCredentials.append(("apiKey_\(remote.id.uuidString)", remote.apiKey))
                    }
                    DebugLogger.shared.log("SyncManager: updated server \(remote.name) from iCloud",
                                           category: "Sync", level: .info)
                }
            } else {
                // New server from another device — insert locally.
                // Respect isActive from remote only on initial import of a fresh install,
                // so the user's previously-active server is ready without manual selection.
                let shouldActivate = isInitial && wasEmpty && remote.isActive
                let newServer = ServerConnection(
                    name: remote.name,
                    type: remote.type,
                    baseURL: remote.baseURL,
                    username: remote.username,
                    epgURL: remote.epgURL,
                    isActive: shouldActivate,
                    localURL: remote.localURL,
                    localEPGURL: remote.localEPGURL,
                    homeSSID: remote.homeSSID
                )
                // Preserve the original UUID so credentials match across devices
                newServer.id = remote.id
                newServer.sortOrder = remote.sortOrder
                newServer.createdAt = remote.createdAt
                newServer.lastConnected = remote.lastConnected
                newServer.isVerified = remote.isVerified
                // Queue credential writes for after the merge
                if !remote.password.isEmpty {
                    pendingCredentials.append(("password_\(remote.id.uuidString)", remote.password))
                }
                if !remote.apiKey.isEmpty {
                    pendingCredentials.append(("apiKey_\(remote.id.uuidString)", remote.apiKey))
                }
                modelContext.insert(newServer)
                DebugLogger.shared.log("SyncManager: added server \(remote.name) from iCloud (active=\(shouldActivate), hasCreds=\(!remote.password.isEmpty || !remote.apiKey.isEmpty))",
                                       category: "Sync", level: .info)
            }
        }

        // Check for servers deleted on other devices
        let remoteIDs = Set(remoteServers.map { $0.id })
        for local in servers where !remoteIDs.contains(local.id) {
            // Only delete if sync has been active (i.e., remote has servers but this one is missing)
            if !remoteServers.isEmpty {
                local.deleteCredentialsFromKeychain()
                modelContext.delete(local)
                DebugLogger.shared.log("SyncManager: deleted server \(local.name) (removed on another device)",
                                       category: "Sync", level: .info)
            }
        }

        try? modelContext.save()

        // Save credentials to Keychain (must stay on main thread — Security
        // framework can trigger dispatch_assert_queue when called off-main).
        for cred in pendingCredentials {
            debugLog("🔑 Saving credential: \(cred.key)")
            KeychainHelper.save(cred.value, for: cred.key)
        }
        if !pendingCredentials.isEmpty {
            debugLog("🔑 All \(pendingCredentials.count) credentials saved")
        }
    }
}
