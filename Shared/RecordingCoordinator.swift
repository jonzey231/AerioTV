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

        let safeName = "\(recording.channelName) - \(recording.programTitle)"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let fileName = safeName.isEmpty ? recording.id.uuidString : safeName
        let path = dir.appendingPathComponent("\(fileName).ts").path
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
            recording.actualEndTime = Date()
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
        recording.actualEndTime = Date()
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
        recording.actualEndTime = Date()
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

        let safeName = "\(recording.channelName) - \(recording.programTitle)"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let fileName = safeName.isEmpty ? recording.id.uuidString : safeName
        let destPath = dir.appendingPathComponent("\(fileName).ts")
        let (tempURL, _) = try await URLSession.shared.download(from: playbackURL)
        try FileManager.default.moveItem(at: tempURL, to: destPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: destPath.path)
        recording.localFilePath = destPath.path
        recording.fileSizeBytes = (attrs[.size] as? Int64) ?? 0
        try? modelContext.save()

        debugLog("⬇️ Downloaded Dispatcharr recording \(remoteID) → \(destPath.path)")
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
                rec.actualEndTime = Date()
                rec.status = .failed
                rec.failureReason = RecordingError.appBackgrounded.localizedDescription
            }
        }
        activeSessions.removeAll()
        updateRecordingState()
        try? modelContext.save()
    }

    // MARK: - Dispatcharr status sync

    /// Full two-way sync with all Dispatcharr servers: updates statuses,
    /// removes locally-tracked recordings deleted on the server, and
    /// discovers server recordings not yet tracked locally.
    func syncWithDispatcharr(servers: [ServerConnection], modelContext: ModelContext) async {
        // Remove local recording entries whose files were deleted outside the app
        pruneOrphanedLocalRecordings(modelContext: modelContext)

        let dispatcharrServers = servers.filter { $0.type == .dispatcharrAPI }
        guard !dispatcharrServers.isEmpty else { return }

        let allLocal = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []

        for server in dispatcharrServers {
            let serverID = server.id.uuidString
            let api = DispatcharrAPI(
                baseURL: server.effectiveBaseURL,
                auth: .apiKey(server.effectiveApiKey),
                userAgent: server.effectiveUserAgent
            )

            let remoteRecordings: [DispatcharrAPI.Recording]
            do {
                remoteRecordings = try await api.listRecordings()
            } catch {
                continue
            }

            let remoteByID = Dictionary(uniqueKeysWithValues: remoteRecordings.map { ($0.id, $0) })
            let localForServer = allLocal.filter {
                $0.destination == .dispatcharrServer && $0.serverID == serverID
            }

            // Update or delete existing local recordings
            for rec in localForServer {
                guard let remoteID = rec.remoteRecordingID else { continue }
                if let remote = remoteByID[remoteID] {
                    let serverStatus = Self.mapStatus(remote)
                    if rec.status != serverStatus {
                        rec.statusRaw = serverStatus.rawValue
                    }
                    rec.comskipCompleted = remote.comskip
                } else {
                    modelContext.delete(rec)
                }
            }

            // Discover server recordings not tracked locally
            let localRemoteIDs = Set(localForServer.compactMap { $0.remoteRecordingID })
            for remote in remoteRecordings where !localRemoteIDs.contains(remote.id) {
                let rec = Recording(
                    channelID: String(remote.channel),
                    channelName: "Channel \(remote.channel)",
                    programTitle: remote.programTitle ?? "",
                    programDescription: remote.programDescription ?? "",
                    scheduledStart: remote.startTime,
                    scheduledEnd: remote.endTime,
                    preRollMinutes: 0,
                    postRollMinutes: 0,
                    destination: .dispatcharrServer,
                    serverID: serverID
                )
                rec.remoteRecordingID = remote.id
                rec.statusRaw = Self.mapStatus(remote).rawValue
                rec.comskipCompleted = remote.comskip
                modelContext.insert(rec)
            }

            try? modelContext.save()
        }
    }

    /// Removes local recording entries whose .ts files no longer exist on disk
    /// (e.g. the user deleted them from the Files app).
    private func pruneOrphanedLocalRecordings(modelContext: ModelContext) {
        let allLocal = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
        let fm = FileManager.default
        var pruned = 0
        for rec in allLocal {
            guard rec.destination == .local,
                  let path = rec.localFilePath,
                  !path.isEmpty,
                  (rec.isCompleted || rec.status == .stopped || rec.status == .interrupted)
            else { continue }
            if !fm.fileExists(atPath: path) {
                modelContext.delete(rec)
                pruned += 1
            }
        }
        if pruned > 0 { try? modelContext.save() }
    }

    private static func mapStatus(_ remote: DispatcharrAPI.Recording) -> RecordingStatus {
        if let status = remote.status {
            return RecordingStatus(rawValue: status) ?? .completed
        }
        if remote.endTime <= Date() {
            return .completed
        } else if remote.startTime <= Date() {
            return .recording
        } else {
            return .scheduled
        }
    }
}
