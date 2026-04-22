import SwiftUI

/// Playback chrome for the unified `MultiviewContainerView` — the
/// parts of the UI that sit *on top* of the tile grid (top bar on
/// iOS, bottom pills on tvOS). Branches on `tiles.count == 1` so
/// the N=1 case gets PlayerView-style top chrome while N>1 relies
/// on the existing `MultiviewTransportBar` docked below.
///
/// Phase C.4 scope — minimum-viable overlay:
/// - iOS N=1: top bar with Close (×) on the right and `+` next to
///   it. Title shown between them. No AirPlay / overflow / scrubber
///   yet — those are a Phase C.6 port of `PlayerView`'s rich chrome.
/// - tvOS N=1: a single `+` pill at bottom-center. Options pill +
///   full per-tile controls come in Phase C.6.
/// - N>1 on either platform: the overlay renders nothing; the
///   existing `MultiviewTransportBar` handles tile count + `+` + `×`.
///
/// Chrome auto-fade is honoured via the injected `MultiviewChromeState`
/// — same environment object the transport bar reads, so the top
/// bar fades in/out together with the bottom bar when the user goes
/// idle.
///
/// Focus-halo discipline: every tvOS button uses
/// `TVNoHighlightButtonStyle` (`Components.swift:10`) which
/// suppresses the default white system halo — the ButtonStyle reads
/// `@Environment(\.isFocused)` inside its label to paint its own
/// focus ring. That was the pattern already used for PlayerView's
/// Options pill; adopting it verbatim here avoids the regression
/// we hit in an earlier iteration where the tvOS focus halo fought
/// with our custom chrome.
struct PlaybackChromeOverlay: View {
    @ObservedObject var store: MultiviewStore

    /// Bound from the container. Tapping `+` flips this to `true` so
    /// the container's `.sheet` / `.fullScreenCover` presents the
    /// channel picker. Keeping the sheet state on the container
    /// (instead of here) means the add-sheet survives even if the
    /// chrome overlay itself unmounts for any reason.
    @Binding var showAddSheet: Bool

    /// Bound from the container. `true` while the tvOS Options panel
    /// is showing. Kept on the container (not here) so the panel's
    /// dismiss path in the container's `.onExitCommand` can reach
    /// it — and so the panel's sleep-timer / stream-info bindings
    /// (which are also container-owned @State) live next to the
    /// presentation flag.
    @Binding var showTVOptions: Bool

    /// Sleep-timer + stream-info state bound from the container.
    /// The iOS overflow menu (added in this phase) needs to read and
    /// write both. Declared here as bindings so the container remains
    /// the single source of truth — same rationale as `showTVOptions`.
    @Binding var sleepTimerEnd: Date?
    @Binding var showStreamInfo: Bool

    /// Bound from the container. Tapping the iOS Record button flips
    /// this true; container presents `RecordProgramSheet` via
    /// `.sheet` — matches the pattern used for `showAddSheet`.
    @Binding var showRecordSheet: Bool

    /// Drives the 5-second auto-fade of chrome. Container owns it;
    /// we read `isVisible` to gate opacity + hit-testing, and call
    /// `reportInteraction()` on every button action to bump the
    /// timer.
    @EnvironmentObject private var chromeState: MultiviewChromeState

