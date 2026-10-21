import Foundation

@MainActor
final class TMDBService: CatalogueService {
    var configured: Bool { !Configuration.tmdbReadAccessToken.isEmpty }
    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], type: T.Type) async throws -> T {
        let token = Configuration.tmdbReadAccessToken
        guard !token.isEmpty else { throw APIError.message("Show information is unavailable in this version of WatchMate. Please contact support.") }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            return try await HTTP.decode(type, request: request)
        } catch APIError.http(401, _) {
            throw APIError.message("Artwork and show information are unavailable because the TMDB credential is invalid.")
        }
    }
    #if DEBUG
    func testConnection() async throws -> String {
        // Make a fresh request rather than using the poster cache.
        _ = try await get("tv/1399", type: TVDetails.self)
        return "Connected. TMDB token is valid."
    }
    #endif

    private var posterCache: [Int: String] = [:]

    func posterPath(tmdbID: Int) async throws -> String? {
        if let cached = posterCache[tmdbID] { return cached.isEmpty ? nil : cached }
        let details = try await get("tv/\(tmdbID)", type: TVDetails.self)
        try Task.checkCancellation()
        posterCache[tmdbID] = details.posterPath ?? ""
        return details.posterPath
    }

    private struct TVDetails: Decodable {
        let overview: String?
        let posterPath: String?
        let seasons: [SeasonArtwork]?
    }
    private struct SeasonArtwork: Decodable {
        let seasonNumber: Int
        let posterPath: String?
    }

    func seasonPosters(tmdbID: Int) async throws -> [Int: String] {
        let details = try await get("tv/\(tmdbID)", type: TVDetails.self)
        var posters: [Int: String] = [:]
        for season in details.seasons ?? [] {
            posters[season.seasonNumber] = season.posterPath
        }
        return posters
    }
    private struct SeasonDetails: Decodable, Sendable {
        struct EpisodeArtwork: Decodable, Sendable {
            let episodeNumber: Int
            let stillPath: String?
        }
        let posterPath: String?
        let episodes: [EpisodeArtwork]
    }
    private var seasonArtworkCache: [String: (date: Date, details: SeasonDetails)] = [:]
    private var seasonArtworkRequests: [String: Task<SeasonDetails, Error>] = [:]

    func episodeArtwork(tmdbID: Int, season: Int, episode: Int) async throws -> [String] {
        let key = "\(tmdbID):\(season)"
        let details: SeasonDetails
        if let cached = seasonArtworkCache[key], Date().timeIntervalSince(cached.date) < 3600 {
            details = cached.details
        } else if let request = seasonArtworkRequests[key] {
            details = try await request.value
        } else {
            // Share one season request across all episode rows, including concurrent appearances.
            let request = Task {
                try await self.get("tv/\(tmdbID)/season/\(season)", type: SeasonDetails.self)
            }
            seasonArtworkRequests[key] = request
            defer { seasonArtworkRequests[key] = nil }
            details = try await request.value
            seasonArtworkCache[key] = (Date(), details)
        }
        return [details.episodes.first { $0.episodeNumber == episode }?.stillPath, details.posterPath]
            .compactMap { $0 }
    }

    private struct WatchRegionResults: Decodable {
        struct Region: Decodable {
            // HTTP.decoder converts TMDB's iso_3166_1 key to iso31661.
            let iso31661: String
        }
        let results: [Region]
    }

    func availableRegions() async throws -> [String] {
        if PreviewEnvironment.isRunning { return ["AU", "CA", "GB", "US"] }
        let response = try await get("watch/providers/regions", type: WatchRegionResults.self)
        return Array(Set(response.results.map(\.iso31661))).sorted()
    }

    private struct WatchProvider: Decodable { let providerId: Int; let providerName: String }
    private struct Country: Decodable {
        let link: String?
        let flatrate: [WatchProvider]?
        let free: [WatchProvider]?
        let ads: [WatchProvider]?
    }
    private struct WatchResults: Decodable { let results: [String: Country] }
    private struct ProviderResults: Decodable { let results: [WatchProvider] }
    func details(tmdbID: Int, region: String) async throws -> CatalogueDetails {
        let details = try await get("tv/\(tmdbID)", type: TVDetails.self)
        let providers = try await get("tv/\(tmdbID)/watch/providers", type: WatchResults.self)
        let country = providers.results[region]
        // Exclude buy/rent offers from the user's subscription filter.
        let offers = (country?.flatrate ?? []) + (country?.free ?? []) + (country?.ads ?? [])
        var seen = Set<Int>()
        let mapped = offers.filter { seen.insert($0.providerId).inserted }
            .map { Provider(id: $0.providerId, name: $0.providerName) }
        return CatalogueDetails(overview: details.overview ?? "", posterPath: details.posterPath,
                                providers: mapped, watchURL: country?.link)
    }
    func providers(region: String) async throws -> [Provider] {
        if PreviewEnvironment.isRunning { return PreviewEnvironment.providers }
        let result = try await get("watch/providers/tv", query: [URLQueryItem(name: "watch_region", value: region)], type: ProviderResults.self)
        return result.results.map { Provider(id: $0.providerId, name: $0.providerName) }.sorted { $0.name < $1.name }
    }
}
