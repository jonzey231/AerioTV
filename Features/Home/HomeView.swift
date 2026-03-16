import SwiftUI
import SwiftData
import Foundation

// MARK: - Favorites Store
final class FavoritesStore: ObservableObject {
    @Published private(set) var favoriteItems: [ChannelDisplayItem] = []
    private var favoriteIDs: Set<String>

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "favoriteChannelIDs") ?? []
        self.favoriteIDs = Set(saved)
    }

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    func toggle(_ item: ChannelDisplayItem) {
        if favoriteIDs.contains(item.id) {
            favoriteIDs.remove(item.id)
            favoriteItems.removeAll { $0.id == item.id }
        } else {
            favoriteIDs.insert(item.id)
            favoriteItems.append(item)
            favoriteItems.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "favoriteChannelIDs")
    }

    /// Called when channels load — hydrates in-memory favorites from fresh item data.
    func register(items: [ChannelDisplayItem]) {
        favoriteItems = items.filter { favoriteIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Now Playing Manager
final class NowPlayingManager: ObservableObject {
    @Published var playingItem: ChannelDisplayItem? = nil
    @Published var playingHeaders: [String: String] = [:]
    @Published var isMinimized: Bool = false

    var isActive: Bool { playingItem != nil }

    func startPlaying(_ item: ChannelDisplayItem, headers: [String: String]) {
        playingItem = item
        playingHeaders = headers
        isMinimized = false
    }

    func minimize() { isMinimized = true }
    func expand() { isMinimized = false }
    func stop() { playingItem = nil; isMinimized = false }
}

// MARK: - Tab Definition
enum AppTab: String, CaseIterable {
    case liveTV    = "livetv"
    case favorites = "favorites"
    case movies    = "movies"
    case tv        = "tv"
    case settings  = "settings"

    var title: String {
        switch self {
        case .liveTV:    return "Live TV"
        case .favorites: return "Favorites"
        case .movies:    return "Movies"
        case .tv:        return "Series"
        case .settings:  return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .liveTV:    return "antenna.radiowaves.left.and.right"
        case .favorites: return "star.fill"
        case .movies:    return "film.stack"
        case .tv:        return "tv"
        case .settings:  return "gearshape.fill"
        }
    }
}

// MARK: - Main Tab View
struct MainTabView: View {
    @AppStorage("defaultTab") private var defaultTabRaw = AppTab.liveTV.rawValue
    @ObservedObject private var theme = ThemeManager.shared

    @State private var selectedTab: AppTab = .liveTV
    @State private var showSearch = false
    @State private var isPlaying = false  // for Movies / TV Shows player state
    @StateObject private var nowPlaying = NowPlayingManager()
    @StateObject private var favoritesStore = FavoritesStore()
    /// Shared drag offset — MiniPlayerBar writes it, PlayerView reads it to slide in from below.
    @State private var miniPlayerDragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Tab content with mini player safe area inset
            tabContentView

            // Full-screen live TV player — kept in hierarchy for uninterrupted playback
            if nowPlaying.isActive, let item = nowPlaying.playingItem {
                let screenH = UIScreen.main.bounds.height
                PlayerView(
                    urls: item.streamURLs,
                    title: item.name,
                    headers: nowPlaying.playingHeaders,
                    onMinimize: { nowPlaying.minimize() },
                    onClose: { nowPlaying.stop() }
                )
                .ignoresSafeArea()
                // When minimized: push off-screen below; drag up pulls it into view.
                // When expanded: sit at y=0 (full screen).
                .offset(y: nowPlaying.isMinimized ? max(0, screenH + miniPlayerDragOffset) : 0)
                .opacity(nowPlaying.isMinimized ? min(1, -miniPlayerDragOffset / 300) : 1)
                .allowsHitTesting(!nowPlaying.isMinimized)
            }
        }
        .environmentObject(nowPlaying)
        .environmentObject(favoritesStore)
    }

    // MARK: - Tab Content
    private var tabContentView: some View {
        TabView(selection: $selectedTab) {
            ChannelListView()
                .tabItem { Label(AppTab.liveTV.title, systemImage: AppTab.liveTV.icon) }
                .tag(AppTab.liveTV)

            FavoritesView()
                .tabItem { Label(AppTab.favorites.title, systemImage: AppTab.favorites.icon) }
                .tag(AppTab.favorites)

            MoviesView(isPlaying: $isPlaying)
                .tabItem { Label(AppTab.movies.title, systemImage: AppTab.movies.icon) }
                .tag(AppTab.movies)

            TVShowsView(isPlaying: $isPlaying)
                .tabItem { Label(AppTab.tv.title, systemImage: AppTab.tv.icon) }
                .tag(AppTab.tv)

            SettingsView()
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.icon) }
                .tag(AppTab.settings)
        }
        .tint(theme.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if nowPlaying.isMinimized, let item = nowPlaying.playingItem {
                MiniPlayerBar(item: item, nowPlaying: nowPlaying, dragOffset: $miniPlayerDragOffset)
            }
        }
        .onAppear {
            selectedTab = AppTab(rawValue: defaultTabRaw) ?? .liveTV
            configureTabBarAppearance()
        }
        .onChange(of: defaultTabRaw) { _, _ in }
        // Global search — hidden during active playback
        .toolbar {
            if !isPlaying && !nowPlaying.isActive && selectedTab != .settings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.accent)
                    }
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
        }
        .liquidGlassTabBar()
    }

    private func configureTabBarAppearance() {
#if os(iOS)
        guard theme.liquidGlassStyle == .disabled else { return }
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(theme.background)

        let normal = UITabBarItemAppearance()
        normal.normal.iconColor = UIColor(Color.textSecondary)
        normal.normal.titleTextAttributes = [.foregroundColor: UIColor(Color.textSecondary)]
        normal.selected.iconColor = UIColor(theme.accent)
        normal.selected.titleTextAttributes = [.foregroundColor: UIColor(theme.accent)]
        appearance.stackedLayoutAppearance = normal

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
#endif
    }
}

// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    let item: ChannelDisplayItem
    @ObservedObject var nowPlaying: NowPlayingManager
    @Binding var dragOffset: CGFloat

    private func expand() {
        let screenH = UIScreen.main.bounds.height
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            dragOffset = -screenH
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            nowPlaying.expand()
            dragOffset = 0
        }
    }

    private func progressFraction(start: Date, end: Date, now: Date) -> CGFloat {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(max(0, min(1, now.timeIntervalSince(start) / total)))
    }

    private func programSubtitle(program: String, start: Date?, end: Date?, now: Date) -> String {
        guard let end else { return program }
        let remaining = max(0, end.timeIntervalSince(now))
        let mins = Int(remaining / 60)
        if mins <= 0 { return "\(program) · Ending soon" }
        if mins < 60 { return "\(program) · \(mins)m left" }
        let h = mins / 60; let m = mins % 60
        let timeStr = m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
        return "\(program) · \(timeStr)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Liquid glass drag handle
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 6)

            HStack(spacing: 12) {
                // Channel logo or placeholder
                AsyncImage(url: item.logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    default:
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentPrimary.opacity(0.15))
                                .frame(width: 40, height: 28)
                            Image(systemName: "tv.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.accentPrimary)
                        }
                    }
                }

                // Channel name + current program + progress
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.headlineSmall)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)

                        if let program = item.currentProgram, !program.isEmpty {
                            Text(programSubtitle(program: program,
                                                 start: item.currentProgramStart,
                                                 end: item.currentProgramEnd,
                                                 now: context.date))
                                .font(.labelSmall)
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)

                            if let start = item.currentProgramStart,
                               let end = item.currentProgramEnd {
                                let progress = progressFraction(start: start, end: end, now: context.date)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.12))
                                            .frame(height: 3)
                                        Capsule()
                                            .fill(Color.accentPrimary.opacity(0.7))
                                            .frame(width: geo.size.width * progress, height: 3)
                                    }
                                }
                                .frame(height: 3)
                            }
                        } else {
                            Text("Live TV")
                                .font(.labelSmall)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }

                Spacer()

                // Stop / close — has its own tap area so it doesn't trigger the bar tap
                Button {
                    nowPlaying.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentPrimary.opacity(0.25))
                .frame(height: 1)
        }
        // Tap anywhere on the bar (except the X) to expand
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        // Drag up — synced with the PlayerView so the video follows the finger
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height < 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height < -40 {
                        expand()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}
