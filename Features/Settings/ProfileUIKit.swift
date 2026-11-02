//  ProfileUIKit.swift
//  Aerio
//
//  Profiles part 3: the building blocks every profile surface shares
//  (Android feature/settings ProfileAvatarUi.kt, ProfilePinUi.kt, and the
//  ChoiceRow / RoleBadge / RoleChip pieces). Themed, one look on iPhone,
//  iPad, and Apple TV: cards on the theme surface, accent focus ring,
//  Capsule pills (white ring when selected on TV).

import SwiftUI

/// Point sizes per form factor.
enum ProfileUI {
    #if os(tvOS)
    static let isTv = true
    #else
    static let isTv = false
    #endif
    static func s(_ phone: CGFloat, _ tv: CGFloat) -> CGFloat { isTv ? tv : phone }
    static var title: AerioFont { .system(size: s(19, 34), weight: .semibold) }
    static var body: AerioFont { .system(size: s(16, 26)) }
    static var bodyStrong: AerioFont { .system(size: s(16, 26), weight: .medium) }
    static var small: AerioFont { .system(size: s(13, 21)) }
    static var label: AerioFont { .system(size: s(13, 21), weight: .semibold) }
    static let errorColor = Color(red: 0.94, green: 0.33, blue: 0.31)
}

// MARK: - Copy shared with Android (word for word)

enum ProfileCopy {
    static func pinCheckMessage(_ r: ProfileManager.PinCheck) -> String? {
        switch r {
        case .ok: return nil
        case .wrong: return "Wrong PIN"
        case .locked(let n): return "Try again in \(n) seconds"
        }
    }

    /// One line under each role (Android roleDescription).
    static func roleDescription(_ r: ProfileRole) -> String {
        switch r {
        case .admin: return "Full access in AerioTV. Has admin rights on the Dispatcharr server."
        case .user: return "Full access in AerioTV. A standard user on the Dispatcharr server."
        case .child: return "Sees only its own content and basic settings. Switching from a Child profile to a non-Child profile requires PIN entry."
        }
    }

    static let roleFooter = "A Child profile sees only its own content and basic settings. Switching from a Child profile to a non-Child profile requires PIN entry."
    static let adminPinTitle = "Enter a PIN from an Admin or Standard profile"
    static let sectionFooter = "Each profile signs in as its own Dispatcharr user. Favorites, recordings, and watch history are kept per profile on this device."

    static func levelCaption(_ userLevel: Int) -> String {
        switch ProfileLevel.of(userLevel) {
        case .admin: return "Dispatcharr admin"
        case .standard: return "Standard"
        case .limited: return "Limited"
        }
    }
}

extension DispatcharrUserSummary {
    /// Android serverLevel: superuser or staff counts as Admin.
    var serverLevel: Int { isSuperuser || isStaff ? 10 : (userLevel ?? 0) }
    var isServerAdmin: Bool { ProfileLevel.of(serverLevel) == .admin }
}

// MARK: - Avatar

enum ProfileAvatarStyle {
    static func color(_ id: String) -> Color {
        switch id {
        case "teal": return Color(hex6: 0x1AC4D8)
        case "blue": return Color(hex6: 0x3B82F6)
        case "orange": return Color(hex6: 0xFB923C)
        case "ember": return Color(hex6: 0xC2410C)
        case "green": return Color(hex6: 0x22C55E)
        case "purple": return Color(hex6: 0x8B5CF6)
        case "slate": return Color(hex6: 0x94A3B8)
        case "sea": return Color(hex6: 0x2B7A86)
        default: return Color(hex6: 0x1AC4D8)
        }
    }

    /// Dark ink on the light swatches (Android avatarInk: luminance above 0.45).
    static func ink(_ id: String) -> Color {
        ["teal", "orange", "green", "slate"].contains(id) ? Color(hex6: 0x0B1220) : .white
    }

    static func symbol(_ id: String) -> String? {
        switch id {
        case "person": return "person.fill"
        case "face": return "face.smiling.fill"
        case "child": return "figure.and.child.holdinghands"
        case "paw": return "pawprint.fill"
        case "cat": return "cat.fill"
        case "fish": return "fish.fill"
        case "star": return "star.fill"
        case "rocket": return "airplane.departure"
        case "music": return "music.note"
        case "soccer": return "soccerball"
        case "gamepad": return "gamecontroller.fill"
        case "movie": return "film.fill"
        default: return nil
        }
    }

