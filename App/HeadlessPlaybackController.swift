#if os(iOS)
import Foundation
import AVFoundation
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

    /// The active engine. A two-case enum instead of a shared protocol ON
    /// PURPOSE: a @MainActor protocol conformance infers main-actor isolation
    /// onto the conforming class, which planted a runtime isolation assert
    /// inside HeadlessMPVAudioEngine's private-queue setup path and crashed
    /// the app on every CarPlay channel tap (EXC_BREAKPOINT in
    /// dispatch_assert_queue, found 2026-08-08 in the CarPlay Simulator).
    private enum Engine {
        case mpv(HeadlessMPVAudioEngine)
        case avPlayer(HeadlessAVPlayerEngine)

        @MainActor func play(url: URL, headers: [String: String]) {
            switch self {
            case .mpv(let e): e.play(url: url, headers: headers)
            case .avPlayer(let e): e.play(url: url, headers: headers)
            }
        }
        @MainActor func setPaused(_ paused: Bool) {
            switch self {
            case .mpv(let e): e.setPaused(paused)
            case .avPlayer(let e): e.setPaused(paused)
            }
        }
        @MainActor func stop() {
            switch self {
            case .mpv(let e): e.stop()
            case .avPlayer(let e): e.stop()
            }
        }
        var isAVPlayer: Bool {
            if case .avPlayer = self { return true }
            return false
        }
    }

    private var engine: Engine?
    private var currentItemID: String?
    private var isPaused = false
    /// Whether the connected car session can present video (CarPlay video
    /// entitlement + car support, iOS 26.4+). Set per-start by the scene
    /// delegate; remembered so the $playingItem re-tune observer keeps the
    /// same engine choice across channel flips.
    private var videoCapable = false
    /// The last engine resolution, kept for the AVPlayer-failure fallback.
    private var lastResolved: ResolvedEngine?
    /// Tracks the audio-session refcount we own, decoupled from `engine`
    /// existence because a mid-session engine swap (mpv <-> AVPlayer)
    /// destroys and recreates `engine` without releasing the session.
    private var ownsAudioSession = false
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
                        self.start(item: item, server: ChannelStore.shared.activeServer,
                                   isLive: true, videoCapable: self.videoCapable)
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
    func start(item: ChannelDisplayItem, server: ServerConnection?, isLive: Bool,
               videoCapable: Bool = false) {
        guard NowPlayingManager.shared.isCarPlayConnected,
              !Self.hasForegroundPlayerScene(),
              !PlaybackEngineRegistry.shared.hasLiveCoordinator
        else {
            debugLog("[CarPlay-Headless] no-op for \(item.name): carplay=\(NowPlayingManager.shared.isCarPlayConnected) fgScene=\(Self.hasForegroundPlayerScene()) liveCoordinators=\(PlaybackEngineRegistry.shared.liveCoordinatorCount) (view engine owns playback)")
            return
        }

        // Already playing this channel — nothing to do (idempotent for the
        // playChannel + $playingItem observer both firing).
        if engine != nil, currentItemID == item.id { return }

        self.videoCapable = videoCapable
        let resolved = PlayerSession.resolveEngine(item: item, server: server, isLive: isLive)
        lastResolved = resolved
        // Host logged (never the full URL - stream URLs can carry query
        // credentials): the cold-car failure mode to catch is a LAN host
        // being handed to a cellular-only phone.
        debugLog("[CarPlay-Headless] start channel=\(item.name) scheme=\(resolved.routeURL.scheme ?? "?") host=\(resolved.routeURL.host ?? "?")")

        // CarPlay video: a video-capable car session + a direct-HLS stream
        // plays through a headless AVPlayer with external playback enabled,
        // so the car can present the video (CarPlay video rides the AirPlay
        // video path, which mpv cannot feed). Everything else — audio-only
        // sessions, non-HLS streams — stays on the proven mpv audio engine.
        // The remux engine is deliberately excluded: its loopback server
        // suspends when the app backgrounds, which is the norm in a car.
        let wantsAVPlayer = videoCapable && resolved.engine == .avPlayerDirectHLS
        if let current = engine, current.isAVPlayer != wantsAVPlayer {
            current.stop()
            engine = nil
        }
        if !ownsAudioSession {
            AudioSessionRefCount.increment(caller: "carplay-headless")
            ownsAudioSession = true
        }

        // Reuse the engine instance across channel flips to avoid
        // audio-session bounce; create it on the first start.
        let eng: Engine
        if let existing = engine {
            eng = existing
        } else if wantsAVPlayer {
            let av = HeadlessAVPlayerEngine()
            av.onPlaybackFailure = { [weak self] message in
                Task { @MainActor in self?.handleAVPlayerFailure(message) }
            }
            debugLog("[CarPlay-Headless] engine=AVPlayer (video-capable car, direct HLS)")
            eng = .avPlayer(av)
        } else {
            eng = .mpv(HeadlessMPVAudioEngine())
        }
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
        if ownsAudioSession {
            ownsAudioSession = false
            AudioSessionRefCount.decrement(caller: "carplay-headless")
        }
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
        if ownsAudioSession {
            ownsAudioSession = false
            AudioSessionRefCount.decrement(caller: "carplay-headless")
        }
        NowPlayingBridge.shared.teardown()
    }

    /// The headless AVPlayer hit a hard failure (asset refused, item errored).
    /// Fall back to the mpv audio engine on the same resolved URL so the car
    /// session degrades to audio instead of dead air. One-way for the current
    /// channel; the next channel flip re-evaluates video eligibility.
    private func handleAVPlayerFailure(_ message: String) {
        guard let current = engine, current.isAVPlayer, let resolved = lastResolved else { return }
        debugLog("[CarPlay-Headless] AVPlayer failed (\(message)); falling back to mpv audio")
        current.stop()
        let eng = Engine.mpv(HeadlessMPVAudioEngine())
        engine = eng
        eng.play(url: resolved.routeURL, headers: resolved.headers)
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
    /// The URL of the current load, for the one-shot retry below.
    private var currentURL: URL?
    /// One retry per loadfile: a live TS drop mid-drive (tunnel, cell
    /// handoff) used to end the file SILENTLY - this engine had no event
    /// loop at all, so a failed or ended stream just sat there as dead air
    /// with Now Playing still up (Logan's real-car report 2026-08-07).
    private var retriedCurrentLoad = false

    func play(url: URL, headers: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.mpv == nil {
                self.setup(headers: headers)
            }
            guard let mpv = self.mpv else { return }
            self.currentURL = url
            self.retriedCurrentLoad = false
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
            self.currentURL = nil
            // Detach the wakeup callback BEFORE destroy: it holds an
            // unretained self, and the engine can deallocate right after
            // this block while a late wakeup is still in flight.
            mpv_set_wakeup_callback(mpv, nil, nil)
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
            debugLog("[CarPlay-Headless] mpv_initialize failed: \(String(cString: mpv_error_string(initResult)))")
            mpv_terminate_destroy(handle)
            return
        }
        mpv = handle
        // Minimal event drain: without it this engine was fire-and-forget -
        // no state, no errors, no end-of-file ever surfaced. The wakeup
        // callback pings our serial queue, where we drain events, log the
        // lifecycle, and give a dead live stream ONE reload before going
        // quiet (the CarPlay UI has no error surface; dead air + a log line
        // beats an invisible crash-loop of retries).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let engine = Unmanaged<HeadlessMPVAudioEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.queue.async { engine.drainEvents() }
        }, selfPtr)
        debugLog("[CarPlay-Headless] mpv initialized (audio-only)")
    }

    /// Runs on `queue`. Drains pending mpv events; logs lifecycle + errors.
    private func drainEvents() {
        guard let mpv else { return }
        while true {
            guard let evPtr = mpv_wait_event(mpv, 0) else { return }
            let ev = evPtr.pointee
            switch ev.event_id {
            case MPV_EVENT_NONE:
                return
            case MPV_EVENT_FILE_LOADED:
                debugLog("[CarPlay-Headless] stream loaded, audio starting")
                retriedCurrentLoad = false
            case MPV_EVENT_END_FILE:
                let end = ev.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                let isError = end.reason == MPV_END_FILE_REASON_ERROR
                let reason = isError
                    ? String(cString: mpv_error_string(end.error))
                    : "reason=\(end.reason.rawValue)"
                debugLog("[CarPlay-Headless] end-file: \(reason)")
                // Only self-heal genuine stream ends/errors; reason STOP (our
                // own loadfile replace / teardown) must not retrigger.
                if (isError || end.reason == MPV_END_FILE_REASON_EOF),
                   let url = currentURL, !retriedCurrentLoad {
                    retriedCurrentLoad = true
                    debugLog("[CarPlay-Headless] one-shot reload after dead stream")
                    queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, let mpv = self.mpv, self.currentURL == url else { return }
                        self.command(mpv, ["loadfile", url.absoluteString, "replace"])
                    }
                }
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
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

/// Headless AVPlayer engine for CarPlay VIDEO sessions. CarPlay presents app
/// video via the AirPlay video path, which only AVPlayer can feed:
/// `allowsExternalPlayback` lets the car take the video surface while the
/// phone stays locked. No layer is attached on the phone — external playback
/// needs none, and when the car declines video (driving) the same player
/// keeps supplying audio, which is exactly the fallback CarPlay specifies.
/// Only ever fed direct-HLS URLs (`.avPlayerDirectHLS`), the same
/// device-verified path the in-app AVPlayer engine defaults to.
@MainActor
final class HeadlessAVPlayerEngine {
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var externalObservation: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    /// Hard failure hook (asset refused / item errored) so the controller can
    /// drop to the mpv audio engine instead of leaving dead air.
    var onPlaybackFailure: ((String) -> Void)?

    func play(url: URL, headers: [String: String]) {
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers
        ])
        let item = AVPlayerItem(asset: asset)
        observeFailures(of: item)

        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let p = AVPlayer(playerItem: item)
            p.allowsExternalPlayback = true
            p.usesExternalPlaybackWhileExternalScreenIsActive = true
            externalObservation = p.observe(\.isExternalPlaybackActive, options: [.new]) { _, change in
                // The single log line that proves the car actually took the
                // video surface (vs quietly staying audio-only).
                debugLog("[CarPlay-Headless] externalPlaybackActive=\(change.newValue ?? false)")
            }
            player = p
        }
        player?.play()
    }

    func setPaused(_ paused: Bool) {
        paused ? player?.pause() : player?.play()
    }

    func stop() {
        statusObservation = nil
        externalObservation = nil
        if let obs = failedToEndObserver {
            NotificationCenter.default.removeObserver(obs)
            failedToEndObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func observeFailures(of item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "unknown item error"
            Task { @MainActor in self?.onPlaybackFailure?(message) }
        }
        if let obs = failedToEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] note in
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "failed to play to end"
            Task { @MainActor in self?.onPlaybackFailure?(err) }
        }
    }
}
#endif
