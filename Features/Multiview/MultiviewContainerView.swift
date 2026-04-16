import SwiftUI

/// Root view of the multiview experience. Composites:
/// - `MultiviewLayoutView` for the animated grid of `MultiviewTileView`s
///   (replaced with a single expanded tile when `fullscreenTileID` is
///   set).
/// - `MultiviewTransportBar` docked at the bottom.
/// - Channel-picker sheet (placeholder here — the real one lands in
///   Phase 5 as `AddToMultiviewSheet`).
/// - Relocate-mode banner (tvOS only, when a tile is being moved).
///
/// Wiring:
/// - Tap "Exit" in the transport bar → `PlayerSession.exit()` which
///   resets the tile list + flips mode back to `.idle`. The parent
///   view (HomeView's mode branch, Phase 4) then tears this view down
///   and shows the Live TV guide.
/// - Tap "Add Tile" → presents the add sheet.
/// - `.focusSection()` on the grid container so tvOS D-pad doesn't
///   escape to the tab bar mid-grid (see plan's focus-engine note).
struct MultiviewContainerView: View {
    @ObservedObject private var store = MultiviewStore.shared
    @ObservedObject private var session = PlayerSession.shared

    /// When `true`, the add-channel sheet is presented. Wired to the
    /// transport bar's "Add Tile" button.
    @State private var showAddSheet: Bool = false

    /// tvOS default-focus namespace. The audio tile opts into this
    /// so the first tvOS-focus pass when entering multiview lands on
    /// the seed / audio tile (the one the user was JUST watching)
    /// rather than letting the focus engine pick an arbitrary tile
    /// — the add-sheet or the transport bar. Without this, the first
    /// thing that lights up can be "Add Tile", which reads as
    /// "do something new" when the user just wants to see their
    /// channel continue playing.
    #if os(tvOS)
    @Namespace private var focusNS
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                gridArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)  // breathing room above the grid

                // Transport bar spans edge-to-edge with its own
                // black background — no outer horizontal padding so
                // it reads as an integrated strip docked at the
                // bottom, not a floating capsule.
                MultiviewTransportBar(
                    store: store,
                    onAdd: { showAddSheet = true },
                    onExit: { session.exit() }
                )
            }

            if store.relocatingTileID != nil {
                relocateBanner
            }

            if store.isThermallyStressed {
                thermalBanner
            }
        }
        .task {
            // Subscribe to thermal-state changes for the lifetime of
            // the container. The observer posts on the main thread
            // per Apple docs, so direct @MainActor writes are fine.
            // Initial state primes the flag for the "already hot when
            // user opens multiview" case.
            store.thermalState = ProcessInfo.processInfo.thermalState
            DebugLogger.shared.log(
                "[MV-Thermal] initial arrival=\(thermalStateName(store.thermalState))",
                category: "Playback", level: .info
            )
            for await _ in NotificationCenter.default.notifications(
                named: ProcessInfo.thermalStateDidChangeNotification
            ) {
                let new = ProcessInfo.processInfo.thermalState
                let old = store.thermalState
                store.thermalState = new
                DebugLogger.shared.log(
                    "[MV-Thermal] state \(thermalStateName(old))→\(thermalStateName(new)) tiles=\(store.tiles.count)",
                    category: "Playback", level: .warning
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .multiviewRequestOpenAddSheet)
        ) { _ in
            // ⌘N keyboard shortcut (or any future programmatic
            // request) asks us to open the add-sheet.
            showAddSheet = true
        }
        #if os(tvOS)
        // Menu-button stack for multiview (innermost → outermost):
        //   1. Add-sheet present  → dismiss sheet (handled by sheet)
        //   2. Relocate mode      → dismiss relocate (tile .onExitCommand)
        //   3. Fullscreen tile    → collapse back to grid
        //   4. Multiview active   → exit multiview (calls session.exit)
        //
        // Without this, Menu inside the grid falls past multiview to
        // HomeView / the tab bar, which feels like the app is
        // ejecting the user instead of leaving multiview. SwiftUI's
        // `.onExitCommand` on a non-focused container is best-effort
        // but in practice works because the `.focusSection()` at the
        // grid scope gives us ownership of d-pad + Menu within that
        // region.
        .onExitCommand {
            if store.fullscreenTileID != nil {
                store.fullscreenTileID = nil
            } else if store.relocatingTileID != nil {
                // Defensive — tile's own .onExitCommand normally
                // handles this first, but if focus has drifted off
                // the tile mid-relocate we still want Menu to cancel.
                store.relocatingTileID = nil
            } else {
                session.exit()
            }
        }
        #endif
        .sheet(isPresented: $showAddSheet) {
            // The real channel picker: Favorites / Recent / All
            // Channels, routed through `MultiviewStore.add(...)`.
            #if os(iOS)
            AddToMultiviewSheet(isPresented: $showAddSheet)
                .presentationDetents([.fraction(0.45), .large])
                .presentationDragIndicator(.visible)
            #else
            // tvOS: sheets present full-screen by default; no detents
            // available. The grid behind keeps audio, so there's no
            // need for a "peek" mode.
            AddToMultiviewSheet(isPresented: $showAddSheet)
            #endif
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var gridArea: some View {
        if let fullscreenID = store.fullscreenTileID,
           let fullscreenTile = store.tiles.first(where: { $0.id == fullscreenID }) {
            // Fullscreen-within-grid: render only that tile at full
            // size. The menu button / Esc still works because the
            // menu action flips `fullscreenTileID` back to nil. Other
            // tiles keep decoding (no pause) so when we come back
            // they're already at live edge.
            MultiviewTileView(tile: fullscreenTile, store: store)
        } else {
            let grid = MultiviewLayoutView(tiles: store.tiles) { tile in
                #if os(tvOS)
                MultiviewTileView(tile: tile, store: store)
                    .prefersDefaultFocus(store.audioTileID == tile.id, in: focusNS)
                #else
                MultiviewTileView(tile: tile, store: store)
                #endif
            }
            #if os(tvOS)
            grid
                .focusSection()
                .focusScope(focusNS)
            #else
            grid
            #endif
        }
    }

    /// Short log-friendly name for `ProcessInfo.ThermalState` —
    /// `String(describing:)` on the raw enum prints "nominal" which
    /// is already what we want, but using a small function keeps
    /// future-proofing simple if Apple adds a new case.
    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair:    return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Thermal banner

    private var thermalBanner: some View {
        VStack {
            HStack {
                Spacer()
                Label(
                    "Device is hot — can't add more streams right now",
                    systemImage: "thermometer.high"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.red.opacity(0.9)))
                Spacer()
            }
            .padding(.top, 12)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: store.isThermallyStressed)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Device is hot, cannot add more streams")
        .allowsHitTesting(false)
        .onAppear {
            // Announce on arrival — `.task` in the container already
            // posts the state change to the store, but VoiceOver
            // needs an explicit notification; the banner's visual
            // insertion doesn't trigger an announcement.
            #if canImport(UIKit)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Device is hot. Cannot add more streams right now."
            )
            #endif
        }
    }

    // MARK: - Relocate banner

    private var relocateBanner: some View {
        VStack {
            HStack {
                Spacer()
                Label(
                    "Move Tile — use arrows; press Menu to finish",
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.orange.opacity(0.9))
                )
                Spacer()
            }
            .padding(.top, 12)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: store.relocatingTileID)
        .allowsHitTesting(false)
    }
}

