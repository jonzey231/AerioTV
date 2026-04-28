import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
#if os(iOS)
import UIKit
#endif

// MARK: - Attempt Log Store
// @unchecked Sendable: all mutations are dispatched to the main queue manually.
// Uses a non-published backing array to avoid SwiftUI re-renders on every state change.
// Only publishes when explicitly requested (e.g., on error display).
final class AttemptLogStore: ObservableObject, @unchecked Sendable {
    @Published var lines: [String] = []
    private var _pending: [String] = []

    /// Append silently — does NOT trigger SwiftUI update.
    func append(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            self?._pending.append(line)
        }
    }

    /// Flush pending entries to @Published (triggers SwiftUI update).
    /// Call this only when the log needs to be displayed (e.g., error screen).
    func flush() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self._pending.isEmpty else { return }
            self.lines.append(contentsOf: self._pending)
            self._pending.removeAll()
        }
    }

    var entries: [String] { lines + _pending }

    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.lines.removeAll()
            self?._pending.removeAll()
        }
    }
}

// MARK: - Media Track (audio/subtitle)

struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let type: String     // "audio" or "sub"
    let title: String
    let lang: String
    let codec: String
    let isDefault: Bool

    var displayName: String {
        if !title.isEmpty { return title }
        if !lang.isEmpty { return Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased() }
        return "\(type == "audio" ? "Audio" : "Subtitle") \(id)"
    }
}

// MARK: - Stream Info

struct StreamInfo: Equatable {
    var videoCodec: String = ""
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var pixelFormat: String = ""
    var hwdec: String = ""
    var audioCodec: String = ""
    var sampleRate: Int = 0
    var channels: Int = 0
    var cacheDuration: Double = 0
    var bitrate: Double = 0       // bytes/sec from demuxer
    var droppedFrames: Int = 0
    var avsync: Double = 0
}

// MARK: - Player Progress Store
// @unchecked Sendable: all @Published mutations dispatched to main queue manually.
final class PlayerProgressStore: ObservableObject, @unchecked Sendable {
    /// Current playback position in milliseconds (live-timeline relative).
    @Published var currentMs: Int32 = 0
    /// Total stream duration in ms (0 for live streams without a static file).
    @Published var durationMs: Int32 = 0
    /// True when player is paused.
    @Published var isPaused: Bool = false
    /// Current playback speed (1.0 = normal).
    @Published var speed: Double = 1.0
    /// Available audio and subtitle tracks (populated on playback-restart).
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var currentAudioTrackID: Int = 0
    @Published var currentSubtitleTrackID: Int = 0
    /// VOD resume tracking — set before playback starts, nil for live
    var vodID: String?
    var vodTitle: String?
    var vodPosterURL: String?
    var vodStreamURL: String?   // Resolved stream URL (for Continue Watching resume)
    var vodServerID: String?    // Server UUID (for Continue Watching auth headers)
    var vodType: String = "movie"  // "movie" or "episode" — determines which Continue Watching section
    var explicitResumeMs: Int32?  // Pre-loaded resume position (bypasses DB lookup)
    /// Closure set by the Coordinator; call with a target position in ms to seek.
    var seekAction: ((Int32) -> Void)?
    /// Closure set by the Coordinator; toggles play/pause.
    var togglePauseAction: (() -> Void)?
    /// Closure set by the Coordinator; sets playback speed.
    var setSpeedAction: ((Double) -> Void)?
    /// Closure set by the Coordinator; sets audio track (0 = auto).
    var setAudioTrackAction: ((Int) -> Void)?
    /// Closure set by the Coordinator; sets subtitle track (0 = off).
    var setSubtitleTrackAction: ((Int) -> Void)?
    /// Whether PiP is currently active. Written synchronously by the
    /// AVPictureInPictureController delegates (auto-PiP only — the manual
    /// menu entry was removed in favour of swipe-home auto-PiP). Read by
    /// `Coordinator.didEnterBackground` to skip the vid=no GPU-safeguard
    /// when iOS is actively driving the PiP window.
    @Published var isPiPActive: Bool = false
    /// True when the user flipped the overflow menu's "Audio Only" item.
    /// Mirrored from `PlayerView`'s local `@State` so the Coordinator's
    /// background handler can keep mpv's audio decoder running when the
    /// user has explicitly opted into background audio. Default false.
    @Published var isAudioOnly: Bool = false
    /// Stream technical info (codec, resolution, bitrate, etc.)
    @Published var streamInfo = StreamInfo()
    /// When true, the stream info overlay is visible and the volatile
    /// stats timer should be running. When false, the timer is paused
    /// to avoid mpv lock contention that causes frame-delivery jitter.
    var isStreamInfoVisible: Bool = false

    static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
}

// MARK: - Shared Error UI
private struct StreamErrorView: View {
    let title: String
    let message: String
    @ObservedObject var logStore: AttemptLogStore
    @Binding var didCopyErrorDetails: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.red)
                        .padding(.top, 60)

                    Text("Stream Failed")
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ATTEMPTS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)

                        ForEach(Array(logStore.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(line.hasPrefix("✓") ? .green : .yellow)
                                #if os(iOS)
                                .textSelection(.enabled)
                                #endif
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(8)
                    .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("ERROR")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)

                        Text(message)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.85))
                            #if os(iOS)
                            .textSelection(.enabled)
                            #endif
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(8)
                    .padding(.horizontal, 20)

                    HStack(spacing: 14) {
                        Button("Copy to Clipboard") {
                            let text = "ATTEMPTS\n" + logStore.lines.joined(separator: "\n") +
                                       "\n\nERROR\n" + message
                            #if os(iOS)
                            UIPasteboard.general.string = text
                            #endif
                            didCopyErrorDetails = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                didCopyErrorDetails = false
                            }
                        }
                        .foregroundColor(.accentColor)

                        Button("Close") { onClose() }
                            .foregroundColor(.accentColor)
                    }
                    .padding(.top, 8)

                    if didCopyErrorDetails {
                        Text("Copied!")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.green)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 40)
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }
}

// MARK: - PlayerView (player)

struct PlayerView: View {
    let urls: [URL]
    let title: String
    let headers: [String: String]
    let isLive: Bool
    let subtitle: String?
    let subtitleStart: Date?
    let subtitleEnd: Date?
    let artworkURL: URL?
    let vodID: String?
    let vodPosterURL: String?
    let vodServerID: String?
    let vodType: String  // "movie" or "episode" — only used when vodID != nil
    let resumePositionMs: Int32?
    let onMinimize: (() -> Void)?
    let onClose: (() -> Void)?

    init(urls: [URL], title: String, headers: [String: String]? = nil,
         isLive: Bool = true,
         subtitle: String? = nil, subtitleStart: Date? = nil, subtitleEnd: Date? = nil,
         artworkURL: URL? = nil,
         vodID: String? = nil, vodPosterURL: String? = nil,
         vodServerID: String? = nil, vodType: String = "movie",
         resumePositionMs: Int32? = nil,
         onMinimize: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.urls = urls
        self.title = title
        self.headers = headers ?? [:]
        self.isLive = isLive
        self.subtitle = subtitle
        self.subtitleStart = subtitleStart
        self.subtitleEnd = subtitleEnd
        self.artworkURL = artworkURL
        self.vodID = vodID
        self.vodPosterURL = vodPosterURL
        self.vodServerID = vodServerID
        self.vodType = vodType
        self.resumePositionMs = resumePositionMs
        self.onMinimize = onMinimize
        self.onClose = onClose
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var logStore = AttemptLogStore()
    @State private var didCopyErrorDetails = false
    @State private var isAudioOnly = false

    var body: some View {
        PlayerRootView(
            urls: urls, title: title, headers: headers,
            isLive: isLive,
            subtitle: subtitle, subtitleStart: subtitleStart, subtitleEnd: subtitleEnd,
            artworkURL: artworkURL,
            vodID: vodID, vodPosterURL: vodPosterURL, vodServerID: vodServerID,
            vodType: vodType,
            resumePositionMs: resumePositionMs,
            onDismiss: { if let c = onClose { c() } else { dismiss() } },
            onMinimize: onMinimize,
            logStore: logStore,
            didCopyErrorDetails: $didCopyErrorDetails,
            isAudioOnly: $isAudioOnly
        )
        .ignoresSafeArea()
    }
}


// MARK: - Player Root View
#if os(tvOS)
/// Focus targets for the tvOS player — SwiftUI's native focus system
/// replaces TVRemoteInputView so the player reliably captures focus
/// from the guide/channel list behind it.
enum TVPlayerFocus: Hashable {
    case background   // invisible layer when controls are hidden
    case gearIcon     // options pill when controls are visible
    case playPause    // center play/pause button
    case optionsPanel // inside the options popup
}
#endif

private struct PlayerRootView: View {
    let urls: [URL]
    let title: String
    let headers: [String: String]
    let isLive: Bool
    let subtitle: String?
    let subtitleStart: Date?
    let subtitleEnd: Date?
    let artworkURL: URL?
    let vodID: String?
    let vodPosterURL: String?
    let vodServerID: String?
    let vodType: String  // "movie" or "episode"
    let resumePositionMs: Int32?
    let onDismiss: () -> Void
    let onMinimize: (() -> Void)?

    @ObservedObject var logStore: AttemptLogStore
    @Binding var didCopyErrorDetails: Bool
    @Binding var isAudioOnly: Bool

    @State private var state: PlayState = .loading
    @State private var lastError: String = ""
    @State private var showControls = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var dragOffset: CGFloat = 0
    // Resume prompt removed — no DVR.

    // Sleep timer
    @State private var sleepTimerEnd: Date?

    // Stream info
    @State private var showStreamInfo = false
    #if os(iOS)
    /// User-draggable position for the stream info overlay (nil = default top-center).
    @State private var streamInfoPosition: CGPoint?
    #endif

