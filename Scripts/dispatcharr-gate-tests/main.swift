// Dispatcharr request gate tests: Retry-After parsing, the per-server 429
// pause, the rejected-key gate and its prompt, the held-key re-check
// schedule, the interactive countdown retry, and the setup sender's key
// check. Sections name the Android test they port
// (app/src/test/java/com/aeriotv/android/core/network/DispatcharrRateLimitTest.kt,
// DispatcharrKeyGateTest.kt, DispatcharrKeyRecheckScheduleTest.kt, and
// core/setup/SetupKeyPreflightTest.kt).

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

nonisolated(unsafe) var now: TimeInterval = 1_000
let wallNow = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!

func freshGate() -> DispatcharrRequestGate {
    let g = DispatcharrRequestGate()
    now = 10_000
    g.clock = { now }
    g.wallClock = { wallNow }
    return g
}

// MARK: - DispatcharrRateLimitTest

// retryAfterSeconds
eq(DispatcharrRequestGate.parseRetryAfter("42", now: wallNow), 42, "delta seconds")
eq(DispatcharrRequestGate.parseRetryAfter(" 42 ", now: wallNow), 42, "delta seconds, trimmed")
eq(DispatcharrRequestGate.parseRetryAfter("2.2", now: wallNow), 3, "decimal rounded up")
eq(DispatcharrRequestGate.parseRetryAfter("1", now: wallNow), 1, "one second")
// retryAfterMissingOrBadDefaultsTo60
eq(DispatcharrRequestGate.parseRetryAfter(nil, now: wallNow), 60, "missing")
eq(DispatcharrRequestGate.parseRetryAfter("", now: wallNow), 60, "empty")
eq(DispatcharrRequestGate.parseRetryAfter("soon", now: wallNow), 60, "unreadable")
eq(DispatcharrRequestGate.parseRetryAfter("0", now: wallNow), 60, "zero")
eq(DispatcharrRequestGate.parseRetryAfter("-5", now: wallNow), 60, "negative")
eq(DispatcharrRequestGate.parseRetryAfter("nan", now: wallNow), 60, "nan")
eq(DispatcharrRequestGate.parseRetryAfter("inf", now: wallNow), 60, "inf")
// retryAfterCappedAt120
eq(DispatcharrRequestGate.parseRetryAfter("3600", now: wallNow), 120, "capped")
eq(DispatcharrRequestGate.parseRetryAfter("99999999999999999999999", now: wallNow), 120, "huge capped, no overflow")
// retryAfterHttpDate
eq(DispatcharrRequestGate.parseRetryAfter("Mon, 09 Nov 2026 12:00:30 GMT", now: wallNow), 30, "HTTP date")
eq(DispatcharrRequestGate.parseRetryAfter("Mon, 09 Nov 2026 13:00:00 GMT", now: wallNow), 120, "HTTP date capped")
eq(DispatcharrRequestGate.parseRetryAfter("Mon, 09 Nov 2026 11:00:00 GMT", now: wallNow), 60, "HTTP date in the past")

// serverKeyNormalizesPorts
eq(DispatcharrRequestGate.serverKey("https://TV.example.com/api/x/"), "tv.example.com:443", "https default port")
eq(DispatcharrRequestGate.serverKey("http://192.168.1.5:9191/api/core/version/"), "192.168.1.5:9191", "explicit port")
eq(DispatcharrRequestGate.serverKey("http://host"), "host:80", "http default port")

// pauseCountsDownAndClears
do {
    let g = freshGate()
    let k = "tv.example.com:443"
    eq(g.pausedSeconds(k), 0, "not paused")
    g.pause(k, seconds: 60)
    eq(g.pausedSeconds(k), 60, "paused 60")
    now += 59.5
    eq(g.pausedSeconds(k), 1, "half a second left rounds up")
    now += 0.5
    eq(g.pausedSeconds(k), 0, "cleared")
    g.pause(k, seconds: 10)
    eq(g.pausedSeconds("other:443"), 0, "another server is never touched")
}

// shorterPauseNeverShortensALongerOne
do {
    let g = freshGate()
    let k = "s:443"
    g.pause(k, seconds: 90)
    g.pause(k, seconds: 5)
    eq(g.pausedSeconds(k), 90, "shorter never shortens")
    g.pause(k, seconds: 500)
    eq(g.pausedSeconds(k), 120, "longer extends, capped")
}

