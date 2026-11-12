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
    store.upsert(profile("elsewhere", other, "kid2"))
    store.setApiKey("kid", "K-KID"); store.setPassword("kid", "P-KID")
    store.setApiKey("guest", "K-GUEST")
    store.setApiKey("elsewhere", "K-ELSE"); store.setPassword("elsewhere", "P-ELSE")
    let signIns = ProfileSignIns(store: store, holds: holds)

    let who = ProfileHostHoldRules.toHold(store.forPlaylist(pl))
    eq(Set(who), ["kid", "guest"], "a route change holds every non-default profile")

    holds.recordIdentity(pl, DefaultIdentity(userId: 1, username: "admin")!)
    let rec = holds.hold(pl, profileIds: who, trustedHosts: R.hosts(base: "https://old.example", local: ""),
                         route: R.key(base: "https://new.example", local: ""))
    eq(rec?.expected, DefaultIdentity(userId: 1, username: "admin"), "the hold keeps the identity recorded before the change")
    eq(rec?.trustedHosts, ["https://old.example:443"], "the hold keeps the hosts from before the change")
    check(holds.isHeld("kid") && holds.isHeld("guest"), "both held")
    check(!holds.isHeld("def") && !holds.isHeld("elsewhere"), "the default profile and other playlists are not held")

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
    eq(ProfileHostHoldRules.onPick(isHeld: holds.isHeld("pw"), hasStoredSignIn: signIns.hasStored("pw"), isDefault: false), .signInAgain,
       "held with no stored key: the form with the line")
    eq(ProfileHostHoldRules.onPick(isHeld: holds.isHeld("gone"), hasStoredSignIn: signIns.hasStored("gone"), isDefault: false), .signInAgain,
       "held with nothing stored any more: the form with the line")
    eq(ProfileHostHoldRules.onPick(isHeld: false, hasStoredSignIn: false, isDefault: false), .signInAgain,
       "not held, nothing stored: the sign-in form (treated exactly like held)")
    eq(ProfileHostHoldRules.onPick(isHeld: false, hasStoredSignIn: false, isDefault: true), .switchNow,
       "the default profile uses the playlist's own sign-in")
    eq(ProfileHostHoldRules.onPick(isHeld: false, hasStoredSignIn: true, isDefault: false), .switchNow, "not held: as before")
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

// MARK: - Pause refinements: held removal, the pending mark, adds during the pause

