import SwiftUI

// MARK: - Liquid Glass View Modifier
// Adapts to the user's chosen LiquidGlassStyle and tints with the current theme accent.
// On iOS 26+: uses the native .glassEffect API when style == .full.
// On iOS 18-25: falls back to ultraThinMaterial + tint overlay.

struct LiquidGlassModifier: ViewModifier {
    @ObservedObject var theme: ThemeManager = .shared
    var cornerRadius: CGFloat = 16
    var tintOpacity: Double? = nil // nil → use style default

    private var effectiveOpacity: Double {
        if let t = tintOpacity { return t }
        switch theme.liquidGlassStyle {
        case .full:     return 0.08
        case .tinted:   return 0.12
        case .minimal:  return 0.04
        case .disabled: return 0.0
        }
    }

    func body(content: Content) -> some View {
        switch theme.liquidGlassStyle {
        case .disabled:
            content
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

        case .minimal:
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

        case .tinted:
            content
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(theme.accent.opacity(effectiveOpacity))
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(theme.accent.opacity(0.18), lineWidth: 1)
                    }
                }

        case .full:
            if #available(iOS 26.0, tvOS 26.0, *) {
                // Use native Liquid Glass when available
                content
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(theme.accent.opacity(0.10))
                    }
            } else {
                // Fallback for iOS < 26
                content
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(theme.accent.opacity(0.10))
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(theme.accent.opacity(0.22), lineWidth: 1)
                        }
                    }
            }
        }
    }
}

// MARK: - Tab Bar Glass Modifier
struct LiquidGlassTabBar: ViewModifier {
    @ObservedObject var theme: ThemeManager = .shared

    func body(content: Content) -> some View {
        if #available(iOS 26.0, tvOS 26.0, *), theme.liquidGlassStyle == .full {
            content
                .toolbarBackground(.hidden, for: .tabBar)
        } else {
            content
        }
    }
}

// MARK: - View Extensions
extension View {
    func liquidGlass(cornerRadius: CGFloat = 16, tintOpacity: Double? = nil) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius, tintOpacity: tintOpacity))
    }

    func liquidGlassTabBar() -> some View {
        modifier(LiquidGlassTabBar())
    }
}
