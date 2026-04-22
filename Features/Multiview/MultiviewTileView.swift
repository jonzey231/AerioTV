import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// One tile in the multiview grid.
///
/// Responsibilities:
/// - Host an `MPVPlayerViewRepresentable` parameterised with the
///   tile's identity, audio-focus state, and pause state.
/// - Draw the focus ring + audio-active badge + channel label.
/// - Handle tap-to-take-audio.
/// - Handle long-press → `.confirmationDialog` with per-tile actions
///   (Remove / Make Audio / Full-Screen / Audio Track / Subtitle
///   Track / Move Tile — tvOS only).
/// - Surface decode errors via a red overlay with a Remove button.
/// - Act as a drag source + drop target on iPadOS for rearrange.
/// - Announce state to VoiceOver via `.accessibilityLabel`.
///
/// Non-responsibilities (container's job):
/// - Layout / positioning (handled by `MultiviewLayoutView`).
/// - tvOS relocate-mode D-pad remap (handled by
///   `MultiviewContainerView.onMoveCommand`).
/// - Add-sheet + exit wiring (handled by `MultiviewTransportBar`).
struct MultiviewTileView: View {
    let tile: MultiviewTile
    @ObservedObject var store: MultiviewStore

    /// `true` when this tile is the only one on-screen (N=1 case).
    /// At N=1 the tile is effectively "the player view" so per-tile
    /// corner chrome (audio badge, bottom label strip, close `×`)
    /// is redundant — the container-level `PlaybackChromeOverlay`
    /// renders title + Close at the top bar instead. Gating the
    /// three chrome pieces on `!isSoleTile` keeps the N=1 experience
    /// clean and matches the ported PlayerView chrome layout.
    ///
    /// Default `false` preserves existing behaviour when this view
    /// is constructed without the parameter (the current
    /// `MultiviewContainerView` call sites that don't yet pass it).
    var isSoleTile: Bool = false

    /// Drives the 5-second auto-fade of tile chrome (audio badge +
    /// label strip). Owned by `MultiviewContainerView`; injected
    /// here so the tile's per-platform bodies can read `isVisible`
    /// and call `reportInteraction()` on Button taps / Select
    /// presses to keep the chrome alive while the user is active.
    @EnvironmentObject private var chromeState: MultiviewChromeState

    /// Observed so the tvOS tile can drop its focusability when the
    /// single-stream player has been minimized to the corner. A
    /// SwiftUI `Button` is always focusable by default on tvOS —
    /// even with `.allowsHitTesting(false)` on an ancestor, the
    /// focus engine still considers the Button as a target, which
    /// would trap focus inside the 400×225 corner instead of letting
    /// it flow to the guide behind. Reading `nowPlaying.isMinimized`
    /// here lets the Button flip to `.focusable(false)` (see
    /// `tvOSBody`) so the focus engine naturally reassigns to
    /// something in the guide.
    #if os(tvOS)
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    #endif

    /// A per-tile progress store. `@StateObject` so SwiftUI keeps it
    /// alive across tile re-renders and a new one is built for each
    /// new tile identity. Holds the tile's audio/subtitle track
    /// list, current mpv progress, and the `togglePauseAction`
    /// callback. Non-audio tiles still decode, so this store keeps
    /// tracking even while muted.
    @StateObject private var progressStore = PlayerProgressStore()

    /// Per-tile attempt log — mpv events, failover attempts. Purely
    /// diagnostic; nothing user-visible.
    @StateObject private var logStore = AttemptLogStore()

    /// iPadOS: focus state driven by `TVPressOverlay`'s UIKit focus
    /// callback. Unused on tvOS after the Button/ButtonStyle rewrite
    /// — there, focus is driven by `@Environment(\.isFocused)`
    /// inside `MultiviewTileButtonStyle`.
    #if !os(tvOS)
    @State private var isFocused: Bool = false
    #endif

    /// Whether the confirmation dialog (per-tile action menu) is
    /// currently showing. iPadOS only — tvOS uses `.contextMenu`
    /// (native long-press menu) which manages its own presentation.
    #if !os(tvOS)
    @State private var showMenu: Bool = false
    #endif

    /// Non-nil when the underlying mpv coordinator reported a fatal
    /// decode error. Drives the red error overlay. Tapping "Remove"
    /// on the overlay calls `store.remove(id:)`, which takes the
    /// tile out of the grid entirely.
    @State private var decodeErrorMessage: String? = nil

    #if os(tvOS)
    /// Timestamp of the most recent Select press, used to detect
    /// double-click on Siri Remote. tvOS has no native double-tap
    /// gesture on `Button`, so we roll our own: remember the press
    /// time; on the next press within
    /// `Self.doubleClickWindowSeconds`, treat it as a double-click
    /// and promote the tile to fullscreen (`store.fullscreenTileID`).
    /// A single Select still takes audio as before.
    ///
    /// The single-tap action fires immediately (no 400ms delay) so
    /// normal audio-swap stays snappy. A user who double-clicks
    /// will briefly see audio switch on the first press before the
    /// fullscreen promotion on the second — acceptable trade-off
    /// for not introducing latency to the common case.
    @State private var lastSelectPressAt: Date? = nil
    private static let doubleClickWindowSeconds: TimeInterval = 0.4
    #endif

    /// Stacked confirmation-dialog flags for the per-tile track
    /// sub-menus. SwiftUI doesn't support nested `.confirmationDialog`
    /// directly; the pattern is to tap a button in the main menu that
    /// dismisses it + sets one of these, which triggers a fresh
    /// dialog on the next render.
    @State private var showAudioTrackMenu: Bool = false
    @State private var showSubtitleTrackMenu: Bool = false

    var isAudioActive: Bool { store.audioTileID == tile.id }

