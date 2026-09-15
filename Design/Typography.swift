import SwiftUI
import UIKit

// MARK: - Text Size (Settings > Appearance)
//
// One app-wide text multiplier (85% to 150%, default 100%) that applies to
// EVERY piece of text on iPhone, iPad and Apple TV. SwiftUI's
// `dynamicTypeSize` does not scale fixed `.system(size:)` fonts, and a
// resolved `Font` is opaque, so fonts are described with `AerioFont` (a
// recipe: fixed point size or text style, plus weight / design / traits)
// and applied through `.scaledFont(_:)`, which multiplies the size by the
// `aerioTextScale` environment value at render time.
//
// The value is injected once at the app root from `@AppStorage` (see
// `TextScale.key`), so changes apply live everywhere, sheets and full
// screen covers included. Existing per-view multipliers (guide / list /
// VOD scale) are baked into the size a call site passes, so the text scale
// multiplies on top of them and never double counts.
//
// At exactly 100% every recipe resolves to the SAME `Font` the app used
// before this feature (text styles stay text styles, so system Dynamic
// Type and default leading are unchanged). Off 100%, text styles resolve
// to their current system point size (honoring the device Dynamic Type
// setting) times the multiplier.
enum TextScale {
    /// UserDefaults / iCloud KVS key. Synced via `SyncManager.syncDoubleKeys`.
    static let key = "textScale"
    static let range: ClosedRange<Double> = 0.85...1.5
    static let step: Double = 0.05
    static let defaultValue: Double = 1.0

    /// Every selectable value, 85% through 150% in 5% steps.
    static let steps: [Double] = stride(from: 85, through: 150, by: 5).map { Double($0) / 100 }

    /// Snaps an arbitrary stored value (edited defaults, a synced value
    /// from an older client) onto the 5% grid inside the range.
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let bounded = min(max(value, range.lowerBound), range.upperBound)
        return (bounded / step).rounded() * step
    }

    /// Persisted value, clamped. Used as the environment default for any
    /// SwiftUI tree hosted outside the app root (UIHostingController).
    static var stored: CGFloat {
        let raw = UserDefaults.standard.object(forKey: key) as? Double ?? defaultValue
        return CGFloat(clamp(raw))
    }

    /// Scales a layout metric that must track text (fixed row heights,
    /// marquee frames). Metrics only ever GROW with text, never shrink
    /// below their designed size, so 85% text keeps the original layout.
    static func grow(_ metric: CGFloat, _ scale: CGFloat) -> CGFloat {
        metric * max(1, scale)
    }

    /// `grow` for a fixed container that mixes primary text with subtext
    /// (a title line plus description / time lines): half the container
    /// is treated as subtext, so Subtext Size grows it proportionally.
    static func growMixed(_ metric: CGFloat, _ scale: CGFloat, subtext: CGFloat) -> CGFloat {
        metric * max(1, scale * (0.5 + 0.5 * subtext))
    }
}

// MARK: - Subtext Size (Settings > Appearance)
//
// A second multiplier (85% to 150%, default 100%) applied ONLY to
// secondary text: descriptions, footers, subtitles, metadata, captions,
// timestamps, empty-state explanations. It stacks on top of Text Size.
// Call sites opt in with `AerioFont.subtext()`, so primary text (titles,
// channel names, buttons, tabs, pills, headers) is never affected.
enum SubtextScale {
    /// UserDefaults / iCloud KVS key. Synced via `SyncManager.syncDoubleKeys`.
    static let key = "subtextScale"
    static let range: ClosedRange<Double> = 0.85...1.5
    static let step: Double = 0.05
    static let defaultValue: Double = 1.0
    static let steps: [Double] = stride(from: 85, through: 150, by: 5).map { Double($0) / 100 }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let bounded = min(max(value, range.lowerBound), range.upperBound)
        return (bounded / step).rounded() * step
    }

    static var stored: CGFloat {
        let raw = UserDefaults.standard.object(forKey: key) as? Double ?? defaultValue
        return CGFloat(clamp(raw))
    }
}

