import Foundation

enum TraktHistoryBatch {
    static func payload(episodeIDs: [Int], watchedAt: Date = Date()) -> [String: Any] {
        let timestamp = Dates.string(watchedAt)
        return ["episodes": Set(episodeIDs).sorted().map {
            ["ids": ["trakt": $0], "watched_at": timestamp] as [String: Any]
        }]
    }

    static func confirmedIDs(in data: Data, requestedIDs: Set<Int>) throws -> Set<Int> {
        struct Response: Decodable {
            struct Counts: Decodable { let episodes: Int }
            struct Missing: Decodable {
                struct Episode: Decodable { let ids: IDs }
                let episodes: [Episode]
            }
            let added: Counts
            let notFound: Missing
        }
        let response = try HTTP.decoder.decode(Response.self, from: data)
        let missing = Set(response.notFound.episodes.map(\.ids.trakt))
        let confirmed = requestedIDs.subtracting(missing)
        // A successful HTTP response can still reject individual IDs.
        guard missing.isSubset(of: requestedIDs), response.added.episodes == confirmed.count else {
            throw APIError.message("Trakt returned an unexpected history result. Refresh before retrying to avoid duplicate watches.")
        }
        return confirmed
    }
}

@MainActor
final class TraktService: ViewingService {
    let auth: TraktAuth
    private var lastWrite: Date = .distantPast
    init(auth: TraktAuth) { self.auth = auth }

    private func request(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = true,
                         method: String = "GET", body: Data? = nil) async throws -> URLRequest {
        guard !auth.clientID.isEmpty else { throw APIError.message("Trakt is unavailable in this version of WatchMate. Please contact support.") }
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
    func accountID() async throws -> String {
        struct AccountSettings: Decodable {
            struct User: Decodable {
                struct UserIDs: Decodable { let uuid: String }
                let ids: UserIDs
            }
            let user: User
        }
        let request = try await request("users/settings")
        let settings = try await HTTP.decode(AccountSettings.self, request: request)
        guard !settings.user.ids.uuid.isEmpty else { throw APIError.message("Trakt did not return an account identifier.") }
        return settings.user.ids.uuid
    }

    #if DEBUG
    func testConnection() async throws -> String {
        let request = try await request("shows/popular", query: [URLQueryItem(name: "limit", value: "1")], authenticated: false)
        _ = try await HTTP.decode([RemoteShow].self, request: request)
        if auth.connected {
            _ = try await accountID()
            return "Connected. Client ID and account sign-in are valid."
        }
        return "Connected. Client ID is valid; account sign-in was not tested."
    }
    #endif

    func watchedShows() async throws -> [WatchedShow] {
        try await page("sync/watched/shows", query: [URLQueryItem(name: "extended", value: "progress")], as: WatchedShow.self)
    }
    func watchlist() async throws -> [RemoteShow] {
        try await page("sync/watchlist/shows", as: ListedShow.self).map(\.show)
    }
    func show(showID: Int) async throws -> RemoteShow {
        let request = try await request("shows/\(showID)", authenticated: false)
        return try await HTTP.decode(RemoteShow.self, request: request)
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
    private func sendWrite(_ path: String, object: [String: Any]) async throws -> Data {
        let delay = 1.1 - Date().timeIntervalSince(lastWrite)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        lastWrite = Date()
        let request = try await request(path, method: "POST", body: JSONSerialization.data(withJSONObject: object))
        let (data, _) = try await HTTP.send(request)
        return data
    }

    private func write(_ path: String, object: [String: Any]) async throws {
        let data = try await sendWrite(path, object: object)
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
    func recordSharedWatch(_ episode: SharedEpisode) async throws {
        let date = episode.watchedAt == .distantPast ? "unknown" : Dates.string(episode.watchedAt)
        try await write("sync/history", object: ["episodes": [["ids": ["trakt": episode.id], "watched_at": date]]])
    }

    func markWatched(episodeIDs: [Int]) async throws -> Set<Int> {
        guard !episodeIDs.isEmpty else { return [] }
        let data = try await sendWrite("sync/history", object: TraktHistoryBatch.payload(episodeIDs: episodeIDs))
        return try TraktHistoryBatch.confirmedIDs(in: data, requestedIDs: Set(episodeIDs))
    }

    func setWatched(episodeID: Int, watched: Bool) async throws {
        var episode: [String: Any] = ["ids": ["trakt": episodeID]]
        if watched { episode["watched_at"] = Dates.string(Date()) }
        try await write(watched ? "sync/history" : "sync/history/remove", object: ["episodes": [episode]])
    }
}
