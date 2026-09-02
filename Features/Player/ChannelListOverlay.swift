import SwiftUI

#if os(tvOS)

// MARK: - Player "Channels" Left-overlay (tvOS)
//
// Ported from the Android `feature/player/ChannelListOverlay.kt` (Remote
// Control initiative / Apple GH #54, Logan spec 2026-07-20): a Left-press on
// the live player opens the channels of the previously-selected group as a
// focusable list over the live picture. A second Left slides in the shared
// docked `GroupSidebarPanel` (defined in `GroupSidebar.swift`) so the user can
// switch groups; Right or Back from the sidebar steps back to the list. OK on
// a row tunes. Back closes the sidebar first, then (with the list showing)
// dismisses the overlay.
//
// Group selection here is OVERLAY-LOCAL: it seeds from the guide's active
// group on open but never mutates the guide filter — browsing channels while
// watching must not silently re-filter the Live TV guide behind the player.
//
// Whole file is tvOS-only: it contributes nothing to the iOS build.

// MARK: - ChannelPickRow (SHARED)

/// A single focusable channel row for the player's Left overlays. THIS FILE
/// OWNS this type — the Recently-Watched overlay (`RecentChannelsOverlay`)
/// reuses it verbatim and must NOT redefine it.
///
/// Renders the channel logo, number, name, a now-airing line, a catch-up
/// affordance, and a "Watching" badge when the row is the channel currently on
/// screen. Focus is owned entirely by an `@Environment(\.isFocused)` button
/// style that draws a squared accent platter (see
/// `feedback_tvos_focus_squared_platter`: own the highlight, never the system
/// glow), matching the app's `TVNoRingButtonStyle` convention and the guide's
/// `ChannelRow` card look.
struct ChannelPickRow: View {
    let item: ChannelDisplayItem
    var isPlaying: Bool
    let onSelect: () -> Void

    /// Observe the shared guide store so the now-airing line fills in as EPG
    /// data lands, mirroring `ChannelRow.liveProgram`'s behaviour.
    @ObservedObject private var guideStore = GuideStore.shared

    /// Honor the same visibility prefs the Live TV rows use so the overlay
    /// stays visually consistent with the guide/list.
    @AppStorage("ui.showChannelLogos") private var showChannelLogos = true
    @AppStorage("ui.showChannelNumbers") private var showChannelNumbers = true

    init(item: ChannelDisplayItem, isPlaying: Bool = false, onSelect: @escaping () -> Void) {
        self.item = item
        self.isPlaying = isPlaying
        self.onSelect = onSelect
    }

    /// Title of the currently-airing programme: prefer the lightweight
    /// per-item payload, fall back to GuideStore's now-live entry. Nil when
    /// neither source has anything (the now-line slot then stays empty — no
    /// group-name fallback, matching `ChannelRow`).
    private var nowTitle: String? {
        if let t = item.currentProgram, !t.isEmpty { return t }
        if let live = guideStore.programs[item.id]?.first(where: { $0.isLive }),
           !live.title.isEmpty {
            return live.title
        }
        return nil
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                if showChannelNumbers {
                    Text(item.number)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.textTertiary)
                        .frame(width: 56, alignment: .trailing)
                        .lineLimit(1)
                }

                if showChannelLogos {
                    CachedLogoImage(url: item.logoURL, width: 68, height: 44)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        // Catch-up affordance (all-platform parity): history
                        // clock beside the name when the channel archives a
                        // replayable window.
                        if item.hasCatchup {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.textTertiary)
                        }
                    }

                    if let now = nowTitle {
                        Text(now)
                            .font(.system(size: 19))
                            .foregroundColor(.accentPrimary.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if isPlaying { watchingBadge }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChannelPickRowButtonStyle())
    }

    /// "Watching" pill — accent fill with app-background ink, matching the
    /// selected group-pill treatment used across Live TV.
    private var watchingBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .bold))
            Text("Watching")
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundColor(.appBackground)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.accentPrimary))
    }
}

// MARK: - Row focus style (squared platter, no system highlight)

/// Owns the focus visual entirely through `@Environment(\.isFocused)` so tvOS's
/// system focus platter is suppressed: focus draws an accent-tinted rounded
/// platter + inset accent border. Unfocused rows are transparent so the live
/// picture shows through the overlay's left scrim.
private struct ChannelPickRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.accentPrimary.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentPrimary : Color.clear, lineWidth: 3)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - ChannelListOverlay

/// The player's Left-press "Channels" overlay. Presented by the player host
/// over the live picture; the host owns the outer Back (see `onDismiss`).
struct ChannelListOverlay: View {
    let channels: [ChannelDisplayItem]
    let activeGroupToken: String
    let allGroups: [String]
    let onTune: (ChannelDisplayItem) -> Void
    let onDismiss: () -> Void

    /// Overlay-local group selection, seeded from the guide's active group.
    /// Changing this NEVER touches the guide's own `selectedGroup`.
    @State private var activeGroup: String
    /// Whether the leading group sidebar pane is showing.
    @State private var sidebarOpen = false
    @FocusState private var focusedRowID: String?

    /// Mark the row the user is currently watching so it shows the "Watching"
    /// badge. Read from the shared now-playing manager (no id is passed in).
    @ObservedObject private var nowPlaying = NowPlayingManager.shared

