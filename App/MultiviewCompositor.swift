//
//  MultiviewCompositor.swift
//  Aerio
//
//  Phone-side Multiview composite (Logan 2026-10-06, part 2). For a
//  receiver that cannot run Multiview itself (the Chromecast web receiver,
//  any AirPlay receiver) the phone composes the grid and sends ONE stream:
//
//    tiles (the local Multiview's AVPlayers, AVPlayerItemVideoOutput)
//      -> CoreImage on Metal, 1280x720 at 30 fps, same rect table as the
//         local grid, thin borders, focused tile highlighted
//      -> VideoToolbox H.264 Main, IDR every 2 s
//    focused tile's audio (tapped from its TSHLSRemuxer ingest)
//      -> AudioToolbox decode -> AAC-LC stereo 48 kHz
//    -> one live MPEG-TS (MultiviewCompositeTSMuxer) on a loopback HTTP
//       server -> ingested like a channel by the existing pipelines:
//       Cast: CastHLSProxySession (castingContent's stream URL)
//       AirPlay: a hidden composite tile whose TSHLSRemuxer LAN playlist
//       the receiver plays (the same AirPlayTileDelivery a channel uses).
//
//  Platform encoders only (VideoToolbox, AudioToolbox). iOS only.
//

#if os(iOS)
import Foundation
import AVFoundation
import AudioToolbox
import Combine
import CoreImage
import CoreVideo
import Metal
import Network
import UIKit
import VideoToolbox

// MARK: - Tile registry

/// The live Multiview tiles the compositor reads: each tile's AVPlayerItem
/// (an AVPlayerItemVideoOutput is attached while a composite runs) and its
/// TSHLSRemuxer (whose ingest bytes are tapped for the audio). Tiles
/// register from `AVPlayerMultiviewTile.startPlayer` and leave on stop.
final class MultiviewCompositeTaps: @unchecked Sendable {
    static let shared = MultiviewCompositeTaps()
    /// The hidden tile that carries the composite to an AirPlay receiver.
    static let compositeTileID = "mv-composite-airplay"

    private struct Entry {
        weak var player: AVPlayer?
        var item: AVPlayerItem
        var output: AVPlayerItemVideoOutput?
        weak var remuxer: TSHLSRemuxer?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Set while a composite runs: (tileID, ingest bytes).
    private var sink: (@Sendable (String, Data) -> Void)?
    /// Which transport the running composite uses (read by the tile gates).
    private var transport: MultiviewCompositeSession.Transport?

    // MARK: Gates the tile reads (main thread)

    /// The tile that owns the AirPlay route: the composite tile while an
    /// AirPlay composite runs, else the audio tile.
    @MainActor static func ownsAirPlay(tileID: String) -> Bool {
        if shared.currentTransport == .airPlay { return tileID == compositeTileID }
        return MultiviewStore.shared.audioTileID == tileID
    }

    /// Mute rule: while a composite runs the phone is silent (the receiver
    /// plays the focused tile's audio) except the AirPlay composite tile,
    /// whose audio IS the receiver's.
    @MainActor static func isMuted(tileID: String, audioID: String?) -> Bool {
        if let t = shared.currentTransport {
            return !(t == .airPlay && tileID == compositeTileID)
        }
        return audioID != tileID
    }

    var currentTransport: MultiviewCompositeSession.Transport? {
        lock.lock(); defer { lock.unlock() }
        return transport
    }

    // MARK: Registration

    func register(tileID: String, player: AVPlayer, item: AVPlayerItem, remuxer: TSHLSRemuxer?) {
        guard tileID != Self.compositeTileID else { return }
        lock.lock()
        let old = entries[tileID]
        var entry = Entry(player: player, item: item, output: nil, remuxer: remuxer)
        let active = transport != nil
        let sink = self.sink
        if active, old?.item === item { entry.output = old?.output }
        entries[tileID] = entry
        if old?.item !== item { audioTapped.remove(tileID) }
        lock.unlock()
        if let o = old?.output, old?.item !== item { old?.item.remove(o) }
        guard active else { return }
        if entry.output == nil { attachOutput(tileID: tileID) }
        if let remuxer, let sink { remuxer.setIngestTap { data in sink(tileID, data) } }
        if currentTransport == .airPlay { player.allowsExternalPlayback = false }
        player.isMuted = true
    }

    func unregister(tileID: String) {
        lock.lock()
        audioTapped.remove(tileID)
        let old = entries.removeValue(forKey: tileID)
        lock.unlock()
        if let o = old?.output { old?.item.remove(o) }
        old?.remuxer?.setIngestTap(nil)
    }

    var registeredIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.keys)
    }

    /// Composite start: outputs on every tile, taps on every remuxer, the
    /// phone muted, and (AirPlay) every real tile pinned to this device.
    func activate(transport t: MultiviewCompositeSession.Transport,
                  sink s: @escaping @Sendable (String, Data) -> Void) {
        lock.lock()
        transport = t
        sink = s
        let snapshot = entries
        lock.unlock()
        for (id, e) in snapshot {
            if e.output == nil { attachOutput(tileID: id) }
            e.remuxer?.setIngestTap { data in s(id, data) }
            if t == .airPlay { e.player?.allowsExternalPlayback = false }
            e.player?.isMuted = true
        }
    }

    @MainActor func deactivate() {
        lock.lock()
        transport = nil
        sink = nil
        let snapshot = entries
        for k in entries.keys { entries[k]?.output = nil }
        lock.unlock()
        let audioID = MultiviewStore.shared.audioTileID
        detachAudioTaps(snapshot)
        pcmSink = nil
        for (id, e) in snapshot {
            if let o = e.output { e.item.remove(o) }
            e.remuxer?.setIngestTap(nil)
            e.player?.isMuted = audioID != id
        }
    }

    private func attachOutput(tileID: String) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        lock.lock()
        guard var e = entries[tileID] else { lock.unlock(); return }
        e.output = output
        entries[tileID] = e
        let item = e.item
        lock.unlock()
        item.add(output)
    }

    // MARK: Player audio taps (Android parity, 2026-10-06)

    private var audioTapped: Set<String> = []

    /// Attach an MTAudioProcessingTap to every registered tile item that
    /// has an audio track and none yet (main thread, polled while a
    /// composite runs: HLS items expose their tracks only once ready).
    @MainActor func attachAudioTaps() {
        lock.lock()
        let s = sink == nil ? nil : pcmSink
        let snapshot = entries.filter { !audioTapped.contains($0.key) }
        lock.unlock()
        guard let s else { return }
        for (id, e) in snapshot where e.item.status == .readyToPlay {
            guard let track = e.item.tracks.compactMap(\.assetTrack).first(where: { $0.mediaType == .audio })
                    ?? e.item.asset.tracks(withMediaType: .audio).first,
                  let tap = MultiviewAudioTap.make(tileID: id, sink: s) else { continue }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            e.item.audioMix = mix
            lock.lock(); audioTapped.insert(id); lock.unlock()
            debugLog("[MV-CAST] composite audio tap attached tile=\(id)")
        }
    }

    /// Set with `sink` while a composite runs.
    private var pcmSink: (@Sendable (String, [Int16], Int) -> Void)?

    func setPCMSink(_ s: (@Sendable (String, [Int16], Int) -> Void)?) {
        lock.lock(); pcmSink = s; lock.unlock()
    }

    private func detachAudioTaps(_ snapshot: [String: Entry]) {
        lock.lock(); let tapped = audioTapped; audioTapped.removeAll(); lock.unlock()
        for (id, e) in snapshot where tapped.contains(id) { e.item.audioMix = nil }
    }

    /// Why a tile has no pixels (the no-pixels diagnostic line).
    func sourceDescription(tileID: String) -> String {
        lock.lock()
        let e = entries[tileID]
        lock.unlock()
        guard let e else { return "not registered (no AVPlayer tile; mpv or not mounted)" }
        let attached = e.output.map { o in e.item.outputs.contains { $0 === o } } ?? false
        return "registered output=\(e.output != nil) attachedToItem=\(attached) item=\(e.item.status.rawValue) playerItemMatches=\(e.player?.currentItem === e.item) rate=\(e.player?.rate ?? -1)"
    }

    /// The tile's newest decoded picture, if it has a new one now.
    func newPixelBuffer(tileID: String, hostTime: CFTimeInterval) -> CVPixelBuffer? {
        lock.lock()
        let output = entries[tileID]?.output
        lock.unlock()
        guard let output else { return nil }
        let t = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }

    /// Seconds the tile's player sits behind its playlist's live edge plus
    /// half a target duration (the remuxer's unpublished tail), main thread.
    @MainActor func displayLagSeconds(tileID: String) -> Double? {
        lock.lock()
        let e = entries[tileID]
        lock.unlock()
        guard let e, let player = e.player, let item = player.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let behind = range.end.seconds - player.currentTime().seconds
        let tail = (e.remuxer?.advertisedTargetDuration.get() ?? 4) / 2
        guard behind.isFinite, behind >= 0 else { return nil }
        return behind + tail
    }
}

