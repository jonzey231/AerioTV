import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - App Theme Preset
enum AppTheme: String, CaseIterable, Codable {
    case aerio   = "aerio"          // Default teal brand theme
    case midnight    = "midnight"      // Blue-grey
    case sunset      = "sunset"        // Warm orange/red
    case forest      = "forest"        // Earthy green
    case lavender    = "lavender"      // Purple/violet
    case monochrome  = "monochrome"    // Pure greyscale
    case light       = "light"         // Neutral low-chroma palette that reads on white

    var displayName: String {
        switch self {
        case .aerio: return "AerioTV"
        case .midnight:    return "Midnight"
        case .sunset:      return "Sunset"
        case .forest:      return "Forest"
        case .lavender:    return "Lavender"
        case .monochrome:  return "Monochrome"
        case .light:       return "Light"
        }
    }

    // MARK: Dark-rendition accents (hue identity)
    var accentPrimary: Color {
        switch self {
        case .aerio: return Color(hex: "1AC4D8")   // Aerio cyan
        case .midnight:    return Color(hex: "60A5FA")
        case .sunset:      return Color(hex: "FB923C")
        case .forest:      return Color(hex: "4ADE80")
        case .lavender:    return Color(hex: "A78BFA")
        case .monochrome:  return Color(hex: "E2E8F0")
        case .light:       return Color(hex: "3E9EAC")   // teal-grey, legible on the neutral dark ground
        }
    }

    var accentSecondary: Color {
        switch self {
        case .aerio: return Color(hex: "1A8FA8")   // Aerio deep teal
        case .midnight:    return Color(hex: "3B82F6")
        case .sunset:      return Color(hex: "F97316")
        case .forest:      return Color(hex: "22C55E")
        case .lavender:    return Color(hex: "8B5CF6")
        case .monochrome:  return Color(hex: "94A3B8")
        case .light:       return Color(hex: "2B7A86")
        }
    }

    // MARK: Dark-rendition surfaces
    var appBackground: Color {
        switch self {
        case .aerio: return Color(hex: "0A1628")   // Aerio navy
        case .midnight:    return Color(hex: "0A0F1A")
        case .sunset:      return Color(hex: "0F0A07")
        case .forest:      return Color(hex: "080F0A")
        case .lavender:    return Color(hex: "0C0A12")
        case .monochrome:  return Color(hex: "0A0A0A")
        case .light:       return Color(hex: "0E1518")   // neutral slate-black
        }
    }

    var cardBackground: Color {
        switch self {
        case .aerio: return Color(hex: "0D1E35")   // Aerio card navy
        case .midnight:    return Color(hex: "111827")
        case .sunset:      return Color(hex: "1A1108")
        case .forest:      return Color(hex: "0E1A10")
        case .lavender:    return Color(hex: "130F1E")
        case .monochrome:  return Color(hex: "111111")
        case .light:       return Color(hex: "17211F")
        }
    }

    // MARK: Light-rendition surfaces (hand-authored per theme)
    // Near-white grounds tinted toward each theme hue; white cards float on top.
    // Mode = surface luminance, orthogonal to the theme's hue identity above.
    var lightAppBackground: Color {
        switch self {
        case .aerio:       return Color(hex: "F2F7FA")
        case .midnight:    return Color(hex: "F4F6FB")
        case .sunset:      return Color(hex: "FCF7F2")
        case .forest:      return Color(hex: "F3F8F4")
        case .lavender:    return Color(hex: "F7F5FC")
        case .monochrome:  return Color(hex: "F5F5F5")
        case .light:       return Color(hex: "F6F8FA")
        }
    }

    var lightCardBackground: Color {
        switch self {
        case .aerio, .midnight, .sunset, .forest,
             .lavender, .monochrome, .light:
            return Color(hex: "FFFFFF")
        }
    }

