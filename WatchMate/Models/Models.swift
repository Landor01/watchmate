import Foundation
import SwiftData

@Model
final class Show {
    @Attribute(.unique) var traktID: Int
    var tmdbID: Int?
    var imdbID: String?
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
    // Minutes after local midnight; independent of the catalogue's broadcast time.
    var reminderMinutes: Int = 540
    @Relationship(deleteRule: .cascade, inverse: \Episode.show) var episodes: [Episode] = []

    init(traktID: Int, tmdbID: Int?, title: String, imdbID: String? = nil) {
        self.traktID = traktID; self.tmdbID = tmdbID; self.title = title
        self.imdbID = imdbID
    }

    var imdbURL: URL? {
        IDs(trakt: traktID, tmdb: tmdbID, imdb: imdbID).imdbURL
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
    static func isComplete(_ episodes: [EpisodeState], includeSpecials: Bool) -> Bool {
        let included = episodes.filter { includeSpecials || $0.season > 0 }
        return !included.isEmpty && included.allSatisfy { $0.watched }
    }

    static func isUpToDate(_ episodes: [EpisodeState], now: Date, includeSpecials: Bool) -> Bool {
        let included = episodes.filter { includeSpecials || $0.season > 0 }
        return !included.isEmpty && !isComplete(included, includeSpecials: true)
            && included.allSatisfy {
                $0.watched || $0.firstAired.map { !AirDates.hasAired($0, now: now) } == true
            }
    }

    static func isCaughtUp(_ episodes: [EpisodeState], now: Date, includeSpecials: Bool) -> Bool {
        let included = episodes.filter { includeSpecials || $0.season > 0 }
        guard !included.isEmpty else { return false }
        return included.allSatisfy {
            $0.watched || $0.skipped || $0.firstAired.map { !AirDates.hasAired($0, now: now) } == true
        }
    }

    // The set of unwatched episodes matters: subtracting counts loses gaps and rewatches.
    static func waiting(_ episodes: [EpisodeState], now: Date, includeSpecials: Bool) -> [EpisodeState] {
        episodes.filter {
            !$0.watched && !$0.skipped && (includeSpecials || $0.season > 0)
                && $0.firstAired.map { AirDates.hasAired($0, now: now) } == true
        }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }
    static func upcoming(_ episodes: [EpisodeState], now: Date, days: Int = 30, includeSpecials: Bool) -> [EpisodeState] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: AirDates.day(now)) ?? now
        return episodes.filter {
            !$0.watched && !$0.skipped && (includeSpecials || $0.season > 0)
                && $0.firstAired.map { !AirDates.hasAired($0, now: now) && AirDates.day($0) <= end } == true
        }.sorted { AirDates.day($0.firstAired!) < AirDates.day($1.firstAired!) }
    }
}

extension Episode {
    var isScheduledInFuture: Bool {
        firstAired.map { !AirDates.hasAired($0) } ?? false
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

struct IDs: Codable {
    let trakt: Int
    let tmdb: Int?
    var imdb: String? = nil

    var imdbURL: URL? {
        guard let imdb, imdb.hasPrefix("tt"),
              !imdb.dropFirst(2).isEmpty,
              imdb.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "https://www.imdb.com/title/\(imdb)/")
    }
}
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