// MARK: - Text Contrast (Settings > Appearance)
//
// 0% to 100% in 10% steps, default 0%. Blends dimmed (textSecondary /
// textTertiary) and accent-colored TEXT toward white (dark appearance) or
// black (light appearance). 0% = designed colors, 100% = plain white or
// black. Text only: surfaces, fills, focus rings and progress bars keep
// their tokens. See `Color.contrastText(_:)` in Colors.swift.
enum TextContrast {
    /// UserDefaults / iCloud KVS key. Synced via `SyncManager.syncDoubleKeys`.
    static let key = "textContrast"
    static let range: ClosedRange<Double> = 0...1
    static let step: Double = 0.1
    static let defaultValue: Double = 0
    static let steps: [Double] = stride(from: 0, through: 100, by: 10).map { Double($0) / 100 }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let bounded = min(max(value, range.lowerBound), range.upperBound)
        return (bounded / step).rounded() * step
    }

    static var stored: Double {
        clamp(UserDefaults.standard.object(forKey: key) as? Double ?? defaultValue)
    }
}

private struct AerioSubtextScaleKey: EnvironmentKey {
    static var defaultValue: CGFloat { SubtextScale.stored }
}

private struct AerioTextContrastKey: EnvironmentKey {
    static var defaultValue: Double { TextContrast.stored }
}

private struct AerioTextScaleKey: EnvironmentKey {
    static var defaultValue: CGFloat { TextScale.stored }
}

extension EnvironmentValues {
    /// App-wide text multiplier. 1.0 = designed size.
    var aerioTextScale: CGFloat {
        get { self[AerioTextScaleKey.self] }
        set { self[AerioTextScaleKey.self] = newValue }
    }

    /// Secondary-text multiplier, applied on top of `aerioTextScale` to
    /// fonts marked `.subtext()`. 1.0 = designed size.
    var aerioSubtextScale: CGFloat {
        get { self[AerioSubtextScaleKey.self] }
        set { self[AerioSubtextScaleKey.self] = newValue }
    }

    /// Text Contrast amount, 0...1. Colors read the same value through
    /// `ThemeManager.shared.textContrast`; this mirror is for views that
    /// want to branch on it.
    var aerioTextContrast: Double {
        get { self[AerioTextContrastKey.self] }
        set { self[AerioTextContrastKey.self] = newValue }
    }
}

/// A font recipe that can be resolved at any text scale. Mirrors the
/// subset of the `Font` API the app uses so `.font(x)` call sites migrate to
/// `.scaledFont(x)` unchanged.
struct AerioFont {
    enum Base {
        case fixed(CGFloat)
        case style(Font.TextStyle)
    }

    var base: Base
    var weightValue: Font.Weight? = nil
    var design: Font.Design? = nil
    var isBold = false
    var isItalic = false
    var isMonospacedDigit = false
    var isMonospaced = false
    /// Secondary text: also multiplied by Settings > Appearance > Subtext Size.
    var isSubtext = false

    // MARK: Constructors (same shapes as Font)

    static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> AerioFont {
        AerioFont(base: .fixed(size), weightValue: weight, design: design)
    }

