import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class AppStore {
    let settings: Settings
    let auth: TraktAuth
    let catalogue = TMDBService()
    private let context: ModelContext
    private let viewing: any ViewingService
    var busy = false
    var errorMessage: String?
    var status = ""
    var connected: Bool
    var providerOptions: [Provider] = []

    init(context: ModelContext, settings: Settings) {
        let auth = TraktAuth()
        self.auth = auth; viewing = TraktService(auth: auth)
        self.context = context; self.settings = settings; connected = auth.connected
    }
    func allShows() throws -> [Show] { try context.fetch(FetchDescriptor<Show>()) }
    func waiting(_ show: Show) -> [Episode] {
        let states = EpisodeRules.waiting(show.episodes.map(\.state), now: Date(), includeSpecials: settings.includeSpecials)
        return states.compactMap { state in show.episodes.first { $0.season == state.season && $0.number == state.number } }
    }
    func upcoming(_ show: Show) -> [Episode] {
        let states = EpisodeRules.upcoming(show.episodes.map(\.state), now: Date(), includeSpecials: settings.includeSpecials)
        return states.compactMap { state in show.episodes.first { $0.season == state.season && $0.number == state.number } }
    }
    func matchesServices(_ show: Show) -> Bool {
        settings.selectedProviders.isEmpty ||
            (show.providerRegion == settings.region && show.providers.contains { settings.selectedProviders.contains($0.id) })
    }
    func start() async {
        if settings.demoMode {
            do { if try allShows().isEmpty { try seedDemo() } } catch { errorMessage = error.localizedDescription }
        } else if connected && (settings.lastSync == nil || Date().timeIntervalSince(settings.lastSync!) > 900) {
            await refresh()
        }
    }
    private func clearData() throws {
        for show in try allShows() { context.delete(show) }
        try context.save()
        settings.lastSync = nil; settings.hiddenShowIDs = []
    }
    func connect() async {
        guard !busy else { return }
        busy = true
        do {
            try await auth.signIn()
            try clearData()
            settings.demoMode = false; connected = true
        } catch { errorMessage = error.localizedDescription }
        busy = false
        if connected && !settings.demoMode { await refresh() }
    }
    func disconnect() async {
        guard !busy else { return }
        do {
            try auth.disconnect(); connected = false
            try clearData(); settings.demoMode = false
            await reschedule()
        } catch { errorMessage = error.localizedDescription }
    }
    func useDemo() async {
        guard !busy else { return }
        do {
            try auth.disconnect(); connected = false
            try clearData(); settings.demoMode = true
            try seedDemo(); await reschedule()
        } catch { errorMessage = error.localizedDescription }
    }
    func refresh() async {
        guard !busy else { return }
        if settings.demoMode { status = "Demo data · connect Trakt for your shows"; return }
        guard connected else { errorMessage = "Connect Trakt in Settings to import your shows."; return }
        busy = true; status = "Importing your shows…"
        defer { busy = false }
        do {
            let service = viewing
            let watched = try await service.watchedShows()
            let listed = try await service.watchlist()
            var remote: [Int: RemoteShow] = [:]
            for show in watched.map(\.show) + listed { remote[show.id] = show }
            var local = Dictionary(uniqueKeysWithValues: try allShows().map { ($0.traktID, $0) })
            for show in local.values where show.isFollowing && remote[show.traktID] == nil {
                remote[show.traktID] = RemoteShow(title: show.title, year: nil, ids: IDs(trakt: show.traktID, tmdb: show.tmdbID))
            }
            var failures: [String] = [], metadataFailures = 0
            let now = Date()
            for source in remote.values.sorted(by: { $0.title < $1.title }) where !settings.hiddenShowIDs.contains(source.id) {
                try Task.checkCancellation()
                status = "Updating \(source.title)…"
                let show = local[source.id] ?? Show(traktID: source.id, tmdbID: source.ids.tmdb, title: source.title)
                if local[source.id] == nil { context.insert(show); local[source.id] = show }
                show.title = source.title; show.tmdbID = source.ids.tmdb; show.isFollowing = true
                do {
                    if show.catalogueUpdatedAt == nil || now.timeIntervalSince(show.catalogueUpdatedAt!) > 21_600 {
                        let episodes = try await service.episodes(showID: source.id)
                        merge(episodes, into: show); show.catalogueUpdatedAt = now
                    }
                    // Apply a complete watched snapshot, including remote unwatch actions.
                    for episode in show.episodes { episode.watchedAt = nil }
                    if let snapshot = watched.first(where: { $0.show.id == source.id }) {
                        for season in snapshot.seasons {
                            for remoteEpisode in season.episodes {
                                show.episodes.first(where: { $0.season == season.number && $0.number == remoteEpisode.number })?.watchedAt = Dates.parse(remoteEpisode.lastWatchedAt) ?? .distantPast
                            }
                        }
                    }
                } catch { failures.append(source.title) }
                if catalogue.configured, let tmdb = show.tmdbID,
                   show.metadataUpdatedAt == nil || show.providerRegion != settings.region || now.timeIntervalSince(show.metadataUpdatedAt!) > 86_400 {
                    do {
                        let data = try await catalogue.details(tmdbID: tmdb, region: settings.region)
                        show.overview = data.overview; show.posterPath = data.posterPath
                        show.providers = data.providers; show.watchURL = data.watchURL
                        show.providerRegion = settings.region; show.metadataUpdatedAt = now
                    } catch { metadataFailures += 1 }
                }
                try context.save()
            }
            // Local follows persist even if Trakt removes them from the watchlist after viewing.
            if failures.isEmpty { settings.lastSync = now }
            status = "Updated \(remote.count) shows"
            if !failures.isEmpty { errorMessage = "Could not refresh episodes for: \(failures.joined(separator: ", ")). Cached data remains available. Pull to refresh to retry." }
            if metadataFailures > 0 { status += " · streaming details unavailable for \(metadataFailures) shows" }
            await reschedule()
        } catch { errorMessage = error.localizedDescription; status = "Refresh incomplete · showing cached data" }
    }
    private func merge(_ sources: [RemoteEpisode], into show: Show) {
        for source in sources {
            if let episode = show.episodes.first(where: { $0.season == source.season && $0.number == source.number }) {
                episode.traktID = source.ids.trakt; episode.title = source.title ?? "Episode \(source.number)"
                episode.overview = source.overview ?? ""; episode.firstAired = Dates.parse(source.firstAired); episode.runtime = source.runtime
            } else {
                let episode = Episode(showID: show.traktID, remote: source)
                context.insert(episode); show.episodes.append(episode)
            }
        }
        let keys = Set(sources.map { "\(show.traktID):\($0.season):\($0.number)" })
        for episode in show.episodes where !keys.contains(episode.key) { context.delete(episode) }
    }
    func setWatched(_ episode: Episode, watched: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if !settings.demoMode { try await viewing.setWatched(episodeID: episode.traktID, watched: watched) }
            episode.watchedAt = watched ? Date() : nil
            try context.save(); await reschedule()
        } catch { errorMessage = error.localizedDescription }
    }
    func skip(_ episode: Episode) async {
        guard !busy else { return }
        episode.isSkipped.toggle()
        do { try context.save(); await reschedule() } catch { errorMessage = error.localizedDescription }
    }
    func follow(_ source: RemoteShow) async {
        guard !busy else { return }
        busy = true
        do {
            try await viewing.follow(source)
            settings.hiddenShowIDs.remove(source.id)
            if let show = try allShows().first(where: { $0.traktID == source.id }) { show.isFollowing = true }
            else { context.insert(Show(traktID: source.id, tmdbID: source.ids.tmdb, title: source.title)) }
            try context.save()
        } catch { errorMessage = error.localizedDescription }
        busy = false; await refresh()
    }
    func hide(_ show: Show) async {
        guard !busy else { return }
        show.isFollowing = false; settings.hiddenShowIDs.insert(show.traktID)
        do { try context.save(); await reschedule() } catch { errorMessage = error.localizedDescription }
    }
    func loadProviders() async {
        do { providerOptions = try await catalogue.providers(region: settings.region) }
        catch { errorMessage = error.localizedDescription }
    }
    func reschedule() async {
        if let shows = try? allShows() { await Notifications.rebuild(shows: shows, includeSpecials: settings.includeSpecials, demo: settings.demoMode) }
    }
    func enableNotifications(_ show: Show, enabled: Bool) async {
        do {
            if enabled && !settings.demoMode {
                guard try await Notifications.requestPermission() else { throw APIError.message("Notifications are disabled. Enable them in iPhone Settings.") }
            }
            show.notificationsEnabled = enabled; try context.save(); await reschedule()
        } catch { errorMessage = error.localizedDescription }
    }
    private func seedDemo() throws {
        let titles = ["Harbour Lights", "The Last Signal", "Northbound"]
        let providers = [Provider(id: 8, name: "Netflix"), Provider(id: 337, name: "Disney+"), Provider(id: 350, name: "Apple TV+")]
        for index in titles.indices {
            let show = Show(traktID: -(index + 1), tmdbID: nil, title: titles[index])
            show.overview = "A fictional programme for exploring WatchMate. Demo viewing history and dates are sample data."
            show.providers = [providers[index]]; show.providerRegion = settings.region
            context.insert(show)
            for number in 1...8 {
                let remote = RemoteEpisode(season: 1, number: number, title: "Chapter \(number)",
                    ids: IDs(trakt: -(100 * (index + 1) + number), tmdb: nil), overview: "Sample episode for demo mode.",
                    firstAired: Dates.string(Date().addingTimeInterval(Double(number - 6) * 86_400)), runtime: 45 + index * 5)
                let episode = Episode(showID: show.traktID, remote: remote)
                if number <= 3 + index { episode.watchedAt = Date().addingTimeInterval(-86_400) }
                context.insert(episode); show.episodes.append(episode)
            }
        }
        providerOptions = providers
        try context.save(); status = "Demo data · fictional programmes"
    }
}
