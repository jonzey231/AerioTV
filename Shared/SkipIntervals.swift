import Foundation

/// Settings > App Behaviors > Skip Intervals (Logan 2026-09-14). Two
/// synced keys ("skipBackSeconds", "skipForwardSeconds", the same names
/// Android syncs) that every skip control outside multiview reads: the
/// live rewind and catch-up cells, the VOD and DVR buttons, a single
/// Siri Remote left/right press (the first D-pad scrub step), the Cast /
/// AirPlay / companion remote sheet, and the lock screen and Control
/// Center skip commands. Holding left/right keeps the accelerating
/// `holdStepMs` scrub. Views that show a skip glyph also hold
/// `@AppStorage` on the keys so a change re-renders them.
///
/// Android twin: `SkipIntervals` in core/ui/SkipIntervals.kt.
enum SkipIntervals {
    static let backKey = "skipBackSeconds"
    static let forwardKey = "skipForwardSeconds"

    /// The choices offered in Settings, in seconds. Every one has an
    /// SF Symbol (`gobackward.N` / `goforward.N`).
    static let choices = [5, 10, 15, 30, 60]
    static let defaultBack = 10
    static let defaultForward = 30

    /// Base step of a HELD left/right scrub; unchanged by the setting.
    static let holdStepMs: Int64 = 10_000

    static var backSeconds: Int {
        sanitize(UserDefaults.standard.object(forKey: backKey) as? Int, fallback: defaultBack)
    }

    static var forwardSeconds: Int {
        sanitize(UserDefaults.standard.object(forKey: forwardKey) as? Int, fallback: defaultForward)
    }

    static var backMs: Int32 { Int32(backSeconds * 1000) }
    static var forwardMs: Int32 { Int32(forwardSeconds * 1000) }

    /// A stored or synced value outside `choices` reads as `fallback`.
    static func sanitize(_ seconds: Int?, fallback: Int) -> Int {
        guard let seconds, choices.contains(seconds) else { return fallback }
        return seconds
    }

    /// Signed ms for a single (non-held) step in `dir`.
    static func stepMs(_ dir: Int) -> Int64 {
        dir < 0 ? -Int64(backMs) : Int64(forwardMs)
    }

    static func backSymbol(_ seconds: Int = backSeconds) -> String {
        "gobackward.\(sanitize(seconds, fallback: defaultBack))"
    }

    static func forwardSymbol(_ seconds: Int = forwardSeconds) -> String {
        "goforward.\(sanitize(seconds, fallback: defaultForward))"
    }

    static func backLabel(_ seconds: Int = backSeconds) -> String {
        "Back \(seconds) seconds"
    }

    static func forwardLabel(_ seconds: Int = forwardSeconds) -> String {
        "Forward \(seconds) seconds"
    }
}
