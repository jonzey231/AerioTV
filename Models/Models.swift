import SwiftData
import SwiftUI
import os

// MARK: - Dispatcharr Auth Header Mode
/// Per-server Dispatcharr auth header shape.
///
/// Auto-detected on Test Connection (v1.6.20+) so different Dispatcharr
/// builds with different header requirements all work without user
/// intervention. Persisted as the raw string in
/// `ServerConnection.dispatcharrAuthMode` for SwiftData stability.
///
///  - `.xapikey`: send `X-API-Key: <key>` only. Preferred when it works
///    — preserves full VOD episode visibility (some Dispatcharr builds
///    filter the per-series episode list when `Authorization` is also
///    present, by routing the request through user-scoped session auth
///    that limits visible m3u_accounts).
///  - `.both`: send both `Authorization: ApiKey <key>` AND
///    `X-API-Key: <key>`. The historical shape Aerio shipped pre-v1.6.20
///    for stream playback. Some Dispatcharr builds reject X-API-Key
///    alone with HTTP 401; this is the fallback that gets those
///    deployments connected.
///  - `.bearer`: send `Authorization: Bearer <key>` only. Rare —
///    reserved for token-based deployments.
enum DispatcharrAuthHeaderMode: String, Codable {
    case xapikey
    case both
    case bearer
}

/// v1.7 — which credential the user provided when adding a Dispatcharr
/// Direct Connect server.
///
///  - `.apiKey`: the user pasted a personal API key from Dispatcharr's
///    Settings → Users → Edit User → API & XC tab. This is the historical
///    Aerio behaviour. Auth headers follow `dispatcharrHeaderMode`
///    (X-API-Key, dual, or bearer-with-the-API-key) and never expire.
///  - `.usernamePassword`: the user logged in with their Dispatcharr admin
///    username + password (or any user account). Aerio exchanges the
///    credentials for a JWT pair against `/api/accounts/token/`, caches
///    the access + refresh tokens per server in memory, and sends
///    `Authorization: Bearer <access>` on every API request. The 30 min
///    access TTL is refreshed silently against `/api/accounts/token/refresh/`
///    on 401; if the 24h refresh has also expired, Aerio re-logs in from
///    the Keychain-stored credentials. This is the equivalent of the
///    Dispatcharr web UI's session — same auth flow Teamarr and Enhanced
///    Channel Manager use.
///
/// Stored as raw string on `ServerConnection` for SwiftData stability.
/// Empty string defaults to `.apiKey` so every server that existed before
/// v1.7 keeps its current behaviour without any migration work.
enum DispatcharrCredentialType: String, Codable {
    case apiKey            = "api_key"
    case usernamePassword  = "username_password"
}

// MARK: - Server Type Enum
enum ServerType: String, Codable, CaseIterable {
    case dispatcharrAPI = "dispatcharr_api"
    case xtreamCodes  = "xtream_codes"
    case m3uPlaylist  = "m3u_playlist"

    var displayName: String {
        switch self {
        case .m3uPlaylist: return "M3U + EPG"
        case .xtreamCodes: return "Xtream Codes"
        // v1.7: renamed from "Dispatcharr API" — Direct Connect is a clearer
        // mental model now that we support both API-key auth AND admin
        // username+password (the same credentials you use on the Dispatcharr
        // web UI). The SwiftData enum case stays `dispatcharrAPI` /
        // `"dispatcharr_api"` for migration safety; only the user-facing
        // string changed.
        case .dispatcharrAPI: return "Dispatcharr Direct Connect"
        }
    }

    var systemIcon: String {
        switch self {
        case .m3uPlaylist: return "doc.text.fill"
        case .xtreamCodes: return "tv.and.hifispeaker.fill"
        case .dispatcharrAPI: return "key.fill"
        }
    }

    var color: Color {
        switch self {
        case .m3uPlaylist:    return .accentPrimary
        case .xtreamCodes:    return .accentSecondary
        case .dispatcharrAPI: return .accentPrimary
        }
    }

    var description: String {
        switch self {
        case .m3uPlaylist: return "Any M3U playlist URL — works with Dispatcharr, any IPTV provider"
        case .xtreamCodes: return "Xtream Codes API — live TV, VOD movies & series"
        case .dispatcharrAPI: return "Connect to Dispatcharr with your admin login or a personal API key (*AerioTV is not officially affiliated with the Dispatcharr project)"
        }
    }

    var supportsLiveTV: Bool { true }
    var supportsVOD: Bool {
        switch self {
        case .m3uPlaylist:  return false
        case .xtreamCodes:  return true
        case .dispatcharrAPI: return true
        }
    }
}

// MARK: - Server Connection Model
@Model
final class ServerConnection {
    var id: UUID
    var name: String
    var type: ServerType
    var baseURL: String       // M3U URL (for m3uPlaylist) or server base URL (for xtreamCodes)
    var username: String      // Xtream Codes username
    var password: String      // Xtream Codes password
    var apiKey: String        // Dispatcharr native API key (optional)
    var epgURL: String        // Optional EPG/XMLTV URL (for m3uPlaylist)
    var isActive: Bool
    var sortOrder: Int
    var createdAt: Date
    var lastConnected: Date?
    var isVerified: Bool
    /// Local LAN URL, used automatically whenever the server is reachable on the local network (e.g. http://192.168.1.10:9191).
    var localURL: String = ""
    /// Local EPG/XMLTV URL, used when the local server is reachable (M3U only).
    var localEPGURL: String = ""
    /// Deprecated: home WiFi SSID switching has been removed. The LAN
    /// URL is now chosen solely by `TVLANProbe` reachability, so this
    /// field is no longer read. Kept declared (never removed) to avoid
    /// a SwiftData schema migration for existing installs.
    var homeSSID: String = ""
    /// Per-server custom User-Agent override. Only consumed for Dispatcharr
    /// servers — set on every outbound `URLRequest` and on MPV playback so
    /// the value shows up in Dispatcharr's admin Stats panel. Empty string
    /// means "use the computed default from `DeviceInfo.defaultUserAgent`".
    var customUserAgent: String = ""
    /// Optional per-Dispatcharr-server XMLTV override. When non-empty,
    /// Aerio fetches EPG from this URL directly instead of Dispatcharr's
    /// /api/epg/* endpoints. Ignored for XC and M3U. Empty = use API.
    var dispatcharrXMLTVURL: String = ""
    /// v1.7.3: optional per-Xtream-server custom XMLTV URL. When
    /// non-empty, AerioTV fetches this XMLTV feed and uses its
    /// `<category>` tags to drive the per-channel color tints
    /// (Sports/News/Movies/Kids) that the Xtream API doesn't expose.
    /// Local-only, NOT iCloud-synced (mirrors `dispatcharrXMLTVURL`;
    /// XMLTV URLs can carry credentials in the path). Ignored for
    /// Dispatcharr and M3U. Empty = no custom tint source.
    var xtreamXMLTVURL: String = ""
    /// Preferred destination for new recordings on this server. Only
    /// meaningful for `.dispatcharrAPI` — XC/M3U servers ignore this and
    /// always record locally. Stored as rawValue for SwiftData stability.
    var defaultRecordingDestinationRaw: String = RecordingDestination.dispatcharrServer.rawValue

    /// v1.6.12: per-server toggle for VOD ingestion. When `false`,
    /// `VODStore` skips this server during `loadMovies` / `loadSeries`
    /// even if the server type technically supports VOD.
    ///
    /// Use case: a user runs two Dispatcharr instances — one as
    /// their "main" server, one as a "sandbox" for trialing new IPTV
    /// providers. Both have huge VOD libraries that overlap (same
    /// upstream Xtream account). Without this toggle, Aerio fetches
    /// VOD from both — adding minutes to launch (e.g. 17k movies ×
    /// 2 servers paginated 25/page = ~1400 sequential HTTP calls
    /// against Dispatcharr) and triggering the cross-server
    /// duplicate-merge code path that's caused us trouble
    /// historically. With this toggle, the user keeps Live TV from
    /// both servers and VOD from just the main one.
    ///
    /// Defaults to `true` so existing servers keep their current
    /// behavior on upgrade. The Edit Server UI hides the toggle for
    /// server types that don't support VOD anyway (M3U-only
    /// playlists today).
    var vodEnabled: Bool = true

    /// Catch-up (timeshift): how many days of ALREADY-AIRED guide data to
    /// keep in the EPG cache for this server. Past programmes are what the
    /// catch-up "Watch" action hangs off, so the cache must retain them
    /// after the upstream feed stops covering them (feeds carry little or
    /// no history). 7-day default matches the common provider catch-up
    /// window; user-configurable in Edit Playlist ("Guide Days"), which also
    /// drives how many days AHEAD the guide loads (Logan 2026-09-11).
    /// 0 = "All Available" (walk until the server runs dry, bounded at 30
    /// days back / 60 ahead); a legacy stored 30 reads as All Available.
    /// Inline default = SwiftData lightweight migration, same pattern as
    /// every post-v1.6 field on this model.
    var epgRetentionDays: Int = 7

