import SwiftUI
import SwiftData

// MARK: - PlayingRecording

/// Identifiable wrapper used by `.fullScreenCover(item:)` on the legacy
/// (mpv) cover. Holds just enough for `PlayerView` to render a recording:
/// title for the chrome, URL for the engine, auth headers for server
/// recordings (local recordings pass `[:]`).
struct PlayingRecording: Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let headers: [String: String]
    /// True for an in-progress recording streamed over HLS: the player
    /// treats it as a growing DVR window (live-edge seek clamp + LIVE
    /// timeline affordance) rather than a fixed file.
    var isDVR: Bool = false
    /// GH #75: WatchProgress identity + resume seed for the legacy (mpv)
    /// cover, so it saves and resumes exactly like the AVPlayer container.
    var vodID: String? = nil
    var serverID: String? = nil
    var resumePositionMs: Int32? = nil
}

// MARK: - RecordingActions

/// Every user action on a `Recording` (play, stop, cancel, delete,
/// download, comskip), shared by the DVR tab and the Settings list so the
/// two surfaces can never drift. Playback prefers the AVPlayer container
/// (`PlayerSession.beginVOD`); when it declines, the legacy cover is
/// mounted through `present`.
@MainActor
struct RecordingActions {
    let servers: [ServerConnection]
    let modelContext: ModelContext
    let coordinator: RecordingCoordinator
    /// Mounts the legacy (mpv) fullScreenCover.
    let present: (PlayingRecording) -> Void

    func server(for rec: Recording) -> ServerConnection? {
        servers.first(where: { $0.id.uuidString == rec.serverID })
    }

