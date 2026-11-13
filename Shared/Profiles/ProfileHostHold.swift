//  ProfileHostHold.swift
//  Aerio
//
//  Profile sign-ins after a server address change (security fix, review
//  finding A-APP-1, approved by the owner 2026-11-11; the Android app has
//  the same rules). Each non-default profile keeps its own Dispatcharr API
//  key and password on this device, attached to the playlist id. Edit
//  Playlist, a setup handoff that updates a playlist in place, an iCloud
//  pull, and a playlist merge can point a playlist at another address, and
//  those sign-ins used to follow it there: laid over every request, sent on
//  the next switch (users/me, then the token endpoint), and used by that
//  profile's Dispatcharr Sync session. A typo or someone else's server got
//  other users' keys and passwords.
//
//  Now a route change (the scheme, host, or port of the server URL or the
//  local URL) holds every non-default profile's stored sign-in before
//  anything is sent. A held sign-in is never sent anywhere (ProfileSignIns).
//  The DEFAULT profile's users/me at the new address is compared with the
//  user id and username this device recorded before the change started
//  (the snapshot; nothing answered during the change, or while anything is
//  held, is recorded). The same account releases every held profile whose
//  own tag (the default account where that profile last signed in) is the
//  snapshot; any other profile, and every profile when the account differs,
//  stays held until it is signed in again. Holds survive a relaunch.
//
//  Pure: Foundation only, with the defaults and the profile store injected,
//  so Scripts/profile-host-tests compiles this file directly.

import Foundation

// MARK: - Route

/// Where a playlist's requests, and so its sign-ins, go: the scheme, host,
/// and port of its server URL and its local URL.
enum PlaylistRoute {

    /// "scheme://host:port", lowercased, with the default port filled in.
    /// Empty for an empty or unparseable value.
    static func hostKey(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        guard let url = URL(string: s), let host = url.host?.lowercased(), !host.isEmpty else { return "" }
        let scheme = (url.scheme ?? "http").lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// True when either route of the playlist now points somewhere else. A
    /// path-only change on the same scheme, host, and port is not a route change.
    static func changed(oldBase: String, newBase: String, oldLocal: String, newLocal: String) -> Bool {
        hostKey(oldBase) != hostKey(newBase) || hostKey(oldLocal) != hostKey(newLocal)
    }

    /// Both routes as one value, to compare a playlist now with a hold.
    static func key(base: String, local: String) -> String {
        hostKey(base) + "|" + hostKey(local)
    }

    /// The routes' host keys, without blanks or repeats.
    static func hosts(base: String, local: String) -> [String] {
        var out: [String] = []
        for k in [hostKey(base), hostKey(local)] where !k.isEmpty && !out.contains(k) { out.append(k) }
        return out
    }

    /// Where the same-server check calls users/me: every current address
    /// whose host the profiles were not used with before the change. When
    /// none is new (the playlist went back), the address requests use now.
    static func checkTargets(base: String, local: String, effective: String, trusted: [String]) -> [String] {
        var out: [String] = []
        var seen: [String] = []
        for url in [base, local] {
            let k = hostKey(url)
            guard !k.isEmpty, !trusted.contains(k), !seen.contains(k) else { continue }
            seen.append(k)
            out.append(url)
        }
        if out.isEmpty, !hostKey(effective).isEmpty { out.append(effective) }
        return out
    }
}

// MARK: - The same-server check

/// The default profile's Dispatcharr account as users/me answered it.
struct DefaultIdentity: Equatable, Sendable {
    let userId: Int
    let username: String

    /// Nil for an answer that names no account (no id or no username).
    init?(userId: Int, username: String) {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard userId > 0, !u.isEmpty else { return nil }
        self.userId = userId
        self.username = u
    }
}

enum SameServerCheck {
    /// One users/me answer: the account, or why there is none
    /// ("network", "rejected", "rate-limited", "error").
    enum Answer: Equatable, Sendable {
        case user(DefaultIdentity)
        case failed(String)
    }

    enum Decision: Equatable, Sendable {
        case lift
        case keep(String)
    }

