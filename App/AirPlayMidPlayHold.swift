import Foundation

/// Mid-play AirPlay handover (device pass 2026-11-14): an AirPlay receiver
/// picked while a live tile plays on this device. The tile's item is the
/// remuxer's LOOPBACK playlist (http://127.0.0.1:<port>/live.m3u8), which a
/// receiver cannot reach; letting that item go external makes AVFoundation
/// drop the rate to 0, and the Apple TV froze on its first frame while the
/// Roku ended the session. So, as on the fresh-tune path (whose first item
/// is already the LAN one), external playback stays OFF until the LAN item
/// is in, then goes back on and the player resumes unless the user paused.
/// Every outcome that does not hand over turns it back on too.
///
/// The hold belongs to one handover (its token): a handover that finishes
/// after a newer one began never releases the newer one's hold.
///
/// Pure logic, compiled by Scripts/airplay-midplay-tests.
struct AirPlayMidPlayHold: Equatable, Sendable {
    /// The handover holding external playback off, nil when none.
    private(set) var holder: UUID?

    var isHeld: Bool { holder != nil }

    /// A mid-play handover starts: external playback goes off.
    mutating func begin(_ token: UUID) { holder = token }

    /// The handover `token` reached an outcome (LAN item in, no LAN
    /// address, LAN unavailable, audio-only receiver, or superseded). True
    /// when that ends the hold, so external playback goes back on; false
    /// when nothing or a newer handover holds it.
    mutating func end(_ token: UUID) -> Bool {
        guard holder == token else { return false }
        holder = nil
        return true
    }

    /// The delivery is torn down (reset): any hold ends, so the player it
    /// leaves behind is not stuck local. True when one was held.
    mutating func clear() -> Bool {
        defer { holder = nil }
        return holder != nil
    }

    /// After the swap to the LAN item: play unless the user paused.
    static func resumesAfterSwap(userPaused: Bool) -> Bool { !userPaused }

    /// AirPlayMonitor's route-driven re-enable stays away from a held player.
    static func routeMayReenable(held: Bool) -> Bool { !held }
}
