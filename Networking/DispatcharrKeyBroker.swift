//
//  DispatcharrKeyBroker.swift
//  Aerio
//
//  The app side of the rejected-key gate (pure logic in
//  DispatcharrRequestGate.swift). Android twins: DispatcharrAuthBroker.kt
//  (fd145f3d) and DispatcharrKeyRecheck.kt (417efa8d).
//
//  - `DispatcharrKeyBroker`: on a 401 from an API-key call, one probe tells
//    a rejected KEY apart from an endpoint-specific 401 for a key that still
//    works, and only proof holds the key: a key-only playlist at once, a
//    password playlist only once its silent re-login was refused too.
//  - `DispatcharrKeyRecheck`: lets a held key recover on its own, slowly,
//    while the app is in the foreground (owner 2026-11-09: "We don't want to
//    just block access but we don't want constant retries that force a
//    server-side block from repeated attempts either.").
//

import Foundation
import SwiftData

enum DispatcharrKeyBroker {
    /// What the broker needs to know about the playlist a key belongs to.
    struct PlaylistInfo: Sendable {
        let id: UUID
        let name: String
        let baseURL: String
        let username: String
        /// Username and password saved here: a silent re-login can re-mint the key.
        /// Any playlist with both stored counts, whatever its credential type
        /// (older playlists carry an empty type that reads as API Key).
        let hasPassword: Bool
        let authMode: DispatcharrAuthHeaderMode
        let userAgent: String
    }

    // MARK: Playlist lookup (installed by RootView)

    @MainActor private static var container: ModelContainer?

    /// Install the SwiftData lookup. Called once from RootView.
    @MainActor static func install(container: ModelContainer) {
        Self.container = container
    }

    /// The saved Dispatcharr playlist that uses `key` (its own key or the
    /// active profile's), preferring `serverID`. Keychain reads happen here,
    /// on a 401 path only, never on a steady-state request.
    /// A key a silent re-login just read from the account: EXACTLY one request
    /// (/api/core/version/, past the rejected-key gate, in the playlist's header
    /// shape) decides whether it may be stored and sent. False only when the
    /// server refused it; no answer counts as usable (DispatcharrRelogin.outcome).
    static func mintedKeyRefused(_ key: String, serverID: UUID, baseURL: String, userAgent: String) async -> Bool {
        let mode = await MainActor.run { headerMode(serverID: serverID) } ?? .xapikey
        let probe = await DispatcharrAPI(baseURL: baseURL, auth: .apiKey(key), userAgent: userAgent, authMode: mode).probeApiKeyOnce()
        switch probe {
        case .rejected:
            return true
        case .accepted(let m):
            DispatcharrRequestGate.shared.noteKeyAccepted(key, mode: m.rawValue)
            return false
        case .unknown:
            return false
        }
    }

    @MainActor private static func headerMode(serverID: UUID) -> DispatcharrAuthHeaderMode? {
        guard let container else { return nil }
        let all = (try? container.mainContext.fetch(FetchDescriptor<ServerConnection>())) ?? []
        return all.first { $0.id == serverID }?.dispatcharrHeaderMode
    }

