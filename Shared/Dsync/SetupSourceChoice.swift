//  SetupSourceChoice.swift
//  Aerio
//
//  Which setup a device starts from when both the cloud backup (Google
//  Drive on Android, iCloud here) and Dispatcharr Sync hold data for the
//  same user and they differ (docs/DispatcharrSyncSchema.md section 10a,
//  Rules 4 and 5), plus CloudCanon, the canonical row identities both
//  sides fingerprint. Port of the pure parts of the Android
//  core/sync/SetupSourceChoice.kt and core/sync/DriveCanon.kt. Android's
//  "Drive" names are "Cloud" here (Source.cloud, Decision.useCloud,
//  cloudFile). The backup update copy is ported here; the Drive snapshot
//  enrichment and the probe failure reasons are Drive specific and not
//  ported.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

enum SetupSourceChoice {
    /// The shared categories compared, in display order. Profiles are per-row merge and never compared.
    static let SHARED = [
        "favorites", "progress", "reminders", "watchlist", "collections", "recents",
        "hiddenTitles", "hiddenGroups", "groupOrder", "settings",
    ]

    /// One category on one side. [updatedAt] is Unix milliseconds. [fingerprint]
    /// is over canonical row identities; nil when a row could not be resolved.
    struct Category: Equatable, Sendable {
        var rows: Int
        var updatedAt: Int64
        var fingerprint: String? = nil
    }

    /// [lastWrite], when set, is the side's latest write time and wins over the per-category times.
    struct Summary: Equatable, Sendable {
        var categories: [String: Category]
        var lastWrite: Int64? = nil

        var isEmpty: Bool { categories.values.allSatisfy { $0.rows <= 0 } }
        var updatedAt: Int64 {
            if let w = lastWrite, w > 0, !isEmpty { return w }
            return categories.values.filter { $0.rows > 0 }.map(\.updatedAt).max() ?? 0
        }
        func rows(_ name: String) -> Int { categories[name]?.rows ?? 0 }
        static let EMPTY = Summary(categories: [:])
    }

    enum Source: Sendable { case cloud, dispatcharr }

    enum Decision: Equatable, Sendable {
        case useCloud
        case useDispatcharr
        case ask(cloud: Summary, dsync: Summary)
    }

    /// One side empty: use the other (both empty: Dispatcharr). Both
    /// non-empty and every shared category provably equal: Dispatcharr. Otherwise ask.
    static func decide(_ cloud: Summary, _ dsync: Summary) -> Decision {
        if dsync.isEmpty && cloud.isEmpty { return .useDispatcharr }
        if dsync.isEmpty { return .useCloud }
        if cloud.isEmpty { return .useDispatcharr }
        if equal(cloud, dsync) { return .useDispatcharr }
        return .ask(cloud: cloud, dsync: dsync)
    }

    static func equal(_ a: Summary, _ b: Summary) -> Bool {
        Set(a.categories.keys).union(b.categories.keys).allSatisfy { categoryEqual(a.categories[$0], b.categories[$0]) }
    }

    /// The Sync Categories item that gates a shared category ("settings" is gated per name instead).
    static func itemId(_ name: String) -> String? {
        switch name {
        case "progress": return "watchProgress"
        case "settings": return nil
        default: return name
        }
    }

    /// Only the categories this device syncs; both sides go through this.
    static func forDevice(_ s: Summary, itemOff: (String) -> Bool) -> Summary {
        Summary(categories: s.categories.filter { n, _ in itemId(n).map { !itemOff($0) } ?? true }, lastWrite: s.lastWrite)
    }

    /// Per category: both empty, or the same row count and the same non-nil fingerprint.
    static func categoryEqual(_ x: Category?, _ y: Category?) -> Bool {
        let xr = x?.rows ?? 0
        let yr = y?.rows ?? 0
        return (xr <= 0 && yr <= 0) || (xr == yr && x?.fingerprint != nil && x?.fingerprint == y?.fingerprint)
    }

    /// Item Off in this device's Sync Categories.
    static func itemOff(_ scopes: [String: DsyncScope], _ id: String) -> Bool { scopes[id] == .off }

    /// A settings name whose item is Off on this device. Names no item covers stay in.
    static func nameOff(_ scopes: [String: DsyncScope], _ name: String) -> Bool {
        DsyncItemCatalog.itemForName(name).map { itemOff(scopes, $0.id) } ?? false
    }