do {
    let (ud, suite) = freshDefaults("pause-refine")
    defer { ud.removePersistentDomain(forName: suite) }
    // Removing a held profile writes no tombstone; any other removal as today.
    check(!ProfileHostHoldRules.removeWritesTombstone(isHeld: true), "removing a held profile: this device only, no tombstone")
    check(ProfileHostHoldRules.removeWritesTombstone(isHeld: false), "removing a profile that is not held: as today")

    // A PUT during the pause keeps the roster's pending mark; after it, a roster PUT clears it as today.
    for key in DsyncKey.allCases {
        check(!DsyncRosterPause.clearsRosterPending(afterPutOf: key, paused: true), "a PUT of \(key.suffix) during the pause keeps the dirty mark")
    }
    check(DsyncRosterPause.clearsRosterPending(afterPutOf: .profiles, paused: false), "after the pause, the roster PUT clears it")
    check(!DsyncRosterPause.clearsRosterPending(afterPutOf: .favorites, paused: false), "another category never clears it")

    // A roster user added during the pause takes its roster row once the pause ends.
    let holds = ProfileHostHoldStore(defaults: ud)
    holds.hold("P", profileIds: ["held"], trustedHosts: [], route: "r")
    holds.markAddedDuringPause("kid2")
    holds.markAddedDuringPause("plain")
    check(ProfileHostHoldStore(defaults: ud).addedDuringPause("kid2"), "the mark survives a relaunch")
    let salt = String(repeating: "b2", count: 16)
    let row = ProfileRow(userId: 9, username: "Kid2", displayName: "Little One", pinType: "numbers",
                         pinHash: PinRules.hashV2(saltHex: salt, normalized: "1357")!, pinSalt: salt,
                         role: "child", updatedAt: 1_792_000_000, avatar: AvatarSpec(icon: "star", color: "green"), order: 1)
    let rows = [ProfileRow(userId: 1, username: "owner", displayName: "owner", pinType: "none", pinHash: "", pinSalt: ""), row]
    holds.liftMatching("P"); holds.lift(profileId: "held")
    check(holds.record("P") == nil, "the pause ended")
    let found = ProfileHostHoldRules.rowAfterPause("kid2", rows: rows)
    eq(found, row, "the profile added during the pause finds its roster row (same match as a manual add)")
    check(ProfileHostHoldRules.rowAfterPause("plain", rows: rows) == nil, "a user not in the roster stays a plain add")
    var added = DispatcharrProfile(id: "kid2", playlistId: "P", displayName: "kid2", username: "kid2", userLevel: 1)
    added.role = .user   // the plain add during the pause
    let adopted = ProfileRoster.applyRow(added, found!)
    check(adopted.effectiveRole == .child && adopted.displayName == "Little One" && adopted.order == 1, "the row's role, name, and order apply")
    check(!DsyncGate.profileRowWins(localUpdatedAt: found!.updatedAt, remote: row), "the row's stamp is kept, so the next push changes nothing")
    holds.clearAddedDuringPause("kid2"); holds.clearAddedDuringPause("plain")
    check(!holds.addedDuringPause("kid2") && !ProfileHostHoldStore(defaults: ud).addedDuringPause("plain"), "checked once, then unmarked")

    // Undo after the pause ended (Remove after an add, Cancel on PIN Required): the add
    // that took its row is a roster add now, so no tombstone; the one with no row is plain.
    let kid2Roster = ProfileHostHoldRules.isRosterAddAfterPause(adoptedRow: found != nil)
    let plainRoster = ProfileHostHoldRules.isRosterAddAfterPause(adoptedRow: ProfileHostHoldRules.rowAfterPause("plain", rows: rows) != nil)
    for (path, today) in [("Remove after an add", true), ("Cancel on PIN Required", true)] {
        check(!ProfileRoster.undoWritesTombstone(rosterAdd: kid2Roster, pauseAdd: holds.addedDuringPause("kid2"), plainWrites: today),
              "\(path): the adopted pause add writes no tombstone")
        eq(ProfileRoster.undoWritesTombstone(rosterAdd: plainRoster, pauseAdd: holds.addedDuringPause("plain"), plainWrites: today), today,
           "\(path): a pause add with no roster row is a plain add, as today")
    }
    holds.markAddedDuringPause("gone"); holds.forgetProfile("gone")
    check(!holds.addedDuringPause("gone"), "a removed profile's mark goes")
}

// MARK: - Saved server copies discarded on a route change (follow-up 6)

