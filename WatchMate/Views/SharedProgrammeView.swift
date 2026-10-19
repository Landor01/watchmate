import SwiftUI

struct SharedProgrammeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let listID: String
    let showID: Int
    @State private var episodes: [RemoteEpisode] = []
    @State private var posterPath: String?
    @State private var seasonPosters: [Int: String] = [:]
    @State private var loading = false
    @State private var working = false
    @State private var importing = false
    @State private var showingHistoryInfo = false
    @State private var message: String?
    @State private var offered = false
    @State private var completedSeasonsExpanded = false
    @State private var completed = 0
    @State private var total = 0

    private var list: HouseholdList? { store.sharedShows.lists.first { $0.id == listID } }
    private var programme: SharedProgramme? { list?.programmes.first { $0.id == showID } }

    var body: some View {
        let progress = programme.map {
            SharedProgrammeProgress(episodes: episodes, programme: $0, includeSpecials: store.settings.includeSpecials)
        }
        ThemedList {
            if let programme, let progress {
                SharedProgrammeSummary(title: programme.show.title, posterPath: posterPath, progress: progress)
                if loading { ProgressView("Loading episodes…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                if !loading && episodes.isEmpty {
                    Text("Episode details haven't loaded. Pull to refresh to try again.")
                        .foregroundStyle(.secondary)
                }
                ForEach(progress.ready + progress.upcoming) { season in
                    seasonSection(season, programme: programme)
                }
                if !progress.completed.isEmpty {
                    Section {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut) { completedSeasonsExpanded.toggle() }
                        } label: {
                            HStack {
                                Text("Completed seasons (\(progress.completed.count))")
                                Spacer()
                                Image(systemName: completedSeasonsExpanded ? "chevron.down" : "chevron.right")
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(completedSeasonsExpanded ? "Expanded" : "Collapsed")
                        .accessibilityHint("Show or hide watched and skipped seasons")
                    }
                    if completedSeasonsExpanded {
                        ForEach(progress.completed) { season in
                            seasonSection(season, programme: programme)
                        }
                    }
                }
            } else {
                Text("This programme is no longer shared.")
            }
        }
        .disabled(working || store.busy)
        .navigationTitle(programme?.show.title ?? "Programme")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(working)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Sync my Trakt history", systemImage: "arrow.triangle.2.circlepath") { importing = true }
                    Button("About shared progress", systemImage: "info.circle") { showingHistoryInfo = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Programme actions")
                .disabled(working || store.busy || programme == nil)
            }
        }
        .alert("Shared viewing history", isPresented: $showingHistoryInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Shared progress and skips belong to this list. They do not change your personal Trakt history. Syncing replaces your progress for this programme, including marking episodes unwatched if you are ahead. You will review the changes before confirming.")
        }
        .safeAreaInset(edge: .bottom) {
            if working {
                VStack(spacing: 8) {
                    ProgressView(value: Double(completed), total: Double(max(1, total)))
                    Text("\(completed) of \(total) episodes updated").font(.subheadline)
                }
                .padding()
                .background(.regularMaterial)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut, value: progress?.completed.map(\.id))
        .task {
            await loadEpisodes()
            if !offered, let offer = store.sharedShows.historyOffers.first(where: { $0.listID == listID && $0.programme.id == showID }) {
                offered = true
                importing = true
                store.sharedShows.review(offer)
            }
        }
        .refreshable {
            guard !working else { return }
            await store.sharedShows.refresh()
            await loadEpisodes()
        }
        .sheet(isPresented: $importing) {
            if let programme { NavigationStack { SharedHistoryImportView(programme: programme) } }
        }
    }

    private func seasonSection(_ season: SharedSeasonProgress, programme: SharedProgramme) -> some View {
        SharedSeasonSection(season: season, listID: listID, showID: showID,
                            tmdbID: programme.show.ids.tmdb, posterPath: seasonPosters[season.id] ?? posterPath,
                            update: update)
    }

    private func loadEpisodes() async {
        guard let programme else { return }
        loading = true
        message = nil
        defer { loading = false }
        do {
            let found = try await TraktService(auth: store.auth).episodes(showID: showID)
            try Task.checkCancellation()
            episodes = found
        } catch is CancellationError { return }
        catch { message = error.localizedDescription }
        guard let tmdbID = programme.show.ids.tmdb, store.catalogue.configured else { return }
        if let path = try? await store.catalogue.posterPath(tmdbID: tmdbID), !Task.isCancelled { posterPath = path }
        if let posters = try? await store.catalogue.seasonPosters(tmdbID: tmdbID), !Task.isCancelled { seasonPosters = posters }
    }

    private func update(_ episodes: [RemoteEpisode], _ action: SharedEpisodeAction) {
        guard let list, !working, !store.busy, !episodes.isEmpty else { return }
        working = true
        store.busy = true
        completed = 0
        total = episodes.count
        message = nil
        Task {
            defer { working = false; store.busy = false }
            do {
                try await store.sharedShows.updateEpisodes(episodes, showID: showID, in: list, action: action) {
                    completed = $0
                }
            } catch {
                message = "Updated \(completed) of \(total) episodes. \(error.localizedDescription) Completed changes are kept; try again to finish."
            }
        }
    }
}

