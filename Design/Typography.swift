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

extension View {
    func displayStyle() -> some View { modifier(DisplayTextStyle()) }
    func sectionHeaderStyle() -> some View { modifier(SectionHeaderStyle(color: .textSecondary)) }
}
