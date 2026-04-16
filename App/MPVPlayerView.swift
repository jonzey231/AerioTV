#if canImport(Libmpv)
import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Libmpv
import CoreVideo
import CoreMedia  // For CMSampleBuffer
import OpenGLES

// MARK: - MPV Player View Controller (OpenGL ES render → AVSampleBufferDisplayLayer → PiP)

class MPVPlayerViewController: UIViewController {
    weak var coordinator: MPVPlayerViewRepresentable.Coordinator?

    /// AVSampleBufferDisplayLayer — vsync-synchronized frame presentation.
    /// Used on both iOS (PiP-compatible) and tvOS (tear-free).
    let sampleBufferLayer = AVSampleBufferDisplayLayer()

    #if os(iOS)
    /// PiP controller — initialized after view loads.
    var pipController: AVPictureInPictureController?
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.layer.isOpaque = true

        // AVSampleBufferDisplayLayer for vsync-synchronized presentation (both platforms).
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.frame = view.bounds
        view.layer.addSublayer(sampleBufferLayer)

        #if os(iOS)
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let coordinator {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: sampleBufferLayer,
                playbackDelegate: coordinator
            )
            pipController = AVPictureInPictureController(contentSource: contentSource)
            pipController?.delegate = coordinator
        }
        #endif

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

        // Wire up PiP toggle (iOS only)
        #if os(iOS)
        let coord = context.coordinator
        coord.progressStore.togglePiPAction = { [weak vc, weak coord] in
            guard let pip = vc?.pipController else { return }
            if pip.isPictureInPictureActive {
                pip.stopPictureInPicture()
                DispatchQueue.main.async { coord?.progressStore.isPiPActive = false }
            } else {
                pip.startPictureInPicture()
                DispatchQueue.main.async { coord?.progressStore.isPiPActive = true }
            }
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

        /// Called from `updateUIViewController`. Sends `mute=0` when
        /// the tile becomes audio-active, `mute=1` otherwise. No-op
        /// when the incoming value matches the last applied.
        @MainActor
        fileprivate func applyAudioFocusIfChanged(_ isActive: Bool) {
            guard lastAppliedAudioFocus != isActive else { return }
            lastAppliedAudioFocus = isActive
            DebugLogger.shared.log(
                "[MV-Audio] mpv mute=\(!isActive) tile=\(tileID ?? "single")",
                category: "MPV-STREAM", level: .info
            )
            setMPVFlag(property: "mute", value: !isActive)
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
            guard lastAppliedPause != paused else { return }
            lastAppliedPause = paused
            DebugLogger.shared.log(
                "[MV-PiP] mpv pause=\(paused) tile=\(tileID ?? "single")",
                category: "MPV-STREAM", level: .info
            )
            setMPVFlag(property: "pause", value: paused)
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
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func didEnterBackground() {
            guard let mpv else { return }
            #if os(iOS)
            // Keep video alive if PiP is active or AirPlay is connected —
            // disabling vid kills the PiP window and drops AirPlay audio.
            if progressStore.isPiPActive {
                #if DEBUG
                print("[MPV-AIRPLAY] Background: PiP active, keeping vid")
                #endif
                return
            }

            let route = AVAudioSession.sharedInstance().currentRoute
            let airPlayAudio = route.outputs.contains(where: { $0.portType == .airPlay })

            #if DEBUG
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            print("[MPV-AIRPLAY] Background: airPlayAudio=\(airPlayAudio), isPiP=\(progressStore.isPiPActive), outputs=[\(outputs)]")
            #endif

            if airPlayAudio { return }
            #endif
            // No PiP / no AirPlay — disable video to prevent GPU crash on background
            mpv_set_property_string(mpv, "vid", "no")
        }

        @objc private func willEnterForeground() {
            guard let mpv else { return }
            // Re-enable video if it was disabled on background entry
            let vid = mpv_get_property_string(mpv, "vid")
            let vidStr = vid.flatMap { String(cString: $0) }
            #if DEBUG
            let route = AVAudioSession.sharedInstance().currentRoute
            let outputs = route.outputs.map { "\($0.portName)(\($0.portType.rawValue))" }.joined(separator: ", ")
            print("[MPV-AIRPLAY] Foreground: vid=\(vidStr ?? "nil"), isPiP=\(progressStore.isPiPActive), outputs=[\(outputs)]")
            #endif
            if vidStr == "no" {
                mpv_set_property_string(mpv, "vid", "auto")
            }
            mpv_free(vid)
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
            isShuttingDown = false
            playbackEnded = false
            // Reset diagnostics
            diagStartTime = Date()
            prevDroppedFrames = 0; prevDecoderDrops = 0
            bufferEnteredTime = nil
            totalBufferingDuration = 0; bufferEventCount = 0
            audioUnderrunCount = 0

            setupMPV()
            play(url: urls[currentIndex])
        }

        // MARK: - Renderer Setup

        /// Called from viewDidLoad. Stores layer reference. Pixel buffers deferred to handleResize.
        @MainActor
        func setupRenderer(layer: CALayer) {
            self.sampleBufferLayer = layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first
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

            // Start mpv on render thread if first time (creates EAGLContext + textureCache)
            if !mpvStarted {
                mpvStarted = true
                renderQueue.async { [weak self] in
                    self?.start()
                }
            }

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

            // Enqueue — the renderPixelBuffer IS the rendered frame (zero copy via IOSurface)
            var enqueued = false
            if let sampleBuffer = Self.makeSampleBuffer(from: renderPixelBuffer, presentationTime: presentationTime) {
                nonisolated(unsafe) let sb = sampleBuffer
                sampleBufferLayer?.sampleBufferRenderer.enqueue(sb)
                enqueued = true
            }

            let enqueueTime = CACurrentMediaTime()
            let intervalMs = lastEnqueueTime > 0 ? (enqueueTime - lastEnqueueTime) * 1000.0 : 0
            let expectedIntervalMs = fps > 0 ? 1000.0 / fps : 33.3

            // ── Per-frame diagnostics ──
            let isAnomaly = intervalMs > 0 && (
                intervalMs > expectedIntervalMs * 2.0 ||
                intervalMs < expectedIntervalMs * 0.3 ||
                !layerReady || layerStatus == .failed || !enqueued
            )

            if totalFrameCount <= 120 || isAnomaly {
                let tag = isAnomaly ? "⚠️" : "🎞️"
                print("\(tag) [FRAME #\(totalFrameCount)] render=\(String(format: "%.1f", renderMs))ms interval=\(String(format: "%.1f", intervalMs))ms expected=\(String(format: "%.1f", expectedIntervalMs))ms fps=\(String(format: "%.1f", fps)) pts=\(String(format: "%.3f", CMTimeGetSeconds(presentationTime)))s ready=\(layerReady) enqueued=\(enqueued) status=\(layerStatus == .failed ? "FAILED" : "ok")")
            }

            if layerStatus == .failed, let err = sampleBufferLayer?.sampleBufferRenderer.error {
                print("🔴 [LAYER FAILED] \(err.localizedDescription)")
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
                print("📊 [FRAME SUMMARY #\(totalFrameCount)] render=\(String(format: "%.1f", avgRender))ms avg / \(String(format: "%.1f", maxRender))ms max | interval=\(String(format: "%.1f", avgInt))ms avg | jitter=\(String(format: "%.2f", jitter))ms | late=\(lateFrameCount) | coalesced=\(coalescedFrameCount) | fps_detected=\(String(format: "%.2f", detectedFps)) | layer=\(layerStatus == .failed ? "FAILED" : "ok")")
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
            #endif

            mpv = mpv_create()
            guard let mpv else {
                logStore.append("✗ MPV: failed to create instance")
                let callback = onFatalError
                Task { await callback("MPV: failed to create player") }
                return
            }

            // ── Pre-init options ──

            // Request error-level logs in release builds so we can detect
            // GL interop failures (10-bit HEVC) and fall back dynamically.
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
            checkError(mpv_set_option_string(mpv, "hwdec-software-fallback", "600"))  // Live MPEG-TS joins mid-GOP without SPS/PPS — VT errors until keyframe arrives
            #endif

            // Initial buffer before playback starts:
            // Live: 0.5s for fast channel start (cache-pause disabled after playback-restart anyway).
            // VOD: 2s for smooth resume-after-seek.
            checkError(mpv_set_option_string(mpv, "cache-pause-wait", isLive ? "0.5" : "2"))

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
            if !initialIsAudioActive {
                checkError(mpv_set_option_string(mpv, "mute", "yes"))
            }
            if initialShouldPause {
                checkError(mpv_set_option_string(mpv, "pause", "yes"))
            }

            #if DEBUG
            print("[MPV-DIAG] setupMPV: options set, calling mpv_initialize...")
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
            #endif

            // ── Post-init: create OpenGL ES render context ──

            // EAGLContext for GPU-accelerated mpv rendering
            eaglContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)
            guard let glCtx = eaglContext else {
                logStore.append("✗ MPV: failed to create EAGLContext")
                let callback = onFatalError
                Task { await callback("MPV: OpenGL ES context creation failed") }
                return
            }
            EAGLContext.setCurrent(glCtx)

            // Texture cache for zero-copy CVPixelBuffer ↔ GL texture sharing
            var cache: CVOpenGLESTextureCache?
            CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, glCtx, nil, &cache)
            textureCache = cache

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
                let ms = isLive ? max(userPrefMs, 5_000) : userPrefMs
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
            } else {
                // VOD: larger buffer for seek-back
                mpv_set_property_string(mpv, "demuxer-max-bytes", "50MiB")
                mpv_set_property_string(mpv, "demuxer-max-back-bytes", "10MiB")
            }

            mpv_set_property_string(mpv, "framedrop", "decoder+vo")
            mpv_set_property_string(mpv, "video-sync", "audio")
            mpv_set_property_string(mpv, "audio-buffer", "1.5")
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
            let cacheStr = String(format: "%.1f", cachingSecs)
            let totalSetupMs = setupStartTime.map { Date().timeIntervalSince($0) * 1000 } ?? -1
            print("[MPV-DIAG] ✓ mpv fully initialized: vo=libmpv (OpenGL ES render), hwdec=videotoolbox (requested)")
            print("[MPV-DIAG]   cache=\(cacheStr)s, readahead=\(cacheStr)s, isLive=\(isLive), setup_time=\(String(format: "%.0f", totalSetupMs))ms")
            #endif
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
                            let prefix = msg.pointee.prefix.map { String(cString: $0) } ?? "?"
                            let level = msg.pointee.level.map { String(cString: $0) } ?? "?"
                            print("[\(self.logTimestamp)] [MPV-LOG] [\(prefix)] \(level): \(text)", terminator: "")
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
                            Task { @MainActor in
                                // Prefer explicit position (from Continue Watching), fall back to DB
                                let resumeMs: Int32? = if let explicitMs, explicitMs > 0 {
                                    explicitMs
                                } else if let vodID, !vodID.isEmpty {
                                    WatchProgressManager.getResumePosition(vodID: vodID)
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
                            print("[MPV-DIAG] Event: playback-restart — cache=\(String(format: "%.2f", cacheDur))s, avsync=\(String(format: "%.4f", avsync))s")
                            print("[MPV-STREAM] video=\(info.videoCodec) \(info.width)×\(info.height) \(info.pixelFormat), hwdec=\(info.hwdec)")
                            print("[MPV-STREAM] audio=\(info.audioCodec) \(info.sampleRate)Hz \(info.channels)ch")
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
                print("[MPV-DIAG]   ↳ First frame rendered (total time from setup: \(String(format: "%.0f", totalStartMs))ms)")

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

                    print("[MPV-STREAM] format=\(fileFormat), video=\(videoCodec) \(videoW)×\(videoH) \(videoFormat), hwdec=\(hwdecCurrent)")
                    print("[MPV-STREAM] audio=\(audioCodec) \(sampleRate)Hz \(channels)ch \(audioParams)")
                    print("[MPV-STREAM] cache_at_start=\(String(format: "%.2f", cacheDur))s, paused_for_cache=\(pauseForCache != 0)")
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

                let ps2 = progressStore
                let mpvQ = mpvQueue
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, !self.nowPlayingConfigured else { return }
                    // Verify still playing — route through mpvQueue to avoid race with stop()
                    let capturedDur = dur  // Bind to let for Sendable compliance
                    mpvQ.async { [weak self] in
                        guard let self, let mpv = self.mpv, !self.isShuttingDown else { return }
                        var idle: Int64 = 0
                        mpv_get_property(mpv, "core-idle", MPV_FORMAT_FLAG, &idle)
                        guard idle == 0 else { return }

                        self.nowPlayingConfigured = true
                        Task { @MainActor [weak self] in
                            // Gate on bridge ownership. A non-audio
                            // multiview tile still reaches this path
                            // (every coordinator's stability check
                            // fires after 2s) but must NOT publish
                            // now-playing info — the audio tile owns
                            // the lockscreen. `nowPlayingConfigured`
                            // stays `true` either way so we don't
                            // rearm the 2s timer.
                            guard let self, self.shouldDriveNowPlayingBridge() else { return }
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

            if reason == MPV_END_FILE_REASON_ERROR {
                let errStr = String(cString: mpv_error_string(endFile.error))
                logStore.append("✗ MPV error: \(errStr)")
                DebugLogger.shared.logPlayback(event: "error: \(errStr)")
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
            print("[\(ts)] [MPV-DIAG] time=\(ms)ms isPlaying=\(isPlaying) callbacks/\(isLive ? 15 : 5)s=\(timeChangeCount)")
            print("[\(ts)] [MPV-PERF] vo_drops: +\(deltaVideoDrops), dec_drops: +\(deltaDecoderDrops), fps: \(String(format: "%.1f", estimatedFPS))/\(String(format: "%.1f", displayFPS))disp, hwdec=\(hwdecCurrent)")
            print("[\(ts)] [MPV-FRAME] render: \(String(format: "%.1f", avgRenderMs))ms avg / \(String(format: "%.1f", maxRenderMs))ms max, interval: \(String(format: "%.1f", avgInterval))ms avg [\(String(format: "%.1f", minInterval))-\(String(format: "%.1f", maxInterval))ms], jitter: \(String(format: "%.2f", jitterMs))ms, late: \(lateFrames)/\(frameCount), layer: \(layerStatus)")
            print("[\(ts)] [MPV-CACHE] duration: \(String(format: "%.2f", cacheDuration))s, bytes: \(cacheBytes / 1024)KB, speed: \(String(format: "%.0f", cacheSpeed / 1024))KB/s, input_rate: \(demuxerBytes / 1024)KB/s, paused_for_cache: \(pausedForCache != 0)")
            print("[\(ts)] [MPV-AUDIO] avsync: \(String(format: "%.4f", avsync))s, audio_pts: \(String(format: "%.2f", audioPts))s, underruns: \(audioUnderrunCount), buf_events: \(bufferEventCount), buf_time: \(String(format: "%.1f", totalBufferingDuration))s")
            #endif

            DebugLogger.shared.log(
                "vo_drops=+\(deltaVideoDrops) dec_drops=+\(deltaDecoderDrops) cache=\(String(format: "%.1f", cacheDuration))s fps=\(String(format: "%.1f", estimatedFPS)) bufEvents=\(bufferEventCount) bufTime=\(String(format: "%.1f", totalBufferingDuration))s underruns=\(audioUnderrunCount)",
                category: "MPV-Perf", level: .perf)

            // Memory + thermal state
            var taskInfo = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kr = withUnsafeMutablePointer(to: &taskInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            let memMB = kr == KERN_SUCCESS ? Double(taskInfo.resident_size) / (1024 * 1024) : -1
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            #if DEBUG
            print("[\(ts)] [MPV-PERF] memory: \(String(format: "%.1f", memMB))MB, thermal: \(thermal)")
            #endif
            DebugLogger.shared.log("memory=\(String(format: "%.1f", memMB))MB thermal=\(thermal)",
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

        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            debugLog("🖼️ PiP: starting")
            DispatchQueue.main.async { self.progressStore.isPiPActive = true }
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

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            debugLog("🖼️ PiP: stopped")
            DispatchQueue.main.async { self.progressStore.isPiPActive = false }
            // Stopping is always safe — clearing the flag when the
            // store's already been reset is a no-op. Still gate on
            // tileID so single-stream PiP doesn't touch the
            // multiview store at all.
            let myTileID = tileID
            if let myTileID {
                Task { @MainActor in
                    MultiviewStore.shared.isPiPActive = false
                    DebugLogger.shared.log(
                        "[MV-PiP] ended tile=\(myTileID)",
                        category: "Playback", level: .info
                    )
                }
            }
        }
    }
}
#endif // canImport(Libmpv)