    #if !os(tvOS)
    /// Drives the iPhone-portrait title layout — moves the channel +
    /// program strip below the button row when we're tall, keeps it
    /// inline between buttons otherwise. On iPhone, `verticalSizeClass`
    /// is `.regular` in portrait and `.compact` in landscape.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// True only on an actual iPhone held in portrait. iPad keeps the
    /// inline layout regardless of orientation because it has enough
    /// horizontal room for the title between buttons; iPhone landscape
    /// keeps inline too (the horizontal bar is short enough that
    /// vertically stacking would eat valuable vertical space).
    private var isiPhonePortrait: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .regular
    }
    #endif

    var body: some View {
        // This overlay ONLY renders the iOS top bar at N=1. tvOS
        // chrome (Options pill + Add pill + live progress band) is
        // mounted inline inside `MultiviewContainerView`'s VStack
        // so the focus engine can route D-pad-down from the tile to
        // the pills — a ZStack overlay doesn't give tvOS the
        // spatial separation it needs. See `PlaybackBottomChrome_tvOS`
        // in this file.
        #if !os(tvOS)
        if store.tiles.count == 1 {
            ZStack {
                // Audio-Only foreground cover. Drawn BEHIND the top
                // chrome so Close / Overflow / + remain tappable — the
                // user needs access to the overflow menu to exit
                // Audio-Only mode. Nothing renders unless the audio
                // tile has its `isAudioOnly` flag set, so the default
                // video-playing case pays zero overhead.
                if let audio = store.audioProgressStore {
                    AudioOnlyForegroundOverlay(
                        progressStore: audio,
                        title: soleTileTitle
                    )
                }
                soleTileChrome_iOS
                    .opacity(chromeState.isVisible ? 1 : 0)
                    .allowsHitTesting(chromeState.isVisible)
                    .animation(.easeInOut(duration: 0.25), value: chromeState.isVisible)
                    .accessibilityHidden(!chromeState.isVisible)
            }
        }
        #else
        EmptyView()
        #endif
        // N > 1 on either platform: transport bar handles chrome,
        // nothing rendered here.
    }

    /// Title of the sole tile (or empty). Drawn in the iOS top bar
    /// and announced by VoiceOver on both platforms.
    private var soleTileTitle: String {
        store.tiles.first?.item.name ?? ""
    }

    #if !os(tvOS)
    /// Dynamic top inset for the N=1 chrome. Adapts to the device in
    /// real time — no hardcoded "iPhone Pro Max needs X pt" branching,
    /// no guessing based on user-agent. Every iPhone, iPad, and Mac
    /// Catalyst layout falls out of the public safe-area / status-bar
    /// APIs. See the comment at the `.padding(.top, dynamicTopInset)`
    /// call site for the full reasoning.
    private var dynamicTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first

        // Window safe area inset. `.first { $0.isKeyWindow }` can return
        // nil mid-transition, so we fall back to any window of the scene.
        let windowInset: CGFloat = {
            guard let scene else { return 0 }
            if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                return key.safeAreaInsets.top
            }
            return scene.windows.first?.safeAreaInsets.top ?? 0
        }()

        // Status-bar frame height — an independent measurement that iOS
        // updates alongside layout changes (orientation, status-bar
        // hiding, etc.). Identical to `windowInset` in most cases, but
        // picks up scenarios where the latter was zeroed by an ancestor
        // `.ignoresSafeArea()`.
        let statusBarHeight = scene?.statusBarManager?.statusBarFrame.height ?? 0

        // Per-orientation floor. In landscape on iPhone the reported
        // inset is usually 0 (no status bar; side notch doesn't affect
        // the top edge), so the 48pt floor we used to apply universally
        // pushed the Close / Overflow / Add buttons noticeably lower
        // than they should sit (#22 feedback). Landscape gets a 20pt
        // floor instead, which hugs the top edge while still clearing
        // rounded-corner insets and the hardware camera cutout.
        // Portrait keeps the 48pt floor so the chrome clears a compact
        // Live Activity pill or a short status bar on non-notch phones.
        let idiomIsPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isLandscapePhone: Bool = {
            guard idiomIsPhone else { return false }
            return scene?.interfaceOrientation.isLandscape ?? false
        }()
        let floor: CGFloat = isLandscapePhone ? 20 : 48

        // Take the max so we always pick up the larger of the two
        // reported values, then add a 12pt breathing constant.
        return max(max(windowInset, statusBarHeight) + 12, floor)
    }
    #endif

    // MARK: - iOS N=1 top bar

    #if !os(tvOS)
    /// iOS top bar for the N=1 case. Layout mirrors today's
    /// PlayerView top bar (Close on the left, Title centred, then
    /// overflow `⋯` and `+` on the right). AirPlay + Stream-Info
    /// overlay join in a later Phase C.6 pass.
    ///
    /// The overflow menu only mounts when we can find the audio
    /// tile's `PlayerProgressStore` via `MultiviewStore.audioProgressStore`
    /// — without it we can't bind tracks / speed / PiP toggle to
    /// real state. It's typically non-nil within one frame of
    /// `MultiviewTileView.onAppear` firing, so in practice the user
    /// just sees the menu appear as the tile becomes playable.
    @ViewBuilder
    private var soleTileChrome_iOS: some View {
        VStack(spacing: 0) {
            // Button row. In iPhone portrait we deliberately drop the
            // inline title from this row and mount it on its own full-width
            // row below — otherwise the channel name + program name get
            // squeezed between Close and the Overflow/+ cluster and
            // truncate inside a ~160pt gap that can't hold them.
            HStack(alignment: .center, spacing: 12) {
                closeButton_iOS
                if !isiPhonePortrait {
                    Spacer(minLength: 8)
                    titleInlineLabel_iOS
                    Spacer(minLength: 8)
                } else {
                    Spacer(minLength: 0)
                }
                if let audio = store.audioProgressStore {
                    iPadOverflowAdapter(
                        progressStore: audio,
                        sleepTimerEnd: $sleepTimerEnd,
                        showStreamInfo: $showStreamInfo,
                        canRecord: canRecordCurrentProgram_iOS,
                        onRecord: {
                            chromeState.reportInteraction()
                            showRecordSheet = true
                        }
                    )
                }
                addButton_iOS
            }
            .padding(.horizontal, 16)
            // Dynamic top inset — not a hardcoded constant, and not a
            // device-specific bump. We read the two public signals iOS
            // exposes for "how far down the chrome should start":
            //
            //   • window.safeAreaInsets.top  → reflects notch / Dynamic
            //     Island cutout on iPhone Pro devices (~59pt) and the
            //     status-bar height on iPad (~24pt) / old iPhones (~20pt)
            //   • statusBarManager.statusBarFrame.height → usually matches
            //     the above but picks up some layouts where safeAreaInsets
            //     is zeroed (e.g., inside an ancestor using
            //     `.ignoresSafeArea()`, which is exactly our situation —
            //     the container zeroes the safe area for its children)
            //
            // The max of the two is "what iOS thinks the top is right
            // now." We add a small constant (12pt) for breathing room
            // and floor at 48pt so the chrome never looks cramped on
            // devices that report abnormally small insets (iPad
            // landscape, older home-button iPhones). No device model
            // probing, no manual bumps per form factor.
            .padding(.top, dynamicTopInset)

            // iPhone-portrait only: dedicated title row below the buttons.
            // Gets the full horizontal width so the channel name and
            // currently-airing program name both render in full. Since
            // we're in portrait the video is letterboxed anyway — this
            // row overlays black bars, not the stream itself.
            if isiPhonePortrait {
                titleStack_iPhonePortrait
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
            liveProgressBand
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(
            // Top gradient matches the rest of the app's in-player
            // chrome: solid black at the top fading to transparent
            // below, so controls stay legible over video content.
            LinearGradient(
                colors: [Color.black.opacity(0.65), Color.clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(maxHeight: 140)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false),
            alignment: .top
        )
        // Bottom gradient for the live-progress band readability.
        // Independent from the top gradient so the middle of the
        // video stays untinted.
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(maxHeight: 110)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false),
            alignment: .bottom
        )
    }

    private var closeButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            PlayerSession.shared.stop()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close player")
        .accessibilityHint("Stop playback and return to the guide")
    }

    /// Inline title used in the button-row HStack for iPad and iPhone
    /// landscape. Single line, truncates if it runs out of room between
    /// the Close button and the right-hand cluster. iPhone portrait
    /// swaps this for `titleStack_iPhonePortrait` below, which takes a
    /// full-width row of its own.
    private var titleLabel_iOS: some View {
        Text(soleTileTitle)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Currently playing channel")
    }

    /// Alias kept so inline call sites stay readable. Same behavior as
    /// `titleLabel_iOS`.
    private var titleInlineLabel_iOS: some View { titleLabel_iOS }

    /// iPhone-portrait title block. Gets its own row below the button
    /// cluster with the full screen width to itself — no more getting
    /// squeezed between pill buttons. Shows channel name on top, the
    /// currently-airing program name underneath (when EPG is known),
    /// and the start-end time range under that. Three short lines beat
    /// a truncated single line for the user's "what am I watching?"
    /// test.
    private var titleStack_iPhonePortrait: some View {
        let tile = store.tiles.first
        let program = tile?.item.currentProgram ?? ""
        let start = tile?.item.currentProgramStart
        let end = tile?.item.currentProgramEnd

        return VStack(alignment: .leading, spacing: 2) {
            Text(soleTileTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            if !program.isEmpty {
                Text(program)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            if let start, let end {
                HStack(spacing: 4) {
                    Text(start, style: .time)
                    Text("–")
                    Text(end, style: .time)
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var addButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            showAddSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add stream")
        .accessibilityHint("Pick another channel to watch alongside this one")
    }

    /// Record button in the iOS top chrome — same 52×52 round pill
    /// as Close / `+` / AirPlay, with a red record-dot icon to
    /// match the system recording vocabulary. Tapping presents
    /// `RecordProgramSheet` for the audio tile's current program,
    /// saving the user a trip back to the guide + long-press.
    /// True when the audio tile has live EPG data so recording the
    /// currently-playing program is meaningful. Gates the iOS
    /// Record pill — streams with no EPG (raw M3U / missing tvg-id)
    /// hide the button entirely.
    private var canRecordCurrentProgram_iOS: Bool {
        guard let audioID = store.audioTileID,
              let audio = store.tiles.first(where: { $0.id == audioID })
        else { return false }
        return audio.item.currentProgram?.isEmpty == false
    }

    #endif

    // MARK: - Live program progress band

    /// Program-name + progress-bar + time-remaining strip, ported
    /// from `PlayerView.liveProgressSection` (`PlayerView.swift:953-1007`).
    /// Reads program metadata off the sole tile's
    /// `ChannelDisplayItem`. Renders nothing when the current
    /// program isn't known (no `currentProgramStart` / `End`),
    /// which keeps the chrome clean at boot and for channels
    /// without EPG data.
    ///
    /// Non-focusable — it's informational. Hardware Play/Pause on
    /// tvOS, on-screen toggle on iOS still drives the Coordinator's
    /// `togglePauseAction`; the band is purely display.
    @ViewBuilder
    private var liveProgressBand: some View {
        if let tile = store.tiles.first,
           let start = tile.item.currentProgramStart,
           let end = tile.item.currentProgramEnd {
            let now = Date()
            let total = end.timeIntervalSince(start)
            let elapsed = now.timeIntervalSince(start)
            let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 0
            let remaining = max(0, end.timeIntervalSince(now))
            let mins = Int(remaining / 60)
            let remainingText = mins > 0 ? "\(mins) min remaining" : "Ending soon"
            let programName = tile.item.currentProgram ?? ""

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.2))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)

                HStack {
                    if !programName.isEmpty {
                        Text(programName)
                            #if os(tvOS)
                            .font(.system(size: 18, weight: .medium))
                            #else
                            .font(.system(size: 12, weight: .medium))
                            #endif
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(remainingText)
                        #if os(tvOS)
                        .font(.system(size: 18, weight: .medium))
                        #else
                        .font(.system(size: 12, weight: .medium))
                        #endif
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                programName.isEmpty
                    ? "\(remainingText)"
                    : "\(programName), \(remainingText)"
            )
        }
    }
}

// MARK: - iPadOS overflow-menu adapter

#if !os(tvOS)
/// Thin wrapper that `@ObservedObject`s the audio tile's
/// `PlayerProgressStore` so SwiftUI re-renders the overflow menu
/// when audio/subtitle track lists, speed, sleep timer, or PiP
/// state change. Declared as a nested struct because `@ObservedObject`
/// has to live on a `View` and `PlaybackChromeOverlay` doesn't
/// directly hold the store (the store lookup is conditional on the
/// audio tile being registered, which happens asynchronously).
///
/// Wiring notes:
/// - Picture-in-Picture has no menu entry — PiP is swipe-home-only
///   (auto-PiP) and is gated by the Settings toggle. The
///   single-stream Coordinator builds the AVPictureInPictureController
///   eagerly in `makeUIViewController`; multiview currently does not
///   auto-PiP (known gap).
/// - `toggleStreamInfo` is a cosmetic state flip for now — the
///   stream-info overlay is a later Phase C.6 port.
/// - `toggleAudioOnly` mutates `progressStore.isAudioOnly` on the
///   audio tile's store. `PlaybackChromeOverlay` observes the same
///   store via `AudioOnlyForegroundOverlay` (below) and renders the
///   dark-wash + artwork foreground treatment when the flag is set.
///   Background-audio discipline (audio keeps playing with the app
///   closed when Audio-Only is on) is already honoured by
///   `Coordinator.didEnterBackground` via the same flag.
/// - `onMenuOpen`/`Close` are no-ops here. In legacy `PlayerView`
///   they gated the 4s controls-hide timer; the unified chrome
///   uses `MultiviewChromeState` which is already driven by any
///   user interaction, so the menu open/close doesn't need special
///   handling.
private struct iPadOverflowAdapter: View {
    @ObservedObject var progressStore: PlayerProgressStore
    @Binding var sleepTimerEnd: Date?
    @Binding var showStreamInfo: Bool
    /// Gates the "Record Current Program" menu item. Passed down from
    /// `PlaybackChromeOverlay` which computes it from the audio tile's
    /// live EPG state (`canRecordCurrentProgram_iOS`).
    let canRecord: Bool
    /// Fired from the menu. The overlay flips `showRecordSheet` so the
    /// container presents `RecordProgramSheet`.
    let onRecord: () -> Void

    var body: some View {
        PlayerOverflowMenu(
            audioTracks: progressStore.audioTracks,
            currentAudioTrackID: progressStore.currentAudioTrackID,
            subtitleTracks: progressStore.subtitleTracks,
            currentSubtitleTrackID: progressStore.currentSubtitleTrackID,
            speed: progressStore.speed,
            isLive: true,  // multiview is always live-only in v1
            sleepTimerEnd: sleepTimerEnd,
            showStreamInfo: showStreamInfo,
            isAudioOnly: progressStore.isAudioOnly,
            canRecord: canRecord,
            setAudioTrack: { [weak progressStore] in progressStore?.setAudioTrackAction?($0) },
            setSubtitleTrack: { [weak progressStore] in progressStore?.setSubtitleTrackAction?($0) },
            setSpeed: { [weak progressStore] in progressStore?.setSpeedAction?($0) },
            setSleepTimer: { newEnd in sleepTimerEnd = newEnd },
            toggleStreamInfo: { showStreamInfo.toggle() },
            toggleAudioOnly: { [weak progressStore] in
                // Flip the audio tile's flag. This drives:
                //   (a) the menu icon ("music.note" ↔ "video.fill")
                //       via the iAudioOnly binding passed on the next
                //       re-render of iPadOverflowAdapter,
                //   (b) AudioOnlyForegroundOverlay (observing the
                //       same store) to fade the dark-wash cover in
                //       or out, and
                //   (c) didEnterBackground to keep audio alive when
                //       the app backgrounds.
                guard let store = progressStore else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    store.isAudioOnly.toggle()
                }
            },
            recordAction: onRecord,
            onMenuOpen: nil,
            onMenuClose: nil
        )
    }
}

// MARK: - Audio-Only foreground overlay

/// Dark-wash cover drawn over the sole video tile when the user has
/// flipped Audio Only in the overflow menu. Mirrors the legacy
/// `PlayerView.audioOnlyBackground` visual treatment (gradient +
/// music-note circle + channel name + "Audio Only" caption) so the
/// unified-player path looks the same to the user.
///
/// We deliberately do NOT touch mpv's `vid` property from the
/// foreground — parity with legacy behaviour. The video tile keeps
/// decoding underneath us; this overlay simply hides it. The GPU
/// cost is acceptable for the foreground case; the real power saving
/// kicks in on swipe-home, where `Coordinator.didEnterBackground`
/// sets `vid=no` for audio-only mode.
///
/// Separated from `iPadOverflowAdapter` so it can mount at the
/// chrome-overlay level (behind the top bar) rather than inside the
/// HStack of menu buttons.
private struct AudioOnlyForegroundOverlay: View {
    @ObservedObject var progressStore: PlayerProgressStore
    let title: String

    var body: some View {
        ZStack {
            if progressStore.isAudioOnly {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "0A0F0D"), Color(hex: "111916")],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .fill(Color.accentPrimary.opacity(0.15))
                                .frame(width: 140, height: 140)
                            Image(systemName: "music.note")
                                .font(.system(size: 56, weight: .light))
                                .foregroundStyle(LinearGradient.accentGradient)
                        }
                        .shadow(color: Color.accentPrimary.opacity(0.3), radius: 30)

                        Text(title)
                            .font(.title2.bold())
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Text("Audio Only")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Audio only: \(title)")
                .accessibilityHint("Video is hidden. Audio continues playing. Tap the options button to show video.")
            }
        }
        // Animate flag transitions even when the parent doesn't wrap
        // the toggle in withAnimation. Keeps the fade consistent across
        // entry points (menu tap here, mirroring from elsewhere later).
        .animation(.easeInOut(duration: 0.25), value: progressStore.isAudioOnly)
    }
}
#endif

