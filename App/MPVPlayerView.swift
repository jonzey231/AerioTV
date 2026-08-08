#if canImport(Libmpv)
import SwiftUI
// Xcode 26.5 / SDK 26.5 newly annotates AVSampleBufferDisplayLayer (a CALayer
// subclass) as @MainActor, which would otherwise reject the long-standing
// render-thread accesses to `.sampleBufferRenderer`. @preconcurrency restores
// the pre-26.5 contract (the enqueue path is serialized and correct as-is)
// by downgrading those isolation diagnostics to warnings.
@preconcurrency import AVFoundation
import AVKit
import Combine
import UIKit
import Libmpv
import CoreVideo
import CoreMedia  // For CMSampleBuffer
import OpenGLES

/// Tiny thread-safe latch for the Switch Stream re-sync keepalive: the
/// keepalive task flips it once its connection receives a first byte (i.e. the
/// server registered it as a client), and the reload waits on it before
/// re-loading the player's own connection.
private actor ReprimeKeepaliveGate {
    private(set) var isConnected = false
    func markConnected() { isConnected = true }
}

// MARK: - libmpv global init warm-up
//
// Observation from `[MV-TIMING]` logs on Apple TV 4K (3rd gen):
//
//   tile=155      setup_ms=2267   ← first mpv instance in the process
//   tile=91E248E9 setup_ms=16     ← second
//   tile=304D83DA setup_ms=9
//   tile=920687C5 setup_ms=16     ← every subsequent one ≤20 ms
//
// The 2.2 s cost on the first `mpv_create + mpv_initialize` pair is
// libmpv's process-wide one-time init: ffmpeg codec table
// registration, filter chain setup, stream protocol registration,
// libass font resolver bootstrap, etc. The 17th mpv instance is
// cheap; the 1st is expensive.
//
// `MPVLibraryWarmup.warmUp()` creates and immediately destroys one
// mpv handle on a background queue during app launch. The handle
// does nothing visible — no window, no file loaded — but the
// `mpv_initialize` call triggers all the one-time process-wide
// init. By the time the user's first tap hits `Coordinator.setupMPV`,
// the cheap fast-path is already active and `mpv_initialize`
// returns in ~5–20 ms.
//
// Idempotent, fire-and-forget. If the user's first tap races the
// warm-up, the tap proceeds on its own (pays full 2 s) and the
// warm-up's `mpv_terminate_destroy` lands harmlessly on its own
// instance.
enum MPVLibraryWarmup {
    /// `nonisolated(unsafe)` because the flag is only flipped once
    /// (false → true) and the check is a benign race — worst case,
    /// two warm-ups run concurrently and one wastes a few ms of CPU.
    private nonisolated(unsafe) static var hasStarted = false
    private nonisolated(unsafe) static var isComplete = false

    /// Trigger libmpv process-wide init on a background queue.
    /// Safe to call from any thread, as many times as you want —
    /// only the first call does anything.
    ///
    /// v1.7.x Phase 5: deferred and de-prioritized to reduce
    /// cold-launch main-thread contention. Pre-v1.7.x the warmup
    /// fired immediately on `RootView.onAppear` at
    /// `.userInitiated` priority. The phase-2 EAGL block (~2.4s
    /// on iPhone 17 Pro Max) competed with SwiftUI's first paint
    /// for the GPU driver mutex, surfacing as a ~1.6s ping#2
    /// watchdog hang while the system spent its launch budget
    /// on EAGLContext setup instead of getting the channel list
    /// on screen. Two changes here:
    ///
    ///   1. **800ms deferred start.** SwiftUI's first paint and
    ///      the initial SwiftData fetches both complete inside
    ///      ~500-800ms on real hardware. Starting the warmup
    ///      after that window means main has the GPU to itself
    ///      during the visible launch sequence.
    ///   2. **`.utility` priority** (was `.userInitiated`). Lower
    ///      CPU priority so any later main-thread work that fires
    ///      during the warmup (channel fetch JSON decode, etc.)
    ///      pre-empts the warmup instead of waiting behind it.
    ///
    /// Net cost: warmup completes ~800ms later (e.g. 3.2s instead
    /// of 2.4s on iPhone 17 Pro Max). Net benefit: the visible
    /// "channel list loading" sequence is no longer a juddery
    /// 1.5s hang. First-channel-tap fast path is preserved
    /// because `waitUntilComplete(timeout: 5.0)` still
    /// synchronizes Coordinator.setupMPV to the warmup, and the
    /// user can't tap a channel within 800ms of cold launch
    /// anyway (channel list isn't even rendered yet).
    static func warmUp() {
        guard !hasStarted else { return }
        hasStarted = true

        // v1.7.x: the warmup is SPLIT into two independently-scheduled phases
        // because they have opposite scheduling needs.
        //
        // Phase 1 (libmpv registration, doWarmUpMPV) takes NO GPU lock and is
        // the ONLY thing the first-tile decoder-race gate (waitUntilComplete)
        // needs, so it runs early (0.3s) on the low-priority utility queue: it
        // cannot preempt the main thread's launch UI (higher QoS), and getting
        // it done well before the splash clears means an early first tap still
        // hits the warm mpv path.
        //
        // Phase 2 (the throwaway EAGLContext GPU pre-warm, doWarmUpEAGL) takes a
        // process-wide GPU driver lock for ~1-2s. When both phases shared one
        // 2.5s defer, on the heavier multi-server startup that lock still landed
        // on top of the channel-list first paint + the cold-start EPG publishes,
        // stalling the main thread (the ~2s launch hang). Deferring it alone to
        // 6.0s lets first paint + the initial publishes drain before the GPU
        // allocation. isComplete flips after Phase 1 ONLY (never gated on EAGL),
        // so a rare tap-before-EAGL just pays the one-time cold EAGLContext cost
        // in the first setupMPV; playback is still correct. Both defers are safe
        // on an empty/no-source install (fixed timers, unlike a readiness gate).
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + 0.3) {
                doWarmUpMPV()
            }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + 6.0) {
                doWarmUpEAGL()
            }
    }

    /// `true` once the background warm-up has completed. Diagnostics
    /// only — most callers never need to read this directly.
    static var completed: Bool { isComplete }

    /// Synchronously wait up to `timeout` seconds for the warm-up to
    /// finish. Spin-polls `isComplete` with 50ms sleeps so the call
    /// is safe from any non-main background queue (specifically the
    /// per-Coordinator `renderQueue`). Returns `true` if the warm-up
    /// completed within `timeout`, `false` if we timed out (in which
    /// case the caller should proceed anyway and accept the cold-
    /// path cost / decoder-error risk).
    ///
    /// Why this exists: v1.6.12 fix for the **multiview first-tile
    /// decoder error**. Pre-v1.6.12, `Coordinator.start()` ran
    /// `setupMPV()` → `loadfile` immediately on `renderQueue`, with
    /// no synchronization to `MPVLibraryWarmup`. The first multiview
    /// tile mounted within ~3 s of app launch would race the
    /// background warm-up's process-wide ffmpeg / codec / protocol
    /// registration — `mpv_initialize` returned success on the
    /// tile's own handle, but `loadfile` arrived before the global
    /// registration finished and the load failed with
    /// `MPV_ERROR_LOADING_FAILED` (-13). Subsequent tiles ran after
    /// the warm-up completed and worked fine. Gating `setupMPV()`
    /// on this wait closes the race; the timeout is generous (5 s)
    /// because the worst-observed warm-up is ~2.2 s on cold device
    /// hardware.
    @discardableResult
    static func waitUntilComplete(timeout: TimeInterval = 5.0) -> Bool {
        // Fast path — already done.
        if isComplete { return true }
        // Defensive: if `warmUp()` was somehow never called (shouldn't
        // happen — `RootView.onAppear` triggers it), kick it now so
        // the wait isn't pointless. Idempotent.
        warmUp()
        let deadline = Date().addingTimeInterval(timeout)
        while !isComplete && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return isComplete
    }

    private static func doWarmUpMPV() {
        // v1.6.15: capture thermal at Phase-1 entry so a later stutter report
        // can tell whether the device was already hot at launch (Resume Last
        // Channel + warmup both compete for the same CPU/GPU budget near launch).
        let thermalAtStart = thermalStateString(ProcessInfo.processInfo.thermalState)

        // Phase 1: libmpv process-wide registration (videotoolbox hwdec, vo
        // init, fast-profile filter chain). This is the ONLY thing the
        // first-tile decoder-race gate needs: waitUntilComplete unblocks on
        // isComplete, flipped at the END of this function. It takes no GPU lock,
        // so warmUp() schedules it on an early defer.
        let mpvStart = Date()
        guard let mpv = mpv_create() else {
            #if DEBUG
            debugLog("[MPV-WARMUP] mpv_create failed, warm-up skipped (thermal=\(thermalAtStart))")
            #endif
            return
        }

        // Match Coordinator.setupMPV() generic options as closely as possible
        // without hitting per-stream config, to trigger the same libmpv init
        // codepath real playback uses. v1.7.x: hwdec default is now
        // videotoolbox-copy (was videotoolbox); see the rationale block above
        // the matching call in setupMPV.
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "profile", "fast")
        #if !targetEnvironment(simulator)
        mpv_set_option_string(mpv, "hwdec", "videotoolbox-copy")
        #endif

        let initResult = mpv_initialize(mpv)

        // Destroy immediately: we don't need the handle, just the side effects
        // of initialize. terminate_destroy is synchronous; no event-loop
        // stragglers.
        mpv_terminate_destroy(mpv)
        let mpvMs = Int(Date().timeIntervalSince(mpvStart) * 1000)

        // Flip the decoder-race gate now, after Phase 1 only. The first
        // multiview tile's setupMPV can proceed the instant libmpv is
        // registered; it does NOT need the Phase-2 EAGL pre-warm (that only
        // hides a one-time GL driver load). Set even when initialize returned an
        // error, matching the prior behavior (only mpv_create failing skips it).
        isComplete = true

        #if DEBUG
        if initResult < 0 {
            let err = String(cString: mpv_error_string(initResult))
            debugLog("[MPV-WARMUP] phase1 libmpv registration in \(mpvMs)ms (thermal=\(thermalAtStart)), isComplete flipped, initialize returned error: \(err)")
        } else {
            debugLog("[MPV-WARMUP] phase1 libmpv registration in \(mpvMs)ms (thermal=\(thermalAtStart)), isComplete flipped, first tap hits the warm mpv path")
        }
        #endif
    }

    private static func doWarmUpEAGL() {
        // Phase 2: OpenGL ES driver pre-warm. On a fresh app install the FIRST
        // EAGLContext(api:) call in the process pays a ~2s one-time cost while
        // the OS pages the OpenGL ES driver in from disk (per-phase timing in
        // setupMPV confirmed it: cold first tile shows EAGLContext_create
        // ~2053ms, subsequent tiles ~11ms). Create a throwaway context + texture
        // cache and discard it, so the driver load amortises during idle startup
        // instead of during the user's first channel tap; later real
        // EAGLContext creations in Coordinator.setupMPV hit the warm path.
        //
        // This takes a process-wide GPU driver lock for ~1-2s, so warmUp()
        // defers it well past channel-list first paint (see the note there).
        // Pure background pre-warm: it does NOT touch isComplete.
        //
        // Simulator skips: its GLES path uses a different software renderer that
        // does not share this cost and CVOpenGLESTextureCacheCreate is a no-op.
        let eaglStart = Date()
        #if !targetEnvironment(simulator)
        if let ctx = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) {
            EAGLContext.setCurrent(ctx)
            var cache: CVOpenGLESTextureCache?
            CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, ctx, nil, &cache)
            // cache retained through scope end then released; we just need the
            // first-time driver allocation to happen. The real cache is built
            // per-Coordinator.
            _ = cache
            EAGLContext.setCurrent(nil)
        }
        #endif
        let eaglMs = Int(Date().timeIntervalSince(eaglStart) * 1000)
        #if DEBUG
        debugLog("[MPV-WARMUP] phase2 EAGL GPU pre-warm in \(eaglMs)ms, first tap hits the warm GL path")
        #endif
    }

    /// Same vocabulary as `MultiviewContainerView.thermalStateName`
    /// so log lines from different subsystems are greppable as one
    /// dataset.
    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - MPV Player View Controller (OpenGL ES render → AVSampleBufferDisplayLayer → PiP)

class MPVPlayerViewController: UIViewController {
    weak var coordinator: MPVPlayerViewRepresentable.Coordinator?

    /// AVSampleBufferDisplayLayer — vsync-synchronized frame presentation.
    /// Used on both iOS (PiP-compatible) and tvOS (tear-free).
    let sampleBufferLayer = AVSampleBufferDisplayLayer()

    #if os(iOS)
    /// PiP controller — created lazily on first request via
    /// `ensurePiPController()`. Nil until the single-stream
    /// makeUIViewController path builds it.
    ///
    /// Previously this was eagerly initialized in `viewDidLoad`.
    /// That meant every multiview tile (up to 9) paid the cost of
    /// an `AVPictureInPictureController` allocation + delegate
    /// table wiring + the `ContentSource` `sampleBufferDisplayLayer`
    /// binding, even though only the audio tile is ever PiP-eligible.
    /// With 9 tiles that's 9× the AVF state for one user-triggered
    /// feature. Lazy creation keeps the cost to 0 for non-audio
    /// tiles and 1 for the one tile that ever needs it.
    var pipController: AVPictureInPictureController?

    /// Build the PiP controller against the already-attached
    /// `sampleBufferDisplayLayer`, or return the cached instance.
    /// Returns `nil` on platforms / devices where PiP isn't
    /// supported (e.g. iPhone in some locales / older simulators).
    /// Called from `makeUIViewController` during single-stream
    /// mount so `canStartPictureInPictureAutomaticallyFromInline`
    /// has a live controller to fire against when the app
    /// backgrounds. The manual PiP menu entry has been removed —
    /// PiP is auto-only.
    ///
    /// Paired with `tearDownPiPController()` for the Audio-Only
    /// suppression path: empirically, iOS ignores runtime writes to
    /// `canStartPictureInPictureAutomaticallyFromInline = false` and
    /// still engages auto-PiP on swipe-home. The reliable suppressor
    /// is destroying the controller entirely when the user flips
    /// Audio Only, then rebuilding via this method when they flip
    /// it back off.
    @discardableResult
    func ensurePiPController() -> AVPictureInPictureController? {
        if let existing = pipController { return existing }
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let coordinator else { return nil }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferLayer,
            playbackDelegate: coordinator
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.delegate = coordinator
        // Always auto-start PiP when the app backgrounds. No user toggle —
        // PiP is the only way to keep video alive when the app leaves the
        // foreground, and removing the toggle eliminates a footgun where
        // users turned it off and then wondered why swipe-home killed
        // their stream. iOS only honours this on an already-instantiated
        // controller, which is why the single-stream path in
        // `makeUIViewController` below eagerly calls this method.
        // Multiview auto-PiP is still deferred — eager-create during a
        // multi-tile mount correlates 1:1 with an app freeze.
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = pip
        return pip
    }

    /// Release the PiP controller entirely. Used by the Audio-Only
    /// suppression path — without a live controller, iOS has no
    /// handle on our sample-buffer layer and can't engage auto-PiP
    /// on swipe-home. The sample buffer layer itself (and mpv) stay
    /// alive; only the PiP controller goes away.
    func tearDownPiPController() {
        guard pipController != nil else { return }
        pipController?.delegate = nil
        pipController = nil
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.layer.isOpaque = true

        // v1.7.x: paint the player's host UIView and the sample buffer
        // layer black explicitly so the AerioTV navy parent
        // (Color(hex: "0A1628") = appBackground) doesn't bleed through
        // during the ~1-2s window between viewDidLoad and the first
        // decoded frame landing in `sampleBufferLayer`. Without this,
        // users on UHD / high-bitrate streams (Sky Sports F1 UHD, p010
        // 10-bit HEVC where the videotoolbox-copy fallback adds
        // ~1.5s before any frame renders) see a brief navy "blue
        // screen" between channel tap and first frame. Black is the
        // industry-standard pre-frame state for video players (matches
        // AVPlayerViewController and tvOS's video playback paradigm).
        view.backgroundColor = .black
        sampleBufferLayer.backgroundColor = UIColor.black.cgColor

        // AVSampleBufferDisplayLayer for vsync-synchronized presentation (both platforms).
        //
        // `.resizeAspect` keeps the source aspect ratio, letterboxing
        // when the tile rect is taller or wider than the video. This
        // is the convention every iOS video app follows. v1.7.x
        // briefly tried `.resizeAspectFill` for multiview tiles to
        // close the visible black gap between stacked tiles in the
        // N=3 right column, but that over-zoomed the content on
        // every layout (single-stream too) which was a worse
        // regression than the gap. Reverted; the gap will be
        // addressed at the layout-rect level (`MultiviewGridMath`)
        // in a future pass instead.
        // Issue #26: honor the persisted aspect mode at layer setup (the
        // Coordinator's sink handles later changes). Defaults to .resizeAspect
        // (Fit) when there's no coordinator yet or no persisted choice.
        sampleBufferLayer.videoGravity = coordinator?.progressStore.aspectMode.videoGravity ?? .resizeAspect
        sampleBufferLayer.frame = view.bounds
        view.layer.addSublayer(sampleBufferLayer)

        // PiP controller is NOT created here — see `ensurePiPController()`
        // above for the lazy-init rationale.

        #if DEBUG
        debugLog("[MPV-DIAG] viewDidLoad: frame=\(view.frame), inWindow=\(view.window != nil)")
        // v1.7.x Issue A round 3: log the AVSBDL initial config so
        // the next test reveals whether anything about the layer
        // setup (controlTimebase, color decoration policy, etc.) is
        // contributing to the single-VSync black flashes during
        // libmpv stalls.
        let tb = sampleBufferLayer.controlTimebase
        var rate: Double = -1
        if let tb { rate = CMTimebaseGetRate(tb) }
        let timebaseDesc: String = tb == nil ? "nil" : "set(rate=\(rate))"
        debugLog("[AVSBDL-INIT] videoGravity=\(sampleBufferLayer.videoGravity.rawValue) frame=\(sampleBufferLayer.frame) controlTimebase=\(timebaseDesc) opaque=\(sampleBufferLayer.isOpaque)")
        #endif

        coordinator?.setupRenderer(layer: view.layer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0 && size.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferLayer.frame = view.bounds
        CATransaction.commit()
        coordinator?.handleResize(size: size)
    }
}

// MARK: - MPV Player View Representable

struct MPVPlayerViewRepresentable: UIViewControllerRepresentable {
    let urls: [URL]
    let headers: [String: String]
    let isLive: Bool
    /// True only for an in-progress DVR recording (growing seekable
    /// window). Single-stream recordings set this; live TV, VOD, and
    /// multiview tiles leave it false. Drives the live-edge seek clamp
    /// and keeps a transient end-of-playlist EOF from locking seeks.
    var isDVR: Bool = false
    /// Catch-up (timeshift): non-nil when playing an aired programme from
    /// the provider archive. The Coordinator then (a) pins the reported
    /// duration to the programme length, (b) offsets time-pos by the
    /// current re-tune window, and (c) turns seeks into URL rebuilds.
    var catchup: CatchupPlayback? = nil
    let nowPlayingTitle: String
    let nowPlayingSubtitle: String?
    let nowPlayingArtworkURL: URL?
    var progressStore: PlayerProgressStore
    var logStore: AttemptLogStore
    let onFatalError: @MainActor @Sendable (String) -> Void
    /// Called once when playback reaches steady state again AFTER an
    /// `onFatalError` was reported (a Retry/auto-reconnect succeeded).
    /// The error-overlay owner uses it to dismiss the card. nil callers
    /// keep the old behavior (error state is terminal).
    var onRecovered: (@MainActor @Sendable () -> Void)? = nil
    /// Identity of this coordinator when used as a multiview tile.
    /// `nil` means single-stream mode (the default) — the Coordinator
    /// behaves exactly like it did before multiview existed and
    /// unconditionally drives `NowPlayingBridge`.
    ///
    /// When non-nil, the Coordinator only drives `NowPlayingBridge`
    /// when `PlayerSession.mode == .multiview` AND
    /// `MultiviewStore.audioTileID == self.tileID`. Non-audio tiles
    /// stay quiet on the lockscreen + remote command surface.
    var tileID: String? = nil

    /// Multiview: `true` when this tile currently owns audio. Drives
    /// the mpv `mute` property — `false` sends `mute=1`, `true` sends
    /// `mute=0`. In single-stream mode (tileID == nil) we ignore this
    /// field; single mode is always audio-active by construction.
    ///
    /// SwiftUI feeds a new value via `updateUIViewController` whenever
    /// `MultiviewStore.audioTileID` changes — the Coordinator tracks
    /// the last-applied value and skips redundant mpv calls.
    var isAudioActive: Bool = true

    /// Multiview + PiP: `true` when this tile should pause itself
    /// (non-audio tiles while PiP is active) via the mpv `pause`
    /// property. Ignored in single-stream mode.
    ///
    /// The PiP window always hosts the current audio tile; the other
    /// tiles freeze on their last decoded frame while PiP is active,
    /// saving network + GPU, and resume when PiP ends.
    var shouldPause: Bool = false

    /// Multiview tile count at the moment this Representable is being
    /// constructed. Captured on the main actor at SwiftUI render time
    /// and passed through to the Coordinator so `setupMPV` (which
    /// runs on a background queue and can't reach
    /// `MultiviewStore.shared`) can pick the matching audio strategy
    /// at pre-init time. Defaults to 1 — single-stream callers don't
    /// need to set it because the audio-strategy branch only fires
    /// for `initialIsAudioActive == false`, which never happens in
    /// single-stream mode.
    var initialTileCount: Int = 1

    func makeCoordinator() -> Coordinator {
        // CarPlay drives audio-only playback, so suppress video from the very
        // first frame at the mpv layer. Besides being the driver-safety
        // default, this is what lets audio play at all on the iOS Simulator:
        // its OpenGL ES path is broken (CVOpenGLESTextureCacheCreate fails),
        // and with video up the VO can never drain frames, stalling the whole
        // stream. makeCoordinator runs on the main thread, so reading the
        // @MainActor NowPlayingManager via assumeIsolated is safe.
        let videoSuppressed = MainActor.assumeIsolated {
            NowPlayingManager.shared.isCarPlayConnected
        }
        let c = Coordinator(urls: urls, headers: headers, isLive: isLive,
                            isDVR: isDVR,
                            progressStore: progressStore, logStore: logStore,
                            onFatalError: onFatalError,
                            tileID: tileID,
                            initialIsAudioActive: isAudioActive,
                            initialShouldPause: shouldPause,
                            initialTileCount: initialTileCount,
                            initialVideoSuppressed: videoSuppressed)
        c.nowPlayingTitle = nowPlayingTitle
        c.nowPlayingSubtitle = nowPlayingSubtitle
        c.nowPlayingArtworkURL = nowPlayingArtworkURL
        c.onRecovered = onRecovered
        // Catch-up: hand the playback context to the Coordinator and pin
        // the store's duration to the programme's real length up front
        // (the timeshift TS reports an estimated duration that must never
        // drive the scrubber). makeCoordinator runs on the main thread.
        if let cu = catchup {
            c.catchup = cu
            progressStore.durationMs = cu.programDurationMs
        }
        return c
    }

    func makeUIViewController(context: Context) -> MPVPlayerViewController {
        // Audio session: route through the process-wide refcount so N
        // concurrent Coordinators (single + PiP, or multiview) don't
        // race on setActive. The first coordinator's increment handles
        // setCategory + setActive(true); subsequent increments no-op;
        // decrements are matched at teardown. The refcount itself
        // swallows session errors with an NSLog (matches the old
        // behavior at this site — session activation can fail in
        // odd backgrounding states and we let mpv try anyway).
        AudioSessionRefCount.increment()

        #if os(iOS)
        // A foreground player view is mounting: claim the coexistence registry
        // and evict any headless CarPlay engine BEFORE this coordinator reaches
        // loadfile, so the two never decode the same channel at once (double
        // audio). The refcount increment above already holds the session active
        // across the handoff, so yielding here causes no deactivation bounce.
        // SwiftUI calls this on the main thread; assumeIsolated bridges to the
        // @MainActor registry/controller regardless of the method's isolation.
        MainActor.assumeIsolated {
            PlaybackEngineRegistry.shared.coordinatorWillMount()
            HeadlessPlaybackController.shared.yieldToViewEngine()
        }
        #endif

        let vc = MPVPlayerViewController()
        vc.coordinator = context.coordinator

        // Wire up PiP (iOS only). PiP is auto-only — the manual
        // overflow-menu entry was removed; users swipe home to
        // engage PiP, gated by the Settings → Appearance →
        // Picture-in-Picture toggle.
        //
        // Eager-create the controller for SINGLE-STREAM mount
        // (`tileID == nil`). iOS's auto-PiP-on-background API
        // (`canStartPictureInPictureAutomaticallyFromInline`) only
        // fires on an already-instantiated controller, so it has to
        // exist in the foreground. Single-stream has exactly one
        // AVSampleBufferDisplayLayer in the hierarchy, so iOS
        // reliably picks it as the auto-PiP target.
        //
        // iOS fires `pictureInPictureControllerWillStartPictureInPicture`
        // before `didEnterBackground`, and that delegate synchronously
        // sets `progressStore.isPiPActive = true` — so the background
        // handler's first-branch check against isPiPActive correctly
        // short-circuits the vid=no path for the PiP case.
        //
        // Eager-create fires on two entry points:
        //   (a) Legacy PlayerView single-stream path (tileID == nil).
        //   (b) Unified-player N=1 — a tileID is set, but there's
        //       exactly one tile in MultiviewStore, which is the case
        //       when the user launches playback from the Guide /
        //       Channels list without having added a second tile.
        //       This is the default user path and MUST support PiP.
        //
        // We gate (b) on `tiles.count <= 1` so the dangerous case —
        // mounting a 2nd tile while the 1st is still loadfile-
        // cascading — still skips. The 1st tile's mount happens in
        // isolation (no parallel mpv activity), so eager-create there
        // is safe; only concurrent multi-tile mounts cause the freeze.
        #if os(iOS)
        let isSoloTile = (tileID == nil) ||
            (isAudioActive && MultiviewStore.shared.tiles.count <= 1)
        if isSoloTile {
            // Wire the VC weak ref onto the Coordinator so
            // `updateAutoPiPEligibility()` can tear down / rebuild
            // the PiP controller in response to Audio-Only toggles.
            // The helper then performs the initial build (when
            // isAudioOnly=false) via `vc.ensurePiPController()`.
            // On devices without PiP support the helper no-ops and
            // leaves `pipAutoEligible` false.
            context.coordinator.viewController = vc
            context.coordinator.updateAutoPiPEligibility()
            #if DEBUG
            debugLog("[MPV-PIP] makeUIViewController: tileID=\(tileID ?? "single") coord=\(ObjectIdentifier(context.coordinator)) audioOnly=\(context.coordinator.progressStore.isAudioOnly)")
            #endif
        }
        #endif

        return vc
    }

    func updateUIViewController(_ uiViewController: MPVPlayerViewController, context: Context) {
        // Layout handled by viewDidLayoutSubviews.
        //
        // IMPORTANT: single-stream mode (tileID == nil) MUST NOT
        // touch mpv's `mute` or `pause` properties from here. Those
        // are driven by the user's on-screen controls + the mpv
        // event stream — any write from SwiftUI's update pass is a
        // potential race against mpv's initialization sequence (mpv
        // is created on the render queue; our writes dispatch via
        // mpvQueue — safe at steady state, but startup ordering is
        // fragile and not worth the risk for a mode that has no
        // multiview logic anyway).
        //
        // Multiview tiles (tileID != nil) DO need these property
        // writes because that's how audio-focus + PiP-pause are
        // implemented. The applyXxxIfChanged helpers idempotency-
        // guard against spurious SwiftUI updates.
        if tileID != nil {
            context.coordinator.applyAudioFocusIfChanged(isAudioActive)
            context.coordinator.applyPauseIfChanged(shouldPause)
            // v1.7.x: route URL changes through the in-place
            // `swapStream` path so a channel-flip on the current
            // tile reuses the existing mpv handle (loadfile replace)
            // instead of going through a coordinator teardown +
            // rebuild. The actual flip is initiated upstream by
            // `MultiviewStore.swapTileContent`, which updates the
            // tile's `streamURL` while preserving the tile's `id`;
            // that drives a fresh Representable with new `urls`
            // through this update pass. `swapStreamIfChanged`
            // dedups against the steady stream of no-op update
            // calls SwiftUI emits. tileID-gated for the same
            // reasons the audio / pause helpers are: single-stream
            // mode has its own lifecycle and doesn't go through
            // the multiview flip path.
            context.coordinator.swapStreamIfChanged(to: urls, newTitle: nowPlayingTitle, newSubtitle: nowPlayingSubtitle)
            // NOTE: no PiP wiring here. Multiview tiles do NOT
            // auto-PiP on background (eager-creating
            // AVPictureInPictureController during a multi-tile
            // mount reproducibly freezes the app). The manual PiP
            // menu item was also removed (PiP is auto-only).
            // Single-stream playback (the case the user was
            // reporting as broken vs v1.6.0) still gets auto-PiP
            // via the eager-create call in `makeUIViewController`
            // above, which runs once.
        }
    }

    static func dismantleUIViewController(_ uiViewController: MPVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
        #if os(iOS)
        // Pair the coordinatorWillMount() claimed in makeUIViewController.
        MainActor.assumeIsolated {
            PlaybackEngineRegistry.shared.coordinatorDidUnmount()
        }
        #endif
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, @unchecked Sendable,
                                AVPictureInPictureControllerDelegate,
                                AVPictureInPictureSampleBufferPlaybackDelegate {
        private var urls: [URL]
        private let headers: [String: String]
        private let isLive: Bool
        /// In-progress DVR recording: a growing seekable window from the
        /// recording start to the live edge. Seeks are clamped a few
        /// seconds behind the edge so we never seek onto EOF, and a
        /// transient end-of-playlist EOF does not lock further seeks.
        private let isDVR: Bool
        /// How far behind the reported playlist end (seconds) a DVR seek
        /// is allowed to land. Seeking exactly to the live edge of an
        /// in-progress HLS playlist lands on EOF and stalls; staying a
        /// few seconds back keeps playback flowing into the live edge.
        /// Catch-up (timeshift) context, or nil for every other playback.
        /// Set once by makeCoordinator before the view mounts.
        var catchup: CatchupPlayback? = nil
        /// Task #149: the native session URL the player is CURRENTLY
        /// tuned to. Every seek re-mint replaces it (new session_id);
        /// teardown revokes it so the server's per-session provider slot
        /// frees ahead of the 10-minute idle TTL. nil on the XC paths.
        var catchupCurrentURL: URL? = nil
        /// Task #149: native re-mints are SERIALIZED. Rapid +/-30s
        /// presses used to fire overlapping mint/revoke/loadfile cycles;
        /// the server 503'd playback opens whose just-revoked sibling
        /// still held the provider slot, and the resulting retry storm
        /// ended on the red error card (ATV log 2026-07-11 20:46). While
        /// a mint is in flight, later seek targets coalesce into
        /// `nativeRemintPendingMs` and only the LATEST runs when the
        /// in-flight one lands. Both are mpvQueue-confined.
        var nativeRemintInFlight = false
        var nativeRemintPendingMs: Int32? = nil
        /// Recovery signal for the playback-error overlay: non-nil when
        /// the host view wants to dismiss its error card on a successful
        /// Retry/auto-reconnect. Fired from PLAYBACK_RESTART when
        /// `fatalErrorReported` is latched.
        var onRecovered: (@MainActor @Sendable () -> Void)? = nil
        /// Latched when `onFatalError` fires so the NEXT successful
        /// playback-restart is recognized as a recovery (and reported
        /// exactly once). mpvQueue-confined.
        var fatalErrorReported = false
        /// Live Rewind: this coordinator's live playback runs through
        /// the aeriots:// buffer relay (fullscreen single live only).
        /// Set in play(url:) when the engine session starts. Backed by
        /// the playback-state lock (cross-thread access).
        var liveRewindActive: Bool {
            get { withPlaybackStateLock { $0.liveRewindActive } }
            set { withPlaybackStateLock { $0.liveRewindActive = newValue } }
        }
        /// Live Rewind: the relay failed for the CURRENT tune, so play
        /// direct and stop re-routing through it. Reset on channel
        /// change (swapStream); a fresh coordinator starts clear.
        var liveRewindFallbackDirect: Bool {
            get { withPlaybackStateLock { $0.liveRewindFallbackDirect } }
            set { withPlaybackStateLock { $0.liveRewindFallbackDirect = newValue } }
        }
        /// Programme-relative start (ms) of the currently tuned timeshift
        /// window: 0 on first tune, the floored seek target after each
        /// re-tune. Displayed position = this + mpv time-pos.
        var catchupBaseOffsetMs: Int32 = 0
        /// Residual seconds to seek once the re-tuned file loads (the
        /// timeshift URL's start segment has minute granularity; this
        /// lands the exact second). Consumed by handleFileLoaded.
        var catchupPendingSeekSecs: Double? = nil
        /// One-shot guard for the mid-programme EOF re-tune; reset per
        /// fresh play() so each window gets one recovery attempt.
        var catchupEofRetuneUsed = false
        /// Task #183: native catch-up position/pause reporting
        /// (Dispatcharr dev 6f62d807). Best-effort telemetry state:
        /// written from the stats tick (mpv event thread) and the pause
        /// path (main); the races are benign one-way/monotonic updates,
        /// accepted by design - do NOT add locking for these.
        var catchupLastKnownPositionSecs: Double = 0
        var catchupPositionLastReportAt: Date? = nil
        var catchupPositionReportedPaused: Bool? = nil
        var catchupPositionUnsupported = false
        static let catchupPositionReportIntervalSecs: TimeInterval = 20

        /// Task #183: POST the local playhead + pause state to the native
        /// session's position endpoint. Sent on the stats tick (which
        /// keeps firing while PAUSED - each accepted report refreshes the
        /// session idle TTL so a long pause can't expire the session) and
        /// immediately on pause/resume flips. One 404 latches reporting
        /// off for this playback (stable-tag server without the endpoint).
        func reportCatchupPositionIfDue(positionSecs: Double, paused: Bool, force: Bool) {
            guard let cu = catchup, cu.nativeChannelUUID != nil,
                  !catchupPositionUnsupported else { return }
            let now = Date()
            let pausedChanged = catchupPositionReportedPaused != paused
            let intervalDue = catchupPositionLastReportAt
                .map { now.timeIntervalSince($0) >= Self.catchupPositionReportIntervalSecs } ?? true
            guard force || pausedChanged || intervalDue else { return }
            catchupPositionLastReportAt = now
            catchupPositionReportedPaused = paused
            let url = catchupCurrentURL ?? cu.url
            Task(priority: .utility) { [weak self] in
                let keep = await CatchupSupport.reportNativePosition(playback: cu,
                                                                    currentURL: url,
                                                                    positionSecs: positionSecs,
                                                                    paused: paused)
                if !keep { self?.catchupPositionUnsupported = true }
            }
        }

        fileprivate static let dvrLiveEdgeGuardSec: Double = 6.0
        fileprivate let progressStore: PlayerProgressStore
        private let logStore: AttemptLogStore
        private let onFatalError: @MainActor @Sendable (String) -> Void

        // Now Playing metadata
        var nowPlayingTitle: String = ""
        var nowPlayingSubtitle: String?
        var nowPlayingArtworkURL: URL?
        private var nowPlayingConfigured = false

        // Multiview tile identity. `nil` = single-stream mode — this
        // coordinator unconditionally drives NowPlayingBridge. Non-nil
        // = one tile in a multiview grid; the coordinator only drives
        // the bridge when it's the audio tile. See
        // `shouldDriveNowPlayingBridge()` for the gating rule.
        //
        // `let` so Swift 6 strict-concurrency doesn't flag the
        // cross-actor read (init on MainActor via `makeCoordinator`,
        // read on MainActor via `shouldDriveNowPlayingBridge`). If
        // SwiftUI rebinds the representable with a different tileID
        // (e.g. tile reorder), the tile's `.id(...)` modifier forces
        // SwiftUI to build a fresh coordinator — so treating this as
        // immutable-per-coordinator-lifetime matches the model.
        let tileID: String?

        /// Human-readable log tag for this coordinator's stream.
        /// Shape: `[tile=<short-id> <channel-name>]`, e.g.
        /// `[tile=744 NBC Sports NOW]`. Used as a prefix on every
        /// per-stream log line (frame diagnostics, stats ticks,
        /// layer failures, mpv warnings) so when 9 streams are
        /// playing their log lines can be filtered and grouped by
        /// channel instead of having to decode opaque UUIDs.
        ///
        /// - Single-stream mode (tileID == nil): returns the
        ///   channel name alone wrapped in `[tile=single <name>]`.
        /// - Multiview: uses the first 6 chars of the UUID so the
        ///   tag stays compact on busy logs. The channel name is
        ///   set by SwiftUI via the representable's
        ///   `nowPlayingTitle` and may update if SwiftUI rebinds,
        ///   so we read it at each log site rather than caching.
        var streamTag: String {
            let id = tileID ?? "single"
            let shortID = id.count > 8 ? String(id.prefix(8)) : id
            let name = nowPlayingTitle.isEmpty ? "?" : nowPlayingTitle
            return "[tile=\(shortID) \(name)]"
        }

        /// Bridge-ownership gate for multiview. Returns `true` when
        /// this coordinator is allowed to write `MPNowPlayingInfoCenter`
        /// + install `MPRemoteCommandCenter` handlers, `false` when it
        /// should stay silent because another coordinator (the audio
        /// tile) is authoritative. In single-stream mode (tileID == nil)
        /// this is always `true` — preserves pre-multiview behavior.
        ///
        /// The check is run on MainActor because `PlayerSession` and
        /// `MultiviewStore` are both `@MainActor`-isolated.
        @MainActor
        fileprivate func shouldDriveNowPlayingBridge() -> Bool {
            #if os(iOS)
            // GH #33: while casting, the phone plays nothing -- a lingering
            // mpv coordinator (teardown races the cast handoff) must not
            // repopulate Now Playing. Android shipped the same fix after a
            // stale media notification survived into remote mode.
            if AerioCastController.shared.isCasting { return false }
            #endif
            // Single-mode coordinator — always authoritative.
            guard let tileID else { return true }
            // Multiview coordinator — only the audio tile drives the
            // bridge. If the session somehow isn't in .multiview mode
            // (race during teardown, or coordinator lingers post-exit),
            // stay quiet. The single-mode coordinator (if any) will
            // pick up the bridge as it takes over.
            guard PlayerSession.shared.mode == .multiview else { return false }
            return MultiviewStore.shared.audioTileID == tileID
        }

        // MARK: - Multiview property application

        /// Initial state captured at Coordinator init — used by
        /// `setupMPV()` to set the `mute` / `pause` options BEFORE
        /// `mpv_initialize` so the first frame already has the right
        /// audio-focus and pause state. Without this, a non-audio
        /// tile created during multiview-entry would briefly play
        /// sound between mpv_initialize and the first SwiftUI
        /// updateUIViewController pass applying `mute=yes`.
        private let initialIsAudioActive: Bool
        private let initialShouldPause: Bool

        /// Last value we wrote to mpv's `mute` property (via the
        /// `applyAudioFocus` path). Seeded with the initial value in
        /// `init` so the first `updateUIViewController` is a no-op —
        /// `setupMPV` already applied the initial mute state as an
        /// option. Only genuine runtime transitions (audio tile
        /// change) flip mpv's mute at runtime.
        private var lastAppliedAudioFocus: Bool?

        /// Last value we wrote to mpv's `pause` property through the
        /// multiview PiP path. Parallel to `lastAppliedAudioFocus`.
        /// We intentionally do NOT consult the normal pause-observer
        /// state here — pausing from PiP is orthogonal to the user's
        /// play/pause button, and we want to drive the pause property
        /// back off on PiP-exit regardless of the last event the
        /// observer saw.
        private var lastAppliedPause: Bool?
        /// GH #60: mpv's ACTUAL pause state, mirrored from the "pause"
        /// property observer - covers every pause path (progress-store
        /// commands, PiP, rewind transport), unlike lastAppliedPause which
        /// only tracks applyPauseIfChanged. Gates the stale/soft watchdogs.
        private var mpvObservedPaused = false

        /// **Belt-and-suspenders** for the `aid` and `mute` writes
        /// inside `applyAudioFocusIfChanged`. v1.6.12 fix for the
        /// audio-bonk-on-tile-rearrange bug.
        ///
        /// The outer `lastAppliedAudioFocus` guard is keyed on the
        /// SwiftUI-level `isActive` boolean, but it can desync from
        /// mpv's actual property state in exotic circumstances (a
        /// Coordinator rebuild that dispatches a write before the
        /// init seed lands, a SwiftUI invalidation cycle that
        /// re-enters the path before the previous mpvQueue dispatch
        /// completes, etc.). Re-writing `aid=auto` when the property
        /// is already `auto` causes mpv to re-run track selection
        /// and tear down + re-open its AudioUnit — which on iOS
        /// produces an audible "bonk" / brief audio dropout. These
        /// secondary guards record the last value the mpvQueue
        /// dispatch actually wrote and skip the
        /// `mpv_set_property*` call when the new value matches.
        ///
        /// `nil` means "we have not written this property yet" —
        /// the next write goes through unconditionally.
        private var lastWrittenAID: String?
        private var lastWrittenMute: Int32?

        /// Set true when this coordinator auto-paused mpv while the
        /// app was backgrounded, either from the explicit
        /// `didEnterBackground` policy path or from the render-layer
        /// `.failed` safeguard. `willEnterForeground` consults this
        /// to know whether it owns the `pause=0` write, without
        /// clobbering a user-initiated pause from the play/pause
        /// button.
        fileprivate var autoPausedOnBackground: Bool {
            get { withPlaybackStateLock { $0.autoPausedOnBackground } }
            set { withPlaybackStateLock { $0.autoPausedOnBackground = newValue } }
        }

        /// True when this coordinator's VC has a pre-built
        /// `AVPictureInPictureController` with
        /// `canStartPictureInPictureAutomaticallyFromInline == true`.
        /// Belt-and-suspenders to the synchronous
        /// `progressStore.isPiPActive = true` write in
        /// `pictureInPictureControllerWillStartPictureInPicture`:
        /// even if iOS ever re-orders its PiP-engagement /
        /// background-transition callbacks, the flag guarantees we
        /// don't set `vid=no` on a coordinator whose video frames
        /// iOS may still be inspecting to decide whether to engage
        /// auto-PiP. `vid=no` mid-decision starves the engagement
        /// and is the original root cause of the auto-PiP
        /// regression we're closing here.
        ///
        /// Flipped false by the `progressStore.$isAudioOnly` sink
        /// when the user opts into Audio Only — otherwise iOS
        /// auto-engages PiP on swipe-home even though the user
        /// explicitly asked for audio only (the PiP window would
        /// shadow the NowPlaying lockscreen/Dynamic Island UI).
        fileprivate var pipAutoEligible: Bool = false

        /// Tracks whether the app is currently in the iOS background
        /// state. Set true in `didEnterBackground`, false in
        /// `willEnterForeground`. v1.6.8: read by `renderAndPresent`
        /// to decide whether to auto-pause mpv when the sample-buffer
        /// layer enters `.failed` status — see the screen-lock fix
        /// in that function for the full rationale.
        fileprivate var isInBackground: Bool {
            get { withPlaybackStateLock { $0.isInBackground } }
            set { withPlaybackStateLock { $0.isInBackground = newValue } }
        }

        /// Weak reference to the `AVPictureInPictureController`
        /// built for this coordinator's VC. Used for diagnostic
        /// logging; the actual build/teardown cycle in
        /// `updateAutoPiPEligibility()` goes through `viewController`
        /// so it can manipulate the strong reference that iOS is
        /// consulting.
        fileprivate weak var pipController: AVPictureInPictureController?

        /// Weak reference to the backing UIViewController. Needed
        /// by `updateAutoPiPEligibility()` to tear down and rebuild
        /// the PiP controller on Audio-Only toggles — the strong
        /// reference lives on the VC, so clearing the Coordinator's
        /// weak ref alone wouldn't actually release the controller
        /// or stop iOS from engaging auto-PiP.
        fileprivate weak var viewController: MPVPlayerViewController?

        /// Combine subscription bag. Currently holds the sink on
        /// `progressStore.$isAudioOnly` that disables auto-PiP when
        /// the user flips Audio Only. Declared fileprivate so the
        /// representable can add more sinks later without exposing
        /// them outside the file.
        fileprivate var cancellables: Set<AnyCancellable> = []

        /// Wall-clock timestamp when `applyPauseIfChanged(true)` last
        /// set `pause=yes`. Consulted on the next unpause transition to
        /// decide whether a `loadfile replace` snap-to-live is worth
        /// doing. Brief pauses (picker open/close during a tile-add —
        /// typically <2s) fall BEHIND live by less than the cache-secs
        /// buffer and don't need the reload; long pauses do.
        ///
        /// The old behaviour re-seeded every tile on every picker-close,
        /// which at 9-tile multiview caused cascading `loadfile replace`
        /// storms (one tile observed a 19s recovery when its reload
        /// hit `Failed to recognize file format` during the cascade).
        fileprivate var pauseStartedAt: Date?

        /// Minimum pause duration before an unpause triggers the
        /// snap-to-live reload. Tuned so normal picker interactions
        /// (open sheet → pick channel → sheet dismisses) stay under
        /// the threshold, while genuine "I left this paused for a
        /// while" pauses still snap forward on resume.
        ///
        /// **History:** v1.7.x originally set this to 2.0s. Archie's
        /// 2026-05-08 multiview tile-add testing surfaced that the
        /// picker dwell on iPhone 17 Pro Max consistently lands at
        /// 2.7s (dialog dismiss animation + tile re-layout +
        /// SwiftUI diff settle). Above the 2s threshold means every
        /// existing tile fires `loadfile replace` on every tile-add
        /// → cascading 2-3s freezes per tile, even when no user
        /// intent is to leave the tiles paused. Bumped to 5s to
        /// cover the observed 2.7s picker dwell with comfortable
        /// margin. Trade-off: a user who genuinely pauses (e.g.,
        /// app backgrounded for 3-4s) won't get an explicit snap
        /// to live edge, but mpv's live cache is 5s deep, so they
        /// resume from at-most-5s-behind which is visually
        /// indistinguishable from live for most live content. Long
        /// idles (>5s) still snap-to-live as before.
        private static let snapToLiveMinPauseSeconds: TimeInterval = 5.0

        /// v1.7.x: in-place stream swap on the existing mpv handle.
        /// Issues `loadfile <newURL> replace`, which keeps the GL
        /// render context, FBO ring, AVSampleBufferDisplayLayer,
        /// audio session, and (where compatible) the videotoolbox-copy
        /// decoder session alive across a channel-flip. The old
        /// channel's last decoded frame stays in the AVSBDL while
        /// mpv internally probes the new stream's headers; once
        /// `playback-restart` fires, frames flow at the new stream's
        /// real container fps with no cadence wobble.
        ///
        /// Paired with `MultiviewStore.swapTileContent(tileID:to:server:)`
        /// at the model layer (that method preserves the tile id so
        /// SwiftUI keeps THIS Coordinator mounted); SwiftUI's
        /// `updateUIViewController` pass then spots the new
        /// `urls.first` and routes through here.
        ///
        /// Replaces the v1.6.15 channel-flip lifecycle of
        /// `PlayerSession.exit() + enterMultiview(seeding:)`, which
        /// dismantled the entire coordinator and produced the
        /// "30fps then 60fps with a 200ms hiccup" wobble "the
        /// Moterator" reported (Discord 2026-05-11).
        ///
        /// - Parameters:
        ///   - newURL: the new stream URL. Headers don't change here
        ///     because in-server channel-flip uses the same auth.
        ///   - newTitle: the new channel's display name, for the
        ///     `MPNowPlayingInfoCenter` metadata. Empty string is
        ///     fine and leaves the existing title alone.
        ///   - newSubtitle: the new channel's current program, shown
        ///     as the Now Playing subtitle (lockscreen + CarPlay).
        ///     Updated alongside the title so a channel flip doesn't
        ///     leave the previous channel's program (or nil) stuck
        ///     under the new channel name.
        @MainActor
        fileprivate func swapStream(to newURL: URL, newTitle: String, newSubtitle: String?) {
            // Update the Coordinator's URL bookkeeping on the main
            // queue first so any subsequent reader (snap-to-live
            // reload, telemetry log line, retry path) sees the new
            // URL. The actual loadfile dispatches to mpvQueue below.
            urls = [newURL]
            currentIndex = 0
            // Reset per-stream telemetry so the diagnostic logs read
            // cleanly for the new stream rather than mixing with the
            // outgoing one's tail. mpv's own `container-fps` /
            // reconfigure events will repopulate `detectedFps` once
            // the new stream's headers are parsed.
            detectedFps = 0
            // v1.7.x: a channel flip goes through loadfile replace here,
            // NOT through play(url:), so the per-stream state that
            // play(url:) resets must be reset here too or it leaks across
            // the flip:
            //  - hdrToneMappingApplied: if left true from an SDR stream,
            //    applyHDRToneMappingIfNeeded() short-circuits on the new
            //    stream and a flip SDR->HDR would skip the BT.709 tone-map
            //    (green/washed HDR). Archie's 2026-06-06 fast-flip log
            //    showed the [HDR] line firing only ONCE for the whole
            //    session - every subsequent flip silently skipped detection.
            //  - hasReachedPlaybackRestartForStream: the new stream has
            //    not restarted yet, so disarm the reload watchdogs through
            //    its startup probe.
            //  - black/stale reload counters + cooldown: the new stream
            //    must not inherit the outgoing one's storm count or sit
            //    inside its cooldown.
            hdrToneMappingApplied = false
            hasReachedPlaybackRestartForStream = false
            consecutiveBlackFramesSuppressed = 0
            lastForcedBlackReloadAt = 0
            forcedReloadWindowStart = 0
            forcedReloadWindowCount = 0
            // Stall report belongs to the OUTGOING stream: reset the anchor to 0
            // (restoring the fresh-coordinator invariant so the SET guard's
            // `lastEnq > 0` again protects the new stream's pre-first-frame
            // window) and drop any soft card. Setting streamStalled=false when a
            // soft card was up fires the tile's onChange(false) -> clean teardown
            // (card + connectionIssueActive + chrome pin). swapStream is
            // @MainActor so this @Published write is safe here (2026-07-13 review).
            lastEnqueueTime = 0
            streamStalledReported = false
            progressStore.streamStalled = false
            // #37: re-read the kill-switch on every re-arm. Channel-flip and
            // multiview tile swaps reuse this coordinator and skip setupMPV,
            // so re-reading here makes "Auto-Recover Frozen Streams" apply to
            // the next channel even within a live multiview session.
            watchdogReloadEnabled = (UserDefaults.standard.object(forKey: "appBehaviorsAutoRecoverFrozenStreams") as? Bool) ?? true
            // Re-apply NowPlayingInfo metadata so the lockscreen +
            // Control Center reflect the new channel. The bridge
            // ownership rule from `shouldDriveNowPlayingBridge()`
            // still applies: if this coordinator isn't the
            // authoritative one, the bridge stays quiet. iOS-only
            // because tvOS doesn't surface the bridge UI (no
            // lockscreen / Control Center video metadata path).
            if !newTitle.isEmpty {
                nowPlayingTitle = newTitle
                // Update the program subtitle in the same pass so a flip
                // doesn't strand the previous channel's program (or nil)
                // under the new channel name on the lockscreen / CarPlay.
                nowPlayingSubtitle = newSubtitle
                #if os(iOS)
                reassertNowPlayingBridge()
                #endif
            }
            let safeURL = DebugLogger.sanitize(newURL.absoluteString)
            logStore.append("↻ MPV: swap stream → \(newTitle)")
            DebugLogger.shared.log(
                "[MV-Tile] swapStream: \(streamTag) to=\(newTitle) url=\(safeURL.prefix(80))",
                category: "MPV-STREAM", level: .info
            )
            // Live Rewind: a channel flip bypasses play(url:), so route
            // here too. This starts a fresh buffer session for the NEW
            // channel (startSession stops the old one) or, when the new
            // tune is ineligible, stops the old session; before this the
            // flip left the engine buffering the PREVIOUS channel with
            // liveRewindActive still true, so the transport, the time-pos
            // mapping, and any seek pointed at the wrong channel's
            // buffer. A flip is also a fresh tune for the relay: clear
            // the direct-stream fallback latch.
            liveRewindFallbackDirect = false
            let routedURL = routeThroughLiveRewind(newURL)
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.activeMPVHandle() else { return }
                self.mpvCommand(mpv, ["loadfile", routedURL.absoluteString, "replace"])
            }
        }

        /// SwiftUI update-pass entry point for `swapStream`. Compares
        /// the incoming primary URL against the Coordinator's current
        /// one and forwards to `swapStream(to:newTitle:)` only on a
        /// real change. Idempotent against the steady stream of
        /// no-op `updateUIViewController` calls SwiftUI issues for
        /// unrelated state changes (audio focus flip, pause flip,
        /// tile reorder, every ancestor `@Published` fire).
        ///
        /// Empty incoming URL list is treated as a no-op rather than
        /// triggering a swap (there's no sensible loadfile target),
        /// and the (rare) edge case where SwiftUI rebinds with no
        /// URLs during a teardown shouldn't accidentally tear the
        /// existing stream.
        @MainActor
        fileprivate func swapStreamIfChanged(to newURLs: [URL], newTitle: String, newSubtitle: String?) {
            guard let newURL = newURLs.first else { return }
            // urls.first is the URL the Coordinator is currently
            // playing (or just issued a swap toward); compare on the
            // absolute string form to dodge any URL-equality quirks
            // around trailing slashes or query order.
            if urls.first?.absoluteString == newURL.absoluteString { return }
            swapStream(to: newURL, newTitle: newTitle, newSubtitle: newSubtitle)
        }

        // MARK: - Switch Stream re-sync

        /// Posted by `SwitchStreamView` after a confirmed Dispatcharr Switch
        /// Stream. Reload ONLY if this coordinator is the one playing that
        /// channel's proxy URL — libmpv usually follows the in-place swap, but
        /// a dead upstream + Dispatcharr failover cascade desyncs it, so we
        /// reload to re-lock onto the fresh buffer.
        @objc fileprivate func switchStreamReprimeRequested(_ note: Notification) {
            guard let uuid = note.userInfo?["uuid"] as? String else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.urls.first,
                      current.absoluteString.contains("/proxy/ts/stream/\(uuid)") else { return }
                self.reprimeWithKeepalive(url: current, headers: self.headers,
                                          title: self.nowPlayingTitle, subtitle: self.nowPlayingSubtitle)
            }
        }

        /// Holds a SECOND bare client connection to the proxy stream open on a
        /// DEDICATED ephemeral session (never the shared API pool), waits for
        /// it to register, THEN forces a `loadfile replace` reload. The
        /// keepalive keeps the channel's client-count >= 1 across our reload so
        /// Dispatcharr's short shutdown delay doesn't tear the channel down and
        /// cold-revert it to the default stream. Best-effort: if the keepalive
        /// can't attach we reload anyway.
        @MainActor
        private func reprimeWithKeepalive(url: URL, headers: [String: String],
                                          title: String, subtitle: String?) {
            debugLog("[SwitchStream] \(streamTag): reload to re-sync libmpv onto the switched stream's buffer")
            let gate = ReprimeKeepaliveGate()
            // Dedicated ephemeral session: its connections never enter the
            // shared API pool, so this throwaway keepalive can't influence
            // which uwsgi worker a later change_stream lands on.
            let session = URLSession(configuration: .ephemeral)
            let keepalive = Task.detached(priority: .utility) {
                var req = URLRequest(url: url, timeoutInterval: 8)
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                // Distinct UA so this throwaway client is identifiable in
                // Dispatcharr logs and never collides with the playback client.
                req.setValue("AerioTV-switch-keepalive", forHTTPHeaderField: "User-Agent")
                do {
                    let (bytes, _) = try await session.bytes(for: req)
                    var first = true
                    for try await _ in bytes {
                        if first { first = false; await gate.markConnected() }
                        if Task.isCancelled { break }
                    }
                } catch {
                    // best-effort; the reload proceeds regardless
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { keepalive.cancel(); session.invalidateAndCancel(); return }
                // Wait (≤4s) for the keepalive to register before we reload
                // (which briefly drops the player's own connection).
                let deadline = Date().addingTimeInterval(4)
                while Date() < deadline {
                    if await gate.isConnected { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                self.swapStream(to: url, newTitle: title, newSubtitle: subtitle)
                // Hold the keepalive while our reload re-establishes, then drop it.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                keepalive.cancel()
                session.invalidateAndCancel()
            }
        }


        /// Called from `updateUIViewController`. Sends `mute=0` when
        /// the tile becomes audio-active, `mute=1` otherwise. No-op
        /// when the incoming value matches the last applied.
        @MainActor
        fileprivate func applyAudioFocusIfChanged(_ isActive: Bool) {
            guard lastAppliedAudioFocus != isActive else { return }
            // N<=1 short-circuit. At a single tile there is no audio-focus
            // competition, and crucially we must NOT issue an mpv property
            // write here for a freshly-loaded single-stream player: a write
            // during mpv's asynchronous initialize -> loadfile window can fail
            // the load (MPV_ERROR_LOADING_FAILED). Removing this skip is what
            // made VOD and recordings "not play at all" while multiview (N>1,
            // which never reaches this branch) kept working. The lone player is
            // set up with aid=auto + mute=no at options time, so skipping is
            // correct for genuine single-stream startup.
            //
            // EXCEPTION: the 2->1 collapse. When the user removes the AUDIO
            // tile, MultiviewStore promotes the surviving (previously
            // non-audio, mute=yes) tile to audio. That survivor's stream is
            // already loaded and playing, so a mute write is safe now; without
            // it the survivor stays silent. We detect this case via
            // lastWrittenMute == 1 (only a tile that was muted as a non-audio
            // multiview tile has that set; a fresh single-stream player has
            // lastWrittenMute == nil), and unmute it.
            if MultiviewStore.shared.tiles.count <= 1 {
                lastAppliedAudioFocus = isActive
                if isActive, lastWrittenMute == 1 {
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else { return }
                        var flag: Int32 = 0
                        mpv_set_property(mpv, "mute", MPV_FORMAT_FLAG, &flag)
                        self.lastWrittenMute = 0
                    }
                }
                return
            }
            lastAppliedAudioFocus = isActive
            DebugLogger.shared.log(
                "[MV-Audio] mpv audio=\(isActive ? "on" : "off") tile=\(tileID ?? "single")",
                category: "MPV-STREAM", level: .info
            )
            // v1.7.x: silencing strategy is now N-aware. Two
            // strategies, picked by current tile count:
            //
            // **mute-only** (`mute=yes`, audio decoder stays alive)
            //   Used when `tiles.count <= 6`. Audio packets keep
            //   decoding continuously on every tile, just muted at
            //   output. When the user switches audio focus the new
            //   tile's audio is already at the right PTS — `mute=no`
            //   resumes audio instantly at the current video
            //   position, no fast-forward, no AudioUnit re-init.
            //   This is the Apple-TV typical-multiview path; cost
            //   is N AudioUnits running silently (cheap on tvOS
            //   hardware — Apple TV 4K A15 handles 6 muted decoders
            //   without underruns in field testing).
            //
            // **silence + decoder-off** (`aid=no` + `mute=yes`)
            //   Used when `tiles.count >= 7`. Disables the audio
            //   track entirely — mpv stops decoding audio and
            //   closes the AudioUnit. This is the v1.6.12 fix for
            //   "Audio device underrun" spam across many
            //   concurrent muted tiles, each fighting the shared
            //   AVAudioSession with its own AudioUnit. The cost is
            //   the audio-focus switch incurs a re-init delay
            //   (~100-300ms AudioUnit open) plus mpv replays the
            //   demuxer's audio cache to catch up to current video
            //   PTS, producing a brief visible video fast-forward.
            //   Acceptable when N>=7 because the alternative is
            //   underrun-cascade video stalls; not acceptable at
            //   typical N where the user notices the lag.
            //
            // **History on the threshold:** v1.7.x originally set
            // the boundary at N>=5 (decoder-off strategy active for
            // N=5+ tiles). User testing on Apple TV 4K with N=6
            // (Archie, 2026-05-08) showed the decoder-off
            // fast-forward fires sporadically and is the dominant
            // audio-switch annoyance at that tile count, while the
            // mute-only path's underrun risk turned out not to
            // materialize on A15-class hardware up through N=6.
            // Bumped the boundary to N>=7 so typical multiview
            // sessions (most users sit at 4-6 tiles) get the
            // instant audio-switch UX. N>=7 retains the safety net
            // for edge cases where users run heavier configurations
            // on older / iPad-class devices that DO underrun.
            //
            // On audio-focus ACQUIRE either strategy clears its
            // suppressors:
            //   - mute-only: `mute=no` (audio already in sync).
            //   - silence + decoder-off: `aid=auto` re-runs track
            //     selection + opens AudioUnit, then `mute=no`.
            //
            // The per-property cache (`lastWrittenAID` /
            // `lastWrittenMute`) keeps duplicate writes from tearing
            // down + reopening the AudioUnit on benign Coordinator
            // re-entrancy. v1.6.12 patch.
            let useDecoderOffStrategy = MultiviewStore.shared.tiles.count >= 7
            let targetAID: String
            if useDecoderOffStrategy {
                targetAID = isActive ? "auto" : "no"
            } else {
                // mute-only path: keep audio decoder alive on every
                // tile so output toggles are instant. Set aid=auto
                // unconditionally; mute toggles do the silencing.
                targetAID = "auto"
            }
            let targetMute: Int32 = isActive ? 0 : 1
            // v1.7.x: track wall-clock time around the audio-focus
            // transition. Archie 2026-05-08 reported "occasional
            // freeze or delay" during rapid focus switching but
            // wasn't sure if it was AerioTV or upstream. Logging
            // the time from intent → mpvQueue dispatch → property
            // write completion lets us see (a) main-thread queue
            // depth at the moment, (b) mpvQueue serial-depth, and
            // (c) the AudioUnit reconfig latency. Anything > 200ms
            // total indicates the AudioUnit reopen is genuinely
            // slow on the device, which is the underlying
            // limitation we'd need a pre-seek-on-acquire to
            // address. Anything < 50ms but with user-perceived
            // delay points at the underlying stream's catch-up
            // (mpv replays cached audio when AID flips to auto).
            let intentTime = CFAbsoluteTimeGetCurrent()
            let strategy = useDecoderOffStrategy ? "decoder-off" : "mute-only"
            let tileCount = MultiviewStore.shared.tiles.count
            mpvQueue.async { [weak self] in
                let dispatchTime = CFAbsoluteTimeGetCurrent()
                guard let self, let mpv = self.activeMPVHandle() else { return }
                if self.lastWrittenAID != targetAID {
                    mpv_set_property_string(mpv, "aid", targetAID)
                    self.lastWrittenAID = targetAID
                }
                if self.lastWrittenMute != targetMute {
                    var flag = targetMute
                    mpv_set_property(mpv, "mute", MPV_FORMAT_FLAG, &flag)
                    self.lastWrittenMute = targetMute
                }
                let writeTime = CFAbsoluteTimeGetCurrent()
                let queueLatencyMs = (dispatchTime - intentTime) * 1000.0
                let writeLatencyMs = (writeTime - dispatchTime) * 1000.0
                let totalMs = (writeTime - intentTime) * 1000.0
                if totalMs > 50 {
                    #if DEBUG
                    debugLog("[MV-Audio] \(self.streamTag) focus=\(isActive ? "ACQUIRE" : "RELEASE") strategy=\(strategy) N=\(tileCount) queueLat=\(String(format: "%.1f", queueLatencyMs))ms writeLat=\(String(format: "%.1f", writeLatencyMs))ms total=\(String(format: "%.1f", totalMs))ms")
                    #endif
                }
            }
        }

        /// Called from `updateUIViewController`. Sends `pause=1` to
        /// freeze the tile (used by non-audio tiles while PiP is
        /// engaged on the audio tile) or `pause=0` to resume.
        ///
        /// This is a mpv-property toggle, not a re-seed. A paused
        /// live stream's decoder holds the last frame and resumes
        /// within ~1-2 seconds when pause goes back to 0 — no
        /// buffering penalty, no network re-handshake.
        @MainActor
        fileprivate func applyPauseIfChanged(_ paused: Bool) {
            // Debounced on BOTH transitions. A previous revision
            // tried to "always re-assert pause=false" as a defensive
            // fix for the "add-tile pauses the original channel"
            // bug, but that flooded `mpvQueue` with redundant
            // property writes during the 2nd-tile startup window,
            // which correlated 1:1 with user-reported
            // `stream-open` / `MPV_ERROR_LOADING_FAILED` when
            // adding multiview tiles (mpv's load pipeline is
            // asynchronous and sensitive to command ordering during
            // initialize→loadfile).
            //
            // If a real external-pause problem resurfaces, handle it
            // at the specific trigger (audio-session interruption
            // observer, tile-add event) rather than flooding the
            // property loop.
            let wasPaused = lastAppliedPause == true
            guard lastAppliedPause != paused else { return }
            lastAppliedPause = paused
            // Timestamp the pause entry so the unpause branch below can
            // measure dwell and skip the reload for brief pauses.
            if paused {
                pauseStartedAt = Date()
            } else {
                // Resuming: restart the stale-frame clock from now. During a
                // pause `lastEnqueueTime` freezes at the pre-pause frame, so
                // without this a pause longer than the stall/reload thresholds
                // would make the resume re-prime gap look like a 15s+ wedge and
                // flash the soft "Reconnecting…" card (and spuriously trip the
                // forced-reload sibling). The real first post-resume frame
                // overwrites this within a tick or two.
                lastEnqueueTime = CACurrentMediaTime()
            }
            DebugLogger.shared.log(
                "[MV-PiP] mpv pause=\(paused) tile=\(tileID ?? "single")",
                category: "MPV-STREAM", level: .info
            )
            setMPVFlag(property: "pause", value: paused)

            // Task #183: pause/resume flips report immediately so the
            // server's stats freeze/unfreeze at the right playhead. The
            // last stats-tick position (<=5s stale) is accurate enough
            // for stats; the periodic tick keeps the TTL fresh after.
            reportCatchupPositionIfDue(positionSecs: catchupLastKnownPositionSecs,
                                       paused: paused, force: true)

            // LIVE stream unpause → jump to live edge by reloading
            // the URL. Without this, resuming after a pause (e.g.
            // user opened the add-sheet to add another tile; every
            // existing tile paused; sheet closed; tiles resumed)
            // plays from the buffered-but-stale pause position,
            // leaving the tile N seconds behind live. User
            // explicitly requested that existing streams snap back
            // to LIVE when the add-sheet closes. `loadfile ... replace`
            // reconnects the stream cleanly at the current live
            // position; mpv's cache flushes and playback resumes
            // from the fresh connection point.
            //
            // Gated on `wasPaused && !paused && isLive`:
            //   - Skip on first paused=false (wasPaused=false, no
            //     prior pause to recover from).
            //   - Skip on paused=true (we're pausing, not resuming).
            //   - Skip on VOD (seeking to live makes no sense for
            //     a fixed-duration stream; resume-from-pause IS
            //     the correct VOD behaviour).
            //
            // Additional gate on pause DURATION: a multiview
            // tile-add fires isPickerPresented → true → every
            // existing tile pauses; picker dismisses ~1s later →
            // every tile unpauses. With N tiles and a rapid add
            // flow, the old code ran `loadfile replace` on every
            // tile for every add, producing cascading re-seed
            // storms (19s recovery on one tile observed after the
            // 9th add, because the reload hit
            // `Failed to recognize file format` mid-cascade).
            // mpv's live cache is typically 5s deep, so a <2s
            // pause doesn't leave us meaningfully behind live —
            // skip the reload entirely and let mpv resume from
            // cache. Long pauses (genuine idle) still snap.
            // Live Rewind: NO snap when the relay carries playback. Pause
            // is the feature (the buffer keeps filling underneath); resume
            // continues from the pause point like a cable box, and Go Live
            // is one press away. The reload here would also silently swap
            // mpv onto the direct URL while liveRewindActive stayed true,
            // stranding the transport/mapping on a buffer mpv left.
            if wasPaused && !paused && isLive, !liveRewindActive, !urls.isEmpty {
                let dwell = pauseStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                if dwell < Self.snapToLiveMinPauseSeconds {
                    #if DEBUG
                    debugLog("[MPV-DIAG] \(streamTag) unpause after \(String(format: "%.2f", dwell))s — skipping snap-to-live (brief pause, cache still fresh)")
                    #endif
                } else {
                    let url = urls[currentIndex]
                    #if DEBUG
                    debugLog("[MPV-DIAG] \(streamTag) unpause → reload live stream (snap to live edge, dwell=\(String(format: "%.1f", dwell))s)")
                    #endif
                    logStore.append("↻ MPV: unpause live → snap to live edge")
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else { return }
                        self.mpvCommand(mpv, ["loadfile", url.absoluteString, "replace"])
                    }
                }
            }
        }

        /// Shared mpvQueue hop for boolean mpv properties. Guards
        /// both the hop target (self/mpv weak-capture) and the
        /// shutdown flag so teardown-races resolve silently. Caller
        /// must already have applied its own last-value debounce.
        private func setMPVFlag(property: String, value: Bool) {
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.activeMPVHandle() else { return }
                var flag: Int32 = value ? 1 : 0
                mpv_set_property(mpv, property, MPV_FORMAT_FLAG, &flag)
            }
        }

        // MARK: - HDR detection (v1.7.x cadence-regression fix)

        /// Already-applied flag so we do not re-issue the property writes
        /// on every playback-restart (which can fire multiple times across
        /// a stream's lifetime - audio reconfig, cache underrun recovery,
        /// etc.). Reset on play(url:) AND swapStream so the next stream
        /// re-evaluates.
        private var hdrToneMappingApplied = false

        /// True once the CURRENT stream (this URL, this play/swap) has
        /// fired MPV_EVENT_PLAYBACK_RESTART at least once. The reload
        /// watchdogs (black-frame storm and stale-frame storm) gate on
        /// this so they fire ONLY for a stream that already reached
        /// steady playback and then wedged - never during the normal
        /// start-file -> probe -> first-frame window.
        ///
        /// Why this matters (Archie 2026-06-06 fast-flip field test):
        /// rapid channel-flipping reuses one mpv handle via loadfile
        /// replace, and the probe for a freshly-swapped stream legitimately
        /// drove AVSBDL stale time to 5425ms BEFORE playback-restart - a
        /// healthy flip that recovered on its own. Without this gate the
        /// 6s stale threshold would eventually misfire on a slightly
        /// slower probe, issuing a redundant loadfile mid-probe and making
        /// the flip worse. A slow probe is pre-restart (flag false -> no
        /// reload); a real post-underrun wedge is post-restart (flag true
        /// -> reload allowed). Reset on play(url:) and swapStream.
        private var hasReachedPlaybackRestartForStream = false

        /// Set the BT.709 SDR pin on the libmpv render target only when
        /// the current source actually needs it. The v1.7.3 fix that
        /// originally introduced these three options applied them
        /// unconditionally on the assumption "SDR -> SDR is a no-op";
        /// Archie's 2026-06-06 field test on ESPN HD showed that to be
        /// wrong on Apple TV - the BT.709 target pin forces mpv's render
        /// path through colorspace work on every frame even for an SDR
        /// source, and the extra cost surfaces as visible jitter on
        /// 30fps content (regression from v1.7.2).
        ///
        /// HDR detection uses mpv's `video-params/primaries` and
        /// `video-params/gamma`. A source is HDR if primaries reports
        /// `bt.2020` or gamma reports `pq` / `hlg` / `smpte2084`. mpv
        /// populates these properties at MPV_EVENT_PLAYBACK_RESTART
        /// time (after the stream's headers are parsed), which is when
        /// this is called from the event loop.
        ///
        /// Called only from MPV_EVENT_PLAYBACK_RESTART on the wakeup
        /// thread, so it is safe to read mpv properties here (unlike
        /// the render-update callback path).
        fileprivate func applyHDRToneMappingIfNeeded(mpv: OpaquePointer) {
            guard !hdrToneMappingApplied else { return }

            func mpvString(_ name: String) -> String {
                guard let raw = mpv_get_property_string(mpv, name) else { return "" }
                let s = String(cString: raw)
                mpv_free(raw)
                return s.lowercased()
            }
            let primaries = mpvString("video-params/primaries")
            let gamma = mpvString("video-params/gamma")
            let isHDR =
                primaries == "bt.2020"
                || gamma == "pq" || gamma == "smpte2084"
                || gamma == "hlg" || gamma == "arib-std-b67"

            if isHDR {
                // Pin the BT.709 SDR target so mpv runs the BT.2020 ->
                // 709 gamut map and the HDR -> SDR tone-map itself before
                // collapsing into our 8-bit BGRA FBO. Without this HDR
                // channels (Sky Sports Main Event UHD class) render green
                // and washed out - that was the original v1.7.3 fix
                // scenario, still preserved here.
                mpv_set_property_string(mpv, "target-prim", "bt.709")
                mpv_set_property_string(mpv, "target-trc", "bt.1886")
                mpv_set_property_string(mpv, "tone-mapping", "bt.2390")
                #if DEBUG
                debugLog("\(self.streamTag) [HDR] tone-map enabled: primaries=\(primaries) gamma=\(gamma)")
                #endif
            } else {
                #if DEBUG
                debugLog("\(self.streamTag) [HDR] SDR source detected (primaries=\(primaries) gamma=\(gamma)); leaving target-prim / target-trc / tone-mapping at mpv defaults")
                #endif
            }
            hdrToneMappingApplied = true
        }

        // mpv handles
        private struct PlaybackState {
            var mpv: OpaquePointer?
            var wakeupRetain: Unmanaged<Coordinator>?  // Balances passRetained in setupMPV
            var isShuttingDown = false
            var hwdecFallbackApplied = false
            /// Task #56: one-shot re-assert of videotoolbox-copy after mpv
            /// falls back to SOFTWARE decode. The fallback is permanent in
            /// mpv, but on live TS the trigger is usually transient (dirty
            /// mid-GOP join data poisoning the VT session, upstream mpv
            /// #9085/#9690); one retry after the next keyframe window
            /// recovers hardware decode. A genuinely VT-hostile stream gets
            /// exactly one extra attempt, then stays software.
            var hwdecReassertDone = false
            var isInBackground = false
            var autoPausedOnBackground = false
            // Live Rewind flags live in the locked state: they are
            // touched from the render queue (play routing), main
            // (swapStream), the mpv queue (seekAction, fallback), and
            // the event thread (end-file, pump).
            var liveRewindActive = false
            var liveRewindFallbackDirect = false
        }
        private var playbackState = PlaybackState()
        private var playbackStateLock = os_unfair_lock()
        private var mpv: OpaquePointer? {
            get { withPlaybackStateLock { $0.mpv } }
            set { withPlaybackStateLock { $0.mpv = newValue } }
        }
        private var wakeupRetain: Unmanaged<Coordinator>? {
            get { withPlaybackStateLock { $0.wakeupRetain } }
            set { withPlaybackStateLock { $0.wakeupRetain = newValue } }
        }
        private var mpvGL: OpaquePointer?  // mpv_render_context — owned by renderQueue
        private let mpvQueue = DispatchQueue(label: "com.aerio.mpv", qos: .userInteractive)

        private func withPlaybackStateLock<T>(_ body: (inout PlaybackState) -> T) -> T {
            os_unfair_lock_lock(&playbackStateLock)
            defer { os_unfair_lock_unlock(&playbackStateLock) }
            return body(&playbackState)
        }

        private func activeMPVHandle() -> OpaquePointer? {
            withPlaybackStateLock { state in
                guard !state.isShuttingDown else { return nil }
                return state.mpv
            }
        }

        /// Atomically marks shutdown and returns the mpv handle. Idempotent —
        /// returns nil on every call after the first so concurrent callers
        /// (e.g. stop() racing an unexpected MPV_EVENT_SHUTDOWN) can never
        /// both capture the handle.
        private func markShuttingDownAndSnapshotMPV() -> OpaquePointer? {
            // Read/clear the relay flag via the STATE FIELD, not the
            // locked property (os_unfair_lock is non-reentrant), and run
            // the engine teardown outside the lock.
            let (handle, hadRelay): (OpaquePointer?, Bool) = withPlaybackStateLock { state in
                guard !state.isShuttingDown else { return (nil, false) }
                state.isShuttingDown = true
                // Live Rewind: the buffer session dies with its player.
                // Buffered segments stay on disk for the retention
                // reaper (user spec: age-out, not session-scoped).
                let had = state.liveRewindActive
                state.liveRewindActive = false
                return (state.mpv, had)
            }
            if hadRelay { LiveRewindEngine.shared.stopSession() }
            return handle
        }

        private func takeMPVHandle() -> OpaquePointer? {
            withPlaybackStateLock { state in
                let handle = state.mpv
                state.mpv = nil
                return handle
            }
        }

        /// Atomically takes the wakeup retain. Used by both stop() and
        /// MPV_EVENT_SHUTDOWN so only one path ever calls retain.release().
        private func takeWakeupRetain() -> Unmanaged<Coordinator>? {
            withPlaybackStateLock { state in
                let r = state.wakeupRetain
                state.wakeupRetain = nil
                return r
            }
        }

        private func resetHwdecFallbackApplied() {
            withPlaybackStateLock {
                $0.hwdecFallbackApplied = false
                $0.hwdecReassertDone = false
            }
        }

        /// Task #56: claim the one-shot software->hardware retry.
        private func claimHwdecReassertIfNeeded() -> Bool {
            withPlaybackStateLock { state in
                guard !state.hwdecReassertDone else { return false }
                state.hwdecReassertDone = true
                return true
            }
        }

        private func claimHwdecFallbackIfNeeded() -> Bool {
            withPlaybackStateLock { state in
                guard !state.hwdecFallbackApplied else { return false }
                state.hwdecFallbackApplied = true
                return true
            }
        }

        private func markAutoPausedOnBackgroundIfNeeded() -> Bool {
            withPlaybackStateLock { state in
                guard !state.autoPausedOnBackground else { return false }
                state.autoPausedOnBackground = true
                return true
            }
        }

        private func takeAutoPausedOnBackground() -> Bool {
            withPlaybackStateLock { state in
                let wasAutoPaused = state.autoPausedOnBackground
                state.autoPausedOnBackground = false
                return wasAutoPaused
            }
        }

        /// The actual GL teardown work. MUST be invoked on `renderQueue`
        /// (either via `renderQueue.sync` or `renderQueue.async`). Clears
        /// libmpv's update callback, frees the FBO ring, flushes the texture
        /// cache, and frees the render context. Idempotent: once the first
        /// caller nils `mpvGL`/`eaglContext`, subsequent calls become no-ops.
        ///
        /// `mpv_render_context_free` is the expensive call here. Per libmpv's
        /// render.h contract it can block until the core releases the render
        /// context, and when the demuxer thread is parked on a network read of
        /// a not-yet-published live HLS segment the core stays busy, so the
        /// free can stall for seconds. That is fine on `mpvQueue` (the
        /// MPV_EVENT_SHUTDOWN path) but NOT on the main thread, which is why
        /// stop() runs this async off-main (see teardownRenderResourcesAsync).
        private func performRenderTeardownBody() {
            if let gl = mpvGL {
                mpv_render_context_set_update_callback(gl, nil, nil)
            }

            if let ctx = eaglContext {
                EAGLContext.setCurrent(ctx)
                if !fboSlots.isEmpty {
                    #if DEBUG
                    debugLog("[MPV-FBO] \(streamTag) destroy \(fboSlots.count)-deep pool (teardown, was \(fboWidth)x\(fboHeight))")
                    #endif
                    for i in 0..<fboSlots.count {
                        if fboSlots[i].fbo != 0 {
                            glDeleteFramebuffers(1, &fboSlots[i].fbo)
                        }
                    }
                    fboSlots = []
                    renderBufferIndex = 0
                }
                if let cache = textureCache { CVOpenGLESTextureCacheFlush(cache, 0) }
                EAGLContext.setCurrent(nil)
            }

            textureCache = nil
            eaglContext = nil

            if let gl = mpvGL {
                mpvGL = nil
                #if DEBUG
                debugLog("🧹 [Teardown] \(streamTag) mpv_render_context_free BEGIN (may block on stalled core)")
                let freeStart = CACurrentMediaTime()
                #endif
                mpv_render_context_free(gl)
                #if DEBUG
                debugLog("🧹 [Teardown] \(streamTag) mpv_render_context_free END after \(String(format: "%.0f", (CACurrentMediaTime() - freeStart) * 1000))ms")
                #endif
            }
        }

        /// Stops the IOSurface re-attach watchdog. Dispatched to main (the
        /// display link is main-thread). Idempotent: invalidate and the
        /// lock-protected buffer release inside stopWatchdog are both safe to
        /// call repeatedly. Shared by every teardown path.
        private func stopWatchdogOnMain() {
            Task { @MainActor [weak self] in
                self?.stopWatchdog()
            }
        }

        /// SYNCHRONOUS render teardown. Used ONLY by the MPV_EVENT_SHUTDOWN
        /// handler, which runs on `mpvQueue` where blocking on a stalled
        /// `mpv_render_context_free` is acceptable. Do NOT call this from the
        /// main thread (it would freeze the UI for in-progress HLS streams);
        /// the main-thread stop() path uses teardownRenderResourcesAsync.
        ///
        /// renderQueue -> mpvQueue is async-only, so this sync is deadlock-free
        /// from mpvQueue.
        private func teardownRenderResourcesOnRenderQueue() {
            stopWatchdogOnMain()
            #if DEBUG
            debugLog("🧹 [Teardown] \(streamTag) renderQueue.sync BEGIN (mpvQueue/SHUTDOWN path)")
            let t0 = CACurrentMediaTime()
            #endif
            renderQueue.sync { [self] in
                performRenderTeardownBody()
            }
            #if DEBUG
            debugLog("🧹 [Teardown] \(streamTag) renderQueue.sync END after \(String(format: "%.0f", (CACurrentMediaTime() - t0) * 1000))ms")
            #endif
        }

        /// ASYNCHRONOUS render teardown. Used by stop() (main thread). Runs the
        /// GL teardown on `renderQueue` so the potentially-blocking
        /// `mpv_render_context_free` never pins the main thread, then invokes
        /// `completion` on `mpvQueue`. stop() chains `mpv_terminate_destroy`
        /// through that completion so the required ordering
        /// (render_context_free completes BEFORE terminate_destroy) is
        /// preserved without a fixed timer.
        private func teardownRenderResourcesAsync(completion: @escaping @Sendable () -> Void) {
            stopWatchdogOnMain()
            #if DEBUG
            debugLog("🧹 [Teardown] \(streamTag) renderQueue.async DISPATCH (off-main stop() path)")
            #endif
            renderQueue.async { [weak self] in
                guard let self else { return }
                #if DEBUG
                debugLog("🧹 [Teardown] \(self.streamTag) renderQueue.async BEGIN body")
                let t0 = CACurrentMediaTime()
                #endif
                self.performRenderTeardownBody()
                #if DEBUG
                debugLog("🧹 [Teardown] \(self.streamTag) renderQueue.async END body after \(String(format: "%.0f", (CACurrentMediaTime() - t0) * 1000))ms → terminate_destroy on mpvQueue")
                #endif
                // Hop to mpvQueue for the destroy step. renderQueue -> mpvQueue
                // is async-only (never sync the other direction), so this is
                // deadlock-free.
                self.mpvQueue.async {
                    completion()
                }
            }
        }

        // OpenGL ES render — GPU renders to CVPixelBuffer via IOSurface-backed FBO (zero copy)
        private let renderQueue = DispatchQueue(label: "com.aerio.mpv.render", qos: .userInteractive)
        private weak var sampleBufferLayer: AVSampleBufferDisplayLayer?  // vsync-synchronized display
        // Cached renderer for the off-main render/diagnostics paths.
        // Captured exactly once on the main actor in setupRenderer(layer:)
        // (right after sampleBufferLayer is assigned), then read from the
        // render queue (renderAndPresent) and mpvQueue (printDiagnostics).
        // AVSampleBufferVideoRenderer is not Sendable; the enqueue path is
        // externally serialized on renderQueue, matching the contract the
        // top-of-file `@preconcurrency import AVFoundation` documents.
        private nonisolated(unsafe) var cachedRenderer: AVSampleBufferVideoRenderer?
        private var eaglContext: EAGLContext?
        private var textureCache: CVOpenGLESTextureCache?
        // v1.7.x Step 5 — triple-buffered FBO ring.
        //
        // Prior single-buffer architecture (one CVPixelBuffer + one
        // GL texture + one FBO, recreated per resolution) produced
        // occasional single-VSync black flashes on UHD HEVC HDR live
        // MPEG-TS playback (Sky Sports Main Event UHD class). Field
        // tests through Steps 3a / 3a-tighten / 3b / 3b-lookahead /
        // 4a all confirmed the pattern: SwiftUI overlays stay drawn
        // while the AVSampleBufferDisplayLayer area goes pitch black
        // for one VSync. The detector at line ~2537 logged
        // `black_supp=0` on tests where flashes were visible, proving
        // the buffer was NOT zero at our detection time but WAS zero
        // when AVSBDL composed it.
        //
        // Root cause: producer/consumer race on a single shared
        // IOSurface. mpv writes frame N+1 to the same IOSurface
        // AVSBDL is about to read for VSync M. mpv's glClear at the
        // start of its render pass leaves the IOSurface temporarily
        // black. If AVSBDL composes during that sub-millisecond
        // window, the layer renders black for that VSync. Step 4a's
        // DisplayImmediately made it 5x worse (1 per 2.4s vs 1 per
        // ~12s baseline) by removing AVSBDL's implicit hold time
        // before composing — confirming the race hypothesis.
        //
        // Triple-buffered ring breaks the race: mpv writes to
        // slot[renderBufferIndex], we hand that slot's pixel buffer
        // to AVSBDL, then advance the cursor. By the time mpv comes
        // back to this slot (after writing two other slots), AVSBDL
        // has long since composed and released its reference. The
        // watchdog's `lastEnqueuedSampleBuffer` cache is also safe:
        // it points at most one slot behind mpv's write position,
        // and mpv is two slots ahead before wrapping.
        //
        // Memory cost (UHD BGRA 3840x2160): 33MB per slot, ~99MB
        // total per single-stream UHD instance. Multiview tiles
        // render at much smaller resolutions (typically 640-960
        // wide), so per-tile cost is ~5-10MB total.
        private struct FBOSlot {
            var pixelBuffer: CVPixelBuffer
            var texture: CVOpenGLESTexture
            var fbo: GLuint
        }
        private static let fboPoolSize = 3
        private var fboSlots: [FBOSlot] = []
        private var renderBufferIndex: Int = 0
        private var fboWidth: Int = 0
        private var fboHeight: Int = 0
        /// Detected stream FPS — used for diagnostics.
        private var detectedFps: Double = 0

        #if os(tvOS)
        // MARK: - Display refresh-rate matching (task #186)
        //
        // Apple's automatic "Match Content" only engages for AVPlayer
        // playback. Our tvOS video path is libmpv -> AVSampleBufferDisplayLayer,
        // which AVKit knows nothing about, so European 50fps live streams
        // played on a 60Hz-defaulted Apple TV judder forever (field report
        // alturismo 2026-07-18 was Android, but tvOS had the same hole with
        // ZERO matching code). The manual path: set
        // window.avDisplayManager.preferredDisplayCriteria and tvOS performs
        // the same mode switch AVPlayer would get -- still gated by the
        // user's Settings > Video and Audio > Match Content setting, so
        // users who left matching off see no change.
        //
        // Fullscreen single-stream only: multiview tiles at mixed rates
        // must not fight over the panel mode. Under the unified player the
        // sole fullscreen stream runs as a tile (tileID non-nil), so the
        // gate is the live tile count, not tileID == nil -- that guard
        // silently killed frame-rate matching on every live stream (Sky
        // Sports UHD 50fps on a 60Hz panel, drops+stutter, 2026-08-07).

        /// Refresh rate last written to preferredDisplayCriteria. Written on
        /// main; read cross-queue only as a cheap dedup pre-check (a torn
        /// read just costs one redundant main-queue hop).
        private var appliedDisplayRefreshRate: Float = 0
        /// The display manager we applied criteria to, so stop()/deinit can
        /// clear it even after the view has left the window.
        private weak var appliedDisplayManager: AVDisplayManager?

        /// Rates a physical panel can actually be asked for. Measured fps is
        /// snapped to the nearest entry (mpv's estimated-vf-fps for a 50fps
        /// DVB feed reads e.g. 49.98).
        private static let canonicalVideoRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

        private func applyDisplayCriteriaIfNeeded(fps: Double) {
            guard fps > 20, fps < 130 else { return }
            guard let rate = Self.canonicalVideoRates.min(by: { abs($0 - fps) < abs($1 - fps) }),
                  abs(rate - fps) <= 0.75 else { return }
            // Only ever ask for the 50 / 59.94 / 60 class: 25 / 29.97 / 30
            // content is requested at DOUBLE rate (clean 2:2 cadence on a
            // mode the UI can live on). Requesting sub-mode rates directly
            // caused a pathological low-rate presentation state on Android
            // (janky UI + repeated visible video dropouts, Logan's Hisense
            // 2026-07-18); mirror the safe mapping here. 23.976 / 24 film
            // cadence is deliberately not requested (divides neither 50 nor
            // 60) until handled on purpose.
            let doubled: Double
            switch rate {
            case 25, 29.97, 30: doubled = rate * 2
            case 50, 59.94, 60: doubled = rate
            default: return
            }
            let target = Float(doubled)
            // Cross-queue pre-check; the authoritative dedup re-runs on main.
            if abs(appliedDisplayRefreshRate - target) < 0.01 { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // `viewController` is only wired on iOS (the PiP path); on
                // tvOS it is ALWAYS nil, which silently killed every
                // criteria request since the representable rework (channel
                // 35 UHD judder, 2026-08-07). tvOS is single-window - the
                // foreground scene's key window is the right fallback.
                let window: UIWindow? = self.viewController?.viewIfLoaded?.window
                    ?? UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first(where: { $0.activationState == .foregroundActive })?
                        .keyWindow
                guard let window else {
                    debugLog("[MPV-DISPLAY] skipped \(target)Hz: no window available")
                    return
                }
                // Solo fullscreen only: 2+ live tiles at mixed rates must
                // not fight over the panel mode.
                let tileCount = MainActor.assumeIsolated { MultiviewStore.shared.tiles.count }
                guard tileCount <= 1 else { return }
                let dm = window.avDisplayManager
                if self.appliedDisplayManager === dm,
                   abs(self.appliedDisplayRefreshRate - target) < 0.01 { return }
                let info = self.progressStore.streamInfo
                let codecName = info.videoCodec.lowercased()
                let codec: CMVideoCodecType =
                    (codecName.contains("hevc") || codecName.contains("h265") || codecName.contains("265"))
                    ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
                var fd: CMVideoFormatDescription?
                // No color extensions: the mpv render path tone-maps to SDR,
                // so the panel must NOT be asked for an HDR mode here even
                // when the source is HDR.
                CMVideoFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    codecType: codec,
                    width: info.width > 0 ? Int32(info.width) : 1920,
                    height: info.height > 0 ? Int32(info.height) : 1080,
                    extensions: nil,
                    formatDescriptionOut: &fd)
                guard let fd else { return }
                self.appliedDisplayManager = dm
                self.appliedDisplayRefreshRate = target
                dm.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: target,
                                                                formatDescription: fd)
                debugLog("[MPV-DISPLAY] preferredDisplayCriteria \(target)Hz " +
                         "(measured \(String(format: "%.2f", fps))fps, " +
                         "matchingEnabled=\(dm.isDisplayCriteriaMatchingEnabled))")
                // Verify the panel actually honored the request (Match
                // Content HDMI re-handshakes take 1-2s), and hand the real
                // rate to mpv: with display fps unknown ("display=0.0" in
                // MPV-PERF) its framedrop estimator runs blind and the
                // Stream Info drops counter counts phantom drops even when
                // the layer presents every frame on time (ch 35 soak,
                // 2026-08-07: late=1/14400 yet vo_drops +125/15s).
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak window] in
                    guard let self, let screen = window?.screen else { return }
                    let hz = screen.maximumFramesPerSecond
                    debugLog("[MPV-DISPLAY] panel reports \(hz)Hz 3s after criteria request")
                    if let mpv = self.activeMPVHandle() {
                        var d = Double(hz)
                        mpv_set_property(mpv, "display-fps-override", MPV_FORMAT_DOUBLE, &d)
                    }
                }
            }
        }

        /// Release our mode preference so the UI returns to the panel
        /// default. Safe to call from any thread and repeatedly.
        private func clearDisplayCriteria() {
            let dm = appliedDisplayManager
            appliedDisplayManager = nil
            appliedDisplayRefreshRate = 0
            guard dm != nil else { return }
            DispatchQueue.main.async {
                dm?.preferredDisplayCriteria = nil
            }
        }
        #endif

        private var renderWidth: Int = 0
        private var renderHeight: Int = 0
        private var videoNativeWidth: Int = 0   // Video's display width (for render sizing)
        private var videoNativeHeight: Int = 0

        // Failover & retry state (identical to VLC coordinator)
        private var currentIndex = 0
        private var hasStarted = false
        private var anyAttemptStarted = false
        private var hasPerformedWarmupRetry = false
        private var playbackStartTime: Date?
        private var sameURLRetryCount = 0
        private let maxSameURLRetries = 3
        /// Retry counter for `MPV_ERROR_LOADING_FAILED` (error -13).
        /// Typically fired when the Dispatcharr proxy returns HTTP 503
        /// under concurrent-tile-load pressure (9 tiles hit the server
        /// simultaneously and some get throttled). Before this counter
        /// existed the tile would show "Decoder unavailable" permanently
        /// even though expanding to full-screen — a single request —
        /// would succeed. Now we retry up to 3 times with exponential
        /// backoff + random jitter (so 9 tiles don't all retry at the
        /// same wall-clock moment and trigger the same thundering-herd
        /// 503 again). Reset on every playback-restart (successful
        /// start of a new stream).
        private var loadFailureRetryCount = 0

        /// v1.7.x Phase 4: retry budget is URL-aware. Live streams
        /// keep the historical 3 retries (~7s total budget — fits
        /// transient 503/network blips). Recording URLs get 5
        /// retries (~93s total budget) since in-progress recordings
        /// can be locked or queued behind a server warmup window.
        private var maxLoadFailureRetries: Int { isRecordingURL ? 5 : 3 }

        /// v1.7.x Phase 4: per-attempt delay multiplier. Live keeps
        /// 1× (1s, 2s, 4s base). Recording uses 3× (3s, 6s, 12s,
        /// 24s, 48s) so the server has room to recover from the
        /// kind of overload that produces fail-fail-fail-then-
        /// succeed patterns on parallel VOD load + recording open.
        private var loadFailureBackoffMultiplier: Double { isRecordingURL ? 3.0 : 1.0 }

        /// True when the current playback URL points at a
        /// Dispatcharr in-progress / completed recording's
        /// `/file/` endpoint. Drives the longer retry budget +
        /// backoff above. Detected by URL path (no need for the
        /// caller to thread an `isRecording` flag through).
        ///
        /// v1.7.x: looks at the URL we're actively playing
        /// (`urls[currentIndex]`) rather than `urls.first`. All
        /// current callers pass single-URL playlists, but a
        /// future failover-aware caller could pass a multi-URL
        /// list with the recording at index 1+; the first form
        /// would silently misclassify and apply the live-stream
        /// retry budget instead.
        private var isRecordingURL: Bool {
            guard urls.indices.contains(currentIndex) else { return false }
            let url = urls[currentIndex]
            return url.path.contains("/recordings/") && url.path.hasSuffix("/file/")
        }
        private var isShuttingDown: Bool {
            get { withPlaybackStateLock { $0.isShuttingDown } }
            set { withPlaybackStateLock { $0.isShuttingDown = newValue } }
        }
        // Diagnostics
        private var diagStartTime: Date?
        private var prevDroppedFrames: Int64 = 0
        private var prevDecoderDrops: Int64 = 0
        private var lastTimePrint: Date = .distantPast
        private var lastProgressUpdate: Date = .distantPast
        private var timeChangeCount: Int = 0
        private var bufferEnteredTime: Date?
        private var totalBufferingDuration: TimeInterval = 0
        private var bufferEventCount: Int = 0
        private var audioUnderrunCount: Int = 0
        private var setupStartTime: Date?
        private var lastProgressSave: Date = .distantPast  // Debounce VOD progress saves to every 10s
        private var hasAttemptedResume = false  // Only auto-seek once per playback session
        private var playbackEnded = false      // Guard against seek-after-EOF
        // renderPending: accessed from mpv callback thread + render thread — use lock
        private var renderPending = false
        private var renderLock = os_unfair_lock()

        // Render/VO-configuration handshake (Codex fix for the Debug-only
        // VOD/DVR `vo-configured=0` wedge). The libmpv VO (vo=libmpv) only
        // reaches "configured" once we actually call mpv_render_context_render
        // against a valid FBO. For a sparse-callback non-live source, the old
        // loop could consume the one update edge before the FBO existed and
        // then bail forever on "no FRAME flag", so the VO never configured and
        // playback-restart hung (seeking=1, current-ao=nil). These flags let us
        // do ONE bounded config-commit render after each FBO (re)build even
        // when no new frame is pending, then resume normal frame-gated
        // rendering. Touched only on renderQueue.
        private var renderTargetNeedsCommit = false   // set when an FBO is (re)built; cleared after the commit render
        private var didCommitRenderTarget = false      // true once mpv_render_context_render has run against a valid FBO
        private var didEnqueueFirstVideoFrame = false   // true once a real frame has been enqueued to the display layer

        // Stream info refresh timer (2s interval for volatile stats).
        // Runs on its own low-priority queue — NEVER on renderQueue (would block frame delivery).
        private var streamInfoTimer: DispatchSourceTimer?
        private let statsQueue = DispatchQueue(label: "com.aerio.mpv.stats", qos: .utility)

        // Frame timing — jitter & tearing diagnostics
        private var lastRenderTime: CFAbsoluteTime = 0       // When last frame finished rendering
        private var lastEnqueueTime: CFAbsoluteTime = 0      // When last frame was enqueued to display layer
        private var frameIntervals: [Double] = []             // Recent inter-frame intervals (ms)
        private var renderDurations: [Double] = []            // Recent render durations (ms)
        private var lateFrameCount: Int64 = 0                 // Frames that took longer than expected
        private var totalFrameCount: Int64 = 0                // Total frames rendered
        private var coalescedFrameCount: Int64 = 0            // Render requests coalesced (dropped)
        private let frameSampleSize = 120                     // Rolling window size (~2-4s at 30-60fps)

        // v1.7.x black-flash diagnostics. Cleared on successful enqueue
        // so a transient blip doesn't carry forward into a future event.
        // Logged on first occurrence + every 30th to capture sustained
        // failure runs without spamming.
        private var layerFailedFrameCount: Int64 = 0          // Foreground sample-buffer-renderer .failed events
        private var makeSampleBufferNilCount: Int64 = 0       // CMSampleBuffer construction failures

        // v1.7.x Issue A round 3 diagnostics — track AVSBDL state
        // transitions, since Archie's 2026-05-08 screen recording
        // showed single-VSync solid-black flashes during libmpv
        // render stalls even though our renderer.status stayed at
        // .rendering throughout. Hypothesis: AVSampleBufferDisplay
        // Layer is internally clearing (or flagging requiresFlush)
        // during the queue-empty window. These two trackers log the
        // moment the layer transitions, so the next test log can
        // confirm or rule out the hypothesis.
        private var lastObservedLayerStatus: AVQueuedSampleBufferRenderingStatus = .unknown
        private var lastObservedRequiresFlush: Bool = false

        // v1.7.x Issue A diagnostics — UHD / 10-bit HEVC blue screen
        // (pre-first-frame) and periodic black flashes (mid-stream).
        // The blue screen correlates with the
        // videotoolbox → videotoolbox-copy fallback (~1.5s gap before
        // any frame). The black flashes correlate with bursts of
        // MPV_EVENT_VIDEO_RECONFIG events that destroy and rebuild
        // the OpenGL FBO mid-stream. These counters let us prove or
        // disprove that correlation rather than guessing.
        //
        // Per-window counters reset on every video-reconfig so each
        // window's "decoder error signature" is independently visible
        // in the log. Cumulative totals are kept alongside for
        // post-hoc correlation across an entire session.
        private var lastVideoReconfigAt: CFAbsoluteTime = 0
        /// #37 (OTA): timestamp of the last MID-STREAM resolution change
        /// (not the initial config). OTA broadcasts switch resolution at
        /// commercial boundaries, which stalls the HDHomeRun feed for a
        /// few seconds; without a grace window the stale-frame storm
        /// watchdog mistakes that stall for a wedge and issues a `loadfile
        /// replace` - the "stream stopping and restarting" + extended
        /// black the reporter saw. Stamped only on a real change (the
        /// previous size was already known), so same-resolution streams
        /// are unaffected and genuine wedges on them still reload normally.
        private var lastResolutionChangeAt: CFAbsoluteTime = 0
        /// Grace after a resolution change during which the stale-frame
        /// storm reload is suppressed, letting the stream finish the
        /// switch on its own. GUESSED at 12s to cover the OTA switch plus
        /// the proxy re-establishing; tune against a real OTA log.
        private let resolutionChangeReloadGraceSec: CFTimeInterval = 12.0
        private var videoReconfigCount: Int64 = 0
        private var lastHwdecCurrentObserved: String = ""

        // v1.7.x Step 7 — audio reconfig + callback-gap correlation.
        //
        // Codex's CODEX_UHD_STUTTER_AVSYNC_NEXT_STEPS_2026-05-08.md
        // recommends correlating MPV_EVENT_AUDIO_RECONFIG with
        // MPV-CALLBACK-GAP events: AC3 audio for live MPEG-TS often
        // reconfigs when the broadcast switches between mono/stereo/
        // 5.1 segments, and each reconfig may cause a brief libmpv
        // pause. The 22:04 field-test log showed three audio-reconfig
        // events plus four 200ms callback gaps mid-playback; if the
        // pairs reliably coincide we have a concrete next direction
        // (audio path tuning). If they don't, network/decoder is the
        // suspect.
        //
        // `lastAudioReconfigAt` is stamped in the dispatcher when
        // MPV_EVENT_AUDIO_RECONFIG fires (currently routed through
        // the `default:` case, which just prints "Event: audio-
        // reconfig"). On each MPV-CALLBACK-GAP we log
        // `since_audio_reconfig=Nms` so future readers can grep for
        // gaps that arrived within ~100ms of an audio reconfig.
        private var lastAudioReconfigAt: CFAbsoluteTime = 0
        private var audioReconfigCount: Int64 = 0

        /// Issue #36 (no audio when the tvOS output is Dolby Atmos): one-shot
        /// post-restart audio health check + stereo-downmix fallback. Reset
        /// per stream in handleStartFile(); re-armed by audio route changes
        /// so toggling Atmos mid-app recovers without a restart.
        private var audioHealthCheckScheduled = false
        private var audioStereoFallbackApplied = false

        // v1.7.x Step 7 — callback-gap severity counters.
        //
        // Cumulative tallies of the gap classifications already
        // emitted at line ~2455 (mild 50-100ms, moderate 100-300ms,
        // severe 300ms+). Surfaced in FRAME SUMMARY so we can see
        // whether gaps are clustered (one bad reconfigure window) or
        // chronic (steady-state decoder issue). The 22:04 test had
        // ~5 moderate-class gaps in a 5-second window — strongly
        // clustered, suggesting episodic root cause rather than
        // continuous instability.
        private var callbackGapMildCount: Int64 = 0
        private var callbackGapModerateCount: Int64 = 0
        private var callbackGapSevereCount: Int64 = 0

        // Per-reconfig-window decoder error counts. These are tallied
        // BEFORE `isNoisyRecoveryMessage` filters them out of the
        // visible log, so we can see decoder error storms even when
        // the underlying lines are filtered to keep the console
        // legible during normal playback.
        private var ppsErrorWindow: Int64 = 0          // SPS/PPS missing or out-of-range
        private var naluErrorWindow: Int64 = 0         // Skipping invalid undecodable NALU
        private var hwdecErrorWindow: Int64 = 0        // VT decode hiccups
        private var vtNullBufferWindow: Int64 = 0      // VT output buffer null

        // Cumulative for full-session correlation. These never reset.
        private var ppsErrorTotal: Int64 = 0
        private var naluErrorTotal: Int64 = 0
        private var hwdecErrorTotal: Int64 = 0
        private var vtNullBufferTotal: Int64 = 0

        // FBO lifecycle timing — answers "is the user-visible black
        // flash a window where the FBO doesn't exist yet?" If
        // fboDestroyedAt is recent (< 50ms) when a video-reconfig
        // fires, we know the layer is presenting nothing for the
        // rebuild gap.
        private var fboDestroyedAt: CFAbsoluteTime = 0

        // v1.7.x Issue A round 4: CoreAnimation IOSurface re-attach
        // watchdog. Three pieces of research (AVSBDL/HDR, libmpv,
        // other iOS players, all 2026-05-08) converged on the same
        // root cause: AVSampleBufferDisplayLayer is a CALayer subclass
        // that publishes its current frame as an IOSurface attached
        // to the layer tree. When our enqueue stops feeding fresh
        // PTS values long enough (which happens during the 60-100ms
        // libmpv render stalls confirmed in the logs), CoreAnimation's
        // change-detection optimizer can drop the surface attachment
        // for one VSync. With HDR content (BT.2020 / p010), the EDR
        // composition path falls back to backgroundColor (black) for
        // that VSync instead of holding a clamped SDR copy of the
        // last frame, producing exactly the user-visible single-frame
        // black flashes Archie reproduced and verified via 60fps
        // screen capture (avg=0, std=0 single VSyncs).
        //
        // The fix is the standard "feed the layer at display refresh"
        // pattern used by moonlight-ios PR #482 and WebKit's MSE
        // backend (Bug 181623). A CADisplayLink ticks at the display
        // refresh rate; on each tick, if the layer hasn't received a
        // fresh enqueue in `watchdogStaleThreshold` seconds, we
        // re-enqueue the most recent CMSampleBuffer with a fresh
        // host-time PTS. That forces CoreAnimation to attach the
        // IOSurface as a new contents reference every VSync,
        // defeating the change-detection optimizer that drops the
        // attachment during gaps. The IOSurface backing is already
        // valid; we're just kicking the compositor.
        //
        // Architecturally-correct fix (v1.8 candidate, NOT shipping
        // here): migrate the display path to AVSampleBufferVideo
        // Renderer + AVSampleBufferRenderSynchronizer (iOS 17+,
        // documented at developer.apple.com). That's how AVPlayer
        // avoids this symptom natively. Significant rewrite, deferred.
        private var displayLinkWatchdog: CADisplayLink?
        private var watchdogLock = os_unfair_lock_s()
        private var lastEnqueuedSampleBuffer: CMSampleBuffer?
        // Floor for the watchdog stale threshold. Original purpose was
        // to mask single-VSync black flashes (~16ms), so 30ms is the
        // minimum a re-enqueue triggers at. v1.7.4.x community feedback
        // (madplanet, UK 50Hz / 25fps content; sjsteve, Apple TV Live)
        // showed continuous re-enqueue activity on streams whose natural
        // frame interval already exceeds 30ms - the watchdog was firing
        // between EVERY real frame, doubling per-frame main-thread work
        // (CMSampleBufferCreateCopyWithNewTiming + renderer.enqueue) on
        // an already-thermal-stressed Apple TV. effectiveThreshold below
        // scales the floor by container fps so a 25fps stream gets ~60ms,
        // a 30fps gets 50ms, and 60fps stays at 30ms.
        private let watchdogStaleThresholdFloor: CFTimeInterval = 0.030  // 30ms
        /// Container fps observed from `container-fps` in the perf-log
        /// pump, used to scale the watchdog threshold per-stream. 0 means
        /// "no measurement yet" - the watchdog uses the floor in that
        /// case. Updated on the main actor (perf-log pump hops to main),
        /// read on the main actor (CADisplayLink tick is main).
        private var containerFpsHint: Double = 0
        // Cumulative count of watchdog-driven re-enqueues, exposed
        // in FRAME SUMMARY so we can see how often the watchdog
        // saved a flash. Field-only diagnostic; non-zero means the
        // watchdog is doing real work.
        private var watchdogReenqueueCount: Int64 = 0

        // v1.7.x Step 6 — backpressure skip counter. Incremented
        // each time `renderAndPresent` early-returns because
        // AVSampleBufferDisplayLayer's renderer reported
        // `isReadyForMoreMediaData == false`. Exposed in FRAME
        // SUMMARY. Field-only diagnostic; non-zero means mpv is
        // producing frames faster than AVSBDL is consuming them
        // (typical for fast hardware decoders on UHD content),
        // and we're correctly rate-limiting via mpv's
        // `framedrop=vo` policy by NOT calling
        // mpv_render_context_render — mpv's internal queue
        // fills, framedrop drops the late frames at the VO
        // boundary, and the upstream demuxer/decoder pipeline
        // is rate-limited to AVSBDL's consumption rate.
        private var backpressureSkipCount: Int64 = 0

        // v1.7.x Issue A round 6 — black-frame detector (Step 3a).
        //
        // The 2026-05-08 fully-applied Step 2 test confirmed mpv's
        // VideoToolbox path occasionally emits a frame whose backing
        // CVPixelBuffer is uniformly zero — luminance avg=0, std=0
        // mathematically — interspersed in an otherwise smooth frame
        // stream (late=0/2954, vo_drops=0, dec_drops=0). 17 such
        // frames in 76s of UHD HEVC HDR playback (~1 every 4.5s).
        // Surrounded by normal content frames (avg 25-130). The bug
        // is inside libmpv's render or VT codepath — from outside
        // libmpv we can't reach it. This detector catches them on
        // input, before we wrap them into a CMSampleBuffer for the
        // display layer. The CADisplayLink watchdog above already
        // handles "queue stale" by re-enqueueing the last good
        // CMSampleBuffer with a fresh PTS — so suppressing here just
        // means the user sees the previous frame held for one mpv-
        // frame-interval (~16ms) instead of a literal black flash.
        //
        // Detection (per Agent C 2026-05-08 research): stratified
        // 16x16 grid sample of the BGRA pixel buffer = 256 luminance
        // samples. Compute avg + std using Rec.601 luma weights
        // (cheap on Apple silicon, <0.5ms on UHD). Trigger when
        // avg < 10 AND std < 8 AND prev frame's avg > 25 AND prev-
        // prev avg > 20. The two-deep surround check (prev AND
        // prev-prev were both bright) prevents suppressing a
        // legitimate cut-to-black transition that lasts more than
        // one frame.
        //
        // v1.7.x 3a-tighten (2026-05-08): initial release shipped
        // with avg<4 AND std<1, calibrated for pure codec-zero
        // (all bytes mathematically zero). Verification recording
        // showed the bug also produces near-uniform-zero buffers
        // with small partial-render slivers carried over from the
        // previous frame, which pushes both avg and std above the
        // tight thresholds: one observed leak had YAVG=7 and would
        // never have hit avg<4. Loosened to avg<10 AND std<8 to
        // catch the partial-corruption class. Real dark content
        // sits at YAVG 16-30 on limited-range YCbCr with sensor
        // noise pushing std above 8, so the surround check
        // (prev_avg > 25, prev_prev_avg > 20) is what actually
        // protects legitimate dark content; the avg/std numbers
        // are just the "is this frame degenerate" filter.
        private var blackFramePrevAvgLuma: Double = 128  // neutral start so first frames don't suppress
        private var blackFramePrevPrevAvgLuma: Double = 128
        private var blackFramesSuppressedCount: Int64 = 0

        // v1.7.x stale-frame reload watchdog threshold.
        //
        // Sibling to the black-frame-storm threshold below. Archie's
        // 2026-06-06 second test (Sky Sports Football HD) showed an
        // audio underrun cascade that DID NOT produce a black-frame
        // storm - instead mpv just stopped delivering frames for ~18
        // seconds while AVSBDL kept re-enqueuing the last good frame
        // (stale=12301ms by the last log line before the user gave up
        // and channel-flipped). cache=6.98s and network=1197KB/s
        // throughout, so the upstream was healthy; mpv's internal
        // pipeline was wedged. Same root cause as the black-frame
        // storm, different symptom.
        //
        // 6-second threshold, MEASURED from the same field log, not
        // guessed. The same session's NORMAL channel-flip probes (the
        // ones that recovered fine on their own) drove AVSBDL stale
        // time up to `re-enqueue #480 (stale=3023ms)` during a healthy
        // flip back to Action HD - mpv was simply probing the new
        // stream (analyzeduration=1.5s + network) and frames flowed
        // right after. A 3s threshold would have misfired there,
        // issuing a redundant loadfile mid-probe and making the flip
        // SLOWER. The actual wedge (Football HD post-underrun) climbed
        // monotonically past that to stale=12301ms with no recovery.
        // 6.0s originally sat at 2x the worst observed normal-probe stale.
        // RAISED to 12.0s for #37 (Glitzbr 2026-06-17 multiview OTA log): an
        // OTA commercial boundary stalls decoded-frame OUTPUT for ~6s (decoder
        // reconfig) while the demuxer cache stays healthy (3-7s, underruns=0),
        // so 6s fired on a stall that self-recovers and the loadfile-replace
        // then made it WORSE - each reload fails fast and forces a ~4-5s
        // re-open, and in multiview the reload work starved sibling tiles into
        // a cascading reload loop for the whole break. 12s sits above the ~8s
        // reconfig self-recovery yet still catches the genuine ~18s mpv wedge
        // that motivated this watchdog. Gated by !paused (a user pause is
        // never force-reloaded), by the #37 resolution-change grace, by the
        // per-stream reload backoff, and by the user Auto-Recover toggle.
        private let staleFrameStormThresholdSec: CFTimeInterval = 12.0

        // Live "stream stalled" REPORT thresholds (2026-07-13). When the
        // stale-frame reload above fires at 12s and does NOT recover, the
        // picture stays frozen while the buffer relay + LAN/WAN failover +
        // direct-fallback ladder grinds toward a terminal error (~60s in the
        // kill-the-container capture). These raise a pre-terminal
        // `progressStore.streamStalled` flag so the tile can show a soft
        // "Reconnecting…" card at ~15s instead. Report at 15s (3s past the
        // first 12s reload, so a reload that DOES recover never trips it) and
        // clear the instant real frames resume (staleAge collapses to ~0). The
        // 3s clear floor sits well above any normal VSync skip so a single
        // late frame can't flap the flag.
        private let staleStallReportThresholdSec: CFTimeInterval = 15.0
        private let staleStallClearThresholdSec: CFTimeInterval = 3.0
        private var streamStalledReported = false

        // v1.7.x black-frame-storm reload watchdog.
        //
        // Archie 2026-06-06 field test on Apple TV (Sky Sports Action HD,
        // H.264 50fps): a mid-stream audio underrun triggered audio-reconfig
        // 48000Hz -> 44100Hz, after which libmpv emitted ~367 consecutive
        // all-black frames over ~7 seconds while the underlying stream had
        // already recovered. Our existing BLACK-DETECT correctly suppressed
        // them (so AVSBDL stayed on the last good frame instead of cutting
        // to black), but the user-visible result was a 7-second frozen-frame
        // freeze with no way out except teardown. The decode pipeline
        // never spontaneously came back; mpv's video buffers needed a kick.
        //
        // Mitigation: count CONSECUTIVE black-frame suppressions (separate
        // from the lifetime total). When the consecutive run exceeds a
        // small threshold, issue `loadfile <currentURL> replace` on
        // mpvQueue to force mpv to re-prime its video pipeline against
        // the same URL. A cooldown prevents storms of reloads if the
        // underlying issue persists.
        //
        // Thresholds:
        // - 30 consecutive suppressed frames = ~0.6s at 50fps, ~1.0s at
        //   30fps. NOTE (#37, Glitzbr 2026-06-17): this DOES trip on OTA
        //   commercial fade-to-black / ad blanking, so the reload is now
        //   gated by the #37 resolution-change grace + the per-stream reload
        //   backoff + the user Auto-Recover toggle (see below).
        // - 5 second reload cooldown = avoids hammering the proxy if
        //   the storm is sourced upstream.
        private var consecutiveBlackFramesSuppressed: Int = 0
        private var lastForcedBlackReloadAt: CFAbsoluteTime = 0
        // GH #60 detector rework (the 6-7 min glitch cycle): the old model
        // suppressed EVERY matching frame (holding the last bright frame, so
        // the luma baseline never updated and a legit ad-break cut to black
        // kept matching forever) and reloaded at 30 consecutive = 0.5s -
        // tripped by ordinary slates, and each trip churned the Dispatcharr
        // connection. Now: suppression only bridges a short anti-flash HOLD
        // (~8 frames); past it the black frames are ENQUEUED (the source
        // really went dark - show it) and the baseline updates, ending the
        // storm naturally. The storm reload is re-keyed to BIT-FLAT ZERO
        // frames (avg==0 && std==0): decoder zero-fill produces exact zeros
        // (the 2026-06-06 367-frame wedge), while camera/ad blacks carry
        // dither and never match. 240 frames = ~4s at 60fps before reload.
        private let blackFrameSuppressHoldFrames: Int = 8
        private var consecutiveZeroFrames: Int = 0
        private let blackFrameStormThreshold: Int = 240
        private let blackFrameReloadCooldownSec: CFAbsoluteTime = 120.0

        // #37 (Glitzbr 2026-06-17 multiview OTA log): a commercial break can
        // trip BOTH reload watchdogs repeatedly. Each loadfile-replace fails
        // fast and forces a ~4-5s re-open, and in multiview the reload work
        // starves sibling tiles past their own threshold, cascading into a
        // reload loop for the whole break. Circuit-breaker: cap forced reloads
        // (both paths combined) to maxForcedReloadsPerWindow per
        // reloadBackoffWindowSec per stream; once capped, back off and let the
        // stream recover on its own (it does once the break ends). Fixed-window
        // counter; touched from the CADisplayLink watchdog (stale path) and the
        // render queue (black path) - the same benign cross-thread pattern as
        // lastForcedBlackReloadAt above (an occasional off-by-one is harmless).
        private var forcedReloadWindowStart: CFAbsoluteTime = 0
        private var forcedReloadWindowCount: Int = 0
        private let reloadBackoffWindowSec: CFAbsoluteTime = 60.0
        private let maxForcedReloadsPerWindow: Int = 3

        // #37 user kill-switch (Settings > App Behaviors > Auto-Recover Frozen
        // Streams). Read once per tune in setupMPV; default true. When false,
        // BOTH forced-reload watchdog paths are disabled and a frozen stream is
        // left for the user to re-tune manually (no auto loadfile-replace).
        private var watchdogReloadEnabled: Bool = true

        // v1.7.x Issue A round 2: localize mid-stream black flashes.
        // Archie 2026-05-08 native-UHD test showed late=3 frames
        // including FRAME #226 with render=8.1ms interval=211.8ms
        // — mpv didn't ASK us to render for 200ms, then the actual
        // render call returned in 8ms. That isolates the stall to
        // libmpv's internal pipeline (decoder/demuxer/render-context),
        // not our render or present path. lastScheduleRenderTime
        // tracks the most recent mpv update-callback fire so a long
        // silence shows up as a single [MPV-CALLBACK-GAP] line.
        private var lastScheduleRenderTime: CFAbsoluteTime = 0

        /// Multiview tile count at the moment this Coordinator is
        /// being constructed. Snapshot on the main actor by the
        /// Representable. setupMPV (background queue) reads this
        /// instead of touching `MultiviewStore.shared.tiles.count`
        /// directly, which would be an actor-isolation violation.
        /// See the audio-strategy branch in setupMPV for usage.
        private let initialTileCount: Int
        /// CarPlay flag captured on the main actor at construction. When true,
        /// `setupMPV` bakes `vid=no` in before `loadfile` so the video pipeline
        /// never comes up: no decode, no GL present (which sidesteps the iOS
        /// Simulator's broken OpenGL ES path that otherwise stalls the whole
        /// stream, audio included), and no wasted power decoding video the
        /// driver can't watch. The background/foreground lifecycle handlers
        /// keep `vid=no` for the whole CarPlay session (they skip the usual
        /// foreground video-restore while a car is connected).
        private let initialVideoSuppressed: Bool

        init(urls: [URL], headers: [String: String], isLive: Bool,
             isDVR: Bool = false,
             progressStore: PlayerProgressStore,
             logStore: AttemptLogStore,
             onFatalError: @escaping @MainActor @Sendable (String) -> Void,
             tileID: String? = nil,
             initialIsAudioActive: Bool = true,
             initialShouldPause: Bool = false,
             initialTileCount: Int = 1,
             initialVideoSuppressed: Bool = false) {
            self.urls = urls
            self.headers = headers
            self.isLive = isLive
            self.isDVR = isDVR
            self.progressStore = progressStore
            self.logStore = logStore
            self.onFatalError = onFatalError
            self.tileID = tileID
            self.initialIsAudioActive = initialIsAudioActive
            self.initialShouldPause = initialShouldPause
            self.initialTileCount = initialTileCount
            self.initialVideoSuppressed = initialVideoSuppressed
            // Seed the `lastApplied*` debounce with the initial
            // values — setupMPV applies them via mpv_set_option
            // BEFORE mpv_initialize, so there's no need for
            // updateUIViewController to re-issue them afterwards.
            // (Subsequent state changes via the Representable still
            // go through applyXxxIfChanged and flip mpv properties.)
            self.lastAppliedAudioFocus = initialIsAudioActive
            self.lastAppliedPause = initialShouldPause
            super.init()

            // Toggle play/pause. The mpv get/set run on mpvQueue: mpv property
            // calls can block until the core services them, and these closures
            // fire from SwiftUI taps on the MAIN thread, so calling mpv inline
            // would freeze the UI whenever the core is parked in a blocking
            // demuxer read (a stalled HLS / DVR stream). That is the same
            // main-thread-block class the stop() path was rewritten to avoid.
            // (Also: MPV_FORMAT_FLAG reads/writes a C int, i.e. Int32, not
            // Swift's 64-bit Int, which previously over-read the pointer.)
            progressStore.togglePauseAction = { [weak self] in
                self?.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    var flag: Int32 = 0
                    mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
                    var newFlag: Int32 = flag == 0 ? 1 : 0
                    mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &newFlag)
                }
            }

            // Retry closure for the playback-error overlay (manual Retry
            // button + its auto-reconnect loop). Resets the exhausted
            // retry budgets and starts a fresh attempt. Native catch-up
            // mints a NEW session (the tuned URL is session-bound and
            // usually already revoked, so replaying it can only 401).
            progressStore.retryAction = { [weak self] in
                guard let self else { return }
                self.mpvQueue.async { [weak self] in
                    guard let self, !self.isShuttingDown, !self.urls.isEmpty else { return }
                    self.loadFailureRetryCount = 0
                    self.sameURLRetryCount = 0
                    self.hasPerformedWarmupRetry = false
                    self.playbackEnded = false
                    debugLog("[MPV-DIAG] user/auto retry after fatal error")
                    if let cu = self.catchup, cu.nativeChannelUUID != nil {
                        if self.nativeRemintInFlight {
                            self.nativeRemintPendingMs = self.catchupBaseOffsetMs
                        } else {
                            self.startNativeRetune(cu: cu, clampedMs: self.catchupBaseOffsetMs)
                        }
                        return
                    }
                    self.currentIndex = 0
                    let url = self.urls[0]
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.play(url: url)
                    }
                }
            }

            // Seek closure: VOD + DVR. Live TV has no seekable timeline.
            // Runs on mpvQueue (off main) so a scrub never blocks the UI when
            // the core is stalled; this also puts playbackEnded access on the
            // same queue as the EOF event handler that sets it.
            progressStore.seekAction = { [weak self] targetMs in
                guard let self, !self.isLive || self.liveRewindActive else { return }
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    if self.liveRewindActive {
                        // Live Rewind: the scrubber spans the buffer window
                        // [tail .. head]; a seek is a re-tune of the relay
                        // at the requested wall time. Near the head, tune
                        // the live head-follow stream instead (the "Go
                        // Live" snap; anchored on FRESH buffer values, the
                        // Android stale-anchor lesson).
                        let engine = LiveRewindEngine.shared
                        guard let buf = engine.bufferForReader else { return }
                        let tail = buf.tailWallMs
                        let head = buf.headWallMs
                        let window = max(Int64(1), head - tail)
                        let clamped = min(max(Int64(targetMs), 0), window)
                        let targetWall = tail + clamped
                        self.playbackEnded = false
                        if targetWall >= head - 5_000 {
                            engine.noteTimeshifting(false)
                            self.mpvCommandAsync(mpv, ["loadfile", "aeriots://live", "replace"])
                            debugLog("[REWIND] seek to live edge")
                        } else {
                            engine.noteTimeshifting(true)
                            self.mpvCommandAsync(mpv, ["loadfile", "aeriots://at/\(targetWall)", "replace"])
                            debugLog("[REWIND] re-tune \((head - targetWall) / 1000)s behind live")
                        }
                        let ps = self.progressStore
                        DispatchQueue.main.async { ps.currentMs = Int32(clamped) }
                        return
                    }
                    if let cu = self.catchup {
                        // Catch-up: the bounded timeshift TS has no reliable
                        // in-stream random access (estimated Content-Length,
                        // session-bound 301s), but the URL encodes its start
                        // time -- so a seek IS a re-tune at programmeStart +
                        // target. Floor to the minute (the URL's start
                        // granularity) and land the exact second with a
                        // residual in-stream seek once the file loads.
                        // Mirrors the shipped AerioTV-Android seek model.
                        let durMs = cu.programDurationMs
                        let clamped = min(max(targetMs, 0), max(0, durMs - 5_000))
                        let offsetSecs = Double(clamped) / 1000.0
                        let flooredSecs = (offsetSecs / 60.0).rounded(.down) * 60.0
                        if cu.nativeChannelUUID != nil {
                            // Task #149 native sessions: a NEW session minted
                            // at programmeStart+offset (async network call)
                            // instead of a rebuilt XC wall-clock URL. NO
                            // minute flooring here: the sessions API takes
                            // full ISO-8601 seconds, and flooring broke the
                            // +/-30s skips (a +30 press from mid-minute
                            // floored BACKWARD and then pinned every
                            // following press to the same window). Mints are
                            // serialized; see startNativeRetune.
                            self.playbackEnded = false
                            if self.nativeRemintInFlight {
                                self.nativeRemintPendingMs = clamped
                                let ps = self.progressStore
                                DispatchQueue.main.async { ps.currentMs = clamped }
                                return
                            }
                            self.startNativeRetune(cu: cu, clampedMs: clamped)
                            return
                        }
                        guard let newURL = CatchupSupport.rebuildForOffset(
                            url: cu.url,
                            panelTimeZoneID: cu.panelTimeZoneID,
                            programStart: cu.programStart,
                            programEnd: cu.programEnd,
                            offsetSeconds: flooredSecs) else { return }
                        self.playbackEnded = false
                        self.catchupBaseOffsetMs = Int32(flooredSecs * 1000)
                        // NO residual in-stream seek: the stream is opened
                        // seekable=0, so the post-load seek only worked when
                        // the target happened to sit in the demuxer cache
                        // (~never at FILE_LOADED) and otherwise failed - the
                        // scrubber flashed the target then snapped back. It
                        // also raced rapid double-seeks (the OLD file's load
                        // consumed the NEW residual). Android removed its
                        // twin for the same reason: land on the floored
                        // minute and say so.
                        self.catchupPendingSeekSecs = nil
                        CatchupRelay.currentHeaders = self.headers
                        let relayURL = CatchupRelay.wrap(newURL)
                        self.mpvCommandAsync(mpv, ["loadfile", relayURL.absoluteString, "replace"])
                        let ps = self.progressStore
                        let honest = Int32(flooredSecs * 1000)
                        DispatchQueue.main.async { ps.currentMs = honest }
                        debugLog("[CATCHUP] re-tune to window \(Int(flooredSecs))s (requested \(clamped / 1000)s)")
                        return
                    }
                    if self.isDVR {
                        // DVR (in-progress recording): the seekable window grows
                        // toward a moving live edge. Clamp the target a few
                        // seconds behind the current playlist end so we never
                        // seek onto EOF (which would otherwise lock every later
                        // seek), and clear any transient end-of-playlist EOF so
                        // the user can always scrub back from the live edge.
                        self.playbackEnded = false
                        var durSec: Double = 0
                        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &durSec)
                        var target = Double(targetMs) / 1000.0
                        if durSec > 0 { target = min(target, durSec - Coordinator.dvrLiveEdgeGuardSec) }
                        target = max(0, target)
                        let secs = String(format: "%.3f", target)
                        self.mpvCommandAsync(mpv, ["seek", secs, "absolute"])
                        return
                    }
                    // Regular VOD: guard against seek-after-EOF.
                    guard !self.playbackEnded else { return }
                    let secs = String(format: "%.3f", Double(targetMs) / 1000.0)
                    self.mpvCommandAsync(mpv, ["seek", secs, "absolute"])
                }
            }

            // Replay-from-start: used by the multiview "Finished" overlay.
            // A VOD that hit EOF has `playbackEnded` latched (which
            // `seekAction` deliberately refuses to seek past), so this
            // dedicated path clears the latch, seeks to 0, and unpauses.
            // Live tiles never reach EOF, so guarding on `!isLive` keeps
            // this inert for them. Runs on mpvQueue like the other
            // transport actions so it never blocks the UI.
            progressStore.replayFromStartAction = { [weak self] in
                guard let self, !self.isLive else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.progressStore.reachedEOF = false
                }
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    self.playbackEnded = false
                    self.mpvCommandAsync(mpv, ["seek", "0", "absolute"])
                    var unpause: Int32 = 0
                    mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &unpause)
                }
            }

            // Playback speed. mpv write on mpvQueue; UI state on main.
            progressStore.setSpeedAction = { [weak self] speed in
                guard let self else { return }
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    mpv_set_property_string(mpv, "speed", String(format: "%.2f", speed))
                }
                DispatchQueue.main.async { self.progressStore.speed = speed }
            }

            // Audio track selection (0 = auto). mpv write on mpvQueue.
            progressStore.setAudioTrackAction = { [weak self] trackID in
                guard let self else { return }
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    mpv_set_property_string(mpv, "aid", trackID == 0 ? "auto" : "\(trackID)")
                }
                DispatchQueue.main.async { self.progressStore.currentAudioTrackID = trackID }
            }

            // Subtitle track selection (0 = off). mpv write on mpvQueue.
            progressStore.setSubtitleTrackAction = { [weak self] trackID in
                guard let self else { return }
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    mpv_set_property_string(mpv, "sid", trackID == 0 ? "no" : "\(trackID)")
                }
                DispatchQueue.main.async { self.progressStore.currentSubtitleTrackID = trackID }
            }

            // Audio Only via the companion remote (GH #33): drop/restore the
            // video track like the Android host's setVideoTrackEnabled --
            // audio keeps rolling with zero video decode. isAudioOnly mirrors
            // so the chrome overlay + background discipline stay consistent.
            progressStore.setVideoEnabledAction = { [weak self] enabled in
                guard let self else { return }
                debugLog("[Companion] host: setVideoEnabled(\(enabled)) (audioOnly=\(!enabled))")
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    mpv_set_property_string(mpv, "vid", enabled ? "auto" : "no")
                }
                DispatchQueue.main.async { self.progressStore.isAudioOnly = !enabled }
            }

            // Task #184: user audio sync offset (mpv audio-delay; positive
            // = audio later). The property lives on the warm mpv instance,
            // so it survives channel swaps for the session by design.
            progressStore.setAudioSyncAction = { [weak self] ms in
                guard let self else { return }
                let clamped = max(-1000, min(1000, ms))
                debugLog("[AUDIO-SYNC] set audio-delay=\(clamped)ms")
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    mpv_set_property_string(mpv, "audio-delay",
                                            String(format: "%.3f", Double(clamped) / 1000.0))
                }
                DispatchQueue.main.async { self.progressStore.audioSyncMs = clamped }
            }

            // Background/foreground handling — disable video output to prevent GPU crashes
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                                   name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                                   name: UIApplication.willEnterForegroundNotification, object: nil)
            // Audio route change — log AirPlay connect/disconnect
            NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged),
                                                   name: AVAudioSession.routeChangeNotification, object: nil)
            // Live Rewind: a second multiview tile invalidates this
            // tile's solo-live relay eligibility (captured at play time);
            // drop to the direct stream. Removed via removeObserver(self)
            // in deinit alongside the others.
            NotificationCenter.default.addObserver(self, selector: #selector(dropLiveRewindRelay),
                                                   name: .aerioLiveRewindDropRelay, object: nil)
            // GH #60 seatbelt (memory-warning hook -> one relay reload).
            NotificationCenter.default.addObserver(self, selector: #selector(memorySeatbeltReload),
                                                   name: .aerioMemorySeatbeltReload, object: nil)
            // Switch Stream: after a confirmed switch the picker asks the live
            // player to reload so libmpv re-locks onto the channel's fresh
            // buffer (recovers the dead-upstream/failover-cascade freeze). Only
            // the coordinator playing that channel's proxy URL reacts. Removed
            // via removeObserver(self) in deinit.
            NotificationCenter.default.addObserver(self, selector: #selector(switchStreamReprimeRequested(_:)),
                                                   name: .switchStreamReprime, object: nil)

            // Issue #26: apply the chosen aspect mode to the display layer
            // whenever it changes (and once on subscribe for the persisted
            // initial value). Cross-platform — the AVSampleBufferDisplayLayer
            // and its videoGravity exist on iOS and tvOS alike.
            progressStore.$aspectMode
                .receive(on: DispatchQueue.main)
                .sink { [weak self] mode in
                    MainActor.assumeIsolated {
                        self?.viewController?.sampleBufferLayer.videoGravity = mode.videoGravity
                    }
                }
                .store(in: &cancellables)

            #if os(iOS)
            // Audio-Only suppresses auto-PiP. Without this, swiping home
            // with Audio-Only on triggers iOS's auto-PiP engagement —
            // the PiP floating window appears with the stream video,
            // shadowing NowPlayingBridge's lockscreen / Dynamic Island
            // audio UI. Reconciling on every isAudioOnly change keeps
            // `canStartPictureInPictureAutomaticallyFromInline` and
            // `pipAutoEligible` aligned with the user's current
            // intent. `.receive(on: main)` so we touch the PiP
            // controller on the same thread that owns it.
            progressStore.$isAudioOnly
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newValue in
                    #if DEBUG
                    if let self {
                        debugLog("[MPV-PIP] isAudioOnly sink fired: newValue=\(newValue) coord=\(ObjectIdentifier(self))")
                    } else {
                        debugLog("[MPV-PIP] isAudioOnly sink fired: newValue=\(newValue) coord=<deallocated>")
                    }
                    #endif
                    self?.updateAutoPiPEligibility()
                }
                .store(in: &cancellables)
            #endif
        }

        #if os(iOS)
        /// Reconcile auto-PiP state with the current Audio-Only flag.
        /// Writes `canStartPictureInPictureAutomaticallyFromInline` on
        /// the stored PiP controller and the matching
        /// `pipAutoEligible` flag so `didEnterBackground` routes to the
        /// correct branch. Idempotent — safe to call from
        /// `makeUIViewController` (initial mount) and from the
        /// `progressStore.$isAudioOnly` sink (subsequent toggles).
        /// No-op before `pipController` has been assigned, so
        /// devices / simulators without PiP support stay in the
        /// default pause-on-background branch.
        ///
        /// Not marked `@MainActor` so the Combine sink (nonisolated
        /// closure, even with `.receive(on: DispatchQueue.main)`)
        /// can call it directly. Both callers — `makeUIViewController`
        /// via `UIViewControllerRepresentable`'s main-thread
        /// contract, and the sink via the main-scheduler delivery —
        /// guarantee main-thread execution at runtime, which is all
        /// AVPictureInPictureController needs.
        fileprivate func updateAutoPiPEligibility() {
            let audioOnly = progressStore.isAudioOnly
            guard let vc = viewController else {
                #if DEBUG
                debugLog("[MPV-PIP] updateAutoPiPEligibility: viewController=nil audioOnly=\(audioOnly) — deferred (VC not wired yet)")
                #endif
                pipController = nil
                pipAutoEligible = false
                return
            }
            // MPVPlayerViewController is @MainActor-isolated (it's a
            // UIViewController subclass). Both callers of this method
            // — makeUIViewController (main-threaded by SwiftUI
            // contract) and the `.receive(on: main)` sink — guarantee
            // main-thread execution at runtime. `assumeIsolated` is
            // the Swift 5.9+ bridge that lets us call @MainActor APIs
            // without async hops while still satisfying strict
            // concurrency.
            MainActor.assumeIsolated {
                if audioOnly {
                    // HARD suppress: destroy the PiP controller entirely.
                    // Setting canStartPictureInPictureAutomaticallyFromInline
                    // at runtime does NOT prevent iOS from engaging
                    // auto-PiP once armed — confirmed in device logs
                    // where the sink wrote `false` to the flag and
                    // iOS still fired
                    // `pictureInPictureControllerWillStartPictureInPicture`
                    // on swipe-home. Only tearing down the controller so
                    // iOS no longer has a handle on our sample-buffer
                    // layer reliably suppresses auto-PiP.
                    vc.tearDownPiPController()
                    self.pipController = nil
                    self.pipAutoEligible = false
                    #if DEBUG
                    debugLog("[MPV-PIP] updateAutoPiPEligibility: audioOnly=true → tore down PiP controller")
                    #endif
                    // Re-assert the now-playing bridge. Tearing down the
                    // AVPictureInPictureController implicitly revokes iOS's
                    // "this app is a video-playback host" signal — which is
                    // the same signal iOS consults when deciding whether to
                    // surface the lockscreen / Dynamic Island now-playing
                    // controls for our app. Without a fresh
                    // `beginReceivingRemoteControlEvents()` + audio-session
                    // re-activation + `MPNowPlayingInfoCenter` publish
                    // AFTER the teardown, the lockscreen / Dynamic Island
                    // stays blank on swipe-home even though our audio
                    // keeps playing. `NowPlayingBridge.configure(...)` is
                    // idempotent — re-running it is the documented way to
                    // reclaim the now-playing route.
                    //
                    // Gated on `nowPlayingConfigured` so we only re-assert
                    // once the bridge was already configured for this
                    // stream (i.e. the user is toggling Audio Only during
                    // active playback, not during the initial mount
                    // before the 2s stability check). On the initial
                    // mount, the stability check will run configure() for
                    // the first time and the teardown here is a no-op on
                    // now-playing anyway (there's nothing published yet).
                    if self.nowPlayingConfigured {
                        self.reassertNowPlayingBridge()
                    }
                } else {
                    // Rebuild / re-arm. `ensurePiPController` is
                    // idempotent (returns cached controller if still
                    // present), so this is safe on the initial mount
                    // path as well as the "user flipped Audio Only
                    // back off" re-arm.
                    let pip = vc.ensurePiPController()
                    self.pipController = pip
                    self.pipAutoEligible = (pip != nil)
                    #if DEBUG
                    if let pip {
                        debugLog("[MPV-PIP] updateAutoPiPEligibility: audioOnly=false → armed pip=\(ObjectIdentifier(pip)) pipAutoEligible=true")
                    } else {
                        debugLog("[MPV-PIP] updateAutoPiPEligibility: audioOnly=false → PiP unsupported on this device")
                    }
                    #endif
                }
            }
        }

        /// Re-invoke `NowPlayingBridge.configure(...)` with the same
        /// metadata + command callbacks that the 2s stability-check
        /// timer used at stream start. Used by the Audio-Only
        /// teardown path in `updateAutoPiPEligibility()` — destroying
        /// the `AVPictureInPictureController` revokes iOS's
        /// remote-control-route assignment, and the lockscreen /
        /// Dynamic Island now-playing UI stays blank until an app
        /// re-claims it. Re-running configure() re-calls
        /// `beginReceivingRemoteControlEvents()`, re-activates the
        /// `.playback` audio session, and re-publishes the full
        /// `nowPlayingInfo` dict, which is the documented way to
        /// reclaim the route.
        ///
        /// Must run on MainActor (guaranteed by callers:
        /// `updateAutoPiPEligibility` wraps its body in
        /// `MainActor.assumeIsolated`).
        @MainActor
        fileprivate func reassertNowPlayingBridge() {
            // Duration is only meaningful for VOD — for live streams we
            // always pass `nil` so the lockscreen shows the live
            // indicator instead of a bogus scrubber.
            var dur: Double? = nil
            if !isLive, let mpv = activeMPVHandle() {
                var duration: Double = 0
                if mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0, duration > 0 {
                    dur = duration
                }
            }
            let title = nowPlayingTitle
            let sub = nowPlayingSubtitle
            let art = nowPlayingArtworkURL
            let live = isLive
            let ps = progressStore
            #if DEBUG
            debugLog("[MPV-PIP] reassertNowPlayingBridge: title=\"\(title)\" live=\(live)")
            #endif
            NowPlayingBridge.shared.configure(
                title: title,
                subtitle: sub,
                artworkURL: art,
                duration: dur,
                isLive: live,
                onPlay:  { ps.togglePauseAction?() },
                onPause: { ps.togglePauseAction?() },
                onSeek: live ? nil : { [weak self] time in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    let secs = String(format: "%.3f", time)
                    self.mpvCommandAsync(mpv, ["seek", secs, "absolute"])
                }
            )
        }
        #endif

        deinit {
            NotificationCenter.default.removeObserver(self)
            #if os(tvOS)
            // Task #186: backstop for teardown paths that skip stop().
            clearDisplayCriteria()
            #endif
        }

        @objc private func didEnterBackground() {
            guard let mpv = activeMPVHandle() else { return }
            #if os(iOS)
            // v1.6.8: track background state so `renderAndPresent`
            // can decide whether to auto-pause mpv when the sample-
            // buffer layer flips to `.failed`. Set early so the
            // flag is honoured even if any of the policy branches
            // below short-circuit before the end of the function.
            isInBackground = true
            // Background-audio discipline — audio plays with the app closed
            // ONLY when:
            //   (1) PiP is engaged (iOS drives the floating window),
            //   (2) Audio-Only mode is on (lockscreen + Dynamic Island
            //       controls via NowPlayingBridge), or
            //   (3) AirPlay is routing audio to another device.
            // Every other case falls to (4) and pauses mpv so there's no
            // phantom audio on the home screen.
            //
            // The synchronous `progressStore.isPiPActive = true` write in
            // `pictureInPictureControllerWillStartPictureInPicture`
            // guarantees branch (1) catches auto-PiP — that delegate fires
            // before this notification in the iOS background transition
            // sequence.

            // (1) PiP engaged.
            if progressStore.isPiPActive {
                #if DEBUG
                debugLog("[MPV-BG] Background: PiP active, keeping vid+audio")
                #endif
                return
            }

            // (1.5) Auto-PiP eligible — iOS may still be inspecting
            //       frames to decide whether to engage PiP. Without
            //       this branch, the `vid=no` safeguard below starves
            //       the engagement and PiP silently fails to appear
            //       (GH #4). When iOS DOES engage, the
            //       `pictureInPictureControllerWillStartPictureInPicture`
            //       delegate fires and flips `progressStore.isPiPActive`
            //       synchronously, so subsequent lifecycle events go
            //       through branch (1). When iOS decides NOT to engage
            //       (e.g. hardware limits, low power mode), we leak a
            //       few frames of background rendering — acceptable
            //       edge case; auto-PiP is the happy path on every
            //       PiP-capable iPhone.
            //
            //       v1.6.17: gate on multiview tile count. If the user
            //       is in multi-tile multiview (count > 1), iOS gets
            //       confused by the multiple AVSampleBufferDisplayLayers
            //       in the hierarchy and doesn't reliably engage PiP
            //       for any of them — and the per-tile vid-stays-alive
            //       path leaks GPU + audio for the audio tile while
            //       the other 8 tiles disable cleanly, leaving a
            //       lopsided "audio plays but tiles black on return"
            //       repro that's difficult to recover from. With the
            //       gate, multi-tile multiview falls through to the
            //       default pause-on-background branch — every tile
            //       suspends symmetrically, audio stops cleanly, and
            //       foregrounding restores everything via the
            //       symmetric vid=auto + unpause path.
            //       Multiview auto-PiP remains a known gap; the v1.6.15
            //       plan acknowledged this would require a multi-tile-
            //       aware PiP setup that's still future work.
            // MultiviewStore is @MainActor; this @objc handler is nonisolated
            // but UIApplication.didEnterBackgroundNotification posts on main,
            // so assumeIsolated is safe.
            let multiviewTileCount = MainActor.assumeIsolated { MultiviewStore.shared.tiles.count }
            let multiviewActive = multiviewTileCount > 1
            if pipAutoEligible, !multiviewActive {
                #if DEBUG
                debugLog("[MPV-BG] Background: auto-PiP eligible, keeping vid live")
                #endif
                return
            }
            #if DEBUG
            if pipAutoEligible, multiviewActive {
                debugLog("[MPV-BG] Background: pipAutoEligible=true but multiview tiles=\(multiviewTileCount) — falling through to default pause-on-background path")
            }
            #endif

            // (2) Audio-Only mode. Kill video, keep audio + Dynamic Island /
            //     lockscreen via NowPlayingBridge.
            if progressStore.isAudioOnly {
                #if DEBUG
                debugLog("[MPV-BG] Background: audio-only, vid=no, audio continues (lockscreen + Dynamic Island)")
                #endif
                mpv_set_property_string(mpv, "vid", "no")
                return
            }

            // (2b) CarPlay connected: keep audio for the car, suppress video
            //      (the phone is backgrounded/locked while driving). The flag
            //      is set by CarPlaySceneDelegate; it stays false off CarPlay
            //      and on tvOS, so this is a no-op everywhere else. Sits with
            //      the audio-only branch (all platforms) so it does not depend
            //      on the iOS-only AirPlay block below.
            // didEnterBackground is delivered on the main thread (the
            // UIApplication lifecycle notification posts on main), so read the
            // main-actor NowPlayingManager via assumeIsolated rather than an
            // async hop, since we must decide synchronously before returning.
            let carPlayConnected = MainActor.assumeIsolated {
                NowPlayingManager.shared.isCarPlayConnected
            }
            if carPlayConnected {
                #if DEBUG
                debugLog("[MPV-BG] Background: CarPlay connected, vid=no, audio continues")
                #endif
                mpv_set_property_string(mpv, "vid", "no")
                return
            }

            // (3) AirPlay route.
            let route = AVAudioSession.sharedInstance().currentRoute
            let airPlayAudio = route.outputs.contains(where: { $0.portType == .airPlay })

            #if DEBUG
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            debugLog("[MPV-BG] Background: airPlayAudio=\(airPlayAudio), isPiP=\(progressStore.isPiPActive), audioOnly=\(progressStore.isAudioOnly), outputs=[\(outputs)]")
            #endif

            if airPlayAudio {
                mpv_set_property_string(mpv, "vid", "no")
                return
            }
            #endif

            // (4) Default — no mode permits background audio. Disable video
            //     (GPU-crash safeguard) AND pause mpv so audio stops. The
            //     pause goes through mpvQueue to match every other mpv
            //     property write in this file — writing `pause` directly
            //     from the main thread during a background transition
            //     races mpv's event loop and the audio-session teardown.
            //     `autoPausedOnBackground` tells the foreground handler to
            //     undo the pause without clobbering a user-initiated one.
            mpv_set_property_string(mpv, "vid", "no")
            _ = markAutoPausedOnBackgroundIfNeeded()
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.activeMPVHandle() else { return }
                var flag: Int32 = 1
                mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
            }
        }

        @objc private func willEnterForeground() {
            guard let mpv = activeMPVHandle() else { return }
            // v1.6.8: clear the background flag immediately so any
            // in-flight render callback that fires after this point
            // doesn't redundantly auto-pause. The actual pause/resume
            // logic below uses `autoPausedOnBackground` (separate
            // flag) to decide whether mpv needs to be unpaused.
            isInBackground = false

            #if os(iOS)
            // v1.6.17: recover the AVSampleBufferDisplayLayer FIRST,
            // before flipping vid=auto and unpausing mpv. iOS suspends
            // the sample-buffer pipeline on background entry; the
            // renderer can land in `.failed` with "Operation
            // Interrupted" and never self-recover. Frames enqueued
            // onto a failed renderer are silently dropped, leaving
            // the view black even though mpv is producing frames.
            //
            // Pre-1.6.17 the recovery was scheduled on a `Task
            // @MainActor` (async) and the unpause was queued on
            // `mpvQueue` (separate serial queue, also async). On
            // multi-tile multiview foregrounding, those two async
            // hops raced — mpv's first post-unpause frame could
            // arrive at the renderer BEFORE flush() ran, get
            // dropped, and the tile would stay black for the whole
            // session.
            //
            // willEnterForeground notifications post on main, so
            // we're already on the main thread here. Wrap the layer
            // touch in `MainActor.assumeIsolated` to satisfy strict
            // concurrency without an async hop, and flush
            // synchronously so the renderer is healthy by the time
            // the unpause queue's first frame lands.
            MainActor.assumeIsolated {
                if let layer = self.viewController?.sampleBufferLayer,
                   layer.sampleBufferRenderer.status == .failed {
                    #if DEBUG
                    let err = layer.sampleBufferRenderer.error?.localizedDescription ?? "?"
                    debugLog("[MPV-BG] Foreground: sampleBufferRenderer FAILED (\(err)) — flushing to recover")
                    #endif
                    layer.sampleBufferRenderer.flush()
                }
            }
            #endif

            // Re-enable video if the background handler disabled it.
            let vid = mpv_get_property_string(mpv, "vid")
            let vidStr = vid.flatMap { String(cString: $0) }
            #if DEBUG
            let route = AVAudioSession.sharedInstance().currentRoute
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            debugLog("[MPV-BG] Foreground: vid=\(vidStr ?? "nil"), isPiP=\(progressStore.isPiPActive), audioOnly=\(progressStore.isAudioOnly), autoPaused=\(autoPausedOnBackground), outputs=[\(outputs)]")
            #endif
            if vidStr == "no" {
                // Keep video suppressed while CarPlay is connected: the driver
                // isn't watching the phone, and on a real device foregrounding
                // (unlocking the phone mid-drive) would otherwise bring the
                // whole video pipeline back up. This @objc handler is posted on
                // the main thread, so reading the @MainActor NowPlayingManager
                // via assumeIsolated is safe.
                let carPlayConnected = MainActor.assumeIsolated {
                    NowPlayingManager.shared.isCarPlayConnected
                }
                // Also stay suppressed while Audio Only is on (companion
                // remote can set it while foregrounded now) -- foreground
                // must not silently undo an explicit audio-only choice.
                if !carPlayConnected, !progressStore.isAudioOnly {
                    mpv_set_property_string(mpv, "vid", "auto")
                }
            }
            mpv_free(vid)

            // Restart the stale-frame clock on foreground. While backgrounded
            // with video disabled (vid=no), no frames enqueue, so lastEnqueueTime
            // freezes at the pre-background frame; on foreground staleAge would
            // equal the whole background duration and — because the background
            // pause/unpause bypasses applyPauseIfChanged so lastAppliedPause is
            // never set — falsely trip the 15s soft "Reconnecting…" report and
            // the forced-reload watchdog. Repriming here mirrors the resume
            // branch of applyPauseIfChanged (2026-07-13 review). Repriming the
            // anchor alone is enough: if a soft card was already up when we
            // backgrounded, the next watchdog tick sees staleAge < 3s with the
            // report latch still set and runs the CLEAR arm, dropping the card.
            lastEnqueueTime = CACurrentMediaTime()

            // Undo the defensive pause applied in branch (4), but only if
            // we applied it — never clobber a user-initiated pause. Goes
            // through mpvQueue to match the background-entry write.
            if takeAutoPausedOnBackground() {
                mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    var flag: Int32 = 0
                    mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
                }
            }
        }

        @objc private func audioRouteChanged(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

            let route = AVAudioSession.sharedInstance().currentRoute
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }
            let hasAirPlay = route.outputs.contains(where: { $0.portType == .airPlay })

            let reasonStr: String = switch reason {
            case .newDeviceAvailable: "newDevice"
            case .oldDeviceUnavailable: "deviceRemoved"
            case .categoryChange: "categoryChange"
            case .override: "override"
            case .routeConfigurationChange: "routeConfig"
            default: "other(\(reasonValue))"
            }

            #if DEBUG
            debugLog("[MPV-AIRPLAY] Route changed: reason=\(reasonStr), airPlay=\(hasAirPlay), outputs=\(outputs)")
            #endif

            // Issue #36: toggling Dolby Atmos in tvOS Settings while the app
            // runs arrives as a route configuration change. Re-run the audio
            // health check (re-armed) so a dead audio chain, or one stuck on
            // the stereo fallback after the user turned Atmos back off,
            // recovers without an app restart.
            #if os(tvOS)
            switch reason {
            case .routeConfigurationChange, .categoryChange, .newDeviceAvailable, .oldDeviceUnavailable:
                mpvQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    self.audioStereoFallbackApplied = false
                    self.runAudioHealthCheck(context: "route-change(\(reasonStr))")
                }
            default:
                break
            }
            #endif

            // If AirPlay just connected and we're in the background with vid disabled, re-enable
            #if os(iOS)
            if hasAirPlay, reason == .newDeviceAvailable, let mpv = self.activeMPVHandle() {
                let vid = mpv_get_property_string(mpv, "vid")
                let vidStr = vid.flatMap { String(cString: $0) }
                mpv_free(vid)
                if vidStr == "no" {
                    #if DEBUG
                    debugLog("[MPV-AIRPLAY] AirPlay connected while vid=no, re-enabling video")
                    #endif
                    mpv_set_property_string(mpv, "vid", "auto")
                }
            }
            #endif
        }

        // MARK: - Lifecycle

        /// Called from the render queue after GL context + framebuffer are ready.
        func start() {
            guard !urls.isEmpty else {
                let callback = onFatalError
                Task { await callback("No URL provided") }
                return
            }
            currentIndex = 0
            anyAttemptStarted = false
            hasPerformedWarmupRetry = false
            sameURLRetryCount = 0
            loadFailureRetryCount = 0
            isShuttingDown = false
            playbackEnded = false
            // Reset diagnostics
            diagStartTime = Date()
            prevDroppedFrames = 0; prevDecoderDrops = 0
            bufferEnteredTime = nil
            totalBufferingDuration = 0; bufferEventCount = 0
            audioUnderrunCount = 0

            // v1.6.12: gate `setupMPV()` + `loadfile` on the
            // process-wide warm-up. Fixes the multiview first-tile
            // decoder error where the first tile's `loadfile` raced
            // libmpv's global ffmpeg/codec/protocol registration.
            // See `MPVLibraryWarmup.waitUntilComplete` for the full
            // rationale. Returns immediately for the common case
            // (warm-up done long before the user ever opens a
            // player).
            MPVLibraryWarmup.waitUntilComplete()

            setupMPV()
            play(url: urls[currentIndex])
        }

        // MARK: - Renderer Setup

        /// Called from viewDidLoad. Stores the sample-buffer layer
        /// reference AND kicks off `start()` on the render queue so
        /// mpv's ~2 s init (mostly one-time process-wide work — see
        /// `MPVLibraryWarmup`) runs in parallel with SwiftUI's
        /// first layout pass (~100-300 ms on a complex grid) rather
        /// than serially after it.
        ///
        /// Pixel-buffer sizing + FBO creation still wait for
        /// `handleResize` (triggered by `viewDidLayoutSubviews`)
        /// because that's when the real `CGSize` becomes available.
        /// `setupFBO` dispatches to the same serial `renderQueue`
        /// as `start()`, so FIFO ordering guarantees
        /// `setupMPV` completes before `setupFBO` runs — no change
        /// in correctness, we just pull the trigger earlier.
        @MainActor
        func setupRenderer(layer: CALayer) {
            self.sampleBufferLayer = layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first
            // Capture the renderer once here on the main actor so the
            // off-main render/diagnostics paths can reach it without a
            // main-actor hop. See the cachedRenderer declaration.
            self.cachedRenderer = self.sampleBufferLayer?.sampleBufferRenderer
            kickstartIfNeeded()
            // v1.7.x Issue A round 4: arm the IOSurface re-attach
            // watchdog now that the layer reference is in place.
            // See the watchdog-state declaration block for the full
            // rationale and source list.
            startWatchdogIfNeeded()
        }

        /// Dispatch `start()` on the render queue exactly once.
        /// Idempotent — safe to call from both `setupRenderer`
        /// (early) and `handleResize` (late) so a Coordinator that
        /// somehow misses the early path still starts.
        private func kickstartIfNeeded() {
            guard !mpvStarted else { return }
            mpvStarted = true
            renderQueue.async { [weak self] in
                self?.start()
            }
        }

        private var mpvStarted = false

        /// Creates (or recreates) the triple-buffered FBO ring.
        /// Each of the 3 slots holds an IOSurface-backed
        /// CVPixelBuffer + a GL texture wrapping it + an FBO with
        /// that texture bound as the color attachment. mpv renders
        /// into one slot per frame, advancing
        /// `renderBufferIndex` round-robin. We hand the matching
        /// slot's pixel buffer to AVSampleBufferDisplayLayer.
        ///
        /// See the FBOSlot declaration block above (~line 1151)
        /// for the full Step 5 rationale.
        private func setupFBO(width: Int, height: Int) {
            guard let eaglContext, let textureCache else { return }
            EAGLContext.setCurrent(eaglContext)

            // Clean up old ring. v1.7.x Issue A: stamp
            // fboDestroyedAt at the moment we delete so
            // [MPV-RECONFIG] can correlate "FBO=DESTROYED" /
            // "RECENTLY_REBUILT" with subsequent reconfig events
            // — answers whether user-visible black flashes are
            // the rebuild gap.
            if !fboSlots.isEmpty {
                #if DEBUG
                debugLog("[MPV-FBO] \(streamTag) destroy \(fboSlots.count)-deep pool (recreate path, was \(fboWidth)x\(fboHeight))")
                #endif
                fboDestroyedAt = CFAbsoluteTimeGetCurrent()
                for i in 0..<fboSlots.count {
                    if fboSlots[i].fbo != 0 {
                        glDeleteFramebuffers(1, &fboSlots[i].fbo)
                    }
                }
                fboSlots = []
                renderBufferIndex = 0
            }
            CVOpenGLESTextureCacheFlush(textureCache, 0)

            // Allocate the ring. Each slot gets a distinct
            // IOSurface-backed CVPixelBuffer + matching GL texture
            // (zero-copy — shares the IOSurface with mpv) + an FBO
            // with that texture bound as the color attachment.
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferOpenGLESCompatibilityKey: true as CFBoolean
            ]
            var newSlots: [FBOSlot] = []
            newSlots.reserveCapacity(Self.fboPoolSize)
            for slotIdx in 0..<Self.fboPoolSize {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                guard let pixelBuffer = pb else {
                    #if DEBUG
                    debugLog("[MPV-ERR] CVPixelBufferCreate failed for slot \(slotIdx)")
                    #endif
                    // Roll back any partial slots already created.
                    for i in 0..<newSlots.count {
                        if newSlots[i].fbo != 0 {
                            glDeleteFramebuffers(1, &newSlots[i].fbo)
                        }
                    }
                    return
                }
                var texture: CVOpenGLESTexture?
                let texResult = CVOpenGLESTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                    GLenum(GL_TEXTURE_2D), GL_RGBA,
                    GLsizei(width), GLsizei(height),
                    GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE),
                    0, &texture
                )
                guard texResult == kCVReturnSuccess, let glTexture = texture else {
                    #if DEBUG
                    debugLog("[MPV-ERR] CVOpenGLESTextureCacheCreateTextureFromImage failed for slot \(slotIdx): \(texResult)")
                    #endif
                    for i in 0..<newSlots.count {
                        if newSlots[i].fbo != 0 {
                            glDeleteFramebuffers(1, &newSlots[i].fbo)
                        }
                    }
                    return
                }
                let texName = CVOpenGLESTextureGetName(glTexture)
                var fbo: GLuint = 0
                glGenFramebuffers(1, &fbo)
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
                glFramebufferTexture2D(
                    GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                    GLenum(GL_TEXTURE_2D), texName, 0
                )
                let fbStatus = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
                if fbStatus != GL_FRAMEBUFFER_COMPLETE {
                    #if DEBUG
                    debugLog("[MPV-ERR] FBO incomplete for slot \(slotIdx): \(fbStatus)")
                    #endif
                }
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
                newSlots.append(FBOSlot(pixelBuffer: pixelBuffer, texture: glTexture, fbo: fbo))
            }
            fboSlots = newSlots
            fboWidth = width
            fboHeight = height
            renderBufferIndex = 0

            #if DEBUG
            // v1.7.x Issue A: include rebuild-gap so we can see how
            // long the layer was presenting nothing if this is a
            // mid-stream FBO recreation (the prime suspect for black
            // flashes on UHD 10-bit HEVC reconfig events).
            let rebuildSuffix: String
            if fboDestroyedAt > 0 {
                let gapMs = (CFAbsoluteTimeGetCurrent() - fboDestroyedAt) * 1000.0
                rebuildSuffix = " (rebuild_gap=\(String(format: "%.1f", gapMs))ms)"
            } else {
                rebuildSuffix = " (initial)"
            }
            let fboIDs = fboSlots.map { String($0.fbo) }.joined(separator: ",")
            let texNames = fboSlots.map { String(CVOpenGLESTextureGetName($0.texture)) }.joined(separator: ",")
            debugLog("[MPV-FBO] \(streamTag) created \(fboSlots.count)-deep pool \(width)x\(height) fbos=[\(fboIDs)] tex=[\(texNames)]\(rebuildSuffix)")
            #endif

            // Codex VO-handshake fix: a freshly (re)built FBO needs ONE
            // config-commit render so mpv's libmpv VO reconfigures to this
            // target (vo-configured=1). Without an explicit kick, a
            // sparse-callback non-live source can sit with the FBO built but
            // never rendered, so the VO never configures and playback-restart
            // hangs (the Debug-only seeking=1 wedge). Runs on renderQueue (same
            // queue as setupFBO), and requestRender coalesces so it cannot
            // double-dispatch or spin.
            renderTargetNeedsCommit = true
            requestRender(reason: "fbo")
        }

        /// Handle rotation/resize — creates or recreates the GL FBO.
        /// Uses video native dimensions when known to avoid oversized render buffers
        /// (e.g., 720p content rendered into a 1080p buffer wastes 2.25x pixels).
        func handleResize(size: CGSize) {
            let w: Int
            let h: Int
            if videoNativeWidth > 0 && videoNativeHeight > 0 {
                // Render at the video's native resolution, with platform caps.
                // AVSampleBufferDisplayLayer scales to fit the view.
                var targetW = videoNativeWidth
                var targetH = videoNativeHeight

                // v1.7.x: caps are tile-count-aware on both platforms.
                //
                // Before: a flat 1920px dim cap on iOS, plus a tighter
                // pixels/sec budget on tvOS, regardless of session
                // shape. Both caps were sized for the worst case
                // (9-tile multiview, where 9 simultaneous UHD FBOs
                // would consume ~300 MB of GPU memory and ~9 GB/s of
                // bandwidth). At solo playback there is no such
                // shared GPU budget, but a UHD stream like Sky Sports
                // Main Event UHD (3840×2160) was still being
                // downscaled to 1920×1080. Half the pixels thrown
                // away for nothing — the user picked UHD, they should
                // get UHD.
                //
                // Now: solo (MultiviewStore.shared.tiles.count <= 1)
                // gets native UHD up to 3840px on iOS AND tvOS, and
                // the tvOS pixels/sec budget is bypassed for solo.
                // Multi-tile keeps the historical caps so the 9-tile
                // budget stays predictable.
                //
                // tvOS solo native UHD is an experiment at Archie's
                // request 2026-05-08. Apple TV 4K's A15 should be
                // able to sustain native UHD HEVC playback in solo,
                // since the videotoolbox-copy decode + GL ES present
                // is the bottleneck there, not the render-shader
                // downscale. If solo native UHD on tvOS produces
                // stutter, thermal regression, or sustained
                // dropped-frame counts, revert by setting
                // `tvOSAllowSoloNativeUHD = false` here.
                //
                // MultiviewStore is @MainActor; handleResize is
                // always invoked on main (viewDidLayoutSubviews and
                // the playback-restart DispatchQueue.main.async in
                // handlePlaybackRestart), so assumeIsolated is safe.
                let tileCount = MainActor.assumeIsolated { MultiviewStore.shared.tiles.count }
                let isSolo = tileCount <= 1

                #if os(tvOS)
                // Always read container-fps so detectedFps stays
                // populated for STREAM-SUMMARY logs even when we
                // skip the pixels/sec cap (solo path).
                if isLive, let mpv = self.activeMPVHandle() {
                    var fpsVal: Double = 0
                    mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &fpsVal)
                    if fpsVal > 0 {
                        detectedFps = fpsVal
                        // Task #186: live resize path often knows fps
                        // before the first perf-pump tick.
                        applyDisplayCriteriaIfNeeded(fps: fpsVal)
                    }
                }
                // tvOS pixels/sec budget — multi-tile only.
                // tvOS solo bypasses this so the user gets native
                // UHD on Apple TV 4K. tvOS multi-tile keeps the
                // 40M pixels/sec budget so the A15 can sustain
                // smooth playback under N concurrent decodes.
                let tvOSAllowSoloNativeUHD = true
                if isLive && !(tvOSAllowSoloNativeUHD && isSolo) {
                    let fps: Double = detectedFps > 0 ? detectedFps : 30
                    let maxPixelsPerSec: Double = 40_000_000
                    let currentPixelsPerSec = Double(targetW * targetH) * fps
                    if currentPixelsPerSec > maxPixelsPerSec {
                        let scale = sqrt(maxPixelsPerSec / currentPixelsPerSec)
                        targetW = Int(Double(targetW) * scale)
                        targetH = Int(Double(targetH) * scale)
                        // Round to even dimensions for video codecs
                        targetW = targetW & ~1
                        targetH = targetH & ~1
                    }
                }
                #endif

                // Dim cap: solo gets native (3840), multi-tile gets
                // 1920 on both platforms.
                let maxDim: Int = isSolo ? 3840 : 1920
                if targetW > maxDim || targetH > maxDim {
                    let ratio = min(Double(maxDim) / Double(targetW),
                                    Double(maxDim) / Double(targetH))
                    w = Int(Double(targetW) * ratio)
                    h = Int(Double(targetH) * ratio)
                } else {
                    w = targetW
                    h = targetH
                }
            } else {
                // Video dimensions unknown yet — use a small initial buffer.
                // Pre-keyframe frames are broken anyway (PPS errors, software fallback).
                // Resizes to native resolution on PLAYBACK_RESTART.
                #if os(tvOS)
                w = 640; h = 360
                #else
                w = 640; h = 360
                #endif
            }
            guard w > 0 && h > 0 else { return }
            guard w != renderWidth || h != renderHeight else { return }

            renderWidth = w
            renderHeight = h

            // Backstop — `setupRenderer` already called this at
            // viewDidLoad time, but if something skipped that path
            // we still need mpv to start. Idempotent.
            kickstartIfNeeded()

            // Create OpenGL FBO backed by IOSurface CVPixelBuffer.
            // Dispatched to renderQueue so it (a) doesn't block the main thread
            // and (b) runs AFTER setupMPV (which created the EAGLContext).
            // Serial queue guarantees FIFO ordering.
            renderQueue.async { [weak self] in
                self?.setupFBO(width: w, height: h)
            }

            #if DEBUG
            // v1.7.x Issue A: tag matches [MPV-FBO] destroy/created
            // pair so a `grep "[MPV-FBO]"` reads the full FBO
            // lifecycle for one stream in chronological order.
            debugLog("[MPV-FBO] \(streamTag) queued \(w)x\(h)")
            // v1.7.x: log the cap-selection decision so a UHD stream
            // capped to FHD vs allowed-native is visible at a glance.
            // native vs render mismatch == we downscaled.
            if videoNativeWidth > 0 && videoNativeHeight > 0 {
                let native = "\(videoNativeWidth)x\(videoNativeHeight)"
                let rendered = "\(w)x\(h)"
                let downscaled = (w < videoNativeWidth || h < videoNativeHeight)
                debugLog("[MPV-RESIZE] \(streamTag) native=\(native) render=\(rendered) downscaled=\(downscaled)")
            }
            #endif
        }

        // MARK: - CoreAnimation IOSurface re-attach watchdog (v1.7.x Issue A)

        /// Start the display-refresh watchdog. Called once after the
        /// sample buffer layer is in place; idempotent (subsequent
        /// calls are no-ops). The display link runs at the display's
        /// preferred refresh rate (60Hz on iPhone, 120Hz on ProMotion)
        /// and is added to .common run-loop modes so it keeps firing
        /// during scroll gestures and other tracked-mode work.
        @MainActor
        func startWatchdogIfNeeded() {
            guard displayLinkWatchdog == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleWatchdogTick(_:)))
            // ProMotion-friendly: prefer 60Hz, allow 30-120 range so
            // iOS picks the display-aligned cadence. The 30Hz floor
            // guarantees we still tick between mpv frames during
            // libmpv stalls.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLinkWatchdog = link
        }

        /// Tear down the watchdog. Called from the same main-thread
        /// teardown path that releases the layer. Safe to call
        /// multiple times.
        @MainActor
        func stopWatchdog() {
            displayLinkWatchdog?.invalidate()
            displayLinkWatchdog = nil
            os_unfair_lock_lock(&watchdogLock)
            lastEnqueuedSampleBuffer = nil
            os_unfair_lock_unlock(&watchdogLock)
        }

        /// Display-link tick. Runs on the main thread.
        ///
        /// Read `lastEnqueueTime` (touched from renderQueue but
        /// CFAbsoluteTime is a Double — torn reads are at worst a
        /// single tick of false positive/negative on Apple silicon,
        /// not a correctness issue). If the layer hasn't received a
        /// fresh enqueue in `watchdogStaleThreshold` seconds, copy
        /// the most recently enqueued sample buffer with a fresh
        /// host-time PTS and re-enqueue it. The IOSurface backing
        /// stays the same; we're forcing CoreAnimation to attach it
        /// as a fresh contents reference for this VSync.
        ///
        /// Skipped when the layer is .failed (existing background-
        /// pause path handles recovery) or not ready for more media
        /// data (would just be rejected). Watchdog stays silent on
        /// those paths.
        @MainActor
        @objc private func handleWatchdogTick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            let lastEnq = lastEnqueueTime
            let staleAge = now - lastEnq
            // Pre-terminal "stream stalled" report, kept deliberately at the
            // TOP of the tick so it's driven purely by staleAge + isLive/pause
            // and does NOT depend on the renderer-ready / cached-buffer guards
            // that gate the re-enqueue + reload below. Raise at 15s (3s past
            // the first 12s forced reload, so a reload that recovers never
            // trips it); clear the instant real frames resume (staleAge
            // collapses under the 3s floor). The tile turns `streamStalled`
            // into a soft "Reconnecting…" card ~45s before the buffer-relay +
            // LAN/WAN failover + direct-fallback ladder would surface its own
            // terminal error. Not gated on the auto-recover toggle: feedback
            // is owed even when the user disabled forced reloads.
            if streamStalledReported, staleAge < staleStallClearThresholdSec {
                streamStalledReported = false
                progressStore.streamStalled = false
            } else if !streamStalledReported,
                      staleAge >= staleStallReportThresholdSec,
                      isLive,
                      lastAppliedPause != true,
                      // GH #60: same observed-pause gate as the reload sibling.
                      !mpvObservedPaused,
                      // Only report a WEDGE of an actively-playing stream. At a
                      // fresh open / channel swap, `lastEnqueueTime` is still 0
                      // (never enqueued a frame) so `staleAge` = seconds-since-
                      // boot and would fire instantly; and `hasReached…` is the
                      // "playback genuinely started" latch the forced-reload
                      // sibling already uses. Both gates keep the soft card off
                      // the pre-first-frame window (ATV field test 2026-07-13
                      // caught a ~1.8s flash at every channel start).
                      hasReachedPlaybackRestartForStream,
                      lastEnq > 0 {
                streamStalledReported = true
                progressStore.streamStalled = true
                debugLog("[STALL-REPORT] \(streamTag) stale=\(String(format: "%.0f", staleAge * 1000))ms >= \(String(format: "%.0f", staleStallReportThresholdSec * 1000))ms; raising soft reconnecting card")
            }
            // Effective threshold: floor at 30ms (original safety net),
            // scaled to 1.5x the natural frame interval for streams whose
            // container fps puts a real frame more than the floor apart.
            // This is the fix for the v1.7.4.x community report that
            // sub-60fps content (UK 50Hz/25fps, 30fps streams) had the
            // watchdog firing between every real frame. A 25fps stream
            // gets 60ms, 30fps gets 50ms, 60fps stays at 30ms.
            let effectiveThreshold: CFTimeInterval = {
                guard containerFpsHint > 0 else { return watchdogStaleThresholdFloor }
                let naturalInterval = 1.0 / containerFpsHint
                return max(watchdogStaleThresholdFloor, naturalInterval * 1.5)
            }()
            guard staleAge >= effectiveThreshold else { return }
            guard let layer = sampleBufferLayer else { return }
            let renderer = layer.sampleBufferRenderer
            guard renderer.status != .failed,
                  renderer.isReadyForMoreMediaData else { return }

            // Pull the cached buffer under the lock. Don't hold the
            // lock through the CMSampleBuffer copy — it's quick but
            // not free.
            os_unfair_lock_lock(&watchdogLock)
            let cached = lastEnqueuedSampleBuffer
            os_unfair_lock_unlock(&watchdogLock)
            guard let cached else { return }

            // Re-stamp with current host time. AVSBDL will reject a
            // sample whose PTS exactly matches a previously-enqueued
            // sample's PTS, so we must produce a strictly later PTS
            // every tick.
            let freshPTS = CMClockGetTime(CMClockGetHostTimeClock())
            guard let restamped = Self.makeImmediateDisplayCopy(of: cached, at: freshPTS) else { return }
            renderer.enqueue(restamped)

            watchdogReenqueueCount &+= 1
            #if DEBUG
            // Log first re-enqueue + every 60th so we get a clear
            // signal that the watchdog is firing without flooding
            // the console during a sustained stall.
            if watchdogReenqueueCount == 1 || watchdogReenqueueCount % 60 == 0 {
                let staleMs = staleAge * 1000.0
                debugLog("[AVSBDL-WATCHDOG] \(streamTag) re-enqueue #\(watchdogReenqueueCount) (stale=\(String(format: "%.0f", staleMs))ms)")
            }
            #endif

            // v1.7.x stale-frame storm reload: companion to the
            // black-frame reload above. Archie 2026-06-06 second test
            // (Sky Sports Football HD): after an Audio device underrun,
            // mpv stopped delivering frames entirely for ~18s while
            // AVSBDL kept re-enqueueing the last good frame and the
            // network/cache stayed healthy. No black frames so the
            // suppression-based watchdog could not see it - but the
            // re-enqueue staleAge here is the perfect signal: it is
            // exactly "time since the last REAL frame from mpv."
            //
            // Trigger conditions:
            // - staleAge >= 3s (well past any normal VSync skip on a
            //   24-60fps stream; matches "user notices the freeze")
            // - lastAppliedPause != true (do not force-reload a stream
            //   the user just paused)
            // - cooldown elapsed (shared with the black-frame variant
            //   via lastForcedBlackReloadAt so the two watchdogs do
            //   not fire on top of each other)
            // - urls.first available (no URL = nothing to loadfile)
            //
            // Cost: a small set of checks every VSync once we are
            // already in a stale state. The branch is reached only
            // when watchdog re-enqueue has already fired, which by
            // definition means we are NOT in the steady-state hot
            // path of clean playback.
            // isLive gate (parity with the black-frame sibling): off-live
            // the reload is never the right move, and for CATCH-UP it
            // reloaded urls.first (the programme-start URL, re-tunes
            // bypass `urls`) with a stale catchupBaseOffsetMs - snapping
            // a paused/rebuffering replay back to 0:00 under a lying
            // timeline.
            if staleAge >= staleFrameStormThresholdSec,
               isLive,
               lastAppliedPause != true,
               // GH #60: also honor mpv's observed pause - an intentional
               // pause via any path must never read as a wedged stream.
               !mpvObservedPaused,
               watchdogReloadEnabled,
               hasReachedPlaybackRestartForStream {
                let wallNow = CFAbsoluteTimeGetCurrent()
                // #37: suppress the reload after a real resolution change (OTA
                // commercial boundary) so an expected switch stall is not
                // mistaken for a wedge, and cap reloads via the per-stream
                // backoff so a sustained break cannot drive a reload loop.
                if wallNow - lastForcedBlackReloadAt >= blackFrameReloadCooldownSec,
                   wallNow - lastResolutionChangeAt >= resolutionChangeReloadGraceSec,
                   let reloadURL = urls.first,
                   forcedReloadAllowed(now: wallNow) {
                    lastForcedBlackReloadAt = wallNow
                    noteForcedReload()
                    // GH #60: while the Live Rewind relay is active, reload the
                    // RELAY (aeriots://live), never the raw upstream URL. The
                    // old urls.first reload left the engine downloading
                    // headless at full bitrate with no consumer while mpv
                    // opened a SECOND direct connection to Dispatcharr (the
                    // reporter's two-connection screenshot). Reloading the
                    // relay keeps the single app-owned connection + the rewind
                    // window; a genuinely wedged relay still escapes via
                    // relayErrorRecovery -> fallBackToDirectStream, which is
                    // the one path that stops the engine session.
                    let reloadTarget = liveRewindActive ? "aeriots://live" : reloadURL.absoluteString
                    let safeURL = DebugLogger.sanitize(reloadTarget)
                    debugLog("[STALE-RELOAD] \(streamTag) stale=\(String(format: "%.0f", staleAge * 1000))ms >= threshold=\(String(format: "%.0f", staleFrameStormThresholdSec * 1000))ms; issuing loadfile replace to re-prime pipeline (url=\(safeURL.prefix(80)))")
                    DebugLogger.shared.log(
                        "🟡 [MPV-RELOAD] stale-frame storm reload tile=\(tileID ?? "single") stale_ms=\(Int(staleAge * 1000))",
                        category: "MPV-STREAM", level: .warning
                    )
                    // MEMORY-LEAK FIX: same as the black-frame reload below.
                    // Flush the display-layer renderer before re-priming so its
                    // stale enqueued 4K CMSampleBuffers/CVPixelBuffers are not
                    // orphaned across the `loadfile replace`. This stale-frame
                    // path is the one that fires REPEATEDLY on a wedged UHD
                    // stream (7x in 2 min in the 2026-06-29 capture), so without
                    // the flush it is the dominant leak contributor.
                    // `removingDisplayedImage: false` keeps the last frame up.
                    cachedRenderer?.flush(removingDisplayedImage: false)
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else { return }
                        self.mpvCommand(mpv, ["loadfile", reloadTarget, "replace"])
                    }
                }
            }
        }

        /// #37 circuit-breaker shared by both forced-reload watchdog paths.
        /// Returns true if a forced reload is allowed right now (under the
        /// per-window cap), advancing the fixed window when it rolls over.
        /// Call noteForcedReload() only when a reload is actually issued.
        private func forcedReloadAllowed(now: CFAbsoluteTime) -> Bool {
            if now - forcedReloadWindowStart > reloadBackoffWindowSec {
                forcedReloadWindowStart = now
                forcedReloadWindowCount = 0
            }
            return forcedReloadWindowCount < maxForcedReloadsPerWindow
        }

        private func noteForcedReload() {
            forcedReloadWindowCount &+= 1
        }

        /// Build a CMSampleBuffer that points at the same IOSurface
        /// as `source` but with a new presentation timestamp and the
        /// kCMSampleAttachmentKey_DisplayImmediately attachment set.
        /// CMSampleBufferCreateCopyWithNewTiming preserves the format
        /// description and image buffer reference, so the GPU
        /// resources are reused — no extra upload, no extra alloc on
        /// the GPU side. The DisplayImmediately attachment tells
        /// AVSBDL to present the frame ASAP rather than scheduling
        /// it against any internal clock.
        private static func makeImmediateDisplayCopy(of source: CMSampleBuffer, at pts: CMTime) -> CMSampleBuffer? {
            var newTiming = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: source,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &newTiming,
                sampleBufferOut: &copy
            )
            guard status == noErr, let buffer = copy else { return nil }

            // Stamp DisplayImmediately on every sample. The attachment
            // array always has at least one entry per sample for non-
            // empty CMSampleBuffers; our render-side buffers are
            // single-sample so we just set it on index 0.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [Any],
               let dict = attachments.first as? NSMutableDictionary {
                dict[kCMSampleAttachmentKey_DisplayImmediately as String] = kCFBooleanTrue
            }
            return buffer
        }

        // MARK: - Background OpenGL ES Render + Display via AVSampleBufferDisplayLayer

        /// Called from mpv's update callback — schedules render on background thread.
        func scheduleRender() {
            // v1.7.x Issue A: log silences in the mpv update-callback
            // stream. Normal callback cadence on a smooth stream is
            // ~16-33ms (matches the frame interval), with up to ~5ms
            // jitter observed in test runs. Thresholds are tiered so
            // we can tell subtle hiccups apart from severe stalls
            // without making one noisy or the other invisible:
            //
            //   mild     50-100ms — subtle, may be perceptible as a
            //                       brief frame hold; likely
            //                       responsible for the "black
            //                       flashes" Archie reports that
            //                       didn't trip the previous 100ms
            //                       gate.
            //   moderate 100-300ms — definite stall, user-visible.
            //   severe   300ms+   — multi-second stalls (e.g., the
            //                       initial demux warmup or the
            //                       videotoolbox-copy fallback
            //                       chain).
            //
            // Each line means libmpv's internal pipeline stalled
            // (decoder waiting for input, demuxer paused for cache,
            // render-context blocked) — not our render or present
            // path. The first gap of a session is suppressed
            // (lastScheduleRenderTime starts at 0).
            let now = CFAbsoluteTimeGetCurrent()
            if lastScheduleRenderTime > 0 {
                let gapMs = (now - lastScheduleRenderTime) * 1000.0
                if gapMs > 50 {
                    let severity: String
                    if gapMs > 300 {
                        severity = "SEVERE"
                        callbackGapSevereCount &+= 1
                    } else if gapMs > 100 {
                        severity = "moderate"
                        callbackGapModerateCount &+= 1
                    } else {
                        severity = "mild"
                        callbackGapMildCount &+= 1
                    }
                    // v1.7.x Step 8: read mpv's audio-pts and avsync
                    // properties at the moment of the gap. Step 7 also
                    // read mpv's `video-pts`, but that property is
                    // populated by mpv's internal video-output module
                    // — which doesn't run in our setup (we use
                    // `vo=libmpv` and render via mpv_render_context_*).
                    // `video-pts` therefore returned 0.000s for the
                    // entire 22:21 session and our self-computed
                    // `a-v = audio_pts - video_pts` was structurally
                    // bogus (just `audio_pts - 0`). mpv's `avsync`
                    // property IS computed internally — it's mpv's
                    // own audio_position - video_position, updated as
                    // mpv emits frames to us via mpv_render_context_render
                    // — so we use that as the canonical sync metric
                    // here. Codex's CODEX_VIDEO_PTS_AVSYNC_DIAGNOSIS
                    // documented this exact bug class.
                    //
                    // The since_audio_reconfig delta surfaces whether
                    // the gap landed in the wake of an AC3 reconfig
                    // (refuted by the 22:21 data: all 3 reconfigs
                    // fired at startup; mid-playback gaps were 10-33s
                    // after the last reconfig).
                    #if DEBUG
                    // CALLBACK-SAFETY (Codex fix): scheduleRender IS the libmpv
                    // render-update callback. Calling normal libmpv API here
                    // (mpv_get_property) violates the render-callback contract
                    // and is a prime suspect for the Debug-only startup wedge,
                    // so the audio-pts/avsync reads that used to live here were
                    // removed. Only local state is read now; the audio/avsync
                    // figures are still available on the stats path.
                    let sinceAudioReconfig: String
                    if lastAudioReconfigAt > 0 {
                        let deltaMs = (now - lastAudioReconfigAt) * 1000.0
                        sinceAudioReconfig = "\(String(format: "%.0f", deltaMs))ms"
                    } else {
                        sinceAudioReconfig = "n/a"
                    }
                    debugLog("[MPV-CALLBACK-GAP] \(streamTag) update-callback silence: \(String(format: "%.0f", gapMs))ms \(severity) since_audio_reconfig=\(sinceAudioReconfig) (libmpv internal stall; render-callback-safe, no mpv property reads here)")
                    #endif
                }
            }
            lastScheduleRenderTime = now

            requestRender(reason: "callback")
        }

        /// Coalesced render request used by ALL render reasons (the libmpv
        /// update callback, an FBO (re)build, and video reconfig). Codex fix:
        /// one funnel so a setup/FBO kick and a callback render can't race or
        /// double-dispatch. Safe to call from the render-update-callback thread
        /// (touches only the local lock, then hops to renderQueue).
        private func requestRender(reason: String) {
            os_unfair_lock_lock(&renderLock)
            let pending = renderPending
            renderPending = true
            os_unfair_lock_unlock(&renderLock)
            if pending {
                coalescedFrameCount += 1
                return
            }
            renderQueue.async { [weak self] in
                self?.renderAndPresent()
            }
        }

        /// Runs on renderQueue — GPU renders mpv frame to CVPixelBuffer via OpenGL FBO,
        /// then enqueues to AVSampleBufferDisplayLayer. Zero CPU pixel copies.
        private func renderAndPresent() {
            os_unfair_lock_lock(&renderLock)
            renderPending = false
            os_unfair_lock_unlock(&renderLock)

            guard let mpvGL, let eaglContext else { return }
            guard !fboSlots.isEmpty else { return }

            // v1.7.x Step 6 — apply backpressure on
            // AVSampleBufferDisplayLayer's renderer. When the
            // renderer reports `isReadyForMoreMediaData == false`,
            // its internal queue is saturated. Apple's documented
            // guidance (`AVQueuedSampleBufferRendering.h`): "It is
            // safe to call enqueueSampleBuffer when
            // readyForMoreMediaData is NO, but it is a bad idea to
            // enqueue sample buffers without bound."
            //
            // Step 5 (triple-buffered FBO ring) eliminated the
            // single-IOSurface producer/consumer race that caused
            // single-VSync black flashes at ~1 per 12s on UHD HEVC
            // HDR live MPEG-TS playback. Field test 2026-05-08
            // 21:49 confirmed the flashes are gone (`black_supp=2`
            // detector hits over 2400+ frames, watchdog-recovered
            // cleanly). But the ring also removed implicit rate
            // limiting that the single-buffer architecture had been
            // providing — mpv's videotoolbox-copy decoder is faster
            // than the source rate, and with three slots to write
            // into, mpv ran at decoder speed (~70fps for a 30fps
            // source). Symptoms over a 45s playback window:
            //   - rss grew from 350MB → 1224MB (decoded UHD frames
            //     piling up in mpv's output queue waiting for audio
            //     to catch up)
            //   - avsync drifted to 2.058s before audio decoder
            //     reset
            //   - libmpv demuxer logged "Too many packets in the
            //     demuxer packet queues: video/0: 250 packets"
            //   - main thread hung 239-371ms three times under
            //     memory pressure
            //
            // Skipping the entire render pass (not just the
            // enqueue) means we don't call
            // mpv_render_context_render, so mpv's frame stays in
            // mpv's internal queue. mpv's `framedrop=vo` policy
            // drops late frames at the VO layer when the queue
            // fills, which rate-limits the upstream
            // demuxer/decoder pipeline to AVSBDL's consumption
            // rate. The watchdog at line ~2349 already follows the
            // same pattern (refuses re-enqueue when not ready);
            // this unifies the policy across the main path and the
            // watchdog path — both refuse to push when AVSBDL is
            // full.
            // Ask libmpv what needs doing. (Aerio fix on PR #14:
            // MPV_RENDER_UPDATE_FRAME imports as a C enum, convert via
            // `.rawValue` before the bitwise AND.) mpv_render_context_update
            // is safe to call without the GL context current.
            let updateFlags = mpv_render_context_update(mpvGL)
            let hasFrame = (updateFlags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0
            // Codex VO-handshake fix: do ONE bounded config-commit render after
            // each FBO (re)build even when no new frame is pending, so mpv's
            // libmpv VO reaches vo-configured=1 and playback-restart can finish
            // (this is the Debug-only seeking=1 / current-ao=nil wedge). After
            // the commit lands, render only when a real frame is pending.
            let shouldCommitTarget = renderTargetNeedsCommit || !didCommitRenderTarget
            guard hasFrame || shouldCommitTarget else { return }

            // Backpressure: rate-limit only STEADY-STATE frame renders (mpv's
            // videotoolbox-copy decoder can outrun AVSBDL on high-bitrate
            // streams; skipping the whole render pass lets framedrop=vo
            // rate-limit the upstream pipeline, per the block comment above).
            // A config-commit render (and therefore the very first frame) must
            // NOT be skipped on backpressure, or the VO never configures.
            if hasFrame && !shouldCommitTarget,
               let renderer = cachedRenderer,
               !renderer.isReadyForMoreMediaData {
                backpressureSkipCount &+= 1
                return
            }

            let w = fboWidth
            let h = fboHeight
            guard w > 0, h > 0 else { return }

            // v1.7.x Step 5: advance the ring cursor and pick the next slot.
            // mpv writes to slot[renderBufferIndex], we hand THAT slot's pixel
            // buffer to AVSBDL. By the time the cursor wraps back here, AVSBDL
            // has composed and released the previous reference, so no
            // producer/consumer race on the IOSurface.
            renderBufferIndex = (renderBufferIndex + 1) % fboSlots.count
            let renderPixelBuffer = fboSlots[renderBufferIndex].pixelBuffer
            let fbo = fboSlots[renderBufferIndex].fbo

            let renderStart = CACurrentMediaTime()
            let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
            let fps = detectedFps

            // Make our GL context current on the render thread
            EAGLContext.setCurrent(eaglContext)

            // Tell mpv to render into our FBO (GPU handles color conversion, scaling, OSD).
            // withUnsafeMutablePointer ensures the data pointers outlive the render call.
            var fboData = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(w), h: Int32(h), internal_format: 0)
            var flipY: CInt = 0  // Don't flip — CVPixelBuffer and AVSampleBufferDisplayLayer share the same top-down row order
            var blockForTarget: CInt = 0  // Don't block — AVSampleBufferDisplayLayer manages timing
            withUnsafeMutablePointer(to: &fboData) { fboPtr in
                withUnsafeMutablePointer(to: &flipY) { flipPtr in
                    withUnsafeMutablePointer(to: &blockForTarget) { blockPtr in
                        var renderParams = [
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockPtr),
                            mpv_render_param()
                        ]
                        mpv_render_context_render(mpvGL, &renderParams)
                    }
                }
            }

            // Flush GPU work (non-blocking — just ensures commands are submitted)
            glFlush()

            // Codex VO-handshake fix: this mpv_render_context_render call has
            // now configured the libmpv VO against a valid FBO. Mark it so we
            // do the config-commit exactly once per FBO (re)build.
            renderTargetNeedsCommit = false
            didCommitRenderTarget = true
            // If this was a config-only commit (no new frame was pending), do
            // NOT build/enqueue a CMSampleBuffer from the (stale) FBO contents.
            // Just return; mpv can now start playback and the next update
            // callback delivers the first real frame to render + enqueue.
            if !hasFrame { return }

            let renderEnd = CACurrentMediaTime()
            let renderMs = (renderEnd - renderStart) * 1000.0

            // Track frame timing for jitter analysis
            totalFrameCount += 1
            if lastEnqueueTime > 0 {
                let intervalMs = (renderEnd - lastEnqueueTime) * 1000.0
                frameIntervals.append(intervalMs)
                if frameIntervals.count > frameSampleSize { frameIntervals.removeFirst() }
            }
            renderDurations.append(renderMs)
            if renderDurations.count > frameSampleSize { renderDurations.removeFirst() }
            lastRenderTime = renderEnd

            // Detect late frames
            if renderMs > 33.0 { lateFrameCount += 1 }

            // Check display layer readiness before enqueue
            let layerReady = cachedRenderer?.isReadyForMoreMediaData ?? false
            let layerStatus = cachedRenderer?.status

            // v1.7.x Issue A round 3: log AVSBDL state transitions so
            // the next test log shows whether the layer is internally
            // clearing or flagging requiresFlush during the libmpv
            // render stalls (Archie's screen recording showed
            // single-VSync black flashes that we believe correspond
            // to layer-side auto-clear behavior, not anything mpv-
            // side). Logged on transition only, so smooth playback
            // produces zero noise.
            if let renderer = cachedRenderer {
                let currentStatus = renderer.status
                if currentStatus != lastObservedLayerStatus {
                    let from = Self.statusName(lastObservedLayerStatus)
                    let to = Self.statusName(currentStatus)
                    #if DEBUG
                    debugLog("[AVSBDL-STATUS] \(streamTag) renderer.status: \(from) → \(to)")
                    #endif
                    lastObservedLayerStatus = currentStatus
                }
                // iOS 18 deprecated AVSampleBufferDisplayLayer.requiresFlushToResumeDecoding
                // in favour of the renderer-side property of the same
                // name, accessed via the layer's sampleBufferRenderer.
                // Functionally identical, just on AVSampleBufferVideo
                // Renderer (iOS 17+). We already use the renderer-
                // side enqueue API throughout, so this matches our
                // existing path.
                let currentFlush = renderer.requiresFlushToResumeDecoding
                if currentFlush != lastObservedRequiresFlush {
                    #if DEBUG
                    debugLog("[AVSBDL-FLUSH] \(streamTag) requiresFlushToResumeDecoding: \(lastObservedRequiresFlush) → \(currentFlush)")
                    #endif
                    lastObservedRequiresFlush = currentFlush
                }
            }

            // v1.6.8 lock-cycle fix: when the sample-buffer layer
            // is in `.failed` state, skip the enqueue entirely —
            // iOS will reject every buffer we hand it, and the
            // render callback would otherwise spin uselessly,
            // logging a 🔴 LAYER FAILED line per frame for the
            // duration of the failure.
            //
            // Why this happens (the screen-lock case):
            //   1. User locks iPhone during live playback.
            //   2. `didEnterBackground` fires; `pipAutoEligible`
            //      is true (auto-PiP is armed), so the policy
            //      keeps mpv producing frames in case iOS
            //      engages PiP.
            //   3. Screen is OFF, so PiP doesn't actually engage.
            //      VideoToolbox loses its session a few seconds
            //      later (`-12903 invalid session`), mpv falls
            //      back to software decode.
            //   4. AVSampleBufferDisplayLayer transitions to
            //      `.failed` because there's no display surface
            //      to render to.
            //   5. Render loop keeps shipping frames into the
            //      failed layer for ~30 seconds until unlock.
            //      CPU stays warm, battery wasted.
            //
            // The fix: when we detect `.failed` AND we're in
            // background, auto-pause mpv (set `pause=1`). This
            // stops mpv's decode loop, so no more wasted CPU on
            // frames that can't be displayed. The existing
            // `willEnterForeground` handler unpauses via the
            // shared `autoPausedOnBackground` flag and flushes
            // the layer to recover, so the resume path is
            // already wired up.
            //
            // Foreground failures (rare; e.g. transient decoder
            // glitch with the screen on) just skip the enqueue —
            // we don't pause mpv because the user is watching
            // and a brief blank frame is preferable to a
            // surprise pause they didn't ask for.
            var enqueued = false

            // v1.7.x Issue A round 6 (Step 3a): black-frame detector.
            // mpv's VT path occasionally hands us a uniformly-zero
            // CVPixelBuffer in an otherwise smooth frame stream
            // (verified 2026-05-08, 17 events in 76s of UHD HEVC HDR
            // playback). The detector below catches them before we
            // wrap into a CMSampleBuffer; suppression skips the
            // enqueue and leaves lastEnqueuedSampleBuffer untouched
            // so the CADisplayLink watchdog re-enqueues the previous
            // good frame on its next tick. Two-deep surround check
            // ensures we don't suppress legitimate cuts to black.
            // See block-level comment above the state declarations
            // for the full rationale and source.
            let blackProbe = Self.detectBlackFrame(renderPixelBuffer)
            // Probe returned (-1, -1) on lock-failure / non-BGRA;
            // treat that as "don't suppress" (no false positives if
            // the probe itself fails).
            let probeValid = blackProbe.avg >= 0
            // v1.7.x 3a-tighten (2026-05-08): loosened from avg<4
            // and std<1 (pure codec-zero only) to avg<10 and std<8
            // (codec-zero + partial-corruption with small carry-
            // over slivers). Verification showed the bug produces
            // both classes; the surround check below is what
            // protects legitimate dark content. See block comment
            // above the state declarations for the full rationale.
            // Codex fix: never suppress before a real frame has been enqueued.
            // The surround check (prevLuma > 25) starts at the 128 placeholder,
            // so without this gate the very FIRST frame can be mistaken for a
            // black flash and dropped, leaving the player black after the
            // handshake fix lets the first frame through.
            let isSuspectBlackFrame = probeValid
                && lastEnqueueTime > 0
                && blackProbe.avg < 10.0
                && blackProbe.std < 8.0
                && blackFramePrevAvgLuma > 25.0
                && blackFramePrevPrevAvgLuma > 20.0
                // GH #60: suppression is an anti-flash HOLD, not a latch. Past
                // the hold the frame enqueues normally, the luma baseline
                // updates to the dark content, and the detector stops matching
                // - a real ad-break/scene black displays as black instead of a
                // frozen frame + a reload storm.
                && consecutiveBlackFramesSuppressed < blackFrameSuppressHoldFrames

            // GH #60: decoder-wedge discriminator. Zero-FILL frames from a
            // wedged pipeline are bit-flat (avg==0, std==0); real dark content
            // carries dither. Tracked independently of suppression so the
            // storm reload below still catches the genuine sustained wedge
            // (2026-06-06: ~367 zero frames, no spontaneous recovery).
            if probeValid {
                if blackProbe.avg == 0.0 && blackProbe.std == 0.0 {
                    consecutiveZeroFrames &+= 1
                } else {
                    consecutiveZeroFrames = 0
                }
            }

            // Storm reload (GH #60 rework of the v1.7.x watchdog): only a
            // sustained run of BIT-FLAT zero frames marks a wedged pipeline
            // (2026-06-06 field test: ~367 zero frames over 7s, no spontaneous
            // recovery; a loadfile replace re-primed it in ~1s). Real dark
            // content never matches (dither), so ad slates / scene blacks no
            // longer reload - the false-fire behind the 6-7 min glitch cycle.
            // `>=` + the 120s cooldown lets a failed reload retry.
            if consecutiveZeroFrames >= blackFrameStormThreshold,
               // #44 (GH): LIVE ONLY. Recordings/VOD are seekable files, so
               // `loadfile <url> replace` restarts them at 0:00; libmpv
               // reconfigures format changes on a seekable file on its own.
               isLive,
               watchdogReloadEnabled,
               hasReachedPlaybackRestartForStream {
                let now = CFAbsoluteTimeGetCurrent()
                // #37: gate like the stale path - post-resolution-change grace
                // (commercial fade / ad blanking) + per-stream reload backoff.
                if now - lastForcedBlackReloadAt >= blackFrameReloadCooldownSec,
                   now - lastResolutionChangeAt >= resolutionChangeReloadGraceSec,
                   let reloadURL = urls.first,
                   forcedReloadAllowed(now: now) {
                    lastForcedBlackReloadAt = now
                    noteForcedReload()
                    // GH #60: relay-aware reload target - never bypass the
                    // rewind relay with a raw-URL reload (headless engine
                    // download + second Dispatcharr connection).
                    let reloadTarget = liveRewindActive ? "aeriots://live" : reloadURL.absoluteString
                    let safeURL = DebugLogger.sanitize(reloadTarget)
                    debugLog("[BLACK-RELOAD] \(streamTag) zeroFrames=\(consecutiveZeroFrames) >= threshold=\(blackFrameStormThreshold); issuing loadfile replace to re-prime pipeline (url=\(safeURL.prefix(80)))")
                    DebugLogger.shared.log(
                        "🟡 [MPV-RELOAD] black-frame storm reload tile=\(tileID ?? "single") zero_consec=\(consecutiveZeroFrames)",
                        category: "MPV-STREAM", level: .warning
                    )
                    // MEMORY-LEAK FIX (5ce93cf): flush the display-layer
                    // renderer BEFORE re-priming so its enqueued 4K
                    // CMSampleBuffers are not orphaned across the reload.
                    // `removingDisplayedImage: false` keeps the last good
                    // frame on screen, so no black flash.
                    cachedRenderer?.flush(removingDisplayedImage: false)
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else { return }
                        self.mpvCommand(mpv, ["loadfile", reloadTarget, "replace"])
                    }
                }
            }

            if layerStatus == .failed {
                if isInBackground && markAutoPausedOnBackgroundIfNeeded() {
                    mpvQueue.async { [weak self] in
                        guard let self, let mpvHandle = self.activeMPVHandle() else { return }
                        var pauseFlag: Int32 = 1
                        mpv_set_property(mpvHandle, "pause", MPV_FORMAT_FLAG, &pauseFlag)
                    }
                    #if DEBUG
                    debugLog("[MPV-BG] Background: sampleBufferRenderer FAILED — auto-paused mpv to stop wasted decode work")
                    #endif
                } else if !isInBackground {
                    // v1.7.x diagnostic: foreground sample-buffer-layer
                    // failures present as black-screen flashes during
                    // playback (Archie 2026-05-08, UHD/high-bitrate).
                    // Log every 30th occurrence so we capture the
                    // pattern without flooding the log on a sustained
                    // failure run. Includes layer-failure-error if
                    // we can pull it from the renderer (iOS 17+ exposes
                    // .error on the renderer).
                    layerFailedFrameCount &+= 1
                    if layerFailedFrameCount == 1 || layerFailedFrameCount % 30 == 0 {
                        let err = cachedRenderer?.error?.localizedDescription ?? "nil"
                        #if DEBUG
                        debugLog("[MPV-LAYER] \(streamTag) FOREGROUND layer .failed (frame #\(layerFailedFrameCount), enqueue skipped) — error=\(err)")
                        #endif
                        DebugLogger.shared.log(
                            "🔴 [MPV-LAYER] foreground .failed tile=\(tileID ?? "single") frame=\(layerFailedFrameCount) error=\(err)",
                            category: "MPV-STREAM", level: .error
                        )
                    }
                }
            } else if isSuspectBlackFrame {
                // Suppress: don't build a CMSampleBuffer, don't
                // enqueue, don't update lastEnqueuedSampleBuffer.
                // The CADisplayLink watchdog will tick within
                // ~16ms and re-enqueue the previously-cached good
                // sample buffer with a fresh PTS, so the user sees
                // the previous frame held instead of solid black.
                blackFramesSuppressedCount &+= 1
                consecutiveBlackFramesSuppressed &+= 1
                #if DEBUG
                if blackFramesSuppressedCount == 1 || blackFramesSuppressedCount % 10 == 0 {
                    debugLog("[BLACK-DETECT] \(streamTag) suppressed black frame #\(blackFramesSuppressedCount) (consec=\(consecutiveBlackFramesSuppressed) avg=\(String(format: "%.2f", blackProbe.avg)) std=\(String(format: "%.2f", blackProbe.std)) prev=\(String(format: "%.0f", blackFramePrevAvgLuma)) prev_prev=\(String(format: "%.0f", blackFramePrevPrevAvgLuma)))")
                }
                #endif
                // GH #60: history deliberately stays frozen ONLY for the short
                // anti-flash hold. Past blackFrameSuppressHoldFrames the
                // isSuspectBlackFrame gate above goes false, the frame takes
                // the normal enqueue path below, and the luma baseline updates
                // to the dark content - so a genuine cut to black displays as
                // black and the detector stops matching. The storm reload
                // moved out of this branch and is keyed to the bit-flat
                // zero-frame counter (see below the detector).
            } else if let sampleBuffer = Self.makeSampleBuffer(from: renderPixelBuffer, presentationTime: presentationTime) {
                nonisolated(unsafe) let sb = sampleBuffer
                cachedRenderer?.enqueue(sb)
                enqueued = true
                // v1.7.x: a real (non-black) frame landed, so the
                // black-frame storm reload watchdog's consecutive
                // counter resets. lastForcedBlackReloadAt stays set
                // so the cooldown still gates the next forced reload
                // - we do not want a one-good-frame-then-storm-again
                // pattern to bypass the cooldown.
                consecutiveBlackFramesSuppressed = 0
                didEnqueueFirstVideoFrame = true   // Codex handshake fix: a real frame has now been presented
                // v1.7.x Issue A round 4: cache the latest enqueued
                // buffer for the IOSurface re-attach watchdog. Stored
                // under watchdogLock so the main-thread display-link
                // tick can read it safely.
                os_unfair_lock_lock(&watchdogLock)
                lastEnqueuedSampleBuffer = sb
                os_unfair_lock_unlock(&watchdogLock)
                // v1.7.x Issue A round 6: update luma history for
                // the next-frame surround check, ONLY on successful
                // enqueue. Suppressed frames don't update history
                // (see comment in the suppression branch above).
                if probeValid {
                    blackFramePrevPrevAvgLuma = blackFramePrevAvgLuma
                    blackFramePrevAvgLuma = blackProbe.avg
                }
                // v1.7.x: clear the failed-count once we successfully
                // enqueue a frame, so a transient blip doesn't carry
                // the count forward into a future event.
                if layerFailedFrameCount > 0 {
                    #if DEBUG
                    debugLog("[MPV-LAYER] \(streamTag) layer recovered after \(layerFailedFrameCount) failed frames")
                    #endif
                    layerFailedFrameCount = 0
                }
            } else {
                // v1.7.x: makeSampleBuffer returned nil. This is rare
                // (CMSampleBuffer construction failure indicates either
                // a corrupt pixel buffer from libmpv's render path or
                // an OOM-class CoreMedia allocator failure). Log so we
                // can correlate with user-visible black flashes.
                makeSampleBufferNilCount &+= 1
                if makeSampleBufferNilCount == 1 || makeSampleBufferNilCount % 30 == 0 {
                    #if DEBUG
                    debugLog("[MPV-LAYER] \(streamTag) makeSampleBuffer returned nil (count=\(makeSampleBufferNilCount))")
                    #endif
                    DebugLogger.shared.log(
                        "🟠 [MPV-LAYER] makeSampleBuffer nil tile=\(tileID ?? "single") count=\(makeSampleBufferNilCount)",
                        category: "MPV-STREAM", level: .warning
                    )
                }
            }

            let enqueueTime = CACurrentMediaTime()
            let intervalMs = lastEnqueueTime > 0 ? (enqueueTime - lastEnqueueTime) * 1000.0 : 0
            let expectedIntervalMs = fps > 0 ? 1000.0 / fps : 33.3
            // v1.7.x Issue A: split present-time out of the existing
            // renderMs (which only covers mpv_render_context_render +
            // glFlush, ending at renderEnd). presentMs is everything
            // between renderEnd and enqueueTime — i.e., the failed-
            // layer check + makeSampleBuffer + AVSBDL.enqueue. Lets
            // us tell layer-side stalls (CoreMedia/AVSBDL) apart from
            // libmpv-side stalls. If render is slow → mpv. If present
            // is slow → CoreMedia / AVSampleBufferDisplayLayer. If
            // both are normal but interval is huge → mpv was silent
            // (catch this via [MPV-CALLBACK-GAP]).
            let presentMs = (enqueueTime - renderEnd) * 1000.0

            // ── Per-frame diagnostics ──
            // DEBUG-only, with tight frame caps. This block previously
            // printed every frame for the first 120 frames (~4 seconds
            // of playback at 30fps), which on Apple TV 4K with 2
            // concurrent tiles meant ~60 print()s per second during
            // startup — enough allocation churn to visibly stutter the
            // UI and audio on thermally-throttled hardware. Now:
            //   - Gated on #if DEBUG so release builds do zero work.
            //   - First-frame ramp cut from 120 → 30 (1 second, enough
            //     to catch pipeline warm-up anomalies).
            //   - Anomaly prints remain (unbounded) because those are
            //     the diagnostic signal we actually care about when
            //     investigating lag.
            #if DEBUG
            // Anomaly = something the developer actually wants to see.
            // The old definition flagged `intervalMs < expected * 0.3`
            // (i.e. frames arriving faster than expected) as an anomaly,
            // but live MPEG-TS streams coalesce frames in bursts via
            // the packetizer — sub-10ms intervals are the rule, not an
            // exception, and the old threshold generated hundreds of
            // ⚠️ lines per minute per tile. At 9 tiles that's thousands
            // of string allocations + stdout writes per minute, enough
            // to make the Xcode console laggy and noticeably affect the
            // debug-build feel. Now: only flag LATE frames (interval >
            // 2× expected) and hard failures (layer not ready / failed
            // / enqueue rejected). Fast-arrival bursts are expected and
            // no longer logged.
            // v1.7.x Issue A: presentMs > 33 flags layer-side stalls
            // (CoreMedia / AVSampleBufferDisplayLayer). With renderMs
            // already gating libmpv-side stalls (see lateFrameCount
            // increment above), this gives us per-frame breakdown of
            // where the slow path is when an interval anomaly fires.
            let isAnomaly = intervalMs > 0 && (
                intervalMs > expectedIntervalMs * 2.0 ||
                presentMs > 33.0 ||
                !layerReady || layerStatus == .failed || !enqueued
            )

            if totalFrameCount <= 30 || isAnomaly {
                let tag = isAnomaly ? "⚠️" : "🎞️"
                // `streamTag` up front so log consumers can filter /
                // group per channel (e.g. `grep "NBC Sports"` to see
                // just that tile's frame history).
                debugLog("\(tag) \(streamTag) [FRAME #\(totalFrameCount)] render=\(String(format: "%.1f", renderMs))ms present=\(String(format: "%.1f", presentMs))ms interval=\(String(format: "%.1f", intervalMs))ms expected=\(String(format: "%.1f", expectedIntervalMs))ms fps=\(String(format: "%.1f", fps)) pts=\(String(format: "%.3f", CMTimeGetSeconds(presentationTime)))s ready=\(layerReady) enqueued=\(enqueued) status=\(layerStatus == .failed ? "FAILED" : "ok")")
            }
            #endif

            if layerStatus == .failed, let err = cachedRenderer?.error {
                debugLog("🔴 \(streamTag) [LAYER FAILED] \(err.localizedDescription)")
            }

            // Periodic summary every 300 frames
            if totalFrameCount > 0 && totalFrameCount % 300 == 0 {
                let avgRender = renderDurations.isEmpty ? 0 : renderDurations.reduce(0, +) / Double(renderDurations.count)
                let maxRender = renderDurations.max() ?? 0
                let avgInt = frameIntervals.isEmpty ? 0 : frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                let jitter: Double = {
                    guard frameIntervals.count > 2 else { return 0 }
                    let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
                    let variance = frameIntervals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(frameIntervals.count)
                    return sqrt(variance)
                }()
                debugLog("📊 \(streamTag) [FRAME SUMMARY #\(totalFrameCount)] render=\(String(format: "%.1f", avgRender))ms avg / \(String(format: "%.1f", maxRender))ms max | interval=\(String(format: "%.1f", avgInt))ms avg | jitter=\(String(format: "%.2f", jitter))ms | late=\(lateFrameCount) | coalesced=\(coalescedFrameCount) | watchdog_reenq=\(watchdogReenqueueCount) | black_supp=\(blackFramesSuppressedCount) | bp_skip=\(backpressureSkipCount) | gaps=\(callbackGapMildCount)/\(callbackGapModerateCount)/\(callbackGapSevereCount)(mild/mod/sev) | audio_reconfigs=\(audioReconfigCount) | fps_detected=\(String(format: "%.2f", detectedFps)) | layer=\(layerStatus == .failed ? "FAILED" : "ok")")
            }

            lastEnqueueTime = enqueueTime
        }

        /// Task #149: the ONE native catch-up re-tune implementation
        /// (seek commits, +/-30s skips, and the transient-load-error
        /// retry all funnel here). Must be called on mpvQueue. Mints a
        /// session at programmeStart+clampedMs, revokes the outgoing
        /// one, and loads the new window. Serialized: while a mint is
        /// in flight, callers park the newest target in
        /// `nativeRemintPendingMs` and this method chases it (revoking
        /// the never-played intermediate session) when the mint lands.
        func startNativeRetune(cu: CatchupPlayback, clampedMs: Int32) {
            nativeRemintInFlight = true
            let previousURL = catchupCurrentURL ?? cu.url
            let offsetSecs = Double(clampedMs) / 1000.0
            Task { [weak self] in
                guard let self else { return }
                let newURL = await CatchupSupport.remintNative(
                    playback: cu,
                    currentURL: previousURL,
                    offsetSeconds: offsetSecs)
                self.mpvQueue.async { [weak self] in
                    guard let self else { return }
                    self.nativeRemintInFlight = false
                    if let pending = self.nativeRemintPendingMs {
                        // A newer target arrived while minting: the
                        // session we just minted was never played, so
                        // free its provider slot and chase the newest
                        // target instead of loading a stale window.
                        self.nativeRemintPendingMs = nil
                        if let newURL {
                            CatchupSupport.revokeNative(playback: cu, currentURL: newURL)
                        }
                        self.startNativeRetune(cu: cu, clampedMs: pending)
                        return
                    }
                    guard let newURL else {
                        debugLog("[CATCHUP] native re-mint failed; keeping current window")
                        return
                    }
                    guard let mpv = self.activeMPVHandle() else {
                        // Player tore down while minting: don't leak the slot.
                        CatchupSupport.revokeNative(playback: cu, currentURL: newURL)
                        return
                    }
                    CatchupSupport.revokeNative(playback: cu, currentURL: previousURL)
                    self.catchupBaseOffsetMs = clampedMs
                    self.catchupPendingSeekSecs = nil
                    self.catchupCurrentURL = newURL
                    CatchupRelay.currentHeaders = self.headers
                    let relayURL = CatchupRelay.wrap(newURL)
                    self.mpvCommandAsync(mpv, ["loadfile", relayURL.absoluteString, "replace"])
                    let ps = self.progressStore
                    DispatchQueue.main.async { ps.currentMs = clampedMs }
                    debugLog("[CATCHUP] native re-tune to \(clampedMs / 1000)s")
                }
            }
        }

        func stop() {
            let mpvToStop = markShuttingDownAndSnapshotMPV()
            stopStreamInfoTimer()
            #if os(tvOS)
            // Task #186: drop our refresh-rate preference so the UI
            // returns to the panel default outside the player.
            clearDisplayCriteria()
            #endif
            DebugLogger.shared.logPlayback(event: "Stop",
                                           url: urls[safe: currentIndex]?.absoluteString)
            // Task #149: free the native catch-up session's provider slot
            // ahead of its idle TTL. Best-effort, fire-and-forget (the
            // helper spawns its own Task).
            if let cu = catchup, cu.nativeChannelUUID != nil {
                CatchupSupport.revokeNative(playback: cu,
                                            currentURL: catchupCurrentURL ?? cu.url)
            }

            if let mpv = mpvToStop {
                // Kill the wakeup callback immediately so no further readEvents()
                // hops land on mpvQueue after we begin dismantling state.
                mpv_set_wakeup_callback(mpv, nil, nil)
                if let retain = takeWakeupRetain() {
                    retain.release()
                }

                // Send `quit` FIRST so mpv begins aborting in-flight I/O and
                // unwinding the demuxer before the render teardown runs, which
                // lets the (potentially-blocking) mpv_render_context_free
                // return promptly instead of waiting on a parked core.
                //
                // CRITICAL: this MUST be the ASYNC command. mpv_command (the
                // sync `mpvCommand` helper) blocks the caller until the core
                // services it, and an in-progress HLS recording's lavf demuxer
                // is parked on a network read of a not-yet-published live
                // segment, so a synchronous quit on the MAIN THREAD froze the
                // UI for up to network-timeout seconds (the >5s watchdog freeze
                // leaving an in-progress DVR recording). mpv_command_async
                // queues quit and returns immediately; it is acted on once the
                // core's read returns. A normal live MPEG-TS channel never hit
                // the sync block because its demuxer is on a continuously-
                // flowing socket, not parked on a future segment.
                mpvCommandAsync(mpv, ["quit"])

                // Tear down render resources OFF the main thread on renderQueue,
                // then run mpv_terminate_destroy on mpvQueue once the render
                // context free has completed. This preserves the required
                // ordering (render_context_free BEFORE terminate_destroy)
                // without the old fixed 0.5s timer, and never blocks main.
                //
                // takeMPVHandle() nils state.mpv, so if MPV_EVENT_SHUTDOWN's
                // handler reaches its own terminate_destroy first this becomes
                // a no-op (and vice versa); exactly one path destroys.
                teardownRenderResourcesAsync { [weak self] in
                    if let m = self?.takeMPVHandle() {
                        mpv_terminate_destroy(m)
                    }
                }
            }

            // Only the coordinator that currently owns the bridge
            // tears it down. In multiview, if an ordinary (non-audio)
            // tile is dismantled, its coordinator must NOT call
            // teardown — otherwise it nukes the audio tile's
            // lockscreen info. Single-mode (tileID == nil) and audio
            // tiles both satisfy `shouldDriveNowPlayingBridge()` and
            // correctly tear down.
            Task { @MainActor [weak self] in
                guard let self, self.shouldDriveNowPlayingBridge() else { return }
                NowPlayingBridge.shared.teardown()
            }

            // Release our claim on the idle timer + audio session. If
            // this is the last active coordinator (single-mode stop,
            // or the final tile of a multiview teardown), the refcount
            // drops to 0 and restores the idle timer + deactivates the
            // audio session. Otherwise it's a no-op.
            //
            // `AudioSessionRefCount` is NOT @MainActor — it's
            // internally serialised on a private dispatch queue, so we
            // call it synchronously to keep its inc/dec pair tightly
            // correlated with coordinator lifetime. Routing it through
            // `Task { @MainActor }` added a window where the new
            // coordinator's increment could race the old coordinator's
            // decrement across actor hops. The idle-timer refcount
            // still needs @MainActor because UIApplication is main-
            // thread-only — that one stays in the Task wrapper.
            AudioSessionRefCount.decrement()
            Task { @MainActor in IdleTimerRefCount.decrement() }
        }

        // MARK: - mpv Setup (runs on mpvQueue)

        private func setupMPV() {
            setupStartTime = Date()
            #if DEBUG
            debugLog("[MPV-DIAG] setupMPV: creating mpv instance...")
            // Per-phase timing markers. Each checkpoint logs the
            // delta since the previous one, so we can pinpoint which
            // phase is eating the ~2s first-tile cost. `phaseStart`
            // resets at each checkpoint.
            let setupT0 = Date()
            var phaseStart = setupT0
            func markPhase(_ name: String) {
                let now = Date()
                let ms = Int(now.timeIntervalSince(phaseStart) * 1000)
                let totalMs = Int(now.timeIntervalSince(setupT0) * 1000)
                debugLog("[MPV-PHASE] \(streamTag) \(name): \(ms)ms (total=\(totalMs)ms)")
                phaseStart = now
            }
            #endif

            mpv = mpv_create()
            #if DEBUG
            markPhase("mpv_create")
            #endif
            guard let mpv else {
                logStore.append("✗ MPV: failed to create instance")
                let callback = onFatalError
                Task { await callback("MPV: failed to create player") }
                return
            }

            // ── Pre-init options ──

            // Request error-level logs in release builds so we can detect
            // GL interop failures (10-bit HEVC) and fall back dynamically.
            //
            // DEBUG builds default to `warn` — enough to catch real
            // issues without flooding the log. A previous iteration
            // raised several subsystems (ffmpeg, stream, stream_lavf,
            // http, demux, tls) to `info` while diagnosing a
            // `MPV_ERROR_LOADING_FAILED` bug; that's resolved and
            // the info-level noise was costing main-thread time on
            // a thermally-throttled Apple TV (dozens of mpv-event
            // callbacks per second routing through DebugLogger +
            // print). If another HTTP/TLS investigation comes up,
            // re-enable selectively at that point — don't leave
            // info-level on for everyone permanently.
            // Catch-up timeshift: the server advertises an ESTIMATED
            // Content-Length (Dispatcharr computes it from bitrate *
            // duration), so ffmpeg's open-time duration probe -- a seek
            // to the advertised end to read the last PTS -- lands past
            // the real data, fails, and then the recovery seek back to 0
            // fails too, killing the load with "nothing to play". Marking
            // the stream unseekable skips the end probe entirely. The
            // player never needs byte-range seeks here anyway: the
            // timeline is pinned to the programme duration and every
            // scrub re-tunes via a rebuilt /timeshift/ URL (same model
            // as the Android UnboundedLengthDataSource fix). Scoped to
            // this instance, which only ever plays catch-up streams.
            // Both option sets are needed: mpv may route the URL through
            // its stream layer (stream-lavf-o) or hand it to libavformat
            // directly inside demux_lavf (demuxer-lavf-o) depending on
            // the protocol match, and the http AVOptions only apply to
            // whichever layer actually opens the connection.
            if catchup != nil {
                let r1 = mpv_set_option_string(mpv, "stream-lavf-o", "seekable=0")
                let r2 = mpv_set_option_string(mpv, "demuxer-lavf-o", "seekable=0")
                debugLog("[CATCHUP] mpv unseekable opts set: stream-lavf-o=\(r1) demuxer-lavf-o=\(r2)")
            }

            #if DEBUG
            checkError(mpv_request_log_messages(mpv, "warn"))
            #else
            checkError(mpv_request_log_messages(mpv, "error"))
            #endif

            checkError(mpv_set_option_string(mpv, "subs-match-os-language", "yes"))
            checkError(mpv_set_option_string(mpv, "subs-fallback", "yes"))

            // vo=libmpv: app drives rendering via OpenGL ES render API.
            // GPU renders to CVPixelBuffer via IOSurface-backed FBO (zero copy).
            checkError(mpv_set_option_string(mpv, "vo", "libmpv"))
            checkError(mpv_set_option_string(mpv, "profile", "fast"))  // Disable expensive post-processing for mobile

            // CarPlay: never bring the video pipeline up. Set as a PRE-INIT
            // option (not a runtime property) so no frame is ever decoded or
            // handed to the GL presenter. This is the driver-safety default
            // AND the reason audio plays in the iOS Simulator, whose OpenGL ES
            // presenter fails (CVOpenGLESTextureCacheCreateTextureFromImage
            // -6683) and would otherwise stall the demuxer/decoder waiting on a
            // VO that can never drain. The lifecycle handlers keep it `no` for
            // the whole CarPlay session.
            if initialVideoSuppressed {
                checkError(mpv_set_option_string(mpv, "vid", "no"))
                #if DEBUG
                debugLog("[MPV-CARPLAY] setupMPV: vid=no (audio-only start, CarPlay)")
                #endif
            }

            #if targetEnvironment(simulator)
            checkError(mpv_set_option_string(mpv, "hwdec", "no"))
            #else
            // v1.7.x: hwdec default is now videotoolbox-copy.
            //
            // Until v1.7.x we started in plain `videotoolbox` (zero-
            // copy IOSurface→GL interop) and only fell back to
            // videotoolbox-copy when GL interop failed (which it
            // always does on 10-bit p010, i.e. UHD HDR HEVC). The
            // fallback path issued a seek-to-current-time to force
            // pipeline reinit; on live streams that seek fails with
            // "Cannot seek in this stream" but mpv still does a full
            // pipeline restart. Combined with the failed videotoolbox
            // attempt and the second decoder warmup that followed,
            // the fallback added ~2 seconds of blue-screen time on
            // every UHD HEVC stream open (full breakdown in Archie's
            // 2026-05-08 test logs).
            //
            // videotoolbox-copy decodes to a CPU-readable buffer,
            // which we then upload to GL. Cost: roughly 1-2ms per
            // frame at 1080p, 3-4ms at UHD on Apple silicon —
            // negligible against a 33ms frame budget. No decode-
            // quality difference, no codec compatibility difference.
            //
            // Field reports indicate plain videotoolbox often fails
            // GL interop on 10-bit content anyway, so the "zero-copy
            // happy path" has become a minority of streams in
            // practice. Starting in copy mode unifies the path,
            // halves the visible blue-screen window on UHD streams,
            // and removes the failed-attempt + seek + reinit chain.
            //
            // The log-handler fallback below stays in as a safety
            // net (claimHwdecFallbackIfNeeded is idempotent), but
            // the seek-to-current-time inside it has been removed —
            // it was the no-op that created the second 2-second
            // window, and the fallback shouldn't normally fire now
            // that we start in copy mode.
            //
            // To revert: change "videotoolbox-copy" back to
            // "videotoolbox" here AND in the matching warmup call
            // (~line 160) AND in the loadfile-replace reset inside
            // play(url:) (~line 3036).
            checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox-copy"))
            // Allow up to 90 consecutive VT decode failures before
            // falling back to software. Live MPEG-TS streams join
            // mid-GOP without SPS/PPS so VT errors until the next
            // keyframe — at 30fps, 90 frames covers a ~3s GOP, which
            // is the upper bound for well-behaved broadcast streams.
            // Dropped from the previous 600 because that was
            // effectively "never fallback" (20 seconds of dropped
            // frames at 30fps) and meant a genuinely VT-incompatible
            // stream would burn CPU on doomed attempts for 20
            // seconds before giving up. 90 is a better ceiling that
            // still covers real mid-GOP joins. The explicit
            // videotoolbox-copy retry in the log-message handler
            // (below, ~line 1338) is a secondary safety net for
            // "Initializing texture for hardware decoding failed".
            // Task #56 revision: 90 was tuned as "a ~3s GOP at 30fps", but
            // the 4K HEVC HDR channels this ceiling exists to protect run
            // 50/60fps -- at 60fps, 90 frames is only 1.5s, LESS than a
            // typical 2-5s broadcast GOP, so a routine mid-GOP join tripped
            // the ceiling before the first keyframe ever arrived and parked
            // 4K playback in software decode permanently (the #56 failure
            // signature; MPVKit/FFmpeg version bumps verified irrelevant).
            // 300 covers a 5s GOP at 60fps. The cost on a genuinely
            // VT-incompatible stream is a longer doomed-attempt window, but
            // Apple silicon hardware-decodes all HEVC Main/Main10 broadcast
            // profiles, so that case is theoretical; the hwdec-current
            // observer's one-shot re-assert (task #56) also backstops any
            // fallback that does happen.
            checkError(mpv_set_option_string(mpv, "hwdec-software-fallback", "300"))
            // Cap libavcodec decode threads. Matters only on the
            // software-decode fallback path (hardware VT decode
            // doesn't use lavc threads). With 2–4 concurrent tiles
            // on a 6-core Apple TV 4K, letting lavc's default
            // auto-detect spawn one-thread-per-core per tile
            // oversubscribes the CPU and is observable as audio
            // underruns + UI lag. Pinning each tile's SW fallback
            // to a single thread keeps the total thread count
            // bounded at (tile count + 1 demuxer + 1 audio) ≈ 6
            // on the 9-tile ceiling. Hardware decode is unaffected.
            checkError(mpv_set_option_string(mpv, "vd-lavc-threads", "1"))
            #endif

            // Initial buffer before playback starts:
            // Live: 0 — start decoding the instant any data arrives.
            //        Previously 0.5s, which was a guaranteed 500ms
            //        floor on every channel tap's first frame. mpv
            //        still waits for the first decodable keyframe
            //        (so you don't get garbled output) but won't add
            //        a synthetic buffer delay on top.
            // VOD:  1s, resume quickly after a seek. Was 2s; halved so
            //        scrubbing buffers back faster (user feedback: "seeking
            //        is slow to buffer"). Still enough prefill to ride out
            //        the typical post-seek segment fetch on VOD/DVR.
            // Stream buffer cushion (App Behaviors → Stream Buffer): when the
            // user sets a non-zero cushion, live prefills that many SECONDS
            // before the first frame instead of starting on first byte
            // (0). VOD/DVR keep their 1s prefill. 0 = byte-identical to the
            // prior low-latency live path.
            let streamBufMs = Int(UserDefaults.standard.double(forKey: "appBehaviorsStreamBufferSeconds") * 1000)
            // #37 kill-switch: read once per tune (applies to the next channel,
            // like Stream Buffer). Default true = watchdog auto-reload on.
            watchdogReloadEnabled = (UserDefaults.standard.object(forKey: "appBehaviorsAutoRecoverFrozenStreams") as? Bool) ?? true
            let cachePauseWait: String = {
                if isLive {
                    return streamBufMs > 0 ? String(Double(streamBufMs) / 1000.0) : "0"
                }
                return "1"
            }()
            setOption(mpv, "cache-pause-wait", cachePauseWait)

            // ────────────────────────────────────────────────────────
            // Startup-speed options. These collectively shave ~1-2s
            // off "tap → first frame" on live MPEG-TS streams.
            //
            // `audio-wait-open=no`: don't block video first-frame on
            // the audio output being open. On iOS the AudioUnit AO
            // adds 100-400ms during channel changes; decoupling
            // video from that wait is a straight win.
            //
            // `initial-audio-sync=no`: don't hold video back to
            // align with the first audio frame. For live TS with no
            // duration metadata this alignment is ~100-300ms of pure
            // delay with no user-visible benefit.
            //
            // `vd-lavc-fast=yes` + `vd-lavc-skiploopfilter=nonref`:
            // when SW decode is active (fallback path), skip the
            // deblocking loop filter on non-reference frames and
            // enable speed-over-quality codec flags. No-op for VT
            // hwdec; matters when VT fails mid-GOP.
            //
            // `stream-lavf-o=reconnect=...`: libavformat-level HTTP
            // reconnect for mid-stream drops. Not a first-frame win
            // but critical for retry behavior on intermittent
            // network — faster recovery instead of burning the
            // 5-second premature-end retry path.
            //
            // `network-timeout=10`: explicit 10s timeout so a
            // genuinely-dead host fails over to the next URL in the
            // fallback list within 10s instead of mpv's 60s default.
            // `audio-wait-open=no` — REMOVED. This option was
            // rejected by MPVKit's bundled mpv build (the
            // `setOption` diagnostic wrapper logged it as
            // `option "audio-wait-open"="no" rejected`). In theory
            // it shaves 100-400ms off first frame on iOS by not
            // blocking video on AudioUnit open, but it's not
            // available on this libmpv version so adding it was a
            // silent no-op at best and potentially a side-effect
            // failure at worst. Leaving the intent here as a
            // reminder in case a future MPVKit bump brings it in.
            setOption(mpv, "initial-audio-sync", "no")
            // GH #56 (OTA HDHR AC-3 black-screen): make an audio-output OPEN
            // FAILURE non-fatal. On tvOS an AC-3 (ATSC A/52A) stream can hit a
            // HDMI route-change (routeConfig) partway through open; mpv's
            // audiounit ao then fails to init, and WITHOUT this option mpv aborts
            // the WHOLE file (END_FILE error -> "loading failed" -> black screen +
            // the yellow error overlay, retrying ~1 min before the route settles).
            // With audio-fallback-to-null the ao falls back to null and VIDEO KEEPS
            // PLAYING; runAudioHealthCheck then reinits real audio (stereo downmix)
            // once the route is stable. This is why the AVPlayer-remux path (system
            // audio) never hit it. setOption so an option this MPVKit build lacks is
            // a logged no-op, not a hard failure (cf. audio-wait-open above).
            setOption(mpv, "audio-fallback-to-null", "yes")
            setOption(mpv, "vd-lavc-fast", "yes")
            setOption(mpv, "vd-lavc-skiploopfilter", "nonref")
            // `stream-lavf-o=reconnect=...`: libavformat-level HTTP reconnect
            // for mid-stream drops, faster recovery than burning the 5-second
            // premature-end retry path. This is the proven 1.7.3 value applied
            // to all streams. (An isLive-split variant was tried while chasing
            // the Debug VOD/DVR wedge and reverted: that wedge was a render
            // VO-config handshake bug, not a reconnect issue.)
            setOption(
                mpv,
                "stream-lavf-o",
                "reconnect=1,reconnect_streamed=1,reconnect_delay_max=2"
            )
            // `network-timeout=30` — raised from 10s. The tighter
            // timeout triggered `tls: IO error: Operation timed out`
            // on a user's WAN route when their LAN probe hadn't
            // completed in time and the app fell back to the
            // external FQDN. TLS handshake + HTTP headers over a
            // cold WAN route can genuinely take more than 10s on a
            // first hit (cert fetch, OCSP, CDN cold-start). 30s
            // matches mpv's default and is permissive enough for
            // cold starts while still failing over faster than
            // mpv's `stream-lavf-o=reconnect_delay_max` reconnect
            // storm (which is 2s per attempt). Retry behaviour on
            // a truly dead host is unchanged — URL-list failover
            // still fires within 30s.
            setOption(mpv, "network-timeout", "30")

            // `demuxer-termination-timeout=2`: bound how long mpv
            // waits for the demuxer thread to terminate when we quit /
            // destroy the player. mpv's default is 0.1s, but a
            // lavf/HLS demuxer parked on a network read of a
            // not-yet-published live segment (an IN-PROGRESS DVR HLS
            // recording) can ignore the abort until its own read
            // returns, which is governed by network-timeout (30s). We
            // keep network-timeout at 30s so a cold WAN/TLS connect
            // still has headroom (see above), but cap the TEARDOWN
            // wait separately at 2s so leaving such a stream can never
            // pin mpv's destroy path for the full network-timeout. The
            // main thread is already protected by tearing the render
            // context down off-main + sending `quit` before the free
            // (see stop()); this is belt-and-suspenders so the
            // background mpv_terminate_destroy also returns promptly.
            // Routed through setOption so a build that rejects it is
            // logged rather than silently ignored.
            setOption(mpv, "demuxer-termination-timeout", "2")

            // ────────────────────────────────────────────────────────
            // Live low-latency tuning. Layered on top of `profile=fast`
            // (which disables mobile-inappropriate post-processing) —
            // we deliberately do NOT use `profile=low-latency` wholesale
            // because its `audio-buffer=0` + `stream-buffer-size=4k`
            // settings are too aggressive for IPTV over cellular /
            // flaky Wi-Fi and cause underruns. The curated subset below
            // targets the demux / probe stage, which is where the
            // majority of mpv's "tap → first frame" latency lives per
            // upstream profiling (see issue #4213). Live-only — VOD
            // benefits from more thorough probing for reliable seek.
            //
            // `demuxer-lavf-analyzeduration=1.5`: cap libavformat's
            // stream-analysis stage at 1.5 seconds. Default is 5s.
            // Originally tuned to 0.1s for tap-to-first-frame latency,
            // but field testing 2026-05-08 (Step 7-8 instrumentation
            // on Sky Sports Main Event UHD HEVC HDR) showed `fps_detected
            // =0.0/container=0.0/display=0.0` for the entire 2-minute
            // playback session — mpv literally never characterized the
            // stream's frame rate because 100ms wasn't enough samples
            // for a 30fps source (would need ~3-4 frames minimum =
            // 100-130ms minimum, with no GOP-boundary tolerance).
            // Without a cadence reference, mpv's `framedrop=vo` policy
            // can't classify late frames, so it never engaged during
            // the periodic 200ms callback gaps that produced visible
            // held-frame stutter. 1.5s gives mpv ~45 source frames
            // worth of analysis runway, which is plenty to lock fps,
            // pixel format, color matrix, and audio params cleanly.
            // Codex's CODEX_POST_FLASH_STUTTER_NEXT_STEPS Fix 1
            // recommends this exact direction.
            //
            // `demuxer-lavf-probesize=1048576`: 1 MB probe (default
            // 5MB). Originally tuned to 32 KB for the same first-frame
            // latency goal. UHD HEVC Main10 BT.2020 streams need more
            // bytes to expose SPS/PPS/VPS NALs cleanly; the 32 KB cap
            // forced libavformat to emit `Skipping invalid undecodable
            // NALU: 39` warnings and triggered the playback-restart
            // reconfig pattern visible in every field-test log. 1 MB
            // is enough headroom for HEVC parameter sets plus a few
            // initial frames without falling all the way back to
            // libavformat's 5MB default.
            //
            // (Note: `demuxer-lavf-o-add=fflags=+nobuffer` would also
            // be a free win here, but MPVKit's bundled libmpv build
            // rejects the option — logged as `option not found`.
            // Left out entirely rather than silently fail. The cache
            // layer above handles the "don't buffer before playing"
            // intent on its own.)
            //
            // `cache-pause-initial=no`: do NOT wait to fully prefill
            // the cache before playback starts. Default behaviour
            // prefills to `cache-secs` (5s) before the first frame —
            // that's a guaranteed 5s floor. `no` starts playing at
            // the first decodable keyframe and lets the cache fill
            // behind the playhead.
            //
            // `hls-bitrate=max`: for HLS variants, pick the highest
            // bitrate immediately instead of measuring bandwidth
            // first. IPTV users are on a known-good home network;
            // the default ABR handshake adds 500-1500ms before the
            // first segment downloads.
            //
            // `video-latency-hacks=yes`: use demuxer-reported FPS to
            // drive the frame queue instead of decoding an extra
            // frame or two to measure it. Saves 1-2 frames of queue
            // depth at the cost of a slight display-sync jitter on
            // streams with incorrect FPS metadata (rare on broadcast
            // MPEG-TS).
            if isLive {
                setOption(mpv, "demuxer-lavf-analyzeduration", "1.5")
                setOption(mpv, "demuxer-lavf-probesize", "1048576")
                // Stream buffer cushion: when set, wait to fill the cushion at
                // open ("yes") rather than starting immediately ("no").
                setOption(mpv, "cache-pause-initial", streamBufMs > 0 ? "yes" : "no")
                setOption(mpv, "hls-bitrate", "max")
                setOption(mpv, "video-latency-hacks", "yes")
            }

            // v1.7.x Issue A round 4 — render-stall mitigations.
            // Each option is independently revertable; remove the
            // corresponding setOption line to restore prior
            // behaviour.
            //
            // framedrop=vo — drop late frames at the VO layer so
            //   the render call doesn't back up. Without this, when
            //   a frame is delivered late to the renderer it stays
            //   queued and forces subsequent frames into the same
            //   slow path. Reference: mpv issue #13946 ("4K HDR
            //   HEVC stuttering, fixed by --profile=fast", which
            //   includes framedrop tuning).
            //
            // video-sync=audio — explicit, even though it matches
            //   mpv's default. We set it explicitly because some
            //   profiles can override it. We must NOT use display-
            //   resample on iOS with vo=libmpv: display-resample
            //   needs accurate VSync feedback from the host, and
            //   our embedded render-context API doesn't feed that
            //   back to libmpv. Multiple GH issues confirm display-
            //   resample causing extra mistimed frames in this
            //   exact configuration.
            //
            // video-timing-offset=0 — pairs with our existing
            //   BLOCK_FOR_TARGET_TIME=0 in the render-param array.
            //   When BLOCK_FOR_TARGET_TIME=0 is set without
            //   video-timing-offset=0, mpv stages frames slightly
            //   ahead of their intended display time, which on
            //   iOS produces a frame's worth of drift per render
            //   call (libmpv render.h docs).
            //
            // 2026-05-08 reverted: vd-queue-enable=yes +
            // vd-queue-max-samples=8 were added in this same round
            // on a research recommendation to smooth render
            // variance via a decoder-ahead queue. Subsequent
            // research (mpv DOCS/man/options.rst master,
            // line ~5600) explicitly states the queue
            // "should not be used with hardware decoding." Removed
            // to align with documented guidance.
            setOption(mpv, "framedrop", "vo")
            setOption(mpv, "video-sync", "audio")
            setOption(mpv, "video-timing-offset", "0")

            // v1.7.3 introduced unconditional target-prim / target-trc /
            // tone-mapping options here to fix green/washed colors on
            // HDR (BT.2020/PQ or HLG) channels. The fix worked for HDR,
            // but the "no-op for SDR" claim turned out to be wrong on
            // Apple TV - Archie's 2026-06-06 field test on ESPN HD (SDR
            // 1080i) showed steady-state micro-stutter that did not
            // exist in v1.7.2. Pinning the target transfer function
            // forces mpv's render path through extra colorspace work
            // on every frame even when source and target both reduce
            // to BT.709 SDR, and on a thermally-stressed Apple TV that
            // extra cost was visible.
            //
            // Moved to applyHDRToneMappingIfNeeded() (called from
            // MPV_EVENT_PLAYBACK_RESTART) so we only set the three
            // options when mpv reports the source is actually HDR
            // (primaries=bt.2020 OR gamma=pq/hlg/smpte2084). SDR
            // channels stay at mpv defaults and recover the v1.7.2
            // cadence; HDR channels still get the correct colors.

            // v1.7.x Issue A round 5 — anti-flash mitigations
            // targeting the FFmpeg-VideoToolbox bridge's silent-
            // failure path. Per the 2026-05-08 research pass
            // (Agent B), the FFmpeg VT bridge does not propagate
            // VT decode-error callbacks back as hard libav errors
            // when reference frames go missing on a live MPEG-TS
            // mid-GOP join — it returns the buffer as-is, which
            // on a reference miss is a zero/black IOSurface.
            // mpv's libav layer reports the frame as successfully
            // decoded; our render pipeline faithfully presents the
            // black IOSurface; user sees one VSync of solid black.
            // Symptom is reproducible on UHD HEVC main10 BT.2020
            // streams (Sky Sports Main Event UHD class) at ~3
            // events per 16s of steady-state playback, with no
            // pipeline-side metric flagging anything wrong.
            //
            // demuxer-lavf-o=fflags=+discardcorrupt —
            //   tells libavformat to drop corrupt MPEG-TS packets
            //   at the demuxer level, before they reach the parser
            //   that hands slices to VT. Targets the root cause
            //   directly: corrupt-ref slices that VT silently
            //   zeroes never reach VT in the first place. Live
            //   MPEG-TS over HTTP frequently has CC errors on
            //   discontinuities; `discardcorrupt` is the standard
            //   FFmpeg-side hardening for this.
            //
            //   Tried `demuxer-lavf-o-append` first (idiomatic for
            //   newer mpv builds, doesn't clobber peer entries),
            //   but MPVKit's libmpv rejected it with "option not
            //   found." Falling back to the plain `-o` form, which
            //   has existed since pre-0.30 mpv. Safe in our config
            //   because we don't set demuxer-lavf-o anywhere else.
            //
            // vd-lavc-threads=1 — single-threaded libavcodec
            //   parsing for the HW decode path. Removes a race
            //   where the FFmpeg parser hands VT a slice whose
            //   reference frames are still being assembled by a
            //   parallel parse thread. HW decode (videotoolbox-
            //   copy) does the actual decode work inside Apple's
            //   VT process anyway — the lavc thread just shepherds
            //   NALU to VT — so single-threaded parsing has no
            //   meaningful throughput cost on Apple silicon.
            //
            // Each option is independently revertable. Pair stays
            // on test/v1.7.x-flash-fix until field-verified.
            setOption(mpv, "demuxer-lavf-o", "fflags=+discardcorrupt")
            setOption(mpv, "vd-lavc-threads", "1")

            // Multiview tiles: set initial `mute` / `pause` as mpv
            // options (not runtime properties) so the first decoded
            // frame already has the right audio-focus + pause state.
            // Without this, a brand-new non-audio tile briefly
            // plays sound between mpv_initialize() and the first
            // SwiftUI updateUIViewController → applyAudioFocusIfChanged
            // cycle — audible as a bleep of overlapping audio every
            // time the user adds a tile.
            //
            // For single-mode (tileID == nil) these options are
            // tile defaults (initialIsAudioActive=true, initialShouldPause=false)
            // which happen to match mpv's own defaults — safe no-ops.
            //
            // Non-audio tiles. Pre-init audio strategy MUST match
            // what `applyAudioFocusIfChanged` does at runtime. The
            // runtime path picks between two strategies based on
            // tile count:
            //   - tiles.count <= 6: mute-only (aid=auto on every
            //     tile so the audio decoder stays alive everywhere;
            //     mute toggles handle silencing). Field-tested as
            //     safe on Apple TV 4K A15 hardware up to N=6.
            //   - tiles.count >= 7: decoder-off (aid=no on non-audio
            //     tiles so mpv never even opens an AudioUnit). v1.6.12
            //     fix for "Audio device underrun" storms with 9
            //     concurrent tiles all fighting the shared
            //     AVAudioSession.
            //
            // Pre-init was previously hardcoded to the decoder-off
            // strategy (`aid=no`) regardless of tile count. That
            // produced Bug 2 from Freyguy1975's Discord report
            // 2026-05-08: switching audio to a newly-added 2nd tile
            // produced silence. Mechanism: tile created with `aid=no`
            // → mpv never opens audio decoder → user switches focus
            // → applyAudioFocusIfChanged writes `aid=auto` LATE →
            // mpv has to start the audio decoder from scratch on a
            // running stream, which fails or is silent because the
            // demuxer has been told to skip audio packets the whole
            // time. Switching back to tile 1 worked because tile 1's
            // audio decoder had been alive from the start.
            //
            // Fix: at pre-init, query the same `tiles.count >= 7`
            // boundary and pick the matching strategy. Mute-only
            // mode keeps `aid` at mpv's default (`auto`) and just
            // sets `mute=yes`, so the audio decoder runs on every
            // tile from the first frame, just silenced. When the
            // user later switches audio focus, applyAudioFocusIfChanged
            // writes `mute=no` and audio resumes instantly — no
            // late audio-decoder cold-start, no AudioUnit reopen
            // race.
            //
            // `mute=yes` belt-and-suspenders against any audio packet
            // that slips through between mpv_create and mpv_initialize
            // applies in both branches.
            if !initialIsAudioActive {
                // `initialTileCount` is snapshot at Representable
                // construction time on the main actor, so it's safe
                // to read here on the renderQueue without an actor
                // hop. Boundary matches the runtime strategy in
                // applyAudioFocusIfChanged: 7+ tiles → decoder-off,
                // otherwise mute-only.
                let useDecoderOffStrategy = initialTileCount >= 7
                if useDecoderOffStrategy {
                    setOption(mpv, "aid", "no")
                    checkError(mpv_set_option_string(mpv, "mute", "yes"))
                } else {
                    // mute-only: leave `aid` at default (auto) so the
                    // audio decoder stays alive. Just mute the
                    // output. Matches applyAudioFocusIfChanged's
                    // runtime strategy at this tile count.
                    checkError(mpv_set_option_string(mpv, "mute", "yes"))
                }
            }
            if initialShouldPause {
                checkError(mpv_set_option_string(mpv, "pause", "yes"))
            }

            // HTTP headers for the stream — set as PRE-INIT options
            // so they're baked into mpv's config before any
            // `loadfile` can run. These are also re-asserted
            // post-init below (~line 1183) as properties; mpv
            // accepts them at both stages. Belt-and-braces.
            //
            // Why both? For multiview, the 2nd+ tile spins up while
            // the 1st tile's mpv is already running on a different
            // queue. We observed `MPV_ERROR_LOADING_FAILED` on
            // added tiles that disappeared once headers were
            // committed pre-init — the load pipeline is async and
            // appears to race with post-init property writes if
            // the first loadfile enqueue beats them to mpvQueue.
            // Pre-init is guaranteed to be in-config before
            // mpv_initialize returns.
            // Issue #29: "Watch from Beginning" for an in-progress recording
            // is signaled via a sentinel header (it rides the existing headers
            // channel instead of threading a new param through five view
            // layers). When present, start the HLS at the first segment
            // instead of ffmpeg's default live edge, and never send the
            // sentinel to the server.
            let startFromBeginningHeader = "X-Aerio-Start-From-Beginning"
            if headers[startFromBeginningHeader] == "1" {
                // demuxer-lavf-o is a single-value REPLACE, not additive, so
                // include fflags=+discardcorrupt (set above for all streams)
                // here too; otherwise the watch-from-beginning path silently
                // drops corrupt-packet discarding.
                checkError(mpv_set_option_string(mpv, "demuxer-lavf-o", "fflags=+discardcorrupt,live_start_index=0"))
                #if DEBUG
                debugLog("[MPV-DIAG] setupMPV: live_start_index=0 (watch recording from beginning)")
                #endif
            }
            if let ua = headers["User-Agent"], !ua.isEmpty {
                checkError(mpv_set_option_string(mpv, "user-agent", ua))
            }
            let preInitCustomHeaders = headers.filter {
                $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame &&
                $0.key.caseInsensitiveCompare(startFromBeginningHeader) != .orderedSame
            }
            if !preInitCustomHeaders.isEmpty {
                let headerList = preInitCustomHeaders
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\r\n")
                checkError(mpv_set_option_string(mpv, "http-header-fields", headerList))
            }

            #if DEBUG
            markPhase("pre_init_options")
            debugLog("[MPV-DIAG] setupMPV: options set, calling mpv_initialize...")
            // Header forensics — log each key + value length so we can
            // confirm what mpv actually sees per tile (and catch the
            // case where a 2nd tile's headers get mangled / cleared).
            // Values are NEVER logged — API keys live in there.
            let uaLen = headers["User-Agent"]?.count ?? 0
            let uaPreview = headers["User-Agent"]?.prefix(40) ?? "none"
            debugLog("[MPV-DIAG]   hdr UA=\(uaPreview) (\(uaLen)b)")
            for (k, v) in preInitCustomHeaders.sorted(by: { $0.key < $1.key }) {
                let lenBytes = v.utf8.count
                debugLog("[MPV-DIAG]   hdr \(k)=<redacted> (\(lenBytes)b)")
            }
            debugLog("[MPV-DIAG]   tile=\(tileID ?? "single") urls=\(urls.count) first_url_len=\(urls.first?.absoluteString.count ?? 0)")
            debugLog("[MPV-DIAG]   \(ProcessMetrics.summaryLine())")
            #endif

            // ── Initialize ──
            // vo=libmpv: no MoltenVK shader compilation, instant initialization.
            #if DEBUG
            let initStart = Date()
            #endif
            let initResult = mpv_initialize(mpv)

            if initResult < 0 {
                let errStr = String(cString: mpv_error_string(initResult))
                logStore.append("✗ MPV: initialization failed — \(errStr)")
                #if DEBUG
                debugLog("[MPV-ERR] mpv_initialize failed: \(errStr)")
                #endif
                mpv_terminate_destroy(mpv)
                self.mpv = nil
                let callback = onFatalError
                Task { await callback("MPV init failed: \(errStr)") }
                return
            }

            // Live Rewind: register the aeriots:// protocol so mpv can
            // read the local timeshift buffer. "aeriots://live" tails
            // the write head a few seconds behind; "aeriots://at/<ms>"
            // starts at a wall-clock offset (re-tune seek model). No
            // seek/size callbacks: the stream is deliberately
            // unseekable and unsized, which also sidesteps ffmpeg's
            // open-time end probe entirely.
            //
            // MUST stay OUTSIDE any #if DEBUG: this registration
            // originally landed inside the DEBUG-only diagnostics block
            // below, which would have shipped Release builds where every
            // relay tune failed with "protocol not found" (caught in the
            // 2026-07-10 pre-release review; all device testing had been
            // Debug builds).
            mpv_stream_cb_add_ro(mpv, "aeriots", nil) { _, uriC, info in
                guard let uriC, let info else { return Int32(MPV_ERROR_LOADING_FAILED.rawValue) }
                let uri = String(cString: uriC)
                let fromWall: Int64? = uri.hasPrefix("aeriots://at/")
                    ? Int64(uri.dropFirst("aeriots://at/".count))
                    : nil
                // A channel flip mid-open closes the session this file
                // was routed for and starts the next channel's within
                // milliseconds; adopt the replacement instead of failing
                // (a stale open failure surfaced as an end-file ERROR
                // that could latch the NEW tune off the relay). Genuine
                // teardown never produces a fresh session, so this
                // drains to the failure path in ~3s during shutdown.
                var candidate = LiveRewindEngine.shared.bufferForReader
                var waited = 0
                while (candidate == nil || candidate!.closed), waited < 30 {
                    // GH #60: mpv's C thread has no draining autorelease pool;
                    // keep Foundation temporaries from pinning (see the reader).
                    autoreleasepool {
                        Thread.sleep(forTimeInterval: 0.1)
                        waited += 1
                        candidate = LiveRewindEngine.shared.bufferForReader
                    }
                }
                guard let buffer = candidate, !buffer.closed,
                      let reader = LiveRewindReader(buffer: buffer, fromWallMs: fromWall) else {
                    debugLog("[REWIND] aeriots open failed (no live session) uri=\(uri)")
                    return Int32(MPV_ERROR_LOADING_FAILED.rawValue)
                }
                LiveRewindEngine.shared.noteReaderStart(reader.startWallMs)
                info.pointee.cookie = Unmanaged.passRetained(reader).toOpaque()
                info.pointee.read_fn = { cookie, buf, nbytes in
                    guard let cookie, let buf else { return -1 }
                    let r = Unmanaged<LiveRewindReader>.fromOpaque(cookie).takeUnretainedValue()
                    return Int64(r.read(into: UnsafeMutableRawPointer(buf), max: Int(nbytes)))
                }
                info.pointee.close_fn = { cookie in
                    guard let cookie else { return }
                    let unmanaged = Unmanaged<LiveRewindReader>.fromOpaque(cookie)
                    unmanaged.takeUnretainedValue().close()
                    unmanaged.release()
                }
                return 0
            }

            // Catch-up relay: aeriocu://<base64 http url>. One streaming
            // connection with no seek/size callbacks, so ffmpeg's
            // open-time end-of-duration probe (which spent Dispatcharr's
            // single timeshift session and killed playback on device;
            // seekable=0 provably did not suppress it) cannot happen.
            mpv_stream_cb_add_ro(mpv, "aeriocu", nil) { _, uriC, info in
                guard let uriC, let info else { return Int32(MPV_ERROR_LOADING_FAILED.rawValue) }
                let uri = String(cString: uriC)
                guard let target = CatchupRelay.unwrap(uri) else {
                    debugLog("[CATCHUP-RELAY] bad uri")
                    return Int32(MPV_ERROR_LOADING_FAILED.rawValue)
                }
                let reader = CatchupHTTPReader(url: target, headers: CatchupRelay.currentHeaders)
                info.pointee.cookie = Unmanaged.passRetained(reader).toOpaque()
                info.pointee.read_fn = { cookie, buf, nbytes in
                    guard let cookie, let buf else { return -1 }
                    let r = Unmanaged<CatchupHTTPReader>.fromOpaque(cookie).takeUnretainedValue()
                    return Int64(r.read(into: UnsafeMutableRawPointer(buf), max: Int(nbytes)))
                }
                info.pointee.close_fn = { cookie in
                    guard let cookie else { return }
                    let unmanaged = Unmanaged<CatchupHTTPReader>.fromOpaque(cookie)
                    unmanaged.takeUnretainedValue().close()
                    unmanaged.release()
                }
                return 0
            }

            #if DEBUG
            let initMs = Date().timeIntervalSince(initStart) * 1000
            debugLog("[MPV-DIAG] setupMPV: mpv_initialize succeeded ✓ (\(String(format: "%.0f", initMs))ms)")
            markPhase("mpv_initialize")
            #endif

            // ── Post-init: create OpenGL ES render context ──

            // EAGLContext for GPU-accelerated mpv rendering
            eaglContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)
            #if DEBUG
            markPhase("EAGLContext_create")
            #endif
            guard let glCtx = eaglContext else {
                logStore.append("✗ MPV: failed to create EAGLContext")
                let callback = onFatalError
                Task { await callback("MPV: OpenGL ES context creation failed") }
                return
            }
            EAGLContext.setCurrent(glCtx)
            #if DEBUG
            markPhase("EAGLContext_setCurrent")
            #endif

            // Texture cache for zero-copy CVPixelBuffer ↔ GL texture sharing
            var cache: CVOpenGLESTextureCache?
            CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, glCtx, nil, &cache)
            textureCache = cache
            #if DEBUG
            markPhase("CVOpenGLESTextureCacheCreate")
            #endif

            // OpenGL render API — GPU handles color conversion, scaling, OSD.
            // get_proc_address resolves GL function pointers from the loaded OpenGLES.framework.
            let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
            var glInitParams = mpv_opengl_init_params(
                get_proc_address: { (ctx, name) -> UnsafeMutableRawPointer? in
                    guard let name else { return nil }
                    return dlsym(dlopen(nil, RTLD_LAZY), name)
                },
                get_proc_address_ctx: nil
            )
            // withUnsafeMutablePointer ensures glInitParams outlives the create call.
            let renderCreateResult: CInt = withUnsafeMutablePointer(to: &glInitParams) { glPtr in
                var renderParams = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glPtr),
                    mpv_render_param()
                ]
                return mpv_render_context_create(&mpvGL, mpv, &renderParams)
            }
            #if DEBUG
            markPhase("mpv_render_context_create")
            #endif

            if renderCreateResult < 0 {
                let errStr = String(cString: mpv_error_string(renderCreateResult))
                logStore.append("✗ MPV: render context creation failed — \(errStr)")
                #if DEBUG
                debugLog("[MPV-ERR] mpv_render_context_create failed: \(errStr)")
                #endif
                mpv_terminate_destroy(mpv)
                self.mpv = nil
                let callback = onFatalError
                Task { await callback("MPV render context failed: \(errStr)") }
                return
            }

            #if DEBUG
            debugLog("[MPV-DIAG] setupMPV: OpenGL ES render context created ✓")
            #endif

            // When mpv has a new frame, schedule render on background thread.
            // GPU renders to CVPixelBuffer via IOSurface FBO; displayed via AVSampleBufferDisplayLayer.
            mpv_render_context_set_update_callback(mpvGL, { ctx in
                guard let ctx else { return }
                let coord = Unmanaged<MPVPlayerViewRepresentable.Coordinator>.fromOpaque(ctx).takeUnretainedValue()
                coord.scheduleRender()
            }, Unmanaged.passUnretained(self).toOpaque())
            #if DEBUG
            markPhase("render_update_callback")
            #endif

            // ── Post-init: property observers + wakeup callback ──

            mpv_observe_property(mpv, 1, "pause", MPV_FORMAT_FLAG)
            mpv_observe_property(mpv, 2, "duration", MPV_FORMAT_DOUBLE)
            mpv_observe_property(mpv, 3, "time-pos", MPV_FORMAT_DOUBLE)
            mpv_observe_property(mpv, 4, "eof-reached", MPV_FORMAT_FLAG)
            mpv_observe_property(mpv, 5, "paused-for-cache", MPV_FORMAT_FLAG)
            mpv_observe_property(mpv, 6, "core-idle", MPV_FORMAT_FLAG)
            // v1.7.x Issue A: observe hwdec-current so we see the
            // exact moment mpv flips from `videotoolbox` to
            // `videotoolbox-copy` after the GL-interop failure
            // (10-bit HEVC). Querying-on-demand only catches it
            // after the fact; observing catches the transition.
            mpv_observe_property(mpv, 7, "hwdec-current", MPV_FORMAT_STRING)

            let retained = Unmanaged.passRetained(self)
            self.wakeupRetain = retained
            let coordPointer = retained.toOpaque()
            mpv_set_wakeup_callback(mpv, { ctx in
                guard let ctx else { return }
                let coordinator = Unmanaged<Coordinator>.fromOpaque(ctx).takeUnretainedValue()
                coordinator.readEvents()
            }, coordPointer)
            #if DEBUG
            markPhase("observe_properties+wakeup")
            #endif

            // ── Post-init: runtime options ──

            let cachingSecs: Double = {
                let userPrefMs: Int = {
                    switch UserDefaults.standard.string(forKey: "streamBufferSize") ?? "default" {
                    case "small":  return 300
                    case "large":  return 3_000
                    case "xlarge": return 8_000
                    default:       return 1_500
                    }
                }()
                // tvOS tends to report `.serious` thermal state more
                // often than iPad (Apple TV 4K's passive cooling
                // doesn't recover as fast), and thermally-throttled
                // CPU/GPU means the audio output ringbuffer is more
                // likely to drain before mpv's decoder catches up.
                // Raise the live-stream minimum from 5s → 10s on
                // tvOS to absorb those hitches — each audio-device
                // underrun that DOES occur freezes video for 1-4s,
                // so the extra 5s of buffer is worth the slightly
                // longer initial startup.
                #if os(tvOS)
                let liveMinMs = 10_000
                // v1.7.4.x: VOD/DVR were using userPrefMs (default 1500ms)
                // unconditionally, which was tuned for single-stream
                // playback. Multiview-VOD field reports (Archie, 2026-06-03)
                // had the 12 Citizens tile freezing 73 seconds because
                // the 1.5s demuxer cache underran when sharing network
                // with concurrent live tiles - libmpv's update callback
                // went quiet until the next tile-add cycle nudged it back.
                // Single-stream VOD stutter (Apple TV VOD community poll
                // 33%) likely has the same root: thin cache + sporadic
                // proxy reads. Raise the non-live floor to 5s on tvOS
                // to give the demuxer enough headroom that a brief
                // network hiccup or co-tile bandwidth contention does
                // not stall video. Memory cost is bounded (~5s of
                // typical 8 Mbps stream is ~5 MB).
                let vodMinMs = 5_000
                #else
                let liveMinMs = 5_000
                let vodMinMs = 3_000
                #endif
                var ms = isLive
                    ? max(userPrefMs, liveMinMs)
                    : max(userPrefMs, vodMinMs)
                // Stream buffer cushion (live only): fold the user's chosen
                // cushion into the floor so cache-secs / demuxer-readahead-
                // secs cover it. streamBufMs is already in milliseconds, the
                // same unit as `ms`. 0 leaves the floor untouched.
                if isLive, streamBufMs > 0 {
                    ms = max(ms, streamBufMs)
                }
                return Double(ms) / 1000.0
            }()

            mpv_set_property_string(mpv, "cache", "yes")
            mpv_set_property_string(mpv, "demuxer-readahead-secs", String(format: "%.1f", cachingSecs))

            if isLive {
                // Live: small demuxer buffer prevents A-V desync from runaway video queues.
                // 50MiB was far too large — video piled up 4000+ packets while audio starved.
                mpv_set_property_string(mpv, "demuxer-max-bytes", "8MiB")
                // Dead-server detection (ATV field test 2026-07-12): with the
                // default network timeout (~60s) a killed Dispatcharr left the
                // picture FROZEN 30-60s before the error card appeared. 10s
                // without a single byte on a LIVE feed is already terminal
                // (Android surfaces at ~6s of stale position), so fail the read
                // fast and let the reload ladder -> error card -> auto-retry
                // take over. Live-only: VOD/recordings keep the tolerant default.
                mpv_set_property_string(mpv, "network-timeout", "8")
                // cache-pause stays "yes" initially — switched to "no" after playback-restart
                // so mpv builds an initial 2s buffer before starting playback.
                mpv_set_property_string(mpv, "cache-secs", String(format: "%.1f", cachingSecs))
                mpv_set_property_string(mpv, "demuxer-max-back-bytes", "0")
                mpv_set_property_string(mpv, "demuxer-donate-buffer", "no")
                // v1.7.x Step 9 — soften the runtime startup overrides.
                // These post-init `mpv_set_property_string` calls
                // were setting the demuxer-analysis options to MORE
                // aggressive values than the pre-init options at
                // line ~3292, which is what mpv actually consulted
                // when calling avformat_find_stream_info. Field test
                // 2026-05-08 (Step 8 instrumentation on Sky Sports
                // Main Event UHD HEVC HDR) showed the consequence:
                // `fps_detected=0.0/container=0.0/display=0.0` for
                // the entire 2-minute playback session. mpv literally
                // never characterized the stream's frame rate.
                //
                // - `probe-info=nostreams` skipped
                //   avformat_find_stream_info() entirely once any
                //   stream had been identified, which on
                //   broadcast-grade MPEG-TS means after the first
                //   PAT/PMT pair. fps detection happens INSIDE
                //   find_stream_info, so skipping it = no fps.
                //   Now `auto` — let mpv complete the analysis.
                //
                // - `analyzeduration=0` would have been "use
                //   libavformat default = 5s" but combined with
                //   probe-info=nostreams it didn't matter. Now 1.5s
                //   to give mpv ~45 frames of analysis runway at
                //   30fps source.
                //
                // - `probesize=32768` (32KB) was too small for UHD
                //   HEVC Main10 BT.2020 streams with their full SPS/
                //   PPS/VPS NAL payloads. Field test logged
                //   "Skipping invalid undecodable NALU: 39" at
                //   startup, which is libavformat tripping on
                //   incomplete HEVC parameter sets. 1MB is enough
                //   headroom for HEVC parameter sets plus several
                //   initial frames without falling all the way back
                //   to libavformat's 5MB default.
                //
                // Trade-off: tap-to-first-frame latency goes from
                // ~1.3s (current) to probably ~2.5–3s. UX cost is
                // small for live broadcast; users tap a channel and
                // wait briefly anyway. Codex's
                // CODEX_POST_FLASH_STUTTER_NEXT_STEPS recommends
                // exactly this direction (Fix 1).
                mpv_set_property_string(mpv, "demuxer-lavf-probe-info", "auto")
                mpv_set_property_string(mpv, "demuxer-lavf-analyzeduration", "1.5")
                mpv_set_property_string(mpv, "demuxer-lavf-probesize", "1048576")
                mpv_set_property_string(mpv, "probesize", "1048576")
            } else {
                // VOD: larger buffer for seek-back
                mpv_set_property_string(mpv, "demuxer-max-bytes", "50MiB")
                mpv_set_property_string(mpv, "demuxer-max-back-bytes", "10MiB")
                // Keyframe (non-exact) seeks for VOD + DVR scrubbing. The
                // default seeks exactly to the requested timestamp, which
                // means decoding from the prior keyframe forward to that
                // frame before anything shows (the slow part of a scrub).
                // hr-seek=no snaps to the nearest keyframe instead, so the
                // picture comes back almost immediately; the landing is a
                // GOP off the exact target, which is the right trade for a
                // scrub (the scrub UI settles the playhead onto the real
                // landing position). Live keeps the default (it never seeks).
                mpv_set_property_string(mpv, "hr-seek", "no")
            }

            mpv_set_property_string(mpv, "framedrop", "decoder+vo")
            mpv_set_property_string(mpv, "video-sync", "audio")
            // Audio output ringbuffer. Larger = more slack between
            // "decoder hiccup" and "audio device underrun → mpv
            // pauses everything for 1-4s". tvOS defaults to 2.5s
            // because Apple TV 4K ships in passive-cooled enclosures
            // that stay in `.serious` thermal state for minutes
            // after any load, and the throttled CPU starves the
            // audio pipeline at the existing 1.5s buffer. iPad
            // keeps 1.5s — it hasn't shown the same underrun
            // cadence and a larger audio buffer trades A-V sync
            // latency for resilience (don't pay it if we don't
            // need to).
            #if os(tvOS)
            mpv_set_property_string(mpv, "audio-buffer", "2.5")
            #else
            mpv_set_property_string(mpv, "audio-buffer", "1.5")
            #endif
            // Correct A-V sync for live TS streams — drop late video frames
            // rather than letting the video queue grow unbounded.
            mpv_set_property_string(mpv, "hr-seek-framedrop", "yes")

            if let ua = headers["User-Agent"], !ua.isEmpty {
                mpv_set_property_string(mpv, "user-agent", ua)
            }
            let customHeaders = headers.filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
            if !customHeaders.isEmpty {
                let headerList = customHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
                mpv_set_property_string(mpv, "http-header-fields", headerList)
            }
            #if DEBUG
            markPhase("post_init_properties")
            #endif

            // `totalSetupMs` is needed by BOTH the DEBUG-only diag
            // prints AND the always-on `[MV-TIMING]` DebugLogger
            // line below, so it has to live outside the `#if DEBUG`
            // block — otherwise release builds fail to compile with
            // "Cannot find 'totalSetupMs' in scope" at the
            // `[MV-TIMING]` usage site. `setupStartTime` itself is
            // unconditional (declared at line ~616, assigned
            // ~1225), so this read is safe in all configurations.
            let totalSetupMs = setupStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? -1
            #if DEBUG
            let cacheStr = String(format: "%.1f", cachingSecs)
            debugLog("[MPV-DIAG] ✓ mpv fully initialized: vo=libmpv (OpenGL ES render), hwdec=videotoolbox-copy (requested)")
            debugLog("[MPV-DIAG]   cache=\(cacheStr)s, readahead=\(cacheStr)s, isLive=\(isLive), setup_time=\(String(format: "%.0f", totalSetupMs))ms")
            #endif

            // ── Per-tile timeline summary ──
            // One dense line per tile setup, surfaced in both DEBUG
            // print *and* DebugLogger so it survives in release
            // crash/feedback reports. Collected fields:
            //   tile         — which tile (or "single")
            //   setup_ms     — mpv_create → here
            //   headers      — count of HTTP headers committed (UA +
            //                  Authorization/X-API-Key/Accept for
            //                  Dispatcharr; UA-only for XC/M3U)
            //   cache_s      — demuxer-readahead-secs
            //   rss_mb/fd/thermal — process-wide resource snapshot
            //                       AT tile-setup-complete. The
            //                       delta across N tile adds is
            //                       the real signal for whether
            //                       the 2nd-tile open failure is a
            //                       FD starvation, memory
            //                       pressure, or thermal trip.
            let totalSetupMsInt = Int(totalSetupMs)
            let headerCount = headers.count
            let cacheSecs = String(format: "%.1f", cachingSecs)
            let timelineLine =
                "[MV-TIMING] tile=\(tileID ?? "single") " +
                "setup_ms=\(totalSetupMsInt) " +
                "headers=\(headerCount) " +
                "cache_s=\(cacheSecs) " +
                "isLive=\(isLive) " +
                ProcessMetrics.summaryLine()
            #if DEBUG
            debugLog(timelineLine)
            #endif
            DebugLogger.shared.log(timelineLine, category: "MPV-STREAM", level: .info)
        }

        // MARK: - Playback

        /// Live Rewind: route an eligible fullscreen-single-live URL
        /// through the app-owned buffer relay, returning the URL mpv
        /// should actually load. Shared by `play(url:)` (fresh tune,
        /// every retry path) and `swapStream` (channel flip), so a flip
        /// re-routes for the NEW channel instead of leaving the old
        /// session buffering the previous one under a live transport.
        /// When the tune is NOT eligible (or the relay is in direct
        /// fallback), any running session is stopped so the transport
        /// chrome and the buffer can never point at a stale channel.
        ///
        /// "Fullscreen single live" includes the unified N=1 path,
        /// where the sole stream is a multiview tile with a non-nil
        /// tileID (PlayerSession routes everything through
        /// MultiviewStore by default). Same solo-tile predicate the
        /// PiP eligibility gate uses.
        private func routeThroughLiveRewind(_ url: URL) -> URL {
            let isSoloLive = tileID == nil ||
                (initialIsAudioActive && initialTileCount <= 1)
            guard isLive, isSoloLive, catchup == nil,
                  url.scheme?.hasPrefix("http") == true,
                  !liveRewindFallbackDirect,
                  LiveRewindEngine.shared.isEnabled else {
                if url.scheme != "aeriots", liveRewindActive {
                    liveRewindActive = false
                    LiveRewindEngine.shared.stopSession()
                }
                return url
            }
            let started = LiveRewindEngine.shared.startSession(
                channelID: url.absoluteString,
                channelName: nowPlayingTitle,
                streamURL: url,
                headers: headers)
            if started {
                liveRewindActive = true
                liveRewindTailRetuneUsed = false
                debugLog("[REWIND] live playback via buffer relay")
                return URL(string: "aeriots://live")!
            }
            return url
        }

        /// Drop the relay for the CURRENT tune and replay the direct
        /// stream. The relay is a best-effort enhancement: it must never
        /// turn a channel that direct playback can play into a red error
        /// card (ATV field report 2026-07-10: "Decoder unavailable /
        /// loading failed" during plain live viewing). The fallback
        /// sticks until the next channel change (`swapStream` resets it)
        /// or a fresh player.
        /// One-shot per tune; reset when a fresh relay route succeeds.
        private var liveRewindTailRetuneUsed = false

        /// Relay error triage, one-shot per tune. Where the re-tune lands
        /// depends on where the VIEWER was (GH #67):
        /// - At the live edge (not timeshifting): resume at the live head.
        ///   The old unconditional tail re-tune yanked live viewers a full
        ///   rewind-depth into the past when the reader faulted at ring
        ///   wrap ("suddenly loops back 30 minutes", KTLA log 2026-07-29).
        ///   Matches the snap-to-live philosophy of the long-pause unpause
        ///   path.
        /// - Timeshifted (scrubbed behind live): re-tune at the buffer
        ///   tail, the closest surviving data when the reader's position
        ///   was evicted (the case the tail re-tune was designed for).
        /// Anything else (or a second failure) is a genuinely sick relay
        /// and drops to the direct stream.
        private func relayErrorRecovery(reason: String) {
            let engine = LiveRewindEngine.shared
            if !liveRewindTailRetuneUsed,
               let buf = engine.bufferForReader, !buf.closed,
               // Only when the buffer actually HAS content: a cold-tune
               // failure (connection still priming, zero segments) has
               // nothing to re-tune into, and the extra attempt just
               // stacked seconds onto the fallback ladder (ATV field
               // observation during the 500-at-prime tune).
               buf.headWallMs - buf.tailWallMs > 5_000 {
                liveRewindTailRetuneUsed = true
                // Racy off-main read of a @Published Bool; a torn read just
                // picks the other (still-reasonable) resume point.
                let wasTimeshifting = engine.timeshifting
                if wasTimeshifting {
                    engine.noteTimeshifting(true)
                    debugLog("[REWIND] relay error (\(reason)); one-shot re-tune at buffer tail")
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else { return }
                        self.mpvCommandAsync(mpv, ["loadfile", "aeriots://at/\(buf.tailWallMs + 2_000)", "replace"])
                    }
                } else {
                    engine.noteTimeshifting(false)
                    debugLog("[REWIND] relay error (\(reason)); one-shot re-tune at live head")
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else { return }
                        self.mpvCommandAsync(mpv, ["loadfile", "aeriots://live", "replace"])
                    }
                }
                return
            }
            fallBackToDirectStream(reason: reason)
        }

        /// A second multiview tile was added while this tile rode the
        /// relay: switch to the direct stream (the fallback latch clears
        /// on the next channel change, and a fresh solo tune re-relays).
        @objc private func dropLiveRewindRelay() {
            guard liveRewindActive else { return }
            fallBackToDirectStream(reason: "multiview tile added")
        }

        /// GH #60 seatbelt: one relay reload when RSS crosses the runaway line
        /// (memory-warning hook). Swapping mpv's stream thread releases
        /// whatever that thread had pinned; belt-and-braces behind the POSIX-
        /// read leak fix. Self-throttled so repeated warnings can't storm.
        private var lastSeatbeltReloadAt: CFAbsoluteTime = 0
        @objc private func memorySeatbeltReload() {
            guard liveRewindActive else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastSeatbeltReloadAt >= 60 else { return }
            lastSeatbeltReloadAt = now
            DebugLogger.shared.log(
                "🟡 [MPV-RELOAD] memory seatbelt relay reload tile=\(tileID ?? "single")",
                category: "MPV-STREAM", level: .warning
            )
            cachedRenderer?.flush(removingDisplayedImage: false)
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.activeMPVHandle() else { return }
                self.mpvCommand(mpv, ["loadfile", "aeriots://live", "replace"])
            }
        }

        private func fallBackToDirectStream(reason: String) {
            liveRewindActive = false
            liveRewindFallbackDirect = true
            LiveRewindEngine.shared.stopSession()
            loadFailureRetryCount = 0
            sameURLRetryCount = 0
            debugLog("[REWIND] relay failed (\(reason)); falling back to direct stream")
            logStore.append("↻ MPV: relay failed — retrying direct stream")
            cachedRenderer?.flush(removingDisplayedImage: false)
            let retryURL = urls[currentIndex]
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.play(url: retryURL)
                }
        }

        private func play(url: URL) {
            guard let mpv = activeMPVHandle() else { return }

            // Live Rewind: route fullscreen single live playback through
            // the app-owned buffer connection. The engine opens the ONE
            // provider stream and mpv consumes the buffer via aeriots://,
            // so pausing never stops the buffer from filling and rewind
            // has runway by construction.
            var url = url
            url = routeThroughLiveRewind(url)
            // Catch-up plays through the aeriocu relay (single-session
            // Dispatcharr timeshift; see the protocol registration).
            if let cu = catchup, url.scheme?.hasPrefix("http") == true {
                // Task #149: remember the live session URL for seek
                // re-mints and the teardown revoke (native path only).
                if cu.nativeChannelUUID != nil { catchupCurrentURL = url }
                CatchupRelay.currentHeaders = headers
                url = CatchupRelay.wrap(url)
                debugLog("[CATCHUP] playing via aeriocu relay")
            }
            // stop() can land between the handle check above and the
            // session start inside the routing; without this re-check the
            // engine keeps a full-bitrate download running with no player
            // attached until the next tune.
            if withPlaybackStateLock({ $0.isShuttingDown }) {
                if liveRewindActive {
                    liveRewindActive = false
                    LiveRewindEngine.shared.stopSession()
                }
                return
            }

            hasStarted = false
            playbackStartTime = nil
            // play() always loads the coordinator's ORIGINAL url (for
            // catch-up: the programme-start window), so the display base
            // must be zero. The load-error retry path funnels through
            // here after a failed re-tune; without this reset it replayed
            // the start window under the old seek target's offset and the
            // whole timeline lied from then on.
            catchupBaseOffsetMs = 0
            catchupEofRetuneUsed = false
            // v1.7.4.x: invalidate the previous stream's container-fps
            // hint so the watchdog reverts to the floor until the perf
            // pump re-measures the new stream. Prevents a 60fps -> 25fps
            // swap from leaving the watchdog tuned to the wrong cadence
            // (it would otherwise stay at the looser 60ms until the next
            // perf cycle).
            Task { @MainActor [weak self] in self?.containerFpsHint = 0 }
            // v1.7.x: reset HDR tone-map gate so the next stream's
            // playback-restart re-evaluates the source colorspace.
            // Without this a channel-flip from HDR to SDR would keep
            // the BT.709 SDR pin alive on the SDR stream (or vice
            // versa would leave HDR without the pin).
            hdrToneMappingApplied = false
            // A fresh file is loading (initial play, retry, or the
            // reload-fallback replay path), so clear any prior VOD EOF
            // state. Multiview's per-tile "Finished" overlay keys on
            // this; live/DVR never set it so this is a harmless no-op
            // for them.
            if progressStore.reachedEOF {
                DispatchQueue.main.async { [weak self] in
                    self?.progressStore.reachedEOF = false
                }
            }
            // `loadfile replace` reuses the same mpv core, so any runtime
            // hwdec downgrade from the previous stream must be cleared before
            // the next file starts. v1.7.x: default is now videotoolbox-copy
            // (see rationale block in setupMPV); the only "downgrade" the
            // safety-net fallback can apply on top of that is the same
            // videotoolbox-copy, so this reset is now mostly defensive.
            resetHwdecFallbackApplied()
            #if !targetEnvironment(simulator)
            mpv_set_property_string(mpv, "hwdec", "videotoolbox-copy")
            #endif
            // v1.7.x Issue A round 6: reset the black-frame detector's
            // luma history to neutral so the surround check doesn't
            // carry the previous stream's last-frame luma into the
            // new stream's startup. Neutral=128 means the surround
            // check (prev>25 AND prev-prev>20) trips immediately on
            // the first real bright frame, which is the right
            // behaviour for tile-rebind / channel-change.
            blackFramePrevAvgLuma = 128
            blackFramePrevPrevAvgLuma = 128
            // v1.7.x: also reset the storm-reload watchdog state. A
            // fresh play(url:) means either an external channel-flip
            // or a user-initiated stream change, neither of which
            // should inherit the prior stream's consecutive black
            // count or sit inside the prior reload's cooldown
            // (the user just asked to start playing something new).
            consecutiveBlackFramesSuppressed = 0
            lastForcedBlackReloadAt = 0
            forcedReloadWindowStart = 0
            forcedReloadWindowCount = 0
            // Disarm the reload watchdogs until this new stream reaches
            // playback-restart, so its startup probe is never treated as
            // a wedge.
            hasReachedPlaybackRestartForStream = false
            // Reset the stall report for the new stream: anchor back to 0 (so the
            // SET guard's `lastEnq > 0` re-protects the pre-first-frame window)
            // and drop any soft card carried over from the outgoing stream. Unlike
            // swapStream, play(url:) can run off a background queue, so the
            // @Published streamStalled write is hopped to the main actor
            // (2026-07-13 review).
            lastEnqueueTime = 0
            streamStalledReported = false
            DispatchQueue.main.async { [weak self] in
                self?.progressStore.streamStalled = false
            }
            // v1.6.23: route URL strings through DebugLogger.sanitize
            // before any console / file output so Xtream credentials
            // (`/live/<u>/<p>/<id>` and `?username=&password=` query
            // forms) don't leak into logs that users may share for
            // support requests.
            let safeURL = DebugLogger.sanitize(url.absoluteString)
            logStore.append("▶️ MPV attempt \(currentIndex + 1)/\(urls.count)")
            logStore.append("  \(safeURL)")
            DebugLogger.shared.logPlayback(event: "Play attempt \(currentIndex + 1)/\(urls.count)",
                                           url: url.absoluteString)

            #if DEBUG
            debugLog("[MPV-DIAG] -- Starting playback --")
            debugLog("[MPV-DIAG] URL: \(safeURL)")
            debugLog("[MPV-DIAG] isLive=\(isLive), attempt=\(currentIndex + 1)/\(urls.count)")
            #endif

            mpvCommand(mpv, ["loadfile", url.absoluteString, "replace"])
        }

        // MARK: - Event Processing

        private func readEvents() {
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.activeMPVHandle() else { return }

                while true {
                    let event = mpv_wait_event(mpv, 0)
                    guard let event, event.pointee.event_id != MPV_EVENT_NONE else { break }

                    switch event.pointee.event_id {
                    case MPV_EVENT_START_FILE:
                        self.handleStartFile()

                    case MPV_EVENT_FILE_LOADED:
                        self.handleFileLoaded()

                    case MPV_EVENT_END_FILE:
                        self.handleEndFile(event)

                    case MPV_EVENT_PROPERTY_CHANGE:
                        self.handlePropertyChange(event)

                    case MPV_EVENT_VIDEO_RECONFIG:
                        // v1.7.x Issue A: dedicated handler logs the
                        // full pipeline snapshot at every reconfig
                        // and resets per-window decoder counters.
                        self.handleVideoReconfig()

                    case MPV_EVENT_AUDIO_RECONFIG:
                        // v1.7.x Step 7: stamp the timestamp so
                        // subsequent MPV-CALLBACK-GAP logs can show
                        // `since_audio_reconfig=Nms`. AC3 audio in
                        // live MPEG-TS reconfigs on
                        // mono/stereo/5.1 transitions; each reconfig
                        // may briefly stall libmpv. Codex flagged
                        // this correlation as a key diagnostic.
                        self.lastAudioReconfigAt = CFAbsoluteTimeGetCurrent()
                        self.audioReconfigCount &+= 1
                        #if DEBUG
                        debugLog("[MPV-DIAG] \(self.streamTag) Event: audio-reconfig #\(self.audioReconfigCount)")
                        #endif

                    case MPV_EVENT_LOG_MESSAGE:
                        if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data)) {
                            let text = msg.pointee.text.map { String(cString: $0) } ?? ""
                            if text.contains("underrun") {
                                self.audioUnderrunCount += 1
                            }
                            // v1.7.x Issue A: tally decoder error
                            // storms BEFORE the noise filter discards
                            // them. These per-window counters reset
                            // on every MPV_EVENT_VIDEO_RECONFIG so we
                            // can see each reconfig window's decoder
                            // error signature in the [MPV-RECONFIG]
                            // log line. UHD 10-bit HEVC streams emit
                            // bursts of these around the videotoolbox
                            // → videotoolbox-copy fallback and around
                            // every mid-stream reconfig — strong
                            // candidates for the user-visible black
                            // flashes Archie reported 2026-05-08.
                            if text.contains("PPS id out of range")
                                || text.contains("non-existing PPS")
                                || text.contains("non-existing SPS") {
                                self.ppsErrorWindow &+= 1
                                self.ppsErrorTotal &+= 1
                            }
                            if text.contains("Skipping invalid undecodable NALU")
                                || text.contains("Skipping NAL unit") {
                                self.naluErrorWindow &+= 1
                                self.naluErrorTotal &+= 1
                            }
                            if text.contains("Error while decoding frame")
                                || text.contains("hardware accelerator failed to decode") {
                                self.hwdecErrorWindow &+= 1
                                self.hwdecErrorTotal &+= 1
                            }
                            if text.contains("vt decoder cb: output image buffer is null") {
                                self.vtNullBufferWindow &+= 1
                                self.vtNullBufferTotal &+= 1
                            }
                            // Defensive fallback: if mpv ever ends up
                            // in plain videotoolbox mode despite our
                            // videotoolbox-copy default (e.g. a future
                            // libmpv build silently re-promotes), the
                            // GL-interop attempt on 10-bit p010 will
                            // still fail with "Initializing texture
                            // for hardware decoding failed". Reapply
                            // copy mode so playback recovers without
                            // a permanent black layer.
                            //
                            // v1.7.x: removed the seek-to-current-time
                            // that used to follow this property write.
                            // It was meant to force pipeline reinit
                            // but on live streams it failed with
                            // "Cannot seek in this stream" and mpv
                            // restarted the pipeline anyway, costing
                            // ~2 seconds of blue-screen time per UHD
                            // stream open. With the videotoolbox-copy
                            // default this branch shouldn't normally
                            // fire at all, and even if it does, the
                            // hwdec property write alone is enough —
                            // mpv will pick up the new mode on the
                            // next decode without our help.
                            if text.contains("Initializing texture for hardware decoding failed") && self.claimHwdecFallbackIfNeeded() {
                                let elapsedMs = self.setupStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? -1
                                debugLog("[MPV-DECODE] \(self.streamTag) defensive fallback fired (mpv re-promoted to videotoolbox?) — reapplying videotoolbox-copy at +\(String(format: "%.0f", elapsedMs))ms from setup")
                                mpv_set_property_string(mpv, "hwdec", "videotoolbox-copy")
                            }
                            #if DEBUG
                            // Filter out expected recovery-phase noise
                            // that doesn't represent an actionable
                            // problem. All of these fire repeatedly
                            // during the normal MPEG-TS mid-GOP join
                            // sequence and settle on their own once
                            // the first keyframe + SPS/PPS arrives,
                            // or are per-frame decoder hiccups that
                            // `hwdec-software-fallback=90` already
                            // handles by switching to SW decode when
                            // they become persistent. Logging each
                            // one created thousands of log lines per
                            // tile-startup and drowned the actually-
                            // useful STREAM-SUMMARY / FRAME SUMMARY
                            // lines that surface real issues. Error-
                            // level mpv output is still captured
                            // verbatim when it isn't one of these
                            // known-expected messages.
                            if Self.isNoisyRecoveryMessage(text) {
                                break
                            }
                            let prefix = msg.pointee.prefix.map { String(cString: $0) } ?? "?"
                            let level = msg.pointee.level.map { String(cString: $0) } ?? "?"
                            // Tag mpv-internal log lines (cplayer warn,
                            // ffmpeg error, etc.) with this stream's
                            // identifier so "Audio device underrun"
                            // and "A/V desync" can be attributed to a
                            // specific tile rather than leaving us
                            // guessing which of N concurrent streams
                            // is misbehaving.
                            // v1.6.23: route mpv text through
                            // DebugLogger.sanitize so any URL-bearing
                            // log line (HTTP redirects, demuxer init,
                            // etc.) is stripped of Xtream-style
                            // path-credentials and query-param
                            // credentials before reaching the console.
                            // mpv's log text already ends in a newline; drop
                            // it so debugLog (which appends its own) does not
                            // leave a blank line between entries. The old call
                            // used print(..., terminator: "") for this; debugLog
                            // takes no terminator, so trim instead.
                            let safeText = DebugLogger.sanitize(text)
                                .trimmingCharacters(in: .newlines)
                            debugLog("[\(self.logTimestamp)] \(self.streamTag) [MPV-LOG] [\(prefix)] \(level): \(safeText)")
                            #endif
                        }
                        break

                    case MPV_EVENT_SHUTDOWN:
                        #if DEBUG
                        debugLog("[MPV-DIAG] Event: shutdown")
                        #endif
                        self.stopStreamInfoTimer()
                        // Claim shutdown ownership atomically using the same gate
                        // as stop(). Exactly one of the two paths ever executes the
                        // teardown body:
                        //
                        //   Normal flow: stop() claims first → isShuttingDown=true →
                        //   markShuttingDownAndSnapshotMPV() returns nil here → we
                        //   just exit the event loop. stop()'s asyncAfter on mpvQueue
                        //   handles the final mpv_terminate_destroy.
                        //
                        //   Unexpected shutdown: mpv aborts without stop() running →
                        //   we claim ownership here → perform full cleanup below.
                        //
                        //   Race (stop + unexpected shutdown simultaneously): whichever
                        //   caller's markShuttingDownAndSnapshotMPV() returns non-nil
                        //   first is the sole owner; the other sees nil and skips.
                        //   This prevents stop() from calling mpvCommand("quit") on a
                        //   handle that the shutdown path has already destroyed.
                        guard let ownedHandle = self.markShuttingDownAndSnapshotMPV() else {
                            return  // stop() owns teardown; just exit the event loop
                        }
                        mpv_set_wakeup_callback(ownedHandle, nil, nil)
                        if let retain = self.takeWakeupRetain() {
                            retain.release()
                        }
                        self.teardownRenderResourcesOnRenderQueue()
                        // takeMPVHandle nils state.mpv so the asyncAfter in any
                        // concurrent stop() becomes a no-op.
                        if let handle = self.takeMPVHandle() {
                            mpv_terminate_destroy(handle)
                        }
                        return  // Exit event loop

                    case MPV_EVENT_PLAYBACK_RESTART:
                        // The current stream has now reached steady
                        // playback at least once. Arms the reload
                        // watchdogs (they only fire post-restart so a
                        // slow startup probe is never mistaken for a
                        // wedge). See hasReachedPlaybackRestartForStream.
                        self.hasReachedPlaybackRestartForStream = true
                        // A restart after a reported fatal error means a
                        // Retry/auto-reconnect succeeded: let the host
                        // view dismiss its error card.
                        if self.fatalErrorReported {
                            self.fatalErrorReported = false
                            if let recovered = self.onRecovered {
                                Task { await recovered() }
                            }
                        }
                        // Now that initial buffer is filled, disable cache-pause for live
                        // so playback doesn't stall on brief network dips.
                        if self.isLive, let mpv = self.activeMPVHandle() {
                            mpv_set_property_string(mpv, "cache-pause", "no")
                        }
                        // Issue #36: verify the audio chain actually opened
                        // (it silently fails when the tvOS output is set to
                        // Dolby Atmos) once the startup transient is past.
                        if !self.audioHealthCheckScheduled {
                            self.audioHealthCheckScheduled = true
                            self.mpvQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                                self?.runAudioHealthCheck(context: "post-restart")
                            }
                        }
                        // v1.7.x: HDR-only target-prim/trc/tone-mapping.
                        // Now that the stream is decoded enough for mpv
                        // to know its colorspace, apply the BT.709 SDR
                        // pin only for actual HDR sources. See
                        // applyHDRToneMappingIfNeeded() for the rationale.
                        if let mpv = self.activeMPVHandle() {
                            self.applyHDRToneMappingIfNeeded(mpv: mpv)
                        }
                        // Clear the load-failure retry budget now that
                        // playback has actually started. If the stream
                        // later drops with LOADING_FAILED, the user
                        // gets a fresh 3 retries instead of inheriting
                        // a stale counter from a prior mid-session
                        // 503 storm.
                        self.loadFailureRetryCount = 0
                        // Populate audio/subtitle track lists for the UI
                        self.queryTracks()
                        // Update render buffer to match video's native dimensions.
                        // iOS: correct PiP aspect ratio. tvOS: avoid oversized buffer
                        // (e.g., 720p stream was rendering into 1920×1080 — 2.25x wasted pixels).
                        if let mpv = self.activeMPVHandle() {
                            var dw: Int64 = 0; var dh: Int64 = 0
                            mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &dw)
                            mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &dh)
                            if dw > 0 && dh > 0 &&
                               (Int(dw) != self.videoNativeWidth || Int(dh) != self.videoNativeHeight) {
                                // #37: a change from a KNOWN size is a real
                                // mid-stream resolution switch (vs initial config).
                                if self.videoNativeWidth > 0 { self.lastResolutionChangeAt = CFAbsoluteTimeGetCurrent() }
                                self.videoNativeWidth = Int(dw)
                                self.videoNativeHeight = Int(dh)
                                let curW = self.renderWidth
                                let curH = self.renderHeight
                                self.renderWidth = 0; self.renderHeight = 0
                                DispatchQueue.main.async { [weak self] in
                                    self?.handleResize(size: CGSize(width: curW, height: curH))
                                }
                            }
                        }
                        // Auto-resume VOD from saved position (once per session)
                        if !self.isLive, !self.hasAttemptedResume, self.activeMPVHandle() != nil {
                            self.hasAttemptedResume = true
                            let seekAction = self.progressStore.seekAction
                            let explicitMs = self.progressStore.explicitResumeMs
                            let vodID = self.progressStore.vodID
                            let resumeServerID = self.progressStore.vodServerID
                            Task { @MainActor in
                                // Prefer explicit position (from Continue Watching), fall back to DB.
                                // v1.6.8 (Codex A1): pass serverID through so a movie/episode
                                // ID that exists on multiple Dispatcharr servers resumes from
                                // the right server's saved position.
                                let resumeMs: Int32? = if let explicitMs, explicitMs > 0 {
                                    explicitMs
                                } else if let vodID, !vodID.isEmpty {
                                    WatchProgressManager.getResumePosition(
                                        vodID: vodID,
                                        serverID: resumeServerID
                                    )
                                } else {
                                    nil
                                }
                                guard let resumeMs, resumeMs > 0 else { return }
                                seekAction?(resumeMs)
                                debugLog("📼 VOD resume: seeking to \(resumeMs)ms")
                            }
                        }
                        // Populate stream info for the UI overlay
                        if let mpv = self.activeMPVHandle() {
                            let info = self.populateStreamInfo(mpv)
                            self.startStreamInfoTimer()

                            #if DEBUG
                            var cacheDur: Double = 0
                            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
                            var avsync: Double = 0
                            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)
                            let t = self.streamTag
                            debugLog("\(t) [MPV-DIAG] Event: playback-restart — cache=\(String(format: "%.2f", cacheDur))s, avsync=\(String(format: "%.4f", avsync))s")
                            debugLog("\(t) [MPV-STREAM] video=\(info.videoCodec) \(info.width)×\(info.height) \(info.pixelFormat), hwdec=\(info.hwdec)")
                            debugLog("\(t) [MPV-STREAM] audio=\(info.audioCodec) \(info.sampleRate)Hz \(info.channels)ch")
                            #endif
                        }
                        break

                    default:
                        #if DEBUG
                        if let name = mpv_event_name(event.pointee.event_id) {
                            debugLog("[MPV-DIAG] Event: \(String(cString: name))")
                        }
                        #endif
                        break
                    }
                }
            }
        }

        private func handleStartFile() {
            logStore.append("ℹ️ MPV state: opening")
            DebugLogger.shared.logPlayback(event: "opening")
            // Issue #36: new stream, re-arm the audio health check + fallback.
            audioHealthCheckScheduled = false
            audioStereoFallbackApplied = false
            #if DEBUG
            debugLog("[MPV-DIAG] State: opening (start-file)")
            #endif
        }

        /// Issue #36: with the tvOS audio output set to Dolby Atmos, mpv's
        /// AVFoundation audio output can fail to open against the spatial
        /// hardware layout. Playback then continues silently: the audio
        /// decoder never produces (audio-params/channel-count stays 0, the
        /// Stream Info card shows "0Hz 0ch") and no error surfaces. This
        /// check runs ~2.5s after playback restart (and again on audio route
        /// changes), logs the negotiation state in BOTH Debug and Release
        /// (it is the diagnostic we ask issue reporters for), and when the
        /// audio chain is dead it forces a stereo downmix, which the audio
        /// output can always open; tvOS then applies its own spatialization,
        /// so Atmos-capable setups still get surround rendering instead of
        /// silence. One fallback attempt per stream.
        ///
        /// Must be called on mpvQueue.
        private func runAudioHealthCheck(context: String) {
            guard let mpv = self.mpv else { return }
            var decCh: Int64 = 0
            mpv_get_property(mpv, "audio-params/channel-count", MPV_FORMAT_INT64, &decCh)
            var outCh: Int64 = 0
            mpv_get_property(mpv, "audio-out-params/channel-count", MPV_FORMAT_INT64, &outCh)
            let codec = getMPVString(mpv, "audio-codec")
            let ao = getMPVString(mpv, "current-ao")
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute.outputs
                .map { "\($0.portType.rawValue)/\($0.channels?.count ?? -1)ch" }
                .joined(separator: "+")
            debugLog("[AUDIO-HEALTH] \(streamTag) (\(context)) codec=\(codec ?? "none") dec_ch=\(decCh) out_ch=\(outCh) ao=\(ao ?? "NONE") route=[\(route)] session=\(Int(session.sampleRate))Hz/\(session.outputNumberOfChannels)ch")

            // Two dead-chain shapes get the stereo fallback (one attempt per
            // stream); anything else is healthy and left alone:
            //  - codec set, but 0 decoded channels / no ao (#36): the chain
            //    came up and failed against the Atmos output layout.
            //  - codec=nil AND ao=nil (#51): the audiounit ao failed so early
            //    against the receiver's spatial layout (log showed
            //    route=HDMIOutput/32ch, session 48000Hz/32ch) that mpv
            //    disabled audio entirely, so no codec is ever reported. The
            //    old `codec != nil` guard read that as "stream has no audio"
            //    and skipped the fallback, leaving those setups silent on
            //    every channel. Only skip when the missing chain is OUR OWN
            //    doing: the multiview decoder-off strategy (7+ tiles) writes
            //    aid=no, at option time (lastWrittenAID still nil) or via
            //    audio-focus (lastWrittenAID == "no").
            let appDisabledAudio = lastWrittenAID == "no" ||
                (lastWrittenAID == nil && initialTileCount >= 7 && !initialIsAudioActive)
            // GH #56: with audio-fallback-to-null a failed ao surfaces as
            // ao="null" (not nil) while video keeps playing. Treat that as a dead
            // chain too so the stereo-downmix reinit still runs and brings real
            // audio back once the HDMI route settles.
            let aoDead = ao == nil || ao == "null"
            let chainDeadNoCodec = codec == nil && aoDead && !appDisabledAudio
            let chainDeadWithCodec = codec != nil && (decCh <= 0 || aoDead)
            guard chainDeadNoCodec || chainDeadWithCodec, !audioStereoFallbackApplied else { return }
            audioStereoFallbackApplied = true
            let failureShape = codec == nil ? "audio disabled after ao init failure"
                : (aoDead ? "no audio output" : "0 channels")
            debugLog("[AUDIO-FALLBACK] \(streamTag) audio chain failed to open (\(failureShape)); forcing stereo downmix + audio chain reinit (Dolby Atmos output workaround)")
            mpv_set_property_string(mpv, "audio-channels", "stereo")
            // Cycle the audio track so the audio output reopens cleanly with
            // the new layout.
            mpv_set_property_string(mpv, "aid", "no")
            mpv_set_property_string(mpv, "aid", "auto")
            mpvQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runAudioHealthCheck(context: "post-fallback")
            }
        }

        /// v1.7.x Issue A diagnostic. mpv emits MPV_EVENT_VIDEO_RECONFIG
        /// every time the video pipeline rebuilds — at startup (initial
        /// config), at hwdec changes (videotoolbox → videotoolbox-copy
        /// fallback), at decoder reset after error storms, and on
        /// MPEG-TS PMT changes mid-stream. UHD 10-bit HEVC streams
        /// (Sky Sports F1 UHD class) emit these every few seconds and
        /// the burst is the prime suspect for the user-visible "black
        /// flashes every 3-10s" Archie reported on 2026-05-08.
        ///
        /// What gets logged on every reconfig:
        ///   - Time gap since the previous reconfig (bursty == bad).
        ///   - Resolution / pixfmt / colormatrix / codec / hwdec — so
        ///     we can tell if the trigger is a real format change or
        ///     a same-format decoder rebuild.
        ///   - "*CHANGED-from=" marker when hwdec actually flipped.
        ///   - FBO presentation state at the moment of reconfig
        ///     (DESTROYED, RECENTLY_REBUILT(Xms), or active(WxH)) —
        ///     answers "did the user see black because the FBO was
        ///     gone?"
        ///   - Per-window decoder-error counts since the last
        ///     reconfig (PPS / NALU / VT-null / hwdec). Tallied
        ///     in MPV_EVENT_LOG_MESSAGE before the noise filter
        ///     discards the lines, so the counts survive even when
        ///     the underlying log lines don't print.
        ///
        /// After logging, per-window counters reset so each window's
        /// signature is independently visible.
        private func handleVideoReconfig() {
            guard let mpv else { return }
            let now = CFAbsoluteTimeGetCurrent()
            videoReconfigCount &+= 1
            let gap: String
            if lastVideoReconfigAt > 0 {
                gap = String(format: "%.0fms", (now - lastVideoReconfigAt) * 1000.0)
            } else {
                let elapsedMs = setupStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? -1
                gap = "first(+\(String(format: "%.0f", elapsedMs))ms_from_setup)"
            }

            // Snapshot pipeline state.
            var w: Int64 = 0; var h: Int64 = 0
            mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &w)
            mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &h)
            let pixfmt = getMPVString(mpv, "video-params/pixelformat") ?? "?"
            let colormatrix = getMPVString(mpv, "video-params/colormatrix") ?? "?"
            let videoCodec = getMPVString(mpv, "video-codec") ?? "?"
            let hwdec = getMPVString(mpv, "hwdec-current") ?? "none"

            // FBO presentation state. Empty pool means we're
            // actively presenting nothing right now; that's the
            // window during which a user would see black.
            let fboState: String
            if fboSlots.isEmpty {
                fboState = "DESTROYED"
            } else if fboDestroyedAt > 0 && (now - fboDestroyedAt) < 0.05 {
                let rebuildMs = (now - fboDestroyedAt) * 1000.0
                fboState = "RECENTLY_REBUILT(\(String(format: "%.1f", rebuildMs))ms)"
            } else {
                fboState = "active(\(fboSlots.count)-deep \(fboWidth)x\(fboHeight))"
            }

            #if DEBUG
            debugLog("[MPV-RECONFIG] \(streamTag) #\(videoReconfigCount) gap=\(gap) size=\(w)x\(h) pixfmt=\(pixfmt) colormatrix=\(colormatrix) codec=\(videoCodec) hwdec=\(hwdec) fbo=\(fboState) decoderErr_since_last: pps=\(ppsErrorWindow) nalu=\(naluErrorWindow) vt_null=\(vtNullBufferWindow) hwdec_err=\(hwdecErrorWindow)")
            #endif

            // Codex VO-handshake fix: build the native-size FBO HERE on
            // video-reconfig, not only on PLAYBACK_RESTART. For a non-live
            // source the restart can never arrive while the VO is still
            // unconfigured (vo-configured=0), so as soon as the decoded size is
            // known we (re)build + commit the render target. handleResize is
            // main-only (it reads @MainActor MultiviewStore) and dispatches
            // setupFBO -> requestRender on renderQueue, which runs the
            // config-commit render that lets mpv finish the restart. Mirrors
            // the PLAYBACK_RESTART resize so the two paths agree (dwidth/dheight,
            // falling back to the video-params w/h already read above).
            var dw: Int64 = 0; var dh: Int64 = 0
            mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &dw)
            mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &dh)
            if dw <= 0 || dh <= 0 { dw = w; dh = h }
            if dw > 0, dh > 0, (Int(dw) != videoNativeWidth || Int(dh) != videoNativeHeight) {
                // #37: stamp a real mid-stream resolution change (not the
                // initial 0 -> size config) so the stale-frame storm
                // watchdog grants the switch a grace window before reloading.
                if videoNativeWidth > 0 { lastResolutionChangeAt = now }
                videoNativeWidth = Int(dw)
                videoNativeHeight = Int(dh)
                let curW = renderWidth
                let curH = renderHeight
                renderWidth = 0; renderHeight = 0   // force handleResize past its no-op guard
                DispatchQueue.main.async { [weak self] in
                    self?.handleResize(size: CGSize(width: curW, height: curH))
                }
            }

            // Reset per-window counters. Cumulative totals stay.
            ppsErrorWindow = 0
            naluErrorWindow = 0
            vtNullBufferWindow = 0
            hwdecErrorWindow = 0
            lastVideoReconfigAt = now
        }

        private func handleFileLoaded() {
            // Catch-up: land the exact second after a minute-granular
            // re-tune. Runs on the event thread; the seek goes through the
            // async command path like every other seek.
            if let residual = catchupPendingSeekSecs {
                catchupPendingSeekSecs = nil
                mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
                    let secs = String(format: "%.3f", residual)
                    self.mpvCommandAsync(mpv, ["seek", secs, "absolute"])
                }
            }
            // Track buffer exit
            if let entered = bufferEnteredTime {
                let bufDuration = Date().timeIntervalSince(entered)
                totalBufferingDuration += bufDuration
                bufferEnteredTime = nil
                #if DEBUG
                debugLog("[MPV-DIAG]   ↳ Buffer resolved in \(String(format: "%.1f", bufDuration))s (total: \(String(format: "%.1f", totalBufferingDuration))s)")
                #endif
            }

            if !hasStarted {
                hasStarted = true
                anyAttemptStarted = true
                playbackStartTime = Date()
                logStore.append("✓ MPV started")
                DebugLogger.shared.logPlayback(event: "playing — first frame")

                #if DEBUG
                let totalStartMs = setupStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? -1
                debugLog("\(streamTag) [MPV-DIAG]   ↳ First frame rendered (total time from setup: \(String(format: "%.0f", totalStartMs))ms)")

                // Dump stream & cache info at first frame
                if let mpv {
                    var cacheDur: Double = 0
                    mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
                    var pauseForCache: Int64 = 0
                    mpv_get_property(mpv, "paused-for-cache", MPV_FORMAT_FLAG, &pauseForCache)

                    // Stream info
                    let videoCodec = getMPVString(mpv, "video-codec") ?? "?"
                    let audioCodec = getMPVString(mpv, "audio-codec") ?? "?"
                    let hwdecCurrent = getMPVString(mpv, "hwdec-current") ?? "none"
                    let videoFormat = getMPVString(mpv, "video-params/pixelformat") ?? "?"
                    var videoW: Int64 = 0; var videoH: Int64 = 0
                    mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &videoW)
                    mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &videoH)
                    let audioParams = getMPVString(mpv, "audio-params/format") ?? "?"
                    var sampleRate: Int64 = 0; var channels: Int64 = 0
                    mpv_get_property(mpv, "audio-params/samplerate", MPV_FORMAT_INT64, &sampleRate)
                    mpv_get_property(mpv, "audio-params/channel-count", MPV_FORMAT_INT64, &channels)
                    let fileFormat = getMPVString(mpv, "file-format") ?? "?"

                    let t = streamTag
                    debugLog("\(t) [MPV-STREAM] format=\(fileFormat), video=\(videoCodec) \(videoW)×\(videoH) \(videoFormat), hwdec=\(hwdecCurrent)")
                    debugLog("\(t) [MPV-STREAM] audio=\(audioCodec) \(sampleRate)Hz \(channels)ch \(audioParams)")
                    debugLog("\(t) [MPV-STREAM] cache_at_start=\(String(format: "%.2f", cacheDur))s, paused_for_cache=\(pauseForCache != 0)")
                }
                #endif

                // Prevent screensaver/idle timer during playback. Route
                // through the refcount helper so N concurrent multiview
                // tiles each claim the idle timer exactly once and the
                // timer only flips when the last coordinator stops.
                // Wrapped in Task { @MainActor } because this event
                // handler runs on the mpv event queue and
                // IdleTimerRefCount is @MainActor-isolated.
                Task { @MainActor in IdleTimerRefCount.increment() }
            }

            let ps = progressStore
            DispatchQueue.main.async { ps.isPaused = false }

            // Configure Now Playing after 2s stability check (same as VLC)
            if !nowPlayingConfigured {
                let title = nowPlayingTitle
                let sub = nowPlayingSubtitle
                let art = nowPlayingArtworkURL
                let live = isLive

                var dur: Double? = nil
                if !live, let mpv {
                    var duration: Double = 0
                    if mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0, duration > 0 {
                        dur = duration
                    }
                }

                #if DEBUG
                let debugTileID = tileID ?? "single"
                debugLog("[NowPlaying-Gate] \(streamTag) 2s stability scheduled (tileID=\(debugTileID), title=\"\(title)\")")
                #endif

                let ps2 = progressStore
                let mpvQ = mpvQueue
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, !self.nowPlayingConfigured else {
                        #if DEBUG
                        debugLog("[NowPlaying-Gate] 2s fire: self=nil or already configured")
                        #endif
                        return
                    }
                    // Verify still playing — route through mpvQueue to avoid race with stop()
                    let capturedDur = dur  // Bind to let for Sendable compliance
                    mpvQ.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else {
                            #if DEBUG
                            debugLog("[NowPlaying-Gate] mpvQ fire: self/mpv nil or shutting down")
                            #endif
                            return
                        }
                        var idle: Int64 = 0
                        mpv_get_property(mpv, "core-idle", MPV_FORMAT_FLAG, &idle)
                        #if DEBUG
                        debugLog("[NowPlaying-Gate] mpvQ fire: core-idle=\(idle)")
                        #endif
                        guard idle == 0 else { return }

                        Task { @MainActor [weak self] in
                            // Gate on bridge ownership. A non-audio
                            // multiview tile still reaches this path
                            // (every coordinator's stability check
                            // fires after 2s) but must NOT publish
                            // now-playing info — the audio tile owns
                            // the lockscreen. If the gate fails we
                            // deliberately leave `nowPlayingConfigured`
                            // false so a later `handleFileLoaded`
                            // re-arms the 2s timer if this tile
                            // eventually becomes authoritative (e.g.
                            // user-initiated `setAudio` swap). The
                            // previous code set the flag true
                            // unconditionally, which silently disabled
                            // lockscreen forever on any ownership race.
                            guard let self else { return }
                            let canDrive = self.shouldDriveNowPlayingBridge()
                            #if DEBUG
                            let sessionMode = PlayerSession.shared.mode
                            let audioID = MultiviewStore.shared.audioTileID ?? "nil"
                            debugLog("[NowPlaying-Gate] shouldDrive=\(canDrive) tileID=\(self.tileID ?? "single") sessionMode=\(sessionMode) audioTileID=\(audioID)")
                            #endif
                            guard canDrive else { return }
                            self.nowPlayingConfigured = true
                            NowPlayingBridge.shared.configure(
                                title: title,
                                subtitle: sub,
                                artworkURL: art,
                                duration: capturedDur,
                                isLive: live,
                                // Distinct play vs pause intents: an explicit
                                // play command must never pause an already-playing
                                // stream (a head unit / BT stack can emit playCommand
                                // on connect), and vice-versa. Toggle only when the
                                // current state differs from the requested one.
                                onPlay:  { if ps2.isPaused { ps2.togglePauseAction?() } },
                                onPause: { if !ps2.isPaused { ps2.togglePauseAction?() } },
                                onSeek: live ? nil : { [weak self] time in
                                    // Remote / lock-screen seek callbacks fire on
                                    // the main thread; hop to mpvQueue so a stalled
                                    // core can never freeze the UI (see seekAction).
                                    self?.mpvQueue.async { [weak self] in
                                        guard let self, let mpv = self.activeMPVHandle() else { return }
                                        let secs = String(format: "%.3f", time)
                                        self.mpvCommandAsync(mpv, ["seek", secs, "absolute"])
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }

        private func handleEndFile(_ event: UnsafePointer<mpv_event>) {
            guard !isShuttingDown else { return }

            let endFile = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let reason = endFile.reason

            #if DEBUG
            debugLog("[MPV-DIAG] State: end-file (reason=\(reason), error=\(endFile.error))")
            #endif

            // `MPV_END_FILE_REASON_STOP` fires when WE intentionally
            // stopped the current playback — e.g. our own
            // `loadfile replace` issued by `applyPauseIfChanged` to
            // snap live streams to the live edge on unpause. Do NOT
            // treat this as a failure. Before this guard existed,
            // the STOP event fell through to the EOF branch below,
            // which read `elapsed < 0.5s` as "instant end" or
            // `elapsed < 5s` as "premature end" and triggered a
            // retry storm — stacking mpv commands, flooding the
            // proxy, and eventually firing `onFatalError` which
            // painted the red "Decoder unavailable" overlay over
            // a stream that was actually playing correctly after
            // the reload. The fresh loadfile's own lifecycle
            // (start-file → first-frame → playback-restart) is
            // what continues playback; this end-file is just the
            // bookkeeping noise from the handoff.
            if reason == MPV_END_FILE_REASON_STOP {
                #if DEBUG
                debugLog("[MPV-DIAG] end-file STOP (intentional — no retry)")
                #endif
                return
            }

            if reason == MPV_END_FILE_REASON_ERROR {
                let errStr = String(cString: mpv_error_string(endFile.error))
                logStore.append("✗ MPV error: \(errStr)")
                DebugLogger.shared.logPlayback(event: "error: \(errStr)")

                // Live Rewind: ANY load error while routed through the
                // relay drops to the direct stream before the generic
                // retry machinery runs. Retrying the relay re-enters the
                // same failure (the retry path re-routes through
                // play(url:)), which is how a transient relay hiccup
                // burned all three retries and painted the red card.
                if liveRewindActive {
                    relayErrorRecovery(reason: errStr)
                    return
                }

                // Loading-failed specific retry: when Dispatcharr (or
                // the upstream proxy) returns 503 under concurrent
                // tile-load pressure, mpv reports
                // `MPV_ERROR_LOADING_FAILED` (-13). Before this retry
                // existed, the tile would show "Decoder unavailable"
                // permanently even though the stream was fine — proven
                // by the fact that expanding a failed tile to
                // full-screen (a single request) always worked. We
                // retry up to N times with exponential backoff plus
                // random jitter so 9 tiles hitting 503 at the same
                // moment don't all retry at the same wall-clock tick
                // and trigger the same thundering-herd problem again.
                //
                // v1.7.x Phase 4: retry policy is URL-aware.
                // Live streams keep the original 3-retry policy at
                // 1s / 2s / 4s. Recording URLs (`/api/channels/
                // recordings/<id>/file/`) get a longer policy:
                // 5 retries at 3s / 6s / 12s / 24s / 48s. Reasoning:
                // in-progress recordings on Dispatcharr can be
                // momentarily unavailable while the recording file
                // is being initialized server-side or while the
                // server is overloaded by parallel VOD pagination
                // (jesmannstl + Archie repro on v1.6.23: recording
                // 61 NBA Basketball failed 3x at 00:25:58–00:26:07,
                // then succeeded cleanly at 00:27:40 once the bulk
                // VOD load finished). A live-stream-tuned 7s total
                // retry budget gave up too quickly. The longer
                // backoff lets the server stabilize without forcing
                // the user to manually re-tap the row.
                //
                // v1.7.x — extend retry to MPV_ERROR_UNKNOWN_FORMAT
                // (-17, "When trying to load the file, the file
                // format could not be determined, or the file was
                // too broken to open it"). Freyguy1975 reported on
                // Discord 2026-05-08 that adding tiles to multiview
                // on Apple TV consistently produced a transient red
                // "Decoder unavailable / Playback error: unrecognized
                // file format" overlay on either the new tile, the
                // existing tile, or both — clearing if he removed
                // and re-added. The user-visible "unrecognized file
                // format" string maps to UNKNOWN_FORMAT, NOT
                // LOADING_FAILED, so the previous retry path missed
                // it entirely: failoverOrError fired without backoff,
                // the warmup-retry guard (`anyAttemptStarted`) was
                // false because we never got past start-file, and the
                // overlay painted immediately. Same exponential-
                // backoff retry as LOADING_FAILED is appropriate
                // because the underlying cause is the same class:
                // proxy/demuxer briefly couldn't return enough bytes
                // to identify the stream within the analyze window.
                // Step 9 (softer probe settings) reduces but doesn't
                // eliminate this class on UHD HEVC under multiview
                // network competition.
                let isTransientLoadError =
                    (endFile.error == MPV_ERROR_LOADING_FAILED.rawValue ||
                     endFile.error == MPV_ERROR_UNKNOWN_FORMAT.rawValue)
                if isTransientLoadError && loadFailureRetryCount < maxLoadFailureRetries {
                    loadFailureRetryCount += 1
                    let retryNum = loadFailureRetryCount
                    let maxR = maxLoadFailureRetries
                    // Exponential backoff. Live: 1s, 2s, 4s. Recording:
                    // 3s, 6s, 12s, 24s, 48s. Add 0–600ms of random
                    // jitter per tile so concurrent retries don't
                    // line up on the same wall-clock moment.
                    let baseDelay = pow(2.0, Double(retryNum - 1)) * loadFailureBackoffMultiplier
                    let jitter = Double.random(in: 0...0.6)
                    let delay = baseDelay + jitter
                    let retryKind = isRecordingURL ? "recording" : "stream"
                    let errLabel = endFile.error == MPV_ERROR_LOADING_FAILED.rawValue
                        ? "LOADING_FAILED"
                        : "UNKNOWN_FORMAT"
                    logStore.append(
                        "⏳ MPV: \(retryKind) \(errLabel.lowercased()) — retry \(retryNum)/\(maxR) in \(String(format: "%.1f", delay))s"
                    )
                    #if DEBUG
                    debugLog("[MPV-DIAG] \(streamTag) \(errLabel) — retry \(retryNum)/\(maxR) in \(String(format: "%.2f", delay))s (\(retryKind))")
                    #endif
                    // Task #149: native catch-up retries must NOT replay
                    // urls[currentIndex] — that URL is session-bound and
                    // the first seek already revoked its session, so every
                    // replay 401s straight back into this branch until the
                    // budget burns out and the red card paints (ATV log
                    // 2026-07-11 20:46). Mint a FRESH session at the
                    // current window instead.
                    if let cu = catchup, cu.nativeChannelUUID != nil {
                        let resumeMs = catchupBaseOffsetMs
                        cachedRenderer?.flush(removingDisplayedImage: false)
                        mpvQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self else { return }
                            if self.nativeRemintInFlight {
                                self.nativeRemintPendingMs = resumeMs
                            } else {
                                self.startNativeRetune(cu: cu, clampedMs: resumeMs)
                            }
                        }
                        return
                    }
                    let retryURL = urls[currentIndex]
                    // MEMORY-LEAK FIX (pairs with the black-frame reload above):
                    // clear the display-layer renderer's stale enqueued buffers
                    // before the retry re-primes, so the failed load's ~4K
                    // buffer set is not left orphaned while play() stands up a
                    // fresh pipeline. This is the second half of the reload ->
                    // LOADING_FAILED -> re-play sequence that leaked ~750MB on
                    // the bursty UHD stream (live capture 2026-06-29).
                    cachedRenderer?.flush(removingDisplayedImage: false)
                    DispatchQueue.global(qos: .userInitiated)
                        .asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.play(url: retryURL)
                        }
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.failoverOrError("Playback error: \(errStr)")
                }
                return
            }

            // Live Rewind: a reader EOF means the engine closed the
            // session under mpv (reconnect budget exhausted on a
            // provider/network drop, or an external stop). Same policy
            // as the error branch: go direct rather than treating a
            // live channel as "ended".
            if isLive, liveRewindActive {
                relayErrorRecovery(reason: "relay EOF")
                return
            }

            // EOF handling — same premature-end logic as VLC
            if isLive, let startTime = playbackStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < 0.5 {
                    logStore.append("⚠️ MPV: instant end (<0.5s) — skipping to next URL")
                    #if DEBUG
                    debugLog("[MPV-DIAG] Instant end (\(String(format: "%.0f", elapsed * 1000))ms) — failing over")
                    #endif
                    sameURLRetryCount = 0
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.failoverOrError("Stream ended instantly")
                    }
                } else if elapsed < 5.0, sameURLRetryCount < maxSameURLRetries {
                    sameURLRetryCount += 1
                    let retryNum = sameURLRetryCount
                    logStore.append("⚠️ MPV: premature end (<5s) — retrying same URL (\(retryNum)/\(maxSameURLRetries))")
                    #if DEBUG
                    debugLog("[MPV-DIAG] Premature end (\(String(format: "%.1f", elapsed))s) — retrying same URL (\(retryNum)/\(maxSameURLRetries))")
                    #endif
                    let retryURL = urls[currentIndex]
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        self?.play(url: retryURL)
                    }
                } else {
                    DebugLogger.shared.logPlayback(event: "ended — triggering failover")
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.failoverOrError("Stream ended")
                    }
                }
            } else if !hasStarted {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.failoverOrError("Stopped before playback")
                }
            } else if isDVR {
                // DVR (in-progress recording): an EOF here is the live edge
                // catching up to the end of the currently-published HLS
                // playlist, not a real end. Do NOT set playbackEnded (that
                // would lock seeks); the seek clamp keeps us a few seconds
                // back so this is rare, and when it does happen the user can
                // still scrub away and mpv resumes as new segments arrive.
                DebugLogger.shared.logPlayback(event: "DVR reached live edge")
                logStore.append("ℹ️ MPV: DVR live edge")
            } else {
                // Catch-up: a dropped archive session mid-programme
                // reaches this arm looking like a normal end. When the
                // clock says we are well short of the programme end,
                // re-tune once at the last played position instead of
                // ending playback (the seek path already rebuilds the
                // window URL and clears playbackEnded).
                if let cu = catchup, !catchupEofRetuneUsed {
                    let posMs = progressStore.currentMs
                    if posMs < cu.programDurationMs - 60_000 {
                        catchupEofRetuneUsed = true
                        debugLog("[CATCHUP] EOF \((cu.programDurationMs - posMs) / 1000)s early; one-shot re-tune")
                        progressStore.seekAction?(posMs)
                        return
                    }
                }
                // VOD ended normally, not an error. This branch is the
                // non-live, non-DVR case (the `isLive` / `!hasStarted` /
                // `isDVR` arms above already returned), so setting
                // `reachedEOF` here can never fire for live or DVR
                // live-edge EOF. Multiview tiles read `reachedEOF` to
                // show the per-tile "Finished" overlay and hand audio
                // off; the single PlayerView ignores it (own end UI).
                playbackEnded = true
                DispatchQueue.main.async { [weak self] in
                    self?.progressStore.reachedEOF = true
                }
                DebugLogger.shared.logPlayback(event: "ended normally")
                logStore.append("ℹ️ MPV: playback ended")
            }
        }

        private func handlePropertyChange(_ event: UnsafePointer<mpv_event>) {
            guard let mpv else { return }
            let prop = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let namePtr = prop.name else { return }
            let name = String(cString: namePtr)

            switch name {
            case "hwdec-current":
                // v1.7.x Issue A: log the moment mpv applies a new
                // hwdec (most importantly, the videotoolbox →
                // videotoolbox-copy fallback after GL-interop fails
                // on 10-bit HEVC). The log-message path triggers the
                // fallback by writing the property; observing the
                // property tells us the moment libmpv has actually
                // applied it, which is what matters for correlating
                // the visible "blue screen" duration against decoder
                // state. setupStartTime lets us measure +ms from the
                // very beginning of mpv setup so we can see how much
                // of the pre-first-frame window was spent in copy
                // init vs the failed videotoolbox attempt.
                if prop.format == MPV_FORMAT_STRING, let data = prop.data {
                    let strPtr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                    let value = strPtr.map { String(cString: $0) } ?? "none"
                    let elapsedMs = setupStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? -1
                    let prev = lastHwdecCurrentObserved.isEmpty ? "(initial)" : lastHwdecCurrentObserved
                    #if DEBUG
                    debugLog("[MPV-DECODE] \(streamTag) hwdec-current: \(prev) → \(value) at +\(String(format: "%.0f", elapsedMs))ms from setup")
                    #endif
                    // Task #56: mpv's software fallback is PERMANENT, but on
                    // live TS the usual trigger is transient join garbage
                    // (pre-keyframe HEVC data poisoning the VideoToolbox
                    // session -- upstream mpv #9085/#9690; MPVKit/FFmpeg
                    // bumps do not fix it, verified against n8.1.2). When
                    // hardware decode drops to software, schedule ONE
                    // re-assert of videotoolbox-copy 3s later -- past the
                    // next keyframe on any sane broadcast GOP -- so 4K HEVC
                    // HDR channels recover hardware decode instead of
                    // burning CPU in 4K software decode forever. One-shot
                    // per stream: a genuinely VT-hostile stream retries
                    // once, fails again, and stays software.
                    let fellBackToSoftware = value == "no"
                        && lastHwdecCurrentObserved.hasPrefix("videotoolbox")
                    if fellBackToSoftware, isLive, claimHwdecReassertIfNeeded() {
                        debugLog("[MPV-DECODE] \(streamTag) hw→software fallback on live stream; scheduling one videotoolbox-copy re-assert in 3s (task #56)")
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self, let current = self.mpv, current == mpv,
                                  !self.withPlaybackStateLock({ $0.isShuttingDown }) else { return }
                            debugLog("[MPV-DECODE] \(self.streamTag) re-asserting videotoolbox-copy after software fallback")
                            mpv_set_property_string(current, "hwdec", "videotoolbox-copy")
                        }
                    }
                    lastHwdecCurrentObserved = value
                }

            case "pause":
                if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                    let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                    // GH #60: authoritative pause mirror for the watchdogs.
                    // lastAppliedPause only tracks applyPauseIfChanged; pauses
                    // via the progress-store commands / PiP / rewind transport
                    // write mpv directly and bypassed it - 12s into such a
                    // pause the stale watchdog treated the intentional freeze
                    // as a wedge and loadfile-replace-looped (reporter's
                    // every-20s double connection while paused).
                    mpvObservedPaused = paused
                    let ps = progressStore
                    DispatchQueue.main.async { ps.isPaused = paused }

                    if paused {
                        logStore.append("ℹ️ MPV state: paused")
                        var timePos: Double = 0
                        mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &timePos)
                        Task { @MainActor [weak self] in
                            guard let self, self.shouldDriveNowPlayingBridge() else { return }
                            NowPlayingBridge.shared.updateElapsed(timePos, rate: 0.0)
                        }
                    }
                }

            case "duration":
                // Catch-up: NEVER let mpv's reported duration overwrite the
                // pinned programme length (the timeshift TS advertises an
                // estimated size, and each re-tune reports the remaining
                // window, not the whole programme).
                if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data, !isLive, catchup == nil {
                    let duration = data.assumingMemoryBound(to: Double.self).pointee
                    let ms = Int32(duration * 1000)
                    let ps = progressStore
                    DispatchQueue.main.async { ps.durationMs = ms }
                }

            case "time-pos":
                if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data {
                    let timeSec = data.assumingMemoryBound(to: Double.self).pointee
                    let ms = Int32(timeSec * 1000)

                    // First-start detection fallback
                    if !hasStarted, ms > 0 {
                        hasStarted = true
                        anyAttemptStarted = true
                        playbackStartTime = Date()
                        logStore.append("✓ MPV time advanced: \(ms)ms")
                        #if DEBUG
                        debugLog("[MPV-DIAG] First time change: \(ms)ms — playback started")
                        #endif
                    }

                    // Throttle UI updates. Live channels have no timeline
                    // EXCEPT in Live Rewind, where currentMs anchors the
                    // transport: without this pump the store stays 0 until
                    // the first seek writes it, so the first Rewind press
                    // computed max(0, 0 - 30s) and re-tuned to the buffer
                    // TAIL (ATV field report: "first RW went back to the
                    // very beginning"), and the timeline never ticked
                    // while rewound.
                    let now = Date()
                    if !isLive || liveRewindActive, now.timeIntervalSince(lastProgressUpdate) >= 1.0 {
                        lastProgressUpdate = now
                        let ps = progressStore
                        // Catch-up: mpv's clock restarts at ~0 after every
                        // re-tune; the programme-relative position adds the
                        // tuned window's base offset.
                        var display = catchup != nil ? catchupBaseOffsetMs + ms : ms
                        if liveRewindActive, let buf = LiveRewindEngine.shared.bufferForReader {
                            // Scrubber position = wall position - window tail.
                            let wall = LiveRewindEngine.shared.readerBaseWallMs + Int64(ms)
                            display = Int32(clamping: max(0, wall - buf.tailWallMs))
                        }
                        DispatchQueue.main.async { ps.currentMs = display }
                    }

                    // Save VOD progress every 30 seconds (non-live only).
                    // v1.7.4.x: was 10s, but each save() hops through
                    // modelContext.save() -> SwiftData persistent-store
                    // change broadcast -> every @Query in the app re-fires.
                    // RootView's `@Query servers` + `@Query playlists` re-
                    // render under MainTabView and any open tvOS context
                    // menu flashes (same disease that commit 06842ce fixed
                    // by removing @Query from EPGGuideView). Tripling the
                    // interval cuts the menu-flash rate to 1/3 without
                    // changing the on-disk resume position UX in a way the
                    // user can perceive (a 30s rather than 10s window of
                    // possibly-lost-on-crash progress). Pause / EOF still
                    // save immediately on the player teardown path.
                    if !isLive, now.timeIntervalSince(lastProgressSave) >= 30.0 {
                        lastProgressSave = now
                        let ps = progressStore
                        let posMs = ms
                        var durSec: Double = 0
                        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &durSec)
                        let durMs = Int32(durSec * 1000)
                        if let vodID = ps.vodID, !vodID.isEmpty, durMs > 0 {
                            let title = ps.vodTitle ?? ""
                            let poster = ps.vodPosterURL
                            let streamURLStr = ps.vodStreamURL
                            let serverIDStr = ps.vodServerID
                            let vodType = ps.vodType
                            let finished = durMs > 0 && posMs > Int32(Double(durMs) * 0.9)
                            Task { @MainActor in
                                WatchProgressManager.save(
                                    vodID: vodID, title: title, positionMs: posMs,
                                    durationMs: durMs, posterURL: poster, vodType: vodType,
                                    isFinished: finished,
                                    streamURL: streamURLStr, serverID: serverIDStr
                                )
                            }
                        }
                    }

                    // Periodic diagnostics + Now Playing update
                    timeChangeCount += 1
                    let npInterval: TimeInterval = isLive ? 15.0 : 5.0
                    if now.timeIntervalSince(lastTimePrint) >= npInterval {
                        printDiagnostics(mpv: mpv, timeSec: timeSec)
                        timeChangeCount = 0
                        lastTimePrint = now
                    }
                }

            case "paused-for-cache":
                if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                    let buffering = data.assumingMemoryBound(to: Int32.self).pointee != 0
                    if buffering {
                        bufferEventCount += 1
                        bufferEnteredTime = Date()
                        logStore.append("ℹ️ MPV state: buffering")
                        #if DEBUG
                        var cacheDur: Double = 0
                        if let mpv = self.activeMPVHandle() {
                            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
                        }
                        debugLog("[MPV-DIAG]   ↳ Buffering started (event #\(bufferEventCount)), cache_at_stall=\(String(format: "%.2f", cacheDur))s, underruns_so_far=\(self.audioUnderrunCount)")
                        #endif
                    } else if let entered = bufferEnteredTime {
                        let bufDuration = Date().timeIntervalSince(entered)
                        totalBufferingDuration += bufDuration
                        bufferEnteredTime = nil
                        #if DEBUG
                        debugLog("[MPV-DIAG]   ↳ Buffer resolved in \(String(format: "%.1f", bufDuration))s (total: \(String(format: "%.1f", totalBufferingDuration))s)")
                        #endif
                    }
                }

            case "core-idle":
                // core-idle=true + !paused can indicate end of stream
                break

            default:
                break
            }
        }

        // MARK: - Diagnostics

        private func printDiagnostics(mpv: OpaquePointer, timeSec: Double) {
            // Frame drop stats
            var videoDrops: Int64 = 0
            var decoderDrops: Int64 = 0
            mpv_get_property(mpv, "frame-drop-count", MPV_FORMAT_INT64, &videoDrops)
            mpv_get_property(mpv, "decoder-frame-drop-count", MPV_FORMAT_INT64, &decoderDrops)

            let deltaVideoDrops = videoDrops - prevDroppedFrames
            let deltaDecoderDrops = decoderDrops - prevDecoderDrops
            prevDroppedFrames = videoDrops
            prevDecoderDrops = decoderDrops

            // Cache state
            var cacheDuration: Double = 0
            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDuration)
            var cacheBytes: Int64 = 0
            mpv_get_property(mpv, "demuxer-cache-state/total-bytes", MPV_FORMAT_INT64, &cacheBytes)
            var cacheSpeed: Double = 0
            mpv_get_property(mpv, "cache-speed", MPV_FORMAT_DOUBLE, &cacheSpeed)
            var pausedForCache: Int64 = 0
            mpv_get_property(mpv, "paused-for-cache", MPV_FORMAT_FLAG, &pausedForCache)

            // Video stats
            var estimatedFPS: Double = 0
            mpv_get_property(mpv, "estimated-vf-fps", MPV_FORMAT_DOUBLE, &estimatedFPS)
            var displayFPS: Double = 0
            mpv_get_property(mpv, "estimated-display-fps", MPV_FORMAT_DOUBLE, &displayFPS)
            // v1.7.x Step 7: container-fps is the FPS reported by the
            // demuxer. Codex flagged that we never establish a stable
            // cadence reference (`fps_detected=0.00` throughout the
            // 22:04 log), which leaves anomaly detection partially
            // blind. Both `container-fps` (demuxer-reported) and
            // `estimated-vf-fps` (decoder-measured) are surfaced
            // separately in MPV-PERF so we can see whether mpv ever
            // converges on a stable cadence for UHD HEVC live MPEG-TS.
            var containerFPS: Double = 0
            mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &containerFPS)
            // v1.7.4.x: with `vo=libmpv` (we replace mpv's internal VO),
            // both `estimated-vf-fps` and `container-fps` can stop
            // reporting after a `loadfile replace` channel-flip swap -
            // mpv returns 0 even when playback is healthy at a stable
            // cadence. Stream Info would then show "0.00fps" forever
            // (Archie, Sky Sports Football, 09:01:32 onwards). Derive
            // a fallback fps from our own measured frame intervals when
            // mpv's properties are zero. This is the cadence the AVSBDL
            // is actually presenting at, so it is also the right number
            // for the user-facing readout.
            if containerFPS <= 0 && estimatedFPS <= 0 && frameIntervals.count > 30 {
                let recentSum = frameIntervals.suffix(60).reduce(0, +)
                let recentCount = Double(min(frameIntervals.count, 60))
                let avgIntervalMs = recentSum / recentCount
                if avgIntervalMs > 4 && avgIntervalMs < 200 {
                    let measuredFps = 1000.0 / avgIntervalMs
                    containerFPS = measuredFps
                    detectedFps = measuredFps
                }
            }
            #if os(tvOS)
            // Task #186: periodic re-check catches streams whose fps only
            // becomes known via measured intervals (unsignaled DVB TS), and
            // fps changes mpv reports mid-stream. Deduped internally --
            // steady state is a no-op.
            if containerFPS > 0 {
                applyDisplayCriteriaIfNeeded(fps: containerFPS)
            } else if estimatedFPS > 0 {
                applyDisplayCriteriaIfNeeded(fps: estimatedFPS)
            }
            #endif
            // Feed the AVSBDL re-enqueue watchdog the live container fps
            // so its stale threshold can scale to the stream's natural
            // frame interval. Without this the watchdog fires between
            // every real frame on sub-60fps content, doubling per-frame
            // main-thread work. See `watchdogStaleThresholdFloor` for
            // the rationale and `handleWatchdogTick` for how the value
            // is consumed.
            if containerFPS > 0 {
                let captured = containerFPS
                Task { @MainActor [weak self] in
                    self?.containerFpsHint = captured
                }
            }

            // A/V sync. mpv's `avsync` is computed internally as
            // audio_position - video_position; positive means video
            // is behind audio, negative means video is ahead. With
            // `vo=libmpv` we don't have a working `video-pts`
            // property (the 22:21 field test found it returns 0.000s
            // throughout the session — populated only by mpv's
            // internal VO module which we replace), so we rely on
            // mpv's own `avsync` for the canonical sync metric. See
            // also the MPV-CALLBACK-GAP block in `scheduleRender`.
            var avsync: Double = 0
            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)
            var audioPts: Double = 0
            mpv_get_property(mpv, "audio-pts", MPV_FORMAT_DOUBLE, &audioPts)

            // Audio device buffer
            let isPlaying: Bool = {
                var flag: Int64 = 0
                mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
                return flag == 0
            }()

            // Network speed (for live streams).
            // v1.7.x Step 8: `demuxer-cache-state/raw-input-rate` is
            // returned as a DOUBLE (bytes/sec, fractional ok), not an
            // INT64. Reading it as INT64 always returned 0 (silent
            // format-mismatch failure), which made the cache-drain
            // hypothesis from the 22:21 field test (`speed: 1441KB/s,
            // input_rate: 0KB/s`) untestable. Fixed format. Two other
            // sites at lines ~5072 / ~5107 already use DOUBLE
            // correctly; this was the only broken one.
            var demuxerInputBytesPerSec: Double = 0
            mpv_get_property(mpv, "demuxer-cache-state/raw-input-rate", MPV_FORMAT_DOUBLE, &demuxerInputBytesPerSec)

            let hwdecCurrent = getMPVString(mpv, "hwdec-current") ?? "none"

            // Frame timing / jitter stats
            let frameCount = totalFrameCount
            let lateFrames = lateFrameCount

            var avgInterval: Double = 0, jitterMs: Double = 0, maxInterval: Double = 0, minInterval: Double = 0
            if frameIntervals.count > 2 {
                let sum = frameIntervals.reduce(0, +)
                avgInterval = sum / Double(frameIntervals.count)
                let variance = frameIntervals.reduce(0.0) { $0 + ($1 - avgInterval) * ($1 - avgInterval) } / Double(frameIntervals.count)
                jitterMs = sqrt(variance)  // Standard deviation = jitter
                maxInterval = frameIntervals.max() ?? 0
                minInterval = frameIntervals.min() ?? 0
            }

            var avgRenderMs: Double = 0, maxRenderMs: Double = 0
            if renderDurations.count > 2 {
                avgRenderMs = renderDurations.reduce(0, +) / Double(renderDurations.count)
                maxRenderMs = renderDurations.max() ?? 0
            }

            // Display layer health
            var layerStatus = "ok"
            if let renderer = cachedRenderer {
                if renderer.status == .failed {
                    layerStatus = "FAILED: \(renderer.error?.localizedDescription ?? "?")"
                } else if renderer.isReadyForMoreMediaData == false {
                    layerStatus = "BACKPRESSURE"
                }
            }

            #if DEBUG
            let ts = logTimestamp
            let ms = Int32(timeSec * 1000)
            // `streamTag` prefix on every diagnostic line so logs
            // from N concurrent tiles can be filtered by channel.
            // Example: `grep "NBC Sports" logs.txt | grep jitter`
            // gives you that one stream's jitter timeline.
            let t = streamTag
            debugLog("[\(ts)] \(t) [MPV-DIAG] time=\(ms)ms isPlaying=\(isPlaying) callbacks/\(isLive ? 15 : 5)s=\(timeChangeCount)")
            debugLog("[\(ts)] \(t) [MPV-PERF] vo_drops: +\(deltaVideoDrops), dec_drops: +\(deltaDecoderDrops), fps: estimated=\(String(format: "%.1f", estimatedFPS))/container=\(String(format: "%.1f", containerFPS))/display=\(String(format: "%.1f", displayFPS)), hwdec=\(hwdecCurrent)")
            debugLog("[\(ts)] \(t) [MPV-FRAME] render: \(String(format: "%.1f", avgRenderMs))ms avg / \(String(format: "%.1f", maxRenderMs))ms max, interval: \(String(format: "%.1f", avgInterval))ms avg [\(String(format: "%.1f", minInterval))-\(String(format: "%.1f", maxInterval))ms], jitter: \(String(format: "%.2f", jitterMs))ms, late: \(lateFrames)/\(frameCount), layer: \(layerStatus)")
            debugLog("[\(ts)] \(t) [MPV-CACHE] duration: \(String(format: "%.2f", cacheDuration))s, bytes: \(cacheBytes / 1024)KB, speed: \(String(format: "%.0f", cacheSpeed / 1024))KB/s, input_rate: \(String(format: "%.0f", demuxerInputBytesPerSec / 1024))KB/s, paused_for_cache: \(pausedForCache != 0)")
            // v1.7.x Step 8: drop the video-pts read and the
            // self-computed `a-v` field. mpv's `avsync` property is
            // the canonical sync metric on this render path; see the
            // comment block at the avsync read above for the full
            // rationale. `audio_pts` is still included because it's
            // the only useful absolute time anchor on this path.
            debugLog("[\(ts)] \(t) [MPV-AUDIO] audio_pts=\(String(format: "%.2f", audioPts))s avsync=\(String(format: "%+.4f", avsync))s(positive=video_behind, mpv-internal) underruns=\(audioUnderrunCount) audio_reconfigs=\(audioReconfigCount) buf_events=\(bufferEventCount) buf_time=\(String(format: "%.1f", totalBufferingDuration))s")
            // One-line per-stream summary — the "tl;dr" that's
            // easiest to grep when scanning 9 concurrent tiles'
            // logs. Mirrors the key numbers from the verbose lines
            // above so `grep STREAM-SUMMARY` gives a quick overview.
            // v1.7.x Step 8: `avsync` (mpv-internal, sign-explicit)
            // replaces the bogus self-computed `a-v`. Includes
            // container-fps and gap-class counts so steady-state
            // cadence health is visible at a glance.
            debugLog("[\(ts)] \(t) [STREAM-SUMMARY] fps=\(String(format: "%.1f", estimatedFPS))/cont=\(String(format: "%.1f", containerFPS)) interval=\(String(format: "%.1f", avgInterval))ms jitter=\(String(format: "%.1f", jitterMs))ms late=\(lateFrames)/\(frameCount) vo_drops=+\(deltaVideoDrops) dec_drops=+\(deltaDecoderDrops) underruns=\(audioUnderrunCount) avsync=\(String(format: "%+.3f", avsync))s gaps=\(callbackGapMildCount)/\(callbackGapModerateCount)/\(callbackGapSevereCount)(mild/mod/sev) cache=\(String(format: "%.1f", cacheDuration))s hwdec=\(hwdecCurrent) layer=\(layerStatus)")
            #endif

            DebugLogger.shared.log(
                "vo_drops=+\(deltaVideoDrops) dec_drops=+\(deltaDecoderDrops) cache=\(String(format: "%.1f", cacheDuration))s fps=\(String(format: "%.1f", estimatedFPS)) bufEvents=\(bufferEventCount) bufTime=\(String(format: "%.1f", totalBufferingDuration))s underruns=\(audioUnderrunCount)",
                category: "MPV-Perf", level: .perf)

            // Task #183: native catch-up position reporting rides this
            // stats tick (5s cadence on timeshift files) WHILE PLAYING.
            // These ticks are time-pos-driven, so they stop when paused -
            // the 2s streamInfoTimer carries the paused-side heartbeat
            // instead. Displayed programme position = window base offset
            // + mpv time-pos within the window.
            if let cu = catchup, cu.nativeChannelUUID != nil {
                let position = Double(catchupBaseOffsetMs) / 1000.0 + max(0, timeSec)
                catchupLastKnownPositionSecs = position
                reportCatchupPositionIfDue(positionSecs: position,
                                           paused: lastAppliedPause == true,
                                           force: false)
            }

            // Process-wide resource snapshot, tagged with this tile's
            // ID so the stats from multiple concurrent tiles can be
            // disambiguated in the log stream. `ProcessMetrics` uses
            // `task_vm_info_data_t.phys_footprint` (the same counter
            // Xcode's memory graph uses) instead of `resident_size`,
            // which undercounts IOSurface-backed textures on iOS/tvOS
            // — critical when we're trying to tell whether the 2nd
            // tile's `Failed to open` is a memory-pressure symptom.
            //
            // FD count is the real new signal: each live mpv tile
            // holds ~5-7 FDs, and the iOS/tvOS default soft limit is
            // 256. If tiles 1-4 drive FDs past ~200 and tile 5 fails
            // to open its socket, the number will say so plainly.
            let metricsLine = ProcessMetrics.summaryLine()
            let tile = tileID ?? "single"
            #if DEBUG
            debugLog("[\(ts)] [MPV-PERF] tile=\(tile) \(metricsLine)")
            #endif
            DebugLogger.shared.log("tile=\(tile) \(metricsLine)",
                                    category: "MPV-Perf", level: .perf)

            // Update Now Playing elapsed time — only the authoritative
            // coordinator (single-mode, or the current audio tile in
            // multiview) writes; non-audio tiles stay quiet to avoid
            // thrashing MPNowPlayingInfoCenter on every stats tick.
            let rate: Float = isPlaying ? 1.0 : 0.0
            Task { @MainActor [weak self] in
                guard let self, self.shouldDriveNowPlayingBridge() else { return }
                NowPlayingBridge.shared.updateElapsed(timeSec, rate: rate)
            }
        }

        // MARK: - Failover (identical logic to VLC coordinator)

        private func failoverOrError(_ reason: String) {
            guard !isShuttingDown else { return }

            logStore.append("✗ MPV: \(reason)")
            if currentIndex + 1 < urls.count {
                currentIndex += 1
                let nextURL = urls[currentIndex]
                let idx = currentIndex
                #if DEBUG
                debugLog("[MPV-DIAG] Failover: waiting 300ms before attempt \(idx + 1)/\(urls.count)")
                #endif
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    debugLog("[MPV-DIAG] Failover: starting attempt \(idx + 1)")
                    #endif
                    self.play(url: nextURL)
                }
            } else if isLive && anyAttemptStarted && !hasPerformedWarmupRetry {
                hasPerformedWarmupRetry = true
                logStore.append("⏳ MPV: proxy warming up — retrying in 2s…")
                #if DEBUG
                debugLog("[MPV-DIAG] Warmup retry: waiting 2s before retry")
                #endif
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.currentIndex = 0
                    self.anyAttemptStarted = false
                    self.logStore.append("🔄 MPV: warm-up retry")
                    #if DEBUG
                    debugLog("[MPV-DIAG] Warmup retry: starting")
                    #endif
                    self.play(url: self.urls[0])
                }
            } else {
                fatalErrorReported = true
                let callback = onFatalError
                Task { await callback(reason) }
            }
        }

        // MARK: - Helpers

        /// HH:MM:SS timestamp for log lines.
        private static let logDateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return f
        }()
        private var logTimestamp: String { Self.logDateFormatter.string(from: Date()) }

        /// Substrings that identify mpv log lines which are
        /// expected-and-recoverable noise during normal playback,
        /// not actionable problems. We filter these from the DEBUG
        /// log stream so useful signal (STREAM-SUMMARY, FRAME
        /// SUMMARY, real failures) isn't drowned by decoder spam.
        ///
        /// Taxonomy of what's in here:
        ///   - `non-existing SPS/PPS`, `no frame!`, `non-existing
        ///     SPS ... referenced in buffering period` — MPEG-TS
        ///     mid-GOP join; mpv recovers on the next keyframe.
        ///   - `Error while decoding frame (hardware decoding)`,
        ///     `hardware accelerator failed to decode picture`,
        ///     `vt decoder cb: output image buffer is null` — VT
        ///     per-frame hiccups under N-way concurrent decode
        ///     pressure; `hwdec-software-fallback=90` catches
        ///     persistent cases and switches the tile to SW decode.
        ///   - `Invalid video timestamp`, `Invalid audio PTS`,
        ///     `Reset playback due to audio timestamp reset` —
        ///     MPEG-TS packet-loss recovery, mpv resyncs on its own.
        ///   - `Audio/Video desynchronisation detected!` and the
        ///     multi-line "Possible reasons include..." block that
        ///     follows — fires once per playback-restart while mpv
        ///     resyncs its A/V clock.
        ///   - `Increasing reorder buffer` — routine h264 decoder
        ///     buffer-size adjustment message.
        ///   - `mpegts: Packet corrupt` — single-packet drop
        ///     recovery, the demuxer skips the bad packet and
        ///     continues.
        ///   - `co located POCs unavailable` — h264 POC reference
        ///     missing after mid-GOP join.
        ///
        /// `Audio device underrun detected` is deliberately NOT
        /// here — we do want to see those, they're the one audio
        /// signal that actually matters. The `audioUnderrunCount`
        /// increment above still fires regardless of this filter.
        private static let noisyRecoverySubstrings: [String] = [
            "non-existing SPS",
            "non-existing PPS",
            "no frame!",
            "Error while decoding frame",
            "hardware accelerator failed to decode picture",
            "vt decoder cb: output image buffer is null",
            "Invalid video timestamp",
            "Invalid audio PTS",
            "Reset playback due to audio timestamp reset",
            "Audio/Video desynchronisation detected",
            "Possible reasons include too slow",
            "position will not match to the video",
            "Consider trying `--profile=fast`",
            "Increasing reorder buffer",
            "mpegts: Packet corrupt",
            "co located POCs unavailable",
            "No frame decoded?"
        ]

        /// Human-readable name for AVQueuedSampleBufferRenderingStatus
        /// raw values, used by the v1.7.x [AVSBDL-STATUS] transition
        /// log. iOS 17+ defines: 0 = .unknown, 1 = .rendering,
        /// 2 = .failed. Anything else is logged as raw value so a
        /// future iOS adding a new case still produces useful logs.
        private static func statusName(_ status: AVQueuedSampleBufferRenderingStatus) -> String {
            switch status {
            case .unknown:   return "unknown"
            case .rendering: return "rendering"
            case .failed:    return "failed"
            @unknown default: return "raw(\(status.rawValue))"
            }
        }

        private static func isNoisyRecoveryMessage(_ text: String) -> Bool {
            for needle in noisyRecoverySubstrings where text.contains(needle) {
                return true
            }
            // Also filter standalone blank `warn:` lines — mpv's
            // cplayer module emits a blank warn line around every
            // multi-line warning (sandwich markers). Dropping the
            // bread along with the filling.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
        }

        /// v1.7.x Issue A round 6: cheap luminance probe on a BGRA
        /// CVPixelBuffer. Returns (avg, std) over a stratified 16x16
        /// grid = 256 sample points, using Rec. 601 luma weights.
        ///
        /// Cost on Apple silicon, UHD 3840x2160:
        ///   - CVPixelBufferLockBaseAddress with kCVPixelBufferLock_ReadOnly:
        ///     ~50-100 microseconds (memory barrier; A18+ has unified
        ///     memory so this is not a copy, just a synchronization).
        ///   - 256 stride-walks across the IOSurface + arithmetic:
        ///     ~50-100 microseconds.
        ///   - Total: well under 0.5ms per frame, 25ms/sec at 50fps,
        ///     ~2.5% of a CPU core. Acceptable on a single-stream
        ///     UHD playback path.
        ///
        /// Returns (-1, -1) if the buffer can't be locked or the
        /// format isn't 32BGRA (the format our render path uses).
        /// Caller treats those as "don't suppress" by checking the
        /// thresholds against the returned values.
        private static func detectBlackFrame(_ pixelBuffer: CVPixelBuffer) -> (avg: Double, std: Double) {
            // Format check: our render path always produces 32BGRA
            // via CVPixelBufferCreate in setupFBO. If this ever
            // changes (e.g. p010 zero-copy lands), this guard
            // signals "skip detection" rather than misreading the
            // bytes as BGRA.
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            guard format == kCVPixelFormatType_32BGRA else {
                return (-1, -1)
            }
            let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            guard lockResult == kCVReturnSuccess else { return (-1, -1) }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard width > 0, height > 0,
                  let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return (-1, -1)
            }
            let ptr = base.assumingMemoryBound(to: UInt8.self)

            // 16x16 stratified grid = 256 samples, evenly distributed.
            // Sampling at the center of each cell so we don't bias
            // toward edges that may have letterbox bars on some
            // sources.
            let strips = 16
            let stepX = max(1, width / strips)
            let stepY = max(1, height / strips)
            let centerX = stepX / 2
            let centerY = stepY / 2

            var sum: Double = 0
            var sumSq: Double = 0
            var count: Int = 0

            for sy in 0..<strips {
                let y = sy * stepY + centerY
                if y >= height { break }
                let rowOff = y * bytesPerRow
                for sx in 0..<strips {
                    let x = sx * stepX + centerX
                    if x >= width { break }
                    let off = rowOff + x * 4  // BGRA: 4 bytes/pixel
                    let b = Double(ptr[off + 0])
                    let g = Double(ptr[off + 1])
                    let r = Double(ptr[off + 2])
                    // Rec. 601 luma — close enough for "is it black".
                    // (Stream is BT.2020 but we render to BGRA in
                    // mpv's render shaders, so by the time we sample
                    // here it's standard sRGB-style values.)
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    sum += luma
                    sumSq += luma * luma
                    count += 1
                }
            }
            guard count > 0 else { return (-1, -1) }
            let avg = sum / Double(count)
            let variance = (sumSq / Double(count)) - (avg * avg)
            let std = sqrt(max(0, variance))
            return (avg, std)
        }

        /// Convert CVPixelBuffer to CMSampleBuffer for AVSampleBufferDisplayLayer.
        private static func makeSampleBuffer(
            from pixelBuffer: CVPixelBuffer,
            presentationTime: CMTime
        ) -> CMSampleBuffer? {
            var formatDesc: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard status == noErr, let desc = formatDesc else { return nil }

            // Duration is .invalid — mpv with video-sync=audio delivers frames
            // at display refresh rate (~60fps) regardless of content FPS,
            // duplicating frames as needed. Declaring a content-based duration
            // (e.g. 33ms for 30fps) conflicts with the actual 16.5ms delivery
            // interval, confusing the display layer. With .invalid duration,
            // each frame shows until the next one is enqueued — matching exactly
            // how mpv delivers them.
            var timingInfo = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: presentationTime,
                decodeTimeStamp: .invalid
            )

            var sampleBuffer: CMSampleBuffer?
            let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: desc,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer
            )
            guard createStatus == noErr else { return nil }
            return sampleBuffer
        }

        /// Query mpv's track-list and populate progressStore with audio/subtitle tracks.
        private func queryTracks() {
            guard let mpv else { return }
            var count: Int64 = 0
            mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count)

            var audio: [MediaTrack] = []
            var subs: [MediaTrack] = []

            for i in 0..<Int(count) {
                let prefix = "track-list/\(i)"
                let type = getMPVString(mpv, "\(prefix)/type") ?? ""
                guard type == "audio" || type == "sub" else { continue }

                var trackID: Int64 = 0
                mpv_get_property(mpv, "\(prefix)/id", MPV_FORMAT_INT64, &trackID)
                let lang = getMPVString(mpv, "\(prefix)/lang") ?? ""
                let title = getMPVString(mpv, "\(prefix)/title") ?? ""
                let codec = getMPVString(mpv, "\(prefix)/codec") ?? ""
                var isDefault: Int = 0
                mpv_get_property(mpv, "\(prefix)/default", MPV_FORMAT_FLAG, &isDefault)

                let track = MediaTrack(id: Int(trackID), type: type, title: title,
                                       lang: lang, codec: codec, isDefault: isDefault != 0)
                if type == "audio" { audio.append(track) }
                else { subs.append(track) }
            }

            var currentAID: Int64 = 0
            mpv_get_property(mpv, "aid", MPV_FORMAT_INT64, &currentAID)
            var currentSID: Int64 = 0
            mpv_get_property(mpv, "sid", MPV_FORMAT_INT64, &currentSID)

            let ps = progressStore
            DispatchQueue.main.async {
                ps.audioTracks = audio
                ps.subtitleTracks = subs
                ps.currentAudioTrackID = Int(currentAID)
                ps.currentSubtitleTrackID = Int(currentSID)
            }
        }

        // MARK: - Stream Info

        /// Populate static stream info fields (codec, resolution, hwdec, audio params).
        /// Called once on PLAYBACK_RESTART from mpvQueue. Returns the info for debug logging.
        @discardableResult
        private func populateStreamInfo(_ mpv: OpaquePointer) -> StreamInfo {
            let videoCodec = getMPVString(mpv, "video-codec") ?? ""
            let audioCodec = getMPVString(mpv, "audio-codec") ?? ""
            let hwdecCurrent = getMPVString(mpv, "hwdec-current") ?? "none"
            let pixelFormat = getMPVString(mpv, "video-params/pixelformat") ?? ""

            var videoW: Int64 = 0; var videoH: Int64 = 0
            mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &videoW)
            mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &videoH)

            var sampleRate: Int64 = 0; var channels: Int64 = 0
            mpv_get_property(mpv, "audio-params/samplerate", MPV_FORMAT_INT64, &sampleRate)
            mpv_get_property(mpv, "audio-params/channel-count", MPV_FORMAT_INT64, &channels)

            var fps: Double = 0
            mpv_get_property(mpv, "estimated-vf-fps", MPV_FORMAT_DOUBLE, &fps)
            if fps <= 0 {
                mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &fps)
            }
            if fps > 0 { detectedFps = fps }
            #if os(tvOS)
            // Task #186: first shot at matching the panel to the stream.
            // PLAYBACK_RESTART fires per (re)load, so channel flips
            // re-evaluate. The perf-pump fallback below covers streams
            // where mpv reports 0 here.
            if fps > 0 { applyDisplayCriteriaIfNeeded(fps: fps) }
            #endif

            // Also grab initial volatile values.
            //
            // Stream Info "drops" = decoder drops + layer-late presents, NOT
            // mpv's frame-drop-count: on the render-API path that VO counter
            // overcounts wildly (ch 35 UHD 2026-08-07: ~120/15s with the
            // panel verified at 50Hz and the layer presenting 1 late frame
            // in 14400 - users read it as stutter that does not exist). The
            // raw VO counter stays visible in the MPV-PERF debug log.
            var cacheDur: Double = 0; var avsync: Double = 0; var drops: Int64 = 0; var bitrate: Double = 0
            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)
            mpv_get_property(mpv, "decoder-frame-drop-count", MPV_FORMAT_INT64, &drops)
            drops += lateFrameCount
            mpv_get_property(mpv, "demuxer-cache-state/raw-input-rate", MPV_FORMAT_DOUBLE, &bitrate)

            let info = StreamInfo(
                videoCodec: videoCodec,
                width: Int(videoW),
                height: Int(videoH),
                fps: fps,
                pixelFormat: pixelFormat,
                hwdec: hwdecCurrent,
                audioCodec: audioCodec,
                sampleRate: Int(sampleRate),
                channels: Int(channels),
                cacheDuration: cacheDur,
                bitrate: bitrate,
                droppedFrames: Int(drops),
                avsync: avsync
            )

            let ps = progressStore
            DispatchQueue.main.async { ps.streamInfo = info }
            return info
        }

        /// Refresh volatile stream info (cache, bitrate, drops, sync, fps).
        /// Called every 2s from the stream info timer on statsQueue.
        /// Skips the mpv property reads when the overlay is hidden to avoid
        /// lock contention with the render thread.
        private func refreshVolatileStreamInfo() {
            guard let mpv = self.activeMPVHandle(),
                  progressStore.isStreamInfoVisible else { return }
            var cacheDur: Double = 0; var avsync: Double = 0
            var drops: Int64 = 0; var bitrate: Double = 0; var fps: Double = 0
            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)
            // Viewer-meaningful drops (decoder + layer-late), not the
            // overcounting VO frame-drop-count - see the initial populate.
            mpv_get_property(mpv, "decoder-frame-drop-count", MPV_FORMAT_INT64, &drops)
            drops += lateFrameCount
            mpv_get_property(mpv, "demuxer-cache-state/raw-input-rate", MPV_FORMAT_DOUBLE, &bitrate)
            mpv_get_property(mpv, "estimated-vf-fps", MPV_FORMAT_DOUBLE, &fps)
            // v1.7.4.x: `vo=libmpv` can leave estimated-vf-fps at 0 even
            // when playback is healthy (Archie field test 09:01 Sky Sports
            // Football showed 0.00fps in the Stream Info box while real
            // intervals were a stable 18ms). Fall back to `detectedFps`
            // (which the perf-pump now derives from measured intervals
            // when mpv returns 0) so the readout reflects what the AVSBDL
            // is actually presenting at.
            if fps <= 0, self.detectedFps > 0 {
                fps = self.detectedFps
            }
            if fps > 0 { self.detectedFps = fps }

            let ps = progressStore
            DispatchQueue.main.async {
                ps.streamInfo.cacheDuration = cacheDur
                ps.streamInfo.bitrate = bitrate
                ps.streamInfo.droppedFrames = Int(drops)
                ps.streamInfo.avsync = avsync
                if fps > 0 { ps.streamInfo.fps = fps }
            }
        }

        /// Start the 2-second refresh timer for volatile stream info fields.
        /// Uses statsQueue (utility QoS) — never renderQueue — to avoid blocking frame delivery.
        private func startStreamInfoTimer() {
            streamInfoTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: statsQueue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                self?.refreshVolatileStreamInfo()
                // Task #183: while PAUSED the time-pos event stream is
                // silent (no stats ticks), so this always-running timer
                // carries the periodic catch-up position report - the
                // accepted report refreshes the session idle TTL, which
                // is what keeps a long-paused native session alive.
                // While playing, the time-pos tick reports instead. The
                // 20s throttle inside the hook keeps this 2s timer cheap.
                if let self, self.lastAppliedPause == true {
                    self.reportCatchupPositionIfDue(positionSecs: self.catchupLastKnownPositionSecs,
                                                    paused: true, force: false)
                }
            }
            timer.resume()
            streamInfoTimer = timer
        }

        /// Stop the stream info refresh timer.
        private func stopStreamInfoTimer() {
            streamInfoTimer?.cancel()
            streamInfoTimer = nil
        }

        private func getMPVString(_ mpv: OpaquePointer, _ name: String) -> String? {
            var cstr: UnsafeMutablePointer<CChar>?
            guard mpv_get_property(mpv, name, MPV_FORMAT_STRING, &cstr) >= 0, let cstr else { return nil }
            let result = String(cString: cstr)
            mpv_free(cstr)
            return result
        }

        private func mpvCommand(_ mpv: OpaquePointer, _ args: [String]) {
            let cargs = args.map { strdup($0) }
            var pointers = cargs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
            pointers.append(nil)
            let result = mpv_command(mpv, &pointers)
            for ptr in cargs { free(ptr) }
            #if DEBUG
            if result < 0 {
                debugLog("[MPV-ERR] command \(args) failed: \(String(cString: mpv_error_string(result)))")
            }
            #endif
        }

        /// Fire-and-forget variant. `mpv_command` (used by `mpvCommand`) is
        /// SYNCHRONOUS: it blocks the caller until the core services the
        /// command. When the core is parked in a blocking demuxer read (an
        /// in-progress HLS recording waiting for the next live segment), a
        /// synchronous command issued from the main thread freezes the UI for
        /// up to network-timeout seconds. `mpv_command_async` queues the
        /// command and returns immediately, so the main thread never blocks;
        /// the command is acted on whenever the core's read returns. Use this
        /// for teardown-path commands like `quit`. The reply event is ignored.
        ///
        /// ALSO used for every `seek` (resume, scrub, remote/lock-screen).
        /// Seeks are issued on `mpvQueue`, the same serial queue that
        /// `readEvents` drains mpv's bounded event queue on. A SYNCHRONOUS
        /// `mpv_command("seek")` there can deadlock: the core sets
        /// `seeking=yes`, then blocks trying to post events while our drain
        /// loop is parked inside the very same synchronous call, so the seek
        /// never completes (observed as `seeking=1`, `current-ao=nil`, frozen
        /// playback on a VOD/DVR resume). It is timing-sensitive, so it only
        /// surfaced in slower Debug builds. The async variant returns at once,
        /// the drain keeps running, and the core finishes the seek normally.
        /// No caller needs the seek to complete synchronously (the UI tracks
        /// `time-pos` via the property observers; PLAYBACK_RESTART fires when
        /// the seek lands).
        private func mpvCommandAsync(_ mpv: OpaquePointer, _ args: [String]) {
            let cargs = args.map { strdup($0) }
            var pointers = cargs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
            pointers.append(nil)
            let result = mpv_command_async(mpv, 0, &pointers)
            for ptr in cargs { free(ptr) }
            #if DEBUG
            if result < 0 {
                debugLog("[MPV-ERR] async command \(args) failed: \(String(cString: mpv_error_string(result)))")
            }
            #endif
        }

        private func checkError(_ status: CInt) {
            if status < 0 {
                #if DEBUG
                debugLog("[MPV-ERR] \(String(cString: mpv_error_string(status)))")
                #endif
            }
        }

        /// Wrapper around `mpv_set_option_string` that logs the
        /// failing option name + value when mpv rejects it. The bare
        /// `checkError(mpv_set_option_string(...))` path only logs
        /// "error setting option" with no context — when stacked
        /// against 20+ option calls in `setupMPV()` that turns an
        /// actionable diagnostic into a coin flip. Use this helper
        /// for any new option added so a silent mpv-rejection is
        /// immediately traceable to a specific key.
        @discardableResult
        private func setOption(_ mpv: OpaquePointer, _ name: String, _ value: String) -> CInt {
            let status = mpv_set_option_string(mpv, name, value)
            if status < 0 {
                #if DEBUG
                debugLog("[MPV-ERR] option \"\(name)\"=\"\(value)\" rejected: \(String(cString: mpv_error_string(status)))")
                #endif
            }
            return status
        }

        private func logOption(_ name: String, _ status: CInt) {
            #if DEBUG
            if status < 0 {
                debugLog("[MPV-OPT] ✗ \(name): \(String(cString: mpv_error_string(status)))")
            } else {
                debugLog("[MPV-OPT] ✓ \(name)")
            }
            #endif
        }

        // MARK: - PiP Delegate (AVPictureInPictureSampleBufferPlaybackDelegate)

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            setPlaying playing: Bool
        ) {
            guard let mpv else { return }
            var flag: Int = playing ? 0 : 1
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
            DispatchQueue.main.async { self.progressStore.isPaused = !playing }
        }

        func pictureInPictureControllerTimeRangeForPlayback(
            _ pictureInPictureController: AVPictureInPictureController
        ) -> CMTimeRange {
            // ALWAYS the infinite range, recordings included. Our sample
            // buffers are stamped with HOST-CLOCK presentation times
            // (CMClockGetTime in the render path), not media time, and the
            // layer has no controlTimebase. AVKit derives "current time"
            // from those PTS values, so against a finite [0, duration]
            // range the position reads as hours past the end and PiP
            // paints its indefinite loading spinner over the video
            // (recordings/VOD showed a gray tile with audio only; live
            // already returned infinite and rendered fine). The infinite
            // range tells AVKit not to model a timeline at all; frames
            // are display-immediately so presentation is unaffected.
            CMTimeRange(start: .negativeInfinity, end: .positiveInfinity)
        }

        func pictureInPictureControllerIsPlaybackPaused(
            _ pictureInPictureController: AVPictureInPictureController
        ) -> Bool {
            progressStore.isPaused
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            didTransitionToRenderSize newRenderSize: CMVideoDimensions
        ) {
            // No action needed — mpv scales internally
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            skipByInterval skipInterval: CMTime,
            completion completionHandler: @escaping () -> Void
        ) {
            let skipMs = Int32(CMTimeGetSeconds(skipInterval) * 1000)
            let newMs = progressStore.currentMs + skipMs
            progressStore.seekAction?(max(0, min(progressStore.durationMs, newMs)))
            completionHandler()
        }

        // MARK: - PiP Controller Delegate

        // NOTE (2026-04-21 rev 2): Reinstated
        // `restoreUserInterfaceForPictureInPictureStopWithCompletionHandler`.
        // The prior note (below, preserved for archaeology) concluded
        // removing the delegate fixed the placeholder — but the user
        // confirmed the placeholder+zoom bug persists in every shipped
        // build since PiP was introduced (commit 791d813, 2026-04-07).
        // Other mpv-backed iOS players using the same
        // AVSampleBufferDisplayLayer architecture DO produce a clean
        // restore, which means our root cause is different from what
        // the prior note diagnosed.
        //
        // Correct diagnosis (higher confidence):
        //   * When the user taps ⤢ maximize, iOS fires
        //     `willStop` → begins restore animation → fires `didStop`
        //     AFTER the animation completes.
        //   * Without `restoreUserInterface`, iOS treats our app as a
        //     "legacy" PiP adopter and uses a conservative restore
        //     pipeline that PAINTS THE GENERIC PLACEHOLDER ICON over
        //     the PiP window for the duration of the animation —
        //     because the framework has no signal that our source
        //     layer is ready to be re-hosted.
        //   * With `restoreUserInterface` implemented, iOS marks the
        //     app as a first-class adopter, coordinates the layer
        //     reparent with our `completionHandler` call, and skips
        //     the placeholder (Apple's sample-buffer PiP docs +
        //     Vonage / WebRTC PiP write-ups all converge on this).
        //
        // The prior failed attempts failed for orthogonal reasons:
        //  * Attempts 1–2 still async-wrote `isPiPActive=false` from
        //    `didStop`, which re-rendered SwiftUI DURING iOS's restore
        //    animation. iOS treats an in-flight view hierarchy change
        //    as "the app isn't ready" and falls back to placeholder.
        //  * Attempt 4 rebuilt the ContentSource, which obviously
        //    breaks the layer reparent mid-flight.
        //  * Attempt 3 added the stub `didStart` / `willStop` which
        //    was progress but not sufficient on its own.
        //
        // The working shape (this revision):
        //  (a) Move the `isPiPActive = false` write from `didStop` to
        //      `willStop`, and make it SYNCHRONOUS. `willStop` fires
        //      BEFORE iOS starts the restore animation, giving SwiftUI
        //      time to settle its re-render before iOS begins
        //      compositing the source layer back in.
        //  (b) Implement `restoreUserInterface…` with a synchronous
        //      `completionHandler(true)` and NO UI work inside the
        //      delegate body. The method's mere presence + synchronous
        //      completion is the signal iOS needs.
        //  (c) Keep `didStop` as a diagnostic log only — the flag is
        //      already cleared, and writing it again would re-trigger
        //      the SwiftUI re-render that we just finished avoiding.
        //
        // If this regresses again, capture a sysdiagnose during the
        // maximize tap — the `mediaserverd` logs under
        // AVPictureInPictureController will show whether iOS is
        // classifying us as a first-class adopter. Missing
        // `restoreUserInterface` shows up as
        // `pip: falling back to placeholder (no UI restore delegate)`.

        /// Fires before iOS tears down the PiP window and BEFORE the
        /// restore animation begins. This is the correct place to
        /// flip `isPiPActive = false` synchronously: SwiftUI re-renders
        /// immediately, settles, and by the time iOS begins compositing
        /// the source layer back in, the view hierarchy is stable.
        ///
        /// Previously this flag was cleared asynchronously from
        /// `didStop` — which fires AFTER the restore animation — so
        /// the SwiftUI re-render landed mid-animation and iOS fell
        /// back to the placeholder icon + zoom.
        func pictureInPictureControllerWillStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            debugLog("🖼️ PiP: will stop")
            // Freeze the last-displayed frame on the sample-buffer
            // layer for the duration of iOS's restore animation.
            // Without this, the renderer keeps draining its queue
            // during the transition — iOS then has to animate
            // against a moving target and falls back to showing its
            // generic PiP-icon placeholder over the window. The
            // `removingDisplayedImage: false` variant preserves
            // whatever frame is currently on screen so the restore
            // animates "current frame in PiP window" → "same
            // current frame at fullscreen rect", which is the
            // visually clean path. Cited in AVFoundation dev-forum
            // field reports as the standard fix for the "PiP icon
            // flash on maximize" symptom on custom sample-buffer
            // adopters.
            MainActor.assumeIsolated {
                if let vc = viewController {
                    vc.sampleBufferLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
                    #if DEBUG
                    debugLog("[MPV-PIP] willStop: flushed sampleBufferRenderer (kept displayed image)")
                    #endif
                }
            }
            // Clear the active flag SYNCHRONOUSLY here, not
            // asynchronously from `didStop`. See the multi-paragraph
            // note above this function for the full rationale.
            progressStore.isPiPActive = false
            let myTileID = tileID
            if let myTileID {
                // MultiviewStore is @MainActor-isolated; we're already on
                // the main thread inside a PiP delegate callback, so
                // assumeIsolated is safe and keeps the write synchronous.
                MainActor.assumeIsolated {
                    MultiviewStore.shared.isPiPActive = false
                    DebugLogger.shared.log(
                        "[MV-PiP] ended tile=\(myTileID)",
                        category: "Playback", level: .info
                    )
                }
            }
        }

        /// The critical delegate for a clean restore animation. Apple's
        /// AVFoundation sample-buffer PiP docs explicitly require this
        /// method for apps that want iOS to animate the PiP window
        /// back into the source layer cleanly. Without it, iOS treats
        /// the app as a legacy adopter and paints a generic PiP icon
        /// placeholder over the window during the animation.
        ///
        /// The body MUST be a synchronous `completionHandler(true)`
        /// with NO UI work. Any UI mutation, layout pass, view
        /// controller presentation, or async hop here makes iOS wait
        /// on the completion handler, and while it waits it paints
        /// the placeholder. `willStop` already handled the only state
        /// transition we need (clearing `isPiPActive`), so this
        /// delegate is intentionally empty.
        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                completionHandler: @escaping (Bool) -> Void
        ) {
            debugLog("🖼️ PiP: restore UI")
            // Synchronous completion. No layout, no state writes, no
            // async hops. The source view is already in its restored
            // position (it never moved during PiP — iOS merely
            // reparented the layer), and `willStop` already cleared
            // `isPiPActive`, so there's nothing for us to do except
            // tell iOS we're ready.
            completionHandler(true)
        }

        /// Diagnostic hook for PiP-start failures. Purely logging —
        /// doesn't change behaviour — but when PiP silently refuses to
        /// start (AirPlay active, audio session category mismatch,
        /// backgrounded before layer became ready) this is the only
        /// callback AVFoundation gives us. Prior to this we had no
        /// visibility into start failures at all.
        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            #if DEBUG
            debugLog("[MPV-PIP] failedToStart: \(error.localizedDescription) (\(error as NSError))")
            #endif
        }

        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            debugLog("🖼️ PiP: starting")
            // Set `progressStore.isPiPActive = true` on the NEXT runloop
            // tick, NOT synchronously. `isPiPActive` is `@Published`, so a
            // synchronous write in here fires `objectWillChange` inside
            // the `willStart` delegate callback — which triggers a SwiftUI
            // re-render while iOS is mid-PiP-engagement-animation. iOS
            // observes the source view hierarchy moving during its own
            // transition and falls back to the generic placeholder-icon
            // restore animation (the "zoom + PiP icon" regression users
            // reported on iOS 26.5).
            //
            // The prior sync-write was introduced to make
            // `didEnterBackground`'s PiP branch read the flag before
            // `vid=no` could fire. That race is now covered by the
            // `pipAutoEligible` flag (set at controller-creation time,
            // checked by `didEnterBackground` branch (1.5) BEFORE any
            // `isPiPActive` read), so we don't need the sync write
            // anymore — the async hop is safe.
            DispatchQueue.main.async { [weak self] in
                self?.progressStore.isPiPActive = true
            }
            // Multiview: tell the store PiP has engaged so non-audio
            // tiles can pause themselves. Only the audio tile can
            // start PiP (PiP button is only exposed on the audio
            // tile's controls), so if we got here with tileID != nil
            // we ARE the audio tile. `MultiviewStore.isPiPActive` is
            // @MainActor so we hop through a Task.
            //
            // Defensive: only write when we're still a live tile in
            // the store. Between coordinator dismantle and this
            // delegate firing, `PlayerSession.exit()` may have run
            // `MultiviewStore.reset()` — in that case the tile is
            // gone and the store's isPiPActive is already false;
            // writing `true` here would leak the flag into the next
            // multiview session.
            let myTileID = tileID
            if myTileID != nil {
                Task { @MainActor in
                    guard let id = myTileID,
                          // Also gate on mode — a tile's id pinning to
                          // `item.id` means the same id CAN exist in a
                          // brand-new multiview session. Without the
                          // mode check, a late-firing PiP delegate
                          // could set `isPiPActive = true` on a new
                          // session that never actually engaged PiP.
                          PlayerSession.shared.mode == .multiview,
                          MultiviewStore.shared.tiles.contains(where: { $0.id == id })
                    else { return }
                    MultiviewStore.shared.isPiPActive = true
                    DebugLogger.shared.log(
                        "[MV-PiP] engaged by audio tile=\(id)",
                        category: "Playback", level: .info
                    )
                }
            }
        }

        /// Required by Apple's documented PiP adoption pattern — every
        /// Apple sample (AVFoundationPiPPlayer, AdoptingPictureInPicture,
        /// createwithswift.com, Vonage reference) implements this hook
        /// even when the body is empty. Our prior implementation only
        /// had `willStart`, and AVF's internal state-machine treats a
        /// missing `didStart` as "the app is not a fully adopted PiP
        /// participant" — which can tip heuristics toward the generic
        /// placeholder-icon restore animation. Keeping the body
        /// minimal (just a log) matches Apple's sample pattern.
        func pictureInPictureControllerDidStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            debugLog("🖼️ PiP: did start")
        }

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            debugLog("🖼️ PiP: stopped")
            // INTENTIONALLY does no state writes. `willStop` + the
            // `restoreUserInterface…` completion handler have already
            // handed control back to the app cleanly; writing
            // `isPiPActive` again from here (even async) would fire
            // `objectWillChange` AFTER iOS has just finished its
            // restore animation, causing a one-frame SwiftUI reflow
            // that can pop the overlay controls back into a different
            // position than the pre-PiP layout. Kept as a log-only
            // hook so the next person debugging PiP has symmetry with
            // `didStart`.
        }
    }
}
#endif // canImport(Libmpv)
