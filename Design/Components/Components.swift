import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)
// MARK: - tvOS dark-focus text field (UIKit-backed)
//
// v1.7.5 (Archie: "make it a regular text field that's not filled with white
// when in focus"): a focused SwiftUI TextField on tvOS renders a solid white
// system "platter" that cannot be suppressed in pure SwiftUI -
// `.focusEffectDisabled()` has no effect on it (verified on the tvOS 26.2
// simulator). The fix is to host a UIKit UITextField and control its focused
// appearance directly in `didUpdateFocus`: force the dark background and draw
// our own accent border on focus, so it never goes white.

/// UITextField that stays TRANSPARENT on focus (no white platter, no gray).
///
/// Researched root cause (Apple Dev Forums 122597 + others): the white focus
/// "platter" - and the translucent gray that remains when backgroundColor is
/// `.clear` - are painted by UITextField's OWN focus-update animation, not by
/// a detachable `UIFocusEffect`. `.focusEffectDisabled()` / `focusEffect = nil`
/// target the iPad/Mac halo system and have no effect on this. The confirmed
/// fix is to override `didUpdateFocus` and NOT call `super`, which suppresses
/// the whole default focus appearance. The field then stays `backgroundColor
/// = .clear` at all times, so its interior shows whatever the SwiftUI host
/// draws behind it, unchanged by focus. The host draws the box + focus border;
/// this field only reports focus via `onFocusChange`. `overrideUserInterface
/// Style = .dark` keeps tvOS from flipping the text colour to black on focus.
final class DarkFocusTextField: UITextField {
    var textInsets = UIEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
    var onFocusChange: ((Bool) -> Void)?

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: textInsets) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: textInsets) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: textInsets) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        backgroundColor = .clear
        borderStyle = .none
        overrideUserInterfaceStyle = .dark
    }

    // Deliberately does NOT call super: that is what suppresses the system
    // white/gray focus platter. We only report focus and keep the interior
    // transparent.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let nowFocused = (context.nextFocusedView === self)
        onFocusChange?(nowFocused)
        backgroundColor = .clear
    }
}

/// SwiftUI host for `DarkFocusTextField`. The field is transparent; the caller
/// draws the box + focus border (driven by `onFocusChange`). Two-way binds
/// `text`; tvOS presents the keyboard normally on Select (real UITextField).
struct DarkFocusTextFieldRepresentable: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isSecure: Bool = false
    var fontSize: CGFloat = 28
    var horizontalInset: CGFloat = 20
    var verticalInset: CGFloat = 14
    var onFocusChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> DarkFocusTextField {
        let tf = DarkFocusTextField()
        tf.delegate = context.coordinator
        tf.isSecureTextEntry = isSecure
        tf.onFocusChange = onFocusChange
        tf.textInsets = UIEdgeInsets(top: verticalInset, left: horizontalInset,
                                     bottom: verticalInset, right: horizontalInset)
        tf.font = .systemFont(ofSize: fontSize)
        tf.textColor = UIColor(Color.textPrimary)
        tf.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(Color.textTertiary)]
        )
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.editingChanged(_:)),
                     for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: DarkFocusTextField, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.isSecureTextEntry = isSecure
        uiView.onFocusChange = onFocusChange
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }
        @objc func editingChanged(_ tf: UITextField) { text = tf.text ?? "" }
    }
}
#endif

// MARK: - Shared tvOS Button Style