    /// Computed: a tile should freeze its mpv decode when:
    /// - PiP is currently active AND this is NOT the audio tile
    ///   (PiP-source tile keeps decoding; others pause for
    ///   CPU/GPU/network savings — existing behaviour).
    /// - OR the channel-picker sheet is open (`isPickerPresented`).
    ///   In the picker case we pause ALL tiles including the audio
    ///   tile — the sheet's channel-list rendering + image loads
    ///   can consume hundreds of MB on Apple TV 4K, and holding a
    ///   concurrent videotoolbox decode session turns borderline
    ///   pressure into jetsam kills. The pause resumes the instant
    ///   the sheet dismisses (pick or cancel), so the user sees a
    ///   momentary freeze rather than a crash.
    private var shouldPause: Bool {
        if store.isPickerPresented { return true }
        // Fullscreen-within-grid mode: the promoted tile keeps
        // decoding; every OTHER tile freezes. This is the
        // double-click-Select UX (tvOS) — user zooms into one
        // stream, the rest pause until Menu is pressed. Saves
        // GPU decode + network cost for 1-3 background tiles
        // while the user is focused on one.
        if let fullID = store.fullscreenTileID, fullID != tile.id {
            return true
        }
        return store.isPiPActive && !isAudioActive
    }

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iPadOSBody
        #endif
    }

    // MARK: - tvOS body (Button + ButtonStyle + contextMenu)

    #if os(tvOS)
    /// tvOS tile wraps the video content in a SwiftUI `Button` and
    /// drives focus chrome through `MultiviewTileButtonStyle`. This
    /// replaces the earlier `TVPressOverlay` + `@State isFocused`
    /// approach which didn't reliably surface focus visuals — users
    /// reported hearing the focus-change sound with no visible
    /// indicator. Native Button + ButtonStyle is the proven tvOS
    /// path used elsewhere in the app (Settings cards, VOD posters)
    /// and it plays correctly with the tvOS focus engine.
    ///
    /// Interaction model (different from iPadOS by design):
    /// - **Select** = take audio (common case). In relocate mode,
    ///   Select commits the move instead.
    /// - **Long-press Select** = native `.contextMenu` with the
    ///   full per-tile action list. `.contextMenu` uses the OS
    ///   long-press timing so the memory-note about SwiftUI's
    ///   `.onLongPressGesture` firing on release doesn't apply
    ///   here.
    /// - **Menu** (Back) while relocating = cancel.
    /// - **D-pad** while relocating = swap with the physical
    ///   neighbour in that direction.
    ///
    /// No separate close button — Remove lives in the context menu
    /// like every other action. Siri Remote users don't want a
    /// second focusable target per tile; it bloats the focus chain
    /// without matching UX value.
    @ViewBuilder
    private var tvOSBody: some View {
        Button {
            // Select presses wake the focus indicator (the center
            // audio icon) but deliberately DON'T call
            // `reportInteraction()` — that would also summon the
            // bottom pills (Options + Add Stream), which is what the
            // old model did and what we just moved away from. The
            // bottom pills are no longer auto-summoned by Select or
            // D-pad; they're reachable via the long-press context
            // menu (Play/Pause pills are still present at N=1 under
            // the unified chrome overlay).
            chromeState.reportFocusActivity()
            // Error state takes priority — if the tile is showing
            // the red "Decoder unavailable" card, Select removes
            // the tile. The inner Button in that card can't be
            // focused (nested inside this outer Button's label),
            // so the instructional text says "Press Select to
            // Remove" and this is how we honour it.
            if decodeErrorMessage != nil {
                DebugLogger.shared.log(
                    "[MV-Cmd] tvOS tile remove via error-overlay (Select) tile=\(tile.id)",
                    category: "Playback", level: .info
                )
                store.remove(id: tile.id)
                return
            }
            // Commit a pending relocate first, otherwise take audio.
            if store.relocatingTileID == tile.id {
                store.relocatingTileID = nil
                DebugLogger.shared.log(
                    "[MV-Cmd] tvOS relocate commit (Select) tile=\(tile.id)",
                    category: "Playback", level: .info
                )
                return
            }
            // Double-click detection: a second Select press within
            // the window promotes this tile to fullscreen-within-grid.
            // The container's `.onExitCommand` reverses it on Menu.
            // `MultiviewTileView.shouldPause` pauses every other
            // tile's mpv handle while a tile is fullscreen —
            // decode/GPU savings come "for free" from that.
            //
            // Gate on N>1: at N=1 there's nothing to zoom into and
            // no other tiles to pause, so the promotion is a no-op
            // visually. Better to keep single-tap = "activity /
            // reveal chrome" semantics at N=1.
            let now = Date()
            if store.tiles.count > 1,
               let last = lastSelectPressAt,
               now.timeIntervalSince(last) < Self.doubleClickWindowSeconds {
                lastSelectPressAt = nil
                store.fullscreenTileID = tile.id
                DebugLogger.shared.log(
                    "[MV-Cmd] tvOS double-click fullscreen tile=\(tile.id)",
                    category: "Playback", level: .info
                )
                return
            }
            lastSelectPressAt = now
            store.setAudio(to: tile.id)
        } label: {
            tileVideoContent
        }
        .buttonStyle(MultiviewTileButtonStyle(
            isRelocating: store.relocatingTileID == tile.id,
            // Use the focus-indicator gate rather than the full
            // chrome gate: the tile ring reappears whenever the
            // user moves focus (D-pad), independent of whether the
            // transport bar is up. That lets focus feedback track
            // navigation without dragging the bottom UI in.
            isChromeVisible: chromeState.focusIndicatorVisible
        ))
        // NOTE: do NOT apply `.focusable(Bool)` here. On tvOS,
        // explicitly attaching `.focusable(true)` to a SwiftUI
        // `Button` appears to disrupt how `@Environment(\.isFocused)`
        // propagates into the Button's label — which broke the
        // `CenterAudioIconView` and the subtle scale-pop at N>=2
        // (user reported no focus indicator during D-pad nav).
        //
        // Mini-mode focus release is handled entirely by HomeView's
        // `.disabled(playerSession.mode == .multiview && !(N==1 && isMinimized))`
        // gate on the `tabContentView` — once that gate opens in
        // mini state, the tvOS focus engine lets focus cross from
        // the tile to the guide via D-pad spatial search. The tile
        // stays focusable (Button default), and the focus indicator
        // continues to work normally.
        // Context-menu at N=1 drops its actions (meaningless with a
        // single tile) but keeps the `.contextMenu` attachment so
        // the focus engine behaviour is unchanged.
        .contextMenu {
            if !isSoleTile { tileContextMenu }
        }
        // Relocate-mode D-pad swap is handled at the CONTAINER level
        // (`MultiviewContainerView`'s `.onMoveCommand`), not here.
        // Previous attempt put the handler on the tile and guarded
        // on `store.relocatingTileID == tile.id`, but tvOS routes
        // D-pad events based on its own view of "which tile is
        // focused" — after the context menu dismiss, focus often
        // ends up on the AUDIO tile (via `prefersDefaultFocus`), not
        // the tile the user asked to move. The tile-level handler
        // would then silently return early (wrong tile) and the
        // swap never happened.
        //
        // Moving the handler to the focusSection-level container
        // means any D-pad within the grid reaches the swap logic,
        // which consults `store.relocatingTileID` directly as the
        // source of truth — no dependence on where focus technically
        // is. The tile-level handler being PRESENT (even as a no-op)
        // would absorb the move event in SwiftUI's propagation path,
        // so we simply don't attach one.
        // No `.onExitCommand` here — SwiftUI's onExitCommand is an
        // absorbing handler (once attached, Menu presses are
        // consumed by this view and never reach ancestors, even if
        // the closure body is a no-op). Previously this view had a
        // `.onExitCommand` that cancelled relocate mode, but its
        // mere presence also swallowed Menu in the common case
        // (focus on a non-relocating tile) — which meant the
        // container's exit stack (chrome-summon, session.stop,
        // exitMultiviewKeepingAudioTile) never fired and the Back
        // button appeared dead. Relocate-cancel is now handled
        // exclusively by the container's `.onExitCommand` at
        // `MultiviewContainerView` (it already has a branch for
        // `store.relocatingTileID != nil`), which fires because the
        // tile no longer intercepts.
        .confirmationDialog(
            "Audio Track",
            isPresented: $showAudioTrackMenu,
            titleVisibility: .visible
        ) {
            audioTrackButtons
        }
        .confirmationDialog(
            "Subtitle Track",
            isPresented: $showSubtitleTrackMenu,
            titleVisibility: .visible
        ) {
            subtitleTrackButtons
        }
        .accessibilityLabel(a11yLabel)
    }

    /// Context-menu contents for a tvOS tile. Items are ordered by
    /// expected frequency: Make Audio (hidden on audio tile) → Full-
    /// Screen → Audio/Subtitle Track sub-sheets → Move Tile →
    /// Remove. Every item uses `Label(_:systemImage:)` so icons
    /// appear next to each row in the native tvOS menu.
    @ViewBuilder
    private var tileContextMenu: some View {
        if !isAudioActive {
            Button {
                store.setAudio(to: tile.id)
            } label: {
                Label("Make Audio", systemImage: "speaker.wave.2.fill")
            }
        }

        let isFullscreen = store.fullscreenTileID == tile.id
        Button {
            store.fullscreenTileID = isFullscreen ? nil : tile.id
        } label: {
            Label(
                isFullscreen ? "Exit Full-Screen" : "Full-Screen in Grid",
                systemImage: isFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
        }

        if progressStore.audioTracks.count > 1 {
            Button {
                Task { @MainActor in showAudioTrackMenu = true }
            } label: {
                Label("Audio Track", systemImage: "waveform")
            }
        }
        if !progressStore.subtitleTracks.isEmpty {
            Button {
                Task { @MainActor in showSubtitleTrackMenu = true }
            } label: {
                Label("Subtitle Track", systemImage: "captions.bubble")
            }
        }

        Button {
            store.relocatingTileID = tile.id
            DebugLogger.shared.log(
                "[MV-Cmd] tvOS relocate enter tile=\(tile.id)",
                category: "Playback", level: .info
            )
        } label: {
            Label(
                "Move Tile",
                systemImage: "arrow.up.and.down.and.arrow.left.and.right"
            )
        }

        Button(role: .destructive) {
            store.remove(id: tile.id)
        } label: {
            Label("Remove", systemImage: "xmark.circle")
        }
    }

    /// Pure visual content of the tile (no gestures, no focus
    /// state) — used as the `Button` label on tvOS. The
    /// surrounding `Button` + `MultiviewTileButtonStyle` handle
    /// focus chrome + input; this view just draws video + overlays.
    @ViewBuilder
    private var tileVideoContent: some View {
        ZStack {
            MPVPlayerViewRepresentable(
                urls: [tile.streamURL],
                headers: tile.headers,
                isLive: true,
                nowPlayingTitle: tile.item.name,
                nowPlayingSubtitle: tile.item.currentProgram,
                nowPlayingArtworkURL: tile.item.logoURL,
                progressStore: progressStore,
                logStore: logStore,
                onFatalError: { message in
                    decodeErrorMessage = message
                    DebugLogger.shared.log(
                        "[MV-Tile] decode error: channel=\(tile.item.name) msg=\(Self.sanitizedErrorMessage(message))",
                        category: "Playback", level: .warning
                    )
                },
                tileID: tile.id,
                isAudioActive: isAudioActive,
                shouldPause: shouldPause
            )
            .id(tile.id)
            .onAppear {
                DebugLogger.shared.log(
                    "[MV-Tile] mount id=\(tile.id) name=\(tile.item.name)",
                    category: "Playback", level: .info
                )
                // Register our per-tile progress store so the unified
                // chrome overlay (PlaybackChromeOverlay + Options
                // panel) can bind scrubber / track pickers / speed to
                // the audio tile's store regardless of which tile it
                // happens to be.
                store.registerProgressStore(progressStore, for: tile.id)
            }
            .onDisappear {
                DebugLogger.shared.log(
                    "[MV-Tile] unmount id=\(tile.id)",
                    category: "Playback", level: .info
                )
                store.unregisterProgressStore(for: tile.id)
            }

            // Per-tile corner chrome is suppressed at N=1. The
            // container-level `PlaybackChromeOverlay` handles title
            // + controls at that layout, so the label strip would
            // just duplicate information.
            //
            // On tvOS the corner `audioBadge` was removed in favour
            // of `centerAudioIcon` — the icon in the tile centre
            // also serves as the focus indicator (replacing the
            // accent ring + scale-up). It shows on any focused tile
            // while the `focusIndicatorVisible` state is awake, and
            // changes appearance to signal whether THAT tile
            // currently owns audio (solid) or would take audio on
            // the next Select press (outline).
            if !isSoleTile {
                labelStrip
                centerAudioIcon
            }
            if let decodeErrorMessage {
                decodeErrorOverlay(decodeErrorMessage)
            }
        }
        .background(Color.black)
    }
    #endif

    // MARK: - iPadOS body (unchanged behavior)

    #if !os(tvOS)
    @ViewBuilder
    private var iPadOSBody: some View {
        tileContent
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
            .confirmationDialog(
                Text(verbatim: tile.item.name),
                isPresented: $showMenu,
                titleVisibility: .visible
            ) {
                menuButtons
            }
            .confirmationDialog(
                "Audio Track",
                isPresented: $showAudioTrackMenu,
                titleVisibility: .visible
            ) {
                audioTrackButtons
            }
            .confirmationDialog(
                "Subtitle Track",
                isPresented: $showSubtitleTrackMenu,
                titleVisibility: .visible
            ) {
                subtitleTrackButtons
            }
    }
    #endif

    // MARK: - iPadOS content

    #if !os(tvOS)
    /// iPadOS tile layout. The corner close `×` was removed per
    /// user feedback — the button was visually noisy and the same
    /// Remove action lives in the long-press context menu (see
    /// `menuButtons` → "Remove stream"). Closing a tile is
    /// intentional enough to warrant the long-press gesture; a
    /// one-tap X made it too easy to accidentally dismiss streams
    /// during audio-focus taps.
    @ViewBuilder
    private var tileContent: some View {
        if isSoleTile {
            // N=1 short-circuit. The sole tile IS the player view —
            // clipShape / scaleEffect / hoverEffect / per-tile
            // animations exist only to distinguish tiles in a
            // multiview grid, and wrapping the auto-PiP source
            // `AVSampleBufferDisplayLayer` in a clipped + animated
            // transform stack was making iOS's PiP restore
            // animation read a stale / animated target rect and
            // fall back to its default "zoom + PiP-icon placeholder"
            // transition. Legacy `PlayerView` mounts the same
            // representable directly inside a plain ZStack (no
            // clip, no scale, no animation) and iOS's restore
            // animation lands cleanly there — we match that.
            //
            // The black background underlay is kept so letterboxed
            // streams don't render over whatever's behind them.
            ZStack {
                tappableRegion
            }
            .background(Color.black)
        } else {
            ZStack {
                tappableRegion
            }
            .overlay(
                // Focus ring (tvOS) / relocate-amber. Audio-active is
                // signalled by the audioBadge (speaker icon top-left),
                // not a ring — see `ring` docstring.
                Self.tileShape
                    .stroke(ring.color, lineWidth: ring.width)
            )
            .clipShape(Self.tileShape)
            // Black underlay so letterbox bars aren't transparent.
            .background(Self.tileShape.fill(Color.black))
            // tvOS focus lift: scale + outer shadow combine with the
            // white ring above to create the full "card lifts on focus"
            // feedback. iPad uses hoverEffect below (no-op on touch).
            .scaleEffect(focusScale)
            .shadow(
                color: focusShadow.color,
                radius: focusShadow.radius,
                y: focusShadow.y
            )
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeInOut(duration: 0.15), value: store.relocatingTileID)
            .hoverEffect(.highlight)
        }
    }

    /// Gesture-receiving inner ZStack. Everything that should respond
    /// to tap-to-take-audio, long-press-to-open-menu, and drag-to-
    /// rearrange lives in here — the close button does NOT, so its
    /// `Button` action isn't stolen by these parent gestures.
    private var tappableRegion: some View {
        ZStack {
            // The actual mpv-backed video view. It's at the bottom of
            // the ZStack so overlays paint on top.
            MPVPlayerViewRepresentable(
                urls: [tile.streamURL],
                headers: tile.headers,
                isLive: true,
                nowPlayingTitle: tile.item.name,
                nowPlayingSubtitle: tile.item.currentProgram,
                nowPlayingArtworkURL: tile.item.logoURL,
                progressStore: progressStore,
                logStore: logStore,
                onFatalError: { message in
                    // Surface on the tile instead of killing the
                    // whole app. The overlay exposes a Remove button.
                    decodeErrorMessage = message
                    // Log the sanitized message — the raw message can
                    // echo server-controlled bytes (HLS errors, HTTP
                    // response bodies). `sanitizedErrorMessage` strips
                    // control/bidi chars and caps length.
                    DebugLogger.shared.log(
                        "[MV-Tile] decode error: channel=\(tile.item.name) msg=\(Self.sanitizedErrorMessage(message))",
                        category: "Playback", level: .warning
                    )
                },
                tileID: tile.id,
                isAudioActive: isAudioActive,
                shouldPause: shouldPause
            )
            // SwiftUI identity is the TILE id, not the item.id, so
            // rearrange (which shuffles `tiles` but keeps ids) doesn't
            // recreate the coordinator. Seed-from-single has
            // `tile.id == item.id` so that case also preserves
            // identity with the single-mode view.
            .id(tile.id)
            .onAppear {
                DebugLogger.shared.log(
                    "[MV-Tile] mount id=\(tile.id) name=\(tile.item.name)",
                    category: "Playback", level: .info
                )
                // Register our per-tile progress store so the unified
                // chrome overlay (PlaybackChromeOverlay + Options
                // panel) can bind scrubber / track pickers / speed to
                // the audio tile's store regardless of which tile it
                // happens to be.
                store.registerProgressStore(progressStore, for: tile.id)
            }
            .onDisappear {
                DebugLogger.shared.log(
                    "[MV-Tile] unmount id=\(tile.id)",
                    category: "Playback", level: .info
                )
                store.unregisterProgressStore(for: tile.id)
            }

            // Per-tile corner chrome suppressed at N=1 (container
            // chrome renders title + Close at the top bar instead).
            //
            // For N>1: mutually-exclusive audio badge (centered, with
            // channel name pill) OR bottom label strip — never both.
            // The audio tile gets the centered badge as its identity
            // marker; other tiles get the bottom name pill. Rendering
            // both on the audio tile produced a duplicate channel
            // name (user flagged: "the channel name is also appearing
            // at the very bottom of the display which shouldn't be
            // there since it's already listed inside the tile itself").
            if !isSoleTile {
                if isAudioActive {
                    audioBadge
                } else {
                    labelStrip
                }
            }

            // Red decode-error overlay. Only shown when mpv's failover
            // has exhausted its retries. Remove button calls the
            // store — tearing down the MPVPlayerView via the tile
            // removal is cleaner than trying to re-init the mpv
            // handle in place.
            if let decodeErrorMessage {
                decodeErrorOverlay(decodeErrorMessage)
            }
        }
        // Explicit hit shape so taps on the letterbox black (where
        // there's no video) still count.
        .contentShape(Rectangle())
        .onTapGesture {
            chromeState.reportInteraction()
            // Error state: tap removes (see decodeErrorOverlay
            // docstring for why the inner Button doesn't work).
            if decodeErrorMessage != nil {
                DebugLogger.shared.log(
                    "[MV-Cmd] iPad tile remove via error-overlay (tap) tile=\(tile.id)",
                    category: "Playback", level: .info
                )
                store.remove(id: tile.id)
                return
            }
            // Move Mode — if a tile is currently pending relocation
            // (user chose "Move Tile" from its long-press menu), the
            // next tile tap commits the swap, or tapping the moving
            // tile itself cancels. See `menuButtons` → "Move Tile"
            // for the entry point, and `relocateBanner` in
            // `MultiviewContainerView` for the on-screen prompt.
            // Audio assignment is intentionally skipped while move
            // mode is active so the user doesn't accidentally
            // reshuffle audio while rearranging layout.
            if let movingID = store.relocatingTileID {
                if movingID == tile.id {
                    store.relocatingTileID = nil
                    DebugLogger.shared.log(
                        "[MV-Cmd] iPad relocate cancel (tap source) tile=\(tile.id)",
                        category: "Playback", level: .info
                    )
                } else {
                    store.swap(movingID, tile.id)
                    store.relocatingTileID = nil
                    DebugLogger.shared.log(
                        "[MV-Cmd] iPad relocate commit (tap target) source=\(movingID) target=\(tile.id)",
                        category: "Playback", level: .info
                    )
                }
                return
            }
            store.setAudio(to: tile.id)
        }
        // NOTE: `.onDrag`/`.onDrop` were removed in favour of a
        // reliable long-press menu. UIKit's `UIDragInteraction`
        // (installed by `.onDrag`) sets up `requireToFail`
        // relationships that reliably starve *any* sibling SwiftUI
        // long-press gesture on the same view — `.onLongPressGesture`,
        // `.simultaneousGesture(LongPressGesture…)`, and
        // `.highPriorityGesture(LongPressGesture…)` all fail to fire
        // so long as `.onDrag` is declared alongside them. Since the
        // per-tile long-press menu is how iPad users Remove / go
        // Full-Screen / pick Audio Track / pick Subtitle Track /
        // take audio — i.e. every non-trivial per-tile action — we
        // prioritise it over drag-to-rearrange. Rearrangement is
        // preserved via the "Move Tile" action in `menuButtons`,
        // which enters relocate mode (`store.relocatingTileID`);
        // the on-grid tap handler above commits the swap when the
        // user taps another tile, matching tvOS semantics but
        // swapping "D-pad arrow" for "tap target".
        .onLongPressGesture(minimumDuration: 0.35) {
            chromeState.reportInteraction()
            showMenu = true
            DebugLogger.shared.log(
                "[MV-Cmd] tile menu opened id=\(tile.id)",
                category: "Playback", level: .info
            )
        }
    }
    #endif

    // MARK: - Shape

    /// Shared rectangle used for clip, background, and stroke.
    /// cornerRadius=0 so adjacent tiles meet flush at edges without
    /// black lens-shaped gaps where two rounded corners would miss
    /// each other. Previously radius=12 — matched Settings cards but
    /// read as visible padding between streams in a tight multiview
    /// grid, which the user flagged.
    private static let tileShape = RoundedRectangle(
        cornerRadius: 0,
        style: .continuous
    )

    // MARK: - iPadOS focus-ring helpers

    #if !os(tvOS)
    /// Precedence: relocating > focused (iPadOS hover) > none.
    /// Focus ring on tvOS is handled by `MultiviewTileButtonStyle`
    /// (see below), not this helper.
    private var ring: (color: Color, width: CGFloat) {
        if store.relocatingTileID == tile.id {
            return (.orange, 4)
        }
        return (.clear, 0)
    }

    private var focusScale: CGFloat { 1.0 }

    private var focusShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        (.clear, 0, 0)
    }
    #endif

    // MARK: - iPadOS close button

    // NOTE: per-tile close `×` (iPad) was intentionally removed.
    // The same Remove action lives in the long-press context menu
    // (`menuButtons` → "Remove"). The inline X was too easy to
    // tap accidentally during audio-focus taps, and users found it
    // visually noisy. Closing a tile is significant enough to
    // warrant the deliberate long-press gesture.

    /// Audio-tile indicator — centered on the tile, visually matching
    /// tvOS's `CenterAudioIconView` (accent speaker capsule above a
    /// dark channel-name pill). Users on iOS complained the previous
    /// corner placement "hung off" the tile and looked out of place;
    /// centering puts it in the same language as Apple TV.
    ///
    /// INTENTIONALLY state-less: no local `@State`, no `Task`,
    /// no `withAnimation`. Visibility is a pure read of the existing
    /// `chromeState.isVisible` — which also drives every other piece
    /// of tile chrome, so the indicator fades in/out with the rest
    /// of the overlay on user-idle timing. A previous attempt to
    /// add per-tile state + a 2.5 s fade-out `Task` correlated with
    /// a cascading freeze during single-stream → multiview
    /// transitions, because the state mutation fired
    /// `MPVPlayerViewRepresentable.updateUIViewController` at the
    /// same moment mpv was doing a `loadfile ... replace` for the
    /// "snap to live edge" cascade. Keeping this pure-read avoids
    /// that entire class of issue.
    private var audioBadge: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.accentPrimary))
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)

            Text(tile.item.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.65))
                        .overlay(
                            Capsule().strokeBorder(
                                Color.white.opacity(0.22),
                                lineWidth: 0.5
                            )
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        }
        // Constrain width so long channel names truncate instead of
        // pushing the indicator past small-tile edges.
        .frame(maxWidth: 220)
        .allowsHitTesting(false)
        .opacity(chromeState.isVisible ? 1 : 0)
    }

    #if os(tvOS)
    /// Centre audio-focus icon — the new tvOS focus indicator that
    /// replaces the accent ring + scale-up treatment.
    ///
    /// - Visible only on the focused tile (reads
    ///   `@Environment(\.isFocused)` — populated inside the Button's
    ///   label hierarchy).
    /// - Further gated on `chromeState.focusIndicatorVisible` so the
    ///   icon fades after 5 s of idle along with every other piece of
    ///   focus chrome, letting the grid read as one flush display.
    /// - Two visual states:
    ///     - **Audio tile** (this tile currently owns audio): solid
    ///       accent-colored capsule, filled speaker icon. "This is
    ///       the one you hear."
    ///     - **Non-audio tile** (focused, Select would bring audio
    ///       here): outline speaker icon, semi-transparent dark
    ///       background, white stroke. "Press Select to route audio
    ///       to this stream."
    ///
    /// Rendered as a SwiftUI struct (not a computed property) so it
    /// can read `@Environment(\.isFocused)` — environment values
    /// aren't available inside computed-property view builders on
    /// the enclosing struct, but they propagate into child views.
    private var centerAudioIcon: some View {
        CenterAudioIconView(
            isAudioActive: isAudioActive,
            channelName: tile.item.name
        )
    }
    #endif

    // MARK: - Label strip

    private var labelStrip: some View {
        VStack {
            Spacer()
            HStack {
                Text(tile.item.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                    )
                Spacer()
            }
            .padding(8)
        }
        .allowsHitTesting(false)
        .opacity(chromeState.isVisible ? 1 : 0)
    }

    // MARK: - Decode-error overlay

    /// Red error card shown when the tile's mpv coordinator reports
    /// a fatal decode/load failure.
    ///
    /// The overlay is drawn INSIDE the tile's primary tap target
    /// (the outer `Button` on tvOS, the `.onTapGesture`-wrapped
    /// `tappableRegion` on iPad). Nesting a SwiftUI `Button` inside
    /// either of those doesn't work:
    ///
    /// - **tvOS**: a `Button`'s label is static content — inner
    ///   Buttons can't receive focus. User reported the "Remove"
    ///   button did nothing because only the outer tile Button was
    ///   ever focusable.
    /// - **iPad**: the parent `.onTapGesture` swallows taps that
    ///   would otherwise reach the inner Button (same quirk that
    ///   broke the close-X before we moved it outside tappableRegion).
    ///
    /// Fix: drop the nested Button entirely. The tile's own tap /
    /// Select action (see `tvOSBody` / `tappableRegion`) routes to
    /// `store.remove(id:)` instead of `setAudio` whenever
    /// `decodeErrorMessage != nil`. The overlay shows instructional
    /// text telling the user which gesture removes the tile on each
    /// platform.
    private func decodeErrorOverlay(_ message: String) -> some View {
        ZStack {
            Color.red.opacity(0.85)
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                Text("Decoder unavailable")
                    .font(.headline)
                    .foregroundStyle(.white)
                // SECURITY: mpv error strings can echo server-controlled
                // bytes (HTTP error bodies, HLS parse errors, remote URL
                // fragments). `verbatim:` disables Markdown interpretation;
                // `sanitizedErrorMessage` strips control/bidi chars +
                // caps length.
                Text(verbatim: Self.sanitizedErrorMessage(message))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                // Instructional pill — what the user should do to
                // remove the errored tile. NOT a real Button; the
                // action is handled by the parent tile's existing
                // tap/Select target.
                Text(removeHintText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.white.opacity(0.22))
                    )
            }
            .padding(12)
        }
    }

    /// Per-platform text telling the user how to remove the tile
    /// when the decode-error card is showing.
    private var removeHintText: String {
        #if os(tvOS)
        return "Press Select to Remove"
        #else
        return "Tap to Remove"
        #endif
    }

    /// Strip control chars, bidi overrides, and truncate to a display-
    /// safe length. The remaining text is still technically attacker-
    /// influenced (mpv faithfully relays server errors), but it can't
    /// spoof structure or hide bytes.
    private static func sanitizedErrorMessage(_ raw: String) -> String {
        // Unicode categories we never want to see in the overlay:
        // C0/C1 controls, bidi overrides/embeddings, zero-width
        // space/joiner, LTR/RTL marks.
        let blockedScalars: Set<Unicode.Scalar> = [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{FEFF}"
        ]
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            if blockedScalars.contains(scalar) { continue }
            if scalar.value < 0x20 && scalar != "\n" && scalar != "\t" { continue }
            if (0x7F...0x9F).contains(scalar.value) { continue }
            cleaned.unicodeScalars.append(scalar)
            if cleaned.count >= 200 { break }
        }
        return cleaned
    }

    // MARK: - iPadOS confirmationDialog buttons

    #if !os(tvOS)
    @ViewBuilder
    private var menuButtons: some View {
        if !isAudioActive {
            Button("Make Audio") {
                store.setAudio(to: tile.id)
            }
        }

        let isFullscreen = store.fullscreenTileID == tile.id
        Button(isFullscreen ? "Exit Full-Screen" : "Full-Screen in Grid") {
            store.fullscreenTileID = isFullscreen ? nil : tile.id
        }

        if progressStore.audioTracks.count > 1 {
            Button("Audio Track…") {
                Task { @MainActor in showAudioTrackMenu = true }
            }
        }
        if !progressStore.subtitleTracks.isEmpty {
            Button("Subtitle Track…") {
                Task { @MainActor in showSubtitleTrackMenu = true }
            }
        }

        // Move Mode — iPad replacement for drag-to-rearrange (which
        // we had to remove because UIKit's `UIDragInteraction`
        // starved the long-press gesture that opens this very
        // menu). Three UX states:
        //   1. No active move, tiles.count > 1 → "Move Tile"
        //      (sets `relocatingTileID = tile.id`, shows banner +
        //      orange ring via `ring` helper).
        //   2. This tile is the moving tile → "Cancel Move"
        //      (clears relocate; tapping the source tile on-grid
        //      also cancels — see `tappableRegion.onTapGesture`).
        //   3. *Another* tile is being moved → "Swap to Here"
        //      (commits the swap from the menu rather than
        //      requiring the user to dismiss then tap this tile).
        // Both commit paths (menu "Swap to Here" + on-grid tap)
        // call `store.swap(movingID, tile.id)` + clear relocate,
        // so the final state is identical regardless of which one
        // the user reached for.
        if store.tiles.count > 1 {
            if let movingID = store.relocatingTileID {
                if movingID == tile.id {
                    Button("Cancel Move") {
                        store.relocatingTileID = nil
                        DebugLogger.shared.log(
                            "[MV-Cmd] iPad relocate cancel (menu) tile=\(tile.id)",
                            category: "Playback", level: .info
                        )
                    }
                } else {
                    Button("Swap to Here") {
                        store.swap(movingID, tile.id)
                        store.relocatingTileID = nil
                        DebugLogger.shared.log(
                            "[MV-Cmd] iPad relocate commit (menu) source=\(movingID) target=\(tile.id)",
                            category: "Playback", level: .info
                        )
                    }
                }
            } else {
                Button("Move Tile") {
                    store.relocatingTileID = tile.id
                    DebugLogger.shared.log(
                        "[MV-Cmd] iPad relocate enter tile=\(tile.id)",
                        category: "Playback", level: .info
                    )
                }
            }
        }

        Button("Remove", role: .destructive) {
            store.remove(id: tile.id)
        }

        Button("Cancel", role: .cancel) {}
    }
    #endif

    @ViewBuilder
    private var audioTrackButtons: some View {
        // SECURITY: `track.displayName` is mpv-sourced and therefore
        // attacker-influenced via stream metadata (title tag, track
        // lang). SwiftUI's `Button(_: String)` and `Button(_: LocalizedStringKey)`
        // both apply Markdown to the label — so a title like
        // `[Click](evil://)` would render a tappable link inside the
        // action sheet. Use the closure-based `Button { } label:`
        // form with `Text(verbatim:)` to disable interpretation.
        ForEach(progressStore.audioTracks) { track in
            let active = track.id == progressStore.currentAudioTrackID
            Button {
                progressStore.setAudioTrackAction?(track.id)
            } label: {
                Text(verbatim: active ? "✓ \(track.displayName)" : track.displayName)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var subtitleTrackButtons: some View {
        Button(progressStore.currentSubtitleTrackID == 0 ? "✓ Off" : "Off") {
            progressStore.setSubtitleTrackAction?(0)
        }
        ForEach(progressStore.subtitleTracks) { track in
            let active = track.id == progressStore.currentSubtitleTrackID
            Button {
                progressStore.setSubtitleTrackAction?(track.id)
            } label: {
                Text(verbatim: active ? "✓ \(track.displayName)" : track.displayName)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - A11y

    private var a11yLabel: String {
        let audioState = isAudioActive ? "audio on" : "muted"
        let name = tile.item.name
        let err = decodeErrorMessage != nil ? ", decode error" : ""
        return "\(name), \(audioState)\(err)"
    }
}

// MARK: - iPadOS drop delegate

// NOTE: `MultiviewTileDropDelegate` was deleted alongside the
// iPad `.onDrag`/`.onDrop` pair — see the gesture block in
// `tappableRegion` for why we removed drag-to-rearrange on iPad
// (UIKit's `UIDragInteraction` starves the long-press menu, which
// is the primary interaction). `MultiviewStore.swap(_:_:)` is
// still there and tvOS relocate mode still uses it, so resurrecting
// iPad drag is a one-liner if/when we add a proper "move mode"
// affordance that doesn't conflict with the long-press menu.

// MARK: - tvOS center audio-focus icon

#if os(tvOS)
/// Focus indicator for a tile on tvOS. Mounted at the tile centre
/// as a peer view inside the Button's label, so
/// `@Environment(\.isFocused)` is populated by the focus engine and
/// the icon appears on whichever tile currently holds focus.
///
/// Two visual states depending on `isAudioActive`:
/// - True (this tile has audio): solid accent capsule with filled
///   speaker icon. Says "this is what you're hearing."
/// - False (this tile is focused but isn't the audio source): dark
///   translucent capsule with outlined speaker icon + thin white
///   stroke. Says "press Select to route audio here."
///
/// Both states honour `chromeState.focusIndicatorVisible` — after
/// 5 s of remote idle the icon fades with the rest of the focus
/// chrome so the tiles read as one flush display surface.
private struct CenterAudioIconView: View {
    let isAudioActive: Bool
    /// Channel name rendered as a pill beneath the speaker icon so
    /// the user knows which stream they're focused on without having
    /// to recognise it from the thumbnail alone. Fades with the same
    /// `shouldShow` gate as the icon so it reads as one combined
    /// focus indicator rather than two independent overlays.
    let channelName: String

    @Environment(\.isFocused) private var isFocused
    @EnvironmentObject private var chromeState: MultiviewChromeState

    /// Visible while this tile is focused AND the shared focus
    /// indicator hasn't timed out. `focusIndicatorVisible` is
    /// woken by any D-pad move or Select press on the container
    /// (`MultiviewChromeState.reportFocusActivity()` / `reportInteraction()`).
    private var shouldShow: Bool {
        isFocused && chromeState.focusIndicatorVisible
    }

    /// Speaker icon. `fill` variant for the audio tile so it reads
    /// as "loud / active"; outline variant for the "focus-but-not-audio"
    /// state so it reads as "Select to make loud".
    private var iconName: String {
        isAudioActive ? "speaker.wave.2.fill" : "speaker.wave.2"
    }

    /// Background is the theme accent when this tile owns audio
    /// (strong presence, matches the app's accent language); a
    /// translucent black capsule when the tile is merely focused
    /// (subdued — it's a hint, not a state).
    @ViewBuilder
    private var iconBackground: some View {
        if isAudioActive {
            Capsule().fill(ThemeManager.shared.accent)
        } else {
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(0.85),
                        lineWidth: 1.5
                    )
                )
        }
    }

    /// Channel-name pill styled to sit just below the speaker icon.
    /// Always uses the subdued black capsule (not the accent) so the
    /// accent stays reserved as the "this is the audio tile" signal
    /// on the icon.
    private var namePill: some View {
        Text(channelName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.65))
                    .overlay(
                        Capsule().strokeBorder(
                            Color.white.opacity(0.25),
                            lineWidth: 1
                        )
                    )
            )
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(iconBackground)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 3)

            namePill
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        }
        .opacity(shouldShow ? 1 : 0)
        .scaleEffect(shouldShow ? 1.0 : 0.9)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.22), value: shouldShow)
        .animation(.easeInOut(duration: 0.22), value: isAudioActive)
    }
}
#endif

