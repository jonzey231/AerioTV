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

    /// Default local recordings directory — `Documents/Recordings/`.
    /// Created lazily.
    var localRecordingsDirectory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    // MARK: - Start local recording

    /// Starts a local recording for the given `Recording` model object.
    /// The `Recording` should already be inserted into SwiftData with
    /// `status == .scheduled` before calling this.
    func startLocalRecording(_ recording: Recording, streamURL: URL,
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

        // Access security-scoped resource if custom dir
        let needsScope = customRecordingsDirectory != nil
        if needsScope { _ = dir.startAccessingSecurityScopedResource() }

        let path = dir.appendingPathComponent("\(recording.id.uuidString).ts").path
        recording.localFilePath = path
        recording.status = .recording
        try? modelContext.save()

        let session = LocalRecordingSession(streamURL: streamURL, filePath: path,
                                            userAgent: nil)
        activeSessions[recording.id] = session
        updateRecordingState()

        do {
            try await session.start()

            // Schedule auto-stop at effectiveEnd
            let delay = recording.effectiveEnd.timeIntervalSinceNow
            if delay > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    await stopLocalRecording(recording, modelContext: modelContext)
                }
            }
        } catch {
            recording.status = .failed
            recording.failureReason = error.localizedDescription
            activeSessions.removeValue(forKey: recording.id)
            updateRecordingState()
            try? modelContext.save()
        }
    }

    /// Stops a local recording, finalizes the file, updates model state.
    func stopLocalRecording(_ recording: Recording, modelContext: ModelContext) async {
        guard let session = activeSessions.removeValue(forKey: recording.id) else { return }
        await session.stop()

        let written = await session.getBytesWritten()
        recording.fileSizeBytes = written
        recording.status = written > 0 ? .completed : .failed
        if written == 0 { recording.failureReason = "No data was written" }
        try? modelContext.save()
        updateRecordingState()
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
        let (tempURL, _) = try await URLSession.shared.download(from: playbackURL)
        try FileManager.default.moveItem(at: tempURL, to: destPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: destPath.path)
        recording.localFilePath = destPath.path
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
    ///   no longer reports it, delete the local row — the user removed it
    ///   elsewhere, so it has no business lingering in our UI.
    /// - Safety: rows with `remoteRecordingID == nil` (still mid-schedule)
    ///   are left alone. Rows for other servers are untouched.
    /// - Import: remote recordings that don't have a matching local row
    ///   (e.g. scheduled on the Dispatcharr web UI, or a row on a fresh
    ///   install) are imported as new local `Recording` entries. Without
    ///   this the DVR tab — which is gated on `hasRecordings` in
    ///   SwiftData — would stay hidden even when the server has
    ///   recordings, making them unreachable from the app.
    /// - Failures: network errors are swallowed with a debug log; this is
    ///   called on every MyRecordingsView appear + refresh tick, so we
    ///   don't want to surface transient connectivity hiccups as errors.
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
                // Still being scheduled on the server — do not prune.
                continue
            }
            knownRemoteIDs.insert(rid)
            if let r = remoteByID[rid] {
                let newStatus = RecordingStatus(rawValue: r.status ?? "scheduled") ?? .scheduled
                if local.status != newStatus {
                    local.status = newStatus
                    didMutate = true
                }
            } else {
                debugLog("🧹 DVR reconcile: server \(serverID) dropped remoteID \(rid) — deleting local row")
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
                serverID: serverID
            )
            modelContext.insert(rec)
            didMutate = true
            debugLog("📥 DVR reconcile: imported remote recording \(r.id) (\(r.programTitle ?? "—")) from server \(serverID)")
        }

        if didMutate {
            try? modelContext.save()
        }
        return didMutate
    }

    // MARK: - Delete local recording

    /// Deletes a local recording's file from disk and removes the
    /// SwiftData row.
    func deleteLocalRecording(_ recording: Recording, modelContext: ModelContext) {
        if let path = recording.localFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        modelContext.delete(recording)
        try? modelContext.save()
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

    /// Lightweight variant called from AerioApp's scenePhase handler
    /// (which has no modelContext). Stops all active sessions immediately.
    /// The Recording model objects will be updated the next time the user
    /// opens My Recordings or when the coordinator syncs state.
    func stopAllSessionsOnBackground() {
        for (_, session) in activeSessions {
            Task { await session.stop() }
        }
        activeSessions.removeAll()
        updateRecordingState()
    }

    /// Full variant with model updates — call this from views that have
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
