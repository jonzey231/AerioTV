import SwiftUI

// MARK: - Dispatcharr Brand Colors
// Static colors are used as fallbacks and for components that can't observe ThemeManager.
// For theme-aware UI, use ThemeManager.shared.accent / .background / .card directly.
extension Color {
    // Backgrounds — dark teal-tinted (default Dispatcharr theme)
    static let appBackground      = Color(hex: "0A0F0D")
    static let cardBackground     = Color(hex: "111916")
    static let elevatedBackground = Color(hex: "182420")
    static let sheetBackground    = Color(hex: "0E1612")

    // Accents — Dispatcharr teal (default; runtime theme overrides via ThemeManager)
    static let accentPrimary   = Color(hex: "2DD4BF")   // bright teal
    static let accentSecondary = Color(hex: "1DB89F")   // medium teal
    static let accentDim       = Color(hex: "145F53")   // dark teal for fills

    // Text
    static let textPrimary   = Color(hex: "EDF6F4")
    static let textSecondary = Color(hex: "7FB8AF")
    static let textTertiary  = Color(hex: "3F6B62")

    // Borders
    static let borderSubtle  = Color(hex: "1E3530")
    static let borderMedium  = Color(hex: "2A4D46")

    // Status
    static let statusLive    = Color(hex: "FF4757")
    static let statusOnline  = Color(hex: "2DD4BF")
    static let statusWarning = Color(hex: "FFA502")
    static let statusOffline = Color(hex: "3F6B62")

    // Server type colors
    static let xtreamColor     = Color(hex: "2DD4BF")
    static let dispatcharrColor = Color(hex: "2DD4BF")
    static let plexColor       = Color(hex: "E5A00D")

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
    static let accentGradient = LinearGradient(
        colors: [.accentPrimary, .accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
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
