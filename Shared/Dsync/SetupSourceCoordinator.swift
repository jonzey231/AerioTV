//  SetupSourceCoordinator.swift
//  Aerio
//
//  Rule 4 (docs/DispatcharrSyncSchema.md section 10a): when iCloud and
//  Dispatcharr Sync both hold data for the signed-in Dispatcharr user, the
//  user picks the setup this device starts from and the other side is
//  replaced with it. Base profile only. Port of the Android
//  core/sync/SetupSourceCoordinator.kt; Android's Google Drive side is
//  iCloud here and plugs in through DsyncCloudHooks, registered by the
//  iCloud side in part 4. The prompt itself is part 5: it observes
//  `pending` and calls choose(_:playlistId:) then afterDispatcharrOn().
//
//  Logs mirror the Android [SYNC] lines, with [CLOUD] where Android says
//  [DRIVE]; counts only.

import Foundation

/// What the coordinator needs from the iCloud side (Android DriveSyncManager calls).
/// Every hook defaults to "no cloud side", so the coordinator is inert until part 4 registers them.
struct DsyncCloudHooks {
    /// False when the user never turned iCloud Sync on (no cloud side to choose from).
    var available: @MainActor () -> Bool = { false }
    /// The shared categories of the iCloud copy, or nil when iCloud could not be read (unknown).
    var readSharedSummary: @MainActor () async -> SetupSourceChoice.Summary? = { nil }
    var markUnknown: @MainActor () -> Void = {}
    var clearUnknown: @MainActor () -> Void = {}
    var isUnknown: @MainActor () -> Bool = { false }
    var releaseHold: @MainActor () -> Void = {}
    var holdShared: @MainActor () -> Void = {}
    var sharedHeld: @MainActor () -> Bool = { false }
    /// Applies the iCloud shared categories as a replace; per category whether it applied.
    var applySharedForReplace: @MainActor (_ ignoreOwnership: Bool) async -> [DsyncCategory: Bool] = { _ in [:] }
    var applySharedNow: @MainActor (_ ignoreOwnership: Bool) async -> Void = { _ in }
    var clearReplaceWaits: @MainActor () -> Void = {}
    var armReplaceWait: @MainActor () -> Void = {}
    var replaceBackupNow: @MainActor () async -> Void = {}
    var markReplaceDeferred: @MainActor () -> Void = {}
    var clearReplaceDeferred: @MainActor () -> Void = {}
    var replaceDeferred: @MainActor () -> Bool = { false }
}

@MainActor
final class SetupSourceCoordinator: ObservableObject {
    static let shared = SetupSourceCoordinator()

    struct Probe: Equatable {
        let playlistId: String
        let cloud: SetupSourceChoice.Summary
        let dsync: SetupSourceChoice.Summary
        let decision: SetupSourceChoice.Decision
    }

    /// The probe waiting on the prompt (decision .ask), for the part 5 UI; nil when no choice is open.
    @Published private(set) var pending: Probe?

    /// Registered by the iCloud side (part 4).
    var cloud = DsyncCloudHooks()

    /// Rule 5: no silent converge while this choice is open (the prompt decides).
    private(set) var setupChoicePending = false {
        didSet { if !setupChoicePending { pending = nil } }
    }

    private var dsync: DispatcharrSyncManager { DispatcharrSyncManager.shared }
    private var pendingCloudReplace = false
    private let replaceLock = DsyncMutex()
    private var retrying = false

    private init() {
        DispatcharrSyncManager.shared.setupChoicePending = { [weak self] in self?.setupChoicePending ?? false }
    }

    /// Reads both sides without applying anything. Nil (no choice to make) with no active
    /// Dispatcharr Direct Connect playlist, no iCloud side, or either side unreadable.
    func probe() async -> Probe? {
        guard let pid = DsyncLocal.activeDispatcharrPlaylist()?.id.uuidString else { return nil }
        guard cloud.available() else { return nil }
        let d = await cloud.readSharedSummary()
        guard let x = await dsync.serverSummary(pid) else { return nil }
        guard let decision = SetupSourceChoice.decideKnown(d, x) else {
            // Unknown iCloud: do not decide. Dispatcharr goes on alone; shared iCloud data waits,
            // and the probe runs again once iCloud answers.
            cloud.markUnknown()
            debugLog("[SYNC] setup source cloud=unknown dsync=\(x.categories.values.reduce(0) { $0 + $1.rows }) rows decision=none (retry when iCloud works)")
            return nil
        }
        guard let d else { return nil }
        let p = Probe(playlistId: pid, cloud: d, dsync: x, decision: decision)
        if case .ask = decision {
            setupChoicePending = true
            pending = p
        } else {
            setupChoicePending = false
        }
        debugLog("[SYNC] setup source cloud=\(d.categories.values.reduce(0) { $0 + $1.rows }) rows dsync=\(x.categories.values.reduce(0) { $0 + $1.rows }) rows decision=\(SetupSourceChoice.decisionName(decision))")
        return p
    }