// MARK: - Session (main actor)

/// One composite at a time. Started by PlayWhereRouter's "Play on <device>"
/// for a receiver without native Multiview; stopped by the remote card's
/// Stop, the cast/AirPlay session ending, the local Multiview closing, or
/// the resource rules.
@MainActor
final class MultiviewCompositeSession: ObservableObject {
    static let shared = MultiviewCompositeSession()
    enum Transport: Sendable, Equatable { case cast, airPlay }
    /// castingContent.mediaID of a composite cast.
    static let castMediaID = "multiview-composite"
    static let tileLimitNote = "Up to 4 channels can be cast"
    static let fellBehindMessage = "Multiview casting stopped: the phone could not keep up"

    @Published private(set) var transport: Transport?
    @Published private(set) var channelNames: [String] = []
    /// AirPlay: the loopback TS the hidden composite tile plays.
    @Published private(set) var airPlayTileURL: URL?
    /// Scaled-down live frames of the composite (about 5 fps) for the
    /// remote controls sheet's preview grid.
    @Published fileprivate(set) var previewImage: UIImage?

    var isActive: Bool { transport != nil }
    var subtitle: String { channelNames.joined(separator: ", ") }

    private var compositor: MultiviewCompositor?
    private var cancellables: Set<AnyCancellable> = []
    private var lagTimer: Timer?
    private var tileIDs: [String] = []

    static func eligible(count: Int) -> Bool { (2...MultiviewCompositeLayout.maxTiles).contains(count) }

    @discardableResult
    func start(transport t: Transport) -> Bool {
        if transport != nil { stop(detail: "restarted", teardownTiles: false) }
        let store = MultiviewStore.shared
        let tiles = Array(store.tiles.prefix(MultiviewCompositeLayout.maxTiles))
        guard Self.eligible(count: tiles.count) else { return false }
        tileIDs = tiles.map(\.id)
        channelNames = tiles.map(\.item.name)
        let focus = store.audioTileID.flatMap { id in tileIDs.contains(id) ? id : nil } ?? tileIDs[0]
        let mode = MultiviewLayoutMode(rawValue: UserDefaults.standard.string(forKey: MultiviewLayoutMode.storageKey) ?? "") ?? .auto
        let accent = UIColor(ThemeManager.shared.accent)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        accent.getRed(&r, green: &g, blue: &b, alpha: &a)
        let comp = MultiviewCompositor(tileIDs: tileIDs, focusID: focus, mode: mode,
                                       accent: (Double(r), Double(g), Double(b)))
        comp.onPreview = { [weak self] image in
            Task { @MainActor in
                guard let self, self.compositor === comp else { return }
                self.previewImage = UIImage(cgImage: image)
            }
        }
        comp.onFailure = { [weak self] reason in
            Task { @MainActor in self?.failed(reason.0, detail: reason.1) }
        }
        guard let url = comp.start() else {
            debugLog("[MV-CAST] composite could not start (loopback server)")
            return false
        }
        compositor = comp
        transport = t
        MultiviewCompositeTaps.shared.setPCMSink { [weak comp] id, pcm, rate in
            comp?.tilePCM(tileID: id, samples: pcm, sampleRate: rate)
        }
        MultiviewCompositeTaps.shared.activate(transport: t) { [weak comp] id, data in
            comp?.tileBytes(tileID: id, data: data)
        }
        comp.setBackgrounded(UIApplication.shared.applicationState == .background)
        setKeepalive(true)
        debugLog("[MV-CAST] composite start tiles=\(tileIDs.count) \(MultiviewCompositeLayout.width)x\(MultiviewCompositeLayout.height)@\(MultiviewCompositeLayout.fps) transport=\(t == .cast ? "cast" : "airplay") focus=\(focus) url=\(url.absoluteString)")
        observe()
        switch t {
        case .cast:
            AerioCastController.shared.setContent(AerioCastController.Content(
                mediaID: Self.castMediaID, kind: .live, title: "Multiview", subtitle: subtitle,
                artURL: nil, streamURL: url, streamHeaders: [:]))
        case .airPlay:
            airPlayTileURL = url
        }
        return true
    }

    /// Logged stop reasons (Android parity): stopped (user, transport or the
    /// local Multiview ending), encoder-behind, render-stall, thermal.
    enum StopReason: String, Sendable { case stopped, encoderBehind = "encoder-behind", renderStall = "render-stall", thermal }

    /// `endTransport`: also end the receiver's playback (Stop, failure, the
    /// local Multiview closing). False when the transport ended first.
    /// `teardownTiles`: also end the headless local Multiview whose tiles
    /// fed the composite (Logan 2026-10-07: "if I stop casting multiview,
    /// why would they continue on my phone?"). False on a restart, when
    /// the local Multiview itself closed, and for Play Here (the tiles
    /// become the local fullscreen player).
    func stop(_ reason: StopReason = .stopped, detail: String, endTransport: Bool = false,
              teardownTiles: Bool = true) {
        guard let t = transport else { return }
        // Cleared first: the teardowns below re-enter stop() through the
        // tile list and cast-content observers.
        transport = nil
        debugLog("[MV-CAST] composite stop reason=\(reason.rawValue) detail=\(detail) teardownTiles=\(teardownTiles)")
        cancellables.removeAll()
        lagTimer?.invalidate()
        lagTimer = nil
        compositor?.stop()
        compositor = nil
        setKeepalive(false)
        airPlayTileURL = nil
        channelNames = []
        previewImage = nil
        MultiviewCompositeTaps.shared.deactivate()
        if teardownTiles {
            DispatchQueue.main.async {
                guard !MultiviewCompositeSession.shared.isActive,
                      PlayerSession.shared.mode == .multiview else { return }
                debugLog("[MV-CAST] composite stopped: headless tiles torn down")
                PlayerSession.shared.stop()
            }
        }
        guard endTransport else { return }
        switch t {
        case .cast:
            if AerioCastController.shared.castingContent?.mediaID == Self.castMediaID {
                AerioCastController.shared.stopCasting()
            }
        case .airPlay:
            AirPlayMonitor.shared.stop()
        }
    }

    /// Background keepalive (Logan 2026-10-07: backgrounding during a
    /// 4-up composite stopped everything). The composite holds the same
    /// shared silent-render keepalive the single-channel cast proxy holds,
    /// under its own name, so the encoder, the tile taps and the loopback
    /// server keep running with the app in the background. The thermal,
    /// render-stall and encoder-behind stop rules still apply.
    static let keepaliveHolder = "mv-composite"
    private var keepaliveHeld = false

