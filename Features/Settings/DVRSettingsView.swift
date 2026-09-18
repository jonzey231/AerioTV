import SwiftUI
import SwiftData

// MARK: - DVR Settings

struct DVRSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [ServerConnection]
    @StateObject private var coordinator = RecordingCoordinator.shared
    /// See SettingsView. Without this, accent-tinted icons and
    /// destructive-action buttons freeze at the theme that was
    /// active when DVRSettingsView was first pushed.
    @ObservedObject private var theme = ThemeManager.shared

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

    /// Whether the active Dispatcharr account may record to the server.
    /// Derived from the probed per-user capability (DVR "manage"), NOT
    /// from the raw level: an admin can grant manage to a level-1 account
    /// and can set "view" on a level-1 account, and both cases were wrong
    /// under the old level test. UNKNOWN (never probed, or the probe
    /// failed) shows the destination and lets the server answer.
    private var canRecordToServer: Bool {
        activeServer?.dispatcharrCanRecordToServer ?? true
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
        #else
        // Pane views own their layout; without this the nav bar renders a
        // "DVR" header inside the pane and shifts the content down.
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .alert("Delete All Local Recordings?", isPresented: $showClearConfirmation) {
            Button("Delete", role: .destructive) { clearAllLocalRecordings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all locally stored recordings from this device. Server-side recordings are not affected.")
        }
        #if os(iOS)
        // iOS only: the TV steps through the stops instead, so nothing
        // there opens these.
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
                // Phase 3, item 3: the buffer Menus became SettingsChoicePickers.
                // The picker only renders a fixed list, so "Custom…" stays as
                // its own row directly underneath, exactly as before.
                SettingsChoicePicker("Start early (pre-roll)",
                                     options: bufferOptions(preRollStops, current: defaultPreRoll),
                                     selection: $defaultPreRoll)
                customBufferRow(isCustom: !preRollStops.contains(defaultPreRoll)) {
                    customPreRollValue = defaultPreRoll > 0 ? defaultPreRoll : 5
                    showCustomPreRoll = true
                }

                SettingsChoicePicker("End late (post-roll)",
                                     options: bufferOptions(postRollStops, current: defaultPostRoll),
                                     selection: $defaultPostRoll)
                customBufferRow(isCustom: !postRollStops.contains(defaultPostRoll)) {
                    customPostRollValue = defaultPostRoll > 0 ? defaultPostRoll : 5
                    showCustomPostRoll = true
                }
            } header: {
                Text("Default Recording Buffers")
                    .sectionHeaderStyle()
            } footer: {
                Text("Applied to new recordings by default. Sports events often run past their scheduled time.")
            }
            .listRowBackground(Color.cardBackground)

            // MARK: - Default Destination (Dispatcharr only)
            // v1.7.x: hidden for non-admin Dispatcharr accounts. They
            // can't record to the server, so local is the only path and
            // there's no destination choice to present.
            if isDispatcharr, canRecordToServer, let server = activeServer {
                Section {
                    // Phase 3, item 3: was a native menu Picker; now the shared
                    // picker, carrying the icons and subtitles tvOS already had.
                    // The SwiftData write stays in onChange so the save travels
                    // with it.
                    SettingsChoicePicker(
                        "Default destination",
                        options: destinationOptions,
                        selection: Binding(
                            get: { server.defaultRecordingDestination },
                            set: { server.defaultRecordingDestination = $0 }
                        ),
                        onChange: { _ in try? modelContext.save() }
                    )
                } header: {
                    Text("Recording Destination")
                        .sectionHeaderStyle()
                } footer: {
                    Text("Server-side recordings are recommended: they continue even when AerioTV is closed.")
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
                    .scaledFont(.footnote)
                }
            } header: {
                Text("Local Storage")
                    .sectionHeaderStyle()
            }
            .listRowBackground(Color.cardBackground)

            // MARK: - Recordings folder
            // v1.7.x: also shown when the account can't record to the
            // server (non-admin); recordings then go local regardless
            // of the stored default destination, so the local folder is
            // relevant.
            if !isDispatcharr || !canRecordToServer || activeServer?.defaultRecordingDestination != .dispatcharrServer {
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

            // MARK: - Danger Zone
            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Delete All Local Recordings", systemImage: "trash.fill")
                }
            } header: {
                Text("Danger Zone").sectionHeaderStyle()
            } footer: {
                Text("Deletes every recording saved on this device. Server recordings on Dispatcharr are not affected.")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
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
                // Logan 2026-09-17: six check rows plus a Custom row,
                // twice, was most of this page for a question that is
                // "how many minutes". Both are one stepper now, shaped
                // like the Appearance page's Text Size row. The TV drops
                // the Custom escape hatch entirely: entering an
                // arbitrary number on a remote is worse than picking a
                // stop, and a custom value set on the phone still syncs
                // here, still displays, and survives until stepped away.
                // iOS keeps its picker page and its Custom row. Android
                // gets the identical stepper.
                // One section, as on iOS: two steppers no longer need a
                // heading each, and a heading that just repeats the row
                // beneath it says the same thing twice.
                SettingsSection("Default Recording Buffers", style: .plain) {
                    TVSettingsStepperRow(
                        title: "Start early (pre-roll)",
                        stops: preRollStops,
                        value: $defaultPreRoll,
                        label: bufferStepperLabel,
                        decreaseLabel: "Less pre-roll",
                        increaseLabel: "More pre-roll"
                    )
                    TVSettingsStepperRow(
                        title: "End late (post-roll)",
                        stops: postRollStops,
                        value: $defaultPostRoll,
                        label: bufferStepperLabel,
                        decreaseLabel: "Less post-roll",
                        increaseLabel: "More post-roll"
                    )
                    Text("Applied to new recordings by default. Sports events often run past their scheduled time.")
                        .scaledFont(.system(size: SettingsMetrics.tvFootnoteSize).subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isDispatcharr, canRecordToServer, let server = activeServer {
                    SettingsSection("Recording Destination", style: .plain) {
                        // Phase 3, item 3: same option list as iOS now.
                        SettingsChoicePicker(
                            "Default destination",
                            options: destinationOptions,
                            selection: Binding(
                                get: { server.defaultRecordingDestination },
                                set: { server.defaultRecordingDestination = $0 }
                            ),
                            onChange: { _ in try? modelContext.save() }
                        )
                    }
                }

                SettingsSection("Local Storage", style: .plain) {
                    tvStorageCard
                    // tvOS treats all app storage as purgeable: under
                    // severe storage pressure the system can evict app
                    // data, recordings included. Disclose it rather than
                    // let a vanished recording look like an app bug.
                    Text("Recordings are stored on this Apple TV. If the system runs critically low on space, tvOS may remove stored app data, including recordings. For must-keep recordings, use a Dispatcharr server destination.")
                        .scaledFont(.system(size: 22).subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }

                SettingsSection("Behavior", style: .plain) {
                    TVSettingsToggleRow(
                        icon: "bolt.fill",
                        iconColor: .yellow,
                        title: "Keep Device Awake",
                        subtitle: "Prevents sleep during local recording",
                        isOn: $keepAwake
                    ) { _ in }
                }

                SettingsSection("Recordings", style: .plain) {
                    TVSettingsNavRow(destination: MyRecordingsView().trackedAsClassicSettingsChild()) {
                        SettingsRow(icon: "film.stack", iconColor: .red,
                                    title: "My Recordings",
                                    subtitle: "\(recordingCount) recordings")
                    }
                }

                SettingsSection("Danger Zone", style: .plain) {
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
                    .scaledFont(.system(size: 26, weight: .medium))
                    .foregroundColor(.textPrimary)
                Spacer()
                HStack(spacing: 24) {
                    Button { if maxStorageMB > 1024 { maxStorageMB -= 1024 } } label: {
                        Image(systemName: "minus.circle.fill")
                            .scaledFont(.system(size: 36))
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(TVNoHighlightButtonStyle())
                    Text(formatGB(mb: maxStorageMB))
                        .scaledFont(.system(size: 28, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .frame(minWidth: 110)
                    Button { if maxStorageMB < 204_800 { maxStorageMB += 1024 } } label: {
                        Image(systemName: "plus.circle.fill")
                            .scaledFont(.system(size: 36))
                            .foregroundColor(.accentPrimary)
                    }
                    .buttonStyle(TVNoHighlightButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Used")
                        .scaledFont(.system(size: 22).subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                    Spacer()
                    Text(formatBytes(coordinator.localUsageBytes) + " of " + formatGB(mb: maxStorageMB))
                        .scaledFont(.system(size: 22).subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
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
                .scaledFont(.system(size: 22))
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

    #endif

    // MARK: - Helpers

    /// The fixed buffer stops. Named so both platforms and the "Custom…"
    /// highlight test share one list (Phase 3).
    private var preRollStops: [Int] { [0, 5, 10, 15, 30, 60] }
    private var postRollStops: [Int] { [0, 5, 10, 15, 30, 60] }

    /// The compact spelling for the tvOS stepper, where the value sits
    /// between a minus and a plus and has to stay on one line. The iOS
    /// picker page keeps the long form ("5 minutes"), which has room.
    private func bufferStepperLabel(_ mins: Int) -> String {
        mins == 0 ? "None" : "\(mins) min"
    }

    /// Buffer choices, with the stored value appended when it is a custom
    /// number. Without that the collapsed iOS row would read "Not set" for
    /// a perfectly valid 20-minute pre-roll (Phase 3).
    private func bufferOptions(_ stops: [Int], current: Int) -> [SettingsChoice<Int>] {
        var options = stops.map { SettingsChoice($0, $0 == 0 ? "None" : "\($0) minutes") }
        if !stops.contains(current) {
            options.append(SettingsChoice(current, "\(current) minutes"))
        }
        return options
    }

    /// Recording destinations. Phase 3 gave iOS the icons and subtitles that
    /// only tvOS used to show.
    private var destinationOptions: [SettingsChoice<RecordingDestination>] {
        [
            SettingsChoice(.dispatcharrServer, "Dispatcharr server",
                           subtitle: "Keeps recording even when AerioTV is closed",
                           icon: "server.rack"),
            SettingsChoice(.local, "This device",
                           subtitle: "Requires AerioTV to remain open",
                           icon: "internaldrive"),
        ]
    }

    #if os(iOS)
    /// The "Custom…" escape hatch, now a row of its own under the picker.
    /// Accent-tinted while the stored value is off the fixed stops, matching
    /// the tvOS action row (Phase 3).
    @ViewBuilder
    private func customBufferRow(isCustom: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .scaledFont(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(width: 22)
                Text("Custom…")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(isCustom ? Color.contrastText(.accentPrimary) : .textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
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
        if let dir = coordinator.localRecordingsDirectory,
           isInsideAppSandbox(dir) {
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

    /// Defensive guard: only allow bulk-delete when the resolved directory is
    /// actually inside this app's data container. Prevents a corrupted
    /// bookmark or unexpected symlink from nuking something outside the
    /// sandbox. Scoped to the container root (Documents' parent), not
    /// Documents itself: the default recordings dir lives under Documents
    /// on iOS but under Caches on tvOS (the only writable large-file
    /// location there), and a Documents-only check turned tvOS delete-all
    /// into a silent no-op.
    private func isInsideAppSandbox(_ url: URL) -> Bool {
        guard let docs = try? FileManager.default.url(for: .documentDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil,
                                                       create: false) else { return false }
        let container = docs.deletingLastPathComponent()
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = container.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.hasPrefix(base)
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
