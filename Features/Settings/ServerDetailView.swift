//
//  ServerDetailView.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

@MainActor
func performServerCascadeDelete(_ server: ServerConnection,
                                servers: [ServerConnection],
                                modelContext: ModelContext) {
    let sid = server.id.uuidString
    server.deleteCredentialsFromKeychain()
    // Cascade: delete any EPGProgram rows scoped to this
    // server so they don't orphan and get reused by a
    // later server of a different type with different
    // channel IDs. Without this, deleting an Xtream
    // playlist and re-adding the same server via
    // Dispatcharr API leaves stale XC EPG rows in
    // SwiftData that loadFromCache would otherwise
    // return, bypassing the network fetch and leaving
    // the guide empty.
    let epgDescriptor = FetchDescriptor<EPGProgram>(
        predicate: #Predicate<EPGProgram> { $0.serverID == sid }
    )
    if let stale = try? modelContext.fetch(epgDescriptor) {
        for p in stale { modelContext.delete(p) }
        debugLog("🗑️ Deleted \(stale.count) orphaned EPGProgram rows for server \(sid)")
    }
    // v1.7.x: cascade delete WatchProgress rows
    // scoped to this server so movie / series /
    // recording resume positions don't orphan
    // when the server is removed. Mirrors the
    // EPGProgram cascade above. WatchProgress.
    // serverID is Optional<String>; the SwiftData
    // #Predicate `$0.serverID == sid` unwraps and
    // matches only rows whose serverID is exactly
    // `sid`, leaving legacy nil-serverID rows
    // (pre-multi-server era) untouched. Same
    // safety pattern the EPGProgram cascade uses.
    let wpDescriptor = FetchDescriptor<WatchProgress>(
        predicate: #Predicate<WatchProgress> { $0.serverID == sid }
    )
    if let stale = try? modelContext.fetch(wpDescriptor) {
        for w in stale { modelContext.delete(w) }
        debugLog("🗑️ Deleted \(stale.count) orphaned WatchProgress rows for server \(sid)")
    }
    // v1.7.x: cascade delete server-side Recording
    // rows scoped to this server. These are
    // Dispatcharr server-side recordings (rows
    // where `localFilePath == nil` and
    // `remoteRecordingID != nil`). After the
    // server is removed, the row is useless: the
    // Dispatcharr playback URL it references
    // (`/api/channels/recordings/<id>/file/` or
    // `/api/channels/recordings/<id>/hls/`) is
    // unreachable, and `MyRecordingsView` would
    // surface unplayable rows pointing at a
    // server the user just deleted.
    //
    // Local recordings (rows where
    // `localFilePath != nil`) are intentionally
    // NOT cascaded. The user may have captured
    // those locally on purpose and want to keep
    // the `.ts` files in `Documents/Recordings/`
    // even after the source server is removed.
    // The `localFilePath == nil` predicate is
    // the gate.
    let recDescriptor = FetchDescriptor<Recording>(
        predicate: #Predicate<Recording> {
            $0.serverID == sid && $0.localFilePath == nil
        }
    )
    if let stale = try? modelContext.fetch(recDescriptor) {
        for r in stale { modelContext.delete(r) }
        debugLog("🗑️ Deleted \(stale.count) orphaned server-side Recording rows for server \(sid)")
    }
    modelContext.delete(server)
    try? modelContext.save()
    // Issue #25: wipe in-memory VOD so On Demand stops
    // showing the removed server's movies / series. Live
    // already clears (ChannelStore.refresh re-runs on the
    // server-list change), but VODStore's no-active-server
    // path returns without clearing, so stale, unplayable
    // entries lingered. The orchestrator re-fires on the
    // allServers change and repopulates VOD for whatever
    // server remains active (if any).
    VODStore.shared.clear()
    // Push updated list to iCloud (server removed)
    SyncManager.shared.pushServers(servers.filter { $0.id != server.id })
    // Push the post-cascade WatchProgress set to
    // iCloud (immediate, not debounced) so the
    // deletion replicates to other devices before
    // they next pull. Without this, another device
    // would re-introduce the orphaned rows on its
    // next merge pass via the KVS payload.
    if let remaining = try? modelContext.fetch(FetchDescriptor<WatchProgress>()) {
        SyncManager.shared.pushWatchProgress(remaining, immediate: true)
    }
}

