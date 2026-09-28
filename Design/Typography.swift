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

// MARK: - Rounded Corners on Logos and Artwork (Settings > Appearance)
//
// One app-wide toggle (Settings > Appearance, "Rounded corners on logos and
// artwork") that decides whether channel logos and program artwork are
// clipped to rounded corners or left square.
//
// The rule, per Logan 2026-09-16: when the toggle is ON a logo or a piece of
// program art takes the corner radius of the CELL OR CARD IT SITS IN, not a
// value of its own. A row card rounded at 12 rounds its logo at 12; the
// in-player info card rounded at 14 rounds its logo at 14; an image sitting
// in a container with no rounding at all (the guide's channel column cell,
// the tvOS guide preview strip) stays square whatever the toggle says.
// When the toggle is OFF every one of them is square.
//
// Call sites therefore pass the radius of their OWN container, and this one
// helper decides whether it is honored or zeroed. There is no second place
// that knows about logo corners.
//
// Movies, TV Shows and DVR poster art are deliberately NOT covered: those
// grids have their own poster shape and are out of this toggle's scope.
// MARK: - Live TV List view availability (tvOS)
//
// Logan 2026-09-16: the Live TV LIST view is removed from the Apple TV UI
// entirely because it is unusable with a remote. The Guide is the only Live
// TV presentation on tvOS. The list code is intentionally KEPT and only
// gated, so flipping this single flag back to `true` restores every entry
// point (the view-mode controls, the Settings > App Behaviors "Default Live
// TV View" option, and the list-only Appearance rows) exactly as it was.
//
// Nothing here touches persisted state: `defaultLiveTVView` keeps whatever
// the user chose, and a stored value of "list" simply resolves to Guide at
// runtime while this flag is off. iPhone and iPad are unaffected; the flag
// is only consulted from tvOS code paths. Android carries the identical
// change and the identical labels.
enum TVListView {
    /// `false` = Apple TV shows the Guide only. Set to `true` to bring the
    /// List view and all of its entry points back.
    static let enabled = false
}

enum LogoCorners {
    /// Settings > Appearance > "Rounded corners in List view". Governs the
    /// Live TV list rows and every other CARD surface on the shared rule:
    /// the in-player info card, the in-player channel picker, the multiview
    /// compact row and Program Info art reached from the list. The guide's
    /// own surfaces moved to `guideKey` (Logan 2026-09-16).
    /// Synced through iCloud alongside the other app-wide Appearance
    /// preferences (see `SyncManager`).
    static let listKey = "ui.roundedLogoCornersList"

    /// Settings > Appearance > "Rounded corners in Guide view". Governs
    /// every GUIDE surface at `guideRadius`: the guide's channel column
    /// logo, the guide preview banner's program art, and the Program Info
    /// sheet's art when that sheet was opened from the guide (Logan
    /// 2026-09-16, rev 2). Default OFF: the guide is a flat rail and a flat
    /// strip, not a card. The same sheet reached from the Live TV list, the
    /// in-player info card, the channel picker and the multiview row stay on
    /// the List toggle.
    static let guideKey = "ui.roundedLogoCornersGuide"

    /// The single toggle both keys were split out of. Read once by
    /// `migrateLegacyKeyIfNeeded()` so nobody's current choice changes, then
    /// left alone. Still the key `SyncManager` carried before the split.
    static let legacyKey = "ui.roundedLogoCorners"

    /// List default ON, so an existing install keeps the shipped look.
    static let listDefault = true
    /// Guide default OFF.
    static let guideDefault = false

    /// Radius the guide surfaces use when the Guide toggle is on: small,
    /// because neither the channel column nor the preview banner has a card
    /// behind the art to be concentric with. Still subject to the shared
    /// tile test and the 25% cap below.
    static let guideRadius: CGFloat = 6

