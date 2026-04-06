import SwiftUI

// MARK: - Aerio Brand Colors
// Key surface and accent colors are DYNAMIC — they read from ThemeManager.shared so
// every view automatically reflects the user's chosen theme without needing to
// observe ThemeManager directly.  Text/border/status colors remain static.
extension Color {
    // MARK: Dynamic (theme-aware) surfaces
    /// App-level dark background — changes with selected theme.
    static var appBackground:      Color { ThemeManager.shared.background }
    /// Card / list row background — changes with selected theme.
    static var cardBackground:     Color { ThemeManager.shared.card }
    /// Slightly elevated surface (drawers, sheets) — derived from card.
    static var elevatedBackground: Color { ThemeManager.shared.card }
    /// Sheet / modal background — mirrors app background.
    static var sheetBackground:    Color { ThemeManager.shared.background }

    // MARK: Dynamic accents
    /// Primary accent — the brand/theme color used for highlights, icons, and tints.
    static var accentPrimary:   Color { ThemeManager.shared.accent }
    /// Secondary accent — slightly muted version of the primary.
    static var accentSecondary: Color { ThemeManager.shared.accentSecondary }
    /// Dim accent — low-opacity fill, e.g. icon badge backgrounds.
    static var accentDim:       Color { ThemeManager.shared.accent.opacity(0.22) }

    // MARK: Text — derived from accent so they complement any theme
    /// Primary text — near-white, works on all dark backgrounds.
    static let textPrimary = Color(hex: "E8F4F8")
    /// Secondary text — accent-tinted at medium opacity (≈ muted teal on default theme).
    #if os(tvOS)
    static var textSecondary: Color { ThemeManager.shared.accent.opacity(0.75) }
    #else
    static var textSecondary: Color { ThemeManager.shared.accent.opacity(0.65) }
    #endif
    /// Tertiary text — accent-tinted at low opacity for hints, labels, etc.
    #if os(tvOS)
    static var textTertiary:  Color { ThemeManager.shared.accent.opacity(0.45) }
    #else
    static var textTertiary:  Color { ThemeManager.shared.accent.opacity(0.28) }
    #endif

    // Borders — accent-tinted so dividers stay visually coherent with the theme
    static var borderSubtle: Color { ThemeManager.shared.accent.opacity(0.10) }
    static var borderMedium: Color { ThemeManager.shared.accent.opacity(0.18) }

    // Status
    static let statusLive    = Color(hex: "FF4757")
    /// "Online" indicator — follows the accent so it matches the active theme.
    static var statusOnline: Color { ThemeManager.shared.accent }
    static let statusWarning = Color(hex: "FFA502")
    /// Offline indicator — dim accent tint, always complementary to the theme.
    static var statusOffline: Color { ThemeManager.shared.accent.opacity(0.22) }

    // Server type colors — dynamic so they match the active theme
    static var xtreamColor:      Color { ThemeManager.shared.accentSecondary }
    static var dispatcharrColor: Color { ThemeManager.shared.accent }
    static let plexColor        = Color(hex: "E5A00D")

    // MARK: Hex conversion (used by ColorPicker → ThemeManager)
    /// Returns an uppercase 6-character hex string, e.g. "2DD4BF".
    func toHex() -> String {
#if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
#else
        // macOS / tvOS fallback
        return "2DD4BF"
#endif
    }

    // Hex initializer
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// MARK: - Gradients
extension LinearGradient {
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [.accentPrimary, .accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    static let cardOverlay = LinearGradient(
        colors: [Color.clear, Color.appBackground.opacity(0.8)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let heroOverlay = LinearGradient(
        colors: [Color.clear, Color.appBackground],
        startPoint: .center,
        endPoint: .bottom
    )
}

// MARK: - Glass Effect Helper
struct GlassBackground: ViewModifier {
    var tint: Color = .accentPrimary
    var opacity: Double = 0.06
    var border: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    tint.opacity(opacity)
                }
            }
            .overlay {
                if border {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                }
            }
    }
}

extension View {
    func glassCard(tint: Color = .accentPrimary, opacity: Double = 0.06, border: Bool = true) -> some View {
        modifier(GlassBackground(tint: tint, opacity: opacity, border: border))
    }
}
