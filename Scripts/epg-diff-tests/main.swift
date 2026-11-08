import Foundation

var failures = 0
var passed = 0
@MainActor func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond { passed += 1 } else { failures += 1; print("FAIL line \(line): \(msg)") }
}

let h: TimeInterval = 3600
let day = Date(timeIntervalSince1970: 1000 * 86_400)
let now = day

func row(_ id: String?, _ ch: String, _ s: Double, _ e: Double, _ title: String, _ desc: String = "") -> EPGDiffRow {
    EPGDiffRow(rowID: id, channelID: ch, start: day.addingTimeInterval(s * h),
               end: day.addingTimeInterval(e * h), title: title, description: desc)
}
func fresh(_ r: EPGDiffRow) -> EPGDiffRow { var x = r; x.rowID = nil; return x }

// unchangedDayWritesNothing
do {
    let cached = [row("1", "a", 0, 2, "News"), row("2", "a", 2, 4, "Game"), row("3", "b", 0, 6, "Movie")]
    let d = EPGDayDiff.compute(fetched: cached.map(fresh), cached: cached, inScope: nil, now: now)
    check(d.writes == 0, "unchanged writes \(d.writes)"); check(d.unchanged == 3, "unchanged count")
}
// additionIsTheOnlyWrite
do {
    let cached = [row("1", "a", 0, 2, "News")]
    let d = EPGDayDiff.compute(fetched: cached.map(fresh) + [row(nil, "a", 2, 4, "Late Show")], cached: cached, inScope: nil, now: now)
    check(d.added == 1 && d.changed == 0 && d.removed == 0, "addition counts")
    check(d.upserts.map(\.title) == ["Late Show"], "addition upsert")
}
// seriesEndingEarlyRemovesTheDroppedGameAndChangesTheSlot
do {
    let cached = [row("1", "s", 18, 20, "Pregame"), row("2", "s", 20, 23, "Game 7"), row("3", "s", 23, 24, "Postgame")]
    let d = EPGDayDiff.compute(fetched: [fresh(cached[0]), row(nil, "s", 20, 24, "Classic Replay")], cached: cached, inScope: nil, now: now)
    check(d.unchanged == 1 && d.changed == 1 && d.added == 0, "series counts")
    check(d.deleteIDs == ["3"], "series delete \(d.deleteIDs)")
    check(d.writes == 2, "series writes")
}
// endTimeMoveIsAChange
do {
    let d = EPGDayDiff.compute(fetched: [row(nil, "a", 0, 2, "Game")], cached: [row("1", "a", 0, 3, "Game")], inScope: nil, now: now)
    check(d.changed == 1 && d.writes == 1, "end move")
}
// descriptionChangeIsAChange
do {
    let d = EPGDayDiff.compute(fetched: [row(nil, "a", 0, 2, "News", "new")], cached: [row("1", "a", 0, 2, "News", "old")], inScope: nil, now: now)
    check(d.changed == 1, "description change")
}
// outOfScopeChannelsAreNeverWritten
do {
    let cached = [row("1", "a", 0, 2, "Old"), row("2", "b", 0, 2, "Old")]
    let fetched = [row(nil, "a", 0, 2, "New"), row(nil, "b", 0, 2, "New"), row(nil, "b", 2, 4, "Extra")]
    let d = EPGDayDiff.compute(fetched: fetched, cached: cached, inScope: { $0 == "a" }, now: now)
    check(d.changed == 1 && d.added == 0 && d.writes == 1, "scope counts")
    check(d.upserts.allSatisfy { $0.channelID == "a" }, "scope channel")
}
// channelMissingFromFetchIsLeftAlone
do {
    let cached = [row("1", "a", 0, 2, "News"), row("2", "b", 0, 2, "Movie")]
    let d = EPGDayDiff.compute(fetched: [fresh(cached[0])], cached: cached, inScope: nil, now: now)
    check(d.writes == 0, "missing channel")
}
// alreadyAiredRowsAreNotRemoved
do {
    let cached = [row("1", "a", 0, 2, "Aired"), row("2", "a", 4, 6, "Later")]
    let fetched = [row(nil, "a", 4, 6, "Later"), row(nil, "a", 0, 1, "Short")]
    let d = EPGDayDiff.compute(fetched: fetched, cached: cached, inScope: nil, now: day.addingTimeInterval(3 * h))
    check(d.removed == 0, "aired kept")
}
// enrichedCategoryIsNotAChange
do {
    var c = row("1", "a", 0, 2, "News"); c.category = "News,Talk"
    let d = EPGDayDiff.compute(fetched: [row(nil, "a", 0, 2, "News")], cached: [c], inScope: nil, now: now)
    check(d.writes == 0, "category enrichment")
}
// sourceRefreshWithNewProgramIdsIsNotARewrite
do {
    var c = row("1", "a", 0, 2, "News"); c.programID = 10
    var f = row(nil, "a", 0, 2, "News"); f.programID = 77
    let d = EPGDayDiff.compute(fetched: [f], cached: [c], inScope: nil, now: now)
    check(d.writes == 0 && d.unchanged == 1, "id only counts")
    check(d.programIDUpdates.count == 1 && d.programIDUpdates[0].rowID == "1" && d.programIDUpdates[0].programID == 77, "id only update")
}
// subtitle, season, episode, flags, icon each count as a change
do {
    let base = row("1", "a", 0, 2, "Show")
    let edits: [(String, (inout EPGDiffRow) -> Void)] = [
        ("subTitle", { $0.subTitle = "Pilot" }), ("season", { $0.season = 2 }), ("episode", { $0.episode = 5 }),
        ("isNew", { $0.isNew = true }), ("isLive", { $0.isLiveBroadcast = true }), ("isPremiere", { $0.isPremiere = true }),
        ("isFinale", { $0.isFinale = true }), ("isRepeat", { $0.isRepeat = true }), ("icon", { $0.iconURL = "x" }),
    ]
    for (name, edit) in edits {
        var f = fresh(base); edit(&f)
        let d = EPGDayDiff.compute(fetched: [f], cached: [base], inScope: nil, now: now)
        check(d.changed == 1 && d.writes == 1, "\(name) change")
    }
}
// short rows are ignored
do {
    let f = EPGDiffRow(channelID: "a", start: day, end: day.addingTimeInterval(10), title: "Blip")
    let d = EPGDayDiff.compute(fetched: [f], cached: [], inScope: nil, now: now)
    check(d.writes == 0, "short row")
}
// planner: per-source pairs, forced source, first sweep, decoder bump, unchanged
do {
    check(EPGSweepPlanner.plan(fresh: "1:a,2:b", stored: "1:a,2:b") == nil, "plan unchanged")
    let p = EPGSweepPlanner.plan(fresh: "1:a,2:c,3:none", stored: "1:a,2:b,3:none")
    check(p?.changedSourceIDs == [2] && p?.allChannels == false, "plan one source")
    check(EPGSweepPlanner.plan(fresh: "1:a", stored: "1:a", forcedSourceID: 7)?.changedSourceIDs == [7], "plan forced")
    check(EPGSweepPlanner.plan(fresh: "1:a", stored: nil)?.allChannels == true, "plan first")
    check(EPGSweepPlanner.plan(fresh: "1:a,grid-decoder:3", stored: "1:a,grid-decoder:2")?.allChannels == true, "plan decoder")
    let k = EPGSweepPlanner.keys(rows: [(" ESPN.us ", 2), ("cnn.us", 1), ("", 2), ("x", nil)], sourceIDs: [2])
    check(k == ["espn.us"], "keys \(k)")
}
// resume progress round trip and fingerprint mismatch
do {
    let days: Set<Date> = [day, day.addingTimeInterval(86_400)]
    let raw = EPGSweepPlanner.encodeProgress(key: "1:a,2:c", days: days)
    check(EPGSweepPlanner.decodeProgress(raw, key: "1:a,2:c") == days, "progress round trip")
    check(EPGSweepPlanner.decodeProgress(raw, key: "1:a,2:d").isEmpty, "progress other fingerprint")
    check(EPGSweepPlanner.decodeProgress(nil, key: "x").isEmpty, "progress empty")
}

