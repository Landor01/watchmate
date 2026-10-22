import Foundation
import UserNotifications

@MainActor
enum Notifications {
    // Device-only preference; per-show reminder choices still sync through iCloud.
    static var deviceRemindersEnabled: Bool {
        UserDefaults.standard.object(forKey: "deviceRemindersEnabled") as? Bool ?? true
    }

    static func hasPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    static func reminderDate(firstAired: Date, minutes: Int, now: Date,
                             calendar: Calendar = .current) -> Date? {
        guard (0..<1440).contains(minutes),
              let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                       second: 0, of: firstAired),
              calendar.isDate(date, inSameDayAs: firstAired), date > now else { return nil }
        return date
    }

    private static var rebuildGeneration = 0

    static func rebuild(shows: [Show], includeSpecials: Bool, demo: Bool) async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard generation == rebuildGeneration else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("watchmate.") }.map(\.identifier))
        guard !demo, deviceRemindersEnabled else { return }
        let settings = await center.notificationSettings()
        guard generation == rebuildGeneration,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let now = Date()
        let candidates = shows.filter { $0.isFollowing && $0.notificationsEnabled }.flatMap { show in
            show.episodes.compactMap { episode -> (String, Episode, Date)? in
                guard episode.watchedAt == nil, !episode.isSkipped,
                      includeSpecials || episode.season > 0,
                      let firstAired = episode.firstAired,
                      let date = reminderDate(firstAired: firstAired, minutes: show.reminderMinutes, now: now)
                else { return nil }
                return (show.title, episode, date)
            }
        }.sorted { $0.2 < $1.2 }
        // iOS has a finite local notification budget; schedule the nearest dates.
        for (title, episode, date) in candidates.prefix(60) {
            guard deviceRemindersEnabled, generation == rebuildGeneration else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(title) · \(episode.label)"
            content.body = "Scheduled air date for \(episode.title). Check your streaming service for availability."
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: "watchmate.\(episode.key)", content: content, trigger: trigger)
            try? await center.add(request)
            // Disabling reminders may happen while adding a request is suspended.
            if !deviceRemindersEnabled {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                return
            }
        }
    }
}
