//  ProfileManager.swift
//  Aerio
//
//  Profiles for Dispatcharr playlists, ported from the Android
//  core/profiles/ProfileManager.kt. Owns the profile records, the one-time
//  migration (each Dispatcharr Direct Connect playlist gets exactly one
//  default profile named after its login), add, rename, avatar, role, PIN,
//  order, remove, the roster catalog from Dispatcharr Sync, and the switch.
//  Xtream and M3U playlists never get a profile.
//
//  Apple differences, each forced by the platform:
//  - No ProfileScope overlay: the playlist row (ServerConnection) is always
//    the default profile; another profile's per-user facts stay on its
//    record and its API key in the Keychain (activeApiKey reads it).
//  - Settings swap on switch (ProfileSettingsStore) instead of scoped keys.
//  - Logs carry the profile id prefix, never a username or display name.
//
//  The UI (part 3) and onboarding (part 4) bind to the @Published state
//  below; Dispatcharr Sync binds to onProfilesMutated, onPickerOpened, and
//  onSwitched.

import Foundation
import Combine

/// The Keychain behind the profile stores (KeychainHelper, device only).
final class KeychainSecretBox: ProfileSecretBox {
    func get(_ key: String) -> String? { KeychainHelper.load(key: key) }
    func set(_ value: String?, _ key: String) {
        if let value { KeychainHelper.save(value, for: key) } else { KeychainHelper.delete(key) }
    }
}

enum ProfileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

private func fail(_ m: String) -> ProfileError { .message(m) }

