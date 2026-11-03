//  ProfileFlows.swift
//  Aerio
//
//  Profiles part 3: every multi-step profile prompt, ported from Android
//  ProfilesUi.kt, ProfilePinUi.kt, ProfileSuggestionsUi.kt, and
//  ProfileAvatarUi.kt with the same copy and the same step order. Each flow
//  is one view whose steps swap in place, hosted by one presentation, and
//  reports back with onClose(error message or nil).

import SwiftUI

@MainActor private var pm: ProfileManager { ProfileManager.shared }

// MARK: - PIN flows

/// "Enter a PIN from an Admin or Standard profile": any full-access profile's PIN passes.
struct AdminPinFlow: View {
    let playlistId: String
    var title = ProfileCopy.adminPinTitle
    let onDismiss: () -> Void
    let onOk: () -> Void

    var body: some View {
        let ids = pm.adminPinIds(playlistId)
        let lengths = Set(ids.compactMap { pm.pinLength($0) })
        ProfilePinEntry(
            title: title,
            type: ids.first.flatMap { pm.pinType($0) } ?? .numbers,
            // Known only when every Admin PIN holder's length is known and equal.
            pinLength: lengths.count == 1 && ids.allSatisfy({ pm.pinLength($0) != nil }) ? lengths.first : nil,
            lockSeconds: { ids.map { pm.pinLockSeconds($0) }.min() ?? 0 },
            onDismiss: onDismiss,
            onEntered: { seq in
                let r = pm.verifyAnyAdminPin(playlistId, seq)
                if r == .ok { onOk(); return nil }
                return ProfileCopy.pinCheckMessage(r)
            }
        )
    }
}

/// "Enter PIN for {name}" before switching to a locked profile.
struct SwitchPinFlow: View {
    let profile: DispatcharrProfile
    let onDismiss: () -> Void
    let onOk: () -> Void
    var body: some View {
        ProfilePinEntry(
            title: "Enter PIN for \(profile.displayName)",
            type: pm.pinType(profile.id) ?? .numbers,
            pinLength: pm.pinLength(profile.id),
            lockSeconds: { pm.pinLockSeconds(profile.id) },
            onDismiss: onDismiss,
            onEntered: { seq in
                let r = pm.verifyPin(profile.id, seq)
                if r == .ok { onOk(); return nil }
                return ProfileCopy.pinCheckMessage(r)
            }
        )
    }
}

/// The PIN type step (radio rows).
private struct PinTypeStep: View {
    let onPick: (PinType) -> Void
    let onCancel: () -> Void
    var body: some View {
        ProfileDialog(title: "PIN type", onCancel: onCancel) {
            ForEach(PinType.allCases, id: \.self) { t in
                ProfileChoiceRow(label: t.label, checked: false) { onPick(t) }
            }
        }
    }
}

/// Set PIN / Change PIN: (current PIN when needed), PIN type, Enter PIN,
/// Confirm PIN. "PINs do not match" restarts the entry. [onChosen] (Reset
/// with a temporary PIN) hands the new PIN back instead of saving it.
struct SetPinFlow: View {
    let playlistId: String
    let profile: DispatcharrProfile
    var onChosen: ((PinType, [String]) -> Void)? = nil
    let onClose: (String?) -> Void

    @State private var current: [String]?
    @State private var type: PinType?
    @State private var first: [String]?
    @State private var mismatch: String?
    @State private var needsCurrent: Bool?

    var body: some View {
        let title = pm.hasPin(profile.id) && onChosen == nil ? "Change PIN" : "Set PIN"
        Group {
            if needsCurrent == true && current == nil {
                ProfilePinEntry(
                    title: "Enter PIN", type: pm.pinType(profile.id) ?? .numbers, pinLength: pm.pinLength(profile.id),
                    lockSeconds: { pm.pinLockSeconds(profile.id) }, onDismiss: { onClose(nil) },
                    onEntered: { seq in
                        let r = pm.verifyPin(profile.id, seq)
                        if r == .ok { current = seq; return nil }
                        return ProfileCopy.pinCheckMessage(r)
                    }
                ).id("current")
            } else if type == nil {
                PinTypeStep(onPick: { type = $0 }, onCancel: { onClose(nil) })
            } else if first == nil {
                ProfilePinEntry(
                    title: "\(title): Enter PIN", type: type!, setting: true, initialError: mismatch,
                    onDismiss: { onClose(nil) },
                    onEntered: { seq in first = seq; mismatch = nil; return nil }
                ).id("first-\(mismatch ?? "")")
            } else {
                ProfilePinEntry(
                    title: "Confirm PIN", type: type!, pinLength: first!.count, onDismiss: { onClose(nil) },
                    onEntered: { seq in
                        if seq != first { mismatch = "PINs do not match"; first = nil; return nil }
                        let t = type!
                        if let onChosen { onChosen(t, seq); return nil }
                        do { try pm.setPin(playlistId, profile.id, t, seq, current: current); onClose(nil) }
                        catch { onClose(error.localizedDescription) }
                        return nil
                    }
                ).id("confirm")
            }
        }
        .onAppear { if needsCurrent == nil { needsCurrent = onChosen == nil && pm.needsCurrentPin(playlistId, profile.id) } }
    }
}

/// Remove PIN: the current PIN first when the actor needs it.
struct RemovePinFlow: View {
    let playlistId: String
    let profile: DispatcharrProfile
    let onClose: (String?) -> Void
    @State private var needsCurrent: Bool?

