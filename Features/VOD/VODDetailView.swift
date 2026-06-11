import SwiftUI
import SwiftData
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Series Detail Cache (v1.6.16.x)
//
// In-memory cache for VODSeries detail (seasons + episodes). Lives
// here because VODDetailView is the sole consumer; promoting it to a
// shared store wasn't worth the indirection.
//
// Why this exists: VODDetailView's `.task { await loadDetail() }` is
// auto-cancelled when the view leaves the hierarchy — fine in
// principle. In practice, three things cancel the task before the
// fetch completes:
//   1. iCloud sync arriving mid-fetch and bumping `servers.count`,
//      which re-renders RootView and rebuilds the navigation stack.
//   2. The user backing out and re-opening (impatience: the parallel
//      page fan-out for a 1000-episode series is still seconds of
//      work even on LAN).
//   3. The parent VOD list refilling per-category, mutating the
//      VODDisplayItem upstream.
// Any of those propagates a structured-concurrency cancellation into
// the URLSession data task, which surfaces as
// `NSURLErrorCancelled (-999)` and tanks the entire fetch. Pre-cache
// the user lived through this as "first open never loads, second
// open works in 5s" — the second-attempt working was Dispatcharr's
// server-side cache being warm from the cancelled-but-partially-
// completed first attempt.
//
// Solution: spawn the fetch via `Task.detached` so it survives view
// cancellation, then store the result in this static cache. The
// next time any VODDetailView mounts for the same seriesID, the
// cache hit returns instantly. `inFlightTasks` de-dupes concurrent
// requests for the same id (e.g., user double-taps the series row).
@MainActor
private enum SeriesDetailCache {
    /// Successfully-fetched series details, keyed by series id.
    /// Lives for the app's lifetime — fine because the data is
    /// small (a series of N episodes is ~N small structs) and
    /// there's no scenario where stale episode data is meaningfully
    /// wrong (the user can pull-to-refresh or restart the app).
    static var entries: [String: VODSeries] = [:]

    /// In-flight detached fetches, keyed by series id. A second
    /// caller for the same id awaits the first's result instead of
    /// kicking off a parallel duplicate fetch.
    static var inFlightTasks: [String: Task<VODSeries?, Never>] = [:]

    /// Returns cached series detail if present; otherwise spawns a
    /// detached fetch (or joins one already in flight), waits for
    /// it, caches + returns the result. The detached fetch is NOT
    /// cancelled when the view that called this method goes away —
    /// it runs to completion in the background and populates the
    /// cache regardless. The view's await on the result MAY return
    /// early if the view's own `.task` is cancelled, but the cache
    /// will be populated by the time the next view mount checks.
    static func loadIfNeeded(seriesID: String,
                              server: ServerSnapshot,
                              existing: VODSeries?) async -> VODSeries? {
        if let cached = entries[seriesID] {
            #if DEBUG
            debugLog("[VOD-Series-Cache] HIT id=\(seriesID) seasons=\(cached.seasons.count) episodes=\(cached.seasons.reduce(0) { $0 + $1.episodes.count })")
            #endif
            return cached
        }
        if let existingTask = inFlightTasks[seriesID] {
            debugLog("[VOD-Series-Cache] JOIN in-flight id=\(seriesID)")
            return await existingTask.value
        }
        debugLog("[VOD-Series-Cache] MISS — spawning detached fetch id=\(seriesID)")
        // v1.6.16.x: register-before-detach. Pre-fix the assignment
        // `inFlightTasks[id] = task` happened AFTER `Task.detached`,
        // which on a warm cache could complete in <1ms — fast
        // enough that the closure's `inFlightTasks.removeValue`
        // ran before the assignment, leaving a stale completed
        // task permanently in the dict. Net result: small memory
        // leak per series visit. Fixed by capturing the task
        // reference in a holder, registering the holder
        // synchronously, then attaching the detached work.
        // Cleanup compares against the captured holder so a fresh
        // re-entrant fetch (rare but possible if the detached
        // task hasn't finished yet) doesn't accidentally clear
        // the new in-flight registration.
        let task = Task<VODSeries?, Never>.detached {
            do {
                let result = try await VODService.fetchSeriesDetail(seriesID: seriesID,
                                                                     from: server,
                                                                     existing: existing)
                await MainActor.run {
                    // Only clear OUR own in-flight registration.
                    if SeriesDetailCache.inFlightTasks[seriesID] != nil {
                        SeriesDetailCache.inFlightTasks.removeValue(forKey: seriesID)
                    }
                    if let result, !result.seasons.isEmpty {
                        // v1.6.16.x: only cache results that actually
                        // have episode data. Pre-fix this branch
                        // accepted empty results (seasons=0), which
                        // permanently locked the user out of ever
                        // loading episodes for a series whose first
                        // fetch returned empty (Dispatcharr
                        // intermittent state, account-filter mismatch,
                        // etc.) — the next mount would short-circuit
                        // on the cache hit and never re-query. Empty
                        // responses now bypass the cache entirely so
                        // every fresh open re-tries the network.
                        SeriesDetailCache.entries[seriesID] = result
                        #if DEBUG
                        debugLog("[VOD-Series-Cache] STORED id=\(seriesID) seasons=\(result.seasons.count) episodes=\(result.seasons.reduce(0) { $0 + $1.episodes.count })")
                        #endif
                    } else if result != nil {
                        debugLog("[VOD-Series-Cache] NOT storing empty result id=\(seriesID) seasons=0 — next open will re-fetch")
                    } else {
                        debugLog("[VOD-Series-Cache] detached fetch returned nil id=\(seriesID)")
                    }
                }
                return result
            } catch {
                await MainActor.run {
                    SeriesDetailCache.inFlightTasks.removeValue(forKey: seriesID)
                    debugLog("[VOD-Series-Cache] detached fetch FAILED id=\(seriesID) error=\(error)")
                }
                return nil
            }
        }
        inFlightTasks[seriesID] = task
        return await task.value
    }
}

// MARK: - Movie Detail Cache (v1.6.16.x)
//
// Same shape as `SeriesDetailCache` above, ported because the
// movie path has the same view-cancellation exposure: iCloud sync
// churn, ancestor re-renders, and back-out + reopen all cancel
// the view's `.task`, which propagates structured-concurrency
// cancellation into the URLSession data task and aborts the
// `provider-info` fetch. Failure mode for movies was milder than
// series (the slim list-time preview kept rendering, just without
// rich plot/cast/director/backdrop) but the user still paid the
// scrape cost on every re-open. With this cache, every successful
// fetch makes subsequent opens instant for the rest of the app
// session.
@MainActor
private enum MovieDetailCache {
    static var entries: [String: VODMovie] = [:]
    static var inFlightTasks: [String: Task<VODMovie?, Never>] = [:]

    static func loadIfNeeded(existing: VODMovie,
                              server: ServerSnapshot) async -> VODMovie? {
        let movieID = existing.id
        if let cached = entries[movieID] {
            debugLog("[VOD-Movie-Cache] HIT id=\(movieID)")
            return cached
        }
        if let existingTask = inFlightTasks[movieID] {
            debugLog("[VOD-Movie-Cache] JOIN in-flight id=\(movieID)")
            return await existingTask.value
        }
        debugLog("[VOD-Movie-Cache] MISS — spawning detached fetch id=\(movieID)")
        // See `SeriesDetailCache.loadIfNeeded` for the
        // register-before-cleanup ordering rationale. Same shape
        // here for symmetry.
        let task = Task<VODMovie?, Never>.detached {
            let result = await VODService.fetchMovieDetail(existing: existing, from: server)
            await MainActor.run {
                if MovieDetailCache.inFlightTasks[movieID] != nil {
                    MovieDetailCache.inFlightTasks.removeValue(forKey: movieID)
                }
                // `fetchMovieDetail` returns the existing movie
                // unchanged on failure; cache only when we got a
                // genuinely-richer object back so a transient
                // failure doesn't lock the user out of getting
                // enriched data on the next open.
                if result != existing {
                    MovieDetailCache.entries[movieID] = result
                    debugLog("[VOD-Movie-Cache] STORED id=\(movieID)")
                } else {
                    debugLog("[VOD-Movie-Cache] NOT storing — fetch returned existing unchanged id=\(movieID)")
                }
            }
            return result
        }
        inFlightTasks[movieID] = task
        return await task.value
    }
}

