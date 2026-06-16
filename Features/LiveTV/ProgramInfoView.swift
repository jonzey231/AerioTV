import SwiftUI

// MARK: - Program Info Target
//
// Minimal value type that carries everything `ProgramInfoView` needs
// to render a program detail modal. Callers build one of these from
// whichever richer program object they have on hand — `GuideProgram`
// in the guide grid, `EPGEntry` + channel context in the list-view
// expanded panel, or `ChannelDisplayItem.currentProgram*` fields for
// the always-visible "now airing" card.
//
// `Identifiable` so call sites can use the `.sheet(item:)` /
// `.fullScreenCover(item:)` form, which presents / dismisses based on
// whether the state is non-nil. Cleaner than tracking a separate Bool
// + a payload that has to survive the dismiss animation.
//
// The `id` is built from the same title+start+end triple `EPGEntry`
// uses so switching programs in rapid succession doesn't fight
// SwiftUI's identity diffing.
struct ProgramInfoTarget: Identifiable, Equatable {
    let channelName: String
    let title: String
    let start: Date
    let end: Date
    let description: String
    /// Raw XMLTV `<category>` string. May contain multiple categories
    /// separated by `,`, `/`, or `;` (e.g. `"Drama, Sci-Fi"`). The
    /// pill renderer splits on those separators and colours each
    /// token independently so users can see both how the feed tagged
    /// the program AND how each tag resolves into Aerio's category
    /// palette.
    let category: String

    /// v1.7.x: Dispatcharr's per-program primary key, used by
    /// `ProgramInfoView` to lazy-load category data from
    /// `/api/epg/programs/<id>/` when the bulk `/api/epg/grid/`
    /// response stripped it (which it does for every program except
    /// the now-airing one we already enriched). Nil for XMLTV /
    /// Xtream / M3U sources whose bulk feed already carries categories
    /// inline; lazy-load is a no-op in those cases.
    let programID: Int?

    var id: String {
        "\(title)-\(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)"
    }

    init(channelName: String, title: String, start: Date, end: Date,
         description: String, category: String, programID: Int? = nil) {
        self.channelName = channelName
        self.title = title
        self.start = start
        self.end = end
        self.description = description
        self.category = category
        self.programID = programID
    }
}

// MARK: - Program Info View
//
// Read-only modal that surfaces everything Aerio knows about a
// single program. Opened from the long-press / context-menu on any
// program cell (guide grid) or row (list view). Purpose is twofold:
//
//   1. Let users read the description + category metadata without
//      needing to start playback.
//   2. Expose the category tagging behind the v1.6.4 guide-cell tint
//      so users can audit their EPG feed quality from inside the app.
//      Matching colour between the info pill and the guide tint is
//      intentional — the pill IS the legend for the grid.
//
// Missing fields are surfaced, not hidden. A program whose XMLTV
// entry has no `<desc>` shows a "No description…" placeholder
// instead of a gap; a missing category renders a neutral-grey pill
// labeled with the raw token. This matches Archie's "audit from
// inside the app" requirement — a silent empty field teaches the
// user nothing about why a program isn't tinted.
struct ProgramInfoView: View {
    let target: ProgramInfoTarget
    @Environment(\.dismiss) private var dismiss

    /// v1.7.x: lazy-loaded category result for Dispatcharr programs
    /// whose `target.category` arrived empty. The bulk
    /// `/api/epg/grid/` endpoint deliberately strips `<category>`
    /// data server-side, so only the now-airing program per channel
    /// (which `enrichDispatcharrCategories` proactively fetches) lands
    /// here with a non-empty `target.category`. For everything else,
    /// we fire a single `/api/epg/programs/<id>/` request when the
    /// modal appears and update the pills as it returns. ~40ms on a
    /// healthy server, so the user perceives "pills appear right
    /// after the sheet slides in" rather than an obvious loading
    /// spinner.
    @State private var loadedCategory: String? = nil
    @State private var isLoadingCategory: Bool = false

    /// Program poster, resolved from the Dispatcharr program detail
    /// (Schedules Direct poster proxy, XMLTV `<image>`/`<icon>`), or
    /// from TMDB-by-title when that opt-in is enabled and the server
    /// has no artwork. nil = no poster, render nothing.
    @State private var posterURL: URL? = nil

    /// Auth headers for the active Dispatcharr server, in case a
    /// program icon is a protected `/media/` URL. The Schedules-Direct
    /// poster proxy and TMDB CDN are both auth-free, so this is
    /// usually unused but harmless.
    private var posterAuthHeaders: [String: String] {
        ChannelStore.shared.activeServer?.authHeaders ?? [:]
    }

