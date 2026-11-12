// Dispatcharr Sync pure-logic tests. Each section names the Android test
// it ports (app/src/test/java/com/aeriotv/android/core/sync/...).

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL \(line): \(msg)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    check(a == b, "\(msg): expected \(b), got \(a)", line: line)
}

func obj(_ s: String) -> DsyncObject {
    guard let o = DsyncJSONParser.parseObject(s) else { fatalError("bad json \(s)") }
    return o
}

typealias Cat = SetupSourceChoice.Category
typealias Sum = SetupSourceChoice.Summary
func sum(_ c: (String, Cat)...) -> Sum { Sum(categories: Dictionary(uniqueKeysWithValues: c)) }

// MARK: - JSON round trip (foundation for every byte count)

do {
    let s = #"{"b":1,"a":[1.0,"x\n\"y",null,true,{"z":-2e3}],"c":"é"}"#
    let o = obj(s)
    eq(DsyncJSONEncoder.encode(o), s, "compact round trip keeps order and literals")
    eq(DsyncJSONEncoder.byteSize(o), s.utf8.count, "byteSize is UTF-8 compact length")
    check(DsyncJSONParser.parse("{\"a\":}") == nil, "malformed JSON rejected")
    check(obj(#"{"a":1,"b":2}"#) == obj(#"{"b":2,"a":1}"#), "object equality ignores order")
    eq(DsyncJSON.number("1.0").asInt, nil, "1.0 is not an Int (intOrNull)")
    eq(DsyncJSON.number("7").asInt, 7, "7 is an Int")
    eq(DsyncJSON.double(1.0).content, "1.0", "Kotlin double spelling")
    eq(truncateUtf8("héllo", 2), "h", "truncate on a code point boundary")
}

// MARK: - DsyncCoexistenceTest

do {
    eq(DsyncCoexistence.SHARED_CATEGORIES, [.favorites, .watchProgress, .reminders, .watchlist, .preferences],
       "sharedCategoriesExcludePlaylistsAndCredentials")

    check(DsyncCoexistence.owns(.favorites, activeIsDispatcharr: true, dispatcharrSyncOn: true, firstPullDoneForUser: true), "owns all three")
    check(!DsyncCoexistence.owns(.favorites, activeIsDispatcharr: false, dispatcharrSyncOn: true, firstPullDoneForUser: true), "owns needs Dispatcharr")
    check(!DsyncCoexistence.owns(.favorites, activeIsDispatcharr: true, dispatcharrSyncOn: false, firstPullDoneForUser: true), "owns needs sync on")
    check(!DsyncCoexistence.owns(.favorites, activeIsDispatcharr: true, dispatcharrSyncOn: true, firstPullDoneForUser: false), "owns needs first pull")
    check(!DsyncCoexistence.owns(.playlists, activeIsDispatcharr: true, dispatcharrSyncOn: true, firstPullDoneForUser: true), "never owns playlists")
    check(!DsyncCoexistence.owns(.credentials, activeIsDispatcharr: true, dispatcharrSyncOn: true, firstPullDoneForUser: true), "never owns credentials")

    // emptyServerCopySeedsFromLocalOnFirstPull
    check(DsyncCoexistence.seedFromLocal(.favorites, consumedBefore: false, data: obj(#"{"ids":[]}"#)), "seed favorites")
    check(DsyncCoexistence.seedFromLocal(.progress, consumedBefore: false, data: obj(#"{"rows":[]}"#)), "seed progress")
    check(DsyncCoexistence.seedFromLocal(.settings, consumedBefore: false, data: obj(#"{"v":{},"tv":{}}"#)), "seed settings")
    check(DsyncCoexistence.seedFromLocal(.hiddenGroups, consumedBefore: false, data: obj(#"{"live":[],"movies":[],"series":[]}"#)), "seed hiddenGroups")
    check(DsyncCoexistence.seedFromLocal(.groupOrder, consumedBefore: false, data: obj(#"{"mode":"default","order":[]}"#)), "seed groupOrder")
    check(DsyncCoexistence.seedFromLocal(.watchlist, consumedBefore: false, data: obj("{}")), "seed watchlist")

    // populatedOrAlreadyConsumedCopiesApplyAsBefore
    check(!DsyncCoexistence.seedFromLocal(.favorites, consumedBefore: false, data: obj(#"{"ids":[5]}"#)), "populated favorites")
    check(!DsyncCoexistence.seedFromLocal(.groupOrder, consumedBefore: false, data: obj(#"{"mode":"alphabetical","order":[]}"#)), "alphabetical mode")
    check(!DsyncCoexistence.seedFromLocal(.radioDefault, consumedBefore: false, data: obj(#"{"on":false}"#)), "radio false is a value")
    check(!DsyncCoexistence.seedFromLocal(.favorites, consumedBefore: true, data: obj(#"{"ids":[]}"#)), "later empty copy is a change")
    check(!DsyncCoexistence.seedFromLocal(.profiles, consumedBefore: false, data: obj(#"{"rows":[]}"#)), "profiles never seed")

    // forcedApplyReplacesEverySharedCategory
    for c in [DsyncCategory.preferences, .favorites, .watchProgress, .reminders, .watchlist] {
        check(DsyncCoexistence.replaceOnForcedApply(c), "replace \(c)")
    }
    for c in [DsyncCategory.playlists, .credentials] { check(!DsyncCoexistence.replaceOnForcedApply(c), "no replace \(c)") }

    // deferredForcedProgressStaysArmedAndRetries
    check(DsyncReadiness.dirtyAfter(DsyncReadiness.decide(.progress, cacheReady: false, unresolvedRows: 8), putOk: false, dirtyBefore: true), "deferral stays dirty")
    eq(DsyncReadiness.decide(.progress, cacheReady: false, unresolvedRows: 8), .deferred, "progress defers")
    check(DsyncCoexistence.forcedRetryDue(armed: true, awaiting: true, cacheReady: true), "retry due")
    check(!DsyncCoexistence.forcedRetryDue(armed: true, awaiting: true, cacheReady: false), "no retry before cache")
    check(!DsyncCoexistence.forcedRetryDue(armed: false, awaiting: true, cacheReady: true), "no retry unarmed")
    check(!DsyncCoexistence.forcedRetryDue(armed: true, awaiting: false, cacheReady: true), "no retry not waiting")
    eq(DsyncReadiness.decide(.progress, cacheReady: true, unresolvedRows: 2), .pushPartial, "partial after cache")
    check(DsyncCoexistence.FORCE_KEYS.contains(.progress), "progress forced")

    // forcedSettingsMirrorCountMatchesDriveProbe
    let cloud: [String: [String: String]] = [
        "v": ["a": "1", "b": "true", "c": "x", "d": "2", "e": "y"],
        "tv": ["f": "3"],
        "mobile": ["g": "z", "blank": ""],
    ]
    let mirror = cloud.mapValues { $0.mapValues { DsyncJSON.string($0) } }
    let serverBase = obj(#"{"v":{"a":"9","old1":"q","old2":"r"},"tv":{"old3":"s"},"mobile":{"old4":"t"}}"#)
    let base = serverBase.filterKeys { !DsyncPayloads.SETTINGS_LANES.contains($0) }
    let data = DsyncPayloads.encodeSettingsLanes(base, mirror)
    let cloudCat = CloudCanon.settingsCategory(cloud, updatedAt: 0)
    eq(cloudCat.rows, 7, "cloud settings rows")
    eq(DsyncCoexistence.rowCount(.settings, data), cloudCat.rows, "settings push count matches cloud probe")
    eq(DsyncCoexistence.fingerprint(.settings, data), cloudCat.fingerprint, "settings fingerprint matches cloud probe")
    eq(DsyncCoexistence.rowCount(.settings, DsyncPayloads.encodeSettingsLanes(serverBase, mirror)), 11, "old merge produced extra rows")

    // cloudFileFor maps every key with a category (DriveFileMappingTest).
    for k in DsyncKey.allCases where k != .profiles { check(DsyncCoexistence.cloudFileFor(k) != nil, "cloud file for \(k)") }
    eq(DsyncCoexistence.cloudFileFor(.recents), .preferences, "recents ride the Preferences file")
    eq(DsyncCoexistence.cloudFileFor(.collections), .preferences, "collections ride the Preferences file")
    eq(DsyncCoexistence.cloudFileFor(.profiles), nil, "profiles have no cloud file")

    // choiceApplies (section 10a pull before replace)
    check(DsyncCoexistence.choiceApplies(remoteWins: false, forceApply: true, key: .favorites, dirty: false), "choice applies")
    check(!DsyncCoexistence.choiceApplies(remoteWins: false, forceApply: true, key: .favorites, dirty: true), "dirty change goes up")
    check(!DsyncCoexistence.choiceApplies(remoteWins: true, forceApply: true, key: .favorites, dirty: false), "newer applies normally")
    check(!DsyncCoexistence.choiceApplies(remoteWins: false, forceApply: true, key: .profiles, dirty: false), "never profiles")
    check(!DsyncCoexistence.choiceApplies(remoteWins: false, forceApply: true, key: .remoteMap, dirty: false), "never remoteMap")
    check(DsyncCoexistence.FORCE_ROW_KEYS.isSubset(of: Set(DsyncCoexistence.FORCE_KEYS)), "row keys are forced keys")
}

// MARK: - DsyncManualTest

do {
    eq(DsyncManual.keys([:]), DsyncCoexistence.FORCE_KEYS, "allOnCoversEveryForcedKey")
    let keys = DsyncManual.keys(["favorites": .off, "watchProgress": .off, "hiddenTitles": .off])
    check(!keys.contains(.favorites) && !keys.contains(.progress) && !keys.contains(.hiddenTitles), "off items excluded")
    check(keys.contains(.recents) && keys.contains(.settings), "others kept")
    let all = DsyncManual.keys([:])
    check(!all.contains(.profiles) && !all.contains(.remoteMap) && !all.contains(.radioDefault), "neverForcedKeysExcluded")
    eq(DsyncManual.rows(dispatcharrOn: true, dispatcharrPlaylist: true, cloudOn: true, cloudSignedIn: true), .init(pushPullDispatcharr: true, pushToBoth: true), "rows all")
    eq(DsyncManual.rows(dispatcharrOn: true, dispatcharrPlaylist: true, cloudOn: false, cloudSignedIn: false), .init(pushPullDispatcharr: true, pushToBoth: false), "rows no cloud")
    eq(DsyncManual.rows(dispatcharrOn: true, dispatcharrPlaylist: true, cloudOn: true, cloudSignedIn: false), .init(pushPullDispatcharr: true, pushToBoth: false), "rows signed out")
    eq(DsyncManual.rows(dispatcharrOn: false, dispatcharrPlaylist: true, cloudOn: true, cloudSignedIn: true), .init(pushPullDispatcharr: false, pushToBoth: false), "rows dsync off")
    eq(DsyncManual.rows(dispatcharrOn: true, dispatcharrPlaylist: false, cloudOn: true, cloudSignedIn: true), .init(pushPullDispatcharr: false, pushToBoth: false), "rows not Dispatcharr")
}

// MARK: - HeldProgressTest (pure parts)

do {
    let nowS: Int64 = 2_000_000_000
    let row = ProgressRow(vodId: 11, type: "m", position: 10, duration: 100, updatedAt: nowS - 60, finished: false,
                          seriesId: nil, season: 0, episode: 0, title: "T m11")
    let wire = DsyncPayloads.encodeProgress(nil, [row], now: nowS)
    let held = [row]
    let keepHeld = { (t: String, id: Int) in
        DsyncHeld.representable(t, id, movies: [], episodes: [], held: Set(held.map(DsyncHeld.item)), cloud: [])
    }
    let (c, gone) = DsyncHeld.vodCategory(.progress, wire, updatedAtMs: 1_000, keep: keepHeld)
    eq(c.rows, 1, "held row counts")
    eq(gone, 0, "held row not excluded")
    eq(c.fingerprint, CloudCanon.dsyncProgress([row]), "held fingerprint is the canonical one")
    // A cloud copy carrying the same canonical row (the placeholder push) is equal.
    let cloudSide = sum(("progress", Cat(rows: 1, updatedAt: 1_000, fingerprint: SetupSourceChoice.fingerprint(["m|11"]))))
    let dsyncSide = sum(("progress", c))
    eq(SetupSourceChoice.decide(cloudSide, dsyncSide), .useDispatcharr, "equal summaries use Dispatcharr")
    check(SetupSourceChoice.convergePlan(cloudSide, dsyncSide, skip: [], lastPushed: [:]).isEmpty, "nothing to converge")

    // unrepresentableRowIsExcludedSoNothingDiffers
    let none = { (t: String, id: Int) in DsyncHeld.representable(t, id, movies: [], episodes: [], held: [], cloud: []) }
    let (c2, gone2) = DsyncHeld.vodCategory(.progress, wire, updatedAtMs: 1_000, keep: none)
    eq(c2.rows, 0, "unrepresentable row dropped")
    eq(gone2, 1, "one excluded")
    let x = sum(("progress", c2))
    let emptyCloud = sum(("progress", Cat(rows: 0, updatedAt: 1_000, fingerprint: SetupSourceChoice.fingerprint([String]()))))
    if case .ask = SetupSourceChoice.decide(emptyCloud, x) { check(false, "must not ask") }
    check(SetupSourceChoice.convergeSkips(emptyCloud, x, skip: [:], lastPushed: [:]).isEmpty, "no skips")
    eq(DsyncHeld.excludeLine("progress", rows: gone2), "[SYNC] probe excludes progress rows=1 (no local match)", "exclude line")

    // driveCarriedOrResolvedRowsStayInTheDispatcharrSummary
    check(DsyncHeld.representable("m", 11, movies: [11], episodes: [], held: [], cloud: []), "resolved movie")
    check(DsyncHeld.representable("m", 11, movies: [], episodes: [], held: [], cloud: ["m|11"]), "cloud carried")
    check(DsyncHeld.representable("s", 5, movies: [], episodes: [], held: [], cloud: []), "series always")
    check(!DsyncHeld.representable("e", 7, movies: [], episodes: [], held: [], cloud: []), "unknown episode")
    check(DsyncHeld.representable("c", 9, movies: [], episodes: [], held: [], cloud: [], channels: nil), "unloaded channel list excludes nothing")
    check(!DsyncHeld.representable("c", 9, movies: [], episodes: [], held: [], cloud: [], channels: [1]), "unknown channel")
    check(DsyncHeld.representable("c", 9, movies: [], episodes: [], held: [], cloud: ["c|9"], channels: [1]), "cloud channel")
    let marks = DsyncPayloads.encodeVodMarks(nil, [VodMarkRow(vodId: 3, type: "s", at: 1), VodMarkRow(vodId: 9, type: "m", at: 1)], cap: 100)
    let (c3, gone3) = DsyncHeld.vodCategory(.watchlist, marks, updatedAtMs: 1_000, keep: none)
    eq(c3.rows, 1, "series mark kept")
    eq(gone3, 1, "movie mark excluded")

    // Placeholders and merge.
    eq(DsyncHeld.placeholder("m", 11), "dsync:m:11", "placeholder id")
    check(DsyncHeld.isPlaceholder("dsync:e:4") && !DsyncHeld.isPlaceholder("uuid-1"), "placeholder test")
    var newer = row; newer.updatedAt += 10; newer.position = 50
    eq(DsyncHeld.merge([row], [newer]), [newer], "merge keeps the newest per item")

    // replaceSnapshotWaitsForLocalProgress (SetupSourceChoiceTest)
    check(DsyncHeld.progressSettled(heldRows: 0, catalogReady: false), "settled no held")
    check(!DsyncHeld.progressSettled(heldRows: 3, catalogReady: false), "wait for catalog")
    check(DsyncHeld.progressSettled(heldRows: 3, catalogReady: true), "settled with catalog")
}

// MARK: - SetupSourceChoiceTest

do {
    eq(SetupSourceChoice.decide(.EMPTY, .EMPTY), .useDispatcharr, "bothEmptyUsesDispatcharr")
    eq(SetupSourceChoice.decide(sum(("favorites", Cat(rows: 0, updatedAt: 5_000))), sum(("favorites", Cat(rows: 3, updatedAt: 1_000)))),
       .useDispatcharr, "zeroRowCategoriesCountAsEmpty")
    eq(SetupSourceChoice.decide(sum(("favorites", Cat(rows: 2, updatedAt: 1))), .EMPTY), .useCloud, "dispatcharrEmptyUsesCloud")
    eq(SetupSourceChoice.decide(.EMPTY, sum(("progress", Cat(rows: 4, updatedAt: 1)))), .useDispatcharr, "cloudEmptyUsesDispatcharr")

    let fp = SetupSourceChoice.fingerprint(["ESPN|100", "CNN|200"])
    let d1 = sum(("reminders", Cat(rows: 2, updatedAt: 10, fingerprint: SetupSourceChoice.fingerprint(["cnn|200", "espn|100"]))),
                 ("favorites", Cat(rows: 0, updatedAt: 0)))
    eq(SetupSourceChoice.decide(d1, sum(("reminders", Cat(rows: 2, updatedAt: 20, fingerprint: fp)))), .useDispatcharr, "equalFingerprintsPreferDispatcharr")

    func isAsk(_ d: SetupSourceChoice.Decision) -> Bool { if case .ask = d { return true }; return false }
    check(isAsk(SetupSourceChoice.decide(sum(("reminders", Cat(rows: 2, updatedAt: 10, fingerprint: SetupSourceChoice.fingerprint(["a|1", "b|2"])))),
                                         sum(("reminders", Cat(rows: 2, updatedAt: 20, fingerprint: SetupSourceChoice.fingerprint(["a|1", "c|3"])))))),
          "differingFingerprintsAsk")
    let nofp = sum(("favorites", Cat(rows: 5, updatedAt: 10)))
    eq(SetupSourceChoice.decide(nofp, nofp), .ask(cloud: nofp, dsync: nofp), "sameCountsWithoutFingerprintAsk")
    check(isAsk(SetupSourceChoice.decide(sum(("progress", Cat(rows: 3, updatedAt: 1, fingerprint: "x"))), sum(("progress", Cat(rows: 4, updatedAt: 1, fingerprint: "x"))))), "differentCountsAsk")
    check(isAsk(SetupSourceChoice.decide(sum(("favorites", Cat(rows: 2, updatedAt: 1))), sum(("progress", Cat(rows: 2, updatedAt: 1, fingerprint: "p"))))), "categoryOnOneSideOnlyAsks")

    let older = sum(("favorites", Cat(rows: 1, updatedAt: 1_000)))
    let newer = sum(("favorites", Cat(rows: 1, updatedAt: 9_000)))
    eq(SetupSourceChoice.defaultSelection(cloud: newer, dsync: older), .dispatcharr, "defaultSelection 1")
    eq(SetupSourceChoice.defaultSelection(cloud: older, dsync: newer), .dispatcharr, "defaultSelection 2")
    eq(sum(("favorites", Cat(rows: 1, updatedAt: 1_000)), ("settings", Cat(rows: 0, updatedAt: 99_000))).updatedAt, 1_000, "recencyIgnoresEmptyCategories")

    // convergeEqualCountsOnlyLoggedSkips
    let a = sum(("progress", Cat(rows: 3, updatedAt: 1, fingerprint: "fp")), ("recents", Cat(rows: 2, updatedAt: 1, fingerprint: "r")))
    let skips = SetupSourceChoice.convergeSkips(a, a, skip: ["progress": "dirty"], lastPushed: [:])
    check(skips.isEmpty, "equal category not skipped")
    eq(SetupSourceChoice.convergeEqualLine(categories: 2, skipped: skips), "[SYNC] converge equal categories=2 skipped=0", "equal line")
    let off = SetupSourceChoice.forDevice(sum(("favorites", Cat(rows: 1, updatedAt: 1, fingerprint: "a")), ("progress", Cat(rows: 3, updatedAt: 1, fingerprint: "fp")))) { $0 == "favorites" }
    check(off.categories["favorites"] == nil, "Off item filtered")
    check(SetupSourceChoice.convergeSkips(off, off, skip: ["favorites": "unread"], lastPushed: [:]).isEmpty, "Off item not counted")

    // countLine
    eq(SetupSourceChoice.countLine(sum(("reminders", Cat(rows: 3, updatedAt: 1)), ("favorites", Cat(rows: 12, updatedAt: 1)),
                                       ("progress", Cat(rows: 8, updatedAt: 1)), ("watchlist", Cat(rows: 0, updatedAt: 1)))),
       "12 favorites, 8 in progress, 3 reminders", "countLineShowsNonZeroInOrder")
    eq(SetupSourceChoice.countLine(sum(("favorites", Cat(rows: 12, updatedAt: 1)), ("progress", Cat(rows: 8, updatedAt: 1)), ("reminders", Cat(rows: 3, updatedAt: 1)),
                                       ("watchlist", Cat(rows: 2, updatedAt: 1)), ("settings", Cat(rows: 40, updatedAt: 1)))),
       "12 favorites, 8 in progress, 3 reminders, 2 in Watchlist, and more", "countLineCapsAtFourThenAndMore")
    eq(SetupSourceChoice.countLine(sum(("favorites", Cat(rows: 1, updatedAt: 1)), ("progress", Cat(rows: 1, updatedAt: 1)),
                                       ("reminders", Cat(rows: 1, updatedAt: 1)), ("collections", Cat(rows: 1, updatedAt: 1)))),
       "1 favorite, 1 in progress, 1 reminder, 1 collection", "countLineExactlyFourHasNoAndMore")
    eq(SetupSourceChoice.countLine(.EMPTY), "Nothing saved yet", "countLineEmpty")

    let now: Int64 = 10_000_000_000
    eq(SetupSourceChoice.updatedLine(now - 5_000, nowMs: now), "Updated just now", "updated now")
    eq(SetupSourceChoice.updatedLine(now - 60_000, nowMs: now), "Updated 1 minute ago", "updated 1 minute")
    eq(SetupSourceChoice.updatedLine(now - 300_000, nowMs: now), "Updated 5 minutes ago", "updated 5 minutes")
    eq(SetupSourceChoice.updatedLine(now - 7_200_000, nowMs: now), "Updated 2 hours ago", "updated 2 hours")
    eq(SetupSourceChoice.updatedLine(now - 3 * 86_400_000, nowMs: now), "Updated 3 days ago", "updated 3 days")
    eq(SetupSourceChoice.updatedLine(0, nowMs: now), "Not updated yet", "not updated")

    let cats = Dictionary(uniqueKeysWithValues: SetupSourceChoice.SHARED.enumerated().map { ($0.element, Cat(rows: $0.offset + 1, updatedAt: 10, fingerprint: "fp\($0.offset)")) })
    eq(SetupSourceChoice.decide(Sum(categories: cats), Sum(categories: cats.mapValues { var c = $0; c.updatedAt = 99; return c })),
       .useDispatcharr, "allSharedCategoriesProvablyEqualPreferDispatcharr")
    var oneOff = cats; oneOff["favorites"] = Cat(rows: 1, updatedAt: 10, fingerprint: nil)
    check(isAsk(SetupSourceChoice.decide(Sum(categories: oneOff), Sum(categories: cats))), "oneUnresolvedCategoryStillAsks")

    eq(SetupSourceChoice.decisionName(.useCloud), "UseCloud", "decision name cloud")
    eq(SetupSourceChoice.decisionName(.useDispatcharr), "UseDispatcharr", "decision name dsync")
    eq(SetupSourceChoice.decisionName(.ask(cloud: .EMPTY, dsync: .EMPTY)), "Ask", "decision name ask")

    // forcedReplacePushesEmptyCategories
    for k in DsyncCoexistence.FORCE_KEYS {
        check(DsyncCoexistence.forcedWritesEmpty(force: true, key: k), "forced writes \(k)")
        check(!DsyncCoexistence.forcedWritesEmpty(force: false, key: k), "unforced \(k)")
    }
    check(!DsyncCoexistence.forcedWritesEmpty(force: true, key: .profiles), "profiles never forced")
    check(DsyncCoexistence.isEmptyData(.progress, obj(#"{"rows":[]}"#)), "empty rows")

    // forcedReplaceCancelledWhereDriveDidNotApply
    var allApplied: [DsyncCategory: Bool] = [:]
    for c in DsyncCategory.allCases { allApplied[c] = true }
    check(DsyncCoexistence.cancelledForceKeys(allApplied).isEmpty, "nothing cancelled")
    var partial = allApplied; partial[.watchProgress] = false; partial[.reminders] = nil
    eq(Set(DsyncCoexistence.cancelledForceKeys(partial)), [.progress, .reminders], "progress and reminders disarm")
    var favFail = allApplied; favFail[.favorites] = false
    eq(Set(DsyncCoexistence.cancelledForceKeys(favFail)), [.favorites, .recents, .collections], "favorites disarms three")
    var failed = allApplied; failed[.watchProgress] = false
    let armed = Set(DsyncCoexistence.armedForceKeys(failed))
    check(!armed.contains(.progress), "progress not armed")
    eq(armed.union(DsyncCoexistence.cancelledForceKeys(failed)), Set(DsyncCoexistence.FORCE_KEYS), "armed plus cancelled is all")
    check(armed.isDisjoint(with: DsyncCoexistence.cancelledForceKeys(failed)), "disjoint")

    check(!DsyncCoexistence.choiceHeld(until: 0, now: 5), "hold off")
    check(DsyncCoexistence.choiceHeld(until: 10, now: 5), "hold on")
    check(!DsyncCoexistence.choiceHeld(until: 10, now: 10), "hold expired")

    let lw = Sum(categories: ["favorites": Cat(rows: 2, updatedAt: 1_000), "settings": Cat(rows: 0, updatedAt: 9_000)], lastWrite: 9_000)
    eq(lw.updatedAt, 9_000, "lastWrite drives updated line")
    eq(Sum(categories: [:], lastWrite: 5).updatedAt, 0, "empty ignores lastWrite")

    for s in [SetupSourceChoice.TITLE, SetupSourceChoice.FOOTER] { check(!s.contains("\u{2014}"), "no em dash") }

    eq(SetupSourceChoice.freshDeviceHold(["favorites"], read: nil), "Dispatcharr pull not done", "hold before pull")
    eq(SetupSourceChoice.freshDeviceHold(["favorites", "recents"], read: ["favorites"]), "recents not pulled yet", "hold per name")
    eq(SetupSourceChoice.freshDeviceHold(["favorites"], read: ["favorites"]), nil, "released")
    eq(SetupSourceChoice.decideKnown(nil, .EMPTY), nil, "unknown side does not decide")
}

// MARK: - ConvergeRoundTripTest (Dispatcharr side, pure parts)

let nowS: Int64 = 2_000_000_000

func dsyncSummary(_ data: [(DsyncKey, DsyncObject)], scopes: [String: DsyncScope] = [:]) -> Sum {
    let cats = data.map { ($0.0, DsyncV2.encodeCategory(nil, deviceId: "dev", updatedAt: nowS - 5, data: $0.1)) }
    let raw = DsyncV2.encodeBucket(nil, deviceId: "dev", appVersion: "1", updatedAt: nowS - 5, replace: cats)
    let back = DsyncJSONParser.parseObject(DsyncJSONEncoder.encode(raw))!
    guard let bucket = DsyncV2.decode(back).bucket else { fatalError("bucket did not decode") }
    return DsyncCoexistence.summarize(bucket, scopes: scopes)
}

let wireLanes: [String: [String: DsyncJSON]] = [
    "v": ["trueBlack": .bool(true), "textScale": .int(1), "customAccentHex": .string("FF00AA"), "defaultTab": .string("guide")],
    "mobile": ["skipBack": .double(10.0)],
]

func dsyncData(_ full: Bool, _ lanes: [String: [String: DsyncJSON]]) -> [(DsyncKey, DsyncObject)] {
    [
        (.favorites, DsyncPayloads.encodeFavorites(nil, full ? [2, 1] : [])),
        (.progress, DsyncPayloads.encodeProgress(nil, full ? [
            ProgressRow(vodId: 11, type: "m", position: 10, duration: 100, updatedAt: nowS - 1, finished: false, seriesId: nil, season: 0, episode: 0, title: "M"),
            ProgressRow(vodId: 21, type: "e", position: 10, duration: 100, updatedAt: nowS - 2, finished: false, seriesId: 7, season: 1, episode: 1, title: "E"),
        ] : [], now: nowS)),
        (.reminders, DsyncPayloads.encodeReminders(nil, full ? [ReminderRow(channelId: 5, start: nowS + 60, end: nowS + 120, title: "T", channelName: "News")] : [], now: nowS)),
        (.watchlist, DsyncPayloads.encodeVodMarks(nil, full ? [VodMarkRow(vodId: 42, type: "s", at: 1), VodMarkRow(vodId: 11, type: "m", at: 1)] : [], cap: 500)),
        (.hiddenTitles, DsyncPayloads.encodeVodMarks(nil, full ? [VodMarkRow(vodId: 12, type: "m", at: 1)] : [], cap: 500)),
        (.recents, DsyncPayloads.encodeRecents(nil, full ? [RecentRow(channelId: 1, watchedAt: 1), RecentRow(channelId: 3, watchedAt: 2)] : [])),
        (.collections, DsyncPayloads.encodeCollections(nil, full ? [CollectionRow(id: "c1", name: "Sports", placement: "b", members: [2, 1])] : [])),
        (.hiddenGroups, DsyncPayloads.encodeHiddenGroups(nil, full ? .init(live: ["Adult"], movies: [], series: ["Kids"]) : .init(live: [], movies: [], series: []))),
        (.groupOrder, DsyncPayloads.encodeGroupOrder(nil, full ? .init(mode: "manual", order: ["News", "Sports"]) : .init(mode: "default", order: []))),
        (.settings, DsyncPayloads.encodeSettingsLanes(nil, lanes)),
    ]
}

/// The cloud side as the converge sees it after a push of the same rows,
/// built from canonical items (the iCloud snapshot builders land later).
func cloudSummary(full: Bool, cloudLanes: [String: [String: String]]) -> Sum {
    func c(_ items: [String]) -> Cat { Cat(rows: items.count, updatedAt: 1, fingerprint: SetupSourceChoice.fingerprint(items)) }
    var out: [String: Cat] = [
        "favorites": c(full ? ["1", "2"] : []),
        "progress": c(full ? ["m|11", "e|21"] : []),
        "reminders": c(full ? ["News|\(nowS + 60)"] : []),
        "watchlist": c(full ? ["m|11", "s|42"] : []),
        "hiddenTitles": c(full ? ["m|12"] : []),
        "recents": c(full ? ["1", "3"] : []),
        "collections": c(full ? [CloudCanon.collectionItem("c1", "Sports", "b", [1, 2])] : []),
        "hiddenGroups": c(full ? ["live|Adult", "series|Kids"] : []),
        "groupOrder": Cat(rows: full ? 2 : 0, updatedAt: 1, fingerprint: SetupSourceChoice.fingerprint(full ? ["0|News", "1|Sports", "mode|manual"] : ["mode|default"])),
    ]
    out["settings"] = CloudCanon.settingsCategory(cloudLanes, updatedAt: 1)
    return Sum(categories: out)
}

// Cloud writes strings; another device (or Android) sends 1 for 1.0 and uppercase hex without "#".
let cloudLanes: [String: [String: String]] = [
    "v": ["trueBlack": "true", "textScale": "1.0", "customAccentHex": "#ff00aa", "defaultTab": "guide"],
    "mobile": ["skipBack": "10"],
]

do {
    // equalDataFingerprintsEqualAfterBothEncoders
    let x = dsyncSummary(dsyncData(true, wireLanes))
    let d = cloudSummary(full: true, cloudLanes: cloudLanes)
    for n in SetupSourceChoice.SHARED {
        check(SetupSourceChoice.categoryEqual(d.categories[n], x.categories[n]), "\(n) cloud=\(String(describing: d.categories[n])) dsync=\(String(describing: x.categories[n]))")
        check((x.categories[n]?.rows ?? 0) > 0, "\(n) has rows")
    }
    eq(SetupSourceChoice.decide(d, x), .useDispatcharr, "equal data uses Dispatcharr")

    // pushRowCountEqualsProbeCountForEveryCategory
    let data = dsyncData(true, wireLanes)
    eq(Set(SetupSourceChoice.SHARED), Set(DsyncCoexistence.FORCE_KEYS.map(\.suffix)), "shared names are the forced keys")
    for (key, v) in data { eq(DsyncCoexistence.rowCount(key, v), x.rows(key.suffix), "\(key) push vs probe") }
    let many = (1...60).map { RecentRow(channelId: $0, watchedAt: Int64($0)) } + [RecentRow(channelId: 60, watchedAt: 1)]
    eq(DsyncCoexistence.rowCount(.recents, DsyncPayloads.encodeRecents(nil, many)), 50, "recents cap and dedupe")

    // emptyCategoriesEqualOnBothSides
    let xe = dsyncSummary(dsyncData(false, [:]))
    let de = cloudSummary(full: false, cloudLanes: [:])
    for n in SetupSourceChoice.SHARED { check(SetupSourceChoice.categoryEqual(de.categories[n], xe.categories[n]), "\(n) empty equal") }
    check(SetupSourceChoice.convergePlan(de, xe, skip: [], lastPushed: [:]).isEmpty, "empty converge plan")

    // categoryOffOnThisDeviceIsNeitherComparedNorConverged
    let scopes: [String: DsyncScope] = ["favorites": .off, "trueBlack": .off]
    let xo = dsyncSummary([(.favorites, DsyncPayloads.encodeFavorites(nil, [2, 1])),
                           (.settings, DsyncPayloads.encodeSettingsLanes(nil, ["v": ["trueBlack": .bool(true)]]))], scopes: scopes)
    check(xo.categories["favorites"] == nil, "Off favorites not summarized")
    eq(xo.rows("settings"), 0, "Off setting name not counted")

    // convergeNeverPingPongsWhenOnePushCannotEqualize
    let stuck = cloudSummary(full: false, cloudLanes: [:])
    let first = SetupSourceChoice.convergePlan(stuck, x, skip: [], lastPushed: [:])
    eq(Set(first), Set(SetupSourceChoice.SHARED), "first converge pushes every category")
    var marks: [String: String] = [:]
    for n in first { marks[n] = SetupSourceChoice.convergeMark(x.categories[n]) }
    check(SetupSourceChoice.convergePlan(stuck, x, skip: [], lastPushed: marks).isEmpty, "no second push for the same state")
    var data2 = dsyncData(true, wireLanes)
    data2[0] = (.favorites, DsyncPayloads.encodeFavorites(nil, [3]))
    eq(SetupSourceChoice.convergePlan(stuck, dsyncSummary(data2), skip: [], lastPushed: marks), ["favorites"], "new state converges again")
    check(!SetupSourceChoice.convergePlan(stuck, x, skip: ["favorites"], lastPushed: [:]).contains("favorites"), "pendingLocalChangeIsSkipped")

    // canonValueSpellings
    eq(CloudCanon.canonValue("1.0"), "1", "canon 1.0")
    eq(CloudCanon.canonValue("1.5"), "1.5", "canon 1.5")
    eq(CloudCanon.canonValue("True"), "true", "canon True")
    eq(CloudCanon.canonValue("#ff00aa"), "FF00AA", "canon hex")
    eq(CloudCanon.canonValue("guide"), "guide", "canon string")
}

// MARK: - Lane rules (schema 4.9, the seven rules), DsyncV2, caps

do {
    eq(DsyncScope.tv.effective(isTv: false), .all, "rule 1: other class reads as All")
    eq(DsyncScope.mobile.effective(isTv: true), .all, "rule 1 on a TV")
    eq(DsyncScope.choices(isTv: true), [.all, .tv, .off], "TV choices")
    eq(DsyncScope.tv.lane(isTv: true), "tv", "rule 2/3: TV lane")
    eq(DsyncScope.off.lane(isTv: true), nil, "rule 5: Off has no lane")
    let scopeOf: (String) -> DsyncScope = { ["a": .mobile, "b": .off, "c": .all][$0] ?? .all }
    let lanes = laneValues([("a", 1), ("b", 2), ("c", 3)], scopeOf: scopeOf, isTv: false)
    eq(lanes, ["mobile": ["a": 1], "v": ["c": 3]], "rule 2/3/5: push lanes")
    let picked = pickFromLanes(["v": ["a": 9, "c": 3], "mobile": ["a": 1], "tv": ["c": 7]], names: ["a", "b", "c"], scopeOf: scopeOf, isTv: false)
    eq(picked, ["a": 1, "c": 3], "rule 4: no cross-lane fallback")
    let rt = DsyncPayloads.encodeSettingsLanes(obj(#"{"v":{"other":1},"tv":{"x":true},"zz":{}}"#), ["v": ["mine": .int(2)]])
    eq(DsyncJSONEncoder.encode(rt), #"{"v":{"other":1,"mine":2},"tv":{"x":true},"zz":{}}"#, "rule 7: names not written round-trip")

    // DsyncV2 decode, unknown members, trims, migrate.
    let prev = obj(#"{"schemaVersion":3,"deviceId":"a","platform":"android","appVersion":"0.5","updatedAt":"2026-11-01T00:00:00Z","categories":{"future":{"x":1},"favorites":{"updatedAt":"2026-11-01T00:00:00Z","deviceId":"a","data":{"ids":[1]},"extra":{"k":1}}},"newTop":true}"#)
    let sub = DsyncV2.encodeCategory(DsyncV2.decode(prev).bucket!.categories["favorites"], deviceId: "me", updatedAt: nowS, data: DsyncPayloads.encodeFavorites(nil, [4]))
    let put = DsyncV2.encodeBucket(prev, deviceId: "me", appVersion: "1.8", updatedAt: nowS, replace: [(.favorites, sub)])
    let pb = DsyncV2.decode(put).bucket!
    check(pb.categories["future"] != nil, "unknown category round-trips")
    eq(put["newTop"], .bool(true), "unknown envelope member round-trips")
    eq(DsyncV2.category(pb, .favorites)?.envelope?.extra, obj(#"{"k":1}"#), "extra round-trips")
    eq(pb.platform, DsyncPlatform.current, "platform string")
    eq(DsyncV2.decode(obj(#"{"schemaVersion":4,"deviceId":"a","platform":"x","appVersion":"1","updatedAt":"2026-11-01T00:00:00Z"}"#)), .tooNew(4), "too new")
    eq(DsyncV2.decode(obj(#"{"schemaVersion":3,"deviceId":"a"}"#)), .malformed, "malformed envelope")
    eq(DsyncEnvelopeCodec.isoSeconds(0), "1970-01-01T00:00:00Z", "ISO seconds")
    eq(DsyncEnvelopeCodec.parseIso("2026-11-01T00:00:00.500Z"), 1_793_491_200, "fractional ISO")
    check(DsyncEnvelopeCodec.remoteWins(localAt: 1, localDevice: "a", remoteAt: 1, remoteDevice: "b"), "tie goes to higher deviceId")

    let rows = (0..<250).map { ProgressRow(vodId: $0, type: "m", position: 1, duration: 2, updatedAt: nowS - Int64($0), finished: false, seriesId: nil, season: 0, episode: 0, title: "t") }
    let big = DsyncV2.encodeBucket(nil, deviceId: "me", appVersion: "1", updatedAt: nowS,
                                   replace: [(.progress, DsyncV2.encodeCategory(nil, deviceId: "me", updatedAt: nowS, data: DsyncPayloads.encodeProgress(nil, rows, now: nowS)))])
    let t0 = DsyncV2.applyTrim(big, 0)!
    eq(DsyncCoexistence.rowCount(.progress, DsyncV2.category(DsyncV2.decode(t0).bucket!, .progress)!.envelope!.data), 200, "trim progress to 200")
    eq(DsyncV2.applyTrim(big, 2), nil, "absent category trim skipped")
    eq(DsyncLimits.KEY_BYTES, 131_072, "128 KiB per key (Dispatcharr APP_DATA_MAX_VALUE_BYTES)")
    eq(DsyncLimits.TOTAL_BYTES, 1_048_576, "1 MiB per user (APP_DATA_MAX_TOTAL_BYTES)")
    check(DsyncKey.isValidKeyName(DsyncBucket.main.wire("logan.aeriotv")), "bucket key matches the server key pattern")

    // Key derivation vectors (identical in the Android DsyncV2Test).
    let vectors: [(String, String?)] = [
        ("Logan", "logan.aeriotv"),
        ("john.doe-1_x", "john.doe-1_x.aeriotv"),
        ("a@b.com", "a-40b.com.aeriotv"),
        ("first+tag", "first-2btag.aeriotv"),
        ("_admin", "u_admin.aeriotv"),
        ("Jos\u{E9}", "jos-c3-a9.aeriotv"),
        ("ADMIN", "admin.aeriotv"),
        ("", nil),
        (String(repeating: "a", count: 60), String(repeating: "a", count: 46) + ".aeriotv"),
    ]
    for (u, want) in vectors {
        eq(DsyncKeyName.main(u), want, "key for \(u.prefix(12))")
        if let w = want { check(DsyncKey.isValidKeyName(w + ".favorites"), "suffixed key valid for \(u.prefix(12))") }
    }
    eq(DsyncKeyName.v2Wires("logan.aeriotv"), ["logan.aeriotv", "logan.aeriotv.favorites", "logan.aeriotv.progress"], "v2 wires under the new name")
    check(DsyncKeyName.isLegacy("app.molinete.aerio") && DsyncKeyName.isLegacy("app.molinete.aerio.favorites"), "legacy keys")
    check(!DsyncKeyName.isLegacy("app.molinete.aeriotv") && !DsyncKeyName.isLegacy("logan.aeriotv"), "not legacy")
    check(DsyncKeyName.isMain("logan.aeriotv") && !DsyncKeyName.isMain(".aeriotv"), "main key shape")

    // Rename plan and value.
    eq(DsyncKeyName.renamePlan(listed: ["other", "app.molinete.aerio.progress", "app.molinete.aerio"], main: "logan.aeriotv"),
       ["app.molinete.aerio", "app.molinete.aerio.progress"], "absent new key: every legacy key, sorted")
    eq(DsyncKeyName.renamePlan(listed: ["logan.aeriotv", "app.molinete.aerio"], main: "logan.aeriotv"), [], "new key present: no migration")
    eq(DsyncKeyName.renamePlan(listed: ["other"], main: "logan.aeriotv"), [], "nothing legacy: no migration")
    let legacyV3 = DsyncV2.encodeBucket(nil, deviceId: "old", appVersion: "1", updatedAt: nowS,
                                        replace: [(.favorites, DsyncV2.encodeCategory(nil, deviceId: "old", updatedAt: nowS, data: DsyncPayloads.encodeFavorites(nil, [4, 5])))])
    let renamed = DsyncKeyName.renameValue([("app.molinete.aerio", legacyV3)], deviceId: "me", appVersion: "2", now: nowS)
    eq(renamed, legacyV3, "legacy v3 alone moves unchanged")
    let v1Newer = DsyncEnvelopeCodec.encode(key: .favorites, previous: nil, deviceId: "z", appVersion: "1", updatedAt: nowS + 100, data: DsyncPayloads.encodeFavorites(nil, [9]))
    let merged = DsyncKeyName.renameValue([("app.molinete.aerio", legacyV3), ("app.molinete.aerio.favorites", v1Newer)], deviceId: "me", appVersion: "2", now: nowS)!
    eq(DsyncPayloads.decodeFavorites(DsyncV2.category(DsyncV2.decode(merged).bucket!, .favorites)!.envelope!.data), [9], "newer legacy v1 wins the rename")
    eq(DsyncKeyName.renameValue([("app.molinete.aerio", obj(#"{"x":1}"#))], deviceId: "me", appVersion: "2", now: nowS), nil, "undecodable legacy value: nothing to put")
    check(!DsyncKey.isValidKeyName("short"), "short key rejected")

    let v1fav = DsyncEnvelope(schemaVersion: 1, deviceId: "z", platform: "ios", appVersion: "1", updatedAt: nowS + 100,
                              data: DsyncPayloads.encodeFavorites(nil, [9]), extra: nil, raw: DsyncObject())
    let migrated = DsyncV2.migrate(v1: [(.favorites, v1fav)], v2: [], v3: prev, deviceId: "me", appVersion: "1", now: nowS)!
    eq(DsyncPayloads.decodeFavorites(DsyncV2.category(DsyncV2.decode(migrated).bucket!, .favorites)!.envelope!.data), [9], "newer v1 wins the migration")
    eq(DsyncV2.migrate(v1: [], v2: [], v3: prev, deviceId: "me", appVersion: "1", now: nowS), nil, "nothing to migrate")

    // Payload codecs keep trailing positions (rule 6.2) and caps.
    let p = DsyncPayloads.decodeProgress(obj(#"{"rows":[[1,"m",5,9,100,0,null,0,0,"T","future"]]}"#))!
    eq(p[0].tail.extra, [.string("future")], "tail decoded")
    eq(DsyncJSONEncoder.encode(DsyncPayloads.progressRowJson(p[0])), #"[1,"m",5,9,100,0,null,0,0,"T","future"]"#, "tail re-emitted")
    let finishedOld = ProgressRow(vodId: 1, type: "m", position: 1, duration: 1, updatedAt: nowS - 31 * 86_400, finished: true, seriesId: nil, season: 0, episode: 0, title: "")
    check(DsyncPayloads.capProgress([finishedOld], now: nowS).isEmpty, "finished older than 30 days dropped")
    eq(DsyncPayloads.decodeFavorites(obj(#"{"ids":[1,"x"]}"#)), nil, "wrong shape is malformed")

    // Settings validator.
    check(DsyncSettingsValidator.accepts("skipBack", .int(10)), "skip 10 ok")
    check(!DsyncSettingsValidator.accepts("skipBack", .int(11)), "skip 11 rejected")
    check(!DsyncSettingsValidator.accepts("textScale", .string("1.0")), "string for a double rejected")
    check(DsyncSettingsValidator.accepts("textScale", .double(1.0)), "double ok")
    check(DsyncSettingsValidator.accepts("customAccentHex", .string("")), "empty accent ok")
    check(DsyncSettingsValidator.accepts("categoryColor.sports", .string("#FF0000")), "category color ok")
    check(!DsyncSettingsValidator.accepts("unknownName", .bool(true)), "unknown name rejected")
    let f = DsyncSettingsValidator.filter(["trueBlack": .bool(true), "selectedTheme": .string("Nope")])
    eq(f.accepted, ["trueBlack": .bool(true)], "filter accepted")
    eq(f.ignored, [#"selectedTheme="Nope""#], "filter ignored line")

    // PIN hash (schema 4.12).
    eq(DsyncPinHash.hash(saltHex: "00ff", normalizedPin: "1234")?.count, 64, "sha256 hex")
    eq(DsyncPinHash.hash(saltHex: "0", normalizedPin: "1"), nil, "odd hex rejected")

    // Profiles tombstones.
    let r1 = ProfileRow(userId: 1, username: "Ann", displayName: "A", pinType: "none", pinHash: "", pinSalt: "", updatedAt: 10)
    let res = ProfileTombstones.resolve([r1], [ProfileTombstone(username: "ann", removedAt: 20)])
    check(res.rows.isEmpty && res.dropped.count == 1, "tombstone removes an older row")
}


// MARK: - Manager rules (DispatcharrSyncManager processCategory, writeLocked, onLocalChange)

do {
    let empty = obj(#"{"ids":[]}"#)
    let full = obj(#"{"ids":[1,2]}"#)
    func d(_ key: DsyncKey = .favorites, forced: Bool = false, consumed: Bool = true, data: DsyncObject? = nil,
           localAt: Int64 = 100, remoteAt: Int64 = 200, dirty: Bool = false, dirtyAt: Int64 = 0, forceApply: Bool = false) -> DsyncPullAction {
        DsyncPullRules.decide(key, forced: forced, consumedBefore: consumed, data: data ?? full,
                              localAt: localAt, localDevice: "A", remoteAt: remoteAt, remoteDevice: "B",
                              dirty: dirty, dirtyAt: dirtyAt, forceApply: forceApply)
    }
    eq(d(forced: true), .forcedSkip, "forced key is consumed, not applied")
    eq(d(consumed: false, data: empty), .seedFromLocal, "empty server on first read seeds from local")
    eq(d(consumed: true, data: empty), .apply, "empty server after a consumed read applies (newer)")
    eq(d(), .apply, "newer server copy applies")
    eq(d(dirty: true), .merge, "row key with an unsent change merges")
    eq(d(.hiddenGroups, data: obj(#"{"live":["a"]}"#), dirty: true, dirtyAt: 300), .keepLocal, "newer local whole value kept")
    eq(d(.hiddenGroups, data: obj(#"{"live":["a"]}"#), dirty: true, dirtyAt: 150), .apply, "older local whole value replaced")
    eq(d(localAt: 300, remoteAt: 200), .notNewer, "consumed stamp is not newer")
    eq(d(localAt: 300, remoteAt: 200, forceApply: true), .choiceApply, "setup choice applies a not-newer key")
    eq(d(localAt: 300, remoteAt: 200, dirty: true, forceApply: true), .notNewer, "setup choice keeps an unsent change")
    eq(d(.profiles, localAt: 300, remoteAt: 200), .merge, "profiles merge per row on every pull")

    check(DsyncPullRules.shouldSkipBucketGet(lastPullAt: 1_000, now: 30_000, fetchedBytes: 50, listedBytes: 50), "same size within a minute skips")
    check(!DsyncPullRules.shouldSkipBucketGet(lastPullAt: 1_000, now: 70_000, fetchedBytes: 50, listedBytes: 50), "a minute later fetches")
    check(!DsyncPullRules.shouldSkipBucketGet(lastPullAt: 1_000, now: 30_000, fetchedBytes: 50, listedBytes: 51), "size change fetches")
    check(!DsyncPullRules.shouldSkipBucketGet(lastPullAt: 0, now: 30_000, fetchedBytes: 50, listedBytes: 50), "first pull fetches")
    check(DsyncPullRules.resendReason("launch") && DsyncPullRules.resendReason("reconnect") && !DsyncPullRules.resendReason("periodic"), "resend reasons")
    check(DsyncPullRules.sameAsConsumed(remoteAt: 5, remoteDevice: "A", remoteData: full, localAt: 5, localDevice: "A", localData: full), "consumed copy")
    check(!DsyncPullRules.sameAsConsumed(remoteAt: 5, remoteDevice: "A", remoteData: full, localAt: 5, localDevice: "A", localData: empty), "changed data")

    // "status=unchanged": compare with the server copy just fetched, not the saved one.
    check(DsyncPushRules.unchanged(built: full, serverData: full, lastData: empty, present: true), "server copy equal")
    check(!DsyncPushRules.unchanged(built: full, serverData: obj(#"{"ids":[1,2,3]}"#), lastData: full, present: true), "fresh server copy wins over a stale saved one")
    check(DsyncPushRules.unchanged(built: full, serverData: nil, lastData: full, present: true), "saved copy when the fetch had none")
    check(!DsyncPushRules.unchanged(built: full, serverData: full, lastData: nil, present: false), "absent category always puts")
    check(!DsyncPushRules.unchanged(built: obj(#"{"ids":[2,1]}"#), serverData: full, lastData: nil, present: true), "order matters (text compare)")
    check(DsyncPushRules.logsUnchanged(force: true, dirty: false, key: .remoteMap), "forced logs")
    check(DsyncPushRules.logsUnchanged(force: false, dirty: true, key: .favorites), "dirty shared logs")
    check(!DsyncPushRules.logsUnchanged(force: false, dirty: true, key: .remoteMap), "dirty non-shared quiet")

    // Debounce and the local-change gate.
    eq(DsyncPushRules.debounceMs(.favorites), 5_000, "5 s debounce")
    eq(DsyncPushRules.debounceMs(.profiles), 1_000, "profiles 1 s")
    check(DsyncPushRules.acceptLocalChange(sessionLive: true, suppressUntilMs: nil, nowMs: 10), "live change accepted")
    check(!DsyncPushRules.acceptLocalChange(sessionLive: true, suppressUntilMs: 20, nowMs: 10), "apply echo suppressed")
    check(DsyncPushRules.acceptLocalChange(sessionLive: true, suppressUntilMs: 10, nowMs: 10), "window over")
    check(!DsyncPushRules.acceptLocalChange(sessionLive: false, suppressUntilMs: nil, nowMs: 10), "no session")
    eq(DsyncTiming.backoff(0), 30_000, "backoff 1")
    eq(DsyncTiming.backoff(2), 600_000, "backoff 3")
    eq(DsyncTiming.backoff(3), nil, "backoff spent")
    eq(DsyncTiming.reconnect(0), 2_000, "reconnect 1")
    eq(DsyncTiming.reconnect(9), 60_000, "reconnect then every 60 s")

    // Converge gating and skip reasons.
    eq(DsyncPushRules.convergeSkip(forced: true, awaiting: true, pending: true, read: false, dirty: true, partial: false), "armed", "armed first")
    eq(DsyncPushRules.convergeSkip(forced: false, awaiting: true, pending: true, read: true, dirty: true, partial: false), "deferred", "deferred")
    eq(DsyncPushRules.convergeSkip(forced: false, awaiting: false, pending: true, read: true, dirty: false, partial: false), "dirty", "queued write")
    eq(DsyncPushRules.convergeSkip(forced: false, awaiting: false, pending: false, read: false, dirty: false, partial: false), "unread", "unread")
    eq(DsyncPushRules.convergeSkip(forced: false, awaiting: false, pending: false, read: true, dirty: true, partial: true), nil, "partial is compared")
    check(DsyncPushRules.convergeAllowed(isBase: true, choiceHeld: false, running: false, anyForced: false, choicePending: false), "converge allowed")
    check(!DsyncPushRules.convergeAllowed(isBase: true, choiceHeld: true, running: false, anyForced: false, choicePending: false), "no converge in a hold")
    check(!DsyncPushRules.convergeAllowed(isBase: true, choiceHeld: false, running: false, anyForced: true, choicePending: false), "no converge while armed")
    check(!DsyncPushRules.convergeAllowed(isBase: true, choiceHeld: false, running: false, anyForced: false, choicePending: true), "no converge with a prompt pending")

    // Favorites apply plan.
    let plan = DsyncFavoritesRules.plan(ids: [3, 1, 9, 3], toLocal: [1: "1", 2: "2", 3: "3"], toInt: ["1": 1, "2": 2, "3": 3],
                                        local: ["2", "x", "1"])
    eq(plan.wanted, ["3", "1"], "mapped in server order, distinct")
    eq(plan.deletes, ["2"], "mapped local dropped by the server")
    eq(plan.order, ["3", "1", "x"], "unmapped local kept after")
    eq(DsyncFavoritesRules.logLine("in", ids: 4, mapped: 2, written: 2, scope: "", playlistId: "ABCDEFGHIJ"),
       "[DSYNC] favorites in: 4 ids, 2 mapped, 2 written, scope=default, playlist=ABCDEFGH", "favorites log line")

    // Recents stamps and apply.
    let st = DsyncRecentsRules.stamp(ids: ["b", "a"], previousHead: "a", stamps: ["a": 50, "z": 1], now: 100)
    eq(st.stamps, ["b": 100, "a": 50], "new head stamped now, stale ids dropped")
    eq(st.head, "b", "head recorded")
    let lr = DsyncRecentsRules.localRows(ids: ["b", "q", "a"], toInt: ["a": 1, "b": 2], stamps: ["b": 100], now: 100)
    eq(lr, [RecentRow(channelId: 2, watchedAt: 100), RecentRow(channelId: 1, watchedAt: 98)], "local rows with fallback stamps")
    let ap = DsyncRecentsRules.applied(local: lr, remote: [RecentRow(channelId: 3, watchedAt: 200), RecentRow(channelId: 1, watchedAt: 99)],
                                       ids: ["b", "q", "a"], toInt: ["a": 1, "b": 2, "c": 3], toLocal: [1: "a", 2: "b", 3: "c"])
    eq(ap.ids, ["c", "b", "a", "q"], "merged newest first, unmapped local after")

    // Reminders apply plan.
    let rp = DsyncRemindersRules.plan(
        rows: [ReminderRow(channelId: 1, start: 1_000, end: 2_000, title: "A", channelName: "One"),
               ReminderRow(channelId: 2, start: 10, end: 20, title: "Old", channelName: "Two"),
               ReminderRow(channelId: 3, start: 1_000, end: 2_000, title: "C", channelName: "Three")],
        nowMs: 500_000,
        local: [.init(key: "k1", channelName: "One", startS: 1_000), .init(key: "k2", channelName: "Two", startS: 5),
                .init(key: "k3", channelName: "Gone", startS: 1)],
        intByName: ["One": 1, "Two": 2], toLocal: [1: "1", 2: "2"])
    eq(rp.removeKeys, ["k2"], "a mapped local row the server dropped is removed; unmapped kept")
    eq(rp.add.map(\.title), [], "already present, expired, and unmappable rows not added")
}

// MARK: - Settings name map (DsyncItemCatalog names to Apple UserDefaults keys)

do {
    let theme = DsyncSettingsMap.entry("selectedTheme")!
    eq(DsyncSettingsMap.toApple(theme, .string("Midnight")) as? String, "midnight", "theme to Apple")
    eq(DsyncSettingsMap.fromApple(theme, "midnight"), .string("Midnight"), "theme from Apple")
    let tab = DsyncSettingsMap.entry("defaultTab")!
    eq(DsyncSettingsMap.toApple(tab, .string("TVShows")) as? String, "tvshows", "tab to Apple")
    eq(DsyncSettingsMap.fromApple(tab, "favorites"), nil, "an Apple-only tab has no schema spelling")
    let hex = DsyncSettingsMap.entry("categoryColor.sports")!
    eq(hex.appleKey, "categoryColor.sports", "prefix family keeps its name")
    eq(DsyncSettingsMap.toApple(hex, .string("#ff0000")) as? String, "FF0000", "hex stored without # uppercased")
    eq(DsyncSettingsMap.toApple(DsyncSettingsMap.entry("customAccentHex")!, .string("")) as? String, nil, "empty accent leaves local")
    eq(DsyncSettingsMap.entry("skipBack")!.appleKey, "skipBackSeconds", "skip back key")
    eq(DsyncSettingsMap.fromApple(DsyncSettingsMap.entry("textScale")!, 1.0), .double(1.0), "double spelling")
    eq(DsyncSettingsMap.fromApple(DsyncSettingsMap.entry("trueBlack")!, NSNumber(value: true)), .bool(true), "NSNumber bool")
    check(DsyncSettingsMap.entry("guideGroupSelector") == nil, "unverified names are not mapped")
    for e in DsyncSettingsMap.ENTRIES { check(DsyncSettingsValidator.isOwned(e.name), "mapped name \(e.name) is a schema name") }
    check(Set(DsyncSettingsMap.ENTRIES.map(\.name)).count == DsyncSettingsMap.ENTRIES.count, "names unique")
    check(Set(DsyncSettingsMap.ENTRIES.map(\.appleKey)).count == DsyncSettingsMap.ENTRIES.count, "Apple keys unique")
}

// MARK: - Cloud snapshots (DriveCanonTest, DriveSnapshotRulesTest, HeldProgressTest snapshot parts)

do {
    let env = CloudCanon.writerEnvelope(nowMs: 1_000, device: "iPhone", providers: nil)
    eq(env.format, 2, "every write carries format 2")
    let fav = CloudFavorites(envelope: env, entries: [CloudFavoriteEntry(channelId: "11", channelName: "One", displayOrder: 0, addedAt: 5)])
    let text = fav.text
    check(text.contains(#""channelId":"11""#) && text.contains(#""dispatcharrChannelId":null"#) && text.contains(#""format":2"#),
          "Android field names on the wire")
    eq(CloudFavorites.decode(text: text), fav, "favorites round trip")
    let old = #"{"envelope":{"version":1,"lastModified":5,"device":"x","extra":1},"entries":[{"channelId":"3","channelName":"c","displayOrder":1,"addedAt":2}]}"#
    eq(CloudCanon.envelopeFormat(old), nil, "older file has no format")
    check(CloudCanon.isOldFormat(nil) && CloudCanon.isOldFormat(1) && !CloudCanon.isOldFormat(2), "null or < 2 is old")
    check(CloudCanon.backupOutdated([2, nil]) && !CloudCanon.backupOutdated([2, 2]) && !CloudCanon.backupOutdated([]), "any present old file")
    eq(CloudCanon.oldFormatNames([("Favorites", nil), ("WatchProgress", 2), ("Preferences", 1)]), ["Favorites", "Preferences"], "old names in order")
    let stamped = CloudCanon.stampFormat(old)!
    eq(CloudCanon.envelopeFormat(stamped), 2, "stamp sets format 2")
    check(stamped.contains(#""extra":1"#) && stamped.contains(#""channelId":"3""#), "stamp keeps every other field")
    eq(CloudCanon.stampFormat(#"{"entries":[]}"#), nil, "no envelope, no stamp")
    eq(CloudCanon.pendingCategories(accepted: false, all: ["a", "b"], done: { _ in false }), [], "never without Update backup")
    eq(CloudCanon.pendingCategories(accepted: true, all: ["a", "b"], done: { $0 == "a" }), ["b"], "done files skipped")

    // Enrichment fills only unresolved rows.
    let (ef, n) = CloudCanon.enrichFavorites(CloudFavorites.decode(text: old)!, CloudCanon.Ids(channels: ["3": 30]))
    eq(n, 1, "one favorite enriched")
    eq(ef.entries[0].dispatcharrChannelId, 30, "canonical channel id")
    let wl = CloudWatchlist(envelope: env, entries: [CloudWatchlistEntry(vodId: "7", vodType: "series", title: "S", addedAt: 1),
                                                     CloudWatchlistEntry(vodId: "8", title: "M", addedAt: 1)],
                            hidden: [CloudHiddenEntry(vodId: "9", hiddenAt: 1)])
    let (ew, nw, nh) = CloudCanon.enrichWatchlist(wl, CloudCanon.Ids(movies: ["8": 8, "9": 9]))
    eq([nw, nh], [2, 1], "series ids are local integers, movies via the map")
    eq(ew.hidden[0].dispatcharrVodId, 9, "hidden row id")
    let pr = CloudPreferences(envelope: env, keys: [CloudCanon.K_RECENTS: "1\n2", CloudCanon.K_COLLECTIONS:
        CloudCanon.encodeCollections([.init(id: "c1", name: "Kids", memberIds: ["2", "3"], placement: "beginning")])])
    let (ep, np) = CloudCanon.enrichPreferences(pr, CloudCanon.Ids(channels: ["1": 10, "2": 20]))
    eq(np, 2, "recents and collection channels mapped")
    eq(ep.dispatcharrChannelIds, ["1": 10, "2": 20], "map written")
    eq(CloudPreferences.decode(text: ep.text)?.dispatcharrChannelIds, ["1": 10, "2": 20], "map round trip")
    eq(CloudCanon.collectionsCategory(ep, .init()).fingerprint, nil, "an unresolved member leaves the fingerprint nil")
    eq(CloudCanon.recentsCategory(ep, .init()).rows, 2, "recents from the stored map")

    // Single progress builder: local rows, held placeholders, the last Dispatcharr rows; resolved local wins.
    let local = CloudProgress(envelope: env, entries: [
        CloudProgressEntry(videoId: "11", title: "Local", positionMs: 1_000, durationMs: 9_000, updatedAt: 5_000, dispatcharrVodId: 11),
        CloudProgressEntry(videoId: "uuid-12", title: "Unmapped", positionMs: 1, durationMs: 2, updatedAt: 1),
        CloudProgressEntry(videoId: "dsync:m:99", title: "Stale", positionMs: 0, durationMs: 0, updatedAt: 0, dispatcharrVodId: 99)])
    let extra = [ProgressRow(vodId: 11, type: "m", position: 3, duration: 9, updatedAt: 9, finished: false, seriesId: nil, season: 0, episode: 0, title: "Srv"),
                 ProgressRow(vodId: 12, type: "m", position: 3, duration: 9, updatedAt: 9, finished: false, seriesId: nil, season: 0, episode: 0, title: "U"),
                 ProgressRow(vodId: 13, type: "e", position: 3, duration: 9, updatedAt: 9, finished: true, seriesId: 4, season: 1, episode: 2, title: "Ep")]
    let snap = CloudCanon.progressSnapshot(local, extra: extra) { t, id in id == 12 && t == "m" ? "uuid-12" : nil }
    eq(snap.entries.map(\.videoId), ["11", "uuid-12", "dsync:e:13"], "resolved local wins, stale placeholder replaced, held rides")
    eq(snap.entries[1].dispatcharrVodId, 12, "reverse id fills the local row")
    eq(CloudCanon.heldRow(snap.entries[2]), ProgressRow(vodId: 13, type: "e", position: 3, duration: 9, updatedAt: 9, finished: true,
                                                         seriesId: 4, season: 1, episode: 2, title: "Ep"), "placeholder round trip")
    eq(CloudProgress.decode(text: snap.text), snap, "progress round trip")

    eq(CloudCanon.pushLine("Favorites", rows: 3, shared: [("favorites", 3)], label: nil, follows: ["favorites local"], ok: true),
       "[CLOUD] push Favorites rows=3 (follow favorites local)", "follow push line")
    eq(CloudCanon.pushLine("Preferences", rows: 9, shared: [("recents", 2), ("settings", 7)], label: "replace", follows: [], ok: false),
       "[CLOUD] push Preferences rows=9 recents=2 settings=7 (replace) failed", "replace push line")
    eq(CloudCanon.migrationLine("progress", rows: 4), "[CLOUD] id migration: progress 4 rows enriched", "migration line")
}

// MARK: - Cloud replace plan (DriveSnapshotRulesTest replace parts)

do {
    let now: Int64 = 100 * 86_400_000
    let env = CloudEnvelope(lastModified: 1, device: "d", format: 2)
    func pe(_ id: String, _ at: Int64, fin: Bool = false, type: String = "movie") -> CloudProgressEntry {
        CloudProgressEntry(videoId: id, title: id, positionMs: 1, durationMs: 2, updatedAt: at, vodType: type, isFinished: fin)
    }
    let local = [pe("1", now), pe("2", now - 1), pe("old", now - 40 * 86_400_000, fin: true), pe("dvr", now, type: "recording"),
                 pe("http://x", now)]
    let backup = CloudProgress(envelope: env, entries: [pe("1", now)])
    eq(CloudCanon.progressReplaceDeletes(local, backup, nowMs: now), ["2"],
       "only counted rows go: finished older than 30 days, non-VOD, and URL rows kept")
    let many = (0..<310).map { pe("m\($0)", now - Int64($0)) }
    eq(CloudCanon.progressReplaceDeletes(many, CloudProgress(envelope: env, entries: []), nowMs: now).count, 300, "beyond the 300 newest kept")

    let r = [CloudReminderEntry(reminderKey: "a", channelName: "One", programTitle: "A", startMillis: now + 1_000, endMillis: now + 1_000),
             CloudReminderEntry(reminderKey: "b", channelName: "Two", programTitle: "B", startMillis: now + 5_000, endMillis: now + 5_000),
             CloudReminderEntry(reminderKey: "ended", channelName: "Three", programTitle: "C", startMillis: 1, endMillis: 2)]
    let rb = CloudReminders(envelope: env, entries: [CloudReminderEntry(reminderKey: "other", channelName: "Two", programTitle: "B",
                                                                         startMillis: now + 5_000, endMillis: now + 5_000)])
    eq(CloudCanon.reminderReplaceDeletes(r, rb, nowMs: now), ["a"], "matched by channel and start; ended reminders kept")

    let fb = CloudFavorites(envelope: env, entries: [CloudFavoriteEntry(channelId: "2", channelName: "", displayOrder: 0, addedAt: 0)])
    eq(CloudCanon.favoriteReplaceDeletes(["1", "2", "1"], fb), ["1"], "favorites the backup lacks")

    let lw = [CloudWatchlistEntry(vodId: "1", title: "Keep", serverId: "p", addedAt: 1),
              CloudWatchlistEntry(vodId: "2", title: "Gone", serverId: "p", addedAt: 1),
              CloudWatchlistEntry(vodId: "3", title: "Other server", serverId: "q", addedAt: 1)]
    let rw = [CloudWatchlistEntry(vodId: "1", title: "Keep", serverId: "p", addedAt: 5),
              CloudWatchlistEntry(vodId: "9", title: "New", serverId: "p", addedAt: 5)]
    let out = CloudCanon.replaceMarks(lw, rw, identity: { "\($0.vodType)|\($0.vodId)|\($0.serverId ?? "")" }, live: { $0.isLive },
                                      inScope: { $0.serverId == nil || $0.serverId == "p" }, tombstone: { var e = $0; e.removedAt = 7; return e })
    eq(out.map(\.vodId), ["1", "2", "3", "9"], "backup rows win, new rows added")
    eq(out.map(\.removedAt), [nil, 7, nil, nil], "the live in-scope row the backup lacks is tombstoned; another server's kept")
    eq(CloudCanon.liveInScope(lw, live: { $0.isLive }, inScope: { $0.serverId == "p" }), 2, "counts line")
    eq(CloudCanon.replaceLine("favorites", local: 3, backup: 1, removed: 2), "[CLOUD] replace favorites local=3 backup=1 removed=2", "replace line")
    eq(CloudCanon.probeFailedLine("NoAccount"), "[CLOUD] setup probe failed: NoAccount (treated as unknown, not empty)", "probe line")
    let scoped = CloudCanon.progressInScope(CloudProgress(envelope: env, entries: [
        CloudProgressEntry(videoId: "1", title: "", positionMs: 0, durationMs: 0, updatedAt: 0, serverId: "p"),
        CloudProgressEntry(videoId: "2", title: "", positionMs: 0, durationMs: 0, updatedAt: 0, serverId: "q"),
        CloudProgressEntry(videoId: "dsync:m:3", title: "", positionMs: 0, durationMs: 0, updatedAt: 0)]), host: "p")
    eq(scoped.entries.map(\.videoId), ["1", "dsync:m:3"], "progress from another playlist is out of scope")
}

// MARK: - Cloud follow, holds, and converge (ConvergeRoundTripTest, DriveSnapshotRulesTest)

do {
    var q = CloudFollowQueue()
    q.note(.preferences, "recents pull"); q.note(.preferences, "recents pull"); q.note(.favorites, "favorites local")
    eq(q.pending, [.favorites, .preferences], "pending files in order")
    eq(q.take(.preferences), ["recents pull"], "follows deduplicated")
    eq(q.take(.preferences), [], "taken once")
    eq(CloudFollowQueue.DELAY_MS, 15_000, "follow pushes within 15 s")

    eq(CloudPushRules.hold(shared: true, choiceHeld: true, unknown: true, deferred: true), "waiting for the setup choice", "choice hold first")
    eq(CloudPushRules.hold(shared: true, choiceHeld: false, unknown: false, deferred: true),
       "replace deferred until the Dispatcharr pull applies", "deferred replace holds")
    eq(CloudPushRules.hold(shared: false, choiceHeld: true, unknown: true, deferred: true), nil, "non-shared files never held")
    eq(CloudPushRules.heldLine("Favorites", "waiting for the setup choice"), "[CLOUD] push Favorites held: waiting for the setup choice", "held line")
    eq(CloudPushRules.stopReason(cloudOn: false, superseded: true), "sync cancelled (iCloud turned off)", "turned off wins")
    eq(CloudPushRules.stopReason(cloudOn: true, superseded: true), "superseded by a newer push", "superseded")
    eq(CloudPushRules.stopReason(cloudOn: true, superseded: false), nil, "go on")

    // Fresh-device hold: released once each category's Dispatcharr pull completed, whatever it counts.
    eq(SetupSourceChoice.freshDeviceHold(["favorites"], read: nil), "Dispatcharr pull not done", "no pull yet")
    eq(SetupSourceChoice.freshDeviceHold(["recents", "settings"], read: ["recents"]), "settings not pulled yet", "one name waits")
    eq(SetupSourceChoice.freshDeviceHold(["favorites"], read: ["favorites"]), nil, "released after the pull")
    eq(SetupSourceChoice.freshDeviceHold([], read: nil), nil, "nothing to wait for")

    // Converge: Dispatcharr is the source of truth; a pushed state is not pushed again (no ping-pong).
    let c = sum(("favorites", Cat(rows: 2, updatedAt: 1, fingerprint: "a")), ("progress", Cat(rows: 1, updatedAt: 1, fingerprint: "p")))
    let d = sum(("favorites", Cat(rows: 3, updatedAt: 2, fingerprint: "b")), ("progress", Cat(rows: 1, updatedAt: 1, fingerprint: "p")))
    let p1 = CloudConverge.plan(cloud: c, dsync: d, skipReasons: [:], marked: [:]) { _ in false }
    eq(p1.push, ["favorites"], "differing category pushed")
    let mark = SetupSourceChoice.convergeMark(d.categories["favorites"])
    let p2 = CloudConverge.plan(cloud: c, dsync: d, skipReasons: [:], marked: ["favorites": mark]) { _ in false }
    eq(p2.push, [], "same Dispatcharr state not pushed twice")
    eq(p2.skipped.map(\.1), ["untranslatable"], "logged skip")
    let p3 = CloudConverge.plan(cloud: c, dsync: d, skipReasons: [:], marked: ["favorites": mark]) { $0 == "favorites" }
    eq(p3.push, ["favorites"], "a local change clears the mark")
    eq(p3.cleared, ["favorites"], "cleared mark reported")
    let p4 = CloudConverge.plan(cloud: c, dsync: d, skipReasons: ["favorites": "dirty"], marked: [:]) { _ in true }
    eq(p4.push, [], "a category with a local change on its way is skipped")
    eq(p4.skipped.map(\.1), ["dirty"], "skip reason")
    eq(SetupSourceChoice.convergeEqualLine(categories: CloudConverge.known(c, c), skipped: []), "[SYNC] converge equal categories=2 skipped=0", "equal line")
    eq(SetupSourceChoice.convergeLine("favorites", cloud: c.categories["favorites"], dsync: d.categories["favorites"]),
       "[SYNC] converge favorites cloud=a/2 dsync=b/3 -> push cloud", "converge line")
}

// MARK: - SyncProvidersTest (Apple writes icloud, preserves googleDrive)

do {
    let stored = SyncProvidersRecord(dispatcharr: false, googleDrive: true, icloud: false, updatedAt: 10, deviceId: "a")
    let p = SyncProvidersRules.forPush(stored: stored, isBaseProfile: true, dispatcharrOn: true, icloudOn: true, reported: [], deviceId: "me", nowMs: 99)
    eq(p.record, SyncProvidersRecord(dispatcharr: true, googleDrive: true, icloud: true, updatedAt: 99, deviceId: "me"), "union with own flags")
    let q = SyncProvidersRules.forPush(stored: p.record, isBaseProfile: true, dispatcharrOn: true, icloudOn: false, reported: p.reported, deviceId: "me", nowMs: 120)
    eq(q.record?.icloud, false, "a flag this device reported goes false once")
    check(!q.reported.contains(SyncProvidersRules.ICLOUD), "then stops forcing it")
    let r = SyncProvidersRules.forPush(stored: q.record, isBaseProfile: true, dispatcharrOn: true, icloudOn: false, reported: q.reported, deviceId: "me", nowMs: 130)
    eq(r.record?.updatedAt, 120, "no change keeps updatedAt")
    eq(SyncProvidersRules.forPush(stored: stored, isBaseProfile: false, dispatcharrOn: true, icloudOn: true, reported: [], deviceId: "me", nowMs: 1).record,
       stored, "a sub-profile never changes the record")
    eq(SyncProvidersRules.newer(stored, SyncProvidersRecord(updatedAt: 10, deviceId: "b"))?.deviceId, "b", "tie: higher deviceId")
    eq(SyncProvidersRules.newer(stored, nil), stored, "nil never replaces")
    let env = CloudEnvelope(lastModified: 1, device: "d", syncProviders: stored, format: 2)
    eq(SyncProvidersRules.fromBody(CloudReminders(envelope: env, entries: []).text), stored, "record rides the envelope")
    eq(SyncProvidersRules.fromJson(.object(DsyncObject([("icloud", .bool(true))]))), nil, "no updatedAt: ignored")
    eq(SyncProvidersRules.offers(stored, icloudOnHere: false, dispatcharrOnHere: false, activeIsDispatcharr: true), [], "Drive never offered on Apple")
    let both = SyncProvidersRecord(dispatcharr: true, icloud: true, updatedAt: 1)
    eq(SyncProvidersRules.offerText(SyncProvidersRules.offers(both, icloudOnHere: false, dispatcharrOnHere: false, activeIsDispatcharr: true)),
       "Your other devices also use iCloud and Dispatcharr Sync. Turn it on here too?", "offer text")
    eq(SyncProvidersRules.offers(both, icloudOnHere: false, dispatcharrOnHere: false, activeIsDispatcharr: false), [SyncProvidersRules.ICLOUD],
       "Dispatcharr only on a Dispatcharr playlist")
    eq(DsyncJSONEncoder.encode(SyncProvidersRules.toJson(SyncProvidersRecord(dispatcharr: true, googleDrive: true, icloud: false,
                                                                              updatedAt: 1761700000000, deviceId: "6F1C"))),
       #"{"dispatcharr":true,"googleDrive":true,"icloud":false,"updatedAt":1761700000000,"deviceId":"6F1C"}"#,
       "section 10b wire shape (Dispatcharr category data and iCloud envelope)")
    // Rule 1: the shared categories iCloud stops applying while Dispatcharr Sync owns them.
    for c in CloudCanon.SHARED_FILES {
        check(DsyncCoexistence.owns(c, activeIsDispatcharr: true, dispatcharrSyncOn: true, firstPullDoneForUser: true), "Dispatcharr owns \(c)")
    }
    eq(Set(CloudCanon.SHARED_FILES), DsyncCoexistence.SHARED_CATEGORIES, "the iCloud snapshot files are the shared categories")
}

// MARK: - Settings second-provider probe (iCloud Sync still off)

do {
    // Dispatcharr Sync on, iCloud Sync being turned on: the iCloud copy is read while the
    // switch is still off, so the gate depends on the signed-in account only.
    let cloudCopy = sum(("favorites", Cat(rows: 3, updatedAt: 2_000, fingerprint: SetupSourceChoice.fingerprint(["a|1", "b|2", "c|3"]))))
    let dsyncCopy = sum(("favorites", Cat(rows: 2, updatedAt: 1_000, fingerprint: SetupSourceChoice.fingerprint(["a|1", "b|2"]))))
    check(SetupSourceChoice.cloudProbeReady(accountPresent: true), "signed-in account opens the probe with iCloud Sync off")
    eq(SetupSourceChoice.probeDecision(accountPresent: true, cloud: cloudCopy, dsync: dsyncCopy),
       .ask(cloud: cloudCopy, dsync: dsyncCopy), "differing copies ask before the iCloud switch commits")
    eq(SetupSourceChoice.defaultSelection(cloud: cloudCopy, dsync: dsyncCopy), .dispatcharr, "prompt default is Dispatcharr")
    eq(SetupSourceChoice.probeDecision(accountPresent: true, cloud: cloudCopy, dsync: .EMPTY), .useCloud, "empty Dispatcharr uses iCloud")
    check(SetupSourceChoice.probeDecision(accountPresent: false, cloud: cloudCopy, dsync: dsyncCopy) == nil, "no account: plain switch")
    check(SetupSourceChoice.probeDecision(accountPresent: true, cloud: nil, dsync: dsyncCopy) == nil, "unreadable iCloud: unknown, no decision")
}

// MARK: - Profiles: RoleRulesTest, ProfilePinTest, ProfileOrderTest, ProfileRosterTest

do {
    let A = ProfileRole.admin, U = ProfileRole.user, C = ProfileRole.child
    eq(ProfileRole.defaultFor(10), A, "level 10 Admin"); eq(ProfileRole.defaultFor(1), U, "level 1 Standard")
    eq(ProfileRole.defaultFor(0), U, "level 0 Standard"); eq(ProfileRole.fromWire("child"), C, "wire child")
    eq(ProfileRole.fromWire("boss"), nil, "unknown wire")
    eq(DispatcharrProfile(id: "b", playlistId: "p", displayName: "Base", username: "base", isDefault: true, userLevel: 1).effectiveRole, U, "base standard")
    eq(DispatcharrProfile(id: "o", playlistId: "p", displayName: "O", username: "o", userLevel: 1, role: A).effectiveRole, U, "admin label needs server admin")
    eq(DispatcharrProfile(id: "o", playlistId: "p", displayName: "O", username: "o", userLevel: 1, role: C).effectiveRole, C, "child kept")
    eq(DispatcharrProfile(id: "o", playlistId: "p", displayName: "O", username: "o", userLevel: 10, role: C).effectiveRole, A, "server admin never Child")
    eq(ProfileRole.optionsFor(10), [A], "admin options"); eq(ProfileRole.optionsFor(1), [U, C], "standard options")
    eq(ProfileRole.optionsFor(serverAdmin: nil), [U, C], "unknown level options")
    eq(RoleRules.serverRoleChange(A, 1), U, "demoted"); eq(RoleRules.serverRoleChange(U, 10), A, "promoted")
    eq(RoleRules.serverRoleChange(C, 10), A, "promoted child"); eq(RoleRules.serverRoleChange(C, 1), nil, "child stays")
    eq(RoleRules.serverRoleChange(A, 10), nil, "admin stays"); eq(RoleRules.serverRoleChange(nil, 1), U, "unset resolves")
    for actor in [A, U] {
        eq(RoleRules.roleChange(actor: actor, from: U, to: A, missingPins: 0, anyPinExists: true, targetIsLastFullAccess: false), .denied(RoleRules.ADMIN_IS_SERVER_SET), "admin is server set")
        eq(RoleRules.roleChange(actor: actor, from: A, to: C, missingPins: 0, anyPinExists: true, targetIsLastFullAccess: false, targetIsServerAdmin: true), .denied(RoleRules.SERVER_ADMIN_STAYS), "server admin stays")
        eq(RoleRules.roleChange(actor: actor, from: U, to: C, missingPins: 1, anyPinExists: true, targetIsLastFullAccess: false), .needsPinsCreated, "missing pins")
        eq(RoleRules.roleChange(actor: actor, from: U, to: C, missingPins: 0, anyPinExists: false, targetIsLastFullAccess: false), .needsPinsCreated, "no pin at all")
        eq(RoleRules.roleChange(actor: actor, from: U, to: C, missingPins: 0, anyPinExists: true, targetIsLastFullAccess: false), .allowed, "to child allowed")
        eq(RoleRules.roleChange(actor: actor, from: C, to: U, missingPins: 0, anyPinExists: true, targetIsLastFullAccess: false), .needsPinEntry, "leaving child needs a PIN")
        check(RoleRules.roleChange(actor: actor, from: U, to: C, missingPins: 0, anyPinExists: true, targetIsLastFullAccess: true) != .allowed, "last full access stays")
        eq(RoleRules.resetGate(actor: actor, actorHasPin: true, childExists: true), .enterOwnPin, "reset own pin")
        eq(RoleRules.resetGate(actor: actor, actorHasPin: false, childExists: false), .confirmOnly, "reset confirm")
    }
    check(RoleRules.roleChange(actor: C, from: U, to: C, missingPins: 0, anyPinExists: true, targetIsLastFullAccess: false) != .allowed, "child cannot change roles")
    eq(RoleRules.addPath(baseIsServerAdmin: true, usersListForbidden: false), .serverList, "server list")
    eq(RoleRules.addPath(baseIsServerAdmin: true, usersListForbidden: true), .manual, "403 manual")
    check(RoleRules.canAssignChannelProfiles(baseIsServerAdmin: true, activeIsServerAdmin: true, active: U), "standard server admin assigns")
    check(!RoleRules.canAssignChannelProfiles(baseIsServerAdmin: true, activeIsServerAdmin: true, active: C), "child never assigns")
    check(!RoleRules.canWriteProfilesKey(C) && !RoleRules.canWriteProfilesKey(nil) && RoleRules.canWriteProfilesKey(U), "profiles key writers")
    check(!RoleRules.canSeeSwitcher(C) && RoleRules.canSeeSwitcher(nil), "switcher")
    for s in ["LiveTV", "Player", "Appearance", "About"] { check(RoleRules.sectionVisible(C, s), "child sees \(s)") }
    for s in ["DvrSettings", "Sync", "Developer"] { check(!RoleRules.sectionVisible(C, s), "child hides \(s)") }
    check(RoleRules.deepLinkAllowed(C, "LiveTV") && !RoleRules.deepLinkAllowed(C, "Sync"), "child deep links")
    // Follow-up 12: Apple's Settings for a Child match Android's exactly.
    let childPanes = SettingsDestination.allCases.filter { RoleRules.settingsSectionVisible(C, $0.rawValue) }
    eq(Set(childPanes), [.liveTV, .player, .appearance, .about], "child Settings panes: Live TV, Player, Appearance, About")
    eq(childPanes.count, RoleRules.CHILD_SECTIONS.count, "same count as Android CHILD_SECTIONS")
    for d in SettingsDestination.allCases {
        check(RoleRules.settingsSectionVisible(U, d.rawValue) && RoleRules.settingsSectionVisible(A, d.rawValue)
              && RoleRules.settingsSectionVisible(nil, d.rawValue), "full access and no profile see \(d.rawValue)")
    }
    for d: SettingsDestination in [.playlists, .moviesTV, .dvr, .general, .remoteControl, .sync, .syncCategories, .developer] {
        check(!RoleRules.settingsSectionVisible(C, d.rawValue), "child hides \(d.rawValue)")
    }
    check(!RoleRules.playlistsVisible(C) && RoleRules.playlistsVisible(U) && RoleRules.playlistsVisible(nil), "Playlists block hidden for a Child only")
    let childLinks = SettingsDeepLinkPage.allCases.filter { RoleRules.deepLinkAllowed(C, $0.rawValue) }
    eq(Set(childLinks), [.root, .livetv, .player, .appearance, .about, .manageProfiles], "child deep links: root, its four panes, Manage Profiles")
    for page: SettingsDeepLinkPage in [.playlists, .playlistDetail, .editPlaylist, .sync, .general, .movies, .dvr, .remote, .developer] {
        check(!RoleRules.deepLinkAllowed(C, page.rawValue), "child deep link \(page.rawValue) lands on the root")
    }
    check(SettingsDeepLinkPage.allCases.allSatisfy { RoleRules.deepLinkAllowed(U, $0.rawValue) }, "Standard opens every deep link")
    eq(SettingsDeepLinkPage(rawValue: "manage-profiles"), .manageProfiles, "manage-profiles link spelling")
    check(SettingsDeepLinkPage.manageProfiles.category == nil, "Manage Profiles routes by role, not a category")
    check(RoleRules.deepLinkAllowed(C, " Manage-Profiles "), "deep link page trimmed and lowercased")
    let holders = [RoleRules.PinHolder(id: "a", role: A, hasPin: true), RoleRules.PinHolder(id: "u1", role: U, hasPin: false),
                   RoleRules.PinHolder(id: "me", role: A, hasPin: false, isActor: true), RoleRules.PinHolder(id: "c", role: C, hasPin: false),
                   RoleRules.PinHolder(id: "u2", role: U, hasPin: false)]
    eq(RoleRules.pinsMissingForChild(holders), ["me", "u1", "u2"], "missing pins, actor first")
    eq(RoleRules.pinsMissingForChild(holders, becomingChild: "u1"), ["me", "u2"], "becoming child excluded")
    check(!RoleRules.canRemovePin(A, childExists: true) && RoleRules.canRemovePin(C, childExists: true), "keep PIN while a Child exists")
    check(!RoleRules.canRemoveDevicePin(childExists: true, otherPins: 0) && RoleRules.canRemoveDevicePin(childExists: true, otherPins: 1), "device PIN")
    check(RoleRules.showLaunchPicker(isTv: true, isDispatcharr: true, toggleOn: true, profileCount: 2, lastRole: A), "launch picker")
    check(!RoleRules.showLaunchPicker(isTv: true, isDispatcharr: true, toggleOn: true, profileCount: 2, lastRole: C), "child skips picker")
    check(!RoleRules.canEditAvatar(actor: C, isOwn: false) && RoleRules.canEditAvatar(actor: C, isOwn: true), "avatar editing")

    // PIN
    eq(PinRules.normalize(.numbers, ["2", "5", "8", "0"]), "2580", "numbers")
    eq(PinRules.normalize(.numbers, ["2", "5", "8"]), nil, "too short")
    eq(PinRules.normalize(.numbers, Array(repeating: "1", count: 7)), nil, "too long")
    eq(PinRules.normalize(.numbers, ["2", "5", "x", "0"]), nil, "non digit")
    eq(PinRules.normalize(.directions, ["Up", "Up", "Down", "Left"]), "UUDL", "directions")
    eq(PinRules.normalize(.directions, ["Up", "Up", "Down", "1"]), nil, "bad direction")
    let salt = Data((0..<16).map { UInt8($0) })
    let h = PinRules.hash(salt: salt, profileId: "p1", type: .numbers, normalized: "2580")
    eq(h.count, 64, "v1 hash hex"); check(h != PinRules.hash(salt: salt, profileId: "p2", type: .numbers, normalized: "2580"), "bound to id")
    check(PinRules.matches(h, PinRules.hash(salt: salt, profileId: "p1", type: .numbers, normalized: "2580")), "v1 stable")
    let s0 = String(repeating: "0", count: 32)
    let v2 = PinRules.hashV2(saltHex: s0, normalized: "1234")!
    check(PinRules.matches(PinRules.hashV2(saltHex: s0, normalized: "1234")!, v2) && !PinRules.matches(v2, PinRules.hashV2(saltHex: s0, normalized: "1235")!), "v2 hash")
    eq(PinRules.freshSaltHex().count, 32, "fresh salt is 16 bytes")
    var b = PinBackoff(); let t: Int64 = 1_000_000
    for _ in 0..<4 { b = b.onWrong(t) }; eq(b.remainingSeconds(t), 0, "four wrong")
    b = b.onWrong(t); eq(b.remainingSeconds(t), 30, "fifth locks 30 s")
    for _ in 0..<5 { b = b.onWrong(t + 30_000) }; eq(b.remainingSeconds(t + 30_000), 60, "doubles")
    eq(PinBackoff.lockMs(50), 30_000 << 10, "cap"); eq(PinBackoff.decode(PinBackoff(fails: 3, round: 2, lockedUntil: 12345).encode()), PinBackoff(fails: 3, round: 2, lockedUntil: 12345), "round trip")
    eq(PinBackoff.decode("garbage"), PinBackoff(), "garbage")
    check(DevicePin.isDevice(DevicePin.id("abc")) && !DevicePin.isDevice("3f2c-uuid"), "device PIN id")

    // Order
    let start = ["a", "b", "c", "d", "e"]
    var steps = start
    for _ in 0..<4 { steps = ProfileOrder.step(steps, "e", .earlier) }
    for _ in 0..<2 { steps = ProfileOrder.step(steps, "b", .later) }
    eq(steps, ["e", "a", "c", "d", "b"], "single moves")
    eq(ProfileOrder.resolve(start, steps), steps, "full order equals single moves")
    eq(ProfileOrder.resolve(start, start), start, "unchanged")
    eq(ProfileOrder.resolve(["a", "b", "c", "f"], ["c", "a", "x", "b"]), ["c", "a", "b", "f"], "roster change mid lift")
    eq(ProfileOrder.step(start, "a", .earlier), start, "clamp top"); eq(ProfileOrder.step(start, "e", .later), start, "clamp bottom")

    // Roster
    func row(_ id: Int, _ u: String, role: String = "user", order: Int = -1, avatar: AvatarSpec? = nil, name: String? = nil, at: Int64 = 1_793_000_000) -> ProfileRow {
        ProfileRow(userId: id, username: u, displayName: name ?? u, pinType: "none", pinHash: "", pinSalt: "", role: role, updatedAt: at, avatar: avatar, order: order)
    }
    let rows = [row(1, "admin"), row(2, "jonzey231"), row(3, "kid", role: "child")]
    let plan = ProfileRoster.plan(rows, ["Admin"])
    eq(plan.merge.map(\.username), ["admin"], "merge local only"); eq(plan.available.map(\.username), ["jonzey231", "kid"], "offered")
    eq(ProfileRoster.suggestions([row(2, "b", order: 2), row(3, "c", order: 1), row(4, "a"), row(1, "me", order: 0)], ["ME"]).map(\.username), ["c", "b", "a"], "roster order")
    let av = AvatarSpec(icon: AvatarCatalog.ICONS[0], color: AvatarCatalog.COLORS[0])
    let applied = ProfileRoster.applyRow(DispatcharrProfile(id: "x", playlistId: "p", displayName: "jonzey231", username: "jonzey231"),
                                         row(7, "jonzey231", role: "child", order: 3, avatar: av, name: "Logan"))
    check(applied.role == C && applied.order == 3 && applied.avatar == av && applied.displayName == "Logan" && applied.userId == 7, "Add pill applies name, avatar, role, and order")
    let kept = ProfileRoster.applyRow(DispatcharrProfile(id: "x", playlistId: "p", displayName: "Mine", username: "x", role: A, order: 5), row(1, "x", role: "", order: -1, name: ""))
    check(kept.role == A && kept.order == 5 && kept.displayName == "Mine", "absent fields keep local")
    let tr = ProfileTombstones.resolve([row(1, "admin"), row(8, "test2", at: 1_792_000_000)], [ProfileTombstone(username: "test2", removedAt: 1_793_500_000, userId: 8)])
    eq(tr.dropped.map(\.username), ["test2"], "tombstone drops"); check(ProfileRoster.suggestions(tr.rows, ["admin"]).isEmpty, "tombstoned not suggested")
    check(ProfileRoster.isStripped(row(1, "u")) && !ProfileRoster.isStripped(row(1, "u", name: "Named")), "stripped rows")

    // Manual add of a roster user (review finding A2): "Enter details" or an
    // API key for a user the roster offers finishes as a roster add.
    do {
        let salt = String(repeating: "a1", count: 16)
        var kidRow = row(9, "Kid", role: "child", order: 2, avatar: av, name: "Little One", at: 1_792_500_000)
        kidRow.pinType = "numbers"; kidRow.pinHash = PinRules.hashV2(saltHex: salt, normalized: "2580")!; kidRow.pinSalt = salt
        let roster = [row(1, "admin"), kidRow]
        eq(ProfileRoster.rowForManualAdd(" kid ", rows: roster, localUsernames: ["admin"]), kidRow, "manual add of a roster user, any case: its row")
        check(ProfileRoster.rowForManualAdd("someone", rows: roster, localUsernames: ["admin"]) == nil, "a user not in the roster: a plain add")
        check(ProfileRoster.rowForManualAdd("   ", rows: roster, localUsernames: []) == nil, "no username: no row")
        check(ProfileRoster.rowForManualAdd("kid", rows: roster, localUsernames: ["KID"]) == nil, "same match as the suggestions (a local profile hides it)")

        // What the roster add stores (ProfileManager.addProfile with the row as seed):
        // the role from the row, the row applied, its PIN imported, its stamp kept.
        let suite = "aerio.dsync-tests.manual-roster.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let pins = ProfilePinStore(defaults: ud, secrets: MemorySecretBox())
        var p = DispatcharrProfile(id: "k", playlistId: "p", displayName: "Kid", username: "Kid", userLevel: 1)
        p.role = ProfileRole.resolve(p.userLevel, ProfileRole.fromWire(kidRow.role))
        p = ProfileRoster.applyRow(p, kidRow)
        pins.importSynced(p.id, PinRules.typeFromWire(kidRow.pinType)!, hash: kidRow.pinHash, salt: kidRow.pinSalt)
        let stamp = kidRow.updatedAt
        eq(p.effectiveRole, C, "the Child role is kept")
        check(p.displayName == "Little One" && p.avatar == av && p.order == 2, "name, avatar, and order from the row")
        let rec = pins.syncRecord(p.id)
        check(rec?.hash == kidRow.pinHash && rec?.salt == kidRow.pinSalt, "the PIN is kept")
        // The next push builds the row from the profile, its PIN, and its stamp (buildProfiles):
        let pushed = ProfileRow(userId: 9, username: "Kid", displayName: p.displayName, pinType: PinRules.wireType(rec?.type),
                                pinHash: rec?.hash ?? "", pinSalt: rec?.salt ?? "", role: p.effectiveRole.wire,
                                updatedAt: stamp, avatar: p.avatar, order: 2)
        check(pushed.role == kidRow.role && pushed.pinType == kidRow.pinType && pushed.pinHash == kidRow.pinHash
              && pushed.pinSalt == kidRow.pinSalt && pushed.updatedAt == kidRow.updatedAt, "the next push sends the same role, PIN, and stamp")
        check(!DsyncGate.profileRowWins(localUpdatedAt: kidRow.updatedAt, remote: pushed), "other devices change nothing on that push")

        // A plain add of the same user (the bug): stamped now, no PIN, the picked role.
        let plain = ProfileRow(userId: 9, username: "Kid", displayName: "Kid", pinType: "none", pinHash: "", pinSalt: "",
                               role: ProfileRole.user.wire, updatedAt: 1_793_000_000, avatar: AvatarSpec(), order: 2)
        check(DsyncGate.profileRowWins(localUpdatedAt: kidRow.updatedAt, remote: plain),
              "a plain add would win everywhere and drop the PIN and the Child role")

        // Undoing an add (follow-up A1). Paths: Remove on an add just made
        // (undoAdd, onboarding and the roster suggestions; a plain add there
        // is a fresh manual add and writes a tombstone) and Cancel on "PIN
        // Required" (discardPendingAdds; a plain add always wrote one).
        let paths: [(String, Bool)] = [("Remove after an add", true), ("Cancel on PIN Required", true)]
        for (path, today) in paths {
            check(!ProfileRoster.undoWritesTombstone(rosterAdd: true, plainWrites: today), "\(path), roster add: no tombstone")
            eq(ProfileRoster.undoWritesTombstone(rosterAdd: false, plainWrites: today), today, "\(path), plain add: as today")
        }
        // The undone roster add is offered again: its row stays, only the local profile goes.
        check(ProfileRoster.suggestions(roster, ["admin", "Kid"]).isEmpty, "while added here, kid is not offered")
        eq(ProfileRoster.suggestions(roster, ["admin"]).map(\.username), ["Kid"], "after the undo, kid is offered again")
        eq(ProfileTombstones.resolve(roster, []).rows.map(\.username), ["admin", "Kid"], "no tombstone: the roster keeps the row")
        // A profile added while the roster sync was paused: no tombstone on either path.
        for (path, today) in paths {
            check(!ProfileRoster.undoWritesTombstone(rosterAdd: false, pauseAdd: true, plainWrites: today), "\(path), pause add: no tombstone")
        }

        // Cancel on "PIN Required" removes only the add that opened it (follow-up 7).
        let pending = ["setup-handoff-profile", "just-added"]
        let drops = ProfileRoster.pinCancelDrops(pending: pending, addedInAction: ["just-added"])
        eq(drops, ["just-added"], "with a setup-handoff profile pending, Cancel removes only the new add")
        check(!drops.contains("setup-handoff-profile"), "the pending setup-handoff profile is untouched, so no tombstone for it")
        eq(ProfileRoster.pinCancelDrops(pending: pending, addedInAction: []), [], "an action that added nothing removes nothing")
        eq(ProfileRoster.pinCancelDrops(pending: ["a"], addedInAction: ["a", "b"]), ["a"], "several adds in one action: each pending one goes")
    }
    eq(AvatarCatalog.defaultColorIndex("ab"), (97 + 98) % 8, "default color index")

    // Avatar ink and initial (review finding A8; the owner's final pick, both platforms).
    for c in ["teal", "orange", "green", "slate"] { eq(AvatarCatalog.inkHex(c), 0x0B1220, "dark ink on \(c)") }
    for c in ["blue", "purple", "sea", "ember"] { eq(AvatarCatalog.inkHex(c), 0xFFFFFF, "white ink on \(c)") }
    eq(Set(AvatarCatalog.COLORS), AvatarCatalog.DARK_INK_COLORS.union(["blue", "purple", "sea", "ember"]), "every color has an ink")
    eq(AvatarCatalog.initial(name: "  bob ", username: "x"), "B", "the trimmed name, uppercased")
    eq(AvatarCatalog.initial(name: "", username: " alice"), "A", "empty name: the trimmed username")
    eq(AvatarCatalog.initial(name: " \t\n", username: "carol"), "C", "whitespace name: the username")
    eq(AvatarCatalog.initial(name: "", username: "  "), "?", "nothing: a question mark")
    eq(AvatarCatalog.initial(name: "", username: ""), "?", "empty both: a question mark")
    eq(AvatarCatalog.initial(name: "\u{e9}lan", username: "x"), "\u{c9}", "a non-ASCII first letter is uppercased")
    eq(SnapshotStaleness.normalize("3, 1,x,2"), "1,2,3", "assignment normalize")
    eq(SnapshotStaleness.reason(SnapshotStamp(userId: 2, assignment: ""), currentUserId: 2, currentAssignment: ""), nil, "fresh stamp")
}

print("\(checks) checks, \(failures) failures")
// MARK: - Profile stores (Android ProfileStore, ProfilePinStore, ProfilePinTest, per-profile settings)

do {
    let suite = "aerio.dsync-tests.profiles.\(UUID().uuidString)"
    let ud = UserDefaults(suiteName: suite)!
    defer { ud.removePersistentDomain(forName: suite) }
    let box = MemorySecretBox()
    let store = ProfileStore(defaults: ud, secrets: box)
    var base = DispatcharrProfile(id: "a", playlistId: "p", displayName: "Base", username: "base", isDefault: true)
    base.createdAt = 0
    var kid = DispatcharrProfile(id: "b", playlistId: "p", displayName: "Kid", username: "kid")
    kid.createdAt = 5
    kid.role = .child
    kid.avatar = AvatarSpec(icon: "cat", color: "teal")
    store.upsert(kid)
    store.upsert(base)
    store.setApiKey("b", "k-secret")
    eq(store.forPlaylist("p").map(\.id), ["a", "b"], "default first, then insertion")
    let reloaded = ProfileStore(defaults: ud, secrets: box)
    eq(reloaded.byId("b"), kid, "profile round trips through UserDefaults")
    eq(reloaded.apiKey("b"), "k-secret", "api key from the secret box")
    check(ud.dictionaryRepresentation().values.allSatisfy { !"\($0)".contains("k-secret") }, "api key never in UserDefaults")
    store.setOrder("p", ["b", "a"])
    eq(store.forPlaylist("p").map(\.id), ["b", "a"], "explicit order wins")
    store.setActiveProfileId("p", "b")
    eq(store.activeProfileId("p"), "b", "active profile")
    check(store.askAtLaunch("p"), "ask at launch defaults on")
    store.remove("b")
    eq(store.activeProfileId("p"), nil, "removing the active profile clears it")
    eq(store.apiKey("b"), nil, "removing a profile clears its key")

    let pins = ProfilePinStore(defaults: ud, secrets: box)
    check(pins.check("x", ["1"]), "no PIN checks true")
    check(!pins.set("x", .numbers, ["1", "2", "3"]), "3 digits rejected")
    check(pins.set("x", .numbers, ["1", "2", "3", "4"]), "4 digits set")
    check(pins.syncRecord("x") != nil, "a fresh PIN is v2 (syncable)")
    eq(pins.length("x"), 4, "length kept")
    check(pins.check("x", ["1", "2", "3", "4"]), "right PIN")
    check(!pins.check("x", ["1", "2", "3", "5"]), "wrong PIN")
    let rec = pins.syncRecord("x")!
    let other = ProfilePinStore(defaults: UserDefaults(suiteName: suite + ".2")!, secrets: MemorySecretBox())
    other.importSynced("x", rec.type, hash: rec.hash, salt: rec.salt!)
    eq(other.length("x"), nil, "a synced PIN arrives with no length (only the hash and salt sync)")
    check(!other.check("x", ["1", "2", "3", "5"]), "a wrong entry on the synced PIN fails")
    eq(other.length("x"), nil, "a wrong entry teaches no length")
    check(other.check("x", ["1", "2", "3", "4"]), "a synced v2 record verifies on another device")
    eq(other.length("x"), 4, "the first correct entry stores the length: the pad shows 4 dots from then on")
    // The pad's dots (owner 2026-11-12): unknown length shows one per digit typed.
    eq(PinRules.dotCount(knownLength: nil, setting: false, typed: 0), 0, "unknown length: no fixed row of empty dots")
    eq(PinRules.dotCount(knownLength: nil, setting: false, typed: 3), 3, "unknown length: a dot per digit typed")
    eq(PinRules.dotCount(knownLength: nil, setting: false, typed: 9), PinRules.MAX_LENGTH, "never more than the maximum")
    eq(PinRules.dotCount(knownLength: 4, setting: false, typed: 1), 4, "a known length shows that many")
    eq(PinRules.dotCount(knownLength: nil, setting: true, typed: 2), PinRules.MIN_LENGTH, "setting a PIN starts at the minimum")
    eq(PinRules.dotCount(knownLength: nil, setting: true, typed: 5), 5, "and grows as digits are typed")
    UserDefaults(suiteName: suite + ".2")!.removePersistentDomain(forName: suite + ".2")
    pins.writeLegacyForTesting("y", .directions, ["Up", "Up", "Left", "Right"])
    check(pins.isLegacy("y") && pins.syncRecord("y") == nil, "v1 record is legacy, not synced")
    check(!pins.check("y", ["U", "U", "L", "L"]), "v1 wrong")
    check(pins.check("y", ["U", "U", "L", "R"]), "v1 right")
    check(!pins.isLegacy("y") && pins.syncRecord("y") != nil, "first correct v1 entry migrates to v2")
    check(pins.check("y", ["up", "up", "left", "right"]), "migrated record still verifies")
    let dev = DevicePin.id("p")
    check(pins.set(dev, .numbers, ["9", "9", "9", "9"]) && pins.hasPin(dev), "device admin PIN under the reserved id")
    pins.saveBackoff("x", PinBackoff().onWrong(1000))
    eq(pins.backoff("x").fails, 1, "backoff persisted")
    pins.remove("x")
    check(!pins.hasPin("x") && pins.backoff("x") == PinBackoff(), "remove clears the record and the backoff")

    let settings = ProfileSettingsStore(defaults: ud)
    check(ProfileSettingsStore.scopedKeys(present: ["categoryColor.sports", "favoriteChannelIDs"]).contains("categoryColor.sports"), "color family is per profile")
    check(!ProfileSettingsStore.scopedKeys(present: ["favoriteChannelIDs"]).contains("favoriteChannelIDs"), "favorites are not a setting")
    check(ProfileSettingsStore.scopedKeys(present: []).isSuperset(of: ["selectedTheme", "radioModeByDefault", "channelGroupOrder"]), "synced settings, group order, radio default")
    ud.set("midnight", forKey: "selectedTheme")
    settings.seed("b", source: settings.capture())
    ud.set("sunset", forKey: "selectedTheme")
    ud.set(true, forKey: "radioModeByDefault")
    settings.swap(from: "a", to: "b")
    eq(ud.string(forKey: "selectedTheme"), "midnight", "switch loads the incoming profile's theme")
    check(ud.object(forKey: "radioModeByDefault") == nil, "a value the incoming profile never had is cleared")
    ud.set("forest", forKey: "selectedTheme")
    settings.swap(from: "b", to: "a")
    eq(ud.string(forKey: "selectedTheme"), "sunset", "switch back restores the outgoing profile's values")
    eq(settings.slot("b")?["selectedTheme"] as? String, "forest", "outgoing values were saved")
    eq(settings.seedExistingOnce(["b", "c"], source: ["selectedTheme": "light"]), 1, "seed once, only unseeded profiles")
    eq(settings.slot("c")?["selectedTheme"] as? String, "light", "existing profile seeded")
    settings.deleteScope("c")
    check(settings.slot("c") == nil, "delete scope")
}

// Record missing after the first read: prompt, never re-upload on our own.
do {
    check(DsyncPullRules.recordMissingAfterFirstRead(hadFirstRead: true, anyBucketListed: false), "missing after first read prompts")
    check(!DsyncPullRules.recordMissingAfterFirstRead(hadFirstRead: false, anyBucketListed: false), "first read of an absent record seeds")
    check(!DsyncPullRules.recordMissingAfterFirstRead(hadFirstRead: true, anyBucketListed: true), "present record syncs")
}

if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
