import SwiftData
import Foundation

// MARK: - M3U Playlist Model
@Model
final class M3UPlaylist {
    var id: UUID
    var name: String
    var sourceType: PlaylistSourceType
    var urlString: String       // if URL-based
    var localFilename: String   // if file-based (stored in app documents)
    var channelCount: Int
    var lastRefreshed: Date?
    var createdAt: Date
    var isActive: Bool

    init(name: String, sourceType: PlaylistSourceType, urlString: String = "", localFilename: String = "") {
        self.id = UUID()
        self.name = name
        self.sourceType = sourceType
        self.urlString = urlString
        self.localFilename = localFilename
        self.channelCount = 0
        self.createdAt = Date()
        self.isActive = true
    }

    var displayURL: String {
        sourceType == .url ? urlString : "Local file: \(localFilename)"
    }
}

enum PlaylistSourceType: String, Codable {
    case url  = "url"
    case file = "file"
}

// MARK: - EPG Source Model
@Model
final class EPGSource {
    var id: UUID
    var name: String
    var sourceType: PlaylistSourceType
    var urlString: String
    var localFilename: String
    var programCount: Int
    var lastRefreshed: Date?
    var createdAt: Date
    var isActive: Bool

    init(name: String, sourceType: PlaylistSourceType, urlString: String = "", localFilename: String = "") {
        self.id = UUID()
        self.name = name
        self.sourceType = sourceType
        self.urlString = urlString
        self.localFilename = localFilename
        self.programCount = 0
        self.createdAt = Date()
        self.isActive = true
    }
}
