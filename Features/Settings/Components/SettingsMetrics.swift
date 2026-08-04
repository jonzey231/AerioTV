//
//  SettingsMetrics.swift
//  Aerio
//
//  Settings redesign Phase 1 (SettingsUIRedesign.md A4): named layout tokens
//  for the Settings surfaces. Phase 1 only DECLARES the canon; screens adopt
//  the tokens as they are touched in later phases, so introducing this file
//  changes nothing visually.
//

import SwiftUI

enum SettingsMetrics {
    // MARK: tvOS type ladder (the v1.7.5 reading-column sizes)
    /// Page title.
    static let tvTitleSize: CGFloat = 30
    /// Section header (Style B "card" sections use this).
    static let tvSectionHeaderSize: CGFloat = 26
    /// Row title.
    static let tvRowTitleSize: CGFloat = 24
    /// Uppercased eyebrow header (Style A "plain" sections) and row values.
    static let tvEyebrowSize: CGFloat = 22
    /// Row subtitle / footnote.
    static let tvFootnoteSize: CGFloat = 20

    // MARK: tvOS layout
    /// The v1.7.5 centered reading column, to be extended to every detail
    /// page in Phase 3 (today only Network / EditServerPage / ServerDetail
    /// use it).
    static let tvReadingColumnWidth: CGFloat = 1200
    /// Planned fixed rail width for the Phase 3 two-pane root.
    static let tvRailWidth: CGFloat = 430

    // MARK: iPad
    /// Detail-pane readable width cap for the Phase 4 split view.
    static let padDetailWidth: CGFloat = 700
    /// Top inset that keeps content clear of the floating tab capsule.
    /// PROVISIONAL: inherited from OnDemandView's iPadOS 18-era constant;
    /// re-measure on the iOS 26 SDK before Phase 4 adopts it (plan A2).
    static let padTabCapsuleTopInset: CGFloat = 72
}