    static func system(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> AerioFont {
        AerioFont(base: .style(style), weightValue: weight, design: design)
    }

    // MARK: Text styles

    static var largeTitle: AerioFont { .system(.largeTitle) }
    static var title: AerioFont { .system(.title) }
    static var title2: AerioFont { .system(.title2) }
    static var title3: AerioFont { .system(.title3) }
    static var headline: AerioFont { .system(.headline) }
    static var subheadline: AerioFont { .system(.subheadline) }
    static var body: AerioFont { .system(.body) }
    static var callout: AerioFont { .system(.callout) }
    static var footnote: AerioFont { .system(.footnote) }
    static var caption: AerioFont { .system(.caption) }
    static var caption2: AerioFont { .system(.caption2) }

    // MARK: Design tokens

    #if os(tvOS)
    // Display (tvOS, viewed from ~10 ft)
    static var displayLarge: AerioFont  { .system(size: 52, weight: .bold, design: .default) }
    static var displayMedium: AerioFont { .system(size: 42, weight: .bold, design: .default) }
    static var displaySmall: AerioFont  { .system(size: 34, weight: .bold, design: .default) }
    // Headlines
    static var headlineLarge: AerioFont  { .system(size: 32, weight: .semibold, design: .default) }
    static var headlineMedium: AerioFont { .system(size: 28, weight: .semibold, design: .default) }
    static var headlineSmall: AerioFont  { .system(size: 24, weight: .semibold, design: .default) }
    // Body
    static var bodyLarge: AerioFont  { .system(size: 28, weight: .regular, design: .default) }
    static var bodyMedium: AerioFont { .system(size: 24, weight: .regular, design: .default) }
    static var bodySmall: AerioFont  { .system(size: 22, weight: .regular, design: .default) }
    // Labels
    static var labelLarge: AerioFont  { .system(size: 22, weight: .medium, design: .default) }
    static var labelMedium: AerioFont { .system(size: 20, weight: .medium, design: .default) }
    static var labelSmall: AerioFont  { .system(size: 18, weight: .medium, design: .default) }
    // Monospaced (URLs, ports, etc.)
    static var monoMedium: AerioFont { .system(size: 22, weight: .regular, design: .monospaced) }
    static var monoSmall: AerioFont  { .system(size: 20, weight: .regular, design: .monospaced) }
    #else
    // Display (iOS / iPadOS / Mac Catalyst)
    static var displayLarge: AerioFont  { .system(size: 34, weight: .bold, design: .default) }
    static var displayMedium: AerioFont { .system(size: 28, weight: .bold, design: .default) }
    static var displaySmall: AerioFont  { .system(size: 22, weight: .bold, design: .default) }
    // Headlines
    static var headlineLarge: AerioFont  { .system(size: 20, weight: .semibold, design: .default) }
    static var headlineMedium: AerioFont { .system(size: 17, weight: .semibold, design: .default) }
    static var headlineSmall: AerioFont  { .system(size: 15, weight: .semibold, design: .default) }
    // Body
    static var bodyLarge: AerioFont  { .system(size: 17, weight: .regular, design: .default) }
    static var bodyMedium: AerioFont { .system(size: 15, weight: .regular, design: .default) }
    static var bodySmall: AerioFont  { .system(size: 13, weight: .regular, design: .default) }
    // Labels
    static var labelLarge: AerioFont  { .system(size: 13, weight: .medium, design: .default) }
    static var labelMedium: AerioFont { .system(size: 12, weight: .medium, design: .default) }
    static var labelSmall: AerioFont  { .system(size: 11, weight: .medium, design: .default) }
    // Monospaced (URLs, ports, etc.)
    static var monoMedium: AerioFont { .system(size: 14, weight: .regular, design: .monospaced) }
    static var monoSmall: AerioFont  { .system(size: 12, weight: .regular, design: .monospaced) }
    #endif

    // MARK: Modifiers (same names as Font)

    func weight(_ weight: Font.Weight) -> AerioFont { var c = self; c.weightValue = weight; return c }
    func bold() -> AerioFont { var c = self; c.isBold = true; return c }
    func italic() -> AerioFont { var c = self; c.isItalic = true; return c }
    func monospacedDigit() -> AerioFont { var c = self; c.isMonospacedDigit = true; return c }
    func monospaced() -> AerioFont { var c = self; c.isMonospaced = true; return c }
    /// Marks the recipe as secondary text so Subtext Size scales it too.
    func subtext() -> AerioFont { var c = self; c.isSubtext = true; return c }

    // MARK: Resolution

    /// The font at the designed size (text scale 100%). No UIKit lookups,
    /// so it is safe from any isolation context.
    var font: Font {
        var f: Font
        switch base {
        case .fixed(let size):
            f = .system(size: size, weight: weightValue ?? .regular, design: design ?? .default)
        case .style(let style):
            f = .system(style, design: design)
            if let w = weightValue { f = f.weight(w) }
        }
        return applyTraits(f)
    }

    private func applyTraits(_ font: Font) -> Font {
        var f = font
        if isBold { f = f.bold() }
        if isItalic { f = f.italic() }
        if isMonospacedDigit { f = f.monospacedDigit() }
        if isMonospaced { f = f.monospaced() }
        return f
    }

    /// Point size this recipe draws at for a given scale, for UIKit
    /// measurement and for layout metrics that must track the text.
    @MainActor
    func pointSize(scale: CGFloat, dynamicTypeSize: DynamicTypeSize = .large) -> CGFloat {
        switch base {
        case .fixed(let size):
            return size * scale
        case .style(let style):
            return Self.systemPointSize(for: style, dynamicTypeSize: dynamicTypeSize) * scale
        }
    }

    @MainActor
    func resolved(scale: CGFloat, dynamicTypeSize: DynamicTypeSize) -> Font {
        // 100%: identical to the pre-feature `.font(...)`.
        if abs(scale - 1) < 0.001 { return font }
        let f: Font
        switch base {
        case .fixed(let size):
            f = .system(size: size * scale,
                        weight: weightValue ?? .regular,
                        design: design ?? .default)
        case .style(let style):
            let size = Self.systemPointSize(for: style, dynamicTypeSize: dynamicTypeSize) * scale
            f = .system(size: size,
                        weight: weightValue ?? Self.defaultWeight(for: style),
                        design: design ?? .default)
        }
        return applyTraits(f)
    }

    private static func defaultWeight(for style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }

    @MainActor
    private static func systemPointSize(for style: Font.TextStyle, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let uiStyle: UIFont.TextStyle
        switch style {
        case .largeTitle:
            #if os(tvOS)
            uiStyle = .title1
            #else
            uiStyle = .largeTitle
            #endif
        case .title: uiStyle = .title1
        case .title2: uiStyle = .title2
        case .title3: uiStyle = .title3
        case .headline: uiStyle = .headline
        case .subheadline: uiStyle = .subheadline
        case .body: uiStyle = .body
        case .callout: uiStyle = .callout
        case .footnote: uiStyle = .footnote
        case .caption: uiStyle = .caption1
        case .caption2: uiStyle = .caption2
        @unknown default: uiStyle = .body
        }
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory(for: dynamicTypeSize))
        return UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: traits).pointSize
    }
}

