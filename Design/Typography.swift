import SwiftUI

extension Font {
    #if os(tvOS)
    // MARK: - Display (tvOS – viewed from ~10 ft)
    static let displayLarge  = Font.system(size: 52, weight: .bold, design: .default)
    static let displayMedium = Font.system(size: 42, weight: .bold, design: .default)
    static let displaySmall  = Font.system(size: 34, weight: .bold, design: .default)

    // MARK: - Headlines
    static let headlineLarge  = Font.system(size: 32, weight: .semibold, design: .default)
    static let headlineMedium = Font.system(size: 28, weight: .semibold, design: .default)
    static let headlineSmall  = Font.system(size: 24, weight: .semibold, design: .default)

    // MARK: - Body
    static let bodyLarge  = Font.system(size: 28, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 24, weight: .regular, design: .default)
    static let bodySmall  = Font.system(size: 22, weight: .regular, design: .default)

    // MARK: - Labels
    static let labelLarge  = Font.system(size: 22, weight: .medium, design: .default)
    static let labelMedium = Font.system(size: 20, weight: .medium, design: .default)
    static let labelSmall  = Font.system(size: 18, weight: .medium, design: .default)

    // MARK: - Monospaced (for URLs, ports, etc.)
    static let monoMedium = Font.system(size: 22, weight: .regular, design: .monospaced)
    static let monoSmall  = Font.system(size: 20, weight: .regular, design: .monospaced)

    #else
    // MARK: - Display (iOS / iPadOS / macOS)
    static let displayLarge  = Font.system(size: 34, weight: .bold, design: .default)
    static let displayMedium = Font.system(size: 28, weight: .bold, design: .default)
    static let displaySmall  = Font.system(size: 22, weight: .bold, design: .default)

    // MARK: - Headlines
    static let headlineLarge  = Font.system(size: 20, weight: .semibold, design: .default)
    static let headlineMedium = Font.system(size: 17, weight: .semibold, design: .default)
    static let headlineSmall  = Font.system(size: 15, weight: .semibold, design: .default)

    // MARK: - Body
    static let bodyLarge  = Font.system(size: 17, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 15, weight: .regular, design: .default)
    static let bodySmall  = Font.system(size: 13, weight: .regular, design: .default)

    // MARK: - Labels
    static let labelLarge  = Font.system(size: 13, weight: .medium, design: .default)
    static let labelMedium = Font.system(size: 12, weight: .medium, design: .default)
    static let labelSmall  = Font.system(size: 11, weight: .medium, design: .default)

    // MARK: - Monospaced (for URLs, ports, etc.)
    static let monoMedium = Font.system(size: 14, weight: .regular, design: .monospaced)
    static let monoSmall  = Font.system(size: 12, weight: .regular, design: .monospaced)
    #endif
}

// MARK: - Text Style Modifiers
struct DisplayTextStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.displayMedium)
            .foregroundColor(.textPrimary)
    }
}

struct SectionHeaderStyle: ViewModifier {
    // Storing the color as a property lets SwiftUI's diff detect when it changes
    // so body(content:) is re-called and the foreground color updates.
    let color: Color
    func body(content: Content) -> some View {
        content
            .font(.labelLarge)
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
        return content.modifier(SectionHeaderStyle(color: derived))
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
