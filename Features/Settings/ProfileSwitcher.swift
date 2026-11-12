//  ProfileSwitcher.swift
//  Aerio
//
//  Profiles part 3: the switcher in the app chrome and the launch surfaces
//  (Android ProfilesUi.kt ProfileSwitcherButton / ProfileSwitcherHost,
//  ProfileRoleUi.kt TvLaunchProfilePicker and WhoIsWatchingTile,
//  ProfilePinUi.kt ProfileLaunchGate, and the MainActivity switch scrim).

import SwiftUI

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
                            // The active profile only when it is held (its sign-in form).
                            guard p.id != activeId || manager.isHeld(p.id), !manager.switching else { return }
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

    enum Flow { case pin(DispatcharrProfile), confirm(DispatcharrProfile), adminPin, add, move(DispatcharrProfile), signIn(DispatcharrProfile) }

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
        if ProfileHostHoldRules.onPick(isHeld: manager.isHeld(p.id), hasStoredSignIn: manager.signIns.hasStored(p.id)) == .signInAgain {
            error = nil
            flow = .signIn(p)
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
        if mode == .switcher && current && !manager.isHeld(p.id) { onClose(); return }
        if manager.hasPin(p.id) && !manager.hasSwitchTicket(p.id) { flow = .pin(p); return }
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
                    if mode == .switcher && PlayerSession.shared.mode != .idle { flow = .confirm(p) } else { choose(p) }
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
            case .signIn(let p):
                KeySignInView(playlistID: playlistId, heldProfile: p, hosted: false,
                              onClose: { flow = nil; focus = p.id }, onSignedIn: { flow = nil; choose(p) })
            case .move(let p):
                let at = profiles.firstIndex { $0.id == p.id } ?? -1
                ProfileDialog(title: p.displayName, onCancel: { flow = nil; focus = p.id }) {
                    if at > 0 { ProfileChoiceRow(label: "Move Left") { move(p, .earlier) } }
                    if at >= 0 && at < profiles.count - 1 { ProfileChoiceRow(label: "Move Right") { move(p, .later) } }
                    if at > 0 { ProfileChoiceRow(label: "Move to Front") { move(p, .first) } }
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
            // A locked restored profile covers everything until its PIN is entered.
            .fullScreenCover(isPresented: Binding(get: { manager.launchGate != nil }, set: { _ in })) {
                if let p = manager.launchGate {
                    ZStack {
                        Color.black.opacity(0.92).ignoresSafeArea()
                        ProfilePinEntry(
                            title: "Enter PIN for \(p.displayName)", type: manager.pinType(p.id) ?? .numbers,
                            pinLength: manager.pinLength(p.id), lockSeconds: { manager.pinLockSeconds(p.id) },
                            onDismiss: nil,
                            onEntered: { ProfileCopy.pinCheckMessage(manager.unlockLaunchGate($0)) }
                        )
                    }
                    .interactiveDismissDisabled()
                }
            }
            #if os(tvOS)
            // Apple TV "Who is watching?" at launch (showLaunchPicker).
            .fullScreenCover(isPresented: Binding(get: { manager.launchPicker != nil }, set: { _ in })) {
                if let pk = manager.launchPicker {
                    WhoIsWatchingView(playlistId: pk.playlistId, mode: .launch, lastProfileId: pk.lastProfileId) {}
                }
            }
            #endif
            .onAppear {
                manager.isPlaying = { PlayerSession.shared.mode != .idle }
            }
    }
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
