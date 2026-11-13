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

// MARK: - Programs section (whole loaded guide, title only, cap)
do {
    let idx = LiveProgramIndex(programs: [
        "a": [prog("Late Match", -3, -1), prog("Match Night", -0.5, 1), prog("Recap", sub: "Match", 2, 3),
              prog("Match Night", 26, 27)],
        "b": [prog("Big Match", 1, 2), prog("Big Match", 1, 2)],
        "z": [prog("Match Hidden", 1, 2)],
    ])
    let order = ["a": 0, "b": 1]
    let r = idx.programHits(query: " MATCH ", now: now, channelOrder: order)
    eq(r.hits.map(\.channelID), ["a", "b", "a"], "now forward, start order, playlist only, deduped")
    eq(r.truncated, false, "not truncated")
    eq(r.hits[0].isAiring(at: now), true, "airing now")
    eq(LiveProgramHit.whenText(r.hits[1].program, now: now, calendar: cal, locale: en, time: time),
       "Today 7:00 PM", "today: Today and time")
    eq(LiveProgramHit.whenText(r.hits[2].program, now: now, calendar: cal, locale: en, time: time),
       "Fri 8:00 PM", "later day: weekday and time")
    let many = LiveProgramIndex(programs: ["a": (0..<250).map { prog("Show", Double($0), Double($0) + 0.5) }])
    let c = many.programHits(query: "show", now: now, channelOrder: ["a": 0])
    eq(c.hits.count, 200, "cap 200")
    eq(c.truncated, true, "truncated")
    eq(idx.programHits(query: "  ", now: now, channelOrder: order).hits.count, 0, "blank query")
}

// MARK: - Channel-name filler is not a program (tvOS review 2026-11-05)
do {
    let keys = LiveSearchMatcher.channelTitleKeys(name: "ESPN2", tvgID: "ESPN2HD.us")
    eq(keys, ["espn2", "espn2hd"], "name and call sign keys")
    eq(LiveSearchMatcher.channelTitleKeys(name: " ", tvgID: nil), [], "no keys")
    check(LiveSearchMatcher.isChannelTitle(" espn2 ", keys: keys), "name match ignores case and spaces")
    check(!LiveSearchMatcher.isChannelTitle("ESPN2 College Football", keys: keys), "real title kept")
    let filler = LiveProgramIndex(programs: [
        "x": [prog("ESPN2", 0, 1), prog("SportsCenter on ESPN2", 1, 2), prog("espn2hd", 2, 3)],
        "y": [prog("ESPN2", 0, 1)],
    ])
    let r = filler.programHits(query: "espn2", now: now, channelOrder: ["x": 0, "y": 1],
                               channelTitles: ["x": keys])
    eq(r.hits.map(\.program.title), ["ESPN2", "SportsCenter on ESPN2"],
       "filler dropped only on its own channel")
}

// MARK: - Channel links (README "Deep links"; Android ChannelDeepLink.kt)

