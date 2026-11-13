//
//  DispatcharrRequestGate.swift
//  Aerio
//
//  Local gate in front of every Dispatcharr API request. Pure logic: no app
//  singletons, no logging, injectable clocks, so
//  Scripts/dispatcharr-gate-tests/run.sh compiles it with swiftc and drives
//  it with a fake clock. Port of Android core/network/DispatcharrRequestGate.kt
//  (commits 289112b4, fd145f3d, 417efa8d).
//
//  Why (measured 2026-11-09): Dispatcharr throttles API-key auth per client
//  IP (10 FAILED key attempts per minute), and once tripped it answers 429 to
//  EVERY API-key request from that IP, valid keys included. Every device in a
//  home shares that IP. A playlist whose key the server no longer accepts
//  kept retrying on every poll, and each 429 was then retried as well.
//
//  Three pieces:
//   1. Server pause (HTTP 429): the first 429 from a server parks that server
//      (host:port) until Retry-After passes. While parked, requests fail
//      locally with `DispatcharrGateError.rateLimited` and no network request.
//   2. Rejected key: remembered per playlist and key HASH (never the key),
//      memory only. While set, every request carrying that key fails locally
//      with `DispatcharrGateError.keyRejected`. One prompt per rejection.
//   3. Slow re-check while a key is held: 1, 5, and 15 minutes after the
//      rejection, then every 30 minutes, plus app foreground and user
//      refresh, never two probes for one key within 60 s, never inside a 429
//      pause, one in flight at a time.
//

import Foundation
import CryptoKit

// MARK: - Typed errors

/// Failures the gate raises instead of sending a request.
enum DispatcharrGateError: Error, LocalizedError, Equatable, Sendable {
    /// HTTP 429 from a Dispatcharr API call, or a call skipped because an
    /// earlier 429 still pauses the server. `seconds` is the wait left;
    /// `reason` is the server's (stream-429-spec.md UPDATE).
    case rateLimited(seconds: Int, reason: RateLimitReason = .other)
    /// The server already rejected this exact API key and nothing was sent.
    case keyRejected

    var errorDescription: String? {
        switch self {
        case .rateLimited(let s, let reason): return DispatcharrRateLimitCopy.rateLimitedMessage(s, reason: reason)
        case .keyRejected: return DispatcharrRateLimitCopy.keyRejectedErrorMessage
        }
    }

