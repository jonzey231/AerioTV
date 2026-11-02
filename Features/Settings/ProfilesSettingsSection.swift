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
    case switchTo(DispatcharrProfile)
    case add
    case deviceSet
    case deviceRemove
}

@MainActor
final class ProfilesFlowModel: ObservableObject {
    @Published var route: ProfileRoute?
    @Published var presented = false
    @Published var status: String?

    func open(_ r: ProfileRoute) {
        route = r
        presented = true
    }

    func close(_ error: String? = nil) {
        status = error
        presented = false
        route = nil
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
                    do { try manager.setAvatar(playlistId, p.id, spec); model.close() } catch { model.close(error.localizedDescription) }
                }
            case .remove(let p):
                ProfileDialog(title: "Remove Profile", confirm: ("Remove", true, true, {
                    if manager.roleOf(p.id) == .child { model.route = .removeAdminPin(p) } else { remove(p) }
                }), onCancel: { model.close() }) {
                    Text("Remove \(p.displayName)? Favorites, recordings, and watch history for this profile on this device will be deleted.")
                        .scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
                }
            case .removeAdminPin(let p):
                AdminPinFlow(playlistId: playlistId, title: "Enter a PIN from an Admin or Standard profile to remove \(p.displayName)",
                             onDismiss: { model.close() }) { remove(p) }
            case .setPin(let p): SetPinFlow(playlistId: playlistId, profile: p) { model.close($0) }
            case .removePin(let p): RemovePinFlow(playlistId: playlistId, profile: p) { model.close($0) }
            case .resetPin(let p): ResetPinFlow(playlistId: playlistId, profile: p) { model.close($0) }
            case .role(let p): RoleFlow(playlistId: playlistId, profile: p) { model.close($0) }
            case .switchTo(let p): ProfileSwitchFlow(playlistId: playlistId, profile: p) { model.close($0) }
            case .add: AddProfileFlow(playlistId: playlistId) { model.close() }
            case .deviceSet: DeviceAdminPinSetFlow(playlistId: playlistId) { model.close($0) }
            case .deviceRemove: DeviceAdminPinRemoveFlow(playlistId: playlistId) { model.close($0) }
            case nil: EmptyView()
            }
        }
    }

    private func remove(_ p: DispatcharrProfile) {
        Task {
            do { try await manager.remove(p.id); model.close() } catch { model.close(error.localizedDescription) }
        }
    }
}

/// The row actions sheet: "Switch to this profile" first (hidden on the active one).
struct ProfileActionsSheet: View {
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
        ProfileDialog(title: p.displayName, onCancel: { model.close() }) {
            Text([isActive ? "Active" : nil, p.effectiveRole.label, hasPin ? "PIN" : nil].compactMap { $0 }.joined(separator: "  "))
                .scaledFont(ProfileUI.small).foregroundColor(.accentPrimary)
            Text(p.username).scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
            if !isActive {
                ProfileChoiceRow(label: "Switch to this profile") {
                    debugLog("[PROFILES] switch from actions")
                    model.route = .switchTo(p)
                }
            }
            ProfileChoiceRow(label: "Rename") { model.route = .rename(p) }
            if g.isRoleAdmin {
                // Dispatcharr admins are always Admin: no Role picker.
                if !ProfileRole.isServerAdmin(p.userLevel) {
                    ProfileChoiceRow(label: "Role: \(p.effectiveRole.label)") { model.route = .role(p) }
                }
                // Apple TV reorders by hold on the row; iPhone and iPad keep these.
                if !ProfileUI.isTv && at > 0 {
                    ProfileChoiceRow(label: "Move Up") { move(p, .earlier) }
                }
                if !ProfileUI.isTv && at >= 0 && at < list.count - 1 {
                    ProfileChoiceRow(label: "Move Down") { move(p, .later) }
                }
            }
            if g.canEditAvatar(p.id) {
                ProfileChoiceRow(label: "Avatar") { model.route = .avatar(p) }
            }
            if canPin {
                ProfileChoiceRow(label: hasPin ? "Change PIN" : "Set PIN") { model.route = .setPin(p) }
                if hasPin { ProfileChoiceRow(label: "Remove PIN") { model.route = .removePin(p) } }
                // An Admin resets another profile's forgotten PIN.
                if hasPin && g.isRoleAdmin && !isActive {
                    ProfileChoiceRow(label: "Reset PIN") { model.route = .resetPin(p) }
                }
            }
            if g.isAdmin && !p.isDefault {
                ProfileChoiceRow(label: "Remove", destructive: true) { model.route = .remove(p) }
            }
        }
    }

    private func move(_ p: DispatcharrProfile, _ how: ProfileOrder.Move) {
        do { _ = try manager.move(playlistId, p.id, how); model.close() } catch { model.close(error.localizedDescription) }
    }
}

/// One profile row's content (Android ProfileRow).
struct ProfileRowContent: View {
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
                    Button { model.status = nil; model.open(.add) } label: {
                        Label { Text("Add Profile").fontWeight(.medium) } icon: { Image(systemName: "plus") }
                            .foregroundColor(.accentPrimary)
                    }
                    .listRowBackground(Color.cardBackground)
                    deviceAdminRows
                }
                if manager.switching {
                    ProgressView().tint(.accentPrimary).listRowBackground(Color.cardBackground)
                }
                if let s = model.status {
                    Text(s).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor).listRowBackground(Color.cardBackground)
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
        Button { model.status = nil; model.open(.deviceSet) } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill").foregroundColor(.accentPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(has ? "Change Device Admin PIN" : "Set Device Admin PIN").foregroundColor(.textPrimary)
                    Text("Works on this device only, alongside Admin profile PINs. Never synced.")
                        .scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
                }
            }
        }
        .listRowBackground(Color.cardBackground)
        if has {
            Button { model.status = nil; model.open(.deviceRemove) } label: {
                Label("Remove Device Admin PIN", systemImage: "lock.fill").foregroundColor(ProfileUI.errorColor)
            }
            .listRowBackground(Color.cardBackground)
        }
    }

    private func openActions(_ p: DispatcharrProfile) {
        guard !manager.switching else { return }
        debugLog("[PROFILES] actions opened")
        model.status = nil
        model.open(.actions(p))
    }
}
#endif

extension View {
    /// Presents the profiles flow for [playlistId] (one presentation for every step).
    func profilesFlowPresentation(_ playlistId: String?, model: ProfilesFlowModel) -> some View {
        sheet(isPresented: Binding(get: { model.presented }, set: { if !$0 { model.close(model.status) } })) {
            if let playlistId { ProfileFlowHost(playlistId: playlistId, model: model) }
        }
    }
}