    /// Channel-picker presentation. The `+` button in the top bar
    /// (iPad) / "Add Stream" row in the options panel (tvOS) sets
    /// this to `true`. Presenting from PlayerView — *not* from
    /// MultiviewContainerView after a mode flip — keeps the current
    /// stream playing under the sheet. The picker commits the mode
    /// transition on pick, so the user never sees the "original
    /// channel stops" mid-transition stall that the previous design
    /// produced.
    @State private var showAddStreamSheet = false

    #if os(tvOS)
    /// tvOS Player Options overlay (shown via gear icon or long-press Select).
    @State private var showTVOptions = false
    /// Focus target for tvOS — drives which element receives Siri Remote input.
    @FocusState private var tvFocus: TVPlayerFocus?
    /// v1.6.12: explicit observer for `NowPlayingManager` so SwiftUI
    /// re-renders PlayerView when `isMinimized` flips. Previously the
    /// view referenced `NowPlayingManager.shared.isMinimized` directly
    /// (line ~462's `.focusable(...)`), which reads the value but
    /// doesn't subscribe to changes. The result was a focus-stranding
    /// bug surfaced by GH #11: minimizing the full-screen player to
    /// the corner then re-expanding via Play/Pause from the guide
    /// left focus on the guide cell. Without re-rendering, the
    /// invisible `Color.clear` background-capture layer's
    /// `.focusable(!isMinimized)` argument stayed at its old value,
    /// so even if the focus engine tried to migrate back into the
    /// player it had nowhere focusable to land. Back presses then
    /// hit the guide cell (no exit handler), bubbled to MainTabView's
    /// `handleMenuPress`, and either felt unresponsive or fired the
    /// wrong branch. Observing the manager makes the focusable state
    /// react properly to state changes; the `.onChange` below grabs
    /// focus back into the player on the false-edge of `isMinimized`.
    @ObservedObject private var nowPlayingManager = NowPlayingManager.shared

    /// GH #11 v3 fix: namespace for `.focusScope` + `resetFocus`.
    /// Earlier attempts (deferred `tvFocus` assignment, clear-then-set
    /// nudge) shipped but didn't take on hardware — the focus engine
    /// silently ignores cross-region programmatic focus claims when
    /// the source region (the guide) and target region (the player)
    /// are siblings under different focus sections. Apple's official
    /// API for forcing this kind of migration is `resetFocus(in:)`
    /// fed by a `@Namespace` + `.focusScope(_:)` pair, with the
    /// preferred-default child opted in via `.prefersDefaultFocus(_:in:)`.
    /// `resetFocus` clears the current focus and lets the engine
    /// re-pick a default within the named scope, which DOES cross
    /// region boundaries. The `Color.clear` background-capture
    /// layer below opts in via `.prefersDefaultFocus`.
    @Namespace private var playerFocusScope

    /// Action handle for `resetFocus(in:)`. Called from the
    /// `.onChange(of: nowPlayingManager.isMinimized)` handler when
    /// the player un-minimizes back to full-screen.
    @Environment(\.resetFocus) private var resetFocus
    #endif

    // Timeline / scrubber
    @StateObject private var progressStore = PlayerProgressStore()
    @State private var isDragging = false
    @State private var dragFraction: CGFloat = 0

    #if os(tvOS)
    @State private var isScrubbing = false  // True while user holds left/right
    #endif

    enum PlayState { case loading, playing, error }

    @ViewBuilder
    private var playerView: some View {
        #if canImport(Libmpv)
        MPVPlayerViewRepresentable(
            urls: urls, headers: headers,
            isLive: isLive,
            nowPlayingTitle: title,
            nowPlayingSubtitle: subtitle,
            nowPlayingArtworkURL: artworkURL,
            progressStore: progressStore,
            logStore: logStore,
            onFatalError: { err in lastError = err; state = .error }
        )
        #else
        Text("MPV engine not available on this platform")
            .foregroundColor(.red)
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch state {
            case .loading:
                loadingOverlay

            case .playing:
                ZStack {
                    // Player stays in the hierarchy at all times — removing it tears down the
                    // coordinator and forces a full restart when toggling back from audio-only.
                    playerView
                        .ignoresSafeArea()

                    #if os(iOS)
                    if isAudioOnly {
                        audioOnlyBackground
                            .transition(.opacity)
                    }
                    #endif

                    if showControls {
                        controlsOverlay
                            .transition(.opacity)
                    }

                    // Stream info overlay — visible when toggled, independent of controls auto-hide
                    if showStreamInfo {
                        #if os(iOS)
                        GeometryReader { geo in
                            let defaultPos = CGPoint(
                                x: geo.size.width / 2,
                                y: deviceSafeAreaTop + 70
                            )
                            let pos = streamInfoPosition ?? defaultPos
                            streamInfoOverlay
                                .position(pos)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            streamInfoPosition = value.location
                                        }
                                )
                        }
                        .transition(.opacity)
                        #else
                        VStack {
                            streamInfoOverlay
                                .padding(.top, deviceSafeAreaTop + 24)
                            Spacer()
                        }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        #endif
                    }

                    #if os(tvOS)
                    // tvOS: SwiftUI-native input layer — truly invisible focusable
                    // surface that captures Siri Remote input when controls are hidden.
                    // Always present (avoids view create/destroy lag) but only focusable
                    // when controls are hidden.
                    Color.clear
                        .focusable(!showControls && !nowPlayingManager.isMinimized)
                        .focused($tvFocus, equals: .background)
                        // GH #11 v3: opt this layer into the player's
                        // focus scope as the preferred-default target.
                        // When the player un-minimizes and we call
                        // `resetFocus(in: playerFocusScope)`, tvOS
                        // looks for a focusable view here that's flagged
                        // as default — Color.clear matches whenever the
                        // controls are hidden (its normal, full-screen,
                        // pre-minimize state). When showControls is true
                        // the gear icon's own focus binding takes over.
                        .prefersDefaultFocus(!showControls, in: playerFocusScope)
                        .onMoveCommand { direction in
                            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                            scheduleControlsHide()
                            if !isLive {
                                if direction == .left {
                                    progressStore.seekAction?(max(0, progressStore.currentMs - 10_000))
                                } else if direction == .right {
                                    let target = progressStore.durationMs > 0
                                        ? min(progressStore.durationMs, progressStore.currentMs + 10_000)
                                        : progressStore.currentMs + 10_000
                                    progressStore.seekAction?(target)
                                }
                            }
                        }
                        .ignoresSafeArea()

                    #else
                    // iOS: transparent tap layer — toggles controls on tap.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                            if showControls && !progressStore.isPaused { scheduleControlsHide() }
                        }
                        .allowsHitTesting(!showControls)
                    #endif
                }

