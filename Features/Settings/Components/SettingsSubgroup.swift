//
//  SettingsSubgroup.swift
//  Aerio
//
//  Settings redesign Phase 3, item 4: a master row that owns a set of
//  sub-toggles and says, in its subtitle, what they currently add up to.
//
//  The problem it solves: pages were flat walls of switches. Live TV
//  showed five badge toggles, the Player page six info-card toggles and
//  three Live Rewind sections, all at the same visual level as the
//  settings that matter. You had to read every row to know the state.
//
//  The Phase 3 shape, matching Android:
//
//    iPhone - the master row shows a summary subtitle ("All 5",
//      "3 of 5", "Logo, name, time") and pushes a page holding the
//      sub-toggles.
//    iPad - there is room, so the sub-toggles stay INLINE under the
//      master row. The summary subtitle still renders, so the form
//      factors read the same at a glance.
//    tvOS - revised 2026-09-19 (Logan: the TV pages are "very long and
//      could be condensed"): a group with a master row pushes, like the
//      iPhone. Groups without one (Live Rewind) stay inline.
//
//  `SettingsSummary` builds the subtitle strings so iOS, tvOS and
//  Android all phrase them identically.
//

import SwiftUI

// MARK: - Summary strings

enum SettingsSummary {
    /// "All 5" / "3 of 5" / "None". Used by the badges group and by any
    /// other group of interchangeable switches.
    static func count(on: Int, of total: Int) -> String {
        if total <= 0 { return "None" }
        if on <= 0 { return "None" }
        if on >= total { return "All \(total)" }
        return "\(on) of \(total)"
    }

    /// "All 6", "None", or the enabled items listed in order and
    /// lowercased after the first ("Logo, name, time"). Used by the
    /// Player Info Card, where WHICH lines show matters more than how
    /// many.
    static func list(_ enabledTitles: [String], of total: Int) -> String {
        if enabledTitles.isEmpty { return "None" }
        if enabledTitles.count >= total { return "All \(total)" }
        return enabledTitles.enumerated().map { index, title in
            index == 0 ? title : title.lowercased()
        }.joined(separator: ", ")
    }
}

// MARK: - Master row + sub-toggles

struct SettingsSubgroup<Content: View>: View {
    let title: String
    let summary: String
    var icon: String = "switch.2"
    var iconColor: Color = .accentPrimary
    /// Explanatory copy: the pushed page's footer on iPhone, a footnote
    /// under the inline block everywhere else.
    var footer: String? = nil
    /// tvOS only: draw the `.card` chrome around the whole block, so the
    /// call site does not need a `SettingsSection` whose header would
    /// just repeat the master row's title.
    var drawsCard: Bool = false
    /// tvOS only: this group's children are a plain OPTION LIST (a set of
    /// interchangeable switches), so the master row opens the pop-up
    /// option sheet instead of pushing a page (Logan 2026-09-19). A group
    /// whose children are MIXED controls stays a pushed page. Multi-select
    /// behavior comes for free: the checkmarks are the children's own
    /// toggles, the sheet stays open while they are flipped, and Menu
    /// closes it.
    var optionsOnly: Bool = false
    /// tvOS only: suppress the master row. Set it where an enclosing
    /// section header and its own master toggle already name the group
    /// (Live Rewind), so the group is not labeled three times on one
    /// screen. iPhone still pushes a page titled `title`.
    var showsMasterRow: Bool = true
    @ViewBuilder let content: Content

    init(_ title: String,
         summary: String,
         icon: String = "switch.2",
         iconColor: Color = .accentPrimary,
         footer: String? = nil,
         drawsCard: Bool = false,
         optionsOnly: Bool = false,
         showsMasterRow: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.icon = icon
        self.iconColor = iconColor
        self.footer = footer
        self.drawsCard = drawsCard
        self.optionsOnly = optionsOnly
        self.showsMasterRow = showsMasterRow
        self.content = content()
    }

