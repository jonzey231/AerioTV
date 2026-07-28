import Foundation
import Combine

/// tvOS group-selection surface for the live guide. Mutually exclusive with the
/// top group-pills row: sidebar mode hides the pills and arms short-Left on the
/// now-airing cell to open the docked group sidebar.
enum GroupSelectorMode: String {
    case pills
    case sidebar
}

/// Owns the TV remote-control mapping + the two companion TV guide prefs
/// (group-selection surface, tune-in destination). Singleton `ObservableObject`
/// so SwiftUI views observe the effective map and re-derive hints live.
///
/// Persistence: three per-device-type keys synced across the user's Apple TVs
/// (registered in `SyncManager` sync lists):
///   - `remoteControlMap.tv`  (Data, JSON)      -> `syncDataKeys`
///   - `guideGroupSelector.tv` (String)         -> `syncStringKeys`
///   - `guideTuneInMini.tv`   (Bool)            -> `syncBoolKeys`
/// Writing to `UserDefaults.standard` triggers `SyncManager`'s debounced push
/// automatically; a remote merge posts `.syncManagerDidApplyPreferences`, which
/// this store observes to reload.
@MainActor
final class RemoteControlStore: ObservableObject {
    static let shared = RemoteControlStore()

    // nonisolated so SyncManager (and any non-main-actor context) can read the
    // key names when building its sync-key lists.
    nonisolated static let mapKey = "remoteControlMap.tv"
    nonisolated static let groupSelectorKey = "guideGroupSelector.tv"
    nonisolated static let tuneInMiniKey = "guideTuneInMini.tv"

    /// The effective remote-control map (resolved through DEFAULT for any
    /// unset slot).
    @Published private(set) var map: RemoteControlMap

    /// `true` = docked group sidebar (short-Left), `false` = top group pills.
    @Published var useGroupSidebar: Bool {
        didSet {
            guard oldValue != useGroupSidebar else { return }
            UserDefaults.standard.set((useGroupSidebar ? GroupSelectorMode.sidebar : .pills).rawValue,
                                      forKey: Self.groupSelectorKey)
        }
    }

    /// `true` = tune live channels into the corner mini player first;
    /// `false` (default) = straight to fullscreen.
    @Published var tuneInMini: Bool {
        didSet {
            guard oldValue != tuneInMini else { return }
            UserDefaults.standard.set(tuneInMini, forKey: Self.tuneInMiniKey)
        }
    }

    private var cancellable: AnyCancellable?

    private init() {
        let ud = UserDefaults.standard
        map = RemoteControlMap.fromData(ud.data(forKey: Self.mapKey))
        let selector = GroupSelectorMode(rawValue: ud.string(forKey: Self.groupSelectorKey) ?? "") ?? .pills
        useGroupSidebar = (selector == .sidebar)
        tuneInMini = ud.bool(forKey: Self.tuneInMiniKey)

        // Reload after a remote sync merge writes fresh values into UserDefaults.
        cancellable = NotificationCenter.default.publisher(for: .syncManagerDidApplyPreferences)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadFromDefaults() }
            }
    }

    private func reloadFromDefaults() {
        let ud = UserDefaults.standard
        let newMap = RemoteControlMap.fromData(ud.data(forKey: Self.mapKey))
        if newMap != map { map = newMap }
        let selector = GroupSelectorMode(rawValue: ud.string(forKey: Self.groupSelectorKey) ?? "") ?? .pills
        let sidebar = (selector == .sidebar)
        if sidebar != useGroupSidebar { useGroupSidebar = sidebar }
        let mini = ud.bool(forKey: Self.tuneInMiniKey)
        if mini != tuneInMini { tuneInMini = mini }
    }

    // MARK: Resolvers

    func playerAction(_ slot: RemoteSlot) -> PlayerRemoteAction { map.playerAction(slot) }
    func guideAction(_ slot: RemoteSlot) -> GuideRemoteAction { map.guideAction(slot) }

    // MARK: Editing (pins preset = custom)

    /// Materialize every slot DEFAULT defines, resolved through the current map,
    /// so a CUSTOM blob is fully explicit (no accidental fallbacks after later
    /// scheme changes).
    private func materializedPlayer() -> [RemoteSlot: PlayerRemoteAction] {
        var out: [RemoteSlot: PlayerRemoteAction] = [:]
        for slot in RemoteControlMap.default.player.keys { out[slot] = map.playerAction(slot) }
        return out
    }

    private func materializedGuide() -> [RemoteSlot: GuideRemoteAction] {
        var out: [RemoteSlot: GuideRemoteAction] = [:]
        for slot in RemoteControlMap.default.guide.keys { out[slot] = map.guideAction(slot) }
        return out
    }

    func setPlayerAction(_ slot: RemoteSlot, _ action: PlayerRemoteAction) {
        var player = materializedPlayer()
        player[slot] = action
        commit(RemoteControlMap(preset: .custom, player: player, guide: materializedGuide()))
    }

    func setGuideAction(_ slot: RemoteSlot, _ action: GuideRemoteAction) {
        var guide = materializedGuide()
        guide[slot] = action
        commit(RemoteControlMap(preset: .custom, player: materializedPlayer(), guide: guide))
    }

    func resetToDefault() {
        commit(.default)
    }

    private func commit(_ newMap: RemoteControlMap) {
        map = newMap
        // preset=default persists as an empty-slot marker so a fresh install /
        // older client resolves to the shipped scheme; CUSTOM persists the full
        // materialized blob.
        UserDefaults.standard.set(newMap.toData(), forKey: Self.mapKey)
    }
}
