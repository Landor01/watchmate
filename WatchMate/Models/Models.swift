import Foundation
import SwiftData

@Model
final class Show {
    @Attribute(.unique) var traktID: Int
    var tmdbID: Int?
    var title: String
    var overview: String = ""
    var posterPath: String?
    var providerData: Data = Data()
    var watchURL: String?
    var providerRegion: String = ""
    var metadataUpdatedAt: Date?
    var catalogueUpdatedAt: Date?
    var isFollowing: Bool = true
    var notificationsEnabled: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \Episode.show) var episodes: [Episode] = []

    init(traktID: Int, tmdbID: Int?, title: String) {
        self.traktID = traktID; self.tmdbID = tmdbID; self.title = title
    }
    // Load episodes with their shows so UI access does not fault the relationship per row.
    static var withEpisodes: FetchDescriptor<Show> {
        var descriptor = FetchDescriptor<Show>(sortBy: [SortDescriptor(\Show.title)])
        descriptor.relationshipKeyPathsForPrefetching = [\Show.episodes]
        return descriptor
    }

    var providers: [Provider] {
        get { (try? JSONDecoder().decode([Provider].self, from: providerData)) ?? [] }
        set { providerData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

@Model
final class Episode {
    @Attribute(.unique) var key: String
    var traktID: Int
    var season: Int
    var number: Int
    var title: String
    var overview: String
    var firstAired: Date?
    var runtime: Int?
    var watchedAt: Date?
    var isSkipped: Bool = false
    var show: Show?

    init(showID: Int, remote: RemoteEpisode) {
        key = "\(showID):\(remote.season):\(remote.number)"
        traktID = remote.ids.trakt; season = remote.season; number = remote.number
        title = remote.title ?? "Episode \(remote.number)"
        overview = remote.overview ?? ""; firstAired = Dates.parse(remote.firstAired)
        runtime = remote.runtime
    }
    var label: String { "S\(season) E\(number)" }
}

struct Provider: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
}

struct EpisodeState: Equatable {
    let season: Int
    let number: Int
    let firstAired: Date?
    let watched: Bool
    let skipped: Bool
}

enum EpisodeRules {
    // The set of unwatched episodes matters: subtracting counts loses gaps and rewatches.
    static func waiting(_ episodes: [EpisodeState], now: Date, includeSpecials: Bool) -> [EpisodeState] {
        episodes.filter {
            !$0.watched && !$0.skipped && (includeSpecials || $0.season > 0)
                && $0.firstAired.map { $0 <= now } == true
        }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }
    static func upcoming(_ episodes: [EpisodeState], now: Date, days: Int = 30, includeSpecials: Bool) -> [EpisodeState] {
        let end = now.addingTimeInterval(Double(days) * 86_400)
        return episodes.filter {
            !$0.watched && !$0.skipped && (includeSpecials || $0.season > 0)
                && $0.firstAired.map { $0 > now && $0 <= end } == true
        }.sorted { $0.firstAired! < $1.firstAired! }
    }
}

extension Episode {
    var isScheduledInFuture: Bool {
        firstAired.map { $0 > Date() } ?? false
    }

    var state: EpisodeState {
        EpisodeState(season: season, number: number, firstAired: firstAired,
                     watched: watchedAt != nil, skipped: isSkipped)
    }
}

enum Dates {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

struct IDs: Codable { let trakt: Int; let tmdb: Int? }
struct RemoteShow: Codable, Identifiable {
    let title: String
    let year: Int?
    let ids: IDs
    var id: Int { ids.trakt }
}
struct RemoteEpisode: Codable {
    let season: Int
    let number: Int
    let title: String?
    let ids: IDs
    let overview: String?
    let firstAired: String?
    let runtime: Int?
}
struct RemoteSeason: Decodable { let number: Int; let episodes: [RemoteEpisode]? }
struct WatchedEpisode: Decodable { let number: Int; let lastWatchedAt: String? }
struct WatchedSeason: Decodable { let number: Int; let episodes: [WatchedEpisode] }
struct WatchedShow: Decodable { let show: RemoteShow; let seasons: [WatchedSeason] }
struct ListedShow: Decodable { let show: RemoteShow }
struct SearchResult: Decodable { let show: RemoteShow? }
struct CatalogueDetails {
    let overview: String
    let posterPath: String?
    let providers: [Provider]
    let watchURL: String?
}
