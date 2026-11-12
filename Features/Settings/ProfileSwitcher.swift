//  ProfileSwitcher.swift
//  Aerio
//
//  Profiles part 3: the switcher in the app chrome and the launch surfaces
//  (Android ProfilesUi.kt ProfileSwitcherButton / ProfileSwitcherHost,
//  ProfileRoleUi.kt TvLaunchProfilePicker and WhoIsWatchingTile,
//  ProfilePinUi.kt ProfileLaunchGate, and the MainActivity switch scrim).

import SwiftUI
import Combine
import SwiftData

/// The active Dispatcharr playlist id, when it has profiles.
@MainActor
private func activeProfilesPlaylist() -> String? {
    DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString
}

/// Opens Settings > Playlists > (active playlist), where PROFILES lives.
@MainActor
func openManageProfiles() {
    debugLog("[PROFILE] manage profiles from the switcher")
    // A Child has no playlist page (follow-up 12): its own PIN-gated Manage Profiles.
    let page: SettingsDeepLinkPage = ProfileManager.shared.activeRoleNow == .child ? .manageProfiles : .playlistDetail
    if let url = URL(string: "aerio://settings/\(page.rawValue)") {
        SettingsDeepLink.handle(url)
    }
}

#if os(iOS)
/// Phone and tablet Live TV header: the active profile's avatar, only with
/// 2+ profiles and never for a Child. Tap opens "Switch Profile".
struct ProfileSwitcherButton: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    var size: CGFloat = 38
    /// Toolbar use (iPhone Duo vertical bar): a titled symbol label, so the
    /// system overflow menu lists it as "Switch Profile" with an icon.
    var titled: Bool = false
    @ObservedObject private var manager = ProfileManager.shared
    @State private var open = false

    var body: some View {
        if let pid = activeProfilesPlaylist(),
           let profiles = manager.profilesByPlaylist[pid], profiles.count >= 2,
           RoleRules.canSeeSwitcher(manager.activeRoleNow) {
            let activeId = manager.activeProfileIds[pid]
            let active = profiles.first { $0.id == activeId } ?? profiles[0]
            Button { open = true } label: {
                if titled {
                    // A symbol, not the avatar: menus drop custom icon views
                    // (the overflow showed the bare title), and bars draw
                    // symbols in the same weight as their other items.
                    Label("Switch Profile", systemImage: "person.crop.circle")
                } else {
                    ProfileAvatarView(active, size: size)
                }
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch Profile")
                .sheet(isPresented: $open) {
                    SwitchProfileSheet(playlistId: pid) { open = false }
                        .presentationDetents(profiles.count > 4 ? [.medium, .large] : [.medium])
                        .presentationBackground(Color.appBackground)
                }
        }
    }
}

/// "Switch Profile": every profile, the active one checked, then Manage Profiles.
private struct SwitchProfileSheet: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let onClose: () -> Void
    @ObservedObject private var manager = ProfileManager.shared
    @State private var target: DispatcharrProfile?
    @State private var error: String?

    var body: some View {
        if let target {
            ProfileDialogHost {
                ProfileSwitchFlow(playlistId: playlistId, profile: target) { err in
                    self.target = nil
                    error = err
                    if err == nil && manager.activeProfileIds[playlistId] == target.id { onClose() }
                }
            }
        } else {
            let profiles = manager.profilesByPlaylist[playlistId] ?? []
            let activeId = manager.activeProfileIds[playlistId]
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switch Profile")
                        .scaledFont(ProfileUI.title)
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    ForEach(profiles) { p in
                        Button {
                            // The active profile only when it needs its sign-in form (held, or no key).
                            guard p.id != activeId || manager.needsSignIn(p.id), !manager.switching else { return }
                            error = nil
                            target = p
                        } label: {
                            ProfileRowContent(profile: p, isActive: p.id == activeId, locked: manager.hasPin(p.id))
                        }
                        .buttonStyle(ProfileRowButtonStyle())
                        .padding(.horizontal, 8)
                    }
                    if manager.switching { ProgressView().tint(.accentPrimary).padding(20) }
                    if let error {
                        Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor).padding(.horizontal, 20)
                    }
                    Button {
                        onClose()
                        openManageProfiles()
                    } label: {
                        Label("Manage Profiles", systemImage: "person.2.badge.gearshape").foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(ProfileRowButtonStyle())
                    .padding(.horizontal, 8).padding(.top, 6)
                }
                .padding(.vertical, 12)
            }
            .onAppear { manager.notePickerOpened(playlistId, "switch") }
        }
    }
}
#endif