// MARK: - tvOS bottom chrome (inline below the tile)

#if os(tvOS)
/// Dedicated tvOS N=1 chrome that mounts INLINE inside
/// `MultiviewContainerView`'s root VStack, right below the grid
/// area. Contains the live program progress band and the twin
/// Options / Add Stream pills.
///
/// Why not a ZStack overlay like iOS? On tvOS an overlay that
/// fills the container puts the pills in the same "focus region"
/// as the sole tile above them — the focus engine can't route
/// D-pad-down from the tile to the pills because spatially they
/// occupy the same area. Worse, when the tile is made
/// non-focusable to let pills take focus, the whole screen loses
/// remote-input routing (the user reported: "D-pad, Select, and
/// Menu buttons do nothing"). An inline VStack sibling gives the
/// focus engine a clean spatial below-relationship — the tile
/// stays focusable, pills live below it, D-pad-down Just Works.
///
/// The container controls visibility: this view renders its
/// content unconditionally; the container wraps it in opacity +
/// animation based on `MultiviewChromeState.isVisible`. Focus
/// behaviour stays stable because the pills are always focusable
/// (the `allowsHitTesting` flip would break focus routing when
/// faded).
struct PlaybackBottomChrome_tvOS: View {
    @ObservedObject var store: MultiviewStore

