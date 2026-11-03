import Foundation

/// Public episode metadata only; watched progress always comes from the current account.
/// Serializes disk access away from the main actor and retains a bounded working set.
actor EpisodeCatalogueCache {
    struct Snapshot: Codable, Sendable {
        let updatedAt: Date
        let episodes: [RemoteEpisode]
        var seriesStatus: String? = nil
    }

    private static let shared = EpisodeCatalogueCache()
    private let directory: URL
    private let capacity: Int
    private var snapshots: [Int: Snapshot] = [:]
    private var recentlyUsed: [Int] = []

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "EpisodeCatalogues", directoryHint: .isDirectory),
         capacity: Int = 32) {
        self.directory = directory
        self.capacity = max(0, capacity)
    }

    static func read(_ showID: Int) async -> Snapshot? {
        await shared.readSnapshot(showID)
    }

    static func releaseMemory() async { await shared.removeAllFromMemory() }

    func removeAllFromMemory() {
        snapshots.removeAll()
        recentlyUsed.removeAll()
    }

    static func save(_ episodes: [RemoteEpisode], showID: Int, now: Date = Date(), seriesStatus: String? = nil) async {
        await shared.saveSnapshot(episodes, showID: showID, now: now, seriesStatus: seriesStatus)
    }

    func readSnapshot(_ showID: Int) -> Snapshot? {
        if let snapshot = snapshots[showID] {
            remember(snapshot, showID: showID)
            return snapshot
        }
        guard let data = try? Data(contentsOf: url(showID)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        remember(snapshot, showID: showID)
        return snapshot
    }

    func saveSnapshot(_ episodes: [RemoteEpisode], showID: Int, now: Date = Date(), seriesStatus: String? = nil) {
        let snapshot = Snapshot(updatedAt: now, episodes: episodes,
                                seriesStatus: seriesStatus ?? readSnapshot(showID)?.seriesStatus)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url(showID), options: .atomic)
        } catch { /* A cache write must not discard a successful catalogue response. */ }
        remember(snapshot, showID: showID)
    }

    private func url(_ showID: Int) -> URL {
        directory.appending(path: "\(showID).json")
    }

    private func remember(_ snapshot: Snapshot, showID: Int) {
        recentlyUsed.removeAll { $0 == showID }
        snapshots[showID] = snapshot
        recentlyUsed.append(showID)
        // Also bound the episode count so unusually large programmes cannot fill the cache.
        while recentlyUsed.count > capacity || snapshots.values.reduce(0, { $0 + $1.episodes.count }) > 10_000 {
            snapshots.removeValue(forKey: recentlyUsed.removeFirst())
        }
    }
}