    /// v1.6.20: per-server Dispatcharr auth header shape, auto-detected
    /// during Test Connection and persisted so subsequent API calls and
    /// stream playback use the same shape. Empty string means
    /// "not yet detected" — `authHeaders` and `DispatcharrAPI` fall back
    /// to the historical dual header shape (`Authorization: ApiKey` +
    /// `X-API-Key`) which is what shipped before v1.6.20.
    ///
    /// Background: three users on private Dispatcharr instances reported
    /// HTTP 401 on Test Connection in v1.6.19 even with valid Admin API
    /// keys. v1.6.16's "X-API-Key alone" change (which fixed a VOD
    /// episodes filtering bug on the user's main server) is rejected by
    /// some Dispatcharr builds — they require the `Authorization` header
    /// or refuse the request. Auto-detection tries X-API-Key first
    /// (preferred — full VOD episode visibility) and falls back to dual
    /// or bearer on 401 so the user gets connected without needing to
    /// know which header shape their server speaks.
    ///
    /// Stored as raw string (not the enum directly) for SwiftData
    /// stability; `dispatcharrHeaderMode` returns the typed enum.
    /// Possible values: `""`, `"xapikey"`, `"both"`, `"bearer"`.
    var dispatcharrAuthMode: String = ""

    /// v1.7: which credential mode the user picked for this Dispatcharr
    /// server. Empty string = legacy default (`.apiKey`) so every server
    /// that existed before v1.7 keeps working without migration. New
    /// users get to choose API Key or Username & Password on the Add
    /// Server screen. See `DispatcharrCredentialType` for full doc.
    /// Possible values: `""` (= apiKey), `"api_key"`, `"username_password"`.
    var dispatcharrCredentialTypeRaw: String = ""

    /// v1.7.x: the connected Dispatcharr user's permission tier
    /// (Streamer = 0, Standard = 1, Admin = 10), captured from
    /// `/api/accounts/users/me/` (`user_level`) at Test Connection /
    /// Save. Used only to gate the server-side Record / DVR
    /// affordances (POST /api/channels/recordings/ requires IsAdmin =
    /// level 10; a Standard user gets HTTP 403). Viewing and local
    /// recording are unaffected.
    ///
    /// Defaults to `10` (admin) so back-compat servers (added before
    /// this field existed, synced from older AerioTV builds, or any
    /// non-Dispatcharr server) are treated as recording-capable and
    /// keep DVR. We only restrict when we positively learn the level
    /// is below 10 during a connect/verify.
    var dispatcharrUserLevel: Int = 10

    /// Dispatcharr 0.30 granular permissions, captured from
    /// /api/accounts/users/me/ at connect and refreshed on every launch.
    /// Defaults are the permissive server defaults so pre-capture rows and
    /// non-Dispatcharr servers behave as before. `dispatcharrDVRAccess` is
    /// "" until learned, in which case the level decides (admin = manage,
    /// standard = view, streamer = none), matching the server's default.
    var dispatcharrDVRAccess: String = ""
    var dispatcharrCatchupEnabled: Bool = true
    var dispatcharrVODMoviesEnabled: Bool = true
    var dispatcharrVODSeriesEnabled: Bool = true
    /// Server version string from /api/core/version/ ("" = unknown).
    var dispatcharrServerVersion: String = ""

    // MARK: Per-user capability snapshot
    //
    // Everything below is one SNAPSHOT of `GET /api/accounts/users/me/`
    // for the account this playlist is connected as. It is additive with
    // permissive defaults, so existing rows keep working, and it is what
    // the derived `dispatcharrCapabilities` gates on. The whole
    // `custom_properties` object is persisted verbatim, so a permission
    // key Dispatcharr adds later needs no store migration.

    /// `is_staff` from users/me. A Django staff / superuser account is a
    /// functional admin even when its custom `user_level` is still 0 or 1.
    var dispatcharrIsStaff: Bool = false
    var dispatcharrIsSuperuser: Bool = false
    /// The FULL `custom_properties` JSON object, verbatim. "" = never
    /// probed (distinct from "{}" = probed, no per-user overrides).
    var dispatcharrCustomPropertiesJSON: String = ""
    /// When the snapshot above was last read from the server. nil = never;
    /// capabilities then read `.unknown` and every affordance stays
    /// enabled so the server, not a guess, has the last word.
    var dispatcharrPermissionsFetchedAt: Date? = nil
    /// Snapshot schema. Bumping `DispatcharrCapabilitySet.currentSchema`
    /// invalidates every stored snapshot once, forcing one re-probe on
    /// upgrade (this is how accounts wrongly stuck at view-only repair
    /// themselves).
    var dispatcharrCapabilitiesSchema: Int = 0
    /// `system_settings.catchup_enabled` from `/api/core/settings/`.
    /// nil = not read (the endpoint needs level >= 1).
    var dispatcharrSystemCatchupEnabled: Bool? = nil

    /// Bumped every time this playlist's CREDENTIALS change (a different
    /// Dispatcharr / Xtream account, or the same account's password or
    /// api key replaced). Everything this app caches per account -- the
    /// channel list, the guide, VOD, DVR, the capability snapshot -- is
    /// keyed on the server row, so without an identity counter in that
    /// key the app kept serving the PREVIOUS account's data after an
    /// edit (reported 2026-09-15 on iPad: swapped an admin login for a
    /// standard "aeriotv" login and the app still behaved as admin).
    /// `MainTabView.channelServerKey` includes this, so a credential
    /// edit re-runs the whole load orchestrator exactly the way
    /// switching playlists does. Editing anything else leaves it alone,
    /// so a name or EPG-URL edit still costs nothing.
    var credentialGeneration: Int = 0

    /// Id of this server's AAC cast output profile from
    /// /api/core/outputprofiles/ (Dispatcharr 0.30 seeds a locked,
    /// active "Web Player (AAC Audio)" profile). nil = not learned yet
    /// or the server has none, in which case a cast session requests no
    /// profile and the phone falls back to AC-3 passthrough or its own
    /// AudioToolbox transcode. Captured wherever the server version is
    /// captured; local playback never requests it.
    var dispatcharrAACOutputProfileID: Int?

    /// v1.7.x: the Channel Profile id(s) assigned to the connected
    /// Dispatcharr user (`channel_profiles` on /api/accounts/users/me/),
    /// stored comma-joined for SwiftData stability. A Channel Profile is
    /// a curated subset of channels (e.g. a "Kids" profile with only
    /// age-appropriate channels). When non-empty, the Dispatcharr
    /// channel-load path filters the loaded channels down to the union
    /// of those profiles' memberships (fetched from
    /// `/api/channels/profiles/<id>/`). This is a child-safety filter.
    ///
    /// Empty string (the default) means no profile is assigned, so the
    /// user sees every channel exactly as before. This default also
    /// keeps back-compat: servers added before this field existed, or
    /// synced from older AerioTV builds, carry "" and stay unfiltered.
    /// Possible values: `""`, `"44"`, `"44,57"`.
    var dispatcharrChannelProfileIDs: String = ""

    /// Task #189 (Android parity): the USER-CHOSEN Dispatcharr Channel
    /// Profile to sync from this playlist (Edit Playlist > Channel
    /// Profile). Unlike `dispatcharrChannelProfileIDs` above (the
    /// account-assigned, fail-closed child-safety filter), this is a
    /// deliberate convenience filter the user picks from the server's
    /// profile list, and it fails OPEN: nil means "All Channels", and a
    /// membership-fetch error at sync time keeps the full list rather
    /// than blanking the lineup. Mirrors Android
    /// `PlaylistEntity.dispatcharrProfileId`.
    var dispatcharrSelectedProfileID: Int? = nil

    init(
        name: String,
        type: ServerType,
        baseURL: String,
        username: String = "",
        password: String = "",
        apiKey: String = "",
        epgURL: String = "",
        isActive: Bool = true,
        localURL: String = "",
        localEPGURL: String = "",
        homeSSID: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.apiKey = apiKey
        self.epgURL = epgURL
        self.isActive = isActive
        self.localURL = localURL
        self.localEPGURL = localEPGURL
        self.homeSSID = homeSSID
        self.sortOrder = 0
        self.createdAt = Date()
        self.isVerified = false
    }

    var supportsVOD: Bool { type.supportsVOD }

    /// Effective User-Agent for this server. Falls back to the app-wide
    /// default if the user hasn't set a per-server override.
    var effectiveUserAgent: String {
        let trimmed = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? DeviceInfo.defaultUserAgent : trimmed
    }

    /// Default destination for new recordings on this server. XC/M3U always
    /// record locally; Dispatcharr respects the user's saved preference.
    var defaultRecordingDestination: RecordingDestination {
        get {
            guard type == .dispatcharrAPI else { return .local }
            return RecordingDestination(rawValue: defaultRecordingDestinationRaw) ?? .dispatcharrServer
        }
        set { defaultRecordingDestinationRaw = newValue.rawValue }
    }

    // MARK: - Keychain-backed credentials