    var body: some View {
        if let reason = pm.pinRemovalBlock(playlistId, profile.id) {
            ProfileDialog(title: "Remove PIN", cancelLabel: nil, confirm: ("OK", true, false, { onClose(nil) }), onCancel: { onClose(nil) }) {
                Text(reason).scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
            }
        } else if needsCurrent == true {
            ProfilePinEntry(
                title: "Remove PIN", type: pm.pinType(profile.id) ?? .numbers, pinLength: pm.pinLength(profile.id),
                lockSeconds: { pm.pinLockSeconds(profile.id) }, onDismiss: { onClose(nil) },
                onEntered: { seq in
                    let r = pm.verifyPin(profile.id, seq)
                    guard r == .ok else { return ProfileCopy.pinCheckMessage(r) }
                    do { try pm.removePin(playlistId, profile.id, current: seq); onClose(nil) } catch { onClose(error.localizedDescription) }
                    return nil
                }
            )
        } else {
            Color.clear.onAppear {
                if pm.needsCurrentPin(playlistId, profile.id) { needsCurrent = true; return }
                do { try pm.removePin(playlistId, profile.id, current: nil); onClose(nil) } catch { onClose(error.localizedDescription) }
            }
        }
    }
}

/// "Reset PIN" for another profile: the actor's own PIN, or a confirm when it has none.
struct ResetPinFlow: View {
    let playlistId: String
    let profile: DispatcharrProfile
    let onClose: (String?) -> Void
    @State private var ownEntries: [String]?

    private func reset(_ admin: [String]?, _ replacement: (PinType, [String])? = nil) {
        do { try pm.resetPin(playlistId, profile.id, adminEntries: admin, replacement: replacement); onClose(nil) }
        catch { onClose(error.localizedDescription) }
    }

    var body: some View {
        let mustKeep = pm.pinRemovalBlock(playlistId, profile.id) != nil
        if let own = ownEntries {
            SetPinFlow(playlistId: playlistId, profile: profile, onChosen: { t, seq in reset(own, (t, seq)) }, onClose: onClose)
        } else {
            switch pm.resetGate(playlistId) {
            case .denied(let reason):
                Color.clear.onAppear { onClose(reason) }
            case .confirmOnly:
                ProfileDialog(title: "Reset PIN", confirm: ("Reset", true, true, { reset(nil) }), onCancel: { onClose(nil) }) {
                    Text("Remove the PIN for \(profile.displayName)? \(profile.displayName) can set a new one.")
                        .scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
                }
            case .enterOwnPin:
                if let admin = pm.activeProfile(playlistId) {
                    ProfilePinEntry(
                        title: "Enter your PIN to reset the PIN for \(profile.displayName)",
                        type: pm.pinType(admin.id) ?? .numbers, pinLength: pm.pinLength(admin.id),
                        lockSeconds: { pm.pinLockSeconds(admin.id) }, onDismiss: { onClose(nil) },
                        onEntered: { seq in
                            let r = pm.verifyPin(admin.id, seq)
                            guard r == .ok else { return ProfileCopy.pinCheckMessage(r) }
                            if mustKeep { ownEntries = seq } else { reset(seq) }
                            return nil
                        }
                    )
                }
            }
        }
    }
}

/// While a Child exists every Admin and Standard profile holds a PIN: walks
/// the actor through each missing one. onDone(true) once none is missing.
struct ChildNeedsAdminPin: View {
    let playlistId: String
    var becomingChild: String? = nil
    let onDone: (Bool) -> Void
    @State private var round = 0
    @State private var explained: String?

    var body: some View {
        let missing = pm.pinsMissingForChild(playlistId, becomingChild: becomingChild)
        let actor = pm.activeProfile(playlistId)
        if let next = missing.first {
            let own = next.id == actor?.id
            if !own && !RoleRules.isFullAccess(pm.activeRole(playlistId)) && !pm.isPendingPinAdd(next.id) {
                ProfileDialog(title: "PIN Required", cancelLabel: nil, confirm: ("OK", true, false, { onDone(false) }), onCancel: { onDone(false) }) {
                    Text("\(RoleRules.KEEP_PIN_REASON) Set a PIN for \(next.displayName) first.").scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
                }
            } else if explained != next.id {
                ProfileDialog(title: "PIN Required", confirm: ("Set PIN", true, false, { explained = next.id }), onCancel: { onDone(false) }) {
                    Text(own ? "\(RoleRules.KEEP_PIN_REASON) Set a PIN for \(next.displayName) first."
                         : "\(RoleRules.KEEP_PIN_REASON) Set a temporary PIN for \(next.displayName). It can be changed later, or reset from the profile's menu.")
                        .scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
                }
            } else {
                SetPinFlow(playlistId: playlistId, profile: next) { _ in
                    if !pm.hasPin(next.id) { onDone(false) } else { round += 1 }
                }
                .id("pin-\(next.id)-\(round)")
            }
        } else if pm.adminHasPin(playlistId) {
            Color.clear.onAppear { onDone(true) }
        } else {
            ProfileDialog(title: "PIN Required", cancelLabel: nil, confirm: ("OK", true, false, { onDone(false) }), onCancel: { onDone(false) }) {
                Text("A Child profile needs a PIN from an Admin or Standard profile to leave it. Set a PIN on an Admin or Standard profile first.")
                    .scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
            }
        }
    }
}

