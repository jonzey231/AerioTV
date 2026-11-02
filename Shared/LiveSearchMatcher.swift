import Foundation

// Search pure logic (Android parity, AerioTV-Android feature/livetv/
// LiveSearchMatcher.kt, DisplayChannels.kt computeLiveSearch, and
// feature/search/SearchViewModel.kt). Foundation only: no UIKit, SwiftUI,
// or SwiftData, so Scripts/search-tests compiles it with swiftc.

/// One guide program as the Live TV filter sees it.
struct LiveSearchProgram: Sendable, Equatable {
    let title: String
    let subTitle: String?
    let start: Date
    let end: Date

    init(title: String, subTitle: String?, start: Date, end: Date) {
        self.title = title
        self.subTitle = subTitle
        self.start = start
        self.end = end
    }
}

/// One channel row as the Live TV filter sees it, in display order.
struct LiveSearchChannel: Sendable, Equatable {
    let id: String
    let name: String
    let number: String

    init(id: String, name: String, number: String) {
        self.id = id
        self.name = name
        self.number = number
    }
}

/// In-memory index over the loaded guide map: per channel id, the programs
/// in start order with title and sub-title lowercased once. Built off the
/// main actor and reused while the guide map is unchanged.
final class LiveProgramIndex: @unchecked Sendable {
    private struct Entry {
        let text: String
        let program: LiveSearchProgram
    }
    private let byChannel: [String: [Entry]]

    init(programs: [String: [LiveSearchProgram]]) {
        var out: [String: [Entry]] = [:]
        out.reserveCapacity(programs.count)
        for (key, list) in programs {
            let entries = list
                .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { $0.start < $1.start }
                .map { p -> Entry in
                    let sub = p.subTitle.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    let text = sub.map { p.title.lowercased() + "\n" + $0.lowercased() } ?? p.title.lowercased()
                    return Entry(text: text, program: p)
                }
            if !entries.isEmpty { out[key] = entries }
        }
        byChannel = out
    }

    /// The earliest program on `channelID` that has not ended by `now` and
    /// whose title or sub-title contains `query`. Descriptions never match.
    func firstMatch(channelID: String, query: String, now: Date) -> LiveSearchProgram? {
        guard let entries = byChannel[channelID] else { return nil }
        let q = query.lowercased()
        for e in entries {
            if e.program.end <= now { continue }
            if e.text.contains(q) { return e.program }
        }
        return nil
    }
}

enum LiveSearchMatcher {
    /// Debounce before a Live TV filter pass (Android LIVE_SEARCH_DEBOUNCE_MS).
    static let debounceMilliseconds = 120

    /// Case-insensitive substring on the channel name or number.
    static func channelMatches(_ ch: LiveSearchChannel, query: String) -> Bool {
        ch.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || ch.number.range(of: query, options: .caseInsensitive) != nil
    }

    struct Result: Sendable, Equatable {
        /// Name or number matches in the given order, then program-only
        /// matches by that program's start.
        let orderedIDs: [String]
        /// Program-only match per channel id: why the row is there.
        let programMatches: [String: LiveSearchProgram]
        var channelCount: Int { orderedIDs.count - programMatches.count }
    }

    /// `channels` arrive already filtered by group and sorted for display.
    static func search(_ channels: [LiveSearchChannel], query rawQuery: String,
                       index: LiveProgramIndex?, now: Date) -> Result {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Result(orderedIDs: channels.map(\.id), programMatches: [:])
        }
        var byName: [String] = []
        var byProgram: [(id: String, offset: Int, program: LiveSearchProgram)] = []
        var matches: [String: LiveSearchProgram] = [:]
        for (offset, ch) in channels.enumerated() {
            if channelMatches(ch, query: query) {
                byName.append(ch.id)
            } else if let p = index?.firstMatch(channelID: ch.id, query: query, now: now) {
                byProgram.append((ch.id, offset, p))
                matches[ch.id] = p
            }
        }
        // Stable by start (Kotlin sortedBy is stable).
        byProgram.sort { a, b in
            if a.program.start != b.program.start { return a.program.start < b.program.start }
            return a.offset < b.offset
        }
        return Result(orderedIDs: byName + byProgram.map(\.id), programMatches: matches)
    }

    /// "<title> · On now", "<title>: <sub-title> · Today 8:20 PM",
    /// "Tomorrow 7:00 AM", or "Sat 9:00 PM".
    static func matchLine(_ p: LiveSearchProgram, now: Date, calendar: Calendar = .current,
                          locale: Locale = .current, time: (Date) -> String) -> String {
        let sub = p.subTitle.flatMap { s -> String? in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.caseInsensitiveCompare(p.title) == .orderedSame ? nil : t
        }
        let title = sub.map { "\(p.title): \($0)" } ?? p.title
        return "\(title) \u{00B7} \(matchWhen(p, now: now, calendar: calendar, locale: locale, time: time))"
    }

    static func matchWhen(_ p: LiveSearchProgram, now: Date, calendar: Calendar = .current,
                          locale: Locale = .current, time: (Date) -> String) -> String {
        if p.start <= now { return "On now" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: p.start)).day ?? 0
        let day: String
        switch days {
        case 0: day = "Today"
        case 1: day = "Tomorrow"
        default:
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = "EEE"
            day = f.string(from: p.start)
        }
        return "\(day) \(time(p.start))"
    }
}

/// Global Search caps (Android SearchViewModel).
enum GlobalSearchRanking {
    static let programCap = 30
    static let movieCap = 25
    static let seriesCap = 25

    /// Live first, then soonest start; one row per channel plus start time;
    /// THEN the cap, so a live airing is never cut by earlier-starting rows.
    static func rankPrograms<T>(_ items: [T], now: Date, cap: Int = programCap,
                                start: (T) -> Date, end: (T) -> Date,
                                channelKey: (T) -> String) -> [T] {
        func live(_ t: T) -> Bool { start(t) <= now && now < end(t) }
        let sorted = items.enumerated().sorted { a, b in
            let la = live(a.element), lb = live(b.element)
            if la != lb { return la }
            let sa = start(a.element), sb = start(b.element)
            if sa != sb { return sa < sb }
            return a.offset < b.offset
        }.map(\.element)
        var seen = Set<String>()
        var out: [T] = []
        for t in sorted {
            let key = channelKey(t) + "|" + String(start(t).timeIntervalSince1970)
            if !seen.insert(key).inserted { continue }
            out.append(t)
            if out.count == cap { break }
        }
        return out
    }
}