    /// Resolves a credential from Keychain. When iCloud credential sync is
    /// enabled, prefer the synchronizable copy so remote updates win over a
    /// stale local-only cache. Otherwise — including when iCloud Sync is
    /// off or the Credentials sync category is disabled — keep the historical
    /// local-first order so this device still works offline / local-only.
    private func resolvedCredential(for key: String, fallback: String) -> String {
        if UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") && SyncCategory.credentials.isEnabled {
            return KeychainHelper.load(key: key, synchronizable: true)
                ?? KeychainHelper.load(key: key)
                ?? fallback
        }
        return KeychainHelper.load(key: key)
            ?? KeychainHelper.load(key: key, synchronizable: true)
            ?? fallback
    }

    /// The effective password. When credential sync is enabled, prefers the
    /// iCloud Keychain copy so cross-device updates beat stale local items.
    var effectivePassword: String {
        let key = "password_\(id.uuidString)"
        return resolvedCredential(for: key, fallback: password)
    }

    /// The effective API key. When credential sync is enabled, prefers the
    /// iCloud Keychain copy so cross-device updates beat stale local items.
    var effectiveApiKey: String {
        let key = "apiKey_\(id.uuidString)"
        return resolvedCredential(for: key, fallback: apiKey)
    }

    /// Persists `password` and `apiKey` to the Keychain, then clears the plaintext
    /// values from the SwiftData store.  Call this after inserting or editing a server.
    func saveCredentialsToKeychain() {
        let pw  = password
        let key = apiKey
        if !pw.isEmpty {
            KeychainHelper.save(pw, for: "password_\(id.uuidString)")
            password = ""
        }
        if !key.isEmpty {
            KeychainHelper.save(key, for: "apiKey_\(id.uuidString)")
            apiKey = ""
        }
    }

    /// Removes this server's credentials from both local and iCloud Keychain.
    /// Call when deleting a server so keys don't linger.
    func deleteCredentialsFromKeychain() {
        KeychainHelper.delete("password_\(id.uuidString)")
        KeychainHelper.delete("apiKey_\(id.uuidString)")
        KeychainHelper.delete("password_\(id.uuidString)", synchronizable: true)
        KeychainHelper.delete("apiKey_\(id.uuidString)", synchronizable: true)
    }

    /// Effective Dispatcharr auth header mode. Honors the persisted
    /// `dispatcharrAuthMode` (auto-detected on Test Connection in
    /// v1.6.20+); falls back to `.both` for servers that haven't been
    /// re-verified since upgrading, since `Authorization: ApiKey` +
    /// `X-API-Key` together is the historical shape that worked on
    /// every Dispatcharr build prior to v1.6.20.
    var dispatcharrHeaderMode: DispatcharrAuthHeaderMode {
        DispatcharrAuthHeaderMode(rawValue: dispatcharrAuthMode) ?? .both
    }

    /// v1.7: which credential mode this Dispatcharr server uses. Empty
    /// raw value (the SwiftData default for servers added before v1.7)
    /// resolves to `.apiKey` so legacy behaviour is preserved.
    var dispatcharrCredentialType: DispatcharrCredentialType {
        DispatcharrCredentialType(rawValue: dispatcharrCredentialTypeRaw) ?? .apiKey
    }

    /// Whether this server can accept server-side (Dispatcharr DVR)
    /// recordings for the connected account. Only Dispatcharr servers
    /// are gated: POST /api/channels/recordings/ requires IsAdmin
    /// (`user_level` >= 10), so a Standard user (level 1) would hit
    /// HTTP 403. Non-Dispatcharr servers return `true` (they never
    /// touch this endpoint; their recordings always go local). The
    /// `dispatcharrUserLevel` default of 10 keeps back-compat /
    /// pre-capture servers recording-capable. Local recording is NOT
    /// gated by this and stays available to everyone.
    var dispatcharrCanRecordToServer: Bool {
        type != .dispatcharrAPI || dispatcharrCanManageDVR
    }

    /// The per-user capability snapshot, derived fresh on every read.
    ///
    /// Back-compat: when no snapshot has ever been stored (`fetchedAt ==
    /// nil`, i.e. an upgraded row or a playlist that arrived over iCloud
    /// from an older sender), the legacy per-flag columns are folded into
    /// a synthetic `custom_properties` so nothing regresses, but the set
    /// still reports `hasSnapshot == false` and every capability reads
    /// `.unknown` -> affordance enabled -> the server decides.
    var dispatcharrCapabilities: DispatcharrCapabilitySet {
        let props: DispatcharrCustomProperties
        let stored = DispatcharrCustomProperties(json: dispatcharrCustomPropertiesJSON)
        if stored.isPresent {
            props = stored
        } else {
            // Synthesize from the legacy columns so a pre-snapshot row
            // still derives the same answers it derived before.
            var values: [String: AnyJSON] = [:]
            if !dispatcharrDVRAccess.isEmpty { values["dvr_access"] = .string(dispatcharrDVRAccess) }
            if !dispatcharrVODMoviesEnabled { values["vod_movies_enabled"] = .bool(false) }
            if !dispatcharrVODSeriesEnabled { values["vod_series_enabled"] = .bool(false) }
            if !dispatcharrCatchupEnabled { values["catchup_enabled"] = .bool(false) }
            props = DispatcharrCustomProperties(values: values)
        }
        return DispatcharrCapabilitySet(
            isDispatcharr: type == .dispatcharrAPI,
            rawUserLevel: dispatcharrUserLevel,
            isStaff: dispatcharrIsStaff,
            isSuperuser: dispatcharrIsSuperuser,
            props: props,
            systemCatchupEnabled: dispatcharrSystemCatchupEnabled,
            fetchedAt: dispatcharrPermissionsFetchedAt,
            schema: dispatcharrCapabilitiesSchema
        )
    }

    /// Effective DVR access for a Dispatcharr account (0.30 semantics,
    /// mirrors apps/channels/dvr_access.py). Non-Dispatcharr = manage.
    var dispatcharrEffectiveDVRAccess: DispatcharrDVRAccess {
        dispatcharrCapabilities.dvrAccess
    }
    /// May list and play recordings (view or manage). Unknown = yes.
    var dispatcharrCanViewDVR: Bool { dispatcharrCapabilities.canViewDvr.isAllowed }
    /// May schedule, stop, cancel and delete recordings and rules.
    /// Unknown = yes; a 403 then self-corrects the snapshot.
    var dispatcharrCanManageDVR: Bool { dispatcharrCapabilities.canManageDvr.isAllowed }
    /// Catch-up / timeshift allowed for this account.
    var dispatcharrCanUseCatchup: Bool { dispatcharrCapabilities.canUseCatchup.isAllowed }
    /// Movies catalog allowed for this account.
    var dispatcharrCanViewVOD: Bool { dispatcharrCapabilities.canViewVod.isAllowed }
    /// Series catalog allowed for this account.
    var dispatcharrCanViewSeries: Bool { dispatcharrCapabilities.canViewSeries.isAllowed }

    /// Adopts a fresh `users/me` snapshot (and the version, when known).
    /// Used by Test Connection, the launch / foreground probe and the 403
    /// self-correction so a permission change on the server applies
    /// without re-adding the playlist. Returns true when anything changed.
    ///
    /// Invariant: an EMPTY read never overwrites a good snapshot. A decode
    /// that produced no `custom_properties` used to blank
    /// `dispatcharrDVRAccess`, which demoted a "manage" account to
    /// view-only until the next successful probe. Now the level / staff
    /// fields still update, the previous blob is kept, and the snapshot is
    /// marked stale so the next probe retries.
    /// Forget everything this row remembers about the account it was
    /// connected AS, so the next probe starts from a blank slate instead
    /// of coalescing the new account onto the old one's answers.
    ///
    /// Called from `ServerCredentialChange.commit` when an edit replaced
    /// the credentials. The account-scoped fields are reset to their
    /// "never probed" defaults; SERVER-scoped fields (version, auth
    /// header shape, AAC output profile id) are deliberately kept
    /// because they describe the deployment, not the user.
    ///
    /// Note the deliberate asymmetry with `applyDispatcharrPermissions`,
    /// which never lets an empty read blank a good snapshot: there the
    /// snapshot still describes the SAME account and a blank read is a
    /// network artifact. Here the account itself changed, so the old
    /// snapshot is not "last known good", it is wrong.
    func resetDispatcharrAccountSnapshot() {
        dispatcharrUserLevel = 10
        dispatcharrIsStaff = false
        dispatcharrIsSuperuser = false
        dispatcharrCustomPropertiesJSON = ""
        dispatcharrPermissionsFetchedAt = nil
        dispatcharrCapabilitiesSchema = 0
        dispatcharrSystemCatchupEnabled = nil
        dispatcharrDVRAccess = ""
        dispatcharrCatchupEnabled = true
        dispatcharrVODMoviesEnabled = true
        dispatcharrVODSeriesEnabled = true
        dispatcharrChannelProfileIDs = ""
    }

    @discardableResult
    func applyDispatcharrPermissions(from user: DispatcharrUser,
                                     version: String?,
                                     systemCatchupEnabled: Bool? = nil) -> Bool {
        var changed = false
        func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<ServerConnection, T>, _ v: T) {
            if self[keyPath: kp] != v { self[keyPath: kp] = v; changed = true }
        }
        set(\.dispatcharrIsStaff, user.isStaff)
        set(\.dispatcharrIsSuperuser, user.isSuperuser)
        if let version, !version.isEmpty { set(\.dispatcharrServerVersion, version) }
        if let systemCatchupEnabled { set(\.dispatcharrSystemCatchupEnabled, systemCatchupEnabled) }

        let fresh = DispatcharrCustomProperties(json: user.customPropertiesJSON)
        guard fresh.isPresent else {
            // No usable blob in this response. Keep whatever we had and
            // mark the snapshot stale so the next opportunistic probe
            // tries again, rather than writing an empty grant.
            debugLog("[PERMS] \(name): users/me carried no custom_properties; keeping the last good snapshot")
            if dispatcharrPermissionsFetchedAt != nil {
                set(\.dispatcharrPermissionsFetchedAt, Date(timeIntervalSince1970: 0))
            }
            return changed
        }

        // A key the admin REMOVED must clear our stored value, so we write
        // the fresh blob wholesale rather than merging into the old one.
        set(\.dispatcharrCustomPropertiesJSON, fresh.jsonString)
        // Keep the legacy columns mirrored: older AerioTV builds on other
        // devices (and the pre-snapshot fallback above) still read them.
        set(\.dispatcharrDVRAccess, fresh.string("dvr_access")?.lowercased() ?? "")
        set(\.dispatcharrCatchupEnabled, fresh.bool("catchup_enabled") != false)
        set(\.dispatcharrVODMoviesEnabled, fresh.bool("vod_movies_enabled") != false)
        set(\.dispatcharrVODSeriesEnabled, fresh.bool("vod_series_enabled") != false)
        set(\.dispatcharrCapabilitiesSchema, DispatcharrCapabilitySet.currentSchema)
        dispatcharrPermissionsFetchedAt = Date()
        changed = true
        return changed
    }

    /// Persist the AAC cast output profile id learned from
    /// /api/core/outputprofiles/. Returns true when it changed, so
    /// callers can decide whether to push the row to iCloud.
    @discardableResult
    func applyDispatcharrAACOutputProfile(_ id: Int?) -> Bool {
        guard dispatcharrAACOutputProfileID != id else { return false }
        dispatcharrAACOutputProfileID = id
        return true
    }

    /// Whether the server is at least `minimum` (semver, "0.30.0"). False
    /// when the version is unknown.
    func dispatcharrVersionAtLeast(_ minimum: String) -> Bool {
        guard type == .dispatcharrAPI, !dispatcharrServerVersion.isEmpty else { return false }
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(dispatcharrServerVersion), b = parts(minimum)
        for i in 0..<3 {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// Whether the connected account may use Switch Stream (pick a
    /// channel's active upstream from the player). Dispatcharr Direct
    /// Connect only, and admin only: `POST /proxy/ts/change_stream/<uuid>`
    /// is server-side `IsAdmin` (`user_level` >= 10), so a Standard /
    /// Streamer account gets HTTP 403. Note the INVERTED shape vs
    /// `dispatcharrCanRecordToServer`: this is `==` + `&&`, so it returns
    /// `false` for every non-Dispatcharr server (Xtream / M3U never expose
    /// member streams or a change-stream endpoint), hiding the affordance
    /// there instead of showing an option that can't work.
    var dispatcharrCanSwitchStream: Bool {
        dispatcharrCapabilities.canSwitchStream.isAllowed
    }

    /// Parsed list of the connected Dispatcharr user's assigned Channel
    /// Profile ids. Splits `dispatcharrChannelProfileIDs` on commas,
    /// trims whitespace, and drops blanks / non-integers so a malformed
    /// stored value can never crash the channel-load filter. An empty
    /// array (the common case: no profile assigned, or a non-Dispatcharr
    /// server) signals "show every channel" to the load path.
    var dispatcharrProfileIDList: [Int] {
        dispatcharrChannelProfileIDs
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Auth headers for API requests. Dispatcharr servers honor the
    /// per-server `dispatcharrHeaderMode` (X-API-Key only, dual, or
    /// bearer-with-API-key, auto-detected during Test Connection so
    /// different Dispatcharr builds with different header requirements
    /// all work). User-Agent is always included so the device shows
    /// up in the admin Stats panel. All other server types just
    /// include Accept. Centralised here to avoid duplication.
    ///
    /// **v1.7 back-compat invariant:** these headers are gated on the
    /// presence of `effectiveApiKey`, **not** on `dispatcharrCredential-
    /// Type`. Reasoning: every existing user has an `apiKey` in the
    /// Keychain and `dispatcharrCredentialTypeRaw == ""` (resolves to
    /// `.apiKey`), so they emit exactly the same headers as before
    /// v1.7. New Direct Connect users (`usernamePassword` mode) also
    /// have an api_key in Keychain because the login flow fetches it
    /// from `/api/accounts/users/me/` during Test Connection and
    /// persists it — we deliberately do this so long-lived
    /// connections (mpv stream playback, logo fetches, recording
    /// playback) keep working with a durable credential and don't
    /// have to refresh-token mid-stream.
    ///
    /// **JWT layering:** when an active JWT access token is also
    /// present (Direct Connect mode, post-login), the
    /// `DispatcharrAPI.headers(for:)` path layers `Authorization:
    /// Bearer <jwt>` ON TOP of these headers, replacing the
    /// `Authorization: ApiKey ...` value where applicable. Dispatcharr
    /// prefers the Bearer header when both are sent. So in practice:
    ///   - API-key-only users: X-API-Key (and/or `Authorization:
    ///     ApiKey`) per `dispatcharrHeaderMode`. Unchanged from v1.6.
    ///   - Direct Connect users with live JWT: `Authorization: Bearer
    ///     <jwt>` + `X-API-Key`. Server uses Bearer.
    ///   - Direct Connect users between sessions (JWT not refreshed
    ///     yet): X-API-Key (and/or `Authorization: ApiKey`) per
    ///     `dispatcharrHeaderMode`. Same as legacy. Auto-recovers
    ///     once JWT refresh completes.
    var authHeaders: [String: String] {
        switch type {
        case .dispatcharrAPI:
            var h: [String: String] = [
                "Accept": "*/*",
                "User-Agent": effectiveUserAgent
            ]
            let key = effectiveApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty key (e.g. brand-new Direct Connect server before
            // Test Connection completes its api_key fetch) returns
            // just Accept + UA so the calling layer can layer JWT
            // Bearer on top. Otherwise emit the configured shape.
            guard !key.isEmpty else { return h }
            switch dispatcharrHeaderMode {
            case .xapikey:
                h["X-API-Key"] = key
            case .both:
                h["Authorization"] = "ApiKey \(key)"
                h["X-API-Key"] = key
            case .bearer:
                h["Authorization"] = "Bearer \(key)"
            }
            return h
        default:
            return ["Accept": "*/*"]
        }
    }

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    /// Returns localURL (normalized) when the server is reachable on the
    /// local network (per `TVLANProbe`), otherwise the public baseURL.
    var effectiveBaseURL: String {
        guard !localURL.isEmpty else { return normalizedBaseURL }
        guard isOnLANNetwork else { return normalizedBaseURL }
        return normalizedLocalURL
    }

    /// BOTH of this server's own hosts (public base + LAN local), lowercased.
    /// The poster/image trust boundary must accept either at ANY time:
    /// poster URLs are built at fetch time while `effectiveBaseURL` flips
    /// between the two per TVLANProbe, so a single-host-at-one-instant
    /// comparison strips auth headers / rejects the server's own LAN-IP
    /// covers whenever fetch-time and check-time routing diverge (the
    /// v1.7.9 blank-VOD-covers regression, Discord 2026-07-23).
    var ownHosts: Set<String> {
        var hosts = Set<String>()
        if let h = URL(string: normalizedBaseURL)?.host?.lowercased() { hosts.insert(h) }
        if !localURL.isEmpty, let h = URL(string: normalizedLocalURL)?.host?.lowercased() { hosts.insert(h) }
        return hosts
    }

    /// Returns localEPGURL when the server is reachable on the local
    /// network (per `TVLANProbe`), otherwise returns epgURL.
    var effectiveEPGURL: String {
        if !localEPGURL.isEmpty, isOnLANNetwork { return localEPGURL }
        if !epgURL.isEmpty { return epgURL }
        // An M3U playlist whose URL is really an Xtream `get.php` link is
        // loaded through the XC JSON (see HomeView.fetchChannels), so its
        // channels carry epg_channel_id. Derive the panel's own xmltv.php so
        // they have a guide to match against; without this those playlists end
        // up with guide ids and no guide. Only ever a fallback: an explicit
        // epgURL, and the LAN override above, both still win.
        guard type == .m3uPlaylist else { return "" }
        return XtreamCodesAPI.derivedXMLTVURL(fromGetPhpURL: baseURL) ?? ""
    }

    var normalizedLocalURL: String {
        var url = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "http://" + url }
        return url
    }

    /// Whether this device is currently on the home/LAN network.
    /// True when `TVLANProbe` has confirmed the server's local URL is
    /// reachable. This is the SOLE LAN signal on every platform — there
    /// is no longer any SSID / Wi-Fi-info / location dependence.
    ///
    /// The probe HEAD-checks `localURL` at app launch, on scenePhase
    /// `.active`, on `NWPathMonitor` network changes, on server-count
    /// change, and via the Settings "Refresh LAN Detection" button.
    /// Network-medium-agnostic, so this works on Ethernet, Wi-Fi, and
    /// any case where the local server is reachable.
    ///
    /// The result is persisted under the legacy `"tvosLANDetected"`
    /// key (name kept to avoid breaking existing installs that already
    /// have a last-known LAN flag stored there).
    private var isOnLANNetwork: Bool {
        // Per-server verdict (2026-08-13 VPS-migration fix): THIS server's
        // localURL must itself have answered the probe. The old global
        // bool let any reachable sibling localURL vouch for a dead one,
        // stranding effectiveBaseURL on a refused-connection LAN address
        // with no WAN fallback. Key format matches
        // TVLANProbe.reachabilityKey (normalized absolute URL, lowercased).
        // A missing array (pre-upgrade persisted state, one launch max)
        // falls back to the old global flag.
        let defaults = UserDefaults.standard
        guard let reachable = defaults.stringArray(forKey: "tvosLANReachableURLs") else {
            return defaults.bool(forKey: "tvosLANDetected")
        }
        return reachable.contains(normalizedLocalURL.lowercased())
    }

    var isHTTPS: Bool {
        baseURL.lowercased().hasPrefix("https://")
    }

    // Legacy compatibility shims (unused but prevent SwiftData migration errors)
    var plexToken: String { "" }
    var dispatcharrAPIKey: String { "" }
}

// MARK: - Channel Group Model
@Model
final class ChannelGroup {
    var id: UUID
    var name: String
    var serverID: UUID
    var sortOrder: Int
    var isHidden: Bool

    @Relationship(deleteRule: .cascade)
    var channels: [Channel] = []

    init(name: String, serverID: UUID) {
        self.id = UUID()
        self.name = name
        self.serverID = serverID
        self.sortOrder = 0
        self.isHidden = false
    }
}

// MARK: - Channel Model
@Model
final class Channel {
    var id: UUID
    var serverID: UUID
    var channelNumber: Int
    var name: String
    var streamURL: String
    var logoURL: String
    var groupName: String
    var epgChannelID: String
    var isFavorite: Bool
    var lastWatched: Date?
    var sortOrder: Int

    init(
        serverID: UUID,
        channelNumber: Int = 0,
        name: String,
        streamURL: String,
        logoURL: String = "",
        groupName: String = "",
        epgChannelID: String = ""
    ) {
        self.id = UUID()
        self.serverID = serverID
        self.channelNumber = channelNumber
        self.name = name
        self.streamURL = streamURL
        self.logoURL = logoURL
        self.groupName = groupName
        self.epgChannelID = epgChannelID
        self.isFavorite = false
        self.sortOrder = 0
    }
}

// MARK: - EPG Program Model
@Model
final class EPGProgram {
    var id: UUID
    var channelID: String
    var title: String
    var programDescription: String
    var startTime: Date
    var endTime: Date
    var category: String
    var posterURL: String
    /// Identifies which server this EPG data belongs to (scopes cache per server).
    var serverID: String
    /// When this entry was fetched from the network (for staleness checks).
    var fetchedAt: Date
    /// v1.7.x: Dispatcharr's per-program primary key. Persists across
    /// launches so `ProgramInfoView`'s lazy `/api/epg/programs/<id>/`
    /// fetch survives cold starts where the orchestrator decides the
    /// cache is fresh enough to skip re-fetching the grid. Without
    /// this, every `<24h-old` cache load came back with `programID =
    /// nil` for every program, leaving the modal unable to retrieve
    /// categories that the bulk grid endpoint deliberately strips.
    /// Default `nil` for SwiftData lightweight migration: existing
    /// cached rows (from builds before this field shipped) survive
    /// the upgrade as nils and get repopulated on the next bulk
    /// grid fetch.
    var programID: Int? = nil

    // MARK: EPG badge metadata (guide/list/info-sheet badges)
    // Optional-or-defaulted stored properties so SwiftData lightweight
    // migration carries pre-badge cached rows forward (mirrors the
    // `programID` precedent above). `isLiveBroadcast` is the feed's
    // XMLTV `<live/>` / Dispatcharr `is_live` flag, distinct from the
    // clock-derived `isLive` computed below.
    var subTitle: String? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var isNew: Bool = false
    var isLiveBroadcast: Bool = false
    var isPremiere: Bool = false
    var isFinale: Bool = false
    var isRepeat: Bool = false

    init(channelID: String, title: String, description: String = "",
         startTime: Date, endTime: Date, category: String = "", posterURL: String = "",
         serverID: String = "", fetchedAt: Date = Date(),
         programID: Int? = nil,
         subTitle: String? = nil, season: Int? = nil, episode: Int? = nil,
         isNew: Bool = false, isLiveBroadcast: Bool = false,
         isPremiere: Bool = false, isFinale: Bool = false, isRepeat: Bool = false) {
        self.id = UUID()
        self.channelID = channelID
        self.title = title
        self.programDescription = description
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
        self.posterURL = posterURL
        self.serverID = serverID
        self.fetchedAt = fetchedAt
        self.programID = programID
        self.subTitle = subTitle
        self.season = season
        self.episode = episode
        self.isNew = isNew
        self.isLiveBroadcast = isLiveBroadcast
        self.isPremiere = isPremiere
        self.isFinale = isFinale
        self.isRepeat = isRepeat
    }

    var isLive: Bool {
        let now = Date()
        return now >= startTime && now <= endTime
    }

    var progressFraction: Double {
        let now = Date()
        guard now >= startTime else { return 0 }
        let total = endTime.timeIntervalSince(startTime)
        // Guard against a zero (or negative) span: an EPG program with
        // start == end would make elapsed / total produce inf/NaN, which
        // then feeds a progress-bar width and triggers SwiftUI layout
        // warnings / a broken bar. Treat a non-positive span as no progress.
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(startTime)
        return min(1.0, elapsed / total)
    }

    var durationMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }
}

// MARK: - DVR / Recording

/// Where a recording is stored. Dispatcharr users can pick; XC/M3U users
/// only have `.local`.
enum RecordingDestination: String, Codable, CaseIterable {
    case dispatcharrServer = "dispatcharr_server"
    case local = "local"

    var displayName: String {
        switch self {
        case .dispatcharrServer: return "Dispatcharr server"
        case .local: return "This device"
        }
    }
}

/// Recording lifecycle states. Values mirror Dispatcharr's
/// `custom_properties.status` so we can store them directly from API
/// responses, with `cancelled` added for locally-cancelled scheduled rows.
enum RecordingStatus: String, Codable {
    case scheduled
    case recording
    case completed
    case interrupted
    case failed
    case stopped
    case cancelled
}

/// A DVR recording — either scheduled on a Dispatcharr server or captured
/// locally via `LocalRecordingSession`. Persisted as the single source of
/// truth for both destinations.
/// SwiftData mirror of a recording (local DVR capture or
/// Dispatcharr-server recording).
///
/// **iCloud sync model (v1.6.23 documented):** `Recording` rows are
/// intentionally device-local. Two reasons:
///
/// 1. **Local recordings** (`destination == .local`): the captured
///    `.ts` file lives in `Documents/Recordings/<UUID>.ts` on the
///    recording device. The file isn't transferable across devices,
///    so syncing the metadata row would point other devices at a
///    file they can't read.
///
/// 2. **Dispatcharr-server recordings** (`destination == .dispatcharrServer`):
///    cross-device coherence already exists via
///    `RecordingCoordinator.reconcileDispatcharrRecordings`. Every
///    device that connects to the same Dispatcharr server fetches
///    `/api/channels/recordings/` from the server and rebuilds its
///    local rows from the authoritative server-side list. No iCloud
///    sync needed; the server is the source of truth.
///
/// The pre-public-release audit flagged "Recording not synced" as a
/// HIGH item; this comment exists so the architectural decision is
/// visible inline rather than buried in CHANGELOG history.
@Model
final class Recording {
    var id: UUID
    /// Channel the recording was scheduled from.
    var channelID: String
    var channelName: String
    /// Program metadata at schedule time (frozen — EPG may change later).
    var programTitle: String
    var programDescription: String
    /// Original EPG start/end before any pre/post-roll adjustment.
    var scheduledStart: Date
    var scheduledEnd: Date
    /// User-chosen buffer for this recording (may differ from DVR defaults).
    var preRollMinutes: Int
    var postRollMinutes: Int
    /// Destination.rawValue — stored as String so SwiftData handles enum
    /// migrations cleanly.
    var destinationRaw: String
    var statusRaw: String
    /// Absolute path inside the app's Documents (or security-scoped bookmark
    /// resolved path) for local recordings. Nil for Dispatcharr recordings.
    var localFilePath: String?
    /// Dispatcharr-assigned integer recording ID. Nil for local recordings.
    var remoteRecordingID: Int?
    /// Server-provided playback URL path (relative, e.g.
    /// `/api/channels/recordings/<id>/file/` for completed,
    /// `/api/channels/recordings/<id>/hls/index.m3u8` for
    /// in-progress on Dispatcharr's new DVR pipeline). Stored
    /// here so `MyRecordingsView` can hand mpv the right URL
    /// without inspecting status. Nil on older Dispatcharr builds
    /// that don't emit `custom_properties.file_url`; callers
    /// fall back to the constructed `/file/` path. v1.6.22.
    var dispatcharrFileURL: String?
    var fileSizeBytes: Int64
    /// Which `ServerConnection` this recording belongs to (UUID string).
    var serverID: String
    var createdAt: Date
    /// Populated when `status == .failed` for user-visible diagnostics.
    var failureReason: String?
    /// Media-center metadata (DVR tab redesign, 2026-09-05). All optional
    /// with defaults so existing stores migrate in place.
    /// Artwork: Dispatcharr `custom_properties.poster_url`, the EPG
    /// programme poster, or a TMDB / TheSportsDB lookup resolved by
    /// `DVRArtResolver`. Absolute URL string.
    var posterURL: String? = nil
    /// Landscape art (TMDB backdrop) for the hero and 16:9 cards; the
    /// poster is the fallback when none was found.
    var backdropURL: String? = nil
    /// Episode name (Dispatcharr `program.sub_title`).
    var subTitle: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    /// Season and episode as shown. Some feeds encode the air date as
    /// "S2026 E905"; those are not episode identity and are hidden.
    var displaySeasonEpisode: (season: Int, episode: Int)? {
        guard let s = seasonNumber, let e = episodeNumber, s < 1900 else { return nil }
        return (s, e)
    }
    /// EPG genre/category text, used to classify the recording
    /// (movie / series / sports) for the DVR pills and art lookups.
    var epgCategory: String? = nil
    var contentRating: String? = nil
    /// Dispatcharr programme id carried by the recording itself (see
    /// DispatcharrAPI.Recording.programID). Default nil for the lightweight
    /// migration of existing rows.
    var dispatcharrProgramID: Int? = nil
    /// Channel logo captured at schedule / import time (the recording's
    /// `channelID` is not resolvable back to a Channel row on every source).
    var channelLogoURL: String? = nil
    /// Stream facts Dispatcharr captures when a recording finishes
    /// (custom_properties.stream_info): shown in Program Info's
    /// Recording block. Nil for local recordings and older servers.
    /// Server-side file name (custom_properties.file_name); the playback
    /// URL has no extension, so the container format comes from here.
    var remoteFileName: String? = nil
    var videoCodec: String? = nil
    var videoResolution: String? = nil
    var videoFrameRate: Double? = nil
    var videoBitrateKbps: Double? = nil
    var audioCodec: String? = nil
    var audioChannels: String? = nil

    init(channelID: String,
         channelName: String,
         programTitle: String,
         programDescription: String = "",
         scheduledStart: Date,
         scheduledEnd: Date,
         preRollMinutes: Int = 0,
         postRollMinutes: Int = 0,
         destination: RecordingDestination,
         status: RecordingStatus = .scheduled,
         localFilePath: String? = nil,
         remoteRecordingID: Int? = nil,
         dispatcharrFileURL: String? = nil,
         fileSizeBytes: Int64 = 0,
         serverID: String,
         failureReason: String? = nil) {
        self.id = UUID()
        self.channelID = channelID
        self.channelName = channelName
        self.programTitle = programTitle
        self.programDescription = programDescription
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.preRollMinutes = preRollMinutes
        self.postRollMinutes = postRollMinutes
        self.destinationRaw = destination.rawValue
        self.statusRaw = status.rawValue
        self.localFilePath = localFilePath
        self.remoteRecordingID = remoteRecordingID
        self.dispatcharrFileURL = dispatcharrFileURL
        self.fileSizeBytes = fileSizeBytes
        self.serverID = serverID
        self.createdAt = Date()
        self.failureReason = failureReason
    }

    var destination: RecordingDestination {
        get { RecordingDestination(rawValue: destinationRaw) ?? .local }
        set { destinationRaw = newValue.rawValue }
    }

    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }

    /// Effective recording start after applying pre-roll buffer.
    var effectiveStart: Date {
        scheduledStart.addingTimeInterval(-Double(preRollMinutes) * 60)
    }

    /// Effective recording end after applying post-roll buffer.
    var effectiveEnd: Date {
        scheduledEnd.addingTimeInterval(Double(postRollMinutes) * 60)
    }

    var isInProgress: Bool { status == .recording }
    var isCompleted: Bool { status == .completed }
    var isUpcoming: Bool { status == .scheduled }

    /// GH #75: the WatchProgress key for this recording. Server
    /// recordings key on the Dispatcharr recording id ("dvr-<id>") so
    /// the same recording resolves to the same row on every Apple
    /// device the user syncs (iPad -> Apple TV); the "dvr-" prefix
    /// keeps it out of the movie / episode id space. Local (on-disk)
    /// recordings key on the local row UUID: the file never leaves
    /// this device, so neither does its progress. nil when a server
    /// recording has no remote id yet (nothing to resume).
    var watchProgressID: String? {
        switch destination {
        case .dispatcharrServer:
            guard let remoteID = remoteRecordingID else { return nil }
            return "dvr-\(remoteID)"
        case .local:
            return "local-\(id.uuidString)"
        }
    }
}

