import Foundation

/// Pure decisions for the live resume gate in AVPlayerProgressDriver
/// (PlayerView.swift): whether a buffer underrun may hold playback, when a
/// running hold must end, and what the chrome and Now Playing show while it
/// holds. No app singletons, so Scripts/cast-hls-proxy-tests compiles it.
///
/// Measured 2026-11-07 on the Streamer (Android, same gate design): three
/// holds in three minutes (13.5 s, 15.5 s, and 6.1 s) read as Pause in the
/// chrome, and one was a repeat-stall hold armed on a feed at 0.68x real
/// time, which never refills the cushion. Two more released onto a buffer
/// that an upstream switch was about to drop, and froze again 1 s later.
enum ResumeGatePolicy {

    /// Feed media seconds per wall second below which a hold cannot win.
    static let mediaRatioMin = 0.9

    /// How long a running hold may sit on a starved feed before letting go.
    static let starvedReleaseAfter: TimeInterval = 3

    /// An upstream source switch keeps its window open this long after the
    /// last switch mark (switch detected, or the new source's first segment).
    static let switchWindow: TimeInterval = 10

    enum Release: Equatable { case targetReached, feedStarved, timeout }

    enum ArmDecision: Equatable {
        /// Hold until the target is buffered.
        case arm
        /// Buffer already at the target (or no target): no hold.
        case notNeeded
        /// Feed below real time: a hold is just a pause until the fuse.
        case skipSlowFeed(ratio: Double)
        /// Upstream switch in progress: defer, then hold once to the full
        /// target after the last switch.
        case deferForSwitch
    }

    /// True while an upstream switch window is open.
    static func switchWindowOpen(secondsSinceSwitch: TimeInterval?) -> Bool {
        guard let s = secondsSinceSwitch else { return false }
        return s >= 0 && s < switchWindow
    }

    /// Whether a stall may start a hold. `repeat` stays in the signature so
    /// the repeat-stall path runs the same rate check as a first stall; it
    /// no longer bypasses it. A nil ratio (not yet measured) may hold.
    static func shouldArm(ahead: Double, target: Double, ratio: Double?,
                          repeat: Bool, switchOpen: Bool = false) -> ArmDecision {
        if switchOpen { return .deferForSwitch }
        if target <= 0 || ahead >= target { return .notNeeded }
        if let ratio, ratio < mediaRatioMin { return .skipSlowFeed(ratio: ratio) }
        return .arm
    }

    /// Release reason for a running hold on this tick, or nil to keep
    /// holding. A hold never releases while a switch window is open (the
    /// buffer it would play is about to be dropped); the fuse still blows.
    static func releaseOnTick(ahead: Double, target: Double, ratio: Double?,
                              held: TimeInterval, timeout: TimeInterval,
                              switchOpen: Bool = false) -> Release? {
        if held >= timeout { return .timeout }
        if switchOpen { return nil }
        if ahead >= target { return .targetReached }
        if let ratio, ratio < mediaRatioMin, held >= starvedReleaseAfter { return .feedStarved }
        return nil
    }

    /// A target never shrinks while a switch window is open.
    static func nextTarget(current: Double, proposed: Double, switchOpen: Bool) -> Double {
        switchOpen ? max(current, proposed) : proposed
    }

    /// What the chrome and Now Playing show: the viewer still wants to play
    /// during a hold, so it reads as buffering, never as paused.
    static func wantsToPlay(playerRunning: Bool, gateHolding: Bool, audioOnlyHolding: Bool) -> Bool {
        playerRunning || gateHolding || audioOnlyHolding
    }

    /// A viewer pause during a hold ends the hold quietly, so its release
    /// can never un-pause the viewer.
    static func endHoldForViewerPause(userPaused: Bool, holding: Bool) -> Bool {
        userPaused && holding
    }
}