    /// The same server: every address answered, each with the user id AND
    /// username recorded before the change. No record, no answer, a failed
    /// answer, or a different user keeps the hold.
    static func decide(expected: DefaultIdentity?, answers: [Answer]) -> Decision {
        guard let expected else { return .keep("no-record") }
        guard !answers.isEmpty else { return .keep("no-address") }
        for a in answers {
            switch a {
            case .failed(let why): return .keep(why)
            case .user(let u): if u != expected { return .keep("different-user") }
            }
        }
        return .lift
    }

    /// The check runs only against the address the hold was made for, so a
    /// users/me that lands before the new address is written (still the old
    /// server) can never lift the hold.
    static func ready(holdRoute: String, routeNow: String) -> Bool { holdRoute == routeNow }
}

// MARK: - Store

/// One playlist's hold: the profiles held, the default identity recorded
/// before the first change (the snapshot every check compares with), the
/// hosts the sign-ins were used with before it, and the route the hold is for now.
struct HostHoldRecord: Equatable, Sendable {
    var profileIds: [String]
    var expected: DefaultIdentity?
    var trustedHosts: [String]
    var route: String
}

/// Which default account a profile's sign-in belongs with: the one users/me
/// answered (live) at the address where the profile last signed in or was
/// verified. `unknown` when that answer could not be read; such a profile is
/// never released by a same-server check, only by signing in again.
enum SignInTag: Equatable, Sendable {
    case identity(DefaultIdentity)
    case unknown
}

enum ProfileHostHoldRules {
    /// Who a route change holds: EVERY non-default profile of the playlist,
    /// with or without a sign-in stored here (follow-up 9). A keyless held
    /// profile behaves like any held one: picking it shows the sign-in form
    /// with the line, and the roster pause runs while it is held.
    static func toHold(_ profiles: [DispatcharrProfile]) -> [String] {
        profiles.filter { !$0.isDefault }.map(\.id)
    }

    /// A passing check releases only the held profiles whose tag is the
    /// snapshot. A profile that signed in at another server (moved away,
    /// added there, moved back) stays held: its key is for that server.
    static func liftable(held: [String], tags: (String) -> SignInTag?, snapshot: DefaultIdentity?) -> [String] {
        guard let snapshot else { return [] }
        return held.filter { tags($0) == .identity(snapshot) }
    }

    enum Pick: Equatable, Sendable {
        /// The "Sign in to Dispatcharr" form with the server-address line, then the switch.
        case signInAgain
        /// The switch as before.
        case switchNow
    }

    /// Picking a profile in a switcher: a held profile always gets the form
    /// with the line, whether or not it still has a stored sign-in. A
    /// non-default profile with nothing stored gets the form too (it is
    /// treated exactly like a held one); the default uses the playlist's own.
    static func onPick(isHeld: Bool, hasStoredSignIn: Bool, isDefault: Bool) -> Pick {
        isHeld || (!isDefault && !hasStoredSignIn) ? .signInAgain : .switchNow
    }

    /// What an ACTIVE profile's requests carry. A non-default profile's own
    /// key, or nothing at all: never the default's (playlist's) key or
    /// password in its place. An active non-default profile with no stored
    /// key (lost to a pulled credential change, or restored on relaunch) is
    /// treated exactly like a held one.
    enum ActiveSignIn: Equatable, Sendable {
        /// The default profile: the playlist's own sign-in.
        case playlist
        /// The profile's own key.
        case own(String)
        /// Held, or no key stored: no request to the playlist's addresses.
        case refused
    }

    static func activeSignIn(isDefault: Bool, isHeld: Bool, storedKey: String?) -> ActiveSignIn {
        if isDefault { return .playlist }
        if isHeld { return .refused }
        let k = storedKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return k.isEmpty ? .refused : .own(k)
    }

    /// A route change, or a relaunch, with a held profile active: it is left
    /// for the default profile (as removing the active profile does), except a
    /// Child (follow-up 8). A Child stays active and held, so nothing it holds
    /// is sent and its requests go nowhere until the hold lifts; leaving it is
    /// the normal switch with its PIN. No forced switch ever bypasses a PIN
    /// away from a Child.
    static func leavesForDefault(activeRole: ProfileRole?) -> Bool { activeRole != .child }

