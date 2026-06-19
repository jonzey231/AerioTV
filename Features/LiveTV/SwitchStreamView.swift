import SwiftUI
import SwiftData

// MARK: - Switch Stream (Dispatcharr Direct Connect)
/// Player Options -> "Switch Stream" picker. Lists a Dispatcharr
/// channel's member streams (highest priority first), each row labelled
/// with quality (resolution / fps / bitrate / codecs) and its source M3U
/// name. Selecting one POSTs `change_stream`; Dispatcharr swaps the
/// upstream in place behind the unchanged `/proxy/ts/stream/<uuid>`
/// connection and libmpv follows the mid-stream TS discontinuity on its
/// own, so we do NOT reload the player here (a reload would drop the only
/// connection and Dispatcharr would revert to the default stream).
///
/// Gated upstream to Dispatcharr Direct Connect + admin accounts
/// (`ServerConnection.dispatcharrCanSwitchStream`), so this view assumes
/// the active server is Dispatcharr; it degrades gracefully otherwise.
///
/// Presented by the player chrome host (`MultiviewContainerView`) as a
/// `.sheet` on iOS and a `.fullScreenCover` on tvOS — the same modality
/// the Record sheet uses. Self-contained: resolves the active server and
/// builds its own `DispatcharrAPI`, mirroring `RecordProgramSheet`.
struct SwitchStreamView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var servers: [ServerConnection]

    /// Integer pk of the channel (DispatcharrChannel.id) — keys the
    /// member-streams list endpoint.
    let channelID: Int
    /// Channel UUID — keys `change_stream` (same uuid as the proxy URL).
    let channelUUID: String
    let channelName: String
    /// Optional close handler. iOS presents this as a `.sheet`, so the
    /// default `dismiss()` works. tvOS presents it as an inline OVERLAY
    /// (not a `.fullScreenCover` — a third stacked cover breaks the tvOS
    /// 27 focus engine), where `dismiss()` is a no-op, so the container
    /// passes a closer that flips its `showSwitchStream` flag.
    var onClose: (() -> Void)? = nil

    /// The stream the user switched to earlier THIS session for this
    /// channel, if any. Survives picker re-opens (held by the container,
    /// keyed by channel) because `/status.stream_id` goes stale right
    /// after a switch — the in-session value is the truthful "current".
    /// nil falls back to the (fresh-read-correct) status stream id.
    var initialStreamID: Int? = nil
    /// Reports a confirmed switch back to the container so it can persist
    /// the in-session selection across re-opens.
    var onSwitched: ((Int) -> Void)? = nil

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    @State private var streams: [DispatcharrStream] = []
    /// m3u_account id -> source display name, from `/api/m3u/accounts/`.
    @State private var sourceNames: [Int: String] = [:]
    @State private var isLoading = true
    @State private var loadError: String?
    /// In-session selection. `/status.stream_id` is unreliable on the
    /// Dispatcharr event path (it stays stale for 20+s after a switch on a
    /// non-owner worker), so we never seed a "current" mark from it and
    /// instead reflect only what the user picks this session.
    @State private var selectedStreamID: Int?
    @State private var isSwitching = false
    @State private var switchError: String?

    #if os(tvOS)
    /// Drives initial focus on tvOS (where this is an inline overlay, not
    /// a cover, so the focus engine won't auto-land somewhere for us).
    /// "done" until streams load, then the first stream row.
    @FocusState private var focusedRow: String?
    #endif

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private func makeAPI() -> DispatcharrAPI? {
        guard let server = activeServer, server.type == .dispatcharrAPI else { return nil }
        return DispatcharrAPI(baseURL: server.effectiveBaseURL,
                              auth: .apiKey(server.effectiveApiKey),
                              userAgent: server.effectiveUserAgent,
                              authMode: server.dispatcharrHeaderMode)
    }

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .task { await load() }
    }

    // MARK: - Load

    private func load() async {
        guard let api = makeAPI() else {
            loadError = "Switch Stream is only available on a Dispatcharr Direct Connect playlist."
            isLoading = false
            return
        }
        do {
            // Streams are required; the source-name map and live status are
            // best-effort. Status seeds the "currently active" mark: the
            // in-session selection wins, else /status.stream_id (correct on
            // a fresh read, before any switch staled it).
            async let streamsTask = api.getChannelStreams(channelID: channelID)
            async let accountsTask = api.getM3UAccounts()
            async let statusTask = api.getChannelStatus(channelUUID: channelUUID)
            let fetched = try await streamsTask
            let accounts = (try? await accountsTask) ?? []
            let status = try? await statusTask
            var map: [Int: String] = [:]
            for a in accounts { if let n = a.name, !n.isEmpty { map[a.id] = n } }
            sourceNames = map
            streams = fetched
            if selectedStreamID == nil {
                selectedStreamID = initialStreamID ?? status?.streamID
            }
            isLoading = false
            if fetched.isEmpty {
                debugLog("[SwitchStream] channel \(channelName) (id=\(channelID)) returned 0 member streams")
            }
        } catch {
            isLoading = false
            loadError = "Couldn't load this channel's streams. Check the server connection and try again."
            debugLog("[SwitchStream] load failed for \(channelName) (id=\(channelID)): \(error.localizedDescription)")
        }
    }

    private func select(_ stream: DispatcharrStream) {
        guard !isSwitching, let api = makeAPI() else { return }
        let previousSelection = selectedStreamID
        // Optimistic: mark the chosen row immediately.
        selectedStreamID = stream.id
        isSwitching = true
        switchError = nil
        Task {
            do {
                // change_stream returns the resolved upstream url. We then
                // confirm by polling /status.url == that url (stream_id is
                // unreliable on the event path). libmpv follows the
                // in-place TS swap on its own once the server has switched,
                // so we do NOT touch the player.
                let targetURL = try await api.changeStream(channelUUID: channelUUID, streamID: stream.id)
                let confirmed = await confirmSwitch(api: api, targetURL: targetURL, streamID: stream.id)
                if confirmed {
                    debugLog("[SwitchStream] \(channelName): confirmed switch to stream id=\(stream.id) \"\(titleLine(for: stream))\"")
                    onSwitched?(stream.id)
                    close()
                } else {
                    // The POST returned 200 but /status.url never matched
                    // within the budget — the switch didn't take. Restore
                    // the prior mark and tell the user rather than leave a
                    // misleading checkmark.
                    isSwitching = false
                    selectedStreamID = previousSelection
                    switchError = "The switch didn't take effect. The server may be busy; the current stream is unchanged."
                    debugLog("[SwitchStream] \(channelName): change_stream not confirmed for stream=\(stream.id) (target=\(targetURL ?? "nil"))")
                }
            } catch {
                isSwitching = false
                selectedStreamID = previousSelection
                switchError = "Couldn't switch the stream. Your account may not have permission, or the server is unreachable."
                debugLog("[SwitchStream] change_stream failed for \(channelName) stream=\(stream.id): \(error.localizedDescription)")
            }
        }
    }

    /// Polls `/status.url` until it equals the change_stream target url, up
    /// to ~6s. If the response carried no url (older server), we can't
    /// confirm by url, so accept optimistically (the POST returned 200).
    private func confirmSwitch(api: DispatcharrAPI, targetURL: String?, streamID: Int) async -> Bool {
        guard let targetURL, !targetURL.isEmpty else { return true }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            // Bail if the user moved on (closed / picked another row).
            if selectedStreamID != streamID { return false }
            if let status = try? await api.getChannelStatus(channelUUID: channelUUID),
               let liveURL = status.url, liveURL == targetURL {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        return false
    }

    // MARK: - Row labels (ported from Android StreamOption.label)

    private func titleLine(for s: DispatcharrStream) -> String {
        if let n = s.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return "Stream \(s.id)"
    }

    /// Source name + quality bits, joined by "  ·  ", nils omitted.
    private func metaLine(for s: DispatcharrStream) -> String {
        var parts: [String] = []
        if let m = s.m3uAccount, let name = sourceNames[m], !name.isEmpty { parts.append(name) }
        let st = s.streamStats
        if let r = prettyResolution(st?.resolution) { parts.append(r) }
        if let f = prettyFPS(st?.sourceFPS) { parts.append(f) }
        if let b = prettyBitrate(st?.outputBitrate) { parts.append(b) }
        if let v = prettyVideoCodec(st?.videoCodec) { parts.append(v) }
        if let a = prettyAudioCodec(st?.audioCodec) { parts.append(a) }
        return parts.joined(separator: "  ·  ")
    }

    private func prettyResolution(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        // Snap the height to the nearest standard tier so non-exact
        // sources (1088, 1062, 576, 544) and slightly-off encodes don't
        // mislabel. Falls back to the raw "{h}p" below the lowest tier.
        if parts.count == 2, let h = Int(parts[1]) {
            switch h {
            case 2000...: return "4K"
            case 1000...: return "1080p"
            case 700...: return "720p"
            case 500...: return "480p"
            default: return "\(h)p"
            }
        }
        return raw
    }

    private func prettyFPS(_ raw: String?) -> String? {
        guard let raw, let v = Double(raw), v > 0 else { return nil }
        return "\(Int(v.rounded()))fps"
    }

    private func prettyBitrate(_ raw: String?) -> String? {
        guard let raw, let kbps = Double(raw), kbps > 0 else { return nil }
        if kbps >= 1000 { return String(format: "%.1f Mbps", kbps / 1000) }
        return "\(Int(kbps)) kbps"
    }

    private func prettyVideoCodec(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "h264", "avc", "avc1": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "mpeg2video", "mpeg2": return "MPEG-2"
        default: return raw.uppercased()
        }
    }

    private func prettyAudioCodec(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.uppercased()
    }

    // MARK: - iOS

    #if os(iOS)
    private var iOSBody: some View {
        List {
            if isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 8)
                }
            } else if let loadError {
                Section { Text(loadError).foregroundColor(.secondary) }
            } else if streams.isEmpty {
                Section { Text("No alternate streams for this channel.").foregroundColor(.secondary) }
            } else {
                if let switchError {
                    Section { Text(switchError).foregroundColor(.orange) }
                }
                Section {
                    ForEach(streams) { stream in
                        Button { select(stream) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(titleLine(for: stream))
                                        .foregroundColor(.primary)
                                    let meta = metaLine(for: stream)
                                    if !meta.isEmpty {
                                        Text(meta)
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if selectedStreamID == stream.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentPrimary)
                                }
                            }
                        }
                        .disabled(isSwitching)
                    }
                } header: {
                    Text("Streams for \(channelName)")
                } footer: {
                    Text("Switches the active upstream for this channel. The picture follows in a few seconds.")
                }
            }
        }
        .navigationTitle("Switch Stream")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { close() }
            }
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSBody: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Switch Stream")
                        .font(.system(size: 42, weight: .bold))
                    Text(channelName)
                        .font(.system(size: 24))
                        .foregroundColor(.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
            .padding(.bottom, 28)

            Group {
                if isLoading {
                    Spacer()
                    ProgressView().scaleEffect(1.6)
                    Spacer()
                } else if let loadError {
                    Spacer()
                    messageCard(loadError, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    Spacer()
                } else if streams.isEmpty {
                    Spacer()
                    messageCard("No alternate streams for this channel.", systemImage: "rectangle.on.rectangle.slash", tint: .textSecondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let switchError {
                                messageCard(switchError, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            }
                            ForEach(streams) { stream in
                                SwitchStreamRow(
                                    title: titleLine(for: stream),
                                    meta: metaLine(for: stream),
                                    isSelected: selectedStreamID == stream.id,
                                    action: { select(stream) }
                                )
                                .focused($focusedRow, equals: "stream-\(stream.id)")
                                .disabled(isSwitching)
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.bottom, 40)
                    }
                    .focusSection()
                }
            }
            // Land focus on the first stream row once they load (the
            // overlay has no auto-focus the way a cover would). Until
            // then "done" holds focus so the screen is never focus-less.
            .onChange(of: streams.count) { _, n in
                if n > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        focusedRow = "stream-\(streams[0].id)"
                    }
                }
            }

            HStack {
                Spacer()
                Button { close() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark")
                        Text("Done")
                    }
                }
                .buttonStyle(SwitchStreamActionStyle())
                .focused($focusedRow, equals: "done")
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 28)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .onExitCommand { close() }
        .onAppear {
            // Seed focus immediately so the overlay is never focus-less
            // while streams load; the streams.onChange moves it to the
            // first row once they arrive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if focusedRow == nil { focusedRow = "done" }
            }
        }
    }

    private func messageCard(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).font(.system(size: 24))
        } icon: {
            Image(systemName: systemImage).foregroundColor(tint)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.elevatedBackground, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 80)
    }
    #endif
}

// MARK: - tvOS row + styles

#if os(tvOS)
/// Focusable stream row. Button + ButtonStyle (not `.focusable +
/// .onTapGesture`) to avoid the `_UIReplicantView` console warning, same
/// rationale as the Record sheet's pills.
private struct SwitchStreamRow: View {
    let title: String
    let meta: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SwitchStreamRowLabel(title: title, meta: meta, isSelected: isSelected)
        }
        .buttonStyle(SwitchStreamRowStyle())
        .focusEffectDisabled()
    }
}

private struct SwitchStreamRowLabel: View {
    let title: String
    let meta: String
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(isFocused ? .white : .textPrimary)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 20))
                        .foregroundColor(isFocused ? .white.opacity(0.85) : .textSecondary)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(isFocused ? .white : .accentPrimary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isFocused ? Color.accentPrimary : Color.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected && !isFocused ? Color.accentPrimary : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

private struct SwitchStreamRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private struct SwitchStreamActionStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(isFocused ? .white : .textSecondary)
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(Capsule().fill(isFocused ? Color.accentPrimary : Color.elevatedBackground))
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif
