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
            soleTileChrome_iOS
                .opacity(chromeState.isVisible ? 1 : 0)
                .allowsHitTesting(chromeState.isVisible)
                .animation(.easeInOut(duration: 0.25), value: chromeState.isVisible)
                .accessibilityHidden(!chromeState.isVisible)
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
            HStack(alignment: .center, spacing: 12) {
                closeButton_iOS
                Spacer(minLength: 8)
                titleLabel_iOS
                Spacer(minLength: 8)
                if canRecordCurrentProgram_iOS {
                    recordButton_iOS
                }
                if let audio = store.audioProgressStore {
                    iPadOverflowAdapter(
                        progressStore: audio,
                        sleepTimerEnd: $sleepTimerEnd,
                        showStreamInfo: $showStreamInfo
                    )
                }
                addButton_iOS
                airPlayButton_iOS
            }
            .padding(.horizontal, 16)
            // Hardcoded top padding large enough to clear the iPad
            // status bar / clock in any orientation. `.safeAreaPadding`
            // didn't work here because HomeView mounts
            // `MultiviewContainerView` with `.ignoresSafeArea()`,
            // which zeros out the safe area for descendants — so
            // any safe-area-respecting modifier resolves to 0 and
            // the chrome row lands on top of the status bar. 48 pt
            // covers iPad landscape (24 pt status bar + 24 pt
            // margin) and iPad portrait (44 pt status bar + 4 pt
            // margin); the gradient background extends under the
            // status bar via `.ignoresSafeArea(edges: .top)` below
            // so there's no visible seam.
            .padding(.top, 48)
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

    private var titleLabel_iOS: some View {
        Text(soleTileTitle)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Currently playing channel")
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
    private var recordButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            showRecordSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Image(systemName: "record.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.red)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record current program")
        .accessibilityHint("Schedule a recording of what's currently airing on this channel")
    }

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

    /// AirPlay system routing button. Same 52×52 `.ultraThinMaterial`
    /// chrome as the Close / `+` buttons so the three pills read as
    /// a row. `AirPlayButton` is a `UIViewRepresentable` defined in
    /// `PlayerView.swift` that wraps `AVRoutePickerView`; reusing
    /// it here means the N=1 unified chrome has feature parity with
    /// the legacy PlayerView top bar. System owns the picker UI
    /// entirely, so no state lives in this overlay.
    private var airPlayButton_iOS: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            AirPlayButton()
                .frame(width: 34, height: 34)
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel("AirPlay")
        .accessibilityHint("Stream audio and video to an AirPlay device")
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
/// - `togglePiP` routes to `progressStore.togglePiPAction` which the
///   tile's mpv Coordinator installs at setup.
/// - `toggleStreamInfo` / `toggleAudioOnly` are no-ops for now — the
///   stream-info overlay and audio-only background are ported in a
///   later Phase C.6 pass. Until then, tapping them is a cosmetic
///   state flip on `showStreamInfo` that has no visible effect in
///   the unified path (legacy PlayerView still honours it).
/// - `onMenuOpen`/`Close` are no-ops here. In legacy `PlayerView`
///   they gated the 4s controls-hide timer; the unified chrome
///   uses `MultiviewChromeState` which is already driven by any
///   user interaction, so the menu open/close doesn't need special
///   handling.
private struct iPadOverflowAdapter: View {
    @ObservedObject var progressStore: PlayerProgressStore
    @Binding var sleepTimerEnd: Date?
    @Binding var showStreamInfo: Bool

    var body: some View {
        PlayerOverflowMenu(
            audioTracks: progressStore.audioTracks,
            currentAudioTrackID: progressStore.currentAudioTrackID,
            subtitleTracks: progressStore.subtitleTracks,
            currentSubtitleTrackID: progressStore.currentSubtitleTrackID,
            speed: progressStore.speed,
            isLive: true,  // multiview is always live-only in v1
            isPiPActive: progressStore.isPiPActive,
            hasPiP: progressStore.togglePiPAction != nil,
            sleepTimerEnd: sleepTimerEnd,
            showStreamInfo: showStreamInfo,
            isAudioOnly: false,  // audio-only bg not yet ported to unified path
            setAudioTrack: { [weak progressStore] in progressStore?.setAudioTrackAction?($0) },
            setSubtitleTrack: { [weak progressStore] in progressStore?.setSubtitleTrackAction?($0) },
            setSpeed: { [weak progressStore] in progressStore?.setSpeedAction?($0) },
            togglePiP: { [weak progressStore] in progressStore?.togglePiPAction?() },
            setSleepTimer: { newEnd in sleepTimerEnd = newEnd },
            toggleStreamInfo: { showStreamInfo.toggle() },
            toggleAudioOnly: nil,
            onMenuOpen: nil,
            onMenuClose: nil
        )
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
