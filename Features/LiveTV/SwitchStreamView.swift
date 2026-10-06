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
// MARK: - Headless switch flow (shared)
//
// The per-tile multiview menu presents streams as a NATIVE
// confirmationDialog (Logan 2026-08-28: the custom picker was a visual
// break there) but must reuse THIS file's battle-tested switch
// machinery - change_stream + confirm-by-/status.url polling (stream_id
// is unreliable on the event path), the owner-worker connection-pool
// caveat, and the reprime notification. Keep flow changes here so both
// presentations stay in lockstep.
enum SwitchStreamFlow {
    struct Option: Identifiable {
        let id: Int
        let title: String
        let isCurrent: Bool
    }

    /// Plain denial lines for a pre-check denial or a 403, worded
    /// identically on Android. Only non-403 failures carry the HTTP code.
    static let switchDeniedMessage = "Your Dispatcharr account can't switch streams. Switching needs an administrator account."
    static let switchNotConfirmedMessage = "The switch didn't take effect. The server may be busy; the current stream is unchanged."
    static let reorderDeniedMessage = "Your Dispatcharr account can't reorder streams. Reordering needs an administrator account."

    /// The app's own confirmed picks, keyed by channel UUID, with the time
    /// of the pick. `/status.stream_id` stays stale for 20+ s after an
    /// event-path switch, so a fresh pick wins over the server for that
    /// window; after it the server's stream_id is the truth (an external
    /// switch from the Dispatcharr UI or failover then moves the radio).
    @MainActor
    private static var recentPicks: [String: (id: Int, at: Date)] = [:]
    private static let pickTrustWindow: TimeInterval = 30

    @MainActor
    static func notePick(channelUUID: String, streamID: Int) {
        recentPicks[channelUUID] = (streamID, Date())
    }

    /// The stream the radio marks: the server's current stream_id, unless
    /// the app switched this channel within the stale window (or the
    /// server read failed), in which case the app's pick (or `fallback`).
    @MainActor
    static func markedStreamID(channelUUID: String, serverID: Int?, fallback: Int?) -> Int? {
        let pick = recentPicks[channelUUID]
        let local: Int? = {
            if let pick, Date().timeIntervalSince(pick.at) < pickTrustWindow { return pick.id }
            return nil
        }()
        if let local { return local }
        if let serverID {
            if let prior = fallback ?? pick?.id, prior != serverID {
                debugLog("[SWITCH] radio follows server stream_id=\(serverID)")
            }
            return serverID
        }
        return fallback ?? pick?.id
    }