/// An Admin or Standard profile added while a Child exists sets its PIN right after; cancelling undoes the add.
struct PinAfterAdd: View {
    let playlistId: String
    let onDone: (Bool) -> Void
    var body: some View {
        ChildNeedsAdminPin(playlistId: playlistId) { ok in
            if ok { onDone(true) } else { Task { await pm.discardPendingAdds(playlistId); onDone(false) } }
        }
    }
}

/// Set or change the Device Admin PIN: current device PIN, PIN type, Enter PIN, Confirm PIN.
struct DeviceAdminPinSetFlow: View {
    let playlistId: String
    var onboarding = false
    let onClose: (String?) -> Void
    @State private var had: Bool?
    @State private var current: [String]?
    @State private var type: PinType?
    @State private var first: [String]?
    @State private var mismatch: String?

    var body: some View {
        let id = pm.deviceAdminPinId(playlistId)
        let title = had == true ? "Change Device Admin PIN" : "Set Device Admin PIN"
        Group {
            if had == true && current == nil {
                ProfilePinEntry(
                    title: "Enter Device Admin PIN", type: pm.pinType(id) ?? .numbers, pinLength: pm.pinLength(id),
                    lockSeconds: { pm.pinLockSeconds(id) }, onDismiss: { onClose(nil) },
                    onEntered: { seq in
                        let r = pm.verifyPin(id, seq)
                        if r == .ok { current = seq; return nil }
                        return ProfileCopy.pinCheckMessage(r)
                    }
                ).id("current")
            } else if type == nil {
                PinTypeStep(onPick: { type = $0 }, onCancel: { onClose(nil) })
            } else if first == nil {
                ProfilePinEntry(title: "\(title): Enter PIN", type: type!, setting: true, initialError: mismatch,
                                onDismiss: { onClose(nil) }, onEntered: { seq in first = seq; mismatch = nil; return nil })
                    .id("first-\(mismatch ?? "")")
            } else {
                ProfilePinEntry(
                    title: "Confirm PIN", type: type!, pinLength: first!.count, onDismiss: { onClose(nil) },
                    onEntered: { seq in
                        if seq != first { mismatch = "PINs do not match"; first = nil; return nil }
                        do { try pm.setDeviceAdminPin(playlistId, type!, seq, current: current, onboarding: onboarding); onClose(nil) }
                        catch { onClose(error.localizedDescription) }
                        return nil
                    }
                ).id("confirm")
            }
        }
        .onAppear { if had == nil { had = pm.hasDeviceAdminPin(playlistId) } }
    }
}

/// Remove the Device Admin PIN: the current device PIN first.
struct DeviceAdminPinRemoveFlow: View {
    let playlistId: String
    let onClose: (String?) -> Void
    var body: some View {
        let id = pm.deviceAdminPinId(playlistId)
        if let reason = pm.deviceAdminPinRemovalBlock(playlistId) {
            ProfileDialog(title: "Remove Device Admin PIN", cancelLabel: nil, confirm: ("OK", true, false, { onClose(nil) }), onCancel: { onClose(nil) }) {
                Text(reason).scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
            }
        } else {
            ProfilePinEntry(
                title: "Remove Device Admin PIN", type: pm.pinType(id) ?? .numbers, pinLength: pm.pinLength(id),
                lockSeconds: { pm.pinLockSeconds(id) }, onDismiss: { onClose(nil) },
                onEntered: { seq in
                    do { try pm.removeDeviceAdminPin(playlistId, current: seq); onClose(nil); return nil }
                    catch { return error.localizedDescription.isEmpty ? "Wrong PIN" : error.localizedDescription }
                }
            )
        }
    }
}

// MARK: - Role

/// Row menu "Role": Standard and Child (Admin for a Dispatcharr admin). Setting
/// Child walks through every missing PIN; leaving Child asks for an Admin PIN.
struct RoleFlow: View {
    let playlistId: String
    let profile: DispatcharrProfile
    let onClose: (String?) -> Void
    @State private var picked: ProfileRole?
    @State private var needCreate = false
    @State private var needEntry = false

    private func apply(_ to: ProfileRole) {
        do { try pm.setRole(playlistId, profile.id, to: to); onClose(nil) } catch { onClose(error.localizedDescription) }
    }

