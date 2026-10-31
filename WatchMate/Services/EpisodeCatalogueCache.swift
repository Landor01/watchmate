import Foundation

/// Public episode metadata only; watched progress always comes from the current account.
enum EpisodeCatalogueCache {
    struct Snapshot: Codable {
        let updatedAt: Date
        let episodes: [RemoteEpisode]
        var seriesStatus: String? = nil
    }

    private static func url(_ showID: Int) -> URL {
        URL.applicationSupportDirectory.appending(path: "EpisodeCatalogues", directoryHint: .isDirectory)
            .appending(path: "\(showID).json")
    }

    static func read(_ showID: Int) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(showID)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ episodes: [RemoteEpisode], showID: Int, now: Date = Date(), seriesStatus: String? = nil) {
        let destination = url(showID)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(updatedAt: now, episodes: episodes, seriesStatus: seriesStatus ?? read(showID)?.seriesStatus)).write(to: destination, options: .atomic)
        } catch { /* A cache write must not discard a successful catalogue response. */ }
    }
}
