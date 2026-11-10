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
    /// earlier 429 still pauses the server. `seconds` is the wait left.
    case rateLimited(seconds: Int)
    /// The server already rejected this exact API key and nothing was sent.
    case keyRejected

    var errorDescription: String? {
        switch self {
        case .rateLimited(let s): return DispatcharrRateLimitCopy.rateLimitedMessage(s)
        case .keyRejected: return DispatcharrRateLimitCopy.keyRejectedErrorMessage
        }
    }

    /// The 429 wait carried by `error` (or one it wraps through
    /// NSUnderlyingErrorKey), or nil when it is not a rate limit.
    static func rateLimitSeconds(_ error: Error) -> Int? {
        var current: Error? = error
        var depth = 0
        while let e = current, depth < 8 {
            if case DispatcharrGateError.rateLimited(let s)? = e as? DispatcharrGateError { return s }
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
    /// Key hash -> playlist ids that saw it rejected.
    private var rejected: [String: Set<String>] = [:]
    private var rechecks: [String: Recheck] = [:]
    private var acceptedAt: [String: (at: TimeInterval, mode: String)] = [:]
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
    func pause(_ server: String, seconds: Int) {
        let s = min(max(seconds, 1), Self.maxRetryAfter)
        let until = clock() + TimeInterval(s)
        lock.lock()
        pausedUntil[server] = max(pausedUntil[server] ?? 0, until)
        lock.unlock()
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
    static func isPausedPath(_ path: String) -> Bool {
        path.contains("/api/") && !path.contains("/api/accounts/token/")
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

    /// Dispatcharr's own answer for an unknown key (ApiKeyAuthentication: "Invalid API key").
    static func isDispatcharrInvalidKeyBody(_ body: String) -> Bool {
        body.range(of: "Invalid API key", options: .caseInsensitive) != nil
    }

    // MARK: Rejected key

    /// One "Sign-in not accepted" prompt. `passwordToo` = the playlist also
    /// has a password and its re-login was refused as well.
    struct Prompt: Equatable, Sendable {
        let playlistID: String
        let playlistName: String
        let passwordToo: Bool
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
                         passwordToo: Bool = false, baseURL: String = "") -> Bool {
        let hash = Self.keyHash(key)
        lock.lock()
        var set = rejected[hash] ?? []
        let fresh = set.insert(playlistID).inserted
        rejected[hash] = set
        var changed: Prompt?? = nil
        if fresh {
            let p = Prompt(playlistID: playlistID, playlistName: playlistName, passwordToo: passwordToo)
            pendingPrompt = p
            changed = .some(p)
            if !baseURL.isEmpty, rechecks[hash] == nil {
                rechecks[hash] = Recheck(hash: hash, key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                         baseURL: baseURL, serverKey: Self.serverKey(baseURL),
                                         playlistID: playlistID, passwordToo: passwordToo,
                                         rejectedAt: clock())
            }
        }
        acceptedAt[hash] = nil
        lock.unlock()
        if let changed { onPromptChange?(changed) }
        return fresh
    }

    /// True while `key` is known rejected (any playlist).
    func isKeyRejected(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let hash = Self.keyHash(trimmed)
        lock.lock(); defer { lock.unlock() }
        return !(rejected[hash]?.isEmpty ?? true)
    }

    /// True while `playlistID` has a rejected key on record.
    func isPlaylistRejected(_ playlistID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rejected.values.contains { $0.contains(playlistID) }
    }

    /// An explicit save for the playlist: forget its rejection and any prompt for it.
    func clearPlaylist(_ playlistID: String) {
        lock.lock()
        for (hash, ids) in rejected {
            var s = ids
            s.remove(playlistID)
            rejected[hash] = s.isEmpty ? nil : s
        }
        rechecks = rechecks.filter { rejected[$0.key] != nil }
        let cleared = pendingPrompt?.playlistID == playlistID
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
        let cleared = pendingPrompt.map { ids.contains($0.playlistID) } ?? false
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
        /// Password playlist whose re-login was refused: the probe is one login.
        let passwordToo: Bool
        let rejectedAt: TimeInterval
        /// Scheduled probes run so far. Guarded by the gate's lock.
        fileprivate(set) var scheduledDone = 0
        fileprivate(set) var lastProbeAt: TimeInterval = -.greatestFiniteMagnitude / 2
        fileprivate(set) var inFlight = false

        init(hash: String, key: String, baseURL: String, serverKey: String,
             playlistID: String, passwordToo: Bool, rejectedAt: TimeInterval) {
            self.hash = hash
            self.key = key
            self.baseURL = baseURL
            self.serverKey = serverKey
            self.playlistID = playlistID
            self.passwordToo = passwordToo
            self.rejectedAt = rejectedAt
        }
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
            if let p = pendingPrompt, ids.contains(p.playlistID) || p.playlistID == r.playlistID {
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

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