    var body: some View {
        if let to = picked, needCreate {
            ChildNeedsAdminPin(playlistId: playlistId, becomingChild: profile.id) { ok in ok ? apply(to) : onClose(nil) }
        } else if let to = picked, needEntry {
            AdminPinFlow(playlistId: playlistId, onDismiss: { onClose(nil) }) { apply(to) }
        } else {
            let current = pm.roleOf(profile.id)
            ProfileDialog(title: "Role", centeredTitle: true, subtitle: profile.displayName, onCancel: { onClose(nil) }) {
                ForEach(ProfileRole.optionsFor(profile.userLevel), id: \.self) { r in
                    ProfileChoiceRow(label: r.label, subtitle: ProfileCopy.roleDescription(r), checked: r == current) {
                        switch pm.roleChangeGate(playlistId, profile.id, to: r) {
                        case .denied(let reason): onClose(reason)
                        case .allowed: apply(r)
                        case .needsPinsCreated: picked = r; needCreate = true
                        case .needsPinEntry: picked = r; needEntry = true
                        }
                    }
                }
                Text(ProfileCopy.roleFooter).scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Per-row role chip: opens the radio sheet (Standard and Child). A Dispatcharr admin shows a plain Admin badge.
struct ProfileRoleChip: View {
    let role: ProfileRole
    var locked = false
    var enabled = true
    let onChange: (ProfileRole) -> Void
    @State private var open = false

    var body: some View {
        if locked {
            ProfileRoleBadge(text: ProfileRole.admin.label)
        } else {
            Button { if enabled { open = true } } label: {
                HStack(spacing: 2) {
                    Text(role.label)
                    Image(systemName: "chevron.down").font(.system(size: ProfileUI.s(10, 16), weight: .bold))
                }
            }
            .buttonStyle(ProfilePillStyle(filled: false))
            .accessibilityHint("Change role")
            .sheet(isPresented: $open) {
                ProfileDialogHost {
                    ProfileDialog(title: "Role", centeredTitle: true, onCancel: { open = false }) {
                        ForEach(ProfileRole.optionsFor(serverAdmin: false), id: \.self) { r in
                            ProfileChoiceRow(label: r.label, subtitle: ProfileCopy.roleDescription(r), checked: r == role) {
                                open = false; onChange(r)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Avatar

/// Row menu "Avatar": a live preview, the 8 colors, and the icon grid.
struct AvatarPickerFlow: View {
    let profile: DispatcharrProfile
    let onClose: () -> Void
    let onSave: (AvatarSpec) -> Void
    @State private var color = ""
    @State private var icon = AvatarCatalog.INITIAL
    @State private var loaded = false

    var body: some View {
        ProfileDialog(title: "Avatar", confirm: ("Save", true, false, { onSave(AvatarSpec(icon: icon, color: color)) }), onCancel: onClose) {
            VStack(spacing: ProfileUI.s(6, 10)) {
                ProfileAvatarView(name: profile.displayName, username: profile.username, spec: AvatarSpec(icon: icon, color: color), size: ProfileUI.s(64, 110))
                Text(profile.displayName).scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
            }
            .frame(maxWidth: .infinity)
            Text("Color").scaledFont(ProfileUI.label).foregroundColor(.textSecondary)
            grid(AvatarCatalog.COLORS, perRow: ProfileUI.isTv ? 8 : 4) { id in
                Button { color = id } label: {
                    Circle().fill(ProfileAvatarStyle.color(id)).frame(width: ProfileUI.s(34, 56), height: ProfileUI.s(34, 56))
                }
                .buttonStyle(AvatarTileStyle(selected: id == color))
                .accessibilityLabel(id.prefix(1).uppercased() + id.dropFirst())
            }
            Text("Icon").scaledFont(ProfileUI.label).foregroundColor(.textSecondary)
            grid(AvatarCatalog.PICKER_ICONS, perRow: ProfileUI.isTv ? 7 : 5) { id in
                Button { icon = id } label: {
                    ProfileAvatarView(name: profile.displayName, username: profile.username, spec: AvatarSpec(icon: id, color: color), size: ProfileUI.s(34, 56))
                }
                .buttonStyle(AvatarTileStyle(selected: id == icon))
                .accessibilityLabel(ProfileAvatarStyle.iconName(id))
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            color = AvatarCatalog.colorFor(profile.avatar, profile.username)
            icon = AvatarCatalog.iconFor(profile.avatar)
        }
    }

    private func grid(_ ids: [String], perRow: Int, @ViewBuilder cell: @escaping (String) -> some View) -> some View {
        let rows = stride(from: 0, to: ids.count, by: perRow).map { Array(ids[$0..<min($0 + perRow, ids.count)]) }
        return VStack(alignment: .leading, spacing: ProfileUI.s(8, 14)) {
            ForEach(rows, id: \.self) { line in
                HStack(spacing: ProfileUI.s(8, 14)) { ForEach(line, id: \.self) { cell($0) } }
            }
        }
    }
}

private struct AvatarTileStyle: ButtonStyle {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let selected: Bool
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(ProfileUI.s(4, 6))
            .overlay(Circle().stroke(selected ? Color.white : (focused ? Color.accentPrimary : .clear), lineWidth: ProfileUI.s(2, 3)))
            .overlay(Circle().stroke(focused && selected ? Color.accentPrimary : .clear, lineWidth: 2).padding(-4))
            .scaleEffect(focused ? 1.1 : 1)
            .animation(.easeInOut(duration: 0.12), value: focused)
    }
}

// MARK: - Simple dialogs

struct RenameProfileFlow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let profile: DispatcharrProfile
    let onClose: () -> Void
    @State private var name = ""
    @State private var loaded = false
    var body: some View {
        ProfileDialog(title: "Rename", confirm: ("Save", !name.trimmingCharacters(in: .whitespaces).isEmpty, false, {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            pm.rename(profile.id, name); onClose()
        }), onCancel: onClose) {
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .scaledFont(ProfileUI.body)
                .padding(ProfileUI.s(10, 16))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.elevatedBackground))
                .submitLabel(.done)
        }
        .onAppear { if !loaded { loaded = true; name = profile.displayName } }
    }
}

/// "Stop playback and switch to {name}?"
struct StopPlaybackConfirm: View {
    let name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    var body: some View {
        ProfileDialog(title: "Switch Profile", confirm: ("Switch", true, false, onConfirm), onCancel: onCancel) {
            Text("Stop playback and switch to \(name)?").scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
        }
    }
}

/// The switch path every surface shares: PIN pad when locked, the stop-playback confirm, then switchTo.
struct ProfileSwitchFlow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let profile: DispatcharrProfile
    let onClose: (String?) -> Void
    @State private var pinPassed = false
    @State private var confirmed = false
    @State private var started = false

    private func run() {
        guard !started else { return }
        started = true
        Task {
            do { try await pm.switchTo(playlistId, profile.id); onClose(nil) }
            catch { onClose(error.localizedDescription.isEmpty ? "Switch failed" : error.localizedDescription) }
        }
    }

    var body: some View {
        if pm.hasPin(profile.id) && !pinPassed && !pm.hasSwitchTicket(profile.id) {
            SwitchPinFlow(profile: profile, onDismiss: { onClose(nil) }) { pinPassed = true }
        } else if PlayerSession.shared.mode != .idle && !confirmed {
            StopPlaybackConfirm(name: profile.displayName, onCancel: { onClose(nil) }) { confirmed = true }
        } else {
            ProgressView().tint(.accentPrimary).scaleEffect(ProfileUI.s(1.2, 2)).onAppear(perform: run)
        }
    }
}

// MARK: - Add Profile

/// Collapsed row that expands a section in place (TV: one focus stop).
struct ProfileExpandRow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let label: String
    let expanded: Bool
    let onToggle: () -> Void
    var body: some View {
        Button(action: onToggle) {
            HStack {
                Text(label).scaledFont(ProfileUI.bodyStrong).foregroundColor(.accentPrimary)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundColor(.accentPrimary)
            }
        }
        .buttonStyle(ProfileRowButtonStyle())
    }
}

/// Password or API key for a user the admin list has no key for.
struct CredentialStep: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let title: String
    let username: String
    let onCancel: () -> Void
    let onSubmit: (String?, String?) async -> String?
    @State private var password = ""
    @State private var apiKey = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let ready = !busy && (!password.isEmpty || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
        ProfileDialog(title: title, confirm: ("Add Profile", ready, false, {
            guard ready else { return }
            busy = true; error = nil
            Task {
                error = await onSubmit(password.isEmpty ? nil : password, apiKey.trimmingCharacters(in: .whitespaces).isEmpty ? nil : apiKey.trimmingCharacters(in: .whitespaces))
                busy = false
            }
        }), onCancel: onCancel) {
            Text("Sign in as \(username) once. Enter the password or an API key.").scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
            ProfileTextField(label: "Password", text: $password, secure: true)
            ProfileTextField(label: "API Key", text: $apiKey)
            if busy { ProgressView().tint(.accentPrimary) }
            if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
        }
    }
}

struct ProfileTextField: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).scaledFont(ProfileUI.label).foregroundColor(.textSecondary)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .scaledFont(ProfileUI.body)
            .padding(ProfileUI.s(10, 16))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.elevatedBackground))
        }
    }
}