    /// What a converge push remembers per category: the Dispatcharr state it pushed for.
    static func convergeMark(_ c: Category?) -> String { "\(c?.rows ?? 0)|\(c?.fingerprint ?? "-")" }

    /// Rule 5 (convergence): the shared categories whose cloud copy differs
    /// from the Dispatcharr copy, minus [skip] and minus those already
    /// pushed for this exact Dispatcharr state (the ping-pong guard).
    static func convergePlan(_ cloud: Summary, _ dsync: Summary, skip: Set<String>, lastPushed: [String: String]) -> [String] {
        SHARED.filter { cloud.categories[$0] != nil || dsync.categories[$0] != nil }
            .filter { !skip.contains($0) }
            .filter { !categoryEqual(cloud.categories[$0], dsync.categories[$0]) }
            .filter { lastPushed[$0] != convergeMark(dsync.categories[$0]) }
    }

    /// The differing categories converge does not push, each with its reason.
    static func convergeSkips(_ cloud: Summary, _ dsync: Summary, skip: [String: String],
                              lastPushed: [String: String]) -> [(String, String)] {
        SHARED.filter { cloud.categories[$0] != nil || dsync.categories[$0] != nil }
            .filter { !categoryEqual(cloud.categories[$0], dsync.categories[$0]) }
            .compactMap { n in
                if let r = skip[n] { return (n, r) }
                return lastPushed[n] == convergeMark(dsync.categories[n]) ? (n, "untranslatable") : nil
            }
    }

    static func convergeEqualLine(categories: Int, skipped: [(String, String)]) -> String {
        "[SYNC] converge equal categories=\(categories) skipped=\(skipped.count)"
    }

    static func convergeSkipLine(_ name: String, reason: String, cloud: Category?, dsync: Category?) -> String {
        "[SYNC] converge skip \(name) reason=\(reason) cloud=\(cloud?.rows ?? 0) dsync=\(dsync?.rows ?? 0)"
    }

    static func convergeLine(_ name: String, cloud: Category?, dsync: Category?) -> String {
        "[SYNC] converge \(name) cloud=\(cloud?.fingerprint ?? "-")/\(cloud?.rows ?? 0) dsync=\(dsync?.fingerprint ?? "-")/\(dsync?.rows ?? 0) -> push cloud"
    }

    /// The cloud file that carries a shared category (Android driveFile).
    static func cloudFile(_ name: String) -> DsyncCategory? {
        switch name {
        case "favorites": return .favorites
        case "progress": return .watchProgress
        case "reminders": return .reminders
        case "watchlist", "hiddenTitles": return .watchlist
        case "collections", "recents", "hiddenGroups", "groupOrder", "settings": return .preferences
        default: return nil
        }
    }

    /// The shared categories one cloud file carries, in SHARED order.
    static func namesInFile(_ file: DsyncCategory) -> [String] { SHARED.filter { cloudFile($0) == file } }

    /// Fresh-device order (Rule 4, Dispatcharr chosen): the first cloud push
    /// of [names] waits until the Dispatcharr pull of each has completed.
    /// Nil means push now; otherwise the reason it waits.
    static func freshDeviceHold(_ names: [String], read: Set<String>?) -> String? {
        if names.isEmpty { return nil }
        guard let read else { return "Dispatcharr pull not done" }
        if let n = names.first(where: { !read.contains($0) }) { return "\(n) not pulled yet" }
        return nil
    }

    /// Rule 4 with an unknown side: a failed cloud probe is unknown, never empty. Nil: do not decide.
    static func decideKnown(_ cloud: Summary?, _ dsync: Summary?) -> Decision? {
        guard let cloud, let dsync else { return nil }
        return decide(cloud, dsync)
    }

    /// Plain name for logs.
    static func decisionName(_ d: Decision) -> String {
        switch d {
        case .useCloud: return "UseCloud"
        case .useDispatcharr: return "UseDispatcharr"
        case .ask: return "Ask"
        }
    }

    /// The card selected when the prompt opens: always Dispatcharr (Logan, 2026-11-01).
    static func defaultSelection(cloud: Summary, dsync: Summary) -> Source { .dispatcharr }

    // ---- copy ----