    /// Every server-side DVR mutation runs through here so a refusal can
    /// never be a silent no-op again. These calls used to be `try?`, so a
    /// denied delete looked exactly like a successful one: the row stayed,
    /// the user tapped again, nothing happened, nothing was logged.
    ///
    /// On 403 we re-probe the account's capabilities and then say either
    /// "your account cannot do this" or, when the permissions say it should
    /// have worked, that it looks like a network restriction on the account.
    /// On success we promote a capability we wrongly believed was denied.
    private func perform(_ capability: DispatcharrCapability,
                         on rec: Recording,
                         _ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
                if let server = server(for: rec) {
                    await DispatcharrCapabilityProbe.promoteIfUnexpectedlyAllowed(server, capability: capability)
                }
            } catch let APIError.forbidden(reason) {
                debugLog("⚠️ DVR \(capability.rawValue) refused (403): \(reason ?? "no reason given")")
                if let server = server(for: rec) {
                    await DispatcharrCapabilityProbe.handleForbidden(server,
                                                                     capability: capability,
                                                                     serverReason: reason)
                } else {
                    DispatcharrPermissionNotice.shared.present(capability.deniedMessage)
                }
            } catch APIError.unauthorized {
                debugLog("⚠️ DVR \(capability.rawValue) refused (401)")
                DispatcharrPermissionNotice.shared.present(
                    "AerioTV is not signed in to this Dispatcharr server any more. Open Settings > Playlists and run Test Connection.")
            } catch {
                debugLog("⚠️ DVR \(capability.rawValue) failed: \(error)")
                DispatcharrPermissionNotice.shared.present(
                    "That recording action failed: \(error.localizedDescription)")
            }
        }
    }

    func api(for rec: Recording) -> DispatcharrAPI? {
        guard let server = servers.first(where: { $0.id.uuidString == rec.serverID }),
              server.type == .dispatcharrAPI else { return nil }
        return DispatcharrAPI(baseURL: server.effectiveBaseURL,
                              auth: .apiKey(server.effectiveApiKey),
                              userAgent: server.effectiveUserAgent,
                              authMode: server.dispatcharrHeaderMode)
    }

    /// Completed and stopped recordings play; an in-progress
    /// Dispatcharr-server recording plays through the server's HLS DVR
    /// pipeline once it has emitted `custom_properties.file_url`. Local
    /// in-progress recordings cannot play yet (the file is open by
    /// `LocalRecordingSession`). Scheduled rows never play.
    func canPlay(_ rec: Recording) -> Bool {
        if rec.isCompleted || rec.status == .stopped { return true }
        if rec.status == .recording, rec.destination == .dispatcharrServer, rec.dispatcharrFileURL != nil {
            return true
        }
        return false
    }

    /// Tap / click: resume saved progress, else from the beginning.
    func play(_ rec: Recording) {
        guard canPlay(rec) else { return }
        if rec.destination == .local, let path = rec.localFilePath {
            playLocal(rec, path: path)
        } else if rec.destination == .dispatcharrServer, rec.remoteRecordingID != nil {
            playServer(rec)
        }
    }

    /// v1.6.8 (B1 Phase 1): plays a completed local recording from disk.
    func playLocal(_ rec: Recording, path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            debugLog("⚠️ Local recording file missing on disk: \(path) — id=\(rec.id)")
            DebugLogger.shared.log(
                "Local recording file missing — \(rec.programTitle) at \(path)",
                category: "DVR", level: .warning)
            return
        }
        debugLog("▶️ Play local recording: \(path)")
        // v1.6.18 / v1.6.23: tear down any live stream (and multiview
        // tiles) before mounting the recording so two engines never play
        // audio at once. See VODDetailView for the full rationale.
        PlayerSession.shared.exit()
        let vodID = rec.watchProgressID ?? "local-\(rec.id.uuidString)"
        let resume = WatchProgressManager.getResumePosition(vodID: vodID, serverID: rec.serverID)
        if !PlaybackFeatureFlags.mpvEngineEnabled {
            if PlayerSession.shared.beginVOD(
                title: rec.programTitle, streamURL: url, headers: [:],
                posterURL: nil, vodID: vodID, serverID: rec.serverID,
                vodType: "recording", resumePositionMs: resume) {
                debugLog("Local recording via AVPlayer container: \(rec.id) resume=\(resume.map(String.init) ?? "none")ms")
                return
            }
        }
        present(PlayingRecording(
            id: rec.id, url: url, title: rec.programTitle, headers: [:],
            vodID: vodID, serverID: rec.serverID, resumePositionMs: resume
        ))
    }

    /// Plays a Dispatcharr server recording (completed OR in-progress).
    ///
    /// URL: prefer `rec.dispatcharrFileURL` (the server's `file_url`:
    /// `/file/` for completed, `/hls/index.m3u8` for in-progress on the
    /// DVR pipeline), else the constructed legacy `/file/` URL. Auth
    /// headers always ride along (`/hls/` requires them from day one).
    ///
    /// resumePositionMs for a growing (DVR) window: 0 = from the
    /// beginning, nil = live edge, >2 s = saved resume.
    func playServer(_ rec: Recording, fromStart: Bool = false, liveEdge: Bool = false) {
        guard let server = servers.first(where: { $0.id.uuidString == rec.serverID }),
              server.type == .dispatcharrAPI,
              let api = api(for: rec),
              let remoteID = rec.remoteRecordingID else {
            debugLog("⚠️ Cannot play server recording. Missing server / api / remoteID for \(rec.programTitle)")
            return
        }
        let url: URL
        let urlSource: String
        if let fileURL = rec.dispatcharrFileURL,
           !fileURL.isEmpty,
           let resolved = Self.resolveRecordingURL(server: server, relative: fileURL) {
            url = resolved
            urlSource = fileURL.contains(".m3u8") ? "server-hls" : "server-file"
        } else if let fallback = api.recordingPlaybackURL(id: remoteID) {
            url = fallback
            urlSource = "legacy-file"
        } else {
            debugLog("⚠️ Cannot play server recording. URL construction failed for \(rec.programTitle)")
            return
        }
        // Issue #29: the from-beginning sentinel is an mpv-only in-process
        // signal (setupMPV consumes and strips it).
        var headers = server.authHeaders
        if fromStart { headers["X-Aerio-Start-From-Beginning"] = "1" }
        let headerKeys = headers.keys.sorted().joined(separator: ",")
        let inProgressTag = (rec.status == .recording) ? " [IN-PROGRESS]" : ""
        debugLog("▶️ Play server recording\(inProgressTag): id=\(remoteID) url=\(DebugLogger.sanitize(url.absoluteString)) source=\(urlSource) headers=\(headerKeys)")
        PlayerSession.shared.exit()
        let isDVR = rec.isInProgress && urlSource == "server-hls"
        let dvrVodID = rec.watchProgressID ?? "dvr-\(remoteID)"
        let resume: Int32?
        if fromStart {
            // Play from Beginning discards the saved position now, not at
            // exit: backing out inside the first two seconds saves nothing,
            // which left the old position for the next Resume (Logan
            // 2026-09-08, Suits). Same rule the local-file path applies.
            WatchProgressManager.delete(vodID: dvrVodID, serverID: rec.serverID)
            resume = isDVR ? 0 : nil
        } else if isDVR, liveEdge {
            resume = nil
        } else if isDVR {
            resume = WatchProgressManager.getResumePosition(vodID: dvrVodID, serverID: rec.serverID) ?? 0
        } else {
            resume = WatchProgressManager.getResumePosition(vodID: dvrVodID, serverID: rec.serverID)
        }
        var containerHeaders = headers
        containerHeaders.removeValue(forKey: "X-Aerio-Start-From-Beginning")
        if PlayerSession.shared.beginVOD(
            title: rec.programTitle, streamURL: url, headers: containerHeaders,
            posterURL: rec.posterURL.flatMap { URL(string: $0) },
            vodID: dvrVodID, serverID: rec.serverID,
            vodType: "recording", resumePositionMs: resume,
            kind: isDVR ? .dvr : .vod,
            dvrScheduledEnd: isDVR ? rec.effectiveEnd : nil,
            dvrChannelID: isDVR ? rec.channelID : nil) {
            debugLog("▶️ \(isDVR ? "In-progress" : "Completed") recording via AVPlayer container: id=\(remoteID) resume=\(resume.map(String.init) ?? "none")ms")
            return
        }
        present(PlayingRecording(
            id: rec.id, url: url, title: rec.programTitle, headers: headers, isDVR: isDVR,
            vodID: dvrVodID, serverID: rec.serverID,
            resumePositionMs: (resume ?? 0) > 0 ? resume : nil
        ))
    }

    /// Resolves the server-provided `file_url` (relative on Dispatcharr,
    /// absolute on some deployments) against the server's base URL.
    static func resolveRecordingURL(server: ServerConnection, relative: String) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        let base = server.effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    func stop(_ rec: Recording) {
        Task {
            if rec.destination == .local {
                await coordinator.stopLocalRecording(rec, modelContext: modelContext)
            } else if let api = api(for: rec) {
                perform(.manageDvr, on: rec) {
                    try await coordinator.stopDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
                }
            }
        }
    }

    func cancel(_ rec: Recording) {
        if rec.destination == .dispatcharrServer, let api = api(for: rec) {
            perform(.manageDvr, on: rec) {
                try await coordinator.deleteDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
            }
        } else {
            rec.status = .cancelled
            try? modelContext.save()
            coordinator.refreshGuideRecordingMarkers(modelContext: modelContext)
        }
    }

    func deleteLocal(_ rec: Recording) {
        coordinator.deleteLocalRecording(rec, modelContext: modelContext)
    }

    /// Dispatcharr 0.30 DVR access: stop / cancel / edit / delete on a
    /// SERVER recording need "manage". A local recording is this device's
    /// own file, so it is never gated.
    func canManage(_ rec: Recording) -> Bool {
        guard rec.destination == .dispatcharrServer, let server = server(for: rec) else { return true }
        return server.dispatcharrCanManageDVR
    }

    /// True when this row has bytes on THIS device: either a local
    /// recording, or a server recording that was saved to the device with
    /// "Save to Device" (which stamps `localFilePath` on the server row).
    func hasDeviceCopy(_ rec: Recording) -> Bool {
        guard let path = rec.localFilePath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Deletes only the on-device copy of a SERVER recording, leaving the
    /// server's recording (and this row) alone. Never touches the network,
    /// so it is available to every user whatever their DVR access.
    func deleteDeviceCopy(_ rec: Recording) {
        guard let path = rec.localFilePath else { return }
        try? FileManager.default.removeItem(atPath: path)
        rec.localFilePath = nil
        rec.fileSizeBytes = 0
        try? modelContext.save()
        debugLog("🗑️ Deleted device copy of recording \(rec.programTitle) at \(path)")
    }

    func deleteFromServer(_ rec: Recording) {
        guard let api = api(for: rec) else { return }
        perform(.manageDvr, on: rec) {
            try await coordinator.deleteDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
        }
    }

    func download(_ rec: Recording) {
        guard let api = api(for: rec) else { return }
        perform(.viewDvr, on: rec) {
            try await coordinator.downloadDispatcharrRecording(api: api, recording: rec, modelContext: modelContext)
        }
    }

    /// Queues server-side comskip on a completed Dispatcharr recording.
    func runComskip(_ rec: Recording) {
        guard let api = api(for: rec), let remoteID = rec.remoteRecordingID else { return }
        perform(.manageDvr, on: rec) {
            try await api.applyComskip(id: remoteID)
            debugLog("✂️ Queued comskip for recording \(remoteID)")
        }
    }
}
