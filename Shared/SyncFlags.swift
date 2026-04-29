//  SyncFlags.swift
//  Aerio
//
//  v1.6.17 — granular per-data-type iCloud sync controls.
//
//  Background: prior to v1.6.17 the iCloud Sync section in Settings was
//  one master toggle that pushed/pulled every data type SyncManager
//  knows about. Users wanted finer control — e.g. "sync my servers
//  across devices but keep my watch progress local-only." This file
//  defines the data-type matrix that the new "Sync Categories"
//  Settings sub-section binds to.
//
//  Storage: per-category state lives in `UserDefaults` under
//  "syncEnabled.<rawValue>". We default missing keys to `true` so
//  existing v1.6.16 users see no behavioral change on upgrade — every
//  category is on until they actively turn one off.
//
//  Round-trip: the toggle prefs themselves ride the existing prefs
//  sync lane (see `SyncManager.syncBoolKeys`) so a flip on one device
//  propagates. There's a bootstrapping subtlety in
//  `SyncManager.doApplyPreferences` — see the inline note there.

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
    case credentials

    var id: String { rawValue }

    /// Title shown in the toggle row.
    var displayName: String {
        switch self {
        case .servers:       return "Playlists & Servers"
        case .watchProgress: return "VOD Watch Progress"
        case .reminders:     return "Reminders"
        case .preferences:   return "App Preferences"
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
            return "Theme, accent color, default tab, refresh schedule, hidden groups, and Guide Display settings."
        case .credentials:
            return "Server passwords and API keys, stored in iCloud Keychain."
        }
    }

    /// Symbol shown in the Settings row.
    var icon: String {
        switch self {
        case .servers:       return "tray.full.fill"
        case .watchProgress: return "play.circle.fill"
        case .reminders:     return "bell.badge.fill"
        case .preferences:   return "gearshape.2.fill"
        case .credentials:   return "key.fill"
        }
    }

    /// `UserDefaults` key for this category's enable flag. Missing
    /// key reads as `true` (v1.6.16 behavior preservation).
    var defaultsKey: String { "syncEnabled.\(rawValue)" }

    /// Reads the user's choice. Defaults to `true` when no value
    /// has been written — keeps every v1.6.16 user on the existing
    /// "everything syncs" behavior on first launch of v1.6.17.
    var isEnabled: Bool {
        let ud = UserDefaults.standard
        if ud.object(forKey: defaultsKey) == nil { return true }
        return ud.bool(forKey: defaultsKey)
    }
}

/// All five `syncEnabled.*` keys, exposed for SyncManager's
/// preferences-dictionary builder so they ride the cross-device
/// sync lane just like every other Bool preference.
extension SyncCategory {
    static var allDefaultsKeys: [String] {
        SyncCategory.allCases.map(\.defaultsKey)
    }
}
