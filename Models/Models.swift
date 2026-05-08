import SwiftData
import SwiftUI

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
    /// Local LAN URL used when connected to a home WiFi SSID (e.g. http://192.168.1.10:9191)
    var localURL: String = ""
    /// Local EPG/XMLTV URL used when connected to a home WiFi SSID (M3U only).
    var localEPGURL: String = ""
    /// Comma-separated list of home WiFi SSIDs (up to 5).
    /// When connected to any of them, localURL is used instead of baseURL.
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

    /// Global home WiFi SSIDs configured in Settings → Network.
    /// Shared across all servers — stored in UserDefaults under "globalHomeSSIDs".
    var homeSSIDs: [String] {
        (UserDefaults.standard.string(forKey: "globalHomeSSIDs") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Returns localURL (normalized) when connected to any configured home WiFi SSID
    /// (iOS) or when LAN reachability was detected at startup (tvOS).
    var effectiveBaseURL: String {
        guard !localURL.isEmpty else { return normalizedBaseURL }
        guard isOnLANNetwork else { return normalizedBaseURL }
        return normalizedLocalURL
    }

    /// Returns localEPGURL when on a home network, otherwise returns epgURL.
    var effectiveEPGURL: String {
        guard !localEPGURL.isEmpty else { return epgURL }
        guard isOnLANNetwork else { return epgURL }
        return localEPGURL
    }

    /// Human-readable label for "what put us on the LAN" — used by
    /// Settings → Server Detail to explain LAN routing. Returns the
    /// matched SSID when SSID detection succeeded, falls back to a
    /// synthetic "Local Network" string when the LAN was confirmed
    /// only via the URL probe (Ethernet, Mac Catalyst with broken
    /// NEHotspotNetwork, etc.), and `nil` when neither signal fired.
    var activeHomeSSID: String? {
        #if os(tvOS)
        // tvOS has no SSID API — probe is the only signal.
        return isOnLANNetwork ? "Local Network" : nil
        #else
        // Prefer the matched-SSID label so users on iPhone / iPad with
        // working NEHotspotNetwork see their network name.
        let current = UserDefaults.standard.string(forKey: "cachedCurrentSSID") ?? ""
        if let matched = homeSSIDs.first(where: { $0 == current }) {
            return matched
        }
        // No SSID match (unknown SSID, no SSID detected, etc.) —
        // surface the probe-based signal as a synthetic label so the
        // UI doesn't say "Not on a home network" when LAN routing is
        // actively in use.
        if UserDefaults.standard.bool(forKey: "tvosLANDetected") {
            return "Local Network"
        }
        return nil
        #endif
    }

    var normalizedLocalURL: String {
        var url = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "http://" + url }
        return url
    }

    /// Whether this device is currently on the home/LAN network.
    /// True when the active network path looks like a LAN with this
    /// server reachable on its local URL.
    ///
    /// Two independent signals are OR'd together so users on any
    /// network medium get correct routing:
    ///
    ///   1. **SSID match** (iOS / iPadOS / Mac Catalyst only). The
    ///      cached SSID — populated by `NetworkMonitor.fetchSSID()` —
    ///      is checked against this server's configured `homeSSIDs`.
    ///      Fast path that doesn't need a network round-trip and
    ///      works pre-`localURL`-probe. Returns false on Ethernet
    ///      (no SSID), on Mac Catalyst with broken NEHotspotNetwork,
    ///      or before Location auth is granted.
    ///
    ///   2. **Probe result** (all platforms via `TVLANProbe`). The
    ///      `localURL` was HEAD-probed at app launch / scenePhase
    ///      .active / network-change and responded successfully.
    ///      Network-medium-agnostic, so this catches Ethernet,
    ///      VPN-bypass, and any other case where the local server
    ///      is reachable but SSID resolution failed.
    ///
    /// Persistence keys are `"cachedCurrentSSID"` (NetworkMonitor)
    /// and `"tvosLANDetected"` (TVLANProbe — legacy name kept to
    /// avoid breaking existing installs that already have a
    /// last-known LAN flag persisted under it).
    private var isOnLANNetwork: Bool {
        // Probe-based signal — works on every platform, every
        // network medium. Set by `TVLANProbe` (v1.6.8 cross-
        // platform; class name is legacy from when it was
        // tvOS-only).
        let probeDetected = UserDefaults.standard.bool(forKey: "tvosLANDetected")
        if probeDetected { return true }

        #if os(tvOS)
        return false
        #else
        // SSID fast-path. Skips the lookup if the user hasn't
        // configured any home SSIDs (would always return false).
        let ssids = homeSSIDs
        guard !ssids.isEmpty else { return false }
        let currentSSID = UserDefaults.standard.string(forKey: "cachedCurrentSSID") ?? ""
        return !currentSSID.isEmpty && ssids.contains(currentSSID)
        #endif
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

    init(channelID: String, title: String, description: String = "",
         startTime: Date, endTime: Date, category: String = "", posterURL: String = "",
         serverID: String = "", fetchedAt: Date = Date(),
         programID: Int? = nil) {
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
    }

    var isLive: Bool {
        let now = Date()
        return now >= startTime && now <= endTime
    }

    var progressFraction: Double {
        let now = Date()
        guard now >= startTime else { return 0 }
        let total = endTime.timeIntervalSince(startTime)
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
}
