import Foundation
import UserNotifications

@MainActor
enum Notifications {
    static func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    static func rebuild(shows: [Show], includeSpecials: Bool, demo: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("watchmate.") }.map(\.identifier))
        guard !demo else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let now = Date()
        let candidates = shows.filter { $0.isFollowing && $0.notificationsEnabled }.flatMap { show in
            show.episodes.filter {
                $0.watchedAt == nil && !$0.isSkipped && (includeSpecials || $0.season > 0)
                    && $0.firstAired.map { $0 > now } == true
            }.map { (show.title, $0) }
        }.sorted { $0.1.firstAired! < $1.1.firstAired! }
        // iOS has a finite local notification budget; schedule the nearest dates.
        for (title, episode) in candidates.prefix(60) {
            guard let date = episode.firstAired else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(title) · \(episode.label)"
            content.body = "Scheduled air date for \(episode.title). Check your streaming service for availability."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSince(now)), repeats: false)
            let request = UNNotificationRequest(identifier: "watchmate.\(episode.key)", content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
