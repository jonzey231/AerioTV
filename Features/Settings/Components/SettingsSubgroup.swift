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
//    iPad and tvOS - there is room, so the sub-toggles stay INLINE
//      under the master row. The summary subtitle still renders, so the
//      three form factors read the same at a glance.
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
    @ViewBuilder let content: Content

    init(_ title: String,
         summary: String,
         icon: String = "switch.2",
         iconColor: Color = .accentPrimary,
         footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.icon = icon
        self.iconColor = iconColor
        self.footer = footer
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

    // MARK: tvOS - always inline

    #if os(tvOS)
    private var tvBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(icon: icon, iconColor: iconColor,
                        title: title, subtitle: summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
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
        .background(Color.appBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
