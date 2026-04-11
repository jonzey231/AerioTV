import SwiftUI
import SwiftData

// MARK: - My Recordings

struct MyRecordingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var nowPlaying: NowPlayingManager
    @Query(sort: \Recording.createdAt, order: .reverse) private var allRecordings: [Recording]
    @Query private var servers: [ServerConnection]
    @StateObject private var coordinator = RecordingCoordinator.shared

    @State private var selectedSegment = 0 // 0=Scheduled, 1=Recording, 2=Completed, 3=Cancelled
    @State private var recordingToDelete: Recording?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFromServerAlert = false
    @State private var showDownloadConfirmation = false

    private var scheduled: [Recording] {
        let now = Date()
        return allRecordings.filter {
            $0.status == .scheduled && $0.effectiveStart > now
        }
    }

    private var recording: [Recording] {
        let now = Date()
        return allRecordings.filter {
            $0.status == .recording ||
            ($0.status == .scheduled && $0.effectiveStart <= now && $0.effectiveEnd > now)
        }
    }

    private var completed: [Recording] {
        allRecordings.filter {
            [.completed, .stopped, .interrupted].contains($0.status) ||
            ($0.status == .scheduled && $0.effectiveEnd <= Date())
        }
    }

    private var cancelled: [Recording] {
        allRecordings.filter { [.cancelled, .failed].contains($0.status) }
    }

    private var activeList: [Recording] {
        switch selectedSegment {
        case 0: return scheduled
        case 1: return recording
        case 2: return completed
        default: return cancelled
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    segmentButton("Scheduled", count: scheduled.count, tag: 0)
                    segmentButton("Recording", count: recording.count, tag: 1)
                    segmentButton("Completed", count: completed.count, tag: 2)
                    segmentButton("Cancelled", count: cancelled.count, tag: 3)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)

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
                        RecordingRow(recording: rec, onStop: rec.isInProgress ? { stopRecording(rec) } : nil)
                            .listRowBackground(Color.cardBackground)
                            .contentShape(Rectangle())
                            .onTapGesture { playIfCompleted(rec) }
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
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("DVR")
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
        .task {
            await RecordingCoordinator.shared.syncWithDispatcharr(
                servers: Array(servers), modelContext: modelContext
            )
        }
    }

    // MARK: - Segment Button

    private func segmentButton(_ label: String, count: Int, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedSegment = tag }
        } label: {
            Text("\(label) (\(count))")
                .font(.subheadline.weight(selectedSegment == tag ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(selectedSegment == tag
                        ? Color.accentPrimary.opacity(0.25)
                        : Color.cardBackground)
                )
                .overlay(
                    Capsule().stroke(selectedSegment == tag
                        ? Color.accentPrimary.opacity(0.5)
                        : Color.clear, lineWidth: 1)
                )
                .foregroundColor(selectedSegment == tag ? .accentPrimary : .textSecondary)
        }
        .buttonStyle(.plain)
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
                if !rec.comskipCompleted {
                    Button {
                        runComskip(rec)
                    } label: {
                        Label("Remove Commercials", systemImage: "scissors")
                    }
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
        if rec.isInProgress {
            Button {
                stopRecording(rec)
            } label: {
                Label("Stop & Keep", systemImage: "stop.fill")
            }
            .tint(.orange)
        }
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

    private func playRecording(path: String, title: String = "Recording") {
        let fileURL = URL(fileURLWithPath: path)
        let item = ChannelDisplayItem(
            id: "local-recording",
            name: title,
            number: "",
            logoURL: nil,
            group: "",
            categoryOrder: 0,
            streamURL: fileURL,
            streamURLs: [fileURL],
            currentProgram: nil
        )
        nowPlaying.startPlaying(item, headers: [:], isLive: false)
    }

    private func playServerRecording(_ rec: Recording) {
        guard let api = apiForRecording(rec),
              let remoteID = rec.remoteRecordingID,
              let url = api.recordingPlaybackURL(id: remoteID) else { return }
        let server = servers.first(where: { $0.id.uuidString == rec.serverID })
        let headers = server?.authHeaders ?? [:]
        let item = ChannelDisplayItem(
            id: "server-recording-\(remoteID)",
            name: rec.programTitle.isEmpty ? rec.channelName : rec.programTitle,
            number: "",
            logoURL: nil,
            group: "",
            categoryOrder: 0,
            streamURL: url,
            streamURLs: [url],
            currentProgram: rec.channelName
        )
        nowPlaying.startPlaying(item, headers: headers, isLive: false)
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
            // Delete the local file and remove the row
            coordinator.deleteLocalRecording(rec, modelContext: modelContext)
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

    private func playIfCompleted(_ rec: Recording) {
        guard rec.isCompleted || rec.status == .stopped else { return }
        if rec.destination == .local, let path = rec.localFilePath {
            playRecording(path: path)
        } else if rec.destination == .dispatcharrServer, rec.remoteRecordingID != nil {
            playServerRecording(rec)
        }
    }

    private func runComskip(_ rec: Recording) {
        guard let api = apiForRecording(rec),
              let remoteID = rec.remoteRecordingID else { return }
        Task {
            try? await api.applyComskip(id: remoteID)
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
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recording.channelName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }

            Text(recording.programTitle.isEmpty ? "Untitled" : recording.programTitle)
                .font(.subheadline)
                .foregroundColor(.accentPrimary)
                .lineLimit(1)

            if !recording.programDescription.isEmpty {
                Text(recording.programDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Text(recordingTimeLabel)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                if recording.destination == .dispatcharrServer {
                    Label("Server", systemImage: "server.rack")
                        .font(.caption2)
                        .foregroundColor(.accentPrimary)
                } else {
                    Label("Local", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundColor(.green)
                }

                if recording.comskipCompleted {
                    Label("No Commercials", systemImage: "scissors")
                        .font(.caption2)
                        .foregroundColor(.accentPrimary)
                }
            }

            if recording.isInProgress, let onStop {
                Button(action: onStop) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                        Text("Stop & Keep")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.red))
                }
                .buttonStyle(.plain)
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

    private var recordingTimeLabel: String {
        let start = recording.effectiveStart
        let end = recording.actualEndTime ?? recording.effectiveEnd

        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"

        let duration = max(0, end.timeIntervalSince(start))
        let durationStr: String
        if duration < 60 {
            durationStr = "\(Int(duration))s"
        } else {
            let mins = Int(duration) / 60
            if mins >= 60 {
                let h = mins / 60
                let m = mins % 60
                durationStr = m > 0 ? "\(h)h \(m)m" : "\(h)h"
            } else {
                durationStr = "\(mins)m"
            }
        }

        return "\(df.string(from: start)) at \(tf.string(from: start)) - \(tf.string(from: end)) (\(durationStr))"
    }
}
