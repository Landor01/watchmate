import Foundation
import Testing
@testable import WatchMate

struct WidgetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func episode(_ number: Int, season: Int = 1, offset: TimeInterval = -60) -> WidgetEpisode {
        WidgetEpisode(id: "12:\(season):\(number)", season: season, number: number,
                      title: "Episode \(number)", overview: "Synopsis", firstAired: now.addingTimeInterval(offset),
                      runtime: 45)
    }

    @Test func selectsEpisodeOrderRatherThanAirDateOrder() {
        let show = WidgetShow(id: 12, title: "Example", episodes: [
            episode(3, offset: -300), episode(1, offset: -10), episode(2, offset: -200)
        ])
        #expect(show.nextEpisode(at: now)?.number == 1)
    }

    @Test func retainsGapsInViewingHistory() {
        let show = WidgetShow(id: 12, title: "Example", episodes: [episode(5), episode(2), episode(6)])
        #expect(show.nextEpisode(at: now)?.number == 2)
    }

    @Test func futureEpisodeBecomesAvailableAtAirTime() {
        let show = WidgetShow(id: 12, title: "Example", episodes: [episode(1, offset: 60)])
        #expect(show.nextEpisode(at: now) == nil)
        #expect(show.nextAirDate(after: now) == now.addingTimeInterval(60))
        #expect(show.nextEpisode(at: now.addingTimeInterval(60))?.number == 1)
    }

    @Test func noEpisodesMeansCaughtUp() {
        let show = WidgetShow(id: 12, title: "Example", episodes: [])
        #expect(show.nextEpisode(at: now) == nil)
        #expect(show.nextAirDate(after: now) == nil)
    }

    @Test func nextAirDateExcludesPastDatesAndUsesEarliestFutureDate() {
        let show = WidgetShow(id: 12, title: "Example", episodes: [
            episode(1), episode(2, offset: 600), episode(3, offset: 120)
        ])
        #expect(show.nextAirDate(after: now) == now.addingTimeInterval(120))
    }

    @Test func seasonOrderMatchesUpNextRules() {
        let source = [episode(1, season: 2), episode(4), episode(1, season: 0)]
        let states = source.map {
            EpisodeState(season: $0.season, number: $0.number, firstAired: $0.firstAired,
                         watched: false, skipped: false)
        }
        let expected = EpisodeRules.waiting(states, now: now, includeSpecials: true).first
        let show = WidgetShow(id: 12, title: "Example", episodes: source)
        #expect(show.nextEpisode(at: now)?.season == expected?.season)
        #expect(show.nextEpisode(at: now)?.number == expected?.number)
    }

    @Test func snapshotRoundTripPreservesAccountEpisodeArtworkAndError() throws {
        let original = WidgetLibrary(
            accountScope: "test-account",
            shows: [WidgetShow(id: 12, title: "Example", episodes: [episode(2)], posterPath: "/poster.jpg")],
            errorShowID: 12, errorMessage: "Try again"
        )
        let decoded = try JSONDecoder().decode(WidgetLibrary.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.shows.first?.nextEpisode(at: now)?.id == "12:1:2")
    }

    @Test func episodeLinkRoundTripPreservesExactEpisodeAndAccount() throws {
        let link = WidgetEpisodeLink(episodeKey: "-1:2:7", accountScope: "account & name")
        let url = try #require(link.url)
        #expect(WidgetEpisodeLink(url: url) == link)
    }

    @Test func episodeLinkRejectsUnrelatedAndMalformedURLs() throws {
        let invalid = [
            "https://episode?key=1:1:1&account=demo",
            "watchmate://other?key=1:1:1&account=demo",
            "watchmate://episode?key=1:1:1",
            "watchmate://episode?key=1:-1:1&account=demo",
            "watchmate://episode?key=1:1:0&account=demo",
            "watchmate://episode?key=1:1:1&key=2:2:2&account=demo",
            "watchmate://episode?key=invalid&account=demo"
        ]
        for value in invalid {
            #expect(WidgetEpisodeLink(url: try #require(URL(string: value))) == nil)
        }
    }

    @Test func artworkRejectsNonEpisodePaths() {
        #expect(throws: WidgetActionError.self) {
            try WidgetArtworkStore.url(for: "../../private")
        }
    }
}