    private func setKeepalive(_ on: Bool) {
        guard on != keepaliveHeld else { return }
        keepaliveHeld = on
        debugLog("[MV-CAST] background keepalive \(on ? "on" : "off")")
        if on { BackgroundKeepalive.acquire(Self.keepaliveHolder) } else { BackgroundKeepalive.release(Self.keepaliveHolder) }
    }

    private func failed(_ reason: StopReason, detail: String) {
        guard transport != nil else { return }
        stop(reason, detail: detail, endTransport: true)
        Self.presentAlert(Self.fellBehindMessage)
    }

    private func observe() {
        let store = MultiviewStore.shared
        store.$audioTileID
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self, let id, self.tileIDs.contains(id) else { return }
                self.compositor?.setFocus(id)
            }
            .store(in: &cancellables)
        store.$tiles
            .dropFirst()
            .sink { [weak self] tiles in
                guard let self else { return }
                if tiles.isEmpty {
                    self.stop(detail: "multiview closed", endTransport: true, teardownTiles: false)
                    return
                }
                let ids = Array(tiles.prefix(MultiviewCompositeLayout.maxTiles)).map(\.id)
                if ids != self.tileIDs {
                    self.tileIDs = ids
                    self.channelNames = Array(tiles.prefix(MultiviewCompositeLayout.maxTiles)).map(\.item.name)
                    self.compositor?.setTiles(ids)
                    debugLog("[MV-CAST] composite tiles changed: \(ids.count)")
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                debugLog("[MV-CAST] composite app background (keepalive held=\(self?.keepaliveHeld ?? false))")
                self?.compositor?.setBackgrounded(true)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                debugLog("[MV-CAST] composite app foreground")
                self?.compositor?.setBackgrounded(false)
            }
            .store(in: &cancellables)
        AerioCastController.shared.$castingContent
            .dropFirst()
            .sink { [weak self] content in
                guard let self, self.transport == .cast else { return }
                if content?.mediaID != Self.castMediaID {
                    self.stop(detail: content == nil ? "cast session ended" : "receiver tuned \(content?.title ?? "a channel")")
                }
            }
            .store(in: &cancellables)
        lagTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let comp = self.compositor else { return }
                for id in self.tileIDs {
                    if let lag = MultiviewCompositeTaps.shared.displayLagSeconds(tileID: id) {
                        comp.setDisplayLag(tileID: id, seconds: lag)
                    }
                }
                MultiviewCompositeTaps.shared.attachAudioTaps()
                if ProcessInfo.processInfo.thermalState == .critical {
                    self.failed(.thermal, detail: "thermal state critical")
                } else if comp.secondsSinceLastCompose() > MultiviewCompositor.maxBehindSeconds {
                    self.failed(.renderStall, detail: String(format: "no composed frame for %.1f s", comp.secondsSinceLastCompose()))
                }
            }
        }
    }

    static func presentAlert(_ message: String) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(title: "Multiview", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }
}

// MARK: - Compositor

/// Compose, encode, mux, serve. Three serial queues: compose (30 fps tick,
/// GPU render, encode submit), audio (tile taps, demux, rings, normalize)
/// and mux (TS writer and the loopback server), so a slow encoder never
/// blocks the audio and vice versa.
final class MultiviewCompositor: @unchecked Sendable {
    /// Composite clock origin in 90 kHz ticks (keeps every PTS positive).
    static let baseTicks: Int64 = 10 * 90_000
    /// The encoder may not trail the clock by more than this (resource rule).
    static let maxBehindSeconds: Double = 3
    static let maxInFlight = 6
    static let bitrate = 4_500_000
    /// Audio is muxed this far ahead of the video it plays with.
    static let audioLeadTicks: Int64 = 27_000
    /// Per-tile audio history kept for a focus switch.
    static let audioRingTicks: Int64 = 25 * 90_000
    static let aacFrameTicks: Int64 = 1920   // 1024 samples at 48 kHz

    var onFailure: (((MultiviewCompositeSession.StopReason, String)) -> Void)?
    /// A scaled-down composed frame every `previewEvery` ticks.
    var onPreview: ((CGImage) -> Void)?
    static let previewEvery = 6
    static let previewSize = CGSize(width: 480, height: 270)
    private var previewTick = 0

    private let composeQueue = DispatchQueue(label: "aerio.mv-composite.compose", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "aerio.mv-composite.audio", qos: .userInitiated)
    private let muxQueue = DispatchQueue(label: "aerio.mv-composite.mux", qos: .userInitiated)
    private let lock = NSLock()

    // Shared (lock)
    private var tileIDs: [String]
    private var focusID: String
    private var lagSeconds: [String: Double] = [:]
    private var stopped = false
    private var lastComposeHost: CFTimeInterval = 0
    /// Focused-tile PCM from the player's audio tap, newest arrival.
    private var tapPCMAt: [String: CFTimeInterval] = [:]

    // Compose queue
    private let mode: MultiviewLayoutMode
    private let accent: (Double, Double, Double)
    private var timer: DispatchSourceTimer?
    private var ciContext: CIContext?
    private var pool: CVPixelBufferPool?
    private var session: VTCompressionSession?
    private var forceKeyframe = false
    /// Bumped per encoder session so a late callback from a dropped
    /// session never invalidates its replacement.
    private var sessionGen = 0
    private var lastRebuildAttempt: CFTimeInterval = 0
    private var rebuildTimes: [CFTimeInterval] = []
    private var encoderRebuilds = 0
    private var renderingInBackground = false
    /// Shared (lock): the app is in the background.
    private var backgroundedFlag = false
    private var keyPolicy = MultiviewKeyframePolicy()
    private var latest: [String: CVPixelBuffer] = [:]
    /// Per-tile frame-source diagnostics (Logan 2026-10-07 black grid).
    private var tileSince: [String: CFTimeInterval] = [:]
    private var firstPixelLogged: Set<String> = []
    private var noPixelsLogged: Set<String> = []
    private var t0: CFTimeInterval = 0
    private var inFlight = 0
    private var submitted = 0
    private var dropped = 0
    private var encodedSinceStats = 0
    private var encodeMsSum: Double = 0
    private var lastStatsAt: CFTimeInterval = 0
    private var lastOutputAt: CFTimeInterval = 0
    private var lastPTS: Int64 = -1

    // Audio queue
    private struct TileAudio {
        var demux = MultiviewTapDemuxer()
        var ring: [MultiviewTapAudioPES] = []
        var lastPTS: Int64 = -1
    }
    private var tileAudio: [String: TileAudio] = [:]
    private var clock = MultiviewAudioClock()
    private var normalizer: MultiviewAudioNormalizer?
    private var normalizerKey = ""
    private var audioFloor: Int64 = 0   // mirrors mux's last emitted audio PTS
    private var unsupportedLogged: Set<String> = []
    private var fallbackLogged: Set<String> = []

    // Mux queue
    private var muxer = MultiviewCompositeTSMuxer()
    private var server: MultiviewCompositeTSServer?
    private var pendingAudio: [(pts: Int64, adts: [UInt8])] = []
    private var lastAudioPTS: Int64 = -1
    private var silentFrame: [UInt8]?
    private var sawKeyframe = false

    init(tileIDs: [String], focusID: String, mode: MultiviewLayoutMode, accent: (Double, Double, Double)) {
        self.tileIDs = tileIDs
        self.focusID = focusID
        self.mode = mode
        self.accent = accent
    }