    static func iconName(_ id: String) -> String {
        switch id {
        case AvatarCatalog.INITIAL: return "Initial"
        case "gamepad": return "Game controller"
        case "paw": return "Paw"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

extension Color {
    init(hex6: UInt32) {
        self.init(red: Double((hex6 >> 16) & 0xFF) / 255, green: Double((hex6 >> 8) & 0xFF) / 255, blue: Double(hex6 & 0xFF) / 255)
    }
}

struct ProfileAvatarView: View {
    let name: String
    let username: String
    let spec: AvatarSpec?
    let size: CGFloat

    init(_ p: DispatcharrProfile, size: CGFloat) {
        name = p.displayName; username = p.username; spec = p.avatar; self.size = size
    }

    init(name: String, username: String, spec: AvatarSpec?, size: CGFloat) {
        self.name = name; self.username = username; self.spec = spec; self.size = size
    }

    var body: some View {
        let colorId = AvatarCatalog.colorFor(spec, username)
        let icon = AvatarCatalog.iconFor(spec)
        ZStack {
            Circle().fill(ProfileAvatarStyle.color(colorId))
            if let sym = ProfileAvatarStyle.symbol(icon) {
                Image(systemName: sym)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundColor(ProfileAvatarStyle.ink(colorId))
            } else {
                Text(String((name.isEmpty ? username : name).prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundColor(ProfileAvatarStyle.ink(colorId))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Badges and rows

struct ProfileRoleBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .scaledFont(ProfileUI.label)
            .foregroundColor(.accentPrimary)
            .padding(.horizontal, ProfileUI.s(8, 14))
            .padding(.vertical, ProfileUI.s(2, 4))
            .background(Capsule().fill(Color.accentPrimary.opacity(0.18)))
    }
}

/// The card button look for profile rows: theme card, accent focus ring on TV.
struct ProfileRowButtonStyle: ButtonStyle {
    var lifted = false
    var destructive = false
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: ProfileUI.s(12, 16), style: .continuous)
        return configuration.label
            .padding(.horizontal, ProfileUI.s(14, 24))
            .padding(.vertical, ProfileUI.s(10, 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.elevatedBackground.opacity(ProfileUI.isTv ? 1 : 0.001)))
            .overlay(shape.stroke(lifted ? Color.accentPrimary : (focused ? Color.accentPrimary : .clear),
                                  lineWidth: lifted ? 3 : 2))
            .contentShape(shape)
            // No focus scale (a focused Settings row keeps its siblings' frame); a lifted row grows.
            .scaleEffect(lifted ? 1.03 : (configuration.isPressed ? 0.98 : 1))
            .animation(.easeInOut(duration: 0.15), value: focused)
            .animation(.easeInOut(duration: 0.15), value: lifted)
    }
}

/// Capsule pill (Add, Remove, dialog buttons): accent focus ring, white ring when selected on TV.
struct ProfilePillStyle: ButtonStyle {
    var filled = true
    var destructive = false
    var selected = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    /// Text on a filled pill: Android onPrimary (app background in dark, white in
    /// light), onError (text primary) for destructive. contrastText(tint) returned
    /// the tint itself at zero text contrast, so the label vanished on its fill.
    private var onFill: Color {
        if destructive { return .white }
        return scheme == .dark ? Color.appBackground : .white
    }
    func makeBody(configuration: Configuration) -> some View {
        let tint = destructive ? ProfileUI.errorColor : Color.accentPrimary
        return configuration.label
            .scaledFont(ProfileUI.label)
            .foregroundColor(filled ? onFill : tint)
            .padding(.horizontal, ProfileUI.s(16, 28))
            .padding(.vertical, ProfileUI.s(7, 12))
            .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
            .overlay(Capsule().stroke(selected ? Color.white : (focused ? Color.accentPrimary : .clear), lineWidth: ProfileUI.s(2, 3)))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(focused ? 1.06 : (configuration.isPressed ? 0.96 : 1))
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

/// One choice row (Android ChoiceRow): radio for one-of-N, plain for actions.
struct ProfileChoiceRow: View {
    let label: String
    var subtitle: String? = nil
    var checked: Bool? = nil
    var destructive = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: ProfileUI.s(12, 18)) {
                if let checked {
                    Image(systemName: checked ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(checked ? .accentPrimary : .textSecondary)
                        .font(.system(size: ProfileUI.s(20, 30)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .scaledFont(ProfileUI.body)
                        .foregroundColor(destructive ? ProfileUI.errorColor : .textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .scaledFont(ProfileUI.small)
                            .foregroundColor(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(ProfileRowButtonStyle())
        .accessibilityAddTraits(checked == true ? .isSelected : [])
    }
}

// MARK: - Themed dialog

/// The themed dialog card every profile prompt uses (Android SettingsAlertDialog).
struct ProfileDialog<Content: View>: View {
    let title: String
    var centeredTitle = false
    var subtitle: String? = nil
    var cancelLabel: String? = "Cancel"
    var confirm: (label: String, enabled: Bool, destructive: Bool, action: () -> Void)? = nil
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: centeredTitle ? .center : .leading, spacing: ProfileUI.s(12, 22)) {
            Text(title)
                .scaledFont(ProfileUI.title)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(centeredTitle ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: centeredTitle ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .scaledFont(ProfileUI.small)
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: ProfileUI.s(6, 12)) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ProfileUI.s(2, 12))
                    .padding(.horizontal, ProfileUI.s(0, 12))
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: ProfileUI.s(12, 24)) {
                Spacer(minLength: 0)
                if let cancelLabel {
                    Button(cancelLabel, action: onCancel).buttonStyle(ProfilePillStyle(filled: false))
                }
                if let confirm {
                    // Never disabled (a disabled focused TV button drops focus); dimmed and inert instead.
                    Button(confirm.label) { if confirm.enabled { confirm.action() } }
                        .buttonStyle(ProfilePillStyle(destructive: confirm.destructive))
                        .opacity(confirm.enabled ? 1 : 0.45)
                }
            }
        }
        .padding(ProfileUI.s(20, 48))
        .frame(maxWidth: ProfileUI.s(520, 1000))
        .background(RoundedRectangle(cornerRadius: ProfileUI.s(20, 28), style: .continuous).fill(Color.cardBackground))
        .padding(ProfileUI.s(16, 60))
        #if os(tvOS)
        .onExitCommand(perform: onCancel)
        #endif
    }
}

/// Hosts a dialog full screen over a dimmed backdrop (one presentation for every step of a flow).
struct ProfileDialogHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            content()
        }
        .presentationBackground(.clear)
    }
}

// MARK: - PIN entry

/// One PIN entry (Android PinEntryDialog). [onEntered] returns an error to
/// show (the entry clears) or nil when accepted. [onDismiss] nil = the
/// launch gate, which cannot be dismissed.
struct ProfilePinEntry: View {
    let title: String
    let type: PinType
    var pinLength: Int? = nil
    var setting = false
    var initialError: String? = nil
    var lockSeconds: (() -> Int)? = nil
    let onDismiss: (() -> Void)?
    let onEntered: ([String]) -> String?

    @State private var entries: [String] = []
    @State private var error: String?
    @State private var submits = 0
    @State private var openedAt = Date()
    @FocusState private var padFocus: String?

    private var fixed: Int? { pinLength.map { min(max($0, PinRules.MIN_LENGTH), PinRules.MAX_LENGTH) } }
    private var minLen: Int { fixed ?? PinRules.MIN_LENGTH }
    private var maxLen: Int { fixed ?? PinRules.MAX_LENGTH }
    /// A press that started on the previous pad must not land here.
    private var ready: Bool { Date().timeIntervalSince(openedAt) >= 0.3 }

    private func add(_ v: String) {
        guard ready, entries.count < maxLen else { return }
        entries.append(v); error = nil
    }

    private func submit() {
        guard ready, entries.count >= minLen else { return }
        let msg = onEntered(entries)
        entries = []
        error = msg
        submits += 1
    }

    private func back() {
        if !entries.isEmpty { entries = []; return }
        onDismiss?()
    }

    var body: some View {
        VStack(spacing: ProfileUI.s(14, 26)) {
            Text(title)
                .scaledFont(ProfileUI.title)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ProfileUI.s(12, 20)) {
                let count = fixed ?? (setting ? min(max(entries.count, PinRules.MIN_LENGTH), PinRules.MAX_LENGTH) : PinRules.MAX_LENGTH)
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(i < entries.count ? Color.accentPrimary : Color.textSecondary.opacity(0.35))
                        .frame(width: ProfileUI.s(14, 22), height: ProfileUI.s(14, 22))
                }
            }
            Text(error ?? " ")
                .scaledFont(ProfileUI.small)
                .foregroundColor(ProfileUI.errorColor)
            if type == .numbers {
                numberPad
            } else {
                directionPad
            }
            if let onDismiss, !ProfileUI.isTv {
                Button("Cancel", action: onDismiss).buttonStyle(ProfilePillStyle(filled: false))
            }
        }
        .padding(ProfileUI.s(24, 48))
        .frame(maxWidth: ProfileUI.s(360, 640))
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.cardBackground))
        .padding(16)
        .onAppear {
            openedAt = Date(); error = initialError
            padFocus = type == .numbers ? "1" : "dir"
        }
        // "Try again in N seconds" ticks every second, then clears.
        .task(id: submits) {
            guard let left = lockSeconds else { return }
            var n = left()
            guard n > 0 else { return }
            while n > 0 {
                error = "Try again in \(n) seconds"
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                n = left()
            }
            error = nil
        }
        #if os(tvOS)
        .onExitCommand { back() }
        #endif
    }

    private var numberPad: some View {
        let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]
        return VStack(spacing: ProfileUI.s(10, 18)) {
            ForEach(rows, id: \.self) { r in
                HStack(spacing: ProfileUI.s(14, 24)) { ForEach(r, id: \.self) { d in key(d) { add(d) } } }
            }
            HStack(spacing: ProfileUI.s(14, 24)) {
                key("Clear", id: "clear") { if ready { entries = [] } }
                key("0") { add("0") }
                key("OK", id: "ok", enabled: entries.count >= minLen) { submit() }
            }
        }
    }

