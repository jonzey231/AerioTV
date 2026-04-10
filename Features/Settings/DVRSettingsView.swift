import SwiftUI
import SwiftData

// MARK: - DVR Settings

struct DVRSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [ServerConnection]
    @StateObject private var coordinator = RecordingCoordinator.shared

    // Buffers
    @AppStorage("dvrDefaultPreRollMins") private var defaultPreRoll = 0
    @AppStorage("dvrDefaultPostRollMins") private var defaultPostRoll = 0

    // Storage
    @AppStorage("dvrMaxLocalStorageMB") private var maxStorageMB = 10_240

    // Idle timer
    @AppStorage("dvrKeepAwake") private var keepAwake = true

    // Custom pre/post steppers
    @State private var showCustomPreRoll = false
    @State private var showCustomPostRoll = false
    @State private var customPreRollValue = 5
    @State private var customPostRollValue = 5

    // Deletion confirmation
    @State private var showClearConfirmation = false

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var isDispatcharr: Bool {
        activeServer?.type == .dispatcharrAPI
    }

    var body: some View {
        List {
            // MARK: - Default Buffers
            Section {
                bufferPicker(label: "Start early (pre-roll)",
                             selection: $defaultPreRoll,
                             options: [0, 5, 10, 15, 30],
                             customAction: { showCustomPreRoll = true })
                bufferPicker(label: "End late (post-roll)",
                             selection: $defaultPostRoll,
                             options: [0, 5, 10, 15, 30, 60],
                             customAction: { showCustomPostRoll = true })
            } header: {
                Text("Default Recording Buffers")
                    .sectionHeaderStyle()
            } footer: {
                Text("Applied to new recordings by default. Sports events often run past their scheduled time.")
            }
            .listRowBackground(Color.cardBackground)

            // MARK: - Default Destination (Dispatcharr only)
            if isDispatcharr, let server = activeServer {
                Section {
                    Picker("Default destination", selection: Binding(
                        get: { server.defaultRecordingDestination },
                        set: { server.defaultRecordingDestination = $0; try? modelContext.save() }
                    )) {
                        Text("Dispatcharr server").tag(RecordingDestination.dispatcharrServer)
                        Text("This device").tag(RecordingDestination.local)
                    }
                } header: {
                    Text("Recording Destination")
                        .sectionHeaderStyle()
                } footer: {
                    Text("Server-side recordings are recommended — they continue even when AerioTV is closed.")
                }
                .listRowBackground(Color.cardBackground)
            }

            // MARK: - Local Storage
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum")
                        Spacer()
                        Text(formatGB(mb: maxStorageMB))
                            .foregroundColor(.secondary)
                    }
                    #if os(iOS)
                    Slider(value: Binding(
                        get: { Double(maxStorageMB) / 1024.0 },
                        set: { maxStorageMB = Int($0 * 1024.0) }
                    ), in: 1...200, step: 1) {
                        Text("Max storage")
                    }
                    #else
                    // tvOS: use +/- buttons instead of slider
                    HStack {
                        Button("-") { if maxStorageMB > 1024 { maxStorageMB -= 1024 } }
                        Spacer()
                        Button("+") { if maxStorageMB < 204_800 { maxStorageMB += 1024 } }
                    }
                    #endif
                }

                // Usage bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Used")
                        Spacer()
                        Text(formatBytes(coordinator.localUsageBytes) + " of " + formatGB(mb: maxStorageMB))
                            .foregroundColor(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(usageColor)
                                .frame(width: max(0, geo.size.width * CGFloat(coordinator.localUsageFraction)))
                        }
                    }
                    .frame(height: 8)
                }

                if coordinator.isApproachingQuotaLimit {
                    Label {
                        Text("Storage is running low. Future recordings may not complete if the limit is reached.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                    }
                    .font(.footnote)
                }
            } header: {
                Text("Local Storage")
                    .sectionHeaderStyle()
            }
            .listRowBackground(Color.cardBackground)

            // MARK: - Recording Behavior
            Section {
                Toggle("Keep device awake during recording", isOn: $keepAwake)
            } header: {
                Text("Behavior")
                    .sectionHeaderStyle()
            } footer: {
                Text("When enabled, the screen won't turn off while a local recording is in progress. Recommended to prevent recording interruption.")
            }
            .listRowBackground(Color.cardBackground)

            // MARK: - Recordings folder
            Section {
                HStack {
                    Text("Recordings folder")
                    Spacer()
                    Text(recordingsFolderLabel)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                #if os(iOS)
                Button("Choose custom folder…") {
                    // TODO: Present UIDocumentPickerViewController
                }
                #endif
            } header: {
                Text("Storage Location")
                    .sectionHeaderStyle()
            }
            .listRowBackground(Color.cardBackground)

            // MARK: - My Recordings
            Section {
                NavigationLink(destination: MyRecordingsView()) {
                    SettingsRow(icon: "film.stack", iconColor: .red,
                                title: "My Recordings",
                                subtitle: "\(recordingCount) recordings")
                }
            } header: {
                Text("Recordings")
                    .sectionHeaderStyle()
            }
            .listRowBackground(Color.cardBackground)

            // MARK: - Danger zone
            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Delete All Local Recordings", systemImage: "trash.fill")
                }
            }
            .listRowBackground(Color.cardBackground)
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .background(Color.appBackground)
        .navigationTitle("DVR")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Delete All Local Recordings?", isPresented: $showClearConfirmation) {
            Button("Delete", role: .destructive) { clearAllLocalRecordings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all locally stored recordings from this device. Server-side recordings are not affected.")
        }
        .sheet(isPresented: $showCustomPreRoll) {
            customBufferSheet(title: "Custom Pre-Roll", value: $customPreRollValue) {
                defaultPreRoll = customPreRollValue
            }
        }
        .sheet(isPresented: $showCustomPostRoll) {
            customBufferSheet(title: "Custom Post-Roll", value: $customPostRollValue) {
                defaultPostRoll = customPostRollValue
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func bufferPicker(label: String, selection: Binding<Int>,
                              options: [Int], customAction: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { mins in
                    Button(mins == 0 ? "None" : "\(mins) min") {
                        selection.wrappedValue = mins
                    }
                }
                Divider()
                Button("Custom…", action: customAction)
            } label: {
                Text(selection.wrappedValue == 0 ? "None" : "\(selection.wrappedValue) min")
                    .foregroundColor(.accentPrimary)
            }
        }
    }

    @ViewBuilder
    private func customBufferSheet(title: String, value: Binding<Int>,
                                   onConfirm: @escaping () -> Void) -> some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Stepper("\(value.wrappedValue) minutes", value: value, in: 1...120)
                #else
                HStack {
                    Text("\(value.wrappedValue) minutes")
                    Spacer()
                    Button("-") { if value.wrappedValue > 1 { value.wrappedValue -= 1 } }
                    Button("+") { if value.wrappedValue < 120 { value.wrappedValue += 1 } }
                }
                #endif
            }
            .navigationTitle(title)
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

    private var usageColor: Color {
        let f = coordinator.localUsageFraction
        if f >= 0.95 { return .red }
        if f >= 0.80 { return .yellow }
        return .green
    }

    private var recordingsFolderLabel: String {
        if let custom = coordinator.customRecordingsDirectory {
            return custom.lastPathComponent
        }
        return "Documents/Recordings"
    }

    private var recordingCount: Int {
        let descriptor = FetchDescriptor<Recording>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func clearAllLocalRecordings() {
        if let dir = coordinator.localRecordingsDirectory {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Delete Recording rows that are local
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.destinationRaw == "local" }
        )
        if let rows = try? modelContext.fetch(descriptor) {
            for r in rows { modelContext.delete(r) }
            try? modelContext.save()
        }
    }

    private func formatGB(mb: Int) -> String {
        let gb = Double(mb) / 1024.0
        return String(format: "%.0f GB", gb)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
