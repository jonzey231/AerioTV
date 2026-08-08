import SwiftUI
import SwiftData

/// The Home section of the Movies & TV tab.
///
/// Structure (dossier section 5.3), every row hidden when empty:
///   1. Continue Watching, movies and episodes merged
///   2. Recently Added, one shelf per PERSONAL library
///   3. Recently Added, one shelf per provider catalog
///
/// Row composition is delegated wholesale to `HomeRowsBuilder` so the layout
/// rules can be tested without a ModelContainer. This view's job is to feed it
/// snapshots and render the result.
///
/// When the catalog has not been populated (a stock server mid-first-sync, or a
/// build where ingest is unavailable) the shelves simply do not appear and Home
/// falls back to Continue Watching alone. That is a legitimate state, not an
/// error: the Movies and TV Shows sections still hold the full library.
struct MediaHomeView: View {
    @ObservedObject var vodStore: VODStore
    var headers: [String: String] = [:]
    /// Push a detail page. Home does not own a NavigationStack; the root does.
    var onOpenItem: (VODDisplayItem) -> Void
    /// Open the grid pre-scoped to a library.
    var onSeeAll: (HomeRowsBuilder.Shelf) -> Void
    /// Resume playback from a Continue Watching card.
    var onResume: (WatchProgress) -> Void

    @Environment(\.modelContext) private var modelContext

    /// Shelves are recomputed when the catalog publishes a new generation
    /// (at most once every 2s by contract) rather than on every render.
    @State private var shelves: [HomeRowsBuilder.Shelf] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                // Merged Continue Watching: vodType nil selects the merged rail.
                ContinueWatchingSection(
                    vodType: nil,
                    headers: headers,
                    onPlay: onResume,
                    series: vodStore.series,
                    onOpenSeries: onOpenItem
                )

                ForEach(shelves) { shelf in
                    MediaShelfRow(
                        title: shelf.title,
                        items: shelf.items,
                        headers: headers,
                        onSeeAll: { onSeeAll(shelf) }
                    )
                }

                if shelves.isEmpty && vodStore.isLoadingMovies {
                    HStack {
                        Spacer()
                        ProgressView("Syncing library…")
                            .tint(.accentPrimary)
                        Spacer()
                    }
                    .padding(.top, 40)
                }

                #if os(iOS)
                // Clear the floating tab bar + home indicator.
                Color.clear.frame(height: 96)
                #endif
            }
            .padding(.top, 12)
        }
        .task { rebuildShelves() }
        .onChange(of: vodStore.movies.count) { _, _ in rebuildShelves() }
        .onChange(of: vodStore.series.count) { _, _ in rebuildShelves() }
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        36
        #else
        20
        #endif
    }

    /// Build the Recently Added shelves from the in-memory catalog.
    ///
    /// Phase A2 sources these from VODStore, which the A1 facade already fills
    /// from the catalog. Phase A6 swaps the input for direct catalog
    /// FetchDescriptors scoped per library; `HomeRowsBuilder` does not change,
    /// which is the point of keeping it pure.
    private func rebuildShelves() {
        // Add times live only on the catalog rows, so pull them once per
        // rebuild rather than per item. Empty when the catalog has not ingested
        // yet, in which case the builder falls back to alphabetical order.
        let createdAt = MediaCatalogStore.shared.createdAtIndex()

        let snapshots = (vodStore.movies + vodStore.series).map { item in
            let derived = library(for: item)
            let name = derived.displayName
            return HomeRowsBuilder.CatalogSnapshot(
                item: item,
                libraryKey: derived.key,
                libraryDisplayName: name.isEmpty ? "Recently Added" : name,
                isPersonalLibrary: derived.isPersonal,
                createdAt: createdAt["\(item.serverID.uuidString)|\(item.id)"]
            )
        }
        shelves = HomeRowsBuilder.recentlyAddedShelves(from: snapshots)
    }

    // MARK: - Library facts
    //
    // Derived through LibraryDeriver so the marker detection and namespace
    // parsing live in exactly one place (dossier section 5.4). On a stock
    // server every item resolves to a provider catalog and nothing breaks.

    /// Personal-library detection needs the provider relation marker, which the
    /// current fetch path does not surface. Until that plumbing lands with the
    /// media-library phase every category derives as a provider catalog, which
    /// is exactly the stock-server behaviour and therefore correct today. The
    /// call site does not change when the marker arrives; only this flag does.
    private func library(for item: VODDisplayItem) -> LibraryDeriver.Library {
        LibraryDeriver.parse(
            categoryName: item.movie?.categoryName ?? item.series?.categoryName ?? "",
            categoryType: item.type == .movie ? "movie" : "series",
            serverID: item.serverID.uuidString,
            isPersonal: false
        )
    }
}