// MARK: - tvOS tile button style

#if os(tvOS)
/// Focus chrome for a multiview tile Button on tvOS.
///
/// Everything is now communicated through scale + shadow. No rings
/// (neither the old accent focus ring nor the previous orange
/// relocate ring) — users wanted a clean edge-to-edge grid without
/// any decorated borders that make it look like a "dev build".
///
/// Three visual states, each progressively more pronounced lift:
///
/// 1. **Idle** — flush, 1.0 scale, no shadow. The grid reads as one
///    continuous display.
/// 2. **Focused** — 1.015 scale + soft 8 pt shadow while the focus
///    indicator is awake. Just enough physical separation for the
///    eye to track where focus is without looking like a zoom.
/// 3. **Relocating** — 1.04 scale + heavier 20 pt shadow regardless
///    of `isChromeVisible` (the user MUST see which tile they're
///    moving). This "lifts the tile off the table" visually, which
///    is the same grammar as iOS drag-and-drop and doesn't require
///    a coloured border to read.
///
/// `configuration.isPressed` dims the label slightly on Select for
/// tactile feedback.
struct MultiviewTileButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    let isRelocating: Bool
    /// Whether the focus indicator should be visible. Distinct from
    /// full chrome visibility — D-pad navigation wakes this without
    /// summoning the transport bar. When false, the subtle focused
    /// lift is suppressed so the grid sits perfectly flush and reads
    /// as one continuous display surface. Ignored when
    /// `isRelocating` is true — the relocating-tile lift always
    /// renders so the user can see which tile is active during Move
    /// Tile mode even after the focus indicator would otherwise
    /// have idle-faded.
    let isChromeVisible: Bool

    // cornerRadius=0 so adjacent tiles' edges touch with zero visual
    // gap. See `MultiviewTileView.tileShape` for the rationale.
    private static let shape = RoundedRectangle(
        cornerRadius: 0,
        style: .continuous
    )

    /// Scale, largest → smallest priority:
    /// - Relocating: 1.04 (clearly off the grid surface)
    /// - Focused (awake): 1.015 (subtle lift)
    /// - Otherwise: 1.0 (flush)
    private var scale: CGFloat {
        if isRelocating { return 1.04 }
        if isFocused && isChromeVisible { return 1.015 }
        return 1.0
    }

    /// Shadow triple for the current visual state. Relocating gets a
    /// heavier drop shadow so the "lifted" tile reads as physically
    /// above its neighbours; focused gets a softer one that just
    /// gives a hint of height.
    private var shadowSpec: (color: Color, radius: CGFloat, y: CGFloat) {
        if isRelocating {
            return (.black.opacity(0.55), 20, 10)
        }
        if isFocused && isChromeVisible {
            return (.black.opacity(0.35), 8, 4)
        }
        return (.clear, 0, 0)
    }

    func makeBody(configuration: Configuration) -> some View {
        let s = shadowSpec
        return configuration.label
            .clipShape(Self.shape)
            .scaleEffect(scale)
            .shadow(color: s.color, radius: s.radius, y: s.y)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeInOut(duration: 0.25), value: isChromeVisible)
            // Slightly snappier animation on relocate enter/exit —
            // the lift needs to register instantly when the user
            // picks "Move Tile" so they associate the pop with the
            // action they just took.
            .animation(.easeOut(duration: 0.18), value: isRelocating)
    }
}
#endif