/// Activate a playlist: stop whatever the old source is still playing
/// (GH #22 parity), flip the isActive flags, persist, and push to iCloud.
/// Shared by the root list activation and the Playlist Detail "Set Active"
/// row (Rev 2 canon amendment 1) so both paths stay in lockstep.
@MainActor
func performSetActiveServer(_ server: ServerConnection,
                            servers: [ServerConnection],
                            modelContext: ModelContext) {
    PlayerSession.shared.stop()
    for s in servers { s.isActive = false }
    server.isActive = true
    try? modelContext.save()
    SyncManager.shared.pushServers(servers)
}

struct ServerDetailView: View {
    let server: ServerConnection
    /// See SettingsView for the rationale — observing ThemeManager
    /// makes every accent-tinted row in this detail page reactive to
    /// theme changes (icons, status pills, action buttons).
    @ObservedObject private var theme = ThemeManager.shared
    @Query private var servers: [ServerConnection]
    /// Used by the per-playlist "Refresh EPG Data" action so the
    /// detached delete can grab a `ModelContainer` from this context.
    @Environment(\.modelContext) private var modelContext
    @State private var isTestingConnection = false
    @State private var connectionResult: String? = nil
    @State private var connectionSuccess = false
    /// Per-playlist EPG-purge UX. v1.6.8: replaces the global
    /// "Refresh EPG Data" action that used to live on
    /// `AppearanceSettingsView`. Each playlist now owns its own
    /// EPG-purge action so users with multiple servers can fix one
    /// playlist's corrupted cache without nuking the others.
    @State private var showPurgeConfirmation = false
    @State private var isPurgingEPG = false
    /// "Refresh Everything" (nuclear) UX. Unlike "Refresh EPG Data"
    /// (which only purges this playlist's EPGProgram rows), this clears
    /// EVERY cache: all guide data + the in-memory per-channel EPG actor
    /// cache + all On Demand state, then reloads channels (so newly-added
    /// channels appear), the guide, and On Demand from scratch. Added
    /// after a user hit a stuck-guide state that survived "Refresh EPG
    /// Data", clearing cache, and force-quitting repeatedly.
    @State private var showRefreshAllConfirmation = false
    @State private var isRefreshingAll = false
    /// Cross-platform LAN-probe observer. `TVLANProbe` is the
    /// (legacy-named) cross-platform reachability checker — see
    /// `AerioApp.swift` for the rationale. Observing the singleton
    /// lets ServerDetailView surface the last probe result on every
    /// platform so users can see WHY the app thinks it's on LAN, plus
    /// drive the "Refresh LAN Detection" button. The probe is the sole
    /// LAN signal — there is no SSID / location dependence.
    @ObservedObject private var tvLANProbe = TVLANProbe.shared
    @State private var lanRefreshAcked = false
    /// Unified playlist page (2026-07): edit is a top-right toolbar
    /// button on iOS and the first Actions row on tvOS (a corner
    /// button is off the D-pad path). Delete lives in Danger Zone.
    @State private var editingServer: ServerConnection? = nil
    @State private var showDeleteConfirm = false
    @State private var isRefreshingPlaylist = false
    @State private var playlistRefreshDone = false
    @Environment(\.dismiss) private var dismiss

    private var hasLANConfigured: Bool {
        // LAN means "we have a localURL we can probe" on every
        // platform. The TVLANProbe reachability check is the only
        // signal that decides LAN vs WAN.
        return server.type != .m3uPlaylist && !server.localURL.isEmpty
    }

    private var isOnLAN: Bool {
        hasLANConfigured && server.effectiveBaseURL != server.normalizedBaseURL
    }