    /// Copies a pre-split choice into the List key, once. Called at app
    /// launch before any view reads the environment.
    static func migrateLegacyKeyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: listKey) == nil,
              let legacy = defaults.object(forKey: legacyKey) as? Bool else { return }
        defaults.set(legacy, forKey: listKey)
    }

    /// Current List value straight from `UserDefaults`, for the environment
    /// default and for non-SwiftUI readers. Falls back to a pre-split value
    /// so a first read before migration still honors the user's choice.
    static var storedList: Bool {
        let defaults = UserDefaults.standard
        return (defaults.object(forKey: listKey) as? Bool)
            ?? (defaults.object(forKey: legacyKey) as? Bool)
            ?? listDefault
    }

    /// Current Guide value.
    static var storedGuide: Bool {
        UserDefaults.standard.object(forKey: guideKey) as? Bool ?? guideDefault
    }

    /// Never let a logo become a circle or a pill: a radius may not exceed
    /// this fraction of the drawn image's SHORTER side. A 26pt tall logo in
    /// a 12pt card therefore rounds at 6.5, not 12 (Logan 2026-09-16, iPhone
    /// list row: the raw card radius turned small logos into circles).
    static let maxRadiusFraction: CGFloat = 0.25

    /// The size an image of `image` points draws at when fitted (never
    /// cropped) inside `slot`. One definition for every surface, so the clip
    /// always hugs the ART's bounds and not the slot's letterbox space.
    static func fitted(image: CGSize, in slot: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0,
              slot.width > 0, slot.height > 0 else { return slot }
        let scale = min(slot.width / image.width, slot.height / image.height)
        return CGSize(width: (image.width * scale).rounded(),
                      height: (image.height * scale).rounded())
    }

    /// THE rounding rule. Every artwork surface the toggle covers calls this
    /// one function rather than clipping on its own (Logan 2026-09-16).
    ///
    /// - Toggle off: square, always.
    /// - Toggle on: round only a TILE, i.e. opaque artwork that reaches its
    ///   own corners (the event logos). A FLOATING logo, transparent around
    ///   its edges (NBC Sports Now and most channel marks), shares no corner
    ///   with anything and stays square. `LogoTileTest` decides, from the
    ///   decoded image's corner alpha.
    /// - The radius is the CONTAINER's, capped at `maxRadiusFraction` of the
    ///   drawn image's shorter side, so a short wide tile never reads as a
    ///   pill or a circle.
    ///
    /// An earlier version decided this geometrically ("does the fitted image
    /// fill the slot on both axes"). That was wrong on device: a fitted image
    /// only fills both axes when its aspect happens to match the slot's, so a
    /// few event logos rounded by coincidence and the rest did not (Logan
    /// 2026-09-16, iPhone). Opacity, not aspect, is the real distinction.
    static func imageRadius(container: CGFloat,
                            fitted: CGSize,
                            isTile: Bool,
                            enabled: Bool) -> CGFloat {
        guard enabled, container > 0, isTile else { return 0 }
        let shorter = min(fitted.width, fitted.height)
        guard shorter > 0 else { return 0 }
        return max(0, min(container, shorter * maxRadiusFraction))
    }

    /// Convenience for a surface that already knows its drawn art's shorter
    /// side (a square logo tile, a placeholder, a slot sized to the art's own
    /// aspect). Same rule, same verdict input.
    static func radius(container: CGFloat,
                       imageShorterSide: CGFloat,
                       isTile: Bool,
                       enabled: Bool) -> CGFloat {
        imageRadius(container: container,
                    fitted: CGSize(width: imageShorterSide, height: imageShorterSide),
                    isTile: isTile,
                    enabled: enabled)
    }
}

// MARK: - Tile vs. floating logo
//
// The rounded-corner toggle may only round artwork that actually reaches its
// own corners. Channel logos come in two shapes and the difference is
// opacity, not aspect (Logan 2026-09-16, iPhone: a geometric "does it fill
// the slot" test rounded a handful of event logos by coincidence and missed
// every other one):
//
//   TILE      opaque to all four corners (event logos, network bugs on a
//             solid plate). Rounds.
//   FLOATING  transparent around its edges (NBC Sports Now and most channel
//             marks). Shares no corner with anything, so it stays square.
//
// The verdict is sampled ONCE per image, off a 24x24 downscaled copy drawn
// into a tiny CGContext, and cached by URL, so scrolling never re-samples.
@MainActor
enum LogoTileTest {
    /// Alpha at or above this counts as opaque. `nonisolated` along with
    /// `sample(_:)`, which runs on a background task.
    nonisolated static let opaqueAlpha: CGFloat = 0.9
    /// Edge of the downscaled copy the corners are read from.
    nonisolated private static let sampleEdge = 24
    /// Patch read at each corner, in downscaled pixels (3x3).
    nonisolated private static let patch = 3

