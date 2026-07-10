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
    /// Live Rewind engine state (iOS unified chrome): drives the band
    /// swap; its 0.5s window publisher paces position re-render.
    @ObservedObject private var liveRewindIOS = LiveRewindEngine.shared
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

    /// Bound from the container. The iOS overflow menu's "Switch Stream"
    /// row flips this true; the container presents `SwitchStreamView`.
    /// Only wired on the iOS (overflow-menu) path; on tvOS the Options
    /// panel drives its own copy in the container.
    @Binding var showSwitchStream: Bool

    /// Drives the 5-second auto-fade of chrome. Container owns it;
    /// we read `isVisible` to gate opacity + hit-testing, and call
    /// `reportInteraction()` on every button action to bump the
    /// timer.
    @EnvironmentObject private var chromeState: MultiviewChromeState

    /// Issue #38: reflects whether the player is currently forcing
    /// landscape, so the fullscreen button shows the correct icon. Synced
    /// from `AppOrientationLock` on appear so it stays right when the
    /// chrome is re-created for a new player session.
    @State private var forcedLandscape = false

    // v1.6.15: removed `verticalSizeClass` + `isiPhonePortrait` —
    // they only existed to switch between the inline title layout
    // (iPad / iPhone landscape) and the three-line title row
    // (iPhone portrait), both of which are now gone. Channel info
    // lives in `ChannelInfoBanner` (HomeView) instead.

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
            // v1.6.18: explicitly bypass the parent's safe-area
            // handling. v1.6.17's iPhone-only multiview safe-area
            // carve-out (HomeView's `iOSMultiviewWrapper` dropped
            // the outer `.ignoresSafeArea()` for iPhone) caused this
            // overlay to start at safe-area-top, after which the
            // `dynamicTopInset` formula's own `windowInset + 12`
            // double-counted the Dynamic Island clearance and
            // pushed the Close / Overflow / + buttons too far down
            // in iPhone portrait. Anchoring this overlay at the
            // literal screen top restores the absolute positioning
            // the formula was designed around — chrome y =
            // dynamicTopInset (~71pt on Pro Max portrait), which
            // hugs the Dynamic Island instead of floating ~130pt
            // below it. Landscape was already fine because
            // dynamicTopInset bottoms out at 20pt there.
            .ignoresSafeArea(edges: .top)
        }
        #else
        EmptyView()
        #endif
        // N > 1 on either platform: transport bar handles chrome,
        // nothing rendered here.
    }

    /// Title of the sole tile (or empty). v1.6.15: no longer used by
    /// the chrome bar (the new `ChannelInfoBanner` in HomeView
    /// covers that), but still consumed by the Audio-Only
    /// foreground overlay — Audio-Only is a fullscreen "no video"
    /// curtain that needs its own readout of which channel is
    /// muted-to-audio.
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
                // v1.6.15: title removed from the chrome bar — the
                // new top-left `ChannelInfoBanner` (HomeView) shows
                // channel logo, number, name, program title, and
                // airing window in one place across iPhone, iPad,
                // and Apple TV. The chrome's centered title /
                // iPhone-portrait three-line title stack was
                // duplicating that information.
                Spacer(minLength: 0)
                #if os(iOS)
                // Issue #38: rotate-to-fullscreen, iPhone only (iPad already
                // rotates with the device).
                if UIDevice.current.userInterfaceIdiom == .phone {
                    landscapeButton_iOS
                }
                #endif
                if let audio = store.audioProgressStore {
                    iPadOverflowAdapter(
                        progressStore: audio,
                        sleepTimerEnd: $sleepTimerEnd,
                        showStreamInfo: $showStreamInfo,
                        canRecord: canRecordCurrentProgram_iOS,
                        onRecord: {
                            chromeState.reportInteraction()
                            showRecordSheet = true
                        },
                        onSwitchStream: canSwitchStreamForAudioTile ? {
                            chromeState.reportInteraction()
                            showSwitchStream = true
                        } : nil,
                        // Pin the chrome up while the overflow menu (and
                        // its sub-menus) is open; release + restart the
                        // fade clock on dismiss. Without this the 5s
                        // timer could hide the chrome (and the menu's
                        // anchor) out from under the open menu.
                        onMenuOpen: { chromeState.setPinned(true) },
                        onMenuClose: {
                            chromeState.setPinned(false)
                            chromeState.reportInteraction()
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

            // v1.6.15: removed the iPhone-portrait three-line title
            // stack (channel name / program / time range). The new
            // `ChannelInfoBanner` (HomeView) renders this as a
            // single top-left HUD on every form factor.

            Spacer(minLength: 0)
            // Dev engine badge sits bottom-left, above the progress band, so
            // it never collides with the top-left ChannelInfoBanner (program
            // info HUD). Only renders while an AVPlayer dev toggle is on.
            HStack {
                engineBadge_iOS
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            if liveRewindIOS.buffering {
                RewindTransportBar_iOS(store: store)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            } else {
                liveProgressBand
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
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
        #if os(iOS)
        // Keep the fullscreen-toggle icon correct when the chrome is
        // (re)created for a new player session.
        .onAppear { forcedLandscape = AppOrientationLock.isForcingLandscape }
        #endif
    }

    /// Dev-only engine badge in the iOS top bar so a tester can confirm at a
    /// glance which pipeline is playing (AVPlayer Direct HLS / Remux TS / mpv).
    /// Only shown while an AVPlayer engine toggle is on; normal users on the
    /// default mpv engine never see it. Mirrors the tvOS badge.
    @ViewBuilder
    private var engineBadge_iOS: some View {
        if (PlaybackFeatureFlags.avPlayerForHLS || PlaybackFeatureFlags.avPlayerRemuxTS),
           let audioID = store.audioTileID,
           let engine = store.tileEngines[audioID] {
            Text(engine)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .fixedSize()
        }
    }

    private var closeButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            #if os(iOS)
            // Issue #38: closing the player must return to the natural
            // orientation. The container's `.onDisappear` is unreliable
            // here (HomeView keeps the container mounted for the mini-
            // player, so it never fires on Close), and `exit()` also runs
            // on channel changes where landscape should persist, so release
            // explicitly at the close action.
            AppOrientationLock.release()
            #endif
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

    // v1.6.15: title helpers removed (`titleLabel_iOS`,
    // `titleInlineLabel_iOS`, `titleStack_iPhonePortrait`,
    // `soleTileTitle`). The new top-left `ChannelInfoBanner`
    // (HomeView) is the single source of truth for "what am I
    // watching" across iPhone, iPad, and Apple TV.

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

    #if os(iOS)
    /// Issue #38: rotate the player into landscape fullscreen on demand,
    /// even when the device is rotation-locked to portrait. iPhone-only
    /// (iPad already rotates freely). Same 52x52 round pill as Close / +.
    private var landscapeButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            forcedLandscape.toggle()
            AppOrientationLock.apply(landscape: forcedLandscape)
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Image(systemName: forcedLandscape
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forcedLandscape ? "Exit fullscreen" : "Rotate to fullscreen")
        .accessibilityHint(forcedLandscape ? "Return to portrait" : "Rotate the video into landscape fullscreen")
    }
    #endif

    /// Record button in the iOS top chrome — same 52×52 round pill
    /// as Close / `+` / AirPlay, with a red record-dot icon to
    /// match the system recording vocabulary. Tapping presents
    /// `RecordProgramSheet` for the audio tile's current program,
    /// saving the user a trip back to the guide + long-press.
    /// True when the audio tile has live EPG data so recording the
    /// currently-playing program is meaningful. Gates the iOS
    /// Record pill availability. v1.6.8 (B1 Phase 1): no longer
    /// gates on EPG — Dispatcharr playlists don't populate
    /// `currentProgram` at load time, so the prior gate hid the
    /// pill permanently. We only need a stream URL to record;
    /// `RecordProgramSheet` handles the missing-EPG case by
    /// falling back to a generic title + default 60-minute
    /// duration the user can override.
    private var canRecordCurrentProgram_iOS: Bool {
        guard let audioID = store.audioTileID,
              let audio = store.tiles.first(where: { $0.id == audioID })
        else { return false }
        return audio.item.streamURL != nil
    }

    /// Whether the audio tile's channel can Switch Stream: a Dispatcharr
    /// channel (has both the integer pk and the proxy uuid) on a Direct
    /// Connect admin server. Gates the iOS overflow-menu "Switch Stream"
    /// row; nil-or-closure is decided from this at the call site.
    private var canSwitchStreamForAudioTile: Bool {
        guard let audioID = store.audioTileID,
              let audio = store.tiles.first(where: { $0.id == audioID }),
              audio.item.dispatcharrChannelID != nil,
              let uuid = audio.item.uuid, !uuid.isEmpty
        else { return false }
        return ChannelStore.shared.activeServer?.dispatcharrCanSwitchStream ?? false
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

// MARK: - Live Rewind transport (iOS unified chrome)

#if !os(tvOS)
/// Live Rewind transport for the iOS unified chrome (locked layout):
/// draggable timeline over [buffer tail .. live edge]; under it the
/// remaining time LEFT and LIVE / behind-live countdown RIGHT;
/// centered skip/pause controls with the Go Live pill on the right
/// while rewound. Actions dispatch through the sole tile's
/// PlayerProgressStore closures into the coordinator's re-tune branch.
struct RewindTransportBar_iOS: View {
    @ObservedObject var store: MultiviewStore
    @ObservedObject private var liveRewind = LiveRewindEngine.shared
    @State private var dragFraction: CGFloat? = nil

    var body: some View {
        let window = max(Int64(1), liveRewind.headWallMs - liveRewind.tailWallMs)
        let posMs = Int64(store.audioProgressStore?.currentMs ?? 0)
        let current = liveRewind.timeshifting ? min(posMs, window) : window
        let fraction = dragFraction ?? CGFloat(Double(current) / Double(window))
        let behindMs = window - current
        let isPaused = store.audioProgressStore?.isPaused ?? false

        VStack(spacing: 6) {
            // Timeline: tap/drag to scrub anywhere in the window.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * max(0, min(1, fraction)))
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .offset(x: geo.size.width * max(0, min(1, fraction)) - 7)
                }
                // The player surface owns competing drag gestures (the
                // swipe-up/down channel flip most notably), which were
                // swallowing the scrub drag. High priority makes the
                // timeline win while a finger is ON it, and the padded
                // contentShape gives the thumb a real touch target.
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragFraction = max(0, min(1, v.location.x / geo.size.width))
                        }
                        .onEnded { v in
                            let f = max(0, min(1, v.location.x / geo.size.width))
                            dragFraction = nil
                            store.audioProgressStore?.seekAction?(Int32(Double(window) * Double(f)))
                        }
                )
                .padding(.vertical, -12)
            }
            .frame(height: 14)

            // Status line: remaining LEFT, LIVE / behind RIGHT.
            HStack {
                if let end = store.tiles.first?.item.currentProgramEnd {
                    let wall = liveRewind.tailWallMs + current
                    let rem = max(0, Int64(end.timeIntervalSince1970 * 1000) - wall)
                    let mins = Int(rem / 60_000)
                    Text(mins >= 60 ? "\(mins / 60) h \(mins % 60) min remaining"
                         : (mins > 0 ? "\(mins) min remaining" : "Ending soon"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                HStack(spacing: 4) {
                    if !(liveRewind.timeshifting && behindMs > 5_000) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                    }
                    Text(liveRewind.timeshifting && behindMs > 5_000
                         ? String(format: "-%d:%02d", behindMs / 60_000, (behindMs / 1000) % 60)
                         : "LIVE")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(liveRewind.timeshifting && behindMs > 5_000
                                         ? Color.white.opacity(0.8) : Color.white)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.audioProgressStore?.seekAction?(Int32(clamping: window))
                }
            }

            // Controls: centered skip/pause cluster; Go Live pill
            // anchors right without disturbing the centering.
            ZStack {
                HStack(spacing: 26) {
                    transportButton("gobackward.30") {
                        if let ps = store.audioProgressStore {
                            ps.seekAction?(max(0, (liveRewind.timeshifting ? ps.currentMs : Int32(clamping: window)) - 30_000))
                        }
                    }
                    transportButton(isPaused ? "play.fill" : "pause.fill") {
                        store.audioProgressStore?.togglePauseAction?()
                    }
                    transportButton("goforward.30") {
                        if let ps = store.audioProgressStore {
                            ps.seekAction?((liveRewind.timeshifting ? ps.currentMs : Int32(clamping: window)) + 30_000)
                        }
                    }
                }
                if liveRewind.timeshifting {
                    HStack {
                        Spacer()
                        Button {
                            store.audioProgressStore?.seekAction?(Int32(clamping: window))
                        } label: {
                            Text("Go Live")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func transportButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.55), in: Circle())
        }
    }
}
#endif

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
/// - `onMenuOpen`/`Close` pin `MultiviewChromeState` while the overflow
///   menu (and its nested sub-menus: Audio Track, Subtitles, Speed,
///   Aspect, Sleep Timer, Audio Only, AirPlay) is open, so the
///   auto-hiding chrome can't fade out from under the open menu after
///   the 5s timer. v1.7.x: this was previously a no-op on the
///   assumption that menu interaction already drove the chrome timer,
///   but opening the SwiftUI `Menu` does not call `reportInteraction()`,
///   so a stale fade could fire mid-menu. Now matches the tvOS pin on
///   `showTVOptions`.
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
    /// Switch Stream (Dispatcharr Direct Connect, admin only). Non-nil
    /// only when the audio tile's channel is eligible; flips
    /// `showSwitchStream` so the container presents `SwitchStreamView`.
    var onSwitchStream: (() -> Void)? = nil
    /// Pin / unpin the auto-hiding chrome while the menu popover is open
    /// (fired from `PlayerOverflowMenu`'s `.onAppear`/`.onDisappear`
    /// under `#if os(iOS)`). See the type doc comment.
    var onMenuOpen: (() -> Void)? = nil
    var onMenuClose: (() -> Void)? = nil

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
            aspectMode: progressStore.aspectMode,
            canRecord: canRecord,
            setAudioTrack: { [weak progressStore] in progressStore?.setAudioTrackAction?($0) },
            setSubtitleTrack: { [weak progressStore] in progressStore?.setSubtitleTrackAction?($0) },
            setSpeed: { [weak progressStore] in progressStore?.setSpeedAction?($0) },
            setAspect: { [weak progressStore] in
                progressStore?.aspectMode = $0
                UserDefaults.standard.set($0.rawValue, forKey: "player.aspectMode")
            },
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
            switchStreamAction: onSwitchStream,
            onMenuOpen: onMenuOpen,
            onMenuClose: onMenuClose
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

    /// Live Rewind: engine state drives the timeline band swap and the
    /// transport cells. Its 0.5s window publisher also provides the
    /// re-render cadence for the position readouts below.
    @ObservedObject private var liveRewind = LiveRewindEngine.shared

    /// Record pill availability (tvOS). v1.6.8 (B1 Phase 1): no
    /// longer gates on EPG — see `canRecordCurrentProgram_iOS`
    /// for full rationale. We only need a stream URL.
    private var canRecordCurrentProgram: Bool {
        guard let audioID = store.audioTileID,
              let audio = store.tiles.first(where: { $0.id == audioID })
        else { return false }
        return audio.item.streamURL != nil
    }

    var body: some View {
        VStack(spacing: 18) {
            // Live program progress band — program name + progress
            // bar + time remaining. Non-focusable; informational.
            // With a Live Rewind session rolling, the band becomes the
            // rewind timeline over [buffer tail .. live edge] instead.
            if let cu = store.catchupTile?.catchup,
               let ps = store.audioProgressStore {
                // Catch-up replay (task #147): position over the pinned
                // programme duration. Observes the progress store
                // directly - there is no rewind engine ticking to drive
                // re-renders in this mode.
                CatchupTimelineBand(progress: ps, playback: cu)
                    .padding(.horizontal, 80)
            } else if liveRewind.buffering {
                LiveRewindTimelineBand(store: store)
                    .padding(.horizontal, 80)
            } else {
                PlaybackLiveProgressBand(store: store)
                    .padding(.horizontal, 80)
            }

            // Modern player chrome (DEFAULT): the controls mirror the native
            // AVPlayerViewController transport (frosted circular tool cells,
            // bottom-RIGHT, label under the focused cell) for BOTH engines, so
            // the custom chrome and the system player read as ONE design (user
            // direction: no differing control styles between screens). Gated on
            // `useModernPlayerChrome` (default on, decoupled from the AVPlayer
            // engine) so it can be reverted to the legacy labeled pill row (the
            // `else` branch) via UserDefaults without a code change.
            if PlaybackFeatureFlags.useModernPlayerChrome {
            HStack(alignment: .top, spacing: 18) {
                // Engine badge is a dev evaluation aid — only shown while an
                // AVPlayer engine toggle is on. Regular users on the default
                // (mpv) modern chrome see clean controls with no engine tag.
                if (PlaybackFeatureFlags.avPlayerForHLS || PlaybackFeatureFlags.avPlayerRemuxTS),
                   let audioID = store.audioTileID,
                   let engine = store.tileEngines[audioID] {
                    Text(engine)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .focusable(false)
                }

                Spacer()

                // Live Rewind transport, leading the row so D-pad LEFT
                // from the existing cells reaches it (same relative
                // placement the Android TV pill row uses).
                // The same three transport cells serve live rewind AND
                // catch-up: currentMs ticks in both modes and seekAction
                // routes to the right seek model per mode (buffer re-tune
                // vs archive window re-tune).
                if store.catchupTile != nil || liveRewind.buffering {
                    nativeToolButton(
                        .rewind30,
                        icon: "gobackward.30",
                        title: "Rewind",
                        a11yLabel: "Rewind 30 seconds",
                        a11yHint: "Jump back thirty seconds"
                    ) {
                        chromeState.reportInteraction()
                        if let ps = store.audioProgressStore {
                            ps.seekAction?(max(0, ps.currentMs - 30_000))
                        }
                    }
                    nativeToolButton(
                        .playPause,
                        icon: (store.audioProgressStore?.isPaused ?? false) ? "play.fill" : "pause.fill",
                        title: (store.audioProgressStore?.isPaused ?? false) ? "Play" : "Pause",
                        a11yLabel: (store.audioProgressStore?.isPaused ?? false) ? "Play" : "Pause",
                        a11yHint: "Pause playback"
                    ) {
                        chromeState.reportInteraction()
                        store.audioProgressStore?.togglePauseAction?()
                    }
                    nativeToolButton(
                        .forward30,
                        icon: "goforward.30",
                        title: "Forward",
                        a11yLabel: "Forward 30 seconds",
                        a11yHint: "Jump forward thirty seconds"
                    ) {
                        chromeState.reportInteraction()
                        if let ps = store.audioProgressStore {
                            ps.seekAction?(ps.currentMs + 30_000)
                        }
                    }
                    if liveRewind.timeshifting {
                        nativeToolButton(
                            .goLive,
                            icon: "forward.end.fill",
                            title: "Go Live",
                            a11yLabel: "Go live",
                            a11yHint: "Return to the live broadcast"
                        ) {
                            chromeState.reportInteraction()
                            let window = Int32(clamping: max(Int64(1), liveRewind.headWallMs - liveRewind.tailWallMs))
                            store.audioProgressStore?.seekAction?(window)
                        }
                    }
                }

                // Same ordering as the native transport custom items:
                // Record, Add Stream, then Options rightmost.
                if canRecordCurrentProgram {
                    nativeToolButton(
                        .record,
                        icon: "record.circle",
                        title: "Record",
                        iconColor: .red,
                        a11yLabel: "Record current program",
                        a11yHint: "Schedule a recording of what's currently airing on this channel"
                    ) {
                        chromeState.reportInteraction()
                        showRecordSheet = true
                    }
                }
                // Catch-up is a single archived replay; multiview
                // alongside it isn't supported, so hide Add Stream.
                if store.catchupTile == nil {
                    nativeToolButton(
                        .addStream,
                        icon: "plus",
                        title: "Add Stream",
                        a11yLabel: "Add stream",
                        a11yHint: "Pick another channel to watch alongside this one"
                    ) {
                        chromeState.reportInteraction()
                        showAddSheet = true
                    }
                }
                nativeToolButton(
                    .options,
                    icon: "slider.horizontal.3",
                    title: "Options",
                    a11yLabel: "Options",
                    a11yHint: "Change audio track, subtitles, sleep timer, or stream info"
                ) {
                    chromeState.reportInteraction()
                    debugLog("[MV-Cmd] Options pill pressed → showTVOptions=true | audioTileID=\(store.audioTileID ?? "nil") tiles=\(store.tiles.count) audioStore=\(store.audioProgressStore == nil ? "nil" : "ok")")
                    showTVOptions = true
                }
            }
            .padding(.horizontal, 80)
            } else {
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
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        // Bottom scrim. The chrome floats over whatever the video
        // shows; a busy bright strip (sports tickers) used to swallow
        // the idle pills entirely (the Android build grounds its
        // controls on a scrim, which is why its buttons read better).
        // Clear at the top so the video still shines through above
        // the progress band.
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.45), .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -30)
        )
        // `.focusSection()` on the pill row's parent registers
        // this view as its own focus anchor so the engine routes
        // D-pad-down from the tile above cleanly into here.
        .focusSection()
    }

    /// One native-style tool cell: frosted circle, icon-only at rest;
    /// the focused cell turns white with a dark icon and shows its
    /// title underneath, exactly the AVPlayerViewController transport
    /// behavior. The fixed-height label slot keeps the circles from
    /// jumping when focus moves.
    @ViewBuilder

    private var addButton: some View {
        // Own the focus ring so it follows the pill's Capsule shape. The
        // shared TVNoHighlightButtonStyle draws a RoundedRectangle(14) ring
        // that reads boxy on a capsule, so suppress it (drawsFocusRing:
        // false) and draw a Capsule accent ring here instead.
        let isFocused = focusedChrome == .addStream
        return Button {
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
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.accentPrimary : Color.white.opacity(0.22),
                    lineWidth: isFocused ? 4 : 1
                )
            )
        }
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .focused($focusedChrome, equals: .addStream)
        .accessibilityLabel("Add stream")
        .accessibilityHint("Pick another channel to watch alongside this one")
    }

    private var optionsButton: some View {
        let isFocused = focusedChrome == .options
        return Button {
            chromeState.reportInteraction()
            debugLog("[MV-Cmd] Options pill pressed → showTVOptions=true | audioTileID=\(store.audioTileID ?? "nil") tiles=\(store.tiles.count) audioStore=\(store.audioProgressStore == nil ? "nil" : "ok")")
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
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.accentPrimary : Color.white.opacity(0.22),
                    lineWidth: isFocused ? 4 : 1
                )
            )
        }
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
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
        let isFocused = focusedChrome == .record
        return Button {
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
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.accentPrimary : Color.white.opacity(0.22),
                    lineWidth: isFocused ? 4 : 1
                )
            )
        }
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .focused($focusedChrome, equals: .record)
        .accessibilityLabel("Record current program")
        .accessibilityHint("Schedule a recording of what's currently airing on this channel")
    }

    private func nativeToolButton(
        _ target: MultiviewContainerView.ChromeFocusTarget,
        icon: String,
        title: String,
        iconColor: Color = .white,
        a11yLabel: String,
        a11yHint: String,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedChrome == target
        return Button(action: action) {
            TVPlayerToolCellVisual(icon: icon, title: title,
                                   iconColor: iconColor, focused: isFocused)
        }
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .focused($focusedChrome, equals: target)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint(a11yHint)
    }
}

#if os(tvOS)
/// The circular tool cell's VISUAL, shared by the unified live chrome
/// and the legacy player transport (catch-up/VOD/recordings): frosted
/// circle that inverts to solid white with a black icon when focused,
/// title fading in beneath. ONE implementation so the two players can
/// never drift apart again (user directive 2026-07-10 after three
/// rounds of lookalike coloring mismatches). Visual only - each host
/// wires its own focus system and passes `focused`.
struct TVPlayerToolCellVisual: View {
    let icon: String
    let title: String
    var iconColor: Color = .white
    let focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .opacity(focused ? 0 : 1)
                Circle()
                    .fill(Color.white)
                    .opacity(focused ? 1 : 0)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(
                        iconColor == .red ? Color.red
                            : (focused ? Color.black : Color.white)
                    )
            }
            .frame(width: 68, height: 68)
            .scaleEffect(focused ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.15), value: focused)

            Text(title)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .opacity(focused ? 1 : 0)
                .frame(height: 24)
        }
    }
}
#endif

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

/// Live Rewind timeline band (tvOS native chrome): track spanning the
/// rewind window, programme name + remaining on the LEFT, LIVE or the
/// behind-live counter on the RIGHT (the locked transport layout).
/// Position values are truthful to the shifted playback point; the
/// engine's 0.5s window publisher drives re-render.
struct LiveRewindTimelineBand: View {
    @ObservedObject var store: MultiviewStore
    @ObservedObject private var liveRewind = LiveRewindEngine.shared

