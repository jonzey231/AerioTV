//
//  SettingsSection.swift
//  Aerio
//
//  Settings redesign Phase 1 (SettingsUIRedesign.md A4): the ONE section
//  container replacing the eight per-file `tvSection` helpers.
//
//  The audit called the eight helpers duplicates; re-verification during
//  extraction found they are actually FOUR distinct visual styles that
//  shipped over time:
//
//    .plain       uppercased 22pt tertiary eyebrow, bare content column
//                 (Developer, Multiview, DVR, Network)
//    .card        28pt semibold primary header, content in a padded
//                 cardBackground rounded-18 card
//                 (App Behaviors, Remote Control)
//    .compactCard title3 secondary header, zero-spacing content clipped
//                 into a rounded-14 card (Sync Categories)
//    .eyebrowCard uppercased eyebrow over a 24pt-padded rounded-16 card
//                 (Edit Playlist page)
//
//  Phase 1 is contractually "no visual change", so each style renders
//  byte-identically to the body it replaces and every call site keeps the
//  style it had. Unifying the four looks is a deliberate Phase 5 polish
//  decision, not a side effect of deduplication.
//
//  On iOS the container renders a plain `Section`, for the Phase 3/4 panes
//  that will host shared bodies. No iOS call sites exist yet in Phase 1.
//

import SwiftUI

struct SettingsSection<Content: View>: View {
    enum Style {
        /// Uppercased eyebrow header, bare content column.
        case plain
        /// Bold header with the content wrapped in a rounded card.
        case card
        /// Compact header with zero-spacing content clipped into a card.
        case compactCard
        /// Uppercased eyebrow header (no leading pad) with the content in a
        /// 24pt-padded rounded-16 card. The Edit Playlist page's look.
        case eyebrowCard
    }

    let title: String
    let style: Style
    @ViewBuilder let content: Content

    init(_ title: String, style: Style, @ViewBuilder content: () -> Content) {
        self.title = title
        self.style = style
        self.content = content()
    }

    var body: some View {
        #if os(tvOS)
        switch style {
        case .plain:
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased())
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.textTertiary)
                    .tracking(1)
                    .padding(.leading, 20)
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
            }
        case .card:
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.textPrimary)
                VStack(spacing: 12) {
                    content
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.cardBackground)
                )
            }
        case .compactCard:
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.textSecondary)
                    .padding(.leading, 12)
                VStack(spacing: 0) { content }
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .eyebrowCard:
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased())
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.textTertiary)
                    .tracking(1)
                VStack(spacing: 16) {
                    content
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.cardBackground)
                )
            }
        }
        #else
        Section(title) {
            content
        }
        #endif
    }
}
