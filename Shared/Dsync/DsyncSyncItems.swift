//  DsyncSyncItems.swift
//  Aerio
//
//  Dispatcharr Sync, pure: the Android core/sync SyncCategory.kt and
//  SyncItems.kt halves the Dispatcharr Sync schema reads. The Apple app
//  already has SyncCategory, SyncScope, SyncItem, and SyncItemCatalog in
//  Shared/SyncFlags.swift, bound to UserDefaults keys; these mirror the
//  Android types (Dispatcharr schema names, section 4.9) under a Dsync
//  prefix so both can live in one module and the files diff by eye.
//
//  The seven lane rules (docs/DispatcharrSyncSchema.md 4.9) live here:
//  DsyncScope.effective (rule 1), lane (rules 2, 3, and 5), laneValues and
//  pickFromLanes (rules 2 to 5); rule 7 (round-trip) is
//  DsyncPayloads.encodeSettingsLanes, rule 6 is UI.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

/// Android SyncCategory: the Google Drive file categories the Dispatcharr
/// keys are gated by. On Apple these are the iCloud categories the cloud
/// side maps onto in later parts.
enum DsyncCategory: String, CaseIterable, Sendable {
    case playlists, watchProgress, reminders, favorites, watchlist, preferences, credentials
}

/// Android SyncScope. Raw values are the wire values ("all", "tv", ...),
/// the same as Apple's SyncScope raw values.
enum DsyncScope: String, CaseIterable, Sendable {
    case all, tv, mobile, off

    var title: String {
        switch self {
        case .all: return "All devices"
        case .tv: return "TVs only"
        case .mobile: return "Phones and tablets only"
        case .off: return "Off"
        }
    }

    /// Rule 1: the other class's lane reads as All devices.
    func effective(isTv: Bool) -> DsyncScope {
        switch self {
        case .tv: return isTv ? .tv : .all
        case .mobile: return isTv ? .all : .mobile
        default: return self
        }
    }

    /// The lane this device writes and reads for this scope, or nil (Off).
    func lane(isTv: Bool) -> String? {
        switch effective(isTv: isTv) {
        case .all: return Self.LANE_ALL
        case .tv: return Self.LANE_TV
        case .mobile: return Self.LANE_MOBILE
        case .off: return nil
        }
    }

    static let LANE_ALL = "v"
    static let LANE_TV = "tv"
    static let LANE_MOBILE = "mobile"
    static let LANES = [LANE_ALL, LANE_TV, LANE_MOBILE]

    static func fromWire(_ s: String?) -> DsyncScope? { s.flatMap(DsyncScope.init(rawValue:)) }

    /// The choices this device offers: its own class lane only.
    static func choices(isTv: Bool) -> [DsyncScope] { [.all, isTv ? .tv : .mobile, .off] }
}

/// One row in Sync Categories (Android SyncItem). [names] are Dispatcharr
/// schema names; [prefixes] cover families such as `categoryColor.`.
struct DsyncItem: Equatable, Sendable {
    let id: String
    let label: String
    var names: [String] = []
    var prefixes: [String] = []
    var isData: Bool = false
    var category: DsyncCategory? = nil
    var dsyncSuffix: String? = nil
    var driveOnly: Bool = false
    var dsyncOnly: Bool = false

    var scopeKey: String { "syncScope.\(id)" }
    var toggleKey: String { "syncItem.\(id)" }
    func covers(_ name: String) -> Bool { names.contains(name) || prefixes.contains { name.hasPrefix($0) } }
}

struct DsyncItemGroup: Sendable {
    let id: String
    let title: String
    let items: [DsyncItem]
    var isData: Bool { items.allSatisfy(\.isData) }
}

/// The six Player Info Card rows, as `playerInfoCard.<row>`.
let INFO_CARD_ROWS = ["channelLogo", "channelName", "programName", "programTime", "programSubtitle", "programDescription"]

enum DsyncItemCatalog {
    private static func S(_ id: String, _ label: String, _ names: [String] = [], prefixes: [String] = []) -> DsyncItem {
        DsyncItem(id: id, label: label, names: names, prefixes: prefixes)
    }

    private static func D(_ id: String, _ label: String, _ names: [String] = [], category: DsyncCategory? = nil,
                          dsyncSuffix: String? = nil, driveOnly: Bool = false, dsyncOnly: Bool = false) -> DsyncItem {
        DsyncItem(id: id, label: label, names: names, isData: true, category: category,
                  dsyncSuffix: dsyncSuffix, driveOnly: driveOnly, dsyncOnly: dsyncOnly)
    }

