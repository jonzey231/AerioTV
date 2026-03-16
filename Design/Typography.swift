import SwiftUI

extension Font {
    // MARK: - Display
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
    func body(content: Content) -> some View {
        content
            .font(.labelLarge)
            .foregroundColor(.textSecondary)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

extension View {
    func displayStyle() -> some View { modifier(DisplayTextStyle()) }
    func sectionHeaderStyle() -> some View { modifier(SectionHeaderStyle()) }
}