    static let TITLE = "Which setup should this device start from?"
    static let FOOTER = "The other will be replaced with the setup you choose."
    static let DISPATCHARR = "Dispatcharr"
    /// Android GOOGLE_DRIVE ("Google Drive"): iCloud here.
    static let ICLOUD = "iCloud"
    static let CONTINUE = "Continue"
    static let CANCEL = "Cancel"
    static let NOTHING = "Nothing saved yet"

    // ---- "Your backup needs an update" (iCloud canonical-id update offer) ----

    static let UPDATE_TITLE = "Your backup needs an update"
    static let UPDATE_BODY = "AerioTV backups changed format. Updating keeps your backup working with the newest " +
        "version of AerioTV on every device. This takes a moment and does not change your favorites, progress, or settings."
    static let UPDATE_ACCEPT = "Update backup"
    static let UPDATE_NOT_NOW = "Not now"

    private static func label(_ name: String, _ n: Int) -> String {
        switch name {
        case "favorites": return n == 1 ? "favorite" : "favorites"
        case "progress": return "in progress"
        case "reminders": return n == 1 ? "reminder" : "reminders"
        case "watchlist": return "in Watchlist"
        case "collections": return n == 1 ? "collection" : "collections"
        case "recents": return n == 1 ? "recent channel" : "recent channels"
        case "hiddenTitles": return n == 1 ? "hidden title" : "hidden titles"
        case "hiddenGroups": return n == 1 ? "hidden group" : "hidden groups"
        case "groupOrder": return n == 1 ? "ordered group" : "ordered groups"
        case "settings": return n == 1 ? "setting" : "settings"
        default: return name
        }
    }

    static let MAX_COUNTS = 4

    /// "12 favorites, 8 in progress, 3 reminders": non-zero categories only, at most four, then "and more".
    static func countLine(_ s: Summary) -> String {
        let parts = SHARED.compactMap { name -> String? in
            let n = s.rows(name)
            return n > 0 ? "\(n) \(label(name, n))" : nil
        }
        if parts.isEmpty { return NOTHING }
        if parts.count > MAX_COUNTS { return parts.prefix(MAX_COUNTS).joined(separator: ", ") + ", and more" }
        return parts.joined(separator: ", ")
    }

    /// "Updated just now", "Updated 5 minutes ago", "Updated 1 hour ago", "Updated 3 days ago".
    static func updatedLine(_ updatedAtMs: Int64, nowMs: Int64) -> String {
        if updatedAtMs <= 0 { return "Not updated yet" }
        let s = max((nowMs - updatedAtMs) / 1000, 0)
        func unit(_ n: Int64, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s") ago" }
        let rel: String
        if s < 60 { rel = "just now" }
        else if s < 3600 { rel = unit(s / 60, "minute") }
        else if s < 86_400 { rel = unit(s / 3600, "hour") }
        else if s < 86_400 * 30 { rel = unit(s / 86_400, "day") }
        else if s < 86_400 * 365 { rel = unit(s / (86_400 * 30), "month") }
        else { rel = unit(s / (86_400 * 365), "year") }
        return "Updated \(rel)"
    }

    /// Order-independent fingerprint of comparable row identities. Same
    /// value as Android: Java String.hashCode over the sorted, trimmed,
    /// lowercased items joined by U+0001, as signed base-16.
    static func fingerprint<C: Collection>(_ items: C) -> String where C.Element == String {
        let norm = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        var h: Int32 = 0
        for u in norm.joined(separator: "\u{0001}").utf16 { h = h &* 31 &+ Int32(u) }
        return String(Int64(h), radix: 16)
    }
}

/// Canonical row identities shared by the cloud snapshots and Dispatcharr
/// Sync (section 10a). Dispatcharr side of the Android DriveCanon.
enum CloudCanon {
    static func channelItem(_ id: Int) -> String { "\(id)" }
    static func vodItem(_ type: String, _ id: Int) -> String { "\(type)|\(id)" }
    static func reminderItem(_ channelName: String, _ startS: Int64) -> String { "\(channelName)|\(startS)" }
    static func collectionItem(_ id: String, _ name: String, _ placement: String, _ members: [Int]) -> String {
        "\(id)|\(name)|\(placement)|" + members.distinctOrdered().sorted().map(String.init).joined(separator: ",")
    }
    static func groupItem(_ kind: String, _ name: String) -> String { "\(kind)|\(name)" }
    static func settingItem(_ lane: String, _ name: String, _ value: String) -> String { "\(lane)|\(name)|\(canonValue(value))" }

