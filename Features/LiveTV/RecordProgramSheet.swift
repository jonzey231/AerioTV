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
    /// Dispatcharr-only: the numeric channel ID for the Dispatcharr
    /// recording API. `nil` for M3U / Xtream channels, or for
    /// Dispatcharr channels that haven't loaded a numeric ID yet.
    /// v1.6.8 (Codex A2) — replaces the prior `Int(channelID) ?? 0`
    /// fallback, which silently sent `0` to Dispatcharr's recording
    /// endpoint when the string `channelID` wasn't parseable. Now the
    /// "Record on Server" path is hard-disabled when this is nil so
    /// the user gets a clear error path instead of a corrupted
    /// recording schedule.
    var dispatcharrChannelID: Int? = nil
    /// The channel's playable stream URL. v1.6.8 (B1 Phase 1):
    /// added so the local-recording path can hand a URL to
    /// `RecordingCoordinator.startLocalRecording(_:streamURL:modelContext:)`
    /// without needing to look the channel up again. `nil` is
    /// tolerated (the Local destination row is then disabled),
    /// but every UI surface that presents this sheet now passes
    /// `ChannelDisplayItem.streamURL` through.
    var streamURL: URL? = nil

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

    /// Whether the connected Dispatcharr account may record to the
    /// server (POST /api/channels/recordings/ requires IsAdmin =
    /// user_level >= 10). A Standard / Streamer account gets HTTP 403,
    /// so we hide the "Dispatcharr server" destination and force local.
    /// Non-Dispatcharr servers report `true` (they never touch this
    /// endpoint). Defaults to `true` when there's no active server.
    private var canRecordToServer: Bool {
        activeServer?.dispatcharrCanRecordToServer ?? true
    }

    /// True when this sheet can't produce any recording for the
    /// connected account, so the Record button must be disabled /
    /// hidden and an explainer shown. Two cases:
    ///   1. Future program on a non-Dispatcharr playlist (the existing
    ///      case; AerioTV can't auto-start a future local recording).
    ///   2. Future program on a Dispatcharr server where the user
    ///      isn't an admin (server scheduling 403s, and a future local
    ///      recording can't auto-start either).
    /// Live programs always have a path (local recording starts
    /// immediately while foregrounded), so this is never true for
    /// `isLive`.
    private var hasNoRecordingPath: Bool {
        guard !isLive else { return false }
        if !isDispatcharr { return true }
        return !canRecordToServer
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
            // v1.6.22 fix (Codex finding 1): future recordings on
            // Dispatcharr playlists are forced to `.dispatcharrServer`.
            // AerioTV doesn't run iOS background tasks for DVR;
            // there's no path to wake the app at the scheduled
            // start time, so a future `.local` row would be
            // permanently stuck as `.scheduled` and never start.
            // Previously the picker still offered "This device"
            // for future programs, creating an impossible state
            // the user couldn't recover from. For live programs
            // ("Record from Now"), both destinations remain valid
            // because the recording starts immediately while the
            // app is foregrounded.
            if isLive {
                // v1.7.x: a non-admin Dispatcharr account can't record
                // to the server (403), so force local for live programs
                // (the only valid path) and the picker hides the server
                // option. canRecordToServer is true for non-Dispatcharr
                // and admin servers, so their default is unchanged.
                if !canRecordToServer {
                    destination = .local
                } else {
                    destination = activeServer?.defaultRecordingDestination ?? .local
                }
            } else {
                destination = .dispatcharrServer
            }
        }
        .sheet(isPresented: $showCustomPreRoll) {
            // GH #67 (djkotik, Android parity): the pre-roll goes NEGATIVE,
            // meaning "start recording N minutes after the listed start" - a
            // 9:00pm rugby listing whose kickoff is 9:50 records from 9:45
            // with -45. Floored so the start stays at least a minute before
            // the programme ends. effectiveStart already subtracts the
            // pre-roll, so a negative value needs no scheduling change.
            customSheet(floor: -(max(0, Int(scheduledEnd.timeIntervalSince(scheduledStart) / 60) - 1))) {
                preRoll = customValue
            }
        }
        .sheet(isPresented: $showCustomPostRoll) {
            customSheet(floor: 1) { postRoll = customValue }
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

            // Destination picker, only shown for live recordings on
            // Dispatcharr playlists. For future programs (`!isLive`),
            // destination is forced to `.dispatcharrServer` (see
            // `.onAppear` above) because AerioTV can't auto-start a
            // local recording at a scheduled future time, so we
            // never offer the choice in the first place. v1.6.22.
            // v1.7.x: also hidden when the account can't record to the
            // server (Standard / Streamer); only local is valid then,
            // so there's no choice to present and destination is
            // already forced to `.local` in `.onAppear`.
            if isDispatcharr && isLive && canRecordToServer {
                Section {
                    Picker("Record to", selection: $destination) {
                        Text("Dispatcharr server").tag(RecordingDestination.dispatcharrServer)
                        Text("This device").tag(RecordingDestination.local)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Destination")
                }
            }

            // Comskip — always shown for Dispatcharr, but disabled
            // when destination == .local (Comskip is a server-side
            // feature; local recordings can't run it). The footer
            // explains why so users don't wonder if it's broken.
            if isDispatcharr {
                Section {
                    Toggle("Remove commercials (Comskip)", isOn: $comskip)
                        .disabled(destination == .local)
                } footer: {
                    if destination == .local {
                        Text("Comskip is only available when recording to a Dispatcharr server via a Dispatcharr API playlist.")
                    } else {
                        Text("Automatically detect and remove commercial breaks after the recording completes. Processed server-side.")
                    }
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

            // v1.6.8 (B1 Phase 1 final): Aerio deliberately doesn't
            // run background tasks for DVR — local recording is only
            // available while the app is foregrounded ("Record from
            // Now"). Future-scheduled recordings always route to
            // Dispatcharr server, which is always running and
            // doesn't depend on the app being open. If the user is
            // on a non-Dispatcharr playlist (M3U / Xtream) AND
            // picks a future program, there's no recording path at
            // all — explain that here so the action doesn't appear
            // to silently fail.
            if !isLive && !isDispatcharr {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scheduled recordings need a Dispatcharr playlist")
                                .font(.footnote.bold())
                            Text("Aerio doesn't run in the background to record on your device — that would drain battery and use storage while you're not watching. Future-scheduled recordings happen on a Dispatcharr server, which keeps running on its own. Switch to a Dispatcharr playlist to schedule this recording, or wait until the program is airing to record it locally.")
                                .font(.footnote)
                        }
                    } icon: {
                        Image(systemName: "clock.badge.exclamationmark.fill")
                            .foregroundColor(.orange)
                    }
                }
            }

            // v1.7.x: future program on a Dispatcharr server where the
            // connected account isn't an admin. Server scheduling 403s
            // and a future local recording can't auto-start, so there's
            // no path. Explain it instead of letting Record fail.
            if !isLive && isDispatcharr && !canRecordToServer {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recording requires a Dispatcharr admin account")
                                .font(.footnote.bold())
                            Text("Scheduling a recording on the Dispatcharr server needs an admin account. Your account can watch and record live programs to this device, but not schedule server recordings. Ask your Dispatcharr administrator for access, or wait until the program is airing to record it on this device.")
                                .font(.footnote)
                        }
                    } icon: {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.orange)
                    }
                }
            }

            // v1.7.x: live program on a Dispatcharr server where the
            // connected account isn't an admin. Recording is allowed but
            // lands on this device (server scheduling needs admin), so say
            // so rather than letting the user assume the server DVR has it.
            if isLive && isDispatcharr && !canRecordToServer {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Saving to this device")
                                .font(.footnote.bold())
                            Text("Your account can record live programs to this device. Recording to the Dispatcharr server requires a Dispatcharr admin account.")
                                .font(.footnote)
                        }
                    } icon: {
                        Image(systemName: "internaldrive.fill")
                            .foregroundColor(.orange)
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
                    // Disabled when there's no recording path
                    // available: future program + non-Dispatcharr
                    // playlist, or future program on a Dispatcharr
                    // server the account can't write to (non-admin).
                    // The orange info section above tells the user why.
                    .disabled(hasNoRecordingPath)
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

                    // Destination row only for live recordings on
                    // Dispatcharr playlists; future Dispatcharr
                    // recordings are forced to `.dispatcharrServer`
                    // (no path to start a future local recording on
                    // iOS without background tasks). Comskip row
                    // still shown for any Dispatcharr context; it
                    // disables itself with an explainer when
                    // destination == .local. v1.6.22 (Codex finding 1).
                    // v1.7.x: destination choice also requires admin
                    // (a non-admin account is forced to local in
                    // `.onAppear`, so there's nothing to choose).
                    if isDispatcharr && isLive && canRecordToServer {
                        destinationRow
                    }
                    if isDispatcharr {
                        comskipRow
                    }

                    if destination == .local {
                        warningsBox
                    }

                    // v1.7.x: explain the no-path case (future program
                    // on a Dispatcharr server the account can't write
                    // to). Mirrors the iOS orange info section; the
                    // Record pill is also hidden below.
                    if hasNoRecordingPath && isDispatcharr {
                        adminRequiredBox
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
                // No-recording-path cases: future program on a
                // non-Dispatcharr playlist, or future program on a
                // Dispatcharr server the account can't write to
                // (non-admin). The info card above explains; hide
                // Record so the user can't tap into a no-op / 403.
                if !hasNoRecordingPath {
                    RecordActionPill(
                        label: "Record",
                        systemImage: "record.circle",
                        tintColor: .red,
                        action: { scheduleRecording() }
                    )
                }
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
    /// Disabled (greyed) when destination == .local with an explainer
    /// footer telling the user to switch destination to enable it.
    private var comskipRow: some View {
        let isDisabled = destination == .local
        return VStack(alignment: .leading, spacing: 8) {
            Text("Remove Commercials (Comskip)")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isDisabled ? .textTertiary : .textPrimary)
                .padding(.leading, 4)
            HStack(spacing: 12) {
                RecordOptionPill(
                    label: "Off",
                    isSelected: !comskip,
                    action: { if !isDisabled { comskip = false } }
                )
                .opacity(isDisabled ? 0.45 : 1.0)
                .allowsHitTesting(!isDisabled)
                RecordOptionPill(
                    label: "On",
                    isSelected: comskip,
                    action: { if !isDisabled { comskip = true } }
                )
                .opacity(isDisabled ? 0.45 : 1.0)
                .allowsHitTesting(!isDisabled)
                Spacer(minLength: 0)
            }
            .focusSection()
            Text(
                isDisabled
                    ? "Comskip runs server-side. Switch the destination to Dispatcharr server to enable."
                    : "Server-side: detects and removes commercial breaks after the recording completes."
            )
                .font(.system(size: 18))
                .foregroundColor(.textSecondary)
                .padding(.leading, 4)
                .padding(.top, 2)
        }
    }

    /// tvOS explainer for the no-path case (future program on a
    /// Dispatcharr server the connected account can't write to).
    /// Mirrors the iOS orange info section; the Record pill is hidden
    /// alongside it. Worded to point the user at local live recording
    /// or an admin account.
    private var adminRequiredBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording requires a Dispatcharr admin account")
                        .font(.system(size: 22, weight: .bold))
                    Text("Scheduling a recording on the Dispatcharr server needs an admin account. Your account can watch and record live programs to this device, but not schedule server recordings. Ask your Dispatcharr administrator for access, or wait until the program is airing to record it on this device.")
                        .font(.system(size: 20))
                }
            } icon: {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.elevatedBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private var warningsBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            // v1.7.x: a non-admin Dispatcharr account is forced to local,
            // so spell out that the recording lands on THIS device and that
            // server recording needs an admin account. The user otherwise
            // cannot tell it did not go to the Dispatcharr server DVR.
            if isDispatcharr && !canRecordToServer {
                Label {
                    Text("Saving to this device. Recording to the Dispatcharr server requires a Dispatcharr admin account.")
                } icon: {
                    Image(systemName: "internaldrive.fill")
                        .foregroundColor(.orange)
                }
            }
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
    private func customSheet(floor: Int = 1, onConfirm: @escaping () -> Void) -> some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Stepper(customBufferLabel, value: $customValue, in: floor...120)
                #else
                HStack {
                    Text(customBufferLabel)
                    Spacer()
                    Button("-") { if customValue > floor { customValue -= 1 } }
                    Button("+") { if customValue < 120 { customValue += 1 } }
                }
                #endif
                if floor < 0 {
                    Text("Step below zero to start the recording after the listed start time.")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
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

    /// GH #67: negative custom pre-roll reads in plain words.
    private var customBufferLabel: String {
        customValue < 0 ? "\(-customValue) min after start" : "\(customValue) minutes"
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
        // v1.7.x: belt-and-suspenders for the admin gate. The UI
        // hides/disables Record for the no-path case and forces local
        // for live programs on non-admin Dispatcharr accounts, but if
        // any future caller bypasses that, never insert a server
        // recording the account can't create (it would 403). For a
        // live program, fall back to local (always valid while
        // foregrounded); for a future program there's no valid path,
        // so bail without inserting a stuck row.
        if !canRecordToServer {
            if isLive {
                if destination != .local {
                    debugLog("RecordProgramSheet: account cannot record to server; coercing live recording to .local")
                }
            } else {
                debugLog("RecordProgramSheet: account cannot record to server and program is future; aborting (no valid recording path)")
                dismiss()
                return
            }
        }

        // v1.6.22 (Codex finding 1): belt-and-suspenders. The UI
        // already prevents this combination (the destination picker
        // is hidden for `!isLive`, and `.onAppear` forces destination
        // to `.dispatcharrServer` for future programs), but if any
        // future call site bypasses the picker, we'd otherwise insert
        // a `.scheduled` local row that can never start. Coerce here
        // so the SwiftData state is always coherent.
        let effectiveDestination: RecordingDestination
        if !canRecordToServer && isLive {
            // Live program, non-admin account: local is the only valid
            // path. Overrides any stale `.dispatcharrServer` selection.
            effectiveDestination = .local
        } else if !isLive && destination == .local {
            debugLog("⚠️ RecordProgramSheet: future + local is unsupported; coercing destination to .dispatcharrServer")
            effectiveDestination = .dispatcharrServer
        } else {
            effectiveDestination = destination
        }
        let rec = Recording(
            channelID: channelID,
            channelName: channelName,
            programTitle: programTitle,
            programDescription: programDescription,
            scheduledStart: isLive ? Date() : scheduledStart,
            scheduledEnd: scheduledEnd,
            preRollMinutes: isLive ? 0 : preRoll,
            postRollMinutes: postRoll,
            destination: effectiveDestination,
            serverID: activeServer?.id.uuidString ?? "unknown"
        )
        modelContext.insert(rec)
        try? modelContext.save()

        // Kick off the recording
        Task {
            if effectiveDestination == .dispatcharrServer, let server = activeServer {
                // v1.6.8 (Codex A2): use the explicit numeric ID
                // plumbed through `ChannelDisplayItem.dispatcharrChannelID`
                // — populated at Dispatcharr load time in
                // `HomeView.fetchDispatcharr` from `DispatcharrChannel.id`.
                // Fall back to a string-parse of the legacy `channelID`
                // for any caller that hasn't migrated yet, but bail
                // loudly (no API call, log a warning) rather than
                // silently sending `0` and corrupting the user's
                // recording schedule on the server.
                guard let channelIntID = dispatcharrChannelID ?? Int(channelID),
                      channelIntID > 0 else {
                    debugLog("⚠️ RecordProgramSheet: cannot start Dispatcharr recording — no numeric channel ID resolved (dispatcharrChannelID=\(String(describing: dispatcharrChannelID)), channelID=\(channelID))")
                    DebugLogger.shared.log(
                        "Dispatcharr recording skipped: channel \"\(channelName)\" has no resolvable numeric ID",
                        category: "DVR", level: .warning)
                    return
                }
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                         auth: .apiKey(server.effectiveApiKey),
                                         userAgent: server.effectiveUserAgent,
                                         authMode: server.dispatcharrHeaderMode)
                // If user has custom buffers, don't let server double-apply offsets.
                let applyServerOffsets = (preRoll == 0 && postRoll == 0)
                try? await coordinator.scheduleDispatcharrRecording(
                    api: api, recording: rec,
                    channelIntID: channelIntID,
                    applyServerOffsets: applyServerOffsets,
                    comskip: comskip,
                    modelContext: modelContext
                )
            }
            // v1.6.8 (B1 Phase 1): wired up local recording for
            // immediate-start cases ("Record from Now" on the
            // currently-airing program). The pipeline below uses
            // the `streamURL` that callers now plumb through from
            // `ChannelDisplayItem.streamURL`. The actual recording
            // I/O lives in `RecordingCoordinator.startLocalRecording`
            // which constructs a `LocalRecordingSession`, writes
            // to `Documents/Recordings/<UUID>.ts`, and auto-stops
            // at `effectiveEnd`.
            //
            // FUTURE-SCHEDULED LOCAL RECORDINGS are deliberately
            // NOT started here — the per-platform scheduler that
            // would wake up at `effectiveStart` doesn't exist yet
            // (Phase 2 = tvOS, Phase 3 = iOS). The recording row
            // is still inserted into SwiftData with status
            // `.scheduled`, but it stays scheduled-and-idle until
            // the user manually starts it from MyRecordings or
            // until the future scheduler ships. The sheet's
            // destination footer warns the user about this so
            // expectations are set up-front rather than at
            // missed-start time.
            if effectiveDestination == .local && rec.effectiveStart <= Date() {
                guard let streamURL else {
                    debugLog("⚠️ RecordProgramSheet: cannot start local recording — no streamURL plumbed in for channel \"\(channelName)\"")
                    DebugLogger.shared.log(
                        "Local recording skipped: channel \"\(channelName)\" has no stream URL on the ChannelDisplayItem (caller didn't plumb)",
                        category: "DVR", level: .warning)
                    return
                }
                await coordinator.startLocalRecording(
                    rec, streamURL: streamURL, modelContext: modelContext
                )
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