    var body: some View {
        // The held `server` model can be deleted out from under this pushed
        // detail view by an iCloud sync merge (SyncManager / AerioApp
        // delete+recreate local ServerConnection rows on a remote merge). SwiftUI
        // then re-renders this view and reading ANY @Persisted property
        // (server.type, server.localURL, ...) traps in SwiftData with
        // `_KKMDBackingData.getValue` assertion (TestFlight crash, 1.7.12). Guard
        // on the detached model (modelContext goes nil after delete) BEFORE any
        // persisted read, render an inert background, and pop.
        Group {
            if server.modelContext == nil {
                Color.appBackground.ignoresSafeArea()
            } else {
                detailContent
            }
        }
        .onChange(of: server.modelContext == nil) { _, deleted in
            if deleted { dismiss() }
        }
    }

    private var detailContent: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            List {
                Section {
                    infoRow("Type", value: server.type.displayName)
                    connectionURLRow("Remote URL", value: server.normalizedBaseURL,
                                     isActiveRoute: !isOnLAN)
                    if hasLANConfigured {
                        connectionURLRow("Local URL", value: server.localURL,
                                         isActiveRoute: isOnLAN)
                    }
                    if !server.username.isEmpty {
                        infoRow("Username", value: server.username)
                    }
                    infoRow("Status", value: server.isVerified ? "Verified" : "Unverified")
                    if let last = server.lastConnected {
                        infoRow("Last Connected", value: last.formatted(.relative(presentation: .named)))
                    }
                    if server.isActive {
                        infoRow("Channels", value: "\(ChannelStore.shared.channels.count)")
                    }
                    if !server.epgURL.isEmpty {
                        infoRow("EPG", value: server.epgURL, isMonospaced: true)
                    }
                } header: {
                    Text("Connection Details").sectionHeaderStyle()
                } footer: {
                    if hasLANConfigured {
                        Text("A checkmark marks the connection in use right now. The local URL is used automatically whenever the server answers on your home network; run Refresh LAN Detection below after a network change.")
                            .font(.labelSmall).foregroundColor(.textTertiary)
                    }
                }
                .listRowBackground(Color.cardBackground)

                Section {
                    // Rev 2 canon amendment 1: activation lives on the
                    // Playlist Detail page on EVERY form factor. The rail
                    // and sidebar models make focus/selection show the
                    // detail, so OK-to-activate cannot survive on TV roots;
                    // this row replaces it one focus-move away. Disabled
                    // with a checkmark when already active, mirroring the
                    // old tvOS root action.
                    Button {
                        performSetActiveServer(server, servers: Array(servers), modelContext: modelContext)
                    } label: {
                        HStack {
                            Image(systemName: server.isActive ? "checkmark.circle.fill" : "power.circle")
                                .foregroundColor(server.isActive ? .statusOnline : .accentPrimary)
                            Text(server.isActive ? "Active Playlist" : "Set Active")
                                .foregroundColor(server.isActive ? .statusOnline : .accentPrimary)
                        }
                    }
                    .disabled(server.isActive)
                    .listRowBackground(Color.cardBackground)

                    #if os(tvOS)
                    // TV: a top-right toolbar button is off the D-pad
                    // path, so editing is the first action row here
                    // (same pattern as Android TV).
                    NavigationLink(destination: EditServerPage(server: server).trackedAsClassicSettingsChild()) {
                        HStack {
                            Image(systemName: "pencil")
                                .foregroundColor(.accentPrimary)
                            Text("Edit Playlist")
                                .foregroundColor(.accentPrimary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                    #endif

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView().tint(.accentPrimary)
                            } else {
                                Image(systemName: "network")
                                    .foregroundColor(.accentPrimary)
                            }
                            Text(isTestingConnection ? "Testing..." : "Test Connection")
                                .foregroundColor(.accentPrimary)
                        }
                    }
                    .listRowBackground(Color.cardBackground)

                    if let result = connectionResult {
                        HStack(spacing: 8) {
                            Image(systemName: connectionSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(connectionSuccess ? .statusOnline : .statusLive)
                            Text(result)
                                .font(.bodySmall)
                                .foregroundColor(connectionSuccess ? .statusOnline : .statusLive)
                        }
                        .listRowBackground(Color.cardBackground)
                    }

                    // Re-fetch channels (and the guide) for the active
                    // playlist. Parity with Android's "Refresh Playlist"
                    // action; non-active playlists reload on activation,
                    // so the row only shows for the active one.
                    if server.isActive {
                        Button {
                            refreshPlaylist()
                        } label: {
                            HStack {
                                if isRefreshingPlaylist {
                                    ProgressView().tint(.accentPrimary)
                                } else {
                                    Image(systemName: playlistRefreshDone ? "checkmark.circle.fill" : "arrow.clockwise")
                                        .foregroundColor(playlistRefreshDone ? .statusOnline : .accentPrimary)
                                }
                                Text(isRefreshingPlaylist ? "Refreshing…"
                                     : playlistRefreshDone ? "Refreshed"
                                     : "Refresh Playlist")
                                    .foregroundColor(isRefreshingPlaylist ? .textSecondary
                                                     : playlistRefreshDone ? .statusOnline : .accentPrimary)
                            }
                        }
                        .disabled(isRefreshingPlaylist)
                        .listRowBackground(Color.cardBackground)
                    }

                    if hasLANConfigured {
                        Button {
                            tvLANProbe.probe(servers: Array(servers))
                        } label: {
                            HStack(spacing: 8) {
                                if tvLANProbe.isProbing {
                                    ProgressView().tint(.accentPrimary).scaleEffect(0.8)
                                } else {
                                    Image(systemName: lanRefreshAcked ? "checkmark.circle.fill" : "wifi.circle")
                                        .foregroundColor(lanRefreshAcked ? .statusOnline : .accentPrimary)
                                }
                                Text(tvLANProbe.isProbing ? "Probing…"
                                     : lanRefreshAcked ? "Up to date"
                                     : "Refresh LAN Detection")
                                    .foregroundColor(tvLANProbe.isProbing ? .textSecondary
                                                     : lanRefreshAcked ? .statusOnline : .accentPrimary)
                            }
                        }
                        .disabled(tvLANProbe.isProbing)
                        .listRowBackground(Color.cardBackground)
                        .onChange(of: tvLANProbe.isProbing) { _, nowProbing in
                            if !nowProbing {
                                lanRefreshAcked = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    lanRefreshAcked = false
                                }
                            }
                        }
                    }
                } header: {
                    Text("Actions").sectionHeaderStyle()
                }

                // MARK: EPG Cache (per-playlist)
                //
                // Per-playlist "nuke + re-fetch" action. Lives here
                // (instead of a single global toggle in Appearance)
                // so users with multiple playlists can scrub one
                // playlist's corrupted guide data without touching
                // the others. The SwiftData delete is filtered by
                // `EPGProgram.serverID == server.id`, and we only
                // call `ChannelStore.forceRefresh` when the purged
                // playlist is the active one — purging a non-active
                // playlist just clears the cache, and the next time
                // the user activates it the normal load path will
                // refetch fresh EPG data.
                Section {
                    Button(role: .destructive) {
                        showPurgeConfirmation = true
                    } label: {
                        HStack(spacing: 10) {
                            if isPurgingEPG {
                                ProgressView().scaleEffect(0.8)
                                    .frame(width: 14)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isPurgingEPG ? "Refreshing EPG Data…" : "Refresh EPG Data")
                                .font(.bodyMedium)
                            Spacer()
                        }
                        .foregroundColor(isPurgingEPG ? .textSecondary : .statusWarning)
                    }
                    .listRowBackground(Color.cardBackground)
                    .disabled(isPurgingEPG)
                } header: {
                    Text("EPG Cache").sectionHeaderStyle()
                } footer: {
                    Text(server.isActive
                         ? "Clears this playlist's cached guide data and downloads it fresh from the server. Use this if program cells look wrong or are missing. Takes a few minutes on large playlists."
                         : "Clears this playlist's cached guide data. The fresh fetch will run automatically the next time you make this playlist active.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }

                // MARK: Refresh Everything (nuclear)
                //
                // The heavier sibling of "Refresh EPG Data". That action only
                // purges this playlist's EPGProgram rows; if a channel or the
                // guide gets wedged, stale state can survive in the in-memory
                // EPGCache actor and the On Demand store. This button clears
                // ALL of it and reloads from scratch, so a user never has to
                // resort to force-quitting and clearing cache by hand.
                Section {
                    Button(role: .destructive) {
                        showRefreshAllConfirmation = true
                    } label: {
                        HStack(spacing: 10) {
                            if isRefreshingAll {
                                ProgressView().scaleEffect(0.8)
                                    .frame(width: 14)
                            } else {
                                Image(systemName: "arrow.clockwise.circle")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isRefreshingAll ? "Refreshing Everything…" : "Refresh Everything")
                                .font(.bodyMedium)
                            Spacer()
                        }
                        .foregroundColor(isRefreshingAll ? .textSecondary : .statusWarning)
                    }
                    .listRowBackground(Color.cardBackground)
                    .disabled(isRefreshingAll || isPurgingEPG)
                } header: {
                    Text("Full Refresh").sectionHeaderStyle()
                } footer: {
                    Text(server.isActive
                         ? "Clears every cache (channels, guide data, and On Demand) and reloads this playlist from scratch. Use this if newly-added channels, guide data, or movies and shows are missing or stale after changes on the server."
                         : "Clears every cache (channels, guide data, and On Demand). This playlist reloads automatically the next time you make it active.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
            
                // MARK: Danger Zone
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Delete Playlist")
                                .font(.bodyMedium)
                            Spacer()
                        }
                        .foregroundColor(.statusLive)
                    }
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Danger Zone").sectionHeaderStyle()
                } footer: {
                    Text("Removes this playlist and its credentials from this device. Your server data will not be affected.")
                        .font(.labelSmall).foregroundColor(.textTertiary)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            #else
            .listStyle(.plain)
            // v1.7.5: cap to a centered 1200pt column on tvOS so the
            // detail rows do not stretch the full TV width (matches the
            // server edit screen). The enclosing ZStack centers it.
            .frame(maxWidth: 1200)
            #endif
        }
        .navigationTitle(server.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editingServer = server }
                    .foregroundColor(.accentPrimary)
            }
        }
        .sheet(item: $editingServer) { EditServerSheet(server: $0) }
        #endif
        .alert("Delete Playlist?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                performServerCascadeDelete(server, servers: Array(servers), modelContext: modelContext)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(server.name)\" from the app. Your server data will not be affected.")
        }
        // Per-playlist EPG-purge confirmation. The action handler:
        //   1. Always calls `GuideStore.shared.purgePrograms(for:…)`
        //      to delete this playlist's EPGProgram rows on a
        //      background context.
        //   2. Only triggers `ChannelStore.shared.forceRefresh(...)`
        //      when this playlist is the active one — refreshing a
        //      non-active server would either no-op (forceRefresh
        //      bails on non-active first(where:isActive)) or, worse,
        //      hijack the user's currently-loaded data with a
        //      different server's payload. For non-active purges we
        //      just clear the cache and let the next activation
        //      refetch normally.
        .alert("Refresh EPG Data?", isPresented: $showPurgeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Refresh", role: .destructive) {
                Task {
                    isPurgingEPG = true
                    await GuideStore.shared.purgePrograms(
                        for: server.id.uuidString,
                        isActiveServer: server.isActive,
                        modelContext: modelContext
                    )
                    // Also drop the in-memory per-channel "upcoming" actor
                    // cache. Without this, purging the SwiftData rows still
                    // left stale guide data sitting in EPGCache, so a wedged
                    // guide could survive "Refresh EPG Data". (This is a
                    // 30-minute in-memory cache that repopulates lazily, so
                    // clearing it for all servers is harmless.)
                    await EPGCache.shared.invalidateAll()
                    if server.isActive {
                        await ChannelStore.shared.forceRefresh(servers: Array(servers), modelContext: modelContext)
                    }
                    isPurgingEPG = false
                }
            }
        } message: {
            Text(server.isActive
                 ? "All cached guide data for \"\(server.name)\" will be cleared and reloaded from the server. This may take a few minutes on large playlists."
                 : "All cached guide data for \"\(server.name)\" will be cleared. The next time you make this playlist active, fresh guide data will load automatically.")
        }
        // Refresh Everything: nuke every cache, then reload. Strictly more
        // thorough than "Refresh EPG Data" so a wedged guide / missing
        // channels can't survive it.
        .alert("Refresh Everything?", isPresented: $showRefreshAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Refresh", role: .destructive) {
                Task {
                    isRefreshingAll = true
                    // 1. Purge ALL guide data: every EPGProgram row in
                    //    SwiftData plus GuideStore's in-memory state and
                    //    load-idempotency flags (via invalidateCache).
                    await GuideStore.shared.purgeAllPrograms(modelContext: modelContext)
                    // 2. Clear the per-channel "upcoming" actor cache.
                    //    "Refresh EPG Data" leaves this in place, which is
                    //    how stale guide data can survive that action.
                    await EPGCache.shared.invalidateAll()
                    // 3. Drop all On Demand (movies + series) state.
                    VODStore.shared.clear()
                    // 4. Reload from scratch for the active playlist:
                    //    channels are re-fetched (newly-added channels
                    //    appear), the guide is rebuilt and re-cached, and
                    //    On Demand repopulates. Non-active playlists just
                    //    keep the cleared state and reload on activation.
                    if server.isActive {
                        await ChannelStore.shared.forceRefresh(servers: Array(servers), modelContext: modelContext)
                        VODStore.shared.refresh(servers: Array(servers))
                    }
                    isRefreshingAll = false
                }
            }
        } message: {
            Text(server.isActive
                 ? "Clears all cached channels, guide data, and On Demand, then reloads \"\(server.name)\" from scratch. Use this if channels or guide data are missing or stale. May take a few minutes on large playlists."
                 : "Clears all cached channels, guide data, and On Demand. \"\(server.name)\" reloads automatically the next time you make it active.")
        }
    }

    // MARK: - About computed properties

    private var aboutDevice: String { DeviceInfo.modelName }

    private var aboutSystem: String {
#if canImport(UIKit)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
#else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
#endif
    }

    private var aboutVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var aboutInstallDate: String { DeviceInfo.firstInstalledText }

    private var aboutUpdateDate: String { DeviceInfo.lastUpdatedText }

    private var aboutCopyText: String {
        [
            "AerioTV \(aboutVersion)",
            "Device: \(aboutDevice)",
            "System: \(aboutSystem)",
            "First Installed: \(aboutInstallDate)",
            "Last Updated: \(aboutUpdateDate)"
        ].joined(separator: "\n")
    }

    /// Connection Details URL row: like `infoRow` but with a green
    /// checkmark marking the route (LAN or WAN) currently in use.
    private func connectionURLRow(_ label: String, value: String, isActiveRoute: Bool) -> some View {
        HStack {
            Text(label)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
            Spacer()
            if isActiveRoute {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.statusOnline)
            }
            Text(value)
                .font(.monoSmall)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Android-parity "Refresh Playlist": re-fetch channels and the
    /// guide for the active playlist without purging any caches.
    private func refreshPlaylist() {
        guard !isRefreshingPlaylist else { return }
        isRefreshingPlaylist = true
        Task {
            await ChannelStore.shared.forceRefresh(servers: Array(servers), modelContext: modelContext)
            isRefreshingPlaylist = false
            playlistRefreshDone = true
            try? await Task.sleep(for: .seconds(2))
            playlistRefreshDone = false
        }
    }

    private func infoRow(_ label: String, value: String, isMonospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.bodyMedium)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(value)
                .font(isMonospaced ? .monoSmall : .bodyMedium)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionResult = nil
        do {
            switch server.type {
            case .xtreamCodes:
                let api = XtreamCodesAPI(baseURL: server.effectiveBaseURL, username: server.username, password: server.effectivePassword)
                _ = try await api.verifyConnection()
            case .dispatcharrAPI:
                // Re-verify with the persisted auth mode as the
                // starting hint — verifyConnection auto-falls-back if
                // the server now wants a different shape (e.g. user
                // upgraded Dispatcharr to a build with stricter auth).
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                         auth: .apiKey(server.effectiveApiKey),
                                         userAgent: server.effectiveUserAgent,
                                         authMode: server.dispatcharrHeaderMode)
                let info = try await api.verifyConnection()
                // v1.6.20: persist the discovered auth shape so
                // subsequent API calls and stream playback use it.
                if let mode = info.discoveredAuthMode,
                   mode.rawValue != server.dispatcharrAuthMode {
                    server.dispatcharrAuthMode = mode.rawValue
                    debugLog("SettingsView Test Connection: persisting auth mode .\(mode.rawValue) for \(server.name)")
                    // Immediate cross-device push so other devices on
                    // the same iCloud account inherit the working
                    // shape without waiting for the next debounce.
                    SyncManager.shared.pushServers(servers, immediate: true)
                }
                // v1.7.x: refresh the connected user's permission tier
                // so the server-side Record / DVR affordances stay
                // accurate if the account was promoted/demoted in
                // Dispatcharr since it was first saved. Best-effort: a
                // failed users/me fetch leaves the stored level
                // unchanged. Re-fetch with the (possibly newly)
                // discovered header shape.
                let levelAPI = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                              auth: .apiKey(server.effectiveApiKey),
                                              userAgent: server.effectiveUserAgent,
                                              authMode: info.discoveredAuthMode ?? server.dispatcharrHeaderMode)
                if let user = try? await levelAPI.fetchCurrentUser() {
                    // effectiveUserLevel folds in is_superuser/is_staff
                    // (legacy superusers carry level 0); the probe
                    // settles OLD servers whose /me/ predates those
                    // fields - see DispatcharrUser.effectiveUserLevel.
                    var level = user.effectiveUserLevel
                    if level < 10, await levelAPI.probeAdminAccess() { level = 10 }
                    if level != server.dispatcharrUserLevel {
                        server.dispatcharrUserLevel = level
                        debugLog("SettingsView Test Connection: persisting user_level \(level) for \(server.name)")
                        SyncManager.shared.pushServers(servers, immediate: true)
                    }
                }
            case .m3uPlaylist:
                guard let url = URL(string: server.baseURL) else { throw APIError.invalidURL }
                let (_, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
            }
            connectionSuccess = true
            connectionResult = "Connection successful"
        } catch let error as APIError {
            connectionSuccess = false
            connectionResult = error.errorDescription ?? "Unknown error"
        } catch {
            connectionSuccess = false
            connectionResult = error.localizedDescription
        }
        isTestingConnection = false
    }
}

