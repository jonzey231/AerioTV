import SwiftUI

// MARK: - Shared tvOS Button Style

/// Suppresses the default tvOS system focus highlight (white glow) and
/// provides a subtle universal focus indication (scale + brightness).
/// Elements that need stronger focus feedback should use TVCardButtonStyle
/// or implement their own @FocusState + custom visuals.
#if os(tvOS)
struct TVNoHighlightButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .brightness(isFocused ? 0.15 : 0)
            .shadow(color: isFocused ? Color.accentPrimary.opacity(0.4) : .clear, radius: 8, y: 2)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Legacy alias — prefer TVNoHighlightButtonStyle for new code.
typealias TVNoRingButtonStyle = TVNoHighlightButtonStyle

/// Focus style for tvOS poster/card grids — scales up and adds a glow on focus.
/// The accent border is applied by VODPosterCard directly on the poster image
/// (not the whole card including text), so this style only handles scale + shadow.
struct TVCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8) // Breathing room so scaled card doesn't overlap neighbours
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: isFocused ? Color.accentPrimary.opacity(0.5) : .clear, radius: 12, y: 6)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif

// MARK: - iOS Pressable Button Style

/// Provides subtle scale + opacity feedback on press for iOS cards/rows.
/// Use on NavigationLinks and Buttons that otherwise appear static.
#if os(iOS)
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.15 : 0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

// tvOS / macOS shim — UIKeyboardType isn't available outside iOS,
// so we mirror the values the app references to keep call sites clean.
#if !os(iOS)
enum UIKeyboardType: Int { case `default` = 0, URL = 3 }
#endif

// MARK: - App Card
struct AppCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
    }
}

// MARK: - Primary Button
struct PrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isLoading: Bool = false
    var isDisabled: Bool = false

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(title)
                        .font(.headlineMedium)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                isDisabled
                    ? AnyShapeStyle(Color.textTertiary)
                    : AnyShapeStyle(LinearGradient.accentGradient)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isDisabled || isLoading)
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Secondary Button
struct SecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(title)
                    .font(.headlineMedium)
            }
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.borderMedium, lineWidth: 1)
            )
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Styled Text Field
struct AppTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var keyboardType: UIKeyboardType = .default
    var isSecure: Bool = false
    var autocapitalization: TextInputAutocapitalization = .never
    var autocorrection: Bool = false

    @FocusState private var isFocused: Bool

    init(_ title: String,
         placeholder: String,
         text: Binding<String>,
         icon: String? = nil,
         keyboardType: UIKeyboardType = .default,
         isSecure: Bool = false,
         autocapitalization: TextInputAutocapitalization = .never,
         autocorrection: Bool = false) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.keyboardType = keyboardType
        self.isSecure = isSecure
        self.autocapitalization = autocapitalization
        self.autocorrection = autocorrection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.labelLarge)
                .foregroundColor(.textSecondary)

            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(isFocused ? .accentPrimary : .textTertiary)
                        .frame(width: 20)
                        .animation(.easeInOut(duration: 0.15), value: isFocused)
                }

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                            #if os(iOS)
                            .keyboardType(keyboardType)
                            #endif
                    }
                }
                .font(.bodyMedium)
                .foregroundColor(.textPrimary)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(!autocorrection)
                .focused($isFocused)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary.opacity(0.6) : (text.isEmpty ? Color.borderSubtle : Color.accentPrimary.opacity(0.4)), lineWidth: isFocused ? 1.5 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isFocused)
            )
            // Tapping anywhere in the field — including the icon area — focuses the input
            .contentShape(Rectangle())
            #if os(iOS)
            .onTapGesture { isFocused = true }
            #endif
        }
    }
}

// MARK: - Server Type Badge
struct ServerTypeBadge: View {
    let type: ServerType

    #if os(tvOS)
    private let iconSize: CGFloat = 16
    private let hPad: CGFloat = 12
    private let vPad: CGFloat = 6
    #else
    private let iconSize: CGFloat = 10
    private let hPad: CGFloat = 8
    private let vPad: CGFloat = 4
    #endif

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: type.systemIcon)
                .font(.system(size: iconSize, weight: .semibold))
            Text(type.displayName)
                .font(.labelSmall)
        }
        .foregroundColor(type.color)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(type.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Live Badge
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.statusLive)
                .frame(width: 5, height: 5)
            Text("LIVE")
                .font(.labelSmall)
                .foregroundColor(Color.statusLive)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.statusLive.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil
    var actionTitle: String = "See All"

    var body: some View {
        HStack {
            Text(title)
                .sectionHeaderStyle()
            Spacer()
            if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.labelMedium)
                        .foregroundColor(.accentPrimary)
                }
                #if os(tvOS)
                .buttonStyle(TVNoHighlightButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
            }
        }
    }
}

// MARK: - Loading View
struct LoadingView: View {
    var message: String = "Loading..."

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.accentPrimary)
                .scaleEffect(1.2)
            Text(message)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)? = nil
    var actionTitle: String = "Get Started"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(LinearGradient.accentGradient)

            VStack(spacing: 8) {
                Text(title)
                    .font(.headlineLarge)
                    .foregroundColor(.textPrimary)
                Text(message)
                    .font(.bodyMedium)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.headlineSmall)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(LinearGradient.accentGradient)
                        .clipShape(Capsule())
                }
                #if os(tvOS)
                .buttonStyle(TVNoHighlightButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - No-Poster Placeholder
/// Shown when no artwork is available for a movie, series, or channel.
struct NoPosterPlaceholder: View {
    /// When true, shows only the logo without text (for small contexts like channel logos).
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Image("AerioLogo")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 20 : 40, height: compact ? 20 : 40)
                .opacity(0.6)
            if !compact {
                Text("No artwork provided")
                    .font(.labelSmall)
                    .foregroundColor(.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - tvOS Category Pill (shared)
#if os(tvOS)
struct TVCategoryPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(isSelected ? .appBackground : (isFocused ? .white : .textSecondary))
                .padding(.horizontal, 26)
                .padding(.vertical, 13)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentPrimary
                              : (isFocused ? Color.accentPrimary.opacity(0.25) : Color.elevatedBackground))
                )
                .scaleEffect(isFocused ? 1.08 : 1.0)
                .shadow(color: Color.accentPrimary.opacity(isFocused ? 0.55 : 0), radius: 14)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(TVNoRingButtonStyle())
        .focused($isFocused)
    }
}
#endif
