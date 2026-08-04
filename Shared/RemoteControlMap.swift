import Foundation

/// TV remote button mapping. One map per CONTEXT (player vs guide),
/// sharing the exact JSON wire schema with the Android build so the two
/// stay in lockstep:
///
/// ```json
/// { "version": 1, "preset": "default",
///   "player": { "okShort": "toggleControls", ... },
///   "guide":  { "ffwd": "pageDown", ... } }
/// ```
///
/// Design invariants (do not relax without a plan change):
/// - Back/Menu is NEVER a slot: the Back / mini-player / guide-ladder model
///   is device-verified canon and stays hardcoded.
/// - Guide SHORT arrows are focus navigation, never mappable.
/// - Unknown slots/actions in a stored blob are IGNORED on read (forward
///   compat); missing slots fall back to `RemoteControlMap.default`'s
///   assignment at RESOLVE time, so a partial blob never strands a button.
///
/// This is a faithful Swift port of the Android `RemoteControlMap.kt`
/// (core/remote). Keep the wire strings identical across platforms.

// MARK: - Slots

/// Stable wire ids. Which slots a platform/context actually offers is decided
/// by the settings UI + resolver, not by this enum.
enum RemoteSlot: String, CaseIterable {
    case okShort, okLong
    case upShort, upLong
    case downShort, downLong
    case leftShort, leftLong
    case rightShort, rightLong
    case playPause, ffwd, rewind
    case channelUp, channelDown

    var wire: String { rawValue }
    static func fromWire(_ s: String) -> RemoteSlot? { RemoteSlot(rawValue: s) }
}

// MARK: - Actions

/// Actions available while the fullscreen live player is frontmost.
enum PlayerRemoteAction: String, CaseIterable {
    case channelUp, channelDown
    case lastChannel
    case recentChannels
    case toggleControls
    case showProgramInfo
    case optionsMenu
    case playPause
    case seekForward, seekBackward
    case restartProgram, jumpToLive
    case minimizeToGuide
    case channelList
    case subtitles, audioTracks
    case aspectRatio, record
    case sleepTimer, openSearch
    /// Fixed hold-Back behavior (stop with NO mini promotion); dispatched by
    /// the app's long-Back path, deliberately NOT offered as a mappable choice
    /// in settings (Back semantics stay hardcoded).
    case stopPlayback
    case none

    var wire: String { rawValue }
    static func fromWire(_ s: String) -> PlayerRemoteAction? { PlayerRemoteAction(rawValue: s) }
}

/// Actions available while the TV guide is frontmost.
enum GuideRemoteAction: String, CaseIterable {
    case pageUp, pageDown
    case timelineBack, timelineForward
    case jumpToNow, jumpToTop
    case focusGroupPills
    case resumePlayer, closeMiniPlayer
    case programInfo, openSearch
    case none

    var wire: String { rawValue }
    static func fromWire(_ s: String) -> GuideRemoteAction? { GuideRemoteAction(rawValue: s) }
}

enum RemotePreset: String {
    case `default`
    case custom

    var wire: String { rawValue }

    /// Only wires this build has ever written are honored. Anything else
    /// (notably any pre-release preset-picker blobs) is nil and the whole
    /// stored map is DISCARDED at decode.
    static func fromWire(_ s: String) -> RemotePreset? { RemotePreset(rawValue: s) }
}

// MARK: - Map

struct RemoteControlMap: Equatable {
    let preset: RemotePreset
    let player: [RemoteSlot: PlayerRemoteAction]
    let guide: [RemoteSlot: GuideRemoteAction]

    init(preset: RemotePreset = .default,
         player: [RemoteSlot: PlayerRemoteAction] = [:],
         guide: [RemoteSlot: GuideRemoteAction] = [:]) {
        self.preset = preset
        self.player = player
        self.guide = guide
    }

    // MARK: Resolve with fallback

    /// Resolve with fallback to the default map so a partial/legacy blob never
    /// leaves a button dead. Explicit `.none` is respected.
    func playerAction(_ slot: RemoteSlot) -> PlayerRemoteAction {
        player[slot] ?? RemoteControlMap.default.player[slot] ?? .none
    }

    func guideAction(_ slot: RemoteSlot) -> GuideRemoteAction {
        guide[slot] ?? RemoteControlMap.default.guide[slot] ?? .none
    }

    /// First slot currently mapped to `action`, for dynamic hint copy.
    func playerSlot(for action: PlayerRemoteAction) -> RemoteSlot? {
        RemoteSlot.allCases.first { playerAction($0) == action }
    }