            case .error:
                StreamErrorView(
                    title: title, message: lastError.isEmpty ? "Playback failed." : lastError,
                    logStore: logStore, didCopyErrorDetails: $didCopyErrorDetails,
                    onClose: onDismiss
                )
                .onAppear { logStore.flush() }
            }
        }
        // Offset and opacity applied to the whole view (including the black background) so the
        // tab content already rendered beneath in MainTabView is revealed as the player slides down.
        .offset(y: max(0, dragOffset))
        .opacity(1.0 - min(0.4, dragOffset / 400))
        #if os(iOS)
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard state == .playing, value.translation.height > 0 else { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    guard state == .playing else { return }
                    // Use the key window height for iPad/split-screen compatibility.
                    let screenH = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                        .first { $0.isKeyWindow }?
                        .frame.height ?? UIScreen.main.bounds.height
                    let isSwipeDown = value.translation.height > abs(value.translation.width) &&
                                      (value.translation.height > 60 ||
                                       value.predictedEndTranslation.height > 150)
                    if isSwipeDown {
                        withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) {
                            dragOffset = screenH
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            if let minimize = onMinimize {
                                minimize()
                            } else {
                                onDismiss()
                            }
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        #endif
        .task { await startPlayback() }
        .task(id: sleepTimerEnd) {
            // Sleep timer countdown — checks every 30s, pauses playback when expired
            guard let end = sleepTimerEnd else { return }
            while true {
                let remaining = end.timeIntervalSince(Date())
                if remaining <= 0 {
                    progressStore.togglePauseAction?()
                    sleepTimerEnd = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!showControls)
        #endif
        #if os(tvOS)
        .focusSection()
        #endif
        .onAppear {
            scheduleControlsHide()
        }
        // Add-stream picker. Presented on top of the live PlayerView
        // — deliberate: the current stream keeps playing under it, so
        // cancelling the picker leaves the user exactly where they
        // were. The sheet commits the multiview transition only if
        // the user actually picks a channel; that commit is the one
        // moment when `PlayerSession.mode` flips, the PlayerView
        // unmounts, and MultiviewContainerView takes over with both
        // tiles already requested.
        #if os(iOS)
        .sheet(isPresented: $showAddStreamSheet) {
            AddToMultiviewSheet(isPresented: $showAddStreamSheet)
                .presentationDetents([.fraction(0.45), .large])
                .presentationDragIndicator(.visible)
        }
        #else
        // tvOS uses `fullScreenCover` for the same reason the
        // multiview-container version does — SwiftUI's default sheet
        // on tvOS renders as a small centred modal that crops titles
        // and crams the channel rows unreadably.
        .fullScreenCover(isPresented: $showAddStreamSheet) {
            AddToMultiviewSheet(isPresented: $showAddStreamSheet)
        }
        #endif
        .onChange(of: progressStore.isPaused) { _, isPaused in
            if isPaused {
                controlsHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            } else {
                scheduleControlsHide()
            }
        }
        .onChange(of: showStreamInfo) { _, visible in
            // Bridge to the coordinator so the volatile stats timer
            // only runs while the overlay is visible — avoids mpv
            // lock contention that causes frame-delivery jitter.
            progressStore.isStreamInfoVisible = visible
        }
        #if os(tvOS)
        .onChange(of: showControls) { _, visible in
            // Drive focus between the invisible background capture layer
            // (when controls are hidden) and the gear icon (when visible).
            tvFocus = visible ? .gearIcon : .background
        }
        .onChange(of: showTVOptions) { _, showing in
            // Panel's own @FocusState + onAppear handles focus when opening.
            // When closing, return focus to the Options pill.
            if !showing { tvFocus = .gearIcon }
        }
        // v1.6.12: GH #11 fix (v3). When the player un-minimizes
        // (corner → full-screen, typically via Play/Pause from the
        // guide), force focus back into the player.
        //
        // Earlier iterations tried (a) just observing `isMinimized`
        // so PlayerView re-renders, then (b) deferring `tvFocus`
        // assignment with `DispatchQueue.main.async` + a
        // clear-then-set nudge — both shipped but neither held up
        // on hardware. The user still had to press a D-pad
        // direction first to kick the focus engine into picking up
        // the player as a valid target.
        //
        // Root cause: tvOS treats the player overlay (`.focusSection()`
        // on its wrapper in HomeView) and the guide as **sibling
        // focus regions**. `@FocusState` + `.focused()` only moves
        // focus WITHIN the current region — it doesn't cross
        // boundaries when the engine has already settled on a
        // focused view in a different region. Programmatic
        // assignment is silently ignored cross-region.
        //
        // Apple's official cross-region force-focus API is
        // `resetFocus(in:)` keyed off a `@Namespace` +
        // `.focusScope(_:)` pair, with the desired default child
        // opted in via `.prefersDefaultFocus(_:in:)`. Calling
        // `resetFocus(in: playerFocusScope)` clears the current
        // focus and lets tvOS pick the preferred-default child of
        // the named scope — and unlike the `tvFocus` binding, this
        // DOES cross region boundaries. The `Color.clear`
        // background-capture layer is opted in as the default when
        // controls are hidden (its normal full-screen state).
        //
        // Still wrapped in `DispatchQueue.main.async` so the
        // `.focusable(...)` re-evaluation and the engine's
        // bookkeeping both settle before we claim focus.
        .onChange(of: nowPlayingManager.isMinimized) { _, minimized in
            guard !minimized else { return }
            DispatchQueue.main.async {
                resetFocus(in: playerFocusScope)
            }
        }
        .onAppear { tvFocus = showControls ? .gearIcon : .background }
        // Handle Menu/Back and Play/Pause at the player level so they
        // work regardless of which element currently has focus.
        // GH #11: Back from fullscreen should always **reveal** the
        // chrome (Options pill, Add Stream, Record, etc.) on the
        // first press, then minimize on the second. Earlier code
        // had it backwards: chrome-shown → Back → hides chrome,
        // chrome-hidden → Back → minimize. That meant users pressing
        // Back from a clean fullscreen state (chrome already
        // auto-hidden) skipped straight to the mini player without
        // ever seeing the Stream UI.
        //
        // New cycle:
        //   showTVOptions panel open → Back closes the panel.
        //   chrome visible           → Back minimizes (or dismisses).
        //   chrome hidden            → Back reveals chrome.
        //
        // The same logic also runs in response to the
        // `.playerBackPress` notification — fired by
        // `MainTabView.handleMenuPress` when the user pressed Back
        // while focus was outside PlayerView (typically the guide
        // cell after expanding from mini via Play/Pause). Without
        // that hand-off the outer handler would minimize directly
        // and skip the chrome-reveal step, exactly the regression
        // GH #11 reported.
        .onExitCommand {
            debugLog("🎮 [PV] .onExitCommand FIRED (focus is inside PlayerView)")
            handleBackPress(source: "onExitCommand")
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerBackPress)) { _ in
            debugLog("🎮 [PV] .onReceive(.playerBackPress) FIRED (relay from MainTabView)")
            handleBackPress(source: "playerBackPress")
        }
        .onPlayPauseCommand {
            progressStore.togglePauseAction?()
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            if !progressStore.isPaused { scheduleControlsHide() }
        }
        // GH #11 v3: PlayerView's outer focus scope. Names the
        // region that `resetFocus(in:)` operates on (see
        // `.onChange(of: nowPlayingManager.isMinimized)` above) and
        // bounds where `.prefersDefaultFocus` hints from descendants
        // (Color.clear) are honored. Different from the
        // `.focusSection()` on the player wrapper in HomeView —
        // sections define D-pad navigation regions, scopes define
        // the namespace `resetFocus`/`prefersDefaultFocus` operate
        // within. They coexist.
        .focusScope(playerFocusScope)
        #endif
    }

    #if os(tvOS)
    /// GH #11: shared Back-press handler for the player. Called from
    /// both `.onExitCommand` (focus inside PlayerView) and
    /// `.onReceive(.playerBackPress)` (focus outside PlayerView,
    /// `MainTabView.handleMenuPress` defers here). One source of
    /// truth for the chrome cycle:
    ///
    ///   Options panel open → close panel.
    ///   Chrome visible      → minimize (or dismiss).
    ///   Chrome hidden       → reveal chrome.
    private func handleBackPress(source: String) {
        debugLog("🎮 [PV-BACK] handleBackPress source=\(source) | showTVOptions=\(showTVOptions) showControls=\(showControls) isMinimized=\(nowPlayingManager.isMinimized) tvFocus=\(String(describing: tvFocus))")
        if showTVOptions {
            debugLog("🎮 [PV-BACK]   → branch: panel-open → close panel")
            withAnimation(.easeInOut(duration: 0.2)) { showTVOptions = false }
            scheduleControlsHide()
        } else if showControls {
            debugLog("🎮 [PV-BACK]   → branch: chrome-visible → minimize")
            if let minimize = onMinimize {
                minimize()
            } else {
                onDismiss()
            }
        } else {
            debugLog("🎮 [PV-BACK]   → branch: chrome-hidden → reveal chrome (set showControls=true)")
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            scheduleControlsHide()
        }
    }
    #endif

    // MARK: - Loading
    private var loadingOverlay: some View {
        VStack(spacing: 20) {
            ProgressView().tint(.accentColor).scaleEffect(1.5)
            Text(title).font(.headline).foregroundColor(.white)
            Text("Connecting…").font(.subheadline).foregroundColor(.gray)
            Button("Cancel") { onDismiss() }
                .foregroundColor(.accentColor).padding(.top, 8)
        }
    }

    // MARK: - Audio-Only Background
    private var audioOnlyBackground: some View {
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
    }

    // MARK: - Safe area helper
    // Reads the key window's top safe area inset directly from UIKit so it's
    // accurate even inside a view that uses .ignoresSafeArea().
    //
    // Two cases the plain reading gets wrong on iPhone:
    //
    //  • Portrait with a running Live Activity in the Dynamic Island. iOS
    //    does NOT enlarge `safeAreaInsets.top` when an LA is active, but
    //    the LA pill visually extends further down than a plain DI. The
    //    player's top chrome ends up kissing (or under) the LA pill.
    //  • Landscape on DI/notch devices. iOS reports `safeAreaInsets.top == 0`
    //    because the app isn't showing a traditional status bar — but the
    //    system still draws the status-bar row + any LA as an overlay.
    //
    // Fix: on iPhone, bump the reported inset by a constant LA buffer on
    // devices that have a notch or Dynamic Island (reported > 40pt is a
    // reliable proxy), and floor landscape to a value that clears a compact
    // LA pill even when the reported inset is zero.
    private var deviceSafeAreaTop: CGFloat {
        #if os(iOS)
        // Robust scene/window lookup. `.first { $0.isKeyWindow }` returns
        // nil during fullScreenCover transitions — that's probably why the
        // previous read occasionally fell through to 0 even on iPhone Pro
        // Max portrait. Fall back to the first window of the active scene,
        // then any connected window, before giving up.
        let reported: CGFloat = {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
                if let key = active.windows.first(where: { $0.isKeyWindow }) {
                    return key.safeAreaInsets.top
                }
                if let any = active.windows.first {
                    return any.safeAreaInsets.top
                }
            }
            return scenes.first?.windows.first?.safeAreaInsets.top ?? 0
        }()

        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return max(reported, 24)  // iPad — conservative minimum
        }
        let isLandscape = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation.isLandscape ?? false
        // Notch / Dynamic Island iPhones report > 40pt of top inset in
        // portrait; older home-button iPhones report ~20pt. Only apply
        // the LA buffer to the former in portrait — iPhone SE / 8 would
        // get wasted vertical space otherwise.
        //
        // In landscape we used to apply the LA buffer AND floor at 60pt,
        // which stacked to ~88pt on Pro iPhones — way too low for a
        // fullscreen video (#22 feedback). In landscape iOS does not
        // overlay a Live Activity pill on top of fullscreen-landscape
        // app content, so the LA buffer isn't needed there, and the
        // floor only has to clear a hypothetical hardware camera or
        // rounded-corner insets (~20pt is plenty).
        let hasNotchOrDI = reported > 40
        let laBuffer: CGFloat = (hasNotchOrDI && !isLandscape) ? 28 : 0
        // 20pt floor in landscape keeps the chrome visually snug against
        // the top edge of the video without crowding the camera cutout.
        // 70pt floor in portrait continues to clear the status-bar row
        // and give the LA buffer room to breathe below.
        let floor: CGFloat = isLandscape ? 20 : 70
        return max(reported, floor) + laBuffer
        #else
        60   // tvOS has no notch / Dynamic Island
        #endif
    }

    private var deviceSafeAreaLeading: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.left ?? 0
        #else
        0
        #endif
    }

    private var deviceSafeAreaBottom: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
        #else
        0
        #endif
    }

    // MARK: - Timeline helpers

    /// For VOD: once player reports a non-zero duration.
    private var canSeekBackward: Bool {
        progressStore.durationMs > 0 && progressStore.currentMs > 2_000
    }

    private var canSeekForward: Bool {
        progressStore.durationMs > 0 && progressStore.currentMs < progressStore.durationMs - 2_000
    }

    private func formatMs(_ ms: Int32) -> String {
        let total = Int(ms / 1_000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    // MARK: - Scrubber bar

    /// Converts a scrubber fraction (0–1) to a target seek position in ms.
    private func fractionToMs(_ fraction: CGFloat) -> Int32 {
        guard progressStore.durationMs > 0 else { return 0 }
        return Int32(fraction * CGFloat(progressStore.durationMs))
    }

    /// Converts the current playback position to a 0–1 scrubber fraction.
    private var currentFraction: CGFloat {
        guard progressStore.durationMs > 0 else { return 0 }
        return CGFloat(progressStore.currentMs) / CGFloat(progressStore.durationMs)
    }

    /// True when the timeline can accept drag/seek gestures.
    private var isScrubberActive: Bool {
        progressStore.durationMs > 0
    }

    private var scrubberBar: some View {
        let displayFraction: CGFloat = isDragging ? dragFraction : max(0, min(1, currentFraction))

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: isDragging ? 5 : 3)

                // Filled portion
                Capsule()
                    .fill(Color.accentPrimary)
                    .frame(width: geo.size.width * max(0, min(1, displayFraction)),
                           height: isDragging ? 5 : 3)

                // Thumb — shown once the timeline is interactive
                if isScrubberActive {
                    Circle()
                        .fill(Color.white)
                        .frame(width: isDragging ? 18 : 13, height: isDragging ? 18 : 13)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: geo.size.width * max(0, min(1, displayFraction))
                                    - (isDragging ? 9 : 6.5))
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            #if os(iOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isScrubberActive else { return }
                        isDragging = true
                        dragFraction = max(0, min(1, value.location.x / geo.size.width))
                        scheduleControlsHide()
                    }
                    .onEnded { value in
                        guard isScrubberActive else { return }
                        let f = max(0, min(1, value.location.x / geo.size.width))
                        progressStore.seekAction?(fractionToMs(f))
                        withAnimation(.easeOut(duration: 0.15)) { isDragging = false }
                    }
            )
            #endif
        }
        .frame(height: 22)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
    }

    #if os(tvOS)
    // MARK: - tvOS Scrubber (visual only — input handled by TVRemoteInputView)

    private var tvScrubberBar: some View {
        let active = isScrubbing
        let displayFraction: CGFloat = max(0, min(1, currentFraction))

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track — expands while scrubbing
                Capsule()
                    .fill(Color.white.opacity(active ? 0.35 : 0.25))
                    .frame(height: active ? 10 : 4)

                // Filled portion
                Capsule()
                    .fill(active ? Color.accentPrimary : Color.accentPrimary.opacity(0.8))
                    .frame(width: geo.size.width * displayFraction,
                           height: active ? 10 : 4)

                // Thumb — large and glowing while scrubbing
                if isScrubberActive {
                    Circle()
                        .fill(Color.white)
                        .frame(width: active ? 28 : 14, height: active ? 28 : 14)
                        .shadow(color: active ? Color.accentPrimary.opacity(0.7) : .black.opacity(0.4),
                                radius: active ? 12 : 3)
                        .offset(x: geo.size.width * displayFraction - (active ? 14 : 7))
                }
            }
            .frame(height: 30)
        }
        .frame(height: 30)
        .animation(.easeInOut(duration: 0.15), value: active)
    }
    #endif

    // MARK: - Bottom controls (timeline + skip buttons)
    private var bottomControls: some View {
        VStack(spacing: 10) {
            #if os(tvOS)
            // Options pill + popup — anchored to bottom-right (hidden in mini player)
            if !nowPlayingManager.isMinimized {
            HStack {
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    // Popup panel — extends upward from the pill
                    if showTVOptions {
                        TVPlayerOptionsPanel(
                            audioTracks: progressStore.audioTracks,
                            currentAudioTrackID: progressStore.currentAudioTrackID,
                            subtitleTracks: progressStore.subtitleTracks,
                            currentSubtitleTrackID: progressStore.currentSubtitleTrackID,
                            speed: progressStore.speed,
                            isLive: isLive,
                            sleepTimerEnd: $sleepTimerEnd,
                            showStreamInfo: $showStreamInfo,
                            setAudioTrack: { progressStore.setAudioTrackAction?($0) },
                            setSubtitleTrack: { progressStore.setSubtitleTrackAction?($0) },
                            setSpeed: { progressStore.setSpeedAction?($0) },
                            onDismiss: {
                                withAnimation(.easeInOut(duration: 0.15)) { showTVOptions = false }
                                scheduleControlsHide()
                            },
                            onEnterMultiview: {
                                // Open the channel picker on top of
                                // the currently-playing stream. The
                                // sheet itself commits the multiview
                                // transition in `commitAdd` when the
                                // user picks a channel; until then,
                                // nothing about the current playback
                                // path changes — the user sees a
                                // picker, the live stream continues
                                // under it. Previously this closure
                                // called `enterMultiviewFromCurrent`
                                // which tore down the playing MPV at
                                // tap time; on tvOS that produced a
                                // 1.5-6s UI stall during which the
                                // sheet sometimes failed to present
                                // at all.
                                showAddStreamSheet = true
                            }
                        )
                        .focusSection()
                        // Back/Menu inside the panel closes it (not the app)
                        .onExitCommand {
                            withAnimation(.easeInOut(duration: 0.15)) { showTVOptions = false }
                            scheduleControlsHide()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 48) // offset above the pill
                    }

                    // Options pill / hint
                    if showTVOptions {
                        // Hint text when panel is open
                        Text("Press \(Image(systemName: "chevron.left")) to close")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    } else {
                        // Options pill button
                        Button {
                            controlsHideTask?.cancel()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showTVOptions = true
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Options")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(TVNoHighlightButtonStyle())
                        .focusEffectDisabled()
                        .focused($tvFocus, equals: .gearIcon)
                    }
                }
            }
            } // if !isMinimized
            #endif

            // Live streams: program progress bar. VOD: scrubber + skip buttons.
            if isLive {
                liveProgressSection
            } else {
                vodControlsSection
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, deviceSafeAreaBottom + 20)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Live Progress (program progress bar based on start/end times)
    private var liveProgressSection: some View {
        VStack(spacing: 6) {
            if let start = subtitleStart, let end = subtitleEnd {
                let now = Date()
                let total = end.timeIntervalSince(start)
                let elapsed = now.timeIntervalSince(start)
                let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 0
                let remaining = max(0, end.timeIntervalSince(now))

                // Progress bar + (tvOS) leading play/pause indicator.
                // The indicator is NON-FOCUSABLE on tvOS — Siri
                // Remote's hardware Play/Pause button drives the
                // actual toggle; this is purely visual feedback.
                HStack(spacing: 12) {
                    #if os(tvOS)
                    tvPlayPauseIndicator
                    #endif
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.2))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.accentPrimary)
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 6)
                }

                // Time remaining
                HStack {
                    if let prog = subtitle, !prog.isEmpty {
                        Text(prog)
                            #if os(tvOS)
                            .font(.system(size: 18, weight: .medium))
                            #else
                            .font(.system(size: 12, weight: .medium))
                            #endif
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    let mins = Int(remaining / 60)
                    Text(mins > 0 ? "\(mins) min remaining" : "Ending soon")
                        #if os(tvOS)
                        .font(.system(size: 18, weight: .medium))
                        #else
                        .font(.system(size: 12, weight: .medium))
                        #endif
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    // MARK: - VOD Controls (scrubber + skip + time labels)
    private var vodControlsSection: some View {
        VStack(spacing: 8) {
            #if os(tvOS)
            // tvOS: small play/pause indicator left of the scrubber
            // (mirrors the live-progress variant). Non-focusable;
            // hardware Play/Pause button drives the toggle.
            HStack(spacing: 12) {
                tvPlayPauseIndicator
                tvScrubberBar
            }
            #else
            scrubberBar
            #endif

            HStack(spacing: 0) {
                let leftMs: Int32 = isDragging
                    ? fractionToMs(dragFraction)
                    : progressStore.currentMs
                Text(formatMs(leftMs))
                    #if os(tvOS)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    #else
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    #endif
                    .foregroundColor(.white.opacity(0.75))
                    .frame(minWidth: 46, alignment: .leading)
                    .monospacedDigit()

                Spacer()

                #if !os(tvOS)
                // Skip back 10 s (iOS only — tvOS uses the scrubber)
                Button {
                    let target = max(0, progressStore.currentMs - 10_000)
                    progressStore.seekAction?(target)
                    scheduleControlsHide()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .opacity(canSeekBackward ? 1 : 0.3)
                .disabled(!canSeekBackward)

                Spacer().frame(width: 32)

                // Skip forward 10 s (iOS only)
                Button {
                    let target = progressStore.durationMs > 0
                        ? min(progressStore.durationMs, progressStore.currentMs + 10_000)
                        : progressStore.currentMs + 10_000
                    progressStore.seekAction?(target)
                    scheduleControlsHide()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .opacity(canSeekForward ? 1 : 0.3)
                .disabled(!canSeekForward)

                Spacer()
                #endif

                Text(formatMs(progressStore.durationMs))
                    #if os(tvOS)
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    #else
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    #endif
                    .foregroundColor(.white.opacity(0.75))
                    .frame(minWidth: 46, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Controls Overlay
    private var controlsOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    // Swipe-down handle — hints that dragging down minimizes
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 36, height: 4)
                        .padding(.top, deviceSafeAreaTop + 8)

                    // Top bar
                    HStack(alignment: .center, spacing: 12) {
                        #if !os(tvOS)
                        // Stop / close button (far left) — tvOS uses the Menu button instead
                        liquidButton(systemName: "xmark", tint: .white) { onDismiss() }
                        #endif

                        // Title + optional current-program subtitle
                        VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            #if os(tvOS)
                            .font(.system(size: 32, weight: .bold))
                            #else
                            .font(.headline)
                            #endif
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        if let prog = subtitle, !prog.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prog)
                                    .lineLimit(1)
                                // Time range line: show "HH:MM – HH:MM" when both times known,
                                // "ends HH:MM" when only end time available.
                                Group {
                                    if let start = subtitleStart, let end = subtitleEnd {
                                        HStack(spacing: 3) {
                                            Text(start, style: .time)
                                            Text("–")
                                            Text(end, style: .time)
                                        }
                                    } else if let end = subtitleEnd {
                                        HStack(spacing: 3) {
                                            Text("ends")
                                            Text(end, style: .time)
                                        }
                                    }
                                }
                                .lineLimit(1)
                            }
                            #if os(tvOS)
                            .font(.system(size: 22, weight: .regular))
                            #else
                            .font(.system(size: 12, weight: .regular))
                            #endif
                            .foregroundColor(.white.opacity(0.72))
                            .shadow(color: .black.opacity(0.5), radius: 3)
                        }
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        #if os(iOS)
                        // Overflow menu — all secondary controls
                        playerOverflowMenu
                        #endif

                        #if os(iOS)
                        // "+" add-stream button — iPad only. Screen is
                        // too narrow on iPhone for a usable 2×2 grid,
                        // let alone 3×3 (see plan's iPhone out-of-scope
                        // note). Tapping opens the channel picker,
                        // which on pick seeds tile 0 with the current
                        // channel + adds the picked one as tile 1.
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            addStreamButton
                        }
                        // AirPlay moved into the overflow menu — the
                        // `AirPlayMenuTrigger` helper keeps a hidden
                        // AVRoutePickerView in the key window so the
                        // menu item can still present the system picker.
                        #endif
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.65), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )

                Spacer()

                bottomControls
            }

            // Center play/pause button — iOS / iPadOS only. tvOS
            // users press Play/Pause on the Siri Remote (hardware
            // button); the on-screen play/pause state is surfaced as
            // a small indicator next to the timeline instead, which
            // keeps the center of the video unobstructed.
            #if !os(tvOS)
            centerPlayPauseButton
            #endif
        }
    }

    // MARK: - Player Overflow Menu (ellipsis)

    /// iPad-only `+` button. Mirrors the AirPlay button's 52×52
    /// ultraThinMaterial chrome so the iPad top bar has three
    /// matching circular buttons (overflow / `+` / AirPlay).
    ///
    /// Presents `AddToMultiviewSheet` **on top of the live PlayerView**
    /// — crucially without touching `PlayerSession.mode`. The current
    /// stream keeps playing behind the sheet. Only when the user
    /// commits (picks a channel) does the sheet call
    /// `PlayerSession.enterMultiview(...)` to seed tile 0 and flip
    /// into multiview. That's where the view swap happens — after
    /// the user has made a deliberate choice, not at button-tap.
    ///
    /// The earlier design flipped mode on tap + relied on a pending
    /// flag to auto-open the picker from the newly-mounted
    /// `MultiviewContainerView`; observed on-device it torched the
    /// live MPV instance twice (PlayerView's teardown + the seed
    /// tile's cold-start), stalled the main thread 1.5-6s, and the
    /// picker sometimes never presented because SwiftUI was still
    /// churning on the view swap. Keeping the sheet owned by
    /// PlayerView avoids all of that — the sheet is just an overlay
    /// on an otherwise-untouched view tree.
    #if os(iOS)
    private var addStreamButton: some View {
        Button {
            showAddStreamSheet = true
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

    #endif

    private var playerOverflowMenu: some View {
        PlayerOverflowMenu(
            audioTracks: progressStore.audioTracks,
            currentAudioTrackID: progressStore.currentAudioTrackID,
            subtitleTracks: progressStore.subtitleTracks,
            currentSubtitleTrackID: progressStore.currentSubtitleTrackID,
            speed: progressStore.speed,
            isLive: isLive,
            sleepTimerEnd: sleepTimerEnd,
            showStreamInfo: showStreamInfo,
            isAudioOnly: isAudioOnly,
            // Legacy single-stream PlayerView doesn't have record-sheet
            // plumbing (it's only reached with the Developer-Settings
            // `playback.unified` flag flipped off, a diagnostic fallback).
            // Record lives in the unified chrome, which users hit by
            // default. Keep this false here so the menu stays clean on
            // the legacy path.
            canRecord: false,
            setAudioTrack: { [weak progressStore] in progressStore?.setAudioTrackAction?($0) },
            setSubtitleTrack: { [weak progressStore] in progressStore?.setSubtitleTrackAction?($0) },
            setSpeed: { [weak progressStore] in progressStore?.setSpeedAction?($0) },
            setSleepTimer: { sleepTimerEnd = $0 },
            toggleStreamInfo: { withAnimation(.easeInOut(duration: 0.2)) { showStreamInfo.toggle() } },
            toggleAudioOnly: {
                withAnimation(.spring(response: 0.3)) { isAudioOnly.toggle() }
                // Mirror to the store so the Coordinator's background
                // handler can keep audio alive when the user opts in.
                progressStore.isAudioOnly = isAudioOnly
            },
            recordAction: nil,
            onMenuOpen: { controlsHideTask?.cancel() },
            onMenuClose: { if !progressStore.isPaused { scheduleControlsHide() } }
        )
        .equatable()
    }

    // MARK: - Audio Track Menu (legacy — now used inside overflow menu)

    private var audioTrackMenu: some View {
        Menu {
            ForEach(progressStore.audioTracks) { track in
                Button {
                    progressStore.setAudioTrackAction?(track.id)
                } label: {
                    if track.id == progressStore.currentAudioTrackID {
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "waveform.circle")
                #if os(tvOS)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 64, height: 64)
                #else
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 52, height: 52)
                #endif
                .foregroundColor(.white)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
    }

    // MARK: - Subtitle Track Menu

    private var subtitleTrackMenu: some View {
        Menu {
            Button {
                progressStore.setSubtitleTrackAction?(0)
            } label: {
                if progressStore.currentSubtitleTrackID == 0 {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }
            ForEach(progressStore.subtitleTracks) { track in
                Button {
                    progressStore.setSubtitleTrackAction?(track.id)
                } label: {
                    if track.id == progressStore.currentSubtitleTrackID {
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                #if os(tvOS)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 64, height: 64)
                #else
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 52, height: 52)
                #endif
                .foregroundColor(progressStore.currentSubtitleTrackID != 0 ? Color.accentPrimary : .white)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
    }

    /// Cycles through playback speed options (0.5x → 0.75x → 1x → 1.25x → 1.5x → 2x).
    private var speedButton: some View {
        Button {
            let speeds = PlayerProgressStore.speedOptions
            let currentIdx = speeds.firstIndex(of: progressStore.speed) ?? 2
            let nextIdx = (currentIdx + 1) % speeds.count
            progressStore.setSpeedAction?(speeds[nextIdx])
        } label: {
            let label = progressStore.speed == 1.0 ? "1x" : String(format: "%gx", progressStore.speed)
            Text(label)
                #if os(tvOS)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .frame(width: 64, height: 64)
                #else
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(width: 52, height: 52)
                #endif
                .foregroundColor(progressStore.speed == 1.0 ? .white : Color.accentPrimary)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
        #if os(tvOS)
        .buttonStyle(TVNoRingButtonStyle())
        #endif
    }

    // MARK: - Sleep Timer Menu

    private var sleepTimerMenu: some View {
        Menu {
            if sleepTimerEnd != nil {
                Button(role: .destructive) {
                    sleepTimerEnd = nil
                } label: {
                    Label("Cancel Timer", systemImage: "xmark")
                }
            }
            ForEach([30, 60, 90, 120], id: \.self) { minutes in
                Button {
                    sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
                } label: {
                    Label("\(minutes) minutes", systemImage: minutes == 30 ? "moon" : minutes == 60 ? "moon.fill" : minutes == 90 ? "moon.stars" : "moon.stars.fill")
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: sleepTimerEnd != nil ? "moon.zzz.fill" : "moon.zzz")
                    #if os(tvOS)
                    .font(.system(size: 28, weight: .semibold))
                    #else
                    .font(.system(size: 19, weight: .semibold))
                    #endif
                    .foregroundColor(sleepTimerEnd != nil ? Color.accentPrimary : .white)

                if let remaining = sleepTimerRemainingText {
                    Text(remaining)
                        #if os(tvOS)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        #else
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        #endif
                        .foregroundColor(Color.accentPrimary)
                }
            }
            #if os(tvOS)
            .frame(width: 64, height: 64)
            #else
            .frame(width: 52, height: 52)
            #endif
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
    }

    private var sleepTimerRemainingText: String? {
        guard let end = sleepTimerEnd else { return nil }
        let remaining = end.timeIntervalSince(Date())
        guard remaining > 0 else { return nil }
        let mins = Int(remaining / 60)
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(mins)m"
    }

    // MARK: - Stream Info Overlay

    private var streamInfoOverlay: some View {
        let info = progressStore.streamInfo
        return VStack(alignment: .leading, spacing: 6) {
            streamInfoRow(label: "VIDEO", value: "\(info.videoCodec)  \(info.width)×\(info.height)")
            streamInfoRow(label: "", value: "\(String(format: "%.2f", info.fps))fps  \(info.pixelFormat)")
            streamInfoRow(label: "", value: "hwdec: \(info.hwdec)")
            streamInfoRow(label: "AUDIO", value: "\(info.audioCodec)  \(info.sampleRate)Hz  \(info.channels)ch")
            streamInfoRow(label: "CACHE", value: "\(String(format: "%.1f", info.cacheDuration))s  \(formatBitrate(info.bitrate))")
            streamInfoRow(label: "SYNC", value: "\(String(format: "%.3f", info.avsync))s  drops: \(info.droppedFrames)")
        }
        #if os(tvOS)
        .padding(20)
        #else
        .padding(12)
        #endif
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private func streamInfoRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    #if os(tvOS)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    #else
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    #endif
                    .foregroundColor(Color.accentPrimary)
                    .frame(width: 46, alignment: .trailing)
            } else {
                Color.clear
                    #if os(tvOS)
                    .frame(width: 46, height: 1)
                    #else
                    .frame(width: 46, height: 1)
                    #endif
            }
            Text(value)
                #if os(tvOS)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                #else
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                #endif
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private func formatBitrate(_ bytesPerSec: Double) -> String {
        let mbps = bytesPerSec * 8.0 / 1_000_000.0
        if mbps >= 1.0 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f kbps", mbps * 1000)
        }
    }

    private func liquidButton(
        systemName: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                #if os(tvOS)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 64, height: 64)
                #else
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 52, height: 52)
                #endif
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
        #if os(tvOS)
        .buttonStyle(TVNoRingButtonStyle())
        #endif
    }

    private func startPlayback() async {
        logStore.reset()
        logStore.append("ℹ️ Player: MPV (libmpv)")
        // Set VOD resume info on progressStore so the coordinator can save/restore progress
        progressStore.vodID = vodID
        progressStore.vodTitle = title
        progressStore.vodPosterURL = vodPosterURL
        progressStore.vodStreamURL = urls.first?.absoluteString
        progressStore.vodServerID = vodServerID
        progressStore.vodType = vodType
        progressStore.explicitResumeMs = resumePositionMs
        state = .playing
        scheduleControlsHide()
    }

    /// Compact, NON-INTERACTIVE play/pause state indicator for tvOS.
    ///
    /// Rendered inline with the timeline (left of the progress bar /
    /// scrubber) so the user has a clear visual of whether playback
    /// is currently running. It deliberately does NOT accept focus:
    /// the Siri Remote's hardware Play/Pause button fires
    /// `playPauseTapped` via `TVRemoteInputView` → `togglePauseAction`
    /// and the user doesn't need a focusable on-screen equivalent.
    /// Omitting it from the focus chain also keeps the focus engine
    /// from requiring an extra left-then-right D-pad step to reach
    /// the scrubber.
    ///
    /// The icon matches current state (not the action): `pause.fill`
    /// while paused, `play.fill` while playing. Read it as "the
    /// stream is currently X".
    #if os(tvOS)
    private var tvPlayPauseIndicator: some View {
        Image(systemName: progressStore.isPaused ? "pause.fill" : "play.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progressStore.isPaused ? "Paused" : "Playing")
            .animation(.easeInOut(duration: 0.15), value: progressStore.isPaused)
    }
    #endif

    private var centerPlayPauseButton: some View {
        Button {
            progressStore.togglePauseAction?()
            if !progressStore.isPaused {
                scheduleControlsHide()
            } else {
                controlsHideTask?.cancel()
            }
        } label: {
            Image(systemName: progressStore.isPaused ? "play.fill" : "pause.fill")
                #if os(tvOS)
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 96, height: 96)
                #else
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 72, height: 72)
                #endif
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        }
        #if os(tvOS)
        .buttonStyle(TVNoRingButtonStyle())
        .focused($tvFocus, equals: .playPause)
        #endif
        .animation(.easeInOut(duration: 0.15), value: progressStore.isPaused)
    }

    private func scheduleControlsHide() {
        guard !progressStore.isPaused else { return }
        #if os(tvOS)
        guard !isScrubbing else { return }  // Never auto-hide while user is scrubbing
        #endif
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
            }
        }
    }

    #if os(tvOS)
    // MARK: - tvOS Remote Hints

    private var tvRemoteHints: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                // Speed / subtitle hints above scrubber
                HStack(spacing: 24) {
                    if !isLive {
                        hintPill(icon: "chevron.up", text: "Speed")
                    }
                    hintPill(icon: "circle.fill", text: "Play/Pause", size: 8)
                    if !progressStore.subtitleTracks.isEmpty {
                        hintPill(icon: "chevron.down", text: "Subtitles")
                    }
                }
                // Scrubber hint
                if !isLive {
                    hintPill(icon: "arrow.left.and.right", text: "Scrub Timeline  \u{2022}  Hold to Seek Faster")
                }
            }
            .padding(.bottom, 160)
        }
    }

    private func hintPill(icon: String, text: String, size: CGFloat = 10) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .bold))
            Text(text)
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.6))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.1), in: Capsule())
    }
    #endif
}

