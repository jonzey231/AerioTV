import SwiftUI
import SwiftData

// MARK: - DVR tab

/// Media-center DVR tab (2026-09-05): hero for the recording in progress
/// (or the newest resumable recording), Recording Now / Scheduled /
/// Recent shelves, then every recording as 16:9 cards behind content-type
/// pills (Movies, TV Shows, Sports) and a sort circle. Same scaffold and
/// focus rules as the Movies and TV Shows tabs.
struct DVRView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var allRecordings: [Recording]
    @Query private var servers: [ServerConnection]
    @StateObject private var coordinator = RecordingCoordinator.shared
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var art = DVRArtResolver.shared
    @ObservedObject private var playerSession = PlayerSession.shared
    @Binding var isPlaying: Bool
    var isSelected: Bool = true

    enum SortOrder: String, CaseIterable {
        case newest, oldest, title, channel
        var label: String {
            switch self {
            case .newest:  return "Newest First"
            case .oldest:  return "Oldest First"
            case .title:   return "Title A to Z"
            case .channel: return "Channel"
            }
        }
    }

    @AppStorage("dvrSortOrder") private var sortOrderRaw = SortOrder.newest.rawValue
    private var sortOrder: SortOrder { SortOrder(rawValue: sortOrderRaw) ?? .newest }
    @State private var selectedKind: DVRContentKind?
    @State private var showSortMenu = false

    @State private var playingRecording: PlayingRecording?
    @State private var recordingToDelete: Recording?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFromServerAlert = false
    @State private var showDownloadConfirmation = false

    #if os(tvOS)
    /// "primary" | "secondary" | "stop" while a hero button has focus.
    @FocusState private var heroFocus: String?
    @FocusState private var catcherFocused: Bool
    @State private var tvTabBarHidden = false
    @State private var wantsTabBarHidden = false
    @State private var scrollIsIdle = true
    /// Grid card with focus (recording id). Drives the alphabet rail.
    @FocusState private var gridFocus: UUID?
    @State private var lastGridFocus: UUID?
    @FocusState private var railCatcherFocused: Bool
    @State private var railFocusRequest: String?
    @State private var railFocused = false
    @State private var railHideTask: Task<Void, Never>?
    private let railWidth: CGFloat = 72
    private let gridColumns = 5
    private let gridSpacing: CGFloat = 24
    #else
    private var gridColumns: Int { isPhone ? 3 : 2 }
    private var gridSpacing: CGFloat { isPhone ? 10 : 12 }
    private let railWidth: CGFloat = 22
    #endif
    @State private var lastScrollY: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var railVisible = false
    @State private var railTop: CGFloat?
    @State private var gridTopVisible: CGFloat = 0
    @State private var rowPitch: CGFloat = 0
    /// The rail appears only for libraries worth jumping around in.
    private let railMinimumCount = 15

    // MARK: Data

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    /// Recordings for the active playlist. A capture running right now is
    /// exempt so the user can always stop it (see MyRecordingsView).
    private var visibleRecordings: [Recording] {
        func isCapturing(_ r: Recording) -> Bool { coordinator.activeSessions[r.id] != nil }
        guard let sid = activeServer?.id.uuidString else { return allRecordings.filter(isCapturing) }
        return allRecordings.filter { $0.serverID == sid || isCapturing($0) }
    }

    private static let terminalStatuses: [RecordingStatus] =
        [.completed, .stopped, .interrupted, .failed, .cancelled]

    private func isAiringNow(_ r: Recording) -> Bool {
        let now = Date()
        return r.effectiveStart <= now && now < r.effectiveEnd
    }

    private var recordingNow: [Recording] {
        visibleRecordings.filter {
            !Self.terminalStatuses.contains($0.status) && ($0.status == .recording || isAiringNow($0))
        }
    }

    private var scheduled: [Recording] {
        visibleRecordings
            .filter { !Self.terminalStatuses.contains($0.status) && $0.status != .recording && !isAiringNow($0) }
            .sorted { $0.effectiveStart < $1.effectiveStart }
    }

    /// Finished recordings that can be watched (failed / cancelled rows
    /// stay in the Settings list, not in the library).
    private var completed: [Recording] {
        visibleRecordings.filter { $0.status == .completed || $0.status == .stopped || $0.status == .interrupted }
    }

    /// The library: everything recorded or recording, newest first.
    private var library: [Recording] { recordingNow + completed }

    private var kindsPresent: [DVRContentKind] {
        let kinds = Set(library.map(DVRClassifier.kind(for:)))
        return DVRContentKind.allCases.filter { kinds.contains($0) }
    }

    private var filteredLibrary: [Recording] {
        var items = library
        if let k = selectedKind { items = items.filter { DVRClassifier.kind(for: $0) == k } }
        switch sortOrder {
        case .newest:  items.sort { $0.scheduledStart > $1.scheduledStart }
        case .oldest:  items.sort { $0.scheduledStart < $1.scheduledStart }
        case .title:   items.sort { $0.programTitle.localizedCaseInsensitiveCompare($1.programTitle) == .orderedAscending }
        case .channel: items.sort { ($0.channelName, $0.scheduledStart) < ($1.channelName, $1.scheduledStart) }
        }
        return items
    }

    private var recent: [Recording] {
        Array(completed.sorted { $0.scheduledStart > $1.scheduledStart }.prefix(20))
    }

    /// Resume fractions by recording id, refreshed on appear, when the set of
    /// recordings changes, and after playback. Reading WatchProgress inside
    /// the body ran a SwiftData fetch per card per render (dozens per
    /// switch to this tab; the switch visibly lagged, Logan 2026-09-05).
    @State private var progressByID: [UUID: Double] = [:]

    private func progressFraction(_ rec: Recording) -> Double {
        progressByID[rec.id] ?? 0
    }

    private func refreshProgress() {
        var out: [UUID: Double] = [:]
        for rec in visibleRecordings {
            guard let id = rec.watchProgressID ?? (rec.destination == .local ? "local-\(rec.id.uuidString)" : nil),
                  let ms = WatchProgressManager.getResumePosition(vodID: id, serverID: rec.serverID), ms > 0 else { continue }
            // A capture still running has only recorded up to now.
            let end = rec.status == .recording ? min(Date(), rec.effectiveEnd) : rec.effectiveEnd
            let total = end.timeIntervalSince(rec.effectiveStart) * 1000
            guard total > 0 else { continue }
            out[rec.id] = min(1, Double(ms) / total)
        }
        if out != progressByID { progressByID = out }
    }

    /// Recording in progress first, else the newest recording with saved
    /// progress, else the newest recording.
    /// Phone deck: recordings in progress first, then finished ones with a
    /// saved position short of the end, newest first.
    private var continueWatching: [Recording] {
        let live = recordingNow.sorted { $0.scheduledStart > $1.scheduledStart }
        let partial = completed
            .filter { progressFraction($0) > 0 && progressFraction($0) < 0.97 }
            .sorted { $0.scheduledStart > $1.scheduledStart }
        return live + partial
    }

    private var heroRecording: Recording? {
        if let live = recordingNow.first(where: { actions.canPlay($0) }) ?? recordingNow.first { return live }
        let done = completed.sorted { $0.scheduledStart > $1.scheduledStart }
        if let partial = done.first(where: { progressFraction($0) > 0 && progressFraction($0) < 0.97 }) { return partial }
        return done.first
    }

    private var headers: [String: String] { activeServer?.authHeaders ?? [:] }

    private var actions: RecordingActions {
        RecordingActions(servers: servers, modelContext: modelContext, coordinator: coordinator,
                         present: { playingRecording = $0 })
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                if visibleRecordings.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            #if os(tvOS)
            .toolbar(tvTabBarHidden ? .hidden : .visible, for: .tabBar)
            #else
            // Phone pass (Logan 2026-09-05): no navigation bar; the hero
            // starts under the status bar, sort sits in the library header.
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .confirmationDialog("Sort Recordings", isPresented: $showSortMenu, titleVisibility: .visible) {
            ForEach(SortOrder.allCases, id: \.self) { order in
                Button(order.label) { sortOrderRaw = order.rawValue }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { actions.deleteLocal(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(device: true))
        }
        .alert("Delete from Server?", isPresented: $showDeleteFromServerAlert) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { actions.deleteFromServer(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(device: false))
        }
        .alert("Save to Device?", isPresented: $showDownloadConfirmation) {
            Button("Save") {
                if let rec = recordingToDelete { actions.download(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download this recording from the Dispatcharr server to your device's local storage.")
        }
        .fullScreenCover(item: $playingRecording) { item in
            PlayerView(
                urls: [item.url],
                title: item.title,
                headers: item.headers,
                isLive: false,
                isDVR: item.isDVR,
                vodID: item.vodID,
                vodServerID: item.serverID,
                vodType: "recording",
                resumePositionMs: item.resumePositionMs
            )
            .onDisappear { refreshProgress() }
        }
        .onChange(of: playerSession.mode) { _, mode in
            // Progress bars refresh after the container player closes.
            if mode == .idle { refreshProgress() }
        }
        .task {
            await reconcile()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                await reconcile()
            }
        }
        .onAppear {
            refreshProgress()
            art.resolve(visibleRecordings, modelContext: modelContext)
        }
        .onChange(of: visibleRecordings.count) { _, _ in
            refreshProgress()
            art.resolve(visibleRecordings, modelContext: modelContext)
        }
    }

    private func deleteMessage(device: Bool) -> String {
        let where_ = device ? "from your device" : "from the Dispatcharr server"
        if let rec = recordingToDelete, !rec.programTitle.isEmpty {
            return "\u{201C}\(rec.programTitle)\u{201D} will be permanently deleted \(where_)."
        }
        return "This recording will be permanently deleted \(where_)."
    }

    private func reconcile() async {
        guard let active = activeServer, active.type == .dispatcharrAPI else { return }
        let api = DispatcharrAPI(baseURL: active.effectiveBaseURL,
                                 auth: .apiKey(active.effectiveApiKey),
                                 userAgent: active.effectiveUserAgent,
                                 authMode: active.dispatcharrHeaderMode)
        await coordinator.reconcileDispatcharrRecordings(api: api, serverID: active.id.uuidString,
                                                         modelContext: modelContext)
        art.resolve(visibleRecordings, modelContext: modelContext)
    }

    // MARK: Content

    private var content: some View {
        GeometryReader { outer in
            ZStack(alignment: .topLeading) {
                scrollBody(outer: outer)
                #if os(tvOS)
                // Rail: a sibling of the ScrollView (an overlay was unreachable
                // by the focus engine), shown only while focus is in the grid
                // or on the rail itself, sliding in from the left edge like
                // Movies and TV Shows (Logan 2026-09-05).
                if filteredLibrary.count > railMinimumCount, let railTop, railVisible {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(width: railWidth,
                                   height: max(0, outer.size.height + outer.safeAreaInsets.top - railTop))
                            .focusable(true)
                            .focused($railCatcherFocused)
                            .onChange(of: railCatcherFocused) { _, focused in
                                if focused { railFocusRequest = "#" }
                            }
                            .padding(.top, railTop)
                        AlphabetRail(
                            available: railLetters,
                            focusRequest: Binding(get: { railFocusRequest }, set: { railFocusRequest = $0 }),
                            onFocusChange: { focused in
                                railFocused = focused
                                updateRailVisibility()
                            },
                            onExitRight: {
                                let items = filteredLibrary
                                if let last = lastGridFocus, items.contains(where: { $0.id == last }) {
                                    gridFocus = last
                                } else if let first = items.first?.id {
                                    gridFocus = first
                                } else {
                                    heroFocus = "primary"
                                }
                            },
                            onExitUp: { heroFocus = "primary" }
                        ) { letter in
                            jumpToLetter(letter)
                        }
                        .frame(width: railWidth)
                        .padding(.top, railTop)
                    }
                    // Centred between the display edge and the first card
                    // column; follows the safe area on any display.
                    .padding(.leading, max(0, (outer.safeAreaInsets.leading + sectionInset - railWidth) / 2))
                    .ignoresSafeArea(.container, edges: [.top, .leading])
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                #else
                // Phone: same rail as Movies, parked at the right edge and
                // centered on the visible grid (Logan 2026-09-05).
                if isPhone, filteredLibrary.count > railMinimumCount, let railTop, railVisible {
                    AlphabetRail(available: railLetters) { letter in
                        jumpToLetter(letter)
                    }
                    .frame(width: railWidth)
                    // Offset, never padding: see the Movies rail (layout loop).
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .offset(y: railTop)
                    .padding(.trailing, 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .ignoresSafeArea(.container, edges: .top)
                }
                #endif
            }
            .onPreferenceChange(GridTopKey.self) { gridTopY in
                guard let gridTopY else { return }
                gridTopVisible = gridTopY
                #if os(tvOS)
                let centered = max(8, (outer.size.height + outer.safeAreaInsets.top - AlphabetRail.totalHeight) / 2 + 80)
                let top = max(centered, gridTopY + 24)
                if railTop != top { railTop = top }
                #else
                let top = max(0, gridTopY) / 2
                if railTop != top { railTop = top }
                let want = gridTopY <= 110
                if want != railVisible {
                    withAnimation(.easeInOut(duration: 0.25)) { railVisible = want }
                }
                #endif
            }
            #if os(tvOS)
            .onChange(of: gridFocus) { _, id in
                if let id { lastGridFocus = id }
                updateRailVisibility()
            }
            #endif
        }
    }

    private struct GridTopKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            if let v = nextValue() { value = v }
        }
    }

    private var railLetters: Set<String> {
        Set(filteredLibrary.map { AlphabetRail.bucket(for: $0.programTitle) })
    }

    private func jumpToLetter(_ letter: String) {
        let items = filteredLibrary
        guard let index = items.firstIndex(where: { AlphabetRail.bucket(for: $0.programTitle) == letter }) else { return }
        let id = items[index].id
        if rowPitch > 0 {
            // Absolute offset: scrollTo(id) silently no-ops for lazy grid
            // rows not yet built.
            let row = index / gridColumns
            let gridTopContent = gridTopVisible + lastScrollY
            #if os(tvOS)
            let gridLead: CGFloat = 20   // the grid's vertical padding
            #else
            let gridLead: CGFloat = 0
            #endif
            let y = gridTopContent + gridLead + CGFloat(row) * rowPitch - 24
            withAnimation(.easeInOut(duration: 0.25)) { scrollPosition.scrollTo(y: max(0, y)) }
        }
        #if os(tvOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { gridFocus = id }
        #endif
    }

    #if os(tvOS)
    private func updateRailVisibility() {
        let want = gridFocus != nil || railFocused
        railHideTask?.cancel()
        if want {
            if !railVisible { withAnimation(.easeOut(duration: 0.3)) { railVisible = true } }
        } else if railVisible {
            railHideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, gridFocus == nil, !railFocused else { return }
                withAnimation(.easeIn(duration: 0.2)) { railVisible = false }
            }
        }
    }
    #endif

    private func scrollBody(outer: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            // Plain stack: a LazyVStack unloaded the Recording Now shelf once
            // it scrolled off, so Up from Recent landed on a UIKit filler and
            // nudged the scroll before the shelf came back (trace 2026-09-05
            // 01:47:12). The grid below stays lazy.
            VStack(alignment: .leading, spacing: sectionSpacing) {
                #if os(iOS)
                if isPhone, !continueWatching.isEmpty {
                    // Phone (Logan 2026-09-05): a deck of every recording that
                    // is started but unfinished, a recording in progress first.
                    Text(continueWatching.allSatisfy(\.isInProgress) ? "Recording Now" : "Continue Watching")
                        .font(.headlineSmall)
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, sectionInset)
                    PhoneCardDeck(items: continueWatching, cardHeight: 220) { rec in
                        DVRHero(recording: rec, headers: headers,
                                progress: progressFraction(rec), canPlay: actions.canPlay(rec),
                                inDeck: true,
                                onPrimary: { heroPrimary(rec) },
                                onSecondary: { heroSecondary(rec) },
                                onStop: { actions.stop(rec) },
                                menu: { menuItems(for: rec) })
                    }
                } else if let hero = heroRecording {
                    DVRHero(recording: hero, headers: headers,
                            progress: progressFraction(hero), canPlay: actions.canPlay(hero),
                            onPrimary: { heroPrimary(hero) },
                            onSecondary: { heroSecondary(hero) },
                            onStop: { actions.stop(hero) },
                            menu: { menuItems(for: hero) })
                }
                #else
                if let hero = heroRecording {
                    #if os(tvOS)
                    // Down from the tab bar lands on whatever is geometrically
                    // below the DVR pill (trace 2026-09-05 01:31: the second
                    // Recent card). While no hero button has focus, a
                    // full-width catcher above the hero takes that hop and
                    // forwards it to the primary button, same as Movies.
                    if heroFocus == nil {
                        Color.clear
                            .frame(height: 8)
                            .frame(maxWidth: .infinity)
                            .focusable(true)
                            .focused($catcherFocused)
                            .onChange(of: catcherFocused) { _, focused in
                                guard focused else { return }
                                heroFocus = "primary"
                            }
                    } else {
                        Color.clear.frame(height: 8)
                    }
                    #endif
                    DVRHero(recording: hero, headers: headers,
                            progress: progressFraction(hero), canPlay: actions.canPlay(hero),
                            onPrimary: { heroPrimary(hero) },
                            onSecondary: { heroSecondary(hero) },
                            onStop: { actions.stop(hero) },
                            menu: { menuItems(for: hero) })
                        #if os(tvOS)
                        .focusedDVRHero($heroFocus)
                        .id("hero")
                        #endif
                }
                #endif
                if !recordingNow.isEmpty {
                    shelf(title: "Recording Now", items: recordingNow)
                }
                if !scheduled.isEmpty {
                    shelf(title: "Scheduled", items: scheduled)
                }
                if recent.count > 1 {
                    #if os(iOS)
                    if isPhone {
                        // Phone (Logan 2026-09-05): the same deck as Continue Watching.
                        Text("Recent Recordings")
                            .font(.headlineSmall)
                            .foregroundColor(.textPrimary)
                            .padding(.horizontal, sectionInset)
                        PhoneCardDeck(items: recent, cardHeight: 220) { rec in
                            DVRHero(recording: rec, headers: headers,
                                    progress: progressFraction(rec), canPlay: actions.canPlay(rec),
                                    inDeck: true,
                                    onPrimary: { heroPrimary(rec) },
                                    onSecondary: { heroSecondary(rec) },
                                    onStop: { actions.stop(rec) },
                                    menu: { menuItems(for: rec) })
                        }
                    } else {
                        shelf(title: "Recent Recordings", items: recent)
                    }
                    #else
                    shelf(title: "Recent Recordings", items: recent)
                    #endif
                }
                if coordinator.isApproachingQuotaLimit {
                    quotaWarning
                }
                if !library.isEmpty {
                    libraryHeader(proxy: proxy)
                        .id("dvr-library")
                    grid
                }
            }
            .padding(.bottom, 80)
            #if os(tvOS)
            // Clear the floating tab bar (the scroll ignores the top inset
            // so the hero art can run full bleed, like Movies).
            .padding(.top, 190)
            #endif
        }
        .coordinateSpace(name: "dvrScroll")
        #if os(iOS)
        .aerioNoTopScrollEdge()
        #endif
        .scrollPosition($scrollPosition)
        #if os(iOS)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            lastScrollY = y
        }
        #endif
        #if os(tvOS)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            lastScrollY = y
            // Same rule as Movies: hide the bar once the hero has scrolled
            // away and the scroll has settled; show it at once on the way up.
            let hide = y > heroHideThreshold
            wantsTabBarHidden = hide
            let wantHidden = hide || tvTabBarHidden
            if TVTabBarScrollState.shared.isHidden != wantHidden {
                TVTabBarScrollState.shared.isHidden = wantHidden
            }
            if !hide, tvTabBarHidden {
                tvTabBarHidden = false
            } else if hide, !tvTabBarHidden, scrollIsIdle {
                tvTabBarHidden = true
            }
        }
        .onScrollPhaseChange { _, phase in
            scrollIsIdle = phase == .idle
            if phase == .idle, wantsTabBarHidden, !tvTabBarHidden { tvTabBarHidden = true }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .aerioTabScrollToTop)) { notif in
            guard (notif.userInfo?["tab"] as? String) == AppTab.dvr.rawValue else { return }
            withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .top) }
            tvTabBarHidden = false
            wantsTabBarHidden = false
            if TVTabBarScrollState.shared.isHidden { TVTabBarScrollState.shared.isHidden = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { heroFocus = "primary" }
        }
        .onChange(of: heroFocus) { _, id in
            // A hero button gaining focus while the page is scrolled brings
            // the page back to the top so the (system-collapsed) bar expands
            // fully, focus staying on the button (Logan 2026-09-05: the bar
            // stayed half hidden with the hero focused). Same rule as Movies.
            guard id != nil, !TVFocusBridge.isTabBarOnScreen(preferredTitle: AppTab.dvr.title) else { return }
            withAnimation(.smooth(duration: 0.45)) { scrollPosition.scrollTo(edge: .top) }
            tvTabBarHidden = false
            wantsTabBarHidden = false
            if TVTabBarScrollState.shared.isHidden { TVTabBarScrollState.shared.isHidden = false }
        }
        #endif
        }   // ScrollViewReader
    }

    /// Same warning My Recordings shows on iOS: local storage near its cap.
    private var quotaWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            Text("Storage is approaching the limit. New recordings may not finish.")
                .font(.labelMedium)
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.yellow.opacity(0.15)))
        .padding(.horizontal, sectionInset)
    }

    private var heroHideThreshold: CGFloat { heroRecording != nil ? 620 : 260 }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        return 28
        #else
        return 20
        #endif
    }

    private func heroPrimary(_ rec: Recording) {
        if rec.isInProgress {
            // Watch from Start while the recording continues.
            if rec.destination == .dispatcharrServer { actions.playServer(rec, fromStart: true) }
        } else {
            actions.play(rec)
        }
    }

    private func heroSecondary(_ rec: Recording) {
        if rec.isInProgress {
            if rec.destination == .dispatcharrServer { actions.playServer(rec, liveEdge: true) }
        } else if rec.destination == .local, let path = rec.localFilePath {
            // Play from Beginning: local files ignore the saved position.
            if let id = rec.watchProgressID {
                WatchProgressManager.delete(vodID: id, serverID: rec.serverID)
            }
            actions.playLocal(rec, path: path)
        } else {
            actions.playServer(rec, fromStart: true)
        }
    }

    // MARK: Shelves

    private func shelf(title: String, items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headlineSmall)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, sectionInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gridSpacing) {
                    ForEach(items, id: \.id) { rec in
                        card(rec)
                            .frame(width: shelfCardWidth)
                    }
                }
                .padding(.horizontal, sectionInset)
                #if os(tvOS)
                .padding(.vertical, 20)
                #endif
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var sectionInset: CGFloat {
        #if os(tvOS)
        return 60
        #else
        return 16
        #endif
    }

    private var shelfCardWidth: CGFloat {
        #if os(tvOS)
        return 340
        #else
        return isPhone ? 150 : 220
        #endif
    }

    private var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    // MARK: Library header + grid

    private func libraryHeader(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                // Plain text, tappable on the phone: scrolls the library to
                // the top of the page (Logan 2026-09-05), same as Movies.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("All Recordings")
                        .font(.headlineSmall)
                        .foregroundColor(.textPrimary)
                    Text("\(filteredLibrary.count)")
                        .font(.labelMedium)
                        .foregroundColor(.textTertiary)
                }
                .contentShape(Rectangle())
                #if os(iOS)
                .onTapGesture {
                    guard isPhone else { return }
                    withAnimation(.easeInOut(duration: 0.55)) { proxy.scrollTo("dvr-library", anchor: .top) }
                }
                #endif
                #if os(tvOS)
                TVNavActionCircle(systemImage: "arrow.up.arrow.down", label: "Sort") { showSortMenu = true }
                    .padding(.leading, 12)
                Spacer()
                #else
                Spacer()
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrderRaw = order.rawValue
                        } label: {
                            if order == sortOrder {
                                Label(order.label, systemImage: "checkmark")
                            } else {
                                Text(order.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.textPrimary.opacity(0.08)))
                }
                .accessibilityLabel("Sort")
                #endif
            }
            .padding(.horizontal, sectionInset)
            #if os(tvOS)
            .focusSection()
            #endif

            if kindsPresent.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        kindPill("All", isSelected: selectedKind == nil) { selectedKind = nil }
                        ForEach(kindsPresent) { k in
                            kindPill(k.label, isSelected: selectedKind == k) {
                                selectedKind = (selectedKind == k) ? nil : k
                            }
                        }
                    }
                    .padding(.horizontal, sectionInset)
                    #if os(tvOS)
                    .padding(.vertical, 12)
                    #endif
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }

    @ViewBuilder
    private func kindPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        Button(action: action) {
            Text(title).font(.system(size: 22, weight: .semibold))
        }
        .buttonStyle(MoviesPillStyle(isSelected: isSelected))
        #else
        Button(action: action) {
            Text(title)
                .font(.labelMedium)
                .foregroundColor(isSelected ? .appBackground : .textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color.accentPrimary : Color.elevatedBackground))
        }
        .buttonStyle(.plain)
        #endif
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: gridColumns)
        let items = filteredLibrary
        let firstID = items.first?.id
        return LazyVGrid(columns: columns, alignment: .leading, spacing: gridRowSpacing) {
            ForEach(items, id: \.id) { rec in
                card(rec, inGrid: true)
                    .background(GeometryReader { g in
                        Color.clear.onAppear {
                            if rec.id == firstID { rowPitch = g.size.height + gridRowSpacing }
                        }
                    })
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: GridTopKey.self,
                                   value: g.frame(in: .named("dvrScroll")).minY.rounded())
        })
        .padding(.horizontal, sectionInset)
        #if os(iOS)
        .padding(.trailing, isPhone ? 18 : 0)   // alphabet rail lane, like Movies
        #endif
        #if os(tvOS)
        .padding(.vertical, 20)
        .focusSection()
        #endif
    }

    private var gridRowSpacing: CGFloat {
        #if os(tvOS)
        return 44
        #else
        return 16
        #endif
    }

    // MARK: Cards

    @ViewBuilder
    private func card(_ rec: Recording, inGrid: Bool = false) -> some View {
        let button = Button {
            select(rec)
        } label: {
            #if os(iOS)
            if isPhone {
                DVRPosterCard(recording: rec, headers: headers, progress: progressFraction(rec))
            } else {
                DVRRecordingCard(recording: rec, headers: headers, progress: progressFraction(rec))
            }
            #else
            DVRRecordingCard(recording: rec, headers: headers, progress: progressFraction(rec))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(MoviesPosterFocusStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .contextMenu { menuItems(for: rec) }
        .id(rec.id)
        #if os(tvOS)
        if inGrid {
            button.focused($gridFocus, equals: rec.id)
        } else {
            button
        }
        #else
        button
        #endif
    }

    private func select(_ rec: Recording) {
        if actions.canPlay(rec) {
            actions.play(rec)
        } else if rec.isUpcoming {
            // Scheduled: nothing to play; the menu carries Cancel.
            debugLog("[DVR] select scheduled \(rec.programTitle): use the context menu to cancel")
        }
    }

    // MARK: Menu

    @ViewBuilder
    private func menuItems(for rec: Recording) -> some View {
        if rec.isCompleted || rec.status == .stopped || rec.status == .interrupted {
            Button { actions.play(rec) } label: { Label("Play", systemImage: "play.fill") }
            if rec.destination == .dispatcharrServer, rec.remoteRecordingID != nil {
                Button { actions.playServer(rec, fromStart: true) } label: {
                    Label("Watch from Beginning", systemImage: "backward.end.fill")
                }
                Button { recordingToDelete = rec; showDownloadConfirmation = true } label: {
                    Label("Save to Device", systemImage: "square.and.arrow.down")
                }
                Button { actions.runComskip(rec) } label: {
                    Label("Remove Commercials", systemImage: "scissors")
                }
            }
        }
        if rec.isInProgress {
            if rec.destination == .dispatcharrServer, rec.dispatcharrFileURL != nil {
                Button { actions.playServer(rec, liveEdge: true) } label: {
                    Label("Start at Live", systemImage: "play.fill")
                }
                Button { actions.playServer(rec, fromStart: true) } label: {
                    Label("Watch from Beginning", systemImage: "backward.end.fill")
                }
            }
            Button { actions.stop(rec) } label: { Label("Stop Recording", systemImage: "stop.fill") }
        }
        if rec.isUpcoming {
            Button(role: .destructive) { actions.cancel(rec) } label: {
                Label("Cancel Recording", systemImage: "xmark.circle")
            }
        }
        if !rec.isUpcoming {
            if rec.destination == .local {
                Button(role: .destructive) { recordingToDelete = rec; showDeleteConfirmation = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) { recordingToDelete = rec; showDeleteFromServerAlert = true } label: {
                    Label("Delete from Server", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .font(.system(size: 56))
                .foregroundColor(.textTertiary)
            Text("No Recordings")
                .font(.headlineLarge)
                .foregroundColor(.textPrimary)
            Text("Recordings for the active playlist show up here. Schedule one from the guide.")
                .font(.bodySmall)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding()
    }
}

// MARK: - Hero

/// Full-bleed hero, same construction as MoviesHero (art clipped to the
/// rounded shape, alpha-mask fades, copy over it, capsule actions).
struct DVRHero<Menu: View>: View {
    let recording: Recording
    var headers: [String: String] = [:]
    let progress: Double
    let canPlay: Bool
    /// Inside the phone card deck: the deck owns the margins.
    var inDeck: Bool = false
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onStop: () -> Void
    @ViewBuilder let menu: () -> Menu

    #if os(tvOS)
    @Environment(\.dvrHeroFocusBinding) private var focusBinding
    private let heroHeight: CGFloat = 420
    private let corner: CGFloat = 24
    private let copyInset: CGFloat = 44
    private let metaSize: CGFloat = 20
    private var titleFont: Font { .displayLarge }
    #else
    private let heroHeight: CGFloat = 220
    private let corner: CGFloat = 16
    private let copyInset: CGFloat = 16
    private let metaSize: CGFloat = 13
    private var titleFont: Font { .displayMedium }
    #endif

    private var artworkURL: URL? { (recording.backdropURL ?? recording.posterURL).flatMap { URL(string: $0) } }
    private var logoURL: URL? { recording.channelLogoURL.flatMap { URL(string: $0) } }

    var body: some View {
        #if os(tvOS)
        ZStack(alignment: .leading) {
            artwork
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .mask(leadingFadeMask)
                .mask(bottomFadeMask)
            copy
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inDeck ? 0 : 16)
        #else
        ZStack(alignment: .leading) {
            artwork
            LinearGradient(
                stops: [
                    .init(color: Color.appBackground.opacity(0.05), location: 0),
                    .init(color: Color.appBackground.opacity(0.92), location: 1)
                ],
                startPoint: .top, endPoint: .bottom)
            copy
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .padding(.horizontal, 16)
        #endif
    }

    @ViewBuilder
    private var artwork: some View {
        GeometryReader { geo in
            if let url = artworkURL {
                AuthPosterImage(url: url, headers: headers, placeholder: .clear, maxPixel: 1920)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                ZStack {
                    Color.cardBackground
                    if let logoURL {
                        AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 600)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width * 0.28)
                            .opacity(0.9)
                            .offset(x: geo.size.width * 0.28)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    #if os(tvOS)
    private var leadingFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0), location: 0.12),
                .init(color: .white.opacity(0.08), location: 0.38),
                .init(color: .white.opacity(0.65), location: 0.7),
                .init(color: .white.opacity(0.95), location: 1)
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    private var bottomFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0.55),
                .init(color: .white.opacity(0), location: 1)
            ],
            startPoint: .top, endPoint: .bottom)
    }
    #endif

    private var metaParts: [String] {
        var parts: [String] = []
        if !recording.channelName.isEmpty { parts.append(recording.channelName) }
        parts.append(DVRFormat.dateRange(recording.scheduledStart, recording.scheduledEnd))
        if recording.isInProgress {
            let sec = max(0, Date().timeIntervalSince(recording.effectiveStart))
            parts.append("\(DVRFormat.duration(seconds: sec)) recorded")
        } else if let se = recording.displaySeasonEpisode {
            parts.append("S\(se.season) E\(se.episode)")
        } else {
            parts.append(DVRFormat.duration(seconds: recording.effectiveEnd.timeIntervalSince(recording.effectiveStart)))
        }
        if let r = recording.contentRating, !r.isEmpty { parts.append(r) }
        return parts
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: copySpacing) {
            if recording.isInProgress {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("Recording now")
                }
                .font(.system(size: metaSize - 2, weight: .bold))
                .foregroundColor(.red)
            } else if progress > 0 {
                #if os(tvOS)
                Text("Continue watching")
                    .font(.system(size: metaSize - 2, weight: .bold))
                    .foregroundColor(.accentPrimary)
                #endif
            }
            Text(recording.programTitle.isEmpty ? "Recording" : recording.programTitle)
                .font(titleFont)
                .foregroundColor(.textPrimary)
                .lineLimit(2)
            if let sub = recording.subTitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: metaSize + 2, weight: .semibold))
                    .foregroundColor(.textPrimary.opacity(0.9))
                    .lineLimit(1)
            }
            #if os(tvOS)
            HStack(spacing: 10) {
                ForEach(Array(metaParts.enumerated()), id: \.offset) { idx, part in
                    if idx > 0 { Text("·").foregroundColor(.textTertiary) }
                    Text(part)
                }
            }
            .font(.system(size: metaSize, weight: .medium))
            .foregroundColor(.textSecondary)
            #else
            // Phone: the channel on its own line, the rest on one line
            // (one HStack wrapped the date mid-range, 2026-09-05).
            VStack(alignment: .leading, spacing: 2) {
                if !recording.channelName.isEmpty {
                    Text(recording.channelName).lineLimit(1)
                }
                Text(metaParts.filter { $0 != recording.channelName }.joined(separator: " · "))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.system(size: metaSize, weight: .medium))
            .foregroundColor(.textSecondary)
            #endif
            #if os(tvOS)
            if !recording.programDescription.isEmpty {
                Text(recording.programDescription)
                    .font(.bodySmall)
                    .foregroundColor(.textPrimary.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            #endif
            actions
        }
        .padding(copyInset)
        #if os(tvOS)
        .frame(maxWidth: 760, alignment: .leading)
        #else
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if recording.isInProgress {
                if canPlay {
                    focusable(MoviesHeroButton(title: "Watch from Start", systemImage: "play.fill",
                                               isPrimary: true, action: onPrimary)
                                .contextMenu { menu() }, role: "primary")
                    focusable(MoviesHeroButton(title: "Jump to Live", systemImage: "dot.radiowaves.left.and.right",
                                               isPrimary: false, action: onSecondary), role: "secondary")
                }
                focusable(MoviesHeroButton(title: "Stop Recording", systemImage: "stop.fill",
                                           isPrimary: !canPlay, action: onStop), role: canPlay ? "stop" : "primary")
            } else {
                focusable(MoviesHeroButton(title: progress > 0 ? "Resume" : "Play", systemImage: "play.fill",
                                           isPrimary: true, action: onPrimary)
                            .contextMenu { menu() }, role: "primary")
                if progress > 0 {
                    focusable(MoviesHeroButton(title: "Play from Beginning", systemImage: "gobackward",
                                               isPrimary: false, action: onSecondary), role: "secondary")
                }
            }
        }
        .padding(.top, 4)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    @ViewBuilder
    private func focusable<V: View>(_ view: V, role: String) -> some View {
        #if os(tvOS)
        if let focusBinding {
            view.focused(focusBinding, equals: role)
        } else {
            view
        }
        #else
        view
        #endif
    }

    private var copySpacing: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 6
        #endif
    }
}

