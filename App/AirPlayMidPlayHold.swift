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

    /// A mid-play pick re-tunes the live tile with the route up (the
    /// fresh-tune handover) unless the user paused it (the in-place swap
    /// keeps the pause) or the receiver is an audio-only speaker (no
    /// picture to hand over; the local player keeps it).
    static func rebuildsForPick(userPaused: Bool, audioOnlyReceiver: Bool) -> Bool {
        !userPaused && !audioOnlyReceiver
    }

    /// After the swap to the LAN item: play unless the user paused.
    static func resumesAfterSwap(userPaused: Bool) -> Bool { !userPaused }

    /// AirPlayMonitor's route-driven re-enable stays away from a held player.
    static func routeMayReenable(held: Bool) -> Bool { !held }

    /// The live driver may re-time an item (write
    /// configuredTimeOffsetFromLive) only when it is the remuxer's loopback
    /// item. An AirPlay LAN item must carry no configured offset: the
    /// receiver starts at the playlist's default point and the LAN
    /// publication delay sets its distance from the edge. The fresh-tune
    /// path never wires the driver for a LAN item, but a mid-play swap puts
    /// one under a driver wired for the loopback item, and inside the
    /// tune's first 30 s the driver raised its join offset (device pass
    /// 2026-11-14 22:51:16.612, "join offset raised to 8.3s" 2 ms after the
    /// swap); the Roku then read the playlist once and AirPlay ended.
    /// Every quick pick that waited for segments failed this way, every
    /// pick after 30 s worked.
    static func driverMayRetime(itemURL: URL?) -> Bool {
        guard let host = itemURL?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
