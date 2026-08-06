import SwiftUI
import SwiftData

/// Which content source the picker is currently listing. Phase 1
/// (Step 4): the picker grew from channels-only to also offer Movies,
/// Series episodes, and server Recordings so a user can build a mixed
/// multiview (a live game in one tile, a movie in another). The pill
/// bar at the top swaps between these; each case drives a different
/// content list + add path. `.channels` is the historical default so
/// the picker opens exactly as it did before.
enum MultiviewPickerSource: String, CaseIterable, Identifiable {
    case channels
    case movies
    case series
    case recordings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .channels:   return "Channels"
        case .movies:     return "Movies"
        case .series:     return "Series"
        case .recordings: return "Recordings"
        }
    }
}

/// Parameters of a VOD / recording add that the store deferred with
/// `.needsWarning` (soft-limit crossed). Stashed so the perf-warning
/// alert's Continue button can re-issue the add with `bypassWarning`.
///
/// SECURITY: `headers` can carry the active server's API key. Do NOT
/// log this struct wholesale; same rule as `MultiviewTile`.
private struct PendingVODAdd {
    let streamURL: URL
    let headers: [String: String]
    let title: String
    let posterURL: URL?
    let kind: TilePlaybackKind
    let vodID: String?
    let serverID: String?
    let vodType: String
}

/// Channel picker presented from `MultiviewTransportBar`'s "Add Tile"
/// button. Three stacked sections:
/// - Favorites (from `FavoritesStore`)
/// - Recent (from `RecentChannelsStore`, most-recent first)
/// - All Channels (from `ChannelStore.channels`, grouped by category
///   / searchable on iPad)
///
/// Adds are routed through `MultiviewStore.add(_:server:bypassWarning:)`.
/// When the store returns `.needsWarning` the sheet shows a
/// confirmation alert; on Continue, it calls `add(...)` again with
/// `bypassWarning: true` and bumps `warningLastShownAt`.
///
/// On iPad: presented as a `.sheet` with two detents — fraction 0.45
/// for a peek (can still see the grid) and `.large` for full-screen
/// search. tvOS uses a full-screen cover via the parent (sheets on
/// tvOS are platform-styled differently and cover the whole screen
/// anyway).
///
/// The sheet stays open across multiple adds. Cancel / swipe-down
/// dismisses.
struct AddToMultiviewSheet: View {
    @Binding var isPresented: Bool

    @ObservedObject private var channelStore = ChannelStore.shared
    @ObservedObject private var favoritesStore = FavoritesStore.shared
    @ObservedObject private var recentsStore = RecentChannelsStore.shared
    @ObservedObject private var multiviewStore = MultiviewStore.shared

    /// Phase 1 (Step 4): VOD catalogue (movies + series for the active
    /// server). Shared singleton, already populated by the On Demand
    /// tab's pre-fetch, so the picker's Movies / Series lists render
    /// instantly without re-fetching.
    @ObservedObject private var vodStore = VODStore.shared

    /// Server recordings live in SwiftData (synced from Dispatcharr by
    /// `MyRecordingsView`'s reconcile loop). Queried newest-first so
    /// the Recordings source mirrors that screen's ordering.
    @Query(sort: \Recording.createdAt, order: .reverse)
    private var allRecordings: [Recording]

    /// All configured servers, used to (a) resolve the active server's
    /// auth headers for VOD / recording playback and (b) scope the
    /// recordings list to the active server (matching `MyRecordingsView`).
    @Query private var servers: [ServerConnection]

    /// Phase 1 (Step 4): which content source the pill bar is showing.
    /// `.channels` keeps the picker's original behaviour on open.
    @State private var pickerSource: MultiviewPickerSource = .channels

    /// IDs (movie id / episode id / recording UUID string) whose
    /// playback URL is currently being resolved before the add lands.
    /// Drives the per-row spinner so a slow Dispatcharr proxy resolve
    /// doesn't look like a dead tap. Mirrors `VODDetailView`'s
    /// `isResolvingURL`, but keyed per row since several can resolve
    /// at once.
    @State private var resolvingIDs: Set<String> = []

    /// Series drill-in target. Non-nil when the user tapped a series
    /// and we're showing (or loading) its episode list. Back clears it.
    @State private var drilledSeries: VODSeries? = nil

    /// Non-nil when the episode fetch threw, so the UI can render an
    /// actionable error message instead of the generic "No episodes
    /// found" placeholder. Cleared on success and on re-entering the
    /// drill-in. v1.7.x: the same fetch used to use `try?` and silently
    /// produce an empty list - users had no way to tell a network blip
    /// from a series with no episodes.
    @State private var drilledEpisodesError: String? = nil

    /// Loaded episodes for `drilledSeries`, flattened across seasons.
    /// `nil` while the detail fetch is in flight (shows a spinner);
    /// empty array means "loaded, but the series has no episodes".
    @State private var drilledEpisodes: [VODEpisode]? = nil

    /// Search query on iPad. tvOS skips the search field — typing via
    /// Siri Remote is painful and the category grouping below is
    /// usually enough.
    @State private var searchText: String = ""

    /// Holds the `ChannelDisplayItem` that triggered a `.needsWarning`
    /// response. Non-nil while the performance-warning alert is
    /// showing; nil otherwise.
    @State private var pendingWarningItem: ChannelDisplayItem? = nil

    /// Phase 1 (Step 4): a VOD / recording add that hit the perf-warning
    /// soft limit, captured so the alert's Continue can re-issue it with
    /// `bypassWarning: true`. Parallel to `pendingWarningItem` (which is
    /// channel-only) because the VOD add takes resolved-URL parameters,
    /// not a `ChannelDisplayItem`.
    @State private var pendingVODAdd: PendingVODAdd? = nil

    /// Non-nil when an add attempt produced a user-facing error
    /// (`.rejectedMax`, `.unresolvable`). Short inline toast.
    @State private var toastMessage: String? = nil

    /// v1.6.12: currently-selected group filter. `"All"` is the
    /// sentinel meaning "no filter". Mirrors the Live TV channel-list
    /// pattern (see `ChannelListView.selectedGroup`) so users get the
    /// same single-keystroke "narrow to Sports / News / Movies" flow
    /// they're used to from the main channel list, without having to
    /// type into the search field.
    ///
    /// v1.7.x: persisted across picker presentations and across app
    /// launches. Freyguy1975 (Discord 2026-05-03) flagged that
    /// re-tapping the category every time you re-open the picker to
    /// add another stream from the same group was tedious — common
    /// with multi-game watch parties (e.g. building a 4-tile baseball
    /// grid from a "Baseball"-filtered list). Storage key is
    /// local-only; the value is intentionally NOT added to
    /// `SyncManager`'s sync allowlist because picker UX is per-
    /// device (different screen sizes, different multiview habits).
    /// Stale-value handling lives in `applyFilters(_:)` below: if
    /// the persisted group is no longer in `groupChips` (server
    /// change, group hidden, playlist edit) it falls back to "All".
    @AppStorage("multiviewPickerLastGroup")
    private var selectedGroup: String = "All"

    /// User-hidden groups loaded from the same `UserDefaults` key
    /// `ChannelListView` uses (`hiddenChannelGroups`). The picker
    /// honours this list so a user who hid a group in the main
    /// channel list doesn't see it resurface in the add-tile picker.
    /// Loaded on appear; not observed for live updates because
    /// hidden-groups edits happen in a separate sheet that's never
    /// presented over this one.
    @State private var hiddenGroups: Set<String> = []