    /// The 429 wait and reason carried by `error` (or one it wraps), nil
    /// when it is not a rate limit.
    static func rateLimit(_ error: Error) -> (seconds: Int, reason: RateLimitReason)? {
        var current: Error? = error
        var depth = 0
        while let e = current, depth < 8 {
            if case DispatcharrGateError.rateLimited(let s, let r)? = e as? DispatcharrGateError { return (s, r) }
            if let final = e as? RateLimitedFinal { return (final.seconds, final.reason) }
            current = (e as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return nil
    }

    /// The 429 wait carried by `error` (or one it wraps through
    /// NSUnderlyingErrorKey), or nil when it is not a rate limit.
    static func rateLimitSeconds(_ error: Error) -> Int? {
        var current: Error? = error
        var depth = 0
        while let e = current, depth < 8 {
            if case DispatcharrGateError.rateLimited(let s, _)? = e as? DispatcharrGateError { return s }
            if let final = e as? RateLimitedFinal { return final.seconds }
            current = (e as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return nil
    }
}

// MARK: - Gate

final class DispatcharrRequestGate: @unchecked Sendable {
    static let shared = DispatcharrRequestGate()

    /// Retry-After when the server sends none (or one we cannot read).
    static let defaultRetryAfter = 60
    /// Never park longer than this, whatever the server asks.
    static let maxRetryAfter = 120

    /// Scheduled re-checks after a rejection: 1, 5, and 15 minutes.
    static let recheckOffsets: [TimeInterval] = [60, 300, 900]
    /// Then one every 30 minutes.
    static let recheckInterval: TimeInterval = 1800
    /// Never two probes for one key within this, whatever asked.
    static let recheckMinGap: TimeInterval = 60
    /// A key a probe just proved good is not probed again for this long.
    static let acceptedMemo: TimeInterval = 60

    /// Monotonic clock in seconds (tests replace it).
    var clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Wall clock, for an HTTP-date Retry-After (tests replace it).
    var wallClock: @Sendable () -> Date = { Date() }
    /// Fired (outside the lock) whenever the pending prompt changes.
    var onPromptChange: (@Sendable (Prompt?) -> Void)?

    private let lock = NSLock()
    private var pausedUntil: [String: TimeInterval] = [:]
    /// The server's reason for each pause (stream-429-spec.md UPDATE).
    private var pausedReason: [String: RateLimitReason] = [:]
    /// Key hash -> the identities (DispatcharrIdentity.key) that saw it rejected:
    /// the playlist's own ("<playlist>") or one of its profiles ("<playlist>|<profile>").
    private var rejected: [String: Set<String>] = [:]
    private var rechecks: [String: Recheck] = [:]
    private var acceptedAt: [String: (at: TimeInterval, mode: String)] = [:]
    /// Key hash -> the key a silent re-login minted in its place, and when.
    private var replacedBy: [String: (key: String, at: TimeInterval)] = [:]
    private var pendingPrompt: Prompt?

    init() {}

    // MARK: Retry-After and the server pause

    /// "host:port" for `url`; the scheme's default port when none is given.
    static func serverKey(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), let host = c.host, !host.isEmpty else {
            var s = trimmed.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let port = c.port ?? ((c.scheme?.lowercased() == "https") ? 443 : 80)
        return "\(host.lowercased()):\(port)"
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
    private static let httpDateLock = NSLock()

    /// Seconds to wait from a Retry-After header: delta seconds (decimals
    /// rounded up) or an HTTP date (RFC 1123). Missing, unreadable, zero,
    /// negative, or a past date = 60 s. Capped at 120 s, at least 1 s.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> Int {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return defaultRetryAfter }
        var secs: Double?
        if let d = Double(v), d.isFinite {
            secs = d.rounded(.up)
        } else {
            httpDateLock.lock()
            let date = httpDateFormatter.date(from: v)
            httpDateLock.unlock()
            if let date {
                let delta = date.timeIntervalSince(now)
                secs = delta > 0 ? delta.rounded(.up) : nil
            }
        }
        guard let s = secs, s > 0 else { return defaultRetryAfter }
        return Int(min(s, Double(maxRetryAfter)).clamped(1, Double(maxRetryAfter)))
    }

    /// Park `server` for `seconds`. A later, longer 429 extends it; a
    /// shorter one never shortens it.
    func pause(_ server: String, seconds: Int, reason: RateLimitReason = .other) {
        let s = min(max(seconds, 1), Self.maxRetryAfter)
        let until = clock() + TimeInterval(s)
        lock.lock()
        pausedUntil[server] = max(pausedUntil[server] ?? 0, until)
        // The latest reason wins: it is what the server says now.
        pausedReason[server] = reason
        lock.unlock()
    }

    /// The server's reason for the current pause (`.other` when unknown).
    func pausedReason(_ server: String) -> RateLimitReason {
        lock.lock(); defer { lock.unlock() }
        return pausedReason[server] ?? .other
    }

    /// Whole seconds left on `server`'s pause, 0 when requests may go out.
    func pausedSeconds(_ server: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let until = pausedUntil[server] else { return 0 }
        let left = until - clock()
        if left <= 0 { pausedUntil[server] = nil; return 0 }
        return Int(left.rounded(.up))
    }

    /// Absolute end of `server`'s pause on `clock`, 0 when not paused.
    func pausedUntilAt(_ server: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return pausedUntil[server] ?? 0
    }

    // MARK: Request inspection helpers

    /// Paths the server pause covers: Dispatcharr's REST root, minus the
    /// login and token refresh endpoints (DispatcharrLoginGate owns those).
    /// Foundation's `URL.path` drops the trailing slash ("/api/accounts/token"),
    /// unlike Android's encodedPath, so the match allows for both; without
    /// that a login 429 paused every API call and never reached the login gate.
    static func isPausedPath(_ path: String) -> Bool {
        guard path.contains("/api/") else { return false }
        let slashed = path.hasSuffix("/") ? path : path + "/"
        return !slashed.contains("/api/accounts/token/")
    }

    /// The API key a request carries: X-API-Key, else `Authorization: ApiKey <k>` or `Bearer <k>`.
    static func requestApiKey(xApiKey: String?, authorization: String?) -> String? {
        if let x = xApiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !x.isEmpty { return x }
        guard let auth = authorization?.trimmingCharacters(in: .whitespacesAndNewlines), !auth.isEmpty else { return nil }
        let parts = auth.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2 else { return nil }
        let scheme = parts[0].lowercased()
        guard scheme == "apikey" || scheme == "bearer" else { return nil }
        let key = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Dispatcharr's own refusal of the key itself (apps/accounts/authentication.py,
    /// ApiKeyAuthentication): "Invalid API key" for an unknown key, "User
    /// inactive" for a key whose account is disabled. Either is proof that no
    /// other header shape will fare better, and each further non-Bearer try
    /// counts toward the server's failed-key lockout (Android parity).
    static func isDispatcharrInvalidKeyBody(_ body: String) -> Bool {
        body.range(of: "Invalid API key", options: .caseInsensitive) != nil
            || body.range(of: "User inactive", options: .caseInsensitive) != nil
    }

    // MARK: Rejected key

    /// One "Sign-in not accepted" prompt. `passwordToo` = the playlist also
    /// has a password and its re-login was refused as well.
    struct Prompt: Equatable, Sendable {
        let playlistID: String
        let playlistName: String
        let passwordToo: Bool
        /// The stored password signed in, but the account has no API key
        /// (removed on the server): the prompt says so (2026-11-11).
        var noKey: Bool = false
        /// A non-default profile's own key (nil: the playlist's): its Sign In
        /// signs that profile in, never the playlist (Android fc04722f).
        var profileID: String? = nil

        var identity: DispatcharrIdentity { DispatcharrIdentity(playlistID: playlistID, profileID: profileID) }
    }

    /// SHA-256 prefix (12 bytes, hex) of the trimmed key: what the gate
    /// remembers instead of the key.
    static func keyHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    var prompt: Prompt? {
        lock.lock(); defer { lock.unlock() }
        return pendingPrompt
    }

    /// Remember that the server rejected `key` for `playlistID`. True only on
    /// the transition (first rejection of this key for this playlist), and
    /// only then is the prompt raised. A non-empty `baseURL` also starts the
    /// slow re-check.
    @discardableResult
    func markKeyRejected(playlistID: String, key: String, playlistName: String = "",
                         passwordToo: Bool = false, noKey: Bool = false, baseURL: String = "",
                         profileID: String? = nil) -> Bool {
        let hash = Self.keyHash(key)
        let who = DispatcharrIdentity(playlistID: playlistID, profileID: profileID)
        lock.lock()
        var set = rejected[hash] ?? []
        let fresh = set.insert(who.key).inserted
        rejected[hash] = set
        var changed: Prompt?? = nil
        if fresh {
            let p = Prompt(playlistID: playlistID, playlistName: playlistName, passwordToo: passwordToo, noKey: noKey,
                           profileID: profileID)
            pendingPrompt = p
            changed = .some(p)
            if !baseURL.isEmpty, rechecks[hash] == nil {
                rechecks[hash] = Recheck(hash: hash, key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                         baseURL: baseURL, serverKey: Self.serverKey(baseURL),
                                         playlistID: playlistID, passwordToo: passwordToo,
                                         rejectedAt: clock(), profileID: profileID)
            }
        }
        acceptedAt[hash] = nil
        lock.unlock()
        if let changed { onPromptChange?(changed) }
        return fresh
    }

    /// Laid over the requests of a held profile kept active (a Child after a
    /// server address change, ProfileHostHold): never a real key, never sent.
    /// Every request and stream carrying it stops here, so the Child neither
    /// sends its held key nor falls back to the default profile's.
    static let HELD_PROFILE_KEY = "aerio-held-profile"

    /// Marks the only requests that may reach a held playlist's addresses: the
    /// same-server check and the held profile's sign-in form. Stripped before sending.
    static let HELD_CHECK_HEADER = "X-Aerio-Held-Check"

    /// What a held profile's refused lists and streams show (item 15): the
    /// existing "Could not reach your Dispatcharr server" line
    /// (DsyncManualCopy.DISPATCHARR_UNREACHABLE), as on Android; never
    /// "Can't reach <host>" or the rejected-key copy.
    static let HELD_UNREACHABLE = "Could not reach your Dispatcharr server"

    /// userInfo flag on a held profile's refusal: the request never left.
    static let HELD_REFUSAL_KEY = "AerioHeldProfileRefusal"

    /// The error a held profile's refused request throws: still a
    /// cannot-connect URLError for every caller that branches on the code,
    /// carrying the held line as its description.
    static func heldRefusal() -> URLError {
        URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: HELD_UNREACHABLE, HELD_REFUSAL_KEY: true])
    }

    /// True when [error], or one it wraps, is a held profile's refusal.
    static func isHeldRefusal(_ error: Error) -> Bool {
        var current: Error? = error
        var depth = 0
        while let e = current, depth < 8 {
            let ns = e as NSError
            if ns.userInfo[HELD_REFUSAL_KEY] as? Bool == true { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return false
    }

    /// The list line for [error]: the held line for a held refusal; nil keeps the existing copy.
    static func heldListMessage(_ error: Error) -> String? { isHeldRefusal(error) ? HELD_UNREACHABLE : nil }

    /// Playlist id -> its server keys ("host:port") while a held profile is
    /// its active one (a Child after a server change).
    private var heldServers: [String: Set<String>] = [:]

    /// While a held profile is [playlistID]'s active one, every Dispatcharr
    /// request to [serverKeys] stops here unless marked HELD_CHECK_HEADER, so
    /// nothing goes out as the held profile or as the default profile.
    func holdServers(playlistID: String, _ serverKeys: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        heldServers[playlistID] = serverKeys.isEmpty ? nil : serverKeys
    }

    func releaseServers(playlistID: String) {
        lock.lock(); defer { lock.unlock() }
        heldServers[playlistID] = nil
    }

    /// [url] is a held playlist's address: nothing may be requested from it,
    /// logos and artwork included (their placeholder shows).
    func isHeldServer(_ url: URL?) -> Bool { url.map { isHeldServer($0.absoluteString) } ?? false }

    /// [url], or nil when it is a held playlist's address: loaders outside
    /// HTTPRouter (AsyncImage) then show their placeholder with no request.
    static func unlessHeld(_ url: URL?) -> URL? { shared.isHeldServer(url) ? nil : url }

    /// True when a request to [url] must stop: it is a held playlist's address.
    func isHeldServer(_ url: String) -> Bool {
        let key = Self.serverKey(url)
        lock.lock(); defer { lock.unlock() }
        return heldServers.values.contains { $0.contains(key) }
    }

    /// True while `key` is known rejected (any playlist), or is the held-profile placeholder.
    func isKeyRejected(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == Self.HELD_PROFILE_KEY { return true }
        let hash = Self.keyHash(trimmed)
        lock.lock(); defer { lock.unlock() }
        return !(rejected[hash]?.isEmpty ?? true)
    }

    /// True while the playlist's OWN key (the default profile's) is held as rejected.
    func isPlaylistRejected(_ playlistID: String) -> Bool { isIdentityRejected(.playlist(playlistID)) }

    /// True while [who]'s key is held as rejected.
    func isIdentityRejected(_ who: DispatcharrIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rejected.values.contains { $0.contains(who.key) }
    }

    /// An explicit save for the playlist: forget ITS OWN rejection and prompt.
    /// A non-default profile's held key stays held (holds are per identity):
    /// only that profile's own sign-in, or its key proving good, releases it.
    func clearPlaylist(_ playlistID: String) { clearIdentity(.playlist(playlistID)) }

    /// Forget [who]'s rejection and its prompt; every other identity's stays.
    func clearIdentity(_ who: DispatcharrIdentity) {
        lock.lock()
        for (hash, ids) in rejected {
            var s = ids
            s.remove(who.key)
            rejected[hash] = s.isEmpty ? nil : s
        }
        rechecks = rechecks.filter { rejected[$0.key] != nil }
        let cleared = pendingPrompt?.identity == who
        if cleared { pendingPrompt = nil }
        lock.unlock()
        if cleared { onPromptChange?(nil) }
    }

    /// `key` just authenticated (or the user typed it on purpose): good again everywhere.
    func clearKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hash = Self.keyHash(trimmed)
        lock.lock()
        rechecks[hash] = nil
        let ids = rejected.removeValue(forKey: hash) ?? []
        let cleared = pendingPrompt.map { ids.contains($0.identity.key) } ?? false
        if cleared { pendingPrompt = nil }
        lock.unlock()
        if cleared { onPromptChange?(nil) }
    }

    /// The prompt was shown and answered (or dismissed).
    func consumePrompt() {
        lock.lock()
        let had = pendingPrompt != nil
        pendingPrompt = nil
        lock.unlock()
        if had { onPromptChange?(nil) }
    }

    /// A probe proved `key` good in header shape `mode`: no probe again for
    /// `acceptedMemo` seconds, so an endpoint-specific 401 for a good key does
    /// not double every request.
    // MARK: Keys a silent re-login replaced

    /// How long a replaced key is rewritten to its successor: long enough for
    /// every request built before the swap to drain.
    static let replacementMemo: TimeInterval = 600

    /// The silent re-login (stored username and password) minted `new` after
    /// the server refused `old`: requests still carrying `old` go out with
    /// `new` (no failed attempt, no probe, no hold), as on Android.
    func noteKeyReplaced(old: String, new: String) {
        let o = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !n.isEmpty, o != n else { return }
        let hash = Self.keyHash(o)
        lock.lock()
        replacedBy[hash] = (n, clock())
        lock.unlock()
    }

    /// Fix Login wrote a new sign-in for `playlistID` (docs/DeviceSetupHandoff.md):
    /// its hold and prompt are lifted, `newKey` counts as good, and requests or
    /// streams still built with `oldKey` go out with `newKey`.
    func liftFixedLogin(playlistID: String, oldKey: String?, newKey: String?) {
        clearPlaylist(playlistID)
        if let n = newKey?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            clearKey(n)
            if let o = oldKey { noteKeyReplaced(old: o, new: n) }
        }
    }

    /// The key that replaced `key` within the memo window, or nil.
    func replacementKey(for key: String) -> String? {
        let hash = Self.keyHash(key)
        lock.lock(); defer { lock.unlock() }
        guard let r = replacedBy[hash] else { return nil }
        if clock() - r.at > Self.replacementMemo { replacedBy[hash] = nil; return nil }
        return r.key
    }

    /// The request's auth headers with a replaced key swapped for its
    /// successor, or nil when nothing changes. Keeps the header shape:
    /// X-API-Key, `ApiKey <k>`, or `Bearer <k>`.
    func rewritingReplacedKey(xApiKey: String?, authorization: String?) -> (xApiKey: String?, authorization: String?)? {
        guard let old = Self.requestApiKey(xApiKey: xApiKey, authorization: authorization),
              let new = replacementKey(for: old) else { return nil }
        var x = xApiKey
        if let v = x, v.trimmingCharacters(in: .whitespacesAndNewlines) == old { x = new }
        var auth = authorization
        if let a = auth {
            let parts = a.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2, parts[1].trimmingCharacters(in: .whitespacesAndNewlines) == old {
                auth = "\(parts[0]) \(new)"
            }
        }
        return (x, auth)
    }

    /// What a 401 that proved the key bad leads to (Android parity): a
    /// playlist with a stored username and password re-signs in first and
    /// carries on with the new key; only no password, or a refused login,
    /// holds the key and asks for Edit Playlist.
    enum RejectedKeyStep: Equatable, Sendable { case relogin, hold }
    static func afterRejectedKey(hasStoredPassword: Bool, loginRefused: Bool) -> RejectedKeyStep {
        hasStoredPassword && !loginRefused ? .relogin : .hold
    }

    func noteKeyAccepted(_ key: String, mode: String) {
        let hash = Self.keyHash(key)
        lock.lock()
        acceptedAt[hash] = (clock(), mode)
        lock.unlock()
    }

    /// The header shape a probe proved for `key` within the memo window, or nil.
    func recentlyAcceptedMode(_ key: String) -> String? {
        let hash = Self.keyHash(key)
        lock.lock(); defer { lock.unlock() }
        guard let a = acceptedAt[hash] else { return nil }
        if clock() - a.at > Self.acceptedMemo { acceptedAt[hash] = nil; return nil }
        return a.mode
    }

    // MARK: Slow re-check while held

    /// One held key's re-check state. `key` stays in memory only, to probe with.
    final class Recheck: @unchecked Sendable {
        let hash: String
        let key: String
        let baseURL: String
        let serverKey: String
        let playlistID: String
        /// A non-default profile's own key (nil: the playlist's): its probe is
        /// that profile's own re-login, or one key probe, never the playlist's.
        let profileID: String?
        /// Password playlist whose re-login was refused: the probe is one login.
        let passwordToo: Bool
        let rejectedAt: TimeInterval
        /// Scheduled probes run so far. Guarded by the gate's lock.
        fileprivate(set) var scheduledDone = 0
        fileprivate(set) var lastProbeAt: TimeInterval = -.greatestFiniteMagnitude / 2
        fileprivate(set) var inFlight = false

        init(hash: String, key: String, baseURL: String, serverKey: String,
             playlistID: String, passwordToo: Bool, rejectedAt: TimeInterval, profileID: String? = nil) {
            self.hash = hash
            self.key = key
            self.baseURL = baseURL
            self.serverKey = serverKey
            self.playlistID = playlistID
            self.profileID = profileID
            self.passwordToo = passwordToo
            self.rejectedAt = rejectedAt
        }

        var identity: DispatcharrIdentity { DispatcharrIdentity(playlistID: playlistID, profileID: profileID) }
    }

    /// Due time of scheduled probe number `done` (0-based) after `rejectedAt`.
    static func scheduledDueAt(rejectedAt: TimeInterval, done: Int) -> TimeInterval {
        if done < recheckOffsets.count { return rejectedAt + recheckOffsets[done] }
        return rejectedAt + recheckOffsets[recheckOffsets.count - 1]
            + TimeInterval(done - recheckOffsets.count + 1) * recheckInterval
    }

    /// Held keys with a re-check (snapshot).
    func allRechecks() -> [Recheck] {
        lock.lock(); defer { lock.unlock() }
        return Array(rechecks.values)
    }

    /// Earliest time `r`'s next scheduled probe may run: its slot, no sooner
    /// than `recheckMinGap` after the last probe, never inside a 429 pause
    /// for its server, nor before `extraBlockedUntil` (a login-gate park).
    func nextScheduledAt(_ r: Recheck, extraBlockedUntil: TimeInterval = 0) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return nextScheduledAtLocked(r, extraBlockedUntil)
    }

    private func nextScheduledAtLocked(_ r: Recheck, _ extra: TimeInterval) -> TimeInterval {
        max(Self.scheduledDueAt(rejectedAt: r.rejectedAt, done: r.scheduledDone),
            r.lastProbeAt + Self.recheckMinGap,
            pausedUntil[r.serverKey] ?? 0,
            extra)
    }

    /// Claim a scheduled probe for `r` if one is due now; true = run it
    /// (exactly one request, or one re-login).
    func claimScheduled(_ r: Recheck, extraBlockedUntil: TimeInterval = 0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !r.inFlight, rechecks[r.hash] === r else { return false }
        let now = clock()
        guard now >= nextScheduledAtLocked(r, extraBlockedUntil) else { return false }
        r.scheduledDone += 1
        r.lastProbeAt = now
        r.inFlight = true
        return true
    }

    /// Claim an on-demand probe (app foreground, a user refresh): allowed
    /// only `recheckMinGap` after the last probe of any kind and outside a
    /// 429 pause. Does not advance the schedule.
    func claimOnDemand(_ r: Recheck, extraBlockedUntil: TimeInterval = 0) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !r.inFlight, rechecks[r.hash] === r else { return false }
        let now = clock()
        if now < r.lastProbeAt + Self.recheckMinGap { return false }
        if now < (pausedUntil[r.serverKey] ?? 0) || now < extraBlockedUntil { return false }
        r.lastProbeAt = now
        r.inFlight = true
        return true
    }

    /// A probe for `r` finished; `accepted` clears the hold and its prompt.
    func finishProbe(_ r: Recheck, accepted: Bool) {
        lock.lock()
        r.inFlight = false
        var cleared = false
        if accepted {
            if rechecks[r.hash] === r { rechecks[r.hash] = nil }
            let ids = rejected.removeValue(forKey: r.hash) ?? []
            if let p = pendingPrompt, ids.contains(p.identity.key) || p.identity == r.identity {
                pendingPrompt = nil
                cleared = true
            }
        }
        lock.unlock()
        if cleared { onPromptChange?(nil) }
    }

    /// Earliest next scheduled probe over every held key, or nil with none held.
    func earliestScheduledAt(extraBlockedUntil: (Recheck) -> TimeInterval = { _ in 0 }) -> TimeInterval? {
        let all = allRechecks()
        let extras = all.map { extraBlockedUntil($0) }
        lock.lock(); defer { lock.unlock() }
        return zip(all, extras).map { nextScheduledAtLocked($0, $1) }.min()
    }

    /// Test hook: forget everything.
    func resetForTests() {
        lock.lock()
        pausedUntil.removeAll()
        rejected.removeAll()
        rechecks.removeAll()
        acceptedAt.removeAll()
        pendingPrompt = nil
        lock.unlock()
    }
}

// MARK: - 429 reasons (stream-429-spec.md, UPDATE 2026-11-10)

/// Why Dispatcharr answered 429, read from its body. Every 429 the app shows
/// (API calls, sign-in, streams) names the reason.
enum RateLimitReason: String, Equatable, Sendable {
    /// "Too many API key attempts. Try again later." (apps/accounts/authentication.py)
    case apiKeyLockout
    /// "Too many login attempts. Try again later."
    case signInLockout
    /// Any other 429.
    case other
}

/// A Dispatcharr 429, classified. Pure so the gate tests can check every
/// body shape (JSON "detail" or "error", plain text, unknown).
enum Dispatcharr429: Equatable, Sendable {
    /// Rate limited: wait `seconds` (Retry-After, else the gate default), then retry.
    case rateLimited(RateLimitReason, seconds: Int)
    /// The per-user stream limit: no retry. `count` from the server's text when it has one.
    case streamLimit(count: Int?)

