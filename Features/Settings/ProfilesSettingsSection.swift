//  ProfilesSettingsSection.swift
//  Aerio
//
//  Profiles part 3: Settings > Playlists > (Dispatcharr playlist) > PROFILES
//  (Android feature/settings/ProfilesUi.kt ProfilesSection after 1903291b and
//  83c0a8ef). Rows with avatar, name, role, and the active check; Add
//  Profile and the Device Admin PIN rows for an Admin; a short press opens
//  the actions sheet with "Switch to this profile" first. iPhone and iPad
//  move with Move Up / Move Down in the sheet; Apple TV reorders by hold
//  (ProfilesTVSection).

import SwiftUI

/// What the profiles presentation shows. One presentation; the route swaps in place.
enum ProfileRoute: Equatable {
    case actions(DispatcharrProfile)
    case rename(DispatcharrProfile)
    case avatar(DispatcharrProfile)
    case remove(DispatcharrProfile)
    case removeAdminPin(DispatcharrProfile)
    case setPin(DispatcharrProfile)
    case removePin(DispatcharrProfile)
    case resetPin(DispatcharrProfile)
    case role(DispatcharrProfile)
    case channelProfiles(DispatcharrProfile)
    case switchTo(DispatcharrProfile)
    /// iPhone and iPad: "Show User QR Code" (own profile, or any profile for an Admin).
    case userQr(DispatcharrProfile)
    case add
    case deviceSet
    case deviceRemove
    /// A refused action: its title, the reason, and OK (ProfileRefusal).
    case refused(ProfileRefusal)
}

@MainActor
final class ProfilesFlowModel: ObservableObject {
    @Published var route: ProfileRoute?
    @Published var presented = false
    /// Apple TV: a row is lifted for reorder; the rest of the page holds still.
    @Published var liftActive = false

    func open(_ r: ProfileRoute) {
        route = r
        presented = true
    }

    /// A flow ended. A refusal reason shows as a dialog titled with the action
    /// ([title]), never as footer text; with no reason the presentation closes.
    func close(_ error: String? = nil, title: String = "") {
        if let r = ProfileRefusal.make(title: title, reason: error) {
            refuse(r)
            return
        }
        presented = false
        route = nil
    }

    /// Show a refused action (also a refusal outside a flow, the Apple TV reorder).
    func refuse(_ r: ProfileRefusal) {
        debugLog("[PROFILES] refused: \(r.title)")
        route = .refused(r)
        presented = true
    }
}

/// The gates the section and the actions sheet read (Android ProfilesViewModel).
@MainActor
struct ProfileGates {
    let playlistId: String
    var pm: ProfileManager { .shared }
    var role: ProfileRole? { pm.activeRole(playlistId) }
    /// Add and remove profiles (the local Admin or Standard role).
    var isAdmin: Bool { RoleRules.canManageProfiles(role) && role != nil }
    /// Admin or Standard (identical in AerioTV).
    var isRoleAdmin: Bool { RoleRules.isFullAccess(role) }
    var activeId: String? { pm.activeProfileIdNow(playlistId) }
    func canEditAvatar(_ id: String) -> Bool { RoleRules.canEditAvatar(actor: role, isOwn: activeId == id) }
}

/// The presentation content for a route (every platform).
struct ProfileFlowHost: View {
    let playlistId: String
    @ObservedObject var model: ProfilesFlowModel
    @ObservedObject private var manager = ProfileManager.shared

