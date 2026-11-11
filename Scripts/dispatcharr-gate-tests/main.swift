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
// URL.path drops the trailing slash (the login 429 used to pause every API call).
check(!DispatcharrRequestGate.isPausedPath("/api/accounts/token"), "login excluded without the trailing slash")
check(!DispatcharrRequestGate.isPausedPath("/api/accounts/token/refresh"), "refresh excluded without the trailing slash")
check(!DispatcharrRequestGate.isPausedPath(URL(string: "http://127.0.0.1:9191/api/accounts/token/")!.path), "login URL.path excluded")
check(DispatcharrRequestGate.isPausedPath(URL(string: "http://127.0.0.1:9191/api/accounts/users/me/")!.path), "users/me URL.path paused")
check(DispatcharrRequestGate.isPausedPath("/api/accounts/tokens"), "a different path that starts alike is still paused")
// Repeat callers (permissions probe users/me, EPG programs pages) are gated
// paths: a held key or a 429 pause fails them locally with nothing sent.
for p in ["/api/accounts/users/me", "/api/epg/programs", "/api/epg/grid", "/api/channels/recordings",
          "/api/accounts/users/me/app-data"] {
    check(DispatcharrRequestGate.isPausedPath(p), "repeat caller \(p) is gated")
}
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
        let _: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { left, _ in shown.append(left) }) {
            attempts += 1
            throw DispatcharrGateError.rateLimited(seconds: 3)
        }
    } catch { thrown = error }
    eq(attempts, 3, "three attempts")
    eq(shown, [3, 2, 1, 3, 2, 1], "countdown twice")
    let msg = (thrown as? LocalizedError)?.errorDescription ?? ""
    check(thrown is RateLimitedFinal, "final error type")
    eq(msg, "Dispatcharr rate-limited this network (HTTP 429). Wait 3 seconds and try again.", "final copy")
    check(!msg.contains("Could not connect"), "no Could not connect prefix")
}

// countdownStopsOnSuccess
do {
    var attempts = 0
    var retried = 0
    let r: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { _, _ in }, onRetry: { retried += 1 }) {
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
        let _: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { _, _ in }) {
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
    let _: Int = try await RateLimitRetry.run(tick: {}, onCountdown: { left, _ in shown.append(left) }) {
        attempts += 1
        if attempts == 1 { throw DispatcharrGateError.rateLimited(seconds: 500) }
        return 1
    }
    eq(shown.first, 120, "countdown starts at 120 at most")
    eq(shown.count, 120, "120 ticks")
    eq(shown.last, 1, "ends at 1")
}

// Sign-in 429 (Add Playlist, Test Connection): a login 429 counts down from
// the login gate's park, retries twice, then names the rate limit (Android
// LoginThrottled through RateLimitRetry.run).
struct Login429: Error {}
func signInLimit(_ e: Error, parked: Int) -> (seconds: Int, reason: RateLimitReason)? {
    RateLimitRetry.signInWait(e,
                              apiLimit: { DispatcharrGateError.rateLimit($0) },
                              isLogin429: { $0 is Login429 },
                              loginParked: { (parked, .signInLockout) })
}
func signInSeconds(_ e: Error, parked: Int) -> Int? { signInLimit(e, parked: parked)?.seconds }
eq(signInSeconds(Login429(), parked: 45), 45, "login 429 waits the park")
eq(signInSeconds(Login429(), parked: 0), 60, "login 429 with a lapsed park waits the default")
eq(signInSeconds(DispatcharrGateError.rateLimited(seconds: 7), parked: 45), 7, "API 429 keeps its own seconds")
eq(signInSeconds(Unauthorized(), parked: 45), nil, "other failures are not a rate limit")
eq(signInLimit(Login429(), parked: 45)?.reason, .signInLockout, "login 429: the sign-in lockout reason")
eq(signInLimit(DispatcharrGateError.rateLimited(seconds: 7, reason: .apiKeyLockout), parked: 45)?.reason, .apiKeyLockout,
   "API 429 keeps its own reason")
