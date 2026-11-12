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
    /// Apple TV's screen height in points (1920 x 1080 at every output resolution).
    static let tvScreenHeight: CGFloat = 1080
    /// Action capsules: the gap between two in one group, and the one larger gap
    /// that opens the next group (Remove, then Cancel; owner 2026-11-12).
    static var actionGap: CGFloat { s(8, 16) }
    static var actionGroupGap: CGFloat { s(20, 36) }
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

    /// Letter and icon ink: #0B1220 on teal, orange, green, and slate, white
    /// on the rest, in light and dark mode (AvatarCatalog.inkHex, the owner's
    /// final pick 2026-11-11; Android draws the same set).
    static func ink(_ id: String) -> Color { Color(hex6: AvatarCatalog.inkHex(id)) }

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
                Text(AvatarCatalog.initial(name: name, username: username))
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
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
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
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    var lifted = false
    var destructive = false
    @Environment(\.isFocused) private var focused
    @Environment(\.inProfileDialog) private var inDialog
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: ProfileUI.s(12, 16), style: .continuous)
        return configuration.label
            // Inside a profile dialog on iPhone and iPad the row has no inset of its
            // own, so its text shares the card's one left edge (owner 2026-11-12).
            // Apple TV keeps it: its focus platter needs the room.
            .padding(.horizontal, inDialog && !ProfileUI.isTv ? 0 : ProfileUI.s(14, 24))
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
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
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

/// One full-width action capsule, for dialogs that are a plain list of actions
/// (owner 2026-11-12: they read as buttons, matching the stacked buttons of the
/// "API key no longer valid" prompt). Neutral secondary fill (13% of the text
/// color, measured from that prompt), centered label, red label for a
/// destructive action. Apple TV: accent focus ring and a brighter fill, no
/// scale (the dialog's scroll view would clip a grown capsule).
struct ProfileActionButtonStyle: ButtonStyle {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    var destructive = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        return configuration.label
            .scaledFont(ProfileUI.bodyStrong)
            .foregroundColor(destructive ? ProfileUI.errorColor : .textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, ProfileUI.s(16, 28))
            .padding(.vertical, ProfileUI.s(8, 12))
            .frame(maxWidth: .infinity, minHeight: ProfileUI.s(48, 66))
            .background(shape.fill(Color.textPrimary.opacity(configuration.isPressed || focused ? 0.22 : 0.13)))
            .overlay(shape.stroke(focused ? Color.accentPrimary : .clear, lineWidth: ProfileUI.s(2, 3)))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

/// An action capsule (ProfileActionButtonStyle) with its label. [newGroup]
/// opens a group: the larger gap above it instead of the usual one.
struct ProfileActionButton: View {
    let label: String
    var destructive = false
    var newGroup = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(label) }
            .buttonStyle(ProfileActionButtonStyle(destructive: destructive))
            .padding(.top, newGroup ? ProfileUI.actionGroupGap - ProfileUI.actionGap : 0)
    }
}

/// One choice row (Android ChoiceRow) with a radio for one-of-N. A dialog that is
/// a plain list of actions uses ProfileActionButton instead.
struct ProfileChoiceRow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
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

// MARK: - Field box

extension View {
    /// The box behind a text field in the profile dialogs and forms. iPhone and
    /// iPad: a light fill and hairline that show on the dialog card (the old
    /// elevatedBackground fill is the card's own color, so the fields were
    /// invisible, measured 2026-11-11). Apple TV: nothing extra, the system
    /// draws the field's own platter (a box under it made a double outline).
    func profileFieldBox() -> some View {
        #if os(tvOS)
        return self
        #else
        return self
            .padding(ProfileUI.s(10, 16))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
        #endif
    }
}

// MARK: - Themed dialog

