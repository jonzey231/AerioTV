// Cast launch intent tests (owner rule 2026-11-14: a basic cast must not need
// the app). A "Google Cast" pick is a plain cast to the web receiver; only
// "AerioTV on TV" launches the AerioTV Android TV app. Mirrors the Android
// CastLaunchIntentTest and adds the sender's carry-over rules.

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

// MARK: Wire contract (byte-identical with Android CastLaunchIntent.kt)

eq(CastLaunchIntent.webReceiver.wire, "aeriotv-launch:web", "plain cast wire string")
eq(CastLaunchIntent.tvApp.wire, "aeriotv-launch:app", "TV app wire string")
for intent in CastLaunchIntent.allCases {
    eq(CastLaunchIntent.of(intent.wire), intent, "\(intent) round-trips")
    check(intent.wire.hasPrefix("aeriotv-launch:"), "\(intent) carries only the marking, no secret")
}
eq(CastLaunchIntent.of(nil), nil, "no credentials is no intent")
eq(CastLaunchIntent.of(""), nil, "empty credentials is no intent")
eq(CastLaunchIntent.of("something else"), nil, "unknown credentials is no intent")
eq(CastLaunchIntent.of(" aeriotv-launch:web "), .webReceiver, "whitespace around the wire value still reads")

// MARK: What the TV app does with it (the launch request checker)

check(!CastLaunchIntent.tvAppAccepts(CastLaunchIntent.webReceiver.wire), "the TV app declines a plain cast")
check(CastLaunchIntent.tvAppAccepts(CastLaunchIntent.tvApp.wire), "the TV app accepts an AerioTV on TV pick")
check(CastLaunchIntent.tvAppAccepts(nil), "an unmarked launch still opens the TV app, so every launch must be marked")
check(CastLaunchIntent.tvAppAccepts("something else"), "an unknown marking opens the TV app")

// MARK: The picker entry decides the receiver

eq(CastPickerSection.googleCast.launchIntent, .webReceiver, "Google Cast is always a plain cast")
eq(CastPickerSection.aerioTVOnTV.launchIntent, .tvApp, "only AerioTV on TV launches the TV app")

// MARK: Session end

eq(CastLaunchIntent.afterSessionEnd(pendingSwitch: nil), .webReceiver, "an end with no switch returns to a plain cast")
eq(CastLaunchIntent.afterSessionEnd(pendingSwitch: .webReceiver), .webReceiver, "a Google Cast switch stays a plain cast")
eq(CastLaunchIntent.afterSessionEnd(pendingSwitch: .tvApp), .tvApp, "an AerioTV on TV switch keeps the TV app")

// MARK: The sender's plan, step by step

do {
    // Fresh install: nothing stored, the first launch is a plain cast.
    var plan = CastLaunchPlan(stored: nil)
    eq(plan.next, .webReceiver, "fresh install starts as a plain cast")
    eq(plan.stored, "aeriotv-launch:web", "and stores the plain cast marking")

    // A Google Cast pick of a TV that has the app: still a plain cast.
    plan.pick(CastPickerSection.googleCast.launchIntent, switching: false)
    eq(plan.next, .webReceiver, "Google Cast pick launches the web receiver")

    // That session ends; nothing waits.
    eq(plan.sessionEnded(), nil, "no switch waits after a plain end")
    eq(plan.next, .webReceiver, "next launch is a plain cast")

    // AerioTV on TV pick: the TV app.
    plan.pick(CastPickerSection.aerioTVOnTV.launchIntent, switching: false)
    eq(plan.next, .tvApp, "AerioTV on TV pick launches the TV app")
    eq(plan.stored, "aeriotv-launch:app", "stored for a resume after an app restart")

    // App restart while that session is up: the resume keeps the TV app.
    var restarted = CastLaunchPlan(stored: plan.stored)
    eq(restarted.next, .tvApp, "a resumed AerioTV on TV session keeps the TV app")

    // The resumed session ends: back to a plain cast, and stored that way.
    eq(restarted.sessionEnded(), nil, "nothing waits")
    eq(restarted.next, .webReceiver, "after the resumed session ends, a plain cast")
    eq(CastLaunchPlan(stored: restarted.stored).next, .webReceiver, "a restart after the end is a plain cast")
}

