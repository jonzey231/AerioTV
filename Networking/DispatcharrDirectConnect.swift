//
//  DispatcharrDirectConnect.swift
//  Aerio
//
//  v1.7 — Dispatcharr Direct Connect (admin username + password login).
//
//  Lets users connect to Dispatcharr with their web-UI admin credentials
//  instead of a 32-character API key. Equivalent to how Teamarr and
//  Enhanced Channel Manager authenticate. Especially helpful on Apple TV
//  where typing a long API key on the Siri Remote on-screen keyboard is
//  genuinely painful.
//
//  Endpoint contract (verified against Dispatcharr 0.23.0 testbench
//  2026-05-02, both LAN HTTP and public HTTPS hostnames):
//
//    POST /api/accounts/token/         body { username, password }
//                                      → { access, refresh }
//    POST /api/accounts/token/refresh/ body { refresh }
//                                      → { access }   (refresh NOT rotated)
//    GET  /api/accounts/users/me/      Bearer access
//                                      → user object including `api_key`
//
//  TTLs: access = 30 minutes (1800s), refresh = 24 hours (86400s).
//  Refresh response only returns a new access token; the existing
//  refresh stays valid for its full 24h window. This sidesteps
//  concurrent-refresh rotation races entirely — two parallel API calls
//  that both see 401 will both refresh, both get a valid new access,
//  both retry. Idempotent.
//
//  Why a separate file: keeps StreamingAPIs.swift (already on the
//  god-files watchlist at 2,000+ lines) from absorbing another major
//  feature. The token store and the JWT-specific extensions live here;
//  the `Auth.jwtSession` enum case and the `headers(for:)` lookup live
//  in StreamingAPIs.swift because they're enum members of `DispatcharrAPI`.
//

import Foundation

// MARK: - Decodable response shapes

/// Response from `/api/accounts/token/` — the JWT login endpoint.
struct DispatcharrJWTPair: Decodable {
    let access: String
    let refresh: String
}

/// Response from `/api/accounts/token/refresh/`. The refresh token is
/// **not** rotated; only a new access token is returned.
struct DispatcharrJWTRefreshResponse: Decodable {
    let access: String
}

/// Slim view of the `/api/accounts/users/me/` response. Aerio only
/// needs `id`, `username`, `api_key`, and the staff/superuser flags
/// (for surfacing "you're connected as <admin>" copy in Settings);
/// the rest of the payload is discarded silently.
struct DispatcharrUser: Decodable {
    let id: Int
    let username: String
    let apiKey: String
    let isStaff: Bool
    let isSuperuser: Bool
    let userLevel: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case apiKey      = "api_key"
        case isStaff     = "is_staff"
        case isSuperuser = "is_superuser"
        case userLevel   = "user_level"
    }
}

// MARK: - Token store

/// Per-server live JWT cache. Holds the access + refresh pair plus a
/// best-effort expiry timestamp parsed from the access token's `exp`
/// claim, so we can pre-emptively refresh before the server returns
/// 401. The store is **process-scoped only** — neither access nor
/// refresh is persisted; the username/password (which re-login uses)
/// are the only durable credential, kept in Keychain by the existing
/// `apiKey_` / `password_` pattern.
///
/// Thread safety: an internal `NSLock` guards the pair dictionary so
/// the store can be read/written from any execution context without
/// hopping to a specific actor. This matters because the call sites
/// (header-emission inside `DispatcharrAPI.headers(for:)`) are
/// nonisolated — building a header dictionary doesn't need an actor
/// hop, and forcing one would require every API call to become async
/// and await the main actor purely for a dictionary lookup.
///
/// `@unchecked Sendable` because we manually serialize access via
/// the lock; Swift can't prove the safety automatically because the
/// dictionary is mutable.
final class DispatcharrTokenStore: @unchecked Sendable {
    static let shared = DispatcharrTokenStore()
    private init() {}

    private struct TokenPair {
        let access: String
        let refresh: String
        let accessExpiresAt: Date
    }

    private let lock = NSLock()
    private var pairs: [UUID: TokenPair] = [:]