/// "Enable API access" (server admin only) for a user with no key: mints a key so Add needs no password.
struct EnableApiAccessRow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let user: DispatcharrUserSummary
    let enabled: Bool
    let interactive: Bool
    let onEnabled: (String) -> Void
    let onRevoked: () -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                guard interactive, !busy else { return }
                error = nil
                if enabled { confirmRevoke = true; return }
                busy = true
                Task {
                    do { let key = try await pm.generateUserApiKey(playlistId, userId: user.id); busy = false; onEnabled(key) }
                    catch { busy = false; self.error = error.localizedDescription.isEmpty ? "Could not enable API access" : error.localizedDescription }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable API access").scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
                        Text("Lets this user sign in on AerioTV with a key instead of a password")
                            .scaledFont(ProfileUI.small).foregroundColor(.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if busy { ProgressView().tint(.accentPrimary) } else {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: ProfileUI.s(22, 32)))
                            .foregroundColor(enabled ? .accentPrimary : .textSecondary)
                    }
                }
            }
            .buttonStyle(ProfileRowButtonStyle())
            .accessibilityAddTraits(enabled ? .isSelected : [])
            if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
        }
        .sheet(isPresented: $confirmRevoke) {
            ProfileDialogHost {
                ProfileDialog(title: "Revoke API access?", confirm: ("Revoke", true, true, {
                    confirmRevoke = false
                    busy = true
                    Task {
                        do { try await pm.revokeUserApiKey(playlistId, userId: user.id); busy = false; onRevoked() }
                        catch { busy = false; self.error = error.localizedDescription.isEmpty ? "Could not revoke API access" : error.localizedDescription }
                    }
                }), onCancel: { confirmRevoke = false }) {
                    Text("\(user.username) will be signed out on every device that uses this key.").scaledFont(ProfileUI.body).foregroundColor(.textPrimary)
                }
            }
        }
    }
}

