import SwiftUI
import SwiftData

// MARK: - My Recordings

struct MyRecordingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var allRecordings: [Recording]
    @Query private var servers: [ServerConnection]
    @StateObject private var coordinator = RecordingCoordinator.shared
    /// See SettingsView. Re-renders on theme change so segmented
    /// control + status pills + accent-tinted action buttons reflect
    /// the active theme.
    @ObservedObject private var theme = ThemeManager.shared

    @State private var selectedSegment = 0 // 0=Scheduled, 1=Recording, 2=Completed
    @State private var recordingToDelete: Recording?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFromServerAlert = false
    @State private var showDownloadConfirmation = false

    // v1.6.8 (B1 Phase 1 / B2-partial): full-screen player
    // presentation for completed recordings. Both local and
    // Dispatcharr server playback land here — local recordings
    // resolve to a `file://` URL pointing into
    // `Documents/Recordings/`, server recordings to the
    // Dispatcharr `/api/channels/recordings/<id>/file/` endpoint
    // (which is `AllowAny` per `recordingPlaybackURL` doc, so
    // no auth headers needed). One state variable drives both —
    // the URL is enough for `PlayerView` to set up MPV.
    @State private var playingRecording: PlayingRecording? = nil

    /// Identifiable wrapper used by `.fullScreenCover(item:)`. Holds
    /// just enough metadata for `PlayerView` to render a recording
    /// (title is shown in the chrome; URL drives MPV).
    struct PlayingRecording: Identifiable {
        let id: UUID
        let url: URL
        let title: String
    }

    private var scheduled: [Recording] {
        allRecordings.filter { $0.status == .scheduled }
    }

    private var recording: [Recording] {
        allRecordings.filter { $0.status == .recording }
    }

    private var completed: [Recording] {
        allRecordings.filter { [.completed, .stopped, .interrupted, .failed, .cancelled].contains($0.status) }
    }

    private var activeList: [Recording] {
        switch selectedSegment {
        case 0: return scheduled
        case 1: return recording
        default: return completed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Same pill selector on both platforms. On tvOS the pills
            // are focusable; on iOS they're plain tap buttons.
            HStack(spacing: 12) {
                segmentButton("Scheduled", count: scheduled.count, tag: 0)
                segmentButton("Recording", count: recording.count, tag: 1)
                segmentButton("Completed", count: completed.count, tag: 2)
                Spacer()
            }
            .padding()

            // Quota warning toast
            if coordinator.isApproachingQuotaLimit && selectedSegment != 2 {
                quotaWarningBanner
            }

            // Failed recordings toast
            if selectedSegment == 2 && completed.contains(where: { $0.status == .failed }) {
                failedRecordingsBanner
            }

            if activeList.isEmpty {
                emptyState
            } else {
                #if os(tvOS)
                // tvOS: List + Button + .buttonStyle(.plain) still paints the
                // giant system white focus halo. Replace with ScrollView +
                // LazyVStack + TVRecordingRow, which uses the same subtle
                // focus treatment (accent stroke + scale bump) as the rest
                // of the tvOS UI. Context menu comes through as a
                // .confirmationDialog triggered by .onLongPressGesture —
                // same pattern used in the EPG guide.
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(activeList, id: \.id) { rec in
                            TVRecordingRow(
                                recording: rec,
                                onSelect: { playIfCompleted(rec) },
                                menu: { contextMenuItems(for: rec) }
                            )
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 20)
                }
                .background(Color.appBackground)
                #else
                List {
                    ForEach(activeList, id: \.id) { rec in
                        RecordingRow(recording: rec)
                            .listRowBackground(Color.cardBackground)
                            .contextMenu {
                                contextMenuItems(for: rec)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                swipeActions(for: rec)
                            }
                    }
                }
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
                .background(Color.appBackground)
                #endif
            }
        }
        .background(Color.appBackground)
        .navigationTitle("My Recordings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Delete Recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { deleteRecording(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rec = recordingToDelete, !rec.programTitle.isEmpty {
                Text("\u{201C}\(rec.programTitle)\u{201D} will be permanently deleted from your device.")
            } else {
                Text("This will permanently delete this recording from your device.")
            }
        }
        .alert("Delete from Server?", isPresented: $showDeleteFromServerAlert) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { deleteFromServer(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rec = recordingToDelete, !rec.programTitle.isEmpty {
                Text("\u{201C}\(rec.programTitle)\u{201D} will be permanently deleted from the Dispatcharr server.")
            } else {
                Text("This will permanently delete this recording from the Dispatcharr server. The file on the server will be removed.")
            }
        }
        .alert("Save to Device?", isPresented: $showDownloadConfirmation) {
            Button("Save") {
                if let rec = recordingToDelete { downloadRecording(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download this recording from the Dispatcharr server to your device's local storage.")
        }
        // v1.6.8 (B1 Phase 1 / B2-partial): completed recording
        // playback. Both local (`file://...`) and server
        // (Dispatcharr `/api/channels/recordings/<id>/file/`)
        // playback funnel through `playingRecording`. PlayerView is
        // told `isLive: false` so transport controls show
        // scrubbable seek instead of the live-edge UI; `urls` is
        // a single-element array because we only have one file
        // per recording (no failover candidates needed for
        // file-backed playback).
        .fullScreenCover(item: $playingRecording) { item in
            PlayerView(
                urls: [item.url],
                title: item.title,
                headers: [:],
                isLive: false
            )
        }
        // Pull Dispatcharr server state whenever the view shows, then
        // keep it honest on a 30s tick while visible. SwiftUI cancels the
        // task on view disappear so we don't burn network on inactive
        // tabs.
        .task {
            await reconcileAll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                await reconcileAll()
            }
        }
    }

    // MARK: - Reconcile

    /// Walks every distinct Dispatcharr `serverID` that appears in the
    /// local recording list and asks the coordinator to reconcile each.
    /// Handles the multi-server case (rare but supported).
    private func reconcileAll() async {
        let dispatcharrServerIDs = Set(
            allRecordings
                .filter { $0.destination == .dispatcharrServer }
                .map { $0.serverID }
        )
        for sid in dispatcharrServerIDs {
            guard let server = servers.first(where: { $0.id.uuidString == sid }),
                  server.type == .dispatcharrAPI else { continue }
            let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                     auth: .apiKey(server.effectiveApiKey),
                                     userAgent: server.effectiveUserAgent)
            await coordinator.reconcileDispatcharrRecordings(
                api: api,
                serverID: sid,
                modelContext: modelContext
            )
        }
    }

    // MARK: - Segment Button (shared iOS + tvOS)

    /// Pill-style segment selector used by both iOS and tvOS. Matches
    /// the Live TV group filter bar / On Demand tab pills so every
    /// in-tab segment selector in the app has identical styling.
    private func segmentButton(_ label: String, count: Int, tag: Int) -> some View {
        DVRSegmentPill(
            label: "\(label) (\(count))",
            isSelected: selectedSegment == tag,
            action: {
                withAnimation(.easeInOut(duration: 0.15)) { selectedSegment = tag }
            }
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for rec: Recording) -> some View {
        if rec.isCompleted || rec.status == .stopped {
            if rec.destination == .local, let path = rec.localFilePath {
                Button {
                    playRecording(rec, path: path)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
            }
            if rec.destination == .dispatcharrServer, let _ = rec.remoteRecordingID {
                Button {
                    playServerRecording(rec)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    recordingToDelete = rec
                    showDownloadConfirmation = true
                } label: {
                    Label("Save to Device", systemImage: "square.and.arrow.down")
                }
                // Post-recording comskip: offers to run commercial
                // detection/removal on the server even if the user
                // didn't toggle it at schedule time. The server
                // handles idempotency so repeated taps are safe.
                Button {
                    runComskip(rec)
                } label: {
                    Label("Remove Commercials", systemImage: "scissors")
                }
            }
        }

        if rec.isInProgress {
            Button {
                stopRecording(rec)
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
            }
        }

        if rec.isUpcoming {
            Button(role: .destructive) {
                cancelRecording(rec)
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        }

        // Delete actions
        if rec.destination == .local {
            Button(role: .destructive) {
                recordingToDelete = rec
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        if rec.destination == .dispatcharrServer {
            Button(role: .destructive) {
                recordingToDelete = rec
                showDeleteFromServerAlert = true
            } label: {
                Label("Delete from Server", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func swipeActions(for rec: Recording) -> some View {
        if rec.destination == .local {
            Button(role: .destructive) {
                recordingToDelete = rec
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        if rec.destination == .dispatcharrServer {
            Button(role: .destructive) {
                recordingToDelete = rec
                showDeleteFromServerAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Banners

    private var quotaWarningBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text("Storage is approaching the limit. New recordings may not finish.")
                .font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.15))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    private var failedRecordingsBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
            Text("Some recordings failed. Long-press for details.")
                .font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.15))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No recordings")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Schedule a recording from the TV guide to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func apiForRecording(_ rec: Recording) -> DispatcharrAPI? {
        guard let server = servers.first(where: { $0.id.uuidString == rec.serverID }),
              server.type == .dispatcharrAPI else { return nil }
        return DispatcharrAPI(baseURL: server.effectiveBaseURL,
                              auth: .apiKey(server.effectiveApiKey),
                              userAgent: server.effectiveUserAgent)
    }

    /// tvOS-only: tapping a completed row plays it without requiring the
    /// context menu. In-progress/scheduled rows do nothing on tap —
    /// interaction goes through the context menu (Stop / Cancel).
    private func playIfCompleted(_ rec: Recording) {
        guard rec.isCompleted || rec.status == .stopped else { return }
        if rec.destination == .local, let path = rec.localFilePath {
            playRecording(rec, path: path)
        } else if rec.destination == .dispatcharrServer, rec.remoteRecordingID != nil {
            playServerRecording(rec)
        }
    }

    /// v1.6.8 (B1 Phase 1): plays a completed local recording from
    /// disk. The on-disk path is the absolute filesystem path
    /// written by `LocalRecordingSession`; we wrap it in a
    /// `file://` URL and hand it to `PlayerView` via the
    /// `playingRecording` state, which drives the
    /// `.fullScreenCover` below. No headers needed — MPV reads
    /// local files directly.
    private func playRecording(_ rec: Recording, path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            debugLog("⚠️ Local recording file missing on disk: \(path) — id=\(rec.id)")
            DebugLogger.shared.log(
                "Local recording file missing — \(rec.programTitle) at \(path)",
                category: "DVR", level: .warning)
            return
        }
        debugLog("▶️ Play local recording: \(path)")
        playingRecording = PlayingRecording(
            id: rec.id, url: url, title: rec.programTitle
        )
    }

    /// v1.6.8 (B2-partial): plays a completed Dispatcharr server
    /// recording. The `/api/channels/recordings/<id>/file/`
    /// endpoint is `AllowAny` (per `DispatcharrAPI.recordingPlaybackURL`
    /// docstring) and supports HTTP Range, so we hand the URL
    /// directly to `PlayerView` without auth headers.
    private func playServerRecording(_ rec: Recording) {
        guard let api = apiForRecording(rec),
              let remoteID = rec.remoteRecordingID,
              let url = api.recordingPlaybackURL(id: remoteID) else {
            debugLog("⚠️ Cannot play server recording — missing api / remoteID / URL for \(rec.programTitle)")
            return
        }
        debugLog("▶️ Play server recording: id=\(remoteID) url=\(url.absoluteString)")
        playingRecording = PlayingRecording(
            id: rec.id, url: url, title: rec.programTitle
        )
    }

    private func stopRecording(_ rec: Recording) {
        Task {
            if rec.destination == .local {
                await coordinator.stopLocalRecording(rec, modelContext: modelContext)
            } else if let api = apiForRecording(rec) {
                try? await coordinator.stopDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
            }
        }
    }

    private func cancelRecording(_ rec: Recording) {
        if rec.destination == .dispatcharrServer, let api = apiForRecording(rec) {
            Task {
                try? await coordinator.deleteDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
            }
        } else {
            rec.status = .cancelled
            try? modelContext.save()
        }
    }

    private func deleteRecording(_ rec: Recording) {
        coordinator.deleteLocalRecording(rec, modelContext: modelContext)
    }

    private func deleteFromServer(_ rec: Recording) {
        guard let api = apiForRecording(rec) else { return }
        Task {
            try? await coordinator.deleteDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
        }
    }

    private func downloadRecording(_ rec: Recording) {
        guard let api = apiForRecording(rec) else { return }
        Task {
            try? await coordinator.downloadDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
        }
    }

    /// Queues server-side comskip (commercial detection/removal) on a
    /// completed Dispatcharr recording. Fire-and-forget — the server
    /// processes in the background and updates its own state.
    private func runComskip(_ rec: Recording) {
        guard let api = apiForRecording(rec),
              let remoteID = rec.remoteRecordingID else { return }
        Task {
            do {
                try await api.applyComskip(id: remoteID)
                debugLog("✂️ Queued comskip for recording \(remoteID)")
            } catch {
                debugLog("⚠️ applyComskip failed for \(remoteID): \(error)")
            }
        }
    }
}

// MARK: - Recording Row

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.programTitle.isEmpty ? "Untitled" : recording.programTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }

            Text(recording.channelName)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack {
                Text(formatDateRange(recording.scheduledStart, recording.scheduledEnd))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if recording.preRollMinutes > 0 || recording.postRollMinutes > 0 {
                    Text("(\(bufferLabel))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if recording.destination == .dispatcharrServer {
                Label("Server", systemImage: "server.rack")
                    .font(.caption2)
                    .foregroundColor(.accentPrimary)
            } else {
                Label("Local", systemImage: "internaldrive")
                    .font(.caption2)
                    .foregroundColor(.green)
            }

            if let reason = recording.failureReason, recording.status == .failed {
                Text(reason)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        let (text, color) = statusInfo
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var statusInfo: (String, Color) {
        switch recording.status {
        case .scheduled: return ("Scheduled", .blue)
        case .recording: return ("Recording", .red)
        case .completed: return ("Completed", .green)
        case .stopped: return ("Stopped", .orange)
        case .interrupted: return ("Interrupted", .orange)
        case .failed: return ("Failed", .red)
        case .cancelled: return ("Cancelled", .secondary)
        }
    }

    private var bufferLabel: String {
        var parts: [String] = []
        if recording.preRollMinutes > 0 { parts.append("-\(recording.preRollMinutes)m") }
        if recording.postRollMinutes > 0 { parts.append("+\(recording.postRollMinutes)m") }
        return parts.joined(separator: " / ")
    }

    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let tf = DateFormatter()
        tf.timeStyle = .short
        return "\(df.string(from: start)) – \(tf.string(from: end))"
    }
}

// MARK: - tvOS Recording Row

#if os(tvOS)
/// Focusable DVR recording cell for the tvOS ScrollView. Mirrors the
/// rest of the tvOS UI's focus treatment (coloured stroke + small scale
/// bump on focus) instead of the giant white halo that List + Button
/// produced. Long-press opens a confirmationDialog of the same menu
/// items that iOS shows as a .contextMenu — the dialog avoids the
/// flashing / rebuilding issues that .contextMenu has on tvOS.
private struct TVRecordingRow<Menu: View>: View {
    let recording: Recording
    let onSelect: () -> Void
    @ViewBuilder let menu: () -> Menu

    // @State (not @FocusState): TVPressOverlay's transparent UIKit
    // overlay owns focus on tvOS; it reports focus changes back
    // through this binding via onFocusChange.
    @State private var isFocused: Bool = false
    @State private var showCtxDialog = false

    var body: some View {
        RecordingRow(recording: recording)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isFocused ? Color.accentPrimary : Color.clear, lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .overlay(
                TVPressOverlay(
                    minimumPressDuration: 0.35,
                    isFocused: $isFocused,
                    onTap: { onSelect() },
                    onLongPress: { showCtxDialog = true }
                )
            )
            .confirmationDialog(
                recording.programTitle.isEmpty ? "Recording" : recording.programTitle,
                isPresented: $showCtxDialog,
                titleVisibility: .visible
            ) {
                menu()
            }
    }
}
#endif

// MARK: - Segment Pill (shared iOS + tvOS)

/// Pill-style tab selector used by both the DVR tab (Scheduled /
/// Recording / Completed) and the On Demand tab (Movies / Series) so
/// every top-level in-tab segment selector in the app looks the same.
///
/// Rendering goes through a custom `ButtonStyle` that reads
/// `@Environment(\.isFocused)` directly — this is the only way on tvOS
/// to get the pill's custom focus treatment (accent stroke + scale)
/// WITHOUT the default system white halo and WITHOUT triggering the
/// `_UIReplicantView as a subview of UIHostingController.view`
/// warning that bare `.focusable() + .onTapGesture` produces.
///
/// Non-private so OnDemandView and other Settings/DVR callers can
/// reuse it.
struct DVRSegmentPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
        }
        .buttonStyle(DVRSegmentPillButtonStyle(isSelected: isSelected))
    }
}

// MARK: tvOS pill style — focusable, custom stroke, scale bump

#if os(tvOS)
private struct DVRSegmentPillButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .font(.system(size: 22, weight: .medium))
            .foregroundColor(
                isSelected ? .appBackground
                           : (focused ? .white : .textSecondary)
            )
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
            )
            .overlay(
                Capsule()
                    .stroke(focused && !isSelected ? Color.accentPrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .opacity(focused ? 1.0 : (isSelected ? 1.0 : 0.85))
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif

// MARK: iOS pill style — plain tappable capsule, no focus state

#if os(iOS)
private struct DVRSegmentPillButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(isSelected ? .appBackground : .textSecondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
#endif
