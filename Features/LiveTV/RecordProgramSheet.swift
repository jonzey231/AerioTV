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

    @AppStorage("dvrDefaultPreRollMins") private var defaultPreRoll = 0
    @AppStorage("dvrDefaultPostRollMins") private var defaultPostRoll = 0

    @State private var preRoll: Int = 0
    @State private var postRoll: Int = 0
    @State private var destination: RecordingDestination = .local
    @State private var showCustomPreRoll = false
    @State private var showCustomPostRoll = false
    @State private var customValue = 5
    // Dispatcharr-only: ask the server to run comskip (commercial
    // detection/removal) after the recording completes. Only meaningful
    // when destination == .dispatcharrServer; ignored for local.
    @State private var comskip = false

    @StateObject private var coordinator = RecordingCoordinator.shared

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var isDispatcharr: Bool {
        activeServer?.type == .dispatcharrAPI
    }

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSForm
            #else
            iOSForm
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
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

    // MARK: - iOS Form

    #if os(iOS)
    private var iOSForm: some View {
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

            // Comskip (Dispatcharr server-side only — local doesn't run it)
            if isDispatcharr && destination == .dispatcharrServer {
                Section {
                    Toggle("Remove commercials (Comskip)", isOn: $comskip)
                } footer: {
                    Text("Automatically detect and remove commercial breaks after the recording completes. Processed server-side.")
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
        .navigationBarTitleDisplayMode(.inline)
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
    #endif

    // MARK: - tvOS Form
    // Presented inside a .fullScreenCover so the content has real estate.
    // Form was dropped entirely because:
    //   1. Its default scroll-content background is translucent on tvOS,
    //      which left the EPG grid bleeding through the record sheet.
    //   2. Focused Form rows paint a screen-wide white halo that hides
    //      both the option being selected and its neighbours.
    // Replaced with a hand-rolled layout using RecordOptionPill /
    // RecordActionPill — same focus pattern as the Live TV group bar.
    #if os(tvOS)
    private var tvOSForm: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isLive ? "Record from Now" : "Record Program")
                    .font(.system(size: 42, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
            .padding(.bottom, 32)

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    programInfoCard

                    if !isLive {
                        optionRow(
                            title: "Start Early",
                            options: [0, 5, 10, 15, 30],
                            selection: $preRoll,
                            label: { $0 == 0 ? "None" : "\($0) min" }
                        )
                    }

                    optionRow(
                        title: "End Late",
                        options: [0, 5, 10, 15, 30, 60],
                        selection: $postRoll,
                        label: { $0 == 0 ? "None" : "\($0) min" }
                    )

                    if isDispatcharr {
                        destinationRow
                    }

                    if isDispatcharr && destination == .dispatcharrServer {
                        comskipRow
                    }

                    if destination == .local {
                        warningsBox
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 40)
            }

            // .focusSection() so pressing down from the last option row
            // (e.g. Destination) lands on the action bar even though
            // nothing sits directly below the currently-focused pill.
            HStack(spacing: 32) {
                Spacer()
                RecordActionPill(
                    label: "Cancel",
                    systemImage: "xmark",
                    tintColor: .textSecondary,
                    action: { dismiss() }
                )
                RecordActionPill(
                    label: "Record",
                    systemImage: "record.circle",
                    tintColor: .red,
                    action: { scheduleRecording() }
                )
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 32)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
    }

    // MARK: - tvOS Row Builders

    private var programInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            tvInfoRow("Program", programTitle)
            tvInfoRow("Channel", channelName)
            tvInfoRow("Time", timeLabel)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.elevatedBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func tvInfoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(label)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.textSecondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(.system(size: 22))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }

    private func optionRow(title: String,
                           options: [Int],
                           selection: Binding<Int>,
                           label: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .padding(.leading, 4)
            // .focusSection() lets the Siri Remote's up/down gesture jump
            // between rows regardless of the focused pill's horizontal
            // position. Without it, pressing down on "60 min" does nothing
            // because no focusable sits directly below it.
            HStack(spacing: 12) {
                ForEach(options, id: \.self) { opt in
                    RecordOptionPill(
                        label: label(opt),
                        isSelected: selection.wrappedValue == opt,
                        action: { selection.wrappedValue = opt }
                    )
                }
                Spacer(minLength: 0)
            }
            .focusSection()
        }
    }

    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Destination")
                .font(.system(size: 24, weight: .semibold))
                .padding(.leading, 4)
            HStack(spacing: 12) {
                RecordOptionPill(
                    label: "Dispatcharr server",
                    isSelected: destination == .dispatcharrServer,
                    action: { destination = .dispatcharrServer }
                )
                RecordOptionPill(
                    label: "This device",
                    isSelected: destination == .local,
                    action: { destination = .local }
                )
                Spacer(minLength: 0)
            }
            .focusSection()
        }
    }

    /// Dispatcharr-only comskip toggle rendered as two pills
    /// (On / Off) so it matches the rest of the tvOS record sheet's
    /// pill-selector UI instead of introducing a stray switch control.
    private var comskipRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove Commercials (Comskip)")
                .font(.system(size: 24, weight: .semibold))
                .padding(.leading, 4)
            HStack(spacing: 12) {
                RecordOptionPill(
                    label: "Off",
                    isSelected: !comskip,
                    action: { comskip = false }
                )
                RecordOptionPill(
                    label: "On",
                    isSelected: comskip,
                    action: { comskip = true }
                )
                Spacer(minLength: 0)
            }
            .focusSection()
            Text("Server-side: detects and removes commercial breaks after the recording completes.")
                .font(.system(size: 18))
                .foregroundColor(.textSecondary)
                .padding(.leading, 4)
                .padding(.top, 2)
        }
    }

    private var warningsBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Keep AerioTV open — closing the app will stop this recording.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
            }
            if coordinator.isApproachingQuotaLimit {
                Label {
                    Text("Storage is running low. This recording may not finish if the limit is reached.")
                } icon: {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundColor(.orange)
                }
            }
        }
        .font(.system(size: 22))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.elevatedBackground, in: RoundedRectangle(cornerRadius: 16))
    }
    #endif

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
            // (for future programs, a scheduler will need to trigger at effectiveStart)
            if destination == .local && rec.effectiveStart <= Date() {
                // TODO: resolve stream URL from channel
                // await coordinator.startLocalRecording(rec, streamURL: url, modelContext: modelContext)
            }
        }

        dismiss()
    }
}