// MARK: - Player Overflow Menu (isolated from rapid progress updates)

/// Extracted into its own Equatable view so that high-frequency
/// `PlayerProgressStore` publishes (position, stream-info, buffer) don't
/// cause the system Menu popover to flicker.  SwiftUI skips re-rendering
/// when all Equatable inputs are unchanged.
struct PlayerOverflowMenu: View, Equatable {
    // Value properties — used for rendering AND equality comparison.
    let audioTracks: [MediaTrack]
    let currentAudioTrackID: Int
    let subtitleTracks: [MediaTrack]
    let currentSubtitleTrackID: Int
    let speed: Double
    let isLive: Bool
    let sleepTimerEnd: Date?
    let showStreamInfo: Bool
    let isAudioOnly: Bool
    /// When true, the menu shows a "Record Current Program" item that
    /// fires `recordAction`. Gated off the audio tile's live EPG state
    /// in the unified chrome so it hides for streams without EPG data.
    let canRecord: Bool

    // Action closures — excluded from equality check.
    var setAudioTrack: ((Int) -> Void)?
    var setSubtitleTrack: ((Int) -> Void)?
    var setSpeed: ((Double) -> Void)?
    var setSleepTimer: ((Date?) -> Void)?
    var toggleStreamInfo: (() -> Void)?
    var toggleAudioOnly: (() -> Void)?
    var recordAction: (() -> Void)?
    var onMenuOpen: (() -> Void)?
    var onMenuClose: (() -> Void)?

