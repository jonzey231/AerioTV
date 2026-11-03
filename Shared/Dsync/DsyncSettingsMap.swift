//  DsyncSettingsMap.swift
//  Aerio
//
//  Dispatcharr Sync, pure: the `settings` schema names (section 4.9, the
//  DsyncItemCatalog names) mapped to the Apple UserDefaults keys the
//  SyncItemCatalog items carry (Shared/SyncFlags.swift), item by item.
//  Only names listed here are written or applied on Apple; every other
//  name in a lane round-trips untouched (rule 7).
//
//  A name is listed only when the Apple key's stored type and values were
//  read from the code that owns it. Value spellings that differ are
//  converted (themes and tabs). Names with no Apple setting, or whose
//  Apple values were not verified, are left out on purpose:
//    guideGroupSelector, phoneGroupSelector, guideSidebarLayout,
//    guideProgramInfoButton, brightnessEdge, defaultLiveTvView,
//    channelLogoSize, hiddenEpgBadges, customCategories,
//    multiview.audioFocusStyle, multiview.logoPosition, multiview.logoSize,
//    liveRewindRetentionHours, liveRewindBudgetGb, exitDialogFocusExit,
//    moviesSortOrder, seriesSortOrder, dvrDefaultDestination, dvrSortOrder,
//    lastGroup, recentGroupVisible.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

enum DsyncSettingsMap {
    enum Kind: Sendable {
        case bool, int, double, string
        /// Apple AppTheme raw values are lowercase ("aerio"); the schema spells "Aerio".
        case theme
        /// Apple AppTab raw values ("livetv"); the schema spells "LiveTV".
        case tab
        /// Live TV group token. Provider group names and "collection:<id>"
        /// pass through; the synthetic groups are spelled the Android way on
        /// the wire ("__favorites__", "__recent__", "All") and the Apple way
        /// locally ("favorites", "recentlyWatched", "" for All).
        case groupToken
        /// Apple stores the category hex uppercased without "#".
        case hex
    }

    struct Entry: Sendable {
        let name: String
        let appleKey: String
        let kind: Kind
    }

