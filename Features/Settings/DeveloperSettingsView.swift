import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Developer Settings View

struct DeveloperSettingsView: View {
    @AppStorage("debugLoggingEnabled") private var debugLoggingEnabled = false

    /// Mirrors `PlaybackFeatureFlags.useUnifiedPlayback`. The toggle
    /// routes every playback entry point (guide tap, favorites,
    /// CarPlay, deep-link, add-sheet) through `PlayerSession.begin(...)`
    /// which mounts `MultiviewContainerView` from the first tile
    /// instead of the legacy `PlayerView`. **Default `true`** as of
    /// Phase D — the unified view is now the canonical path. Users
    /// who hit a unified-path regression can flip this off for the
    /// legacy `PlayerView` fallback while we chase the bug.
    @AppStorage("playback.unified") private var unifiedPlayback = true

    @Query private var servers: [ServerConnection]

    @State private var showEnableConfirmation = false
    @State private var showDisableConfirmation = false
    @State private var copiedConfirmation = false
    @State private var showClearConfirmation = false
    @State private var showLogViewer = false
    @State private var logSize = "Empty"
    private let logger = DebugLogger.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("Developer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)

        // MARK: - Enable Confirmation
        .alert("Enable Debug Logging?", isPresented: $showEnableConfirmation) {
            Button("Enable Logging", role: .none) {
                debugLoggingEnabled = true
                logger.enable()
                refreshLogSize()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AerioTV will write detailed diagnostic logs to a file on your device.\n\nThis includes network requests, playback events, and error details. The file is only accessible from this device via the Files app or the share button below.\n\nLogging has a minor impact on performance and storage. You can disable it at any time.")
        }

        // MARK: - Disable Confirmation
        .alert("Disable Debug Logging?", isPresented: $showDisableConfirmation) {
            Button("Disable", role: .destructive) {
                logger.disable()
                debugLoggingEnabled = false
                refreshLogSize()
            }
            Button("Keep Logging", role: .cancel) {}
        } message: {
            Text("The existing log file will be kept. You can share or clear it at any time.")
        }

        // MARK: - Clear Confirmation
        .confirmationDialog("Clear Log File?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) {
                logger.clearLogs()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshLogSize() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the current aerio_debug_logs.txt. This cannot be undone.")
        }
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {

                // MARK: - Debug Logging Toggle
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(debugLoggingEnabled
                                      ? Color.accentPrimary.opacity(0.18)
                                      : Color.elevatedBackground)
                                .frame(width: 36, height: 36)
                            Image(systemName: debugLoggingEnabled
                                  ? "ladybug.fill"
                                  : "ladybug")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(debugLoggingEnabled ? .accentPrimary : .textSecondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Debug Logging")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text(debugLoggingEnabled
                                 ? "Active — writing to aerio_debug_logs.txt"
                                 : "Off — no data is collected")
                                .font(.labelSmall)
                                .foregroundColor(debugLoggingEnabled ? .accentPrimary : .textTertiary)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { debugLoggingEnabled },
                            set: { newValue in
                                if newValue {
                                    showEnableConfirmation = true
                                } else {
                                    showDisableConfirmation = true
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(.accentPrimary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.cardBackground)

                } header: {
                    Text("Logging")
                        .sectionHeaderStyle()
                } footer: {
                    Text("When enabled, detailed logs are written to a file in On My iPhone › AerioTV. Logs include network requests, playback events, EPG activity, errors, and app lifecycle events. No personally identifiable information is collected.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                        .padding(.top, 4)
                }
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif

                // MARK: - Unified Playback (experimental)
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(unifiedPlayback
                                      ? Color.accentPrimary.opacity(0.18)
                                      : Color.elevatedBackground)
                                .frame(width: 36, height: 36)
                            Image(systemName: unifiedPlayback
                                  ? "rectangle.stack.fill"
                                  : "rectangle.stack")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(unifiedPlayback ? .accentPrimary : .textSecondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unified Playback")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text(unifiedPlayback
                                 ? "On — default. Every channel runs in the multiview container."
                                 : "Off — legacy PlayerView fallback")
                                .font(.labelSmall)
                                .foregroundColor(unifiedPlayback ? .accentPrimary : .textTertiary)
                        }

                        Spacer()

                        Toggle("", isOn: $unifiedPlayback)
                            .labelsHidden()
                            .tint(.accentPrimary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Playback Engine")
                        .sectionHeaderStyle()
                } footer: {
                    Text("Unified Playback is the default shipping path — a single tile mounts MultiviewContainerView from the first frame, so adding a second stream is seamless (no view-swap, no re-setup). Disable only if you hit a unified-path regression; the legacy PlayerView remains available as a fallback for the single-stream case but does not support tvOS multiview or the new mini-player UX. Only affects live playback; VOD always uses the legacy path. Restart playback for the change to take effect.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                        .padding(.top, 4)
                }
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif

                // MARK: - Log File Actions (only when logging is active or file exists)
                if debugLoggingEnabled || (logger.logFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                    Section {

                        // File size row
                        HStack {
                            Label {
                                Text("Log File Size")
                                    .font(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                            } icon: {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.textSecondary)
                            }
                            Spacer()
                            Text(logSize)
                                .font(.monoSmall)
                                .foregroundColor(.textTertiary)
                        }
                        .listRowBackground(Color.cardBackground)
                        .task { refreshLogSize() }

                        // View
                        if let url = logger.logFileURL,
                           FileManager.default.fileExists(atPath: url.path) {
                            Button {
                                showLogViewer = true
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("View Log File")
                                            .font(.bodyMedium)
                                            .foregroundColor(.textPrimary)
                                        Text("Scroll through entries in the app")
                                            .font(.labelSmall)
                                            .foregroundColor(.textTertiary)
                                    }
                                } icon: {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .foregroundColor(.accentPrimary)
                                }
                            }
                            .listRowBackground(Color.cardBackground)
                            .sheet(isPresented: $showLogViewer) {
                                LogViewerView(url: url)
                            }
                        }

                        // Share — uses a UIKit sheet with proper iPad popover anchoring
                        if let url = logger.logFileURL,
                           FileManager.default.fileExists(atPath: url.path) {
                            Button {
                                shareFile(url)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Share Log File")
                                            .font(.bodyMedium)
                                            .foregroundColor(.textPrimary)
                                        Text("Email, Messages, Discord, Signal…")
                                            .font(.labelSmall)
                                            .foregroundColor(.textTertiary)
                                    }
                                } icon: {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundColor(.accentPrimary)
                                }
                            }
                            #if os(tvOS)
                            .buttonStyle(TVNoHighlightButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .listRowBackground(Color.cardBackground)
                        }

                        // Clear
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Label("Clear Log File", systemImage: "trash")
                                .font(.bodyMedium)
                        }
                        .listRowBackground(Color.cardBackground)

                    } header: {
                        Text("Log File")
                            .sectionHeaderStyle()
                    }
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif
                }

                // MARK: - What's Logged
                Section {
                    logCategoryRow(icon: "network",                title: "Network",     detail: "All API requests — URL, method, status code, duration, payload size")
                    logCategoryRow(icon: "play.rectangle.fill",    title: "Playback",    detail: "Stream URLs loaded, player state transitions, DVR mode, failover attempts")
                    logCategoryRow(icon: "calendar",               title: "EPG",         detail: "Current program fetches, upcoming program loads, decode errors")
                    logCategoryRow(icon: "antenna.radiowaves.left.and.right", title: "Channels", detail: "Channel list loads, server type, item counts, timing")
                    logCategoryRow(icon: "app.badge",              title: "Lifecycle",   detail: "App foreground/background, launch, scene transitions")
                    logCategoryRow(icon: "exclamationmark.triangle.fill", title: "Errors", detail: "Caught exceptions with full context, source file and line number")
                    logCategoryRow(icon: "gauge.with.dots.needle.67percent", title: "Performance", detail: "Timed operations — parse time, load time, memory at session start")
                } header: {
                    Text("What's Captured")
                        .sectionHeaderStyle()
                } footer: {
                    Text("Logs rotate automatically when the file exceeds 10 MB. The previous log is preserved as aerio_debug_logs_archive.txt.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif

            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
    }
    #endif

    // MARK: - tvOS Body
    // Uses the shared TVSettings* components so focus highlights match the
    // rest of the tvOS UI. iOS-only rows (Share Log File via
    // UIActivityViewController) are omitted — the log file can still be
    // retrieved via the companion iOS/iPad app or Files app sharing.
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvSection("Logging") {
                    TVSettingsToggleRow(
                        icon: debugLoggingEnabled ? "ladybug.fill" : "ladybug",
                        iconColor: debugLoggingEnabled ? .accentPrimary : .textSecondary,
                        title: "Debug Logging",
                        subtitle: debugLoggingEnabled
                            ? "Active — writing to aerio_debug_logs.txt"
                            : "Off — no data is collected",
                        isOn: Binding(
                            get: { debugLoggingEnabled },
                            set: { newValue in
                                if newValue {
                                    showEnableConfirmation = true
                                } else {
                                    showDisableConfirmation = true
                                }
                            }
                        )
                    ) { _ in }
                }

                tvSection("Experimental") {
                    TVSettingsToggleRow(
                        icon: unifiedPlayback ? "rectangle.stack.fill" : "rectangle.stack",
                        iconColor: unifiedPlayback ? .accentPrimary : .textSecondary,
                        title: "Unified Playback",
                        subtitle: unifiedPlayback
                            ? "On — every channel runs in the multiview container"
                            : "Off — legacy single-stream PlayerView",
                        isOn: $unifiedPlayback
                    ) { _ in }
                }

                if debugLoggingEnabled || (logger.logFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                    tvSection("Log File") {
                        tvLogSizeCard
                            .task { refreshLogSize() }

                        if let url = logger.logFileURL,
                           FileManager.default.fileExists(atPath: url.path) {
                            TVSettingsActionRow(
                                icon: "doc.text.magnifyingglass",
                                label: "View Log File",
                                isAccent: true,
                                action: { showLogViewer = true }
                            )
                            .sheet(isPresented: $showLogViewer) {
                                LogViewerView(url: url)
                            }
                        }

                        TVSettingsActionRow(
                            icon: "trash",
                            label: "Clear Log File",
                            isDestructive: true,
                            action: { showClearConfirmation = true }
                        )
                    }
                }

                tvSection("What's Captured") {
                    tvLogCategoryCard
                }
            }
            .padding(48)
        }
    }

    private var tvLogSizeCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundColor(.textSecondary)
                .frame(width: 36)
            Text("Log File Size")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.textPrimary)
            Spacer()
            Text(logSize)
                .font(.system(size: 24, design: .monospaced))
                .foregroundColor(.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentPrimary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private var tvLogCategoryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            tvLogCategory(icon: "network",
                          title: "Network",
                          detail: "All API requests — URL, method, status code, duration, payload size")
            tvLogCategory(icon: "play.rectangle.fill",
                          title: "Playback",
                          detail: "Stream URLs loaded, player state transitions, DVR mode, failover attempts")
            tvLogCategory(icon: "calendar",
                          title: "EPG",
                          detail: "Current program fetches, upcoming program loads, decode errors")
            tvLogCategory(icon: "antenna.radiowaves.left.and.right",
                          title: "Channels",
                          detail: "Channel list loads, server type, item counts, timing")
            tvLogCategory(icon: "app.badge",
                          title: "Lifecycle",
                          detail: "App foreground/background, launch, scene transitions")
            tvLogCategory(icon: "exclamationmark.triangle.fill",
                          title: "Errors",
                          detail: "Caught exceptions with full context, source file and line number")
            tvLogCategory(icon: "gauge.with.dots.needle.67percent",
                          title: "Performance",
                          detail: "Timed operations — parse time, load time, memory at session start")

            Text("Logs rotate automatically when the file exceeds 10 MB. The previous log is preserved as aerio_debug_logs_archive.txt.")
                .font(.system(size: 20))
                .foregroundColor(.textTertiary)
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentPrimary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func tvLogCategory(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.accentSecondary)
                .frame(width: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text(detail)
                    .font(.system(size: 20))
                    .foregroundColor(.textSecondary)
            }
        }
    }

    private func tvSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textTertiary)
                .tracking(1)
                .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }
    #endif

    // MARK: - Helpers

    private func refreshLogSize() {
        logSize = logger.logFileSizeString
    }

    /// Present a UIActivityViewController with proper iPad popover anchoring.
    private func shareFile(_ url: URL) {
        #if os(iOS)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return
        }

        // Walk to the topmost presented controller.
        var presenter = rootVC
        while let next = presenter.presentedViewController { presenter = next }

        // iPad requires a popover anchor — center it in the presenting view.
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = [.up, .down]
        }

        presenter.present(activityVC, animated: true)
        #endif
    }
}

