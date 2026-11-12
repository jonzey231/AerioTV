//
//  DispatcharrRateLimitRetry.swift
//  Aerio
//
//  User-facing copy for the Dispatcharr rate-limit and rejected-key states,
//  the countdown retry the interactive flows run on a 429, and the "Set up
//  another device" sender's key check. Pure logic (no app singletons), so
//  Scripts/dispatcharr-gate-tests/run.sh compiles it with swiftc and runs it
//  with a fake tick. Port of Android RateLimitRetry.kt, DispatcharrErrors.kt
//  (289112b4), ApiKeyRejectedPrompt.kt (fd145f3d), and SetupSender.kt
//  preflightSetupKey (db6aacb6). Every string is Android's word for word.
//

import Foundation

// MARK: - Copy

enum DispatcharrRateLimitCopy {
    /// "1 second", "45 seconds".
    static func secondsPhrase(_ seconds: Int) -> String {
        seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// The rate-limit sentence for `reason` (stream-429-spec.md UPDATE:
    /// say exactly that Dispatcharr rate-limited them, and why).
    private static func rateLimitLead(_ reason: RateLimitReason) -> String {
        switch reason {
        case .apiKeyLockout: return "Dispatcharr rate-limited this network after too many failed API key attempts."
        case .signInLockout: return "Dispatcharr rate-limited sign-ins from this network after too many failed attempts."
        case .other: return "Dispatcharr rate-limited this network (HTTP 429)."
        }
    }

    /// Final copy once the automatic retries are spent.
    static func rateLimitedMessage(_ seconds: Int, reason: RateLimitReason = .other) -> String {
        "\(rateLimitLead(reason)) Wait \(secondsPhrase(seconds)) and try again."
    }

    /// The countdown line while a 429 is waited out.
    static func serverBusyCountdown(_ seconds: Int, reason: RateLimitReason = .other) -> String {
        "\(rateLimitLead(reason)) Trying again in \(secondsPhrase(seconds))."
    }

    /// The stream-limit refusal (no retry).
    static func streamLimitMessage(_ count: Int?) -> String {
        guard let count else { return "Dispatcharr stream limit reached." }
        return "Dispatcharr stream limit reached: \(count) concurrent streams allowed for this account."
    }

    /// Error text for a call the rejected-key gate held locally.
    static let keyRejectedErrorMessage =
        "Dispatcharr no longer accepts this playlist's API key. Enter the current key in Edit Playlist, or ask your Dispatcharr administrator for a new one."

    /// Title of the rejected-key prompt.
    static let keyRejectedTitle = "API key no longer valid"

    /// Title of the catch-up failure alert (list and guide): the rejected-key
    /// title when a held key stopped it, "Catch-up Unavailable" otherwise.
    static func catchupAlertTitle(_ error: Error) -> String {
        var current: Error? = error
        var depth = 0
        while let e = current, depth < 8 {
            if case DispatcharrGateError.keyRejected? = e as? DispatcharrGateError { return keyRejectedTitle }
            current = (e as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return "Catch-up Unavailable"
    }

    /// Body of the rejected-key prompt (key-only playlist, or a password
    /// playlist whose re-login was refused too). Blank name: "this playlist".
    /// Same on every device (sign-in from the prompt, 2026-11-11). A Child
    /// (no Edit Playlist, follow-up 12) reads only the actions it can take, as
    /// on Android: no Edit Playlist clause, and no sign-in sentence when it
    /// cannot sign in either (a non-default Child). Trimmed only, no new words.
    static func keyRejectedBody(playlistName: String, passwordToo: Bool,
                                canSignIn: Bool = true, canEditPlaylist: Bool = true) -> String {
        let trimmed = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "this playlist" : playlistName
        let lead = passwordToo
            ? "Dispatcharr no longer accepts the sign-in for \(name). It may have been changed on the server."
            : "Dispatcharr no longer accepts the API key for \(name). It may have been changed on the server."
        let signIn = "Sign in with your Dispatcharr username and password to reconnect"
        if canEditPlaylist {
            return lead + " " + signIn + (passwordToo ? ", or enter the current details in Edit Playlist." : ", or enter the current key in Edit Playlist.")
        }
        return canSignIn ? lead + " " + signIn + "." : lead
    }

    /// Sender status line while it checks the key it is about to send.
    static let checkingLine = "Checking the playlist sign-in"

    /// Sender copy when the key it would send is refused.
    static let setupKeyRejectedMessage =
        "Dispatcharr no longer accepts this playlist's API key, so it was not sent. "
            + "Enter the current key in Edit Playlist, then try again."
}

extension DispatcharrRateLimitCopy {
    /// The rejected-key prompt's body for what happened: the account has no
    /// API key (a stored password signed in, but the key was removed on the
    /// server), else the key-only or password-too body.
    static func keyRejectedPromptBody(playlistName: String, passwordToo: Bool, noKey: Bool,
                                      canSignIn: Bool = true, canEditPlaylist: Bool = true) -> String {
        noKey ? KeySignInCopy.noAPIKey
            : keyRejectedBody(playlistName: playlistName, passwordToo: passwordToo,
                              canSignIn: canSignIn, canEditPlaylist: canEditPlaylist)
    }
}

// MARK: - Sign in from the rejected-key prompt (2026-11-11)

/// "API key no longer valid": sign in with the Dispatcharr username and
/// password instead of entering a key (Android ApiKeyRejectedPrompt, same
/// words). The prompt's buttons per device, the sign-in form, and its
/// messages live here, so a wording change is one edit. Pure; the gate
/// tests pin it.
enum KeySignInCopy {
    // Prompt buttons.
    static let signIn = "Sign In"
    static let editPlaylist = "Edit Playlist"
    static let notNow = "Not Now"
    /// TVs: the Fix Login receive screen.
    static let updateFromPhone = "Update from Phone"
    /// TVs: the same sign-in form as Sign In; key entry stays in Settings > Edit Playlist.
    static let signInWithRemote = "Sign In with Remote"

    // The form.
    static let formTitle = "Sign in to Dispatcharr"
    static let username = "Username"
    static let password = "Password"
    static let submit = "Sign In"
    static let cancel = "Cancel"
    static let footnote = "AerioTV keeps your password on this device so it can reconnect if the key changes again."
    static let wrongCredentials = "Dispatcharr did not accept that username or password."
    static let noAPIKey = "This account has no API key yet. Ask your Dispatcharr administrator to turn on API access for it."

    /// Above the fields when a profile's sign-in is held after its
    /// playlist's server address changed (ProfileHostHold, 2026-11-11). A
    /// blank name reads "this playlist", as on Android.
    static func hostChanged(playlistName: String) -> String {
        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "The server address for \(name.isEmpty ? "this playlist" : name) changed. Sign in again to use this profile."
    }

    enum PromptAction: Equatable, Sendable { case signIn, editPlaylist, updateFromPhone, notNow }

    /// The prompt's buttons, in order. Phones and tablets: Sign In (primary),
    /// Edit Playlist, Not Now. TVs: Update from Phone (primary, default
    /// focus), Sign In with Remote, Not Now. A profile that may not open the
    /// form (a Child, or the app behind the launch PIN) gets no sign-in button,
    /// and a Child gets no Edit Playlist either (follow-up 12: a Child never
    /// reaches a playlist's settings, as on Android).
    static func promptActions(isTV: Bool, canSignIn: Bool, canEditPlaylist: Bool) -> [PromptAction] {
        if isTV { return canSignIn ? [.updateFromPhone, .signIn, .notNow] : [.updateFromPhone, .notNow] }
        return (canSignIn ? [.signIn] : []) + (canEditPlaylist ? [.editPlaylist] : []) + [.notNow]
    }

    static func label(_ a: PromptAction, isTV: Bool) -> String {
        switch a {
        case .signIn: return isTV ? signInWithRemote : signIn
        case .editPlaylist: return editPlaylist
        case .updateFromPhone: return updateFromPhone
        case .notNow: return notNow
        }
    }

    /// What a sign-in attempt came to.
    enum Outcome: Equatable, Sendable {
        case signedIn
        case wrongCredentials
        case noAPIKey
        /// The existing line for a rate limit or a connection failure.
        case failed(String)
    }

    /// The form's inline line for an outcome; nil on success (the form closes).
    static func message(_ o: Outcome) -> String? {
        switch o {
        case .signedIn: return nil
        case .wrongCredentials: return wrongCredentials
        case .noAPIKey: return noAPIKey
        case .failed(let line): return line
        }
    }

    /// Sign In is offered once both fields have something in them.
    static func canSubmit(username: String, password: String) -> Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }
}

/// Follow-up 11 (2026-11-11): the "Sign in to Dispatcharr" form and Fix Login
/// receive reconnect only the playlist's CURRENT account, for every account.
/// Changing which account a playlist uses stays in Edit Playlist.
enum KeySignInAccount {
    /// The playlist's known account: who a sign-in may reconnect it as.
    struct Known: Equatable, Sendable {
        let username: String
        /// Compared whenever one is recorded.
        let userId: Int?
    }

    /// The chain, first match: the recorded default identity (user id and
    /// username, ProfileHostHold's record, written only from the default
    /// profile's own users/me), else the playlist's own stored username (the
    /// default's sign-in), else the default profile's username. Never a value
    /// a non-default profile could have written (account facts, the form).
    static func known(recorded: (userId: Int, username: String)?, row: String, defaultProfile: String) -> Known? {
        if let r = recorded {
            let u = r.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !u.isEmpty || r.userId > 0 { return Known(username: u, userId: r.userId > 0 ? r.userId : nil) }
        }
        for c in [row, defaultProfile] {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return Known(username: t, userId: nil) }
        }
        return nil
    }

    /// Whether the account users/me named after the sign-in may be written to
    /// the playlist: the known user (username without regard to case) and,
    /// whenever an id is recorded, the same user id. With no known account, a
    /// Child (active or default) is refused and anyone else allowed, as before.
    static func accepts(username: String, userId: Int, known: Known?, childInvolved: Bool) -> Bool {
        guard let known else { return !childInvolved }
        if let id = known.userId, id != userId { return false }
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !known.username.isEmpty, u.caseInsensitiveCompare(known.username) != .orderedSame { return false }
        return true
    }
}

// MARK: - Countdown retry (interactive flows)

/// The give-up failure: its description is the user-facing rate-limit copy.
struct RateLimitedFinal: Error, LocalizedError, Equatable, Sendable {
    let seconds: Int
    var reason: RateLimitReason = .other
    var errorDescription: String? { DispatcharrRateLimitCopy.rateLimitedMessage(seconds, reason: reason) }
}

/// Interactive flows (device setup receiver, Add Playlist, Test Connection)
/// when the server answers 429: show the reason's countdown line
/// (`serverBusyCountdown`) live, try again automatically up to
/// `maxAutoRetries` times, then fail with `RateLimitedFinal`.
enum RateLimitRetry {
    /// 2 automatic retries, 3 attempts in all.
    static let maxAutoRetries = 2