    /// Starts the loopback server and the clock; returns the TS URL.
    func start() -> URL? {
        let server = MultiviewCompositeTSServer()
        guard let port = server.start() else { return nil }
        self.server = server
        silentFrame = MultiviewAudioNormalizer.silentADTSFrame()
        composeQueue.sync {
            renderingInBackground = isBackgrounded
            ciContext = Self.makeContext(software: renderingInBackground)
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: MultiviewCompositeLayout.width,
                kCVPixelBufferHeightKey as String: MultiviewCompositeLayout.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            makeEncoder()
            t0 = CACurrentMediaTime()
            lock.lock(); lastComposeHost = t0; lock.unlock()
            lastStatsAt = t0
            lastOutputAt = t0
            let timer = DispatchSource.makeTimerSource(queue: composeQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(MultiviewCompositeLayout.fps), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
        return URL(string: "http://127.0.0.1:\(port)/multiview.ts")
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        composeQueue.sync {
            timer?.cancel()
            timer = nil
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            latest.removeAll()
        }
        audioQueue.sync {
            normalizer = nil
            tileAudio.removeAll()
        }
        muxQueue.sync {
            server?.stop()
            server = nil
            pendingAudio.removeAll()
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func setFocus(_ id: String) {
        lock.lock()
        let changed = focusID != id
        focusID = id
        lock.unlock()
        guard changed else { return }
        debugLog("[MV-CAST] composite focus -> \(id)")
        audioQueue.async { [weak self] in self?.refocusAudio() }
    }

    func setTiles(_ ids: [String]) {
        lock.lock(); tileIDs = ids; lock.unlock()
    }

    /// Wall seconds since the compose tick last ran (render-stall rule).
    func secondsSinceLastCompose() -> Double {
        lock.lock(); defer { lock.unlock() }
        return isStoppedLocked ? 0 : CACurrentMediaTime() - lastComposeHost
    }

    private var isStoppedLocked: Bool { stopped }

    /// Decoded PCM from a tile player's audio tap (Android parity: the
    /// composite's audio is what the tile plays). Interleaved stereo Int16
    /// at `sampleRate`, stamped on the composite clock as it arrives: the
    /// tap runs as the tile renders, so this IS the picture's timing.
    func tilePCM(tileID: String, samples: [Int16], sampleRate: Int) {
        let now = compositeNow()
        audioQueue.async { [weak self] in
            guard let self, !self.isStopped, tileID == self.snapshot().focus else { return }
            let first = self.tapPCMAt[tileID] == nil
            self.tapPCMAt[tileID] = CACurrentMediaTime()
            if first {
                debugLog("[MV-CAST] composite audio: tile \(tileID) via player audio tap (\(sampleRate) Hz)")
            }
            let key = "pcm-\(sampleRate)"
            if self.normalizer == nil || self.normalizerKey != key {
                self.normalizer = MultiviewAudioNormalizer(pcmSampleRate: sampleRate)
                self.normalizerKey = key
            }
            // The tap delivers just ahead of output; the frame's start time
            // is its arrival minus its own duration.
            let start = now - Int64(samples.count / 2) * 90_000 / Int64(max(1, sampleRate))
            guard let produced = self.normalizer?.feedPCM(samples, mappedPTS: start) else { return }
            self.enqueueAudio(produced.filter { $0.pts > self.audioFloor })
        }
    }

    /// True while the focused tile's tap is delivering (the ingest path
    /// then stays idle for it).
    private func tapLive(_ id: String) -> Bool {
        guard let at = tapPCMAt[id] else { return false }
        return CACurrentMediaTime() - at < 1.0
    }

    func setDisplayLag(tileID: String, seconds: Double) {
        lock.lock(); lagSeconds[tileID] = seconds; lock.unlock()
    }

    private func snapshot() -> (tiles: [String], focus: String) {
        lock.lock(); defer { lock.unlock() }
        return (tileIDs, focusID)
    }

    /// The composite clock now, 90 kHz.
    private func compositeNow() -> Int64 {
        Self.baseTicks + Int64((CACurrentMediaTime() - t0) * 90_000)
    }

    // MARK: Compose + encode (compose queue)

    private func tick() {
        guard !isStopped, let pool else { return }
        let host = CACurrentMediaTime()
        if session == nil {
            // Encoder lost (invalidated on app background or a media
            // services reset): rebuild at most once a second; the
            // encoder-behind rule below still ends the composite if it
            // cannot come back within 3 s.
            if host - lastRebuildAttempt >= 1 {
                lastRebuildAttempt = host
                makeEncoder()
                if session != nil {
                    forceKeyframe = true
                    debugLog("[MV-CAST] composite encoder rebuilt (\(encoderRebuilds))")
                }
            }
            if session == nil {
                if host - lastOutputAt > Self.maxBehindSeconds {
                    fail(.encoderBehind, "encoder could not be rebuilt for \(String(format: "%.1f", host - lastOutputAt)) s")
                }
                return
            }
        }
        guard let session else { return }
        let backgrounded = isBackgrounded
        if backgrounded != renderingInBackground || ciContext == nil {
            // iOS refuses GPU work from a background app: CoreImage runs
            // on the CPU renderer while backgrounded, Metal otherwise.
            renderingInBackground = backgrounded
            ciContext = Self.makeContext(software: backgrounded)
            debugLog("[MV-CAST] composite renderer \(backgrounded ? "cpu (background)" : "metal (foreground)")")
        }
        guard let ciContext else { return }
        let pts = Self.baseTicks + Int64((host - t0) * 90_000)
        maybeLogStats(now: host)
        // Resource rule: the encoder may not trail the clock by > 3 s.
        if host - lastOutputAt > Self.maxBehindSeconds, submitted > 0 {
            fail(.encoderBehind, "encoder output \(String(format: "%.1f", host - lastOutputAt)) s behind")
            return
        }
        guard inFlight < Self.maxInFlight, pts > lastPTS else { dropped += 1; return }
        let (tiles, focus) = snapshot()
        lock.lock(); lastComposeHost = host; lock.unlock()
        for (n, id) in tiles.enumerated() {
            if let pb = MultiviewCompositeTaps.shared.newPixelBuffer(tileID: id, hostTime: host) {
                if latest[id] == nil, firstPixelLogged.insert(id).inserted {
                    debugLog("[MV-CAST] composite frame source tile=\(n) first pixel buffer \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) id=\(id) after \(String(format: "%.1f", host - (tileSince[id] ?? host))) s")
                }
                latest[id] = pb
                noPixelsLogged.remove(id)
            } else {
                let since = tileSince[id] ?? host
                if tileSince[id] == nil { tileSince[id] = host }
                if latest[id] == nil, host - since >= 5, noPixelsLogged.insert(id).inserted {
                    debugLog("[MV-CAST] composite tile \(n) no pixels for 5 s id=\(id) \(MultiviewCompositeTaps.shared.sourceDescription(tileID: id))")
                }
            }
        }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { dropped += 1; return }
        let image = compose(tiles: tiles, focus: focus)
        previewTick += 1
        if previewTick >= Self.previewEvery, let onPreview {
            previewTick = 0
            let sx = Self.previewSize.width / CGFloat(MultiviewCompositeLayout.width)
            let small = image.transformed(by: CGAffineTransform(scaleX: sx, y: sx))
            if let cg = ciContext.createCGImage(small, from: CGRect(origin: .zero, size: Self.previewSize)) {
                onPreview(cg)
            }
        }
        ciContext.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: MultiviewCompositeLayout.width,
                                                       height: MultiviewCompositeLayout.height),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var key = keyPolicy.isKeyframe(pts: pts)
        if forceKeyframe { key = true; forceKeyframe = false }
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        inFlight += 1
        submitted += 1
        lastPTS = pts
        let submittedAt = host
        let gen = sessionGen
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: out,
            presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
            duration: CMTime(value: 3000, timescale: 90_000),
            frameProperties: props, infoFlagsOut: nil) { [weak self] st, _, sample in
                self?.encoded(status: st, sample: sample, pts: pts, submittedAt: submittedAt, gen: gen)
            }
        if status != noErr {
            inFlight -= 1
            dropped += 1
            if status == kVTInvalidSessionErr { encoderInvalidated(host: host) }
        }
    }

    private func compose(tiles: [String], focus: String) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: MultiviewCompositeLayout.width, height: MultiviewCompositeLayout.height)
        var image = CIImage(color: .black).cropped(to: full)
        let rects = MultiviewCompositeLayout.tileRects(count: tiles.count, mode: mode)
        // Round 2 (Logan 2026-10-07, shared with Android): thin borders,
        // 2 px gray on every tile, 4 px theme accent on the focused tile
        // only, 4 px black gaps. White read as a thick frame on the TV.
        let border = CIColor(red: 0.5, green: 0.5, blue: 0.5)
        let highlight = CIColor(red: CGFloat(accent.0), green: CGFloat(accent.1), blue: CGFloat(accent.2))
        for (i, rect) in rects.enumerated() where i < tiles.count {
            let id = tiles[i]
            let tileArea = MultiviewCompositeLayout.flipped(rect)
            if let pb = latest[id] {
                let src = CIImage(cvPixelBuffer: pb)
                let w = src.extent.width, h = src.extent.height
                if w > 0, h > 0 {
                    let fit = MultiviewCompositeLayout.flipped(MultiviewCompositeLayout.videoRect(in: rect, aspect: w / h))
                    let placed = src
                        .transformed(by: CGAffineTransform(scaleX: fit.width / w, y: fit.height / h))
                        .transformed(by: CGAffineTransform(translationX: fit.minX - src.extent.minX * fit.width / w,
                                                           y: fit.minY - src.extent.minY * fit.height / h))
                        .cropped(to: tileArea)
                    image = placed.composited(over: image)
                }
            }
            let focused = id == focus
            let strips = MultiviewCompositeLayout.borderStrips(
                rect, width: focused ? MultiviewCompositeLayout.focusBorderWidth : MultiviewCompositeLayout.borderWidth)
            for s in strips {
                image = CIImage(color: focused ? highlight : border)
                    .cropped(to: MultiviewCompositeLayout.flipped(s))
                    .composited(over: image)
            }
        }
        return image
    }