/// One "Who is watching?" tile: avatar with the round accent ring on focus,
/// dimmed at rest, lock badge, name; [current] adds a "Current" caption.
struct WhoIsWatchingTile: View {
    let profile: DispatcharrProfile
    let locked: Bool
    var current = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            WhoIsWatchingTileLabel(icon: nil, profile: profile, label: profile.displayName, locked: locked, current: current)
        }
        .buttonStyle(WhoIsWatchingTileStyle())
    }
}

/// A picker tile that is an action (Add Profile, Manage Profiles).
struct PickerActionTile: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            WhoIsWatchingTileLabel(icon: icon, profile: nil, label: label, locked: false, current: false)
        }
        .buttonStyle(WhoIsWatchingTileStyle())
    }
}

private struct WhoIsWatchingTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct WhoIsWatchingTileLabel: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let icon: String?
    let profile: DispatcharrProfile?
    let label: String
    let locked: Bool
    let current: Bool
    @Environment(\.isFocused) private var focused
    private var lit: Bool { focused || !ProfileUI.isTv }

    var body: some View {
        let d = ProfileUI.s(88, 150)
        VStack(spacing: ProfileUI.s(10, 16)) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let profile {
                        ProfileAvatarView(profile, size: d)
                    } else {
                        Circle().fill(Color.textPrimary.opacity(0.12)).frame(width: d, height: d)
                            .overlay(Image(systemName: icon ?? "plus").font(.system(size: d * 0.42)).foregroundColor(.textPrimary))
                    }
                }
                .padding(5)
                .overlay(Circle().stroke(focused ? Color.accentPrimary : .clear, lineWidth: ProfileUI.s(3, 5)))
                .opacity(lit ? 1 : 0.6)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: ProfileUI.s(13, 22)))
                        .foregroundColor(.accentPrimary)
                        .padding(ProfileUI.s(5, 8))
                        .background(Circle().fill(Color.cardBackground))
                        .accessibilityLabel("PIN")
                }
            }
            .scaleEffect(focused ? 1.08 : 1)
            Text(label)
                .scaledFont(.system(size: ProfileUI.s(17, 28), weight: focused ? .semibold : .regular))
                .foregroundColor(lit ? .textPrimary : Color.textSecondary.opacity(0.7))
                .lineLimit(1)
            if current {
                Text("Current").scaledFont(ProfileUI.label).foregroundColor(.accentPrimary)
            }
        }
        .frame(width: ProfileUI.s(120, 210))
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