    // MARK: Light-rendition accents (darkened so they read on white)
    // The dark-rendition accents above are tuned for near-black grounds and
    // wash out on white; these are hue-matched but darkened / saturated so
    // highlights, checkmarks, and accent-derived text stay legible in light
    // mode. The palest dark accents (Monochrome pale grey, Aerio pale cyan)
    // would be invisible on white, so they get the largest darkening.
    var lightAccentPrimary: Color {
        switch self {
        case .aerio:       return Color(hex: "0E8FA0")   // deep teal-cyan
        case .midnight:    return Color(hex: "2563EB")
        case .sunset:      return Color(hex: "E8590C")
        case .forest:      return Color(hex: "16A34A")
        case .lavender:    return Color(hex: "7C3AED")
        case .monochrome:  return Color(hex: "475569")   // slate (pale grey is invisible on white)
        case .light:       return Color(hex: "2B7A86")   // neutral teal-grey, reads on white
        }
    }

    var lightAccentSecondary: Color {
        switch self {
        case .aerio:       return Color(hex: "0B6E7C")
        case .midnight:    return Color(hex: "1D4ED8")
        case .sunset:      return Color(hex: "C2410C")
        case .forest:      return Color(hex: "15803D")
        case .lavender:    return Color(hex: "6D28D9")
        case .monochrome:  return Color(hex: "334155")
        case .light:       return Color(hex: "1F5A64")
        }
    }
}

// MARK: - Appearance Mode (surface luminance axis)
// Orthogonal to `AppTheme`: the theme picks the hue identity, the mode picks
// whether surfaces are dark or light. Default is `.dark` so existing users
// (no stored value) see zero visual change on upgrade. Synced across devices
// via the "appearanceMode" string key (see SyncManager.syncStringKeys).
enum AppearanceMode: String, CaseIterable, Codable {
    case dark
    case light
    case system

    var displayName: String {
        switch self {
        case .dark:   return "Dark"
        case .light:  return "Light"
        case .system: return "System"
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

    // Use distinct names to avoid collision with @Published's synthesized backing storage
    @AppStorage("selectedTheme")    private var storedTheme      = AppTheme.aerio.rawValue
    @AppStorage("liquidGlassStyle") private var storedGlassStyle = LiquidGlassStyle.tinted.rawValue
    // Appearance mode (Dark / Light / System). Defaults to `.dark` so existing
    // users with no stored value see zero visual change on upgrade. Synced
    // across devices via the "appearanceMode" prefs key.
    @AppStorage("appearanceMode")   private var storedAppearanceMode = AppearanceMode.dark.rawValue
    @AppStorage("defaultTab")       var defaultTab = "livetv"

    @Published var selectedTheme: AppTheme = .aerio
    @Published var liquidGlassStyle: LiquidGlassStyle = .tinted
    @Published var appearanceMode: AppearanceMode = .dark

    // @Published (not @AppStorage) so objectWillChange fires when these change,
    // ensuring all observers re-render and pick up the new accent immediately.
    @Published var useCustomAccent: Bool = false {
        didSet { UserDefaults.standard.set(useCustomAccent, forKey: "useCustomAccent") }
    }
    @Published var customAccentHex: String = "1AC4D8" {
        didSet { UserDefaults.standard.set(customAccentHex, forKey: "customAccentHex") }
    }

    private init() {
        selectedTheme    = AppTheme(rawValue: storedTheme) ?? .aerio
        liquidGlassStyle = LiquidGlassStyle(rawValue: storedGlassStyle) ?? .tinted
        // Absent stored value resolves to .dark — the single most important
        // upgrade-safety property (existing users must not flip to light).
        appearanceMode   = AppearanceMode(rawValue: storedAppearanceMode) ?? .dark
        useCustomAccent  = UserDefaults.standard.bool(forKey: "useCustomAccent")
        customAccentHex  = UserDefaults.standard.string(forKey: "customAccentHex") ?? "1AC4D8"

        // Re-apply in-memory state whenever iCloud sync pushes new preferences.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadFromStorage),
            name: .syncManagerDidApplyPreferences,
            object: nil
        )
    }

    /// Re-reads all theme state from UserDefaults.
    /// Called after iCloud sync applies remote preferences so @Published properties
    /// reflect the updated values without requiring an app restart.
    @objc func reloadFromStorage() {
        selectedTheme    = AppTheme(rawValue: storedTheme) ?? .aerio
        liquidGlassStyle = LiquidGlassStyle(rawValue: storedGlassStyle) ?? .tinted
        // Re-read the synced appearance mode so an iCloud push applies live.
        appearanceMode   = AppearanceMode(rawValue: storedAppearanceMode) ?? .dark
        useCustomAccent  = UserDefaults.standard.bool(forKey: "useCustomAccent")
        customAccentHex  = UserDefaults.standard.string(forKey: "customAccentHex") ?? "1AC4D8"
    }

    func setTheme(_ theme: AppTheme) {
        useCustomAccent = false   // Preset selection always overrides a custom accent
        selectedTheme   = theme
        storedTheme     = theme.rawValue
    }

    func setLiquidGlassStyle(_ style: LiquidGlassStyle) {
        liquidGlassStyle = style
        storedGlassStyle = style.rawValue
    }

    /// Sets the appearance mode. Orthogonal to theme selection — picking a
    /// theme never changes the mode, and setting the mode never changes the
    /// theme. Writes both the @Published value (so views re-render) and the
    /// synced @AppStorage backing.
    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode      = mode
        storedAppearanceMode = mode.rawValue
    }

