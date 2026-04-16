import SwiftUI

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

    /// Search query on iPad. tvOS skips the search field — typing via
    /// Siri Remote is painful and the category grouping below is
    /// usually enough.
    @State private var searchText: String = ""

    /// Holds the `ChannelDisplayItem` that triggered a `.needsWarning`
    /// response. Non-nil while the performance-warning alert is
    /// showing; nil otherwise.
    @State private var pendingWarningItem: ChannelDisplayItem? = nil

    /// Non-nil when an add attempt produced a user-facing error
    /// (`.rejectedMax`, `.unresolvable`). Short inline toast.
    @State private var toastMessage: String? = nil

    var body: some View {
        NavigationStack {
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
            #if os(iOS)
            .searchable(text: $searchText, prompt: "Search channels")
            #endif
            .navigationTitle("Add to Multiview")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            #else
            // tvOS: no toolbar, so expose a Close row at the very
            // top of the list. Without this the only way out of the
            // sheet is Menu, and if the user can't work out that
            // Menu dismisses a modal it looks trapped. `.onExitCommand`
            // below is the real escape hatch — the Close row is
            // belt-and-braces for discoverability.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
            .onExitCommand { isPresented = false }
            #endif
            .alert(
                "Performance may degrade",
                isPresented: Binding(
                    get: { pendingWarningItem != nil },
                    set: { if !$0 { pendingWarningItem = nil } }
                ),
                presenting: pendingWarningItem
            ) { item in
                Button("Continue", role: .destructive) {
                    // Clear the pending flag BEFORE re-entering
                    // `commitAdd`. If `add` ever returns a new
                    // `.needsWarning` in the same call (e.g. a future
                    // refactor where the throttle is per-tile-count),
                    // the subsequent `pendingWarningItem = newItem`
                    // would otherwise be clobbered by the clear
                    // below. Defensive; today's commit path can't
                    // re-enter.
                    pendingWarningItem = nil
                    commitAdd(item, bypassWarning: true)
                }
                Button("Cancel", role: .cancel) {
                    pendingWarningItem = nil
                }
            } message: { _ in
                Text("Adding more than \(multiviewStore.softLimit) streams may cause audio drops, buffering, or overheating on some devices.")
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    toastView(toastMessage)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
        }
    }

    // MARK: - Sections

    private func section(title: String, items: [ChannelDisplayItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                CompactChannelRow(
                    item: item,
                    isAlreadyAdded: alreadyAdded(item),
                    isDisabled: multiviewStore.isAtMax
                ) {
                    tryAdd(item)
                }
            }
        }
    }

    // MARK: - Data

    private var favoriteChannels: [ChannelDisplayItem] {
        applySearch(favoritesStore.favoriteItems)
    }

    private var recentChannels: [ChannelDisplayItem] {
        applySearch(recentsStore.resolved)
    }

    private var allChannelsFiltered: [ChannelDisplayItem] {
        applySearch(channelStore.channels)
    }

    /// Apply the current search filter (or pass through when empty).
    /// Matches across name / group / channel number, case-insensitive.
    /// `String.contains` is a literal substring match — no regex
    /// injection surface even though `searchText` is user input.
    private func applySearch(_ items: [ChannelDisplayItem]) -> [ChannelDisplayItem] {
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter { item in
            item.name.lowercased().contains(q)
                || item.group.lowercased().contains(q)
                || item.number.lowercased().contains(q)
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
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.black.opacity(0.8))
            )
            .accessibilityLabel(text)
    }
}
