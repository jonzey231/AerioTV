import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if os(tvOS)
import Network
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

// MARK: - Developer Settings View

struct DeveloperSettingsView: View {
    /// See SettingsView. Re-renders this page on every theme change
    /// so accent-tinted toggles and section headers don't freeze at
    /// the theme that was active when the page was first pushed.
    @ObservedObject private var theme = ThemeManager.shared
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

    /// **Experimental** — iPhone-only. When on, the Live TV chrome is
    /// compacted: Manage Groups moves into the nav bar toolbar, and the
    /// filter-pills + search strip can be hidden entirely via two new
    /// toggles inside the Manage Groups sheet. Default **off** so the
    /// main user base is unaffected; we ship the flag first to let
    /// opted-in testers validate the layout before considering a flip.
    /// Reads:
    /// - `ChannelListView` for the chrome layout branch
    /// - `ManageGroupsSheet` for the hide-filter / hide-search toggles
    @AppStorage("ui.iphone.compactChrome") private var compactChromeiPhone = false

    /// Companion toggles — previously only exposed inside the Manage
    /// Groups sheet, which made the parent "Compact Chrome" toggle
    /// seem to do nothing (#22 feedback: "I can't tell what iPhone
    /// Compact Chrome even does"). Exposed inline here so turning
    /// Compact Chrome ON reveals its actual controls directly beneath.
    @AppStorage("ui.iphone.hideFilterBar") private var hideFilterBarCompact = false
    @AppStorage("ui.iphone.hideSearchBar") private var hideSearchBarCompact = false

    @Query private var servers: [ServerConnection]