    private static var cache: [String: Bool] = [:]

    /// The cached verdict for an image URL, or nil if it has not been
    /// sampled yet. Surfaces that never see the decoded bitmap (program art
    /// slots, which draw through `AuthPosterImage`) read this and treat an
    /// unknown image as a tile: program art is opaque photography, and the
    /// verdict sharpens as soon as any surface decodes the same URL.
    static func cachedVerdict(for url: URL?) -> Bool? {
        guard let url else { return nil }
        return cache[url.absoluteString]
    }

    /// The cached verdict for a key, without sampling.
    static func cached(_ key: String) -> Bool? { cache[key] }

    /// Records a verdict sampled off the main thread by `sample(_:)`.
    static func record(_ value: Bool, for key: String) { cache[key] = value }

    /// The verdict for a decoded image, sampling it the first time only.
    /// Prefer `sample(_:)` on a background task plus `record(_:for:)`: the
    /// sampling draws a bitmap, and a cache miss on the main actor during a
    /// fast flick showed up as a main-runloop hang (Logan 2026-09-16).
    static func verdict(for key: String, image: UIImage) -> Bool {
        if let hit = cache[key] { return hit }
        let value = sample(image)
        cache[key] = value
        return value
    }

    /// True when all four corners (the corner pixel plus a 3x3 patch just
    /// inside it) are opaque. An image with no alpha channel is a tile by
    /// definition and is never drawn.
    nonisolated static func sample(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }
        let edge = sampleEdge
        var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: edge,
                                      height: edge,
                                      bitsPerComponent: 8,
                                      bytesPerRow: edge * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: edge, height: edge))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        // Undecidable (context allocation failed): treat as floating, which
        // is the conservative half of the rule - a square logo is never wrong
        // looking, a wrongly rounded one is.
        guard ok else { return false }

        let threshold = UInt8(clamping: Int((opaqueAlpha * 255).rounded()))
        let starts = [0, edge - patch]
        for originY in starts {
            for originX in starts {
                for dy in 0..<patch {
                    for dx in 0..<patch {
                        let x = originX + dx
                        let y = originY + dy
                        let alpha = pixels[(y * edge + x) * 4 + 3]
                        if alpha < threshold { return false }
                    }
                }
            }
        }
        return true
    }
}

private struct AerioRoundedLogoCornersKey: EnvironmentKey {
    static var defaultValue: Bool { LogoCorners.storedList }
}

private struct AerioRoundedGuideCornersKey: EnvironmentKey {
    static var defaultValue: Bool { LogoCorners.storedGuide }
}

extension EnvironmentValues {
    /// Settings > Appearance > "Rounded corners in List view". Read by
    /// `CachedLogoImage`, `ProgramArtSlot` and the few call sites that clip
    /// a logo themselves.
    var aerioRoundedLogoCorners: Bool {
        get { self[AerioRoundedLogoCornersKey.self] }
        set { self[AerioRoundedLogoCornersKey.self] = newValue }
    }

    /// Settings > Appearance > "Rounded corners in Guide view". Read by the
    /// guide's channel column (through `ChannelBadge`) and by the guide's
    /// program art (through `ProgramArtSlot(usesGuideCorners:)`).
    var aerioRoundedGuideCorners: Bool {
        get { self[AerioRoundedGuideCornersKey.self] }
        set { self[AerioRoundedGuideCornersKey.self] = newValue }
    }
}

extension View {
    /// Injects both persisted corner preferences. Apply once at the app
    /// root, next to `aerioTextScaleRoot`.
    func aerioLogoCornersRoot(list: Bool, guide: Bool) -> some View {
        environment(\.aerioRoundedLogoCorners, list)
            .environment(\.aerioRoundedGuideCorners, guide)
    }

}

