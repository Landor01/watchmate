import Foundation

@MainActor
final class TraktService: ViewingService {
    let auth: TraktAuth
    private var lastWrite: Date = .distantPast
    init(auth: TraktAuth) { self.auth = auth }

    private func request(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = true,
                         method: String = "GET", body: Data? = nil) async throws -> URLRequest {
        guard !auth.clientID.isEmpty else { throw APIError.message("Add a Trakt client ID in Settings.") }
        var components = URLComponents(string: "https://api.trakt.tv/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(auth.clientID, forHTTPHeaderField: "trakt-api-key")
        if authenticated { request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization") }
        return request
    }
    private func page<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> [T] {
        var output: [T] = [], page = 1
        var previousData: Data?
        while true {
            let request = try await request(path, query: query + [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "limit", value: "100")])
            let (data, response) = try await HTTP.send(request)
            let batch = try HTTP.decoder.decode([T].self, from: data)
            if batch.isEmpty { break }
            if data == previousData { throw APIError.message("The API repeated a page; sync stopped to avoid an incomplete history.") }
            previousData = data; output += batch
            if let count = response.value(forHTTPHeaderField: "X-Pagination-Page-Count").flatMap(Int.init) {
                if page >= count { break }
            }
            page += 1
            try Task.checkCancellation()
        }
        return output
    }
    func watchedShows() async throws -> [WatchedShow] {
        try await page("sync/watched/shows", query: [URLQueryItem(name: "extended", value: "progress")], as: WatchedShow.self)
    }
    func watchlist() async throws -> [RemoteShow] {
        try await page("sync/watchlist/shows", as: ListedShow.self).map(\.show)
    }
    func episodes(showID: Int) async throws -> [RemoteEpisode] {
        let request = try await request("shows/\(showID)/seasons", query: [URLQueryItem(name: "extended", value: "full,episodes")], authenticated: false)
        let seasons = try await HTTP.decode([RemoteSeason].self, request: request)
        return seasons.flatMap { $0.episodes ?? [] }
    }
    func search(_ query: String) async throws -> [RemoteShow] {
        let request = try await request("search/show", query: [URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: "30")], authenticated: false)
        return try await HTTP.decode([SearchResult].self, request: request).compactMap(\.show)
    }
    private func write(_ path: String, object: [String: Any]) async throws {
        let delay = 1.1 - Date().timeIntervalSince(lastWrite)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        lastWrite = Date()
        let request = try await request(path, method: "POST", body: JSONSerialization.data(withJSONObject: object))
        let (data, _) = try await HTTP.send(request)
        // A 200 may still contain not_found entries. Do not claim a successful mutation.
        if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let missing = result["not_found"] as? [String: Any],
           missing.values.contains(where: { ($0 as? [Any])?.isEmpty == false }) {
            throw APIError.message("Trakt could not find this show or episode; your changes were not saved.")
        }
    }
    func follow(_ show: RemoteShow) async throws {
        try await write("sync/watchlist", object: ["shows": [["ids": ["trakt": show.ids.trakt]]]])
    }
    func setWatched(episodeID: Int, watched: Bool) async throws {
        var episode: [String: Any] = ["ids": ["trakt": episodeID]]
        if watched { episode["watched_at"] = Dates.string(Date()) }
        try await write(watched ? "sync/history" : "sync/history/remove", object: ["episodes": [episode]])
    }
}
