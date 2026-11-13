import SwiftUI

struct SharedProgrammeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let listID: String
    let showID: Int
    @State private var episodes: [RemoteEpisode] = []
    @State private var localShow: Show?
    @State private var posterPath: String?
    @State private var resolvedIMDbURL: URL?
    @State private var seasonPosters: [Int: String] = [:]
    @State private var loading = false
    @State private var working = false
    @State private var presentedSheet: ProgrammeSheet?
    @State private var showingHistoryInfo = false
    @State private var message: String?
    @State private var offered = false
    @State private var completedSeasonsExpanded = false
    @State private var completed = 0
    @State private var total = 0

    private enum ProgrammeSheet: Identifiable {
        case notes(SharedProgramme, HouseholdList)
        case history(SharedProgramme)

        var id: String {
            switch self {
            case .notes: "notes"
            case .history: "history"
            }
        }
    }

    private var list: HouseholdList? { store.sharedShows.lists.first { $0.id == listID } }
    private var programme: SharedProgramme? { list?.programmes.first { $0.id == showID } }

    var body: some View {
        let progress = programme.map {
            SharedProgrammeProgress(episodes: episodes, programme: $0, includeSpecials: store.settings.includeSpecials)
        }
        ThemedList {
            if let programme, let progress {
                SharedProgrammeSummary(title: programme.show.title, posterPath: posterPath, progress: progress, imdbURL: programme.show.ids.imdbURL ?? resolvedIMDbURL)
                if let localShow {
                    Section {
                        SharedShowReminderControls(show: localShow)
                    }
                }
                if let list {
                    SharedProgrammeNotesSection(notes: programme.notes) {
                        presentedSheet = .notes(programme, list)
                    }
                }
                if loading { ProgressView("Loading episodes…").centeredProgressMessage() }
                if let message { Text(message).foregroundStyle(Color.readableSecondary) }
                if !loading && episodes.isEmpty {
                    Text("Episode details haven't loaded. Pull to refresh to try again.")
                        .foregroundStyle(Color.readableSecondary)
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
                    if !store.settings.demoMode {
                        Button("Sync my Trakt history", systemImage: "arrow.triangle.2.circlepath") {
                            if let programme { presentedSheet = .history(programme) }
                        }
                    }
                    Button("About shared progress", systemImage: "info.circle") { showingHistoryInfo = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Programme actions")
                .disabled(working || store.busy || programme == nil)
            }
        }
        .alert("Shared viewing history", isPresented: $showingHistoryInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("When Shared shows update Trakt history is on in Settings, marking episodes watched or unwatched also updates your Trakt account and matching shared lists. When off, shared progress stays separate. Skips belong to this list. Sync my Trakt history replaces your personal progress with this list’s progress after you review and confirm the changes.")
        }
        .accessibilityHidden(working)
        .overlay {
            if working {
                SeasonUpdateOverlay(title: "Updating shared progress…", total: total)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut, value: progress?.completed.map(\.id))
        .task {
            await loadEpisodes()
            if !offered, presentedSheet == nil, let offer = store.sharedShows.historyOffers.first(where: { $0.listID == listID && $0.programme.id == showID }) {
                offered = true
                presentedSheet = .history(offer.programme)
                store.sharedShows.review(offer)
            }
        }
        .task(id: programme?.show.id) {
            await resolveIMDbURL()
        }
        .refreshable {
            guard !working else { return }
            await store.refreshSharedShows()
            await loadEpisodes(forceRefresh: true)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .notes(let programme, let list):
                SharedProgrammeNotesEditor(programme: programme, list: list)
            case .history(let programme):
                NavigationStack { SharedHistoryImportView(programme: programme) }
            }
        }
    }

    private func seasonSection(_ season: SharedSeasonProgress, programme: SharedProgramme) -> some View {
        SharedSeasonSection(season: season, listID: listID, showID: showID,
                            tmdbID: programme.show.ids.tmdb, posterPath: seasonPosters[season.id] ?? posterPath,
                            update: update)
    }

    private func resolveIMDbURL() async {
        resolvedIMDbURL = nil
        guard let programme, programme.show.ids.imdbURL == nil else { return }
        // Older shared payloads may predate IMDb IDs. Prefer an offline local match.
        if let show = try? store.show(id: showID),
           let url = show.imdbURL {
            resolvedIMDbURL = url
            return
        }
        guard !PreviewEnvironment.isRunning, !store.settings.demoMode else { return }
        if let show = try? await TraktService(auth: store.auth).show(showID: showID),
           !Task.isCancelled, show.id == showID {
            resolvedIMDbURL = show.ids.imdbURL
        }
    }

    private func loadEpisodes(forceRefresh: Bool = false) async {
        guard let programme else { return }
        if PreviewEnvironment.isRunning || store.settings.demoMode {
            if let show = try? store.show(id: showID) {
                localShow = show
                posterPath = show.posterPath
                episodes = show.episodes.map {
                    RemoteEpisode(season: $0.season, number: $0.number, title: $0.title,
                                  ids: IDs(trakt: $0.traktID, tmdb: nil), overview: $0.overview,
                                  firstAired: $0.firstAired?.ISO8601Format(), runtime: $0.runtime)
                }
            }
            return
        }
        localShow = try? store.show(id: showID)
        let cached = await EpisodeCatalogueCache.read(showID)
        guard !Task.isCancelled else { return }
        if let cached { episodes = cached.episodes }
        loading = episodes.isEmpty
        message = nil
        defer { loading = false }
        do {
            // Prepare reminder settings even if episode loading fails.
            if localShow == nil {
                localShow = try store.prepareSharedReminderShow(programme.show, episodes: [])
            }
            let service = TraktService(auth: store.auth)
            let found: [RemoteEpisode]
            if forceRefresh {
                found = try await service.refreshEpisodes(showID: showID)
            } else if let cached, !RefreshPolicy.isStale(cached.updatedAt, interval: 21_600, now: Date()) {
                found = cached.episodes
            } else {
                found = try await service.episodes(showID: showID)
            }
            try Task.checkCancellation()
            episodes = found
            localShow = try store.prepareSharedReminderShow(programme.show, episodes: found)
            await store.reschedule()
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
                try await store.updateSharedEpisodes(episodes, showID: showID, in: list, action: action) {
                    completed = $0
                }
            } catch {
                message = "Updated \(completed) of \(total) episodes. \(error.localizedDescription) Completed changes are kept; try again to finish."
            }
        }
    }
}