    static let groups: [DsyncItemGroup] = [
        DsyncItemGroup(id: "appearance", title: "Appearance", items: [
            S("selectedTheme", "Color Theme", ["selectedTheme", "customThemeHex"]),
            // True Black is a Mode choice, so it rides this item's scope
            // (SyncItemCatalog does the same with appearance.trueBlack).
            S("appearanceMode", "Light and Dark Mode", ["appearanceMode", "trueBlack"]),
            S("customAccent", "Custom Accent Color", ["useCustomAccent", "customAccentHex"]),
            S("textScale", "Text Size", ["textScale"]),
            S("subtextScale", "Subtext Size", ["subtextScale"]),
            S("textContrast", "Text Contrast", ["textContrast"]),
            S("timeFormat", "Time Format", ["timeFormat"]),
        ]),
        DsyncItemGroup(id: "general", title: "General", items: [
            S("defaultTab", "Default Tab", ["defaultTab"]),
            S("skipLoadingScreen", "Skip Loading Screen", ["skipLoadingScreen"]),
            S("resumeLastChannel", "Resume Last Channel", ["autoResumeLastChannel"]),
        ]),
        DsyncItemGroup(id: "liveTV", title: "Live TV", items: [
            S("defaultLiveTVView", "Default View", ["defaultLiveTvView"]),
            S("guideLayout", "Guide Layout", ["guideLayout"]),
            S("groupSelection", "Group Selection", ["phoneGroupSelector", "guideGroupSelector", "guideSidebarLayout"]),
            S("edgeSwipeSidebar", "Swipe from Left Edge Opens Sidebar", ["liveTvEdgeSwipeOpensSidebar"]),
            S("showChannelLogos", "Show Channel Logos", ["channelListShowLogos"]),
            S("showChannelNumbers", "Show Channel Numbers", ["channelListShowNumbers"]),
            S("showChannelNames", "Show Channel Names", ["channelListShowNames"]),
            S("showProgramSubtitles", "Show Program Subtitles", ["channelListShowProgramSubtitles"]),
            S("logoSize", "Logo Size", ["channelLogoSize"]),
            S("programBadges", "Show Program Badges", ["showEpgBadgesTv", "showEpgBadgesMobile", "hiddenEpgBadges"]),
            S("programInfoButton", "Program Info Button", ["guideProgramInfoButton", "programInfoButtonGuide", "programInfoButtonList"]),
            S("roundedGuideLogos", "Rounded Guide Logos", ["logoCornersGuide"]),
            S("roundedProgramCells", "Rounded Program Cells", ["logoCornersGuideCells"]),
            S("roundedListLogos", "Rounded List Logos and Artwork", ["logoCornersList"]),
            S("liveTVDisplayScale", "Display Scale", ["displayScaleLiveTv", "displayScaleGuide"]),
            S("categoryColors", "Color Programs by Category", ["enableCategoryColors", "customCategories"],
              prefixes: ["categoryColor.", "categoryBucketEnabled."]),
        ]),
        DsyncItemGroup(id: "player", title: "Player", items: [
            S("infoCard", "Pop Up Info Card on Channel Change",
              ["playerInfoCard.showOnChannelChange"] + INFO_CARD_ROWS.map { "playerInfoCard.\($0)" }),
            S("liveRewind", "Pause & Rewind Live TV", [
                "liveRewindEnabled", "liveRewindDepthMinutes", "liveRewindKeepRecent", "liveRewindKeepCount",
                "liveRewindRetentionHours", "liveRewindBudgetGb",
            ]),
            S("skipIntervals", "Skip Back and Skip Forward", ["skipBack", "skipForward"]),
            S("skipWithoutControls", "Skip Without Controls", ["skipWithoutControls"]),
            S("autoRecover", "Auto-Recover Frozen Streams", ["autoRecoverFrozenStreams"]),
            S("channelFlip", "Up / Down Channel Change", ["appleTVChannelFlip"]),
            S("edgeBrightness", "Edge Slide for Brightness", ["edgeBrightnessGesture", "brightnessEdge"]),
            S("edgeVolume", "Edge Slide for Volume", ["edgeVolumeGesture"]),
            S("multiviewAudioFocus", "Audio Focus Indicator", ["multiview.audioFocusStyle"]),
            S("multiviewPadding", "Padding Between Tiles", ["multiview.tilePadding"]),
            S("multiviewCorners", "Tile Corners", ["multiview.tileCornersRounded"]),
            S("multiviewLogos", "Multiview Channel Logos", ["multiview.showLogos", "multiview.logoPosition", "multiview.logoSize"]),
            S("multiviewSubtitles", "Multiview Subtitles", ["multiview.pickerShowSubtitles"]),
            S("multiviewDescriptions", "Multiview Descriptions", ["multiview.pickerShowDescriptions"]),
        ]),
        DsyncItemGroup(id: "vod", title: "Movies & TV Shows", items: [
            S("refreshLibrary", "Refresh Library", ["vodLibraryRefreshHours"]),
            S("tmdb", "Use TMDB for Movies and TV Shows", ["tmdbPostersEnabled"]),
            S("vodDisplayScale", "Display Scale", ["displayScaleMovies"]),
            S("vodSortOrder", "Sort Order", ["moviesSortOrder", "seriesSortOrder"]),
        ]),
        DsyncItemGroup(id: "dvr", title: "DVR", items: [
            S("preRoll", "Start Early (Pre-Roll)", ["dvrPreRollMins"]),
            S("postRoll", "End Late (Post-Roll)", ["dvrPostRollMins"]),
            S("defaultDestination", "Default Destination", ["dvrDefaultDestination"]),
            S("dvrSortOrder", "Sort Order", ["dvrSortOrder"]),
        ]),
        DsyncItemGroup(id: "remote", title: "Remote Control", items: [
            S("remoteHints", "Show Remote Hints", ["showRemoteHints"]),
            S("exitFocus", "Exit Prompt Starts on Exit", ["exitDialogFocusExit"]),
            S("playChannelsIn", "Play Channels In", ["guideTuneInMini"]),
            D("remoteMap", "Remote Button Map", dsyncSuffix: "remoteMap"),
        ]),
        DsyncItemGroup(id: "data", title: "Your Data", items: [
            D("servers", "Playlists & Servers", category: .playlists, driveOnly: true),
            D("credentials", "Credentials", category: .credentials, driveOnly: true),
            D("favorites", "Favorites", category: .favorites, dsyncSuffix: "favorites"),
            D("recents", "Recently Watched", dsyncSuffix: "recents"),
            D("collections", "Collections", dsyncSuffix: "collections"),
            D("watchProgress", "Watch Progress", category: .watchProgress, dsyncSuffix: "progress"),
            D("reminders", "Reminders", category: .reminders, dsyncSuffix: "reminders"),
            D("watchlist", "Watchlist", category: .watchlist, dsyncSuffix: "watchlist"),
            D("hiddenTitles", "Hidden Titles", dsyncSuffix: "hiddenTitles"),
            D("hiddenGroups", "Hidden Groups", dsyncSuffix: "hiddenGroups"),
            // The per-playlist group choices ride `settings` but follow this toggle (Apple parity).
            D("groupOrder", "Group Order", ["defaultGroup", "lastGroup", "recentGroupVisible"], dsyncSuffix: "groupOrder"),
            D("profiles", "Profiles", dsyncSuffix: "profiles", dsyncOnly: true),
            D("radioDefault", "Radio Mode by Default", dsyncSuffix: "radioDefault"),
        ]),
    ]