    var body: some View {
        ProfileDialogHost {
            switch model.route {
            case .actions(let p): ProfileActionsSheet(playlistId: playlistId, profile: p, model: model)
            case .rename(let p): RenameProfileFlow(profile: p) { model.close() }
            case .avatar(let p):
                AvatarPickerFlow(profile: p, onClose: { model.close() }) { spec in
                    do { try manager.setAvatar(playlistId, p.id, spec); model.close() }
                    catch { model.close(error.localizedDescription, title: ProfileActionTitle.avatar) }
                }
            case .remove(let p):
                ProfileDialog(title: "Remove Profile", confirm: ("Remove", true, true, {
                    if manager.roleOf(p.id) == .child { model.route = .removeAdminPin(p) } else { remove(p) }
                }), onCancel: { model.close() }) {
                    Text("Remove \(p.displayName)? Favorites, recordings, and watch history for this profile on this device will be deleted.")
                        .scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
                }
            case .removeAdminPin(let p):
                AdminPinFlow(playlistId: playlistId, title: PinCopy.removeChild(p.displayName),
                             onDismiss: { model.close() }) { remove(p) }
            case .setPin(let p):
                SetPinFlow(playlistId: playlistId, profile: p) {
                    model.close($0, title: ProfileActionTitle.setPin(hasPin: manager.hasPin(p.id)))
                }
            case .removePin(let p): RemovePinFlow(playlistId: playlistId, profile: p) { model.close($0, title: ProfileActionTitle.removePin) }
            case .resetPin(let p): ResetPinFlow(playlistId: playlistId, profile: p) { model.close($0, title: ProfileActionTitle.resetPin) }
            case .role(let p): RoleFlow(playlistId: playlistId, profile: p) { model.close($0, title: ProfileActionTitle.role) }
            case .channelProfiles(let p):
                ChannelProfilesFlow(playlistId: playlistId, profile: p) { model.close($0, title: ProfileActionTitle.channelProfiles) }
            case .switchTo(let p):
                ProfileSwitchFlow(playlistId: playlistId, profile: p) { model.close($0, title: ProfileActionTitle.switchProfile) }
            case .userQr(let p):
                #if os(iOS)
                UserQrFlow(playlistId: playlistId, profileId: p.id) { model.close() }
                #else
                EmptyView()
                #endif
            case .add: AddProfileFlow(playlistId: playlistId) { model.close() }
            case .deviceSet:
                let title = ProfileActionTitle.deviceAdminPin(has: manager.hasDeviceAdminPin(playlistId))
                DeviceAdminPinSetFlow(playlistId: playlistId) { model.close($0, title: title) }
            case .deviceRemove:
                DeviceAdminPinRemoveFlow(playlistId: playlistId) { model.close($0, title: ProfileActionTitle.removeDeviceAdminPin) }
            case .refused(let r): ProfileRefusalDialog(refusal: r) { model.close() }
            case nil: EmptyView()
            }
        }
    }

    private func remove(_ p: DispatcharrProfile) {
        Task {
            do { try await manager.remove(p.id); model.close() }
            catch { model.close(error.localizedDescription, title: ProfileActionTitle.removeProfile) }
        }
    }
}

/// The row actions sheet: "Switch to this profile" first (hidden on the active one).
struct ProfileActionsSheet: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let profile: DispatcharrProfile
    @ObservedObject var model: ProfilesFlowModel
    @ObservedObject private var manager = ProfileManager.shared

    var body: some View {
        let g = ProfileGates(playlistId: playlistId)
        let p = manager.store.byId(profile.id) ?? profile
        let isActive = p.id == g.activeId
        let hasPin = manager.hasPin(p.id)
        let canPin = manager.canManagePin(playlistId, p.id)
        let list = manager.profilesByPlaylist[playlistId] ?? []
        let at = list.firstIndex { $0.id == p.id } ?? -1
        ProfileDialog(title: p.displayName, actionStack: true, onCancel: { model.close() }) {
            // Header block: these lines describe the title, so they are centered with it.
            VStack(spacing: 2) {
                Text([isActive ? "Active" : nil, p.effectiveRole.label, hasPin ? "PIN" : nil].compactMap { $0 }.joined(separator: "  "))
                    .scaledFont(ProfileUI.small).foregroundColor(.accentPrimary)
                Text(p.username).scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, ProfileUI.s(4, 6))
            if !isActive {
                ProfileActionButton(label: "Switch to this profile") {
                    debugLog("[PROFILES] switch from actions")
                    model.route = .switchTo(p)
                }
            }
            ProfileActionButton(label: "Rename") { model.route = .rename(p) }
            if g.isRoleAdmin {
                // Dispatcharr admins are always Admin: no Role picker.
                if !ProfileRole.isServerAdmin(p.userLevel) {
                    ProfileActionButton(label: "Role: \(p.effectiveRole.label)") { model.route = .role(p) }
                }
                // Apple TV reorders by hold on the row; iPhone and iPad keep these.
                if !ProfileUI.isTv && at > 0 {
                    ProfileActionButton(label: "Move Up") { move(p, .earlier) }
                }
                if !ProfileUI.isTv && at >= 0 && at < list.count - 1 {
                    ProfileActionButton(label: "Move Down") { move(p, .later) }
                }
            }
            if g.canEditAvatar(p.id) {
                ProfileActionButton(label: "Set Avatar") { model.route = .avatar(p) }
            }
            if canPin {
                ProfileActionButton(label: hasPin ? "Change PIN" : "Set PIN") { model.route = .setPin(p) }
                if hasPin { ProfileActionButton(label: "Remove PIN") { model.route = .removePin(p) } }
                // An Admin resets another profile's forgotten PIN.
                if hasPin && g.isRoleAdmin && !isActive {
                    ProfileActionButton(label: "Reset PIN") { model.route = .resetPin(p) }
                }
            }
            if manager.canAssignChannelProfiles(playlistId) {
                ProfileActionButton(label: "Channel Profiles") { model.route = .channelProfiles(p) }
            }
            #if os(iOS)
            if (isActive || g.isRoleAdmin) && UserQrPayload.code(playlistId: playlistId, profileId: p.id) != nil {
                ProfileActionButton(label: "Show User QR Code") { model.route = .userQr(p) }
            }
            #endif
            if g.isAdmin && !p.isDefault {
                ProfileActionButton(label: "Remove", destructive: true, newGroup: true) { model.route = .remove(p) }
            }
        }
    }

    private func move(_ p: DispatcharrProfile, _ how: ProfileOrder.Move) {
        do { _ = try manager.move(playlistId, p.id, how); model.close() }
        catch { model.close(error.localizedDescription, title: how == .earlier ? ProfileActionTitle.moveUp : ProfileActionTitle.moveDown) }
    }
}