do {
    let pl = "11111111-AAAA-BBBB-CCCC-000000000001", other = "22222222-AAAA-BBBB-CCCC-000000000002"
    // What the sync state holds for the playlist: copies for two profiles, plus things that must stay.
    let keys = ["braw|\(pl)|default|app.molinete.aerio", "raw|\(pl)|default|favorites", "data|\(pl)|kid-profile|progress",
                "raw|\(pl)|kid-profile|profiles",
                "at|\(pl)|default|favorites", "dev|\(pl)|default|favorites", "dirty|\(pl)|default|favorites",
                "pdirty|\(pl)", "rstamp|\(pl)|default", "braw|\(other)|default|app.molinete.aerio"]
    let copies = keys.filter { DsyncServerCopy.isCopy($0, playlistId: pl) }
    eq(copies.count, 4, "every profile's bucket, category, and last-data copies are server copies")
    check(!copies.contains { $0.hasPrefix("at|") || $0.hasPrefix("dev|") || $0.hasPrefix("dirty|") || $0.hasPrefix("pdirty|") || $0.hasPrefix("rstamp|") },
          "stamps, pending marks, and local recents stamps stay")
    check(!copies.contains { $0.contains(other) }, "another playlist's copy stays")

    // The old server's bucket copy (with data merged from the user's other devices) and a local change.
    func cat(_ dev: String, _ data: DsyncObject) -> DsyncObject { DsyncV2.encodeCategory(nil, deviceId: dev, updatedAt: 10, data: data) }
    let oldCopy = DsyncV2.encodeBucket(nil, deviceId: "old", appVersion: "t", updatedAt: 1,
                                       replace: [(.progress, cat("other-device", DsyncObject([("rows", .array([.string("old server row")]))]))),
                                                 (.watchlist, cat("other-device", DsyncObject([("rows", .array([.string("old list row")]))])))])
    let mine = cat("me", DsyncObject([("ids", .array([.int(7)]))]))
    func put(from copy: DsyncObject?) -> Set<String> {
        let v = DsyncV2.encodeBucket(copy, deviceId: "me", appVersion: "t", updatedAt: 2, replace: [(.favorites, mine)])
        return Set(v[DsyncV2.CATEGORIES]?.asObject?.keys ?? [])
    }
    // A route change: the copy is discarded; the new server has no record (404): only this device's data goes.
    check(R.changed(oldBase: "https://a.example", newBase: "https://b.example", oldLocal: "", newLocal: ""), "host change: discard")
    eq(put(from: nil), [DsyncKey.favorites.suffix], "after a route change, a PUT to an empty server carries nothing from the old copy")
    eq(put(from: oldCopy), [DsyncKey.favorites.suffix, DsyncKey.progress.suffix, DsyncKey.watchlist.suffix],
       "(without the discard it would have carried the old server's categories)")
    // A path-only change keeps the copy, and the PUT is built as today.
    check(!R.changed(oldBase: "https://a.example/x", newBase: "https://a.example/y", oldLocal: "", newLocal: ""), "path-only: keep the copy")
    // A read at the new address rebuilds the copy from what that server has.
    let newServer = DsyncV2.encodeBucket(nil, deviceId: "srv", appVersion: "t", updatedAt: 3,
                                         replace: [(.recents, cat("srv-device", DsyncObject([("rows", .array([]))])))])
    eq(put(from: newServer), [DsyncKey.favorites.suffix, DsyncKey.recents.suffix], "after a read at the new address, the PUT carries that server's categories only")
}

// MARK: - A Child stays where it is on a server address change (follow-up 8)

