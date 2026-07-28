import SwiftUI

#if os(tvOS)

/// Hold-Up "Recently Watched" overlay (Remote Control initiative, Logan spec
/// 2026-07-20) — the tvOS port of Android's `RecentChannelsOverlay.kt`.
///
/// Shows the recents LRU (`RecentChannelsStore.shared.resolved`, already
/// most-recent-first and capped at 25) as a focusable list over the live
/// picture. OK tunes the highlighted channel (`onTune`); Back dismisses
/// (`onDismiss`, via `.onExitCommand`). While this overlay is up the gesture
/// executor routes Up/Down into the list instead of channel-flipping, so the
/// D-pad walks the rows.
///
/// Left-anchored panel with a horizontal scrim that fades to clear on the
/// right so the video keeps showing behind it, mirroring the common live-TV
/// convention of a channel surface sliding in from the left. The scrim is a
/// deliberately fixed black gradient (not a theme token): it sits directly on
/// live video, where a light-theme ground would be wrong.
///
/// Row rendering (logo / number / name / now-playing line / Watching badge)
/// is delegated to `ChannelPickRow`, the shared row defined by
/// `ChannelListOverlay.swift`; this file never redefines it.
struct RecentChannelsOverlay: View {

    /// Tune the chosen channel. The host wires this to its live-tune path
    /// (e.g. `NowPlayingManager.shared.startPlaying(...)`) and is expected to
    /// dismiss the overlay as part of tuning.
    private let onTune: (ChannelDisplayItem) -> Void

    /// Dismiss without tuning (hardware Back / Menu).
    private let onDismiss: () -> Void

    /// Live LRU. `resolved` is most-recent-first and already capped at the
    /// store's max (25); observing keeps the list and the Watching badge in
    /// step if anything mutates while the overlay is briefly up.
    @ObservedObject private var recents = RecentChannelsStore.shared

    /// For the "Watching" mark on whichever channel is currently on screen.
    @ObservedObject private var nowPlaying = NowPlayingManager.shared

    /// Drives initial focus. This overlay is placed in a ZStack over the
    /// player (not presented as a cover), so the focus engine won't auto-land
    /// on a row for us — we seed it on appear.
    @FocusState private var focusedID: String?

    init(onTune: @escaping (ChannelDisplayItem) -> Void,
         onDismiss: @escaping () -> Void) {
        self.onTune = onTune
        self.onDismiss = onDismiss
    }

    /// Snapshot of the recents, defensively re-capped at 25.
    private var entries: [ChannelDisplayItem] {
        Array(recents.resolved.prefix(25))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Left scrim → clear on the right so live video shows behind.
            // Fixed black (not a theme token) because it grounds text on top
            // of video, not on an app surface. Never intercepts focus/taps.
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.88), location: 0.0),
                    .init(color: Color.black.opacity(0.55), location: 0.42),
                    .init(color: Color.clear, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 20) {
                Text("Recently Watched")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.textPrimary)

                if entries.isEmpty {
                    Text("Channels you watch will show up here.")
                        .font(.system(size: 24))
                        .foregroundColor(.textSecondary)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { channel in
                                ChannelPickRow(
                                    item: channel,
                                    isPlaying: channel.id == nowPlaying.playingItem?.id,
                                    onSelect: { onTune(channel) }
                                )
                                .focused($focusedID, equals: channel.id)
                            }
                        }
                        .padding(.trailing, 12)
                    }
                    .focusSection()
                }
            }
            .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 64)
            .padding(.vertical, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hardware Back / Menu closes the overlay.
        .onExitCommand(perform: onDismiss)
        // Land focus on the first (most-recent) row once it exists. The tiny
        // delay lets the LazyVStack rows materialize before we address one,
        // matching the established tvOS overlay pattern in this codebase.
        .onAppear {
            guard let firstID = entries.first?.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if focusedID == nil { focusedID = firstID }
            }
        }
    }
}

#endif