    func guideSlot(for action: GuideRemoteAction) -> RemoteSlot? {
        RemoteSlot.allCases.first { guideAction($0) == action }
    }

    // MARK: Encode

    func toJSON() -> String {
        var playerObj: [String: String] = [:]
        for (slot, action) in player { playerObj[slot.wire] = action.wire }
        var guideObj: [String: String] = [:]
        for (slot, action) in guide { guideObj[slot.wire] = action.wire }
        let obj: [String: Any] = [
            "version": RemoteControlMap.schemaVersion,
            "preset": preset.wire,
            "player": playerObj,
            "guide": guideObj,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    func toData() -> Data { Data(toJSON().utf8) }

    // MARK: Constants

    static let schemaVersion = 1

    /// The PRE-initiative control scheme, kept verbatim so any regression can
    /// be reverted by pointing `default` back at it. NOT user-selectable.
    static let legacyScheme = RemoteControlMap(
        preset: .default,
        player: [
            .upShort: .channelUp,
            .downShort: .channelDown,
            .leftShort: .seekBackward,
            .rightShort: .seekForward,
            .okShort: .toggleControls,
            .okLong: .none,
            .playPause: .playPause,
            .ffwd: .seekForward,
            .rewind: .seekBackward,
            .channelUp: .channelUp,
            .channelDown: .channelDown,
        ],
        guide: [
            .leftLong: .timelineBack,
            .rightLong: .closeMiniPlayer,
            .okLong: .programInfo,
            .playPause: .resumePlayer,
        ]
    )

    /// The app's standard control scheme (matches Android DEFAULT exactly):
    /// OK = show controls, Up/Down = channel surf, hold-Up = recently watched,
    /// hold-Down = search, Right = previous-channel zap, hold-Right = program
    /// info, hold-Left in the guide pages into already-aired programmes.
    static let `default` = RemoteControlMap(
        preset: .default,
        player: [
            .okShort: .toggleControls,
            .okLong: .none,
            .upShort: .channelUp,
            .downShort: .channelDown,
            .upLong: .recentChannels,
            .downLong: .openSearch,
            .leftShort: .channelList,
            .leftLong: .minimizeToGuide,
            .rightShort: .lastChannel,
            .rightLong: .showProgramInfo,
            .playPause: .playPause,
            .ffwd: .seekForward,
            .rewind: .seekBackward,
            .channelUp: .channelUp,
            .channelDown: .channelDown,
        ],
        guide: [
            .ffwd: .pageDown,
            .rewind: .pageUp,
            .channelUp: .pageUp,
            .channelDown: .pageDown,
            .okLong: .programInfo,
            .leftLong: .timelineBack,
            .rightLong: .closeMiniPlayer,
            .playPause: .resumePlayer,
        ]
    )

    // MARK: Decode

    /// Tolerant decode: unknown slots/actions are skipped, malformed input
    /// falls back to `default`. Never throws.
    static func fromJSON(_ raw: String?) -> RemoteControlMap {
        guard let raw = raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .default
        }
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .default
        }
        let presetWire = (obj["preset"] as? String) ?? RemotePreset.default.wire
        guard let preset = RemotePreset.fromWire(presetWire) else {
            // Unknown preset wire (e.g. a pre-release picker blob): discard the
            // whole stored map so stale slot layouts don't strand the user.
            return .default
        }
        // preset=default means "track the app's standard scheme": ignore any
        // stored slot dump (older builds persisted the full resolved map, which
        // would otherwise pin those users to that build's defaults forever).
        // Stored slots are only authoritative for CUSTOM.
        if preset == .default { return .default }
        return RemoteControlMap(
            preset: preset,
            player: decodeContext(obj["player"] as? [String: Any]) { PlayerRemoteAction.fromWire($0) },
            guide: decodeContext(obj["guide"] as? [String: Any]) { GuideRemoteAction.fromWire($0) }
        )
    }

    static func fromData(_ data: Data?) -> RemoteControlMap {
        guard let data = data, let str = String(data: data, encoding: .utf8) else { return .default }
        return fromJSON(str)
    }

    private static func decodeContext<A>(
        _ obj: [String: Any]?,
        _ action: (String) -> A?
    ) -> [RemoteSlot: A] {
        guard let obj = obj else { return [:] }
        var out: [RemoteSlot: A] = [:]
        for (key, value) in obj {
            guard let slot = RemoteSlot.fromWire(key) else { continue }
            guard let wire = value as? String, let act = action(wire) else { continue }
            out[slot] = act
        }
        return out
    }
}