do {
    // Device switch from the picker: casting on TV A through the TV app,
    // then a Google Cast pick of TV B while A is still connected.
    var plan = CastLaunchPlan(stored: nil)
    plan.pick(.tvApp, switching: false)
    plan.pick(CastPickerSection.googleCast.launchIntent, switching: true)
    eq(plan.next, .webReceiver, "the switch's own intent is set at once")
    eq(plan.sessionEnded(), .webReceiver, "A's end hands B the Google Cast intent")
    eq(plan.next, .webReceiver, "B launches as a plain cast, not A's TV app")

    // The other way: a plain cast on A, then AerioTV on TV for B.
    plan.pick(.webReceiver, switching: false)
    plan.pick(CastPickerSection.aerioTVOnTV.launchIntent, switching: true)
    eq(plan.sessionEnded(), .tvApp, "A's end hands B the AerioTV on TV intent")
    eq(plan.next, .tvApp, "B launches the TV app")
    // B's start pick (beginSession runs again with the handed intent).
    plan.pick(.tvApp, switching: false)
    eq(plan.next, .tvApp, "B's own start keeps the TV app")
    eq(plan.sessionEnded(), nil, "B's end has no switch")
    eq(plan.next, .webReceiver, "and returns to a plain cast")
}

do {
    // A failed start or a refused startSession: back to a plain cast.
    var plan = CastLaunchPlan(stored: CastLaunchIntent.tvApp.wire)
    plan.pick(.tvApp, switching: false)
    plan.startFailed()
    eq(plan.next, .webReceiver, "a failed AerioTV on TV start returns to a plain cast")
    eq(plan.sessionEnded(), nil, "a failure leaves no switch waiting")

    // Garbage in storage never opens the TV app.
    eq(CastLaunchPlan(stored: "aeriotv-launch:tv").next, .webReceiver, "an unknown stored value is a plain cast")
    eq(CastLaunchPlan(stored: "").next, .webReceiver, "an empty stored value is a plain cast")
}

// MARK: A plain cast never drops a TV from AerioTV on TV (Android 7a03952b)

check(CastPickerRules.webAnswerDemotes(launchIntent: .tvApp), "a web answer to an AerioTV on TV launch: the TV app is gone")
check(!CastPickerRules.webAnswerDemotes(launchIntent: .webReceiver), "a web answer to a plain cast says nothing about the app")

// MARK: A TV running AerioTV is listed under AerioTV on TV by name (Android 2d32f325)

do {
    let remote = Set(["Living Room Google TV (2)", "Guest Room Google TV", "Living Room Apple TV"].map(CastPickerRules.normalizedTVName))
    check(CastPickerRules.listsUnderAerioTVOnTV(castName: "Living Room Google TV", recordedNative: false, appTVNames: remote),
          "the AerioTV Remote name (with NSD's (2) suffix) matches the Cast name")
    check(CastPickerRules.listsUnderAerioTVOnTV(castName: " guest room google tv ", recordedNative: false, appTVNames: remote),
          "case and spaces do not matter")
    check(!CastPickerRules.listsUnderAerioTVOnTV(castName: "Upstairs", recordedNative: false, appTVNames: remote),
          "a speaker with no AerioTV app is not listed")
    check(CastPickerRules.listsUnderAerioTVOnTV(castName: "Upstairs", recordedNative: true, appTVNames: []),
          "a TV recorded by a native session stays listed")
    check(!CastPickerRules.listsUnderAerioTVOnTV(castName: nil, recordedNative: false, appTVNames: remote), "no name, no match")
    eq(CastPickerRules.normalizedTVName("Living Room Google TV (12)"), "living room google tv", "NSD suffix removed")
    eq(CastPickerRules.normalizedTVName("TV (Basement)"), "tv (basement)", "only a numeric suffix is NSD's")
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
