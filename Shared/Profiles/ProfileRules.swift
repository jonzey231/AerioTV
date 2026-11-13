// Pure profile rules, ported from the Android core/profiles package
// (ProfileRole.kt, ProfilePin.kt, ProfileOrder.kt, ProfileRoster.kt,
// AvatarSpec.kt, SnapshotStamp.kt). No app singletons: the dsync test
// script compiles this file directly.

import Foundation
import CryptoKit

/// Android ProfileLevel: Dispatcharr user_level 10 admin, 1 standard, 0 streamer.
enum ProfileLevel: String, Sendable {
    case admin = "Admin", standard = "Standard", limited = "Limited"

    static func of(_ userLevel: Int) -> ProfileLevel {
        userLevel >= 10 ? .admin : (userLevel >= 1 ? .standard : .limited)
    }
}

/// App-local role of a profile. The label follows the Dispatcharr access
/// (owner rule 2026-10-29): a server admin is Admin, any other user
/// Standard or Child.
enum ProfileRole: String, CaseIterable, Sendable {
    case admin, user, child

    var label: String {
        switch self {
        case .admin: return "Admin"
        case .user: return "Standard"
        case .child: return "Child"
        }
    }

    var wire: String { rawValue }

    static func isServerAdmin(_ userLevel: Int) -> Bool { ProfileLevel.of(userLevel) == .admin }

    static func defaultFor(_ userLevel: Int) -> ProfileRole { isServerAdmin(userLevel) ? .admin : .user }

    static func optionsFor(_ userLevel: Int) -> [ProfileRole] { optionsFor(serverAdmin: isServerAdmin(userLevel)) }

    /// serverAdmin nil = level unknown: Standard and Child, never Admin.
    static func optionsFor(serverAdmin: Bool?) -> [ProfileRole] {
        serverAdmin == true ? [.admin] : [.user, .child]
    }

    static func resolve(_ userLevel: Int, _ picked: ProfileRole?) -> ProfileRole {
        if let picked, optionsFor(userLevel).contains(picked) { return picked }
        return defaultFor(userLevel)
    }

    static func fromWire(_ s: String?) -> ProfileRole? { allCases.first { $0.wire == s } }
}

/// Android RoleRules. Inside AerioTV, Admin and Standard are identical
/// ("full access"); only gates that call Dispatcharr admin endpoints look
/// at the server admin flag.
enum RoleRules {
    static func isFullAccess(_ role: ProfileRole?) -> Bool { role != nil && role != .child }
    static func canSeeSwitcher(_ active: ProfileRole?) -> Bool { active != .child }
    static func canManageProfiles(_ active: ProfileRole?) -> Bool { active != .child }

    /// Settings for a Child, exactly Android's CHILD_SECTIONS (below) in Apple's
    /// SettingsDestination raw values (follow-up 12): Live TV, Player, Appearance,
    /// and About, plus Manage Profiles, the PIN-gated way out. Everything else
    /// (the Playlists block and every playlist page, Movies and TV Shows, DVR,
    /// General, Remote Control, Sync, Developer) is hidden. Deep links use
    /// deepLinkAllowed and the Playlists block playlistsVisible.
    static let CHILD_SETTINGS_SECTIONS: Set<String> = ["live-tv", "player", "appearance", "about"]

    static func settingsSectionVisible(_ active: ProfileRole?, _ section: String) -> Bool {
        active != .child || CHILD_SETTINGS_SECTIONS.contains(section)
    }
    static func canChangeRoles(_ active: ProfileRole?) -> Bool { isFullAccess(active) }

    enum AddPath: Sendable { case serverList, manual }

    static func addPath(baseIsServerAdmin: Bool, usersListForbidden: Bool) -> AddPath {
        baseIsServerAdmin && !usersListForbidden ? .serverList : .manual
    }

    static func canAssignChannelProfiles(baseIsServerAdmin: Bool, activeIsServerAdmin: Bool, active: ProfileRole?) -> Bool {
        baseIsServerAdmin && activeIsServerAdmin && isFullAccess(active)
    }

    static func canWriteProfilesKey(_ active: ProfileRole?) -> Bool { isFullAccess(active) }
    static func canEditAvatar(actor: ProfileRole?, isOwn: Bool) -> Bool { actor != .child || isOwn }
    static func canEditServer(_ active: ProfileRole?) -> Bool { active != .child }

