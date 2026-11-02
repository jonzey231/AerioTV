//  WelcomeSyncChain.swift
//  Aerio
//
//  Welcome "Keep your devices in sync" (Dispatcharr Sync port, part 4):
//  both cards are selectable and Continue runs one chain. Port of the
//  Android feature/onboarding/WelcomeSyncChain.kt; Android's Google Drive
//  is iCloud here. Add Profiles ("Who watches on this iPhone?") closes every
//  Dispatcharr chain, as on Android. The plan is pure so the order is easy
//  to diff against Android; WelcomeView walks it.

import Foundation

enum WelcomeSyncChain {
    enum Step: String {
        /// iCloud Sync on, "What should come in from iCloud?", restore (playlists first).
        case cloudRestore
        /// "Your backup needs an update": the restored backup is old format.
        case backupUpdate
        /// Connect a Server, Dispatcharr entry, Dispatcharr Sync on after the connect.
        case connectServer
        /// "Turn on Dispatcharr Sync?" (autoEnable when Dispatcharr was selected).
        case dispatcharrSync
        /// "Also back up to iCloud?"
        case cloudOffer
        /// "Who watches on this iPhone?" (AddProfilesStepView); skipped for a kid-only device.
        case addProfiles
        case main
    }

    /// Steps after Continue. restoredIsDispatcharr: the iCloud restore activated a
    /// Dispatcharr Direct Connect playlist (ignored when iCloud is not selected).
    /// cloudAvailable: the device is signed in to iCloud.
    static func plan(cloud: Bool, dispatcharr: Bool, restoredIsDispatcharr: Bool,
                     cloudAvailable: Bool, backupNeedsUpdate: Bool = false) -> [Step] {
        if !cloud && !dispatcharr { return [] }
        var steps: [Step] = []
        if cloud { steps.append(.cloudRestore) }
        if showBackupUpdate(cloud: cloud, backupNeedsUpdate: backupNeedsUpdate) { steps.append(.backupUpdate) }
        if dispatcharr {
            if !(cloud && restoredIsDispatcharr) { steps.append(.connectServer) }
            steps.append(.dispatcharrSync)
            if showCloudOffer(cloudOn: cloud, cloudAvailable: cloudAvailable) { steps.append(.cloudOffer) }
            steps.append(.addProfiles)
        } else if restoredIsDispatcharr {
            // iCloud only, restore brought a Dispatcharr playlist: the step asks (no auto-on), then Add Profiles.
            steps.append(.dispatcharrSync)
            steps.append(.addProfiles)
        }
        steps.append(.main)
        return steps
    }

    /// The backup update step runs right after an iCloud restore of an old-format backup, for every playlist type.
    static func showBackupUpdate(cloud: Bool, backupNeedsUpdate: Bool) -> Bool { cloud && backupNeedsUpdate }

    /// "Also back up to iCloud?" runs after the Dispatcharr Sync step only while iCloud is off and available.
    static func showCloudOffer(cloudOn: Bool, cloudAvailable: Bool) -> Bool { !cloudOn && cloudAvailable }

    /// After the iCloud restore: continue into Connect a Server (true) or the sync step on the restored playlist (false).
    static func connectAfterRestore(dispatcharr: Bool, restoredIsDispatcharr: Bool) -> Bool {
        dispatcharr && !restoredIsDispatcharr
    }

    /// Providers selected or answered in this onboarding flow; the one-time providers
    /// offer leaves them out. Process memory only (wire ids: SyncProvidersRules.ICLOUD, .DISPATCHARR).
    @MainActor private static var answered = Set<String>()
    @MainActor static func markAnswered(_ id: String) { answered.insert(id) }
    @MainActor static func wasAnswered(_ id: String) -> Bool { answered.contains(id) }
    @MainActor static func filterOffers(_ offers: [String]) -> [String] { offers.filter { !wasAnswered($0) } }

    /// The Welcome card selections of the last Continue, restored after a Cancel on the setup prompt.
    @MainActor private(set) static var kept: (cloud: Bool, dispatcharr: Bool)?
    @MainActor static func keepSelection(cloud: Bool, dispatcharr: Bool) { kept = (cloud, dispatcharr) }

    @MainActor private static var returnedFromChoice = false
    @MainActor static func markReturnedFromChoice() { returnedFromChoice = true }
    /// True once after a setup prompt Cancel, so Welcome does not auto-advance on the restored playlist.
    @MainActor static func consumeReturnedFromChoice() -> Bool {
        defer { returnedFromChoice = false }
        return returnedFromChoice
    }
}

/// Keeps the onboarding cover up while the Welcome chain runs: RootView dismisses
/// onboarding as soon as a playlist exists, which would cut the chain off after
/// the restore or the connect.
@MainActor
final class OnboardingHold: ObservableObject {
    static let shared = OnboardingHold()
    @Published private(set) var holding = false
    private init() {}

    func begin(_ why: String) {
        guard !holding else { return }
        holding = true
        debugLog("[SYNC] onboarding chain start: \(why)")
    }

    func end(_ why: String) {
        guard holding else { return }
        holding = false
        debugLog("[SYNC] onboarding chain end: \(why)")
    }
}
