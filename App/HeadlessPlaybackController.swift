#if os(iOS)
import Foundation
import Combine
import Libmpv
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Counts the live `MPVPlayerView.Coordinator` instances that are actually
/// mounted and decoding. The headless CarPlay engine must never run at the
/// same time as a view-mounted engine (double audio), so it consults this
/// before starting and yields to a coordinator the instant one mounts.
@MainActor
final class PlaybackEngineRegistry {
    static let shared = PlaybackEngineRegistry()
    private init() {}

    private(set) var liveCoordinatorCount = 0

    /// A SwiftUI player representable is mounting its coordinator. Called from
    /// `makeUIViewController` on the main actor, BEFORE the coordinator's
    /// `renderQueue` reaches `loadfile`, so the headless engine can be
    /// silenced first with no overlap.
    func coordinatorWillMount() {
        liveCoordinatorCount += 1
    }

    /// A coordinator finished tearing down (paired with `coordinatorWillMount`).
    func coordinatorDidUnmount() {
        liveCoordinatorCount = max(0, liveCoordinatorCount - 1)
    }

    var hasLiveCoordinator: Bool { liveCoordinatorCount > 0 }
}

/// Plays a live channel's AUDIO with no SwiftUI player view mounted.
///
/// The full player (mpv/AVPlayer engine + `AVAudioSession` activation +
/// `NowPlayingBridge`) lives inside the `MPVPlayerView` SwiftUI representable,
/// which only instantiates when a foreground `UIWindowScene` renders it. In a
/// car the phone is typically locked / the app is not foregrounded (or the app
/// was cold-launched purely to service the CarPlay scene), so nothing mounts
/// and a CarPlay channel tap produced no audio. This controller closes that
/// gap: it drives a headless audio-only mpv instance directly from
/// `CarPlaySceneDelegate.playChannel`, activates the audio session durably, and
/// publishes complete Now Playing metadata — with a clean handoff to/from the
/// view engine so only one of them ever decodes audio.
@MainActor
final class HeadlessPlaybackController {
    static let shared = HeadlessPlaybackController()

    private var engine: HeadlessMPVAudioEngine?
    private var currentItemID: String?
    private var isPaused = false
    /// Advances the Now Playing program timeline while headless (there is no
    /// perf pump calling `updateElapsed` when no coordinator is mounted).
    private var elapsedTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Re-tune when the active channel changes (CarPlay next/previous track,
        // or a re-tap in the list) WHILE we own the engine. The gate inside
        // `start` keeps this inert on the foreground path.
        NowPlayingManager.shared.$playingItem
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                // Delivered on the main run loop (== MainActor executor).
                MainActor.assumeIsolated {
                    guard let self, self.engine != nil, let item else { return }
                    if item.id != self.currentItemID {
                        self.start(item: item, server: ChannelStore.shared.activeServer, isLive: true)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// True when a foreground `UIWindowScene` exists — i.e. the phone app is on
    /// screen, so the SwiftUI player will mount and own playback. Mirrors the
    /// scene lookup in `AerioApp`.
    static func hasForegroundPlayerScene() -> Bool {
        UIApplication.shared.connectedScenes
            .contains { ($0 as? UIWindowScene)?.activationState == .foregroundActive }
    }

    /// Start (or re-tune to) a channel headlessly. No-op unless we're in the
    /// cold-car state: CarPlay connected, no foreground scene, and no mounted
    /// coordinator — so this never fights the view engine or spawns a second
    /// audio producer.
    func start(item: ChannelDisplayItem, server: ServerConnection?, isLive: Bool) {
        guard NowPlayingManager.shared.isCarPlayConnected,
              !Self.hasForegroundPlayerScene(),
              !PlaybackEngineRegistry.shared.hasLiveCoordinator
        else { return }

        // Already playing this channel — nothing to do (idempotent for the
        // playChannel + $playingItem observer both firing).
        if engine != nil, currentItemID == item.id { return }

        let resolved = PlayerSession.resolveEngine(item: item, server: server, isLive: isLive)
        NSLog("[CarPlay-Headless] start channel=\(item.name) engine=mpv url_scheme=\(resolved.routeURL.scheme ?? "?")")

        let firstStart = (engine == nil)
        if firstStart {
            AudioSessionRefCount.increment(caller: "carplay-headless")
        }

        // Reuse the mpv instance across channel flips (loadfile replace) to
        // avoid audio-session bounce; create it on the first start.
        let eng = engine ?? HeadlessMPVAudioEngine()
        engine = eng
        currentItemID = item.id
        isPaused = false
        eng.play(url: resolved.routeURL, headers: resolved.headers)

        // Complete Now Playing: title / program subtitle / channel logo /
        // program-relative timeline, plus play-pause + next/prev commands.
        NowPlayingBridge.shared.configure(
            for: item,
            isLive: isLive,
            onPlay: { [weak self] in self?.setPaused(false) },
            onPause: { [weak self] in self?.setPaused(true) },
            onSeek: nil
        )
        startElapsedTimer()
    }

    /// A SwiftUI player view is taking over (phone foregrounded / unlocked).
    /// Stop the headless engine but DON'T tear down Now Playing — the mounting
    /// coordinator re-arms the bridge itself, so the lock-screen/CarPlay chrome
    /// never flickers.
    func yieldToViewEngine() {
        guard engine != nil else { return }
        NSLog("[CarPlay-Headless] yield to view engine")
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        engine?.stop()
        engine = nil
        currentItemID = nil
        AudioSessionRefCount.decrement(caller: "carplay-headless")
    }

    /// Full teardown (CarPlay disconnect, or a global stop/exit). Clears Now
    /// Playing only if we still own the engine.
    func stop() {
        guard engine != nil else { return }
        NSLog("[CarPlay-Headless] stop")
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        engine?.stop()
        engine = nil
        currentItemID = nil
        AudioSessionRefCount.decrement(caller: "carplay-headless")
        NowPlayingBridge.shared.teardown()
    }

    private func setPaused(_ paused: Bool) {
        guard let engine else { return }
        isPaused = paused
        engine.setPaused(paused)
        NowPlayingBridge.shared.updateElapsed(0, rate: paused ? 0.0 : 1.0)
    }

    /// Tick the program timeline forward (~5s) so CarPlay's progress bar
    /// advances and the pause state stays fresh. The bridge recomputes the
    /// program-relative elapsed itself for live, so the passed time is ignored.
    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine != nil else { return }
                NowPlayingBridge.shared.updateElapsed(0, rate: self.isPaused ? 0.0 : 1.0)
            }
        }
        elapsedTimer = timer
    }
}

