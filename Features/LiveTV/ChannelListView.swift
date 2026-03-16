import SwiftUI
import SwiftData

// MARK: - Channel List View
struct ChannelListView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingManager
    @EnvironmentObject private var favoritesStore: FavoritesStore

    @Query private var servers: [ServerConnection]
    @State private var channels: [ChannelDisplayItem] = []
    @State private var filteredChannels: [ChannelDisplayItem] = []
    @State private var orderedGroups: [String] = []           // preserves API order
    @State private var searchText: String = ""
    @State private var selectedGroup: String = "All"
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var selectedServer: ServerConnection? = nil
    @State private var epgChannelCount: Int = 0
    @State private var epgErrorMessage: String? = nil

    var body: some View {
        NavigationStack {
            mainContent
                .navigationTitle("Live TV")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Color.appBackground, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { serverPickerMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await loadChannels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                        .foregroundColor(.accentPrimary)
                    }
                }
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search channels")
                .onChange(of: searchText) { _, _ in filterChannels() }
                .onChange(of: selectedGroup) { _, _ in filterChannels() }
                .task { await loadChannels() }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if servers.isEmpty {
                EmptyStateView(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "No Servers",
                    message: "Add a server in Settings to browse Live TV channels."
                )
            } else if isLoading {
                LoadingView(message: "Loading channels...")
            } else if let error = errorMessage {
                errorView(error)
            } else if channels.isEmpty {
                EmptyStateView(
                    icon: "tv",
                    title: "No Channels",
                    message: "No channels found.",
                    action: { Task { await loadChannels() } },
                    actionTitle: "Refresh"
                )
            } else {
                channelListContent
            }
        }
    }

    private func playerHeaders(for server: ServerConnection?) -> [String: String] {
        guard let server else { return ["Accept": "*/*"] }
        switch server.type {
        case .dispatcharrAPI:
            let key = server.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                "Authorization": "ApiKey \(key)",
                "X-API-Key": key,
                "Accept": "*/*"
            ]
        default:
            return ["Accept": "*/*"]
        }
    }

    // MARK: - Channel List Content
    private var channelListContent: some View {
        VStack(spacing: 0) {
            // Group filter pills
            if orderedGroups.count > 1 {
                groupFilterBar.padding(.vertical, 10)
            }

            List {
                ForEach(filteredChannels) { item in
                    ChannelRow(item: item, onTap: {
                        if !item.streamURLs.isEmpty {
                            nowPlaying.startPlaying(item, headers: playerHeaders(for: selectedServer))
                        }
                    }, fetchUpcoming: makeFetchUpcoming(for: item))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .background(Color.appBackground)
            .scrollContentBackground(.hidden)
            .refreshable { await loadChannels() }
        }
    }

    // MARK: - Group Filter Bar
    private var groupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["All"] + orderedGroups, id: \.self) { group in
                    Button {
                        withAnimation(.spring(response: 0.25)) { selectedGroup = group }
                    } label: {
                        Text(group)
                            .font(.labelMedium)
                            .foregroundColor(selectedGroup == group ? .appBackground : .textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedGroup == group
                                    ? AnyView(Capsule().fill(Color.accentPrimary))
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
        Menu {
            ForEach(servers) { server in
                Button {
                    selectedServer = server
                    Task { await loadChannels() }
                } label: {
                    Label(server.name, systemImage: server.type.systemIcon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedServer?.name ?? "Select")
                    .font(.labelMedium)
                    .foregroundColor(.accentPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentPrimary)
            }
        }
    }

    // MARK: - Error View
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.statusWarning)
            Text("Connection Error")
                .font(.headlineLarge)
                .foregroundColor(.textPrimary)
            Text(message)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton("Try Again") { Task { await loadChannels() } }
                .frame(maxWidth: 200)
        }
        .padding(32)
    }


    // MARK: - Sorting helpers
    private func numericChannelValue(_ value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Double.greatestFiniteMagnitude }
        if let direct = Double(trimmed) { return direct }
        var seenDot = false
        var collected = ""
        for ch in trimmed {
            if ch >= "0" && ch <= "9" { collected.append(ch); continue }
            if ch == "." && !seenDot { seenDot = true; collected.append(ch); continue }
            break
        }
        if collected.isEmpty { return Double.greatestFiniteMagnitude }
        if collected.last == "." { collected.removeLast() }
        return Double(collected) ?? Double.greatestFiniteMagnitude
    }

    private func sortChannelsForDisplay(_ items: [ChannelDisplayItem], groupOrder: [String]) -> [ChannelDisplayItem] {
        let groupIndex: [String: Int] = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { ($1, $0) })
        return items.sorted {
            let n0 = numericChannelValue($0.number)
            let n1 = numericChannelValue($1.number)
            if n0 != n1 { return n0 < n1 }
            let g0 = groupIndex[$0.group] ?? Int.max
            let g1 = groupIndex[$1.group] ?? Int.max
            if g0 != g1 { return g0 < g1 }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Load Channels
    func loadChannels() async {
        guard let server = selectedServer ?? servers.first else { return }
        selectedServer = server
        isLoading = true
        errorMessage = nil
        epgChannelCount = 0
        epgErrorMessage = nil

        do {
            var items: [ChannelDisplayItem] = []
            var groupOrder: [String] = []

            switch server.type {
            case .m3uPlaylist:
                guard let m3uURL = URL(string: server.baseURL) else { throw APIError.invalidURL }
                let (m3uData, m3uResp) = try await URLSession.shared.data(from: m3uURL)
                guard let http = m3uResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw APIError.serverError((m3uResp as? HTTPURLResponse)?.statusCode ?? -1)
                }
                guard let m3uContent = String(data: m3uData, encoding: .utf8) else {
                    throw APIError.invalidResponse
                }
                let m3uChannels = M3UParser.parse(content: m3uContent)
                var m3uGroups: [String] = []
                for ch in m3uChannels {
                    if !ch.groupTitle.isEmpty && !m3uGroups.contains(ch.groupTitle) {
                        m3uGroups.append(ch.groupTitle)
                    }
                }
                groupOrder = m3uGroups
                epgChannelCount = m3uChannels.filter { !$0.tvgID.isEmpty }.count
                items = m3uChannels.enumerated().compactMap { (index, ch) in
                    guard let streamURL = URL(string: ch.url) else { return nil }
                    return ChannelDisplayItem(
                        id: ch.id.uuidString, name: ch.name,
                        number: ch.channelNumber.map { String($0) } ?? String(index + 1),
                        logoURL: URL(string: ch.tvgLogo),
                        group: ch.groupTitle.isEmpty ? "Uncategorized" : ch.groupTitle,
                        categoryOrder: m3uGroups.firstIndex(of: ch.groupTitle) ?? Int.max,
                        streamURL: streamURL, streamURLs: [streamURL]
                    )
                }
                items = sortChannelsForDisplay(items, groupOrder: groupOrder)

            case .xtreamCodes:
                let xAPI = XtreamCodesAPI(baseURL: server.normalizedBaseURL,
                                          username: server.username, password: server.password)
                async let streamsFetch = xAPI.getLiveStreams()
                async let categoriesFetch = xAPI.getLiveCategories()
                let streams = try await streamsFetch
                let categories = (try? await categoriesFetch) ?? []
                let catOrder = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($1.id, $0) })
                let usedCategoryIDs = Set(streams.compactMap { $0.categoryID })
                let orderedCategoryNames: [String] = categories
                    .filter { usedCategoryIDs.contains($0.id) }
                    .map { $0.name }
                var xGroups = orderedCategoryNames
                if streams.contains(where: { ($0.categoryID ?? "").isEmpty }) {
                    xGroups.append("Uncategorized")
                }
                groupOrder = xGroups
                epgChannelCount = streams.filter { !($0.epgChannelID ?? "").isEmpty }.count
                items = streams.enumerated().compactMap { (index, stream) in
                    let streamURLs = xAPI.streamURLs(for: stream)
                    guard let primary = streamURLs.first else { return nil }
                    let catName = categories.first(where: { $0.id == stream.categoryID })?.name ?? "Uncategorized"
                    let catIdx = catOrder[stream.categoryID ?? ""] ?? Int.max
                    return ChannelDisplayItem(
                        id: String(stream.streamID),
                        name: stream.name,
                        number: String(stream.num ?? (index + 1)),
                        logoURL: stream.streamIcon.flatMap { URL(string: $0) },
                        group: catName,
                        categoryOrder: catIdx,
                        streamURL: primary,
                        streamURLs: streamURLs
                    )
                }
                items = sortChannelsForDisplay(items, groupOrder: groupOrder)

            case .dispatcharrAPI:
                let dAPI = DispatcharrAPI(
                    baseURL: server.normalizedBaseURL,
                    auth: .apiKey(server.apiKey)
                )

                // Fire all three requests concurrently
                async let groupsFetch = dAPI.getChannelGroups()
                async let channelsFetch = dAPI.getChannels()
                async let programsFetch = dAPI.getCurrentPrograms()

                let dGroupsResponse = (try? await groupsFetch) ?? []
                let dChannels = try await channelsFetch

                let groupNameByID: [Int: String] = Dictionary(
                    uniqueKeysWithValues: dGroupsResponse.map { ($0.id, $0.name) }
                )
                let usedGroupIDs = Set(dChannels.compactMap { $0.channelGroupID })
                var dGroupOrder: [String] = dGroupsResponse
                    .filter { usedGroupIDs.contains($0.id) }
                    .map { $0.name }

                if dChannels.contains(where: { $0.channelGroupID == nil }) {
                    dGroupOrder.append("Uncategorized")
                }

                let base = server.normalizedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                func logoURL(for logoID: Int?) -> URL? {
                    guard let logoID else { return nil }
                    return URL(string: "\(base)/api/channels/logos/\(logoID)/cache/")
                }

                func liveStreamURLs(for uuid: String?) -> [URL] {
                    guard let uuid, !uuid.isEmpty else { return [] }
                    let candidates: [String] = [
                        "\(base)/proxy/hls/stream/\(uuid)",
                        "\(base)/proxy/hls/stream/\(uuid).m3u8",
                        "\(base)/proxy/hls/channel/\(uuid)",
                        "\(base)/proxy/hls/channel/\(uuid).m3u8",
                        "\(base)/proxy/ts/stream/\(uuid)",
                        "\(base)/proxy/ts/channel/\(uuid)"
                    ]
                    var seen = Set<String>()
                    return candidates.compactMap { URL(string: $0) }.filter { url in
                        seen.insert(url.absoluteString).inserted
                    }
                }

                items = dChannels.enumerated().map { (index, ch) in
                    let grpName = ch.channelGroupID.flatMap { groupNameByID[$0] } ?? "Uncategorized"
                    let urls = liveStreamURLs(for: ch.uuid)
                    let numStr = ch.channelNumber.map { n in
                        n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
                    } ?? String(index + 1)
                    var item = ChannelDisplayItem(
                        id: String(ch.id),
                        name: ch.name,
                        number: numStr,
                        logoURL: logoURL(for: ch.logoID),
                        group: grpName,
                        categoryOrder: dGroupOrder.firstIndex(of: grpName) ?? Int.max,
                        streamURL: urls.first,
                        streamURLs: urls
                    )
                    item.tvgID = ch.tvgID
                    return item
                }
                groupOrder = dGroupOrder
                items = sortChannelsForDisplay(items, groupOrder: groupOrder)

                // Apply EPG data from the already-in-flight programs request
                do {
                    let programs = try await programsFetch
                    epgErrorMessage = nil
                    if !programs.isEmpty {
                        var programByTvgID: [String: (title: String, start: Date?, end: Date?)] = [:]
                        for prog in programs {
                            guard let tvgID = prog.tvgID, !tvgID.isEmpty, !prog.title.isEmpty else { continue }
                            programByTvgID[tvgID] = (prog.title, prog.startTime?.toDate(), prog.endTime?.toDate())
                        }
                        items = items.map { item in
                            guard let tvgID = item.tvgID, !tvgID.isEmpty,
                                  let info = programByTvgID[tvgID] else { return item }
                            var updated = item
                            updated.currentProgram = info.title
                            updated.currentProgramStart = info.start
                            updated.currentProgramEnd = info.end
                            return updated
                        }
                    }
                    epgChannelCount = items.filter { $0.currentProgram != nil }.count
                } catch {
                    epgErrorMessage = error.localizedDescription
                }
            }

            // Derive group order from actual sorted channel positions
            var seenGroups = Set<String>()
            var sortedGroupOrder: [String] = []
            for item in items {
                if seenGroups.insert(item.group).inserted {
                    sortedGroupOrder.append(item.group)
                }
            }

            channels = items
            orderedGroups = sortedGroupOrder
            filterChannels()
            favoritesStore.register(items: items)

        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func filterChannels() {
        var result = channels
        if selectedGroup != "All" {
            result = result.filter { $0.group == selectedGroup }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        filteredChannels = sortChannelsForDisplay(result, groupOrder: orderedGroups)
    }

    // MARK: - Upcoming EPG fetch factory
    private func makeFetchUpcoming(for item: ChannelDisplayItem) -> (() async -> [EPGEntry])? {
        guard let server = selectedServer else { return nil }
        switch server.type {
        case .dispatcharrAPI:
            guard let tvgID = item.tvgID, !tvgID.isEmpty else { return nil }
            let dAPI = DispatcharrAPI(baseURL: server.normalizedBaseURL, auth: .apiKey(server.apiKey))
            return {
                let programs = (try? await dAPI.getUpcomingPrograms(tvgIDs: [tvgID], limit: 8)) ?? []
                return programs.map { EPGEntry(title: $0.title, startTime: $0.startTime?.toDate(), endTime: $0.endTime?.toDate()) }
            }
        case .xtreamCodes:
            let xAPI = XtreamCodesAPI(baseURL: server.normalizedBaseURL,
                                      username: server.username, password: server.password)
            let streamID = item.id
            return {
                guard let epg = try? await xAPI.getEPG(streamID: streamID, limit: 9) else { return [] }
                let now = Date()
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                func parseDate(_ s: String) -> Date? {
                    if let ts = Double(s) {
                        return ts > 2_000_000_000_000 ? Date(timeIntervalSince1970: ts / 1000) : Date(timeIntervalSince1970: ts)
                    }
                    return formatter.date(from: s)
                }
                return epg.epgListings.compactMap { listing -> EPGEntry? in
                    let start = parseDate(listing.start)
                    let end = parseDate(listing.end)
                    if let e = end, now >= e { return nil }             // past
                    if let s = start, let e = end, now >= s && now < e { return nil } // on now
                    return EPGEntry(title: listing.title, startTime: start, endTime: end)
                }.prefix(3).map { $0 }
            }
        case .m3uPlaylist:
            return nil
        }
    }
}