// paused paths
check(DispatcharrRequestGate.isPausedPath("/api/channels/channels/"), "API path paused")
check(DispatcharrRequestGate.isPausedPath("/dispatcharr/api/vod/movies/"), "API path under a prefix paused")
check(!DispatcharrRequestGate.isPausedPath("/api/accounts/token/"), "login excluded")
check(!DispatcharrRequestGate.isPausedPath("/api/accounts/token/refresh/"), "token refresh excluded")
check(!DispatcharrRequestGate.isPausedPath("/player_api.php"), "Xtream path not paused")
check(!DispatcharrRequestGate.isPausedPath("/proxy/ts/stream/abc"), "stream path not paused")

// rateLimitFoundThroughCauses
eq(DispatcharrGateError.rateLimitSeconds(DispatcharrGateError.rateLimited(seconds: 30)), 30, "direct")
eq(DispatcharrGateError.rateLimitSeconds(NSError(domain: "x", code: 1,
    userInfo: [NSUnderlyingErrorKey: DispatcharrGateError.rateLimited(seconds: 30)])), 30, "wrapped")
eq(DispatcharrGateError.rateLimitSeconds(RateLimitedFinal(seconds: 12)), 12, "final")
eq(DispatcharrGateError.rateLimitSeconds(DispatcharrGateError.keyRejected), nil, "key rejected is not a rate limit")
eq(DispatcharrGateError.rateLimitSeconds(URLError(.timedOut)), nil, "network error is not a rate limit")

struct Unauthorized: Error {}

// countdownRetriesTwiceThenNamesTheRateLimit
do {
    var shown: [Int] = []
    var attempts = 0
    var thrown: Error?
    do {
        let _: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { shown.append($0) }) {
            attempts += 1
            throw DispatcharrGateError.rateLimited(seconds: 3)
        }
    } catch { thrown = error }
    eq(attempts, 3, "three attempts")
    eq(shown, [3, 2, 1, 3, 2, 1], "countdown twice")
    let msg = (thrown as? LocalizedError)?.errorDescription ?? ""
    check(thrown is RateLimitedFinal, "final error type")
    eq(msg, "The server is rate-limiting requests from this network (HTTP 429). Wait 3 seconds and try again.", "final copy")
    check(!msg.contains("Could not connect"), "no Could not connect prefix")
}

// countdownStopsOnSuccess
do {
    var attempts = 0
    var retried = 0
    let r: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { _ in }, onRetry: { retried += 1 }) {
        attempts += 1
        if attempts == 1 { throw DispatcharrGateError.rateLimited(seconds: 1) }
        return 7
    }
    eq(r, 7, "value after one retry")
    eq(attempts, 2, "two attempts")
    eq(retried, 1, "onRetry once")
}

// otherFailuresAreNotRetried
do {
    var attempts = 0
    var thrown: Error?
    do {
        let _: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { _ in }) {
            attempts += 1
            throw Unauthorized()
        }
    } catch { thrown = error }
    eq(attempts, 1, "no retry for a non-429")
    check(thrown is Unauthorized, "original error rethrown")
}

// countdown clamps 1 to 120
do {
    var shown: [Int] = []
    var attempts = 0
    let _: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { shown.append($0) }) {
        attempts += 1
        if attempts == 1 { throw DispatcharrGateError.rateLimited(seconds: 500) }
        return 1
    }
    eq(shown.first, 120, "countdown starts at 120 at most")
    eq(shown.count, 120, "120 ticks")
    eq(shown.last, 1, "ends at 1")
}

// countdownCopy
eq(DispatcharrRateLimitCopy.serverBusyCountdown(45), "The server is busy. Trying again in 45 seconds.", "countdown plural")
eq(DispatcharrRateLimitCopy.serverBusyCountdown(1), "The server is busy. Trying again in 1 second.", "countdown singular")
eq(DispatcharrRateLimitCopy.rateLimitedMessage(1),
   "The server is rate-limiting requests from this network (HTTP 429). Wait 1 second and try again.", "final singular")
eq(DispatcharrGateError.rateLimited(seconds: 60).errorDescription,
   "The server is rate-limiting requests from this network (HTTP 429). Wait 60 seconds and try again.", "typed error copy")

// MARK: - DispatcharrKeyGateTest

