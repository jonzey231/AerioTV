import SwiftUI

/// Bottom-docked transport strip for the multiview grid.
///
/// Slim version (per device-test feedback): solid black bar instead
/// of ultraThinMaterial chrome, small monospaced tile-count chip on
/// the left, icon-only `+` and `×` buttons on the right. No text
/// labels — the icons are universally recognisable and leave more
/// vertical space for the actual grid. Accessibility labels still
/// spell out the actions for VoiceOver.
///
/// State comes from the passed-in `MultiviewStore`; the bar itself
/// is pure presentation. Action closures fire back up to the
/// container view.
struct MultiviewTransportBar: View {
    @ObservedObject var store: MultiviewStore

    /// Fires when the user taps the `+` button. Container shows the
    /// channel picker sheet.
    var onAdd: () -> Void

    /// Fires when the user taps the `×` button. Container calls
    /// `PlayerSession.shared.exit()`.
    var onExit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            tileCountChip

            Spacer(minLength: 12)

            addButton
            exitButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    // MARK: - Subviews

    /// Compact `N / 9` readout. Uses a smaller font than v1 and drops
    /// the leading grid icon to save horizontal space. The perf-
    /// warning orange dot still appears past `softLimit`, and the
    /// "max" pill still appears at the hard cap.
    private var tileCountChip: some View {
        HStack(spacing: 6) {
            Text("\(store.count) / \(store.maxTiles)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(store.isAtMax ? .secondary : .primary)
            if store.isAtMax {
                Text("max")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().stroke(.secondary.opacity(0.4), lineWidth: 1)
                    )
                    .accessibilityHidden(true)
            } else if store.count > store.softLimit {
                // Perf-warning has fired (or been acknowledged);
                // small orange dot signals "degraded performance"
                // territory without getting in the way.
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Performance-degraded mode")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            store.isAtMax
                ? "Tile count: \(store.count) of \(store.maxTiles), maximum reached"
                : "Tile count: \(store.count) of \(store.maxTiles)"
        )
    }

    /// `+` icon button. Disabled at cap. Text label removed in favour
    /// of the glyph — matches the per-tile close-`×` affordance and
    /// reduces bar height.
    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(store.isAtMax ? Color.secondary : Color.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isAtMax)
        .accessibilityLabel("Add tile")
        .accessibilityHint(
            store.isAtMax
                ? "Maximum number of tiles reached"
                : "Open the channel picker to add another tile"
        )
    }

    /// `×` icon button (destructive). Exits multiview entirely.
    /// Matches the `xmark.circle.fill` affordance on the per-tile
    /// close buttons so the destructive iconography is consistent.
    private var exitButton: some View {
        Button(role: .destructive, action: onExit) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.red)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exit multiview")
        .accessibilityHint("Leave multiview and stop all streams")
    }
}

#if DEBUG
#Preview("Transport Bar — slim") {
    MultiviewTransportBar(
        store: MultiviewStore.shared,
        onAdd: {},
        onExit: {}
    )
    .padding(40)
    .background(Color.black)
}
#endif
