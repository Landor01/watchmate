import Foundation
import CryptoKit
import Observation

struct SharedDiscoveryEntry: Identifiable, Codable {
    let listID: String
    let listName: String
    let showID: Int
    let title: String
    let episode: RemoteEpisode
    let watched: Bool
    let skipped: Bool
    var tmdbID: Int? = nil
    var id: String { "\(listID):\(showID):\(episode.ids.trakt)" }
    var date: Date? { Dates.parse(episode.firstAired).map { AirDates.day($0) } }

    static func entries(lists: [HouseholdList], catalogues: [Int: [RemoteEpisode]],
                        includeSpecials: Bool) -> [SharedDiscoveryEntry] {
        lists.flatMap { list in
            list.programmes.flatMap { programme in
                let watched = Set(programme.episodes.map(\.id))
                return (catalogues[programme.id] ?? []).filter { includeSpecials || $0.season > 0 }.map {
                    SharedDiscoveryEntry(listID: list.id, listName: list.name, showID: programme.id,
                                         title: programme.show.title, episode: $0,
                                         watched: watched.contains($0.ids.trakt),
                                         skipped: programme.skippedEpisodeIDs?.contains($0.ids.trakt) == true,
                                         tmdbID: programme.show.ids.tmdb)
                }
            }
        }
    }

    static func waiting(_ entries: [SharedDiscoveryEntry], now: Date = Date()) -> [SharedDiscoveryEntry] {
        entries.filter { !$0.watched && !$0.skipped && $0.date.map { AirDates.hasAired($0, now: now) } == true }
            .sorted { ($0.episode.season, $0.episode.number, $0.id) < ($1.episode.season, $1.episode.number, $1.id) }
    }

    static func scheduled(_ entries: [SharedDiscoveryEntry]) -> [SharedDiscoveryEntry] {
        entries.filter { !$0.watched && !$0.skipped && $0.date != nil }
    }

    static func next(_ entries: [SharedDiscoveryEntry]) -> [SharedDiscoveryEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert("\($0.listID):\($0.showID)").inserted }
    }
}

@MainActor @Observable
final class SharedDiscoveryCatalogue {
    private(set) var episodes: [Int: [RemoteEpisode]] = [:]
    private(set) var loading = false
    private(set) var message: String?
    @ObservationIgnored private var loadRevision = 0

    func load(store: AppStore, shows: [Show], forceRefresh: Bool = false) async {
        loadRevision += 1
        let revision = loadRevision
        loading = true
        message = nil
        defer { if loadRevision == revision { loading = false } }
        let ids = store.sharedShows.showIDs
        episodes = episodes.filter { ids.contains($0.key) }
        for id in ids.sorted() {
            let cached = await EpisodeCatalogueCache.read(id)
            guard !Task.isCancelled, revision == loadRevision else { return }
            let localDate = shows.first { $0.traktID == id }?.catalogueUpdatedAt ?? .distantPast
            if !forceRefresh, let cached, cached.updatedAt > localDate {
                episodes[id] = cached.episodes
                continue
            }
            if !forceRefresh, let show = shows.first(where: { $0.traktID == id }), show.catalogueUpdatedAt != nil {
                episodes[id] = show.episodes.map {
                    RemoteEpisode(season: $0.season, number: $0.number, title: $0.title,
                                  ids: IDs(trakt: $0.traktID, tmdb: nil), overview: $0.overview,
                                  firstAired: $0.firstAired.map { Dates.string($0) }, runtime: $0.runtime)
                }
                continue
            }
            if let cached {
                episodes[id] = cached.episodes
                if !forceRefresh { continue }
            }
            guard forceRefresh else {
                message = "Some shared episode details aren't saved yet. Pull to refresh or open the programme."
                continue
            }
            do {
                let service = TraktService(auth: store.auth)
                let fetched = forceRefresh ? try await service.refreshEpisodes(showID: id) : try await service.episodes(showID: id)
                try Task.checkCancellation()
                guard revision == loadRevision else { return }
                episodes[id] = fetched
            } catch {
                if Task.isCancelled || revision != loadRevision { return }
                message = "Some shared episode details could not load. Pull to refresh."
            }
        }
    }
}

/// A complete presentation, independent of the live records being refreshed.
/// Display copies are never inserted into SwiftData or used for mutations.
@MainActor
struct UpNextSnapshot: Codable {
    struct PersonalEntry: Identifiable, Codable {
        let show: Show
        let episode: Episode
        let waitingCount: Int
        var id: String { episode.key }

        private struct Saved: Codable {
            let show: RemoteShow
            let episode: RemoteEpisode
            let posterPath: String?
            let providers: [Provider]
            let providerRegion: String
            let waitingCount: Int
        }

        init(show: Show, episode: Episode, waitingCount: Int) {
            self.show = show
            self.episode = episode
            self.waitingCount = waitingCount
        }