    var body: some View {
        let window = max(Int64(1), liveRewind.headWallMs - liveRewind.tailWallMs)
        let posMs = Int64(store.audioProgressStore?.currentMs ?? 0)
        let current = liveRewind.timeshifting ? min(posMs, window) : window
        let fraction = Double(current) / Double(window)
        let behindMs = window - current
        let programme = store.tiles.first?.item.currentProgram ?? ""
        let remainingText: String? = {
            guard let end = store.tiles.first?.item.currentProgramEnd else { return nil }
            let wall = liveRewind.tailWallMs + current
            let rem = max(0, Int64(end.timeIntervalSince1970 * 1000) - wall)
            let mins = Int(rem / 60_000)
            if mins >= 60 { return "\(mins / 60) h \(mins % 60) min remaining" }
            return mins > 0 ? "\(mins) min remaining" : "Ending soon"
        }()

        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                }
            }
            .frame(height: 6)

            HStack(spacing: 14) {
                if !programme.isEmpty {
                    Text(programme)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                if let remainingText {
                    Text(remainingText)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text(liveRewind.timeshifting && behindMs > 5_000
                     ? String(format: "-%d:%02d", behindMs / 60_000, (behindMs / 1000) % 60)
                     : "LIVE")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(liveRewind.timeshifting && behindMs > 5_000
                                     ? Color.white.opacity(0.8)
                                     : Color.accentColor)
            }
        }
        .focusable(false)
    }
}

/// Catch-up variant of the timeline band: playback position over the
/// programme's pinned duration (the archive stream reports no duration
/// of its own; `programDurationMs` comes from the EPG entry). Unlike
/// LiveRewindTimelineBand there is no engine publishing window ticks,
/// so this observes the tile's progress store directly for re-renders.
struct CatchupTimelineBand: View {
    @ObservedObject var progress: PlayerProgressStore
    let playback: CatchupPlayback

    var body: some View {
        let duration = max(Int32(1), playback.programDurationMs)
        let current = min(max(0, progress.currentMs), duration)
        let fraction = Double(current) / Double(duration)

        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                }
            }
            .frame(height: 6)

            HStack(spacing: 14) {
                Text(playback.title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer()
                Text("\(Self.clock(current)) / \(Self.clock(duration))")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
            }
        }
        .focusable(false)
    }

    private static func clock(_ ms: Int32) -> String {
        let total = Int(ms) / 1000
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
