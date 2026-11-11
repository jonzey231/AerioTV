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
    static let KEEP_PIN_REASON = "While a Child profile exists, Admin and Standard profiles keep a PIN."

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
        return .denied("Set a PIN on this profile first.")
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
    static func undoWritesTombstone(rosterAdd: Bool, plainWrites: Bool) -> Bool { rosterAdd ? false : plainWrites }

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
