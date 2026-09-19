//
//  SettingsRow.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

/// The ONE leading icon for a Settings row: a tinted rounded tile with
/// the glyph centered in it.
///
/// Phase 3 item 5 (Logan 2026-09-19, Apple TV walkthrough): a tvOS page
/// mixed three leading treatments - a tile (Show Program Badges, Debug
/// Logging), a bare glyph (Badge Types, Time Format, the log rows) and
/// nothing at all (Color Theme, Mode, Playback Engine). The rule is now:
/// within a page, every row that has an icon uses THIS tile, and a row
/// either has this tile or no icon at all. Never a bare glyph.
struct SettingsIconTile: View {
    let icon: String
    var color: Color = .accentPrimary
    /// White-on-accent variant for the iPad sidebar's selection pill.
    var selectionContrast: Bool = false

    #if os(tvOS)
    static let boxSize: CGFloat = 48
    static let glyphSize: CGFloat = 22
    static let corner: CGFloat = 10
    #else
    static let boxSize: CGFloat = 32
    static let glyphSize: CGFloat = 14
    static let corner: CGFloat = 7
    #endif

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(selectionContrast ? Color.white.opacity(0.2) : color.opacity(0.2))
                .frame(width: Self.boxSize, height: Self.boxSize)
            Image(systemName: icon)
                .scaledFont(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundColor(selectionContrast ? .white : color)
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    /// Optional cap on the subtitle's line count. The iPad Settings
    /// sidebar passes 1 so a long value (an active playlist's name) ends
    /// in an ellipsis instead of wrapping the row taller; everywhere else
    /// keeps the unlimited default.
    var subtitleLineLimit: Int? = nil
    /// Overrides the title color. Used by destructive / warning rows
    /// (Delete Playlist, Refresh EPG Data) so they keep their red or
    /// amber title while still using the standard tiled icon and row
    /// metrics (Logan 2026-09-19, playlist detail page).
    var titleColor: Color? = nil
    /// iPad sidebar (Phase 4): true while the row sits on the accent
    /// selection pill, where the normal accent-tinted subtitle and icon
    /// would blend into the fill. Flips the row to white-on-accent, the
    /// native iPadOS sidebar look.
    var selectionContrast: Bool = false
    /// Shows a native spinner at the row's trailing edge while this
    /// row's own action is running (Logan 2026-09-15: the separate
    /// activity pill under the Push / Pull rows flashed so briefly it
    /// read as a glitch, so the indicator lives in the row that is
    /// actually working). The trailing box is always laid out, so the
    /// row's height never changes when the spinner appears.
    /// `nil` (the default) lays out no trailing box at all, preserving
    /// the row's original geometry everywhere else it is used.
    var isBusy: Bool? = nil
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

    /// Trailing spinner box, sized to match the leading icon tile so the
    /// row's two ends balance.
    private var iconBoxSize: CGFloat { SettingsIconTile.boxSize }

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(icon: icon, color: iconColor,
                             selectionContrast: selectionContrast)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(selectionContrast ? .white : (titleColor ?? .textPrimary))
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(.bodySmall)
                        .foregroundColor(selectionContrast ? .white.opacity(0.85) : Color.contrastText(.textSecondary))
                        .lineLimit(subtitleLineLimit)
                        .truncationMode(.tail)
                }
            }

            if let isBusy {
                Spacer(minLength: 0)

                // Reserved trailing box: present whether or not the
                // spinner is running so the row keeps a constant height
                // (and, on tvOS, a constant focus ring).
                ZStack {
                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(selectionContrast ? .white : .accentPrimary)
                            #if !os(tvOS)
                            .controlSize(.small)
                            #endif
                    }
                }
                .frame(width: iconBoxSize, height: iconBoxSize)
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