// MARK: - tvOS Option Pill

#if os(tvOS)
/// Segmented-style pill used for each option in the Pre-roll, Post-roll,
/// and Destination rows. Matches `DVRSegmentPill` / `TVGroupPill`:
/// accent-fill when selected, stroke + scale bump on focus, subtle
/// opacity drop when neither selected nor focused.
///
/// Uses `Button + ButtonStyle` (not bare `.focusable + .onTapGesture`)
/// because the latter combination causes UIKit's focus engine to
/// insert a `_UIReplicantView` into SwiftUI's UIHostingController.view,
/// which prints a console warning.
private struct RecordOptionPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
        }
        .buttonStyle(RecordOptionPillButtonStyle(isSelected: isSelected))
    }
}

private struct RecordOptionPillButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .font(.system(size: 22, weight: .medium))
            .foregroundColor(isSelected ? .appBackground : (focused ? .white : .textSecondary))
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentPrimary : Color.elevatedBackground)
            )
            .overlay(
                Capsule()
                    .stroke(focused && !isSelected ? Color.accentPrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .opacity(focused ? 1.0 : (isSelected ? 1.0 : 0.85))
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif

// MARK: - tvOS Action Pill

#if os(tvOS)
/// Record/Cancel buttons for the tvOS Record sheet. Same rationale as
/// `RecordOptionPill` above — Button + ButtonStyle avoids the
/// `_UIReplicantView` warning that `.focusable + .onTapGesture`
/// produces, while still giving us a custom focus effect.
private struct RecordActionPill: View {
    let label: String
    let systemImage: String
    let tintColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(label)
            }
        }
        .buttonStyle(RecordActionPillButtonStyle(tintColor: tintColor))
    }
}

private struct RecordActionPillButtonStyle: ButtonStyle {
    let tintColor: Color
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(focused ? .white : tintColor)
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(
                Capsule()
                    .fill(focused ? tintColor : Color.elevatedBackground)
            )
            .overlay(
                Capsule()
                    .stroke(tintColor, lineWidth: focused ? 0 : 2)
            )
            .scaleEffect(focused ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif
