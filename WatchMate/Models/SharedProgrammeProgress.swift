import Foundation

enum SharedEpisodeAction {
    case watched(Bool)
    case skipped(Bool)
}

struct SharedEpisodeProgress: Identifiable {
    let episode: RemoteEpisode
    let watchedAt: Date?
    let skipped: Bool
    var id: Int { episode.ids.trakt }
    var isFuture: Bool { Dates.parse(episode.firstAired).map { $0 > Date() } ?? false }
}

struct SharedSeasonProgress: Identifiable {
    let id: Int
    let episodes: [SharedEpisodeProgress]
    var watchedCount: Int { episodes.filter { $0.watchedAt != nil }.count }
    var skippedCount: Int { episodes.filter { $0.skipped && $0.watchedAt == nil }.count }
}

struct SharedProgrammeProgress {
    let ready: [SharedSeasonProgress]
    let upcoming: [SharedSeasonProgress]
    let completed: [SharedSeasonProgress]
    let watchedCount: Int
    let watchedMinutes: Int
    let remainingMinutes: Int
    let unknownWatchedRuntimes: Int
    let unknownRemainingRuntimes: Int

    init(episodes: [RemoteEpisode], programme: SharedProgramme, includeSpecials: Bool, now: Date = Date()) {
        let dates = Dictionary(programme.episodes.map { ($0.id, $0.watchedAt) }, uniquingKeysWith: { first, _ in first })
        let skipped = programme.skippedEpisodeIDs ?? []
        let rows = episodes.filter { includeSpecials || $0.season > 0 }.map {
            SharedEpisodeProgress(episode: $0, watchedAt: dates[$0.ids.trakt],
                                  skipped: dates[$0.ids.trakt] == nil && skipped.contains($0.ids.trakt))
        }
        let grouped = Dictionary(grouping: rows, by: { $0.episode.season })
        var ready: [SharedSeasonProgress] = []
        var upcoming: [SharedSeasonProgress] = []
        var completed: [SharedSeasonProgress] = []
        for season in grouped.keys.sorted() {
            let rows = (grouped[season] ?? []).sorted { $0.episode.number < $1.episode.number }
            let section = SharedSeasonProgress(id: season, episodes: rows)
            let remaining = rows.filter { $0.watchedAt == nil && !$0.skipped }
            if remaining.isEmpty { completed.append(section) }
            else if remaining.contains(where: { Dates.parse($0.episode.firstAired).map { $0 <= now } == true }) {
                ready.append(section)
            } else { upcoming.append(section) }
        }
        self.ready = ready
        self.upcoming = upcoming
        self.completed = completed
        let watched = rows.filter { $0.watchedAt != nil }
        let remaining = rows.filter {
            $0.watchedAt == nil && !$0.skipped && Dates.parse($0.episode.firstAired).map { $0 <= now } == true
        }
        watchedCount = watched.count
        watchedMinutes = watched.reduce(0) { $0 + max(0, $1.episode.runtime ?? 0) }
        remainingMinutes = remaining.reduce(0) { $0 + max(0, $1.episode.runtime ?? 0) }
        unknownWatchedRuntimes = watched.filter { ($0.episode.runtime ?? 0) <= 0 }.count
        unknownRemainingRuntimes = remaining.filter { ($0.episode.runtime ?? 0) <= 0 }.count
    }
}
