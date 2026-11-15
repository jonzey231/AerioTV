import Foundation

/// Which receiver a Cast launch is for (owner rule 2026-11-14: a basic cast
/// must not need the app). A pick under "Google Cast" is a plain cast to the
/// web receiver through the phone proxy, even on a TV that has AerioTV; only
/// the "AerioTV on TV" entry launches the AerioTV Android TV app (Cast
/// Connect). The Cast SDK launches the TV app whenever it is installed
/// (GCKLaunchOptions.androidReceiverCompatible, set once at startup), so the
/// sender names its intent in the launch credentials
/// (GCKCastContext.setLaunchCredentialsData) and the TV app's launch request
/// checker declines a plain cast; the Cast framework then loads the web
/// receiver instead. Nothing secret rides here: no key, no sign-in.
///
/// The wire strings are the Android contract (CastLaunchIntent.kt) and must
/// stay byte-identical with it. Pure logic, compiled by
/// Scripts/cast-launch-tests.
enum CastLaunchIntent: String, CaseIterable, Sendable {
    /// A plain cast to the web receiver (the phone proxy path).
    case webReceiver = "aeriotv-launch:web"
    /// The AerioTV Android TV app, picked from "AerioTV on TV".
    case tvApp = "aeriotv-launch:app"

    var wire: String { rawValue }

    static func of(_ wire: String?) -> CastLaunchIntent? {
        guard let wire else { return nil }
        return CastLaunchIntent(rawValue: wire.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The TV app's answer to a launch request: it declines only an explicit
    /// plain cast. A launch with no intent (an older sender) launches the app
    /// as before, which is why every launch path here names one.
    static func tvAppAccepts(_ credentials: String?) -> Bool { of(credentials) != .webReceiver }

    /// The intent once a session ends: a device switch that is waiting to
    /// start keeps the intent of the entry it was picked from; otherwise the
    /// next launch is a plain cast unless "AerioTV on TV" is picked again.
    static func afterSessionEnd(pendingSwitch: CastLaunchIntent?) -> CastLaunchIntent {
        pendingSwitch ?? .webReceiver
    }

    /// Log wording, shared with the Android sender's "[Cast] next launch" line.
    var logDescription: String {
        self == .tvApp ? "AerioTV app on the TV (Cast Connect)" : "web receiver (plain cast)"
    }
}

/// The Cast picker's two device sections. The entry decides the receiver.
enum CastPickerSection: Sendable {
    /// "AerioTV on TV": devices recorded as running the AerioTV TV app.
    case aerioTVOnTV
    /// "Google Cast": every other Cast device, always a plain cast.
    case googleCast

    var launchIntent: CastLaunchIntent { self == .aerioTVOnTV ? .tvApp : .webReceiver }
}

/// The sender's launch-intent bookkeeping (AerioCastController runs exactly
/// this, so the test script drives the same rules). `next` is what the SDK's
/// launch credentials carry for the next launch; `stored` is what is kept
/// across an app restart.
struct CastLaunchPlan: Equatable, Sendable {
    /// What the next Cast launch carries.
    private(set) var next: CastLaunchIntent
    /// A device switch waiting for the current session to end: the intent of
    /// the entry it was picked from.
    private(set) var pendingSwitch: CastLaunchIntent?

    /// At app start: a session the SDK resumes (or relaunches when its join
    /// fails) keeps the entry it was picked from; anything else is a plain
    /// cast.
    init(stored: String?) {
        next = CastLaunchIntent.of(stored) ?? .webReceiver
        pendingSwitch = nil
    }

    /// The value persisted for the next app start.
    var stored: String { next.wire }

    /// A picker pick. `switching` means another device's session is up and
    /// ends first; the new device then starts with this same intent.
    mutating func pick(_ intent: CastLaunchIntent, switching: Bool) {
        next = intent
        pendingSwitch = switching ? intent : nil
    }

    /// The session ended. Returns the waiting switch's intent, if any; the
    /// next launch is that intent, else a plain cast.
    mutating func sessionEnded() -> CastLaunchIntent? {
        let waiting = pendingSwitch
        pendingSwitch = nil
        next = CastLaunchIntent.afterSessionEnd(pendingSwitch: waiting)
        return waiting
    }

    /// A launch the SDK refused or that failed to start: back to a plain cast.
    mutating func startFailed() {
        next = .webReceiver
        pendingSwitch = nil
    }
}
