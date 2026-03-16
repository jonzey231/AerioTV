import SwiftUI
import AVFoundation
import AVKit
import MediaPlayer
#if os(iOS)
import UIKit
#endif

// VLC-based playback (MobileVLCKit) – reliable for MPEG-TS over HTTP.
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

// MARK: - Attempt Log Store
// @unchecked Sendable: all mutations are dispatched to the main queue manually.
final class AttemptLogStore: ObservableObject, @unchecked Sendable {
    @Published var lines: [String] = []

    func append(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lines.append(line)
        }
    }

    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.lines.removeAll()
        }
    }
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
                                .textSelection(.enabled)
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
                            .textSelection(.enabled)
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

#if canImport(MobileVLCKit)

// MARK: - PlayerView (VLC + controls overlay)

struct PlayerView: View {
    let urls: [URL]
    let title: String
    let headers: [String: String]
    let onMinimize: (() -> Void)?
    let onClose: (() -> Void)?

    init(urls: [URL], title: String, headers: [String: String]? = nil,
         onMinimize: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.urls = urls
        self.title = title
        self.headers = headers ?? [:]
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
                        urls: urls, headers: headers, logStore: logStore,
                        onFatalError: { err in lastError = err; state = .error }
                    )
                    .ignoresSafeArea()

                    if isAudioOnly {
                        audioOnlyBackground
                            .transition(.opacity)
                    }

                    if showControls {
                        controlsOverlay
                            .transition(.opacity)
                    }

                    // Transparent tap layer — toggles controls on tap, passes through button taps.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                            if showControls { scheduleControlsHide() }
                        }
                        .allowsHitTesting(!showControls)
                }

            case .error:
                StreamErrorView(
                    title: title, message: lastError.isEmpty ? "Playback failed." : lastError,
                    logStore: logStore, didCopyErrorDetails: $didCopyErrorDetails,
                    onClose: onDismiss
                )
            }
        }
        // Offset and opacity applied to the whole view (including the black background) so the
        // tab content already rendered beneath in MainTabView is revealed as the player slides down.
        .offset(y: max(0, dragOffset))
        .opacity(1.0 - min(0.4, dragOffset / 400))
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard state == .playing, value.translation.height > 0 else { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    guard state == .playing else { return }
                    let screenH = UIScreen.main.bounds.height
                    // Accept the gesture if the actual drag is > 60pt downward, OR
                    // if a fast flick would predictably land far enough — catches quick swipes
                    // that don't travel far before the finger lifts.
                    let isSwipeDown = value.translation.height > abs(value.translation.width) &&
                                      (value.translation.height > 60 ||
                                       value.predictedEndTranslation.height > 150)
                    if isSwipeDown {
                        // Overdamped spring (dampingFraction ≥ 1) behaves like a fast easeOut:
                        // it starts at full speed and decelerates smoothly to the target —
                        // no slow-start stutter that easeIn produces.
                        withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) {
                            dragOffset = screenH
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 220_000_000)
                            onMinimize?()
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .task { await startPlayback() }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showControls)
        .onAppear { scheduleControlsHide() }
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
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 44
    }

    // MARK: - Controls Overlay
    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // Swipe-down handle — hints that dragging down minimizes
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 36, height: 4)
                    .padding(.top, deviceSafeAreaTop + 8)

                // Top bar
                HStack(alignment: .center, spacing: 12) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.6), radius: 4)

                    Spacer()

                    HStack(spacing: 10) {
                        // Audio-only toggle
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
        }
    }

    // Frosted-glass circular button used in the player controls.
    private func liquidButton(
        systemName: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        }
    }

    private func startPlayback() async {
        logStore.reset()
        logStore.append("ℹ️ Player: MobileVLCKit (VLC)")
        state = .playing
    }

    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
            }
        }
    }
}

// MARK: - VLC Representable
private struct VLCPlayerViewRepresentable: UIViewRepresentable {
    let urls: [URL]
    let headers: [String: String]
    @ObservedObject var logStore: AttemptLogStore
    let onFatalError: @MainActor @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls, headers: headers, logStore: logStore, onFatalError: onFatalError)
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
                options: [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
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

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private var urls: [URL]
        private let headers: [String: String]
        private let logStore: AttemptLogStore
        private let onFatalError: @MainActor @Sendable (String) -> Void

        private let mediaPlayer = VLCMediaPlayer()
        private weak var drawableView: UIView?
        private var currentIndex = 0
        private var hasStarted = false
        private var anyAttemptStarted = false   // true if any URL reached .playing
        private var hasPerformedWarmupRetry = false
        private var lastState: VLCMediaPlayerState = .stopped

        init(urls: [URL], headers: [String: String], logStore: AttemptLogStore, onFatalError: @escaping @MainActor @Sendable (String) -> Void) {
            self.urls = urls
            self.headers = headers
            self.logStore = logStore
            self.onFatalError = onFatalError
            super.init()
            mediaPlayer.delegate = self
        }

        func attach(to view: UIView) { drawableView = view; mediaPlayer.drawable = view }

        func updateDrawable(_ view: UIView) {
            if mediaPlayer.drawable as AnyObject? !== view { mediaPlayer.drawable = view }
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
            play(url: urls[currentIndex])
        }

        func stop() { mediaPlayer.stop(); mediaPlayer.drawable = nil }

        private func play(url: URL) {
            hasStarted = false
            logStore.append("▶️ VLC attempt \(currentIndex + 1)/\(urls.count)")
            logStore.append("  \(url.absoluteString)")

            let media = VLCMedia(url: url)
            for o in [":network-caching=300",":clock-jitter=0",":clock-synchro=0",
                      ":live-caching=300",":file-caching=300",":drop-late-frames",":skip-frames"] {
                media.addOption(o)
            }
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
                play(url: urls[currentIndex])
            } else if anyAttemptStarted && !hasPerformedWarmupRetry {
                // All URLs exhausted but at least one reached .playing — likely a Dispatcharr
                // proxy cold-start: the session wasn't ready on first connection but is now.
                // Wait briefly and retry from URL 0; this matches the pattern where the same
                // channel always plays on the second manual attempt.
                hasPerformedWarmupRetry = true
                logStore.append("⏳ VLC: proxy warming up — retrying in 1.5s…")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let self else { return }
                    self.currentIndex = 0
                    self.anyAttemptStarted = false
                    self.logStore.append("🔄 VLC: warm-up retry")
                    self.play(url: self.urls[0])
                }
            } else {
                let callback = onFatalError
                Task { await callback(reason) }
            }
        }

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            let s = mediaPlayer.state
            if s == lastState { return }
            lastState = s
            switch s {
            case .opening:   logStore.append("ℹ️ VLC state: opening")
            case .buffering: logStore.append("ℹ️ VLC state: buffering")
            case .playing:
                if !hasStarted {
                    hasStarted = true
                    anyAttemptStarted = true
                    logStore.append("✓ VLC started")
                }
            case .paused:    logStore.append("ℹ️ VLC state: paused")
            case .stopped:   if !hasStarted { failoverOrError("Stopped before playback") }
            case .ended:     failoverOrError("Stream ended")
            case .error:     failoverOrError("Playback error")
            default:         logStore.append("ℹ️ VLC state: \(s.rawValue)")
            }
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            if hasStarted { return }
            let ms = (mediaPlayer.value(forKey: "time") as? VLCTime)?.intValue ?? 0
            if ms > 0 { hasStarted = true; logStore.append("✓ VLC time advanced: \(ms)ms") }
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

#else

// MARK: - Fallback stub (tvOS / missing VLCKit)
struct PlayerView: View {
    let urls: [URL]
    let title: String
    let headers: [String: String]

    init(urls: [URL], title: String, headers: [String: String]? = nil) {
        self.urls = urls; self.title = title; self.headers = headers ?? [:]
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44)).foregroundColor(.yellow)
                Text("Playback Unavailable")
                    .font(.title3.bold()).foregroundColor(.white)
                Text("This build does not include VLC playback support.")
                    .font(.callout).foregroundColor(.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button("Close") { dismiss() }
                    .foregroundColor(.accentColor).padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }
}

#endif
