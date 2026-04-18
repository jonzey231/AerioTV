import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Runtime diagnostics for the playback pipeline — timing budgets,
/// main-actor hop tracking, memory-warning hooks, and a heavyweight
/// "something's seriously wrong" snapshot.
///
/// This is read-only observation. Nothing here influences playback
/// behaviour. The goal is to catch the kind of slow-burn resource
/// pressure that manifests as "2nd mpv tile fails to open,"
/// "fullScreenCover doesn't present," "1.5-6s main-thread hangs
/// during view swap" before the user reports them as "the app
/// crashed." Every signal surfaces to `DebugLogger` (visible in
/// release feedback reports) and DEBUG `print` for attached-device
/// developer loops.
///
/// Call it from both the mpv Coordinator (timing budgets) and the
/// `MainThreadWatchdog` (memory / hang-snapshot).
enum PlaybackDiagnostics {

    // MARK: - Timing budgets
    //
    // `reportSetupTiming` / `reportFirstFrame` are called by the
    // mpv Coordinator in Phase C.6 once we instrument `setupMPV`
    // and `handleFileLoaded`. They're public now so the API is
    // available to callers once they land; nobody calls them yet.
    // TODO(C.6): wire from `MPVPlayerView.Coordinator.setupMPV`
    //            (line ~1277 `[MV-TIMING]` log) — replace that log
    //            with reportSetupTiming + optional reportFirstFrame
    //            on the audio-reconfig event.

    /// Threshold at which a setupMPV call is noisy. Typical on a
    /// warm device is ~50ms (options-only) + ~2s (mpv_initialize) =
    /// ~2s total. The 1500ms budget covers the options + handle
    /// creation portion; the separate `mpvInitBudgetMs` covers init.
    /// If either trips, log a warning with the process summary so
    /// we can correlate with resource pressure.
    static let setupBudgetMs: Int = 1500
    static let mpvInitBudgetMs: Int = 500
    static let firstFrameBudgetMs: Int = 8000

    /// Called at the end of `MPVPlayerView.Coordinator.setupMPV`.
    /// `totalMs` is the entire function runtime; `initMs` is just
    /// `mpv_initialize`. Logs a warning for each budget that was
    /// exceeded, with the process summary attached so we can
    /// correlate slow setup to memory / FD / thermal pressure.
    static func reportSetupTiming(tileID: String, totalMs: Int, initMs: Int) {
        if totalMs > setupBudgetMs {
            DebugLogger.shared.log(
                "[PlaybackDiag] ⚠️ setupMPV SLOW tile=\(tileID) total=\(totalMs)ms (budget \(setupBudgetMs)ms) \(ProcessMetrics.summaryLine())",
                category: "Playback", level: .warning
            )
        }
        if initMs > mpvInitBudgetMs {
            DebugLogger.shared.log(
                "[PlaybackDiag] ⚠️ mpv_initialize SLOW tile=\(tileID) init=\(initMs)ms (budget \(mpvInitBudgetMs)ms) \(ProcessMetrics.summaryLine())",
                category: "Playback", level: .warning
            )
        }
    }

    /// Called when the first decoded frame renders. `msFromSetupStart`
    /// is the delta from `setupMPV` begin; the typical live-stream
    /// range is 1500-7000ms depending on thermal state. Past the
    /// 8000ms budget we suspect upstream network / HDCP negotiation
    /// issues and log for correlation.
    static func reportFirstFrame(tileID: String, msFromSetupStart: Int) {
        if msFromSetupStart > firstFrameBudgetMs {
            DebugLogger.shared.log(
                "[PlaybackDiag] ⚠️ first frame SLOW tile=\(tileID) delta=\(msFromSetupStart)ms (budget \(firstFrameBudgetMs)ms) \(ProcessMetrics.summaryLine())",
                category: "Playback", level: .warning
            )
        }
    }

    // MARK: - Main-actor hop tracking
    //
    // `hopIn()` / `hopOut()` / `mainHopsInflight` are called by
    // the mpv Coordinator's event-loop hops in Phase C.6. Nobody
    // calls them yet; the counter stays at 0 and the snapshot
    // logs `mainHopsInflight=0`. That's fine — the infrastructure
    // is ready so C.6 can drop in `defer { hopOut() }` without
    // another file change.
    // TODO(C.6): wrap every `Task { @MainActor in ... }` spawned
    //            from the mpv Coordinator's callbacks with
    //            `hopIn()` / `defer { hopOut() }`.
    /// mpv Coordinator callbacks that are still in-flight. Each
    /// mpv event handler that hops to main for SwiftUI state updates
    /// should `increment()` at the start of the Task body and
    /// `decrement()` in a `defer`. If this number grows without
    /// bound, main is starved — the watchdog surfaces it.
    ///
    /// Atomic via a DispatchQueue rather than a Swift `Mutex` so the
    /// increment/decrement calls can come from any thread (which is
    /// the whole point — mpv fires events from its own queue, and
    /// the hop to main is what this counter tracks).
    private static let hopQueue = DispatchQueue(label: "app.molinete.aerio.playbackdiag.hop")
    private nonisolated(unsafe) static var _hopsInflight: Int = 0

    /// Current in-flight main-actor hop count. Read-only peek for
    /// the watchdog; do not use as a synchronisation primitive.
    static var mainHopsInflight: Int {
        hopQueue.sync { _hopsInflight }
    }

    /// Call at the start of a main-actor hop body that originates
    /// from a mpv Coordinator callback.
    static func hopIn() {
        hopQueue.sync { _hopsInflight += 1 }
    }

    /// Call in a `defer` at the start of a main-actor hop body.
    static func hopOut() {
        hopQueue.sync { _hopsInflight = max(0, _hopsInflight - 1) }
    }

    // MARK: - Memory warning hook

    #if canImport(UIKit)
    /// Idempotency guard — the hook-install call site is
    /// `AerioApp.AppEntryView.onAppear` which fires on every
    /// scene re-mount. Without the guard a dozen observers pile
    /// up over a long-running session and each memory warning
    /// triggers a dozen duplicate log lines. The guard is
    /// single-threaded (main-actor) because `onAppear` runs on
    /// main.
    @MainActor private static var memoryHookInstalled = false

    /// Subscriber that logs a rich snapshot on iOS
    /// `UIApplication.didReceiveMemoryWarningNotification`. Install
    /// once at app startup; survives the app lifetime. Subsequent
    /// calls are no-ops (see `memoryHookInstalled`).
    ///
    /// When memory pressure fires we want to know exactly how many
    /// tiles are alive, what the audio session refcount is, and the
    /// process-wide resource state. That gives us the minimum data
    /// to decide whether to (a) pause non-audio tiles, (b) eject
    /// the oldest tile, (c) show a "close some streams" banner.
    /// Phase C doesn't yet act on memory pressure — it just logs.
    @MainActor
    static func installMemoryWarningHook() {
        guard !memoryHookInstalled else { return }
        memoryHookInstalled = true
        // Observer-token discard is intentional — this hook lives for
        // the full app lifetime and `UIApplication.shared` outlives
        // the observer (no dangling-reference risk). Duplicate
        // installs are caught by `memoryHookInstalled` above.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let tiles = MultiviewStore.shared.tiles.count
                let audioID = MultiviewStore.shared.audioTileID ?? "nil"
                DebugLogger.shared.log(
                    "[PlaybackDiag] 💥 memory warning tiles=\(tiles) audioTile=\(audioID) \(ProcessMetrics.summaryLine()) mainHops=\(mainHopsInflight)",
                    category: "Playback", level: .warning
                )
            }
        }
    }
    #endif

    // MARK: - Heavyweight snapshot

    /// Emits a dense multi-line `[SNAPSHOT]`-prefixed log containing
    /// everything we'd want to see if a user reports "the app
    /// crashed when I added a tile." Called by the watchdog on
    /// a main-thread hang >2s during an add-tile window, or
    /// manually from DEBUG code paths.
    ///
    /// Explicitly does NOT crash or abort. The point is observation,
    /// not enforcement.
    @MainActor
    static func captureSnapshot(reason: String) {
        let tiles = MultiviewStore.shared.tiles
        let audioID = MultiviewStore.shared.audioTileID ?? "nil"
        let mode = String(describing: PlayerSession.shared.mode)

        var lines: [String] = []
        lines.append("[SNAPSHOT] reason=\(reason)")
        lines.append("[SNAPSHOT] \(ProcessMetrics.summaryLine())")
        lines.append("[SNAPSHOT] mode=\(mode) tiles=\(tiles.count) audioTile=\(audioID) mainHopsInflight=\(mainHopsInflight)")
        for (i, tile) in tiles.enumerated() {
            lines.append("[SNAPSHOT]   tile[\(i)] id=\(tile.id) name=\(tile.item.name)")
        }
        // `isMinimized` currently lives on `NowPlayingManager`; it moves to
        // `PlayerSession` in a later Phase C step. Reading it from the
        // current owner keeps the snapshot accurate during migration.
        lines.append("[SNAPSHOT] isMinimized=\(NowPlayingManager.shared.isMinimized)")

        for line in lines {
            #if DEBUG
            print(line)
            #endif
            DebugLogger.shared.log(
                line, category: "Playback", level: .warning
            )
        }
    }
}
