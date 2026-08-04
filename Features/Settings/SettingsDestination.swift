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
/// Raw values are EXPLICIT and match the legacy route strings exactly
/// ("app-behaviors", "dvr-settings"), because Swift's derived raw values
/// would not. Nothing persists these strings; they only document the
/// mechanical conversion from the old switch.
enum SettingsDestination: String, Hashable, CaseIterable {
    case appearance     = "appearance"
    case appBehaviors   = "app-behaviors"
    case remoteControl  = "remote-control"
    case multiview      = "multiview"
    case network        = "network"
    case dvr            = "dvr-settings"
    case sync           = "sync"            // Phase 3 pane host for the root Sync toggles
    case syncCategories = "sync-categories"
    case developer      = "developer"
    case about          = "about"           // Phase 3 pane host for the About rows
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