    var body: some View {
        Group {
            #if os(tvOS)
            tvOSBody
            #else
            iPadOSBody
            #endif
        }
        // Phase 1 (Step 4): perf-warning alert for VOD / recording adds.
        // Parallel to the channel warning in `SharedSheetModifiers`;
        // separate because the deferred add carries resolved-URL params
        // rather than a `ChannelDisplayItem`. Continue re-issues the add
        // with `bypassWarning: true`.
        .alert(
            "Performance may degrade",
            isPresented: Binding(
                get: { pendingVODAdd != nil },
                set: { if !$0 { pendingVODAdd = nil } }
            ),
            presenting: pendingVODAdd
        ) { pending in
            Button("Continue", role: .destructive) {
                pendingVODAdd = nil
                commitAddVOD(
                    streamURL: pending.streamURL, headers: pending.headers,
                    title: pending.title, posterURL: pending.posterURL,
                    kind: pending.kind, vodID: pending.vodID,
                    serverID: pending.serverID, vodType: pending.vodType,
                    bypassWarning: true
                )
            }
            // #46 (GH): suppress this warning permanently (device-local) and
            // proceed, matching the channel-add alert above.
            Button("Don't Show Again") {
                UserDefaults.standard.set(true, forKey: "multiviewPerfWarningSuppressed")
                pendingVODAdd = nil
                commitAddVOD(
                    streamURL: pending.streamURL, headers: pending.headers,
                    title: pending.title, posterURL: pending.posterURL,
                    kind: pending.kind, vodID: pending.vodID,
                    serverID: pending.serverID, vodType: pending.vodType,
                    bypassWarning: true
                )
            }
            Button("Cancel", role: .cancel) { pendingVODAdd = nil }
        } message: { _ in
            Text("Adding more than \(multiviewStore.softLimit) streams may cause audio drops, buffering, or overheating on some devices.")
        }
    }

    // MARK: - iPadOS body (NavigationStack + List + detents)

    #if !os(tvOS)
    @ViewBuilder
    private var iPadOSBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // v1.6.12: group filter pill bar — same vocabulary as
                // Live TV's filter row. Placed above the List (not in
                // the toolbar) so the chips stay visible while the
                // search bar is focused; collapsed entirely when there
                // are 0–1 visible groups so a single-group provider
                // doesn't get a lonely "All" chip eating vertical room.
                //
                // Phase 1 (Step 4): the source switcher (Channels /
                // Movies / Series / Recordings) sits above the group
                // filter. The group filter is channel-only (VOD has no
                // group chips), so it's hidden for the other sources.
                iPadSourcePillBar
                if pickerSource == .channels, groupChips.count > 1 {
                    iPadGroupFilterBar
                }

