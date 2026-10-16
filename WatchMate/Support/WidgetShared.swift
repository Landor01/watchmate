import Foundation
import AppIntents

// Shared with the widget target through its WidgetShared.swift source link.
struct WidgetEpisodeLink: Hashable, Sendable {
    let episodeKey: String
    let accountScope: String

    var url: URL? {
        var components = URLComponents()
        components.scheme = "watchmate"
        components.host = "episode"
        components.queryItems = [
            URLQueryItem(name: "key", value: episodeKey),
            URLQueryItem(name: "account", value: accountScope)
        ]
        return components.url
    }

    init(episodeKey: String, accountScope: String) {
        self.episodeKey = episodeKey
        self.accountScope = accountScope
    }

    init?(url: URL) {
        guard url.scheme == "watchmate", url.host == "episode",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.filter({ $0.name == "key" }).count == 1,
              items.filter({ $0.name == "account" }).count == 1,
              let key = items.first(where: { $0.name == "key" })?.value,
              let account = items.first(where: { $0.name == "account" })?.value,
              !account.isEmpty else { return nil }
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let showID = Int(parts[0]), showID != 0,
              let season = Int(parts[1]), season >= 0,
              let episode = Int(parts[2]), episode > 0 else { return nil }
        episodeKey = key
        accountScope = account
    }
}

struct WidgetEpisode: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let overview: String
    let firstAired: Date
    let runtime: Int?
}

struct WidgetShow: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let title: String
    let episodes: [WidgetEpisode]
    var posterPath: String? = nil

    func nextEpisode(at date: Date) -> WidgetEpisode? {
        episodes.filter { $0.firstAired <= date }
            .min { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    func nextAirDate(after date: Date) -> Date? {
        episodes.map(\.firstAired).filter { $0 > date }.min()
    }
}

struct WidgetLibrary: Codable, Equatable, Sendable {
    let accountScope: String
    let shows: [WidgetShow]
    var errorShowID: Int? = nil
    var errorMessage: String? = nil

    static let empty = WidgetLibrary(accountScope: "", shows: [])
}

enum WidgetSnapshotStore {
    static let kind = "WatchMateNextEpisode"
    static let groupID = "group.net.andrewroland.WatchMate"

    static func fileURL() throws -> URL {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw WidgetActionError.unavailable
        }
        return directory.appendingPathComponent("next-episode-widget.json")
    }

    static func read() throws -> WidgetLibrary {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(WidgetLibrary.self, from: Data(contentsOf: url))
    }

    @discardableResult
    static func write(_ library: WidgetLibrary) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(library)
        let url = try fileURL()
        guard (try? Data(contentsOf: url)) != data else { return false }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
}

struct WidgetShowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static let defaultQuery = WidgetShowQuery()
    let id: Int
    @Property(title: "Title") var title: String

    init(id: Int, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct WidgetShowQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [WidgetShowEntity] {
        let ids = Set(identifiers)
        return try entities().filter { ids.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetShowEntity] {
        try entities()
    }

    func entities(matching string: String) async throws -> [WidgetShowEntity] {
        try entities().filter { $0.title.localizedStandardContains(string) }
    }

    private func entities() throws -> [WidgetShowEntity] {
        try WidgetSnapshotStore.read().shows.map { WidgetShowEntity(id: $0.id, title: $0.title) }
    }
}

struct NextEpisodeConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Next Episode"
    static let description = IntentDescription("Choose a programme from My Shows.")
    @Parameter(title: "Show") var show: WidgetShowEntity?
}

struct WidgetArtworkPaths: Codable, Sendable {
    let fetchedAt: Date
    let paths: [String]
}

enum WidgetArtworkStore {
    static func url(for episodeID: String) throws -> URL {
        guard episodeID.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" }) else {
            throw WidgetActionError.unavailable
        }
        return try WidgetSnapshotStore.fileURL().deletingLastPathComponent()
            .appendingPathComponent("artwork-\(episodeID.replacingOccurrences(of: ":", with: "-")).json")
    }

    static func read(for episodeID: String) -> WidgetArtworkPaths? {
        guard let url = try? url(for: episodeID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetArtworkPaths.self, from: data)
    }

    static func write(paths: [String], for episodeID: String) throws {
        let data = try JSONEncoder().encode(WidgetArtworkPaths(fetchedAt: .now, paths: paths))
        try data.write(to: url(for: episodeID), options: .atomic)
    }

}

enum WidgetActionError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    case busy
    case changed
    case updateFailed

    static func requireMainApp() throws {
        throw WidgetActionError.unavailable
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: "Open WatchMate once to make your shows available."
        case .busy: "WatchMate is updating. Please try again shortly."
        case .changed: "Your shows have changed. The widget has been refreshed."
        case .updateFailed: "Could not update this episode. Check your connection and try again."
        }
    }
}

struct MarkWidgetEpisodeWatched: AppIntent {
    static let title: LocalizedStringResource = "Mark Episode Watched"
    static let isDiscoverable = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Show ID") var showID: Int
    @Parameter(title: "Episode") var episodeKey: String
    @Parameter(title: "Account") var accountScope: String

    init() {}
    init(showID: Int, episodeKey: String, accountScope: String) {
        self.showID = showID
        self.episodeKey = episodeKey
        self.accountScope = accountScope
    }

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        // The system routes execution to the main app; the extension only renders the button.
        try WidgetActionError.requireMainApp()
        #else
        try await AppServices.shared().store.performWidgetAction(
            showID: showID, episodeKey: episodeKey, accountScope: accountScope, markWatched: true
        )
        #endif
        return .result()
    }
}

struct SkipWidgetEpisode: AppIntent {
    static let title: LocalizedStringResource = "Skip Episode"
    static let isDiscoverable = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Show ID") var showID: Int
    @Parameter(title: "Episode") var episodeKey: String
    @Parameter(title: "Account") var accountScope: String

    init() {}
    init(showID: Int, episodeKey: String, accountScope: String) {
        self.showID = showID
        self.episodeKey = episodeKey
        self.accountScope = accountScope
    }

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        try WidgetActionError.requireMainApp()
        #else
        try await AppServices.shared().store.performWidgetAction(
            showID: showID, episodeKey: episodeKey, accountScope: accountScope, markWatched: false
        )
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
// iOS 18–25 route these intents to the app without bringing its UI forward.
// Newer systems use supportedModes and allowedExecutionTargets above.
@available(iOS, introduced: 18.0, deprecated: 26.0)
extension MarkWidgetEpisodeWatched: ForegroundContinuableIntent {}
@available(iOS, introduced: 18.0, deprecated: 26.0)
extension SkipWidgetEpisode: ForegroundContinuableIntent {}
#endif