    /// Before Dispatcharr Sync turns on (or iCloud Sync, from Settings).
    /// iCloud: arm the forced Dispatcharr push per category whose iCloud copy applied.
    /// Dispatcharr: iCloud's shared categories stay held and the next iCloud push replaces the backup.
    func choose(_ source: SetupSourceChoice.Source, playlistId: String, ignoreOwnership: Bool = false) async {
        debugLog("[SYNC] setup source chosen: \(source == .cloud ? "Cloud" : "Dispatcharr")")
        setupChoicePending = false
        cloud.clearUnknown()
        switch source {
        case .cloud:
            cloud.clearReplaceWaits()
            // Dispatcharr Sync neither pulls nor pushes shared keys until the apply is done.
            dsync.holdForChoice()
            cloud.releaseHold()
            let applied = await cloud.applySharedForReplace(ignoreOwnership)
            let cancel = DsyncCoexistence.cancelledForceKeys(applied)
            dsync.cancelForceReplace(playlistId, keys: cancel) // leftovers from an earlier arm
            for c in Set(cancel.compactMap(\.category)).sorted(by: { $0.rawValue < $1.rawValue }) {
                debugLog("[SYNC] forced replace cancelled: iCloud backup did not apply (\(c.rawValue))")
            }
            dsync.requestForceReplace(playlistId, keys: DsyncCoexistence.armedForceKeys(applied))
            dsync.releaseChoiceHold()
        case .dispatcharr:
            // Fresh-device order: armed before any hold is released, so no iCloud push of a
            // shared category goes out before the Dispatcharr pull has applied it here.
            cloud.armReplaceWait()
            pendingCloudReplace = true
        }
    }

    /// After Dispatcharr Sync is on: finish a Dispatcharr choice. The iCloud backup is replaced
    /// right after the first pull (or its time limit).
    func afterDispatcharrOn() {
        guard pendingCloudReplace else { return }
        pendingCloudReplace = false
        Task {
            let done = await dsync.awaitFirstPull(timeoutMs: DsyncTiming.CHOICE_FIRST_PULL_WAIT_MS)
            if !done { debugLog("[SYNC] first Dispatcharr pull not finished; iCloud waits for it") }
            cloud.releaseHold()
            await pullThenReplace()
        }
    }

    /// Pull before replace: a full Dispatcharr pull with the stamp check forced applies every
    /// shared key first, and only then is the iCloud backup replaced. A failed pull replaces nothing.
    private func pullThenReplace() async {
        await replaceLock.lock()
        defer { replaceLock.unlock() }
        guard await dsync.pullForChoice() else {
            cloud.markReplaceDeferred()
            debugLog("[CLOUD] replace deferred: Dispatcharr pull failed")
            return
        }
        cloud.clearReplaceDeferred()
        // The pulled progress rows become local first, so the replace counts them as local.
        await dsync.awaitProgressLocal()
        await cloud.replaceBackupNow()
    }

    /// A deferred Dispatcharr-choice replace: retry on the next cycle (never twice at once).
    func retryDeferredReplace() {
        guard cloud.replaceDeferred(), !replaceLock.isLocked else { return }
        Task { await pullThenReplace() }
    }

    /// Unknown iCloud retry: probe again; a readable iCloud decides now. Ask stays for the prompt.
    func retryUnknownCloud() async {
        guard cloud.isUnknown(), !retrying else { return }
        retrying = true
        defer { retrying = false }
        guard let p = await probe() else { return }
        switch p.decision {
        case .useDispatcharr:
            await choose(.dispatcharr, playlistId: p.playlistId)
            afterDispatcharrOn()
        case .useCloud:
            await choose(.cloud, playlistId: p.playlistId, ignoreOwnership: true)
        case .ask:
            debugLog("[SYNC] setup source needs the prompt: open Settings > Sync")
        }
    }

    /// The Sync screen opens the prompt for a pending unknown-iCloud choice.
    func cloudUnknownPending() -> Bool { cloud.isUnknown() }

    /// No choice was needed or possible: apply whatever iCloud held and carry on as before.
    func releaseHeld() async {
        setupChoicePending = false
        guard cloud.sharedHeld() else { return }
        cloud.releaseHold()
        await cloud.applySharedNow(false)
    }

    func holdShared() { cloud.holdShared() }

    /// The prompt was dismissed without a choice.
    func cancelPrompt() { setupChoicePending = false }
}
