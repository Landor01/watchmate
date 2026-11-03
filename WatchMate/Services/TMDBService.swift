import Foundation

@MainActor
final class TMDBService: CatalogueService {
    private let send: (URLRequest) async throws -> Data

    init(send: @escaping (URLRequest) async throws -> Data = { request in
        try await HTTP.send(request).0
    }) {
        self.send = send
    }

    var configured: Bool { !Configuration.tmdbReadAccessToken.isEmpty }
    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], type: T.Type) async throws -> T {
        let token = Configuration.tmdbReadAccessToken
        guard !token.isEmpty else { throw APIError.message("Show information is unavailable in this version of WatchMate. Please contact support.") }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let data = try await send(request)
            return try HTTP.decoder.decode(type, from: data)
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

    private let showCache = CatalogueReadCache<Int, TVDetails>(lifetime: 3600)
    private let regionCache = CatalogueReadCache<String, [String]>(lifetime: 86_400)
    private let providerCache = CatalogueReadCache<String, [Provider]>(lifetime: 86_400)

    private func showDetails(tmdbID: Int) async throws -> TVDetails {
        try await showCache.value(for: tmdbID) {
            let details = try await self.get("tv/\(tmdbID)",
                                             query: [URLQueryItem(name: "append_to_response", value: "watch/providers")],
                                             type: TVDetails.self)
            guard details.watchProviders != nil else {
                throw APIError.message("TMDB did not return streaming availability. Try refreshing again.")
            }
            return details
        }
    }

    func posterPath(tmdbID: Int) async throws -> String? {
        let details = try await showDetails(tmdbID: tmdbID)
        return details.posterPath
    }

    private struct TVDetails: Decodable {
        let status: String?
        let overview: String?
        let posterPath: String?
        let seasons: [SeasonArtwork]?
        let watchProviders: WatchResults?

        enum CodingKeys: String, CodingKey {
            case overview, posterPath, seasons, status
            case watchProviders = "watch/providers"
        }
    }
    private struct SeasonArtwork: Decodable {
        let seasonNumber: Int
        let posterPath: String?
    }

    func seasonPosters(tmdbID: Int) async throws -> [Int: String] {
        let details = try await showDetails(tmdbID: tmdbID)
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
    private let seasonArtworkCache = CatalogueReadCache<String, SeasonDetails>(
        lifetime: 3600, maximumCost: 1_000_000,
        cost: { $0.episodes.reduce(128) { $0 + 64 + ($1.stillPath?.utf8.count ?? 0) } })

    func releaseCachedMetadata() {
        seasonArtworkCache.removeAll()
        showCache.removeAll()
        regionCache.removeAll()
        providerCache.removeAll()
    }

    func episodeArtwork(tmdbID: Int, season: Int, episode: Int) async throws -> [String] {
        let key = "\(tmdbID):\(season)"
        let details = try await seasonArtworkCache.value(for: key) {
            try await self.get("tv/\(tmdbID)/season/\(season)", type: SeasonDetails.self)
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
        return try await regionCache.value(for: "regions") {
            let response = try await self.get("watch/providers/regions", type: WatchRegionResults.self)
            return Array(Set(response.results.map(\.iso31661))).sorted()
        }
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
        let details = try await showDetails(tmdbID: tmdbID)
        guard let providers = details.watchProviders else {
            throw APIError.message("TMDB did not return streaming availability. Try refreshing again.")
        }
        let country = providers.results[region]
        // Exclude buy/rent offers from the user's subscription filter.
        let offers = (country?.flatrate ?? []) + (country?.free ?? []) + (country?.ads ?? [])
        var seen = Set<Int>()
        let mapped = offers.filter { seen.insert($0.providerId).inserted }
            .map { Provider(id: $0.providerId, name: $0.providerName) }
        return CatalogueDetails(overview: details.overview ?? "", posterPath: details.posterPath,
                                providers: mapped, watchURL: country?.link, seriesStatus: details.status)
    }
    func providers(region: String) async throws -> [Provider] {
        if PreviewEnvironment.isRunning { return PreviewEnvironment.providers }
        return try await providerCache.value(for: region) {
            let result = try await self.get("watch/providers/tv", query: [URLQueryItem(name: "watch_region", value: region)], type: ProviderResults.self)
            return result.results.map { Provider(id: $0.providerId, name: $0.providerName) }.sorted { $0.name < $1.name }
        }
    }
}
