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
    case custom      = "custom"        // Derived from one user color (CustomThemePalette)

    var displayName: String {
        switch self {
        case .aerio: return "AerioTV"
        case .midnight:    return "Midnight"
        case .sunset:      return "Sunset"
        case .forest:      return "Forest"
        case .lavender:    return "Lavender"
        case .monochrome:  return "Monochrome"
        case .light:       return "Slate"
        case .custom:      return "Custom"
        }
    }

    // MARK: Dark-rendition accents (hue identity)
    var accentPrimary: Color {
        switch self {
        case .custom:      return Color(hex: ThemeManager.shared.customPalette.darkAccent)
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
        case .custom:      return Color(hex: ThemeManager.shared.customPalette.darkAccentSecondary)
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
        case .custom:      return Color(hex: ThemeManager.shared.customPalette.darkBackground)
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
        case .custom:      return Color(hex: ThemeManager.shared.customPalette.darkCard)
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
        case .custom:      return Color(hex: ThemeManager.shared.customPalette.lightBackground)
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
             .lavender, .monochrome, .light, .custom:
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
        case .custom:      return Color(hex: ThemeManager.shared.customPalette.lightAccent)
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
        case .custom:      return Color(hex: ThemeManager.shared.customPalette.lightAccentSecondary)
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

// MARK: - Mode picker choice
// Settings > Appearance > Mode is one one-of-N picker: System, Light, Dark,
// True Black. Storage and sync stay the two existing fields so older
// clients keep working: True Black = appearanceMode "dark" plus
// appearance.trueBlack true. trueBlack is honored only with Dark, so a
// stored System or Light with trueBlack on reads as plain System or Light.
enum AppearanceChoice: String, CaseIterable {
    case system, light, dark, trueBlack

    var displayName: String {
        switch self {
        case .system:    return "System"
        case .light:     return "Light"
        case .dark:      return "Dark"
        case .trueBlack: return "True Black"
        }
    }

    var subtitle: String {
        switch self {
        case .system:    return "Follow the system setting"
        case .light:     return "Light surfaces"
        case .dark:      return "Dark surfaces (default)"
        case .trueBlack: return "Dark surfaces at pure black, for OLED screens"
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

    /// Settings > Appearance > Color Theme > Custom > Theme Color. The one
    /// base color the Custom theme is built from (see CustomThemePalette).
    /// Synced with the Color Theme item as `customThemeHex`. Like the custom
    /// accent, it is NOT part of the Appearance List identity, so changing
    /// it repaints the page without resetting its scroll.
    static let customThemeHexKey = "customThemeHex"
    @Published var customThemeHex: String = CustomThemePalette.defaultHex {
        didSet {
            guard oldValue != customThemeHex else { return }
            customPalette = CustomThemePalette.derive(customThemeHex)
            UserDefaults.standard.set(customThemeHex, forKey: ThemeManager.customThemeHexKey)
        }
    }
    /// Derived once per base color change; every themed color reads it.
    private(set) var customPalette = CustomThemePalette.derive(CustomThemePalette.defaultHex)

    /// Settings > Appearance > Text Contrast (0...1). @Published so every
    /// observer re-renders and `Color.contrastText` picks up the new value
    /// live, the same path a custom accent change takes.
    @Published var textContrast: Double = TextContrast.stored

    /// Settings > Appearance > True Black Background. Synced bool key
    /// `appearance.trueBlack`, default Off. Applied at theme resolution
    /// (`background` / `card` below), never per view.
    static let trueBlackKey = "appearance.trueBlack"
    @Published var trueBlack: Bool = false {
        didSet {
            guard oldValue != trueBlack else { return }
            UserDefaults.standard.set(trueBlack, forKey: ThemeManager.trueBlackKey)
        }
    }

    private init() {
        selectedTheme    = AppTheme(rawValue: storedTheme) ?? .aerio
        liquidGlassStyle = LiquidGlassStyle(rawValue: storedGlassStyle) ?? .tinted
        // Absent stored value resolves to .dark, the single most important
        // upgrade-safety property (existing users must not flip to light).
        appearanceMode   = AppearanceMode(rawValue: storedAppearanceMode) ?? .dark
        useCustomAccent  = UserDefaults.standard.bool(forKey: "useCustomAccent")
        customAccentHex  = UserDefaults.standard.string(forKey: "customAccentHex") ?? "1AC4D8"
        trueBlack        = UserDefaults.standard.bool(forKey: ThemeManager.trueBlackKey)
        let base = CustomThemePalette.clean(UserDefaults.standard.string(forKey: ThemeManager.customThemeHexKey))
            ?? CustomThemePalette.defaultHex
        customPalette    = CustomThemePalette.derive(base)
        customThemeHex   = base

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
        // Equal-value guard: every observer (about 200 views follow the theme
        // live) re-renders on any @Published write, and a sync apply posts
        // this notice for every settings pull, changed theme or not.
        // Read UserDefaults directly: the @AppStorage boxes on this class
        // refresh from a change notification that lands after the write, so a
        // reload right after a profile swap or a sync apply read the previous
        // profile's theme (iPad 2026-11-03: Jordan's lavender after the
        // switch back to Logan).
        let ud = UserDefaults.standard
        let t = AppTheme(rawValue: ud.string(forKey: "selectedTheme") ?? "") ?? .aerio
        if t != selectedTheme { selectedTheme = t }
        let g = LiquidGlassStyle(rawValue: ud.string(forKey: "liquidGlassStyle") ?? "") ?? .tinted
        if g != liquidGlassStyle { liquidGlassStyle = g }
        // Re-read the synced appearance mode so an iCloud push applies live.
        let m = AppearanceMode(rawValue: ud.string(forKey: "appearanceMode") ?? "") ?? .dark
        if m != appearanceMode { appearanceMode = m }
        let ca = UserDefaults.standard.bool(forKey: "useCustomAccent")
        if ca != useCustomAccent { useCustomAccent = ca }
        let hex = UserDefaults.standard.string(forKey: "customAccentHex") ?? "1AC4D8"
        if hex != customAccentHex { customAccentHex = hex }
        let base = CustomThemePalette.clean(ud.string(forKey: ThemeManager.customThemeHexKey))
            ?? CustomThemePalette.defaultHex
        if base != customThemeHex { customThemeHex = base }
        debugLog("[THEME] reload theme=\(selectedTheme.rawValue) customAccent=\(useCustomAccent)")
        let black = UserDefaults.standard.bool(forKey: ThemeManager.trueBlackKey)
        if black != trueBlack { trueBlack = black }
        let contrast = TextContrast.stored
        if abs(contrast - textContrast) > 0.0001 { textContrast = contrast }
    }

    /// Sets Text Contrast (snapped to 10% steps) and persists it.
    func setTextContrast(_ value: Double) {
        let snapped = TextContrast.clamp(value)
        guard abs(snapped - textContrast) > 0.0001 else { return }
        UserDefaults.standard.set(snapped, forKey: TextContrast.key)
        textContrast = snapped
    }

    func setTheme(_ theme: AppTheme) {
        useCustomAccent = false   // Preset selection always overrides a custom accent
        selectedTheme   = theme
        storedTheme     = theme.rawValue
    }

    /// Sets the Custom theme's base color from a hex string (with or
    /// without "#"). Only a complete RRGGBB is stored.
    func setCustomThemeHex(_ raw: String) {
        guard let clean = CustomThemePalette.clean(raw), clean != customThemeHex else { return }
        customThemeHex = clean
    }

    func setLiquidGlassStyle(_ style: LiquidGlassStyle) {
        liquidGlassStyle = style
        storedGlassStyle = style.rawValue
    }

    /// Sets the appearance mode. Orthogonal to theme selection, picking a
    /// theme never changes the mode, and setting the mode never changes the
    /// theme. Writes both the @Published value (so views re-render) and the
    /// synced @AppStorage backing.
    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode      = mode
        storedAppearanceMode = mode.rawValue
    }

    /// True Black applies only with the Dark mode (see AppearanceChoice).
    var effectiveTrueBlack: Bool { trueBlack && appearanceMode == .dark }

    var appearanceChoice: AppearanceChoice {
        switch appearanceMode {
        case .system: return .system
        case .light:  return .light
        case .dark:   return trueBlack ? .trueBlack : .dark
        }
    }

    func setAppearanceChoice(_ choice: AppearanceChoice) {
        let black = choice == .trueBlack
        if black != trueBlack { trueBlack = black }
        let mode: AppearanceMode
        switch choice {
        case .system: mode = .system
        case .light: mode = .light
        case .dark, .trueBlack: mode = .dark
        }
        if mode != appearanceMode { setAppearanceMode(mode) }
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
    /// (mode-independent) colors, pass `darkAccent`/`lightAccent`, not the
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

    /// Primary text on the dark rendition: the fixed near-white for presets,
    /// a hue-tinted near-white for the Custom theme.
    var darkTextPrimary: Color {
        selectedTheme == .custom ? Color(hex: customPalette.darkText) : Color(hex: "E8F4F8")
    }
    /// Ink for text and borders on the light rendition: the fixed slate for
    /// presets, a hue-tinted near-black for the Custom theme.
    var lightInk: Color {
        selectedTheme == .custom ? Color(hex: customPalette.lightInk) : Color(hex: "0F1B24")
    }

    // MARK: - Dynamic Colors (respects current theme + custom accent + mode)
    var accent: Color { ThemeManager.resolve(dark: darkAccent, light: lightAccent) }

    var accentSecondary: Color {
        ThemeManager.resolve(dark: darkAccentSecondary, light: lightAccentSecondary)
    }

    /// Dark-rendition page background: the theme's color, or pure black
    /// when True Black Background is On (OLED). Light rendition untouched.
    var darkBackground: Color {
        effectiveTrueBlack ? Color(hex: "000000") : selectedTheme.appBackground
    }
    /// Dark-rendition card / sheet surface: the theme's color, or a very dark
    /// gray (#0A0A0A) under True Black so elevation still reads.
    var darkCard: Color {
        effectiveTrueBlack ? Color(hex: "0A0A0A") : selectedTheme.cardBackground
    }

    var background: Color {
        ThemeManager.resolve(dark: darkBackground,
                             light: selectedTheme.lightAppBackground)
    }
    var card: Color {
        ThemeManager.resolve(dark: darkCard,
                             light: selectedTheme.lightCardBackground)
    }
}


// MARK: - Custom theme palette
//
// CUSTOM THEME DERIVATION (shared formula; Android ui/theme/CustomThemePalette.kt
// implements the same steps, keep the two identical so both platforms land on
// the same hex values):
//
// 1. Parse the base color "RRGGBB" and convert it to HSL: h in degrees
//    [0, 360), s and l in [0, 1]. Let cap(x) = min(s, x).
// 2. Dark rendition:
//      background   = HSL(h, cap(0.55), 0.07)
//      card / sheet = HSL(h, cap(0.50), 0.12)
//      text primary = HSL(h, cap(0.30), 0.94)
// 3. Light rendition:
//      background   = HSL(h, cap(0.45), 0.965)
//      card / sheet = #FFFFFF (as every preset)
//      text ink     = HSL(h, cap(0.40), 0.10)
//    Secondary text, tertiary text, and dividers keep the preset rules
//    (accent or ink at the preset opacities), so they follow these values.
// 4. Matching accent: hue ha = (h - 30) mod 360 (the step from AerioTV's
//    navy ground to its cyan accent); saturation sa = s when s < 0.08 (a gray
//    base keeps a gray accent), otherwise clamp(s, 0.65, 0.90).
//      dark accent    = HSL(ha, sa, L), L = 0.60 + 0.02 * k for the smallest
//                       k in 0...15 whose WCAG contrast on the dark
//                       background is at least 4.5
//      dark secondary = HSL(ha, sa, L - 0.12)
//      light accent   = HSL(ha, sa, L), L = 0.40 - 0.02 * k for the smallest
//                       k in 0...12 whose WCAG contrast on the light
//                       background is at least 4.5
//      light secondary= HSL(ha, sa, L - 0.08)
// 5. HSL to RGB uses the standard chroma formula; each channel is
//    floor(v * 255 + 0.5). Contrast is measured on those 8-bit values.
// Mode (Light, Dark, System) and True Black Background apply on top exactly
// as for presets (ThemeManager.background / card). Custom Accent Color, when
// on, replaces the matching accent in both modes.
struct CustomThemePalette: Equatable, Sendable {
    let darkBackground: String
    let darkCard: String
    let darkText: String
    let lightBackground: String
    let lightInk: String
    let darkAccent: String
    let darkAccentSecondary: String
    let lightAccent: String
    let lightAccentSecondary: String

    /// AerioTV navy, so a first pick of Custom looks close to the default.
    static let defaultHex = "0A1628"

    /// "RRGGBB" uppercased, a leading "#" dropped; nil unless six hex digits.
    static func clean(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return s.uppercased()
    }

    static func derive(_ hex: String) -> CustomThemePalette {
        let v = UInt32(clean(hex) ?? defaultHex, radix: 16) ?? 0x0A1628
        let (h, s, _) = rgbToHsl(Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF))
        func cap(_ x: Double) -> Double { min(s, x) }
        let darkBg = hsl(h, cap(0.55), 0.07)
        let lightBg = hsl(h, cap(0.45), 0.965)
        let ha = h >= 30 ? h - 30 : h + 330
        let sa = s < 0.08 ? s : min(0.90, max(0.65, s))
        var dl = 0.60
        for k in 0...15 {
            dl = 0.60 + 0.02 * Double(k)
            if contrast(hsl(ha, sa, dl), darkBg) >= 4.5 { break }
        }
        var ll = 0.40
        for k in 0...12 {
            ll = 0.40 - 0.02 * Double(k)
            if contrast(hsl(ha, sa, ll), lightBg) >= 4.5 { break }
        }
        return CustomThemePalette(
            darkBackground: hexString(darkBg),
            darkCard: hexString(hsl(h, cap(0.50), 0.12)),
            darkText: hexString(hsl(h, cap(0.30), 0.94)),
            lightBackground: hexString(lightBg),
            lightInk: hexString(hsl(h, cap(0.40), 0.10)),
            darkAccent: hexString(hsl(ha, sa, dl)),
            darkAccentSecondary: hexString(hsl(ha, sa, max(0, dl - 0.12))),
            lightAccent: hexString(hsl(ha, sa, ll)),
            lightAccentSecondary: hexString(hsl(ha, sa, max(0, ll - 0.08)))
        )
    }

    typealias RGB = (r: Int, g: Int, b: Int)

    static func rgbToHsl(_ r8: Int, _ g8: Int, _ b8: Int) -> (Double, Double, Double) {
        let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        if d == 0 { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, min(1, s), l)
    }

    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        func q(_ v: Double) -> Int { min(255, max(0, Int(floor((v + m) * 255 + 0.5)))) }
        return (q(r1), q(g1), q(b1))
    }

    static func luminance(_ c: RGB) -> Double {
        func ch(_ v: Int) -> Double {
            let x = Double(v) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func hexString(_ c: RGB) -> String {
        String(format: "%02X%02X%02X", c.r, c.g, c.b)
    }
}