    /// Display category — prefers the loaded value over the target's
    /// initial value so a successful detail fetch wins. Empty string
    /// when neither source has data; the pills sections then hide
    /// entirely (matches the pre-v1.7.x behaviour for unenriched
    /// XMLTV / Xtream programs whose feed has no category tags).
    private var effectiveCategory: String {
        if let loaded = loadedCategory, !loaded.isEmpty { return loaded }
        return target.category
    }

    // Shared between platforms: a formatter for the start/end time
    // row. 12-hour on iOS (user locale), short style on tvOS.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .none
        f.dateStyle = .medium
        return f
    }()

    /// Duration label — "45 min", "1 h 30 min", "2 h". Duration of 0
    /// or negative (malformed EPG) falls back to "—".
    private var durationLabel: String {
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0 else { return "—" }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if mins == 0 {
            return "\(hours) h"
        }
        return "\(hours) h \(mins) min"
    }

    private var start: Date { target.start }
    private var end: Date { target.end }
    private var isLive: Bool { start <= Date() && end > Date() }

    /// Time range + date header. Collapses "same day" to just the
    /// time range; adds the date only when the program spans or
    /// starts on a different calendar day than today (late-night
    /// programs that start at 23:45 and end at 00:30 still read
    /// as "today" here — that's fine, the date row is an
    /// affordance for overnight / future recording scheduling
    /// more than strict precision).
    private var timeRangeLabel: String {
        let start = Self.timeFormatter.string(from: target.start)
        let end = Self.timeFormatter.string(from: target.end)
        return "\(start) – \(end)"
    }

    private var dateLabel: String {
        Self.dateFormatter.string(from: target.start)
    }

    /// Split raw category string on XMLTV's common separators. Empty
    /// tokens (double-commas, trailing separators) are filtered out.
    /// Reads `effectiveCategory` so a Dispatcharr lazy-load result
    /// flows into the pill rendering as soon as it lands.
    private var categoryTokens: [String] {
        let separators = CharacterSet(charactersIn: ",/;")
        return effectiveCategory
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// XMLTV program-type/format words that describe HOW a program is
    /// packaged rather than WHAT it contains. Shown in a separate
    /// "Metadata" pill row so users can see the content categories
    /// on their own without the format-indicator noise drowning
    /// them out. These are the words Archie specifically called out
    /// as not being genres — "Episode", "Series", etc. The match
    /// is case-insensitive and exact (not substring) so "Comedy"
    /// never accidentally lands in Metadata.
    private static let metadataTokens: Set<String> = [
        "episode",
        "series",
        "movie",
        "film",
        "feature",
        "feature film",
        "short",
        "short film",
        "special",
        "premiere",
        "season premiere",
        "series premiere",
        "finale",
        "season finale",
        "series finale",
        "rerun",
        "repeat",
        "live",
        "pilot",
        "made-for-tv movie",
        "made for tv movie",
        "miniseries",
        "limited series"
    ]

    /// Category tokens classified as XMLTV metadata (format/type).
    private var metadataPills: [String] {
        categoryTokens.filter { Self.metadataTokens.contains($0.lowercased()) }
    }

    /// Category tokens that are actual genres — everything not
    /// claimed by `metadataPills`. These are the tokens the category
    /// colour palette tries to resolve into buckets (Sports, News,
    /// Drama, etc.) for the pill tint.
    private var genrePills: [String] {
        categoryTokens.filter { !Self.metadataTokens.contains($0.lowercased()) }
    }

    var body: some View {
        #if os(tvOS)
        tvBody
            .task(id: target.id) {
                await loadCategoryIfNeeded()
                await loadTMDBPosterIfNeeded()
            }
        #else
        NavigationStack {
            iOSForm
                // Suppress the system grouped-list background so the
                // sheet stays on the app's black theme at both
                // `.medium` and `.large` detents. Without this the
                // Form renders its default "grouped list" grey,
                // which looks off against the rest of Aerio's dark
                // chrome (user-reported: expanded sheet turns gray).
                .scrollContentBackground(.hidden)
                .background(Color.appBackground)
                .navigationTitle("Program Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .toolbarBackground(Color.appBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
        .task(id: target.id) {
            await loadCategoryIfNeeded()
            await loadTMDBPosterIfNeeded()
        }
        #endif
    }

    // MARK: - Lazy Category Load (Dispatcharr only)
    //
    // Fires when the modal appears with an empty `target.category`
    // and a non-nil `programID`. Hits `/api/epg/programs/<id>/` to
    // pull the rich detail Dispatcharr's bulk grid strips, then
    // populates `loadedCategory` so the pill sections re-render.
    //
    // Silently no-ops when:
    //   • `target.category` is already populated (now-airing program
    //     enriched at guide-load time, or any XMLTV / Xtream source
    //     that includes categories inline). One less network call.
    //   • `target.programID` is nil (XMLTV / Xtream / M3U sources
    //     that don't carry Dispatcharr's per-program primary key).
    //   • `ChannelStore.shared.activeServer` is missing or isn't a
    //     `dispatcharrAPI` server. Defensive — the modal is only
    //     reached via channel rows whose server is by definition
    //     the active one, but a server switch mid-presentation
    //     shouldn't crash the lookup.
    //   • The fetch fails (timeout, 401, decode error). Pills just
    //     don't appear — same outcome as if the program genuinely
    //     had no categories. No banner, no error state. The user
    //     can dismiss + reopen to retry.
    @MainActor
    private func loadCategoryIfNeeded() async {
        // v1.7.x diagnostic: log every guard outcome and the API
        // result so a user with empty Program Info pills can capture
        // exactly which step is breaking. Each branch tags its reason
        // so the log greps cleanly.
        let pidStr = target.programID.map(String.init) ?? "nil"
        debugLog("📺 ProgramInfo lazy-load entry: title='\(target.title.prefix(40))' category.empty=\(target.category.isEmpty) programID=\(pidStr)")
        // Fetch the detail when EITHER the category pills are still
        // missing OR we don't yet have a poster (the detail call
        // carries both, so one request serves both needs).
        let categoryNeeded = target.category.isEmpty && loadedCategory == nil
        let posterNeeded = posterURL == nil
        guard categoryNeeded || posterNeeded else {
            debugLog("📺 ProgramInfo lazy-load SKIP: category + poster already resolved")
            return
        }
        guard let pid = target.programID else {
            debugLog("📺 ProgramInfo lazy-load SKIP: programID is nil (target wasn't built from a Dispatcharr-grid program — XMLTV/Xtream/dummy source, or the construction site didn't thread programID)")
            return
        }
        guard let server = ChannelStore.shared.activeServer else {
            debugLog("📺 ProgramInfo lazy-load SKIP: ChannelStore.activeServer is nil")
            return
        }
        guard server.type == .dispatcharrAPI else {
            debugLog("📺 ProgramInfo lazy-load SKIP: activeServer.type=\(server.type) (not dispatcharrAPI)")
            return
        }
        let baseURL = server.effectiveBaseURL
        let apiKey = server.effectiveApiKey
        guard !baseURL.isEmpty, !apiKey.isEmpty else {
            debugLog("📺 ProgramInfo lazy-load SKIP: baseURL.empty=\(baseURL.isEmpty) apiKey.empty=\(apiKey.isEmpty)")
            return
        }
        isLoadingCategory = true
        defer { isLoadingCategory = false }
        // v1.7.x: pass serverID + savedUsername so a 401 from a
        // rotated api_key triggers silent re-bootstrap rather than
        // leaving the modal pill-less.
        let api = DispatcharrAPI(baseURL: baseURL,
                                  auth: .apiKey(apiKey),
                                  userAgent: server.effectiveUserAgent,
                                  authMode: server.dispatcharrHeaderMode,
                                  serverID: server.id,
                                  savedUsername: server.dispatcharrCredentialType == .usernamePassword
                                      ? server.username : nil)
        do {
            let detail = try await api.getProgramDetail(id: pid)
            let cats = detail.categories.joined(separator: ",")
            debugLog("📺 ProgramInfo lazy-load OK: pid=\(pid) returned \(detail.categories.count) categories: '\(cats.prefix(80))'")
            // Only assign if we got something — avoids triggering a
            // pointless re-render on empty results, and leaves the
            // door open for a future retry path.
            if categoryNeeded, !cats.isEmpty {
                loadedCategory = cats
            }
            // Server-provided poster (SD proxy / XMLTV image / icon).
            // resolveImageURL validates the host (SSRF guard) and maps
            // bare TMDB slugs to the CDN, same as the VOD path.
            if posterNeeded, let raw = detail.bestPosterString {
                posterURL = VODService.resolveImageURL(raw, base: baseURL, size: "w500")
                debugLog("📺 ProgramInfo poster: \(posterURL?.absoluteString ?? "rejected/none")")
            }
        } catch {
            debugLog("📺 ProgramInfo lazy-load FAIL: pid=\(pid) error=\(error.localizedDescription)")
            // Swallow — the modal stays usable without pills.
        }
    }

    /// TMDB-by-title poster fallback. Runs after the server-poster
    /// attempt; only fires when the program has no server poster, the
    /// user enabled TMDB posters (Settings > App Behaviors), and a key
    /// is stored. Works for every source (no Dispatcharr programID
    /// required) since it keys off the title.
    @MainActor
    private func loadTMDBPosterIfNeeded() async {
        guard posterURL == nil,
              TMDBPosters.isEnabled,
              let apiKey = TMDBPosters.apiKey,
              !target.title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        if let url = await TMDBService.posterURL(forTitle: target.title, apiKey: apiKey) {
            posterURL = url
            debugLog("📺 ProgramInfo TMDB poster: \(url.absoluteString)")
        }
    }

    // MARK: - iOS Layout

    #if os(iOS)
    @ViewBuilder
    private var iOSForm: some View {
        Form {
            if let posterURL {
                Section {
                    HStack {
                        Spacer()
                        AuthPosterImage(url: posterURL, headers: posterAuthHeaders)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 130, height: 195)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                LabeledContent("Channel", value: target.channelName)
                LabeledContent("Program", value: target.title)
                LabeledContent("Airs", value: timeRangeLabel)
                LabeledContent("Date", value: dateLabel)
                LabeledContent("Duration", value: durationLabel)
                if isLive {
                    HStack {
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.statusLive, in: Capsule())
                        Spacer()
                    }
                }
            }

            Section("Description") {
                descriptionText
                    .textSelection(.enabled)
            }

            // Metadata pills — XMLTV format indicators. Rendered as
            // neutral grey pills regardless of palette state because
            // they're not genres (no tint mapping applies).
            if !metadataPills.isEmpty {
                Section("Metadata") {
                    CategoryPillsLayout(spacing: 6) {
                        ForEach(metadataPills, id: \.self) { token in
                            CategoryPill(rawToken: token, forceNeutral: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Genre pills — tokens that may resolve to a palette
            // bucket (Sports, Drama, etc.). Unresolved tokens still
            // render as neutral grey pills so the user can audit
            // what their feed tagged.
            if !genrePills.isEmpty {
                Section("Categories") {
                    CategoryPillsLayout(spacing: 6) {
                        ForEach(genrePills, id: \.self) { token in
                            CategoryPill(rawToken: token)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    #endif

    // MARK: - tvOS Layout

    #if os(tvOS)
    @ViewBuilder
    private var tvBody: some View {
        ZStack(alignment: .topTrailing) {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if let posterURL {
                        AuthPosterImage(url: posterURL, headers: posterAuthHeaders)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 220, height: 330)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    // Header — channel + title + live badge
                    VStack(alignment: .leading, spacing: 12) {
                        Text(target.channelName.uppercased())
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.textSecondary)
                            .tracking(1.5)
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(target.title)
                                .font(.system(size: 44, weight: .bold))
                                .foregroundColor(.textPrimary)
                            if isLive {
                                Text("LIVE")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.statusLive, in: Capsule())
                            }
                        }
                    }

                    // Time row — date + range + duration
                    HStack(spacing: 40) {
                        infoColumn(title: "Airs", value: timeRangeLabel)
                        infoColumn(title: "Date", value: dateLabel)
                        infoColumn(title: "Duration", value: durationLabel)
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.textSecondary)
                        descriptionText
                    }

                    // Metadata pills (XMLTV format indicators — neutral
                    // grey, not palette-tinted).
                    if !metadataPills.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Metadata")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.textSecondary)
                            CategoryPillsLayout(spacing: 10) {
                                ForEach(metadataPills, id: \.self) { token in
                                    CategoryPill(rawToken: token, forceNeutral: true)
                                }
                            }
                        }
                    }

                    // Genre pills (palette-tinted where the token
                    // matches a bucket / custom entry).
                    if !genrePills.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Categories")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.textSecondary)
                            CategoryPillsLayout(spacing: 10) {
                                ForEach(genrePills, id: \.self) { token in
                                    CategoryPill(rawToken: token)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 72)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Close") { dismiss() }
                .padding(.top, 48)
                .padding(.trailing, 64)
        }
        // tvOS Menu button defaults to dismissing the fullScreenCover,
        // but being explicit keeps the behaviour intentional. The
        // .onExitCommand handler runs even when the Close button
        // doesn't have focus, which matches users' Menu-to-back
        // expectation throughout the app.
        .onExitCommand { dismiss() }
    }

    private func infoColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.textTertiary)
                .tracking(1.2)
            Text(value)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.textPrimary)
        }
    }
    #endif

    // MARK: - Shared Chrome

    @ViewBuilder
    private var descriptionText: some View {
        if target.description.isEmpty {
            #if os(tvOS)
            Text("No program description provided in XMLTV.")
                .font(.system(size: 22))
                .foregroundColor(.textTertiary)
                .italic()
            #else
            Text("No program description provided in XMLTV.")
                .foregroundStyle(.secondary)
                .italic()
            #endif
        } else {
            #if os(tvOS)
            Text(target.description)
                .font(.system(size: 24))
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text(target.description)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }
}

// MARK: - Category Pill
//
// Colour comes from the same `CategoryColor` palette the guide grid
// uses for cell tint, so a pill in this modal matches the tint on
// the cell the user long-pressed to open the modal. Resolution
// order matches `CategoryColor.backgroundColor`:
//
//   1. User-defined custom category (from Settings) — hex wins.
//   2. Built-in bucket whose aliases contain the token — bucket's
//      current (possibly user-overridden) colour wins.
//   3. Neither — neutral grey pill so the token is still visible,
//      teaching the user that this tag doesn't resolve to any
//      colour in their palette. Part of the "audit EPG quality"
//      goal.
//
// The label is always the RAW token from the XMLTV feed, not the
// resolved bucket's display name. Users asked for "how did my feed
// tag this program" — showing the bucket name would hide the raw
// data behind Aerio's canonicalisation.
struct CategoryPill: View {
    let rawToken: String
    /// When true, skip palette resolution entirely and render as a
    /// neutral grey pill. Used for the "Metadata" section in
    /// `ProgramInfoView`, whose tokens (Episode / Series / Movie
    /// etc.) aren't genres and shouldn't falsely pick up a bucket
    /// colour via substring match (e.g., "Special" wouldn't hit a
    /// bucket today but a future palette change shouldn't surprise
    /// us).
    var forceNeutral: Bool = false

    /// Resolved (color, opacity) pair. `nil` background → use the
    /// neutral-grey fallback handled below.
    private var fill: Color {
        if forceNeutral { return Color.textTertiary }
        if let hex = CategoryColor.customHex(for: rawToken) {
            return Color(hex: hex)
        }
        if let bucket = CategoryColor.bucket(for: rawToken) {
            return bucket.baseColor
        }
        return Color.textTertiary
    }

    /// Whether the palette actually matched this token. Used to dim
    /// the "unmatched" pills slightly so matched ones read as the
    /// visually-active state.
    private var isResolved: Bool {
        guard !forceNeutral else { return false }
        return CategoryColor.customHex(for: rawToken) != nil ||
               CategoryColor.bucket(for: rawToken) != nil
    }

    var body: some View {
        Text(rawToken)
            #if os(tvOS)
            .font(.system(size: 20, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            #else
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            #endif
            .foregroundColor(isResolved ? .white : .textSecondary)
            .background(
                Capsule().fill(fill.opacity(isResolved ? 0.85 : 0.25))
            )
    }
}

// MARK: - CategoryPillsLayout
//
// A simple flow layout: children are laid out left-to-right, wrapping
// to a new line when the available width runs out. Used for the
// category pills since a typical program has 1–4 categories and a
// horizontal ScrollView would look out of place inside a Form row
// or a tvOS vertical stack.
//
// Uses the Swift 5.7+ `Layout` protocol. iOS 16+ / tvOS 16+ / macOS
// 13+ — well under Aerio's deployment floor.
struct CategoryPillsLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if cursorX + size.width > maxWidth, cursorX > 0 {
                cursorY += lineHeight + spacing
                cursorX = 0
                lineHeight = 0
            }
            cursorX += size.width + spacing
            contentWidth = max(contentWidth, cursorX - spacing)
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: contentWidth, height: cursorY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var lineHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if cursorX + size.width > bounds.maxX, cursorX > bounds.minX {
                cursorY += lineHeight + spacing
                cursorX = bounds.minX
                lineHeight = 0
            }
            sub.place(
                at: CGPoint(x: cursorX, y: cursorY),
                proposal: ProposedViewSize(size)
            )
            cursorX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
