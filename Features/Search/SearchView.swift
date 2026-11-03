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

    private static var shortTimeFmt: DateFormatter { ClockFormat.short() }

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
    /// action circles stay visible above it, never a sheet or cover. In this
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

    /// Row last opened from the results (Android GH #162): Back from the
    /// player lands on it again with the query and results intact.
    @State private var lastOpenedID: String?
    #if os(tvOS)
    @FocusState private var focusedRowID: String?
    #endif

    /// Guide-channel lookup for EPG result rows (channel name + logo, Android
    /// parity: "LIVE . Channel . start-end" with the channel's logo as the
    /// thumbnail). Rebuilt per search from the active playlist's channels.
    @State private var channelsByID: [String: ChannelDisplayItem] = [:]

    private static var rangeTimeFmt: DateFormatter { ClockFormat.short() }

    /// Shared middle of both layouts: scope chips + the four-way content.
    @ViewBuilder private var searchContent: some View {
        VStack(spacing: 0) {
            scopePicker.padding(.vertical, 8)
                // Never leave the selection parked on a chip that the
                // account's permissions just removed.
                .onChange(of: availableScopes) { _, scopes in
                    if !scopes.contains(scope) { scope = .all }
                }
                .onAppear { if !availableScopes.contains(scope) { scope = .all } }

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
            .onDismissSearch {
                if !query.isEmpty { query = "" }
            }
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
    /// NavigationStack, no title, no Cancel, the nav bar IS the chrome, and
    /// Menu (routed by the caller through `onClose`) leaves the screen.
    private var embeddedBody: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(.system(size: 26, weight: .medium))
                        .foregroundColor(theme.accent)
                    TextField("Search movies, shows, programs…", text: $query)
                        .textFieldStyle(.plain)
                        .scaledFont(.system(size: 28))
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

    /// The active server for capability gating. Mirrors the tab gates in
    /// MainTabView so search and the tab bar never disagree.
    private var searchActiveServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    /// Scopes this account may search. A Dispatcharr account denied
    /// `vod_movies_enabled` / `vod_series_enabled` loses the matching chip
    /// rather than being offered a catalog it cannot see, and loses "All"'s
    /// VOD half via `vodSearchAllowed` below. UNKNOWN never removes a chip.
    private var availableScopes: [SearchScope] {
        guard let active = searchActiveServer else { return SearchScope.allCases }
        return SearchScope.allCases.filter { s in
            switch s {
            case .movies: return active.dispatcharrCanViewVOD
            case .tv:     return active.dispatcharrCanViewSeries
            default:      return true
            }
        }
    }

    // MARK: - Scope Picker
    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableScopes, id: \.self) { s in
                    Button {
                        withAnimation(.spring(response: 0.25)) { scope = s }
                    } label: {
                        Text(s.rawValue)
                            .scaledFont(.labelMedium)
                            .foregroundColor(scope == s ? .appBackground : Color.contrastText(.textSecondary))
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
        #if os(tvOS)
        // Own focus region so Up from the first result lands on a chip even
        // when no chip sits straight above the focused row.
        .focusSection()
        #endif
    }

    // MARK: - Results List
    private var resultsList: some View {
        ScrollViewReader { proxy in
            List(results) { result in
                resultRow(result)
                    .id(result.id)
                    #if os(tvOS)
                    .focused($focusedRowID, equals: result.id)
                    #endif
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
            #if os(tvOS)
            // Back from a player opened out of the results (HomeView posts
            // this instead of the guide refocus while Search is up).
            .onReceive(NotificationCenter.default.publisher(for: .aerioSearchRestoreFocus)) { _ in
                guard let id = lastOpenedID,
                      let index = results.firstIndex(where: { $0.id == id }) else {
                    debugLog("[SEARCH] restore skipped: opened row not in results=\(results.count)")
                    return
                }
                debugLog("[SEARCH] restore results=\(results.count) index=\(index)")
                proxy.scrollTo(id, anchor: .center)
                Task { @MainActor in
                    // One frame so the row is laid out before focusing it.
                    try? await Task.sleep(for: .milliseconds(50))
                    focusedRowID = id
                }
            }
            .onChange(of: focusedRowID) { _, id in
                if let id, let i = results.firstIndex(where: { $0.id == id }) {
                    debugLog("[FOCUS] search:row\(i)")
                }
            }
            #endif
        }
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

    /// Program art the app already holds, no extra fetch (Android
    /// 999e4c82): the art the guide banner resolved this session (what
    /// Program Info opens with), then the program's own poster through the
    /// SSRF gate. Nil falls back to the channel logo in the row.
    private func programArtURL(_ prog: EPGProgram) -> URL? {
        #if os(tvOS)
        // The guide banner (and its art cache) is tvOS-only.
        if let held = GuidePreviewArtCache.shared.cachedArt(title: prog.title, programID: prog.programID) {
            return held
        }
        #endif
        return validatedPosterURL(.epg(prog))
    }

    /// A live airing plays its channel through the Live TV tap path
    /// (play-where prompt, Radio Mode, Mini Player setting) and Search stays
    /// up underneath, so Back from the player returns here (Android GH #162).
    /// A future airing, or one whose channel is not in the loaded list,
    /// jumps to the guide.
    private func openProgram(_ prog: EPGProgram) {
        #if os(tvOS)
        if embedsInTabChrome, prog.isLive,
           let ch = channelsByID[prog.channelID], !ch.streamURLs.isEmpty {
            debugLog("[SEARCH] live result: open channel")
            NotificationCenter.default.post(name: .aerioOpenChannel, object: nil,
                                            userInfo: ["channelID": ch.id])
            return
        }
        if embedsInTabChrome, prog.isLive {
            debugLog("[SEARCH] live result: channel not in the loaded list")
        }
        #else
        // iPhone and iPad (Android f08ebb04 parity): a live airing plays its
        // channel instead of jumping to the guide. Entering the player
        // closes Search on these platforms (standing rule 2026-09-16).
        if prog.isLive, let ch = channelsByID[prog.channelID], !ch.streamURLs.isEmpty {
            debugLog("[SEARCH] live result: open channel")
            if let onClose { onClose() } else { dismiss() }
            NotificationCenter.default.post(name: .aerioOpenChannel, object: nil,
                                            userInfo: ["channelID": ch.id])
            return
        }
        #endif
        jumpToGuide(prog)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            lastOpenedID = result.id
            switch result {
            case .vod(let item): selectedVODItem = item
            case .epg(let prog): openProgram(prog)
            }
        } label: {
            HStack(spacing: 12) {
                // Thumbnail: fixed 50x70 box so nothing shifts when art lands.
                switch result {
                case .vod:
                    AsyncImage(url: validatedPosterURL(result)) { phase in
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
                case .epg(let prog):
                    SearchProgramThumb(art: programArtURL(prog),
                                       logo: channelsByID[prog.channelID]?.logoURL,
                                       icon: prog.isLive ? "tv" : "calendar")
                }

                VStack(alignment: .leading, spacing: 4) {
                    let text = rowText(result)
                    Text(result.title)
                        .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                        .lineLimit(2)
                    Text(text.subtitle)
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textSecondary))
                        .lineLimit(1)
                    if let detail = text.detail {
                        Text(detail)
                            .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                            .lineLimit(2)
                    }

                    if case .epg(let prog) = result, prog.isLive {
                        LiveBadge()
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 12))
                    .foregroundColor(Color.contrastText(.textTertiary))
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
                .scaledFont(.system(size: 48)).foregroundColor(Color.contrastText(.textTertiary))
            Text("Search for movies, shows,\nor EPG programs")
                .scaledFont(.bodyMedium.subtext()).foregroundColor(Color.contrastText(.textSecondary))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var noResults: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .scaledFont(.system(size: 48)).foregroundColor(Color.contrastText(.textTertiary))
            Text("No results for \"\(query)\"")
                .scaledFont(.headlineMedium).foregroundColor(.textPrimary)
            Text("Try a different search term or change the scope filter.")
                .scaledFont(.bodyMedium.subtext()).foregroundColor(Color.contrastText(.textSecondary))
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
        var programCount = 0, movieCount = 0, seriesCount = 0

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
            let now = Date()
            // Android SearchViewModel / EpgProgrammeDao.searchInWindow
            // parity: title OR description, now-forward only (endTime > now)
            // so ended airings never take a slot, start order. The fetch
            // bound only protects SQLite; the 30-row cap is applied AFTER
            // the live-first sort and the per-airing de-duplication below.
            var descriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> { p in
                    p.serverID == sid
                    && p.endTime > now
                    && (p.title.localizedStandardContains(lowered)
                        || p.programDescription.localizedStandardContains(lowered))
                },
                sortBy: [SortDescriptor(\.startTime)]
            )
            descriptor.fetchLimit = 200
            let epgMatches = (try? modelContext.fetch(descriptor)) ?? []
            let epgResults = GlobalSearchRanking.rankPrograms(
                epgMatches, now: now,
                start: { $0.startTime }, end: { $0.endTime },
                channelKey: { $0.channelID })
            programCount = epgResults.count
            found += epgResults.map { .epg($0) }
        }

        // VOD search. The old path re-downloaded the complete movie+series
        // catalog from EVERY configured server on the first keystroke (ten
        // servers here; the log showed the whole fan-out being cancelled and
        // re-fired per keypress). The active playlist's library is already
        // resident in VODStore -- filter that, off the MainActor.
        if scope != .epg {
            // Dispatcharr 0.30 per-user permissions: a denied half never
            // contributes results, including under the "All" scope. The
            // store is normally already empty for a denied account (the
            // load paths clear it and the snapshot restore is gated), but
            // search must not depend on that ordering.
            let active = searchActiveServer
            let allowMovies = active.map { $0.dispatcharrCanViewVOD } ?? true
            let allowSeries = active.map { $0.dispatcharrCanViewSeries } ?? true
            // Titles the user hid never surface in search (Logan
            // 2026-09-14): filter here, before the detached match.
            // The catalog answers this with an indexed query off the main
            // actor; there is no resident library array to walk any more.
            let hidden = HiddenVODStore.shared.snapshot(serverID: searchActiveServer?.id.uuidString)
            // Android caps: 25 movies plus 25 series (was 50 combined, so a
            // long movie list could starve the series half).
            var vodResults: [VODDisplayItem] = []
            if allowMovies, scope != .tv {
                let movies = await VODStore.shared.searchCatalog(kind: .movie, query: lowered,
                                                                 hiddenTitleKeys: hidden)
                    .prefix(GlobalSearchRanking.movieCap)
                movieCount = movies.count
                vodResults += movies
            }
            if allowSeries, scope != .movies {
                let series = await VODStore.shared.searchCatalog(kind: .series, query: lowered,
                                                                 hiddenTitleKeys: hidden)
                    .prefix(GlobalSearchRanking.seriesCap)
                seriesCount = series.count
                vodResults += series
            }
            found += vodResults.map { .vod($0) }
        }

        // Drop a stale pass if the user kept typing past this query.
        guard query.trimmingCharacters(in: .whitespaces) == q.trimmingCharacters(in: .whitespaces) else { return }
        // Counts only, never the query text.
        DebugLogger.shared.log(
            "[SEARCH] query q=\(q.count) scope=\(scope.rawValue) programs=\(programCount) movies=\(movieCount) series=\(seriesCount)",
            category: "Search", level: .info)
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

extension Notification.Name {
    /// Posted by HomeView when a player opened from Search closes while the
    /// tvOS in-place Search is still up: Search refocuses the opened row.
    static let aerioSearchRestoreFocus = Notification.Name("aerioSearchRestoreFocus")
}

/// EPG result thumbnail (Android SearchScreen ResultRow): program art when
/// held, else the channel logo (also when the art fails to load), both
/// fitted inside the fixed 50x70 box; the logo keeps 5 pt of breathing room.
private struct SearchProgramThumb: View {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let art: URL?
    let logo: URL?
    let icon: String
    @State private var artFailed = false

    var body: some View {
        let showArt = art != nil && !artFailed
        let url = showArt ? art : logo
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.elevatedBackground)
            .frame(width: 50, height: 70)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fit)
                                .padding(showArt ? 0 : 5)
                        case .failure:
                            Image(systemName: icon).foregroundColor(.textTertiary)
                                .onAppear { if showArt { artFailed = true } }
                        default:
                            Color.clear
                        }
                    }
                    .id(url)
                } else {
                    Image(systemName: icon).foregroundColor(.textTertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
