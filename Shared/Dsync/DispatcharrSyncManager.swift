//  DispatcharrSyncManager.swift
//  Aerio
//
//  Dispatcharr Sync (docs/DispatcharrSyncSchema.md, shared with the Android
//  app): the third sync provider. Every category lives in the signed-in
//  Dispatcharr user's own App Data (`users/me/app-data/app.molinete.aerio/`),
//  written with that playlist's own credential. Port of the Android
//  core/sync/dsync/DispatcharrSyncManager.kt; the pure decisions are in
//  DsyncManagerRules.swift, the Apple stores in DsyncLocal.swift.
//
//  One session per (active Dispatcharr Direct Connect playlist, profile).
//  Apple has no profiles yet, so every session is the base user (token "",
//  profile key "default") and the `profiles` key is read and kept (stamps and
//  roster rows) but never applied or written. A session pulls first; a key
//  is never written before it was read in that session. Cadence and error
//  handling follow section 7: launch, foreground (5 minutes since the last
//  pull), every 15 minutes while foregrounded, 5 s after a local change,
//  and the reconnect retries after the network comes back.
//
//  iCloud (parts 3 to 5) plugs in through closures: cloudFollow (Rule 5
//  follow push), cloudConverge (Rule 5 self-heal), cloudMirrorLanes (Rule 4
//  settings mirror), and setupChoicePending (Rule 5 gate). Unset, they are
//  logged and skipped.
//
//  Logs mirror the Android lines ([DSYNC], [SYNC]; [CLOUD] where Android
//  says [DRIVE]) and carry counts only: never keys, tokens, URLs, or values.

import Foundation
import SwiftData
import Combine
import Network

@MainActor
final class DsyncSession {
    let playlistId: String
    let profileKey: String
    let token: String
    let mutex = DsyncMutex()
    var client: DispatcharrAppDataClient?

    /// Keys deferred because their id cache was not built, with the local row count waiting.
    var awaitingCache: [DsyncKey: Int] = [:]
    var sweepRetried = Set<DsyncKey>()
    /// Keys whose last build pushed with untranslated rows (stay dirty).
    var partial = Set<DsyncKey>()
    var progressDiag = Set<Int>()
    var readyAtPush: [DsyncKey: Bool] = [:]
    /// No key is written before this session's first complete pull.
    var firstPullDone = false
    /// The last list call answered (false while offline).
    var listOk = false
    /// Keys whose last send failed, or that were unsent when the session began.
    var resend = Set<DsyncKey>()
    var reconnectTask: Task<Void, Never>?
    var read = Set<DsyncKey>()
    var blocked = Set<DsyncKey>()
    var tooLarge = Set<DsyncKey>()
    var serverFull = false
    var paused = false
    var serverBytes: [String: Int64] = [:]
    /// Bucket wire name to the list `bytes` when that bucket was last fetched.
    var fetchedBytes: [String: Int64] = [:]
    /// Categories present inside the key on the server.
    var present = Set<DsyncKey>()
    var pending: [DsyncKey: Task<Void, Never>] = [:]
    var healed = Set<DsyncKey>()
    /// Keys a Settings > Sync manual push is sending.
    var manual = Set<DsyncKey>()
    var retries: [DsyncKey: Int] = [:]
    var convergeAfterWrite = Set<DsyncKey>()
    var suppressUntil: [DsyncKey: Int64] = [:]
    var lastPullAt: Int64 = 0
    /// Setup choice pull (section 10a): apply shared keys even when the stamp is "not newer".
    var forceApply = false
    var forceApplyFailed = false
    var pullComplete = false
    var bucketFailed = false
    /// Last local fingerprint per key (change detection).
    var signatures: [DsyncKey: String] = [:]
    var loops: [Task<Void, Never>] = []
    var ended = false
    /// The one re-pull after the channel list loaded (Apple only).
    var channelsRepulled = false

    init(playlistId: String, profileKey: String, token: String) {
        self.playlistId = playlistId
        self.profileKey = profileKey
        self.token = token
    }
}

@MainActor
final class DispatcharrSyncManager: ObservableObject {
    static let shared = DispatcharrSyncManager()

    /// What Settings shows on the Dispatcharr Sync row.
    struct Ui: Equatable {
        var active = false
        /// Unix milliseconds.
        var lastSyncAt: Int64 = 0
        /// "Sync data too large", "Sync storage on the server is full", "Sign in again to sync", or nil.
        var message: String? = nil
        var running = false
    }

    @Published private(set) var ui = Ui()