    static var allItems: [DsyncItem] { groups.flatMap(\.items) }

    static func item(_ id: String) -> DsyncItem? { allItems.first { $0.id == id } }

    /// The item that carries a settings schema name, or nil (not ours).
    static func itemForName(_ name: String) -> DsyncItem? { allItems.first { $0.covers(name) } }

    /// The data item for a Dispatcharr key suffix.
    static func itemForDsync(_ suffix: String) -> DsyncItem? { allItems.first { $0.dsyncSuffix == suffix } }
}

/// Splits per-lane values for a push: every name goes to the lane its
/// item's scope picks on this device; Off (or the other class's lane) is
/// not written. Lane order follows first appearance, as on Android.
func laneValues<V>(_ values: [(String, V)], scopeOf: (String) -> DsyncScope, isTv: Bool) -> [String: [String: V]] {
    var out: [String: [String: V]] = [:]
    for (name, v) in values {
        guard let lane = scopeOf(name).lane(isTv: isTv) else { continue }
        out[lane, default: [:]][name] = v
    }
    return out
}

/// Picks pulled values: each name is read from the lane its scope picks on
/// this device and nowhere else (rule 4: no fallback across lanes).
func pickFromLanes<V>(_ lanes: [String: [String: V]], names: [String], scopeOf: (String) -> DsyncScope, isTv: Bool) -> [String: V] {
    var all = Set(names)
    for m in lanes.values { all.formUnion(m.keys) }
    var out: [String: V] = [:]
    for name in all {
        guard let lane = scopeOf(name).lane(isTv: isTv) else { continue }
        if let v = lanes[lane]?[name] { out[name] = v }
    }
    return out
}