    @MainActor static func playlist(forKey key: String, serverID: UUID?) -> PlaylistInfo? {
        guard let container else { return nil }
        let ctx = container.mainContext
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let all = ((try? ctx.fetch(FetchDescriptor<ServerConnection>())) ?? [])
            .filter { !$0.isGone && $0.type == .dispatcharrAPI }
        func uses(_ s: ServerConnection) -> Bool {
            s.baseApiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
                || s.effectiveApiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
        let match = all.first { $0.id == serverID && uses($0) } ?? all.first { uses($0) }
        guard let s = match else { return nil }
        let hasPassword = Self.hasStoredPassword(s)
        return PlaylistInfo(id: s.id, name: s.name, baseURL: s.effectiveBaseURL, username: s.username,
                            hasPassword: hasPassword, authMode: s.dispatcharrHeaderMode,
                            userAgent: s.effectiveUserAgent)
    }

    /// A username and a password saved for the playlist (Keychain): what
    /// silentRebootstrapApiKey needs. 2026-11-10: this required the
    /// usernamePassword credential type, so a playlist added before v1.7
    /// (empty type) with a saved password was held and prompted on a
    /// rotated key instead of re-signing in like Android.
    @MainActor static func hasStoredPassword(_ s: ServerConnection) -> Bool {
        !s.username.trimmingCharacters(in: .whitespaces).isEmpty && !s.effectivePassword.isEmpty
    }

    /// Who can re-mint `key` after the server refused it: the request's own
    /// playlist when it carried a username, else the saved playlist that
    /// uses the key and has a stored password. nil = nobody (hold).
    @MainActor static func reloginTarget(key: String, serverID: UUID?,
                                         savedUsername: String?) -> (id: UUID, username: String)? {
        if let sid = serverID, let u = savedUsername, !u.isEmpty { return (sid, u) }
        guard let info = playlist(forKey: key, serverID: serverID),
              DispatcharrRequestGate.afterRejectedKey(
                hasStoredPassword: info.hasPassword,
                loginRefused: DispatcharrLoginGate.shared.isRejected(serverID: info.id)) == .relogin
        else { return nil }
        return (info.id, info.username)
    }

    /// A key the probe proved rejected: iCloud's key for its playlist comes
    /// first (no network), before a silent re-login or the hold. iCloud carries
    /// the playlist's own key only: never for a profile's key (Android fc04722f).
    @MainActor static func adoptCloudKey(replacing key: String, serverID: UUID?) -> String? {
        guard profileIdentity(forKey: key, serverID: serverID) == nil,
              let info = playlist(forKey: key, serverID: serverID) else { return nil }
        return SyncManager.shared.adoptCloudApiKey(playlistID: info.id, rejectedKey: key)
    }

    /// The non-default profile whose own key [key] is (the active profile's
    /// request overlay), or nil for the playlist's own key. A profile's key
    /// re-signs in only as that profile and is held per identity.
    @MainActor static func profileIdentity(forKey key: String, serverID: UUID?) -> DispatcharrIdentity? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let info = playlist(forKey: trimmed, serverID: serverID),
              let o = ProfileOverlay.values(info.id.uuidString),
              o.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return nil }
        return DispatcharrIdentity(playlistID: info.id.uuidString, profileID: o.profileId)
    }

    /// A profile's own key proven rejected and not re-minted (no own password,
    /// or its own re-login refused or failed): hold THAT key for that profile.
    /// Requests and streams with it stop, the prompt names the profile, and
    /// nothing falls back to the playlist's credentials. True = held (the caller
    /// fails with `DispatcharrGateError.keyRejected`).
    @MainActor static func holdProfileKey(key: String, identity who: DispatcharrIdentity) -> Bool {
        let gate = DispatcharrRequestGate.shared
        if gate.isKeyRejected(key) { return true }
        guard let pid = who.profileID, let info = playlist(id: who.playlistID) else { return false }
        let ownPassword = ProfileManager.shared.hasOwnPassword(pid)
        let noKey = ownPassword && DispatcharrLoginGate.shared.foundNoKey(identity: who)
        if ownPassword {
            // A re-login that only failed (network, a switch while it waited) is not proof.
            guard DispatcharrLoginGate.shared.isRejected(identity: who) || noKey else { return false }
        }
        if gate.markKeyRejected(playlistID: who.playlistID, key: key, playlistName: info.name,
                                passwordToo: ownPassword && !noKey, noKey: noKey, baseURL: info.baseURL,
                                profileID: pid) {
            debugLog("[AUTH] API key for profile \(who) rejected by the server; holding its calls and streams locally "
                     + "until the profile signs in again (never the playlist's sign-in)"
                     + (noKey ? " (the account has no API key)" : ownPassword ? " (its re-login refused too)" : ""))
        }
        return true
    }

    @MainActor static func playlist(id: String) -> PlaylistInfo? {
        guard let container, let uuid = UUID(uuidString: id) else { return nil }
        let descriptor = FetchDescriptor<ServerConnection>(predicate: #Predicate { $0.id == uuid })
        guard let s = (try? container.mainContext.fetch(descriptor))?.first, !s.isGone else { return nil }
        let hasPassword = Self.hasStoredPassword(s)
        return PlaylistInfo(id: s.id, name: s.name, baseURL: s.effectiveBaseURL, username: s.username,
                            hasPassword: hasPassword, authMode: s.dispatcharrHeaderMode,
                            userAgent: s.effectiveUserAgent)
    }

    // MARK: 401 probe (single flight per key)

    private static let probes = SingleFlight<DispatcharrAPI.KeyProbe>()

    /// After a 401 from `api` (an `.apiKey` instance): is the key itself
    /// good? Concurrent 401s for one key share one probe; a key proven good
    /// in the last 60 s is not probed again.
    static func probe(after401 api: DispatcharrAPI, key: String) async throws -> DispatcharrAPI.KeyProbe {
        let gate = DispatcharrRequestGate.shared
        if gate.isKeyRejected(key) { return .rejected }
        if let raw = gate.recentlyAcceptedMode(key), let mode = DispatcharrAuthHeaderMode(rawValue: raw) {
            return .accepted(mode)
        }
        let hash = DispatcharrRequestGate.keyHash(key)
        let host = URL(string: api.baseURL)?.host ?? "?"
        let (result, mine) = try await probes.run(hash) { try await api.probeApiKeyShapes() }
        if mine {
            if case .accepted(let mode) = result { gate.noteKeyAccepted(key, mode: mode.rawValue) }
            debugLog("[AUTH] 401 on an API-key call to \(host); key probe: \(result.logName)")
        }
        return result
    }

    // MARK: Stream 401 (2026-11-10)

    /// A stream open (live or catch-up ingest, a Multiview tile, MKV VOD or
    /// DVR, the Cast proxy) answered 401 with an API key: the same steps an
    /// API call takes. One probe (single flight per key, shared with API
    /// calls); a rejected key with a stored password re-signs in silently
    /// and the stream opens once more with the new key; otherwise the key is
    /// held, the playlist prompts, and no stream opens with it again
    /// (StreamKeyGate.headersForOpen). Never a retry loop on a dead key.
    static func after401(streamHeaders headers: [String: String], serverID: UUID? = nil) async -> StreamKeyGate.After401 {
        guard let key = StreamKeyGate.apiKey(in: headers) else { return .unchanged }
        let gate = DispatcharrRequestGate.shared
        if let newer = gate.replacementKey(for: key) { return .retry(newKey: newer) }
        if gate.isKeyRejected(key) { return .held }
        guard let info = await MainActor.run(body: { playlist(forKey: key, serverID: serverID) }) else {
            debugLog("[AUTH] stream 401 with a key no saved playlist uses; no probe")
            return .unchanged
        }
        let api = DispatcharrAPI(baseURL: info.baseURL, auth: .apiKey(key), userAgent: info.userAgent, authMode: info.authMode)
        let probe: StreamKeyGate.Probe
        switch (try? await self.probe(after401: api, key: key)) ?? .unknown {
        case .accepted: probe = .accepted
        case .rejected: probe = .rejected
        case .unknown: probe = .unknown
        }
        var reloginTried = false
        var newKey: String?
        // A non-default profile's own key (Android fc04722f): its own re-login
        // only, never the playlist's password or iCloud key; else its key is held.
        if let who = await MainActor.run(body: { profileIdentity(forKey: key, serverID: info.id) }) {
            if probe == .rejected {
                reloginTried = await MainActor.run { ProfileManager.shared.hasOwnPassword(who.profileID ?? "") }
                newKey = await ProfileManager.shared.reloginProfile(who, rejectedKey: key)
                if let n = newKey, !n.isEmpty, n != key { gate.noteKeyReplaced(old: key, new: n) }
            }
            let outcome = StreamKeyGate.after401(probe: probe, reloginTried: reloginTried, newKey: newKey, oldKey: key)
            if outcome == .held { _ = await MainActor.run { holdProfileKey(key: key, identity: who) } }
            debugLog("[AUTH] stream 401 for profile \(who): probe=\(probe) -> \(outcome)")
            return outcome
        }
        if probe == .rejected,
           let cloudKey = await MainActor.run(body: { adoptCloudKey(replacing: key, serverID: info.id) }) {
            // iCloud's key: the open retries once with it (noteKeyReplaced is done).
            reloginTried = true
            newKey = cloudKey
        } else if probe == .rejected,
           let target = await MainActor.run(body: { reloginTarget(key: key, serverID: info.id, savedUsername: nil) }) {
            reloginTried = true
            newKey = await DispatcharrAPI.silentRebootstrapApiKey(serverID: target.id, baseURL: info.baseURL,
                                                                  username: target.username, userAgent: info.userAgent)
            if let n = newKey, !n.isEmpty, n != key { gate.noteKeyReplaced(old: key, new: n) }
            // The re-login's own key came back and is the one just refused: hold it.
            if newKey == key { DispatcharrLoginGate.shared.noteKeyRefused(serverID: target.id) }
        }
        let outcome = StreamKeyGate.after401(probe: probe, reloginTried: reloginTried, newKey: newKey, oldKey: key)
        if outcome == .held { _ = await holdIfProven(key: key, serverID: info.id, baseURL: info.baseURL) }
        let word: String = {
            switch outcome {
            case .retry(let n): return n == nil ? "key good, one retry" : "one retry with the new key"
            case .held: return "key held, playlist prompts, no further opens"
            case .unchanged: return "no answer, normal failure path"
            }
        }()
        debugLog("[AUTH] stream 401 for \(info.id.uuidString.prefix(8)): probe=\(probe) -> \(word)")
        return outcome
    }

    /// The probe proved the key rejected: hold it when that is the end of
    /// the road (key-only playlist, or a password playlist whose re-login
    /// was refused). True = the key is now held and the caller fails with
    /// `DispatcharrGateError.keyRejected`.
    static func holdIfProven(key: String, serverID: UUID?, baseURL: String) async -> Bool {
        let gate = DispatcharrRequestGate.shared
        if gate.isKeyRejected(key) { return true }
        // A profile's own key is held per identity, never as the playlist's.
        if let who = await MainActor.run(body: { profileIdentity(forKey: key, serverID: serverID) }) {
            return await MainActor.run { holdProfileKey(key: key, identity: who) }
        }
        guard let info = await MainActor.run(body: { playlist(forKey: key, serverID: serverID) }) else {
            debugLog("[AUTH] rejected API key belongs to no saved playlist; not held")
            return false
        }
        let passwordToo: Bool
        // A stored password that signed in on an account with no API key
        // ends the road too: re-signing in can never mint a key (2026-11-11).
        let noKey = info.hasPassword && DispatcharrLoginGate.shared.foundNoKey(serverID: info.id)
        // A re-login that signed in but whose key the server refused ends the road
        // too: re-signing in mints the same refused key (2026-11-12, Android parity).
        let keyRefused = info.hasPassword && DispatcharrLoginGate.shared.foundRefusedKey(serverID: info.id)
        if info.hasPassword {
            let loginRefused = DispatcharrLoginGate.shared.isRejected(serverID: info.id)
            guard loginRefused || noKey || keyRefused else { return false }
            passwordToo = loginRefused && !noKey
        } else {
            passwordToo = false
        }
        if gate.markKeyRejected(playlistID: info.id.uuidString, key: key, playlistName: info.name,
                                passwordToo: passwordToo, noKey: noKey, baseURL: info.baseURL) {
            debugLog("[AUTH] API key for \(info.id.uuidString.prefix(8)) rejected by the server; holding every API call "
                     + "for this playlist locally (no network) until Edit Playlist changes the key or credentials"
                     + (noKey ? " (the account has no API key)" : passwordToo ? " (re-login refused too)"
                        : keyRefused ? " (the key a re-login issued was refused too)" : ""))
        }
        return true
    }

    /// The probe found a header shape that works and differs from the one
    /// recorded: record it on the playlist(s) using this key.
    static func persistAuthMode(_ mode: DispatcharrAuthHeaderMode, key: String, serverID: UUID?) {
        Task { @MainActor in
            guard let container else { return }
            let ctx = container.mainContext
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let all = (try? ctx.fetch(FetchDescriptor<ServerConnection>())) ?? []
            var changed = false
            for s in all where !s.isGone && s.type == .dispatcharrAPI
                && (s.id == serverID || s.baseApiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed)
                && s.dispatcharrAuthMode != mode.rawValue {
                s.dispatcharrAuthMode = mode.rawValue
                changed = true
                debugLog("[AUTH] persisting auth mode .\(mode.rawValue) for \(s.id.uuidString.prefix(8))")
            }
            guard changed else { return }
            try? ctx.save()
            SyncManager.shared.pushServers(all.filter { !$0.isGone }, immediate: true)
        }
    }
}

