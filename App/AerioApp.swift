import SwiftUI
import SwiftData
#if os(iOS)
import NetworkExtension
import Network
import CoreLocation
// CoreWLAN is the native macOS Wi-Fi API and is reachable from Mac
// Catalyst. We use it as a fallback when `NEHotspotNetwork.fetchCurrent()`
// returns nil on Catalyst (a documented-but-misbehaving path: Apple
// claims Catalyst support, but in practice the iOS NetworkExtension
// SSID resolver only reliably reports a value on iPhone/iPad even
// when the wifi-info entitlement + Location are both granted).
#if targetEnvironment(macCatalyst)
import CoreWLAN
#endif
#elseif os(tvOS)
// tvOS doesn't expose NetworkExtension or the SSID APIs, but Network
// (NWPathMonitor) is available — used by `TVLANProbe` below to
// re-probe the home-server on network-change transitions.
import Network
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

    /// Owned explicitly (vs. letting `.modelContainer(for:)` auto-
    /// build it) so we can fire an eager warmup fetch off-main at
    /// launch. On the torture playlist the EPGProgram store has
    /// ~97k rows; SQLite's first-use schema validation + page-cache
    /// warmup can cost 2-3 seconds on iPad, and without this eager
    /// hit the cost lands on the MainActor the first time
    /// `ChannelStore.load` or `@Query var servers` touches the
    /// context — producing a ~3.4s ping#3 hang on warm relaunch.
    /// The warmup fetch runs off main (own `ModelContext`) so by
    /// the time UI code touches the shared context, SQLite is
    /// already open and hot.
    let sharedModelContainer: ModelContainer

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

        // Build the shared container explicitly so we can warm it.
        let schema = Schema([
            ServerConnection.self,
            ChannelGroup.self,
            Channel.self,
            EPGProgram.self,
            M3UPlaylist.self,
            EPGSource.self,
            WatchProgress.self,
            Recording.self
        ])
        do {
            self.sharedModelContainer = try ModelContainer(for: schema)
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }

        // Fire a throwaway fetch off main to force SQLite open +
        // schema validation off the critical path. Uses a fresh
        // background `ModelContext`, never touches MainActor.
        // `ServerConnection` is a tiny table so the fetch itself
        // costs microseconds — the expensive work is in what
        // SwiftData does around it on first access.
        let containerRef = self.sharedModelContainer
        Task.detached(priority: .userInitiated) {
            let start = CFAbsoluteTimeGetCurrent()
            let ctx = ModelContext(containerRef)
            _ = try? ctx.fetch(FetchDescriptor<ServerConnection>())
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            debugLog("🗄️ SwiftData warmup fetch: \(elapsed)ms (off-main)")
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
        .modelContainer(sharedModelContainer)
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
                // Re-probe LAN on every foreground transition — covers
                // the "user took the Apple TV / iPad / Mac to a
                // different network and came back" case that the
                // launch-only probe missed. `reprobe()` reuses the
                // candidate snapshot from the most recent
                // `probe(servers:)` call, so no modelContext access
                // is required here. v1.6.8: now runs on iOS too,
                // not just tvOS — see TVLANProbe header.
                TVLANProbe.shared.reprobe()
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
            // Primary path: NEHotspotNetwork.fetchCurrent() — the
            // documented iOS / iPadOS / Mac Catalyst API. On
            // iPhone + iPad with the wifi-info entitlement and
            // Location granted, this reliably returns the current
            // SSID. On Mac Catalyst it's documented as supported
            // but ships with a long-standing behavioural gap: the
            // call resolves to nil even when the underlying Wi-Fi
            // interface is connected to a known network and the
            // app has Location authorised. v1.6.8 user report
            // (Mac Catalyst, MacBook on "4OH4") surfaced this:
            // app showed "Detected SSID: Not detected" even though
            // the Mac was actively on the configured home
            // network.
            var ssid = await NEHotspotNetwork.fetchCurrent()?.ssid

            #if targetEnvironment(macCatalyst)
            // Fallback path: CoreWLAN. `CWWiFiClient.shared().interface()?.ssid()`
            // is the native macOS resolver and is reachable from
            // Mac Catalyst (linker pulls in CoreWLAN.framework
            // when imported under the `targetEnvironment(macCatalyst)`
            // gate). It's synchronous, gated by the same
            // wifi-info entitlement, and on macOS 14+ also
            // requires Location — both of which are already in
            // place. We only consult it when the NetworkExtension
            // path returned nil, so on the (theoretical) Catalyst
            // build where Apple eventually fixes NEHotspotNetwork,
            // CoreWLAN stays out of the way.
            if ssid == nil {
                if let coreWLANSSID = CWWiFiClient.shared().interface()?.ssid(),
                   !coreWLANSSID.isEmpty {
                    DebugLogger.shared.log(
                        "NetworkMonitor: NEHotspotNetwork returned nil, CoreWLAN fallback resolved SSID = \(coreWLANSSID)",
                        category: "Network", level: .info)
                    ssid = coreWLANSSID
                }
            }
            #endif

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

// MARK: - LAN Probe (cross-platform)
//
// History:
//   • Originally tvOS-only because tvOS doesn't expose
//     NetworkExtension's `NEHotspotNetwork` family — no SSID API
//     means we had to fall back to "can we reach the configured
//     localURL?" as the LAN detection signal.
//   • v1.6.8: promoted to iOS / iPadOS / Mac Catalyst as well.
//     Two reasons:
//        1. Mac Catalyst's `NEHotspotNetwork.fetchCurrent()`
//           returns nil even with the wifi-info entitlement +
//           Location granted (long-standing Apple bug). SSID
//           detection on Mac is effectively broken.
//        2. Ethernet has no SSID at all. A user with a wired
//           iPad / Mac would never get LAN routing under the
//           SSID-only path even when the local server is on
//           the same subnet.
//     Probe-based detection works in both cases — if HEAD on the
//     local URL succeeds, we're on the LAN, period.
//
// The class name (`TVLANProbe`) is kept for now to avoid touching
// every call site; the legacy "tvosLANDetected" UserDefaults key is
// likewise preserved so existing installs don't lose their last-known
// LAN state across the update.
//
// `ServerConnection.isOnLANNetwork` reads this probe's result and OR's
// it with the iOS SSID-match path, so iPhone / iPad still get the
// fast SSID-only signal when NEHotspotNetwork works, but ALSO get the
// probe-based fallback when it doesn't (Mac Catalyst, Ethernet, or any
// case where SSID resolution returns nil).
//
// Reliability hardening (v1.6.7):
//
//   1. Retry: a single HEAD request can lose to transient DNS/ARP
//      flakiness on first boot (the router's ARP cache doesn't yet
//      know the Apple TV's MAC). Up to 3 attempts with a 500ms delay
//      between — first success wins.
//
//   2. Re-probe on foreground: old behaviour only probed at app
//      launch and on servers.count change, which missed the
//      "travel" case where a user takes a MacBook / Apple TV to a
//      friend's place and comes back. Now `scenePhase == .active`
//      fires a re-probe.
//
//   3. Re-probe on network change: `NWPathMonitor` transitions to
//      `.satisfied` (debounced 200ms to coalesce reconnect storms)
//      also trigger a re-probe. Covers Ethernet plug-in mid-session
//      and Wi-Fi handoff between access points.
//
//   4. Rich result metadata: UI can surface the last-probed host,
//      latency, and timestamp so users on a tvOS Settings screen
//      can see "last checked 5 min ago, 42 ms" without guessing.
//      Persisted to UserDefaults for cold-launch read-before-probe.
//
// The class is an `ObservableObject` singleton so `ServerDetailView`
// can `@ObservedObject` it to drive the "Refresh LAN Detection"
// button state + the last-probe labels. Callers remain
// `TVLANProbe.shared.probe(servers:)` — the old static call sites
// in `RootView.onAppear` + `onChange(servers.count)` are updated to
// the new form.
@MainActor
final class TVLANProbe: ObservableObject {
    static let shared = TVLANProbe()

    // MARK: Published state (for Settings UI)

    @Published private(set) var isProbing: Bool = false
    @Published private(set) var lastDetected: Bool = false
    @Published private(set) var lastHost: String? = nil
    @Published private(set) var lastLatencyMs: Int? = nil
    @Published private(set) var lastTimestamp: Date? = nil

    // MARK: Persistence keys (also read externally by
    // `ServerConnection.isOnLANNetwork` for the `detected` bool)

    private static let detectedKey = "tvosLANDetected"
    private static let timestampKey = "tvosLastProbeTimestamp"
    private static let hostKey = "tvosLastProbeHost"
    private static let latencyKey = "tvosLastProbeLatencyMS"

    // MARK: Internal state

    /// Snapshot of URL candidates from the most recent `probe(servers:)`
    /// call. Reused by `reprobe()` on scenePhase foreground + NWPath
    /// `.satisfied` transitions so we don't need to re-plumb the
    /// SwiftData @Query all the way down from RootView.
    private var candidateURLs: [URL] = []

    /// Cancels the in-flight probe when a newer call arrives, so two
    /// overlapping probes (e.g., scenePhase .active landing at the
    /// same moment NWPath fires) don't race each other to
    /// UserDefaults.
    private var currentProbeTask: Task<Void, Never>? = nil

    private let pathMonitor = NWPathMonitor()
    /// Debounce timer for NWPath updates — network-change storms
    /// (Ethernet renegotiation, Wi-Fi roam) emit several .satisfied
    /// transitions in quick succession; we only want to probe once
    /// per storm.
    private var pathDebounce: Task<Void, Never>? = nil

    private init() {
        // Hydrate from UserDefaults so the Settings UI can render the
        // last-known state immediately on cold launch, before the
        // first probe even fires. A probe landing after this will
        // overwrite with fresh values via `record(...)`.
        let defaults = UserDefaults.standard
        self.lastDetected = defaults.bool(forKey: Self.detectedKey)
        let host = defaults.string(forKey: Self.hostKey)
        self.lastHost = (host?.isEmpty == false) ? host : nil
        let latency = defaults.integer(forKey: Self.latencyKey)
        self.lastLatencyMs = latency > 0 ? latency : nil
        let ts = defaults.double(forKey: Self.timestampKey)
        self.lastTimestamp = ts > 0 ? Date(timeIntervalSince1970: ts) : nil

        startPathMonitor()
    }

    // MARK: Public entry points

    /// Primary entry — called from RootView.onAppear, RootView
    /// `onChange(servers.count)`, and the Settings "Refresh LAN
    /// Detection" button. Extracts candidate `localURL` values from
    /// the passed servers, remembers them for future `reprobe()`
    /// calls, and kicks off the probe.
    func probe(servers: [ServerConnection]) {
        let serversWithoutLocal = servers.filter { $0.localURL.isEmpty }.count
        let candidates = servers.compactMap { s -> URL? in
            guard !s.localURL.isEmpty else { return nil }
            var url = s.localURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix("/") { url = String(url.dropLast()) }
            if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "http://" + url }
            return URL(string: url)
        }
        self.candidateURLs = candidates

        guard !candidates.isEmpty else {
            // No `localURL` on any server — this is a CONFIG issue,
            // not a network issue. Record a failed probe so the
            // Settings UI shows "No local URL configured" instead
            // of a stale pre-config true value.
            record(detected: false, host: nil, latencyMs: nil)
            print("📡 tvOS LAN probe: SKIPPED — no local URL configured on any server (\(serversWithoutLocal) server(s) missing `localURL`). Set Settings → Server → Local URL to enable LAN routing.")
            return
        }
        print("📡 tvOS LAN probe: starting — \(candidates.count) candidate local URL(s), \(serversWithoutLocal) server(s) without local URL")
        startProbeTask(candidates: candidates)
    }

    /// Re-probe with the most recently remembered candidate set. Used
    /// by scenePhase `.active` and `NWPathMonitor`'s `.satisfied`
    /// transition — neither has a fresh servers array handy, so we
    /// reuse the snapshot from the last `probe(servers:)` call.
    func reprobe() {
        let candidates = self.candidateURLs
        guard !candidates.isEmpty else {
            // First probe hasn't happened yet (rare — would mean
            // scenePhase .active fired before RootView.onAppear).
            // Skip silently; the imminent onAppear probe will hydrate
            // our candidate snapshot.
            return
        }
        print("📡 tvOS LAN probe: re-probing (\(candidates.count) candidate(s))")
        startProbeTask(candidates: candidates)
    }

    // MARK: Probe core

    private func startProbeTask(candidates: [URL]) {
        // Cancel any probe that's still running. The newer call's
        // result should win — a user tapping "Refresh" during a
        // slow in-flight probe shouldn't wait for the old one to
        // time out before their explicit request takes effect.
        currentProbeTask?.cancel()
        currentProbeTask = Task {
            await runProbe(candidates: candidates)
        }
    }

    private func runProbe(candidates: [URL]) async {
        isProbing = true
        defer { isProbing = false }

        let maxAttempts = 3
        let retryDelayNs: UInt64 = 500_000_000 // 500ms
        var allLogs: [String] = []

        for attempt in 1...maxAttempts {
            for baseURL in candidates {
                guard !Task.isCancelled else { return }
                // Per-candidate HEAD request with a 3s timeout.
                // Bumped from 2s historically because some home
                // routers respond slowly to the first connection to
                // a host the ARP table doesn't know yet (observed
                // on Ubiquiti setups when the TV just came off
                // standby).
                var request = URLRequest(url: baseURL, timeoutInterval: 3.0)
                request.httpMethod = "HEAD"
                let start = Date()
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                        // SUCCESS — any 2xx/3xx/4xx response proves
                        // the TCP+HTTP path is alive. 5xx could be
                        // a hung upstream so we don't treat that as
                        // proof of LAN reachability.
                        let host = baseURL.host ?? baseURL.absoluteString
                        allLogs.append("\(host)=\(http.statusCode)/\(ms)ms ✓ (attempt \(attempt)/\(maxAttempts))")
                        record(detected: true, host: host, latencyMs: ms)
                        print("📡 tvOS LAN probe: DETECTED — \(allLogs.joined(separator: ", "))")
                        return
                    } else if let http = response as? HTTPURLResponse {
                        allLogs.append("\(baseURL.host ?? "?")=\(http.statusCode)/\(ms)ms ✗ (attempt \(attempt))")
                    }
                } catch {
                    let nsErr = error as NSError
                    allLogs.append("\(baseURL.host ?? "?")=err(\(nsErr.code)) (attempt \(attempt))")
                }
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: retryDelayNs)
                guard !Task.isCancelled else { return }
            }
        }

        // All attempts failed — record a definitive false so
        // `effectiveBaseURL` falls back to the external URL and the
        // UI reflects the failure with a timestamp the user can
        // cross-reference against their network state.
        record(detected: false, host: nil, latencyMs: nil)
        print("📡 tvOS LAN probe: FAILED after \(maxAttempts) attempts — [\(allLogs.joined(separator: ", "))]. Streams will use external URL.")
    }

    /// Commits a probe result to both UserDefaults (so the rest of
    /// the app + cold-launch state can read it synchronously) and
    /// `@Published` state (so the Settings UI can re-render).
    private func record(detected: Bool, host: String?, latencyMs: Int?) {
        let timestamp = Date()
        let defaults = UserDefaults.standard
        defaults.set(detected, forKey: Self.detectedKey)
        defaults.set(timestamp.timeIntervalSince1970, forKey: Self.timestampKey)
        defaults.set(host ?? "", forKey: Self.hostKey)
        defaults.set(latencyMs ?? 0, forKey: Self.latencyKey)

        self.lastDetected = detected
        self.lastHost = host
        self.lastLatencyMs = latencyMs
        self.lastTimestamp = timestamp
    }

    // MARK: NWPathMonitor

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // We only care about the "just came online" transition
            // — `.satisfied` means the OS has a usable default
            // route. Partial-connectivity and offline states would
            // only waste a probe round-trip.
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self.pathDebounce?.cancel()
                self.pathDebounce = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    self.reprobe()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}