// rejectedKeyIsHeldAndPromptsOnce
do {
    let g = freshGate()
    nonisolated(unsafe) var promptEvents: [DispatcharrRequestGate.Prompt?] = []
    g.onPromptChange = { promptEvents.append($0) }
    check(!g.isKeyRejected("old-key"), "not held at first")
    check(g.markKeyRejected(playlistID: "p1", key: "old-key", playlistName: "Home", passwordToo: false), "first mark is the transition")
    check(g.isKeyRejected("old-key"), "held")
    check(g.isPlaylistRejected("p1"), "playlist held")
    eq(g.prompt, DispatcharrRequestGate.Prompt(playlistID: "p1", playlistName: "Home", passwordToo: false), "prompt raised")
    g.consumePrompt()
    check(!g.markKeyRejected(playlistID: "p1", key: "old-key", playlistName: "Home"), "second mark is not a transition")
    eq(g.prompt, nil, "no second prompt")
    eq(promptEvents.count, 2, "one raise, one consume")
}

// otherKeysAreNotHeld
do {
    let g = freshGate()
    g.markKeyRejected(playlistID: "p1", key: "old-key")
    check(!g.isKeyRejected("new-key"), "other key not held")
    check(!g.isKeyRejected(""), "empty key never held")
    check(!g.isPlaylistRejected("p2"), "other playlist not held")
}

// editClearsThePlaylistAndItsPrompt
do {
    let g = freshGate()
    g.markKeyRejected(playlistID: "p1", key: "old-key")
    g.clearPlaylist("p1")
    check(!g.isKeyRejected("old-key"), "edit clears")
    eq(g.prompt, nil, "edit clears the prompt")
    check(g.markKeyRejected(playlistID: "p1", key: "old-key"), "a new rejection after the edit prompts again")
}

// clearingOnePlaylistKeepsAnotherWithTheSameKey
do {
    let g = freshGate()
    g.markKeyRejected(playlistID: "p1", key: "shared")
    g.markKeyRejected(playlistID: "p2", key: "shared")
    g.clearPlaylist("p1")
    check(g.isKeyRejected("shared"), "still held for p2")
    check(g.isPlaylistRejected("p2"), "p2 still held")
}

// provenKeyClearsEverywhere
do {
    let g = freshGate()
    g.markKeyRejected(playlistID: "p1", key: "k")
    g.markKeyRejected(playlistID: "p2", key: "k")
    g.clearKey("k")
    check(!g.isKeyRejected("k"), "proven key clears")
    eq(g.prompt, nil, "and its prompt")
}

// keyIsHashedAndTrimmed
do {
    let h = DispatcharrRequestGate.keyHash("abc")
    eq(h.count, 24, "12 bytes hex")
    check(!h.contains("abc"), "never the key")
    eq(h, DispatcharrRequestGate.keyHash(" abc "), "trimmed")
    eq(h, "ba7816bf8f01cfea414140de", "SHA-256 prefix")
}

// keyReadFromEveryHeaderShape
eq(DispatcharrRequestGate.requestApiKey(xApiKey: "k1", authorization: "ApiKey k1"), "k1", "X-API-Key")
eq(DispatcharrRequestGate.requestApiKey(xApiKey: nil, authorization: "ApiKey k2"), "k2", "ApiKey")
eq(DispatcharrRequestGate.requestApiKey(xApiKey: nil, authorization: "Bearer k3"), "k3", "Bearer")
eq(DispatcharrRequestGate.requestApiKey(xApiKey: nil, authorization: "Basic abc"), nil, "Basic ignored")
eq(DispatcharrRequestGate.requestApiKey(xApiKey: nil, authorization: nil), nil, "none")
eq(DispatcharrRequestGate.requestApiKey(xApiKey: "", authorization: "ApiKey"), nil, "empty")

// dispatcharrInvalidKeyBodyRecognized
check(DispatcharrRequestGate.isDispatcharrInvalidKeyBody("{\"detail\":\"Invalid API key\"}"), "invalid key body")
check(!DispatcharrRequestGate.isDispatcharrInvalidKeyBody("{\"detail\":\"Authentication credentials were not provided.\"}"), "missing credentials body")
check(!DispatcharrRequestGate.isDispatcharrInvalidKeyBody(""), "empty body")

// keyRejected copy
eq(DispatcharrGateError.keyRejected.errorDescription,
   "The server did not accept this playlist's API key. Enter a new key in Edit Playlist.", "key rejected error copy")
eq(DispatcharrRateLimitCopy.keyRejectedTitle, "Sign-in not accepted", "prompt title")
eq(DispatcharrRateLimitCopy.keyRejectedBody(playlistName: "Home", passwordToo: false),
   "The server did not accept the API key for Home. Enter a new key in Edit Playlist to reconnect.", "key-only body")