/// "Who is watching?" full screen. Launch: the TV launch picker (no Back,
/// pickAtLaunch). Switch: the current profile captioned, Back closes, and
/// Manage Profiles opens the playlist page.
struct WhoIsWatchingView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    enum Mode { case launch, switcher }
    let playlistId: String
    let mode: Mode
    var lastProfileId: String? = nil
    let onClose: () -> Void

    @ObservedObject private var manager = ProfileManager.shared
    @State private var busy = false
    @State private var error: String?
    @State private var flow: Flow?
    @FocusState private var focus: String?

    /// signIn: the profile, and whether its form is the playlist's own sign-in
    /// (the default profile whose key is held), fixed when the form opens.
    enum Flow { case pin(DispatcharrProfile), confirm(DispatcharrProfile), adminPin, add, move(DispatcharrProfile), signIn(DispatcharrProfile, asPlaylist: Bool) }

    /// The hold that opened Move also ends in a Select release; that one is swallowed.
    @State private var swallowNextSelect = false

    /// Long press on a tile (Admin or Standard): Move Left, Move Right, Move to Front (Android ProfileMoveSheet).
    private var noFlow: Bool { if case .none = flow { return true }; return false }

    private var canReorder: Bool { RoleRules.isFullAccess(manager.activeRole(playlistId)) }

    private func openMove(_ p: DispatcharrProfile) {
        guard canReorder, !busy else { return }
        debugLog("[PROFILE] picker move opened")
        flow = .move(p)
    }

    private func choose(_ p: DispatcharrProfile) {
        // Held after a server address change: sign in again first (Cancel keeps the current profile).
        if manager.needsSignIn(p.id) {
            error = nil
            flow = .signIn(p, asPlaylist: manager.pickForm(p.id) == .playlistForm)
            return
        }
        busy = true; error = nil
        Task {
            do {
                if mode == .launch {
                    try await manager.pickAtLaunch(p.id)
                } else {
                    try await manager.switchTo(playlistId, p.id)
                    onClose()
                }
            } catch { self.error = error.localizedDescription.isEmpty ? "Switch failed" : error.localizedDescription }
            busy = false
        }
    }

    private func picked(_ p: DispatcharrProfile, current: Bool) {
        if swallowNextSelect { swallowNextSelect = false; return }
        guard !busy else { return }
        // The current profile, unless it is held (a Child kept after a server change): then its sign-in form.
        if mode == .switcher && current && !manager.needsSignIn(p.id) { onClose(); return }
        if manager.hasPin(p.id) && !manager.hasSwitchTicket(p.id) { flow = .pin(p); return }
        afterPin(p)
    }

    /// After the PIN: the sign-in form first when the profile needs one (held,
    /// keyless, or its key held as rejected; nothing sent with the held key),
    /// then the stop-playback confirm, then the switch.
    private func afterPin(_ p: DispatcharrProfile) {
        if manager.needsSignIn(p.id) { error = nil; flow = .signIn(p, asPlaylist: manager.pickForm(p.id) == .playlistForm); return }
        afterSignIn(p)
    }

    private func afterSignIn(_ p: DispatcharrProfile) {
        if mode == .switcher && PlayerSession.shared.mode != .idle { flow = .confirm(p); return }
        choose(p)
    }

    private func move(_ p: DispatcharrProfile, _ how: ProfileOrder.Move) {
        flow = nil
        do { _ = try manager.move(playlistId, p.id, how) } catch { self.error = error.localizedDescription }
        focus = p.id
    }

    private func startAdd() {
        guard !busy else { return }
        debugLog("[PROFILE] add profile from picker")
        if manager.adminHasPin(playlistId) { flow = .adminPin } else { manager.pickerAddUnlocked = playlistId; flow = .add }
    }

    var body: some View {
        let profiles = manager.profilesByPlaylist[playlistId] ?? []
        let currentId = mode == .launch
            ? (lastProfileId ?? profiles.first(where: \.isDefault)?.id)
            : (manager.activeProfileIds[playlistId] ?? profiles.first(where: \.isDefault)?.id)
        ZStack {
            Color.appBackground.ignoresSafeArea()
            switch flow {
            case .pin(let p):
                SwitchPinFlow(profile: p, onDismiss: { flow = nil }) {
                    flow = nil
                    afterPin(p)
                }
            case .confirm(let p):
                StopPlaybackConfirm(name: p.displayName, onCancel: { flow = nil }) { flow = nil; choose(p) }
            case .adminPin:
                AdminPinFlow(playlistId: playlistId, onDismiss: { flow = nil }) {
                    manager.pickerAddUnlocked = playlistId
                    flow = .add
                }
            case .add:
                AddProfileFlow(playlistId: playlistId) { flow = nil; manager.pickerAddUnlocked = nil }
            case .signIn(let p, let asPlaylist):
                // A non-default profile's own form, or the playlist's own sign-in for the default.
                KeySignInView(playlistID: playlistId, heldProfile: asPlaylist ? nil : p, hosted: false,
                              onClose: { flow = nil; focus = p.id }, onSignedIn: { flow = nil; afterSignIn(p) })
            case .move(let p):
                let at = profiles.firstIndex { $0.id == p.id } ?? -1
                ProfileDialog(title: p.displayName, actionStack: true, onCancel: { flow = nil; focus = p.id }) {
                    if at > 0 { ProfileActionButton(label: "Move Left") { move(p, .earlier) } }
                    if at >= 0 && at < profiles.count - 1 { ProfileActionButton(label: "Move Right") { move(p, .later) } }
                    if at > 0 { ProfileActionButton(label: "Move to Front") { move(p, .first) } }
                }
            case nil:
                VStack(spacing: ProfileUI.s(28, 48)) {
                    Text("Who is watching?")
                        .scaledFont(.system(size: ProfileUI.s(28, 52), weight: .semibold))
                        .foregroundColor(.textPrimary)
                    // Centered under the title when the row fits; scrolls
                    // only when it does not (tvOS review 2026-11-05: the
                    // avatars sat left-aligned under a centered title).
                    ViewThatFits(in: .horizontal) {
                        profileRow(profiles, currentId)
                        ScrollView(.horizontal, showsIndicators: false) { profileRow(profiles, currentId) }
                    }
                    .frame(maxWidth: .infinity)
                    #if os(tvOS)
                    .background(
                        SwitchStreamSelectHoldDetector(
                            minimumPressDuration: 0.5,
                            isEnabled: canReorder && noFlow,
                            onBegan: {
                                guard let id = focus, let p = profiles.first(where: { $0.id == id }) else { return }
                                swallowNextSelect = true
                                openMove(p)
                            },
                            onEnded: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { swallowNextSelect = false } }
                        )
                        .allowsHitTesting(false)
                    )
                    #endif
                    if busy || manager.switching { ProgressView().tint(.accentPrimary) }
                    if let error { Text(error).scaledFont(ProfileUI.body).foregroundColor(ProfileUI.errorColor) }
                }
                .onAppear {
                    focus = currentId
                    manager.notePickerOpened(playlistId, mode == .launch ? "launch" : "switch")
                }
                #if os(tvOS)
                .onExitCommand(perform: mode == .switcher ? onClose : nil)
                #endif
            }
        }
    }
    @ViewBuilder private func profileRow(_ profiles: [DispatcharrProfile], _ currentId: String?) -> some View {
                    HStack(spacing: ProfileUI.s(28, 48)) {
                        ForEach(profiles) { p in
                            let isCurrent = p.id == currentId
                            WhoIsWatchingTile(profile: p, locked: manager.hasPin(p.id), current: mode == .switcher && isCurrent) {
                                picked(p, current: isCurrent)
                            }
                            .focused($focus, equals: p.id)
                            #if os(iOS)
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in openMove(p) })
                            #endif
                        }
                        if RoleRules.canSeeSwitcher(manager.activeRoleNow) {
                            PickerActionTile(icon: "plus", label: "Add Profile", action: startAdd)
                            if mode == .switcher {
                                PickerActionTile(icon: "person.2.badge.gearshape", label: "Manage Profiles") {
                                    onClose()
                                    openManageProfiles()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, ProfileUI.s(24, 80))
                    .padding(.vertical, ProfileUI.s(12, 40))
    }
}

