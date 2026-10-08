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
///
/// AVPlayer tiles (`AVPlayerMultiviewTile`) do not register here: they
/// follow a simpler ownership rule (see `HeadlessPlaybackController`):
/// in the background with a car connected the headless engine owns audio,
/// in the foreground the tile does, and the tile yields or defers itself.
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

/// Plays a live channel with no SwiftUI player view mounted (CarPlay with
/// the phone locked, or the app launched by the car alone).
///
/// The full player (engine + `AVAudioSession` activation + Now Playing)
/// lives inside the SwiftUI tile, which only renders in a foreground
/// `UIWindowScene`. In a car the phone is usually locked, so this
/// controller drives its own engine straight from `CarPlaySceneDelegate`.
///
/// Engine (2026-10-07): the AVPlayer live path, routed exactly like the
/// foreground tile (`PlayerSession.resolveEngine`): direct HLS plays
/// straight into AVPlayer, raw MPEG-TS goes through the on-device
/// `TSHLSRemuxer` loopback playlist. Audio only (no layer, external
/// playback off) unless the car session supports video and the stream is
/// direct HLS. The legacy audio-only mpv engine is kept as a fallback
/// behind `PlaybackFeatureFlags.mpvEngineEnabled` for what AVPlayer cannot
/// take: live channels the resolver sends to mpv (formats that are neither
/// HLS nor MPEG-TS, or the AVPlayer toggles switched off) and TS sources
/// the remuxer's codec gate rejects (MPEG-2 video, MP2 audio, HEVC after a
/// mid-stream source switch).
///
/// Ownership rules (no double audio):
/// 1. Only starts with CarPlay connected, no foreground app scene, and no
///    mounted mpv coordinator.
/// 2. A foreground view engine starting (mpv coordinator mount, AVPlayer
///    tile start) calls `yieldToViewEngine()` first.
/// 3. An AVPlayer tile that starts while the app is in the background and
///    this controller is active defers itself to the next foreground.
/// 4. A live AVPlayer tile going to the background with a car connected
///    quiesces and hands its channel here (`takeOverFromBackgroundedView`).
@MainActor
final class HeadlessPlaybackController: ObservableObject {
    static let shared = HeadlessPlaybackController()

    /// The channel the car is playing, for the phone's CarPlay dock card and
    /// the CarPlay list's playing indicator. nil when the car owns nothing.
    @Published private(set) var carItem: ChannelDisplayItem?
    /// User pause state of the car session (card / sheet play-pause glyph).
    @Published private(set) var carPaused = false

    /// The active engine. A two-case enum instead of a shared protocol ON
    /// PURPOSE: a @MainActor protocol conformance infers main-actor isolation
    /// onto the conforming class, which planted a runtime isolation assert
    /// inside HeadlessMPVAudioEngine's private-queue setup path and crashed
    /// the app on every CarPlay channel tap (EXC_BREAKPOINT in
    /// dispatch_assert_queue, found 2026-08-08 in the CarPlay Simulator).
    private enum Engine {
        case mpv(HeadlessMPVAudioEngine)
        case avPlayer(HeadlessAVPlayerEngine)

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
        var name: String {
            if case .avPlayer = self { return "AVPlayer" }
            return "mpv"
        }
    }

    private var engine: Engine? {
        didSet {
            let active = engine != nil
            if active != activeSubject.value { activeSubject.send(active) }
            if !active, carItem != nil { carItem = nil }
        }
    }
    /// Emits whether the car (headless engine) owns audio. AVPlayer tiles
    /// mute themselves while it is true and unmute when it drops.
    let activeSubject = CurrentValueSubject<Bool, Never>(false)
    private var currentItem: ChannelDisplayItem?
    private var currentItemID: String? { currentItem?.id }
    private var isPaused = false
    private var pausedAt: Date?
    /// Whether the connected car session can present video (CarPlay video
    /// entitlement + car support, iOS 26.4+). Set by the scene delegate at
    /// connect; kept so re-tunes and take-overs make the same choice.
    var videoCapable = false
    /// Index into the channel's `streamURLs` for the failover walk, and the
    /// number of attempts made for the current channel.
    private var attempt = 0
    private var healthySince: Date?
    private var retryWork: DispatchWorkItem?
    /// Tracks the audio-session refcount we own, decoupled from `engine`
    /// existence because a mid-session engine swap (AVPlayer <-> mpv)
    /// destroys and recreates `engine` without releasing the session.
    private var ownsAudioSession = false
    /// Advances the Now Playing program timeline while headless (there is no
    /// perf pump calling `updateElapsed` when no view is mounted).
    private var elapsedTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// True while a headless engine owns playback.
    var isActive: Bool { engine != nil }