/// "From your other devices": synced roster users with no profile on this device.
struct RosterSuggestionsView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let users: [DispatcharrUserSummary]?
    var enabled = true
    let onAdded: () -> Void
    /// Section label (onboarding: "FROM YOUR OTHER DEVICES").
    var title = "From your other devices"
    /// Line under the rows (onboarding: ROSTER_FOOTNOTE).
    var footnote: String? = nil
    /// Settings: an added row stays listed as "Added" with Remove. Onboarding:
    /// it leaves the list and shows under ON THIS DEVICE with the red minus.
    var keepAdded = true
    /// The id of a profile just added here (onboarding focus hand-off).
    var onAddedProfile: (String) -> Void = { _ in }
    @ObservedObject private var manager = ProfileManager.shared
    @State private var busy: String?
    @State private var error: String?
    @State private var added: [ProfileRow] = []
    @State private var addedIds: [String: String] = [:]
    @State private var roles: [String: ProfileRole] = [:]
    @Binding var step: AddProfileFlow.Step?

    private func listed(_ r: ProfileRow) -> DispatcharrUserSummary? {
        users?.first { $0.username.caseInsensitiveCompare(r.username) == .orderedSame }
    }
    private func rosterAdmin(_ r: ProfileRow) -> Bool { listed(r)?.isServerAdmin == true }
    private func roleFor(_ r: ProfileRow) -> ProfileRole {
        if rosterAdmin(r) { return .admin }
        let x = roles[r.username.lowercased()] ?? ProfileRole.fromWire(r.role)
        return x == nil || x == .admin ? .user : x!
    }

    private func finish(_ r: ProfileRow, _ id: String) {
        addedIds[r.username.lowercased()] = id
        if keepAdded { added.append(r) }
        if pm.needsPinAfterAdd(playlistId, id) {
            step = .pinAfter(onDone: { ok in
                if !ok { addedIds.removeValue(forKey: r.username.lowercased()); added.removeAll { $0.username.caseInsensitiveCompare(r.username) == .orderedSame } }
                step = nil
                if ok { onAddedProfile(id); onAdded() }
            })
        } else { onAddedProfile(id); onAdded() }
    }

    func add(_ row: ProfileRow) {
        guard busy == nil, enabled else { return }
        var r = row
        r.role = roleFor(row).wire
        error = nil
        if r.role == ProfileRole.child.wire && !AddProfileFlow.childGateClear(playlistId) {
            step = .childGate(onDone: { ok in step = nil; if ok { add(row) } })
            return
        }
        guard let user = listed(r), !(user.apiKey ?? "").isEmpty else {
            let fallback = listed(r) ?? DispatcharrUserSummary(id: r.userId, username: r.username, apiKey: nil, userLevel: nil,
                                                              isSuperuser: false, isStaff: false, channelProfiles: [])
            step = .credentials(title: "Add \(r.username)", username: r.username, submit: { pw, key in
                do {
                    let p = try await pm.addFromRoster(playlistId, row: r, user: fallback, password: pw, apiKey: key)
                    step = nil
                    finish(r, p.id)
                    return nil
                } catch { return error.localizedDescription.isEmpty ? "Could not add profile" : error.localizedDescription }
            })
            return
        }
        busy = r.username
        Task {
            do { let p = try await pm.addFromRoster(playlistId, row: r, user: user, password: nil, apiKey: nil); busy = nil; finish(r, p.id) }
            catch { busy = nil; self.error = error.localizedDescription.isEmpty ? "Could not add profile" : error.localizedDescription }
        }
    }

    private func undo(_ r: ProfileRow) {
        guard let id = addedIds[r.username.lowercased()], busy == nil else { return }
        busy = r.username; error = nil
        Task {
            do {
                try await pm.undoAdd(id)
                busy = nil
                addedIds.removeValue(forKey: r.username.lowercased())
                added.removeAll { $0.username.caseInsensitiveCompare(r.username) == .orderedSame }
            } catch { busy = nil; self.error = error.localizedDescription.isEmpty ? "Could not remove profile" : error.localizedDescription }
        }
    }

    var body: some View {
        let rows = manager.rosterSuggestions[playlistId] ?? []
        let all = rows + added.filter { a in !rows.contains { $0.username.caseInsensitiveCompare(a.username) == .orderedSame } }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: ProfileUI.s(4, 10)) {
                Text(title).scaledFont(ProfileUI.label).foregroundColor(.textSecondary)
                ForEach(all, id: \.username) { r in row(r) }
                if let footnote { Text(footnote).scaledFont(ProfileUI.small).foregroundColor(.textSecondary).fixedSize(horizontal: false, vertical: true) }
                if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
            }
        }
    }

    @ViewBuilder
    private func row(_ r: ProfileRow) -> some View {
        let isAdded = added.contains { $0.username.caseInsensitiveCompare(r.username) == .orderedSame }
        let canAdd = enabled && busy == nil && !isAdded
        HStack(spacing: ProfileUI.s(8, 16)) {
            HStack(spacing: ProfileUI.s(10, 18)) {
                ProfileAvatarView(name: r.displayName.isEmpty ? r.username : r.displayName, username: r.username, spec: r.avatar, size: ProfileUI.s(28, 48))
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.displayName.isEmpty ? r.username : r.displayName).scaledFont(ProfileUI.body).foregroundColor(.textPrimary).lineLimit(1)
                    Text(r.username).scaledFont(ProfileUI.small).foregroundColor(.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            if isAdded {
                ProfileRoleBadge(text: roleFor(r).label)
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").foregroundColor(.accentPrimary)
                    Text("Added").scaledFont(ProfileUI.label).foregroundColor(.accentPrimary)
                }
                if addedIds[r.username.lowercased()] != nil {
                    Button("Remove") { undo(r) }.buttonStyle(ProfilePillStyle(filled: true))
                }
            } else {
                ProfileRoleChip(role: roleFor(r), locked: rosterAdmin(r), enabled: canAdd) { roles[r.username.lowercased()] = $0 }
                if busy == r.username { ProgressView().tint(.accentPrimary) } else {
                    Button("Add") { if canAdd { add(r) } }.buttonStyle(ProfilePillStyle(filled: true))
                }
            }
        }
        .padding(.vertical, ProfileUI.s(4, 6))
    }
}

