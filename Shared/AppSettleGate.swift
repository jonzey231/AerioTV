import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Shared "the app has settled" signal for quiet background refresh passes
/// (Logan 2026-09-12).
///
/// The EPG background grid re-sweep established the rule the VOD and DVR
/// passes now follow: cached data paints instantly at launch, and the network
/// refresh only starts once
///
///   1. the guide has rendered (its data load finished), and
///   2. any tune started with the launch is past its first frame, and
///   3. roughly `settleDelay` seconds have passed since launch or since the
///      app came back to the foreground.
///
/// A sweep also has to HOLD STILL mid-run while a tune is between press and
/// first frame, or while the app is not in the foreground. `shouldPause` and
/// `awaitResumeIfPaused()` are that half of the contract.
///
/// The EPG sweep in `Features/LiveTV/EPGGuideView.swift` still carries its own
/// copy of this logic (`backgroundSweepSettleDelay` plus its private
/// `backgroundSweepShouldPause`); it can adopt this gate as-is, which is why
/// the delay constant lives here.
@MainActor
final class AppSettleGate {
    static let shared = AppSettleGate()

    /// How long after launch or a foreground return the app counts as settled.
    /// Matches the EPG sweep's `backgroundSweepSettleDelay`.
    nonisolated static let settleDelay: TimeInterval = 20

    /// Start of the current settle window: process start, then every
    /// foreground return.
    private var windowStart = Date()

    /// Set once the guide's data load has finished for this launch. Until
    /// then no background sweep may start, however long the window has run:
    /// the guide is the screen the user is looking at.
    private var guideRendered = false

    private init() {}

    /// The guide finished loading (channels plus EPG, from cache or network).
    /// Called from the launch orchestrator once its EPG phase ends.
    func noteGuideRendered() {
        guard !guideRendered else { return }
        guideRendered = true
        debugLog("[SETTLE] guide rendered")
    }

    /// The app returned to the foreground: restart the settle window so a
    /// sweep scheduled off this edge waits the same 20 s.
    func noteForegroundReturn() {
        windowStart = Date()
        debugLog("[SETTLE] foreground return; settle window restarted")
    }

    /// True while any background sweep must hold still: a tune is between
    /// press and first frame, or the app is not in the foreground.
    /// MainActor-isolated on purpose: `UIApplication.shared.applicationState`
    /// is main-thread-only, and every caller (the VOD sweep, the DVR refresh)
    /// already runs on the main actor.
    var shouldPause: Bool {
        if TuneTimeline.shared.isTuning { return true }
        #if canImport(UIKit)
        return UIApplication.shared.applicationState != .active
        #else
        return false
        #endif
    }

    /// Waits until the app is settled. Returns as soon as all three
    /// conditions hold; never throws, so a cancelled caller just falls
    /// through and checks `Task.isCancelled` itself.
    func awaitSettled(reason: String) async {
        // The remainder of the settle window, recomputed each pass so a
        // foreground return mid-wait extends it.
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(windowStart)
            let remaining = Self.settleDelay - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(min(remaining, 5)))
                continue
            }
            if !guideRendered || shouldPause {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            debugLog("[SETTLE] settled (\(reason)) after \(Int(elapsed))s")
            return
        }
    }

    /// Mid-sweep hold. Call between units of work (a page, a chunk) so a
    /// channel press or a trip to the background stops the network traffic
    /// without abandoning the sweep's progress.
    func awaitResumeIfPaused() async {
        var held = 0
        while shouldPause, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            held += 5
        }
        if held > 0 {
            debugLog("[SETTLE] background work held \(held)s (tune or background)")
        }
    }
}
