import Foundation
import Combine

/// Browse state shared between the pinned Sort control and the grids it drives.
///
/// It has to be shared because of where the controls live: the dossier puts
/// Sort and Filter as pinned pills NEXT TO the section pills, which sit outside
/// the grids' NavigationStacks (see MoviesTVRootView for why that placement is
/// load bearing on tvOS). The control and the thing it controls are therefore in
/// different subtrees, so the state belongs above both.
///
/// Owned by `MoviesTVRootView` for the life of the tab.
final class MediaBrowseModel: ObservableObject {
    private static let sortKey = "moviesTV.sort"

    /// Persisted so the user's ordering survives relaunch. Stored as the raw
    /// string rather than an index, so reordering `MediaSort` later cannot
    /// silently change what a returning user sees.
    @Published var sort: MediaSort {
        didSet {
            guard sort != oldValue else { return }
            UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey)
        }
    }

    /// Seed for `.random`, fixed for the life of this model and therefore for
    /// the life of the tab. Deliberately NOT persisted: Random that is stable
    /// forever is just an arbitrary fixed order, and Random that reshuffles as
    /// you scroll is unusable. Once per app run is the useful middle.
    let randomSeed: UInt64

    /// Raised by the pinned Filter pill; the visible grid presents its own
    /// filter sheet from it. Lives here for the same reason `sort` does: the
    /// pill is outside the grids' NavigationStacks. Only one grid is in the
    /// tree at a time (the root switches on section), so a single flag cannot
    /// present two sheets at once.
    @Published var showFilter = false

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.sortKey)
        self.sort = stored.flatMap(MediaSort.init(rawValue:)) ?? .title
        self.randomSeed = UInt64.random(in: UInt64.min...UInt64.max)
    }
}
