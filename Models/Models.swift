import SwiftData
import SwiftUI

// MARK: - Server Type Enum
enum ServerType: String, Codable, CaseIterable {
    case dispatcharrAPI = "dispatcharr_api"
    case xtreamCodes  = "xtream_codes"
    case m3uPlaylist  = "m3u_playlist"

    var displayName: String {
        switch self {
        case .m3uPlaylist: return "M3U + EPG"
        case .xtreamCodes: return "Xtream Codes"
        case .dispatcharrAPI: return "Dispatcharr API"
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
        case .dispatcharrAPI: return "Dispatcharr native API — connect with a personal API key"
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

    /// The effective password: reads from local Keychain first, then iCloud
    /// Keychain (synchronizable), then falls back to the SwiftData field.
    var effectivePassword: String {
        let key = "password_\(id.uuidString)"
        return KeychainHelper.load(key: key)
            ?? KeychainHelper.load(key: key, synchronizable: true)
            ?? password
    }

    /// The effective API key: reads from local Keychain first, then iCloud
    /// Keychain (synchronizable), then falls back to the SwiftData field.
    var effectiveApiKey: String {
        let key = "apiKey_\(id.uuidString)"
        return KeychainHelper.load(key: key)
            ?? KeychainHelper.load(key: key, synchronizable: true)
            ?? apiKey
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

    /// Auth headers for API requests. Dispatcharr servers include ApiKey + X-API-Key
    /// plus the User-Agent so it shows up in the admin Stats panel; all other types
    /// just include Accept. Centralised here to avoid duplication.
    var authHeaders: [String: String] {
        switch type {
        case .dispatcharrAPI:
            let key = effectiveApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["Authorization": "ApiKey \(key)", "X-API-Key": key, "Accept": "*/*",
                    "User-Agent": effectiveUserAgent]
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

    /// The matched home SSID currently in use, if on LAN.
    var activeHomeSSID: String? {
        #if os(tvOS)
        // tvOS can't detect SSIDs — return a synthetic label if LAN is detected
        return isOnLANNetwork ? "Local Network" : nil
        #else
        let current = UserDefaults.standard.string(forKey: "cachedCurrentSSID") ?? ""
        return homeSSIDs.first(where: { $0 == current })
        #endif
    }

    var normalizedLocalURL: String {
        var url = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "http://" + url }
        return url
    }

    /// Whether this device is currently on the home/LAN network.
    /// iOS: checks cached SSID against configured home SSIDs.
    /// tvOS: checks a reachability flag set at startup by probing the local URL.
    private var isOnLANNetwork: Bool {
        #if os(tvOS)
        return UserDefaults.standard.bool(forKey: "tvosLANDetected")
        #else
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

    init(channelID: String, title: String, description: String = "",
         startTime: Date, endTime: Date, category: String = "", posterURL: String = "",
         serverID: String = "", fetchedAt: Date = Date()) {
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
