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
        .alert("Delete All Recordings?", isPresented: $showClearConfirmation) {
            Button("Delete Finished", role: .destructive) {
                Task { await clearLocalRecordings(includingInProgress: false) }
            }
            if inProgressLocalCount > 0 {
                Button("Delete All Including In-Progress", role: .destructive) {
                    Task { await clearLocalRecordings(includingInProgress: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = inProgressLocalCount
            Text("Finished recordings will be deleted."
                 + (n > 0 ? " \(n) in-progress recordings can also be stopped and deleted." : ""))
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
                SettingsChoicePicker("Start Early (Pre-Roll)",
                                     options: bufferOptions(preRollStops, current: defaultPreRoll),
                                     selection: $defaultPreRoll)
                customBufferRow(isCustom: !preRollStops.contains(defaultPreRoll)) {
                    customPreRollValue = defaultPreRoll > 0 ? defaultPreRoll : 5
                    showCustomPreRoll = true
                }

                SettingsChoicePicker("End Late (Post-Roll)",
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
                        "Default Destination",
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
                    // 0.25 GB steps (owner 2026-11-13), snapped in the binding:
                    // a `step:` makes iOS 26 draw a tick per step, which at
                    // this density ran together into a grey line under the
                    // track (Logan's iPhone screenshot, build e8d7cb2).
                    Slider(value: Binding(
                        get: { Double(maxStorageMB) / 1024.0 },
                        set: { maxStorageMB = DVRStorageCapRules.snappedMB(gb: $0) }
                    ), in: 1...200) {
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
                Toggle("Keep Device Awake During Recording", isOn: $keepAwake)
            } header: {
                Text("Behavior")
                    .sectionHeaderStyle()
            } footer: {
                Text("When enabled, the screen won't turn off while a local recording is in progress. Recommended to prevent recording interruption.")
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
        #if os(iOS)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        #endif
    }
    #endif

    // MARK: - tvOS Body
    // Uses the shared TVSettings* components (TVSettingsSelectionRow,
    // TVSettingsToggleRow, TVSettingsActionRow, TVSettingsNavRow) so focus
    // highlight matches the rest of the tvOS Settings UI uniformly.
    #if os(tvOS)
    private var tvOSBody: some View {
        TVSettingsPane(spacing: 32) {
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
                    title: "Start Early (Pre-Roll)",
                    stops: preRollStops,
                    value: $defaultPreRoll,
                    label: bufferStepperLabel,
                    decreaseLabel: "Less pre-roll",
                    increaseLabel: "More pre-roll"
                )
                TVSettingsStepperRow(
                    title: "End Late (Post-Roll)",
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
                        "Default Destination",
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
                    iconColor: theme.accent,
                    title: "Keep Device Awake",
                    subtitle: "Prevents sleep during local recording",
                    isOn: $keepAwake
                ) { _ in }
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
    }

    private var tvStorageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Maximum")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                // Left and Right adjust it in 0.25 GB steps; held, they repeat
                // and speed up (owner 2026-11-13).
                TVStorageCapAdjuster(valueMB: $maxStorageMB)
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
            SettingsChoice(.dispatcharrServer, "Dispatcharr Server",
                           subtitle: "Keeps recording even when AerioTV is closed",
                           icon: "server.rack"),
            SettingsChoice(.local, "This Device",
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
        #if os(iOS)
        // Phase 3: one stepper does not need a full-height sheet on iPhone.
        // Sized to its content, with .medium as the fallback stop. tvOS has
        // no sheet detents, so this stays inside the iOS branch.
        .presentationDetents([.height(180), .medium])
        .presentationDragIndicator(.visible)
        #endif
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

    private func localRecordingRows() -> [Recording] {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.destinationRaw == "local" }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Local recordings currently being written. Read when the confirmation
    /// renders, so the count and the extra button match the moment of asking.
    private var inProgressLocalCount: Int {
        localRecordingRows().filter { $0.isInProgress }.count
    }

    /// Deletes finished local recordings (anything not recording and not
    /// scheduled). Scheduled rows are always kept. With
    /// `includingInProgress`, recordings being written are stopped first and
    /// deleted too. Files in the recordings folder that no kept row points
    /// at are removed, as the old wipe-the-folder version did.
    private func clearLocalRecordings(includingInProgress: Bool) async {
        let rows = localRecordingRows()
        // Save to Device copies of server recordings, with their locations
        // resolved now, while the files still exist (the same resolution the
        // sweep below uses on the folder's files).
        let copies = deviceCopyRows().compactMap { r in
            r.resolvedLocalFilePath.map { (row: r, path: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
        }
        var keepPaths = Set<String>()
        for r in rows {
            if r.isUpcoming {
                if let p = r.resolvedLocalFilePath { keepPaths.insert(URL(fileURLWithPath: p).resolvingSymlinksInPath().path) }
                continue
            }
            if r.isInProgress {
                guard includingInProgress else {
                    if let p = r.resolvedLocalFilePath { keepPaths.insert(URL(fileURLWithPath: p).resolvingSymlinksInPath().path) }
                    continue
                }
                await coordinator.stopLocalRecording(r, modelContext: modelContext)
            }
            coordinator.deleteLocalRecording(r, modelContext: modelContext)
        }
        var removed = Set<String>()
        if let dir = coordinator.localRecordingsDirectory, isInsideAppSandbox(dir),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files {
                let p = f.resolvingSymlinksInPath().path
                guard !keepPaths.contains(p) else { continue }
                if (try? FileManager.default.removeItem(at: f)) != nil { removed.insert(p) }
            }
        }
        // The sweep removed those copies' files: the rows stay (the server's
        // recording is untouched) without a device copy, so nothing points
        // at a deleted file (DeviceCopySweep).
        let cleared = Set(DeviceCopySweep.clearedCopies(copies.map { (id: $0.row.id, path: $0.path) },
                                                        removedPaths: removed))
        for c in copies where cleared.contains(c.row.id) {
            c.row.localFilePath = nil
            c.row.fileSizeBytes = 0
        }
        if !cleared.isEmpty { try? modelContext.save() }
        debugLog("[DVR] Delete All Local Recordings: removed \(removed.count) file(s); cleared the device copy on \(cleared.count) of \(copies.count) server recording(s) saved to this device")
    }

    /// Server recordings with a copy saved on this device.
    private func deviceCopyRows() -> [Recording] {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.destinationRaw != "local" && $0.localFilePath != nil }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
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

    /// "10 GB", "10.25 GB": DVRStorageCapRules.label (the locale's decimal separator).
    private func formatGB(mb: Int) -> String { DVRStorageCapRules.label(mb: mb) }

    private func formatBytes(_ bytes: Int64) -> String {
        // ByteCountFormatter spells nothing as "Zero KB", which reads like a
        // bug next to "of 10 GB". An empty library is "0 KB" (Phase 3).
        guard bytes > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
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

#if os(tvOS)
/// Settings > DVR > Maximum on Apple TV: the value between a left and a
/// right chevron, adjusted with Left and Right. A press moves 0.25 GB; held,
/// it repeats after 0.4 s every 0.1 s, at 0.25 GB for 8 repeats, then 1 GB
/// for 12, then 5 GB (DVRStorageCapRules.holdStepMB), so 10 to 100 GB takes
/// about 4 s. A swipe is one step. Up and Down still move focus.
private struct TVStorageCapAdjuster: View {
    @Binding var valueMB: Int
    @State private var isFocused = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "chevron.left")
                .font(.system(size: 22, weight: .semibold))
                .opacity(valueMB <= DVRStorageCapRules.minMB ? 0.25 : 0.8)
            Text(DVRStorageCapRules.label(mb: valueMB))
                .scaledFont(.system(size: 28, weight: .semibold).monospacedDigit())
                .frame(minWidth: 150)
            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .semibold))
                .opacity(valueMB >= DVRStorageCapRules.maxMB ? 0.25 : 0.8)
        }
        .foregroundColor(isFocused ? Color.contrastText(.accentPrimary) : .textPrimary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(isFocused ? Color.accentPrimary.opacity(0.12) : Color.elevatedBackground)
        )
        .overlay(
            Capsule().strokeBorder(Color.accentPrimary, lineWidth: isFocused ? SettingsMetrics.tvFocusRingWidth : 0)
        )
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .settingsRowFocusLog("DVR Maximum", isFocused: isFocused)
        .overlay(
            TVPressOverlay(
                isFocused: $isFocused,
                canFocus: true,
                interceptsDirectional: true,
                horizontalAdjustOnly: true,
                onTap: {},
                onLongPress: {},
                onMoveLeft: { begin(up: false) },
                onMoveRight: { begin(up: true) },
                onHorizontalRelease: { end() }
            )
        )
        .onChange(of: isFocused) { _, focused in if !focused { end() } }
        .onDisappear { end() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Maximum")
        .accessibilityValue(DVRStorageCapRules.label(mb: valueMB))
    }

    private func adjust(up: Bool, _ n: Int) {
        valueMB = DVRStorageCapRules.stepped(valueMB, by: DVRStorageCapRules.holdStepMB(n), up: up)
    }

    private func begin(up: Bool) {
        repeatTask?.cancel()
        adjust(up: up, 0)
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            var n = 1
            // Capped (about 40 s) in case a release never arrives.
            while !Task.isCancelled && n < 400 {
                adjust(up: up, n)
                n += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func end() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
#endif
