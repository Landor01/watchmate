import XCTest
@testable import WatchMate

final class EpisodeRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func episode(_ number: Int, season: Int = 1, offset: TimeInterval? = -1, watched: Bool = false, skipped: Bool = false) -> EpisodeState {
        EpisodeState(season: season, number: number, firstAired: offset.map { now.addingTimeInterval($0) }, watched: watched, skipped: skipped)
    }
    func testGapsAreRetainedInsteadOfSubtractingProgress() {
        let states = [episode(1, watched: true), episode(2), episode(3, watched: true), episode(4)]
        XCTAssertEqual(EpisodeRules.waiting(states, now: now, includeSpecials: false).map(\.number), [2, 4])
    }
    func testFutureUnknownDatesSkippedAndSpecialsExcluded() {
        let states = [episode(1, season: 0), episode(1, offset: nil), episode(2, offset: 60), episode(3, skipped: true), episode(4)]
        XCTAssertEqual(EpisodeRules.waiting(states, now: now, includeSpecials: false).map(\.number), [4])
    }
    func testSpecialsAreOptIn() {
        XCTAssertEqual(EpisodeRules.waiting([episode(1, season: 0)], now: now, includeSpecials: true).count, 1)
    }
    func testWholeSeasonDropIncludesAllUnwatchedEpisodes() {
        XCTAssertEqual(EpisodeRules.waiting((1...8).map { episode($0, offset: 0) }, now: now, includeSpecials: false).count, 8)
    }
    func testComingSoonWindowAndChronologicalOrder() {
        let states = [episode(1, offset: 100), episode(2, offset: 50), episode(3, offset: 31 * 86_400), episode(4, offset: 0), episode(5, offset: 10, watched: true)]
        XCTAssertEqual(EpisodeRules.upcoming(states, now: now, includeSpecials: false).map(\.number), [2, 1])
    }
    func testISO8601DatesAcceptFractionalSeconds() {
        XCTAssertNotNil(Dates.parse("2026-10-04T08:00:00.000Z"))
        XCTAssertNotNil(Dates.parse("2026-10-04T08:00:00Z"))
        XCTAssertNil(Dates.parse(nil))
    }
    func testTraktWatchedResponseDecoding() throws {
        let json = #"[{"show":{"title":"Sample","year":2026,"ids":{"trakt":1,"tmdb":2}},"seasons":[{"number":1,"episodes":[{"number":2,"last_watched_at":"2026-10-04T08:00:00Z"}]}]}]"#
        let decoded = try HTTP.decoder.decode([WatchedShow].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.show.ids.tmdb, 2)
        XCTAssertEqual(decoded.first?.seasons.first?.episodes.first?.number, 2)
    }
    func testTokenExpiry() {
        let token = OAuthTokens(accessToken: "test", refreshToken: "test", expiresIn: 3600, createdAt: 100)
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 3700))
    }
}