    /// Which sign-in form choosing a profile opens (switcher, launch picker).
    enum PickForm: Equatable, Sendable {
        /// None: the switch as before.
        case none
        /// The profile's own "Sign in to Dispatcharr" form (its username, only its user accepted).
        case profileForm
        /// The playlist's own sign-in (the default profile, the known-user chain).
        case playlistForm
    }

    /// Choosing a profile whose key is held as rejected (Roku spec 8.4 step 4,
    /// the phones match it): after the PIN the switch already needs, and before
    /// any sync flush or playback stop, its sign-in form opens and nothing is
    /// sent with the held key. A non-default profile gets its own form; the
    /// default profile the playlist's own sign-in. A Child target too (an adult,
    /// or an adult's PIN, chose it). The current profile is left to the flows it
    /// has today (an active Child gets only what it gets today).
    static func pickForm(isDefault: Bool, keyHeld: Bool, isCurrent: Bool) -> PickForm {
        guard keyHeld, !isCurrent else { return .none }
        return isDefault ? .playlistForm : .profileForm
    }

    enum Reopen: Equatable, Sendable {
        /// Signed in: nothing to do.
        case asIs
        /// Anyone but a Child: the default profile takes over.
        case fallBackToDefault
        /// A Child stays (nothing sent, the unreachable line) and its sign-in form opens.
        case staySignIn
    }

    /// The active profile reopened at launch or on a playlist change while it
    /// is held or has no stored key (activeSignIn == .refused).
    static func onReopen(isDefault: Bool, role: ProfileRole?, refused: Bool) -> Reopen {
        guard !isDefault, refused else { return .asIs }
        return leavesForDefault(activeRole: role) ? .fallBackToDefault : .staySignIn
    }

    /// Removing a profile (Remove Profile): a HELD profile goes from this
    /// device only, with no tombstone. Its row was never part of the new
    /// server's roster, and a tombstone sent there once the roster sync
    /// resumes could delete a same-named profile on that server's devices.
    static func removeWritesTombstone(isHeld: Bool) -> Bool { !isHeld }

    /// A profile added while the playlist's roster sync was paused could not
    /// see the roster. On the first pull after the pause it takes the roster
    /// row for its username, if there is one, the way a manual add of a
    /// roster user does (same match, the row's stamp kept); nil keeps it a plain add.
    static func rowAfterPause(_ username: String, rows: [ProfileRow]) -> ProfileRow? {
        ProfileRoster.rowForManualAdd(username, rows: rows, localUsernames: [])
    }

    /// A pause add that took its roster row is a roster add from then on, so
    /// undoing it while it still can be undone (Remove after an add, or Cancel
    /// on "PIN Required") stays on this device with no tombstone. One that
    /// found no row stays a plain add.
    static func isRosterAddAfterPause(adoptedRow: Bool) -> Bool { adoptedRow }
}

// MARK: - Stored secrets and the playlist's own route

/// The playlist's OWN stored secrets after a route change (security fix,
/// 2026-11-12, Android found it first). The default profile's saved password
/// went to a new address with nothing proving it was the same server: the
/// identity repair, seeing the stored key answer as another user there,
/// signed in at the new address with the saved username and password, and a
/// silent re-login after a 401 did the same.
///
/// A route change leaves every new address UNPROVEN until the same-server
/// check passes there (the default account answers with the user id and
/// username recorded before the change), or the user signs in there with
/// what they type. Proof is per address (Android 6aa73a74): when only the
/// Local URL changed, the Server URL stays proven. To an unproven address,
/// nothing stored and secret goes out for the playlist: no saved password (silent re-login, launch warmup,
/// identity repair, Edit Playlist's verify and the host-change sign-in,
/// Refresh Session, a Fix Login sent from another device), no other
/// profile's stored key or password (the profile holds), and no Dispatcharr
/// Sync session. The new address gets only what the user types, and the
/// playlist's own API key from the Edit Playlist save the user made (the
/// same-server check sends it). A check that finds another account holds
/// that key, so the default profile shows the sign-in form.
enum StoredSecretRules {
    /// Every path that can send a stored secret, for the log and the tests.
    enum Path: String, CaseIterable, Sendable {
        case identityRepair = "identity repair"
        case silentRelogin = "silent re-login"
        case launchWarmup = "launch sign-in"
        case editPlaylistVerify = "Edit Playlist verify"
        case hostChangeSignIn = "host change sign-in"
        case refreshSession = "Refresh Session"
        case fixLogin = "Fix Login"
        case dispatcharrSync = "Dispatcharr Sync"
        case defaultProfileSwitch = "default profile switch"
    }

