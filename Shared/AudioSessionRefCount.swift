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
    ///
    /// `caller` is an optional string attributing the call to a
    /// specific tile / entry-point. Gets logged verbatim. Pass
    /// something short and stable — e.g. `"tile=ABC"` or
    /// `"enterMultiview-float"` — so the log trail tells us
    /// exactly which path raised the refcount when we're debugging
    /// audio-session deadlocks or the "2nd tile won't open"
    /// puzzle.
    static func increment(caller: String = "unknown") {
        queue.sync {
            let before = count
            count += 1
            let after = count
            NSLog("[MV-Audio] refcount inc \(before)→\(after) caller=\(caller)")
            guard after == 1 else { return }
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
                // Pin the hardware rate BEFORE activation: a fresh
                // activation otherwise negotiates whatever the system
                // offers, and an ATV+receiver chain that came up at
                // 44100Hz played SILENCE while every mpv diagnostic
                // read healthy (catch-up field capture: live session
                // 48000Hz/6ch audible, catch-up session 44100Hz/2ch
                // silent, ao=NONE at the activation route-change).
                // 48kHz is the HDMI/broadcast standard and what every
                // live session on this box negotiates.
                try? AVAudioSession.sharedInstance().setPreferredSampleRate(48_000)
                try AVAudioSession.sharedInstance().setActive(true)
                // Landed 0→1 — good entry-point to attribute audio
                // regressions (wrong category, deactivation bounce).
                NSLog("[MV-Audio] session activated (refcount 0→1) caller=\(caller)")
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
    static func decrement(caller: String = "unknown") {
        queue.sync {
            guard count > 0 else {
                NSLog("[MV-Audio] refcount over-decrement (count already 0) caller=\(caller)")
                return
            }
            let before = count
            count -= 1
            let after = count
            NSLog("[MV-Audio] refcount dec \(before)→\(after) caller=\(caller)")
            guard after == 0 else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
                NSLog("[MV-Audio] session deactivated (refcount →0) caller=\(caller)")
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

#if os(iOS)
/// One silent AVAudioEngine shared by every pipeline that must keep the
/// process scheduled while the phone is pocketed and something else (a
/// Chromecast, an AirPlay receiver) is being served from it.
///
/// A configured-but-silent audio session is NOT enough: iOS suspends a
/// backgrounded process that renders no audio, which froze the receiver
/// mid-cast within minutes (device-verified 2026-08-13, iPhone 17 Pro
/// Max: proxy port unreachable after backgrounding while the TV starved).
/// Only an ACTIVE render keeps the process scheduled, so the engine runs
/// a player node with nothing scheduled into a muted main mixer.
///
/// Holders are named ("cast-hls-proxy", ...) so the log says which
/// pipeline raised or dropped the engine. Each holder also holds one
/// `AudioSessionRefCount` reference for its lifetime. The engine starts
/// with the first holder and stops with the last one.
enum BackgroundKeepalive {

    private static let queue = DispatchQueue(label: "app.molinete.aerio.background.keepalive")
    private nonisolated(unsafe) static var holders: Set<String> = []
    private nonisolated(unsafe) static var engine: AVAudioEngine?

    /// Add `holder`. No-op when it already holds the engine.
    static func acquire(_ holder: String) {
        queue.sync {
            guard holders.insert(holder).inserted else { return }
            AudioSessionRefCount.increment(caller: holder)
            if engine == nil {
                let newEngine = AVAudioEngine()
                // The engine must have a source attached for some route
                // configurations to start; a player node with nothing
                // scheduled renders silence.
                let player = AVAudioPlayerNode()
                newEngine.attach(player)
                newEngine.connect(player, to: newEngine.mainMixerNode, format: nil)
                newEngine.mainMixerNode.outputVolume = 0
                do {
                    try newEngine.start()
                    engine = newEngine
                } catch {
                    // Backgrounding will then suspend the holder's
                    // pipeline; surfaced so the field log explains a
                    // frozen receiver.
                    debugLog("[KEEPALIVE] background keepalive engine FAILED (+\(holder)): \(error)")
                    return
                }
            }
            debugLog("[KEEPALIVE] background keepalive engine running (+\(holder))")
        }
    }

    /// Current holders, sorted (the AirPlay background-entry line names them).
    static var currentHolders: [String] {
        queue.sync { holders.sorted() }
    }

    /// Drop `holder`; the engine stops when no holder is left.
    static func release(_ holder: String) {
        queue.sync {
            guard holders.remove(holder) != nil else { return }
            if holders.isEmpty {
                engine?.stop()
                engine = nil
                debugLog("[KEEPALIVE] background keepalive engine stopped (-\(holder))")
            } else {
                debugLog("[KEEPALIVE] background keepalive holder released (-\(holder)), "
                    + "still held by \(holders.sorted().joined(separator: ","))")
            }
            AudioSessionRefCount.decrement(caller: holder)
        }
    }
}
#endif