    // Only compare the data that affects rendering — skip closures.
    nonisolated static func == (lhs: PlayerOverflowMenu, rhs: PlayerOverflowMenu) -> Bool {
        lhs.audioTracks == rhs.audioTracks &&
        lhs.currentAudioTrackID == rhs.currentAudioTrackID &&
        lhs.subtitleTracks == rhs.subtitleTracks &&
        lhs.currentSubtitleTrackID == rhs.currentSubtitleTrackID &&
        lhs.speed == rhs.speed &&
        lhs.isLive == rhs.isLive &&
        lhs.sleepTimerEnd == rhs.sleepTimerEnd &&
        lhs.showStreamInfo == rhs.showStreamInfo &&
        lhs.isAudioOnly == rhs.isAudioOnly &&
        lhs.canRecord == rhs.canRecord
    }

    private var sleepTimerRemainingText: String? {
        guard let end = sleepTimerEnd else { return nil }
        let remaining = end.timeIntervalSince(Date())
        guard remaining > 0 else { return nil }
        let mins = Int(remaining / 60)
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(mins)m"
    }

    var body: some View {
        Menu {
            Group {
                // Audio track (sub-menu, only when multiple)
                if audioTracks.count > 1 {
                    Menu {
                        ForEach(audioTracks) { track in
                            Button {
                                setAudioTrack?(track.id)
                            } label: {
                                if track.id == currentAudioTrackID {
                                    Label(track.displayName, systemImage: "checkmark")
                                } else {
                                    Text(track.displayName)
                                }
                            }
                        }
                    } label: {
                        Label("Audio Track", systemImage: "waveform.circle")
                    }
                }

                // Subtitles (sub-menu, only when available)
                if !subtitleTracks.isEmpty {
                    Menu {
                        Button {
                            setSubtitleTrack?(0)
                        } label: {
                            if currentSubtitleTrackID == 0 {
                                Label("Off", systemImage: "checkmark")
                            } else {
                                Text("Off")
                            }
                        }
                        ForEach(subtitleTracks) { track in
                            Button {
                                setSubtitleTrack?(track.id)
                            } label: {
                                if track.id == currentSubtitleTrackID {
                                    Label(track.displayName, systemImage: "checkmark")
                                } else {
                                    Text(track.displayName)
                                }
                            }
                        }
                    } label: {
                        Label {
                            if currentSubtitleTrackID != 0,
                               let track = subtitleTracks.first(where: { $0.id == currentSubtitleTrackID }) {
                                Text("Subtitles: \(track.displayName)")
                            } else {
                                Text("Subtitles")
                            }
                        } icon: {
                            Image(systemName: "captions.bubble")
                        }
                    }
                }

                // Playback speed (VOD only)
                if !isLive {
                    let speeds = PlayerProgressStore.speedOptions
                    Menu {
                        ForEach(speeds, id: \.self) { spd in
                            Button {
                                setSpeed?(spd)
                            } label: {
                                let label = spd == 1.0 ? "Normal" : "\(String(format: "%g", spd))x"
                                if spd == speed {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    } label: {
                        let speedLabel = speed == 1.0 ? "1x" : "\(String(format: "%g", speed))x"
                        Label("Speed: \(speedLabel)", systemImage: "gauge.with.dots.needle.67percent")
                    }
                }

                Divider()

                // Record current program. Gated on `canRecord` so streams
                // without live EPG data (raw M3U / missing tvg-id) don't
                // show an item the user can't usefully tap.
                if canRecord {
                    Button {
                        recordAction?()
                    } label: {
                        Label("Record Current Program", systemImage: "record.circle")
                    }
                }

                // Sleep timer (sub-menu)
                Menu {
                    if sleepTimerEnd != nil {
                        Button(role: .destructive) {
                            setSleepTimer?(nil)
                        } label: {
                            Label("Cancel Timer", systemImage: "xmark")
                        }
                        Divider()
                    }
                    ForEach([30, 60, 90, 120], id: \.self) { minutes in
                        Button {
                            setSleepTimer?(Date().addingTimeInterval(Double(minutes) * 60))
                        } label: {
                            Text("\(minutes) minutes")
                        }
                    }
                } label: {
                    if let remaining = sleepTimerRemainingText {
                        Label("Sleep Timer: \(remaining)", systemImage: "moon.zzz.fill")
                    } else {
                        Label("Sleep Timer", systemImage: "moon.zzz")
                    }
                }

                // Stream info (toggle)
                Button {
                    toggleStreamInfo?()
                } label: {
                    Label(
                        showStreamInfo ? "Hide Stream Info" : "Stream Info",
                        systemImage: showStreamInfo ? "info.circle.fill" : "info.circle"
                    )
                }

                #if os(iOS)
                Divider()

                // Audio only
                Button {
                    toggleAudioOnly?()
                } label: {
                    Label(
                        isAudioOnly ? "Show Video" : "Audio Only",
                        systemImage: isAudioOnly ? "video.fill" : "music.note"
                    )
                }

                // Picture-in-Picture is automatic — no manual menu item.
                // Swipe home to shrink the player into a floating window;
                // controlled by Settings → Appearance → Picture-in-Picture.

                // AirPlay. Routes audio only on iPhone (the mix of HLS +
                // MPV-backed TS streams rules out reliable video routing),
                // so the menu placement matches its actual scope — no
                // point taking a top-bar chrome slot for audio routing.
                Button {
                    AirPlayMenuTrigger.present()
                } label: {
                    Label("AirPlay (Audio Only)", systemImage: "airplay.audio")
                }
                #endif
            }
            #if os(iOS)
            // Cancel auto-hide while the menu popover is open so the
            // anchor view stays in the hierarchy and items remain tappable.
            .onAppear { onMenuOpen?() }
            .onDisappear { onMenuClose?() }
            #endif
        } label: {
            Image(systemName: "ellipsis")
                #if os(tvOS)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
                #else
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                #endif
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
    }
}

// MARK: - tvOS Player Options Sheet

#if os(tvOS)
/// Full-screen options sheet presented on tvOS when the user presses Select
/// while player controls are visible. Provides audio, subtitle, speed,
/// sleep timer, and stream info toggles in a focusable list.
/// Compact floating options panel that extends upward from the Options pill.
struct TVPlayerOptionsPanel: View {
    let audioTracks: [MediaTrack]
    let currentAudioTrackID: Int
    let subtitleTracks: [MediaTrack]
    let currentSubtitleTrackID: Int
    let speed: Double
    let isLive: Bool

    @Binding var sleepTimerEnd: Date?
    @Binding var showStreamInfo: Bool

    var setAudioTrack: ((Int) -> Void)?
    var setSubtitleTrack: ((Int) -> Void)?
    var setSpeed: ((Double) -> Void)?
    var onDismiss: (() -> Void)?
    /// Fires when the user picks "Enter Multiview" from the panel.
    /// The caller is responsible for seeding + flipping the
    /// `PlayerSession` mode; the panel just reports the intent and
    /// dismisses itself. v1 only shows the option during live-TV
    /// playback (the panel is already gated on that upstream).
    var onEnterMultiview: (() -> Void)?

    /// Focus tracking for every pill in the panel. Each pill binds to
    /// a unique string id via `.focused($focusedID, equals:)`; the
    /// `optionPill` helper reads `focusedID == id` to drive the
    /// accent-stroke highlight. A single @FocusState avoids the
    /// per-item state proliferation a multi-state approach would
    /// need, and gives us a sane "first pill focused on appear"
    /// behavior via `firstFocusableID`.
    @FocusState private var focusedID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                audioSection
                subtitleSection
                if !isLive { speedSection }
                sleepTimerSection
                if isLive, onEnterMultiview != nil {
                    multiviewSection
                }
                streamInfoSection
            }
            .padding(20)
        }
        .focusEffectDisabled()
        .frame(width: 460)
        .frame(maxHeight: 560)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
        .onAppear {
            // Land focus on the first rendered pill after a tick so
            // the focus engine has finished laying out the buttons.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedID = firstFocusableID
            }
        }
    }

