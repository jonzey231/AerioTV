import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif
#if os(iOS)
import Network
#elseif os(tvOS)
// Network (NWPathMonitor) is available — used by `TVLANProbe` below to
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

#if os(iOS)
/// Process-wide holder for the interface-orientation mask the app reports
/// to UIKit, plus the helper that drives an actual rotation (issue #38).
///
/// The app stays portrait on iPhone so browse / guide / settings never
/// rotate; ONLY the video player widens the mask to landscape while the
/// user holds fullscreen, and exiting restores the natural orientation.
/// iPad keeps its free rotation. `requestGeometryUpdate` alone cannot
/// override an engaged rotation lock: iOS clamps the requested geometry to
/// what the scene reports from `supportedInterfaceOrientationsFor`, so the
/// AppDelegate reports `mask` and `apply` updates it before rotating.
@MainActor
enum AppOrientationLock {
    /// Mask when nothing is forcing landscape: portrait on iPhone, all
    /// orientations on iPad (so iPad follows the device naturally).
    static var base: UIInterfaceOrientationMask {
        // iPad free-rotates. iPhone allows device-driven rotation (portrait
        // + both landscapes) so the player follows the device again. Before
        // #38 there was no AppDelegate mask, so the Info.plist orientations
        // governed and the app auto-rotated; returning `.portrait` here
        // pinned it portrait and killed auto-rotate. `.allButUpsideDown`
        // restores it; the force-landscape toggle still pins `.landscape`.
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// The mask UIKit honors. Seeded to `.portrait` and corrected for the
    /// running idiom by `syncBase()` at launch; thereafter written only by
    /// `apply`. Read by the AppDelegate on the main thread.
    static var mask: UIInterfaceOrientationMask = .portrait

    /// True while the player is forcing landscape (chrome reads this to pick
    /// its icon, so there is a single source of truth).
    static var isForcingLandscape: Bool { mask == .landscape }

    /// Set the at-rest mask for the current idiom. Called once at launch so
    /// iPad starts free-rotating while iPhone starts portrait.
    static func syncBase() {
        if !isForcingLandscape { mask = base }
    }

    /// Force the player into landscape, or release back to `base`. Updates
    /// the reported mask, then asks the active scene to rotate.
    static func apply(landscape: Bool) {
        let target: UIInterfaceOrientationMask = landscape ? .landscape : base
        mask = target
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            debugLog("🔄 [Orientation] requestGeometryUpdate(landscape=\(landscape)) error=\(error.localizedDescription)")
        }
        // Re-query supportedInterfaceOrientations so the new mask is honored
        // immediately, notably when releasing back to portrait (no pending
        // geometry change would otherwise trigger the re-query).
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Teardown convenience: always return to the natural orientation.
    static func release() {
        guard isForcingLandscape else { return }
        apply(landscape: false)
    }
}

/// Minimal application delegate that exists only to report the dynamic
/// orientation mask above (issue #38). The phone UI's CarPlay support uses
/// a separate *scene* delegate; this is the *application* delegate and the
/// two coexist.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // UIKit invokes delegate methods on the main thread, so it is safe to
        // assume the isolation and seed the at-rest mask for this idiom.
        MainActor.assumeIsolated {
            AppOrientationLock.syncBase()
            // Google Cast sender (GH #33): initialise GCKCastContext once at
            // launch so GCKUICastButton can discover the Android TV receiver.
            // iOS-only; the whole controller is #if os(iOS).
            AerioCastController.shared.start()
            // Companion remote (GH #33 second-screen): passive mDNS browse for
            // open AerioTV Android TV apps, app-lifetime. Chrome-scoped
            // discovery churned the browse on every chrome show (Android
            // device test) -- app scope is the cheap, stable choice.
            CompanionClient.shared.startDiscovery()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { AppOrientationLock.mask }
    }
}
#endif

@main
struct AerioApp: App {
    #if os(iOS)
    // Issue #38: report AppOrientationLock.mask so the player's fullscreen
    // button can force landscape even under an engaged rotation lock.
    // Coexists with the CarPlay scene delegate (a scene delegate, not this
    // application delegate).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
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

    /// Process-wide handle to the SwiftData container so non-SwiftUI scenes
    /// (the CarPlay scene) can fetch saved servers when the phone UI scene
    /// has not run. Set once in init; read on the main thread thereafter.
    nonisolated(unsafe) static var sharedContainer: ModelContainer?

