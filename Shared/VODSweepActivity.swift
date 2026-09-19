import Combine
import Foundation
import SwiftUI

// MARK: - VOD sweep activity (Android parity, Logan 2026-09-16)
//
// Two questions the VOD catalog sweep and the tabs that display it keep
// asking, in one place so both halves can never disagree:
//
//   1. "Is a sweep running, or about to run, for this kind?"  The Movies and
//      TV Shows tabs must stay VISIBLE and show a loading state while their
//      catalog repopulates. Before this, a tab was hidden whenever its count
//      was 0, so "Refresh Everything" made the tab vanish and reappear (the
//      count drops to 0, then grows). Android never did that: an allowed (or
//      not yet probed) kind keeps its tab and shows that it is updating.
//      Only an explicitly DENIED kind hides the tab.
//
//   2. "Is the user looking at that tab right now?"  A sweep the user is
//      watching runs at full speed: no artificial pause between pages and a
//      small number of page requests in flight. Off screen it stays on the
//      quiet paced path so it never competes with playback. iPhone measured
//      about 30 pages/minute with the 500 ms pace; Android runs 200+ in the
//      foreground, and this is how the gap closes.
//
// Deliberately tiny and describable: Android is getting the same two flags.
// State lives on the main actor because both readers (the sweep, which runs
// on the @MainActor VODStore, and SwiftUI) are already there.
@MainActor
final class VODSweepActivity: ObservableObject {
    static let shared = VODSweepActivity()

    /// Never exceed this many page requests in flight against Dispatcharr.
    /// The server sends in bursts and answers 503 "stopping" when it wants
    /// to be left alone, so the foreground gain comes from removing the
    /// artificial pause, not from piling on connections.
    static let foregroundConcurrency = 3

    /// Pause between pages on the quiet (off screen) path. Same 500 ms the
    /// sweep loop used before this file existed.
    static let backgroundPageDelay: Duration = .milliseconds(500)

    /// Pause between pages while the GUIDE is the screen in front of the user
    /// (tvOS, 1.8.40 regression). The uncapped sweep walks for tens of
    /// minutes, and every page still costs the main actor a little: the lane
    /// bookkeeping, the count publish, the SQLite hand-off. At 500 ms those
    /// slices arrive twice a second under a screen whose whole job is to
    /// answer a remote press instantly, and the presses felt delayed.
    /// Tripling the pace off screen costs the background sweep time nobody is
    /// watching. A sweep the user IS watching (Movies / TV Shows in front) and
    /// a Saving Changes rebuild both stay on the fast foreground path.
    static let guidePageDelay: Duration = .milliseconds(1500)

    // MARK: Sweep state

    @Published private(set) var moviesRunning = false
    @Published private(set) var seriesRunning = false
    /// Scheduled but not yet started: the launch orchestrator runs the series
    /// sweep only after the movie sweep finishes, which can be a minute or
    /// more. Without "pending" the TV Shows tab would disappear for that
    /// whole window after a refresh.
    @Published private(set) var moviesPending = false
    @Published private(set) var seriesPending = false

    /// True while `kind` is sweeping or waiting its turn to sweep. This is
    /// the single expression the tab gate and the "Updating" badge read.
    func isActive(_ kind: VODItemType) -> Bool {
        kind == .series ? (seriesRunning || seriesPending) : (moviesRunning || moviesPending)
    }

    func isRunning(_ kind: VODItemType) -> Bool {
        kind == .series ? seriesRunning : moviesRunning
    }

    /// A sweep has been scheduled for these kinds but has not started.
    func markPending(_ kinds: [VODItemType]) {
        for kind in kinds {
            if kind == .series { if !seriesPending { seriesPending = true } }
            else { if !moviesPending { moviesPending = true } }
        }
    }

    /// The sweep loop for `kind` has begun.
    func markRunning(_ kind: VODItemType) {
        if kind == .series {
            if !seriesRunning { seriesRunning = true }
            if seriesPending { seriesPending = false }
        } else {
            if !moviesRunning { moviesRunning = true }
            if moviesPending { moviesPending = false }
        }
    }

    /// The sweep loop for `kind` has ended, by completion, error or cancel.
    func markIdle(_ kind: VODItemType) {
        if kind == .series {
            if seriesRunning { seriesRunning = false }
            if seriesPending { seriesPending = false }
        } else {
            if moviesRunning { moviesRunning = false }
            if moviesPending { moviesPending = false }
        }
    }

    /// Playlist cleared, server deleted, sweep task cancelled wholesale.
    func clearAll() {
        if moviesRunning { moviesRunning = false }
        if seriesRunning { seriesRunning = false }
        if moviesPending { moviesPending = false }
        if seriesPending { seriesPending = false }
    }

    // MARK: Screen presence

    // Plain stored state, NOT @Published: this flips on every tab switch and
    // nothing in the view tree should re-render because of it (the scroll
    // churn rule). Only the sweep loop reads it.
    private var moviesOnScreen = false
    private var seriesOnScreen = false
    /// Live TV (the guide) is the frontmost tab. Same plain-state rule as the
    /// two above: nothing re-renders because of it, only the sweep reads it.
    private var liveTVOnScreen = false

    /// Driven by the real on-screen state of the Movies / TV Shows views
    /// (their appear / disappear and tab selection), never guessed.
    func setOnScreen(_ kind: VODItemType, _ visible: Bool) {
        if kind == .series {
            guard seriesOnScreen != visible else { return }
            seriesOnScreen = visible
        } else {
            guard moviesOnScreen != visible else { return }
            moviesOnScreen = visible
        }
        debugLog("[VOD-CAT] on screen kind=\(kind == .series ? "series" : "movies") -> \(visible)")
    }

    /// True when the sweep for `kind` may run unpaced and concurrent: its own
    /// screen is in front of the user, so the growing count is visible and
    /// the wait is the thing being optimized.
    func isForeground(_ kind: VODItemType) -> Bool {
        kind == .series ? seriesOnScreen : moviesOnScreen
    }

    /// Driven by the frontmost tab, so the quiet sweep can get quieter still
    /// while the guide has the screen. See `guidePageDelay`.
    func setLiveTVOnScreen(_ visible: Bool) {
        guard liveTVOnScreen != visible else { return }
        liveTVOnScreen = visible
        debugLog("[VOD-CAT] on screen kind=livetv -> \(visible)")
    }

    /// How many page requests the sweep for `kind` may keep in flight.
    func pageConcurrency(for kind: VODItemType) -> Int {
        isForeground(kind) ? Self.foregroundConcurrency : 1
    }

    /// Pause the BACKGROUND sweep takes between pages of `kind`. Stretched
    /// while the guide is in front on tvOS; unchanged everywhere else, and
    /// never consulted on the foreground path.
    func backgroundPageDelay(for kind: VODItemType) -> Duration {
        #if os(tvOS)
        if liveTVOnScreen, !isForeground(kind) { return Self.guidePageDelay }
        #endif
        return Self.backgroundPageDelay
    }
}

// MARK: - Catalog facts the tab bar reads

/// The handful of BOOLEANS `MainTabView` needs about the VOD catalog, on their
/// own tiny observable.
///
/// `MainTabView` used to observe `VODStore` directly, which meant every
/// progressive count publish the sweep made (one integer, every 5 s, for as
/// long as an uncapped walk takes) invalidated `MainTabView.body` and with it
/// the Live TV subtree underneath it. That is the other half of the 1.8.40
/// guide navigation lag. The tab bar never wanted the counts: it wanted "is
/// there a Movies tab", which only moves on a real false -> true transition.
///
/// So the counts stay on `VODStore` for the screens that DISPLAY them (Movies,
/// TV Shows, Settings keep observing the detailed store) and `MainTabView`
/// observes this instead. Values are recomputed from both sources whenever
/// either announces a change and republished only when one actually differs,
/// so a sweep that adds 100 titles a page publishes nothing here.
@MainActor
final class VODCatalogFacts: ObservableObject {
    static let shared = VODCatalogFacts()

