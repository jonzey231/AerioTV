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
                try configureCategory()
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
            #if os(iOS)
            // Incident 2026-09-25 (cast suspended in the background): a
            // background keepalive holder needs the session ACTIVE for the
            // whole cast. Its own reference cannot reach this line, so a
            // 1->0 here while holders exist is someone else's unbalanced
            // decrement consuming it; deactivating would let iOS suspend
            // the process under the receiver. Keep the session, restore
            // the count, and say who did it.
            if BackgroundKeepalive.hasHolders {
                count = 1
                debugLog("[KEEPALIVE] refcount hit 0 (caller=\(caller)) while keepalive holders "
                    + "\(BackgroundKeepalive.currentHolders.joined(separator: ",")) need the session: "
                    + "NOT deactivating (unbalanced decrement)")
                return
            }
            #endif
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

    /// The app's playback category (also re-applied by BackgroundKeepalive
    /// after a media-services reset, which drops it; 2026-09-25).
    static func configureCategory() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
        #else
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
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

    // Incident 2026-09-25 (cast freeze after an ingest splice): the engine
    // start/stop and the AVAudioSession activation used to run INSIDE
    // `queue.sync`, so any caller (the cast proxy's session queue, main via
    // `currentHolders`) waited on AVFoundation, and a route-change / config
    // notification delivered on that same thread that read `currentHolders`
    // would dispatch_sync onto the queue it already owned. Now the holder
    // set sits behind a plain lock (held for set operations only) and every
    // AVFoundation call runs asynchronously, in order, on `engineQueue`.
    //
    // Same incident, the actual failure: the phone was backgrounded at
    // 14:01:56 with the engine "running (+cast-hls-proxy)" since 13:55:24,
    // and iOS suspended the process at ~14:04:11 anyway (sockets defunct on
    // the brief resume at 14:04:14, then silence). A silent engine keeps
    // the process scheduled only while it is RUNNING, and AVAudioEngine
    // stops itself on a configuration change (route change, sample-rate
    // change), an interruption (another app's audio, a call, Siri) or a
    // media-services reset, and nothing restarted it. The observers below
    // restart it while holders exist and log every transition.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var holders: Set<String> = []
    /// Everything below is touched only on `engineQueue`.
    private static let engineQueue = DispatchQueue(label: "app.molinete.aerio.background.keepalive")
    private nonisolated(unsafe) static var engine: AVAudioEngine?
    private nonisolated(unsafe) static var observersInstalled = false

    /// True while any pipeline holds the keepalive (lock only, never waits
    /// on AVFoundation, safe from any queue).
    static var hasHolders: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !holders.isEmpty
    }

    /// Add `holder`. No-op when it already holds the engine. Never blocks
    /// on AVFoundation: the engine starts asynchronously.
    static func acquire(_ holder: String) {
        lock.lock()
        let inserted = holders.insert(holder).inserted
        lock.unlock()
        guard inserted else { return }
        engineQueue.async {
            installObserversIfNeeded()
            AudioSessionRefCount.increment(caller: holder)
            // Released again before this block ran: the release block
            // queued behind us balances the refcount; no engine needed.
            guard hasHolders else { return }
            if ensureEngineRunning(reason: "+\(holder)") {
                debugLog("[KEEPALIVE] background keepalive engine running (+\(holder))")
            }
        }
    }

    /// Current holders, sorted (the AirPlay background-entry line names them).
    static var currentHolders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return holders.sorted()
    }

    /// Drop `holder`; the engine stops when no holder is left. Never
    /// blocks on AVFoundation: the engine stops asynchronously.
    static func release(_ holder: String) {
        lock.lock()
        let removed = holders.remove(holder) != nil
        let remaining = holders.sorted()
        lock.unlock()
        guard removed else { return }
        engineQueue.async {
            if !hasHolders {
                if let e = engine {
                    e.stop()
                    engine = nil
                    debugLog("[KEEPALIVE] background keepalive engine stopped (-\(holder))")
                }
            } else {
                debugLog("[KEEPALIVE] background keepalive holder released (-\(holder)), "
                    + "still held by \(remaining.joined(separator: ","))")
            }
            AudioSessionRefCount.decrement(caller: holder)
        }
    }

    /// Build (if needed) and start the engine. engineQueue only. Returns
    /// true when the engine is running afterwards.
    @discardableResult
    private static func ensureEngineRunning(reason: String) -> Bool {
        if let e = engine, e.isRunning { return true }
        let e: AVAudioEngine
        if let existing = engine {
            e = existing
        } else {
            e = AVAudioEngine()
            // The engine must have a source attached for some route
            // configurations to start; a player node with nothing
            // scheduled renders silence.
            let player = AVAudioPlayerNode()
            e.attach(player)
            e.connect(player, to: e.mainMixerNode, format: nil)
            e.mainMixerNode.outputVolume = 0
            engine = e
        }
        do {
            try e.start()
            return true
        } catch {
            // Backgrounding will then suspend the holder's pipeline;
            // surfaced so the field log explains a frozen receiver.
            debugLog("[KEEPALIVE] background keepalive engine FAILED (\(reason)): \(error) "
                + sessionStateText())
            return false
        }
    }

    /// Engine and session state for the log (engineQueue, or any thread
    /// for the read-only parts).
    private static func sessionStateText() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
            + "options=\(session.categoryOptions.rawValue) otherAudio=\(session.isOtherAudioPlaying) "
            + "silenceHint=\(session.secondaryAudioShouldBeSilencedHint) "
            + "rate=\(Int(session.sampleRate)) route=[\(outputs)]"
    }

    /// One line for the app's background entry: who holds the keepalive,
    /// whether the engine is actually rendering, and the session state
    /// iOS judges background audio by. Non-blocking for the caller.
    static func logBackgroundEntry() {
        let holdersNow = currentHolders
        engineQueue.async {
            let running = engine?.isRunning ?? false
            debugLog("[KEEPALIVE] background entry: holders=[\(holdersNow.joined(separator: ","))] "
                + "engine=\(engine == nil ? "none" : (running ? "running" : "STOPPED")) "
                + sessionStateText())
            if !holdersNow.isEmpty, !running {
                if ensureEngineRunning(reason: "background entry") {
                    debugLog("[KEEPALIVE] engine restarted on background entry")
                }
            }
        }
    }

    /// Restart the engine after something stopped it, while holders exist.
    private static func restartIfHeld(_ why: String, reactivate: Bool) {
        engineQueue.async {
            guard hasHolders else { return }
            let wasRunning = engine?.isRunning ?? false
            if reactivate {
                do {
                    if why == "media services reset" { try AudioSessionRefCount.configureCategory() }
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    debugLog("[KEEPALIVE] \(why): session reactivation FAILED: \(error) " + sessionStateText())
                }
            }
            guard !wasRunning else {
                debugLog("[KEEPALIVE] \(why): engine still running")
                return
            }
            if ensureEngineRunning(reason: why) {
                debugLog("[KEEPALIVE] \(why): engine restarted (holders=\(currentHolders.joined(separator: ",")))")
            }
        }
    }

    /// engineQueue only; installed on the first acquire, never removed.
    private static func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default
        // Every handler hops ASYNC to engineQueue: a notification can be
        // delivered on the thread that is inside an AVFoundation call.
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { note in
            guard let e = note.object as? AVAudioEngine else { return }
            engineQueue.async {
                guard e === engine else { return }
                debugLog("[KEEPALIVE] engine configuration change (engine stopped by AVFoundation)")
                restartIfHeld("configuration change", reactivate: false)
            }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            switch type {
            case .began:
                debugLog("[KEEPALIVE] audio session interruption BEGAN (holders=\(currentHolders.joined(separator: ",")))")
            case .ended:
                debugLog("[KEEPALIVE] audio session interruption ended")
                restartIfHeld("interruption ended", reactivate: true)
            default:
                break
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
            guard hasHolders else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            debugLog("[KEEPALIVE] route change reason=\(reason)")
            restartIfHeld("route change", reactivate: false)
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            engineQueue.async {
                debugLog("[KEEPALIVE] media services were reset; rebuilding the engine")
                engine?.stop()
                engine = nil
            }
            restartIfHeld("media services reset", reactivate: true)
        }
    }
}
#endif