    /// Decides which pill is the default-focused one on appear,
    /// walking the same order the body renders: audio → subtitles →
    /// speed (VOD) → sleep timer → multiview → stream-info. Lands
    /// on a real id so the `@FocusState` binding takes.
    private var firstFocusableID: String {
        if audioTracks.count > 1, let first = audioTracks.first {
            return "audio-\(first.id)"
        }
        if !subtitleTracks.isEmpty {
            return "sub-0"  // "Off" pill
        }
        if !isLive, let firstSpeed = PlayerProgressStore.speedOptions.first {
            return "speed-\(firstSpeed)"
        }
        if sleepTimerEnd != nil {
            return "sleep-cancel"
        }
        return "sleep-30"
    }

    // MARK: - Sections

    @ViewBuilder private var audioSection: some View {
        if audioTracks.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Audio Track")
                ForEach(audioTracks) { track in
                    optionPill(
                        id: "audio-\(track.id)",
                        text: track.displayName,
                        isSelected: track.id == currentAudioTrackID
                    ) {
                        setAudioTrack?(track.id); onDismiss?()
                    }
                }
            }
        }
    }

    @ViewBuilder private var subtitleSection: some View {
        if !subtitleTracks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Subtitles")
                optionPill(id: "sub-0", text: "Off", isSelected: currentSubtitleTrackID == 0) {
                    setSubtitleTrack?(0); onDismiss?()
                }
                ForEach(subtitleTracks) { track in
                    optionPill(
                        id: "sub-\(track.id)",
                        text: track.displayName,
                        isSelected: track.id == currentSubtitleTrackID
                    ) {
                        setSubtitleTrack?(track.id); onDismiss?()
                    }
                }
            }
        }
    }

    @ViewBuilder private var speedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Speed")
            ForEach(PlayerProgressStore.speedOptions, id: \.self) { spd in
                let selected = spd == speed
                optionPill(
                    id: "speed-\(spd)",
                    text: spd == 1.0 ? "Normal" : "\(String(format: "%g", spd))x",
                    isSelected: selected
                ) {
                    setSpeed?(spd); onDismiss?()
                }
            }
        }
    }

    @ViewBuilder private var sleepTimerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Sleep Timer")
            if sleepTimerEnd != nil {
                optionPill(id: "sleep-cancel", text: "Cancel Timer", isSelected: false) {
                    sleepTimerEnd = nil; onDismiss?()
                }
            }
            ForEach([30, 60, 90, 120], id: \.self) { mins in
                optionPill(
                    id: "sleep-\(mins)",
                    text: "\(mins) minutes",
                    isSelected: false
                ) {
                    sleepTimerEnd = Date().addingTimeInterval(Double(mins) * 60); onDismiss?()
                }
            }
        }
    }

    /// "Add Stream" row. Only rendered for live streams when the
    /// outer view provided an `onEnterMultiview` closure (i.e. from
    /// HomeView's live-TV mount path). Named "Add Stream" — not
    /// "Enter Multiview" — because user feedback was that the
    /// mode-switch framing felt jarring. Tapping fires the closure
    /// (which flips `PlayerRootView`'s `showAddStreamSheet` state)
    /// and dismisses the panel. The sheet presents on top of the
    /// still-playing PlayerView; only when the user picks a channel
    /// does the sheet call `PlayerSession.enterMultiview(seeding:server:)`
    /// and transition to the grid. Browsing the picker does NOT
    /// interrupt playback.
    @ViewBuilder private var multiviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Add Stream")
            optionPill(
                id: "multiview-enter",
                text: "Add Another Channel…",
                systemImage: "plus.rectangle.on.rectangle",
                isSelected: false
            ) {
                onEnterMultiview?()
                onDismiss?()
            }
        }
    }

    /// Stream Info lives in its own section but uses the same pill
    /// chrome as every other row — just with a leading info icon and
    /// the title swapping based on the current toggle state. Unified
    /// so the whole panel reads as one consistent focusable list.
    @ViewBuilder private var streamInfoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Diagnostics")
            optionPill(
                id: "stream-info",
                text: showStreamInfo ? "Hide Stream Info" : "Stream Info",
                systemImage: showStreamInfo ? "info.circle.fill" : "info.circle",
                isSelected: showStreamInfo
            ) {
                showStreamInfo.toggle()
                onDismiss?()
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.45))
            .textCase(.uppercase)
    }

    /// Pill-shaped focusable option. Visual states:
    ///
    /// - **Default**: subtle white fill, hairline white stroke
    /// - **Selected** (checkmark, e.g. current audio track): deeper
    ///   white fill + bolder text + accent checkmark on the right
    /// - **Focused** (tvOS focus engine): `accentPrimary` 22% fill,
    ///   `accentPrimary` 70% stroke at 2.5pt. Matches the focus
    ///   chrome of `tvSettingsCardBG` so the panel feels like the
    ///   rest of the app.
    ///
    /// Why `TVNoHighlightButtonStyle` + an inner label that reads
    /// `@Environment(\.isFocused)`: plain `.buttonStyle(.plain)`
    /// does NOT remove tvOS's system focus halo — it only strips
    /// the default button presentation. The halo stacks on top of
    /// our custom accent chrome, producing a bright white outline
    /// around the pill (user-reported). `TVNoHighlightButtonStyle`
    /// explicitly suppresses the halo AND provides a subtle scale
    /// + brightness focus cue; our label reads
    /// `@Environment(\.isFocused)` (populated by that style) to
    /// drive the accent fill + stroke. One focus signal, no
    /// double-highlight.
    ///
    /// `systemImage` is optional — nil by default. Passed non-nil
    /// for the Stream Info row which needs a leading icon.
    private func optionPill(
        id: String,
        text: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            OptionPillLabel(
                text: text,
                systemImage: systemImage,
                isSelected: isSelected
            )
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focusEffectDisabled()
        .focused($focusedID, equals: id)
    }
}

