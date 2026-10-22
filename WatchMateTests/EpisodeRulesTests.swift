import XCTest
import Testing
@testable import WatchMate

@MainActor
struct ReminderTimeTests {
    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    @Test func chosenTimeIgnoresBroadcastTimeAndIncludesToday() throws {
        let calendar = try calendar("Europe/London")
        let airDate = try #require(Dates.parse("2026-10-22T22:00:00Z"))
        let now = try #require(Dates.parse("2026-10-22T07:00:00Z"))
        let date = try #require(Notifications.reminderDate(firstAired: airDate, minutes: 570, now: now, calendar: calendar))
        #expect(date == Dates.parse("2026-10-22T08:30:00Z"))
        #expect(Notifications.reminderDate(firstAired: airDate, minutes: 570, now: date, calendar: calendar) == nil)
        #expect(Notifications.reminderDate(firstAired: airDate, minutes: 570, now: date.addingTimeInterval(60), calendar: calendar) == nil)
    }

    @Test func daylightSavingAndLocalDate() throws {
        let calendar = try calendar("Europe/London")
        let now = try #require(Dates.parse("2026-03-28T00:00:00Z"))
        let airDate = try #require(Dates.parse("2026-03-29T22:00:00Z"))
        let date = try #require(Notifications.reminderDate(firstAired: airDate, minutes: 540, now: now, calendar: calendar))
        #expect(date == Dates.parse("2026-03-29T08:00:00Z"))
        let missingHour = try #require(Notifications.reminderDate(firstAired: airDate, minutes: 90, now: now, calendar: calendar))
        #expect(calendar.isDate(missingHour, inSameDayAs: airDate))
        #expect(calendar.component(.hour, from: missingHour) == 2)
        #expect(Notifications.reminderDate(firstAired: airDate, minutes: 1440, now: now, calendar: calendar) == nil)
    }

    @Test func showsHaveIndependentReminderTimes() {
        let first = Show(traktID: 1, tmdbID: nil, title: "First")
        let second = Show(traktID: 2, tmdbID: nil, title: "Second")
        #expect(first.reminderMinutes == 540)
        first.reminderMinutes = 1200
        first.notificationsEnabled = false
        #expect(first.reminderMinutes == 1200)
        #expect(second.reminderMinutes == 540)
    }
}

struct MyShowsGroupingTests {
    @Test func completionAndUpcomingEpisodes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let watched = EpisodeState(season: 1, number: 1, firstAired: now, watched: true, skipped: false)
        let future = EpisodeState(season: 1, number: 2, firstAired: now.addingTimeInterval(86_400), watched: false, skipped: false)
        #expect(EpisodeRules.isComplete([watched], includeSpecials: false))
        #expect(!EpisodeRules.isUpToDate([watched], now: now, includeSpecials: false))
        #expect(!EpisodeRules.isComplete([watched, future], includeSpecials: false))
        #expect(EpisodeRules.isUpToDate([watched, future], now: now, includeSpecials: false))
        #expect(!EpisodeRules.isUpToDate([watched, future], now: now.addingTimeInterval(86_400), includeSpecials: false))
    }

    @Test func incompleteUnknownSkippedAndSpecialEpisodes() {
        let now = Date()
        for date in [nil, Optional(now)] {
            let unwatched = EpisodeState(season: 1, number: 1, firstAired: date, watched: false, skipped: true)
            #expect(!EpisodeRules.isComplete([unwatched], includeSpecials: false))
            #expect(!EpisodeRules.isUpToDate([unwatched], now: now, includeSpecials: false))
        }
        let watched = EpisodeState(season: 1, number: 1, firstAired: now, watched: true, skipped: false)
        let special = EpisodeState(season: 0, number: 1, firstAired: now, watched: false, skipped: false)
        #expect(EpisodeRules.isComplete([watched, special], includeSpecials: false))
        #expect(!EpisodeRules.isComplete([watched, special], includeSpecials: true))
        #expect(!EpisodeRules.isComplete([], includeSpecials: false))
        #expect(!EpisodeRules.isUpToDate([], now: now, includeSpecials: false))
    }
}

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
        let states = [episode(1, season: 0), episode(1, offset: nil), episode(2, offset: 86_400), episode(3, skipped: true), episode(4)]
        XCTAssertEqual(EpisodeRules.waiting(states, now: now, includeSpecials: false).map(\.number), [4])
    }
    func testSpecialsAreOptIn() {
        XCTAssertEqual(EpisodeRules.waiting([episode(1, season: 0)], now: now, includeSpecials: true).count, 1)
    }
    func testWholeSeasonDropIncludesAllUnwatchedEpisodes() {
        XCTAssertEqual(EpisodeRules.waiting((1...8).map { episode($0, offset: 0) }, now: now, includeSpecials: false).count, 8)
    }
    func testComingSoonWindowAndChronologicalOrder() {
        let states = [episode(1, offset: 2 * 86_400), episode(2, offset: 86_400), episode(3, offset: 31 * 86_400), episode(4, offset: 0), episode(5, offset: 10, watched: true)]
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
