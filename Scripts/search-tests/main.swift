// Search pure-logic tests: Live TV filter matching, ordering, the "why it
// matched" line, and the Global Search cap-after-sort rule.

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL \(line): \(msg)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    check(a == b, "\(msg): expected \(b), got \(a)", line: line)
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/New_York")!
let en = Locale(identifier: "en_US")
// Thursday 2026-11-05 18:00 local.
let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 18))!
func at(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
let timeFmt: DateFormatter = {
    let f = DateFormatter(); f.locale = en; f.timeZone = cal.timeZone; f.dateFormat = "h:mm a"; return f
}()
func time(_ d: Date) -> String { timeFmt.string(from: d) }

func prog(_ t: String, sub: String? = nil, _ s: Double, _ e: Double) -> LiveSearchProgram {
    LiveSearchProgram(title: t, subTitle: sub, start: at(s), end: at(e))
}

let channels = [
    LiveSearchChannel(id: "a", name: "News One", number: "101"),
    LiveSearchChannel(id: "b", name: "Sports Two", number: "202"),
    LiveSearchChannel(id: "c", name: "Movies Three", number: "303"),
    LiveSearchChannel(id: "d", name: "Kids Four", number: "404"),
    LiveSearchChannel(id: "e", name: "Docs Five", number: "505"),
]
// Descriptions are not part of the model at all: the index only ever sees
// title and sub-title, so a description-only hit cannot exist.
let index = LiveProgramIndex(programs: [
    "a": [prog("Evening Report", -1, 1)],
    "b": [prog("Old Game", -3, -1), prog("Big Match", 2, 4)],
    "c": [prog("Feature", sub: "Galaxy Quest", 26, 28)],
    "d": [prog("Galaxy Cartoons", -0.5, 0.5)],
    "e": [prog("Planet", sub: "Ocean Deep", 0.5, 1.5)],
])

// MARK: - name and number
do {
    let r = LiveSearchMatcher.search(channels, query: "sports", index: index, now: now)
    eq(r.orderedIDs, ["b"], "name match")
    eq(r.programMatches.count, 0, "name match carries no program line")
    let n = LiveSearchMatcher.search(channels, query: "30", index: index, now: now)
    eq(n.orderedIDs, ["c"], "number match")
    let empty = LiveSearchMatcher.search(channels, query: "  ", index: index, now: now)
    eq(empty.orderedIDs, channels.map(\.id), "blank query keeps every row")
}

// MARK: - now, upcoming via sub-title, ordering
do {
    let r = LiveSearchMatcher.search(channels, query: "galaxy", index: index, now: now)
    // d airs now (start -0.5), c is tomorrow via the sub-title.
    eq(r.orderedIDs, ["d", "c"], "program-only matches by start")
    eq(r.programMatches["d"]?.title, "Galaxy Cartoons", "now match")
    eq(r.programMatches["c"]?.subTitle, "Galaxy Quest", "upcoming via sub-title")
    eq(LiveSearchMatcher.matchLine(r.programMatches["d"]!, now: now, calendar: cal, locale: en, time: time),
       "Galaxy Cartoons \u{00B7} On now", "on now line")
    eq(LiveSearchMatcher.matchLine(r.programMatches["c"]!, now: now, calendar: cal, locale: en, time: time),
       "Feature: Galaxy Quest \u{00B7} Tomorrow 8:00 PM", "tomorrow line")
    eq(LiveSearchMatcher.matchLine(prog("X", 0.5, 1), now: now, calendar: cal, locale: en, time: time),
       "X \u{00B7} Today 6:30 PM", "today line")
    eq(LiveSearchMatcher.matchLine(prog("X", 51, 52), now: now, calendar: cal, locale: en, time: time),
       "X \u{00B7} Sat 9:00 PM", "weekday line")
    eq(r.channelCount, 0, "counts split")
}
do {
    // Name matches first in display order, then program-only matches.
    let r = LiveSearchMatcher.search(channels, query: "o", index: index, now: now)
    eq(Array(r.orderedIDs.prefix(5)), ["a", "b", "c", "d", "e"], "every name has an o")
    let mixed = LiveSearchMatcher.search(channels, query: "match", index: index, now: now)
    eq(mixed.orderedIDs, ["b"], "upcoming title match")
    let m2 = LiveSearchMatcher.search(channels, query: "ocean", index: index, now: now)
    eq(m2.orderedIDs, ["e"], "sub-title match")
    let both = LiveSearchMatcher.search([channels[4], LiveSearchChannel(id: "x", name: "Ocean TV", number: "9")],
                                        query: "ocean", index: index, now: now)
    eq(both.orderedIDs, ["x", "e"], "name match before program-only match")
}

// MARK: - no description, ended program
do {
    let r = LiveSearchMatcher.search(channels, query: "old game", index: index, now: now)
    eq(r.orderedIDs, [], "ended program never matches")
    let d = LiveProgramIndex(programs: ["a": [prog("Evening Report", -1, 1)]])
    eq(d.firstMatch(channelID: "a", query: "anchors", now: now), nil, "no description field to match")
}

// MARK: - Global Search cap after the live-first sort
do {
    struct P { let ch: String; let s: Double; let e: Double }
    // 40 earlier-starting upcoming rows can never push out the live one,
    // even when it arrives last.
    var items = (0..<40).map { P(ch: "u\($0)", s: 1 + Double($0) * 0.1, e: 5) }
    items.append(P(ch: "live", s: -1, e: 1))
    items.append(P(ch: "live", s: -1, e: 1)) // duplicate airing
    let out = GlobalSearchRanking.rankPrograms(items, now: now, start: { at($0.s) }, end: { at($0.e) },
                                               channelKey: { $0.ch })
    eq(out.count, 30, "program cap 30")
    eq(out.first?.ch, "live", "live first")
    eq(out.filter { $0.ch == "live" }.count, 1, "one row per channel plus start")
    eq(out[1].ch, "u0", "then soonest start")
    eq(GlobalSearchRanking.movieCap + GlobalSearchRanking.seriesCap, 50, "25 movies plus 25 series")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
