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

    // MARK: tvOS focus visuals (Phase 3)
    /// The ONE focus ring width for every Settings control on tvOS.
    /// Matches the guide's ring. Phase 3 rule (Logan 2026-09-17): focus
    /// rings are never bright white and never oversized, so nothing in
    /// Settings draws a 3pt or 4pt ring, and controls do not scale up on
    /// focus (the ring alone reads at TV distance).
    static let tvFocusRingWidth: CGFloat = 2
    /// Resting hairline around a Settings card.
    static let tvCardBorderWidth: CGFloat = 1

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

    // MARK: iPad split, Phase 2 (2026-09-17)
    // The split is decided by the Settings tab's AVAILABLE WIDTH, not by
    // the horizontal size class alone, so iPad Split View at 50% and
    // Stage Manager windows get two panes while a narrow Slide Over stays
    // a single list. Numbers match the Android tablet breakpoints
    // (600 dp / 840 dp) so both platforms feel the same.

    /// Minimum available width for two panes.
    static let padSplitMinWidth: CGFloat = 600
    /// Minimum available height for two panes. Below this (a short
    /// landscape Stage Manager window) the single list reads better.
    static let padSplitMinHeight: CGFloat = 480
    /// Width at which the sidebar steps up to its wide size.
    static let padSidebarWideBreakpoint: CGFloat = 840
    /// Sidebar width from `padSplitMinWidth` to just under the wide
    /// breakpoint.
    static let padSidebarWidth: CGFloat = 280
    /// Sidebar width at `padSidebarWideBreakpoint` and up.
    static let padSidebarWidthWide: CGFloat = 320
    /// Content cap for the detail pane, centered. Mirrors the tvOS
    /// reading column; narrower panes simply fill.
    static let padDetailContentCap: CGFloat = tvReadingColumnWidth

    /// The sidebar width for a given available width.
    static func sidebarWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        width >= padSidebarWideBreakpoint ? padSidebarWidthWide : padSidebarWidth
    }

    /// True when the Settings tab should show two panes.
    static func padWantsSplit(width: CGFloat, height: CGFloat) -> Bool {
        width >= padSplitMinWidth && height >= padSplitMinHeight
    }
    /// Top inset that keeps content clear of the floating tab capsule.
    /// PROVISIONAL: inherited from OnDemandView's iPadOS 18-era constant;
    /// re-measure on the iOS 26 SDK before Phase 4 adopts it (plan A2).
    static let padTabCapsuleTopInset: CGFloat = 72

    // MARK: iPhone bottom clearance (Phase 3, Logan 2026-09-18)
    /// Bottom scroll clearance under the floating tab bar. Same 96 pt the
    /// other tabs already reserve with their trailing spacer row
    /// (ChannelListView / MoviesView / TVShowsView / PhoneMediaPage), so
    /// the last Settings row clears the bar by the same margin.
    static let phoneTabBarClearance: CGFloat = 96
}

#if os(iOS)
import UIKit

/// Makes a Settings scroll container behave like every other phone tab:
/// content runs UNDER the floating tab bar (no opaque scroll-edge band),
/// the bar tucks away after a deliberate downward scroll and returns on
/// any upward scroll, and the last row clears the bar.
///
/// Why Settings differed (Logan 2026-09-18): every other tab pairs
/// `scrollAwayTabBar` + `ignoresSafeArea(.container, edges: .bottom)` +
/// `aerioContentUnderTabBar()` on its scroll view. Settings had none of
/// the three, so the system's bottom scroll-edge effect resolved to the
/// HARD style (the solid band behind the bar) and nothing ever fed
/// `TabBarCollapseState`, leaving the bar pinned and expanded.
///
/// Phone only: iPad Settings is a split view with its own chrome.
private struct SettingsPhoneTabBarChrome: ViewModifier {
    @State private var tabBarHidden = false
    @State private var tracker = TabBarScrollTracker()

    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content
                .onScrollGeometryChange(for: [CGFloat].self) { geo in
                    [geo.contentOffset.y,
                     geo.contentSize.height - geo.containerSize.height
                        + geo.contentInsets.bottom - geo.contentInsets.top]
                } action: { old, new in
                    let oldY = old[0], y = new[0], maxY = new[1]
                    // No bar changes while rubber-banding past either end:
                    // the spring-back reads as a scroll in the opposite
                    // direction (MoviesView 2026-09-09).
                    if y > maxY - 1 || oldY > maxY - 1 { return }
                    if let hidden = tracker.update(oldY: oldY, newY: y,
                                                   hidden: tabBarHidden) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            tabBarHidden = hidden
                        }
                    }
                }
                .scrollAwayTabBar(collapsed: tabBarHidden)
                .contentMargins(.bottom, SettingsMetrics.phoneTabBarClearance,
                                for: .scrollContent)
                .ignoresSafeArea(.container, edges: .bottom)
                .aerioContentUnderTabBar()
        } else {
            content
        }
    }
}

extension View {
    /// See `SettingsPhoneTabBarChrome`. Applied to the scroll container of
    /// every Settings page, root and pushed, including the picker and
    /// sub-toggle pages.
    func settingsPhoneTabBarChrome() -> some View {
        modifier(SettingsPhoneTabBarChrome())
    }
}
#endif