private struct SharedShowReminderControls: View {
    @Environment(AppStore.self) private var store
    let show: Show

    var body: some View {
        Toggle("Remind me on scheduled air dates", isOn: Binding(
            get: { show.notificationsEnabled },
            set: { enabled in Task { await store.enableNotifications(show, enabled: enabled) } }
        ))
        .disabled(store.busy || store.settings.demoMode)
        if show.notificationsEnabled {
            DatePicker("Reminder time", selection: Binding(
                get: {
                    Calendar.current.date(bySettingHour: show.reminderMinutes / 60,
                                          minute: show.reminderMinutes % 60, second: 0, of: Date()) ?? Date()
                },
                set: { store.setReminderTime(show, date: $0) }
            ), displayedComponents: .hourAndMinute)
            .disabled(store.busy || store.settings.demoMode)
            Text("Remind me at this local time on each scheduled air date (note that shared show reminders are personal to you).")
                .font(.caption).foregroundStyle(Color.readableSecondary)
        }
    }
}

private struct SharedProgrammeSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let posterPath: String?
    let progress: SharedProgrammeProgress
    var imdbURL: URL? = nil
    @State private var showingTimeInfo = false

    var body: some View {
        Section {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                PosterImageView(posterPath: posterPath, width: 96)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("\(progress.watchedCount) episodes watched together").foregroundStyle(.tint)
                    Label("Watched: \(duration(progress.watchedMinutes, unknown: progress.unknownWatchedRuntimes))",
                          systemImage: "clock")
                    Label("Left to watch: \(duration(progress.remainingMinutes, unknown: progress.unknownRemainingRuntimes))",
                          systemImage: "hourglass")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showingTimeInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("About viewing time totals")
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if let imdbURL {
                Link(destination: imdbURL) {
                    Label("View show on IMDb", systemImage: "arrow.up.right.square")
                }
            }
        }
        .alert("Viewing time totals", isPresented: $showingTimeInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            if progress.unknownWatchedRuntimes + progress.unknownRemainingRuntimes > 0 {
                Text("Time left covers aired episodes, excluding skipped episodes. Totals follow your Specials setting. Some episode runtimes are unavailable; time totals include known runtimes only.")
            } else {
                Text("Time left covers aired episodes, excluding skipped episodes. Totals follow your Specials setting.")
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

private struct SharedProgrammeNotesSection: View {
    let notes: String?
    let edit: () -> Void

    var body: some View {
        Section {
            if let notes, !notes.isEmpty {
                Text(notes).textSelection(.enabled)
            }
            Button(notes?.isEmpty == false ? "Edit notes" : "Add notes", action: edit)
        } header: {
            Text("Shared notes")
        } footer: {
            Text("Visible to everyone in this shared list.")
        }
    }
}

private struct SharedProgrammeNotesEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let programme: SharedProgramme
    let list: HouseholdList
    @State private var draft = ""
    @State private var original: SharedProgramme?
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Add notes about this show", text: $draft, axis: .vertical)
                        .lineLimit(3...12)
                        .accessibilityLabel("Shared notes")
                } footer: {
                    Text("Visible to everyone in this shared list.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .disabled(saving)
            .navigationTitle("Shared notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || original == nil)
                }
            }
            .interactiveDismissDisabled(saving || draft != (original?.notes ?? ""))
            .onAppear {
                guard original == nil else { return }
                original = programme
                draft = programme.notes ?? ""
            }
        }
    }

    private func save() async {
        guard let original, !saving else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try await store.sharedShows.setNotes(draft, for: original, in: list)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SharedSeasonSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                Button { toggle() } label: {
                    HStack(spacing: 12) {
                        FallbackArtworkView(paths: [posterPath].compactMap { $0 }, width: 44, height: 66)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(season.id == 0 ? "Specials" : "Season \(season.id)").font(.headline)
                            Text("\(season.watchedCount) of \(season.episodes.count) watched")
                                .font(.caption).foregroundStyle(Color.readableSecondary)
                            if season.skippedCount > 0 {
                                Text("\(season.skippedCount) skipped").font(.caption).foregroundStyle(Color.readableSecondary)
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
                    .buttonStyle(WatchActionButtonStyle(isSecondary: true))
                    .disabled(season.episodes.allSatisfy { $0.watchedAt != nil || $0.skipped })
                }
                .buttonStyle(WatchActionButtonStyle())
                .font(.caption)
                Button { toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(Color.readableSecondary)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse season" : "Expand season")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: SharedEpisodeProgress
    let listID: String
    let showID: Int
    let tmdbID: Int?
    let posterPath: String?
    let update: ([RemoteEpisode], SharedEpisodeAction) -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
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
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.padding(.vertical, 4)
    }
}

private struct SharedEpisodeButtons: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: SharedEpisodeProgress
    let update: ([RemoteEpisode], SharedEpisodeAction) -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            Button(row.watchedAt == nil ? "Mark watched" : "Unwatch") {
                update([row.episode], .watched(row.watchedAt == nil))
            }
            .disabled(row.watchedAt == nil && row.isFuture)
            Button(row.skipped ? "Unskip" : "Skip") {
                update([row.episode], .skipped(!row.skipped))
            }
            .buttonStyle(WatchActionButtonStyle(isSecondary: true))
            .disabled(row.watchedAt != nil)
        }
        .buttonStyle(WatchActionButtonStyle())
        .font(.caption)
    }
}