    private static let HEX = try! NSRegularExpression(pattern: "^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")

    /// One spelling per value on both sides (Rule 5): booleans lowercase,
    /// numbers without a trailing ".0", color hex uppercase without "#".
    static func canonValue(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower == "true" || lower == "false" { return lower }
        if dsyncMatches(HEX, t) && (t.hasPrefix("#") || t.contains(where: \.isLetter)) {
            return String(t.drop { $0 == "#" }.prefix(8)).uppercased()
        }
        if let d = Double(t), !d.isNaN, !d.isInfinite {
            if d == d.rounded(.down) && abs(d) < 1e15 { return String(Int64(d)) }
            return DsyncJSON.kotlinDouble(d)
        }
        return t
    }

    /// Settings lanes without the names this device has Off in Sync Categories.
    static func lanesOn<V>(_ lanes: [String: [String: V]], off: (String) -> Bool) -> [String: [String: V]] {
        lanes.mapValues { $0.filter { !off($0.key) } }
    }

    private static func fp(_ items: [String]) -> String { SetupSourceChoice.fingerprint(items) }

    // ---- Dispatcharr side (wire rows) ----

    static func dsyncFavorites(_ ids: [Int]) -> String { fp(ids.distinctOrdered().map(channelItem)) }
    static func dsyncRecents(_ rows: [RecentRow]) -> String { fp(rows.map { channelItem($0.channelId) }.distinctOrdered()) }
    static func dsyncProgress(_ rows: [ProgressRow]) -> String { fp(rows.map { vodItem($0.type, $0.vodId) }.distinctOrdered()) }
    static func dsyncReminders(_ rows: [ReminderRow]) -> String { fp(rows.map { reminderItem($0.channelName, $0.start) }) }
    static func dsyncMarks(_ rows: [VodMarkRow]) -> String { fp(rows.map { vodItem($0.type, $0.vodId) }.distinctOrdered()) }
    static func dsyncCollections(_ rows: [CollectionRow]) -> String { fp(rows.map { collectionItem($0.id, $0.name, $0.placement, $0.members) }) }
    static func dsyncHiddenGroups(_ g: DsyncPayloads.HiddenGroups) -> String { fp(hiddenGroupItems(g.live, g.movies, g.series)) }
    static func dsyncGroupOrder(_ g: DsyncPayloads.GroupOrder) -> String { fp(groupOrderItems(groupMode(g.mode), g.order)) }

    /// A known mode, lowercase, else "default".
    static func groupMode(_ m: String?) -> String {
        guard let l = m?.lowercased(), DsyncPayloads.GROUP_MODES.contains(l) else { return "default" }
        return l
    }

    /// (non-blank setting count, fingerprint) over every lane.
    static func dsyncSettings(_ lanes: [String: [String: DsyncJSON]]) -> (Int, String) {
        var items: [String] = []
        for (lane, m) in lanes {
            for (k, v) in m where !v.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(settingItem(lane, k, v.content))
            }
        }
        return (items.count, fp(items))
    }

    private static func hiddenGroupItems(_ live: [String], _ movies: [String], _ series: [String]) -> [String] {
        (live.map { groupItem("live", $0) } + movies.map { groupItem("movies", $0) } + series.map { groupItem("series", $0) }).distinctOrdered()
    }

    private static func groupOrderItems(_ mode: String, _ order: [String]) -> [String] {
        order.distinctOrdered().enumerated().map { "\($0.offset)|\($0.element)" } + ["mode|\(mode)"]
    }

    static func groupOrderRows(_ mode: String, _ order: [String]) -> Int {
        if !order.isEmpty { return order.distinctOrdered().count }
        return mode != "default" ? 1 : 0
    }

    /// Cloud-side settings category from lanes already translated to schema
    /// names; blank values are left out on both sides.
    static func settingsCategory(_ lanes: [String: [String: String]], updatedAt: Int64) -> SetupSourceChoice.Category {
        var items: [String] = []
        for (lane, m) in lanes {
            for (k, v) in m where !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(settingItem(lane, k, v)) }
        }
        return SetupSourceChoice.Category(rows: items.count, updatedAt: updatedAt, fingerprint: fp(items))
    }
}