    /// User-facing failure line, worded identically on Android: a 403
    /// returns `deniedMessage`; otherwise "Couldn't switch the stream
    /// (HTTP 500): <server text>", or "Couldn't switch the stream
    /// (HTTP 500)." when the server sent none.
    static func failureMessage(_ action: String, deniedMessage: String, error: Error) -> String {
        if SwitchStreamView.httpStatus(of: error) == 403 { return deniedMessage }
        if let failure = error as? DispatcharrHTTPFailure {
            if let reason = failure.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                return "Couldn't \(action) (HTTP \(failure.status)): \(reason)"
            }
            return "Couldn't \(action) (HTTP \(failure.status))."
        }
        if let status = SwitchStreamView.httpStatus(of: error) {
            if case APIError.forbidden(let reason?) = error, !reason.isEmpty {
                return "Couldn't \(action) (HTTP \(status)): \(reason)"
            }
            return "Couldn't \(action) (HTTP \(status))."
        }
        return "Couldn't \(action): \(error.localizedDescription)"
    }

    /// Re-read the user level right before an admin-only action. Returns
    /// whether the account may switch streams on the FRESH answer (fail
    /// closed: unknown = no).
    @MainActor
    static func recheckAdmin(server: ServerConnection?, trigger: String) async -> Bool {
        guard let server, server.type == .dispatcharrAPI else { return false }
        await DispatcharrCapabilityProbe.refresh(server, reason: trigger, waitIfInFlight: true)
        return server.dispatcharrCanSwitchStream
    }

    /// A 403 on an admin-only call: the server says the level changed, so
    /// re-read it now and let every gate follow.
    @MainActor
    static func noteFailure(server: ServerConnection?, error: Error, trigger: String) {
        guard let server, SwitchStreamView.httpStatus(of: error) == 403 else { return }
        Task { @MainActor in
            await DispatcharrCapabilityProbe.refresh(server, reason: trigger, waitIfInFlight: true)
        }
    }

    @MainActor
    static func makeAPI(server: ServerConnection?) -> DispatcharrAPI? {
        guard let server, server.type == .dispatcharrAPI else { return nil }
        return DispatcharrAPI(baseURL: server.effectiveBaseURL,
                              auth: .apiKey(server.effectiveApiKey),
                              userAgent: server.effectiveUserAgent,
                              authMode: server.dispatcharrHeaderMode)
    }

    /// Callers run `recheckAdmin` first (the player and Multiview both
    /// show `switchDeniedMessage` on a denial before listing streams).
    @MainActor
    static func loadOptions(server: ServerConnection?,
                            channelID: Int,
                            channelUUID: String) async -> [Option]? {
        guard let api = makeAPI(server: server) else { return nil }
        do {
            async let streamsTask = api.getChannelStreams(channelID: channelID)
            async let accountsTask = api.getM3UAccounts()
            async let statusTask = api.getChannelStatus(channelUUID: channelUUID)
            let fetched = try await streamsTask
            let accounts = (try? await accountsTask) ?? []
            let currentID = markedStreamID(channelUUID: channelUUID,
                                           serverID: (try? await statusTask)?.streamID,
                                           fallback: nil)
            var names: [Int: String] = [:]
            for a in accounts { if let n = a.name, !n.isEmpty { names[a.id] = n } }
            return fetched.map { st in
                let source = st.m3uAccount.flatMap { names[$0] }
                let base = st.name?.trimmingCharacters(in: .whitespaces) ?? "Stream \(st.id)"
                let title = source.map { "\(base)  ·  \($0)" } ?? base
                return Option(id: st.id, title: title, isCurrent: st.id == currentID)
            }
        } catch {
            debugLog("[SwitchStream] flow load failed (id=\(channelID)): \(error.localizedDescription)")
            return nil
        }
    }

    /// change_stream + confirm; posts the reprime on success.
    /// Returns nil on success, else the user-facing failure line (the
    /// same wording as the player path). Mirrors
    /// SwitchStreamView.select()/confirmSwitch() - see those comments.
    @MainActor
    static func performSwitch(server: ServerConnection?,
                              channelUUID: String,
                              streamID: Int) async -> String? {
        guard let api = makeAPI(server: server) else { return switchNotConfirmedMessage }
        do {
            let targetURL = try await api.changeStream(channelUUID: channelUUID, streamID: streamID)
            if let targetURL, !targetURL.isEmpty {
                let deadline = Date().addingTimeInterval(6)
                var confirmed = false
                while Date() < deadline {
                    if let status = try? await api.getChannelStatus(channelUUID: channelUUID),
                       let liveURL = status.url, liveURL == targetURL {
                        confirmed = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard confirmed else {
                    debugLog("[SwitchStream] flow: change_stream not confirmed (stream=\(streamID))")
                    return switchNotConfirmedMessage
                }
            }
            notePick(channelUUID: channelUUID, streamID: streamID)
            NotificationCenter.default.post(name: .switchStreamReprime, object: nil,
                                            userInfo: ["uuid": channelUUID])
            debugLog("[SwitchStream] flow: confirmed switch to stream id=\(streamID)")
            return nil
        } catch {
            noteFailure(server: server, error: error, trigger: "403 on change_stream")
            debugLog("[SwitchStream] flow: change_stream failed (stream=\(streamID)): \(error.localizedDescription)")
            return failureMessage("switch the stream", deniedMessage: switchDeniedMessage, error: error)
        }
    }
}

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
    /// Reorder (admin only): a PATCH of the channel's `streams` order is
    /// in flight, and the last save failure (with its HTTP status).
    @State private var isSavingOrder = false
    @State private var orderError: String?
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    /// The order when Reorder mode began. Drags only rearrange the local
    /// list; the order is saved ONCE when Reorder mode ends (Finish, or
    /// the sheet closing mid-reorder), and only if it changed.
    @State private var orderBeforeReorder: [DispatcharrStream]?
    #endif

    #if os(tvOS)
    /// Drives initial focus on tvOS (where this is an inline overlay, not
    /// a cover, so the focus engine won't auto-land somewhere for us).
    /// "done" until streams load, then the first stream row.
    @FocusState private var focusedRow: String?
    #endif

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    /// Reordering is for Dispatcharr Direct Connect admins only (the same
    /// `IsAdmin` gate that shows Switch Stream; the channel PATCH is
    /// `IsAdmin` server side too). Non-admins see the sheet unchanged.
    private var canReorder: Bool {
        guard let server = activeServer, server.type == .dispatcharrAPI else { return false }
        return server.dispatcharrCanSwitchStream && streams.count > 1
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
        // Re-read the user level before listing: an admin can demote (or
        // promote) the account at any time, and the picker must follow the
        // live answer, not the one cached at launch.
        guard await SwitchStreamFlow.recheckAdmin(server: activeServer, trigger: "Switch Stream open") else {
            loadError = SwitchStreamFlow.switchDeniedMessage
            isLoading = false
            return
        }
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
            // The radio follows the server: the server's current stream_id
            // read on open wins, except within the stale window after this
            // app's own switch (see SwitchStreamFlow.markedStreamID).
            if selectedStreamID == nil {
                selectedStreamID = SwitchStreamFlow.markedStreamID(
                    channelUUID: channelUUID, serverID: status?.streamID, fallback: initialStreamID)
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
        #if os(iOS)
        // Row taps do not switch while Reorder mode is on.
        if editMode.isEditing { return }
        #endif
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
                // unreliable on the event path). libmpv follows the in-place
                // TS swap for PLAYBACK on its own, so we do NOT reconnect the
                // player (reconnecting is an Android/ExoPlayer-only need and
                // its client churn actively pushes our API calls onto a
                // non-owner worker). Whether Dispatcharr's Stats page reflects
                // the switch depends on the url-changing change_stream landing
                // on the channel's OWNER worker — the only path that rewrites
                // the Redis stream_id the Stats card reads. We keep the API
                // connection pool clean so it stays pinned to that worker.
                let targetURL = try await api.changeStream(channelUUID: channelUUID, streamID: stream.id)
                let confirmed = await confirmSwitch(api: api, targetURL: targetURL, streamID: stream.id)
                if confirmed {
                    debugLog("[SwitchStream] \(channelName): confirmed switch to stream id=\(stream.id) \"\(titleLine(for: stream))\"")
                    SwitchStreamFlow.notePick(channelUUID: channelUUID, streamID: stream.id)
                    onSwitched?(stream.id)
                    // Tell the live player the switch landed. It keeps its
                    // connection and only reloads once (no overlap) if
                    // playback does not advance.
                    NotificationCenter.default.post(
                        name: .switchStreamReprime, object: nil,
                        userInfo: ["uuid": channelUUID]
                    )
                    close()
                } else {
                    // The POST returned 200 but /status.url never matched
                    // within the budget — the switch didn't take. Restore
                    // the prior mark and tell the user rather than leave a
                    // misleading checkmark.
                    isSwitching = false
                    selectedStreamID = previousSelection
                    switchError = SwitchStreamFlow.switchNotConfirmedMessage
                    debugLog("[SwitchStream] \(channelName): change_stream not confirmed for stream=\(stream.id) (target=\(targetURL ?? "nil"))")
                }
            } catch {
                isSwitching = false
                selectedStreamID = previousSelection
                // #89: show the HTTP status (and the server's own text)
                // instead of a generic guess. Same wording as Android.
                switchError = SwitchStreamFlow.failureMessage("switch the stream", deniedMessage: SwitchStreamFlow.switchDeniedMessage, error: error)
                SwitchStreamFlow.noteFailure(server: activeServer, error: error, trigger: "403 on change_stream")
                debugLog("[SwitchStream] change_stream failed for \(channelName) stream=\(stream.id) status=\(Self.httpStatus(of: error).map(String.init) ?? "none"): \(error.localizedDescription)")
            }
        }
    }

    /// HTTP status carried by a DispatcharrAPI error, when there is one.
    nonisolated static func httpStatus(of error: Error) -> Int? {
        if let failure = error as? DispatcharrHTTPFailure { return failure.status }
        guard let api = error as? APIError else { return nil }
        switch api {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .serverError(let code): return code
        case .emptyResponse(let code): return code
        default: return nil
        }
    }


    // MARK: - Reorder (admin)

    #if os(iOS)
    /// Drag only in Reorder mode (iOS otherwise allows a long-press drag
    /// whenever onMove has a handler).
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard canReorder, !isSavingOrder, editMode.isEditing else { return nil }
        return { source, destination in move(from: source, to: destination) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard canReorder, !isSavingOrder, editMode.isEditing else { return }
        streams.move(fromOffsets: source, toOffset: destination)
    }

    private func beginReorder() {
        orderBeforeReorder = streams
        orderError = nil
        withAnimation { editMode = .active }
    }

    /// Leaves Reorder mode and saves the order once if it changed.
    private func endReorder(trigger: String) {
        let previous = orderBeforeReorder
        orderBeforeReorder = nil
        withAnimation { editMode = .inactive }
        guard let previous else { return }
        if previous.map(\.id) != streams.map(\.id) {
            debugLog("[SwitchStream] reorder ended (\(trigger)); saving channel=\(channelID)")
            saveOrder(previous: previous)
        }
    }
    #endif

    /// tvOS Move Up / Move Down: shifts one row by `offset` (-1 or +1).
    private func moveStream(_ stream: DispatcharrStream, by offset: Int) {
        guard canReorder, !isSavingOrder,
              let index = streams.firstIndex(where: { $0.id == stream.id }) else { return }
        let target = index + offset
        guard streams.indices.contains(target) else { return }
        let previous = streams
        streams.swapAt(index, target)
        saveOrder(previous: previous)
        #if os(tvOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedRow = "stream-\(stream.id)"
        }
        #endif
    }

    /// PATCHes the full member-stream order (Dispatcharr deletes links
    /// missing from the list, so every id goes). On failure the list is
    /// restored, the HTTP status shown, and the server order refetched.
    private func saveOrder(previous: [DispatcharrStream]) {
        guard let api = makeAPI() else { streams = previous; return }
        let ids = streams.map(\.id)
        guard ids != previous.map(\.id) else { return }
        isSavingOrder = true
        orderError = nil
        Task {
            // Fresh user level before the write; a demoted account gets the
            // permission message and the old order back, with no PATCH.
            guard await SwitchStreamFlow.recheckAdmin(server: activeServer, trigger: "stream reorder save") else {
                streams = previous
                orderError = SwitchStreamFlow.reorderDeniedMessage
                isSavingOrder = false
                return
            }
            do {
                try await api.updateChannelStreamOrder(channelID: channelID, streamIDs: ids)
                isSavingOrder = false
                debugLog("[SwitchStream] reorder saved channel=\(channelID) order=\(ids)")
            } catch {
                let status = Self.httpStatus(of: error)
                debugLog("[SwitchStream] reorder failed status=\(status.map(String.init) ?? "none") channel=\(channelID): \(error.localizedDescription)")
                streams = previous
                orderError = SwitchStreamFlow.failureMessage("save the stream order", deniedMessage: SwitchStreamFlow.reorderDeniedMessage, error: error)
                SwitchStreamFlow.noteFailure(server: activeServer, error: error, trigger: "403 on stream reorder")
                isSavingOrder = false
                await load()
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
                if let orderError {
                    Section { Text(orderError).foregroundColor(.orange) }
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
                                            .scaledFont(.footnote)
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
                        .disabled(isSwitching || isSavingOrder)
                    }
                    .onMove(perform: moveHandler)
                } header: {
                    HStack(spacing: 8) {
                        Text("Streams for \(channelName)")
                        if isSavingOrder {
                            ProgressView()
                            Text("Saving Order")
                        }
                    }
                } footer: {
                    Text(canReorder
                         ? "Switches the active upstream for this channel. The picture follows in a few seconds. Tap Reorder to change the stream priority."
                         : "Switches the active upstream for this channel. The picture follows in a few seconds.")
                }
            }
        }
        .navigationTitle("Switch Stream")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { close() }
            }
            if canReorder {
                ToolbarItem(placement: .primaryAction) {
                    Button(editMode.isEditing ? "Finish" : "Reorder") {
                        if editMode.isEditing { endReorder(trigger: "Finish") } else { beginReorder() }
                    }
                    .disabled(isSavingOrder)
                }
            }
        }
        .environment(\.editMode, $editMode)
        // Closing the sheet while reordering saves the pending order.
        .onDisappear {
            if editMode.isEditing { endReorder(trigger: "dismiss") }
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
                        .scaledFont(.system(size: 42, weight: .bold))
                    Text(channelName)
                        .scaledFont(.system(size: 24).subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
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
                            if let orderError {
                                messageCard(orderError, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            }
                            if isSavingOrder {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text("Saving Order")
                                        .scaledFont(.system(size: 22))
                                        .foregroundColor(Color.contrastText(.textSecondary))
                                }
                                .padding(.horizontal, 80)
                            }
                            ForEach(Array(streams.enumerated()), id: \.element.id) { index, stream in
                                HStack(spacing: 16) {
                                    SwitchStreamRow(
                                        title: titleLine(for: stream),
                                        meta: metaLine(for: stream),
                                        isSelected: selectedStreamID == stream.id,
                                        action: { select(stream) }
                                    )
                                    .focused($focusedRow, equals: "stream-\(stream.id)")
                                    .disabled(isSwitching || isSavingOrder)
                                    // Admin reorder: trailing "more" button with a
                                    // Move Up / Move Down menu (Android parity).
                                    // Right from the row focuses it, Left returns.
                                    if canReorder && streams.count > 1 {
                                        Menu {
                                            // Disabled header so the entry reads
                                            // "Reorder" like the phone and tablet
                                            // button (Android TV parity).
                                            Section("Reorder") {
                                                if index > 0 {
                                                    Button { moveStream(stream, by: -1) } label: {
                                                        Label("Move Up", systemImage: "arrow.up")
                                                    }
                                                }
                                                if index < streams.count - 1 {
                                                    Button { moveStream(stream, by: 1) } label: {
                                                        Label("Move Down", systemImage: "arrow.down")
                                                    }
                                                }
                                            }
                                        } label: {
                                            SwitchStreamMoreLabel()
                                        }
                                        .buttonStyle(SwitchStreamRowStyle())
                                        .focusEffectDisabled()
                                        .focused($focusedRow, equals: "more-\(stream.id)")
                                        .disabled(isSwitching || isSavingOrder)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
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
            Text(text).scaledFont(.system(size: 24))
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
                    .scaledFont(.system(size: 26, weight: .semibold))
                    .foregroundColor(isFocused ? .white : .textPrimary)
                if !meta.isEmpty {
                    Text(meta)
                        .scaledFont(.system(size: 20))
                        .foregroundColor(isFocused ? .white.opacity(0.85) : Color.contrastText(.textSecondary))
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(.system(size: 28))
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

/// Trailing "more" button for a stream row. Same height as the row
/// (the HStack is vertically fixed and this fills it).
private struct SwitchStreamMoreLabel: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: "ellipsis")
            .scaledFont(.system(size: 28, weight: .semibold))
            .foregroundColor(isFocused ? .white : .textSecondary)
            .frame(width: 96)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.accentPrimary : Color.elevatedBackground)
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
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
            .scaledFont(.system(size: 24, weight: .semibold))
            .foregroundColor(isFocused ? .white : .textSecondary)
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(Capsule().fill(isFocused ? Color.accentPrimary : Color.elevatedBackground))
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif
