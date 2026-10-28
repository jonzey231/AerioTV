//  SyncFlags.swift
//  Aerio
//
//  v1.6.17, granular per-data-type iCloud sync controls.
//
//  Background: prior to v1.6.17 the iCloud Sync section in Settings was
//  one master toggle that pushed/pulled every data type SyncManager
//  knows about. Users wanted finer control, e.g. "sync my servers
//  across devices but keep my watch progress local-only." This file
//  defines the data-type matrix that the new "Sync Categories"
//  Settings sub-section binds to.
//
//  Storage: per-category state lives in `UserDefaults` under
//  "syncEnabled.<rawValue>". We default missing keys to `true` so
//  existing v1.6.16 users see no behavioral change on upgrade, every
//  category is on until they actively turn one off.
//
//  Round-trip: the toggle prefs themselves ride the existing prefs
//  sync lane (see `SyncManager.syncBoolKeys`) so a flip on one device
//  propagates. There's a bootstrapping subtlety in
//  `SyncManager.doApplyPreferences`, see the inline note there.

import Foundation
import Combine

/// User-facing iCloud sync category. One row per case in the
/// "Sync Categories" Settings detail view. Display order in the UI
/// follows declaration order.
enum SyncCategory: String, CaseIterable, Identifiable {
    case servers
    case watchProgress
    case reminders
    case preferences
    case remoteControl
    case radioModeDefault
    case credentials

    var id: String { rawValue }

    /// Title shown in the toggle row.
    var displayName: String {
        switch self {
        case .servers:       return "Playlists & Servers"
        case .watchProgress: return "VOD Watch Progress"
        case .reminders:     return "Reminders"
        case .preferences:   return "App Preferences"
        case .remoteControl: return "Remote Button Map"
        case .radioModeDefault: return "Radio Mode by Default"
        case .credentials:   return "Credentials"
        }
    }

    /// One-line subtitle / footer hint shown beneath the toggle.
    var subtitle: String {
        switch self {
        case .servers:
            return "Server configurations, playlist URLs, per-server toggles, and reorder positions."
        case .watchProgress:
            return "Resume points and last-watched timestamps for movies and TV episodes."
        case .reminders:
            return "Upcoming-program reminders you scheduled from the EPG."
        case .preferences:
            return "Theme, appearance mode, accent color, default tab, hidden groups, and Guide Display settings."
        case .remoteControl:
            return "Your customized Apple TV remote button assignments. Turn this off on a TV whose remote is a different model from your others."
        case .radioModeDefault:
            return "Whether every channel opens in Radio Mode. Off by default, so each device keeps its own choice."
        case .credentials:
            return "Server passwords and API keys, stored in iCloud Keychain."
        }
    }

    /// One-line form for the onboarding chooser. `subtitle` is reference
    /// copy for the Settings page, where the user has gone looking for
    /// detail and there is room to read it; on the setup sheet the same
    /// strings wrapped to three lines each and turned a six-row list into a
    /// wall of text (Logan 2026-08-10, Apple TV). Say what it is, move on.
    var briefSubtitle: String {
        switch self {
        case .servers:       return "Playlists and server settings"
        case .watchProgress: return "Where you left off in movies and shows"
        case .reminders:     return "Program reminders you scheduled"
        case .preferences:   return "Theme, layout, and Guide settings"
        case .remoteControl: return "Your custom remote button assignments"
        case .radioModeDefault: return "Open every channel in Radio Mode"
        case .credentials:   return "Server passwords and API keys"
        }
    }

    /// Symbol shown in the Settings row.
    var icon: String {
        switch self {
        case .servers:       return "tray.full.fill"
        case .watchProgress: return "play.circle.fill"
        case .reminders:     return "bell.badge.fill"
        case .preferences:   return "gearshape.2.fill"
        case .remoteControl: return "av.remote.fill"
        case .radioModeDefault: return "radio"
        case .credentials:   return "key.fill"
        }
    }

