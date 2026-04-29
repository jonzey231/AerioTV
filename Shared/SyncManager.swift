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
    private let watchProgressKVSKey = "syncedWatchProgress"
    private let reminderKVSKey = "syncedReminders"

    /// Background queue used ONLY for the initial sync flow (ping → sleep → read).
    // initQueue removed — all KVS access must be on main dispatch queue.

    // MARK: - Notification Observers
    private var kvsObserver: NSObjectProtocol?
    private var udObserver: NSObjectProtocol?
    private var reminderObserver: NSObjectProtocol?

    // MARK: - Debounce / Timers
    private var pushDebounce: DispatchWorkItem?
    private var prefPushDebounce: DispatchWorkItem?
    private var watchProgressPushDebounce: DispatchWorkItem?
    private var reminderPushDebounce: DispatchWorkItem?
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
        "bgRefreshType", "globalHomeSSIDs",
        // Guide Display palette overrides — one hex string per
        // category bucket. Missing keys fall through to the defaults
        // in `ProgramCategory.defaultHex`, so clients running older
        // builds that don't know about these keys are safe.
        "categoryColor.sports", "categoryColor.movie",
        "categoryColor.kids",   "categoryColor.news",
        // Additional buckets added with the "Add more categories"
        // disclosure section. Same safety property as above —
        // older clients ignore unknown keys.
        "categoryColor.documentary", "categoryColor.drama",
        "categoryColor.comedy",      "categoryColor.reality",
        "categoryColor.educational", "categoryColor.scifi",
        "categoryColor.music"
    ]
    /// Data-typed keys (Codable JSON blobs). `customCategoryColors.v1`
    /// holds the user-defined `[CustomCategory]` list from
    /// `CategoryColor.loadCustomCategories()` — it needs its own
    /// sync lane because it's stored as Data in UserDefaults, not
    /// a plain String/Bool/Number.
    private let syncDataKeys: [String] = [
        CategoryColor.customCategoriesKey
    ]
    private let syncBoolKeys = [
        "useCustomAccent", "preferAVPlayer", "bgRefreshEnabled",
        // Guide Display master toggle + channel-card stripe companion.
        "enableCategoryColors", "tintChannelCards",
        // Per-bucket enable flags for the additional (non-default)
        // buckets surfaced in "Add more categories". Default buckets
        // are always on, so we only sync the additional flags.
        "categoryBucketEnabled.documentary", "categoryBucketEnabled.drama",
        "categoryBucketEnabled.comedy",      "categoryBucketEnabled.reality",
        "categoryBucketEnabled.educational", "categoryBucketEnabled.scifi",
        "categoryBucketEnabled.music"
    ]
    private let syncDoubleKeys  = ["networkTimeout"]
    private let syncIntKeys = [
        "maxRetries", "bgRefreshIntervalMins", "bgRefreshHour", "bgRefreshMinute",
        "epgWindowHours"
    ]
    // `favoriteChannelIDs` carries the membership Set; `favoriteOrder`
    // carries the user's manual drag-reorder positions from the iOS
    // Favorites tab. Both are plain `[String]` so they share the same
    // sync path. Kept distinct so older clients that only know about
    // the membership key keep working.
    private let syncStringArrayKeys  = ["favoriteChannelIDs", "favoriteOrder"]
    private let syncHiddenGroupKeys = [
        "hiddenChannelGroups", "hiddenMovieGroups", "hiddenSeriesGroups"
    ]

    // MARK: - Start / Stop Observing

    func startObserving() {
        guard isSyncEnabled else {
            debugLog("🔵 SyncManager.startObserving: sync disabled, skipping")
            return
        }
        // Skip if already observing — avoids remove-then-re-add churn on every foreground.
        guard kvsObserver == nil else { return }
        debugLog("🔵 SyncManager.startObserving: registering KVS observer")

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

        // Observe local reminder changes to push to iCloud
        if reminderObserver == nil {
            reminderObserver = NotificationCenter.default.addObserver(
                forName: .remindersDidChange,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    SyncManager.shared.pushReminders()
                }
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
        if let obs = reminderObserver {
            NotificationCenter.default.removeObserver(obs)
            reminderObserver = nil
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
            let wpKey = self.watchProgressKVSKey
            let rKey  = self.reminderKVSKey
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                let servers   = NSUbiquitousKeyValueStore.default.array(forKey: serverKey) as? [[String: Any]]
                let prefs     = NSUbiquitousKeyValueStore.default.dictionary(forKey: prefKey)
                let wp        = NSUbiquitousKeyValueStore.default.array(forKey: wpKey) as? [[String: Any]]
                let reminders = NSUbiquitousKeyValueStore.default.array(forKey: rKey) as? [[String: Any]]
                debugLog("🔵 SyncManager: initial KVS check — servers=\(servers != nil), prefs=\(prefs != nil), watchProgress=\(wp != nil), reminders=\(reminders != nil)")

                Task { @MainActor [weak self] in
                    self?.handleImportResult(servers: servers, prefs: prefs, watchProgress: wp, reminders: reminders)
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
            let wpKey = watchProgressKVSKey
            let rKey = reminderKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: sKey)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: pKey)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: wpKey)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: rKey)
                debugLog("🔵 SyncManager: cleared KVS data")
            }
        }
    }

    /// Wipe all iCloud-side state for this app — payloads in
    /// iCloud KVS plus the synchronizable copies of credentials in
    /// iCloud Keychain. **Local data on this device is preserved**:
    /// SwiftData servers, the local-only Keychain copies of
    /// passwords/API keys, and UserDefaults all stay intact, so
    /// the app keeps working on this device. The intent is "wipe
    /// the cloud and start fresh" — useful when a user wants to
    /// clear stale or corrupted sync state across their fleet
    /// without losing access on any individual device.
    ///
    /// What this clears:
    ///   • KVS keys: `syncedServers`, `syncedPreferences`,
    ///     `syncedWatchProgress`, `syncedReminders`, `lastSyncPing`.
    ///   • iCloud Keychain entries: `password_<id>` and
    ///     `apiKey_<id>` (both `synchronizable: true`) for every
    ///     local server. Local-only Keychain copies are not touched.
    ///   • Launch-task gating flags
    ///     (`kvsToKeychainMigrationDoneV1`,
    ///     `kvsCredentialPurgeDoneV1`). Resetting them lets a
    ///     subsequent re-enable of Sync trigger a clean migration
    ///     from local Keychain → iCloud Keychain on this device,
    ///     replicating what a brand-new install would do.
    ///
    /// Pending debounced pushes are cancelled first so an in-flight
    /// `pushServers` debounce doesn't immediately repopulate the
    /// cloud from this device.
    ///
    /// **Note on sync state:** the iCloud-Sync toggle is left
    /// alone. After `clearAllICloudData` returns, if Sync is still
    /// enabled the next natural push (or a manual "Sync Now") will
    /// repopulate the cloud with this device's local state — which
    /// is exactly what users typically want from "start fresh."
    /// To fully detach, the caller should also flip the toggle off
    /// after invoking this.
    @MainActor
    func clearAllICloudData(localServers: [ServerConnection]) {
        debugLog("🔵 SyncManager.clearAllICloudData: starting (local servers=\(localServers.count))")

        // Cancel pending debounces so they don't race the wipe.
        pushDebounce?.cancel(); pushDebounce = nil
        prefPushDebounce?.cancel(); prefPushDebounce = nil
        watchProgressPushDebounce?.cancel(); watchProgressPushDebounce = nil
        reminderPushDebounce?.cancel(); reminderPushDebounce = nil

        // KVS removal — must run on the literal main dispatch queue.
        // We're already on @MainActor but `dispatch_assert_queue(main)`
        // checks the GCD queue identity, not the actor, so we hop
        // explicitly. Synchronize after to push the deletes out
        // immediately rather than waiting for the next idle window.
        let sKey  = kvsKey
        let pKey  = prefKVSKey
        let wpKey = watchProgressKVSKey
        let rKey  = reminderKVSKey
        DispatchQueue.main.async {
            let kvs = NSUbiquitousKeyValueStore.default
            kvs.removeObject(forKey: sKey)
            kvs.removeObject(forKey: pKey)
            kvs.removeObject(forKey: wpKey)
            kvs.removeObject(forKey: rKey)
            kvs.removeObject(forKey: "lastSyncPing")
            kvs.synchronize()
            debugLog("🔵 SyncManager.clearAllICloudData: KVS payloads cleared")
        }

        // iCloud Keychain — only the synchronizable copies. Local
        // copies are intentionally preserved so this device keeps
        // working without re-auth.
        var keychainCleared = 0
        for server in localServers {
            let id = server.id.uuidString
            if KeychainHelper.delete("password_\(id)", synchronizable: true) {
                keychainCleared += 1
            }
            if KeychainHelper.delete("apiKey_\(id)", synchronizable: true) {
                keychainCleared += 1
            }
        }

        // Reset launch-task gating so a future Sync re-enable can
        // run the migration + purge cleanly. No-op when the flags
        // weren't set; safe regardless.
        UserDefaults.standard.removeObject(forKey: "kvsToKeychainMigrationDoneV1")
        UserDefaults.standard.removeObject(forKey: "kvsCredentialPurgeDoneV1")

        debugLog("🔵 SyncManager.clearAllICloudData: cleared \(keychainCleared) iCloud Keychain entries, reset migration flags")
    }

    // MARK: - Scoped Delete (v1.6.17)

    /// Wipes a single category's iCloud payload without touching the rest.
    /// Used by the per-row "Delete from iCloud" buttons in the granular
    /// Sync Categories Settings sub-section. Local data on this device is
    /// preserved — only the cloud copy is removed.
    @MainActor
    func clearCloudCategory(_ category: SyncCategory, localServers: [ServerConnection]) {
        debugLog("🔵 SyncManager.clearCloudCategory: starting category=\(category.rawValue)")

        switch category {
        case .servers:
            pushDebounce?.cancel(); pushDebounce = nil
            let key = kvsKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared servers KVS")
            }
        case .watchProgress:
            watchProgressPushDebounce?.cancel(); watchProgressPushDebounce = nil
            let key = watchProgressKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared watch progress KVS")
            }
        case .reminders:
            reminderPushDebounce?.cancel(); reminderPushDebounce = nil
            let key = reminderKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared reminders KVS")
            }
        case .preferences:
            prefPushDebounce?.cancel(); prefPushDebounce = nil
            let key = prefKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared preferences KVS")
            }
        case .credentials:
            // Mirrors the credentials-only portion of clearAllICloudData.
            var keychainCleared = 0
            for server in localServers {
                let id = server.id.uuidString
                if KeychainHelper.delete("password_\(id)", synchronizable: true) {
                    keychainCleared += 1
                }
                if KeychainHelper.delete("apiKey_\(id)", synchronizable: true) {
                    keychainCleared += 1
                }
            }
            // Reset migration flags so re-enabling credential sync later
            // can re-migrate cleanly (matches clearAllICloudData).
            UserDefaults.standard.removeObject(forKey: "kvsToKeychainMigrationDoneV1")
            UserDefaults.standard.removeObject(forKey: "kvsCredentialPurgeDoneV1")
            debugLog("🔵 SyncManager.clearCloudCategory: cleared \(keychainCleared) iCloud Keychain entries")
        }
    }

    private func handleImportResult(servers: [[String: Any]]?, prefs: [String: Any]?,
                                     watchProgress: [[String: Any]]? = nil,
                                     reminders: [[String: Any]]? = nil) {
        guard isSyncEnabled, isImporting else { return }

        if servers != nil || prefs != nil || watchProgress != nil || reminders != nil {
            importTimeoutWork?.cancel()
            doMerge(servers: servers, isInitial: true)
            doApplyPreferences(prefs: prefs)
            mergeRemoteWatchProgress(watchProgress)
            mergeRemoteReminders(reminders)
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
            self.pushReminders(immediate: true)
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
        // v1.6.17 — granular per-category gate.
        guard SyncCategory.servers.isEnabled else {
            debugLog("🔵 SyncManager.pushServers: category disabled by user")
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

        // v1.6.17 — the per-category sync toggles ALWAYS round-trip through
        // the prefs lane so a fresh device picks them up on its first import,
        // and so a flip on iPhone reaches iPad even if "App Preferences" sync
        // is otherwise off. The remaining prefs are gated by the user's
        // "App Preferences" category toggle below.
        for k in SyncCategory.allDefaultsKeys {
            if ud.object(forKey: k) != nil { dict[k] = ud.bool(forKey: k) }
        }

        // Granular gate: when "App Preferences" sync is off, push only the
        // toggle subset above and bail. The other devices' caches stay
        // whatever the user set them to locally.
        guard SyncCategory.preferences.isEnabled else {
            return dict
        }

        for k in syncStringKeys      { if let v = ud.string(forKey: k)      { dict[k] = v } }
        for k in syncBoolKeys        { if ud.object(forKey: k) != nil       { dict[k] = ud.bool(forKey: k) } }
        for k in syncDoubleKeys      { if ud.object(forKey: k) != nil       { dict[k] = ud.double(forKey: k) } }
        for k in syncIntKeys         { if ud.object(forKey: k) != nil       { dict[k] = ud.integer(forKey: k) } }
        // Data-typed keys are mirrored through KVS as Data so
        // complex blobs like the custom-categories JSON list
        // round-trip intact across devices.
        for k in syncDataKeys        { if let v = ud.data(forKey: k)        { dict[k] = v } }
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
        let servers   = NSUbiquitousKeyValueStore.default.array(forKey: kvsKey) as? [[String: Any]]
        let prefs     = NSUbiquitousKeyValueStore.default.dictionary(forKey: prefKVSKey)
        let wp        = NSUbiquitousKeyValueStore.default.array(forKey: watchProgressKVSKey) as? [[String: Any]]
        let reminders = NSUbiquitousKeyValueStore.default.array(forKey: reminderKVSKey) as? [[String: Any]]
        debugLog("🔵 SyncManager.remoteDidChange: servers=\(servers != nil), prefs=\(prefs != nil), wp=\(wp != nil), reminders=\(reminders != nil)")

        processRemoteChange(servers: servers, prefs: prefs, watchProgress: wp, reminders: reminders, reason: reason)
    }

    private func processRemoteChange(servers: [[String: Any]]?, prefs: [String: Any]?,
                                     watchProgress: [[String: Any]]? = nil,
                                     reminders: [[String: Any]]? = nil,
                                     reason: Int?) {
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
        mergeRemoteWatchProgress(watchProgress)
        mergeRemoteReminders(reminders)
    }

    private func doMerge(servers: [[String: Any]]?, isInitial: Bool) {
        guard let servers else {
            debugLog("🔵 SyncManager.doMerge: no server data")
            return
        }
        // v1.6.17 — granular per-category gate. When the user opts out of
        // server sync on this device, ignore remote server payloads (their
        // local server list stays authoritative for this device).
        guard SyncCategory.servers.isEnabled else {
            debugLog("🔵 SyncManager.doMerge: category disabled by user, ignoring remote payload")
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

        // v1.6.17 — the per-category sync toggle states ALWAYS apply, even
        // when the user has "App Preferences" sync turned off. Otherwise a
        // user who disabled "App Preferences" sync on iPhone could never
        // re-enable it from iPad (the iPhone would never receive the flip).
        for k in SyncCategory.allDefaultsKeys {
            if let v = dict[k] as? Bool { ud.set(v, forKey: k) }
        }

        // Granular gate: when "App Preferences" sync is off on this device,
        // bail before applying the rest of the prefs payload. Local prefs
        // stay authoritative; the toggle flips above still propagated.
        guard SyncCategory.preferences.isEnabled else {
            debugLog("🔵 SyncManager.doApplyPreferences: category disabled by user, applied toggle subset only")
            return
        }

        for k in syncStringKeys      { if let v = dict[k] as? String   { ud.set(v, forKey: k) } }
        for k in syncBoolKeys        { if let v = dict[k] as? Bool     { ud.set(v, forKey: k) } }
        for k in syncDoubleKeys      { if let v = dict[k] as? Double   { ud.set(v, forKey: k) } }
        for k in syncIntKeys         { if let v = dict[k] as? Int      { ud.set(v, forKey: k) } }
        for k in syncDataKeys        { if let v = dict[k] as? Data     { ud.set(v, forKey: k) } }
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
        // v1.6.17 — when the user opts out of credential sync, leave any
        // existing keychain entries on this device alone (don't migrate
        // them to synchronizable). Note: existing already-synchronizable
        // entries from prior versions can still appear on other devices
        // until "Delete Credentials from iCloud" is invoked from
        // Settings — this only affects what we migrate going forward.
        guard SyncCategory.credentials.isEnabled else {
            debugLog("🔵 SyncManager.syncCredentials: category disabled by user")
            return
        }
        let id = server.id.uuidString
        KeychainHelper.migrateToSynchronizable(key: "password_\(id)")
        KeychainHelper.migrateToSynchronizable(key: "apiKey_\(id)")
    }

    func saveCredentialsSynced(for server: ServerConnection) {
        guard isSyncEnabled else {
            server.saveCredentialsToKeychain()
            return
        }
        // v1.6.17 — granular per-category gate. Fall back to local-only
        // keychain saves so a credential change doesn't leak across
        // devices when the user opted out.
        guard SyncCategory.credentials.isEnabled else {
            debugLog("🔵 SyncManager.saveCredentialsSynced: category disabled by user, saving locally")
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
        // v1.6.12: credentials are no longer written to iCloud KVS.
        //
        // Pre-v1.6.8 we shipped passwords + API keys as `_password` /
        // `_apiKey` keys inside the per-server dict because iCloud
        // Keychain replication was historically slow / unreliable
        // and KVS round-tripped within a couple of seconds. v1.6.8
        // (Codex D1) added direct iCloud Keychain replication for
        // both fields — and Apple has since made Keychain sync
        // genuinely fast — so the KVS plaintext is now strictly
        // worse: it duplicates the secret material in a separate
        // store with weaker access controls than the Keychain we're
        // already using.
        //
        // The deserialize side still reads `_password` / `_apiKey`
        // (see below) so legacy KVS payloads written by older
        // clients are adopted into Keychain on this device, and the
        // one-shot purge task in `AerioApp` schedules an immediate
        // push after launch to actively overwrite any plaintext
        // still parked in the cloud.
        return dict
    }

    private nonisolated func deserialize(_ dict: [String: Any]) -> SyncedServer? {
        guard let idStr   = dict["id"] as? String,
              let id      = UUID(uuidString: idStr),
              let name    = dict["name"] as? String,
              let typeRaw = dict["type"] as? String,
              let type    = ServerType(rawValue: typeRaw),
              let baseURL = dict["baseURL"] as? String else { return nil }

        // `_password` / `_apiKey` are read here purely for **legacy
        // adoption**. v1.6.12 stopped writing them to KVS (see
        // `serialize` for the rationale), but a payload pushed by
        // an older client — or by a still-pre-v1.6.12 device on the
        // same Apple ID — will still carry them. When found, the
        // existing `mergeRemoteServers` path persists them into the
        // local + iCloud Keychain copies, and the launch-time
        // purge task in `AerioApp` then overwrites the cloud KVS
        // with a credential-free payload. So the plaintext flows
        // through this code one last time on each device's first
        // upgraded launch and never again.
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

    // MARK: - Watch Progress Sync

    private func serializeWatchProgress(_ p: WatchProgress) -> [String: Any] {
        var dict: [String: Any] = [
            "vodID": p.vodID,
            "title": p.title,
            "positionMs": Int(p.positionMs),
            "durationMs": Int(p.durationMs),
            "vodType": p.vodType,
            "updatedAt": p.updatedAt.timeIntervalSince1970,
            "isFinished": p.isFinished
        ]
        if let v = p.posterURL  { dict["posterURL"]  = v }
        if let v = p.streamURL  { dict["streamURL"]  = v }
        if let v = p.serverID   { dict["serverID"]   = v }
        // v1.6.8 (Codex A3): Carry `seriesID` across the iCloud-sync
        // boundary so Top Shelf episode deep-links work after a
        // cross-device hand-off. Without this, a resume started on
        // iPhone would sync to Apple TV with `seriesID = nil`, which
        // fell through to the `aerio://vod/episode/...` fallback in
        // the Top Shelf extension (no standalone episode detail
        // view exists, so that deep link dead-ended).
        if let v = p.seriesID   { dict["seriesID"]   = v }
        return dict
    }

    private struct SyncedWatchProgress {
        let vodID: String
        let title: String
        let positionMs: Int32
        let durationMs: Int32
        let posterURL: String?
        let vodType: String
        let updatedAt: Date
        let isFinished: Bool
        let streamURL: String?
        let serverID: String?
        /// Parent series ID for episode-type progress entries (nil for
        /// movies). Carried through iCloud sync as of v1.6.8 — see
        /// `serializeWatchProgress` comment for context.
        let seriesID: String?
    }

    nonisolated private func deserializeWatchProgress(_ dict: [String: Any]) -> SyncedWatchProgress? {
        guard let vodID = dict["vodID"] as? String,
              let ts = dict["updatedAt"] as? TimeInterval else { return nil }
        return SyncedWatchProgress(
            vodID: vodID,
            title: dict["title"] as? String ?? "",
            positionMs: Int32(dict["positionMs"] as? Int ?? 0),
            durationMs: Int32(dict["durationMs"] as? Int ?? 0),
            posterURL: dict["posterURL"] as? String,
            vodType: dict["vodType"] as? String ?? "movie",
            updatedAt: Date(timeIntervalSince1970: ts),
            isFinished: dict["isFinished"] as? Bool ?? false,
            streamURL: dict["streamURL"] as? String,
            serverID: dict["serverID"] as? String,
            seriesID: dict["seriesID"] as? String
        )
    }

    /// Push all local watch progress entries to KVS (debounced).
    func pushWatchProgress(_ entries: [WatchProgress], immediate: Bool = false) {
        guard isSyncEnabled, !isMerging else { return }
        // v1.6.17 — granular per-category gate.
        guard SyncCategory.watchProgress.isEnabled else {
            debugLog("🔵 SyncManager.pushWatchProgress: category disabled by user")
            return
        }

        let payload = entries.map { serializeWatchProgress($0) }
        nonisolated(unsafe) let capturedPayload = payload

        watchProgressPushDebounce?.cancel()
        let key = watchProgressKVSKey
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.lastPushTime = ProcessInfo.processInfo.systemUptime
            }
            NSUbiquitousKeyValueStore.default.set(capturedPayload, forKey: key)
            debugLog("🔵 SyncManager: pushed \(capturedPayload.count) watch progress entries to KVS")
        }
        watchProgressPushDebounce = work
        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
        }
    }

    /// Merge remote watch progress into local SwiftData.
    ///
    /// **v1.6.11 crash fix.** Previously this method keyed both
    /// the remote and local lookups by `vodID` alone via
    /// `Dictionary(uniqueKeysWithValues:)`, which traps on
    /// duplicate keys. v1.6.8 (Codex A1) dropped the
    /// `@Attribute(.unique)` constraint on `WatchProgress.vodID`
    /// because two different servers will routinely use the same
    /// numeric ID for unrelated content — uniqueness moved into
    /// `(vodID, serverID)`. The merge path was never updated to
    /// match: any user with resume progress on the same `vodID`
    /// across two servers (i.e., two Dispatcharr instances pulling
    /// from overlapping providers) hit a hard crash inside
    /// `pullFromCloud` the first time iCloud KVS pushed those
    /// entries down. Keys are now composite (`serverID|vodID`) and
    /// dictionary construction uses `uniquingKeysWith:` so neither
    /// path can ever trap on a duplicate again — if two payloads
    /// share a composite key (corrupted state, double-push race),
    /// the most recently updated wins.
    private func mergeRemoteWatchProgress(_ remoteEntries: [[String: Any]]?) {
        guard let remoteEntries, !remoteEntries.isEmpty else { return }
        guard let context = WatchProgressManager.modelContext else { return }
        // v1.6.17 — granular per-category gate. Local watch progress
        // stays authoritative on this device when the user opts out.
        guard SyncCategory.watchProgress.isEnabled else {
            debugLog("🔵 SyncManager.mergeRemoteWatchProgress: category disabled by user, ignoring \(remoteEntries.count) remote entries")
            return
        }

        isMerging = true
        defer { isMerging = false }

        // Composite key: same vodID across different servers is a
        // legitimate post-A1 state and must not collide. Empty
        // string when serverID is nil so legacy rows still hash
        // deterministically. Helper takes the two strings directly
        // because `remotes` is `[SyncedWatchProgress]` (the DTO)
        // while `locals` is `[WatchProgress]` (SwiftData model)
        // — both expose `vodID` + `serverID` but aren't the same
        // type.
        func compositeKey(_ vodID: String, _ serverID: String?) -> String {
            "\(serverID ?? "")|\(vodID)"
        }

        let remotes = remoteEntries.compactMap { deserializeWatchProgress($0) }
        let remoteByID = Dictionary(
            remotes.map { (compositeKey($0.vodID, $0.serverID), $0) },
            uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b }
        )
        let remoteKeys = Set(remoteByID.keys)

        // Fetch all local entries
        let descriptor = FetchDescriptor<WatchProgress>()
        guard let locals = try? context.fetch(descriptor) else { return }
        let localByID = Dictionary(
            locals.map { (compositeKey($0.vodID, $0.serverID), $0) },
            uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b }
        )

        // Upsert remote → local
        for remote in remotes {
            if let local = localByID[compositeKey(remote.vodID, remote.serverID)] {
                // Conflict: most recent updatedAt wins
                if remote.updatedAt > local.updatedAt {
                    local.title = remote.title
                    local.positionMs = remote.positionMs
                    local.durationMs = remote.durationMs
                    local.posterURL = remote.posterURL
                    local.vodType = remote.vodType
                    local.updatedAt = remote.updatedAt
                    local.isFinished = remote.isFinished
                    local.streamURL = remote.streamURL
                    local.serverID = remote.serverID
                    local.seriesID = remote.seriesID
                }
            } else {
                // Insert new
                let wp = WatchProgress(
                    vodID: remote.vodID, title: remote.title,
                    positionMs: remote.positionMs, durationMs: remote.durationMs,
                    posterURL: remote.posterURL, vodType: remote.vodType,
                    updatedAt: remote.updatedAt, isFinished: remote.isFinished,
                    streamURL: remote.streamURL, serverID: remote.serverID,
                    seriesID: remote.seriesID
                )
                context.insert(wp)
            }
        }

        // Delete locals that are absent from remote (deleted on other device)
        for local in locals {
            if !remoteKeys.contains(compositeKey(local.vodID, local.serverID)) {
                context.delete(local)
            }
        }

        try? context.save()
        debugLog("🔵 SyncManager: merged \(remotes.count) remote watch progress entries")

        NotificationCenter.default.post(name: .syncManagerDidUpdateWatchProgress, object: nil)
    }

    // MARK: - Reminder Sync

    /// Push local reminders to iCloud KVS (debounced).
    func pushReminders(immediate: Bool = false) {
        guard isSyncEnabled, !isMerging else { return }
        // v1.6.17 — granular per-category gate.
        guard SyncCategory.reminders.isEnabled else {
            debugLog("🔵 SyncManager.pushReminders: category disabled by user")
            return
        }

        let reminders = ReminderManager.shared.syncableReminders
        var payload: [[String: Any]] = []
        for (key, r) in reminders {
            payload.append([
                "key": key,
                "programTitle": r.programTitle,
                "channelName": r.channelName,
                "startTime": r.startTime.timeIntervalSince1970,
                "updatedAt": r.updatedAt.timeIntervalSince1970
            ])
        }
        nonisolated(unsafe) let capturedPayload = payload

        reminderPushDebounce?.cancel()
        let key = reminderKVSKey
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                SyncManager.shared.lastPushTime = ProcessInfo.processInfo.systemUptime
            }
            NSUbiquitousKeyValueStore.default.set(capturedPayload, forKey: key)
            debugLog("🔵 SyncManager: pushed \(capturedPayload.count) reminders to KVS")
        }
        reminderPushDebounce = work
        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
    }

    /// Merge remote reminders from iCloud into local ReminderManager.
    private func mergeRemoteReminders(_ remoteEntries: [[String: Any]]?) {
        guard let remoteEntries else { return }
        // v1.6.17 — granular per-category gate.
        guard SyncCategory.reminders.isEnabled else {
            debugLog("🔵 SyncManager.mergeRemoteReminders: category disabled by user, ignoring \(remoteEntries.count) remote entries")
            return
        }

        isMerging = true
        defer { isMerging = false }

        var remoteReminders: [String: SyncableReminder] = [:]
        for dict in remoteEntries {
            guard let key       = dict["key"] as? String,
                  let title     = dict["programTitle"] as? String,
                  let channel   = dict["channelName"] as? String,
                  let startTs   = dict["startTime"] as? TimeInterval,
                  let updatedTs = dict["updatedAt"] as? TimeInterval else { continue }
            remoteReminders[key] = SyncableReminder(
                programTitle: title,
                channelName: channel,
                startTime: Date(timeIntervalSince1970: startTs),
                updatedAt: Date(timeIntervalSince1970: updatedTs)
            )
        }

        ReminderManager.shared.mergeRemote(remoteReminders)
        debugLog("🔵 SyncManager: merged \(remoteReminders.count) remote reminders")
    }

    // MARK: - Active Pull (foreground resume)

    /// Reads ALL KVS keys and merges remote data into local state.
    /// Called every time the app enters the foreground so changes made
    /// on other devices are picked up immediately — even when no KVS
    /// `didChangeExternally` notification was delivered (common on tvOS).
    /// Timestamp of last pull — used to throttle so we don't re-merge on
    /// every scenePhase == .active (which fires frequently on tvOS).
    nonisolated(unsafe) private static var lastPullTime: TimeInterval = 0

    func pullFromCloud() {
        guard isSyncEnabled, !isMerging, !isImporting else { return }

        // Throttle: skip if we pulled within the last 60 seconds
        let now = ProcessInfo.processInfo.systemUptime
        guard now - Self.lastPullTime > 60 else {
            debugLog("🔵 SyncManager.pullFromCloud: throttled (\(Int(now - Self.lastPullTime))s since last)")
            return
        }
        Self.lastPullTime = now
        debugLog("🔵 SyncManager.pullFromCloud: reading KVS on foreground")

        let sKey = kvsKey
        let pKey = prefKVSKey
        let wpKey = watchProgressKVSKey
        let rKey = reminderKVSKey

        // Read KVS off the main thread — reads are thread-safe (local cache).
        // Merge still runs on MainActor (required by @MainActor isolation).
        Task.detached(priority: .utility) {
            let servers   = NSUbiquitousKeyValueStore.default.array(forKey: sKey) as? [[String: Any]]
            let prefs     = NSUbiquitousKeyValueStore.default.dictionary(forKey: pKey)
            let wp        = NSUbiquitousKeyValueStore.default.array(forKey: wpKey) as? [[String: Any]]
            let reminders = NSUbiquitousKeyValueStore.default.array(forKey: rKey) as? [[String: Any]]

            guard servers != nil || prefs != nil || wp != nil || reminders != nil else {
                debugLog("🔵 SyncManager.pullFromCloud: no remote data")
                return
            }

            // Hop to MainActor for EACH merge step separately so the
            // main runloop can drain any queued UI work between them.
            // A single `MainActor.run { ... }` block that did all four
            // merges back-to-back showed up as a ~1.8s main-thread
            // hang on app launch; splitting gives the runloop room to
            // pump events (channel-fetch completion callbacks,
            // SwiftUI re-renders, etc.) between the SwiftData-heavy
            // watch-progress upsert and the reminder merge.
            await MainActor.run { SyncManager.shared.doMerge(servers: servers, isInitial: false) }
            await MainActor.run { SyncManager.shared.doApplyPreferences(prefs: prefs) }
            await MainActor.run { SyncManager.shared.mergeRemoteWatchProgress(wp) }
            await MainActor.run { SyncManager.shared.mergeRemoteReminders(reminders) }
            await MainActor.run { debugLog("🔵 SyncManager.pullFromCloud: merge complete") }
        }
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
    static let watchProgressDidChange = Notification.Name("watchProgressDidChange")
    static let syncManagerDidUpdateWatchProgress = Notification.Name("syncManagerDidUpdateWatchProgress")
    static let remindersDidChange = Notification.Name("remindersDidChange")
    /// Posted when the Top Shelf extension (or any other source) opens a
    /// channel deep link. userInfo["channelID"] contains the channel ID.
    static let aerioOpenChannel = Notification.Name("aerioOpenChannel")
    /// Posted when a VOD deep link is opened.
    /// userInfo["vodID"] and userInfo["vodType"] ("movie" or "episode").
    static let aerioOpenVOD = Notification.Name("aerioOpenVOD")
    /// Posted by HomeView's tvOS Menu-button handler when the user is
    /// already on the Live-TV tab with nothing playing. The channel
    /// list listens for this and scrolls to the first row — same UX
    /// vocabulary as Apple's TV / Music apps where Menu on a long
    /// list means "take me back to the top".
    static let guideScrollToTop = Notification.Name("guideScrollToTop")
    /// Posted by `ChannelStore.primeXMLTVFromURL` after it has
    /// finished the XMLTV parse AND written category-enriched
    /// entries into EPGCache via `GuideStore.seedEPGCache`. Any
    /// open expanded schedule panels listen for this and re-fetch
    /// their `upcomingPrograms` so the newly-landed category data
    /// drives the per-program tint gradient — without this, a
    /// schedule panel that was expanded BEFORE the XMLTV parse
    /// completed would stay visually uncolored until the user
    /// collapsed and re-opened it.
    static let epgCategoriesDidUpdate = Notification.Name("epgCategoriesDidUpdate")
    /// Posted when the tvOS single-stream player is minimized to the
    /// corner. The guide (ChannelListView / EPGGuideView) listens
    /// and programmatically moves its own `@FocusState` to the
    /// first channel row, because the tvOS focus engine does NOT
    /// release focus from a SwiftUI Button that becomes
    /// `.focusable(false)` on an ancestor's state change — the
    /// focus stays trapped in the corner unless something else
    /// explicitly claims it. This notification is that explicit
    /// claim. Body has no userInfo.
    static let forceGuideFocus = Notification.Name("forceGuideFocus")

    /// v1.6.12 (GH #11): a Back/Menu press caught by `MainTabView`'s
    /// outer `.onExitCommand` while a single-stream player is active
    /// AND not minimized — i.e. the player is full-screen but focus
    /// is somewhere outside its view hierarchy (typically the guide,
    /// which still holds focus after Play/Pause re-expanded the mini
    /// player). Posted by `handleMenuPress` and consumed by
    /// `PlayerView`'s `.onReceive`, where it runs the same chrome-
    /// cycle logic as the player's own `.onExitCommand` would have
    /// run if it had received the press directly.
    ///
    /// Without this hand-off the outer handler would call
    /// `nowPlaying.minimize()` immediately and the user would skip
    /// the chrome-reveal step, dropping straight to the mini player
    /// on the first Back press after un-minimizing — exactly the
    /// regression GH #11 reported. Body has no userInfo.
    static let playerBackPress = Notification.Name("playerBackPress")
}