    /// A stored secret may go to [target] only when [target] is one of the
    /// playlist's current addresses (scheme, host, and port) AND that address
    /// is proven: proof is per address (Android 6aa73a74). [provenHosts] nil
    /// means no change since this device last proved the route, so every
    /// current address is proven. A typed address that is not saved yet is a
    /// new address, never proven. Identity repair, Dispatcharr Sync, the
    /// default profile's switch, and the launch sign-in ask about the address
    /// they would use.
    static func mayUseStored(provenHosts: [String]?, target: String, base: String, local: String) -> Bool {
        let k = PlaylistRoute.hostKey(target)
        guard !k.isEmpty, PlaylistRoute.hosts(base: base, local: local).contains(k) else { return false }
        guard let provenHosts else { return true }
        return provenHosts.contains(k)
    }

    /// What a password field holds when it goes out: what the user typed,
    /// else the saved password only where it may go, else nothing.
    static func password(typed: String, stored: String, mayUseStored: Bool) -> String {
        if !typed.isEmpty { return typed }
        return mayUseStored ? stored : ""
    }

    /// A same-server check verdict for the playlist's own key: another
    /// account at the new address holds the key (the sign-in form); a
    /// network failure or a refused key leaves it to the usual paths.
    static func holdsPlaylistKey(after decision: SameServerCheck.Decision) -> Bool {
        decision == .keep("different-user")
    }
}

/// Whether the Edit Playlist form's password field was typed in during this
/// visit (Android 6aa73a74 tracks the same). A field opened with a value in it
/// (an in-memory copy the Keychain save kept) and left untouched is the SAVED
/// password, never something the user typed, so it is held to the stored
/// secret rules. Memory only.
final class TypedSecretFields: @unchecked Sendable {
    static let shared = TypedSecretFields()
    private let lock = NSLock()
    private var typed = Set<String>()

    /// The form opened: nothing is typed yet.
    func began(_ playlistId: String) { lock.lock(); typed.remove(playlistId); lock.unlock() }
    /// The user changed the password field.
    func edited(_ playlistId: String) { lock.lock(); typed.insert(playlistId); lock.unlock() }
    /// The field's value when the user typed it in this visit, else "".
    func typedPassword(_ playlistId: String, field: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return typed.contains(playlistId) ? field : ""
    }
}

/// What the user sees when a stored secret is kept from an unproven address.
enum StoredSecretCopy {
    /// Edit Playlist's save and Refresh Session, Username & Password, a new address, no typed password.
    static let typePasswordAtNewAddress = "Enter the password to sign in at the new server address."
    /// Fix Login on the receiving device while its playlist's new address is unproven.
    static let fixLoginNewAddress = "This playlist's server address changed. Sign in on this device to use the new address."
}

/// A route change waiting for proof: the route it is for and the hosts the
/// playlist was used with before the first change.
struct UnprovenRoute: Equatable, Sendable {
    var route: String
    var trustedHosts: [String]
}

/// The holds, the default profile's recorded identity, and each profile's
/// sign-in tag, in UserDefaults (no secrets: profile ids, user ids,
/// usernames, hosts).
final class ProfileHostHoldStore {
    static let KEY_HOLDS = "aerio.profiles.host_hold.v1"
    static let KEY_IDENTITY = "aerio.profiles.default_identity.v1"
    static let KEY_TAGS = "aerio.profiles.signin_tag.v1"
    static let KEY_PAUSE_ADDS = "aerio.profiles.added_during_pause.v1"
    static let KEY_UNPROVEN = "aerio.profiles.route_unproven.v1"

    private let defaults: UserDefaults
    private var holds: [String: HostHoldRecord] = [:]
    private var identities: [String: DefaultIdentity] = [:]
    private var tags: [String: SignInTag] = [:]
    /// Profiles added while their playlist's roster sync was paused.
    private var pauseAdds = Set<String>()
    /// Playlists in the middle of a route change (memory only).
    private var changing = Set<String>()
    /// Playlists whose route changed and is not proven yet (StoredSecretRules).
    private var unproven: [String: UnprovenRoute] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
    }

