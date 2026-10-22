import Foundation
import Observation
import SwiftData
import WidgetKit
import OSLog

@MainActor @Observable
final class AppStore {
    let settings: Settings
    let auth: TraktAuth
    let catalogue = TMDBService()
    let cloud = CloudSync()
    let sharedShows = SharedShows()
    let sharedHistoryImport = SharedHistoryImport()
    private var applyingCloudChanges = false
    private var widgetArtworkTask: Task<Void, Never>?
    @ObservationIgnored private var widgetPublicationRevision = 0
    private var cloudTask: Task<Void, Never>?
    private var cloudSyncInProgress = false
    private var lastCloudAttempt: Date?
    private var lastAppliedCloudValues: [String: Data] = [:]
    private let context: ModelContext
    private let viewing: any ViewingService
    var widgetEpisodeLink: WidgetEpisodeLink?
    var busy = false
    var seasonUpdateInProgress = false
    var seasonUpdateCompleted = 0
    var seasonUpdateTotal = 0
    var errorMessage: String?
    var status = ""
    var connected: Bool
    var providerOptions: [Provider] = []

    init(context: ModelContext, settings: Settings, viewing: (any ViewingService)? = nil) {
        let auth = TraktAuth()
        self.auth = auth; self.viewing = viewing ?? TraktService(auth: auth)
        self.context = context; self.settings = settings; connected = auth.connected
        settings.onPreferencesChanged = { [weak self] in
            self?.queueCloudChanges()
            self?.publishWidgetSnapshot()
        }
    }
    func allShows() throws -> [Show] { try context.fetch(Show.withEpisodes) }
    func hasShows() throws -> Bool {
        var descriptor = FetchDescriptor<Show>()
        descriptor.fetchLimit = 1
        return try context.fetchCount(descriptor) > 0
    }
    func waiting(_ show: Show) -> [Episode] {
        let states = EpisodeRules.waiting(show.episodes.map(\.state), now: Date(), includeSpecials: settings.includeSpecials)
        return states.compactMap { state in show.episodes.first { $0.season == state.season && $0.number == state.number } }
    }
    func upcoming(_ show: Show) -> [Episode] {
        let states = EpisodeRules.upcoming(show.episodes.map(\.state), now: Date(), includeSpecials: settings.includeSpecials)
        return states.compactMap { state in show.episodes.first { $0.season == state.season && $0.number == state.number } }
    }
    func start() async {
        guard !AppStoreScreenshotMode.isEnabled, !PreviewEnvironment.isRunning else { return }
        defer { publishWidgetSnapshot() }
        guard !busy else { return }
        if settings.demoMode {
            do {
                let shows = try allShows()
                let legacyTitles: Set<String> = ["Harbour Lights", "The Last Signal", "Northbound"]
                let isLegacyDemo = !shows.isEmpty && shows.allSatisfy {
                    $0.traktID < 0 && $0.posterPath == nil && legacyTitles.contains($0.title)
                }
                if isLegacyDemo {
                    // Only replace the old fictional demo library, never a connected account.
                    for show in shows { context.delete(show) }
                    try context.save()
                    settings.hiddenShowIDs = []
                }
                if shows.isEmpty || isLegacyDemo { try seedDemo() }
            } catch { errorMessage = error.localizedDescription }
        } else if connected {
            sharedShows.activate(accountID: settings.traktAccountID)
            await sharedShows.refresh(reportErrors: false, automatic: true)
            await syncCloud(automatic: true)
            busy = true
            await retryPendingSharedProgress()
            busy = false
            let needsCatalogue = (try? allShows().contains { $0.isFollowing && $0.catalogueUpdatedAt == nil }) ?? false
            if needsCatalogue || settings.lastSync == nil || settings.lastSync.map({ Date().timeIntervalSince($0) > 900 }) == true {
                await refresh(syncCloudFirst: false)
            }
        }
    }
    private func clearData() throws {
        for show in try allShows() { context.delete(show) }
        try context.save()
        settings.lastSync = nil; settings.hiddenShowIDs = []; settings.historyRevision = nil
        publishWidgetSnapshot()
    }
    func connect() async {
        guard !busy else { return }
        busy = true
        var signedIn = false
        do {
            queueCloudChanges()
            try await auth.signIn()
            signedIn = true
            let accountID = try await viewing.accountID()
            if settings.demoMode || settings.traktAccountID != accountID {
                cloudTask?.cancel()
                cloud.deactivate()
                try clearData()
            }
            settings.traktAccountID = accountID
            sharedShows.activate(accountID: accountID)
            settings.demoMode = false; connected = true
        } catch {
            if signedIn {
                // Never associate newly issued tokens with the previous account's cloud library.
                try? auth.disconnect()
                connected = false
                cloud.deactivate()
                settings.traktAccountID = nil
                sharedShows.activate(accountID: nil)
            }
            errorMessage = error.localizedDescription
        }
        busy = false
        if connected && !settings.demoMode { await refresh() }
    }
    func disconnect() async {
        guard !busy else { return }
        do {
            queueCloudChanges()
            cloudTask?.cancel()
            cloud.deactivate()
            settings.traktAccountID = nil
            sharedShows.activate(accountID: nil)
            try auth.disconnect(); connected = false
            try clearData(); settings.demoMode = false
            await reschedule()
        } catch { errorMessage = error.localizedDescription }
    }
    func useDemo() async {
        guard !busy else { return }
        do {
            queueCloudChanges()
            cloudTask?.cancel()
            cloud.deactivate()
            settings.traktAccountID = nil
            sharedShows.activate(accountID: nil)
            try auth.disconnect(); connected = false
            try clearData(); settings.demoMode = true
            try seedDemo(); await reschedule()
        } catch { errorMessage = error.localizedDescription }
    }
    func refresh(syncCloudFirst: Bool = true) async {
        guard !busy else { return }
        if settings.demoMode { status = "Demo data · connect Trakt for your shows"; return }
        guard connected else { errorMessage = "Connect Trakt in Settings to import your shows."; return }
        if syncCloudFirst { await syncCloud() }
        guard !busy else { return }
        busy = true; status = "Importing your shows…"
        defer { busy = false }
        await retryPendingSharedProgress()
        do {
            let service = viewing
            let watched = try await service.watchedShows()
            let listed = try await service.watchlist()
            var remote: [Int: RemoteShow] = [:]
            for show in watched.map(\.show) + listed { remote[show.id] = show }
            var local = Dictionary(uniqueKeysWithValues: try allShows().map { ($0.traktID, $0) })
            for show in local.values where show.isFollowing && remote[show.traktID] == nil {
                remote[show.traktID] = RemoteShow(title: show.title, year: nil, ids: IDs(trakt: show.traktID, tmdb: show.tmdbID, imdb: show.imdbID))
            }
            var failures: [String] = [], metadataFailures = 0
            var metadataError: String?
            let now = Date()
            for source in remote.values.sorted(by: { $0.title < $1.title }) where !settings.hiddenShowIDs.contains(source.id) {
                try Task.checkCancellation()
                status = "Updating \(source.title)…"
                let show = local[source.id] ?? Show(traktID: source.id, tmdbID: source.ids.tmdb, title: source.title, imdbID: source.ids.imdb)
                if local[source.id] == nil {
                    context.insert(show); local[source.id] = show
                    show.notificationsEnabled = cloudDecode(Bool.self, key: "reminders:\(source.id)") ?? false
                    show.reminderMinutes = cloudDecode(Int.self, key: "reminderTime:\(source.id)") ?? 540
                }
                show.title = source.title; show.tmdbID = source.ids.tmdb; show.isFollowing = true
                if let imdbID = source.ids.imdb { show.imdbID = imdbID }
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
                    } catch { metadataFailures += 1; metadataError = error.localizedDescription }
                }
                try context.save()
            }
            // Local follows persist even if Trakt removes them from the watchlist after viewing.
            if failures.isEmpty { settings.lastSync = now }
            status = "Updated \(remote.count) shows"
            if !failures.isEmpty { errorMessage = "Could not refresh episodes for: \(failures.joined(separator: ", ")). Cached data remains available. Pull to refresh to retry." }
            if metadataFailures > 0 {
                status += " · artwork and streaming details unavailable for \(metadataFailures) shows"
                if failures.isEmpty {
                    errorMessage = metadataError
                }
            }
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
                episode.isSkipped = cloudDecode(Bool.self, key: "skip:" + episode.key) ?? false
                context.insert(episode); show.episodes.append(episode)
            }
        }
        let keys = Set(sources.map { "\(show.traktID):\($0.season):\($0.number)" })
        for episode in show.episodes where !keys.contains(episode.key) { context.delete(episode) }
    }
    /// Called with the store's mutation lock held by the screen or widget.
    func updateSharedEpisodes(_ episodes: [RemoteEpisode], showID: Int, in list: HouseholdList,
                              action: SharedEpisodeAction, progress: (Int) -> Void = { _ in }) async throws {
        guard settings.sharedShowsUpdateTraktHistory, !settings.demoMode,
              case .watched(let watched) = action else {
            try await sharedShows.updateEpisodes(episodes, showID: showID, in: list, action: action, progress: progress)
            return
        }
        defer {
            publishWidgetSnapshot()
            queueCloudChanges()
        }
        for (index, episode) in episodes.enumerated() {
            try Task.checkCancellation()
            guard !watched || Dates.parse(episode.firstAired).map({ AirDates.hasAired($0) }) != false else { continue }
            try await updateTraktProgress(episode, showID: showID, watched: watched)
            do {
                try await syncAndRetainSharedProgress(episode, showID: showID, watched: watched, source: list)
            } catch {
                throw APIError.message("Your Trakt history was updated, but shared progress could not finish syncing. \(error.localizedDescription) Refresh to retry the shared update.")
            }
            progress(index + 1)
        }
        await reschedule()
    }

    private func remoteEpisode(_ episode: Episode) -> RemoteEpisode {
        RemoteEpisode(season: episode.season, number: episode.number, title: episode.title,
                      ids: IDs(trakt: episode.traktID, tmdb: nil), overview: episode.overview,
                      firstAired: episode.firstAired.map { Dates.string($0) }, runtime: episode.runtime)
    }

    func updateTraktProgress(_ episode: RemoteEpisode, showID: Int, watched: Bool) async throws {
        // Check the server, including for shared-only shows, so retries do not add another play.
        let history = try await viewing.watchedShows()
        let existing = history.first { $0.show.id == showID }?.seasons
            .first { $0.number == episode.season }?.episodes.first { $0.number == episode.number }
        if (existing != nil) != watched {
            try await viewing.setWatched(episodeID: episode.ids.trakt, watched: watched)
        }
        if let local = try allShows().first(where: { $0.traktID == showID })?.episodes
            .first(where: { $0.season == episode.season && $0.number == episode.number }) {
            local.watchedAt = watched ? (Dates.parse(existing?.lastWatchedAt) ?? Date()) : nil
            if watched { local.isSkipped = false }
            try context.save()
        }
        settings.historyRevision = UUID().uuidString
        publishWidgetSnapshot()
    }

    func refreshSharedShows() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await sharedShows.refresh()
        await retryPendingSharedProgress()
    }

    private struct PendingSharedProgress: Codable {
        let episode: RemoteEpisode
        let showID: Int
        let watched: Bool
        var key: String { "\(showID):\(episode.season):\(episode.number)" }
    }

    private func pendingSharedProgress(accountID: String) throws -> [String: PendingSharedProgress] {
        guard let data = UserDefaults.standard.data(forKey: "pendingSharedProgress:" + accountID) else { return [:] }
        return try JSONDecoder().decode([String: PendingSharedProgress].self, from: data)
    }

    private func savePendingSharedProgress(_ pending: [String: PendingSharedProgress], accountID: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(pending), forKey: "pendingSharedProgress:" + accountID)
    }

    private func syncAndRetainSharedProgress(_ episode: RemoteEpisode, showID: Int, watched: Bool,
                                            source: HouseholdList? = nil) async throws {
        guard settings.sharedShowsUpdateTraktHistory, !settings.demoMode,
              let accountID = settings.traktAccountID else { return }
        let change = PendingSharedProgress(episode: episode, showID: showID, watched: watched)
        var pending = try pendingSharedProgress(accountID: accountID)
        pending[change.key] = change
        try savePendingSharedProgress(pending, accountID: accountID)
        try await syncSharedProgress(episode, showID: showID, watched: watched, source: source)
        pending = try pendingSharedProgress(accountID: accountID)
        pending.removeValue(forKey: change.key)
        try savePendingSharedProgress(pending, accountID: accountID)
    }

    /// Retry only the iCloud side of acknowledged Trakt writes, including after a relaunch.
    private func retryPendingSharedProgress() async {
        guard settings.sharedShowsUpdateTraktHistory, !settings.demoMode, connected,
              let accountID = settings.traktAccountID else { return }
        do {
            let pending = try pendingSharedProgress(accountID: accountID)
            guard !pending.isEmpty else { return }
            let history = try await viewing.watchedShows()
            for change in pending.values {
                try Task.checkCancellation()
                guard settings.traktAccountID == accountID else { return }
                // A later action on another device (or while the toggle was off) wins over this retry.
                let watched = history.first { $0.show.id == change.showID }?.seasons
                    .first { $0.number == change.episode.season }?.episodes
                    .contains { $0.number == change.episode.number } == true
                try await syncAndRetainSharedProgress(change.episode, showID: change.showID, watched: watched)
            }
        } catch {
            errorMessage = "Your Trakt history is saved. Shared progress is waiting to sync; refresh to retry. \(error.localizedDescription)"
        }
    }

    private func syncSharedProgress(_ episode: RemoteEpisode, showID: Int, watched: Bool,
                                    source: HouseholdList? = nil) async throws {
        guard settings.sharedShowsUpdateTraktHistory, !settings.demoMode else { return }
        sharedShows.activate(accountID: settings.traktAccountID)
        while sharedShows.loading {
            try await Task.sleep(for: .milliseconds(50))
        }
        await sharedShows.refresh(reportErrors: false, automatic: true)
        if let message = sharedShows.refreshMessage {
            throw APIError.message(message)
        }
        var lists = sharedShows.lists.filter { $0.programmes.contains { $0.id == showID } }
        if let source, !lists.contains(where: { $0.id == source.id }) { lists.append(source) }
        for list in lists {
            guard let programme = list.programmes.first(where: { $0.id == showID }) else { continue }
            let alreadyWatched = programme.episodes.contains { $0.id == episode.ids.trakt }
            if alreadyWatched == watched && (!watched || programme.skippedEpisodeIDs?.contains(episode.ids.trakt) != true) { continue }
            try await sharedShows.setWatched(episode, showID: showID, in: list, watched: watched)
        }
    }

    private func updatePersonalProgress(_ episode: Episode, watched: Bool) async throws {
        if !settings.demoMode {
            if settings.sharedShowsUpdateTraktHistory, let showID = episode.show?.traktID {
                try await updateTraktProgress(remoteEpisode(episode), showID: showID, watched: watched)
            } else {
                try await viewing.setWatched(episodeID: episode.traktID, watched: watched)
            }
        }
        episode.watchedAt = watched ? (episode.watchedAt ?? Date()) : nil
        try context.save()
        if !settings.demoMode { settings.historyRevision = UUID().uuidString }
        if let showID = episode.show?.traktID {
            do {
                try await syncAndRetainSharedProgress(remoteEpisode(episode), showID: showID, watched: watched)
            } catch {
                throw APIError.message("Your Trakt history was updated, but shared progress could not finish syncing. \(error.localizedDescription) Refresh to retry the shared update.")
            }
        }
    }

    func setWatched(_ episode: Episode, watched: Bool) async {
        guard !busy, !watched || !episode.isScheduledInFuture else { return }
        busy = true; defer { busy = false }
        do {
            try await updatePersonalProgress(episode, watched: watched)
        } catch { errorMessage = error.localizedDescription }
        await reschedule()
    }
    func markSeasonWatched(_ show: Show, season: Int) async {
        guard !busy else { return }
        busy = true
        seasonUpdateInProgress = true
        seasonUpdateCompleted = 0
        let episodes = show.episodes.filter { $0.season == season && !$0.isScheduledInFuture }.sorted { $0.number < $1.number }
        seasonUpdateTotal = episodes.count
        let previousStatus = status
        status = "Marking season watched…"
        defer {
            seasonUpdateInProgress = false
            busy = false
            status = previousStatus
        }

        // Stage confirmed results so observed episode rows change together, even after a partial failure.
        var confirmed: [(episode: Episode, watchedAt: Date)] = []
        var failureMessage: String?
        do {
            for episode in episodes {
                try Task.checkCancellation()
                if settings.sharedShowsUpdateTraktHistory {
                    try await updatePersonalProgress(episode, watched: true)
                } else if episode.watchedAt == nil && !settings.demoMode {
                    try await viewing.setWatched(episodeID: episode.traktID, watched: true)
                }
                confirmed.append((episode, episode.watchedAt ?? Date()))
                seasonUpdateCompleted += 1
            }
        } catch {
            failureMessage = "Updated \(confirmed.count) of \(episodes.count) episodes. \(error.localizedDescription) You can retry to finish the season."
        }

        for result in confirmed {
            result.episode.watchedAt = result.watchedAt
            result.episode.isSkipped = false
        }
        do {
            try context.save()
            if !confirmed.isEmpty && !settings.demoMode { settings.historyRevision = UUID().uuidString }
        } catch {
            failureMessage = "Could not save the season update. Pull to refresh to reload your Trakt history. \(error.localizedDescription)"
        }
        await reschedule()
        if let failureMessage { errorMessage = failureMessage }
    }

    func skipSeason(_ show: Show, season: Int) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        for episode in show.episodes where episode.season == season {
            episode.isSkipped = true
        }
        do { try context.save(); await reschedule() } catch { errorMessage = error.localizedDescription }
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
            else { context.insert(Show(traktID: source.id, tmdbID: source.ids.tmdb, title: source.title, imdbID: source.ids.imdb)) }
            try context.save()
        } catch { errorMessage = error.localizedDescription }
        busy = false; await refresh()
    }
    func returnToMyShows(_ programme: SharedProgramme, from list: HouseholdList) async throws {
        guard !busy else { throw APIError.message("Please wait for the current update to finish.") }
        busy = true
        defer { busy = false }
        let account = settings.traktAccountID
        // Establish the personal entry before removing the shared copy.
        try await viewing.follow(programme.show)
        guard settings.traktAccountID == account else { throw CancellationError() }
        if let show = try allShows().first(where: { $0.traktID == programme.id }) {
            show.isFollowing = true
        } else {
            context.insert(Show(traktID: programme.id, tmdbID: programme.show.ids.tmdb, title: programme.show.title, imdbID: programme.show.ids.imdb))
        }
        settings.hiddenShowIDs.remove(programme.id)
        try context.save()
        try await sharedShows.remove(programme, from: list)
        guard settings.traktAccountID == account else { throw CancellationError() }
        sharedShows.showInMyShows(programme.id)
        await reschedule()
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
        guard !AppStoreScreenshotMode.isEnabled, !PreviewEnvironment.isRunning else { return }
        publishWidgetSnapshot()
        queueCloudChanges()
        if let shows = try? allShows() { await Notifications.rebuild(shows: shows, includeSpecials: settings.includeSpecials, demo: settings.demoMode) }
    }
    func setReminderTime(_ show: Show, date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        show.reminderMinutes = (components.hour ?? 9) * 60 + (components.minute ?? 0)
        do {
            try context.save()
            Task { await reschedule() }
        } catch { errorMessage = error.localizedDescription }
    }

    func enableNotifications(_ show: Show, enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if enabled && !settings.demoMode {
                guard try await Notifications.requestPermission() else { throw APIError.message("Notifications are disabled. Enable them in iPhone Settings.") }
            }
            show.notificationsEnabled = enabled; try context.save(); await reschedule()
        } catch { errorMessage = error.localizedDescription }
    }
    private func cloudSnapshot() throws -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var snapshot: [String: Data] = [
            "onlyMyServices": try encoder.encode(settings.highlightAvailableServices),
            "region": try encoder.encode(settings.region),
            "specials": try encoder.encode(settings.includeSpecials),
            "sharedShowsUpdateTraktHistory": try encoder.encode(settings.sharedShowsUpdateTraktHistory),
            "providers": try encoder.encode(settings.selectedProviders.sorted())
        ]
        try settings.prepareProfilePhotoForSync()
        if let photo = settings.profilePhotoData { snapshot["profilePhoto"] = photo }
        if let revision = settings.historyRevision { snapshot["historyRevision"] = try encoder.encode(revision) }
        for show in try allShows() where show.traktID > 0 {
            let source = RemoteShow(title: show.title, year: nil, ids: IDs(trakt: show.traktID, tmdb: show.tmdbID, imdb: show.imdbID))
            snapshot["show:\(show.traktID)"] = try encoder.encode(source)
            snapshot["following:\(show.traktID)"] = try encoder.encode(show.isFollowing && !settings.hiddenShowIDs.contains(show.traktID))
            snapshot["reminders:\(show.traktID)"] = try encoder.encode(show.notificationsEnabled)
            snapshot["reminderTime:\(show.traktID)"] = try encoder.encode(show.reminderMinutes)
            for episode in show.episodes where episode.isSkipped || cloud.data(for: "skip:" + episode.key) != nil {
                snapshot["skip:" + episode.key] = try encoder.encode(episode.isSkipped)
            }
        }
        // Keep hidden preferences even if their cached catalogue has already been removed.
        for id in settings.hiddenShowIDs {
            snapshot["following:\(id)"] = try encoder.encode(false)
        }
        return snapshot
    }

    private func cloudDecode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = cloud.data(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func applyCloudValues() throws {
        applyingCloudChanges = true
        defer { applyingCloudChanges = false }
        if let photo = cloud.data(for: "profilePhoto") {
            try settings.applyProfilePhotoData(photo)
        }
        if let revision = cloudDecode(String.self, key: "historyRevision"), revision != settings.historyRevision {
            settings.historyRevision = revision
            settings.lastSync = nil
        }
        if let filter = cloudDecode(Bool.self, key: "onlyMyServices") { settings.highlightAvailableServices = filter }
        if let region = cloudDecode(String.self, key: "region") { settings.region = region }
        if let specials = cloudDecode(Bool.self, key: "specials") { settings.includeSpecials = specials }
        if let sharedHistory = cloudDecode(Bool.self, key: "sharedShowsUpdateTraktHistory") { settings.sharedShowsUpdateTraktHistory = sharedHistory }
        if let providers = cloudDecode([Int].self, key: "providers") { settings.selectedProviders = Set(providers) }
        var shows = Dictionary(uniqueKeysWithValues: try allShows().map { ($0.traktID, $0) })
        for (key, data) in cloud.values where key.hasPrefix("show:") {
            let source = try JSONDecoder().decode(RemoteShow.self, from: data)
            if shows[source.id] == nil {
                let show = Show(traktID: source.id, tmdbID: source.ids.tmdb, title: source.title, imdbID: source.ids.imdb)
                context.insert(show)
                shows[source.id] = show
            }
        }
        for (key, data) in cloud.values where key.hasPrefix("following:") {
            guard let id = Int(key.dropFirst("following:".count)) else { continue }
            let following = try JSONDecoder().decode(Bool.self, from: data)
            if following { settings.hiddenShowIDs.remove(id) } else { settings.hiddenShowIDs.insert(id) }
            shows[id]?.isFollowing = following
        }
        for show in shows.values {
            if let enabled = cloudDecode(Bool.self, key: "reminders:\(show.traktID)") {
                show.notificationsEnabled = enabled
            }
            if let minutes = cloudDecode(Int.self, key: "reminderTime:\(show.traktID)"), (0..<1440).contains(minutes) {
                show.reminderMinutes = minutes
            }
            for episode in show.episodes {
                if let skipped = cloudDecode(Bool.self, key: "skip:" + episode.key) {
                    episode.isSkipped = skipped
                }
            }
        }
        try context.save()
        try cloud.accept(cloudSnapshot())
    }

    func queueCloudChanges() {
        guard !applyingCloudChanges, !settings.demoMode, connected, cloud.accountID != nil else { return }
        do { try cloud.capture(cloudSnapshot()) } catch { cloud.report(error) }
        guard cloud.pendingCount > 0, !cloudSyncInProgress else { return }
        cloudTask?.cancel()
        cloudTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            await self.syncCloud()
        }
    }

    func syncCloud(automatic: Bool = false) async {
        guard !busy, !cloudSyncInProgress, connected, !settings.demoMode else { return }
        // Idle polling is infrequent; explicit refreshes and queued edits bypass this throttle.
        if automatic, cloud.accountID == settings.traktAccountID, let lastCloudAttempt {
            let interval: TimeInterval = cloud.pendingCount > 0 ? 60 : 300
            guard Date().timeIntervalSince(lastCloudAttempt) >= interval else { return }
        }
        cloudSyncInProgress = true
        lastCloudAttempt = Date()
        defer { cloudSyncInProgress = false }
        do {
            if settings.traktAccountID == nil {
                let accountID = try await viewing.accountID()
                guard connected, !settings.demoMode else { return }
                settings.traktAccountID = accountID
            }
            guard let accountID = settings.traktAccountID else { return }
            if cloud.accountID != accountID {
                try cloud.activate(accountID: accountID)
                lastAppliedCloudValues = [:]
                try cloud.capture(cloudSnapshot(), initial: cloud.values.isEmpty)
            } else {
                try cloud.capture(cloudSnapshot())
            }
            await cloud.synchronize()
            guard connected, !settings.demoMode, settings.traktAccountID == accountID,
                  cloud.accountID == accountID, !busy else { return }
            // Capture edits made while the network request was suspended before applying remote values.
            try cloud.capture(cloudSnapshot())
            let values = cloud.values
            if values != lastAppliedCloudValues {
                try applyCloudValues()
                publishWidgetSnapshot()
                lastAppliedCloudValues = cloud.values
                if let shows = try? allShows() {
                    await Notifications.rebuild(shows: shows, includeSpecials: settings.includeSpecials, demo: false)
                }
            }
        } catch { cloud.report(error) }
    }

    func episode(forWidgetLink link: WidgetEpisodeLink) -> Episode? {
        guard link.accountScope == widgetAccountScope,
              let shows = try? allShows() else { return nil }
        return shows.filter { $0.isFollowing && !settings.hiddenShowIDs.contains($0.traktID) }
            .flatMap(\.episodes)
            .first { $0.key == link.episodeKey }
    }

    var widgetAccountScope: String {
        settings.demoMode ? "demo" : (settings.traktAccountID ?? "")
    }

    func widgetLibrary() throws -> WidgetLibrary {
        guard settings.demoMode || connected else { return .empty }
        return try Self.widgetLibrary(context: context, accountScope: widgetAccountScope,
                                      hiddenShowIDs: settings.hiddenShowIDs, includeSpecials: settings.includeSpecials)
    }

    nonisolated private static func widgetLibrary(context: ModelContext, accountScope: String,
                                                 hiddenShowIDs: Set<Int>, includeSpecials: Bool) throws -> WidgetLibrary {
        let shows = try context.fetch(Show.withEpisodes)
            .filter { $0.isFollowing && !hiddenShowIDs.contains($0.traktID) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { show in
                let episodes = show.episodes.compactMap { episode -> WidgetEpisode? in
                    guard episode.watchedAt == nil, !episode.isSkipped,
                          includeSpecials || episode.season > 0,
                          let firstAired = episode.firstAired else { return nil }
                    return WidgetEpisode(
                        id: episode.key, season: episode.season, number: episode.number,
                        title: episode.title, overview: episode.overview,
                        firstAired: firstAired, runtime: episode.runtime
                    )
                }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
                return WidgetShow(id: show.traktID, title: show.title, episodes: episodes, posterPath: show.posterPath)
            }
        return WidgetLibrary(accountScope: accountScope, shows: shows)
    }

    /// Resolve persisted relationships in a context created off the main actor.
    func publishStartupWidgetSnapshot() {
        guard !AppStoreScreenshotMode.isEnabled, !PreviewEnvironment.isRunning else { return }
        let container = context.container
        let accountScope = widgetAccountScope
        let hiddenShowIDs = settings.hiddenShowIDs
        let includeSpecials = settings.includeSpecials
        let enabled = settings.demoMode || connected
        let revision = widgetPublicationRevision
        Task { [weak self] in
            do {
                let library = try await Task.detached(priority: .utility) {
                    guard enabled else { return WidgetLibrary.empty }
                    let context = ModelContext(container)
                    return try Self.widgetLibrary(context: context, accountScope: accountScope,
                                                  hiddenShowIDs: hiddenShowIDs, includeSpecials: includeSpecials)
                }.value
                // A refresh, account change, or preference edit may have published newer data.
                guard let self, self.widgetPublicationRevision == revision else { return }
                self.publishWidgetSnapshot(library: library)
            } catch {
                Logger(subsystem: "net.andrewroland.WatchMate", category: "Widget")
                    .error("Could not load startup widget data: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func publishWidgetSnapshot(errorShowID: Int? = nil, message: String? = nil) {
        publishWidgetSnapshot(library: nil, errorShowID: errorShowID, message: message)
    }

    private func publishWidgetSnapshot(library: WidgetLibrary?, errorShowID: Int? = nil, message: String? = nil) {
        guard !AppStoreScreenshotMode.isEnabled, !PreviewEnvironment.isRunning else { return }
        widgetPublicationRevision += 1
        do {
            var library = try library ?? widgetLibrary()
            library.errorShowID = errorShowID
            library.errorMessage = message
            if try WidgetSnapshotStore.write(library) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
            }
            if widgetArtworkTask == nil, catalogue.configured, !settings.demoMode {
                widgetArtworkTask = Task { [weak self] in
                    guard let self else { return }
                    await self.prepareWidgetArtwork()
                    self.widgetArtworkTask = nil
                }
            }
        } catch {
            Logger(subsystem: "net.andrewroland.WatchMate", category: "Widget")
                .error("Could not publish widget data: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cache metadata ahead of time; WidgetKit downloads images before rendering its timeline.
    private func prepareWidgetArtwork(showID: Int? = nil) async {
        guard catalogue.configured, !settings.demoMode, let shows = try? allShows() else { return }
        let scope = widgetAccountScope
        var changed = false
        for show in shows where show.isFollowing && (showID == nil || show.traktID == showID) {
            guard let tmdbID = show.tmdbID else { continue }
            let candidates = Array(waiting(show).prefix(2)) + Array(upcoming(show).prefix(1))
            for episode in candidates {
                guard !Task.isCancelled, scope == widgetAccountScope else { return }
                if let cached = WidgetArtworkStore.read(for: episode.key),
                   Date().timeIntervalSince(cached.fetchedAt) < 21_600 { continue }
                do {
                    let paths = try await catalogue.episodeArtwork(tmdbID: tmdbID, season: episode.season, episode: episode.number)
                    try WidgetArtworkStore.write(paths: paths, for: episode.key)
                    changed = true
                } catch {
                    // The widget can still use the programme poster from its snapshot.
                }
            }
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind) }
    }

    /// Acts on the episode rendered in the widget, never on a newly advanced episode.
    func performWidgetAction(showID: Int, episodeKey: String, accountScope: String, markWatched: Bool) async throws {
        guard !busy else {
            publishWidgetSnapshot(errorShowID: showID, message: String(localized: WidgetActionError.busy.localizedStringResource))
            throw WidgetActionError.busy
        }
        guard !accountScope.isEmpty, accountScope == widgetAccountScope,
              settings.demoMode || connected,
              let show = try allShows().first(where: { $0.traktID == showID && $0.isFollowing }),
              !settings.hiddenShowIDs.contains(showID),
              let episode = show.episodes.first(where: { $0.key == episodeKey }) else {
            publishWidgetSnapshot()
            throw WidgetActionError.changed
        }
        // Replayed taps must not add another Trakt play or toggle a skip back off.
        guard episode.watchedAt == nil, !episode.isSkipped else {
            // A previous attempt may have saved Trakt before a shared-list write failed.
            if markWatched && episode.watchedAt != nil {
                busy = true
                defer { busy = false }
                do {
                    try await syncAndRetainSharedProgress(remoteEpisode(episode), showID: showID, watched: true)
                } catch {
                    publishWidgetSnapshot(errorShowID: showID, message: error.localizedDescription)
                    throw WidgetActionError.updateFailed
                }
            }
            publishWidgetSnapshot()
            return
        }
        guard waiting(show).first?.key == episodeKey else {
            publishWidgetSnapshot()
            throw WidgetActionError.changed
        }
        busy = true
        do {
            if markWatched {
                try await updatePersonalProgress(episode, watched: true)
            } else {
                episode.isSkipped = true
            }
            try context.save()
            if markWatched && !settings.demoMode { settings.historyRevision = UUID().uuidString }
        } catch {
            context.rollback()
            busy = false
            errorMessage = error.localizedDescription
            publishWidgetSnapshot(errorShowID: showID, message: String(localized: WidgetActionError.updateFailed.localizedStringResource))
            throw WidgetActionError.updateFailed
        }
        await reschedule()
        busy = false
        await prepareWidgetArtwork(showID: showID)
        // Capture and attempt to send skips/history revisions before background execution ends.
        await syncCloud()
    }

    private func seedDemo() throws {
        try DemoLibrary.seed(in: context)
        providerOptions = Array(Set(try allShows().flatMap(\.providers))).sorted { $0.name < $1.name }
        status = "Demo data · sample viewing progress"
    }
}
