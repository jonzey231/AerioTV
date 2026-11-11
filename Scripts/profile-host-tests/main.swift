// Profile sign-ins after a server address change (Shared/Profiles/
// ProfileHostHold.swift, review finding A-APP-1, 2026-11-11): route-change
// detection, the same-server decision, the hold in front of every outbound
// use of a profile's sign-in, and the hold surviving a relaunch.

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL \(line): \(msg)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    check(a == b, "\(msg): expected \(b), got \(a)", line: line)
}

func freshDefaults(_ name: String) -> (UserDefaults, String) {
    let suite = "aerio.profile-host-tests.\(name).\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

func profile(_ id: String, _ playlist: String, _ user: String, isDefault: Bool = false) -> DispatcharrProfile {
    DispatcharrProfile(id: id, playlistId: playlist, displayName: user, username: user, isDefault: isDefault)
}

typealias R = PlaylistRoute

// MARK: - Route-change detection

do {
    func changed(_ ob: String, _ nb: String, _ ol: String = "", _ nl: String = "") -> Bool {
        R.changed(oldBase: ob, newBase: nb, oldLocal: ol, newLocal: nl)
    }
    check(changed("http://tv.example.com", "https://tv.example.com"), "scheme change is a route change")
    check(changed("https://tv.example.com", "https://tv.example.org"), "host change is a route change")
    check(changed("https://tv.example.com:8443", "https://tv.example.com:9443"), "port change is a route change")
    check(changed("http://tv.example.com", "http://tv.example.com:8080"), "an explicit non-default port is a route change")
    check(!changed("http://tv.example.com", "http://tv.example.com:80"), "the default port spelled out is the same route")
    check(!changed("https://tv.example.com", "https://tv.example.com:443/"), "https default port and a trailing slash")
    check(!changed("https://tv.example.com/dispatcharr", "https://tv.example.com/other/path"), "path-only change is not a route change")
    check(!changed("HTTPS://TV.Example.COM", "https://tv.example.com"), "scheme and host compare without case")
    check(!changed("tv.example.com:9191", "http://tv.example.com:9191"), "no scheme reads as http")
    check(!changed(" https://tv.example.com ", "https://tv.example.com"), "surrounding spaces ignored")
    check(changed("https://a.example", "https://a.example", "http://192.168.1.10:9191", "http://192.168.1.11:9191"), "local URL host change")
    check(changed("https://a.example", "https://a.example", "http://192.168.1.10:9191", "http://192.168.1.10:9192"), "local URL port change")
    check(changed("https://a.example", "https://a.example", "", "http://192.168.1.10:9191"), "local URL added")
    check(changed("https://a.example", "https://a.example", "http://192.168.1.10:9191", ""), "local URL removed")
    check(!changed("https://a.example", "https://a.example", "http://192.168.1.10:9191/x", "http://192.168.1.10:9191/y"), "local path-only change")
    eq(R.hostKey(""), "", "blank has no host")
    eq(R.hostKey("https://Tv.Example.com/dispatcharr/"), "https://tv.example.com:443", "host key form")
    eq(R.key(base: "https://a.example/x", local: "http://10.0.0.2:9191"), "https://a.example:443|http://10.0.0.2:9191", "route key")
    eq(R.hosts(base: "http://a.example", local: "http://a.example:80/p"), ["http://a.example:80"], "hosts without repeats")
    eq(R.hosts(base: "https://a.example", local: ""), ["https://a.example:443"], "hosts without blanks")
}

// MARK: - Where the check asks

do {
    let trusted = ["https://old.example:443", "http://192.168.1.10:9191"]
    eq(R.checkTargets(base: "https://new.example", local: "http://192.168.1.10:9191", effective: "https://new.example", trusted: trusted),
       ["https://new.example"], "a new server URL is checked; the unchanged local URL is not")
    eq(R.checkTargets(base: "https://old.example", local: "http://192.168.1.20:9191", effective: "https://old.example", trusted: trusted),
       ["http://192.168.1.20:9191"], "a new local URL is checked even when requests use the server URL now")
    eq(R.checkTargets(base: "https://new.example", local: "http://192.168.1.20:9191", effective: "https://new.example", trusted: trusted),
       ["https://new.example", "http://192.168.1.20:9191"], "both new: both checked")
    eq(R.checkTargets(base: "https://old.example/", local: "http://192.168.1.10:9191", effective: "http://192.168.1.10:9191", trusted: trusted),
       ["http://192.168.1.10:9191"], "back on the old addresses: the address in use now")
    eq(R.checkTargets(base: "https://new.example", local: "https://new.example:443/x", effective: "https://new.example", trusted: trusted),
       ["https://new.example"], "one host named twice is asked once")
}

// MARK: - The same-server decision

do {
    let me = DefaultIdentity(userId: 7, username: "admin")!
    typealias A = SameServerCheck.Answer
    eq(SameServerCheck.decide(expected: me, answers: [.user(DefaultIdentity(userId: 7, username: "admin")!)]), .lift,
       "same user id and username: lift")
    eq(SameServerCheck.decide(expected: me, answers: [.user(DefaultIdentity(userId: 8, username: "admin")!)]), .keep("different-user"),
       "different user id: hold")
    eq(SameServerCheck.decide(expected: me, answers: [.user(DefaultIdentity(userId: 7, username: "someone")!)]), .keep("different-user"),
       "same id, different username: hold")
    eq(SameServerCheck.decide(expected: nil, answers: [.user(me)]), .keep("no-record"), "no identity recorded before the change: hold")
    eq(SameServerCheck.decide(expected: me, answers: [.failed("network")]), .keep("network"), "check failed (network): hold")
    eq(SameServerCheck.decide(expected: me, answers: [.failed("rejected")]), .keep("rejected"), "check failed (key rejected): hold")
    eq(SameServerCheck.decide(expected: me, answers: []), .keep("no-address"), "nothing asked: hold")
    eq(SameServerCheck.decide(expected: me, answers: [.user(me), .failed("network")]), .keep("network"),
       "every address must answer: one unreachable keeps the hold")
    eq(SameServerCheck.decide(expected: me, answers: [.user(me), .user(me)]), .lift, "both addresses the same server: lift")
    check(DefaultIdentity(userId: 0, username: "admin") == nil, "no user id is no identity")
    check(DefaultIdentity(userId: 7, username: "  ") == nil, "no username is no identity")
    eq(DefaultIdentity(userId: 7, username: " admin ")?.username, "admin", "username trimmed")
    check(!SameServerCheck.ready(holdRoute: "https://new.example:443|", routeNow: "https://old.example:443|"),
          "a users/me before the new address is written never runs the check")
    check(SameServerCheck.ready(holdRoute: "https://new.example:443|", routeNow: "https://new.example:443|"),
          "the check runs once the new address is on the playlist")
}

// MARK: - The hold in front of every outbound use

do {
    let (ud, suite) = freshDefaults("hold")
    defer { ud.removePersistentDomain(forName: suite) }
    let secrets = MemorySecretBox()
    let store = ProfileStore(defaults: ud, secrets: secrets)
    let holds = ProfileHostHoldStore(defaults: ud)
    let pl = "PLAYLIST-A", other = "PLAYLIST-B"
    store.upsert(profile("def", pl, "admin", isDefault: true))
    store.upsert(profile("kid", pl, "kid"))
    store.upsert(profile("guest", pl, "guest"))
    store.upsert(profile("empty", pl, "nobody"))
    store.upsert(profile("elsewhere", other, "kid2"))
    store.setApiKey("kid", "K-KID"); store.setPassword("kid", "P-KID")
    store.setApiKey("guest", "K-GUEST")
    store.setApiKey("elsewhere", "K-ELSE"); store.setPassword("elsewhere", "P-ELSE")
    let signIns = ProfileSignIns(store: store, holds: holds)

    let who = ProfileHostHoldRules.toHold(store.forPlaylist(pl), hasStoredSignIn: signIns.hasStored)
    eq(Set(who), ["kid", "guest"], "a route change holds every non-default profile with a stored sign-in")

    holds.recordIdentity(pl, DefaultIdentity(userId: 1, username: "admin")!)
    let rec = holds.hold(pl, profileIds: who, trustedHosts: R.hosts(base: "https://old.example", local: ""),
                         route: R.key(base: "https://new.example", local: ""))
    eq(rec?.expected, DefaultIdentity(userId: 1, username: "admin"), "the hold keeps the identity recorded before the change")
    eq(rec?.trustedHosts, ["https://old.example:443"], "the hold keeps the hosts from before the change")
    check(holds.isHeld("kid") && holds.isHeld("guest"), "both held")
    check(!holds.isHeld("def") && !holds.isHeld("empty") && !holds.isHeld("elsewhere"), "default, no-sign-in, and other playlists are not held")

    for use in ProfileSignIns.Use.allCases {
        check(signIns.apiKey("kid", for: use) == nil, "held key never reaches \(use.rawValue)")
        check(signIns.password("kid", for: use) == nil, "held password never reaches \(use.rawValue)")
        check(signIns.apiKey("guest", for: use) == nil, "held key-only profile never reaches \(use.rawValue)")
        eq(signIns.apiKey("elsewhere", for: use), "K-ELSE", "another playlist's profile still reaches \(use.rawValue)")
        eq(signIns.password("elsewhere", for: use), "P-ELSE", "another playlist's password still reaches \(use.rawValue)")
    }
    eq(store.apiKey("kid"), "K-KID", "the Keychain keeps the held key (nothing to re-enter after a lift)")
    check(signIns.hasStored("kid"), "a held profile still counts as having a sign-in stored")

    // Frozen while held: a different user's users/me at the new address
    // never changes the record and never lifts, however often it answers.
    let stranger = DefaultIdentity(userId: 99, username: "stranger")!
    for round in 1...3 {
        check(!holds.recordIdentity(pl, stranger), "round \(round): recording is frozen while a profile is held")
        eq(holds.identity(pl), DefaultIdentity(userId: 1, username: "admin"), "round \(round): the record is unchanged")
        eq(holds.record(pl)?.expected, DefaultIdentity(userId: 1, username: "admin"), "round \(round): the expectation is unchanged")
        eq(SameServerCheck.decide(expected: holds.record(pl)?.expected, answers: [.user(stranger)]), .keep("different-user"),
           "round \(round): the check against the stranger keeps the hold")
        check(holds.isHeld("kid") && holds.isHeld("guest"), "round \(round): both still held")
    }

    // A second change while held: same expectation and hosts, the new route.
    holds.hold(pl, profileIds: [], trustedHosts: ["https://new.example:443"], route: R.key(base: "https://third.example", local: ""))
    eq(holds.record(pl)?.route, R.key(base: "https://third.example", local: ""), "a second change moves the hold's route")
    eq(holds.record(pl)?.trustedHosts, ["https://old.example:443"], "a second change keeps the hosts from before the first")
    eq(holds.record(pl)?.expected, DefaultIdentity(userId: 1, username: "admin"), "a second change keeps the first expectation")
    eq(holds.record(pl)?.profileIds, ["guest", "kid"], "a second change keeps the held profiles")

    // Nothing to hold, no hold yet: no record.
    check(holds.hold(other, profileIds: [], trustedHosts: [], route: "x") == nil, "no profiles to hold: no record")
    check(holds.record(other) == nil, "no record written")

    // Sign in again: that profile only.
    check(holds.lift(profileId: "kid"), "signing in lifts that profile")
    eq(signIns.apiKey("kid", for: .requestOverlay), "K-KID", "a lifted profile's key is usable again")
    check(signIns.apiKey("guest", for: .requestOverlay) == nil, "the other profile stays held")
    check(!holds.lift(profileId: "kid"), "lifting twice is a no-op")
    check(!holds.recordIdentity(pl, stranger), "one profile still held: recording stays frozen")
    eq(holds.identity(pl), DefaultIdentity(userId: 1, username: "admin"), "record unchanged while one is held")

    // The last held profile signs in again: recording resumes, and the new
    // address is the trusted one from then on.
    check(holds.lift(profileId: "guest"), "the last held profile signs in again")
    check(holds.record(pl) == nil, "no hold left")
    eq(signIns.apiKey("guest", for: .syncSession), "K-GUEST", "released")
    check(holds.recordIdentity(pl, stranger), "recording resumes once nothing is held")
    eq(holds.identity(pl), stranger, "the new address's account is recorded")

    // The same server: every profile tagged with the snapshot at once.
    holds.setTag("kid", .identity(stranger)); holds.setTag("guest", .identity(stranger))
    holds.hold(pl, profileIds: ["kid", "guest"], trustedHosts: [], route: "r2")
    eq(holds.record(pl)?.expected, stranger, "a later change expects the account recorded after the last lift")
    let both = holds.liftMatching(pl)
    eq(both.lifted, ["guest", "kid"], "the same-server lift releases every profile tagged with the snapshot")
    eq(both.kept, [], "none kept")
    check(holds.record(pl) == nil, "no hold left")
    eq(holds.liftMatching(pl).lifted, [], "nothing left to lift")
    check(holds.recordIdentity(pl, DefaultIdentity(userId: 1, username: "admin")!), "recording resumes after the same-server lift")

    // A merge moves the hold with the profiles.
    holds.hold(pl, profileIds: ["guest"], trustedHosts: [], route: "r")
    holds.move(from: pl, to: other)
    check(holds.record(pl) == nil && holds.record(other)?.profileIds == ["guest"], "merge moves the hold")
    holds.drop(other)
    check(!holds.isHeld("guest"), "drop removes the hold")

    // A held profile that is removed counts like one signed in again.
    holds.hold(pl, profileIds: ["kid"], trustedHosts: [], route: "r3")
    check(!holds.recordIdentity(pl, stranger), "frozen while the profile is held")
    holds.forgetProfile("kid")
    check(holds.tag("kid") == nil, "a removed profile's tag goes")
    check(holds.recordIdentity(pl, stranger), "removed: recording resumes")

    // Only deleting the playlist clears the recorded identity.
    holds.hold(pl, profileIds: ["kid"], trustedHosts: [], route: "r4")
    holds.forgetPlaylist(pl)
    check(holds.identity(pl) == nil && holds.record(pl) == nil, "a deleted playlist's identity and hold are gone")
    check(ProfileHostHoldStore(defaults: ud).identity(pl) == nil, "and stay gone after a relaunch")
}

// MARK: - The hold survives a relaunch

do {
    let (ud, suite) = freshDefaults("relaunch")
    defer { ud.removePersistentDomain(forName: suite) }
    let secrets = MemorySecretBox()
    let first = ProfileStore(defaults: ud, secrets: secrets)
    first.upsert(profile("def", "P", "admin", isDefault: true))
    first.upsert(profile("kid", "P", "kid"))
    first.setApiKey("kid", "K-KID"); first.setPassword("kid", "P-KID")
    let h1 = ProfileHostHoldStore(defaults: ud)
    h1.recordIdentity("P", DefaultIdentity(userId: 3, username: "admin")!)
    h1.recordIdentity("Q", DefaultIdentity(userId: 4, username: "other")!)
    let made = h1.hold("P", profileIds: ["kid"], trustedHosts: ["https://old.example:443", "http://10.0.0.2:9191"],
                       route: R.key(base: "https://new.example", local: "http://10.0.0.2:9191"))

    // Relaunch: new store objects over the same defaults and Keychain.
    let h2 = ProfileHostHoldStore(defaults: ud)
    let relaunched = ProfileSignIns(store: ProfileStore(defaults: ud, secrets: secrets), holds: h2)
    eq(h2.record("P"), made, "the hold reads back exactly")
    check(h2.isHeld("kid"), "still held after a relaunch")
    for use in ProfileSignIns.Use.allCases {
        check(relaunched.apiKey("kid", for: use) == nil && relaunched.password("kid", for: use) == nil,
              "a relaunch never sends a held sign-in (\(use.rawValue))")
    }
    eq(h2.identity("P"), DefaultIdentity(userId: 3, username: "admin"), "recorded identity reads back")
    eq(h2.identity("Q"), DefaultIdentity(userId: 4, username: "other"), "every playlist's identity reads back")
    eq(h2.tag("kid"), .identity(DefaultIdentity(userId: 3, username: "admin")!), "the tag the hold gave an untagged profile reads back")
    h2.setTag("kid2", .unknown)
    eq(ProfileHostHoldStore(defaults: ud).tag("kid2"), .unknown, "an unknown tag reads back as unknown")

    // A lift is persisted too.
    h2.lift(profileId: "kid")
    let h3 = ProfileHostHoldStore(defaults: ud)
    check(!h3.isHeld("kid") && h3.record("P") == nil, "a lift survives a relaunch")
    eq(ProfileSignIns(store: ProfileStore(defaults: ud, secrets: secrets), holds: h3).apiKey("kid", for: .profileSwitch), "K-KID",
       "after the lift the stored key is used again")
}

// MARK: - One change, end to end (pure)

do {
    let (ud, suite) = freshDefaults("flow")
    defer { ud.removePersistentDomain(forName: suite) }
    let holds = ProfileHostHoldStore(defaults: ud)
    let oldBase = "https://old.example", newBase = "https://new.example", local = "http://192.168.1.10:9191"
    holds.recordIdentity("P", DefaultIdentity(userId: 5, username: "owner")!)
    check(!R.changed(oldBase: oldBase, newBase: oldBase + "/dispatcharr", oldLocal: local, newLocal: local), "path edit: nothing runs")
    check(R.changed(oldBase: oldBase, newBase: newBase, oldLocal: local, newLocal: local), "host edit: hold")
    let rec = holds.hold("P", profileIds: ["kid"], trustedHosts: R.hosts(base: oldBase, local: local),
                         route: R.key(base: newBase, local: local))!
    eq(holds.tag("kid"), .identity(DefaultIdentity(userId: 5, username: "owner")!), "an existing profile is tagged with the record")
    // Before the write the playlist still reads the old address: no check.
    check(!SameServerCheck.ready(holdRoute: rec.route, routeNow: R.key(base: oldBase, local: local)), "old address: wait")
    // After the write: users/me at the new server URL only.
    check(SameServerCheck.ready(holdRoute: rec.route, routeNow: R.key(base: newBase, local: local)), "new address: check")
    let targets = R.checkTargets(base: newBase, local: local, effective: newBase, trusted: rec.trustedHosts)
    eq(targets, [newBase], "only the new address is asked")
    eq(SameServerCheck.decide(expected: rec.expected, answers: [.user(DefaultIdentity(userId: 5, username: "owner")!)]), .lift,
       "same server: lift")
    eq(SameServerCheck.decide(expected: rec.expected, answers: [.user(DefaultIdentity(userId: 2, username: "owner")!)]),
       .keep("different-user"), "someone else's server answering with the same username: hold")
    eq(holds.liftMatching("P").lifted, ["kid"], "same server: the profile is released")
}

// MARK: - SNAPSHOT: a users/me made as part of the change never updates the record

do {
    let (ud, suite) = freshDefaults("snapshot")
    defer { ud.removePersistentDomain(forName: suite) }
    let before = DefaultIdentity(userId: 1, username: "owner")!
    let newServer = DefaultIdentity(userId: 2, username: "stranger")!
    // Each path, in the order the app runs it: the change starts, the path's
    // own users/me at the new address answers, the hold is placed, the
    // address is written, and the check runs.
    for path in ["Edit Playlist validation before save", "host-change cleanup re-verify", "setup payload verify before commit"] {
        let holds = ProfileHostHoldStore(defaults: ud)
        holds.forgetPlaylist("P")
        check(holds.recordIdentity("P", before), "\(path): the record before the change")
        holds.setTag("kid", .identity(before))
        holds.beginChange("P")
        check(!holds.recordIdentity("P", newServer), "\(path): the change's own users/me is not recorded (no hold yet)")
        eq(holds.identity("P"), before, "\(path): record unchanged")
        let rec = holds.hold("P", profileIds: ["kid"], trustedHosts: ["http://127.0.0.1:18761"], route: "new")
        eq(rec?.expected, before, "\(path): the snapshot is the record from before the change")
        check(!holds.recordIdentity("P", newServer), "\(path): still not recorded while held")
        holds.endChange("P")
        check(!holds.recordIdentity("P", newServer), "\(path): after the change, still frozen while held")
        eq(SameServerCheck.decide(expected: holds.record("P")?.expected, answers: [.user(newServer)]), .keep("different-user"),
           "\(path): the new server never matches itself")
        check(holds.isHeld("kid"), "\(path): the profile stays held")
    }
    // A change with nothing to hold: nothing recorded during it; once it
    // ends, the new address is the trusted one.
    let holds = ProfileHostHoldStore(defaults: ud)
    holds.forgetPlaylist("Q")
    holds.recordIdentity("Q", before)
    holds.beginChange("Q")
    check(!holds.recordIdentity("Q", newServer), "nothing held: still not recorded during the change")
    check(holds.hold("Q", profileIds: [], trustedHosts: [], route: "new") == nil, "nothing to hold")
    holds.endChange("Q")
    check(holds.recordIdentity("Q", newServer), "after the change, with nothing held, the new address is trusted")
}

// MARK: - PER-PROFILE TAG: move away, add a profile there, move back

do {
    let (ud, suite) = freshDefaults("tags")
    defer { ud.removePersistentDomain(forName: suite) }
    let holds = ProfileHostHoldStore(defaults: ud)
    let a = DefaultIdentity(userId: 1, username: "owner")!    // the default account at server A
    let b = DefaultIdentity(userId: 9, username: "someone")!  // the default account at server B
    holds.recordIdentity("P", a)
    holds.backfillTags("P", profileIds: ["p1"])
    eq(holds.tag("p1"), .identity(a), "an existing profile gets the recorded identity the first time")
    holds.setTag("p1", .identity(a))

    // A to B: p1 held, snapshot A; B answers as someone else.
    holds.beginChange("P")
    holds.hold("P", profileIds: ["p1"], trustedHosts: [R.hostKey("https://a.example")], route: R.key(base: "https://b.example", local: ""))
    holds.endChange("P")
    eq(SameServerCheck.decide(expected: holds.record("P")?.expected, answers: [.user(b)]), .keep("different-user"), "B is not A")

    // p2 is added at B: its tag is B's live answer, never the frozen record.
    check(!holds.recordIdentity("P", b), "B's answer is not recorded while p1 is held")
    holds.setTag("p2", .identity(b))
    check(holds.backfillTags("P", profileIds: ["p2"]) == 0, "a tagged profile is never backfilled")

    // B back to A: p2 is held too; A answers as A.
    holds.beginChange("P")
    holds.hold("P", profileIds: ["p1", "p2"], trustedHosts: [R.hostKey("https://b.example")], route: R.key(base: "https://a.example", local: ""))
    holds.endChange("P")
    eq(holds.record("P")?.expected, a, "the snapshot is still A")
    eq(SameServerCheck.decide(expected: holds.record("P")?.expected, answers: [.user(a)]), .lift, "A is the same server as before")
    let r = holds.liftMatching("P")
    eq(r.lifted, ["p1"], "p1 (signed in at A) is released")
    eq(r.kept, ["p2"], "p2 (signed in at B) stays held: its key is for B")
    check(holds.isHeld("p2") && !holds.isHeld("p1"), "only p2 held")
    check(!holds.recordIdentity("P", a), "still frozen while p2 is held")

    // An unknown tag (the default account could not be read when it signed in) is never released by a check.
    holds.setTag("p3", .unknown)
    holds.hold("P", profileIds: ["p3"], trustedHosts: [], route: R.key(base: "https://a.example", local: ""))
    eq(holds.liftMatching("P").kept.sorted(), ["p2", "p3"], "unknown tags stay held")
    eq(ProfileHostHoldRules.liftable(held: ["x"], tags: { _ in .identity(a) }, snapshot: nil), [], "no snapshot: nothing released")
}

// MARK: - Rule 6: a held profile always gets the form with the line

do {
    let (ud, suite) = freshDefaults("pick")
    defer { ud.removePersistentDomain(forName: suite) }
    let secrets = MemorySecretBox()
    let store = ProfileStore(defaults: ud, secrets: secrets)
    let holds = ProfileHostHoldStore(defaults: ud)
    store.upsert(profile("pw", "P", "pwonly"))
    store.upsert(profile("gone", "P", "gone"))
    store.setPassword("pw", "P-ONLY")
    store.setApiKey("gone", "K-GONE")
    holds.hold("P", profileIds: ["pw", "gone"], trustedHosts: [], route: "r")
    store.setApiKey("gone", nil)   // the Keychain item went away while held
    let signIns = ProfileSignIns(store: store, holds: holds)
    check(signIns.apiKey("pw", for: .profileSwitch) == nil, "a password-only profile has no stored key")
    eq(ProfileHostHoldRules.onPick(isHeld: holds.isHeld("pw"), hasStoredSignIn: signIns.hasStored("pw")), .signInAgain,
       "held with no stored key: the form with the line")
    eq(ProfileHostHoldRules.onPick(isHeld: holds.isHeld("gone"), hasStoredSignIn: signIns.hasStored("gone")), .signInAgain,
       "held with nothing stored any more: the form with the line")
    eq(ProfileHostHoldRules.onPick(isHeld: false, hasStoredSignIn: false), .switchNow, "not held, nothing stored: as before")
    eq(ProfileHostHoldRules.onPick(isHeld: false, hasStoredSignIn: true), .switchNow, "not held: as before")
    eq(KeySignInCopy.hostChanged(playlistName: "Home"),
       "The server address for Home changed. Sign in again to use this profile.", "the line above the fields")
}

// MARK: - Roster sync paused while a profile is held (follow-up B13)

do {
    let (ud, suite) = freshDefaults("pause")
    defer { ud.removePersistentDomain(forName: suite) }
    let holds = ProfileHostHoldStore(defaults: ud)
    func paused(_ pid: String) -> Bool { holds.record(pid) != nil }   // ProfileManager.rosterSyncPaused
    holds.recordIdentity("P", DefaultIdentity(userId: 1, username: "owner")!)
    holds.setTag("kid", .identity(DefaultIdentity(userId: 1, username: "owner")!))
    check(!paused("P"), "nothing held: not paused")
    holds.hold("P", profileIds: ["kid"], trustedHosts: [], route: "new")
    check(paused("P") && holds.heldPlaylistIds == ["P"], "a held profile pauses the playlist's roster sync")

    // Push: the profiles category itself is never written; every other category still is.
    check(!DsyncRosterPause.writes(.profiles, paused: true), "while held, profiles is not written")
    for key in DsyncKey.allCases where key != .profiles {
        check(DsyncRosterPause.writes(key, paused: true), "while held, \(key.suffix) still syncs")
    }

    // A PUT of another category never carries local roster rows.
    let localRoster = DsyncV2.encodeCategory(nil, deviceId: "me", updatedAt: 1_794_000_000,
                                             data: DsyncObject([("rows", .array([.string("local roster row with a PIN hash")]))]))
    let fav = DsyncV2.encodeCategory(nil, deviceId: "me", updatedAt: 1_794_000_001, data: DsyncObject([("ids", .array([]))]))
    let stale = DsyncV2.encodeBucket(nil, deviceId: "me", appVersion: "t", updatedAt: 1, replace: [(.profiles, localRoster)])
    let sentNoServer = DsyncV2.encodeBucket(DsyncRosterPause.base(stale, serverHasBucket: false, paused: true),
                                            deviceId: "me", appVersion: "t", updatedAt: 2, replace: [(.favorites, fav)])
    let catsNoServer = sentNoServer[DsyncV2.CATEGORIES]?.asObject
    check(catsNoServer?[DsyncKey.profiles.suffix] == nil, "no server copy: profiles is left out, never the local rows")
    check(catsNoServer?[DsyncKey.favorites.suffix] != nil, "the other category goes out")
    // The server's copy (what this PUT's refresh read) goes back unchanged, whatever its value and type.
    for serverValue: DsyncJSON in [.object(DsyncV2.encodeCategory(nil, deviceId: "srv", updatedAt: 5, data: DsyncObject([("rows", .array([]))]))),
                                   .string("not an object")] {
        let server = DsyncObject([(DsyncV2.CATEGORIES, .object(DsyncObject([(DsyncKey.profiles.suffix, serverValue)])))])
        let sent = DsyncV2.encodeBucket(DsyncRosterPause.base(server, serverHasBucket: true, paused: true),
                                        deviceId: "me", appVersion: "t", updatedAt: 3, replace: [(.favorites, fav)])
        eq(sent[DsyncV2.CATEGORIES]?.asObject?[DsyncKey.profiles.suffix], serverValue, "the server's profiles value goes back unchanged")
    }

    // Pull: a pulled tombstone that would delete the held profile is not applied.
    let tomb = ProfileTombstone(username: "kid", removedAt: 1_794_000_100, userId: 5)
    check(ProfileTombstones.kills([tomb], "kid", 1_794_000_000), "the new server's tombstone would delete kid")
    check(!DsyncRosterPause.appliesPulledProfiles(paused: paused("P")), "while held, pulled rows and tombstones are not applied")

    // The hold clears (same server, or each held profile signed in or removed): as today.
    holds.liftMatching("P")
    check(!paused("P") && holds.heldPlaylistIds.isEmpty, "nothing held: resumed")
    check(DsyncRosterPause.appliesPulledProfiles(paused: paused("P")), "after the hold clears, pulled rows merge again")
    check(DsyncRosterPause.writes(.profiles, paused: paused("P")), "after the hold clears, the roster is written again")
    eq(DsyncRosterPause.base(stale, serverHasBucket: false, paused: paused("P")), stale, "not paused: the bucket is built as today")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
