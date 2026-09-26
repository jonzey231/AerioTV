#if os(iOS)
import AVFoundation
import Combine
import Foundation

// MARK: - AirPlay session monitor (remote-session card parity, 2026-09-12; phases 2026-09-21)

/// Where the AirPlay session stands, for the one remote-session card.
enum AirPlayPhase: Equatable {
    /// No AirPlay output on the route.
    case none
    /// An AirPlay output is selected and a channel is starting toward it.
    case probing(routeName: String?)
    /// An AirPlay output is selected but nothing is playing: the card
    /// invites the user to pick a channel.
    case idleRoute(String?)
    /// The receiver took the player (`isExternalPlaybackActive`).
    case active
    /// The output disappeared while the receiver played; playback stopped
    /// (device test 2026-09-25: no fall-back to the phone).
    case routeLost
    /// The user ended the session from the card or the sheet.
    case ended
}

/// AirPlay has no session object of our own: AVFoundation owns the route, and
/// the only honest signal that the TV took over is `isExternalPlaybackActive`
/// on the AVPlayer the engine built. This wraps that signal, the route off
/// the audio session and the resolved receiver so the ONE remote-session
/// card can represent AirPlay next to Google Cast and the companion
/// transport.
@MainActor
final class AirPlayMonitor: ObservableObject {

    static let shared = AirPlayMonitor()

    @Published private(set) var isExternal = false
    /// Card / sheet / lock-screen name: the resolved receiver name, else the
    /// route's port name when it is not the generic "AirPlay", else nil.
    @Published private(set) var deviceName: String?
    @Published private(set) var isPlaying = true
    @Published private(set) var phase: AirPlayPhase = .none
    /// Set by `AirPlayReceiverResolver`; nil while unknown.
    @Published private(set) var receiver: AirPlayReceiver?
    /// The receiver owns the picture: the fullscreen player is dismissed
    /// (minimized, still mounted so the tile keeps feeding the receiver)
    /// and the remote-session card drives the session, as for Cast.
    /// Sticky across channel flips; cleared when the session ends.
    @Published private(set) var hostsHeadless = false

    private weak var player: AVPlayer?
    private var externalObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    /// A tile is preparing a start with an AirPlay route selected.
    private var tileLoading = false
    /// A channel was picked with the route already on AirPlay: the tune
    /// runs headless from the press (no fullscreen player) until the tile
    /// has a player or falls back. Survives the old tile's detach on a flip.
    private var headlessTune = false
    private var loadingForCard: Bool { tileLoading || headlessTune }
    private var servingSubscription: AnyCancellable?
    /// The receiver dropped `isExternalPlaybackActive` with the AirPlay
    /// output still on the route. Device log 2026-09-25 17:04:54.794: that
    /// happens during a receiver REBUFFER (bursty ingest), and the old 3 s
    /// `receiverReleaseGrace` turned the stall into a full stop at
    /// 17:04:57.876 while Dispatcharr still had the channel healthy. It is
    /// now held as a stall: `isExternal` stays true (LAN delivery, variant,
    /// keepalive, watchdog suspension and the card are untouched, the card
    /// reads "Buffering…"), and `stallWatch` ends the session only on a
    /// real end (see `stallTick`).
    @Published private(set) var receiverBuffering = false
    /// Raw `isExternalPlaybackActive` from the attached player.
    private(set) var playerExternal = false
    private var stallWatch: Task<Void, Never>?
    private var stallStartedAt: Date?
    /// When the player was last seen NOT waiting / buffering during the
    /// stall (nil while it buffers).
    private var stallNotBufferingSince: Date?
    private var stallLastLogAt = Date.distantPast
    /// External playback off, player not buffering, no item error, route
    /// still AirPlay: only after this long is it the receiver ending.
    static let receiverIdleEndSeconds: TimeInterval = 60
    /// Re-entrancy guard for the stop paths (the teardown they run
    /// detaches the player, which re-evaluates the route).
    private var stoppingSession = false