    /// Runs `attempt`; on a 429 failure counts down through `onCountdown`
    /// (N, N-1, ..., 1, N = Retry-After clamped 1 to 120), then runs it again.
    /// `onRetry` fires right before each new attempt so the caller can put
    /// its normal status line back. The last 429 becomes `RateLimitedFinal`;
    /// any other failure is rethrown unchanged.
    static func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        rateLimit: (Error) -> (seconds: Int, reason: RateLimitReason)? = { DispatcharrGateError.rateLimit($0) },
        tick: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) },
        onCountdown: (_ secondsLeft: Int, _ reason: RateLimitReason) -> Void,
        onRetry: () -> Void = {},
        attempt: () async throws -> T
    ) async throws -> T {
        var retries = 0
        while true {
            do {
                return try await attempt()
            } catch {
                guard let limit = rateLimit(error) else { throw error }
                let wait = limit.seconds
                if retries >= maxAutoRetries { throw RateLimitedFinal(seconds: max(1, wait), reason: limit.reason) }
                retries += 1
                var left = min(max(wait, 1), DispatcharrRequestGate.maxRetryAfter)
                while left > 0 {
                    if Task.isCancelled { throw CancellationError() }
                    onCountdown(left, limit.reason)
                    await tick()
                    left -= 1
                }
                onRetry()
            }
        }
    }

    /// The wait for a sign-in failure (Add Playlist, Test Connection). An API
    /// 429 carries its own seconds. A login 429 (/api/accounts/token/, Android
    /// LoginThrottled) waits out the login gate's park for that server, which
    /// holds the Retry-After; the default when the park has already lapsed.
    /// nil: not a rate limit, so the caller's normal error copy applies.
    static func signInWait(
        _ error: Error,
        apiLimit: (Error) -> (seconds: Int, reason: RateLimitReason)?,
        isLogin429: (Error) -> Bool,
        loginParked: () -> (seconds: Int, reason: RateLimitReason)
    ) -> (seconds: Int, reason: RateLimitReason)? {
        if let limit = apiLimit(error) { return limit }
        guard isLogin429(error) else { return nil }
        let parked = loginParked()
        return (parked.seconds > 0 ? parked.seconds : DispatcharrRequestGate.defaultRetryAfter, parked.reason)
    }
}

