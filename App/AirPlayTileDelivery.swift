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
/// URL, `/live.m3u8`, whatever the receiver (2026-09-26: a Roku plays the
/// muxed TS playlist but rejects any demuxed fMP4 master). Only the audio
/// inside the LAN TS segments depends on the receiver: the source audio
/// (passthrough, Apple receivers) or AAC-LC stereo muxed into the same
/// segments by the remuxer (Roku). Then it suspends the local-render watchdogs, holds the background keepalive and
/// disarms PiP auto-start.
///
/// The one owner of the session: the player's `isExternalPlaybackActive`
/// is the only signal that the receiver has the stream. The audio route
/// only starts things (an AirPlay output selected at tune time, or one
/// appearing during loopback playback); route loss on its own never ends
/// a session. The session ends when external playback stays off for
/// `receiverReleaseGrace` with the receiver silent on the LAN listener (or
/// for `receiverReleaseHardCap` regardless), when the user stops it, or when the parked
/// watchdog fires.
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

    /// Handover waits for published LAN segments: mid-play the phone is
    /// still playing, so the swap gives up quickly; a fresh tune has no
    /// buffered window yet.
    static let midPlayReadyTimeout: TimeInterval = 6
    static let startReadyTimeout: TimeInterval = 30
    /// Mid-play: how long the swapped LAN item has to go external before
    /// the handoff is declared failed.
    static let externalConfirmTimeout: TimeInterval = 5
    /// External playback off while serving ends the session once the
    /// receiver has also been silent on the LAN listener (no playlist or
    /// segment request) for this long. Device log 2026-09-25 17:04: a
    /// rebuffering receiver drops external playback for an unknown time
    /// while it keeps fetching, so its requests are the evidence.
    static let receiverReleaseGrace: TimeInterval = 10
    /// External playback off this long ends the session even while the
    /// receiver keeps fetching.
    static let receiverReleaseHardCap: TimeInterval = 60
    /// Published LAN segments the receiver's first playlist must carry:
    /// 5 segments (2.5 to 3.8 s each), so the default start point (3 x the
    /// LAN target of 4 s = 12 s behind the published end) exists.
    static let handoverPublishedSegments = 5
    /// The handover gave the player the LAN URL; the receiver must take it
    /// (external playback active) within this long or the session stops.
    static let receiverTakeTimeout: TimeInterval = 15
    /// Players attached to a tile delivery; AirPlayMonitor leaves their
    /// session end to the delivery.
    private static let tilePlayers = NSHashTable<AVPlayer>.weakObjects()
    static func isTilePlayer(_ player: AVPlayer) -> Bool { tilePlayers.contains(player) }

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
    private var releaseGraceTask: Task<Void, Never>?
    private var releasedAt: Date?

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
                      start: @escaping (_ url: URL) -> Void) -> Bool {
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
                start(url)
                self.holdLocalOutputForTake(url: url)
                self.watchReceiverTake(token: myToken)
            case .noAddress:
                debugLog("[AVP-AIRPLAY] no LAN address for the remux server; starting on loopback")
                self.state = .idle
                AirPlayMonitor.shared.headlessTuneFellBack(reason: "no LAN address")
                start(loopbackURL)
            case .unavailable:
                debugLog("[AVP-AIRPLAY] LAN delivery unavailable; leaving the loopback item in place")
                self.state = .idle
                AirPlayMonitor.shared.headlessTuneFellBack(reason: "LAN delivery unavailable")
                start(loopbackURL)
            case .audioOnlyReceiver:
                self.state = .idle
                AirPlayMonitor.shared.headlessTuneFellBack(reason: "audio-only receiver")
                start(loopbackURL)
            }
            AirPlayMonitor.shared.noteTileLoading(false)
        }
        return true
    }

    /// The fresh-tune player was muted until the receiver takes the LAN
    /// item (`holdLocalOutputForTake`).
    private var mutedForTake = false

    /// Fresh tune: `play()` on the LAN item renders on this device until
    /// AVPlayer goes external (the fullscreen player is hidden by the
    /// headless tune, but the audio still plays through the current route).
    /// Mute it until `isExternalPlaybackActive` turns true so the phone
    /// never plays on its own while the receiver has not taken the item
    /// (device log 2026-09-26 11:08). Not paused: the receiver takes a
    /// playing item, and the card reads the player's rate.
    private func holdLocalOutputForTake(url: URL) {
        guard let player, state == .serving, !player.isExternalPlaybackActive,
              (player.currentItem?.asset as? AVURLAsset)?.url == url else { return }
        mutedForTake = true
        player.isMuted = true
        debugLog("[AVP-AIRPLAY] tile \(channelName): local output muted until the receiver takes the LAN item")
    }

    private func releaseTakeMute() {
        guard mutedForTake else { return }
        mutedForTake = false
        player?.isMuted = false
        debugLog("[AVP-AIRPLAY] tile \(channelName): receiver took the LAN item, player unmuted")
    }

    /// Fresh-tune handover: the player has the LAN URL; stop the session
    /// if the receiver never takes it (external playback never active).
    private func watchReceiverTake(token myToken: UUID) {
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.receiverTakeTimeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.token == myToken, self.state == .serving else { return }
                if self.player?.isExternalPlaybackActive == true { return }
            }
            guard let self, self.token == myToken, self.state == .serving,
                  self.player?.isExternalPlaybackActive != true else { return }
            debugLog("[AVP-AIRPLAY] receiver never took the LAN item within \(Int(Self.receiverTakeTimeout)) s; stopping")
            self.endReceiverSession("receiver never took the LAN item")
        }
    }

    // MARK: Player attachment (every start)

    /// The tile's AVPlayer for this tune. Observes `isExternalPlaybackActive`
    /// for the tile's own lines and for the mid-play handoff.
    func attach(player: AVPlayer, remuxer: TSHLSRemuxer?, loopbackURL: URL?, channelName: String) {
        self.player = player
        Self.tilePlayers.add(player)
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
            if let since = releasedAt {
                debugLog(String(format: "[AVP-AIRPLAY] tile %@: external playback back after %.1f s; session kept",
                                channelName, Date().timeIntervalSince(since)))
            }
            cancelReleaseGrace()
            releaseTakeMute()
            debugLog("[AVP-AIRPLAY] tile \(channelName): external playback active, local-render watchdogs suspended")
            onWatchdogs?(true, nil)
            // The receiver took the loopback item (route picked mid-play):
            // hand it the LAN URL.
            if state == .idle { beginMidPlay() }
        } else if state == .serving {
            debugLog("[AVP-AIRPLAY] tile \(channelName): external playback off (player \(AirPlayMonitor.playerStatusText(player))); ending the session after \(Int(Self.receiverReleaseGrace)) s of receiver silence or \(Int(Self.receiverReleaseHardCap)) s off")
            startReleaseGrace()
        } else if state == .preparing {
            debugLog("[AVP-AIRPLAY] tile \(channelName): external playback off while the LAN handover is prepared")
        } else {
            debugLog("[AVP-AIRPLAY] tile \(channelName): external playback ended, watchdogs re-armed")
            onWatchdogs?(false, player?.currentItem)
        }
    }

    private func startReleaseGrace() {
        releaseGraceTask?.cancel()
        releasedAt = Date()
        let myToken = token
        let offSince = Date()
        // Only peers other than the phone count: after the receiver drops
        // external playback the phone's own player fetches from the LAN
        // listener (device log 2026-09-26 09:49), which kept the silence
        // rule from ever firing.
        func requests(_ r: TSHLSRemuxer?) -> Int {
            guard let st = r?.lanLinkStats else { return 0 }
            return TSHLSRemuxer.remotePeerRequests(st)
        }
        var lastRequests = requests(remuxer)
        var silentSince = offSince
        var fetchLogged = false
        releaseGraceTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.token == myToken, self.state == .serving,
                      self.player?.isExternalPlaybackActive != true else { return }
                let now = Date()
                let total = requests(self.remuxer)
                if total != lastRequests {
                    lastRequests = total
                    silentSince = now
                    if !fetchLogged {
                        fetchLogged = true
                        debugLog("[AVP-AIRPLAY] tile \(self.channelName): external playback off but the receiver is still fetching; holding")
                    }
                }
                let off = now.timeIntervalSince(offSince)
                let silent = now.timeIntervalSince(silentSince)
                if silent >= Self.receiverReleaseGrace {
                    self.endReceiverSession(String(format: "external playback off %.1f s and the receiver silent on the LAN for %.0f s (silence grace): the receiver ended AirPlay",
                                                   off, silent))
                    return
                }
                if off >= Self.receiverReleaseHardCap {
                    self.endReceiverSession(String(format: "external playback off %.0f s (hard cap) while the receiver still fetched: ending the session", off))
                    return
                }
            }
        }
    }

    private func cancelReleaseGrace() {
        releaseGraceTask?.cancel()
        releaseGraceTask = nil
        releasedAt = nil
    }

    private func observeRoute() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            MainActor.assumeIsolated { self?.routeChanged(reasonRaw: reason) }
        }
    }

    /// One diagnostic line per route change. The route only starts a
    /// mid-play handover (an AirPlay output appeared while this tile plays
    /// on loopback; an audio-only speaker is skipped once the receiver
    /// resolves); it never ends a session.
    private func routeChanged(reasonRaw: UInt) {
        let hasAirPlay = Self.routeHasAirPlay()
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        let external = player?.isExternalPlaybackActive
        debugLog("[AVP-AIRPLAY] route change: reason=\(Self.routeChangeReasonText(reasonRaw)) outputs=[\(outputs)] airplay=\(hasAirPlay) externalActive=\(external.map { String($0) } ?? "nil") state=\(state)")
        if hasAirPlay, state == .idle, player != nil, remuxer != nil {
            beginMidPlay()
        }
    }

    static func routeChangeReasonText(_ raw: UInt) -> String {
        guard let r = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "raw\(raw)" }
        switch r {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "raw\(raw)"
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
    /// item (automatic). No configured join offset: the receiver starts at
    /// the playlist's default point and the LAN publication delay keeps
    /// that point inside the window.
    private func makeLANItem(url: URL, copying old: AVPlayerItem) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.preferredForwardBufferDuration = old.preferredForwardBufferDuration
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
            let detail = TSHLSRemuxer.itemFailureDetail(item)
            let rejection = Self.receiverRejection(item.error)
            Task { @MainActor in
                debugLog("[AVP-AIRPLAY] LAN item failure detail: \(detail)")
                self?.lanItemFailed(item, reason: reason, receiverRejection: rejection)
            }
        }
    }

    /// One reload of a failed LAN item per serving session (device log
    /// 2026-09-25 17:04: a receiver-side hiccup must not end the session).
    private var lanReloadUsed = false

    /// AVError -11870 (externalPlaybackNotSupportedForAsset): the receiver
    /// refused the asset. Returns the underlying receiver code text ("-60034"
    /// in device log 2026-09-26 11:08), or nil for any other failure.
    nonisolated static func receiverRejection(_ error: Error?) -> String? {
        guard let e = error as NSError?, e.domain == AVFoundationErrorDomain,
              e.code == AVError.Code.externalPlaybackNotSupportedForAsset.rawValue else { return nil }
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(u.domain) \(u.code)"
        }
        return "none"
    }

    private func lanItemFailed(_ item: AVPlayerItem, reason: String, receiverRejection: String? = nil) {
        guard let player, player.currentItem === item else { return }
        // The receiver rejected the asset: a reload on the same URL gets the
        // same answer while the phone plays headless (device log 2026-09-26
        // 11:08). Stop now; the phone never carries on alone.
        if state == .serving, let code = receiverRejection {
            endReceiverSession("receiver rejected the asset (AVError -11870, receiver code \(code)): \(reason)")
            return
        }
        if state == .serving, !lanReloadUsed,
           let url = (item.asset as? AVURLAsset)?.url {
            lanReloadUsed = true
            remuxer?.resetLANReceiverTimeBase()
            debugLog("[AVP-AIRPLAY] LAN item failed (\(reason)): reloading once on the same LAN URL \(url.absoluteString)")
            let fresh = makeLANItem(url: url, copying: item)
            player.replaceCurrentItem(with: fresh)
            observeLANItem(fresh)
            player.play()
            return
        }
        if state == .serving {
            endReceiverSession("LAN item failed again after the reload (\(reason)); giving up")
            return
        }
        debugLog("[AVP-AIRPLAY] LAN item failed (\(reason))")
        end(reason: "item failed")
    }

    // MARK: Shared steps

    private enum LANResult { case ready(URL), noAddress, unavailable, audioOnlyReceiver }

    /// Plan section 3 then section 4: receiver, audio plan, LAN listener,
    /// then the published-segment handover wait. One path for every plan:
    /// the receiver always gets `/live.m3u8`; `aacStereo` only turns on the
    /// remuxer's LAN audio rewrite.
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
        let aac = await setLANAudio(remuxer: remuxer, aac: plan == .aacStereo)
        guard token == myToken else { return .unavailable }
        if plan == .aacStereo, !aac {
            debugLog("[AVP-AIRPLAY] audio: passthrough (decoder unavailable)")
            plan = .passthroughDecoderUnavailable
        }
        let lan: TSHLSRemuxer.LANDeliveryResult = await withCheckedContinuation { cont in
            remuxer.startLANDelivery { cont.resume(returning: $0) }
        }
        guard token == myToken else { return .unavailable }
        switch lan {
        case .ready(let ip, let port):
            lanEndpoint = (ip, port)
            await waitForPublishedSegments(remuxer: remuxer, timeout: readyTimeout, token: myToken)
            guard token == myToken else { return .unavailable }
            guard let url = URL(string: "http://\(ip):\(port)/live.m3u8") else { return .unavailable }
            return .ready(url)
        case .noAddress:
            return .noAddress
        case .unavailable:
            remuxer.stopLANDelivery()
            return .unavailable
        }
    }

    private func setLANAudio(remuxer: TSHLSRemuxer, aac: Bool) async -> Bool {
        await withCheckedContinuation { cont in
            remuxer.setLANAudioAAC(aac) { cont.resume(returning: $0) }
        }
    }

    /// Handover wait: the receiver's first LAN playlist must list at least
    /// `handoverPublishedSegments` segments that passed the publication
    /// delay, so its default start point (3 x TARGETDURATION from the end)
    /// lands inside the list. On timeout the handover proceeds anyway.
    private func waitForPublishedSegments(remuxer: TSHLSRemuxer, timeout: TimeInterval, token myToken: UUID) async {
        let need = Self.handoverPublishedSegments
        var st = remuxer.lanPublishedState()
        guard st.segments < need else { return }
        let began = Date()
        debugLog(String(format: "[AVP-AIRPLAY] handover: waiting for %d published segments (have %d, delay %.1f s)",
                        need, st.segments, st.delay))
        let deadline = began.addingTimeInterval(timeout)
        while st.segments < need, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard token == myToken else { return }
            st = remuxer.lanPublishedState()
        }
        let waited = Date().timeIntervalSince(began)
        if st.segments >= need {
            debugLog(String(format: "[AVP-AIRPLAY] handover after %.1f s", waited))
        } else {
            debugLog(String(format: "[AVP-AIRPLAY] handover wait timed out after %.1f s (%d of %d published segments); starting anyway",
                            waited, st.segments, need))
        }
    }

    private var endpointText: String {
        guard let e = lanEndpoint else { return "?" }
        return "\(e.ip):\(e.port)"
    }

    // MARK: Late receiver resolution (device log 2026-09-25)

    /// The tile currently serving a receiver (one at a time).
    private static weak var servingTile: AirPlayTileDelivery?
    private var replanning = false

    /// The resolver named the receiver after the plan was decided. An
    /// unresolved receiver starts on passthrough (automatic mode); if it
    /// turns out to be non-Apple, turn on the LAN audio rewrite and hand
    /// the receiver a fresh item on the same `/live.m3u8`.
    static func receiverResolved(_ r: AirPlayReceiver) {
        servingTile?.replanIfNeeded(for: r)
    }

    private func replanIfNeeded(for r: AirPlayReceiver) {
        guard state == .serving, plan == .passthrough, !replanning,
              AirPlayAudioMode.current == .automatic,
              r.model != nil, !r.isApple, !r.isAudioOnly,
              let remuxer, let player, let old = player.currentItem, lanEndpoint != nil else { return }
        let codec = remuxer.sourceAudioCodec
        guard codec == "AC-3" || codec == "E-AC-3" else { return }
        debugLog("[AVP-AIRPLAY] receiver resolved to non-Apple '\(r.name)' model=\(r.model ?? "?") while serving passthrough: switching LAN audio to AAC-LC stereo (item swap)")
        replanning = true
        let myToken = token
        Task { @MainActor in
            defer { self.replanning = false }
            let aac = await self.setLANAudio(remuxer: remuxer, aac: true)
            guard self.token == myToken, self.state == .serving, let player = self.player else { return }
            guard aac, let url = (old.asset as? AVURLAsset)?.url else {
                debugLog("[AVP-AIRPLAY] re-plan: LAN audio rewrite unavailable; staying on passthrough")
                return
            }
            self.plan = .aacStereo
            remuxer.resetLANReceiverTimeBase()
            let item = self.makeLANItem(url: url, copying: player.currentItem ?? old)
            player.replaceCurrentItem(with: item)
            self.observeLANItem(item)
            debugLog("[AVP-AIRPLAY] re-plan: receiver now gets AAC-LC stereo in the LAN TS \(self.endpointText)")
        }
    }

    /// Watchdogs, keepalive, PiP (sections 6 and 7).
    private func enterServing() {
        state = .serving
        lanReloadUsed = false
        cancelReleaseGrace()
        Self.servingTile = self
        onWatchdogs?(true, nil)
        if !keepaliveHeld {
            keepaliveHeld = true
            if let pending = Self.flipKeepaliveRelease {
                // The previous tile's keepalive, held across the flip:
                // take it over instead of releasing and re-acquiring.
                pending.cancel()
                Self.flipKeepaliveRelease = nil
                debugLog("[AVP-AIRPLAY] background keepalive carried across the channel flip")
            } else {
                debugLog("[AVP-AIRPLAY] background keepalive on")
                BackgroundKeepalive.acquire(Self.keepaliveHolder)
            }
        }
        Self.serving.send(true)
        RemoteSessionNowPlaying.publishAirPlay()
        startLinkLog()
    }

    // MARK: Link line (device log 2026-09-25 17:04)

    private var linkTask: Task<Void, Never>?
    private var linkIngestKbps: [Double] = []
    private var linkLastIngest: Int64?
    private var linkLastServed: Int64 = 0
    private var linkLastStarved = 0
    private var linkTicks = 0

    /// Parked-receiver watchdog: the receiver fetched a playlist but no
    /// media segment for `parkTimeout`.
    static let parkTimeout: TimeInterval = 20
    private var parkLastSegments = 0
    private var parkBaselinePlaylists = 0
    private var parkLastSegmentAt = Date()

    /// One `[AVP-AIRPLAY] link:` line every 10 s while serving, from 1 s
    /// ingest samples (so the min shows a burst gap the average hides).
    private func startLinkLog() {
        guard linkTask == nil else { return }
        NetworkPathLog.shared.start()
        linkIngestKbps = []
        linkLastIngest = nil
        linkTicks = 0
        let st = remuxer?.lanLinkStats
        linkLastServed = st?.servedBytes ?? 0
        linkLastStarved = st?.starvedClosures ?? 0
        parkLastSegments = st?.servedSegmentRequests ?? 0
        parkBaselinePlaylists = st?.servedPlaylistRequests ?? 0
        parkLastSegmentAt = Date()
        linkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.linkTick()
            }
        }
    }

    /// True when the session was stopped.
    private func checkParked(_ st: TSHLSRemuxer.LANLinkStats) -> Bool {
        // Upstream stall: nothing cut and unfetched, so the receiver has
        // nothing to ask for. The clock only runs while segments wait.
        if st.servedSegmentRequests != parkLastSegments || st.reservoirSegments == 0 {
            parkLastSegments = st.servedSegmentRequests
            parkLastSegmentAt = Date()
            return false
        }
        guard st.servedPlaylistRequests > parkBaselinePlaylists,
              Date().timeIntervalSince(parkLastSegmentAt) >= Self.parkTimeout else { return false }
        endReceiverSession("receiver parked: playlist fetched, no segment in \(Int(Self.parkTimeout)) s with \(st.reservoirSegments) segs available")
        return true
    }

    private func stopLinkLog() {
        linkTask?.cancel()
        linkTask = nil
    }

    private func linkTick() {
        guard state == .serving, let remuxer else { return }
        let st = remuxer.lanLinkStats
        if let last = linkLastIngest {
            linkIngestKbps.append(Double(max(0, st.ingestBytes - last)) * 8 / 1000)
        }
        linkLastIngest = st.ingestBytes
        linkTicks += 1
        if checkParked(st) { return }
        guard linkTicks % 10 == 0 else { return }
        let samples = linkIngestKbps
        linkIngestKbps = []
        let avg = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
        let minimum = samples.min() ?? 0
        let stalls = st.starvedClosures - linkLastStarved
        linkLastStarved = st.starvedClosures
        let servedKbps = Double(max(0, st.servedBytes - linkLastServed)) * 8 / 1000 / 10
        linkLastServed = st.servedBytes
        let status = AirPlayMonitor.playerStatusText(player)
        let external = player?.isExternalPlaybackActive ?? false
        let published = remuxer.lanPublishedState()
        let recvSeg = st.receiverHighestSeq >= 0 ? "\(st.receiverHighestSeq)" : "-"
        let edgeSeg = published.edge >= 0 ? "\(published.edge)" : "-"
        let lagSegs = (st.receiverHighestSeq >= 0 && published.edge >= 0)
            ? "\(published.edge - st.receiverHighestSeq)" : "-"
        func secs(_ t: CMTime?) -> String {
            guard let t, t.isValid, t.seconds.isFinite else { return "-" }
            return String(format: "%.1f", t.seconds)
        }
        func rangeText(_ v: NSValue?) -> String {
            guard let r = v?.timeRangeValue else { return "-" }
            return "\(secs(r.start))..\(secs(r.end))"
        }
        let playerT = secs(player?.currentTime())
        let seekable = rangeText(player?.currentItem?.seekableTimeRanges.last)
        // Direct margins in the receiver's item time (t = 0 at the start of
        // the first segment of the first LAN playlist it read).
        func f1(_ v: Double?) -> String {
            guard let v, v.isFinite else { return "-" }
            return String(format: "%.1f", v)
        }
        let t = player?.currentTime().seconds
        let tOK = t?.isFinite ?? false
        let e = published.realEdgeTime
        let p = published.publishedEdgeTime
        let recvBuffer = tOK ? p.map { $0 - t! } : nil
        let margin = tOK ? e.map { $0 - t! } : nil
        let base = published.timeBaseSeq >= 0 ? "seg \(published.timeBaseSeq)" : "-"
        debugLog(String(format: "[AVP-AIRPLAY] link: ingest %.0f kbps avg/%.0f kbps min over 10 s, stalls %d, reservoir %d segs/%.1f s, served %.0f kbps to %@, player status %@, external %@ (hold-back %.1f s, published %d segs, delay %.1f s), receiver last seg %@ / published edge %@ (lag %@ segs), real edge %@ s, published edge %@ s, receiver buffer %@ s, total margin %@ s (t0=%@), player t=%@ s seekable=[%@]",
                        avg, minimum, stalls, st.reservoirSegments, st.reservoirSeconds, servedKbps,
                        st.peer ?? "none", status, external ? "true" : "false", st.holdBack,
                        published.segments, published.delay, recvSeg, edgeSeg, lagSegs,
                        f1(e), f1(p), f1(recvBuffer), f1(margin), base,
                        playerT, seekable))
    }

    /// The receiver-side end of a serving session (external playback off
    /// past the grace, the parked watchdog, a LAN item that failed twice):
    /// playback stops outright, no local resume. LAN delivery (with its
    /// audio rewrite) and the keepalive go now, then the monitor runs the same stop as
    /// the card's X.
    private func endReceiverSession(_ why: String) {
        guard state == .serving else { return }
        debugLog("[AVP-AIRPLAY] \(why): LAN delivery torn down, playback stopped")
        token = UUID()
        state = .idle
        cancelReleaseGrace()
        lanItemStatusObservation = nil
        teardownLAN()
        leaveServing()
        // Stays muted if the receiver never took the item: playback stops.
        mutedForTake = false
        player?.pause()
        AirPlayMonitor.shared.receiverEnded(routeLost: !Self.routeHasAirPlay(), servedByTile: true)
    }

    /// A LAN item failed outside a serving session: drop LAN delivery.
    private func end(reason: String) {
        guard state != .idle else { return }
        token = UUID()
        state = .idle
        cancelReleaseGrace()
        lanItemStatusObservation = nil
        teardownLAN()
        debugLog("[AVP-AIRPLAY] LAN delivery dropped (\(reason))")
        leaveServing()
    }

    private func teardownLAN() {
        remuxer?.stopLANDelivery()
        lanEndpoint = nil
    }

    /// Channel flip under AirPlay (device log 2026-09-25 16:28:17 / 16:28:27):
    /// the old tile released the keepalive and the new one re-acquired it
    /// ~2.5 s later, a window in which a backgrounded app could suspend.
    /// While the route stays AirPlay the release is deferred this long and
    /// handed to the next tile that starts serving.
    static let flipKeepaliveGrace: TimeInterval = 15
    private static var flipKeepaliveRelease: DispatchWorkItem?

    /// The session ended for good (card X, receiver end): drop a
    /// keepalive held for a flip now.
    static func releaseFlipKeepalive() {
        guard let pending = flipKeepaliveRelease else { return }
        pending.cancel()
        flipKeepaliveRelease = nil
        debugLog("[AVP-AIRPLAY] background keepalive off")
        BackgroundKeepalive.release(keepaliveHolder)
    }

    private func leaveServing(holdForFlip: Bool = false) {
        stopLinkLog()
        if keepaliveHeld, holdForFlip, Self.routeHasAirPlay(), Self.flipKeepaliveRelease == nil {
            keepaliveHeld = false
            debugLog("[AVP-AIRPLAY] background keepalive held \(Int(Self.flipKeepaliveGrace))s for the next tune (route still AirPlay)")
            let work = DispatchWorkItem {
                MainActor.assumeIsolated {
                    guard AirPlayTileDelivery.flipKeepaliveRelease != nil else { return }
                    AirPlayTileDelivery.flipKeepaliveRelease = nil
                    debugLog("[AVP-AIRPLAY] background keepalive off (no tune took it over)")
                    BackgroundKeepalive.release(AirPlayTileDelivery.keepaliveHolder)
                }
            }
            Self.flipKeepaliveRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flipKeepaliveGrace, execute: work)
        }
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
        let wasServing = state == .serving
        if state != .idle { teardownLAN() }
        state = .idle
        externalObservation = nil
        lanItemStatusObservation = nil
        cancelReleaseGrace()
        tileExternal = false
        mutedForTake = false
        if let player { Self.tilePlayers.remove(player) }
        player = nil
        leaveServing(holdForFlip: wasServing && logEnd)
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