do {
    var shown: [Int] = []
    var reasons: [RateLimitReason] = []
    var retried = 0
    var attempts = 0
    var thrown: Error?
    do {
        let _: Int = try await RateLimitRetry.run(
            rateLimit: { signInLimit($0, parked: 2) },
            tick: {},
            onCountdown: { left, reason in shown.append(left); reasons.append(reason) },
            onRetry: { retried += 1 }
        ) {
            attempts += 1
            throw Login429()
        }
    } catch { thrown = error }
    eq(attempts, 3, "login: three attempts")
    eq(retried, 2, "login: two automatic retries")
    eq(shown, [2, 1, 2, 1], "login: countdown from the park")
    eq(Set(reasons), [.signInLockout], "login: the sign-in reason on every tick")
    eq(DispatcharrRateLimitCopy.serverBusyCountdown(shown[0], reason: reasons[0]),
       "Dispatcharr rate-limited sign-ins from this network after too many failed attempts. Trying again in 2 seconds.",
       "login: countdown line")
    eq((thrown as? LocalizedError)?.errorDescription,
       "Dispatcharr rate-limited sign-ins from this network after too many failed attempts. Wait 2 seconds and try again.",
       "login: final copy")
}
do {
    var attempts = 0
    let r: Int = try await RateLimitRetry.run(rateLimit: { signInLimit($0, parked: 1) }, tick: {}, onCountdown: { _, _ in }) {
        attempts += 1
        if attempts == 1 { throw Login429() }
        return 5
    }
    eq(r, 5, "login: success after one countdown")
    eq(attempts, 2, "login: two attempts")
}

// countdownCopy
// The exact copy table (stream-429-spec.md UPDATE).
eq(DispatcharrRateLimitCopy.serverBusyCountdown(45, reason: .apiKeyLockout),
   "Dispatcharr rate-limited this network after too many failed API key attempts. Trying again in 45 seconds.", "API key countdown")
eq(DispatcharrRateLimitCopy.rateLimitedMessage(45, reason: .apiKeyLockout),
   "Dispatcharr rate-limited this network after too many failed API key attempts. Wait 45 seconds and try again.", "API key final")
eq(DispatcharrRateLimitCopy.serverBusyCountdown(30, reason: .signInLockout),
   "Dispatcharr rate-limited sign-ins from this network after too many failed attempts. Trying again in 30 seconds.", "sign-in countdown")
eq(DispatcharrRateLimitCopy.rateLimitedMessage(30, reason: .signInLockout),
   "Dispatcharr rate-limited sign-ins from this network after too many failed attempts. Wait 30 seconds and try again.", "sign-in final")
eq(DispatcharrRateLimitCopy.serverBusyCountdown(45),
   "Dispatcharr rate-limited this network (HTTP 429). Trying again in 45 seconds.", "other countdown plural")
eq(DispatcharrRateLimitCopy.serverBusyCountdown(1),
   "Dispatcharr rate-limited this network (HTTP 429). Trying again in 1 second.", "other countdown singular")
eq(DispatcharrRateLimitCopy.rateLimitedMessage(1),
   "Dispatcharr rate-limited this network (HTTP 429). Wait 1 second and try again.", "other final singular")
eq(DispatcharrRateLimitCopy.rateLimitedMessage(1, reason: .apiKeyLockout),
   "Dispatcharr rate-limited this network after too many failed API key attempts. Wait 1 second and try again.", "API key final singular")
eq(DispatcharrRateLimitCopy.streamLimitMessage(2),
   "Dispatcharr stream limit reached: 2 concurrent streams allowed for this account.", "stream limit with count")
eq(DispatcharrRateLimitCopy.streamLimitMessage(nil), "Dispatcharr stream limit reached.", "stream limit without count")
eq(DispatcharrGateError.rateLimited(seconds: 60).errorDescription,
   "Dispatcharr rate-limited this network (HTTP 429). Wait 60 seconds and try again.", "typed error copy")