    static let CHILD_SECTIONS: Set<String> = ["LiveTV", "Player", "Appearance", "About"]
    static func sectionVisible(_ active: ProfileRole?, _ sectionName: String) -> Bool {
        active != .child || CHILD_SECTIONS.contains(sectionName)
    }
    static func playlistsVisible(_ active: ProfileRole?) -> Bool { active != .child }

    static let CHILD_DEEP_LINK_PAGES: Set<String> = ["root", "livetv", "player", "appearance", "about", "manage-profiles"]
    static func deepLinkAllowed(_ active: ProfileRole?, _ page: String) -> Bool {
        active != .child || CHILD_DEEP_LINK_PAGES.contains(page.trimmingCharacters(in: .whitespaces).lowercased())
    }

    struct PinHolder: Sendable {
        var id: String
        var role: ProfileRole
        var hasPin: Bool
        var isActor: Bool = false
    }

    /// Ids of the Admin and Standard profiles that still need a PIN before
    /// (or while) a Child exists, the acting profile first.
    static func pinsMissingForChild(_ profiles: [PinHolder], becomingChild: String? = nil) -> [String] {
        let missing = profiles.filter { $0.id != becomingChild && isFullAccess($0.role) && !$0.hasPin }
        return missing.filter(\.isActor).map(\.id) + missing.filter { !$0.isActor }.map(\.id)
    }

    enum RoleChange: Equatable, Sendable {
        case allowed, needsPinsCreated, needsPinEntry
        case denied(String)
    }

    static let ADMIN_IS_SERVER_SET = "Admin is set by the Dispatcharr server."
    static let SERVER_ADMIN_STAYS = "Dispatcharr admins are always Admin in AerioTV."
    static let KEEP_PIN_REASON = "While a Child profile exists, every Admin and Standard profile needs its own profile PIN."

    /// The role to store after the server reports newLevel; nil = no change.
    static func serverRoleChange(_ stored: ProfileRole?, _ newLevel: Int) -> ProfileRole? {
        let r = ProfileRole.resolve(newLevel, stored)
        return r == stored ? nil : r
    }

    static func roleChange(actor: ProfileRole?, from: ProfileRole, to: ProfileRole, missingPins: Int,
                           anyPinExists: Bool, targetIsLastFullAccess: Bool, targetIsServerAdmin: Bool = false) -> RoleChange {
        if !isFullAccess(actor) { return .denied("Only an Admin or Standard profile can change roles.") }
        if targetIsServerAdmin && to != .admin { return .denied(SERVER_ADMIN_STAYS) }
        if !targetIsServerAdmin && to == .admin { return .denied(ADMIN_IS_SERVER_SET) }
        if from == to { return .allowed }
        if to == .child && targetIsLastFullAccess { return .denied("At least one profile must stay Admin or Standard.") }
        if to == .child && (missingPins > 0 || !anyPinExists) { return .needsPinsCreated }
        if from == .child { return .needsPinEntry }
        return .allowed
    }

    static func removeNeedsPin(_ target: ProfileRole) -> Bool { target == .child }
    static func canRemovePin(_ targetRole: ProfileRole, childExists: Bool) -> Bool { targetRole == .child || !childExists }
    static func canRemoveDevicePin(childExists: Bool, otherPins: Int) -> Bool { !childExists || otherPins > 0 }

    enum ResetGate: Equatable, Sendable {
        case enterOwnPin, confirmOnly
        case denied(String)
    }

    static func resetGate(actor: ProfileRole?, actorHasPin: Bool, childExists: Bool) -> ResetGate {
        if !isFullAccess(actor) { return .denied("Only an Admin or Standard profile can reset a PIN.") }
        if actorHasPin { return .enterOwnPin }
        if !childExists { return .confirmOnly }
        return .denied("Set a PIN on your own profile first.")
    }

    static func showLaunchPicker(isTv: Bool, isDispatcharr: Bool, toggleOn: Bool, profileCount: Int, lastRole: ProfileRole?) -> Bool {
        isTv && isDispatcharr && toggleOn && profileCount >= 2 && lastRole != .child
    }
}

// MARK: - PIN

enum PinType: String, CaseIterable, Sendable {
    case numbers = "Numbers", directions = "Directions"
    var label: String { rawValue }
}

enum PinDirection: String, CaseIterable, Sendable {
    case up = "Up", down = "Down", left = "Left", right = "Right"
    var letter: Character {
        switch self { case .up: return "U"; case .down: return "D"; case .left: return "L"; case .right: return "R" }
    }
    var label: String { rawValue }
}