    /// True only on iPhone, where the sub-toggles are pushed. iPad has
    /// the width to keep them inline, and so does the TV.
    private var pushesPage: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iosBody
        #endif
    }

    // MARK: iOS / iPadOS

    #if !os(tvOS)
    @ViewBuilder
    private var iosBody: some View {
        if pushesPage {
            NavigationLink {
                SettingsSubgroupPage(title: title, footer: footer) { content }
            } label: {
                SettingsRow(icon: icon, iconColor: iconColor,
                            title: title, subtitle: summary,
                            subtitleLineLimit: 1)
            }
        } else {
            SettingsRow(icon: icon, iconColor: iconColor,
                        title: title, subtitle: summary)
            content
        }
    }
    #endif

    // MARK: tvOS - pushed when the group has its own master row

    #if os(tvOS)
    /// Logan 2026-09-19: the TV pages read as "very long and could be
    /// condensed". A group that owns a master row now behaves like the
    /// iPhone - one row carrying the summary, pushing a page with the
    /// sub-toggles and the explanatory footer on it. That takes Live TV's
    /// Badges from seven rows to one and removes the second stacked
    /// footer under the section. Groups with `showsMasterRow == false`
    /// (Live Rewind) have no row to collapse into, so they stay inline.
    @State private var isSheetPresented = false

    /// Title / summary / chevron, shared by the sheet and page variants.
    private var tvMasterRowLabel: some View {
        HStack(spacing: 16) {
            // Phase 3 item 5: tiled, matching every other Settings row.
            SettingsIconTile(icon: icon, color: iconColor)
            Text(title)
                .scaledFont(.system(size: SettingsMetrics.tvRowTitleSize, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer(minLength: 16)
            Text(summary)
                .scaledFont(.system(size: SettingsMetrics.tvEyebrowSize))
                .foregroundColor(Color.contrastText(.textSecondary))
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .scaledFont(.system(size: 22, weight: .semibold))
                .foregroundColor(Color.contrastText(.textTertiary))
        }
    }

    @ViewBuilder
    private var tvBody: some View {
        if showsMasterRow && optionsOnly {
            TVSettingsCardButtonRow(action: { isSheetPresented = true }) {
                tvMasterRowLabel
            }
            .fullScreenCover(isPresented: $isSheetPresented) {
                TVSettingsSheetCard(title: title, footer: footer) { content }
            }
        } else if showsMasterRow {
            TVSettingsNavRow(
                destination: TVSettingsSubgroupPage(title: title, footer: footer) { content }
                    .trackedAsClassicSettingsChild()
            ) {
                tvMasterRowLabel
            }
        } else {
            tvInlineBody
        }
    }

    @ViewBuilder
    private var tvInlineBody: some View {
        if drawsCard {
            tvStack
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.cardBackground)
                )
        } else {
            tvStack
        }
    }

    private var tvStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsMasterRow {
                SettingsRow(icon: icon, iconColor: iconColor,
                            title: title, subtitle: summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            content
            if let footer, !footer.isEmpty {
                Text(footer)
                    .scaledFont(.system(size: SettingsMetrics.tvFootnoteSize).subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif
}

// MARK: - Pushed sub-toggle page (tvOS)

#if os(tvOS)
/// The page a collapsed `SettingsSubgroup` master row pushes on tvOS.
/// The title is drawn in the content, not through `.navigationTitle`:
/// tvOS renders that as an oversized system title drawn over the
/// scrolling rows.
struct TVSettingsSubgroupPage<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .scaledFont(.system(size: 38, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                    content

                    if let footer, !footer.isEmpty {
                        Text(footer)
                            .scaledFont(.system(size: SettingsMetrics.tvFootnoteSize).subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: SettingsMetrics.tvReadingColumnWidth)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 60)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
#endif

// MARK: - Pushed sub-toggle page (iPhone)

#if !os(tvOS)
struct SettingsSubgroupPage<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        List {
            Section {
                content
            } footer: {
                if let footer, !footer.isEmpty {
                    Text(footer)
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        #endif
        .background(Color.appBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
