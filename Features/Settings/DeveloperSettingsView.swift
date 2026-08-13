import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if os(tvOS)
import Network
import CoreImage
import CoreImage.CIFilterBuiltins
// HDR prototype (Phase 0, feature/hdr-metal): mpv renders straight into a
// CAMetalLayer via gpu-next/vulkan/MoltenVK instead of the production
// GLES-FBO-to-AVSampleBufferDisplayLayer path. tvOS-only, dev-gated.
import Libmpv
import QuartzCore
import AVFoundation
import CoreMedia
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
    /// Engine auto-detection, HLS arm. **Default ON** (matches
    /// PlaybackFeatureFlags.avPlayerForHLS absent-key-means-on): genuine
    /// HLS + natively-HLS-capable Dispatcharr servers ride AVPlayer; mpv
    /// stays the automatic fallback. The off switch remains for chasing
    /// AVPlayer-path regressions.
    @AppStorage("playback.avplayerHLS") private var avPlayerHLS = true
    /// Engine auto-detection, remux arm: raw MPEG-TS through the on-device
    /// TS-to-HLS remuxer into AVPlayer (H.264 + AC-3/AAC only; auto
    /// fallback to mpv otherwise). Still opt-in: background-audio +
    /// transition-restart caveats keep it below the default-on bar.
    @AppStorage("playback.avplayerRemuxTS") private var avPlayerRemuxTS = false

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
    /// HDR engine flag (tvOS only). When on, SOLO live playback renders
    /// through the Metal/MoltenVK gpu-next path with zero-copy
    /// videotoolbox decode, HDR passthrough, and an HDR10 display-mode
    /// switch on HDR sources. Multiview (2+ tiles), PiP, and CarPlay
    /// stay on the GLES engine. Read by MPVPlayerViewRepresentable.
    @AppStorage("playback.metalHDR") private var metalHDREngine = false
    /// HDR prototype cover. Non-nil = presenting, carrying the resolved
    /// stream URL for the requested channel number.
    @State private var metalHDRTestItem: MetalHDRTestItem?
    @State private var metalHDRTestError: String?
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
        .confirmationDialog("Delete All Logs?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Delete All Logs", role: .destructive) {
                logger.clearLogs()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshLogSize() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the current log file and any rotated archives. This cannot be undone.")
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
                                 ? "On: live playback uses the multiview engine. Required for the AVPlayer options below."
                                 : "Off: legacy single-stream player (mpv only, no AVPlayer or multiview)")
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
                    Text("mpv is the default engine and plays every live channel, including HEVC. The two AVPlayer options route specific stream types to Apple's native player; anything AVPlayer cannot render (such as HEVC inside MPEG-TS) automatically falls back to mpv, so turning them on never loses a channel. Unified Playback hosts all of this: a single tile mounts MultiviewContainerView from the first frame, so adding a second stream is seamless. Disable it only if you hit a unified-path regression; the legacy PlayerView covers single-stream playback but has no multiview, mini-player, or AVPlayer support. Live only (VOD always uses the legacy path). Restart playback for changes to take effect.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                        .padding(.top, 4)
                }
                #if os(iOS)
                .listSectionSeparator(.hidden)
                #endif

                // MARK: - AVPlayer for HLS (test branch)
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(avPlayerHLS
                                      ? Color.accentPrimary.opacity(0.18)
                                      : Color.elevatedBackground)
                                .frame(width: 36, height: 36)
                            Image(systemName: avPlayerHLS ? "play.tv.fill" : "play.tv")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(avPlayerHLS ? .accentPrimary : .textSecondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("AVPlayer for HLS Streams")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text(avPlayerHLS
                                 ? "On (default): HLS-capable channels auto-play on Apple's AVPlayer; everything else stays on mpv"
                                 : "Off: every channel uses the mpv engine")
                                .font(.labelSmall)
                                .foregroundColor(avPlayerHLS ? .accentPrimary : .textTertiary)
                        }

                        Spacer()

                        Toggle("", isOn: $avPlayerHLS)
                            .labelsHidden()
                            .tint(.accentPrimary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.cardBackground)

                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(avPlayerRemuxTS
                                      ? Color.accentPrimary.opacity(0.18)
                                      : Color.elevatedBackground)
                                .frame(width: 36, height: 36)
                            Image(systemName: avPlayerRemuxTS ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(avPlayerRemuxTS ? .accentPrimary : .textSecondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("AVPlayer Remux for TS Streams")
                                .font(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text(avPlayerRemuxTS
                                 ? "On: raw MPEG-TS remuxed to HLS for AVPlayer (HEVC/MPEG-2 fall back to mpv)"
                                 : "Off: raw TS channels use the mpv engine (the default)")
                                .font(.labelSmall)
                                .foregroundColor(avPlayerRemuxTS ? .accentPrimary : .textTertiary)
                        }

                        Spacer()

                        Toggle("", isOn: $avPlayerRemuxTS)
                            .labelsHidden()
                            .tint(.accentPrimary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("AVPlayer Engine (Test)")
                        .sectionHeaderStyle()
                } footer: {
                    Text("Experimental engine router: live channels whose URL is genuine HLS (.m3u8, typically Xtream Codes sources) play through Apple's native AVPlayer for true HDR/Dolby Vision output, Dolby Atmos passthrough, and AirPlay. Channels are presented in the system player without the app's custom chrome, channel flipping, or multiview. Raw MPEG-TS streams (Dispatcharr) are unaffected; AVPlayer cannot play them. Takes effect on the next channel start.")
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
                            Label("Delete All Logs", systemImage: "trash")
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
                SettingsSection("Logging", style: .plain) {
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

                SettingsSection("Experimental", style: .plain) {
                    TVSettingsToggleRow(
                        icon: unifiedPlayback ? "rectangle.stack.fill" : "rectangle.stack",
                        iconColor: unifiedPlayback ? .accentPrimary : .textSecondary,
                        title: "Unified Playback",
                        subtitle: unifiedPlayback
                            ? "On: required for the AVPlayer engines below; also enables multiview"
                            : "Off: legacy single-stream player (mpv only)",
                        isOn: $unifiedPlayback
                    ) { _ in }

                    TVSettingsToggleRow(
                        icon: avPlayerHLS ? "play.tv.fill" : "play.tv",
                        iconColor: avPlayerHLS ? .accentPrimary : .textSecondary,
                        title: "AVPlayer for HLS Streams",
                        subtitle: avPlayerHLS
                            ? "On: HLS channels play on Apple's AVPlayer (HEVC auto-falls back to mpv)"
                            : "Off: every channel uses the mpv engine (the default)",
                        isOn: $avPlayerHLS
                    ) { _ in }

                    TVSettingsToggleRow(
                        icon: avPlayerRemuxTS ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle",
                        iconColor: avPlayerRemuxTS ? .accentPrimary : .textSecondary,
                        title: "AVPlayer Remux for TS Streams",
                        subtitle: avPlayerRemuxTS
                            ? "On: raw MPEG-TS remuxed to HLS for AVPlayer (HEVC/MPEG-2 fall back to mpv)"
                            : "Off: raw TS channels use the mpv engine (the default)",
                        isOn: $avPlayerRemuxTS
                    ) { _ in }

                    TVSettingsToggleRow(
                        icon: metalHDREngine ? "sparkles.tv.fill" : "sparkles.tv",
                        iconColor: metalHDREngine ? .accentPrimary : .textSecondary,
                        title: "Metal HDR Engine",
                        subtitle: metalHDREngine
                            ? "On: solo live channels render HDR10 with zero-copy 4K decode"
                            : "Off: all channels use the standard engine (the default)",
                        isOn: $metalHDREngine
                    ) { _ in }

                    // Phase 0 HDR prototype: play channel 35 (UHD HDR test
                    // channel) through the Metal/MoltenVK render path with
                    // hwdec=videotoolbox (zero-copy) and
                    // target-colorspace-hint=yes. Diagnostic only; results
                    // land in the debug log as [METAL-HDR] lines.
                    TVSettingsActionRow(
                        icon: "tv.and.mediabox",
                        label: "Metal HDR Test (Channel 35)",
                        isAccent: true,
                        action: {
                            let channels = ChannelStore.shared.channels
                            if let ch = channels.first(where: { $0.number == "35" }),
                               let url = ch.streamURL ?? ch.streamURLs.first {
                                debugLog("[METAL-HDR] launching test ch=35 name=\(ch.name)")
                                metalHDRTestError = nil
                                metalHDRTestItem = MetalHDRTestItem(url: url)
                            } else {
                                metalHDRTestError = channels.isEmpty
                                    ? "Channels not loaded yet - open Live TV first."
                                    : "No channel numbered 35 in the active playlist."
                                debugLog("[METAL-HDR] launch failed: \(metalHDRTestError ?? "?")")
                            }
                        }
                    )
                    if let err = metalHDRTestError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                    }
                }

                if debugLoggingEnabled || (logger.logFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                    SettingsSection("Log File", style: .plain) {
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
                            label: "Delete All Logs",
                            isDestructive: true,
                            action: { showClearConfirmation = true }
                        )
                    }
                }

                SettingsSection("What's Captured", style: .plain) {
                    tvLogCategoryCard
                }
            }
            .padding(48)
        }
        .fullScreenCover(item: $metalHDRTestItem) { item in
            MetalHDRTestScreen(url: item.url)
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


// MARK: - Metal HDR Prototype (Phase 0, feature/hdr-metal, tvOS only)
//
// Answers ONE question: does tvOS pass mpv's HDR (PQ/BT.2020) output through
// a CAMetalLayer + MoltenVK swapchain correctly, with hwdec=videotoolbox in
// DIRECT (zero-copy) mode? Everything here is diagnostic scaffolding around
// that question; none of it is production plumbing. Recipe mirrors MPVKit's
// Demo-tvOS MPVMetalViewController (MPVKit 1.0.0 = mpv 0.41 + libplacebo
// 7.360.1 + MoltenVK 1.4).
//
// Verdict evidence, logged as [METAL-HDR] every 5s:
//   hwdec=videotoolbox (NOT -copy) -> zero-copy confirmed
//   gamma=pq primaries=bt.2020 sig-peak>1 -> HDR passthrough negotiated
//   frame-drop counters -> smoothness vs tonight's 44-71 drops/15s baseline
// Color CORRECTNESS still needs eyes on the TV (Logan's morning review).
#if os(tvOS)

struct MetalHDRTestItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// MoltenVK workaround: it momentarily forces drawableSize to 1x1 to
/// complete presentation; without this clamp the size can stick at 1x1
/// (black frame / flicker). See mpv PR #13651.
final class HDRTestMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

struct MetalHDRTestScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var hud: String = "starting..."

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalMPVTestHost(url: url) { line in
                hud = line
            }
            .ignoresSafeArea()

            // Stats HUD: small, top-left, updated from the poller. Play/Pause
            // toggles it so Logan can judge colors with a clean frame.
            Text(hud)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .padding(12)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct MetalMPVTestHost: UIViewControllerRepresentable {
    let url: URL
    let onStats: (String) -> Void

    func makeUIViewController(context: Context) -> MetalMPVTestViewController {
        let vc = MetalMPVTestViewController()
        vc.playURL = url
        vc.onStats = onStats
        return vc
    }

    func updateUIViewController(_ uiViewController: MetalMPVTestViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: MetalMPVTestViewController, coordinator: ()) {
        uiViewController.shutdown()
    }
}

/// mpv wakeup trampoline. File-scope so it carries NO actor isolation --
/// mpv invokes it from its core thread. It only bounces to drainEvents,
/// which itself just hops onto the event queue.
private func metalHDRTestWakeup(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let me = unsafeBitCast(ctx, to: MetalMPVTestViewController.self)
    me.drainEvents()
}

final class MetalMPVTestViewController: UIViewController {
    var playURL: URL?
    var onStats: ((String) -> Void)?

    private var metalLayer = HDRTestMetalLayer()
    // nonisolated(unsafe): read from the mpv wakeup callback (mpv's core
    // thread) via drainEvents. Written only on the main thread (setup +
    // shutdown); shutdown clears the wakeup callback before destroy so the
    // core thread never sees a dangling handle.
    private nonisolated(unsafe) var mpv: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "metal-hdr-test.mpv", qos: .userInitiated)
    private var statsTimer: Timer?
    private var statsTick = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)

        setupMpv()
        if let url = playURL {
            command("loadfile", args: [url.absoluteString, "replace"])
        }
        startStatsPoller()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestHDRDisplayMode()
    }

    /// Round 2: ask tvOS to switch the HDMI output to HDR10 @ 50Hz via the
    /// public AVDisplayCriteria init (tvOS 17+). Without this the ATV stays
    /// in its UI mode (SDR 4K60) and the TV never sees HDR - confirmed by
    /// Logan's Hisense info panel on the first run. Honored only when the
    /// user's Match Dynamic Range / Match Frame Rate settings are on.
    private func requestHDRDisplayMode() {
        guard let window = view.window else {
            debugLog("[METAL-HDR] no window; cannot request HDR mode")
            return
        }
        let displayManager = window.avDisplayManager
        var formatDesc: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        ]
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let formatDesc else {
            debugLog("[METAL-HDR] CMVideoFormatDescriptionCreate failed: \(status)")
            return
        }
        let criteria = AVDisplayCriteria(refreshRate: 50.0, formatDescription: formatDesc)
        displayManager.preferredDisplayCriteria = criteria
        debugLog("[METAL-HDR] preferredDisplayCriteria set: HEVC 3840x2160 bt.2020/PQ @ 50Hz (displayModeSwitchInProgress=\(displayManager.isDisplayModeSwitchInProgress))")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
    }

    private func setupMpv() {
        guard let handle = mpv_create() else {
            debugLog("[METAL-HDR] mpv_create FAILED")
            return
        }
        mpv = handle

        // Route mpv warnings+errors into the debug log (info+ is too chatty).
        mpv_request_log_messages(handle, "warn")

        // The load-bearing options. wid = the CAMetalLayer: MPV_FORMAT_INT64
        // reads the pointer value out of the reference var, exactly like the
        // MPVKit demo does.
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &metalLayer), "wid")
        check(mpv_set_option_string(handle, "vo", "gpu-next"), "vo")
        check(mpv_set_option_string(handle, "gpu-api", "vulkan"), "gpu-api")
        check(mpv_set_option_string(handle, "gpu-context", "moltenvk"), "gpu-context")
        check(mpv_set_option_string(handle, "hwdec", "videotoolbox"), "hwdec")
        // HDR passthrough. MUST be set pre-init; cannot be toggled at runtime.
        check(mpv_set_option_string(handle, "target-colorspace-hint", "yes"), "target-colorspace-hint")

        // Live-TS niceties borrowed from the production engine, kept minimal.
        mpv_set_option_string(handle, "video-rotate", "no")
        mpv_set_option_string(handle, "cache", "yes")
        mpv_set_option_string(handle, "demuxer-max-bytes", "64MiB")
        mpv_set_option_string(handle, "demuxer-max-back-bytes", "16MiB")
        mpv_set_option_string(handle, "user-agent", "AerioTV")

        check(mpv_initialize(handle), "initialize")

        // The callback MUST be a file-scope function: a closure literal here
        // inherits the class's MainActor isolation, and Swift 6's dynamic
        // isolation check SIGTRAPs the instant mpv's core thread enters it
        // (crash #2 of this prototype; crash #1 was the same check on
        // drainEvents itself).
        mpv_set_wakeup_callback(handle, metalHDRTestWakeup, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        debugLog("[METAL-HDR] mpv initialized: vo=gpu-next gpu-api=vulkan gpu-context=moltenvk hwdec=videotoolbox target-colorspace-hint=yes")
    }

    /// Idempotent teardown. Called from SwiftUI dismantle and deinit.
    func shutdown() {
        statsTimer?.invalidate()
        statsTimer = nil
        // Release the display-mode request so the ATV returns to its UI
        // mode after the test. isViewLoaded guard: shutdown is also called
        // from deinit, where touching `view` could force-load it.
        if isViewLoaded, let window = view.window {
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
        guard let handle = mpv else { return }
        mpv = nil
        // Clear the wakeup callback before destroy so a late wakeup can't
        // touch a deallocating self (we're passed unretained).
        mpv_set_wakeup_callback(handle, nil, nil)
        eventQueue.async {
            mpv_terminate_destroy(handle)
            debugLog("[METAL-HDR] mpv destroyed")
        }
    }

    deinit {
        shutdown()
    }

    // MARK: Stats

    private func startStatsPoller() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
    }

    private func pollStats() {
        guard let handle = mpv else { return }
        statsTick += 1

        let hwdec = getString(handle, "hwdec-current") ?? "-"
        let pixfmt = getString(handle, "video-params/pixelformat") ?? "-"
        let primaries = getString(handle, "video-params/primaries") ?? "-"
        let gamma = getString(handle, "video-params/gamma") ?? "-"
        let sigPeak = getDouble(handle, "video-params/sig-peak")
        let w = getInt(handle, "video-params/w")
        let h = getInt(handle, "video-params/h")
        let fps = getDouble(handle, "container-fps")
        let voDrops = getInt(handle, "frame-drop-count")
        let decDrops = getInt(handle, "decoder-frame-drop-count")
        let cacheSecs = getDouble(handle, "demuxer-cache-duration")

        let hud = String(
            format: "%dx%d %@ %.5g fps | hwdec=%@ | %@ / %@ peak=%.5g\nvo-drops=%d dec-drops=%d cache=%.1fs",
            w, h, pixfmt, fps, hwdec, primaries, gamma, sigPeak, voDrops, decDrops, cacheSecs
        )
        onStats?(hud)

        // Log a durable evidence line every 5s.
        if statsTick % 5 == 0 {
            debugLog("[METAL-HDR] t=\(statsTick)s res=\(w)x\(h) fmt=\(pixfmt) fps=\(fps) hwdec=\(hwdec) primaries=\(primaries) gamma=\(gamma) sig-peak=\(sigPeak) vo-drops=\(voDrops) dec-drops=\(decDrops) cache=\(String(format: "%.1f", cacheSecs))s")
        }
    }

    // MARK: mpv plumbing

    // nonisolated: invoked from mpv's wakeup callback on mpv's core thread.
    // The Swift 6 dynamic isolation check SIGTRAPs if this is left implicitly
    // MainActor (UIViewController inference) - that was the first on-device
    // crash of this prototype. All it does is hop to eventQueue.
    fileprivate nonisolated func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while let handle = self.mpv {
                guard let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE else { break }
                switch event.pointee.event_id {
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data))?.pointee {
                        let prefix = String(cString: msg.prefix)
                        let text = String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        debugLog("[METAL-HDR][mpv \(prefix)] \(text)")
                    }
                case MPV_EVENT_END_FILE:
                    debugLog("[METAL-HDR] end-file event")
                default:
                    break
                }
            }
        }
    }

    private func command(_ name: String, args: [String]) {
        guard let handle = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = ([name] + args).map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        check(mpv_command(handle, &cargs), "command \(name)")
    }

    private func check(_ status: CInt, _ what: String) {
        if status < 0 {
            debugLog("[METAL-HDR] mpv error on \(what): \(String(cString: mpv_error_string(status)))")
        }
    }

    private func getString(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    private func getDouble(_ handle: OpaquePointer, _ name: String) -> Double {
        var v = Double()
        mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v)
        return v
    }

    private func getInt(_ handle: OpaquePointer, _ name: String) -> Int {
        var v = Int64()
        mpv_get_property(handle, name, MPV_FORMAT_INT64, &v)
        return Int(v)
    }
}
#endif

