#if canImport(Libmpv)
import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Libmpv
import CoreVideo
import CoreMedia  // For CMSampleBuffer
#if os(tvOS)
import IOSurface  // For CVPixelBufferGetIOSurface on tvOS
#endif

// MARK: - MPV Player View Controller (SW render → AVSampleBufferDisplayLayer → PiP)

class MPVPlayerViewController: UIViewController {
    weak var coordinator: MPVPlayerViewRepresentable.Coordinator?

    #if os(iOS)
    /// AVSampleBufferDisplayLayer for PiP-compatible display (iOS only).
    let sampleBufferLayer = AVSampleBufferDisplayLayer()
    /// PiP controller — initialized after view loads.
    var pipController: AVPictureInPictureController?
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.layer.isOpaque = true

        #if os(iOS)
        // iOS: AVSampleBufferDisplayLayer for PiP support
        sampleBufferLayer.videoGravity = .resizeAspect
        sampleBufferLayer.frame = view.bounds
        view.layer.addSublayer(sampleBufferLayer)

        if AVPictureInPictureController.isPictureInPictureSupported(),
           let coordinator {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: sampleBufferLayer,
                playbackDelegate: coordinator
            )
            pipController = AVPictureInPictureController(contentSource: contentSource)
            pipController?.delegate = coordinator
        }
        #else
        // tvOS: plain CALayer — no PiP, simpler display path
        view.layer.contentsGravity = .resizeAspect
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
        #if os(iOS)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferLayer.frame = view.bounds
        CATransaction.commit()
        #endif
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

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(urls: urls, headers: headers, isLive: isLive,
                            progressStore: progressStore, logStore: logStore,
                            onFatalError: onFatalError)
        c.nowPlayingTitle = nowPlayingTitle
        c.nowPlayingSubtitle = nowPlayingSubtitle
        c.nowPlayingArtworkURL = nowPlayingArtworkURL
        return c
    }

    func makeUIViewController(context: Context) -> MPVPlayerViewController {
        // Configure audio session
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            #else
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            #endif
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logStore.append("⚠️ AudioSession: \(error)")
        }

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
        // Layout handled by viewDidLayoutSubviews
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
        private let progressStore: PlayerProgressStore
        private let logStore: AttemptLogStore
        private let onFatalError: @MainActor @Sendable (String) -> Void

        // Now Playing metadata
        var nowPlayingTitle: String = ""
        var nowPlayingSubtitle: String?
        var nowPlayingArtworkURL: URL?
        private var nowPlayingConfigured = false

        // mpv handles
        private var mpv: OpaquePointer?
        private var mpvGL: OpaquePointer?  // mpv_render_context (SW render API)
        private let mpvQueue = DispatchQueue(label: "com.aerio.mpv", qos: .userInteractive)
        private var wakeupRetain: Unmanaged<Coordinator>?  // Balances passRetained in setupMPV

        // SW render — background thread renders to CVPixelBuffer
        private let renderQueue = DispatchQueue(label: "com.aerio.mpv.render", qos: .userInteractive)
        private weak var displayLayer: CALayer?  // tvOS: direct CALayer.contents
        #if os(iOS)
        private weak var sampleBufferLayer: AVSampleBufferDisplayLayer?  // iOS: PiP-compatible
        #endif
        private var pixelBuffers: [CVPixelBuffer?] = [nil, nil]  // Double-buffered
        private var currentBufferIndex = 0
        private var renderWidth: Int = 0
        private var renderHeight: Int = 0

        // Failover & retry state (identical to VLC coordinator)
        private var currentIndex = 0
        private var hasStarted = false
        private var anyAttemptStarted = false
        private var hasPerformedWarmupRetry = false
        private var playbackStartTime: Date?
        private var sameURLRetryCount = 0
        private let maxSameURLRetries = 3
        private var isShuttingDown = false

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
        // renderPending: accessed from mpv callback thread + render thread — use lock
        private var renderPending = false
        private var renderLock = os_unfair_lock()

        init(urls: [URL], headers: [String: String], isLive: Bool,
             progressStore: PlayerProgressStore,
             logStore: AttemptLogStore,
             onFatalError: @escaping @MainActor @Sendable (String) -> Void) {
            self.urls = urls
            self.headers = headers
            self.isLive = isLive
            self.progressStore = progressStore
            self.logStore = logStore
            self.onFatalError = onFatalError
            super.init()

            // Toggle play/pause
            progressStore.togglePauseAction = { [weak self] in
                guard let self, let mpv = self.mpv else { return }
                var flag: Int = 0
                mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
                var newFlag: Int = flag == 0 ? 1 : 0
                mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &newFlag)
            }

            // Seek closure — VOD only
            progressStore.seekAction = { [weak self] targetMs in
                guard let self, !self.isLive, let mpv = self.mpv else { return }
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
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func didEnterBackground() {
            guard let mpv else { return }
            // Disable video output to prevent Metal crash on background
            mpv_set_property_string(mpv, "vid", "no")
        }

        @objc private func willEnterForeground() {
            guard let mpv else { return }
            mpv_set_property_string(mpv, "vid", "auto")
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
            self.displayLayer = layer
            #if os(iOS)
            self.sampleBufferLayer = layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first
            #endif
        }

        private var mpvStarted = false

        /// Handle rotation/resize — creates or recreates double-buffered CVPixelBuffers.
        func handleResize(size: CGSize) {
            #if os(tvOS)
            let scale: CGFloat = 1.0
            #else
            let scale = min(UIScreen.main.scale, 2.0)
            #endif
            let w = Int(size.width * scale)
            let h = Int(size.height * scale)
            guard w > 0 && h > 0 else { return }
            guard w != renderWidth || h != renderHeight else { return }

            renderWidth = w
            renderHeight = h

            // Create IOSurface-backed pixel buffers for zero-copy CALayer display
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            for i in 0..<2 {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                    kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
                pixelBuffers[i] = pb
            }

            #if DEBUG
            print("[MPV-DIAG] CVPixelBuffer: \(w)x\(h)")
            #endif

            // Start mpv on render thread if first time
            if !mpvStarted {
                mpvStarted = true
                renderQueue.async { [weak self] in
                    self?.start()
                }
            }
        }

        // MARK: - Background SW Render + Display via AVSampleBufferDisplayLayer

        /// Called from mpv's update callback — schedules render on background thread.
        func scheduleRender() {
            os_unfair_lock_lock(&renderLock)
            let pending = renderPending
            renderPending = true
            os_unfair_lock_unlock(&renderLock)
            guard !pending else { return }

            renderQueue.async { [weak self] in
                self?.renderAndPresent()
            }
        }

        /// Runs on renderQueue — renders mpv frame to CVPixelBuffer, enqueues to AVSampleBufferDisplayLayer.
        /// No OpenGL, no vsync blocking. ~3ms per frame vs 15-31ms with GL.
        private func renderAndPresent() {
            os_unfair_lock_lock(&renderLock)
            renderPending = false
            os_unfair_lock_unlock(&renderLock)

            guard let mpvGL else { return }
            let w = renderWidth
            let h = renderHeight
            let bufIdx = currentBufferIndex
            guard w > 0, h > 0, let pixelBuffer = pixelBuffers[bufIdx] else { return }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                return
            }
            var stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            var size: [CInt] = [CInt(w), CInt(h)]

            // "bgr0" = B,G,R,padding — matches kCVPixelFormatType_32BGRA on little-endian ARM.
            // MPV_RENDER_PARAM_SW_FORMAT expects char* (data points to the string directly).
            withUnsafeMutablePointer(to: &size[0]) { sizePtr in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    "bgr0".withCString { fmtCStr in
                        var params: [mpv_render_param] = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizePtr),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: fmtCStr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePtr),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: baseAddress),
                            mpv_render_param()
                        ]
                        mpv_render_context_render(mpvGL, &params)
                    }
                }
            }

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            // Flip double buffer for next frame
            currentBufferIndex = 1 - bufIdx

            #if os(iOS)
            // iOS: enqueue CMSampleBuffer to AVSampleBufferDisplayLayer (PiP-compatible)
            if let sampleBuffer = Self.makeSampleBuffer(from: pixelBuffer) {
                let layer = sampleBufferLayer
                DispatchQueue.main.async {
                    layer?.enqueue(sampleBuffer)
                }
            }
            #else
            // tvOS: direct IOSurface display via CALayer.contents (simpler, proven path)
            nonisolated(unsafe) let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
            let layer = displayLayer
            DispatchQueue.main.async {
                layer?.contents = surface
            }
            #endif

            mpv_render_context_report_swap(mpvGL)
        }

        func stop() {
            isShuttingDown = true
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

            Task { @MainActor in NowPlayingBridge.shared.teardown() }

            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
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

            #if DEBUG
            checkError(mpv_request_log_messages(mpv, "warn"))
            #else
            checkError(mpv_request_log_messages(mpv, "no"))
            #endif

            checkError(mpv_set_option_string(mpv, "subs-match-os-language", "yes"))
            checkError(mpv_set_option_string(mpv, "subs-fallback", "yes"))

            // vo=libmpv: app drives rendering via software render API.
            // Background thread renders to CVPixelBuffer; main thread displays via CALayer.contents.
            // No OpenGL, no GL→Metal translation overhead, no rotation bugs.
            checkError(mpv_set_option_string(mpv, "vo", "libmpv"))
            checkError(mpv_set_option_string(mpv, "profile", "fast"))  // Disable expensive post-processing for mobile

            #if targetEnvironment(simulator)
            checkError(mpv_set_option_string(mpv, "hwdec", "no"))
            #else
            // videotoolbox-copy: hardware decode on GPU, then copy frame to CPU memory
            // for the SW render API. Pure "videotoolbox" outputs GPU textures which the
            // SW renderer can't read, causing fallback to full software decoding.
            checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox-copy"))
            checkError(mpv_set_option_string(mpv, "hwdec-software-fallback", "600"))  // Live MPEG-TS joins mid-GOP without SPS/PPS — VT errors until keyframe arrives
            #endif

            checkError(mpv_set_option_string(mpv, "cache-pause-wait", "2"))  // Buffer 2s before starting playback

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

            // ── Post-init: create software render context ──
            let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String)
            var renderParams = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param()
            ]
            let renderCreateResult = mpv_render_context_create(&mpvGL, mpv, &renderParams)

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
            print("[MPV-DIAG] setupMPV: SW render context created ✓")
            #endif

            // When mpv has a new frame, schedule render on background thread.
            // SW render writes to CVPixelBuffer; main thread displays via CALayer.contents.
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
            mpv_set_property_string(mpv, "demuxer-max-bytes", "50MiB")

            if isLive {
                // cache-pause stays "yes" initially — switched to "no" after playback-restart
                // so mpv builds an initial 2s buffer before starting playback.
                mpv_set_property_string(mpv, "cache-secs", String(format: "%.1f", cachingSecs))
                mpv_set_property_string(mpv, "demuxer-max-back-bytes", "0")
                mpv_set_property_string(mpv, "demuxer-donate-buffer", "no")
                mpv_set_property_string(mpv, "demuxer-lavf-probe-info", "nostreams")
                mpv_set_property_string(mpv, "demuxer-lavf-analyzeduration", "0")
            } else {
                mpv_set_property_string(mpv, "demuxer-max-back-bytes", "10MiB")
            }

            mpv_set_property_string(mpv, "framedrop", "decoder")
            mpv_set_property_string(mpv, "video-sync", "audio")
            mpv_set_property_string(mpv, "audio-buffer", "1.5")

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
            print("[MPV-DIAG] ✓ mpv fully initialized: vo=libmpv (SW render), hwdec=videotoolbox-copy (requested)")
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
                        // Auto-resume VOD from saved position (once per session)
                        if !self.isLive, !self.hasAttemptedResume, let mpv = self.mpv,
                           let vodID = self.progressStore.vodID {
                            self.hasAttemptedResume = true
                            // Get resume position on MainActor, then seek on mpvQueue
                            Task { @MainActor [weak self] in
                                guard let resumeMs = WatchProgressManager.getResumePosition(vodID: vodID),
                                      resumeMs > 0 else { return }
                                let secs = String(format: "%.3f", Double(resumeMs) / 1000.0)
                                self?.mpvQueue.async {
                                    guard let self, let mpv = self.mpv else { return }
                                    self.mpvCommand(mpv, ["seek", secs, "absolute"])
                                }
                                debugLog("📼 VOD resume: seeking to \(resumeMs)ms")
                            }
                        }
                        #if DEBUG
                        if let mpv = self.mpv {
                            var cacheDur: Double = 0
                            mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &cacheDur)
                            var avsync: Double = 0
                            mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)

                            // Stream params are now populated (unlike at FILE_LOADED)
                            let videoCodec = self.getMPVString(mpv, "video-codec") ?? "?"
                            let audioCodec = self.getMPVString(mpv, "audio-codec") ?? "?"
                            let hwdecCurrent = self.getMPVString(mpv, "hwdec-current") ?? "none"
                            let videoFormat = self.getMPVString(mpv, "video-params/pixelformat") ?? "?"
                            var videoW: Int64 = 0; var videoH: Int64 = 0
                            mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &videoW)
                            mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &videoH)
                            var sampleRate: Int64 = 0; var channels: Int64 = 0
                            mpv_get_property(mpv, "audio-params/samplerate", MPV_FORMAT_INT64, &sampleRate)
                            mpv_get_property(mpv, "audio-params/channel-count", MPV_FORMAT_INT64, &channels)

                            print("[MPV-DIAG] Event: playback-restart — cache=\(String(format: "%.2f", cacheDur))s, avsync=\(String(format: "%.4f", avsync))s")
                            print("[MPV-STREAM] video=\(videoCodec) \(videoW)×\(videoH) \(videoFormat), hwdec=\(hwdecCurrent)")
                            print("[MPV-STREAM] audio=\(audioCodec) \(sampleRate)Hz \(channels)ch")
                        }
                        #endif
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

                // Prevent screensaver/idle timer during playback
                DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
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
                        Task { @MainActor in
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
                        Task { @MainActor in NowPlayingBridge.shared.updateElapsed(timePos, rate: 0.0) }
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
                            let finished = durMs > 0 && posMs > Int32(Double(durMs) * 0.9)
                            Task { @MainActor in
                                WatchProgressManager.save(
                                    vodID: vodID, title: title, positionMs: posMs,
                                    durationMs: durMs, posterURL: poster, isFinished: finished
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

            #if DEBUG
            let ts = logTimestamp
            let ms = Int32(timeSec * 1000)
            print("[\(ts)] [MPV-DIAG] time=\(ms)ms isPlaying=\(isPlaying) callbacks/\(isLive ? 15 : 5)s=\(timeChangeCount)")
            print("[\(ts)] [MPV-PERF] vo_drops: +\(deltaVideoDrops), dec_drops: +\(deltaDecoderDrops), fps: \(String(format: "%.1f", estimatedFPS))/\(String(format: "%.1f", displayFPS))disp, hwdec=\(hwdecCurrent)")
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

            // Update Now Playing elapsed time
            let rate: Float = isPlaying ? 1.0 : 0.0
            Task { @MainActor in
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
        private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
            var formatDesc: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard status == noErr, let desc = formatDesc else { return nil }

            var timingInfo = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 60),  // 60fps frame duration
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
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
        }

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            debugLog("🖼️ PiP: stopped")
        }
    }
}
#endif // canImport(Libmpv)
