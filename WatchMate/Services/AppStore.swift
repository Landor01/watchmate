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
    private var backgroundRefreshInProgress = false
    private var lastProgressAttempt: Date?
    private var catalogueAttempts: [Int: Date] = [:]
    private var mutationRevision = 0
    private var refreshingShowIDs: Set<Int> = []
    private var lastAppliedCloudValues: [String: Data] = [:]
    private let context: ModelContext
    private let viewing: any ViewingService
    var widgetEpisodeLink: WidgetEpisodeLink?
    var busy = false {
        didSet {
            // Each operation supplies its own message; never reuse a previous refresh summary.
            if busy && !oldValue {
                mutationRevision += 1
                status = String(localized: "Working…")
            }
        }
    }
    var seasonUpdateInProgress = false
    var seasonUpdateCompleted = 0
    var seasonUpdateTotal = 0
    var errorMessage: String?
    var status = ""
    var connected: Bool
    var providerOptions: [Provider] = []
    private(set) var catalogueRevision = 0

    init(context: ModelContext, settings: Settings, viewing: (any ViewingService)? = nil) {
        let auth = TraktAuth()
        self.auth = auth; self.viewing = viewing ?? TraktService(auth: auth)
        self.context = context; self.settings = settings; connected = auth.connected
        sharedShows.onMembershipChanged = { [weak self] in self?.publishWidgetSnapshot() }
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
            // Cached SwiftData is already visible. No library import on ordinary launches.
            publishWidgetSnapshot()
            await refreshInBackground()

        }
    }
    /// Read-only background work never holds the UI mutation lock. A newer action
    /// invalidates the response before it can overwrite local progress.
    func refreshInBackground(now: Date = Date(), synchronizeCloud: Bool = true) async {
        guard !busy, !backgroundRefreshInProgress, connected, !settings.demoMode else { return }
        backgroundRefreshInProgress = true
        defer { backgroundRefreshInProgress = false }
        let account = settings.traktAccountID
        let revision = mutationRevision
        func canApply() -> Bool {
            !Task.isCancelled && !busy && connected && !settings.demoMode
                && settings.traktAccountID == account && mutationRevision == revision
        }
        var snapshot: [WatchedShow]?
        if RefreshPolicy.isStale(lastProgressAttempt, interval: 900, now: now) {
            lastProgressAttempt = now
            do {
                let history = try await viewing.watchedShows()
                guard canApply() else { return }
                snapshot = history
                for show in try allShows() {
                    applyHistory(history, to: show)
                }
                try context.save()
                publishWidgetSnapshot()
            } catch { /* Keep saved progress when offline; manual refresh reports errors. */ }
        }
        guard canApply() else { return }
        if synchronizeCloud {
            sharedShows.activate(accountID: account)
            await sharedShows.refresh(reportErrors: false, automatic: true)
            guard canApply() else { return }
            await syncCloud(automatic: true)
            guard canApply() else { return }
        }

        // One request at a time, with a small work budget per foreground check.
        // Persist successful timestamps; failed requests are throttled in this session.
        let candidates = ((try? allShows()) ?? []).filter {
            $0.isFollowing && !settings.hiddenShowIDs.contains($0.traktID)
                && RefreshPolicy.refreshAutomatically(status: $0.seriesStatus,
                    updatedAt: $0.catalogueUpdatedAt, attemptedAt: catalogueAttempts[$0.traktID], now: now)
        }.sorted { ($0.catalogueUpdatedAt ?? .distantPast) < ($1.catalogueUpdatedAt ?? .distantPast) }
        if !candidates.isEmpty && snapshot == nil {
            snapshot = try? await viewing.watchedShows()
            guard canApply(), snapshot != nil else { return }
        }
        for show in candidates.prefix(5) {
            guard canApply() else { return }
            catalogueAttempts[show.traktID] = now
            await refreshShow(show, now: now, history: snapshot)
        }
        guard canApply() else { return }
        let localIDs = Set(((try? allShows()) ?? []).map(\.traktID))
        var seen = localIDs
        let shared = sharedShows.lists.flatMap(\.programmes).filter { seen.insert($0.id).inserted }
        var remaining = max(0, 5 - candidates.prefix(5).count)
        for programme in shared where remaining > 0 {
            let cached = EpisodeCatalogueCache.read(programme.id)
            guard RefreshPolicy.refreshAutomatically(status: cached?.seriesStatus,
                updatedAt: cached?.updatedAt, attemptedAt: catalogueAttempts[programme.id], now: now) else { continue }
            guard canApply() else { return }
            remaining -= 1
            catalogueAttempts[programme.id] = now
            do {
                let episodes = try await viewing.episodes(showID: programme.id)
                guard canApply() else { return }
                var seriesStatus = cached?.seriesStatus
                if let tmdbID = programme.show.ids.tmdb, catalogue.configured {
                    seriesStatus = try await catalogue.details(tmdbID: tmdbID, region: settings.region).seriesStatus
                }
                guard canApply() else { return }
                EpisodeCatalogueCache.save(episodes, showID: programme.id, now: now, seriesStatus: seriesStatus)
                catalogueRevision += 1
            } catch { /* Keep the saved shared catalogue available offline. */ }
        }
        // Acknowledge queued shared writes only while holding the mutation lock.
        if synchronizeCloud, canApply(), let account,
           let pending = try? pendingSharedProgress(accountID: account), !pending.isEmpty {
            busy = true
            status = String(localized: "Syncing shared progress…")
            await retryPendingSharedProgress(history: snapshot)
            busy = false
        }
    }

    func refreshShow(_ show: Show, now: Date = Date(), history: [WatchedShow]? = nil) async {
        guard !busy, connected, !settings.demoMode, !PreviewEnvironment.isRunning,
              !refreshingShowIDs.contains(show.traktID),
              RefreshPolicy.isStale(show.catalogueUpdatedAt, interval: 21_600, now: now) else { return }
        let id = show.traktID
        refreshingShowIDs.insert(id)
        defer { refreshingShowIDs.remove(id) }
        let account = settings.traktAccountID
        let revision = mutationRevision
        let region = settings.region
        do {
            let snapshot: [WatchedShow]
            if let history { snapshot = history } else { snapshot = try await viewing.watchedShows() }
            try Task.checkCancellation()
            guard !busy, mutationRevision == revision, settings.traktAccountID == account else { return }
            let episodes = try await viewing.episodes(showID: id)
            guard !Task.isCancelled, !busy, mutationRevision == revision,
                  settings.traktAccountID == account, connected, !settings.demoMode,
                  show.modelContext != nil else { return }
            merge(episodes, into: show)
            applyHistory(snapshot, to: show)
            catalogueRevision += 1
            show.catalogueUpdatedAt = now
            show.episodeIMDbIDsLoaded = true
            try context.save()
            publishWidgetSnapshot()
            if catalogue.configured, let tmdbID = show.tmdbID,
               RefreshPolicy.isStale(show.metadataUpdatedAt, interval: 86_400, now: now) || show.providerRegion != region || show.seriesStatus == nil {
                let details = try await catalogue.details(tmdbID: tmdbID, region: region)
                guard !Task.isCancelled, !busy, mutationRevision == revision,
                      settings.traktAccountID == account, settings.region == region,
                      show.modelContext != nil else { return }
                show.overview = details.overview
                show.posterPath = details.posterPath
                show.providers = details.providers
                show.watchURL = details.watchURL
                show.seriesStatus = details.seriesStatus
                show.providerRegion = region
                show.metadataUpdatedAt = now
                try context.save()
            }
            await reschedule(prefetchArtwork: false)
        } catch { /* Opening a show keeps its saved content usable offline. */ }
    }

    private func applyHistory(_ history: [WatchedShow], to show: Show) {
        let snapshot = history.first { $0.show.id == show.traktID }
        var dates: [String: Date] = [:]
        for season in snapshot?.seasons ?? [] {
            for episode in season.episodes {
                dates["\(season.number):\(episode.number)"] = Dates.parse(episode.lastWatchedAt) ?? .distantPast
            }
        }
        for episode in show.episodes {
            episode.watchedAt = dates["\(episode.season):\(episode.number)"]
        }
    }

    private func clearData() throws {
        for show in try allShows() { context.delete(show) }
        try context.save()
        lastProgressAttempt = nil
        catalogueAttempts = [:]
        mutationRevision += 1
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
    func refresh(syncCloudFirst: Bool = true, showIDs: Set<Int>? = nil) async {
        guard !busy else { return }
        if settings.demoMode { status = "Demo data · connect Trakt for your shows"; return }
        guard connected else { errorMessage = "Connect Trakt in Settings to import your shows."; return }
        if syncCloudFirst { await syncCloud() }
        guard !busy else { return }
        busy = true; status = "Importing your shows…"
        defer { busy = false }
        do {
            let service = viewing
            let watched = try await service.watchedShows()
            await retryPendingSharedProgress(history: watched)
            let listed = showIDs == nil ? try await service.watchlist() : []
            var remote: [Int: RemoteShow] = [:]
            for show in watched.map(\.show) + listed { remote[show.id] = show }
            var local = Dictionary(uniqueKeysWithValues: try allShows().map { ($0.traktID, $0) })
            for show in local.values where show.isFollowing && remote[show.traktID] == nil {
                remote[show.traktID] = RemoteShow(title: show.title, year: nil, ids: IDs(trakt: show.traktID, tmdb: show.tmdbID, imdb: show.imdbID))
            }
            var failures: [String] = [], metadataFailures = 0
            var metadataError: String?
            let now = Date()
            for source in remote.values.sorted(by: { $0.title < $1.title }) where !settings.hiddenShowIDs.contains(source.id) && (showIDs == nil || showIDs?.contains(source.id) == true) {
                try Task.checkCancellation()
                status = "Updating \(source.title)…"
                let show = local[source.id] ?? Show(traktID: source.id, tmdbID: source.ids.tmdb, title: source.title, imdbID: source.ids.imdb)
                if local[source.id] == nil {
                    context.insert(show); local[source.id] = show
                    show.notificationsEnabled = cloudDecode(Bool.self, key: "reminders:\(source.id)") ?? false
                    show.reminderMinutes = cloudDecode(Int.self, key: "reminderTime:\(source.id)") ?? 540
                    show.notes = cloudDecode(String.self, key: "notes:\(source.id)") ?? ""
                }
                show.title = source.title; show.tmdbID = source.ids.tmdb; show.isFollowing = true
                if let imdbID = source.ids.imdb { show.imdbID = imdbID }
                do {
                    let episodes = try await service.refreshEpisodes(showID: source.id)
                    merge(episodes, into: show); show.catalogueUpdatedAt = now
                    show.episodeIMDbIDsLoaded = true
                    catalogueRevision += 1
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
                        show.seriesStatus = data.seriesStatus
                    } catch { metadataFailures += 1; metadataError = error.localizedDescription }
                }
                try context.save()
            }
            // Local follows persist even if Trakt removes them from the watchlist after viewing.
            if failures.isEmpty && showIDs == nil { settings.lastSync = now }
            status = showIDs == nil ? "Library refreshed" : "Selected programmes refreshed"
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
                episode.imdbID = source.ids.imdb
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
        switch action {
        case .watched(let watched):
            status = watched ? String(localized: "Marking watched…") : String(localized: "Marking unwatched…")
        case .skipped(let skipped):
            status = skipped ? String(localized: "Skipping episodes…") : String(localized: "Restoring skipped episodes…")
        }
        guard settings.sharedShowsUpdateTraktHistory, !settings.demoMode,
              case .watched(let watched) = action else {
            try await sharedShows.updateEpisodes(episodes, showID: showID, in: list, action: action, progress: progress)
            return
        }
        defer {
            publishWidgetSnapshot()
            queueCloudChanges()
        }
        if watched {
            let eligible = episodes.filter { Dates.parse($0.firstAired).map { AirDates.hasAired($0) } != false }
            let confirmed = try await markTraktEpisodesWatched(eligible, showID: showID)
            try saveConfirmedWatches(eligible, showID: showID, confirmed: confirmed)
            let accepted = eligible.filter { confirmed[$0.ids.trakt] != nil }
            try await syncAndRetainSharedEpisodes(accepted, showID: showID, source: list, progress: progress)
            await reschedule()
            guard accepted.count == eligible.count else {
                throw APIError.message("Trakt could not find \(eligible.count - accepted.count) episodes. Confirmed watches were saved; refresh before retrying.")
            }
            return
        }
        let confirmed = try await markTraktEpisodesUnwatched(episodes, showID: showID)
        let accepted = episodes.filter { confirmed.contains($0.ids.trakt) }
        try await syncAndRetainSharedEpisodes(accepted, showID: showID, watched: false, source: list, progress: progress)
        guard accepted.count == episodes.count else {
            throw APIError.message("Trakt could not find some episodes. Confirmed removals were saved; refresh before retrying.")
        }
        await reschedule()
    }

    /// One history snapshot and at most one write, regardless of season length.
    func markTraktEpisodesWatched(_ episodes: [RemoteEpisode], showID: Int) async throws -> [Int: Date] {
        guard !episodes.isEmpty else { return [:] }
        let history = try await viewing.watchedShows().first { $0.show.id == showID }
        var existing: [String: Date] = [:]
        for season in history?.seasons ?? [] {
            for episode in season.episodes {
                existing["\(season.number):\(episode.number)"] = Dates.parse(episode.lastWatchedAt) ?? .distantPast
            }
        }
        var confirmed: [Int: Date] = [:]
        var missing: [Int] = []
        for episode in episodes {
            if let date = existing["\(episode.season):\(episode.number)"] {
                confirmed[episode.ids.trakt] = date
            } else {
                missing.append(episode.ids.trakt)
            }
        }
        try Task.checkCancellation()
        if !missing.isEmpty {
            let date = Date()
            let accepted = try await viewing.markWatched(episodeIDs: missing)
            for id in accepted where missing.contains(id) { confirmed[id] = date }
        }
        return confirmed
    }

    func markTraktEpisodesUnwatched(_ episodes: [RemoteEpisode], showID: Int) async throws -> Set<Int> {
        guard !episodes.isEmpty else { return [] }
        let history = try await viewing.watchedShows().first { $0.show.id == showID }
        let watched = Set(history?.seasons.flatMap { season in
            season.episodes.map { "\(season.number):\($0.number)" }
        } ?? [])
        let removals = Set(episodes.filter { watched.contains("\($0.season):\($0.number)") }.map(\.ids.trakt))
        var confirmed = Set(episodes.map(\.ids.trakt)).subtracting(removals)
        try Task.checkCancellation()
        if !removals.isEmpty {
            let accepted = try await viewing.markUnwatched(episodeIDs: removals.sorted())
            confirmed.formUnion(accepted.intersection(removals))
        }
        let local = try allShows().first { $0.traktID == showID }
        for episode in episodes where confirmed.contains(episode.ids.trakt) {
            local?.episodes.first { $0.season == episode.season && $0.number == episode.number }?.watchedAt = nil
        }
        try context.save()
        if !confirmed.isEmpty { settings.historyRevision = UUID().uuidString }
        return confirmed
    }

    private func saveConfirmedWatches(_ episodes: [RemoteEpisode], showID: Int, confirmed: [Int: Date]) throws {
        let local = try allShows().first { $0.traktID == showID }
        for episode in episodes {
            guard let date = confirmed[episode.ids.trakt],
                  let saved = local?.episodes.first(where: { $0.season == episode.season && $0.number == episode.number }) else { continue }
            saved.watchedAt = date
            saved.isSkipped = false
        }
        try context.save()
        if !confirmed.isEmpty { settings.historyRevision = UUID().uuidString }
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
        do {
            let enabledIDs = Set(try allShows().filter(\.notificationsEnabled).map(\.traktID))
            let programmes = sharedShows.lists.flatMap(\.programmes)
            var refreshedIDs: Set<Int> = []
            for programme in programmes where enabledIDs.contains(programme.id) {
                guard refreshedIDs.insert(programme.id).inserted else { continue }
                let episodes = try await TraktService(auth: auth).episodes(showID: programme.id)
                _ = try prepareSharedReminderShow(programme.show, episodes: episodes)
            }
        } catch { errorMessage = error.localizedDescription }
        await reschedule()
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
        try await syncAndRetainSharedEpisodes([episode], showID: showID, watched: watched, source: source)
    }

    private func syncAndRetainSharedEpisodes(_ episodes: [RemoteEpisode], showID: Int, watched: Bool = true,
                                           source: HouseholdList? = nil,
                                           progress: (Int) -> Void = { _ in }) async throws {
        guard !episodes.isEmpty, settings.sharedShowsUpdateTraktHistory, !settings.demoMode,
              let accountID = settings.traktAccountID else {
            progress(episodes.count)
            return
        }
        // Journal the entire acknowledged batch before any CloudKit work, so a
        // failure on the first episode cannot lose the remaining shared updates.
        var pending = try pendingSharedProgress(accountID: accountID)
        for episode in episodes {
            let change = PendingSharedProgress(episode: episode, showID: showID, watched: watched)
            pending[change.key] = change
        }
        try savePendingSharedProgress(pending, accountID: accountID)
        do {
            sharedShows.activate(accountID: accountID)
            while sharedShows.loading { try await Task.sleep(for: .milliseconds(50)) }
            await sharedShows.refresh(reportErrors: false, automatic: true)
            if let message = sharedShows.refreshMessage { throw APIError.message(message) }
            var lists = sharedShows.lists.filter { $0.programmes.contains { $0.id == showID } }
            if let source, !lists.contains(where: { $0.id == source.id }) { lists.append(source) }
            for (index, list) in lists.enumerated() {
                guard let programme = list.programmes.first(where: { $0.id == showID }) else { continue }
                let changes = episodes.filter { episode in
                    let alreadyWatched = programme.episodes.contains { $0.id == episode.ids.trakt }
                    return alreadyWatched != watched
                        || (watched && programme.skippedEpisodeIDs?.contains(episode.ids.trakt) == true)
                }
                if !changes.isEmpty {
                    try await sharedShows.updateEpisodes(changes, showID: showID, in: list, action: .watched(watched)) { completed in
                        if index == lists.count - 1 { progress(episodes.count - changes.count + completed) }
                    }
                }
            }
            pending = try pendingSharedProgress(accountID: accountID)
            for episode in episodes { pending.removeValue(forKey: "\(showID):\(episode.season):\(episode.number)") }
            try savePendingSharedProgress(pending, accountID: accountID)
            progress(episodes.count)
        } catch {
            throw APIError.message("Your Trakt history is saved. Shared progress is waiting to sync; refresh to retry. \(error.localizedDescription)")
        }
    }

    /// Retry only the iCloud side of acknowledged Trakt writes, including after a relaunch.
    private func retryPendingSharedProgress(history snapshot: [WatchedShow]? = nil) async {
        guard settings.sharedShowsUpdateTraktHistory, !settings.demoMode, connected,
              let accountID = settings.traktAccountID else { return }
        do {
            let pending = try pendingSharedProgress(accountID: accountID)
            guard !pending.isEmpty else { return }
            let history: [WatchedShow]
            if let snapshot { history = snapshot } else { history = try await viewing.watchedShows() }
            var batches: [Int: [Bool: [RemoteEpisode]]] = [:]
            for change in pending.values {
                try Task.checkCancellation()
                guard settings.traktAccountID == accountID else { return }
                // A later action on another device (or while the toggle was off) wins over this retry.
                let watched = history.first { $0.show.id == change.showID }?.seasons
                    .first { $0.number == change.episode.season }?.episodes
                    .contains { $0.number == change.episode.number } == true
                batches[change.showID, default: [:]][watched, default: []].append(change.episode)
            }
            for showID in batches.keys.sorted() {
                for watched in [false, true] {
                    guard let episodes = batches[showID]?[watched] else { continue }
                    try Task.checkCancellation()
                    guard settings.traktAccountID == accountID else { return }
                    try await syncAndRetainSharedEpisodes(episodes, showID: showID, watched: watched)
                }
            }
        } catch {
            errorMessage = "Your Trakt history is saved. Shared progress is waiting to sync; refresh to retry. \(error.localizedDescription)"
        }
    }

    private func updatePersonalProgress(_ episode: Episode, watched: Bool) async throws {
        status = watched ? String(localized: "Marking watched…") : String(localized: "Marking unwatched…")
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

        do {
            let remote = episodes.map(remoteEpisode)
            if settings.demoMode {
                for episode in episodes {
                    episode.watchedAt = episode.watchedAt ?? Date()
                    episode.isSkipped = false
                }
                try context.save()
                seasonUpdateCompleted = episodes.count
            } else {
                let confirmed = try await markTraktEpisodesWatched(remote, showID: show.traktID)
                try saveConfirmedWatches(remote, showID: show.traktID, confirmed: confirmed)
                let accepted = remote.filter { confirmed[$0.ids.trakt] != nil }
                try await syncAndRetainSharedEpisodes(accepted, showID: show.traktID) { completed in
                    seasonUpdateCompleted = completed
                }
                if accepted.count != remote.count {
                    errorMessage = "Trakt could not find \(remote.count - accepted.count) episodes. Confirmed watches were saved; refresh before retrying."
                }
            }
        } catch {
            errorMessage = "\(error.localizedDescription) Refresh before retrying to reconcile any watches already saved by Trakt."
        }
        await reschedule()
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
        busy = false; await refresh(showIDs: [source.id])
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
    func reschedule(prefetchArtwork: Bool = true) async {
        guard !AppStoreScreenshotMode.isEnabled, !PreviewEnvironment.isRunning else { return }
        publishWidgetSnapshot(prefetchArtwork: prefetchArtwork)
        queueCloudChanges()
        if let shows = try? allShows() { await Notifications.rebuild(shows: shows, sharedProgrammes: sharedShows.lists.flatMap(\.programmes), includeSpecials: settings.includeSpecials, demo: settings.demoMode) }
    }
    func prepareSharedReminderShow(_ source: RemoteShow, episodes: [RemoteEpisode]) throws -> Show {
        let existing = try allShows().first { $0.traktID == source.id }
        let show = existing ?? Show(traktID: source.id, tmdbID: source.ids.tmdb, title: source.title, imdbID: source.ids.imdb)
        if existing == nil {
            show.isFollowing = false
            show.notificationsEnabled = cloudDecode(Bool.self, key: "reminders:\(source.id)") ?? false
            show.reminderMinutes = cloudDecode(Int.self, key: "reminderTime:\(source.id)") ?? 540
            context.insert(show)
        }
        merge(episodes, into: show)
        try context.save()
        return show
    }

    func saveSharedReminders(_ show: Show, enabled: Bool, date: Date) throws {
        show.notificationsEnabled = enabled
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        show.reminderMinutes = (components.hour ?? 9) * 60 + (components.minute ?? 0)
        try context.save()
        queueCloudChanges()
    }

    func setNotes(_ show: Show, notes: String) {
        guard show.notes != notes else { return }
        show.notes = notes
        do {
            try context.save()
            queueCloudChanges()
        } catch { errorMessage = error.localizedDescription }
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
            snapshot["notes:\(show.traktID)"] = try encoder.encode(show.notes)
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
            if let notes = cloudDecode(String.self, key: "notes:\(show.traktID)") {
                show.notes = notes
            }
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
                    await Notifications.rebuild(shows: shows, sharedProgrammes: sharedShows.lists.flatMap(\.programmes), includeSpecials: settings.includeSpecials, demo: false)
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

    func publishWidgetSnapshot(errorShowID: Int? = nil, message: String? = nil, prefetchArtwork: Bool = false) {
        publishWidgetSnapshot(library: nil, errorShowID: errorShowID, message: message, prefetchArtwork: prefetchArtwork)
    }

    private func publishWidgetSnapshot(library: WidgetLibrary?, errorShowID: Int? = nil, message: String? = nil, prefetchArtwork: Bool = false) {
        guard !AppStoreScreenshotMode.isEnabled, !PreviewEnvironment.isRunning else { return }
        widgetPublicationRevision += 1
        do {
            var library = try library ?? widgetLibrary()
            let names = sharedShows.widgetListNames
            library.shows = library.shows.map { show in
                var show = show
                show.sharedListNames = names[show.id]
                return show
            }
            library.errorShowID = errorShowID
            library.errorMessage = message
            if try WidgetSnapshotStore.write(library) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
            }
            if prefetchArtwork, widgetArtworkTask == nil, catalogue.configured, !settings.demoMode {
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
        var requests = 0
        for show in shows where show.isFollowing && (showID == nil || show.traktID == showID) {
            guard let tmdbID = show.tmdbID else { continue }
            let candidates = Array(waiting(show).prefix(2)) + Array(upcoming(show).prefix(1))
            for episode in candidates {
                guard !Task.isCancelled, scope == widgetAccountScope else { return }
                if let cached = WidgetArtworkStore.read(for: episode.key),
                   !cached.paths.isEmpty || Date().timeIntervalSince(cached.fetchedAt) < 86_400 { continue }
                guard requests < 5 else { break }
                requests += 1
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