                iPadContent
            }
            .searchable(text: $searchText, prompt: iPadSearchPrompt)
            .navigationTitle("Add to Multiview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .onAppear { loadHiddenGroups() }
            // v1.7.x: re-validate the persisted filter when channels
            // finish loading (Dispatcharr cold start can deliver
            // groups several seconds after the picker mounts) or
            // when the user switches active server while the picker
            // is open. Without this, a persisted "Sports" filter on
            // server A would render an empty list when server B is
            // active and has no "Sports" group.
            .onChange(of: channelStore.orderedGroups) { _, _ in
                validateSelectedGroup()
            }
            .modifier(SharedSheetModifiers(
                pendingWarningItem: $pendingWarningItem,
                toastMessage: $toastMessage,
                softLimit: multiviewStore.softLimit,
                onContinueWarning: { item in
                    pendingWarningItem = nil
                    commitAdd(item, bypassWarning: true)
                },
                onCancelWarning: { pendingWarningItem = nil }
            ))
        }
    }

    /// Horizontal scrolling row of group-filter chips for iPad.
    /// Visual lifted from `ChannelListView`'s inline filter row so
    /// the picker matches the channel list at a glance: accent fill
    /// for selected, elevated background for unselected, capsule
    /// shape, single-tap select. Spring animation softens the
    /// selection swap.
    @ViewBuilder
    private var iPadGroupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groupChips, id: \.self) { group in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedGroup = group
                        }
                    } label: {
                        Text(group)
                            .font(.labelMedium)
                            .foregroundColor(selectedGroup == group
                                             ? .appBackground
                                             : .textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedGroup == group
                                    ? AnyView(Capsule().fill(Color.accentPrimary))
                                    : AnyView(Capsule().fill(Color.elevatedBackground))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter: \(group)")
                    .accessibilityAddTraits(selectedGroup == group ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Phase 1 (Step 4): source switcher pill bar for iPad. Same visual
    /// vocabulary as `iPadGroupFilterBar` (accent fill selected,
    /// elevated unselected, capsule) so the picker reads as one
    /// cohesive control. Switching source clears the search field and
    /// any series drill-in so the new source starts clean.
    @ViewBuilder
    private var iPadSourcePillBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MultiviewPickerSource.allCases) { source in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectSource(source)
                        }
                    } label: {
                        Text(source.displayName)
                            .font(.labelMedium)
                            .foregroundColor(pickerSource == source
                                             ? .appBackground
                                             : .textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                pickerSource == source
                                    ? AnyView(Capsule().fill(Color.accentPrimary))
                                    : AnyView(Capsule().fill(Color.elevatedBackground))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Source: \(source.displayName)")
                    .accessibilityAddTraits(pickerSource == source ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Phase 1 (Step 4): the iPad content list, switched by source.
    /// Channels keep their original Favorites / Recent / All sections;
    /// Movies / Series / Recordings render their own row types. All use
    /// a plain `List` with `LazyVStack`-equivalent on-demand row
    /// realization so large catalogues don't decode every poster up
    /// front.
    @ViewBuilder
    private var iPadContent: some View {
        switch pickerSource {
        case .channels:
            List {
                if !favoriteChannels.isEmpty {
                    section(title: "Favorites", items: favoriteChannels)
                }
                if !recentChannels.isEmpty {
                    section(title: "Recent", items: recentChannels)
                }
                section(title: "All Channels", items: allChannelsFiltered)
            }
            .listStyle(.plain)
        case .movies:
            List {
                moviesSection
            }
            .listStyle(.plain)
        case .series:
            iPadSeriesContent
        case .recordings:
            List {
                recordingSection
            }
            .listStyle(.plain)
        }
    }

    /// Series source on iPad: either the show grid (a list of series)
    /// or, when one is drilled into, that series' episodes with a Back
    /// row at the top. A `List` keeps the platform's swipe / scroll
    /// behaviour consistent with the channels source.
    @ViewBuilder
    private var iPadSeriesContent: some View {
        List {
            if let series = drilledSeries {
                Section {
                    Button {
                        exitSeriesDrillIn()
                    } label: {
                        Label("Back to Series", systemImage: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(Color.accentPrimary)
                    }
                    .buttonStyle(.plain)
                }
                if drilledEpisodes == nil {
                    Section(series.name) {
                        HStack {
                            ProgressView()
                            Text("Loading episodes...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if drilledEpisodesFiltered.isEmpty {
                    // v1.7.x: render fetch failures distinctly. Pre-fix the
                    // try? in loadDrilledEpisodes turned every error into
                    // a silent empty list - users could not tell a network
                    // blip from a series with no scraped episodes.
                    Section(series.name) {
                        if let err = drilledEpisodesError {
                            Label("Couldn't load episodes: \(err)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No episodes found")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section(series.name) {
                        ForEach(drilledEpisodesFiltered) { ep in
                            episodeRow(ep, seriesPoster: series.posterURL)
                        }
                    }
                }
            } else {
                Section("Series") {
                    ForEach(seriesFiltered) { item in
                        seriesRow(item)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Movies section body (iPad). Each row resolves + adds on tap.
    private var moviesSection: some View {
        Section("Movies") {
            ForEach(moviesFiltered) { item in
                if let movie = item.movie {
                    movieRow(movie)
                }
            }
        }
    }

    /// Recordings section body (iPad).
    private var recordingSection: some View {
        Section("Recordings") {
            ForEach(recordingsFiltered, id: \.id) { rec in
                recordingRow(rec)
            }
        }
    }

    /// Search prompt reflects the active source so the field reads
    /// naturally ("Search movies" while browsing movies, etc.).
    private var iPadSearchPrompt: String {
        switch pickerSource {
        case .channels:   return "Search channels"
        case .movies:     return "Search movies"
        case .series:     return drilledSeries == nil ? "Search series" : "Search episodes"
        case .recordings: return "Search recordings"
        }
    }
    #endif

    // MARK: - tvOS body (full-screen, couch-readable)

    #if os(tvOS)
    /// Full-screen tvOS picker. Built from scratch (no
    /// `NavigationStack`, no `List`) because SwiftUI's default sheet
    /// on tvOS renders small + centred — titles truncate, rows
    /// cram, and the whole thing looks like an iPad form sheet
    /// stranded on a 4K TV. This layout uses the entire screen:
    /// big title, a prominent Close button top-right, a
    /// `ScrollView` + `LazyVStack` for the sections so the content
    /// can be as wide and spacious as we want.
    ///
    /// Dismissal paths:
    /// - Focus → Close button → Select
    /// - Menu (Siri Remote Back) → `.onExitCommand`
    @ViewBuilder
    private var tvOSBody: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 80)
                    .padding(.top, 40)
                    .padding(.bottom, 20)

                // Phase 1 (Step 4): source switcher (Channels / Movies
                // / Series / Recordings). Sits directly under the
                // header so D-pad Down from Close lands here first, then
                // the (channel-only) group filter, then the list.
                tvSourcePillBar
                    .padding(.horizontal, 80)
                    .padding(.bottom, 12)
                    .focusSection()

                // v1.6.12: group filter pill bar. Sits between the
                // header and the channel scroll so the focus engine's
                // natural top-to-bottom traversal lands on filter
                // chips before the (much longer) channel list, mirroring
                // Live TV's tvOS layout. `.focusSection()` keeps focus
                // grouped here when the user moves up from the channels
                // — without it, swiping up jumps straight to the Close
                // button instead of the chips. Channel-only: VOD
                // sources have no group chips.
                if pickerSource == .channels, groupChips.count > 1 {
                    tvGroupFilterBar
                        .padding(.horizontal, 80)
                        .padding(.bottom, 12)
                        .focusSection()
                }

                ScrollView {
                    // Rows are direct children of `LazyVStack` so
                    // SwiftUI can lazily materialise them as the
                    // user scrolls. A previous revision grouped
                    // each section into a `VStack` child, which
                    // defeated lazy-loading entirely — the parent
                    // `LazyVStack` saw each section as a single
                    // opaque child and instantiated all 700+
                    // `CompactChannelRow`s up-front, each with its
                    // own eager `AsyncImage` decode. That's what
                    // caused the "scroll 4-5 channels → crash"
                    // behaviour: RSS blew past the tvOS foreground
                    // process cap before the system could reap
                    // off-screen rows.
                    //
                    // Now section headers + rows are flat siblings
                    // in a single `LazyVStack`. `spacing: 12` keeps
                    // the row rhythm; the header `.padding(.top, 20)`
                    // reinstates the visual gap between sections
                    // without costing lazy-load.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        tvContent
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 60)
                }
            }
        }
        .onExitCommand { isPresented = false }
        .onAppear { loadHiddenGroups() }
        // v1.7.x: re-validate persisted filter when channels load
        // async or active-server changes mid-presentation. See iOS
        // body's matching modifier for the full rationale.
        .onChange(of: channelStore.orderedGroups) { _, _ in
            validateSelectedGroup()
        }
        .modifier(SharedSheetModifiers(
            pendingWarningItem: $pendingWarningItem,
            toastMessage: $toastMessage,
            softLimit: multiviewStore.softLimit,
            onContinueWarning: { item in
                pendingWarningItem = nil
                commitAdd(item, bypassWarning: true)
            },
            onCancelWarning: { pendingWarningItem = nil }
        ))
    }

    /// Horizontal scrolling row of group-filter chips for tvOS.
    /// Larger type and padding than the iPad bar (couch-readable),
    /// and uses `PickerGroupPillButtonStyle` (defined at the bottom
    /// of this file) so focus halo + scale match the rest of the
    /// tvOS multiview vocabulary.
    @ViewBuilder
    private var tvGroupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(groupChips, id: \.self) { group in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedGroup = group
                        }
                    } label: {
                        Text(group)
                            .font(.system(size: 22, weight: .medium))
                    }
                    .buttonStyle(PickerGroupPillButtonStyle(
                        isSelected: selectedGroup == group
                    ))
                    .accessibilityLabel("Filter: \(group)")
                    .accessibilityAddTraits(selectedGroup == group ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Phase 1 (Step 4): source switcher pill bar for tvOS. Same
    /// `PickerGroupPillButtonStyle` as the group filter so focus halo +
    /// scale match. Switching source resets search + any series
    /// drill-in.
    @ViewBuilder
    private var tvSourcePillBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(MultiviewPickerSource.allCases) { source in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectSource(source)
                        }
                    } label: {
                        Text(source.displayName)
                            .font(.system(size: 22, weight: .medium))
                    }
                    .buttonStyle(PickerGroupPillButtonStyle(
                        isSelected: pickerSource == source
                    ))
                    .accessibilityLabel("Source: \(source.displayName)")
                    .accessibilityAddTraits(pickerSource == source ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Phase 1 (Step 4): tvOS content, switched by source. Each branch
    /// emits flat `LazyVStack` siblings (section header + rows) so lazy
    /// realization is preserved exactly like the channels list.
    @ViewBuilder
    private var tvContent: some View {
        switch pickerSource {
        case .channels:
            // Each `ForEach` id is namespaced by section name
            // ("fav:<id>", "recent:<id>", "all:<id>") because the same
            // channel can appear in multiple sections (a favorited
            // channel is also in All Channels), and SwiftUI's
            // `LazyVStack` emits "ID used by multiple child views"
            // warnings + real rendering glitches when two siblings
            // share an `explicitID`. Composite keys keep each row's
            // identity unique within the flat list.
            if !favoriteChannels.isEmpty {
                tvSectionHeader("Favorites")
                ForEach(favoriteChannels, id: \.favSectionID) { item in
                    tvChannelRow(item)
                }
            }
            if !recentChannels.isEmpty {
                tvSectionHeader("Recent")
                ForEach(recentChannels, id: \.recentSectionID) { item in
                    tvChannelRow(item)
                }
            }
            tvSectionHeader("All Channels")
            ForEach(allChannelsFiltered, id: \.allSectionID) { item in
                tvChannelRow(item)
            }
        case .movies:
            tvSectionHeader("Movies")
            if moviesFiltered.isEmpty {
                tvEmptyRow("No movies available")
            }
            ForEach(moviesFiltered) { item in
                if let movie = item.movie {
                    movieRow(movie)
                }
            }
        case .series:
            tvSeriesContent
        case .recordings:
            tvSectionHeader("Recordings")
            if recordingsFiltered.isEmpty {
                tvEmptyRow("No playable recordings")
            }
            ForEach(recordingsFiltered, id: \.id) { rec in
                recordingRow(rec)
            }
        }
    }

    /// tvOS Series source: show list, or the drilled series' episodes
    /// with a Back row. Flat siblings keep lazy realization.
    @ViewBuilder
    private var tvSeriesContent: some View {
        if let series = drilledSeries {
            Button {
                exitSeriesDrillIn()
            } label: {
                Label("Back to Series", systemImage: "chevron.left")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentPrimary)
                    .padding(.vertical, 8)
            }
            .buttonStyle(TVNoHighlightButtonStyle())
            tvSectionHeader(series.name)
            if drilledEpisodes == nil {
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Loading episodes...")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.vertical, 12)
            } else if drilledEpisodesFiltered.isEmpty {
                tvEmptyRow(drilledEpisodesError.map { "Couldn't load episodes: \($0)" } ?? "No episodes found")
            } else {
                ForEach(drilledEpisodesFiltered) { ep in
                    episodeRow(ep, seriesPoster: series.posterURL)
                }
            }
        } else {
            tvSectionHeader("Series")
            if seriesFiltered.isEmpty {
                tvEmptyRow("No series available")
            }
            ForEach(seriesFiltered) { item in
                seriesRow(item)
            }
        }
    }

    /// A simple empty-state row for the tvOS list (no content for the
    /// active source). Couch-readable, muted.
    private func tvEmptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.vertical, 24)
    }

    /// Header: title on the left, big Close button on the right.
    /// Close uses `TransportButtonStyle`-style focus chrome
    /// (defined locally below) so its focus state matches the rest
    /// of the multiview UI vocabulary.
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to Multiview")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(multiviewStore.count) of \(multiviewStore.maxTiles) tiles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Text("Close")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 160, minHeight: 60)
                    .padding(.horizontal, 24)
            }
            .buttonStyle(AddSheetCloseButtonStyle())
            .accessibilityLabel("Close picker")
        }
    }
    #endif

    // MARK: - Sections

    #if os(tvOS)
    /// Section header used inside the flat `LazyVStack` — rendered
    /// as a single `Text` so lazy loading isn't defeated by wrapping
    /// it in a container. The `.padding(.top, 20)` reinstates the
    /// visual gap between sections that the old 32pt `LazyVStack`
    /// spacing used to provide.
    private func tvSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    /// Row factory — each returned view is a direct child of the
    /// flat `LazyVStack`, so SwiftUI can lazy-materialise them.
    private func tvChannelRow(_ item: ChannelDisplayItem) -> some View {
        CompactChannelRow(
            item: item,
            isAlreadyAdded: alreadyAdded(item),
            isDisabled: multiviewStore.isAtMax
        ) {
            tap(item)
        }
    }
    #else
    private func section(title: String, items: [ChannelDisplayItem]) -> some View {
        Section(title) {
            // Keyed by the unique stream URL (rowKey) so two channels
            // sharing a tvg-id stay distinct within the section.
            ForEach(items, id: \.rowKey) { item in
                CompactChannelRow(
                    item: item,
                    isAlreadyAdded: alreadyAdded(item),
                    isDisabled: multiviewStore.isAtMax
                ) {
                    tap(item)
                }
            }
        }
    }
    #endif

    /// Tap dispatcher. v1.6.12: a tap on an already-added row now
    /// removes the corresponding tile from multiview (deselect)
    /// rather than being a no-op. Pre-v1.6.12 the user had to
    /// dismiss the picker, find the tile in the grid, and remove it
    /// from the per-tile menu — confusingly indirect for what is
    /// just "I changed my mind." Now the picker is a true toggle:
    /// tap to add, tap again to remove.
    ///
    /// No toast on remove — the row's trailing icon flips from green
    /// check back to the `+` and the live tile count in the header
    /// drops by one, both immediately visible and far less noisy than
    /// a transient capsule. Adds still show their own error/warning
    /// toasts via `commitAdd`.
    private func tap(_ item: ChannelDisplayItem) {
        if alreadyAdded(item) {
            multiviewStore.remove(id: item.id)
        } else {
            tryAdd(item)
        }
    }

    // MARK: - VOD / Recording rows (Phase 1 Step 4)

    /// A movie row. Tap resolves the proxy URL then adds a `.vod` tile.
    /// Shows a spinner while resolving, a green check once a tile with
    /// this movie's id exists, the `+` otherwise.
    private func movieRow(_ movie: VODMovie) -> some View {
        let added = vodAlreadyAdded(vodID: movie.id)
        return VODPickerRow(
            title: movie.name,
            subtitle: movie.releaseYear.isEmpty ? nil : movie.releaseYear,
            posterURL: movie.posterURL,
            headers: activeServerHeaders,
            trailing: rowTrailingState(isAdded: added, isResolving: resolvingIDs.contains(movie.id)),
            isDisabled: multiviewStore.isAtMax && !added
        ) {
            if added {
                removeVODTile(vodID: movie.id)
                return
            }
            guard let url = movie.streamURL else {
                showToast("This movie has no playable stream")
                return
            }
            Task {
                await resolveAndAddVOD(
                    id: movie.id, proxyURL: url, title: movie.name,
                    posterURL: movie.posterURL, vodID: movie.id, vodType: "movie"
                )
            }
        }
    }

    /// A series row. Tap drills into the show's episode list (no add on
    /// the series itself; a multiview tile plays one episode).
    private func seriesRow(_ item: VODDisplayItem) -> some View {
        VODPickerRow(
            title: item.name,
            subtitle: item.releaseYear.isEmpty ? nil : item.releaseYear,
            posterURL: item.posterURL,
            headers: activeServerHeaders,
            trailing: .disclosure,
            isDisabled: false
        ) {
            if let series = item.series {
                enterSeriesDrillIn(series)
            }
        }
    }

    /// An episode row inside a drilled-into series. Tap resolves the
    /// episode's proxy URL then adds a `.vod` tile.
    private func episodeRow(_ ep: VODEpisode, seriesPoster: URL?) -> some View {
        let added = vodAlreadyAdded(vodID: ep.id)
        let label = episodeNumberLabel(season: ep.seasonNumber, episode: ep.episodeNumber)
        let title = label.isEmpty ? ep.title : "\(label)  \(ep.title)"
        return VODPickerRow(
            title: title,
            subtitle: nil,
            posterURL: ep.posterURL ?? seriesPoster,
            headers: activeServerHeaders,
            trailing: rowTrailingState(isAdded: added, isResolving: resolvingIDs.contains(ep.id)),
            isDisabled: multiviewStore.isAtMax && !added
        ) {
            if added {
                removeVODTile(vodID: ep.id)
                return
            }
            guard let url = ep.streamURL else {
                showToast("This episode has no playable stream")
                return
            }
            Task {
                await resolveAndAddVOD(
                    id: ep.id, proxyURL: url, title: ep.title,
                    posterURL: ep.posterURL ?? seriesPoster,
                    vodID: ep.id, vodType: "episode"
                )
            }
        }
    }

    /// A recording row. Tap adds the recording as a tile (completed =>
    /// `.vod` file, in-progress => `.dvr` HLS). Recordings carry no VOD
    /// id (no continue-watching), so the row can't show an "added"
    /// check keyed on a vodID; it always shows `+` (a recording can be
    /// added more than once, matching the channel duplicate rule).
    private func recordingRow(_ rec: Recording) -> some View {
        let subtitle = rec.isInProgress
            ? "Recording now - \(rec.channelName)"
            : rec.channelName
        return VODPickerRow(
            title: rec.programTitle.isEmpty ? "Recording" : rec.programTitle,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            posterURL: nil,
            headers: activeServerHeaders,
            trailing: multiviewStore.isAtMax ? .blocked : .add,
            isDisabled: multiviewStore.isAtMax
        ) {
            addRecording(rec)
        }
    }

    /// Trailing-icon state for a VOD row, given add + resolve flags.
    private func rowTrailingState(isAdded: Bool, isResolving: Bool) -> VODPickerRow.Trailing {
        if isResolving { return .loading }
        if isAdded { return .added }
        if multiviewStore.isAtMax { return .blocked }
        return .add
    }

    /// "S1:E4" / "E4" / "" using the same convention as Continue Watching.
    private func episodeNumberLabel(season: Int, episode: Int) -> String {
        if season > 0 && episode > 0 { return "S\(season):E\(episode)" }
        if episode > 0 { return "E\(episode)" }
        return ""
    }

    /// `true` when a tile already carries this VOD id (movie / episode).
    private func vodAlreadyAdded(vodID: String) -> Bool {
        multiviewStore.tiles.contains { $0.vodID == vodID }
    }

    /// Remove the tile carrying this VOD id (tap-again-to-deselect,
    /// matching the channel toggle behaviour).
    private func removeVODTile(vodID: String) {
        guard let tile = multiviewStore.tiles.first(where: { $0.vodID == vodID }) else { return }
        multiviewStore.remove(id: tile.id)
    }

    // MARK: - Source / drill-in navigation (Phase 1 Step 4)

    /// Switch the active source. Clears the search field and any series
    /// drill-in so the new source starts from a clean state. No-op when
    /// the source is unchanged.
    private func selectSource(_ source: MultiviewPickerSource) {
        guard source != pickerSource else { return }
        pickerSource = source
        searchText = ""
        drilledSeries = nil
        drilledEpisodes = nil
    }

    /// Begin a series drill-in: stash the series, clear the search, and
    /// kick off the episode fetch.
    private func enterSeriesDrillIn(_ series: VODSeries) {
        drilledSeries = series
        drilledEpisodes = nil
        drilledEpisodesError = nil
        searchText = ""
        Task { await loadDrilledEpisodes(series) }
    }

    /// Leave the series drill-in, back to the show list.
    private func exitSeriesDrillIn() {
        drilledSeries = nil
        drilledEpisodes = nil
        drilledEpisodesError = nil
        searchText = ""
    }

    // MARK: - Data

    private var favoriteChannels: [ChannelDisplayItem] {
        applyFilters(favoritesStore.favoriteItems)
    }

    private var recentChannels: [ChannelDisplayItem] {
        applyFilters(recentsStore.resolved)
    }

    private var allChannelsFiltered: [ChannelDisplayItem] {
        applyFilters(channelStore.channels)
    }

    // MARK: - VOD / Recordings data (Phase 1 Step 4)

    /// The active server, used for VOD / recording auth headers and
    /// for the async URL resolve. VOD content is per-active-server
    /// (the On Demand tab loads from whichever server is active), so
    /// the channel store's `activeServer` is the same server that
    /// produced `vodStore.movies` / `.series`.
    private var activeServer: ServerConnection? {
        channelStore.activeServer
            ?? servers.first(where: { $0.isActive })
            ?? servers.first
    }

    /// Auth headers for the active server's stream / file requests.
    /// Same shape `VODDetailView.serverHeaders()` and
    /// `MyRecordingsView` hand to the player. Falls back to an empty
    /// dictionary when no server is active (the lists are then empty
    /// too, so this is only defensive).
    private var activeServerHeaders: [String: String] {
        activeServer?.authHeaders ?? [:]
    }

    /// Movies for the active server, search-filtered. The group filter
    /// is channel-only, so VOD sources honour just the search query.
    private var moviesFiltered: [VODDisplayItem] {
        searchFilterVOD(vodStore.movies)
    }

    /// Series for the active server, search-filtered.
    private var seriesFiltered: [VODDisplayItem] {
        searchFilterVOD(vodStore.series)
    }

    /// Episodes of the drilled-into series, search-filtered by title.
    private var drilledEpisodesFiltered: [VODEpisode] {
        let eps = drilledEpisodes ?? []
        guard !searchText.isEmpty else { return eps }
        let q = searchText.lowercased()
        return eps.filter { $0.title.lowercased().contains(q) }
    }

    /// Recordings scoped to the active server and limited to the
    /// statuses a tile can actually play: completed / stopped (a
    /// finished file) and in-progress recordings that expose the new
    /// HLS DVR pipeline. Scheduled / failed rows are omitted (nothing
    /// to play). Search-filtered on the program title.
    private var recordingsFiltered: [Recording] {
        guard let sid = activeServer?.id.uuidString else { return [] }
        let scoped = allRecordings.filter { $0.serverID == sid }
        let playable = scoped.filter { recordingIsPlayable($0) }
        guard !searchText.isEmpty else { return playable }
        let q = searchText.lowercased()
        return playable.filter {
            $0.programTitle.lowercased().contains(q)
                || $0.channelName.lowercased().contains(q)
        }
    }

    /// A recording is addable to a tile when it has a playable URL:
    /// a completed/stopped server recording, or an in-progress server
    /// recording whose HLS pipeline URL the server has emitted. Local
    /// recordings are excluded: their `file://` path plays fine in the
    /// single full-screen player but the multiview tile pipeline is
    /// built around remote streams, and an in-progress local file is
    /// held open by the recorder. Matches `MyRecordingsView`'s
    /// server-playback gating.
    private func recordingIsPlayable(_ rec: Recording) -> Bool {
        guard rec.destination == .dispatcharrServer,
              rec.remoteRecordingID != nil else { return false }
        if rec.isCompleted || rec.status == .stopped { return true }
        if rec.status == .recording, rec.dispatcharrFileURL != nil { return true }
        return false
    }

    /// Case-insensitive substring match on a VOD item's name. The
    /// group-filter pill bar is channel-only, so VOD lists filter on
    /// the search query alone.
    private func searchFilterVOD(_ items: [VODDisplayItem]) -> [VODDisplayItem] {
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter { $0.name.lowercased().contains(q) }
    }

    /// Groups eligible to appear in the filter pill bar — the
    /// store-ordered list with user-hidden groups removed. A group
    /// only shows if at least one channel in `channelStore.channels`
    /// belongs to it; `orderedGroups` is already maintained that way
    /// upstream.
    private var visibleGroups: [String] {
        channelStore.orderedGroups.filter { !hiddenGroups.contains($0) }
    }

    /// Pills shown in the filter bar — leading "All" sentinel plus
    /// every visible group. Computed (not stored) so the bar updates
    /// automatically when the channel store finishes its initial
    /// load while the picker is open (Dispatcharr cold launch can
    /// take a couple of seconds).
    private var groupChips: [String] {
        ["All"] + visibleGroups
    }

    /// Apply the current group + search filters. Group filter runs
    /// first because it's the cheaper predicate (`==` vs three
    /// substring comparisons) and prunes the working set before the
    /// substring scan. `selectedGroup == "All"` short-circuits past
    /// the group step.
    ///
    /// Matches across name / group / channel number, case-insensitive.
    /// `String.contains` is a literal substring match — no regex
    /// injection surface even though `searchText` is user input.
    private func applyFilters(_ items: [ChannelDisplayItem]) -> [ChannelDisplayItem] {
        var result = items
        if selectedGroup != "All" {
            result = result.filter { $0.group == selectedGroup }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { item in
                item.name.lowercased().contains(q)
                    || item.group.lowercased().contains(q)
                    || item.number.lowercased().contains(q)
            }
        }
        return result
    }

    /// One-shot loader for the user's hidden-groups set. Called from
    /// each body's `.onAppear`. If the previously-selected group is
    /// now hidden (because the user hid it elsewhere between picker
    /// presentations), snap back to "All" so the filter doesn't get
    /// stuck pointing at an invisible chip.
    ///
    /// v1.7.x: now that `selectedGroup` is `@AppStorage`-backed, the
    /// stale-value cases multiply: persisted group might (a) be
    /// hidden, (b) belong to a server the user has since switched
    /// away from, or (c) have been edited out of the playlist
    /// upstream. `validateSelectedGroup()` covers all three by
    /// falling back to "All" whenever the persisted value isn't
    /// in the current `groupChips`. Called here AND from
    /// `.onChange(of: channelStore.orderedGroups)` so we catch the
    /// "channels loaded async after picker presented" case too.
    private func loadHiddenGroups() {
        hiddenGroups = HiddenGroupsStore.load(forKey: "hiddenChannelGroups")
        validateSelectedGroup()
    }

    /// v1.7.x: drop `selectedGroup` back to "All" if the persisted
    /// value is no longer represented in `groupChips`. Idempotent;
    /// safe to call from any view-update context. The `@AppStorage`
    /// write only fires when the value actually changes (SwiftUI
    /// optimization), so this won't ping-pong.
    private func validateSelectedGroup() {
        guard selectedGroup != "All" else { return }
        if !groupChips.contains(selectedGroup) {
            selectedGroup = "All"
        }
    }

    private func alreadyAdded(_ item: ChannelDisplayItem) -> Bool {
        multiviewStore.tiles.contains { $0.item.id == item.id }
    }

    // MARK: - Add flow

    private func tryAdd(_ item: ChannelDisplayItem) {
        // Thermal refusal — the container banner is the primary
        // signal; this toast gives the immediate feedback at the
        // moment of the blocked tap. Threshold is `.critical` only
        // (matches `isThermallyStressed`); `.serious` is warning-not-
        // blocking per the plan.
        if multiviewStore.isThermallyStressed {
            DebugLogger.shared.log(
                "[MV-Thermal] add refused: critical",
                category: "Playback", level: .warning
            )
            showToast("Device is too hot to add more streams")
            return
        }
        commitAdd(item, bypassWarning: false)
    }

    private func commitAdd(_ item: ChannelDisplayItem, bypassWarning: Bool) {
        // Auto-seed when this sheet was presented from single-mode
        // `PlayerView` (tile list is empty, `PlayerSession.mode` is
        // not yet `.multiview`). Seeding tile 0 here — at commit time,
        // *after* the user has picked — is the whole point of the
        // sheet-first flow: the current stream keeps playing under
        // the sheet while the user browses, and the mode flip / view
        // swap happens exactly once in response to a deliberate pick
        // rather than at button-tap.
        //
        // Idempotent: `enterMultiview(seeding:server:)` only seeds if
        // `tiles.isEmpty`, and we guard on that here too. If the
        // sheet is already open from inside `MultiviewContainerView`
        // (the transport-bar `+`), this branch is a no-op and we
        // fall straight through to `add(...)`.
        if multiviewStore.tiles.isEmpty,
           PlayerSession.shared.mode != .multiview,
           let currentItem = NowPlayingManager.shared.playingItem,
           let server = channelStore.activeServer {
            DebugLogger.shared.log(
                "[MV-Mode] commitAdd from single — seeding tile 0 with current=\(currentItem.name) before picked=\(item.name)",
                category: "Playback", level: .info
            )
            PlayerSession.shared.enterMultiview(seeding: currentItem, server: server)
        }

        let result = multiviewStore.add(
            item,
            server: channelStore.activeServer,
            bypassWarning: bypassWarning
        )
        switch result {
        case .added:
            // Push into recents so the next add-sheet open shows it
            // near the top. Keeps the "frequently-added" set warm
            // without a dedicated "most-added" heuristic.
            recentsStore.push(item)
        case .needsWarning:
            DebugLogger.shared.log(
                "[MV-Tile] perf warning shown (count=\(multiviewStore.count))",
                category: "Playback", level: .info
            )
            pendingWarningItem = item
            multiviewStore.warningLastShownAt = Date()
        case .rejectedMax:
            showToast("Maximum \(multiviewStore.maxTiles) streams reached")
        case .alreadyPresent:
            showToast("Already added")
        case .unresolvable:
            showToast("This channel has no playable stream")
        }
    }

    // MARK: - VOD / Recording add flow (Phase 1 Step 4)

    /// Resolve a VOD proxy URL (Dispatcharr only) then add the tile.
    /// Mirrors `VODDetailView.resolveAndLaunch`: Dispatcharr's
    /// `/proxy/vod/*` endpoints redirect to a session / provider URL,
    /// and the tile's player can drop custom headers across a redirect,
    /// so we resolve the final URL up-front with the active server's
    /// auth headers. Xtream URLs are direct (auth is in the path) and
    /// need no resolve. While resolving, `id` is held in `resolvingIDs`
    /// so the row shows a spinner.
    ///
    /// `proxyURL` here is the raw `VODMovie.streamURL` / `VODEpisode.streamURL`.
    /// The resolved URL and the server headers are NEVER logged
    /// (credentials); same convention as the rest of this file.
    @MainActor
    private func resolveAndAddVOD(
        id: String,
        proxyURL: URL,
        title: String,
        posterURL: URL?,
        vodID: String?,
        vodType: String
    ) async {
        guard !resolvingIDs.contains(id) else { return }
        let server = activeServer
        var headers = activeServerHeaders

        // Thermal refusal: same gate as the channel path's `tryAdd`.
        if multiviewStore.isThermallyStressed {
            showToast("Device is too hot to add more streams")
            return
        }

        resolvingIDs.insert(id)
        defer { resolvingIDs.remove(id) }

        var resolvedURL = proxyURL
        if let server, server.type == .dispatcharrAPI {
            let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                     auth: .apiKey(server.effectiveApiKey),
                                     userAgent: server.effectiveUserAgent,
                                     authMode: server.dispatcharrHeaderMode)
            resolvedURL = (try? await api.resolveFinalURLForPlayback(proxyURL)) ?? proxyURL
            // Audit #38 parity (Android ee06e17): never replay the API key
            // to a session URL that resolved OFF the server's own hosts.
            // User-Agent stays; it carries no secret.
            if !api.isOwnHost(resolvedURL) {
                headers = headers.filter {
                    $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
                }
            }
        }

        commitAddVOD(
            streamURL: resolvedURL,
            headers: headers,
            title: title,
            posterURL: posterURL,
            kind: .vod,
            vodID: vodID,
            serverID: server?.id.uuidString,
            vodType: vodType
        )
    }

    /// Add a server recording as a tile. Completed / stopped recordings
    /// play their finished file (kind `.vod`, no continue-watching);
    /// in-progress recordings play the growing HLS DVR window (kind
    /// `.dvr`). URL + headers are built exactly as
    /// `MyRecordingsView.playServerRecording` does. No async resolve is
    /// needed (the recording endpoints are not the redirecting
    /// `/proxy/vod/*` shape).
    @MainActor
    private func addRecording(_ rec: Recording) {
        guard let server = activeServer,
              server.type == .dispatcharrAPI,
              let remoteID = rec.remoteRecordingID else {
            showToast("This recording has no playable stream")
            return
        }
        if multiviewStore.isThermallyStressed {
            showToast("Device is too hot to add more streams")
            return
        }

        // Prefer the server-reported file_url (HLS for in-progress,
        // direct file for completed); fall back to the constructed
        // /file/ URL on older builds. Same precedence as MyRecordingsView.
        let url: URL
        let isHLS: Bool
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        if let fileURL = rec.dispatcharrFileURL, !fileURL.isEmpty,
           let resolved = resolveRecordingURL(server: server, relative: fileURL) {
            url = resolved
            isHLS = fileURL.contains(".m3u8")
        } else if let fallback = api.recordingPlaybackURL(id: remoteID) {
            url = fallback
            isHLS = false
        } else {
            showToast("This recording has no playable stream")
            return
        }

        // In-progress + HLS is a growing DVR window (kind .dvr); a
        // completed recording or the legacy /file/ fallback is a fixed
        // file (kind .vod). vodID stays nil so there's no
        // continue-watching, matching the single recording player.
        let kind: TilePlaybackKind = (rec.isInProgress && isHLS) ? .dvr : .vod
        commitAddVOD(
            streamURL: url,
            headers: server.authHeaders,
            title: rec.programTitle.isEmpty ? "Recording" : rec.programTitle,
            posterURL: nil,
            kind: kind,
            vodID: nil,
            serverID: server.id.uuidString,
            vodType: "movie"
        )
    }

    /// Resolves a Dispatcharr-relative `file_url` against the active
    /// server's base URL. Copy of `MyRecordingsView.resolveRecordingURL`
    /// (absolute strings pass through; relative ones anchor to the base).
    private func resolveRecordingURL(server: ServerConnection, relative: String) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        let base = server.effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    /// Shared commit for VOD / recording tiles. Auto-seeds tile 0 from
    /// a playing single stream (same as the channel `commitAdd`) so the
    /// sheet-first flow works when the picker was opened over a live
    /// stream, then routes through `MultiviewStore.addVOD` and maps the
    /// `AddResult` to the same warning / toast UI as the channel path.
    /// The perf-warning Continue branch re-issues with `bypassWarning`
    /// via `pendingVODAdd`.
    @MainActor
    private func commitAddVOD(
        streamURL: URL,
        headers: [String: String],
        title: String,
        posterURL: URL?,
        kind: TilePlaybackKind,
        vodID: String?,
        serverID: String?,
        vodType: String,
        bypassWarning: Bool = false
    ) {
        // Auto-seed tile 0 from the current single stream, identical
        // to the channel `commitAdd` branch so adding a movie/recording
        // as the FIRST tile keeps the live stream playing in tile 0.
        if multiviewStore.tiles.isEmpty,
           PlayerSession.shared.mode != .multiview,
           let currentItem = NowPlayingManager.shared.playingItem,
           let server = channelStore.activeServer {
            PlayerSession.shared.enterMultiview(seeding: currentItem, server: server)
        }

        let result = multiviewStore.addVOD(
            title: title,
            streamURL: streamURL,
            headers: headers,
            posterURL: posterURL,
            kind: kind,
            vodID: vodID,
            serverID: serverID,
            vodType: vodType,
            resumePositionMs: nil,
            bypassWarning: bypassWarning
        )
        switch result {
        case .added:
            break
        case .needsWarning:
            // Stash the parameters so Continue can re-issue with
            // bypassWarning. Reuse the same alert as the channel path.
            pendingVODAdd = PendingVODAdd(
                streamURL: streamURL, headers: headers, title: title,
                posterURL: posterURL, kind: kind, vodID: vodID,
                serverID: serverID, vodType: vodType
            )
            multiviewStore.warningLastShownAt = Date()
        case .rejectedMax:
            showToast("Maximum \(multiviewStore.maxTiles) streams reached")
        case .alreadyPresent:
            showToast("Already added")
        case .unresolvable:
            showToast("This title has no playable stream")
        }
    }

    /// Load the drilled-into series' episodes. Mirrors
    /// `VODDetailView`'s series `loadDetail`: route through
    /// `VODService.fetchSeriesDetail`, which returns a fully populated
    /// `VODSeries` (seasons + episodes). Flattened season-then-episode
    /// for a single scroll list. The slim list-time `VODSeries` carries
    /// no episodes, so this fetch is required.
    @MainActor
    private func loadDrilledEpisodes(_ series: VODSeries) async {
        guard let server = activeServer else {
            drilledEpisodes = []
            return
        }
        drilledEpisodes = nil  // spinner
        let snap = server.snapshot
        // v1.7.x: surface failures instead of swallowing them. The pre-fix
        // call was `try? await ...` which collapsed every error path
        // (network, decode, auth) into an empty episode list, so a user
        // who hit the Series picker on a server that briefly failed
        // /api/vod/series/<id>/episodes/ would see "No episodes found"
        // with no signal to retry. Surface the error in debugLog so the
        // failure mode is visible the next time it happens, and leave a
        // dedicated drilledEpisodesError state for the UI to render an
        // actionable message rather than the generic empty placeholder.
        let detail: VODSeries?
        do {
            detail = try await VODService.fetchSeriesDetail(
                seriesID: series.id, from: snap, existing: series
            )
        } catch {
            debugLog("[MV-AddToMV] series detail fetch FAILED: id=\(series.id) name=\(series.name) error=\(error.localizedDescription)")
            guard drilledSeries?.id == series.id else { return }
            drilledEpisodesError = error.localizedDescription
            drilledEpisodes = []
            return
        }
        // Bail if the user backed out / switched series while loading.
        guard drilledSeries?.id == series.id else { return }
        let flattened = (detail?.seasons ?? [])
            .sorted { $0.seasonNumber < $1.seasonNumber }
            .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
        if flattened.isEmpty {
            // Distinguish "fetch succeeded, server reports zero episodes"
            // (rare but real - Dispatcharr's scraper hasn't run yet for
            // this series, OR the seasons array is empty by design) from
            // "fetch failed" above. Both render the same empty state in
            // the UI today, but the debugLog tells us which one to chase.
            debugLog("[MV-AddToMV] series detail returned empty episodes: id=\(series.id) name=\(series.name) seasons=\(detail?.seasons.count ?? 0)")
        }
        drilledEpisodesError = nil
        drilledEpisodes = flattened
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            #if os(tvOS)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            #else
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #endif
            .foregroundStyle(.white)
            .background(
                Capsule().fill(Color.black.opacity(0.85))
            )
            .accessibilityLabel(text)
    }
}

// MARK: - VOD / Recording picker row (Phase 1 Step 4)

/// A single Movies / Series / Episode / Recording row inside the
/// `AddToMultiviewSheet`. Visual sibling to `CompactChannelRow`: a
/// leading poster thumbnail, a title (+ optional subtitle), and a
/// trailing affordance whose icon depends on state (add / added /
/// loading / blocked / disclosure). Platform-agnostic, with the same
/// tvOS focus treatment (`TVNoHighlightButtonStyle`) the channel row
/// uses so the picker reads as one consistent list.
///
/// Poster art routes through `AuthPosterImage` (defined in
/// `MoviesView.swift`) so the active server's auth headers reach the
/// poster fetch (Dispatcharr posters 401 without them). Recordings
/// have no art and fall back to a film-icon placeholder.
private struct VODPickerRow: View {
    /// Trailing-icon state. `disclosure` is for a series row (tap
    /// drills in rather than adds); the others mirror
    /// `CompactChannelRow.trailing`.
    enum Trailing {
        case add
        case added
        case loading
        case blocked
        case disclosure
    }

    let title: String
    var subtitle: String? = nil
    let posterURL: URL?
    var headers: [String: String] = [:]
    let trailing: Trailing
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: rowSpacing) {
                poster

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(titleFont)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(subtitleFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
                trailingIcon
            }
            .padding(.vertical, rowVPadding)
            .padding(.horizontal, rowHPadding)
            .contentShape(Rectangle())
            .opacity(rowOpacity)
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isDisabled)
        .accessibilityLabel(a11yLabel)
    }

    // MARK: Subviews

    @ViewBuilder
    private var poster: some View {
        // 2:3 poster aspect, matching the VOD grid. Sized to the same
        // footprint as the channel row's square logo so both row types
        // align in a mixed list.
        if posterURL != nil {
            AuthPosterImage(url: posterURL, headers: headers)
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: posterWidth, height: posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: posterWidth, height: posterHeight)
                .overlay(
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                )
        }
    }

    @ViewBuilder
    private var trailingIcon: some View {
        switch trailing {
        case .add:
            Image(systemName: "plus.circle")
                .font(.system(size: trailingIconSize))
                .foregroundStyle(Color.accentPrimary)
        case .added:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: trailingIconSize))
                .foregroundStyle(.green)
        case .loading:
            ProgressView()
                #if os(tvOS)
                .scaleEffect(1.4)
                #endif
        case .blocked:
            Image(systemName: "hand.raised.slash")
                .font(.system(size: trailingIconSize))
                .foregroundStyle(.secondary)
        case .disclosure:
            Image(systemName: "chevron.right")
                .font(.system(size: trailingIconSize * 0.8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Platform sizing

    private var posterWidth: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 30
        #endif
    }

    private var posterHeight: CGFloat {
        #if os(tvOS)
        return 72
        #else
        return 45
        #endif
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 12
        #endif
    }

    private var rowVPadding: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 8
        #endif
    }

    private var rowHPadding: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 12
        #endif
    }

    private var titleFont: Font {
        #if os(tvOS)
        return .system(size: 26, weight: .semibold)
        #else
        return .headline
        #endif
    }

    private var subtitleFont: Font {
        #if os(tvOS)
        return .system(size: 20, weight: .regular)
        #else
        return .caption
        #endif
    }

    private var trailingIconSize: CGFloat {
        #if os(tvOS)
        return 30
        #else
        return 22
        #endif
    }

    private var rowOpacity: Double {
        switch trailing {
        case .added:   return 0.55
        case .blocked: return 0.4
        default:       return 1
        }
    }

    private var a11yLabel: String {
        let sub = subtitle.map { ", \($0)" } ?? ""
        switch trailing {
        case .added:      return "\(title)\(sub), added"
        case .blocked:    return "\(title)\(sub), cannot add, limit reached"
        case .loading:    return "\(title)\(sub), adding"
        case .disclosure: return "\(title)\(sub), show episodes"
        case .add:        return "\(title)\(sub)"
        }
    }
}