// MARK: - Channel Display Item
struct ChannelDisplayItem: Identifiable, Equatable {
    let id: String
    let name: String
    let number: String
    let logoURL: URL?
    let group: String
    let categoryOrder: Int
    let streamURL: URL?
    let streamURLs: [URL]
    var tvgID: String? = nil
    var currentProgram: String? = nil
    var currentProgramStart: Date? = nil
    var currentProgramEnd: Date? = nil
}

// MARK: - EPG Entry (for upcoming schedule)
struct EPGEntry: Identifiable, Equatable {
    var id: String { "\(title)-\(startTime?.timeIntervalSinceReferenceDate ?? 0)" }
    let title: String
    let startTime: Date?
    let endTime: Date?
}

// MARK: - Channel Row
struct ChannelRow: View {
    let item: ChannelDisplayItem
    let onTap: () -> Void
    var fetchUpcoming: (() async -> [EPGEntry])? = nil
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isExpanded = false
    @State private var upcomingPrograms: [EPGEntry] = []
    @State private var isLoadingUpcoming = false

    // Show 3 on iPhone (compact), all fetched results on iPad/Mac/TV (regular)
    private var maxUpcomingCount: Int { sizeClass == .regular ? 8 : 3 }

    var body: some View {
        VStack(spacing: 0) {
            // Main tappable row
            Button(action: onTap) {
                HStack(spacing: 14) {
                    // Channel number
                    Text(item.number)
                        .font(.monoSmall)
                        .lineLimit(1)
                        .foregroundColor(.textTertiary)
                        .frame(width: 32, alignment: .trailing)

                    // Logo
                    AsyncImage(url: item.logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 44, height: 30)
                        default:
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentPrimary.opacity(0.12))
                                    .frame(width: 44, height: 30)
                                Image(systemName: "tv.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.accentPrimary.opacity(0.5))
                            }
                        }
                    }

                    // Name + EPG / Group
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.bodyMedium)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        if let program = item.currentProgram, !program.isEmpty {
                            MarqueeText(text: program, font: .labelSmall, color: .accentPrimary.opacity(0.85))
                                .frame(height: 16)
                        } else {
                            Text(item.group)
                                .font(.labelSmall)
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Expand toggle (only shown when EPG data is available)
                    if item.currentProgram != nil {
                        Button {
                            withAnimation(.spring(response: 0.25)) { isExpanded.toggle() }
                            if isExpanded && upcomingPrograms.isEmpty, fetchUpcoming != nil {
                                Task {
                                    isLoadingUpcoming = true
                                    upcomingPrograms = await fetchUpcoming?() ?? []
                                    isLoadingUpcoming = false
                                }
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.textTertiary)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }

                    // Play indicator
                    if !item.streamURLs.isEmpty {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.accentPrimary.opacity(0.6))
                    }

                    // Favorite
                    Button {
                        favoritesStore.toggle(item)
                    } label: {
                        Image(systemName: favoritesStore.isFavorite(item.id) ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundColor(favoritesStore.isFavorite(item.id) ? .statusWarning : .textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)

            // Expanded schedule section
            if isExpanded, let program = item.currentProgram {
                Divider()
                    .background(Color.borderSubtle)
                    .padding(.horizontal, 14)

                // On Now
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.accentPrimary)
                        .frame(width: 2, height: 44)
                        .cornerRadius(1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("On Now")
                            .font(.labelSmall)
                            .foregroundColor(.accentPrimary)
                        Text(program)
                            .font(.bodySmall)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        if let end = item.currentProgramEnd {
                            Text("Until \(end, style: .time)")
                                .font(.labelSmall)
                                .foregroundColor(.textSecondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                // Upcoming programs
                if isLoadingUpcoming {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading schedule…")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                } else {
                    ForEach(upcomingPrograms.prefix(maxUpcomingCount)) { entry in
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(Color.borderSubtle)
                                .frame(width: 2, height: 34)
                                .cornerRadius(1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.bodySmall)
                                    .foregroundColor(.textPrimary)
                                    .lineLimit(1)
                                if let start = entry.startTime {
                                    Text(start, style: .time)
                                        .font(.labelSmall)
                                        .foregroundColor(.textTertiary)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                    }
                    if !upcomingPrograms.isEmpty {
                        EmptyView().padding(.bottom, 4)
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentPrimary.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

// MARK: - Favorites View
struct FavoritesView: View {
    @EnvironmentObject private var nowPlaying: NowPlayingManager
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @Query private var servers: [ServerConnection]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                if favoritesStore.favoriteItems.isEmpty {
                    EmptyStateView(
                        icon: "star",
                        title: "No Favorites",
                        message: "Tap the star on any channel in Live TV to add it here."
                    )
                } else {
                    List {
                        ForEach(favoritesStore.favoriteItems) { item in
                            ChannelRow(item: item) {
                                if !item.streamURLs.isEmpty {
                                    nowPlaying.startPlaying(item, headers: playerHeaders(for: servers.first))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .background(Color.appBackground)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
        }
    }

    private func playerHeaders(for server: ServerConnection?) -> [String: String] {
        guard let server else { return ["Accept": "*/*"] }
        switch server.type {
        case .dispatcharrAPI:
            let key = server.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["Authorization": "ApiKey \(key)", "X-API-Key": key, "Accept": "*/*"]
        default:
            return ["Accept": "*/*"]
        }
    }
}

// MARK: - Marquee Text
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.onAppear {
                            textWidth = textGeo.size.width
                            containerWidth = geo.size.width
                        }
                    }
                )
                .offset(x: offset)
        }
        .clipped()
        .onChange(of: text) { _, _ in offset = 0; textWidth = 0 }
        .task(id: textWidth) { await runMarquee() }
    }

    @MainActor
    private func runMarquee() async {
        offset = 0
        let dist = textWidth - containerWidth
        guard dist > 8 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: Double(dist) / 40)) { offset = -dist }
            try? await Task.sleep(for: .seconds(Double(dist) / 40 + 0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) { offset = 0 }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}
