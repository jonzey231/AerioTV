import Foundation
import SwiftData
import SwiftUI

/// Central coordinator for all DVR operations. Manages the lifecycle of
/// active local recordings, tracks storage quota, disables the idle timer
/// while recording, and bridges Dispatcharr server-side recordings via
/// the REST API.
///
/// There's exactly one instance for the lifetime of the app (the
/// `shared` singleton). UI layers observe it via `@Published` properties.
@MainActor
final class RecordingCoordinator: ObservableObject {
    static let shared = RecordingCoordinator()

    // MARK: - Published state

    /// Active local recording sessions keyed by `Recording.id`.
    @Published private(set) var activeSessions: [UUID: LocalRecordingSession] = [:]

    /// Pending auto-stop tasks keyed by `Recording.id`. Each sleeps until the
    /// recording's `effectiveEnd` and then stops it. Tracked (not fire-and-
    /// forget) so an early stop can cancel the pending task instead of leaving
    /// it sleeping for the rest of the scheduled duration, holding the
    /// `Recording` + `ModelContext` and later firing against removed state.
    private var autoStopTasks: [UUID: Task<Void, Never>] = [:]

    /// Whether any recording (local or server-side) is currently in progress.
    @Published private(set) var isRecording = false

    // MARK: - Quota

    /// Maximum local storage in bytes. Derived from UserDefaults
    /// `dvrMaxLocalStorageMB` (default 10 GB).
    var maxLocalStorageBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "dvrMaxLocalStorageMB")
        let effectiveMB = mb > 0 ? mb : 10_240 // 10 GB default
        return Int64(effectiveMB) * 1_048_576
    }

    /// Current disk usage of the local recordings directory.
    var localUsageBytes: Int64 {
        guard let dir = localRecordingsDirectory else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Fraction 0–1 of local storage used.
    var localUsageFraction: Double {
        let max = maxLocalStorageBytes
        guard max > 0 else { return 0 }
        return Double(localUsageBytes) / Double(max)
    }

    /// True when the user has consumed ≥80% of their local storage quota.
    var isApproachingQuotaLimit: Bool { localUsageFraction >= 0.80 }

    /// True when the user has consumed ≥100% of their local storage quota.
    var isQuotaExceeded: Bool { localUsageFraction >= 1.0 }

    // MARK: - Paths

    /// Default local recordings directory.
    ///
    /// iOS: `Documents/Recordings/` (user-visible in the Files app).
    ///
    /// tvOS: `Caches/Recordings/`. A physical Apple TV mounts BOTH the
    /// app's Documents directory AND Application Support read-only:
    /// Documents failed at file-create ("You don't have permission to
    /// save the file", 2026-06-05 ATV test), and mkdir under Application
    /// Support fails with NSCocoaError 513 / POSIX EPERM (2026-07-10
    /// device console, found via the identical Live Rewind failure; the
    /// SIMULATOR enforces neither, so only device runs catch this).
    /// Caches is the platform's only writable large-file location; the
    /// OS may purge it under pressure, which the DVR settings copy
    /// disclosed already - tvOS treats all app storage as purgeable.
    var localRecordingsDirectory: URL? {
        guard let dir = Self.defaultRecordingsDirectory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The default recordings folder in THIS install's container, without
    /// creating it. Stored recording locations are relative to it
    /// (RecordingPathRules), because the container's path can change
    /// between installs and updates.
    nonisolated static var defaultRecordingsDirectory: URL? {
        #if os(tvOS)
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        #else
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        #endif
        return base.appendingPathComponent(RecordingPathRules.folderName, isDirectory: true)
    }

    /// Launch, once per run: stored absolute paths into the default folder
    /// (this container's, or a previous one's with the file now here) become
    /// relative. Custom-folder paths are left as they are.
    nonisolated static func migrateStoredRecordingPaths(container: ModelContainer) {
        guard let root = defaultRecordingsDirectory?.path else { return }
        let ctx = ModelContext(container)
        let rows = (try? ctx.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.localFilePath != nil }))) ?? []
        var relative = 0, migrated = 0, reRooted = 0, kept = 0
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        for r in rows {
            guard let p = r.localFilePath, !p.isEmpty else { continue }
            if p.hasPrefix(RecordingPathRules.prefix) { relative += 1; continue }
            if let rel = RecordingPathRules.migrated(p, root: root, exists: exists) {
                if (p as NSString).deletingLastPathComponent != root { reRooted += 1 }
                r.localFilePath = rel
                migrated += 1
            } else {
                kept += 1
            }
        }
        if migrated > 0 { try? ctx.save() }
        if migrated > 0 || kept > 0 {
            debugLog("[DVR-PATHS] recording locations: \(migrated) made relative (\(reRooted) from a previous container), \(relative) already relative, \(kept) kept as stored (custom folder or file not here)")
        }
    }

    /// Launch, after the migration: every recording file in the default
    /// folder that no row points at (a row lost, or a file an older build
    /// left behind) becomes a row under "Saved on this device", so it can be
    /// played or deleted (owner 2026-11-13). Named from the file's dates.
    nonisolated static func adoptOrphanRecordingFiles(container: ModelContainer) {
        guard let dir = defaultRecordingsDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let ctx = ModelContext(container)
        let rows = (try? ctx.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.localFilePath != nil }))) ?? []
        let root = dir.path
        // The names rows point at in this folder (resolved, so an old
        // container's path counts by its file name here).
        let known = Set(rows.compactMap { r -> String? in
            guard let p = r.resolvedLocalFilePath else { return nil }
            return (p as NSString).deletingLastPathComponent == root ? (p as NSString).lastPathComponent : nil
        })
        let orphans = RecordingPathRules.orphans(files: names, known: known)
        guard !orphans.isEmpty else { return }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var adopted = 0
        for name in orphans {
            let path = (root as NSString).appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { continue }
            let modified = attrs[.modificationDate] as? Date ?? Date()
            let created = min(attrs[.creationDate] as? Date ?? modified, modified)
            let rec = Recording(channelID: "", channelName: "",
                                programTitle: "Recording from \(df.string(from: created))",
                                scheduledStart: created, scheduledEnd: modified,
                                destination: .local, status: .completed,
                                localFilePath: RecordingPathRules.stored(path, root: root),
                                fileSizeBytes: size,
                                serverID: PlaylistLockdown.savedOnDeviceServerID)
            rec.capturedStart = created
            rec.capturedSeconds = max(0, modified.timeIntervalSince(created))
            ctx.insert(rec)
            adopted += 1
        }
        guard adopted > 0 else { return }
        try? ctx.save()
        debugLog("[DVR-PATHS] adopted \(adopted) recording file(s) no row pointed at; they show under Saved on this device")
    }

    /// Custom folder URL from a security-scoped bookmark (iOS only). If
    /// nil, `localRecordingsDirectory` is used.
    var customRecordingsDirectory: URL? {
        #if os(tvOS)
        return nil // tvOS has no document picker / security-scoped bookmarks
        #else
        guard let data = UserDefaults.standard.data(forKey: "dvrCustomFolderBookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        if isStale { return nil }
        return url
        #endif
    }

    /// The effective output directory for a new local recording.
    var effectiveRecordingsDirectory: URL? {
        customRecordingsDirectory ?? localRecordingsDirectory
    }

    // MARK: - Guide recording markers (audit #50)

    /// One row per Scheduled/Recording entry, snapshotted for the guide's
    /// per-cell "set to record" dot. Cells read this directly -- the
    /// ReminderManager pattern: no per-cell observation, because with
    /// hundreds of visible cells a @Published invalidation on every
    /// reconcile would be a real re-render cost. The snapshot refreshes on
    /// every mutation path in this coordinator plus the guide's onAppear.
    struct GuideRecordingMarker: Equatable {
        let channelID: String
        /// Empty on rows imported from the server by reconcile.
        let channelName: String
        let title: String
        let start: Date
        let end: Date
    }
    /// @Published, but assigned ONLY when the snapshot actually changed:
    /// the refresh runs on every reconcile tick, and an unconditional
    /// publish would repaint hundreds of guide cells every ~30s for
    /// nothing. The equatable gate keeps publishes to real mutations
    /// (schedule/cancel/delete/finish), which is what lets a guide cell
    /// observe this and drop its red dot when a recording is cancelled
    /// from the DVR tab (field report 2026-08-27: dot survived the
    /// delete because the tab switch never re-fired the guide's
    /// onAppear reseed).
    @Published private(set) var guideRecordingMarkers: [GuideRecordingMarker] = []

    /// Rebuilds `guideRecordingMarkers` from SwiftData. Fetches every row
    /// and filters in memory -- recording counts are tiny.
    func refreshGuideRecordingMarkers(modelContext: ModelContext) {
        let all = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
        let fresh: [GuideRecordingMarker] = all.compactMap { rec in
            guard rec.status == .scheduled || rec.status == .recording else { return nil }
            return GuideRecordingMarker(channelID: rec.channelID,
                                        channelName: rec.channelName,
                                        title: rec.programTitle,
                                        start: rec.scheduledStart,
                                        end: rec.scheduledEnd)
        }
        if fresh != guideRecordingMarkers { guideRecordingMarkers = fresh }
    }

    /// Guide-cell query: is a Scheduled/in-progress recording set for this
    /// programme slot? Channel identity is matched on whichever field the
    /// row actually carries: server-imported rows store the Dispatcharr
    /// numeric channel id (and an empty name), so the cell's own
    /// `dispatcharrChannelID` bridges that id space; sheet-created rows
    /// carry the guide's own id + name.
    ///
    /// There is deliberately NO title fallback (field report 2026-08-25,
    /// di5cord20): a simulcast - America's Got Talent airing the same slot
    /// on WGRZ, Citytv AND WNBC - lit the record dot on every channel
    /// carrying the programme, because same title + same window matches
    /// every airing. Channel identity must decide; a recording whose ids
    /// genuinely can't be bridged loses its dot rather than painting
    /// phantom ones across the guide.
    func hasGuideRecordingMarker(channelID: String, channelName: String,
                                 dispatcharrChannelID: Int?,
                                 title: String, start: Date, end: Date) -> Bool {
        let dispatcharrIDString = dispatcharrChannelID.map(String.init)
        return guideRecordingMarkers.contains { m in
            guard m.start < end, start < m.end else { return false }
            if m.channelID == channelID { return true }
            if let did = dispatcharrIDString, m.channelID == did { return true }
            if !m.channelName.isEmpty && m.channelName == channelName { return true }
            return false
        }
    }

    // MARK: - Start local recording

    /// Starts a local recording for the given `Recording` model object.
    /// The `Recording` should already be inserted into SwiftData with
    /// `status == .scheduled` before calling this. `server` is the channel's
    /// playlist: the stream opens with the headers live playback sends for
    /// the same channel (its User-Agent and key), through the same gates.
    func startLocalRecording(_ recording: Recording, streamURL: URL, server: ServerConnection? = nil,
                             modelContext: ModelContext) async {
        // Quota check
        guard !isQuotaExceeded else {
            recording.status = .failed
            recording.failureReason = RecordingError.quotaExceeded(
                usedMB: Int(localUsageBytes / 1_048_576),
                maxMB: Int(maxLocalStorageBytes / 1_048_576)
            ).localizedDescription
            try? modelContext.save()
            return
        }

        guard let dir = effectiveRecordingsDirectory else {
            recording.status = .failed
            recording.failureReason = "Could not determine recordings directory"
            try? modelContext.save()
            return
        }

        // The headers live playback opens this channel with, and the URL and
        // headers after the stream-address gate (ServerConnection.keyedStream):
        // a URL on an address the playlist left is rebuilt on the address in
        // use, or sent without the key, or, with Xtream Codes credentials in
        // it, not opened at all. Before this the recorder sent no key and the
        // system User-Agent, unlike live playback and AerioTV for Android.
        var openURL = streamURL
        var openHeaders: [String: String] = [:]
        if let server {
            guard let opened = server.keyedStream(streamURL, headers: server.liveStreamHeaders) else {
                recording.status = .failed
                recording.failureReason = InterruptedCapture.nothingWritten
                try? modelContext.save()
                debugLog("[DVR] on-device recording \(recording.id.uuidString.prefix(8)): its stream URL is on an address the playlist left; nothing opened")
                refreshGuideRecordingMarkers(modelContext: modelContext)
                return
            }
            openURL = opened.url
            openHeaders = opened.headers
        }

        // Access security-scoped resource if custom dir
        let needsScope = customRecordingsDirectory != nil
        if needsScope { _ = dir.startAccessingSecurityScopedResource() }

        let path = dir.appendingPathComponent("\(recording.id.uuidString).ts").path
        // Relative in the default folder, absolute in a custom one.
        recording.localFilePath = RecordingPathRules.stored(path, root: Self.defaultRecordingsDirectory?.path)
        recording.status = .recording
        try? modelContext.save()

        let session = LocalRecordingSession(streamURL: openURL, filePath: path,
                                            userAgent: nil, headers: openHeaders)
        activeSessions[recording.id] = session
        updateRecordingState()

        do {
            try await session.start()

            // Schedule auto-stop at effectiveEnd. Tracked so an early stop can
            // cancel it (see autoStopTasks / stopLocalRecording).
            let delay = recording.effectiveEnd.timeIntervalSinceNow
            if delay > 0 {
                let recID = recording.id
                autoStopTasks[recID] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    await self?.stopLocalRecording(recording, modelContext: modelContext)
                }
            }
        } catch {
            recording.status = .failed
            recording.failureReason = error.localizedDescription
            activeSessions.removeValue(forKey: recording.id)
            updateRecordingState()
            discardEmptyCapture(recording)
            try? modelContext.save()
        }
        refreshGuideRecordingMarkers(modelContext: modelContext)
    }

    /// Stops a local recording, finalizes the file, updates model state.
    func stopLocalRecording(_ recording: Recording, modelContext: ModelContext) async {
        // Cancel any pending auto-stop for this recording. On an early stop this
        // prevents the scheduled task from sleeping (and retaining state) until
        // effectiveEnd; when this IS the auto-stop firing, cancelling an
        // already-completed task is a harmless no-op.
        autoStopTasks.removeValue(forKey: recording.id)?.cancel()
        guard let session = activeSessions.removeValue(forKey: recording.id) else {
            // Diagnostic for the "Stop doesn't stop" report: if no session is
            // tracked here when Stop is pressed, the underlying URLSession may
            // still be writing (orphaned), which is why deleting the file was
            // needed to halt it. This distinguishes "session not found" from
            // "stop ran but didn't cancel the task" in logs.
            debugLog("🔴 stopLocalRecording: NO active session for id=\(recording.id) (already stopped or orphaned) - active keys=\(activeSessions.keys.map { $0.uuidString.prefix(8) })")
            // Still marked recording with nothing capturing (a relaunch or a
            // trip to the background ended it): Stop finishes it now.
            if finishInterrupted(recording, trigger: "stop") {
                try? modelContext.save()
                updateRecordingState()
                refreshGuideRecordingMarkers(modelContext: modelContext)
            }
            return
        }
        debugLog("🔴 stopLocalRecording: stopping active session id=\(recording.id)")
        await session.stop()

        let written = await session.getBytesWritten()
        recording.fileSizeBytes = written
        recording.status = written > 0 ? .completed : .failed
        if written == 0 {
            recording.failureReason = "No data was written"
            discardEmptyCapture(recording)
        }
        // The length shown is what the file holds (stopped early, or started
        // partway into its window), not the scheduled window.
        if written > 0 {
            let attrs = recording.resolvedLocalFilePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
            let created = attrs?[.creationDate] as? Date
            let fallbackStart = max(recording.createdAt, recording.effectiveStart)
            recording.capturedSeconds = InterruptedCapture.capturedSeconds(
                created: created,
                modified: attrs?[.modificationDate] as? Date,
                fallbackStart: fallbackStart,
                now: Date())
            recording.capturedStart = InterruptedCapture.captureStart(created: created, fallbackStart: fallbackStart)
            debugLog("[DVR] on-device recording \(recording.id.uuidString.prefix(8)) stopped: \(written) bytes, \(Int(recording.capturedSeconds ?? 0)) s captured")
        }
        try? modelContext.save()
        updateRecordingState()
        refreshGuideRecordingMarkers(modelContext: modelContext)
    }

    // MARK: - Dispatcharr server-side recording

    /// Schedules a recording on the Dispatcharr server and saves a
    /// local `Recording` row to track it.
    func scheduleDispatcharrRecording(api: DispatcharrAPI,
                                      recording: Recording,
                                      channelIntID: Int,
                                      applyServerOffsets: Bool,
                                      comskip: Bool = false,
                                      modelContext: ModelContext) async throws {
        let result = try await api.createRecording(
            channelID: channelIntID,
            startTime: recording.effectiveStart,
            endTime: recording.effectiveEnd,
            title: recording.programTitle,
            description: recording.programDescription,
            applyServerOffsets: applyServerOffsets,
            comskip: comskip
        )
        recording.remoteRecordingID = result.id
        recording.status = RecordingStatus(rawValue: result.status ?? "scheduled") ?? .scheduled
        try? modelContext.save()
        refreshGuideRecordingMarkers(modelContext: modelContext)
    }

    /// Deletes a recording from the Dispatcharr server AND removes the
    /// local `Recording` row.
    func deleteDispatcharrRecording(api: DispatcharrAPI,
                                    recording: Recording,
                                    modelContext: ModelContext) async throws {
        if let remoteID = recording.remoteRecordingID {
            try await api.deleteRecording(id: remoteID)
        }
        modelContext.delete(recording)
        try? modelContext.save()
        refreshGuideRecordingMarkers(modelContext: modelContext)
    }

    /// Stops an in-flight Dispatcharr recording early, keeping the
    /// partial file on the server.
    func stopDispatcharrRecording(api: DispatcharrAPI,
                                  recording: Recording,
                                  modelContext: ModelContext) async throws {
        guard let remoteID = recording.remoteRecordingID else { return }
        try await api.stopRecording(id: remoteID)
        recording.status = .stopped
        try? modelContext.save()
        refreshGuideRecordingMarkers(modelContext: modelContext)
    }

    /// Downloads a completed Dispatcharr recording to local storage.
    func downloadDispatcharrRecording(api: DispatcharrAPI,
                                      recording: Recording,
                                      modelContext: ModelContext) async throws {
        guard let remoteID = recording.remoteRecordingID,
              let playbackURL = api.recordingPlaybackURL(id: remoteID),
              let dir = effectiveRecordingsDirectory else { return }

        let needsScope = customRecordingsDirectory != nil
        if needsScope { _ = dir.startAccessingSecurityScopedResource() }
        defer { if needsScope { dir.stopAccessingSecurityScopedResource() } }

        let destPath = dir.appendingPathComponent("\(recording.id.uuidString).ts")

        // Authenticated, status-checked, atomic download. The /file/ endpoint
        // sits behind the same auth as every other Dispatcharr call, so the old
        // unauthenticated URLSession.shared.download(from:) 401/403'd on secured
        // servers and then silently saved the HTML/JSON error body as a .ts with
        // a bogus byte count. Attach the stream auth headers, require 200 before
        // committing, and replace any stale file so re-download isn't blocked.
        var request = URLRequest(url: playbackURL)
        api.streamAuthHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        // A rejected key or a 429 pause fails here with nothing sent.
        await DispatcharrHTTPGate.awaitLaunchCredentialMerge(request)
        request = try DispatcharrHTTPGate.prepare(request)
        // A deleted playlist's recording: nothing is downloaded (PlaylistRevocation).
        try PlaylistRevocation.shared.check(url: playbackURL.absoluteString,
                                            apiKey: request.value(forHTTPHeaderField: "X-API-Key"))
        // The stream sign-in rides this request: a redirect to another host
        // or port, or from https to http, drops it (RedirectAuthPolicy).
        let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: RedirectAuthGuard.shared)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "RecordingCoordinator", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Recording download failed (HTTP \(code))"])
        }
        if FileManager.default.fileExists(atPath: destPath.path) {
            try? FileManager.default.removeItem(at: destPath)
        }
        try FileManager.default.moveItem(at: tempURL, to: destPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: destPath.path)
        recording.localFilePath = RecordingPathRules.stored(destPath.path, root: Self.defaultRecordingsDirectory?.path)
        recording.fileSizeBytes = (attrs[.size] as? Int64) ?? 0
        try? modelContext.save()

        debugLog("⬇️ Downloaded Dispatcharr recording \(remoteID) → \(destPath.path)")
    }

    // MARK: - Dispatcharr reconcile

    /// Reconciles local SwiftData `Recording` rows for a single Dispatcharr
    /// server against the server's authoritative recording list. Keeps the
    /// local DVR tab honest as the server transitions rows through
    /// scheduled → recording → completed and as users delete recordings
    /// from the Dispatcharr web UI.
    ///
    /// - Status: when the server's `custom_properties.status` differs from
    ///   our local `statusRaw`, adopt the server's value.
    /// - Pruning: if a local row has a `remoteRecordingID` but the server
    ///   no longer reports it, delete the local row, the user removed it
    ///   elsewhere, so it has no business lingering in our UI.
    /// - Safety: rows with `remoteRecordingID == nil` (still mid-schedule)
    ///   are left alone. Rows for other servers are untouched.
    /// - Import: remote recordings that don't have a matching local row
    ///   (e.g. scheduled on the Dispatcharr web UI, or a row on a fresh
    ///   install) are imported as new local `Recording` entries. Without
    ///   this the DVR tab, which is gated on `hasRecordings` in
    ///   SwiftData, would stay hidden even when the server has
    ///   recordings, making them unreachable from the app.
    /// - Failures: network errors are swallowed with a debug log; this is
    ///   called on every MyRecordingsView appear + refresh tick, so we
    ///   don't want to surface transient connectivity hiccups as errors.
    /// Copies the server's DVR metadata (poster, episode identity, rating,
    /// category) onto the local row. Server art wins over anything we
    /// resolved ourselves; the other fields fill in only when empty so a
    /// value captured at schedule time is never blanked by a sparse poll.
    /// Returns true when anything changed.
    /// Copies the server's end-of-recording facts (size, codec, resolution,
    /// fps, bitrates) onto the local row. Returns true when anything changed.
    static func applyStreamFacts(_ r: DispatcharrAPI.Recording, to local: Recording) -> Bool {
        var changed = false
        if let bytes = r.bytesWritten, bytes > 0, local.fileSizeBytes != bytes {
            local.fileSizeBytes = bytes; changed = true
        }
        if let v = r.fileName, !v.isEmpty, local.remoteFileName != v { local.remoteFileName = v; changed = true }
        if let v = r.videoCodec, local.videoCodec != v { local.videoCodec = v; changed = true }
        if let v = r.videoResolution, local.videoResolution != v { local.videoResolution = v; changed = true }
        if let v = r.videoFrameRate, local.videoFrameRate != v { local.videoFrameRate = v; changed = true }
        if let v = r.videoBitrateKbps, local.videoBitrateKbps != v { local.videoBitrateKbps = v; changed = true }
        if let v = r.audioCodec, local.audioCodec != v { local.audioCodec = v; changed = true }
        if let v = r.audioChannels, local.audioChannels != v { local.audioChannels = v; changed = true }
        return changed
    }

    private func applyRemoteMetadata(_ r: DispatcharrAPI.Recording, to local: Recording,
                                     api: DispatcharrAPI) -> Bool {
        var changed = false
        // Same resolver as every other server image: keeps a path-prefixed
        // base URL for root-relative paths and validates absolute ones.
        if let raw = r.posterURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let u = VODService.resolveImageURL(raw, base: api.baseURL, size: "w780") {
            let absolute = u.absoluteString
            if local.posterURL != absolute { local.posterURL = absolute; changed = true }
        }
        // Channel identity for rows scheduled elsewhere (web UI, another
        // device): the card's logo fallback and the hero's channel name
        // come from the active playlist's channel with this Dispatcharr id.
        if local.channelName.isEmpty || (local.channelLogoURL ?? "").isEmpty,
           let ch = ChannelStore.shared.channels.first(where: { $0.dispatcharrChannelID == r.channel }) {
            if local.channelName.isEmpty { local.channelName = ch.name; changed = true }
            if (local.channelLogoURL ?? "").isEmpty, let logo = ch.logoURL {
                local.channelLogoURL = logo.absoluteString; changed = true
            }
        }
        if (local.subTitle ?? "").isEmpty, let s = r.subTitle, !s.isEmpty { local.subTitle = s; changed = true }
        if local.seasonNumber == nil, let s = r.season { local.seasonNumber = s; changed = true }
        if local.episodeNumber == nil, let e = r.episode { local.episodeNumber = e; changed = true }
        if (local.contentRating ?? "").isEmpty, let c = r.rating, !c.isEmpty { local.contentRating = c; changed = true }
        if (local.epgCategory ?? "").isEmpty, let c = r.category, !c.isEmpty { local.epgCategory = c; changed = true }
        if local.dispatcharrProgramID == nil, let pid = r.programID { local.dispatcharrProgramID = pid; changed = true }
        return changed
    }

    @discardableResult
    func reconcileDispatcharrRecordings(api: DispatcharrAPI,
                                        serverID: String,
                                        modelContext: ModelContext) async -> Bool {
        let remote: [DispatcharrAPI.Recording]
        do {
            remote = try await api.listRecordings()
        } catch {
            debugLog("⚠️ DVR reconcile: listRecordings failed for server \(serverID): \(error)")
            return false
        }

        // Build id → remote map once; per-local lookup is O(1).
        var remoteByID: [Int: DispatcharrAPI.Recording] = [:]
        remoteByID.reserveCapacity(remote.count)
        for r in remote { remoteByID[r.id] = r }

        // Fetch all recordings; filter in-memory to avoid SwiftData
        // #Predicate quirks around the raw String destinationRaw/statusRaw.
        let fetch = FetchDescriptor<Recording>()
        guard let allLocals = try? modelContext.fetch(fetch) else { return false }
        let mine = allLocals.filter {
            $0.serverID == serverID && $0.destinationRaw == RecordingDestination.dispatcharrServer.rawValue
        }

        var didMutate = false
        var knownRemoteIDs = Set<Int>()
        for local in mine {
            guard let rid = local.remoteRecordingID else {
                // Still being scheduled on the server, do not prune.
                continue
            }
            knownRemoteIDs.insert(rid)
            if let r = remoteByID[rid] {
                let newStatus = RecordingStatus(rawValue: r.status ?? "scheduled") ?? .scheduled
                if local.status != newStatus {
                    local.status = newStatus
                    didMutate = true
                }
                // v1.6.22: pick up the server-provided playback URL
                // so an in-progress recording's HLS manifest path
                // lands on the local row. Status flips during a
                // recording's lifecycle (.recording → .completed),
                // and the URL flips with it (HLS m3u8 → file URL),
                // so we always overwrite.
                if local.dispatcharrFileURL != r.fileURL {
                    local.dispatcharrFileURL = r.fileURL
                    didMutate = true
                }
                if applyRemoteMetadata(r, to: local, api: api) { didMutate = true }
                if Self.applyStreamFacts(r, to: local) { didMutate = true }
            } else {
                debugLog("🧹 DVR reconcile: server \(serverID) dropped remoteID \(rid), deleting local row")
                modelContext.delete(local)
                didMutate = true
            }
        }

        // Import any server recording we don't have a local row for yet.
        // This is the only path that lights up the DVR tab for a user who
        // scheduled on the Dispatcharr web UI or reinstalled the app.
        for r in remote where !knownRemoteIDs.contains(r.id) {
            let status = RecordingStatus(rawValue: r.status ?? "scheduled") ?? .scheduled
            let rec = Recording(
                channelID: String(r.channel),
                channelName: "",  // Filled in lazily via the channel store; safe to leave empty.
                programTitle: r.programTitle ?? "",
                programDescription: r.programDescription ?? "",
                scheduledStart: r.startTime,
                scheduledEnd: r.endTime,
                preRollMinutes: 0,
                postRollMinutes: 0,
                destination: .dispatcharrServer,
                status: status,
                remoteRecordingID: r.id,
                dispatcharrFileURL: r.fileURL,
                serverID: serverID
            )
            _ = applyRemoteMetadata(r, to: rec, api: api)
            _ = Self.applyStreamFacts(r, to: rec)
            modelContext.insert(rec)
            didMutate = true
            debugLog("📥 DVR reconcile: imported remote recording \(r.id) (\(r.programTitle ?? "-")) from server \(serverID)")
        }

        if didMutate {
            try? modelContext.save()
        }
        refreshGuideRecordingMarkers(modelContext: modelContext)
        return didMutate
    }

    // MARK: - Delete local recording

    /// Deletes a local recording's file from disk and removes the
    /// SwiftData row.
    func deleteLocalRecording(_ recording: Recording, modelContext: ModelContext) {
        if let path = recording.resolvedLocalFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        modelContext.delete(recording)
        try? modelContext.save()
        refreshGuideRecordingMarkers(modelContext: modelContext)
    }

    // MARK: - Idle Timer

    private func updateRecordingState() {
        let hasActive = !activeSessions.isEmpty
        isRecording = hasActive
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = hasActive
        #endif
    }

    // MARK: - Background handling

    /// Called from AerioApp's scenePhase handler on background. Stops all
    /// active sessions immediately; with a model context, their
    /// rows are then finished as interrupted (finishInterruptedRecordings).
    /// Without one, the next launch or Stop finishes them.
    func stopAllSessionsOnBackground(modelContext: ModelContext? = nil) {
        let stopping = Array(activeSessions.values)
        activeSessions.removeAll()
        updateRecordingState()
        guard !stopping.isEmpty else { return }
        Task {
            for session in stopping { await session.stop() }
            // Their rows are finished now (interrupted), not left "Recording
            // now" with nothing capturing.
            if let modelContext { finishInterruptedRecordings(in: modelContext, trigger: "background") }
        }
    }

    // MARK: - On-device recordings with no capture behind them (owner 2026-11-13)

    /// Every on-device row still marked recording with no capture running
    /// for it becomes finished (InterruptedCapture). At launch that is every
    /// one: no capture survives a relaunch.
    func finishInterruptedRecordings(in modelContext: ModelContext, trigger: String) {
        let rows = (try? modelContext.fetch(FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.destinationRaw == "local" && $0.statusRaw == "recording" }
        ))) ?? []
        var finished = 0
        for r in rows where activeSessions[r.id] == nil {
            if finishInterrupted(r, trigger: trigger) { finished += 1 }
        }
        guard finished > 0 else { return }
        try? modelContext.save()
        refreshGuideRecordingMarkers(modelContext: modelContext)
    }

    /// One row: interrupted with what its file captured, or failed when
    /// nothing was. False when the row is not an on-device recording in
    /// progress (nothing to do).
    @discardableResult
    private func finishInterrupted(_ rec: Recording, trigger: String) -> Bool {
        guard rec.destination == .local, rec.status == .recording else { return false }
        let attrs = rec.resolvedLocalFilePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
        let out = InterruptedCapture.outcome(
            fileBytes: attrs.flatMap { ($0[.size] as? NSNumber)?.int64Value },
            created: attrs?[.creationDate] as? Date,
            modified: attrs?[.modificationDate] as? Date,
            fallbackStart: max(rec.createdAt, rec.effectiveStart),
            now: Date())
        rec.statusRaw = out.statusRaw
        rec.fileSizeBytes = out.bytes
        rec.capturedSeconds = out.capturedSeconds
        rec.capturedStart = out.captureStart
        rec.failureReason = out.failureReason
        let what = out.capturedSeconds.map { "kept \(out.bytes) bytes, \(Int($0)) s captured" }
            ?? "nothing captured (\(out.failureReason ?? ""))"
        debugLog("[DVR] on-device recording \(rec.id.uuidString.prefix(8)) had no capture running (\(trigger)): now \(out.statusRaw), \(what)")
        if rec.status == .failed { discardEmptyCapture(rec) }
        return true
    }

    /// A capture that wrote nothing leaves no file behind: AerioTV for
    /// Android discards the empty file too (LocalRecordingService, and its
    /// recovery of an interrupted capture). The row stays failed with its
    /// reason and its stored path, so the DVR lists it as before, and a
    /// failed row is never shown as missing (isLocalFileMissing reads
    /// finished rows only). Only an empty file is removed.
    private func discardEmptyCapture(_ rec: Recording) {
        guard let path = rec.resolvedLocalFilePath,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              size.int64Value == 0 else { return }
        try? FileManager.default.removeItem(atPath: path)
        debugLog("[DVR] on-device recording \(rec.id.uuidString.prefix(8)) captured nothing: its empty file is removed")
    }

    /// Full variant with model updates, call this from views that have
    /// a modelContext when the app backgrounds.
    func handleAppBackgrounded(modelContext: ModelContext) async {
        for (id, session) in activeSessions {
            await session.stop()
            let descriptor = FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { $0.id == id }
            )
            if let rec = try? modelContext.fetch(descriptor).first {
                let written = await session.getBytesWritten()
                rec.fileSizeBytes = written
                rec.status = .failed
                rec.failureReason = RecordingError.appBackgrounded.localizedDescription
            }
        }
        activeSessions.removeAll()
        updateRecordingState()
        try? modelContext.save()
    }
}

extension Recording {
    /// Where this recording's file is on this device now: the stored value
    /// resolved against the current container (RecordingPathRules). Every
    /// file access goes through this, never the raw `localFilePath`.
    var resolvedLocalFilePath: String? {
        RecordingPathRules.resolve(localFilePath,
                                   root: RecordingCoordinator.defaultRecordingsDirectory?.path,
                                   exists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// A finished recording on this device whose file is not there (removed
    /// outside the app, or purged from Apple TV's cache): shown as missing,
    /// with no Play, and still deletable.
    var isLocalFileMissing: Bool {
        guard destination == .local, status == .completed || status == .stopped || status == .interrupted else { return false }
        return RecordingPathRules.isMissing(resolvedPath: resolvedLocalFilePath,
                                            exists: { FileManager.default.fileExists(atPath: $0) })
    }
}