    private init() {
        // Re-tune when the active channel changes (CarPlay next/previous track,
        // or a re-tap in the list) WHILE we own the engine.
        NowPlayingManager.shared.$playingItem
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                MainActor.assumeIsolated {
                    guard let self, self.engine != nil, let item else { return }
                    if item.id != self.currentItemID {
                        self.start(item: item, server: ChannelStore.shared.activeServer,
                                   isLive: true, videoCapable: self.videoCapable)
                    }
                }
            }
            .store(in: &cancellables)

        // Phone call / Siri / navigation prompt: AVPlayer and mpv both go
        // quiet on interruption. A live stream resumed from where it paused
        // would replay stale audio or stall on an expired window, so a
        // resumable end re-tunes the channel at the live edge.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated { self?.handleInterruption(note) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.engine != nil else { return }
                    debugLog("[CARPLAY] error: media services were reset; re-tuning")
                    self.retune(reason: "media services reset")
                }
            }
            .store(in: &cancellables)
    }

    /// True when a foreground app `UIWindowScene` exists, i.e. the phone app
    /// is on screen and the SwiftUI player will mount and own playback. Car
    /// window scenes (`UIWindowSceneSessionRoleCarPlay`) are not the phone UI
    /// and never count.
    static func hasForegroundPlayerScene() -> Bool {
        UIApplication.shared.connectedScenes.contains {
            $0.session.role == .windowApplication
                && ($0 as? UIWindowScene)?.activationState == .foregroundActive
        }
    }

    /// Start (or re-tune to) a channel headlessly. Runs whenever CarPlay is
    /// connected, whatever the phone app's state (field test 2026-10-08:
    /// a car tap with the phone app on screen used to hand playback to the
    /// phone's player and leave the car silent). While it runs the car owns
    /// audio and any AVPlayer tile on the phone renders video muted. Only a
    /// mounted legacy mpv coordinator (which cannot be muted from here)
    /// blocks it.
    func start(item: ChannelDisplayItem, server: ServerConnection?, isLive: Bool,
               videoCapable: Bool = false) {
        guard NowPlayingManager.shared.isCarPlayConnected,
              !PlaybackEngineRegistry.shared.hasLiveCoordinator
        else {
            debugLog("[CARPLAY] engine: headless not started for \(item.name): carplay=\(NowPlayingManager.shared.isCarPlayConnected) fgScene=\(Self.hasForegroundPlayerScene()) mpvCoordinators=\(PlaybackEngineRegistry.shared.liveCoordinatorCount) (view engine owns playback)")
            return
        }

        // Already playing this channel: nothing to do (idempotent for the
        // playChannel + $playingItem observer both firing).
        if engine != nil, currentItemID == item.id { return }

        self.videoCapable = videoCapable
        if !ownsAudioSession {
            AudioSessionRefCount.increment(caller: "carplay-headless")
            ownsAudioSession = true
        }
        currentItem = item
        carItem = item
        carPaused = false
        attempt = 0
        healthySince = nil
        isPaused = false
        pausedAt = nil
        tune(server: server)

        // Complete Now Playing: title / program subtitle / channel logo /
        // program-relative timeline, plus play-pause + next/prev commands.
        // Next/previous from the car or lock screen flip the CAR's channel
        // here; the phone's changeChannel path would need a phone session,
        // which never exists while the car owns playback.
        let subtitle = item.currentProgram?.trimmingCharacters(in: .whitespacesAndNewlines)
        NowPlayingBridge.shared.configure(
            title: item.name,
            subtitle: (subtitle?.isEmpty == false) ? subtitle : item.group,
            artworkURL: item.logoURL,
            duration: nil,
            isLive: isLive,
            programStart: item.currentProgramStart,
            programEnd: item.currentProgramEnd,
            onPlay: { [weak self] in self?.setPaused(false) },
            onPause: { [weak self] in self?.setPaused(true) },
            onSeek: nil,
            onFlipChannel: { [weak self] dir in self?.flipChannel(dir) }
        )
        startElapsedTimer()
    }

    // MARK: Phone-side controls (CarPlay dock card / sheet)

    func togglePause() {
        debugLog("[CARPLAY] card: play/pause (paused=\(isPaused) -> \(!isPaused))")
        setPaused(!isPaused)
    }

    /// Step the car's channel through the active playlist's channel list
    /// (same order as the phone's channel up/down).
    func flipChannel(_ direction: Int) {
        guard let current = currentItem else { return }
        let list = ChannelStore.shared.channels
        guard let idx = list.firstIndex(where: { $0.id == current.id }) else { return }
        let next = list[max(0, min(list.count - 1, idx + direction))]
        guard next.id != current.id else { return }
        debugLog("[CARPLAY] tune: flip \(direction > 0 ? "+1" : "-1") \(current.name) -> \(next.name)")
        start(item: next, server: ChannelStore.shared.activeServer, isLive: true,
              videoCapable: videoCapable)
    }

    /// Phone card X / sheet Stop: end the car session.
    func stopFromPhone() {
        debugLog("[CARPLAY] card: stop from phone")
        stop()
    }

    /// A live AVPlayer tile is leaving the screen (phone locked or app
    /// switched) with a car connected. The tile has already quiesced; pick
    /// its channel up here so the car keeps playing.
    func takeOverFromBackgroundedView(reason: String) {
        guard NowPlayingManager.shared.isCarPlayConnected,
              let item = NowPlayingManager.shared.playingItem else { return }
        guard engine == nil || currentItemID != item.id else { return }
        debugLog("[CARPLAY] engine: headless take-over from view (\(reason)) channel=\(item.name)")
        start(item: item, server: ChannelStore.shared.activeServer, isLive: true,
              videoCapable: videoCapable)
    }

    /// A view engine is taking over (phone foregrounded / unlocked). Stop
    /// the headless engine but DON'T tear down Now Playing: the mounting
    /// view re-arms the bridge itself, so the lock-screen/CarPlay chrome
    /// never flickers.
    func yieldToViewEngine() {
        guard engine != nil else { return }
        debugLog("[CARPLAY] yield: headless \(engine?.name ?? "?") engine stops, view engine takes over channel=\(currentItem?.name ?? "?")")
        shutDownEngine()
    }

    /// Full teardown (CarPlay disconnect, or a global stop/exit). Clears Now
    /// Playing only if we still own the engine.
    func stop() {
        guard engine != nil else { return }
        debugLog("[CARPLAY] teardown: headless \(engine?.name ?? "?") engine stopped channel=\(currentItem?.name ?? "?")")
        shutDownEngine()
        NowPlayingBridge.shared.teardown()
    }

    private func shutDownEngine() {
        retryWork?.cancel()
        retryWork = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        engine?.stop()
        engine = nil
        currentItem = nil
        if ownsAudioSession {
            ownsAudioSession = false
            AudioSessionRefCount.decrement(caller: "carplay-headless")
        }
    }

    // MARK: Tune / failover

    /// Resolve the current channel (with the failover walk's URL) the same
    /// way the foreground tile does, and play it on the matching engine.
    private func tune(server: ServerConnection?, forceMPV: Bool = false) {
        guard var item = currentItem else { return }
        let urls = item.streamURLs
        if attempt > 0, !urls.isEmpty {
            item.streamURL = urls[attempt % urls.count]
        }
        var resolved = PlayerSession.resolveEngine(item: item, server: server, isLive: true)
        // CarPlay video: every MPEG-TS channel goes through the remuxer so
        // the car can be served its credential-free LAN playlist, including
        // channels the resolver would upgrade to Dispatcharr HLS (Force HLS
        // or a cached probe). The car cannot present our auth headers or the
        // HLS session token (cp3 00:26:30: 404 after external playback).
        if videoCapable, !forceMPV, PlaybackFeatureFlags.avPlayerRemuxTS,
           let raw = item.streamURL ?? item.streamURLs.first,
           classifyStreamURL(raw) == .mpegTS, resolved.engine != .avPlayerRemuxTS {
            debugLog("[CARPLAY] video: \(item.name) routed through the TS remuxer for LAN delivery (resolver said \(resolved.engine))")
            resolved = ResolvedEngine(engine: .avPlayerRemuxTS, routeURL: raw, headers: resolved.headers)
        }
        let useMPV = forceMPV || resolved.engine == .mpv
        // Host logged, never the full URL (stream URLs can carry query
        // credentials): the cold-car failure to catch is a LAN host handed
        // to a cellular-only phone.
        debugLog("[CARPLAY] tune: channel=\(item.name) attempt=\(attempt + 1) route=\(resolved.engine) scheme=\(resolved.routeURL.scheme ?? "?") host=\(resolved.routeURL.host ?? "?") video=\(videoCapable && !useMPV)")

        if useMPV {
            guard PlaybackFeatureFlags.mpvEngineEnabled else {
                debugLog("[CARPLAY] error: \(item.name) needs the mpv fallback but the mpv engine is disabled; nothing to play")
                return
            }
            if case .mpv(let e)? = engine {
                e.play(url: resolved.routeURL, headers: resolved.headers)
            } else {
                engine?.stop()
                let e = HeadlessMPVAudioEngine()
                engine = .mpv(e)
                debugLog("[CARPLAY] engine: mpv audio-only (fallback) channel=\(item.name)")
                e.play(url: resolved.routeURL, headers: resolved.headers)
            }
            return
        }

        let av: HeadlessAVPlayerEngine
        if case .avPlayer(let e)? = engine {
            av = e
        } else {
            engine?.stop()
            av = HeadlessAVPlayerEngine()
            av.onFailure = { [weak self] failure in
                self?.handleAVPlayerFailure(failure)
            }
            av.onPlaying = { [weak self] in
                guard let self, self.healthySince == nil else { return }
                self.healthySince = Date()
            }
            engine = .avPlayer(av)
        }
        debugLog("[CARPLAY] engine: AVPlayer \(resolved.engine == .avPlayerDirectHLS ? "direct HLS" : "TS remux loopback") channel=\(item.name)")
        // Video for the remux path (LAN playlist) and for genuine HLS sources
        // that need no headers. Dispatcharr direct HLS never reaches here in
        // video mode (rerouted above).
        let video = videoCapable && (resolved.engine == .avPlayerRemuxTS
            || (resolved.engine == .avPlayerDirectHLS && resolved.headers["X-API-Key"] == nil))
        av.play(resolved, allowsVideo: video)
    }

    private func handleAVPlayerFailure(_ failure: HeadlessAVPlayerEngine.Failure) {
        guard engine != nil, let item = currentItem else { return }
        // A stream that played for a minute earns a fresh failover budget;
        // without the reset one blip an hour into a drive would exhaust it.
        if let since = healthySince, Date().timeIntervalSince(since) > 60 {
            attempt = 0
        }
        healthySince = nil
        switch failure {
        case .codec(let codec):
            debugLog("[CARPLAY] error: AVPlayer cannot take \(item.name) (\(codec)); mpv fallback=\(PlaybackFeatureFlags.mpvEngineEnabled)")
            tune(server: ChannelStore.shared.activeServer, forceMPV: true)
        case .playback(let message):
            let budget = max(2, item.streamURLs.count)
            attempt += 1
            guard attempt < budget else {
                debugLog("[CARPLAY] error: \(item.name) failed after \(attempt) attempts (\(message)); mpv fallback=\(PlaybackFeatureFlags.mpvEngineEnabled)")
                if PlaybackFeatureFlags.mpvEngineEnabled {
                    tune(server: ChannelStore.shared.activeServer, forceMPV: true)
                }
                return
            }
            debugLog("[CARPLAY] error: \(item.name) \(message); failover attempt \(attempt + 1)/\(budget) in 2 s")
            retryWork?.cancel()
            let id = item.id
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.engine != nil, self.currentItemID == id else { return }
                    self.tune(server: ChannelStore.shared.activeServer)
                }
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// Re-tune the current channel from scratch (live edge).
    private func retune(reason: String) {
        guard engine != nil, currentItem != nil else { return }
        debugLog("[CARPLAY] tune: re-tune current channel (\(reason))")
        engine?.stop()
        engine = .none
        carItem = currentItem
        attempt = 0
        healthySince = nil
        isPaused = false
        carPaused = false
        pausedAt = nil
        tune(server: ChannelStore.shared.activeServer)
    }

    private func handleInterruption(_ note: Notification) {
        guard engine != nil,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            debugLog("[CARPLAY] interruption began channel=\(currentItem?.name ?? "?")")
        case .ended:
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            debugLog("[CARPLAY] interruption ended shouldResume=\(shouldResume) userPaused=\(isPaused)")
            guard shouldResume, !isPaused else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            retune(reason: "interruption ended")
        @unknown default:
            break
        }
    }

    private func setPaused(_ paused: Bool) {
        guard let engine else { return }
        // Live: a resume after more than 30 s paused goes back to the live
        // edge instead of playing a stale (or expired) window.
        if !paused, isPaused, let at = pausedAt, Date().timeIntervalSince(at) > 30 {
            debugLog("[CARPLAY] tune: resume after \(Int(Date().timeIntervalSince(at))) s paused, back to live")
            retune(reason: "resume after long pause")
            NowPlayingBridge.shared.updateElapsed(0, rate: 1.0)
            return
        }
        isPaused = paused
        carPaused = paused
        pausedAt = paused ? Date() : nil
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

/// Headless AVPlayer engine for CarPlay, on the same live path as the
/// foreground tile: direct HLS straight into AVPlayer, raw MPEG-TS through
/// `TSHLSRemuxer` (loopback or in-process delivery, chosen by the remuxer
/// exactly as for the tile). No layer is attached. External playback is off
/// unless the car session supports video and the stream is direct HLS, in
/// which case the car can take the video surface while parked and the same
/// player keeps supplying audio when it cannot (CarPlay's rule).
@MainActor
final class HeadlessAVPlayerEngine {
    enum Failure {
        /// The remuxer's codec gate refused the source: AVPlayer cannot take it.
        case codec(String)
        /// Ingest, item or stall failure: worth a failover attempt.
        case playback(String)
    }

    var onFailure: ((Failure) -> Void)?
    var onPlaying: (() -> Void)?

    private var player: AVPlayer?
    private var remuxer: TSHLSRemuxer?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var externalObservation: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    /// Bumped on every play/stop so late callbacks from a torn-down
    /// pipeline are ignored.
    private var token = UUID()
    private var silenceStarted: Date?
    private var silenceLogged = false
    /// CarPlay video: the head unit is served the remuxer's LAN playlist.
    private var lanURL: URL?
    private var keepaliveHeld = false
    private var itemReissues = 0
    static let keepaliveHolder = "carplay-video"

    func play(_ resolved: ResolvedEngine, allowsVideo: Bool) {
        teardownPipeline()
        token = UUID()
        let t = token
        switch resolved.engine {
        case .avPlayerDirectHLS, .mpv:
            startPlayer(url: resolved.routeURL, headers: resolved.headers, allowsVideo: allowsVideo)
        case .avPlayerRemuxTS:
            let mux = TSHLSRemuxer(sourceURL: resolved.routeURL, headers: resolved.headers)
            mux.reportsIngestStall = true
            // Remuxer callbacks are delivered on the main queue.
            mux.onReady = { [weak self] localURL in
                MainActor.assumeIsolated {
                    guard let self, self.token == t else { return }
                    guard allowsVideo else {
                        debugLog("[CARPLAY] engine: remux ready, audio only on loopback \(localURL.scheme ?? "?")://\(localURL.host ?? "")")
                        self.startPlayer(url: localURL, headers: [:], allowsVideo: false)
                        return
                    }
                    self.startLANVideo(mux: mux, loopbackURL: localURL, token: t)
                }
            }
            mux.onError = { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self, self.token == t else { return }
                    if case .unsupportedCodec(let codec) = error {
                        self.fail(.codec(codec))
                    } else {
                        self.fail(.playback("\(error)"))
                    }
                }
            }
            // Dispatcharr's proxy delivers in bursts, so 2 to 6 s of socket
            // silence between bursts is normal (cp2 2026-10-08 00:13:18 to
            // :28, every gap closed by the next burst; the TS-REMUX lines
            // still record each one). Only a gap that outlasts 10 s is worth
            // a CarPlay line, and its recovery is logged only after it.
            mux.onIngestSilence = { [weak self] silent in
                MainActor.assumeIsolated {
                    guard let self, self.token == t else { return }
                    if silent {
                        self.silenceStarted = Date()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self, self.token == t, let since = self.silenceStarted,
                                      !self.silenceLogged else { return }
                                self.silenceLogged = true
                                debugLog("[CARPLAY] engine: remux ingest silent for \(Int(Date().timeIntervalSince(since)) + 2) s")
                            }
                        }
                    } else {
                        if self.silenceLogged, let since = self.silenceStarted {
                            debugLog("[CARPLAY] engine: remux ingest flowing again after \(Int(Date().timeIntervalSince(since)) + 2) s")
                        }
                        self.silenceStarted = nil
                        self.silenceLogged = false
                    }
                }
            }
            mux.onIngestClosed = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.token == t else { return }
                    self.fail(.playback("upstream closed the stream"))
                }
            }
            if allowsVideo {
                mux.onLANFirstRequest = { peer in
                    debugLog("[CARPLAY] video: receiver first request from \(peer)")
                }
            }
            remuxer = mux
            mux.start()
        }
    }

    /// CarPlay video (2026-10-08, cp3): with external playback the HEAD UNIT
    /// fetches the item URL itself, and AVURLAsset's header option never
    /// leaves the phone, so a Dispatcharr URL that needs X-API-Key / the
    /// HLS session token cannot be fetched by the car. Serve the car the
    /// remuxer's LAN playlist instead (the AirPlay listener: muxed TS,
    /// keep-alive HTTP, LAN hold-back), which needs no credentials and
    /// works for every TS channel. No LAN address: audio only on loopback.
    private func startLANVideo(mux: TSHLSRemuxer, loopbackURL: URL, token t: UUID) {
        mux.startLANDelivery { [weak self] result in
            guard let self, self.token == t else { return }
            switch result {
            case .ready(let ip, let port):
                guard let url = URL(string: "http://\(ip):\(port)/live.m3u8") else {
                    debugLog("[CARPLAY] video: bad LAN url; audio only on loopback")
                    self.startPlayer(url: loopbackURL, headers: [:], allowsVideo: false)
                    return
                }
                self.lanURL = url
                debugLog("[CARPLAY] video: lan url \(url.absoluteString)")
                if !self.keepaliveHeld {
                    // External playback leaves no local audio render, so
                    // the process needs the keepalive AirPlay uses.
                    self.keepaliveHeld = true
                    BackgroundKeepalive.acquire(Self.keepaliveHolder)
                }
                self.startPlayer(url: url, headers: [:], allowsVideo: true)
            default:
                debugLog("[CARPLAY] video: LAN delivery unavailable (\(result)); audio only on loopback")
                self.startPlayer(url: loopbackURL, headers: [:], allowsVideo: false)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        paused ? player?.pause() : player?.play()
    }

    func stop() {
        token = UUID()
        teardownPipeline()
    }

    private func fail(_ failure: Failure) {
        // One report per pipeline: invalidate before handing it up so a
        // second callback from the same dying pipeline is dropped.
        token = UUID()
        teardownPipeline()
        onFailure?(failure)
    }

    private func teardownPipeline() {
        statusObservation = nil
        timeControlObservation = nil
        externalObservation = nil
        if let obs = failedToEndObserver {
            NotificationCenter.default.removeObserver(obs)
            failedToEndObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        lanURL = nil
        itemReissues = 0
        if keepaliveHeld {
            keepaliveHeld = false
            BackgroundKeepalive.release(Self.keepaliveHolder)
        }
        if let mux = remuxer {
            mux.onLANFirstRequest = nil
            mux.onReady = nil
            mux.onError = nil
            mux.onIngestSilence = nil
            mux.onIngestClosed = nil
            mux.stop()
            remuxer = nil
        }
    }

    /// A failed item while the car is fetching the LAN playlist is usually
    /// the receiver, not the pipeline (the remuxer is still ingesting):
    /// hand it a fresh item on the SAME LAN URL (AirPlay's reissue) up to
    /// twice before a full failover, so the retry never tears the
    /// listener out from under the car's fetch.
    private func itemFailed(_ message: String) {
        if let url = lanURL, remuxer != nil, itemReissues < 2 {
            itemReissues += 1
            debugLog("[CARPLAY] external playback: item failed (\(message)); reissuing on the same LAN url (\(itemReissues)/2)")
            statusObservation = nil
            timeControlObservation = nil
            externalObservation = nil
            if let obs = failedToEndObserver {
                NotificationCenter.default.removeObserver(obs)
                failedToEndObserver = nil
            }
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            startPlayer(url: url, headers: [:], allowsVideo: true)
            return
        }
        fail(.playback(message))
    }

    private func startPlayer(url: URL, headers: [String: String], allowsVideo: Bool) {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        if url.scheme == HLSDelivery.scheme {
            asset.resourceLoader.setDelegate(HLSResourceLoaderRegistry.shared,
                                             queue: HLSResourceLoaderRegistry.shared.queue)
        }
        let item = AVPlayerItem(asset: asset)
        // Same live-edge policy as the tile: trust the server's join point.
        item.automaticallyPreservesTimeOffsetFromLive = true
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = allowsVideo
        p.usesExternalPlaybackWhileExternalScreenIsActive = allowsVideo
        // No layer and a locked phone: keep decoding audio in the background.
        p.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        let t = token
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "unknown item error"
            Task { @MainActor in
                guard let self, self.token == t else { return }
                self.itemFailed("item failed: \(message)")
            }
        }
        timeControlObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor in
                guard let self, self.token == t else { return }
                self.onPlaying?()
            }
        }
        if allowsVideo {
            externalObservation = p.observe(\.isExternalPlaybackActive, options: [.new]) { _, change in
                // The line that proves the car took the video surface.
                debugLog("[CARPLAY] external playback active=\(change.newValue ?? false)")
            }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak self] note in
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "failed to play to end"
            MainActor.assumeIsolated {
                guard let self, self.token == t else { return }
                self.itemFailed(err)
            }
        }
        player = p
        p.play()
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
    /// The +1 reference handed to mpv as the wakeup-callback context.
    /// Touched only on `queue`.
    private var callbackContext: Unmanaged<HeadlessMPVAudioEngine>?
    /// Bumped by stop() so a delayed reload scheduled before it is dropped.
    private var retryGeneration = 0

    func play(url: URL, headers: [String: String]) {
        queue.async { [self] in
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
        // STRONG capture on purpose (TestFlight 1.8.9 crash, thread 11:
        // objc_msgSend in dispatch_async from the wakeup closure, called on
        // mpv's core thread from reinit_audio_chain_src). This block used to
        // capture [weak self]; every caller drops its last reference right
        // after calling stop(), so self was already nil when the block ran,
        // the guard returned, and mpv was never destroyed: its core thread
        // kept loading the file and fired the wakeup callback with an
        // unretained pointer to the freed engine. Holding self here
        // guarantees the callback is detached and the handle destroyed.
        queue.async { [self] in
            self.retryGeneration &+= 1
            guard let mpv = self.mpv else { return }
            self.mpv = nil
            self.currentURL = nil
            // Detach the wakeup callback BEFORE destroy, then release the
            // retained context it carried (setup's passRetained).
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
            self.callbackContext?.release()
            self.callbackContext = nil
        }
    }

    private func setup(headers: [String: String]) {
        // Close the same first-load registration race the coordinator guards
        // against (loadfile before libmpv's global codec/protocol init).
        MPVLibraryWarmup.waitUntilComplete()

        guard let handle = mpv_create() else {
            debugLog("[CARPLAY] error: mpv_create failed")
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
            debugLog("[CARPLAY] error: mpv_initialize failed: \(String(cString: mpv_error_string(initResult)))")
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
        // The context is RETAINED for as long as the handle lives and
        // released in stop() only after mpv_set_wakeup_callback(nil) and
        // mpv_terminate_destroy, so a wakeup from mpv's core thread can
        // never reach a freed engine (the 1.8.9 thread-11 crash).
        let context = Unmanaged.passRetained(self)
        callbackContext = context
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let engine = Unmanaged<HeadlessMPVAudioEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.queue.async { engine.drainEvents() }
        }, context.toOpaque())
        debugLog("[CARPLAY] engine: mpv initialized (audio-only)")
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
                debugLog("[CARPLAY] engine: mpv stream loaded, audio starting")
                retriedCurrentLoad = false
            case MPV_EVENT_END_FILE:
                let end = ev.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                let isError = end.reason == MPV_END_FILE_REASON_ERROR
                let reason = isError
                    ? String(cString: mpv_error_string(end.error))
                    : "reason=\(end.reason.rawValue)"
                debugLog("[CARPLAY] engine: mpv end-file: \(reason)")
                // Only self-heal genuine stream ends/errors; reason STOP (our
                // own loadfile replace / teardown) must not retrigger.
                if (isError || end.reason == MPV_END_FILE_REASON_EOF),
                   let url = currentURL, !retriedCurrentLoad {
                    retriedCurrentLoad = true
                    debugLog("[CARPLAY] engine: mpv one-shot reload after dead stream")
                    let generation = retryGeneration
                    queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.retryGeneration == generation,
                              let mpv = self.mpv, self.currentURL == url else { return }
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
#endif