extension DispatcharrAPI.KeyProbe {
    var logName: String {
        switch self {
        case .accepted(let m): return "accepted (\(m.rawValue))"
        case .rejected: return "rejected"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Held-key re-check

/// One probe 1, 5, and 15 minutes after the rejection, then every 30
/// minutes; also one when the app comes to the foreground and one on a user
/// refresh, at most one probe per key per 60 s across all of them; never
/// inside a 429 pause. Key-only playlist: ONE /api/core/version/ request.
/// Password playlist: one re-login through DispatcharrLoginGate. Accepted:
/// the hold and its prompt clear and `onRecovered` reloads the playlist and
/// On Demand. The timer runs only while the app is in the foreground.
@MainActor
final class DispatcharrKeyRecheck {
    static let shared = DispatcharrKeyRecheck()
    private init() {}

    private var loop: Task<Void, Never>?
    /// Playlist id whose held key just proved good again: reload it.
    var onRecovered: ((String) -> Void)?

    private static let idlePoll: TimeInterval = 60

    /// Scene active: start the timer and run one on-demand probe.
    func onForeground() {
        startLoop()
        probeAllOnDemand(reason: "foreground")
    }

    /// Scene background: the timer stops (it never keeps a suspended app busy).
    func onBackground() {
        loop?.cancel()
        loop = nil
    }

    /// A user refresh (pull to refresh, Refresh Playlist, Test Connection,
    /// On Demand refresh): one probe per held key, at most once a minute.
    func userRefresh() {
        probeAllOnDemand(reason: "user refresh")
    }

    private var gate: DispatcharrRequestGate { DispatcharrRequestGate.shared }

    private func probeAllOnDemand(reason: String) {
        for r in gate.allRechecks() where gate.claimOnDemand(r, extraBlockedUntil: loginBlockedUntil(r)) {
            Task { await self.runProbe(r, reason: reason) }
        }
    }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let gate = self.gate
                let next = gate.earliestScheduledAt(extraBlockedUntil: { self.loginBlockedUntil($0) })
                let now = gate.clock()
                let wait = next.map { min(max($0 - now, 1), Self.idlePoll) } ?? Self.idlePoll
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
                for r in gate.allRechecks() where gate.claimScheduled(r, extraBlockedUntil: self.loginBlockedUntil(r)) {
                    await self.runProbe(r, reason: "schedule #\(r.scheduledDone)")
                }
            }
        }
    }

