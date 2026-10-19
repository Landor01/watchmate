import Foundation
import Observation

struct SharedHistoryChange: Identifiable {
    let episode: SharedEpisode
    let watched: Bool
    var id: Int { episode.id }
}

struct SharedHistoryPreview {
    let programme: SharedProgramme
    let accountID: String
    let changes: [SharedHistoryChange]
    let existingCount: Int
    var watchCount: Int { changes.filter(\.watched).count }
    var unwatchCount: Int { changes.count - watchCount }
}

@MainActor @Observable
final class SharedHistoryImport {
    private(set) var running = false
    private(set) var preparing = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var status = ""
    private(set) var currentEpisode = ""
    var preview: SharedHistoryPreview?
    private var task: Task<Void, Never>?

    func prepare(programme: SharedProgramme, store: AppStore) async {
        guard !running, !preparing, !store.busy, store.connected, !store.settings.demoMode else { return }
        preparing = true
        store.busy = true
        preview = nil
        status = "Checking your Trakt history…"
        defer { preparing = false; store.busy = false }
        do {
            let service = TraktService(auth: store.auth)
            let account = try await service.accountID()
            let history = try await service.watchedShows().first { $0.show.id == programme.id }
            let catalogue = try await service.episodes(showID: programme.id)
            let watched = Set(history?.seasons.flatMap { season in
                season.episodes.map { "\(season.number):\($0.number)" }
            } ?? [])
            let changes = try SharedHistoryPlan.changes(shared: programme.episodes, watched: watched, catalogue: catalogue)
            preview = SharedHistoryPreview(programme: programme, accountID: account, changes: changes, existingCount: watched.count)
            status = changes.isEmpty ? "Your progress already matches." : ""
        } catch { status = error.localizedDescription }
    }

    func start(store: AppStore) {
        guard let preview, !running, !store.busy, store.connected,
              store.settings.traktAccountID == preview.accountID else { return }
        running = true
        completed = 0
        total = preview.changes.count
        status = "Updating your Trakt history…"
        store.busy = true
        self.preview = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                running = false
                store.busy = false
                task = nil
            }
            do {
                let service = TraktService(auth: store.auth)
                guard try await service.accountID() == preview.accountID else {
                    throw APIError.message("Your Trakt account changed. Sync stopped.")
                }
                for change in preview.changes {
                    try Task.checkCancellation()
                    guard store.connected, store.settings.traktAccountID == preview.accountID else {
                        throw APIError.message("Your Trakt account changed. Sync stopped.")
                    }
                    currentEpisode = "Season \(change.episode.season), episode \(change.episode.number) · " +
                        (change.watched ? "marking watched" : "marking unwatched")
                    if change.watched { try await service.recordSharedWatch(change.episode) }
                    else { try await service.setWatched(episodeID: change.id, watched: false) }
                    completed += 1
                }
                try Task.checkCancellation()
                status = "Finished. Your progress now matches the shared progress."
            } catch is CancellationError {
                status = "Stopped after \(completed) of \(total) episodes. Changes already made are kept. Review and sync again to finish."
            } catch {
                status = "Stopped after \(completed) of \(total) episodes. \(error.localizedDescription) Changes already made are kept. Review and sync again to finish."
            }
            currentEpisode = ""
            store.settings.lastSync = nil
            store.busy = false
            await store.refresh()
        }
    }

    func cancel() { task?.cancel() }
}