eq(DispatcharrGateError.rateLimited(seconds: 60, reason: .apiKeyLockout).errorDescription,
   "Dispatcharr rate-limited this network after too many failed API key attempts. Wait 60 seconds and try again.",
   "typed error copy names the reason")

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
// An inactive account's key is refused by the same authentication class:
// treat it as rejected, no sweep of the other header shapes.
check(DispatcharrRequestGate.isDispatcharrInvalidKeyBody("{\"detail\":\"User inactive\"}"), "inactive user body")
check(DispatcharrRequestGate.isDispatcharrInvalidKeyBody("{\"detail\":\"user inactive\"}"), "inactive user body, any case")
check(!DispatcharrRequestGate.isDispatcharrInvalidKeyBody("{\"detail\":\"User not found\"}"), "other 401 body is not proof")

// A rotated key with a stored password: re-sign in, never hold (Android parity).
eq(DispatcharrRequestGate.afterRejectedKey(hasStoredPassword: true, loginRefused: false), .relogin, "password: re-login first")
eq(DispatcharrRequestGate.afterRejectedKey(hasStoredPassword: true, loginRefused: true), .hold, "refused login: hold")
eq(DispatcharrRequestGate.afterRejectedKey(hasStoredPassword: false, loginRefused: false), .hold, "no password: hold")
// The key the re-login minted replaces the old one in requests still carrying it.
do {
    let g = freshGate()
    eq(g.replacementKey(for: "old-key"), nil, "nothing replaced yet")
    check(g.rewritingReplacedKey(xApiKey: "old-key", authorization: nil) == nil, "no rewrite before a re-login")
    g.noteKeyReplaced(old: "old-key", new: "new-key")
    eq(g.replacementKey(for: "old-key"), "new-key", "old key maps to the new one")
    eq(g.replacementKey(for: " old-key "), "new-key", "whitespace ignored")
    eq(g.replacementKey(for: "other"), nil, "other keys untouched")
    let x = g.rewritingReplacedKey(xApiKey: "old-key", authorization: nil)
    eq(x?.xApiKey, "new-key", "X-API-Key swapped")
    eq(x?.authorization, nil, "no Authorization added")
    let both = g.rewritingReplacedKey(xApiKey: "old-key", authorization: "ApiKey old-key")
    eq(both?.xApiKey, "new-key", "dual shape: X-API-Key swapped")
    eq(both?.authorization, "ApiKey new-key", "dual shape: ApiKey swapped")
    eq(g.rewritingReplacedKey(xApiKey: nil, authorization: "Bearer old-key")?.authorization, "Bearer new-key", "bearer shape swapped")
    check(g.rewritingReplacedKey(xApiKey: "new-key", authorization: nil) == nil, "the new key is left alone")
    g.noteKeyReplaced(old: "same", new: "same")
    eq(g.replacementKey(for: "same"), nil, "a re-login that returns the same key replaces nothing")
    now += DispatcharrRequestGate.replacementMemo + 1
    eq(g.replacementKey(for: "old-key"), nil, "the swap expires after the memo window")
}

