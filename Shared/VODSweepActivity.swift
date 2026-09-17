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

    /// How many page requests the sweep for `kind` may keep in flight.
    func pageConcurrency(for kind: VODItemType) -> Int {
        isForeground(kind) ? Self.foregroundConcurrency : 1
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
