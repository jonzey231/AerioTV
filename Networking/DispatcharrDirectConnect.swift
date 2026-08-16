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
    /// Dispatcharr permission tier: Streamer = 0, Standard = 1,
    /// Admin = 10. Server-side write endpoints (POST
    /// /api/channels/recordings/, the DVR-on-server flow) require
    /// IsAdmin, i.e. user_level >= 10; a Standard user can connect and
    /// view fine but gets HTTP 403 on those writes. Decodes
    /// permissively: older Dispatcharr builds (and any payload that
    /// omits the field) default to 0 so a missing key never fails the
    /// whole users/me decode. Capture-and-gate happens at the call
    /// sites, not here.
    let userLevel: Int

    /// The Channel Profile id(s) assigned to this Dispatcharr user
    /// (`channel_profiles`). A Channel Profile is a curated subset of
    /// channels (e.g. a "Kids" profile with only age-appropriate
    /// channels); the membership is fetched separately from
    /// `/api/channels/profiles/<id>/`. Empty means no profile is
    /// assigned, in which case the user sees every channel (the common
    /// admin case). Decodes permissively: older Dispatcharr builds (and
    /// any payload that omits the field) default to `[]` so a missing
    /// key never fails the whole users/me decode. Captured at connect
    /// and persisted so the channel-load path can filter to the allowed
    /// channels (a child-safety filter).
    let channelProfiles: [Int]

    /// Catch-up (timeshift): the user's XC-output password from
    /// `custom_properties.xc_password`. Dispatcharr's /timeshift/ endpoint
    /// authenticates ONLY with path-embedded XC credentials (Django
    /// username + this value, hmac-compared) -- no JWT/ApiKey support --
    /// so Direct Connect catch-up reads it from the same /me/ call that
    /// already yields api_key. nil when the account has no XC output
    /// configured; catch-up then surfaces an explanatory error.
    let xcPassword: String?

    /// The permission tier the app should GATE on. A Django superuser /
    /// staff account is a functional admin even when its custom
    /// user_level is still 0 (STREAMER) or 1 (STANDARD) - legacy
    /// superusers never had the level defaulted to 10, and Dispatcharr
    /// fixed the same detection server-side in #954. Raw `userLevel`
    /// alone silently demoted such admins (Discord field report
    /// 2026-07-11: only "This device" offered as DVR destination).
    /// Matches Android DispatcharrClient.fetchUserLevel.
    var effectiveUserLevel: Int {
        (isSuperuser || isStaff) ? 10 : userLevel
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case apiKey      = "api_key"
        case isStaff     = "is_staff"
        case isSuperuser = "is_superuser"
        case userLevel   = "user_level"
        case channelProfiles = "channel_profiles"
        case customProperties = "custom_properties"
    }

    private struct CustomProps: Decodable {
        let xcPassword: String?
        enum CodingKeys: String, CodingKey { case xcPassword = "xc_password" }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        // Lenient for the same reason every other field here is, and for
        // one more: a STRICT decode of this key threw a raw Foundation
        // DecodingError that escaped fetchCurrentUser uncaught, so an
        // account whose api_key is absent or null surfaced to the user as
        // "The data couldn't be read because it is missing" - a message
        // that names neither the field nor the fix (Discord 2026-08-16,
        // Dispatcharr dev running a superuser created outside the
        // api_key-minting path). Decoding to "" instead lets
        // fetchCurrentUser raise `.noAPIKeyForAccount`, which says what
        // to do about it. Android already behaved this way
        // (DispatcharrClient.fetchApiKey), so this is parity too.
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
        // Lenient: is_staff / is_superuser only joined Dispatcharr's
        // /users/me/ payload in 2025-06 (serializer commit 1e91dd75);
        // a strict decode failed the WHOLE user object against older
        // servers, killing Direct Connect verify outright.
        isStaff = (try? c.decodeIfPresent(Bool.self, forKey: .isStaff)) ?? false
        isSuperuser = (try? c.decodeIfPresent(Bool.self, forKey: .isSuperuser)) ?? false
        // Default to 0 (lowest privilege) when absent so older
        // Dispatcharr builds that predate the field still decode.
        userLevel = (try? c.decodeIfPresent(Int.self, forKey: .userLevel)) ?? 0
        // Default to [] (no profile = show every channel) when absent so
        // older Dispatcharr builds that predate the field still decode.
        channelProfiles = (try? c.decodeIfPresent([Int].self, forKey: .channelProfiles)) ?? []
        // custom_properties is a free-form object; only xc_password is
        // read, permissively, so any other shape never fails the decode.
        let props = try? c.decodeIfPresent(CustomProps.self, forKey: .customProperties)
        let raw = (props ?? nil)?.xcPassword?.trimmingCharacters(in: .whitespaces)
        xcPassword = (raw?.isEmpty == false) ? raw : nil
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
    /// Login was throttled by Dispatcharr (HTTP 429 on
    /// `/api/accounts/token/`). Distinct from `.transport` because it
    /// is self-clearing and the user must be told to WAIT rather than
    /// to check their URL or credentials.
    case loginRateLimited
    /// `/api/accounts/users/me/` returned 200 but the account carries
    /// no `api_key`. AerioTV needs it for stream/logo headers, so this
    /// is fatal for setup, but it is entirely fixable server-side.
    case noAPIKeyForAccount(username: String)
    /// `/api/accounts/users/me/` returned 200 with a shape we could not
    /// decode. Carries the underlying decode failure so the message
    /// names the offending field instead of Foundation's opaque
    /// "The data couldn't be read because it is missing".
    case unexpectedUserResponse(detail: String)
    /// Generic transport failure — wraps the underlying URLError or
    /// HTTP status for telemetry.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            // v1.7.x: spell out the Dashboard-vs-XC distinction.
            // Field reports show users typing their XC API password
            // here (it's the more familiar one — they use it in
            // Xtream Codes URLs all the time) and assuming AerioTV
            // is broken when it 401s. Calling out the exact admin
            // path turns the error into a self-resolving signal.
            return "Invalid username or password. AerioTV uses your Dispatcharr Dashboard password (System → Users → Account tab), not your Dispatcharr XC password."
        case .unexpectedLoginResponse:
            return "Server returned an unexpected response shape during login. Verify the URL points at a Dispatcharr 0.23.0 or newer instance."
        case .refreshExpired:
            return "Your session expired. AerioTV will re-authenticate automatically."
        case .loginRateLimited:
            return "The server is rate-limiting login attempts (HTTP 429). Wait a minute and try again."
        case .noAPIKeyForAccount(let username):
            return "The Dispatcharr account '\(username)' has no API key. In Dispatcharr, open System, then Users, edit this user, and generate an API key, then try again."
        case .unexpectedUserResponse(let detail):
            return "The server's user profile response was missing expected data (\(detail)). Verify the URL points at a Dispatcharr 0.23.0 or newer instance."
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
        // v1.7.x diagnostic: log every login attempt + outcome so a
        // user with "can't sign in" reports can capture the exact
        // failure mode in Console.app. Neither the password nor the
        // full username is logged (both are half of a credential pair
        // and these logs get shared in bug reports). The masked form
        // (first character + length) still supports "wrong account
        // picked" self-diagnosis without leaking the account name.
        let usernameMasked = username.isEmpty ? "" : "\(username.prefix(1))***"
        debugLog("📺 Direct Connect login: attempting POST /api/accounts/token/ baseURL=\(baseURL.prefix(60)) username='\(usernameMasked)' usernameLen=\(username.count) passwordLen=\(password.count)")
        guard let url = URL(string: "\(normalizedBase(baseURL))/api/accounts/token/") else {
            debugLog("📺 Direct Connect login FAIL: malformed URL after normalization")
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
            debugLog("📺 Direct Connect login FAIL: transport error — \(error.localizedDescription)")
            throw DispatcharrDirectConnectError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        debugLog("📺 Direct Connect login: HTTP \(status), bodyBytes=\(data.count)")
        if status == 401 || status == 403 {
            // Echo a small body excerpt so users with custom
            // Dispatcharr deployments (proxy auth, custom error
            // shapes) can see what the server actually returned.
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? "<non-utf8>"
            debugLog("📺 Direct Connect login FAIL: invalid credentials, body=\(snippet)")
            throw DispatcharrDirectConnectError.invalidCredentials
        }
        if status == 429 {
            // Dispatcharr throttles /api/accounts/token/ (django-ratelimit).
            // Seen in the field when Test Connection and the token warmup
            // land close together: the SECOND login 429s and the generic
            // transport copy sent the user chasing URL/credential problems
            // that did not exist (Discord 2026-08-16).
            debugLog("📺 Direct Connect login FAIL: rate limited (HTTP 429)")
            throw DispatcharrDirectConnectError.loginRateLimited
        }
        guard status == 200 else {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? "<non-utf8>"
            debugLog("📺 Direct Connect login FAIL: HTTP \(status), body=\(snippet)")
            throw DispatcharrDirectConnectError.transport("HTTP \(status) on login")
        }

        // Reject the SPA-shell case: login route on a non-Dispatcharr
        // host might 200 with HTML. Decode strictly and error out if
        // the response isn't the expected JWT pair.
        do {
            let pair = try JSONDecoder().decode(DispatcharrJWTPair.self, from: data)
            debugLog("📺 Direct Connect login OK: access.len=\(pair.access.count), refresh.len=\(pair.refresh.count)")
            return pair
        } catch {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? "<non-utf8>"
            debugLog("📺 Direct Connect login FAIL: 200 OK but decode failed — \(error.localizedDescription); body=\(snippet)")
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
        // Decode failures used to escape here as raw DecodingErrors, whose
        // localizedDescription is the useless "The data couldn't be read
        // because it is missing". Wrap them with the failing key so the
        // Test Connection error names the actual mismatch.
        let user: DispatcharrUser
        do {
            user = try JSONDecoder().decode(DispatcharrUser.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? "<non-utf8>"
            debugLog("📺 Direct Connect users/me FAIL: decode failed — \(error); body=\(snippet)")
            let detail: String
            if case let DecodingError.keyNotFound(key, _) = error {
                detail = "missing field '\(key.stringValue)'"
            } else if case let DecodingError.typeMismatch(_, ctx) = error {
                detail = "unexpected type at '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))'"
            } else if case let DecodingError.valueNotFound(_, ctx) = error {
                detail = "null at '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))'"
            } else {
                detail = "not valid JSON"
            }
            throw DispatcharrDirectConnectError.unexpectedUserResponse(detail: detail)
        }
        // AerioTV leans on api_key as the durable credential (stream and
        // logo headers, recording playback), so an account without one
        // cannot finish setup. Tell the user the server-side fix instead
        // of failing with a decode-shaped error (Discord 2026-08-16: a
        // superuser created before Dispatcharr's api_key-minting path
        // existed carried none).
        guard !user.apiKey.isEmpty else {
            debugLog("📺 Direct Connect users/me FAIL: account '\(user.username.prefix(1))***' has no api_key")
            throw DispatcharrDirectConnectError.noAPIKeyForAccount(username: user.username)
        }
        return user
    }

    /// Capability probe for admin status. Dispatcharr only added
    /// is_superuser / is_staff to the /users/me/ payload in 2025-06, so
    /// against older servers a legacy superuser reads as plain
    /// user_level 0 and `effectiveUserLevel` still under-reports. The
    /// users LIST endpoint is IsAdmin-gated server-side on every
    /// Dispatcharr version, so a 2xx here proves admin regardless of
    /// what /me/ claims. Callers use this to settle levels below 10;
    /// any failure means "not provably admin" (returns false, never
    /// throws). Matches Android DispatcharrClient.fetchUserLevel.
    func probeAdminAccess() async -> Bool {
        guard let url = URL(string: "\(Self.normalizedBase(baseURL))/api/accounts/users/") else {
            return false
        }
        var request = URLRequest(url: url)
        for (key, value) in headersForUserDetail() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (_, response) = try? await HTTPRouter.data(for: request) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (200...299).contains(status)
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

    // MARK: - Silent api_key Re-Bootstrap (v1.7.x Save Credentials)

    /// Silent re-auth path for `.apiKey` 401s. When a Dispatcharr
    /// admin rotates a user's API key (or the key is revoked some
    /// other way), AerioTV's saved api_key in Keychain is suddenly
    /// rejected by the server. Without this helper the user would
    /// see channel-list refresh failures and have to manually
    /// re-enter the new key.
    ///
    /// With this helper, every api_key 401 from a server in
    /// `Username & Password` mode triggers a transparent recovery:
    ///
    ///   1. Read the saved username (passed by caller) + Keychain
    ///      password (`password_<serverID>`).
    ///   2. POST `/api/accounts/token/` to log in fresh — Dispatcharr
    ///      revoked the api_key but the credentials themselves are
    ///      still valid.
    ///   3. Cache the resulting JWT pair in `DispatcharrTokenStore`
    ///      so subsequent `.jwtSession` paths skip a round trip.
    ///   4. Use the fresh JWT to GET `/api/accounts/users/me/` and
    ///      extract the new `api_key` field.
    ///   5. Persist the new api_key to BOTH local and synchronizable
    ///      Keychain slots so other devices on iCloud Keychain
    ///      pick it up the next time they launch.
    ///   6. Return the new api_key so the caller can replay the
    ///      original 401-failed request with fresh headers.
    ///
    /// Mirrors the pattern Teamarr (`teamarr/dispatcharr/auth.py`
    /// `_authenticate`) and Enhanced Channel Manager
    /// (`backend/dispatcharr_client.py` `_request`) use for their
    /// server-to-server connections to Dispatcharr: store the admin
    /// credentials, re-login from them whenever a token expires.
    ///
    /// Returns `nil` on any failure (no creds in Keychain, login
    /// rejected, users/me decode error, etc.). Callers fall back to
    /// surfacing the original 401 so the existing error path stays
    /// intact — silent recovery is a best-effort upgrade, not a
    /// guarantee.
    ///
    /// - Parameters:
    ///   - serverID: `ServerConnection.id` for keying the Keychain
    ///     password lookup AND the resulting api_key write-back.
    ///   - baseURL: the server's `effectiveBaseURL` snapshot.
    ///   - username: the saved Dispatcharr admin username.
    ///   - userAgent: the server's `effectiveUserAgent` snapshot
    ///     so Dispatcharr's admin Stats panel attributes the
    ///     re-login to the right device.
    /// - Returns: the freshly-extracted api_key, or `nil` on any
    ///   failure. Caller should fall back to surfacing the 401.
    static func silentRebootstrapApiKey(
        serverID: UUID,
        baseURL: String,
        username: String,
        userAgent: String
    ) async -> String? {
        guard !username.isEmpty else {
            debugLog("📺 silentRebootstrapApiKey: SKIP empty username (server=\(serverID.uuidString.prefix(8)))")
            return nil
        }
        let pwKey = "password_\(serverID.uuidString)"
        // Match `ServerConnection.resolvedCredential` lookup order:
        // synchronizable first when iCloud sync is on, otherwise
        // local-first. Falling through both keeps the recovery path
        // working regardless of the user's iCloud state.
        let password = KeychainHelper.load(key: pwKey, synchronizable: true)
            ?? KeychainHelper.load(key: pwKey)
            ?? ""
        guard !password.isEmpty else {
            debugLog("📺 silentRebootstrapApiKey: SKIP no password in Keychain (server=\(serverID.uuidString.prefix(8))) — server is in API Key mode without saved credentials")
            return nil
        }
        do {
            let pair = try await login(
                baseURL: baseURL,
                username: username,
                password: password,
                userAgent: userAgent
            )
            DispatcharrTokenStore.shared.store(
                serverID: serverID,
                access: pair.access,
                refresh: pair.refresh
            )
            // Use the just-issued bearer to fetch the new api_key.
            let bearerAPI = DispatcharrAPI(
                baseURL: baseURL,
                auth: .bearer(pair.access),
                userAgent: userAgent
            )
            let user = try await bearerAPI.fetchCurrentUser()
            // Persist to both Keychain slots. Idempotent if iCloud
            // Keychain is off (the synchronizable write just lands
            // locally as if it were the regular slot, which Apple
            // documents as benign).
            let apiKeyKey = "apiKey_\(serverID.uuidString)"
            KeychainHelper.save(user.apiKey, for: apiKeyKey)
            KeychainHelper.save(user.apiKey, for: apiKeyKey, synchronizable: true)
            debugLog("📺 silentRebootstrapApiKey: SUCCESS — fresh api_key persisted for server \(serverID.uuidString.prefix(8))")
            return user.apiKey
        } catch {
            debugLog("📺 silentRebootstrapApiKey: FAIL — \(error.localizedDescription) (server=\(serverID.uuidString.prefix(8)))")
            return nil
        }
    }
}
