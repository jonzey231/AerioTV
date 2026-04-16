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

    // Folder picker
    @State private var showFolderPicker = false

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var isDispatcharr: Bool {
        activeServer?.type == .dispatcharrAPI
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
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
        #if os(iOS)
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView { url in
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(bookmark, forKey: "dvrCustomFolderBookmark")
                }
            }
        }
        #endif
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
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
                    Slider(value: Binding(
                        get: { Double(maxStorageMB) / 1024.0 },
                        set: { maxStorageMB = Int($0 * 1024.0) }
                    ), in: 1...200, step: 1) {
                        Text("Max storage")
                    }
                }

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
            if !isDispatcharr || activeServer?.defaultRecordingDestination != .dispatcharrServer {
                Section {
                    HStack {
                        Text("Recordings folder")
                        Spacer()
                        Text(recordingsFolderLabel)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Button("Choose custom folder…") {
                        showFolderPicker = true
                    }
                } header: {
                    Text("Storage Location")
                        .sectionHeaderStyle()
                }
                .listRowBackground(Color.cardBackground)
            }

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
        .scrollContentBackground(.hidden)
    }
    #endif

    // MARK: - tvOS Body
    // Uses the shared TVSettings* components (TVSettingsSelectionRow,
    // TVSettingsToggleRow, TVSettingsActionRow, TVSettingsNavRow) so focus
    // highlight matches the rest of the tvOS Settings UI uniformly.
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvSection("Start Early (Pre-Roll)") {
                    ForEach([0, 5, 10, 15, 30], id: \.self) { mins in
                        TVSettingsSelectionRow(
                            label: mins == 0 ? "None" : "\(mins) minutes",
                            isSelected: defaultPreRoll == mins,
                            action: { defaultPreRoll = mins }
                        )
                    }
                    TVSettingsActionRow(
                        icon: "slider.horizontal.3",
                        label: "Custom…",
                        isAccent: ![0, 5, 10, 15, 30].contains(defaultPreRoll),
                        action: {
                            customPreRollValue = defaultPreRoll > 0 ? defaultPreRoll : 5
                            showCustomPreRoll = true
                        }
                    )
                }

                tvSection("End Late (Post-Roll)") {
                    ForEach([0, 5, 10, 15, 30, 60], id: \.self) { mins in
                        TVSettingsSelectionRow(
                            label: mins == 0 ? "None" : "\(mins) minutes",
                            isSelected: defaultPostRoll == mins,
                            action: { defaultPostRoll = mins }
                        )
                    }
                    TVSettingsActionRow(
                        icon: "slider.horizontal.3",
                        label: "Custom…",
                        isAccent: ![0, 5, 10, 15, 30, 60].contains(defaultPostRoll),
                        action: {
                            customPostRollValue = defaultPostRoll > 0 ? defaultPostRoll : 5
                            showCustomPostRoll = true
                        }
                    )
                }

                if isDispatcharr, let server = activeServer {
                    tvSection("Recording Destination") {
                        TVSettingsSelectionRow(
                            icon: "server.rack",
                            label: "Dispatcharr server",
                            subtitle: "Keeps recording even when AerioTV is closed",
                            isSelected: server.defaultRecordingDestination == .dispatcharrServer,
                            action: {
                                server.defaultRecordingDestination = .dispatcharrServer
                                try? modelContext.save()
                            }
                        )
                        TVSettingsSelectionRow(
                            icon: "internaldrive",
                            label: "This device",
                            subtitle: "Requires AerioTV to remain open",
                            isSelected: server.defaultRecordingDestination == .local,
                            action: {
                                server.defaultRecordingDestination = .local
                                try? modelContext.save()
                            }
                        )
                    }
                }

                tvSection("Local Storage") {
                    tvStorageCard
                }

                tvSection("Behavior") {
                    TVSettingsToggleRow(
                        icon: "bolt.fill",
                        iconColor: .yellow,
                        title: "Keep Device Awake",
                        subtitle: "Prevents sleep during local recording",
                        isOn: $keepAwake
                    ) { _ in }
                }

                tvSection("Recordings") {
                    TVSettingsNavRow(destination: MyRecordingsView()) {
                        SettingsRow(icon: "film.stack", iconColor: .red,
                                    title: "My Recordings",
                                    subtitle: "\(recordingCount) recordings")
                    }
                }

                tvSection("Danger Zone") {
                    TVSettingsActionRow(
                        icon: "trash.fill",
                        label: "Delete All Local Recordings",
                        isDestructive: true,
                        action: { showClearConfirmation = true }
                    )
                }
            }
            .padding(48)
        }
    }

    private var tvStorageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Maximum")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.textPrimary)
                Spacer()
                HStack(spacing: 24) {
                    Button { if maxStorageMB > 1024 { maxStorageMB -= 1024 } } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(TVNoHighlightButtonStyle())
                    Text(formatGB(mb: maxStorageMB))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .frame(minWidth: 110)
                    Button { if maxStorageMB < 204_800 { maxStorageMB += 1024 } } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(TVNoHighlightButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Used")
                        .font(.system(size: 22))
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text(formatBytes(coordinator.localUsageBytes) + " of " + formatGB(mb: maxStorageMB))
                        .font(.system(size: 22))
                        .foregroundColor(.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.2))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(usageColor)
                            .frame(width: max(0, geo.size.width * CGFloat(coordinator.localUsageFraction)))
                    }
                }
                .frame(height: 12)
            }

            if coordinator.isApproachingQuotaLimit {
                Label {
                    Text("Storage is running low. Future recordings may not complete if the limit is reached.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                }
                .font(.system(size: 22))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentPrimary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func tvSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.textTertiary)
                .tracking(1)
                .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }
    #endif

    // MARK: - Helpers

    #if os(iOS)
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
    #endif

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

// MARK: - Folder Picker (iOS only)
#if os(iOS)
import UniformTypeIdentifiers

struct FolderPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif
