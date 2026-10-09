import Foundation

enum APIError: LocalizedError {
    case message(String)
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(let code, let detail):
            if code == 401 { return "Sign-in expired or the API credential is invalid. Reconnect in Settings." }
            if code == 429 { return "API rate limit reached. Try again later. \(detail)" }
            return "API request failed (\(code)). \(detail)"
        }
    }
}

enum HTTP {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request; request.timeoutInterval = 30
        for attempt in 0...2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw APIError.message("Invalid server response.") }
            if (200..<300).contains(response.statusCode) { return (data, response) }
            // Never automatically repeat writes: the server may have accepted them.
            if response.statusCode == 429 && request.httpMethod == "GET" && attempt < 2 {
                let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5
                if delay <= 60 {
                    try await Task.sleep(for: .seconds(max(1, delay))); continue
                }
            }
            // Keep OAuth error information without displaying response bodies or tokens.
            let detail = response.statusCode == 429 ? "Retry after: \(response.value(forHTTPHeaderField: "Retry-After") ?? "unknown") seconds." : ""
            throw APIError.http(response.statusCode, detail)
        }
        throw APIError.message("Request could not be completed.")
    }
    static func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, _) = try await send(request); return try decoder.decode(type, from: data)
    }
}

@MainActor
protocol ViewingService {
    func watchedShows() async throws -> [WatchedShow]
    func watchlist() async throws -> [RemoteShow]
    func episodes(showID: Int) async throws -> [RemoteEpisode]
    func search(_ query: String) async throws -> [RemoteShow]
    func follow(_ show: RemoteShow) async throws
    func setWatched(episodeID: Int, watched: Bool) async throws
}

@MainActor
protocol CatalogueService {
    func details(tmdbID: Int, region: String) async throws -> CatalogueDetails
    func providers(region: String) async throws -> [Provider]
}
