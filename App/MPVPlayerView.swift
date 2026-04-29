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
    static func warmUp() {
        guard !hasStarted else { return }
        hasStarted = true

        DispatchQueue.global(qos: .userInitiated).async {
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
            print("[MPV-WARMUP] mpv_create failed — warm-up skipped (thermal=\(thermalAtStart))")
            #endif
            return
        }

        // Match `Coordinator.setupMPV()` generic options as closely
        // as possible without hitting per-stream config. The goal
        // is to trigger the same libmpv init codepath real
        // playback uses: videotoolbox hwdec registration, libmpv
        // vo init, fast-profile filter chain load.
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "profile", "fast")
        #if !targetEnvironment(simulator)
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
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
            print("[MPV-WARMUP] done in \(totalMs)ms (mpv=\(mpvMs)ms, eagl=\(eaglMs)ms, thermal=\(thermalAtStart)→\(thermalAtEnd)) — initialize returned error: \(err)")
        } else {
            print("[MPV-WARMUP] process-wide init complete in \(totalMs)ms (mpv=\(mpvMs)ms, eagl=\(eaglMs)ms, thermal=\(thermalAtStart)→\(thermalAtEnd)) — first channel tap will hit the warm path")
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

        // AVSampleBufferDisplayLayer for vsync-synchronized presentation (both platforms).
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.frame = view.bounds
        view.layer.addSublayer(sampleBufferLayer)

        // PiP controller is NOT created here — see `ensurePiPController()`
        // above for the lazy-init rationale.

        #if DEBUG
        print("[MPV-DIAG] viewDidLoad: frame=\(view.frame), inWindow=\(view.window != nil)")
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

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(urls: urls, headers: headers, isLive: isLive,
                            progressStore: progressStore, logStore: logStore,
                            onFatalError: onFatalError,
                            tileID: tileID,
                            initialIsAudioActive: isAudioActive,
                            initialShouldPause: shouldPause)
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
            print("[MPV-PIP] makeUIViewController: tileID=\(tileID ?? "single") coord=\(ObjectIdentifier(context.coordinator)) audioOnly=\(context.coordinator.progressStore.isAudioOnly)")
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
            // NOTE: no PiP wiring here. Multiview tiles do NOT
            // auto-PiP on background (eager-creating
            // AVPictureInPictureController during a multi-tile
            // mount reproducibly freezes the app). The manual PiP
            // menu item was also removed — PiP is auto-only.
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

        /// Set true when `didEnterBackground` paused mpv because the
        /// user hadn't opted into any background-audio mode (no PiP,
        /// no Audio-Only, no AirPlay). `willEnterForeground` consults
        /// this to know whether it owns the `pause=0` write, without
        /// clobbering a user-initiated pause from the play/pause
        /// button.
        fileprivate var autoPausedOnBackground: Bool = false

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
        fileprivate var isInBackground: Bool = false

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
        private static let snapToLiveMinPauseSeconds: TimeInterval = 2.0

        /// Called from `updateUIViewController`. Sends `mute=0` when
        /// the tile becomes audio-active, `mute=1` otherwise. No-op
        /// when the incoming value matches the last applied.
        @MainActor
        fileprivate func applyAudioFocusIfChanged(_ isActive: Bool) {
            guard lastAppliedAudioFocus != isActive else { return }
            // N=1 short-circuit: at a single tile there is no audio-focus
            // competition — the one tile is always the audio tile, and
            // the mpv options `aid=auto` + `mute=no` were set at setup.
            // SwiftUI still fires `updateUIViewController` on every state
            // change, which re-calls this path with `isActive=true` each
            // time; the redundant mpvQueue dispatch + AudioUnit reconfig
            // shows up in the hot path as wasted work that isn't moving
            // audio anywhere. Record the state so when a 2nd tile arrives
            // and genuine audio-focus transitions begin, the debounce
            // guard above has the right baseline. Skip the mpv write.
            if MultiviewStore.shared.tiles.count <= 1 {
                lastAppliedAudioFocus = isActive
                return
            }
            lastAppliedAudioFocus = isActive
            DebugLogger.shared.log(
                "[MV-Audio] mpv audio=\(isActive ? "on" : "off") tile=\(tileID ?? "single")",
                category: "MPV-STREAM", level: .info
            )
            // Two-layer silence for non-audio tiles:
            //   - `aid=no`  : disable audio track entirely. mpv
            //                 stops decoding audio and closes the
            //                 AudioUnit. This is the fix for
            //                 "Audio device underrun" spam across
            //                 N concurrent muted tiles — each
            //                 muted tile was still opening its own
            //                 AO and fighting the shared
            //                 AVAudioSession, producing periodic
            //                 underruns that cascaded into 2-7s
            //                 video stalls.
            //   - `mute=yes`: belt-and-suspenders in case the aid
            //                 change races an in-flight audio
            //                 packet. Keeping both ensures the
            //                 user never hears a non-audio tile
            //                 even during the 50ms switchover.
            //
            // On audio-focus ACQUIRE we do the inverse: aid=auto
            // (re-runs mpv's track selection so the preferred
            // audio track plays) + mute=no.
            //
            // v1.6.12: each `mpv_set_property*` call is now gated on
            // a per-property cache (`lastWrittenAID` /
            // `lastWrittenMute`) so even if the outer
            // `lastAppliedAudioFocus` guard somehow lets a duplicate
            // through (Coordinator rebuild edge case, SwiftUI
            // re-entrancy), we never re-write the same value to mpv
            // — re-writing `aid=auto` re-runs track selection and
            // tears down + re-opens the AudioUnit, which is the
            // audible "bonk" users heard during tile rearrange.
            let targetAID  = isActive ? "auto" : "no"
            let targetMute: Int32 = isActive ? 0 : 1
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.mpv, !self.isShuttingDown else { return }
                if self.lastWrittenAID != targetAID {
                    mpv_set_property_string(mpv, "aid", targetAID)
                    self.lastWrittenAID = targetAID
                }
                if self.lastWrittenMute != targetMute {
                    var flag = targetMute
                    mpv_set_property(mpv, "mute", MPV_FORMAT_FLAG, &flag)
                    self.lastWrittenMute = targetMute
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
                    print("[MPV-DIAG] \(streamTag) unpause after \(String(format: "%.2f", dwell))s — skipping snap-to-live (brief pause, cache still fresh)")
                    #endif
                } else {
                    let url = urls[currentIndex]
                    #if DEBUG
                    print("[MPV-DIAG] \(streamTag) unpause → reload live stream (snap to live edge, dwell=\(String(format: "%.1f", dwell))s)")
                    #endif
                    logStore.append("↻ MPV: unpause live → snap to live edge")
                    mpvQueue.async { [weak self] in
                        guard let self, let mpv = self.mpv, !self.isShuttingDown else { return }
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
                guard let self, let mpv = self.mpv, !self.isShuttingDown else { return }
                var flag: Int32 = value ? 1 : 0
                mpv_set_property(mpv, property, MPV_FORMAT_FLAG, &flag)
            }
        }

        // mpv handles
        private var mpv: OpaquePointer?
        private var mpvGL: OpaquePointer?  // mpv_render_context (OpenGL render API)
        private let mpvQueue = DispatchQueue(label: "com.aerio.mpv", qos: .userInteractive)
        private var wakeupRetain: Unmanaged<Coordinator>?  // Balances passRetained in setupMPV

        // OpenGL ES render — GPU renders to CVPixelBuffer via IOSurface-backed FBO (zero copy)
        private let renderQueue = DispatchQueue(label: "com.aerio.mpv.render", qos: .userInteractive)
        private weak var sampleBufferLayer: AVSampleBufferDisplayLayer?  // vsync-synchronized display
        private var eaglContext: EAGLContext?
        private var textureCache: CVOpenGLESTextureCache?
        private var renderPixelBuffer: CVPixelBuffer?   // IOSurface-backed, reused per resolution
        private var renderTexture: CVOpenGLESTexture?    // GL texture wrapping the pixel buffer
        private var fbo: GLuint = 0                      // FBO with texture as color attachment
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
        private let maxLoadFailureRetries = 3
        private var isShuttingDown = false
        private var hwdecFallbackApplied = false  // Prevents repeated fallback attempts for 10-bit streams

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

        init(urls: [URL], headers: [String: String], isLive: Bool,
             progressStore: PlayerProgressStore,
             logStore: AttemptLogStore,
             onFatalError: @escaping @MainActor @Sendable (String) -> Void,
             tileID: String? = nil,
             initialIsAudioActive: Bool = true,
             initialShouldPause: Bool = false) {
            self.urls = urls
            self.headers = headers
            self.isLive = isLive
            self.progressStore = progressStore
            self.logStore = logStore
            self.onFatalError = onFatalError
            self.tileID = tileID
            self.initialIsAudioActive = initialIsAudioActive
            self.initialShouldPause = initialShouldPause
            // Seed the `lastApplied*` debounce with the initial
            // values — setupMPV applies them via mpv_set_option
            // BEFORE mpv_initialize, so there's no need for
            // updateUIViewController to re-issue them afterwards.
            // (Subsequent state changes via the Representable still
            // go through applyXxxIfChanged and flip mpv properties.)
            self.lastAppliedAudioFocus = initialIsAudioActive
            self.lastAppliedPause = initialShouldPause
            super.init()

            // Toggle play/pause
            progressStore.togglePauseAction = { [weak self] in
                guard let self, let mpv = self.mpv else { return }
                var flag: Int = 0
                mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
                var newFlag: Int = flag == 0 ? 1 : 0
                mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &newFlag)
            }

            // Seek closure — VOD only. Guards against seek-after-EOF.
            progressStore.seekAction = { [weak self] targetMs in
                guard let self, !self.isLive, !self.playbackEnded, let mpv = self.mpv else { return }
                let secs = String(format: "%.3f", Double(targetMs) / 1000.0)
                self.mpvCommand(mpv, ["seek", secs, "absolute"])
            }

            // Playback speed
            progressStore.setSpeedAction = { [weak self] speed in
                guard let self, let mpv = self.mpv else { return }
                mpv_set_property_string(mpv, "speed", String(format: "%.2f", speed))
                DispatchQueue.main.async { self.progressStore.speed = speed }
            }

            // Audio track selection (0 = auto)
            progressStore.setAudioTrackAction = { [weak self] trackID in
                guard let self, let mpv = self.mpv else { return }
                mpv_set_property_string(mpv, "aid", trackID == 0 ? "auto" : "\(trackID)")
                DispatchQueue.main.async { self.progressStore.currentAudioTrackID = trackID }
            }

            // Subtitle track selection (0 = off)
            progressStore.setSubtitleTrackAction = { [weak self] trackID in
                guard let self, let mpv = self.mpv else { return }
                mpv_set_property_string(mpv, "sid", trackID == 0 ? "no" : "\(trackID)")
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
                        print("[MPV-PIP] isAudioOnly sink fired: newValue=\(newValue) coord=\(ObjectIdentifier(self))")
                    } else {
                        print("[MPV-PIP] isAudioOnly sink fired: newValue=\(newValue) coord=<deallocated>")
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
                print("[MPV-PIP] updateAutoPiPEligibility: viewController=nil audioOnly=\(audioOnly) — deferred (VC not wired yet)")
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
                    print("[MPV-PIP] updateAutoPiPEligibility: audioOnly=true → tore down PiP controller")
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
                        print("[MPV-PIP] updateAutoPiPEligibility: audioOnly=false → armed pip=\(ObjectIdentifier(pip)) pipAutoEligible=true")
                    } else {
                        print("[MPV-PIP] updateAutoPiPEligibility: audioOnly=false → PiP unsupported on this device")
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
            if !isLive, let mpv {
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
            print("[MPV-PIP] reassertNowPlayingBridge: title=\"\(title)\" live=\(live)")
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
                    guard let self, let mpv = self.mpv else { return }
                    let secs = String(format: "%.3f", time)
                    self.mpvCommand(mpv, ["seek", secs, "absolute"])
                }
            )
        }
        #endif

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func didEnterBackground() {
            guard let mpv else { return }
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
                print("[MPV-BG] Background: PiP active, keeping vid+audio")
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
                print("[MPV-BG] Background: auto-PiP eligible, keeping vid live")
                #endif
                return
            }
            #if DEBUG
            if pipAutoEligible, multiviewActive {
                print("[MPV-BG] Background: pipAutoEligible=true but multiview tiles=\(multiviewTileCount) — falling through to default pause-on-background path")
            }
            #endif

            // (2) Audio-Only mode. Kill video, keep audio + Dynamic Island /
            //     lockscreen via NowPlayingBridge.
            if progressStore.isAudioOnly {
                #if DEBUG
                print("[MPV-BG] Background: audio-only, vid=no, audio continues (lockscreen + Dynamic Island)")
                #endif
                mpv_set_property_string(mpv, "vid", "no")
                return
            }

            // (3) AirPlay route.
            let route = AVAudioSession.sharedInstance().currentRoute
            let airPlayAudio = route.outputs.contains(where: { $0.portType == .airPlay })

            #if DEBUG
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            print("[MPV-BG] Background: airPlayAudio=\(airPlayAudio), isPiP=\(progressStore.isPiPActive), audioOnly=\(progressStore.isAudioOnly), outputs=[\(outputs)]")
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
            autoPausedOnBackground = true
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.mpv, !self.isShuttingDown else { return }
                var flag: Int32 = 1
                mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
            }
        }

        @objc private func willEnterForeground() {
            guard let mpv else { return }
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
                    print("[MPV-BG] Foreground: sampleBufferRenderer FAILED (\(err)) — flushing to recover")
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
            print("[MPV-BG] Foreground: vid=\(vidStr ?? "nil"), isPiP=\(progressStore.isPiPActive), audioOnly=\(progressStore.isAudioOnly), autoPaused=\(autoPausedOnBackground), outputs=[\(outputs)]")
            #endif
            if vidStr == "no" {
                mpv_set_property_string(mpv, "vid", "auto")
            }
            mpv_free(vid)

            // Undo the defensive pause applied in branch (4), but only if
            // we applied it — never clobber a user-initiated pause. Goes
            // through mpvQueue to match the background-entry write.
            if autoPausedOnBackground {
                autoPausedOnBackground = false
                mpvQueue.async { [weak self] in
                    guard let self, let mpv = self.mpv, !self.isShuttingDown else { return }
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
            print("[MPV-AIRPLAY] Route changed: reason=\(reasonStr), airPlay=\(hasAirPlay), outputs=\(outputs)")
            #endif

            // If AirPlay just connected and we're in the background with vid disabled, re-enable
            #if os(iOS)
            if hasAirPlay, reason == .newDeviceAvailable, let mpv = self.mpv {
                let vid = mpv_get_property_string(mpv, "vid")
                let vidStr = vid.flatMap { String(cString: $0) }
                mpv_free(vid)
                if vidStr == "no" {
                    #if DEBUG
                    print("[MPV-AIRPLAY] AirPlay connected while vid=no, re-enabling video")
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

        /// Creates (or recreates) the OpenGL FBO backed by an IOSurface CVPixelBuffer.
        /// mpv renders into this FBO; the CVPixelBuffer IS the rendered frame (zero copy).
        private func setupFBO(width: Int, height: Int) {
            guard let eaglContext, let textureCache else { return }
            EAGLContext.setCurrent(eaglContext)

            // Clean up old resources
            if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
            renderTexture = nil
            renderPixelBuffer = nil
            CVOpenGLESTextureCacheFlush(textureCache, 0)

            // Create IOSurface-backed CVPixelBuffer (shared with GL via texture cache)
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferOpenGLESCompatibilityKey: true as CFBoolean
            ]
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
            guard let pixelBuffer = pb else { return }
            renderPixelBuffer = pixelBuffer

            // Wrap as OpenGL ES texture (zero-copy — shares IOSurface)
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
                print("[MPV-ERR] CVOpenGLESTextureCacheCreateTextureFromImage failed: \(texResult)")
                #endif
                return
            }
            renderTexture = glTexture

            // Create FBO with the texture as color attachment
            let texName = CVOpenGLESTextureGetName(glTexture)
            glGenFramebuffers(1, &fbo)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
            glFramebufferTexture2D(
                GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                GLenum(GL_TEXTURE_2D), texName, 0
            )

            let fbStatus = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
            if fbStatus != GL_FRAMEBUFFER_COMPLETE {
                #if DEBUG
                print("[MPV-ERR] FBO incomplete: \(fbStatus)")
                #endif
            }

            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
            fboWidth = width
            fboHeight = height

            #if DEBUG
            print("[MPV-DIAG] FBO created: \(width)x\(height), fbo=\(fbo), tex=\(texName)")
            #endif
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
                #if os(tvOS)
                // tvOS SW render budget: cap total pixels/sec so the A15 can sustain
                // smooth playback. UHD@24fps is fine, 1080p@30fps is fine, 720p@60fps
                // needs a small downscale. The threshold is ~40M pixels/sec.
                if isLive {
                    var fps: Double = 30
                    if let mpv = self.mpv {
                        var fpsVal: Double = 0
                        mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &fpsVal)
                        if fpsVal > 0 { fps = fpsVal; detectedFps = fpsVal }
                    }
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
                let maxDim = 1920
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
            print("[MPV-DIAG] FBO queued: \(w)x\(h)")
            #endif
        }

        // MARK: - Background OpenGL ES Render + Display via AVSampleBufferDisplayLayer

        /// Called from mpv's update callback — schedules render on background thread.
        func scheduleRender() {
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

            guard let mpvGL, let eaglContext, let renderPixelBuffer else { return }
            let w = fboWidth
            let h = fboHeight
            guard w > 0, h > 0, fbo != 0 else { return }

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
            if layerStatus == .failed {
                if isInBackground && !autoPausedOnBackground, let mpvHandle = mpv {
                    autoPausedOnBackground = true
                    var pauseFlag: Int32 = 1
                    mpv_set_property(mpvHandle, "pause", MPV_FORMAT_FLAG, &pauseFlag)
                    #if DEBUG
                    print("[MPV-BG] Background: sampleBufferRenderer FAILED — auto-paused mpv to stop wasted decode work")
                    #endif
                }
            } else if let sampleBuffer = Self.makeSampleBuffer(from: renderPixelBuffer, presentationTime: presentationTime) {
                nonisolated(unsafe) let sb = sampleBuffer
                sampleBufferLayer?.sampleBufferRenderer.enqueue(sb)
                enqueued = true
            }

            let enqueueTime = CACurrentMediaTime()
            let intervalMs = lastEnqueueTime > 0 ? (enqueueTime - lastEnqueueTime) * 1000.0 : 0
            let expectedIntervalMs = fps > 0 ? 1000.0 / fps : 33.3

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
            let isAnomaly = intervalMs > 0 && (
                intervalMs > expectedIntervalMs * 2.0 ||
                !layerReady || layerStatus == .failed || !enqueued
            )

            if totalFrameCount <= 30 || isAnomaly {
                let tag = isAnomaly ? "⚠️" : "🎞️"
                // `streamTag` up front so log consumers can filter /
                // group per channel (e.g. `grep "NBC Sports"` to see
                // just that tile's frame history).
                print("\(tag) \(streamTag) [FRAME #\(totalFrameCount)] render=\(String(format: "%.1f", renderMs))ms interval=\(String(format: "%.1f", intervalMs))ms expected=\(String(format: "%.1f", expectedIntervalMs))ms fps=\(String(format: "%.1f", fps)) pts=\(String(format: "%.3f", CMTimeGetSeconds(presentationTime)))s ready=\(layerReady) enqueued=\(enqueued) status=\(layerStatus == .failed ? "FAILED" : "ok")")
            }
            #endif

            if layerStatus == .failed, let err = sampleBufferLayer?.sampleBufferRenderer.error {
                print("🔴 \(streamTag) [LAYER FAILED] \(err.localizedDescription)")
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
                print("📊 \(streamTag) [FRAME SUMMARY #\(totalFrameCount)] render=\(String(format: "%.1f", avgRender))ms avg / \(String(format: "%.1f", maxRender))ms max | interval=\(String(format: "%.1f", avgInt))ms avg | jitter=\(String(format: "%.2f", jitter))ms | late=\(lateFrameCount) | coalesced=\(coalescedFrameCount) | fps_detected=\(String(format: "%.2f", detectedFps)) | layer=\(layerStatus == .failed ? "FAILED" : "ok")")
            }

            lastEnqueueTime = enqueueTime
            mpv_render_context_report_swap(mpvGL)
        }

        func stop() {
            isShuttingDown = true
            stopStreamInfoTimer()
            DebugLogger.shared.logPlayback(event: "Stop",
                                           url: urls[safe: currentIndex]?.absoluteString)

            if let mpv {
                // Remove wakeup callback before quit to prevent use-after-free
                mpv_set_wakeup_callback(mpv, nil, nil)
                // Release retain balance — take-and-nil to prevent double-release
                // if MPV_EVENT_SHUTDOWN also fires
                if let retain = wakeupRetain {
                    wakeupRetain = nil
                    retain.release()
                }

                // Free OpenGL resources before destroying render context
                if let ctx = eaglContext {
                    EAGLContext.setCurrent(ctx)
                    if fbo != 0 { glDeleteFramebuffers(1, &fbo); fbo = 0 }
                    renderTexture = nil
                    renderPixelBuffer = nil
                    if let cache = textureCache { CVOpenGLESTextureCacheFlush(cache, 0) }
                    textureCache = nil
                    EAGLContext.setCurrent(nil)
                    eaglContext = nil
                }

                // Free render context before destroying mpv
                if let gl = mpvGL {
                    mpvGL = nil
                    mpv_render_context_free(gl)
                }

                // Send quit command — mpv will fire MPV_EVENT_SHUTDOWN
                mpvCommand(mpv, ["quit"])

                // Give mpv a moment to shut down, then force destroy if needed
                mpvQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    if let m = self?.mpv {
                        mpv_terminate_destroy(m)
                        self?.mpv = nil
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
            print("[MPV-DIAG] setupMPV: creating mpv instance...")
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
                print("[MPV-PHASE] \(streamTag) \(name): \(ms)ms (total=\(totalMs)ms)")
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

            #if targetEnvironment(simulator)
            checkError(mpv_set_option_string(mpv, "hwdec", "no"))
            #else
            // videotoolbox (no -copy): GPU decode → GPU texture via IOSurface interop.
            // Decoded frames stay on GPU — the OpenGL render API maps them as textures
            // for zero-copy color conversion, scaling, and OSD.
            checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
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
            // VOD:  2s for smooth resume-after-seek.
            checkError(mpv_set_option_string(mpv, "cache-pause-wait", isLive ? "0" : "2"))

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
            // `demuxer-lavf-analyzeduration=0.1`: cap libavformat's
            // stream-analysis stage at 100ms. Default is 5s — libmpv
            // scans that much data to identify all elementary streams
            // before the first frame decodes, which dominates first-
            // frame latency on well-formed MPEG-TS. Dropping to 0.1s
            // trusts the first PMT/PAT table (arrives within a few
            // packets on broadcast-grade TS) and moves straight to
            // decode. Worst case on an oddly-muxed stream: mpv misses
            // a late-arriving audio track. Acceptable tradeoff for
            // the user-perceived speedup.
            //
            // `demuxer-lavf-probesize=32768`: 32KB probe (default 5MB).
            // Pairs with analyzeduration — once we've capped the time
            // budget, capping the byte budget prevents mpv from
            // waiting for a full 5MB buffer to arrive before
            // confirming the stream is decodable.
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
                setOption(mpv, "demuxer-lavf-analyzeduration", "0.1")
                setOption(mpv, "demuxer-lavf-probesize", "32768")
                setOption(mpv, "cache-pause-initial", "no")
                setOption(mpv, "hls-bitrate", "max")
                setOption(mpv, "video-latency-hacks", "yes")
            }

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
            // Non-audio tiles: set `aid=no` so mpv never even
            // opens an AudioUnit for them. Previously we used
            // `mute=yes` which is audible-silence but the AO
            // stays open and competes with every other tile's
            // AO on the shared AVAudioSession — that contention
            // is what produced the "Audio device underrun"
            // storms with 9 concurrent tiles, which then
            // cascaded into 2-7s video-frame stalls. `aid=no`
            // eliminates the AO entirely. `mute=yes` is kept as
            // belt-and-suspenders against any audio packet that
            // slips through between mpv_create and mpv_initialize.
            if !initialIsAudioActive {
                setOption(mpv, "aid", "no")
                checkError(mpv_set_option_string(mpv, "mute", "yes"))
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
            if let ua = headers["User-Agent"], !ua.isEmpty {
                checkError(mpv_set_option_string(mpv, "user-agent", ua))
            }
            let preInitCustomHeaders = headers.filter {
                $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame
            }
            if !preInitCustomHeaders.isEmpty {
                let headerList = preInitCustomHeaders
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\r\n")
                checkError(mpv_set_option_string(mpv, "http-header-fields", headerList))
            }

            #if DEBUG
            markPhase("pre_init_options")
            print("[MPV-DIAG] setupMPV: options set, calling mpv_initialize...")
            // Header forensics — log each key + value length so we can
            // confirm what mpv actually sees per tile (and catch the
            // case where a 2nd tile's headers get mangled / cleared).
            // Values are NEVER logged — API keys live in there.
            let uaLen = headers["User-Agent"]?.count ?? 0
            let uaPreview = headers["User-Agent"]?.prefix(40) ?? "none"
            print("[MPV-DIAG]   hdr UA=\(uaPreview) (\(uaLen)b)")
            for (k, v) in preInitCustomHeaders.sorted(by: { $0.key < $1.key }) {
                let lenBytes = v.utf8.count
                print("[MPV-DIAG]   hdr \(k)=<redacted> (\(lenBytes)b)")
            }
            print("[MPV-DIAG]   tile=\(tileID ?? "single") urls=\(urls.count) first_url_len=\(urls.first?.absoluteString.count ?? 0)")
            print("[MPV-DIAG]   \(ProcessMetrics.summaryLine())")
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
                print("[MPV-ERR] mpv_initialize failed: \(errStr)")
                #endif
                mpv_terminate_destroy(mpv)
                self.mpv = nil
                let callback = onFatalError
                Task { await callback("MPV init failed: \(errStr)") }
                return
            }

            #if DEBUG
            let initMs = Date().timeIntervalSince(initStart) * 1000
            print("[MPV-DIAG] setupMPV: mpv_initialize succeeded ✓ (\(String(format: "%.0f", initMs))ms)")
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
                print("[MPV-ERR] mpv_render_context_create failed: \(errStr)")
                #endif
                mpv_terminate_destroy(mpv)
                self.mpv = nil
                let callback = onFatalError
                Task { await callback("MPV render context failed: \(errStr)") }
                return
            }

            #if DEBUG
            print("[MPV-DIAG] setupMPV: OpenGL ES render context created ✓")
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
                #else
                let liveMinMs = 5_000
                #endif
                let ms = isLive ? max(userPrefMs, liveMinMs) : userPrefMs
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
                mpv_set_property_string(mpv, "demuxer-lavf-probe-info", "nostreams")
                mpv_set_property_string(mpv, "demuxer-lavf-analyzeduration", "0")
                // Smaller probesize — MPEG-TS's codec identity is
                // obvious from the first ~32KB of PAT/PMT/PES
                // headers. mpv/ffmpeg's default probesize is 5MB
                // which for live TS means reading 200-500ms of data
                // before committing to a demuxer/decoder. 32KB is
                // ~2-4 TS packets worth of probing — enough to
                // identify codec, cheap to read from the stream.
                // Live-only; VOD keeps the larger default for mkv/
                // mp4 moov-parsing correctness.
                mpv_set_property_string(mpv, "demuxer-lavf-probesize", "32768")
                mpv_set_property_string(mpv, "probesize", "32768")
            } else {
                // VOD: larger buffer for seek-back
                mpv_set_property_string(mpv, "demuxer-max-bytes", "50MiB")
                mpv_set_property_string(mpv, "demuxer-max-back-bytes", "10MiB")
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
            print("[MPV-DIAG] ✓ mpv fully initialized: vo=libmpv (OpenGL ES render), hwdec=videotoolbox (requested)")
            print("[MPV-DIAG]   cache=\(cacheStr)s, readahead=\(cacheStr)s, isLive=\(isLive), setup_time=\(String(format: "%.0f", totalSetupMs))ms")
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
            print(timelineLine)
            #endif
            DebugLogger.shared.log(timelineLine, category: "MPV-STREAM", level: .info)
        }

        // MARK: - Playback

        private func play(url: URL) {
            guard let mpv else { return }

            hasStarted = false
            playbackStartTime = nil
            logStore.append("▶️ MPV attempt \(currentIndex + 1)/\(urls.count)")
            logStore.append("  \(url.absoluteString)")
            DebugLogger.shared.logPlayback(event: "Play attempt \(currentIndex + 1)/\(urls.count)",
                                           url: url.absoluteString)

            #if DEBUG
            print("[MPV-DIAG] ── Starting playback ──")
            print("[MPV-DIAG] URL: \(url.absoluteString)")
            print("[MPV-DIAG] isLive=\(isLive), attempt=\(currentIndex + 1)/\(urls.count)")
            #endif

            mpvCommand(mpv, ["loadfile", url.absoluteString, "replace"])
        }

        // MARK: - Event Processing

        private func readEvents() {
            mpvQueue.async { [weak self] in
                guard let self, let mpv = self.mpv else { return }

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

                    case MPV_EVENT_LOG_MESSAGE:
                        if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data)) {
                            let text = msg.pointee.text.map { String(cString: $0) } ?? ""
                            if text.contains("underrun") {
                                self.audioUnderrunCount += 1
                            }
                            // 10-bit HEVC: OpenGL ES can't map the VideoToolbox texture.
                            // Fall back to videotoolbox-copy (GPU decode → CPU copy → GL upload).
                            // This is slower than zero-copy but still hardware-decoded.
                            if text.contains("Initializing texture for hardware decoding failed") && !self.hwdecFallbackApplied {
                                self.hwdecFallbackApplied = true
                                print("[MPV-DIAG] ⚠️ GL interop failed (likely 10-bit HEVC) — falling back to videotoolbox-copy")
                                mpv_set_property_string(mpv, "hwdec", "videotoolbox-copy")
                                // Seek to current position to force reinit with the new hwdec
                                var timePos: Double = 0
                                mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &timePos)
                                self.mpvCommand(mpv, ["seek", String(format: "%.1f", timePos), "absolute", "exact"])
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
                            print("[\(self.logTimestamp)] \(self.streamTag) [MPV-LOG] [\(prefix)] \(level): \(text)", terminator: "")
                            #endif
                        }
                        break

                    case MPV_EVENT_SHUTDOWN:
                        #if DEBUG
                        print("[MPV-DIAG] Event: shutdown")
                        #endif
                        self.stopStreamInfoTimer()
                        if !self.isShuttingDown {
                            mpv_set_wakeup_callback(mpv, nil, nil)
                            if let retain = self.wakeupRetain {
                                self.wakeupRetain = nil
                                retain.release()
                            }
                            if let gl = self.mpvGL {
                                self.mpvGL = nil
                                mpv_render_context_free(gl)
                            }
                            mpv_terminate_destroy(mpv)
                            self.mpv = nil
                        }
                        return  // Exit event loop

                    case MPV_EVENT_PLAYBACK_RESTART:
                        // Now that initial buffer is filled, disable cache-pause for live
                        // so playback doesn't stall on brief network dips.
                        if self.isLive, let mpv = self.mpv {
                            mpv_set_property_string(mpv, "cache-pause", "no")
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
                        if let mpv = self.mpv {
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
                        if !self.isLive, !self.hasAttemptedResume, self.mpv != nil {
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
                        if let mpv = self.mpv {
                            let info = self.populateStreamInfo(mpv)
                            self.startStreamInfoTimer()

                            #if DEBUG
                            var cacheDur: Double = 0
                            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
                            var avsync: Double = 0
                            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)
                            let t = self.streamTag
                            print("\(t) [MPV-DIAG] Event: playback-restart — cache=\(String(format: "%.2f", cacheDur))s, avsync=\(String(format: "%.4f", avsync))s")
                            print("\(t) [MPV-STREAM] video=\(info.videoCodec) \(info.width)×\(info.height) \(info.pixelFormat), hwdec=\(info.hwdec)")
                            print("\(t) [MPV-STREAM] audio=\(info.audioCodec) \(info.sampleRate)Hz \(info.channels)ch")
                            #endif
                        }
                        break

                    default:
                        #if DEBUG
                        if let name = mpv_event_name(event.pointee.event_id) {
                            print("[MPV-DIAG] Event: \(String(cString: name))")
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
            print("[MPV-DIAG] State: opening (start-file)")
            #endif
        }

        private func handleFileLoaded() {
            // Track buffer exit
            if let entered = bufferEnteredTime {
                let bufDuration = Date().timeIntervalSince(entered)
                totalBufferingDuration += bufDuration
                bufferEnteredTime = nil
                #if DEBUG
                print("[MPV-DIAG]   ↳ Buffer resolved in \(String(format: "%.1f", bufDuration))s (total: \(String(format: "%.1f", totalBufferingDuration))s)")
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
                print("\(streamTag) [MPV-DIAG]   ↳ First frame rendered (total time from setup: \(String(format: "%.0f", totalStartMs))ms)")

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
                    print("\(t) [MPV-STREAM] format=\(fileFormat), video=\(videoCodec) \(videoW)×\(videoH) \(videoFormat), hwdec=\(hwdecCurrent)")
                    print("\(t) [MPV-STREAM] audio=\(audioCodec) \(sampleRate)Hz \(channels)ch \(audioParams)")
                    print("\(t) [MPV-STREAM] cache_at_start=\(String(format: "%.2f", cacheDur))s, paused_for_cache=\(pauseForCache != 0)")
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
                print("[NowPlaying-Gate] \(streamTag) 2s stability scheduled (tileID=\(debugTileID), title=\"\(title)\")")
                #endif

                let ps2 = progressStore
                let mpvQ = mpvQueue
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, !self.nowPlayingConfigured else {
                        #if DEBUG
                        print("[NowPlaying-Gate] 2s fire: self=nil or already configured")
                        #endif
                        return
                    }
                    // Verify still playing — route through mpvQueue to avoid race with stop()
                    let capturedDur = dur  // Bind to let for Sendable compliance
                    mpvQ.async { [weak self] in
                        guard let self, let mpv = self.mpv, !self.isShuttingDown else {
                            #if DEBUG
                            print("[NowPlaying-Gate] mpvQ fire: self/mpv nil or shutting down")
                            #endif
                            return
                        }
                        var idle: Int64 = 0
                        mpv_get_property(mpv, "core-idle", MPV_FORMAT_FLAG, &idle)
                        #if DEBUG
                        print("[NowPlaying-Gate] mpvQ fire: core-idle=\(idle)")
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
                            print("[NowPlaying-Gate] shouldDrive=\(canDrive) tileID=\(self.tileID ?? "single") sessionMode=\(sessionMode) audioTileID=\(audioID)")
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
                                    guard let self, let mpv = self.mpv else { return }
                                    let secs = String(format: "%.3f", time)
                                    self.mpvCommand(mpv, ["seek", secs, "absolute"])
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
            print("[MPV-DIAG] State: end-file (reason=\(reason), error=\(endFile.error))")
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
                print("[MPV-DIAG] end-file STOP (intentional — no retry)")
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
                // retry up to 3 times with exponential backoff plus
                // random jitter so 9 tiles hitting 503 at the same
                // moment don't all retry at the same wall-clock tick
                // and trigger the same thundering-herd problem again.
                let isLoadingFailed = endFile.error == MPV_ERROR_LOADING_FAILED.rawValue
                if isLoadingFailed && loadFailureRetryCount < maxLoadFailureRetries {
                    loadFailureRetryCount += 1
                    let retryNum = loadFailureRetryCount
                    let maxR = maxLoadFailureRetries
                    // Exponential backoff: 1s, 2s, 4s. Add 0–600ms of
                    // random jitter per tile so concurrent retries
                    // don't line up on the same wall-clock moment.
                    let baseDelay = pow(2.0, Double(retryNum - 1))
                    let jitter = Double.random(in: 0...0.6)
                    let delay = baseDelay + jitter
                    logStore.append(
                        "⏳ MPV: load failed (503?) — retry \(retryNum)/\(maxR) in \(String(format: "%.1f", delay))s"
                    )
                    #if DEBUG
                    print("[MPV-DIAG] \(streamTag) LOADING_FAILED — retry \(retryNum)/\(maxR) in \(String(format: "%.2f", delay))s")
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
                    print("[MPV-DIAG] Instant end (\(String(format: "%.0f", elapsed * 1000))ms) — failing over")
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
                    print("[MPV-DIAG] Premature end (\(String(format: "%.1f", elapsed))s) — retrying same URL (\(retryNum)/\(maxSameURLRetries))")
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
            } else {
                // VOD ended normally — not an error
                playbackEnded = true
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
                        print("[MPV-DIAG] First time change: \(ms)ms — playback started")
                        #endif
                    }

                    // Throttle UI updates
                    let now = Date()
                    if !isLive, now.timeIntervalSince(lastProgressUpdate) >= 1.0 {
                        lastProgressUpdate = now
                        let ps = progressStore
                        DispatchQueue.main.async { ps.currentMs = ms }
                    }

                    // Save VOD progress every 10 seconds (non-live only)
                    if !isLive, now.timeIntervalSince(lastProgressSave) >= 10.0 {
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
                        if let mpv = self.mpv {
                            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
                        }
                        print("[MPV-DIAG]   ↳ Buffering started (event #\(bufferEventCount)), cache_at_stall=\(String(format: "%.2f", cacheDur))s, underruns_so_far=\(self.audioUnderrunCount)")
                        #endif
                    } else if let entered = bufferEnteredTime {
                        let bufDuration = Date().timeIntervalSince(entered)
                        totalBufferingDuration += bufDuration
                        bufferEnteredTime = nil
                        #if DEBUG
                        print("[MPV-DIAG]   ↳ Buffer resolved in \(String(format: "%.1f", bufDuration))s (total: \(String(format: "%.1f", totalBufferingDuration))s)")
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

            // A/V sync
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

            // Network speed (for live streams)
            var demuxerBytes: Int64 = 0
            mpv_get_property(mpv, "demuxer-cache-state/raw-input-rate", MPV_FORMAT_INT64, &demuxerBytes)

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
            print("[\(ts)] \(t) [MPV-DIAG] time=\(ms)ms isPlaying=\(isPlaying) callbacks/\(isLive ? 15 : 5)s=\(timeChangeCount)")
            print("[\(ts)] \(t) [MPV-PERF] vo_drops: +\(deltaVideoDrops), dec_drops: +\(deltaDecoderDrops), fps: \(String(format: "%.1f", estimatedFPS))/\(String(format: "%.1f", displayFPS))disp, hwdec=\(hwdecCurrent)")
            print("[\(ts)] \(t) [MPV-FRAME] render: \(String(format: "%.1f", avgRenderMs))ms avg / \(String(format: "%.1f", maxRenderMs))ms max, interval: \(String(format: "%.1f", avgInterval))ms avg [\(String(format: "%.1f", minInterval))-\(String(format: "%.1f", maxInterval))ms], jitter: \(String(format: "%.2f", jitterMs))ms, late: \(lateFrames)/\(frameCount), layer: \(layerStatus)")
            print("[\(ts)] \(t) [MPV-CACHE] duration: \(String(format: "%.2f", cacheDuration))s, bytes: \(cacheBytes / 1024)KB, speed: \(String(format: "%.0f", cacheSpeed / 1024))KB/s, input_rate: \(demuxerBytes / 1024)KB/s, paused_for_cache: \(pausedForCache != 0)")
            print("[\(ts)] \(t) [MPV-AUDIO] avsync: \(String(format: "%.4f", avsync))s, audio_pts: \(String(format: "%.2f", audioPts))s, underruns: \(audioUnderrunCount), buf_events: \(bufferEventCount), buf_time: \(String(format: "%.1f", totalBufferingDuration))s")
            // One-line per-stream summary — the "tl;dr" that's
            // easiest to grep when scanning 9 concurrent tiles'
            // logs. Mirrors the key numbers from the verbose lines
            // above so `grep STREAM-SUMMARY` gives a quick overview.
            print("[\(ts)] \(t) [STREAM-SUMMARY] fps=\(String(format: "%.1f", estimatedFPS)) interval=\(String(format: "%.1f", avgInterval))ms jitter=\(String(format: "%.1f", jitterMs))ms late=\(lateFrames)/\(frameCount) vo_drops=+\(deltaVideoDrops) dec_drops=+\(deltaDecoderDrops) underruns=\(audioUnderrunCount) avsync=\(String(format: "%.3f", avsync))s cache=\(String(format: "%.1f", cacheDuration))s hwdec=\(hwdecCurrent) layer=\(layerStatus)")
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
            print("[\(ts)] [MPV-PERF] tile=\(tile) \(metricsLine)")
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
                print("[MPV-DIAG] Failover: waiting 300ms before attempt \(idx + 1)/\(urls.count)")
                #endif
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    print("[MPV-DIAG] Failover: starting attempt \(idx + 1)")
                    #endif
                    self.play(url: nextURL)
                }
            } else if isLive && anyAttemptStarted && !hasPerformedWarmupRetry {
                hasPerformedWarmupRetry = true
                logStore.append("⏳ MPV: proxy warming up — retrying in 2s…")
                #if DEBUG
                print("[MPV-DIAG] Warmup retry: waiting 2s before retry")
                #endif
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.currentIndex = 0
                    self.anyAttemptStarted = false
                    self.logStore.append("🔄 MPV: warm-up retry")
                    #if DEBUG
                    print("[MPV-DIAG] Warmup retry: starting")
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
            guard let mpv = self.mpv,
                  progressStore.isStreamInfoVisible else { return }
            var cacheDur: Double = 0; var avsync: Double = 0
            var drops: Int64 = 0; var bitrate: Double = 0; var fps: Double = 0
            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)
            mpv_get_property(mpv, "frame-drop-count", MPV_FORMAT_INT64, &drops)
            mpv_get_property(mpv, "demuxer-cache-state/raw-input-rate", MPV_FORMAT_DOUBLE, &bitrate)
            mpv_get_property(mpv, "estimated-vf-fps", MPV_FORMAT_DOUBLE, &fps)
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
                print("[MPV-ERR] command \(args) failed: \(String(cString: mpv_error_string(result)))")
            }
            #endif
        }

        private func checkError(_ status: CInt) {
            if status < 0 {
                #if DEBUG
                print("[MPV-ERR] \(String(cString: mpv_error_string(status)))")
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
                print("[MPV-ERR] option \"\(name)\"=\"\(value)\" rejected: \(String(cString: mpv_error_string(status)))")
                #endif
            }
            return status
        }

        private func logOption(_ name: String, _ status: CInt) {
            #if DEBUG
            if status < 0 {
                print("[MPV-OPT] ✗ \(name): \(String(cString: mpv_error_string(status)))")
            } else {
                print("[MPV-OPT] ✓ \(name)")
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
                    print("[MPV-PIP] willStop: flushed sampleBufferRenderer (kept displayed image)")
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
            print("[MPV-PIP] failedToStart: \(error.localizedDescription) (\(error as NSError))")
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
