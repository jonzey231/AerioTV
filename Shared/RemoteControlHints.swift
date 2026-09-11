import Foundation
import SwiftUI

/// Human copy for the on-screen gesture hint chips, derived from the EFFECTIVE
/// remote map so a remapped button never advertises a stale gesture.
///
/// Actions without a natural short phrase return nil and their sentence is
/// simply omitted - a hint that says nothing beats one that lies.
///
/// Swift port of the Android `RemoteControlHints.kt` (core/remote).
enum RemoteControlHints {

    private static func playerPhrase(_ action: PlayerRemoteAction) -> String? {
        switch action {
        case .showProgramInfo:  return "program info"
        case .toggleControls:   return "player controls"
        case .optionsMenu:      return "options"
        case .channelList:      return "the channel list"
        // "recently watched channels" made the combined Left/Right chip
        // run past its width cap; the short form reads the same.
        case .recentChannels:   return "recent channels"
        case .openSearch:       return "search"
        case .lastChannel:      return "the previous channel"
        case .minimizeToGuide:  return "the TV guide"
        default:                return nil
        }
    }

    /// The player's Select line, compressed: "Select: X  ·  Hold Select: Y".
    /// Nil when neither OK slot maps to a phrasable action.
    static func selectHint(_ map: RemoteControlMap) -> String? {
        var parts: [String] = []
        if let short = playerPhrase(map.playerAction(.okShort)) { parts.append("Select: \(short)") }
        if let long = playerPhrase(map.playerAction(.okLong)) { parts.append("Hold Select: \(long)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Whether Up/Down still channel-surf (gates the flip hint chip).
    static func verticalFlipMapped(_ map: RemoteControlMap) -> Bool {
        map.playerAction(.upShort) == .channelUp && map.playerAction(.downShort) == .channelDown
    }

    /// The player's Left/Right line (Android parity, Logan 2026-08-06: users
    /// forgot what the horizontal presses do). channelList gets the fixed
    /// second-press note - Left inside the channel list opens the group
    /// sidebar - because that stage is built into the overlay, not the map.
    /// Nil when neither slot maps to a phrasable action.
    static func playerHorizontalHint(_ map: RemoteControlMap) -> String? {
        var parts: [String] = []
        let left = map.playerAction(.leftShort)
        if left == .channelList {
            parts.append("Left = channel list")
            parts.append("Left again = groups")
        } else if let phrase = playerPhrase(left) {
            parts.append("Left = \(phrase)")
        }
        if let phrase = playerPhrase(map.playerAction(.rightShort)) {
            parts.append("Right = \(phrase)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private static func guidePhrase(_ action: GuideRemoteAction) -> String? {
        switch action {
        case .timelineBack:     return "browse earlier programs"
        case .timelineForward:  return "browse later programs"
        case .focusGroupPills:  return "jump to the group pills"
        case .pageUp:           return "page channels up"
        case .pageDown:         return "page channels down"
        case .jumpToNow:        return "jump to now"
        case .jumpToTop:        return "jump to the top channel"
        case .resumePlayer:     return "return to the player"
        default:                return nil
        }
    }

    /// The guide's hold-Left chip; nil when the slot is unmapped. Sidebar
    /// mode owns the hold (Logan 2026-08-06 ruling), so the chip advertises
    /// the group menu instead of whatever the map says.
    @MainActor
    static func guideHoldLeftHint(_ map: RemoteControlMap) -> String? {
        if RemoteControlStore.shared.useGroupSidebar {
            return "Hold left on remote to open channel groups."
        }
        guard let phrase = guidePhrase(map.guideAction(.leftLong)) else { return nil }
        return "Hold left on remote to \(phrase)."
    }

    /// Terse phrases for the corner hint chip. `guidePhrase` is written for
    /// full sentences ("browse earlier programs"); dropped verbatim into the
    /// chip it pushed the pill under the centered tab bar, so the chip gets
    /// its own two-or-three-word forms.
    private static func guidePhraseShort(_ action: GuideRemoteAction) -> String? {
        switch action {
        case .timelineBack:     return "earlier"
        case .timelineForward:  return "later"
        case .focusGroupPills:  return "group pills"
        case .pageUp:           return "page up"
        case .pageDown:         return "page down"
        case .jumpToNow:        return "now"
        case .jumpToTop:        return "top channel"
        case .resumePlayer:     return "player"
        default:                return nil
        }
    }

    /// Terse form for the compact combined guide nav chip: "Hold Left = X".
    /// In sidebar mode SHORT Left opens the sidebar too, so the chip says
    /// plain "Left = groups" - "Left / Hold Left = groups" was true but ran
    /// the pill into the tab bar for no extra information.
    @MainActor
    static func guideHoldLeftShort(_ map: RemoteControlMap) -> String? {
        if RemoteControlStore.shared.useGroupSidebar {
            return "Left = groups"
        }
        guard let phrase = guidePhraseShort(map.guideAction(.leftLong)) else { return nil }
        return "Hold Left = \(phrase)"
    }
}

#if os(tvOS)
/// Remote Control #196: shared dispatcher for the guide-context actions
/// reachable from more than one press site (hold-Left / hold-Right in
/// ChannelListView, hold-Select in EPGGuideView). Grid moves post the
/// notifications EPGGuideView observes; mini-player actions run directly
/// against the shared singletons. Returns false for actions the CALLER
/// owns locally (focusGroupPills pin-All, programInfo menu, none) so the
/// call site keeps its canonical behavior for them.
@MainActor
enum GuideRemoteDispatch {
    /// Hold gestures page in coarse steps: 2.5 hours matches the pre-map
    /// guide history jump users already know.
    static let timelineJumpHours = 2.5
    /// Channel rows a pageUp/pageDown hold moves by.
    static let pageStepRows = 5

    @discardableResult
    static func perform(_ action: GuideRemoteAction) -> Bool {
        switch action {
        case .timelineBack:
            post(.guideTimelineJump, ["hours": -timelineJumpHours])
            return true
        case .timelineForward:
            post(.guideTimelineJump, ["hours": timelineJumpHours])
            return true
        case .jumpToNow:
            post(.guideJumpToNow)
            return true
        case .jumpToTop:
            post(.guideScrollToTop)
            return true
        case .pageUp:
            post(.guidePageStep, ["step": -pageStepRows])
            return true
        case .pageDown:
            post(.guidePageStep, ["step": pageStepRows])
            return true
        case .resumePlayer:
            guard NowPlayingManager.shared.isActive,
                  NowPlayingManager.shared.isMinimized else { return false }
            withAnimation(.spring(response: 0.35)) {
                NowPlayingManager.shared.expand()
            }
            return true
        case .closeMiniPlayer:
            guard NowPlayingManager.shared.isActive,
                  NowPlayingManager.shared.isMinimized else { return false }
            // Full session teardown: on the unified path a bare
            // NowPlayingManager.stop() orphans the PlayerSession-owned mini.
            withAnimation(.spring(response: 0.35)) { PlayerSession.shared.exit() }
            return true
        case .focusGroupPills, .programInfo, .openSearch, .none:
            return false
        }
    }

    private static func post(_ name: Notification.Name, _ userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }
}
#endif

// MARK: - Remote hint strip (Logan 2026-09-11)

/// Synced preference backing the on-screen remote hint strip. Named to
/// match the Android twin's `show_remote_hints` so SyncManager maps the
/// two by name. Default ON.
let showRemoteHintsKey = "showRemoteHints"

/// Opacity of the black band behind the tvOS player chrome's bottom
/// control block (Logan 2026-09-11). One constant so both chromes and
/// the hint strip's own banded variant stay identical.
let playerChromeBandOpacity: Double = 0.88

#if os(tvOS)
// MARK: - Hint resolvers

extension RemoteControlHints {

    /// THE resolution used by BOTH the press path and the hint strip: a
    /// remote slot resolved through the user's effective map. The live
    /// chrome's `handleTVMoveCommand`, `startScrubHold` and
    /// `handlePlayerLongPress` all route their slot lookups through the
    /// convenience overload below, so a hint can never advertise a
    /// different action than the press actually runs (Logan 2026-09-11).
    static func resolvedPlayerAction(_ slot: RemoteSlot, map: RemoteControlMap) -> PlayerRemoteAction {
        map.playerAction(slot)
    }

    /// Same resolution against the live store, for the press path.
    @MainActor
    static func resolvedPlayerAction(_ slot: RemoteSlot) -> PlayerRemoteAction {
        resolvedPlayerAction(slot, map: RemoteControlStore.shared.map)
    }

    /// True for the actions that move the playhead, i.e. the only ones
    /// that may be advertised as "Scrub".
    static func isSeekAction(_ action: PlayerRemoteAction) -> Bool {
        action == .seekForward || action == .seekBackward
    }

    /// Terse action label for a PLAYER slot, for the hint strip. Nil
    /// means "do not advertise this slot" (unmapped, or no short phrase).
    /// `isPaused` only matters for the literal play/pause action.
    static func stripPlayerAction(_ action: PlayerRemoteAction, isPaused: Bool) -> String? {
        switch action {
        case .channelUp:       return "Channel up"
        case .channelDown:     return "Channel down"
        case .lastChannel:     return "Previous channel"
        case .recentChannels:  return "Recent channels"
        case .toggleControls:  return "Player controls"
        case .showProgramInfo: return "Program info"
        case .optionsMenu:     return "Options"
        case .playPause:       return isPaused ? "Resume" : "Pause"
        case .seekForward:     return "Seek forward"
        case .seekBackward:    return "Seek back"
        case .restartProgram:  return "Restart"
        case .jumpToLive:      return "Jump to live"
        case .minimizeToGuide: return "TV guide"
        case .channelList:     return "Channel list"
        case .subtitles:       return "Subtitles"
        case .audioTracks:     return "Audio"
        case .aspectRatio:     return "Aspect ratio"
        case .record:          return "Record"
        case .sleepTimer:      return "Sleep timer"
        case .openSearch:      return "Search"
        case .stopPlayback:    return "Stop"
        case .none:            return nil
        }
    }

    /// Terse action label for a GUIDE slot, for the hint strip.
    static func stripGuideAction(_ action: GuideRemoteAction) -> String? {
        switch action {
        case .pageUp:          return "Page up"
        case .pageDown:        return "Page down"
        case .timelineBack:    return "Earlier"
        case .timelineForward: return "Later"
        case .jumpToNow:       return "Now"
        case .jumpToTop:       return "Top channel"
        case .focusGroupPills: return "Group pills"
        case .resumePlayer:    return "Resume"
        case .closeMiniPlayer: return "Close mini"
        case .programInfo:     return "Program info"
        case .openSearch:      return "Search"
        case .none:            return nil
        }
    }

    /// Live TV tab strip. Everything is derived from the CURRENT map plus
    /// the current state; nothing is hard-coded.
    ///
    /// - Groups: sidebar mode owns the hold (RemoteControlStore ruling), so
    ///   it reads "Hold Left  Groups". In pills mode the hold runs whatever
    ///   `leftLong` maps to, and the pair is dropped when that is unmapped.
    /// - Back: HomeView.handleMenuPress - with the mini up a single Back
    ///   expands it and a double Back jumps to the top channel; with no mini
    ///   a single Back jumps to the top channel (#42 P3/P5).
    /// - Mini pairs come from the guide map's `playPause` and `rightLong`
    ///   slots and only while the corner mini is actually up.
    static func liveTVPairs(map: RemoteControlMap,
                            useGroupSidebar: Bool,
                            miniActive: Bool) -> [RemoteHintPair] {
        var pairs: [RemoteHintPair] = []
        if useGroupSidebar {
            pairs.append(RemoteHintPair(key: "Hold Left", action: "Groups"))
        } else if let phrase = stripGuideAction(map.guideAction(.leftLong)) {
            pairs.append(RemoteHintPair(key: "Hold Left", action: phrase))
        }
        pairs.append(RemoteHintPair(key: miniActive ? "Double Back" : "Back",
                                    action: "Top channel"))
        if miniActive {
            if let phrase = stripGuideAction(map.guideAction(.playPause)) {
                pairs.append(RemoteHintPair(key: "Play/Pause", action: phrase))
            }
            if let phrase = stripGuideAction(map.guideAction(.rightLong)) {
                pairs.append(RemoteHintPair(key: "Hold Right", action: phrase))
            }
        }
        return pairs
    }

    /// The unified live chrome's strip (MultiviewContainerView, solo tile).
    /// Every pair but Back comes straight off the map; Back is fixed and
    /// never remappable, and with the chrome up it dismisses the chrome.
    ///
    /// - `scrubbable`: catch-up / VOD / Live Rewind, where short Left/Right
    ///   step the timeline instead of running their mapped action, and the
    ///   holds scrub rather than dispatching leftLong/rightLong.
    /// - `channelFlipEnabled`: the pre-map App Behaviors toggle still
    ///   suppresses a channelUp/channelDown mapping, so the pair is dropped.
    static func livePlayerPairs(map: RemoteControlMap,
                                scrubbable: Bool,
                                isPaused: Bool,
                                channelFlipEnabled: Bool) -> [RemoteHintPair] {
        var pairs: [RemoteHintPair] = []
        if let phrase = stripPlayerAction(resolvedPlayerAction(.playPause, map: map), isPaused: isPaused) {
            pairs.append(RemoteHintPair(key: "Play/Pause", action: phrase))
        }
        // No Select pair: the strip only renders while the chrome is
        // VISIBLE, and in that state Select activates whatever control
        // holds focus rather than running its mapped okShort action
        // (Logan 2026-09-11). "Back  Hide controls" below covers the way
        // out instead.
        // Left / Right are ALWAYS read off the map, never off the mode
        // (Logan 2026-09-11). The press path resolves them through
        // `resolvedPlayerAction`, and so does this, so the two cannot
        // drift. They collapse to one "Scrub" pair ONLY when both sides
        // actually resolve to a seek; a side mapped to anything else is
        // shown as itself, and an unmapped side is dropped.
        let left = resolvedPlayerAction(.leftShort, map: map)
        let right = resolvedPlayerAction(.rightShort, map: map)
        if isSeekAction(left), isSeekAction(right) {
            pairs.append(RemoteHintPair(key: "Left/Right", action: "Scrub"))
        } else {
            if let phrase = stripPlayerAction(left, isPaused: isPaused) {
                pairs.append(RemoteHintPair(key: "Left", action: phrase))
            }
            if let phrase = stripPlayerAction(right, isPaused: isPaused) {
                pairs.append(RemoteHintPair(key: "Right", action: phrase))
            }
        }
        let up = resolvedPlayerAction(.upShort, map: map)
        let down = resolvedPlayerAction(.downShort, map: map)
        let flipSuppressed = { (a: PlayerRemoteAction) in
            (a == .channelUp || a == .channelDown) && !channelFlipEnabled
        }
        if up == .channelUp, down == .channelDown, channelFlipEnabled {
            pairs.append(RemoteHintPair(key: "Up/Down", action: "Change channel"))
        } else {
            if !flipSuppressed(up), let phrase = stripPlayerAction(up, isPaused: isPaused) {
                pairs.append(RemoteHintPair(key: "Up", action: phrase))
            }
            if !flipSuppressed(down), let phrase = stripPlayerAction(down, isPaused: isPaused) {
                pairs.append(RemoteHintPair(key: "Down", action: phrase))
            }
        }
        if !scrubbable {
            if let phrase = stripPlayerAction(resolvedPlayerAction(.leftLong, map: map), isPaused: isPaused) {
                pairs.append(RemoteHintPair(key: "Hold Left", action: phrase))
            }
            if let phrase = stripPlayerAction(resolvedPlayerAction(.rightLong, map: map), isPaused: isPaused) {
                pairs.append(RemoteHintPair(key: "Hold Right", action: phrase))
            }
        }
        pairs.append(RemoteHintPair(key: "Back", action: "Hide controls"))
        return pairs
    }

    /// The legacy full-screen presentation's strip (PlayerView: VOD,
    /// recordings, catch-up covers). That view does NOT run the mapped
    /// executor - its own `.onMoveCommand` / `.onTapGesture` handlers own
    /// every press - so these pairs are read off THOSE handlers, not the
    /// map, and stay honest about what the buttons really do there.
    /// `.onPlayPauseCommand` and `handleBackPress` are map-independent too.
    static func legacyPlayerPairs(scrubberActive: Bool,
                                  isPaused: Bool) -> [RemoteHintPair] {
        var pairs: [RemoteHintPair] = [
            RemoteHintPair(key: "Play/Pause", action: isPaused ? "Resume" : "Pause")
        ]
        if scrubberActive {
            pairs.append(RemoteHintPair(key: "Left/Right", action: "Scrub"))
            // Select activates the focused control here too, so it is not
            // advertised (Logan 2026-09-11).
            pairs.append(RemoteHintPair(key: "Up/Down", action: "Transport row"))
        }
        pairs.append(RemoteHintPair(key: "Back", action: "Mini player"))
        return pairs
    }
}
#endif

#if os(tvOS)
/// One "key  action" pair in the hint strip.
struct RemoteHintPair: Identifiable {
    let key: String
    let action: String
    var id: String { key + action }
}

/// The redesigned tvOS hint surface (Logan 2026-09-11): ONE line of
/// "key  action" pairs separated by a middle dot. No capsules, no
/// backgrounds, 18pt, key names in the secondary text color and the
/// action in the tertiary one. Only pairs that apply right now are
/// passed in, and every pair is resolved from the CURRENT remote map.
///
/// Horizontally CENTERED on screen (Logan 2026-09-11). One line: when
/// the pairs do not fit the width the host allows, the line truncates
/// with an ellipsis rather than shifting off center, which is why the
/// whole strip is a single concatenated `Text` and not an `HStack` of
/// them. Never focusable, never hit-testable: it is a reminder, not a
/// control.
struct RemoteHintStrip: View {
    let pairs: [RemoteHintPair]

    private var line: Text {
        var out = Text("")
        for (index, pair) in pairs.enumerated() {
            if index > 0 {
                out = out + Text("  \u{00B7}  ")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.textTertiary)
            }
            out = out + Text(pair.key)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.textSecondary)
            out = out + Text("  ")
            out = out + Text(pair.action)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.textTertiary)
        }
        return out
    }

    /// The player strip rides over live video, so it gets a band behind
    /// it (Logan 2026-09-11): full screen width, black at 55%, text
    /// vertically centered with 12pt above and below, flush with the
    /// bottom edge. The Live TV strip sits on the app background and
    /// passes `banded: false`.
    var banded: Bool = false

    var body: some View {
        if pairs.isEmpty {
            EmptyView()
        } else if banded {
            line
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(
                    Color.black.opacity(playerChromeBandOpacity)
                        .ignoresSafeArea(edges: [.horizontal, .bottom])
                )
                .focusable(false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            line
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .focusable(false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
#endif