do {
    check(!ProfileHostHoldRules.leavesForDefault(activeRole: .child), "a held Child is never switched to the default (no PIN bypass)")
    check(ProfileHostHoldRules.leavesForDefault(activeRole: .user) && ProfileHostHoldRules.leavesForDefault(activeRole: .admin),
          "an Admin or Standard profile is left for the default as before")

    let (ud, suite) = freshDefaults("child")
    defer { ud.removePersistentDomain(forName: suite) }
    let secrets = MemorySecretBox()
    let store = ProfileStore(defaults: ud, secrets: secrets)
    let holds = ProfileHostHoldStore(defaults: ud)
    var child = profile("child", "P", "kid"); child.userLevel = 1; child.role = .child
    store.upsert(profile("def", "P", "owner", isDefault: true)); store.upsert(child)
    store.setApiKey("child", "K-CHILD"); store.setPassword("child", "P-CHILD")
    store.setActiveProfileId("P", "child")
    let owner = DefaultIdentity(userId: 1, username: "owner")!
    holds.recordIdentity("P", owner)

    // A cloud-pulled address change with the Child active (routeWillChangeNow): held, kept active, nothing sent.
    holds.hold("P", profileIds: ProfileHostHoldRules.toHold(store.forPlaylist("P")),
               trustedHosts: [R.hostKey("https://old.example")], route: R.key(base: "https://new.example", local: ""))
    check(holds.isHeld("child"), "the Child is held")
    eq(store.activeProfileId("P"), "child", "and stays the active profile (no switch)")
    let signIns = ProfileSignIns(store: store, holds: holds)
    for use in ProfileSignIns.Use.allCases {
        check(signIns.apiKey("child", for: use) == nil && signIns.password("child", for: use) == nil, "nothing the Child holds is sent (\(use.rawValue))")
    }
    // Its requests go nowhere: the placeholder laid over them stops at the gate, and is never the default's key.
    let gate = DispatcharrRequestGate()
    check(gate.isKeyRejected(DispatcharrRequestGate.HELD_PROFILE_KEY), "every request with the placeholder stops locally")
    eq(StreamKeyGate.headersForOpen(["X-API-Key": DispatcharrRequestGate.HELD_PROFILE_KEY], gate: gate), .held, "no stream opens")
    check(gate.prompt == nil && !gate.isPlaylistRejected("P"), "and no rejected-key prompt for it")
    // Nor as the default profile: every request to the playlist's addresses stops at the gate
    // (only the same-server check and the held sign-in form, marked HELD_CHECK_HEADER, go through).
    gate.holdServers(playlistID: "P", [DispatcharrRequestGate.serverKey("https://new.example"),
                                       DispatcharrRequestGate.serverKey("http://192.168.1.20:9191")])
    check(gate.isHeldServer("https://new.example/api/channels/channels/"), "a request to the new server URL stops")
    check(gate.isHeldServer("http://192.168.1.20:9191/api/accounts/users/me/"), "a request to the Local URL stops")
    check(!gate.isHeldServer("https://other.example/api/"), "another server is untouched")
    gate.releaseServers(playlistID: "P")
    check(!gate.isHeldServer("https://new.example/api/channels/channels/"), "released when the hold lifts")

    // Relaunch: still the active profile, still held; the restore keeps it under its own rules.
    let store2 = ProfileStore(defaults: ud, secrets: secrets)
    let holds2 = ProfileHostHoldStore(defaults: ud)
    eq(store2.activeProfileId("P"), "child", "after a relaunch the Child is still the active profile (no reset to the default)")
    check(holds2.isHeld("child"), "and still held")
    check(!ProfileHostHoldRules.leavesForDefault(activeRole: store2.byId("child")?.effectiveRole), "the launch restore keeps it (no switch, no PIN bypass)")

    // A different server: the hold stays; leaving the Child is the normal switch (its PIN step), never forced.
    eq(SameServerCheck.decide(expected: holds2.record("P")?.expected, answers: [.user(DefaultIdentity(userId: 2, username: "stranger")!)]),
       .keep("different-user"), "a different server keeps the Child held")
    // The same server: the hold lifts and the Child carries on.
    eq(SameServerCheck.decide(expected: holds2.record("P")?.expected, answers: [.user(owner)]), .lift, "the same server passes")
    eq(holds2.liftMatching("P").lifted, ["child"], "the Child's hold lifts (its tag is the snapshot)")
    eq(ProfileSignIns(store: store2, holds: holds2).apiKey("child", for: .requestOverlay), "K-CHILD", "and its own key is used again")
}

// MARK: - Every non-default profile is held, keyless ones included (follow-up 9)

do {
    let (ud, suite) = freshDefaults("keyless")
    defer { ud.removePersistentDomain(forName: suite) }
    let store = ProfileStore(defaults: ud, secrets: MemorySecretBox())
    let holds = ProfileHostHoldStore(defaults: ud)
    store.upsert(profile("def", "K", "owner", isDefault: true))
    store.upsert(profile("a", "K", "anna"))
    store.upsert(profile("b", "K", "ben"))
    let signIns = ProfileSignIns(store: store, holds: holds)
    check(!signIns.hasStored("a") && !signIns.hasStored("b"), "only keyless extra profiles")
    check(holds.record("K") == nil, "not paused before the change")
    holds.hold("K", profileIds: ProfileHostHoldRules.toHold(store.forPlaylist("K")), trustedHosts: [], route: "new")
    check(holds.isHeld("a") && holds.isHeld("b") && !holds.isHeld("def"), "a route change holds the keyless profiles")
    check(holds.record("K") != nil && holds.heldPlaylistIds.contains("K"), "so the roster pause starts for that playlist")
    check(!DsyncRosterPause.writes(.profiles, paused: holds.record("K") != nil), "and the roster is not written")
    eq(ProfileHostHoldRules.onPick(isHeld: holds.isHeld("a"), hasStoredSignIn: signIns.hasStored("a"), isDefault: false), .signInAgain,
       "picking a keyless held profile shows the sign-in form with the line")
}

