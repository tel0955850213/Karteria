import Foundation
import UserNotifications

enum PracticeReminderService {
    enum Result: Equatable {
        case scheduled
        case disabled
        case denied
    }

    static func apply(
        goalID: UUID,
        schedule: PracticeSchedule,
        isEnabled: Bool
    ) async -> Result {
        let center = UNUserNotificationCenter.current()
        let identifiers = (1...7).map { reminderIdentifier(goalID: goalID, weekday: $0) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        guard isEnabled else { return .disabled }

        let settings = await center.notificationSettings()
        let authorization: UNAuthorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                authorization = try await center.requestAuthorization(options: [.alert, .sound]) ? .authorized : .denied
            } catch {
                return .denied
            }
        default:
            authorization = settings.authorizationStatus
        }
        guard authorization == .authorized || authorization == .provisional else { return .denied }

        for weekday in schedule.weekdays {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = schedule.preferredHour
            components.minute = 0
            let content = UNMutableNotificationContent()
            content.title = "Karteria"
            content.body = "A two-minute deliberate rep still counts."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(
                identifier: reminderIdentifier(goalID: goalID, weekday: weekday),
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                return .denied
            }
        }
        return .scheduled
    }

    static func removeAll(for goalID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (1...7).map { reminderIdentifier(goalID: goalID, weekday: $0) }
        )
    }

    private static func reminderIdentifier(goalID: UUID, weekday: Int) -> String {
        "karteria-practice-\(goalID.uuidString)-\(weekday)"
    }
}
