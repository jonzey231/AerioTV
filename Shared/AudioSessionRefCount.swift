import Foundation
import AVFoundation

/// Serialised reference counter for `AVAudioSession.setActive(...)`.
///
/// Multiple `MPVPlayerView.Coordinator` instances each manage their own
/// mpv handle. They all need the shared `AVAudioSession` active, but
/// the session is a process-global singleton — each coordinator calling
/// `setActive(true/false)` on init / teardown races when two or more
/// players are alive at once. Symptoms:
/// - Audio silently goes away when the first coordinator teardown
///   races ahead of a second coordinator that's still playing.
/// - Deadlocks / `AVAudioSessionErrorCode.cannotInterruptOthers` on
///   rapid channel changes.
///
/// This refcount guards the transition so `setActive(true)` runs only on
/// 0→1 and `setActive(false)` runs only on N→0. All N intermediate
/// increments/decrements are cheap no-ops.
///
/// Both the count mutation and the `setActive(...)` call are serialised
/// on a private queue so a pair of increment/decrement calls arriving
/// on different threads can't interleave and leave the session in the
/// wrong state. The `setActive` call itself is synchronous — it's a
/// short blocking call on iOS so holding the queue for its duration
/// is acceptable.
enum AudioSessionRefCount {

    // MARK: - State

    private static let queue = DispatchQueue(label: "app.molinete.aerio.audiosession.refcount")
    private nonisolated(unsafe) static var count: Int = 0

    // MARK: - Public API

    /// Increment the count. If this raises the count from 0 to 1,
    /// activates the shared `AVAudioSession`. Otherwise no-op.
    /// Safe to call from any thread.
    static func increment() {
        queue.sync {
            count += 1
            guard count == 1 else { return }
            do {
                #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(
                    .playback,
                    mode: .moviePlayback,
                    options: [.allowAirPlay, .allowBluetoothA2DP]
                )
                #else
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                #endif
                try AVAudioSession.sharedInstance().setActive(true)
                // Landed 0→1 — good entry-point to attribute audio
                // regressions (wrong category, deactivation bounce).
                NSLog("[MV-Audio] session activated (refcount 0→1)")
            } catch {
                // Intentionally swallowed — this mirrors the existing
                // inline behavior in MPVPlayerView.swift:91-102. The
                // session activation can fail in background / weird
                // states; we let mpv try to play anyway.
                NSLog("AudioSessionRefCount.increment: setActive(true) failed: \(error)")
            }
        }
    }

    /// Decrement the count. If this drops the count from 1 to 0,
    /// deactivates the shared `AVAudioSession` (with notify-others so
    /// any paused apps can resume). Otherwise no-op. Safe to call
    /// from any thread. Never drops below 0.
    static func decrement() {
        queue.sync {
            guard count > 0 else {
                NSLog("AudioSessionRefCount.decrement: over-decrement (count already 0)")
                return
            }
            count -= 1
            guard count == 0 else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
                NSLog("[MV-Audio] session deactivated (refcount →0)")
            } catch {
                // Same tolerance as increment — log and move on.
                NSLog("AudioSessionRefCount.decrement: setActive(false) failed: \(error)")
            }
        }
    }

    #if DEBUG
    /// For tests: reset the counter without touching `setActive`. Never
    /// call from production code — the session state would go out of
    /// sync with the ref count. DEBUG-only so the release binary
    /// doesn't ship a footgun.
    static func _resetForTesting() {
        queue.sync { count = 0 }
    }

    /// For tests: peek the current count. DEBUG-only.
    static var _currentCount: Int {
        queue.sync { count }
    }
    #endif
}
