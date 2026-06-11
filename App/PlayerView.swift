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

/// Standalone Stream Info card used by both `PlayerView` (legacy
/// single-stream path) and `MultiviewContainerView` (unified path).
/// v1.6.15.x: extracted from PlayerView's private `streamInfoOverlay`
/// because the unified path's `MultiviewContainerView` had its
/// `showStreamInfo` toggle wired but no actual overlay mount —
/// toggling the row in Options did nothing visible. Sharing one card
/// view keeps the visual treatment identical across both paths.
///
/// v1.6.19: reverted the v1.6.18 Dispatcharr server-side stats path
/// and the 5-field redesign. The card now renders the original
/// 6-row layout (VIDEO / AUDIO / CACHE / SYNC) sourced exclusively
/// from mpv on every server type. Rationale: Dispatcharr's
/// `stream_stats` describe what the SERVER is doing, not what's
/// arriving at the device. Users care about what their player is
/// actually decoding — which mpv reports authoritatively across
/// every server type. Same numbers everywhere = consistent UX,
/// fewer "why is the resolution different on Apple TV vs iPhone"
/// questions, less plumbing to maintain.
struct StreamInfoCardView: View {
    let info: StreamInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "VIDEO", value: "\(info.videoCodec)  \(info.width)×\(info.height)")
            row(label: "", value: "\(String(format: "%.2f", info.fps))fps  \(info.pixelFormat)")
            row(label: "", value: "hwdec: \(info.hwdec)")
            row(label: "AUDIO", value: "\(info.audioCodec)  \(info.sampleRate)Hz  \(info.channels)ch")
            row(label: "CACHE", value: "\(String(format: "%.1f", info.cacheDuration))s  \(StreamInfoCardView.formatBitrate(info.bitrate))")
            row(label: "SYNC", value: "\(String(format: "%.3f", info.avsync))s  drops: \(info.droppedFrames)")
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

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
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
                Color.clear.frame(width: 46, height: 1)
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

    static func formatBitrate(_ bytesPerSec: Double) -> String {
        let mbps = bytesPerSec * 8.0 / 1_000_000.0
        if mbps >= 1.0 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f kbps", mbps * 1000)
        }
    }
}

// MARK: - Video Aspect Mode (issue #26)