// MARK: - App Entry View (Splash → Root)
// splashFinished is @State (in-memory only), so it resets to false on every
// cold launch (force-close + reopen or first install). When the user simply
// backgrounds and foregrounds the app the process stays alive, @State keeps
// its true value, and the splash is not replayed. No persistence needed.
struct AppEntryView: View {
    @State private var splashFinished = false
    @Environment(\.modelContext) private var modelContext

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
        .onAppear {
            kickoffSplashTimePreload()
        }
    }

    /// v1.6.13.x: Pre-warm the channel + EPG cache load DURING the
    /// splash animation, instead of waiting until MainTabView's
    /// `.task(channelServerKey)` fires (which doesn't run until the
    /// 2.8s splash dismisses + RootView mounts + MainTabView lays
    /// out). With "Skip Loading Screen" enabled, the user sees an
    /// empty Live TV tab for that whole window unless we overlap
    /// the network fetch with the splash.
    ///
    /// `ChannelStore.refresh` is now idempotent (see HomeView.swift
    /// — the guard short-circuits when a load is already in flight
    /// for the same server), so MainTabView's later call is a no-op
    /// and the channel fetch we kicked off here gets to keep running
    /// without being cancelled + re-issued.
    @MainActor
    private func kickoffSplashTimePreload() {
        let descriptor = FetchDescriptor<ServerConnection>()
        guard let servers = try? modelContext.fetch(descriptor),
              !servers.isEmpty else { return }
        ChannelStore.shared.refresh(servers: servers)

        // Also kick off the SwiftData EPG cache load so the guide
        // can render immediately on first paint with cached programs.
        // `loadFromCache` is `inFlightLoadTask`-coalesced inside
        // GuideStore so MainTabView's later call won't duplicate.
        // GuideStore.loadFromCache logs its own completion line.
        let activeServer = servers.first(where: { $0.isActive }) ?? servers.first
        let activeServerID = activeServer?.id.uuidString ?? "unknown"
        let context = modelContext
        Task {
            _ = await GuideStore.shared.loadFromCache(
                modelContext: context,
                channels: [],
                serverID: activeServerID
            )
        }
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

    /// v1.6.12: drives the post-update "What's new" sheet. Set to
    /// `true` from `onAppear` only when `WhatsNewStore.shouldShow()`
    /// returns true — i.e. user is on a release we have curated
    /// notes for, hasn't already acknowledged this version, and
    /// hasn't permanently opted out. Kept on a slight delay so the
    /// sheet rises after the splash → root transition settles.
    @State private var showWhatsNew = false

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
            .whatsNewSheet(isPresented: $showWhatsNew)
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

                // v1.6.12: post-update "What's new" pop-up. Only fire
                // when the onboarding cover isn't being raised (we
                // don't want two modals stacking on the very first
                // launch) and the store says we have a fresh release
                // entry the user hasn't seen yet.
                //
                // `isExistingUser` resolves the v1.6.11 → v1.6.12
                // upgrade case: the marker UserDefault didn't exist
                // pre-1.6.12, so on the first launch with this code
                // an upgrader's `lastSeenVersion` is nil. Without
                // this signal the store would mistake them for a
                // fresh install and silently skip. Anyone with
                // servers configured or onboarding marked complete
                // is conclusively an existing user.
                //
                // The 0.6 s delay lets the splash → MainTabView
                // opacity transition finish so the sheet animates in
                // cleanly instead of racing the splash fade.
                let isExistingUser = hasCompletedOnboarding || hasAnySource
                if !showOnboarding && WhatsNewStore.shouldShow(isExistingUser: isExistingUser) {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        // Re-check after the delay: if the user
                        // backgrounded the app or onboarding raced in
                        // during the wait, skip silently.
                        if !showOnboarding && !showWhatsNew {
                            showWhatsNew = true
                        }
                    }
                }
                // One-time cleanup: purge EPGProgram rows belonging to any
                // server that no longer exists. Fixes historical damage
                // from an earlier build where server deletion didn't
                // cascade EPG rows — users who deleted a server type and
                // re-added the same server via a different type would end
                // up with orphaned EPG data that left the guide empty.
                pruneOrphanedEPGPrograms()
                // v1.6.8 (Codex D1): one-shot KVS → iCloud Keychain
                // credential migration. For every server, copy any
                // local-Keychain credential into the iCloud-synchronizable
                // Keychain so a user's existing v1.6.7 install rolls
                // forward without re-auth and so brand-new devices
                // signed into the same Apple ID get credentials via
                // Keychain (E2E encrypted) instead of relying on KVS
                // plaintext. Idempotent: `migrateToSynchronizable`
                // skips keys already in iCloud Keychain. The
                // `kvsToKeychainMigrationDoneV1` flag prevents the
                // (cheap) walk on every launch — the migration only
                // needs to run once per device, since
                // `mergeRemoteServers` and `saveCredentialsSynced`
                // both write to iCloud Keychain on every save going
                // forward.
                migrateCredentialsToICloudKeychainIfNeeded()
                // v1.6.12: drain any legacy plaintext credentials
                // still parked in iCloud KVS by overwriting the
                // cloud payload with a credential-free push. Runs
                // once per device, idempotent (gated by a separate
                // UserDefaults flag).
                purgeKVSPlaintextCredentialsIfNeeded()
                // Cross-platform LAN probe (formerly tvOS-only). On
                // iOS this complements the SSID-based detection so
                // hardwired iPads / Mac Catalyst still get LAN
                // routing even when SSID resolution returns nil.
                TVLANProbe.shared.probe(servers: servers)
                #if os(tvOS)
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
                // Re-probe LAN whenever servers change (e.g., iCloud
                // sync delivers a server with localURL). Cross-
                // platform as of v1.6.8 — see TVLANProbe header.
                TVLANProbe.shared.probe(servers: servers)
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
    /// v1.6.8 (Codex D1): one-shot launch migration that walks every
    /// `ServerConnection` and copies its local-Keychain credentials
    /// into the iCloud-synchronizable Keychain via
    /// `KeychainHelper.migrateToSynchronizable`. Gated by a UserDefaults
    /// flag so the (cheap) walk runs at most once per device.
    ///
    /// Why it's safe to run unconditionally idempotent:
    ///   • `migrateToSynchronizable` reads the local Keychain item
    ///     and skips writing to iCloud Keychain when an iCloud item
    ///     already exists for the same key. So re-running can't
    ///     corrupt or downgrade an already-migrated credential.
    ///   • Local Keychain items remain in place — we don't delete
    ///     them. `effectivePassword`/`effectiveApiKey`'s read order
    ///     (local → iCloud → SwiftData) makes the local copy a
    ///     valid fallback if the user later disables iCloud Sync.
    ///
    /// v1.6.12 update: KVS plaintext is no longer written by this
    ///   version. `SyncManager.serialize` stopped emitting
    ///   `_password` / `_apiKey` keys, and a sibling launch task
    ///   (`purgeKVSPlaintextCredentialsIfNeeded`, below) actively
    ///   overwrites the cloud KVS with a credential-free payload on
    ///   first upgraded launch. Older clients (pre-v1.6.12) will
    ///   keep pushing plaintext until they roll forward, but we
    ///   don't read that plaintext on the next round-trip — the
    ///   already-running migration above means our local Keychain
    ///   is canonical and we only need KVS for non-secret
    ///   server-list metadata.
    private func migrateCredentialsToICloudKeychainIfNeeded() {
        let flagKey = "kvsToKeychainMigrationDoneV1"
        if UserDefaults.standard.bool(forKey: flagKey) { return }
        // Migration only does useful work when iCloud Sync is on —
        // otherwise the local Keychain is the only intended store
        // and copying to iCloud Keychain would defy the user's
        // explicit "no iCloud" preference. The flag is still set
        // so we don't re-walk on every launch; if the user enables
        // iCloud Sync later, `saveCredentialsSynced` writes to both
        // stores on every credential save and `mergeRemoteServers`
        // fills in iCloud Keychain when remote servers arrive.
        guard SyncManager.shared.isSyncEnabled else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }
        var migrated = 0
        for server in servers {
            let id = server.id.uuidString
            if KeychainHelper.migrateToSynchronizable(key: "password_\(id)") {
                migrated += 1
            }
            if KeychainHelper.migrateToSynchronizable(key: "apiKey_\(id)") {
                migrated += 1
            }
        }
        UserDefaults.standard.set(true, forKey: flagKey)
        if migrated > 0 {
            DebugLogger.shared.log(
                "Credential migration: copied \(migrated) credential(s) to iCloud Keychain across \(servers.count) server(s)",
                category: "Sync", level: .info)
        }
    }

    /// One-shot launch task that scrubs legacy plaintext credentials
    /// out of iCloud KVS on first upgraded launch.
    ///
    /// Pre-v1.6.12 clients pushed `_password` and `_apiKey` strings
    /// into the per-server dict in the KVS payload — see the
    /// docstring on `SyncManager.serialize` for the historical
    /// rationale. v1.6.12 stopped writing those keys, but any
    /// payload already in the cloud (pushed by an older device or by
    /// this device before the upgrade) still carries them until a
    /// fresh push overwrites it. Natural pushes are debounced and
    /// only fire on server-list changes, so a user who doesn't touch
    /// their Settings → Servers list could leave plaintext sitting
    /// in KVS for an arbitrary amount of time.
    ///
    /// This task forces an immediate (non-debounced) push from this
    /// device, which writes a credential-free payload (because
    /// `serialize` no longer emits the secret keys) and overwrites
    /// whatever is currently in the cloud. After one successful run
    /// the `kvsCredentialPurgeDoneV1` UserDefaults flag prevents
    /// re-runs.
    ///
    /// Safe to run when iCloud Sync is disabled — we early-out and
    /// just set the flag, since with Sync off we never write to KVS
    /// anyway and any plaintext sitting up there can't reach this
    /// device. If the user later enables Sync, the next natural push
    /// (which fires on the toggle) will write the credential-free
    /// payload.
    private func purgeKVSPlaintextCredentialsIfNeeded() {
        let flagKey = "kvsCredentialPurgeDoneV1"
        if UserDefaults.standard.bool(forKey: flagKey) { return }

        guard SyncManager.shared.isSyncEnabled else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }
        // No servers means nothing to push — the cloud KVS will be
        // overwritten with an empty array by the regular push flow
        // the moment the user adds their first server.
        guard !servers.isEmpty else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        // Force a non-debounced push so the cloud KVS gets a
        // credential-free payload immediately. `pushServers` calls
        // `serialize` on each server, which (post-v1.6.12) omits
        // `_password` / `_apiKey` — the new payload supersedes the
        // legacy one in KVS.
        SyncManager.shared.pushServers(servers, immediate: true)
        UserDefaults.standard.set(true, forKey: flagKey)
        DebugLogger.shared.log(
            "KVS credential purge: scheduled immediate credential-free push for \(servers.count) server(s)",
            category: "Sync", level: .info)
    }

    private func pruneOrphanedEPGPrograms() {
        // Fetch + iterate all EPGProgram rows on the main MainActor
        // context WAS the dominant cost of warm-relaunch startup on
        // the torture playlist (97k rows × 2+ seconds of main-thread
        // fetch + loop). We now push both the fetch AND the delete
        // loop to a background `ModelContext` and narrow the fetch
        // via a predicate so SQLite only returns the rows we're
        // actually going to delete — which is almost always zero.
        //
        // Note: the v1.6.7 XMLTV category-fix migration USED to live
        // here too, but moved into `GuideStore.loadFromCache` so the
        // purge + the SwiftData fetch happen on the same background
        // ModelContext in strict order. Running them as two separate
        // detached tasks at different priorities raced — the higher-
        // priority loadFromCache read the old rows before the
        // lower-priority prune could delete them, and those old
        // concatenated-category strings landed in GuideStore.programs
        // and persisted through the session.
        let liveServerIDArray = servers.map { $0.id.uuidString }
        let container = modelContext.container
        Task.detached(priority: .utility) {
            let bgContext = ModelContext(container)
            let descriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> { !liveServerIDArray.contains($0.serverID) }
            )
            guard let orphans = try? bgContext.fetch(descriptor), !orphans.isEmpty else { return }
            for ep in orphans { bgContext.delete(ep) }
            try? bgContext.save()
            debugLog("🗑️ Pruned \(orphans.count) orphaned EPGProgram rows (background)")
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
                    // v1.6.20: adopt remote's auto-detected Dispatcharr
                    // auth shape if it discovered one. Empty remote
                    // value (no detection yet on the source device)
                    // doesn't overwrite a working local discovery.
                    if !remote.dispatcharrAuthMode.isEmpty {
                        local.dispatcharrAuthMode = remote.dispatcharrAuthMode
                    }
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
                // v1.6.20: inherit the auto-detected Dispatcharr auth
                // shape from the source device so the new install
                // doesn't have to re-run discovery on first cold
                // start. Empty remote value falls through to the
                // model default of `""` which `dispatcharrHeaderMode`
                // resolves to `.both` for back-compat.
                newServer.dispatcharrAuthMode = remote.dispatcharrAuthMode
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
        //
        // v1.6.8 (Codex D1): also write to the iCloud-synchronizable
        // Keychain so a credential merged in from one device propagates
        // to every other device on the same Apple ID without going
        // through the KVS plaintext path. The local-only write stays
        // for the case where the user later disables iCloud Sync —
        // they still need a copy of their credentials on this device.
        // `effectivePassword` / `effectiveApiKey` already prefer local,
        // then iCloud, then SwiftData, so the dual write is invisible
        // to readers. v1.6.7 devices keep working because we still
        // include plaintext in the KVS payload (see
        // `SyncManager.serialize`); the KVS plaintext gets phased out
        // in v1.7.x once the v1.6.7 install base has rolled forward.
        for cred in pendingCredentials {
            debugLog("🔑 Saving credential: \(cred.key)")
            KeychainHelper.save(cred.value, for: cred.key)
            KeychainHelper.save(cred.value, for: cred.key, synchronizable: true)
        }
        if !pendingCredentials.isEmpty {
            debugLog("🔑 All \(pendingCredentials.count) credentials saved (local + iCloud)")
        }
    }
}