private struct SharedEpisodeStatus: View {
    let row: SharedEpisodeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = Dates.parse(row.episode.firstAired) {
                if !AirDates.hasAired(date) { Text("Airs: \(Text(date, style: .date))") }
                else { Text("Aired: \(Text(date, style: .date))") }
                if row.isFuture { Text("Scheduled").foregroundStyle(.primary) }
            } else { Text("Air date unknown") }
            if let date = row.watchedAt {
                if date == .distantPast { Text("Watched together · date unknown") }
                else { Text("Watched together on \(date, format: .dateTime.day().month(.abbreviated).year())") }
            }
            if row.skipped { Text("Skipped in this shared list") }
            if let runtime = row.episode.runtime, runtime > 0 { Text("\(runtime) min") }
        }
        .font(.caption).foregroundStyle(Color.readableSecondary)
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

struct SharedEpisodeDetails: View {
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
        EpisodeDetailsScreen(
            details: EpisodeDetails(episode: episode, showTitle: programme?.show.title,
                                    showIMDbURL: programme?.show.ids.imdbURL),
            navigationTitle: "S\(episode.season) E\(episode.number)"
        ) {
            SharedEpisodeArtwork(tmdbID: tmdbID, episode: episode, posterPath: posterPath, width: 120)
        } streaming: {
            EmptyView()
        } watching: {
            EpisodeWatchSection(
                watchedAt: row.watchedAt, isSkipped: row.skipped,
                isFuture: row.isFuture, isShared: true,
                isDisabled: store.busy || programme == nil, isUpdating: store.busy,
                toggleWatched: { update([episode], .watched(row.watchedAt == nil)) },
                toggleSkipped: { update([episode], .skipped(!row.skipped)) }
            )
        }
    }
}