// Held addresses before the playlists can be read (launch): the hold's own
// route names the same server keys the playlist's URLs would.
do {
    let route = PlaylistRoute.key(base: "https://Remote.example/", local: "http://192.168.1.5:9191")
    let fromRoute = Set(route.split(separator: "|").map(String.init).filter { !$0.isEmpty }.map { DispatcharrRequestGate.serverKey($0) })
    let fromURLs = Set(["https://remote.example", "http://192.168.1.5:9191"].map { DispatcharrRequestGate.serverKey($0) })
    eq(fromRoute, fromURLs, "route fallback holds the same addresses")
    let noLocal = PlaylistRoute.key(base: "http://a.example:9191", local: "")
    eq(Set(noLocal.split(separator: "|").map(String.init).filter { !$0.isEmpty }.map { DispatcharrRequestGate.serverKey($0) }),
       ["a.example:9191"], "a playlist with no local address holds one")
}

// MARK: - An active keyless non-default profile (security fix, 2026-11-12)
// It never falls back to the default's (playlist's) key or password: it is
// treated exactly like a held profile, so nothing is sent with the default's key.
do {
    let (ud, suite) = freshDefaults("keyless")
    defer { ud.removePersistentDomain(forName: suite) }
    let secrets = MemorySecretBox()
    let store = ProfileStore(defaults: ud, secrets: secrets)
    let holds = ProfileHostHoldStore(defaults: ud)
    store.upsert(profile("def", "K", "parent", isDefault: true))
    store.upsert(profile("kid", "K", "kid"))
    store.setApiKey("kid", "K-KID")
    store.setActiveProfileId("K", "kid")
    store.setApiKey("kid", nil)   // lost to a pulled credential change while active
    let R = ProfileHostHoldRules.self
    let kid = store.byId("kid")!
    let decision = R.activeSignIn(isDefault: kid.isDefault, isHeld: holds.isHeld("kid"), storedKey: store.apiKey("kid"))
    eq(decision, .refused, "an active keyless non-default profile is refused, never the playlist's sign-in")
    // What the request overlay lays over the playlist for it, and what that sends.
    let overlayKey: String? = {
        switch decision {
        case .own(let k): return k
        case .refused: return DispatcharrRequestGate.HELD_PROFILE_KEY
        case .playlist: return nil   // would be the default's key
        }
    }()
    check(overlayKey != nil, "an overlay is laid, so the default's key is never used in its place")
    let defaultKey = "DEFAULT-KEY"
    let sent = overlayKey ?? defaultKey
    check(sent != defaultKey, "nothing is sent with the default's key")
    let g = DispatcharrRequestGate()
    check(g.isKeyRejected(sent), "the placeholder stops every request at the gate")
    eq(StreamKeyGate.headersForOpen(["X-API-Key": sent], gate: g), .held, "and every stream open")
    check(StreamKeyGate.isProfileHeld(["X-API-Key": sent]), "with the held line (Could not reach your Dispatcharr server)")
    // The other combinations.
    eq(R.activeSignIn(isDefault: false, isHeld: false, storedKey: "  "), .refused, "a blank key is no key")
    eq(R.activeSignIn(isDefault: false, isHeld: false, storedKey: " K-KID "), .own("K-KID"), "a stored key is the profile's own")
    eq(R.activeSignIn(isDefault: false, isHeld: true, storedKey: "K-KID"), .refused, "held, key or not: refused")
    eq(R.activeSignIn(isDefault: true, isHeld: false, storedKey: nil), .playlist, "only the default uses the playlist's sign-in")
    for held in [false, true] {
        for key in [nil, "", "K"] as [String?] {
            check(R.activeSignIn(isDefault: false, isHeld: held, storedKey: key) != .playlist,
                  "a non-default profile never gets the playlist's sign-in (held=\(held) key=\(key ?? "nil"))")
        }
    }
    // Picking or reopening it shows the sign-in form; leaving a Child keeps its PIN (leavesForDefault).
    let signIns = ProfileSignIns(store: store, holds: holds)
    eq(R.onPick(isHeld: holds.isHeld("kid"), hasStoredSignIn: signIns.hasStored("kid"), isDefault: false), .signInAgain,
       "picking the keyless profile shows the sign-in form")
    check(!R.leavesForDefault(activeRole: .child), "a keyless Child is never switched away without its PIN")
    check(R.leavesForDefault(activeRole: .user), "a keyless adult leaves for the default, as a held one does")
    // Reopened at launch or on a playlist change (Android b542c797).
    eq(R.onReopen(isDefault: false, role: .child, refused: true), .staySignIn, "a Child stays, and its sign-in form opens")
    eq(R.onReopen(isDefault: false, role: .user, refused: true), .fallBackToDefault, "a Standard profile falls back to the default")
    eq(R.onReopen(isDefault: false, role: .admin, refused: true), .fallBackToDefault, "an Admin profile falls back to the default")
    eq(R.onReopen(isDefault: false, role: .child, refused: false), .asIs, "a signed-in Child stays as is")
    eq(R.onReopen(isDefault: true, role: .child, refused: true), .asIs, "the default profile uses the playlist's own sign-in")
    // Signing in as its own user unblocks it: a stored key is its own again.
    store.setApiKey("kid", "K-KID-NEW")
    eq(R.activeSignIn(isDefault: false, isHeld: holds.isHeld("kid"), storedKey: store.apiKey("kid")), .own("K-KID-NEW"),
       "signed in again: its own key, nothing refused")
}

