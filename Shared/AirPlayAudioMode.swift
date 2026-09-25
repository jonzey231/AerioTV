import Foundation

/// How the AirPlay pipeline treats a channel's audio for the receiver
/// (rebuilt 2026-09-24 from the lost 2026-09-21 work; the phone log reads
/// `(mode: automatic)` on every receiver line).
///
/// Roku's AirPlay receiver accepts neither AC-3 nor E-AC-3, so surround over
/// AirPlay to a Roku is impossible: `automatic` hands non-Apple receivers an
/// AAC-LC stereo downmix (the `airplay-aac` variant) and keeps Apple TV and
/// Mac receivers on AC-3 passthrough.
enum AirPlayAudioMode: String, CaseIterable, Sendable {
    case automatic
    case passthrough
    case stereo

    static let storageKey = "airPlayAudioMode"
    static let defaultMode: AirPlayAudioMode = .automatic

    /// The persisted choice, `.automatic` when unset or unknown.
    static var current: AirPlayAudioMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AirPlayAudioMode.init(rawValue:))
            ?? defaultMode
    }

    /// What the `[AVP-AIRPLAY] receiver ...` line prints after `mode:`.
    var logLabel: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .passthrough: return "Passthrough"
        case .stereo: return "Stereo AAC"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: return "Apple TV and Mac receivers get the original audio; Roku and other TVs get AAC stereo."
        case .passthrough: return "Sends the channel's audio untouched. Receivers that cannot decode surround play no audio."
        case .stereo: return "Downmixes surround channels to AAC stereo for every receiver."
        }
    }

    static let footer = "Roku and most non-Apple AirPlay receivers cannot play surround audio (AC-3 or E-AC-3). Automatic sends them AAC stereo instead. With Passthrough a Roku plays no audio on surround channels."
}
