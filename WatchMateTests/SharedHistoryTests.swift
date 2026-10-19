import Foundation
import Testing
@testable import WatchMate

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