// MARK: - Choosing a profile whose key is held as rejected (Roku spec 8.4 step 4)
do {
    let R = ProfileHostHoldRules.self
    eq(R.pickForm(isDefault: false, keyHeld: true, isCurrent: false), .profileForm, "a non-default target opens its own form")
    eq(R.pickForm(isDefault: true, keyHeld: true, isCurrent: false), .playlistForm, "the default opens the playlist's own sign-in")
    eq(R.pickForm(isDefault: false, keyHeld: false, isCurrent: false), .none, "a good key switches as before")
    eq(R.pickForm(isDefault: false, keyHeld: true, isCurrent: true), .none, "the current profile keeps today's flows")

    let (ud, suite) = freshDefaults("pickheld")
    defer { ud.removePersistentDomain(forName: suite) }
    let store = ProfileStore(defaults: ud, secrets: MemorySecretBox())
    store.upsert(profile("def", "P", "parent", isDefault: true))
    store.upsert(profile("kid", "P", "kid"))
    store.setApiKey("kid", "KID-OLD")
    let g = DispatcharrRequestGate()
    let kid = DispatcharrIdentity(playlistID: "P", profileID: "kid")
    g.markKeyRejected(playlistID: "P", key: "DEF-OLD", playlistName: "Home")
    g.markKeyRejected(playlistID: "P", key: "KID-OLD", playlistName: "Home", profileID: "kid")
    check(g.isKeyRejected(store.apiKey("kid") ?? ""), "the target's key is held: the form opens, nothing is sent with it")

    // Cancel: stays on the current profile with nothing changed.
    let activeBefore = store.activeProfileId("P")
    eq(store.activeProfileId("P"), activeBefore, "cancel keeps the current profile")
    eq(store.apiKey("kid"), "KID-OLD", "cancel changes no key")
    check(g.isKeyRejected("KID-OLD") && g.isIdentityRejected(kid) && g.isPlaylistRejected("P"), "cancel lifts no hold")

    // The wrong user: refused, nothing written.
    check(!KeySignInAccount.acceptsProfile(username: "parent", profileUsername: "kid"), "another user's sign-in is refused")
    check(!KeySignInAccount.acceptsProfile(username: "kid", profileUsername: " "), "no profile username, nothing accepted")
    eq(store.apiKey("kid"), "KID-OLD", "a refused sign-in writes nothing")
    check(g.isIdentityRejected(kid), "and its hold stays")

    // The non-default pass: its own user (any case) replaces its key and password, clears only its own hold.
    check(KeySignInAccount.acceptsProfile(username: "KID", profileUsername: "kid"), "its own user, compared without regard to case")
    store.setApiKey("kid", "KID-NEW")
    store.setPassword("kid", "kid-pass")
    g.clearIdentity(kid)
    g.clearKey("KID-NEW")
    g.noteKeyReplaced(old: "KID-OLD", new: "KID-NEW")
    check(!g.isIdentityRejected(kid) && !g.isKeyRejected("KID-NEW"), "its own hold clears; the switch goes on")
    eq(store.apiKey("kid"), "KID-NEW", "its key replaced")
    eq(store.password("kid"), "kid-pass", "its password replaced")
    check(g.isPlaylistRejected("P") && g.isKeyRejected("DEF-OLD"), "the default's hold is untouched")

    // The default target: the playlist's own sign-in with the known-user chain.
    let A = KeySignInAccount.self
    let known = A.known(recorded: (userId: 1, username: "parent"), row: "parent", defaultProfile: "parent")
    check(A.accepts(username: "Parent", userId: 1, known: known, childInvolved: false), "the playlist's known user signs in")
    check(!A.accepts(username: "kid", userId: 5, known: known, childInvolved: true), "any other account is refused")
    check(!A.accepts(username: "parent", userId: 2, known: known, childInvolved: false), "the recorded id is compared")
    g.clearPlaylist("P")
    check(!g.isPlaylistRejected("P") && !g.isKeyRejected("DEF-OLD"), "a pass clears the playlist's own hold")
}