/// Add Profile (Android AddProfileDialog): roster suggestions, the server
/// list behind "Show other users on this server", Search behind a button,
/// users with a profile on this device hidden, a role chip per row, and
/// "Enable API access" for users with no key.
struct AddProfileFlow: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let onClose: () -> Void

    enum Step {
        case credentials(title: String, username: String, submit: (String?, String?) async -> String?)
        case childGate(onDone: (Bool) -> Void)
        case pinAfter(onDone: (Bool) -> Void)
    }

    static func childGateClear(_ playlistId: String, becomingChild: String? = nil) -> Bool {
        pm.adminHasPin(playlistId) && pm.pinsMissingForChild(playlistId, becomingChild: becomingChild).isEmpty
    }

    @ObservedObject private var manager = ProfileManager.shared
    @State private var users: [DispatcharrUserSummary]?
    @State private var manual = false
    @State private var error: String?
    @State private var busy = false
    @State private var serverOpen = false
    @State private var searchOpen = false
    @State private var query = ""
    @State private var rowRoles: [Int: ProfileRole] = [:]
    @State private var minted: Set<Int> = []
    @State private var canManageKeys = false
    @State private var step: Step?
    @State private var loaded = false
    // Manual form
    @State private var useKey = false
    @State private var mUser = ""
    @State private var mSecret = ""
    @State private var manualRole: ProfileRole = .user

    private func added(_ p: DispatcharrProfile) {
        if pm.needsPinAfterAdd(playlistId, p.id) { step = .pinAfter(onDone: { _ in onClose() }) } else { onClose() }
    }

    private func roleOf(_ u: DispatcharrUserSummary) -> ProfileRole { u.isServerAdmin ? .admin : (rowRoles[u.id] ?? .user) }

    private func addUser(_ user: DispatcharrUserSummary) {
        guard !busy else { return }
        if roleOf(user) == .child && !Self.childGateClear(playlistId) {
            step = .childGate(onDone: { ok in step = nil; if ok { addUser(user) } })
            return
        }
        if let key = user.apiKey, !key.isEmpty {
            busy = true; error = nil
            Task {
                do { let p = try await pm.addProfile(playlistId, user: user, password: nil, apiKey: nil, role: roleOf(user)); added(p) }
                catch { busy = false; self.error = error.localizedDescription.isEmpty ? "Could not add profile" : error.localizedDescription; askCredentials(user) }
            }
        } else {
            askCredentials(user)
        }
    }

    private func askCredentials(_ user: DispatcharrUserSummary) {
        step = .credentials(title: "Add Profile", username: user.username, submit: { pw, key in
            do { let p = try await pm.addProfile(playlistId, user: user, password: pw, apiKey: key, role: roleOf(user)); step = nil; added(p); return nil }
            catch { return error.localizedDescription.isEmpty ? "Could not add profile" : error.localizedDescription }
        })
    }

    var body: some View {
        Group {
            switch step {
            case .credentials(let title, let username, let submit):
                CredentialStep(title: title, username: username, onCancel: { step = nil }, onSubmit: submit)
            case .childGate(let onDone):
                ChildNeedsAdminPin(playlistId: playlistId, onDone: onDone)
            case .pinAfter(let onDone):
                PinAfterAdd(playlistId: playlistId, onDone: onDone)
            case nil:
                if manual { manualForm } else { listForm }
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            pm.notePickerOpened(playlistId, "addProfile")
            canManageKeys = pm.canManageUserApiKeys(playlistId)
            do {
                switch try await pm.addCandidates(playlistId) {
                case .manual: manual = true
                case .serverList(let u): users = u
                }
            } catch { self.error = error.localizedDescription.isEmpty ? "Could not load users" : error.localizedDescription }
        }
    }

    private var listForm: some View {
        let suggested = manager.rosterSuggestions[playlistId] ?? []
        let local = manager.profilesByPlaylist[playlistId] ?? []
        let rest = users?.filter { u in
            !suggested.contains { $0.username.caseInsensitiveCompare(u.username) == .orderedSame }
                && !local.contains { $0.username.caseInsensitiveCompare(u.username) == .orderedSame }
        }
        let expanded = serverOpen || suggested.isEmpty
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = rest.map { r in q.isEmpty ? r : r.filter { $0.username.localizedCaseInsensitiveContains(q) } }
        return ProfileDialog(title: "Add Profile", onCancel: onClose) {
            RosterSuggestionsView(playlistId: playlistId, users: users, enabled: !busy, onAdded: onClose, step: $step)
            if !suggested.isEmpty, rest?.isEmpty == false {
                ProfileExpandRow(label: "Show other users on this server", expanded: serverOpen) {
                    serverOpen.toggle(); if !serverOpen { query = ""; searchOpen = false }
                }
            }
            if expanded, rest?.isEmpty == false {
                ProfileExpandRow(label: "Search", expanded: searchOpen) { searchOpen.toggle(); if !searchOpen { query = "" } }
                if searchOpen { ProfileTextField(label: "", text: $query, placeholder: "Search users") }
            }
            if users == nil && error == nil {
                ProgressView().tint(.accentPrimary)
            } else if rest?.isEmpty == true {
                if suggested.isEmpty { Text("Every Dispatcharr user on this server already has a profile.").scaledFont(ProfileUI.body).foregroundColor(.textPrimary) }
            } else if !expanded {
                EmptyView()
            } else if busy {
                ProgressView().tint(.accentPrimary)
            } else if shown?.isEmpty == true {
                Text("No users match.").scaledFont(ProfileUI.body).foregroundColor(.textSecondary)
            } else if let shown {
                ForEach(shown, id: \.id) { user in serverRow(user) }
            }
            if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
        }
    }

    @ViewBuilder
    private func serverRow(_ user: DispatcharrUserSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ProfileUI.s(8, 16)) {
                Button { addUser(user) } label: {
                    HStack(spacing: ProfileUI.s(10, 18)) {
                        ProfileAvatarView(name: user.username, username: user.username, spec: nil, size: ProfileUI.s(28, 48))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.username).scaledFont(ProfileUI.body).foregroundColor(.textPrimary).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(ProfileLevel.of(user.serverLevel).rawValue).scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
                                if (user.apiKey ?? "").isEmpty {
                                    Image(systemName: "key.fill").font(.system(size: ProfileUI.s(11, 17))).foregroundColor(.textSecondary)
                                    Text("Needs a password or API key").scaledFont(ProfileUI.small).foregroundColor(.textSecondary).lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(ProfileRowButtonStyle())
                ProfileRoleChip(role: roleOf(user), locked: user.isServerAdmin, enabled: !busy) { rowRoles[user.id] = $0 }
            }
            if canManageKeys && ((user.apiKey ?? "").isEmpty || minted.contains(user.id)) {
                EnableApiAccessRow(playlistId: playlistId, user: user, enabled: minted.contains(user.id), interactive: !busy,
                                   onEnabled: { key in minted.insert(user.id); setUserKey(user.id, key) },
                                   onRevoked: { minted.remove(user.id); setUserKey(user.id, nil) })
                    .padding(.leading, ProfileUI.s(8, 16))
            }
        }
    }

    private func setUserKey(_ id: Int, _ key: String?) {
        users = users?.map { u in
            u.id == id ? DispatcharrUserSummary(id: u.id, username: u.username, apiKey: key, userLevel: u.userLevel,
                                                isSuperuser: u.isSuperuser, isStaff: u.isStaff, channelProfiles: u.channelProfiles) : u
        }
    }

    private var manualForm: some View {
        let secretOk = !mSecret.trimmingCharacters(in: .whitespaces).isEmpty && (useKey || !mUser.trimmingCharacters(in: .whitespaces).isEmpty)
        return ProfileDialog(title: "Add Profile", confirm: ("Add Profile", secretOk && !busy, false, {
            guard secretOk, !busy else { return }
            busy = true; error = nil
            Task {
                do {
                    let p = useKey
                        ? try await pm.addProfileByApiKey(playlistId, apiKey: mSecret.trimmingCharacters(in: .whitespaces), role: manualRole)
                        : try await pm.addProfileManual(playlistId, username: mUser.trimmingCharacters(in: .whitespaces), password: mSecret, apiKey: nil, role: manualRole)
                    busy = false
                    added(p)
                } catch { busy = false; self.error = error.localizedDescription.isEmpty ? "Could not add profile" : error.localizedDescription }
            }
        }), onCancel: onClose) {
            RosterSuggestionsView(playlistId: playlistId, users: nil, enabled: !busy, onAdded: onClose, step: $step)
            Text("Role").scaledFont(ProfileUI.label).foregroundColor(.textSecondary)
            ForEach(ProfileRole.optionsFor(serverAdmin: nil), id: \.self) { r in
                ProfileChoiceRow(label: r.label, checked: r == manualRole) {
                    if r == .child && !Self.childGateClear(playlistId) {
                        step = .childGate(onDone: { ok in step = nil; if ok { manualRole = .child } })
                    } else { manualRole = r }
                }
            }
            Text(ProfileCopy.roleDescription(manualRole)).scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
            HStack(spacing: ProfileUI.s(8, 16)) {
                Button("Username & Password") { useKey = false; mUser = ""; mSecret = ""; error = nil }
                    .buttonStyle(ProfilePillStyle(filled: !useKey, selected: !useKey && ProfileUI.isTv))
                Button("API Key") { useKey = true; mUser = ""; mSecret = ""; error = nil }
                    .buttonStyle(ProfilePillStyle(filled: useKey, selected: useKey && ProfileUI.isTv))
            }
            Text(useKey ? "The API key identifies the Dispatcharr user." : "Sign in as that Dispatcharr user once.")
                .scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
            if !useKey {
                ProfileTextField(label: "Username", text: $mUser, placeholder: "Dispatcharr username")
                ProfileTextField(label: "Password", text: $mSecret, placeholder: "Dispatcharr password", secure: true)
            } else {
                ProfileTextField(label: "API Key", text: $mSecret, placeholder: "Paste the user's API key", secure: true)
            }
            if busy { ProgressView().tint(.accentPrimary) }
            if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
        }
    }
}