/// Root chrome for profiles: the switch scrim, the launch PIN gate, and the
/// TV launch picker. Applied once on the main tab view.
struct ProfileRootChrome: ViewModifier {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    @ObservedObject private var manager = ProfileManager.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if manager.switching {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        ProgressView().tint(.accentPrimary).scaleEffect(ProfileUI.s(1.4, 2))
                    }
                    .transition(.opacity)
                }
            }
            // The launch PIN gate and the Apple TV launch picker live in their own
            // window above every alert and sheet (LaunchLockWindow), never a cover
            // another presentation could block or drop (security fix 2026-11-12).
            .onAppear {
                manager.isPlaying = { PlayerSession.shared.mode != .idle }
                LaunchLockWindow.shared.install()
            }
    }
}

/// What the launch lock window shows: the restored profile's PIN entry, or the
/// Apple TV "Who is watching?" picker at launch.
struct LaunchLockView: View {
    @ObservedObject private var themeLive = ThemeManager.shared
    @ObservedObject private var manager = ProfileManager.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if let p = manager.launchGate {
                // A locked restored profile covers everything until its PIN is entered.
                Color.black.opacity(0.92).ignoresSafeArea()
                ProfilePinEntry(
                    title: "Enter PIN for \(p.displayName)", type: manager.pinType(p.id) ?? .numbers,
                    pinLength: manager.pinLength(p.id), lockSeconds: { manager.pinLockSeconds(p.id) },
                    onDismiss: nil,
                    onEntered: { ProfileCopy.pinCheckMessage(manager.unlockLaunchGate($0)) }
                )
            } else if let pk = manager.launchPicker {
                #if os(tvOS)
                // Apple TV "Who is watching?" at launch (showLaunchPicker).
                WhoIsWatchingView(playlistId: pk.playlistId, mode: .launch, lastProfileId: pk.lastProfileId) {}
                #else
                let _ = pk
                #endif
            }
        }
    }
}

