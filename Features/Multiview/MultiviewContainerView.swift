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
    /// Watched so the tvOS tile focus can be released the instant
    /// the user minimizes to the corner. The @FocusState binding
    /// below (`focusedTileID`) pins focus to the audio tile during
    /// normal playback — on minimize we explicitly clear it so the
    /// tile drops out of the focus engine's consideration and focus
    /// flows to the guide beneath. Without this observer the
    /// binding stays stale and focus stays trapped in the corner.
    @ObservedObject private var nowPlaying = NowPlayingManager.shared

    /// When `true`, the add-channel sheet is presented. Wired to the
    /// transport bar's "Add Tile" button.
    @State private var showAddSheet: Bool = false

    /// When `true`, the exit-confirmation dialog is presented. Set by
    /// the second Menu/Back press (first press summons the chrome;
    /// second press prompts for confirmation instead of exiting
    /// immediately — prevents accidental fat-thumb Menu-spams from
    /// nuking the user's carefully arranged multiview).
    ///
    /// The dialog's wording + action differ by tile count:
    ///   - N=1 on unified path: "Exit playback?" → `session.stop()`
    ///   - N>=2 (or legacy)  : "Exit multiview?" → collapse to the
    ///     audio tile via `exitMultiviewKeepingAudioTile()` (unified
    ///     stays in the container at N=1; legacy swaps to PlayerView).
    @State private var showExitConfirmation: Bool = false

    /// When `true` at N=1 on the unified path, the Options panel
    /// (audio / subtitles / sleep timer / stream info) is overlaid
    /// above the tile. Wired to the Options pill in
    /// `PlaybackChromeOverlay`. Declared cross-platform (not behind
    /// `#if os(tvOS)`) because the `PlaybackChromeOverlay` struct
    /// signature needs a non-optional Binding at compile time; iOS
    /// simply never flips the flag so the panel never mounts (and
    /// the panel itself is wrapped in `#if os(tvOS)` anyway).
    @State private var showTVOptions: Bool = false

    /// Presents the `RecordProgramSheet` for the audio tile's
    /// currently-playing program. Triggered by the Record pill in
    /// the tvOS bottom chrome / the iOS record button, so the user
    /// can schedule a recording without going back to the guide
    /// and long-pressing. Only effective when the audio tile has a
    /// non-nil `currentProgram` (EPG data loaded) — the pill itself
    /// is gated on that condition.
    @State private var showRecordSheet: Bool = false

    /// Sleep-timer state for the Options panel. Lives on the
    /// container so it survives panel dismissals and is shared
    /// between the timer-countdown loop and the Options UI. Was
    /// previously owned by `PlayerRootView`; ported as part of the
    /// PlayerView chrome absorb.
    @State private var sleepTimerEnd: Date? = nil

    /// Stream-info overlay toggle for the Options panel. Same
    /// rationale as `sleepTimerEnd`: container-owned so the panel
    /// binding + future stream-info overlay mount stay in sync.
    /// Phase C.6 mounts the actual overlay; for now the Options
    /// panel's toggle flips this flag with no visible effect in
    /// the unified path (still fires in the legacy path's
    /// `PlayerView`, which is unaffected).
    @State private var showStreamInfo: Bool = false

    #if os(tvOS)
    /// tvOS N=1 chrome focus targets. Binding flows into
    /// `PlaybackBottomChrome_tvOS` so the Options / Add Stream
    /// pills can opt into named focus via `.focused(_:equals:)`.
    /// Driven by the D-pad-down handler on the tile: when the
    /// chrome appears, we set this to `.options` so focus moves
    /// onto the pill immediately instead of requiring the user to
    /// press down a second time. Resets to `nil` (implicit
    /// fallback to the tile's `prefersDefaultFocus`) when the
    /// chrome fades back out.
    enum ChromeFocusTarget: Hashable { case options, addStream, record }
    @FocusState private var focusedChrome: ChromeFocusTarget?

    /// Tile-level focus state, keyed on tile id. Used ONLY to pin
    /// focus to the relocating tile while Move-Tile mode is active —
    /// the context menu's "Move Tile" action dismisses the menu and
    /// tvOS re-evaluates focus, which (via `prefersDefaultFocus` on
    /// the audio tile) steals focus off the intended target. That
    /// means D-pad presses end up on the wrong tile's `.onMoveCommand`
    /// and the guard `relocatingTileID == tile.id` silently fails, so
    /// swaps never happen. Driving this `@FocusState` from the
    /// `relocatingTileID` change lets us explicitly re-focus the tile
    /// the user asked to move, and keeps the focus pinned there
    /// across subsequent swaps (the tile id doesn't change, only its
    /// array position, so the binding keeps tracking correctly).
    ///
    /// When relocate ends, we don't clear `focusedTileID` — letting
    /// the focus engine reclaim normal navigation keeps the UX
    /// natural (user exits relocate and focus is right where it was).
    @FocusState private var focusedTileID: String?
    #endif

    /// tvOS default-focus namespace. The audio tile opts into this
    /// so the first tvOS-focus pass when entering multiview lands on
    /// the seed / audio tile (the one the user was JUST watching)
    /// rather than letting the focus engine pick an arbitrary tile
    /// — the add-sheet or the transport bar. Without this, the first
    /// thing that lights up can be "Add Tile", which reads as
    /// "do something new" when the user just wants to see their
    /// channel continue playing.
    #if os(tvOS)
    /// Namespace for `.prefersDefaultFocus` hints. The tile whose
    /// id matches `MultiviewStore.audioTileID` opts in, so when
    /// multiview appears tvOS lands focus on the seed / audio tile
    /// rather than picking an arbitrary focusable.
    @Namespace private var focusNS
    #endif

    /// Drives the 5-second auto-fade of multiview chrome (transport
    /// bar, audio badge on each tile, channel label on each tile).
    /// Owned here; injected into children via `.environmentObject`
    /// so the tile view + transport bar can read `isVisible` and
    /// call `reportInteraction()` from their button actions.
    @StateObject private var chromeState = MultiviewChromeState()

    /// Settings → Multiview → "Padding Between Tiles". v1.6.8 —
    /// false (default) keeps adjacent tiles meeting flush like the
    /// original multiview design; true inserts an 8pt gap between
    /// tiles so each stream stands on its own.
    @AppStorage(multiviewTilePaddingKey)
    private var paddingEnabled: Bool = false

    /// Resolved spacing for the grid math, derived from the user's
    /// preference. 0pt is the legacy flush layout; 8pt is the
    /// "padded" layout introduced in v1.6.8.
    private var tileSpacing: CGFloat { paddingEnabled ? 8 : 0 }

    var body: some View {
        // N=1 treatment — "this is effectively PlayerView" — is
        // gated on the unified-playback feature flag. Without the
        // flag, legacy users can still hit N=1 (e.g. by removing a
        // tile from N=2 via its per-tile ×) and we MUST NOT change
        // their UX: leave transport bar visible, leave per-tile
        // chrome + close buttons in place, don't mount the new
        // overlay. The flag is the single contract that says
        // "the user has opted into the unified playback path."
        //
        // Phase C.4 lands the minimum overlay at N=1 (Close + `+`
        // on iOS, `+` pill on tvOS) for flag-on users only; Phase
        // C.6 adds scrubber, options panel, AirPlay, stream info,
        // mini-player.
        let unifiedPath = PlaybackFeatureFlags.useUnifiedPlayback
        let isSoleTile = unifiedPath && store.tiles.count == 1

        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                gridArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Edge-to-edge at every N. The previous
                    // `.padding(.horizontal, 16) / .padding(.top, 4)`
                    // at N>=2 was adding a visible gutter around the
                    // multiview grid that the user flagged as
                    // "padding between streams". With
                    // `MultiviewGridMath.defaultSpacing = 0` the
                    // tiles already sit flush against each other; the
                    // container now pushes that flush layout all the
                    // way to the screen edges too.
                    .ignoresSafeArea()
                    // v1.6.12 (GH #11 follow-up): disable the tile
                    // Button(s) while the TVOptions panel is open so
                    // D-pad-UP from the panel's first row can't
                    // escape to the tile above. Combined with the
                    // chrome-disable below this gives the panel a
                    // hard focus trap on every direction (no other
                    // focusable view exists outside the panel).
                    #if os(tvOS)
                    .disabled(showTVOptions)
                    #endif

                #if os(tvOS)
                // tvOS N=1 chrome lives INLINE in this VStack but
                // collapses to height 0 when the chrome is faded —
                // so during normal playback the tile is edge-to-edge
                // and the user doesn't see a permanent black strip
                // reserving space below the video. When the user
                // presses D-pad-down on the tile, the
                // `.onMoveCommand` handler at the container level
                // calls `chromeState.reportInteraction()` which
                // reveals the chrome AND, via `@FocusState`
                // redirect, pulls focus to the first pill (Options)
                // so there's no intermediate "press down a second
                // time" step.
                //
                // Previous iterations: ZStack overlay let the tile
                // stay full-screen but pills were unreachable
                // (focus couldn't traverse spatially); inline-always
                // made pills reachable but permanently shrunk the
                // video. The collapse-when-faded approach gives
                // both: full-screen when watching, inline sibling
                // when interacting.
                // Render the bottom pills only when NOT minimized —
                // when the player shrinks to the corner, we don't
                // want Options / Add Stream as focusable targets
                // inside the tiny mini box. Keeping them mounted
                // (with opacity 0 + height 0) still registers them
                // as focusable Button descendants in SwiftUI's
                // hierarchy, which traps focus in the corner. The
                // `if` guard fully removes them from the view tree
                // while minimized, so the only remaining focusable
                // inside the container is the tile Button (which we
                // also mark `.focusable(false)` when minimized) —
                // net result: zero focusable elements in the mini,
                // and focus naturally flows to the guide beneath.
                if isSoleTile && !nowPlaying.isMinimized {
                    PlaybackBottomChrome_tvOS(
                        store: store,
                        showAddSheet: $showAddSheet,
                        showTVOptions: $showTVOptions,
                        showRecordSheet: $showRecordSheet,
                        focusedChrome: $focusedChrome
                    )
                    .frame(height: chromeState.isVisible ? nil : 0)
                    .opacity(chromeState.isVisible ? 1 : 0)
                    .clipped()
                    .animation(.easeInOut(duration: 0.25), value: chromeState.isVisible)
                    .accessibilityHidden(!chromeState.isVisible)
                    // v1.6.12 (GH #11 follow-up): hard focus trap
                    // when the TVOptions panel is open. The pill row
                    // (Options / Record / Add Stream) is what the
                    // user could D-pad into past Stream Info — its
                    // .focusSection() on the panel side is just a
                    // preference; the focus engine still honored the
                    // directional move because the pill row was
                    // focusable. Disabling makes its buttons
                    // non-focusable and removes the only escape
                    // target, so D-pad-down at the bottom of the
                    // panel just stops there.
                    .disabled(showTVOptions)
                }
                #endif

                if !isSoleTile {
                    // Transport bar spans edge-to-edge with its own
                    // black background — no outer horizontal padding so
                    // it reads as an integrated strip docked at the
                    // bottom, not a floating capsule. At N=1 on the
                    // unified path the PlaybackChromeOverlay's
                    // controls replace it; legacy users always see it.
                    //
                    // When the chrome is faded the transport bar
                    // collapses to height 0 (not just opacity 0) so
                    // the grid can expand into the freed space —
                    // previously this strip reserved ~80pt of
                    // permanent black at the bottom of the screen
                    // even while invisible, which the user flagged
                    // as wasted space.
                    MultiviewTransportBar(
                        store: store,
                        onAdd: { showAddSheet = true },
                        // Exit resumes the audio tile's channel in
                        // single-stream mode — users expect to return
                        // to "the channel I was watching", not to the
                        // guide. Fall-through to `.exit()` (full stop)
                        // only happens when there's no audio tile.
                        onExit: { session.exitMultiviewKeepingAudioTile() }
                    )
                    .frame(height: chromeState.isVisible ? nil : 0)
                    .opacity(chromeState.isVisible ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(chromeState.isVisible)
                    .animation(.easeInOut(duration: 0.25), value: chromeState.isVisible)
                    // v1.6.12 (GH #11 follow-up): while the TVOptions
                    // panel is open, disable focus on the transport
                    // bar so D-pad-down past the last panel row has
                    // nowhere to escape — the panel's `.focusSection()`
                    // is just a preference; the focus engine still
                    // honors directional moves to other focusable
                    // views unless those views are .disabled. With
                    // this guard the panel becomes a true focus trap.
                    #if os(tvOS)
                    .disabled(showTVOptions)
                    #endif
                }
            }

            // N=1 chrome overlay — top bar (iOS) / bottom pill (tvOS).
            // Only mounted for unified-path users at N=1; legacy
            // users get a bare no-op mount (overlay renders nothing)
            // so `showAddSheet` / `chromeState` observers keep
            // working without introducing visible UI.
            if unifiedPath {
                PlaybackChromeOverlay(
                    store: store,
                    showAddSheet: $showAddSheet,
                    showTVOptions: $showTVOptions,
                    sleepTimerEnd: $sleepTimerEnd,
                    showStreamInfo: $showStreamInfo,
                    showRecordSheet: $showRecordSheet
                )
                // (No `.disabled(showTVOptions)` here — on tvOS this
                // overlay is empty by design; the actual chrome pills
                // live in `PlaybackBottomChrome_tvOS` rendered above
                // and that's where the focus-trap disable is wired.)
            }

            #if os(tvOS)
            // Options panel at N=1 on the unified path. Reuses the
            // existing `TVPlayerOptionsPanel` from PlayerView; the
            // only difference is `onEnterMultiview: nil` so the
            // panel doesn't show an "Add Stream" row (our `+` pill
            // peer-sibling covers that). Bound to the audio tile's
            // `PlayerProgressStore` via `store.audioProgressStore`
            // — the chrome overlay can reach back into whichever
            // tile currently holds audio through the registry we
            // added in Phase C.6a.
            //
            // Rendered above the grid but below the thermal /
            // relocate banners. Dismissal: tap an option (panel's
            // own `onDismiss`), Menu button (`.onExitCommand` on
            // the panel), or wait for the 5s chrome fade (we do
            // NOT hide it on fade — a panel open mid-fade would
            // blink; the Options panel has its own lifecycle).
            if isSoleTile,
               showTVOptions,
               let audioStore = store.audioProgressStore,
               let audioTile = store.tiles.first {
                TVPlayerOptionsPanel(
                    audioTracks: audioStore.audioTracks,
                    currentAudioTrackID: audioStore.currentAudioTrackID,
                    subtitleTracks: audioStore.subtitleTracks,
                    currentSubtitleTrackID: audioStore.currentSubtitleTrackID,
                    speed: audioStore.speed,
                    isLive: true,  // multiview is always live-only in v1
                    sleepTimerEnd: $sleepTimerEnd,
                    showStreamInfo: $showStreamInfo,
                    setAudioTrack: { audioStore.setAudioTrackAction?($0) },
                    setSubtitleTrack: { audioStore.setSubtitleTrackAction?($0) },
                    setSpeed: { audioStore.setSpeedAction?($0) },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showTVOptions = false
                        }
                    },
                    // Deliberately nil — `+` pill is a peer action
                    // in `PlaybackChromeOverlay`. Listing "Add Stream"
                    // inside this panel would be a second path to
                    // the same action, which is the workflow the
                    // user explicitly asked us to remove.
                    onEnterMultiview: nil
                )
                // v1.6.12 (GH #11 follow-up): trap D-pad navigation
                // inside the panel. Without `.focusSection()` tvOS
                // lets focus escape down past the last row (Stream
                // Info) into whatever's behind / below the panel —
                // typically the chrome's Options pill — which left
                // the panel still visible but unreachable. The
                // matching pattern lives on PlayerView's panel
                // instance; this brings the multiview path to
                // parity. tvOS strongly prefers to keep focus inside
                // a `focusSection`, so D-pad-down at the bottom of
                // the scroll just stops there instead of leaping
                // out.
                .focusSection()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Audio tile id in the SwiftUI identity so switching
                // audio tile (if that ever happens mid-panel) rebuilds
                // the panel with fresh track lists.
                .id(audioTile.id)
                .onExitCommand {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showTVOptions = false
                    }
                }
            }
            #endif

            if store.relocatingTileID != nil {
                relocateBanner
            }

            if store.isThermallyStressed {
                thermalBanner
            }

        }
        .environmentObject(chromeState)
        // NOTE: intentionally NO `onAppear { chromeState.reportInteraction() }`.
        // Under the new UX the container mounts with chrome hidden
        // (see `MultiviewChromeState.isVisible = false`). The user
        // sees just the stream on a fresh channel start and must
        // press Menu to summon the chrome. Auto-summoning on appear
        // made the first Menu press feel like a no-op because the
        // chrome was technically "visible" but not perceived yet, so
        // the press fell through to the minimize branch.
        //
        // v1.6.15: mirror this container's local chrome visibility
        // up to `NowPlayingManager.chromeIsVisible` so the
        // `ChannelInfoBanner` overlay (which lives in HomeView's
        // outer ZStack, not in this container's environment) can
        // lock its visibility to the same auto-fade timer. Cross-
        // platform — both iPhone/iPad (PlaybackChromeOverlay) and
        // tvOS (inline pills) read the same `chromeState`.
        .onChange(of: chromeState.isVisible) { _, visible in
            nowPlaying.chromeIsVisible = visible
        }
        // v1.6.15: wake chrome only on stream starts that explicitly
        // requested it (cold-launch auto-resume, channel-row tap).
        // Siri Remote up/down flips bump `streamStartedToken` but
        // NOT `chromeWakeToken`, so the channel-scroll path leaves
        // chrome hidden — that way a follow-up up/down keeps flipping
        // channels instead of landing on the chrome's Record pill.
        // The banner still appears on every flip via its own 5s
        // timer driven by `streamStartedToken`.
        .onChange(of: nowPlaying.chromeWakeToken) { _, newToken in
            guard newToken != nil else { return }
            chromeState.reportInteraction()
        }
        #if os(tvOS)
        // Force focus onto the audio tile on mount.
        // `prefersDefaultFocus` is only a HINT — tvOS often ignores
        // it when the container mounts on top of an already-focused
        // view (the channel row the user just Select-pressed to
        // start playback). Without this explicit `@FocusState`
        // write, focus stays on that old channel row, Menu events
        // bypass the container's `.onExitCommand`, and the user has
        // to D-pad (which shifts focus into the container) before
        // Menu can summon chrome. The `Task.yield()` lets tvOS's own
        // focus pass complete first so our write lands last.
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                if let audioID = store.audioTileID {
                    focusedTileID = audioID
                } else if let firstID = store.tiles.first?.id {
                    focusedTileID = firstID
                }
            }
        }
        // When the user minimizes to the corner, tvOS won't release
        // focus from the tile Button on its own — `.focusable(false)`
        // via the tile isn't honoured reliably for a focused view.
        // Post `.forceGuideFocus` so the guide (ChannelListView /
        // EPGGuideView) can programmatically take focus with its
        // own `@FocusState`. This is the only reliable way to move
        // focus off the container on tvOS.
        .onChange(of: nowPlaying.isMinimized) { _, minimized in
            if minimized {
                // Clear local @FocusState so the binding no longer
                // pulls focus to the tile, then post the guide-focus
                // claim.
                focusedTileID = nil
                DebugLogger.shared.log(
                    "[MV-Cmd] minimized → forceGuideFocus",
                    category: "Playback", level: .info
                )
                NotificationCenter.default.post(name: .forceGuideFocus, object: nil)
            } else {
                // v1.6.15: when the player un-minimizes, re-assert
                // focus on the front tile so the container's
                // `.onMoveCommand` (and its up/down channel-flip)
                // receives D-pad events immediately. Without this
                // focus stayed on the tab bar above (UITabBarButton),
                // and the user had to D-pad once just to "wake"
                // focus before any subsequent press did anything —
                // the "must press down first" symptom from internal
                // testing. The tiny `Task.yield()` lets tvOS's own
                // post-expand focus pass complete first so our
                // write lands last.
                if let firstID = store.tiles.first?.id {
                    Task { @MainActor in
                        await Task.yield()
                        focusedTileID = firstID
                    }
                }
            }
        }
        // v1.6.15: re-assert focus on the new front tile whenever
        // the tile id changes — covers the channel-flip path
        // (`changeChannel` → `PlayerSession.exit() + enterMultiview()`)
        // which clears tiles to a fresh id. Without this,
        // `focusedTileID` still pointed at the OLD id (now absent
        // from the focusable set), so the container sat in
        // "ambiguous focus" and dropped the next D-pad press.
        .onChange(of: store.tiles.first?.id) { _, newID in
            guard let newID, !nowPlaying.isMinimized else { return }
            Task { @MainActor in
                await Task.yield()
                focusedTileID = newID
            }
        }
        // v1.6.12 (GH #11 follow-up): pin chrome visibility while
        // the TVOptions panel is open so its 5s auto-fade timer
        // can't strand the panel on a faded background. On
        // dismiss we release the pin and report a fresh
        // interaction so the fade clock starts from "now" rather
        // than picking up where it left off.
        .onChange(of: showTVOptions) { _, showing in
            chromeState.setPinned(showing)
            if !showing {
                chromeState.reportInteraction()
            }
        }
        #endif
        #if os(iOS)
        // iPad: any tap anywhere in multiview reveals chrome +
        // resets the 5s fade timer. `.simultaneousGesture` so it
        // fires alongside the tile's own `.onTapGesture` (which
        // takes audio) rather than stealing it.
        .simultaneousGesture(
            TapGesture().onEnded { chromeState.reportInteraction() }
        )
        #endif
        #if os(tvOS)
        // tvOS: D-pad navigation only wakes the per-tile focus
        // indicator (accent ring + scale + shadow). The bottom
        // chrome (transport bar, Options/Add-Stream pills, scrubber)
        // stays hidden so the user can sweep focus between streams
        // without the UI sliding in every keystroke — per user
        // request, chrome is summoned exclusively by Menu/Back
        // (handled in `.onExitCommand` below).
        //
        // Button actions (Select press on a tile, pill tap, etc.)
        // still call `reportInteraction()` — they're the
        // "I intend to use the chrome" signal. Plain D-pad moves
        // are just "I'm looking around".
        .onMoveCommand { direction in
            // Relocate mode takes priority: when the user picked
            // "Move Tile" from the context menu we need D-pad presses
            // to swap the relocating tile with its neighbour
            // regardless of where tvOS thinks focus is. Handling this
            // at the CONTAINER level (instead of the individual
            // tile's `.onMoveCommand`) dodges the "focus drifted to
            // the audio tile after context-menu dismiss" race:
            // `.onMoveCommand` on a `.focusSection()` fires for any
            // D-pad event while focus is anywhere inside the scope,
            // so the swap runs even if focus is technically on a
            // different tile. The tile's own `.onMoveCommand` stays
            // for historical compatibility (harmless no-op in the
            // common case).
            if let relocatingID = store.relocatingTileID,
               let idx = store.tiles.firstIndex(where: { $0.id == relocatingID }) {
                let neighborDir: MultiviewGridMath.NeighborDirection
                switch direction {
                case .left:  neighborDir = .left
                case .right: neighborDir = .right
                case .up:    neighborDir = .up
                case .down:  neighborDir = .down
                @unknown default: return
                }
                if let neighborIdx = MultiviewGridMath.physicalNeighbor(
                    of: idx,
                    count: store.tiles.count,
                    direction: neighborDir
                ) {
                    let neighborID = store.tiles[neighborIdx].id
                    DebugLogger.shared.log(
                        "[MV-Cmd] tvOS relocate swap (container-level) dir=\(neighborDir) tile=\(relocatingID) neighbor=\(neighborID)",
                        category: "Playback", level: .info
                    )
                    store.swap(relocatingID, neighborID)
                    // Keep focus pinned on the relocating tile after
                    // the swap — its array index changed but its id
                    // didn't, so the `.focused($focusedTileID)`
                    // binding keeps working. Reasserting here covers
                    // the case where tvOS's post-swap focus pass
                    // tried to move focus elsewhere.
                    focusedTileID = relocatingID
                }
                return
            }
            // v1.6.15: Apple TV up/down channel-change. Gated on:
            //   1. Single-stream playback (N=1, full-screen). At N>=2
            //      up/down is grid navigation, not a channel-flip.
            //   2. Player NOT minimized — when shrunk to corner the
            //      remote belongs to the guide behind, not the player.
            //   3. Chrome is HIDDEN. When the user has summoned chrome
            //      via Menu/Back, up/down should navigate to the
            //      Options / Record / Add Stream pills below the tile,
            //      not flip channels behind their back. Pressing
            //      Menu/Back again hides chrome and re-enables flip.
            //   Up = next channel (higher number), Down = previous —
            //   matches the IPTV remote idiom (inverse of guide-list
            //   scroll direction).
            if store.tiles.count == 1,
               !nowPlaying.isMinimized,
               !chromeState.isVisible {
                if direction == .up {
                    nowPlaying.changeChannel(direction: +1)
                    return
                } else if direction == .down {
                    nowPlaying.changeChannel(direction: -1)
                    return
                }
            }
            // Normal navigation: just wake the focus indicator.
            chromeState.reportFocusActivity()
        }
        .onChange(of: chromeState.isVisible) { _, visible in
            // When chrome fades, release any pill focus so the next
            // render restores the tile as the default focus via
            // `.prefersDefaultFocus` — otherwise the focus engine
            // would keep the (now invisible + height-0) pill as its
            // remembered target and D-pad events would get dropped.
            if !visible {
                focusedChrome = nil
            }
        }
        #endif
        .onChange(of: showAddSheet) { _, presenting in
            // Flip `isPickerPresented` whenever the add-sheet opens
            // or closes. Every tile's `MultiviewTileView.shouldPause`
            // reads this and pauses its mpv handle — stops live
            // decode while the picker's channel list is rendering
            // so we don't OOM at 1.8+ GB RSS on Apple TV 4K.
            // Resumes on dismissal.
            store.isPickerPresented = presenting
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
            handleMenuPress(source: "onExitCommand")
        }
        // GH #11 fix: also listen for the .playerBackPress relay so
        // MainTabView's outer `.onExitCommand` (which fires after the
        // user expands from mini back to fullscreen via Play/Pause —
        // focus is still on the guide cell, so the container's own
        // .onExitCommand doesn't fire) routes through the same
        // chrome-cycle logic. Without this, post-expand Back goes
        // directly to `nowPlaying.minimize()` and skips the
        // chrome-reveal step the user expects.
        .onReceive(NotificationCenter.default.publisher(for: .playerBackPress)) { _ in
            handleMenuPress(source: "playerBackPress")
        }
        .onPlayPauseCommand {
            // Siri Remote Play/Pause routing:
            //   - Mini state (container is collapsed to corner) →
            //     EXPAND back to full-screen. The container-level
            //     handler fires even when the outer wrapper is
            //     `.disabled`/hit-testing-off, so we need to
            //     explicitly short-circuit here to reach
            //     `nowPlaying.expand()`. Without this the handler
            //     would toggle pause on the tile while it's still
            //     in the corner — confusing.
            //   - Full-screen state → toggle pause on the audio
            //     tile's mpv handle. Ported from the legacy
            //     PlayerView path (PlayerView.swift ~line 625).
            //     `audioProgressStore` resolves to whichever tile
            //     currently owns audio (tile 0 at N=1, the
            //     user-picked tile at N≥2).
            //
            // In the full-screen case we also call
            // `reportInteraction()` so the scrubber/overlay reflects
            // the new pause state immediately — matches the legacy
            // `showControls = true` after a Play/Pause.
            if NowPlayingManager.shared.isMinimized {
                DebugLogger.shared.log(
                    "[MV-Cmd] tvOS Play/Pause → expand (was mini)",
                    category: "Playback", level: .info
                )
                withAnimation(.spring(response: 0.35)) {
                    NowPlayingManager.shared.expand()
                }
            } else if let toggle = store.audioProgressStore?.togglePauseAction {
                DebugLogger.shared.log(
                    "[MV-Cmd] tvOS Play/Pause → toggle pause on audio tile",
                    category: "Playback", level: .info
                )
                toggle()
                chromeState.reportInteraction()
            }
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showAddSheet) {
            // The real channel picker: Favorites / Recent / All
            // Channels, routed through `MultiviewStore.add(...)`.
            AddToMultiviewSheet(isPresented: $showAddSheet)
                .presentationDetents([.fraction(0.45), .large])
                .presentationDragIndicator(.visible)
        }
        #else
        // tvOS: use `fullScreenCover` instead of `.sheet`. SwiftUI's
        // default sheet on tvOS renders as a small centred modal
        // sized like an iPad form sheet, which truncates the
        // "Add to Multiview" title and crams the channel rows into
        // an unreadable column. Full-screen gives us the whole
        // display to work with and matches how the tvOS system
        // itself surfaces pickers (Settings sheets, AirPlay picker).
        .fullScreenCover(isPresented: $showAddSheet) {
            AddToMultiviewSheet(isPresented: $showAddSheet)
        }
        #endif
        // Record sheet — presented by the Record pill in the tvOS
        // bottom chrome or the iOS top chrome's record button.
        // Populated from the audio tile's currently-playing program
        // via `ChannelDisplayItem`'s EPG fields. Closure-safe: if
        // the audio tile has gone away (user removed the last tile
        // between opening the sheet and it rendering), we render
        // an EmptyView so SwiftUI dismisses the sheet cleanly.
        #if os(iOS)
        .sheet(isPresented: $showRecordSheet) {
            recordSheetContent
        }
        #else
        .fullScreenCover(isPresented: $showRecordSheet) {
            recordSheetContent
        }
        #endif
        // Exit-confirmation dialog. Presented when the user presses
        // Menu/Back with chrome already visible (see the `onExitCommand`
        // comment above for the full Menu stack). Confirming runs
        // the appropriate exit action for the current tile count;
        // cancelling dismisses with no state change. On tvOS the
        // Menu button dismisses the dialog without confirming (SwiftUI
        // built-in), and `reportInteraction()` keeps chrome alive
        // while the dialog is visible so the user isn't stranded
        // staring at faded chrome after they cancel.
        .confirmationDialog(
            exitConfirmationTitle,
            isPresented: $showExitConfirmation,
            titleVisibility: .visible
        ) {
            Button(exitConfirmationPrimary, role: .destructive) {
                performConfirmedExit()
            }
            Button("Cancel", role: .cancel) {
                // Keep chrome alive so the user isn't left staring
                // at faded pills after they back out.
                chromeState.reportInteraction()
            }
        } message: {
            Text(exitConfirmationMessage)
        }
    }

    /// Title for the exit-confirmation dialog. Phrased per tile
    /// count so "Exit multiview?" at N=1 doesn't read as nonsensical
    /// (there's nothing "multi" to exit).
    private var exitConfirmationTitle: String {
        if PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 {
            return "Exit Playback?"
        }
        return "Exit Multiview?"
    }

    /// Primary-button label for the exit-confirmation dialog. Short
    /// imperative verb matching the title's phrasing.
    private var exitConfirmationPrimary: String {
        if PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 {
            return "Exit"
        }
        return "Exit Multiview"
    }

    /// Content for the Record sheet. Resolves the audio tile and
    /// its `ChannelDisplayItem` at render time so the sheet always
    /// reflects the current audio tile — if the user changed audio
    /// focus between tapping Record and the sheet animating in,
    /// they see the latest channel's program, not a stale snapshot.
    /// Renders `EmptyView` only when there's no audio tile or no
    /// stream URL on it — both are unreachable in practice because
    /// the parent `canRecordCurrentProgram*` gate already requires
    /// a stream URL. v1.6.8 (B1 Phase 1): no longer falls through
    /// to `EmptyView` when EPG metadata is missing — Dispatcharr
    /// playlists routinely have no `currentProgram` populated, and
    /// the prior gate left users on those playlists with an
    /// invisible / empty record sheet. The fallback path uses
    /// generic title + a 60-minute default duration that the user
    /// can override via `RecordProgramSheet`'s pre/post-roll
    /// controls.
    @ViewBuilder
    private var recordSheetContent: some View {
        if let audioID = store.audioTileID,
           let audio = store.tiles.first(where: { $0.id == audioID }),
           audio.item.streamURL != nil {
            let now = Date()
            // Title fallback: prefer the EPG-known program name,
            // otherwise the generic "<channel> live recording" so the
            // sheet has something readable when Dispatcharr playlists
            // don't have `currentProgram` populated yet.
            let programTitle: String = audio.item.currentProgram
                ?? "\(audio.item.name) live recording"
            let start: Date = audio.item.currentProgramStart ?? now
            let end: Date = (audio.item.currentProgramEnd
                .flatMap { $0 > now ? $0 : nil })
                ?? now.addingTimeInterval(3600)
            RecordProgramSheet(
                programTitle: programTitle,
                // `RecordProgramSheet.programDescription` is a
                // non-optional `String`; `ChannelDisplayItem` stores
                // it as `String?`. Fall back to an empty string
                // when EPG didn't provide a description (common for
                // short/news programs) — the sheet renders an empty
                // description area cleanly.
                programDescription: audio.item.currentProgramDescription ?? "",
                channelID: audio.item.id,
                channelName: audio.item.name,
                scheduledStart: start,
                scheduledEnd: end,
                // The chrome's Record pill is only enabled when the
                // user is actively watching, so the recording is
                // always "from now" — `isLive: true` drives the
                // "Record from Now" wording + the current-time seek.
                // `hasEPG` only affects the title fallback above
                // (use the program name when known, otherwise the
                // generic "<channel> live recording" string).
                isLive: true,
                dispatcharrChannelID: audio.item.dispatcharrChannelID,
                streamURL: audio.item.streamURL
            )
        } else {
            EmptyView()
        }
    }

    /// Body text for the exit-confirmation dialog. Explains what
    /// happens after tapping the primary button so the user isn't
    /// surprised by the destination view.
    private var exitConfirmationMessage: String {
        if PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 {
            return "Stops playback and returns to the channel guide."
        }
        return "Collapses the grid back to the stream you were listening to. You can re-add streams from the single view."
    }

    /// Run the actual exit action that the confirmation dialog was
    /// guarding. Separated from the `onExitCommand` closure so the
    /// confirmation's Yes-button and any future programmatic exit
    /// path (e.g. iPad toolbar "Exit" button) share one code path.
    private func performConfirmedExit() {
        if PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 {
            // Unified-path N=1: full teardown — HomeView falls
            // through to the Live TV guide / previous tab once
            // mode flips to `.idle`.
            session.stop()
        } else {
            // N>=2 (or legacy N=1 which doesn't hit the unified
            // branch): collapse to the audio tile.
            session.exitMultiviewKeepingAudioTile()
        }
    }

    #if os(tvOS)
    /// Shared Menu/Back handler for the multiview container. Called
    /// from both the container's own `.onExitCommand` (when focus is
    /// inside the focusSection) and `.onReceive(.playerBackPress)`
    /// (when focus is outside — typically the guide cell still
    /// holding focus after Play/Pause re-expanded the mini player).
    /// Routing both inputs to the same method means the chrome cycle
    /// is identical regardless of where focus actually sits.
    ///
    /// Menu stack, innermost → outermost:
    ///   0. Options panel open  → close panel. v1.6.12 (GH #11
    ///                            follow-up): the panel has its own
    ///                            `.onExitCommand` that dismisses it,
    ///                            but if the user scrolls down past
    ///                            the last focusable row inside the
    ///                            panel, tvOS lets focus escape to
    ///                            the chrome below. Back then bubbles
    ///                            past the panel's handler and lands
    ///                            here — without this branch the
    ///                            press would fall through to
    ///                            "minimize" and the panel would stay
    ///                            stuck on-screen. Catching it
    ///                            unconditionally at the top of the
    ///                            stack means Back always closes the
    ///                            panel first regardless of where
    ///                            focus drifted to.
    ///   1. Already minimized   → full teardown (`PlayerSession.stop`).
    ///   2. Fullscreen tile     → collapse back to grid.
    ///   3. Relocate mode       → cancel relocate.
    ///   4. Chrome hidden       → first Menu press summons the
    ///                            bottom UI (Options pill, Add
    ///                            Stream, transport bar). Per user
    ///                            request, D-pad moves do NOT summon
    ///                            chrome — Menu is the dedicated
    ///                            summon gesture.
    ///   5a. Chrome visible at N=1 (unified single-stream)
    ///                          → MINIMIZE to the corner mini
    ///                            player. The user then sees the
    ///                            guide with the stream still
    ///                            playing; further Menu on the guide
    ///                            stops playback.
    ///   5b. Chrome visible at N≥2 → "Exit Multiview?" confirmation.
    ///                            Guard against accidental Menu-
    ///                            spams that would otherwise tear
    ///                            down a carefully arranged grid.
    private func handleMenuPress(source: String) {
        DebugLogger.shared.log(
            "[MV-Cmd] tvOS Menu source=\(source) | showTVOptions=\(showTVOptions) isMinimized=\(nowPlaying.isMinimized) chromeVisible=\(chromeState.isVisible) tiles=\(store.tiles.count) fullscreenTile=\(store.fullscreenTileID ?? "nil") relocating=\(store.relocatingTileID ?? "nil")",
            category: "Playback", level: .info
        )
        if showTVOptions {
            DebugLogger.shared.log(
                "[MV-Cmd]   → branch: TVOptions panel open → close panel",
                category: "Playback", level: .info
            )
            withAnimation(.easeInOut(duration: 0.15)) {
                showTVOptions = false
            }
            // Keep chrome alive so the user lands on the Options pill
            // they just dismissed from rather than a fading bottom
            // bar — same UX choice as the panel's own .onExitCommand
            // for in-panel dismiss.
            chromeState.reportInteraction()
            return
        }
        if nowPlaying.isMinimized {
            DebugLogger.shared.log(
                "[MV-Cmd]   → branch: minimized → stop",
                category: "Playback", level: .info
            )
            PlayerSession.shared.stop()
        } else if store.fullscreenTileID != nil {
            DebugLogger.shared.log(
                "[MV-Cmd]   → branch: fullscreen tile → collapse to grid",
                category: "Playback", level: .info
            )
            store.fullscreenTileID = nil
        } else if store.relocatingTileID != nil {
            DebugLogger.shared.log(
                "[MV-Cmd]   → branch: relocate mode → cancel",
                category: "Playback", level: .info
            )
            store.relocatingTileID = nil
        } else if !chromeState.isVisible {
            DebugLogger.shared.log(
                "[MV-Cmd]   → branch: chrome hidden → summon chrome",
                category: "Playback", level: .info
            )
            chromeState.reportInteraction()
        } else {
            let isSoleStreamUnified = PlaybackFeatureFlags.useUnifiedPlayback
                && store.tiles.count == 1
            if isSoleStreamUnified {
                DebugLogger.shared.log(
                    "[MV-Cmd]   → branch: chrome visible + N=1 → minimize",
                    category: "Playback", level: .info
                )
                NowPlayingManager.shared.minimize()
            } else {
                DebugLogger.shared.log(
                    "[MV-Cmd]   → branch: chrome visible + N>=2 → confirm exit",
                    category: "Playback", level: .info
                )
                showExitConfirmation = true
            }
        }
    }
    #endif

    // MARK: - Grid

    @ViewBuilder
    private var gridArea: some View {
        // `isSoleTile` is N=1 — the tile is effectively the whole
        // player. `MultiviewTileView` reads it to suppress its own
        // corner chrome (audio badge, label strip, close X) so the
        // container-level `PlaybackChromeOverlay` can paint a
        // top-bar Close + Title without duplicating per-tile chrome.
        // Gated on the unified-playback feature flag so legacy
        // multiview users who hit N=1 mid-session (by removing a
        // tile from N=2) keep ALL their per-tile chrome including
        // the close × — otherwise they'd have no way to remove the
        // last tile. User-facing fullscreen-within-grid
        // (fullscreenTileID set) is still technically N>1 behind
        // the scenes, so we leave `isSoleTile = false` there.
        let isSole = PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1

        if let fullscreenID = store.fullscreenTileID,
           let fullscreenTile = store.tiles.first(where: { $0.id == fullscreenID }) {
            // Fullscreen-within-grid: render only that tile at full
            // size. The menu button / Esc still works because the
            // menu action flips `fullscreenTileID` back to nil. Other
            // tiles keep decoding (no pause) so when we come back
            // they're already at live edge.
            MultiviewTileView(tile: fullscreenTile, store: store)
        } else {
            let grid = MultiviewLayoutView(tiles: store.tiles, spacing: tileSpacing) { tile in
                #if os(tvOS)
                MultiviewTileView(tile: tile, store: store, isSoleTile: isSole)
                    .prefersDefaultFocus(store.audioTileID == tile.id, in: focusNS)
                    // Bind each tile to the container's `focusedTileID`
                    // `@FocusState`. Normal navigation: the binding
                    // tracks the focus engine (SwiftUI updates the
                    // published value as focus moves). Relocate mode:
                    // we programmatically SET the binding below (see
                    // `.onChange(of: store.relocatingTileID)`) which
                    // forces focus onto the tile the user wants to
                    // move, so D-pad presses reach that tile's
                    // `.onMoveCommand` and actually trigger swaps.
                    .focused($focusedTileID, equals: tile.id)
                #else
                MultiviewTileView(tile: tile, store: store, isSoleTile: isSole)
                #endif
            }
            #if os(tvOS)
            grid
                .focusSection()
                .focusScope(focusNS)
                // When the user picks "Move Tile" in the context
                // menu, the menu dismisses and tvOS re-evaluates
                // focus. `prefersDefaultFocus` then yanks focus to
                // the audio tile, stranding relocate mode on an
                // unfocused tile. Detecting the relocate-start edge
                // here and re-asserting focus on the relocating tile
                // is what makes "Move Tile → D-pad → swap" actually
                // work. The reassertion is asynchronous via a tiny
                // Task.yield so it runs AFTER tvOS's own focus pass
                // completes — otherwise our write can be overridden.
                .onChange(of: store.relocatingTileID) { _, newID in
                    guard let newID else { return }
                    Task { @MainActor in
                        await Task.yield()
                        focusedTileID = newID
                    }
                }
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
        // Banner text differs per-platform because the input model
        // does: tvOS drives swaps from the Siri Remote D-pad
        // (handled in `MultiviewContainerView.onMoveCommand`), iPad
        // commits swaps by tapping a second tile (handled in
        // `MultiviewTileView.tappableRegion.onTapGesture`). Keep
        // the orange capsule styling identical so the visual
        // affordance reads the same across devices.
        #if os(tvOS)
        let message = "Move Tile — use arrows; press Menu to finish"
        #else
        let message = "Move Tile — tap a tile to swap, or tap again to cancel"
        #endif
        return VStack {
            HStack {
                Spacer()
                Label(
                    message,
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

// MARK: - Chrome auto-fade state

/// Tracks whether multiview's supplementary chrome (transport bar,
/// per-tile audio badge, per-tile channel-name strip) is currently
/// visible. After 5s of inactivity the chrome fades out so the
/// video grid is unobstructed; the next user interaction fades it
/// back in and restarts the timer.
///
/// "Interaction" means:
/// - iPad: any tap (container's `.simultaneousGesture` catches the
///   tap alongside whatever tile gesture it may belong to)
/// - tvOS: any D-pad move OR any button action (the button's
///   action closure calls `reportInteraction()` before running)
///
/// Focus rings and relocate rings are NOT part of the faded chrome
/// — they stay visible because they're critical navigation
/// feedback, not decorative chrome.
@MainActor
final class MultiviewChromeState: ObservableObject {
    /// `true` while the chrome should be visible; `false` once the
    /// 5s idle timer fires. SwiftUI observers wrap this in an
    /// `.animation` so the transition is a fade, not a snap.
    ///
    /// **Chrome** here means the heavy UI: bottom transport bar, the
    /// Options / Add-Stream pills, the N=1 scrubber, etc. It does NOT
    /// include the per-tile focus ring — that's governed by
    /// `focusIndicatorVisible` below so the user can navigate
    /// between tiles without the bottom bar swinging in every time.
    ///
    /// Starts at `false` — the user sees a clean, flush stream on
    /// mount and only the explicit Menu-button press summons the
    /// chrome. Previously this was `true` with an auto-fade to
    /// hidden after 5 s, but that meant Menu pressed *during* the
    /// initial visible window fell through to the "chrome is up, so
    /// this must be the 2nd press → minimize" branch — which looked
    /// like Menu did nothing because the chrome was so subtle the
    /// user hadn't perceived it as "up" yet.
    @Published var isVisible: Bool = false

    /// `true` while the per-tile focus indicator (accent-colored
    /// ring, scale, shadow) should be visible. Bumps on every D-pad
    /// move via `reportFocusActivity()`, fades back after 5s idle.
    ///
    /// Kept separate from `isVisible` so d-pad navigation doesn't
    /// drag the transport bar in with it — the user asked for a
    /// less-jarring "highlight only" experience where the streams
    /// stay full-screen while focus moves between them, and only the
    /// Menu button summons the bottom UI.
    @Published var focusIndicatorVisible: Bool = true

    /// v1.6.12: when `true`, `isVisible` is pinned to `true` and the
    /// auto-hide task is suppressed regardless of how much time has
    /// passed since the last interaction. Used by `MultiviewContainerView`
    /// while the TVOptions panel is open — without it the chrome
    /// would fade out 5s after the panel was summoned, which left
    /// the panel hovering on a fully-faded background and the user
    /// unable to dismiss back to the chrome state. Toggle via
    /// `setPinned(_:)` so any in-flight hide task is cancelled
    /// atomically with the flag change.
    @Published private(set) var isPinned: Bool = false

    /// Cancellable auto-hide task for the full chrome.
    private var hideTask: Task<Void, Never>?

    /// Cancellable auto-hide task for the focus indicator.
    private var focusHideTask: Task<Void, Never>?

    /// Monotonic timestamp of the most-recent `reportInteraction()`
    /// call that actually rescheduled the hide task. Used to coalesce
    /// high-frequency events: D-pad sweep on tvOS can fire Button
    /// actions 20+ times per second, and each `Task` cancel+create
    /// does a few allocations + a MainActor hop. Since the hide
    /// deadline is 5s out, a reschedule in the first 500ms after
    /// a previous reschedule is redundant — the user still has
    /// 4.5s of visible chrome either way.
    private var lastRescheduleAt: ContinuousClock.Instant?

    /// Minimum time between reschedules. Calls within this window of
    /// a prior reschedule early-return if chrome is already visible.
    /// Chosen at 500ms — well under any human repeat-interaction
    /// cadence but above the tvOS focus-engine's fastest sweep.
    private static let rescheduleCoalesceThresholdMs = 500

    /// Delay before auto-hide fires after the last interaction.
    private static let fadeDelayNs: UInt64 = 5_000_000_000

    /// Reveal chrome + reset the 5s timer. Safe to call as often as
    /// wanted — the cancel+reschedule loop is the whole point, but
    /// the 500ms coalesce guard stops D-pad/focus bursts from
    /// churning `Task` allocations.
    func reportInteraction() {
        let now = ContinuousClock.now
        // Fast path: chrome is already visible AND we just
        // rescheduled within the last 500ms. Dropping this call
        // still leaves > 4s of visible chrome, so it's indistinct
        // from the caller's POV.
        if isVisible, let last = lastRescheduleAt {
            let elapsed = last.duration(to: now)
            if elapsed < .milliseconds(Self.rescheduleCoalesceThresholdMs) {
                return
            }
        }

        if !isVisible {
            withAnimation(.easeInOut(duration: 0.25)) {
                isVisible = true
            }
        }
        // Chrome showing implies the focus indicator should be
        // visible too (the user is clearly interacting). This lets
        // tile taps / pill clicks that already call
        // `reportInteraction()` keep the focus ring alive without
        // each call site having to double-bump.
        reportFocusActivity()
        lastRescheduleAt = now
        hideTask?.cancel()
        // While pinned (e.g. TVOptions panel open), don't even
        // schedule the hide task — chrome stays up until the pin
        // is released by the panel-close path.
        guard !isPinned else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.fadeDelayNs)
            guard !Task.isCancelled, let self else { return }
            // Re-check the pin at fire time too — pin may have been
            // set during the 5s sleep (the panel could open after
            // chrome was summoned), in which case we skip the hide
            // and the panel-close path will reschedule a fresh
            // interaction.
            guard !self.isPinned else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                self.isVisible = false
            }
        }
    }

    /// v1.6.12: pin chrome visibility on or off. While `pinned ==
    /// true`, `isVisible` is force-set to `true` and any in-flight
    /// hide task is cancelled — auto-hide is fully suppressed.
    /// Releasing the pin (`setPinned(false)`) doesn't immediately
    /// hide the chrome; it just lets the next `reportInteraction()`
    /// reschedule a fresh fade timer. Callers typically follow
    /// `setPinned(false)` with `reportInteraction()` to start the
    /// fade clock from now.
    func setPinned(_ pinned: Bool) {
        guard isPinned != pinned else { return }
        isPinned = pinned
        if pinned {
            hideTask?.cancel()
            if !isVisible {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isVisible = true
                }
            }
        }
    }

    /// Reveal the focus indicator (tile ring / scale / shadow) and
    /// reset its own 5-second fade timer, **without** touching
    /// chrome visibility. Called on every D-pad move from the grid
    /// so the user can navigate between streams without the bottom
    /// UI sweeping in with the focus change.
    ///
    /// Chrome visibility is a separate signal — `reportInteraction()`
    /// brings chrome in; Menu/Back (`onExitCommand`) also does. This
    /// method is the minimum "the user is pointing at something"
    /// signal for focus feedback only.
    func reportFocusActivity() {
        if !focusIndicatorVisible {
            withAnimation(.easeInOut(duration: 0.18)) {
                focusIndicatorVisible = true
            }
        }
        focusHideTask?.cancel()
        focusHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.fadeDelayNs)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                self.focusIndicatorVisible = false
            }
        }
    }
}

