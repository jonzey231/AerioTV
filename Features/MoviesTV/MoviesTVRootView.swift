import SwiftUI
import SwiftData

/// Root of the Movies & TV tab: Home / Movies / TV Shows.
///
/// This replaces `OnDemandView`'s two-way Movies / Series selector and keeps
/// that view's skeleton VERBATIM, because every structural choice in it is load
/// bearing and was paid for with a shipped bug:
///
///   - **Pills live OUTSIDE the inner NavigationStack.** Inside, a pushed
///     detail did not cover them, and on tvOS they stayed focusable and trapped
///     focus: Down from the pills never crossed into the pushed detail, so the
///     Play button on a movie's info screen was unreachable.
///   - **Pills are REMOVED from the tree while a detail is pushed** rather than
///     hidden, which is what actually hands focus to the detail content. They
///     return on pop.
///   - **One shared background ZStack.** Without it the pill region rendered
///     with the TabView's lighter blue against the inner view's dark blue, a
///     visible two-tone seam on tvOS.
///   - **The 72pt iPad top inset.** iPadOS 18+'s floating TabView capsule does
///     not consume top safe area, so content at the safe-area top still renders
///     behind it.
///
/// New in this phase: a third section, and `@SceneStorage` so the tab reopens
/// where the user left it.
struct MoviesTVRootView: View {
    @ObservedObject var vodStore: VODStore
    @Binding var isPlaying: Bool
    @Binding var isDetailPushed: Bool
    @Binding var popRequested: Bool

    enum Section: String, CaseIterable {
        case home, movies, tvShows

        var title: String {
            switch self {
            case .home: return "Home"
            case .movies: return "Movies"
            case .tvShows: return "TV Shows"
            }
        }
    }

    /// Last section the user was on, restored per scene. Stored as the raw
    /// string so adding or reordering sections later cannot silently land the
    /// user somewhere else, the way a stored index would.
    @SceneStorage("moviesTV.section") private var storedSection: String = Section.home.rawValue

    /// Sort state, owned here because the Sort control is pinned beside the
    /// section pills (outside the grids' NavigationStacks) while the thing it
    /// orders lives inside them.
    @StateObject private var browse = MediaBrowseModel()

    private var section: Section {
        get { Section(rawValue: storedSection) ?? .home }
        nonmutating set { storedSection = newValue.rawValue }
    }

    #if os(iOS)
    /// With `UIDevice.userInterfaceIdiom`, distinguishes full-width iPad (a
    /// floating TabView, needs the inset) from iPhone or Split-View iPad (a
    /// bottom tab bar, no collision).
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if !isDetailPushed {
                    #if os(tvOS)
                    HStack {
                        Spacer()
                        pillRow
                        Spacer()
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                    .focusSection()
                    #else
                    iOSPillHeader
                    #endif
                }

                switch section {
                case .home:
                    MoviesTVHomeSection(
                        vodStore: vodStore,
                        isPlaying: $isPlaying,
                        isDetailPushed: $isDetailPushed,
                        popRequested: $popRequested,
                        onBrowseMovies: { section = .movies },
                        onBrowseTVShows: { section = .tvShows }
                    )
                case .movies:
                    MoviesView(
                        vodStore: vodStore,
                        browse: browse,
                        isPlaying: $isPlaying,
                        isDetailPushed: $isDetailPushed,
                        popRequested: $popRequested
                    )
                case .tvShows:
                    TVShowsView(
                        vodStore: vodStore,
                        browse: browse,
                        isPlaying: $isPlaying,
                        isDetailPushed: $isDetailPushed,
                        popRequested: $popRequested
                    )
                }
            }
        }
        // Tab-bar visibility is owned inside each section's NavigationStack (a
        // pushed detail hides it, the roots assert it visible), so popping
        // restores it reliably on tvOS 27. A toggle at this level did not
        // re-assert on pop.
    }

    private var pillRow: some View {
        HStack(spacing: 12) {
            ForEach(Section.allCases, id: \.self) { candidate in
                DVRSegmentPill(
                    label: candidate.title,
                    isSelected: section == candidate,
                    action: {
                        withAnimation(.easeInOut(duration: 0.15)) { section = candidate }
                    }
                )
            }
            // Sort rides in the SAME pinned row as the sections rather than in
            // a toolbar or behind a long-press: the dossier's 10-foot rule is
            // that nothing which changes what you are looking at may be hidden
            // behind an affordance you cannot see. Home is shelves with their
            // own fixed ordering, so the control only appears on the grids.
            if section != .home {
                sortPill
            }
        }
    }

    /// Sort as a pinned pill. Uses `Menu` with checkmark labels, the same
    /// control the Live TV channel list already ships for its sort on both
    /// platforms, so this is a proven focus surface on tvOS rather than a new
    /// one invented for this screen.
    private var sortPill: some View {
        Menu {
            ForEach(MediaSort.allCases) { candidate in
                Button {
                    browse.sort = candidate
                } label: {
                    if browse.sort == candidate {
                        Label(candidate.label, systemImage: "checkmark")
                    } else {
                        Text(candidate.label)
                    }
                }
            }
        } label: {
            #if os(tvOS)
            Text(browse.sort.label)
            #else
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                Text(browse.sort.label)
            }
            #endif
        }
        #if os(tvOS)
        .buttonStyle(MoviesTVSortPillStyle())
        #endif
    }

    #if os(iOS)
    private var iOSPillHeader: some View {
        HStack {
            Spacer()
            pillRow
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, extraTopPadding)
        .padding(.bottom, 10)
        .background(Color.appBackground)
    }

    /// 72pt clears the floating bar's ~54pt capsule plus an 18pt gap, in both
    /// orientations. Split View drops to `.compact`, which per Apple falls back
    /// to a bottom tab bar, hence the size-class cross-check.
    private var extraTopPadding: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad && hSize == .regular {
            return 72
        }
        return 10
    }
    #endif
}

