import Foundation
import Observation

struct SharedDiscoveryEntry: Identifiable {
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

    func load(store: AppStore, shows: [Show], forceRefresh: Bool = false) async {
        loading = true
        message = nil
        defer { loading = false }
        let ids = store.sharedShows.showIDs
        episodes = episodes.filter { ids.contains($0.key) }
        for id in ids.sorted() {
            let cached = EpisodeCatalogueCache.read(id)
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
            if let cached = EpisodeCatalogueCache.read(id) {
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
                episodes[id] = fetched
            } catch {
                if Task.isCancelled { return }
                message = "Some shared episode details could not load. Pull to refresh."
            }
        }
    }
}