    /// `UserDefaults` key for this category's enable flag. Missing
    /// key reads as `true` (v1.6.16 behavior preservation).
    var defaultsKey: String { "syncEnabled.\(rawValue)" }

    /// Reads the user's choice. Defaults to `true` when no value
    /// has been written, keeps every v1.6.16 user on the existing
    /// "everything syncs" behavior on first launch of v1.6.17.
    var isEnabled: Bool {
        let ud = UserDefaults.standard
        if ud.object(forKey: defaultsKey) == nil { return defaultEnabled }
        return ud.bool(forKey: defaultsKey)
    }

    /// Value when the user has never chosen. Every category is on except
    /// "Radio Mode by Default" (Discord: Glitzbr), a per-device listening
    /// choice that stays local unless the user opts in.
    var defaultEnabled: Bool { self != .radioModeDefault }
}

/// All five `syncEnabled.*` keys, exposed for SyncManager's
/// preferences-dictionary builder so they ride the cross-device
/// sync lane just like every other Bool preference.
extension SyncCategory {
    static var allDefaultsKeys: [String] {
        // `remoteControl` is deliberately EXCLUDED: it is a per-device choice
        // and must not ride the sync lane like the others.
        //
        // The whole point of the category (Discord: Glitzbr) is "this TV has a
        // different remote from my other one". If the flag synced, turning it
        // off on the odd TV out would propagate and turn it off on the main TV
        // too, which then stops publishing its map - the opposite of what he
        // asked for. `radioModeDefault` is per device for the same reason. Every other category is a genuinely account-wide
        // preference, so they keep syncing.
        SyncCategory.allCases
            .filter { $0 != .remoteControl && $0 != .radioModeDefault }
            .map(\.defaultsKey)
    }
}

// MARK: - Shared master default

/// Default for the master `iCloudSyncEnabled` toggle when the user has
/// never chosen. Every @AppStorage binding reads this one constant so the
/// screens cannot disagree about whether sync is on.
let iCloudSyncEnabledDefault = false

// MARK: - Per-item sync choices (2026-10-27)
//
// Owner decision: every synced option is selectable on its own in Sync
// Categories. Settings items take a four-way scope (All devices, TVs only,
// Phones and tablets only, Off) stored per device under
// "syncScope.<item id>" (missing = All devices). Data items keep a plain
// on/off stored under "syncItem.<id>" (missing = on), or bind to their
// existing SyncCategory flag. In the iCloud preferences blob, All devices
// rides the shared map; TVs only rides the `tv` lane (written by tvOS) and
// Phones and tablets only rides the `mobile` lane (written by iOS and
// iPadOS), mirroring the Android and Dispatcharr `v` / `tv` / `mobile`
// lanes. Off neither writes nor reads, and leaves the cloud value alone.

enum SyncScope: String, CaseIterable, Identifiable {
    case all, tv, mobile, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:    return "All devices"
        case .tv:     return "TVs only"
        case .mobile: return "Phones and tablets only"
        case .off:    return "Off"
        }
    }

    /// The lane this device form factor owns.
    static var deviceLane: SyncScope {
        #if os(tvOS)
        return .tv
        #else
        return .mobile
        #endif
    }

    static let tvLaneKey = "tv"
    static let mobileLaneKey = "mobile"
    var laneKey: String? {
        switch self {
        case .tv: return Self.tvLaneKey
        case .mobile: return Self.mobileLaneKey
        default: return nil
        }
    }
}

struct SyncItem: Identifiable, Hashable {
    let id: String
    /// Same wording as the Settings row it controls.
    let label: String
    /// UserDefaults keys this item carries. Empty for data items that
    /// ride a dedicated blob (recents, My List, hidden titles).
    let keys: [String]
    /// When set, the toggle is the existing category flag itself.
    let category: SyncCategory?
    /// Data items show an on/off toggle; settings items show a scope.
    let isData: Bool

