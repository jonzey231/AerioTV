#if os(iOS)
import AVFoundation
import AVKit
import Combine
import Foundation
import SwiftUI
import UIKit

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
    /// The player the receiver is showing, for the AirPlay Options sheet's
    /// audio, subtitle and speed rows (AVPlayer carries those to the receiver).
    var attachedPlayer: AVPlayer? { player }
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
    /// The receiver dropped `isExternalPlaybackActive` while a tile serves
    /// it (a receiver rebuffer, device log 2026-09-25 17:04). The card
    /// stays active and reads "Buffering…"; whether the session ends is
    /// AirPlayTileDelivery's call (its release grace), never this one's.
    @Published private(set) var receiverBuffering = false
    /// Channel name of an in-place channel flip in progress: set when the
    /// tile splices the new channel into the receiver's playlist and
    /// cleared when the receiver fetches the new channel's first segment
    /// (or the flip is abandoned / the session ends). The card and sheet
    /// read "Switching to <channel>" for that window, as for Cast.
    @Published private(set) var switchingToTitle: String?

    func noteSwitching(to name: String?) {
        if switchingToTitle != name { switchingToTitle = name }
    }

    /// Accent status line for the AirPlay card and sheet while playing: a
    /// flip in progress wins, then a receiver rebuffer, then the steady
    /// "AirPlay to <receiver>" (`playing`). Same precedence as Cast's
    /// castStatusLine.
    func statusLine(playing: String) -> String {
        if let switchingToTitle { return "Switching to \(switchingToTitle)" }
        return receiverBuffering ? "Buffering\u{2026}" : playing
    }
    /// Raw `isExternalPlaybackActive` from the attached player.
    private(set) var playerExternal = false
    /// A player no tile delivery owns (PlayerView's direct / HLS / VOD
    /// players): external playback off for this long is the receiver
    /// ending AirPlay, and playback stops outright (no local resume).
    static let receiverReleaseGrace: TimeInterval = 5
    private var releaseGraceTask: Task<Void, Never>?
    /// Re-entrancy guard for the stop paths (the teardown they run
    /// detaches the player, which re-evaluates the route).
    private var stoppingSession = false

    // MARK: User-ended latch (2026-10-05)

    /// Route uid the user ended with the card's X / Stop AirPlay while the
    /// system route stayed on that receiver. While it matches the current
    /// AirPlay output the app does not use the route on its own: tunes play
    /// on this device (fullscreen player, allowsExternalPlayback false, no
    /// LAN serving, no card). Set by the card's X (active or idle card) and
    /// Stop AirPlay. Cleared ONLY by an explicit pick of a receiver in the
    /// AirPlay picker (Logan 2026-10-07: a route leaving AirPlay,
    /// newDeviceAvailable or foregrounding must not clear it; device log
    /// 11:31:36 / 11:35:01 "route left AirPlay" re-enabled serving). The
    /// latch is per receiver uid, so a different receiver is servable.
    ///
    /// What iOS allows: AVPlayer.allowsExternalPlayback = false keeps the
    /// VIDEO (and the player's external playback session) on the device.
    /// There is no public API to deselect an AirPlay AUDIO route:
    /// AVAudioSession exposes currentRoute (read only), setPreferredInput
    /// (inputs only) and overrideOutputAudioPort(.speaker) (playAndRecord
    /// category only, and it does not drop an AirPlay output); only the
    /// system route picker (AVRoutePickerView / Control Center) changes the
    /// output. So while the user leaves the receiver selected, the system
    /// audio route still points at it, and an audio-only channel's sound
    /// may still play there (the app no longer serves it video).
    private(set) var userEndedRouteUID: String?

    /// The AirPlay output the app may use on its own: the current output
    /// unless the user ended AirPlay on it. Every "the route is AirPlay,
    /// serve the receiver" decision reads this, never the raw route.
    static func servableAirPlayOutput() -> (name: String?, uid: String)? {
        guard let out = AirPlayReceiverResolver.currentAirPlayOutput() else { return nil }
        if let ended = shared.userEndedRouteUID, ended == out.uid { return nil }
        return out
    }

    /// A tune now would be served to a screen receiver (Force HLS bypass).
    var willServeReceiver: Bool {
        Self.servableAirPlayOutput() != nil && receiver?.isAudioOnly != true
    }

    /// Set with userEndedRouteUID by "Play Here" (PlayWhereRouter, Logan
    /// 2026-10-06): the latch lasts for that one local player only. When the
    /// player it pinned is gone (no player re-attaches within 1.5 s and the
    /// session is idle) the latch clears and the route is offered again
    /// (idle card, "Select a Channel"), without the user re-picking it.
    private var latchIsPerTune = false
    /// A player attached while the per-tune latch was set.
    private var perTuneSawPlayer = false
    private var perTuneClearTask: Task<Void, Never>?

    /// "Play Here" while an AirPlay session is active. Pins the next player
    /// to this device with the same latch the card's X uses (attach() sets
    /// allowsExternalPlayback false; no LAN serving, no headless tune).
    ///
    /// What AirPlay cannot do: serve the receiver and play a second stream
    /// here at the same time. The receiver's stream IS the one player
    /// session's tile (its AVPlayer is the external-playback player and its
    /// TSHLSRemuxer LAN session feeds the receiver), and a new tune replaces
    /// that session (a live tune swaps or reseeds the sole tile; catch-up,
    /// VOD and DVR call PlayerSession.exit() first). A second tile would
    /// turn the pick into a multiview grid and a second attached player
    /// would take over the route, so the closest safe behavior is: the
    /// receiver's playback stops (same teardown as the card's X), the pick
    /// plays here, and the route comes back as the idle card when that
    /// local player closes. Returns true when a session was torn down (the
    /// caller waits a beat before tuning).
    func pinLocalForPlayHere() -> Bool {
        guard let route = AirPlayReceiverResolver.currentAirPlayOutput() else { return false }
        userEndedRouteUID = route.uid
        latchIsPerTune = true
        perTuneSawPlayer = false
        perTuneClearTask?.cancel()
        let playing = player != nil || PlayerSession.shared.mode != .idle
            || NowPlayingManager.shared.playingItem != nil
        debugLog("[AVP-AIRPLAY] play here: next player pinned local; \(playing ? "receiver playback stops (one player session serves AirPlay)" : "receiver idle")")
        if playing {
            stopPlayback()
        }
        setPhase(.none)
        evaluate()
        return playing
    }

    /// Player gone under the per-tune latch: clear it once nothing
    /// re-attached (a channel flip re-attaches at once).
    private func schedulePerTuneClear() {
        guard latchIsPerTune, perTuneSawPlayer else { return }
        perTuneClearTask?.cancel()
        perTuneClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.latchIsPerTune,
                  self.player == nil,
                  PlayerSession.shared.mode == .idle else { return }
            self.clearUserEnded("play-here player closed")
            self.evaluate()
        }
    }

    private func clearUserEnded(_ why: String) {
        latchIsPerTune = false
        perTuneSawPlayer = false
        perTuneClearTask?.cancel()
        perTuneClearTask = nil
        guard userEndedRouteUID != nil else { return }
        userEndedRouteUID = nil
        debugLog("[AVP-AIRPLAY] user-ended latch cleared (\(why)): AirPlay route usable again")
    }

    /// Route change hook (monitor's own observer and the tile's, whichever
    /// runs first): a newly available device is a fresh user choice.
    /// The X latch is no longer cleared here (Logan 2026-10-07): only an
    /// explicit pick re-enables serving. The per-tune Play Here latch still
    /// clears when the route leaves AirPlay (nothing left to pin against).
    func noteRouteChange(reasonRaw: UInt) {
        guard userEndedRouteUID != nil, latchIsPerTune,
              AirPlayReceiverResolver.currentAirPlayOutput() == nil else { return }
        clearUserEnded("route left AirPlay (Play Here)")
    }

    /// The system route picker closed (AVRoutePickerViewDelegate). With an
    /// AirPlay output selected that is the user picking AirPlay, including
    /// the same receiver again (no route change fires for that). A picker
    /// cancelled without a choice is indistinguishable and also counts.
    func routePickerDismissed() {
        guard userEndedRouteUID != nil,
              AirPlayReceiverResolver.currentAirPlayOutput() != nil else { return }
        clearUserEnded("route picked in the AirPlay picker")
        evaluate()
        NotificationCenter.default.post(name: .aerioAirPlayRoutePicked, object: nil)
    }

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
                    let monitor = AirPlayMonitor.shared
                    if serving {
                        monitor.handOffToReceiver()
                    } else if monitor.receiverBuffering {
                        // The tile stopped serving while the receiver was
                        // off: settle the card on the player's real state.
                        monitor.receiverBuffering = false
                        monitor.isExternal = monitor.playerExternal
                        monitor.evaluate()
                    }
                }
            }
    }

    /// Route observation for the whole process (idle-route card at launch,
    /// card phases). Idempotent; called at scene activation.
    func startObservingRoutes() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            Task { @MainActor in
                AirPlayMonitor.shared.noteRouteChange(reasonRaw: reason)
                AirPlayMonitor.shared.evaluate()
            }
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
        if userEndedRouteUID != nil, Self.servableAirPlayOutput() == nil,
           AirPlayReceiverResolver.currentAirPlayOutput() != nil {
            // The user ended AirPlay on this route: the video stays here.
            player.allowsExternalPlayback = false
            if latchIsPerTune {
                perTuneSawPlayer = true
                perTuneClearTask?.cancel()
            }
            debugLog("[AVP-AIRPLAY] player pinned local (\(latchIsPerTune ? "Play Here" : "user ended AirPlay on this route"))")
        } else {
            Self.enableExternalPlayback(on: player)
        }
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

    /// Detach only when `p` is the attached player. A Multiview tile that
    /// does not own the route (device log 2026-10-07 11:32:35: ESPN2 HD
    /// retried a frozen pipeline during a 2-up AirPlay composite) must not
    /// detach the composite tile's player; that dropped the card to the
    /// idle route ("Select a Channel") while the receiver kept playing.
    func detach(ifAttached p: AVPlayer?) {
        guard let p, player === p else { return }
        detach(silently: false)
    }

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
        guard let player, !player.allowsExternalPlayback,
              Self.servableAirPlayOutput() != nil else { return }
        Self.enableExternalPlayback(on: player)
        debugLog("[AVP-AIRPLAY] external playback re-enabled on the attached player (AirPlay route present)")
    }

    private func detach(silently: Bool) {
        externalObservation = nil
        rateObservation = nil
        player = nil
        tileLoading = false
        cancelReleaseGrace()
        playerExternal = false
        if silently {
            isExternal = false
        } else {
            apply(false, fromPlayer: false)
        }
        if !silently { schedulePerTuneClear() }
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
        guard let out = Self.servableAirPlayOutput(),
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

    /// Seekable window for the AirPlay sheet's timeline scrub, in player
    /// seconds. nil when the item has no seekable range of at least 1 s
    /// (plain live): the bar stays read-only.
    func remoteSeekWindow() -> RemoteSeekWindow? {
        guard let player, let item = player.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let lo = range.start.seconds, hi = range.end.seconds
        let pos = player.currentTime().seconds
        guard lo.isFinite, hi.isFinite, pos.isFinite, hi - lo >= 1 else { return nil }
        let isLive = !item.duration.seconds.isFinite
        return RemoteSeekWindow(start: lo, end: hi, position: min(max(pos, lo), hi), isLive: isLive)
    }

    /// Timeline scrub release: the same player seek the skip buttons use,
    /// to an absolute player time clamped to the seekable range.
    func seek(to seconds: Double) {
        guard let player, let item = player.currentItem else { return }
        var target = seconds
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let lo = range.start.seconds, hi = range.end.seconds
            if lo.isFinite, hi.isFinite { target = min(max(target, lo), hi) }
        }
        guard target.isFinite else { return }
        debugLog("[Cast] scrub seek to \(Int(target))s (AirPlay)")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The card's X / Stop AirPlay. Playback stops outright and must NOT
    /// fall back to the phone's screen (rule 4: "if I close it, it should
    /// just close"). An app cannot deselect an AirPlay route (see
    /// userEndedRouteUID), so when the system route is still AirPlay the
    /// user-ended latch is set (Logan 2026-10-05: the next channel must play
    /// on this device, not reconnect to the receiver) and the card hides.
    /// The idle-route card with Disconnect (route picker) remains for a
    /// route the user did not end, e.g. a receiver still selected at launch.
    func stop() {
        let route = AirPlayReceiverResolver.currentAirPlayOutput()
        if let route {
            userEndedRouteUID = route.uid
            latchIsPerTune = false
            debugLog("[Cast] stop: playback stopped, no local resume (AirPlay); system route still on AirPlay, card hidden")
            debugLog("[AVP-AIRPLAY] user ended AirPlay: local playback until a route is picked again")
        } else {
            debugLog("[Cast] stop: session ended, no local resume (AirPlay)")
        }
        setPhase(.ended)
        stopPlayback()
        if route != nil {
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
        MultiviewCompositeSession.shared.stop(detail: "airplay session ended")
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
              Self.servableAirPlayOutput() != nil,
              PlayerSession.shared.mode != .idle || NowPlayingManager.shared.playingItem != nil
        else { return }
        hostsHeadless = true
        debugLog("[AVP-AIRPLAY] fullscreen player dismissed: the receiver plays, the tile keeps serving it headless behind the card")
        AppOrientationLock.release()
        if !NowPlayingManager.shared.isMinimized {
            NowPlayingManager.shared.applyMinimized()
        }
    }

    /// The receiver side ended AirPlay: stop, same as the card's X. Called
    /// only by AirPlayTileDelivery, the session's one owner (external
    /// playback off past its grace, parked receiver, LAN item failed).
    /// `routeLost`: no AirPlay output was left on the route at that point
    /// (card wording only). `servedByTile`: the tile was serving the
    /// receiver on the LAN, so the session belonged to it even if the
    /// card never reached `.active`.
    func receiverEnded(routeLost: Bool, servedByTile: Bool = false) {
        guard !stoppingSession, phase != .ended, phase != .routeLost else { return }
        guard servedByTile || phase == .active || hostsHeadless || isExternal else { return }
        cancelReleaseGrace()
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
    /// Device log 2026-10-07 11:34:27.572: the idle card's X only hid the
    /// card, so the next tap (11:34:28.622) tuned headless onto the Apple
    /// TV. The X now ends the app's use of the route exactly like the
    /// active card's X: it sets the user-ended latch and stops anything
    /// still serving the receiver.
    func dismissIdleCard() {
        let route = AirPlayReceiverResolver.currentAirPlayOutput()
        dismissedRouteUID = route?.uid
        debugLog("[Cast] card hide (AirPlay, dismissed by user)")
        if let route {
            userEndedRouteUID = route.uid
            latchIsPerTune = false
            perTuneClearTask?.cancel()
            debugLog("[AVP-AIRPLAY] user ended AirPlay (idle card X): local playback until a route is picked again")
        }
        if MultiviewCompositeSession.shared.transport == .airPlay
            || AirPlayTileDelivery.isServingReceiver {
            stopPlayback()
        }
        setPhase(.none)
    }

    func disconnectIdleRoute() {
        debugLog("[AVP-AIRPLAY] disconnect: presenting the AirPlay route picker (an app cannot deselect the route; pick this iPhone to end AirPlay)")
        AirPlayMenuTrigger.present()
    }

    private func apply(_ active: Bool, fromPlayer: Bool) {
        if fromPlayer { playerExternal = active }
        if active, fromPlayer { cancelReleaseGrace() }
        if isExternal != active {
            if !active, fromPlayer, phase == .active, AirPlayTileDelivery.isServingReceiver {
                // The tile decides whether this is the end (release
                // grace); the card holds and reads "Buffering…".
                if !receiverBuffering { receiverBuffering = true }
                return
            }
            if !active, fromPlayer, phase == .active,
               let player, !AirPlayTileDelivery.isTilePlayer(player) {
                // No tile owns this player: the monitor's own grace, on
                // the player signal only (never the route).
                startReleaseGrace()
                return
            }
            isExternal = active
            if !active, phase == .active {
                debugLog("[Cast] card hide (AirPlay)")
            }
        }
        evaluate()
    }

    private func startReleaseGrace() {
        if !receiverBuffering { receiverBuffering = true }
        guard releaseGraceTask == nil else { return }
        debugLog("[AVP-AIRPLAY] external playback off (player \(Self.playerStatusText(player))); stopping unless it returns within \(Int(Self.receiverReleaseGrace)) s")
        releaseGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.receiverReleaseGrace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.releaseGraceTask = nil
            guard self.player?.isExternalPlaybackActive != true,
                  !AirPlayTileDelivery.isServingReceiver else { return }
            debugLog("[AVP-AIRPLAY] external playback off for \(Int(Self.receiverReleaseGrace)) s: the receiver ended AirPlay")
            self.receiverEnded(routeLost: false)
        }
    }

    private func cancelReleaseGrace() {
        releaseGraceTask?.cancel()
        releaseGraceTask = nil
        if receiverBuffering { receiverBuffering = false }
    }

    /// "playing", "paused" or "waiting:<reason>" for the tile's lines.
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
        let rawOut = AirPlayReceiverResolver.currentAirPlayOutput()
        // The X latch survives the route leaving AirPlay or moving to a
        // different output (Logan 2026-10-07); it is uid-scoped, so another
        // receiver is servable anyway. Only Play Here's per-tune latch
        // clears with the route.
        if userEndedRouteUID != nil, latchIsPerTune, rawOut == nil {
            clearUserEnded("route left AirPlay (Play Here)")
        }
        if rawOut != nil, Self.servableAirPlayOutput() == nil,
           !isExternal, !AirPlayTileDelivery.isServingReceiver {
            // User-ended route: no card, no external playback, no browse.
            headlessTune = false
            if phase != .none, phase != .ended { setPhase(.none) }
            return
        }
        let out = rawOut
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
            // Route loss never ends a session: while the receiver plays or
            // a tile serves it, AirPlayTileDelivery owns the end.
            if isExternal || AirPlayTileDelivery.isServingReceiver { return }
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
        if p == .none || p == .ended || p == .routeLost {
            hostsHeadless = false
            noteSwitching(to: nil)
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

extension Notification.Name {
    /// The user re-picked an AirPlay route after ending AirPlay (the latch
    /// cleared with no route change): a tile playing locally hands over.
    static let aerioAirPlayRoutePicked = Notification.Name("aerioAirPlayRoutePicked")
}

/// Shared AVRoutePickerView delegate: a closed picker with an AirPlay output
/// selected clears the user-ended latch.
@MainActor
final class AirPlayRoutePickerDelegate: NSObject, @MainActor AVRoutePickerViewDelegate {
    static let shared = AirPlayRoutePickerDelegate()
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        AirPlayMonitor.shared.routePickerDismissed()
    }
}

/// Audio route chip (Logan 2026-10-07, round 2). iOS cannot deselect an
/// AirPlay audio output, so after the user ended AirPlay (the card's X
/// latch, 0d61b58) a channel playing here still sends its audio to the
/// receiver. While the latch is set and the route's output is still
/// AirPlay, the local fullscreen player shows this chip at the top; a tap
/// opens the system route picker, the X hides it for that receiver, and it
/// goes away once the route leaves AirPlay.
struct AirPlayAudioRouteChip: View {
    @State private var device: (name: String, uid: String)?
    @State private var dismissedUID: String?
    @State private var loggedUID: String?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let device, device.uid != dismissedUID {
                HStack(spacing: 10) {
                    Button {
                        debugLog("[AVP-AIRPLAY] audio route chip tapped: presenting the route picker")
                        AirPlayMenuTrigger.present()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "airplayaudio")
                                .font(.system(size: 14, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                                .foregroundStyle(ThemeManager.shared.accent)
                            Text("Audio is on \(device.name). Switch to \(Self.deviceWord)")
                                .scaledFont(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        dismissedUID = device.uid
                        debugLog("[AVP-AIRPLAY] audio route chip dismissed device=\(device.name)")
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))  // glyph in a fixed box: not text, stays fixed
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .transition(.opacity)
                .onAppear {
                    guard loggedUID != device.uid else { return }
                    loggedUID = device.uid
                    debugLog("[AVP-AIRPLAY] audio route chip shown device=\(device.name)")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: device?.uid)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private static var deviceWord: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func refresh() {
        let latched = AirPlayMonitor.shared.userEndedRouteUID != nil
        guard latched, let out = AirPlayReceiverResolver.currentAirPlayOutput() else {
            if device != nil { device = nil }
            loggedUID = nil
            return
        }
        let name = (out.name ?? "AirPlay").trimmingCharacters(in: .whitespaces)
        if device?.uid != out.uid || device?.name != name { device = (name, out.uid) }
    }
}
#endif
