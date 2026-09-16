import Foundation

/// Settings > App Behaviors > Player Info Card (Logan 2026-09-15).
/// Six synced booleans that decide which rows the in-player program
/// info card draws while the player chrome is showing. They affect
/// ONLY that card: the guide, channel list, mini player, Now Playing /
/// lock screen metadata and the cast UI all keep rendering everything
/// they always did.
///
/// Every key defaults to `true`, and nothing is written to
/// UserDefaults until the user flips a row, so an absent key (a fresh
/// install, or a device that has never seen this build) reads as ON.
/// The keys ride `SyncManager.syncBoolKeys`, matching the names
/// Android syncs.
///
/// Android twin: `PlayerInfoCardSettings` in core/ui/.
enum PlayerInfoCardSettings {
    static let channelLogoKey       = "playerInfoCardChannelLogo"
    static let channelNameKey       = "playerInfoCardChannelName"
    static let programNameKey       = "playerInfoCardProgramName"
    static let programTimeKey       = "playerInfoCardProgramTime"
    static let programSubtitleKey   = "playerInfoCardProgramSubtitle"
    static let programDescriptionKey = "playerInfoCardProgramDescription"

    /// Every key, in Settings display order.
    static let allKeys = [
        channelLogoKey, channelNameKey, programNameKey,
        programTimeKey, programSubtitleKey, programDescriptionKey
    ]

    /// Row titles, keyed by defaults key. Exact strings the user asked for.
    static func title(_ key: String) -> String {
        switch key {
        case channelLogoKey:        return "Channel Logo"
        case channelNameKey:        return "Channel Name"
        case programNameKey:        return "Program Name"
        case programTimeKey:        return "Program Time"
        case programSubtitleKey:    return "Program Subtitle"
        case programDescriptionKey: return "Program Description"
        default:                    return key
        }
    }

    /// An unset key is ON. Only an explicit `false` hides a row.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static var showChannelLogo: Bool       { isOn(channelLogoKey) }
    static var showChannelName: Bool       { isOn(channelNameKey) }
    static var showProgramName: Bool       { isOn(programNameKey) }
    static var showProgramTime: Bool       { isOn(programTimeKey) }
    static var showProgramSubtitle: Bool   { isOn(programSubtitleKey) }
    static var showProgramDescription: Bool { isOn(programDescriptionKey) }
}

// MARK: - Card data helpers

extension PlayerInfoCardSettings {
    /// Episode title for a channel's live program. `ChannelDisplayItem`
    /// carries a description but no episode title, so this always comes
    /// from the bulk-EPG store. A subtitle that merely restates the
    /// program title or its synopsis is dropped, matching the guide and
    /// the Program Info sheet.
    @MainActor
    static func liveEpisodeTitle(forChannelID id: String) -> String? {
        guard let p = GuideStore.shared.liveProgram(for: id) else { return nil }
        let sub = (p.subTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sub.isEmpty,
              !EPGText.subtitleIsRedundant(sub, title: p.title, description: p.description)
        else { return nil }
        return sub
    }

    /// Synopsis for a channel's live program: the item's own
    /// current-program description when it has one (Xtream + Dispatcharr
    /// current-programs cache), else the bulk-EPG store's.
    @MainActor
    static func liveSynopsis(forChannelID id: String, itemDescription: String?) -> String? {
        let own = (itemDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        let store = (GuideStore.shared.liveProgram(for: id)?.description ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return store.isEmpty ? nil : store
    }
}
