import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
#if os(iOS)
import UIKit
#endif

// VLC-based playback – reliable for MPEG-TS over HTTP.
// MobileVLCKit for iOS, TVVLCKit for tvOS – same API surface.
#if canImport(MobileVLCKit)
@preconcurrency import MobileVLCKit
#elseif canImport(TVVLCKit)
@preconcurrency import TVVLCKit
#endif

// MARK: - Attempt Log Store
// @unchecked Sendable: all mutations are dispatched to the main queue manually.
// Uses a non-published backing array to avoid SwiftUI re-renders on every VLC state change.
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

// MARK: - Player Progress Store
// @unchecked Sendable: all @Published mutations dispatched to main queue manually.
final class PlayerProgressStore: ObservableObject, @unchecked Sendable {
    /// Current playback position in milliseconds (live-timeline relative).
    @Published var currentMs: Int32 = 0
    /// Total stream duration in ms (0 for live streams without a static file).
    @Published var durationMs: Int32 = 0
    /// True when VLC is paused.
    @Published var isPaused: Bool = false
    /// Closure set by the Coordinator; call with a target position in ms to seek.
    var seekAction: ((Int32) -> Void)?
    /// Closure set by the Coordinator; toggles play/pause.
    var togglePauseAction: (() -> Void)?
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

// MARK: - PlayerView (VLC)

struct PlayerView: View {
    let urls: [URL]
    let title: String
    let headers: [String: String]
    let isLive: Bool
    let subtitle: String?
    let subtitleStart: Date?
    let subtitleEnd: Date?
    let artworkURL: URL?
    let onMinimize: (() -> Void)?
    let onClose: (() -> Void)?

    init(urls: [URL], title: String, headers: [String: String]? = nil,
         isLive: Bool = true,
         subtitle: String? = nil, subtitleStart: Date? = nil, subtitleEnd: Date? = nil,
         artworkURL: URL? = nil,
         onMinimize: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.urls = urls
        self.title = title
        self.headers = headers ?? [:]
        self.isLive = isLive
        self.subtitle = subtitle
        self.subtitleStart = subtitleStart
        self.subtitleEnd = subtitleEnd
        self.artworkURL = artworkURL
        self.onMinimize = onMinimize
        self.onClose = onClose
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var logStore = AttemptLogStore()
    @State private var didCopyErrorDetails = false
    @State private var isAudioOnly = false

    var body: some View {
        VLCPlayerRootView(
            urls: urls, title: title, headers: headers,
            isLive: isLive,
            subtitle: subtitle, subtitleStart: subtitleStart, subtitleEnd: subtitleEnd,
            artworkURL: artworkURL,
            onDismiss: { if let c = onClose { c() } else { dismiss() } },
            onMinimize: onMinimize,
            logStore: logStore,
            didCopyErrorDetails: $didCopyErrorDetails,
            isAudioOnly: $isAudioOnly
        )
        .ignoresSafeArea()
    }
}


// MARK: - VLC Root View
private struct VLCPlayerRootView: View {
    let urls: [URL]
    let title: String
    let headers: [String: String]
    let isLive: Bool
    let subtitle: String?
    let subtitleStart: Date?
    let subtitleEnd: Date?
    let artworkURL: URL?
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

    enum PlayState { case loading, playing, error }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch state {
            case .loading:
                loadingOverlay

