import Foundation
import Testing
@testable import WatchMate

struct SharedProgrammeProgressTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func episode(_ id: Int, season: Int, runtime: Int? = 45, future: Bool = false) -> RemoteEpisode {
        RemoteEpisode(season: season, number: id, title: "Episode",
                      ids: IDs(trakt: id, tmdb: nil), overview: nil,
                      firstAired: Dates.string(now.addingTimeInterval(future ? 86_400 : -86_400)), runtime: runtime)
    }
    private func programme(watched: [SharedEpisode] = [], skipped: Set<Int> = []) -> SharedProgramme {
        SharedProgramme(show: RemoteShow(title: "Test", year: nil, ids: IDs(trakt: 1, tmdb: nil)),
                        addedBy: "owner", episodes: watched, skippedEpisodeIDs: skipped)
    }

    @Test func seasonOrderSeparatesReadyUpcomingAndCompleted() {
        let episodes = [episode(1, season: 1), episode(2, season: 2), episode(3, season: 3, future: true), episode(4, season: 4)]
        let show = programme(watched: [SharedEpisode(id: 1, season: 1, number: 1, watchedAt: now)], skipped: [4])
        let progress = SharedProgrammeProgress(episodes: episodes, programme: show, includeSpecials: true, now: now)
        #expect(progress.ready.map(\.id) == [2])
        #expect(progress.upcoming.map(\.id) == [3])
        #expect(progress.completed.map(\.id) == [1, 4])
    }

    @Test func timeLeftExcludesSkippedFutureAndWatchedEpisodes() {
        let episodes = [episode(1, season: 1, runtime: 30), episode(2, season: 1, runtime: 40),
                        episode(3, season: 1, runtime: 50), episode(4, season: 1, runtime: 60, future: true)]
        let show = programme(watched: [SharedEpisode(id: 1, season: 1, number: 1, watchedAt: now)], skipped: [3])
        let progress = SharedProgrammeProgress(episodes: episodes, programme: show, includeSpecials: true, now: now)
        #expect(progress.watchedCount == 1)
        #expect(progress.watchedMinutes == 30)
        #expect(progress.remainingMinutes == 40)
        #expect(progress.unknownRemainingRuntimes == 0)
    }

    @Test func unknownRuntimesAreReportedInsteadOfEstimated() {
        let episodes = [episode(1, season: 1, runtime: nil), episode(2, season: 1, runtime: 0), episode(3, season: 1, runtime: 25)]
        let show = programme(watched: [SharedEpisode(id: 1, season: 1, number: 1, watchedAt: now)])
        let progress = SharedProgrammeProgress(episodes: episodes, programme: show, includeSpecials: true, now: now)
        #expect(progress.watchedMinutes == 0)
        #expect(progress.unknownWatchedRuntimes == 1)
        #expect(progress.remainingMinutes == 25)
        #expect(progress.unknownRemainingRuntimes == 1)
    }

    @Test func unskippingReopensACompletedSeason() {
        let episodes = [episode(1, season: 1)]
        let skipped = SharedProgrammeProgress(episodes: episodes, programme: programme(skipped: [1]), includeSpecials: true, now: now)
        let unskipped = SharedProgrammeProgress(episodes: episodes, programme: programme(), includeSpecials: true, now: now)
        #expect(skipped.completed.map(\.id) == [1])
        #expect(skipped.remainingMinutes == 0)
        #expect(unskipped.completed.isEmpty)
        #expect(unskipped.ready.map(\.id) == [1])
        #expect(unskipped.remainingMinutes == 45)
    }

    @Test func specialsSettingAppliesToSeasonsAndTimeTotals() {
        let episodes = [episode(1, season: 0, runtime: 20), episode(2, season: 1, runtime: 45)]
        let progress = SharedProgrammeProgress(episodes: episodes, programme: programme(), includeSpecials: false, now: now)
        #expect(progress.ready.map(\.id) == [1])
        #expect(progress.remainingMinutes == 45)
    }

    @Test func existingSharedPayloadWithoutSkippedEpisodesStillDecodes() throws {
        let data = Data(#"{"show":{"title":"Test","ids":{"trakt":1}},"addedBy":"owner","episodes":[],"revision":"existing"}"#.utf8)
        let decoded = try JSONDecoder().decode(SharedProgramme.self, from: data)
        #expect(decoded.skippedEpisodeIDs == nil)
        #expect(decoded.revision == "existing")
    }

    @Test func skippingDoesNotBecomeATraktWatch() throws {
        let show = programme(skipped: [1])
        let decoded = try JSONDecoder().decode(SharedProgramme.self, from: JSONEncoder().encode(show))
        let changes = try SharedHistoryPlan.changes(shared: decoded.episodes, watched: [], catalogue: [episode(1, season: 1)])
        #expect(decoded.skippedEpisodeIDs == [1])
        #expect(changes.isEmpty)
    }
}