private func contentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
    switch size {
    case .xSmall: return .extraSmall
    case .small: return .small
    case .medium: return .medium
    case .large: return .large
    case .xLarge: return .extraLarge
    case .xxLarge: return .extraExtraLarge
    case .xxxLarge: return .extraExtraExtraLarge
    case .accessibility1: return .accessibilityMedium
    case .accessibility2: return .accessibilityLarge
    case .accessibility3: return .accessibilityExtraLarge
    case .accessibility4: return .accessibilityExtraExtraLarge
    case .accessibility5: return .accessibilityExtraExtraExtraLarge
    @unknown default: return .large
    }
}

private struct ScaledFontModifier: ViewModifier {
    let font: AerioFont
    @Environment(\.aerioTextScale) private var scale
    @Environment(\.aerioSubtextScale) private var subtextScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let effective = font.isSubtext ? scale * subtextScale : scale
        return content.font(font.resolved(scale: effective, dynamicTypeSize: dynamicTypeSize))
    }
}

extension View {
    /// `.font(_:)` that honors Settings > Appearance > Text Size.
    func scaledFont(_ font: AerioFont) -> some View {
        modifier(ScaledFontModifier(font: font))
    }

    /// Injects the persisted text scale. Apply once at the app root and on
    /// any SwiftUI tree hosted in a UIHostingController.
    func aerioTextScaleRoot(_ scale: Double) -> some View {
        environment(\.aerioTextScale, CGFloat(TextScale.clamp(scale)))
    }