// 429 reasons (stream-429-spec.md UPDATE): every body shape.
do {
    func c(_ body: String?, _ retryAfter: String? = nil) -> Dispatcharr429 {
        Dispatcharr429.classify(body: body.map { Data($0.utf8) }, retryAfter: retryAfter)
    }
    eq(c(#"{"detail":"Too many API key attempts. Try again later."}"#, "58"), .rateLimited(.apiKeyLockout, seconds: 58),
       "JSON detail, API key lockout")
    eq(c(#"{"detail":"Too many API key attempts. Try again later. Expected available in 41 seconds."}"#, "41"),
       .rateLimited(.apiKeyLockout, seconds: 41), "JSON detail with the DRF suffix")
    eq(c(#"{"detail":"too many api key attempts. try again later."}"#), .rateLimited(.apiKeyLockout, seconds: 60),
       "case-insensitive; no Retry-After: the gate default")
    eq(c(#"{"detail":"Too many login attempts. Try again later."}"#, "30"), .rateLimited(.signInLockout, seconds: 30),
       "JSON detail, sign-in lockout")
    eq(c("Too many login attempts. Try again later.", "15"), .rateLimited(.signInLockout, seconds: 15),
       "plain-text sign-in lockout")
    eq(c("Too many API key attempts. Try again later.\n"), .rateLimited(.apiKeyLockout, seconds: 60), "plain-text API key lockout")
    eq(c(#"{"error":"Stream limit exceeded (2 concurrent streams allowed)"}"#), .streamLimit(count: 2),
       "stream limit JSON error with its count")
    eq(c(#"{"error":"Stream limit exceeded (2 concurrent streams allowed)"}"#, "30"), .streamLimit(count: 2),
       "stream limit wins over a Retry-After")
    eq(c(#"{"error":"Stream limit exceeded"}"#), .streamLimit(count: nil), "stream limit without a count")
    eq(c(#"{"detail":"Request was throttled."}"#, "12"), .rateLimited(.other, seconds: 12), "unknown JSON detail: other")
    eq(c("<html>429</html>", "9"), .rateLimited(.other, seconds: 9), "unknown plain text: other")
    eq(c(nil, "500"), .rateLimited(.other, seconds: 120), "no body: other, capped Retry-After")
    eq(c("", "0"), .rateLimited(.other, seconds: 60), "empty body, zero Retry-After: default")
    eq(c(#"{"detail":"Server says: Too many API key attempts"}"#), .rateLimited(.other, seconds: 60),
       "only a LEADING phrase counts")
    eq(Dispatcharr429.streamCount("Stream limit exceeded (12 concurrent streams allowed)"), 12, "count parsed")
    // Timeshift answers its stream limit as 403 plain text.
    eq(Dispatcharr429.classify(reasonText: Dispatcharr429.reasonText(Data("Stream limit exceeded".utf8)), retryAfter: nil),
       .streamLimit(count: nil), "timeshift 403 plain text: stream limit")
}
// No stream opens while the server is paused.
do {
    let g = freshGate()
    let stream = "https://tv.example.test/proxy/ts/stream/abc"
    eq(g.streamOpenWaitSeconds(stream), 0, "not paused: open")
    g.noteStream429(stream, .streamLimit(count: 2))
    eq(g.streamOpenWaitSeconds(stream), 0, "a stream limit never pauses the gate")
    g.noteStream429(stream, .rateLimited(.apiKeyLockout, seconds: 30))
    eq(g.streamOpenWaitSeconds(stream), 30, "lockout: no open for the Retry-After")
    eq(g.pausedReason(DispatcharrRequestGate.serverKey(stream)), .apiKeyLockout, "the pause keeps the server's reason")
    eq(g.pausedSeconds(DispatcharrRequestGate.serverKey("https://tv.example.test/api/channels/channels/")), 30,
       "the same pause as API calls to that server")
    eq(g.streamOpenWaitSeconds("https://other.example.test/proxy/ts/stream/x"), 0, "other servers unaffected")
    now += 29
    eq(g.streamOpenWaitSeconds(stream), 1, "one second left")
    now += 1
    eq(g.streamOpenWaitSeconds(stream), 0, "open again once the pause ends")
    // An API 429 pauses stream opens too.
    g.pause(DispatcharrRequestGate.serverKey("https://tv.example.test/api/epg/grid/"), seconds: 10)
    eq(g.streamOpenWaitSeconds(stream), 10, "an API 429 also holds stream opens")
}

// Key probe single flight: concurrent callers for one key share one probe.
actor ProbeCounter {
    var runs = 0
    func hit() { runs += 1 }
}
do {
    let flight = SingleFlight<Int>()
    let counter = ProbeCounter()
    let gate = AsyncStream<Void>.makeStream()
    nonisolated(unsafe) var release: AsyncStream<Void>.Continuation? = gate.continuation
    let work: @Sendable () async throws -> Int = {
        await counter.hit()
        for await _ in gate.stream { break }
        return 42
    }
    async let a = flight.run("key-hash", work)
    // Let the first caller start its probe before the others arrive.
    while await counter.runs == 0 { await Task.yield() }
    async let b = flight.run("key-hash", work)
    async let c = flight.run("key-hash", work)
    for _ in 0..<50 { await Task.yield() }
    eq(flight.count, 1, "one probe in flight")
    release?.yield(); release?.finish(); release = nil
    let results = try await [a, b, c]
    eq(results.map(\.value), [42, 42, 42], "every caller gets the one result")
    eq(results.filter(\.owner).count, 1, "exactly one owner")
    eq(await counter.runs, 1, "the probe ran once")
    eq(flight.count, 0, "released after it finished")
    // A later call starts a fresh probe.
    let again = try await flight.run("key-hash") { await counter.hit(); return 7 }
    eq(again.value, 7, "fresh probe value")
    check(again.owner, "fresh probe owner")
    eq(await counter.runs, 2, "a later call probes again")
}
do {
    let flight = SingleFlight<Int>()
    let counter = ProbeCounter()
    async let a = flight.run("k1") { await counter.hit(); return 1 }
    async let b = flight.run("k2") { await counter.hit(); return 2 }
    let (ra, rb) = try await (a, b)
    eq([ra.value, rb.value], [1, 2], "different keys keep their own result")
    eq(await counter.runs, 2, "different keys probe separately")
}
do {
    struct Boom: Error {}
    let flight = SingleFlight<Int>()
    var threw = false
    do { _ = try await flight.run("k") { throw Boom() } } catch { threw = error is Boom }
    check(threw, "a failed probe throws to its caller")
    eq(flight.count, 0, "a failed probe is released")
}

// keyRejected copy
eq(DispatcharrGateError.keyRejected.errorDescription,
   "Dispatcharr no longer accepts this playlist's API key. Enter the current key in Edit Playlist, or ask your Dispatcharr administrator for a new one.", "key rejected error copy")
eq(DispatcharrRateLimitCopy.keyRejectedTitle, "API key no longer valid", "prompt title")
// Fix Login (2026-11-11): writing a new sign-in lifts the hold and the prompt for
// that playlist only, the new key counts as good, and the old key goes out as the new one.
do {
    let g = DispatcharrRequestGate()
    g.markKeyRejected(playlistID: "P1", key: "DEAD", playlistName: "Home")
    g.markKeyRejected(playlistID: "P2", key: "OTHER", playlistName: "Other")
    g.consumePrompt()
    g.markKeyRejected(playlistID: "P1", key: "DEAD2", playlistName: "Home")
    check(g.prompt?.playlistID == "P1", "prompt up for P1")
    g.liftFixedLogin(playlistID: "P1", oldKey: "DEAD", newKey: "GOOD")
    check(!g.isPlaylistRejected("P1"), "P1 hold lifted")
    check(g.prompt == nil, "P1 prompt cleared")
    check(g.isPlaylistRejected("P2") && g.isKeyRejected("OTHER"), "another playlist's hold stays")
    check(!g.isKeyRejected("GOOD"), "new key good")
    eq(g.replacementKey(for: "DEAD"), "GOOD", "old key goes out as the new one")
    eq(StreamKeyGate.headersForOpen(["X-API-Key": "DEAD"], gate: g), .send(["X-API-Key": "GOOD"]), "a stream built with the old key opens with the new one")
    g.liftFixedLogin(playlistID: "P2", oldKey: "OTHER", newKey: nil)
    check(!g.isPlaylistRejected("P2"), "password-only fix still lifts the hold")
}

// Catch-up alert title (2026-11-11): the rejected-key title only when a held key stopped it.
eq(DispatcharrRateLimitCopy.catchupAlertTitle(DispatcharrGateError.keyRejected), "API key no longer valid", "catch-up held key title")
eq(DispatcharrRateLimitCopy.catchupAlertTitle(NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: DispatcharrGateError.keyRejected])),
   "API key no longer valid", "catch-up held key title (wrapped)")
eq(DispatcharrRateLimitCopy.catchupAlertTitle(DispatcharrGateError.rateLimited(seconds: 30)), "Catch-up Unavailable", "catch-up 429 title")
eq(DispatcharrRateLimitCopy.catchupAlertTitle(URLError(.timedOut)), "Catch-up Unavailable", "catch-up other failure title")
eq(DispatcharrRateLimitCopy.keyRejectedBody(playlistName: "Home", passwordToo: false),
   "Dispatcharr no longer accepts the API key for Home. It may have been changed or removed on the server. Enter the current key in Edit Playlist, or ask your Dispatcharr administrator for a new one.", "key-only body")
eq(DispatcharrRateLimitCopy.keyRejectedBody(playlistName: "Home", passwordToo: true),
   "Dispatcharr no longer accepts the API key or password for Home. They may have been changed on the server. Enter the current details in Edit Playlist, or ask your Dispatcharr administrator.",
   "password body")
eq(DispatcharrRateLimitCopy.keyRejectedBody(playlistName: "  ", passwordToo: false),
   "Dispatcharr no longer accepts the API key for this playlist. It may have been changed or removed on the server. Enter the current key in Edit Playlist, or ask your Dispatcharr administrator for a new one.", "blank name")

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
    }, onCountdown: { left, limited in shown.append((left, limited != nil)) })
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
   "Dispatcharr no longer accepts this playlist's API key, so it was not sent. Enter the current key in Edit Playlist, then try again.",
   "sender rejected copy")

// MARK: - Stream opens and 401s (2026-11-10)
do {
    let g = DispatcharrRequestGate()
    let h = ["X-API-Key": "dead", "Authorization": "ApiKey dead", "User-Agent": "UA"]
    eq(StreamKeyGate.apiKey(in: h), "dead", "stream open carries its key")
    eq(StreamKeyGate.headersForOpen(h, gate: g), .send(h), "a good key opens as it is")
    // A key the silent re-login replaced goes out as its successor, in both header shapes.
    g.noteKeyReplaced(old: "dead", new: "fresh")
    if case .send(let s) = StreamKeyGate.headersForOpen(h, gate: g) {
        eq(s["X-API-Key"], "fresh", "replaced key swapped in X-API-Key")
        eq(s["Authorization"], "ApiKey fresh", "replaced key swapped in Authorization")
        eq(s["User-Agent"], "UA", "other headers kept")
    } else { check(false, "replaced key should open") }
    // A key held as rejected never opens (no request at all).
    let g2 = DispatcharrRequestGate()
    _ = g2.markKeyRejected(playlistID: "P", key: "dead")
    eq(StreamKeyGate.headersForOpen(h, gate: g2), .held, "held key: no open")
    eq(StreamKeyGate.headersForOpen(["Authorization": "Bearer dead"], gate: g2), .held, "held key in Bearer shape: no open")
    eq(StreamKeyGate.headersForOpen(["User-Agent": "UA"], gate: g2), .send(["User-Agent": "UA"]), "no key: opens (M3U)")
    // What a 401 leads to.
    eq(StreamKeyGate.after401(probe: .rejected, reloginTried: true, newKey: "fresh", oldKey: "dead"), .retry(newKey: "fresh"),
       "rejected key with a stored password: re-login, one retry with the new key")
    eq(StreamKeyGate.after401(probe: .rejected, reloginTried: false, newKey: nil, oldKey: "dead"), .held,
       "rejected key, no password: hold and prompt")
    eq(StreamKeyGate.after401(probe: .rejected, reloginTried: true, newKey: nil, oldKey: "dead"), .held,
       "re-login refused: hold")
    eq(StreamKeyGate.after401(probe: .rejected, reloginTried: true, newKey: "dead", oldKey: "dead"), .held,
       "re-login gave the same key: hold")
    eq(StreamKeyGate.after401(probe: .accepted, reloginTried: false, newKey: nil, oldKey: "k"), .retry(newKey: nil),
       "key proven good: one retry as it is")
    eq(StreamKeyGate.after401(probe: .unknown, reloginTried: false, newKey: nil, oldKey: "k"), .unchanged,
       "no answer: the normal failure path")
    eq(StreamKeyGate.retriesPerOpen, 1, "one broker round per open")
}

// MARK: - Launch credential barrier (2026-11-10)

do {
    typealias E = CredentialMergeBarrier.Entry
    eq(CredentialMergeBarrier.doubtfulKeys([E(localKey: "same", localChangedAt: 0, cloudKey: "same", cloudChangedAt: 0)]), [],
       "keys agree with iCloud: nothing waits")
    eq(CredentialMergeBarrier.doubtfulKeys([E(localKey: "old", localChangedAt: 0, cloudKey: "new", cloudChangedAt: 0)]), ["old"],
       "iCloud carries a different key, neither stamped: the local key waits for the merge")
    eq(CredentialMergeBarrier.doubtfulKeys([E(localKey: "old", localChangedAt: 100, cloudKey: "new", cloudChangedAt: 900)]), ["old"],
       "iCloud's key is newer: the local key waits")
    eq(CredentialMergeBarrier.doubtfulKeys([E(localKey: "mine", localChangedAt: 900, cloudKey: "older", cloudChangedAt: 100)]), [],
       "this device's key is the newer one: no wait")
    eq(CredentialMergeBarrier.doubtfulKeys([E(localKey: "", localChangedAt: 0, cloudKey: "new", cloudChangedAt: 0)]), [],
       "no local key: nothing to hold back")
    eq(CredentialMergeBarrier.doubtfulKeys([E(localKey: "k", localChangedAt: 0, cloudKey: " ", cloudChangedAt: 0)]), [],
       "an empty iCloud key never holds a call")

    final class Clock: @unchecked Sendable { var t: TimeInterval = 1000 }
    let c = Clock()
    let b = CredentialMergeBarrier()
    b.clock = { c.t }
    eq(b.remainingWait(forKey: "old"), 0, "unarmed: no wait")
    b.arm(doubtfulKeys: [])
    check(!b.isArmed, "armed with nothing: not armed")
    b.arm(doubtfulKeys: ["old"])
    check(b.isArmed, "armed with a doubtful key")
    eq(b.remainingWait(forKey: "old"), CredentialMergeBarrier.maxWait, "a doubtful key waits up to the bound")
    eq(b.remainingWait(forKey: " old "), CredentialMergeBarrier.maxWait, "the key is matched trimmed")
    eq(b.remainingWait(forKey: "other"), 0, "any other key goes at once")
    eq(b.remainingWait(forKey: nil), 0, "a call without a key goes at once")
    c.t += 1.5
    eq(b.remainingWait(forKey: "old"), CredentialMergeBarrier.maxWait - 1.5, "the bound runs from arming, not per call")
    b.release()
    eq(b.remainingWait(forKey: "old"), 0, "the merge ran: the call goes")
    check(!b.isArmed, "released: not armed")
    b.arm(doubtfulKeys: ["old"])
    c.t += CredentialMergeBarrier.maxWait + 0.1
    eq(b.remainingWait(forKey: "old"), 0, "past the bound the call goes without the merge")
    check(!b.isArmed, "past the bound: not armed")
    check(CredentialMergeBarrier.maxWait <= 5, "the wait is bounded to a few seconds")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
