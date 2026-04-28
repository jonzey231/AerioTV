import SwiftUI

/// A single channel row inside the `AddToMultiviewSheet` picker.
///
/// Visual (post-v1.6.12 — info parity with Live TV List rows):
/// ```
/// 101  [logo]  CHANNEL NAME              [✓ / +]
///              Currently airing program · 18 min left
///              ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░
/// ```
///
/// Tapping fires `onTap`. When `isAlreadyAdded == true` the row
/// shows a green check (still tappable — the parent dispatches
/// tap-while-added as a removal). `isDisabled == true` (hard cap
/// reached AND not already added) grays the row and blocks tap;
/// rows that are already added remain tappable even at the cap so
/// the user can deselect to make room.
///
/// **Current-program source** (matches `ChannelRow` in
/// `ChannelListView` post-v1.6.10): prefers the lightweight per-item
/// `currentProgram*` fields when populated (Xtream short-EPG,
/// Dispatcharr current-programs cache when fresh) and falls back to
/// `GuideStore.programs[item.id].first(where: \.isLive)` when
/// they're not. Without the fallback, Dispatcharr users would see
/// the picker rows showing only the channel name with no program
/// info — exactly the same bug the Live TV List had before
/// v1.6.10.
///
/// Platform-agnostic — same layout on iPadOS and tvOS, with
/// platform-specific size constants. On tvOS the outer Button
/// becomes focusable via `TVNoHighlightButtonStyle`; no custom
/// focus ring needed.
struct CompactChannelRow: View {
    let item: ChannelDisplayItem
    let isAlreadyAdded: Bool
    let isDisabled: Bool
    /// Single tap action — parent decides whether to add or remove
    /// based on `isAlreadyAdded`. Was `onAdd` pre-v1.6.12; renamed
    /// to keep callers honest about the semantic.
    let onTap: () -> Void

    /// Observe `GuideStore.programs` so the row can fall back to the
    /// guide dataset when the item-level current-program payload is
    /// empty. SwiftUI invalidates only when the specific channel's
    /// program list changes (the published property is the whole
    /// dictionary, but the diff per row is cheap).
    @ObservedObject private var guideStore = GuideStore.shared