/// One profile row's content (Android ProfileRow).
struct ProfileRowContent: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let profile: DispatcharrProfile
    let isActive: Bool
    let locked: Bool
    var trailingLabel: String? = nil

    var body: some View {
        HStack(spacing: ProfileUI.s(12, 20)) {
            ProfileAvatarView(profile, size: ProfileUI.s(32, 56))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).scaledFont(ProfileUI.body).foregroundColor(.textPrimary).lineLimit(1)
                Text([profile.effectiveRole.label, locked ? "PIN" : nil].compactMap { $0 }.joined(separator: "  "))
                    .scaledFont(ProfileUI.small).foregroundColor(.accentPrimary).lineLimit(1)
                Text(([profile.username, ProfileCopy.levelCaption(profile.userLevel)]
                      + (profile.streamLimit > 0 ? ["Streams: \(profile.streamLimit)"] : [])).joined(separator: "  "))
                    .scaledFont(ProfileUI.small).foregroundColor(.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let trailingLabel {
                // Gap so the label never touches the profile name.
                Text(trailingLabel).scaledFont(ProfileUI.label).foregroundColor(.accentPrimary).padding(.leading, ProfileUI.s(16, 24))
            }
            if locked {
                Image(systemName: "lock.fill").font(.system(size: ProfileUI.s(13, 22))).foregroundColor(.textSecondary)
                    .accessibilityLabel("PIN")
            }
            if isActive {
                Image(systemName: "checkmark").font(.system(size: ProfileUI.s(16, 26), weight: .bold)).foregroundColor(.accentPrimary)
                    .accessibilityLabel("Active")
            }
        }
    }
}

