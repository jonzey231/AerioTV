import Foundation

/// Settings > Appearance > Time Format. One key ("timeFormat": "system",
/// "12" or "24", Drive/iCloud-synced under the same name Android uses) that
/// every clock in the app reads, so the guide header, cell ranges, program
/// info, search and recordings all agree. System follows the device's
/// 24-hour setting exactly as before the option existed.
enum ClockFormat {
    static let defaultsKey = "timeFormat"

    static var mode: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? "system"
    }

    static var uses24Hour: Bool {
        switch mode {
        case "12": return false
        case "24": return true
        default:
            let t = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
            return t.contains("H") || t.contains("k")
        }
    }

    // Guarded by `lock` below.
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    private static func formatter(_ kind: String, _ build: (DateFormatter) -> Void) -> DateFormatter {
        let key = "\(kind):\(mode)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.dateStyle = .none
        build(f)
        cache[key] = f
        return f
    }

    /// "7:30 PM" / "19:30"; System keeps the locale's own short style.
    static func short() -> DateFormatter {
        formatter("short") { f in
            switch mode {
            case "12": f.dateFormat = "h:mm a"
            case "24": f.dateFormat = "HH:mm"
            default: f.timeStyle = .short
            }
        }
    }

    /// Guide header labels: "7:30pm" / "19:30".
    static func guideLabel() -> DateFormatter {
        formatter("guideLabel") { f in
            if uses24Hour {
                f.dateFormat = "HH:mm"
            } else {
                f.dateFormat = "h:mma"
                f.amSymbol = "am"
                f.pmSymbol = "pm"
            }
        }
    }

    /// Guide cell ranges: "7:30" / "19:30".
    static func guideShort() -> DateFormatter {
        formatter("guideShort") { f in
            f.dateFormat = uses24Hour ? "HH:mm" : "h:mm"
        }
    }

    /// Medium date plus the short clock: "Sep 2, 2026 at 7:30 PM".
    static func dateAndShortTime() -> DateFormatter {
        formatter("dateTime") { f in
            switch mode {
            case "12":
                f.dateFormat = DateFormatter.dateFormat(fromTemplate: "yMMMd hmm a", options: 0, locale: .current)
            case "24":
                f.dateFormat = DateFormatter.dateFormat(fromTemplate: "yMMMd HHmm", options: 0, locale: .current)
            default:
                f.dateStyle = .medium
                f.timeStyle = .short
            }
        }
    }
}