#if DEBUG

#Preview("Shared programme") {
    PreviewHost { data in
        NavigationStack { SharedProgrammeView(listID: data.list.id, showID: data.show.traktID) }
    }
}

#Preview("Shared summary") {
    PreviewHost { data in
        List { SharedProgrammeSummary(title: data.show.title, posterPath: data.show.posterPath, progress: data.sharedProgress, imdbURL: URL(string: "https://www.imdb.com/title/tt11280740/")) }
    }
}

#Preview("Shared season") {
    PreviewHost { data in
        List { SharedSeasonSection(season: data.sharedSeason, listID: data.list.id, showID: data.show.traktID, tmdbID: nil, posterPath: data.show.posterPath, update: { _, _ in }) }
    }
}

#Preview("Shared episode row") {
    PreviewHost { data in
        List { SharedSeasonEpisodeRow(row: data.sharedRow, listID: data.list.id, showID: data.show.traktID, tmdbID: nil, posterPath: data.show.posterPath, update: { _, _ in }) }
    }
}

#Preview("Shared episode buttons") {
    PreviewHost { data in
        SharedEpisodeButtons(row: data.sharedRow, update: { _, _ in }).padding()
    }
}

#Preview("Shared episode status") {
    PreviewHost { data in
        SharedEpisodeStatus(row: data.sharedRow).padding()
    }
}

#Preview("Shared artwork") {
    PreviewHost { data in
        SharedEpisodeArtwork(tmdbID: nil, episode: data.remoteEpisode, posterPath: data.show.posterPath, width: 160)
    }
}

#Preview("Shared episode details") {
    PreviewHost { data in
        NavigationStack { SharedEpisodeDetails(listID: data.list.id, showID: data.show.traktID, episode: data.remoteEpisode, tmdbID: nil, posterPath: data.show.posterPath, update: { _, _ in }) }
    }
}
#endif