// MARK: - Channel Number Column (Live TV list, in-player picker)
//
// The channel-number column used to be a hard-coded point width (26 on
// iPhone, 36 on iPad, 42 on tvOS). Those numbers were chosen when channel
// numbers were two or three digits; a four-digit number like 1500 already
// truncated to "15..." at 100% Text Size, and Dispatcharr also hands out
// sub-channel numbers in the "1500.5" form (Logan 2026-09-16, iPhone list
// with numbers shown and names hidden).
//
// The column is now MEASURED: the list finds the widest number it is about
// to show, and every row sizes its column to that many monospaced
// characters at the row's actual rendered point size. Monospaced digits all
// share one advance, so character count is an exact proxy for width, and
// every row in a list gets the SAME column width, so the logos stay aligned.
// The number is single line and never truncates or wraps.
@MainActor
enum ChannelNumberColumn {
    /// Floor: a list of single-digit channels still leaves room for four,
    /// so the column does not visibly jump as the user filters groups.
    static let minimumCharacters = 4
    /// Ceiling, so one absurd provider number cannot eat the whole row.
    static let maximumCharacters = 8

    /// Widest number in a list, in characters, clamped to the range above.
    /// Stops scanning as soon as it hits the ceiling, so a long channel list
    /// costs almost nothing per render.
    static func characters(in numbers: some Sequence<String>) -> Int {
        var widest = minimumCharacters
        for number in numbers {
            let count = number.count
            if count > widest {
                widest = min(count, maximumCharacters)
                if widest == maximumCharacters { break }
            }
        }
        return widest
    }

    /// Height of one line of the number in the monospaced number style, so a
    /// stacked leading column can subtract it from the logo's share of the
    /// row without measuring a second geometry.
    /// Memoized for the same reason `ChannelRowTextColumn.lineHeight` is: the
    /// guide column's badge asks for this on EVERY body evaluation, and a
    /// `UIFont` lookup per badge per press showed up as guide navigation lag
    /// on Apple TV (1.8.40). The answer only moves when Text Size does.
    static func lineHeight(fontSize: CGFloat, weight: UIFont.Weight = .bold) -> CGFloat {
        let points = max(1, fontSize)
        // Quarter-point buckets: finer than any visible difference, coarse
        // enough that a slider drag settles on a handful of entries.
        let key = Int((points * 4).rounded()) &* 16 &+ Int(weight.rawValue * 8)
        if let hit = lineCache[key] { return hit }
        let value = UIFont.monospacedSystemFont(ofSize: points, weight: weight)
            .lineHeight.rounded(.up)
        lineCache[key] = value
        return value
    }

    private static var lineCache: [Int: CGFloat] = [:]
    private static var cache: [String: CGFloat] = [:]

    /// Width of `characters` monospaced digits at `fontSize`.
    ///
    /// `fontSize` must be the size actually RENDERED, i.e. the call site's
    /// base size already multiplied by the Live TV List scale and by Text
    /// Size. Pass it through `max(1, textScale)` the way `TextScale.grow`
    /// does, so a container never shrinks below its designed width at 85%.
    static func width(characters: Int, fontSize: CGFloat, weight: UIFont.Weight = .bold) -> CGFloat {
        let chars = max(1, characters)
        let size = max(1, fontSize)
        let key = "\(chars)|\(Int(size.rounded()))|\(weight.rawValue)"
        if let hit = cache[key] { return hit }
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        let sample = String(repeating: "0", count: chars)
        let measured = (sample as NSString).size(withAttributes: [.font: font]).width
        let value = measured.rounded(.up)
        cache[key] = value
        return value
    }
}

// MARK: - Channel Row Height (Live TV list)
//
// Every Live TV list row is the SAME height: the height of the tallest
// layout a row can have (channel name, program title, subtitle line, two
// description lines, progress bar). A row with less text keeps that height
// and leaves the unused lines blank instead of collapsing (Logan
// 2026-09-16, iPhone, MLB group: rows with more text drew a bigger logo,
// because the logo was sized from the row).
//
// The height is DERIVED from the same font metrics the row draws with, at
// the current Text Size and Subtext Size, not hardcoded, so 150% Text Size
// still fits every line.
@MainActor
enum ChannelRowTextColumn {
    /// Memoized: a row body asks for its height on EVERY evaluation, and the
    /// answer only changes when Text Size, Subtext Size or the display scale
    /// does. Building five `UIFont`s per row per body showed up in the
    /// iPhone flick profile (Logan 2026-09-16), so both the per-line metric
    /// and the finished height are cached.
    private static var lineCache: [Int: CGFloat] = [:]
    private static var heightCache: [String: CGFloat] = [:]

