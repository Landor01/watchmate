import Foundation

enum RefreshPolicy {
    static func isStale(_ date: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= interval
    }

    static func refreshAutomatically(status: String?, updatedAt: Date?, attemptedAt: Date?, now: Date) -> Bool {
        // Being caught up is not the same as a series ending: returning shows
        // still need new episode announcements even when all known episodes are watched.
        guard status != "Ended", status != "Canceled" else { return false }
        return isStale(updatedAt, interval: 86_400, now: now)
            && isStale(attemptedAt, interval: 86_400, now: now)
    }
}