#if os(tvOS)
/// Sort pill styling. Mirrors `DVRSegmentPillButtonStyle`'s unselected state so
/// the control reads as a sibling of the section pills, and owns its focus
/// visual through `isFocused` so tvOS never paints its squared platter over the
/// capsule (see `feedback_tvos_focus_squared_platter`).
private struct MoviesTVSortPillStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .font(.system(size: 22, weight: .medium))
            .foregroundColor(focused ? .white : .textSecondary)
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(Capsule().fill(Color.elevatedBackground))
            .overlay(
                Capsule().stroke(focused ? Color.accentPrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .opacity(focused ? 1.0 : 0.85)
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif

/// Home wrapped in its own NavigationStack so poster taps push a detail exactly
/// as they do from the grids, including the tab-bar hide/restore behaviour.
private struct MoviesTVHomeSection: View {
    @ObservedObject var vodStore: VODStore
    @Query private var servers: [ServerConnection]
    @Binding var isPlaying: Bool
    @Binding var isDetailPushed: Bool
    @Binding var popRequested: Bool
    let onBrowseMovies: () -> Void
    let onBrowseTVShows: () -> Void

    @State private var navPath = NavigationPath()

    /// Auth headers for the active Dispatcharr server, used by AuthPosterImage.
    /// Same resolution order as the grids so a poster that loads there loads here.
    private var dispatcharrHeaders: [String: String] {
        guard let s = servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI && $0.isActive })
                   ?? servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI })
        else { return [:] }
        return s.authHeaders
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                MediaHomeView(
                    vodStore: vodStore,
                    headers: dispatcharrHeaders,
                    onOpenItem: { navPath.append($0) },
                    onSeeAll: { shelf in
                        // Route to the grid that owns this shelf's media type.
                        // Scoping the grid to the specific library arrives with
                        // the library scope chips in a later phase; landing on
                        // the right grid is the useful half and it ships now.
                        if shelf.items.first?.type == .series {
                            onBrowseTVShows()
                        } else {
                            onBrowseMovies()
                        }
                    },
                    onResume: { progress in
                        // Home hands resume back to the same detail flow the
                        // grids use, so there is exactly one playback path.
                        if let item = resolveItem(for: progress) {
                            navPath.append(item)
                        }
                    }
                )
            }
            .navigationDestination(for: VODDisplayItem.self) { item in
                VODDetailView(item: item, isPlaying: $isPlaying)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            #if os(tvOS)
            .toolbar(.visible, for: .tabBar)
            #endif
        }
        .onChange(of: navPath.count) { _, count in
            isDetailPushed = count > 0
        }
        .onChange(of: popRequested) { _, requested in
            guard requested, !navPath.isEmpty else { return }
            navPath.removeLast(navPath.count)
        }
    }

    /// Map a progress row back to its catalog item so Resume opens the detail
    /// page, where the existing Resume / Play from Beginning logic already
    /// lives. Episodes resolve to their parent show.
    private func resolveItem(for progress: WatchProgress) -> VODDisplayItem? {
        if progress.vodType == "episode" {
            return vodStore.series.first { $0.id == progress.seriesID }
        }
        return vodStore.movies.first { $0.id == progress.vodID }
    }
}