/// The launch lock's own window, one per foreground scene, at a level above
/// alerts: an alert, sheet, or cover in the app's window can neither block nor
/// drop it, and nothing under it is usable until the PIN passes. A watchdog
/// puts it back on screen whenever a scene lacks it while locked.
@MainActor
final class LaunchLockWindow {
    static let shared = LaunchLockWindow()
    private init() {}

    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var bag: [AnyCancellable] = []
    private var watchdog: Task<Void, Never>?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let pm = ProfileManager.shared
        pm.$launchGate.combineLatest(pm.$launchPicker)
            .receive(on: RunLoop.main)
            .sink { [weak self] gate, picker in self?.update(locked: gate != nil || picker != nil) }
            .store(in: &bag)
        for name in [UIScene.didActivateNotification, UIScene.willEnterForegroundNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.update(locked: ProfileManager.shared.launchLocked) }
                .store(in: &bag)
        }
    }

    private var scenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .unattached && $0.activationState != .background }
    }

    private func update(locked: Bool) {
        guard locked else { hide(); return }
        show()
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled, ProfileManager.shared.launchLocked {
                self?.show()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.watchdog = nil
            self?.hide()
        }
    }

    #if os(tvOS)
    /// Apple TV: the lock is presented over the app's topmost controller, the
    /// same proven path as the rejected-key prompt and Fix Login (focus moves
    /// to it); the watchdog presents it again whenever it is not on screen.
    private var host: UIViewController?

    private func show() {
        if let h = host, h.viewIfLoaded?.window != nil { return }
        let all = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { $0.windowLevel == .normal && !$0.isHidden }
        guard var top = (all.first { $0.isKeyWindow } ?? all.first)?.rootViewController else { return }
        while let next = top.presentedViewController, next !== host { top = next }
        guard !top.isBeingDismissed, !top.isBeingPresented, !(top is UIAlertController) else { return }
        var root: AnyView = AnyView(LaunchLockView())
        if let c = AerioApp.sharedContainer { root = AnyView(LaunchLockView().modelContainer(c)) }
        let h = UIHostingController(rootView: root)
        h.modalPresentationStyle = .fullScreen
        h.isModalInPresentation = true
        host = h
        top.present(h, animated: false)
        debugLog("[PROFILE] launch lock on screen (presented over the topmost screen)")
    }

    private func hide() {
        guard let h = host else { return }
        host = nil
        h.presentingViewController?.dismiss(animated: true)
        debugLog("[PROFILE] launch lock passed; its screen is gone")
    }
    #else
    /// Puts the lock on every foreground scene that lacks it.
    private func show() {
        let live = scenes
        let showing = live.filter { s in windows[ObjectIdentifier(s)].map { !$0.isHidden && $0.windowScene === s } ?? false }.count
        guard LaunchLockRules.gateNeedsPresenting(locked: ProfileManager.shared.launchLocked, scenes: live.count,
                                                 scenesShowingGate: showing) else { return }
        for scene in live where windows[ObjectIdentifier(scene)].map({ $0.isHidden || $0.windowScene !== scene }) ?? true {
            var root: AnyView = AnyView(LaunchLockView())
            if let c = AerioApp.sharedContainer { root = AnyView(LaunchLockView().modelContainer(c)) }
            let host = UIHostingController(rootView: root)
            let w = UIWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            w.rootViewController = host
            w.makeKeyAndVisible()
            windows[ObjectIdentifier(scene)] = w
            debugLog("[PROFILE] launch lock on screen (its own window above every alert and sheet)")
        }
    }

    private func hide() {
        guard !windows.isEmpty else { return }
        for (_, w) in windows {
            w.isHidden = true
            // Hand the keyboard and focus back to the app's own window.
            w.windowScene?.windows.first { $0 !== w && !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
        }
        windows.removeAll()
        debugLog("[PROFILE] launch lock passed; its window is gone")
    }
    #endif
}