/// Minimal audio-only libmpv instance for headless CarPlay playback. Mirrors
/// the pre-init subset of `MPVPlayerView.Coordinator.setupMPV` that matters for
/// audio: `vo=libmpv`, `profile=fast`, `vid=no` (no video pipeline, no GL
/// surface required — the same flag that lets audio play in the iOS Simulator),
/// HTTP UA/headers, then `loadfile`. All handle access is serialised on one
/// private queue; `@unchecked Sendable` because that queue — not the type
/// system — provides the isolation for the C handle.
final class HeadlessMPVAudioEngine: @unchecked Sendable {
    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "app.molinete.aerio.headless.mpv")

    func play(url: URL, headers: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.mpv == nil {
                self.setup(headers: headers)
            }
            guard let mpv = self.mpv else { return }
            self.command(mpv, ["loadfile", url.absoluteString, "replace"])
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let mpv = self?.mpv else { return }
            mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            self.mpv = nil
            mpv_terminate_destroy(mpv)
        }
    }

    private func setup(headers: [String: String]) {
        // Close the same first-load registration race the coordinator guards
        // against (loadfile before libmpv's global codec/protocol init).
        MPVLibraryWarmup.waitUntilComplete()

        guard let handle = mpv_create() else {
            NSLog("[CarPlay-Headless] mpv_create failed")
            return
        }
        mpv_set_option_string(handle, "vo", "libmpv")
        mpv_set_option_string(handle, "profile", "fast")
        // Audio-only: never bring up the video pipeline (no view/GL surface).
        mpv_set_option_string(handle, "vid", "no")
        #if targetEnvironment(simulator)
        mpv_set_option_string(handle, "hwdec", "no")
        #else
        mpv_set_option_string(handle, "hwdec", "videotoolbox-copy")
        #endif
        if let ua = headers["User-Agent"], !ua.isEmpty {
            mpv_set_option_string(handle, "user-agent", ua)
        }
        let custom = headers.filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
        if !custom.isEmpty {
            let list = custom.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            mpv_set_option_string(handle, "http-header-fields", list)
        }
        let initResult = mpv_initialize(handle)
        if initResult < 0 {
            NSLog("[CarPlay-Headless] mpv_initialize failed: \(String(cString: mpv_error_string(initResult)))")
            mpv_terminate_destroy(handle)
            return
        }
        mpv = handle
        NSLog("[CarPlay-Headless] mpv initialized (audio-only)")
    }

    /// Same C-string bridging as `MPVPlayerView.Coordinator.mpvCommand`.
    private func command(_ mpv: OpaquePointer, _ args: [String]) {
        let cargs = args.map { strdup($0) }
        var pointers = cargs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        pointers.append(nil)
        mpv_command(mpv, &pointers)
        for ptr in cargs { free(ptr) }
    }
}
#endif
