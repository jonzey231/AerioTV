import Foundation

/// Pulls an event start out of a channel NAME. Xtream event feeds name their
/// dynamic channels like "NFHS 01: A vs B @ Sep 02 03:30AM ET" or
/// "FOX ONE 01: ... @ 3 Sep 01:30 AM ET" (Logan 2026-09-03); with no EPG
/// behind them the guide shows the name in place of a programme, and the
/// parsed time tells the viewer when it starts. Mirrors the Android
/// core/guide/EventTimeParser.kt.
enum EventTimeParser {
    private static let months = "jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec"
    private static let tz = "(?:\\s*(ET|EST|EDT|CT|CST|CDT|MT|MST|MDT|PT|PST|PDT|GMT|UTC|BST|CET|CEST|AEST|AEDT))?"
    private static let time = "(\\d{1,2})(?::(\\d{2}))?\\s*([AaPp]\\.?[Mm]\\.?)?"

    private static let monthFirst = try! NSRegularExpression(
        pattern: "\\b(\(months))[a-z]*\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?,?(?:\\s+(\\d{4}))?\\s*[,@-]?\\s*(?:at\\s+)?\(time)\(tz)\\b",
        options: [.caseInsensitive])
    private static let dayFirst = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(\(months))[a-z]*\\.?,?(?:\\s+(\\d{4}))?\\s*[,@-]?\\s*(?:at\\s+)?\(time)\(tz)\\b",
        options: [.caseInsensitive])
    private static let numeric = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?\\s*[,@-]?\\s*(?:at\\s+)?\(time)\(tz)\\b",
        options: [.caseInsensitive])

    private static let zones: [String: String] = [
        "ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York",
        "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago",
        "MT": "America/Denver", "MST": "America/Denver", "MDT": "America/Denver",
        "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
        "GMT": "UTC", "UTC": "UTC", "BST": "Europe/London",
        "CET": "Europe/Paris", "CEST": "Europe/Paris", "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney",
    ]

    /// Event start parsed from `name`, or nil. `now` resolves a missing year.
    static func parse(_ name: String, now: Date = Date(), zone: TimeZone = .current) -> Date? {
        let ns = name as NSString
        let range = NSRange(location: 0, length: ns.length)
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        if let m = monthFirst.firstMatch(in: name, range: range) {
            return build(month: month(g(m, 1)), day: Int(g(m, 2) ?? "") ?? 0, year: g(m, 3), hour: g(m, 4), minute: g(m, 5), ampm: g(m, 6), tzToken: g(m, 7), now: now, zone: zone)
        }
        if let m = dayFirst.firstMatch(in: name, range: range) {
            return build(month: month(g(m, 2)), day: Int(g(m, 1) ?? "") ?? 0, year: g(m, 3), hour: g(m, 4), minute: g(m, 5), ampm: g(m, 6), tzToken: g(m, 7), now: now, zone: zone)
        }
        if let m = numeric.firstMatch(in: name, range: range) {
            return build(month: (Int(g(m, 1) ?? "") ?? 0) - 1, day: Int(g(m, 2) ?? "") ?? 0, year: g(m, 3), hour: g(m, 4), minute: g(m, 5), ampm: g(m, 6), tzToken: g(m, 7), now: now, zone: zone)
        }
        return nil
    }

    private static func month(_ token: String?) -> Int {
        guard let t = token?.lowercased().prefix(3) else { return -1 }
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(t)) ?? -1
    }

    private static func build(month: Int, day: Int, year: String?, hour: String?, minute: String?, ampm: String?, tzToken: String?, now: Date, zone: TimeZone) -> Date? {
        guard (0...11).contains(month), (1...31).contains(day), var h = Int(hour ?? "") else { return nil }
        let min = Int(minute ?? "0") ?? 0
        if let mer = ampm?.replacingOccurrences(of: ".", with: "").uppercased() {
            guard (1...12).contains(h) else { return nil }
            if mer == "PM", h < 12 { h += 12 }
            if mer == "AM", h == 12 { h = 0 }
        } else if !(0...23).contains(h) { return nil }
        guard (0...59).contains(min) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tzToken.flatMap { zones[$0.uppercased()] }.flatMap { TimeZone(identifier: $0) } ?? zone
        let nowYear = cal.component(.year, from: now)
        func at(_ y: Int) -> Date? {
            cal.date(from: DateComponents(year: y, month: month + 1, day: day, hour: h, minute: min))
        }
        if let ys = year {
            let y = ys.count == 2 ? 2000 + (Int(ys) ?? 0) : (Int(ys) ?? nowYear)
            return at(y)
        }
        guard let thisYear = at(nowYear) else { return nil }
        // No year in the name: this year, unless that is more than two days
        // past, in which case the feed already rolled into next year.
        return thisYear < now.addingTimeInterval(-2 * 86_400) ? at(nowYear + 1) : thisYear
    }

    /// "Starts Wed 3:30 PM" style lead-in for an empty guide row, or nil.
    static func startLabel(for name: String, now: Date = Date()) -> String? {
        guard let start = parse(name, now: now) else { return nil }
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE jmm")
        return (start < now ? "Started " : "Starts ") + f.string(from: start)
    }
}
