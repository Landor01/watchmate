import Foundation
import Testing
import SwiftData
@testable import WatchMate

@Suite(.serialized)
@MainActor
struct SharedTraktProgressTests {
    @Test func settingDefaultsOnAndRetainsExplicitOff() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "sharedShowsUpdateTraktHistory")
        defer { defaults.set(original, forKey: "sharedShowsUpdateTraktHistory") }
        defaults.removeObject(forKey: "sharedShowsUpdateTraktHistory")
        #expect(Settings().sharedShowsUpdateTraktHistory)
        let settings = Settings()
        settings.sharedShowsUpdateTraktHistory = false
        #expect(!Settings().sharedShowsUpdateTraktHistory)
    }

    @Test(arguments: [true, false])
    func sharedHistoryWritesOnlyWhenStateChanges(watched: Bool) async throws {
        let defaults = UserDefaults.standard
        let revision = defaults.object(forKey: "historyRevision")
        defer { defaults.set(revision, forKey: "historyRevision") }
        let container = try ModelContainer(for: Show.self, Episode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = ProgressViewingService()
        service.watched = !watched
        let store = AppStore(context: container.mainContext, settings: Settings(), viewing: service)
        let remote = RemoteEpisode(season: 1, number: 2, title: nil, ids: IDs(trakt: 42, tmdb: nil),
                                   overview: nil, firstAired: nil, runtime: nil)
        let show = Show(traktID: 7, tmdbID: nil, title: "Test")
        let episode = Episode(showID: 7, remote: remote)
        container.mainContext.insert(show)
        show.episodes.append(episode)
        try container.mainContext.save()

        try await store.updateTraktProgress(remote, showID: 7, watched: watched)
        try await store.updateTraktProgress(remote, showID: 7, watched: watched)
        #expect(service.writes == [watched])
        #expect((episode.watchedAt != nil) == watched)
    }

    @Test func sharedOnlyShowUpdatesTraktWithoutLocalCatalogue() async throws {
        let defaults = UserDefaults.standard
        let revision = defaults.object(forKey: "historyRevision")
        defer { defaults.set(revision, forKey: "historyRevision") }
        let container = try ModelContainer(for: Show.self, Episode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = ProgressViewingService()
        let store = AppStore(context: container.mainContext, settings: Settings(), viewing: service)
        let remote = RemoteEpisode(season: 1, number: 2, title: nil, ids: IDs(trakt: 42, tmdb: nil),
                                   overview: nil, firstAired: nil, runtime: nil)
        try await store.updateTraktProgress(remote, showID: 7, watched: true)
        #expect(service.writes == [true])
    }
}

@MainActor
private final class ProgressViewingService: ViewingService {
    var watched = false
    var writes: [Bool] = []
    func accountID() async throws -> String { "test" }
    func watchedShows() async throws -> [WatchedShow] {
        guard watched else { return [] }
        return [WatchedShow(show: RemoteShow(title: "Test", year: nil, ids: IDs(trakt: 7, tmdb: nil)),
                            seasons: [WatchedSeason(number: 1, episodes: [
                                WatchedEpisode(number: 2, lastWatchedAt: Dates.string(Date()))
                            ])])]
    }
    func watchlist() async throws -> [RemoteShow] { [] }
    func episodes(showID: Int) async throws -> [RemoteEpisode] { [] }
    func search(_ query: String) async throws -> [RemoteShow] { [] }
    func follow(_ show: RemoteShow) async throws {}
    func setWatched(episodeID: Int, watched: Bool) async throws {
        #expect(episodeID == 42)
        writes.append(watched)
        self.watched = watched
    }
}

struct SharedHistoryTests {
    private func remote(_ id: Int, season: Int = 1, number: Int) -> RemoteEpisode {
        RemoteEpisode(season: season, number: number, title: nil, ids: IDs(trakt: id, tmdb: nil),
                      overview: nil, firstAired: nil, runtime: nil)
    }

    private func shared(_ id: Int, season: Int = 1, number: Int) -> SharedEpisode {
        SharedEpisode(id: id, season: season, number: number, watchedAt: Date(timeIntervalSince1970: 100))
    }

    @Test func inviteeAheadMustUnwatchExtraEpisodes() throws {
        let changes = try SharedHistoryPlan.changes(shared: [shared(1, number: 1)],
                                                   watched: ["1:1", "1:2", "1:3"],
                                                   catalogue: [remote(1, number: 1), remote(2, number: 2), remote(3, number: 3)])
        #expect(changes.map(\.id) == [2, 3])
        #expect(changes.allSatisfy { !$0.watched })
    }

    @Test func equalCountsWithDifferentGapsRequireBothKindsOfChange() throws {
        let changes = try SharedHistoryPlan.changes(shared: [shared(2, number: 2)],
                                                   watched: ["1:1"], catalogue: [remote(1, number: 1), remote(2, number: 2)])
        #expect(changes.map(\.id) == [1, 2])
        #expect(changes.map(\.watched) == [false, true])
    }

    @Test func includesSpecialsAndMultipleSeasons() throws {
        let changes = try SharedHistoryPlan.changes(shared: [shared(30, season: 3, number: 1),
                                                             shared(10, season: 0, number: 1),
                                                             shared(20, season: 2, number: 1)],
                                                   watched: [], catalogue: [])
        #expect(changes.map(\.id) == [10, 20, 30])
        #expect(changes.allSatisfy { $0.watched })
    }

    @Test func matchingHistoryNeedsNoWritesOrDuplicateWatches() throws {
        let changes = try SharedHistoryPlan.changes(shared: [shared(1, number: 1)],
                                                   watched: ["1:1"], catalogue: [remote(1, number: 1)])
        #expect(changes.isEmpty)
    }

    @Test func retryAfterPartialImportSkipsAlreadyAppliedChanges() throws {
        let changes = try SharedHistoryPlan.changes(shared: [shared(1, number: 1), shared(2, number: 2)],
                                                   watched: ["1:1"], catalogue: [remote(1, number: 1), remote(2, number: 2)])
        #expect(changes.map(\.id) == [2])
        #expect(changes[0].watched)
    }

    @Test func emptySharedHistoryClearsInviteeProgress() throws {
        let changes = try SharedHistoryPlan.changes(shared: [], watched: ["1:1"],
                                                   catalogue: [remote(1, number: 1)])
        #expect(changes.count == 1)
        #expect(changes.first?.watched == false)
    }

    @Test func missingCatalogueEpisodeFailsBeforeAnyDestructiveWork() {
        #expect(throws: APIError.self) {
            try SharedHistoryPlan.changes(shared: [], watched: ["1:99"], catalogue: [remote(1, number: 1)])
        }
    }

    @Test func duplicateSharedEntriesAreNotWrittenTwice() throws {
        let episode = shared(1, number: 1)
        let changes = try SharedHistoryPlan.changes(shared: [episode, episode], watched: [], catalogue: [])
        #expect(changes.count == 1)
        #expect(changes.first?.episode.watchedAt == episode.watchedAt)
    }
}