#if os(tvOS)
private struct DVRHeroFocusBindingKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: FocusState<String?>.Binding? = nil
}

extension EnvironmentValues {
    var dvrHeroFocusBinding: FocusState<String?>.Binding? {
        get { self[DVRHeroFocusBindingKey.self] }
        set { self[DVRHeroFocusBindingKey.self] = newValue }
    }
}

extension View {
    func focusedDVRHero(_ binding: FocusState<String?>.Binding) -> some View {
        environment(\.dvrHeroFocusBinding, binding)
    }
}
#endif

// MARK: - Card

/// 16:9 recording card: art (server, EPG, TMDB or TheSportsDB; channel
/// logo when none), REC / Scheduled badge, channel logo bottom-left,
#if os(iOS)
/// Phone library tile: a 2:3 poster (TMDB or the library's, channel logo
/// when neither exists), REC badge, progress bar, title and meta below,
/// like the Movies grid (Logan 2026-09-05).
struct DVRPosterCard: View {
    let recording: Recording
    var headers: [String: String] = [:]
    var progress: Double = 0
    @ObservedObject private var art = DVRArtResolver.shared

    private var posterURL: URL? { recording.posterURL.flatMap { URL(string: $0) } }
    private var logoURL: URL? { recording.channelLogoURL.flatMap { URL(string: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.programTitle.isEmpty ? "Recording" : recording.programTitle)
                    .font(.labelSmall)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: 34, alignment: .top)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts = [DVRFormat.day(recording.scheduledStart)]
        if recording.isInProgress {
            parts.append("Recording")
        } else if recording.isUpcoming {
            parts.append(DVRFormat.time(recording.scheduledStart))
        } else {
            parts.append(DVRFormat.duration(seconds: recording.effectiveEnd.timeIntervalSince(recording.effectiveStart)))
        }
        if let se = recording.displaySeasonEpisode { parts.append("S\(se.season) E\(se.episode)") }
        return parts.joined(separator: " · ")
    }

    private var poster: some View {
        Color.cardBackground
            .overlay {
                if let posterURL {
                    AuthPosterImage(url: posterURL, headers: headers, placeholder: .cardBackground, maxPixel: 500)
                        .aspectRatio(contentMode: .fill)
                } else if let logoURL {
                    AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 240)
                        .aspectRatio(contentMode: .fit)
                        .padding(18)
                } else {
                    NoPosterPlaceholder()
                }
            }
            .clipped()
        .overlay(alignment: .topLeading) {
            if recording.isInProgress {
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("REC").font(.system(size: 9, weight: .heavy))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                .padding(5)
            }
        }
        .overlay(alignment: .bottom) {
            if progress > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.45))
                        Rectangle().fill(Color.accentPrimary).frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 3)
            }
        }
    }
}
#endif

/// duration bottom-right, progress bar, centred title and meta below.
struct DVRRecordingCard: View {
    let recording: Recording
    var headers: [String: String] = [:]
    var progress: Double = 0
    @ObservedObject private var art = DVRArtResolver.shared

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    private let corner: CGFloat = 12
    private let titleSize: CGFloat = 22
    private let metaSize: CGFloat = 18
    private let badgeSize: CGFloat = 16
    #else
    private let corner: CGFloat = 10
    private let titleSize: CGFloat = 14
    private let metaSize: CGFloat = 12
    private let badgeSize: CGFloat = 11
    #endif

