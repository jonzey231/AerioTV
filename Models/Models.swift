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
        case .m3uPlaylist: return .accentPrimary
        case .xtreamCodes: return .xtreamColor
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

    init(
        name: String,
        type: ServerType,
        baseURL: String,
        username: String = "",
        password: String = "",
        apiKey: String = "",
        epgURL: String = "",
        isActive: Bool = true
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
        self.sortOrder = 0
        self.createdAt = Date()
        self.isVerified = false
    }

    var supportsVOD: Bool { type.supportsVOD }

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
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

    init(channelID: String, title: String, description: String = "",
         startTime: Date, endTime: Date, category: String = "", posterURL: String = "") {
        self.id = UUID()
        self.channelID = channelID
        self.title = title
        self.programDescription = description
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
        self.posterURL = posterURL
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