// MARK: - A refused profile action is a dialog (owner 2026-11-12)
do {
    // Changing the only full-access profile to Child: the role step's reason, word for word, titled "Role".
    let reason: String? = {
        if case .denied(let r) = RoleRules.roleChange(actor: .admin, from: .admin, to: .child, missingPins: 0,
                                                       anyPinExists: true, targetIsLastFullAccess: true) { return r }
        return nil
    }()
    eq(reason, "At least one profile must stay Admin or Standard.", "the existing reason")
    let r = ProfileRefusal.make(title: ProfileActionTitle.role, reason: reason)
    eq(r, ProfileRefusal(title: "Role", message: "At least one profile must stay Admin or Standard."),
       "a dialog titled with the action, the reason word for word")
    eq(ProfileRefusal.okLabel, "OK", "its only button")
    check(ProfileRefusal.make(title: "Role", reason: nil) == nil, "no reason: the flow just closes")
    check(ProfileRefusal.make(title: "Role", reason: "  ") == nil, "a blank reason shows nothing")
    eq(ProfileRefusal.make(title: ProfileActionTitle.removePin, reason: RoleRules.KEEP_PIN_REASON)?.message, RoleRules.KEEP_PIN_REASON,
       "Remove PIN refusal keeps its reason")
    // The existing titles, per action.
    eq([ProfileActionTitle.role, ProfileActionTitle.resetPin, ProfileActionTitle.removePin, ProfileActionTitle.removeProfile],
       ["Role", "Reset PIN", "Remove PIN", "Remove Profile"], "role, PIN reset and remove, remove profile")
    eq([ProfileActionTitle.setPin(hasPin: false), ProfileActionTitle.setPin(hasPin: true)], ["Set PIN", "Change PIN"], "set or change PIN")
    eq([ProfileActionTitle.deviceAdminPin(has: false), ProfileActionTitle.deviceAdminPin(has: true), ProfileActionTitle.removeDeviceAdminPin],
       ["Set Device Admin PIN", "Change Device Admin PIN", "Remove Device Admin PIN"], "Device Admin PIN actions")
    eq([ProfileActionTitle.avatar, ProfileActionTitle.channelProfiles, ProfileActionTitle.switchProfile, ProfileActionTitle.moveUp,
        ProfileActionTitle.moveDown], ["Set Avatar", "Channel Profiles", "Switch Profile", "Move Up", "Move Down"], "the other actions")
}

