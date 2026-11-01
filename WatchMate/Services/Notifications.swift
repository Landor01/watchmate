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

    /// Preserve other notification types and leave identical reminders untouched.
    static func changes(pending: [UNNotificationRequest], desired: [UNNotificationRequest])
        -> (removing: [String], adding: [UNNotificationRequest]) {
        let desiredIDs = Set(desired.map(\.identifier))
        let existing = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let removing = pending.filter {
            $0.identifier.hasPrefix("watchmate.") && !desiredIDs.contains($0.identifier)
        }.map(\.identifier)
        let adding = desired.filter { request in
            guard let old = existing[request.identifier],
                  let oldTrigger = old.trigger as? UNCalendarNotificationTrigger,
                  let newTrigger = request.trigger as? UNCalendarNotificationTrigger else { return true }
            return !old.content.isEqual(request.content)
                || oldTrigger.dateComponents != newTrigger.dateComponents
                || oldTrigger.repeats != newTrigger.repeats
        }
        return (removing, adding)
    }

    private static var rebuildGeneration = 0
    private static var rebuildTask: Task<Void, Never>?

    static func rebuild(shows: [Show], sharedProgrammes: [SharedProgramme] = [], includeSpecials: Bool, demo: Bool) async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let previous = rebuildTask
        let task = Task { @MainActor in
            // Let any in-flight add finish before reading the system's pending requests.
            await previous?.value
            guard generation == rebuildGeneration else { return }
            await reconcile(shows: shows, sharedProgrammes: sharedProgrammes,
                            includeSpecials: includeSpecials, demo: demo, generation: generation)
        }
        rebuildTask = task
        await task.value
        if generation == rebuildGeneration { rebuildTask = nil }
    }

    private static func reconcile(shows: [Show], sharedProgrammes: [SharedProgramme],
                                  includeSpecials: Bool, demo: Bool, generation: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard generation == rebuildGeneration else { return }
        let ownedIDs = pending.filter { $0.identifier.hasPrefix("watchmate.") }.map(\.identifier)
        guard !demo, deviceRemindersEnabled else {
            center.removePendingNotificationRequests(withIdentifiers: ownedIDs)
            return
        }
        let settings = await center.notificationSettings()
        guard generation == rebuildGeneration else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: ownedIDs)
            return
        }
        let now = Date()
        let sharedByID = Dictionary(grouping: sharedProgrammes, by: \.id)
        let candidates = shows.filter { ($0.isFollowing || sharedByID[$0.traktID] != nil) && $0.notificationsEnabled }.flatMap { show in
            show.episodes.compactMap { episode -> (String, Episode, Date)? in
                let needsReminder: Bool
                if let programmes = sharedByID[show.traktID] {
                    needsReminder = programmes.contains { programme in
                        !programme.episodes.contains { $0.season == episode.season && $0.number == episode.number }
                            && !(programme.skippedEpisodeIDs?.contains(episode.traktID) ?? false)
                    }
                } else {
                    needsReminder = episode.watchedAt == nil && !episode.isSkipped
                }
                guard needsReminder,
                      includeSpecials || episode.season > 0,
                      let firstAired = episode.firstAired,
                      let date = reminderDate(firstAired: firstAired, minutes: show.reminderMinutes, now: now)
                else { return nil }
                return (show.title, episode, date)
            }
        }.sorted { $0.2 < $1.2 }
        // iOS has a finite local notification budget; schedule the nearest dates.
        let desired = candidates.prefix(60).map { title, episode, date in
            let content = UNMutableNotificationContent()
            content.title = "\(title) · \(episode.label)"
            content.body = "Scheduled air date for \(episode.title). Check your streaming service for availability."
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            return UNNotificationRequest(identifier: "watchmate.\(episode.key)", content: content, trigger: trigger)
        }
        guard generation == rebuildGeneration else { return }
        let changes = changes(pending: pending, desired: desired)
        if !changes.removing.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: changes.removing)
        }
        for request in changes.adding {
            guard deviceRemindersEnabled, generation == rebuildGeneration else { return }
            try? await center.add(request)
            // Disabling reminders may happen while adding a request is suspended.
            if !deviceRemindersEnabled {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                return
            }
        }
    }
}