private struct SharedProgrammeSummary: View {
    let title: String
    let posterPath: String?
    let progress: SharedProgrammeProgress

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                PosterImageView(posterPath: posterPath, width: 96)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title2.bold())
                    Text("\(progress.watchedCount) episodes watched together").foregroundStyle(.tint)
                    Label("Watched: \(duration(progress.watchedMinutes, unknown: progress.unknownWatchedRuntimes))",
                          systemImage: "clock")
                    Label("Left to watch: \(duration(progress.remainingMinutes, unknown: progress.unknownRemainingRuntimes))",
                          systemImage: "hourglass")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Time left covers aired episodes, excluding skipped episodes. Totals follow your Specials setting.")
                .font(.caption).foregroundStyle(.secondary)
            if progress.unknownWatchedRuntimes + progress.unknownRemainingRuntimes > 0 {
                Text("Some episode runtimes are unavailable; time totals include known runtimes only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func duration(_ minutes: Int, unknown: Int) -> String {
        guard minutes > 0 else { return unknown > 0 ? String(localized: "Unknown") : String(localized: "0 min") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }
}

private struct SharedSeasonSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let season: SharedSeasonProgress
    let listID: String
    let showID: Int
    let tmdbID: Int?
    let posterPath: String?
    let update: ([RemoteEpisode], SharedEpisodeAction) -> Void
    @State private var expanded = false

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Button { toggle() } label: {
                    HStack(spacing: 12) {
                        FallbackArtworkView(paths: [posterPath].compactMap { $0 }, width: 44, height: 66)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(season.id == 0 ? "Specials" : "Season \(season.id)").font(.headline)
                            Text("\(season.watchedCount) of \(season.episodes.count) watched")
                                .font(.caption).foregroundStyle(.secondary)
                            if season.skippedCount > 0 {
                                Text("\(season.skippedCount) skipped").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide season episodes")
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Mark watched") {
                        update(season.episodes.filter { !$0.isFuture && ($0.watchedAt == nil || $0.skipped) }.map(\.episode), .watched(true))
                    }
                    .disabled(season.episodes.allSatisfy { $0.isFuture || ($0.watchedAt != nil && !$0.skipped) })
                    Button("Skip") {
                        update(season.episodes.filter { $0.watchedAt == nil && !$0.skipped }.map(\.episode), .skipped(true))
                    }
                    .disabled(season.episodes.allSatisfy { $0.watchedAt != nil || $0.skipped })
                }
                .buttonStyle(.bordered)
                .font(.caption)
                Button { toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(minWidth: 24, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse season" : "Expand season")
            }
            .padding(.vertical, 4)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if expanded {
                ForEach(season.episodes) { row in
                    SharedSeasonEpisodeRow(row: row, listID: listID, showID: showID, tmdbID: tmdbID,
                                           posterPath: posterPath, update: update)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
            }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut) { expanded.toggle() }
    }
}

private struct SharedSeasonEpisodeRow: View {
    let row: SharedEpisodeProgress
    let listID: String
    let showID: Int
    let tmdbID: Int?
    let posterPath: String?
    let update: ([RemoteEpisode], SharedEpisodeAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SharedEpisodeArtwork(tmdbID: tmdbID, episode: row.episode, posterPath: posterPath, width: 72)
            VStack(alignment: .leading, spacing: 4) {
                NavigationLink {
                    SharedEpisodeDetails(listID: listID, showID: showID, episode: row.episode,
                                         tmdbID: tmdbID, posterPath: posterPath, update: update)
                } label: {
                    Text("S\(row.episode.season) E\(row.episode.number) · \(row.episode.title ?? "Episode")")
                        .font(.subheadline.bold())
                }
                SharedEpisodeStatus(row: row)
                SharedEpisodeButtons(row: row, update: update)
            }
        }.padding(.vertical, 4)
    }
}

