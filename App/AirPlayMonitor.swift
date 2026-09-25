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
    /// The output disappeared while playing; local playback continues.
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

    /// Set by the idle-route card's Disconnect: players built for the rest
    /// of this route session get `allowsExternalPlayback = false`, so a
    /// channel started afterwards stays on the phone. Cleared when the
    /// AirPlay output leaves the route.
    private(set) var externalPlaybackDisabledForSession = false

    private weak var player: AVPlayer?
    private var externalObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    /// A tile is preparing a start with an AirPlay route selected.
    private var tileLoading = false

    private init() {
        AirPlayReceiverResolver.shared.onReceiverChange = { [weak self] r in
            self?.setReceiver(r)
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
        if externalPlaybackDisabledForSession { player.allowsExternalPlayback = false }
        startObservingRoutes()
        externalObservation = player.observe(\.isExternalPlaybackActive,
                                            options: [.initial, .new]) { p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor in AirPlayMonitor.shared.apply(active) }
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

    private func detach(silently: Bool) {
        externalObservation = nil
        rateObservation = nil
        player = nil
        tileLoading = false
        if silently {
            isExternal = false
        } else {
            apply(false)
        }
    }

    /// The tile is starting a channel with the route already on AirPlay
    /// (card reads "Connecting to AirPlay" until the receiver takes it).
    func noteTileLoading(_ loading: Bool) {
        guard tileLoading != loading else { return }
        tileLoading = loading
        evaluate()
    }

    func togglePlayPause() {
        guard let player else { return }
        player.timeControlStatus == .paused ? player.play() : player.pause()
    }

    /// The card's X. AirPlay has nothing to "disconnect", so closing ends the
    /// session outright, and it must NOT fall back to the phone's screen
    /// (rule 4: "if I close it, it should just close").
    func stop() {
        debugLog("[Cast] stop: session ended, no local resume (AirPlay); system route stays on AirPlay")
        player?.allowsExternalPlayback = false
        setPhase(.ended)
        detach(silently: true)
        PlayerSession.shared.stop()
        NowPlayingManager.shared.stop()
        RemoteSessionNowPlaying.clear()
    }

    /// Idle-route card's Disconnect: nothing is playing, so there is no
    /// player to pull off the receiver. The app stops offering the route
    /// (card hidden, new players pinned local) until the route changes.
    func disconnectIdleRoute() {
        externalPlaybackDisabledForSession = true
        setPhase(.ended)
    }

    private func apply(_ active: Bool) {
        if isExternal != active {
            isExternal = active
            if !active, phase == .active {
                // Receiver gave the player back with the route still there.
                debugLog("[Cast] card hide (AirPlay)")
            }
        }
        evaluate()
    }

    private func setReceiver(_ r: AirPlayReceiver?) {
        if receiver != r { receiver = r }
        refreshName()
        if phase == .active { RemoteSessionNowPlaying.republishAirPlayDevice() }
    }

    /// Re-derive the phase from the route, the player and the tile.
    func evaluate() {
        let out = AirPlayReceiverResolver.currentAirPlayOutput()
        refreshName()
        guard let out else {
            externalPlaybackDisabledForSession = false
            AirPlayReceiverResolver.shared.cancelRetryLadder()
            if receiver != nil { receiver = nil }
            switch phase {
            case .active, .probing:
                debugLog("[Cast] card hide (AirPlay route lost); playback continues on this device")
                setPhase(.routeLost)
                RemoteSessionNowPlaying.clear()
                setPhase(.none)
            case .idleRoute:
                debugLog("[Cast] card hide (AirPlay idle route)")
                setPhase(.none)
            default:
                setPhase(.none)
            }
            return
        }
        if isExternal {
            if phase != .active {
                debugLog("[Cast] card show (AirPlay)")
                setPhase(.active)
                AirPlayReceiverResolver.shared.runRetryLadder()
            }
            return
        }
        // An ended session stays hidden until the route itself changes.
        if phase == .ended, externalPlaybackDisabledForSession || player == nil && !tileLoading {
            return
        }
        if tileLoading || player != nil {
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