    /// Dispatcharr Sync on or off (Android KEY_DSYNC_ENABLED, same name).
    /// Device-local, never synced; independent of iCloud Sync.
    static let enabledKey = "dispatcharr_sync_enabled"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        evaluateTarget()
    }

    // ---- iCloud hooks (registered in part 4) ----

    /// Rule 5: queue the debounced cloud follow push for one key.
    var cloudFollow: ((DsyncKey, String) -> Void)?
    /// Rule 5 self-heal: compare the cloud copy with this pull's Dispatcharr summary.
    var cloudConverge: ((String, SetupSourceChoice.Summary, [String: String]) async -> Void)?
    /// Rule 4 mirror: the settings lanes the chosen cloud copy just applied.
    var cloudMirrorLanes: ((String) -> [String: [String: DsyncJSON]])?
    /// The VOD catalog wrote a page (the iCloud backup update retries once the sweep is quiet).
    var cloudCatalogPage: (() -> Void)?
    /// Rule 5 gate: a setup choice prompt is open (SetupSourceCoordinator).
    var setupChoicePending: () -> Bool = { false }

    private let state = DsyncStateStore.shared
    private let held = DsyncHeldStore.shared
    var deviceId: String { state.deviceId }
    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    private var session: DsyncSession?
    private var lastEnded: DsyncSession?
    private var started = false
    private var foreground = true
    private var cancellables: [AnyCancellable] = []
    private var pathMonitor: NWPathMonitor?
    private var pathSatisfied = true
    private var scanTask: Task<Void, Never>?
    private var catalogQuietTask: Task<Void, Never>?
    private var lastCatalogRecheckMs: Int64 = 0
    private var choiceHoldUntil: Int64 = 0
    private var convergeRunning = false
    private var unresolvedLogged = Set<String>()
    private var targetChanging = false

    private init() {}

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func nowS() -> Int64 { Int64(Date().timeIntervalSince1970) }

    private static func sleep(_ ms: Int64) async {
        try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }

    // MARK: - Lifecycle

    /// Called once after the SwiftData context is shared (AerioApp).
    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        nc.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleScan(swiftData: false) } }
            .store(in: &cancellables)
        nc.publisher(for: ModelContext.didSave)
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleScan(swiftData: true) } }
            .store(in: &cancellables)
        nc.publisher(for: .remindersDidChange)
            .sink { [weak self] _ in Task { @MainActor in self?.scheduleScan(swiftData: false) } }
            .store(in: &cancellables)
        ChannelStore.shared.$channels
            .sink { [weak self] _ in Task { @MainActor in self?.channelsChanged() } }
            .store(in: &cancellables)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "aerio.dsync.path"))
        pathMonitor = monitor
        evaluateTarget()
    }

    func onForeground() {
        foreground = true
        evaluateTarget()
        guard let s = session else { return }
        if Self.nowMs() - s.lastPullAt >= DsyncTiming.FOREGROUND_PULL_MS {
            Task { await self.pullAll(s, "foreground") }
        }
    }

    func onBackground() {
        foreground = false
        if let s = session { Task { await self.flush(s) } }
    }

    private static let channelKeys: [DsyncKey] = [.favorites, .recents, .reminders, .collections]

    /// The channel list arrives after the session's first pull on Apple (Android keeps a
    /// channel snapshot on disk): channel keys that could not apply then are pulled once more.
    private func channelsChanged() {
        evaluateTarget()
        guard let s = session, s.firstPullDone, !s.channelsRepulled,
              !DsyncLocal.channelMap(s.playlistId).toInt.isEmpty else { return }
        let waiting = Self.channelKeys.filter { enabled($0, s) && !s.read.contains($0) }
        guard !waiting.isEmpty else { return }
        s.channelsRepulled = true
        s.fetchedBytes.removeAll()
        debugLog("[DSYNC] channel list loaded; pulling \(waiting.count) waiting channel keys")
        Task { await self.pullAll(s, "channels") }
    }

    private func pathChanged(_ ok: Bool) {
        let was = pathSatisfied
        pathSatisfied = ok
        if ok && !was, let s = session { reconnect(s) }
    }

    /// The network came back: retry the pull at 2 s, 5 s, 15 s, then every 60 s until the list answers.
    private func reconnect(_ s: DsyncSession) {
        s.reconnectTask?.cancel()
        s.reconnectTask = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                await Self.sleep(DsyncTiming.reconnect(i))
                guard let self, !Task.isCancelled, self.session === s else { return }
                await self.pullAll(s, "reconnect")
                if s.listOk { return }
                i += 1
                debugLog("[DSYNC] reconnect pull failed; retry \(i + 1)")
            }
        }
    }

    // MARK: - Session

    private func targetPlaylist() -> String? {
        guard isEnabled, let s = DsyncLocal.activeDispatcharrPlaylist() else { return nil }
        return s.id.uuidString
    }

    /// Starts, ends, or switches the session when the enable flag or the active playlist changed.
    private func evaluateTarget() {
        guard started, !targetChanging else { return }
        let t = targetPlaylist()
        if t == session?.playlistId { return }
        targetChanging = true
        Task {
            defer { self.targetChanging = false }
            if let old = self.session {
                // Send what the old session queued while it is still the live one.
                debugLog("[DSYNC] session end user=\(old.profileKey.prefix(8)) (change)")
                await self.flush(old)
                self.session = nil
                self.endSession(old)
            }
            guard let t else {
                self.ui = Ui()
                return
            }
            await self.runSession(t, trigger: "launch")
            // A change while this one started is picked up now.
            if self.targetPlaylist() != self.session?.playlistId { self.targetChanging = false; self.evaluateTarget() }
        }
    }

    private func endSession(_ s: DsyncSession) {
        s.ended = true
        for t in s.pending.values { t.cancel() }
        s.pending.removeAll()
        for t in s.loops { t.cancel() }
        s.reconnectTask?.cancel()
        lastEnded = s
        for key in DsyncKey.allCases { s.signatures[key] = DsyncLocal.signature(key, s.playlistId) }
    }

    private func runSession(_ playlistId: String, trigger: String) async {
        let s = DsyncSession(playlistId: playlistId, profileKey: "default", token: "")
        session = s
        let server = DsyncLocal.server(playlistId)
        s.client = server.flatMap(DsyncLocal.client)
        ui = Ui(active: true, lastSyncAt: state.long(k("last", s)))
        debugLog("[DSYNC] session start playlist=\(playlistId.prefix(8)) user=\(server?.username.isEmpty == false ? server!.username : "?") userId=?")
        // Change detection starts from the state at session start (Android drop(1)).
        for key in DsyncKey.allCases { s.signatures[key] = DsyncLocal.signature(key, playlistId) }
        stampRecents(s)
        await pullAll(s, trigger)
        s.loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await Self.sleep(DsyncTiming.PERIODIC_PULL_MS)
                guard let self, !Task.isCancelled, self.session === s else { return }
                if self.foreground { await self.pullAll(s, "periodic") }
            }
        })
        // Deferred keys go out as soon as their id cache is built.
        s.loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await Self.sleep(DsyncTiming.CACHE_POLL_MS)
                guard let self, !Task.isCancelled, self.session === s else { return }
                if s.awaitingCache.isEmpty { continue }
                for key in Array(s.awaitingCache.keys) {
                    guard await self.cacheReady(s, key) else { continue }
                    if self.isForced(s, key) { self.retryForced(s, key, "catalog") } else { self.schedule(s, key, 0) }
                }
            }
        })
    }

    /// Onboarding Turn On: wait (bounded) until the session has finished its first complete pull.
    func awaitFirstPull(timeoutMs: Int64 = DsyncTiming.FIRST_PULL_WAIT_MS) async -> Bool {
        let end = Self.nowMs() + timeoutMs
        while Self.nowMs() < end {
            if session?.firstPullDone == true { return true }
            await Self.sleep(200)
        }
        return session?.firstPullDone == true
    }

    /// Settings > Sync Now: pull, then flush anything waiting.
    func syncNow() {
        guard let s = session else { return }
        Task {
            s.paused = false
            await self.pullAll(s, "manual")
            await self.flush(s)
        }
    }

    // MARK: - VOD catalog hook

    /// VODCatalogStore wrote a page: deferred VOD keys re-check (at most every
    /// 3 s), and a forced key retries once the sweep has been quiet for 3 s.
    func noteCatalogPageWritten() {
        cloudCatalogPage?()
        guard let s = session, !s.awaitingCache.isEmpty else { return }
        let now = Self.nowMs()
        if now - lastCatalogRecheckMs >= DsyncReadiness.PAGE_RECHECK_MS {
            lastCatalogRecheckMs = now
            Task {
                for key in Array(s.awaitingCache.keys) where !s.sweepRetried.contains(key) {
                    guard let misses = self.probeMovieMisses(s, key) else { continue }
                    if DsyncReadiness.retryDuringSweep(key, cacheReady: await self.cacheReady(s, key), probeMisses: misses) {
                        s.sweepRetried.insert(key)
                        self.schedule(s, key, 0)
                    }
                }
            }
        }
        catalogQuietTask?.cancel()
        catalogQuietTask = Task { [weak self] in
            await Self.sleep(DsyncReadiness.PAGE_RECHECK_MS)
            guard let self, !Task.isCancelled, self.session === s else { return }
            for key in Array(s.awaitingCache.keys) where self.isForced(s, key) {
                self.retryForced(s, key, "catalog", ready: await self.cacheReady(s, key))
            }
        }
    }

    // MARK: - Local change detection

    private func scheduleScan(swiftData: Bool) {
        evaluateTarget()
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await Self.sleep(500)
            guard let self, !Task.isCancelled else { return }
            self.scan(swiftData: swiftData)
        }
    }

    private static let swiftDataKeys: Set<DsyncKey> = [.progress, .watchlist]

    private func scan(swiftData: Bool) {
        if let s = session {
            for key in DsyncKey.allCases where key != .profiles {
                if Self.swiftDataKeys.contains(key) != swiftData { continue }
                let sig = DsyncLocal.signature(key, s.playlistId)
                guard let old = s.signatures[key] else { s.signatures[key] = sig; continue }
                if old == sig { continue }
                s.signatures[key] = sig
                if key == .recents { stampRecents(s) }
                onLocalChange(s, key)
            }
            return
        }
        // Between sessions: mark the change on the last session's persisted keys so the next one sends it.
        guard let old = lastEnded else { return }
        for key in DsyncKey.allCases where key != .profiles {
            if Self.swiftDataKeys.contains(key) != swiftData { continue }
            let sig = DsyncLocal.signature(key, old.playlistId)
            guard let prev = old.signatures[key], prev != sig else { continue }
            old.signatures[key] = sig
            if !isDirty(old, key) { debugLog("[DSYNC] \(key.suffix) dirty; no session (kept for the next one)") }
            setDirty(old, key, true)
        }
    }

    // MARK: - Rule 4: setup source choice

    private func forceKey(_ playlistId: String, _ key: DsyncKey) -> String { "force|\(playlistId)|\(key.suffix)" }

    private func isBase(_ s: DsyncSession) -> Bool { s.token.isEmpty }

    func isForced(_ s: DsyncSession, _ key: DsyncKey) -> Bool {
        isBase(s) && DsyncCoexistence.FORCE_KEYS.contains(key) && state.bool(forceKey(s.playlistId, key))
    }

    private func clearForced(_ s: DsyncSession, _ key: DsyncKey) { state.remove(forceKey(s.playlistId, key)) }

    /// The user chose the cloud copy: every shared key of [playlistId] goes up whole from this device.
    func requestForceReplace(_ playlistId: String, keys: [DsyncKey] = DsyncCoexistence.FORCE_KEYS) {
        let arm = keys.filter { DsyncCoexistence.FORCE_KEYS.contains($0) }
        guard !arm.isEmpty else { return }
        for k in arm { state.set(forceKey(playlistId, k), true) }
        debugLog("[DSYNC] force replace armed for playlist=\(playlistId.prefix(8)) keys=\(arm.count) (user chose iCloud)")
        guard let s = session, s.playlistId == playlistId, isBase(s) else { return }
        for k in arm { setDirty(s, k, true) }
        if s.firstPullDone && !choiceHeld() { for k in arm where s.read.contains(k) { schedule(s, k, 0) } }
    }

    func holdForChoice() {
        choiceHoldUntil = Self.nowMs() + DsyncTiming.CHOICE_HOLD_MS
        debugLog("[DSYNC] shared keys held while the iCloud backup applies")
    }

    func releaseChoiceHold() {
        guard choiceHoldUntil != 0 else { return }
        choiceHoldUntil = 0
        debugLog("[DSYNC] shared key hold released")
        guard let s = session, s.firstPullDone else { return }
        for k in DsyncCoexistence.FORCE_KEYS where s.read.contains(k) && isDirty(s, k) { schedule(s, k, 0) }
    }

    private func choiceHeld() -> Bool { DsyncCoexistence.choiceHeld(until: choiceHoldUntil, now: Self.nowMs()) }

    func cancelForceReplace(_ playlistId: String, keys: [DsyncKey]) {
        for k in keys { state.remove(forceKey(playlistId, k)) }
    }

    private func retryForced(_ s: DsyncSession, _ key: DsyncKey, _ why: String, ready: Bool = true) {
        guard DsyncCoexistence.forcedRetryDue(armed: isForced(s, key), awaiting: s.awaitingCache[key] != nil, cacheReady: ready) else { return }
        if s.pending[key] != nil { return }
        debugLog("[DSYNC] force push \(key.suffix) retry (\(why)) rows=\(s.awaitingCache[key] ?? 0)")
        schedule(s, key, 0)
    }

    /// Read-only probe: the base user's App Data for [playlistId], summarized per shared category.
    /// Nil when the server could not be read; an absent key reads as an empty summary.
    func serverSummary(_ playlistId: String) async -> SetupSourceChoice.Summary? {
        guard let server = DsyncLocal.server(playlistId), let c = DsyncLocal.client(server) else { return nil }
        guard let r = await c.appDataGet(DsyncBucket.main.wire) else { return nil }
        if r.status == 404 { return .EMPTY }
        guard r.ok else {
            debugLog("[DSYNC] setup probe status=\(r.status)")
            return nil
        }
        guard let root = r.body.flatMap(DsyncJSONParser.parse)?.asObject, let bucket = DsyncV2.decode(root).bucket else { return .EMPTY }
        let out = await deviceSummary(server, bucket)
        let line = out.categories.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rows)" }.joined(separator: ", ")
        debugLog("[DSYNC] setup probe \(line.isEmpty ? "empty" : line)")
        return out
    }

    /// What the cloud fresh-device order needs: the shared keys this session's pull read, and the
    /// server copy as last fetched. Nil with no session; read is nil before the first complete pull.
    func cloudOrderState() async -> (read: Set<String>?, server: SetupSourceChoice.Summary)? {
        guard let s = session, isBase(s) else { return nil }
        guard s.firstPullDone else { return (nil, .EMPTY) }
        let read = Set(s.read.filter { DsyncCoexistence.FORCE_KEYS.contains($0) }.map(\.suffix))
        guard let b = bucketRaw(s, .main).flatMap({ DsyncV2.decode($0).bucket }), let server = DsyncLocal.server(s.playlistId) else {
            return (read, .EMPTY)
        }
        return (read, await deviceSummary(server, b))
    }

    private func serverDataOf(_ s: DsyncSession, _ b: DsyncBucket, _ key: DsyncKey) -> DsyncObject? {
        guard let bucket = bucketRaw(s, b).flatMap({ DsyncV2.decode($0).bucket }) else { return nil }
        return DsyncV2.category(bucket, key)?.envelope?.data
    }

    /// The representable filter for the setup probe and converge (section 10a).
    private func representable(_ server: ServerConnection, _ bucket: DsyncV2.Bucket) async -> (String, Int) -> Bool {
        func data(_ k: DsyncKey) -> DsyncObject? { DsyncV2.category(bucket, k)?.envelope?.data }
        let prog = data(.progress).flatMap { DsyncPayloads.decodeProgress($0) } ?? []
        let marks = [DsyncKey.watchlist, .hiddenTitles].flatMap { k in data(k).flatMap { DsyncPayloads.decodeVodMarks($0) } ?? [] }
        let movieIds = Array(Set(prog.filter { $0.type == "m" }.map(\.vodId) + marks.filter { $0.type == "m" }.map(\.vodId)))
        let movies = Set(await DsyncLocal.catalog(server, kind: .movie, ids: movieIds).keys)
        let pid = server.id.uuidString
        let localEpisodes = Set(DsyncLocal.progressRows(pid).filter { $0.vodType == "episode" }.compactMap { Int($0.vodID) })
        let episodes = Set(prog.filter { $0.type == "e" && (localEpisodes.contains($0.vodId) || $0.seriesId != nil) }.map(\.vodId))
        let h = held.items(pid)
        let cloud = held.cloudItems(pid)
        let m = DsyncLocal.channelMap(pid)
        let channels: Set<Int>? = m.toInt.isEmpty ? nil : Set(m.toInt.values)
        return { t, id in DsyncHeld.representable(t, id, movies: movies, episodes: episodes, held: h, cloud: cloud, channels: channels) }
    }

    /// Summary of the Dispatcharr copy restricted to representable rows, with the exclusion lines.
    private func deviceSummary(_ server: ServerConnection, _ bucket: DsyncV2.Bucket) async -> SetupSourceChoice.Summary {
        let scopes = DsyncLocal.scopes()
        var gone: [String: Int] = [:]
        let keep = await representable(server, bucket)
        let out = DsyncCoexistence.summarize(bucket, scopes: scopes, keep: keep, excluded: &gone)
        for (n, c) in gone.sorted(by: { $0.key < $1.key }) where out.categories[n] != nil { debugLog(DsyncHeld.excludeLine(n, rows: c)) }
        return out
    }

    func noteCloudItems(_ playlistId: String, _ items: Set<String>) { held.noteCloudItems(playlistId, items) }

    func heldProgress(_ playlistId: String) -> [ProgressRow] { held.progress(playlistId) }

    /// The Dispatcharr rows the cloud progress snapshot must carry: held rows plus the server copy's rows.
    func cloudProgressRows() -> (String?, [ProgressRow]) {
        guard let s = session, isBase(s) else { return (nil, []) }
        let h = held.progress(s.playlistId)
        if isForced(s, .progress) || !enabled(.progress, s) { return (s.playlistId, h) }
        let server = serverDataOf(s, .main, .progress).flatMap { DsyncPayloads.decodeProgress($0) } ?? []
        return (s.playlistId, DsyncHeld.merge(h, server))
    }

    /// Saved reverse id: on Apple the local id is the canonical id.
    func cachedUuid(_ type: String, _ id: Int) -> String? { type == "e" || type == "m" ? String(id) : nil }

    /// Pull before replace: true only when the list and the bucket were read and every forced apply ran.
    func pullForChoice() async -> Bool { await forcedPull("setup choice") }

    private func forcedPull(_ reason: String) async -> Bool {
        guard let s = session, isBase(s) else { return false }
        s.paused = false
        s.forceApply = true
        s.forceApplyFailed = false
        await pullAll(s, reason)
        s.forceApply = false
        let ok = s.listOk && s.pullComplete && !s.forceApplyFailed
        debugLog("[DSYNC] \(reason) pull ok=\(ok)")
        return ok
    }

    /// Settings > Sync "Push to Dispatcharr": a forced replace of every enabled shared key, sent now.
    func manualPush() async -> Bool {
        guard let s = session, isBase(s) else { return false }
        s.paused = false
        if !s.firstPullDone { await pullAll(s, "manual push") }
        guard s.firstPullDone else { return false }
        let keys = DsyncManual.keys(DsyncLocal.scopes()).filter { enabled($0, s) }
        if keys.isEmpty { return true }
        for k in keys { state.set(forceKey(s.playlistId, k), true) }
        for k in keys { setDirty(s, k, true) }
        for k in keys { s.pending.removeValue(forKey: k)?.cancel() }
        s.manual.formUnion(keys)
        for k in keys { await write(s, k) }
        s.manual.subtract(keys)
        let failed = keys.filter { isForced(s, $0) }
        debugLog("[DSYNC] manual push done keys=\(keys.count) failed=\(failed.count)")
        return failed.isEmpty
    }

    /// Settings > Sync "Pull from Dispatcharr": the setup-choice pull; applied keys queue the cloud follow.
    func manualPull() async -> Bool {
        guard let s = session, isBase(s) else { return false }
        guard await forcedPull("manual") else { return false }
        for key in DsyncManual.keys(DsyncLocal.scopes()) where enabled(key, s) {
            let rows = serverDataOf(s, DsyncBucket.of(key), key).map { DsyncCoexistence.rowCount(key, $0) } ?? 0
            debugLog("[DSYNC] manual pull \(key.suffix) rows=\(rows)")
            cloudFollowFor(s, key, "manual pull")
        }
        await flush(s)
        return true
    }

    /// Settings > Sync "Push to both": the Dispatcharr forced push, then the cloud replace.
    func manualPushToBoth(replaceCloud: () async -> Void) async -> Bool {
        debugLog("[SYNC] manual push to both")
        guard await manualPush() else { return false }
        await replaceCloud()
        return true
    }

    /// Setup-choice ordering: wait (bounded) until the held progress rows can be written locally.
    func awaitProgressLocal(timeoutMs: Int64 = DsyncTiming.PROGRESS_LOCAL_WAIT_MS) async {
        guard let s = session, isBase(s), let server = DsyncLocal.server(s.playlistId) else { return }
        if held.progress(s.playlistId).isEmpty { return }
        let end = Self.nowMs() + timeoutMs
        var settled = false
        while Self.nowMs() < end {
            if DsyncHeld.progressSettled(heldRows: held.progress(s.playlistId).count, catalogReady: await DsyncLocal.moviesReady(server)) {
                settled = true
                break
            }
            await Self.sleep(500)
        }
        if !settled {
            debugLog("[DSYNC] progress held=\(held.progress(s.playlistId).count) catalog not ready; replace goes ahead with placeholders")
            return
        }
        let before = held.progress(s.playlistId)
        if before.isEmpty { return }
        var written = 0
        let left = await DsyncLocal.applyProgress(server, before, written: &written)
        if left.count != before.count { await holdProgress(s, server, left, "retry") }
        debugLog("[DSYNC] progress before replace resolved=\(written) held=\(left.count)")
    }

    /// A cloud apply carried placeholder rows: hold them (replace when the user chose iCloud).
    func holdFromCloud(_ playlistId: String, _ rows: [ProgressRow], replace: Bool) {
        held.setProgress(playlistId, replace ? rows : DsyncHeld.merge(held.progress(playlistId), rows))
    }

    // MARK: - Rule 5: convergence with iCloud

    private var cloudOn: Bool {
        let ud = UserDefaults.standard
        return ud.object(forKey: "iCloudSyncEnabled") == nil ? iCloudSyncEnabledDefault : ud.bool(forKey: "iCloudSyncEnabled")
    }

    /// iCloud follows Dispatcharr Sync: a shared key applied from a pull, or changed here, queues the cloud push.
    private func cloudFollowFor(_ s: DsyncSession, _ key: DsyncKey, _ why: String) {
        guard isBase(s), let cat = key.category, DsyncCoexistence.SHARED_CATEGORIES.contains(cat) else { return }
        guard enabled(key, s), cloudOn else { return }
        debugLog("[SYNC] cloud follow \(key.suffix) (\(why))")
        cloudFollow?(key, why)
    }

    /// Rule 5 self-heal, once per complete pull, only once the setup choice is settled.
    private func maybeConverge(_ s: DsyncSession) {
        let anyForced = DsyncCoexistence.FORCE_KEYS.contains { isForced(s, $0) }
        guard DsyncPushRules.convergeAllowed(isBase: isBase(s), choiceHeld: choiceHeld(), running: convergeRunning,
                                             anyForced: anyForced, choicePending: setupChoicePending()) else { return }
        guard let raw = bucketRaw(s, .main), let bucket = DsyncV2.decode(raw).bucket else { return }
        var skip: [String: String] = [:]
        for k in DsyncCoexistence.FORCE_KEYS {
            if let r = DsyncPushRules.convergeSkip(forced: isForced(s, k), awaiting: s.awaitingCache[k] != nil,
                                                   pending: s.pending[k] != nil, read: s.read.contains(k),
                                                   dirty: isDirty(s, k), partial: s.partial.contains(k)) { skip[k.suffix] = r }
        }
        // A dirty key with no write queued: queue it; an equal key ends as status=unchanged.
        for k in DsyncCoexistence.FORCE_KEYS where skip[k.suffix] == "dirty" && s.pending[k] == nil {
            s.convergeAfterWrite.insert(k)
            schedule(s, k, 0)
        }
        guard let converge = cloudConverge else { return }
        convergeRunning = true
        Task {
            defer { self.convergeRunning = false }
            guard let server = DsyncLocal.server(s.playlistId) else { return }
            let x = await self.deviceSummary(server, bucket)
            await converge(s.playlistId, x, skip)
        }
    }

    /// Coexistence Rule 1: true when iCloud must not apply [category], because Dispatcharr Sync owns it.
    func ownsCategory(_ category: DsyncCategory) -> Bool {
        guard DsyncCoexistence.SHARED_CATEGORIES.contains(category) else { return false }
        let active = DsyncLocal.activeDispatcharrPlaylist()
        let done = isEnabled && active != nil ? state.bool("fpdone|\(active!.id.uuidString)|default") : false
        return DsyncCoexistence.owns(category, activeIsDispatcharr: active != nil, dispatcharrSyncOn: isEnabled, firstPullDoneForUser: done)
    }

    // MARK: - Per-key enablement

    /// Per-item choices: data keys follow their item's on/off; settings is gated per name.
    /// Profiles: no Profiles feature on Apple yet, so this device never writes the key.
    private func enabled(_ key: DsyncKey, _ s: DsyncSession) -> Bool {
        if key == .settings { return true }
        if key == .profiles { return false }
        guard let item = DsyncItemCatalog.itemForDsync(key.suffix) else { return true }
        return DsyncLocal.scopes()[item.id] != .off
    }

    /// Pull side: profiles is read (stamps and roster kept) though never written.
    private func pulled(_ key: DsyncKey, _ s: DsyncSession) -> Bool { key == .profiles || enabled(key, s) }

    // MARK: - Persisted per (playlist, profile, key) state

    private func k(_ name: String, _ s: DsyncSession, _ key: DsyncKey? = nil) -> String {
        "\(name)|\(s.playlistId)|\(s.profileKey)" + (key.map { "|\($0.suffix)" } ?? "")
    }

    private func rawOf(_ s: DsyncSession, _ key: DsyncKey) -> DsyncObject? { state.object(k("raw", s, key)) }
    private func lastDataOf(_ s: DsyncSession, _ key: DsyncKey) -> DsyncObject? { state.object(k("data", s, key)) }

    private func saveAfter(_ s: DsyncSession, _ key: DsyncKey, raw: DsyncObject, at: Int64, dev: String, data: DsyncObject) {
        state.setObject(k("raw", s, key), raw)
        state.set(k("at", s, key), at)
        state.set(k("dev", s, key), dev)
        state.setObject(k("data", s, key), data)
    }

    private func setDirty(_ s: DsyncSession, _ key: DsyncKey, _ dirty: Bool) {
        state.set(k("dirty", s, key), dirty)
        if dirty { state.set(k("dirtyAt", s, key), Self.nowS()) }
    }

    private func dirtyAt(_ s: DsyncSession, _ key: DsyncKey) -> Int64 { state.long(k("dirtyAt", s, key)) }
    private func isDirty(_ s: DsyncSession, _ key: DsyncKey) -> Bool { state.bool(k("dirty", s, key)) }

    private func stampLast(_ s: DsyncSession) {
        let now = Self.nowMs()
        state.set(k("last", s), now)
        ui.lastSyncAt = now
    }

    private func refreshMessage(_ s: DsyncSession) {
        let msg: String? = s.paused ? "Sign in again to sync"
            : !s.tooLarge.isEmpty ? "Sync data too large"
            : s.serverFull ? "Sync storage on the server is full" : nil
        if session === s, ui.message != msg { ui.message = msg }
    }

    private func bucketRaw(_ s: DsyncSession, _ b: DsyncBucket) -> DsyncObject? { state.object(k("braw", s) + "|" + b.rawValue) }
    private func saveBucketRaw(_ s: DsyncSession, _ b: DsyncBucket, _ raw: DsyncObject) {
        state.setObject(k("braw", s) + "|" + b.rawValue, raw)
        foldProviders(s, raw)
    }

    // ---- syncProviders record (schema section 10b) ----

    /// The base user only: a sub-profile's key never feeds the owner's record.
    private func foldProviders(_ s: DsyncSession, _ raw: DsyncObject) {
        guard isBase(s) else { return }
        let rec = SyncProvidersRules.fromJson(raw[DsyncV2.CATEGORIES]?.asObject?[SyncProvidersRules.DSYNC_CATEGORY]?.asObject?["data"])
        SyncProvidersStore.fold(SyncProvidersStore.dsyncScope(s.playlistId), rec)
    }

    /// Every PUT by the base user re-emits the union record; other users round-trip theirs untouched.
    private func withProviders(_ s: DsyncSession, _ value: DsyncObject) -> DsyncObject {
        guard isBase(s), let rec = SyncProvidersStore.forPush(SyncProvidersStore.dsyncScope(s.playlistId), dispatcharrOn: true,
                                                                icloudOn: SyncManager.shared.isSyncEnabled, deviceId: deviceId) else { return value }
        var cats = value[DsyncV2.CATEGORIES]?.asObject ?? DsyncObject()
        let name = SyncProvidersRules.DSYNC_CATEGORY
        cats[name] = .object(DsyncV2.encodeCategory(cats[name]?.asObject, deviceId: rec.deviceId.isEmpty ? deviceId : rec.deviceId,
                                                    updatedAt: rec.updatedAt / 1000, data: SyncProvidersRules.toJson(rec)))
        var out = value
        out[DsyncV2.CATEGORIES] = .object(cats)
        return out
    }

    /// The `profiles` roster rows as last read (kept for the Profiles feature, a later batch).
    func profileRoster() -> [ProfileRow] {
        guard let s = session else { return [] }
        return rawOf(s, .profiles)?["data"]?.asObject.flatMap { DsyncPayloads.decodeProfiles($0) } ?? []
    }

    // MARK: - Pull (section 7.1, 7.2)

    private func pullAll(_ s: DsyncSession, _ reason: String) async {
        await s.mutex.lock()
        defer { s.mutex.unlock() }
        guard session === s else { return }
        if choiceHeld() {
            debugLog("[DSYNC] pull (\(reason)) held while the iCloud backup applies")
            return
        }
        guard let c = s.client else { return }
        s.listOk = false
        s.pullComplete = false
        s.bucketFailed = false
        ui.running = true
        defer {
            ui.running = false
            refreshMessage(s)
        }
        switch await c.list(reason: reason) {
        case .failed, .rejected: return
        case .paused:
            s.paused = true
            refreshMessage(s)
            return
        case .ok(let sizes):
            s.paused = false
            s.listOk = true
            s.serverBytes = sizes
        }
        guard await migrateV1(s, c) else { return }
        for b in DsyncBucket.allCases {
            guard session === s else { return }
            let keys = b.keys.filter { pulled($0, s) }
            if !keys.isEmpty { await pullBucket(s, c, b, keys) }
        }
        s.lastPullAt = Self.nowMs()
        s.pullComplete = !s.bucketFailed
        s.firstPullDone = true
        state.set(k("fpdone", s), true)
        stampLast(s)
        debugLog("[DSYNC] pull done (\(reason)) read=\(s.read.count) server=\(s.serverBytes.count)")
        // A category absent on the server, or changed here before this session could write it, goes up now.
        for key in s.read where key != .profiles {
            let dirty = isDirty(s, key)
            if dirty && DsyncPullRules.resendReason(reason) { s.resend.insert(key) }
            if isForced(s, key) && s.awaitingCache[key] != nil { retryForced(s, key, "cycle") }
            else if dirty || !s.present.contains(key) { schedule(s, key, 0) }
        }
        maybeConverge(s)
    }

    private func pullBucket(_ s: DsyncSession, _ c: DispatcharrAppDataClient, _ b: DsyncBucket, _ keys: [DsyncKey]) async {
        guard s.serverBytes[b.wire] != nil else {
            for key in keys { s.present.remove(key); s.read.insert(key) }
            return
        }
        let listed = s.serverBytes[b.wire]
        if !s.forceApply && DsyncPullRules.shouldSkipBucketGet(lastPullAt: s.lastPullAt, now: Self.nowMs(),
                                                               fetchedBytes: s.fetchedBytes[b.wire], listedBytes: listed) {
            return
        }
        switch await c.fetchBucket(b) {
        case .absent: for key in keys { s.present.remove(key); s.read.insert(key) }
        case .failed, .malformed: s.bucketFailed = true
        case .tooNew:
            s.bucketFailed = true
            s.blocked.formUnion(keys)
        case .got(let bucket, let bytes):
            if let listed { s.fetchedBytes[b.wire] = listed }
            saveBucketRaw(s, b, bucket.raw)
            for key in keys {
                switch DsyncV2.category(bucket, key) {
                case nil:
                    s.present.remove(key)
                    s.read.insert(key)
                case .ok(let env)?:
                    s.present.insert(key)
                    await processCategory(s, key, env, bytes)
                default:
                    debugLog("[DSYNC] malformed \(b.wire) category \(key.suffix)")
                }
            }
        }
    }

    /// Migration to schema v3 (one key). False = the server could not be reached.
    private func migrateV1(_ s: DsyncSession, _ c: DispatcharrAppDataClient) async -> Bool {
        let main = DsyncBucket.main.wire
        let others = s.serverBytes.keys.filter { $0.hasPrefix(main + ".") }.sorted()
        var mainRaw: DsyncObject?
        var mainIsOld = false
        if s.serverBytes[main] != nil && !state.bool(k("v3seen", s)) {
            guard let r = await c.appDataGet(main), r.status < 500 else { return false }
            let got = r.ok ? r.body.flatMap(DsyncJSONParser.parse)?.asObject : nil
            mainRaw = got
            mainIsOld = got != nil && DsyncV2.decode(got!).bucket == nil
            if !mainIsOld { state.set(k("v3seen", s), true) }
        }
        if others.isEmpty && !mainIsOld { return true }
        if mainRaw == nil && s.serverBytes[main] != nil {
            guard let r = await c.appDataGet(main), r.status < 500 else { return false }
            mainRaw = r.ok ? r.body.flatMap(DsyncJSONParser.parse)?.asObject : nil
        }
        var v1: [(DsyncKey, DsyncEnvelope)] = []
        var v2: [DsyncV2.Bucket] = []
        var v3: DsyncObject?
        if let raw = mainRaw, let b = DsyncV2.decode(raw, min: DsyncV2.MIN_SUBOBJECT_SCHEMA).bucket {
            if b.schemaVersion >= DsyncV2.SCHEMA { v3 = raw } else { v2.append(b) }
        }
        for name in others {
            guard let r = await c.appDataGet(name), r.status < 500 else { return false }
            guard r.ok, let raw = r.body.flatMap(DsyncJSONParser.parse)?.asObject else { continue }
            if let k1 = DsyncKey.fromWire(name), let e = DsyncEnvelopeCodec.decode(raw, knownVersion: 1).envelope {
                v1.append((k1, e))
                continue
            }
            if let b = DsyncV2.decode(raw, min: DsyncV2.MIN_SUBOBJECT_SCHEMA).bucket { v2.append(b) }
        }
        if let value = DsyncV2.migrate(v1: v1, v2: v2, v3: v3, deviceId: deviceId, appVersion: appVersion, now: Self.nowS()) {
            var body = value
            var step = 0
            while true {
                let r = await c.appDataPut(main, body: DsyncJSONEncoder.encode(body))
                debugLog("[DSYNC] migration put \(main) bytes=\(DsyncEnvelopeCodec.byteSize(body)) status=\(r.map { String($0.status) } ?? "network")")
                guard let r, r.status < 500 else { return false }
                if r.ok { break }
                if r.status != 413 { return true }
                guard let next = DispatcharrAppDataClient.nextTrim(body, from: step) else {
                    debugLog("[DSYNC] migration: still too large after every trim; old keys kept")
                    return true
                }
                body = next.0
                step = next.1
            }
            s.serverBytes[main] = Int64(DsyncEnvelopeCodec.byteSize(body))
        }
        var removed = 0
        for name in others {
            if let r = await c.appDataDelete(name), r.ok || r.status == 404 {
                removed += 1
                s.serverBytes.removeValue(forKey: name)
            }
        }
        state.set(k("v3seen", s), true)
        debugLog("[DSYNC] migrated to the single key (\(removed) keys removed)")
        return true
    }

    private enum ApplyResult { case applied, malformed, notReady, failed }

    /// One pulled category (v1 rules per category, section 6).
    private func processCategory(_ s: DsyncSession, _ key: DsyncKey, _ env: DsyncEnvelope, _ bytes: Int) async {
        let raw = env.raw
        if key == .profiles {
            // No Profiles feature on Apple yet: keep the stamps and the roster rows, apply nothing.
            saveAfter(s, key, raw: raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
            debugLog("[DSYNC] pull profiles bytes=\(bytes) rows=\(DsyncPayloads.decodeProfiles(env.data)?.count ?? -1) kept (not applied on this device)")
            s.read.insert(key)
            return
        }
        let localAt = state.long(k("at", s, key))
        let action = DsyncPullRules.decide(key, forced: isForced(s, key),
                                           consumedBefore: localAt > 0 || state.contains(k("at", s, key)), data: env.data,
                                           localAt: localAt, localDevice: state.string(k("dev", s, key)) ?? "",
                                           remoteAt: env.updatedAt, remoteDevice: env.deviceId,
                                           dirty: isDirty(s, key), dirtyAt: dirtyAt(s, key), forceApply: s.forceApply)
        switch action {
        case .forcedSkip:
            saveAfter(s, key, raw: raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
            setDirty(s, key, true)
            debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) not applied: replacing with this device's copy (user chose iCloud)")
        case .seedFromLocal:
            saveAfter(s, key, raw: raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
            setDirty(s, key, true)
            debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) empty on server, first pull: seeding from local")
        case .merge:
            guard let merged = mergedEnvelope(s, key, env) else { return }
            let applied = await apply(s, key, merged)
            guard applied == .applied else {
                if applied == .malformed { debugLog("[DSYNC] malformed category \(key.suffix)") }
                return
            }
            s.suppressUntil[key] = Self.nowMs() + DsyncTiming.SUPPRESS_MS
            saveAfter(s, key, raw: raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
            cloudFollowFor(s, key, "pull")
            setDirty(s, key, true)
            debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) merged with local change")
        case .choiceApply:
            let applied = await apply(s, key, env)
            guard applied == .applied else {
                s.forceApplyFailed = true
                debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) setup choice apply did not run")
                return
            }
            s.suppressUntil[key] = Self.nowMs() + DsyncTiming.SUPPRESS_MS
            saveAfter(s, key, raw: raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
            debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) applied (setup choice, stamp not newer)")
        case .keepLocal:
            state.setObject(k("raw", s, key), raw)
            debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) kept local (local change newer)")
        case .apply:
            if isDirty(s, key) { setDirty(s, key, false) }
            switch await apply(s, key, env) {
            case .applied:
                s.suppressUntil[key] = Self.nowMs() + DsyncTiming.SUPPRESS_MS
                saveAfter(s, key, raw: raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
                debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) applied")
                cloudFollowFor(s, key, "pull")
            case .malformed:
                debugLog("[DSYNC] malformed category \(key.suffix)")
                return
            case .notReady, .failed:
                // The channel list is not loaded yet: do not count as read.
                if s.forceApply { s.forceApplyFailed = true }
                return
            }
        case .notNewer:
            state.setObject(k("raw", s, key), raw)
            debugLog("[DSYNC] pull \(key.suffix) bytes=\(bytes) not newer")
            if key == .progress { await retryHeldProgress(s, env) }
            if await healIfLocalDiffers(s, key, env) == .notReady { return }
        }
        s.read.insert(key)
    }

    private static let HEAL_KEYS: Set<DsyncKey> = [.favorites, .recents, .collections, .hiddenGroups, .groupOrder]

    /// Self-heal, once per session per key: a consumed stamp skips the apply, so a local copy
    /// that is empty or differs from a non-empty server copy (no unsent change) is re-applied.
    private func healIfLocalDiffers(_ s: DsyncSession, _ key: DsyncKey, _ env: DsyncEnvelope) async -> ApplyResult? {
        guard Self.HEAL_KEYS.contains(key), !isDirty(s, key), !s.healed.contains(key) else { return nil }
        let d = env.data
        let m = DsyncLocal.channelMap(s.playlistId)
        var check: (Bool, Int)?
        switch key {
        case .favorites:
            let ids = DsyncPayloads.decodeFavorites(d) ?? []
            if !ids.isEmpty && !m.toInt.isEmpty {
                let local = Set(DsyncLocal.favorites().filter { m.toInt[$0] != nil })
                let server = Set(ids.compactMap { m.toLocal[$0] })
                if !server.isEmpty && local != server { check = (local.isEmpty, ids.count) }
            }
        case .recents:
            let remote = DsyncPayloads.decodeRecents(d) ?? []
            if !remote.isEmpty && !m.toInt.isEmpty {
                let local = Set(DsyncLocal.recents(s.playlistId).filter { m.toInt[$0] != nil })
                let server = Set(remote.compactMap { m.toLocal[$0.channelId] })
                if !server.isEmpty && !server.isSubset(of: local) { check = (local.isEmpty, remote.count) }
            }
        case .collections:
            let remote = DsyncPayloads.decodeCollections(d) ?? []
            if !remote.isEmpty && !m.toInt.isEmpty {
                let local = DsyncLocal.collections()
                let l = Dictionary(local.map { ($0.id, "\($0.name)|\(Set($0.memberIDs.filter { m.toInt[$0] != nil }).sorted())") }, uniquingKeysWith: { a, _ in a })
                let r = Dictionary(remote.map { ($0.id, "\($0.name)|\(Set($0.members.compactMap { m.toLocal[$0] }).sorted())") }, uniquingKeysWith: { a, _ in a })
                if l != r { check = (local.isEmpty, remote.count) }
            }
        case .hiddenGroups:
            if let g = DsyncPayloads.decodeHiddenGroups(d), !(g.live.isEmpty && g.movies.isEmpty && g.series.isEmpty) {
                let l = DsyncLocal.hiddenGroups()
                if !(Set(l.live) == Set(g.live) && Set(l.movies) == Set(g.movies) && Set(l.series) == Set(g.series)) {
                    check = (l.live.isEmpty && l.movies.isEmpty && l.series.isEmpty, g.live.count + g.movies.count + g.series.count)
                }
            }
        case .groupOrder:
            if let g = DsyncPayloads.decodeGroupOrder(d), !(g.order.isEmpty && g.mode == "default") {
                let l = DsyncLocal.groupOrder()
                if !(l.mode == g.mode && l.order == g.order) { check = (l.order.isEmpty, g.order.count) }
            }
        default: break
        }
        guard let check else {
            s.healed.insert(key)
            return nil
        }
        let applied = await apply(s, key, env)
        if applied == .notReady { return applied }
        s.healed.insert(key)
        if applied == .applied {
            s.suppressUntil[key] = Self.nowMs() + DsyncTiming.SUPPRESS_MS
            cloudFollowFor(s, key, "pull")
            debugLog("[DSYNC] \(key.suffix) in: re-applied after \(check.0 ? "empty local" : "local differs") (\(check.1))")
        }
        return applied
    }

    // MARK: - Write (section 7.3 to 7.8)

    private func onLocalChange(_ s: DsyncSession, _ key: DsyncKey) {
        guard DsyncPushRules.acceptLocalChange(sessionLive: session === s, suppressUntilMs: s.suppressUntil[key], nowMs: Self.nowMs()) else { return }
        s.tooLarge.remove(key)
        setDirty(s, key, true)
        cloudFollowFor(s, key, "local")
        schedule(s, key, DsyncPushRules.debounceMs(key))
    }

    private func schedule(_ s: DsyncSession, _ key: DsyncKey, _ delayMs: Int64) {
        guard !s.ended else { return }
        s.pending[key]?.cancel()
        s.pending[key] = Task { [weak self] in
            if delayMs > 0 { await Self.sleep(delayMs) }
            guard !Task.isCancelled else { return }
            s.pending.removeValue(forKey: key)
            await self?.write(s, key)
        }
    }

    private func flush(_ s: DsyncSession) async {
        let keys = Array(s.pending.keys)
        for key in keys { s.pending.removeValue(forKey: key)?.cancel() }
        for key in keys { await write(s, key) }
    }

    private func write(_ s: DsyncSession, _ key: DsyncKey) async {
        await s.mutex.lock()
        defer { s.mutex.unlock() }
        await writeLocked(s, key)
    }

    private func retryLater(_ s: DsyncSession, _ key: DsyncKey) {
        s.resend.insert(key)
        let n = s.retries[key] ?? 0
        if let delay = DsyncTiming.backoff(n) {
            s.retries[key] = n + 1
            schedule(s, key, delay)
        }
    }

    private func writeLocked(_ s: DsyncSession, _ key: DsyncKey) async {
        guard !s.paused, session === s else { return }
        if DsyncCoexistence.FORCE_KEYS.contains(key) && choiceHeld() {
            setDirty(s, key, true)
            return
        }
        guard DsyncGate.mayWrite(sessionToken: s.token, currentToken: "", firstPullDone: s.firstPullDone, keyRead: s.read.contains(key)) else { return }
        guard !s.blocked.contains(key), enabled(key, s), let c = s.client else { return }
        let b = DsyncBucket.of(key)
        if s.resend.contains(key) { debugLog("[DSYNC] retry \(key.suffix) after offline") }
        let force = isForced(s, key)
        switch await refreshBeforePut(s, c, b, key, force: force) {
        case .unreachable:
            retryLater(s, key)
            return
        case .remoteTook: return
        case .ok: break
        }
        let raw = rawOf(s, key)
        // A forced replace builds row categories from local alone.
        let base: DsyncObject? = force && DsyncCoexistence.FORCE_ROW_KEYS.contains(key) ? nil : raw?["data"]?.asObject
        let now = Self.nowS()
        guard let data = await build(s, key, base: base, now: now) else { return }
        guard session === s else { return }
        if force && s.manual.contains(key) {
            debugLog("[DSYNC] manual push \(key.suffix) rows=\(DsyncCoexistence.rowCount(key, data))")
        } else if DsyncCoexistence.forcedWritesEmpty(force: force, key: key) && DsyncCoexistence.isEmptyData(key, data) {
            debugLog("[DSYNC] force push \(key.suffix) rows=0 (empty, mirrors iCloud)")
        } else if force && key == .settings {
            debugLog("[DSYNC] force push settings rows=\(DsyncCoexistence.rowCount(key, data)) (mirrors iCloud)")
        } else if force {
            debugLog("[DSYNC] force push \(key.suffix) rows=\(DsyncCoexistence.rowCount(key, data)) (user chose iCloud)")
        }
        // Compare with the server copy refreshBeforePut just fetched, not the last copy saved.
        if DsyncPushRules.unchanged(built: data, serverData: serverDataOf(s, b, key), lastData: lastDataOf(s, key), present: s.present.contains(key)) {
            if DsyncPushRules.logsUnchanged(force: force, dirty: isDirty(s, key), key: key) {
                debugLog("[DSYNC] put \(b.wire) (\(key.suffix)) status=unchanged rows=\(DsyncCoexistence.rowCount(key, data)) (server already holds this copy)")
            }
            if force { clearForced(s, key) }
            markSent(s, key)
            clearAwaiting(s, key)
            return
        }
        if s.serverFull && s.serverBytes[b.wire] == nil {
            refreshMessage(s)
            return
        }
        let sub = DsyncV2.encodeCategory(raw, deviceId: deviceId, updatedAt: now, data: data)
        // No byte guard before the PUT: send the full value; trim only on a 413.
        var value = withProviders(s, DsyncV2.encodeBucket(bucketRaw(s, b), deviceId: deviceId, appVersion: appVersion, updatedAt: now, replace: [(key, sub)]))
        var step = 0
        while true {
            let (status, _) = await c.put(b, key: key, value: value)
            switch status {
            case .ok:
                saveBucketRaw(s, b, value)
                let sent = value[DsyncV2.CATEGORIES]?.asObject?[key.suffix]?.asObject ?? DsyncObject()
                let at = sent["updatedAt"]?.asStr.flatMap(DsyncEnvelopeCodec.parseIso) ?? Self.nowS()
                saveAfter(s, key, raw: sent, at: at, dev: deviceId, data: data)
                s.serverBytes[b.wire] = Int64(DsyncEnvelopeCodec.byteSize(value))
                s.present.insert(key)
                stampLast(s)
                s.resend.remove(key)
                if force { clearForced(s, key) }
                markSent(s, key)
                clearAwaiting(s, key)
                s.retries.removeValue(forKey: key)
                s.tooLarge.remove(key)
            case .tooLarge:
                if let next = DispatcharrAppDataClient.nextTrim(value, from: step) {
                    value = next.0
                    step = next.1
                    continue
                }
                s.tooLarge.insert(key)
                debugLog("[DSYNC] \(b.wire) still too large after every trim; stopped until the next change")
            case .full: s.serverFull = true
            case .auth: s.paused = true
            case .retry: retryLater(s, key)
            case .rejected: break
            }
            break
        }
        refreshMessage(s)
    }

    private enum Refresh { case ok, unreachable, remoteTook }

    /// GET the key first: row categories merge, a newer whole value is taken, and every other
    /// category is re-emitted at its current server value.
    private func refreshBeforePut(_ s: DsyncSession, _ c: DispatcharrAppDataClient, _ b: DsyncBucket, _ key: DsyncKey, force: Bool) async -> Refresh {
        let got: (DsyncV2.Bucket, Int)
        switch await c.fetchBucket(b) {
        case .failed: return .unreachable
        case .absent, .malformed: return .ok
        case .tooNew:
            s.blocked.formUnion(b.keys)
            return .remoteTook
        case .got(let bucket, let bytes): got = (bucket, bytes)
        }
        saveBucketRaw(s, b, got.0.raw)
        s.serverBytes[b.wire] = Int64(got.1)
        guard let env = DsyncV2.category(got.0, key)?.envelope else { return .ok }
        s.present.insert(key)
        if force { return .ok }
        let at = state.long(k("at", s, key))
        let dev = state.string(k("dev", s, key)) ?? ""
        if DsyncPullRules.sameAsConsumed(remoteAt: env.updatedAt, remoteDevice: env.deviceId, remoteData: env.data,
                                         localAt: at, localDevice: dev, localData: rawOf(s, key)?["data"]?.asObject) { return .ok }
        if DsyncGate.ROW_MERGE_KEYS.contains(key) {
            guard let merged = mergedEnvelope(s, key, env) else { return .unreachable }
            let applied = await apply(s, key, merged)
            if applied != .applied { return applied == .malformed ? .ok : .unreachable }
            s.suppressUntil[key] = Self.nowMs() + DsyncTiming.SUPPRESS_MS
            saveAfter(s, key, raw: env.raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
            debugLog("[DSYNC] pull \(key.suffix) bytes=\(got.1) merged with local change (before put)")
            return .ok
        }
        guard DsyncEnvelopeCodec.remoteWins(localAt: at, localDevice: dev, remoteAt: env.updatedAt, remoteDevice: env.deviceId) else { return .ok }
        switch DsyncGate.onNewerPull(key, dirty: isDirty(s, key), dirtyAt: dirtyAt(s, key), remoteAt: env.updatedAt) {
        case .keepLocal:
            state.setObject(k("raw", s, key), env.raw)
            return .ok
        default:
            guard await apply(s, key, env) == .applied else { return .unreachable }
            s.suppressUntil[key] = Self.nowMs() + DsyncTiming.SUPPRESS_MS
            saveAfter(s, key, raw: env.raw, at: env.updatedAt, dev: env.deviceId, data: env.data)
            setDirty(s, key, false)
            debugLog("[DSYNC] \(key.suffix): server copy newer than the local change; applied")
            return .remoteTook
        }
    }

    // MARK: - Id cache readiness (DsyncReadiness)

    private func cacheReady(_ s: DsyncSession, _ key: DsyncKey) async -> Bool {
        switch DsyncReadiness.cacheFor(key) {
        case nil: return true
        case .channels?: return !DsyncLocal.channelMap(s.playlistId).toInt.isEmpty
        case .vodCatalog?:
            guard let server = DsyncLocal.server(s.playlistId) else { return false }
            return await DsyncLocal.moviesReady(server)
        }
    }

    /// Gate one build: true = defer (the key stays dirty; the cache poll re-pushes it).
    private func deferForCache(_ s: DsyncSession, _ key: DsyncKey, localRows: Int, unresolvedRows: Int, ready: Bool? = nil) async -> Bool {
        let isReady: Bool
        if let ready { isReady = ready } else { isReady = await cacheReady(s, key) }
        let decision = DsyncReadiness.decide(key, cacheReady: isReady, unresolvedRows: unresolvedRows)
        if decision == .pushPartial {
            if s.partial.insert(key).inserted {
                if isForced(s, key) {
                    debugLog("[DSYNC] force push \(key.suffix) drops untranslated=\(unresolvedRows) sent=\(localRows - unresolvedRows) (not in this catalog)")
                } else {
                    debugLog("[DSYNC] push \(key.suffix) partial after sweep: translated=\(localRows - unresolvedRows) untranslated=\(unresolvedRows) (kept local; key stays dirty)")
                }
            }
        } else {
            s.partial.remove(key)
        }
        if decision != .deferred {
            if s.awaitingCache[key] != nil { s.readyAtPush[key] = isReady }
            return false
        }
        setDirty(s, key, DsyncReadiness.dirtyAfter(.deferred, putOk: false, dirtyBefore: isDirty(s, key)))
        if s.awaitingCache.updateValue(localRows, forKey: key) == nil {
            debugLog("[DSYNC] push \(key.suffix) deferred: id cache not ready (rows=\(localRows), untranslated=\(unresolvedRows))")
        }
        return true
    }

    private func clearAwaiting(_ s: DsyncSession, _ key: DsyncKey) {
        let ready = s.readyAtPush.removeValue(forKey: key) ?? true
        s.sweepRetried.remove(key)
        if let n = s.awaitingCache.removeValue(forKey: key) {
            debugLog("[DSYNC] \(key.suffix) re-pushed after cache ready rows=\(n)\(ready ? "" : " during sweep")")
        }
    }

    /// After a successful send: clean, unless untranslated rows stayed local.
    private func markSent(_ s: DsyncSession, _ key: DsyncKey) {
        if s.partial.contains(key) { state.set(k("dirty", s, key), true) } else { setDirty(s, key, false) }
        if s.convergeAfterWrite.remove(key) != nil && s.convergeAfterWrite.isEmpty { maybeConverge(s) }
    }

    /// Local-only probe: movie rows of [key] whose id does not translate, or nil for keys outside the VOD catalog.
    private func probeMovieMisses(_ s: DsyncSession, _ key: DsyncKey) -> Int? {
        switch key {
        case .progress: return DsyncLocal.progressRows(s.playlistId).filter { $0.vodType == "movie" && Int($0.vodID) == nil }.count
        case .watchlist: return DsyncLocal.watchlist(s.playlistId).filter { $0.vodType == "movie" && Int($0.vodID) == nil }.count
        case .hiddenTitles: return DsyncLocal.hiddenTitles(s.playlistId).filter { $0.0 == "movie" && Int($0.1) == nil }.count
        default: return nil
        }
    }

    // MARK: - Recents stamps

    private func recentStamps(_ s: DsyncSession) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for (id, v) in state.object(k("rstamp", s)) ?? DsyncObject() { if let n = v.asLong { out[id] = n } }
        return out
    }

    private func saveRecentStamps(_ s: DsyncSession, _ stamps: [String: Int64], head: String?) {
        state.setObject(k("rstamp", s), DsyncObject(stamps.sorted { $0.key < $1.key }.map { ($0.key, DsyncJSON.long($0.value)) }))
        if let head { state.set(k("rhead", s), head) }
    }

    private func stampRecents(_ s: DsyncSession) {
        let r = DsyncRecentsRules.stamp(ids: DsyncLocal.recents(s.playlistId), previousHead: state.string(k("rhead", s)),
                                        stamps: recentStamps(s), now: Self.nowS())
        saveRecentStamps(s, r.stamps, head: r.head)
    }

    // MARK: - Build (local to data), section 4 and 6.2

    private func unresolvedOnce(_ s: DsyncSession, _ what: String, _ localId: String) {
        if unresolvedLogged.insert("\(s.profileKey)|\(what)|\(localId)").inserted {
            debugLog("[DSYNC] \(what): no server id for a local row yet; kept on this device only")
        }
    }

    private func build(_ s: DsyncSession, _ key: DsyncKey, base: DsyncObject?, now: Int64) async -> DsyncObject? {
        let pid = s.playlistId
        switch key {
        case .favorites:
            let m = DsyncLocal.channelMap(pid)
            let rows = DsyncLocal.favorites()
            if await deferForCache(s, key, localRows: rows.count, unresolvedRows: rows.count, ready: !m.toInt.isEmpty) { return nil }
            let local = rows.compactMap { m.toInt[$0] }
            let keep = (base.flatMap { DsyncPayloads.decodeFavorites($0) } ?? []).filter { m.toLocal[$0] == nil }
            let out = (local + keep).distinctOrdered()
            debugLog(DsyncFavoritesRules.logLine("out", ids: rows.count, mapped: local.count, written: out.count, scope: s.token, playlistId: pid))
            return DsyncPayloads.encodeFavorites(base, out)
        case .recents:
            let m = DsyncLocal.channelMap(pid)
            let ids = DsyncLocal.recents(pid)
            if await deferForCache(s, key, localRows: ids.count, unresolvedRows: ids.count, ready: !m.toInt.isEmpty) { return nil }
            let local = DsyncRecentsRules.localRows(ids: ids, toInt: m.toInt, stamps: recentStamps(s), now: now)
            let remote = base.flatMap { DsyncPayloads.decodeRecents($0) } ?? []
            let out = DsyncPayloads.encodeRecents(base, DsyncMerge.recents(local, remote))
            debugLog("[DSYNC] recents out local=\(ids.count) canonical=\(local.map(\.channelId).distinctOrdered().count) server=\(remote.count) out=\(DsyncCoexistence.rowCount(key, out))")
            return out
        case .progress:
            guard let server = DsyncLocal.server(pid) else { return nil }
            let candidates = DsyncLocal.progressRows(pid)
            var local: [ProgressRow] = []
            for p in candidates {
                if let r = DsyncLocal.progressRow(p) { local.append(r) } else { unresolvedOnce(s, "progress", p.vodID) }
            }
            if candidates.count > local.count && s.progressDiag.insert(candidates.count - local.count).inserted {
                let miss = candidates.filter { DsyncLocal.progressRow($0) == nil }
                let movies = miss.filter { $0.vodType == "movie" }.count
                let eps = miss.filter { $0.vodType == "episode" && $0.seriesID.flatMap { Int($0) } != nil }.count
                let ready = await DsyncLocal.moviesReady(server)
                debugLog("[DSYNC] progress drops untranslated: movies=\(movies) episodes=\(eps) other=\(miss.count - movies - eps) catalogReady=\(ready)")
            }
            if await deferForCache(s, key, localRows: candidates.count, unresolvedRows: candidates.count - local.count) { return nil }
            let remote = base.flatMap { DsyncPayloads.decodeProgress($0) } ?? []
            let have = Set(local.map { "\($0.type)|\($0.vodId)" })
            let heldRows = isBase(s) ? held.progress(pid).filter { !have.contains("\($0.type)|\($0.vodId)") } : []
            return DsyncPayloads.encodeProgress(base, DsyncMerge.progress(local + heldRows, remote), now: now)
        case .reminders:
            let m = DsyncLocal.channelMap(pid)
            let all = DsyncLocal.reminders()
            if await deferForCache(s, key, localRows: all.count, unresolvedRows: all.count, ready: !m.toInt.isEmpty) { return nil }
            let remote = base.flatMap { DsyncPayloads.decodeReminders($0) } ?? []
            var remoteEnd: [String: Int64] = [:]
            for r in remote { remoteEnd["\(r.channelId)|\(r.start)"] = r.end }
            // Apple reminders carry no end time: the server row's end is kept, else the start.
            let local: [ReminderRow] = all.compactMap { e in
                guard let cid = m.intByName[e.info.channelName] else { return nil }
                let start = Int64(e.info.startTime.timeIntervalSince1970)
                return ReminderRow(channelId: cid, start: start, end: remoteEnd["\(cid)|\(start)"] ?? start,
                                   title: e.info.programTitle, channelName: e.info.channelName)
            }
            let keep = remote.filter { m.toLocal[$0.channelId] == nil }
            let rows = DsyncPayloads.carryTails(local, remote, id: { AnyHashable("\($0.channelId)|\($0.start)") }, tail: { $0.tail },
                                                withTail: { var r = $0; r.tail = $1; return r })
            return DsyncPayloads.encodeReminders(base, rows + keep, now: now)
        case .watchlist, .hiddenTitles:
            guard let server = DsyncLocal.server(pid) else { return nil }
            let what = key == .watchlist ? "watchlist" : "hiddenTitles"
            let live: [(String, String, Date)] = key == .watchlist
                ? DsyncLocal.watchlist(pid).map { ($0.vodType, $0.vodID, $0.addedAt) } : DsyncLocal.hiddenTitles(pid)
            var local: [VodMarkRow] = []
            for (t, id, at) in live {
                if let r = DsyncLocal.markRow(type: t, id: id, at: at) { local.append(r) } else if t == "movie" { unresolvedOnce(s, what, "m:\(id)") }
            }
            if await deferForCache(s, key, localRows: live.count, unresolvedRows: live.count - local.count) { return nil }
            let remote = base.flatMap { DsyncPayloads.decodeVodMarks($0) } ?? []
            let rows = DsyncPayloads.carryTails(local, remote, id: { AnyHashable("\($0.type)|\($0.vodId)") }, tail: { $0.tail },
                                                withTail: { var r = $0; r.tail = $1; return r })
            let unknown = await unknownMovieRows(server, remote, rows)
            return DsyncPayloads.encodeVodMarks(base, rows + unknown, cap: key == .watchlist ? DsyncLimits.WATCHLIST : DsyncLimits.HIDDEN_TITLES)
        case .hiddenGroups:
            return DsyncPayloads.encodeHiddenGroups(base, DsyncLocal.hiddenGroups())
        case .groupOrder:
            return DsyncPayloads.encodeGroupOrder(base, DsyncLocal.groupOrder())
        case .settings:
            if isForced(s, key) && !s.manual.contains(key), let mirror = cloudMirrorLanes?(pid) {
                // Rule 4 mirror: exactly the cloud lanes just applied.
                debugLog("[DSYNC] settings: mirror lanes \(laneLine(mirror))")
                return DsyncPayloads.encodeSettingsLanes(base?.filterKeys { !DsyncPayloads.SETTINGS_LANES.contains($0) }, mirror)
            }
            let values = DsyncLocal.settingsValues().filter { DsyncSettingsValidator.isOwned($0.0) }
            debugLog("[DSYNC] settings: defaultGroup=\(values.first { $0.0 == "defaultGroup" }?.1.content ?? "")")
            let scopes = DsyncLocal.scopes()
            let lanes = laneValues(values, scopeOf: { DsyncLocal.scopeForName(scopes, $0) }, isTv: DsyncLocal.isTv)
            debugLog("[DSYNC] settings: lanes \(laneLine(lanes))")
            return DsyncPayloads.encodeSettingsLanes(base, lanes)
        case .remoteMap:
            // Phones and tablets round-trip the TV map untouched: never write it.
            guard DsyncLocal.isTv, let tv = DsyncLocal.remoteMap() else { return nil }
            var merged = base?["tv"]?.asObject ?? DsyncObject()
            if tv.isEmpty { merged = DsyncObject() } else { for (n, v) in tv { merged[n] = v } }
            return DsyncPayloads.encodeRemoteMap(base, merged)
        case .radioDefault:
            return DsyncPayloads.encodeRadioDefault(base, DsyncLocal.radioDefault())
        case .collections:
            let m = DsyncLocal.channelMap(pid)
            let local = DsyncLocal.collections()
            if await deferForCache(s, key, localRows: local.count, unresolvedRows: local.count, ready: !m.toInt.isEmpty) { return nil }
            var remote: [String: CollectionRow] = [:]
            for r in base.flatMap({ DsyncPayloads.decodeCollections($0) }) ?? [] where remote[r.id] == nil { remote[r.id] = r }
            let rows = local.map { c -> CollectionRow in
                let r = remote[c.id]
                let stale = (r?.members ?? []).filter { m.toLocal[$0] == nil }
                return CollectionRow(id: c.id, name: c.name, placement: c.placement == .beginning ? "b" : "e",
                                     members: (c.memberIDs.compactMap { m.toInt[$0] } + stale).distinctOrdered(), tail: r?.tail ?? Tail())
            }
            return DsyncPayloads.encodeCollections(base, rows)
        case .profiles:
            return nil
        }
    }

    private func laneLine<V>(_ lanes: [String: [String: V]]) -> String {
        let line = DsyncScope.LANES.compactMap { l in lanes[l].map { "\(l)=\($0.count)" } }.joined(separator: ", ")
        return line.isEmpty ? "none" : line
    }

    /// Server movie rows this device cannot map (not in its catalog) are kept, never dropped.
    private func unknownMovieRows(_ server: ServerConnection, _ remote: [VodMarkRow], _ ours: [VodMarkRow]) async -> [VodMarkRow] {
        let have = Set(ours.map { "\($0.type)|\($0.vodId)" })
        let movies = remote.filter { $0.type == "m" && !have.contains("m|\($0.vodId)") }
        if movies.isEmpty { return [] }
        let known = await DsyncLocal.catalog(server, kind: .movie, ids: movies.map(\.vodId))
        return movies.filter { known[$0.vodId] == nil }
    }

    // MARK: - Held progress (section 10a)

    private func holdProgress(_ s: DsyncSession, _ server: ServerConnection, _ unresolved: [ProgressRow], _ why: String) async {
        guard isBase(s) else { return }
        held.setProgress(s.playlistId, unresolved)
        if !unresolved.isEmpty || why != "retry" {
            let ready = await DsyncLocal.moviesReady(server)
            debugLog("[DSYNC] progress \(why) held=\(unresolved.count) movies=\(unresolved.filter { $0.type == "m" }.count) "
                + "episodes=\(unresolved.filter { $0.type == "e" }.count) catalogReady=\(ready)")
        }
    }

    /// Held rows a newer catalog now resolves become local rows (no server read).
    private func retryHeldProgress(_ s: DsyncSession, _ env: DsyncEnvelope) async {
        guard isBase(s), let server = DsyncLocal.server(s.playlistId) else { return }
        var written = 0
        if !held.has(s.playlistId) {
            guard let rows = DsyncPayloads.decodeProgress(env.data) else { return }
            await holdProgress(s, server, await DsyncLocal.applyProgress(server, rows, written: &written), "in (held set rebuilt)")
        } else if !isDirty(s, .progress) {
            let before = held.progress(s.playlistId)
            guard let rows = DsyncPayloads.decodeProgress(env.data) else { return }
            let left = await DsyncLocal.applyProgress(server, DsyncHeld.merge(rows, before), written: &written)
            if Set(left.map(DsyncHeld.item)) != Set(before.map(DsyncHeld.item)) { await holdProgress(s, server, left, "retry") }
        } else {
            let before = held.progress(s.playlistId)
            if before.isEmpty { return }
            let left = await DsyncLocal.applyProgress(server, before, written: &written)
            if left.count != before.count { await holdProgress(s, server, left, "retry") }
        }
        if written > 0 {
            debugLog("[DSYNC] progress held rows resolved=\(written)")
            cloudFollowFor(s, .progress, "held resolved")
        }
    }

    // MARK: - Apply (data to local), section 6.1 full replace

    /// A newer server value against an unsent change: the row union of both sides.
    private func mergedEnvelope(_ s: DsyncSession, _ key: DsyncKey, _ env: DsyncEnvelope) -> DsyncEnvelope? {
        let m = DsyncLocal.channelMap(s.playlistId)
        func with(_ d: DsyncObject) -> DsyncEnvelope {
            DsyncEnvelope(schemaVersion: env.schemaVersion, deviceId: env.deviceId, platform: env.platform, appVersion: env.appVersion,
                          updatedAt: env.updatedAt, data: d, extra: env.extra, raw: env.raw)
        }
        switch key {
        case .favorites:
            guard !m.toInt.isEmpty, let remote = DsyncPayloads.decodeFavorites(env.data) else { return nil }
            let local = DsyncLocal.favorites().compactMap { m.toInt[$0] }
            return with(DsyncPayloads.encodeFavorites(env.data, DsyncGate.favoritesUnion(local, remote)))
        case .collections:
            guard !m.toInt.isEmpty, let remote = DsyncPayloads.decodeCollections(env.data) else { return nil }
            let local = DsyncLocal.collections().map {
                CollectionRow(id: $0.id, name: $0.name, placement: $0.placement == .beginning ? "b" : "e", members: $0.memberIDs.compactMap { m.toInt[$0] })
            }
            return with(DsyncPayloads.encodeCollections(env.data, DsyncGate.collectionsUnion(local, remote)))
        case .reminders:
            guard !m.toInt.isEmpty, let remote = DsyncPayloads.decodeReminders(env.data) else { return nil }
            let local: [ReminderRow] = DsyncLocal.reminders().compactMap { e in
                guard let cid = m.intByName[e.info.channelName] else { return nil }
                let start = Int64(e.info.startTime.timeIntervalSince1970)
                return ReminderRow(channelId: cid, start: start, end: start, title: e.info.programTitle, channelName: e.info.channelName)
            }
            return with(DsyncPayloads.encodeReminders(env.data, DsyncGate.remindersUnion(local, remote), now: Self.nowS()))
        default:
            return env
        }
    }

    private func apply(_ s: DsyncSession, _ key: DsyncKey, _ env: DsyncEnvelope) async -> ApplyResult {
        let d = env.data
        let pid = s.playlistId
        switch key {
        case .favorites:
            guard let ids = DsyncPayloads.decodeFavorites(d) else { return .malformed }
            let m = DsyncLocal.channelMap(pid)
            if m.toInt.isEmpty {
                debugLog("[DSYNC] favorites in: \(ids.count) ids, channel list \(pid.prefix(8)) not loaded; retry next pull")
                return .notReady
            }
            let plan = DsyncFavoritesRules.plan(ids: ids, toLocal: m.toLocal, toInt: m.toInt, local: DsyncLocal.favorites())
            DsyncLocal.setFavorites(plan.order)
            debugLog(DsyncFavoritesRules.logLine("in", ids: ids.count, mapped: plan.wanted.count, written: plan.wanted.count, scope: s.token, playlistId: pid))
        case .recents:
            guard let remote = DsyncPayloads.decodeRecents(d) else { return .malformed }
            let m = DsyncLocal.channelMap(pid)
            if m.toInt.isEmpty { return .notReady }
            let stamps = recentStamps(s)
            let ids = DsyncLocal.recents(pid)
            let local = DsyncRecentsRules.localRows(ids: ids, toInt: m.toInt, stamps: stamps, now: Self.nowS())
            let r = DsyncRecentsRules.applied(local: local, remote: remote, ids: ids, toInt: m.toInt, toLocal: m.toLocal)
            DsyncLocal.setRecents(pid, r.ids)
            var st = stamps
            for (id, at) in r.stamps { st[id] = at }
            saveRecentStamps(s, st, head: r.ids.first)
        case .progress:
            guard let rows = DsyncPayloads.decodeProgress(d) else { return .malformed }
            guard let server = DsyncLocal.server(pid) else { return .failed }
            var written = 0
            let unresolved = await DsyncLocal.applyProgress(server, rows, written: &written)
            await holdProgress(s, server, unresolved, "in")
        case .reminders:
            guard let rows = DsyncPayloads.decodeReminders(d) else { return .malformed }
            let m = DsyncLocal.channelMap(pid)
            if m.toInt.isEmpty { return .notReady }
            applyReminders(rows, m)
        case .watchlist:
            guard let rows = DsyncPayloads.decodeVodMarks(d) else { return .malformed }
            guard let server = DsyncLocal.server(pid) else { return .failed }
            await DsyncLocal.applyWatchlist(server, rows)
        case .hiddenTitles:
            guard let rows = DsyncPayloads.decodeVodMarks(d) else { return .malformed }
            guard let server = DsyncLocal.server(pid) else { return .failed }
            await DsyncLocal.applyHiddenTitles(server, rows)
        case .hiddenGroups:
            guard let g = DsyncPayloads.decodeHiddenGroups(d) else { return .malformed }
            DsyncLocal.setHiddenGroups(g)
        case .groupOrder:
            guard let g = DsyncPayloads.decodeGroupOrder(d) else { return .malformed }
            DsyncLocal.setGroupOrder(g)
        case .settings:
            guard let lanes = DsyncPayloads.decodeSettingsLanes(d) else { return .malformed }
            // Each name is read from the one lane its scope picks here; only owned names are validated.
            let scopes = DsyncLocal.scopes()
            let v = pickFromLanes(lanes, names: [], scopeOf: { DsyncLocal.scopeForName(scopes, $0) }, isTv: DsyncLocal.isTv)
            let r = DsyncSettingsValidator.filter(v.filter { DsyncSettingsValidator.isOwned($0.key) })
            for line in r.ignored { debugLog("[DSYNC] settings: ignored \(line)") }
            if let g = r.accepted["defaultGroup"] { debugLog("[DSYNC] settings: defaultGroup=\(g.content)") }
            DsyncLocal.applySettings(r.accepted)
        case .remoteMap:
            guard let tv = DsyncPayloads.decodeRemoteMap(d) else { return .malformed }
            if DsyncLocal.isTv { DsyncLocal.setRemoteMap(tv) }
        case .radioDefault:
            guard let on = DsyncPayloads.decodeRadioDefault(d) else { return .malformed }
            DsyncLocal.setRadioDefault(on)
        case .collections:
            guard let rows = DsyncPayloads.decodeCollections(d) else { return .malformed }
            let m = DsyncLocal.channelMap(pid)
            if m.toInt.isEmpty { return .notReady }
            DsyncLocal.setCollections(rows.map {
                ChannelCollection(id: $0.id, name: $0.name, memberIDs: $0.members.compactMap { m.toLocal[$0] },
                                  placement: $0.placement == "b" ? .beginning : .end)
            })
        case .profiles:
            return DsyncPayloads.decodeProfiles(d) == nil ? .malformed : .applied
        }
        return .applied
    }

    private func applyReminders(_ rows: [ReminderRow], _ m: DsyncLocal.ChannelMap) {
        let local = DsyncLocal.reminders()
        let plan = DsyncRemindersRules.plan(
            rows: rows, nowMs: Self.nowMs(),
            local: local.map { .init(key: $0.key, channelName: $0.info.channelName, startS: Int64($0.info.startTime.timeIntervalSince1970)) },
            intByName: m.intByName, toLocal: m.toLocal)
        var next: [String: SyncableReminder] = [:]
        let gone = Set(plan.removeKeys)
        for e in local where !gone.contains(e.key) { next[e.key] = e.info }
        for r in plan.add {
            let name = m.nameOf[r.channelId] ?? r.channelName
            let start = Date(timeIntervalSince1970: TimeInterval(r.start))
            next[ReminderManager.programKey(channelName: name, title: r.title, start: start)] =
                SyncableReminder(programTitle: r.title, channelName: name, startTime: start, updatedAt: Date())
        }
        ReminderManager.shared.mergeRemote(next)
    }
}
