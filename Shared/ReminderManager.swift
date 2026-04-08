import Foundation
import UserNotifications

/// In-app banner data for foreground reminder display.
struct ReminderBanner: Equatable {
    let title: String
    let channel: String
}

/// Rich reminder data stored per program key.
struct ReminderInfo: Codable, Equatable {
    let notificationID: String   // device-local notification UUID
    let programTitle: String
    let channelName: String
    let startTime: Date          // program start time
    let updatedAt: Date          // when this reminder was created/modified
}

/// Syncable reminder data (excludes device-specific notification ID).
/// Used by SyncManager for iCloud KVS push/pull.
struct SyncableReminder: Equatable {
    let programTitle: String
    let channelName: String
    let startTime: Date
    let updatedAt: Date
}

/// Manages program reminders via local notifications.
/// On iOS, reminders fire 5 minutes before a program's start time.
/// When the app is in the foreground, an in-app banner is shown instead.
/// On tvOS, UNNotificationContent properties are unavailable, so reminders
/// are tracked in state only (no push banner) — useful if a future tvOS
/// version or companion app consumes them.
///
/// Supports iCloud sync via SyncManager — when reminders change locally,
/// posts `.remindersDidChange` so SyncManager pushes to KVS. When remote
/// reminders arrive, `mergeRemote(_:)` schedules local notifications.
@MainActor
final class ReminderManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = ReminderManager()

    private let storageKey = "programReminders"

    /// Maps program key → reminder info for active reminders.
    @Published private(set) var activeReminders: [String: ReminderInfo] = [:]

    /// In-app banner to display when a reminder fires while app is in foreground.
    @Published var pendingBanner: ReminderBanner?

    private override init() {
        super.init()
        loadReminders()
        #if os(iOS)
        UNUserNotificationCenter.current().delegate = self
        #endif
    }

    // MARK: - Storage

    private func loadReminders() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }

        // Try new format: [String: ReminderInfo]
        if let dict = try? JSONDecoder().decode([String: ReminderInfo].self, from: data) {
            activeReminders = dict
            return
        }

        // Migrate from old format: [String: String] (key → notificationID only)
        if let oldDict = try? JSONDecoder().decode([String: String].self, from: data) {
            activeReminders = migrateOldFormat(oldDict)
            persist()
            debugLog("🔔 ReminderManager: migrated \(activeReminders.count) reminders to rich format")
        }
    }

    /// Converts legacy [key → notificationID] entries to [key → ReminderInfo]
    /// by parsing the channel, title, and timestamp from the program key.
    private func migrateOldFormat(_ dict: [String: String]) -> [String: ReminderInfo] {
        var result: [String: ReminderInfo] = [:]
        for (key, notifID) in dict {
            let parts = key.split(separator: "|", maxSplits: 2)
            guard parts.count == 3 else { continue }
            result[key] = ReminderInfo(
                notificationID: notifID,
                programTitle: String(parts[1]),
                channelName: String(parts[0]),
                startTime: Date(timeIntervalSinceReferenceDate: TimeInterval(String(parts[2])) ?? 0),
                updatedAt: Date()
            )
        }
        return result
    }

    /// Unique key for a program (channel + title + start).
    static func programKey(channelName: String, title: String, start: Date) -> String {
        "\(channelName)|\(title)|\(Int(start.timeIntervalSinceReferenceDate))"
    }

    func hasReminder(forKey key: String) -> Bool {
        activeReminders[key] != nil
    }

    // MARK: - Schedule / Cancel

    /// Request notification permission and schedule a reminder.
    func scheduleReminder(programTitle: String, channelName: String, startTime: Date) {
        let key = Self.programKey(channelName: channelName, title: programTitle, start: startTime)
        guard activeReminders[key] == nil else { return }

        #if os(iOS)
        Task {
            let notifCenter = UNUserNotificationCenter.current()
            let granted = try? await notifCenter.requestAuthorization(options: [.alert, .sound])
            guard granted == true else { return }

            let content = UNMutableNotificationContent()
            content.title = programTitle
            content.body = "\(programTitle) starts in 5 minutes on \(channelName)"
            content.sound = .default

            let fireDate = startTime.addingTimeInterval(-5 * 60)
            guard fireDate > Date() else { return }

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = UUID().uuidString
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

            try? await notifCenter.add(request)
            await MainActor.run {
                let mgr = ReminderManager.shared
                mgr.activeReminders[key] = ReminderInfo(
                    notificationID: id,
                    programTitle: programTitle,
                    channelName: channelName,
                    startTime: startTime,
                    updatedAt: Date()
                )
                mgr.persist()
                mgr.notifySyncManager()
            }
        }
        #else
        // tvOS: track reminder in state (no notification banner available)
        let id = UUID().uuidString
        activeReminders[key] = ReminderInfo(
            notificationID: id,
            programTitle: programTitle,
            channelName: channelName,
            startTime: startTime,
            updatedAt: Date()
        )
        persist()
        notifySyncManager()
        #endif
    }

    /// Cancel a previously scheduled reminder.
    func cancelReminder(forKey key: String) {
        guard let info = activeReminders.removeValue(forKey: key) else { return }
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [info.notificationID])
        #endif
        persist()
        notifySyncManager()
    }

    // MARK: - iCloud Sync

    /// Called by SyncManager when remote reminder data arrives from iCloud.
    /// Merges remote state with local, scheduling/cancelling local
    /// notifications as needed. Does NOT post `.remindersDidChange`
    /// (SyncManager sets `isMerging` to prevent push loops).
    func mergeRemote(_ remoteReminders: [String: SyncableReminder]) {
        let localKeys = Set(activeReminders.keys)
        let remoteKeys = Set(remoteReminders.keys)

        // New from remote — schedule local notifications
        for key in remoteKeys.subtracting(localKeys) {
            guard let remote = remoteReminders[key] else { continue }
            scheduleFromSync(key: key, reminder: remote)
        }

        // Removed on remote — cancel locally
        for key in localKeys.subtracting(remoteKeys) {
            if let info = activeReminders.removeValue(forKey: key) {
                #if os(iOS)
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: [info.notificationID]
                )
                #endif
            }
        }

        // Present on both — most recent updatedAt wins
        for key in localKeys.intersection(remoteKeys) {
            guard let remote = remoteReminders[key],
                  let local = activeReminders[key],
                  remote.updatedAt > local.updatedAt else { continue }
            #if os(iOS)
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: [local.notificationID]
            )
            #endif
            scheduleFromSync(key: key, reminder: remote)
        }

        persist()
        debugLog("🔔 ReminderManager: merged remote (new=\(remoteKeys.subtracting(localKeys).count), removed=\(localKeys.subtracting(remoteKeys).count))")
    }

    /// Returns syncable data for SyncManager to push to iCloud KVS.
    var syncableReminders: [String: SyncableReminder] {
        activeReminders.mapValues { info in
            SyncableReminder(
                programTitle: info.programTitle,
                channelName: info.channelName,
                startTime: info.startTime,
                updatedAt: info.updatedAt
            )
        }
    }

    // MARK: - Private Helpers

    /// Schedule a local notification from a synced remote reminder.
    private func scheduleFromSync(key: String, reminder: SyncableReminder) {
        let id = UUID().uuidString
        activeReminders[key] = ReminderInfo(
            notificationID: id,
            programTitle: reminder.programTitle,
            channelName: reminder.channelName,
            startTime: reminder.startTime,
            updatedAt: reminder.updatedAt
        )

        #if os(iOS)
        let fireDate = reminder.startTime.addingTimeInterval(-5 * 60)
        guard fireDate > Date() else { return }

        Task {
            let notifCenter = UNUserNotificationCenter.current()
            let granted = try? await notifCenter.requestAuthorization(options: [.alert, .sound])
            guard granted == true else { return }

            let content = UNMutableNotificationContent()
            content.title = reminder.programTitle
            content.body = "\(reminder.programTitle) starts in 5 minutes on \(reminder.channelName)"
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await notifCenter.add(request)
        }
        #endif
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(activeReminders) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Notify SyncManager that reminders changed locally.
    private func notifySyncManager() {
        NotificationCenter.default.post(name: .remindersDidChange, object: nil)
    }
}

// MARK: - UNUserNotificationCenterDelegate (foreground banner)

#if os(iOS)
extension ReminderManager: UNUserNotificationCenterDelegate {
    /// Called when a notification fires while the app is in the foreground.
    /// Shows an in-app banner instead of the OS notification banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let title = content.title
        let body = content.body

        Task { @MainActor in
            // Extract channel name from body ("X starts in 5 minutes on ChannelName")
            let channel: String
            if let range = body.range(of: " on ", options: .backwards) {
                channel = String(body[range.upperBound...])
            } else {
                channel = ""
            }
            ReminderManager.shared.pendingBanner = ReminderBanner(title: title, channel: channel)
        }

        // Play the notification sound, but don't show the OS banner (we handle it in-app)
        completionHandler([.sound])
    }
}
#endif
