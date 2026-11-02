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
    check(DsyncKey.isValidKeyName(DsyncBucket.main.wire), "bucket key matches the server key pattern")
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

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