/// Inner label for `optionPill` — rendered inside the Button so it
/// picks up `@Environment(\.isFocused)` populated by the button
/// style. Drives accent fill + stroke based on focus; checkmark
/// for selected state inverts color when the pill is focused so
/// it stays readable over the accent-tinted background.
private struct OptionPillLabel: View {
    let text: String
    let systemImage: String?
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(text)
                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                .foregroundColor(.white)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isFocused ? .white : Color.accentPrimary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule().fill(pillFill)
        )
        .overlay(
            Capsule().stroke(
                isFocused ? Color.accentPrimary.opacity(0.70) : Color.white.opacity(0.08),
                lineWidth: isFocused ? 2.5 : 1
            )
        )
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    /// Fill-color precedence: focused > selected > default.
    private var pillFill: Color {
        if isFocused { return Color.accentPrimary.opacity(0.22) }
        if isSelected { return Color.white.opacity(0.10) }
        return Color.white.opacity(0.04)
    }
}
#endif


// MARK: - AirPlay Route Picker Button
#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Color.accentPrimary)
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - AirPlay Menu Trigger
// We moved AirPlay off the top-chrome button row and into the overflow
// menu. Since AerioTV streams audio-only via AirPlay (no video routing
// on iPhone given the mix of HLS + MPV-backed TS streams), a dedicated
// visible button was chrome bloat. Menus, however, can't host an
// interactive `AVRoutePickerView` directly — items are rendered as
// Buttons by SwiftUI. We route the menu tap through this helper,
// which keeps one `AVRoutePickerView` permanently attached to the
// key window (invisible and sized 1×1 offscreen) and fires the
// touchUpInside on its internal UIButton when `present()` is called.
//
// Subview-hopping into `AVRoutePickerView` is not officially blessed
// by Apple but is the documented workaround across the iOS community
// (Podcasts, Spotify, etc. all do it). The route picker view's
// private subview layout has been stable through iOS 13 → 18; if
// Apple ever rearranges it, `present()` becomes a no-op and the
// user can still reach AirPlay via Control Center — a graceful
// degradation rather than a crash.
@MainActor
enum AirPlayMenuTrigger {
    private static let pickerView: AVRoutePickerView = {
        let v = AVRoutePickerView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        v.alpha = 0.01       // kept non-zero so the subview button stays touch-enabled
        v.isUserInteractionEnabled = true
        return v
    }()

    /// Attach the hidden picker view to the app's key window (idempotent)
    /// and fire the underlying UIButton's touchUpInside action to make iOS
    /// present the system AirPlay route selection sheet.
    static func present() {
        attachIfNeeded()
        for subview in pickerView.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
        // Iteration fallback — Apple has historically nested the button one
        // level deeper in some iOS versions. Walk one layer down before
        // giving up.
        for subview in pickerView.subviews {
            for inner in subview.subviews {
                if let button = inner as? UIButton {
                    button.sendActions(for: .touchUpInside)
                    return
                }
            }
        }
    }

    private static func attachIfNeeded() {
        guard pickerView.superview == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let window = activeScene?.windows.first(where: { $0.isKeyWindow })
                ?? activeScene?.windows.first else { return }
        window.addSubview(pickerView)
    }
}
#else
struct AirPlayButton: View {
    var body: some View { EmptyView() }
}
#endif

// MARK: - tvOS Remote Input Handler (gesture recognizers for hold-to-scrub)
#if os(tvOS)
struct TVRemoteInputView: UIViewRepresentable {
    var onLeftHold: (Bool) -> Void    // true = started, false = ended
    var onRightHold: (Bool) -> Void
    var onSeek: (Int32) -> Void       // signed seek delta in ms (negative = back)
    var onUp: () -> Void
    var onDown: () -> Void
    var onSelect: () -> Void
    var onPlayPause: () -> Void
    var onMenu: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TVRemoteUIView {
        let view = TVRemoteUIView()
        view.coordinator = context.coordinator
        context.coordinator.callbacks = self
        view.setupGestures()
        return view
    }

    func updateUIView(_ uiView: TVRemoteUIView, context: Context) {
        context.coordinator.callbacks = self
    }

    class Coordinator: @unchecked Sendable {
        var callbacks: TVRemoteInputView?
        var scrubTimer: Timer?
        var scrubTickCount: Int = 0
        private var activeScrubDirection: Int = 0

        func startScrubTimer(direction: Int) {
            scrubTickCount = 0
            activeScrubDirection = direction
            scrubTimer?.invalidate()
            // First accelerated tick fires immediately
            fireTick()
            // Repeat every 200ms while held
            scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.fireTick()
            }
        }

        func stopScrubTimer() {
            scrubTimer?.invalidate()
            scrubTimer = nil
            scrubTickCount = 0
            activeScrubDirection = 0
        }

        private func fireTick() {
            scrubTickCount += 1
            let tick = scrubTickCount
            let sec: Int32
            if tick <= 3 { sec = 10 }
            else if tick <= 8 { sec = 20 }
            else if tick <= 15 { sec = 30 }
            else { sec = 60 }
            let delta = Int32(activeScrubDirection) * sec * 1000
            DispatchQueue.main.async { [weak self] in
                self?.callbacks?.onSeek(delta)
            }
        }
    }

    class TVRemoteUIView: UIView {
        weak var coordinator: Coordinator?

        override var canBecomeFocused: Bool { true }

        // Explicitly declare self as the preferred focus target so the
        // tvOS focus engine doesn't fall through to views behind the player.
        override var preferredFocusEnvironments: [UIFocusEnvironment] { [self] }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                // Retry focus grab — the first attempt may lose to views
                // that are already in the hierarchy (e.g. the guide).
                for delay in [0.15, 0.5, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.window != nil, !self.isFocused else { return }
                        self.setNeedsFocusUpdate()
                        self.updateFocusIfNeeded()
                    }
                }
            }
        }

        func setupGestures() {
            // --- Left arrow: tap + long-press ---
            let leftLong = UILongPressGestureRecognizer(target: self, action: #selector(leftLongPress(_:)))
            leftLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
            leftLong.minimumPressDuration = 0.3
            addGestureRecognizer(leftLong)

            let leftTap = UITapGestureRecognizer(target: self, action: #selector(leftTapped))
            leftTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
            leftTap.require(toFail: leftLong)
            addGestureRecognizer(leftTap)

            // --- Right arrow: tap + long-press ---
            let rightLong = UILongPressGestureRecognizer(target: self, action: #selector(rightLongPress(_:)))
            rightLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
            rightLong.minimumPressDuration = 0.3
            addGestureRecognizer(rightLong)

            let rightTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped))
            rightTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
            rightTap.require(toFail: rightLong)
            addGestureRecognizer(rightTap)

            // --- Other buttons: tap only ---
            let pressTypes: [(UIPress.PressType, Selector)] = [
                (.upArrow, #selector(upTapped)),
                (.downArrow, #selector(downTapped)),
                (.select, #selector(selectTapped)),
                (.playPause, #selector(playPauseTapped)),
                (.menu, #selector(menuTapped)),
            ]
            for (pt, sel) in pressTypes {
                let tap = UITapGestureRecognizer(target: self, action: sel)
                tap.allowedPressTypes = [NSNumber(value: pt.rawValue)]
                addGestureRecognizer(tap)
            }
        }

        // MARK: - Left arrow

        @objc private func leftTapped() {
            coordinator?.callbacks?.onSeek(-10_000)
            // Brief visual feedback
            coordinator?.callbacks?.onLeftHold(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.coordinator?.callbacks?.onLeftHold(false)
            }
        }

        @objc private func leftLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let coordinator else { return }
            switch gesture.state {
            case .began:
                coordinator.callbacks?.onLeftHold(true)
                coordinator.startScrubTimer(direction: -1)
            case .ended, .cancelled, .failed:
                coordinator.stopScrubTimer()
                coordinator.callbacks?.onLeftHold(false)
            default: break
            }
        }

        // MARK: - Right arrow

        @objc private func rightTapped() {
            coordinator?.callbacks?.onSeek(10_000)
            coordinator?.callbacks?.onRightHold(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.coordinator?.callbacks?.onRightHold(false)
            }
        }

        @objc private func rightLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let coordinator else { return }
            switch gesture.state {
            case .began:
                coordinator.callbacks?.onRightHold(true)
                coordinator.startScrubTimer(direction: 1)
            case .ended, .cancelled, .failed:
                coordinator.stopScrubTimer()
                coordinator.callbacks?.onRightHold(false)
            default: break
            }
        }

        // MARK: - Other buttons

        @objc private func upTapped() { coordinator?.callbacks?.onUp() }
        @objc private func downTapped() { coordinator?.callbacks?.onDown() }
        @objc private func selectTapped() { coordinator?.callbacks?.onSelect() }
        @objc private func playPauseTapped() { coordinator?.callbacks?.onPlayPause() }
        @objc private func menuTapped() { coordinator?.callbacks?.onMenu() }
    }
}
#endif