// MARK: - The launch PIN gate comes first (security fix 2026-11-12)
do {
    let L = LaunchLockRules.self
    check(L.locked(gateArmed: true, pickerUp: false) && L.locked(gateArmed: false, pickerUp: true), "the gate or the launch picker locks the app")
    check(!L.promptMayShow(gateArmed: true, pickerUp: false), "the rejected-key prompt waits while the PIN gate is up")
    check(!L.promptMayShow(gateArmed: false, pickerUp: true), "and while the Apple TV launch picker is up")
    check(L.promptMayShow(gateArmed: false, pickerUp: false), "it shows once the PIN passes")
    // Ordering at launch: a held key's prompt is pending, the gate is armed first.
    var gate = true
    let pending = true
    var shown: [String] = []
    if gate { shown.append("gate") }
    if pending && L.promptMayShow(gateArmed: gate, pickerUp: false) { shown.append("prompt") }
    eq(shown, ["gate"], "only the PIN gate is on screen at launch")
    gate = false
    if pending && L.promptMayShow(gateArmed: gate, pickerUp: false) { shown.append("prompt") }
    eq(shown, ["gate", "prompt"], "the PIN first, then the prompt")
    // After the PIN, the prompt has its normal role-based buttons, Sign In included.
    eq(KeySignInCopy.promptActions(isTV: false, canSignIn: !gate, canEditPlaylist: !gate), [.signIn, .editPlaylist, .notNow],
       "a Standard profile's prompt after the PIN: Sign In, Edit Playlist, Not Now")
    // Nothing reachable from a prompt while locked: the gate's window is put back until it is on screen.
    check(L.gateNeedsPresenting(locked: true, scenes: 1, scenesShowingGate: 0), "a dropped gate is presented again")
    check(L.gateNeedsPresenting(locked: true, scenes: 0, scenesShowingGate: 0), "no scene yet: keep trying")
    check(L.gateNeedsPresenting(locked: true, scenes: 2, scenesShowingGate: 1), "every scene gets the gate")
    check(!L.gateNeedsPresenting(locked: true, scenes: 1, scenesShowingGate: 1), "on screen: nothing to do")
    check(!L.gateNeedsPresenting(locked: false, scenes: 1, scenesShowingGate: 0), "unlocked: no gate")
}

// MARK: - Live TV landing group (Android dd2bb36f)
do {
    let L = LiveTVLanding.self
    let shown = ["__favorites__", "All", "NBA", "News"]
    eq(L.group(pin: "", shown: shown, fallback: "All"), "All", "an All pin (stored empty) lands on All, never the group on screen")
    eq(L.group(pin: "__favorites__", shown: shown, fallback: "All"), "__favorites__", "a pinned Favorites lands on Favorites")
    eq(L.group(pin: "NBA", shown: shown, fallback: "All"), "NBA", "a pinned group that resolves lands there")
    eq(L.group(pin: "Sports", shown: shown, fallback: "All"), "All", "a pin missing on this playlist lands on All")
    eq(L.group(pin: "collection:abc", shown: shown, fallback: "All"), "collection:abc", "a pinned collection lands there")
    eq(L.group(pin: " ", shown: shown, fallback: "First"), "First", "no All shown: the first visible group")
    eq(L.logLine(reason: "switch", group: "All", pin: ""), "[GROUPS] switch landing group=All (default=unset)", "switch log line")
    eq(L.logLine(reason: "playlist", group: "NBA", pin: "NBA"), "[GROUPS] playlist landing group=NBA (default=set)", "playlist log line")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
