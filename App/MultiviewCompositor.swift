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
    /// The remuxer each tile last registered with, kept across unregister
    /// (a sole-tile re-mount unregisters before the new player registers),
    /// so a tile's new ingest connection is recognized.
    private var lastRemuxer: [String: ObjectIdentifier] = [:]
    /// Set while a composite runs: a tile's ingest restarted on a new
    /// connection (watchdog retry, standing retry, re-mount).
    private var sourceRestartSink: (@Sendable (String) -> Void)?

    func setSourceRestartSink(_ s: (@Sendable (String) -> Void)?) {
        lock.lock(); sourceRestartSink = s; lock.unlock()
    }

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
        let newID = remuxer.map(ObjectIdentifier.init)
        let previousID = lastRemuxer[tileID]
        if let newID { lastRemuxer[tileID] = newID }
        let restartSink = active && previousID != nil && newID != nil && previousID != newID ? sourceRestartSink : nil
        lock.unlock()
        restartSink?(tileID)
        if let o = old?.output, old?.item !== item { old?.item.remove(o) }
        if old?.item !== item, old?.remuxer === remuxer { remuxer?.resetLocalTimeBase() }
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
        for (id, e) in entries { if let r = e.remuxer { lastRemuxer[id] = ObjectIdentifier(r) } }
        lock.unlock()
        for (id, e) in snapshot {
            if e.output == nil { attachOutput(tileID: id) }
            e.remuxer?.setIngestTap { data in s(id, data) }
            if t == .airPlay { e.player?.allowsExternalPlayback = false }
            e.player?.isMuted = true
        }
    }

    /// `restoreMute`: false when the one tile left is handed to the AirPlay
    /// receiver as a single channel; it re-mounts as the sole tile with a
    /// fresh player, and the old one must not play on the phone meanwhile.
    @MainActor func deactivate(restoreMute: Bool = true) {
        lock.lock()
        transport = nil
        sink = nil
        sourceRestartSink = nil
        lastRemuxer.removeAll()
        let snapshot = entries
        for k in entries.keys { entries[k]?.output = nil }
        lock.unlock()
        let audioID = MultiviewStore.shared.audioTileID
        detachAudioTaps(snapshot)
        pcmSink = nil
        for (id, e) in snapshot {
            if let o = e.output { e.item.remove(o) }
            e.remuxer?.setIngestTap(nil)
            if restoreMute { e.player?.isMuted = audioID != id }
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

    /// The tile player's item time, whether it is playing, and its remuxer
    /// (which maps item time to the source PTS on screen), main thread.
    @MainActor func playbackSample(tileID: String) -> (itemTime: Double, playing: Bool, remuxer: TSHLSRemuxer?)? {
        lock.lock()
        let e = entries[tileID]
        lock.unlock()
        guard let e, let player = e.player, player.currentItem === e.item else { return nil }
        return (player.currentTime().seconds, player.timeControlStatus == .playing, e.remuxer)
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
/// The composite's live preview frames, observed only by the preview grid.
@MainActor
final class MultiviewCompositePreview: ObservableObject {
    static let shared = MultiviewCompositePreview()
    @Published var image: UIImage?
    private init() {}
}

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
    /// remote controls sheet's preview grid. Published on its own object
    /// (MultiviewCompositePreview), not on this session: MainTabView
    /// observes this session, so a frame published here re-rendered the
    /// whole tab root and the remote controls sheet about 5 times a second
    /// (device log 2026-10-07 round 8: "[TAB] bodies/1s ... MainTabView=6"
    /// for the whole composite cast against 2 before it), which rebuilt
    /// the sheet's Layout menu mid-tap (flicker, taps lost).
    var previewImage: UIImage? {
        get { MultiviewCompositePreview.shared.image }
        set {
            if newValue == nil, MultiviewCompositePreview.shared.image == nil { return }
            MultiviewCompositePreview.shared.image = newValue
        }
    }
    /// The composite's grid layout for this session (Layout row in the
    /// remote controls sheet). Seeded from the stored preference at start.
    @Published private(set) var layoutMode: MultiviewLayoutMode = .auto

    /// Layout row pick: the composite re-lays out live (Cast and AirPlay
    /// share this compositor), the preview follows `layoutMode`.
    func setLayout(_ m: MultiviewLayoutMode) {
        guard m != layoutMode else { return }
        debugLog("[MV-CAST] layout \(layoutMode.rawValue) -> \(m.rawValue) tiles=\(tileIDs.count) transport=\(transport.map { "\($0)" } ?? "none")")
        layoutMode = m
        compositor?.setMode(m)
        // Round 7: the new layout reaches the TV only when the receiver's
        // playhead does, so a Cast receiver far behind is caught up here
        // too (Logan timed about 9 s for Stacked).
        if transport == .cast {
            AerioCastController.shared.compositeLayoutChanged(m.rawValue)
        }
    }
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
        // Initial layout: the app's stored Multiview layout preference
        // (Settings > Player > Multiview); the sheet's Layout row then
        // changes it for this composite session only.
        let mode = MultiviewLayoutMode(rawValue: UserDefaults.standard.string(forKey: MultiviewLayoutMode.storageKey) ?? "") ?? .auto
        layoutMode = mode
        debugLog("[MV-CAST] layout initial=\(mode.rawValue) tiles=\(tiles.count)")
        let accent = UIColor(ThemeManager.shared.accent)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        accent.getRed(&r, green: &g, blue: &b, alpha: &a)
        let comp = MultiviewCompositor(tileIDs: tileIDs, focusID: focus, mode: mode,
                                       accent: (Double(r), Double(g), Double(b)),
                                       style: MultiviewCompositeStyle.current())
        comp.setNames(Dictionary(tiles.map { ($0.id, $0.item.name) }, uniquingKeysWith: { a, _ in a }))
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
        loadLogos(tiles.map { ($0.id, $0.item.logoURL) })
        MultiviewCompositeTaps.shared.setPCMSink { [weak comp] id, pcm, rate in
            comp?.tilePCM(tileID: id, samples: pcm, sampleRate: rate)
        }
        MultiviewCompositeTaps.shared.setSourceRestartSink { [weak comp] id in
            comp?.tileSourceRestarted(tileID: id)
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
    /// `surfaceHidden`: false when the one tile left becomes the receiver's
    /// single-channel session (`handOffSingleTile`): it stays headless behind
    /// the remote card, exactly like a single channel played on AirPlay.
    func stop(_ reason: StopReason = .stopped, detail: String, endTransport: Bool = false,
              teardownTiles: Bool = true, surfaceHidden: Bool = true) {
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
        logoTask?.cancel()
        logoTask = nil
        playingState.removeAll()
        MultiviewCompositeTaps.shared.deactivate(restoreMute: surfaceHidden)
        if teardownTiles {
            DispatchQueue.main.async {
                guard !MultiviewCompositeSession.shared.isActive,
                      PlayerSession.shared.mode == .multiview else { return }
                debugLog("[MV-CAST] composite stopped: headless tiles torn down")
                PlayerSession.shared.stop()
            }
        } else {
            // Never silent headless playback (device log 2026-10-07
            // 13:30:15): the composite hid the phone player
            // (NowPlayingManager minimized) and a stop that keeps the tiles
            // left them playing hidden, with no card, no Now Playing and no
            // way back. Play Here expands before this runs and a restart is
            // active again, so both pass through. Anything else still
            // hidden afterward is surfaced full screen, or ended when no
            // tile is left.
            DispatchQueue.main.async {
                guard !MultiviewCompositeSession.shared.isActive,
                      PlayerSession.shared.mode == .multiview,
                      NowPlayingManager.shared.isMinimized,
                      !MultiviewBackgroundSession.shared.isActive else { return }
                let count = MultiviewStore.shared.tiles.count
                if !surfaceHidden, count > 0 {
                    debugLog("[MV-CAST] composite stopped (\(detail)): \(count) tile(s) stay headless for the receiver")
                    return
                }
                if count == 0 {
                    debugLog("[MV-CAST] composite stopped (\(detail)): no tiles left; Multiview ended")
                    PlayerSession.shared.stop()
                } else {
                    debugLog("[MV-CAST] composite stopped (\(detail)): \(count) hidden tile(s) surfaced full screen")
                    NowPlayingManager.shared.expand()
                }
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

    /// One tile left (round 7, device log 2026-10-07 15:47:22 Cast and
    /// 15:53:31 AirPlay: "composite tiles changed: 1", the composite kept
    /// running as a one-tile picture). The remaining channel goes to the
    /// receiver as a single-channel session:
    /// - Cast: the card's channel path (castPickedChannel). The new cast
    ///   content stops this composite through the castingContent observer,
    ///   which also ends the headless local Multiview: the receiver plays
    ///   the channel from its own proxy ingest.
    /// - AirPlay: the composite stops here, before the remaining tile
    ///   re-mounts as the sole tile (it does on 2 to 1, 15:53:31.370
    ///   "MV-Tile onAppear"). With no composite running, that tile is the
    ///   AirPlay route owner again (ownsAirPlay: the audio tile), so its
    ///   fresh tune takes the normal "route already selected: starting on
    ///   LAN" handover, and it stays headless behind the card.
    private func handOffSingleTile(_ tile: MultiviewTile) {
        guard let t = transport else { return }
        debugLog("[MV-CAST] composite: one tile left (\(tile.item.name)); the receiver plays it as a single channel (\(t == .cast ? "cast" : "airplay"))")
        switch t {
        case .cast:
            AerioCastController.shared.castPickedChannel(tile.item)
            // No castable stream: castPickedChannel surfaced it and the
            // composite is still the cast content; end it like Stop.
            if isActive {
                stop(detail: "one tile left, not castable", endTransport: true)
            }
        case .airPlay:
            stop(detail: "one tile left: \(tile.item.name) as a single channel on AirPlay",
                 teardownTiles: false, surfaceHidden: false)
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

    /// Channel logos for the composite (Settings > Multiview > Show
    /// Channel Logos), the same cropped images the local tiles draw.
    private var logoTask: Task<Void, Never>?

    private func loadLogos(_ tiles: [(id: String, url: URL?)]) {
        logoTask?.cancel()
        logoTask = Task { @MainActor [weak self] in
            for (id, url) in tiles {
                guard let url, let img = await MultiviewTileLogoOverlay.croppedLogo(url),
                      !Task.isCancelled, let cg = img.cgImage else { continue }
                self?.compositor?.setLogo(tileID: id, image: cg)
            }
        }
    }

    /// Last sampled playing state per tile (stall recovery detection).
    private var playingState: [String: Bool] = [:]

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
                let changed = self.compositor?.currentFocusID != id
                self.compositor?.setFocus(id)
                // Round 6: measure the receiver's lag behind the composite
                // at every focus change and nudge it to the live edge.
                if changed, self.transport == .cast {
                    Task { @MainActor in AerioCastController.shared.compositeFocusChanged(tileID: id) }
                }
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
                // Round 7: the composite takes 2 to 4 tiles. With one left
                // the receiver plays that channel as a normal single-channel
                // session instead of a one-tile composite.
                if ids.count == 1, ids != self.tileIDs, let last = tiles.first {
                    self.handOffSingleTile(last)
                    return
                }
                if ids != self.tileIDs {
                    let shown = Array(tiles.prefix(MultiviewCompositeLayout.maxTiles))
                    let added = shown.filter { !self.tileIDs.contains($0.id) }
                    self.tileIDs = ids
                    self.channelNames = shown.map(\.item.name)
                    self.compositor?.setNames(Dictionary(shown.map { ($0.id, $0.item.name) }, uniquingKeysWith: { a, _ in a }))
                    self.compositor?.setTiles(ids)
                    if !added.isEmpty { self.loadLogos(added.map { ($0.id, $0.item.logoURL) }) }
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
                comp.setStyle(MultiviewCompositeStyle.current())
                for id in self.tileIDs {
                    if let lag = MultiviewCompositeTaps.shared.displayLagSeconds(tileID: id) {
                        comp.setDisplayLag(tileID: id, seconds: lag)
                    }
                    if let p = MultiviewCompositeTaps.shared.playbackSample(tileID: id) {
                        let was = self.playingState[id]
                        self.playingState[id] = p.playing
                        comp.setPlayback(tileID: id, itemTime: p.itemTime, playing: p.playing,
                                         resumed: was == false && p.playing, remuxer: p.remuxer)
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

// MARK: - Style (Settings > Player > Multiview)

/// The local Multiview's appearance settings, read for the composite so the
/// cast grid and the sheet preview draw what the phone's own Multiview
/// draws (Logan 2026-10-07). Lengths are the local view's points; `scale`
/// maps them to composite pixels as if the phone's fullscreen Multiview
/// (landscape, the screen's short side tall) were the 720-line canvas.
struct MultiviewCompositeStyle: Equatable, Sendable {
    var focusStyle: MultiviewAudioFocusStyle = .centerIcon
    var padding = true
    var rounded = false
    var showLogos = false
    var logoPosition: MultiviewLogoPosition = .topLeft
    var logoSizePercent = multiviewLogoSizeDefault
    var scale: CGFloat = 1

    /// Local tile spacing with padding on (MultiviewContainerView.tileSpacing).
    static let paddingPoints: CGFloat = 8
    /// Local rounded tile radius (MultiviewTileView.tileCornerRadius).
    static let cornerPoints: CGFloat = 12
    /// Local audio-focus stroke width (audioFocusStrokeOverlay).
    static let strokePoints: CGFloat = 3
    /// Focus indicator after a focus change: fully shown this long, then
    /// faded out over `indicatorFadeSeconds` (Center Icon and the fading
    /// accent outline; the gray outline stays on).
    static let indicatorHoldSeconds: Double = 2
    static let indicatorFadeSeconds: Double = 0.5

    var spacingPx: CGFloat { padding ? (Self.paddingPoints * scale).rounded() : 0 }
    var cornerPx: CGFloat { rounded ? Self.cornerPoints * scale : 0 }

    @MainActor static func current() -> MultiviewCompositeStyle {
        let d = UserDefaults.standard
        var st = MultiviewCompositeStyle()
        st.focusStyle = MultiviewAudioFocusStyle(rawValue: d.string(forKey: MultiviewAudioFocusStyle.storageKey) ?? "") ?? .centerIcon
        st.padding = d.object(forKey: multiviewTilePaddingKey) as? Bool ?? true
        st.rounded = d.bool(forKey: multiviewTileCornersRoundedKey)
        st.showLogos = d.bool(forKey: multiviewShowLogosKey)
        st.logoPosition = MultiviewLogoPosition(rawValue: d.string(forKey: multiviewLogoPositionKey) ?? "") ?? .topLeft
        st.logoSizePercent = d.object(forKey: multiviewLogoSizeKey) as? Int ?? multiviewLogoSizeDefault
        let b = UIScreen.main.bounds
        let short = max(1, min(b.width, b.height))
        st.scale = CGFloat(MultiviewCompositeLayout.height) / short
        return st
    }
}

// MARK: - Overlays (drawn on the compose queue, CoreGraphics)

/// Full-canvas transparent overlays in composite pixels (top-left origin),
/// mirroring the local tile chrome for the current settings. Rebuilt only
/// when what they depend on changes.
enum MultiviewCompositeOverlay {
    static var canvas: CGSize { CGSize(width: MultiviewCompositeLayout.width, height: MultiviewCompositeLayout.height) }

    private static func render(_ draw: (CGContext) -> Void) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: canvas, format: format).image { draw($0.cgContext) }
        return img.cgImage.map { CIImage(cgImage: $0) }
    }

    /// White where each tile's rounded shape is (the clip mask).
    static func clipMask(rects: [CGRect], radius: CGFloat) -> CIImage? {
        render { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            for r in rects {
                ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: radius).cgPath)
            }
            ctx.fillPath()
        }
    }

    /// Channel logos (MultiviewTileLogoOverlay geometry, name strip hidden).
    static func logos(rects: [CGRect], tiles: [String], aspects: [String: CGFloat],
                      logos: [String: CGImage], style: MultiviewCompositeStyle) -> CIImage? {
        render { ctx in
            let k = style.scale
            let inset = 8 * k, pad = 4 * k
            let pct = CGFloat(min(max(style.logoSizePercent, 5), 25)) / 100
            for (i, rect) in rects.enumerated() where i < tiles.count {
                guard let cg = logos[tiles[i]], cg.width > 0, cg.height > 0 else { continue }
                let video = MultiviewCompositeLayout.videoRect(in: rect, aspect: aspects[tiles[i]] ?? 16.0 / 9.0)
                let hBase = max(video.height * pct - pad * 2, 1)
                let aspect = CGFloat(cg.width) / CGFloat(cg.height)
                let maxW = min(4 * hBase, max(video.width * 0.5 - pad * 2, 1))
                let h0 = hBase * min(max((3 / aspect).squareRoot(), 1), 2)
                let w = min(h0 * aspect, maxW)
                let h = w / aspect
                let bw = w + pad * 2, bh = h + pad * 2
                let x = style.logoPosition.isLeading ? video.minX + inset : video.maxX - inset - bw
                let y = style.logoPosition.isTop ? video.minY + inset : video.maxY - inset - bh
                let box = CGRect(x: x, y: y, width: bw, height: bh)
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
                ctx.addPath(UIBezierPath(roundedRect: box, cornerRadius: 6 * k).cgPath)
                ctx.fillPath()
                UIImage(cgImage: cg).draw(in: box.insetBy(dx: pad, dy: pad))
                ctx.restoreGState()
            }
        }
    }

    /// The audio-focus indicator for `style` on the focused tile: the
    /// Center Icon badge (accent speaker capsule over the channel name
    /// pill) or a 3 pt stroke on the tile shape (gray or accent).
    static func indicator(rect: CGRect, name: String, style: MultiviewCompositeStyle,
                          accent: UIColor) -> CIImage? {
        let k = style.scale
        return render { ctx in
            switch style.focusStyle {
            case .grayPersistent, .themeFading:
                let color = style.focusStyle == .grayPersistent ? UIColor(white: 0.55, alpha: 1) : accent
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(MultiviewCompositeStyle.strokePoints * k)
                ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: style.cornerPx).cgPath)
                ctx.strokePath()
            case .centerIcon:
                let symbolConfig = UIImage.SymbolConfiguration(pointSize: 22 * k, weight: .semibold)
                let symbol = UIImage(systemName: "speaker.wave.2.fill", withConfiguration: symbolConfig)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                let sSize = symbol?.size ?? CGSize(width: 22 * k, height: 22 * k)
                let cap = CGSize(width: sSize.width + 28 * k, height: sSize.height + 20 * k)
                let font = UIFont.systemFont(ofSize: 12 * k, weight: .semibold)
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: para]
                let maxW = min(220 * k, rect.width)
                let textW = min((name as NSString).size(withAttributes: attrs).width, maxW - 20 * k)
                let pill = CGSize(width: max(0, textW) + 20 * k, height: font.lineHeight + 8 * k)
                let total = cap.height + 8 * k + pill.height
                let top = rect.midY - total / 2
                let capRect = CGRect(x: rect.midX - cap.width / 2, y: top, width: cap.width, height: cap.height)
                let pillRect = CGRect(x: rect.midX - pill.width / 2, y: capRect.maxY + 8 * k,
                                      width: pill.width, height: pill.height)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 2 * k), blur: 6 * k,
                              color: UIColor.black.withAlphaComponent(0.45).cgColor)
                ctx.setFillColor(accent.cgColor)
                ctx.addPath(UIBezierPath(roundedRect: capRect, cornerRadius: cap.height / 2).cgPath)
                ctx.fillPath()
                ctx.restoreGState()
                symbol?.draw(in: CGRect(x: capRect.midX - sSize.width / 2, y: capRect.midY - sSize.height / 2,
                                        width: sSize.width, height: sSize.height))
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 1 * k), blur: 4 * k,
                              color: UIColor.black.withAlphaComponent(0.4).cgColor)
                ctx.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
                ctx.addPath(UIBezierPath(roundedRect: pillRect, cornerRadius: pill.height / 2).cgPath)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
                ctx.setLineWidth(0.5 * k)
                ctx.addPath(UIBezierPath(roundedRect: pillRect.insetBy(dx: 0.25 * k, dy: 0.25 * k),
                                         cornerRadius: pill.height / 2).cgPath)
                ctx.strokePath()
                (name as NSString).draw(with: CGRect(x: pillRect.minX + 10 * k, y: pillRect.minY + 4 * k,
                                                     width: max(0, textW), height: font.lineHeight),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: attrs, context: nil)
            }
        }
    }

}

// MARK: - Tile video decoder (keeps the composite playing in the background)

/// One composite tile's pictures, decoded straight from its TSHLSRemuxer
/// ingest with a VTDecompressionSession: no AVPlayer, no layer.
///
/// Why (device log 2026-10-07 11:55:52 to 11:56:32, 3-up cast, phone
/// locked): the tile AVPlayers stopped delivering pictures the moment the
/// app went to the background (AVPlayerItemVideoOutput gave nothing, the
/// loopback playlists went unfetched, AVP-PERF edge grew +4 s, +6 s,
/// +20 s) while the remuxers kept ingesting and the composite encoder,
/// rebuilt once on the background transition, kept encoding 30 fps with
/// nothing dropped. VideoToolbox sessions are invalidated on every
/// foreground/background transition (kVTInvalidSessionErr) and work again
/// once recreated, which the encoder rebuild in that log proves on this
/// device; the same rule applies to decompression sessions (FFmpeg and
/// GStreamer recreate them on kVTInvalidSessionErr). So the composite
/// decodes its own tiles, always, and recreates the session when it is
/// invalidated.
///
/// Timing: each tile has a picture clock (source PTS shown at a host
/// time). The focused tile's audio uses the SAME clock, so audio and
/// picture stay together by construction. The clock is seeded from the
/// tile player's measured position (so the composite keeps the player's
/// learned distance behind live) and advances at wall rate; it holds when
/// the ingest runs dry and resumes when 2 s are buffered again.
final class MultiviewTileVideoDecoder: @unchecked Sendable {
    struct AccessUnit {
        var dts: Int64   // unwrapped 90 kHz
        var pts: Int64   // unwrapped 90 kHz
        var key: Bool
        var nals: [[UInt8]]
        var params: [[UInt8]]?
        var bytes: Int
    }

    let tileID: String
    /// Measured on-screen source PTS of the tile player (33-bit), if known.
    var anchorHint: (() -> Int64?)?
    /// The picture clock (re)anchored or resumed (reason), any queue.
    var onClockJump: ((String) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()

    // Demux (queue)
    private var carry: [UInt8] = []
    private var pmtPID = -1
    private var videoPID = -1
    private var hevc = false
    private var pes: [UInt8] = []
    private var lastRaw: Int64 = -1
    private var wrapBase: Int64 = 0
    private var paramSets: [Int: [UInt8]] = [:]

    // Buffer + decode (queue)
    private var aus: [AccessUnit] = []
    private var bufferedBytes = 0
    private var next = 0
    private var session: VTDecompressionSession?
    private var sessionParams: [[UInt8]]?
    private var needKey = true
    private var lastRebuildAt: CFTimeInterval = 0
    private var firstAUHost: CFTimeInterval = 0
    private var stalled = false
    private var stalls = 0
    private var rebuilds = 0
    private var invalidations = 0
    private var decoded = 0
    private var shown = 0
    private var lastStatsAt: CFTimeInterval = 0
    private var stopped = false

    // Clock + frames (lock)
    private var anchor: (src: Int64, host: CFTimeInterval)?
    private var frames: [(pts: Int64, pb: CVPixelBuffer)] = []
    private var lastShownPTS: Int64 = .min
    /// Compose ticks that found no decoded picture at or before the clock
    /// (the composite then repeats the tile's previous picture).
    private var misses = 0
    /// Largest PTS minus DTS seen since the last stats line (B-frame
    /// reorder depth), 90 kHz.
    private var maxReorderTicks: Int64 = 0

    static let maxBufferedBytes = 48 * 1024 * 1024
    /// Decoded pictures kept for the clock. Was 6 (device log 2026-10-07
    /// 13:28:56 to 13:30:11): ESPNU decoded 600 pictures per 10 s but
    /// showed 0.0 to 2.0 fps for the whole session while the other tiles
    /// showed 25 to 30. Decode runs 100 ms of DTS ahead of the clock, so at
    /// 59.94 fps the 6 newest pictures by PTS were all still in the future
    /// as soon as the stream reorders (PTS ahead of DTS); the one due now
    /// was evicted and the tile froze on an old picture while its audio
    /// followed the clock (video behind audio). Decode now also stops once
    /// `maxFuturePictures` wait ahead of the clock.
    static let maxFrames = 12
    static let maxFuturePictures = 9
    static let resumeAheadTicks: Int64 = 2 * 90_000
    static let maxOutput = CGSize(width: 960, height: 540)

    init(tileID: String) {
        self.tileID = tileID
        queue = DispatchQueue(label: "aerio.mv-composite.decode.\(tileID.prefix(8))", qos: .userInitiated)
    }

    var isAnchored: Bool { lock.lock(); defer { lock.unlock() }; return anchor != nil }

    /// Source PTS (unwrapped, 90 kHz) of the picture last handed to the
    /// composite, nil before the first one.
    var lastShownSourcePTS: Int64? {
        lock.lock(); defer { lock.unlock() }
        return lastShownPTS == .min ? nil : lastShownPTS
    }

    /// Source PTS (33-bit) the picture clock shows at `host`, nil until anchored.
    func displayedPTS(host: CFTimeInterval) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let a = anchor else { return nil }
        return (a.src + Int64((host - a.host) * 90_000)) & TSLANAudioRewriter.pts33Mask
    }

    func stop() {
        queue.sync {
            stopped = true
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            aus.removeAll()
        }
        lock.lock(); frames.removeAll(); anchor = nil; lock.unlock()
    }

    // MARK: Ingest

    func feed(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.carry += data
            var i = 0
            while i + 188 <= self.carry.count {
                if self.carry[i] != 0x47 { i += 1; continue }
                self.packet(Array(self.carry[i..<(i + 188)]))
                i += 188
            }
            self.carry.removeFirst(i)
        }
    }

    private func packet(_ p: [UInt8]) {
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let pusi = p[1] & 0x40 != 0
        if pid == 0, pusi {
            if let pmt = TSLANAudioRewriter.firstPMTPID(p) { pmtPID = pmt }
            return
        }
        if pid == pmtPID, pusi, let info = TSLANAudioRewriter.parsePMT(p) {
            if info.videoPID >= 0, info.videoPID != videoPID || (info.videoType == 0x24) != hevc {
                pes.removeAll()
                videoPID = info.videoPID
                hevc = info.videoType == 0x24
            }
            return
        }
        guard pid == videoPID, let payload = TSLANAudioRewriter.payload(p) else { return }
        if pusi { flushPES() }
        if pusi || !pes.isEmpty { pes += payload }
    }

    private func unwrap(_ raw: Int64) -> Int64 {
        let period = TSLANAudioRewriter.pts33Mask + 1
        if lastRaw >= 0 {
            if raw < lastRaw && lastRaw - raw > period / 2 { wrapBase += period }
            else if raw > lastRaw && raw - lastRaw > period / 2 { wrapBase -= period }
        }
        lastRaw = raw
        return raw + wrapBase
    }

    private func flushPES() {
        defer { pes.removeAll(keepingCapacity: true) }
        guard pes.count >= 14, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return }
        let flags = pes[7] >> 6
        guard flags & 0x2 != 0 else { return }
        let start = 9 + Int(pes[8])
        guard start < pes.count else { return }
        let ptsRaw = TSLANAudioRewriter.decodePTS(pes, 9)
        let dtsRaw = flags == 3 && pes.count >= 19 ? TSLANAudioRewriter.decodePTS(pes, 14) : ptsRaw
        let dts = unwrap(dtsRaw)
        var ptsDelta = (ptsRaw - dtsRaw) & TSLANAudioRewriter.pts33Mask
        if ptsDelta > TSLANAudioRewriter.pts33Mask / 2 { ptsDelta -= TSLANAudioRewriter.pts33Mask + 1 }
        let pts = dts + ptsDelta
        var nals: [[UInt8]] = []
        var key = false
        for nal in Self.splitAnnexB(pes, from: start) where !nal.isEmpty {
            let t = hevc ? Int((nal[0] >> 1) & 0x3F) : Int(nal[0] & 0x1F)
            if hevc {
                if t == 32 || t == 33 || t == 34 { paramSets[t] = nal; continue }
                if t == 35 { continue }
                if (16...21).contains(t) { key = true }
            } else {
                if t == 7 || t == 8 { paramSets[t] = nal; continue }
                if t == 9 { continue }
                if t == 5 { key = true }
            }
            nals.append(nal)
        }
        guard !nals.isEmpty else { return }
        var params: [[UInt8]]?
        if key {
            let order = hevc ? [32, 33, 34] : [7, 8]
            let sets = order.compactMap { paramSets[$0] }
            if sets.count == order.count { params = sets }
        }
        let bytes = nals.reduce(0) { $0 + $1.count + 4 }
        append(AccessUnit(dts: dts, pts: pts, key: key, nals: nals, params: params, bytes: bytes))
    }

    static func splitAnnexB(_ b: [UInt8], from: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = from
        var nalStart = -1
        let n = b.count
        while i + 2 < n {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if nalStart >= 0 {
                    var end = i
                    while end > nalStart, b[end - 1] == 0 { end -= 1 }
                    out.append(Array(b[nalStart..<end]))
                }
                i += 3
                nalStart = i
                continue
            }
            i += 1
        }
        if nalStart >= 0, nalStart < n { out.append(Array(b[nalStart..<n])) }
        return out
    }

    private func append(_ au: AccessUnit) {
        if let last = aus.last {
            let d = au.dts - last.dts
            // A retried tile's new connection replays the server's backlog:
            // drop what is already buffered.
            if d <= 0, d > -60 * 90_000 { return }
            if d > 10 * 90_000 || d <= -60 * 90_000 {
                reset(reason: String(format: "source jump %+.1f s", Double(d) / 90_000))
            }
        }
        if aus.isEmpty { firstAUHost = CACurrentMediaTime() }
        aus.append(au)
        bufferedBytes += au.bytes
        while bufferedBytes > Self.maxBufferedBytes, aus.count > 1 {
            // Drop the oldest GOP.
            var cut = 1
            while cut < aus.count, !aus[cut].key { cut += 1 }
            if cut >= aus.count { cut = aus.count - 1 }
            dropFront(cut)
        }
    }

    private func dropFront(_ count: Int) {
        guard count > 0 else { return }
        for k in 0..<count { bufferedBytes -= aus[k].bytes }
        aus.removeFirst(count)
        next = max(0, next - count)
    }

    /// The tile's ingest restarted on a new connection: forget the old
    /// connection's demux state and buffer (see
    /// MultiviewCompositor.tileSourceRestarted).
    func restartSource() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.carry.removeAll()
            self.pes.removeAll()
            self.lastRaw = -1
            self.wrapBase = 0
            self.reset(reason: "tile ingest restarted on a new connection")
        }
    }

    private func reset(reason: String) {
        aus.removeAll()
        bufferedBytes = 0
        next = 0
        needKey = true
        stalled = false
        lock.lock(); anchor = nil; frames.removeAll(); lastShownPTS = .min; lock.unlock()
        debugLog("[MV-CAST] tile decode \(tileID): buffer reset (\(reason)); picture clock re-anchors")
    }

    // MARK: Pump (compose tick)

    /// Decodes what the picture clock needs at `host`. Async on the decoder queue.
    func pump(host: CFTimeInterval, background: Bool) {
        queue.async { [weak self] in self?.pumpOnQueue(host: host, background: background) }
    }

    private func pumpOnQueue(host: CFTimeInterval, background: Bool) {
        guard !stopped, !aus.isEmpty else { return }
        lock.lock(); var a = anchor; lock.unlock()
        if a == nil {
            guard let firstKey = aus.firstIndex(where: \.key) else { return }
            let newest = aus[aus.count - 1].pts
            var src: Int64
            var how: String
            if let hint = anchorHint?() {
                var v = (newest & ~TSLANAudioRewriter.pts33Mask) + hint
                let period = TSLANAudioRewriter.pts33Mask + 1
                if v - newest > period / 2 { v -= period }
                if newest - v > period / 2 { v += period }
                src = v
                how = "player position"
            } else if host - firstAUHost >= 4 {
                src = newest - 12 * 90_000
                how = "buffer (no player position)"
            } else {
                return
            }
            let floorPTS = aus[firstKey].pts
            if src < floorPTS { src = floorPTS }
            if src > newest { src = newest }
            a = (src, host)
            lock.lock(); anchor = a; lock.unlock()
            seek(to: src)
            debugLog(String(format: "[MV-CAST] tile decode %@: picture clock anchored from %@, %.1f s behind the newest ingested picture, %.1f s buffered",
                            tileID, how, Double(newest - src) / 90_000, Double(newest - aus[0].dts) / 90_000))
            onClockJump?("picture clock anchored")
        }
        guard var anchorNow = a else { return }
        var target = anchorNow.src + Int64((host - anchorNow.host) * 90_000)
        let newestDTS = aus[aus.count - 1].dts
        if stalled {
            if newestDTS - anchorNow.src >= Self.resumeAheadTicks {
                stalled = false
                anchorNow = (anchorNow.src, host)
                lock.lock(); anchor = anchorNow; lock.unlock()
                target = anchorNow.src
                debugLog("[MV-CAST] tile decode \(tileID): ingest back, picture clock resumes")
                onClockJump?("picture clock resumed after a stall")
            } else {
                anchorNow = (anchorNow.src, host)
                lock.lock(); anchor = anchorNow; lock.unlock()
                target = anchorNow.src
            }
        } else if target > newestDTS + 45_000 {
            stalled = true
            stalls += 1
            anchorNow = (newestDTS, host)
            lock.lock(); anchor = anchorNow; lock.unlock()
            target = newestDTS
            debugLog("[MV-CAST] tile decode \(tileID): ingest ran dry, picture clock holds (stall \(stalls))")
        }
        if target < aus[0].dts {
            // Fell out of the buffer: jump to its oldest picture.
            let src = aus.first(where: \.key)?.pts ?? aus[0].pts
            lock.lock(); anchor = (src, host); lock.unlock()
            target = src
            seek(to: src)
            debugLog("[MV-CAST] tile decode \(tileID): picture clock fell behind the buffer; re-anchored")
            onClockJump?("picture clock re-anchored")
        }
        // Far behind the clock (session rebuilt, app back): restart at the
        // keyframe before the target instead of decoding the whole gap.
        if next < aus.count, aus[next].dts < target - 90_000 { seek(to: target) }
        var budget = 40
        while next < aus.count, aus[next].dts <= target + 9_000, budget > 0 {
            lock.lock()
            let waiting = frames.reduce(0) { $0 + ($1.pts > target ? 1 : 0) }
            lock.unlock()
            if waiting >= Self.maxFuturePictures { break }
            maxReorderTicks = max(maxReorderTicks, aus[next].pts - aus[next].dts)
            decode(aus[next])
            next += 1
            budget -= 1
        }
        // Keep from the keyframe before (target - 1 s): a rebuild restarts there.
        if let k = aus.lastIndex(where: { $0.key && $0.pts <= target - 90_000 }), k > 0, k <= next {
            dropFront(k)
        }
        if host - lastStatsAt >= 10 {
            let span = lastStatsAt > 0 ? host - lastStatsAt : 10
            lastStatsAt = host
            let newest = aus[aus.count - 1].pts
            lock.lock(); let missed = misses; misses = 0; let held = frames.count; lock.unlock()
            debugLog(String(format: "[MV-CAST] tile decode %@ bg=%@ shown=%.1f fps decoded=%d missed=%d held=%d reorder=%.0f ms behind=%.1f s buffered=%.1f s stalls=%d session=%@ rebuilds=%d invalidated=%d",
                            tileID, background ? "yes" : "no", Double(shown) / span, decoded, missed, held,
                            Double(maxReorderTicks) / 90, Double(newest - target) / 90_000,
                            Double(newest - aus[0].dts) / 90_000,
                            stalls, session == nil ? "none" : "live", rebuilds, invalidations))
            shown = 0
            decoded = 0
            maxReorderTicks = 0
        }
    }

    /// Decode restarts at the last keyframe at or before `src`.
    private func seek(to src: Int64) {
        guard let k = aus.lastIndex(where: { $0.key && $0.pts <= src }) ?? aus.firstIndex(where: \.key) else { return }
        next = k
        needKey = true
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        lock.lock(); frames.removeAll(); lastShownPTS = .min; lock.unlock()
    }

    private func decode(_ au: AccessUnit) {
        if au.key, let params = au.params, params != sessionParams || session == nil {
            makeSession(params)
        }
        guard let session else { return }
        if needKey {
            guard au.key else { return }
            needKey = false
        }
        var sample: [UInt8] = []
        sample.reserveCapacity(au.bytes)
        for nal in au.nals {
            let n = UInt32(nal.count)
            sample += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            sample += nal
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: sample.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: sample.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              sample.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                     offsetIntoDestination: 0, dataLength: sample.count) }) == noErr
        else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: au.pts, timescale: 90_000),
                                        decodeTimeStamp: CMTime(value: au.dts, timescale: 90_000))
        var size = sample.count
        var sb: CMSampleBuffer?
        guard let fd = formatDescription,
              CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return }
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, pts, _ in
            guard let self, status == noErr, let image else { return }
            self.lock.lock()
            self.frames.append((pts.value, image))
            self.frames.sort { $0.pts < $1.pts }
            if self.frames.count > Self.maxFrames { self.frames.removeFirst(self.frames.count - Self.maxFrames) }
            self.lock.unlock()
        }
        if st == noErr {
            decoded += 1
        } else if st == kVTInvalidSessionErr {
            // Foreground/background transition: the session is gone.
            invalidations += 1
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            sessionParams = nil
            needKey = true
            debugLog("[MV-CAST] tile decode \(tileID): session invalidated (app \(UIApplication.shared.applicationState == .background ? "background" : "transition")); rebuilding at the next keyframe")
            if let k = aus.lastIndex(where: { $0.key && $0.dts <= au.dts }) { next = max(0, k - 1) }
        }
    }

    private var formatDescription: CMVideoFormatDescription?

    private func makeSession(_ params: [[UInt8]]) {
        let now = CACurrentMediaTime()
        if session == nil, sessionParams == nil, rebuilds > 0, now - lastRebuildAt < 1 { return }
        lastRebuildAt = now
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        sessionParams = nil
        guard let fd = Self.makeFormat(params, hevc: hevc) else {
            debugLog("[MV-CAST] tile decode \(tileID): parameter sets rejected")
            return
        }
        let dims = CMVideoFormatDescriptionGetPresentationDimensions(fd, usePixelAspectRatio: true, useCleanAperture: true)
        let scale = min(1, Self.maxOutput.width / max(dims.width, 1), Self.maxOutput.height / max(dims.height, 1))
        let w = max(2, Int((dims.width * scale / 2).rounded()) * 2)
        let h = max(2, Int((dims.height * scale / 2).rounded()) * 2)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fd,
                                              decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else {
            rebuilds += 1
            debugLog("[MV-CAST] tile decode \(tileID): session create failed status=\(st)")
            return
        }
        rebuilds += 1
        session = s
        sessionParams = params
        formatDescription = fd
        needKey = true
        debugLog("[MV-CAST] tile decode \(tileID): \(hevc ? "HEVC" : "H.264") session \(rebuilds == 1 ? "created" : "rebuilt (\(rebuilds - 1))") \(Int(dims.width))x\(Int(dims.height)) -> \(w)x\(h)\(UIApplication.shared.applicationState == .background ? " in background" : "")")
    }

    static func makeFormat(_ sets: [[UInt8]], hevc: Bool) -> CMVideoFormatDescription? {
        let ptrs: [UnsafeMutablePointer<UInt8>] = sets.map { s in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, s.count))
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let cptrs: [UnsafePointer<UInt8>] = ptrs.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMFormatDescription?
        let st: OSStatus = cptrs.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { ss in
                hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        return st == noErr ? fd : nil
    }

    // MARK: Frames (compose queue)

    /// The newest decoded picture at or before the clock, if it is new.
    func frame(host: CFTimeInterval) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let a = anchor else { return nil }
        let target = a.src + Int64((host - a.host) * 90_000)
        guard let idx = frames.lastIndex(where: { $0.pts <= target }) else {
            if !frames.isEmpty || lastShownPTS != .min { misses += 1 }
            return nil
        }
        let f = frames[idx]
        frames.removeFirst(idx)
        guard f.pts != lastShownPTS else { return nil }
        lastShownPTS = f.pts
        queue.async { [weak self] in self?.shown += 1 }
        return f.pb
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
    /// Audio is muxed this far ahead of the video it plays with. Zero
    /// (device log 2026-10-07): with 300 ms, a reader that joins at a key
    /// frame (the Cast proxy, the AirPlay remuxer) gets that GOP's video
    /// from the key frame but its audio only from key + 300 ms, because the
    /// first 300 ms went out with the previous GOP. Every composite cast
    /// logged `seg=0 vpts=0.000 apts=0.299` (11:21:27, 11:52:39, 13:28:52).
    /// The receiver appends the demuxed renditions in MSE sequence mode
    /// (see CastFMP4Remuxer.timelineBasePTS), which places each rendition's
    /// first frame at 0, so the whole session played its audio 299 ms
    /// early. Muxed at the video's own time the joining reader gets audio
    /// from the key frame on; it also leaves late tile audio 300 ms more
    /// time to arrive before the mux fills the slot with silence.
    static let audioLeadTicks: Int64 = 0
    /// Per-tile audio history kept for a focus switch.
    static let audioRingTicks: Int64 = 25 * 90_000
    static let aacFrameTicks: Int64 = 1920   // 1024 samples at 48 kHz

    var onFailure: (((MultiviewCompositeSession.StopReason, String)) -> Void)?
    /// No new picture from any tile for this long while backgrounded is
    /// logged (diagnostic only; the composite keeps running).
    static let backgroundNoPictureSeconds: Double = 1.5
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
    /// The focused tile (read under the lock).
    var currentFocusID: String { lock.lock(); defer { lock.unlock() }; return focusID }
    private var lagSeconds: [String: Double] = [:]
    private var stopped = false
    private var lastComposeHost: CFTimeInterval = 0
    /// Focused-tile PCM from the player's audio tap, newest arrival.
    private var tapPCMAt: [String: CFTimeInterval] = [:]
    private var style: MultiviewCompositeStyle
    private var names: [String: String] = [:]
    private var logos: [String: CGImage] = [:]
    /// Host time of the last focus change (indicator fade, latency log).
    private var focusChangedHost: CFTimeInterval = 0
    /// Per-tile VideoToolbox decoders fed from the ingest taps: the
    /// composite's pictures and the focused tile's audio clock.
    private var decoders: [String: MultiviewTileVideoDecoder] = [:]
    /// Last measured player position per tile (33-bit source PTS and host),
    /// the decoder's first anchor.
    private var measuredShared: [String: (pts: Int64, host: CFTimeInterval, playing: Bool)] = [:]
    /// The focused tile's audio mapping (lock): composite PTS = source PTS
    /// + offset, for the A/V offset log on the compose queue.
    private var audioOffsetShared: (tileID: String, offset: Int64)?
    /// Compose queue: when the A/V offset was last logged, and whether
    /// the next tick should log it (set by a re-anchor or a focus change).
    private var avLoggedAt: CFTimeInterval = 0
    /// The current normalizer's measured codec delay (lock), for that log.
    private var normalizerDelayShared: Int64 = 0
    private var normalizerDelayTicks: Int64 { lock.lock(); defer { lock.unlock() }; return normalizerDelayShared }

    // Compose queue
    /// Composite grid layout (lock): the sheet's Layout row changes it
    /// live (2026-10-07), so it is read under the lock each frame.
    private var mode: MultiviewLayoutMode
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
    /// Overlay cache (compose queue).
    private var overlayKey = ""
    private var clipMaskImage: CIImage?
    private var logoOverlay: CIImage?
    private var indicatorOverlay: CIImage?
    /// Background diagnostic (compose queue).
    private var lastAnyPixelsHost: CFTimeInterval = 0
    private var noPictureLogged = false

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
    /// Bumped on every re-anchor / refocus / pause: the mux drops queued
    /// frames of older epochs, so a switched-away tile's audio (queued up
    /// to its display lag ahead) never plays after the switch.
    private var audioEpoch = 0
    /// The tile player's on-screen source PTS (90 kHz, 33-bit), measured
    /// from its item time and its remuxer's segment map, and when.
    private var measured: [String: (pts: Int64, host: CFTimeInterval, playing: Bool)] = [:]
    /// Why the next anchor happens (logged with it).
    private var anchorReason = "start"
    /// True when the current anchor used neither a measured position nor
    /// a known lag (the 6 s guess): re-anchor once either is known.
    private var anchorGuessed = false
    private var driftStrikes = 0
    /// Pending focus-latency log: set on refocus, logged at the first
    /// enqueued audio of the new tile.
    private var focusLatencyFrom: CFTimeInterval?
    private var measuredRejectedLogged: Set<String> = []

    // Mux queue
    private var muxer = MultiviewCompositeTSMuxer()
    private var server: MultiviewCompositeTSServer?
    private var pendingAudio: [(pts: Int64, adts: [UInt8])] = []
    private var muxEpoch = 0
    private var lastAudioPTS: Int64 = -1
    private var silentFrame: [UInt8]?
    private var sawKeyframe = false

    init(tileIDs: [String], focusID: String, mode: MultiviewLayoutMode, accent: (Double, Double, Double),
         style: MultiviewCompositeStyle) {
        self.tileIDs = tileIDs
        self.focusID = focusID
        self.mode = mode
        self.accent = accent
        self.style = style
        for id in tileIDs { decoders[id] = makeDecoder(id) }
    }

    private func makeDecoder(_ id: String) -> MultiviewTileVideoDecoder {
        let d = MultiviewTileVideoDecoder(tileID: id)
        d.anchorHint = { [weak self] in
            guard let self else { return nil }
            self.lock.lock(); let m = self.measuredShared[id]; self.lock.unlock()
            guard let m, CACurrentMediaTime() - m.host < 1.5 else { return nil }
            let age = CACurrentMediaTime() - m.host
            return (m.pts + (m.playing ? Int64(age * 90_000) : 0)) & TSLANAudioRewriter.pts33Mask
        }
        d.onClockJump = { [weak self] reason in
            self?.audioQueue.async {
                guard let self, !self.isStopped, self.snapshot().focus == id else { return }
                self.anchorReason = reason
                self.reanchorFocused()
            }
        }
        return d
    }

    private func decoder(_ id: String) -> MultiviewTileVideoDecoder? {
        lock.lock(); defer { lock.unlock() }
        return decoders[id]
    }

    /// Settings > Multiview changed while the composite runs (polled).
    func setStyle(_ st: MultiviewCompositeStyle) {
        lock.lock(); style = st; lock.unlock()
    }

    /// Re-lays out the composite from the next frame on. The audio-focus
    /// indicator does NOT show again (Logan, round 7: picking Default in the
    /// Layout row flashed the indicator on the audio tile, then it faded);
    /// it shows on a focus change and on a tile rearrange only.
    func setMode(_ m: MultiviewLayoutMode) {
        lock.lock(); mode = m; lock.unlock()
    }

    func setNames(_ n: [String: String]) {
        lock.lock(); names.merge(n) { _, new in new }; lock.unlock()
    }

    func setLogo(tileID: String, image: CGImage) {
        lock.lock(); logos[tileID] = image; lock.unlock()
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
            lastAnyPixelsHost = t0
            lock.lock(); lastComposeHost = t0; focusChangedHost = t0; lock.unlock()
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
        lock.lock(); stopped = true; let ds = Array(decoders.values); decoders.removeAll(); lock.unlock()
        ds.forEach { $0.stop() }
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
        let at = CACurrentMediaTime()
        lock.lock()
        let changed = focusID != id
        focusID = id
        if changed { focusChangedHost = at }
        lock.unlock()
        guard changed else { return }
        debugLog("[MV-CAST] composite focus -> \(id)")
        audioQueue.async { [weak self] in
            self?.focusLatencyFrom = at
            self?.anchorReason = "focus change"
            self?.refocusAudio()
        }
    }

    func setTiles(_ ids: [String]) {
        // A rearrange is an interaction: the indicator shows again.
        lock.lock()
        tileIDs = ids
        focusChangedHost = CACurrentMediaTime()
        var gone: [MultiviewTileVideoDecoder] = []
        for (id, d) in decoders where !ids.contains(id) { gone.append(d); decoders[id] = nil }
        for id in ids where decoders[id] == nil { decoders[id] = makeDecoder(id) }
        lock.unlock()
        gone.forEach { $0.stop() }
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
            // The picture clock owns the timing once the decoder runs.
            guard let self, !self.isStopped, tileID == self.snapshot().focus,
                  self.decoder(tileID)?.isAnchored != true else { return }
            let first = self.tapPCMAt[tileID] == nil
            self.tapPCMAt[tileID] = CACurrentMediaTime()
            if first {
                debugLog("[MV-CAST] composite audio: tile \(tileID) via player audio tap (\(sampleRate) Hz)")
            }
            let key = "pcm-\(sampleRate)"
            if self.normalizer == nil || self.normalizerKey != key {
                self.normalizer = MultiviewAudioNormalizer(pcmSampleRate: sampleRate)
                self.normalizerKey = key
                let d = self.normalizer?.codecDelayTicks ?? 0
                self.lock.lock(); self.normalizerDelayShared = d; self.lock.unlock()
            }
            // The tap delivers just ahead of output; the frame's start time
            // is its arrival minus its own duration.
            let start = now - Int64(samples.count / 2) * 90_000 / Int64(max(1, sampleRate))
            guard let produced = self.normalizer?.feedPCM(samples, mappedPTS: start) else { return }
            self.enqueueAudio(produced.filter { $0.pts > self.audioFloor }, tileID: tileID)
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
        var gotPixels = false
        for (n, id) in tiles.enumerated() {
            // The tile's own decoder once its picture clock runs (it keeps
            // running in the background); the player's output only until then.
            let dec = decoder(id)
            dec?.pump(host: host, background: backgrounded)
            let pbOpt = dec?.isAnchored == true
                ? dec?.frame(host: host)
                : MultiviewCompositeTaps.shared.newPixelBuffer(tileID: id, hostTime: host)
            if let pb = pbOpt {
                gotPixels = true
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
        logAVOffset(focus: focus, compositePTS: pts, host: host)
        if gotPixels {
            lastAnyPixelsHost = host
            if noPictureLogged {
                noPictureLogged = false
                debugLog("[MV-CAST] composite tile pictures flowing again\(backgrounded ? " (background)" : "")")
            }
        } else if !noPictureLogged, host - lastAnyPixelsHost > Self.backgroundNoPictureSeconds, backgrounded {
            // Diagnostic only (device log 2026-10-07 11:55:54): the tiles
            // decode on the phone now, so this should not appear.
            noPictureLogged = true
            debugLog(String(format: "[MV-CAST] composite background: no new tile picture for %.1f s", host - lastAnyPixelsHost))
        }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { dropped += 1; return }
        let image = compose(tiles: tiles, focus: focus, host: host)
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
                self?.encoded(status: st, sample: sample, pts: pts, submittedAt: submittedAt, gen: gen,
                              requestedKey: key)
            }
        if status != noErr {
            inFlight -= 1
            dropped += 1
            if status == kVTInvalidSessionErr { encoderInvalidated(host: host) }
        }
    }

    /// Compose queue. The composite's own audio to video offset for the
    /// focused tile, in ms: the source time its audio carries at this
    /// frame's composite PTS minus the source time of the picture this
    /// frame shows for it. Positive = audio ahead of the picture. Logged
    /// after every audio anchor or focus change and every 10 s. It covers
    /// the phone side only (anchoring, decoded picture choice, held
    /// pictures); the codec delay is already inside the audio PTS, and the
    /// join lead is the `seg=0 vpts apts` line of the Cast proxy.
    private func logAVOffset(focus: String, compositePTS: Int64, host: CFTimeInterval) {
        lock.lock()
        let audio = audioOffsetShared
        let due = avLoggedAt == 0 || host - avLoggedAt >= 10
        lock.unlock()
        guard due, let audio, audio.tileID == focus,
              let shown = decoder(focus)?.lastShownSourcePTS else { return }
        let mask = TSLANAudioRewriter.pts33Mask
        let audioSource = (compositePTS - audio.offset) & mask
        var diff = (audioSource - (shown & mask)) & mask
        if diff > mask / 2 { diff -= mask + 1 }
        lock.lock(); avLoggedAt = host; lock.unlock()
        let codecDelay = normalizerDelayTicks
        debugLog(String(format: "[MV-CAST] composite A/V offset tile=%@ audio-video=%+.0f ms (+ = audio ahead of the picture; codec delay %.1f ms compensated, mux audio lead %.0f ms)",
                        focus, Double(diff) / 90, Double(codecDelay) / 90, Double(Self.audioLeadTicks) / 90))
    }

    private func compose(tiles: [String], focus: String, host: CFTimeInterval) -> CIImage {
        let full = CGRect(x: 0, y: 0, width: MultiviewCompositeLayout.width, height: MultiviewCompositeLayout.height)
        lock.lock()
        let st = style
        let nameMap = names
        let logoMap = logos
        let focusAt = focusChangedHost
        let mode = self.mode
        lock.unlock()
        // Round 3 (Logan 2026-10-07): the composite draws what the local
        // Multiview draws for the user's settings: tile padding, square or
        // rounded tiles, the audio-focus indicator style, channel logos. No
        // borders on the other tiles (the local grid has none).
        let rects = MultiviewCompositeLayout.tileRects(count: tiles.count, mode: mode, spacing: st.spacingPx)
        var aspects: [String: CGFloat] = [:]
        for id in tiles {
            if let pb = latest[id], CVPixelBufferGetHeight(pb) > 0 {
                let a = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(CVPixelBufferGetHeight(pb))
                aspects[id] = (a * 100).rounded() / 100
            }
        }
        let focusIndex = tiles.firstIndex(of: focus)
        let key = "\(rects)|\(tiles)|\(focus)|\(st)|\(aspects.sorted { $0.key < $1.key })|\(logoMap.keys.sorted())|\(focusIndex.map { nameMap[tiles[$0]] ?? "" } ?? "")"
        if key != overlayKey {
            overlayKey = key
            clipMaskImage = st.cornerPx > 0 ? MultiviewCompositeOverlay.clipMask(rects: rects, radius: st.cornerPx) : nil
            logoOverlay = st.showLogos && !logoMap.isEmpty
                ? MultiviewCompositeOverlay.logos(rects: rects, tiles: tiles, aspects: aspects, logos: logoMap, style: st)
                : nil
            let accentColor = UIColor(red: CGFloat(accent.0), green: CGFloat(accent.1), blue: CGFloat(accent.2), alpha: 1)
            indicatorOverlay = focusIndex.flatMap { i in
                i < rects.count ? MultiviewCompositeOverlay.indicator(rect: rects[i], name: nameMap[focus] ?? "",
                                                                       style: st, accent: accentColor) : nil
            }
        }
        var videos = CIImage(color: .black).cropped(to: full)
        for (i, rect) in rects.enumerated() where i < tiles.count {
            let id = tiles[i]
            let tileArea = MultiviewCompositeLayout.flipped(rect)
            guard let pb = latest[id] else { continue }
            let src = CIImage(cvPixelBuffer: pb)
            let w = src.extent.width, h = src.extent.height
            guard w > 0, h > 0 else { continue }
            let fit = MultiviewCompositeLayout.flipped(MultiviewCompositeLayout.videoRect(in: rect, aspect: w / h))
            let placed = src
                .transformed(by: CGAffineTransform(scaleX: fit.width / w, y: fit.height / h))
                .transformed(by: CGAffineTransform(translationX: fit.minX - src.extent.minX * fit.width / w,
                                                   y: fit.minY - src.extent.minY * fit.height / h))
                .cropped(to: tileArea)
            videos = placed.composited(over: videos)
        }
        var image = videos
        if let mask = clipMaskImage {
            image = videos.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: full),
                kCIInputMaskImageKey: mask,
            ])
        }
        if let logoOverlay { image = logoOverlay.composited(over: image) }
        if let indicator = indicatorOverlay {
            let alpha = Self.indicatorAlpha(style: st.focusStyle, since: host - focusAt)
            if alpha >= 0.999 {
                image = indicator.composited(over: image)
            } else if alpha > 0.001 {
                image = indicator.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                ]).composited(over: image)
            }
        }
        return image.cropped(to: full)
    }

    /// Indicator opacity `since` seconds after the last focus change: the
    /// gray outline stays on; Center Icon and the accent outline hold for
    /// 2 s, then fade out over 0.5 s (ease in out).
    static func indicatorAlpha(style: MultiviewAudioFocusStyle, since: Double) -> CGFloat {
        if style == .grayPersistent { return 1 }
        let hold = MultiviewCompositeStyle.indicatorHoldSeconds
        let fade = MultiviewCompositeStyle.indicatorFadeSeconds
        if since <= hold { return 1 }
        let t = min(1, (since - hold) / fade)
        let eased = t * t * (3 - 2 * t)
        return CGFloat(1 - eased)
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
    private func encoded(status: OSStatus, sample: CMSampleBuffer?, pts: Int64, submittedAt: CFTimeInterval, gen: Int,
                         requestedKey: Bool) {
        let now = CACurrentMediaTime()
        let parsed = status == noErr ? sample.flatMap { Self.annexB($0) } : nil
        if requestedKey, parsed?.1 != true {
            // A forced key frame that did not come out as one (dropped by
            // the real-time encoder): the segmenters would cut 2 s later.
            // The next frame is forced instead, and the log shows it.
            debugLog("[MV-CAST] composite key frame requested at pts \(pts) not produced (\(parsed == nil ? "frame dropped" : "not a key frame")); forcing the next frame")
            composeQueue.async { [weak self] in self?.forceKeyframe = true }
        }
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
        guard let (au, key) = parsed else { return }
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

    /// Audio queue. Frames of an older epoch than the mux's are dropped.
    private func enqueueAudio(_ frames: [(pts: Int64, adts: [UInt8])], tileID: String) {
        guard !frames.isEmpty else { return }
        if let from = focusLatencyFrom, let first = frames.first {
            focusLatencyFrom = nil
            let now = compositeNow()
            debugLog(String(format: "[MV-CAST] focus applied in %.0f ms (tile %@ audio on the stream from composite +%.0f ms; the receiver's own buffer adds its delay on top)",
                            (CACurrentMediaTime() - from) * 1000, tileID, Double(first.pts - now) / 90))
        }
        let epoch = audioEpoch
        muxQueue.async { [weak self] in
            guard let self, epoch >= self.muxEpoch else { return }
            self.pendingAudio += frames
            // Bound memory if the video stalls.
            if self.pendingAudio.count > 2000 { self.pendingAudio.removeFirst(self.pendingAudio.count - 2000) }
        }
    }

    // MARK: Audio (audio queue)

    /// A tile's ingest restarted on a new connection (round 7, device log
    /// 2026-10-07 15:52:00 to 15:53:58). ESPNU HD's player was torn down
    /// by its watchdog (15:52:00, 15:52:37) and re-mounted (15:53:31); each
    /// new connection started BEHIND the newest picture the decoder already
    /// held (Dispatcharr starts a new client back in its buffer; the
    /// earlier 15:51:08 retry took 19 s to pass the old point, "ingest
    /// back" at 15:51:27). The decoder drops anything not newer than its
    /// last access unit (within 60 s), the feed ran slower than real time,
    /// so it dropped every new byte: "decoded=0 held=1 buffered=1.6 s" from
    /// 15:52:20 until Switch Stream's -62 s jump reset it at 15:54:05. The
    /// tile was frozen on the TV and stayed frozen at 1 tile. A new
    /// connection now resets the tile's decoder and its audio demux, and
    /// the picture clock re-anchors on the new source.
    func tileSourceRestarted(tileID: String) {
        decoder(tileID)?.restartSource()
        audioQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.tileAudio[tileID] = nil
            self.fallbackLogged.remove(tileID)
        }
    }

    /// A tile's raw ingest bytes (its remuxer queue).
    func tileBytes(tileID: String, data: Data) {
        decoder(tileID)?.feed(data)
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

    /// Audio queue. New epoch: the mux forgets every queued frame.
    private func bumpAudioEpoch() {
        audioEpoch += 1
        let e = audioEpoch
        muxQueue.async { [weak self] in
            guard let self else { return }
            self.muxEpoch = e
            self.pendingAudio.removeAll()
        }
    }

    /// The tile player's position (main thread sample, 2 Hz). Maps it to
    /// the on-screen source PTS through the remuxer, re-anchors the audio
    /// when the focused tile resumes after a stall or drifts off the
    /// anchor (Logan 2026-10-07: audio drifted out of sync after tile
    /// stalls; the ingest kept arriving while the picture froze, and the
    /// fixed offset never noticed).
    func setPlayback(tileID: String, itemTime: Double, playing: Bool, resumed: Bool, remuxer: TSHLSRemuxer?) {
        let host = CACurrentMediaTime()
        audioQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            if let src = remuxer?.localSourcePTS(itemTime: itemTime) {
                let m = (Int64(src * 90_000) & TSLANAudioRewriter.pts33Mask, host, playing)
                self.measured[tileID] = m
                self.lock.lock(); self.measuredShared[tileID] = m; self.lock.unlock()
            } else {
                self.measured[tileID] = nil
                self.lock.lock(); self.measuredShared[tileID] = nil; self.lock.unlock()
            }
            // With the tile's decoder running, its picture clock is the
            // timing: the player's stalls and drift no longer apply.
            guard tileID == self.snapshot().focus, !self.tapLive(tileID),
                  self.decoder(tileID)?.isAnchored != true else { return }
            if resumed {
                self.anchorReason = "stall recovery"
                debugLog("[MV-CAST] composite audio: focused tile \(tileID) resumed after a stall; re-anchoring")
                self.reanchorFocused()
                return
            }
            guard playing, self.clock.offset != nil else { return }
            let (displayed, method) = self.displayedSource(tileID)
            if self.anchorGuessed, method != "guess" {
                self.anchorReason = "lag now known (\(method))"
                self.reanchorFocused()
                return
            }
            guard method == "measured",
                  let d = self.clock.drift(compositeNow: self.compositeNow(), displayedSourcePTS: displayed) else {
                self.driftStrikes = 0
                return
            }
            if abs(d) > Self.driftReanchorTicks {
                self.driftStrikes += 1
                if self.driftStrikes >= 2 {
                    self.anchorReason = String(format: "drift %+.2f s", Double(d) / 90_000)
                    self.reanchorFocused()
                }
            } else {
                self.driftStrikes = 0
            }
        }
    }

    /// Audio vs picture drift that re-anchors (two samples in a row).
    static let driftReanchorTicks: Int64 = 18_000   // 200 ms

    /// Audio queue. Drop the queued audio and anchor again on the focused
    /// tile's recent ingest (same tile, so the decoder stays).
    private func reanchorFocused() {
        driftStrikes = 0
        clock.reanchor()
        bumpAudioEpoch()
        let focus = snapshot().focus
        if let ring = tileAudio[focus]?.ring, !ring.isEmpty { process(ring, tileID: focus) }
    }

    private func refocusAudio() {
        lock.lock(); audioOffsetShared = nil; lock.unlock()
        clock.reanchor()
        bumpAudioEpoch()
        driftStrikes = 0
        normalizer = nil
        normalizerKey = ""
        let focus = snapshot().focus
        // Tap path: a flag flip, the new tile's PCM is already arriving.
        if tapLive(focus) { return }
        // Replay the focused tile's recent audio: what the tile shows now
        // lies inside it, the clock drops anything already covered.
        if let ring = tileAudio[focus]?.ring, !ring.isEmpty { process(ring, tileID: focus) }
    }

    /// The source PTS the focused tile is showing now: measured (the
    /// player's item time through its remuxer's segment map, advanced by
    /// the wall time since the sample) when fresh and sane, else the
    /// estimate (newest ingested audio minus the player's distance behind
    /// the live edge), else that estimate with a 6 s guess.
    private func displayedSource(_ id: String) -> (pts: Int64, method: String) {
        if let pts = decoder(id)?.displayedPTS(host: CACurrentMediaTime()) { return (pts, "picture clock") }
        let mask = TSLANAudioRewriter.pts33Mask
        let last = tileAudio[id]?.lastPTS ?? 0
        lock.lock()
        let lag = lagSeconds[id]
        lock.unlock()
        let estimate = (last - Int64((lag ?? 6) * 90_000)) & mask
        if let m = measured[id] {
            let age = CACurrentMediaTime() - m.host
            if age < 1.5 {
                let pts = (m.pts + (m.playing ? Int64(age * 90_000) : 0)) & mask
                // Sanity: within 10 s of the estimate (a wrong time base,
                // e.g. a reused remuxer, must not throw the audio off).
                var diff = (pts - estimate) & mask
                if diff > mask / 2 { diff -= mask + 1 }
                if lag == nil || abs(diff) < 10 * 90_000 { return (pts, "measured") }
                if measuredRejectedLogged.insert(id).inserted {
                    debugLog(String(format: "[MV-CAST] composite audio: measured position %.2f s off the estimate for tile %@; using the estimate", Double(diff) / 90_000, id))
                }
            }
        }
        return (estimate, lag == nil ? "guess" : "estimate")
    }

    private func displayedSourcePTS(_ id: String) -> Int64 { displayedSource(id).pts }

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
                var method = ""
                let mappedOpt = clock.map(sourcePTS: srcPTS & TSLANAudioRewriter.pts33Mask, compositeNow: now,
                                          displayedSourcePTS: {
                                              let d = self.displayedSource(tileID)
                                              method = d.method
                                              return d.pts
                                          },
                                          floor: audioFloor)
                // Logged even when this first frame lands below the floor
                // (a ring replay anchors on an already-covered frame).
                if !wasAnchored, let o = clock.offset {
                    lock.lock(); let lag = lagSeconds[tileID] ?? -1; lock.unlock()
                    anchorGuessed = method == "guess"
                    let src = srcPTS & TSLANAudioRewriter.pts33Mask
                    debugLog(String(format: "[MV-CAST] composite audio anchor tile=%@ codec=%@ reason=%@ position=%@ lag=%.2fs offset=%lld lead=%.2fs",
                                    tileID, codec.name, anchorReason, method, lag, o, Double(src + o - now) / 90_000))
                    anchorReason = "source jump"
                }
                if let o = clock.offset {
                    lock.lock()
                    if audioOffsetShared?.tileID != tileID || audioOffsetShared?.offset != o {
                        audioOffsetShared = (tileID, o)
                        avLoggedAt = 0
                    }
                    lock.unlock()
                }
                guard let mapped = mappedOpt else { continue }
                let key = "\(codec.name)-\(frame.sampleRate)-\(frame.channels)"
                if normalizer == nil || key != normalizerKey {
                    normalizer = MultiviewAudioNormalizer(codec: codec, sampleRate: frame.sampleRate,
                                                          channels: frame.channels, samplesPerFrame: frame.samples,
                                                          asc: frame.asc)
                    normalizerKey = key
                    lock.lock(); normalizerDelayShared = normalizer?.codecDelayTicks ?? 0; lock.unlock()
                    if let n = normalizer {
                        debugLog("[MV-CAST] composite audio: \(key) codec delay compensated (\(n.codecDelayDescription))")
                    } else {
                        debugLog("[MV-CAST] composite audio: no decoder for \(key); silence")
                    }
                }
                guard let normalizer else { continue }
                produced += normalizer.feed(frame.bytes, mappedPTS: mapped)
            }
        }
        enqueueAudio(produced, tileID: tileID)
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
    /// Codec delay the converters report (kAudioConverterPrimeInfo
    /// leadingFrames): the decoder's at the source rate plus the AAC
    /// encoder's priming at 48 kHz. Output packet k carries the input from
    /// k * 1024 - leading samples, so every output PTS is moved earlier by
    /// this (measured from the converters, not a constant).
    private(set) var codecDelayTicks: Int64 = 0
    private(set) var codecDelayDescription = ""

    private static func leadingFrames(_ c: AudioConverterRef?) -> Int {
        guard let c else { return 0 }
        var info = AudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        var size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        guard AudioConverterGetProperty(c, kAudioConverterPrimeInfo, &size, &info) == noErr else { return 0 }
        return Int(info.leadingFrames)
    }

    private func measureCodecDelay() {
        let dec = Self.leadingFrames(decoder)
        let enc = Self.leadingFrames(encoder)
        codecDelayTicks = Int64(dec) * 90_000 / Int64(max(1, sampleRate)) + Int64(enc) * 90_000 / Int64(Self.outputRate)
        codecDelayDescription = String(format: "decoder %d frames at %d Hz, encoder %d frames at %d Hz, %.1f ms",
                                       dec, sampleRate, enc, Self.outputRate, Double(codecDelayTicks) / 90)
    }

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
        measureCodecDelay()
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
        measureCodecDelay()
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
                    let pts = anchorPTS + outputPackets * 1024 * 90_000 / Int64(Self.outputRate) - codecDelayTicks
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
