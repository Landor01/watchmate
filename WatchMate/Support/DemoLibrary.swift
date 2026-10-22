import Foundation
import SwiftData
import UIKit

/// Bundled, offline programme information with sample viewing progress.
enum DemoLibrary {
    private struct Library: Decodable {
        let calendarDate: String
        let shows: [Programme]
    }

    private struct Programme: Decodable {
        let id: Int
        let title: String
        let overview: String
        let posterPath: String?
        let providers: [Provider]
        let watchURL: String?
        let episodes: [Chapter]
    }

    private struct Chapter: Decodable {
        let season: Int
        let number: Int
        let title: String
        let overview: String
        let airDate: String?
        let runtime: Int?
        let artwork: String?
        let watched: Bool
    }

    private static let library: Result<Library, Error> = Result {
        guard let url = Bundle.main.url(forResource: "DemoLibrary", withExtension: "json") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
    }

    static var calendarDate: Date {
        guard let fixture = try? library.get() else { return Date() }
        return Dates.parse(fixture.calendarDate + "T12:00:00Z") ?? Date()
    }

    @MainActor
    static func image(for path: String?) -> UIImage? {
        guard let path, path.hasPrefix("fixture:") else { return nil }
        let filename = String(path.dropFirst("fixture:".count))
        guard filename == (filename as NSString).lastPathComponent else { return nil }
        return UIImage(named: "demo-" + (filename as NSString).deletingPathExtension)
    }

    static func artwork(for episodeKey: String) -> String? {
        guard episodeKey.hasPrefix("-"), let fixture = try? library.get() else { return nil }
        for show in fixture.shows {
            if let chapter = show.episodes.first(where: {
                "\(show.id):\($0.season):\($0.number)" == episodeKey
            }) {
                return chapter.artwork
            }
        }
        return nil
    }

    @MainActor
    static func seed(in context: ModelContext) throws {
        let fixture = try library.get()
        for source in fixture.shows {
            // Keep local fixture identifiers separate from real Trakt IDs.
            // Artwork and metadata are bundled, so demo mode needs no network.
            let show = Show(traktID: source.id, tmdbID: nil, title: source.title)
            show.overview = source.overview
            show.posterPath = source.posterPath
            show.providers = source.providers
            show.providerRegion = "GB"
            show.watchURL = source.watchURL
            context.insert(show)
            for chapter in source.episodes {
                let remote = RemoteEpisode(
                    season: chapter.season, number: chapter.number, title: chapter.title,
                    ids: IDs(trakt: source.id * 1000 - chapter.number, tmdb: nil),
                    overview: chapter.overview,
                    firstAired: chapter.airDate.map { $0 + "T00:00:00Z" },
                    runtime: chapter.runtime
                )
                let episode = Episode(showID: show.traktID, remote: remote)
                if chapter.watched, let aired = episode.firstAired, AirDates.hasAired(aired) {
                    episode.watchedAt = min(aired.addingTimeInterval(86_400), Date())
                }
                context.insert(episode)
                show.episodes.append(episode)
            }
        }
        try context.save()
    }
}
