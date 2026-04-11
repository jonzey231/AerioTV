import SwiftUI
import SwiftData

/// Sheet presented when a user taps "Record" on a future or currently-airing
/// program in the EPG guide. Lets the user pick pre/post-roll buffers,
/// destination, and confirm.
struct RecordProgramSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var servers: [ServerConnection]

    let programTitle: String
    let programDescription: String
    let channelID: String
    let channelName: String
    let scheduledStart: Date
    let scheduledEnd: Date
    /// Whether the program is already live (disables pre-roll).
    let isLive: Bool
    /// Dispatcharr stream UUID for resolving the stream URL (local recording).
    var streamUUID: String? = nil

    @AppStorage("dvrDefaultPreRollMins") private var defaultPreRoll = 0
    @AppStorage("dvrDefaultPostRollMins") private var defaultPostRoll = 0

    @State private var preRoll: Int = 0
    @State private var postRoll: Int = 0
    @State private var destination: RecordingDestination = .local
    @State private var comskip = false
    @State private var showCustomPreRoll = false
    @State private var showCustomPostRoll = false
    @State private var customValue = 5

    @StateObject private var coordinator = RecordingCoordinator.shared

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var isDispatcharr: Bool {
        activeServer?.type == .dispatcharrAPI
    }

    var body: some View {
        NavigationStack {
            Form {
                // Program info
                Section {
                    LabeledContent("Program", value: programTitle)
                    LabeledContent("Channel", value: channelName)
                    LabeledContent("Time", value: timeLabel)
                }

                // Pre-roll
                Section("Start Early") {
                    if isLive {
                        Text("Pre-roll unavailable (program already started)")
                            .foregroundColor(.secondary)
                    } else {
                        bufferOptions(
                            selection: $preRoll,
                            options: [0, 5, 10, 15, 30],
                            customAction: {
                                customValue = preRoll > 0 ? preRoll : 5
                                showCustomPreRoll = true
                            }
                        )
                    }
                }

                // Post-roll
                Section("End Late") {
                    bufferOptions(
                        selection: $postRoll,
                        options: [0, 5, 10, 15, 30, 60],
                        customAction: {
                            customValue = postRoll > 0 ? postRoll : 5
                            showCustomPostRoll = true
                        }
                    )
                }

                // Destination
                if isDispatcharr {
                    Section("Destination") {
                        Picker("Record to", selection: $destination) {
                            Text("Dispatcharr server").tag(RecordingDestination.dispatcharrServer)
                            Text("This device").tag(RecordingDestination.local)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // Comskip (Dispatcharr server recordings only)
                if isDispatcharr && destination == .dispatcharrServer {
                    Section {
                        Toggle("Remove commercials (Comskip)", isOn: $comskip)
                    } footer: {
                        Text("Automatically detect and remove commercial breaks after recording completes. Processed server-side.")
                    }
                }

                // Warnings
                if destination == .local {
                    Section {
                        Label {
                            Text("Keep AerioTV open — closing the app will stop this recording.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                        }
                    }
                }

                if destination == .local && coordinator.isApproachingQuotaLimit {
                    Section {
                        Label {
                            Text("Storage is running low. This recording may not finish if the limit is reached.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "externaldrive.badge.exclamationmark")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .navigationTitle(isLive ? "Record from Now" : "Record Program")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") { scheduleRecording() }
                        .bold()
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            preRoll = isLive ? 0 : defaultPreRoll
            postRoll = defaultPostRoll
            destination = activeServer?.defaultRecordingDestination ?? .local
        }
        .sheet(isPresented: $showCustomPreRoll) {
            customSheet { preRoll = customValue }
        }
        .sheet(isPresented: $showCustomPostRoll) {
            customSheet { postRoll = customValue }
        }
    }

    // MARK: - Buffer options grid

    @ViewBuilder
    private func bufferOptions(selection: Binding<Int>, options: [Int],
                               customAction: @escaping () -> Void) -> some View {
        ForEach(options, id: \.self) { mins in
            Button {
                selection.wrappedValue = mins
            } label: {
                HStack {
                    Text(mins == 0 ? "None" : "\(mins) min")
                    Spacer()
                    if selection.wrappedValue == mins {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentPrimary)
                    }
                }
            }
            .foregroundColor(.primary)
        }
        Button("Custom…", action: customAction)
    }

    @ViewBuilder
    private func customSheet(onConfirm: @escaping () -> Void) -> some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Stepper("\(customValue) minutes", value: $customValue, in: 1...120)
                #else
                HStack {
                    Text("\(customValue) minutes")
                    Spacer()
                    Button("-") { if customValue > 1 { customValue -= 1 } }
                    Button("+") { if customValue < 120 { customValue += 1 } }
                }
                #endif
            }
            .navigationTitle("Custom Buffer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onConfirm()
                        showCustomPreRoll = false
                        showCustomPostRoll = false
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCustomPreRoll = false
                        showCustomPostRoll = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    /// Resolves the stream URL for local recording using the stream UUID
    /// and the server's current effectiveBaseURL.
    private func resolveStreamURL() -> URL? {
        guard let uuid = streamUUID, !uuid.isEmpty,
              let server = activeServer else { return nil }
        let base = server.effectiveBaseURL.hasSuffix("/")
            ? String(server.effectiveBaseURL.dropLast())
            : server.effectiveBaseURL
        return URL(string: "\(base)/proxy/ts/stream/\(uuid)")
    }

    private var timeLabel: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let tf = DateFormatter()
        tf.timeStyle = .short
        return "\(df.string(from: scheduledStart)) – \(tf.string(from: scheduledEnd))"
    }

    // MARK: - Schedule

    private func scheduleRecording() {
        let rec = Recording(
            channelID: channelID,
            channelName: channelName,
            programTitle: programTitle,
            programDescription: programDescription,
            scheduledStart: isLive ? Date() : scheduledStart,
            scheduledEnd: scheduledEnd,
            preRollMinutes: isLive ? 0 : preRoll,
            postRollMinutes: postRoll,
            destination: destination,
            serverID: activeServer?.id.uuidString ?? "unknown"
        )
        modelContext.insert(rec)
        try? modelContext.save()

        // Kick off the recording
        Task {
            if destination == .dispatcharrServer, let server = activeServer {
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                         auth: .apiKey(server.effectiveApiKey),
                                         userAgent: server.effectiveUserAgent)
                // If user has custom buffers, don't let server double-apply offsets.
                let applyServerOffsets = (preRoll == 0 && postRoll == 0)
                // TODO: resolve Dispatcharr integer channel ID from channelID
                let channelIntID = Int(channelID) ?? 0
                try? await coordinator.scheduleDispatcharrRecording(
                    api: api, recording: rec,
                    channelIntID: channelIntID,
                    applyServerOffsets: applyServerOffsets,
                    comskip: comskip,
                    modelContext: modelContext
                )
            }
            // Local recordings that should start now
            if destination == .local && rec.effectiveStart <= Date() {
                if let url = resolveStreamURL() {
                    await coordinator.startLocalRecording(rec, streamURL: url, modelContext: modelContext)
                } else {
                    rec.status = .failed
                    rec.failureReason = "Could not resolve stream URL for this channel."
                    try? modelContext.save()
                }
            }
        }

        dismiss()
    }
}