    /// Flag-gated by the container. Tapping Add Stream sets this
    /// true; container presents the channel-picker fullScreenCover.
    @Binding var showAddSheet: Bool

    /// Container toggles this to present `TVPlayerOptionsPanel` as
    /// an overlay above the grid.
    @Binding var showTVOptions: Bool

    /// Container presents `RecordProgramSheet` via fullScreenCover
    /// when this flips true. Tapped from the Record pill — gives
    /// users a way to record the currently-playing program without
    /// having to go back to the guide and long-press.
    @Binding var showRecordSheet: Bool

    /// Focus target binding from the container. Each pill attaches
    /// via `.focused(_:equals:)` so the container's D-pad-down
    /// handler can programmatically redirect focus to the first
    /// pill (Options) when the chrome appears from its
    /// collapsed-height state. Without this binding, tapping
    /// D-pad-down while chrome is faded would require the user to
    /// press again (first press = "reveal chrome", second press =
    /// "move focus to pill"); the binding folds both into one
    /// interaction.
    @FocusState.Binding var focusedChrome: MultiviewContainerView.ChromeFocusTarget?

    @EnvironmentObject private var chromeState: MultiviewChromeState

    /// True when the audio tile has live EPG data so recording the
    /// currently-playing program is meaningful. Gates the Record
    /// pill — streams with no EPG (raw M3U / missing tvg-id) hide
    /// the pill entirely rather than presenting a sheet with blank
    /// program metadata.
    private var canRecordCurrentProgram: Bool {
        guard let audioID = store.audioTileID,
              let audio = store.tiles.first(where: { $0.id == audioID })
        else { return false }
        return audio.item.currentProgram?.isEmpty == false
    }