    init() {
        #if DEBUG
        // Test-harness hooks, DEBUG builds only. Both read standard
        // launch arguments (UserDefaults maps "-key value" args).
        //
        // -tmdbAPIKeyOverride <key>: writes the supplied key into the
        // SAME keychain slot the Settings field uses, so automated
        // device runs can exercise the TMDB suite without driving the
        // on-screen keyboard. The key itself is never logged.
        if let key = UserDefaults.standard.string(forKey: "tmdbAPIKeyOverride"),
           !key.isEmpty {
            TMDBPosters.saveAPIKey(key)
            debugLog("🎬 TMDB key override applied from launch argument (length \(key.count))")
        }
        // -debugYouTubeProbe <videoKey>: after the UI settles, probe
        // whether the tvOS YouTube app accepts a deep link (parity
        // dossier P3 item 12). Logs canOpenURL plus the open() result
        // for both the youtube:// scheme and the https universal link.
        if let probeKey = UserDefaults.standard.string(forKey: "debugYouTubeProbe"),
           !probeKey.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if let deep = URL(string: "youtube://watch?v=\(probeKey)") {
                    debugLog("[YT-PROBE] canOpen(youtube://) = \(UIApplication.shared.canOpenURL(deep))")
                    // Log the attempt BEFORE calling open: if YouTube comes
                    // foreground, this app suspends and a post-open write can
                    // be lost, hiding the result.
                    debugLog("[YT-PROBE] attempting open(youtube://watch?v=...)")
                    UIApplication.shared.open(deep) { ok in
                        debugLog("[YT-PROBE] open(youtube://watch?v=...) -> \(ok)")
                    }
                }
                try? await Task.sleep(for: .seconds(8))
                if let universal = URL(string: "https://www.youtube.com/watch?v=\(probeKey)") {
                    debugLog("[YT-PROBE] attempting open(https universal link)")
                    UIApplication.shared.open(universal) { ok in
                        debugLog("[YT-PROBE] open(https universal link) -> \(ok)")
                    }
                }
            }
        }
        #endif

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
            // Expose the container so the CarPlay scene can fetch servers
            // and hydrate channels without the phone UI scene running.
            Self.sharedContainer = self.sharedModelContainer
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

        // Live Rewind launch sweep: buffered video dies an hour after
        // its session ends, which usually elapses while the app isn't
        // running - so the reaper must run at launch, not only during
        // sessions (user clarification 2026-07-11).
        LiveRewindEngine.shared.startupSweep()
    }

    var body: some Scene {
        WindowGroup {
            AppEntryView()
                .environmentObject(ThemeManager.shared)
                // GH #33: this Apple TV is a companion HOST -- advertise
                // _aeriotv._tcp + run the WS server so an iPhone or Android
                // phone can control it. Overlay shows the pairing code on the
                // TV during pairing. iOS is a client, not a host (no-op there).
                #if os(tvOS)
                .overlay { CompanionPairingOverlay() }
                .task { CompanionHost.shared.start() }
                #endif
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
                #if os(tvOS)
                // GH #33: tvOS cancels the companion host's NWListener on
                // suspend and start() alone won't revive it (started guard) --
                // re-assert the _aeriotv._tcp advert on every foreground.
                CompanionHost.shared.ensureRunning()
                #endif
                #if os(iOS)
                // GH #33: the companion browse can die while suspended (its
                // .failed only lands on resume); re-assert so the Control-TV
                // button never shows a frozen device list.
                CompanionClient.shared.ensureDiscovery()
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
                // v1.7.x: Direct Connect session warmup. Refresh the
                // JWT access token (or re-login from Keychain
                // credentials) for every Dispatcharr Direct Connect
                // server so foreground requests land with a fresh
                // Bearer header instead of relying on the api_key
                // fallback. Best-effort: errors logged but never
                // surfaced; the fallback keeps the app functional.
                Self.warmupDirectConnectSessions(in: sharedModelContainer.mainContext)
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

    // MARK: - Direct Connect session warmup

    /// v1.7.x: refresh JWT access tokens for every Dispatcharr Direct
    /// Connect server. Fired from the scene-phase `.active` transition
    /// (covers cold launch, foreground resume, and the user picking
    /// our app back up after multitasking elsewhere).
    ///
    /// Strategy per server:
    ///   - If a refresh token is cached in `DispatcharrTokenStore`,
    ///     try `/api/accounts/token/refresh/`. On success, swap in
    ///     the new access token (refresh stays the same — Dispatcharr
    ///     does not rotate it).
    ///   - On `.refreshExpired` (24h+ idle session), clear the cache
    ///     entry and fall through to a fresh login.
    ///   - Fresh login uses the username + password persisted in the
    ///     Keychain. Both must be present; missing credentials skip
    ///     this server (the api_key fallback in `authHeaders` covers
    ///     subsequent requests).
    ///
    /// All work is best-effort: failures are logged but never
    /// surfaced. Fires in a detached Task so the scene-phase handler
    /// returns immediately and the user doesn't see any UI lag.
    @MainActor
    static func warmupDirectConnectSessions(in context: ModelContext) {
        // v1.7.x crash fix: previously this used a `#Predicate`
        // expression against `$0.type.rawValue`, but SwiftData's
        // predicate validator can't introspect a `String`-raw enum
        // through `.rawValue` and crashes at fetch time with
        // "Failed to validate \ServerConnection.type.rawValue
        // because rawValue is not a member of ServerType".
        // Workaround: fetch every server and filter in Swift.
        // The cost is negligible (a typical user has 1-3 servers)
        // and the resulting code is straightforward.
        let descriptor = FetchDescriptor<ServerConnection>()
        guard let allServers = try? context.fetch(descriptor),
              !allServers.isEmpty else { return }
        let servers = allServers.filter { $0.type == .dispatcharrAPI }
        guard !servers.isEmpty else { return }

        // Build per-server credential snapshots on main (Keychain
        // reads are thread-safe but ServerConnection is a SwiftData
        // @Model — pluck the values here, hand the primitives off
        // to the detached Task below).
        struct WarmupTarget: Sendable {
            let id: UUID
            let baseURL: String
            let username: String
            let password: String
            let userAgent: String
        }
        let targets: [WarmupTarget] = servers.compactMap { server in
            guard server.dispatcharrCredentialType == .usernamePassword else { return nil }
            return WarmupTarget(
                id: server.id,
                baseURL: server.effectiveBaseURL,
                username: server.username,
                password: server.effectivePassword,
                userAgent: server.effectiveUserAgent
            )
        }
        guard !targets.isEmpty else { return }

        Task.detached(priority: .utility) {
            for target in targets {
                await DispatcharrTokenStore.shared.warmup(
                    serverID: target.id,
                    baseURL: target.baseURL,
                    username: target.username,
                    password: target.password,
                    userAgent: target.userAgent
                )
            }
        }
    }
}

// MARK: - LAN Probe (cross-platform)
//
// History:
//   • Originally tvOS-only because tvOS doesn't expose a Wi-Fi SSID
//     API — we fell back to "can we reach the configured localURL?"
//     as the LAN detection signal.
//   • v1.6.8: promoted to iOS / iPadOS / Mac Catalyst as well.
//   • Later: SSID / location / Wi-Fi-info detection was removed
//     entirely. The probe is now the SOLE decider on every platform:
//     if a HEAD on the local URL succeeds, we're on the LAN, period.
//     This is network-medium-agnostic (Ethernet, Wi-Fi, VPN-bypass)
//     and requires no location permission or Wi-Fi-info entitlement.
//
// The class name (`TVLANProbe`) is kept to avoid touching every call
// site; the legacy "tvosLANDetected" UserDefaults key is likewise
// preserved so existing installs don't lose their last-known LAN
// state across the update.
//
// `ServerConnection.isOnLANNetwork` reads this probe's result and
// nothing else — it is the only LAN signal on all platforms.
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

    /// Awaitable re-probe for the guide/playback failover paths. Runs the
    /// same candidate set + retry/timeout logic as `reprobe()` but returns
    /// only after the verdict is written, so the caller can read the fresh
    /// `effectiveBaseURL` immediately. Returns the new LAN-detected value.
    @discardableResult
    func reprobeAndWait() async -> Bool {
        let candidates = self.candidateURLs
        guard !candidates.isEmpty else { return UserDefaults.standard.bool(forKey: Self.detectedKey) }
        currentProbeTask?.cancel()
        let task = Task { await runProbe(candidates: candidates) }
        currentProbeTask = task
        await task.value
        return UserDefaults.standard.bool(forKey: Self.detectedKey)
    }

    // MARK: Probe core

    private func startProbeTask(candidates: [URL]) {
        // Assume we are NOT on the LAN until this probe positively confirms
        // it. Clearing the persisted detection flag up front means
        // `effectiveBaseURL` defaults to the always-reachable external URL the
        // instant a probe starts (launch, foreground, or network change),
        // rather than routing streams to a possibly-now-unreachable LAN host
        // for the multi-second life of a failing probe. The break this fixes:
        // leaving home Wi-Fi for cellular (getting in the car) left the stale
        // `true` in place, so playback hit the dead LAN URL until a manual
        // Test Connection forced a reprobe. At home the probe re-confirms the
        // LAN in well under a second, and the SSID fast-path keeps routing
        // correct in the meantime whenever the SSID is known.
        if UserDefaults.standard.bool(forKey: Self.detectedKey) {
            UserDefaults.standard.set(false, forKey: Self.detectedKey)
            lastDetected = false
        }
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

        // Fast path: if the device is not on WiFi or wired Ethernet, every LAN
        // URL (a private-subnet address) is unreachable by definition. Skip the
        // HEAD probes (which would otherwise eat their full timeout against a
        // dead host) and record the external URL immediately, so a playing
        // stream re-tunes to WAN the instant WiFi drops instead of after a
        // multi-second probe. tvOS is always WiFi/wired, so this only ever
        // trips on iPhone/iPad cellular.
        let currentPath = pathMonitor.currentPath
        if currentPath.status == .satisfied,
           !currentPath.usesInterfaceType(.wifi),
           !currentPath.usesInterfaceType(.wiredEthernet) {
            record(detected: false, host: nil, latencyMs: nil)
            print("📡 LAN probe: off-LAN interface (cellular) — external URL, no probe")
            return
        }

        let maxAttempts = 2
        let retryDelayNs: UInt64 = 300_000_000 // 300ms
        var allLogs: [String] = []

        for attempt in 1...maxAttempts {
            for baseURL in candidates {
                guard !Task.isCancelled else { return }
                // Per-candidate HEAD request with a 2s timeout. Some
                // home routers (notably Ubiquiti) respond slowly to the
                // first connection to a host the ARP table doesn't know
                // yet, so attempt 1 may eat the full timeout warming the
                // path while the 2nd attempt 300ms later then connects
                // fast. 2s x 2 attempts keeps a reachable-but-cold LAN
                // within ~4s worst case while making the leaving-home
                // LAN to WAN failover far snappier than the old 3s x 3
                // (which took ~10s before falling back).
                var request = URLRequest(url: baseURL, timeoutInterval: 2.0)
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

        // The verdict may have just flipped LAN<->WAN (e.g. the user left
        // home WiFi for cellular). If a live stream is playing, re-point it to
        // the now-correct URL right away rather than waiting for it to freeze
        // and error out on a dead host. `retuneCurrentToActiveURL` is a no-op
        // when nothing is playing or the URL is unchanged, so a no-flip probe
        // costs nothing here.
        if NowPlayingManager.shared.playingItem != nil {
            PlayerSession.shared.retuneCurrentToActiveURL()
        }
    }

    // MARK: NWPathMonitor

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Re-probe on every usable-route update (`.satisfied`),
            // which fires on WiFi/cellular switches and other network
            // changes, not just a cold "just came online" — that is how
            // leaving home WiFi triggers the LAN to WAN re-tune. Skip
            // offline / partial-connectivity states (nothing to reach).
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
    #if DEBUG
    /// `-AerioFadeProbeURL <url>`: see the body comment.
    static var fadeProbeURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-AerioFadeProbeURL"),
              args.indices.contains(i + 1) else { return nil }
        return URL(string: args[i + 1])
    }
    #endif
    @State private var splashFinished = false
    @Environment(\.modelContext) private var modelContext
    // Observes appearance mode so `.preferredColorScheme` re-resolves live
    // when the user flips Dark / Light / System (or an iCloud sync applies it).
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            #if DEBUG
            if let probeURL = Self.fadeProbeURL {
                // Test-only harness: boots straight into the native
                // AVPlayer screen with the URL from the launch
                // arguments, bypassing onboarding/server state, so a
                // simulator run can exercise the chrome fade with zero
                // configuration. DEBUG builds only; the URL arrives
                // via launch args, so nothing is bundled.
                NativeHLSPlayerScreen(
                    item: ChannelDisplayItem(
                        id: "fade-probe",
                        name: "Fade Probe",
                        number: "0",
                        logoURL: nil,
                        group: "",
                        categoryOrder: 0,
                        streamURL: probeURL,
                        streamURLs: [probeURL]
                    ),
                    userAgent: nil,
                    overrideURL: probeURL
                )
            } else if splashFinished {
                RootView()
                    .transition(.opacity)
            } else {
                SplashView(isFinished: $splashFinished)
                    .transition(.opacity)
            }
            #else
            if splashFinished {
                RootView()
                    .transition(.opacity)
            } else {
                SplashView(isFinished: $splashFinished)
                    .transition(.opacity)
            }
            #endif
        }
        .animation(.easeIn(duration: 0.3), value: splashFinished)
        // Resolved appearance mode: .dark / .light, or nil for System (follow OS).
        // Player chrome and video scrims stay dark independently via their own
        // `.environment(\.colorScheme, .dark)` overrides.
        .preferredColorScheme(theme.resolvedColorScheme)
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
    // Observes appearance mode so the app re-resolves its color scheme live
    // when the user changes Dark / Light / System in Settings.
    @ObservedObject private var theme = ThemeManager.shared

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

    /// Live Rewind one-time feature prompt (task #145 P2). The P1 field
    /// test proved the need: the feature ships OFF by default and the
    /// toggle sat unnoticed in Settings, so the player showed no
    /// transport at all. Asked once; both answers write the seen flag.
    @AppStorage("liveRewindPromptSeen") private var liveRewindPromptSeen = false
    @AppStorage("liveRewindEnabled") private var liveRewindEnabled = false
    @State private var showLiveRewindPrompt = false

    private var hasAnySource: Bool {
        !servers.isEmpty || !playlists.isEmpty
    }

    var body: some View {
        MainTabView()
            .preferredColorScheme(theme.resolvedColorScheme)
            .fullScreenCover(isPresented: $showOnboarding) {
                NavigationStack {
                    WelcomeView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
                .preferredColorScheme(theme.resolvedColorScheme)
            }
            .whatsNewSheet(isPresented: $showWhatsNew)
            .alert("New: Live Rewind", isPresented: $showLiveRewindPrompt) {
                Button("Enable") {
                    liveRewindEnabled = true
                    liveRewindPromptSeen = true
                }
                Button("Not Now", role: .cancel) {
                    liveRewindPromptSeen = true
                }
            } message: {
                Text("Pause and rewind live TV. While you watch a channel fullscreen, AerioTV keeps a rolling buffer on this device so you can skip back, scrub the timeline, or pause and pick up where you left off.\n\nBuffered video is deleted automatically. You can change this anytime in Settings > App Behaviors > Live Rewind.")
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

                // Live Rewind one-time prompt: never stacked over
                // onboarding or What's New. If either modal claims this
                // launch, the next clean launch asks instead. Users who
                // already found the toggle are seeded silently.
                if !liveRewindPromptSeen {
                    if liveRewindEnabled {
                        liveRewindPromptSeen = true
                    } else {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            if !showOnboarding && !showWhatsNew && !liveRewindPromptSeen {
                                showLiveRewindPrompt = true
                            }
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
                //
                // Default Live TV View is now a PER-DEVICE preference. It used
                // to ride the synced key set, so an iPhone's "list" could
                // clobber the Apple TV's Guide default (the guide silently
                // opened in List after a sync). Clear the possibly-clobbered
                // value once so each device falls back to its form-factor
                // default going forward.
                clearLegacySyncedDefaultViewIfNeeded()
                migrateCredentialsToICloudKeychainIfNeeded()
                // v1.6.23: re-publish servers to iCloud KVS so the
                // payload includes credentials again. v1.6.12 stopped
                // emitting `_password` / `_apiKey` to KVS on the theory
                // that iCloud Keychain (kSecAttrSynchronizable) would
                // carry credentials cross-device. That assumption broke
                // for users who hadn't enabled iCloud Keychain on their
                // Apple TV / second device — the server config synced,
                // but every API call returned 401 (Freyguy1975 v1.6.22
                // report). v1.6.23's `serialize` re-includes the
                // credentials; this republish forces an immediate
                // overwrite of the legacy credential-stripped payload
                // sitting in KVS so existing multi-device users
                // immediately benefit.
                //
                // Function name kept for diff continuity but it now
                // republishes-with-credentials rather than purging-
                // credentials. The previous purge ran on a different
                // flag so this republish fires for both already-purged
                // installs and for upgrade installs that never ran the
                // v1.6.12 purge.
                republishServersWithCredentialsIfNeeded()
                // v1.6.20: silently auto-detect the Dispatcharr
                // auth header shape for any verified server still
                // missing one. Closes the v1.6.19→v1.6.20 upgrade
                // window where the back-compat `.both` fallback
                // could briefly resurface the v1.6.16 VOD-episodes-
                // empty bug until the user manually re-ran Test
                // Connection. No-op once every server has a
                // persisted shape (either from this discovery or
                // from iCloud sync).
                discoverDispatcharrAuthModeIfNeeded()
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
                    // v1.6.20: a sync delivery may have brought in
                    // a verified server from another device that
                    // never ran auth-mode discovery (e.g., that
                    // device was on v1.6.19 when the server was
                    // added). Run discovery again now that we
                    // have the merged set in the local store.
                    discoverDispatcharrAuthModeIfNeeded()
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
    ///     them. `effectivePassword`/`effectiveApiKey` prefer the
    ///     iCloud copy while credential sync is enabled, but fall
    ///     back to the local copy when sync is off.
    ///
    /// History: v1.6.12 stopped writing `_password` / `_apiKey` to KVS and
    ///   relied on iCloud Keychain (kSecAttrSynchronizable) to carry
    ///   credentials cross-device. That broke for users without iCloud
    ///   Keychain on a second device (commonly Apple TV), so v1.6.23 RESTORED
    ///   the KVS credential carry in `SyncManager.serialize` and added
    ///   `republishServersWithCredentialsIfNeeded` (below) to overwrite the
    ///   credential-stripped payload v1.6.12 left in KVS. This Keychain
    ///   migration still runs so iCloud Keychain stays populated where it IS
    ///   available; the KVS carry is the reliable fallback where it is not.
    ///   (There is no purge task; an earlier revision referenced a
    ///   `purgeKVSPlaintextCredentialsIfNeeded` that no longer exists.)
    /// One-time cleanup: `defaultLiveTVView` used to be in the synced key set,
    /// so a phone's "list" default could overwrite an Apple TV's "guide" (the
    /// guide would silently open in List after a sync). It is now a per-device
    /// @AppStorage value; clear the possibly-clobbered value exactly once so
    /// each device falls back to its form-factor default (Apple TV / iPad ->
    /// Guide, iPhone -> List). The user can re-pick per device and it stays local.
    private func clearLegacySyncedDefaultViewIfNeeded() {
        let flagKey = "defaultLiveTVViewUnsyncedClearedV1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.removeObject(forKey: "defaultLiveTVView")
        UserDefaults.standard.set(true, forKey: flagKey)
    }

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

    /// One-shot launch task that re-publishes servers to iCloud KVS
    /// so the payload includes credentials again on v1.6.23+.
    ///
    /// Background: pre-v1.6.12 clients pushed `_password` / `_apiKey`
    /// in the KVS per-server dict. v1.6.12 stopped emitting those keys
    /// on the theory that iCloud Keychain (kSecAttrSynchronizable)
    /// would carry credentials cross-device. That assumption broke for
    /// users who hadn't enabled iCloud Keychain on a second device
    /// (most common: Apple TV with iCloud Keychain disabled). The
    /// server metadata synced via KVS, the playlist rendered, every
    /// API call returned 401 — and there was no UX recovery short of
    /// re-typing the API key on every device. Field reports starting
    /// in v1.6.22 (Freyguy1975, multiple Apple TV deployments) made it
    /// clear the Keychain-only path is unreliable in practice.
    ///
    /// v1.6.23 restored the KVS credential carry in `serialize`. This
    /// task forces an immediate non-debounced push so the legacy
    /// credential-stripped payload that's been sitting in KVS since
    /// v1.6.12 gets overwritten with the v1.6.23 shape. After one
    /// successful run the `kvsCredentialRepublishDoneV1_6_23` flag
    /// prevents re-runs.
    ///
    /// Safe when iCloud Sync is disabled — we early-out, since with
    /// Sync off we never write to KVS. If the user later enables Sync,
    /// the next natural push (fired on the toggle) carries the new
    /// credential-bearing shape.
    private func republishServersWithCredentialsIfNeeded() {
        let flagKey = "kvsCredentialRepublishDoneV1_6_23"
        if UserDefaults.standard.bool(forKey: flagKey) { return }

        guard SyncManager.shared.isSyncEnabled else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }
        guard !servers.isEmpty else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        // Force a non-debounced push so the cloud KVS gets the new
        // credential-bearing payload immediately. `pushServers` calls
        // the v1.6.23 `serialize`, which re-emits `_password` /
        // `_apiKey` (gated on `SyncCategory.credentials.isEnabled`).
        SyncManager.shared.pushServers(servers, immediate: true)
        UserDefaults.standard.set(true, forKey: flagKey)
        DebugLogger.shared.log(
            "KVS credential republish: scheduled immediate push for \(servers.count) server(s)",
            category: "Sync", level: .info)
    }

    /// v1.6.20: Silent auto-discovery of the Dispatcharr auth header
    /// shape for any verified server whose `dispatcharrAuthMode` is
    /// still empty. Closes the v1.6.19→v1.6.20 upgrade window where
    /// users who installed v1.6.20 but didn't manually re-tap Test
    /// Connection were left with the back-compat default (`.both`),
    /// which could briefly resurface the v1.6.16 VOD-episodes-empty
    /// bug for some series before the user happened to test
    /// connection again.
    ///
    /// Behavior:
    ///  - Runs on every cold launch, but is a no-op for any server
    ///    whose `dispatcharrAuthMode` is already populated (either
    ///    from a manual Test Connection on this device or via
    ///    iCloud sync from another device that already discovered).
    ///  - Only runs against servers with `isVerified == true` so
    ///    we don't burn HTTP requests against a server the user
    ///    never successfully connected to in the first place.
    ///  - Detached background Task per server, with the result
    ///    written back on the main actor through a fresh fetch (no
    ///    main-thread blocking, no holding the ModelContext across
    ///    suspension points).
    ///  - Silent on failure: a transient network blip or a
    ///    temporarily-unreachable server leaves the field empty,
    ///    and the next launch retries.
    ///
    /// This is intentionally launch-only (not foreground/network-
    /// reachability triggered). Once the flag is populated, it
    /// sticks across launches and across iCloud sync, so a single
    /// successful discovery on any device on the user's Apple ID
    /// permanently fixes the upgrade window for every device.
    private func discoverDispatcharrAuthModeIfNeeded() {
        let candidates = servers.filter {
            $0.type == .dispatcharrAPI
                && $0.isVerified
                && $0.dispatcharrAuthMode.isEmpty
        }
        guard !candidates.isEmpty else { return }

        DebugLogger.shared.log(
            "Auth-mode auto-discovery: \(candidates.count) Dispatcharr server(s) need a header-shape probe",
            category: "Sync", level: .info)

        // Snapshot per-server inputs on the main actor so the
        // detached Task never touches the SwiftData model.
        struct Probe: Sendable {
            let id: UUID
            let baseURL: String
            let apiKey: String
            let userAgent: String
        }
        let probes: [Probe] = candidates.map {
            Probe(id: $0.id,
                  baseURL: $0.effectiveBaseURL,
                  apiKey: $0.effectiveApiKey,
                  userAgent: $0.effectiveUserAgent)
        }
        let container = modelContext.container

        Task.detached(priority: .utility) {
            for probe in probes {
                // Default `.xapikey` start point. verifyConnection
                // auto-falls-back to `.both` and `.bearer` on HTTP
                // 401 and returns whichever shape worked.
                let api = DispatcharrAPI(baseURL: probe.baseURL,
                                         auth: .apiKey(probe.apiKey),
                                         userAgent: probe.userAgent,
                                         authMode: .xapikey)
                do {
                    let info = try await api.verifyConnection()
                    guard let mode = info.discoveredAuthMode else {
                        debugLog("Auth-mode auto-discovery: \(probe.baseURL) verified but no mode reported (legacy code path)")
                        continue
                    }
                    // Persist on the main actor through a fresh
                    // ModelContext fetch. Capturing the SwiftData
                    // model into the detached Task is unsafe.
                    await MainActor.run {
                        // Fresh main-actor context off the same
                        // shared container. Lets us safely fetch
                        // and write without holding a model
                        // reference across the await suspension.
                        let context = ModelContext(container)
                        let id = probe.id
                        let descriptor = FetchDescriptor<ServerConnection>(
                            predicate: #Predicate<ServerConnection> { $0.id == id }
                        )
                        guard let server = try? context.fetch(descriptor).first else {
                            debugLog("Auth-mode auto-discovery: server \(probe.id) not found at write time (deleted?)")
                            return
                        }
                        // Re-check the empty guard. If the user
                        // tapped Test Connection manually while
                        // we were probing, or another device's
                        // sync landed first, don't overwrite.
                        guard server.dispatcharrAuthMode.isEmpty else {
                            debugLog("Auth-mode auto-discovery: server \(probe.id) already has mode \"\(server.dispatcharrAuthMode)\", skipping write")
                            return
                        }
                        server.dispatcharrAuthMode = mode.rawValue
                        try? context.save()
                        DebugLogger.shared.log(
                            "Auth-mode auto-discovery: \(probe.baseURL) → .\(mode.rawValue) (persisted)",
                            category: "Sync", level: .info)
                        // Push so other devices on the same iCloud
                        // account inherit immediately. Re-fetch the
                        // full set so the push payload includes
                        // every server, not just the one we just
                        // mutated.
                        let allServers = (try? context.fetch(FetchDescriptor<ServerConnection>())) ?? []
                        SyncManager.shared.pushServers(allServers, immediate: true)
                    }
                } catch {
                    DebugLogger.shared.log(
                        "Auth-mode auto-discovery: \(probe.baseURL) failed (\(error.localizedDescription)), will retry next launch",
                        category: "Sync", level: .warning)
                }
            }
        }
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
                    // v1.7: adopt remote's credential type. Empty
                    // remote value (legacy v1.6.x sender) leaves the
                    // local field alone — for an existing API-key
                    // server that's exactly right, since the local
                    // raw is also "" and resolves to .apiKey.
                    if !remote.dispatcharrCredentialTypeRaw.isEmpty {
                        local.dispatcharrCredentialTypeRaw = remote.dispatcharrCredentialTypeRaw
                    }
                    // v1.7.x: adopt the connected user's permission tier
                    // so the server-side Record / DVR affordances gate
                    // consistently across devices. deserialize defaults
                    // an absent value to 10 (admin), so a legacy sender
                    // (no key) or an admin server leaves the local field
                    // at the recording-capable default; only a positively
                    // synced sub-10 value restricts.
                    local.dispatcharrUserLevel = remote.dispatcharrUserLevel
                    // v1.7.x: adopt the connected user's assigned Channel
                    // Profile id(s) so the child-safety channel filter is
                    // consistent across devices. deserialize defaults an
                    // absent value to "" (no profile = show all), so a
                    // legacy sender (no key) or an unrestricted server
                    // leaves the local field unfiltered; only a positively
                    // synced non-empty value applies the filter.
                    local.dispatcharrChannelProfileIDs = remote.dispatcharrChannelProfileIDs
                    // Task #189: adopt the user-chosen Channel Profile so
                    // the synced lineup matches across devices.
                    local.dispatcharrSelectedProfileID = remote.dispatcharrSelectedProfileID
                    // Catch-up: adopt the remote guide-history retention
                    // so the replay window matches across devices.
                    local.epgRetentionDays = remote.epgRetentionDays
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
                // v1.7: inherit the credential type so a server set
                // up via Direct Connect on the source device also
                // logs in via Direct Connect on this device. Empty
                // remote value falls through to "" which resolves to
                // `.apiKey` (the legacy default).
                newServer.dispatcharrCredentialTypeRaw = remote.dispatcharrCredentialTypeRaw
                // v1.7.x: inherit the connected user's permission tier so
                // the server-side Record / DVR affordances gate the same
                // way on this device. Absent in the payload defaults to
                // 10 (admin = recording-capable) via deserialize.
                newServer.dispatcharrUserLevel = remote.dispatcharrUserLevel
                // v1.7.x: inherit the connected user's assigned Channel
                // Profile id(s) so the child-safety channel filter applies
                // the same way on this device. Absent in the payload
                // defaults to "" (no profile = show all) via deserialize.
                newServer.dispatcharrChannelProfileIDs = remote.dispatcharrChannelProfileIDs
                // Task #189: inherit the user-chosen Channel Profile.
                newServer.dispatcharrSelectedProfileID = remote.dispatcharrSelectedProfileID
                // Catch-up: inherit the guide-history retention setting.
                newServer.epgRetentionDays = remote.epgRetentionDays
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

        // Check for servers deleted on other devices.
        //
        // v1.7.x defense-in-depth fix paired with `SyncManager.pushServers`'s
        // schedule-time `lastPushTime` stamp: a freshly-added local server
        // (still inside the 2-second push debounce window OR with a stale
        // bounce-back-guard timestamp that let a foreign KVS notification
        // through) must NOT be deleted just because the in-flight remote
        // payload pre-dates this device's push. The user's intent is
        // "I just added this server", and there is no scenario where a server
        // created in the last few seconds was legitimately "deleted on
        // another device" because the cross-device propagation alone
        // takes longer than the freshness threshold. Skipping the delete
        // gives `pushServers`' debounced work a chance to catch up and
        // write the new server to KVS, after which subsequent merges
        // see a consistent state.
        //
        // Threshold: 10 seconds. Comfortably longer than the 2.0s push
        // debounce, the typical end-to-end iCloud KVS propagation
        // latency (sub-second on Apple's backbone in practice but can
        // spike to a few seconds under congestion), and any reasonable
        // multi-step Add Server flow's tail (saveCredentialsSynced runs
        // on the next run loop, but the user might have tapped Save and
        // had the modal dismiss animation in flight). Short enough that
        // a server legitimately deleted on another device WHILE this
        // device was offline still gets cleaned up on the next sync.
        // The createdAt is preserved from the original insert, so the
        // 10s window is measured from when the server was first added,
        // not from when this merge runs.
        let remoteIDs = Set(remoteServers.map { $0.id })
        let now = Date()
        for local in servers where !remoteIDs.contains(local.id) {
            // Only delete if sync has been active (i.e., remote has servers but this one is missing)
            if !remoteServers.isEmpty {
                let ageSeconds = now.timeIntervalSince(local.createdAt)
                if ageSeconds < 10 {
                    // v1.7.x: caught a near-miss. The race we're guarding
                    // against (FINDING 1 in the v1.7.0 multi-server-add
                    // bug investigation): a foreign KVS notification fires
                    // during the local push debounce, the bounce-back
                    // guard fails because lastPushTime is stale, and we
                    // arrive here with a JUST-ADDED local server about
                    // to be wrongly deleted. File-backed log so users
                    // who hit this can ship us a forensic trail.
                    DebugLogger.shared.log(
                        "SyncManager: SKIPPED delete of server \(local.name) (too young: \(String(format: "%.1f", ageSeconds))s old, threshold 10s, remoteCount=\(remoteServers.count)). Race-guard prevented data loss; the push debounce will catch up.",
                        category: "Sync",
                        level: .warning
                    )
                    continue
                }
                local.deleteCredentialsFromKeychain()
                modelContext.delete(local)
                DebugLogger.shared.log(
                    "SyncManager: deleted server \(local.name) (removed on another device, age=\(String(format: "%.1f", ageSeconds))s, remoteCount=\(remoteServers.count))",
                    category: "Sync",
                    level: .info
                )
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
        // `effectivePassword` / `effectiveApiKey` already resolve the
        // right copy for the current sync mode, so the dual write is
        // invisible to readers. v1.6.7 devices keep working because we still
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
