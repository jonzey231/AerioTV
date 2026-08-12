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

    private static let shortTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

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
            let time = Self.shortTimeFmt.string(from: prog.startTime)
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
    /// tvOS in-place mode (Logan 2026-08-12, matching Android TV): the Search
    /// circle swaps the tab CONTENT for this screen while the nav bar and
    /// action circles stay visible above it — never a sheet or cover. In this
    /// mode the NavigationStack chrome (title, Cancel, `.searchable`) is
    /// replaced by an inline field + the same scope chips and results.
    var embedsInTabChrome = false
    /// How the embedded mode closes (Menu press / EPG jump); presentation
    /// mode keeps using `dismiss`.
    var onClose: (() -> Void)? = nil

    @Query private var servers: [ServerConnection]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var selectedVODItem: VODDisplayItem?
    @State private var isPlaying = false

    // Debounce
    @State private var searchTask: Task<Void, Never>?

    /// Guide-channel lookup for EPG result rows (channel name + logo, Android
    /// parity: "LIVE . Channel . start-end" with the channel's logo as the
    /// thumbnail). Rebuilt per search from the active playlist's channels.
    @State private var channelsByID: [String: ChannelDisplayItem] = [:]

    private static let rangeTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Shared middle of both layouts: scope chips + the four-way content.
    @ViewBuilder private var searchContent: some View {
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

    var body: some View {
        if embedsInTabChrome {
            embeddedBody
        } else {
            presentedBody
        }
    }

    /// The iOS presentation (sheet) and any other presented context.
    private var presentedBody: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                searchContent
            }
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(theme.accent)
                }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search movies, shows, programs...")
            #else
            .searchable(text: $query, prompt: "Search movies, shows, programs...")
            #endif
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

    /// tvOS in-place layout: an inline search field row + the shared scope
    /// chips and results, rendered as tab content below the persistent nav
    /// chrome (which the caller keeps visible above this view). No
    /// NavigationStack, no title, no Cancel — the nav bar IS the chrome, and
    /// Menu (routed by the caller through `onClose`) leaves the screen.
    private var embeddedBody: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(theme.accent)
                    TextField("Search movies, shows, programs…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28))
                        .foregroundColor(.textPrimary)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.elevatedBackground.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(theme.accent.opacity(0.35), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 40)

                searchContent
            }
            // Clears the persistent nav chrome band the caller leaves visible.
            .padding(.top, 24)
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
        .onChange(of: scope) { _, _ in
            if !query.isEmpty { scheduleSearch(query) }
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
                    #if os(tvOS)
                    .buttonStyle(TVNoHighlightButtonStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
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
                #if os(iOS)
                .listRowSeparator(.hidden)
                #endif
        }
        .listStyle(.plain)
        .background(Color.appBackground)
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
    }

    /// SSRF gate for the search-result thumbnail. VOD posters are already
    /// validated by VODService when the item is built, so they pass through.
    /// EPG poster URLs are untrusted feed data: allow any configured server's
    /// host (LAN or WAN) and otherwise block loopback / link-local / private
    /// SSRF targets via VODService.validateAbsoluteURL.
    private func validatedPosterURL(_ result: SearchResult) -> URL? {
        switch result {
        case .vod:
            return result.posterURL
        case .epg(let prog):
            guard let url = URL(string: prog.posterURL),
                  let host = url.host?.lowercased() else { return nil }
            let serverHosts: Set<String> = Set(servers.flatMap { s in
                [s.effectiveBaseURL, s.normalizedBaseURL, s.normalizedLocalURL]
                    .compactMap { URL(string: $0)?.host?.lowercased() }
            })
            if serverHosts.contains(host) { return url }
            return VODService.validateAbsoluteURL(url, serverHost: nil)
        }
    }

    /// Subtitle + detail line, Android SearchScreen parity: EPG rows carry
    /// the channel name and full time range with the programme description
    /// underneath; VOD rows carry the plot.
    private func rowText(_ result: SearchResult) -> (subtitle: String, detail: String?) {
        switch result {
        case .vod(let item):
            let detail = (item.movie?.plot ?? item.series?.plot)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (result.subtitle, (detail?.isEmpty ?? true) ? nil : detail)
        case .epg(let prog):
            let range = Self.rangeTimeFmt.string(from: prog.startTime)
                + " \u{2013} " + Self.rangeTimeFmt.string(from: prog.endTime)
            let parts = [channelsByID[prog.channelID]?.name, range].compactMap { $0 }
            let detail = prog.programDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return (parts.joined(separator: " \u{00B7} "), detail.isEmpty ? nil : detail)
        }
    }

    /// EPG rows thumbnail with the CHANNEL's logo (already SSRF-validated at
    /// channel build time); programme art is the fallback.
    private func rowThumbnailURL(_ result: SearchResult) -> URL? {
        if case .epg(let prog) = result,
           let logo = channelsByID[prog.channelID]?.logoURL {
            return logo
        }
        return validatedPosterURL(result)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            switch result {
            case .vod(let item): selectedVODItem = item
            case .epg(let prog): jumpToGuide(prog)
            }
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                AsyncImage(url: rowThumbnailURL(result)) { phase in
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
                    let text = rowText(result)
                    Text(result.title)
                        .font(.bodyMedium).foregroundColor(.textPrimary)
                        .lineLimit(2)
                    Text(text.subtitle)
                        .font(.labelSmall).foregroundColor(.textSecondary)
                        .lineLimit(1)
                    if let detail = text.detail {
                        Text(detail)
                            .font(.labelSmall).foregroundColor(.textTertiary)
                            .lineLimit(2)
                    }

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
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
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
        // Per-playlist scope (Logan 2026-08-12): search the ACTIVE playlist,
        // like every other media surface.
        let activeServerID = (servers.first(where: { $0.isActive }) ?? servers.first)?.id.uuidString
        var found: [SearchResult] = []

        // EPG search. This used to be an in-memory filter over a @Query of
        // the ENTIRE EPG cache -- materializing ~258k SwiftData models and
        // string-scanning them on the MainActor, which froze the app on the
        // first keystroke of any large playlist (ATV repro 2026-08-12). The
        // predicate + fetchLimit push the match into SQLite: only the
        // handful of hits ever become model objects.
        if scope == .all || scope == .epg {
            channelsByID = Dictionary(
                ChannelStore.shared.channels.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            let sid = activeServerID ?? ""
            var descriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> { p in
                    p.serverID == sid
                    && (p.title.localizedStandardContains(lowered)
                        || p.programDescription.localizedStandardContains(lowered))
                },
                sortBy: [SortDescriptor(\.startTime)]
            )
            descriptor.fetchLimit = 60
            let epgMatches = (try? modelContext.fetch(descriptor)) ?? []
            let epgResults = epgMatches
                .sorted { a, b in
                    // Live programs first, then upcoming, then past
                    if a.isLive != b.isLive { return a.isLive }
                    return a.startTime < b.startTime
                }
                .prefix(30)
            found += epgResults.map { .epg($0) }
        }

        // VOD search. The old path re-downloaded the complete movie+series
        // catalog from EVERY configured server on the first keystroke (ten
        // servers here; the log showed the whole fan-out being cancelled and
        // re-fired per keypress). The active playlist's library is already
        // resident in VODStore -- filter that, off the MainActor.
        if scope != .epg {
            let movies = VODStore.shared.movies
            let series = VODStore.shared.series
            let searchScope = scope
            let vodResults: [VODDisplayItem] = await Task.detached(priority: .userInitiated) {
                let pool: [VODDisplayItem]
                switch searchScope {
                case .movies: pool = movies
                case .tv:     pool = series
                default:      pool = movies + series
                }
                return Array(
                    pool.lazy
                        .filter { $0.name.localizedCaseInsensitiveContains(lowered) }
                        .prefix(50)
                )
            }.value

            found += vodResults.map { .vod($0) }
        }

        results = found
        isSearching = false
    }

    /// Tapping an EPG search result jumps to that program in the Live
    /// TV guide. We stash the target (channel id + start time) in
    /// UserDefaults so the guide can consume it even if it isn't
    /// mounted yet (cold path), dismiss this sheet, then post the
    /// warm-path trigger that switches to the Live TV tab + guide mode.
    /// `prog.channelID` already equals the guide's channel key
    /// (ChannelDisplayItem.id), so no tvg-id/name matching is needed.
    private func jumpToGuide(_ prog: EPGProgram) {
        let defaults = UserDefaults.standard
        defaults.set(prog.channelID, forKey: "guideJumpChannelID")
        defaults.set(prog.startTime.timeIntervalSince1970, forKey: "guideJumpStart")
        if let onClose { onClose() } else { dismiss() }
        NotificationCenter.default.post(name: .aerioJumpToGuideProgram, object: nil)
    }
}