/// How the decoded video is sized inside the player, applied to the
/// `AVSampleBufferDisplayLayer`'s `videoGravity`. `fit` is the default
/// (letterbox, whole frame visible); `fill` crops to fill the screen
/// while preserving aspect; `stretch` fills the screen ignoring aspect.
enum VideoAspectMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit:     return "Fit"
        case .fill:    return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var icon: String {
        switch self {
        case .fit:     return "rectangle.arrowtriangle.2.inward"
        case .fill:    return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit:     return .resizeAspect
        case .fill:    return .resizeAspectFill
        case .stretch: return .resize
        }
    }
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
    /// True when a non-live VOD file has played all the way to its end.
    /// Set by the Coordinator's `handleEndFile` VOD branch and cleared
    /// whenever a fresh file starts loading or the user replays from 0.
    /// Multiview reads this (per-tile) to show a "Finished" overlay and
    /// to hand audio off to another tile; the legacy single PlayerView
    /// ignores it (it has its own end handling), so adding it here is a
    /// no-op for that path. Never set for live or DVR live-edge EOF.
    @Published var reachedEOF: Bool = false
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
    /// Closure set by the Coordinator; replays the current VOD file from
    /// the start. Distinct from `seekAction` because a VOD that has hit
    /// EOF has `playbackEnded` latched, which the normal seek guard
    /// blocks. This path clears that latch (and `reachedEOF`), seeks to
    /// 0, and unpauses. Used by the multiview "Finished" overlay's Replay
    /// button. Nil / unused on the legacy single PlayerView path.
    var replayFromStartAction: (() -> Void)?
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
    /// On-screen video sizing (issue #26). The Coordinator observes this and
    /// applies the matching `videoGravity` to the display layer. Self-seeds
    /// from UserDefaults so the user's choice survives across streams and
    /// launches; the overflow menu's action writes the same key.
    @Published var aspectMode: VideoAspectMode =
        VideoAspectMode(rawValue: UserDefaults.standard.string(forKey: "player.aspectMode") ?? "") ?? .fit
    /// Stream technical info (codec, resolution, bitrate, etc.) sourced
    /// from mpv. Populated for live playback and read by the Stream
    /// Info overlay on every server type.
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
    /// True when this is an in-progress DVR recording: a growing
    /// seekable window from the recording's start to the live edge,
    /// rather than a fixed-duration file. Drives the live-edge seek
    /// clamp + LIVE timeline affordance. Always false for live TV and
    /// regular VOD.
    let isDVR: Bool
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
         isLive: Bool = true, isDVR: Bool = false,
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
        self.isDVR = isDVR
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

    // The "Apple TV up/down channel-flip" toggle (v1.7.x) lives on
    // `PlayerRootView` because that's where `.onMoveCommand` is
    // mounted. PlayerView itself doesn't read the value.

    var body: some View {
        PlayerRootView(
            urls: urls, title: title, headers: headers,
            isLive: isLive, isDVR: isDVR,
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
    case scrubber     // VOD timeline (focusable while chrome is visible)
}
#endif

private struct PlayerRootView: View {
    let urls: [URL]
    let title: String
    let headers: [String: String]
    let isLive: Bool
    /// See `PlayerView.isDVR`. Mirrored here (the timeline math lives in
    /// this view) and threaded into the Coordinator for the live-edge
    /// seek clamp.
    let isDVR: Bool
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

    /// v1.7.x: gates the Apple TV up/down d-pad channel-flip on
    /// single-stream live playback. Default ON to preserve the
    /// behaviour shipped since v1.6.15. Surfaced in Settings →
    /// App Behaviors → Apple TV Remote. Mirrored on `PlayerView`
    /// for parity (each struct's @AppStorage shares the same
    /// UserDefaults backing store, so they stay in sync).
    @AppStorage("appBehaviorsAppleTVChannelFlip")
    private var appleTVChannelFlip = true

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
    // iOS: after a drag releases, hold the bar at the released position
    // until mpv's reported position catches up (mirrors the tvOS
    // scrubSettleTask), so the thumb doesn't snap back to the stale
    // pre-seek spot and then jump forward.
    @State private var dragSettling = false
    @State private var dragSettleTask: Task<Void, Never>?
    /// iOS full-screen button: when true the player has forced the window
    /// into landscape (overriding a portrait rotation-lock). Released when
    /// toggled off or when the player closes.
    @State private var forcedLandscape = false

    #if os(tvOS)
    @State private var isScrubbing = false         // True while previewing a scrub position
    @State private var scrubTargetMs: Int32 = 0    // Preview playhead, committed on idle/Select
    @State private var scrubLastDirection = 0      // -1 left, +1 right (drives hold acceleration)
    @State private var scrubAccelCount = 0         // Consecutive same-direction steps
    @State private var scrubCommitTask: Task<Void, Never>?
    @State private var scrubSettleTask: Task<Void, Never>?  // Holds the playhead at the target until mpv catches up post-seek
    #endif

    enum PlayState { case loading, playing, error }

    @ViewBuilder
    private var playerView: some View {
        #if canImport(Libmpv)
        // v1.7.x: black backdrop directly behind the representable so
        // the AerioTV navy theme background can't leak through during
        // the ~1.5s window before the first decoded frame lands. The
        // outer ZStack at body level already paints black, but on
        // some layout paths (UHD letterbox, multiview tile transitions)
        // SwiftUI's UIViewControllerRepresentable host appears to
        // briefly show through to the SwiftUI background fill rather
        // than the ZStack's Color.black. Adding an explicit
        // `.background(Color.black)` on the representable closes that
        // gap regardless of which parent is rendering. Combined with
        // the `view.backgroundColor = .black` set in viewDidLoad, this
        // is a double-fence: the UIKit side is black, AND the SwiftUI
        // side is black.
        MPVPlayerViewRepresentable(
            urls: urls, headers: headers,
            isLive: isLive, isDVR: isDVR,
            nowPlayingTitle: title,
            nowPlayingSubtitle: subtitle,
            nowPlayingArtworkURL: artworkURL,
            progressStore: progressStore,
            logStore: logStore,
            onFatalError: { err in lastError = err; state = .error }
        )
        .background(Color.black)
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
                            // v1.6.15: Apple TV up/down channel-flip
                            // for live single-stream playback. Gated
                            // on chrome being hidden AND live — when
                            // the user has summoned chrome via
                            // Menu/Back, up/down should walk the
                            // chrome controls (Options pill, Stream
                            // info row), NOT flip channels behind
                            // their back. Pressing Menu/Back again
                            // hides chrome and re-enables flip.
                            //
                            // v1.7.x: also gated on the Settings →
                            // App Behaviors toggle. Users who hit
                            // accidental D-pad presses can disable
                            // the flip without losing other remote
                            // behaviours.
                            if appleTVChannelFlip, isLive, !showControls,
                               direction == .up || direction == .down {
                                NowPlayingManager.shared.changeChannel(
                                    direction: direction == .up ? +1 : -1
                                )
                                return
                            }
                            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                            scheduleControlsHide()
                            // VOD: a left/right press from the hidden-chrome
                            // state reveals the timeline (focus lands on the
                            // scrubber via onChange(showControls)) and starts a
                            // scrub preview. No seek fires until commit, so the
                            // video keeps playing with no per-press buffer stall.
                            if !isLive, isScrubberActive {
                                if direction == .left { scrubStep(-1) }
                                else if direction == .right { scrubStep(+1) }
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
        // Release a forced-landscape lock when the player closes so the
        // rest of the app returns to the device's own orientation.
        .onDisappear { if forcedLandscape { requestOrientation(landscape: false) } }
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard state == .playing, value.translation.height > 0 else { return }
                    // v1.6.18: when chrome is visible, a downward swipe
                    // is a channel-flip-down gesture (handled in
                    // onEnded below) — NOT a minimize. Skip the
                    // dragOffset assignment so the player doesn't
                    // visually slide while the user is trying to flip.
                    if showControls { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    guard state == .playing else { return }

                    // v1.6.18: chrome-visible vertical swipe = channel
                    // flip (live only). User flow: tap once to summon
                    // chrome, then swipe up/down to flip channels;
                    // each flip refreshes the chrome fade timer so
                    // the Tap → Swipe → Swipe → Swipe flow stays
                    // alive without re-tapping. Inverted from the
                    // tvOS gate at line ~590 above (which flips on
                    // !showControls, since tvOS chrome-visible
                    // up/down navigates the Options pill row).
                    // Direction matches tvOS: up = next (+1), down
                    // = previous (-1). Strong vertical bias keeps
                    // iPad split-view drag-from-edge from being
                    // misread as a channel flip.
                    // v1.7.x: also gated on the Settings → App
                    // Behaviors → "Up / Down channel change" toggle.
                    // iOS swipe + tvOS d-pad share the same storage
                    // key; users who turn the feature off don't get
                    // accidental flips from either input path.
                    if appleTVChannelFlip, showControls, isLive {
                        let dy = value.translation.height
                        let dx = abs(value.translation.width)
                        if abs(dy) > 40, abs(dy) > dx * 1.5 {
                            let direction = dy < 0 ? +1 : -1
                            NowPlayingManager.shared.changeChannel(direction: direction)
                            scheduleControlsHide()
                            withAnimation(.spring(response: 0.25)) { dragOffset = 0 }
                            return
                        }
                    }

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
            // If a car is already connected when the player mounts (the user
            // opened the phone app mid-CarPlay session), default to
            // audio-only, same as the fresh-connect handler below.
            if NowPlayingManager.shared.isCarPlayConnected {
                isAudioOnly = true
                progressStore.isAudioOnly = true
            }
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
            // v1.6.18: also publish to the shared NowPlayingManager
            // so `ChannelInfoBanner` can suppress itself while the
            // user has Stream Info open — they sit at the same
            // top-left coordinates on iPhone and would otherwise
            // overlap, covering the stats the user just asked for.
            NowPlayingManager.shared.streamInfoIsVisible = visible
        }
        // v1.6.15: mirror this player's chrome visibility into the
        // shared `NowPlayingManager.chromeIsVisible` flag so the
        // `ChannelInfoBanner` overlay (in HomeView's outer ZStack)
        // can lock step with chrome's auto-fade. Cross-platform —
        // both legacy iOS PlayerView and tvOS need this; the
        // unified iOS path goes through `MultiviewContainerView`'s
        // own mirror and lands in the same shared flag.
        .onChange(of: showControls) { _, visible in
            NowPlayingManager.shared.chromeIsVisible = visible
        }
        // v1.6.15: wake the chrome only on stream starts that asked
        // for it (cold-launch auto-resume, channel-row tap). Siri
        // Remote up/down flips intentionally do not bump
        // `chromeWakeToken` — a flip should keep chrome hidden so
        // the next up/down keeps flipping channels. The banner
        // (HomeView's `ChannelInfoBanner`) still surfaces on every
        // flip via its own 5s timer.
        .onChange(of: NowPlayingManager.shared.chromeWakeToken) { _, newToken in
            guard newToken != nil, isLive else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            scheduleControlsHide()
        }
        // CarPlay sessions default to audio-only (the driver is not watching
        // the phone). The existing Show Video toggle still overrides it for a
        // passenger; disconnecting CarPlay returns to video. Drives the same
        // isAudioOnly path the overflow toggle uses. No-op on tvOS (CarPlay
        // never connects there).
        .onChange(of: NowPlayingManager.shared.isCarPlayConnected) { _, connected in
            isAudioOnly = connected
            progressStore.isAudioOnly = connected
        }
        #if os(tvOS)
        .onChange(of: showControls) { _, visible in
            // Drive focus between the invisible background capture layer
            // (chrome hidden) and the chrome itself. For VOD the timeline
            // scrubber is the default landing spot so the user can scrub
            // right away; live (no seekable timeline) and the mini player
            // fall back to the Options pill.
            if visible {
                tvFocus = (!isLive && isScrubberActive) ? .scrubber : .gearIcon
            } else {
                tvFocus = .background
                cancelScrub()
            }
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
        .onAppear { tvFocus = showControls ? ((!isLive && isScrubberActive) ? .scrubber : .gearIcon) : .background }
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

    /// The right end of the seekable timeline, in ms.
    ///
    /// - Regular VOD: mpv's reported `duration` (a fixed file length).
    /// - DVR (in-progress recording): the live edge of a growing HLS
    ///   window. mpv's `duration` tracks the published-playlist extent,
    ///   which only grows; flooring it at `currentMs` keeps the bar from
    ///   ever sitting left of the playhead during a playlist-refresh
    ///   wobble. The right edge therefore represents "live".
    private var timelineEndMs: Int32 {
        if isDVR { return max(progressStore.durationMs, progressStore.currentMs) }
        return progressStore.durationMs
    }

    /// For VOD: once player reports a non-zero duration.
    private var canSeekBackward: Bool {
        timelineEndMs > 0 && progressStore.currentMs > 2_000
    }

    private var canSeekForward: Bool {
        timelineEndMs > 0 && progressStore.currentMs < timelineEndMs - 2_000
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
        guard timelineEndMs > 0 else { return 0 }
        return Int32(fraction * CGFloat(timelineEndMs))
    }

    /// Converts the current playback position to a 0–1 scrubber fraction.
    private var currentFraction: CGFloat {
        guard timelineEndMs > 0 else { return 0 }
        return CGFloat(progressStore.currentMs) / CGFloat(timelineEndMs)
    }

    /// True when the timeline can accept drag/seek gestures.
    private var isScrubberActive: Bool {
        timelineEndMs > 0
    }

    private var scrubberBar: some View {
        // Position holds at the drag fraction both while dragging AND while
        // settling (post-release, until mpv catches up). Thumb SIZE keys off
        // isDragging alone, so it shrinks the instant the finger lifts.
        let displayFraction: CGFloat = (isDragging || dragSettling) ? dragFraction : max(0, min(1, currentFraction))

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
                        dragSettleTask?.cancel()  // a fresh drag supersedes any settle
                        dragSettling = false
                        isDragging = true
                        dragFraction = max(0, min(1, value.location.x / geo.size.width))
                        scheduleControlsHide()
                    }
                    .onEnded { value in
                        guard isScrubberActive else { return }
                        let f = max(0, min(1, value.location.x / geo.size.width))
                        let target = fractionToMs(f)
                        dragFraction = f
                        progressStore.seekAction?(target)
                        withAnimation(.easeOut(duration: 0.15)) { isDragging = false }
                        // Hold the bar at the released position until mpv's
                        // reported position lands within a GOP of the target
                        // (keyframe seeks land a little short), then release
                        // it onto the real position instead of snapping back.
                        dragSettling = true
                        dragSettleTask?.cancel()
                        dragSettleTask = Task { @MainActor in
                            for _ in 0..<75 {  // ~6s backstop at 80ms/iter
                                if Task.isCancelled { return }
                                if abs(Int64(progressStore.currentMs) - Int64(target)) < 4_000 { break }
                                try? await Task.sleep(nanoseconds: 80_000_000)
                            }
                            guard !Task.isCancelled else { return }
                            dragSettling = false
                        }
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
        let focused = (tvFocus == .scrubber)
        let active = isScrubbing || focused
        let displayFraction: CGFloat = max(0, min(1, tvDisplayFraction))

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
        // Glide the thumb/fill between scrub steps instead of teleporting,
        // so a held scrub reads as one continuous sweep rather than a
        // sequence of 10s jumps (user feedback: "super jumpy"). Tuned just
        // under the step cadence so it keeps up under fast acceleration.
        .animation(.easeOut(duration: 0.16), value: tvDisplayFraction)
    }

    /// Fraction shown on the tvOS timeline: the live position normally,
    /// the preview playhead while the user is scrubbing.
    private var tvDisplayFraction: CGFloat {
        guard timelineEndMs > 0 else { return 0 }
        let ms = isScrubbing ? scrubTargetMs : progressStore.currentMs
        return max(0, min(1, CGFloat(ms) / CGFloat(timelineEndMs)))
    }

    /// Move the scrub preview by one step. No seek happens here, so the
    /// video keeps playing smoothly while scrubbing. Holding the same
    /// direction accelerates (1x..12x) so a long movie is crossable; a
    /// single tap nudges about 10 seconds.
    private func scrubStep(_ dir: Int) {
        guard timelineEndMs > 0 else { return }
        controlsHideTask?.cancel()
        scrubSettleTask?.cancel()  // a fresh scrub supersedes any post-seek settle
        if !isScrubbing {
            isScrubbing = true
            scrubTargetMs = progressStore.currentMs
            scrubAccelCount = 0
        }
        if dir == scrubLastDirection { scrubAccelCount += 1 } else { scrubAccelCount = 0 }
        scrubLastDirection = dir
        let mult = Int32(min(12, 1 + scrubAccelCount / 2))
        let step = Int64(10_000) * Int64(mult)
        let target = Int64(scrubTargetMs) + Int64(dir) * step
        scrubTargetMs = Int32(max(0, min(Int64(timelineEndMs), target)))
        debugLog("🎚️ [VOD-SCRUB] step dir=\(dir) x\(mult) -> \(scrubTargetMs)/\(progressStore.durationMs)ms")
        scheduleScrubCommit()
    }

    /// Auto-commit the scrub a beat after the user stops moving, so
    /// "scrub to a spot and let go" buffers from there on its own. 650ms
    /// is long enough to ride out the gaps between held d-pad repeats but
    /// short enough that the seek fires promptly once the user lets go.
    private func scheduleScrubCommit() {
        scrubCommitTask?.cancel()
        scrubCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            commitScrub()
        }
    }

    /// Seek to the preview position. One real seek, so mpv buffers from
    /// there once. Idempotent so Select and the idle timer cannot
    /// double-seek.
    private func commitScrub() {
        guard isScrubbing else { return }
        let target = scrubTargetMs
        scrubLastDirection = 0
        scrubAccelCount = 0
        scrubCommitTask?.cancel()
        debugLog("🎚️ [VOD-SCRUB] commit seek -> \(target)/\(progressStore.durationMs)ms")
        progressStore.seekAction?(target)
        // Keep the playhead pinned at the target (isScrubbing stays true, so
        // the bar keeps showing `scrubTargetMs`) until mpv's reported position
        // catches up to the seek. Clearing isScrubbing immediately makes the
        // bar snap to the stale pre-seek `currentMs` for a beat and then jump
        // forward once mpv updates (the "playhead jumps around" symptom).
        //
        // Convergence window is 4s: with keyframe seeks (hr-seek=no) mpv
        // lands on the nearest keyframe, up to a GOP shy of the exact
        // target, so a tight 1.5s test would never match and the playhead
        // would stick at the target for the full backstop before snapping.
        // 4s covers a typical streaming GOP, so the bar releases onto the
        // real landing position as soon as playback resumes there.
        scrubSettleTask?.cancel()
        scrubSettleTask = Task { @MainActor in
            for _ in 0..<75 {  // ~6s backstop at 80ms/iter
                if Task.isCancelled { return }
                if abs(Int64(progressStore.currentMs) - Int64(target)) < 4_000 { break }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard !Task.isCancelled else { return }
            isScrubbing = false
        }
        scheduleControlsHide()
    }

    /// Abandon an in-progress scrub without seeking (Back, or chrome hide).
    private func cancelScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        scrubLastDirection = 0
        scrubAccelCount = 0
        scrubCommitTask?.cancel()
        scrubSettleTask?.cancel()
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
            // tvOS: small play/pause indicator left of the focusable
            // timeline. The hardware Play/Pause button still drives the
            // pause toggle; this row owns left/right scrubbing.
            HStack(spacing: 12) {
                tvPlayPauseIndicator
                tvScrubberBar
            }
            .focusable(showControls && !isLive && isScrubberActive)
            .focused($tvFocus, equals: .scrubber)
            .onMoveCommand { direction in
                switch direction {
                case .left:  scrubStep(-1)
                case .right: scrubStep(+1)
                case .up:    tvFocus = .gearIcon
                default:     break
                }
            }
            .onTapGesture {
                // Select commits an in-progress scrub right away;
                // otherwise it toggles play/pause like a video timeline.
                if isScrubbing { commitScrub() }
                else { progressStore.togglePauseAction?(); scheduleControlsHide() }
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
                    let target = timelineEndMs > 0
                        ? min(timelineEndMs, progressStore.currentMs + 10_000)
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

                timelineTrailingLabel
            }
        }
        // YouTube-style scrub readout: a floating bubble above the bar
        // showing exactly where a scrub will land + how far that is from
        // the live/current position. Overlay (not a row) so it never
        // shifts the timeline; it fades in only while scrubbing.
        .overlay(alignment: .top) { scrubReadout }
        .animation(.easeInOut(duration: 0.18), value: scrubReadoutActive)
    }

    /// The position the scrub readout + landing reflect: the preview
    /// target while the user is actively scrubbing, otherwise the live
    /// playback position. iOS drives it from the drag fraction, tvOS
    /// from the step preview.
    private var scrubReadoutTargetMs: Int32 {
        #if os(tvOS)
        return isScrubbing ? scrubTargetMs : progressStore.currentMs
        #else
        return isDragging ? fractionToMs(dragFraction) : progressStore.currentMs
        #endif
    }

    /// True while the user is moving the playhead (drag on iOS, step on
    /// tvOS) and the readout bubble should be shown.
    private var scrubReadoutActive: Bool {
        #if os(tvOS)
        return isScrubbing
        #else
        return isDragging
        #endif
    }

    /// "+2:30" / "-0:45": the signed offset of the scrub target from the
    /// current playback position, for the readout's secondary line.
    private func signedDelta(_ ms: Int64) -> String {
        let sign = ms < 0 ? "-" : "+"
        return sign + formatMs(Int32(min(Int64(Int32.max), abs(ms))))
    }

    @ViewBuilder
    private var scrubReadout: some View {
        if scrubReadoutActive {
            let target = scrubReadoutTargetMs
            let delta = Int64(target) - Int64(progressStore.currentMs)
            VStack(spacing: 2) {
                Text(formatMs(target))
                    #if os(tvOS)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    #else
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    #endif
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(signedDelta(delta))
                    #if os(tvOS)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    #else
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    #endif
                    .foregroundColor(delta < 0 ? Color.orange : Color.green)
                    .monospacedDigit()
            }
            #if os(tvOS)
            .padding(.horizontal, 22).padding(.vertical, 12)
            #else
            .padding(.horizontal, 14).padding(.vertical, 8)
            #endif
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
            #if os(tvOS)
            .offset(y: -78)
            #else
            .offset(y: -52)
            #endif
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// Right-hand timeline readout. Regular VOD shows the total runtime.
    /// DVR (in-progress recording) shows a LIVE pill: a filled red dot
    /// when the playhead is riding the live edge, a hollow gray dot when
    /// the user has scrubbed back into the window. The pill's right edge
    /// is "live", so scrubbing all the way right (or tapping it on iOS)
    /// returns to the live edge.
    @ViewBuilder
    private var timelineTrailingLabel: some View {
        // scrubReadoutTargetMs already resolves the active scrub/drag
        // preview per-platform (tvOS step state vs iOS drag fraction).
        let displayMs = scrubReadoutTargetMs
        let atLive = timelineEndMs > 0 && displayMs >= timelineEndMs - 15_000
        if isDVR {
            HStack(spacing: 5) {
                Circle()
                    .fill(atLive ? Color.red : Color.white.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text("LIVE")
                    #if os(tvOS)
                    .font(.system(size: 18, weight: .semibold))
                    #else
                    .font(.system(size: 11, weight: .semibold))
                    #endif
                    .foregroundColor(atLive ? .white : .white.opacity(0.55))
            }
            .frame(minWidth: 46, alignment: .trailing)
            #if !os(tvOS)
            .contentShape(Rectangle())
            .onTapGesture {
                progressStore.seekAction?(timelineEndMs)
                scheduleControlsHide()
            }
            #endif
        } else {
            Text(formatMs(timelineEndMs))
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
                        // Full-screen / force-landscape toggle. Lets users who
                        // lock their device to portrait force landscape playback
                        // without turning off their rotation lock. Tap again to
                        // release back to the device orientation.
                        liquidButton(systemName: forcedLandscape
                                     ? "arrow.down.right.and.arrow.up.left"
                                     : "arrow.up.left.and.arrow.down.right",
                                     tint: .white) {
                            forcedLandscape.toggle()
                            requestOrientation(landscape: forcedLandscape)
                        }
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
            aspectMode: progressStore.aspectMode,
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
            setAspect: { progressStore.aspectMode = $0; UserDefaults.standard.set($0.rawValue, forKey: "player.aspectMode") },
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

    /// v1.6.15.x: thin wrapper that delegates to the standalone
    /// `StreamInfoCardView` (defined alongside `StreamInfo` near the
    /// top of this file). The card itself is reusable across both
    /// the legacy single-stream path (this view) and the unified
    /// multiview path (`MultiviewContainerView`).
    private var streamInfoOverlay: some View {
        StreamInfoCardView(info: progressStore.streamInfo)
    }

    #if os(iOS)
    /// Force the window orientation. `landscape` rotates into (and pins)
    /// landscape even when the device is rotation-locked to portrait,
    /// because the app's Info.plist permits landscape. Passing false
    /// releases the lock back to the device's own orientation. iOS 16+.
    /// On iPad-on-Mac this is a no-op (Mac windows do not rotate; use the
    /// window's full-screen control there).
    private func requestOrientation(landscape: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .allButUpsideDown
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            debugLog("🔄 requestGeometryUpdate(landscape=\(landscape)) error=\(error.localizedDescription)")
        }
    }
    #endif

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
    /// Current on-screen aspect mode (issue #26), shown with a checkmark in
    /// the Aspect Ratio submenu.
    let aspectMode: VideoAspectMode
    /// When true, the menu shows a "Record Current Program" item that
    /// fires `recordAction`. Gated off the audio tile's live EPG state
    /// in the unified chrome so it hides for streams without EPG data.
    let canRecord: Bool

    // Action closures — excluded from equality check.
    var setAudioTrack: ((Int) -> Void)?
    var setSubtitleTrack: ((Int) -> Void)?
    var setSpeed: ((Double) -> Void)?
    var setAspect: ((VideoAspectMode) -> Void)?
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
        lhs.aspectMode == rhs.aspectMode &&
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

                // Aspect Ratio (issue #26) — live + VOD, hidden in audio-only.
                if !isAudioOnly {
                    Menu {
                        ForEach(VideoAspectMode.allCases) { mode in
                            Button {
                                setAspect?(mode)
                            } label: {
                                if mode == aspectMode {
                                    Label(mode.label, systemImage: "checkmark")
                                } else {
                                    Text(mode.label)
                                }
                            }
                        }
                    } label: {
                        Label("Aspect: \(aspectMode.label)", systemImage: aspectMode.icon)
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

// MARK: - Native AVPlayer engine (TEST, branch test/avplayer-hls-engine)

/// Full-screen native AVPlayer playback for genuine HLS streams, presented
/// when the Developer "AVPlayer for HLS Streams" toggle routes a .m3u8 URL
/// here instead of the mpv pipeline (see PlayerSession.begin). Uses
/// AVPlayerViewController for the system transport/chrome: native HDR and
/// Dolby Vision output, Atmos passthrough, AirPlay, and the standard
/// scrubbing UI come along for free, which is the whole point of the test.
/// Deliberately NOT integrated with the app's custom chrome, channel-flip,
/// or multiview; this is an engine evaluation surface, not a replacement.
struct NativeHLSPlayerScreen: View {
    let item: ChannelDisplayItem
    let userAgent: String?
    /// When true, the stream is raw MPEG-TS: an on-device TSHLSRemuxer
    /// ingests it and AVPlayer plays the loopback playlist it serves.
    var useRemux = false
    /// Ingest headers for the remuxer (Dispatcharr auth + UA); also sent
    /// on direct playback so the server's HLS endpoints see the same
    /// auth the TS path sends.
    var ingestHeaders: [String: String] = [:]
    /// Non-nil when the router upgraded the URL to the server's native
    /// HLS output (?output_format=hls); played instead of item.streamURL.
    var overrideURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var remuxer: TSHLSRemuxer?
    @State private var statusText: String?
    @State private var showRecordSheet = false
    @State private var showStreamInfo = false
    @State private var sleepWork: DispatchWorkItem?


    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                NativeAVPlayerController(
                    player: player,
                    canRecord: item.streamURL != nil,
                    onRecord: { showRecordSheet = true },
                    onAddStream: { switchToMPV(openAddStream: true) },
                    onSwitchToMPV: { switchToMPV(openAddStream: false) },
                    onStreamInfo: { showStreamInfo.toggle() },
                    onSleepTimer: { seconds in setSleepTimer(seconds) },
                    trailingAccessory: trailingAccessoryView
                )
                .ignoresSafeArea()
            }
            if let statusText {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(statusText)
                        .font(.bodyMedium)
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            if showStreamInfo, let player {
                NativeStreamInfoCard(
                    player: player,
                    channelName: item.name,
                    program: item.currentProgram,
                    engineNote: useRemux ? "AVPlayer (remuxed TS)" : "AVPlayer (direct HLS)"
                )
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
                .padding(60)
            }
        }
        // Record sheet over the native player. Same RecordProgramSheet
        // the mpv chrome's Record pill presents, fed from the same
        // ChannelDisplayItem EPG fields.
        .fullScreenCover(isPresented: $showRecordSheet) {
            recordSheet
        }
        // Direct playback failure (e.g. a stale capability cache sent a
        // server-side HLS request to a server that no longer answers it):
        // fall back to mpv, same as the tile path. The per-session
        // re-probe corrects the cache for next time.
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let failed = note.object as? AVPlayerItem,
                  failed === player?.currentItem else { return }
            DebugLogger.shared.log(
                "[AVP-HLS] native playback failed; falling back to mpv",
                category: "Playback", level: .warning
            )
            fallbackToMPV()
        }
        #if os(tvOS)
        // mpv parity: Menu means "minimize to the corner mini player
        // over the guide", not "kill the channel". AVPlayerViewController
        // consumes Menu while its transport is visible (hides it); the
        // press only bubbles here once the transport is hidden, matching
        // the mpv chrome cycle.
        .onExitCommand { minimizeToMini() }
        #else
        // iOS: unlike tvOS, AVPlayerViewController draws its OWN top
        // chrome here (close, PiP, AirPlay, volume), so the overlay
        // carries ONLY the actions the native player lacks, styled in
        // the native chrome's exact vocabulary: 50pt dark-material
        // circles for lone actions, related actions grouped in ONE
        // material capsule (mirroring the native PiP+AirPlay pill),
        // aligned to the same screen margins one row below the native
        // controls. Leading: minimize to the corner mini (the native X
        // fully stops, the chevron keeps watching). Trailing capsule:
        // Record, Add Stream, Options (Stream Info, Sleep Timer,
        // Switch to MPV, Stop). Aspect is omitted: the native player
        // already has pinch zoom.
        .statusBarHidden()
        #endif
        .onAppear {
            AudioSessionRefCount.increment(caller: "native-hls")
            IdleTimerRefCount.increment(caller: "native-hls")
            guard let url = overrideURL ?? item.streamURL ?? item.streamURLs.first else { return }
            NowPlayingManager.shared.lastPlayedChannelID = item.id

            if useRemux {
                // Raw TS: stand up the loopback remuxer, then play its
                // playlist URL once two segments exist. The codec gate
                // (H.264 + AC-3/AAC only) falls back to mpv otherwise.
                statusText = "Preparing stream..."
                let mux = TSHLSRemuxer(sourceURL: url, headers: ingestHeaders)
                mux.onReady = { localURL in
                    statusText = nil
                    startPlayer(with: localURL, headers: [:])
                    DebugLogger.shared.log(
                        "[AVP-HLS] native engine playing REMUXED channel id=\(item.id)",
                        category: "Playback", level: .info
                    )
                }
                mux.onError = { error in
                    DebugLogger.shared.log(
                        "[AVP-HLS] remux failed (\(error)); falling back to mpv",
                        category: "Playback", level: .warning
                    )
                    fallbackToMPV()
                }
                remuxer = mux
                mux.start()
            } else {
                var headers = ingestHeaders
                if headers.isEmpty, let userAgent, !userAgent.isEmpty {
                    headers["User-Agent"] = userAgent
                }
                startPlayer(with: url, headers: headers)
                DebugLogger.shared.log(
                    "[AVP-HLS] native engine playing channel id=\(item.id)\(overrideURL != nil ? " (server-side HLS)" : "")",
                    category: "Playback", level: .info
                )
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            remuxer?.stop()
            remuxer = nil
            sleepWork?.cancel()
            sleepWork = nil
            AudioSessionRefCount.decrement(caller: "native-hls")
            IdleTimerRefCount.decrement(caller: "native-hls")
            DebugLogger.shared.log(
                "[AVP-HLS] native engine closed",
                category: "Playback", level: .info
            )
        }
    }

    private func startPlayer(with url: URL, headers: [String: String]) {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        // Feed the native info panel real channel/program names instead
        // of whatever stale Now Playing state it can scrape.
        playerItem.externalMetadata = Self.nativeMetadata(
            title: item.name,
            subtitle: item.currentProgram
        )
        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.play()
        player = avPlayer
    }

    private static func nativeMetadata(title: String, subtitle: String?) -> [AVMetadataItem] {
        func make(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let entry = AVMutableMetadataItem()
            entry.identifier = id
            entry.value = value as NSString
            entry.extendedLanguageTag = "und"
            return entry
        }
        var entries = [make(.commonIdentifierTitle, title)]
        if let subtitle, !subtitle.isEmpty {
            entries.append(make(.iTunesMetadataTrackSubTitle, subtitle))
        }
        return entries
    }

    /// The app-action capsule, hosted INSIDE the player controller and
    /// pinned to its layout-margin guides so it aligns with the native
    /// chrome by construction in every orientation (an external overlay
    /// could only approximate Apple's margins). Empty on tvOS, where
    /// the actions live in the transport bar instead.
    private var trailingAccessoryView: AnyView {
        #if os(iOS)
        AnyView(
            HStack(spacing: 22) {
                if item.streamURL != nil {
                    Button {
                        showRecordSheet = true
                    } label: {
                        iosOverlayIcon("record.circle", tint: .red)
                    }
                }
                Button {
                    switchToMPV(openAddStream: true)
                } label: {
                    iosOverlayIcon("plus")
                }
                Menu {
                    Button {
                        showStreamInfo.toggle()
                    } label: {
                        Label("Stream Info", systemImage: "info.circle")
                    }
                    Menu {
                        ForEach([30, 60, 90, 120], id: \.self) { minutes in
                            Button("\(minutes) minutes") {
                                setSleepTimer(TimeInterval(minutes * 60))
                            }
                        }
                        Button("Off", role: .destructive) { setSleepTimer(nil) }
                    } label: {
                        Label("Sleep Timer", systemImage: "moon.zzz")
                    }
                    Button {
                        switchToMPV(openAddStream: false)
                    } label: {
                        Label("Switch to MPV Player", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) {
                        dismiss()
                    } label: {
                        Label("Stop Playback", systemImage: "stop.circle")
                    }
                } label: {
                    iosOverlayIcon("slider.horizontal.3")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            // Material alone goes light over bright content; the native
            // pills hold a dark tone everywhere, so blur over a dark
            // underlay to match.
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.4), in: Capsule())
            .environment(\.colorScheme, .dark)
        )
        #else
        AnyView(EmptyView())
        #endif
    }

    #if os(iOS)
    /// Icon styling for the grouped capsule (the capsule supplies its
    /// own material background, mirroring the native PiP+AirPlay pill).
    @ViewBuilder
    private func iosOverlayIcon(_ icon: String, tint: Color = .white) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(tint)
    }
    #endif

    /// Remux failure path: dismiss this cover and restart the channel on
    /// the mpv pipeline, bypassing the native router so it cannot loop.
    private func fallbackToMPV() {
        switchToMPV(openAddStream: false)
    }

    /// Menu/Back, mpv parity: continue this channel in the corner mini
    /// player over the guide. The unified container mounts (its per-tile
    /// router keeps the tile on AVPlayer when eligible) and immediately
    /// minimizes. The stream restarts across the handoff, which is the
    /// cost of trading system chrome for the container; acceptable in
    /// the corner mini.
    private func minimizeToMini() {
        let session = PlayerSession.shared
        let server = session.nativeHLSServer
        session.nativeHLSItem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            session.begin(item: item, server: server, bypassNativeRouter: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NowPlayingManager.shared.minimize()
            }
        }
    }

    /// Native Options parity with the mpv panel's sleep timer: nil
    /// cancels; otherwise the native player closes when it fires.
    private func setSleepTimer(_ seconds: TimeInterval?) {
        sleepWork?.cancel()
        sleepWork = nil
        guard let seconds else {
            debugLog("[AVP-HLS] sleep timer cancelled")
            return
        }
        let work = DispatchWorkItem {
            debugLog("[AVP-HLS] sleep timer fired; closing native player")
            PlayerSession.shared.nativeHLSItem = nil
        }
        sleepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        debugLog("[AVP-HLS] sleep timer set: \(Int(seconds / 60))m")
    }

    /// Leave the native player and restart this channel on the mpv
    /// pipeline (router bypassed). With `openAddStream`, additionally
    /// asks the mounted multiview container to open its add-channel
    /// sheet, which is what "Add Stream" means: multiview is an mpv
    /// capability, so the engine switches first.
    private func switchToMPV(openAddStream: Bool) {
        let session = PlayerSession.shared
        let server = session.nativeHLSServer
        session.nativeHLSItem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            session.begin(item: item, server: server, bypassNativeRouter: true)
            if openAddStream {
                // Give the container a beat to mount before asking it
                // to present the sheet (same notification the iPad
                // keyboard shortcut uses).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(
                        name: .multiviewRequestOpenAddSheet, object: nil)
                }
            }
        }
    }

    /// Mirror of the mpv chrome's Record pill payload
    /// (MultiviewContainerView.recordSheetContent): EPG-known program
    /// name when available, generic live-recording fallback otherwise.
    @ViewBuilder
    private var recordSheet: some View {
        let now = Date()
        RecordProgramSheet(
            programTitle: item.currentProgram ?? "\(item.name) live recording",
            programDescription: item.currentProgramDescription ?? "",
            channelID: item.id,
            channelName: item.name,
            scheduledStart: item.currentProgramStart ?? now,
            scheduledEnd: (item.currentProgramEnd.flatMap { $0 > now ? $0 : nil })
                ?? now.addingTimeInterval(3600),
            isLive: true,
            dispatcharrChannelID: item.dispatcharrChannelID,
            streamURL: item.streamURL
        )
    }
}

/// Thin AVPlayerViewController wrapper. The system controller supplies the
/// full native transport (and on tvOS, the swipe-down info panel); the
/// app's own actions ride the transport bar as custom items (tvOS 15+):
/// Record, Add Stream, and an Options menu with aspect toggle and a
/// switch-to-mpv escape hatch for A/B comparison.
private struct NativeAVPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    var canRecord: Bool = false
    var onRecord: (() -> Void)?
    var onAddStream: (() -> Void)?
    var onSwitchToMPV: (() -> Void)?
    var onStreamInfo: (() -> Void)?
    var onSleepTimer: ((TimeInterval?) -> Void)?
    /// iOS: the app-action capsule, mounted INSIDE the native controls
    /// hierarchy so it inherits the chrome's fade on Apple's own clock
    /// (a parallel show/hide state machine drifted out of phase).
    var trailingAccessory: AnyView = AnyView(EmptyView())

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        #if os(tvOS)
        controller.transportBarCustomMenuItems = Self.transportItems(
            for: controller,
            canRecord: canRecord,
            onRecord: onRecord,
            onAddStream: onAddStream,
            onSwitchToMPV: onSwitchToMPV,
            onStreamInfo: onStreamInfo,
            onSleepTimer: onSleepTimer
        )
        #else
        let hosting = UIHostingController(rootView: trailingAccessory)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.hosting = hosting
        // The native controls hierarchy does not exist yet; attach once
        // it does so the capsule inherits the chrome's fade.
        context.coordinator.attachAccessory(to: controller, attempts: 20)
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        #if os(iOS)
        context.coordinator.hosting?.rootView = trailingAccessory
        #endif
    }

    @MainActor
    final class Coordinator: NSObject {
        #if os(iOS)
        var hosting: UIHostingController<AnyView>?
        private weak var controllerRef: AVPlayerViewController?
        private weak var fadeSource: UIView?
        private var displayLink: CADisplayLink?
        // No deinit invalidate: the display link retains this
        // coordinator, and tickFade invalidates itself once the player
        // leaves the window, which releases the retain so the
        // coordinator can deinit normally.

        /// Mount the capsule on the controller's own view at the
        /// calibrated position (decoupled from Apple's fragile control
        /// tree, which rebuilds), then mirror the fade by SAMPLING a
        /// real native button's on-screen opacity every frame onto the
        /// capsule. Sampling the composited presentation opacity tracks
        /// whatever Apple animates, on any view, with any curve, exactly
        /// (mounting inside a guessed "fading" container kept landing on
        /// a non-fading layer). Retries until the controls exist.
        func attachAccessory(to controller: AVPlayerViewController, attempts: Int) {
            guard let hostingView = hosting?.view, hostingView.superview == nil else { return }
            controllerRef = controller
            controller.view.layoutIfNeeded()
            mount(hostingView, controller: controller)
            startFadeMirror(attempts: attempts)
        }

        private func mount(_ view: UIView, controller: AVPlayerViewController) {
            // controller.view is the AVPlayerViewController's OWN view,
            // so declaring it the parent is consistent (the earlier
            // crash was declaring AVPlayerViewController while mounting
            // inside a private controls VC's view).
            if let hosting {
                controller.addChild(hosting)
                controller.view.addSubview(view)
                hosting.didMove(toParent: controller)
            } else {
                controller.view.addSubview(view)
            }
            // Leading clears the X + PiP/AirPlay cluster; centerline is
            // the calibrated orientation-aware constant (approved on
            // device), updated on size-class change so rotation holds.
            view.leadingAnchor.constraint(
                equalTo: controller.view.layoutMarginsGuide.leadingAnchor, constant: 185
            ).isActive = true
            let constraint = view.centerYAnchor.constraint(
                equalTo: controller.view.safeAreaLayoutGuide.topAnchor,
                constant: Self.fallbackCenterOffset(for: controller.traitCollection)
            )
            constraint.isActive = true
            view.registerForTraitChanges([UITraitVerticalSizeClass.self]) {
                (registered: UIView, _: UITraitCollection) in
                constraint.constant = Self.fallbackCenterOffset(for: registered.traitCollection)
            }
        }

        private func startFadeMirror(attempts: Int) {
            guard let controller = controllerRef else { return }
            if let button = Self.topRowReferenceControl(in: controller.view, host: controller.view) {
                fadeSource = button
                let link = CADisplayLink(target: self, selector: #selector(tickFade))
                link.add(to: .main, forMode: .common)
                displayLink = link
                debugLog("[AVP-HLS] capsule fade mirroring native control")
            } else if attempts > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self?.startFadeMirror(attempts: attempts - 1)
                }
            } else {
                debugLog("[AVP-HLS] native control not found; capsule stays visible")
            }
        }

        @objc private func tickFade() {
            guard let capsule = hosting?.view else { return }
            // Player dismissed: stop sampling.
            if capsule.window == nil {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            // Native button gone (Glass rebuilt its tree): re-find it.
            guard let source = fadeSource else {
                displayLink?.invalidate()
                displayLink = nil
                startFadeMirror(attempts: 8)
                return
            }
            let target = Self.onScreenAlpha(of: source)
            if abs(capsule.alpha - target) > 0.001 {
                capsule.alpha = target
            }
        }

        /// Composited on-screen opacity of `view`: the product of every
        /// ancestor's presentation-layer opacity up to the window, so it
        /// reflects an in-flight fade no matter which ancestor Apple is
        /// animating. Zero if anything in the chain is hidden.
        private static func onScreenAlpha(of view: UIView) -> CGFloat {
            var current: UIView? = view
            var alpha: CGFloat = 1
            while let v = current {
                if v.isHidden { return 0 }
                let opacity = v.layer.presentation()?.opacity ?? Float(v.alpha)
                alpha *= CGFloat(opacity)
                current = v.superview
            }
            return alpha
        }

        /// Native top-row center, relative to the safe-area top:
        /// measured from device screenshots; portrait tucks the row
        /// into the safe area band, landscape floats it lower.
        private static func fallbackCenterOffset(for traits: UITraitCollection) -> CGFloat {
            traits.verticalSizeClass == .compact ? 44 : 20
        }

        /// The highest plausibly button-sized native control in the top
        /// band of the player, i.e. a member of the chrome's top row.
        private static func topRowReferenceControl(in root: UIView, host: UIView) -> UIView? {
            var best: (view: UIView, midY: CGFloat)?
            var queue: [UIView] = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if view is UIControl || view.accessibilityTraits.contains(.button),
                   view.bounds.height >= 36, view.bounds.height <= 64 {
                    let midY = view.convert(view.bounds, to: host).midY
                    if best == nil || midY < best!.midY {
                        best = (view, midY)
                    }
                }
                queue.append(contentsOf: view.subviews)
            }
            guard let best, best.midY > 0, best.midY < host.bounds.height * 0.3 else {
                return nil
            }
            return best.view
        }
        #endif
    }

    #if os(tvOS)
    /// Rebuilt after each aspect toggle so the menu state stays in
    /// step with the controller's current videoGravity. Audio and
    /// subtitle selection are deliberately absent: the native info
    /// panel already provides them.
    private static func transportItems(
        for controller: AVPlayerViewController,
        canRecord: Bool,
        onRecord: (() -> Void)?,
        onAddStream: (() -> Void)?,
        onSwitchToMPV: (() -> Void)?,
        onStreamInfo: (() -> Void)?,
        onSleepTimer: ((TimeInterval?) -> Void)?
    ) -> [UIMenuElement] {
        var items: [UIMenuElement] = []

        if canRecord, let onRecord {
            items.append(UIAction(
                title: "Record",
                image: UIImage(systemName: "record.circle")
            ) { _ in onRecord() })
        }

        if let onAddStream {
            items.append(UIAction(
                title: "Add Stream",
                image: UIImage(systemName: "plus")
            ) { _ in onAddStream() })
        }

        let isFill = controller.videoGravity == .resizeAspectFill
        let aspectAction = UIAction(
            title: isFill ? "Aspect: Fill" : "Aspect: Fit",
            image: UIImage(systemName: "rectangle.arrowtriangle.2.outward"),
            state: isFill ? .on : .off
        ) { [weak controller] _ in
            guard let controller else { return }
            controller.videoGravity =
                controller.videoGravity == .resizeAspectFill ? .resizeAspect : .resizeAspectFill
            controller.transportBarCustomMenuItems = transportItems(
                for: controller, canRecord: canRecord, onRecord: onRecord,
                onAddStream: onAddStream, onSwitchToMPV: onSwitchToMPV,
                onStreamInfo: onStreamInfo, onSleepTimer: onSleepTimer)
        }

        var optionsChildren: [UIMenuElement] = [aspectAction]

        if let onStreamInfo {
            optionsChildren.append(UIAction(
                title: "Stream Info",
                image: UIImage(systemName: "info.circle")
            ) { _ in onStreamInfo() })
        }

        if let onSleepTimer {
            var sleepChildren: [UIMenuElement] = [30, 60, 90, 120].map { minutes in
                UIAction(title: "\(minutes) minutes") { _ in
                    onSleepTimer(TimeInterval(minutes * 60))
                }
            }
            sleepChildren.append(UIAction(
                title: "Off",
                attributes: .destructive
            ) { _ in onSleepTimer(nil) })
            optionsChildren.append(UIMenu(
                title: "Sleep Timer",
                image: UIImage(systemName: "moon.zzz"),
                children: sleepChildren
            ))
        }

        if let onSwitchToMPV {
            optionsChildren.append(UIAction(
                title: "Switch to MPV Player",
                image: UIImage(systemName: "arrow.triangle.2.circlepath")
            ) { _ in onSwitchToMPV() })
        }
        items.append(UIMenu(
            title: "Options",
            image: UIImage(systemName: "slider.horizontal.3"),
            children: optionsChildren
        ))

        return items
    }
    #endif
}

/// Stream-info overlay for the native player, the counterpart of the
/// mpv Options panel's stream info. Values come straight from AVPlayer:
/// presentation size and the HLS access log's bitrate figures, refreshed
/// every 2 seconds while shown.
private struct NativeStreamInfoCard: View {
    let player: AVPlayer
    let channelName: String
    let program: String?
    let engineNote: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                Text(channelName)
                    .font(.system(size: 28, weight: .bold))
                if let program, !program.isEmpty {
                    Text(program)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(engineNote)
                let size = player.currentItem?.presentationSize ?? .zero
                if size != .zero {
                    Text("\(Int(size.width))x\(Int(size.height))")
                }
                if let event = player.currentItem?.accessLog()?.events.last {
                    if event.indicatedBitrate > 0 {
                        Text(String(format: "%.1f Mbps indicated", event.indicatedBitrate / 1_000_000))
                    }
                    if event.observedBitrate > 0 {
                        Text(String(format: "%.1f Mbps observed", event.observedBitrate / 1_000_000))
                    }
                    if event.numberOfStalls > 0 {
                        Text("\(event.numberOfStalls) stall(s)")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.white)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 480, alignment: .leading)
        }
    }
}