// MARK: - VOD Detail View (Movie or Series)
#if os(tvOS)
/// Clears any leftover `additionalSafeAreaInsets` on the active window's
/// root controller. The VOD player is presented as a full-screen cover
/// whose `ignoresSafeArea` content can leave the root with a negative or
/// collapsed top inset on tvOS, which pulls the tab bar up into the
/// overscan and stays stuck until the app is relaunched. Resetting it
/// forces the true title-safe inset to be re-read on the next layout pass.
@MainActor
private func aerioRestoreRootSafeAreaInsets() {
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows {
            guard let root = window.rootViewController else { continue }
            if root.additionalSafeAreaInsets != .zero {
                root.additionalSafeAreaInsets = .zero
            }
            root.view.setNeedsLayout()
        }
    }
}
#endif

struct VODDetailView: View {
    let item: VODDisplayItem
    @Query private var servers: [ServerConnection]
    /// Every episode-typed `WatchProgress` row. Filtered in memory by
    /// `seriesID == item.id` inside `progressByEpisodeID`. v1.6.8:
    /// drives the "Currently Watching" / "Watched" pill on each
    /// episode row so users arriving at the series detail page (for
    /// example from a tvOS Top Shelf deep-link after cross-device
    /// sync) can see at a glance which episode they were in the
    /// middle of. SwiftData `#Predicate` can capture primitives from
    /// the surrounding scope, but binding `seriesID` at query-init
    /// time would require a custom `init` just to reassign
    /// `_watchProgress`; the episode-count fits comfortably in
    /// memory so we take the simpler filter-on-read path.
    @Query(filter: #Predicate<WatchProgress> { $0.vodType == "episode" })
    private var allEpisodeProgress: [WatchProgress]
    @Environment(\.dismiss) private var dismiss

    @State private var fullMovie: VODMovie?
    @State private var fullSeries: VODSeries?
    /// TMDB poster fallback when the provider gave this VOD item no
    /// artwork (opt-in; Settings > App Behaviors > Program Posters).
    @State private var tmdbPosterURL: URL?
    /// True once the TMDB lookup has run to completion (hit or miss), so
    /// the source note can tell "still searching" from "searched, none".
    @State private var tmdbLookupDone = false
    /// TMDB text-metadata backfill (Android parity): fetched once per
    /// screen entry when the server AND provider-info leave any of
    /// plot/genre/cast/director blank. Server values always win; TMDB
    /// only fills the holes, so fully-described libraries never hit TMDB.
    @State private var tmdbDetails: TMDBDetails?
    /// Structured credits driving the Cast & Crew photo strip. NOT gated
    /// on missing metadata: servers only ever send comma-separated name
    /// strings, so headshots always need TMDB. Nil when the opt-in or
    /// key is absent, and the strip simply does not render.
    @State private var tmdbCredits: TMDBCredits?
    /// Non-nil presents the person bio sheet.
    @State private var bioPerson: TMDBPerson?
    /// Non-nil pushes that title's detail (Known For deep-link). A plain
    /// push, so Back returns to THIS title with the bio sheet closed.
    @State private var knownForPush: VODDisplayItem?
    #if os(tvOS)
    /// Drives the top tab bar's visibility from this detail's scroll
    /// position so it reappears when the user scrolls back to the top
    /// (a pushed tvOS detail otherwise hides it, leaving the Menu
    /// button as the only way back up to it).
    @State private var detailScrolledToTop = true
    #endif
    @State private var selectedSeason: Int = 0
    @State private var playingURL: IdentifiableURL?
    @State private var playingTitle = ""
    @State private var playingHeaders: [String: String] = [:]
    @State private var playingVodID: String = ""       // movie.id or episode.id depending on context
    @State private var playingVodType: String = "movie" // "movie" or "episode"
    @State private var playingPosterURL: String?       // episode poster overrides series poster when playing an episode
    @State private var isLoadingDetail = false
    @State private var isResolvingURL = false
    @Binding var isPlaying: Bool

    private var server: ServerConnection? {
        servers.first { $0.id == item.serverID }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                // v1.6.12: explicit `.frame(maxWidth: .infinity, alignment: .leading)`
                // on this outer VStack clamps the column to the
                // ScrollView's content width. Without it, an
                // `.frame(maxWidth: .infinity)` on a deeper child
                // (e.g. metaRow's value Text) propagates up through
                // the leading-aligned VStack and bleeds the layout
                // past the safe-area's leading edge — which clipped
                // the first letter off every plot/genre/cast line
                // in the v1.6.12 enrichment work.
                VStack(alignment: .leading, spacing: 0) {
                    heroSection
                    infoSection
                    castCrewSection
                    if item.type == .series {
                        episodeSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(tvOS)
            // Reveal the top tab bar while the header (hero + plot +
            // cast + season selector) is in view; hide it once the user
            // scrolls down into the episode list. Lets the user reach
            // the tab bar again by scrolling back up, without the Menu
            // button (a pushed detail otherwise hides it). tvOS scrolls
            // by focus, not free inertia, so "scroll to the top" of a
            // series lands on the first focusable header element with
            // the non-focusable hero still off-screen (~500pt offset).
            // The threshold sits above that whole header band so the
            // bar returns as soon as the user climbs back out of the
            // episode list, then stays hidden deeper in the list.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y < 600
            } action: { _, headerVisible in
                if detailScrolledToTop != headerVisible { detailScrolledToTop = headerVisible }
            }
            #endif
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        #if os(tvOS)
        .toolbar(detailScrolledToTop ? .visible : .hidden, for: .tabBar)
        #endif
        .task {
            await loadDetail()
            // Provider-info has settled once loadDetail() returns (the
            // task is sequential), satisfying the backfill's settled gate.
            await loadTMDBDetailsIfNeeded()
            await loadTMDBCreditsIfNeeded()
            await loadTMDBPosterIfNeeded()
        }
        .sheet(item: $bioPerson) { person in
            PersonBioSheet(person: person, resolve: resolveKnownFor)
        }
        .navigationDestination(item: $knownForPush) { pushed in
            VODDetailView(item: pushed, isPlaying: $isPlaying)
        }
        .fullScreenCover(item: $playingURL) { wrapper in
            PlayerView(
                urls: [wrapper.url],
                title: playingTitle,
                headers: playingHeaders,
                isLive: false,
                artworkURL: (playingPosterURL.flatMap { URL(string: $0) }) ?? item.posterURL,
                vodID: playingVodID,
                vodPosterURL: playingPosterURL ?? item.posterURL?.absoluteString,
                vodServerID: item.serverID.uuidString,
                vodType: playingVodType
            )
            .onDisappear {
                isPlaying = false
                #if os(tvOS)
                // Restore the root safe area the full-screen cover can
                // collapse on tvOS, otherwise the tab bar leaks off the
                // top of the screen until the app is relaunched.
                DispatchQueue.main.async { aerioRestoreRootSafeAreaInsets() }
                #endif
            }
        }
    }

    // MARK: - Hero
    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop or poster as hero.
            //
            // v1.6.12: wrapped in `GeometryReader` so the image's
            // frame is **explicitly** clamped to the container's
            // proposed width. The previous chain
            // (`.aspectRatio(contentMode: .fill).frame(maxWidth: .infinity).frame(height: 280)`)
            // looked correct on a poster image (~0.67 aspect → 187pt
            // wide at 280pt tall, fits the screen) but the moment the
            // backdrop image loaded (~1.78 aspect → 498pt wide at
            // 280pt tall), `.aspectRatio(.fill)` reported that 498pt
            // as the view's preferred width. `.frame(maxWidth: .infinity)`
            // accepts up to infinity, so the frame became 498pt —
            // **wider than the iPhone viewport**. The parent VStack
            // adopted 498pt, and SwiftUI's positioning of a too-wide
            // leading-aligned frame inside a narrower ScrollView
            // viewport bled the entire infoSection past the safe-
            // area's leading edge, clipping the first letter of every
            // text row. Forcing `.frame(width: geo.size.width, …)`
            // here fully detaches the image's natural aspect from the
            // parent's width math: the frame is exactly the proposed
            // width, the `.aspectRatio(.fill)` content scales to
            // fill (overflowing internally), and `.clipped()` trims
            // the overflow. No upward width propagation, hero looks
            // identical, layout stays inside the safe area.
            let heroURL = (fullMovie?.backdropURL ?? fullSeries?.backdropURL) ?? item.posterURL ?? tmdbPosterURL
            GeometryReader { geo in
                AuthPosterImage(url: heroURL, headers: serverHeaders())
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: 280)
                    .clipped()
            }
            .frame(height: 280)
            .overlay(LinearGradient.heroOverlay)

            HStack(alignment: .bottom, spacing: 14) {
                // Small poster thumbnail
                AuthPosterImage(url: item.posterURL ?? tmdbPosterURL, headers: serverHeaders())
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.headlineLarge)
                        .foregroundColor(.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        // v1.6.12: prefer the full-detail year/rating
                        // when we have it (Dispatcharr now populates
                        // VODMovie.releaseDate and rating from
                        // custom_properties), falling back to the
                        // grid-time `item` snapshot for backwards
                        // compatibility with Xtream payloads.
                        let detailYear = (fullMovie?.releaseYear ?? fullSeries?.releaseYear) ?? ""
                        let serverYear = detailYear.isEmpty ? item.releaseYear : detailYear
                        // TMDB backfill is LAST in the chain: server wins.
                        let displayYear = serverYear.isEmpty ? (tmdbDetails?.year ?? "") : serverYear
                        if !displayYear.isEmpty {
                            Text(displayYear)
                                .font(.labelSmall).foregroundColor(.textSecondary)
                        }
                        // Rating, server-wins per the parity spec: the
                        // provider-info merged rating first, then the grid-row
                        // snapshot. A server "0"/"0.0" means unrated and is
                        // dropped; it would otherwise render a starred zero AND
                        // block the TMDB vote backfill (common on Xtream list
                        // payloads). TMDB's vote average is last in the chain
                        // (its own 0.0 was already dropped at parse).
                        let infoRating = (fullMovie?.rating ?? fullSeries?.rating) ?? ""
                        let rawServerRating = (infoRating.isEmpty ? item.rating : infoRating)
                            .trimmingCharacters(in: .whitespaces)
                        let serverRating = (rawServerRating == "0" || rawServerRating == "0.0") ? "" : rawServerRating
                        let displayRating = serverRating.isEmpty ? (tmdbDetails?.voteAverage ?? "") : serverRating
                        if !displayRating.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.statusWarning)
                                Text(displayRating)
                                    .font(.labelSmall).foregroundColor(.textSecondary)
                            }
                        }
                        // v1.6.12: runtime when known (movies only —
                        // series carry per-episode durations on the
                        // episode rows, not at the show level).
                        if let movie = fullMovie, !movie.duration.isEmpty {
                            Text(movie.duration)
                                .font(.labelSmall).foregroundColor(.textSecondary)
                        }
                        if item.type == .movie {
                            Text("MOVIE")
                                .font(.labelSmall).foregroundColor(.textTertiary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.elevatedBackground)
                                .clipShape(Capsule())
                        }
                    }

                    if item.type == .movie, let movie = fullMovie ?? item.movie {
                        playButton(url: movie.streamURL, title: movie.name)
                    }
                }
            }
            .padding(16)
        }
        // Android parity P2 (behavior only): tvOS scrolls by focus and the
        // hero held no focusable, so once the user descended into the
        // episode list the title/rating/poster band was unreachable (focus
        // climbing back up stopped at the first header control ~500pt
        // below the hero). A plain focus stop on the band gives D-pad Up a
        // landing spot, and the focus engine scrolls the hero back into
        // view natively. No action on select; it is a read-only stop.
        // SERIES ONLY: movies never had the gap (their Play button lives
        // inside the hero) and nesting a focusable container around an
        // already-focusable child invites focus-engine surprises.
        #if os(tvOS)
        .focusable(item.type == .series)
        #endif
    }

    // MARK: - Info
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Server-wins merge per field: provider value first, TMDB
            // backfill only when the server left the field blank.
            let serverPlot = fullMovie?.plot ?? fullSeries?.plot ?? ""
            let plot = serverPlot.isEmpty ? (tmdbDetails?.overview ?? "") : serverPlot
            if !plot.isEmpty {
                Text(plot)
                    .font(.bodyMedium)
                    .foregroundColor(.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // v1.6.12: external-link row. Surfaces the YouTube
            // trailer + a "View on TMDB" link when the underlying
            // VODMovie carries those identifiers (Dispatcharr's
            // /provider-info/ populates them; series don't have
            // either today). Hidden entirely on tvOS — the system
            // has no browser, and there's no in-app trailer player
            // yet, so the buttons would be no-ops on Apple TV.
            #if os(tvOS)
            tvOSTrailerQR
            tvOSTMDBQR
            #else
            externalLinks
            #endif

            let serverGenre = fullMovie?.genre ?? fullSeries?.genre ?? ""
            let genre = serverGenre.isEmpty ? (tmdbDetails?.genres ?? "") : serverGenre
            if !genre.isEmpty {
                metaRow(label: "Genre", value: genre)
            }
            // v0.26.0 reliably populates release_date from basic sync.
            // The hero already shows the year, so only surface the full
            // date here when it carries more than the year (e.g. a
            // month/day). Pure-year values are skipped as redundant.
            let released = fullMovie?.releaseDate ?? fullSeries?.releaseDate ?? ""
            if released.count > 4 {
                metaRow(label: "Released", value: released)
            }
            // The classic Cast/Director text rows are suppressed while the
            // Cast & Crew photo strip renders (it carries the same names
            // with headshots); they remain as the fallback when TMDB
            // enrichment is off or returned nothing.
            if castCrewPeople.isEmpty {
                let serverCast = fullMovie?.cast ?? fullSeries?.cast ?? ""
                let cast = serverCast.isEmpty ? (tmdbDetails?.castTop ?? "") : serverCast
                if !cast.isEmpty {
                    metaRow(label: "Cast", value: cast)
                }
                let serverDirector = fullMovie?.director ?? fullSeries?.director ?? ""
                let director = serverDirector.isEmpty ? (tmdbDetails?.director ?? "") : serverDirector
                if !director.isEmpty {
                    metaRow(label: "Director", value: director)
                }
            }
            let country = fullMovie?.country ?? fullSeries?.country ?? ""
            if !country.isEmpty {
                metaRow(label: "Country", value: country)
            }

            tmdbSourceNote
        }
        // v1.6.12 (third pass): clamp infoSection to fill width
        // BEFORE padding so the .padding(.horizontal, 16) carves
        // 16pt margins out of the screen-wide column. Earlier
        // iterations applied `.padding(16)` to a VStack that was
        // sizing to its natural content width — the padding was
        // applied but produced an outer frame narrower than the
        // screen, then the parent leading-aligned VStack pinned
        // that narrow frame to x=0 of the screen, putting the
        // content at x=padding (which looks correct in isolation
        // but visually presents as a narrower column hugging the
        // left edge with no breathing room from the safe area).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - TMDB source note
    //
    // Surfaces the opt-in TMDB poster fallback to the user (and doubles
    // as a verification aid): confirms when the artwork came from TMDB,
    // and turns an art-less item into a CTA to add a key. Shared by iOS
    // and tvOS, so it shows on both. Only the poster is sourced from
    // TMDB today; provider-supplied metadata is unchanged.
    @ViewBuilder
    private var tmdbSourceNote: some View {
        if tmdbPosterURL != nil && tmdbDetails != nil {
            tmdbNoteRow(
                icon: "checkmark.seal.fill",
                tint: .accentPrimary,
                text: "Poster and missing details pulled from TMDB using your API key."
            )
        } else if tmdbPosterURL != nil {
            // The poster shown above was supplied by TMDB.
            tmdbNoteRow(
                icon: "checkmark.seal.fill",
                tint: .accentPrimary,
                text: "Poster pulled from TMDB using your API key."
            )
        } else if tmdbDetails != nil {
            // Server artwork is present but TMDB filled in blank text
            // fields (plot/genre/cast/director/year/rating).
            tmdbNoteRow(
                icon: "checkmark.seal.fill",
                tint: .accentPrimary,
                text: "Missing details filled in from TMDB using your API key."
            )
        } else if item.posterURL == nil {
            if !TMDBPosters.isEnabled || TMDBPosters.apiKey == nil {
                // No provider artwork and no TMDB key supplied yet.
                tmdbNoteRow(
                    icon: "sparkles",
                    tint: .accentPrimary,
                    text: "No artwork from your provider. Enter a TMDB API key in Settings > App Behaviors to fill it in automatically. Only works when TMDB has a matching title."
                )
            } else if tmdbLookupDone {
                // Key supplied and TMDB was queried, but nothing matched.
                tmdbNoteRow(
                    icon: "magnifyingglass",
                    tint: .textTertiary,
                    text: "No matching title found on TMDB."
                )
            }
        }
    }

    @ViewBuilder
    private func tmdbNoteRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.labelSmall)
                .foregroundColor(tint)
            Text(text)
                .font(.labelSmall)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - External links (Trailer + TMDB)

    /// Horizontal row of pill-shaped links opening the YouTube
    /// trailer and the TMDB movie/TV page in Safari. Hidden when
    /// neither identifier is present so the row doesn't stake out
    /// vertical space for two empty columns. iOS-only — see
    /// `infoSection` for the platform gate rationale.
    ///
    /// v1.6.12: now reads from `fullSeries` as a fallback so series
    /// detail pages get the same treatment as movies. The TMDB URL
    /// branches on `item.type` because TMDB uses `/movie/<id>` for
    /// films and `/tv/<id>` for shows — same `tmdb_id` namespace,
    /// different web path.
    #if !os(tvOS)
    @ViewBuilder
    private var externalLinks: some View {
        let rawTrailer = fullMovie?.youtubeTrailer
            ?? fullSeries?.youtubeTrailer
            ?? ""
        let rawTmdbID = fullMovie?.tmdbID
            ?? fullSeries?.tmdbID
            ?? ""
        let trailerURL = trailerURL(from: rawTrailer)
        let tmdbURL    = tmdbURL(from: rawTmdbID, type: item.type)

        if trailerURL != nil || tmdbURL != nil {
            HStack(spacing: 10) {
                if let url = trailerURL {
                    Link(destination: url) {
                        externalLinkLabel(icon: "play.rectangle.fill",
                                          text: "Trailer")
                    }
                }
                if let url = tmdbURL {
                    Link(destination: url) {
                        externalLinkLabel(icon: "info.circle.fill",
                                          text: "View on TMDB")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Pill-styled label for the external-link row — keeps the
    /// `Trailer` and `View on TMDB` chips visually consistent and
    /// centralises the styling so future links (IMDB, etc.) drop
    /// in with one extra `Link { externalLinkLabel(...) }` call.
    private func externalLinkLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.labelMedium)
        }
        .foregroundStyle(Color.accentPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(Color.elevatedBackground)
        )
    }

    #endif

    /// Compose the TMDB page URL for a VOD item. `tmdbID` is the
    /// bare numeric ID Dispatcharr stores. TMDB uses different web
    /// paths for films vs. shows (`themoviedb.org/movie/<id>` and
    /// `themoviedb.org/tv/<id>`) even though both share a single
    /// numeric namespace, so we branch on `VODItemType`. Episodes
    /// fall back to the show's path; there's no per-episode TMDB
    /// page, and currently the episode rows aren't surfacing the
    /// link anyway. Cross-platform: iOS uses it for the Link pill,
    /// tvOS for the View on TMDB QR.
    private func tmdbURL(from id: String, type: VODItemType) -> URL? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pathSegment: String = {
            switch type {
            case .movie:           return "movie"
            case .series, .episode: return "tv"
            }
        }()
        return URL(string: "https://www.themoviedb.org/\(pathSegment)/\(trimmed)")
    }

    /// Build a YouTube watch URL from whatever shape Dispatcharr stores
    /// `youtube_trailer` in. Most providers send just the 11-char video
    /// key (`dQw4w9WgXcQ`), but a stray full URL or `youtu.be/<key>`
    /// shows up occasionally — handle both rather than producing a
    /// malformed URL. Cross-platform: tvOS uses it for the QR code.
    private func trailerURL(from raw: String) -> URL? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if key.hasPrefix("http://") || key.hasPrefix("https://") {
            return URL(string: key)
        }
        if key.hasPrefix("youtu.be/") {
            return URL(string: "https://" + key)
        }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }

    #if os(tvOS)
    // MARK: - tvOS trailer QR

    /// Apple TV has no browser and the YouTube tvOS app exposes no
    /// working deep link, so a trailer can't be opened on-device. We
    /// render the YouTube watch URL as a QR code the user scans with
    /// their phone (where the iOS YouTube universal link opens the
    /// video). ToS-safe and version-proof.
    @ViewBuilder
    private var tvOSTrailerQR: some View {
        let rawTrailer = fullMovie?.youtubeTrailer ?? fullSeries?.youtubeTrailer ?? ""
        if let url = trailerURL(from: rawTrailer),
           let qr = Self.qrCodeImage(from: url.absoluteString) {
            HStack(alignment: .center, spacing: 24) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                    )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill")
                        Text("Trailer").font(.headlineSmall)
                    }
                    .foregroundStyle(Color.accentPrimary)
                    Text("Scan with your phone to watch the trailer on YouTube.")
                        .font(.bodyMedium)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// "View on TMDB" as a scannable QR (Android parity P2): the iOS
    /// phone build shows a tappable Link pill, but tvOS compiled the whole
    /// externalLinks row out, silently dropping the TMDB link on TV. Same
    /// card styling as the trailer QR above.
    @ViewBuilder
    private var tvOSTMDBQR: some View {
        let rawID = fullMovie?.tmdbID ?? fullSeries?.tmdbID
            ?? item.movie?.tmdbID ?? item.series?.tmdbID ?? ""
        if !rawID.isEmpty,
           let url = tmdbURL(from: rawID, type: item.type),
           let qr = Self.qrCodeImage(from: url.absoluteString) {
            HStack(alignment: .center, spacing: 24) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                    )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                        Text("View on TMDB").font(.headlineSmall)
                    }
                    .foregroundStyle(Color.accentPrimary)
                    Text("Scan with your phone to view this title on TMDB.")
                        .font(.bodyMedium)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Render a string as a QR-code image via CoreImage, scaled up with
    /// a nearest-neighbor transform so the modules stay crisp. Returns
    /// nil if generation fails. fileprivate so PersonBioSheet's person QR
    /// reuses the same generator.
    fileprivate static func qrCodeImage(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // Error correction H (parity spec): a phone camera reads a TV
        // screen at an angle through living-room lighting.
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    #endif

    // MARK: - Episodes
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoadingDetail {
                HStack { Spacer(); ProgressView().tint(.accentPrimary); Spacer() }
                    .padding(32)
            } else if let series = fullSeries, !series.seasons.isEmpty {
                // Season picker
                if series.seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(series.seasons.enumerated()), id: \.offset) { idx, season in
                                Button {
                                    withAnimation(.spring(response: 0.25)) { selectedSeason = idx }
                                } label: {
                                    Text("Season \(season.seasonNumber)")
                                        .font(.labelMedium)
                                        .foregroundColor(selectedSeason == idx ? .appBackground : .textSecondary)
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(
                                            selectedSeason == idx
                                                ? AnyView(Capsule().fill(Color.accentPrimary))
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

                // Episode list
                if selectedSeason < series.seasons.count {
                    let episodes = series.seasons[selectedSeason].episodes
                    ForEach(episodes) { ep in
                        episodeRow(ep)
                    }
                }
            }
        }
        .padding(.bottom, 32)
    }

    private func episodeRow(_ ep: VODEpisode) -> some View {
        TVEpisodeRowButton(
            ep: ep,
            headers: serverHeaders(),
            progress: progressByEpisodeID[ep.id]
        ) {
            playEpisode(ep)
        }
    }

    /// Lookup from `episode.id` → `WatchProgress` for episodes of
    /// this series. Only populated for series detail pages; a movie
    /// item never returns any rows because `allEpisodeProgress` is
    /// already filtered to `vodType == "episode"` and movies don't
    /// have a matching `seriesID`.
    private var progressByEpisodeID: [String: WatchProgress] {
        guard item.type == .series else { return [:] }
        let seriesID = item.id
        var map: [String: WatchProgress] = [:]
        for wp in allEpisodeProgress where wp.seriesID == seriesID {
            map[wp.vodID] = wp
        }
        return map
    }

    // MARK: - Helpers

    private func playButton(url: URL?, title: String) -> some View {
        TVPlayButton(isResolvingURL: isResolvingURL) {
            guard let url, !isResolvingURL else { return }
            Task { await resolveAndLaunch(url: url, title: title) }
        }
    }

    private func playEpisode(_ ep: VODEpisode) {
        guard let url = ep.streamURL else { return }
        // Stash the parent series ID into WatchProgress before playback starts.
        // The Top Shelf extension uses this to build a deep link that
        // navigates back to the series detail. The episode itself doesn't
        // have a standalone detail view to return to.
        // v1.6.8 (Codex A1): pass serverID through too so resume positions
        // don't collide across servers that share an episode ID.
        // v1.7.3 (Issue #19): also capture the rest of the series as an
        // "up next" queue so Continue Watching advances to the next
        // episode when this one finishes, with no later series fetch.
        WatchProgressManager.save(
            vodID: ep.id,
            title: ep.title,
            positionMs: 0,
            durationMs: 0,
            posterURL: ep.posterURL?.absoluteString,
            vodType: "episode",
            serverID: ep.serverID.uuidString,
            seriesID: ep.seriesID,
            seasonNumber: ep.seasonNumber,
            episodeNumber: ep.episodeNumber,
            upNextQueue: upNextQueueJSON(after: ep)
        )
        Task {
            await resolveAndLaunch(
                url: url,
                title: ep.title,
                vodID: ep.id,               // episode's own unique ID
                vodType: "episode",
                posterURL: ep.posterURL?.absoluteString
            )
        }
    }

    /// v1.7.3 (Issue #19): flatten the loaded series into the episodes
    /// that come after `ep` (rest of the season, then later seasons),
    /// capped to a sane lookahead, encoded as a JSON `[UpNextEntry]` for
    /// `WatchProgress.upNextQueue`. Returns nil when the series isn't
    /// loaded or `ep` is the final episode.
    private func upNextQueueJSON(after ep: VODEpisode) -> String? {
        guard let series = fullSeries else { return nil }
        let ordered = series.seasons
            .sorted { $0.seasonNumber < $1.seasonNumber }
            .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
        guard let idx = ordered.firstIndex(where: { $0.id == ep.id }),
              idx + 1 < ordered.count else { return nil }
        let tail = ordered[(idx + 1)...].prefix(50).map {
            UpNextEntry(vodID: $0.id, title: $0.title,
                        posterURL: $0.posterURL?.absoluteString,
                        streamURL: $0.streamURL?.absoluteString,
                        seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber)
        }
        guard !tail.isEmpty,
              let data = try? JSONEncoder().encode(Array(tail)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Resolves any redirects in the proxy URL with auth headers before handing off to the player.
    /// Dispatcharr's /proxy/vod/* endpoints often redirect to a session-based or provider URL.
    /// The player follows redirects but can drop custom headers; resolving first avoids that.
    @MainActor
    private func resolveAndLaunch(url: URL, title: String, vodID: String? = nil,
                                  vodType: String = "movie", posterURL: String? = nil) async {
        playingTitle = title
        playingHeaders = serverHeaders()
        playingVodID = vodID ?? item.id  // default to movie id
        playingVodType = vodType
        playingPosterURL = posterURL

        var resolvedURL = url
        if let server, server.type == .dispatcharrAPI {
            isResolvingURL = true
            let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                     auth: .apiKey(server.effectiveApiKey),
                                     userAgent: server.effectiveUserAgent,
                                     authMode: server.dispatcharrHeaderMode)
            resolvedURL = (try? await api.resolveFinalURLForPlayback(url)) ?? url
            isResolvingURL = false
        }

        // v1.6.18 — tear down any active live stream before mounting
        // the VOD/episode fullScreenCover. The MainTabView-level
        // player overlay persists across tab navigation (so a
        // minimized live channel keeps playing while the user is
        // in On Demand), and fullScreenCover layers on top WITHOUT
        // unmounting underneath. Without this stop() call, the
        // live mpv keeps decoding audio while the VOD mpv also
        // produces audio — two simultaneous streams. Same root
        // cause as the recording-playback fix in MyRecordingsView
        // (v1.6.18 user report from NicolaiVdS, Apple TV).
        //
        // v1.6.23 — `NowPlayingManager.stop()` only clears
        // single-stream state (`playingItem`, `isMinimized`); when the
        // active session is `.multiview`, the `MultiviewStore` tiles
        // and their mpv coordinators stay mounted under the VOD
        // fullScreenCover, decode in the background, and contend with
        // the VOD on the GPU (jesmannstl, v1.6.23: live tile=666 KRCG
        // kept producing frames for 3+ minutes after VOD started, plus
        // visible VOD black-screen flickers). Route through
        // `PlayerSession.shared.exit()` instead — that resets the tile
        // store, flips `mode = .idle`, tears down `NowPlayingBridge`,
        // and also calls `NowPlayingManager.shared.stop()` at the end
        // so the single-stream case is still handled. Safe in
        // single-stream mode: the multiview-specific branches inside
        // `exit()` are guarded by `if let audioID = store.audioTileID`.
        PlayerSession.shared.exit()
        playingURL = IdentifiableURL(url: resolvedURL)
        isPlaying = true
    }

    private func serverHeaders() -> [String: String] {
        guard let server else { return [:] }
        return server.authHeaders
    }

    private func metaRow(label: String, value: String) -> some View {
        // v1.6.12 (second pass): the previous fix used
        // `.frame(maxWidth: .infinity, alignment: .leading)` on the
        // value Text, which was the layout-cascade trigger — that
        // modifier propagates "ideal width = infinity" up through the
        // HStack → VStack → infoSection chain, and SwiftUI's eventual
        // clamp lands at a position that bleeds the leading edge past
        // the safe area. Solution: drop the maxWidth-infinity hint
        // entirely and rely on `.fixedSize(horizontal: false, vertical: true)`,
        // which lets the value Text accept whatever horizontal space
        // the HStack offers (no cascade) while still allowing it to
        // grow vertically for multi-line wrapping. Long cast lists
        // wrap correctly without any width hint upstream.
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.labelSmall).foregroundColor(.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.labelSmall).foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// When the provider supplied no poster, fall back to TMDB (opt-in).
    /// Prefers an exact tmdb_id lookup, else searches by title. Runs
    /// after loadDetail so any detail-fetched tmdb_id is available.
    @MainActor
    private func loadTMDBPosterIfNeeded() async {
        guard item.posterURL == nil, tmdbPosterURL == nil,
              TMDBPosters.isEnabled, let apiKey = TMDBPosters.apiKey else { return }
        let isMovie = (item.type != .series)
        let tmdbID = item.movie?.tmdbID ?? item.series?.tmdbID
            ?? fullMovie?.tmdbID ?? fullSeries?.tmdbID
        var url: URL?
        if let id = tmdbID, !id.isEmpty {
            url = await TMDBService.posterURL(forTMDBID: id, isMovie: isMovie, apiKey: apiKey)
        }
        if url == nil, !item.name.isEmpty {
            url = await TMDBService.posterURL(forTitle: item.name, apiKey: apiKey)
        }
        if let url { tmdbPosterURL = url }
        tmdbLookupDone = true
    }

    /// TMDB text-metadata backfill (Android parity, dossier Part 1
    /// section 2). Fires once per screen entry, only when the opt-in is
    /// on, a key exists, AND at least one of plot/genre/cast/director is
    /// still blank after the server's own enrichment settled (the caller
    /// awaits loadDetail() first). Exact tmdb_id wins; title search
    /// rescues stale or absent provider ids. Country is never backfilled.
    private func loadTMDBDetailsIfNeeded() async {
        // Episode-typed items (reachable via global Search) have no
        // movie/series payload; a title search with an episode display
        // name risks matching the wrong show entirely.
        guard item.type == .movie || item.type == .series else { return }
        guard tmdbDetails == nil,
              TMDBPosters.isEnabled,
              let apiKey = TMDBPosters.apiKey else { return }
        let plot = fullMovie?.plot ?? fullSeries?.plot ?? ""
        let genre = fullMovie?.genre ?? fullSeries?.genre ?? ""
        let cast = fullMovie?.cast ?? fullSeries?.cast ?? ""
        let director = fullMovie?.director ?? fullSeries?.director ?? ""
        let missingMeta = plot.isEmpty || genre.isEmpty || cast.isEmpty || director.isEmpty
        guard missingMeta else { return }

        let isMovie = item.type == .movie
        // fullMovie/fullSeries already merged provider-info over the list
        // row (provider wins), so prefer their id, then the raw row's.
        let tmdbID = [fullMovie?.tmdbID, fullSeries?.tmdbID,
                      item.movie?.tmdbID, item.series?.tmdbID]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        if let id = tmdbID,
           let details = await TMDBService.details(forTMDBID: id, isMovie: isMovie, apiKey: apiKey) {
            tmdbDetails = details
            return
        }
        guard !item.name.isEmpty else { return }
        tmdbDetails = await TMDBService.details(forTitle: item.name, isMovie: isMovie, apiKey: apiKey)
    }

    /// Structured credits for the Cast & Crew strip. Same settled gate as
    /// the details backfill (runs after loadDetail()), same once-per-entry
    /// behavior, but NO missing-metadata condition: server text strings
    /// can never supply headshots.
    private func loadTMDBCreditsIfNeeded() async {
        // Same episode guard as the details backfill above.
        guard item.type == .movie || item.type == .series else { return }
        guard tmdbCredits == nil,
              TMDBPosters.isEnabled,
              let apiKey = TMDBPosters.apiKey else { return }
        let isMovie = item.type == .movie
        let tmdbID = [fullMovie?.tmdbID, fullSeries?.tmdbID,
                      item.movie?.tmdbID, item.series?.tmdbID]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        if let id = tmdbID,
           let credits = await TMDBService.credits(forTMDBID: id, isMovie: isMovie, apiKey: apiKey) {
            tmdbCredits = credits
            return
        }
        guard !item.name.isEmpty else { return }
        tmdbCredits = await TMDBService.credits(forTitle: item.name, isMovie: isMovie, apiKey: apiKey)
    }

    /// Combined people list for the strip: cast first, then directors,
    /// deduped by person id, so an actor-director appears once with their
    /// character name.
    private var castCrewPeople: [TMDBPerson] {
        guard let credits = tmdbCredits else { return [] }
        var seen = Set<String>()
        return (credits.cast + credits.directors).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Cast & Crew strip
    @ViewBuilder
    private var castCrewSection: some View {
        if !castCrewPeople.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast & Crew")
                    .font(.headlineSmall)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(castCrewPeople) { person in
                            PersonCard(person: person) { bioPerson = person }
                        }
                    }
                    .padding(.horizontal, 16)
                    // Headroom for the tvOS focus scale so the focused
                    // card's ring is not clipped by the scroll view.
                    .padding(.vertical, 12)
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// Resolve a Known For tile against the user's library and push the
    /// match. Returns false when the title is not in the library (the
    /// sheet shows the miss message). On success the sheet is dismissed
    /// first so remote Back from the pushed title returns here with the
    /// sheet closed.
    private func resolveKnownFor(_ kf: TMDBKnownForItem) async -> Bool {
        guard let hit = await VODStore.shared.resolveKnownForItem(kf, server: server) else {
            return false
        }
        bioPerson = nil
        // Let the sheet dismissal settle before pushing, so the navigation
        // transition does not race the modal teardown.
        try? await Task.sleep(for: .milliseconds(350))
        knownForPush = hit
        return true
    }

    private func loadDetail() async {
        guard let server else { return }

        switch item.type {
        case .movie:
            // Two-phase render: show the slim list-time data
            // immediately, then upgrade fields when the rich
            // `/provider-info/` payload returns. Dispatcharr's
            // provider-info endpoint is server-side throttled to
            // 24h per movie, but the FIRST call for a movie that
            // hasn't been visited yet synchronously triggers an
            // upstream Xtream fetch (`refresh_movie_advanced_data`),
            // which can take several seconds. By rendering
            // `item.movie` first we keep the initial frame instant
            // and let SwiftUI animate the new fields in when they
            // arrive.
            //
            // v1.6.16.x: route through `MovieDetailCache` so the
            // detached fetch survives view cancellation (iCloud
            // sync, back-out + reopen, ancestor re-render) and
            // subsequent opens hit the cache instantly. Same
            // pattern as `SeriesDetailCache`, ported for parity.
            fullMovie = item.movie
            if let existing = item.movie {
                // Cache fast-path
                if let cached = MovieDetailCache.entries[existing.id] {
                    fullMovie = cached
                    debugLog("[VOD-Movie] view path used cache id=\(existing.id)")
                    return
                }
                let snap = server.snapshot
                if let enriched = await MovieDetailCache.loadIfNeeded(existing: existing, server: snap),
                   enriched != existing {
                    fullMovie = enriched
                }
            }
        case .series:
            guard fullSeries == nil else { return }
            // v1.6.12: render the slim list-time series instantly so
            // the user sees the basics (poster, title, year, plot,
            // genre) without waiting for the network. The detail
            // fetch then enriches with cast/director/backdrop/
            // trailer/TMDB-id, mirroring the movie two-phase render.
            //
            // v1.6.16: ALWAYS flip `isLoadingDetail` to true while
            // the series-detail fetch is in flight, even if the
            // list-time preview is present. The preview only carries
            // metadata (poster, title, plot) — NO seasons / episodes.
            // Pre-1.6.16 the episode section silently rendered empty
            // while the fetch was running, which on Dispatcharr +
            // large series (One Piece, etc.) left the user staring
            // at an empty list for minutes with no spinner. The
            // workaround was "open the series, back out, open it
            // again" because the second open used Dispatcharr's
            // warm server-side cache. Now the section shows a
            // ProgressView until seasons populate, regardless of
            // preview state, so the user has clear feedback that
            // episodes are loading.
            // v1.6.16.x: route through `SeriesDetailCache` so the
            // network fetch survives this view's lifecycle. The
            // detached task spawned inside `loadIfNeeded` continues
            // running even when SwiftUI cancels our `.task` on the
            // user backing out, an iCloud-sync server-list refresh,
            // or any other ancestor re-render. On a re-mount the
            // cache hit returns the result instantly.
            //
            // Render the slim preview first so the hero / metadata
            // are visible while the episode fetch is in flight.
            if let preview = item.series, fullSeries == nil {
                fullSeries = preview
            }
            // Cache fast-path: if we've already fetched this series
            // in a previous mount of this view (or a sibling),
            // skip the spinner and go straight to seasons.
            if let cached = SeriesDetailCache.entries[item.id] {
                fullSeries = cached
                if let idx = cached.seasons.indices.first {
                    selectedSeason = idx
                }
                debugLog("[VOD-Series] view path used cache id=\(item.id) seasons=\(cached.seasons.count)")
                return
            }
            isLoadingDetail = true
            let snap = server.snapshot
            let fetchStart = Date()
            debugLog("[VOD-Series] fetchStart id=\(item.id) name=\(item.name) hasPreview=\(item.series != nil)")
            let enriched = await SeriesDetailCache.loadIfNeeded(seriesID: item.id,
                                                                 server: snap,
                                                                 existing: item.series)
            // The view's `.task` may have been cancelled while we
            // were awaiting the detached fetch. If so, the writes
            // below are no-ops (the @State storage is destroyed),
            // and the cache will be populated by the detached task
            // anyway — the next view mount picks up the fast path.
            let elapsedMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
            if let enriched {
                fullSeries = enriched
                debugLog("[VOD-Series] fetchOK id=\(item.id) elapsed=\(elapsedMs)ms seasons=\(enriched.seasons.count) episodes=\(enriched.seasons.reduce(0) { $0 + $1.episodes.count })")
            } else {
                debugLog("[VOD-Series] fetchNIL id=\(item.id) elapsed=\(elapsedMs)ms — fullSeries stays at preview (seasons=\(fullSeries?.seasons.count ?? 0))")
            }
            isLoadingDetail = false
            if let idx = fullSeries?.seasons.indices.first {
                selectedSeason = idx
            }
        case .episode:
            break
        }
    }
}

// MARK: - Episode Row with tvOS Focus

/// Extracted into its own view so it can own a @FocusState for per-row focus highlighting.
private struct TVEpisodeRowButton: View {
    let ep: VODEpisode
    let headers: [String: String]
    /// Optional resume/watched state. v1.6.8: lets the row surface a
    /// "Currently Watching" / "Watched" pill badge so users arriving
    /// at a series detail page (especially from a Top Shelf
    /// deep-link after cross-device sync) can see at a glance which
    /// episode they're in the middle of without scrubbing the list.
    let progress: WatchProgress?
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AuthPosterImage(url: ep.posterURL, headers: headers)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("E\(ep.episodeNumber) · \(ep.title)")
                        .font(.bodyMedium).foregroundColor(.textPrimary)
                        .lineLimit(1)
                    // v1.6.16.x: metadata strip — duration · air date ·
                    // rating. Mirrors what Dispatcharr's web UI shows
                    // in its episode rows (Duration / Date columns)
                    // plus the per-episode TMDB rating which is
                    // valuable on tvOS where users browse with the
                    // Siri Remote and can't easily scrub plots.
                    // Each piece is independently optional — empty
                    // ones are skipped, separators only render
                    // between non-empty pieces, so a sparse row
                    // (e.g. only duration set) doesn't show a
                    // dangling " · " divider.
                    let pieces: [String] = [
                        ep.duration,
                        ep.displayAirDate,
                        ep.displayRating.isEmpty ? "" : "★ \(ep.displayRating)"
                    ].filter { !$0.isEmpty }
                    if !pieces.isEmpty {
                        Text(pieces.joined(separator: " · "))
                            .font(.labelSmall)
                            .foregroundColor(.textSecondary.opacity(0.85))
                            .lineLimit(1)
                    }
                    if !ep.plot.isEmpty {
                        Text(ep.plot)
                            .font(.labelSmall).foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                    // Progress pill + timeline — only rendered when
                    // there's a WatchProgress row for this episode.
                    // Finished episodes get a muted "Watched" chip
                    // (no timeline — the pill itself communicates
                    // completion); in-progress episodes get the
                    // accent "Currently Watching" chip plus a thin
                    // accent-tinted progress bar + percentage so
                    // users can tell how far in they were without
                    // resuming. Sizes are platform-specific —
                    // v1.6.8 feedback bumped the tvOS font +
                    // padding 50% larger for 10-foot readability.
                    if let progress {
                        #if os(tvOS)
                        let iconSize: CGFloat = 15
                        let textSize: CGFloat = 17
                        let hPadding: CGFloat = 12
                        let vPadding: CGFloat = 5
                        let barMaxWidth: CGFloat = 360
                        let barHeight: CGFloat = 5
                        let pctTextSize: CGFloat = 15
                        #else
                        let iconSize: CGFloat = 10
                        let textSize: CGFloat = 11
                        let hPadding: CGFloat = 8
                        let vPadding: CGFloat = 3
                        let barMaxWidth: CGFloat = 240
                        let barHeight: CGFloat = 3
                        let pctTextSize: CGFloat = 10
                        #endif

                        HStack(spacing: 4) {
                            Image(systemName: progress.isFinished
                                  ? "checkmark.circle.fill"
                                  : "play.circle.fill")
                                .font(.system(size: iconSize, weight: .semibold))
                            Text(progress.isFinished ? "Watched" : "Currently Watching")
                                .font(.system(size: textSize, weight: .semibold))
                        }
                        .foregroundColor(progress.isFinished ? .textSecondary : .white)
                        .padding(.horizontal, hPadding)
                        .padding(.vertical, vPadding)
                        .background(
                            Capsule().fill(progress.isFinished
                                           ? Color.elevatedBackground
                                           : Color.accentPrimary)
                        )

                        // Linear timeline. Shown only for in-progress
                        // episodes with a usable duration — some
                        // episode rows persist with `durationMs == 0`
                        // because playback was stopped before mpv
                        // reported a duration, and rendering a 0-based
                        // percentage would lie to the user.
                        if !progress.isFinished, progress.durationMs > 0 {
                            let pct = max(0.0, min(1.0,
                                Double(progress.positionMs) / Double(progress.durationMs)))
                            HStack(spacing: 8) {
                                ProgressView(value: pct)
                                    .progressViewStyle(.linear)
                                    .tint(.accentPrimary)
                                    .frame(maxWidth: barMaxWidth)
                                    .scaleEffect(x: 1.0, y: barHeight / 3.0, anchor: .center)
                                Text("\(Int(pct * 100))%")
                                    .font(.system(size: pctTextSize, weight: .semibold))
                                    .foregroundColor(.textSecondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentPrimary.opacity(0.7))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            #if os(tvOS)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.elevatedBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary : .clear, lineWidth: 3)
            )
            .shadow(color: isFocused ? Color.accentPrimary.opacity(0.45) : .clear,
                    radius: isFocused ? 16 : 0, y: 4)
            .scaleEffect(isFocused ? 1.045 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            #endif
        }
        #if os(tvOS)
        // Row draws its own focus highlight above, so suppress the
        // button style's ring to avoid a second nested rectangle.
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .focused($isFocused)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Play Button with tvOS Focus

/// Extracted so it can own a @FocusState for clear focus highlighting on the Play CTA.
private struct TVPlayButton: View {
    let isResolvingURL: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isResolvingURL {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(isResolvingURL ? "Loading…" : "Play")
            }
            .font(.headlineSmall)
            .foregroundColor(.white)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(LinearGradient.accentGradient)
            .clipShape(Capsule())
            #if os(tvOS)
            .overlay(
                Capsule()
                    .stroke(isFocused ? Color.white : .clear, lineWidth: 2.5)
            )
            .shadow(color: isFocused ? Color.accentPrimary.opacity(0.6) : .clear, radius: 10, y: 4)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            #endif
        }
        #if os(tvOS)
        // Play CTA draws its own capsule focus highlight above, so
        // suppress the button style's ring to avoid a nested rectangle.
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .focused($isFocused)
        #else
        .buttonStyle(.plain)
        #endif
        .disabled(isResolvingURL)
    }
}

// MARK: - Identifiable URL wrapper (avoids global retroactive conformance on URL)
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Cast & Crew person card

/// One headshot card in the Cast & Crew strip. tvOS sizes are roughly
/// double the Android dp values (the Android TV design canvas is 960x540dp
/// against tvOS's 1920x1080pt).
private struct PersonCard: View {
    let person: TMDBPerson
    let onSelect: () -> Void

    #if os(tvOS)
    private let cardWidth: CGFloat = 180
    #else
    private let cardWidth: CGFloat = 90
    #endif

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.elevatedBackground.opacity(0.55))
                    if let url = TMDBService.profileImageURL(path: person.profilePath, size: "w185") {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                personGlyph
                            }
                        }
                    } else {
                        personGlyph
                    }
                }
                .frame(width: cardWidth, height: cardWidth * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(person.name)
                    .font(.labelMedium)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let role = person.role {
                    Text(role)
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }

    private var personGlyph: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 32))
            .foregroundColor(.textTertiary)
    }
}