eq(DispatcharrRateLimitCopy.keyRejectedBody(playlistName: "Home", passwordToo: true),
   "The server did not accept the API key or the password for Home. Enter a new key or password in Edit Playlist to reconnect.",
   "password body")
eq(DispatcharrRateLimitCopy.keyRejectedBody(playlistName: "  ", passwordToo: false),
   "The server did not accept the API key for this playlist. Enter a new key in Edit Playlist to reconnect.", "blank name")

// accepted memo
do {
    let g = freshGate()
    g.noteKeyAccepted("k", mode: "xapikey")
    eq(g.recentlyAcceptedMode("k"), "xapikey", "memo holds")
    now += 61
    eq(g.recentlyAcceptedMode("k"), nil, "memo expires after 60 s")
    g.noteKeyAccepted("k", mode: "both")
    g.markKeyRejected(playlistID: "p1", key: "k")
    eq(g.recentlyAcceptedMode("k"), nil, "a rejection drops the memo")
}

// MARK: - DispatcharrKeyRecheckScheduleTest

let base = "https://tv.example.com"
func hold(_ g: DispatcharrRequestGate, key: String = "k", passwordToo: Bool = false) -> DispatcharrRequestGate.Recheck {
    g.markKeyRejected(playlistID: "p1", key: key, playlistName: "Home", passwordToo: passwordToo, baseURL: base)
    return g.allRechecks().first!
}

func runSchedule(_ g: DispatcharrRequestGate, _ r: DispatcharrRequestGate.Recheck, minutes: Int) -> [Int] {
    let start = now
    var fired: [Int] = []
    for m in 0...minutes {
        now = start + TimeInterval(m * 60)
        if g.claimScheduled(r) {
            fired.append(Int((now - start) / 60))
            g.finishProbe(r, accepted: false)
        }
    }
    return fired
}

// scheduleIsOneFiveFifteenThenEveryThirty
do {
    let g = freshGate()
    let r = hold(g)
    eq(runSchedule(g, r, minutes: 110), [1, 5, 15, 45, 75, 105], "1, 5, 15, then every 30")
}

// scheduledDueTimes
eq(DispatcharrRequestGate.scheduledDueAt(rejectedAt: 0, done: 0), 60, "first")
eq(DispatcharrRequestGate.scheduledDueAt(rejectedAt: 0, done: 1), 300, "second")
eq(DispatcharrRequestGate.scheduledDueAt(rejectedAt: 0, done: 2), 900, "third")
eq(DispatcharrRequestGate.scheduledDueAt(rejectedAt: 0, done: 3), 2700, "fourth")
eq(DispatcharrRequestGate.scheduledDueAt(rejectedAt: 0, done: 4), 4500, "fifth")

// onDemandLimitedToOnePerMinuteAndSharedWithSchedule
do {
    let g = freshGate()
    let r = hold(g)
    check(g.claimOnDemand(r), "foreground right after the rejection")
    g.finishProbe(r, accepted: false)
    now += 30
    check(!g.claimOnDemand(r), "user refresh 30 s later refused")
    now += 30
    check(g.claimScheduled(r), "1-minute slot at exactly the gap")
    g.finishProbe(r, accepted: false)
    now += 1
    check(!g.claimOnDemand(r), "on-demand right after refused")
}

// onDemandPushesTheNextScheduledProbe
do {
    let g = freshGate()
    let r = hold(g)
    now += 50
    check(g.claimOnDemand(r), "on-demand at +50 s")
    g.finishProbe(r, accepted: false)
    now += 10
    check(!g.claimScheduled(r), "slot at +60 s waits for the gap")
    now += 50
    check(g.claimScheduled(r), "runs at +110 s")
}

// neverInsideA429Pause
do {
    let g = freshGate()
    let r = hold(g)
    g.pause(DispatcharrRequestGate.serverKey(base), seconds: 120)
    now += 60
    check(!g.claimScheduled(r), "scheduled refused inside the pause")
    check(!g.claimOnDemand(r), "on-demand refused inside the pause")
    eq(g.nextScheduledAt(r), now + 60, "slot moves to the pause's end")
    now += 60
    check(g.claimScheduled(r), "runs when the pause ends")
}

// loginParkBlocksPasswordProbes
do {
    let g = freshGate()
    let r = hold(g, passwordToo: true)
    now += 60
    check(!g.claimScheduled(r, extraBlockedUntil: now + 20), "login park blocks")
    now += 20
    check(g.claimScheduled(r, extraBlockedUntil: 0), "runs after the park")
}

