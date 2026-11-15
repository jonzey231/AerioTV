// Mid-play AirPlay handover hold tests (device pass 2026-11-14: picking
// AirPlay mid-play paused the player). The tile's loopback item must not go
// external while the LAN item is prepared; external playback comes back on
// with the LAN item and for every outcome that does not hand over.

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL \(line): \(msg)") }
}

/// A stand-in for the tile's player and AirPlayMonitor, driven by the same
/// rules AirPlayTileDelivery runs.
struct Sim {
    var hold = AirPlayMidPlayHold()
    var allowsExternal = true
    var playing = true
    var userPaused = false

    mutating func beginMidPlay(_ t: UUID) {
        hold.begin(t)
        allowsExternal = false
        // AVFoundation drops the rate when an item it cannot hand over
        // went external first.
        playing = false
    }
    /// AirPlayMonitor.reenableExternalPlaybackForRoute on a route update.
    mutating func routeUpdate() {
        if AirPlayMidPlayHold.routeMayReenable(held: hold.isHeld) { allowsExternal = true }
    }
    mutating func outcome(_ t: UUID, swapped: Bool) {
        if hold.end(t) { allowsExternal = true }
        if swapped, AirPlayMidPlayHold.resumesAfterSwap(userPaused: userPaused) { playing = true }
    }
    mutating func reset() {
        if hold.clear() { allowsExternal = true }
    }
}

// MARK: The handover from the device pass

do {
    var s = Sim()
    let t = UUID()
    s.beginMidPlay(t)
    check(!s.allowsExternal, "the loopback item is held on this device while the LAN is prepared")
    s.routeUpdate()
    check(!s.allowsExternal, "a route update during the preparation does not undo the hold")
    s.outcome(t, swapped: true)
    check(s.allowsExternal, "external playback is back on with the LAN item")
    check(s.playing, "the player resumes after the swap (the pause no longer sticks)")
    check(!s.hold.isHeld, "the hold is over")
    s.routeUpdate()
    check(s.allowsExternal, "route updates behave as before once the hold ends")
}

do {
    var s = Sim()
    s.userPaused = true
    let t = UUID()
    s.beginMidPlay(t)
    s.outcome(t, swapped: true)
    check(s.allowsExternal, "a paused tile still gets external playback back")
    check(!s.playing, "but stays paused: the user paused it")
}

// MARK: Every outcome that does not hand over turns external playback back on

for name in ["no LAN address", "LAN delivery unavailable", "audio-only receiver", "handover superseded"] {
    var s = Sim()
    let t = UUID()
    s.beginMidPlay(t)
    s.outcome(t, swapped: false)
    check(s.allowsExternal, "\(name): external playback back on")
    check(!s.hold.isHeld, "\(name): no hold left")
}

// MARK: Tokens

do {
    var hold = AirPlayMidPlayHold()
    let t = UUID()
    check(!hold.end(t), "nothing held: an outcome releases nothing")
    hold.begin(t)
    check(hold.end(t), "the holder's outcome releases")
    check(!hold.end(t), "a second outcome for the same handover releases nothing")
}

do {
    // A teardown during the preparation, then a new handover on the same
    // delivery before the first one's task wakes up.
    var s = Sim()
    let old = UUID(), new = UUID()
    s.beginMidPlay(old)
    s.reset()
    check(s.allowsExternal, "a reset mid-preparation leaves no player stuck on this device")
    s.beginMidPlay(new)
    s.outcome(old, swapped: false)
    check(!s.allowsExternal, "the stale handover does not release the newer one's hold")
    check(s.hold.isHeld, "the newer handover still holds")
    s.outcome(new, swapped: true)
    check(s.allowsExternal, "the newer handover releases its own hold")
}

do {
    var hold = AirPlayMidPlayHold()
    check(!hold.clear(), "a reset with nothing held reports nothing")
    check(AirPlayMidPlayHold.routeMayReenable(held: false), "the monitor re-enables a player nothing holds")
    check(!AirPlayMidPlayHold.routeMayReenable(held: true), "the monitor leaves a held player alone")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
