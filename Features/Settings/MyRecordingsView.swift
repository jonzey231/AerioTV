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
    /// (title is shown in the chrome; URL drives MPV; headers are
    /// passed through to mpv's `http-header-fields` for server
    /// recordings whose endpoint requires the same auth as the
    /// rest of the Dispatcharr API. Local recordings pass `[:]`.
    struct PlayingRecording: Identifiable {
        let id: UUID
        let url: URL
        let title: String
        let headers: [String: String]
        /// True for an in-progress recording streamed over HLS: the
        /// player treats it as a growing DVR window (live-edge seek
        /// clamp + LIVE timeline affordance) rather than a fixed file.
        var isDVR: Bool = false
    }

    /// v1.6.10: Recordings are scoped to the currently-active playlist
    /// (server) so the user doesn't see Server B's Dispatcharr DVR
    /// queue while they're using Server A. Mirrors how Live TV /
    /// Channels / On Demand all key off `isActive`. If no server is
    /// active (e.g. fresh install, M3U-only), `currentServerID` is
    /// nil and the list shows nothing — the empty state then prompts
    /// the user to pick a server.
    private var currentServerID: String? {
        let active = servers.first(where: { $0.isActive }) ?? servers.first
        return active?.id.uuidString
    }

    /// Recordings tied to the currently-active server. Used as the
    /// source for every segment so the counts in the pill selector
    /// also reflect the per-server scope.
    ///
    /// A capture that is running RIGHT NOW is exempt from the per-server
    /// scope: a local recording keeps writing across a playlist switch, and
    /// filtering it out left the user with a DVR tab that showed nothing and
    /// no way to stop the capture. Membership comes from the coordinator's
    /// live session map rather than `status == .recording`, so a stale row
    /// left by a previous run (crash mid-capture) does not leak in here.
    private var visibleRecordings: [Recording] {
        func isCapturing(_ r: Recording) -> Bool { coordinator.activeSessions[r.id] != nil }
        guard let sid = currentServerID else { return allRecordings.filter(isCapturing) }
        return allRecordings.filter { $0.serverID == sid || isCapturing($0) }
    }

    /// Terminal states always belong in Completed regardless of the clock.
    private static let terminalStatuses: [RecordingStatus] =
        [.completed, .stopped, .interrupted, .failed, .cancelled]

    /// True when the recording's effective window is airing right now.
    ///
    /// Section assignment can't trust `status` alone for a recording of a
    /// currently-airing program: when we POST it to Dispatcharr the server
    /// returns `custom_properties.status == "scheduled"` for the first
    /// several seconds (its task scheduler hasn't transitioned the job to
    /// "recording" yet), so the row would sit in Scheduled until the next
    /// reconcile poll lands. Treating "now is inside [effectiveStart,
    /// effectiveEnd]" as actively-recording puts it under Recording
    /// immediately, independent of the server-side status lag, and matches
    /// what the user just did ("record this program that is on now").
    private func isAiringNow(_ r: Recording) -> Bool {
        let now = Date()
        return r.effectiveStart <= now && now < r.effectiveEnd
    }

    private var scheduled: [Recording] {
        visibleRecordings.filter {
            !Self.terminalStatuses.contains($0.status)
                && $0.status != .recording
                && !isAiringNow($0)
        }
    }

    private var recording: [Recording] {
        visibleRecordings.filter {
            !Self.terminalStatuses.contains($0.status)
                && ($0.status == .recording || isAiringNow($0))
        }
    }

    private var completed: [Recording] {
        visibleRecordings.filter { Self.terminalStatuses.contains($0.status) }
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
                            // v1.6.20: tap-to-play on completed rows.
                            // Long-press still surfaces the context
                            // menu (Play, Stop / Cancel, Delete,
                            // Download; whatever applies to the
                            // row's status). `.contextMenu` keeps
                            // working alongside the tap gesture.
                            // In-progress and scheduled rows do
                            // nothing on tap because `playIfCompleted`
                            // gates on `isCompleted || stopped`.
                            // `contentShape(.rectangle)` makes the
                            // whole row the tap target so users
                            // don't have to land on the title text.
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playIfCompleted(rec)
                            }
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
                headers: item.headers,
                isLive: false,
                isDVR: item.isDVR
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

    /// Reconciles the **currently-active** server's Dispatcharr
    /// recordings. v1.6.10: previously walked every Dispatcharr
    /// `serverID` in the local DB and pinged each one — which spent
    /// bandwidth (and Dispatcharr quota) keeping data fresh for
    /// servers the user wasn't even viewing. Now scoped to the
    /// active server, matching the per-playlist visibility filter
    /// in `visibleRecordings`. When the user switches active server,
    /// the next `.task { await reconcileAll() }` invocation catches
    /// that server up.
    private func reconcileAll() async {
        guard let active = servers.first(where: { $0.isActive }) ?? servers.first,
              active.type == .dispatcharrAPI else { return }
        let api = DispatcharrAPI(baseURL: active.effectiveBaseURL,
                                 auth: .apiKey(active.effectiveApiKey),
                                 userAgent: active.effectiveUserAgent,
                                 authMode: active.dispatcharrHeaderMode)
        await coordinator.reconcileDispatcharrRecordings(
            api: api,
            serverID: active.id.uuidString,
            modelContext: modelContext
        )
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
            // v1.6.22: Dispatcharr's new DVR pipeline serves an HLS
            // playlist for in-progress recordings via
            // `/api/channels/recordings/<id>/hls/index.m3u8`. When
            // the server emitted that URL into custom_properties.file_url
            // (which we mirror to `rec.dispatcharrFileURL`), expose
            // a "Watch Live" action so the user can play the
            // recording as it captures. Older Dispatcharr builds
            // without this pipeline don't populate the URL, so the
            // button stays hidden for them.
            if rec.destination == .dispatcharrServer,
               rec.dispatcharrFileURL != nil,
               rec.remoteRecordingID != nil {
                // Row tap now starts from the beginning; this menu leads with
                // jumping to the live edge instead (matches Android's
                // "Start at Live").
                Button {
                    playServerRecording(rec)
                } label: {
                    Label("Start at Live", systemImage: "play.fill")
                }
                // Issue #29: play the in-progress recording from the start
                // (the /file/ partial) rather than the live edge.
                Button {
                    playServerRecording(rec, fromStart: true)
                } label: {
                    Label("Watch from Beginning", systemImage: "backward.end.fill")
                }
            }
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
                              userAgent: server.effectiveUserAgent,
                              authMode: server.dispatcharrHeaderMode)
    }

    /// tvOS-only: tapping a row plays it without requiring the
    /// context menu. v1.6.22: in-progress Dispatcharr-server
    /// recordings are now playable via the server's new HLS DVR
    /// pipeline (`/api/channels/recordings/<id>/hls/index.m3u8`),
    /// so a row whose status is `.recording` can also tap-to-play
    /// as long as the server emitted `custom_properties.file_url`
    /// in the recording metadata (we read it into
    /// `rec.dispatcharrFileURL`). Local in-progress recordings
    /// can't play yet (the file is open by `LocalRecordingSession`
    /// and reading it concurrently is fragile). Scheduled rows
    /// still no-op on tap; the user uses the context menu to
    /// cancel them.
    private func playIfCompleted(_ rec: Recording) {
        let canPlay: Bool
        if rec.isCompleted || rec.status == .stopped {
            canPlay = true
        } else if rec.status == .recording,
                  rec.destination == .dispatcharrServer,
                  rec.dispatcharrFileURL != nil {
            canPlay = true
        } else {
            canPlay = false
        }
        guard canPlay else { return }
        if rec.destination == .local, let path = rec.localFilePath {
            playRecording(rec, path: path)
        } else if rec.destination == .dispatcharrServer, rec.remoteRecordingID != nil {
            // Android parity: tapping an in-progress recording starts it FROM
            // THE BEGINNING (not the live edge). Completed rows already play
            // from the start of the file, so fromStart only matters here for
            // the in-progress HLS route (emits X-Aerio-Start-From-Beginning).
            playServerRecording(rec, fromStart: rec.isInProgress)
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
        // v1.6.18 — tear down any active live stream before mounting
        // the recording's fullScreenCover. The MainTabView-level
        // player overlay persists across tab navigation (so a
        // minimized live channel keeps playing while the user is
        // in DVR), and fullScreenCover layers on top WITHOUT
        // unmounting underneath. Without this stop() call, the
        // live mpv keeps decoding audio while the recording's mpv
        // also produces audio — two simultaneous streams. User
        // report (NicolaiVdS, Apple TV): "audio is recording AND
        // live channel". Stop() clears playingItem → SwiftUI
        // unmounts the live PlayerView → coordinator.stop() runs
        // → mpv quit. The 0.5s mpv_terminate_destroy delay
        // overlaps briefly with the recording's mpv spin-up but
        // the live mpv stops decoding on `quit` command before
        // the destroy fires, so audible overlap is sub-second.
        //
        // v1.6.23 — multiview-aware fix: see VODDetailView.swift for
        // the full rationale. `NowPlayingManager.stop()` alone leaves
        // multiview tiles + their mpv coordinators alive; route
        // through `PlayerSession.shared.exit()` so the tile store is
        // reset and mode flips to `.idle`.
        PlayerSession.shared.exit()
        playingRecording = PlayingRecording(
            id: rec.id, url: url, title: rec.programTitle, headers: [:]
        )
    }

    /// v1.6.8 (B2-partial), evolved in v1.6.22: plays a Dispatcharr
    /// server recording (completed OR in-progress).
    ///
    /// URL strategy:
    ///   1. Prefer `rec.dispatcharrFileURL`: the server-provided
    ///      `custom_properties.file_url` field. For completed
    ///      recordings this is `/api/channels/recordings/<id>/file/`
    ///      (raw media file). For in-progress recordings on
    ///      Dispatcharr's new DVR pipeline it's
    ///      `/api/channels/recordings/<id>/hls/index.m3u8`
    ///      (HLS playlist that lets mpv watch the recording while
    ///      it's still being captured).
    ///   2. Fall back to the constructed `/file/` URL on older
    ///      Dispatcharr builds that don't emit `file_url`. Those
    ///      builds also don't have the HLS pipeline, so the only
    ///      playable recordings on them are completed ones, and
    ///      `/file/` is correct.
    ///
    /// Auth headers: the `/file/` endpoint was historically AllowAny
    /// but v1.6.20 found a deployment that tightened it to require
    /// the per-server auth shape. The new `/hls/...` endpoint is
    /// JWT/ApiKey-required from day one. We always pass
    /// `server.authHeaders` (X-API-Key + UA, plus Authorization in
    /// `.both` mode) to mpv via `http-header-fields`; the segment
    /// fetches inside the HLS playlist also re-route through
    /// `/api/channels/recordings/<id>/hls/<segment>` so the same
    /// headers carry through.
    private func playServerRecording(_ rec: Recording, fromStart: Bool = false) {
        guard let server = servers.first(where: { $0.id.uuidString == rec.serverID }),
              server.type == .dispatcharrAPI,
              let api = apiForRecording(rec),
              let remoteID = rec.remoteRecordingID else {
            debugLog("⚠️ Cannot play server recording. Missing server / api / remoteID for \(rec.programTitle)")
            return
        }
        // Prefer the server's reported file_url (HLS for in-progress,
        // direct file for completed). Fall back to the constructed
        // legacy /file/ URL for older builds.
        let url: URL
        let urlSource: String
        if let fileURL = rec.dispatcharrFileURL,
           !fileURL.isEmpty,
           let resolved = resolveRecordingURL(server: server, relative: fileURL) {
            url = resolved
            urlSource = fileURL.contains(".m3u8") ? "server-hls" : "server-file"
        } else if let fallback = api.recordingPlaybackURL(id: remoteID) {
            url = fallback
            urlSource = "legacy-file"
        } else {
            debugLog("⚠️ Cannot play server recording. URL construction failed for \(rec.programTitle)")
            return
        }
        // Issue #29: "Watch from Beginning" uses the same HLS URL as Watch
        // Live, but signals mpv (via a sentinel header that setupMPV consumes
        // and strips) to start at the first segment instead of the live edge.
        var headers = server.authHeaders
        if fromStart { headers["X-Aerio-Start-From-Beginning"] = "1" }
        let headerKeys = headers.keys.sorted().joined(separator: ",")
        let inProgressTag = (rec.status == .recording) ? " [IN-PROGRESS]" : ""
        debugLog("▶️ Play server recording\(inProgressTag): id=\(remoteID) url=\(DebugLogger.sanitize(url.absoluteString)) source=\(urlSource) headers=\(headerKeys)")
        // v1.6.18 — see `playRecording` above for the rationale.
        // Same fix shape: stop the live stream before mounting the
        // recording's fullScreenCover so two mpv instances aren't
        // both producing audio.
        // v1.6.23 — multiview-aware: route through PlayerSession.exit().
        PlayerSession.shared.exit()
        // An in-progress recording streamed over HLS is a growing DVR
        // window: drive the live-edge-aware timeline. Completed recordings
        // and the legacy /file/ fallback are fixed files (plain VOD).
        let isDVR = rec.isInProgress && urlSource == "server-hls"
        // COMPLETED recordings ride the AVPlayer VOD container (Logan
        // 2026-08-26): that path carries the 10s WatchProgress saver,
        // exact-position Back exit, resume, and iCloud sync - none of
        // which the legacy cover ever had for recordings. The vodID is
        // a dvr-scoped key so recording progress can never collide with
        // a movie's numeric id. In-progress recordings (growing HLS
        // window) keep the legacy DVR cover; beginVOD declining (engine
        // toggle off with mpv enabled) also falls through unchanged.
        // Both shapes now ride the AVPlayer container. In-progress
        // recordings (growing HLS window) go in as `.dvr` tiles: direct
        // AVPlayer HLS with the driver in DVR-window mode (growing
        // scrubber, live-edge default). resumePositionMs semantics for
        // DVR: 0 = explicit from-the-beginning seek, nil = live edge,
        // >2s = saved resume. beginVOD declining (engine toggle off with
        // mpv enabled) still falls through to the legacy cover unchanged.
        let dvrVodID = "dvr-\(remoteID)"
        let resume: Int32?
        if fromStart {
            resume = isDVR ? 0 : nil
        } else {
            resume = WatchProgressManager.getResumePosition(vodID: dvrVodID, serverID: rec.serverID)
        }
        // The from-beginning sentinel is an mpv-only in-process signal
        // (setupMPV consumes and strips it); the AVPlayer path would
        // send it to the server as a real header. The container gets
        // resumePositionMs == 0 instead.
        var containerHeaders = headers
        containerHeaders.removeValue(forKey: "X-Aerio-Start-From-Beginning")
        if PlayerSession.shared.beginVOD(
            title: rec.programTitle, streamURL: url, headers: containerHeaders,
            posterURL: nil, vodID: dvrVodID, serverID: rec.serverID,
            vodType: "recording", resumePositionMs: resume,
            kind: isDVR ? .dvr : .vod) {
            debugLog("▶️ \(isDVR ? "In-progress" : "Completed") recording via AVPlayer container: id=\(remoteID) resume=\(resume.map(String.init) ?? "none")ms")
            return
        }
        playingRecording = PlayingRecording(
            id: rec.id, url: url, title: rec.programTitle, headers: headers, isDVR: isDVR
        )
    }

    /// Resolves the server-provided `file_url` (which Dispatcharr
    /// emits as a relative path, e.g.
    /// `/api/channels/recordings/61/hls/index.m3u8`) against the
    /// active server's effective base URL. Some deployments emit
    /// an absolute URL already; `URL(string:relativeTo:)` handles
    /// both forms; an absolute string ignores the base, a relative
    /// one is anchored to it.
    private func resolveRecordingURL(server: ServerConnection, relative: String) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        let base = server.effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
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
            coordinator.refreshGuideRecordingMarkers(modelContext: modelContext)
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
    @Environment(\.modelContext) private var modelContext

    /// Genre tags pulled from the EPG cache for this recording's
    /// program, matched by server + title + air-window overlap (see
    /// `resolveEPGCategory`). Empty when no cached EPG row matches
    /// (e.g. an old completed recording whose programme rolled out of
    /// the current grid window); the synopsis above still renders.
    @State private var epgCategory: String = ""

    /// True when this row should advertise live in-progress playback.
    /// v1.6.23 (Codex UX P2): the row is already tappable to play
    /// (via `playIfCompleted` in the parent), but without a visible
    /// affordance most users assume in-progress recordings are
    /// stop-only. The pill below makes the capability discoverable.
    /// Gated on `dispatcharrFileURL != nil` because that's the
    /// signal the server has the new HLS DVR pipeline; older
    /// Dispatcharr builds without the pipeline can't serve
    /// in-progress playback so the pill stays hidden.
    private var canWatchLive: Bool {
        guard recording.status == .recording else { return false }
        guard recording.destination == .dispatcharrServer else { return false }
        return recording.dispatcharrFileURL != nil
    }

    /// Split the matched EPG `<category>` string on XMLTV's common
    /// separators into individual genre tokens for the pills.
    private var categoryTokens: [String] {
        let separators = CharacterSet(charactersIn: ",/;")
        return epgCategory
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One targeted fetch (limit 1) against the EPG cache to enrich the
    /// row with genre tags. Matched by `serverID` + exact `title` +
    /// air-window overlap rather than `channelID`, because a
    /// recording's `channelID` is the channel's display id while
    /// `EPGProgram.channelID` is the feed's tvg-id key (they differ for
    /// Dispatcharr, which carries a whole epgDataID/uuid bridge). Title
    /// + window is reliable enough for display and degrades gracefully:
    /// no match leaves `epgCategory` empty and no pills render.
    private func resolveEPGCategory() {
        guard epgCategory.isEmpty else { return }
        let title = recording.programTitle
        guard !title.isEmpty else { return }
        let sid = recording.serverID
        let start = recording.scheduledStart
        let end = recording.scheduledEnd
        var descriptor = FetchDescriptor<EPGProgram>(
            predicate: #Predicate<EPGProgram> { p in
                p.serverID == sid && p.title == title
                    && p.startTime < end && p.endTime > start
            }
        )
        descriptor.fetchLimit = 1
        if let match = try? modelContext.fetch(descriptor).first,
           !match.category.isEmpty {
            epgCategory = match.category
        }
    }

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

            // Full program synopsis. Frozen onto the recording at
            // schedule time (`Recording.programDescription`), so it
            // survives EPG cache rollover and shows on scheduled,
            // recording, AND completed rows alike. Hidden when the
            // source feed gave no description rather than showing an
            // empty gap.
            if !recording.programDescription.isEmpty {
                Text(recording.programDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            // Genre pills from the EPG, using the same palette as the
            // guide so the recording carries matching category context.
            if !categoryTokens.isEmpty {
                CategoryPillsLayout(spacing: 6) {
                    ForEach(categoryTokens, id: \.self) { token in
                        CategoryPill(rawToken: token)
                    }
                }
                .padding(.top, 2)
            }

            HStack(spacing: 8) {
                if recording.destination == .dispatcharrServer {
                    Label("Server", systemImage: "server.rack")
                        .font(.caption2)
                        .foregroundColor(.accentPrimary)
                } else {
                    Label("Local", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundColor(.green)
                }

                if canWatchLive {
                    // Row tap now starts from the beginning, so the pill no
                    // longer says "Watch Live" (that's the long-press menu's
                    // "Start at Live"). Keep the red in-progress tint.
                    Label("In Progress", systemImage: "record.circle")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.18))
                        .foregroundColor(.red)
                        .clipShape(Capsule())
                        .accessibilityHint("Tap to watch from the beginning; long-press for Start at Live, Stop, or Delete.")
                }
            }

            if let reason = recording.failureReason, recording.status == .failed {
                Text(reason)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .task(id: recording.id) { resolveEPGCategory() }
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