    init(_ id: String, _ label: String, _ keys: [String] = [],
         category: SyncCategory? = nil, isData: Bool = false) {
        self.id = id; self.label = label; self.keys = keys; self.category = category
        self.isData = isData || category != nil
    }

    var toggleKey: String { "syncItem.\(id)" }
    var scopeKey: String { "syncScope.\(id)" }

    /// Effective scope. Items that ride the preferences payload are Off
    /// while the "App Preferences" category flag (the compatibility switch
    /// older builds and the onboarding chooser write) is off.
    var scope: SyncScope {
        if category == nil, !SyncCategory.preferences.isEnabled { return .off }
        return storedScope
    }

    /// Settings items: the chosen scope. Data items: .all or .off.
    var storedScope: SyncScope {
        let ud = UserDefaults.standard
        if isData {
            if let category { return category.isEnabled ? .all : .off }
            if ud.object(forKey: toggleKey) == nil { return .all }
            return ud.bool(forKey: toggleKey) ? .all : .off
        }
        return ud.string(forKey: scopeKey).flatMap(SyncScope.init(rawValue:)) ?? .all
    }

    /// True when this device writes and reads the item on some lane.
    var isActiveHere: Bool {
        let s = scope
        return s == .all || s == SyncScope.deviceLane
    }

    var isEnabled: Bool { scope != .off }

    func setScope(_ s: SyncScope) {
        let ud = UserDefaults.standard
        if isData {
            if let category { ud.set(s != .off, forKey: category.defaultsKey) }
            else { ud.set(s != .off, forKey: toggleKey) }
        } else {
            ud.set(s.rawValue, forKey: scopeKey)
        }
    }
}

struct SyncItemGroup: Identifiable {
    let id: String
    let title: String
    let items: [SyncItem]
}

enum SyncItemCatalog {
    // Data item ids that have no plain UserDefaults keys.
    static let recentsID = "recents"
    static let watchlistID = "watchlist"
    static let hiddenTitlesID = "hiddenTitles"