    /// The catalog half of the tab gate: titles stored, or a sweep in flight
    /// that will store some. The PERMISSION half stays in the view, which is
    /// where the active server lives.
    @Published private(set) var hasMovies = false
    @Published private(set) var hasSeries = false

    /// The background-work flags the "Syncing" indicator and the heartbeat log
    /// read. Booleans that flip a handful of times per sweep, not per page.
    @Published private(set) var isLoadingMovies = false
    @Published private(set) var isLoadingSeries = false
    @Published private(set) var isRefillingMovies = false
    @Published private(set) var isRefillingSeries = false
    @Published private(set) var isSearchingMovies = false
    @Published private(set) var isSearchingSeries = false

    private var cancellables: Set<AnyCancellable> = []
    private var recomputeQueued = false
    private var pull: (@MainActor () -> Void)?

    /// Wires the facts to their sources. Idempotent, and called from
    /// `MainTabView` rather than from `init` so neither singleton has to exist
    /// before the other.
    ///
    /// `objectWillChange` fires BEFORE the source's value is written, so the
    /// recompute is deferred one main-actor turn and coalesced: a burst of
    /// publishes costs one pass, and a pass that finds nothing changed
    /// publishes nothing.
    func start(recompute: @escaping @MainActor () -> Void,
               sources: [ObservableObjectPublisher]) {
        guard pull == nil else { return }
        pull = recompute
        for source in sources {
            source
                .sink { [weak self] _ in self?.scheduleRecompute() }
                .store(in: &cancellables)
        }
        recompute()
    }

    private func scheduleRecompute() {
        guard !recomputeQueued else { return }
        recomputeQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recomputeQueued = false
            self.pull?()
        }
    }

    /// Called by the recompute closure with everything read in one place.
    /// Every write is guarded: an equal-value `@Published` write still
    /// re-renders every observer, which is the whole thing this type exists to
    /// avoid.
    func apply(hasMovies: Bool, hasSeries: Bool,
               isLoadingMovies: Bool, isLoadingSeries: Bool,
               isRefillingMovies: Bool, isRefillingSeries: Bool,
               isSearchingMovies: Bool, isSearchingSeries: Bool) {
        if self.hasMovies != hasMovies { self.hasMovies = hasMovies }
        if self.hasSeries != hasSeries { self.hasSeries = hasSeries }
        if self.isLoadingMovies != isLoadingMovies { self.isLoadingMovies = isLoadingMovies }
        if self.isLoadingSeries != isLoadingSeries { self.isLoadingSeries = isLoadingSeries }
        if self.isRefillingMovies != isRefillingMovies { self.isRefillingMovies = isRefillingMovies }
        if self.isRefillingSeries != isRefillingSeries { self.isRefillingSeries = isRefillingSeries }
        if self.isSearchingMovies != isSearchingMovies { self.isSearchingMovies = isSearchingMovies }
        if self.isSearchingSeries != isSearchingSeries { self.isSearchingSeries = isSearchingSeries }
    }
}

// MARK: - "Updating" badge

/// The inline status the Movies and TV Shows screens show beside their
/// library count while the catalog is still growing. Same shape as the
/// "Searching server…" row those screens already carry: a small spinner and
/// tertiary text, nothing that competes with the content.
struct VODUpdatingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .tint(.accentPrimary)
                #if os(tvOS)
                .scaleEffect(0.7)
                #else
                .scaleEffect(0.6)
                #endif
            Text("Updating")
                .scaledFont(.labelMedium.subtext())
                .foregroundColor(Color.contrastText(.textTertiary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Updating library")
    }
}