// MARK: - Metal HDR autorun (headless driving via devicectl)
//
// Push an empty marker file to Library/Caches/metal_hdr_autorun in the app
// container (devicectl device copy to --domain-type appDataContainer), then
// launch with --terminate-existing. On launch this waits for the channel
// list, presents MetalHDRTestScreen full-screen for `runSeconds`, then
// dismisses itself. Single-shot: the marker is deleted on pickup, so the
// next normal launch is unaffected. Debug builds only (call site is
// #if DEBUG gated in AerioApp).
#if os(tvOS)
enum MetalHDRAutoRun {
    static let runSeconds: TimeInterval = 180
    static let channelNumber = "35"

    static func checkAndRun() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        // Two marker flavors:
        //   metal_hdr_autorun      - present the isolated Metal test screen
        //   metal_hdr_tune         - tune channel 35 through the REAL player
        //                            (same notification the aerio://channel
        //                            deep link posts), exercising the
        //                            production engine path end to end
        let testMarker = caches.appendingPathComponent("metal_hdr_autorun")
        let tuneMarker = caches.appendingPathComponent("metal_hdr_tune")
        let tuneMode = FileManager.default.fileExists(atPath: tuneMarker.path)
        guard tuneMode || FileManager.default.fileExists(atPath: testMarker.path) else { return }
        try? FileManager.default.removeItem(at: tuneMode ? tuneMarker : testMarker)
        debugLog("[METAL-HDR] autorun marker found (mode=\(tuneMode ? "tune" : "test")); waiting for channel \(channelNumber)")