// history floor: one rule for the prunes and the writers
do {
    let cap: TimeInterval = 7 * 86_400
    check(EPGHistoryWindow.floor(reachDays: 0, capSeconds: cap, now: now) == now.addingTimeInterval(-86_400), "floor no catch-up keeps a day")
    check(EPGHistoryWindow.floor(reachDays: 3, capSeconds: cap, now: now) == now.addingTimeInterval(-3 * 86_400), "floor reach 3")
    check(EPGHistoryWindow.floor(reachDays: 30, capSeconds: cap, now: now) == now.addingTimeInterval(-cap), "floor capped by retention")
    check(EPGHistoryWindow.floor(reachDays: nil, capSeconds: cap, now: now) == now.addingTimeInterval(-cap), "floor unknown channel")
    check(EPGHistoryWindow.floor(reachDays: 90, capSeconds: 40 * 86_400, now: now) == now.addingTimeInterval(-30 * 86_400), "floor reach capped at 30")
}
// a repeat pass over what the first pass wrote costs zero writes
do {
    let fetched = [row(nil, "a", -30, -28, "Old"), row(nil, "a", 1, 2, "One"), row(nil, "b", 2, 3, "Two")]
    let first = EPGDayDiff.compute(fetched: fetched, cached: [], inScope: nil, now: now)
    check(first.added == 3 && first.writes == 3, "first pass adds")
    let stored = first.upserts.enumerated().map { i, r -> EPGDiffRow in var x = r; x.rowID = "r\(i)"; return x }
    let second = EPGDayDiff.compute(fetched: fetched, cached: stored, inScope: nil, now: now)
    check(second.writes == 0 && second.unchanged == 3, "repeat pass writes nothing")
    // a partial snapshot (channel a only) never removes channel b
    let partial = EPGDayDiff.compute(fetched: [fetched[1]], cached: stored, inScope: nil, now: now)
    check(partial.writes == 0, "partial snapshot keeps other channels")
}

print("\(passed) checks passed, \(failures) failed")
if failures > 0 { exit(1) }
print("ALL TESTS PASSED")