    init(channels: [ChannelDisplayItem],
         activeGroupToken: String,
         allGroups: [String],
         onTune: @escaping (ChannelDisplayItem) -> Void,
         onDismiss: @escaping () -> Void) {
        self.channels = channels
        self.activeGroupToken = activeGroupToken
        self.allGroups = allGroups
        self.onTune = onTune
        self.onDismiss = onDismiss
        _activeGroup = State(initialValue: activeGroupToken)
    }

    /// Groups offered by the sidebar. The sidebar renders the "All" sentinel as
    /// "All Channels", so guarantee it is present even if the host omitted it.
    private var sidebarGroups: [String] {
        allGroups.contains("All") ? allGroups : ["All"] + allGroups
    }

    /// The active group's channels, filtered overlay-locally from the seeded
    /// `channels`. "All" shows everything; any other token filters by group.
    private var entries: [ChannelDisplayItem] {
        guard activeGroup != "All" else { return channels }
        return channels.filter { $0.group == activeGroup }
    }

    private var playingID: String? { nowPlaying.playingItem?.id }

    var body: some View {
        ZStack(alignment: .leading) {
            // Left-weighted scrim so the live picture stays visible on the
            // right while the list reads cleanly on the left.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.92), location: 0.0),
                    .init(color: .black.opacity(0.55), location: 0.45),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 24) {
                if sidebarOpen {
                    GroupSidebarPanel(
                        groups: sidebarGroups,
                        selectedToken: activeGroup,
                        onSelect: { token in
                            // Overlay-local: re-filter to the picked group and
                            // return to the list. The guide filter is untouched.
                            activeGroup = token
                            sidebarOpen = false
                        },
                        // Back/Menu inside the rail closes the WHOLE overlay
                        // (Logan 2026-08-06: Right steps out one layer at a
                        // time; Back always exits fully).
                        onDismiss: { onDismiss() }
                    )
                    // The panel itself doesn't handle Right (only the guide
                    // pane does); add it here so Right steps back out of the
                    // rail to the channel list, matching GuideGroupSidebarPane.
                    .onMoveCommand { direction in
                        if direction == .right { sidebarOpen = false }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                channelColumn
            }
            .padding(.leading, 48)
            .padding(.vertical, 40)
        }
        // Back closes the whole overlay from ANY stage (Logan 2026-08-06:
        // Right is the layer-by-layer step-out; Back always exits fully).
        // The sidebar rail's own .onExitCommand forwards here too.
        .onExitCommand { onDismiss() }
        .onAppear { focusFirstRow() }
        .onChange(of: sidebarOpen) { _, open in
            if !open { focusFirstRow() }
        }
        .onChange(of: activeGroup) { _, _ in
            focusFirstRow()
        }
        .animation(.easeInOut(duration: 0.2), value: sidebarOpen)
    }

    // MARK: Channel column

    @ViewBuilder
    private var channelColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(groupSidebarLabel(activeGroup))
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.textPrimary)
                .padding(.leading, 6)

            if entries.isEmpty {
                Text("No channels in this group.")
                    .font(.system(size: 22))
                    .foregroundColor(.textSecondary)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            // Stable scroll anchor so a group change can jump
                            // the list back to the top even mid-load.
                            Color.clear
                                .frame(height: 0)
                                .id("overlay.top")

                            ForEach(entries) { item in
                                ChannelPickRow(
                                    item: item,
                                    isPlaying: item.id == playingID,
                                    onSelect: { onTune(item) }
                                )
                                .id(item.id)
                                .focused($focusedRowID, equals: item.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusSection()
                    // Left from the channel list slides the group sidebar in
                    // (spec: "Left again = enter sidebar to select other
                    // groups") — but only when it isn't already open. With the
                    // sidebar open the rail is the left neighbour, so Left is
                    // normal focus traversal into it and never reaches here.
                    // Up/Down are consumed by row-to-row focus movement.
                    .onMoveCommand { direction in
                        if direction == .left && !sidebarOpen {
                            sidebarOpen = true
                        }
                        // Logan 2026-08-06: Right steps OUT one layer at
                        // every stage. From the list (no sidebar) the next
                        // layer out is the player itself.
                        if direction == .right && !sidebarOpen {
                            onDismiss()
                        }
                    }
                    .onAppear { proxy.scrollTo(landingID, anchor: .center) }
                    .onChange(of: activeGroup) { _, _ in
                        proxy.scrollTo(landingID, anchor: .center)
                    }
                    .onChange(of: sidebarOpen) { _, open in
                        if !open { proxy.scrollTo(landingID, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Focus

    /// Landing row: the channel already playing when it is in this group
    /// (Logan 2026-09-02: "default focus should be on the channel already
    /// watching"), else the top row.
    private var landingID: String {
        if let playing = playingID, entries.contains(where: { $0.id == playing }) { return playing }
        return entries.first?.id ?? "overlay.top"
    }

    /// Land focus on the landing row. Retries briefly because a single
    /// `@FocusState` write is dropped while the LazyVStack row is still laying
    /// out (same pattern the guide + sidebar use).
    private func focusFirstRow() {
        guard !entries.isEmpty else { return }
        let target = landingID
        Task { @MainActor in
            for _ in 0..<10 {
                focusedRowID = target
                try? await Task.sleep(nanoseconds: 60_000_000)
                if focusedRowID == target { break }
            }
        }
    }
}

#endif