    /// Password re-check: also wait out a login throttle park.
    nonisolated private func loginBlockedUntil(_ r: DispatcharrRequestGate.Recheck) -> TimeInterval {
        guard r.passwordToo else { return 0 }
        let secs = DispatcharrLoginGate.shared.serverParkedSeconds(baseURL: r.baseURL)
        return secs > 0 ? DispatcharrRequestGate.shared.clock() + TimeInterval(secs) : 0
    }

    private func runProbe(_ r: DispatcharrRequestGate.Recheck, reason: String) async {
        let id8 = r.playlistID.prefix(8)
        var accepted = false
        let info = DispatcharrKeyBroker.playlist(id: r.playlistID)
        // The playlist was deleted while its key was held (measured on the
        // simulator 2026-11-10: a re-check still went out for it): drop the
        // hold instead of probing for a playlist nobody has.
        guard info != nil else {
            debugLog("[AUTH] held key re-check for \(id8) (\(reason)): playlist removed; hold dropped")
            gate.finishProbe(r, accepted: false)
            gate.clearIdentity(r.identity)
            return
        }
        let outcome: String
        // A non-default profile's held key: its own re-login (own password), or
        // one key probe; never the playlist's password (Android fc04722f).
        if let pid = r.profileID {
            guard ProfileManager.shared.store.byId(pid) != nil else {
                debugLog("[AUTH] held key re-check for \(r.identity) (\(reason)): profile removed; hold dropped")
                gate.finishProbe(r, accepted: false)
                gate.clearIdentity(r.identity)
                return
            }
            if ProfileManager.shared.hasOwnPassword(pid) {
                let fresh = await ProfileManager.shared.reloginProfile(r.identity, rejectedKey: r.key)
                if let fresh { gate.noteKeyReplaced(old: r.key, new: fresh) }
                accepted = fresh != nil
                outcome = accepted ? "accepted (its own re-login issued a key)"
                    : DispatcharrLoginGate.shared.isRejected(identity: r.identity) ? "rejected (its login refused)" : "unknown"
            } else {
                let api = DispatcharrAPI(baseURL: r.baseURL, auth: .apiKey(r.key),
                                         userAgent: info?.userAgent ?? DeviceInfo.defaultUserAgent,
                                         authMode: info?.authMode ?? .xapikey)
                let probe = await api.probeApiKeyOnce()
                if case .accepted = probe { accepted = true }
                outcome = probe.logName
            }
        } else if let info, info.hasPassword {
            let fresh = await DispatcharrAPI.silentRebootstrapApiKey(serverID: info.id, baseURL: info.baseURL,
                                                                     username: info.username, userAgent: info.userAgent)
            if let fresh, fresh != r.key { DispatcharrRequestGate.shared.noteKeyReplaced(old: r.key, new: fresh) }
            // The re-login's key was checked before it came back (one request);
            // a key the server refused comes back as none and the hold stays.
            accepted = fresh != nil && fresh != r.key
            outcome = accepted ? "accepted (re-login issued a key)"
                : DispatcharrLoginGate.shared.isRejected(serverID: info.id) ? "rejected (login refused)"
                : DispatcharrLoginGate.shared.foundNoKey(serverID: info.id) ? "rejected (the account has no API key)"
                : DispatcharrLoginGate.shared.foundRefusedKey(serverID: info.id) ? "rejected (the key the re-login issued was refused)" : "unknown"
        } else {
            let api = DispatcharrAPI(baseURL: r.baseURL, auth: .apiKey(r.key),
                                     userAgent: info?.userAgent ?? DeviceInfo.defaultUserAgent,
                                     authMode: info?.authMode ?? .xapikey)
            let probe = await api.probeApiKeyOnce()
            if case .accepted = probe { accepted = true }
            outcome = probe.logName
        }
        debugLog("[AUTH] held key re-check for \(id8) (\(reason)): \(outcome)")
        gate.finishProbe(r, accepted: accepted)
        if accepted {
            debugLog("[AUTH] key for \(id8) accepted again; hold cleared, reloading")
            onRecovered?(r.playlistID)
        }
    }
}