// MARK: - Person bio sheet

/// TMDB person biography sheet (Android parity: PersonBioDialog). Opens
/// from a Cast & Crew card; the fetch is lazy (fired on present) so
/// browsing the strip costs nothing until a card is picked. The header
/// name and headshot show immediately from the tapped TMDBPerson while
/// the bio loads. The Close button stays pinned below the scrolling body
/// so long biographies never push it off-screen for remote users.
private struct PersonBioSheet: View {
    let person: TMDBPerson
    /// Parent-supplied Known For resolver: returns false when the title
    /// is not in the user's library (the sheet shows the miss message);
    /// on success the parent dismisses this sheet and pushes the title.
    let resolve: (TMDBKnownForItem) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bio: TMDBPersonBio?
    @State private var loaded = false
    /// Double-fire latch: a Known For resolve can hit the network; a
    /// second press while one is in flight would stack two pushes.
    @State private var resolving = false
    @State private var missText: String?

    #if os(tvOS)
    private let headshotWidth: CGFloat = 260
    private let tileWidth: CGFloat = 170
    #else
    private let headshotWidth: CGFloat = 140
    private let tileWidth: CGFloat = 96
    #endif

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 20) {
                        headshot
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bio?.name ?? person.name)
                                .font(.headlineLarge)
                                .foregroundColor(.textPrimary)
                            lifeLine(label: "Born", value: bio?.birthday, isDate: true)
                            lifeLine(label: "Died", value: bio?.deathday, isDate: true)
                            lifeLine(label: "Birthplace", value: bio?.placeOfBirth, isDate: false)
                            Spacer().frame(height: 10)
                            if !loaded {
                                ProgressView()
                            } else if let text = bio?.biography {
                                Text(text)
                                    .font(.bodyMedium)
                                    .foregroundColor(.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("No biography available.")
                                    .font(.bodyMedium)
                                    .foregroundColor(.textTertiary)
                            }
                            // iOS half of the person TMDB-page surface (the
                            // tvOS half is the corner QR): a tappable link to
                            // the full filmography.
                            #if !os(tvOS)
                            if let personURL = URL(string: "https://www.themoviedb.org/person/\(person.id)") {
                                Link(destination: personURL) {
                                    Label("View on TMDB", systemImage: "arrow.up.right.square")
                                        .font(.labelMedium)
                                        .foregroundColor(.accentPrimary)
                                }
                                .padding(.top, 8)
                            }
                            #endif
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if os(tvOS)
                        personQR
                        #endif
                    }
                    knownForStrip
                }
                .padding(24)
            }

            HStack(spacing: 16) {
                if let missText {
                    Text(missText)
                        .font(.labelMedium)
                        .foregroundColor(.statusWarning)
                        .transition(.opacity)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .task(id: person.id) {
            guard TMDBPosters.isEnabled, let key = TMDBPosters.apiKey else {
                loaded = true
                return
            }
            bio = await TMDBService.personBio(forID: person.id, apiKey: key)
            loaded = true
        }
    }

    private var headshot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.elevatedBackground.opacity(0.55))
            // w342: the sheet photo renders about 2x the strip card; the
            // w185 thumb would upscale soft on a TV.
            if let url = TMDBService.profileImageURL(path: bio?.profilePath ?? person.profilePath, size: "w342") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.textTertiary)
                    }
                }
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.textTertiary)
            }
        }
        .frame(width: headshotWidth, height: headshotWidth * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func lifeLine(label: String, value: String?, isDate: Bool) -> some View {
        if let value, !value.isEmpty {
            Text("\(label): \(isDate ? Self.formatBioDate(value) : value)")
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
                .padding(.top, 4)
        }
    }

    /// TMDB dates arrive as yyyy-MM-dd; show the locale MEDIUM style with
    /// the raw string as the parse-failure fallback.
    private static func formatBioDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private var knownForStrip: some View {
        if let items = bio?.knownFor, !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Known For")
                    .font(.headlineSmall)
                    .foregroundColor(.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            knownForTile(item)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func knownForTile(_ item: TMDBKnownForItem) -> some View {
        Button {
            tapKnownFor(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.elevatedBackground.opacity(0.55))
                    if let url = TMDBService.profileImageURL(path: item.posterPath, size: "w185") {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "film")
                                    .font(.system(size: 28))
                                    .foregroundColor(.textTertiary)
                            }
                        }
                    }
                }
                .frame(width: tileWidth, height: tileWidth * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(item.title)
                    .font(.labelMedium)
                    .foregroundColor(.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: tileWidth, alignment: .leading)
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }

    private func tapKnownFor(_ item: TMDBKnownForItem) {
        guard !resolving else { return }
        resolving = true
        Task { @MainActor in
            let found = await resolve(item)
            if !found {
                withAnimation { missText = "Not in your library." }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { missText = nil }
            }
            resolving = false
        }
    }

    #if os(tvOS)
    /// Mini person QR in the sheet's corner: Apple TV has no browser, so
    /// the user scans with a phone to open the full filmography on TMDB.
    @ViewBuilder
    private var personQR: some View {
        if let qr = VODDetailView.qrCodeImage(from: "https://www.themoviedb.org/person/\(person.id)") {
            VStack(spacing: 4) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 120, height: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white)
                    )
                Text("View on TMDB")
                    .font(.labelSmall)
                    .foregroundColor(.textSecondary)
            }
        }
    }
    #endif
}