// MARK: - Log Viewer View

struct LogViewerView: View {
    let url: URL

    @State private var content: String = ""
    @State private var isLoading = true
    @State private var isTruncated = false
    @Environment(\.dismiss) private var dismiss

    private let maxLines = 2_000

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading…")
                        .foregroundColor(.textSecondary)
                } else if content.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 40))
                            .foregroundColor(.textTertiary)
                        Text("Log file is empty.")
                            .font(.bodyMedium)
                            .foregroundColor(.textTertiary)
                    }
                } else {
                    VStack(spacing: 0) {
                        if isTruncated {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Showing last \(maxLines) lines — share the file for the full log")
                                    .font(.labelSmall)
                            }
                            .foregroundColor(.statusWarning)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.statusWarning.opacity(0.12))
                        }

                        LogTextView(text: content)
                    }
                }
            }
            .navigationTitle("Log File")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.accentPrimary)
                }
            }
            .task { await loadContent() }
        }
    }

    private func loadContent() async {
        let result: (String, Bool) = await Task.detached(priority: .userInitiated) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return ("", false)
            }
            let lines = raw.components(separatedBy: "\n")
            if lines.count > maxLines {
                return (lines.suffix(maxLines).joined(separator: "\n"), true)
            }
            return (raw, false)
        }.value

        content = result.0
        isTruncated = result.1
        isLoading = false
    }
}

// MARK: - Log Text View

#if canImport(UIKit)
private struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        #if os(iOS)
        tv.isEditable = false
        #endif
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        tv.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = UIColor.label
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard uiView.text != text else { return }
        uiView.text = text
        // Scroll to bottom so the newest entries are visible immediately
        DispatchQueue.main.async {
            let bottom = max(0, uiView.contentSize.height - uiView.bounds.height + uiView.contentInset.bottom)
            uiView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
    }
}
#endif

// MARK: - Log Category Row

private func logCategoryRow(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.accentSecondary)
            .frame(width: 20)
            .padding(.top, 2)

        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headlineSmall)
                .foregroundColor(.textPrimary)
            Text(detail)
                .font(.labelSmall)
                .foregroundColor(.textSecondary)
        }
    }
    .padding(.vertical, 4)
}
