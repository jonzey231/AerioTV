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
///    dispatch queue, `MainActor.assumeIsolated` may execute on a thread that
///    fails KVS's internal `dispatch_assert_queue(main_queue)`.
///  - Therefore all KVS `set` / `removeObject` calls are wrapped in
///    `DispatchQueue.main.async { }` so they run in a clean GCD context.
///  - KVS reads in `remoteDidChange` happen on the notification's delivery
///    thread (KVS's own internal queue).
///  - The initial sync flow (ping → delayed read) runs on the main queue.
///  - Never call `synchronize()`, it deadlocks on real devices.

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    // MARK: - KVS Keys
    private let kvsKey     = "syncedServers"
    private let prefKVSKey = "syncedPreferences"
    private let watchProgressKVSKey = "syncedWatchProgress"
    private let reminderKVSKey = "syncedReminders"

    /// Background queue used ONLY for the initial sync flow (ping → sleep → read).
    // initQueue removed, all KVS access must be on main dispatch queue.

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

    // MARK: - Preference last-writer-wins (2026-10-12)
    /// A local synced write that has not been pushed yet. While set, no
    /// cloud preferences blob is applied (a pull used to overwrite a fresh
    /// Text Size step or remote map edit with the older cloud copy because
    /// the local push waits up to 60 s).
    private var prefsDirtySince: Date?
    /// Blob key carrying the writer's modification time.
    private static let prefsModifiedAtKey = "_prefsModifiedAt"
    /// Modification time of the last blob this device pushed or applied.
    private static let prefsLocalModifiedAtDefaultsKey = "syncPrefsLocalModifiedAt"
    /// Snapshot of the last pushed blob, to tell a real synced change from
    /// a non-synced UserDefaults write inside the post-stamp quiet window.
    private var lastPushedPrefs: NSDictionary?
    /// Fingerprint of the blob last pushed or applied, so "unchanged" still
    /// reads unchanged after a relaunch (PrefsSyncClock.fingerprint).
    private static let prefsBaselineFingerprintKey = "syncPrefsBaselineFingerprint"

    // MARK: - Read before push (2026-11-10)
    /// Logan: stale data never beats newer data. No lane pushes until a
    /// read-and-merge of iCloud ran since launch (or since the last profile
    /// switch); a push asked for earlier starts one and runs after it.
    private var mergedBeforePushes = false
    private enum PushLane: Hashable { case serversAndProgress, preferences, reminders }
    private var deferredPushLanes: Set<PushLane> = []
    private var deferredPrefsImmediate = false
    private var mergeBeforePushRunning = false
    private var profileObserver: NSObjectProtocol?

    // MARK: - Per item records and deletion times (2026-11-10)
    /// This device's change and removal times per item (SyncStamps). The
    /// favorites, watch progress, and reminders records are shared with the
    /// iCloud snapshots (CloudSnapshotSync).
    static let progressStamps = SyncStamps("watchProgress")
    static let reminderStamps = SyncStamps("reminders")
    static let serverStamps = SyncStamps("playlists")
    static let favoriteStamps = SyncStamps("favorites")
    /// Deletion times ride side keys older builds ignore (their lists only
    /// ever carry live rows).
    static let progressRemovedKVSKey = "syncedWatchProgress.removed.v1"
    static let remindersRemovedKVSKey = "syncedReminders.removed.v1"
    static let serversRemovedKVSKey = "syncedServers.removed.v1"
    /// Favorites' change and removal times inside the preferences payload.
    static let favoritesSyncKey = "favorites.sync.v1"
    private static let favoriteKeys: Set<String> = ["favoriteChannelIDs", "favoriteOrder"]
    private static let favoritesKnownOrderKey = "syncFavoritesKnownOrder.v1"
    private static let favoriteOrderStamp = "__order"
    private static let serverFingerprintsKey = "syncServerFingerprints.v1"
    /// Per-key preferences (PrefsLaneMerge): the values this device last saw
    /// and when each last changed here.
    private static let prefsSeenKey = "syncPrefsSeenValues.v1"
    private static let prefsKeyTimesKey = "syncPrefsKeyTimes.v1"
    private static var prefsLanes: [String: String] { [SyncScope.tvLaneKey: "tv", SyncScope.mobileLaneKey: "mobile"] }
    /// Keys merged their own way (per favorite, per row) or carrying the merge itself.
    private static var prefsSkipKeys: Set<String> {
        [prefsModifiedAtKey, PrefsLaneMerge.timesKey, favoritesSyncKey, "favoriteChannelIDs", "favoriteOrder",
         HiddenVODStore.syncKey, watchlistSyncKey]
    }

    // MARK: - First download (2026-11-10)
    /// A fresh device never writes to iCloud before iCloud's copy has
    /// reached it (FirstDownloadGate). Remembered once confirmed.
    private static let firstDownloadKey = "syncFirstDownloadDone.v1"
    private var firstDownloadWaitStarted = false
    /// The empty-iCloud probe (FirstDownloadGate.probeSurvived): a key only
    /// this install writes, never data.
    private static let launchID = UUID().uuidString
    private static var probeKVSKey: String {
        let ud = UserDefaults.standard
        if let id = ud.string(forKey: "syncProbeInstallID") { return "syncProbe.\(id)" }
        let id = UUID().uuidString
        ud.set(id, forKey: "syncProbeInstallID")
        return "syncProbe.\(id)"
    }

    /// True while waiting for the initial import after the user first enables sync.
    @Published private(set) var isImporting = false

    // MARK: - Sync Activity (UI progress)

    /// What the sync layer is doing right now, for the quiet progress
    /// indicator in Settings > Sync (Logan 2026-09-15: a manual Push or
    /// Pull gave no feedback at all on tvOS or iOS). Only MANUAL /
    /// immediate operations are tracked - the 2 s and 60 s debounced
    /// background pushes are deliberately invisible, otherwise the
    /// indicator would sit spinning for a minute after an unrelated
    /// preference change.
    enum SyncActivity: Equatable { case idle, pushing, pulling }

    @Published private(set) var activity: SyncActivity = .idle

    /// Reason the last tracked operation failed, or nil. Cleared when a
    /// new operation starts. Surfaced inline by the Sync rows, never as
    /// a blocking alert.
    @Published private(set) var lastSyncFailure: String?

    /// In-flight tracked operations. A manual Push fans out into four
    /// separate KVS lanes (servers, preferences, watch progress,
    /// reminders); the indicator clears only when the last one lands.
    private var activeOperationCount = 0

    /// When the current tracked run started, and how long the spinner is
    /// held visible at minimum. A KVS write can land in a few
    /// milliseconds, and Logan's device feedback (2026-09-15) was that the
    /// indicator "flashes so briefly it reads as a glitch", so a run that
    /// finishes sooner keeps the spinner up until this much has elapsed.
    private var activityStart: Date?
    private static let minimumActivityDuration: TimeInterval = 0.9

    /// `@Published` writes re-render observers even when the value is
    /// unchanged, so every assignment below is guarded.
    private func beginActivity(_ kind: SyncActivity) {
        activeOperationCount += 1
        if activityStart == nil { activityStart = Date() }
        if lastSyncFailure != nil { lastSyncFailure = nil }
        if activity != kind { activity = kind }
    }

    private func endActivity(failure: String? = nil) {
        activeOperationCount = max(0, activeOperationCount - 1)
        if let failure, lastSyncFailure != failure { lastSyncFailure = failure }
        guard activeOperationCount == 0, activity != .idle else { return }

        let elapsed = activityStart.map { Date().timeIntervalSince($0) } ?? Self.minimumActivityDuration
        let remaining = Self.minimumActivityDuration - elapsed
        guard remaining > 0 else {
            activityStart = nil
            activity = .idle
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self else { return }
            // A new operation may have started during the hold; that run
            // owns the indicator now.
            guard self.activeOperationCount == 0, self.activity != .idle else { return }
            self.activityStart = nil
            self.activity = .idle
        }
    }

    /// Shared completion for a tracked KVS push: `synchronize()` is the
    /// only signal the store gives us that the write was accepted.
    private static func pushFailureReason() -> String? {
        NSUbiquitousKeyValueStore.default.synchronize()
            ? nil
            : "iCloud did not accept the update. Check iCloud settings and your network, then try again."
    }

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

    /// Every synced setting rides one type-agnostic lane: the value is
    /// copied as the property-list object UserDefaults holds (String,
    /// NSNumber, Data, or [String]), so a new setting needs only a
    /// SyncItemCatalog entry. Older clients read the same keys with typed
    /// casts, which NSNumber and String bridge for. Hidden groups (JSON
    /// Data locally, [String] on the wire) and the remote map (own
    /// category) keep their dedicated handling below.
    private var syncPlistKeys: [String] {
        SyncItemCatalog.allKeys.filter {
            !syncHiddenGroupKeys.contains($0) && $0 != RemoteControlStore.mapKey
        }
    }
    /// Device-local by owner decision (2026-10-27): buffer, network,
    /// background refresh, and the AVPlayer developer flag. No longer
    /// pushed. For one version a pull still adopts the cloud value when
    /// this device has none, so a fresh install restoring from an older
    /// snapshot keeps the user's choice.
    private let legacyReadOnlyKeys = [
        "streamBufferSize", "appBehaviorsStreamBufferSeconds", "networkTimeout", "maxRetries",
        "bgRefreshEnabled", "bgRefreshType", "bgRefreshIntervalMins", "bgRefreshHour",
        "bgRefreshMinute", "preferAVPlayer"
    ]
    /// Payload keys for the data items without plain UserDefaults keys.
    private static let recentsSyncKey = "recentChannels.sync.v1"
    private static let watchlistSyncKey = "watchlist.sync.v1"
    private let syncHiddenGroupKeys = [
        "hiddenChannelGroups", "hiddenMovieGroups", "hiddenSeriesGroups"
    ]

    // MARK: - Start / Stop Observing

    func startObserving() {
        guard isSyncEnabled else {
            debugLog("🔵 SyncManager.startObserving: sync disabled, skipping")
            return
        }
        // Pushes waiting on iCloud's first download look again on every foreground.
        if isSyncEnabled, !isImporting, firstDownloadDone {
            if UserDefaults.standard.bool(forKey: Self.initialPushPendingKey) {
                UserDefaults.standard.removeObject(forKey: Self.initialPushPendingKey)
                debugLog("[SYNC] iCloud's copy confirmed; sending the first push that waited")
                scheduleInitialPush()
            } else if !deferredPushLanes.isEmpty {
                startMergeBeforePush()
            }
        }
        // A setting's change time is stamped when it changes, not at the next push.
        startObservingDefaults()
        // Skip if already observing, avoids remove-then-re-add churn on every foreground.
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
            CloudAccount.noteExternalChange(reason: reason)
            MainActor.assumeIsolated {
                SyncManager.shared.handleRemoteChange(reason: reason)
            }
        }

        // iCloud account or iCloud Drive state changed: re-read availability.
        if !CloudAccount.identityObserved {
        CloudAccount.identityObserved = true
        NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { _ in
            debugLog("[SYNC] iCloud identity changed; available=\(CloudAccount.isAvailable)")
            NotificationCenter.default.post(name: .syncManagerDidApplyPreferences, object: nil)
        }
        }

        // A profile switch swaps this device's data: the next push waits for
        // a fresh read-and-merge.
        if profileObserver == nil {
            profileObserver = NotificationCenter.default.addObserver(
                forName: .aerioProfileDidSwitch, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    let mgr = SyncManager.shared
                    mgr.mergedBeforePushes = false
                    debugLog("[SYNC] profile switched; the next push waits for a read-and-merge")
                }
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

        // Block-based observer on .main queue, same fix as KVS observer.
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
        if let obs = profileObserver {
            NotificationCenter.default.removeObserver(obs)
            profileObserver = nil
        }
        isObservingDefaults = false
    }

    /// True once a read-and-merge ran; otherwise remembers `lane`, starts
    /// one (unless the enable import is already reading), and returns false.
    private func mergedBeforePush(_ lane: PushLane, immediate: Bool = false) -> Bool {
        let downloaded = firstDownloadDone
        if mergedBeforePushes, downloaded { return true }
        deferredPushLanes.insert(lane)
        if lane == .preferences, immediate { deferredPrefsImmediate = true }
        guard downloaded else {
            waitForFirstDownload()
            return false
        }
        debugLog("[SYNC] \(lane) push waits for a read-and-merge of iCloud first")
        if !isImporting { startMergeBeforePush() }
        return false
    }

    /// The same read and merges as a pull, without the Settings indicator.
    private func startMergeBeforePush() {
        guard !mergeBeforePushRunning else { return }
        mergeBeforePushRunning = true
        let sKey = kvsKey, pKey = prefKVSKey, wpKey = watchProgressKVSKey, rKey = reminderKVSKey
        Task { @MainActor in
            let mgr = SyncManager.shared
            defer { mgr.mergeBeforePushRunning = false }
            guard mgr.isSyncEnabled else { return }
            let store = NSUbiquitousKeyValueStore.default
            let servers   = store.array(forKey: sKey) as? [[String: Any]]
            let prefs     = store.dictionary(forKey: pKey)
            let wp        = store.array(forKey: wpKey) as? [[String: Any]]
            let reminders = store.array(forKey: rKey) as? [[String: Any]]
            mgr.doMerge(servers: servers, isInitial: false)
            await Task.yield()
            CloudSnapshotSync.shared.foldProviders()
            mgr.doApplyPreferences(prefs: prefs)
            await Task.yield()
            mgr.mergeRemoteWatchProgress(wp)
            await Task.yield()
            mgr.mergeRemoteReminders(reminders)
            mgr.noteMerged("before the first push")
        }
    }

    /// A read-and-merge of iCloud finished: pushes may go, and the ones
    /// that waited go now.
    private func noteMerged(_ how: String) {
        if !mergedBeforePushes { debugLog("[SYNC] read-and-merge done (\(how)); pushes open") }
        mergedBeforePushes = true
        // Still waiting for iCloud's copy: the deferred pushes keep waiting.
        guard firstDownloadDone else { return }
        CloudSnapshotSync.shared.releaseDownloadHold()
        if UserDefaults.standard.bool(forKey: Self.initialPushPendingKey) {
            UserDefaults.standard.removeObject(forKey: Self.initialPushPendingKey)
            scheduleInitialPush()
        }
        let lanes = deferredPushLanes
        let prefsImmediate = deferredPrefsImmediate
        deferredPushLanes = []
        deferredPrefsImmediate = false
        if lanes.contains(.serversAndProgress) {
            NotificationCenter.default.post(name: .syncManagerNeedsPush, object: nil, userInfo: ["immediate": false])
        }
        if lanes.contains(.preferences) { doPushPreferences(immediate: prefsImmediate, localChange: false) }
        if lanes.contains(.reminders) { pushReminders() }
    }

    /// What this device last saw live in iCloud for a list (key to change
    /// time), so an older build's absence can count as a deletion. Nil until
    /// a pull recorded it: then nothing is deleted for being absent.
    static func loadSeen(_ lane: String) -> [String: TimeInterval]? {
        UserDefaults.standard.dictionary(forKey: "syncSeen.\(lane).v1") as? [String: TimeInterval]
    }

    static func saveSeen(_ lane: String, _ seen: [String: TimeInterval]?) {
        if let seen { UserDefaults.standard.set(seen, forKey: "syncSeen.\(lane).v1") }
        else { UserDefaults.standard.removeObject(forKey: "syncSeen.\(lane).v1") }
    }

    private static let seenLanes = ["watchProgress", "reminders", "playlists", "favorites"]

    /// iCloud no longer holds what this device saw there (cleared, turned
    /// off, another account).
    private static func forgetSeen(_ lanes: [String] = seenLanes) {
        for lane in lanes { saveSeen(lane, nil) }
    }

    /// Whether iCloud's copy has reached this device (or it synced before).
    /// Once true it stays true until the iCloud account changes.
    var firstDownloadDone: Bool {
        let ud = UserDefaults.standard
        if ud.bool(forKey: Self.firstDownloadKey) { return true }
        let kvs = NSUbiquitousKeyValueStore.default
        let dataKeys = [kvsKey, prefKVSKey, watchProgressKVSKey, reminderKVSKey,
                        Self.progressRemovedKVSKey, Self.remindersRemovedKVSKey, Self.serversRemovedKVSKey]
            + CloudCanon.SHARED_FILES.map { CloudSnapshotSync.kvsKey($0) }
        let state = FirstDownloadGate.state(
            alreadyDone: false,
            deliveredFromCloud: ud.bool(forKey: CloudAccount.seenKey),
            cloudHasData: dataKeys.contains { kvs.object(forKey: $0) != nil },
            syncedBefore: ud.double(forKey: "syncLastDate") > 0,
            probeSurvived: FirstDownloadGate.probeSurvived(
                written: ud.string(forKey: "syncProbeValue"), writtenInLaunch: ud.string(forKey: "syncProbeLaunch"),
                currentLaunch: Self.launchID, readBack: kvs.string(forKey: Self.probeKVSKey)))
        guard state == .done else { return false }
        ud.set(true, forKey: Self.firstDownloadKey)
        debugLog("[SYNC] iCloud's copy has reached this device; pushes may write")
        return true
    }

    /// Pushes wait for the first download. The timeout only logs and looks
    /// again: it never forces a push over a copy that has not arrived.
    private func waitForFirstDownload() {
        guard !firstDownloadWaitStarted else { return }
        firstDownloadWaitStarted = true
        debugLog("[SYNC] pushes wait: iCloud's copy has not reached this device yet")
        // The empty-iCloud probe: written once, checked after a relaunch.
        let ud = UserDefaults.standard
        if ud.string(forKey: "syncProbeValue") == nil {
            let value = "\(Self.launchID)@\(Int(Date().timeIntervalSince1970))"
            ud.set(value, forKey: "syncProbeValue")
            ud.set(Self.launchID, forKey: "syncProbeLaunch")
            let key = Self.probeKVSKey
            DispatchQueue.main.async { NSUbiquitousKeyValueStore.default.set(value, forKey: key) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + FirstDownloadGate.timeout) {
            MainActor.assumeIsolated {
                let mgr = SyncManager.shared
                mgr.firstDownloadWaitStarted = false
                guard !mgr.deferredPushLanes.isEmpty else { return }
                if mgr.firstDownloadDone {
                    mgr.startMergeBeforePush()
                } else {
                    debugLog("[SYNC] iCloud's copy still not here after \(Int(FirstDownloadGate.timeout)) s; pushes keep waiting (never forced)")
                    mgr.waitForFirstDownload()
                }
            }
        }
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
                debugLog("🔵 SyncManager: initial KVS check, servers=\(servers != nil), prefs=\(prefs != nil), watchProgress=\(wp != nil), reminders=\(reminders != nil)")

                Task { @MainActor [weak self] in
                    self?.handleImportResult(servers: servers, prefs: prefs, watchProgress: wp, reminders: reminders)
                }
            }

            // Timeout: if nothing arrives in 12s, stop waiting.
            importTimeoutWork?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.isSyncEnabled, self.isImporting else { return }
                    debugLog("🔵 SyncManager: import timeout, pushing local state")
                    self.isImporting = false
                    self.startObservingDefaults()
                    self.noteMerged("import timeout, iCloud had nothing")
                    self.scheduleInitialPush()
                }
            }
            importTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: timeout)
        } else {
            // Turning iCloud Sync off stops syncing on THIS device only (Logan
            // 2026-11-10). It used to erase the iCloud copy for every device;
            // erasing is the separate "Clear iCloud Data" action with its own
            // confirmation. Pending pushes are cancelled so nothing writes after.
            isImporting = false
            importTimeoutWork?.cancel()
            stopObserving()
            mergedBeforePushes = false
            deferredPushLanes = []
            pushDebounce?.cancel(); pushDebounce = nil
            prefPushDebounce?.cancel(); prefPushDebounce = nil
            watchProgressPushDebounce?.cancel(); watchProgressPushDebounce = nil
            reminderPushDebounce?.cancel(); reminderPushDebounce = nil
            debugLog("🔵 SyncManager: iCloud Sync off on this device; the iCloud copy is left as it is")
        }
    }

    /// Wipe all iCloud-side state for this app, payloads in
    /// iCloud KVS plus the synchronizable copies of credentials in
    /// iCloud Keychain. **Local data on this device is preserved**:
    /// SwiftData servers, the local-only Keychain copies of
    /// passwords/API keys, and UserDefaults all stay intact, so
    /// the app keeps working on this device. The intent is "wipe
    /// the cloud and start fresh", useful when a user wants to
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
    /// repopulate the cloud with this device's local state, which
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

        // KVS removal, must run on the literal main dispatch queue.
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
            for k in [SyncManager.progressRemovedKVSKey, SyncManager.remindersRemovedKVSKey, SyncManager.serversRemovedKVSKey] {
                kvs.removeObject(forKey: k)
            }
            kvs.removeObject(forKey: "lastSyncPing")
            kvs.synchronize()
            debugLog("🔵 SyncManager.clearAllICloudData: KVS payloads cleared")
        }
        // iCloud holds nothing now: the next pushes send everything.
        Self.forgetSeen()

        // iCloud Keychain, only the synchronizable copies. Local
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
    /// preserved, only the cloud copy is removed.
    @MainActor
    func clearCloudCategory(_ category: SyncCategory, localServers: [ServerConnection]) {
        debugLog("🔵 SyncManager.clearCloudCategory: starting category=\(category.rawValue)")

        switch category {
        case .servers:
            pushDebounce?.cancel(); pushDebounce = nil
            Self.forgetSeen(["playlists"])
            let key = kvsKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: SyncManager.serversRemovedKVSKey)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared servers KVS")
            }
        case .watchProgress:
            watchProgressPushDebounce?.cancel(); watchProgressPushDebounce = nil
            Self.forgetSeen(["watchProgress"])
            let key = watchProgressKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: SyncManager.progressRemovedKVSKey)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared watch progress KVS")
            }
        case .reminders:
            reminderPushDebounce?.cancel(); reminderPushDebounce = nil
            Self.forgetSeen(["reminders"])
            let key = reminderKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.removeObject(forKey: SyncManager.remindersRemovedKVSKey)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared reminders KVS")
            }
        case .preferences:
            prefPushDebounce?.cancel(); prefPushDebounce = nil
            Self.forgetSeen(["favorites"])
            let key = prefKVSKey
            DispatchQueue.main.async {
                NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
                NSUbiquitousKeyValueStore.default.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared preferences KVS")
            }
        case .remoteControl:
            // The map lives INSIDE the preferences dictionary rather than
            // under a KVS key of its own, so "delete from iCloud" here means
            // rewriting that dictionary without the map entry. Removing
            // prefKVSKey wholesale would take every other preference with it.
            prefPushDebounce?.cancel(); prefPushDebounce = nil
            let prefsKey = prefKVSKey
            let mapKey = RemoteControlStore.mapKey
            DispatchQueue.main.async {
                let store = NSUbiquitousKeyValueStore.default
                if var dict = store.dictionary(forKey: prefsKey) {
                    dict.removeValue(forKey: mapKey)
                    store.set(dict, forKey: prefsKey)
                }
                store.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared remote map from preferences KVS")
            }
        case .radioModeDefault:
            // Like the remote map: the key lives inside the preferences
            // dictionary, so rewrite it without the entry.
            prefPushDebounce?.cancel(); prefPushDebounce = nil
            let prefsKey = prefKVSKey
            let radioKey = RadioModeSession.byDefaultKey
            DispatchQueue.main.async {
                let store = NSUbiquitousKeyValueStore.default
                if var dict = store.dictionary(forKey: prefsKey) {
                    dict.removeValue(forKey: radioKey)
                    store.set(dict, forKey: prefsKey)
                }
                store.synchronize()
                debugLog("🔵 SyncManager.clearCloudCategory: cleared Radio Mode by Default from preferences KVS")
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
            // SECURITY: serialize(...) also writes cleartext `_password`/`_apiKey`
            // into the "syncedServers" KVS blob as a transport fallback (~922),
            // so deleting only the Keychain left those credentials sitting in
            // iCloud. Re-push the server blob with credentials explicitly
            // stripped (the Keychain is already gone above, so a re-serialize
            // omits them anyway, this is belt-and-suspenders). Cancel any
            // pending server push first so it can't re-write creds afterward.
            pushDebounce?.cancel(); pushDebounce = nil
            nonisolated(unsafe) let capturedServers = localServers.map { $0 }
            let serversKey = kvsKey
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let stripped = capturedServers.map { srv -> [String: Any] in
                        var d = self.serialize(srv)
                        d.removeValue(forKey: "_password")
                        d.removeValue(forKey: "_apiKey")
                        return d
                    }
                    NSUbiquitousKeyValueStore.default.set(stripped, forKey: serversKey)
                    NSUbiquitousKeyValueStore.default.synchronize()
                    debugLog("🔵 SyncManager.clearCloudCategory: re-pushed \(stripped.count) servers to KVS without credentials")
                }
            }
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
            noteMerged("enable import")
        } else {
            importTimeoutWork?.cancel()
            isImporting = false
            startObservingDefaults()
            debugLog("🔵 SyncManager: no remote data, will push local state")
            noteMerged("enable import, iCloud had nothing")
            // Schedule push for next run-loop iteration so KVS writes
            // happen in a clean GCD context (via DispatchQueue.main.async).
            scheduleInitialPush()
        }
    }

    /// Schedules the first push (servers + preferences) on the next main-queue
    /// iteration, ensuring KVS writes are on the literal main dispatch queue.
    private static let initialPushPendingKey = "syncInitialPushPending.v1"

    private func scheduleInitialPush() {
        // Remembered across launches until iCloud's copy has reached this device.
        if !firstDownloadDone { UserDefaults.standard.set(true, forKey: Self.initialPushPendingKey) }
        Task { @MainActor [weak self] in
            guard let self, self.isSyncEnabled else { return }
            debugLog("🔵 SyncManager: initial push, posting syncManagerNeedsPush")
            NotificationCenter.default.post(
                name: .syncManagerNeedsPush,
                object: nil,
                userInfo: ["immediate": true]
            )
            // Seeding: no local change, so the blob keeps its own stamp.
            self.doPushPreferences(immediate: true, localChange: false)
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
        // v1.6.17, granular per-category gate.
        guard SyncCategory.servers.isEnabled else {
            debugLog("🔵 SyncManager.pushServers: category disabled by user")
            return
        }
        // A playlist deleted here since the last look gets its deletion time
        // now, before any wait.
        Self.serverStamps.observe(live: Set(servers.filter { !$0.isGone }.map { $0.id.uuidString }),
                                  now: Date().timeIntervalSince1970)
        guard mergedBeforePush(.serversAndProgress) else { return }

        // Snapshot server data on the calling thread (SwiftData requires main-actor access)
        // but keep it lightweight, defer Keychain reads to the async block.
        debugLog("🔵 SyncManager.pushServers: capturing \(servers.count) servers")
        nonisolated(unsafe) let capturedServers = servers.map { $0 }
        let key = kvsKey

        // v1.7.x bounce-back-guard fix: stamp `lastPushTime` AT SCHEDULE TIME,
        // not just when the debounced work fires. The 2-second debounce on
        // non-immediate pushes opened a window where `processRemoteChange`'s
        // `(now - lastPushTime) < 5.0` guard saw a stale timestamp from the
        // previous successful push (potentially minutes/hours ago) and
        // wrongly let a foreign KVS notification through. The follow-on
        // `mergeRemoteServers` then ran against KVS that didn't yet contain
        // the just-added local server and the "delete local servers not in
        // remote" branch tore the new SwiftData row + its Keychain entries
        // out before `saveCredentialsSynced` could persist them. Stamping
        // here closes the window: any didChangeExternally notification
        // arriving during the debounce sees a fresh timestamp and the
        // guard correctly suppresses the spurious merge. The work block
        // re-stamps after the actual KVS write so a notification that
        // arrives AFTER the push has the same protection. Idempotent.
        lastPushTime = ProcessInfo.processInfo.systemUptime

        pushDebounce?.cancel()
        let work = DispatchWorkItem {
            // DispatchWorkItem runs on DispatchQueue.main but is NOT a @MainActor
            // context.  Use assumeIsolated so we can access @MainActor properties
            // (serialize, lastPushTime) without a dispatch_assert_queue crash.
            MainActor.assumeIsolated {
                let mgr = SyncManager.shared
                // Debounced: a playlist deleted during the 2 s window is
                // skipped, never read (2026-10-14 delete crash audit).
                let payload = capturedServers.filter { !$0.isGone }.map { mgr.serialize($0) }
                mgr.lastPushTime = ProcessInfo.processInfo.systemUptime
                // Re-read and merge per playlist (newest change or deletion
                // wins, a tie keeps iCloud's): a playlist another device added
                // in between is never dropped, and the "deleted on another
                // device" path elsewhere never fires for it.
                let store = NSUbiquitousKeyValueStore.default
                let now = Date().timeIntervalSince1970
                func byID(_ list: [[String: Any]]) -> [String: [String: Any]] {
                    WatchProgressSyncMerge.byKey(list, key: { $0["id"] as? String }, stamp: SyncManager.serverRowStamp)
                }
                let remoteRemoved = store.dictionary(forKey: SyncManager.serversRemovedKVSKey) as? [String: TimeInterval] ?? [:]
                let stamps = SyncManager.serverStamps
                stamps.prune(now: now)
                let r = LaneMerge.forPush(local: byID(payload), localRemoved: stamps.removed,
                                          remote: byID(store.array(forKey: key) as? [[String: Any]] ?? []),
                                          remoteRemoved: remoteRemoved, base: SyncManager.loadSeen("playlists"),
                                          stamp: SyncManager.serverRowStamp, now: now)
                store.set(r.rows, forKey: key)
                store.set(r.removed, forKey: SyncManager.serversRemovedKVSKey)
                SyncManager.saveSeen("playlists", r.base)
                debugLog("🔵 SyncManager: pushed \(r.rows.count) servers (local=\(payload.count) keptFromCloud=\(r.keptFromCloud) deletions=\(r.removed.count))")
                mgr.stampSyncDate()
            }
        }
        pushDebounce = work

        // Manual (immediate) pushes drive the Settings > Sync progress
        // indicator. `notify` fires whether the item runs or is cancelled
        // by a newer push, so the counter can never leak.
        if immediate {
            beginActivity(.pushing)
            work.notify(queue: .main) {
                MainActor.assumeIsolated {
                    SyncManager.shared.endActivity(failure: SyncManager.pushFailureReason())
                }
            }
        }

        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
        debugLog("🔵 SyncManager.pushServers: scheduled (immediate=\(immediate))")
    }

    // MARK: - Push Preferences (Local → iCloud)

    /// A synced setting just changed here (callers are user actions).
    func pushPreferences() {
        doPushPreferences(immediate: false, localChange: true)
    }

    func pushPreferencesImmediate() {
        doPushPreferences(immediate: true, localChange: true)
    }

    /// Going to the background: send an unpushed local change now. With
    /// none pending nothing is written, so a device that only opened the
    /// app never re-stamps its (possibly stale) data as newest.
    func flushPendingPreferences() {
        guard prefsDirtySince != nil else { return }
        doPushPreferences(immediate: true, localChange: false)
    }

    /// Whether the blob differs from what this device last pushed or
    /// applied; nil when it has no record of either.
    private func prefsChanged(_ built: [String: Any]) -> Bool? {
        if let last = lastPushedPrefs, (built as NSDictionary).isEqual(last) { return false }
        guard let saved = UserDefaults.standard.string(forKey: Self.prefsBaselineFingerprintKey) else {
            return lastPushedPrefs == nil ? nil : true
        }
        let same = PrefsSyncClock.fingerprint(built) == saved
        if same { lastPushedPrefs = built as NSDictionary }
        return !same
    }

    /// The blob this device just pushed or applied is the new baseline.
    private func recordPrefsBaseline(_ plain: [String: Any]) {
        lastPushedPrefs = plain as NSDictionary
        UserDefaults.standard.set(PrefsSyncClock.fingerprint(plain), forKey: Self.prefsBaselineFingerprintKey)
    }

    /// `localChange`: a synced value changed here just now (a user action).
    /// Only that sets the change time; every other push carries the stamp
    /// the data already had (PrefsSyncClock), and the write re-reads iCloud
    /// first so a newer blob there is applied, never overwritten.
    private func doPushPreferences(immediate: Bool, localChange: Bool) {
        if ProfileManager.shared.nonDefaultActive() { return }  // iCloud carries the default profile only
        guard isSyncEnabled, !isMerging else {
            debugLog("🔵 SyncManager.pushPrefs: skipped (enabled=\(isSyncEnabled), merging=\(isMerging))")
            return
        }
        let built = buildPreferencesDict()
        let changed = prefsChanged(built)
        // Recorded before the read-before-push gate: a change made before the
        // first merge keeps its time, so that merge cannot overwrite it with
        // older iCloud data.
        if localChange, changed != false { prefsDirtySince = Date() }
        // Each value's change time (a value that changed here since the last look: now).
        let local = localPrefKeys(built, now: Date().timeIntervalSince1970)
        guard mergedBeforePush(.preferences, immediate: immediate) else { return }

        debugLog("🔵 SyncManager.pushPrefs: building snapshot")
        // Rule 5 follow: the iCloud snapshots of the files the preferences payload carries.
        for c in [DsyncCategory.favorites, .watchlist, .preferences] { CloudSnapshotSync.shared.follow(c, "\(c.rawValue) local") }
        nonisolated(unsafe) let snapshot = built
        nonisolated(unsafe) let flat = local.flat
        let times = local.times
        let key = prefKVSKey

        prefPushDebounce?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let mgr = SyncManager.shared
                mgr.lastPushTime = ProcessInfo.processInfo.systemUptime
                // Re-read right before the write and merge per key, per
                // favorite, and per row: nothing iCloud has that is newer is
                // overwritten, and nothing is written when nothing here is newer.
                let cloud = NSUbiquitousKeyValueStore.default.dictionary(forKey: key)
                let r = mgr.mergeWithCloudPreferences(snapshot, flat: flat, times: times, cloud: cloud)
                mgr.prefsDirtySince = nil
                if r.write {
                    NSUbiquitousKeyValueStore.default.set(r.blob, forKey: key)
                    let stamp = r.blob[SyncManager.prefsModifiedAtKey] as? TimeInterval ?? 0
                    debugLog("🔵 SyncManager: pushed preferences (newest change=\(Int(stamp)) newer keys here=\(r.localNewer))")
                    UserDefaults.standard.set(stamp, forKey: SyncManager.prefsLocalModifiedAtDefaultsKey)
                    mgr.stampSyncDate()
                } else {
                    debugLog("[SYNC] prefs not pushed: nothing here is newer than iCloud's copy")
                }
                mgr.recordPrefsBaseline(snapshot)
                // iCloud had keys newer than this device's: bring them here now.
                if r.remoteNewer { mgr.doApplyPreferences(prefs: r.blob) }
            }
        }
        prefPushDebounce = work

        // Manual (immediate) pushes drive the Settings > Sync progress
        // indicator. `notify` fires whether the item runs or is cancelled
        // by a newer push, so the counter can never leak.
        if immediate {
            beginActivity(.pushing)
            work.notify(queue: .main) {
                MainActor.assumeIsolated {
                    SyncManager.shared.endActivity(failure: SyncManager.pushFailureReason())
                }
            }
        }

        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60.0, execute: work)
        }
        debugLog("🔵 SyncManager.pushPrefs: scheduled (immediate=\(immediate))")
    }

    /// This device's blob merged onto iCloud's (re-read right before the
    /// write): per key by change time (PrefsLaneMerge, a tie keeps iCloud's),
    /// per favorite, and per row for My List and hidden titles (iCloud's rows
    /// come here first, then the union goes up). Keys this device does not
    /// write (items scoped Off, the other device class's lane) stay as iCloud
    /// has them. `write` is false when nothing here is newer.
    private func mergeWithCloudPreferences(_ local: [String: Any], flat: [String: Any], times: [String: TimeInterval],
                                           cloud: [String: Any]?)
        -> (blob: [String: Any], write: Bool, remoteNewer: Bool, localNewer: Int) {
        let lanes = Self.prefsLanes
        let skip = Self.prefsSkipKeys
        guard let cloud else {
            var out = local
            out[PrefsLaneMerge.timesKey] = times
            out[Self.prefsModifiedAtKey] = max(times.values.max() ?? 0, 1)
            return (out, true, false, flat.count)
        }
        let cloudTimes = cloud[PrefsLaneMerge.timesKey] as? [String: TimeInterval] ?? [:]
        let cloudStamp = cloud[Self.prefsModifiedAtKey] as? TimeInterval ?? 0
        let m = PrefsLaneMerge.merge(local: flat, localTimes: times,
                                     remote: PrefsLaneMerge.flatten(cloud, lanes: lanes, skip: skip),
                                     remoteTimes: cloudTimes, remoteStamp: cloudStamp)
        var out = cloud.filter { skip.contains($0.key) }
        for (k, v) in PrefsLaneMerge.unflatten(m.values, lanes: lanes) { out[k] = v }
        out[PrefsLaneMerge.timesKey] = m.times
        // An older build's blob gains its times once.
        var write = !m.localNewer.isEmpty || cloud[PrefsLaneMerge.timesKey] == nil

        // Favorites merge per favorite with iCloud's (never by blob time).
        if Self.favoritesSynced, let mine = FavoritesSyncMerge.state(from: local) {
            let remote = FavoritesSyncMerge.state(from: cloud)
            let base = Self.loadSeen("favorites")
            let f = FavoritesSyncMerge.merge(local: mine, remote: remote, base: base, now: Date().timeIntervalSince1970)
            out["favoriteChannelIDs"] = f.order
            out["favoriteOrder"] = f.order
            out[Self.favoritesSyncKey] = FavoritesSyncMerge.blob(f.state)
            Self.saveSeen("favorites", LaneMerge.baseAfterPush(local: mine.side, remote: remote?.side ?? .init(),
                                                               base: base, plan: f.plan))
            if f.plan.values.contains(.local) || f.state.side.removed != (remote?.side.removed ?? [:])
                || (cloud["favoriteChannelIDs"] as? [String]) != f.order { write = true }
        }
        // My List and hidden titles: iCloud's rows first (newest per row,
        // deletions kept), then the union. Never iCloud's rows dropped.
        func same(_ a: Any?, _ b: Any?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return PrefsLaneMerge.valueID(x) == PrefsLaneMerge.valueID(y)
            default: return false
            }
        }
        if SyncCategory.preferences.isEnabled, SyncItemCatalog.isEnabled(SyncItemCatalog.watchlistID) {
            if let blob = cloud[Self.watchlistSyncKey] as? Data {
                isMerging = true
                WatchlistManager.mergeSyncBlob(blob, replace: false)
                isMerging = false
            }
            if let mine = WatchlistManager.syncBlob() {
                out[Self.watchlistSyncKey] = mine
                if !same(mine, cloud[Self.watchlistSyncKey]) { write = true }
            }
        }
        if SyncCategory.preferences.isEnabled, SyncItemCatalog.isEnabled(SyncItemCatalog.hiddenTitlesID) {
            if let blob = cloud[HiddenVODStore.syncKey] as? Data {
                isMerging = true
                HiddenVODStore.shared.mergeRemote(blob)
                isMerging = false
            }
            if let mine = HiddenVODStore.shared.syncBlob() {
                out[HiddenVODStore.syncKey] = mine
                if !same(mine, cloud[HiddenVODStore.syncKey]) { write = true }
            }
        }
        // The blob's time older builds read: the newest change it carries, never the push time.
        out[Self.prefsModifiedAtKey] = max(cloudStamp, m.times.values.max() ?? 0, 1)
        return (out, write, !m.remoteNewer.isEmpty, m.localNewer.count)
    }

    /// This device's synced values per key ("lane:key") and when each last
    /// changed here. The first look only records (unknown age). A non-default
    /// profile's swapped-in values are never read as changes.
    private func localPrefKeys(_ blob: [String: Any], now: TimeInterval) -> (flat: [String: Any], times: [String: TimeInterval]) {
        let flat = PrefsLaneMerge.flatten(blob, lanes: Self.prefsLanes, skip: Self.prefsSkipKeys)
        let ud = UserDefaults.standard
        let prev = ud.dictionary(forKey: Self.prefsKeyTimesKey) as? [String: TimeInterval] ?? [:]
        if ProfileManager.shared.nonDefaultActive() { return (flat, prev) }
        let seen = ud.dictionary(forKey: Self.prefsSeenKey) as? [String: String]
        let r = PrefsLaneMerge.observe(flat: flat, seen: seen, times: prev, now: now)
        if seen != r.seen { ud.set(r.seen, forKey: Self.prefsSeenKey) }
        if prev != r.times { ud.set(r.times, forKey: Self.prefsKeyTimesKey) }
        return (flat, r.times)
    }

    /// What a pull applied: iCloud's values and their times are this device's now.
    private func settlePrefKeys(_ keys: [String], values: [String: Any], times: [String: TimeInterval], stamp: TimeInterval) {
        guard !keys.isEmpty else { return }
        let ud = UserDefaults.standard
        var seen = ud.dictionary(forKey: Self.prefsSeenKey) as? [String: String] ?? [:]
        var mine = ud.dictionary(forKey: Self.prefsKeyTimesKey) as? [String: TimeInterval] ?? [:]
        for k in keys {
            if let v = values[k] { seen[k] = PrefsLaneMerge.valueID(v) }
            mine[k] = PrefsLaneMerge.remoteTime(times, key: k, blobStamp: stamp)
        }
        ud.set(seen, forKey: Self.prefsSeenKey)
        ud.set(mine, forKey: Self.prefsKeyTimesKey)
    }

    // MARK: - Favorites per favorite (2026-11-10)

    /// Favorites ride the shared map when their item is on (never a lane).
    private static var favoritesSynced: Bool {
        SyncCategory.preferences.isEnabled && SyncItemCatalog.allows("favoriteChannelIDs")
    }

    /// This device's favorites with their times. Looks first: a favorite
    /// added or removed here since the last look gets its time now, and a
    /// reorder stamps the order.
    private func localFavoritesState(now: TimeInterval) -> FavoritesSyncMerge.State {
        let ud = UserDefaults.standard
        let ids = ud.stringArray(forKey: "favoriteChannelIDs") ?? []
        let order = ud.stringArray(forKey: "favoriteOrder") ?? []
        let st = Self.favoriteStamps
        // A non-default profile's favorites are swapped in: never read them
        // as changes to the default profile's (iCloud carries the default only).
        if !ProfileManager.shared.nonDefaultActive() {
            st.observe(live: Set(ids), now: now)
            let known = ud.stringArray(forKey: Self.favoritesKnownOrderKey)
            if let known, FavoritesSyncMerge.reordered(known, order) { st.touch(Self.favoriteOrderStamp, at: now) }
            if known != order { ud.set(order, forKey: Self.favoritesKnownOrderKey) }
        }
        var live: [String: TimeInterval] = [:]
        for id in ids { live[id] = st.touched[id] ?? 0 }
        return .init(side: .init(live: live, removed: st.removed), order: order,
                     orderAt: st.touched[Self.favoriteOrderStamp] ?? 0)
    }

    /// Pull: merge iCloud's favorites into this device's per favorite.
    /// Returns true when this device holds something iCloud lacks (push it).
    private func applyFavorites(from cloud: [String: Any]) -> Bool {
        guard let remote = FavoritesSyncMerge.state(from: cloud) else { return false }
        let now = Date().timeIntervalSince1970
        let mine = localFavoritesState(now: now)
        let m = FavoritesSyncMerge.merge(local: mine, remote: remote, base: Self.loadSeen("favorites"), now: now)
        let ud = UserDefaults.standard
        let curIDs = ud.stringArray(forKey: "favoriteChannelIDs") ?? []
        let curOrder = ud.stringArray(forKey: "favoriteOrder") ?? []
        if Set(curIDs) != Set(m.order) || curOrder != m.order {
            isMerging = true
            defer { isMerging = false }
            ud.set(m.order, forKey: "favoriteChannelIDs")
            ud.set(m.order, forKey: "favoriteOrder")
            FavoritesStore.shared.applySynced(order: m.order, items: ChannelStore.shared.channels)
            debugLog("[SYNC] favorites merged per favorite: \(m.order.count) (was \(curIDs.count))")
        }
        var removedApplied: [String: TimeInterval] = [:]
        var touched: [String: TimeInterval] = [:]
        for (k, p) in m.plan {
            switch p {
            case .removed(let t): removedApplied[k] = t
            case .remote: if let t = remote.side.live[k], t > 0 { touched[k] = t }
            default: break
            }
        }
        Self.favoriteStamps.settle(live: Set(m.order), removed: removedApplied, touched: touched)
        if remote.orderAt > mine.orderAt { Self.favoriteStamps.touch(Self.favoriteOrderStamp, at: remote.orderAt) }
        ud.set(m.order, forKey: Self.favoritesKnownOrderKey)
        Self.saveSeen("favorites", remote.side.live)
        // Something here is newer than iCloud's copy (or iCloud lacks it).
        return m.plan.values.contains(.local) || Set(remote.side.live.keys) != Set(m.order)
            || m.state.side.removed != remote.side.removed
    }

    /// Property-list types KVS accepts.
    private static func isPlistValue(_ v: Any) -> Bool {
        v is String || v is NSNumber || v is Data || v is Date || v is [Any] || v is [String: Any]
    }

    /// `includeBlobs`: false for the settings-only look the defaults observer
    /// runs (no My List fetch, hidden titles, or favorites; those carry their own times).
    private func buildPreferencesDict(includeBlobs: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [:]
        let ud = UserDefaults.standard

        // v1.6.17, the per-category sync toggles ALWAYS round-trip through
        // the prefs lane so a fresh device picks them up on its first import,
        // and so a flip on iPhone reaches iPad even if "App Preferences" sync
        // is otherwise off. The remaining prefs are gated by the user's
        // "App Preferences" category toggle below.
        for k in SyncCategory.allDefaultsKeys {
            if ud.object(forKey: k) != nil { dict[k] = ud.bool(forKey: k) }
        }

        // Remote button map rides its own category, so it is handled BEFORE
        // the preferences gate: the two toggles are independent, and someone
        // who turns off App Preferences but leaves Remote Button Map on should
        // still get their map. The syncDataKeys loop below skips it.
        if SyncCategory.remoteControl.isEnabled,
           let v = ud.data(forKey: RemoteControlStore.mapKey) {
            dict[RemoteControlStore.mapKey] = v
        }
        // "Radio Mode by Default" rides its own category, default OFF, so
        // the key never leaves this device unless the user opts in. It is
        // in none of the sync*Keys sets.
        if SyncCategory.radioModeDefault.isEnabled,
           ud.object(forKey: RadioModeSession.byDefaultKey) != nil {
            dict[RadioModeSession.byDefaultKey] = ud.bool(forKey: RadioModeSession.byDefaultKey)
        }

        // Granular gate: when "App Preferences" sync is off, push only the
        // toggle subset above and bail. The other devices' caches stay
        // whatever the user set them to locally.
        guard SyncCategory.preferences.isEnabled else {
            return dict
        }

        // All devices rides the shared map; TVs only / Phones and tablets
        // only ride this form factor's lane. Off writes nothing.
        var lane: [String: Any] = [:]
        let deviceLane = SyncScope.deviceLane
        for k in syncPlistKeys {
            let scope = SyncItemCatalog.scope(of: k)
            guard scope == .all || scope == deviceLane,
                  let v = ud.object(forKey: k), Self.isPlistValue(v) else { continue }
            if scope == .all { dict[k] = v } else { lane[k] = v }
        }
        if !lane.isEmpty, let laneKey = deviceLane.laneKey { dict[laneKey] = lane }
        // Favorites' change and removal times (FavoritesSyncMerge).
        if includeBlobs, Self.favoritesSynced {
            dict[Self.favoritesSyncKey] = FavoritesSyncMerge.blob(localFavoritesState(now: Date().timeIntervalSince1970))
        }
        // The remote button map is carved out under its own category
        // (Discord: Glitzbr) and handled above the preferences gate.
        for k in syncHiddenGroupKeys where SyncItemCatalog.allows(k) {
            if let data = ud.data(forKey: k),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                dict[k] = arr
            }
        }
        // Hidden VOD titles (long-press Hide). One JSON blob carrying every
        // (playlist, title) entry with its hidden flag and timestamp, so the
        // merge on the other side is entry-wise last writer wins and an
        // unhide survives as a tombstone. Older clients ignore the key.
        if includeBlobs, SyncItemCatalog.isEnabled(SyncItemCatalog.hiddenTitlesID),
           let blob = HiddenVODStore.shared.syncBlob() {
            dict[HiddenVODStore.syncKey] = blob
        }
        if SyncItemCatalog.isEnabled(SyncItemCatalog.recentsID) {
            let recents = RecentChannelsStore.syncSnapshot()
            if !recents.isEmpty { dict[Self.recentsSyncKey] = recents }
        }
        if includeBlobs, SyncItemCatalog.isEnabled(SyncItemCatalog.watchlistID),
           let blob = WatchlistManager.syncBlob() {
            dict[Self.watchlistSyncKey] = blob
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
                // A different iCloud: what this device saw there no longer
                // applies, and its copy has to arrive before any push.
                Self.forgetSeen()
                UserDefaults.standard.set(false, forKey: Self.firstDownloadKey)
                UserDefaults.standard.removeObject(forKey: "syncProbeValue")
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
        CloudSnapshotSync.shared.foldProviders()
        doApplyPreferences(prefs: prefs)
        mergeRemoteWatchProgress(watchProgress)
        mergeRemoteReminders(reminders)
        noteMerged("iCloud change")
    }

    private func doMerge(servers: [[String: Any]]?, isInitial: Bool, replace: Bool = false) {
        guard let servers else {
            debugLog("🔵 SyncManager.doMerge: no server data")
            return
        }
        // v1.6.17, granular per-category gate. When the user opts out of
        // server sync on this device, ignore remote server payloads (their
        // local server list stays authoritative for this device).
        guard SyncCategory.servers.isEnabled else {
            debugLog("🔵 SyncManager.doMerge: category disabled by user, ignoring remote payload")
            return
        }

        isMerging = true
        defer { isMerging = false }

        let remoteServers = servers.compactMap { deserialize($0) }
        debugLog("🔵 SyncManager.doMerge: \(replace ? "replacing with" : "merging") \(remoteServers.count) servers (initial=\(isInitial))")

        NotificationCenter.default.post(
            name: .syncManagerDidReceiveRemoteServers,
            object: nil,
            userInfo: ["servers": remoteServers, "isInitial": isInitial, "replace": replace]
        )
    }

    /// Coexistence Rules 1 and 4 for one shared category on an iCloud pull: true when it must not
    /// apply. iCloud keeps pushing the full snapshot as the backup; a held or owned category waits.
    private func cloudPullBlocked(_ c: DsyncCategory, ignoreOwnership: Bool) -> Bool {
        let file = CloudCanon.fileName(c)
        if ProfileManager.shared.nonDefaultActive() {
            debugLog("[CLOUD] pull \(file) held: a non-default profile is active (iCloud carries the default profile)")
            return true
        }
        let cloud = CloudSnapshotSync.shared
        if cloud.sharedHeld() {
            debugLog("[CLOUD] pull \(file) held: waiting for the setup choice")
            return true
        }
        if !ignoreOwnership && cloud.cloudUnknown() {
            debugLog("[CLOUD] pull \(file) held: iCloud state unknown (setup probe failed)")
            return true
        }
        if !ignoreOwnership && DispatcharrSyncManager.shared.ownsCategory(c) {
            debugLog("[CLOUD] pull \(file) skipped: Dispatcharr Sync owns it")
            return true
        }
        return false
    }

    private func doApplyPreferences(prefs: [String: Any]?, replace: Bool = false, ignoreOwnership: Bool = false) {
        guard let dict = prefs else {
            debugLog("🔵 SyncManager.doApplyPreferences: no preference data")
            return
        }

        // Favorites merge per favorite on every pull, whatever the blob's time.
        var needsPush = false
        if !replace, Self.favoritesSynced, !cloudPullBlocked(.favorites, ignoreOwnership: ignoreOwnership) {
            needsPush = applyFavorites(from: dict)
        }
        defer { if needsPush { doPushPreferences(immediate: false, localChange: false) } }

        // Per key (PrefsLaneMerge, Logan 2026-11-10): a change made here gets
        // its time first, then only the keys that changed elsewhere after they
        // changed here apply. An explicit Replace pull applies every key.
        let cloudT = dict[Self.prefsModifiedAtKey] as? TimeInterval ?? 0
        let cloudTimes = dict[PrefsLaneMerge.timesKey] as? [String: TimeInterval] ?? [:]
        let cloudFlat = PrefsLaneMerge.flatten(dict, lanes: Self.prefsLanes, skip: Self.prefsSkipKeys)
        let local = localPrefKeys(buildPreferencesDict(), now: Date().timeIntervalSince1970)
        let newer: Set<String> = replace ? Set(cloudFlat.keys)
            : Set(PrefsLaneMerge.newerRemote(local: local.flat, localTimes: local.times, remote: cloudFlat,
                                             remoteTimes: cloudTimes, remoteStamp: cloudT))
        if !replace, !PrefsLaneMerge.merge(local: local.flat, localTimes: local.times, remote: cloudFlat,
                                           remoteTimes: cloudTimes, remoteStamp: cloudT).localNewer.isEmpty {
            // This device holds newer values iCloud lacks: send them after.
            needsPush = true
        }
        // Only what actually applied is settled (a key a category gate kept
        // out stays this device's own, with its own time).
        var applied: [String] = []
        func applies(_ flatKey: String) -> Bool {
            guard replace || newer.contains(flatKey) else { return false }
            applied.append(flatKey)
            return true
        }
        let laneName = SyncScope.deviceLane.laneKey.flatMap { Self.prefsLanes[$0] } ?? "mobile"
        defer { settlePrefKeys(applied, values: cloudFlat, times: cloudTimes, stamp: cloudT) }
        if !replace { debugLog("[SYNC] prefs pull: \(newer.count) key(s) newer in iCloud") }

        isMerging = true
        defer { isMerging = false }

        let ud = UserDefaults.standard
        // Rule 1: the preferences payload carries favorites, My List, hidden titles, recents,
        // collections, groups, the remote map, Radio Mode, and settings. While Dispatcharr Sync
        // owns them only the Sync category toggles apply (iCloud's own configuration).
        let blocked = [DsyncCategory.favorites, .watchlist, .preferences].filter { cloudPullBlocked($0, ignoreOwnership: ignoreOwnership) }
        if !blocked.isEmpty {
            for k in SyncCategory.allDefaultsKeys where applies("v:\(k)") {
                if let v = dict[k] as? Bool { ud.set(v, forKey: k) }
            }
            return
        }
        if cloudT > 0 { ud.set(cloudT, forKey: Self.prefsLocalModifiedAtDefaultsKey) }

        // v1.6.17, the per-category sync toggle states ALWAYS apply, even
        // when the user has "App Preferences" sync turned off. Otherwise a
        // user who disabled "App Preferences" sync on iPhone could never
        // re-enable it from iPad (the iPhone would never receive the flip).
        for k in SyncCategory.allDefaultsKeys where applies("v:\(k)") {
            if let v = dict[k] as? Bool { ud.set(v, forKey: k) }
        }

        // Remote button map rides its own category - applied before the
        // preferences gate so the two toggles stay independent (mirrors the
        // carve-out on the push side).
        if SyncCategory.remoteControl.isEnabled, applies("v:\(RemoteControlStore.mapKey)"),
           let v = dict[RemoteControlStore.mapKey] as? Data {
            ud.set(v, forKey: RemoteControlStore.mapKey)
        }
        // "Radio Mode by Default": applied only when this device opted in.
        if SyncCategory.radioModeDefault.isEnabled, applies("v:\(RadioModeSession.byDefaultKey)"),
           let v = dict[RadioModeSession.byDefaultKey] as? Bool {
            ud.set(v, forKey: RadioModeSession.byDefaultKey)
        }

        // Granular gate: when "App Preferences" sync is off on this device,
        // bail before applying the rest of the prefs payload. Local prefs
        // stay authoritative; the toggle flips above still propagated.
        guard SyncCategory.preferences.isEnabled else {
            debugLog("🔵 SyncManager.doApplyPreferences: category disabled by user, applied toggle subset only")
            return
        }

        let deviceLane = SyncScope.deviceLane
        let laneDict = deviceLane.laneKey.flatMap { dict[$0] as? [String: Any] } ?? [:]
        for k in syncPlistKeys {
            // Favorites merged per favorite above (a Replace takes iCloud's).
            if !replace, Self.favoriteKeys.contains(k) { continue }
            switch SyncItemCatalog.scope(of: k) {
            case .all:
                if applies("v:\(k)"), let v = dict[k], Self.isPlistValue(v) { ud.set(v, forKey: k) }
            case deviceLane:
                if applies("\(laneName):\(k)"), let v = laneDict[k], Self.isPlistValue(v) { ud.set(v, forKey: k) }
            default:
                break
            }
        }
        for k in legacyReadOnlyKeys where ud.object(forKey: k) == nil {
            if let v = dict[k], Self.isPlistValue(v) { ud.set(v, forKey: k) }
        }
        for k in syncHiddenGroupKeys where SyncItemCatalog.allows(k) && applies("v:\(k)") {
            if let arr = dict[k] as? [String],
               let data = try? JSONEncoder().encode(arr.sorted()) {
                ud.set(data, forKey: k)
            }
        }
        // Hidden VOD titles: merged per entry rather than overwritten, so a
        // hide made here and an unhide made there both land, newest stamp
        // winning, with per-playlist scoping intact.
        if replace {
            // Pull from iCloud replaces outright: a synced key the cloud copy
            // does not carry returns to its default here instead of keeping
            // this device's value, and hidden titles take the cloud table.
            let allKeys = (syncPlistKeys + syncHiddenGroupKeys).filter { SyncItemCatalog.allows($0) }
            for k in allKeys where dict[k] == nil { ud.removeObject(forKey: k) }
            if SyncCategory.remoteControl.isEnabled, dict[RemoteControlStore.mapKey] == nil {
                ud.removeObject(forKey: RemoteControlStore.mapKey)
            }
            if SyncItemCatalog.isEnabled(SyncItemCatalog.hiddenTitlesID) {
                HiddenVODStore.shared.replaceWithRemote(dict[HiddenVODStore.syncKey] as? Data)
            }
        } else if SyncItemCatalog.isEnabled(SyncItemCatalog.hiddenTitlesID),
                  let blob = dict[HiddenVODStore.syncKey] as? Data {
            HiddenVODStore.shared.mergeRemote(blob)
        }
        // Recently watched rides the blob last writer wins, like every
        // other preference; My List merges row-wise with tombstones.
        if SyncItemCatalog.isEnabled(SyncItemCatalog.recentsID), applies("v:\(Self.recentsSyncKey)"),
           let recents = dict[Self.recentsSyncKey] as? [String: [String]] {
            RecentChannelsStore.applySyncSnapshot(recents, replace: replace)
        }
        if SyncItemCatalog.isEnabled(SyncItemCatalog.watchlistID),
           let blob = dict[Self.watchlistSyncKey] as? Data {
            WatchlistManager.mergeSyncBlob(blob, replace: replace)
        }
        if replace, Self.favoritesSynced {
            // The cloud's favorites are now this device's synced state.
            let ids = ud.stringArray(forKey: "favoriteChannelIDs") ?? []
            let order = ud.stringArray(forKey: "favoriteOrder") ?? []
            let st = FavoritesSyncMerge.state(from: dict)
            Self.favoriteStamps.settle(live: Set(ids), removed: st?.side.removed ?? [:],
                                       touched: (st?.side.live ?? [:]).filter { $0.value > 0 })
            ud.set(order, forKey: Self.favoritesKnownOrderKey)
            FavoritesStore.shared.applySynced(order: order.isEmpty ? ids : order, items: ChannelStore.shared.channels)
        }
        // Stores that cache their keys in memory reload from defaults.
        ChannelCollectionsStore.shared.reloadFromDefaults()
        HiddenVODStore.shared.reloadCategoryVisibility()

        // What was just applied is the cloud state, not a local change.
        recordPrefsBaseline(buildPreferencesDict())
        prefsDirtySince = nil
        NotificationCenter.default.post(name: .syncManagerDidApplyPreferences, object: nil)
        debugLog("[SYNC] prefs applied from cloud (\(newer.count) keys)")
    }

    // MARK: - UserDefaults Observer

    private var udChangeCount = 0

    /// Called on the main queue by the block-based UserDefaults notification
    /// observer, for every defaults write. Coalesced: a short moment later the
    /// synced settings are looked at once, and each value that changed gets
    /// its change time then (PrefsLaneMerge), so a setting carries the time
    /// the user changed it, not the time of the next push.
    private var settingsLookPending = false

    private func handleUserDefaultsChange() {
        guard isSyncEnabled, !isMerging, !settingsLookPending else { return }
        settingsLookPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let mgr = SyncManager.shared
                mgr.settingsLookPending = false
                guard mgr.isSyncEnabled, !mgr.isMerging, !ProfileManager.shared.nonDefaultActive() else { return }
                let before = UserDefaults.standard.dictionary(forKey: SyncManager.prefsKeyTimesKey) as? [String: TimeInterval] ?? [:]
                let now = Date().timeIntervalSince1970
                let after = mgr.localPrefKeys(mgr.buildPreferencesDict(includeBlobs: false), now: now).times
                let changed = after.filter { before[$0.key] != $0.value }.count
                guard changed > 0 else { return }
                mgr.udChangeCount += 1
                if mgr.udChangeCount <= 3 || mgr.udChangeCount % 50 == 0 {
                    debugLog("[SYNC] settings changed here: \(changed) key(s) stamped")
                }
                if mgr.prefsDirtySince == nil { mgr.prefsDirtySince = Date(timeIntervalSince1970: now) }
                mgr.doPushPreferences(immediate: false, localChange: false)
            }
        }
    }

    // MARK: - Credential Sync

    func syncCredentials(for server: ServerConnection) {
        guard isSyncEnabled else { return }
        // v1.6.17, when the user opts out of credential sync, leave any
        // existing keychain entries on this device alone (don't migrate
        // them to synchronizable). Note: existing already-synchronizable
        // entries from prior versions can still appear on other devices
        // until "Delete Credentials from iCloud" is invoked from
        // Settings, this only affects what we migrate going forward.
        guard SyncCategory.credentials.isEnabled else {
            debugLog("🔵 SyncManager.syncCredentials: category disabled by user")
            return
        }
        let id = server.id.uuidString
        KeychainHelper.migrateToSynchronizable(key: "password_\(id)")
        // A key the server refused never goes to iCloud.
        if let key = KeychainHelper.load(key: "apiKey_\(id)"), DispatcharrRequestGate.shared.isKeyRejected(key) {
            debugLog("[SYNC] API key for \(id.prefix(8)) is held as rejected; not copied to iCloud Keychain")
        } else {
            KeychainHelper.migrateToSynchronizable(key: "apiKey_\(id)")
        }
    }

    // MARK: - Credential change times (2026-11-10)

    enum CredentialKind: String { case password, apiKey }

    /// When this device last changed (or adopted) the credential; 0 = unknown.
    nonisolated static func credentialChangedAt(_ kind: CredentialKind, _ serverID: UUID) -> TimeInterval {
        UserDefaults.standard.double(forKey: "syncCredentialChangedAt.\(kind.rawValue).\(serverID.uuidString)")
    }

    nonisolated static func setCredentialChangedAt(_ kind: CredentialKind, _ serverID: UUID, _ t: TimeInterval) {
        UserDefaults.standard.set(t, forKey: "syncCredentialChangedAt.\(kind.rawValue).\(serverID.uuidString)")
    }

    /// The credentials from an iCloud server record this device should
    /// store (CredentialSyncRule): never empty, never a rejected key, never
    /// older than this device's. Records the adopted change times.
    /// `local`: nil for a playlist new to this device.
    /// Launch (2026-11-10): when iCloud carries a different key for a
    /// playlist and this device's is not known to be newer, that key's first
    /// API calls wait for the merge (CredentialMergeBarrier, bounded).
    static func armLaunchCredentialBarrier() {
        guard UserDefaults.standard.bool(forKey: "iCloudSyncEnabled"),
              SyncCategory.servers.isEnabled, SyncCategory.credentials.isEnabled else { return }
        let records = NSUbiquitousKeyValueStore.default.array(forKey: "syncedServers") as? [[String: Any]] ?? []
        let entries = records.compactMap { d -> CredentialMergeBarrier.Entry? in
            guard let id = d["id"] as? String, let uuid = UUID(uuidString: id),
                  let cloud = d["_apiKey"] as? String, !cloud.isEmpty else { return nil }
            return CredentialMergeBarrier.Entry(
                localKey: ServerConnection.resolveCredential(key: "apiKey_\(id)", fallback: ""),
                localChangedAt: credentialChangedAt(.apiKey, uuid),
                cloudKey: cloud, cloudChangedAt: d["_apiKeyChangedAt"] as? Double ?? 0)
        }
        let keys = CredentialMergeBarrier.doubtfulKeys(entries)
        guard !keys.isEmpty else { return }
        CredentialMergeBarrier.shared.arm(doubtfulKeys: keys)
        debugLog("[SYNC] launch: iCloud carries a different API key for \(keys.count) playlist(s); "
                 + "their first calls wait for the merge (at most \(Int(CredentialMergeBarrier.maxWait)) s)")
    }

    /// A key the server just proved rejected (DispatcharrKeyBroker): when
    /// iCloud carries a different key for that playlist that the server has
    /// not refused, adopt it now (CredentialSyncRule: a rejected key never
    /// beats one the server has not refused) instead of waiting for the next
    /// pull. No network. Returns the adopted key.
    func adoptCloudApiKey(playlistID: UUID, rejectedKey: String) -> String? {
        guard isSyncEnabled, SyncCategory.credentials.isEnabled else { return nil }
        let records = NSUbiquitousKeyValueStore.default.array(forKey: kvsKey) as? [[String: Any]] ?? []
        guard let d = records.first(where: { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == playlistID }),
              let cloud = (d["_apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              CredentialSyncRule.adoptRemote(remote: cloud, remoteStamp: 0, local: rejectedKey, localStamp: 0,
                                             legacyRemoteNewer: false, replace: false,
                                             rejected: DispatcharrRequestGate.shared.isKeyRejected(cloud),
                                             localRejected: true)
        else { return nil }
        let slot = "apiKey_\(playlistID.uuidString)"
        KeychainHelper.save(cloud, for: slot)
        KeychainHelper.save(cloud, for: slot, synchronizable: true)
        let t = d["_apiKeyChangedAt"] as? Double ?? 0
        if t > 0 { Self.setCredentialChangedAt(.apiKey, playlistID, t) }
        DispatcharrRequestGate.shared.noteKeyReplaced(old: rejectedKey, new: cloud,
                                                      routes: DispatcharrKeyBroker.routes(serverID: playlistID))
        debugLog("[SYNC] adopting iCloud's apiKey for \(playlistID.uuidString.prefix(8)): the server rejected this device's key")
        return cloud
    }

    func credentialsToAdopt(_ remote: SyncedServer, local: ServerConnection?,
                            legacyRemoteNewer: Bool, replace: Bool) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        let id = remote.id
        let pairs: [(CredentialKind, String, TimeInterval, String)] = [
            (.password, remote.password, remote.passwordChangedAt, local?.effectivePassword ?? ""),
            (.apiKey, remote.apiKey, remote.apiKeyChangedAt, local?.baseApiKey ?? "")
        ]
        for (kind, value, remoteStamp, localValue) in pairs {
            let rejected = kind == .apiKey && !value.isEmpty && DispatcharrRequestGate.shared.isKeyRejected(value)
            let localRejected = kind == .apiKey && !localValue.isEmpty && DispatcharrRequestGate.shared.isKeyRejected(localValue)
            let localStamp = local == nil ? 0 : Self.credentialChangedAt(kind, id)
            guard CredentialSyncRule.adoptRemote(remote: value, remoteStamp: remoteStamp,
                                                 local: localValue, localStamp: localStamp,
                                                 legacyRemoteNewer: legacyRemoteNewer, replace: replace,
                                                 rejected: rejected, localRejected: localRejected) else {
                if rejected { debugLog("[SYNC] iCloud carries a rejected API key for \(id.uuidString.prefix(8)); not stored") }
                else if !value.isEmpty, value != localValue {
                    debugLog("[SYNC] kept this device's \(kind.rawValue) for \(id.uuidString.prefix(8)): iCloud's is not newer (cloud=\(Int(remoteStamp)) local=\(Int(localStamp)))")
                }
                continue
            }
            if localRejected {
                debugLog("[SYNC] adopting iCloud's apiKey for \(id.uuidString.prefix(8)): the server rejected this device's key")
            }
            if remoteStamp > 0 { Self.setCredentialChangedAt(kind, id, remoteStamp) }
            out.append(("\(kind.rawValue)_\(id.uuidString)", value))
        }
        return out
    }

    func saveCredentialsSynced(for server: ServerConnection) {
        guard isSyncEnabled else {
            server.saveCredentialsToKeychain()
            return
        }
        // v1.6.17, granular per-category gate. Fall back to local-only
        // keychain saves so a credential change doesn't leak across
        // devices when the user opted out.
        guard SyncCategory.credentials.isEnabled else {
            debugLog("🔵 SyncManager.saveCredentialsSynced: category disabled by user, saving locally")
            server.saveCredentialsToKeychain()
            return
        }
        // Prefer in-memory edits over cached keychain copies so a user can
        // rotate credentials on this device even when an older value is still
        // present locally or in iCloud Keychain.
        let pw  = server.password.isEmpty ? server.effectivePassword : server.password
        let key = server.apiKey.isEmpty ? server.baseApiKey : server.apiKey
        let id  = server.id.uuidString
        // A changed value records its change time, so iCloud never lets an
        // older copy from another device replace it (CredentialSyncRule).
        let now = Date().timeIntervalSince1970
        if !pw.isEmpty, pw != ServerConnection.resolveCredential(key: "password_\(id)", fallback: "") {
            Self.setCredentialChangedAt(.password, server.id, now)
        }
        if !key.isEmpty, key != ServerConnection.resolveCredential(key: "apiKey_\(id)", fallback: "") {
            Self.setCredentialChangedAt(.apiKey, server.id, now)
        }
        let keyRejected = !key.isEmpty && DispatcharrRequestGate.shared.isKeyRejected(key)

        // Only drop the in-memory copy AFTER the credential is safely
        // persisted to the LOCAL keychain (the canonical store that
        // effectivePassword/effectiveApiKey fall back to). The previous code
        // cleared unconditionally, so a failed Keychain write lost the
        // credential entirely. The synchronizable (iCloud) write may fail
        // independently, e.g. iCloud Keychain disabled, without data loss
        // because the local copy remains, so it does not gate the clear.
        if !pw.isEmpty {
            let localOK = KeychainHelper.save(pw, for: "password_\(id)")
            KeychainHelper.save(pw, for: "password_\(id)", synchronizable: true)
            if localOK {
                server.password = ""
            } else {
                debugLog("🔵 SyncManager.saveCredentialsSynced: local password Keychain save FAILED, keeping in-memory copy")
            }
        }
        if !key.isEmpty {
            let localOK = KeychainHelper.save(key, for: "apiKey_\(id)")
            if keyRejected {
                debugLog("[SYNC] API key for \(id.prefix(8)) is held as rejected; saved on this device only, not to iCloud Keychain")
            } else {
                KeychainHelper.save(key, for: "apiKey_\(id)", synchronizable: true)
            }
            if localOK {
                server.apiKey = ""
            } else {
                debugLog("🔵 SyncManager.saveCredentialsSynced: local apiKey Keychain save FAILED, keeping in-memory copy")
            }
        }
    }

    // MARK: - Serialization

    private func serialize(_ server: ServerConnection) -> [String: Any] {
        debugLog("🔵 SyncManager.serialize: \(server.name), thread=\(Thread.current)")
        var dict = serializeRecord(server)
        let changed = Self.serverChangedAt(server.id.uuidString, record: dict)
        if changed > 0 { dict["_changedAt"] = changed }
        appendCredentials(server, to: &dict)
        return dict
    }

    // MARK: - Playlist change times (2026-11-10)

    /// Fields that change without the playlist changing (or have their own rule).
    private static let volatileServerKeys: Set<String> = [
        "lastConnected", "isActive", "_password", "_apiKey", "_passwordChangedAt", "_apiKeyChangedAt", "_changedAt",
        "dispatcharrAccountUsername"
    ]

    nonisolated static func legacyServerStamp(_ row: [String: Any]) -> TimeInterval {
        row["lastConnected"] as? TimeInterval ?? row["createdAt"] as? TimeInterval ?? 0
    }

    /// A row's change time: its own, else the shipped rule's date for an older build's row.
    nonisolated static func serverRowStamp(_ row: [String: Any]) -> TimeInterval {
        if let t = row["_changedAt"] as? TimeInterval, t > 0 { return t }
        return legacyServerStamp(row)
    }

    /// When this playlist's synced fields last changed here (0: unknown), from
    /// the record's fingerprint against the one last recorded. A first
    /// sighting is of unknown age: 0, never "now" (the merge then uses the
    /// shipped rule's date, `serverRowStamp`).
    private static func serverChangedAt(_ id: String, record: [String: Any]) -> TimeInterval {
        let fp = PrefsSyncClock.fingerprint(record.filter { !volatileServerKeys.contains($0.key) })
        var fps = UserDefaults.standard.dictionary(forKey: serverFingerprintsKey) as? [String: String] ?? [:]
        let stamps = serverStamps
        if fps[id] == fp, let t = stamps.touched[id] { return t }
        let t: TimeInterval = fps[id] == nil ? (stamps.touched[id] ?? 0) : Date().timeIntervalSince1970
        fps[id] = fp
        UserDefaults.standard.set(fps, forKey: serverFingerprintsKey)
        stamps.touch(id, at: t)
        return t
    }

    /// A playlist record just adopted from iCloud: its fields are the synced
    /// state at the sender's change time, not a local change.
    func noteServerAdopted(_ server: ServerConnection, changedAt: TimeInterval) {
        let record = serializeRecord(server)
        let fp = PrefsSyncClock.fingerprint(record.filter { !Self.volatileServerKeys.contains($0.key) })
        var fps = UserDefaults.standard.dictionary(forKey: Self.serverFingerprintsKey) as? [String: String] ?? [:]
        fps[server.id.uuidString] = fp
        UserDefaults.standard.set(fps, forKey: Self.serverFingerprintsKey)
        Self.serverStamps.touch(server.id.uuidString, at: changedAt)
    }

    /// The playlist's identity for the one-playlist rule (PlaylistIdentity):
    /// never the key itself, only its fingerprint.
    func playlistIdentityRow(_ s: ServerConnection) -> PlaylistIdentity.Row {
        let type = s.type == .dispatcharrAPI ? "dispatcharr" : (s.type == .xtreamCodes ? "xtream" : "m3u")
        var user = s.username
        if s.type == .dispatcharrAPI, user.trimmingCharacters(in: .whitespaces).isEmpty {
            user = DispatcharrAccountFactsStore.load(s.id).username
        }
        let key = s.type == .dispatcharrAPI ? s.baseApiKey : ""
        return .init(id: s.id.uuidString, type: type, url: s.baseURL, username: user,
                     apiKeyFP: PlaylistIdentity.keyFingerprint(key),
                     changedAt: Self.serverStamps.touched[s.id.uuidString] ?? 0,
                     createdAt: s.createdAt.timeIntervalSince1970)
    }

    /// A playlist merged into another here: its deletion time is now, so
    /// every device converges. The winner is remembered: if another device
    /// picked the opposite (their stamps briefly differed) and sends a
    /// deletion time for it, it is kept and re-sent live, never lost.
    func notePlaylistMergedAway(_ id: String, into winner: String) {
        let st = Self.serverStamps
        var live = st.known ?? []
        live.remove(id)
        st.settle(live: live, removed: [id: Date().timeIntervalSince1970])
        var map = UserDefaults.standard.dictionary(forKey: Self.playlistMergedIntoKey) as? [String: String] ?? [:]
        map[id] = winner
        UserDefaults.standard.set(map, forKey: Self.playlistMergedIntoKey)
    }

    private static let playlistMergedIntoKey = "syncPlaylistMergedInto.v1"

    /// The account (username) iCloud sync reported for playlist `id`, from the
    /// synced playlist records, or nil. Fix Login's one-playlist identity rule
    /// (Android SyncStamps.learnedAccount). Main queue only (KVS).
    func learnedAccount(playlistID id: String) -> String? {
        let want = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !want.isEmpty,
              let records = NSUbiquitousKeyValueStore.default.array(forKey: kvsKey) as? [[String: Any]] else { return nil }
        for r in records where (r["id"] as? String)?.lowercased() == want {
            if let u = (r["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty { return u }
        }
        return nil
    }

    /// True when this device merged another playlist into [id]: a deletion
    /// time for it is the other device's opposite pick. It stays, with a
    /// fresh change time so it wins and every device converges on it.
    func keepMergedWinner(_ id: String) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: Self.playlistMergedIntoKey) as? [String: String] ?? [:]
        guard map.values.contains(id) else { return false }
        Self.serverStamps.touch(id, at: Date().timeIntervalSince1970)
        debugLog("[SYNC] kept playlist \(id.prefix(8)): another device merged it away while this one merged into it")
        return true
    }

    /// The pull plan for playlists (AerioApp mergeRemoteServers): per
    /// playlist, newest change or deletion wins, a tie keeps iCloud's.
    /// `newer`: the playlists whose iCloud record is strictly newer than
    /// this device's (the only ones whose fields are copied).
    func serverMergePlan(remote: [SyncedServer], local: [ServerConnection]) -> (picks: [String: LaneMerge.Pick], newer: Set<String>) {
        let now = Date().timeIntervalSince1970
        let stamps = Self.serverStamps
        var localStamps: [String: TimeInterval] = [:]
        for s in local where !s.isGone {
            let record = serializeRecord(s)
            let t = Self.serverChangedAt(s.id.uuidString, record: record)
            localStamps[s.id.uuidString] = t > 0 ? t : Self.legacyServerStamp(record)
        }
        stamps.observe(live: Set(localStamps.keys), now: now)
        let remoteStamps = Dictionary(remote.map { ($0.id.uuidString, $0.stamp) }, uniquingKeysWith: { max($0, $1) })
        let removed = NSUbiquitousKeyValueStore.default.dictionary(forKey: Self.serversRemovedKVSKey) as? [String: TimeInterval] ?? [:]
        let picks = LaneMerge.plan(local: .init(live: localStamps, removed: stamps.removed),
                                   remote: .init(live: remoteStamps, removed: removed),
                                   base: Self.loadSeen("playlists"), now: now)
        let newer = Set(remoteStamps.filter { k, t in localStamps[k].map { t > $0 } ?? true }.keys)
        return (picks, newer)
    }

    /// After the playlist merge: settle what it applied and record what iCloud had.
    func noteServersMerged(remote: [SyncedServer], liveAfter: Set<String>, removedApplied: [String: TimeInterval]) {
        Self.serverStamps.settle(live: liveAfter, removed: removedApplied)
        Self.saveSeen("playlists", Dictionary(remote.map { ($0.id.uuidString, $0.stamp) }, uniquingKeysWith: { max($0, $1) }))
    }

    /// The playlist's own fields (no credentials, no change time).
    private func serializeRecord(_ server: ServerConnection) -> [String: Any] {
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
        // v1.6.20: cross-device persistence of the auto-detected
        // Dispatcharr auth header shape. Empty (= "not yet detected")
        // skipped intentionally so we don't overwrite a remote
        // device's already-discovered shape with our pre-discovery
        // default. Older clients that don't know about this key
        // simply ignore it during deserialize and keep their own
        // local default.
        if !server.dispatcharrAuthMode.isEmpty {
            dict["dispatcharrAuthMode"] = server.dispatcharrAuthMode
        }
        // v1.7 Direct Connect: cross-device persistence of the
        // credential type. Empty (= "" = .apiKey, the legacy default)
        // is omitted so older clients don't see an unfamiliar key
        // and stay perfectly back-compat. Only ".usernamePassword"
        // values ride along on the wire, and a v1.6.x client
        // receiving this key just ignores it during deserialize and
        // treats the server as a regular Dispatcharr API server,
        // which still works because we ALSO sync the API key (fetched
        // from /api/accounts/users/me/ at login time) into the
        // Keychain via the existing apiKey_<id> pattern.
        if !server.dispatcharrCredentialTypeRaw.isEmpty {
            dict["dispatcharrCredentialType"] = server.dispatcharrCredentialTypeRaw
        }
        // v1.7.x: cross-device persistence of the connected Dispatcharr
        // user's permission tier, used to gate the server-side Record /
        // DVR affordances. Only carried when it's below the default 10
        // (admin): a Standard / Streamer account is the only case worth
        // restricting, and omitting the key for the common admin case
        // keeps the payload identical to today and invisible to older
        // clients (which ignore the unknown key and keep their own
        // recording-capable default).
        if server.dispatcharrUserLevel < 10 {
            dict["dispatcharrUserLevel"] = server.dispatcharrUserLevel
        }
        // Per-user capability snapshot. Syncing ONLY the level (and the
        // profile ids) is what made a synced playlist arrive with no DVR
        // permission at all and resolve to view-only on the receiving
        // device: the whole point of the snapshot is that the level alone
        // does not determine access. Carry the entire thing. Every key is
        // omitted when it carries no information, so older clients see an
        // unchanged payload and ignore what they do not know.
        if server.dispatcharrIsStaff { dict["dispatcharrIsStaff"] = true }
        if server.dispatcharrIsSuperuser { dict["dispatcharrIsSuperuser"] = true }
        if !server.dispatcharrCustomPropertiesJSON.isEmpty {
            dict["dispatcharrCustomProperties"] = server.dispatcharrCustomPropertiesJSON
        }
        if let fetched = server.dispatcharrPermissionsFetchedAt {
            dict["dispatcharrPermissionsFetchedAt"] = fetched.timeIntervalSince1970
        }
        if server.dispatcharrCapabilitiesSchema > 0 {
            dict["dispatcharrCapabilitiesSchema"] = server.dispatcharrCapabilitiesSchema
        }
        if let sysCatchup = server.dispatcharrSystemCatchupEnabled {
            dict["dispatcharrSystemCatchupEnabled"] = sysCatchup
        }
        // v1.7.x: cross-device persistence of the connected Dispatcharr
        // user's assigned Channel Profile id(s), used to drive the
        // child-safety Channel Profile filter on the channel list. Only
        // carried when non-empty: a server with no profile assigned is
        // the common case, and omitting the key for it keeps the payload
        // identical to today and invisible to older clients (which ignore
        // the unknown key and keep their own unfiltered default).
        if !server.dispatcharrChannelProfileIDs.isEmpty {
            dict["dispatcharrChannelProfileIDs"] = server.dispatcharrChannelProfileIDs
        }
        // Task #189: user-chosen Channel Profile (Edit Playlist picker).
        // Only carried when set, same older-client-invisible pattern as
        // the account field above.
        if let selected = server.dispatcharrSelectedProfileID {
            dict["dispatcharrSelectedProfileID"] = selected
        }
        // Catch-up: per-server guide-history retention (days). Only
        // carried when it differs from the default 7 so the payload
        // stays identical to today for untouched servers and older
        // clients never see an unfamiliar key.
        if server.epgRetentionDays != 7 {
            dict["epgRetentionDays"] = server.epgRetentionDays
        }
        // Per-playlist settings that a user expects to follow the playlist
        // to another device: DVR default destination, Fetch On Demand, and
        // the catch-up time offset. Older clients ignore the keys; an absent
        // key leaves the receiving device's value untouched.
        dict["defaultRecordingDestination"] = server.defaultRecordingDestinationRaw
        dict["vodEnabled"] = server.vodEnabled
        dict["catchupTimeOffsetMinutes"] = CatchupSupport.timeOffsetMinutes(serverID: server.id)
        // The Dispatcharr account (users/me) so another device can tell this
        // is the same playlist (one-playlist rule); not a secret.
        if server.type == .dispatcharrAPI {
            let u = DispatcharrAccountFactsStore.load(server.id).username
            if !u.isEmpty { dict["dispatcharrAccountUsername"] = u }
        }
        return dict
    }

    private func appendCredentials(_ server: ServerConnection, to dict: inout [String: Any]) {
        // v1.6.23: re-include credentials in the KVS payload as a
        // **transport fallback** when iCloud Keychain isn't propagating.
        //
        // History: v1.6.12 stopped writing `_password` / `_apiKey` here
        // on the assumption that iCloud Keychain (which we set with
        // `kSecAttrSynchronizable = true` in `saveCredentialsSynced`)
        // would carry credentials across devices. Field reports in
        // v1.6.22 (Freyguy1975, multiple Apple TV deployments) showed
        // that path fails silently for any user who hasn't enabled
        // iCloud Keychain on the receiving device, the server
        // metadata syncs via KVS, the device renders the playlist,
        // every API call returns 401, and there's no UX recovery short
        // of re-entering the API key. The KVS payload is still
        // encrypted in transit by Apple, scoped to this app's iCloud
        // container, and only readable by the user's own devices,
        // it's a weaker store than Keychain but acceptable as a
        // fallback for users who declined the Keychain path.
        //
        // The Keychain write in `saveCredentialsSynced` stays the
        // primary persistence; this is the *transport*. When iCloud
        // Keychain DOES work, the receiving device's `effectiveApiKey`
        // returns the Keychain copy (which the merge path overwrote
        // from this `_apiKey` value, idempotent). When iCloud Keychain
        // doesn't work, this is the only path the credential reaches
        // the second device.
        //
        // Gated on `SyncCategory.credentials.isEnabled` so users who
        // explicitly opted credentials out of sync don't get them
        // shipped via KVS either, same gate as the Keychain write
        // in `saveCredentialsSynced`.
        if SyncCategory.credentials.isEnabled {
            let pw  = server.effectivePassword
            let key = server.baseApiKey
            if !pw.isEmpty {
                dict["_password"] = pw
                let t = Self.credentialChangedAt(.password, server.id)
                if t > 0 { dict["_passwordChangedAt"] = t }
            }
            // A key the server refused is never carried to iCloud.
            if !key.isEmpty, !DispatcharrRequestGate.shared.isKeyRejected(key) {
                dict["_apiKey"] = key
                let t = Self.credentialChangedAt(.apiKey, server.id)
                if t > 0 { dict["_apiKeyChangedAt"] = t }
            }
        }
    }

    private nonisolated func deserialize(_ dict: [String: Any]) -> SyncedServer? {
        guard let idStr   = dict["id"] as? String,
              let id      = UUID(uuidString: idStr),
              let name    = dict["name"] as? String,
              let typeRaw = dict["type"] as? String,
              let type    = ServerType(rawValue: typeRaw),
              let baseURL = dict["baseURL"] as? String else { return nil }

        // `_password` / `_apiKey` carry credentials across devices via the
        // KVS payload. History: v1.6.12 briefly stopped writing them (relying
        // on iCloud Keychain alone), but v1.6.23 RESTORED the carry after
        // field reports that Keychain-only sync failed for users without
        // iCloud Keychain enabled on a second device (commonly Apple TV): the
        // server metadata synced and the playlist rendered, but every API call
        // returned 401 with no recovery short of re-typing the key. There is
        // no longer a purge task. When present, `mergeRemoteServers` adopts
        // these into the local + iCloud Keychain copies. The carry is gated on
        // `SyncCategory.credentials.isEnabled` in `serialize`, and KVS is
        // encrypted in transit and at rest by Apple and scoped to the user's
        // own private iCloud container (a weaker store than Keychain, kept as a
        // deliberate fallback so credential sync works without iCloud Keychain).
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
            apiKey:        dict["_apiKey"]     as? String ?? "",
            dispatcharrAuthMode: dict["dispatcharrAuthMode"] as? String ?? "",
            // v1.7: empty string from older clients defaults to
            // .apiKey via `dispatcharrCredentialType` accessor on the
            // SwiftData model. No data loss for legacy senders.
            dispatcharrCredentialTypeRaw: dict["dispatcharrCredentialType"] as? String ?? "",
            // v1.7.x: absent (older sender or omitted admin default)
            // means 10 (admin = recording-capable). Only a positively
            // synced sub-10 value restricts the server-side Record /
            // DVR affordances on this device.
            dispatcharrUserLevel: dict["dispatcharrUserLevel"] as? Int ?? 10,
            // Per-user capability snapshot. Absent (older sender) leaves
            // the receiving device with no snapshot, which reads
            // `.unknown` -> affordances stay ENABLED and the server
            // decides, rather than the old silent downgrade to view-only.
            dispatcharrIsStaff: dict["dispatcharrIsStaff"] as? Bool ?? false,
            dispatcharrIsSuperuser: dict["dispatcharrIsSuperuser"] as? Bool ?? false,
            dispatcharrCustomPropertiesJSON: dict["dispatcharrCustomProperties"] as? String ?? "",
            dispatcharrPermissionsFetchedAt: (dict["dispatcharrPermissionsFetchedAt"] as? TimeInterval)
                .map { Date(timeIntervalSince1970: $0) },
            dispatcharrCapabilitiesSchema: dict["dispatcharrCapabilitiesSchema"] as? Int ?? 0,
            dispatcharrSystemCatchupEnabled: dict["dispatcharrSystemCatchupEnabled"] as? Bool,
            // v1.7.x: absent (older sender or a server with no profile
            // assigned) means "" = no filter = show all channels. Only a
            // positively synced non-empty value drives the child-safety
            // Channel Profile filter on this device.
            dispatcharrChannelProfileIDs: dict["dispatcharrChannelProfileIDs"] as? String ?? "",
            // Task #189: absent means nil = All Channels (older sender or
            // no profile chosen).
            dispatcharrSelectedProfileID: dict["dispatcharrSelectedProfileID"] as? Int,
            // Catch-up: absent (older sender or untouched default)
            // means 7 days of retained guide history.
            epgRetentionDays: dict["epgRetentionDays"] as? Int ?? 7,
            defaultRecordingDestinationRaw: dict["defaultRecordingDestination"] as? String,
            vodEnabled: dict["vodEnabled"] as? Bool,
            catchupTimeOffsetMinutes: dict["catchupTimeOffsetMinutes"] as? Int,
            // Absent (older sender, or never changed since this rule): 0.
            passwordChangedAt: dict["_passwordChangedAt"] as? TimeInterval ?? 0,
            apiKeyChangedAt: dict["_apiKeyChangedAt"] as? TimeInterval ?? 0,
            changedAt: Self.serverRowStamp(dict),
            knownChangedAt: dict["_changedAt"] as? TimeInterval ?? 0,
            accountUsername: dict["dispatcharrAccountUsername"] as? String ?? ""
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
        /// movies). Carried through iCloud sync as of v1.6.8, see
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
        if ProfileManager.shared.nonDefaultActive() { return }  // iCloud carries the default profile only
        // v1.6.17, granular per-category gate.
        guard SyncCategory.watchProgress.isEnabled else {
            debugLog("🔵 SyncManager.pushWatchProgress: category disabled by user")
            return
        }

        let payload = entries.filter { !$0.isDeleted }.map { serializeWatchProgress($0) }
        let localRows = WatchProgressSyncMerge.byKey(payload, key: WatchProgressSyncMerge.key, stamp: WatchProgressSyncMerge.stamp)
        // A row removed here since the last look gets its deletion time now,
        // before any wait, so the removal is never mistaken for an absence.
        Self.progressStamps.observe(live: Set(localRows.keys), now: Date().timeIntervalSince1970)
        guard mergedBeforePush(.serversAndProgress) else { return }

        CloudSnapshotSync.shared.follow(.watchProgress, "progress local")
        nonisolated(unsafe) let capturedRows = localRows
        // What this device had seen in iCloud when it took this snapshot.
        let seen = Self.loadSeen("watchProgress")

        watchProgressPushDebounce?.cancel()
        let key = watchProgressKVSKey
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                SyncManager.shared.lastPushTime = ProcessInfo.processInfo.systemUptime
                // Re-read right before the write and merge per entry (newest
                // wins, a tie keeps iCloud's, deletions by their time), so
                // nothing another device changed in between is lost.
                let store = NSUbiquitousKeyValueStore.default
                let now = Date().timeIntervalSince1970
                let remote = WatchProgressSyncMerge.byKey(store.array(forKey: key) as? [[String: Any]] ?? [],
                                                          key: WatchProgressSyncMerge.key, stamp: WatchProgressSyncMerge.stamp)
                let remoteRemoved = store.dictionary(forKey: SyncManager.progressRemovedKVSKey) as? [String: TimeInterval] ?? [:]
                let stamps = SyncManager.progressStamps
                stamps.prune(now: now)
                let r = LaneMerge.forPush(local: capturedRows, localRemoved: stamps.removed, remote: remote,
                                          remoteRemoved: remoteRemoved, base: seen, stamp: WatchProgressSyncMerge.stamp, now: now)
                store.set(r.rows, forKey: key)
                store.set(r.removed, forKey: SyncManager.progressRemovedKVSKey)
                SyncManager.saveSeen("watchProgress", r.base)
                debugLog("🔵 SyncManager: pushed \(r.rows.count) watch progress entries to KVS (local=\(capturedRows.count) keptFromCloud=\(r.keptFromCloud) deletions=\(r.removed.count))")
            }
        }
        watchProgressPushDebounce = work
        // Manual (immediate) pushes drive the Settings > Sync progress
        // indicator. `notify` fires whether the item runs or is cancelled
        // by a newer push, so the counter can never leak.
        if immediate {
            beginActivity(.pushing)
            work.notify(queue: .main) {
                MainActor.assumeIsolated {
                    SyncManager.shared.endActivity(failure: SyncManager.pushFailureReason())
                }
            }
        }

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
    /// numeric ID for unrelated content, uniqueness moved into
    /// `(vodID, serverID)`. The merge path was never updated to
    /// match: any user with resume progress on the same `vodID`
    /// across two servers (i.e., two Dispatcharr instances pulling
    /// from overlapping providers) hit a hard crash inside
    /// `pullFromCloud` the first time iCloud KVS pushed those
    /// entries down. Keys are now composite (`serverID|vodID`) and
    /// dictionary construction uses `uniquingKeysWith:` so neither
    /// path can ever trap on a duplicate again, if two payloads
    /// share a composite key (corrupted state, double-push race),
    /// the most recently updated wins.
    private func mergeRemoteWatchProgress(_ remoteEntries: [[String: Any]]?, replace: Bool = false, ignoreOwnership: Bool = false) {
        // nil means the cloud has no watch-progress key at all, nothing to
        // apply in either mode. An EMPTY array during a replace is meaningful
        // ("the authoritative device has no progress"), so it falls through
        // to the delete pass below instead of returning early.
        let remoteRemoved = NSUbiquitousKeyValueStore.default.dictionary(forKey: Self.progressRemovedKVSKey) as? [String: TimeInterval] ?? [:]
        guard let remoteEntries = remoteEntries ?? (remoteRemoved.isEmpty ? nil : []) else { return }
        guard replace || !remoteEntries.isEmpty || !remoteRemoved.isEmpty else { return }
        guard !cloudPullBlocked(.watchProgress, ignoreOwnership: ignoreOwnership) else { return }
        guard let context = WatchProgressManager.modelContext else { return }
        // v1.6.17, granular per-category gate. Local watch progress
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
        // both expose `vodID` + `serverID` but aren't the same
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

        // Per entry (LaneMerge): the newest change or deletion wins, a tie
        // keeps iCloud's; an entry added here and not pushed yet survives; one
        // deleted here is not re-inserted. Absence deletes only once a pull
        // recorded what iCloud had. A replace keeps the cloud authoritative.
        let now = Date().timeIntervalSince1970
        let stamps = Self.progressStamps
        let localStamps = localByID.mapValues { $0.updatedAt.timeIntervalSince1970 }
        let remoteStamps = remoteByID.mapValues { $0.updatedAt.timeIntervalSince1970 }
        stamps.observe(live: Set(localStamps.keys), now: now)
        let plan = LaneMerge.plan(local: .init(live: localStamps, removed: stamps.removed),
                                  remote: .init(live: remoteStamps, removed: remoteRemoved),
                                  base: Self.loadSeen("watchProgress"), now: now)
        var liveAfter = Set(localStamps.keys)

        // Upsert remote → local
        for remote in remoteByID.values {
            let ck = compositeKey(remote.vodID, remote.serverID)
            if !replace, plan[ck] != .remote { continue }
            liveAfter.insert(ck)
            if let local = localByID[ck] {
                // Conflict: most recent updatedAt wins. A replace is the user
                // declaring the cloud authoritative, so remote wins outright.
                if replace || remote.updatedAt > local.updatedAt {
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

        // Delete locals deleted on another device: absent from remote, seen
        // there before, and not changed here since.
        var deleted = 0
        var applied: [String: TimeInterval] = [:]
        for local in locals {
            let ck = compositeKey(local.vodID, local.serverID)
            let drop: Bool
            if replace {
                drop = !remoteKeys.contains(ck)
            } else {
                switch plan[ck] {
                case .removed(let t)?: drop = true; applied[ck] = t
                case .gone?: drop = true
                default: drop = false
                }
            }
            if drop {
                context.delete(local)
                liveAfter.remove(ck)
                deleted += 1
            }
        }
        // What this merge applied is the synced state, not a local change.
        for (k, p) in plan { if case .removed(let t) = p { applied[k] = max(applied[k] ?? 0, t) } }
        stamps.settle(live: liveAfter, removed: applied)
        Self.saveSeen("watchProgress", remoteStamps)

        try? context.save()
        debugLog("🔵 SyncManager: merged \(remotes.count) remote watch progress entries (deleted here=\(deleted))")

        NotificationCenter.default.post(name: .syncManagerDidUpdateWatchProgress, object: nil)
    }

    // MARK: - Reminder Sync

    /// Push local reminders to iCloud KVS (debounced).
    func pushReminders(immediate: Bool = false) {
        guard isSyncEnabled, !isMerging else { return }
        if ProfileManager.shared.nonDefaultActive() { return }  // iCloud carries the default profile only
        // v1.6.17, granular per-category gate.
        guard SyncCategory.reminders.isEnabled else {
            debugLog("🔵 SyncManager.pushReminders: category disabled by user")
            return
        }
        let reminders = ReminderManager.shared.syncableReminders
        // A reminder cancelled here since the last look gets its deletion time now.
        Self.reminderStamps.observe(live: Set(reminders.keys), now: Date().timeIntervalSince1970)
        guard mergedBeforePush(.reminders) else { return }

        CloudSnapshotSync.shared.follow(.reminders, "reminders local")
        var localRows: [String: [String: Any]] = [:]
        for (key, r) in reminders {
            localRows[key] = [
                "key": key,
                "programTitle": r.programTitle,
                "channelName": r.channelName,
                "startTime": r.startTime.timeIntervalSince1970,
                "updatedAt": r.updatedAt.timeIntervalSince1970
            ]
        }
        nonisolated(unsafe) let capturedRows = localRows
        let seen = Self.loadSeen("reminders")

        reminderPushDebounce?.cancel()
        let key = reminderKVSKey
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                SyncManager.shared.lastPushTime = ProcessInfo.processInfo.systemUptime
                // Re-read and merge per reminder, like watch progress.
                let store = NSUbiquitousKeyValueStore.default
                let now = Date().timeIntervalSince1970
                let remote = SyncManager.reminderRows(store.array(forKey: key) as? [[String: Any]] ?? [])
                let remoteRemoved = store.dictionary(forKey: SyncManager.remindersRemovedKVSKey) as? [String: TimeInterval] ?? [:]
                let stamps = SyncManager.reminderStamps
                stamps.prune(now: now)
                let r = LaneMerge.forPush(local: capturedRows, localRemoved: stamps.removed, remote: remote,
                                          remoteRemoved: remoteRemoved, base: seen, stamp: SyncManager.reminderStamp, now: now)
                // A reminder whose program started over a day ago is spent.
                let live = r.rows.filter {
                    SyncMerge.keepReminder(removedAt: nil, endMs: Int64(($0["startTime"] as? TimeInterval ?? 0) * 1000), nowMs: Int64(now * 1000))
                }
                store.set(live, forKey: key)
                store.set(r.removed, forKey: SyncManager.remindersRemovedKVSKey)
                SyncManager.saveSeen("reminders", r.base)
                debugLog("🔵 SyncManager: pushed \(live.count) reminders to KVS (local=\(capturedRows.count) keptFromCloud=\(r.keptFromCloud) deletions=\(r.removed.count))")
            }
        }
        reminderPushDebounce = work
        // Manual (immediate) pushes drive the Settings > Sync progress
        // indicator. `notify` fires whether the item runs or is cancelled
        // by a newer push, so the counter can never leak.
        if immediate {
            beginActivity(.pushing)
            work.notify(queue: .main) {
                MainActor.assumeIsolated {
                    SyncManager.shared.endActivity(failure: SyncManager.pushFailureReason())
                }
            }
        }

        if immediate {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
    }

    /// Merge remote reminders from iCloud into local ReminderManager.
    private func mergeRemoteReminders(_ remoteEntries: [[String: Any]]?, ignoreOwnership: Bool = false) {
        // Deletion times alone (every reminder cancelled) still apply.
        let hasRemovals = NSUbiquitousKeyValueStore.default.dictionary(forKey: Self.remindersRemovedKVSKey) != nil
        guard let remoteEntries = remoteEntries ?? (hasRemovals ? [] : nil) else { return }
        guard !cloudPullBlocked(.reminders, ignoreOwnership: ignoreOwnership) else { return }
        // v1.6.17, granular per-category gate.
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

        // Per reminder (LaneMerge): newest change or cancel wins, a tie keeps
        // iCloud's; one set here and not pushed yet survives; one cancelled
        // here is not re-added. ReminderManager then makes the device match.
        let now = Date().timeIntervalSince1970
        let stamps = Self.reminderStamps
        let local = ReminderManager.shared.syncableReminders
        stamps.observe(live: Set(local.keys), now: now)
        let remoteRemoved = NSUbiquitousKeyValueStore.default.dictionary(forKey: Self.remindersRemovedKVSKey) as? [String: TimeInterval] ?? [:]
        let remoteStamps = remoteReminders.mapValues { $0.updatedAt.timeIntervalSince1970 }
        let plan = LaneMerge.plan(local: .init(live: local.mapValues { $0.updatedAt.timeIntervalSince1970 }, removed: stamps.removed),
                                  remote: .init(live: remoteStamps, removed: remoteRemoved),
                                  base: Self.loadSeen("reminders"), now: now)
        var wanted: [String: SyncableReminder] = [:]
        var applied: [String: TimeInterval] = [:]
        for (k, p) in plan {
            switch p {
            case .local: wanted[k] = local[k]
            case .remote: wanted[k] = remoteReminders[k]
            case .removed(let t): applied[k] = t
            case .gone: break
            }
        }
        ReminderManager.shared.mergeRemote(wanted)
        stamps.settle(live: Set(wanted.keys), removed: applied)
        Self.saveSeen("reminders", remoteStamps)
        debugLog("🔵 SyncManager: merged \(remoteReminders.count) remote reminders (kept=\(wanted.count) deletions=\(applied.count))")
    }

    nonisolated static func reminderRows(_ list: [[String: Any]]) -> [String: [String: Any]] {
        WatchProgressSyncMerge.byKey(list, key: { $0["key"] as? String }, stamp: reminderStamp)
    }

    nonisolated static func reminderStamp(_ row: [String: Any]) -> TimeInterval {
        row["updatedAt"] as? TimeInterval ?? 0
    }

    // MARK: - Active Pull (foreground resume)

    /// Reads ALL KVS keys and merges remote data into local state.
    /// Called every time the app enters the foreground so changes made
    /// on other devices are picked up immediately, even when no KVS
    /// `didChangeExternally` notification was delivered (common on tvOS).
    /// Timestamp of last pull, used to throttle so we don't re-merge on
    /// every scenePhase == .active (which fires frequently on tvOS).
    nonisolated(unsafe) private static var lastPullTime: TimeInterval = 0

    /// - Parameter force: bypass the 60s throttle. Automatic callers (foreground
    ///   resume) leave this false; a USER tapping "Pull from iCloud" must never
    ///   be silently ignored, which is exactly what the throttle would do right
    ///   after launch -- the button would look broken.
    /// - Parameter replace: OVERWRITE this device's state with the cloud copy
    ///   instead of merging into it. Only ever true for the explicit
    ///   "Pull from iCloud" button, which confirms with the user first
    ///   (mirrors Android's "Pull Config from Drive"). Every automatic path
    ///   (foreground resume, KVS change notification) still merges.
    /// - Parameter ignoreOwnership: Rule 4, the user chose the iCloud backup: apply even the
    ///   categories Dispatcharr Sync owns.
    func pullFromCloud(force: Bool = false, replace: Bool = false, ignoreOwnership: Bool = false) {
        guard isSyncEnabled, !isMerging, !isImporting else { return }

        // Throttle: skip if we pulled within the last 60 seconds. An explicit
        // replace is a deliberate, confirmed user action and never throttles.
        let now = ProcessInfo.processInfo.systemUptime
        guard force || replace || now - Self.lastPullTime > 60 else {
            debugLog("🔵 SyncManager.pullFromCloud: throttled (\(Int(now - Self.lastPullTime))s since last)")
            return
        }
        Self.lastPullTime = now
        debugLog("🔵 SyncManager.pullFromCloud: reading KVS (force=\(force) replace=\(replace))")

        let sKey = kvsKey
        let pKey = prefKVSKey
        let wpKey = watchProgressKVSKey
        let rKey = reminderKVSKey

        // Reads AND merges run on the main actor. KVS reads must be on the
        // main queue (this file's threading rules; the old code read inside
        // Task.detached on a utility thread, which worked only by hitting the
        // local cache and contradicted the documented invariant). The
        // [String: Any] KVS payloads are not Sendable, so they cannot cross
        // back to a detached task anyway. The merges are SwiftData-heavy, so
        // we Task.yield() between each one to let the main runloop drain
        // queued UI work (doing all four back-to-back once showed a ~1.8s
        // launch hang: channel-fetch callbacks, SwiftUI re-renders, etc.).
        // Drives the Settings > Sync progress indicator. The merges below
        // are the slow part of a pull, so the indicator is up for their
        // whole duration and clears on the last one.
        beginActivity(.pulling)
        Task { @MainActor in
            let servers   = NSUbiquitousKeyValueStore.default.array(forKey: sKey) as? [[String: Any]]
            let prefs     = NSUbiquitousKeyValueStore.default.dictionary(forKey: pKey)
            let wp        = NSUbiquitousKeyValueStore.default.array(forKey: wpKey) as? [[String: Any]]
            let reminders = NSUbiquitousKeyValueStore.default.array(forKey: rKey) as? [[String: Any]]

            guard servers != nil || prefs != nil || wp != nil || reminders != nil else {
                debugLog("🔵 SyncManager.pullFromCloud: no remote data")
                SyncManager.shared.endActivity(
                    failure: "Nothing to pull yet. iCloud has no data from your other devices."
                )
                SyncManager.shared.noteMerged("pull, iCloud had nothing")
                return
            }

            defer { SyncManager.shared.endActivity() }

            SyncManager.shared.doMerge(servers: servers, isInitial: false, replace: replace)
            await Task.yield()
            CloudSnapshotSync.shared.foldProviders()
            SyncManager.shared.doApplyPreferences(prefs: prefs, replace: replace, ignoreOwnership: ignoreOwnership)
            await Task.yield()
            SyncManager.shared.mergeRemoteWatchProgress(wp, replace: replace, ignoreOwnership: ignoreOwnership)
            await Task.yield()
            SyncManager.shared.mergeRemoteReminders(reminders, ignoreOwnership: ignoreOwnership)
            debugLog("🔵 SyncManager.pullFromCloud: \(replace ? "replace" : "merge") complete")
            SyncManager.shared.noteMerged("pull")
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
    /// v1.6.20: per-server Dispatcharr auth header shape, raw string
    /// (`""`, `"xapikey"`, `"both"`, or `"bearer"`). Unused by other
    /// server types. Synced so that once one device discovers the
    /// working shape during Test Connection, every other device on
    /// the same iCloud account inherits it without re-running
    /// discovery. Empty string = inherit the back-compat default
    /// (`.both`) on the receiving device.
    let dispatcharrAuthMode: String
    /// v1.7: per-server Dispatcharr credential type, raw string
    /// (`""` or `"api_key"` resolves to API Key mode, the legacy
    /// behaviour; `"username_password"` resolves to Direct Connect
    /// mode). Synced so a user who set up Direct Connect on one
    /// device gets the matching mode on every other device on the
    /// same Apple ID. The credentials themselves (username +
    /// password) ride along via the existing
    /// `password_<id>` Keychain entry pattern; iCloud Keychain
    /// replicates them out-of-band, with the KVS plaintext fallback
    /// added in v1.6.23 covering devices that don't have iCloud
    /// Keychain enabled.
    let dispatcharrCredentialTypeRaw: String
    /// v1.7.x: the connected Dispatcharr user's permission tier
    /// (Streamer = 0, Standard = 1, Admin = 10). Synced so a Standard
    /// account discovered on one device gates the server-side Record /
    /// DVR affordances on every device. Defaults to 10 (admin) when
    /// absent from the payload (older sender, or an admin server whose
    /// level is omitted to stay back-compat) so non-restricted servers
    /// stay recording-capable.
    let dispatcharrUserLevel: Int
    /// Per-user capability snapshot from `/api/accounts/users/me/`, synced
    /// WHOLE. `dispatcharrCustomPropertiesJSON` is the verbatim
    /// `custom_properties` object (dvr_access, vod_movies_enabled, ...),
    /// so a device receiving a playlist gates on the same facts as the
    /// device that probed it. Absent from older senders: the receiver then
    /// has no snapshot, reads every capability as unknown, and keeps the
    /// affordances enabled until its own probe runs.
    let dispatcharrIsStaff: Bool
    let dispatcharrIsSuperuser: Bool
    let dispatcharrCustomPropertiesJSON: String
    let dispatcharrPermissionsFetchedAt: Date?
    let dispatcharrCapabilitiesSchema: Int
    let dispatcharrSystemCatchupEnabled: Bool?
    /// v1.7.x: the connected Dispatcharr user's assigned Channel Profile
    /// id(s), comma-joined (`""`, `"44"`, `"44,57"`). Synced so a user
    /// whose account is locked to a "Kids" profile on one device gets the
    /// same curated channel list on every device on the same Apple ID.
    /// Defaults to "" (no profile = show all channels) when absent from
    /// the payload (older sender, or a server with no profile assigned),
    /// keeping unrestricted servers unfiltered.
    let dispatcharrChannelProfileIDs: String
    /// Task #189: the USER-CHOSEN Channel Profile (Edit Playlist picker).
    /// nil = All Channels; absent from older senders deserializes to nil.
    let dispatcharrSelectedProfileID: Int?
    /// Catch-up: per-server guide-history retention in days. Absent
    /// in payloads from older clients; deserialize defaults it to 7.
    let epgRetentionDays: Int
    /// Per-playlist DVR default destination, Fetch On Demand flag, and
    /// catch-up time offset (minutes). nil = absent from an older sender,
    /// so the receiving device keeps its own value.
    let defaultRecordingDestinationRaw: String?
    let vodEnabled: Bool?
    let catchupTimeOffsetMinutes: Int?
    /// When the sending device last changed each credential (0 = unknown),
    /// so an older copy never replaces a newer one (CredentialSyncRule).
    var passwordChangedAt: TimeInterval = 0
    var apiKeyChangedAt: TimeInterval = 0
    /// The record's change time (its own, else lastConnected or createdAt
    /// for an older build's row).
    var changedAt: TimeInterval = 0
    var stamp: TimeInterval { changedAt }
    /// Its own change time only (0 unknown), for the one-playlist winner pick.
    var knownChangedAt: TimeInterval = 0
    /// The Dispatcharr account username, when the sender knew it.
    var accountUsername: String = ""

    /// Applies the optional per-playlist fields to a local server record.
    @MainActor func applyPlaylistSettings(to server: ServerConnection) {
        if let v = defaultRecordingDestinationRaw, !v.isEmpty { server.defaultRecordingDestinationRaw = v }
        if let v = vodEnabled { server.vodEnabled = v }
        if let v = catchupTimeOffsetMinutes {
            UserDefaults.standard.set(v, forKey: CatchupSupport.timeOffsetKey(serverID: id))
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let syncManagerDidReceiveRemoteServers = Notification.Name("syncManagerDidReceiveRemoteServers")
    static let syncManagerDidApplyPreferences = Notification.Name("syncManagerDidApplyPreferences")
    static let syncManagerNeedsPush = Notification.Name("syncManagerNeedsPush")
    /// ProfileManager finished switching a playlist's profile (data swapped).
    static let aerioProfileDidSwitch = Notification.Name("aerioProfileDidSwitch")
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
    /// list listens for this and scrolls to the first row, same UX
    /// vocabulary as Apple's TV / Music apps where Menu on a long
    /// list means "take me back to the top".
    static let guideScrollToTop = Notification.Name("guideScrollToTop")
    /// #42 Part 1: a guide long-press Left. `Began` posts when the hold crosses
    /// the threshold (jump focus to the leftmost "All" pill); `Ended` posts on
    /// release. Between them the pill bar pins focus to "All" so the still-held
    /// press cannot overshoot left into the leading Guide/Search/List controls.
    static let guideLeftHoldBegan = Notification.Name("guideLeftHoldBegan")
    static let guideLeftHoldEnded = Notification.Name("guideLeftHoldEnded")
    /// Docked group sidebar (Group Selection: Sidebar Menu) closed. userInfo:
    /// `rebind` (Bool - true when the group changed, so re-resolve a fresh
    /// now-cell; false = restore the origin cell) + `returnID` (String? origin
    /// program id). EPGGuideView runs its retry-assert focus loop on receipt so
    /// Right/Back never orphan focus onto the nav tab.
    static let guideGroupSidebarDismissed = Notification.Name("guideGroupSidebarDismissed")
    /// #42: a guide long-press Right while a corner mini-player is minimized.
    /// `Began` posts when the hold crosses the threshold (close the mini);
    /// `Ended` posts on release. Between them EPGGuideView pins its timeline
    /// (gates onMoveCommand(.right)) so the still-held Right does not scroll the
    /// EPG forward after the mini closes.
    static let guideRightHoldBegan = Notification.Name("guideRightHoldBegan")
    /// A short Right press was released while the hold-Right detector was armed
    /// (mini minimized): the guide performs its deferred Right step now.
    static let guideRightPressEnded = Notification.Name("guideRightPressEnded")
    static let guideRightHoldEnded = Notification.Name("guideRightHoldEnded")
    /// Remote Control #196: mapped guide actions dispatched from the hold
    /// handlers in ChannelListView into the guide grid. `guideTimelineJump`
    /// carries userInfo["hours"] (Double, signed: negative = earlier);
    /// `guidePageStep` carries userInfo["step"] (Int, signed channel rows).
    static let guideTimelineJump = Notification.Name("guideTimelineJump")
    static let guideJumpToNow = Notification.Name("guideJumpToNow")
    static let guidePageStep = Notification.Name("guidePageStep")
    /// Sidebar mode's hold-Left (Logan 2026-08-06 ruling, Android twin):
    /// posted by ChannelListView's hold handler; EPGGuideView answers with
    /// the focused programme id via its onRequestGroupSidebar callback.
    static let guideOpenGroupSidebar = Notification.Name("guideOpenGroupSidebar")
    /// Menu while the drawer is open closes it (HomeView owns the press).
    static let guideCloseGroupSidebar = Notification.Name("guideCloseGroupSidebar")
    /// Posted by `ChannelStore.primeXMLTVFromURL` after it has
    /// finished the XMLTV parse AND written category-enriched
    /// entries into EPGCache via `GuideStore.seedEPGCache`. Any
    /// open expanded schedule panels listen for this and re-fetch
    /// their `upcomingPrograms` so the newly-landed category data
    /// drives the per-program tint gradient, without this, a
    /// schedule panel that was expanded BEFORE the XMLTV parse
    /// completed would stay visually uncolored until the user
    /// collapsed and re-opened it.
    static let epgCategoriesDidUpdate = Notification.Name("epgCategoriesDidUpdate")
    /// Posted when the tvOS single-stream player is minimized to the
    /// corner. The guide (ChannelListView / EPGGuideView) listens
    /// and programmatically moves its own `@FocusState` to the
    /// first channel row, because the tvOS focus engine does NOT
    /// release focus from a SwiftUI Button that becomes
    /// `.focusable(false)` on an ancestor's state change, the
    /// focus stays trapped in the corner unless something else
    /// explicitly claims it. This notification is that explicit
    /// claim. Body has no userInfo.
    static let forceGuideFocus = Notification.Name("forceGuideFocus")
    /// tvOS: scene left / returned to active. userInfo["active"]: Bool,
    /// ["owed"]: Bool (a background stop owes the guide a refocus).
    static let guideScenePhaseChanged = Notification.Name("guideScenePhaseChanged")

    /// Posted by `SearchView` when the user taps an EPG program search
    /// result. `MainTabView` switches to the Live TV tab,
    /// `ChannelListView` forces guide mode (and clears any group
    /// filter so the target channel is visible), and `EPGGuideView`
    /// scrolls to the program's channel + start time. The durable
    /// target (channel id + start) is stashed in UserDefaults
    /// (`guideJumpChannelID` / `guideJumpStart`) so the cold path
    /// (guide not yet mounted) can consume it on load; this
    /// notification is just the warm-path trigger. No userInfo.
    static let aerioJumpToGuideProgram = Notification.Name("aerioJumpToGuideProgram")

    /// v1.6.12 (GH #11): a Back/Menu press caught by `MainTabView`'s
    /// outer `.onExitCommand` while a single-stream player is active
    /// AND not minimized, i.e. the player is full-screen but focus
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
    /// on the first Back press after un-minimizing, exactly the
    /// regression GH #11 reported. Body has no userInfo.
    static let playerBackPress = Notification.Name("playerBackPress")
}

/// Whether this device can use iCloud for AerioTV's sync, which runs on the
/// iCloud key-value store only. `FileManager.ubiquityIdentityToken` is nil
/// whenever iCloud Drive is off, even with an account signed in and the
/// key-value store working (iPad simulator 2026-11-03: signed in, Drive Off,
/// AerioTV said "Not signed in"). So the account counts as present when the
/// token exists OR the key-value store has delivered a change from iCloud on
/// this device (remembered across launches). `synchronize()` is not used: it
/// deadlocks on real devices.
enum CloudAccount {
    static let seenKey = "icloud.kvsDeliveredOnce"
    nonisolated(unsafe) static var identityObserved = false

    static var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
            || UserDefaults.standard.bool(forKey: seenKey)
    }

    /// Called for every key-value store change from iCloud. An account
    /// change clears the memory until iCloud delivers again.
    static func noteExternalChange(reason: Int?) {
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            UserDefaults.standard.set(false, forKey: seenKey)
        } else if UserDefaults.standard.bool(forKey: seenKey) == false {
            UserDefaults.standard.set(true, forKey: seenKey)
            debugLog("[SYNC] iCloud key-value store delivered a change; account counted as present")
        }
    }
}
