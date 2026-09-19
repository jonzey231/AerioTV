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
/// The ONE segmented chip for Settings: scale pills, stepper +/- keys,
/// Reset, and any short ladder of choices that reads better in a row
/// than as a list.
///
/// Why it is a VIEW and not a `ButtonStyle` (Logan 2026-09-19, third
/// round of device screenshots): the previous `TVSteppedSegmentStyle`
/// read focus through `@Environment(\.isFocused)` inside the style. That
/// value never arrived for a button hosted in a hand-built (non-List)
/// Settings card, so the Appearance Text Size / Subtext Size / Text
/// Contrast rows showed NO focus at all, and the Live TV scale pills
/// (which used `.buttonStyle(.plain)`) got the system's white platter
/// instead. Owning focus with `@FocusState` on the button itself is the
/// app's proven pattern and is what every other Settings row does.
///
/// The visual, per the standing rule: selection is the filled accent
/// capsule, focus is a 2 pt accent ring traced OUTSIDE that fill with a
/// 3 pt gap, so a focused+selected chip shows both and neither is white.
/// No scale bump.
struct TVSettingsPill<Label: View>: View {
    var isSelected: Bool = false
    var isDisabled: Bool = false
    /// Ghost variant: accent label on a faint accent fill with a hairline,
    /// never the solid accent capsule. Phase 3 item 4 (Logan 2026-09-19):
    /// Appearance's "Reset" pill was passing `isSelected: isDefault`, so a
    /// value already at its default drew a fully accent-filled capsule.
    /// That read as "selected and focused", and the pill's REAL focus ring
    /// was invisible against it. An action pill is never "selected", so it
    /// is a ghost at rest and takes the standard ring on focus.
    var isGhost: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @FocusState private var isFocused: Bool

    private var labelColor: Color {
        if isSelected { return .appBackground }
        if isGhost { return Color.contrastText(.accentPrimary) }
        return isFocused ? Color.contrastText(.accentPrimary)
                         : Color.contrastText(.textSecondary)
    }

    private var fillOpacity: Double {
        if isGhost { return isFocused ? 0.18 : 0.10 }
        return isFocused ? 0.18 : 0
    }

    var body: some View {
        Button(action: action) {
            label()
                .foregroundColor(labelColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected
                                   ? Color.accentPrimary
                                   : Color.accentPrimary.opacity(fillOpacity))
                )
                .overlay(
                    // Ghost hairline. Drawn inside the chip, so the focus
                    // ring outside it stays the only thing that moves.
                    Capsule().strokeBorder(
                        Color.accentPrimary.opacity(isGhost && !isSelected ? 0.45 : 0),
                        lineWidth: 1)
                )
                // Gap between the chip and its ring, always reserved so
                // the row geometry never shifts on focus.
                .padding(3)
        }
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .overlay(
            Capsule().strokeBorder(Color.accentPrimary,
                                   lineWidth: isFocused ? SettingsMetrics.tvFocusRingWidth : 0)
        )
        .focused($isFocused)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

extension TVSettingsPill where Label == AnyView {
    init(_ title: String, isSelected: Bool = false, isDisabled: Bool = false,
         isGhost: Bool = false, action: @escaping () -> Void) {
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.isGhost = isGhost
        self.action = action
        self.label = {
            AnyView(
                Text(title)
                    .scaledFont(.system(size: 22, weight: .medium))
                    .lineLimit(1)
            )
        }
    }
}

/// The +/- key of a Settings stepper row. Same chip, a glyph instead of
/// a word, so every stepper on the TV looks and focuses identically.
struct TVSettingsStepKey: View {
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        TVSettingsPill(isDisabled: isDisabled, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .frame(minWidth: 28)
        }
    }
}
#endif