        init(from decoder: any Decoder) throws {
            let saved = try Saved(from: decoder)
            show = Show(traktID: saved.show.id, tmdbID: saved.show.ids.tmdb,
                        title: saved.show.title, imdbID: saved.show.ids.imdb)
            show.posterPath = saved.posterPath
            show.providers = saved.providers
            show.providerRegion = saved.providerRegion
            episode = Episode(showID: saved.show.id, remote: saved.episode)
            waitingCount = saved.waitingCount
        }

        func encode(to encoder: any Encoder) throws {
            try Saved(show: RemoteShow(title: show.title, year: nil,
                ids: IDs(trakt: show.traktID, tmdb: show.tmdbID, imdb: show.imdbID)),
                episode: RemoteEpisode(season: episode.season, number: episode.number, title: episode.title,
                    ids: IDs(trakt: episode.traktID, tmdb: nil, imdb: episode.imdbID), overview: episode.overview,
                    firstAired: episode.firstAired.map { Dates.string($0) }, runtime: episode.runtime),
                posterPath: show.posterPath, providers: show.providers,
                providerRegion: show.providerRegion, waitingCount: waitingCount).encode(to: encoder)
        }
    }

    let accountScope: String
    let entries: [PersonalEntry]
    let shared: [SharedDiscoveryEntry]
    let watchedRuntimes: [Int?]
    let waitingRuntimes: [Int?]
    let message: String?

    init(store: AppStore, shows: [Show], catalogues: [Int: [RemoteEpisode]], message: String?) {
        accountScope = store.widgetAccountScope
        let sharedIDs = store.sharedShows.showIDs
        let personalIDs = store.sharedShows.personalShowIDs
        let personal = shows.filter {
            $0.isFollowing && !store.settings.hiddenShowIDs.contains($0.traktID)
                && (!sharedIDs.contains($0.traktID) || personalIDs.contains($0.traktID))
        }
        let waiting = personal.map { (show: $0, episodes: store.waiting($0)) }
        entries = waiting.compactMap { item in
            guard let episode = item.episodes.first else { return nil }
            let show = Show(traktID: item.show.traktID, tmdbID: item.show.tmdbID,
                            title: item.show.title, imdbID: item.show.imdbID)
            show.posterPath = item.show.posterPath
            show.providers = item.show.providers
            show.providerRegion = item.show.providerRegion
            let remote = RemoteEpisode(season: episode.season, number: episode.number, title: episode.title,
                ids: IDs(trakt: episode.traktID, tmdb: nil, imdb: episode.imdbID), overview: episode.overview,
                firstAired: episode.firstAired.map { Dates.string($0) }, runtime: episode.runtime)
            let copy = Episode(showID: show.traktID, remote: remote)
            return PersonalEntry(show: show, episode: copy, waitingCount: item.episodes.count)
        }.sorted { $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending }
        shared = SharedDiscoveryEntry.entries(lists: store.sharedShows.lists, catalogues: catalogues,
                                              includeSpecials: store.settings.includeSpecials)
        watchedRuntimes = personal.flatMap(\.episodes).filter {
            $0.watchedAt != nil && (store.settings.includeSpecials || $0.season > 0)
        }.map(\.runtime) + shared.filter(\.watched).map { $0.episode.runtime }
        waitingRuntimes = waiting.flatMap(\.episodes).map(\.runtime)
            + SharedDiscoveryEntry.waiting(shared).map { $0.episode.runtime }
        self.message = message
    }
}

/// Persist the whole presentation atomically so termination midway through a refresh
/// cannot leave the next launch showing a mixture of old and new sections.
@MainActor
enum UpNextSnapshotCache {
    private struct Saved: Codable {
        let snapshot: UpNextSnapshot
        let includeSpecials: Bool
        let hiddenIDs: Set<Int>
        let region: String
    }

    static func url(scope: String) -> URL {
        let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory.appending(path: "UpNext", directoryHint: .isDirectory)
            .appending(path: key + ".json")
    }

    static func read(scope: String, settings: Settings) -> UpNextSnapshot? {
        guard let data = try? Data(contentsOf: url(scope: scope)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.snapshot.accountScope == scope, saved.includeSpecials == settings.includeSpecials,
              saved.hiddenIDs == settings.hiddenShowIDs, saved.region == settings.region else { return nil }
        return saved.snapshot
    }

    static func save(_ snapshot: UpNextSnapshot, settings: Settings) {
        let file = url(scope: snapshot.accountScope)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let saved = Saved(snapshot: snapshot, includeSpecials: settings.includeSpecials,
                              hiddenIDs: settings.hiddenShowIDs, region: settings.region)
            try JSONEncoder().encode(saved).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* Retain the in-memory presentation if the cache cannot be written. */ }
    }

    static func remove(scope: String) {
        try? FileManager.default.removeItem(at: url(scope: scope))
    }
}
