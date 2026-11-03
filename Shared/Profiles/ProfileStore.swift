//  ProfileStore.swift
//  Aerio
//
//  Device-local profile records, ported from the Android
//  core/profiles/DispatcharrProfile.kt ProfileStore, plus the per-profile
//  settings slots of AppPreferences (seedProfileSettings,
//  seedExistingProfilesOnce, deleteProfileScope).
//
//  A profile is one Dispatcharr USER on a Dispatcharr playlist. The default
//  profile's credential stays on the playlist (ServerConnection, never
//  duplicated here); a non-default profile keeps its own API key and
//  password in the Keychain through a ProfileSecretBox. The records are
//  small, so they live in UserDefaults like Android's SharedPreferences:
//  readable synchronously at launch, before any scoped read.
//
//  Pure: Foundation only, with the defaults and the secret box injected, so
//  Scripts/dsync-tests compiles this file directly. The Keychain box is in
//  ProfileManager.swift.

import Foundation

/// Where profile secrets live (API keys, passwords, PIN records, the device
/// PIN salt). The app passes the Keychain; the tests pass memory.
protocol ProfileSecretBox: AnyObject {
    func get(_ key: String) -> String?
    func set(_ value: String?, _ key: String)
}

final class MemorySecretBox: ProfileSecretBox {
    private var values: [String: String] = [:]
    init() {}
    func get(_ key: String) -> String? { values[key] }
    func set(_ value: String?, _ key: String) { values[key] = value }
}

final class ProfileStore {
    private let defaults: UserDefaults
    private let secrets: ProfileSecretBox

    /// Every playlist's profiles (Android `profiles` StateFlow).
    private(set) var profiles: [DispatcharrProfile] = []
    /// Called after every write (the manager republishes its state).
    var onChange: (() -> Void)?

    init(defaults: UserDefaults, secrets: ProfileSecretBox) {
        self.defaults = defaults
        self.secrets = secrets
        profiles = load()
    }

    static let KEY_PROFILES = "aerio.profiles.v1"
    static let KEY_ACTIVE = "aerio.profiles.active."
    static let KEY_LAST_PLAYLIST = "aerio.profiles.last_active_playlist"
    static let KEY_ASK = "aerio.profiles.ask_at_launch."
    static let SECRET_API_KEY = "aerio.profile.apikey."
    static let SECRET_PASSWORD = "aerio.profile.password."

    // MARK: Persistence

    private func load() -> [DispatcharrProfile] {
        guard let data = defaults.data(forKey: Self.KEY_PROFILES) else { return [] }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap(Self.decode)
    }