    private var artworkURL: URL? { (recording.backdropURL ?? recording.posterURL).flatMap { URL(string: $0) } }
    private var logoURL: URL? { recording.channelLogoURL.flatMap { URL(string: $0) } }
    private var isLive: Bool {
        recording.isInProgress || (recording.isUpcoming && recording.effectiveStart <= Date() && Date() < recording.effectiveEnd)
    }

    var body: some View {
        VStack(spacing: 8) {
            artworkBlock
            VStack(spacing: 2) {
                Text(recording.programTitle.isEmpty ? "Recording" : recording.programTitle)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                Text(metaLine)
                    .font(.system(size: metaSize))
                    .foregroundColor(.textTertiary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    private var metaLine: String {
        if let sub = recording.subTitle, !sub.isEmpty {
            if let se = recording.displaySeasonEpisode { return "S\(se.season) E\(se.episode) · \(sub)" }
            return sub
        }
        if let se = recording.displaySeasonEpisode { return "S\(se.season) E\(se.episode)" }
        if recording.isUpcoming { return DVRFormat.dateRange(recording.scheduledStart, recording.scheduledEnd) }
        return DVRFormat.day(recording.scheduledStart)
    }

    private var artworkBlock: some View {
        // The 16:9 base owns the size; the art is an overlay clipped to it
        // (a filled image inside the stack made the card take the image's
        // own aspect, Logan 2026-09-05).
        Color.cardBackground
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { artLayer }
            .overlay(alignment: .bottom) { bottomBand }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .topLeading) { badge }
            #if os(tvOS)
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.accentPrimary, lineWidth: isFocused ? 4 : 0)
            )
            #endif
    }

    @ViewBuilder
    private var artLayer: some View {
        GeometryReader { g in
            if let url = artworkURL {
                AuthPosterImage(url: url, headers: headers, placeholder: .cardBackground, maxPixel: 800)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
            } else if let logoURL {
                AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 400)
                    .aspectRatio(contentMode: .fit)
                    .padding(28)
                    .opacity(0.9)
                    .frame(width: g.size.width, height: g.size.height)
            } else {
                NoPosterPlaceholder()
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    /// Bottom band so the logo and duration read on any art.
    private var bottomBand: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.75), location: 1)
                ],
                startPoint: .top, endPoint: .bottom)
            .frame(height: bandHeight)
            HStack(alignment: .bottom) {
                if artworkURL != nil, let logoURL {
                    AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 200)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: logoWidth, height: logoWidth * 0.5, alignment: .leading)
                } else if artworkURL != nil, !recording.channelName.isEmpty {
                    Text(recording.channelName)
                        .font(.system(size: badgeSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(durationText)
                    .font(.system(size: badgeSize, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, progress > 0 ? 12 : 10)
            if progress > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(Color.accentPrimary).frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private var bandHeight: CGFloat {
        #if os(tvOS)
        return 90
        #else
        return 56
        #endif
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        return 72
        #else
        return 48
        #endif
    }

    private var durationText: String {
        if recording.isInProgress {
            return DVRFormat.duration(seconds: max(0, Date().timeIntervalSince(recording.effectiveStart)))
        }
        if recording.isUpcoming { return DVRFormat.time(recording.scheduledStart) }
        return DVRFormat.duration(seconds: recording.effectiveEnd.timeIntervalSince(recording.effectiveStart))
    }

    @ViewBuilder
    private var badge: some View {
        if isLive {
            HStack(spacing: 6) {
                Circle().fill(Color.white).frame(width: 7, height: 7)
                Text("REC")
            }
            .font(.system(size: badgeSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.red))
            .padding(10)
        } else if recording.isUpcoming {
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                Text(DVRFormat.day(recording.scheduledStart))
            }
            .font(.system(size: badgeSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(10)
        } else if recording.status == .interrupted {
            Text("Partial")
                .font(.system(size: badgeSize, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.orange.opacity(0.85)))
                .padding(10)
        }
    }
}

// MARK: - Formatting

enum DVRFormat {
    static func duration(seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            let m = minutes % 60
            return m == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(m) min"
        }
        return "\(max(1, minutes)) min"
    }

    /// Honours the app's 12/24-hour setting like every other clock.
    static func time(_ date: Date) -> String {
        ClockFormat.short().string(from: date)
    }

    /// "Today", "Tomorrow", "Yesterday", else "Sep 5".
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d yyyy")
        return f.string(from: date)
    }

    static func dateRange(_ start: Date, _ end: Date) -> String {
        "\(day(start)) \(time(start)) to \(time(end))"
    }
}