#if os(tvOS)
/// One-row stepper for a short ladder of numbers: label on the left,
/// the current value in the middle, a minus and a plus capsule around
/// it. Mirrors the Appearance page's Text Size row, including its focus
/// visual (`TVSteppedSegmentStyle`: theme accent ring at the standard
/// Settings width, never white, no scale bump). Left/Right move focus
/// between the two buttons; Select steps the value.
///
/// Why it exists (Logan 2026-09-17): the DVR pre-roll and post-roll
/// choices rendered as six check rows each, plus a Custom row, which is
/// a whole screen of TV real estate for "how many minutes early". One
/// row says the same thing. Android is getting the identical control.
///
/// A value that is NOT one of `stops` (a custom number set on the phone,
/// which syncs) is displayed as-is and survives until the user steps
/// away from it: minus goes to the nearest stop below, plus to the
/// nearest stop above.
struct TVSettingsStepperRow: View {
    let title: String
    let stops: [Int]
    @Binding var value: Int
    /// How a value reads in the middle of the row, e.g. "None" / "5 min".
    let label: (Int) -> String
    var decreaseLabel: String = "Decrease"
    var increaseLabel: String = "Increase"

    private var sortedStops: [Int] { stops.sorted() }
    private var previousStop: Int? { sortedStops.last(where: { $0 < value }) }
    private var nextStop: Int? { sortedStops.first(where: { $0 > value }) }

    var body: some View {
        HStack(spacing: 24) {
            Text(title)
                .scaledFont(.system(size: SettingsMetrics.tvRowTitleSize, weight: .medium))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)

            TVSettingsStepKey(systemImage: "minus",
                              isDisabled: previousStop == nil) {
                if let previousStop { value = previousStop }
            }
            .accessibilityLabel(decreaseLabel)

            Text(label(value))
                .scaledFont(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundColor(Color.contrastText(.accentPrimary))
                .lineLimit(1)
                .frame(minWidth: 140)

            TVSettingsStepKey(systemImage: "plus",
                              isDisabled: nextStop == nil) {
                if let nextStop { value = nextStop }
            }
            .accessibilityLabel(increaseLabel)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(label(value))
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
            // Phase 3: the one Settings ring (accent, standard width). The
            // track used to ring at 3pt and scale up; both are gone.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentPrimary,
                              lineWidth: isFocused ? SettingsMetrics.tvFocusRingWidth : 0)
        )
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
    /// Phase 3 item 7 (Logan 2026-09-19, Movies & TV Shows): Test and Save
    /// both read as bare text at rest on the TV. They now match the phone:
    /// the PRIMARY action is an accent-filled button, the secondary one is
    /// a ghost with a hairline, and both keep the same height, radius and
    /// focus ring so they read as a pair of buttons before anything is
    /// focused. The standard Settings primary metrics are also what the
    /// Developer > Share Log File "Close" button uses (item 8).
    enum Role { case primary, ghost }

    let title: String
    var role: Role = .ghost
    var disabled: Bool = false
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var labelColor: Color {
        if disabled { return Color.contrastText(.textTertiary) }
        return role == .primary ? .appBackground : Color.contrastText(.accentPrimary)
    }

    private var fill: Color {
        switch role {
        case .primary: return .accentPrimary
        case .ghost:   return Color.accentPrimary.opacity(isFocused ? 0.20 : 0.10)
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledFont(.system(size: 24, weight: .semibold))
                .foregroundColor(labelColor)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .frame(minWidth: 160)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    // Ghost hairline, drawn inside the button so the focus
                    // ring outside it stays the only thing that changes.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentPrimary
                            .opacity(role == .ghost ? 0.55 : 0), lineWidth: 1)
                )
                .overlay(
                    // Focus ring, driven by this button's OWN FocusState. The
                    // shared button style reads focus from the environment,
                    // which does not arrive for a button inside a hand-built
                    // card, so on device these buttons showed no focus at all
                    // (Logan 2026-09-19). Drawn outside the fill with a gap so
                    // it stays visible against the accent-filled primary.
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentPrimary,
                                      lineWidth: SettingsMetrics.tvFocusRingWidth)
                        .padding(-5)
                        .opacity(isFocused ? 1 : 0)
                )
        }
        // One ring, from the shared style, traced at the button's own
        // 12pt radius instead of the style's default 14pt.
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false, settingsStyle: true))
        .focused($isFocused)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .disabled(disabled)
    }
}
#endif
