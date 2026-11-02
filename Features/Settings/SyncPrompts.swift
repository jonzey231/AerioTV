//  SyncPrompts.swift
//  Aerio
//
//  The Dispatcharr Sync coexistence prompts shared by Settings > Sync and
//  onboarding (Dispatcharr Sync port, part 4). Ports of the Android
//  feature/onboarding/SetupSourceDialog.kt ("Which setup should this device
//  start from?"), BackupUpdateStepScreen.kt ("Your backup needs an
//  update", as a step and as the Settings dialog), and the BackupUpdateOffer
//  session flags from core/sync/SetupSourceChoice.kt. Android's Google Drive
//  is iCloud here; every other string is Android's, word for word.
//
//  Buttons are never disabled mid-flow (tvOS focus would fall away); taps
//  are ignored while busy instead.

import SwiftUI

// MARK: - Backup update offer (session flags)

/// When to offer the one-time iCloud id update. Session flags live in process
/// memory per base user (playlist id): "Not now" keeps the old format until the
/// next app session; onboarding never shows it twice, and Settings offers it at
/// most once per app session. Android BackupUpdateOffer.
@MainActor
enum BackupUpdateOffer {
    private static var declined = Set<String>()
    private static var settingsShown = Set<String>()

    /// A restore found an old-format backup (any playlist type).
    static func shouldOffer(backupOutdated: Bool, accepted: Bool, playlistId: String) -> Bool {
        backupOutdated && !accepted && !declined.contains(playlistId)
    }

    /// Settings (iCloud Sync on): the same rule, once per app session.
    static func shouldOfferInSettings(cloudOn: Bool, backupOutdated: Bool, accepted: Bool, playlistId: String) -> Bool {
        cloudOn && !settingsShown.contains(playlistId) && shouldOffer(backupOutdated: backupOutdated, accepted: accepted, playlistId: playlistId)
    }

    static func markSettingsShown(_ playlistId: String) { settingsShown.insert(playlistId) }
    static func decline(_ playlistId: String) {
        declined.insert(playlistId)
        debugLog("[CLOUD] backup update declined (not now)")
    }

    /// Onboarding after a restore: the key to offer the update for, or nil.
    static func offerAfterRestore() -> String? {
        guard let key = CloudSnapshotSync.shared.refreshUpdateOffer() else { return nil }
        return shouldOffer(backupOutdated: true, accepted: false, playlistId: key) ? key : nil
    }

    /// Sync screen open with iCloud Sync on: the key to offer for (marks the session), or nil.
    static func offerForSettings(cloudOn: Bool) -> String? {
        guard cloudOn, let key = CloudSnapshotSync.shared.refreshUpdateOffer() else { return nil }
        guard shouldOfferInSettings(cloudOn: true, backupOutdated: true, accepted: false, playlistId: key) else { return nil }
        markSettingsShown(key)
        return key
    }
}

// MARK: - Shared platform flags

private var syncPromptIsTV: Bool {
    #if os(tvOS)
    return true
    #else
    return false
    #endif
}

// MARK: - "Your backup needs an update"

/// The backup update content: a full-screen onboarding step, or (inDialog) the
/// same content inside the Settings sheet surface.
struct BackupUpdateStepView: View {
    let busy: Bool
    let onUpdate: () -> Void
    let onNotNow: () -> Void
    var inDialog: Bool = false

    var body: some View {
        let content = VStack(spacing: syncPromptIsTV ? 20 : 12) {
            Text(SetupSourceChoice.UPDATE_TITLE)
                .scaledFont(syncPromptIsTV ? .system(size: 38, weight: .semibold) : .headlineLarge)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(SetupSourceChoice.UPDATE_BODY)
                .scaledFont(syncPromptIsTV ? .system(size: 24).subtext() : .bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SyncStepPrimaryButton(title: SetupSourceChoice.UPDATE_ACCEPT, busy: busy) {
                if !busy { onUpdate() }
            }
            .padding(.top, 8)
            SyncStepSecondaryButton(title: SetupSourceChoice.UPDATE_NOT_NOW) {
                if !busy { onNotNow() }
            }
        }
        .frame(maxWidth: syncPromptIsTV ? 900 : 520)
        if inDialog {
            content.padding(24)
        } else {
            SyncStepFrame { content }
        }
    }
}

/// Centered, scrollable frame every onboarding sync step uses.
struct SyncStepFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, syncPromptIsTV ? 80 : 20)
                    .padding(.vertical, syncPromptIsTV ? 60 : 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
        }
    }
}

/// Filled Capsule CTA. tvOS: white ring on focus (primary action rule).
struct SyncStepPrimaryButton: View {
    let title: String
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        let tv = syncPromptIsTV
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                        .scaledFont(.system(size: tv ? 26 : 17, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: tv ? 66 : 54)
            .background(Capsule(style: .continuous).fill(LinearGradient.accentGradient))
            .contentShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle(isSelected: true))
        .tvFocusRingShape(.capsule)
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(title)
        .accessibilityValue(busy ? "In progress" : "")
    }
}

