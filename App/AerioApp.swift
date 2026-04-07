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
                }
                #if os(tvOS)
                .onOpenURL { url in
                    // Handle aerio://channel/<id> deep links from Top Shelf
                    guard url.scheme == "aerio",
                          url.host == "channel",
                          let channelID = url.pathComponents.last, !channelID.isEmpty else { return }
                    // Store the channel ID for the Live TV tab to pick up
                    UserDefaults.standard.set(channelID, forKey: "launchChannelID")
                    UserDefaults.standard.set(true, forKey: "launchOnLiveTV")
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
            WatchProgress.self
        ])
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                DebugLogger.shared.logLifecycle("Scene → active (foreground)")
                // Always refresh the cached SSID when foregrounding so LAN/WAN
                // switching reacts immediately after the user toggles Wi-Fi.
                #if os(iOS)
                NetworkMonitor.shared.refresh()
                #endif
                // Start iCloud sync if enabled
                SyncManager.shared.startObserving()
            case .inactive:    DebugLogger.shared.logLifecycle("Scene → inactive")
            case .background:
                DebugLogger.shared.logLifecycle("Scene → background")
                #if os(tvOS)
                // Stop playback so audio doesn't continue in the background.
                // tvOS has no PiP or background audio entitlement for IPTV streams.
                NotificationCenter.default.post(name: .stopPlaybackForBackground, object: nil)
                #endif
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

    private let pathMonitor = NWPathMonitor()
    private var lastWifiState = false
    private let locationDelegate = LocationDelegate()

    private init() {
        startPathMonitor()
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
        }
    }

    private func ensureLocationAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        let status = locationDelegate.manager.authorizationStatus
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            completion(true)
        case .notDetermined:
            locationDelegate.onAuthChange = { newStatus in
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
                } else if !onWifi {
                    // Left WiFi — clear SSID so we don't use a stale LAN URL.
                    self.currentSSID = nil
                    UserDefaults.standard.removeObject(forKey: "cachedCurrentSSID")
                }
                self.lastWifiState = onWifi
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}

/// Minimal CLLocationManager delegate for obtaining location authorization.
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var onAuthChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        onAuthChange?(status)
        onAuthChange = nil
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
                // Share model context with WatchProgressManager for VOD resume tracking
                WatchProgressManager.modelContext = modelContext
                if !hasCompletedOnboarding && !hasAnySource {
                    showOnboarding = true
                }
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