            case .playing:
                ZStack {
                    // VLC stays in the hierarchy at all times — removing it tears down the
                    // coordinator and forces a full restart when toggling back from audio-only.
                    VLCPlayerViewRepresentable(
                        urls: urls, headers: headers,
                        isLive: isLive,
                        nowPlayingTitle: title,
                        nowPlayingSubtitle: subtitle,
                        nowPlayingArtworkURL: artworkURL,
                        progressStore: progressStore,
                        logStore: logStore,
                        onFatalError: { err in lastError = err; state = .error }
                    )
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

                    #if !os(tvOS)
                    // Transparent tap layer — toggles controls on tap, passes through button taps.
                    // tvOS uses Siri Remote commands (.onTapGesture, .onMoveCommand, etc.) instead.
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
        // Make the player view focusable so tvOS delivers remote events
        .focusable()
        // Siri Remote: Play/Pause button toggles VLC playback and shows controls
        .onPlayPauseCommand {
            print("[REMOTE] Play/Pause pressed — isPaused=\(progressStore.isPaused), hasAction=\(progressStore.togglePauseAction != nil)")
            progressStore.togglePauseAction?()
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            if !progressStore.isPaused { scheduleControlsHide() }
        }
        // Siri Remote: Menu button — hide controls first, then minimize (or dismiss)
        .onExitCommand {
            print("[REMOTE] Menu pressed — showControls=\(showControls), hasMinimize=\(onMinimize != nil)")
            if showControls {
                withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
            } else if let minimize = onMinimize {
                minimize()
            } else {
                onDismiss()
            }
        }
        // Siri Remote: any swipe/move direction always shows controls
        .onMoveCommand { direction in
            print("[REMOTE] Swipe/Move: \(direction)")
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            scheduleControlsHide()
        }
        // Siri Remote: Select (click) shows controls if hidden, hides if shown
        .onLongPressGesture(minimumDuration: 0.01, perform: {
            print("[REMOTE] Select (click) — showControls=\(showControls)")
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
            scheduleControlsHide()
        })
        #endif
        .onAppear { scheduleControlsHide() }
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

    /// For VOD: once VLC reports a non-zero duration.
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
            scrubberBar

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

                // Skip back 10 s
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
                #if os(tvOS)
                .buttonStyle(TVNoRingButtonStyle())
                #endif
                .opacity(canSeekBackward ? 1 : 0.3)
                .disabled(!canSeekBackward)

                Spacer().frame(width: 32)

                // Skip forward 10 s
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
                #if os(tvOS)
                .buttonStyle(TVNoRingButtonStyle())
                #endif
                .opacity(canSeekForward ? 1 : 0.3)
                .disabled(!canSeekForward)

                Spacer()

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
                        // Audio-only toggle (iOS only)
                        liquidButton(
                            systemName: isAudioOnly ? "video.fill" : "music.note",
                            tint: isAudioOnly ? Color.accentPrimary : .white
                        ) {
                            withAnimation(.spring(response: 0.3)) { isAudioOnly.toggle() }
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

            // (Resume prompt removed — no DVR.)
        }
        // .animation removed (resume prompt removed)
    }

    // Frosted-glass circular button used in the player controls.
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
        logStore.append("ℹ️ Player: MobileVLCKit (VLC)")
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
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
            }
        }
    }

    // formatOffset removed — DVR/resume prompt removed.
}

// MARK: - VLC Representable
private struct VLCPlayerViewRepresentable: UIViewRepresentable {
    let urls: [URL]
    let headers: [String: String]
    let isLive: Bool
    let nowPlayingTitle: String
    let nowPlayingSubtitle: String?
    let nowPlayingArtworkURL: URL?
    @ObservedObject var progressStore: PlayerProgressStore
    @ObservedObject var logStore: AttemptLogStore
    let onFatalError: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(urls: urls, headers: headers, isLive: isLive,
                    progressStore: progressStore, logStore: logStore,
                    onFatalError: onFatalError)
        c.nowPlayingTitle = nowPlayingTitle
        c.nowPlayingSubtitle = nowPlayingSubtitle
        c.nowPlayingArtworkURL = nowPlayingArtworkURL
        return c
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        // VLC only needs the view as a render target — it doesn't need touch events.
        // Disabling interaction lets SwiftUI gesture recognizers on parent views fire correctly.
        view.isUserInteractionEnabled = false

        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            #else
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            #endif
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logStore.append("⚠️ AudioSession: \(error)")
        }

        context.coordinator.attach(to: view)
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.updateDrawable(uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
        private var urls: [URL]
        private let headers: [String: String]
        private let isLive: Bool
        private let progressStore: PlayerProgressStore
        private let logStore: AttemptLogStore
        private let onFatalError: @MainActor @Sendable (String) -> Void

        // Now Playing metadata — set by VLCPlayerViewRepresentable
        var nowPlayingTitle: String = ""
        var nowPlayingSubtitle: String?
        var nowPlayingArtworkURL: URL?
        private var nowPlayingConfigured = false

        // Primary live/VOD player.
        private let mediaPlayer = VLCMediaPlayer()
        private weak var drawableView: UIView?
        private var currentIndex = 0
        private var hasStarted = false
        private var anyAttemptStarted = false   // true if any URL reached .playing
        private var hasPerformedWarmupRetry = false
        private var lastState: VLCMediaPlayerState = .stopped
        /// Tracks when the current URL started playing (first frame) so we can
        /// detect premature "ended" reports from VLC on live HLS streams.
        private var playbackStartTime: Date?
        /// Number of times we've retried the same URL due to premature "ended".
        private var sameURLRetryCount = 0
        private let maxSameURLRetries = 3

        // DVR removed — live streams play at the live edge only.

        init(urls: [URL], headers: [String: String], isLive: Bool,
             progressStore: PlayerProgressStore,
             logStore: AttemptLogStore,
             onFatalError: @escaping @MainActor @Sendable (String) -> Void) {
            self.urls = urls
            self.headers = headers
            self.isLive = isLive
            self.progressStore = progressStore
            self.logStore = logStore
            self.onFatalError = onFatalError
            super.init()
            mediaPlayer.delegate = self

            // Toggle play/pause.
            progressStore.togglePauseAction = { [weak self] in
                guard let self else { return }
                if self.progressStore.isPaused {
                    self.mediaPlayer.play()
                } else {
                    self.mediaPlayer.pause()
                }
            }

            // Seek closure — VOD only (live streams have no DVR).
            progressStore.seekAction = { [weak self] targetMs in
                guard let self, !self.isLive else { return }
                self.mediaPlayer.time = VLCTime(int: targetMs)
            }
        }

        func attach(to view: UIView) {
            drawableView = view
            // VLC's drawable must be set on the main thread to avoid
            // "Modifying properties of a view's layer off the main thread" warnings.
            if Thread.isMainThread {
                mediaPlayer.drawable = view
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.mediaPlayer.drawable = view
                }
            }
        }

        func updateDrawable(_ view: UIView) {
            drawableView = view
            if mediaPlayer.drawable as AnyObject? !== view {
                if Thread.isMainThread {
                    mediaPlayer.drawable = view
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.mediaPlayer.drawable = view
                    }
                }
            }
        }

        func start() {
            guard !urls.isEmpty else {
                let callback = onFatalError
                Task { await callback("No URL provided") }
                return
            }
            currentIndex = 0
            anyAttemptStarted = false
            hasPerformedWarmupRetry = false
            sameURLRetryCount = 0
            play(url: urls[currentIndex])
        }

        func stop() {
            DebugLogger.shared.logPlayback(event: "Stop",
                                           url: urls[safe: currentIndex]?.absoluteString)
            mediaPlayer.delegate = nil
            mediaPlayer.stop()
            mediaPlayer.media = nil
            Task { @MainActor in NowPlayingBridge.shared.teardown() }
            // Clear drawable on the main thread to avoid layer-modification warnings.
            if Thread.isMainThread {
                mediaPlayer.drawable = nil
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.mediaPlayer.drawable = nil
                }
            }
        }

        private func play(url: URL) {
            // Fully stop and release previous media before starting new playback.
            // Without this, VLC's internal threads (decoder, demuxer, audio output)
            // from the previous URL may still be running, causing resource conflicts
            // and "Failed to set properties" errors on subsequent attempts.
            if mediaPlayer.isPlaying || mediaPlayer.state != .stopped {
                mediaPlayer.stop()
            }
            mediaPlayer.media = nil

            hasStarted = false
            playbackStartTime = nil
            logStore.append("▶️ VLC attempt \(currentIndex + 1)/\(urls.count)")
            logStore.append("  \(url.absoluteString)")
            DebugLogger.shared.logPlayback(event: "Play attempt \(currentIndex + 1)/\(urls.count)",
                                           url: url.absoluteString)

            let media = VLCMedia(url: url)
            // Read the user's buffer size preference and convert to VLC ms values.
            // Live streams get a higher minimum (3000ms) to avoid premature "ended"
            // reports from VLC on HLS streams served by proxies like Dispatcharr.
            let cachingMs: Int = {
                let userPref: Int = {
                    switch UserDefaults.standard.string(forKey: "streamBufferSize") ?? "default" {
                    case "small":  return 300
                    case "large":  return 3_000
                    case "xlarge": return 8_000
                    default:       return 1_500   // "default" = 1.5 s
                    }
                }()
                // For live proxy streams, enforce a minimum buffer to avoid
                // premature "ended" reports from VLC.
                if isLive { return max(userPref, 1_500) }
                return userPref
            }()

            // VLC options for smooth playback.
            var options: [String] = [
                ":network-caching=\(cachingMs)",
                ":live-caching=\(cachingMs)",
                ":file-caching=\(cachingMs)",
                ":drop-late-frames",
                ":skip-frames",
                // Decode optimization: skip loop filter & IDCT for non-reference frames.
                // Value 4 = skip for non-ref frames only (safe quality tradeoff).
                ":avcodec-skiploopfilter=4",
                ":avcodec-skip-idct=4"
                // Note: TVVLCKit enables VideoToolbox hardware decoding by default.
                // Explicit :codec/:videotoolbox options can interfere — don't add them.
            ]
            // Only disable clock sync for VOD — live MPEG-TS streams need clock
            // recovery via PCR timestamps; disabling it causes VLC to report
            // premature "ended" on proxy streams.
            if !isLive {
                options.append(":clock-jitter=0")
                options.append(":clock-synchro=0")
            }
            for o in options { media.addOption(o) }

            #if DEBUG
            print("[VLC-DIAG] ── Starting playback ──")
            print("[VLC-DIAG] URL: \(url.absoluteString)")
            print("[VLC-DIAG] network-caching=\(cachingMs)ms, live-caching=\(cachingMs)ms")
            print("[VLC-DIAG] isLive=\(isLive), attempt=\(currentIndex + 1)/\(urls.count)")
            #endif

            if let ua = headers["User-Agent"], !ua.isEmpty { media.addOption(":http-user-agent=\(ua)") }
            for (k, v) in headers where k.caseInsensitiveCompare("User-Agent") != .orderedSame {
                media.addOption(":http-header=\(k): \(v)")
            }
            mediaPlayer.media = media
            mediaPlayer.play()
        }

        private func failoverOrError(_ reason: String) {
            logStore.append("✗ VLC: \(reason)")
            if currentIndex + 1 < urls.count {
                currentIndex += 1
                // Pause lets VLC's internal threads (decoder, demuxer, audio)
                // fully release before we start a new stream. TVVLCKit has strict
                // dispatch queue assertions that crash if old threads are still active.
                let nextURL = urls[currentIndex]
                let idx = currentIndex
                print("[VLC-DIAG] Failover: waiting 300ms before attempt \(idx + 1)/\(urls.count)")
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    print("[VLC-DIAG] Failover: starting attempt \(idx + 1)")
                    self.play(url: nextURL)
                }
            } else if isLive && anyAttemptStarted && !hasPerformedWarmupRetry {
                // Live streams only: Dispatcharr proxy cold-start — the FFmpeg session wasn't
                // ready on the first connection but is now. Retry once after a brief wait.
                hasPerformedWarmupRetry = true
                logStore.append("⏳ VLC: proxy warming up — retrying in 2s…")
                print("[VLC-DIAG] Warmup retry: waiting 2s before retry")
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.currentIndex = 0
                    self.anyAttemptStarted = false
                    self.logStore.append("🔄 VLC: warm-up retry")
                    print("[VLC-DIAG] Warmup retry: starting")
                    self.play(url: self.urls[0])
                }
            } else {
                let callback = onFatalError
                Task { await callback(reason) }
            }
        }

        private var lastBufferPrint: Date = .distantPast

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            let s = mediaPlayer.state
            if s == lastState { return }
            lastState = s

            #if DEBUG
            let ts = String(format: "%.3f", Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
            print("[VLC-DIAG] [\(ts)] State: \(s.rawValue) (\(stateLabel(s)))")
            #endif

            switch s {
            case .opening:
                logStore.append("ℹ️ VLC state: opening")
                DebugLogger.shared.logVLCState("opening")
            case .buffering:
                logStore.append("ℹ️ VLC state: buffering")
                DebugLogger.shared.logVLCState("buffering")
                #if DEBUG
                print("[VLC-DIAG]   ↳ Buffering detected — possible stutter cause")
                #endif
            case .playing:
                if !hasStarted {
                    hasStarted = true
                    anyAttemptStarted = true
                    playbackStartTime = Date()
                    logStore.append("✓ VLC started")
                    DebugLogger.shared.logVLCState("playing — first frame")
                    #if DEBUG
                    print("[VLC-DIAG]   ↳ First frame rendered")
                    #endif
                }
                let ps = progressStore
                DispatchQueue.main.async { ps.isPaused = false }

                // Configure Now Playing after playback stabilizes.
                // Wait 2s then check if still playing — instant-end URLs (0ms)
                // will have already failed over, so configure only fires once
                // playback is genuinely stable. This prevents artwork downloads
                // from racing with VLC failover on tvOS.
                if !nowPlayingConfigured {
                    let title = nowPlayingTitle
                    let sub = nowPlayingSubtitle
                    let art = nowPlayingArtworkURL
                    let live = isLive
                    let dur: Double? = live ? nil : (mediaPlayer.media?.length.intValue).map { Double($0) / 1000.0 }
                    let mp = mediaPlayer
                    let ps2 = progressStore
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self,
                              !self.nowPlayingConfigured,
                              self.mediaPlayer.isPlaying else { return }
                        self.nowPlayingConfigured = true
                        Task { @MainActor in
                            NowPlayingBridge.shared.configure(
                                title: title,
                                subtitle: sub,
                                artworkURL: art,
                                duration: dur,
                                isLive: live,
                                onPlay:  { ps2.togglePauseAction?() },
                                onPause: { ps2.togglePauseAction?() },
                                onSeek: live ? nil : { time in
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        mp.time = VLCTime(int: Int32(time * 1000))
                                    }
                                }
                            )
                        }
                    }
                }
            case .paused:
                logStore.append("ℹ️ VLC state: paused")
                DebugLogger.shared.logVLCState("paused")
                let ps = progressStore
                let timeSec = Double(mediaPlayer.time.intValue) / 1000.0
                DispatchQueue.main.async { ps.isPaused = true }
                Task { @MainActor in NowPlayingBridge.shared.updateElapsed(timeSec, rate: 0.0) }
            case .stopped:
                DebugLogger.shared.logVLCState("stopped", url: urls[safe: currentIndex]?.absoluteString)
                // Defer failover out of VLC's delegate callback to avoid
                // _dispatch_assert_queue_fail inside TVVLCKit's internal threading.
                if !hasStarted {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.failoverOrError("Stopped before playback")
                    }
                }
            case .ended:
                // For live streams, VLC sometimes prematurely reports "ended".
                // Two distinct cases:
                //  1. Instant-end (<0.5s): server returned a tiny/empty response.
                //     Retrying the same URL is pointless — fail over immediately.
                //  2. Short-end (0.5s–5s): transient issue (proxy hiccup, brief
                //     buffer underrun). Retry the same URL up to 3 times.
                //
                // IMPORTANT: All failover calls are deferred off VLC's delegate thread
                // to prevent _dispatch_assert_queue_fail crashes in TVVLCKit.
                if isLive, let startTime = playbackStartTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed < 0.5 {
                        // Instant-end — server can't deliver this URL, skip to next.
                        logStore.append("⚠️ VLC: instant end (<0.5s) — skipping to next URL")
                        print("[VLC-DIAG] Instant end (\(String(format: "%.0f", elapsed * 1000))ms) — failing over")
                        sameURLRetryCount = 0
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            self?.failoverOrError("Stream ended instantly")
                        }
                    } else if elapsed < 5.0, sameURLRetryCount < maxSameURLRetries {
                        sameURLRetryCount += 1
                        let retryNum = sameURLRetryCount
                        logStore.append("⚠️ VLC: premature end (<5s) — retrying same URL (\(retryNum)/\(maxSameURLRetries))")
                        DebugLogger.shared.logVLCState("ended prematurely — retrying same URL (\(retryNum)/\(maxSameURLRetries))")
                        print("[VLC-DIAG] Premature end (\(String(format: "%.1f", elapsed))s) — retrying same URL (\(retryNum)/\(maxSameURLRetries))")
                        let retryURL = urls[currentIndex]
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) { [weak self] in
                            self?.play(url: retryURL)
                        }
                    } else {
                        DebugLogger.shared.logVLCState("ended — triggering failover")
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            self?.failoverOrError("Stream ended")
                        }
                    }
                } else {
                    DebugLogger.shared.logVLCState("ended — triggering failover")
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.failoverOrError("Stream ended")
                    }
                }
            case .error:
                DebugLogger.shared.logVLCState("error — triggering failover",
                                               url: urls[safe: currentIndex]?.absoluteString)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.failoverOrError("Playback error")
                }
            default:
                logStore.append("ℹ️ VLC state: \(s.rawValue)")
                DebugLogger.shared.logVLCState("\(s.rawValue)")
            }
        }

        private func stateLabel(_ s: VLCMediaPlayerState) -> String {
            switch s {
            case .opening: return "opening"
            case .buffering: return "buffering"
            case .playing: return "playing"
            case .paused: return "paused"
            case .stopped: return "stopped"
            case .ended: return "ended"
            case .error: return "error"
            case .esAdded: return "esAdded"
            @unknown default: return "unknown(\(s.rawValue))"
            }
        }

        private var timeChangeCount: Int = 0
        private var lastTimePrint: Date = .distantPast
        private var lastProgressUpdate: Date = .distantPast

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            let ms  = mediaPlayer.time.intValue
            let dur = mediaPlayer.media?.length.intValue ?? 0

            // Throttle UI updates to max once per second to reduce main thread load.
            // For live streams, skip entirely — no scrubber is shown and these
            // @Published updates trigger expensive SwiftUI re-renders that cause stutter.
            let now = Date()
            if !isLive, now.timeIntervalSince(lastProgressUpdate) >= 1.0 {
                lastProgressUpdate = now
                let ps = progressStore
                DispatchQueue.main.async {
                    ps.currentMs  = ms
                    ps.durationMs = dur
                }
            }

            // Periodic diagnostic print + Now Playing update.
            // Live streams: update every 15s (system interpolates via playbackRate).
            // VOD: update every 5s for scrubber accuracy.
            timeChangeCount += 1
            let diagNow = Date()
            let npInterval: TimeInterval = isLive ? 15.0 : 5.0
            if diagNow.timeIntervalSince(lastTimePrint) >= npInterval {
                let state = mediaPlayer.state.rawValue
                let isPlaying = mediaPlayer.isPlaying
                #if DEBUG
                print("[VLC-DIAG] time=\(ms)ms dur=\(dur)ms isPlaying=\(isPlaying) state=\(state) callbacks/\(Int(npInterval))s=\(timeChangeCount)")
                #endif
                timeChangeCount = 0
                lastTimePrint = diagNow

                // Update Now Playing elapsed time (capture values on VLC thread)
                let timeSec = Double(ms) / 1000.0
                let rate: Float = isPlaying ? 1.0 : 0.0
                Task { @MainActor in
                    NowPlayingBridge.shared.updateElapsed(timeSec, rate: rate)
                }
            }

            // First-start detection (drives the "connecting" → "playing" state transition).
            guard !hasStarted else { return }
            if ms > 0 {
                hasStarted = true
                anyAttemptStarted = true
                logStore.append("✓ VLC time advanced: \(ms)ms")
                print("[VLC-DIAG] First time change: \(ms)ms — playback started")
            }
        }
    }
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

