import SwiftUI
import Combine

// MARK: - App Theme Preset
enum AppTheme: String, CaseIterable, Codable {
    case dispatcharr = "dispatcharr"   // Default teal brand theme
    case midnight    = "midnight"      // Blue-grey
    case sunset      = "sunset"        // Warm orange/red
    case forest      = "forest"        // Earthy green
    case lavender    = "lavender"      // Purple/violet
    case monochrome  = "monochrome"    // Pure greyscale

    var displayName: String {
        switch self {
        case .dispatcharr: return "Dispatcharr"
        case .midnight:    return "Midnight"
        case .sunset:      return "Sunset"
        case .forest:      return "Forest"
        case .lavender:    return "Lavender"
        case .monochrome:  return "Monochrome"
        }
    }

    var accentPrimary: Color {
        switch self {
        case .dispatcharr: return Color(hex: "2DD4BF")
        case .midnight:    return Color(hex: "60A5FA")
        case .sunset:      return Color(hex: "FB923C")
        case .forest:      return Color(hex: "4ADE80")
        case .lavender:    return Color(hex: "A78BFA")
        case .monochrome:  return Color(hex: "E2E8F0")
        }
    }

    var accentSecondary: Color {
        switch self {
        case .dispatcharr: return Color(hex: "1DB89F")
        case .midnight:    return Color(hex: "3B82F6")
        case .sunset:      return Color(hex: "F97316")
        case .forest:      return Color(hex: "22C55E")
        case .lavender:    return Color(hex: "8B5CF6")
        case .monochrome:  return Color(hex: "94A3B8")
        }
    }

    var appBackground: Color {
        switch self {
        case .dispatcharr: return Color(hex: "0A0F0D")
        case .midnight:    return Color(hex: "0A0F1A")
        case .sunset:      return Color(hex: "0F0A07")
        case .forest:      return Color(hex: "080F0A")
        case .lavender:    return Color(hex: "0C0A12")
        case .monochrome:  return Color(hex: "0A0A0A")
        }
    }

    var cardBackground: Color {
        switch self {
        case .dispatcharr: return Color(hex: "111916")
        case .midnight:    return Color(hex: "111827")
        case .sunset:      return Color(hex: "1A1108")
        case .forest:      return Color(hex: "0E1A10")
        case .lavender:    return Color(hex: "130F1E")
        case .monochrome:  return Color(hex: "111111")
        }
    }
}

// MARK: - Liquid Glass Style
enum LiquidGlassStyle: String, CaseIterable, Codable {
    case full      = "full"       // Full Liquid Glass (iOS 26+)
    case tinted    = "tinted"     // Tinted glass with accent color
    case minimal   = "minimal"    // Ultra-thin material only
    case disabled  = "disabled"   // Regular solid backgrounds

    var displayName: String {
        switch self {
        case .full:     return "Liquid Glass"
        case .tinted:   return "Tinted Glass"
        case .minimal:  return "Minimal Glass"
        case .disabled: return "Solid"
        }
    }
}

// MARK: - Theme Manager
final class ThemeManager: ObservableObject, @unchecked Sendable {
    static let shared = ThemeManager()

    // Use distinct names to avoid collision with @Published's synthesized `_selectedTheme` / `_liquidGlassStyle` backing storage
    @AppStorage("selectedTheme")    private var storedTheme      = AppTheme.dispatcharr.rawValue
    @AppStorage("liquidGlassStyle") private var storedGlassStyle = LiquidGlassStyle.tinted.rawValue
    @AppStorage("useCustomAccent")  var useCustomAccent = false
    @AppStorage("customAccentHex")  var customAccentHex = "2DD4BF"
    @AppStorage("defaultTab")       var defaultTab = "livetv"

    @Published var selectedTheme: AppTheme = .dispatcharr
    @Published var liquidGlassStyle: LiquidGlassStyle = .tinted

    private init() {
        selectedTheme    = AppTheme(rawValue: storedTheme) ?? .dispatcharr
        liquidGlassStyle = LiquidGlassStyle(rawValue: storedGlassStyle) ?? .tinted
    }

    func setTheme(_ theme: AppTheme) {
        selectedTheme = theme
        storedTheme   = theme.rawValue
    }

    func setLiquidGlassStyle(_ style: LiquidGlassStyle) {
        liquidGlassStyle = style
        storedGlassStyle = style.rawValue
    }

    // MARK: - Dynamic Colors (respects current theme + custom accent)
    var accent: Color {
        if useCustomAccent {
            return Color(hex: customAccentHex)
        }
        return selectedTheme.accentPrimary
    }

    var accentSecondary: Color {
        if useCustomAccent {
            return Color(hex: customAccentHex).opacity(0.8)
        }
        return selectedTheme.accentSecondary
    }

    var background: Color { selectedTheme.appBackground }
    var card: Color        { selectedTheme.cardBackground }
}

