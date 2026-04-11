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

    var body: some View {
        VStack(spacing: 0) {
            Picker("Content", selection: $segment) {
                Text("Movies").tag(0)
                Text("Series").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

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