// MARK: - Dispatcharr per-user capabilities
//
// Replaces the old hard "Admin vs Standard" gate. Dispatcharr hands every
// authenticated account its own permission blob on
// `GET /api/accounts/users/me/` (Authenticated, any level), which carries
// `user_level`, `is_staff`, `is_superuser` and the FULL free-form
// `custom_properties` object (`dvr_access`, `vod_movies_enabled`,
// `vod_series_enabled`, `catchup_enabled`, `allowed_m3u_profile_ids`, ...).
// We persist that blob verbatim per ServerConnection and DERIVE named
// capabilities from it on read, so a new server-side permission key needs
// no store migration: only a new derived accessor.
//
// Tri-state on purpose. `unknown` (we have never successfully probed this
// account, or the probe failed and left us with nothing) renders the
// affordance ENABLED and lets the server have the last word. Silently
// downgrading an unknown account to view-only is the bug this replaces.

/// A free-form JSON value, used to round-trip Dispatcharr's
/// `custom_properties` object without knowing its keys.
enum AnyJSON: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool BEFORE number: JSONDecoder happily reads `true` as 1.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyJSON].self) { self = .object(o); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intArrayValue: [Int]? {
        guard case .array(let a) = self else { return nil }
        return a.compactMap { if case .number(let d) = $0 { return Int(d) } else { return nil } }
    }
}