    /// One line of the system font at a rendered point size.
    static func lineHeight(_ size: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        let points = max(1, size)
        // Quarter-point buckets: finer than any visible difference, coarse
        // enough that a slider drag settles on a handful of entries.
        let key = Int((points * 4).rounded()) &* 16 &+ Int(weight.rawValue * 8)
        if let hit = lineCache[key] { return hit }
        let value = UIFont.systemFont(ofSize: points, weight: weight).lineHeight.rounded(.up)
        lineCache[key] = value
        return value
    }

    /// Cache key for a row shape.
    private static func key(_ parts: [CGFloat], _ flags: [Bool]) -> String {
        parts.map { String(Int(($0 * 100).rounded())) }.joined(separator: ",")
            + "|" + flags.map { $0 ? "1" : "0" }.joined()
    }

    /// tvOS row: name 26 semibold, title in a 28pt grown box, 18pt subtitle,
    /// two 18pt description lines, 5pt progress bar with a 4pt top padding,
    /// 4pt VStack spacing between the five children.
    static func tvOSHeight(showName: Bool,
                           showSubtitle: Bool,
                           textScale: CGFloat,
                           subtextScale: CGFloat) -> CGFloat {
        let cacheKey = "tv|" + key([textScale, subtextScale], [showName, showSubtitle])
        if let hit = heightCache[cacheKey] { return hit }
        let gap: CGFloat = 4
        let sub = textScale * subtextScale
        var height: CGFloat = 0
        var children = 0
        if showName {
            height += lineHeight(26 * textScale, weight: .semibold); children += 1
        }
        height += TextScale.grow(28, sub); children += 1
        if showSubtitle {
            height += lineHeight(18 * sub, weight: .regular); children += 1
        }
        height += 2 * lineHeight(18 * sub, weight: .regular); children += 1
        height += 5 + 4; children += 1
        let total = (height + gap * CGFloat(max(0, children - 1))).rounded(.up)
        heightCache[cacheKey] = total
        return total
    }

    /// iPhone / iPad row. `s` is the Live TV List display scale; `isWide` is
    /// the iPad branch. Mirrors `iOSRow` line for line.
    static func iOSHeight(isWide: Bool,
                          scale s: CGFloat,
                          showName: Bool,
                          showSubtitle: Bool,
                          textScale: CGFloat,
                          subtextScale: CGFloat) -> CGFloat {
        let cacheKey = "ios|" + key([s, textScale, subtextScale], [isWide, showName, showSubtitle])
        if let hit = heightCache[cacheKey] { return hit }
        let gap = (isWide ? 4 : 2) * s
        let sub = textScale * subtextScale
        let bodySize = (isWide ? 12 : 10) * s * sub
        var height: CGFloat = 0
        var children = 0
        if showName {
            height += lineHeight((isWide ? 17 : 15) * s * textScale, weight: .medium); children += 1
        }
        height += TextScale.grow((isWide ? 20 : 16) * s, sub); children += 1
        if showSubtitle {
            height += lineHeight(bodySize); children += 1
        }
        height += 2 * lineHeight(bodySize); children += 1
        height += 3; children += 1
        let total = (height + gap * CGFloat(max(0, children - 1))).rounded(.up)
        heightCache[cacheKey] = total
        return total
    }
}

private struct AerioChannelNumberCharsKey: EnvironmentKey {
    /// Mirrors `ChannelNumberColumn.minimumCharacters`; spelled out here
    /// because an `EnvironmentKey` default is evaluated off the main actor.
    static var defaultValue: Int { 4 }
}

extension EnvironmentValues {
    /// Character count the channel-number column must fit, published by the
    /// Live TV list (and the in-player picker) from the channels it is
    /// showing, so every row lands on one width. See `ChannelNumberColumn`.
    var aerioChannelNumberChars: Int {
        get { self[AerioChannelNumberCharsKey.self] }
        set { self[AerioChannelNumberCharsKey.self] = newValue }
    }
}