/// Reserved PIN-store id for the Device Admin PIN (never a profile id, never synced).
enum DevicePin {
    static let PREFIX = "device-admin|"
    static func id(_ playlistId: String) -> String { PREFIX + playlistId }
    static func isDevice(_ id: String) -> Bool { id.hasPrefix(PREFIX) }
}

enum PinRules {
    static let MIN_LENGTH = 4
    static let MAX_LENGTH = 6

    /// How many dots a PIN pad shows. A known length: that many. Setting a PIN:
    /// at least the minimum, one more per digit up to the maximum. An unknown
    /// length (a PIN that arrived through Dispatcharr Sync, which syncs only the
    /// hash and salt): one dot per digit typed, never a fixed row of empty dots
    /// (owner 2026-11-12: a 4-digit PIN showed 6). The first correct entry stores
    /// the length on this device (ProfilePinStore.check).
    static func dotCount(knownLength: Int?, setting: Bool, typed: Int) -> Int {
        if let n = knownLength { return min(max(n, MIN_LENGTH), MAX_LENGTH) }
        if setting { return min(max(typed, MIN_LENGTH), MAX_LENGTH) }
        return min(max(typed, 0), MAX_LENGTH)
    }

    /// Digits for Numbers, U/D/L/R letters for Directions; nil when invalid.
    static func normalize(_ type: PinType, _ entries: [String]) -> String? {
        guard (MIN_LENGTH...MAX_LENGTH).contains(entries.count) else { return nil }
        var out = ""
        for e in entries {
            switch type {
            case .numbers:
                guard e.count == 1, let c = e.first, ("0"..."9").contains(c) else { return nil }
                out.append(c)
            case .directions:
                guard let d = PinDirection.allCases.first(where: {
                    $0.rawValue.caseInsensitiveCompare(e) == .orderedSame || String($0.letter).caseInsensitiveCompare(e) == .orderedSame
                }) else { return nil }
                out.append(d.letter)
            }
        }
        return out
    }

    /// v1 (device salt), kept so a legacy record still verifies.
    static func hash(salt: Data, profileId: String, type: PinType, normalized: String) -> String {
        var h = SHA256()
        h.update(data: salt)
        h.update(data: Data("|\(profileId)|\(type.rawValue)|\(normalized)".utf8))
        return DsyncPinHash.toHex(Data(h.finalize()))
    }

    /// v2 (synced): SHA-256 of salt bytes || UTF-8 PIN, lowercase hex.
    static func hashV2(saltHex: String, normalized: String) -> String? {
        DsyncPinHash.hash(saltHex: saltHex, normalizedPin: normalized)
    }

    static func wireType(_ type: PinType?) -> String {
        switch type { case .numbers: return "numbers"; case .directions: return "directions"; case nil: return "none" }
    }

    static func typeFromWire(_ s: String) -> PinType? {
        switch s { case "numbers": return .numbers; case "directions": return .directions; default: return nil }
    }

    /// Constant-time compare of two hex digests.
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    static func freshSaltHex() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[i] = UInt8.random(in: 0...255) }
        return DsyncPinHash.toHex(Data(b))
    }
}

/// Wrong-PIN backoff: 5 wrong entries, then a 30 s wait that doubles each round.
struct PinBackoff: Equatable, Sendable {
    var fails = 0
    var round = 0
    var lockedUntil: Int64 = 0

    static let ATTEMPTS = 5
    static let BASE_LOCK_MS: Int64 = 30_000
    static let MAX_DOUBLINGS = 10

    func remainingSeconds(_ now: Int64) -> Int { now >= lockedUntil ? 0 : Int((lockedUntil - now + 999) / 1000) }

    func onWrong(_ now: Int64) -> PinBackoff {
        let f = fails + 1
        if f < PinBackoff.ATTEMPTS { var c = self; c.fails = f; return c }
        let r = round + 1
        return PinBackoff(fails: 0, round: r, lockedUntil: now + PinBackoff.lockMs(r))
    }

    func onOk() -> PinBackoff { PinBackoff() }

    func encode() -> String { "\(fails),\(round),\(lockedUntil)" }

    static func lockMs(_ round: Int) -> Int64 { BASE_LOCK_MS << Int64(min(max(round - 1, 0), MAX_DOUBLINGS)) }

    static func decode(_ raw: String?) -> PinBackoff {
        guard let p = raw?.split(separator: ",", omittingEmptySubsequences: false), p.count == 3 else { return PinBackoff() }
        return PinBackoff(fails: Int(p[0]) ?? 0, round: Int(p[1]) ?? 0, lockedUntil: Int64(p[2]) ?? 0)
    }
}