// MARK: - Namespaced ID helpers

private extension ChannelDisplayItem {
    /// Section-namespaced identity used as a SwiftUI `ForEach` id
    /// when the same item appears in multiple sections of the same
    /// `LazyVStack`. SwiftUI emits "ID is used by multiple child
    /// views" runtime warnings when two siblings share an
    /// `explicitID`; prefixing with a section name restores
    /// uniqueness without allocating a whole wrapper type per row.
    ///
    /// Exposed as three computed properties (rather than a single
    /// `func namespacedID(_:)`) because `ForEach(_:id:)` requires a
    /// `KeyPath<Element, ID>`, and Swift key paths can reference
    /// computed properties but not functions with arguments.
    /// Namespaced off `rowKey` (the unique stream URL), not `id`, so a
    /// provider that reuses one tvg-id across distinct channels can't make
    /// two rows collide within a section.
    var favSectionID: String { "fav:\(rowKey)" }
    var recentSectionID: String { "recent:\(rowKey)" }
    var allSectionID: String { "all:\(rowKey)" }
}

// MARK: - Shared sheet modifiers

/// Bundles the perf-warning alert + toast overlay + animation
/// modifiers so both the iPad and tvOS body paths apply them
/// identically without duplicating 30 lines of code. The caller
/// passes in the bindings and closures it owns; the modifier
/// attaches the SwiftUI side.
private struct SharedSheetModifiers: ViewModifier {
    @Binding var pendingWarningItem: ChannelDisplayItem?
    @Binding var toastMessage: String?
    let softLimit: Int
    let onContinueWarning: (ChannelDisplayItem) -> Void
    let onCancelWarning: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Performance may degrade",
                isPresented: Binding(
                    get: { pendingWarningItem != nil },
                    set: { if !$0 { pendingWarningItem = nil } }
                ),
                presenting: pendingWarningItem
            ) { item in
                Button("Continue", role: .destructive) {
                    onContinueWarning(item)
                }
                // #46 (GH): suppress this warning permanently (device-local)
                // and proceed with the add, so a user who routinely runs more
                // than the soft limit is not nagged every time.
                Button("Don't Show Again") {
                    UserDefaults.standard.set(true, forKey: "multiviewPerfWarningSuppressed")
                    onContinueWarning(item)
                }
                Button("Cancel", role: .cancel) {
                    onCancelWarning()
                }
            } message: { _ in
                Text("Adding more than \(softLimit) streams may cause audio drops, buffering, or overheating on some devices.")
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    toast(toastMessage)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            #if os(tvOS)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            #else
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #endif
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .accessibilityLabel(text)
    }
}