    var body: some View {
        VStack(spacing: 18) {
            // Live program progress band — program name + progress
            // bar + time remaining. Non-focusable; informational.
            PlaybackLiveProgressBand(store: store)
                .padding(.horizontal, 80)

            HStack(spacing: 20) {
                // Render Options first (leftmost) so D-pad-right
                // from it lands on `+`. User mental model:
                // "[adjust this stream] | [record it] | [add another stream]".
                optionsButton
                if canRecordCurrentProgram {
                    recordButton
                }
                addButton
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        // `.focusSection()` on the pill row's parent registers
        // this view as its own focus anchor so the engine routes
        // D-pad-down from the tile above cleanly into here.
        .focusSection()
    }

    private var addButton: some View {
        Button {
            chromeState.reportInteraction()
            showAddSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                Text("Add Stream")
                    .font(.system(size: 24, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($focusedChrome, equals: .addStream)
        .accessibilityLabel("Add stream")
        .accessibilityHint("Pick another channel to watch alongside this one")
    }

    private var optionsButton: some View {
        Button {
            chromeState.reportInteraction()
            showTVOptions = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .semibold))
                Text("Options")
                    .font(.system(size: 24, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($focusedChrome, equals: .options)
        .accessibilityLabel("Options")
        .accessibilityHint("Change audio track, subtitles, sleep timer, or stream info")
    }

    /// Record pill — presents `RecordProgramSheet` for the audio
    /// tile's currently-playing program. Saves the user a trip
    /// back to the guide + long-press when they're already watching
    /// something they want to record. Shown only when the audio
    /// tile has EPG data (`canRecordCurrentProgram`). Red record
    /// dot icon reads as the universal recording vocabulary; pill
    /// style matches Options / Add Stream.
    private var recordButton: some View {
        Button {
            chromeState.reportInteraction()
            showRecordSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "record.circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.red)
                Text("Record")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($focusedChrome, equals: .record)
        .accessibilityLabel("Record current program")
        .accessibilityHint("Schedule a recording of what's currently airing on this channel")
    }
}

/// Extracted standalone live-progress band view so
/// `PlaybackBottomChrome_tvOS` can reuse the same layout as
/// `PlaybackChromeOverlay.liveProgressBand`. Both read program
/// metadata off the sole tile's `ChannelDisplayItem`; renders
/// nothing when EPG data is missing.
struct PlaybackLiveProgressBand: View {
    @ObservedObject var store: MultiviewStore

    var body: some View {
        if let tile = store.tiles.first,
           let start = tile.item.currentProgramStart,
           let end = tile.item.currentProgramEnd {
            let now = Date()
            let total = end.timeIntervalSince(start)
            let elapsed = now.timeIntervalSince(start)
            let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 0
            let remaining = max(0, end.timeIntervalSince(now))
            let mins = Int(remaining / 60)
            let remainingText = mins > 0 ? "\(mins) min remaining" : "Ending soon"
            let programName = tile.item.currentProgram ?? ""

            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.2))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)

                HStack {
                    if !programName.isEmpty {
                        Text(programName)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(remainingText)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                programName.isEmpty
                    ? "\(remainingText)"
                    : "\(programName), \(remainingText)"
            )
        }
    }
}
#endif
