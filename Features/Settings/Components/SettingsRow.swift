//
//  SettingsRow.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    /// iPad sidebar (Phase 4): true while the row sits on the accent
    /// selection pill, where the normal accent-tinted subtitle and icon
    /// would blend into the fill. Flips the row to white-on-accent, the
    /// native iPadOS sidebar look.
    var selectionContrast: Bool = false
    /// Observe ThemeManager so the subtitle's `.textSecondary`
    /// (computed as `theme.accent.opacity(0.65)`) re-evaluates on
    /// theme changes. v1.6.8: parent SettingsView observes
    /// ThemeManager too, but SwiftUI's List + UITableView cell
    /// diff skips re-rendering a row's body unless one of its
    /// observed inputs changes — and Settings rows are
    /// constructed with the same prop values across themes
    /// (icon name + title + subtitle string). Subscribing the
    /// row directly forces a body refresh on every theme push,
    /// which is what makes `.textSecondary` actually pick up the
    /// new opacity-tinted accent.
    @ObservedObject private var theme = ThemeManager.shared

    #if os(tvOS)
    private let iconBoxSize: CGFloat = 48
    private let iconFontSize: CGFloat = 22
    private let cornerRadius: CGFloat = 10
    #else
    private let iconBoxSize: CGFloat = 32
    private let iconFontSize: CGFloat = 14
    private let cornerRadius: CGFloat = 7
    #endif

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selectionContrast ? Color.white.opacity(0.2) : iconColor.opacity(0.2))
                    .frame(width: iconBoxSize, height: iconBoxSize)
                Image(systemName: icon)
                    .font(.system(size: iconFontSize, weight: .semibold))
                    .foregroundColor(selectionContrast ? .white : iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(selectionContrast ? .white : .textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.bodySmall)
                        .foregroundColor(selectionContrast ? .white.opacity(0.85) : .textSecondary)
                }
            }
        }
        #if os(tvOS)
        .padding(.vertical, 14)
        #else
        .padding(.vertical, 2)
        #endif
    }
}

// MARK: - Server Detail View
// MARK: - Shared playlist delete cascade

/// Deletes a playlist and everything scoped to it: Keychain
/// credentials, EPGProgram rows, WatchProgress rows, server-side
/// Recording rows, in-memory VOD, and the iCloud copies. Shared by
/// the Settings root list and the playlist detail page's Danger
/// Zone so both delete paths stay in lockstep.