/// Outlined Capsule button. tvOS: theme-accent ring on focus.
struct SyncStepSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        let tv = syncPromptIsTV
        Button(action: action) {
            Text(title)
                .scaledFont(.system(size: tv ? 26 : 17, weight: .medium))
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: tv ? 66 : 54)
                .background(Capsule(style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        .tvFocusRingShape(.capsule)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - "Which setup should this device start from?"

/// Rule 4 prompt (phone, tablet, and TV): two radio cards, Dispatcharr
/// preselected (SetupSourceChoice.defaultSelection), Continue applies the
/// selection, Cancel backs out. Present it in a sheet with interactive dismiss off.
struct SetupSourcePromptView: View {
    let cloud: SetupSourceChoice.Summary
    let dsync: SetupSourceChoice.Summary
    var busy: Bool = false
    let onContinue: (SetupSourceChoice.Source) -> Void
    let onCancel: () -> Void

    @State private var selected: SetupSourceChoice.Source
    @State private var now = Int64(Date().timeIntervalSince1970 * 1000)
    #if os(tvOS)
    private enum Field: Hashable { case dispatcharr, cloud }
    @FocusState private var focus: Field?
    #endif

    init(cloud: SetupSourceChoice.Summary, dsync: SetupSourceChoice.Summary, busy: Bool = false,
         onContinue: @escaping (SetupSourceChoice.Source) -> Void, onCancel: @escaping () -> Void) {
        self.cloud = cloud
        self.dsync = dsync
        self.busy = busy
        self.onContinue = onContinue
        self.onCancel = onCancel
        _selected = State(initialValue: SetupSourceChoice.defaultSelection(cloud: cloud, dsync: dsync))
    }

    var body: some View {
        let tv = syncPromptIsTV
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: tv ? 18 : 12) {
                    Text(SetupSourceChoice.TITLE)
                        .scaledFont(tv ? .system(size: 36, weight: .semibold) : .headlineLarge)
                        .foregroundColor(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    SetupSourceCard(title: SetupSourceChoice.DISPATCHARR, summary: dsync, now: now,
                                    selected: selected == .dispatcharr) { selected = .dispatcharr }
                        #if os(tvOS)
                        .focused($focus, equals: .dispatcharr)
                        #endif
                    SetupSourceCard(title: SetupSourceChoice.ICLOUD, summary: cloud, now: now,
                                    selected: selected == .cloud) { selected = .cloud }
                        #if os(tvOS)
                        .focused($focus, equals: .cloud)
                        #endif
                    Text(SetupSourceChoice.FOOTER)
                        .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        SyncStepSecondaryButton(title: SetupSourceChoice.CANCEL) { if !busy { onCancel() } }
                        SyncStepPrimaryButton(title: SetupSourceChoice.CONTINUE, busy: busy) { if !busy { onContinue(selected) } }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: tv ? 900 : 560)
                .frame(maxWidth: .infinity)
                .padding(tv ? 60 : 24)
            }
        }
        #if os(tvOS)
        .defaultFocus($focus, .dispatcharr)
        #endif
        .interactiveDismissDisabled(true)
        .onAppear {
            now = Int64(Date().timeIntervalSince1970 * 1000)
            debugLog("[SYNC] setup source prompt shown default=\(selected == .dispatcharr ? "Dispatcharr" : "Cloud")")
        }
    }
}

/// One side of the setup prompt: radio mark, name, updated line, count line.
private struct SetupSourceCard: View {
    let title: String
    let summary: SetupSourceChoice.Summary
    let now: Int64
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        let tv = syncPromptIsTV
        let updated = SetupSourceChoice.updatedLine(summary.updatedAt, nowMs: now)
        let counts = SetupSourceChoice.countLine(summary)
        Button(action: onSelect) {
            HStack(spacing: tv ? 18 : 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .scaledFont(.system(size: tv ? 30 : 22))
                    .foregroundColor(selected ? .accentPrimary : Color.contrastText(.textTertiary))
                VStack(alignment: .leading, spacing: tv ? 4 : 2) {
                    Text(title)
                        .scaledFont(tv ? .system(size: 26, weight: .semibold) : .headlineSmall)
                        .foregroundColor(.textPrimary)
                    Text(updated)
                        .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                    Text(counts)
                        .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, tv ? 24 : 14)
            .padding(.vertical, tv ? 18 : 12)
            .background(OnboardingCardBackground(highlighted: selected))
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle(isSelected: selected))
        .tvFocusRingShape(.rounded(18))
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(updated), \(counts)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Settings action status

/// Point-in-time result of a Settings > Sync manual action (Android ActionStatus).
enum SyncActionStatus: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)

    var isRunning: Bool { self == .running }

    var line: String? {
        switch self {
        case .success(let m), .failure(let m): return m
        default: return nil
        }
    }

    var isError: Bool { if case .failure = self { return true } else { return false } }
}

/// Android SyncSettingsViewModel result strings.
enum DsyncManualCopy {
    static let PUSHED_TO_DISPATCHARR = "Pushed to Dispatcharr"
    static let PULLED_FROM_DISPATCHARR = "Pulled from Dispatcharr"
    static let PUSHED_TO_BOTH = "Pushed to both"
    static let DISPATCHARR_UNREACHABLE = "Could not reach your Dispatcharr server"
}

/// The result line under a manual action row; in the accessibility tree as static text.
struct SyncActionStatusLine: View {
    let status: SyncActionStatus

    var body: some View {
        if let line = status.line {
            Text(line)
                .scaledFont(syncPromptIsTV ? .system(size: 20) : .labelSmall)
                .foregroundColor(status.isError ? .statusLive : .accentPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, syncPromptIsTV ? 24 : 0)
                .accessibilityLabel(line)
        }
    }
}
