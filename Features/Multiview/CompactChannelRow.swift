import SwiftUI

/// A single channel row inside the `AddToMultiviewSheet` picker.
///
/// Visual:
/// ```
/// [logo]  CHANNEL NAME     [✓ badge if already added]
///         Program (optional)
/// ```
///
/// Tapping fires `onAdd`. When `isAlreadyAdded == true` the row is
/// dimmed + the check badge replaces the Add-capable chevron.
/// `isDisabled == true` (e.g. hard cap reached) grays the row and
/// blocks tap.
///
/// Platform-agnostic — same layout on iPadOS and tvOS. On tvOS the
/// outer Button becomes focusable via `.buttonStyle(.plain)` +
/// system focus chrome; no custom focus ring is required at this
/// density (individual rows in a sheet, not large cards).
struct CompactChannelRow: View {
    let item: ChannelDisplayItem
    let isAlreadyAdded: Bool
    let isDisabled: Bool
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: rowSpacing) {
                logo
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.name)
                        .font(titleFont)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let prog = item.currentProgram, !prog.isEmpty {
                        Text(verbatim: prog)
                            .font(subtitleFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
        .disabled(isDisabled || isAlreadyAdded)
        .accessibilityLabel(a11yLabel)
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
        if isAlreadyAdded { return "\(item.name), already added" }
        if isDisabled { return "\(item.name), cannot add, limit reached" }
        return item.name
    }
}