@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    let store: ProfileStore
    let pinStore: ProfilePinStore
    let settings: ProfileSettingsStore
    let data: ProfileDataStore
    /// Profile sign-ins held after a server address change (ProfileHostHold.swift).
    let holds: ProfileHostHoldStore

    // MARK: Published state for the UI (part 3) and onboarding (part 4)

    /// Every playlist's profiles in list order.
    @Published private(set) var profilesByPlaylist: [String: [DispatcharrProfile]] = [:]
    /// Active profile id per playlist (the default profile when none is set).
    @Published private(set) var activeProfileIds: [String: String] = [:]
    /// The active playlist's active role (nil = no Dispatcharr playlist).
    @Published private(set) var activeRoleNow: ProfileRole? = nil
    /// "From your other devices": synced roster rows with no local profile, per playlist.
    @Published private(set) var rosterSuggestions: [String: [ProfileRow]] = [:]
    /// Profile ids undoAdd accepts right now (onboarding shows Remove on these rows).
    @Published private(set) var undoableRosterAdds: Set<String> = []
    /// True from the first step of a switch until it landed.
    @Published private(set) var switching = false
    /// The locked profile whose PIN must be entered before any content shows.
    @Published private(set) var launchGate: DispatcharrProfile? = nil
    /// Non-null while the TV "who is watching" picker covers the app at launch.
    @Published private(set) var launchPicker: LaunchPicker? = nil
    /// A switch asked for a profile with a PIN and no ticket: the UI shows the PIN pad.
    @Published var pendingPinPrompt: PinPrompt? = nil
    /// Bumps on every PIN change (set, remove, migration, synced import).
    @Published private(set) var pinChanges: Int64 = 0

    struct LaunchPicker: Equatable { let playlistId: String; let lastProfileId: String? }
    struct PinPrompt: Equatable { let playlistId: String; let profileId: String }

    enum PinCheck: Equatable { case ok, wrong, locked(Int) }

    // MARK: Hooks

    /// Dispatcharr Sync: every profile list mutation (add, remove, rename,
    /// role, PIN, order) reports here so the `profiles` key is stamped and re-sent.
    var onProfilesMutated: ((_ playlistId: String, _ username: String, _ what: String, _ stampAt: Int64) -> Void)?
    /// Dispatcharr Sync: a profile picker surface opened (launch, switch, addProfile, foreground).
    var onPickerOpened: ((_ playlistId: String, _ reason: String) -> Void)?
    /// A switch landed: Dispatcharr Sync re-keys its session; the UI reloads channels, groups, and VOD.
    var onSwitched: ((_ playlistId: String, _ from: String?, _ to: String) -> Void)?
    /// Dispatcharr Sync: before a switch, push the outgoing profile's pending changes (Android flush on session end).
    var beforeSwitch: ((_ playlistId: String) async -> Void)?
    /// Dispatcharr Sync: these profiles' sign-ins were just held (a server address change).
    var onSignInsHeld: ((_ playlistId: String, _ profileIds: Set<String>) -> Void)?
    /// Dispatcharr Sync: nothing on the playlist is held any more; the `profiles` category syncs again.
    var onRosterSyncResumed: ((_ playlistId: String) -> Void)?
    /// True while anything is playing (main player, mini player, background audio).
    var isPlaying: () -> Bool = { false }
    /// The stop-playback confirmation ("Switching profiles stops playback"); true = go ahead.
    var confirmStopPlayback: (() async -> Bool)?

    private var started = false
    private var cancellables: [AnyCancellable] = []
    private var lastActivePlaylist: String?

    private init() {
        let box = KeychainSecretBox()
        store = ProfileStore(defaults: .standard, secrets: box)
        pinStore = ProfilePinStore(defaults: .standard, secrets: box)
        settings = ProfileSettingsStore(defaults: .standard)
        data = ProfileDataStore(defaults: .standard)
        holds = ProfileHostHoldStore(defaults: .standard)
        store.onChange = { [weak self] in self?.publish() }
        pinStore.onChange = { [weak self] in
            guard let self else { return }
            self.pinChanges = self.pinStore.changes
        }
        publish()
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func nowS() -> Int64 { Int64(Date().timeIntervalSince1970) }
    private static func tag(_ id: String) -> String { String(id.prefix(8)) }

    private func publish() {
        var by: [String: [DispatcharrProfile]] = [:]
        for pid in Set(store.profiles.map(\.playlistId)) { by[pid] = store.forPlaylist(pid) }
        if by != profilesByPlaylist { profilesByPlaylist = by }
        var act: [String: String] = [:]
        for pid in by.keys { if let a = activeProfileIdNow(pid) { act[pid] = a } }
        if act != activeProfileIds { activeProfileIds = act }
        refreshRosterPause()
        var s: [String: [ProfileRow]] = [:]
        for (pid, rows) in rosterRows {
            // No suggestions while the playlist's roster sync is paused (a held profile).
            s[pid] = rosterSyncPaused(pid) ? [] : ProfileRoster.suggestions(rows, store.forPlaylist(pid).map(\.username))
        }
        if s != rosterSuggestions { rosterSuggestions = s }
        refreshActiveRole()
        refreshOverlay(act)
    }

    /// True while any profile of [playlistId] is held after a server address
    /// change: Dispatcharr Sync pauses the `profiles` category in both
    /// directions (DsyncRosterPause), and no roster suggestions are offered.
    func rosterSyncPaused(_ playlistId: String) -> Bool { holds.record(playlistId) != nil }

    private var rosterPaused = Set<String>()

    /// Logs the pause and the resume once each; a resume asks Dispatcharr Sync to merge the roster again.
    private func refreshRosterPause() {
        let now = holds.heldPlaylistIds
        for pid in now.subtracting(rosterPaused).sorted() { debugLog("[PROFILE-HOST] roster sync paused playlist=\(Self.tag(pid))") }
        let resumed = rosterPaused.subtracting(now).sorted()
        rosterPaused = now
        for pid in resumed {
            debugLog("[PROFILE-HOST] roster sync resumed playlist=\(Self.tag(pid))")
            onRosterSyncResumed?(pid)
        }
    }

    /// The request overlay (ProfileOverlay): every playlist whose active profile is not the default.
    private func refreshOverlay(_ act: [String: String]) {
        var next: [String: ProfileOverlay.Values] = [:]
        for (pid, id) in act {
            // A held sign-in is never laid over a request (ProfileHostHold).
            guard let p = store.byId(id), !p.isDefault, let key = signIns.apiKey(id, for: .requestOverlay), !key.isEmpty else { continue }
            let ids = p.accountProfileIds.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            next[pid] = ProfileOverlay.Values(profileId: id, apiKey: key, channelProfileIds: ids)
        }
        if ProfileOverlay.set(next) { debugLog("[PROFILE] request overlay: \(next.count) playlist(s) on a non-default profile") }
        var caps: [String: ProfileCapsOverlay.Values] = [:]
        for (pid, id) in act {
            guard let p = store.byId(id), !p.isDefault else { continue }
            caps[pid] = ProfileCapsOverlay.Values(
                userLevel: p.userLevel, isStaff: p.isStaff, isSuperuser: p.isSuperuser,
                customProperties: p.customProperties,
                fetchedAt: p.capabilitiesFetchedAt > 0 ? Date(timeIntervalSince1970: Double(p.capabilitiesFetchedAt) / 1000) : nil)
        }
        if ProfileCapsOverlay.set(caps) {
            debugLog("[PERMS] profile overlay: \(caps.count) playlist(s) gate on the active profile's own permissions")
            NotificationCenter.default.post(name: .dispatcharrCapabilitiesDidChange, object: nil)
        }
    }

    /// The capability probe for a playlist whose active profile is not the
    /// default: the same /me/ read, with that profile's own key, stored on
    /// the profile (Android refreshes the active profile's permissions the
    /// same way). Returns whether the server was reached.
    func refreshActiveCapabilities(_ playlistId: String, reason: String) async -> Bool {
        guard let p = activeProfile(playlistId), !p.isDefault, let server = DsyncLocal.server(playlistId),
              let key = signIns.apiKey(p.id, for: .profileSwitch) else { return false }
        guard let me = await fetchMe(server, key),
              me.username.caseInsensitiveCompare(p.username) == .orderedSame,
              let live = store.byId(p.id) else {
            debugLog("[PERMS] profile probe FAILED \(Self.tag(p.id)) reason=\(reason); keeping the last snapshot")
            return false
        }
        let next = applyMe(live, me)
        let changed = next.userLevel != live.userLevel || next.dvrAccess != live.dvrAccess
            || next.catchupEnabled != live.catchupEnabled || next.vodMoviesEnabled != live.vodMoviesEnabled
            || next.vodSeriesEnabled != live.vodSeriesEnabled || next.customProperties != live.customProperties
            || next.isStaff != live.isStaff || next.isSuperuser != live.isSuperuser
        store.upsert(next)
        followServerRole(p.id, me.effectiveUserLevel)
        publish()
        await saveAccountFacts(server, key: key, me: me)
        debugLog("[PERMS] profile probe OK \(Self.tag(p.id)) level=\(next.userLevel) dvr=\(next.dvrAccess.isEmpty ? "default" : next.dvrAccess) catchup=\(next.catchupEnabled) vod=\(next.vodMoviesEnabled) series=\(next.vodSeriesEnabled) changed=\(changed) reason=\(reason)")
        if changed { NotificationCenter.default.post(name: .dispatcharrCapabilitiesDidChange, object: nil) }
        return true
    }

    /// True while [playlistId] (default: the active Dispatcharr playlist) runs a non-default profile.
    /// iCloud backs up the default profile only (Android Drive sync runs under defaultOnly).
    func nonDefaultActive(_ playlistId: String? = nil) -> Bool {
        guard let pid = playlistId ?? DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString else { return false }
        return ProfileOverlay.values(pid) != nil
    }

    // MARK: Lifecycle

    /// Migration, launch restore, and active-playlist tracking. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        restoreAtLaunch()
        ChannelStore.shared.$channels
            .sink { [weak self] _ in Task { @MainActor in await self?.activePlaylistMaybeChanged() } }
            .store(in: &cancellables)
        Task {
            // A profile whose sign-in was held when the app last closed is
            // left for the default profile before anything loads as it.
            for pid in Set(store.profiles.map(\.playlistId)) { await leaveHeldProfile(pid) }
            await activePlaylistMaybeChanged()
            let ids = store.profiles.filter { !$0.isDefault }.map(\.id)
            let n = settings.seedExistingOnce(ids, source: settings.capture())
            if n > 0 { debugLog("[PROFILE] settings seeded for \(n) existing profile(s)") }
        }
    }

    /// Synchronous launch restore (Android restoreSync): the launch picker or the PIN gate.
    private func restoreAtLaunch() {
        guard let pid = store.lastActivePlaylistId else { return }
        let all = store.forPlaylist(pid)
        // A held profile is never restored: start() leaves it for the default profile.
        let active = store.activeProfileId(pid).flatMap(store.byId).flatMap { holds.isHeld($0.id) ? nil : $0 }
        let restored = (active?.playlistId == pid ? active : nil) ?? all.first { $0.isDefault }
        if RoleRules.showLaunchPicker(isTv: DsyncLocal.isTv, isDispatcharr: !all.isEmpty, toggleOn: store.askAtLaunch(pid),
                                      profileCount: all.count, lastRole: restored?.effectiveRole) {
            launchPicker = LaunchPicker(playlistId: pid, lastProfileId: restored?.id)
            debugLog("[PROFILE] launch picker armed (\(all.count) profiles)")
            return
        }
        if let restored, pinStore.hasPin(restored.id) {
            launchGate = restored
            debugLog("[PROFILE] launch gate armed for \(Self.tag(restored.id))")
        }
    }

    private func activePlaylistMaybeChanged() async {
        let pid = DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString
        guard pid != lastActivePlaylist else { return }
        lastActivePlaylist = pid
        guard let pid, let server = DsyncLocal.server(pid) else { refreshActiveRole(); return }
        store.lastActivePlaylistId = pid
        await ensureDefaultProfile(server)
        if let base = store.forPlaylist(pid).first(where: \.isDefault) {
            followServerRole(base.id, server.dispatcharrIsSuperuser || server.dispatcharrIsStaff ? 10 : server.dispatcharrUserLevel)
        }
        publish()
    }

    /// Every Dispatcharr playlist has exactly one default profile.
    private func ensureDefaultProfile(_ server: ServerConnection, preferredId: String? = nil) async {
        guard server.type == .dispatcharrAPI else { return }
        let pid = server.id.uuidString
        if store.forPlaylist(pid).contains(where: \.isDefault) { return }
        var username = server.dispatcharrCredentialType == .usernamePassword ? server.username : ""
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            // API-key login: ask the server who the key belongs to.
            if let me = await fetchMe(server, server.baseApiKey) {
                username = me.username
                noteDefaultUsersMe(pid, userId: me.id, username: me.username)
            }
        }
        if store.forPlaylist(pid).contains(where: \.isDefault) { return }
        // A setup handoff passes the sender's profile id (kept when free here).
        let newId = preferredId.flatMap { store.byId($0) == nil ? $0 : nil } ?? UUID().uuidString
        var p = DispatcharrProfile(id: newId, playlistId: pid,
                                   displayName: username.isEmpty ? server.name : username,
                                   username: username, isDefault: true)
        p.userLevel = server.dispatcharrUserLevel
        // The role follows the Dispatcharr access (owner 2026-10-29).
        p.role = ProfileRole.defaultFor(server.dispatcharrUserLevel)
        p.createdAt = 0
        store.upsert(p)
        debugLog("[PROFILE] migrated playlist \(Self.tag(pid)) -> default profile")
    }

    // MARK: Reads

    func profiles(_ playlistId: String) -> [DispatcharrProfile] { store.forPlaylist(playlistId) }

    func activeProfileIdNow(_ playlistId: String) -> String? {
        if let a = store.activeProfileId(playlistId), store.byId(a) != nil { return a }
        return store.forPlaylist(playlistId).first(where: \.isDefault)?.id
    }

    func activeProfile(_ playlistId: String) -> DispatcharrProfile? { activeProfileIdNow(playlistId).flatMap(store.byId) }
    func roleOf(_ profileId: String) -> ProfileRole? { store.byId(profileId)?.effectiveRole }
    func activeRole(_ playlistId: String) -> ProfileRole? { activeProfile(playlistId)?.effectiveRole }
    func anyChild(_ playlistId: String) -> Bool { store.forPlaylist(playlistId).contains { $0.effectiveRole == .child } }
    func profileIdFor(_ playlistId: String, _ username: String) -> String? {
        store.forPlaylist(playlistId).first { $0.username.caseInsensitiveCompare(username) == .orderedSame }?.id
    }

    /// The API key requests for [playlistId] use: the active profile's own key, or the playlist's for the default.
    func activeApiKey(_ playlistId: String) -> String? {
        guard let p = activeProfile(playlistId) else { return nil }
        if p.isDefault { return DsyncLocal.server(playlistId)?.baseApiKey }
        return signIns.apiKey(p.id, for: .syncSession)
    }

    /// The session's user id when not read yet (a default profile never switched to): ask /me/ once.
    func ensureUserId(_ playlistId: String) async -> Int {
        guard let p = activeProfile(playlistId) else { return 0 }
        if p.userId > 0 { return p.userId }
        guard let server = DsyncLocal.server(playlistId), let key = activeApiKey(playlistId),
              let me = await fetchMe(server, key), me.username.caseInsensitiveCompare(p.username) == .orderedSame else { return 0 }
        if p.isDefault { noteDefaultUsersMe(playlistId, userId: me.id, username: me.username) }
        store.update(p.id) { var c = $0; c.userId = me.id; return c }
        return me.id
    }

    /// The server users for the `profiles` key: the admin list, or the local profiles' own ids.
    func syncUsers(_ playlistId: String) async -> [DispatcharrUserSummary] {
        if activeIsAdmin(playlistId) && baseIsServerAdmin(playlistId), let server = DsyncLocal.server(playlistId),
           let list = try? await baseApi(server).listUsers(), !list.isEmpty { return list }
        // No users list without a server admin key (403): the local profiles' own user ids stand in.
        return store.forPlaylist(playlistId).filter { $0.userId > 0 }.map { DispatcharrUserSummary(id: $0.userId, username: $0.username) }
    }

    private func refreshActiveRole() {
        let role = store.lastActivePlaylistId.flatMap { activeRole($0) }
        if activeRoleNow != role {
            activeRoleNow = role
            debugLog("[PROFILE] active role \(role?.label ?? "none")")
        }
    }

    /// Admin profiles may add and remove profiles. Reads the ACTIVE user.
    func activeIsAdmin(_ playlistId: String) -> Bool {
        guard let p = activeProfile(playlistId) else { return false }
        if p.isDefault, let s = DsyncLocal.server(playlistId) {
            return s.dispatcharrUserLevel >= 10 || s.dispatcharrIsSuperuser || s.dispatcharrIsStaff
        }
        return p.userLevel >= 10 || p.isSuperuser || p.isStaff
    }

    /// The BASE login (the playlist row's own credentials) is a server admin.
    func baseIsServerAdmin(_ playlistId: String) -> Bool {
        guard let s = DsyncLocal.server(playlistId) else { return false }
        return s.dispatcharrUserLevel >= 10 || s.dispatcharrIsSuperuser || s.dispatcharrIsStaff
    }

    // MARK: Network helpers

    /// An API instance signed in as one user's key. serverID stays nil: the
    /// base user's silent re-bootstrap must never swap in the playlist's key.
    private func api(_ server: ServerConnection, key: String) -> DispatcharrAPI {
        DispatcharrAPI(baseURL: server.effectiveBaseURL, auth: .apiKey(key), userAgent: server.effectiveUserAgent,
                       authMode: server.dispatcharrHeaderMode)
    }

    /// The playlist's own (base) credential, with its normal recovery.
    private func baseApi(_ server: ServerConnection) -> DispatcharrAPI {
        let jwt = server.dispatcharrCredentialType == .usernamePassword
        return DispatcharrAPI(baseURL: server.effectiveBaseURL, auth: .apiKey(server.baseApiKey),
                              userAgent: server.effectiveUserAgent, authMode: server.dispatcharrHeaderMode,
                              serverID: server.id, savedUsername: jwt ? server.username : nil)
    }

    private func fetchMe(_ server: ServerConnection, _ key: String) async -> DispatcharrUser? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        return try? await api(server, key: k).fetchCurrentUser()
    }

    private struct Auth { let key: String; let me: DispatcharrUser }

    /// The active profile's display facts (username, Channel Profile names)
    /// for the Playlist Detail permissions section. Call after publish() so
    /// the store keys on the active profile (Android: profile-scoped facts).
    private func saveAccountFacts(_ server: ServerConnection, key: String, me: DispatcharrUser) async {
        var facts = DispatcharrAccountFacts()
        facts.username = me.username
        if !me.channelProfiles.isEmpty,
           let profiles = try? await api(server, key: key).listChannelProfiles() {
            facts.profileNames = me.channelProfiles.compactMap { id in
                profiles.first(where: { $0.id == id })?.name
            }
        }
        DispatcharrAccountFactsStore.save(facts, for: server.id)
    }

    /// Sign in as one user: a stored API key first with one GET /me/, then the
    /// password login (POST token + GET me) when the key is missing, rejected,
    /// or belongs to someone else.
    private func authenticate(_ server: ServerConnection, username: String, password: String?, apiKey: String?) async throws -> Auth {
        if let stored = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            // The user typed this sign-in on purpose: let it reach the server
            // even if an earlier copy of the key is held as rejected.
            DispatcharrRequestGate.shared.clearKey(stored)
            if let me = await fetchMe(server, stored),
               username.isEmpty || me.username.caseInsensitiveCompare(username) == .orderedSame {
                return Auth(key: stored, me: me)
            }
            if password?.isEmpty ?? true { throw fail("The API key for \(username) was rejected.") }
        }
        guard let password, !password.isEmpty, !username.isEmpty else { throw fail("Enter a password or an API key.") }
        let pair: DispatcharrJWTPair
        do {
            pair = try await DispatcharrAPI.login(baseURL: server.effectiveBaseURL, username: username, password: password,
                                                  userAgent: server.effectiveUserAgent)
        } catch {
            throw fail("Sign-in for \(username) was rejected. Try again in a minute.")
        }
        let jwtApi = DispatcharrAPI(baseURL: server.effectiveBaseURL, auth: .bearer(pair.access),
                                    userAgent: server.effectiveUserAgent, authMode: server.dispatcharrHeaderMode)
        let me = try await jwtApi.fetchCurrentUser()
        return Auth(key: me.apiKey, me: me)
    }

    private func applyMe(_ p: DispatcharrProfile, _ me: DispatcharrUser) -> DispatcharrProfile {
        var c = p
        c.userId = me.id
        c.username = me.username
        c.userLevel = me.effectiveUserLevel
        let props = me.customPropertiesJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        c.hideAdultContent = (props?["hide_adult_content"] as? Bool) == true
        c.dvrAccess = me.dvrAccessRaw?.lowercased() ?? ""
        c.catchupEnabled = me.catchupEnabled
        c.vodMoviesEnabled = me.vodMoviesEnabled
        c.vodSeriesEnabled = me.vodSeriesEnabled
        c.accountProfileIds = me.channelProfiles.map(String.init).joined(separator: ",")
        c.isStaff = me.isStaff
        c.isSuperuser = me.isSuperuser
        c.customProperties = me.customPropertiesJSON
        c.capabilitiesFetchedAt = Self.nowMs()
        return c
    }

    /// Owner rule 2026-10-29: the AerioTV role follows the Dispatcharr access.
    private func followServerRole(_ profileId: String, _ newLevel: Int) {
        guard let p = store.byId(profileId) else { return }
        let next = RoleRules.serverRoleChange(p.role, newLevel)
        if next == nil && p.userLevel == newLevel { return }
        store.update(profileId) { var c = $0; c.userLevel = newLevel; if let next { c.role = next }; return c }
        if let next {
            debugLog("[PROFILES] server role changed for \(Self.tag(profileId)): \(p.role?.label ?? "none") -> \(next.label)")
            mutated(profileId, "role")
            refreshActiveRole()
        }
    }

    // MARK: Sync hooks

    /// [stampAt] > 0 stamps the row with that time (a roster add); 0 = now.
    private func mutated(_ profileId: String, _ what: String, _ stampAt: Int64 = 0) {
        guard let p = store.byId(profileId) else { return }
        onProfilesMutated?(p.playlistId, p.username, what, stampAt)
    }

    /// [reason] is launch, switch, addProfile, or foreground. Never blocks.
    func notePickerOpened(_ playlistId: String, _ reason: String) { onPickerOpened?(playlistId, reason) }

    // MARK: PIN

    private var switchTickets = Set<String>()
    private var adminTickets = Set<String>()
    private var pendingPinAdds = Set<String>()
    /// The Admin whose PIN last passed verifyAnyAdminPin (holds a switch ticket).
    private(set) var lastAdminUnlock: String?

    func hasPin(_ profileId: String) -> Bool { pinStore.hasPin(profileId) }
    func pinType(_ profileId: String) -> PinType? { pinStore.type(profileId) }
    func pinLength(_ profileId: String) -> Int? { pinStore.length(profileId) }
    func pinLockSeconds(_ profileId: String) -> Int { pinStore.backoff(profileId).remainingSeconds(Self.nowMs()) }
    func hasSwitchTicket(_ profileId: String) -> Bool { switchTickets.contains(profileId) }
    func isPendingPinAdd(_ profileId: String) -> Bool { pendingPinAdds.contains(profileId) }
    func consumeAdminTicket(_ playlistId: String) -> Bool { adminTickets.remove(playlistId) != nil }

    /// Check [entries] against [profileId]'s PIN, with the wrong-PIN backoff.
    func verifyPin(_ profileId: String, _ entries: [String]) -> PinCheck {
        let now = Self.nowMs()
        let b = pinStore.backoff(profileId)
        let left = b.remainingSeconds(now)
        if left > 0 { return .locked(left) }
        if pinStore.check(profileId, entries) {
            pinStore.saveBackoff(profileId, b.onOk())
            switchTickets.insert(profileId)
            debugLog("[PROFILE] pin ok for \(Self.tag(profileId))")
            return .ok
        }
        let next = b.onWrong(now)
        pinStore.saveBackoff(profileId, next)
        debugLog("[PROFILE] pin wrong for \(Self.tag(profileId))")
        let l = next.remainingSeconds(now)
        return l > 0 ? .locked(l) : .wrong
    }

    /// Launch gate: enter the restored profile's PIN.
    func unlockLaunchGate(_ entries: [String]) -> PinCheck {
        guard let g = launchGate else { return .ok }
        let r = verifyPin(g.id, entries)
        if r == .ok {
            switchTickets.remove(g.id)
            launchGate = nil
        }
        return r
    }

    /// Admin and Standard profiles on [playlistId] that have a PIN.
    func adminPinHolders(_ playlistId: String) -> [DispatcharrProfile] {
        store.forPlaylist(playlistId).filter { RoleRules.isFullAccess($0.effectiveRole) && pinStore.hasPin($0.id) }
    }

    func adminHasPin(_ playlistId: String) -> Bool { !adminPinHolders(playlistId).isEmpty || hasDeviceAdminPin(playlistId) }

    /// Assumption A: Admin and Standard profiles that still need a PIN while a Child exists.
    func pinsMissingForChild(_ playlistId: String, becomingChild: String? = nil) -> [DispatcharrProfile] {
        let actor = activeProfileIdNow(playlistId)
        let all = store.forPlaylist(playlistId)
        let ids = RoleRules.pinsMissingForChild(all.map {
            RoleRules.PinHolder(id: $0.id, role: $0.effectiveRole, hasPin: pinStore.hasPin($0.id), isActor: $0.id == actor)
        }, becomingChild: becomingChild)
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    func needsPinAfterAdd(_ playlistId: String, _ profileId: String) -> Bool {
        anyChild(playlistId) && RoleRules.isFullAccess(roleOf(profileId)) && !pinStore.hasPin(profileId)
    }

    /// The PIN step after an add was cancelled: the add is undone (a Child exists, so a PIN is required).
    /// A roster add goes from this device only, with no tombstone, and is offered again.
    func discardPendingAdds(_ playlistId: String) async {
        let drop = store.forPlaylist(playlistId).filter { pendingPinAdds.contains($0.id) && !pinStore.hasPin($0.id) && !$0.isDefault }
        for p in drop {
            pendingPinAdds.remove(p.id)
            let roster = rosterAddIds.contains(p.id)
            await deleteLocal(p, fromSync: false, tombstone: ProfileRoster.undoWritesTombstone(rosterAdd: roster, plainWrites: true))
            rosterAddIds.remove(p.id)
            freshUndoable.remove(p.id)
            undoableRosterAdds.remove(p.id)
            debugLog("[PROFILE] add of \(Self.tag(p.id)) undone: no PIN while a Child exists\(roster ? " (roster add: this device only)" : "")")
        }
    }

    // Device Admin PIN (device-local, never synced).
    func deviceAdminPinId(_ playlistId: String) -> String { DevicePin.id(playlistId) }
    func hasDeviceAdminPin(_ playlistId: String) -> Bool { pinStore.hasPin(deviceAdminPinId(playlistId)) }
    func deviceAdminPinType(_ playlistId: String) -> PinType? { pinStore.type(deviceAdminPinId(playlistId)) }

    /// Every Admin PIN id that passes "Enter an Admin PIN": Admin profiles, then the device PIN.
    func adminPinIds(_ playlistId: String) -> [String] {
        adminPinHolders(playlistId).map(\.id) + (hasDeviceAdminPin(playlistId) ? [deviceAdminPinId(playlistId)] : [])
    }

    func setDeviceAdminPin(_ playlistId: String, _ type: PinType, _ entries: [String], current: [String]?, onboarding: Bool = false) throws {
        let id = deviceAdminPinId(playlistId)
        if pinStore.hasPin(id) {
            guard verifyPin(id, current ?? []) == .ok else { throw fail("Wrong PIN") }
        } else if !(onboarding || RoleRules.isFullAccess(activeRole(playlistId))) {
            throw fail("Only an Admin or Standard profile can set the Device Admin PIN.")
        }
        guard pinStore.set(id, type, entries) else { throw fail("Enter 4 to 6") }
        debugLog("[PROFILE] device admin pin set on \(Self.tag(playlistId))")
    }

    /// Nil = removable; otherwise why the device PIN must stay.
    func deviceAdminPinRemovalBlock(_ playlistId: String) -> String? {
        RoleRules.canRemoveDevicePin(childExists: anyChild(playlistId), otherPins: adminPinHolders(playlistId).count) ? nil
            : "This is the last PIN that can leave a Child profile, so it stays while any profile is a Child."
    }

    func removeDeviceAdminPin(_ playlistId: String, current: [String]) throws {
        let id = deviceAdminPinId(playlistId)
        if let b = deviceAdminPinRemovalBlock(playlistId) { throw fail(b) }
        guard verifyPin(id, current) == .ok else { throw fail("Wrong PIN") }
        pinStore.remove(id)
        debugLog("[PROFILE] device admin pin removed on \(Self.tag(playlistId))")
    }

    /// Onboarding "Who is this profile for?" shows only for a Standard server login
    /// (Android ProfileRoleStepViewModel.isStandardUser): read live from /me/.
    func baseIsStandardUser(_ playlistId: String) async -> Bool {
        guard let server = DsyncLocal.server(playlistId), let me = await fetchMe(server, server.baseApiKey) else { return false }
        noteDefaultUsersMe(playlistId, userId: me.id, username: me.username)
        let admin = me.effectiveUserLevel >= 10 || me.isStaff || me.isSuperuser
        debugLog("[PROFILE] onboarding role step: level=\(me.effectiveUserLevel) admin=\(admin)")
        return !admin
    }

    /// Onboarding "Who is this profile for?" = Child, once a Device Admin PIN exists.
    func makeBaseChild(_ playlistId: String) throws {
        guard hasDeviceAdminPin(playlistId) else { throw fail("Set a Device Admin PIN first.") }
        guard let base = store.forPlaylist(playlistId).first(where: \.isDefault) else { throw fail("Profile not found") }
        guard !ProfileRole.isServerAdmin(base.userLevel) else { throw fail(RoleRules.SERVER_ADMIN_STAYS) }
        store.update(base.id) { var c = $0; c.role = .child; return c }
        refreshActiveRole()
        debugLog("[PROFILE] onboarding: \(Self.tag(base.id)) is a Child; device admin pin holds Admin")
    }

    /// "Enter a PIN from an Admin or Standard profile": any full-access PIN (or the Device Admin PIN) passes.
    func verifyAnyAdminPin(_ playlistId: String, _ entries: [String]) -> PinCheck {
        let holders = adminPinIds(playlistId)
        guard !holders.isEmpty else { return .wrong }
        let device = deviceAdminPinId(playlistId)
        let now = Self.nowMs()
        var minLock = Int.max
        var tried = false
        for h in holders {
            let b = pinStore.backoff(h)
            let left = b.remainingSeconds(now)
            if left > 0 { minLock = min(minLock, left); continue }
            tried = true
            if pinStore.check(h, entries) {
                pinStore.saveBackoff(h, b.onOk())
                adminTickets.insert(playlistId)
                if h != device {
                    switchTickets.insert(h)
                    lastAdminUnlock = h
                }
                debugLog("[PROFILE] pin ok for \(h == device ? "device admin" : Self.tag(h))")
                return .ok
            }
        }
        // Count the miss against every Admin that was tried.
        var lock = Int.max
        for h in holders {
            let b = pinStore.backoff(h)
            if b.remainingSeconds(now) > 0 { continue }
            let next = b.onWrong(now)
            pinStore.saveBackoff(h, next)
            let l = next.remainingSeconds(now)
            if l > 0 { lock = min(lock, l) }
            debugLog("[PROFILE] pin wrong for \(h == device ? "device admin" : Self.tag(h))")
        }
        if !tried { return .locked(minLock) }
        let anyOpen = holders.contains { pinStore.backoff($0).remainingSeconds(now) == 0 }
        return anyOpen ? .wrong : .locked(min(lock, minLock))
    }

    /// An Admin or Standard profile may manage any profile's PIN; a Child only its own.
    func canManagePin(_ playlistId: String, _ profileId: String) -> Bool {
        RoleRules.isFullAccess(activeRole(playlistId)) || activeProfileIdNow(playlistId) == profileId
            || (pendingPinAdds.contains(profileId) && !pinStore.hasPin(profileId))
    }

    /// Changing or removing ANY PIN needs that profile's existing PIN (phase 2b).
    func needsCurrentPin(_ playlistId: String, _ profileId: String) -> Bool { pinStore.hasPin(profileId) }

    /// Nil = removable; otherwise why the PIN must stay (assumption A: a Child exists).
    func pinRemovalBlock(_ playlistId: String, _ profileId: String) -> String? {
        guard let role = roleOf(profileId) else { return nil }
        return RoleRules.canRemovePin(role, childExists: anyChild(playlistId)) ? nil : RoleRules.KEEP_PIN_REASON
    }

    func resetGate(_ playlistId: String) -> RoleRules.ResetGate {
        let actor = activeProfile(playlistId)
        return RoleRules.resetGate(actor: activeRole(playlistId), actorHasPin: actor.map { pinStore.hasPin($0.id) } ?? false,
                                   childExists: anyChild(playlistId))
    }

    func resetPin(_ playlistId: String, _ profileId: String, adminEntries: [String]?, replacement: (PinType, [String])? = nil) throws {
        guard let actor = activeProfile(playlistId) else { throw fail("Profile not found") }
        guard actor.id != profileId else { throw fail("Use Remove PIN for this profile.") }
        if let keep = pinRemovalBlock(playlistId, profileId), replacement == nil { throw fail(keep) }
        switch resetGate(playlistId) {
        case .denied(let r): throw fail(r)
        case .enterOwnPin:
            guard verifyPin(actor.id, adminEntries ?? []) == .ok else { throw fail("Wrong PIN") }
            switchTickets.remove(actor.id)
        case .confirmOnly: break
        }
        if let (type, entries) = replacement {
            guard pinStore.set(profileId, type, entries) else { throw fail("Enter 4 to 6") }
            mutated(profileId, "pin reset")
            debugLog("[PROFILE] pin reset to a temporary pin for \(Self.tag(profileId))")
        } else {
            pinStore.remove(profileId)
            mutated(profileId, "pin reset")
            debugLog("[PROFILE] pin removed for \(Self.tag(profileId))")
        }
    }

    func setPin(_ playlistId: String, _ profileId: String, _ type: PinType, _ entries: [String], current: [String]?) throws {
        guard canManagePin(playlistId, profileId) else { throw fail("Only an Admin or Standard profile can change another profile's PIN.") }
        let had = pinStore.hasPin(profileId)
        if needsCurrentPin(playlistId, profileId) {
            guard verifyPin(profileId, current ?? []) == .ok else { throw fail("Wrong PIN") }
            switchTickets.remove(profileId)
        }
        guard pinStore.set(profileId, type, entries) else { throw fail("Enter 4 to 6") }
        pendingPinAdds.remove(profileId)
        mutated(profileId, "pin set")
        debugLog("[PROFILE] pin \(had ? "changed" : "set") for \(Self.tag(profileId))")
    }

    func removePin(_ playlistId: String, _ profileId: String, current: [String]?) throws {
        guard canManagePin(playlistId, profileId) else { throw fail("Only an Admin or Standard profile can remove another profile's PIN.") }
        if let b = pinRemovalBlock(playlistId, profileId) { throw fail(b) }
        if needsCurrentPin(playlistId, profileId) {
            guard verifyPin(profileId, current ?? []) == .ok else { throw fail("Wrong PIN") }
            switchTickets.remove(profileId)
        }
        pinStore.remove(profileId)
        mutated(profileId, "pin removed")
        debugLog("[PROFILE] pin removed for \(Self.tag(profileId))")
    }

    // MARK: Roles

    /// Pure decision for the UI: what setting [profileId] to [to] needs.
    func roleChangeGate(_ playlistId: String, _ profileId: String, to: ProfileRole) -> RoleRules.RoleChange {
        guard let target = store.byId(profileId) else { return .denied("Profile not found") }
        let full = store.forPlaylist(playlistId).filter { RoleRules.isFullAccess($0.effectiveRole) }.count
        return RoleRules.roleChange(actor: activeRole(playlistId), from: target.effectiveRole, to: to,
                                    missingPins: pinsMissingForChild(playlistId, becomingChild: profileId).count,
                                    anyPinExists: adminPinIds(playlistId).contains { $0 != profileId },
                                    targetIsLastFullAccess: RoleRules.isFullAccess(target.effectiveRole) && full <= 1,
                                    targetIsServerAdmin: ProfileRole.isServerAdmin(target.userLevel))
    }

    /// Set [profileId]'s role. Leaving Child needs a PIN ticket (verifyAnyAdminPin).
    func setRole(_ playlistId: String, _ profileId: String, to: ProfileRole) throws {
        guard let target = store.byId(profileId) else { throw fail("Profile not found") }
        switch roleChangeGate(playlistId, profileId, to: to) {
        case .denied(let r): throw fail(r)
        case .needsPinsCreated: throw fail(RoleRules.KEEP_PIN_REASON)
        case .needsPinEntry: guard consumeAdminTicket(playlistId) else { throw fail("Enter a PIN from an Admin or Standard profile") }
        case .allowed: break
        }
        store.update(profileId) { var c = $0; c.role = to; return c }
        mutated(profileId, "role")
        refreshActiveRole()
        debugLog("[PROFILE] role \(target.effectiveRole.label) -> \(to.label) for \(Self.tag(profileId))")
    }

    // MARK: Add

    /// The TV picker's Add Profile: an Admin PIN unlocks adding for one dialog, whoever is active.
    var pickerAddUnlocked: String?

    private func canAdd(_ playlistId: String) -> Bool {
        RoleRules.canManageProfiles(activeRole(playlistId)) || pickerAddUnlocked == playlistId
    }

    enum AddCandidates { case serverList([DispatcharrUserSummary]), manual }

    /// Add Profile entry: a server admin gets the users list; anyone else, or a 403, gets the manual form.
    func addCandidates(_ playlistId: String) async throws -> AddCandidates {
        guard canAdd(playlistId) else { throw fail("Only an Admin or Standard profile can add profiles.") }
        let serverAdmin = baseIsServerAdmin(playlistId) && activeIsAdmin(playlistId)
        if RoleRules.addPath(baseIsServerAdmin: serverAdmin, usersListForbidden: false) == .manual { return .manual }
        do {
            return .serverList(try await listServerUsers(playlistId))
        } catch {
            let m = error.localizedDescription
            if m.contains("HTTP 403") || m.contains("HTTP 401") { return .manual }
            throw error
        }
    }

    /// Add Profile step 1: the server's users, fetched with the admin key.
    func listServerUsers(_ playlistId: String) async throws -> [DispatcharrUserSummary] {
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        guard canAdd(playlistId) else { throw fail("Only an Admin or Standard profile can add profiles.") }
        guard activeIsAdmin(playlistId) else { throw fail("Only a Dispatcharr admin can list server users.") }
        let taken = Set(store.forPlaylist(playlistId).map(\.username))
        return try await baseApi(server).listUsers().filter { !taken.contains($0.username) }
            .sorted { $0.username.lowercased() < $1.username.lowercased() }
    }

    /// Enable API access is offered: the base login is a server admin and the active profile is an Admin.
    func canManageUserApiKeys(_ playlistId: String) -> Bool { baseIsServerAdmin(playlistId) && activeIsAdmin(playlistId) }

    /// Mint a key for server user [userId] with the base admin key. Returns the raw key (never logged).
    func generateUserApiKey(_ playlistId: String, userId: Int) async throws -> String {
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        guard canManageUserApiKeys(playlistId) else { throw fail("Only a Dispatcharr admin can enable API access.") }
        return try await baseApi(server).generateUserApiKey(userId: userId)
    }

    /// Clear server user [userId]'s key with the base admin key.
    func revokeUserApiKey(_ playlistId: String, userId: Int) async throws {
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        guard canManageUserApiKeys(playlistId) else { throw fail("Only a Dispatcharr admin can revoke API access.") }
        try await baseApi(server).revokeUserApiKey(userId: userId)
    }

    /// Manual add (non-admin base): [username] signs in with [password] or [apiKey].
    /// A user the synced roster offers finishes as a roster add (its row and stamp kept).
    func addProfileManual(_ playlistId: String, username: String, password: String?, apiKey: String?, role: ProfileRole? = nil) async throws -> DispatcharrProfile {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw fail("Enter a username.") }
        if store.forPlaylist(playlistId).contains(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }) {
            throw fail("\(name) already has a profile.")
        }
        let user = DispatcharrUserSummary(id: 0, username: name)
        if let row = rosterRowForManualAdd(playlistId, name) {
            return try await addFromRoster(playlistId, row: row, user: user, password: password, apiKey: apiKey)
        }
        return try await addProfile(playlistId, user: user, password: password, apiKey: apiKey, role: role)
    }

    /// The synced roster row a manual add must finish with (ProfileRoster.rowForManualAdd).
    private func rosterRowForManualAdd(_ playlistId: String, _ username: String) -> ProfileRow? {
        // A paused roster (a held profile) is not used: its rows may be another server's.
        guard !rosterSyncPaused(playlistId) else { return nil }
        let row = ProfileRoster.rowForManualAdd(username, rows: rosterRows[playlistId] ?? [],
                                                localUsernames: store.forPlaylist(playlistId).map(\.username))
        if row != nil { debugLog("[DSYNC] profiles: manual add of a roster user; finishing it as a roster add (row kept)") }
        return row
    }

    /// Manual add by API key only: /me/ with [apiKey] names the user. A user the
    /// synced roster offers finishes as a roster add (its row and stamp kept).
    func addProfileByApiKey(_ playlistId: String, apiKey: String, role: ProfileRole? = nil) async throws -> DispatcharrProfile {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw fail("Enter an API key.") }
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        guard let me = await fetchMe(server, key) else { throw fail("This API key was not accepted by the server.") }
        if store.forPlaylist(playlistId).contains(where: { $0.username.caseInsensitiveCompare(me.username) == .orderedSame }) {
            throw fail("\(me.username) already has a profile.")
        }
        let user = DispatcharrUserSummary(id: me.id, username: me.username, userLevel: me.userLevel,
                                          isSuperuser: me.isSuperuser, isStaff: me.isStaff)
        if let row = rosterRowForManualAdd(playlistId, me.username) {
            return try await addFromRoster(playlistId, row: row, user: user, password: nil, apiKey: key)
        }
        return try await addProfile(playlistId, user: user, password: nil, apiKey: key, role: role)
    }

    /// Add Profile step 2: validate by signing in as [user] once, then store the credential. Never changes the server.
    func addProfile(_ playlistId: String, user: DispatcharrUserSummary, password: String?, apiKey: String?,
                    role: ProfileRole? = nil, seed: ProfileRow? = nil, id preferredId: String? = nil) async throws -> DispatcharrProfile {
        // Same rule as setRole (assumption A): before a Child is added, every Admin and Standard profile holds a PIN.
        if role == .child, !(adminHasPin(playlistId) && pinsMissingForChild(playlistId).isEmpty) { throw fail(RoleRules.KEEP_PIN_REASON) }
        guard canAdd(playlistId) else { throw fail("Only an Admin or Standard profile can add profiles.") }
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        // A setup handoff passes the sender's profile id (kept when free here).
        let id = preferredId.flatMap { store.byId($0) == nil ? $0 : nil } ?? UUID().uuidString
        // The admin users list carries each user's api_key: use it directly,
        // and only fall back to a typed password or key when the server has none.
        let listed = user.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        let typedNone = (password?.isEmpty ?? true) && (apiKey?.isEmpty ?? true)
        let auth = try await authenticate(server, username: user.username, password: typedNone ? nil : password,
                                          apiKey: typedNone ? listed : apiKey)
        guard auth.me.username.caseInsensitiveCompare(user.username) == .orderedSame else {
            throw fail("This API key belongs to \(auth.me.username), not \(user.username).")
        }
        var profile = applyMe(DispatcharrProfile(id: id, playlistId: playlistId, displayName: user.username, username: auth.me.username), auth.me)
        profile.createdAt = Self.nowMs()
        profile.role = ProfileRole.resolve(profile.userLevel, role)
        // A roster add: name, role, avatar, order, and user id land in the FIRST store write.
        if let seed { profile = ProfileRoster.applyRow(profile, seed) }
        // Credentials first, so the profile never exists without its key.
        store.setApiKey(id, auth.key)
        store.setPassword(id, password)
        store.upsert(profile)
        if needsPinAfterAdd(playlistId, id) { pendingPinAdds.insert(id) }
        settings.seed(id, source: defaultProfileSettings(playlistId))
        if let seed {
            if let type = PinRules.typeFromWire(seed.pinType), seed.pinHash.count == 64, seed.pinSalt.count == 32 {
                pinStore.importSynced(id, type, hash: seed.pinHash, salt: seed.pinSalt)
            }
            // Keep the row's own stamp: the server row stays authoritative for every field this device did not change.
            mutated(id, "roster-add", seed.updatedAt)
        } else {
            // The roster is paused (a held profile): the first pull after the pause checks it against the roster.
            if rosterSyncPaused(playlistId) { holds.markAddedDuringPause(id) }
            mutated(id, "add")
        }
        debugLog("[PROFILE] added \(Self.tag(id)) on \(Self.tag(playlistId)) level=\(ProfileLevel.of(profile.userLevel).rawValue) role=\(profile.effectiveRole.label)")
        await tagSignIn(id, server)
        return store.byId(id) ?? profile
    }

    /// The default profile's settings: live when it is active, else its saved slot.
    private func defaultProfileSettings(_ playlistId: String) -> [String: Any] {
        guard let def = store.forPlaylist(playlistId).first(where: \.isDefault) else { return settings.capture() }
        if activeProfileIdNow(playlistId) == def.id { return settings.capture() }
        return settings.slot(def.id) ?? settings.capture()
    }

    // MARK: Roster (Dispatcharr Sync `profiles` key)

    private var rosterRows: [String: [ProfileRow]] = [:]
    private var freshUndoable = Set<String>()
    /// Profiles added from the synced roster in this run (addFromRoster, including a
    /// manual add of a roster user): undoing one never writes a tombstone.
    private var rosterAddIds = Set<String>()

    /// Merge a pulled `profiles` list PER ROW (schema 4.12). The roster is a
    /// catalog: a row with no local profile is never added here (it is offered
    /// in rosterSuggestions and added only by addFromRoster). Returns 0 (opt-in only).
    @discardableResult
    func mergeSyncedProfiles(_ playlistId: String, _ rows: [ProfileRow],
                             localUpdatedAt: (String) -> Int64 = { _ in 0 },
                             adopted: (String, Int64) -> Void = { _, _ in },
                             removedAt: (String) -> Int64 = { _ in 0 },
                             customized: (String, String, AvatarSpec?) -> Bool = { _, _, _ in true }) -> Int {
        rosterRows[playlistId] = rows
        publish()
        let plan = ProfileRoster.plan(rows, store.forPlaylist(playlistId).map(\.username))
        debugLog("[DSYNC] profiles: \(plan.available.count) roster rows available, not added (opt-in)")
        guard RoleRules.canWriteProfilesKey(activeRole(playlistId)) else { return 0 }
        adoptRowsForPauseAdds(playlistId, rows, adopted: adopted)
        for r in plan.merge {
            guard var local = store.forPlaylist(playlistId).first(where: { $0.username.caseInsensitiveCompare(r.username) == .orderedSame }) else { continue }
            let id = local.id
            debugLog("[DSYNC] profiles: row \(Self.tag(id)) updatedAt=\(r.updatedAt) removedAt=\(removedAt(r.username)) local=yes")
            if local.userId == 0 && r.userId > 0 { store.update(id) { var c = $0; c.userId = r.userId; return c } }
            let mine = localUpdatedAt(local.username)
            // No local claim on name/avatar: the server's name and avatar apply whatever the stamps say.
            if let adopt = ProfileRoster.adoptUncustomized(localName: local.displayName, localAvatar: local.avatar,
                                                           customized: customized(local.username, local.displayName, local.avatar), r) {
                store.update(id) { var c = $0; c.displayName = adopt.0; c.avatar = adopt.1; return c }
                debugLog("[DSYNC] profiles: adopted synced name/avatar for \(Self.tag(id))")
                local = store.byId(id) ?? local
            }
            let repair = ProfileRoster.repair(localName: local.displayName, localAvatar: local.avatar, localAt: mine, r)
            if repair == .resendLocal {
                debugLog("[DSYNC] profiles: server row \(Self.tag(id)) looks stripped; re-sending local")
                mutated(id, "repair")
                continue
            }
            if repair == .applyServer {
                debugLog("[DSYNC] profiles: local row \(Self.tag(id)) is stripped; applying server name/avatar")
            } else if !DsyncGate.profileRowWins(localUpdatedAt: mine, remote: r) {
                debugLog("[DSYNC] profiles: keep local row for \(Self.tag(id)) (local \(mine) >= server \(r.updatedAt))")
                continue
            }
            if !r.displayName.trimmingCharacters(in: .whitespaces).isEmpty && r.displayName != local.displayName {
                store.update(id) { var c = $0; c.displayName = r.displayName; return c }
            }
            if let role = ProfileRole.fromWire(r.role).map({ ProfileRole.resolve(local.userLevel, $0) }),
               role != local.effectiveRole || local.role == nil {
                store.update(id) { var c = $0; c.role = role; return c }
                debugLog("[DSYNC] profiles: role \(role.label) for \(Self.tag(id))")
            }
            // Absent order (older writer, -1) keeps the local position.
            if r.order >= 0 && r.order != local.order {
                store.update(id) { var c = $0; c.order = r.order; return c }
                debugLog("[DSYNC] profiles: order \(r.order) for \(Self.tag(id))")
            }
            // Absent (older writer) keeps the local avatar; {} is a deliberate default.
            if r.avatar != nil {
                let avatar = AvatarCatalog.normalize(r.avatar)
                if avatar != local.avatar {
                    store.update(id) { var c = $0; c.avatar = avatar; return c }
                    debugLog("[DSYNC] profiles: avatar for \(Self.tag(id))")
                }
            }
            if let type = PinRules.typeFromWire(r.pinType) {
                if r.pinHash.count == 64 && r.pinSalt.count == 32 { pinStore.importSynced(id, type, hash: r.pinHash, salt: r.pinSalt) }
            } else if pinStore.hasPin(id) && !pinStore.isLegacy(id) {
                // A v1 PIN set on this device before sync stays until re-entered.
                pinStore.remove(id)
                debugLog("[DSYNC] profiles: pin removed for \(Self.tag(id)) (server row newer)")
            }
            adopted(local.username, r.updatedAt)
        }
        refreshActiveRole()
        return 0
    }

    /// The first pull after a roster pause: a profile added during it takes its
    /// username's roster row, if any, the way a manual add of a roster user
    /// does (row applied, PIN imported, the row's stamp kept). Otherwise it
    /// stays a plain add. Either way its mark is cleared.
    private func adoptRowsForPauseAdds(_ playlistId: String, _ rows: [ProfileRow], adopted: (String, Int64) -> Void) {
        for p in store.forPlaylist(playlistId) where !p.isDefault && holds.addedDuringPause(p.id) {
            holds.clearAddedDuringPause(p.id)
            guard let row = ProfileHostHoldRules.rowAfterPause(p.username, rows: rows) else { continue }
            store.upsert(ProfileRoster.applyRow(p, row))
            if let type = PinRules.typeFromWire(row.pinType), row.pinHash.count == 64, row.pinSalt.count == 32 {
                pinStore.importSynced(p.id, type, hash: row.pinHash, salt: row.pinSalt)
                pendingPinAdds.remove(p.id)
            }
            adopted(p.username, row.updatedAt)
            debugLog("[DSYNC] profiles: \(Self.tag(p.id)) added during the roster pause takes its roster row (row and stamp kept)")
        }
    }

    /// Add a profile from a roster suggestion (an explicit choice).
    func addFromRoster(_ playlistId: String, row: ProfileRow, user: DispatcharrUserSummary, password: String?, apiKey: String?) async throws -> DispatcharrProfile {
        let role = ProfileRole.fromWire(row.role)
        let added = try await addProfile(playlistId, user: user, password: password, apiKey: apiKey, role: role, seed: row)
        refreshActiveRole()
        debugLog("[DSYNC] profiles: added \(Self.tag(added.id)) from the roster (explicit choice) role=\(role?.label ?? "default") order=\(row.order)")
        rosterAddIds.insert(added.id)
        undoableRosterAdds.insert(added.id)
        return store.byId(added.id) ?? added
    }

    /// "Set up from another device" (docs/DeviceSetupHandoff.md, Receiver apply;
    /// Android ProfileManager.applySetupProfile): the default profile takes the
    /// sent name, role, avatar, order, and PIN; any other profile goes through
    /// the roster add path (one sign-in with the sent credential), then its PIN.
    /// One playlist across devices (2026-11-10): a playlist merged into
    /// another hands its profiles over when the winner has none here (the
    /// active choice follows); otherwise the loser's are removed.
    /// The two playlists share the server URL; a different local URL moves
    /// the profiles' sign-ins to another address, so they are held first
    /// (ProfileHostHold), and any hold the loser had goes with them.
    func movePlaylistProfiles(from loser: String, to winner: String,
                              loserRoute: (base: String, local: String), winnerRoute: (base: String, local: String)) {
        guard loser != winner else { return }
        let mine = store.forPlaylist(loser)
        guard !mine.isEmpty else { return }
        if store.forPlaylist(winner).isEmpty {
            if PlaylistRoute.changed(oldBase: loserRoute.base, newBase: winnerRoute.base,
                                     oldLocal: loserRoute.local, newLocal: winnerRoute.local),
               let rec = holds.hold(loser, profileIds: ProfileHostHoldRules.toHold(mine, hasStoredSignIn: signIns.hasStored),
                                    trustedHosts: PlaylistRoute.hosts(base: loserRoute.base, local: loserRoute.local),
                                    route: PlaylistRoute.key(base: winnerRoute.base, local: winnerRoute.local)) {
                debugLog("[PROFILE-HOST] hold playlist=\(Self.tag(winner)) profiles=\(rec.profileIds.count)")
                onSignInsHeld?(loser, Set(rec.profileIds))
            }
            holds.move(from: loser, to: winner)
            for p in mine { store.update(p.id) { var c = $0; c.playlistId = winner; return c } }
            if let a = store.activeProfileId(loser) { store.setActiveProfileId(winner, a) }
        } else {
            store.removeForPlaylist(loser)
            holds.drop(loser)
        }
        store.setActiveProfileId(loser, nil)
        publish()
        if holds.record(winner) != nil {
            Task {
                await self.leaveHeldProfile(winner)
                await self.recheckHostHold(winner)
            }
        }
    }

    func applySetupProfile(_ playlistId: String, row: ProfileRow, isDefault: Bool, password: String?, apiKey: String?,
                           profileId: String? = nil) async throws {
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        await ensureDefaultProfile(server, preferredId: isDefault ? profileId : nil)
        let id: String
        if isDefault {
            guard let base = store.forPlaylist(playlistId).first(where: \.isDefault) else { throw fail("Profile not found") }
            store.update(base.id) { ProfileRoster.applyRow($0, row) }
            id = base.id
        } else if let existing = store.forPlaylist(playlistId).first(where: { $0.username.caseInsensitiveCompare(row.username) == .orderedSame }) {
            store.update(existing.id) { ProfileRoster.applyRow($0, row) }
            id = existing.id
        } else {
            let added = try await addProfile(playlistId, user: DispatcharrUserSummary(id: 0, username: row.username),
                                             password: password, apiKey: apiKey, role: ProfileRole.fromWire(row.role), seed: row,
                                             id: profileId)
            id = added.id
        }
        if let type = PinRules.typeFromWire(row.pinType), row.pinHash.count == 64, !row.pinSalt.isEmpty {
            pinStore.importSynced(id, type, hash: row.pinHash, salt: row.pinSalt)
            pendingPinAdds.remove(id)
        }
        refreshActiveRole()
        publish()
        debugLog("[SETUP] profile applied \(Self.tag(id)) default=\(isDefault)")
    }

    /// Save a sign-in for an existing profile that has none here (validated by one sign-in).
    func saveSignIn(_ playlistId: String, profileId: String, password: String?, apiKey: String?) async throws {
        guard let server = DsyncLocal.server(playlistId), let p = store.byId(profileId) else { throw fail("Profile not found") }
        let auth = try await authenticate(server, username: p.username, password: password, apiKey: apiKey)
        guard auth.me.username.caseInsensitiveCompare(p.username) == .orderedSame else {
            throw fail("This API key belongs to \(auth.me.username), not \(p.username).")
        }
        store.setApiKey(profileId, auth.key)
        store.setPassword(profileId, password)
        // Typed at the playlist's current address: a held sign-in is replaced.
        if holds.lift(profileId: profileId) {
            debugLog("[PROFILE-HOST] lifted playlist=\(Self.tag(playlistId)) profile=\(Self.tag(profileId)) (signed in)")
        }
        publish()
        await tagSignIn(profileId, server)
        debugLog("[PROFILE] sign-in saved for \(Self.tag(profileId))")
    }

    /// Onboarding manual add: the profile just created here may be removed (its undo writes the tombstone).
    func markFreshAddUndoable(_ profileId: String) {
        // A manual add that finished as a roster add undoes like one: this
        // device only, no tombstone (the row belongs to the other devices).
        if !undoableRosterAdds.contains(profileId) { freshUndoable.insert(profileId) }
        undoableRosterAdds.insert(profileId)
    }

    func canUndoAdd(_ profileId: String) -> Bool { undoableRosterAdds.contains(profileId) }

    /// Undo a roster add: local cleanup on THIS DEVICE ONLY, no Admin PIN, no tombstone.
    func undoAdd(_ profileId: String) async throws {
        guard undoableRosterAdds.contains(profileId) else { throw fail("Only a profile just added here can be undone.") }
        guard let p = store.byId(profileId) else { undoableRosterAdds.remove(profileId); return }
        guard !p.isDefault else { throw fail("The default profile cannot be removed.") }
        let fresh = freshUndoable.remove(profileId) != nil
        let roster = rosterAddIds.remove(profileId) != nil
        await deleteLocal(p, fromSync: false, tombstone: ProfileRoster.undoWritesTombstone(rosterAdd: roster, plainWrites: fresh))
        undoableRosterAdds.remove(profileId)
        refreshActiveRole()
        debugLog("[PROFILES] undo add \(Self.tag(profileId))")
    }

    // MARK: Channel Profiles per user (Admin only)

    struct ChannelProfileChoice: Equatable, Sendable { let id: Int; let name: String }
    struct ChannelProfileAssignment: Equatable, Sendable { let userId: Int; let choices: [ChannelProfileChoice]; let assigned: Set<Int> }

    /// Channel Profiles are assigned on the server: base and active must be server admins.
    func canAssignChannelProfiles(_ playlistId: String) -> Bool {
        RoleRules.canAssignChannelProfiles(baseIsServerAdmin: baseIsServerAdmin(playlistId),
                                           activeIsServerAdmin: activeIsAdmin(playlistId), active: activeRole(playlistId))
    }

    /// The server's channel profiles and [profileId]'s user's current list (Android channelProfileAssignment).
    func channelProfileAssignment(_ playlistId: String, _ profileId: String) async throws -> ChannelProfileAssignment {
        guard activeIsAdmin(playlistId) else { throw fail("Only a Dispatcharr admin can assign channel profiles.") }
        guard let p = store.byId(profileId) else { throw fail("Profile not found") }
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        let api = baseApi(server)
        guard let user = try await api.listUsers().first(where: { $0.username.caseInsensitiveCompare(p.username) == .orderedSame }) else {
            throw fail("\(p.username) was not found on the server.")
        }
        let choices = try await api.listChannelProfiles().map { ChannelProfileChoice(id: $0.id, name: $0.name) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return ChannelProfileAssignment(userId: user.id, choices: choices, assigned: Set(user.channelProfiles))
    }

    /// PATCH the user's channel_profiles (empty = All). Channels reload when
    /// [profileId] is the active profile (Android saveChannelProfiles).
    func saveChannelProfiles(_ playlistId: String, _ profileId: String, userId: Int, ids: [Int]) async throws {
        guard activeIsAdmin(playlistId) else { throw fail("Only a Dispatcharr admin can assign channel profiles.") }
        guard let p = store.byId(profileId) else { throw fail("Profile not found") }
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        try await baseApi(server).patchUserChannelProfiles(userId: userId, ids: ids)
        let joined = ids.sorted().map(String.init).joined(separator: ",")
        if p.isDefault {
            server.dispatcharrChannelProfileIDs = joined
            try? server.modelContext?.save()
        } else {
            store.update(profileId) { var c = $0; c.accountProfileIds = joined; return c }
            publish()
        }
        debugLog("[PROFILE] channel profiles for \(Self.tag(profileId)) set to \(ids.isEmpty ? "All" : "\(ids.count) profile(s)")")
        if activeProfileIdNow(playlistId) == profileId {
            await ChannelStore.shared.reloadChannelsAndWait(servers: [server])
        }
    }

    // MARK: Edit

    /// Row menu "Avatar". Stamps the synced row like a rename.
    func setAvatar(_ playlistId: String, _ profileId: String, _ avatar: AvatarSpec?) throws {
        guard let target = store.byId(profileId) else { throw fail("Profile not found") }
        let isOwn = activeProfileIdNow(playlistId) == profileId
        guard RoleRules.canEditAvatar(actor: activeRole(playlistId), isOwn: isOwn) else {
            throw fail("Only an Admin or Standard profile can change another profile's avatar.")
        }
        let clean = AvatarCatalog.normalize(avatar)
        if clean == target.avatar { return }
        store.update(profileId) { var c = $0; c.avatar = clean; return c }
        mutated(profileId, "avatar")
        debugLog("[PROFILE] avatar \(clean?.icon ?? AvatarCatalog.INITIAL)/\(clean.map { $0.color.isEmpty ? "default" : $0.color } ?? "default") for \(Self.tag(profileId))")
    }

    func rename(_ profileId: String, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        store.update(profileId) { var c = $0; c.displayName = clean; return c }
        mutated(profileId, "rename")
    }

    /// Admin reorder (Move Left / Move Right / Move to Front, Move Up / Move Down). Returns the new index.
    @discardableResult
    func move(_ playlistId: String, _ profileId: String, _ how: ProfileOrder.Move) throws -> Int {
        guard RoleRules.isFullAccess(activeRole(playlistId)) else { throw fail("Only an Admin or Standard profile can reorder profiles.") }
        let list = store.forPlaylist(playlistId)
        guard let from = list.firstIndex(where: { $0.id == profileId }) else { throw fail("Profile not found") }
        let ids = ProfileOrder.step(list.map(\.id), profileId, how)
        let to = ids.firstIndex(of: profileId) ?? from
        if to == from && list.allSatisfy({ $0.order >= 0 }) { return from }
        let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        commitOrder(playlistId, ids.compactMap { byId[$0] })
        debugLog("[PROFILE] moved \(Self.tag(profileId)) \(from) -> \(to) on \(Self.tag(playlistId))")
        return to
    }

    /// Admin reorder with the FULL new order. True when anything was written.
    @discardableResult
    func setOrder(_ playlistId: String, _ orderedIds: [String]) throws -> Bool {
        guard RoleRules.isFullAccess(activeRole(playlistId)) else { throw fail("Only an Admin or Standard profile can reorder profiles.") }
        let current = store.forPlaylist(playlistId)
        let ids = ProfileOrder.resolve(current.map(\.id), orderedIds)
        if ids == current.map(\.id) && current.allSatisfy({ $0.order >= 0 }) { return false }
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        commitOrder(playlistId, ids.compactMap { byId[$0] })
        debugLog("[PROFILE] set order n=\(ids.count) on \(Self.tag(playlistId))")
        return true
    }

    /// Persist [list] as the playlist's order and stamp every row whose position changed.
    private func commitOrder(_ playlistId: String, _ list: [DispatcharrProfile]) {
        let before = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.order) })
        store.setOrder(playlistId, list.map(\.id))
        for (i, q) in list.enumerated() where before[q.id] != i { mutated(q.id, "order") }
    }

    // MARK: Remove

    /// Remove a profile and its local state on this device. Never touches the
    /// server user. The default profile cannot be removed.
    func remove(_ profileId: String) async throws {
        guard let p = store.byId(profileId) else { return }
        guard !p.isDefault else { throw fail("The default profile cannot be removed.") }
        guard RoleRules.isFullAccess(activeRole(p.playlistId)) else { throw fail("Only an Admin or Standard profile can remove profiles.") }
        if RoleRules.removeNeedsPin(p.effectiveRole) {
            guard consumeAdminTicket(p.playlistId) else { throw fail("Enter a PIN from an Admin or Standard profile") }
        }
        // A held profile (server address change) goes from this device only, with no tombstone.
        let held = holds.isHeld(p.id)
        await deleteLocal(p, fromSync: false, tombstone: ProfileHostHoldRules.removeWritesTombstone(isHeld: held))
        if held { debugLog("[PROFILE-HOST] lifted playlist=\(Self.tag(p.playlistId)) profile=\(Self.tag(p.id)) (removed; this device only)") }
    }

    /// A synced removal tombstone beat this local profile: the same cleanup, no PIN, no new tombstone.
    func removeFromSync(_ playlistId: String, _ username: String) async -> Bool {
        guard let p = store.forPlaylist(playlistId).first(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame }),
              !p.isDefault, RoleRules.canWriteProfilesKey(activeRole(playlistId)) else { return false }
        await deleteLocal(p, fromSync: true)
        return true
    }

    private func deleteLocal(_ p: DispatcharrProfile, fromSync: Bool, tombstone: Bool? = nil) async {
        let tomb = tombstone ?? !fromSync
        if store.activeProfileId(p.playlistId) == p.id, let def = store.forPlaylist(p.playlistId).first(where: \.isDefault) {
            // The Admin removing the active profile: internal, no PIN prompt.
            try? await switchTo(p.playlistId, def.id, bypassPin: true)
        }
        pinStore.remove(p.id)
        settings.deleteScope(p.id)
        data.deleteScope(p.id)
        holds.forgetProfile(p.id)
        if tomb { onProfilesMutated?(p.playlistId, p.username, "remove", 0) }
        else if !fromSync { onProfilesMutated?(p.playlistId, p.username, "undo-add", 0) }
        store.remove(p.id)
        debugLog("[PROFILE] removed \(Self.tag(p.id)) on \(Self.tag(p.playlistId)); local state deleted\(fromSync ? " (synced removal)" : "")")
    }

    // MARK: Server address change (profile sign-ins, review finding A-APP-1)

    /// Every outbound read of a non-default profile's sign-in: nil while held.
    var signIns: ProfileSignIns { ProfileSignIns(store: store, holds: holds) }

    /// True while [profileId]'s sign-in is held after its playlist's server
    /// address changed: picking it opens the sign-in form first.
    func isHeld(_ profileId: String) -> Bool { holds.isHeld(profileId) }

    /// A successful users/me with the DEFAULT profile's sign-in for
    /// [playlistId]: record who answered (frozen while anything on the
    /// playlist is held), and run the same-server check again when it has a hold.
    func noteDefaultUsersMe(_ playlistId: String, userId: Int, username: String) {
        if let id = DefaultIdentity(userId: userId, username: username), holds.recordIdentity(playlistId, id) {
            // Profiles from before this release are tagged the first time there is a record.
            holds.backfillTags(playlistId, profileIds: store.forPlaylist(playlistId).filter { !$0.isDefault }.map(\.id))
        }
        guard holds.record(playlistId) != nil else { return }
        Task { await self.recheckHostHold(playlistId) }
    }

    /// A route change of [playlistId] starts (before its own validation
    /// users/me) or ends: in between, nothing users/me answers is recorded,
    /// so the snapshot is the record from before the change.
    func beginRouteChange(_ playlistId: String) { holds.beginChange(playlistId) }
    func endRouteChange(_ playlistId: String) { holds.endChange(playlistId) }

    /// [profileId] signed in or was verified at the playlist's current
    /// address: tag it with the default account users/me answers there now
    /// (live, never the frozen record). Unreadable: the last record when it
    /// is still live (nothing held, no change under way), else unknown.
    private func tagSignIn(_ profileId: String, _ server: ServerConnection) async {
        let pid = server.id.uuidString
        let route = PlaylistRoute.key(base: server.baseURL, local: server.localURL)
        let me = await fetchMe(server, server.baseApiKey)
        guard !server.isGone, PlaylistRoute.key(base: server.baseURL, local: server.localURL) == route,
              store.byId(profileId) != nil, !holds.isHeld(profileId) else { return }
        if let me { noteDefaultUsersMe(pid, userId: me.id, username: me.username) }
        if let live = me.flatMap({ DefaultIdentity(userId: $0.id, username: $0.username) }) {
            holds.setTag(profileId, .identity(live))
        } else if holds.mayRecord(pid), let last = holds.identity(pid) {
            holds.setTag(profileId, .identity(last))
        } else {
            holds.setTag(profileId, .unknown)
        }
    }

    /// Before a new server or local URL is written to [playlistId]: hold every
    /// non-default profile's stored sign-in, then leave a held active profile
    /// for the default one (as removing the active profile does). A path-only
    /// change does nothing. The caller writes the address, then runs
    /// recheckHostHold.
    func routeWillChange(_ playlistId: String, oldBase: String, oldLocal: String, newBase: String, newLocal: String) async {
        guard holdForRouteChange(playlistId, oldBase: oldBase, oldLocal: oldLocal, newBase: newBase, newLocal: newLocal) else { return }
        await leaveHeldProfile(playlistId)
    }

    /// The same for a caller that cannot wait (the iCloud merge): the hold is
    /// in place when this returns; the switch to the default profile and the
    /// same-server check follow once the caller has written the address.
    func routeWillChangeNow(_ playlistId: String, oldBase: String, oldLocal: String, newBase: String, newLocal: String) {
        guard PlaylistRoute.changed(oldBase: oldBase, newBase: newBase, oldLocal: oldLocal, newLocal: newLocal) else { return }
        let leave = holdForRouteChange(playlistId, oldBase: oldBase, oldLocal: oldLocal, newBase: newBase, newLocal: newLocal)
        guard holds.record(playlistId) != nil else { return }
        Task {
            if leave { await self.leaveHeldProfile(playlistId) }
            await self.recheckHostHold(playlistId)
        }
    }

    /// Places the hold. True when the active profile is now held.
    private func holdForRouteChange(_ playlistId: String, oldBase: String, oldLocal: String, newBase: String, newLocal: String) -> Bool {
        guard PlaylistRoute.changed(oldBase: oldBase, newBase: newBase, oldLocal: oldLocal, newLocal: newLocal) else { return false }
        let ids = ProfileHostHoldRules.toHold(store.forPlaylist(playlistId), hasStoredSignIn: signIns.hasStored)
        guard let rec = holds.hold(playlistId, profileIds: ids,
                                   trustedHosts: PlaylistRoute.hosts(base: oldBase, local: oldLocal),
                                   route: PlaylistRoute.key(base: newBase, local: newLocal)) else { return false }
        debugLog("[PROFILE-HOST] hold playlist=\(Self.tag(playlistId)) profiles=\(rec.profileIds.count)")
        onSignInsHeld?(playlistId, Set(rec.profileIds))
        // The request overlay drops a held profile at once.
        publish()
        return store.activeProfileId(playlistId).map(holds.isHeld) ?? false
    }

    /// The active profile is held: switch to the default profile first.
    func leaveHeldProfile(_ playlistId: String) async {
        guard let a = store.activeProfileId(playlistId), holds.isHeld(a),
              let def = store.forPlaylist(playlistId).first(where: \.isDefault) else { return }
        // The channel reload only for the playlist on screen (it would load this one in its place).
        let onScreen = DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString == playlistId
        try? await switchTo(playlistId, def.id, bypassPin: true, reload: onScreen)
    }

    private var checking = Set<String>()
    private var checkAgain = Set<String>()

    /// The same-server check: with the DEFAULT profile's sign-in only,
    /// users/me at the new address (through the request gate). The same user
    /// id and username as recorded before the change lifts the hold for every
    /// profile of the playlist; anything else keeps it until the next
    /// successful default users/me. One check per playlist at a time.
    func recheckHostHold(_ playlistId: String) async {
        guard holds.record(playlistId) != nil else { return }
        guard checking.insert(playlistId).inserted else {
            checkAgain.insert(playlistId)
            return
        }
        defer { checking.remove(playlistId) }
        repeat {
            checkAgain.remove(playlistId)
            await sameServerCheck(playlistId)
        } while checkAgain.contains(playlistId) && holds.record(playlistId) != nil
    }

    private func sameServerCheck(_ playlistId: String) async {
        guard let rec = holds.record(playlistId) else { return }
        let tag = Self.tag(playlistId)
        func failed(_ why: String) { debugLog("[PROFILE-HOST] same-server check failed playlist=\(tag) reason=\(why)") }
        guard let server = DsyncLocal.server(playlistId), !server.isGone, server.type == .dispatcharrAPI else {
            failed("no-playlist")
            return
        }
        let route = PlaylistRoute.key(base: server.baseURL, local: server.localURL)
        // A users/me before the new address is written still reaches the old server.
        guard SameServerCheck.ready(holdRoute: rec.route, routeNow: route) else { failed("address-pending"); return }
        guard rec.expected != nil else { failed("no-record"); return }
        let key = server.baseApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { failed("no-default-sign-in"); return }
        let targets = PlaylistRoute.checkTargets(base: server.normalizedBaseURL,
                                                 local: server.localURL.isEmpty ? "" : server.normalizedLocalURL,
                                                 effective: server.effectiveBaseURL, trusted: rec.trustedHosts)
        let ua = server.effectiveUserAgent
        let mode = server.dispatcharrHeaderMode
        var answers: [SameServerCheck.Answer] = []
        for url in targets {
            do {
                let me = try await DispatcharrAPI(baseURL: url, auth: .apiKey(key), userAgent: ua, authMode: mode).fetchCurrentUser()
                answers.append(DefaultIdentity(userId: me.id, username: me.username).map { .user($0) } ?? .failed("error"))
            } catch {
                answers.append(.failed(Self.checkFailure(error)))
            }
        }
        // The address or the hold may have moved while users/me was out.
        guard let now = holds.record(playlistId), now.route == rec.route,
              let live = DsyncLocal.server(playlistId), !live.isGone,
              PlaylistRoute.key(base: live.baseURL, local: live.localURL) == route else {
            failed("address-changed")
            return
        }
        switch SameServerCheck.decide(expected: now.expected, answers: answers) {
        case .lift:
            debugLog("[PROFILE-HOST] same-server check passed playlist=\(tag)")
            // Only profiles that signed in where this account answered before the change.
            let r = holds.liftMatching(playlistId)
            debugLog("[PROFILE-HOST] lifted playlist=\(tag) profiles=\(r.lifted.count) kept=\(r.kept.count) (same server)")
            publish()
        case .keep(let why):
            failed(why)
        }
    }

    /// A fixed reason for the log; never the error text (it can carry a URL).
    private static func checkFailure(_ error: Error) -> String {
        if DispatcharrHTTPGate.rateLimit(in: error) != nil { return "rate-limited" }
        if case DispatcharrGateError.keyRejected? = error as? DispatcharrGateError { return "rejected" }
        if error is URLError { return "network" }
        if case DispatcharrDirectConnectError.transport(let m)? = error as? DispatcharrDirectConnectError {
            if m.contains("HTTP 401") || m.contains("HTTP 403") { return "rejected" }
            return m.contains("HTTP ") ? "error" : "network"
        }
        return "error"
    }

    /// The sign-in form signed a held profile in at the playlist's current
    /// address: its key and password are replaced, only its hold lifts, and
    /// it is tagged with the default account there.
    func completeHeldSignIn(_ profileId: String, apiKey: String, password: String) async {
        store.setApiKey(profileId, apiKey)
        store.setPassword(profileId, password)
        guard let p = store.byId(profileId) else { return }
        if holds.lift(profileId: profileId) {
            debugLog("[PROFILE-HOST] lifted playlist=\(Self.tag(p.playlistId)) profile=\(Self.tag(profileId)) (signed in)")
        }
        publish()
        if let server = DsyncLocal.server(p.playlistId) { await tagSignIn(profileId, server) }
    }

    /// The playlist was deleted: its hold and recorded identity go with it.
    func playlistDeleted(_ playlistId: String) {
        holds.forgetPlaylist(playlistId)
        publish()
    }

    // MARK: Switch

    /// The UI entry for a switch: PIN prompt policy, then the stop-playback confirm, then switchTo.
    /// Returns false when it stopped for the PIN pad or the user kept playing.
    func requestSwitch(_ playlistId: String, _ profileId: String) async throws -> Bool {
        if pinStore.hasPin(profileId) && !switchTickets.contains(profileId) {
            pendingPinPrompt = PinPrompt(playlistId: playlistId, profileId: profileId)
            return false
        }
        if profileId != activeProfileIdNow(playlistId), isPlaying(), let confirm = confirmStopPlayback {
            guard await confirm() else { return false }
        }
        try await switchTo(playlistId, profileId)
        return true
    }

    /// Picker choice at launch. A locked profile has already passed verifyPin (its ticket).
    func pickAtLaunch(_ profileId: String) async throws {
        guard let pk = launchPicker else { return }
        if pinStore.hasPin(profileId) && !switchTickets.contains(profileId) { throw fail("Enter PIN") }
        if profileId == activeProfileIdNow(pk.playlistId) {
            switchTickets.remove(profileId)
            launchPicker = nil
            debugLog("[PROFILE] launch picker: kept \(Self.tag(profileId))")
            return
        }
        debugLog("[PROFILE] launch picker: chose \(Self.tag(profileId))")
        try await switchTo(pk.playlistId, profileId)
        launchPicker = nil
    }

    func askAtLaunch(_ playlistId: String) -> Bool { store.askAtLaunch(playlistId) }
    func setAskAtLaunch(_ playlistId: String, _ on: Bool) {
        store.setAskAtLaunch(playlistId, on)
        debugLog("[PROFILE] ask who is watching at launch = \(on)")
    }

    /// Switch [playlistId] to [profileId]. The caller already confirmed stopping
    /// playback. Signs in as the profile (stored key first, then the password),
    /// re-reads permissions, swaps the settings, and hands the switch to
    /// Dispatcharr Sync and the reload (onSwitched). [reload] false skips the
    /// channel reload (leaving a held profile on a playlist that is not on screen).
    func switchTo(_ playlistId: String, _ profileId: String, bypassPin: Bool = false, reload: Bool = true) async throws {
        if !bypassPin && pinStore.hasPin(profileId) {
            guard switchTickets.remove(profileId) != nil else { throw fail("Enter PIN") }
        }
        guard let target = store.byId(profileId) else { throw fail("Profile not found") }
        guard let server = DsyncLocal.server(playlistId) else { throw fail("Playlist not found") }
        // Held after a server address change: the sign-in form comes first (the UI opens it).
        if !target.isDefault && holds.isHeld(profileId) { throw fail(KeySignInCopy.hostChanged(playlistName: server.name)) }
        let from = activeProfile(playlistId)
        switching = true
        defer { switching = false }
        let t0 = Self.nowMs()
        // The outgoing profile's pending sync changes go first (Android flushes the old session).
        await beforeSwitch?(playlistId)
        if target.isDefault {
            if let me = await fetchMe(server, server.baseApiKey) {
                store.update(target.id) { var c = $0; c.userId = me.id; return c }
                followServerRole(target.id, me.effectiveUserLevel)
                noteDefaultUsersMe(playlistId, userId: me.id, username: me.username)
            }
        } else {
            let a = try await authenticate(server, username: target.username,
                                           password: signIns.password(target.id, for: .tokenLogin),
                                           apiKey: signIns.apiKey(target.id, for: .profileSwitch))
            store.setApiKey(target.id, a.key)
            store.upsert(applyMe(target, a.me))
            followServerRole(target.id, a.me.effectiveUserLevel)
        }
        let sw = settings.swap(from: from?.id, to: target.id)
        store.setActiveProfileId(playlistId, target.isDefault ? nil : target.id)
        publish()
        if !target.isDefault, let key = signIns.apiKey(target.id, for: .profileSwitch), let me = await fetchMe(server, key) {
            await saveAccountFacts(server, key: key, me: me)
        }
        // After the overlay moved, so iCloud (default profile only) never sees the incoming data as a change.
        data.swap(playlistId, from: from?.id, to: target.id)
        // The swap wrote UserDefaults directly; the in-memory settings holders
        // (ThemeManager, RemoteControlStore, the channel list, Movies, TV Shows)
        // re-read on the same notice a Dispatcharr Sync or iCloud apply posts.
        // Android re-keys every settings Flow on the token change instead.
        NotificationCenter.default.post(name: .syncManagerDidApplyPreferences, object: nil)
        // iCloud: the next push waits for a fresh read-and-merge.
        NotificationCenter.default.post(name: .aerioProfileDidSwitch, object: nil)
        debugLog("[PROFILE] settings swap -> \(Self.tag(target.id)) slot=\(sw.loaded) keys=\(sw.keys); stores re-read")
        if !DispatcharrSyncManager.shared.isEnabled {
            debugLog("[PROFILE] switch: Dispatcharr Sync is off; no pull for this profile (local slots only)")
        }
        debugLog("[PROFILE] switch \(from.map { Self.tag($0.id) } ?? "?") -> \(Self.tag(target.id))")
        debugLog("[SWITCH] profile gate=\(Self.nowMs() - t0)ms")
        onSwitched?(playlistId, from?.id, target.id)
        // Verified at this address: tag it with the default account here (ProfileHostHold).
        if !target.isDefault { Task { await self.tagSignIn(target.id, server) } }
        if from?.id != target.id && reload { await reloadAfterSwitch(server) }
    }

    /// Android Reload: channels, groups, guide, VOD, and DVR load again as the new
    /// profile's user. Channels reload here; the credentialGeneration bump re-runs
    /// the load orchestrator for the guide, VOD (its cache is per profile), and DVR.
    private func reloadAfterSwitch(_ server: ServerConnection) async {
        PlayerSession.shared.stop()
        DispatcharrTokenStore.shared.clear(serverID: server.id)
        CatchupSupport.invalidateCredentials(serverID: server.id)
        let t0 = Self.nowMs()
        await ChannelStore.shared.reloadChannelsAndWait(servers: [server])
        server.credentialGeneration &+= 1
        try? server.modelContext?.save()
        NotificationCenter.default.post(name: .dispatcharrCapabilitiesDidChange, object: nil)
        debugLog("[SWITCH] channels reloaded in \(Self.nowMs() - t0)ms; guide, VOD, and DVR reload sent")
    }
}
