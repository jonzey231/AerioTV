//
//  SettingsDestination.swift
//  Aerio
//
//  Settings redesign Phase 2 (SettingsUIRedesign.md A1): the typed route
//  model replacing the string routes that drove the tvOS
//  `navigationDestination(for: String.self)` switch.
//

import Foundation

/// A Settings pane destination. These are the screens that will become
/// rail/sidebar detail panes in Phases 3 and 4; today they are the tvOS
/// push destinations.
///
/// My Recordings is deliberately NOT a case here: it stays a classic
/// full-screen push (and a top-level tab), and keeping it out of
/// CaseIterable means no rail or sidebar builder can ever list it by
/// accident.
///
/// Raw values are EXPLICIT ("dvr-settings", "live-tv") because Swift's
/// derived raw values would not match. Nothing persists these strings.
///
/// Phase 1 regroup (2026-09-17): `appBehaviors`, `multiview` and
/// `network` are gone; their rows live on `liveTV`, `player`, `moviesTV`
/// and `general`.
enum SettingsDestination: String, Hashable, CaseIterable {
    case playlists      = "playlists"       // pane: playlist list (rail lists categories only)
    // App
    case liveTV         = "live-tv"
    case player         = "player"
    case moviesTV       = "movies-tv"
    case dvr            = "dvr-settings"
    // Device
    case appearance     = "appearance"
    case general        = "general"
    case remoteControl  = "remote-control"
    case sync           = "sync"
    case syncCategories = "sync-categories"
    // Last section
    case developer      = "developer"
    case about          = "about"
}

/// Everything the Settings navigation can route to. `.category` covers the
/// pane destinations above; the other cases carry their model identity in
/// the route itself, which is what lets Phase 2 delete the `serverToEdit`
/// state bridge and its onDisappear-reset re-push hack.
enum SettingsRoute: Hashable {
    case category(SettingsDestination)
    /// Playlist detail (rail/sidebar selection target from Phase 3 on).
    case server(UUID)
    /// The full-screen Edit Playlist page (tvOS push).
    case editServer(UUID)
    /// Classic full-screen push, never a pane (Rev 2 ruling).
    case myRecordings
}
