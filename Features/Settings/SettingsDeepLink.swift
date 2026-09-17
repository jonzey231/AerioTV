//
//  SettingsDeepLink.swift
//  Aerio
//
//  `aerio://settings/<page>` deep links. Built for automated screenshot
//  runs (`xcrun simctl openurl booted "aerio://settings/livetv"`), kept in
//  every configuration because the code is inert until such a URL arrives.
//
//  Two delivery paths, mirroring the Top Shelf channel/VOD links:
//   - A notification, for a warm app whose views are already mounted.
//   - A pending page held on the shared object, for a cold launch where
//     the URL lands before MainTabView/SettingsView exist. MainTabView
//     PEEKS at it (`hasPending`) to select the Settings tab; SettingsView
//     CONSUMES it (`consumePending()`) once, when it mounts.
//

import Foundation

extension Notification.Name {
    /// Posted with `userInfo["page"] = SettingsDeepLinkPage.rawValue`.
    static let aerioOpenSettingsPage = Notification.Name("aerioOpenSettingsPage")
}

/// The pages a `aerio://settings/<page>` URL can address. The raw values are
/// the URL spellings, deliberately short and lowercase for the screenshot
/// scripts; anything unrecognized falls back to `.root`.
enum SettingsDeepLinkPage: String, CaseIterable {
    case root
    case playlists
    case livetv
    case player
    case movies
    case dvr
    case appearance
    case general
    case remote          // tvOS only; no-op elsewhere
    case sync
    case developer
    case about
    /// Playlist detail for the active server.
    case playlistDetail = "playlist-detail"
    /// Edit Playlist for the active server.
    case editPlaylist   = "edit-playlist"

    /// The Settings category this page maps to, or nil for the two
    /// playlist pages (which need the active server's identity) and for
    /// `.root`.
    var category: SettingsDestination? {
        switch self {
        case .playlists:     return .playlists
        case .livetv:        return .liveTV
        case .player:        return .player
        case .movies:        return .moviesTV
        case .dvr:           return .dvr
        case .appearance:    return .appearance
        case .general:       return .general
        case .remote:        return .remoteControl
        case .sync:          return .sync
        case .developer:     return .developer
        case .about:         return .about
        case .root, .playlistDetail, .editPlaylist:
            return nil
        }
    }
}

@MainActor
final class SettingsDeepLink {
    static let shared = SettingsDeepLink()
    private init() {}

    private var pending: SettingsDeepLinkPage?

    /// True while a page is waiting for SettingsView to mount. Peeking does
    /// not clear it, so MainTabView can switch tabs and SettingsView can
    /// still consume the page afterwards.
    var hasPending: Bool { pending != nil }

    /// Handles `aerio://settings[/<page>]`. Returns false (and does
    /// nothing) for any other URL, so the caller can fall through to the
    /// Top Shelf channel/VOD handling.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "aerio", url.host == "settings" else { return false }
        let raw = url.pathComponents
            .filter { $0 != "/" }
            .first?
            .lowercased() ?? SettingsDeepLinkPage.root.rawValue
        // Unknown page = root (spec), never a silent no-op.
        let page = SettingsDeepLinkPage(rawValue: raw) ?? .root
        shared.pending = page
        NotificationCenter.default.post(
            name: .aerioOpenSettingsPage,
            object: nil,
            userInfo: ["page": page.rawValue]
        )
        return true
    }

    /// The `-settingsPage <page>` launch argument (UserDefaults maps
    /// `-key value` args into the argument domain) or the
    /// `AERIO_SETTINGS_PAGE` environment variable.
    ///
    /// This is the tvOS Simulator path: `simctl openurl` there raises a
    /// system "Open in AerioTV?" confirmation that nothing can dismiss,
    /// because the tvOS Simulator takes no synthetic input. A launch
    /// argument needs no confirmation:
    ///
    ///   xcrun simctl launch --terminate-running-process <udid> \
    ///       app.molinete.aerio -settingsPage livetv
    ///
    /// Neither source is persisted; both are read once per launch.
    nonisolated static func pageFromLaunchEnvironment() -> SettingsDeepLinkPage? {
        let raw = UserDefaults.standard.string(forKey: "settingsPage")
            ?? ProcessInfo.processInfo.environment["AERIO_SETTINGS_PAGE"]
        guard let raw, !raw.isEmpty else { return nil }
        return SettingsDeepLinkPage(rawValue: raw.lowercased()) ?? .root
    }

    /// Parks the launch-argument page exactly like a cold-launch deep link,
    /// so the rest of the flow (MainTabView peek, SettingsView consume) is
    /// identical. Called once from `AerioApp.init`.
    static func applyLaunchArgumentIfPresent() {
        guard let page = pageFromLaunchEnvironment() else { return }
        shared.pending = page
        NotificationCenter.default.post(
            name: .aerioOpenSettingsPage,
            object: nil,
            userInfo: ["page": page.rawValue]
        )
    }

    /// Takes the pending page, clearing it so a later mount does not
    /// re-navigate.
    func consumePending() -> SettingsDeepLinkPage? {
        defer { pending = nil }
        return pending
    }
}