    // MARK: Reads

    func record(_ playlistId: String) -> HostHoldRecord? { holds[playlistId] }

    /// Playlists with any profile held.
    var heldPlaylistIds: Set<String> { Set(holds.keys) }

    func isHeld(_ profileId: String) -> Bool { holds.values.contains { $0.profileIds.contains(profileId) } }

    /// The default profile's identity this device last recorded for [playlistId].
    func identity(_ playlistId: String) -> DefaultIdentity? { identities[playlistId] }

    func tag(_ profileId: String) -> SignInTag? { tags[profileId] }

    func addedDuringPause(_ profileId: String) -> Bool { pauseAdds.contains(profileId) }

    /// Whether a users/me answer may update [playlistId]'s record now.
    /// Never during a route change (SNAPSHOT: the change's own users/me,
    /// such as the save's validation, the host-change re-verify, or a setup
    /// payload's verify, would record the new server and then match itself),
    /// and never while any profile of the playlist is held (FREEZE).
    /// Nor while its route is unproven: the new server's answer would become
    /// the record and the check would then match itself.
    func mayRecord(_ playlistId: String) -> Bool {
        holds[playlistId] == nil && !changing.contains(playlistId) && unproven[playlistId] == nil
    }

    /// The playlist's route changed and is not proven yet (StoredSecretRules).
    func isRouteUnproven(_ playlistId: String) -> Bool { unproven[playlistId] != nil }
    func unprovenRoute(_ playlistId: String) -> UnprovenRoute? { unproven[playlistId] }
    var unprovenPlaylistIds: Set<String> { Set(unproven.keys) }

    // MARK: Writes

    /// A route change for [playlistId] starts: from here the record is the
    /// snapshot until endChange.
    func beginChange(_ playlistId: String) { changing.insert(playlistId) }
    func endChange(_ playlistId: String) { changing.remove(playlistId) }
    func isChanging(_ playlistId: String) -> Bool { changing.contains(playlistId) }

    /// Record the default profile's users/me answer for [playlistId]. False
    /// when frozen: once nothing is held and no change is under way it
    /// records again, and from then on the new address is the trusted one.
    @discardableResult
    func recordIdentity(_ playlistId: String, _ id: DefaultIdentity) -> Bool {
        guard mayRecord(playlistId) else { return false }
        guard identities[playlistId] != id else { return true }
        identities[playlistId] = id
        save()
        return true
    }

    /// A route change: every address not proven before is unproven. A
    /// playlist already waiting keeps its proven addresses and follows the
    /// new route. An address that did not change (only the Local URL moved)
    /// stays proven.
    func markRouteUnproven(_ playlistId: String, trustedHosts: [String], route: String) {
        var r = unproven[playlistId] ?? UnprovenRoute(route: route, trustedHosts: trustedHosts)
        r.route = route
        unproven[playlistId] = r
        save()
    }

    /// The addresses where the playlist's stored secrets may go, or nil when
    /// its whole current route is proven.
    func provenHosts(_ playlistId: String) -> [String]? { unproven[playlistId]?.trustedHosts }

    /// [hosts] are proven now (the same-server check passed there, or the
    /// user signed in there with what they typed). Once every current
    /// address is proven the record goes. True when anything changed.
    @discardableResult
    func proveHosts(_ playlistId: String, _ hosts: [String], currentHosts: [String]) -> Bool {
        guard var r = unproven[playlistId] else { return false }
        let added = hosts.filter { !$0.isEmpty && !r.trustedHosts.contains($0) }
        r.trustedHosts += added
        if currentHosts.allSatisfy(r.trustedHosts.contains) {
            unproven[playlistId] = nil
        } else {
            unproven[playlistId] = r
        }
        save()
        return !added.isEmpty || unproven[playlistId] == nil
    }

    /// A profile signed in or was verified at the playlist's current address.
    func setTag(_ profileId: String, _ tag: SignInTag) {
        guard tags[profileId] != tag else { return }
        tags[profileId] = tag
        save()
    }

