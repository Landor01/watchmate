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

    @Test func ordinaryLibraryPathsDoNotUseDemoArtwork() {
        #expect(DemoLibrary.image(for: "/real-poster.jpg") == nil)
        #expect(DemoLibrary.image(for: "fixture:../image.jpg") == nil)
        #expect(DemoLibrary.artwork(for: "123:1:4") == nil)
    }
}
