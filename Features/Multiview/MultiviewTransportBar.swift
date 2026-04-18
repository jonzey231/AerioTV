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

    /// Drives the 5-second chrome auto-fade. Bar button actions
    /// report interaction so clicks keep chrome visible for another
    /// 5 seconds. iPad's `.onTapGesture` path covers taps anywhere
    /// else; tvOS's `.onMoveCommand` on the container covers D-pad
    /// navigation.
    @EnvironmentObject private var chromeState: MultiviewChromeState

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            tileCountChip
            Spacer(minLength: 20)
            addButton
            exitButton
        }
        // tvOS needs more vertical breathing room because the
        // focused `+` / `×` buttons scale to 1.15 — cramming them
        // into the iPad-sized bar clips the focus halo against the
        // grid above.
        .padding(.horizontal, 60)
        .padding(.vertical, 24)
        .background(Color.black)
        #else
        HStack(spacing: 14) {
            tileCountChip
            Spacer(minLength: 12)
            addButton
            exitButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
        #endif
    }

    // MARK: - Subviews

    /// Compact `N / 9` readout. Uses a smaller font than v1 and drops
    /// the leading grid icon to save horizontal space. The perf-
    /// warning orange dot still appears past `softLimit`, and the
    /// "max" pill still appears at the hard cap.
    private var tileCountChip: some View {
        HStack(spacing: 6) {
            Text("\(store.count) / \(store.maxTiles)")
                #if os(tvOS)
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                #else
                .font(.footnote.monospacedDigit())
                #endif
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

    /// `+` icon button. Disabled at cap.
    private var addButton: some View {
        Button {
            chromeState.reportInteraction()
            onAdd()
        } label: {
            #if os(tvOS)
            Image(systemName: "plus")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(store.isAtMax ? Color.secondary : Color.white)
                .frame(width: 80, height: 80)
                .contentShape(Circle())
            #else
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(store.isAtMax ? Color.secondary : Color.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TransportButtonStyle(tint: .white))
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(store.isAtMax)
        .accessibilityLabel("Add tile")
        .accessibilityHint(
            store.isAtMax
                ? "Maximum number of tiles reached"
                : "Open the channel picker to add another tile"
        )
    }

    /// `×` icon button (destructive). Exits multiview entirely.
    private var exitButton: some View {
        Button(role: .destructive) {
            chromeState.reportInteraction()
            onExit()
        } label: {
            #if os(tvOS)
            Image(systemName: "xmark")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Color.red)
                .frame(width: 80, height: 80)
                .contentShape(Circle())
            #else
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.red)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TransportButtonStyle(tint: .red))
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel("Exit multiview")
        .accessibilityHint("Leave multiview and stop all streams")
    }
}

// MARK: - tvOS transport button style

#if os(tvOS)
/// Focus chrome for transport-bar circular buttons. Reads
/// `@Environment(\.isFocused)` so a focused `+` lights up with
/// white fill + ring + 1.15 scale, and a focused `×` gets the
/// same treatment tinted red. Matches the tile's
/// `MultiviewTileButtonStyle` language (strong, unambiguous
/// focus signal) so the whole multiview screen shares one focus
/// vocabulary.
struct TransportButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(
                    isFocused ? tint.opacity(0.35) : Color.white.opacity(0.08)
                )
            )
            .overlay(
                Circle().stroke(
                    isFocused ? tint : Color.white.opacity(0.15),
                    lineWidth: isFocused ? 4 : 1
                )
            )
            .scaleEffect(isFocused ? 1.15 : 1.0)
            .shadow(
                color: isFocused ? tint.opacity(0.55) : .clear,
                radius: isFocused ? 16 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif

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