    static let groups: [SyncItemGroup] = [
        SyncItemGroup(id: "appearance", title: "Appearance", items: [
            SyncItem("selectedTheme", "Color Theme", ["selectedTheme"]),
            SyncItem("appearanceMode", "Light and Dark Mode", ["appearanceMode"]),
            SyncItem("trueBlack", "True Black Background", ["appearance.trueBlack"]),
            SyncItem("customAccent", "Custom Accent Color", ["useCustomAccent", "customAccentHex"]),
            SyncItem("glassEffect", "Glass Effect", ["liquidGlassStyle"]),
            SyncItem("textScale", "Text Size", ["textScale"]),
            SyncItem("subtextScale", "Subtext Size", ["subtextScale"]),
            SyncItem("textContrast", "Text Contrast", ["textContrast"]),
            SyncItem("timeFormat", "Time Format", ["timeFormat"]),
        ]),
        SyncItemGroup(id: "general", title: "General", items: [
            SyncItem("defaultTab", "Default Tab", ["defaultTab"]),
            SyncItem("skipLoadingScreen", "Skip Loading Screen", ["appBehaviorsSkipLoadingScreen"]),
            SyncItem("resumeLastChannel", "Resume Last Channel", ["appBehaviorsAutoResumeLastChannel"]),
        ]),
        SyncItemGroup(id: "liveTV", title: "Live TV", items: [
            SyncItem("defaultLiveTVView", "Default View", ["defaultLiveTVView"]),
            SyncItem("guideLayout", "Guide Layout", ["liveTVLayout"]),
            SyncItem("groupSelection", "Group Selection",
                     ["phoneGroupSelector", "guideGroupSelector.tv", "guideSidebarLayout.tv"]),
            SyncItem("edgeSwipeSidebar", "Swipe from Left Edge Opens Sidebar", ["liveTVEdgeSwipeOpensSidebar"]),
            SyncItem("showChannelLogos", "Show Channel Logos", ["ui.showChannelLogos"]),
            SyncItem("showChannelNumbers", "Show Channel Numbers", ["ui.showChannelNumbers"]),
            SyncItem("showChannelNames", "Show Channel Names", ["ui.showChannelNames"]),
            SyncItem("showProgramSubtitles", "Show Program Subtitles", ["ui.showProgramSubtitles"]),
            SyncItem("logoSize", "Logo Size", ["ui.channelLogoSize"]),
            SyncItem("programBadges", "Show Program Badges",
                     ["showEpgBadges.tv", "showEpgBadges.mobile", "ui.hiddenEpgBadges"]),
            SyncItem("programInfoButton", "Program Info Button",
                     ["guideProgramInfoButton", "guideProgramInfoButtonGuideView", "guideProgramInfoButtonListView"]),
            SyncItem("roundedGuideLogos", "Rounded Guide Logos", ["ui.roundedLogoCornersGuide"]),
            SyncItem("roundedProgramCells", "Rounded Program Cells", ["guide.roundedProgramCells"]),
            SyncItem("roundedListLogos", "Rounded List Logos and Artwork",
                     ["ui.roundedLogoCornersList", "ui.roundedLogoCorners"]),
            SyncItem("liveTVDisplayScale", "Display Scale", ["guideScale", "listScale"]),
            SyncItem("categoryColors", "Color Programs by Category",
                     ["enableCategoryColors", "customCategoryColors.v1"]
                     + ["sports", "movie", "kids", "news", "documentary", "drama",
                        "comedy", "reality", "educational", "scifi", "music"].map { "categoryColor.\($0)" }
                     + ["documentary", "drama", "comedy", "reality", "educational", "scifi",
                        "music"].map { "categoryBucketEnabled.\($0)" }),
            SyncItem("tintChannelCards", "Tint Channel Cards", ["tintChannelCards"]),
        ]),
        SyncItemGroup(id: "player", title: "Player", items: [
            SyncItem("infoCard", "Pop Up Info Card on Channel Change",
                     ["playerShowChannelInfoCard", "playerInfoCardChannelLogo", "playerInfoCardChannelName",
                      "playerInfoCardProgramName", "playerInfoCardProgramTime",
                      "playerInfoCardProgramSubtitle", "playerInfoCardProgramDescription"]),
            SyncItem("liveRewind", "Pause & Rewind Live TV",
                     ["liveRewindEnabled", "liveRewindDepthMinutes", "liveRewindRetainChannels", "liveRewindRetainCount"]),
            SyncItem("skipIntervals", "Skip Back and Skip Forward", ["skipBackSeconds", "skipForwardSeconds"]),
            SyncItem("skipWithoutControls", "Skip Without Controls", ["player.skipWithoutControls"]),
            SyncItem("autoRecover", "Auto-Recover Frozen Streams", ["appBehaviorsAutoRecoverFrozenStreams"]),
            SyncItem("channelFlip", "Up / Down Channel Change", ["appBehaviorsAppleTVChannelFlip"]),
            SyncItem("edgeBrightness", "Edge Slide for Brightness",
                     ["appBehaviorsEdgeBrightnessGesture", "appBehaviorsBrightnessEdge"]),
            SyncItem("edgeVolume", "Edge Slide for Volume", ["appBehaviorsEdgeVolumeGesture"]),
            SyncItem("multiviewAudioFocus", "Audio Focus Indicator", ["multiviewAudioFocusStyle"]),
            SyncItem("multiviewPadding", "Padding Between Tiles", ["multiviewTilePadding"]),
            SyncItem("multiviewCorners", "Tile Corners", ["multiviewTileCornersRounded"]),
            SyncItem("multiviewLogos", "Multiview Channel Logos",
                     ["multiview.showLogos", "multiview.logoPosition", "multiview.logoSize"]),
            SyncItem("multiviewSubtitles", "Multiview Subtitles", ["multiviewPickerShowSubtitles"]),
            SyncItem("multiviewDescriptions", "Multiview Descriptions", ["multiviewPickerShowDescriptions"]),
        ]),
        SyncItemGroup(id: "vod", title: "Movies & TV Shows", items: [
            SyncItem("refreshLibrary", "Refresh Library", ["vodLibraryRefreshHours"]),
            SyncItem("tmdb", "Use TMDB for Movies and TV Shows", ["programPostersTMDBEnabled"]),
            SyncItem("vodDisplayScale", "Display Scale", ["uiScale"]),
            SyncItem("hiddenCategory", "Hidden Category", ["vod.hiddenCategoryVisible.v1"]),
        ]),
        SyncItemGroup(id: "dvr", title: "DVR", items: [
            SyncItem("preRoll", "Start Early (Pre-Roll)", ["dvrDefaultPreRollMins"]),
            SyncItem("postRoll", "End Late (Post-Roll)", ["dvrDefaultPostRollMins"]),
        ]),
        SyncItemGroup(id: "remote", title: "Remote Control", items: [
            SyncItem("remoteHints", "Show Remote Hints", ["showRemoteHints"]),
            SyncItem("playChannelsIn", "Play Channels In", ["guideTuneInMini.tv"]),
            SyncItem("remoteMap", "Remote Button Map", category: .remoteControl),
        ]),
        SyncItemGroup(id: "data", title: "Your Data", items: [
            SyncItem("servers", "Playlists & Servers", category: .servers),
            SyncItem("credentials", "Credentials", category: .credentials),
            SyncItem("favorites", "Favorites", ["favoriteChannelIDs", "favoriteOrder"], isData: true),
            SyncItem(recentsID, "Recently Watched", isData: true),
            SyncItem("collections", "Collections", ["channelCollections"], isData: true),
            SyncItem("watchProgress", "Watch Progress", category: .watchProgress),
            SyncItem("reminders", "Reminders", category: .reminders),
            SyncItem(watchlistID, "My List", isData: true),
            SyncItem(hiddenTitlesID, "Hidden Titles", isData: true),
            SyncItem("hiddenGroups", "Hidden Groups",
                     ["hiddenChannelGroups", "hiddenMovieGroups", "hiddenSeriesGroups"], isData: true),
            SyncItem("groupOrder", "Group Order",
                     ["channelGroupOrder", "channelGroupOrder.sortMode", "defaultChannelGroup"], isData: true),
            SyncItem("radioDefault", "Radio Mode by Default", category: .radioModeDefault),
        ]),
    ]