// MARK: - Avatar

extension AvatarCatalog {
    static var PICKER_ICONS: [String] { [INITIAL] + ICONS }

    /// Stable default color: sum of the lowercased username's UTF-16 units, mod 8.
    static func defaultColorIndex(_ username: String) -> Int {
        let s = username.trimmingCharacters(in: .whitespaces).lowercased().utf16.reduce(0) { $0 + Int($1) }
        return s % COLORS.count
    }

    static func defaultColor(_ username: String) -> String { COLORS[defaultColorIndex(username)] }

    static func colorFor(_ spec: AvatarSpec?, _ username: String) -> String {
        if let c = spec?.color, COLORS.contains(c) { return c }
        return defaultColor(username)
    }

    static func iconFor(_ spec: AvatarSpec?) -> String {
        if let i = spec?.icon, ICONS.contains(i) { return i }
        return INITIAL
    }

    /// Ink for the letter or icon on the circle: the owner's final pick
    /// (2026-11-11), the same on Android and on every form factor, in light
    /// and dark mode. #0B1220 on teal, orange, green, and slate; white on
    /// blue, purple, sea, and ember. A fixed set, not a luminance rule.
    static let DARK_INK_COLORS: Set<String> = ["teal", "orange", "green", "slate"]
    static let DARK_INK: UInt32 = 0x0B1220
    static let LIGHT_INK: UInt32 = 0xFFFFFF

    static func inkHex(_ colorId: String) -> UInt32 { DARK_INK_COLORS.contains(colorId) ? DARK_INK : LIGHT_INK }

    /// The letter on an initial avatar, the same on Android: the trimmed
    /// display name, else the trimmed username, else "?"; its first
    /// character, uppercased.
    static func initial(name: String, username: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = !n.isEmpty ? n : (!u.isEmpty ? u : "?")
        return String(s.prefix(1)).uppercased()
    }
}

// MARK: - Profile record (pure part of Android DispatcharrProfile)

struct DispatcharrProfile: Equatable, Sendable, Identifiable {
    var id: String
    var playlistId: String
    var displayName: String
    /// The Dispatcharr username this profile authenticates as.
    var username: String
    var isDefault = false
    /// Dispatcharr user_level: 10 admin, 1 standard, 0 streamer.
    var userLevel = 10
    var accountProfileIds = ""
    var createdAt: Int64 = 0
    /// nil = the default for userLevel.
    var role: ProfileRole? = nil
    /// Dispatcharr user id from /me/ (0 = not read yet).
    var userId = 0
    var avatar: AvatarSpec? = nil
    /// List position (0 first); -1 = never moved (insertion order).
    var order = -1
    // Per-user facts from /api/accounts/users/me/ for a non-default profile
    // (Android DispatcharrProfile). The default profile keeps them on the
    // playlist row. Credentials are never here: ProfileStore keeps the API
    // key and password in the Keychain.
    var streamLimit = 0
    var hideAdultContent = false
    var dvrAccess = ""
    var catchupEnabled = true
    var vodMoviesEnabled = true
    var vodSeriesEnabled = true
    var isStaff = false
    var isSuperuser = false
    var customProperties = ""
    var capabilitiesFetchedAt: Int64 = 0

    var effectiveRole: ProfileRole { ProfileRole.resolve(userLevel, role) }
}

enum ProfileOrder {
    enum Move: Sendable { case earlier, later, first }

    static func step(_ ids: [String], _ id: String, _ how: Move) -> [String] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        let raw: Int
        switch how { case .earlier: raw = from - 1; case .later: raw = from + 1; case .first: raw = 0 }
        let to = min(max(raw, 0), ids.count - 1)
        var out = ids
        let v = out.remove(at: from)
        out.insert(v, at: to)
        return out
    }

    /// Unknown ids drop; current ids the request does not name keep their
    /// relative place at the end.
    static func resolve(_ current: [String], _ requested: [String]) -> [String] {
        let known = Set(current)
        var seen = Set<String>()
        let head = requested.filter { known.contains($0) && seen.insert($0).inserted }
        let headSet = Set(head)
        return head + current.filter { !headSet.contains($0) }
    }

    /// Android ProfileStore.forPlaylist sort: default first, then created,
    /// then explicit order (stable; never moved = after).
    static func sorted(_ list: [DispatcharrProfile]) -> [DispatcharrProfile] {
        let base = list.enumerated().sorted { a, b in
            if a.element.isDefault != b.element.isDefault { return a.element.isDefault }
            if a.element.createdAt != b.element.createdAt { return a.element.createdAt < b.element.createdAt }
            return a.offset < b.offset
        }.map(\.element)
        return base.enumerated().sorted { a, b in
            let x = a.element.order >= 0 ? a.element.order : Int.max
            let y = b.element.order >= 0 ? b.element.order : Int.max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }
}

/// The synced roster is a catalog, not a mandate (owner 2026-10-27).
enum ProfileRoster {
    /// The heading between "From your other devices" and the manual form in Add
    /// Profile (owner 2026-11-12): a suggestion row's role menu sat right above
    /// the form's Role radios, so the role looked chosen twice.
    static let manualFormHeading = "Or sign in as another Dispatcharr user"

    /// The divider and that heading show only when suggestion rows are shown
    /// directly above a manual form; with no suggestions nothing changes.
    static func showsManualFormHeading(suggestionRows: Int, formFollows: Bool) -> Bool {
        suggestionRows > 0 && formFollows
    }

    struct Plan: Equatable, Sendable {
        var merge: [ProfileRow]
        var available: [ProfileRow]
    }

    static func plan(_ rows: [ProfileRow], _ localUsernames: [String]) -> Plan {
        let have = Set(localUsernames.map { $0.lowercased() })
        return Plan(merge: rows.filter { have.contains($0.username.lowercased()) },
                    available: rows.filter { !have.contains($0.username.lowercased()) })
    }

    static func suggestions(_ rows: [ProfileRow], _ localUsernames: [String]) -> [ProfileRow] {
        var seen = Set<String>()
        let distinct = plan(rows, localUsernames).available.filter { seen.insert($0.username.lowercased()).inserted }
        return distinct.sorted { a, b in
            let x = a.order >= 0 ? a.order : Int.max, y = b.order >= 0 ? b.order : Int.max
            return x != y ? x < y : a.username.lowercased() < b.username.lowercased()
        }
    }

    /// A manual add ("Enter details" or an API key) of a user the synced
    /// roster already offers (review finding A2): the row to finish it with
    /// as a roster add, matched like the suggestions (the username, ignoring
    /// case). A plain add would stamp the row now with no PIN and the picked
    /// role, and the next push would drop that profile's PIN and Child role
    /// on every device. Nil: a plain add.
    static func rowForManualAdd(_ username: String, rows: [ProfileRow], localUsernames: [String]) -> ProfileRow? {
        let u = username.trimmingCharacters(in: .whitespaces).lowercased()
        guard !u.isEmpty else { return nil }
        return suggestions(rows, localUsernames).first { $0.username.lowercased() == u }
    }

    /// Undoing a fresh add (onboarding or Settings Remove, or Cancel on the
    /// "PIN Required" step after an add while a Child exists), follow-up A1:
    /// a roster add is removed on this device only, with no tombstone and no
    /// roster change, so its row is offered again under "From your other
    /// devices". A plain add keeps [plainWrites], today's behavior on that path.
    /// A profile added while the playlist's roster sync was paused counts the
    /// same ([pauseAdd]): the device could not tell whether that user has a
    /// roster row, and a tombstone sent once the pause ends could delete that
    /// person's profile on every synced device.
    static func undoWritesTombstone(rosterAdd: Bool, pauseAdd: Bool = false, plainWrites: Bool) -> Bool {
        rosterAdd || pauseAdd ? false : plainWrites
    }

    /// Cancel on "PIN Required" (follow-up 7): only the profiles added in the
    /// action that opened the step are removed. Every other pending add, such
    /// as one from a setup handoff, stays exactly as it was, still waiting for its PIN.
    static func pinCancelDrops(pending: [String], addedInAction: Set<String>) -> [String] {
        pending.filter { addedInAction.contains($0) }
    }

    static func applyRow(_ p: DispatcharrProfile, _ r: ProfileRow) -> DispatcharrProfile {
        var out = p
        if !r.displayName.trimmingCharacters(in: .whitespaces).isEmpty { out.displayName = r.displayName }
        if let role = ProfileRole.fromWire(r.role) { out.role = role }
        if r.order >= 0 { out.order = r.order }
        if r.avatar != nil { out.avatar = AvatarCatalog.normalize(r.avatar) }
        if out.userId == 0 && r.userId > 0 { out.userId = r.userId }
        return out
    }

    static func isStripped(_ displayName: String, _ username: String, _ avatar: AvatarSpec?) -> Bool {
        let blank = displayName.trimmingCharacters(in: .whitespaces).isEmpty
        return (blank || displayName.caseInsensitiveCompare(username) == .orderedSame) && (avatar == nil || avatar == AvatarSpec())
    }

    static func isStripped(_ r: ProfileRow) -> Bool { isStripped(r.displayName, r.username, r.avatar) }

    private static func ifBlank(_ s: String, _ alt: String) -> String {
        s.trimmingCharacters(in: .whitespaces).isEmpty ? alt : s
    }

    static func guardFreshRosterAdd(_ out: ProfileRow, prev: ProfileRow?, freshRosterAdd: Bool) -> ProfileRow? {
        guard freshRosterAdd, let prev, isStripped(out), !isStripped(prev) else { return nil }
        var o = out
        o.displayName = ifBlank(prev.displayName, out.displayName)
        o.avatar = prev.avatar ?? out.avatar
        o.order = prev.order >= 0 ? prev.order : out.order
        return o
    }

    static func guardUncustomized(_ out: ProfileRow, prev: ProfileRow?, customized: Bool) -> ProfileRow? {
        guard !customized, let prev, !isStripped(prev) else { return nil }
        var next = out
        next.displayName = ifBlank(prev.displayName, out.displayName)
        next.avatar = prev.avatar ?? out.avatar
        return next == out ? nil : next
    }

    static func adoptUncustomized(localName: String, localAvatar: AvatarSpec?, customized: Bool, _ r: ProfileRow) -> (String, AvatarSpec?)? {
        if customized || isStripped(r) { return nil }
        let name = ifBlank(r.displayName, localName)
        let avatar = r.avatar.map { AvatarCatalog.normalize($0) } ?? localAvatar
        if name == localName && avatar == localAvatar { return nil }
        return (name, avatar)
    }

    enum Repair: Sendable { case none, resendLocal, applyServer }

    static let STRIPPED_WINDOW_S: Int64 = 600

    static func repair(localName: String, localAvatar: AvatarSpec?, localAt: Int64, _ r: ProfileRow) -> Repair {
        let serverStripped = isStripped(r)
        let localStripped = isStripped(localName, r.username, localAvatar)
        if serverStripped && !localStripped && localAt > 0 && r.updatedAt > localAt && r.updatedAt - localAt <= STRIPPED_WINDOW_S {
            return .resendLocal
        }
        if localStripped && !serverStripped && localAt >= r.updatedAt { return .applyServer }
        return .none
    }
}

// MARK: - Snapshot stamps

struct SnapshotStamp: Equatable, Sendable {
    var userId: Int
    var assignment: String

    func encode() -> String { "\(userId)|\(SnapshotStaleness.normalize(assignment))" }

    static func decode(_ raw: String?) -> SnapshotStamp? {
        guard let p = raw?.split(separator: "|", omittingEmptySubsequences: false), p.count == 2, let u = Int(p[0]) else { return nil }
        return SnapshotStamp(userId: u, assignment: String(p[1]))
    }
}

enum SnapshotStaleness {
    static func normalize(_ ids: String) -> String {
        var seen = Set<Int>()
        return ids.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }.sorted().map(String.init).joined(separator: ",")
    }

    static func reason(_ stamp: SnapshotStamp?, currentUserId: Int, currentAssignment: String) -> String? {
        guard let stamp else { return "no stamp" }
        if currentUserId <= 0 { return "user id unknown" }
        if stamp.userId != currentUserId { return "user id \(stamp.userId) != \(currentUserId)" }
        let a = normalize(stamp.assignment), b = normalize(currentAssignment)
        if a != b { return "channel profiles \(a.isEmpty ? "All" : a) -> \(b.isEmpty ? "All" : b)" }
        return nil
    }
}

// MARK: - Refused profile actions (owner 2026-11-12, device testing)

/// A refused profile action shows as a dialog, never as small red footer
/// text users miss: the action's existing title, the reason word for word,
/// and one button, "OK". No other new copy.
struct ProfileRefusal: Equatable, Sendable {
    let title: String
    let message: String

    static let okLabel = "OK"

    /// nil when there is no reason (the flow simply closed).
    static func make(title: String, reason: String?) -> ProfileRefusal? {
        guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ProfileRefusal(title: title, message: reason)
    }
}

/// The existing titles of the profile actions, for their refusal dialogs.
enum ProfileActionTitle {
    static let role = "Role"
    static let removePin = "Remove PIN"
    static let resetPin = "Reset PIN"
    static let removeProfile = "Remove Profile"
    static let avatar = "Set Avatar"
    static let rename = "Rename"
    static let channelProfiles = "Channel Profiles"
    static let switchProfile = "Switch Profile"
    static let addProfile = "Add Profile"
    static let removeDeviceAdminPin = "Remove Device Admin PIN"
    static let moveUp = "Move Up"
    static let moveDown = "Move Down"
    static let profiles = "Profiles"

    static func setPin(hasPin: Bool) -> String { hasPin ? "Change PIN" : "Set PIN" }
    static func deviceAdminPin(has: Bool) -> String { has ? "Change Device Admin PIN" : "Set Device Admin PIN" }
}

// MARK: - Launch lock (security fix 2026-11-12)

/// While the launch PIN gate (or the Apple TV launch picker) is up, the app is
/// locked: nothing is usable until the PIN passes. Every modal prompt (the
/// rejected-key prompt and what it opens, the sync offers, "data is missing",
/// What's New, a Child's sign-in form) waits until the lock is gone, so none can
/// be presented first and keep the gate off screen, and none is reachable
/// through it.
enum LaunchLockRules {
    static func locked(gateArmed: Bool, pickerUp: Bool) -> Bool { gateArmed || pickerUp }

    /// A modal prompt may be presented now.
    static func promptMayShow(gateArmed: Bool, pickerUp: Bool) -> Bool { !locked(gateArmed: gateArmed, pickerUp: pickerUp) }

    /// The gate is on screen when every foreground scene shows it; otherwise it is presented again.
    static func gateNeedsPresenting(locked: Bool, scenes: Int, scenesShowingGate: Int) -> Bool {
        locked && scenesShowingGate < max(scenes, 1)
    }

    /// Apple TV: the lock's screen leaves without an animation, so no
    /// transition is still running when the next screen presents (device log
    /// 2026-11-12: the "Setting Up" cover was presented 55 ms after the PIN
    /// passed, while the lock's screen was still animating away).
    static let lockDismissAnimated = false

    /// The lock lives in its own window above the app, on Apple TV as on
    /// iPhone and iPad. Over the main screen, never in place of it: a
    /// full-screen presentation took the main screen out of the window, so it
    /// was first laid out when the PIN passed, in front of the user (device
    /// log 2026-11-12: the preview banner's art stepped 126, 237, 394, 539,
    /// 394 right after the PIN). And not a presentation the app owns: one
    /// over the loading screen went away with it when the loading screen was
    /// dismissed, and the guide was shown and focused for 0.6 s before the PIN
    /// (device log 2026-11-13 10:59:39).
    static let lockInOwnWindow = true

    /// What a screen beneath the lock may do: nothing while it is up (no focus,
    /// no touch, nothing for VoiceOver), and exactly what it did before once
    /// it passes.
    static func beneath(locked: Bool, wasInteractive: Bool, wasAccessibilityHidden: Bool)
        -> (interactive: Bool, accessibilityHidden: Bool) {
        locked ? (false, true) : (wasInteractive, wasAccessibilityHidden)
    }

    /// A cover closed by its state can still end up on screen, frozen, when it
    /// was presented while another screen was leaving (device log 2026-11-12:
    /// "Setting Up" stayed on "Loading EPG" after its state went false, and
    /// Skip, which only sets that state, could not close it). It is closed when
    /// its state has said closed for a moment (never racing the cover's own
    /// close), it is on screen, and nothing is shown over it.
    static func closesStrayCover(stateOpen: Bool, onScreen: Bool, coveredByAnother: Bool, closedFor: Double) -> Bool {
        !stateOpen && onScreen && !coveredByAnother && closedFor >= strayCoverGrace
    }

    /// How long a cover's state must have been false before it counts as stray (seconds).
    static let strayCoverGrace: Double = 0.5

    /// When to look for a stray cover after its state went false (seconds): it
    /// can finish presenting after the close.
    static let strayCoverChecks: [Double] = [0.6, 1.5, 3.0]
}

// MARK: - Live TV landing group (Android dd2bb36f)

/// Where Live TV lands at launch, on a profile switch, and on a playlist add or
/// switch: the pinned Default Group when it resolves (a group shown on this
/// playlist, or a collection), else All (the fallback). The group already on
/// screen is never kept. An "All" pin is stored as "" and lands on All.
enum LiveTVLanding {
    static func group(pin: String, shown: [String], fallback: String) -> String {
        let p = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty && (shown.contains(p) || p.hasPrefix("collection:")) { return p }
        return fallback
    }

    /// The log line for one landing decision.
    static func logLine(reason: String, group: String, pin: String) -> String {
        "[GROUPS] \(reason) landing group=\(group) (default=\(pin.isEmpty ? "unset" : "set"))"
    }
}

