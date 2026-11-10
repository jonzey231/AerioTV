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

    /// Final copy once the automatic retries are spent: names the rate limit.
    static func rateLimitedMessage(_ seconds: Int) -> String {
        "The server is rate-limiting requests from this network (HTTP 429). "
            + "Wait \(secondsPhrase(seconds)) and try again."
    }

    /// The countdown line interactive flows show while they wait out a 429.
    static func serverBusyCountdown(_ seconds: Int) -> String {
        "The server is busy. Trying again in \(secondsPhrase(seconds))."
    }

    /// Error text for a call the rejected-key gate held locally.
    static let keyRejectedErrorMessage =
        "The server did not accept this playlist's API key. Enter a new key in Edit Playlist."

    /// Title of the rejected-key prompt.
    static let keyRejectedTitle = "Sign-in not accepted"

    /// Body of the rejected-key prompt (key-only playlist, or a password
    /// playlist whose re-login was refused too). Blank name: "this playlist".
    static func keyRejectedBody(playlistName: String, passwordToo: Bool) -> String {
        let trimmed = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "this playlist" : playlistName
        if passwordToo {
            return "The server did not accept the API key or the password for \(name). "
                + "Enter a new key or password in Edit Playlist to reconnect."
        }
        return "The server did not accept the API key for \(name). Enter a new key in Edit Playlist to reconnect."
    }

    /// Sender status line while it checks the key it is about to send.
    static let checkingLine = "Checking the playlist sign-in"

    /// Sender copy when the key it would send is refused.
    static let setupKeyRejectedMessage =
        "The server did not accept this playlist's API key, so it was not sent. "
            + "Enter a new key in Edit Playlist, then try again."
}

// MARK: - Countdown retry (interactive flows)

/// The give-up failure: its description is the user-facing rate-limit copy.
struct RateLimitedFinal: Error, LocalizedError, Equatable, Sendable {
    let seconds: Int
    var errorDescription: String? { DispatcharrRateLimitCopy.rateLimitedMessage(seconds) }
}

/// Interactive flows (device setup receiver, Add Playlist, Test Connection)
/// when the server answers 429: show "The server is busy. Trying again in N
/// seconds." with a live countdown, try again automatically up to
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
        rateLimitSeconds: (Error) -> Int? = { DispatcharrGateError.rateLimitSeconds($0) },
        tick: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) },
        onCountdown: (Int) -> Void,
        onRetry: () -> Void = {},
        attempt: () async throws -> T
    ) async throws -> T {
        var retries = 0
        while true {
            do {
                return try await attempt()
            } catch {
                guard let wait = rateLimitSeconds(error) else { throw error }
                if retries >= maxAutoRetries { throw RateLimitedFinal(seconds: max(1, wait)) }
                retries += 1
                var left = min(max(wait, 1), DispatcharrRequestGate.maxRetryAfter)
                while left > 0 {
                    if Task.isCancelled { throw CancellationError() }
                    onCountdown(left)
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
    static func signInWaitSeconds(
        _ error: Error,
        apiSeconds: (Error) -> Int?,
        isLogin429: (Error) -> Bool,
        loginParkedSeconds: () -> Int
    ) -> Int? {
        if let s = apiSeconds(error) { return s }
        guard isLogin429(error) else { return nil }
        let left = loginParkedSeconds()
        return left > 0 ? left : DispatcharrRequestGate.defaultRetryAfter
    }
}

// MARK: - Setup sender key check

/// One authenticated GET /api/accounts/users/me/ with exactly the key the
/// sender is about to hand over.
enum SetupKeyCheck: Equatable, Sendable {
    case accepted
    /// 401/403, or a key the gate already holds as rejected (nothing sent).
    case rejected
    /// No verdict: `retryAfter` set for a 429, nil for a network error or any other status.
    case unknown(retryAfter: Int?)
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
    /// `onCountdown(left, true)` and checks again; a network error waits
    /// `networkRetrySeconds` (`onCountdown(left, false)`) and checks again;
    /// up to `RateLimitRetry.maxAutoRetries` re-checks, then the send goes
    /// ahead (the receiver has its own 429 retry).
    static func run(
        isolation: isolated (any Actor)? = #isolation,
        tick: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) },
        check: () async -> SetupKeyCheck,
        onCountdown: (_ secondsLeft: Int, _ rateLimited: Bool) -> Void
    ) async -> SetupKeyVerdict {
        var retries = 0
        while true {
            switch await check() {
            case .accepted: return .send
            case .rejected: return .rejected
            case .unknown(let retryAfter):
                if retries >= RateLimitRetry.maxAutoRetries { return .send }
                retries += 1
                let limited = retryAfter != nil
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