    /// Profiles from before this release have no tag: they get the recorded
    /// identity the first time there is one (never over a tag they have).
    @discardableResult
    func backfillTags(_ playlistId: String, profileIds: [String]) -> Int {
        guard let id = identities[playlistId] else { return 0 }
        var n = 0
        for p in profileIds where tags[p] == nil {
            tags[p] = .identity(id)
            n += 1
        }
        if n > 0 { save() }
        return n
    }

    /// Hold [profileIds] while [playlistId] changes to [route]. The snapshot
    /// is the record as it stood before the change; untagged profiles get it
    /// as their tag. A playlist already on hold keeps its snapshot and hosts
    /// from before its first change and only follows the new route. Returns
    /// the hold, or nil when nothing is held.
    @discardableResult
    func hold(_ playlistId: String, profileIds: [String], trustedHosts: [String], route: String) -> HostHoldRecord? {
        backfillTags(playlistId, profileIds: profileIds)
        var r = holds[playlistId]
            ?? HostHoldRecord(profileIds: [], expected: identities[playlistId], trustedHosts: trustedHosts, route: route)
        r.profileIds = Array(Set(r.profileIds).union(profileIds)).sorted()
        r.route = route
        guard !r.profileIds.isEmpty else { return nil }
        holds[playlistId] = r
        save()
        return r
    }

    /// The same server: releases the held profiles whose tag is the
    /// snapshot; the rest stay held. Returns both lists.
    @discardableResult
    func liftMatching(_ playlistId: String) -> (lifted: [String], kept: [String]) {
        guard var r = holds[playlistId] else { return ([], []) }
        let lifted = ProfileHostHoldRules.liftable(held: r.profileIds, tags: { self.tags[$0] }, snapshot: r.expected)
        r.profileIds.removeAll { lifted.contains($0) }
        holds[playlistId] = r.profileIds.isEmpty ? nil : r
        if !lifted.isEmpty || r.profileIds.isEmpty { save() }
        return (lifted, r.profileIds)
    }

    /// One profile signed in again, or removed. True when it was held.
    @discardableResult
    func lift(profileId: String) -> Bool {
        guard let hit = holds.first(where: { $0.value.profileIds.contains(profileId) }) else { return false }
        var r = hit.value
        r.profileIds.removeAll { $0 == profileId }
        holds[hit.key] = r.profileIds.isEmpty ? nil : r
        save()
        return true
    }

    /// A plain add while the playlist's roster sync is paused (rowAfterPause runs on it later).
    func markAddedDuringPause(_ profileId: String) {
        guard pauseAdds.insert(profileId).inserted else { return }
        save()
    }

    /// The first pull after the pause checked it.
    func clearAddedDuringPause(_ profileId: String) {
        guard pauseAdds.remove(profileId) != nil else { return }
        save()
    }

    /// A profile was removed: its hold, tag, and pause mark go.
    func forgetProfile(_ profileId: String) {
        lift(profileId: profileId)
        let hadTag = tags.removeValue(forKey: profileId) != nil
        let hadMark = pauseAdds.remove(profileId) != nil
        if hadTag || hadMark { save() }
    }

    /// A playlist merged into another: its holds go with its profiles.
    func move(from loser: String, to winner: String) {
        // The winner's own route state stands; the loser's goes with it.
        if loser != winner, unproven.removeValue(forKey: loser) != nil { save() }
        guard loser != winner, let r = holds.removeValue(forKey: loser) else { return }
        if var w = holds[winner] {
            w.profileIds = Array(Set(w.profileIds).union(r.profileIds)).sorted()
            holds[winner] = w
        } else {
            holds[winner] = r
        }
        save()
    }

    /// A playlist's profiles were removed: its hold goes too.
    func drop(_ playlistId: String) {
        guard holds.removeValue(forKey: playlistId) != nil else { return }
        save()
    }

    /// The playlist itself was deleted: its hold and its recorded identity
    /// go. The only place the identity is cleared.
    func forgetPlaylist(_ playlistId: String) {
        let hadHold = holds.removeValue(forKey: playlistId) != nil
        let hadIdentity = identities.removeValue(forKey: playlistId) != nil
        let hadRoute = unproven.removeValue(forKey: playlistId) != nil
        changing.remove(playlistId)
        if hadHold || hadIdentity || hadRoute { save() }
    }

