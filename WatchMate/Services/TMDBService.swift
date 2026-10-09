import Foundation

@MainActor
final class TMDBService: CatalogueService {
    var configured: Bool { !Keychain.string("tmdb.token").isEmpty }
    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], type: T.Type) async throws -> T {
        let token = Keychain.string("tmdb.token")
        guard !token.isEmpty else { throw APIError.message("Add your TMDB API Read Access Token in Settings.") }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await HTTP.decode(type, request: request)
    }
    private struct TVDetails: Decodable { let overview: String?; let posterPath: String? }
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
        let result = try await get("watch/providers/tv", query: [URLQueryItem(name: "watch_region", value: region)], type: ProviderResults.self)
        return result.results.map { Provider(id: $0.providerId, name: $0.providerName) }.sorted { $0.name < $1.name }
    }
}
