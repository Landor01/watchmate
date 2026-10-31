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

/// A short-lived cache for public catalogue reads only. Concurrent callers share
/// the same request; errors are never cached and one cancelled waiter cannot
/// cancel a request still needed by another screen.
@MainActor
final class CatalogueReadCache<Key: Hashable, Value: Sendable> {
    private var values: [Key: (date: Date, value: Value)] = [:]
    private var requests: [Key: Task<Value, Error>] = [:]
    private let lifetime: TimeInterval
    private let now: () -> Date

    init(lifetime: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.lifetime = lifetime
        self.now = now
    }

    func invalidate(_ key: Key) { values[key] = nil }

    func value(for key: Key, load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let date = now()
        values = values.filter { date.timeIntervalSince($0.value.date) < lifetime }
        if let cached = values[key] { return cached.value }
        if let request = requests[key] {
            let value = try await request.value
            try Task.checkCancellation()
            return value
        }
        let request = Task { try await load() }
        requests[key] = request
        defer { requests[key] = nil }
        let value = try await request.value
        // Bound retained catalogue data even when browsing a large library.
        if values.count >= 128, let oldest = values.min(by: { $0.value.date < $1.value.date })?.key {
            values[oldest] = nil
        }
        values[key] = (now(), value)
        try Task.checkCancellation()
        return value
    }
}

@MainActor
protocol ViewingService {
    func accountID() async throws -> String
    func watchedShows() async throws -> [WatchedShow]
    func watchlist() async throws -> [RemoteShow]
    func episodes(showID: Int) async throws -> [RemoteEpisode]
    func refreshEpisodes(showID: Int) async throws -> [RemoteEpisode]
    func search(_ query: String) async throws -> [RemoteShow]
    func follow(_ show: RemoteShow) async throws
    func setWatched(episodeID: Int, watched: Bool) async throws
    func markWatched(episodeIDs: [Int]) async throws -> Set<Int>
    func markUnwatched(episodeIDs: [Int]) async throws -> Set<Int>
}

extension ViewingService {
    func refreshEpisodes(showID: Int) async throws -> [RemoteEpisode] {
        try await episodes(showID: showID)
    }
}

@MainActor
protocol CatalogueService {
    func details(tmdbID: Int, region: String) async throws -> CatalogueDetails
    func providers(region: String) async throws -> [Provider]
}
