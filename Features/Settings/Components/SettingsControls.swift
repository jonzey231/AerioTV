//
//  SettingsControls.swift
//  Aerio
//
//  Settings redesign Phase 1 (regroup): the shared Settings controls that
//  used to live at the bottom of AppBehaviorsSettingsView.swift. That file
//  became PlayerSettingsView.swift, but TVSteppedSegmentStyle is used by
//  Appearance too, so the controls move to Components/ where every page
//  can reach them. Bodies are unchanged.
//

import SwiftUI

#if os(tvOS)
/// Segment chip for `tvSteppedSegmentsRow`. Mirrors `MoviesPillStyle`
/// (Capsule, owned focus visual so the system white platter never shows)
/// at the row's original compact padding. Focused: white ring when
/// selected, accent ring when not.
struct TVSteppedSegmentStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isSelected ? .appBackground : (isFocused ? .white : .textSecondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(isSelected ? Color.accentPrimary : Color.clear))
            .overlay(Capsule().strokeBorder(isSelected ? Color.white : Color.accentPrimary, lineWidth: isFocused ? 3 : 0))
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif

// MARK: - Stream Buffer Slider (reusable, platform-split)

/// Reusable "Stream Buffer" control for Settings → App Behaviors.
///
/// Encapsulates the per-platform slider so both `iOSBody` and
/// `tvOSBody` can drop in `StreamBufferSlider(value:)`:
///   - iOS / iPadOS: a native `Slider` (0...5, step 0.5) with a
///     right-aligned "Off" / "X.Xs" value label, modeled on the
///     networkTimeout row in `SettingsView`.
///   - tvOS: a custom focusable track adjusted with the Siri Remote.
///     Left/right decrement/increment by 0.5 (clamped 0...5);
///     up/down are passed through so the focus engine still navigates
///     to adjacent rows.
struct StreamBufferSlider: View {
    @Environment(\.aerioTextScale) private var textScale
    @Binding var value: Double
    @ObservedObject private var theme = ThemeManager.shared

    private static let range: ClosedRange<Double> = 0...5
    private static let step: Double = 0.5

    /// "Off" at 0, otherwise "X.Xs".
    private var valueLabel: String {
        value <= 0 ? "Off" : String(format: "%.1fs", value)
    }

    #if os(iOS)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stream Buffer")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(valueLabel)
                    .scaledFont(.monoSmall)
                    .foregroundColor(Color.contrastText(theme.accent))
            }
            Slider(value: $value, in: Self.range, step: Self.step)
                .tint(theme.accent)
        }
    }
    #else
    // tvOS: custom focusable track driven by the Siri Remote.
    @State private var isFocused = false

    private func clamp(_ v: Double) -> Double {
        min(max(v, Self.range.lowerBound), Self.range.upperBound)
    }

    private func adjust(by delta: Double) {
        withAnimation(.easeOut(duration: 0.12)) {
            value = clamp(value + delta)
        }
    }

    var body: some View {
        HStack(spacing: 24) {
            Text("Stream Buffer")
                .scaledFont(.system(size: 24, weight: .semibold))
                .foregroundColor(.textPrimary)
                .frame(width: 260, alignment: .leading)

            GeometryReader { geo in
                let trackWidth = geo.size.width
                let fraction = Self.range.upperBound > 0
                    ? value / Self.range.upperBound
                    : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.textTertiary.opacity(0.25))
                        .frame(height: 10)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: max(0, trackWidth * fraction), height: 10)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 44)

            Text(valueLabel)
                .scaledFont(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundColor(isFocused ? theme.accent : Color.contrastText(.textSecondary))
                .frame(width: TextScale.grow(90, textScale), alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFocused ? Color.accentPrimary.opacity(0.12) : Color.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentPrimary, lineWidth: isFocused ? 3 : 0)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .overlay(
            TVPressOverlay(
                isFocused: $isFocused,
                canFocus: true,
                interceptsDirectional: true,
                // Slider adjust mode: left/right change the value; up/down and
                // Menu fall through so the focus engine can navigate away.
                horizontalAdjustOnly: true,
                // Tap does nothing (a value slider, not a button).
                onTap: {},
                onLongPress: {},
                onMoveUp: {},
                onMoveDown: {},
                onMenu: {},
                // Left/right adjust the value, clamped 0...5.
                onMoveLeft: { adjust(by: -Self.step) },
                onMoveRight: { adjust(by: Self.step) }
            )
        )
        .accessibilityElement()
        .accessibilityLabel("Stream Buffer")
        .accessibilityValue(valueLabel)
    }
    #endif
}

#if os(tvOS)
/// Compact tvOS action button that renders its label correctly when
/// focused. The default tvOS button style fills with the accent and
/// hides the label inside a hand-built (non-List) settings card, so we
/// suppress it with TVNoHighlightButtonStyle and draw our own focus
/// border + fill (mirroring TVSettingsActionRow's approach).
struct TVCompactButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledFont(.system(size: 24, weight: .semibold))
                .foregroundColor(disabled ? Color.contrastText(.textTertiary) : Color.contrastText(.accentPrimary))
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(minWidth: 160)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFocused ? Color.accentPrimary.opacity(0.20) : Color.elevatedBackground)
                )
        }
        // One ring, from the shared style, traced at the button's own
        // 12pt radius instead of the style's default 14pt.
        .buttonStyle(TVNoHighlightButtonStyle())
        .tvFocusRingShape(.rounded(12))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .disabled(disabled)
    }
}
#endif
