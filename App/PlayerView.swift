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
    /// Closure set by the ViewController; toggles Picture-in-Picture.
    var togglePiPAction: (() -> Void)?
    /// Whether PiP is currently active.
    @Published var isPiPActive: Bool = false

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
    let resumePositionMs: Int32?
    let onMinimize: (() -> Void)?
    let onClose: (() -> Void)?

    init(urls: [URL], title: String, headers: [String: String]? = nil,
         isLive: Bool = true,
         subtitle: String? = nil, subtitleStart: Date? = nil, subtitleEnd: Date? = nil,
         artworkURL: URL? = nil,
         vodID: String? = nil, vodPosterURL: String? = nil,
         vodServerID: String? = nil, resumePositionMs: Int32? = nil,
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

                    #if os(tvOS)
                    // tvOS: UIKit press handler — captures all Siri Remote input with
                    // proper pressesBegan/pressesEnded for reliable hold-to-scrub.
                    TVRemoteInputView(
                        onLeftHold: { holding in
                            isScrubbing = holding
                            if holding {
                                withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                            } else {
                                scheduleControlsHide()
                            }
                        },
                        onRightHold: { holding in
                            isScrubbing = holding
                            if holding {
                                withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                            } else {
                                scheduleControlsHide()
                            }
                        },
                        onSeek: { seekMs in
                            guard !isLive, progressStore.durationMs > 0 else { return }
                            let target = max(0, min(progressStore.durationMs, progressStore.currentMs + seekMs))
                            progressStore.seekAction?(target)
                        },
                        onUp: {
                            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                            scheduleControlsHide()
                            if !isLive {
                                let speeds = PlayerProgressStore.speedOptions
                                let idx = speeds.firstIndex(of: progressStore.speed) ?? 2
                                progressStore.setSpeedAction?(speeds[(idx + 1) % speeds.count])
                            }
                        },
                        onDown: {
                            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                            scheduleControlsHide()
                            if !progressStore.subtitleTracks.isEmpty {
                                let cur = progressStore.currentSubtitleTrackID
                                if cur == 0 {
                                    progressStore.setSubtitleTrackAction?(progressStore.subtitleTracks[0].id)
                                } else if let i = progressStore.subtitleTracks.firstIndex(where: { $0.id == cur }),
                                          i + 1 < progressStore.subtitleTracks.count {
                                    progressStore.setSubtitleTrackAction?(progressStore.subtitleTracks[i + 1].id)
                                } else {
                                    progressStore.setSubtitleTrackAction?(0)
                                }
                            }
                        },
                        onSelect: {
                            if showControls {
                                progressStore.togglePauseAction?()
                                if !progressStore.isPaused { scheduleControlsHide() }
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                                scheduleControlsHide()
                            }
                        },
                        onPlayPause: {
                            progressStore.togglePauseAction?()
                            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                            if !progressStore.isPaused { scheduleControlsHide() }
                        },
                        onMenu: {
                            if showControls {
                                withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
                            } else if let minimize = onMinimize {
                                minimize()
                            } else {
                                onDismiss()
                            }
                        }
                    )
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
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!showControls)
        #endif
        #if os(tvOS)
        // Focus section isolates the player from tab content behind it
        .focusSection()
        #endif
        .onAppear {
            scheduleControlsHide()
            #if os(tvOS)
            // Grab focus from the guide/channel list behind the player ZStack overlay.
            // Without this, the guide retains focus and d-pad scrolls channels instead
            // of showing media controls.
            // TVRemoteInputView grabs focus automatically via canBecomeFocused
            #endif
        }
        .onChange(of: progressStore.isPaused) { _, isPaused in
            if isPaused {
                controlsHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            } else {
                scheduleControlsHide()
            }
        }
    }

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
    // Reads the key window's top safe area inset directly from UIKit so it's accurate
    // even inside a view that uses .ignoresSafeArea().
    private var deviceSafeAreaTop: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 44
        #else
        60   // tvOS has no notch / Dynamic Island
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

                // Progress bar
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
            tvScrubberBar
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
                        // Audio track selector — only when multiple tracks
                        if progressStore.audioTracks.count > 1 {
                            audioTrackMenu
                        }

                        // Subtitle track selector — only when subs available
                        if !progressStore.subtitleTracks.isEmpty {
                            subtitleTrackMenu
                        }

                        // Playback speed (VOD only — live streams always 1x)
                        if !isLive {
                            speedButton
                        }

                        #if os(iOS)
                        // Audio-only toggle (iOS only)
                        liquidButton(
                            systemName: isAudioOnly ? "video.fill" : "music.note",
                            tint: isAudioOnly ? Color.accentPrimary : .white
                        ) {
                            withAnimation(.spring(response: 0.3)) { isAudioOnly.toggle() }
                        }

                        // Picture-in-Picture
                        if progressStore.togglePiPAction != nil {
                            liquidButton(
                                systemName: progressStore.isPiPActive ? "pip.exit" : "pip.enter",
                                tint: progressStore.isPiPActive ? Color.accentPrimary : .white
                            ) {
                                progressStore.togglePiPAction?()
                            }
                        }

                        // AirPlay
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                            AirPlayButton()
                                .frame(width: 34, height: 34)
                        }
                        .frame(width: 52, height: 52)
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

            // Center play/pause button
            centerPlayPauseButton

            #if os(tvOS)
            // D-pad control hints
            tvRemoteHints
            #endif
        }
    }

    // MARK: - Audio Track Menu

    private var audioTrackMenu: some View {
        Menu {
            ForEach(progressStore.audioTracks) { track in
                Button {
                    progressStore.setAudioTrackAction?(track.id)
                } label: {
                    Label(track.displayName,
                          systemImage: track.id == progressStore.currentAudioTrackID ? "checkmark" : "")
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
                Label("Off",
                      systemImage: progressStore.currentSubtitleTrackID == 0 ? "checkmark" : "")
            }
            ForEach(progressStore.subtitleTracks) { track in
                Button {
                    progressStore.setSubtitleTrackAction?(track.id)
                } label: {
                    Label(track.displayName,
                          systemImage: track.id == progressStore.currentSubtitleTrackID ? "checkmark" : "")
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
        progressStore.explicitResumeMs = resumePositionMs
        state = .playing
        scheduleControlsHide()
    }

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

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.setNeedsFocusUpdate()
                    self?.updateFocusIfNeeded()
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

