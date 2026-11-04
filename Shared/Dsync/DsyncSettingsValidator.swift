//  DsyncSettingsValidator.swift
//  Aerio
//
//  Read-side validation of a pulled `settings` lane (docs/
//  DispatcharrSyncSchema.md, settings values table): an unknown value, an
//  out-of-range number, or a value of the wrong type is ignored and the
//  local setting stays unchanged. Port of the Android
//  core/sync/dsync/DsyncSettingsValidator.kt; the schema names are the
//  shared Dispatcharr names, mapped to Apple UserDefaults keys in a later part.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

enum DsyncSettingsValidator {

    private static let ENUMS: [String: Set<String>] = [
        "selectedTheme": ["Aerio", "Midnight", "Sunset", "Forest", "Lavender", "Monochrome", "Light", "Custom"],
        "appearanceMode": ["dark", "light", "system"],
        "defaultTab": ["", "LiveTV", "DVR", "Movies", "TVShows", "Settings"],
        "timeFormat": ["system", "12", "24"],
        "guideGroupSelector": ["pills", "sidebar"],
        "phoneGroupSelector": ["pills", "sidebar"],
        "guideSidebarLayout": ["overlay", "shift"],
        "guideProgramInfoButton": ["off", "current", "all"],
        "guideLayout": ["basic", "preview"],
        "brightnessEdge": ["left", "right"],
        "dvrDefaultDestination": ["server", "local"],
    ]

    private static let RANGES: [String: ClosedRange<Double>] = [
        "textScale": 0.85...1.50,
        "subtextScale": 0.85...1.50,
        "textContrast": 0.0...1.0,
        "displayScaleLiveTv": 0.85...1.50,
        "displayScaleMovies": 0.85...1.50,
        "displayScaleGuide": 0.5...2.0,
    ]

    /// Same list as Shared/SkipIntervals (kept here so this stays pure).
    static let SKIP_CHOICES = [5, 10, 15, 30, 60]

    /// Whole numbers: an allowed set or an inclusive range.
    private static let INTS: [String: @Sendable (Int) -> Bool] = [
        "skipBack": { SKIP_CHOICES.contains($0) },
        "skipForward": { SKIP_CHOICES.contains($0) },
        "channelLogoSize": { (25...250).contains($0) },
        "dvrPreRollMins": { (0...240).contains($0) },
        "dvrPostRollMins": { (0...240).contains($0) },
        "vodLibraryRefreshHours": { (0...720).contains($0) },
        "liveRewindDepthMinutes": { (1...1440).contains($0) },
        "liveRewindKeepCount": { (1...5).contains($0) },
        "liveRewindRetentionHours": { (1...720).contains($0) },
        "liveRewindBudgetGb": { (1...500).contains($0) },
        "multiview.logoSize": { (5...25).contains($0) },
    ]

    static let BOOLEANS: Set<String> = Set([
        "trueBlack", "useCustomAccent", "programInfoButtonGuide", "programInfoButtonList", "showEpgBadgesTv",
        "showEpgBadgesMobile", "showRemoteHints", "exitDialogFocusExit", "guideTuneInMini", "playerInfoCard.showOnChannelChange",
        "liveTvEdgeSwipeOpensSidebar", "skipLoadingScreen", "appleTVChannelFlip", "enableCategoryColors",
        "tmdbPostersEnabled", "autoResumeLastChannel", "logoCornersList", "logoCornersGuide", "logoCornersGuideCells",
        "channelListShowLogos", "channelListShowNumbers", "channelListShowNames", "channelListShowProgramSubtitles",
        "skipWithoutControls", "autoRecoverFrozenStreams", "edgeBrightnessGesture", "edgeVolumeGesture",
        "liveRewindEnabled", "liveRewindKeepRecent", "multiview.tilePadding", "multiview.tileCornersRounded",
        "multiview.showLogos", "multiview.pickerShowSubtitles", "multiview.pickerShowDescriptions",
        "recentGroupVisible",
    ] + INFO_CARD_ROWS.map { "playerInfoCard.\($0)" })

    /// Free strings with a max length (any value).
    private static let STRINGS: [String: Int] = [
        "defaultGroup": 200, "lastGroup": 200, "customCategories": 4096, "hiddenEpgBadges": 1024,
        "defaultLiveTvView": 20, "moviesSortOrder": 40, "seriesSortOrder": 40, "dvrSortOrder": 40,
        "multiview.audioFocusStyle": 40, "multiview.logoPosition": 40,
    ]

    /// "RRGGBB" with an optional leading "#"; customAccentHex also takes "" (preset accent).
    private static let HEX = try! NSRegularExpression(pattern: "^#?[0-9A-Fa-f]{6}$")
    static let COLOR_PREFIX = "categoryColor."
    static let BUCKET_PREFIX = "categoryBucketEnabled."
    private static let SUFFIX = try! NSRegularExpression(pattern: "^[A-Za-z0-9_]{1,40}$")

    /// Every schema name this table owns (prefix families excluded; see isOwned).
    static let NAMES: Set<String> = Set(ENUMS.keys).union(RANGES.keys).union(INTS.keys).union(BOOLEANS)
        .union(STRINGS.keys).union(["customAccentHex", "customThemeHex"])

    static func isOwned(_ name: String) -> Bool {
        NAMES.contains(name)
            || (name.hasPrefix(COLOR_PREFIX) && dsyncMatches(SUFFIX, String(name.dropFirst(COLOR_PREFIX.count))))
            || (name.hasPrefix(BUCKET_PREFIX) && dsyncMatches(SUFFIX, String(name.dropFirst(BUCKET_PREFIX.count))))
    }

    /// Kotlin String.length counts UTF-16 units.
    private static func kLength(_ s: String) -> Int { s.utf16.count }

    /// True when [value] is acceptable for [name]. Unknown names are not accepted.
    static func accepts(_ name: String, _ value: DsyncJSON) -> Bool {
        let isString = value.asStr != nil
        if name == "customAccentHex" {
            guard let s = value.asStr else { return false }
            return s.isEmpty || dsyncMatches(HEX, s)
        }
        if name == "customThemeHex" { return value.asStr.map { dsyncMatches(HEX, $0) } ?? false }
        if name.hasPrefix(COLOR_PREFIX) && isOwned(name) { return value.asStr.map { dsyncMatches(HEX, $0) } ?? false }
        if name.hasPrefix(BUCKET_PREFIX) && isOwned(name) { return value.asBool != nil }
        if let max = STRINGS[name] { return value.asStr.map { kLength($0) <= max } ?? false }
        if let ok = INTS[name] {
            guard !isString, let i = value.asInt else { return false }
            return ok(i)
        }
        if let allowed = ENUMS[name] { return value.asStr.map { allowed.contains($0) } ?? false }
        if let r = RANGES[name] {
            guard !isString, let d = value.asDouble else { return false }
            return !d.isNaN && r.contains(d)
        }
        if BOOLEANS.contains(name) { return value.asBool != nil }
        return false
    }

    struct Result: Equatable, Sendable {
        let accepted: [String: DsyncJSON]
        /// "<key>=<value>" lines to log (setting names and values, never credentials).
        let ignored: [String]
    }

    /// Splits [v] into the values to apply and the ignored lines, in name order.
    static func filter(_ v: [String: DsyncJSON]) -> Result {
        var ok: [String: DsyncJSON] = [:]
        var bad: [String] = []
        for k in v.keys.sorted() {
            let e = v[k]!
            if accepts(k, e) { ok[k] = e } else { bad.append("\(k)=\(e.compact)") }
        }
        return Result(accepted: ok, ignored: bad)
    }
}