// oneProbeAtATime
do {
    let g = freshGate()
    let r = hold(g)
    check(g.claimOnDemand(r), "first")
    now += 120
    check(!g.claimScheduled(r), "still in flight")
    g.finishProbe(r, accepted: false)
    check(g.claimScheduled(r), "after finish")
}

// acceptedClearsHoldAndPrompt
do {
    let g = freshGate()
    let r = hold(g)
    check(g.claimOnDemand(r), "claim")
    g.finishProbe(r, accepted: true)
    check(!g.isKeyRejected("k"), "hold cleared")
    eq(g.prompt, nil, "prompt cleared")
    check(g.allRechecks().isEmpty, "re-check dropped")
    eq(g.earliestScheduledAt(), nil, "nothing scheduled")
}

// rejectedStaysHeldWithoutANewPrompt
do {
    let g = freshGate()
    let r = hold(g)
    g.consumePrompt()
    now += 60
    check(g.claimScheduled(r), "claim")
    g.finishProbe(r, accepted: false)
    check(g.isKeyRejected("k"), "still held")
    eq(g.prompt, nil, "no new prompt")
    eq(g.nextScheduledAt(r), DispatcharrRequestGate.scheduledDueAt(rejectedAt: r.rejectedAt, done: 1), "schedule continues")
}

// editOrProvenKeyDropsTheRecheck
do {
    let g = freshGate()
    _ = hold(g)
    g.clearPlaylist("p1")
    check(g.allRechecks().isEmpty, "edit drops the re-check")
    _ = hold(g)
    g.clearKey("k")
    check(g.allRechecks().isEmpty, "proven key drops the re-check")
}

// noBaseUrlNoRecheck
do {
    let g = freshGate()
    g.markKeyRejected(playlistID: "p1", key: "k")
    check(g.allRechecks().isEmpty, "no base URL, no re-check")
}

// worstCaseRateIsFarUnderTheThrottle
do {
    let g = freshGate()
    let r = hold(g)
    var probes = 0
    var perMinute: [Int: Int] = [:]
    let start = now
    for s in 0...600 {
        now = start + TimeInterval(s)
        if g.claimScheduled(r) || g.claimOnDemand(r) {
            probes += 1
            perMinute[s / 60, default: 0] += 1
            g.finishProbe(r, accepted: false)
        }
    }
    check(probes <= 11, "at most one per 60 s over 600 s (probes=\(probes))")
    check(perMinute.values.allSatisfy { $0 <= 1 }, "never two in one minute")
}

// MARK: - SetupKeyPreflightTest

func preflight(_ answers: [SetupKeyCheck]) async -> (SetupKeyVerdict, Int, [(Int, Bool)]) {
    var i = 0
    var shown: [(Int, Bool)] = []
    let v = await SetupKeyPreflight.run(tick: {}, check: {
        let a = answers[min(i, answers.count - 1)]
        i += 1
        return a
    }, onCountdown: { left, limited in shown.append((left, limited)) })
    return (v, i, shown)
}

do {
    let (v, calls, shown) = await preflight([.accepted])
    eq(v, .send, "accepted sends")
    eq(calls, 1, "one check")
    eq(shown.count, 0, "no countdown")
}
do {
    let (v, calls, _) = await preflight([.rejected])
    eq(v, .rejected, "rejected never sends")
    eq(calls, 1, "one check")
}
do {
    let (v, calls, shown) = await preflight([.unknown(retryAfter: 2), .rejected])
    eq(v, .rejected, "429 then rejected")
    eq(calls, 2, "two checks")
    eq(shown.map(\.0), [2, 1], "countdown on Retry-After")
    eq(shown.map(\.1), [true, true], "rate-limited countdown")
}
do {
    let (v, calls, _) = await preflight([.unknown(retryAfter: 1), .unknown(retryAfter: nil), .unknown(retryAfter: 1)])
    eq(v, .send, "still unknown after two re-checks sends")
    eq(calls, 3, "three checks")
}
do {
    let (_, _, shown) = await preflight([.unknown(retryAfter: nil), .accepted])
    eq(shown.map(\.0), [3, 2, 1], "network error waits 3 s")
    eq(shown.map(\.1), [false, false, false], "not a rate-limit countdown")
}
eq(DispatcharrRateLimitCopy.checkingLine, "Checking the playlist sign-in", "checking line")
eq(DispatcharrRateLimitCopy.setupKeyRejectedMessage,
   "The server did not accept this playlist's API key, so it was not sent. Enter a new key in Edit Playlist, then try again.",
   "sender rejected copy")

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