    private func save(_ list: [DispatcharrProfile]) {
        let arr = list.map(Self.encode)
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]) {
            defaults.set(data, forKey: Self.KEY_PROFILES)
        }
        profiles = list
        onChange?()
    }

    static func encode(_ p: DispatcharrProfile) -> [String: Any] {
        var o: [String: Any] = [
            "id": p.id, "playlistId": p.playlistId, "displayName": p.displayName, "username": p.username,
            "isDefault": p.isDefault, "userLevel": p.userLevel, "accountProfileIds": p.accountProfileIds,
            "createdAt": p.createdAt, "userId": p.userId, "order": p.order,
            "streamLimit": p.streamLimit, "hideAdultContent": p.hideAdultContent, "dvrAccess": p.dvrAccess,
            "catchupEnabled": p.catchupEnabled, "vodMoviesEnabled": p.vodMoviesEnabled,
            "vodSeriesEnabled": p.vodSeriesEnabled, "isStaff": p.isStaff, "isSuperuser": p.isSuperuser,
            "customProperties": p.customProperties, "capabilitiesFetchedAt": p.capabilitiesFetchedAt,
        ]
        if let r = p.role { o["role"] = r.wire }
        if let a = p.avatar { o["avatar"] = ["icon": a.icon, "color": a.color] }
        return o
    }

    static func decode(_ o: [String: Any]) -> DispatcharrProfile? {
        guard let id = o["id"] as? String, let pid = o["playlistId"] as? String else { return nil }
        func i(_ k: String, _ d: Int) -> Int { (o[k] as? NSNumber)?.intValue ?? d }
        func l(_ k: String) -> Int64 { (o[k] as? NSNumber)?.int64Value ?? 0 }
        func b(_ k: String, _ d: Bool) -> Bool { (o[k] as? NSNumber)?.boolValue ?? d }
        func s(_ k: String) -> String { o[k] as? String ?? "" }
        var p = DispatcharrProfile(id: id, playlistId: pid, displayName: s("displayName"), username: s("username"))
        p.isDefault = b("isDefault", false)
        p.userLevel = i("userLevel", 10)
        p.accountProfileIds = s("accountProfileIds")
        p.createdAt = l("createdAt")
        p.role = ProfileRole.fromWire(o["role"] as? String)
        p.userId = i("userId", 0)
        if let a = o["avatar"] as? [String: Any] {
            p.avatar = AvatarSpec(icon: a["icon"] as? String ?? AvatarCatalog.INITIAL, color: a["color"] as? String ?? "")
        }
        p.order = i("order", -1)
        p.streamLimit = i("streamLimit", 0)
        p.hideAdultContent = b("hideAdultContent", false)
        p.dvrAccess = s("dvrAccess")
        p.catchupEnabled = b("catchupEnabled", true)
        p.vodMoviesEnabled = b("vodMoviesEnabled", true)
        p.vodSeriesEnabled = b("vodSeriesEnabled", true)
        p.isStaff = b("isStaff", false)
        p.isSuperuser = b("isSuperuser", false)
        p.customProperties = s("customProperties")
        p.capabilitiesFetchedAt = l("capabilitiesFetchedAt")
        return p
    }

    // MARK: Reads

    /// Default first, then insertion; an explicit order wins (Android forPlaylist).
    func forPlaylist(_ playlistId: String) -> [DispatcharrProfile] {
        ProfileOrder.sorted(profiles.filter { $0.playlistId == playlistId })
    }

    func byId(_ id: String) -> DispatcharrProfile? { profiles.first { $0.id == id } }

    // MARK: Writes

    /// Persist [orderedIds] (every profile of [playlistId]) as positions 0..n-1.
    func setOrder(_ playlistId: String, _ orderedIds: [String]) {
        var pos: [String: Int] = [:]
        for (i, id) in orderedIds.enumerated() { pos[id] = i }
        save(profiles.map { p in
            guard p.playlistId == playlistId, let o = pos[p.id] else { return p }
            var c = p; c.order = o; return c
        })
    }

    func upsert(_ profile: DispatcharrProfile) {
        save(profiles.filter { $0.id != profile.id } + [profile])
    }

    func update(_ id: String, _ transform: (DispatcharrProfile) -> DispatcharrProfile) {
        save(profiles.map { $0.id == id ? transform($0) : $0 })
    }

    func remove(_ id: String) {
        guard let p = byId(id) else { return }
        save(profiles.filter { $0.id != id })
        setApiKey(id, nil)
        setPassword(id, nil)
        if activeProfileId(p.playlistId) == id { defaults.removeObject(forKey: Self.KEY_ACTIVE + p.playlistId) }
    }

    func removeForPlaylist(_ playlistId: String) {
        for p in profiles where p.playlistId == playlistId {
            setApiKey(p.id, nil)
            setPassword(p.id, nil)
        }
        save(profiles.filter { $0.playlistId != playlistId })
        defaults.removeObject(forKey: Self.KEY_ACTIVE + playlistId)
    }

    // MARK: Credentials (Keychain)

    /// A non-default profile's own API key; the default profile's is on the playlist.
    func apiKey(_ id: String) -> String? { secrets.get(Self.SECRET_API_KEY + id).flatMap { $0.isEmpty ? nil : $0 } }
    func setApiKey(_ id: String, _ key: String?) { secrets.set(key?.isEmpty == true ? nil : key, Self.SECRET_API_KEY + id) }
    func password(_ id: String) -> String? { secrets.get(Self.SECRET_PASSWORD + id).flatMap { $0.isEmpty ? nil : $0 } }
    func setPassword(_ id: String, _ pw: String?) { secrets.set(pw?.isEmpty == true ? nil : pw, Self.SECRET_PASSWORD + id) }

    // MARK: Active profile and launch

    /// Active profile id for [playlistId] on this device; nil = default.
    func activeProfileId(_ playlistId: String) -> String? { defaults.string(forKey: Self.KEY_ACTIVE + playlistId) }

    func setActiveProfileId(_ playlistId: String, _ profileId: String?) {
        if let profileId { defaults.set(profileId, forKey: Self.KEY_ACTIVE + playlistId) }
        else { defaults.removeObject(forKey: Self.KEY_ACTIVE + playlistId) }
        onChange?()
    }

    /// TV launch picker toggle ("Ask who is watching at launch"), per playlist. Default on.
    func askAtLaunch(_ playlistId: String) -> Bool {
        defaults.object(forKey: Self.KEY_ASK + playlistId) == nil ? true : defaults.bool(forKey: Self.KEY_ASK + playlistId)
    }

    func setAskAtLaunch(_ playlistId: String, _ on: Bool) { defaults.set(on, forKey: Self.KEY_ASK + playlistId) }

    /// Last active playlist id, so launch can restore the profile synchronously.
    var lastActivePlaylistId: String? {
        get { defaults.string(forKey: Self.KEY_LAST_PLAYLIST) }
        set { defaults.set(newValue, forKey: Self.KEY_LAST_PLAYLIST) }
    }
}

// MARK: - Per-profile settings