    /// Injects Subtext Size and Text Contrast. Apply once at the app root.
    func aerioSecondaryTextRoot(subtextScale: Double, contrast: Double) -> some View {
        self
            .environment(\.aerioSubtextScale, CGFloat(SubtextScale.clamp(subtextScale)))
            .environment(\.aerioTextContrast, TextContrast.clamp(contrast))
    }
}

extension Text {
    /// For `Text` concatenation (`Text + Text`), where a `View` modifier
    /// would lose the `Text` type. The caller reads `aerioTextScale`.
    @MainActor
    func scaledFont(_ font: AerioFont, scale: CGFloat) -> Text {
        let effective = font.isSubtext ? scale * SubtextScale.stored : scale
        return self.font(font.resolved(scale: effective, dynamicTypeSize: .large))
    }
}

// MARK: - Unscaled design tokens
//
// Kept for the rare place that needs a raw `Font` at the designed size.
// Text on screen should use `.scaledFont(.token)` instead.
extension Font {
    static var displayLarge: Font  { AerioFont.displayLarge.font }
    static var displayMedium: Font { AerioFont.displayMedium.font }
    static var displaySmall: Font  { AerioFont.displaySmall.font }
    static var headlineLarge: Font  { AerioFont.headlineLarge.font }
    static var headlineMedium: Font { AerioFont.headlineMedium.font }
    static var headlineSmall: Font  { AerioFont.headlineSmall.font }
    static var bodyLarge: Font  { AerioFont.bodyLarge.font }
    static var bodyMedium: Font { AerioFont.bodyMedium.font }
    static var bodySmall: Font  { AerioFont.bodySmall.font }
    static var labelLarge: Font  { AerioFont.labelLarge.font }
    static var labelMedium: Font { AerioFont.labelMedium.font }
    static var labelSmall: Font  { AerioFont.labelSmall.font }
    static var monoMedium: Font { AerioFont.monoMedium.font }
    static var monoSmall: Font  { AerioFont.monoSmall.font }
}

// MARK: - Text Style Modifiers
struct DisplayTextStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scaledFont(.displayMedium)
            .foregroundColor(.textPrimary)
    }
}

struct SectionHeaderStyle: ViewModifier {
    // Storing the color as a property lets SwiftUI's diff detect when it changes
    // so body(content:) is re-called and the foreground color updates.
    let color: Color
    func body(content: Content) -> some View {
        content
            .scaledFont(.labelLarge)
            .foregroundColor(color)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

/// Theme-reactive wrapper that observes `ThemeManager` and re-applies
/// `SectionHeaderStyle` with the current accent-derived `.textSecondary`
/// every time the theme changes.
///
/// We can't put `@ObservedObject` on a `ViewModifier`, so the older
/// `.sectionHeaderStyle()` extension would freeze its `Color` argument
/// inside SwiftUI List cells — the cell content didn't refresh on theme
/// changes (Mac Catalyst especially). Wrapping the styled `Text` in a
/// `View` struct lets us subscribe to `ThemeManager.objectWillChange`,
/// which forces a body re-evaluation that picks up the fresh accent.
private struct ThemeReactiveSectionHeader<Content: View>: View {
    @ObservedObject private var theme = ThemeManager.shared
    let content: Content
    var body: some View {
        // Read theme.accent so SwiftUI's dependency tracker registers
        // the property — opacity is applied here (not via the static
        // `Color.textSecondary` accessor) so the resulting `Color`
        // changes structurally on every theme push, ensuring the
        // .foregroundColor modifier re-applies inside cached cells.
        let derived: Color = {
            #if os(tvOS)
            return theme.accent.opacity(0.75)
            #else
            return theme.accent.opacity(0.65)
            #endif
        }()
        // Text Contrast blends the accent header toward white / black.
        return content.modifier(SectionHeaderStyle(color: Color.contrastText(derived)))
    }
}

extension View {
    func displayStyle() -> some View { modifier(DisplayTextStyle()) }
    /// Theme-reactive section header. See `ThemeReactiveSectionHeader`
    /// for why this is a wrapping `View` rather than a plain modifier.
    func sectionHeaderStyle() -> some View {
        ThemeReactiveSectionHeader(content: self)
    }
}