    @State private var showEnableConfirmation = false
    @State private var showDisableConfirmation = false
    @State private var copiedConfirmation = false
    @State private var showClearConfirmation = false
    @State private var showLogViewer = false
    #if os(tvOS)
    /// Drives the tvOS-only share sheet that exposes the log file on the
    /// LAN via a tiny embedded HTTP server. iOS uses
    /// UIActivityViewController instead (not available on tvOS).
    @State private var showTvOSShareSheet = false
    #endif
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
        // MARK: - tvOS Share Sheet (LAN HTTP server + QR code)
        // Presented when the user taps Share Log File on tvOS. The server
        // is started in `shareFile` just before this flips true; it stops
        // automatically when the sheet disappears (TvOSLogShareSheet.onDisappear).
        #if os(tvOS)
        .fullScreenCover(isPresented: $showTvOSShareSheet) {
            TvOSLogShareSheet(isPresented: $showTvOSShareSheet)
        }
        #endif
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {

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

                // MARK: - Experimental UI (iPhone only)
                // Veldmuus-proposal flag. Only show on actual iPhones — the
                // feature doesn't apply to iPad (its layout isn't cramped) or
                // to Mac Catalyst (no UIDevice.phone idiom in the iOS-family
                // sense). When toggled, the compact-chrome layout moves the
                // Manage Groups icon to the nav-bar trailing edge and lets
                // users hide the filter pills + search from inside the sheet.
                if UIDevice.current.userInterfaceIdiom == .phone {
                    Section {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(compactChromeiPhone
                                          ? Color.accentPrimary.opacity(0.18)
                                          : Color.elevatedBackground)
                                    .frame(width: 36, height: 36)
                                Image(systemName: compactChromeiPhone
                                      ? "iphone.gen3.landscape"
                                      : "iphone.gen3")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(compactChromeiPhone ? .accentPrimary : .textSecondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("iPhone Compact Chrome")
                                    .font(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Text(compactChromeiPhone
                                     ? "On — Manage Groups lives in the Live TV nav bar"
                                     : "Off — classic layout")
                                    .font(.labelSmall)
                                    .foregroundColor(compactChromeiPhone ? .accentPrimary : .textTertiary)
                            }

                            Spacer()

                            Toggle("", isOn: $compactChromeiPhone)
                                .labelsHidden()
                                .tint(.accentPrimary)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.cardBackground)

                        // Companion toggles — only meaningful when
                        // Compact Chrome is ON. Previously these were
                        // buried inside the Manage Groups sheet, which
                        // made the parent toggle seem inert ("I can't
                        // tell what iPhone Compact Chrome even does").
                        // Surfacing them here means turning Compact
                        // Chrome on immediately reveals its actual
                        // controls — users can see at a glance what
                        // the feature does before toggling sub-options.
                        if compactChromeiPhone {
                            Toggle(isOn: $hideFilterBarCompact) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hide Filter Bar")
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    Text("Removes the group pills strip above the channel list.")
                                        .font(.labelSmall)
                                        .foregroundColor(.textTertiary)
                                }
                            }
                            .tint(.accentPrimary)
                            .listRowBackground(Color.cardBackground)

                            Toggle(isOn: $hideSearchBarCompact) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hide Search Bar")
                                        .font(.bodyMedium)
                                        .foregroundColor(.textPrimary)
                                    Text("Replaces the always-visible search row with the nav-bar search icon.")
                                        .font(.labelSmall)
                                        .foregroundColor(.textTertiary)
                                }
                            }
                            .tint(.accentPrimary)
                            .listRowBackground(Color.cardBackground)
                        }
                    } header: {
                        Text("Experimental UI")
                            .sectionHeaderStyle()
                    } footer: {
                        Text(compactChromeiPhone
                             ? "Compact Chrome moves Manage Groups into the Live TV nav bar. The two toggles above let you further reclaim vertical space by hiding the filter pills and/or the search row. All three options revert instantly — no restart required."
                             : "Designed for iPhone landscape. When enabled, Manage Groups moves to the nav bar and two further toggles appear for hiding the filter pills and search row. Reverting restores the classic layout instantly."
                        )
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                        .padding(.top, 4)
                    }
                    #if os(iOS)
                    .listSectionSeparator(.hidden)
                    #endif
                }

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
                            // v1.7.x: poll the file size every 2s while the
                            // screen is up. Pre-fix this only refreshed inside
                            // .task(once-on-appear), so a user enabling
                            // logging and watching the row would see "Empty"
                            // until they backed out and re-entered Developer
                            // Settings. Now Empty -> 1 KB -> 5 KB updates
                            // live as the firehose lands in the file, which
                            // is the simplest possible signal that the write
                            // path is actually working.
                            TimelineView(.periodic(from: Date(), by: 2)) { _ in
                                Text(logSize)
                                    .font(.monoSmall)
                                    .foregroundColor(.textTertiary)
                                    .onAppear { refreshLogSize() }
                                    .onChange(of: Date().timeIntervalSinceReferenceDate) { _, _ in
                                        refreshLogSize()
                                    }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                        .task { refreshLogSize() }

                        // View
                        // v1.7.x: show this whenever Debug Logging is enabled
                        // OR the file already has bytes on disk. Pre-fix the
                        // guard was file-existence only, but the file is
                        // created lazily on the first write - so users who
                        // just toggled logging on, then opened this screen,
                        // saw no View / Share buttons until they triggered
                        // something log-worthy (a channel play). LogViewerView
                        // and the share path both handle empty content
                        // gracefully, so it is safe to surface the buttons
                        // immediately on enable.
                        if let url = logger.logFileURL,
                           (debugLoggingEnabled || FileManager.default.fileExists(atPath: url.path)) {
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
                        // (iOS) or a LAN HTTP server + QR sheet (tvOS). Same
                        // relaxed guard as View above so the button appears
                        // the moment Debug Logging is on, not after the
                        // first log flush.
                        if let url = logger.logFileURL,
                           (debugLoggingEnabled || FileManager.default.fileExists(atPath: url.path)) {
                            Button {
                                shareFile(url)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Share Log File")
                                            .font(.bodyMedium)
                                            .foregroundColor(.textPrimary)
                                        #if os(tvOS)
                                        // tvOS share sheet is AirDrop-only in
                                        // practice (Mail / Messages / third-
                                        // party apps are not on the platform),
                                        // so we say so up front instead of the
                                        // iOS-style "Email, Messages, ...".
                                        Text("Send via AirDrop to a nearby Mac or iPhone")
                                            .font(.labelSmall)
                                            .foregroundColor(.textTertiary)
                                        #else
                                        Text("Email, Messages, Discord, Signal…")
                                            .font(.labelSmall)
                                            .foregroundColor(.textTertiary)
                                        #endif
                                    }
                                } icon: {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundColor(.accentPrimary)
                                }
                            }
                            // v1.7.x: removed the platform-split buttonStyle.
                            // On tvOS the previous TVNoHighlightButtonStyle()
                            // returned only the label content with a focus-
                            // ring overlay - no card chrome, no padding - and
                            // in a List/Form row it rendered effectively
                            // invisible against the dark background until
                            // focused. The sibling View Log File button right
                            // above this one uses no buttonStyle at all and
                            // gets the default tvOS form-row chrome the user
                            // expects, so match that pattern exactly. iOS
                            // List handles the .plain treatment naturally too.
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

                // MARK: - Debug Logging Toggle
                // Relocated from the top of this screen to sit just
                // above "What's Captured" — that positioning makes
                // the toggle's effect self-documenting: you see the
                // toggle, immediately below you see "here's what
                // enabling it will log", and below that the log
                // file actions. Previously the toggle was at the
                // very top and the explainer + file actions were
                // buried several sections down, which made it
                // unclear to users what the toggle actually did.
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

                        // View / Share gate: surface when Debug Logging is
                        // enabled OR the file already has bytes, mirroring
                        // the iOSBody guard. Pre-fix this was file-existence
                        // only, so a user who just toggled logging on saw
                        // no rows until the first write landed.
                        if let url = logger.logFileURL,
                           (debugLoggingEnabled || FileManager.default.fileExists(atPath: url.path)) {
                            TVSettingsActionRow(
                                icon: "doc.text.magnifyingglass",
                                label: "View Log File",
                                isAccent: true,
                                action: { showLogViewer = true }
                            )
                            .sheet(isPresented: $showLogViewer) {
                                LogViewerView(url: url)
                            }

                            // v1.7.x: matching Share Log File row was missing
                            // from this body entirely - all prior iterations
                            // of the Share fix landed in iOSBody (line ~356)
                            // and the tvOS view never showed a Share entry.
                            // Wires through shareFile(url), which starts
                            // LogShareServer and presents TvOSLogShareSheet
                            // (URL + QR for the user's phone).
                            TVSettingsActionRow(
                                icon: "square.and.arrow.up",
                                label: "Share Log File",
                                isAccent: true,
                                action: { shareFile(url) }
                            )
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

    /// Present a UIActivityViewController with proper iPad popover anchoring
    /// (iOS) or a LAN HTTP server + QR sheet (tvOS).
    private func shareFile(_ url: URL) {
        // v1.7.x: ensure the file exists before we hand it to the share
        // path. Debug Logging is async-buffered, so the user can toggle
        // it on and immediately tap Share with the file not yet flushed
        // to disk. Create an empty placeholder so both iOS's
        // UIActivityViewController and the tvOS LAN server have a real
        // file URL to operate on. The next real log line appends as
        // usual.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        }
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

        #if os(tvOS)
        // tvOS does not have UIActivityViewController (no AirDrop API
        // exposed to apps), so we cannot present a system share sheet.
        // Instead we start a small HTTP server bound to the Apple TV's
        // LAN address that serves only this log file, and let the user
        // open the URL on their phone or Mac browser. The phone saves
        // the .txt and forwards it to us via email, Discord, etc.
        // No setup beyond "be on the same WiFi as the Apple TV".
        // The actual UI lives in TvOSLogShareSheet below; this just
        // flips the state that presents it.
        LogShareServer.shared.start(fileURL: url)
        showTvOSShareSheet = true
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

// MARK: - tvOS Log Share (LAN HTTP server + QR code)

#if os(tvOS)
/// One-shot local HTTP server used by tvOS Developer Settings to make
/// the debug log file reachable from a nearby phone or laptop on the
/// same WiFi. tvOS has no UIActivityViewController (AirDrop API is not
/// exposed there), so we expose the file ourselves on a random high
/// port for the duration of the share sheet and tear the server down
/// when the user dismisses.
///
/// Why a server rather than a one-shot URL: the user opens the URL on
/// a different device (their phone's Safari, or their Mac), the file
/// streams over the LAN to that device's Downloads folder, and they
/// forward it to us via Email, Messages, Discord, etc. No setup beyond
/// "be on the same WiFi as the Apple TV".
///
/// Privacy posture: the server binds to all interfaces but only on the
/// LAN segment the Apple TV is on, and only stays up while the share
/// sheet is presented (TvOSLogShareSheet.onDisappear calls stop). The
/// route /log.txt returns the file content; everything else returns
/// 404. The file content is the same already-sanitized log produced by
/// DebugLogger.shared (Xtream creds, api_key, JWT, etc. are scrubbed
/// before they ever hit the file).
@MainActor
final class LogShareServer: ObservableObject {
    static let shared = LogShareServer()

    /// http://<lan-ip>:<port>/log.txt once the listener is ready. nil
    /// until the listener picks an interface and port (typically within
    /// ~50 ms of start).
    @Published private(set) var shareURL: String?
    /// True while a server is bound. UI binds to this to render the
    /// "waiting" vs "ready" states distinctly.
    @Published private(set) var isRunning: Bool = false
    /// Set to a brief human-readable reason when start cannot bind a
    /// port at all (rare; typically only if the LAN is unreachable).
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var fileURL: URL?

    private init() {}

    func start(fileURL: URL) {
        stop()
        self.fileURL = fileURL
        do {
            let listener = try NWListener(using: NWParameters.tcp)
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                Task { @MainActor in self.handle(connection: conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port?.rawValue else { return }
                        let ip = Self.firstNonLoopbackIPv4() ?? "127.0.0.1"
                        self.shareURL = "http://\(ip):\(port)/log.txt"
                        self.isRunning = true
                    case .failed(let err):
                        self.lastError = err.localizedDescription
                        self.shareURL = nil
                        self.isRunning = false
                    case .cancelled:
                        self.shareURL = nil
                        self.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
            self.isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        fileURL = nil
        shareURL = nil
        isRunning = false
    }

    private func handle(connection conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { conn.cancel(); return }
                let path = Self.parseRequestPath(from: data)
                if path == "/log.txt" {
                    self.respondLogFile(on: conn)
                } else {
                    self.respondNotFound(on: conn)
                }
            }
        }
    }

    private func respondLogFile(on conn: NWConnection) {
        guard let fileURL, let body = try? Data(contentsOf: fileURL) else {
            respondNotFound(on: conn); return
        }
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nContent-Disposition: attachment; filename=\"aerio_debug_logs.txt\"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(headers.utf8); payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func respondNotFound(on conn: NWConnection) {
        let body = "Not Found"
        let headers = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(headers.utf8); payload.append(Data(body.utf8))
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func parseRequestPath(from data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard let lineEnd = text.range(of: "\r\n") else { return nil }
        let firstLine = text[..<lineEnd.lowerBound]
        let parts = firstLine.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let pathPart = parts[1]
        if let q = pathPart.firstIndex(of: "?") { return String(pathPart[..<q]) }
        return String(pathPart)
    }

    /// Walk the BSD interface list and return the first non-loopback
    /// IPv4 address. tvOS Apple TVs typically have a single en0; this
    /// returns its 192.168.x.x / 10.x.x.x / etc. address so the user
    /// can type it on their phone if the QR code is not convenient.
    private static func firstNonLoopbackIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard let addrRef = p.pointee.ifa_addr else { continue }
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  addrRef.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addrRef, socklen_t(addrRef.pointee.sa_len),
                           &hostBuf, socklen_t(hostBuf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                // v1.7.x: was String(cString: hostBuf) which Swift 6
                // deprecated. Truncate to the NUL terminator and decode
                // the leading bytes - getnameinfo writes a C-string into
                // the buffer so the NUL is present, never reading past
                // it. UInt8 reinterpret of CChar is safe (same width).
                let nulIndex = hostBuf.firstIndex(of: 0) ?? hostBuf.endIndex
                let bytes = hostBuf[..<nulIndex].map { UInt8(bitPattern: $0) }
                let host = String(decoding: bytes, as: UTF8.self)
                if !host.isEmpty, host != "127.0.0.1" { return host }
            }
        }
        return nil
    }

    /// Build a QR-code image for `string`. Used by TvOSLogShareSheet to
    /// render a code the user can scan with their phone camera. H-level
    /// error correction is generous for a TV that the user is viewing
    /// through a phone camera at an angle / through living-room lighting.
    static func qrCode(for string: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Full-screen sheet on tvOS that surfaces the LAN URL hosting the log
/// file along with a QR code the user scans on their phone. Drives
/// LogShareServer's lifecycle: starts when shown (via the caller's
/// shareFile flow), stops on dismiss.
struct TvOSLogShareSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var server = LogShareServer.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 32) {
                Text("Share Log File")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                Text("On your phone or laptop, open this URL or scan the QR code. The .txt file will download. Forward it to us via Email or Discord.")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)

                if let urlString = server.shareURL {
                    if let qr = LogShareServer.qrCode(for: urlString) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 360, height: 360)
                            .background(Color.white)
                            .padding(12)
                            .background(Color.white)
                    }
                    Text(urlString)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                    Text("Server stops when you close this screen. The Apple TV and your phone must be on the same WiFi.")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                } else if let err = server.lastError {
                    Label("Could not start LAN server: \(err)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.statusWarning)
                        .padding()
                } else {
                    ProgressView("Starting LAN server…")
                        .foregroundStyle(.white)
                        .padding()
                }

                Button {
                    isPresented = false
                } label: {
                    Text("Close")
                        .font(.system(size: 26, weight: .semibold))
                        .padding(.horizontal, 48)
                        .padding(.vertical, 16)
                }
                .padding(.top, 12)
            }
            .padding(48)
        }
        .onDisappear {
            // Stop the listener as soon as the user leaves the screen so
            // it never outlives the share UX. Idempotent.
            LogShareServer.shared.stop()
        }
    }
}
#endif