// MARK: - Playlist List Row
struct PlaylistListRow: View {
    let playlist: M3UPlaylist

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentPrimary.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: playlist.sourceType == .url ? "link" : "doc.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.accentPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                HStack(spacing: 6) {
                    Text("\(playlist.channelCount) channels")
                        .font(.labelSmall)
                        .foregroundColor(.textSecondary)
                    if let refreshed = playlist.lastRefreshed {
                        Text("·")
                            .foregroundColor(.textTertiary)
                        Text(refreshed, style: .relative)
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                }
            }

            Spacer()

            Circle()
                .fill(Color.statusOnline)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }
}

// AppearanceSettingsView is defined in AppearanceSettingsView.swift

// MARK: - Edit Playlist Sheet
struct EditPlaylistSheet: View {
    @Bindable var playlist: M3UPlaylist
    @Environment(\.dismiss) private var dismiss
    /// See SettingsView for rationale.
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                Form {
                    Section {
                        TextField("Name", text: $playlist.name)
                            .listRowBackground(Color.cardBackground)
                        if playlist.sourceType == .url {
                            TextField("URL", text: $playlist.urlString)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .listRowBackground(Color.cardBackground)
                        } else {
                            HStack {
                                Text("Source")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Text("Local file")
                                    .foregroundColor(.textTertiary)
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                    } header: {
                        Text("Playlist Details").sectionHeaderStyle()
                    }
                }
                #if os(iOS)
                .scrollContentBackground(.hidden)
                #endif
            }
            .navigationTitle("Edit Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.accentPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { dismiss() }
                        .foregroundColor(.accentPrimary)
                        .fontWeight(.semibold)
                        .disabled(playlist.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Edit Server Sheet