/// Android AppPreferences per-profile settings (2026-10-27). Android keeps
/// each scoped setting under "<key>@prof:<profileId>"; Apple's settings are
/// read straight from UserDefaults by @AppStorage everywhere, so the bare
/// keys hold the ACTIVE profile's values and every profile has a saved slot
/// that a switch swaps in and out. The scoped set is Android's exactly:
/// every setting Dispatcharr Sync carries (PROFILE_SETTING_KEYS, here the
/// DsyncSettingsMap entries Apple has) and the category color and bucket
/// families, plus group sort mode and order and Radio Mode by Default.
/// Favorites, recents, and the rest are not settings and are not here.
final class ProfileSettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    static let SLOT_PREFIX = "aerio.profileSettings."
    static let KEY_SEEDED = "aerio.profileSettings.seeded"
    /// Android KEY_GROUP_SORT_MODE, KEY_GROUP_ORDER, KEY_RADIO_MODE_BY_DEFAULT on Apple
    /// (DsyncLocal.groupModeKey, groupOrderKey, RadioModeSession.byDefaultKey).
    static let EXTRA_KEYS = ["channelGroupOrder", "channelGroupOrder.sortMode", "radioModeByDefault"]

    /// The Apple UserDefaults keys that are per profile, given the keys present now.
    static func scopedKeys(present: [String]) -> Set<String> {
        var out = Set(DsyncSettingsMap.ENTRIES.map(\.appleKey))
        out.formUnion(EXTRA_KEYS)
        for k in present where k.hasPrefix(DsyncSettingsValidator.COLOR_PREFIX) || k.hasPrefix(DsyncSettingsValidator.BUCKET_PREFIX) {
            out.insert(k)
        }
        return out
    }

    private func keysNow(_ slots: [[String: Any]] = []) -> Set<String> {
        var present = Array(defaults.dictionaryRepresentation().keys)
        for s in slots { present += s.keys }
        return Self.scopedKeys(present: present)
    }

    func slot(_ profileId: String) -> [String: Any]? { defaults.dictionary(forKey: Self.SLOT_PREFIX + profileId) }

    /// The live (bare) values of every scoped key; an absent key stays absent.
    func capture() -> [String: Any] {
        var out: [String: Any] = [:]
        for k in keysNow() { if let v = defaults.object(forKey: k) { out[k] = v } }
        return out
    }

    /// Save the live values as [profileId]'s slot (the outgoing profile of a switch).
    func saveLive(as profileId: String) { defaults.set(capture(), forKey: Self.SLOT_PREFIX + profileId) }

    /// Make [profileId]'s slot the live values. False (nothing changed) when it has no slot.
    @discardableResult
    func loadLive(from profileId: String) -> Bool {
        guard let s = slot(profileId) else { return false }
        for k in keysNow([s]) {
            if let v = s[k] { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) }
        }
        return true
    }

    /// A switch from [from] to [to]: the outgoing values are kept, the incoming ones go live.
    /// Returns whether [to] had a slot (false leaves the live values in place) and its key count.
    @discardableResult
    func swap(from: String?, to: String) -> (loaded: Bool, keys: Int) {
        guard from != to else { return (false, 0) }
        if let from { saveLive(as: from) }
        let loaded = loadLive(from: to)
        return (loaded, slot(to)?.count ?? 0)
    }

    /// Android seedProfileSettings: a new profile starts with the default
    /// profile's settings. [source] is the default profile's values (the live
    /// values when the default profile is active, else its slot).
    func seed(_ profileId: String, source: [String: Any]) {
        defaults.set(source, forKey: Self.SLOT_PREFIX + profileId)
        markSeeded([profileId])
    }

    /// Android seedExistingProfilesOnce: existing profiles get a slot once,
    /// never overwriting a value they already have.
    func seedExistingOnce(_ profileIds: [String], source: [String: Any]) -> Int {
        let done = Set(defaults.stringArray(forKey: Self.KEY_SEEDED) ?? [])
        let todo = profileIds.filter { !$0.isEmpty && !done.contains($0) }
        guard !todo.isEmpty else { return 0 }
        for id in todo {
            var s = slot(id) ?? [:]
            for (k, v) in source where s[k] == nil { s[k] = v }
            defaults.set(s, forKey: Self.SLOT_PREFIX + id)
        }
        markSeeded(todo)
        return todo.count
    }

    private func markSeeded(_ ids: [String]) {
        let done = Set(defaults.stringArray(forKey: Self.KEY_SEEDED) ?? []).union(ids)
        defaults.set(done.sorted(), forKey: Self.KEY_SEEDED)
    }

    /// Android deleteProfileScope: the removed profile's slot goes.
    func deleteScope(_ profileId: String) {
        defaults.removeObject(forKey: Self.SLOT_PREFIX + profileId)
        let done = (defaults.stringArray(forKey: Self.KEY_SEEDED) ?? []).filter { $0 != profileId }
        defaults.set(done, forKey: Self.KEY_SEEDED)
    }
}
