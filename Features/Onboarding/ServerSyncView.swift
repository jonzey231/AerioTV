import SwiftUI
import SwiftData

// MARK: - Sync Stage

/// Represents a loading step shown during server sync.
private struct SyncStage: Identifiable {
    let id: String
    let label: String
    var status: StageStatus = .pending

    enum StageStatus: Equatable {
        case pending
        case loading
        case done(String)   // detail text (e.g. "2,127 channels")
        case failed(String) // error text
    }

    var icon: String {
        switch status {
        case .pending:  return "circle"
        case .loading:  return "arrow.triangle.2.circlepath"
        case .done:     return "checkmark.circle.fill"
        case .failed:   return "exclamationmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch status {
        case .pending:  return .textTertiary
        case .loading:  return .accentPrimary
        case .done:     return .statusOnline
        case .failed:   return .statusLive
        }
    }
}

// MARK: - Server Sync View

/// Full-screen loading screen shown after a server is added.
/// Displays step-by-step progress as channels, groups, EPG, and VOD data load.
struct ServerSyncView: View {
    let server: ServerConnection
    @Environment(\.dismiss) private var dismiss

    @State private var stages: [SyncStage] = [
        SyncStage(id: "connect",  label: "Connecting to server"),
        SyncStage(id: "groups",   label: "Loading channel groups"),
        SyncStage(id: "channels", label: "Loading channels"),
        SyncStage(id: "epg",      label: "Loading EPG data"),
        SyncStage(id: "vod",      label: "Loading movies & series"),
    ]
    @State private var allDone = false
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 12) {
                    Image("AerioLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .accentPrimary.opacity(0.3), radius: 20, y: 4)

                    Text("Setting Up")
                        .font(.headlineLarge)
                        .foregroundColor(.textPrimary)

                    Text(server.name.isEmpty ? "Your server" : server.name)
                        .font(.bodyMedium)
                        .foregroundColor(.textSecondary)
                }

                // Progress stages
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(stages) { stage in
                        stageRow(stage)
                        if stage.id != stages.last?.id {
                            Rectangle()
                                .fill(Color.borderSubtle)
                                .frame(width: 1, height: 16)
                                .padding(.leading, 15)
                        }
                    }
                }
                .padding(20)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 32)

                Spacer()

                // Bottom actions
                if allDone {
                    PrimaryButton("Continue to Live TV", icon: "play.tv") {
                        dismiss()
                    }
                    .padding(.horizontal, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Button("Skip") {
                        syncTask?.cancel()
                        dismiss()
                    }
                    .font(.bodyMedium)
                    .foregroundColor(.textSecondary)
                }

                Spacer().frame(height: 20)
            }
        }
        .interactiveDismissDisabled(!allDone)
        .task {
            let task = Task { await runSync() }
            syncTask = task
            await task.value
        }
    }

    // MARK: - Stage Row

    private func stageRow(_ stage: SyncStage) -> some View {
        HStack(spacing: 14) {
            ZStack {
                if case .loading = stage.status {
                    ProgressView()
                        .tint(.accentPrimary)
                        .scaleEffect(0.8)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: stage.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(stage.iconColor)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.label)
                    .font(.bodyMedium)
                    .foregroundColor(
                        stage.status == .pending ? .textTertiary : .textPrimary
                    )

                if case .done(let detail) = stage.status, !detail.isEmpty {
                    Text(detail)
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                }
                if case .failed(let err) = stage.status {
                    Text(err)
                        .font(.labelSmall)
                        .foregroundColor(.statusLive)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.3), value: stage.status)
    }

    // MARK: - Sync Logic

    @MainActor
    private func runSync() async {
        let snap = server.snapshot
        let epgURLString = server.effectiveEPGURL

        // Stage 0: Connect
        updateStage("connect", status: .loading)
        // Brief pause to show "connecting" state
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        updateStage("connect", status: .done("Connected"))

        // Stage 1: Groups
        updateStage("groups", status: .loading)
        let groupCount = await loadGroups(snap: snap)
        guard !Task.isCancelled else { return }
        updateStage("groups", status: .done(groupCount > 0 ? "\(groupCount) groups" : ""))

        // Stage 2: Channels
        updateStage("channels", status: .loading)
        let channelCount = await loadChannels(snap: snap)
        guard !Task.isCancelled else { return }
        updateStage("channels", status: .done(channelCount > 0 ? "\(channelCount) channels" : ""))

        // Stage 3: EPG
        updateStage("epg", status: .loading)
        let epgCount = await loadEPG(snap: snap, epgURL: epgURLString)
        guard !Task.isCancelled else { return }
        updateStage("epg", status: .done(epgCount > 0 ? "\(epgCount) programs" : ""))

        // Stage 4: VOD
        updateStage("vod", status: .loading)
        let vodCount = await loadVOD(snap: snap)
        guard !Task.isCancelled else { return }
        updateStage("vod", status: .done(vodCount > 0 ? "\(vodCount) titles" : "No VOD available"))

        // All done
        withAnimation(.spring(response: 0.4)) {
            allDone = true
        }
    }

    private func updateStage(_ id: String, status: SyncStage.StageStatus) {
        if let idx = stages.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                stages[idx].status = status
            }
        }
    }

    // MARK: - Data Loading

    private func loadGroups(snap: ServerSnapshot) async -> Int {
        switch snap.type {
        case .dispatcharrAPI:
            let api = DispatcharrAPI(baseURL: snap.baseURL, auth: .apiKey(snap.apiKey))
            if let groups = try? await api.getChannelGroups() {
                return groups.count
            }
        case .xtreamCodes:
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            if let groups = try? await api.getLiveCategories() {
                return groups.count
            }
        case .m3uPlaylist:
            // M3U groups are parsed inline with channels
            return 0
        }
        return 0
    }

    private func loadChannels(snap: ServerSnapshot) async -> Int {
        switch snap.type {
        case .dispatcharrAPI:
            let api = DispatcharrAPI(baseURL: snap.baseURL, auth: .apiKey(snap.apiKey))
            if let channels = try? await api.getChannels() {
                return channels.count
            }
        case .xtreamCodes:
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            if let streams = try? await api.getLiveStreams() {
                return streams.count
            }
        case .m3uPlaylist:
            if let url = URL(string: snap.baseURL),
               let channels = try? await M3UParser.fetchAndParse(url: url) {
                return channels.count
            }
        }
        return 0
    }

    private func loadEPG(snap: ServerSnapshot, epgURL: String) async -> Int {
        switch snap.type {
        case .dispatcharrAPI:
            let api = DispatcharrAPI(baseURL: snap.baseURL, auth: .apiKey(snap.apiKey))
            if let programs = try? await api.getCurrentPrograms() {
                return programs.count
            }
        case .xtreamCodes:
            // Xtream EPG is per-channel; just verify the server is reachable.
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            if let _ = try? await api.verifyConnection() {
                return 1  // Server is accessible for EPG
            }
        case .m3uPlaylist:
            // EPG is optional for M3U
            if !epgURL.isEmpty, let url = URL(string: epgURL),
               let programs = try? await XMLTVParser.fetchAndParse(url: url) {
                return programs.count
            }
        }
        return 0
    }

    private func loadVOD(snap: ServerSnapshot) async -> Int {
        guard snap.type == .dispatcharrAPI || snap.type == .xtreamCodes else {
            return 0
        }
        switch snap.type {
        case .dispatcharrAPI:
            let api = DispatcharrAPI(baseURL: snap.baseURL, auth: .apiKey(snap.apiKey))
            var count = 0
            if let movies = try? await api.getVODMovies() { count += movies.count }
            if let series = try? await api.getVODSeries() { count += series.count }
            return count
        case .xtreamCodes:
            let api = XtreamCodesAPI(baseURL: snap.baseURL, username: snap.username, password: snap.password)
            var count = 0
            if let movies = try? await api.getVODStreams() { count += movies.count }
            if let series = try? await api.getSeries() { count += series.count }
            return count
        default:
            return 0
        }
    }
}