#if os(tvOS)
/// Apple TV top bar: the active profile's avatar right after Settings
/// (Android TvProfileSwitcherButton). Same diameter as the Refresh and
/// Search circles; the avatar disc is the button and focus rings its edge.
/// Only with 2+ profiles and never for a Child. Opens "Who is watching?".
struct TVProfileSwitcherCircle: View {
    @ObservedObject private var manager = ProfileManager.shared
    @State private var open = false
    @State private var focused = false

    var body: some View {
        if let pid = activeProfilesPlaylist(),
           let profiles = manager.profilesByPlaylist[pid], profiles.count >= 2,
           RoleRules.canSeeSwitcher(manager.activeRoleNow) {
            let activeId = manager.activeProfileIds[pid]
            let active = profiles.first { $0.id == activeId } ?? profiles[0]
            // The circle sits inside the system tab bar's frame (UITabBar
            // @0,46 1920x68 with a full-width focus guide; simulator hierarchy
            // dump 2026-11-06), so the engine's own horizontal search from
            // here is wrong both ways: Left finds nothing and Right lands back
            // on the selected pill (Apple TV trace 2026-11-06 13:37, 13:39).
            // A UIKit press catcher owns focus instead: from a UIKit item the
            // engine's Left reaches the last pill on its own (simulator trace
            // 13:56), with the explicit pill focus as the fallback, and Right
            // is consumed so focus stays put (last item on the bar). Up and
            // Down stay with the focus engine. Simulator: Select opens the
            // picker, Menu closes it and focus returns to the circle.
            ProfileAvatarView(active, size: 60)
                .overlay(Circle().stroke(focused ? Color.white : .clear, lineWidth: 4))
                .scaleEffect(focused ? 1.08 : 1)
                .animation(.easeInOut(duration: 0.15), value: focused)
                .overlay(
                    TVPressOverlay(
                        isFocused: $focused,
                        interceptsDirectional: true,
                        horizontalAdjustOnly: true,
                        onTap: {
                            debugLog("[PROFILE] picker opened (tv top bar)")
                            open = true
                        },
                        onLongPress: {},
                        onMoveLeft: {
                            debugLog("[FOCUS] profile circle: Left -> Settings pill")
                            TVTabPillFocuser.focusPill(title: "Settings", reason: "profile circle Left")
                        },
                        onMoveRight: {
                            debugLog("[FOCUS] profile circle: Right stays (last item on the bar)")
                        })
                )
                .accessibilityLabel("Switch Profile")
                .fullScreenCover(isPresented: $open) {
                    WhoIsWatchingView(playlistId: pid, mode: .switcher) { open = false }
                }
        }
    }
}
#endif
