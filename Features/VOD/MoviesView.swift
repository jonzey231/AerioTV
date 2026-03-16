import SwiftUI
import SwiftData

// MARK: - Movies View
struct MoviesView: View {
    @Query private var servers: [ServerConnection]
    @ObservedObject private var theme = ThemeManager.shared
    @Binding var isPlaying: Bool

    @State private var allMovies: [VODDisplayItem] = []
    @State private var filteredMovies: [VODDisplayItem] = []
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

                if !servers.filter({ $0.supportsVOD }).isEmpty && allMovies.isEmpty && !isLoading {
                    emptyState
                } else if isLoading {
                    LoadingView(message: "Loading movies...")
                } else if let err = errorMessage {
                    errorView(err)
                } else {
                    content
                }
            }
            .navigationTitle("Movies")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    serverPickerMenu
                }
            }
            .task { await loadMovies() }
            .onChange(of: selectedCategory) { _, _ in filterMovies() }
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
                    ForEach(filteredMovies) { item in
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
                    Task { await loadMovies() }
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
            icon: "film.stack",
            title: "No Movies",
            message: "Add an Xtream Codes or Dispatcharr server to browse movies.",
            action: { Task { await loadMovies() } },
            actionTitle: "Refresh"
        )
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundColor(.statusWarning)
            Text("Failed to load movies")
                .font(.headlineLarge).foregroundColor(.textPrimary)
            Text(msg)
                .font(.bodyMedium).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton("Try Again") { Task { await loadMovies() } }
                .frame(maxWidth: 200)
        }
        .padding(32)
    }

    // MARK: - Load

    func loadMovies() async {
        let vodServers = servers.filter({ $0.supportsVOD })
        guard let server = selectedServer ?? vodServers.first else { return }
        selectedServer = server
        isLoading = true
        errorMessage = nil

        do {
            nonisolated(unsafe) let serverRef = server
            let (movies, cats) = try await VODService.fetchMovies(from: serverRef)
            allMovies = movies.map { VODDisplayItem(movie: $0) }
            categories = cats.filter { $0.itemCount > 0 }
            filterMovies()
        } catch let err as APIError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func filterMovies() {
        if selectedCategory == "All" {
            filteredMovies = allMovies
        } else {
            filteredMovies = allMovies.filter { $0.movie?.categoryName == selectedCategory }
        }
    }
}

// MARK: - VOD Poster Card
struct VODPosterCard: View {
    let item: VODDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Poster image
            AsyncImage(url: item.posterURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(2/3, contentMode: .fill)
                        .clipped()
                default:
                    Rectangle()
                        .fill(Color.cardBackground)
                        .aspectRatio(2/3, contentMode: .fit)
                        .overlay {
                            Image(systemName: item.type == .movie ? "film" : "tv")
                                .font(.system(size: 28))
                                .foregroundColor(.textTertiary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if !item.rating.isEmpty {
                    Text(item.rating)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
            }

            // Title
            Text(item.name)
                .font(.labelSmall)
                .foregroundColor(.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !item.releaseYear.isEmpty {
                Text(item.releaseYear)
                    .font(.system(size: 10))
                    .foregroundColor(.textTertiary)
            }
        }
    }
}