    static var allItems: [SyncItem] { groups.flatMap(\.items) }

    /// Key -> owning item, for the push and pull filters.
    private static let itemByKey: [String: SyncItem] = {
        var map: [String: SyncItem] = [:]
        for item in groups.flatMap(\.items) { for k in item.keys { map[k] = item } }
        return map
    }()

    /// Every key some item carries, for the type-agnostic preferences lane.
    static var allKeys: [String] { allItems.flatMap(\.keys) }

    /// Scope of the item that owns this key; keys no item owns are .all.
    static func scope(of key: String) -> SyncScope {
        itemByKey[key]?.scope ?? .all
    }

    /// True when this device syncs the key on the shared map.
    static func allows(_ key: String) -> Bool { scope(of: key) == .all }

    static func isEnabled(_ id: String) -> Bool {
        allItems.first { $0.id == id }?.isActiveHere ?? true
    }

    /// Keeps the "App Preferences" category flag in step with the
    /// per-item choices: on while any item that rides the preferences
    /// payload is not Off. The category flag remains the compatibility
    /// switch older builds understand.
    static func syncPreferencesCategoryFlag() {
        let anyOn = allItems.contains { $0.category == nil && $0.storedScope != .off }
        UserDefaults.standard.set(anyOn, forKey: SyncCategory.preferences.defaultsKey)
    }
}