    @ViewBuilder
    private var directionPad: some View {
        #if os(tvOS)
        // The D-pad itself is the input.
        Button { submit() } label: {
            Text("Up, Down, Left, Right. Select to confirm, Back to clear.")
                .scaledFont(ProfileUI.small)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(16)
        }
        .buttonStyle(ProfileRowButtonStyle())
        .focused($padFocus, equals: "dir")
        .onMoveCommand { d in
            switch d {
            case .up: add(PinDirection.up.rawValue)
            case .down: add(PinDirection.down.rawValue)
            case .left: add(PinDirection.left.rawValue)
            case .right: add(PinDirection.right.rawValue)
            @unknown default: break
            }
        }
        #else
        VStack(spacing: 10) {
            key("Up", symbol: "chevron.up") { add(PinDirection.up.rawValue) }
            HStack(spacing: 14) {
                key("Left", symbol: "chevron.left") { add(PinDirection.left.rawValue) }
                key("OK", id: "ok", enabled: entries.count >= minLen) { submit() }
                key("Right", symbol: "chevron.right") { add(PinDirection.right.rawValue) }
            }
            key("Down", symbol: "chevron.down") { add(PinDirection.down.rawValue) }
            Button("Clear") { if ready { entries = [] } }.buttonStyle(ProfilePillStyle(filled: false))
        }
        #endif
    }

    private func key(_ label: String, id: String? = nil, symbol: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).accessibilityLabel(label) } else { Text(label) }
            }
            .font(.system(size: ProfileUI.s(label.count > 1 && symbol == nil ? 16 : 24, label.count > 1 && symbol == nil ? 24 : 34), weight: .semibold))
            .frame(width: ProfileUI.s(64, 110), height: ProfileUI.s(52, 80))
        }
        .buttonStyle(ProfilePadKeyStyle())
        .focused($padFocus, equals: id ?? label)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct ProfilePadKeyStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(focused ? Color.contrastText(.accentPrimary) : .textPrimary)
            .background(Capsule().fill(focused ? Color.accentPrimary : Color.elevatedBackground))
            .overlay(Capsule().stroke(Color.textSecondary.opacity(ProfileUI.isTv ? 0 : 0.25), lineWidth: 1))
            .scaleEffect(focused ? 1.06 : (configuration.isPressed ? 0.94 : 1))
            .animation(.easeInOut(duration: 0.12), value: focused)
    }
}