    private init() {
        AirPlayReceiverResolver.shared.onReceiverChange = { [weak self] r in
            self?.setReceiver(r)
        }
        // A tile serving a receiver on the LAN (route picked mid-play, or a
        // tune started with the route selected) is a handoff even before
        // the receiver reports external playback.
        servingSubscription = AirPlayTileDelivery.serving
            .removeDuplicates()
            .sink { serving in
                Task { @MainActor in
                    if serving { AirPlayMonitor.shared.handOffToReceiver() }
                }
            }
    }

    /// Route observation for the whole process (idle-route card at launch,
    /// route loss while playing). Idempotent; called at scene activation.
    func startObservingRoutes() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AirPlayMonitor.shared.evaluate() }
        }
        evaluate()
    }

    /// Called by every iOS AVPlayer engine site right after the player is
    /// built. One player at a time: a new session replaces the old.
    func attach(_ player: AVPlayer) {
        detach(silently: true)
        self.player = player
        // Every attached player may go external (device log 2026-09-25
        // 12:38:47: a player pinned local by an earlier X never entered
        // external playback when the Apple TV was picked mid-play, so only
        // the system audio route reached the TV).
        // No per-session opt-out (device log 2026-09-25): while the system
        // route is AirPlay a tune goes to the receiver, because that is
        // what the route means; only the user's route picker changes it.
        Self.enableExternalPlayback(on: player)
        startObservingRoutes()
        externalObservation = player.observe(\.isExternalPlaybackActive,
                                            options: [.initial, .new]) { p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor in AirPlayMonitor.shared.apply(active, fromPlayer: true) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in
                let monitor = AirPlayMonitor.shared
                if monitor.isPlaying != playing { monitor.isPlaying = playing }
            }
        }
    }

    func detach() { detach(silently: false) }

    /// Video external playback on: the receiver takes the item, not just
    /// the audio route.
    static func enableExternalPlayback(on player: AVPlayer) {
        if !player.allowsExternalPlayback { player.allowsExternalPlayback = true }
        if !player.usesExternalPlaybackWhileExternalScreenIsActive {
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
        }
    }

    /// The attached player, re-enabled for external playback when an
    /// AirPlay output appears (a player from an older build path that
    /// was never pinned local). Also called by AirPlayTileDelivery before a mid-play
    /// handoff swaps the item.
    func reenableExternalPlaybackForRoute() {
        guard let player, !player.allowsExternalPlayback else { return }
        Self.enableExternalPlayback(on: player)
        debugLog("[AVP-AIRPLAY] external playback re-enabled on the attached player (AirPlay route present)")
    }

    private func detach(silently: Bool) {
        externalObservation = nil
        rateObservation = nil
        player = nil
        tileLoading = false
        endStall()
        playerExternal = false
        if silently {
            isExternal = false
        } else {
            apply(false, fromPlayer: false)
        }
    }

    /// The tile is starting a channel with the route already on AirPlay
    /// (card reads "Connecting to AirPlay" until the receiver takes it).
    func noteTileLoading(_ loading: Bool) {
        if !loading { headlessTune = false }
        guard tileLoading != loading else { evaluate(); return }
        tileLoading = loading
        evaluate()
    }

    /// Tune entry (NowPlayingManager.startPlaying): a live channel picked
    /// while an AirPlay route is selected never shows the fullscreen
    /// player (device log 2026-09-25 12:36:33: the player came up with
    /// its loading state and was dismissed only after playback started).
    /// The container mounts hidden and minimized, the card reads
    /// "Connecting to AirPlay…" at once. Returns true when the caller must
    /// start minimized.
    func beginHeadlessTune(channel: String) -> Bool {
        guard let out = AirPlayReceiverResolver.currentAirPlayOutput(),
              receiver?.isAudioOnly != true,
              !AerioCastController.shared.isCasting,
              !CompanionClient.shared.isControlling else { return false }
        headlessTune = true
        if !hostsHeadless { hostsHeadless = true }
        debugLog("[AVP-AIRPLAY] AirPlay route selected (\(out.name ?? "?")): tuning \(channel) headless, no fullscreen player; card shows Connecting to AirPlay")
        AppOrientationLock.release()
        // evaluate() moves an idle-route / ended card to probing; an
        // active one follows once the old tile detaches.
        evaluate()
        return true
    }

    /// The headless tune cannot reach the receiver (audio-only speaker,
    /// no LAN address, LAN delivery unavailable, route gone at READY):
    /// show the player on this device instead of playing invisibly.
    func headlessTuneFellBack(reason: String) {
        guard headlessTune || (hostsHeadless && !isExternal && !AirPlayTileDelivery.isServingReceiver) else { return }
        headlessTune = false
        hostsHeadless = false
        debugLog("[AVP-AIRPLAY] headless tune fell back (\(reason)): showing the player on this device")
        NowPlayingManager.shared.expand()
        evaluate()
    }

    func togglePlayPause() {
        guard let player else { return }
        player.timeControlStatus == .paused ? player.play() : player.pause()
    }

    /// Back / Forward skip from the AirPlay sheet: seeks the tile's player
    /// (which feeds the receiver) within its seekable range, clamped so a
    /// forward skip lands on the live edge at most.
    func seek(by seconds: Double) {
        guard let player, let item = player.currentItem else { return }
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        var target = now + seconds
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let lo = range.start.seconds, hi = range.end.seconds
            if lo.isFinite, hi.isFinite { target = min(max(target, lo), hi) }
        }
        debugLog("[AVP-AIRPLAY] skip \(seconds > 0 ? "+" : "")\(Int(seconds))s -> \(String(format: "%.1f", target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The card's X / Stop AirPlay. Playback stops outright and must NOT
    /// fall back to the phone's screen (rule 4: "if I close it, it should
    /// just close"). An app cannot deselect an AirPlay route, so when the
    /// system route is still AirPlay the card returns to the idle-route
    /// state (Disconnect opens the route picker) and the next channel goes
    /// to the receiver (device log 2026-09-25: pinning later players local
    /// left the TV with the audio route only).
    func stop() {
        let routeStays = AirPlayReceiverResolver.currentAirPlayOutput() != nil
        if routeStays {
            debugLog("[Cast] stop: playback stopped, no local resume (AirPlay); system route still on AirPlay, card back to idle route (Disconnect opens the route picker)")
        } else {
            debugLog("[Cast] stop: session ended, no local resume (AirPlay)")
        }
        setPhase(.ended)
        stopPlayback()
        if routeStays {
            setPhase(.none)
            evaluate()
        }
    }

    /// The one teardown behind the card's X, Stop AirPlay and a
    /// receiver-side end (device test 2026-09-25): playback stops outright,
    /// never falls back to the phone. PlayerSession.stop() unmounts the
    /// tile, whose AirPlayTileDelivery.reset() tears down LAN delivery and
    /// the airplay-aac variant and releases the keepalive.
    private func stopPlayback() {
        guard !stoppingSession else { return }
        stoppingSession = true
        defer { stoppingSession = false }
        hostsHeadless = false
        headlessTune = false
        detach(silently: true)
        PlayerSession.shared.stop()
        NowPlayingManager.shared.stop()
        AirPlayTileDelivery.releaseFlipKeepalive()
        RemoteSessionNowPlaying.clear()
    }

    /// The fullscreen player gives way to the card (Cast parity, device
    /// test 2026-09-25: the player stayed up as a black screen). The
    /// container is minimized, not torn down: its tile is what feeds the
    /// receiver, so the session continues headless behind the card.
    func handOffToReceiver() {
        if hostsHeadless { AppOrientationLock.release() }
        guard !hostsHeadless, !stoppingSession,
              AirPlayReceiverResolver.currentAirPlayOutput() != nil,
              PlayerSession.shared.mode != .idle || NowPlayingManager.shared.playingItem != nil
        else { return }
        hostsHeadless = true
        debugLog("[AVP-AIRPLAY] fullscreen player dismissed: the receiver plays, the tile keeps serving it headless behind the card")
        AppOrientationLock.release()
        if !NowPlayingManager.shared.isMinimized {
            NowPlayingManager.shared.applyMinimized()
        }
    }

    /// The receiver side ended AirPlay (route gone, or the receiver let go
    /// of the player): stop, same as the card's X. Called by the monitor's
    /// own route evaluation and by the tile's route observer, whichever
    /// runs first; the second call is a no-op.
    /// `servedByTile`: the tile was serving the receiver on the LAN, so
    /// the session belonged to it even if the card never reached `.active`.
    func receiverEnded(routeLost: Bool, servedByTile: Bool = false) {
        guard !stoppingSession, phase != .ended, phase != .routeLost else { return }
        guard servedByTile || phase == .active || hostsHeadless || isExternal else { return }
        endStall()
        if routeLost {
            debugLog("[Cast] card hide (AirPlay route lost); playback stopped")
            setPhase(.routeLost)
            stopPlayback()
            setPhase(.none)
        } else {
            debugLog("[Cast] card hide (AirPlay)")
            debugLog("[Cast] stop: the receiver ended AirPlay; playback stopped, no local resume")
            setPhase(.ended)
            stopPlayback()
        }
    }

    /// Idle-route card's Disconnect: an app cannot deselect an AirPlay
    /// route, so this presents the system route picker for the user to
    /// pick this iPhone. The card stays until the route actually changes.
    /// Route uid whose idle card the user dismissed with X. The route
    /// stays selected (an app cannot drop it); the idle card stays hidden
    /// for this route until the route changes or a channel is tuned.
    private(set) var dismissedRouteUID: String?

    /// Idle card X (2026-09-25 production recording): hide the card only.
    func dismissIdleCard() {
        dismissedRouteUID = AirPlayReceiverResolver.currentAirPlayOutput()?.uid
        debugLog("[Cast] card hide (AirPlay, dismissed by user)")
        setPhase(.none)
    }

    func disconnectIdleRoute() {
        debugLog("[AVP-AIRPLAY] disconnect: presenting the AirPlay route picker (an app cannot deselect the route; pick this iPhone to end AirPlay)")
        AirPlayMenuTrigger.present()
    }

    private func apply(_ active: Bool, fromPlayer: Bool) {
        if fromPlayer { playerExternal = active }
        if active, fromPlayer, let since = stallStartedAt {
            debugLog("[AVP-AIRPLAY] external playback resumed after \(String(format: "%.1f", Date().timeIntervalSince(since))) s")
            endStall()
        }
        if isExternal != active {
            if !active, fromPlayer, phase == .active,
               AirPlayReceiverResolver.currentAirPlayOutput() != nil {
                // The receiver let go with the route still up: a stall
                // until proven otherwise (device log 2026-09-25 17:04).
                beginStall()
                return
            }
            isExternal = active
            if !active, phase == .active {
                // Player detached (tune teardown, channel flip): not a
                // receiver-side end.
                debugLog("[Cast] card hide (AirPlay)")
            }
        }
        evaluate()
    }

    // MARK: Receiver stall (device log 2026-09-25 17:04)

    /// "playing", "paused" or "waiting:<reason>" for the stall and link lines.
    static func playerStatusText(_ player: AVPlayer?) -> String {
        guard let player else { return "none" }
        switch player.timeControlStatus {
        case .playing: return "playing"
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate:
            return "waiting:" + waitingReasonText(player.reasonForWaitingToPlay)
        @unknown default: return "unknown"
        }
    }

    static func waitingReasonText(_ reason: AVPlayer.WaitingReason?) -> String {
        guard let reason else { return "unknown" }
        switch reason {
        case .toMinimizeStalls: return "toMinimizeStalls"
        case .evaluatingBufferingRate: return "evaluatingBufferingRate"
        case .noItemToPlay: return "noItemToPlay"
        default: return reason.rawValue
        }
    }

    /// Buffering reason for the stall lines.
    private func stallReasonText() -> String {
        guard let player else { return "no player" }
        var parts: [String] = []
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            parts.append(Self.waitingReasonText(player.reasonForWaitingToPlay))
        } else {
            parts.append(Self.playerStatusText(player))
        }
        if let item = player.currentItem {
            if item.isPlaybackBufferEmpty { parts.append("buffer empty") }
            if item.status == .failed { parts.append("item failed: \(item.error?.localizedDescription ?? "unknown")") }
        }
        return parts.joined(separator: ", ")
    }

    private func beginStall() {
        guard stallStartedAt == nil else { return }
        let now = Date()
        stallStartedAt = now
        stallNotBufferingSince = nil
        stallLastLogAt = now
        if !receiverBuffering { receiverBuffering = true }
        debugLog("[AVP-AIRPLAY] external playback paused by the receiver (buffering: \(stallReasonText())); holding the session")
        stallWatch?.cancel()
        stallWatch = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                AirPlayMonitor.shared.stallTick()
            }
        }
    }

    private func endStall() {
        stallWatch?.cancel()
        stallWatch = nil
        stallStartedAt = nil
        stallNotBufferingSince = nil
        if receiverBuffering { receiverBuffering = false }
    }

    /// Once a second while the receiver is stalled. Ends the session only
    /// when (a) the route lost its AirPlay output (the route evaluation's
    /// own end), (b) the player has not been waiting / buffering for
    /// `receiverIdleEndSeconds` with no item error, or (c) the item failed
    /// and no serving tile is left to reload it (the tile reloads it once
    /// on the same LAN URL and gives up itself on a second failure).
    private func stallTick() {
        guard let since = stallStartedAt else { return }
        let now = Date()
        let off = now.timeIntervalSince(since)
        guard let player else {
            endStall()
            isExternal = false
            evaluate()
            return
        }
        if AirPlayReceiverResolver.currentAirPlayOutput() == nil {
            debugLog("[AVP-AIRPLAY] AirPlay output left the route during the receiver stall (\(Int(off)) s)")
            endStall()
            evaluate()
            return
        }
        if let item = player.currentItem, item.status == .failed {
            if AirPlayTileDelivery.isServingReceiver { return }
            debugLog("[AVP-AIRPLAY] receiver stall: item failed (\(item.error?.localizedDescription ?? "unknown")) and no LAN tile to reload it; the receiver ended AirPlay")
            endStall()
            receiverEnded(routeLost: false)
            return
        }
        let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            || player.currentItem?.isPlaybackBufferEmpty == true
        if buffering {
            stallNotBufferingSince = nil
        } else if stallNotBufferingSince == nil {
            stallNotBufferingSince = now
        }
        if let idle = stallNotBufferingSince,
           now.timeIntervalSince(idle) >= Self.receiverIdleEndSeconds {
            debugLog("[AVP-AIRPLAY] external playback off \(Int(off)) s, player \(Self.playerStatusText(player)) (not buffering) for \(Int(Self.receiverIdleEndSeconds)) s, no item error: the receiver ended AirPlay")
            endStall()
            receiverEnded(routeLost: false)
            return
        }
        if now.timeIntervalSince(stallLastLogAt) >= 10 {
            stallLastLogAt = now
            debugLog("[AVP-AIRPLAY] external playback still paused by the receiver after \(Int(off)) s (buffering: \(stallReasonText())); holding the session")
        }
    }

    private func setReceiver(_ r: AirPlayReceiver?) {
        if receiver != r { receiver = r }
        // A receiver resolved after the plan was decided: the serving tile
        // re-plans passthrough -> AAC for a non-Apple one (2026-09-25).
        if let r { AirPlayTileDelivery.receiverResolved(r) }
        refreshName()
        if phase == .active { RemoteSessionNowPlaying.republishAirPlayDevice() }
    }

    /// Re-derive the phase from the route, the player and the tile.
    func evaluate() {
        let out = AirPlayReceiverResolver.currentAirPlayOutput()
        refreshName()
        if out != nil {
            reenableExternalPlaybackForRoute()
            // Browse from the moment the route appears, not only at
            // handoff (device log 2026-09-25 16:22-16:25: UNRESOLVED).
            AirPlayReceiverResolver.shared.routePresent()
        }
        guard let out else {
            dismissedRouteUID = nil
            headlessTune = false
            AirPlayReceiverResolver.shared.cancelRetryLadder()
            // Incident 2026-09-25: no AirPlay route, no Bonjour browse.
            AirPlayReceiverResolver.shared.stopBrowsing()
            if receiver != nil { receiver = nil }
            if player?.isExternalPlaybackActive == true,
               phase == .active || hostsHeadless || AirPlayTileDelivery.isServingReceiver {
                // Device log 2026-09-25 23:12:49: the route briefly showed
                // no AirPlay output while the receiver kept playing. Hold;
                // apply(false) re-evaluates once the player lets go.
                debugLog("[AVP-AIRPLAY] route shows no AirPlay output but external playback is active; holding the session")
                return
            }
            if phase == .active || hostsHeadless || AirPlayTileDelivery.isServingReceiver {
                receiverEnded(routeLost: true)
                setPhase(.none)
                return
            }
            switch phase {
            case .probing:
                // The receiver never took playback (audio-only speaker, or
                // it dropped mid-handoff): the phone was still playing.
                debugLog("[Cast] card hide (AirPlay route lost before handoff); playback continues on this device")
                setPhase(.none)
            case .idleRoute:
                debugLog("[Cast] card hide (AirPlay idle route)")
                setPhase(.none)
            default:
                setPhase(.none)
            }
            return
        }
        if let dismissed = dismissedRouteUID, dismissed != out.uid {
            dismissedRouteUID = nil
        }
        if isExternal {
            dismissedRouteUID = nil
            if phase != .active {
                debugLog("[Cast] card show (AirPlay)")
                setPhase(.active)
                AirPlayReceiverResolver.shared.runRetryLadder()
            }
            if player != nil { handOffToReceiver() }
            return
        }
        // An ended session stays hidden until the route itself changes.
        if phase == .ended, player == nil && !loadingForCard {
            return
        }
        if loadingForCard || player != nil {
            // A tune on the dismissed route still goes to the TV.
            dismissedRouteUID = nil
            guard !isProbing else { return }
            debugLog("[Cast] card show (AirPlay, probing route \(out.name ?? "?"))")
            setPhase(.probing(routeName: out.name))
            AirPlayReceiverResolver.shared.runRetryLadder()
            return
        }
        // Idle route: only for a screen-capable receiver and only while no
        // Cast / companion session owns the card (plan open question 8).
        if receiver?.isAudioOnly == true
            || AerioCastController.shared.isCasting
            || CompanionClient.shared.isControlling {
            if case .idleRoute = phase { setPhase(.none) }
            return
        }
        if case .idleRoute = phase { return }
        if dismissedRouteUID == out.uid { return }
        let label = AirPlayReceiver.isGenericName(out.name) ? "unresolved" : (out.name ?? "unresolved")
        debugLog("[Cast] card show (AirPlay idle route \(label))")
        setPhase(.idleRoute(out.name))
        AirPlayReceiverResolver.shared.runRetryLadder()
    }

    private var isProbing: Bool {
        if case .probing = phase { return true }
        return false
    }

    private func setPhase(_ p: AirPlayPhase) {
        if p == .ended, phase != .ended {
            debugLog("[Cast] card hide (AirPlay, session ended)")
        }
        if p == .none || p == .ended || p == .routeLost { hostsHeadless = false }
        if phase != p { phase = p }
    }

    private func refreshName() {
        let routeName = AirPlayReceiverResolver.currentAirPlayOutput()?.name
        let name = receiver?.displayName
            ?? (AirPlayReceiver.isGenericName(routeName) ? nil : routeName)
        if deviceName != name { deviceName = name }
    }
}
#endif
