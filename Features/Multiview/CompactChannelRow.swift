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
            HStack(spacing: 12) {
                logo
                VStack(alignment: .leading, spacing: 2) {
                    // `verbatim:` for server-controlled strings —
                    // matches the Phase 3 hardening on
                    // MultiviewTileView's error overlay. `SwiftUI.Text`
                    // does NOT apply Markdown to a non-literal `String`
                    // today, but this is defensive against a future
                    // SwiftUI change that might (and the intent is
                    // clearer at the call site).
                    Text(verbatim: item.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let prog = item.currentProgram, !prog.isEmpty {
                        Text(verbatim: prog)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .opacity(rowOpacity)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isAlreadyAdded)
        .accessibilityLabel(a11yLabel)
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
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            logoPlaceholder
                .frame(width: 42, height: 42)
        }
    }

    private var logoPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                .foregroundStyle(.green)
                .accessibilityLabel("Already added")
        } else if isDisabled {
            Image(systemName: "hand.raised.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cannot add — limit reached")
        } else {
            Image(systemName: "plus.circle")
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