/// The themed dialog card every profile prompt uses (Android SettingsAlertDialog).
struct ProfileDialog<Content: View>: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let title: String
    var centeredTitle = false
    var subtitle: String? = nil
    var cancelLabel: String? = "Cancel"
    var confirm: (label: String, enabled: Bool, destructive: Bool, action: () -> Void)? = nil
    /// A plain list of actions (ProfileActionButton rows): Cancel is the last
    /// capsule of the stack, kept outside the scroll so it is always reachable,
    /// instead of the small button at the bottom right.
    var actionStack = false
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content
    /// The content's own height: the card hugs it and scrolls only past the cap.
    @State private var contentHeight: CGFloat = 0
    @Environment(\.profileDialogMaxHeight) private var maxHeight

    // One rule for every profile dialog (owner 2026-11-12): the title (and its
    // subtitle) centered; rows and text below stay leading. `centeredTitle` is
    // kept for its call sites and no longer changes anything.
    var body: some View {
        // Capsules sit 8 pt apart on iPhone and iPad, like the prompt's buttons;
        // Cancel is its own group, so the larger gap sits above it.
        let gap = actionStack ? ProfileUI.actionGap : ProfileUI.s(6, 12)
        let inset = ProfileUI.s(2, 12)
        VStack(alignment: .center, spacing: ProfileUI.s(12, 22)) {
            Text(title)
                .scaledFont(ProfileUI.title)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .scaledFont(ProfileUI.small)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Sized to its content (like "Sign in to Dispatcharr"); it scrolls only
            // when the card would pass about 80% of the screen.
            VStack(spacing: max(0, (actionStack ? ProfileUI.actionGroupGap : gap) - inset)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: gap) { content() }
                        .environment(\.inProfileDialog, true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, inset)
                        .padding(.horizontal, ProfileUI.s(0, 12))
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in contentHeight = h }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Past the cap the cut can fall exactly between two capsules; the
                // flash (once the content is measured) shows there is more to
                // scroll. A no-op when it all fits.
                .scrollIndicatorsFlash(trigger: contentHeight)
                .frame(maxHeight: max(contentHeight, 1))
                if actionStack, let cancelLabel {
                    ProfileActionButton(label: cancelLabel, action: onCancel)
                        .padding(.horizontal, ProfileUI.s(0, 12))
                }
            }
            if !actionStack {
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
        }
        .padding(ProfileUI.s(20, 48))
        .frame(maxWidth: ProfileUI.s(520, 1000))
        .background(RoundedRectangle(cornerRadius: ProfileUI.s(20, 28), style: .continuous).fill(Color.cardBackground))
        // The cap only limits what the card is offered (its content scrolls past
        // it); the card itself stays the size of its content.
        .frame(maxHeight: maxHeight)
        .padding(ProfileUI.s(16, 60))
        // A tap on the host's backdrop is this Cancel; with no Cancel, nothing.
        .profileDialogDismiss(cancelLabel == nil ? nil : onCancel)
        #if os(tvOS)
        .onExitCommand(perform: onCancel)
        #endif
    }
}

/// The tallest a profile dialog card grows before its content scrolls.
private struct ProfileDialogMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

/// True for views inside a profile dialog's content (its rows lose their own inset).
private struct InProfileDialogKey: EnvironmentKey {
    static let defaultValue = false
}

/// The Cancel of the dialog on screen, for its host's backdrop. Only a dialog
/// with a Cancel publishes one (ProfileDialog with a Cancel button, a PIN entry
/// with onDismiss); everything else leaves the backdrop inert.
struct ProfileDialogDismiss {
    let action: () -> Void
}

private struct ProfileDialogDismissKey: PreferenceKey {
    static var defaultValue: ProfileDialogDismiss? { nil }
    static func reduce(value: inout ProfileDialogDismiss?, nextValue: () -> ProfileDialogDismiss?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Publishes [action] as what a tap outside the card does (nil: nothing).
    func profileDialogDismiss(_ action: (() -> Void)?) -> some View {
        preference(key: ProfileDialogDismissKey.self, value: action.map(ProfileDialogDismiss.init))
    }
}

extension EnvironmentValues {
    var profileDialogMaxHeight: CGFloat {
        get { self[ProfileDialogMaxHeightKey.self] }
        set { self[ProfileDialogMaxHeightKey.self] = newValue }
    }

    var inProfileDialog: Bool {
        get { self[InProfileDialogKey.self] }
        set { self[InProfileDialogKey.self] = newValue }
    }
}

/// Hosts a dialog centered over a dimmed backdrop (one presentation for every
/// step of a flow). The card is sized to its content and capped at about 80%
/// of the screen.
///
/// iPhone and iPad (owner 2026-11-12, Android parity: SettingsAlertDialog's
/// default dismiss on an outside click): a tap on the backdrop does exactly
/// what the dialog's Cancel does, the same handler, so every Cancel side effect
/// (PIN Required undoing the add that opened it) is the same. A dialog with no
/// Cancel publishes nothing and the tap does nothing. Taps on the card land on
/// the card, never the backdrop. Apple TV has no touch backdrop; Menu is the
/// dialog's Cancel there (onExitCommand).
struct ProfileDialogHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(tvOS)
        // Apple TV shows this in a sheet that sizes itself to its content. A
        // GeometryReader root has no size of its own there, so the card
        // collapsed to a sliver at screen center (device report 2026-11-12,
        // build 98fc424). The host is the backdrop and the card, as before
        // 98fc424, so the card takes its content's size (up to 1000 pt wide).
        // The 80% cap comes from the 1080 pt screen, never from the sheet's own
        // size: a cap measured from a content-sized sheet shrinks the card on
        // every pass (measured in a standalone tvOS probe).
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            content()
                .environment(\.profileDialogMaxHeight, ProfileUI.tvScreenHeight * 0.8)
        }
        .presentationBackground(.clear)
        #else
        GeometryReader { geo in
            ZStack {
                content()
                    .environment(\.profileDialogMaxHeight, geo.size.height * 0.8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .backgroundPreferenceValue(ProfileDialogDismissKey.self) { dismiss in
                Color.black.opacity(0.6).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss?.action() }
            }
        }
        .presentationBackground(.clear)
        #endif
    }
}

// MARK: - PIN entry

/// One PIN entry (Android PinEntryDialog). [onEntered] returns an error to
/// show (the entry clears) or nil when accepted. [onDismiss] nil = the
/// launch gate, which cannot be dismissed.
struct ProfilePinEntry: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
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
        // A tap on the host's backdrop is this Cancel; nil (the launch gate): nothing.
        .profileDialogDismiss(onDismiss)
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
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
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