    static let ENTRIES: [Entry] = [
        // Appearance
        Entry(name: "selectedTheme", appleKey: "selectedTheme", kind: .theme),
        Entry(name: "appearanceMode", appleKey: "appearanceMode", kind: .string),
        Entry(name: "trueBlack", appleKey: "appearance.trueBlack", kind: .bool),
        Entry(name: "useCustomAccent", appleKey: "useCustomAccent", kind: .bool),
        Entry(name: "customAccentHex", appleKey: "customAccentHex", kind: .hex),
        Entry(name: "textScale", appleKey: "textScale", kind: .double),
        Entry(name: "subtextScale", appleKey: "subtextScale", kind: .double),
        Entry(name: "textContrast", appleKey: "textContrast", kind: .double),
        Entry(name: "timeFormat", appleKey: "timeFormat", kind: .string),
        // General
        Entry(name: "defaultTab", appleKey: "defaultTab", kind: .tab),
        Entry(name: "skipLoadingScreen", appleKey: "appBehaviorsSkipLoadingScreen", kind: .bool),
        Entry(name: "autoResumeLastChannel", appleKey: "appBehaviorsAutoResumeLastChannel", kind: .bool),
        // Live TV
        Entry(name: "guideLayout", appleKey: "liveTVLayout", kind: .string),
        Entry(name: "liveTvEdgeSwipeOpensSidebar", appleKey: "liveTVEdgeSwipeOpensSidebar", kind: .bool),
        Entry(name: "channelListShowLogos", appleKey: "ui.showChannelLogos", kind: .bool),
        Entry(name: "channelListShowNumbers", appleKey: "ui.showChannelNumbers", kind: .bool),
        Entry(name: "channelListShowNames", appleKey: "ui.showChannelNames", kind: .bool),
        Entry(name: "channelListShowProgramSubtitles", appleKey: "ui.showProgramSubtitles", kind: .bool),
        Entry(name: "showEpgBadgesTv", appleKey: "showEpgBadges.tv", kind: .bool),
        Entry(name: "showEpgBadgesMobile", appleKey: "showEpgBadges.mobile", kind: .bool),
        Entry(name: "programInfoButtonGuide", appleKey: "guideProgramInfoButtonGuideView", kind: .bool),
        Entry(name: "programInfoButtonList", appleKey: "guideProgramInfoButtonListView", kind: .bool),
        Entry(name: "logoCornersGuide", appleKey: "ui.roundedLogoCornersGuide", kind: .bool),
        Entry(name: "logoCornersGuideCells", appleKey: "guide.roundedProgramCells", kind: .bool),
        Entry(name: "logoCornersList", appleKey: "ui.roundedLogoCornersList", kind: .bool),
        Entry(name: "displayScaleLiveTv", appleKey: "listScale", kind: .double),
        Entry(name: "displayScaleGuide", appleKey: "guideScale", kind: .double),
        Entry(name: "enableCategoryColors", appleKey: "enableCategoryColors", kind: .bool),
        // Player
        Entry(name: "playerInfoCard.showOnChannelChange", appleKey: "playerShowChannelInfoCard", kind: .bool),
        Entry(name: "playerInfoCard.channelLogo", appleKey: "playerInfoCardChannelLogo", kind: .bool),
        Entry(name: "playerInfoCard.channelName", appleKey: "playerInfoCardChannelName", kind: .bool),
        Entry(name: "playerInfoCard.programName", appleKey: "playerInfoCardProgramName", kind: .bool),
        Entry(name: "playerInfoCard.programTime", appleKey: "playerInfoCardProgramTime", kind: .bool),
        Entry(name: "playerInfoCard.programSubtitle", appleKey: "playerInfoCardProgramSubtitle", kind: .bool),
        Entry(name: "playerInfoCard.programDescription", appleKey: "playerInfoCardProgramDescription", kind: .bool),
        Entry(name: "liveRewindEnabled", appleKey: "liveRewindEnabled", kind: .bool),
        Entry(name: "liveRewindDepthMinutes", appleKey: "liveRewindDepthMinutes", kind: .int),
        Entry(name: "liveRewindKeepRecent", appleKey: "liveRewindRetainChannels", kind: .bool),
        Entry(name: "liveRewindKeepCount", appleKey: "liveRewindRetainCount", kind: .int),
        Entry(name: "skipBack", appleKey: "skipBackSeconds", kind: .int),
        Entry(name: "skipForward", appleKey: "skipForwardSeconds", kind: .int),
        Entry(name: "skipWithoutControls", appleKey: "player.skipWithoutControls", kind: .bool),
        Entry(name: "autoRecoverFrozenStreams", appleKey: "appBehaviorsAutoRecoverFrozenStreams", kind: .bool),
        Entry(name: "appleTVChannelFlip", appleKey: "appBehaviorsAppleTVChannelFlip", kind: .bool),
        Entry(name: "edgeBrightnessGesture", appleKey: "appBehaviorsEdgeBrightnessGesture", kind: .bool),
        Entry(name: "edgeVolumeGesture", appleKey: "appBehaviorsEdgeVolumeGesture", kind: .bool),
        Entry(name: "multiview.tilePadding", appleKey: "multiviewTilePadding", kind: .bool),
        Entry(name: "multiview.tileCornersRounded", appleKey: "multiviewTileCornersRounded", kind: .bool),
        Entry(name: "multiview.showLogos", appleKey: "multiview.showLogos", kind: .bool),
        Entry(name: "multiview.pickerShowSubtitles", appleKey: "multiviewPickerShowSubtitles", kind: .bool),
        Entry(name: "multiview.pickerShowDescriptions", appleKey: "multiviewPickerShowDescriptions", kind: .bool),
        // Movies & TV Shows
        Entry(name: "vodLibraryRefreshHours", appleKey: "vodLibraryRefreshHours", kind: .int),
        Entry(name: "tmdbPostersEnabled", appleKey: "programPostersTMDBEnabled", kind: .bool),
        Entry(name: "displayScaleMovies", appleKey: "uiScale", kind: .double),
        // DVR
        Entry(name: "dvrPreRollMins", appleKey: "dvrDefaultPreRollMins", kind: .int),
        Entry(name: "dvrPostRollMins", appleKey: "dvrDefaultPostRollMins", kind: .int),
        // Remote Control
        Entry(name: "showRemoteHints", appleKey: "showRemoteHints", kind: .bool),
        Entry(name: "guideTuneInMini", appleKey: "guideTuneInMini.tv", kind: .bool),
        // Group Order item (rides `settings`)
        Entry(name: "defaultGroup", appleKey: "defaultChannelGroup", kind: .groupToken),
    ]