    /// The SwiftUI `ColorScheme?` to feed `.preferredColorScheme(...)`.
    /// `.system` returns nil so the app follows the OS setting.
    var resolvedColorScheme: ColorScheme? {
        switch appearanceMode {
        case .dark:   return .dark
        case .light:  return .light
        case .system: return nil
        }
    }

    /// Resolves a (dark, light) color pair against the current appearance
    /// mode. For `.system` it returns a dynamic color that follows the
    /// device trait so system chrome (status bar, etc.) and surfaces stay
    /// in lock-step. The `dark`/`light` arguments must be concrete
    /// (mode-independent) colors — pass `darkAccent`/`lightAccent`, not the
    /// already-resolved `accent`, to avoid nested dynamic resolution.
    static func resolve(dark: Color, light: Color) -> Color {
        switch shared.appearanceMode {
        case .dark:  return dark
        case .light: return light
        case .system:
            #if canImport(UIKit)
            return Color(UIColor { trait in
                trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
            })
            #else
            return dark
            #endif
        }
    }

    // MARK: - Concrete accents (mode-independent, ignore appearance mode)
    /// Accent for the dark rendition. Honors a custom accent override.
    var darkAccent: Color {
        useCustomAccent ? Color(hex: customAccentHex) : selectedTheme.accentPrimary
    }
    /// Accent for the light rendition (darkened per theme so it reads on
    /// white). A custom accent is the user's explicit choice, so it is kept
    /// identical across modes rather than darkened.
    var lightAccent: Color {
        useCustomAccent ? Color(hex: customAccentHex) : selectedTheme.lightAccentPrimary
    }
    var darkAccentSecondary: Color {
        useCustomAccent ? Color(hex: customAccentHex).opacity(0.8) : selectedTheme.accentSecondary
    }
    var lightAccentSecondary: Color {
        useCustomAccent ? Color(hex: customAccentHex).opacity(0.8) : selectedTheme.lightAccentSecondary
    }

    // MARK: - Dynamic Colors (respects current theme + custom accent + mode)
    var accent: Color { ThemeManager.resolve(dark: darkAccent, light: lightAccent) }

    var accentSecondary: Color {
        ThemeManager.resolve(dark: darkAccentSecondary, light: lightAccentSecondary)
    }

    var background: Color {
        ThemeManager.resolve(dark: selectedTheme.appBackground,
                             light: selectedTheme.lightAppBackground)
    }
    var card: Color {
        ThemeManager.resolve(dark: selectedTheme.cardBackground,
                             light: selectedTheme.lightCardBackground)
    }
}

