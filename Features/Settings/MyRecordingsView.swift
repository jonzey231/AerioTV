import SwiftUI
import SwiftData

// MARK: - My Recordings

struct MyRecordingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var allRecordings: [Recording]
    @Query private var servers: [ServerConnection]
    @StateObject private var coordinator = RecordingCoordinator.shared

    @State private var selectedSegment = 0 // 0=Scheduled, 1=Recording, 2=Completed
    @State private var recordingToDelete: Recording?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFromServerAlert = false
    @State private var showDownloadConfirmation = false

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
            Picker("Filter", selection: $selectedSegment) {
                Text("Scheduled (\(scheduled.count))").tag(0)
                Text("Recording (\(recording.count))").tag(1)
                Text("Completed (\(completed.count))").tag(2)
            }
            .pickerStyle(.segmented)
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
                List {
                    ForEach(activeList, id: \.id) { rec in
                        RecordingRow(recording: rec)
                            .listRowBackground(Color.cardBackground)
                            .contextMenu {
                                contextMenuItems(for: rec)
                            }
                            #if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                swipeActions(for: rec)
                            }
                            #endif
                    }
                }
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
                .background(Color.appBackground)
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
            Text("This will permanently delete this recording from your device.")
        }
        .alert("Delete from Server?", isPresented: $showDeleteFromServerAlert) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { deleteFromServer(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this recording from the Dispatcharr server. The file on the server will be removed.")
        }
        .alert("Save to Device?", isPresented: $showDownloadConfirmation) {
            Button("Save") {
                if let rec = recordingToDelete { downloadRecording(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download this recording from the Dispatcharr server to your device's local storage.")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for rec: Recording) -> some View {
        if rec.isCompleted || rec.status == .stopped {
            if rec.destination == .local, let path = rec.localFilePath {
                Button {
                    playRecording(path: path)
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

    private func playRecording(path: String) {
        // TODO: Push PlayerView with local file URL
        debugLog("▶️ Play local recording: \(path)")
    }

    private func playServerRecording(_ rec: Recording) {
        guard let api = apiForRecording(rec),
              let remoteID = rec.remoteRecordingID,
              let _ = api.recordingPlaybackURL(id: remoteID) else { return }
        // TODO: Push PlayerView with server URL
        debugLog("▶️ Play server recording: \(rec.remoteRecordingID ?? -1)")
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
