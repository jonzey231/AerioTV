#if canImport(Libmpv)
import SwiftUI
import AVFoundation
import AVKit
import Combine
import UIKit
import Libmpv
import CoreVideo
import CoreMedia  // For CMSampleBuffer
import OpenGLES

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

        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + 0.8) {
                doWarmUp()
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

    private static func doWarmUp() {
        let totalStart = Date()
        // v1.6.15: capture thermal state at warmup entry so we can
        // tell, from a stutter report, whether the device was
        // already cooking when the user opened the app vs. whether
        // playback itself heated it up. Resume Last Channel + warmup
        // both fire near launch and compete for the same CPU/GPU
        // budget; on a hot device that's been observed to produce
        // brief audio/video stutters during the first ~10s of
        // playback. The MultiviewStore observer covers state
        // transitions DURING playback; this captures the "starting
        // point" before that observer is even mounted.
        let thermalAtStart = thermalStateString(ProcessInfo.processInfo.thermalState)

        // ── Phase 1: libmpv ────────────────────────────────────────
        let mpvStart = Date()
        guard let mpv = mpv_create() else {
            #if DEBUG
            debugLog("[MPV-WARMUP] mpv_create failed — warm-up skipped (thermal=\(thermalAtStart))")
            #endif
            return
        }

        // Match `Coordinator.setupMPV()` generic options as closely
        // as possible without hitting per-stream config. The goal
        // is to trigger the same libmpv init codepath real
        // playback uses: videotoolbox hwdec registration, libmpv
        // vo init, fast-profile filter chain load. v1.7.x: hwdec
        // default is now videotoolbox-copy (was videotoolbox); see
        // the rationale block above the matching call in setupMPV.
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "profile", "fast")
        #if !targetEnvironment(simulator)
        mpv_set_option_string(mpv, "hwdec", "videotoolbox-copy")
        #endif

        let initResult = mpv_initialize(mpv)

        // Destroy immediately — we don't need the handle, just the
        // side effects of initialize. `terminate_destroy` is
        // synchronous; no event-loop stragglers.
        mpv_terminate_destroy(mpv)
        let mpvMs = Int(Date().timeIntervalSince(mpvStart) * 1000)

        // ── Phase 2: OpenGL ES driver ──────────────────────────────
        // On a fresh app install, the FIRST `EAGLContext(api:)` call
        // in the process pays a ~2 s one-time cost while tvOS pages
        // the OpenGL ES driver in from disk. Per-phase timing inside
        // `setupMPV` confirmed this: cold first tile shows
        // `EAGLContext_create: 2053ms`, subsequent tiles ~11 ms.
        //
        // The fix is the same pattern as the mpv warm-up: create a
        // throwaway EAGLContext + texture cache during launch, discard
        // immediately, let the driver load amortise during idle
        // startup time instead of during the user's first channel
        // tap. Subsequent real EAGLContext creations in
        // `Coordinator.setupMPV` hit the warm path.
        //
        // Simulator skips — the simulator GLES path uses a different
        // software renderer that doesn't share this cost and the
        // CVOpenGLESTextureCacheCreate call is a no-op there.
        let eaglStart = Date()
        #if !targetEnvironment(simulator)
        if let ctx = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) {
            EAGLContext.setCurrent(ctx)
            var cache: CVOpenGLESTextureCache?
            CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, ctx, nil, &cache)
            // `cache` retained through scope end then released —
            // we just need the first-time driver allocation to
            // happen. The real cache is built per-Coordinator.
            _ = cache
            EAGLContext.setCurrent(nil)
        }
        #endif
        let eaglMs = Int(Date().timeIntervalSince(eaglStart) * 1000)

        isComplete = true

        #if DEBUG
        let totalMs = Int(Date().timeIntervalSince(totalStart) * 1000)
        // Sample thermal again at completion. If the state moved
        // during warmup (entry=fair, exit=serious) that itself is a
        // signal — the warmup pushed the device hotter, which then
        // bites the auto-resume that's about to start a stream.
        let thermalAtEnd = thermalStateString(ProcessInfo.processInfo.thermalState)
        if initResult < 0 {
            let err = String(cString: mpv_error_string(initResult))
            debugLog("[MPV-WARMUP] done in \(totalMs)ms (mpv=\(mpvMs)ms, eagl=\(eaglMs)ms, thermal=\(thermalAtStart)→\(thermalAtEnd)) — initialize returned error: \(err)")
        } else {
            debugLog("[MPV-WARMUP] process-wide init complete in \(totalMs)ms (mpv=\(mpvMs)ms, eagl=\(eaglMs)ms, thermal=\(thermalAtStart)→\(thermalAtEnd)) — first channel tap will hit the warm path")
        }
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
    let nowPlayingTitle: String
    let nowPlayingSubtitle: String?
    let nowPlayingArtworkURL: URL?
    var progressStore: PlayerProgressStore
    var logStore: AttemptLogStore
    let onFatalError: @MainActor @Sendable (String) -> Void
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
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.activeMPVHandle() else { return }
                self.mpvCommand(mpv, ["loadfile", newURL.absoluteString, "replace"])
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
            }
            DebugLogger.shared.log(
                "[MV-PiP] mpv pause=\(paused) tile=\(tileID ?? "single")",
                category: "MPV-STREAM", level: .info
            )
            setMPVFlag(property: "pause", value: paused)

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
            if wasPaused && !paused && isLive, !urls.isEmpty {
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
        /// etc.). Reset on play(url:) so the next stream re-evaluates.
        private var hdrToneMappingApplied = false

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
            var isInBackground = false
            var autoPausedOnBackground = false
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
            withPlaybackStateLock { state in
                guard !state.isShuttingDown else { return nil }
                state.isShuttingDown = true
                return state.mpv
            }
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
            withPlaybackStateLock { $0.hwdecFallbackApplied = false }
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
        // 3-second threshold: shorter than the 5s the user manually
        // gave up at, long enough that natural cache underruns on a
        // weak network do not falsely trigger. Gated by !paused so a
        // user pause does not get force-reloaded.
        private let staleFrameStormThresholdSec: CFTimeInterval = 3.0

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
        //   30fps. That is short enough to feel like a "blip" instead
        //   of a freeze, long enough that an isolated 1-2 black frame
        //   from a real channel cut to commercial does NOT trip it.
        // - 5 second reload cooldown = avoids hammering the proxy if
        //   the storm is sourced upstream.
        private var consecutiveBlackFramesSuppressed: Int = 0
        private var lastForcedBlackReloadAt: CFAbsoluteTime = 0
        private let blackFrameStormThreshold: Int = 30
        private let blackFrameReloadCooldownSec: CFAbsoluteTime = 5.0

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

            // Seek closure: VOD + DVR. Live TV has no seekable timeline.
            // Runs on mpvQueue (off main) so a scrub never blocks the UI when
            // the core is stalled; this also puts playbackEnded access on the
            // same queue as the EOF event handler that sets it.
            progressStore.seekAction = { [weak self] targetMs in
                guard let self, !self.isLive else { return }
                self.mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.activeMPVHandle() else { return }
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

            // Background/foreground handling — disable video output to prevent GPU crashes
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                                   name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                                   name: UIApplication.willEnterForegroundNotification, object: nil)
            // Audio route change — log AirPlay connect/disconnect
            NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged),
                                                   name: AVAudioSession.routeChangeNotification, object: nil)

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
                if !carPlayConnected {
                    mpv_set_property_string(mpv, "vid", "auto")
                }
            }
            mpv_free(vid)

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
                    if fpsVal > 0 { detectedFps = fpsVal }
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
            if staleAge >= staleFrameStormThresholdSec, lastAppliedPause != true {
                let wallNow = CFAbsoluteTimeGetCurrent()
                if wallNow - lastForcedBlackReloadAt >= blackFrameReloadCooldownSec,
                   let reloadURL = urls.first {
                    lastForcedBlackReloadAt = wallNow
                    let safeURL = DebugLogger.sanitize(reloadURL.absoluteString)
                    debugLog("[STALE-RELOAD] \(streamTag) stale=\(String(format: "%.0f", staleAge * 1000))ms >= threshold=\(String(format: "%.0f", staleFrameStormThresholdSec * 1000))ms; issuing loadfile replace to re-prime pipeline (url=\(safeURL.prefix(80)))")
                    DebugLogger.shared.log(
                        "🟡 [MPV-RELOAD] stale-frame storm reload tile=\(tileID ?? "single") stale_ms=\(Int(staleAge * 1000))",
                        category: "MPV-STREAM", level: .warning
                    )
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.activeMPVHandle() else { return }
                        self.mpvCommand(mpv, ["loadfile", reloadURL.absoluteString, "replace"])
                    }
                }
            }
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
               let renderer = sampleBufferLayer?.sampleBufferRenderer,
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
            let layerReady = sampleBufferLayer?.sampleBufferRenderer.isReadyForMoreMediaData ?? false
            let layerStatus = sampleBufferLayer?.sampleBufferRenderer.status

            // v1.7.x Issue A round 3: log AVSBDL state transitions so
            // the next test log shows whether the layer is internally
            // clearing or flagging requiresFlush during the libmpv
            // render stalls (Archie's screen recording showed
            // single-VSync black flashes that we believe correspond
            // to layer-side auto-clear behavior, not anything mpv-
            // side). Logged on transition only, so smooth playback
            // produces zero noise.
            if let layer = sampleBufferLayer {
                let currentStatus = layer.sampleBufferRenderer.status
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
                let currentFlush = layer.sampleBufferRenderer.requiresFlushToResumeDecoding
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
                        let err = sampleBufferLayer?.sampleBufferRenderer.error?.localizedDescription ?? "nil"
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
                // v1.7.x storm reload: if libmpv has been emitting
                // all-zero frames for blackFrameStormThreshold in a
                // row, its video pipeline is wedged - the upstream
                // audio reconfig / decoder re-prime case from the
                // 2026-06-06 field test produced ~367 consecutive
                // black frames over 7s with no spontaneous recovery.
                // A single `loadfile <currentURL> replace` re-primes
                // the demuxer + decoder against the same URL and the
                // stream resumes within ~1s. Cooldown prevents repeat
                // hits when the source is genuinely dark or the
                // proxy keeps producing the same broken bytes.
                if consecutiveBlackFramesSuppressed == blackFrameStormThreshold {
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastForcedBlackReloadAt >= blackFrameReloadCooldownSec,
                       let reloadURL = urls.first {
                        lastForcedBlackReloadAt = now
                        let safeURL = DebugLogger.sanitize(reloadURL.absoluteString)
                        debugLog("[BLACK-RELOAD] \(streamTag) consecutive=\(consecutiveBlackFramesSuppressed) >= threshold=\(blackFrameStormThreshold); issuing loadfile replace to re-prime pipeline (url=\(safeURL.prefix(80)))")
                        DebugLogger.shared.log(
                            "🟡 [MPV-RELOAD] black-frame storm reload tile=\(tileID ?? "single") consec=\(consecutiveBlackFramesSuppressed)",
                            category: "MPV-STREAM", level: .warning
                        )
                        mpvQueue.async { [weak self] in
                            guard let self, let mpv = self.activeMPVHandle() else { return }
                            self.mpvCommand(mpv, ["loadfile", reloadURL.absoluteString, "replace"])
                        }
                    }
                }
                // Note: we deliberately do NOT update the prev/prev-
                // prev luma history with the suppressed frame. The
                // surround check on the NEXT frame still compares
                // against the last GOOD frame's luma, so a sustained
                // codec-zero burst (rare but possible) would only
                // suppress the first frame, not subsequent ones —
                // which is correct: if the source actually went
                // dark, we want frames after the first to update
                // the comparison baseline.
            } else if let sampleBuffer = Self.makeSampleBuffer(from: renderPixelBuffer, presentationTime: presentationTime) {
                nonisolated(unsafe) let sb = sampleBuffer
                sampleBufferLayer?.sampleBufferRenderer.enqueue(sb)
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

            if layerStatus == .failed, let err = sampleBufferLayer?.sampleBufferRenderer.error {
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

        func stop() {
            let mpvToStop = markShuttingDownAndSnapshotMPV()
            stopStreamInfoTimer()
            DebugLogger.shared.logPlayback(event: "Stop",
                                           url: urls[safe: currentIndex]?.absoluteString)

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
            checkError(mpv_set_option_string(mpv, "hwdec-software-fallback", "90"))
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
            checkError(mpv_set_option_string(mpv, "cache-pause-wait", isLive ? "0" : "1"))

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
                setOption(mpv, "cache-pause-initial", "no")
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
                let ms = isLive
                    ? max(userPrefMs, liveMinMs)
                    : max(userPrefMs, vodMinMs)
                return Double(ms) / 1000.0
            }()

            mpv_set_property_string(mpv, "cache", "yes")
            mpv_set_property_string(mpv, "demuxer-readahead-secs", String(format: "%.1f", cachingSecs))

            if isLive {
                // Live: small demuxer buffer prevents A-V desync from runaway video queues.
                // 50MiB was far too large — video piled up 4000+ packets while audio starved.
                mpv_set_property_string(mpv, "demuxer-max-bytes", "8MiB")
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

        private func play(url: URL) {
            guard let mpv = activeMPVHandle() else { return }

            hasStarted = false
            playbackStartTime = nil
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
                        // Now that initial buffer is filled, disable cache-pause for live
                        // so playback doesn't stall on brief network dips.
                        if self.isLive, let mpv = self.activeMPVHandle() {
                            mpv_set_property_string(mpv, "cache-pause", "no")
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
            #if DEBUG
            debugLog("[MPV-DIAG] State: opening (start-file)")
            #endif
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
                                onPlay:  { ps2.togglePauseAction?() },
                                onPause: { ps2.togglePauseAction?() },
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
                    let retryURL = urls[currentIndex]
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
                    lastHwdecCurrentObserved = value
                }

            case "pause":
                if prop.format == MPV_FORMAT_FLAG, let data = prop.data {
                    let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
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
                if prop.format == MPV_FORMAT_DOUBLE, let data = prop.data, !isLive {
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

                    // Throttle UI updates
                    let now = Date()
                    if !isLive, now.timeIntervalSince(lastProgressUpdate) >= 1.0 {
                        lastProgressUpdate = now
                        let ps = progressStore
                        DispatchQueue.main.async { ps.currentMs = ms }
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
            if let layer = sampleBufferLayer {
                if layer.sampleBufferRenderer.status == .failed {
                    layerStatus = "FAILED: \(layer.sampleBufferRenderer.error?.localizedDescription ?? "?")"
                } else if layer.sampleBufferRenderer.isReadyForMoreMediaData == false {
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

            // Also grab initial volatile values
            var cacheDur: Double = 0; var avsync: Double = 0; var drops: Int64 = 0; var bitrate: Double = 0
            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)
            mpv_get_property(mpv, "frame-drop-count", MPV_FORMAT_INT64, &drops)
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
            mpv_get_property(mpv, "frame-drop-count", MPV_FORMAT_INT64, &drops)
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
            // Live streams have no defined range
            if isLive { return CMTimeRange(start: .negativeInfinity, end: .positiveInfinity) }
            let duration = CMTime(value: Int64(progressStore.durationMs), timescale: 1000)
            return CMTimeRange(start: .zero, duration: duration)
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
