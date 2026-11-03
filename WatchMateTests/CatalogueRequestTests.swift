import Foundation
import Testing
@testable import WatchMate

@MainActor
struct CatalogueRequestTests {
    @Test func cacheEvictsByCostAndDoesNotRetainOversizedValues() async throws {
        let cache = CatalogueReadCache<Int, String>(lifetime: 60, maximumCost: 10, cost: { $0.utf8.count })
        _ = try await cache.value(for: 1) { "123456" }
        _ = try await cache.value(for: 2) { "abcdef" }
        #expect(try await cache.value(for: 1) { "reloaded" } == "reloaded")
        _ = try await cache.value(for: 3) { "too large to cache" }
        #expect(try await cache.value(for: 3) { "new" } == "new")
        cache.removeAll()
        #expect(try await cache.value(for: 3) { "cleared" } == "cleared")
    }

    @Test func memoryWarningDoesNotLetInFlightRequestRepopulateCache() async throws {
        let cache = CatalogueReadCache<Int, Int>(lifetime: 60)
        var release: CheckedContinuation<Int, Never>?
        let request = Task {
            try await cache.value(for: 1) {
                await withCheckedContinuation { release = $0 }
            }
        }
        while release == nil { await Task.yield() }
        cache.removeAll()
        release?.resume(returning: 42)
        #expect(try await request.value == 42)
        #expect(try await cache.value(for: 1) { 99 } == 99)
    }

    @Test func diskCataloguePreservesStatusAndEvictsMemoryWithoutLosingSavedData() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EpisodeCatalogueCache(directory: directory, capacity: 1)
        let episode = RemoteEpisode(season: 1, number: 1, title: "Pilot",
                                    ids: IDs(trakt: 101, tmdb: nil), overview: nil, firstAired: nil, runtime: 42)
        await cache.saveSnapshot([episode], showID: 1, seriesStatus: "Ended")
        await cache.saveSnapshot([episode, episode], showID: 1)
        let updated = await cache.readSnapshot(1)
        #expect(updated?.episodes.count == 2)
        #expect(updated?.seriesStatus == "Ended")
        // The warm read succeeds without a file; eviction then exposes the missing file.
        try FileManager.default.removeItem(at: directory.appending(path: "1.json"))
        #expect(await cache.readSnapshot(1) != nil)
        await cache.saveSnapshot([], showID: 2)
        #expect(await cache.readSnapshot(1) == nil)
        let reopened = EpisodeCatalogueCache(directory: directory)
        #expect(await reopened.readSnapshot(2)?.episodes.isEmpty == true)
    }

    @Test func concurrentReadsShareRequestAndCacheExpires() async throws {
        var date = Date(timeIntervalSince1970: 100)
        let cache = CatalogueReadCache<Int, Int>(lifetime: 60, now: { date })
        var reads = 0
        var release: CheckedContinuation<Int, Never>?
        let first = Task {
            try await cache.value(for: 7) {
                reads += 1
                return await withCheckedContinuation { release = $0 }
            }
        }
        while release == nil { await Task.yield() }
        var joined = false
        let second = Task {
            joined = true
            return try await cache.value(for: 7) { reads += 1; return 99 }
        }
        while !joined { await Task.yield() }
        release?.resume(returning: 42)
        #expect(try await first.value == 42)
        #expect(try await second.value == 42)
        #expect(reads == 1)
        #expect(try await cache.value(for: 7) { reads += 1; return 99 } == 42)
        date = date.addingTimeInterval(61)
        #expect(try await cache.value(for: 7) { reads += 1; return 99 } == 99)
        #expect(reads == 2)
    }

    @Test func failedReadsCanBeRetriedAndKeysStaySeparate() async throws {
        let cache = CatalogueReadCache<Int, Int>(lifetime: 60)
        await #expect(throws: (any Error).self) {
            try await cache.value(for: 1) { throw APIError.message("Offline") }
        }
        #expect(try await cache.value(for: 1) { 10 } == 10)
        #expect(try await cache.value(for: 2) { 20 } == 20)
    }

    @Test func cancelledWaiterDoesNotCancelSharedRequest() async throws {
        let cache = CatalogueReadCache<Int, Int>(lifetime: 60)
        var release: CheckedContinuation<Int, Never>?
        let first = Task {
            try await cache.value(for: 1) {
                await withCheckedContinuation { release = $0 }
            }
        }
        while release == nil { await Task.yield() }
        first.cancel()
        release?.resume(returning: 42)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await cache.value(for: 1) { 99 } == 42)
    }

    @Test func tmdbDetailsPostersAndRegionsReuseCombinedResponse() async throws {
        var paths: [String] = []
        let service = TMDBService { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            paths.append(url.path)
            #expect(components.queryItems?.contains(URLQueryItem(name: "append_to_response", value: "watch/providers")) == true)
            return Data(#"{"overview":"Overview","poster_path":"/show.jpg","seasons":[{"season_number":1,"poster_path":"/season.jpg"}],"watch/providers":{"results":{"GB":{"link":"https://example.com/gb","flatrate":[{"provider_id":8,"provider_name":"Netflix"}],"ads":[{"provider_id":8,"provider_name":"Netflix"}]},"US":{"free":[{"provider_id":9,"provider_name":"Free TV"}]}}}}"#.utf8)
        }
        #expect(try await service.posterPath(tmdbID: 7) == "/show.jpg")
        #expect(try await service.seasonPosters(tmdbID: 7) == [1: "/season.jpg"])
        let gb = try await service.details(tmdbID: 7, region: "GB")
        let us = try await service.details(tmdbID: 7, region: "US")
        #expect(gb.overview == "Overview")
        #expect(gb.providers.map(\.id) == [8])
        #expect(us.providers.map(\.id) == [9])
        #expect(paths == ["/3/tv/7"])
    }

    @Test func providerCataloguesCacheByRegion() async throws {
        var requests = 0
        let service = TMDBService { request in
            requests += 1
            if request.url?.path.hasSuffix("/regions") == true {
                return Data(#"{"results":[{"iso_3166_1":"GB"},{"iso_3166_1":"US"}]}"#.utf8)
            }
            return Data(#"{"results":[{"provider_id":8,"provider_name":"Netflix"}]}"#.utf8)
        }
        _ = try await service.availableRegions()
        _ = try await service.availableRegions()
        _ = try await service.providers(region: "GB")
        _ = try await service.providers(region: "GB")
        _ = try await service.providers(region: "US")
        #expect(requests == 3)
    }
}