// MARK: - What's New (owner 2026-11-12)

/// What's New on every platform: what each way out does, where Apple TV focus
/// starts, and when the list's top edge fades under the pinned header.
enum WhatsNewRules {
    enum Exit: Equatable {
        /// This version is marked seen and What's New closes (the next release shows it again).
        case markSeenAndClose
        /// Never again on this device, then it closes.
        case disableAndClose
    }

    /// Menu on Apple TV is the same close as the swipe down on iPhone and iPad.
    static let onMenu: Exit = .markSeenAndClose
    static let onSwipeDown: Exit = .markSeenAndClose
    static let onNeverShowAgain: Exit = .disableAndClose

    enum Focus: Hashable {
        case bullet(Int)
        case neverShowAgain
    }

    /// Apple TV: focus goes inside What's New as it appears, never nothing
    /// (device log 2026-11-12: the cover sat with nothing focused until the
    /// remote was touched, and Menu reaches the cover's close only through a
    /// focused view inside it).
    static func initialFocus(bulletCount: Int) -> Focus {
        bulletCount > 0 ? .bullet(0) : .neverShowAgain
    }

    /// The top edge of the list fades (about one line) only once it has
    /// scrolled away from the top, so at rest the first line is not faded.
    static func fadeActive(scrolledBy offset: Double) -> Bool { offset > 0.5 }
}

// MARK: - PIN wording (owner 2026-11-12, byte-identical with Android)

/// Every PIN prompt and line, with two terms used everywhere: "profile PIN" (a
/// PIN on one profile) and "Device Admin PIN" (always in full, never "Admin PIN"
/// alone or "device PIN"). `name` is the profile's display name as the profile
/// list shows it. RoleRules.KEEP_PIN_REASON and the reset refusal live with
/// their rules.
enum PinCopy {
    /// The Admin pads (Manage Profiles gate, role change away from Child, the
    /// Apple TV picker's Add Profile) and the refusals behind them.
    static let adminPad = "Enter an Admin or Standard profile PIN, or the Device Admin PIN"
    /// The gate sentence on a Child's Manage Profiles page.
    static let manageGate = "To switch or add profiles, enter an Admin or Standard profile PIN, or the Device Admin PIN."
    static func removeChild(_ name: String) -> String {
        "Enter an Admin or Standard profile PIN, or the Device Admin PIN, to remove \(name)"
    }
    /// The Device Admin PIN row's subtitle, everywhere the row shows.
    static let deviceAdminRow = "Lets a parent leave a Child profile and manage profiles on this device. Separate from profile PINs. Never synced."
    /// The Manage Profiles row in a Child's Settings.
    static let manageProfilesRow = "Switch or add profiles (PIN required)"
    /// Onboarding "Who is this profile for?".
    static let onboardingChildNote = "Pick Child and you'll set a Device Admin PIN next. A parent uses it to leave the Child profile on this device. It is never synced."
    static func userQr(_ name: String) -> String { "Enter the PIN for \(name), or the Device Admin PIN, to show this code" }
    static let childRole = "Sees only its own content and basic settings. Leaving it needs an Admin or Standard profile PIN, or the Device Admin PIN."
    /// PIN Required when no PIN can leave a Child.
    static let noWayOut = "Leaving a Child profile needs an Admin or Standard profile PIN, or the Device Admin PIN. Set one first."
    static func setPin(_ name: String) -> String { "Set PIN for \(name)" }
    static func changePin(_ name: String) -> String { "Change PIN for \(name)" }
    static func confirmPin(_ name: String) -> String { "Confirm PIN for \(name)" }
    static let confirmDeviceAdminPin = "Confirm Device Admin PIN"
    static func currentPin(_ name: String) -> String { "Enter the current PIN for \(name)" }
    static func resetActor(_ name: String) -> String { "Enter your profile PIN to reset the PIN for \(name)" }
    static let deviceAdminOnlyWayOut = "The Device Admin PIN is the only way to leave a Child profile on this device, so it stays while any profile is a Child."
    static func pinType(_ name: String) -> String { "PIN type for \(name)" }
    static let deviceAdminPinType = "Device Admin PIN type"
    static func removePin(_ name: String) -> String { "Remove PIN for \(name)" }
    /// A switch refused without a PIN pass.
    static func enterPinFor(_ name: String) -> String { "Enter the PIN for \(name)" }
    static let pinLength = "Use 4 to 6 numbers or directions."
}
