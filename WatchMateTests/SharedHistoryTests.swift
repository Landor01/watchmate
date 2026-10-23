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

    private func withBatchStore(_ operation: (AppStore, ModelContainer, BatchViewingService) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["demoMode", "sharedShowsUpdateTraktHistory", "traktAccountID", "historyRevision"]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originals) { defaults.set(value, forKey: key) }
        }
        let settings = Settings()
        settings.demoMode = false
        settings.sharedShowsUpdateTraktHistory = false
        settings.traktAccountID = nil
        let container = try ModelContainer(for: Show.self, Episode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = BatchViewingService()
        let store = AppStore(context: container.mainContext, settings: settings, viewing: service)
        store.connected = false
        try await operation(store, container, service)
    }

    @Test func seasonUsesOneBatchSkipsExistingAndFutureAndShowsProgressWithoutProviders() async throws {
        try await withBatchStore { store, container, service in
            let show = Show(traktID: 7, tmdbID: nil, title: "No streaming services")
            container.mainContext.insert(show)
            let past = Date().addingTimeInterval(-86_400)
            let future = Date().addingTimeInterval(7 * 86_400)
            for number in 1...4 {
                let remote = RemoteEpisode(season: 1, number: number, title: "Episode",
                                           ids: IDs(trakt: number, tmdb: nil), overview: nil,
                                           firstAired: Dates.string(number == 4 ? future : past), runtime: 45)
                show.episodes.append(Episode(showID: 7, remote: remote))
            }
            show.episodes.first { $0.number == 2 }?.isSkipped = true
            try container.mainContext.save()
            service.watchedNumbers = [1]
            service.onBatch = {
                #expect(store.busy)
                #expect(store.seasonUpdateInProgress)
                #expect(store.seasonUpdateTotal == 3)
                #expect(store.seasonUpdateCompleted == 0)
            }
            await store.markSeasonWatched(show, season: 1)
            #expect(service.historyReads == 1)
            #expect(service.batches == [[2, 3]])
            #expect(service.singleWrites == 0)
            #expect(show.episodes.filter { $0.watchedAt != nil }.count == 3)
            #expect(show.episodes.first { $0.number == 2 }?.isSkipped == false)
            #expect(show.episodes.first { $0.number == 4 }?.watchedAt == nil)
            #expect(store.seasonUpdateCompleted == 3)
            #expect(!store.seasonUpdateInProgress && !store.busy)
            #expect(store.errorMessage == nil)

            await store.markSeasonWatched(show, season: 1)
            #expect(service.batches.count == 1) // Retrying must not add repeat plays.
        }
    }

    @Test func partialBatchOnlyChangesConfirmedEpisodes() async throws {
        try await withBatchStore { store, container, service in
            let show = Show(traktID: 7, tmdbID: nil, title: "Test")
            container.mainContext.insert(show)
            for number in 1...2 {
                show.episodes.append(Episode(showID: 7, remote: RemoteEpisode(
                    season: 1, number: number, title: nil, ids: IDs(trakt: number, tmdb: nil),
                    overview: nil, firstAired: nil, runtime: nil)))
            }
            try container.mainContext.save()
            service.rejectedIDs = [2]
            await store.markSeasonWatched(show, season: 1)
            #expect(show.episodes.first { $0.number == 1 }?.watchedAt != nil)
            #expect(show.episodes.first { $0.number == 2 }?.watchedAt == nil)
            #expect(store.seasonUpdateCompleted == 1)
            #expect(store.errorMessage != nil)
            #expect(!store.busy && !store.seasonUpdateInProgress)
        }
    }

    @Test func failedBatchLeavesLocalHistoryUnchangedAndClosesProgress() async throws {
        try await withBatchStore { store, container, service in
            let show = Show(traktID: 7, tmdbID: nil, title: "Test")
            container.mainContext.insert(show)
            let episode = Episode(showID: 7, remote: RemoteEpisode(
                season: 1, number: 1, title: nil, ids: IDs(trakt: 1, tmdb: nil),
                overview: nil, firstAired: nil, runtime: nil))
            show.episodes.append(episode)
            try container.mainContext.save()
            service.shouldFail = true
            await store.markSeasonWatched(show, season: 1)
            #expect(episode.watchedAt == nil)
            #expect(store.errorMessage != nil)
            #expect(!store.busy && !store.seasonUpdateInProgress)
        }
    }

    @Test func sharedOnlyBatchNeedsOneHistoryReadAndPreservesExistingWatchDate() async throws {
        try await withBatchStore { store, _, service in
            service.watchedNumbers = [1]
            let episodes = (1...3).map { number in
                RemoteEpisode(season: 1, number: number, title: nil, ids: IDs(trakt: number, tmdb: nil),
                              overview: nil, firstAired: nil, runtime: nil)
            }
            let confirmed = try await store.markTraktEpisodesWatched(episodes, showID: 7)
            #expect(confirmed.count == 3)
            #expect(confirmed[1] == Dates.parse("2026-01-01T12:00:00Z"))
            #expect(service.historyReads == 1)
            #expect(service.batches == [[2, 3]])
        }
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
    func markWatched(episodeIDs: [Int]) async throws -> Set<Int> {
        for id in episodeIDs { try await setWatched(episodeID: id, watched: true) }
        return Set(episodeIDs)
    }
    func setWatched(episodeID: Int, watched: Bool) async throws {
        #expect(episodeID == 42)
        writes.append(watched)
        self.watched = watched
    }
}

