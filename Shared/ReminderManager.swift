import Foundation
import UserNotifications

/// Manages program reminders via local notifications.
/// On iOS, reminders fire 5 minutes before a program's start time.
/// On tvOS, UNNotificationContent properties are unavailable, so reminders
/// are tracked in state only (no push banner) — useful if a future tvOS
/// version or companion app consumes them.
@MainActor
final class ReminderManager: ObservableObject {
    static let shared = ReminderManager()

    private let storageKey = "programReminders"

    /// Maps program key → notification identifier for active reminders.
    @Published private(set) var activeReminders: [String: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            activeReminders = dict
        }
    }

    /// Unique key for a program (channel + title + start).
    static func programKey(channelName: String, title: String, start: Date) -> String {
        "\(channelName)|\(title)|\(Int(start.timeIntervalSinceReferenceDate))"
    }

    func hasReminder(forKey key: String) -> Bool {
        activeReminders[key] != nil
    }

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

            // Fire 5 minutes before start
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
                ReminderManager.shared.activeReminders[key] = id
                ReminderManager.shared.persist()
            }
        }
        #else
        // tvOS: track reminder in state (no notification banner available)
        let id = UUID().uuidString
        activeReminders[key] = id
        persist()
        #endif
    }

    /// Cancel a previously scheduled reminder.
    func cancelReminder(forKey key: String) {
        guard let id = activeReminders.removeValue(forKey: key) else { return }
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        #endif
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(activeReminders) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