// MARK: - Known For library deep-link resolution

extension VODStore {
    /// Strip ONE trailing "(YYYY)" and lowercase; keeps a year-only title
    /// intact (mirrors TMDBService.splitTitleYear).
    fileprivate static func normalizeVodTitle(_ raw: String) -> String {
        TMDBService.splitTitleYear(raw).title.lowercased()
    }

    fileprivate func storedTMDBID(of item: VODDisplayItem) -> String? {
        let id = item.movie?.tmdbID ?? item.series?.tmdbID ?? ""
        return id.isEmpty ? nil : id
    }

    /// Resolve a Known For tile to an item in the user's library
    /// (Android parity, dossier Part 1 section 6).
    ///
    /// Matching order: loaded lists (browse + server-search results)
    /// first, with a STRICT tmdb-id match; an entity that carries a
    /// tmdb id can ONLY match by that id (this stops a remake with the
    /// same name hijacking the match), so the normalized-title fallback
    /// applies to id-less rows only. When both miss on a Dispatcharr
    /// source, a one-shot server search runs and the hit is merged into
    /// the browse list BEFORE returning, so the pushed detail screen can
    /// resolve its own item. XC sources load their whole library up
    /// front, making a loaded-list miss a real miss: the server fallback
    /// is skipped there.
    @MainActor
    func resolveKnownForItem(_ kf: TMDBKnownForItem, server: ServerConnection?) async -> VODDisplayItem? {
        let loaded = kf.isMovie ? movies + movieSearchResults : series + seriesSearchResults
        if let hit = loaded.first(where: { storedTMDBID(of: $0) == kf.id }) { return hit }
        let wanted = Self.normalizeVodTitle(kf.title)
        if let hit = loaded.first(where: {
            storedTMDBID(of: $0) == nil && Self.normalizeVodTitle($0.name) == wanted
        }) { return hit }

        guard let server, server.type == .dispatcharrAPI, server.supportsVOD else { return nil }
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        let baseURL = server.effectiveBaseURL
        let sID = server.id

        var rows: [VODDisplayItem] = []
        do {
            if kf.isMovie {
                // The query is the tile's exact display title, so the
                // first page is plenty.
                for try await batch in api.searchVODMoviesStream(query: kf.title) {
                    rows = batch.map { makeSearchMovieItem($0, api: api, baseURL: baseURL, serverID: sID) }
                    break
                }
            } else {
                for try await batch in api.searchVODSeriesStream(query: kf.title) {
                    rows = batch.map { makeSearchSeriesItem($0, baseURL: baseURL, serverID: sID) }
                    break
                }
            }
        } catch {
            // Any fetch failure is treated identically to not-in-library.
            return nil
        }

        // Within server results: strict tmdb-id first, then normalized
        // title (no id-blank precondition here).
        let hit = rows.first(where: { storedTMDBID(of: $0) == kf.id })
            ?? rows.first(where: { Self.normalizeVodTitle($0.name) == wanted })
        if let hit { mergeKnownForHit(hit) }
        return hit
    }
}
