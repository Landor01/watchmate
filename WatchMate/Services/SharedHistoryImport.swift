import Foundation
import Observation

struct SharedHistoryChange: Identifiable {
    let episode: SharedEpisode
    let watched: Bool
    var showTitle: String? = nil
    var episodeTitle: String? = nil
    var id: Int { episode.id }
}

struct SharedHistoryPreview {
    let programmes: [SharedProgramme]
    let batches: [[SharedHistoryChange]]
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
    private(set) var currentShowTitle = ""
    private(set) var currentEpisode = ""
    var preview: SharedHistoryPreview?
    private var task: Task<Void, Never>?

    func prepare(programme: SharedProgramme, store: AppStore) async {
        await prepare(programmes: [programme], store: store)
    }

    func prepare(programmes: [SharedProgramme], store: AppStore) async {
        guard !running, !preparing, !store.busy, store.connected, !store.settings.demoMode else { return }
        preparing = true
        store.busy = true
        preview = nil
        status = "Checking your Trakt history…"
        defer { preparing = false; store.busy = false }
        do {
            let service = TraktService(auth: store.auth)
            let account = try await service.accountID()
            let history = try await service.watchedShows()
            var changes: [SharedHistoryChange] = []
            var batches: [[SharedHistoryChange]] = []
            var existingCount = 0
            var seen: [Int: Set<Int>] = [:]
            for programme in programmes {
                let sharedIDs = Set(programme.episodes.map(\.id))
                if let previous = seen[programme.id] {
                    guard previous == sharedIDs else {
                        throw APIError.message("This selection contains different shared progress for \(programme.show.title). Sync that programme from the list you want to use.")
                    }
                    continue
                }
                seen[programme.id] = sharedIDs
                try Task.checkCancellation()
                let catalogue = try await service.episodes(showID: programme.id)
                let watched = Set(history.first { $0.show.id == programme.id }?.seasons.flatMap { season in
                    season.episodes.map { "\(season.number):\($0.number)" }
                } ?? [])
                let episodeTitles = Dictionary(catalogue.map { ($0.ids.trakt, $0.title) },
                                               uniquingKeysWith: { first, _ in first })
                let planned = try SharedHistoryPlan.changes(shared: programme.episodes, watched: watched, catalogue: catalogue).map { change in
                    var change = change
                    change.showTitle = programme.show.title
                    change.episodeTitle = episodeTitles[change.id] ?? nil
                    return change
                }
                changes += planned
                batches += SharedHistoryBatchPlan.batches(planned)
                existingCount += watched.count
            }
            try Task.checkCancellation()
            guard store.connected, store.settings.traktAccountID == account else {
                throw APIError.message("Your Trakt account changed. Review again.")
            }
            preview = SharedHistoryPreview(programmes: programmes, batches: batches, accountID: account,
                                           changes: changes, existingCount: existingCount)
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
                for batch in preview.batches {
                    try Task.checkCancellation()
                    guard store.connected, store.settings.traktAccountID == preview.accountID else {
                        throw APIError.message("Your Trakt account changed. Sync stopped.")
                    }
                    guard let change = batch.first else { continue }
                    currentShowTitle = change.showTitle ?? ""
                    currentEpisode = "Season \(change.episode.season) · \(batch.count) episodes"
                    if change.watched {
                        let confirmed = try await service.recordSharedWatches(batch.map(\.episode))
                        completed += confirmed.count
                        guard confirmed.count == batch.count else {
                            throw APIError.message("Trakt could not find some episodes.")
                        }
                    } else {
                        let confirmed = try await service.markUnwatched(episodeIDs: batch.map(\.id))
                        completed += confirmed.count
                        guard confirmed.count == batch.count else {
                            throw APIError.message("Trakt could not find some episodes.")
                        }
                    }
                }
                try Task.checkCancellation()
                status = "Finished. Your progress now matches the shared progress."
            } catch is CancellationError {
                status = "Stopped after \(completed) of \(total) episodes. Changes already made are kept. Review and sync again to finish."
            } catch {
                status = "Stopped after \(completed) of \(total) episodes. \(error.localizedDescription) Changes already made are kept. Review and sync again to finish."
            }
            currentShowTitle = ""
            currentEpisode = ""
            store.busy = false
            await store.refresh(showIDs: Set(preview.programmes.map(\.id)))
        }
    }

    func cancel() { task?.cancel() }
}

enum SharedHistoryBatchPlan {
    static func batches(_ changes: [SharedHistoryChange]) -> [[SharedHistoryChange]] {
        let seasons = Dictionary(grouping: changes, by: { $0.episode.season })
        return seasons.keys.sorted().flatMap { season -> [[SharedHistoryChange]] in
            let changes = seasons[season] ?? []
            let removals = changes.filter { !$0.watched }
            let watches = changes.filter(\.watched)
            return (removals.isEmpty ? [] : [removals]) + (watches.isEmpty ? [] : [watches])
        }
    }
}