    /// Currently-airing program for this row, picking the best
    /// available source. Mirrors `ChannelRow.liveProgram` so both
    /// surfaces converge on the same render path.
    private var liveProgram: (title: String, description: String?, start: Date, end: Date)? {
        if let title = item.currentProgram, !title.isEmpty,
           let start = item.currentProgramStart,
           let end = item.currentProgramEnd {
            return (title, item.currentProgramDescription, start, end)
        }
        if let p = guideStore.programs[item.id]?.first(where: { $0.isLive }) {
            return (p.title, p.description, p.start, p.end)
        }
        return nil
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: rowSpacing) {
                // Channel number — monospaced, matches Live TV List
                // visual. Hidden if empty so M3U-only sources without
                // numbers don't get a phantom whitespace column.
                if !item.number.isEmpty {
                    Text(item.number)
                        .font(.system(size: numberFontSize, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(width: numberWidth, alignment: .trailing)
                }

                logo

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.name)
                        .font(titleFont)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if let prog = liveProgram {
                        // Title + time-remaining on the same line.
                        // The remaining-minutes label is only shown
                        // when there's a positive value left;
                        // already-finished or future-start programs
                        // omit it (the program shouldn't appear at
                        // all in those cases, but be defensive).
                        HStack(spacing: 6) {
                            Text(verbatim: prog.title)
                                .font(subtitleFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let remaining = remainingLabel(end: prog.end) {
                                Text(verbatim: "· \(remaining)")
                                    .font(subtitleFont)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        // Thin progress bar indicating how far through
                        // the program we are. Same visual treatment
                        // as `nowPlayingProgressBar` in `ChannelRow`,
                        // just rendered inline so it ships with the
                        // picker without needing to extract that
                        // helper.
                        ProgressView(value: progressFraction(start: prog.start, end: prog.end))
                            .tint(Color.accentPrimary.opacity(0.85))
                            .frame(height: 2)
                    }
                }

                Spacer(minLength: 8)
                trailing
            }
            .padding(.vertical, rowVPadding)
            .padding(.horizontal, rowHPadding)
            .contentShape(Rectangle())
            .opacity(rowOpacity)
        }
        #if os(tvOS)
        // tvOS: use the app's standard no-halo style so the whole
        // row gets the same scale-up focus cue as Settings rows —
        // consistent with the rest of the tvOS app.
        .buttonStyle(TVNoHighlightButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        // v1.6.12: rows for already-added channels stay tappable so
        // the user can deselect (parent removes the tile). Only the
        // genuine "max tiles reached" state for not-yet-added rows
        // disables interaction.
        .disabled(isDisabled && !isAlreadyAdded)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint(a11yHint)
    }

    // MARK: - Program-time helpers

    /// "18 min left" / "32 sec left" style remaining-time label.
    /// Returns nil for programs that have already ended, are still in
    /// the future, or where end ≤ now+0 (avoids "0 sec left" jitter).
    private func remainingLabel(end: Date) -> String? {
        let now = Date()
        let remaining = end.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        if remaining < 60 {
            return "\(Int(remaining)) sec left"
        }
        let minutes = Int(remaining / 60)
        if minutes < 60 {
            return "\(minutes) min left"
        }
        let hours = minutes / 60
        let mins  = minutes % 60
        return mins == 0 ? "\(hours) hr left" : "\(hours) hr \(mins) min left"
    }

    /// Fraction `[0.0…1.0]` of the program elapsed. Clamped both ends
    /// so an out-of-range value (e.g. clock skew) doesn't render an
    /// invalid `ProgressView`.
    private func progressFraction(start: Date, end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return max(0, min(1, elapsed / total))
    }

    // MARK: - Platform sizing

    /// tvOS uses significantly larger rows (read from a couch, D-pad
    /// nav) — bigger logo, larger type, more padding. iPad stays
    /// compact so the sheet's detent heights don't explode.
    private var logoSize: CGFloat {
        #if os(tvOS)
        return 72
        #else
        return 42
        #endif
    }

    private var numberWidth: CGFloat {
        #if os(tvOS)
        return 56
        #else
        return 36
        #endif
    }

    private var numberFontSize: CGFloat {
        #if os(tvOS)
        return 22
        #else
        return 13
        #endif
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 12
        #endif
    }

    private var rowVPadding: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 8
        #endif
    }

    private var rowHPadding: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 12
        #endif
    }

    private var titleFont: Font {
        #if os(tvOS)
        return .system(size: 26, weight: .semibold)
        #else
        return .headline
        #endif
    }

    private var subtitleFont: Font {
        #if os(tvOS)
        return .system(size: 20, weight: .regular)
        #else
        return .caption
        #endif
    }

    private var trailingIconSize: CGFloat {
        #if os(tvOS)
        return 30
        #else
        return 22
        #endif
    }

    // MARK: - Subviews

    @ViewBuilder
    private var logo: some View {
        if let url = item.logoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                default:
                    logoPlaceholder
                }
            }
            .frame(width: logoSize, height: logoSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            logoPlaceholder
                .frame(width: logoSize, height: logoSize)
        }
    }

    private var logoPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            )
    }

    @ViewBuilder
    private var trailing: some View {
        if isAlreadyAdded {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: trailingIconSize))
                .foregroundStyle(.green)
                .accessibilityLabel("Already added")
        } else if isDisabled {
            Image(systemName: "hand.raised.slash")
                .font(.system(size: trailingIconSize))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cannot add — limit reached")
        } else {
            Image(systemName: "plus.circle")
                .font(.system(size: trailingIconSize))
                .foregroundStyle(Color.accentPrimary)
        }
    }

    private var rowOpacity: Double {
        if isAlreadyAdded { return 0.55 }
        if isDisabled { return 0.4 }
        return 1
    }

    private var a11yLabel: String {
        let progFragment: String = {
            guard let prog = liveProgram else { return "" }
            return ", airing \(prog.title)"
        }()
        if isAlreadyAdded { return "\(item.name)\(progFragment), added" }
        if isDisabled { return "\(item.name)\(progFragment), cannot add, limit reached" }
        return "\(item.name)\(progFragment)"
    }

    /// Tells VoiceOver what tapping this row will do. Without this
    /// hint, an "added" row reads as just "added" with no signal
    /// that activating it removes the tile.
    private var a11yHint: String {
        if isAlreadyAdded { return "Double tap to remove from multiview" }
        if isDisabled { return "" }
        return "Double tap to add to multiview"
    }
}
