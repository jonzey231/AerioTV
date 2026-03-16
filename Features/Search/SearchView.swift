import SwiftUI
import SwiftData

// MARK: - Search Scope
enum SearchScope: String, CaseIterable {
    case all     = "All"
    case movies  = "Movies"
    case tv      = "TV Shows"
    case epg     = "EPG"
}

// MARK: - Search Result
enum SearchResult: Identifiable {
    case vod(VODDisplayItem)
    case epg(EPGProgram)

    var id: String {
        switch self {
        case .vod(let item): return "vod-\(item.id)"
        case .epg(let prog): return "epg-\(prog.id)"
        }
    }

    var title: String {
        switch self {
        case .vod(let item): return item.name
        case .epg(let prog): return prog.title
        }
    }

    var subtitle: String {
        switch self {
        case .vod(let item):
            switch item.type {
            case .movie:  return "Movie · \(item.releaseYear)"
            case .series: return "TV Show"
            case .episode: return "Episode"
            }
        case .epg(let prog):
            let fmt = DateFormatter()
            fmt.dateStyle = .none
            fmt.timeStyle = .short
            let time = fmt.string(from: prog.startTime)
            return prog.isLive ? "LIVE · \(time)" : time
        }
    }

    var iconName: String {
        switch self {
        case .vod(let item):
            switch item.type {
            case .movie: return "film"
            case .series: return "tv"
            case .episode: return "play.tv"
            }
        case .epg: return "calendar"
        }
    }

    var posterURL: URL? {
        switch self {
        case .vod(let item): return item.posterURL
        case .epg(let prog): return URL(string: prog.posterURL)
        }
    }
}

// MARK: - Search View
struct SearchView: View {
    @Query private var servers: [ServerConnection]
    @Query private var epgPrograms: [EPGProgram]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var vodCache: [UUID: [VODDisplayItem]] = [:]
    @State private var selectedVODItem: VODDisplayItem?
    @State private var isPlaying = false

    // Debounce
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    scopePicker.padding(.vertical, 8)

                    if query.isEmpty {
                        searchPrompt
                    } else if isSearching {
                        LoadingView(message: "Searching...")
                    } else if results.isEmpty {
                        noResults
                    } else {
                        resultsList
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(theme.accent)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search movies, shows, programs...")
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .onChange(of: scope) { _, _ in
                if !query.isEmpty { scheduleSearch(query) }
            }
        }
        .sheet(item: $selectedVODItem) { item in
            NavigationStack {
                VODDetailView(item: item, isPlaying: $isPlaying)
            }
        }
    }

    // MARK: - Scope Picker
    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases, id: \.self) { s in
                    Button {
                        withAnimation(.spring(response: 0.25)) { scope = s }
                    } label: {
                        Text(s.rawValue)
                            .font(.labelMedium)
                            .foregroundColor(scope == s ? .appBackground : .textSecondary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(
                                scope == s
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

    // MARK: - Results List
    private var resultsList: some View {
        List(results) { result in
            resultRow(result)
                .listRowBackground(Color.cardBackground)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .background(Color.appBackground)
        .scrollContentBackground(.hidden)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            switch result {
            case .vod(let item): selectedVODItem = item
            case .epg: break // EPG tap — could navigate to guide/channel
            }
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                AsyncImage(url: result.posterURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.elevatedBackground)
                            .frame(width: 50, height: 70)
                            .overlay(Image(systemName: result.iconName)
                                        .foregroundColor(.textTertiary))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.bodyMedium).foregroundColor(.textPrimary)
                        .lineLimit(2)
                    Text(result.subtitle)
                        .font(.labelSmall).foregroundColor(.textSecondary)

                    if case .epg(let prog) = result, prog.isLive {
                        LiveBadge()
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Placeholder Views
    private var searchPrompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48)).foregroundColor(.textTertiary)
            Text("Search for movies, shows,\nor EPG programs")
                .font(.bodyMedium).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var noResults: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48)).foregroundColor(.textTertiary)
            Text("No results for \"\(query)\"")
                .font(.headlineMedium).foregroundColor(.textPrimary)
            Text("Try a different search term or change the scope filter.")
                .font(.bodyMedium).foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Search Logic

    private func scheduleSearch(_ newQuery: String) {
        searchTask?.cancel()
        guard !newQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            await performSearch(newQuery)
        }
    }

    @MainActor
    private func performSearch(_ q: String) async {
        isSearching = true
        let lowered = q.lowercased()
        var found: [SearchResult] = []

        // EPG Search (fast — local SwiftData query)
        if scope == .all || scope == .epg {
            let epgResults = epgPrograms.filter {
                $0.title.localizedCaseInsensitiveContains(lowered)
                || $0.programDescription.localizedCaseInsensitiveContains(lowered)
            }
            .sorted { a, b in
                // Live programs first, then upcoming, then past
                if a.isLive != b.isLive { return a.isLive }
                return a.startTime < b.startTime
            }
            .prefix(30)
            found += epgResults.map { .epg($0) }
        }

        // VOD Search — need to fetch from servers
        if scope != .epg {
            // Ensure VOD is cached
            await ensureVODCache()

            let allVOD = vodCache.values.flatMap { $0 }
            let vodResults = allVOD.filter {
                $0.name.localizedCaseInsensitiveContains(lowered)
            }

            let filtered: [VODDisplayItem]
            switch scope {
            case .movies:  filtered = vodResults.filter { $0.type == .movie }
            case .tv:      filtered = vodResults.filter { $0.type == .series }
            default:       filtered = vodResults
            }

            found += filtered.prefix(50).map { .vod($0) }
        }

        results = found
        isSearching = false
    }

    @MainActor
    private func ensureVODCache() async {
        let vodServers = servers.filter({ $0.supportsVOD })
        for server in vodServers {
            if vodCache[server.id] == nil {
                nonisolated(unsafe) let serverRef = server
                var items: [VODDisplayItem] = []
                if let (movies, _) = try? await VODService.fetchMovies(from: serverRef) {
                    items += movies.map { VODDisplayItem(movie: $0) }
                }
                if let (series, _) = try? await VODService.fetchSeries(from: serverRef) {
                    items += series.map { VODDisplayItem(series: $0) }
                }
                vodCache[server.id] = items
            }
        }
    }
}