    // MARK: - Read

    /// The current access token for a server, if one is cached.
    /// Returns nil when the server has never logged in this session,
    /// or when `clear(serverID:)` was called explicitly.
    func accessToken(for serverID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pairs[serverID]?.access
    }

    /// The current refresh token for a server, if cached.
    func refreshToken(for serverID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pairs[serverID]?.refresh
    }

    /// True when the cached access token's `exp` claim is in the past
    /// or within `slack` seconds of expiring. Defaults to 30 seconds
    /// of slack so a request that lands right at the boundary doesn't
    /// race the server's clock. Returns true when no token is cached
    /// at all, since the caller should treat that as "needs login".
    func accessIsExpired(for serverID: UUID, slack: TimeInterval = 30) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let pair = pairs[serverID] else { return true }
        return pair.accessExpiresAt.timeIntervalSinceNow < slack
    }

    // MARK: - Write

    /// Cache a freshly-issued JWT pair. Call after a successful
    /// `/api/accounts/token/` login.
    func store(serverID: UUID, access: String, refresh: String) {
        let exp = Self.expiry(of: access) ?? Date(timeIntervalSinceNow: 1500)
        lock.lock(); defer { lock.unlock() }
        pairs[serverID] = TokenPair(access: access, refresh: refresh, accessExpiresAt: exp)
    }

    /// Update only the access token after a successful refresh. The
    /// refresh token stays the same — Dispatcharr does not rotate it
    /// on `/api/accounts/token/refresh/`, only emits a new access.
    func storeRefreshedAccess(serverID: UUID, access: String) {
        let exp = Self.expiry(of: access) ?? Date(timeIntervalSinceNow: 1500)
        lock.lock(); defer { lock.unlock() }
        guard let existing = pairs[serverID] else { return }
        pairs[serverID] = TokenPair(access: access, refresh: existing.refresh, accessExpiresAt: exp)
    }

    /// Drop the cached pair for a server. Call when the server is
    /// removed, when the user explicitly logs out, or when the
    /// refresh token has expired (24h+ idle) and we need to fall back
    /// to a full re-login from Keychain credentials.
    func clear(serverID: UUID) {
        lock.lock(); defer { lock.unlock() }
        pairs.removeValue(forKey: serverID)
    }

    /// Drop every cached pair. Used by the iCloud-data-clear flow.
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        pairs.removeAll()
    }

    // MARK: - Helpers

    // MARK: - Warmup

    /// v1.7.x: refresh (or re-login from Keychain credentials) the
    /// JWT for a single server. Best-effort; errors are logged but
    /// never thrown. Called from `AerioApp`'s scene-phase observer
    /// on `.active` and from the initial-sync hook so cold launches
    /// land with a fresh access token in the cache before the first
    /// API call. The api_key fallback path in
    /// `ServerConnection.authHeaders` keeps the app functional even
    /// when warmup fails (e.g. server unreachable, network blip),
    /// so this method's failure modes are non-fatal.
    ///
    /// - Parameters:
    ///   - serverID: the `ServerConnection.id` keying this token
    ///     pair.
    ///   - baseURL: `server.effectiveBaseURL` snapshot. Captured by
    ///     the caller on main so this method can run off-main.
    ///   - username: `server.username` snapshot.
    ///   - password: `server.effectivePassword` snapshot
    ///     (Keychain-resolved before call).
    ///   - userAgent: `server.effectiveUserAgent` snapshot.
    ///
    /// Strategy: try refresh first if a refresh token is cached.
    /// On `.refreshExpired` (24h+ idle) or any other refresh
    /// failure, fall back to a fresh login from username + password.
    /// On both failures, log and return; the api_key fallback
    /// covers the resulting requests.
    func warmup(serverID: UUID,
                baseURL: String,
                username: String,
                password: String,
                userAgent: String) async {
        // Phase 1: try refresh.
        if let refresh = refreshToken(for: serverID) {
            do {
                let newAccess = try await DispatcharrAPI.refreshAccessToken(
                    baseURL: baseURL,
                    refresh: refresh,
                    userAgent: userAgent
                )
                storeRefreshedAccess(serverID: serverID, access: newAccess)
                debugLog("📺 Direct Connect warmup: refreshed access token (server=\(serverID.uuidString.prefix(8)))")
                return
            } catch DispatcharrDirectConnectError.refreshExpired {
                clear(serverID: serverID)
                // Fall through to login.
            } catch {
                debugLog("📺 Direct Connect warmup: refresh failed (\(error.localizedDescription)); falling back to login")
            }
        }

        // Phase 2: fresh login. Requires both fields to be present.
        guard !username.isEmpty, !password.isEmpty else {
            debugLog("📺 Direct Connect warmup: no credentials cached (server=\(serverID.uuidString.prefix(8))); skipping")
            return
        }
        do {
            let pair = try await DispatcharrAPI.login(
                baseURL: baseURL,
                username: username,
                password: password,
                userAgent: userAgent
            )
            store(serverID: serverID, access: pair.access, refresh: pair.refresh)
            debugLog("📺 Direct Connect warmup: logged in fresh (server=\(serverID.uuidString.prefix(8)))")
        } catch {
            debugLog("📺 Direct Connect warmup: login failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Helpers

    /// Best-effort decode of the access token's `exp` claim (Unix
    /// epoch seconds). Returns `nil` on any parse failure (the
    /// caller falls back to a 25-minute heuristic, 5 min before the
    /// 30 min Dispatcharr default) so we still pre-emptively
    /// refresh without trusting a malformed token.
    private static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        // JWTs use base64url with no padding. Add padding back so
        // standard Foundation decoder accepts it.
        let padded = payload.padding(toLength: ((payload.count + 3) / 4) * 4,
                                     withPad: "=",
                                     startingAt: 0)
        let normalized = padded.replacingOccurrences(of: "-", with: "+")
                               .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: normalized),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp  = obj["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

// MARK: - Errors

enum DispatcharrDirectConnectError: Error, LocalizedError {
    /// Server returned 401 on `/api/accounts/token/`. Wrong credentials.
    case invalidCredentials
    /// Server returned a successful response that didn't decode as
    /// `{ access, refresh }`. Indicates a protocol mismatch (older
    /// Dispatcharr build that doesn't emit JWT, or the SPA login
    /// page returned in place of the API).
    case unexpectedLoginResponse
    /// Refresh failed because the refresh token is itself expired
    /// (>24h since last login). Caller should re-login from the
    /// Keychain-stored username/password.
    case refreshExpired
    /// Generic transport failure — wraps the underlying URLError or
    /// HTTP status for telemetry.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid username or password. Check your Dispatcharr admin credentials."
        case .unexpectedLoginResponse:
            return "Server returned an unexpected response shape during login. Verify the URL points at a Dispatcharr 0.23.0 or newer instance."
        case .refreshExpired:
            return "Your session expired. AerioTV will re-authenticate automatically."
        case .transport(let detail):
            return "Login transport error: \(detail)"
        }
    }
}

// MARK: - DispatcharrAPI Direct Connect extensions

extension DispatcharrAPI {
    /// One-shot static login. Doesn't require an authenticated
    /// `DispatcharrAPI` instance because it's the bootstrap call.
    /// Returns the JWT pair on success; throws
    /// `DispatcharrDirectConnectError` on protocol failures.
    ///
    /// - Note: This call is unauthenticated by definition (the
    ///   credentials ARE the auth). `userAgent` is still passed so
    ///   Dispatcharr's admin Stats panel attributes the login to the
    ///   right device.
    static func login(baseURL: String,
                      username: String,
                      password: String,
                      userAgent: String = DeviceInfo.defaultUserAgent) async throws -> DispatcharrJWTPair {
        guard let url = URL(string: "\(normalizedBase(baseURL))/api/accounts/token/") else {
            throw DispatcharrDirectConnectError.transport("Malformed login URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await HTTPRouter.data(for: request)
        } catch {
            throw DispatcharrDirectConnectError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 {
            throw DispatcharrDirectConnectError.invalidCredentials
        }
        guard status == 200 else {
            throw DispatcharrDirectConnectError.transport("HTTP \(status) on login")
        }

        // Reject the SPA-shell case: login route on a non-Dispatcharr
        // host might 200 with HTML. Decode strictly and error out if
        // the response isn't the expected JWT pair.
        do {
            return try JSONDecoder().decode(DispatcharrJWTPair.self, from: data)
        } catch {
            throw DispatcharrDirectConnectError.unexpectedLoginResponse
        }
    }

    /// Refresh the access token using a previously-issued refresh
    /// token. Throws `.refreshExpired` if the server rejects the
    /// refresh (typically a 401 from a 24h+ idle session) so the
    /// caller knows to re-login from Keychain credentials.
    static func refreshAccessToken(baseURL: String,
                                   refresh: String,
                                   userAgent: String = DeviceInfo.defaultUserAgent) async throws -> String {
        guard let url = URL(string: "\(normalizedBase(baseURL))/api/accounts/token/refresh/") else {
            throw DispatcharrDirectConnectError.transport("Malformed refresh URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = ["refresh": refresh]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await HTTPRouter.data(for: request)
        } catch {
            throw DispatcharrDirectConnectError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 {
            throw DispatcharrDirectConnectError.refreshExpired
        }
        guard status == 200,
              let decoded = try? JSONDecoder().decode(DispatcharrJWTRefreshResponse.self, from: data)
        else {
            throw DispatcharrDirectConnectError.transport("HTTP \(status) on refresh")
        }
        return decoded.access
    }

    /// Fetch the authenticated user's record from
    /// `/api/accounts/users/me/`. Used at first-time setup to grab the
    /// API key (so we can persist it locally and continue working in
    /// the existing `.apiKey` paths if desired) and to confirm
    /// authorization is healthy.
    func fetchCurrentUser() async throws -> DispatcharrUser {
        guard let url = URL(string: "\(Self.normalizedBase(baseURL))/api/accounts/users/me/") else {
            throw DispatcharrDirectConnectError.transport("Malformed users/me URL")
        }
        var request = URLRequest(url: url)
        for (key, value) in headersForUserDetail() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await HTTPRouter.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw DispatcharrDirectConnectError.transport("HTTP \(status) on users/me")
        }
        return try JSONDecoder().decode(DispatcharrUser.self, from: data)
    }

    /// Headers for `/api/accounts/users/me/`. Pulled out so the
    /// Direct Connect path can fetch the user object regardless of
    /// auth mode (API key OR live JWT). Mirrors `headers(for:)`'s
    /// switch on auth without recomputing content negotiation.
    private func headersForUserDetail() -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json",
            "User-Agent": userAgent
        ]
        switch auth {
        case .apiKey(let key):
            // Same shape as the standard headers — match `authMode`.
            switch authMode {
            case .xapikey:
                h["X-API-Key"] = key
            case .both:
                h["Authorization"] = "ApiKey \(key)"
                h["X-API-Key"] = key
            case .bearer:
                h["Authorization"] = "Bearer \(key)"
            }
        case .bearer(let token):
            h["Authorization"] = "Bearer \(token)"
        case .jwtSession(let serverID):
            // Reach into the live token store. Same fallback pattern
            // as `headers(for:)`: emit Accept + UA even if the
            // access slot is empty, so the eventual 401 surfaces
            // cleanly to the caller.
            if let access = DispatcharrTokenStore.shared.accessToken(for: serverID) {
                h["Authorization"] = "Bearer \(access)"
            }
        }
        return h
    }

    // MARK: - Base URL normalization

    /// Strip trailing slashes from a base URL. Mirrors
    /// `ServerConnection.normalizedBaseURL` so the static login /
    /// refresh paths can be called without a `ServerConnection`
    /// instance (e.g. during the AddServerView Test Connection flow,
    /// where the user hasn't saved the server yet).
    fileprivate static func normalizedBase(_ baseURL: String) -> String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }
}
