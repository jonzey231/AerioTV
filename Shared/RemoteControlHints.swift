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
        case .recentChannels:   return "recently watched channels"
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

    /// The guide's hold-Left chip; nil when the slot is unmapped.
    static func guideHoldLeftHint(_ map: RemoteControlMap) -> String? {
        guard let phrase = guidePhrase(map.guideAction(.leftLong)) else { return nil }
        return "Hold left on remote to \(phrase)."
    }

    /// Terse form for the compact combined guide nav chip: "Hold Left = X".
    static func guideHoldLeftShort(_ map: RemoteControlMap) -> String? {
        guard let phrase = guidePhrase(map.guideAction(.leftLong)) else { return nil }
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