/// Suppresses the default tvOS system focus highlight (white glow) and
/// provides themed focus feedback. The visible focus indicator is the
/// 2pt accent stroke ring drawn on the focused element. v1.6.21 dropped
/// the scale, brightness, and shadow effects per user feedback that the
/// pop-out was distracting and pushed text too close to row borders. The
/// stroke alone is sufficient to identify focus at TV viewing distance.
/// Press feedback is a brief opacity dip.
#if os(tvOS)
struct TVNoHighlightButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    /// When false, this style draws NO focus ring of its own and only
    /// dims on press. Use it for buttons that already render their own
    /// complete focus highlight (e.g. the VOD episode row and Play CTA)
    /// so the focused control shows ONE ring, not this style's ring
    /// nested inside the caller's. Defaults true to preserve every
    /// existing call site.
    var drawsFocusRing: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                // Accent stroke ring drawn on focus. 14pt corner radius
                // matches every primary/secondary/affordance button in
                // this codebase (PrimaryButton, SecondaryButton both
                // use RoundedRectangle(cornerRadius: 14)). Source-type
                // rows on Add Playlist use 16pt cards; the slight inset
                // is invisible at TV viewing distance.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentPrimary,
                            lineWidth: (drawsFocusRing && isFocused) ? 2 : 0)
                    .opacity((drawsFocusRing && isFocused) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isFocused)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
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

    /// v1.7.x: when `isSecure` is true, this drives a trailing
    /// eye-toggle button that flips between `SecureField` and
    /// `TextField`. Lets users verify they typed the password
    /// correctly — especially valuable on Apple TV where the Siri
    /// Remote keyboard makes typos easy. Defaults to hidden so
    /// dots are still the at-rest state; security posture is
    /// unchanged unless the user explicitly taps reveal.
    @State private var passwordVisible: Bool = false

    /// v1.7.5: tvOS focus state, driven by the UIKit DarkFocusTextField's
    /// focus callback (the tvOS body hosts that instead of a SwiftUI
    /// TextField, so @FocusState can't track it). Drives the box border +
    /// icon tint on tvOS the way `isFocused` does on iOS.
    @State private var isFocusedTV: Bool = false

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
        #if os(tvOS)
        tvBody
        #else
        iosBody
        #endif
    }

    #if os(tvOS)
    /// tvOS body: hosts the UIKit dark-focus field so a focused field never
    /// shows the system white platter. The box (background + accent focus
    /// border) is drawn here; the field is transparent and reports focus via
    /// onFocusChange. No leading icon (no call site passes one) and the
    /// secure-reveal eye is kept for password verification on the remote.
    private var tvBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.labelLarge)
                .foregroundColor(.textSecondary)

            HStack(spacing: 12) {
                DarkFocusTextFieldRepresentable(
                    text: $text,
                    placeholder: placeholder,
                    isSecure: isSecure && !passwordVisible,
                    fontSize: 26,
                    horizontalInset: 0,   // the HStack already pads horizontally
                    onFocusChange: { isFocusedTV = $0 }
                )
                if isSecure {
                    Button {
                        passwordVisible.toggle()
                    } label: {
                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                            .font(.system(size: 22))
                            .foregroundColor(.textTertiary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(passwordVisible ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 60)
            .background(Color.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocusedTV ? Color.accentPrimary
                                        : (text.isEmpty ? Color.borderSubtle : Color.accentPrimary.opacity(0.4)),
                            lineWidth: isFocusedTV ? 3 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isFocusedTV)
            )
        }
    }
    #endif

    private var iosBody: some View {
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
                    if isSecure && !passwordVisible {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                            #if os(iOS)
                            .keyboardType(keyboardType)
                            #endif
                    }
                }
                .font(.bodyMedium)
                // v1.6.21 fix for the "white-on-white" tvOS bug.
                // tvOS fills the focused TextField with white and
                // expects dark text. Forcing `.textPrimary` (light)
                // there made typed text invisible against the
                // white fill. On tvOS, switch to a dark colour
                // when focused so the entered text contrasts; on
                // iOS the original light colour is correct.
                #if os(tvOS)
                .foregroundColor(isFocused ? .black : .textPrimary)
                // v1.6.21 fix for vertical centering on tvOS. Without
                // this, the focused TVTextField paints typed text
                // top-aligned within the 52pt field height, leaving
                // it visually misaligned with the leading icon (which
                // SwiftUI centers via the HStack default alignment).
                // `.frame(maxHeight: .infinity, alignment: .center)`
                // tells SwiftUI to expand the TextField to fill the
                // available height with its content centered, which
                // overrides the top-alignment quirk.
                .frame(maxHeight: .infinity, alignment: .center)
                #else
                .foregroundColor(.textPrimary)
                #endif
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(!autocorrection)
                .focused($isFocused)

                // v1.7.x: trailing reveal/hide button for secure
                // fields. Only renders when `isSecure` is true so
                // non-password fields stay flush. Tap toggles
                // `passwordVisible`, which swaps the inner field
                // between SecureField and TextField. Stays empty
                // on tvOS focus engine because tvOS users tap the
                // field directly — adding a sibling button would
                // confuse the focus engine without corresponding
                // value (Siri Remote keyboard reveal is server-side).
                if isSecure {
                    Button {
                        passwordVisible.toggle()
                    } label: {
                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                            .font(.system(size: 16))
                            .foregroundColor(.textTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(passwordVisible ? "Hide password" : "Show password")
                }
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
            // Tapping anywhere in the field, including the icon area, focuses the input
            .contentShape(Rectangle())
            #if os(iOS)
            .onTapGesture { isFocused = true }
            #endif
        }
        // tvOS notes: the system applies a white fill to the focused
        // TextField. v1.6.21 attempted to suppress this with a
        // Button-wrapped mock label and a hidden TextField behind it
        // for the keyboard sheet, but on tvOS the system keyboard
        // sheet only presents when the user explicitly presses
        // Select on a directly-focused TextField. Programmatically
        // setting `@FocusState` on a hidden field doesn't trigger
        // the keyboard, so users couldn't type. Reverted to the
        // direct-TextField path; the white fill on focus stays as
        // an accepted system UX for now. A proper themed-focus tvOS
        // text field requires UIViewRepresentable wrapping
        // UITextField with custom focused-appearance overrides,
        // which is bigger than v1.6.21 scope.
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
