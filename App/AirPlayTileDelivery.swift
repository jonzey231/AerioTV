#if os(iOS)
import AVFoundation
import Combine
import Foundation

// MARK: - AirPlay handoff for the AVPlayer tile (rebuilt 2026-09-24 from the 2026-09-21 log)

/// Moves ONE live tile between loopback delivery (the phone plays) and LAN
/// delivery (an AirPlay receiver plays), per plan sections 3-7.
///
/// In AirPlay video mode AVPlayer hands the item's URL to the receiver, so
/// the loopback URL the tile normally plays is unreachable from the TV.
/// While a receiver is served this swaps the item for the remuxer's LAN
/// URL: `/live.m3u8` untouched (passthrough, Apple receivers) or the
/// `airplay-aac` variant's `/aac/master.m3u8` (AAC-LC stereo, Roku), then
/// suspends the local-render watchdogs, holds the background keepalive and
/// disarms PiP auto-start. The reverse runs when the route goes away.
///
/// Owned by the tile (`@State`), one per tile; main actor only.
@MainActor
final class AirPlayTileDelivery {

    /// Audio the receiver gets (plan section 3).
    enum AudioPlan { case passthrough, aacStereo, passthroughDecoderUnavailable }

    /// True from the LAN swap until the swap back (or teardown). The
    /// progress driver's freeze / escalation checks and PiP read this.
    static let serving = CurrentValueSubject<Bool, Never>(false)
    static var isServingReceiver: Bool { serving.value }

    /// Readiness waits for the airplay-aac variant: mid-play the phone is
    /// still playing, so the swap gives up quickly (plan open question 2);
    /// at a fresh tune the variant has no buffered window to prime from.
    static let midPlayReadyTimeout: TimeInterval = 6
    static let startReadyTimeout: TimeInterval = 30
    /// Mid-play: how long the swapped LAN item has to go external before
    /// the handoff is declared failed.
    static let externalConfirmTimeout: TimeInterval = 5

    private enum State { case idle, preparing, serving }
    private var state: State = .idle
    private var token = UUID()

    private weak var remuxer: TSHLSRemuxer?
    private weak var player: AVPlayer?
    private var channelName = ""
    private var loopbackURL: URL?
    private var plan: AudioPlan = .passthrough
    private var lanEndpoint: (ip: String, port: UInt16)?
    private var keepaliveHeld = false
    private var externalObservation: NSKeyValueObservation?
    private var lanItemStatusObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    /// The tile's own view of `isExternalPlaybackActive` (for its lines).
    private var tileExternal = false

    static let keepaliveHolder = "airplay-video"

    /// Tile hook: suspend (true) or re-arm (false) the stall watchdog; the
    /// item is the one now current (re-arm rebinds the watchdog to it).
    var onWatchdogs: ((_ suspend: Bool, _ item: AVPlayerItem?) -> Void)?

    var isServing: Bool { state == .serving }
    /// The receiver gets transcoded audio (background-entry line).
    var servesAAC: Bool { state == .serving && plan == .aacStereo }

    // MARK: Route

    static func routeHasAirPlay() -> Bool {
        AirPlayReceiverResolver.currentAirPlayOutput() != nil
    }

    // MARK: Start path ("AirPlay route already selected")

    /// Called when the remuxer declares READY. With an AirPlay output
    /// already on the route, resolves the receiver, plans the audio, and
    /// calls `start` with the LAN URL (or the loopback one when LAN
    /// delivery cannot run). Returns false when AirPlay is not involved;
    /// the caller then starts on loopback as always.
    func prepareStart(remuxer: TSHLSRemuxer, loopbackURL: URL, channelName: String,
                      start: @escaping (_ url: URL, _ lanAAC: Bool) -> Void) -> Bool {
        reset(logEnd: false)
        self.remuxer = remuxer
        self.loopbackURL = loopbackURL
        self.channelName = channelName
        observeRoute()
        guard Self.routeHasAirPlay() else {
            AirPlayMonitor.shared.headlessTuneFellBack(reason: "no AirPlay route at READY")
            return false
        }
        debugLog("[AVP-AIRPLAY] item audio codec=\(remuxer.sourceAudioCodec) channel=\(channelName)")
        if remuxer.inProcessDelivery {
            debugLog("[AVP-AIRPLAY] LAN delivery unavailable; leaving the loopback item in place")
            AirPlayMonitor.shared.headlessTuneFellBack(reason: "in-process delivery")
            return false
        }
        state = .preparing
        let myToken = UUID()
        token = myToken
        AirPlayMonitor.shared.noteTileLoading(true)
        Task { @MainActor in
            let result = await self.prepareLAN(remuxer: remuxer, readyTimeout: Self.startReadyTimeout,
                                               token: myToken)
            guard self.token == myToken else { return }
            switch result {
            case .ready(let url):
                debugLog("[AVP-AIRPLAY] AirPlay route already selected: starting on LAN \(self.endpointText), watchdogs suspended")
                self.enterServing()
                start(url, self.plan == .aacStereo)
            case .noAddress:
                debugLog("[AVP-AIRPLAY] no LAN address for the remux server; starting on loopback")
                self.state = .idle
                AirPlayMonitor.shared.headlessTuneFellBack(reason: "no LAN address")
                start(loopbackURL, false)
            case .unavailable:
                debugLog("[AVP-AIRPLAY] LAN delivery unavailable; leaving the loopback item in place")
                self.state = .idle
                AirPlayMonitor.shared.headlessTuneFellBack(reason: "LAN delivery unavailable")
                start(loopbackURL, false)
            case .audioOnlyReceiver:
                self.state = .idle
                AirPlayMonitor.shared.headlessTuneFellBack(reason: "audio-only receiver")
                start(loopbackURL, false)
            }
            AirPlayMonitor.shared.noteTileLoading(false)
        }
        return true
    }