do {
    func url(_ s: String) -> URL { URL(string: s)! }
    // Parsing: the first path segment, percent-decoded; both schemes; channel host only.
    check(ChannelLink.id(from: url("aeriotv://channel/number:5")) == "number:5", "aeriotv number link")
    check(ChannelLink.id(from: url("aerio://channel/42")) == "42", "legacy aerio link (Top Shelf)")
    check(ChannelLink.id(from: url("AERIOTV://Channel/disp:ABC")) == "disp:ABC", "scheme and host any case, id kept")
    check(ChannelLink.id(from: url("aeriotv://channel/m3u:http%3A%2F%2Fh.example%2Fs.ts")) == "m3u:http://h.example/s.ts",
          "a percent-encoded m3u:<url> decodes whole")
    check(ChannelLink.id(from: url("aeriotv://channel/m3u%3Anews.1")) == "m3u:news.1", "encoded colon decodes")
    check(ChannelLink.id(from: url("aeriotv://channel/")) == nil, "empty id")
    check(ChannelLink.id(from: url("aeriotv://setup?v=1&code=x")) == nil, "setup link is not a channel link")
    check(ChannelLink.id(from: url("aerio://vod/movie/12")) == nil, "VOD link is not a channel link")
    check(ChannelLink.id(from: url("https://channel/5")) == nil, "other schemes ignored")

    // Cross-platform ids, as Android names its channels.
    check(ChannelLink.crossID(isDispatcharr: true, isM3U: false, uuid: "u-1", tvgID: "x", streamURL: "http://a") == "disp:u-1", "Dispatcharr: disp:<uuid>")
    check(ChannelLink.crossID(isDispatcharr: false, isM3U: true, uuid: nil, tvgID: "news.1", streamURL: "http://a") == "m3u:news.1", "M3U: m3u:<tvg-id>")
    check(ChannelLink.crossID(isDispatcharr: false, isM3U: true, uuid: nil, tvgID: "", streamURL: "http://a/b") == "m3u:http://a/b", "M3U without tvg-id: m3u:<url>")
    check(ChannelLink.crossID(isDispatcharr: false, isM3U: false, uuid: nil, tvgID: "x", streamURL: "http://a") == nil, "Xtream: none")

    let u7 = "00000000-0000-4000-8000-000000000007"
    let disp: [ChannelLinkCandidate] = [
        .init(id: "5", crossID: "disp:00000000-0000-4000-8000-000000000005", uuid: "00000000-0000-4000-8000-000000000005", dispatcharrID: 5, number: "5"),
        .init(id: "7", crossID: "disp:\(u7)", uuid: u7, dispatcharrID: 7, number: "7.1"),
        .init(id: "9", crossID: "disp:00000000-0000-4000-8000-00000000000a", uuid: "00000000-0000-4000-8000-00000000000A", dispatcharrID: 9, number: "12"),
    ]
    check(ChannelLink.resolve("7", in: disp) == "7", "Apple's own id")
    check(ChannelLink.resolve("disp:\(u7)", in: disp) == "7", "disp:<uuid>")
    check(ChannelLink.resolve("DISP:\(u7.uppercased())", in: disp) == "7", "disp: any case")
    check(ChannelLink.resolve(u7, in: disp) == "7", "bare uuid")
    check(ChannelLink.resolve("00000000-0000-4000-8000-00000000000a", in: disp) == "9", "bare uuid, any case")
    check(ChannelLink.resolve("dispatcharr:9", in: disp) == "9", "dispatcharr:<channel id>")
    check(ChannelLink.resolve("dispatcharr: 5 ", in: disp) == "5", "dispatcharr: trims")
    check(ChannelLink.resolve("dispatcharr:x", in: disp) == nil, "dispatcharr: needs an integer")
    check(ChannelLink.resolve("number:5", in: disp) == "5", "number:<n>")
    check(ChannelLink.resolve("number:7.1", in: disp) == "7", "number with a decimal")
    check(ChannelLink.resolve("number:5.0", in: disp) == "5", "number by value when the text differs")
    check(ChannelLink.resolve("number:12", in: disp) == "9", "number is the guide's number, not the id")
    check(ChannelLink.resolve("number:", in: disp) == nil, "empty number")
    check(ChannelLink.resolve("number:99", in: disp) == nil, "no such number")
    check(ChannelLink.resolve("disp:00000000-0000-4000-8000-0000000000ff", in: disp) == nil, "unknown uuid")
    check(ChannelLink.resolve("m3u:news.1", in: disp) == nil, "m3u: does not match a Dispatcharr channel")
    check(ChannelLink.resolve("  ", in: disp) == nil, "blank link")

    let m3u: [ChannelLinkCandidate] = [
        .init(id: "m3u_aa", crossID: "m3u:news.1", uuid: nil, dispatcharrID: nil, number: "1"),
        .init(id: "m3u_bb", crossID: "m3u:http://h.example/s.ts", uuid: nil, dispatcharrID: nil, number: "2"),
        .init(id: "m3u_cc", crossID: "m3u:news.1", uuid: nil, dispatcharrID: nil, number: "3"),
    ]
    check(ChannelLink.resolve("m3u:news.1", in: m3u) == "m3u_aa", "m3u:<tvg-id>, the first in channel order")
    check(ChannelLink.resolve("m3u:http://h.example/s.ts", in: m3u) == "m3u_bb", "m3u:<url>")
    check(ChannelLink.resolve("m3u_bb", in: m3u) == "m3u_bb", "Apple's own M3U id (Top Shelf)")
    check(ChannelLink.resolve("dispatcharr:1", in: m3u) == nil, "dispatcharr: never matches an M3U channel")
    check(ChannelLink.resolve("number:2", in: m3u) == "m3u_bb", "number on M3U")

    check(ChannelLink.logForm("m3u:http://user:pw@h.example/s.ts") == "m3u:<url, 29 characters>", "a URL id is logged by length only")
    check(ChannelLink.logForm("number:5") == "number:5", "other ids are logged as is")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