private struct SharedEpisodeButtons: View {
    let row: SharedEpisodeProgress
    let update: ([RemoteEpisode], SharedEpisodeAction) -> Void

    var body: some View {
        HStack {
            Button(row.watchedAt == nil ? "Mark watched" : "Unwatch") {
                update([row.episode], .watched(row.watchedAt == nil))
            }
            .disabled(row.watchedAt == nil && row.isFuture)
            Button(row.skipped ? "Unskip" : "Skip") {
                update([row.episode], .skipped(!row.skipped))
            }.disabled(row.watchedAt != nil)
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }
}

private struct SharedEpisodeStatus: View {
    let row: SharedEpisodeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = Dates.parse(row.episode.firstAired) {
                if date >= Calendar.current.startOfDay(for: Date()) { Text("Airs: \(Text(date, style: .date))") }
                else { Text("Aired: \(Text(date, style: .date))") }
                if row.isFuture { Text("Scheduled").foregroundStyle(.orange) }
            } else { Text("Air date unknown") }
            if let date = row.watchedAt {
                if date == .distantPast { Text("Watched together · date unknown") }
                else { Text("Watched together on \(date, format: .dateTime.day().month(.abbreviated).year())") }
            }
            if row.skipped { Text("Skipped in this shared list") }
            if let runtime = row.episode.runtime, runtime > 0 { Text("\(runtime) min") }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

private struct SharedEpisodeArtwork: View {
    @Environment(AppStore.self) private var store
    let tmdbID: Int?
    let episode: RemoteEpisode
    let posterPath: String?
    let width: CGFloat
    @State private var paths: [String] = []

    var body: some View {
        FallbackArtworkView(paths: paths + [posterPath].compactMap { $0 }, width: width, height: width, contentMode: .fill)
            .task(id: "\(tmdbID ?? 0):\(episode.season):\(episode.number)") {
                paths = []
                guard let tmdbID, store.catalogue.configured else { return }
                if let artwork = try? await store.catalogue.episodeArtwork(tmdbID: tmdbID, season: episode.season, episode: episode.number),
                   !Task.isCancelled { paths = artwork }
            }
    }
}

private struct SharedEpisodeDetails: View {
    @Environment(AppStore.self) private var store
    let listID: String
    let showID: Int
    let episode: RemoteEpisode
    let tmdbID: Int?
    let posterPath: String?
    let update: ([RemoteEpisode], SharedEpisodeAction) -> Void

    private var programme: SharedProgramme? {
        store.sharedShows.lists.first { $0.id == listID }?.programmes.first { $0.id == showID }
    }

    var body: some View {
        let row = SharedEpisodeProgress(episode: episode, watchedAt: programme?.episodes.first { $0.id == episode.ids.trakt }?.watchedAt,
                                        skipped: programme?.skippedEpisodeIDs?.contains(episode.ids.trakt) ?? false)
        ThemedList {
            Section {
                SharedEpisodeArtwork(tmdbID: tmdbID, episode: episode, posterPath: posterPath, width: 240)
                    .frame(maxWidth: .infinity)
                Text(episode.title ?? "Episode").font(.title2.bold())
                SharedEpisodeStatus(row: row)
                if let overview = episode.overview, !overview.isEmpty { Text(overview).font(.subheadline) }
                SharedEpisodeButtons(row: row, update: update).disabled(store.busy || programme == nil)
                if store.busy { ProgressView("Updating shared progress…") }
            }
        }
        .navigationTitle("S\(episode.season) E\(episode.number)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