    // MARK: Player attachment (every start)

    /// The tile's AVPlayer for this tune. Observes `isExternalPlaybackActive`
    /// for the tile's own lines and for the mid-play handoff.
    func attach(player: AVPlayer, remuxer: TSHLSRemuxer?, loopbackURL: URL?, channelName: String) {
        self.player = player
        if let remuxer { self.remuxer = remuxer }
        if let loopbackURL { self.loopbackURL = loopbackURL }
        self.channelName = channelName
        observeRoute()
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor in self?.externalChanged(active) }
        }
    }

    private func externalChanged(_ active: Bool) {
        guard active != tileExternal else { return }
        tileExternal = active
        if active {
            debugLog("[AVP-AIRPLAY] tile \(channelName): external playback active, local-render watchdogs suspended")
            onWatchdogs?(true, nil)
            // The receiver took the loopback item (route picked mid-play):
            // hand it the LAN URL.
            if state == .idle { beginMidPlay() }
        } else {
            debugLog("[AVP-AIRPLAY] tile \(channelName): external playback ended, watchdogs re-armed")
            if state != .serving { onWatchdogs?(false, player?.currentItem) }
        }
    }

    private func observeRoute() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        }
    }

    private func routeChanged() {
        let hasAirPlay = Self.routeHasAirPlay()
        // Mid-play start: the route gained an AirPlay output while this
        // tile plays on loopback (the 09-21 log serves on the LAN before
        // the receiver reports external playback). An audio-only speaker
        // is skipped once the receiver resolves. Route LOSS ends the
        // whole session (device test 2026-09-25: no fall-back to the phone).
        if hasAirPlay, state == .idle, player != nil, remuxer != nil {
            beginMidPlay()
        } else if !hasAirPlay, state != .idle {
            end(reason: "route")
        }
    }

    // MARK: Mid-play handoff

    private func beginMidPlay() {
        guard state == .idle, let remuxer, let player, player.currentItem != nil,
              Self.routeHasAirPlay() else { return }
        debugLog("[AVP-AIRPLAY] item audio codec=\(remuxer.sourceAudioCodec) channel=\(channelName)")
        if remuxer.inProcessDelivery {
            debugLog("[AVP-AIRPLAY] LAN delivery unavailable; leaving the loopback item in place")
            return
        }
        // The player must be allowed to go external or the receiver only
        // gets the system audio route (device log 2026-09-25 12:38:47).
        AirPlayMonitor.shared.reenableExternalPlaybackForRoute()
        AirPlayMonitor.enableExternalPlayback(on: player)
        state = .preparing
        let myToken = UUID()
        token = myToken
        Task { @MainActor in
            let result = await self.prepareLAN(remuxer: remuxer, readyTimeout: Self.midPlayReadyTimeout,
                                               token: myToken)
            guard self.token == myToken else { return }
            switch result {
            case .ready(let url):
                guard let player = self.player, let old = player.currentItem else {
                    self.teardownLAN(); self.state = .idle; return
                }
                let item = self.makeLANItem(url: url, copying: old)
                player.replaceCurrentItem(with: item)
                self.observeLANItem(item)
                // Truthful handoff line (device log 2026-09-25 12:38:47:
                // "serving on LAN" was logged but the receiver never
                // fetched): claim serving only once AVPlayer is external.
                self.onWatchdogs?(true, nil)
                let deadline = Date().addingTimeInterval(Self.externalConfirmTimeout)
                while !player.isExternalPlaybackActive, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard self.token == myToken else { return }
                }
                guard player.isExternalPlaybackActive else {
                    debugLog("[AVP-AIRPLAY] receiver did not take the LAN item (external playback never became active within \(Int(Self.externalConfirmTimeout))s, allowsExternalPlayback=\(player.allowsExternalPlayback)); back to loopback, playing on this device")
                    self.lanItemStatusObservation = nil
                    if let loopbackURL = self.loopbackURL {
                        let back = AVPlayerItem(url: loopbackURL)
                        back.automaticallyPreservesTimeOffsetFromLive = true
                        player.replaceCurrentItem(with: back)
                        self.onWatchdogs?(false, back)
                    } else {
                        self.onWatchdogs?(false, player.currentItem)
                    }
                    self.teardownLAN()
                    self.state = .idle
                    return
                }
                debugLog("[AVP-AIRPLAY] external playback active: serving on LAN \(self.endpointText), watchdogs suspended")
                self.enterServing()
            case .noAddress:
                debugLog("[AVP-AIRPLAY] no LAN address for the remux server; starting on loopback")
                self.state = .idle
            case .unavailable:
                debugLog("[AVP-AIRPLAY] LAN delivery unavailable; leaving the loopback item in place")
                self.state = .idle
            case .audioOnlyReceiver:
                self.state = .idle
            }
        }
    }

    /// Mid-play LAN item: the same forward-buffer policy as the loopback
    /// item (automatic). An AAC item takes its join point from the variant
    /// playlist's HOLD-BACK (plan section 5); a passthrough item keeps the
    /// loopback item's configured offset.
    private func makeLANItem(url: URL, copying old: AVPlayerItem) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.preferredForwardBufferDuration = old.preferredForwardBufferDuration
        if plan == .aacStereo {
            debugLog("[AVP-AIRPLAY] join offset left to the variant playlist's HOLD-BACK (primary offset not applied) channel=\(channelName)")
        } else {
            item.configuredTimeOffsetFromLive = old.configuredTimeOffsetFromLive
        }
        return item
    }

    /// Called by the tile after `startPlayer` built a LAN item on the start
    /// path, so a failed item falls back like a mid-play one.
    func noteStartItem(_ item: AVPlayerItem) {
        guard state == .serving else { return }
        observeLANItem(item)
    }

    private func observeLANItem(_ item: AVPlayerItem) {
        lanItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? "unknown"
            Task { @MainActor in
                debugLog("[AVP-AIRPLAY] LAN item failed (\(reason))")
                self?.end(reason: "item failed")
            }
        }
    }

    // MARK: Shared steps

    private enum LANResult { case ready(URL), noAddress, unavailable, audioOnlyReceiver }

    /// Plan section 3 then section 4: receiver, audio plan, variant
    /// readiness (AAC), LAN listener.
    private func prepareLAN(remuxer: TSHLSRemuxer, readyTimeout: TimeInterval, token myToken: UUID) async -> LANResult {
        let mode = AirPlayAudioMode.current
        let receiver = await AirPlayReceiverResolver.shared.resolveForHandoff()
        guard token == myToken else { return .unavailable }
        debugLog(receiver.logLine(mode: mode))
        // A HomePod / AirPort route plays the phone's audio; there is no
        // screen to hand the video to.
        if receiver.isAudioOnly { return .audioOnlyReceiver }
        let codec = remuxer.sourceAudioCodec
        let transcodable = codec == "AC-3" || codec == "E-AC-3"
        plan = (receiver.wantsAAC(mode: mode) && transcodable) ? .aacStereo : .passthrough
        var path = "/live.m3u8"
        if plan == .aacStereo {
            let variant: AirPlayAACVariant? = await withCheckedContinuation { cont in
                remuxer.startAACVariant { cont.resume(returning: $0) }
            }
            guard token == myToken else { return .unavailable }
            if let variant {
                let deadline = Date().addingTimeInterval(readyTimeout)
                while !variant.isReady, !variant.hasFailed, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard token == myToken else { return .unavailable }
                }
                guard variant.isReady else {
                    // Plan open question 2: no swap without a ready variant.
                    remuxer.stopAACVariant()
                    plan = .passthrough
                    return .unavailable
                }
                debugLog("[AVP-AIRPLAY] audio: source \(variant.sourceAudioLabel) -> AAC stereo for AirPlay")
                debugLog("[AVP-AIRPLAY] \(variant.statusLine("variant ready"))")
                path = "/aac/master.m3u8"
            } else {
                debugLog("[AVP-AIRPLAY] audio: passthrough (decoder unavailable)")
                plan = .passthroughDecoderUnavailable
            }
        }
        let lan: TSHLSRemuxer.LANDeliveryResult = await withCheckedContinuation { cont in
            remuxer.startLANDelivery { cont.resume(returning: $0) }
        }
        guard token == myToken else { return .unavailable }
        switch lan {
        case .ready(let ip, let port):
            lanEndpoint = (ip, port)
            guard let url = URL(string: "http://\(ip):\(port)\(path)") else { return .unavailable }
            if let variant = remuxer.currentAirPlayVariant, plan == .aacStereo {
                variant.startServingLog { line in debugLog("[AVP-AIRPLAY] \(line)") }
            }
            return .ready(url)
        case .noAddress:
            remuxer.stopAACVariant()
            return .noAddress
        case .unavailable:
            remuxer.stopAACVariant()
            remuxer.stopLANDelivery()
            return .unavailable
        }
    }

    private var endpointText: String {
        guard let e = lanEndpoint else { return "?" }
        return "\(e.ip):\(e.port)"
    }

    /// Watchdogs, keepalive, PiP (sections 6 and 7).
    private func enterServing() {
        state = .serving
        onWatchdogs?(true, nil)
        if !keepaliveHeld {
            keepaliveHeld = true
            debugLog("[AVP-AIRPLAY] background keepalive on")
            BackgroundKeepalive.acquire(Self.keepaliveHolder)
        }
        Self.serving.send(true)
        RemoteSessionNowPlaying.publishAirPlay()
    }

    /// End of LAN delivery. A LAN item failure goes back to loopback (plan
    /// section 4c "End"). A route loss is the receiver ending AirPlay and
    /// stops playback outright (device test 2026-09-25: the phone must not
    /// pick the channel back up): LAN delivery, the variant and the
    /// keepalive go now, then the monitor runs the same stop as the card's X.
    func end(reason: String) {
        guard state != .idle else { return }
        token = UUID()
        let wasServing = state == .serving
        state = .idle
        if reason == "route" {
            lanItemStatusObservation = nil
            teardownLAN()
            leaveServing()
            if wasServing {
                player?.pause()
                debugLog("[AVP-AIRPLAY] external playback ended (route lost): LAN delivery torn down, playback stopped")
                AirPlayMonitor.shared.receiverEnded(routeLost: true, servedByTile: true)
            }
            return
        }
        if wasServing, let player, let loopbackURL {
            let item = AVPlayerItem(url: loopbackURL)
            item.automaticallyPreservesTimeOffsetFromLive = true
            player.replaceCurrentItem(with: item)
            lanItemStatusObservation = nil
            teardownLAN()
            debugLog("[AVP-AIRPLAY] external playback ended: back to loopback delivery, watchdogs re-armed")
            onWatchdogs?(false, item)
        } else {
            teardownLAN()
        }
        leaveServing()
    }

    private func teardownLAN() {
        remuxer?.stopAACVariant()
        remuxer?.stopLANDelivery()
        lanEndpoint = nil
    }

    private func leaveServing() {
        if keepaliveHeld {
            keepaliveHeld = false
            debugLog("[AVP-AIRPLAY] background keepalive off")
            BackgroundKeepalive.release(Self.keepaliveHolder)
        }
        if Self.serving.value {
            Self.serving.send(false)
            RemoteSessionNowPlaying.clear()
        }
    }

    /// Tile teardown: the player and remuxer are going away with it, so no
    /// item swap; just drop what this session holds.
    func reset(logEnd: Bool = true) {
        token = UUID()
        if state != .idle, logEnd {
            debugLog("[AVP-AIRPLAY] tile \(channelName): AirPlay delivery released with the pipeline")
        }
        if state != .idle { teardownLAN() }
        state = .idle
        externalObservation = nil
        lanItemStatusObservation = nil
        tileExternal = false
        player = nil
        leaveServing()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    /// Plan section 6: the background-entry lines. Returns true when the
    /// tile must NOT quiesce (a receiver is being served from this phone).
    func handleBackgroundEntry() -> Bool {
        guard state == .serving else { return false }
        let holders = BackgroundKeepalive.currentHolders.joined(separator: ",")
        var running = "AVPlayer external playback, TSHLSRemuxer ingest URLSession, remuxer NWListener (loopback + LAN delivery)"
        if plan == .aacStereo { running += ", AAC transcode for the receiver" }
        debugLog("[AVP-AIRPLAY] background entry: keepalive=\(keepaliveHeld ? "on" : "off") holders=\(holders); still running: \(running); tile background quiesce suppressed for this session")
        debugLog("[AVP-AIRPLAY] background: pipeline NOT quiesced, the receiver is being served from this phone channel=\(channelName)")
        return true
    }
}
#endif