@MainActor
private final class BatchViewingService: ViewingService {
    var historyReads = 0
    var singleWrites = 0
    var batches: [[Int]] = []
    var watchedNumbers: Set<Int> = []
    var rejectedIDs: Set<Int> = []
    var shouldFail = false
    var onBatch: (() -> Void)?

    func accountID() async throws -> String { "test" }
    func watchedShows() async throws -> [WatchedShow] {
        historyReads += 1
        return [WatchedShow(show: RemoteShow(title: "Test", year: nil, ids: IDs(trakt: 7, tmdb: nil)),
                            seasons: [WatchedSeason(number: 1, episodes: watchedNumbers.sorted().map {
                                WatchedEpisode(number: $0, lastWatchedAt: "2026-01-01T12:00:00Z")
                            })])]
    }
    func watchlist() async throws -> [RemoteShow] { [] }
    func episodes(showID: Int) async throws -> [RemoteEpisode] { [] }
    func search(_ query: String) async throws -> [RemoteShow] { [] }
    func follow(_ show: RemoteShow) async throws {}
    func setWatched(episodeID: Int, watched: Bool) async throws { singleWrites += 1 }
    func markWatched(episodeIDs: [Int]) async throws -> Set<Int> {
        onBatch?()
        batches.append(episodeIDs)
        if shouldFail { throw APIError.message("Simulated failure") }
        let accepted = Set(episodeIDs).subtracting(rejectedIDs)
        watchedNumbers.formUnion(accepted)
        return accepted
    }
}

struct TraktHistoryBatchTests {
    @Test func payloadIsOneDeduplicatedEpisodeArrayWithWatchDates() throws {
        let payload = TraktHistoryBatch.payload(episodeIDs: [3, 1, 3], watchedAt: Date(timeIntervalSince1970: 100))
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let episodes = try #require(decoded["episodes"] as? [[String: Any]])
        #expect(episodes.count == 2)
        #expect(episodes.compactMap { ($0["ids"] as? [String: Int])?["trakt"] } == [1, 3])
        #expect(episodes.allSatisfy { $0["watched_at"] as? String == Dates.string(Date(timeIntervalSince1970: 100)) })
        #expect(decoded["shows"] == nil) // Never implicitly mark unaired/unselected episodes.
    }

    @Test func partialResponseReturnsOnlyAcceptedIDs() throws {
        let data = Data(#"{"added":{"episodes":1},"not_found":{"episodes":[{"ids":{"trakt":2}}]}}"#.utf8)
        #expect(try TraktHistoryBatch.confirmedIDs(in: data, requestedIDs: [1, 2]) == [1])
    }

    @Test func inconsistentResponseDoesNotClaimSuccess() {
        let data = Data(#"{"added":{"episodes":0},"not_found":{"episodes":[]}}"#.utf8)
        #expect(throws: (any Error).self) {
            try TraktHistoryBatch.confirmedIDs(in: data, requestedIDs: [1, 2])
        }
    }

    @Test func unknownMissingIDsDoNotClaimSuccess() {
        let data = Data(#"{"added":{"episodes":1},"not_found":{"episodes":[{"ids":{"trakt":999}}]}}"#.utf8)
        #expect(throws: (any Error).self) {
            try TraktHistoryBatch.confirmedIDs(in: data, requestedIDs: [1])
        }
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