    private static let byName: [String: Entry] = Dictionary(ENTRIES.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    /// Prefix families carried under the same name on both platforms.
    static let PREFIXES: [(String, Kind)] = [
        (DsyncSettingsValidator.COLOR_PREFIX, .hex),
        (DsyncSettingsValidator.BUCKET_PREFIX, .bool),
    ]

    /// The Apple key and kind for a schema name, or nil (not carried on Apple).
    static func entry(_ name: String) -> Entry? {
        if let e = byName[name] { return e }
        for (p, k) in PREFIXES where name.hasPrefix(p) && DsyncSettingsValidator.isOwned(name) {
            return Entry(name: name, appleKey: name, kind: k)
        }
        return nil
    }

    static let THEMES = ["Aerio", "Midnight", "Sunset", "Forest", "Lavender", "Monochrome", "Light"]
    static let TABS: [(String, String)] = [
        ("LiveTV", "livetv"), ("DVR", "dvr"), ("Movies", "movies"), ("TVShows", "tvshows"), ("Settings", "settings"),
    ]

    /// A validated schema value as the Apple value to store, or nil (leave local unchanged).
    static func toApple(_ e: Entry, _ v: DsyncJSON) -> Any? {
        switch e.kind {
        case .bool: return v.asBool
        case .int: return v.asInt
        case .double: return v.asDouble
        case .string: return v.asStr
        case .theme: return v.asStr.flatMap { s in THEMES.contains(s) ? s.lowercased() : nil }
        case .tab:
            guard let s = v.asStr else { return nil }
            if s.isEmpty { return nil }
            return TABS.first { $0.0 == s }?.1
        case .groupToken:
            guard let s = v.asStr else { return nil }
            return GROUP_TOKENS.first { $0.wire == s }?.apple ?? s
        case .hex:
            // "" (preset accent) has no Apple spelling: leave local unchanged.
            guard let s = v.asStr, !s.isEmpty else { return nil }
            return (s.hasPrefix("#") ? String(s.dropFirst()) : s).uppercased()
        }
    }

    /// The Apple stored value as the schema value, or nil (nothing stored, or a value the schema has no spelling for).
    static func fromApple(_ e: Entry, _ raw: Any?) -> DsyncJSON? {
        guard let raw else { return nil }
        switch e.kind {
        case .bool:
            if let b = raw as? Bool { return .bool(b) }
            if let n = raw as? NSNumber { return .bool(n.boolValue) }
            return nil
        case .int:
            if let i = raw as? Int { return .int(i) }
            if let n = raw as? NSNumber { return .int(n.intValue) }
            return nil
        case .double:
            if let d = raw as? Double { return .double(d) }
            if let n = raw as? NSNumber { return .double(n.doubleValue) }
            return nil
        case .string:
            return (raw as? String).map { .string($0) }
        case .theme:
            guard let s = raw as? String else { return nil }
            return THEMES.first { $0.lowercased() == s.lowercased() }.map { .string($0) }
        case .tab:
            guard let s = raw as? String else { return nil }
            return TABS.first { $0.1 == s }.map { .string($0.0) }
        case .hex:
            // Only a complete RRGGBB goes out; a partial value would be
            // rejected by every receiver's validator anyway.
            guard let s = raw as? String else { return nil }
            let body = s.hasPrefix("#") ? String(s.dropFirst()) : s
            guard body.count == 6, body.allSatisfy(\.isHexDigit) else { return nil }
            return .string(s)
        case .groupToken:
            guard let s = raw as? String else { return nil }
            if s.isEmpty { return .string("") }
            return .string(GROUP_TOKENS.first { $0.apple == s }?.wire ?? s)
        }
    }

    /// Synthetic Live TV group tokens: (wire spelling, Apple spelling).
    /// Wire "All" and Apple "" both mean All Channels; Apple writes "" back.
    static let GROUP_TOKENS: [(wire: String, apple: String)] = [
        ("__favorites__", "favorites"),
        ("__recent__", "recentlyWatched"),
        ("All", ""),
    ]
}