/// Typed, key-agnostic reader over a persisted `custom_properties` blob.
struct DispatcharrCustomProperties: Sendable, Equatable {
    /// True when we actually have a blob from the server (even an empty
    /// `{}`), as opposed to "never probed". An empty object is a real
    /// answer: it means the admin set no per-user overrides.
    let isPresent: Bool
    private let values: [String: AnyJSON]

    init(json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: AnyJSON].self, from: data) else {
            isPresent = false
            values = [:]
            return
        }
        isPresent = true
        values = decoded
    }

    init(values: [String: AnyJSON]) {
        isPresent = true
        self.values = values
    }

    static let absent = DispatcharrCustomProperties(json: "")

    /// A key the server did not send reads nil, which every capability
    /// treats as "server default", exactly as Dispatcharr does.
    func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    func string(_ key: String) -> String? { values[key]?.stringValue }
    func intArray(_ key: String) -> [Int]? { values[key]?.intArrayValue }

    var jsonString: String {
        guard isPresent,
              let data = try? JSONEncoder().encode(values),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

/// Tri-state answer for one capability.
enum CapabilityState: String, Sendable {
    /// We probed and the account may do this.
    case allowed
    /// We probed and the account may NOT do this.
    case denied
    /// We have no trustworthy snapshot. The affordance stays enabled and
    /// the server decides; a 403 then self-corrects the snapshot.
    case unknown

    /// Render the affordance? Unknown renders ENABLED on purpose.
    var isAllowed: Bool { self != .denied }
    var isKnown: Bool { self != .unknown }
}

/// The named capabilities the app gates on. Extend this list (plus the
/// matching derivation in `DispatcharrCapabilitySet`) as Dispatcharr adds
/// granular permissions; no store change is needed because the whole
/// `custom_properties` blob is already persisted.
enum DispatcharrCapability: String, Sendable, CaseIterable {
    case viewVod
    case viewSeries
    case useCatchup
    case viewDvr
    case manageDvr
    case switchStream
    case managePlaylists
    case readServerSettings

    /// What to tell the user when the server says no and our re-probe
    /// agrees that the account genuinely lacks this.
    var deniedMessage: String {
        switch self {
        case .viewVod:
            return "Your Dispatcharr account does not have access to movies. Ask your server administrator for VOD access."
        case .viewSeries:
            return "Your Dispatcharr account does not have access to TV shows. Ask your server administrator for VOD access."
        case .useCatchup:
            return "Catch-up is turned off for your Dispatcharr account. Ask your server administrator to enable it."
        case .viewDvr:
            return "Your Dispatcharr account does not have access to recordings. Ask your server administrator for DVR access."
        case .manageDvr:
            return "Your Dispatcharr account can view recordings but not manage them. Ask your server administrator for DVR manage access."
        case .switchStream:
            return "Switching the active stream needs a Dispatcharr administrator account."
        case .managePlaylists:
            return "Editing playlists on the server needs a Dispatcharr administrator account."
        case .readServerSettings:
            return "Your Dispatcharr account cannot read server settings."
        }
    }

    /// What to tell the user when the server said no but the account's
    /// own permissions say it should have been allowed. Dispatcharr can
    /// also refuse on per-user `allowed_networks` (a network policy),
    /// which has nothing to do with the permission tier.
    var networkRestrictionMessage: String {
        "Your Dispatcharr account has permission for this, but the server refused the request. This usually means a network restriction on the account (allowed networks). Ask your server administrator to allow this device's network."
    }
}

/// Capabilities derived from one persisted snapshot. Value type: build it
/// fresh from the model on every read so it can never go stale in place.
struct DispatcharrCapabilitySet: Sendable {
    let isDispatcharr: Bool
    let rawUserLevel: Int
    let isStaff: Bool
    let isSuperuser: Bool
    let props: DispatcharrCustomProperties
    /// `system_settings.catchup_enabled` from `/api/core/settings/`.
    /// nil = not read (readable at level >= 1, so a Streamer never sees it).
    let systemCatchupEnabled: Bool?
    let fetchedAt: Date?
    let schema: Int

    /// The level to gate on. A Django staff / superuser is a functional
    /// admin even when its custom `user_level` is still 0 or 1 (legacy
    /// superusers never had the level defaulted to 10).
    var effectiveUserLevel: Int { (isStaff || isSuperuser) ? 10 : rawUserLevel }

    /// Bump to force one re-probe for every user on upgrade. Raised to 1
    /// so accounts wrongly stuck at view-only (synced playlists arrived
    /// without any permission payload) repair themselves on first launch.
    static let currentSchema = 1

    /// Re-probe roughly every six hours from a screen that cares.
    static let staleAfter: TimeInterval = 6 * 60 * 60

    /// Do we have a snapshot we are willing to gate on?
    var hasSnapshot: Bool { fetchedAt != nil && schema >= Self.currentSchema }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        return schema < Self.currentSchema || Date().timeIntervalSince(fetchedAt) > Self.staleAfter
    }

    // MARK: Derived capabilities

    /// Mirrors `apps/channels/dvr_access.py`: level >= 10 -> manage,
    /// level < 1 -> none, else `custom_properties.dvr_access` when it is
    /// one of none/view/manage, else "view" (an ABSENT key = view).
    var dvrAccess: DispatcharrDVRAccess {
        guard isDispatcharr else { return .manage }
        if effectiveUserLevel >= 10 { return .manage }
        if effectiveUserLevel < 1 { return .none }
        switch props.string("dvr_access")?.lowercased() {
        case "none": return .none
        case "manage": return .manage
        default: return .view
        }
    }

    var canViewDvr: CapabilityState {
        guard isDispatcharr else { return .allowed }
        guard hasSnapshot else { return .unknown }
        return dvrAccess == .none ? .denied : .allowed
    }

    var canManageDvr: CapabilityState {
        guard isDispatcharr else { return .allowed }
        guard hasSnapshot else { return .unknown }
        return dvrAccess == .manage ? .allowed : .denied
    }

    /// `apps/vod/utils.py`: absent = enabled; only an explicit `false`
    /// disables. A blocked account gets an EMPTY catalog, not a 403.
    var canViewVod: CapabilityState {
        guard isDispatcharr else { return .allowed }
        guard hasSnapshot else { return .unknown }
        return props.bool("vod_movies_enabled") == false ? .denied : .allowed
    }

    var canViewSeries: CapabilityState {
        guard isDispatcharr else { return .allowed }
        guard hasSnapshot else { return .unknown }
        return props.bool("vod_series_enabled") == false ? .denied : .allowed
    }

    /// Catch-up needs BOTH the per-user flag and the server-wide
    /// `system_settings.catchup_enabled`. Either explicit false denies;
    /// an unread system setting never denies on its own.
    var canUseCatchup: CapabilityState {
        guard isDispatcharr else { return .allowed }
        guard hasSnapshot else { return .unknown }
        if props.bool("catchup_enabled") == false { return .denied }
        if systemCatchupEnabled == false { return .denied }
        return .allowed
    }

    /// `POST /proxy/ts/change_stream/<uuid>` and the other /proxy control
    /// endpoints are still `IsAdmin` server-side, so this stays admin
    /// only. Non-Dispatcharr servers never expose member streams at all,
    /// so the affordance is hidden rather than shown-then-failing.
    var canSwitchStream: CapabilityState {
        guard isDispatcharr else { return .denied }
        guard hasSnapshot else { return .unknown }
        return effectiveUserLevel >= 10 ? .allowed : .denied
    }

    /// Server-side playlist / M3U account writes are `IsAdmin`.
    var canManagePlaylists: CapabilityState {
        guard isDispatcharr else { return .allowed }
        guard hasSnapshot else { return .unknown }
        return effectiveUserLevel >= 10 ? .allowed : .denied
    }

    /// `GET /api/core/settings/` is readable at level >= 1.
    var canReadServerSettings: CapabilityState {
        guard isDispatcharr else { return .allowed }
        guard hasSnapshot else { return .unknown }
        return effectiveUserLevel >= 1 ? .allowed : .denied
    }

    func state(of capability: DispatcharrCapability) -> CapabilityState {
        switch capability {
        case .viewVod: return canViewVod
        case .viewSeries: return canViewSeries
        case .useCatchup: return canUseCatchup
        case .viewDvr: return canViewDvr
        case .manageDvr: return canManageDvr
        case .switchStream: return canSwitchStream
        case .managePlaylists: return canManagePlaylists
        case .readServerSettings: return canReadServerSettings
        }
    }

    /// Compact, greppable one-liner for the probe log. Deliberately flat
    /// `key=value` pairs so a tester can verify a permission change with
    /// `log stream | grep "\[PERMS\]"` (or a grep over the shared log
    /// file) without reading the app's UI.
    var probeSummary: String {
        func flag(_ s: CapabilityState) -> String {
            switch s {
            case .allowed: return "true"
            case .denied: return "false"
            case .unknown: return "unknown"
            }
        }
        return "level=\(effectiveUserLevel) staff=\(isStaff) su=\(isSuperuser) "
            + "dvr=\(dvrAccess.rawValue) vod=\(flag(canViewVod)) series=\(flag(canViewSeries)) "
            + "catchup=\(flag(canUseCatchup)) switch=\(canSwitchStream.rawValue)"
    }

    var debugDescription: String {
        "level=\(effectiveUserLevel)(raw \(rawUserLevel), staff=\(isStaff), su=\(isSuperuser)) dvr=\(dvrAccess.rawValue) vod=\(canViewVod.rawValue) series=\(canViewSeries.rawValue) catchup=\(canUseCatchup.rawValue) switch=\(canSwitchStream.rawValue) snapshot=\(hasSnapshot ? "yes" : "NO") schema=\(schema)"
    }
}

