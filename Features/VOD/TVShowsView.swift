import SwiftUI
import SwiftData

// MARK: - TV Shows View
struct TVShowsView: View {
    @Query private var servers: [ServerConnection]
    @ObservedObject private var theme = ThemeManager.shared
    @Binding var isPlaying: Bool

    @State private var allShows: [VODDisplayItem] = []
    @State private var filteredShows: [VODDisplayItem] = []
    @State private var categories: [VODCategory] = []
    @State private var selectedCategory = "All"
    @State private var selectedServer: ServerConnection?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if !servers.filter({ $0.supportsVOD }).isEmpty && allShows.isEmpty && !isLoading {
                    emptyState
                } else if isLoading {
                    LoadingView(message: "Loading TV shows...")
                } else if let err = errorMessage {
                    errorView(err)
                } else {
                    content
                }
            }
            .navigationTitle("TV")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    serverPickerMenu
                }
            }
            .task { await loadShows() }
            .onChange(of: selectedCategory) { _, _ in filterShows() }
        }
    }

    // MARK: - Content
    private var content: some View {
        VStack(spacing: 0) {
            if categories.count > 1 {
                categoryFilterBar.padding(.vertical, 10)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredShows) { item in
                        NavigationLink(destination: VODDetailView(item: item, isPlaying: $isPlaying)) {
                            VODPosterCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Category Filter
    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["All"] + categories.map(\.name), id: \.self) { cat in
                    Button {
                        withAnimation(.spring(response: 0.25)) { selectedCategory = cat }
                    } label: {
                        Text(cat)
                            .font(.labelMedium)
                            .foregroundColor(selectedCategory == cat ? .appBackground : .textSecondary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(
                                selectedCategory == cat
                                    ? AnyView(Capsule().fill(theme.accent))
                                    : AnyView(Capsule().fill(Color.elevatedBackground))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Server Picker
    private var serverPickerMenu: some View {
        let vodServers = servers.filter({ $0.supportsVOD })
        return Menu {
            ForEach(vodServers) { server in
                Button {
                    selectedServer = server
                    Task { await loadShows() }
                } label: {
                    Label(server.name, systemImage: server.type.systemIcon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedServer?.name ?? "Select")
                    .font(.labelMedium).foregroundColor(theme.accent)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(theme.accent)
            }
        }
    }

    // MARK: - Empty / Error
    private var emptyState: some View {
        EmptyStateView(
            icon: "tv",
            title: "No TV Shows",
            message: "Add an Xtream Codes or Dispatcharr server to browse TV shows.",
            action: { Task { await loadShows() } },
            actionTitle: "Refresh"
        )
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundColor(.statusWarning)
            Text("Failed to load TV shows")
                .font(.headlineLarge).foregroundColor(.textPrimary)
            Text(msg)
                .font(.bodyMedium).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton("Try Again") { Task { await loadShows() } }
                .frame(maxWidth: 200)
        }
        .padding(32)
    }

    // MARK: - Load

    func loadShows() async {
        let vodServers = servers.filter({ $0.supportsVOD })
        guard let server = selectedServer ?? vodServers.first else { return }
        selectedServer = server
        isLoading = true
        errorMessage = nil

        do {
            nonisolated(unsafe) let serverRef = server
            let (series, cats) = try await VODService.fetchSeries(from: serverRef)
            allShows = series.map { VODDisplayItem(series: $0) }
            categories = cats.filter { $0.itemCount > 0 }
            filterShows()
        } catch let err as APIError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func filterShows() {
        if selectedCategory == "All" {
            filteredShows = allShows
        } else {
            filteredShows = allShows.filter { $0.series?.categoryName == selectedCategory }
        }
    }
}