// NOTE: `iOSCenterAudioIndicator` (an iOS center-of-tile audio-
// routing badge ported from tvOS's `CenterAudioIconView`) was
// prototyped here and reverted after user testing on
// iPhone 17 Pro Max / iOS 26 showed the Add-to-Multiview `Done`
// tap producing a cascading freeze every time.
//
// Root signal from the log:
//   unpause → reload live stream (snap to live edge) on all tiles
//   → end-file STOP on tile 1 → watchdog silent → app frozen
//
// The "unpause → reload" cascade is pre-existing behaviour (tiles
// pause while the add-sheet is up, unpause on dismiss, and live
// streams snap back to live via `loadfile ... replace`). What
// changed: the indicator introduced @State + withAnimation
// + a Task.sleep tied to the audio-tile identity at the exact
// moment SwiftUI was already re-invalidating
// `MPVPlayerViewRepresentable` due to the pause/unpause
// transition. The combination correlated with the freeze.
//
// The top-left `audioBadge` remains as the only audio-focus
// affordance. Re-introducing the center indicator safely would
// likely mean putting it on a sibling overlay view at
// `MultiviewContainerView` level that observes `store.audioTileID`
// directly, so per-tile re-renders don't bubble into
// `MPVPlayerViewRepresentable.updateUIViewController` during
// multi-tile transitions. Feature is on the backlog.
