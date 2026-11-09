import Testing
import SwiftData
@testable import WatchMate

@MainActor
struct DemoLibraryTests {
    @Test func bundledLibraryLoadsWithOfflineArtwork() throws {
        let container = try ModelContainer(
            for: Show.self, Episode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        try DemoLibrary.seed(in: container.mainContext)
        let shows = try container.mainContext.fetch(Show.withEpisodes)
        #expect(shows.count == 6)
        #expect(shows.allSatisfy { $0.traktID < 0 && $0.tmdbID == nil })
        for show in shows {
            #expect(DemoLibrary.image(for: show.posterPath) != nil)
            #expect(!show.episodes.isEmpty)
            #expect(show.episodes.contains { $0.watchedAt != nil })
            #expect(show.episodes.contains { $0.watchedAt == nil })
            for episode in show.episodes {
                #expect(episode.show === show)
                #expect(DemoLibrary.image(for: DemoLibrary.artwork(for: episode.key)) != nil)
            }
        }
        let severance = try #require(shows.first { $0.title == "Severance" })
        let episode = try #require(severance.episodes.first { $0.number == 4 })
        #expect(episode.title == "The You You Are")
        #expect(episode.firstAired == Dates.parse("2022-03-03T00:00:00Z"))
    }

    @Test func existingDemoLibraryReceivesMissingEpisodesWithoutResettingProgress() throws {
        let container = try ModelContainer(
            for: Show.self, Episode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = container.mainContext
        try DemoLibrary.seed(in: context)
        let shows = try context.fetch(Show.withEpisodes)
        let show = try #require(shows.first { $0.title == "Severance" })
        let existing = try #require(show.episodes.first { $0.number == 4 })
        existing.isSkipped = true
        let upcoming = try #require(show.episodes.first { $0.number == 10 })
        let upcomingKey = upcoming.key
        let originalCount = show.episodes.count
        show.episodes.removeAll { $0.key == upcomingKey }
        context.delete(upcoming)
        try context.save()

        try DemoLibrary.seed(in: context)
        try DemoLibrary.seed(in: context)

        #expect(try context.fetch(Show.withEpisodes).count == shows.count)
        #expect(show.episodes.count == originalCount)
        #expect(show.episodes.filter { $0.key == upcomingKey }.count == 1)
        #expect(existing.isSkipped)
        #expect(existing.watchedAt == nil)
    }

    @Test func sharedDemoProgressIsOfflineAndSeparateFromPersonalProgress() async throws {
        let container = try ModelContainer(
            for: Show.self, Episode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        try DemoLibrary.seed(in: container.mainContext)
        let shows = try container.mainContext.fetch(Show.withEpisodes)
        let service = SharedShows()
        service.prepareDemo(shows: shows)
        #expect(service.lists.count == 2)
        #expect(service.lists.allSatisfy { !$0.programmes.isEmpty })
        #expect(service.historyOffers.isEmpty)
        #expect(service.personalShowIDs.isEmpty)
        let personalIDs = Set(shows.filter {
            !service.showIDs.contains($0.traktID) || service.personalShowIDs.contains($0.traktID)
        }.map(\.traktID))
        #expect(personalIDs == [-5])
        #expect(personalIDs.isDisjoint(with: service.showIDs))
        #expect(Set(shows.flatMap(\.episodes).map(\.key)).count == shows.flatMap(\.episodes).count)
        let list = try #require(service.lists.first)
        let show = try #require(shows.first { $0.traktID == -1 })
        let episode = try #require(show.episodes.first { $0.number == 4 })
        let remote = RemoteEpisode(season: episode.season, number: episode.number, title: episode.title,
                                   ids: IDs(trakt: episode.traktID, tmdb: nil), overview: episode.overview,
                                   firstAired: episode.firstAired.map { Dates.string($0) }, runtime: episode.runtime)

        try await service.updateEpisodes([remote], showID: show.traktID, in: list, action: .skipped(true))
        #expect(service.lists.first?.programmes.first?.skippedEpisodeIDs?.contains(episode.traktID) == true)
        try await service.updateEpisodes([remote], showID: show.traktID, in: list, action: .watched(true))
        service.prepareDemo(shows: shows)
        await service.refresh()
        let programme = try #require(service.lists.first?.programmes.first)
        #expect(programme.episodes.contains { $0.id == episode.traktID })
        #expect(programme.skippedEpisodeIDs?.contains(episode.traktID) == false)
        #expect(episode.watchedAt == nil)
        #expect(!episode.isSkipped)
        try await service.setNotes("Next Friday", for: programme, in: list)
        #expect(service.lists.first?.programmes.first?.notes == "Next Friday")

        service.activate(accountID: nil)
        #expect(!service.isDemo)
        #expect(service.lists.isEmpty)
    }

    @Test func ordinaryLibraryPathsDoNotUseDemoArtwork() {
        #expect(DemoLibrary.image(for: "/real-poster.jpg") == nil)
        #expect(DemoLibrary.image(for: "fixture:../image.jpg") == nil)
        #expect(DemoLibrary.artwork(for: "123:1:4") == nil)
    }
}