    // MARK: Persistence

    private static func identity(from v: [String: Any]) -> DefaultIdentity? {
        DefaultIdentity(userId: (v["userId"] as? NSNumber)?.intValue ?? 0, username: v["username"] as? String ?? "")
    }

    private func object(_ key: String) -> [String: [String: Any]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]) ?? [:]
    }

    private func load() {
        for (pid, v) in object(Self.KEY_HOLDS) {
            let ids = (v["profiles"] as? [String]) ?? []
            guard !ids.isEmpty else { continue }
            holds[pid] = HostHoldRecord(profileIds: ids.sorted(), expected: Self.identity(from: v),
                                        trustedHosts: (v["trusted"] as? [String]) ?? [],
                                        route: v["route"] as? String ?? "")
        }
        for (pid, v) in object(Self.KEY_IDENTITY) {
            if let id = Self.identity(from: v) { identities[pid] = id }
        }
        for (profileId, v) in object(Self.KEY_TAGS) {
            if let id = Self.identity(from: v) { tags[profileId] = .identity(id) } else { tags[profileId] = .unknown }
        }
        pauseAdds = Set(defaults.stringArray(forKey: Self.KEY_PAUSE_ADDS) ?? [])
        for (pid, v) in object(Self.KEY_UNPROVEN) {
            unproven[pid] = UnprovenRoute(route: v["route"] as? String ?? "", trustedHosts: (v["trusted"] as? [String]) ?? [])
        }
    }

    private func write(_ o: [String: Any], _ key: String) {
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { defaults.set(data, forKey: key) }
    }

    private func save() {
        var h: [String: Any] = [:]
        for (pid, r) in holds {
            var v: [String: Any] = ["profiles": r.profileIds, "trusted": r.trustedHosts, "route": r.route]
            if let e = r.expected { v["userId"] = e.userId; v["username"] = e.username }
            h[pid] = v
        }
        write(h, Self.KEY_HOLDS)
        var i: [String: Any] = [:]
        for (pid, id) in identities { i[pid] = ["userId": id.userId, "username": id.username] }
        write(i, Self.KEY_IDENTITY)
        var t: [String: Any] = [:]
        for (profileId, tag) in tags {
            switch tag {
            case .identity(let id): t[profileId] = ["userId": id.userId, "username": id.username]
            case .unknown: t[profileId] = ["unknown": true]
            }
        }
        write(t, Self.KEY_TAGS)
        defaults.set(pauseAdds.sorted(), forKey: Self.KEY_PAUSE_ADDS)
        var u: [String: Any] = [:]
        for (pid, r) in unproven { u[pid] = ["route": r.route, "trusted": r.trustedHosts] }
        write(u, Self.KEY_UNPROVEN)
    }
}

// MARK: - Outbound sign-ins

/// Every read of a non-default profile's stored sign-in that can leave this
/// device goes through here, naming what it is for. While the profile is
/// held, nothing comes back for any use; the Keychain keeps the values so a
/// lifted hold needs nothing re-entered.
struct ProfileSignIns {
    enum Use: String, CaseIterable, Sendable {
        /// The active profile's key laid over every request (ProfileOverlay).
        case requestOverlay
        /// users/me with the stored key: a switch, the permissions probe, the account facts.
        case profileSwitch
        /// The stored password to the token endpoint.
        case tokenLogin
        /// The profile's Dispatcharr Sync session.
        case syncSession
        /// A setup handoff payload, or the User QR code.
        case setupPayload
    }

    let store: ProfileStore
    let holds: ProfileHostHoldStore

    func apiKey(_ profileId: String, for use: Use) -> String? {
        holds.isHeld(profileId) ? nil : store.apiKey(profileId)
    }

    func password(_ profileId: String, for use: Use) -> String? {
        holds.isHeld(profileId) ? nil : store.password(profileId)
    }

    /// Whether this device stores any sign-in for the profile, held or not.
    func hasStored(_ profileId: String) -> Bool {
        store.apiKey(profileId) != nil || store.password(profileId) != nil
    }
}
