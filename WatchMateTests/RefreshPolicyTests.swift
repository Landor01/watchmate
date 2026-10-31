import Foundation
import SwiftData
import Testing
@testable import WatchMate

extension SharedTraktProgressTests {
@Suite(.serialized)
@MainActor
struct RefreshPolicyTests {
    @Test func dailyPolicyDistinguishesReturningAndEndedSeries() {
        let now = Date(timeIntervalSince1970: 200_000)
        let old = now.addingTimeInterval(-90_000)
        #expect(RefreshPolicy.refreshAutomatically(status: "Returning Series", updatedAt: old, attemptedAt: nil, now: now))
        #expect(RefreshPolicy.refreshAutomatically(status: nil, updatedAt: nil, attemptedAt: nil, now: now))
        #expect(!RefreshPolicy.refreshAutomatically(status: "Ended", updatedAt: old, attemptedAt: nil, now: now))
        #expect(!RefreshPolicy.refreshAutomatically(status: "Canceled", updatedAt: old, attemptedAt: nil, now: now))
        #expect(!RefreshPolicy.refreshAutomatically(status: "Returning Series", updatedAt: now, attemptedAt: nil, now: now))
        #expect(!RefreshPolicy.refreshAutomatically(status: nil, updatedAt: old, attemptedAt: now, now: now))
    }

    private func withStore(_ operation: (AppStore, ModelContainer, RefreshViewingService) async throws -> Void) async throws {
        let keys = ["demoMode", "traktAccountID", "historyRevision", "hidden", "lastSync", "sharedShowsUpdateTraktHistory"]
        let defaults = UserDefaults.standard
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let settings = Settings()
        settings.demoMode = false
        settings.traktAccountID = nil
        settings.hiddenShowIDs = []
        settings.sharedShowsUpdateTraktHistory = false
        let container = try ModelContainer(for: Show.self, Episode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let service = RefreshViewingService()
        let store = AppStore(context: container.mainContext, settings: settings, viewing: service)
        store.connected = true
        try await operation(store, container, service)
    }

    private func addShow(_ id: Int, to container: ModelContainer, date: Date?, status: String? = nil) throws -> Show {
        let show = Show(traktID: id, tmdbID: nil, title: "Show \(id)")
        show.catalogueUpdatedAt = date
        show.seriesStatus = status
        container.mainContext.insert(show)
        show.episodes.append(Episode(showID: id, remote: RefreshViewingService.episode))
        try container.mainContext.save()
        return show
    }

    @Test func cachedLaunchChecksProgressWithoutImportingCatalogueOrBlockingUI() async throws {
        try await withStore { store, container, service in
            let now = Date()
            let show = try addShow(7, to: container, date: now)
            service.onHistory = { #expect(!store.busy) }
            await store.refreshInBackground(now: now, synchronizeCloud: false)
            await store.refreshInBackground(now: now.addingTimeInterval(60), synchronizeCloud: false)
            #expect(service.historyReads == 1)
            #expect(service.watchlistReads == 0)
            #expect(service.catalogueIDs.isEmpty)
            #expect(show.episodes.first?.watchedAt != nil)
            #expect(!store.busy)
        }
    }

    @Test func staleDailyRefreshIsBoundedAndSkipsEndedShows() async throws {
        try await withStore { store, container, service in
            let now = Date()
            for id in 1...8 { _ = try addShow(id, to: container, date: now.addingTimeInterval(-90_000)) }
            _ = try addShow(99, to: container, date: nil, status: "Ended")
            await store.refreshInBackground(now: now, synchronizeCloud: false)
            #expect(service.catalogueIDs.count == 5)
            #expect(!service.catalogueIDs.contains(99))
            #expect(service.historyReads == 1)
            #expect(service.watchlistReads == 0)
            #expect(!store.busy)
        }
    }

    @Test func newUserActionInvalidatesInFlightProgressSnapshot() async throws {
        try await withStore { store, container, service in
            let show = try addShow(7, to: container, date: Date())
            service.onHistory = {
                store.busy = true
                show.episodes.first?.watchedAt = nil
                store.busy = false
            }
            await store.refreshInBackground(synchronizeCloud: false)
            #expect(show.episodes.first?.watchedAt == nil)
            #expect(service.catalogueIDs.isEmpty)
        }
    }

    @Test func openingShowRefreshesOnlyThatShowAndPreservesWatchedProgress() async throws {
        try await withStore { store, container, service in
            let show = try addShow(7, to: container, date: nil)
            _ = try addShow(8, to: container, date: nil)
            service.onCatalogue = { #expect(!store.busy) }
            await store.refreshShow(show)
            await store.refreshShow(show)
            #expect(service.catalogueIDs == [7])
            #expect(service.historyReads == 1)
            #expect(service.watchlistReads == 0)
            #expect(show.episodes.first?.watchedAt != nil)
        }
    }

    @Test func explicitRefreshFetchesOnlyRequestedShowEvenWhenCacheIsFresh() async throws {
        try await withStore { store, container, service in
            _ = try addShow(7, to: container, date: Date())
            _ = try addShow(8, to: container, date: Date())
            await store.refresh(syncCloudFirst: false, showIDs: [7])
            #expect(service.catalogueIDs == [7])
            #expect(service.watchlistReads == 0)
            #expect(!store.busy)
        }
    }

    @Test func accountChangeDiscardsShowResponse() async throws {
        try await withStore { store, container, service in
            let show = try addShow(7, to: container, date: nil)
            service.onCatalogue = { store.settings.traktAccountID = "different-account" }
            await store.refreshShow(show)
            #expect(show.catalogueUpdatedAt == nil)
            #expect(show.episodes.first?.watchedAt == nil)
        }
    }
}

}

@MainActor
private final class RefreshViewingService: ViewingService {
    static var episode: RemoteEpisode {
        RemoteEpisode(season: 1, number: 1, title: "Episode", ids: IDs(trakt: 42, tmdb: nil),
                      overview: nil, firstAired: nil, runtime: nil)
    }
    var historyReads = 0
    var watchlistReads = 0
    var catalogueIDs: [Int] = []
    var onHistory: (() -> Void)?
    var onCatalogue: (() -> Void)?
    func accountID() async throws -> String { "test" }
    func watchedShows() async throws -> [WatchedShow] {
        historyReads += 1
        onHistory?()
        return [WatchedShow(show: RemoteShow(title: "Show 7", year: nil, ids: IDs(trakt: 7, tmdb: nil)),
                            seasons: [WatchedSeason(number: 1, episodes: [WatchedEpisode(number: 1, lastWatchedAt: "2026-01-01T12:00:00Z")])])]
    }
    func watchlist() async throws -> [RemoteShow] { watchlistReads += 1; return [] }
    func episodes(showID: Int) async throws -> [RemoteEpisode] {
        catalogueIDs.append(showID)
        onCatalogue?()
        return [Self.episode]
    }
    func search(_ query: String) async throws -> [RemoteShow] { [] }
    func follow(_ show: RemoteShow) async throws {}
    func setWatched(episodeID: Int, watched: Bool) async throws {}
    func markWatched(episodeIDs: [Int]) async throws -> Set<Int> { Set(episodeIDs) }
    func markUnwatched(episodeIDs: [Int]) async throws -> Set<Int> { Set(episodeIDs) }
}
