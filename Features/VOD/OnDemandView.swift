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

    #if os(iOS)
    /// Used (together with `UIDevice.userInterfaceIdiom`) to detect
    /// "full-width iPad" vs. "iPhone-or-Split-View-iPad" so we only
    /// apply the iPadOS 18 floating-TabView top-padding fix when a
    /// floating TabView is actually present. Compact width = bottom
    /// tab bar, no padding needed.
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    /// Pill pair used as the "Movies / Series" segment selector on
    /// both platforms. On both tvOS and iOS/iPadOS the pills sit
    /// above the inner media grid as a plain VStack child — this
    /// keeps them clear of iPadOS 18+'s floating TabView capsule,
    /// which overlapped the pills when they were attached via
    /// `.safeAreaInset(edge: .top)` on MoviesView/TVShowsView.
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
                #else
                // iOS / iPadOS: pill row renders above the inner
                // NavigationStack (matching tvOS's layout). The row
                // itself does the work of dodging iPadOS 18+'s
                // floating TabView capsule — see `iOSPillHeader`'s
                // `extraTopPadding` for the 72pt kick that pushes
                // the pills below the floating bar when present.
                iOSPillHeader
                #endif

                if segment == 0 {
                    MoviesView(
                        vodStore: vodStore,
                        isPlaying: $isPlaying,
                        isDetailPushed: $isDetailPushed,
                        popRequested: $popRequested
                    )
                } else {
                    TVShowsView(
                        vodStore: vodStore,
                        isPlaying: $isPlaying,
                        isDetailPushed: $isDetailPushed,
                        popRequested: $popRequested
                    )
                }
            }
        }
    }

    #if os(iOS)
    /// Pill row rendered above the inner NavigationStack. Explicit
    /// `Color.appBackground` matches the surrounding blue so the row
    /// reads as part of the app content, not the TabView's chrome.
    ///
    /// iPad needs extra top padding because iPadOS 18+'s floating
    /// TabView capsule does NOT consume top safe area — content
    /// placed at the view's safe-area top still ends up visually
    /// behind the floating capsule (see
    /// `https://developer.apple.com/documentation/swiftui/tabview`
    /// changelog for iOS 18). `72pt` is tuned to clear the floating
    /// bar's ~54pt capsule height plus an 18pt breathing gap, and
    /// works in both portrait and landscape. iPhone keeps zero
    /// extra padding because its TabView lives at the bottom —
    /// top of content is just below the status bar, no collision.
    /// Split View on iPad drops to `.compact` horizontalSizeClass
    /// which (per Apple) falls back to a bottom tab bar, so we
    /// cross-check with the size class too.
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

    private var extraTopPadding: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad && hSize == .regular {
            return 72
        }
        return 10
    }
    #endif
}