    /// kVTInvalidSessionErr (iOS invalidates the hardware encoder when
    /// the app backgrounds, field log 2026-10-07 10:39:47): drop the
    /// session and let the next tick rebuild it. More than 3 rebuilds in
    /// 30 s is the encoder-behind stop.
    private func encoderInvalidated(host: CFTimeInterval) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        inFlight = 0
        rebuildTimes = rebuildTimes.filter { host - $0 < 30 } + [host]
        encoderRebuilds += 1
        debugLog("[MV-CAST] composite encoder session invalid; rebuilding (\(rebuildTimes.count) in 30 s)")
        if rebuildTimes.count > 3 {
            fail(.encoderBehind, "encoder session invalid \(rebuildTimes.count) times in 30 s")
            return
        }
        lastRebuildAttempt = 0
        lastOutputAt = max(lastOutputAt, host)
    }

    static func makeContext(software: Bool) -> CIContext {
        if !software, let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: software])
    }

    /// Set from the main thread on app background / foreground.
    func setBackgrounded(_ value: Bool) {
        lock.lock(); backgroundedFlag = value; lock.unlock()
    }

    private var isBackgrounded: Bool { lock.lock(); defer { lock.unlock() }; return backgroundedFlag }

    private func makeEncoder() {
        var s: VTCompressionSession?
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(MultiviewCompositeLayout.width),
            height: Int32(MultiviewCompositeLayout.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else {
            debugLog("[MV-CAST] composite encoder create failed status=\(st)")
            return
        }
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Self.bitrate))
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: Self.bitrate * 3 / 2 / 8), NSNumber(value: 1)] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: MultiviewCompositeLayout.fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: MultiviewCompositeLayout.fps * 2))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
        sessionGen += 1
        session = s
    }

    /// VideoToolbox output (its own thread).
    private func encoded(status: OSStatus, sample: CMSampleBuffer?, pts: Int64, submittedAt: CFTimeInterval, gen: Int) {
        let now = CACurrentMediaTime()
        composeQueue.async { [weak self] in
            guard let self else { return }
            self.inFlight = max(0, self.inFlight - 1)
            guard status == noErr, sample != nil else {
                self.dropped += 1
                if status == kVTInvalidSessionErr, self.session != nil, gen == self.sessionGen {
                    self.encoderInvalidated(host: now)
                }
                return
            }
            self.lastOutputAt = now
            self.encodedSinceStats += 1
            self.encodeMsSum += (now - submittedAt) * 1000
        }
        guard status == noErr, let sample, let (au, key) = Self.annexB(sample) else { return }
        muxQueue.async { [weak self] in self?.muxVideo(au, pts: pts, keyframe: key) }
    }

    private func maybeLogStats(now: CFTimeInterval) {
        guard now - lastStatsAt >= 10 else { return }
        let secs = now - lastStatsAt
        let fps = Double(encodedSinceStats) / secs
        let enc = encodedSinceStats > 0 ? encodeMsSum / Double(encodedSinceStats) : 0
        debugLog(String(format: "[MV-CAST] composite fps=%.1f enc=%.1fms dropped=%d thermal=%d",
                        fps, enc, dropped, ProcessInfo.processInfo.thermalState.rawValue))
        lastStatsAt = now
        encodedSinceStats = 0
        encodeMsSum = 0
        dropped = 0
    }

    private func fail(_ reason: MultiviewCompositeSession.StopReason, _ detail: String) {
        lock.lock()
        let already = stopped
        lock.unlock()
        guard !already else { return }
        timer?.cancel()
        timer = nil
        onFailure?((reason, detail))
    }

    /// AVCC sample to Annex B: AUD, then SPS/PPS on key frames, then the
    /// slices. nil on a malformed sample.
    static func annexB(_ sample: CMSampleBuffer) -> ([UInt8], Bool)? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var key = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            key = !notSync
        }
        let start: [UInt8] = [0, 0, 0, 1]
        var out: [UInt8] = start + [0x09, 0xF0]
        if key {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
                out += start
                out += UnsafeBufferPointer(start: ptr, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data) == noErr else { return nil }
        var o = 0
        while o + 4 <= length {
            let n = Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3])
            o += 4
            guard n > 0, o + n <= length else { return nil }
            if data[o] & 0x1F != 9 { out += start; out += data[o..<(o + n)] }
            o += n
        }
        return (out, key)
    }

    // MARK: Mux (mux queue)

    private func muxVideo(_ au: [UInt8], pts: Int64, keyframe: Bool) {
        guard let server else { return }
        if !sawKeyframe {
            guard keyframe else { return }
            sawKeyframe = true
            lastAudioPTS = pts - Self.aacFrameTicks
        }
        var bytes = muxer.video(accessUnit: au, pts: pts, keyframe: keyframe)
        bytes += drainAudio(through: pts + Self.audioLeadTicks)
        server.broadcast(bytes, keyframeStart: keyframe)
    }

    /// Audio up to `limit`: real frames in order, silence across any gap
    /// so the audio track never stops (a focus switch, a stalled tile, a
    /// codec the phone cannot decode).
    private func drainAudio(through limit: Int64) -> [UInt8] {
        var out: [UInt8] = []
        pendingAudio.sort { $0.pts < $1.pts }
        while lastAudioPTS + Self.aacFrameTicks <= limit {
            let next = lastAudioPTS + Self.aacFrameTicks
            // Drop real frames already covered.
            while let f = pendingAudio.first, f.pts < next - Self.aacFrameTicks / 2 { pendingAudio.removeFirst() }
            if let f = pendingAudio.first, f.pts <= next + Self.aacFrameTicks / 2 {
                pendingAudio.removeFirst()
                out += muxer.audio(adtsFrame: f.adts, pts: f.pts)
                lastAudioPTS = f.pts
            } else {
                // No real frame for this slot yet: silence keeps the track going.
                if let silentFrame { out += muxer.audio(adtsFrame: silentFrame, pts: next) }
                lastAudioPTS = next
            }
        }
        let floor = lastAudioPTS
        audioQueue.async { [weak self] in self?.audioFloor = floor }
        return out
    }

    private func enqueueAudio(_ frames: [(pts: Int64, adts: [UInt8])]) {
        guard !frames.isEmpty else { return }
        muxQueue.async { [weak self] in
            guard let self else { return }
            self.pendingAudio += frames
            // Bound memory if the video stalls.
            if self.pendingAudio.count > 2000 { self.pendingAudio.removeFirst(self.pendingAudio.count - 2000) }
        }
    }

    // MARK: Audio (audio queue)

    /// A tile's raw ingest bytes (its remuxer queue).
    func tileBytes(tileID: String, data: Data) {
        audioQueue.async { [weak self] in self?.handleTileBytes(tileID, [UInt8](data)) }
    }

    private func handleTileBytes(_ id: String, _ bytes: [UInt8]) {
        guard !isStopped else { return }
        var ta = tileAudio[id] ?? TileAudio()
        let pes = ta.demux.feed(bytes)
        guard !pes.isEmpty else { tileAudio[id] = ta; return }
        ta.ring += pes
        if let last = pes.last?.pts {
            ta.lastPTS = last
            let mask = TSLANAudioRewriter.pts33Mask
            ta.ring.removeAll { ((last - $0.pts) & mask) > Self.audioRingTicks }
        }
        tileAudio[id] = ta
        // Fallback only: the player's audio tap is the source when it runs
        // (Apple documents no audio tap for HLS items, so the ingest path
        // stays for tiles whose tap never delivers).
        if id == snapshot().focus, !tapLive(id) {
            if fallbackLogged.insert(id).inserted {
                debugLog("[MV-CAST] composite audio: tile \(id) via ingest tap (no player audio tap PCM)")
            }
            process(pes, tileID: id)
        }
    }

    private func refocusAudio() {
        clock.reanchor()
        normalizer = nil
        normalizerKey = ""
        let focus = snapshot().focus
        // Tap path: a flag flip, the new tile's PCM is already arriving.
        if tapLive(focus) { return }
        // Replay the focused tile's recent audio: what the tile shows now
        // lies inside it, the clock drops anything already covered.
        if let ring = tileAudio[focus]?.ring, !ring.isEmpty { process(ring, tileID: focus) }
    }

    /// The source PTS the focused tile is showing now (estimate: newest
    /// ingested audio minus the player's distance behind it).
    private func displayedSourcePTS(_ id: String) -> Int64 {
        let last = tileAudio[id]?.lastPTS ?? 0
        lock.lock()
        let lag = lagSeconds[id] ?? 6
        lock.unlock()
        return (last - Int64(lag * 90_000)) & TSLANAudioRewriter.pts33Mask
    }

    private func process(_ pes: [MultiviewTapAudioPES], tileID: String) {
        var produced: [(pts: Int64, adts: [UInt8])] = []
        let now = compositeNow()
        for p in pes {
            guard let codec = MultiviewAudioNormalizer.codec(streamType: p.streamType, payload: p.payload) else {
                let key = "\(tileID)-\(p.streamType)"
                if unsupportedLogged.insert(key).inserted {
                    debugLog(String(format: "[MV-CAST] composite audio: stream_type 0x%02X not decodable on the phone; silence for this tile", p.streamType))
                }
                continue
            }
            var offset = 0
            var sampleOffset = 0
            while let frame = MultiviewAudioNormalizer.nextFrame(codec, p.payload, &offset) {
                let srcPTS = p.pts + Int64(sampleOffset) * 90_000 / Int64(max(1, frame.sampleRate))
                sampleOffset += frame.samples
                let wasAnchored = clock.offset != nil
                guard let mapped = clock.map(sourcePTS: srcPTS & TSLANAudioRewriter.pts33Mask, compositeNow: now,
                                             displayedSourcePTS: { self.displayedSourcePTS(tileID) },
                                             floor: audioFloor) else { continue }
                if !wasAnchored, let o = clock.offset {
                    lock.lock(); let lag = lagSeconds[tileID] ?? -1; lock.unlock()
                    debugLog(String(format: "[MV-CAST] composite audio anchor tile=%@ codec=%@ lag=%.2fs offset=%lld lead=%.2fs",
                                    tileID, codec.name, lag, o, Double(mapped - now) / 90_000))
                }
                let key = "\(codec.name)-\(frame.sampleRate)-\(frame.channels)"
                if normalizer == nil || key != normalizerKey {
                    normalizer = MultiviewAudioNormalizer(codec: codec, sampleRate: frame.sampleRate,
                                                          channels: frame.channels, samplesPerFrame: frame.samples,
                                                          asc: frame.asc)
                    normalizerKey = key
                    if normalizer == nil {
                        debugLog("[MV-CAST] composite audio: no decoder for \(key); silence")
                    }
                }
                guard let normalizer else { continue }
                produced += normalizer.feed(frame.bytes, mappedPTS: mapped)
            }
        }
        enqueueAudio(produced)
    }
}