// MARK: - Capability probe

/// The one place that reads `/api/accounts/users/me/` and writes the
/// capability snapshot onto a `ServerConnection`.
///
/// Every trigger funnels through here so the probe logic (admin fallback
/// probe, version, server-wide catch-up switch, failure handling) cannot
/// drift between call sites. A FAILED probe keeps the last good snapshot:
/// we never revoke on a network error.
@MainActor
enum DispatcharrCapabilityProbe {

    private static var inFlight: Set<UUID> = []

    /// Unified-logging channel for the probe. INFO level and always
    /// compiled in (unlike `debugLog`, whose console half is Debug only),
    /// so a Release / TestFlight build can be verified with
    /// `log stream --predicate 'category == "Permissions"'` or simply
    /// grepping for "[PERMS]".
    private static let permsLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aerio.app",
        category: "Permissions")

    /// One line per probe outcome, on both the unified log and the
    /// on-disk debug log.
    private static func logProbe(_ line: String) {
        permsLog.info("\(line, privacy: .public)")
        debugLog(line)
    }

    /// Reads users/me and applies the snapshot.
    ///
    /// Returns whether the probe REACHED the server, not whether anything
    /// changed: callers retry on an unreachable server, and retrying a
    /// successful probe that simply found nothing new is pure waste. A
    /// change additionally posts `.dispatcharrCapabilitiesDidChange`.
    @discardableResult
    static func refresh(_ server: ServerConnection, reason: String) async -> Bool {
        guard server.type == .dispatcharrAPI else { return false }
        guard !inFlight.contains(server.id) else { return false }
        inFlight.insert(server.id)
        defer { inFlight.remove(server.id) }

        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode,
                                 serverID: server.id,
                                 savedUsername: server.dispatcharrCredentialType == .usernamePassword
                                     ? server.username : nil)
        guard let user = try? await api.fetchCurrentUser() else {
            logProbe("[PERMS] probe FAILED server=\(server.name) reason=\(reason) "
                     + "detail=users/me-unavailable; keeping the last good snapshot "
                     + "(\(server.dispatcharrCapabilities.probeSummary))")
            return false
        }
        // SELF-HEAL: does the stored key actually authenticate as the
        // account whose username this playlist carries?
        //
        // users/me answers as whoever the key belongs to. A playlist that
        // was edited from one Dispatcharr user to another before the
        // credential-change path existed kept the previous account's
        // api_key, and that key was still valid server-side, so nothing
        // ever 401'd and nothing re-authenticated. The username the user
        // typed is the statement of intent; the username the server echoes
        // is the fact. When they disagree, the cached identity is stale by
        // definition and is repaired exactly like a credential edit, so a
        // broken playlist fixes itself on the next probe instead of
        // needing the user to re-save credentials.
        //
        // Only with a username to compare against: in pure API Key mode
        // there is nothing the user asserted about WHICH account, so a
        // mismatch cannot be detected and must not be guessed at.
        if await healIdentityMismatchIfNeeded(server, serverUsername: user.username) {
            // The repair re-probed with the new key; that pass owns the
            // snapshot, and re-applying this stale payload over it would
            // put the old account's answers straight back.
            return true
        }

        var level = user.effectiveUserLevel
        // A legacy superuser can still report a low custom level; the
        // IsAdmin-gated users LIST endpoint settles it.
        if level < 10, await api.probeAdminAccess() { level = 10 }
        let version = (try? await api.fetchVersion()) ?? nil
        // Only worth asking when the account may read settings at all.
        var systemCatchup: Bool? = nil
        if level >= 1 { systemCatchup = (try? await api.fetchSystemCatchupEnabled()) ?? nil }

        var changed = false
        if server.dispatcharrUserLevel != level {
            server.dispatcharrUserLevel = level
            changed = true
        }
        if !user.channelProfiles.isEmpty || !server.dispatcharrChannelProfileIDs.isEmpty {
            let joined = user.channelProfiles.map(String.init).joined(separator: ",")
            if server.dispatcharrChannelProfileIDs != joined {
                server.dispatcharrChannelProfileIDs = joined
                changed = true
            }
        }
        if server.applyDispatcharrPermissions(from: user,
                                              version: version,
                                              systemCatchupEnabled: systemCatchup) {
            changed = true
        }
        logProbe("[PERMS] probe OK \(server.dispatcharrCapabilities.probeSummary) "
                 + "changed=\(changed) server=\(server.name) reason=\(reason)")
        debugLog("[PERMS] detail \(server.name) (\(reason)): \(server.dispatcharrCapabilities.debugDescription)")
        if changed { NotificationCenter.default.post(name: .dispatcharrCapabilitiesDidChange, object: nil) }
        return true
    }

    /// Playlists whose identity mismatch has already been acted on in this
    /// process. One repair per playlist per app run: if the re-authenticated
    /// key STILL answers as somebody else, the server is doing something we
    /// do not model (a shared key, a proxy rewriting the account) and
    /// repairing again would spin -- log it and leave it alone.
    private static var identityRepaired: Set<UUID> = []

    /// Compare the username the server echoed against the one saved on the
    /// playlist and, on a genuine mismatch, re-authenticate.
    ///
    /// Returns true when a repair ran (the caller must then abandon the
    /// payload it was about to apply, since the repair took a fresh
    /// snapshot of its own).
    private static func healIdentityMismatchIfNeeded(_ server: ServerConnection,
                                                     serverUsername: String) async -> Bool {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let typed = norm(server.username)
        let actual = norm(serverUsername)
        guard !typed.isEmpty, !actual.isEmpty, typed != actual else { return false }

        guard !identityRepaired.contains(server.id) else {
            logProbe("[PERMS] stored key STILL authenticates as '\(serverUsername)' but the "
                     + "playlist is '\(server.username)' after a repair this run; leaving it "
                     + "alone (server=\(server.name))")
            return false
        }
        identityRepaired.insert(server.id)
        logProbe("[PERMS] stored key authenticates as '\(serverUsername)' but the playlist is "
                 + "'\(server.username)'; re-authenticating (server=\(server.name))")

        // `inFlight` still holds this server for the probe we are inside;
        // drop it so the repair's own probe is not swallowed as a duplicate.
        // The caller's `defer` removes it again, which is a no-op.
        inFlight.remove(server.id)
        await ServerCredentialChange.repairIdentityMismatch(server: server)
        return true
    }

    /// Servers already probed in THIS process. A cold launch must probe
    /// regardless of the TTL (a permission change on the server has to be
    /// picked up by force quitting and reopening), but it should cost
    /// exactly ONE probe per server per launch, so the launch pass marks
    /// each server here once it has run.
    private static var launchProbed: Set<UUID> = []

    /// Has the cold-launch pass already covered this server in this
    /// process? Callers use it to avoid re-forcing when the launch
    /// orchestrator re-fires (server key change) inside the same launch.
    static func needsLaunchProbe(_ server: ServerConnection) -> Bool {
        !launchProbed.contains(server.id)
    }

    /// Mark the cold-launch probe as done for this server (recorded even
    /// when the probe failed, since the launch pass owns its own retry
    /// with backoff and must not loop forever).
    static func noteLaunchProbed(_ server: ServerConnection) {
        launchProbed.insert(server.id)
    }

    /// Opportunistic refresh for screens that care (DVR, On Demand). Only
    /// probes when the snapshot is missing, schema-outdated, or older than
    /// `DispatcharrCapabilitySet.staleAfter` (about 6 hours).
    static func refreshIfStale(_ server: ServerConnection, reason: String) async {
        guard server.type == .dispatcharrAPI,
              server.dispatcharrCapabilities.isStale else { return }
        await refresh(server, reason: reason)
    }

    /// Re-probe after the server answered 403 on something we believed the
    /// account could do, then decide what to tell the user.
    ///
    /// - If the fresh snapshot agrees the account lacks `capability`, show
    ///   the specific permission message.
    /// - If the snapshot says it SHOULD be allowed, the refusal is very
    ///   likely a per-user `allowed_networks` policy rather than a level,
    ///   so say that instead of blaming permissions.
    @discardableResult
    static func handleForbidden(_ server: ServerConnection,
                                capability: DispatcharrCapability,
                                serverReason: String?) async -> String {
        await refresh(server, reason: "403 on \(capability.rawValue)")
        let caps = server.dispatcharrCapabilities
        let message: String
        if caps.state(of: capability) == .denied {
            message = capability.deniedMessage
        } else {
            var text = capability.networkRestrictionMessage
            if let serverReason, !serverReason.isEmpty {
                text += "\n\nThe server said: \(serverReason)"
            }
            message = text
        }
        DispatcharrPermissionNotice.shared.present(message)
        return message
    }

    /// A 200 on something we believed was denied: our snapshot was wrong
    /// (or the admin just granted access). Re-probe so the UI promotes the
    /// affordance instead of staying wrongly hidden.
    static func promoteIfUnexpectedlyAllowed(_ server: ServerConnection,
                                             capability: DispatcharrCapability) async {
        guard server.type == .dispatcharrAPI,
              server.dispatcharrCapabilities.state(of: capability) == .denied else { return }
        await refresh(server, reason: "200 on supposedly denied \(capability.rawValue)")
    }
}

/// Single, app-wide surface for "the server refused that, and here is
/// exactly why" messages raised from deep inside action helpers that have
/// no view of their own.
@MainActor
final class DispatcharrPermissionNotice: ObservableObject {
    static let shared = DispatcharrPermissionNotice()
    @Published var message: String? = nil
    var isPresented: Bool { message != nil }
    func present(_ text: String) { message = text }
    func dismiss() { message = nil }
}

extension Notification.Name {
    /// Posted whenever a capability snapshot changes, so views gating on
    /// capabilities can re-evaluate without polling.
    static let dispatcharrCapabilitiesDidChange = Notification.Name("dispatcharrCapabilitiesDidChange")
}

/// Presents `DispatcharrPermissionNotice` as an alert at the app root.
struct DispatcharrPermissionNoticeAlert: ViewModifier {
    @ObservedObject private var notice = DispatcharrPermissionNotice.shared

    func body(content: Content) -> some View {
        content.alert("Dispatcharr Permissions",
                      isPresented: Binding(get: { notice.message != nil },
                                           set: { if !$0 { notice.dismiss() } })) {
            Button("OK", role: .cancel) { notice.dismiss() }
        } message: {
            Text(notice.message ?? "")
        }
    }
}
