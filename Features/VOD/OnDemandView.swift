import SwiftUI

// MARK: - On Demand (Movies + Series)
/// Wrapper that combines MoviesView and TVShowsView into a single tab
/// with a segment picker, keeping the tab bar within iOS's 5-tab limit.
struct OnDemandView: View {
    @ObservedObject var vodStore: VODStore
    @Binding var isPlaying: Bool
    @Binding var isDetailPushed: Bool
    @Binding var popRequested: Bool

    @State private var segment = 0 // 0 = Movies, 1 = Series

    /// Pill pair used as the "Movies / Series" segment selector on
    /// both platforms. Layout varies: tvOS centres them above the grid
    /// as a custom header; iOS injects them into the inner view's
    /// navigation bar via a `principal` toolbar item so they take the
    /// place of the old "Movies" / "Series" title.
    private var pillRow: some View {
        HStack(spacing: 12) {
            DVRSegmentPill(
                label: "Movies",
                isSelected: segment == 0,
                action: {
                    withAnimation(.easeInOut(duration: 0.15)) { segment = 0 }
                }
            )
            DVRSegmentPill(
                label: "Series",
                isSelected: segment == 1,
                action: {
                    withAnimation(.easeInOut(duration: 0.15)) { segment = 1 }
                }
            )
        }
    }

    var body: some View {
        // ZStack with an explicit Color.appBackground at the back so
        // the entire tab — pill area AND grid area — shares the same
        // dark blue. Without this, the pill row region on tvOS used
        // the default TabView background (a lighter blue) while the
        // inner MoviesView/TVShowsView's own ZStack painted the dark
        // blue, producing a visible two-tone seam.
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                #if os(tvOS)
                // tvOS: centre the pills above the media grid. Minimal
                // top padding — the tab bar's own safe area provides
                // most of the gap; we just add a small breathing room.
                HStack {
                    Spacer()
                    pillRow
                    Spacer()
                }
                .padding(.horizontal, 40)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .focusSection()
                #endif

                if segment == 0 {
                    MoviesView(
                        vodStore: vodStore,
                        isPlaying: $isPlaying,
                        isDetailPushed: $isDetailPushed,
                        popRequested: $popRequested
                    )
                    #if os(iOS)
                    // iOS: pin the pill row as a safe-area inset at
                    // the TOP of the Movies grid's scroll view. It
                    // sits below the nav bar + `.searchable` search
                    // bar (which live inside MoviesView's
                    // NavigationStack) and above the scroll content,
                    // in the app's blue content area — not stuck up
                    // in the nav bar's black chrome.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        iOSPillHeader
                    }
                    #endif
                } else {
                    TVShowsView(
                        vodStore: vodStore,
                        isPlaying: $isPlaying,
                        isDetailPushed: $isDetailPushed,
                        popRequested: $popRequested
                    )
                    #if os(iOS)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        iOSPillHeader
                    }
                    #endif
                }
            }
        }
    }

    #if os(iOS)
    /// Header rendered inside the search-bar-aware safe-area inset on
    /// iOS so the pill row sits on `Color.appBackground` below the
    /// nav bar + `.searchable` drawer.
    private var iOSPillHeader: some View {
        HStack {
            Spacer()
            pillRow
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.appBackground)
    }
    #endif
}