// MARK: - Audio normalizer (AudioToolbox)

/// Any supported source frame (ADTS AAC, AC-3, E-AC-3, MPEG audio) to
/// AAC-LC stereo 48 kHz ADTS frames, so the composite's audio PID keeps
/// one format whichever tile is focused.
final class MultiviewAudioNormalizer {
    enum Codec {
        case aac, ac3, eac3, mp2
        var name: String {
            switch self { case .aac: return "AAC"; case .ac3: return "AC-3"; case .eac3: return "E-AC-3"; case .mp2: return "MP2" }
        }
    }

    struct Frame {
        var bytes: [UInt8]       // AAC: raw (ADTS header stripped)
        var sampleRate: Int
        var channels: Int
        var samples: Int
        var asc: [UInt8]?
    }

    static let outputRate = 48_000

    static func codec(streamType: UInt8, payload: [UInt8]) -> Codec? {
        switch streamType {
        case 0x0F: return .aac
        case 0x03, 0x04: return .mp2
        case 0x81, 0x87, 0x06:
            // bsid tells AC-3 (<= 10) from E-AC-3 (16).
            guard let i = (0..<max(0, payload.count - 6)).first(where: { payload[$0] == 0x0B && payload[$0 + 1] == 0x77 }) else {
                return streamType == 0x87 ? .eac3 : .ac3
            }
            return (payload[i + 5] >> 3) > 10 ? .eac3 : .ac3
        default: return nil
        }
    }

    /// The next whole frame in `payload` at or after `offset`.
    static func nextFrame(_ codec: Codec, _ payload: [UInt8], _ offset: inout Int) -> Frame? {
        while offset < payload.count {
            switch codec {
            case .aac:
                if let h = MultiviewADTS.parse(payload, offset), offset + h.frameLength <= payload.count {
                    let start = offset + h.headerLength
                    let end = offset + h.frameLength
                    offset = end
                    return Frame(bytes: Array(payload[start..<end]), sampleRate: h.sampleRate,
                                 channels: max(1, h.channels), samples: 1024, asc: MultiviewADTS.audioSpecificConfig(h))
                }
            case .ac3, .eac3, .mp2:
                let src: CastAudioSourceCodec = codec == .ac3 ? .ac3 : (codec == .eac3 ? .eac3 : .mp2)
                if let info = CastAudioFrameParser.parseFrameHeader(src, payload, offset),
                   info.frameLength > 0, offset + info.frameLength <= payload.count {
                    let f = Frame(bytes: Array(payload[offset..<(offset + info.frameLength)]), sampleRate: info.sampleRate,
                                  channels: info.channels, samples: info.samplesPerFrame, asc: nil)
                    offset += info.frameLength
                    return f
                }
            }
            offset += 1
        }
        return nil
    }

