#if canImport(UIKit)
import UIKit

/// Serialised reference counter for `UIApplication.isIdleTimerDisabled`.
///
/// Multiple `MPVPlayerView.Coordinator` instances running concurrently
/// (multiview, PiP + main player, etc.) each want to keep the idle
/// timer disabled while their stream is playing. The idle timer is a
/// process-global boolean: if player A tears down and re-enables the
/// idle timer while player B is still running, the device will
/// screensaver / sleep mid-playback.
///
/// This refcount guards the `isIdleTimerDisabled` flag so it's set to
/// `true` only on 0→1 and back to `false` only on N→0. The whole
/// enum is `@MainActor` because `UIApplication` is main-thread-only
/// anyway, which also satisfies Swift 6 strict concurrency checks
/// around the shared `count` static.
@MainActor
enum IdleTimerRefCount {

    // MARK: - State

    private static var count: Int = 0

    // MARK: - Public API

    /// Increment. On 0→1 sets `isIdleTimerDisabled = true`.
    static func increment() {
        count += 1
        if count == 1 {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    /// Decrement. On 1→0 sets `isIdleTimerDisabled = false`.
    /// Clamped at 0.
    static func decrement() {
        guard count > 0 else {
            NSLog("IdleTimerRefCount.decrement: over-decrement (count already 0)")
            return
        }
        count -= 1
        if count == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    #if DEBUG
    /// Tests only. DEBUG-gated so release builds don't ship it.
    static func _resetForTesting() { count = 0 }

    /// Tests only. DEBUG-gated.
    static var _currentCount: Int { count }
    #endif
}
#endif
