import Foundation
import SwiftData
import Combine

// MARK: - iCloud Server Sync Manager
/// Synchronizes ServerConnection playlists AND app preferences across devices
/// via NSUbiquitousKeyValueStore (KVS).
///
/// **Threading rules**:
///  - KVS writes MUST happen on the literal main **dispatch queue** (GCD).
///    Swift's `@MainActor` cooperative executor is NOT the same as the main
///    dispatch queue — `MainActor.assumeIsolated` may execute on a thread that
///    fails KVS's internal `dispatch_assert_queue(main_queue)`.
///  - Therefore all KVS `set` / `removeObject` calls are wrapped in
///    `DispatchQueue.main.async { }` so they run in a clean GCD context.
///  - KVS reads in `remoteDidChange` happen on the notification's delivery
///    thread (KVS's own internal queue).
///  - The initial sync flow (ping → delayed read) runs on the main queue.
///  - Never call `synchronize()` — it deadlocks on real devices.

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    // MARK: - KVS Keys
    private let kvsKey     = "syncedServers"
    private let prefKVSKey = "syncedPreferences"

    /// Background queue used ONLY for the initial sync flow (ping → sleep → read).
    // initQueue removed — all KVS access must be on main dispatch queue.

    // MARK: - Notification Observers
    private var kvsObserver: NSObjectProtocol?
    private var udObserver: NSObjectProtocol?

    // MARK: - Debounce / Timers
    private var pushDebounce: DispatchWorkItem?
    private var prefPushDebounce: DispatchWorkItem?
    private var importTimeoutWork: DispatchWorkItem?

    /// Prevents re-entrant updates (remote change → local save → push cycle).
    private var isMerging = false

    /// True while waiting for the initial import after the user first enables sync.
    @Published private(set) var isImporting = false

    /// Whether the UserDefaults observer is active.
    private var isObservingDefaults = false

    /// Time of last sync-date stamp, used to suppress the feedback loop
    /// where stampSyncDate → UD notification → pushPreferences → stamp…
    /// `nonisolated(unsafe)` so DispatchWorkItems on the main queue can write
    /// it without going through MainActor.assumeIsolated (which deadlocks).
    nonisolated(unsafe) private var lastStampTime: TimeInterval = 0

    /// Time of last KVS push, used to suppress bounce-back processing
    /// when KVS fires didChangeExternally for our own writes.
    nonisolated(unsafe) private var lastPushTime: TimeInterval = 0

    private init() {}

    // MARK: - Preference Key Sets

    private let syncStringKeys = [
        "selectedTheme", "liquidGlassStyle", "customAccentHex",
        "defaultTab", "defaultLiveTVView", "streamBufferSize",
        "bgRefreshType", "globalHomeSSIDs"
    ]
    private let syncBoolKeys = [
        "useCustomAccent", "pipEnabled", "preferAVPlayer", "bgRefreshEnabled"
    ]
    private let syncDoubleKeys  = ["networkTimeout"]
    private let syncIntKeys = [
        "maxRetries", "bgRefreshIntervalMins", "bgRefreshHour", "bgRefreshMinute",
        "epgWindowHours"
    ]
    private let syncStringArrayKeys  = ["favoriteChannelIDs"]
    private let syncHiddenGroupKeys = [
        "hiddenChannelGroups", "hiddenMovieGroups", "hiddenSeriesGroups"
    ]

    // MARK: - Start / Stop Observing

    func startObserving() {
        guard isSyncEnabled else {
            debugLog("🔵 SyncManager.startObserving: sync disabled, skipping")
            return
        }
        debugLog("🔵 SyncManager.startObserving: registering KVS observer")

        // Remove previous observer if any.
        if let obs = kvsObserver {
            NotificationCenter.default.removeObserver(obs)
            kvsObserver = nil
        }

        // Use block-based observer with queue: .main so the callback always
        // runs on the literal main dispatch queue.  The old selector-based API
        // delivered on KVS's internal background queue, which triggered
        // dispatch_assert_queue(main) crashes from Swift's @MainActor runtime
        // isolation check on the @objc selector.
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Extract what we need from the notification before crossing isolation boundary.
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated {
                SyncManager.shared.handleRemoteChange(reason: reason)
            }
        }
    }

    private func startObservingDefaults() {
        guard !isObservingDefaults else { return }
        isObservingDefaults = true
        debugLog("🔵 SyncManager: registering UserDefaults observer")

        // Block-based observer on .main queue — same fix as KVS observer.
        udObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SyncManager.shared.handleUserDefaultsChange()
            }
        }
    }

    func stopObserving() {
        if let obs = kvsObserver {
            NotificationCenter.default.removeObserver(obs)
            kvsObserver = nil
        }
        if let obs = udObserver {
            NotificationCenter.default.removeObserver(obs)
            udObserver = nil
        }
        isObservingDefaults = false
    }

    // MARK: - Enable / Disable Sync

    func syncSettingChanged(enabled: Bool) {
        debugLog("🔵 SyncManager.syncSettingChanged: enabled=\(enabled)")
        if enabled {
            isImporting = true
            startObserving()

            // Write the KVS ping on the main dispatch queue (KVS requires it),
            // then check for remote data after a delay on a background queue.
            let serverKey = kvsKey
            let prefKey   = prefKVSKey

            // Step 1: KVS write on literal main dispatch queue.
            DispatchQueue.main.async {
                debugLog("🔵 SyncManager: writing KVS ping")
                NSUbiquitousKeyValueStore.default.set(
                    Date().timeIntervalSince1970, forKey: "lastSyncPing"
                )
                debugLog("🔵 SyncManager: KVS ping written")
            }

            // Step 2: After a delay, read KVS on the main queue.
            // KVS internally calls dispatch_assert_queue(main) for both
            // reads AND writes, so all access must be on the main queue.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                let servers = NSUbiquitousKeyValueStore.default.array(forKey: serverKey) as? [[String: Any]]
                let prefs   = NSUbiquitousKeyValueStore.default.dictionary(forKey: prefKey)
                debugLog("🔵 SyncManager: initial KVS check — servers=\(servers != nil), prefs=\(prefs != nil)")

                // Already on main queue — hop to @MainActor for the merge.
                Task { @MainActor [weak self] in
                    self?.handleImportResult(servers: servers, prefs: prefs)
                }
            }

            // Timeout: if nothing arrives in 12s, stop waiting.
            importTimeoutWork?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.isSyncEnabled, self.isImporting else { return }
                    debugLog("🔵 SyncManager: import timeout — pushing local state")
                    self.isImporting = false
                    self.startObservingDefaults()
                    self.scheduleInitialPush()
                }
            }
            importTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: timeout)
        } else {
            isImporting = false
            importTimeoutWork?.cancel()
            stopObserving()

            // KVS clear on main dispatch queue.
            let sKey = kvsKey
            let pKey = prefKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: sKey)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: pKey)
                debugLog("🔵 SyncManager: cleared KVS data")
            }
        }
    }

    private func handleImportResult(servers: [[String: Any]]?, prefs: [String: Any]?) {
        guard isSyncEnabled, isImporting else { return }

        if servers != nil || prefs != nil {
            importTimeoutWork?.cancel()
            doMerge(servers: servers, isInitial: true)
            doApplyPreferences(prefs: prefs)
            isImporting = false
            startObservingDefaults()
            debugLog("🔵 SyncManager: import complete from initial check")
        } else {
            importTimeoutWork?.cancel()
            isImporting = false
            startObservingDefaults()
            debugLog("🔵 SyncManager: no remote data — will push local state")
            // Schedule push for next run-loop iteration so KVS writes
            // happen in a clean GCD context (via DispatchQueue.main.async).
            scheduleInitialPush()
        }
    }

    /// Schedules the first push (servers + preferences) on the next main-queue
    /// iteration, ensuring KVS writes are on the literal main dispatch queue.
    private func scheduleInitialPush() {
        Task { @MainActor [weak self] in
            guard let self, self.isSyncEnabled else { return }
            debugLog("🔵 SyncManager: initial push — posting syncManagerNeedsPush")
            NotificationCenter.default.post(
                name: .syncManagerNeedsPush,
                object: nil,
                userInfo: ["immediate": true]
            )
            self.doPushPreferences(immediate: true)
        }
    }

    // MARK: - Push Servers (Local → iCloud)

    /// Pushes server configs to KVS.  Serialization happens immediately on
    /// the calling thread (@MainActor).  The KVS write is dispatched to
    /// `DispatchQueue.main.async` to guarantee the literal main dispatch queue.
    func pushServers(_ servers: [ServerConnection], immediate: Bool = false) {
        guard isSyncEnabled, !isMerging else {
            debugLog("🔵 SyncManager.pushServers: skipped (enabled=\(isSyncEnabled), merging=\(isMerging))")
            return
        }

        // Snapshot server data on the calling thread (SwiftData requires main-actor access)
        // but keep it lightweight — defer Keychain reads to the async block.
        debugLog("🔵 SyncManager.pushServers: capturing \(servers.count) servers")
        nonisolated(unsafe) let capturedServers = servers.map { $0 }
        let key = kvsKey

        pushDebounce?.cancel()
        let work = DispatchWorkItem {
            // DispatchWorkItem runs on DispatchQueue.main but is NOT a @MainActor
            // context.  Use assumeIsolated so we can access @MainActor properties
            // (serialize, lastPushTime) without a dispatch_assert_queue crash.
            MainActor.assumeIsolated {
                let mgr = SyncManager.shared
                let payload = capturedServers.map { mgr.serialize($0) }
                mgr.lastPushTime = ProcessInfo.processInfo.systemUptime
                NSUbiquitousKeyValueStore.default.set(payload, forKey: key)
                debugLog("🔵 SyncManager: pushed \(payload.count) servers")
                mgr.stampSyncDate()
            }
        }
        pushDebounce = work

        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
        debugLog("🔵 SyncManager.pushServers: scheduled (immediate=\(immediate))")
    }

    // MARK: - Push Preferences (Local → iCloud)

    func pushPreferences() {
        doPushPreferences(immediate: false)
    }

    func pushPreferencesImmediate() {
        doPushPreferences(immediate: true)
    }

    private func doPushPreferences(immediate: Bool) {
        guard isSyncEnabled, !isMerging else {
            debugLog("🔵 SyncManager.pushPrefs: skipped (enabled=\(isSyncEnabled), merging=\(isMerging))")
            return
        }

        debugLog("🔵 SyncManager.pushPrefs: building snapshot")
        nonisolated(unsafe) let snapshot = buildPreferencesDict()
        let key = prefKVSKey

        prefPushDebounce?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let mgr = SyncManager.shared
                mgr.lastPushTime = ProcessInfo.processInfo.systemUptime
                NSUbiquitousKeyValueStore.default.set(snapshot, forKey: key)
                debugLog("🔵 SyncManager: pushed preferences")
                mgr.stampSyncDate()
            }
        }
        prefPushDebounce = work

        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60.0, execute: work)
        }
        debugLog("🔵 SyncManager.pushPrefs: scheduled (immediate=\(immediate))")
    }

    private func buildPreferencesDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        let ud = UserDefaults.standard
        for k in syncStringKeys      { if let v = ud.string(forKey: k)      { dict[k] = v } }
        for k in syncBoolKeys        { if ud.object(forKey: k) != nil       { dict[k] = ud.bool(forKey: k) } }
        for k in syncDoubleKeys      { if ud.object(forKey: k) != nil       { dict[k] = ud.double(forKey: k) } }
        for k in syncIntKeys         { if ud.object(forKey: k) != nil       { dict[k] = ud.integer(forKey: k) } }
        for k in syncStringArrayKeys { if let v = ud.stringArray(forKey: k) { dict[k] = v } }
        for k in syncHiddenGroupKeys {
            if let data = ud.data(forKey: k),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                dict[k] = arr
            }
        }
        return dict
    }

    /// Stamps the sync date in UserDefaults and records the time for debounce checks.
    func stampSyncDate() {
        lastStampTime = ProcessInfo.processInfo.systemUptime
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "syncLastDate")
    }

    // MARK: - Pull & Merge (iCloud → Local)

    /// Called on the main queue by the block-based KVS notification observer.
    private func handleRemoteChange(reason: Int?) {
        debugLog("🔵 SyncManager.remoteDidChange: fired on main queue, reason=\(String(describing: reason))")

        // Already on main dispatch queue (observer registered with queue: .main).
        let servers = NSUbiquitousKeyValueStore.default.array(forKey: kvsKey) as? [[String: Any]]
        let prefs   = NSUbiquitousKeyValueStore.default.dictionary(forKey: prefKVSKey)
        debugLog("🔵 SyncManager.remoteDidChange: servers=\(servers != nil), prefs=\(prefs != nil)")

        processRemoteChange(servers: servers, prefs: prefs, reason: reason)
    }

    private func processRemoteChange(servers: [[String: Any]]?, prefs: [String: Any]?, reason: Int?) {
        guard isSyncEnabled else { return }

        // Skip bounce-backs: if we pushed within the last 5 seconds, this is
        // likely our own data echoing back. Don't re-merge it.
        let now = ProcessInfo.processInfo.systemUptime
        if !isImporting && (now - lastPushTime) < 5.0 {
            debugLog("🔵 SyncManager.processRemoteChange: skipping bounce-back (\(now - lastPushTime)s since push)")
            return
        }

        if let reason {
            switch reason {
            case NSUbiquitousKeyValueStoreQuotaViolationChange:
                DebugLogger.shared.log("SyncManager: iCloud KVS quota exceeded",
                                       category: "Sync", level: .warning)
                return
            case NSUbiquitousKeyValueStoreAccountChange:
                DebugLogger.shared.log("SyncManager: iCloud account changed",
                                       category: "Sync", level: .info)
            default: break
            }
        }

        let wasImporting = isImporting
        if wasImporting {
            isImporting = false
            importTimeoutWork?.cancel()
            startObservingDefaults()
        }

        debugLog("🔵 SyncManager.processRemoteChange: merging (initial=\(wasImporting))")
        doMerge(servers: servers, isInitial: wasImporting)
        doApplyPreferences(prefs: prefs)
    }

    private func doMerge(servers: [[String: Any]]?, isInitial: Bool) {
        guard let servers else {
            debugLog("🔵 SyncManager.doMerge: no server data")
            return
        }

        isMerging = true
        defer { isMerging = false }

        let remoteServers = servers.compactMap { deserialize($0) }
        debugLog("🔵 SyncManager.doMerge: merging \(remoteServers.count) servers (initial=\(isInitial))")

        NotificationCenter.default.post(
            name: .syncManagerDidReceiveRemoteServers,
            object: nil,
            userInfo: ["servers": remoteServers, "isInitial": isInitial]
        )
    }

    private func doApplyPreferences(prefs: [String: Any]?) {
        guard let dict = prefs else {
            debugLog("🔵 SyncManager.doApplyPreferences: no preference data")
            return
        }

        isMerging = true
        defer { isMerging = false }

        let ud = UserDefaults.standard
        for k in syncStringKeys      { if let v = dict[k] as? String   { ud.set(v, forKey: k) } }
        for k in syncBoolKeys        { if let v = dict[k] as? Bool     { ud.set(v, forKey: k) } }
        for k in syncDoubleKeys      { if let v = dict[k] as? Double   { ud.set(v, forKey: k) } }
        for k in syncIntKeys         { if let v = dict[k] as? Int      { ud.set(v, forKey: k) } }
        for k in syncStringArrayKeys { if let v = dict[k] as? [String] { ud.set(v, forKey: k) } }
        for k in syncHiddenGroupKeys {
            if let arr = dict[k] as? [String],
               let data = try? JSONEncoder().encode(arr.sorted()) {
                ud.set(data, forKey: k)
            }
        }

        NotificationCenter.default.post(name: .syncManagerDidApplyPreferences, object: nil)
        debugLog("🔵 SyncManager.doApplyPreferences: applied")
    }

    // MARK: - UserDefaults Observer

    private var udChangeCount = 0

    /// Called on the main queue by the block-based UserDefaults notification observer.
    private func handleUserDefaultsChange() {
        guard isSyncEnabled, !isMerging else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastStampTime < 3.0 { return }

        udChangeCount += 1
        if udChangeCount <= 3 || udChangeCount % 50 == 0 {
            debugLog("🔵 SyncManager.userDefaultsDidChange: #\(udChangeCount)")
        }
        pushPreferences()
    }

    // MARK: - Credential Sync

    func syncCredentials(for server: ServerConnection) {
        guard isSyncEnabled else { return }
        let id = server.id.uuidString
        KeychainHelper.migrateToSynchronizable(key: "password_\(id)")
        KeychainHelper.migrateToSynchronizable(key: "apiKey_\(id)")
    }

    func saveCredentialsSynced(for server: ServerConnection) {
        guard isSyncEnabled else {
            server.saveCredentialsToKeychain()
            return
        }
        let pw  = server.effectivePassword.isEmpty ? server.password : server.effectivePassword
        let key = server.effectiveApiKey.isEmpty ? server.apiKey : server.effectiveApiKey
        let id  = server.id.uuidString

        if !pw.isEmpty {
            KeychainHelper.save(pw, for: "password_\(id)")
            KeychainHelper.save(pw, for: "password_\(id)", synchronizable: true)
            server.password = ""
        }
        if !key.isEmpty {
            KeychainHelper.save(key, for: "apiKey_\(id)")
            KeychainHelper.save(key, for: "apiKey_\(id)", synchronizable: true)
            server.apiKey = ""
        }
    }

    // MARK: - Serialization

    private func serialize(_ server: ServerConnection) -> [String: Any] {
        debugLog("🔵 SyncManager.serialize: \(server.name), thread=\(Thread.current)")
        var dict: [String: Any] = [
            "id": server.id.uuidString,
            "name": server.name,
            "type": server.type.rawValue,
            "baseURL": server.baseURL,
            "username": server.username,
            "epgURL": server.epgURL,
            "isActive": server.isActive,
            "sortOrder": server.sortOrder,
            "createdAt": server.createdAt.timeIntervalSince1970,
            "isVerified": server.isVerified,
            "localURL": server.localURL,
            "localEPGURL": server.localEPGURL,
            "homeSSID": server.homeSSID
        ]
        if let lastConnected = server.lastConnected {
            dict["lastConnected"] = lastConnected.timeIntervalSince1970
        }
        // Include credentials so they arrive with the config — iCloud Keychain
        // sync is too slow to rely on.  KVS is per-Apple-ID and encrypted.
        debugLog("🔵 SyncManager.serialize: reading effectivePassword, thread=\(Thread.current)")
        let pw = server.effectivePassword
        debugLog("🔵 SyncManager.serialize: reading effectiveApiKey, thread=\(Thread.current)")
        let ak = server.effectiveApiKey
        if !pw.isEmpty { dict["_password"] = pw }
        if !ak.isEmpty { dict["_apiKey"] = ak }
        debugLog("🔵 SyncManager.serialize: done (hasPw=\(!pw.isEmpty), hasKey=\(!ak.isEmpty))")
        return dict
    }

    private nonisolated func deserialize(_ dict: [String: Any]) -> SyncedServer? {
        guard let idStr   = dict["id"] as? String,
              let id      = UUID(uuidString: idStr),
              let name    = dict["name"] as? String,
              let typeRaw = dict["type"] as? String,
              let type    = ServerType(rawValue: typeRaw),
              let baseURL = dict["baseURL"] as? String else { return nil }

        return SyncedServer(
            id: id, name: name, type: type, baseURL: baseURL,
            username:      dict["username"]  as? String ?? "",
            epgURL:        dict["epgURL"]    as? String ?? "",
            isActive:      dict["isActive"]  as? Bool   ?? false,
            sortOrder:     dict["sortOrder"] as? Int    ?? 0,
            createdAt:     Date(timeIntervalSince1970: dict["createdAt"] as? TimeInterval ?? 0),
            lastConnected: (dict["lastConnected"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) },
            isVerified:    dict["isVerified"]  as? Bool   ?? false,
            localURL:      dict["localURL"]    as? String ?? "",
            localEPGURL:   dict["localEPGURL"] as? String ?? "",
            homeSSID:      dict["homeSSID"]    as? String ?? "",
            password:      dict["_password"]   as? String ?? "",
            apiKey:        dict["_apiKey"]     as? String ?? ""
        )
    }

    // MARK: - Helpers

    var isSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
    }
}

// MARK: - Synced Server
struct SyncedServer: Sendable {
    let id: UUID
    let name: String
    let type: ServerType
    let baseURL: String
    let username: String
    let epgURL: String
    let isActive: Bool
    let sortOrder: Int
    let createdAt: Date
    let lastConnected: Date?
    let isVerified: Bool
    let localURL: String
    let localEPGURL: String
    let homeSSID: String
    let password: String
    let apiKey: String
}

// MARK: - Notification Names
extension Notification.Name {
    static let syncManagerDidReceiveRemoteServers = Notification.Name("syncManagerDidReceiveRemoteServers")
    static let syncManagerDidApplyPreferences = Notification.Name("syncManagerDidApplyPreferences")
    static let syncManagerNeedsPush = Notification.Name("syncManagerNeedsPush")
    static let stopPlaybackForBackground = Notification.Name("stopPlaybackForBackground")
}