        Task { @MainActor in
            for tick in 0..<120 {
                if let ch = ChannelStore.shared.channels.first(where: { $0.number == channelNumber }) {
                    if tuneMode {
                        // The tune marker exists to exercise the flag-gated
                        // production engine headlessly, so it enables the
                        // flag too (debug builds only; the toggle in this
                        // screen is the user-facing switch).
                        UserDefaults.standard.set(true, forKey: "playback.metalHDR")
                        debugLog("[METAL-HDR] autorun: production tune after \(tick)s, ch=\(channelNumber) id=\(ch.id) name=\(ch.name)")
                        NotificationCenter.default.post(
                            name: .aerioOpenChannel,
                            object: nil,
                            userInfo: ["channelID": ch.id]
                        )
                        return
                    }
                    if let url = ch.streamURL ?? ch.streamURLs.first {
                        debugLog("[METAL-HDR] autorun: presenting after \(tick)s, ch=\(channelNumber) name=\(ch.name)")
                        present(url: url)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            debugLog("[METAL-HDR] autorun: channel \(channelNumber) never appeared in 120s; giving up")
        }
    }

    @MainActor
    private static func present(url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else {
            debugLog("[METAL-HDR] autorun: no root view controller; aborting")
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }

        let host = UIHostingController(rootView: MetalHDRTestScreen(url: url))
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: false)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(runSeconds) * 1_000_000_000)
            debugLog("[METAL-HDR] autorun: \(Int(runSeconds))s window complete; dismissing")
            host.dismiss(animated: false)
        }
    }
}
#endif