    static let apiKeyLockoutPhrase = "Too many API key attempts"
    static let signInLockoutPhrase = "Too many login attempts"
    static let streamLimitPhrase = "Stream limit exceeded"

    /// The server's sentence: JSON "detail" or "error", else the plain-text body.
    static func reasonText(_ body: Data?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: body) {
            guard let dict = object as? [String: Any] else { return nil }
            for key in ["detail", "error"] {
                if let text = (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
            }
            return nil
        }
        let raw = String(decoding: body.prefix(1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    static func classify(body: Data?, retryAfter: String?, now: Date = Date()) -> Dispatcharr429 {
        classify(reasonText: reasonText(body), retryAfter: retryAfter, now: now)
    }

    /// Matches the leading phrase case-insensitively (spec).
    static func classify(reasonText: String?, retryAfter: String?, now: Date = Date()) -> Dispatcharr429 {
        let text = (reasonText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func leads(_ phrase: String) -> Bool {
            text.range(of: phrase, options: [.caseInsensitive, .anchored]) != nil
        }
        if leads(streamLimitPhrase) { return .streamLimit(count: streamCount(text)) }
        let seconds = DispatcharrRequestGate.parseRetryAfter(retryAfter, now: now)
        if leads(apiKeyLockoutPhrase) { return .rateLimited(.apiKeyLockout, seconds: seconds) }
        if leads(signInLockoutPhrase) { return .rateLimited(.signInLockout, seconds: seconds) }
        return .rateLimited(.other, seconds: seconds)
    }

    /// "Stream limit exceeded (2 concurrent streams allowed)" -> 2.
    static func streamCount(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "(") else { return nil }
        let digits = text[text.index(after: open)...].prefix { $0.isNumber }
        return Int(digits)
    }
}

extension DispatcharrRequestGate {
    /// Seconds a stream open to `url`'s server must still wait: no stream
    /// opens (first try, retry, or failover) while the server is paused
    /// after a 429. 0 = go ahead.
    func streamOpenWaitSeconds(_ url: String) -> Int {
        pausedSeconds(Self.serverKey(url))
    }

    /// A stream 429: a rate limit pauses the server exactly like an API
    /// 429; a stream-limit refusal changes nothing here.
    func noteStream429(_ url: String, _ refusal: Dispatcharr429) {
        if case .rateLimited(let reason, let seconds) = refusal {
            pause(Self.serverKey(url), seconds: seconds, reason: reason)
        }
    }
}

// MARK: - Single flight

/// One task in flight per key: callers that arrive while it runs await its
/// result instead of starting their own. Used for the 401 key probe, where
/// every extra probe of a bad key costs one attempt of the server's
/// failed-key budget (Android parity). The key is released when the task
/// finishes, so a later call starts fresh.
final class SingleFlight<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [String: Task<Value, Error>] = [:]

    init() {}

    /// The value of the task in flight for `key`, or of `work` started as the
    /// new one. `owner` is true only for the caller whose `work` ran.
    func run(_ key: String,
             _ work: @escaping @Sendable () async throws -> Value) async throws -> (value: Value, owner: Bool) {
        let (task, owner): (Task<Value, Error>, Bool) = lock.withLock {
            if let running = inFlight[key] { return (running, false) }
            let started = Task { try await work() }
            inFlight[key] = started
            return (started, true)
        }
        defer { if owner { lock.withLock { inFlight[key] = nil } } }
        return (try await task.value, owner)
    }

    /// Tasks in flight right now (tests).
    var count: Int { lock.withLock { inFlight.count } }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - Stream opens and 401s (2026-11-10)

/// Stream opens (live and catch-up ingest, Multiview tiles, MKV VOD and DVR,
/// the Cast proxy) carry the playlist's API key as headers. A Google TV
/// on an older build sent a dead key on every stream retry (60 401s, then
/// 180 lockout 429s in three minutes). Every open now re-reads its headers
/// through the gate, and a 401 goes through the key broker exactly as an
/// API call does. Pure logic; the gate tests check it.
enum StreamKeyGate {
    enum Open: Equatable {
        /// Open with these headers (a replaced key already swapped for its successor).
        case send([String: String])
        /// The key is held as rejected: no open, no request.
        case held
    }

    static func header(_ h: [String: String], _ name: String) -> String? {
        h.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func set(_ h: inout [String: String], _ name: String, _ value: String?) {
        let existing = h.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        if let existing { h[existing] = value } else if let value { h[name] = value }
    }

    /// The API key a stream open carries (nil when none).
    static func apiKey(in h: [String: String]) -> String? {
        DispatcharrRequestGate.requestApiKey(xApiKey: header(h, "X-API-Key"), authorization: header(h, "Authorization"))
    }

    /// The held-profile placeholder rides these headers (a held Child): the
    /// open stops with the held line, not the rejected-key notice (item 15).
    static func isProfileHeld(_ h: [String: String]) -> Bool {
        apiKey(in: h)?.trimmingCharacters(in: .whitespacesAndNewlines) == DispatcharrRequestGate.HELD_PROFILE_KEY
    }

    /// Re-read before every open, retry, and reconnect: a key the silent
    /// re-login replaced goes out as its successor; a key held as rejected
    /// never goes out again.
    static func headersForOpen(_ headers: [String: String], gate: DispatcharrRequestGate = .shared) -> Open {
        var h = headers
        if let swapped = gate.rewritingReplacedKey(xApiKey: header(h, "X-API-Key"), authorization: header(h, "Authorization")) {
            set(&h, "X-API-Key", swapped.xApiKey)
            set(&h, "Authorization", swapped.authorization)
        }
        if let key = apiKey(in: h), gate.isKeyRejected(key) { return .held }
        return .send(h)
    }

    enum Probe: Equatable, Sendable { case accepted, rejected, unknown }

    enum After401: Equatable, Sendable {
        /// Open once more: with the re-login's new key, or (nil) the same
        /// key the probe proved good (the stream refused something else).
        case retry(newKey: String?)
        /// The key is held; the playlist prompts. No further opens with it.
        case held
        /// Nothing proven (no answer): the normal failure path, never a
        /// loop on the key (the next open re-reads the headers).
        case unchanged
    }

    /// What a stream 401 leads to: the probe's answer, then a silent
    /// re-login when the playlist stores a password, else the hold.
    static func after401(probe: Probe, reloginTried: Bool, newKey: String?, oldKey: String) -> After401 {
        switch probe {
        case .accepted: return .retry(newKey: nil)
        case .unknown: return .unchanged
        case .rejected:
            if reloginTried, let n = newKey, !n.isEmpty, n != oldKey { return .retry(newKey: n) }
            return .held
        }
    }

    /// One broker round per open: a second 401 right after a retry is not
    /// probed again (the next open re-reads, and a held key never opens).
    static let retriesPerOpen = 1
}

// MARK: - Launch credential barrier (2026-11-10)

/// At launch iCloud may carry a newer key than this device's for a
/// playlist. A Dispatcharr API call carrying such a key waits (bounded) for
/// the iCloud credential merge, so a stale device adopts iCloud's key
/// instead of spending failed attempts on its own. A call carrying any other
/// key, and every call once the merge ran or the bound passed, goes out at
/// once, so a launch whose keys agree with iCloud never waits.
final class CredentialMergeBarrier: @unchecked Sendable {
    static let shared = CredentialMergeBarrier()

    /// Bound on the wait, from arming. Measured 2026-11-10 on an Apple TV:
    /// the iCloud merge lands 3.2 to 3.3 s after launch.
    static let maxWait: TimeInterval = 4

    /// Monotonic clock in seconds (tests replace it).
    var clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private let lock = NSLock()
    /// Hashes of the local keys the merge may replace.
    private var doubtful: Set<String> = []
    private var deadline: TimeInterval = 0

    struct Entry: Equatable, Sendable {
        let localKey: String
        let localChangedAt: TimeInterval
        let cloudKey: String
        let cloudChangedAt: TimeInterval
    }

    /// The local keys the iCloud merge may replace: iCloud carries a
    /// different, non-empty key for the playlist, and this device's key is
    /// not known to be the newer one (CredentialSyncRule).
    static func doubtfulKeys(_ entries: [Entry]) -> [String] {
        entries.compactMap { e in
            let l = e.localKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = e.cloudKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !l.isEmpty, !c.isEmpty, l != c else { return nil }
            if e.localChangedAt > 0, e.localChangedAt >= e.cloudChangedAt { return nil }
            return l
        }
    }

    /// Arm at launch with the keys the merge may replace (empty: nothing waits).
    func arm(doubtfulKeys keys: [String]) {
        lock.lock()
        doubtful = Set(keys.map(DispatcharrRequestGate.keyHash))
        deadline = clock() + Self.maxWait
        lock.unlock()
    }

    /// The iCloud credential merge ran: every waiter goes now.
    func release() {
        lock.lock(); doubtful = []; lock.unlock()
    }

    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return !doubtful.isEmpty && clock() < deadline
    }

    /// Seconds a call carrying `key` should still wait (0 = send now).
    func remainingWait(forKey key: String?) -> TimeInterval {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let hash = DispatcharrRequestGate.keyHash(key)
        lock.lock(); defer { lock.unlock() }
        guard doubtful.contains(hash) else { return 0 }
        let left = deadline - clock()
        if left <= 0 { doubtful = []; return 0 }
        return left
    }

    /// Wait until released or the bound passes. Returns the seconds waited.
    @discardableResult
    func wait(forKey key: String?) async -> TimeInterval {
        guard remainingWait(forKey: key) > 0 else { return 0 }
        let start = clock()
        while remainingWait(forKey: key) > 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return clock() - start
    }
}

// MARK: - Sign-in identity (Android fc04722f)

/// Whose sign-in a key or a login belongs to: the playlist's own (the default
/// profile's), or one non-default profile of it. Holds, the silent re-login,
/// and login sharing are kept per identity, never per playlist alone, so the
/// default's fresh login is never handed to a profile, nor the reverse.
struct DispatcharrIdentity: Hashable, Sendable, CustomStringConvertible {
    let playlistID: String
    /// nil = the playlist's own sign-in (the default profile).
    let profileID: String?

    static func playlist(_ playlistID: String) -> DispatcharrIdentity {
        DispatcharrIdentity(playlistID: playlistID, profileID: nil)
    }

    var isPlaylist: Bool { profileID == nil }

    /// "<playlist>" or "<playlist>|<profile>".
    var key: String { profileID.map { playlistID + "|" + $0 } ?? playlistID }

    var description: String {
        String(playlistID.prefix(8)) + (profileID.map { "/" + String($0.prefix(8)) } ?? "")
    }

    /// The login share's slot: this identity and these credentials.
    func loginSlot(username: String, password: String) -> String {
        let digest = SHA256.hash(data: Data((username + "\u{1F}" + password).utf8))
        return key + "|" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Who may re-sign in after a key was proven rejected (Android fc04722f).
enum DispatcharrRelogin {
    enum Plan: Equatable, Sendable {
        /// The playlist's own username and stored password (its own identity).
        case asPlaylist
        /// The non-default profile's own username and stored password.
        case asProfile
        /// Nobody: the key is held and the identity prompts.
        case none
    }

    /// A non-default profile re-signs in ONLY as itself, with its own stored
    /// password; with none, nobody does. Never the playlist's password for a
    /// profile. The playlist's own identity uses the playlist's password.
    static func plan(_ who: DispatcharrIdentity, ownPassword: Bool, playlistPassword: Bool) -> Plan {
        if who.isPlaylist { return playlistPassword ? .asPlaylist : .none }
        return ownPassword ? .asProfile : .none
    }

    /// iCloud carries the playlist's own key only: never adopted for a profile.
    static func mayAdoptCloudKey(_ who: DispatcharrIdentity) -> Bool { who.isPlaylist }

    /// A re-login that waited through a profile switch: the playlist's active
    /// identity changed since it started, so it writes nothing.
    static func overtaken(activeAtStart: DispatcharrIdentity, activeNow: DispatcharrIdentity) -> Bool {
        activeAtStart != activeNow
    }

    /// What the one request checking a just-minted key said.
    enum Proof: Equatable, Sendable { case accepted, refused, unknown }

    /// A re-login signed in and read the account's key: EXACTLY one request
    /// checks that key before anything stores or sends it. The server refusing
    /// it ends the re-login as `.keyRefused`: the identity parks for the
    /// window, no caller gets the key, and the old key is held, so a key the
    /// server still refuses never goes out again (2026-11-12, Android parity:
    /// it was never held, and about 15 refused requests went out in a second,
    /// tripping Dispatcharr's 10 per minute IP lockout). No answer (network,
    /// 5xx) is not a refusal: the key is used, but as unproven (ReloginBook).
    static func outcome(minted key: String, proof: Proof) -> ReloginBook.Outcome {
        switch proof {
        case .accepted: return .key(key)
        case .refused: return .keyRefused
        case .unknown: return .keyUnproven(key)
        }
    }
}

/// The silent re-login rules, per identity (DispatcharrLoginGate): at most one
/// attempt per identity per window, shared by concurrent callers and reused
/// inside the window by that identity only; a rejected login parks that
/// identity; a sign-in that found no API key parks it too. Pure; the gate
/// holds the tasks and the lock.
struct ReloginBook: Sendable {
    enum Claim: Equatable, Sendable { case wait, parked(Int), shared(String?, Int), mine }
    enum Outcome: Equatable, Sendable {
        /// A key that passed its one-request check.
        case key(String)
        case failed, rejected
        /// Signed in, but the server refused the key it issued (DispatcharrRelogin.outcome).
        case keyRefused
        /// A key whose check got no answer (network, 5xx): used, but never proven.
        case keyUnproven(String)
    }

    let window: TimeInterval
    private var inFlight: Set<String> = []
    private var lastAttemptAt: [String: TimeInterval] = [:]
    private var lastKey: [String: String] = [:]
    private var rejectedUntil: [String: TimeInterval] = [:]
    private var noKeyUntil: [String: TimeInterval] = [:]
    private var keyRefusedUntil: [String: TimeInterval] = [:]
    /// The last key passed its check when it was issued.
    private var lastKeyProven: [String: Bool] = [:]

    init(window: TimeInterval = 60) { self.window = window }

    /// [refusedKey]: the key the server just refused, which sent this caller
    /// here. A finished re-login is shared only when its key differs from it
    /// (retry with that key); in flight, it is always shared (2026-11-12,
    /// Android parity).
    mutating func claim(_ who: DispatcharrIdentity, now: TimeInterval, refusedKey: String? = nil) -> Claim {
        let k = who.key
        if inFlight.contains(k) { return .wait }
        if let until = rejectedUntil[k], until > now { return .parked(Int((until - now).rounded(.up))) }
        // Its last re-login minted a key the server refused: no new attempt, and
        // nobody gets that key, for the window.
        if let until = keyRefusedUntil[k], until > now { return .parked(Int((until - now).rounded(.up))) }
        if let last = lastAttemptAt[k], now - last < window {
            let shared = lastKey[k]
            guard let refused = refusedKey, let key = shared, key == refused else {
                return .shared(shared, Int(now - last))
            }
            // The key this re-login handed out is the one just refused.
            if lastKeyProven[k] != true {
                // Handed out unproven and refused before it ever succeeded: the
                // end of the road for the window, as a refused check is.
                noteKeyRefused(who, now: now)
                return .parked(Int(window))
            }
            // It passed its check when issued and worked since: the server has
            // rotated it again. A fresh re-login (its own one-request check
            // still applies), never a hold on a stale shared result.
        }
        lastAttemptAt[k] = now
        lastKey[k] = nil
        lastKeyProven[k] = nil
        inFlight.insert(k)
        return .mine
    }

    /// True when [refusedKey] is the key [who]'s last re-login issued and it
    /// passed its check: a server-side rotation, not a refused re-login.
    func isRotation(_ who: DispatcharrIdentity, refusedKey: String?, now: TimeInterval) -> Bool {
        guard let refusedKey, let last = lastAttemptAt[who.key], now - last < window else { return false }
        return lastKey[who.key] == refusedKey && lastKeyProven[who.key] == true
    }

    /// The attempt [who] claimed finished; the key it minted, if any.
    @discardableResult
    mutating func finish(_ who: DispatcharrIdentity, _ outcome: Outcome, now: TimeInterval) -> String? {
        let k = who.key
        inFlight.remove(k)
        switch outcome {
        case .key(let key): lastKey[k] = key; lastKeyProven[k] = true; return key
        case .keyUnproven(let key): lastKey[k] = key; lastKeyProven[k] = false; return key
        case .failed: return nil
        case .rejected: rejectedUntil[k] = now + window; return nil
        case .keyRefused: lastKey[k] = nil; lastKeyProven[k] = nil; keyRefusedUntil[k] = now + window; return nil
        }
    }

    func isRejected(_ who: DispatcharrIdentity, now: TimeInterval) -> Bool { (rejectedUntil[who.key] ?? 0) > now }

    /// True when the park is new (log it once).
    @discardableResult
    mutating func noteRejected(_ who: DispatcharrIdentity, now: TimeInterval) -> Bool {
        if isRejected(who, now: now) { return false }
        rejectedUntil[who.key] = now + window
        return true
    }

    mutating func clearRejected(_ who: DispatcharrIdentity) {
        rejectedUntil[who.key] = nil
        noKeyUntil[who.key] = nil
        keyRefusedUntil[who.key] = nil
    }

    /// A key [who]'s re-login handed out unproven was refused before it ever
    /// succeeded: park like a refused check, and nobody gets it again for the
    /// window (claim). A key that passed its check and is refused later is a
    /// rotation, never this.
    mutating func noteKeyRefused(_ who: DispatcharrIdentity, now: TimeInterval) {
        lastKey[who.key] = nil
        lastKeyProven[who.key] = nil
        keyRefusedUntil[who.key] = now + window
    }
    func foundRefusedKey(_ who: DispatcharrIdentity, now: TimeInterval) -> Bool { (keyRefusedUntil[who.key] ?? 0) > now }

    mutating func noteNoKey(_ who: DispatcharrIdentity, now: TimeInterval) { noKeyUntil[who.key] = now + window }
    func foundNoKey(_ who: DispatcharrIdentity, now: TimeInterval) -> Bool { (noKeyUntil[who.key] ?? 0) > now }
    mutating func clearNoKey(_ who: DispatcharrIdentity) { noKeyUntil[who.key] = nil }
}

// MARK: - Deleted playlists, per instance

/// Work for a playlist that was deleted, by instance. A delete bumps the
/// playlist id's generation; work notes the generation when it starts and
/// stops at its next resume once it changed. A playlist id can come back:
/// Set up another device creates the playlist with the sender's id, and
/// iCloud sync restores a playlist under its own id. The re-created
/// playlist's work starts at the new generation and runs, while
/// late work from the deleted instance stays stopped. (A set of deleted ids
/// stopped the re-created playlist's work too, until the app restarted;
/// Android hit that on 2026-11-12.)
struct PlaylistGenerations: Sendable {
    private var bumps: [UUID: Int] = [:]

    /// The generation work for [id] started now belongs to.
    func current(_ id: UUID) -> Int { bumps[id] ?? 0 }

    /// The playlist [id] was deleted: work started before now stops.
    mutating func deleted(_ id: UUID) { bumps[id, default: 0] += 1 }

    /// True when work started at [generation] must stop: its playlist was
    /// deleted since (even if one with the same id exists again).
    func isStale(_ id: UUID, since generation: Int) -> Bool { current(id) != generation }
}

// MARK: - A deleted playlist: no request of any kind (owner 2026-11-12)

/// What identifies a deleted playlist's traffic: its API keys (the playlist's
/// own and its profiles'), the secrets an Xtream Codes or M3U playlist carries
/// in its URLs, and the server hosts no remaining playlist uses. Never logged.
struct PlaylistFingerprint: Sendable, Equatable {
    var playlistID: String
    /// Dispatcharr API keys (X-API-Key, or Authorization ApiKey / Bearer).
    var keys: Set<String> = []
    /// URL fragments only this playlist's requests carry: "/<user>/<pass>/",
    /// "username=<user>&password=<pass>", the M3U and XMLTV URLs.
    var urlSecrets: [String] = []
    /// "host:port" keys (DispatcharrRequestGate.serverKey) that no remaining
    /// playlist uses, so anything sent there was for this playlist.
    var hosts: Set<String> = []

    /// Xtream Codes credentials as they appear in request URLs.
    static func xtreamSecrets(username: String, password: String) -> [String] {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !p.isEmpty else { return [] }
        return ["/\(u)/\(p)/", "username=\(u)&password=\(p)"]
    }

    var isEmpty: Bool { keys.isEmpty && urlSecrets.isEmpty && hosts.isEmpty }
}

/// Deleted playlists, by fingerprint, in memory: a request that carries one
/// of them (a late retry, a timer, a re-check, an image load) is refused
/// before it is sent, and an answer that arrives after the delete is dropped.
/// A playlist the user signs in to again (re-added, set up from another
/// device, restored from iCloud) lifts the entries it matches.
struct PlaylistRevocationBook: Sendable {
    private(set) var revoked: [String: PlaylistFingerprint] = [:]

    mutating func revoke(_ f: PlaylistFingerprint) {
        guard !f.isEmpty else { return }
        revoked[f.playlistID] = f
    }

    /// The deleted playlist whose traffic this is, or nil.
    func refusal(url: String, apiKey: String?) -> String? {
        guard !revoked.isEmpty else { return nil }
        let host = url.isEmpty ? "" : DispatcharrRequestGate.serverKey(url)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for (id, f) in revoked {
            if !key.isEmpty, f.keys.contains(key) { return id }
            if !host.isEmpty, f.hosts.contains(host) { return id }
            if f.urlSecrets.contains(where: { !$0.isEmpty && url.contains($0) }) { return id }
        }
        return nil
    }

    /// A playlist is in use again: the same id, or any key, URL secret, or
    /// host it shares with a revoked entry. True when anything was lifted.
    @discardableResult
    mutating func lift(matching live: PlaylistFingerprint) -> Bool {
        let before = revoked.count
        revoked = revoked.filter { id, f in
            !(id == live.playlistID
              || !f.keys.isDisjoint(with: live.keys)
              || !f.hosts.isDisjoint(with: live.hosts)
              || f.urlSecrets.contains(where: { live.urlSecrets.contains($0) }))
        }
        return revoked.count != before
    }

    var isEmpty: Bool { revoked.isEmpty }
}

/// What a playlist delete stops (the plan the app runs; pure so the tests
/// can check that nothing playable or sendable is left).
enum PlaylistDeletePlan {
    /// A Multiview tile (or the single player's tile) belongs to the deleted
    /// playlist when it is a live channel of the playlist on screen, a
    /// movie, episode, or recording the playlist served, or its stream
    /// carries the playlist's key or URL secrets.
    static func stopsTile(isLive: Bool, deletedIsOnScreen: Bool, tileServerID: String?, deletedID: String,
                          refusedByFingerprint: Bool) -> Bool {
        if refusedByFingerprint { return true }
        if let sid = tileServerID, !sid.isEmpty { return sid == deletedID }
        return isLive && deletedIsOnScreen
    }

    /// Items left playable after the delete: nothing tagged with the deleted id.
    static func playable<T>(_ items: [T], playlistID: (T) -> String?, deletedID: String) -> [T] {
        items.filter { playlistID($0) != deletedID }
    }
}

// MARK: - Reminders for channels no playlist on this device has (owner 2026-11-12)

/// Reminders are kept everywhere (this device's list, iCloud, Dispatcharr
/// Sync), but on a device where no remaining playlist has a reminder's
/// channel, the reminder is hidden: no bell, no badge, no notification. A
/// playlist with that channel coming back (re-added, set up, restored from
/// iCloud) makes it reappear. Channel names are recorded per playlist when
/// its channel list loads; a playlist this device never loaded has no names
/// yet, so it hides nothing and keeps nothing hidden.
struct ReminderChannelIndex: Sendable, Equatable {
    var namesByPlaylist: [String: Set<String>] = [:]
    /// Channel names hidden on this device.
    var hidden: Set<String> = []

    func isHidden(_ channelName: String) -> Bool { hidden.contains(channelName) }

    /// A playlist's channel list loaded. Returns the names that reappear.
    @discardableResult
    mutating func recordPlaylist(_ playlistID: String, names: Set<String>) -> Set<String> {
        namesByPlaylist[playlistID] = names
        let back = hidden.intersection(names)
        hidden.subtract(back)
        return back
    }

    /// A playlist was deleted. [displayedNames] is its channel list when it
    /// was the one on screen (its recorded names otherwise). Returns the
    /// names newly hidden: its channels that no remaining playlist has.
    @discardableResult
    mutating func playlistDeleted(_ playlistID: String, displayedNames: Set<String> = []) -> Set<String> {
        let mine = (namesByPlaylist.removeValue(forKey: playlistID) ?? []).union(displayedNames)
        let others = namesByPlaylist.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let gone = mine.subtracting(others).subtracting(hidden)
        hidden.formUnion(gone)
        return gone
    }
}

/// The app's revocation gate (HTTPRouter consults it for every request):
/// refuses a request that carries a deleted playlist's fingerprint, drops
/// an answer that arrives after the delete, and cancels the requests in
/// flight when a playlist is deleted.
final class PlaylistRevocation: @unchecked Sendable {
    static let shared = PlaylistRevocation()

    struct Refused: Error, LocalizedError, Equatable {
        let playlistID: String
        var errorDescription: String? { "This playlist was deleted." }
    }

    private let lock = NSLock()
    private var book = PlaylistRevocationBook()
    private var inFlight: [UUID: (url: String, apiKey: String?, cancel: @Sendable () -> Void)] = [:]

    /// Throws when [url] or [apiKey] belongs to a deleted playlist.
    func check(url: String, apiKey: String?) throws {
        lock.lock(); let id = book.refusal(url: url, apiKey: apiKey); lock.unlock()
        if let id { throw Refused(playlistID: id) }
    }

    func isRevoked(url: String, apiKey: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return book.refusal(url: url, apiKey: apiKey) != nil
    }

    /// A request is being sent; [cancel] stops it if its playlist is deleted meanwhile.
    func track(url: String, apiKey: String?, cancel: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); inFlight[id] = (url, apiKey, cancel); lock.unlock()
        return id
    }

    func untrack(_ id: UUID) {
        lock.lock(); inFlight[id] = nil; lock.unlock()
    }

    /// The playlist was deleted: refuse its traffic from now on and cancel
    /// what is in flight. Returns how many requests were cancelled.
    @discardableResult
    func revoke(_ f: PlaylistFingerprint) -> Int {
        lock.lock()
        book.revoke(f)
        var one = PlaylistRevocationBook()
        one.revoke(f)
        let hits = inFlight.filter { one.refusal(url: $0.value.url, apiKey: $0.value.apiKey) != nil }
        for id in hits.keys { inFlight[id] = nil }
        lock.unlock()
        for h in hits.values { h.cancel() }
        return hits.count
    }

    /// A playlist is in use again (added, set up, restored): lift what it matches.
    @discardableResult
    func lift(matching live: PlaylistFingerprint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return book.lift(matching: live)
    }

    var inFlightCount: Int { lock.lock(); defer { lock.unlock() }; return inFlight.count }

    func resetForTests() {
        lock.lock(); book = PlaylistRevocationBook(); inFlight = [:]; lock.unlock()
    }
}

/// The delete confirmation when the playlist has recordings saved on this
/// device (owner 2026-11-12; byte-identical with Android). Without any, the
/// confirmation is today's.
enum PlaylistDeleteCopy {
    static func title(_ playlistName: String) -> String { "Delete \(playlistName)?" }
    static func body(recordings n: Int) -> String {
        let saved = n == 1 ? "1 recording saved on this device came" : "\(n) recordings saved on this device came"
        return "This removes the playlist and its sign-in from this device. \(saved) from this playlist."
    }
    static let keepRecordings = "Delete, Keep Recordings"
    static let deleteRecordings = "Delete Playlist and Recordings"
    static let cancel = "Cancel"
    /// The DVR section for kept recordings, under every playlist.
    static let savedOnDeviceSection = "Saved on this device"
}

// MARK: - On-device recording locations (owner 2026-11-13)

/// Where an on-device recording's file is. The app's data container can move
/// between installs and updates (seen on the simulator 2026-11-12: after a
/// reinstall a 40 MB recording's stored absolute path pointed into the old
/// container and the file "was gone"). A recording in the default recordings
/// folder (Documents/Recordings, Caches/Recordings on Apple TV) is stored
/// relative to it, as "recordings:<file name>", and resolved at runtime. A
/// recording in a custom folder (a security-scoped bookmark outside the
/// container) keeps its absolute path. An old absolute path into a previous
/// container's default folder is re-rooted when the file is under the current
/// one.
enum RecordingPathRules {
    static let prefix = "recordings:"
    /// The default folder's own name (the last component of the root).
    static let folderName = "Recordings"

    /// The value to store for [path]: relative when it sits directly in [root].
    static func stored(_ path: String, root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        let parent = (path as NSString).deletingLastPathComponent
        guard parent == r else { return path }
        return prefix + (path as NSString).lastPathComponent
    }

    /// The file's current location for a stored value, or nil when it has none.
    static func resolve(_ stored: String?, root: String?, exists: (String) -> Bool) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix(prefix) {
            guard let root, !root.isEmpty else { return nil }
            return (root as NSString).appendingPathComponent(String(stored.dropFirst(prefix.count)))
        }
        if exists(stored) { return stored }
        return reRooted(stored, root: root, exists: exists) ?? stored
    }

    /// An absolute path into a previous container's default folder whose file
    /// is now under [root]: its current path there, else nil.
    static func reRooted(_ stored: String, root: String?, exists: (String) -> Bool) -> String? {
        guard let root, !root.isEmpty, stored.hasPrefix("/") else { return nil }
        let parent = (stored as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent == folderName else { return nil }
        let candidate = (root as NSString).appendingPathComponent((stored as NSString).lastPathComponent)
        return candidate != stored && exists(candidate) ? candidate : nil
    }

    /// The migration of one stored value at launch: its relative form when it
    /// is an absolute path into the default folder (this container's, or a
    /// previous one's with the file now here); nil leaves it as it is.
    static func migrated(_ stored: String, root: String?, exists: (String) -> Bool) -> String? {
        guard !stored.hasPrefix(prefix), let root, !root.isEmpty else { return nil }
        let rel = Self.stored(stored, root: root)
        if rel != stored { return rel }
        if let moved = reRooted(stored, root: root, exists: exists) { return Self.stored(moved, root: root) }
        return nil
    }
}