    private let sampleRate: Int
    private var decoder: AudioConverterRef?
    private var encoder: AudioConverterRef?
    private let decodeOutChannels: Int
    private var fifo: [Int16] = []
    private var anchorPTS: Int64 = -1
    private var inputSamples: Int64 = 0
    private var outputPackets: Int64 = 0
    private let input = ConverterInput()

    /// PCM input (the player audio tap): no decoder, encoder only.
    init?(pcmSampleRate: Int) {
        sampleRate = pcmSampleRate
        decodeOutChannels = 2
        var encIn = Self.pcm(pcmSampleRate, 2)
        var encOut = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.outputRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        var enc: AudioConverterRef?
        guard AudioConverterNew(&encIn, &encOut, &enc) == noErr, let enc else { return nil }
        var bitrate: UInt32 = 160_000
        _ = AudioConverterSetProperty(enc, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        encoder = enc
    }

    /// Interleaved stereo PCM stamped on the composite clock.
    func feedPCM(_ stereo: [Int16], mappedPTS: Int64) -> [(pts: Int64, adts: [UInt8])] {
        let expected = anchorPTS + inputSamples * 90_000 / Int64(sampleRate)
        // Tap callbacks jitter by a buffer or two; re-anchor only on a
        // real jump (a focus switch, a stall) of more than 100 ms.
        if anchorPTS < 0 || abs(mappedPTS - expected) > 9_000 {
            if anchorPTS >= 0, let encoder { AudioConverterReset(encoder) }
            fifo.removeAll(keepingCapacity: true)
            anchorPTS = mappedPTS
            inputSamples = 0
            outputPackets = 0
        }
        inputSamples += Int64(stereo.count / 2)
        fifo += stereo
        return encodeAvailable()
    }

    init?(codec: Codec, sampleRate: Int, channels: Int, samplesPerFrame: Int, asc: [UInt8]?) {
        self.sampleRate = sampleRate
        let formatID: AudioFormatID
        switch codec {
        case .aac: formatID = kAudioFormatMPEG4AAC
        case .ac3: formatID = kAudioFormatAC3
        case .eac3: formatID = kAudioFormatEnhancedAC3
        case .mp2: formatID = kAudioFormatMPEGLayer2
        }
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(samplesPerFrame), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        var dec: AudioConverterRef?
        var outChannels = 2
        var pcm = Self.pcm(sampleRate, 2)
        var st = AudioConverterNew(&inDesc, &pcm, &dec)
        if st != noErr, codec == .mp2 {
            inDesc.mFormatID = kAudioFormatMPEGLayer3
            st = AudioConverterNew(&inDesc, &pcm, &dec)
        }
        if st != noErr || dec == nil {
            outChannels = channels
            pcm = Self.pcm(sampleRate, channels)
            st = AudioConverterNew(&inDesc, &pcm, &dec)
        }
        guard st == noErr, let dec else { return nil }
        decodeOutChannels = outChannels
        decoder = dec
        var encIn = Self.pcm(sampleRate, 2)
        var encOut = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.outputRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        var enc: AudioConverterRef?
        guard AudioConverterNew(&encIn, &encOut, &enc) == noErr, let enc else {
            AudioConverterDispose(dec)
            return nil
        }
        var bitrate: UInt32 = 160_000
        _ = AudioConverterSetProperty(enc, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        encoder = enc
    }

    deinit {
        if let decoder { AudioConverterDispose(decoder) }
        if let encoder { AudioConverterDispose(encoder) }
    }

    /// One source frame stamped on the composite clock; returns the AAC
    /// frames (ADTS) completed by it.
    func feed(_ bytes: [UInt8], mappedPTS: Int64) -> [(pts: Int64, adts: [UInt8])] {
        // Re-anchor when the input jumps more than 100 ms off the ladder.
        let expected = anchorPTS + inputSamples * 90_000 / Int64(sampleRate)
        if anchorPTS < 0 || abs(mappedPTS - expected) > 9_000 {
            if anchorPTS >= 0 {
                if let decoder { AudioConverterReset(decoder) }
                if let encoder { AudioConverterReset(encoder) }
            }
            fifo.removeAll(keepingCapacity: true)
            anchorPTS = mappedPTS
            inputSamples = 0
            outputPackets = 0
        }
        guard let pcm = decode(bytes), !pcm.isEmpty else { return [] }
        let stereo = decodeOutChannels == 2 ? pcm : CastAudioTranscoder.downmixToStereo(pcm, channels: decodeOutChannels)
        inputSamples += Int64(stereo.count / 2)
        fifo += stereo
        return encodeAvailable()
    }

    private func decode(_ bytes: [UInt8]) -> [Int16]? {
        guard let decoder else { return nil }
        input.set(bytes)
        let capacity = 4096 * decodeOutChannels
        var out = [Int16](repeating: 0, count: capacity)
        var frames = UInt32(4096)
        let st: OSStatus = out.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(decodeOutChannels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(decoder, converterInputProc,
                                                   Unmanaged.passUnretained(input).toOpaque(), &frames, &list, nil)
        }
        guard st == noErr || st == ConverterInput.noMoreData else { return nil }
        return Array(out.prefix(Int(frames) * decodeOutChannels))
    }

    private func encodeAvailable() -> [(pts: Int64, adts: [UInt8])] {
        guard let encoder, let freq = TSLANAudioRewriter.adtsFrequencyIndex(Self.outputRate) else { return [] }
        var result: [(pts: Int64, adts: [UInt8])] = []
        while !fifo.isEmpty {
            input.setPCM(fifo)
            fifo.removeAll(keepingCapacity: true)
            while true {
                var packets = UInt32(1)
                var buffer = [UInt8](repeating: 0, count: 2048)
                var desc = AudioStreamPacketDescription()
                let st: OSStatus = buffer.withUnsafeMutableBytes { raw in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                    return AudioConverterFillComplexBuffer(encoder, converterInputProc,
                                                           Unmanaged.passUnretained(input).toOpaque(),
                                                           &packets, &list, &desc)
                }
                guard st == noErr || st == ConverterInput.noMoreData, packets > 0 else { break }
                let size = Int(desc.mDataByteSize)
                if size > 0 {
                    let pts = anchorPTS + outputPackets * 1024 * 90_000 / Int64(Self.outputRate)
                    outputPackets += 1
                    result.append((pts, TSLANAudioRewriter.adtsHeader(payloadLength: size, frequencyIndex: freq)
                                   + buffer[Int(desc.mStartOffset)..<(Int(desc.mStartOffset) + size)]))
                }
                if st == ConverterInput.noMoreData { break }
            }
            // Whatever the encoder did not take stays for the next call.
            fifo += input.takeRemainingPCM()
            break
        }
        return result
    }

    private static func pcm(_ rate: Int, _ channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    }

    /// One silent AAC-LC stereo 48 kHz frame (ADTS), from the platform
    /// encoder; nil if it cannot run (the composite then has no gap fill).
    static func silentADTSFrame() -> [UInt8]? {
        var encIn = pcm(outputRate, 2)
        var encOut = AudioStreamBasicDescription(
            mSampleRate: Float64(outputRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        var enc: AudioConverterRef?
        guard AudioConverterNew(&encIn, &encOut, &enc) == noErr, let enc,
              let freq = TSLANAudioRewriter.adtsFrequencyIndex(outputRate) else { return nil }
        defer { AudioConverterDispose(enc) }
        let input = ConverterInput()
        input.setPCM([Int16](repeating: 0, count: 1024 * 2 * 8))
        var last: [UInt8]?
        for _ in 0..<8 {
            var packets = UInt32(1)
            var buffer = [UInt8](repeating: 0, count: 2048)
            var desc = AudioStreamPacketDescription()
            let st: OSStatus = buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(enc, converterInputProc,
                                                       Unmanaged.passUnretained(input).toOpaque(),
                                                       &packets, &list, &desc)
            }
            guard st == noErr || st == ConverterInput.noMoreData, packets > 0 else { break }
            let size = Int(desc.mDataByteSize)
            if size > 0 {
                last = TSLANAudioRewriter.adtsHeader(payloadLength: size, frequencyIndex: freq)
                    + buffer[Int(desc.mStartOffset)..<(Int(desc.mStartOffset) + size)]
            }
        }
        return last
    }
}

/// Stable input storage for AudioConverter's pull callback: one compressed
/// packet (decode) or a block of interleaved stereo PCM (encode).
private final class ConverterInput {
    static let noMoreData: OSStatus = 0x6E6F6474   // 'nodt'
    var storage: UnsafeMutableRawPointer?
    var capacity = 0
    var size = 0
    var offset = 0
    var isPCM = false
    var consumed = true
    let packetDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    deinit {
        storage?.deallocate()
        packetDescription.deallocate()
    }

    private func reserve(_ n: Int) {
        guard n > capacity else { return }
        storage?.deallocate()
        storage = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        capacity = n
    }

    func set(_ bytes: [UInt8]) {
        reserve(bytes.count)
        bytes.withUnsafeBytes { storage?.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        size = bytes.count
        offset = 0
        isPCM = false
        consumed = false
    }

    func setPCM(_ samples: [Int16]) {
        let n = samples.count * 2
        reserve(n)
        samples.withUnsafeBytes { if let b = $0.baseAddress { storage?.copyMemory(from: b, byteCount: n) } }
        size = n
        offset = 0
        isPCM = true
        consumed = n == 0
    }

    func takeRemainingPCM() -> [Int16] {
        guard isPCM, !consumed, let storage, offset < size else { consumed = true; return [] }
        let count = (size - offset) / 2
        let p = (storage + offset).bindMemory(to: Int16.self, capacity: count)
        consumed = true
        return Array(UnsafeBufferPointer(start: p, count: count))
    }
}

private let converterInputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, user in
    guard let user else { ioPackets.pointee = 0; return ConverterInput.noMoreData }
    let input = Unmanaged<ConverterInput>.fromOpaque(user).takeUnretainedValue()
    guard !input.consumed, let storage = input.storage, input.offset < input.size else {
        ioPackets.pointee = 0
        return ConverterInput.noMoreData
    }
    let base = storage + input.offset
    let bytes = input.size - input.offset
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = base
    ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
    if input.isPCM {
        ioData.pointee.mBuffers.mNumberChannels = 2
        ioPackets.pointee = UInt32(bytes / 4)
    } else {
        ioData.pointee.mBuffers.mNumberChannels = 0
        input.packetDescription.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes))
        outDesc?.pointee = input.packetDescription
        ioPackets.pointee = 1
    }
    input.offset = input.size
    input.consumed = true
    return noErr
}

// MARK: - Player audio tap

/// MTAudioProcessingTap on a tile's AVPlayerItem: passes the audio through
/// untouched and hands a stereo Int16 copy to the compositor. Whether a
/// muted tile (the phone is silent during a composite) still delivers, and
/// whether AVFoundation runs the tap on these loopback HLS items at all, is
/// unmeasured: the ingest path takes over for any tile whose tap is silent.
enum MultiviewAudioTap {
    final class Context {
        let tileID: String
        let sink: @Sendable (String, [Int16], Int) -> Void
        var format = AudioStreamBasicDescription()
        init(tileID: String, sink: @escaping @Sendable (String, [Int16], Int) -> Void) {
            self.tileID = tileID
            self.sink = sink
        }
    }