// MARK: - tvOS group filter pill style

#if os(tvOS)
/// Pill style for the picker's group-filter chips. Mirrors the
/// `TVGroupPillButtonStyle` used by `ChannelListView`'s tvOS group
/// row (which is `private` to that file, hence this duplicate) so
/// the picker reads as a sibling to the main channel list rather
/// than its own visual dialect.
///
/// - Selected: accent fill, dark foreground (high-contrast against
///   the brand color).
/// - Focused-not-selected: accent ring + 1.05 scale, label switches
///   to white so it's legible against the elevated background.
/// - Resting: elevated background, secondary-text label, slight
///   opacity dip so the focused chip clearly leads.
struct PickerGroupPillButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .foregroundColor(isSelected
                             ? .appBackground
                             : (focused ? .white : .textSecondary))
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
            )
            .overlay(
                Capsule()
                    .stroke(focused && !isSelected ? Color.accentPrimary : Color.clear,
                            lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .opacity(focused ? 1.0 : (isSelected ? 1.0 : 0.85))
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif

// MARK: - tvOS close button style

#if os(tvOS)
/// Capsule-shaped focus chrome for the sheet's Close button.
/// Shares the same design language as
/// `MultiviewTransportBar.TransportButtonStyle`: default subtle
/// white fill, focused state gets a heavy white ring + 1.08 scale
/// + accent shadow. Reads `@Environment(\.isFocused)` so SwiftUI
/// focus state drives the visual without an external binding.
struct AddSheetCloseButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(
                    isFocused ? Color.white.opacity(0.28) : Color.white.opacity(0.10)
                )
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(0.18),
                    lineWidth: isFocused ? 4 : 1
                )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: isFocused ? .black.opacity(0.55) : .clear,
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif
