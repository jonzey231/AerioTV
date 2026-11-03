//  AddProfilesStepView.swift
//  Aerio
//
//  Onboarding profiles steps for a Dispatcharr playlist (Profiles part 4),
//  ports of Android feature/onboarding/ProfileRoleStepScreen.kt,
//  AddProfilesStepScreen.kt, AddProfilesStepParts.kt, and
//  components/ManualProfileForm.kt (41bcb743, 7d16d839, 3d8bf4e1, dcc399de):
//  1. "Who is this profile for?" for a Standard server login (User or Child;
//     Child sets the Device Admin PIN, a kid-only device),
//  2. "Who watches on this iPhone?": ON THIS DEVICE with the Added chip and
//     the red minus, "From your other devices" roster suggestions, and the
//     server users (admin login) or "Add another profile" (any other login).
//  Every string is Android's word for word; the device noun is iPhone, iPad,
//  or TV where Android says phone, tablet, or TV.

import SwiftUI

enum AddProfilesCopy {
    static let rosterFootnote =
        "Adding a profile here copies its name, avatar, role, and order. Skipping it changes nothing on the other device."
    static let subtitle =
        "Profiles are chosen per device, so a shared TV and a personal phone can differ. Add the ones that belong here."

    /// Android rememberDeviceNoun: "phone", "tablet", or "TV"; Apple names the device.
    @MainActor static var deviceNoun: String {
        #if os(tvOS)
        return "TV"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    static func header(_ device: String) -> String { "Who watches on this \(device)?" }

    /// Under Continue: who is on this device so far (Android ProfileCountLine).
    static func countLine(_ device: String, _ profiles: [DispatcharrProfile]) -> String? {
        switch profiles.count {
        case 0: return nil
        case 1:
            let n = profiles[0].displayName.isEmpty ? profiles[0].username : profiles[0].displayName
            return "Only \(n) is on this \(device). You can add more later in Settings."
        default: return "\(profiles.count) profiles on this \(device)."
        }
    }
}

@MainActor private var pm: ProfileManager { ProfileManager.shared }

private var stepIsTV: Bool {
    #if os(tvOS)
    return true
    #else
    return false
    #endif
}

/// Android StepCaption: "Step 2 of 3" in the accent color.
struct OnboardingStepCaption: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let current: Int
    let total: Int
    var body: some View {
        Text("Step \(current) of \(total)")
            .scaledFont(.system(size: stepIsTV ? 22 : 14, weight: .semibold))
            .foregroundColor(.accentPrimary)
    }
}

/// The step's title and the per-device line.
private struct ProfilesStepHeader: View {
    let device: String
    var body: some View {
        VStack(spacing: stepIsTV ? 10 : 6) {
            Text(AddProfilesCopy.header(device))
                .scaledFont(.system(size: stepIsTV ? 40 : 24, weight: .semibold))
                .foregroundColor(.textPrimary)
            Text(AddProfilesCopy.subtitle)
                .scaledFont(stepIsTV ? .system(size: 22).subtext() : .bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Who is this profile for?

/// Onboarding "Who is this profile for?" right after the Dispatcharr login.
/// Only for a Standard server user; an admin login stays the local Admin.
/// Child sets a Device Admin PIN here (device-local, never synced), then the
/// profile becomes a Child: a kid-only device whose Admin is the device PIN.
struct ProfileRoleStepView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    let onDone: (_ child: Bool) -> Void

    @State private var standard = false
    @State private var choice: ProfileRole = .user
    @State private var settingPin = false
    @State private var error: String?
    @State private var done = false

    private func finish(_ child: Bool) {
        guard !done else { return }
        done = true
        onDone(child)
    }

    private func makeChild() {
        do { try pm.makeBaseChild(playlistId); finish(true) } catch { self.error = error.localizedDescription }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if settingPin {
                DeviceAdminPinSetFlow(playlistId: playlistId, onboarding: true) { err in
                    settingPin = false
                    if let err { error = err; return }
                    guard pm.hasDeviceAdminPin(playlistId) else { return } // cancelled
                    makeChild()
                }
            } else if !standard {
                ProgressView().tint(.accentPrimary)
            } else {
                ScrollView {
                    VStack(spacing: stepIsTV ? 20 : 12) {
                        Text("Who is this profile for?")
                            .scaledFont(.system(size: stepIsTV ? 40 : 24, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text("A Child profile needs a Device Admin PIN, set next. It works on this device only and is never synced.")
                            .scaledFont(stepIsTV ? .system(size: 22).subtext() : .bodyMedium.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach([ProfileRole.user, .child], id: \.self) { r in
                            ProfileChoiceRow(label: r.label, subtitle: ProfileCopy.roleDescription(r), checked: r == choice) { choice = r }
                        }
                        if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
                        OnboardingPillButton(title: "Continue", filled: true, fullWidth: true) {
                            error = nil
                            if choice == .child {
                                if pm.hasDeviceAdminPin(playlistId) { makeChild() } else { settingPin = true }
                            } else { finish(false) }
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: stepIsTV ? 900 : 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, stepIsTV ? 80 : 20)
                    .padding(.vertical, stepIsTV ? 60 : 24)
                }
                .onboardingPadCentered()
            }
        }
        .navigationBarHidden(true)
        .task {
            // The default profile is created when the playlist goes active; give it a moment.
            for _ in 0..<25 where !pm.profiles(playlistId).contains(where: \.isDefault) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if await pm.baseIsStandardUser(playlistId) { standard = true } else { finish(false) }
        }
    }
}

// MARK: - ON THIS DEVICE

/// ON THIS IPHONE/IPAD/TV: the profiles already here, each with an "Added"
/// chip; a profile added in this step also gets the red minus (undo).
private struct OnThisDeviceSection: View {
    let device: String
    let profiles: [DispatcharrProfile]
    let undoable: Set<String>
    let removeEnabled: Bool
    let onRemove: (DispatcharrProfile) -> Void

    var body: some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: stepIsTV ? 8 : 4) {
                OnboardingSectionLabel("On this \(device)")
                ForEach(profiles) { p in
                    HStack(spacing: stepIsTV ? 18 : 12) {
                        ProfileAvatarView(p, size: stepIsTV ? 56 : 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName.isEmpty ? p.username : p.displayName)
                                .scaledFont(ProfileUI.bodyStrong).foregroundColor(.textPrimary).lineLimit(1)
                            Text(p.isDefault ? "Signed in now. \(p.effectiveRole.label)." : p.effectiveRole.label)
                                .scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
                        }
                        Spacer(minLength: 8)
                        AddedChip()
                        if !p.isDefault && undoable.contains(p.id) {
                            Button { if removeEnabled { onRemove(p) } } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: stepIsTV ? 34 : 22))
                                    .foregroundColor(ProfileUI.errorColor)
                                    .frame(width: stepIsTV ? 60 : 40, height: stepIsTV ? 60 : 40)
                            }
                            #if os(tvOS)
                            .buttonStyle(TVNoHighlightButtonStyle())
                            .tvFocusRingShape(.capsule)
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .accessibilityLabel("Remove \(p.displayName.isEmpty ? p.username : p.displayName) from this device")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AddedChip: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: stepIsTV ? 18 : 12, weight: .bold))
            Text("Added").scaledFont(ProfileUI.label)
        }
        .foregroundColor(.accentPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentPrimary.opacity(0.14)))
    }
}

// MARK: - Who watches on this device?

/// "Who watches on this iPhone?" Admin login: the server users (behind "Add
/// from Dispatcharr"), checked rows with a role chip each, then Add selected.
/// Any other login: "Add another profile" with Scan a QR code (iPhone and
/// iPad) and Enter details. Both list ON THIS DEVICE and the roster
/// suggestions first.
struct AddProfilesStepView: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let playlistId: String
    /// Onboarding: "Step 2 of 3" caption.
    var onboarding = true
    /// iPhone and iPad: "Set up a TV with this playlist" (docs/DeviceSetupHandoff.md).
    var onSetUpTv: (() -> Void)? = nil
    let onDone: () -> Void

    private enum Phase { case loading, pick([DispatcharrUserSummary]), manual }

    @ObservedObject private var manager = ProfileManager.shared
    @State private var phase: Phase = .loading
    @State private var step: AddProfileFlow.Step?
    @State private var pinWalk = false
    @State private var finished = false
    @State private var busy = false
    @State private var undoBusy = false
    @State private var error: String?
    // Admin list
    @State private var selected: Set<Int> = []
    @State private var rowRoles: [Int: ProfileRole] = [:]
    @State private var needsCredential: [DispatcharrUserSummary] = []
    @State private var serverOpen = false
    @State private var searchOpen = false
    @State private var query = ""
    @State private var minted: Set<Int> = []
    @State private var canManageKeys = false
    // Manual ("Add another profile")
    @State private var wantsMore = false
    @State private var scanOpen = false
    @State private var detailsOpen = false
    @State private var scanTrigger = 0
    @State private var scanBusy = false
    @State private var scanStatus: String?
    #if os(iOS)
    @State private var setupLink: SetupTvOfferCenter.LinkBox?
    #endif
    @State private var role: ProfileRole = .user
    @State private var useKey = false
    @State private var mUser = ""
    @State private var mSecret = ""
    @State private var formBusy = false
    @State private var formError: String?

    private var device: String { AddProfilesCopy.deviceNoun }
    private var local: [DispatcharrProfile] { manager.profilesByPlaylist[playlistId] ?? [] }
    private var suggested: [ProfileRow] { manager.rosterSuggestions[playlistId] ?? [] }

    /// Adding next to a Child walks the PIN step first (Android Assumption A).
    private func done() {
        if pm.anyChild(playlistId) && !pm.pinsMissingForChild(playlistId).isEmpty { pinWalk = true; return }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if pinWalk {
                PinAfterAdd(playlistId: playlistId) { _ in pinWalk = false; finish() }
            } else if let s = step {
                stepView(s)
            } else if let u = needsCredential.first {
                CredentialStep(title: "Add \(u.username)", username: u.username, onCancel: {
                    needsCredential.removeFirst()
                    if needsCredential.isEmpty && error == nil { done() }
                }) { pw, key in
                    do {
                        _ = try await pm.addProfile(playlistId, user: u, password: pw, apiKey: key, role: roleOf(u))
                        needsCredential.removeFirst()
                        if needsCredential.isEmpty && error == nil { done() }
                        return nil
                    } catch { return error.localizedDescription.isEmpty ? "Could not add profile" : error.localizedDescription }
                }
            } else {
                switch phase {
                case .loading: ProgressView().tint(.accentPrimary)
                case .pick(let users): pickBody(users)
                case .manual: manualBody
                }
            }
        }
        .navigationBarHidden(true)
        #if os(tvOS)
        // Menu at the top of setup never closes the app.
        .onExitCommand { }
        #endif
        #if os(iOS)
        .sheet(item: $setupLink) { box in SetUpTvView(link: box.link) { setupLink = nil } }
        #endif
        .task { await load() }
    }

    @ViewBuilder
    private func stepView(_ s: AddProfileFlow.Step) -> some View {
        switch s {
        case .credentials(let title, let username, let submit):
            CredentialStep(title: title, username: username, onCancel: { step = nil }, onSubmit: submit)
        case .childGate(let onDone):
            ChildNeedsAdminPin(playlistId: playlistId, onDone: onDone)
        case .pinAfter(let onDone):
            PinAfterAdd(playlistId: playlistId, onDone: onDone)
        }
    }

    private func load() async {
        guard case .loading = phase else { return }
        canManageKeys = pm.canManageUserApiKeys(playlistId)
        do {
            switch try await pm.addCandidates(playlistId) {
            case .manual:
                phase = .manual
            case .serverList(let users):
                if !users.isEmpty { phase = .pick(users); return }
                // Nothing from the server list: wait briefly for the first pull's
                // roster before skipping (sync off: skip now).
                if DispatcharrSyncManager.shared.isEnabled {
                    for _ in 0..<32 where suggested.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                }
                debugLog("[DSYNC] onboarding add step: \(suggested.count) suggestions")
                if suggested.isEmpty { finish() } else { phase = .pick([]) }
            }
        } catch {
            debugLog("[PROFILE] onboarding step skipped: \(type(of: error))")
            finish()
        }
    }

    private func undo(_ p: DispatcharrProfile) {
        guard !undoBusy else { return }
        undoBusy = true
        Task {
            do { try await pm.undoAdd(p.id) } catch { self.error = error.localizedDescription.isEmpty ? "Could not remove profile" : error.localizedDescription }
            undoBusy = false
        }
    }

    private var header: some View {
        VStack(spacing: stepIsTV ? 12 : 8) {
            if onboarding { OnboardingStepCaption(current: 2, total: 3) }
            ProfilesStepHeader(device: device)
        }
    }

    private var onThisDevice: some View {
        OnThisDeviceSection(device: device, profiles: local, undoable: manager.undoableRosterAdds,
                            removeEnabled: !busy && !undoBusy, onRemove: undo)
    }

    private func roster(_ users: [DispatcharrUserSummary]?) -> some View {
        RosterSuggestionsView(playlistId: playlistId, users: users, enabled: !busy, onAdded: {},
                              title: "FROM YOUR OTHER DEVICES", footnote: AddProfilesCopy.rosterFootnote,
                              keepAdded: false, step: $step)
    }

    @ViewBuilder
    private var countLine: some View {
        if let line = AddProfilesCopy.countLine(device, local) {
            Text(line)
                .scaledFont(ProfileUI.small).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var setUpTvLink: some View {
        if let onSetUpTv {
            Button(action: onSetUpTv) {
                Text("Set up a TV with this playlist")
                    .scaledFont(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentPrimary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Admin login: the server users

    private func roleOf(_ u: DispatcharrUserSummary) -> ProfileRole { u.isServerAdmin ? .admin : (rowRoles[u.id] ?? .user) }

    private func rest(_ users: [DispatcharrUserSummary]) -> [DispatcharrUserSummary] {
        users.filter { u in
            !suggested.contains { $0.username.caseInsensitiveCompare(u.username) == .orderedSame }
                && !local.contains { $0.username.caseInsensitiveCompare(u.username) == .orderedSame }
        }
    }

    private func addSelected(_ users: [DispatcharrUserSummary]) {
        guard !busy else { return }
        let picked = users.filter { selected.contains($0.id) }
        if picked.contains(where: { roleOf($0) == .child }) && !AddProfileFlow.childGateClear(playlistId) {
            step = .childGate(onDone: { ok in step = nil; if ok { addSelected(users) } })
            return
        }
        busy = true; error = nil
        Task {
            var failures: [String] = []
            var creds: [DispatcharrUserSummary] = []
            for u in picked {
                if (u.apiKey ?? "").isEmpty { creds.append(u); continue }
                do { _ = try await pm.addProfile(playlistId, user: u, password: nil, apiKey: nil, role: roleOf(u)) }
                catch { failures.append(u.username) }
            }
            busy = false
            needsCredential = creds
            if !failures.isEmpty {
                error = "Could not add: \(failures.joined(separator: ", "))"
                selected = Set(users.filter { failures.contains($0.username) }.map(\.id))
            } else if creds.isEmpty {
                done()
            }
        }
    }

    private func setUserKey(_ users: [DispatcharrUserSummary], _ id: Int, _ key: String?) {
        phase = .pick(users.map { u in
            u.id == id ? DispatcharrUserSummary(id: u.id, username: u.username, apiKey: key, userLevel: u.userLevel,
                                                isSuperuser: u.isSuperuser, isStaff: u.isStaff, channelProfiles: u.channelProfiles) : u
        })
    }

    @ViewBuilder
    private func userList(_ users: [DispatcharrUserSummary]) -> some View {
        let rest = rest(users)
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? rest : rest.filter { $0.username.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: stepIsTV ? 12 : 10) {
            onThisDevice
            roster(users)
            if !rest.isEmpty {
                OnboardingActionCard(
                    icon: "person.badge.plus",
                    title: "Add from Dispatcharr",
                    detail: "Choose an existing Dispatcharr user to add as a profile on this device.",
                    highlighted: serverOpen,
                    trailingSymbol: serverOpen ? "chevron.down" : "chevron.right"
                ) {
                    serverOpen.toggle()
                    if !serverOpen { query = ""; searchOpen = false }
                }
            }
            if serverOpen && !rest.isEmpty {
                ProfileExpandRow(label: "Search", expanded: searchOpen) { searchOpen.toggle(); if !searchOpen { query = "" } }
                if searchOpen { ProfileTextField(label: "", text: $query, placeholder: "Search users") }
            }
            if serverOpen {
                ForEach(shown, id: \.id) { u in serverRow(users, u) }
            }
            if serverOpen && shown.isEmpty && (suggested.isEmpty || !rest.isEmpty) {
                Text(rest.isEmpty ? "No other users on this server." : "No users match.")
                    .scaledFont(ProfileUI.body).foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        }
    }

    private func serverRow(_ users: [DispatcharrUserSummary], _ user: DispatcharrUserSummary) -> some View {
        let checked = selected.contains(user.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ProfileUI.s(8, 16)) {
                Button {
                    guard !busy else { return }
                    if checked { selected.remove(user.id) } else { selected.insert(user.id) }
                } label: {
                    HStack(spacing: ProfileUI.s(12, 18)) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: ProfileUI.s(22, 32)))
                            .foregroundColor(checked ? .accentPrimary : .textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.username).scaledFont(ProfileUI.bodyStrong).foregroundColor(.textPrimary).lineLimit(1)
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
                .accessibilityAddTraits(checked ? .isSelected : [])
                if checked {
                    ProfileRoleChip(role: roleOf(user), locked: user.isServerAdmin, enabled: !busy) { rowRoles[user.id] = $0 }
                }
            }
            if canManageKeys && ((user.apiKey ?? "").isEmpty || minted.contains(user.id)) {
                EnableApiAccessRow(playlistId: playlistId, user: user, enabled: minted.contains(user.id), interactive: !busy,
                                   onEnabled: { key in minted.insert(user.id); setUserKey(users, user.id, key) },
                                   onRevoked: { minted.remove(user.id); setUserKey(users, user.id, nil) })
                    .padding(.leading, ProfileUI.s(8, 16))
            }
        }
    }

    @ViewBuilder
    private func pickControls(_ users: [DispatcharrUserSummary]) -> some View {
        VStack(spacing: stepIsTV ? 14 : 10) {
            if let error { Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
            if busy {
                ProgressView().tint(.accentPrimary).frame(minHeight: stepIsTV ? 60 : 44)
            } else {
                OnboardingPillButton(title: selected.isEmpty ? "Continue" : "Add selected", filled: true, fullWidth: true) {
                    if selected.isEmpty { done() } else { addSelected(users) }
                }
            }
            countLine
            setUpTvLink
        }
    }

    @ViewBuilder
    private func pickBody(_ users: [DispatcharrUserSummary]) -> some View {
        if stepIsTV {
            // TV: the list on the left, the actions on the right (Android TV layout).
            VStack(spacing: 24) {
                header.frame(maxWidth: 1100)
                HStack(alignment: .top, spacing: 48) {
                    // Bottom fade: the list scrolls (Android d57ef3d0).
                    ScrollView { userList(users).padding(.vertical, 8).padding(.bottom, 40) }
                        .frame(maxWidth: .infinity)
                        .mask {
                            VStack(spacing: 0) {
                                Color.black
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 60)
                            }
                        }
                    ScrollView { pickControls(users) }
                        .frame(width: 560)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 48)
        } else {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        userList(users)
                    }
                    .padding(.top, 24)
                }
                pickControls(users).padding(.bottom, 16)
            }
            .onboardingPadWidth(560, other: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
    }

    // MARK: Any other login: "Add another profile"

    private func collapseAfterAdd() {
        wantsMore = false; scanOpen = false; detailsOpen = false
        role = .user
        mUser = ""; mSecret = ""
    }

    /// Profiles added here are undoable: the Added chip and the red minus.
    private func addWith(_ username: String, _ password: String?, _ apiKey: String?) async -> String? {
        do {
            let p = apiKey != nil
                ? try await pm.addProfileByApiKey(playlistId, apiKey: apiKey!, role: role)
                : try await pm.addProfileManual(playlistId, username: username, password: password, apiKey: nil, role: role)
            pm.markFreshAddUndoable(p.id)
            if pm.needsPinAfterAdd(playlistId, p.id) {
                step = .pinAfter(onDone: { _ in step = nil })
            }
            collapseAfterAdd()
            return nil
        } catch { return error.localizedDescription.isEmpty ? "Could not add profile" : error.localizedDescription }
    }

    private func pickRole(_ r: ProfileRole) {
        if r == .child && !AddProfileFlow.childGateClear(playlistId) {
            step = .childGate(onDone: { ok in step = nil; if ok { role = .child } })
        } else { role = r }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: ProfileUI.s(8, 14)) {
            if !useKey {
                ProfileTextField(label: "Username", text: $mUser, placeholder: "Dispatcharr username")
                ProfileTextField(label: "Password", text: $mSecret, placeholder: "Dispatcharr password", secure: true)
            } else {
                ProfileTextField(label: "API Key", text: $mSecret, placeholder: "Paste the user's API key", secure: true)
            }
            Button {
                guard !formBusy else { return }
                useKey.toggle(); mUser = ""; mSecret = ""; formError = nil
            } label: {
                Text(useKey ? "Use a username and password instead" : "Use an API key instead")
                    .scaledFont(.bodyMedium).foregroundColor(.accentPrimary).frame(minHeight: 40)
            }
            .buttonStyle(ProfileRowButtonStyle())
            // Each role radio carries its own description (Android descriptionPerChoice).
            ForEach(ProfileRole.optionsFor(serverAdmin: nil), id: \.self) { r in
                ProfileChoiceRow(label: r.label, subtitle: ProfileCopy.roleDescription(r), checked: r == role) { pickRole(r) }
            }
            if let formError { Text(formError).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor) }
            // Never disabled mid-flow (TV focus); taps are ignored while busy.
            OnboardingPillButton(title: formBusy ? "Adding" : "Add profile", filled: true, fullWidth: true) {
                let secret = mSecret.trimmingCharacters(in: .whitespaces)
                let name = mUser.trimmingCharacters(in: .whitespaces)
                guard !formBusy, !secret.isEmpty, useKey || !name.isEmpty else { return }
                formBusy = true; formError = nil
                Task {
                    formError = useKey ? await addWith("", nil, secret) : await addWith(name, mSecret, nil)
                    formBusy = false
                }
            }
        }
    }

    private var manualBody: some View {
        ScrollView {
            VStack(spacing: stepIsTV ? 18 : 12) {
                header
                onThisDevice
                roster(nil)
                // One expandable card: Continue already covers "not now".
                OnboardingActionCard(
                    icon: "person.badge.plus",
                    title: "Add another profile",
                    detail: "Scan a QR code or sign in as another Dispatcharr user.",
                    trailingSymbol: wantsMore ? "chevron.up" : "chevron.right"
                ) {
                    if wantsMore { wantsMore = false; scanOpen = false; detailsOpen = false } else { wantsMore = true }
                }
                if wantsMore {
                    #if os(iOS)
                    // Apple TV has no camera: Scan a QR code is iPhone and iPad only.
                    OnboardingActionCard(
                        icon: "qrcode.viewfinder",
                        title: "Scan a QR code",
                        detail: "Use the QR code from your Dispatcharr administrator, or import it from Photos.",
                        highlighted: scanOpen
                    ) {
                        scanOpen = true; detailsOpen = false; scanStatus = nil; scanTrigger += 1
                    }
                    QrScanActions(enabled: !scanBusy, linksOnly: true, scanTrigger: scanTrigger) { r in
                        scanOpen = true; detailsOpen = false
                        switch r {
                        case .userKey(let k):
                            guard !scanBusy else { return }
                            scanBusy = true; scanStatus = nil
                            Task {
                                scanStatus = await addWith("", nil, k.apiKey)
                                scanBusy = false
                            }
                        case .setupLink(let l): setupLink = .init(link: l)
                        case .invalid: break
                        }
                    }
                    if scanBusy { ProgressView().tint(.accentPrimary) }
                    if let scanStatus {
                        Text(scanStatus).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #endif
                    OnboardingActionCard(
                        icon: "square.and.pencil",
                        title: "Enter details",
                        detail: "Sign in as that Dispatcharr user once.",
                        highlighted: detailsOpen
                    ) {
                        detailsOpen.toggle()
                        if detailsOpen { scanOpen = false }
                    }
                    if detailsOpen { manualForm }
                }
                if let error {
                    Text(error).scaledFont(ProfileUI.small).foregroundColor(ProfileUI.errorColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // While Enter details is open, Add profile is the single filled primary.
                OnboardingPillButton(title: "Continue", filled: !(wantsMore && detailsOpen), fullWidth: true) { done() }
                    .padding(.top, 4)
                countLine
                setUpTvLink
            }
            .onboardingPadWidth(560, other: stepIsTV ? 1000 : 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, stepIsTV ? 80 : 20)
            .padding(.vertical, stepIsTV ? 48 : 24)
        }
        .onboardingPadCentered()
    }
}