#if os(iOS)
/// iPhone and iPad: the PROFILES section inside the playlist page List.
struct ProfilesSettingsSection: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    @ObservedObject var model: ProfilesFlowModel
    @ObservedObject private var manager = ProfileManager.shared

    var body: some View {
        let g = ProfileGates(playlistId: playlistId)
        let profiles = manager.profilesByPlaylist[playlistId] ?? []
        let _ = manager.pinChanges
        // A Child has no Profiles section; nothing new for a single-profile non-admin.
        if RoleRules.canSeeSwitcher(manager.activeRoleNow), profiles.count >= 2 || g.isAdmin {
            Section {
                ForEach(profiles) { p in
                    Button { openActions(p) } label: {
                        HStack(spacing: 4) {
                            ProfileRowContent(profile: p, isActive: p.id == g.activeId, locked: manager.hasPin(p.id))
                            Image(systemName: "pencil").foregroundColor(.textSecondary).padding(6)
                                .accessibilityLabel("Profile options")
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(manager.switching)
                    .listRowBackground(Color.cardBackground)
                }
                if g.isAdmin {
                    Button { model.open(.add) } label: {
                        Label { Text("Add Profile").fontWeight(.medium) } icon: { Image(systemName: "plus") }
                            .foregroundColor(.accentPrimary)
                    }
                    .listRowBackground(Color.cardBackground)
                    deviceAdminRows
                }
                if manager.switching {
                    ProgressView().tint(.accentPrimary).listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Profiles").sectionHeaderStyle()
            } footer: {
                Text(ProfileCopy.sectionFooter)
            }
        }
    }

    @ViewBuilder
    private var deviceAdminRows: some View {
        let has = manager.hasDeviceAdminPin(playlistId)
        Button { model.open(.deviceSet) } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill").foregroundColor(.accentPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(has ? "Change Device Admin PIN" : "Set Device Admin PIN").foregroundColor(.textPrimary)
                    Text(PinCopy.deviceAdminRow)
                        .scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
                }
            }
        }
        .listRowBackground(Color.cardBackground)
        if has {
            Button { model.open(.deviceRemove) } label: {
                Label("Remove Device Admin PIN", systemImage: "lock.fill").foregroundColor(ProfileUI.errorColor)
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    private func openActions(_ p: DispatcharrProfile) {
        guard !manager.switching else { return }
        debugLog("[PROFILES] actions opened")
        model.open(.actions(p))
    }
}
#endif

#if os(tvOS)
/// Apple TV: the PROFILES section with hold-to-reorder (Android pick-up,
/// Apple f67bfbd pattern). A Select hold lifts the focused row (scale 1.03,
/// accent stroke, "Moving", the others dimmed); Up and Down move it, Select
/// places it with one setOrder save, Menu cancels.
struct ProfilesTVSection: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    @ObservedObject var model: ProfilesFlowModel
    @ObservedObject private var manager = ProfileManager.shared
    @FocusState private var focusedRow: String?
    @State private var liftedId: String?
    @State private var liftOrder: [DispatcharrProfile] = []
    @State private var orderBeforeLift: [DispatcharrProfile]?
    /// The hold lifts while Select is still held; its release must not place the row.
    @State private var swallowNextSelect = false

    var body: some View {
        let g = ProfileGates(playlistId: playlistId)
        let profiles = manager.profilesByPlaylist[playlistId] ?? []
        let _ = manager.pinChanges
        let canReorder = profiles.count > 1 && g.isRoleAdmin
        let shown = liftedId != nil ? liftOrder : profiles
        if RoleRules.canSeeSwitcher(manager.activeRoleNow), profiles.count >= 2 || g.isAdmin {
            SettingsSection("Profiles", style: .plain) {
                if canReorder {
                    Text(liftedId != nil ? "Up / Down to move, OK to place, Menu to cancel" : "Long press to select and reorder")
                        .scaledFont(ProfileUI.small)
                        .foregroundColor(.textSecondary)
                        .padding(.horizontal, 20)
                }
                ScrollViewReader { proxy in
                    VStack(spacing: 12) {
                        ForEach(shown) { p in
                            let lifted = liftedId == p.id
                            let dimmed = liftedId != nil && !lifted
                            Button { rowPressed(p) } label: {
                                ProfileRowContent(profile: p, isActive: p.id == g.activeId, locked: manager.hasPin(p.id),
                                                  trailingLabel: lifted ? "Moving" : nil)
                                    .frame(minHeight: 80)
                            }
                            .buttonStyle(ProfileRowButtonStyle(lifted: lifted))
                            .focused($focusedRow, equals: p.id)
                            // Only the lifted row stays focusable while lifted; it is never disabled.
                            .disabled(dimmed)
                            .opacity(dimmed ? 0.45 : 1)
                            .id(p.id)
                        }
                    }
                    .onChange(of: liftOrder.map(\.id)) { _, _ in
                        if let id = liftedId { withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
                .onMoveCommand { d in
                    guard liftedId != nil else { return }
                    switch d {
                    case .up: moveLifted(-1)
                    case .down: moveLifted(1)
                    default: break
                    }
                }
                .onExitCommand(perform: liftedId != nil ? { cancelLifted() } : nil)
                .background(
                    SwitchStreamSelectHoldDetector(
                        minimumPressDuration: 0.5,
                        isEnabled: canReorder && liftedId == nil && !model.presented,
                        onBegan: { lift(profiles) },
                        onEnded: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { swallowNextSelect = false } }
                    )
                    .allowsHitTesting(false)
                )
                if g.isAdmin {
                    TVSettingsTileActionRow(icon: "plus", title: "Add Profile", titleColor: .accentPrimary) {
                        model.open(.add)
                    }
                    .disabled(liftedId != nil)
                    let has = manager.hasDeviceAdminPin(playlistId)
                    TVSettingsTileActionRow(icon: "lock.fill", title: has ? "Change Device Admin PIN" : "Set Device Admin PIN",
                                            subtitle: PinCopy.deviceAdminRow) {
                        model.open(.deviceSet)
                    }
                    .disabled(liftedId != nil)
                    if has {
                        TVSettingsTileActionRow(icon: "lock.fill", iconColor: ProfileUI.errorColor, title: "Remove Device Admin PIN",
                                                titleColor: ProfileUI.errorColor) {
                            model.open(.deviceRemove)
                        }
                        .disabled(liftedId != nil)
                    }
                }
                if manager.switching { ProgressView().tint(.accentPrimary).padding(.horizontal, 20) }
                Text(ProfileCopy.sectionFooter)
                    .scaledFont(ProfileUI.small)
                    .foregroundColor(.textSecondary)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func rowPressed(_ p: DispatcharrProfile) {
        if swallowNextSelect { swallowNextSelect = false; return }
        if liftedId != nil { placeLifted(); return }
        guard !manager.switching else { return }
        debugLog("[PROFILES] actions opened")
        model.open(.actions(p))
    }

    private func lift(_ profiles: [DispatcharrProfile]) {
        guard liftedId == nil, !manager.switching, let id = focusedRow,
              let at = profiles.firstIndex(where: { $0.id == id }) else { return }
        orderBeforeLift = profiles
        liftOrder = profiles
        swallowNextSelect = true
        withAnimation(.easeInOut(duration: 0.15)) { liftedId = id }
        model.liftActive = true
        debugLog("[PROFILES] pick-up start from=\(at)")
    }

    private func moveLifted(_ delta: Int) {
        guard let id = liftedId, let i = liftOrder.firstIndex(where: { $0.id == id }) else { return }
        let target = i + delta
        guard target >= 0, target < liftOrder.count else { return }
        withAnimation(.easeInOut(duration: 0.12)) { liftOrder.swapAt(i, target) }
        focusedRow = id
    }

    private func placeLifted() {
        guard let id = liftedId, let before = orderBeforeLift else { return }
        let from = before.firstIndex { $0.id == id } ?? -1
        let to = liftOrder.firstIndex { $0.id == id } ?? -1
        let order = liftOrder.map(\.id)
        withAnimation(.easeInOut(duration: 0.15)) { liftedId = nil }
        orderBeforeLift = nil
        model.liftActive = false
        debugLog("[PROFILES] pick-up drop id=\(from) from=\(from) to=\(to) save=\(from != to)")
        // Placed where it started: nothing is saved and no sheet opens.
        if from != to {
            do { _ = try manager.setOrder(playlistId, order) }
            catch { if let r = ProfileRefusal.make(title: ProfileActionTitle.profiles, reason: error.localizedDescription) { model.refuse(r) } }
        }
        focusedRow = id
    }

    private func cancelLifted() {
        guard let id = liftedId else { return }
        let from = orderBeforeLift?.firstIndex { $0.id == id } ?? -1
        if let before = orderBeforeLift { liftOrder = before }
        withAnimation(.easeInOut(duration: 0.15)) { liftedId = nil }
        orderBeforeLift = nil
        model.liftActive = false
        debugLog("[PROFILES] pick-up cancel from=\(from)")
        focusedRow = id
    }
}
#endif

extension View {
    /// Presents the profiles flow for [playlistId] (one presentation for every step).
    func profilesFlowPresentation(_ playlistId: String?, model: ProfilesFlowModel) -> some View {
        // A card centered on screen over a dim, sized to its content (owner
        // 2026-11-12), not a full-height sheet. Apple TV too: a tvOS sheet drew
        // its own dark panel around the card (device report 2026-11-12). Menu
        // stays the dialog's own Cancel (each step handles it), as on device.
        fullScreenCover(isPresented: Binding(get: { model.presented }, set: { if !$0 { model.close() } })) {
            if let playlistId { ProfileFlowHost(playlistId: playlistId, model: model) }
        }
    }
}

/// Admin only: assign the user's Dispatcharr Channel Profiles (Android ChannelProfilesDialog).
struct ChannelProfilesFlow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let profile: DispatcharrProfile
    let onClose: (String?) -> Void
    @State private var data: ProfileManager.ChannelProfileAssignment?
    @State private var picked: Set<Int> = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ProfileDialog(title: "Channel Profiles", confirm: data == nil ? nil : ("Save", !busy, false, {
            guard let d = data, !busy else { return }
            busy = true; error = nil
            Task {
                do { try await ProfileManager.shared.saveChannelProfiles(playlistId, profile.id, userId: d.userId, ids: Array(picked)); onClose(nil) }
                catch { busy = false; self.error = error.localizedDescription.isEmpty ? "Could not save" : error.localizedDescription }
            }
        }), onCancel: { onClose(nil) }) {
            if let d = data {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ProfileChoiceRow(label: "All", checked: picked.isEmpty) { picked.removeAll() }
                        ForEach(d.choices, id: \.id) { c in
                            ProfileChoiceRow(label: c.name, checked: picked.contains(c.id)) {
                                if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                            }
                        }
                    }
                }
                .frame(maxHeight: ProfileUI.s(360, 560))
            } else if error == nil {
                ProgressView().tint(.accentPrimary)
            }
            if busy { ProgressView().tint(.accentPrimary) }
            if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
        }
        .task {
            do { let d = try await ProfileManager.shared.channelProfileAssignment(playlistId, profile.id); data = d; picked = d.assigned }
            catch { self.error = error.localizedDescription.isEmpty ? "Could not load channel profiles" : error.localizedDescription }
        }
    }
}

// MARK: - Manage Profiles for a Child (follow-up 12, Android ManageProfilesRow / ManageProfilesPage)

/// The bottom of a Child's Settings: its only way out, behind an Admin PIN.
struct ChildManageProfilesRow: View {
    var body: some View {
        SettingsRow(icon: "person.2.badge.gearshape", iconColor: .accentPrimary,
                    title: "Manage Profiles", subtitle: PinCopy.manageProfilesRow)
    }
}

/// Manage Profiles for a Child: an Admin or Standard PIN first, then the
/// profile list (pick one to switch; a profile with its own PIN asks for it,
/// except the one whose PIN opened the page), Add Profile, and the Device Admin
/// PIN. Nothing about other profiles shows before the PIN.
struct ChildManageProfilesView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    @ObservedObject private var manager = ProfileManager.shared
    @State private var unlocked = false
    @State private var flow: Flow?

    private enum Flow { case adminPin, switchTo(DispatcharrProfile), add, deviceSet, deviceRemove, refused(ProfileRefusal) }

    /// "Enter PIN": the same PIN pad as before (Admin, Standard, or Device Admin PIN).
    private func openGate() {
        if manager.adminHasPin(playlistId) {
            flow = .adminPin
        } else {
            // No Admin PIN exists (an inconsistent state, e.g. after a sync): never strand the Child.
            debugLog("[PROFILE] manage profiles: no Admin PIN exists; opening")
            unlocked = true
        }
    }

    /// A flow ended: a refusal reason shows as its dialog (ProfileRefusal), never as page text.
    private func finish(_ err: String?, title: String) {
        flow = ProfileRefusal.make(title: title, reason: err).map { .refused($0) }
    }

    var body: some View {
        let profiles = manager.profilesByPlaylist[playlistId] ?? []
        let activeId = manager.activeProfileIdNow(playlistId)
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if !unlocked {
                // The gate (owner 2026-11-12): a centered lock, the explanation, and one
                // prominent "Enter PIN" button (Admin, Standard, and Device Admin PINs all work).
                VStack(spacing: ProfileUI.s(16, 32)) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: ProfileUI.s(44, 80), weight: .semibold))
                        .foregroundColor(.accentPrimary)
                        .accessibilityHidden(true)
                    Text(PinCopy.manageGate)
                        .scaledFont(ProfileUI.body)
                        .foregroundColor(.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { openGate() } label: {
                        Text("Enter PIN")
                            .scaledFont(ProfileUI.bodyStrong)
                            .frame(minWidth: ProfileUI.s(200, 400))
                            .padding(.vertical, ProfileUI.s(4, 8))
                    }
                    .buttonStyle(ProfilePillStyle())
                }
                .frame(maxWidth: ProfileUI.s(420, 900))
                .padding(.horizontal, ProfileUI.s(24, 60))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: ProfileUI.s(8, 14)) {
                    Group {
                        ForEach(profiles) { p in
                            Button {
                                // The active Child only when it needs its sign-in form (held, or no key).
                                guard p.id != activeId || manager.needsSignIn(p.id), !manager.switching else { return }
                                    flow = .switchTo(p)
                            } label: {
                                ProfileRowContent(profile: p, isActive: p.id == activeId, locked: manager.hasPin(p.id))
                            }
                            .buttonStyle(ProfileRowButtonStyle())
                        }
                        if manager.switching { ProgressView().tint(.accentPrimary) }
                        // Behind the Admin PIN a parent can add their own profile (a kid-only device).
                        Button {
                            manager.pickerAddUnlocked = playlistId
                            flow = .add
                        } label: {
                            Label("Add Profile", systemImage: "plus").foregroundColor(.accentPrimary)
                        }
                        .buttonStyle(ProfileRowButtonStyle())
                        // The full Device Admin PIN row, as on the playlist's Profiles page and on
                        // Android: Change with its line, and Remove (refused while it is the only
                        // way out of a Child, PinCopy.deviceAdminOnlyWayOut).
                        if manager.hasDeviceAdminPin(playlistId) {
                            Button { flow = .deviceSet } label: {
                                HStack(spacing: ProfileUI.s(12, 18)) {
                                    Image(systemName: "lock.fill").foregroundColor(.accentPrimary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Change Device Admin PIN").foregroundColor(.textPrimary)
                                        Text(PinCopy.deviceAdminRow)
                                            .scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .buttonStyle(ProfileRowButtonStyle())
                            Button { flow = .deviceRemove } label: {
                                Label("Remove Device Admin PIN", systemImage: "lock.fill").foregroundColor(ProfileUI.errorColor)
                            }
                            .buttonStyle(ProfileRowButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, ProfileUI.s(16, 60))
                .padding(.vertical, ProfileUI.s(12, 40))
            }
            }
            if let flow {
                ProfileDialogHost {
                    switch flow {
                    case .adminPin:
                        AdminPinFlow(playlistId: playlistId, onDismiss: { self.flow = nil }) {
                            self.flow = nil
                            unlocked = true
                        }
                    case .switchTo(let p):
                        ProfileSwitchFlow(playlistId: playlistId, profile: p) { err in
                            finish(err, title: ProfileActionTitle.switchProfile)
                        }
                    case .add:
                        AddProfileFlow(playlistId: playlistId) {
                            self.flow = nil
                            manager.pickerAddUnlocked = nil
                        }
                    case .deviceSet:
                        let title = ProfileActionTitle.deviceAdminPin(has: manager.hasDeviceAdminPin(playlistId))
                        DeviceAdminPinSetFlow(playlistId: playlistId) { err in
                            finish(err, title: title)
                        }
                    case .deviceRemove:
                        DeviceAdminPinRemoveFlow(playlistId: playlistId) { err in
                            finish(err, title: ProfileActionTitle.removeDeviceAdminPin)
                        }
                    case .refused(let r):
                        ProfileRefusalDialog(refusal: r) { self.flow = nil }
                    }
                }
            }
        }
        .navigationTitle("Manage Profiles")
        // The same title treatment as the other Settings pages (About, Live TV).
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        // Locked again whenever the active profile is (again) a Child.
        .onChange(of: manager.activeRoleNow) { _, role in if role == .child { unlocked = false } }
        .onAppear { manager.notePickerOpened(playlistId, "switch") }
    }
}