    static func make(tileID: String, sink: @escaping @Sendable (String, [Int16], Int) -> Void) -> MTAudioProcessingTap? {
        let ctx = Context(tileID: tileID, sink: sink)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(ctx).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let n = Int(framesOut.pointee)
                guard n > 0, let pcm = MultiviewAudioTap.stereoInt16(bufferList, frames: n, format: ctx.format) else { return }
                ctx.sink(ctx.tileID, pcm, Int(ctx.format.mSampleRate))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            Unmanaged<Context>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }

    /// Float32 or Int16, interleaved or not, any channel count -> stereo
    /// interleaved Int16 (first two channels; mono doubled).
    static func stereoInt16(_ list: UnsafeMutablePointer<AudioBufferList>, frames n: Int,
                            format f: AudioStreamBasicDescription) -> [Int16]? {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard !buffers.isEmpty, f.mSampleRate > 0 else { return nil }
        let isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = max(1, Int(f.mChannelsPerFrame))
        func sample(_ ch: Int, _ i: Int) -> Float {
            let c = min(ch, channels - 1)
            let (buf, idx) = nonInterleaved ? (buffers[min(c, buffers.count - 1)], i) : (buffers[0], i * channels + c)
            guard let d = buf.mData else { return 0 }
            if isFloat { return d.assumingMemoryBound(to: Float.self)[idx] }
            return Float(d.assumingMemoryBound(to: Int16.self)[idx]) / 32768
        }
        var out = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            for ch in 0..<2 {
                let v = max(-1, min(1, sample(ch, i)))
                out[i * 2 + ch] = Int16(v * 32767)
            }
        }
        return out
    }
}

// MARK: - Loopback TS server

/// Serves the composite TS on 127.0.0.1 as one endless close-delimited
/// HTTP/1.1 body per connection. A new reader starts on the latest key
/// frame (the cached GOP), so its demuxer meets PAT, PMT and an IDR first.
final class MultiviewCompositeTSServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aerio.mv-composite.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var gop: [UInt8] = []
    private static let maxGOP = 12 * 1024 * 1024
    private static let maxPending = 24 * 1024 * 1024

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var started = false
        var pending = 0
        init(_ c: NWConnection) { connection = c }
    }

    /// Returns the bound port, or nil.
    func start() -> UInt16? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        return listener.port?.rawValue
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for c in clients.values { c.connection.cancel() }
            clients.removeAll()
            gop.removeAll()
        }
    }

    func broadcast(_ bytes: [UInt8], keyframeStart: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if keyframeStart { self.gop = bytes } else if self.gop.count < Self.maxGOP { self.gop += bytes }
            for c in self.clients.values {
                if !c.started { continue }
                self.send(bytes, to: c)
            }
        }
    }

    private func accept(_ c: NWConnection) {
        let client = Client(c)
        clients[ObjectIdentifier(client)] = client
        c.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled:
                self.clients[ObjectIdentifier(client)] = nil
            default: break
            }
        }
        c.start(queue: queue)
        readRequest(client, buffer: Data())
    }

    private func readRequest(_ client: Client, buffer: Data) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || (done && buf.isEmpty) { client.connection.cancel(); return }
            guard let text = String(data: buf, encoding: .utf8), text.contains("\r\n\r\n") else {
                if buf.count > 16_384 { client.connection.cancel(); return }
                self.readRequest(client, buffer: buf)
                return
            }
            let firstLine = text.split(separator: "\r\n").first.map(String.init) ?? ""
            guard firstLine.hasPrefix("GET "), firstLine.contains("/multiview.ts") else {
                let body = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                client.connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in client.connection.cancel() })
                return
            }
            debugLog("[MV-CAST] composite TS reader connected (\(self.clients.count) reader(s))")
            let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            client.connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            client.started = true
            if !self.gop.isEmpty { self.send(self.gop, to: client) }
        }
    }

    private func send(_ bytes: [UInt8], to client: Client) {
        if client.pending > Self.maxPending {
            debugLog("[MV-CAST] composite TS reader too slow (\(client.pending) B pending); dropped")
            client.connection.cancel()
            return
        }
        client.pending += bytes.count
        let n = bytes.count
        client.connection.send(content: Data(bytes), completion: .contentProcessed { [weak client] _ in
            client?.pending -= n
        })
    }
}
#endif