// MARK: - Setup sender key check

/// One authenticated GET /api/accounts/users/me/ with exactly the key the
/// sender is about to hand over.
enum SetupKeyCheck: Equatable, Sendable {
    case accepted
    /// 401/403, or a key the gate already holds as rejected (nothing sent).
    case rejected
    /// No verdict: `retryAfter` set for a 429 (with the server's reason),
    /// nil for a network error or any other status.
    case unknown(retryAfter: Int?, reason: RateLimitReason = .other)
}

enum SetupKeyVerdict: Equatable, Sendable {
    /// The server accepted the key, or no verdict after the retries: send.
    case send
    /// 401/403: do not send; offer Edit Playlist.
    case rejected
}

enum SetupKeyPreflight {
    /// Wait before re-checking the key after a network error.
    static let networkRetrySeconds = 3

    /// 401/403 = `.rejected`. A 429 counts down its Retry-After through
    /// `onCountdown(left, reason)` and checks again; a network error waits
    /// `networkRetrySeconds` (`onCountdown(left, nil)`) and checks again;
    /// up to `RateLimitRetry.maxAutoRetries` re-checks, then the send goes
    /// ahead (the receiver has its own 429 retry).
    static func run(
        isolation: isolated (any Actor)? = #isolation,
        tick: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) },
        check: () async -> SetupKeyCheck,
        onCountdown: (_ secondsLeft: Int, _ rateLimit: RateLimitReason?) -> Void
    ) async -> SetupKeyVerdict {
        var retries = 0
        while true {
            switch await check() {
            case .accepted: return .send
            case .rejected: return .rejected
            case .unknown(let retryAfter, let reason):
                if retries >= RateLimitRetry.maxAutoRetries { return .send }
                retries += 1
                let limited: RateLimitReason? = retryAfter != nil ? reason : nil
                var left = min(max(retryAfter ?? networkRetrySeconds, 1), DispatcharrRequestGate.maxRetryAfter)
                while left > 0 {
                    if Task.isCancelled { return .send }
                    onCountdown(left, limited)
                    await tick()
                    left -= 1
                }
            }
        }
    }
}
