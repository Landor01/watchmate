import CloudKit
import SwiftUI
import SwiftData

struct SharedShowsView: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var creating = false
    @State private var working = false

    var body: some View {
        ThemedList {
            if (!store.connected || store.settings.demoMode) && !PreviewEnvironment.isRunning {
                ContentUnavailableView("Connect Trakt first", systemImage: "person.crop.circle",
                                       description: Text("Connect your own Trakt account in Settings. Shared Shows also requires iCloud."))
            } else {
                if store.sharedShows.loading && store.sharedShows.lists.isEmpty { ProgressView("Loading shared lists…") }
                if let message = store.sharedShows.refreshMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if store.sharedShows.lists.isEmpty && !store.sharedShows.loading {
                    ContentUnavailableView("Watch together", systemImage: "person.2",
                                           description: Text("Create a list, then invite someone to share it."))
                }
                if store.sharedShows.lists.contains(where: { !$0.programmes.isEmpty }) {
                    NavigationLink("Sync Progress to Trakt") {
                        SharedHistoryImportView(programmes: store.sharedShows.lists.flatMap(\.programmes))
                    }
                    .disabled(store.busy)
                }
                if !store.sharedShows.historyOffers.isEmpty {
                    NavigationLink("New shared programmes: review viewing history") { SharedHistoryInboxView() }
                }
                ForEach(store.sharedShows.lists) { list in
                    NavigationLink {
                        HouseholdListView(listID: list.id)
                    } label: {
                        HStack(spacing: 12) {
                            SharedListAvatarView(name: list.name, photoData: list.photoData, size: 44)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(list.name).font(.headline)
                                Text("\(list.programmes.count) programmes").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Create Shared Shows list", systemImage: "plus") { creating = true }
                    .disabled(working)
            }
        }
        .navigationTitle("Shared Shows")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.connected && !store.settings.demoMode { await store.sharedShows.refresh(automatic: true) } }
        .refreshable { await store.refreshSharedShows() }
        .alert("New shared list", isPresented: $creating) {
            TextField("List name", text: $name)
            Button("Create") {
                working = true
                Task {
                    defer { working = false }
                    do { try await store.sharedShows.create(name: name); name = "" }
                    catch { store.sharedShows.errorMessage = error.localizedDescription }
                }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Invite people after creating your list. Everyone keeps their own Trakt account.")
        }
    }
}

private struct HouseholdListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.themeAccent) private var themeAccent
    let listID: String
    @State private var adding = false
    @State private var share: CKShare?
    @State private var sharing = false
    @State private var working = false
    @State private var removing: SharedProgramme?
    @State private var moving: SharedProgramme?
    @Query(Show.withEpisodes) private var shows: [Show]
    @State private var catalogues: [Int: [RemoteEpisode]] = [:]

    private var list: HouseholdList? { store.sharedShows.lists.first { $0.id == listID } }

    var body: some View {
        ThemedList {
            if let list {
                SharedListPhotoSection(list: list)
                if !list.programmes.isEmpty {
                    NavigationLink("Sync Progress to Trakt") {
                        SharedHistoryImportView(programmes: list.programmes)
                    }
                    .disabled(store.busy)
                }
                if list.programmes.isEmpty {
                    Text("Add programmes from My Shows or search for something new.")
                }
                let completedIDs = completedProgrammeIDs(in: list)
                let active = list.programmes.filter { !completedIDs.contains($0.id) }
                let completed = list.programmes.filter { completedIDs.contains($0.id) }
                programmeRows(active, in: list)
                if !completed.isEmpty {
                    Section("Completed") {
                        programmeRows(completed, in: list)
                    }
                }
            } else {
                ContentUnavailableView("List unavailable", systemImage: "person.2.slash",
                                       description: Text("Pull to refresh. The owner may have stopped sharing this list."))
            }
        }
        .task(id: list?.programmes.map(\.id)) { await loadCatalogues() }
        .navigationTitle(list?.name ?? "Shared Shows")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add programmes", systemImage: "plus") { adding = true }
                    Button("Invite / Manage sharing", systemImage: "person.badge.plus") {
                        guard let list else { return }
                        working = true
                        Task {
                            defer { working = false }
                            do { share = try await store.sharedShows.share(for: list); sharing = true }
                            catch { store.sharedShows.errorMessage = error.localizedDescription }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("List actions")
                .disabled(list == nil || working || store.busy)
            }
        }
        .refreshable {
            await store.refreshSharedShows()
            await loadCatalogues(forceRefresh: true)
        }
        .sheet(isPresented: $adding) {
            if let list { NavigationStack { SharedProgrammePicker(list: list) } }
        }
        .sheet(isPresented: $sharing, onDismiss: { Task { await store.sharedShows.refresh() } }) {
            if let share, let list { HouseholdSharingSheet(share: share, service: store.sharedShows, list: list) }
        }
        .sheet(item: $moving) { programme in
            if let list {
                NavigationStack { MoveSharedProgrammeView(programme: programme, source: list) }
            }
        }
        .confirmationDialog("Remove programme for everyone?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from shared list", role: .destructive) {
                guard let list, let removing else { return }
                Task {
                    do { try await store.sharedShows.remove(removing, from: list) }
                    catch { store.sharedShows.errorMessage = error.localizedDescription }
                    self.removing = nil
                }
            }
        } message: {
            Text("This removes the programme and its shared progress from this list. Everyone’s personal Trakt history is kept.")
        }
    }

    private func programmeRows(_ programmes: [SharedProgramme], in list: HouseholdList) -> some View {
        ForEach(programmes) { programme in
            NavigationLink {
                SharedProgrammeView(listID: listID, showID: programme.id)
            } label: {
                SharedProgrammeRow(list: list, programme: programme)
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .swipeActions(allowsFullSwipe: false) {
                Button("Move", systemImage: "folder") { moving = programme }.tint(themeAccent)
                Button("Remove", role: .destructive) { removing = programme }
            }
            .contextMenu {
                Button("Move to My Shows or another list", systemImage: "folder") { moving = programme }
                Button("Remove from shared list", role: .destructive) { removing = programme }
            }
        }
    }

    private func completedProgrammeIDs(in list: HouseholdList) -> Set<Int> {
        let now = Date()
        return Set(list.programmes.compactMap { programme in
            guard let episodes = episodes(for: programme) else { return nil }
            let watched = Set(programme.episodes.map(\.id))
            let skipped = programme.skippedEpisodeIDs ?? []
            let states = episodes.map {
                EpisodeState(season: $0.season, number: $0.number, firstAired: Dates.parse($0.firstAired),
                             watched: watched.contains($0.ids.trakt), skipped: skipped.contains($0.ids.trakt))
            }
            return EpisodeRules.isCaughtUp(states, now: now, includeSpecials: store.settings.includeSpecials) ? programme.id : nil
        })
    }

    private func episodes(for programme: SharedProgramme) -> [RemoteEpisode]? {
        if let loaded = catalogues[programme.id] { return loaded }
        if let show = shows.first(where: { $0.traktID == programme.id }), show.catalogueUpdatedAt != nil {
            return show.episodes.map {
                RemoteEpisode(season: $0.season, number: $0.number, title: $0.title,
                              ids: IDs(trakt: $0.traktID, tmdb: nil), overview: $0.overview,
                              firstAired: $0.firstAired.map { Dates.string($0) }, runtime: $0.runtime)
            }
        }
        return catalogues[programme.id]
    }

    private func loadCatalogues(forceRefresh: Bool = false) async {
        guard let list else { return }
        for programme in list.programmes {
            if !forceRefresh, let show = shows.first(where: { $0.traktID == programme.id }), show.catalogueUpdatedAt != nil { continue }
            if !forceRefresh, let cached = EpisodeCatalogueCache.read(programme.id) {
                catalogues[programme.id] = cached.episodes
                continue
            }
            do {
                let service = TraktService(auth: store.auth)
                let episodes = forceRefresh ? try await service.refreshEpisodes(showID: programme.id) : try await service.episodes(showID: programme.id)
                try Task.checkCancellation()
                catalogues[programme.id] = episodes
            } catch {
                if Task.isCancelled { return }
                // Keep programmes with unavailable episode details in the main section.
            }
        }
    }
}

private struct SharedProgrammeRow: View {
    @Environment(AppStore.self) private var store
    let list: HouseholdList
    let programme: SharedProgramme
    @State private var posterPath: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PosterImageView(posterPath: posterPath)
            VStack(alignment: .leading, spacing: 4) {
                Text(programme.show.title).font(.headline)
                Text("\(programme.episodes.count) episodes watched together")
                    .font(.caption).foregroundStyle(.secondary)
                SharedListSummaryView(list: list, programme: programme)
                if programme.addedBy != store.settings.traktAccountID {
                    Text("Review or sync viewing history").font(.caption).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .task(id: programme.show.ids.tmdb) {
            if PreviewEnvironment.isRunning {
                posterPath = try? store.allShows().first(where: { $0.traktID == programme.id })?.posterPath
                return
            }
            posterPath = nil
            guard let tmdbID = programme.show.ids.tmdb, store.catalogue.configured else { return }
            if let path = try? await store.catalogue.posterPath(tmdbID: tmdbID), !Task.isCancelled {
                posterPath = path
            }
        }
    }
}

private struct MoveSharedProgrammeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let programme: SharedProgramme
    let source: HouseholdList
    @State private var destination: HouseholdList?
    @State private var confirming = false
    @State private var working = false
    @State private var errorMessage: String?

    private var destinations: [HouseholdList] {
        store.sharedShows.lists.filter { $0.id != source.id }
    }

    var body: some View {
        ThemedList {
            Section(programme.show.title) {
                Button("Return to My Shows", systemImage: "tv") {
                    destination = nil
                    confirming = true
                }
                Text("Keep your personal Trakt history. To use the shared progress instead, sync viewing history from the programme’s menu before moving it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Move to another shared list") {
                ForEach(destinations) { list in
                    let alreadyAdded = list.programmes.contains { $0.id == programme.id }
                    Button {
                        destination = list
                        confirming = true
                    } label: {
                        VStack(alignment: .leading) {
                            Text(list.name)
                            if alreadyAdded {
                                Text("Already contains this programme").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(alreadyAdded)
                }
                if destinations.isEmpty {
                    Text("Create another list in Shared Shows first.")
                        .foregroundStyle(.secondary)
                }
            }
            if working { ProgressView("Moving programme…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
        }
        .disabled(working || store.busy)
        .navigationTitle("Move programme")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(working)
            }
        }
        .interactiveDismissDisabled(working)
        .confirmationDialog("Remove from this list for everyone?", isPresented: $confirming, titleVisibility: .visible) {
            Button(destination == nil ? "Return to My Shows" : "Move to selected list", role: .destructive) {
                Task { await move() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let destination {
                Text("This removes the programme from \(source.name) for everyone and shares its watched and skipped progress with everyone in \(destination.name). Personal Trakt histories are kept.")
            } else {
                Text("This removes the programme and its shared progress from \(source.name) for everyone and adds it to your My Shows. Your personal Trakt history is kept. Copies in other shared lists are unchanged.")
            }
        }
    }

    private func move() async {
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            if let destination {
                try await store.sharedShows.move(programme, from: source, to: destination)
            } else {
                try await store.returnToMyShows(programme, from: source)
                await store.refresh(showIDs: [programme.id])
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SharedProgrammePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Show.title) private var shows: [Show]
    let list: HouseholdList
    var initialShow: RemoteShow? = nil
    @State private var query = ""
    @State private var results: [RemoteShow] = []
    @State private var working = false
    @State private var searching = false
    @State private var message: String?
    @State private var selection: RemoteShow?

    private var existingIDs: Set<Int> {
        Set(store.sharedShows.lists.first(where: { $0.id == list.id })?.programmes.map(\.id) ?? [])
    }

    var body: some View {
        let personal = shows.filter { $0.isFollowing && !existingIDs.contains($0.traktID) }
        ThemedList {
            Section {
                Text("Moving a programme shares its current watched progress across every season. Your Trakt history stays intact. Other people choose whether to overwrite their own progress.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if working { ProgressView("Reading viewing history and sharing programme…") }
            if searching { ProgressView("Searching…") }
            if let message { Text(message).foregroundStyle(.secondary) }
            if query.isEmpty {
                Section("Move from My Shows") {
                    ForEach(personal) { show in
                        Button {
                            selection = RemoteShow(title: show.title, year: nil, ids: IDs(trakt: show.traktID, tmdb: show.tmdbID, imdb: show.imdbID))
                        } label: {
                            HStack(spacing: 12) {
                                SharedPickerThumbnail(tmdbID: show.tmdbID, posterPath: show.posterPath)
                                Text(show.title).font(.headline)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            } else {
                Section("Search results") {
                    ForEach(results) { show in
                        Button {
                            selection = show
                        } label: {
                            HStack(spacing: 12) {
                                SharedPickerThumbnail(tmdbID: show.ids.tmdb)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(show.title).font(.headline)
                                    if let year = show.year {
                                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if existingIDs.contains(show.id) { Image(systemName: "checkmark") }
                            }
                        }.disabled(existingIDs.contains(show.id))
                    }
                }
            }
        }
        .disabled(working || store.busy)
        .navigationTitle("Add shared programmes")
        .searchable(text: $query, prompt: "Search TV programmes")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
        .interactiveDismissDisabled(working)
        .task { if let initialShow, !existingIDs.contains(initialShow.id) { selection = initialShow } }
        .task(id: query) {
            results = []
            guard query.count >= 2 else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                searching = true
                defer { searching = false }
                let found = try await TraktService(auth: store.auth).search(query)
                try Task.checkCancellation()
                results = found
            } catch is CancellationError {} catch { message = error.localizedDescription }
        }
        .confirmationDialog("Share programme and viewing progress?", isPresented: Binding(
            get: { selection != nil }, set: { if !$0 { selection = nil } }
        ), titleVisibility: .visible) {
            Button("Move to Shared Shows") {
                guard let selection else { return }
                Task { await add(selection) }
            }
            Button("Cancel", role: .cancel) { selection = nil }
        } message: {
            Text("The programme will appear in this shared list instead of My Shows. Its current Trakt watched progress will be visible to everyone invited to the list.")
        }
    }

    private func add(_ show: RemoteShow) async {
        working = true
        store.busy = true
        message = nil
        defer { working = false; store.busy = false; selection = nil }
        do {
            let service = TraktService(auth: store.auth)
            let account = try await service.accountID()
            let history = try await service.watchedShows().first { $0.show.id == show.id }
            let catalogue = try await service.episodes(showID: show.id)
            var episodes: [SharedEpisode] = []
            for season in history?.seasons ?? [] {
                for episode in season.episodes {
                    guard let remote = catalogue.first(where: { $0.season == season.number && $0.number == episode.number }) else {
                        throw APIError.message("A watched episode is missing from Trakt’s catalogue. Nothing has been moved. Please try again later.")
                    }
                    episodes.append(SharedEpisode(id: remote.ids.trakt, season: season.number, number: episode.number,
                                                  watchedAt: Dates.parse(episode.lastWatchedAt) ?? .distantPast))
                }
            }
            try await store.sharedShows.add(SharedProgramme(show: show, addedBy: account, episodes: episodes), to: list)
            guard store.settings.traktAccountID == account else { throw CancellationError() }
            store.sharedShows.showInMyShows(show.id, visible: false)
            message = "\(show.title) added."
        } catch { message = error.localizedDescription }
    }
}

struct SharedHistoryImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let programmes: [SharedProgramme]

    init(programme: SharedProgramme) {
        programmes = [programme]
    }

    init(programmes: [SharedProgramme]) {
        self.programmes = programmes
    }

    private var selectionTitle: String {
        programmes.count == 1 ? programmes[0].show.title : "\(programmes.count) shared programmes"
    }
    @State private var confirming = false

    var body: some View {
        let importer = store.sharedHistoryImport
        ThemedList {
            Section {
                SharedHistoryImportHeader(selectionTitle: selectionTitle)
                    .padding(.vertical, 12)
            }
            if importer.preparing {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView("Comparing your progress…").font(.headline)
                        Text("Checking every season and special. Nothing changes until you confirm.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            if let preview = importer.preview {
                Section("Review your changes") {
                    SharedHistoryChangeSummary(preview: preview)
                    if !preview.changes.isEmpty {
                        SharedHistoryOverwriteNotice()
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Allow at least \(max(1, Int(ceil(Double(preview.batches.count) * 1.1 / 60)))) min", systemImage: "clock")
                                .font(.subheadline.weight(.medium))
                            Text("Large libraries can take several minutes. Keep WatchMate open and connected. Network delays and Trakt limits may add time.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(role: .destructive) { confirming = true } label: {
                                Label("Replace progress & sync", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            if importer.running {
                Section("Syncing to Trakt") {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Matching your shared progress", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                        Text("\(importer.completed) of \(importer.total)")
                            .font(.largeTitle.bold()).monospacedDigit()
                        ProgressView("Episodes updated", value: Double(importer.completed), total: Double(max(1, importer.total)))
                        Text(importer.currentEpisode).font(.caption).foregroundStyle(.secondary)
                        Text("Keep WatchMate open and connected to the internet.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Stop syncing", role: .cancel) { importer.cancel() }
                            .buttonStyle(.bordered)
                        Text("Stopping keeps changes already made. Review and sync again to finish.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            if !importer.status.isEmpty && !importer.preparing && !importer.running && importer.preview?.changes.isEmpty != true {
                Section {
                    Label(importer.status, systemImage: "info.circle")
                        .padding(.vertical, 8)
                }
            }
            if !importer.running && !importer.preparing {
                Section {
                    Button {
                        Task { await importer.prepare(programmes: programmes, store: store) }
                    } label: {
                        Label("Review changes again", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationTitle("Sync viewing history")
        .navigationBarBackButtonHidden(importer.running || importer.preparing)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(importer.running ? "Syncing…" : "Done") { importer.preview = nil; dismiss() }
                    .disabled(importer.running || importer.preparing)
            }
        }
        .interactiveDismissDisabled(importer.running || importer.preparing)
        .task { if !PreviewEnvironment.isRunning, !importer.running { await importer.prepare(programmes: programmes, store: store) } }
        .alert("Overwrite your existing progress?", isPresented: $confirming) {
            Button("Overwrite and sync", role: .destructive) { importer.start(store: store) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your existing viewing progress for \(selectionTitle) will be overwritten to match the sharer’s progress. \(importer.preview?.watchCount ?? 0) episodes will be marked watched and \(importer.preview?.unwatchCount ?? 0) will be marked unwatched. This cannot be automatically undone.")
        }
    }
}

private struct SharedHistoryImportHeader: View {
    @Environment(\.themeAccent) private var accent
    let selectionTitle: String

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 20) {
                Image(systemName: "person.2.fill")
                    .padding(18)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                Image(systemName: "arrow.right")
                    .font(.title3.weight(.semibold))
                Image(systemName: "play.rectangle.fill")
                    .padding(18)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
            }
            .font(.largeTitle)
            .foregroundStyle(accent)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Get on the same episode")
                    .font(.title2.bold())
                Text(selectionTitle)
                    .font(.headline).foregroundStyle(accent)
                Text("Match your Trakt viewing history to the shared progress.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Label("Shared progress → Your Trakt", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accent.opacity(0.10), in: Capsule())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SharedHistoryChangeSummary: View {
    let preview: SharedHistoryPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if preview.changes.isEmpty {
                Label("You're already in sync", systemImage: "checkmark.circle.fill")
                    .font(.title3.bold())
                Text("Your viewing progress matches. There's nothing to change.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Here's what will change")
                    .font(.headline)
                SharedHistoryCountRow(count: preview.watchCount, title: "Mark watched", symbol: "checkmark.circle.fill", color: .green)
                SharedHistoryCountRow(count: preview.unwatchCount, title: "Mark unwatched", symbol: "arrow.uturn.backward.circle.fill", color: .orange)
            }
            Label("\(preview.existingCount) currently watched on Trakt", systemImage: "clock.arrow.circlepath")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Includes all seasons and specials for your selection.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct SharedHistoryCountRow: View {
    let count: Int
    let title: LocalizedStringKey
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(count, format: .number)
                    .font(.title.bold()).monospacedDigit()
                Text(title).font(.subheadline.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct SharedHistoryOverwriteNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This replaces your progress", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("Episodes watched beyond the shared progress will become unwatched. Their Trakt watch history, including repeat watches, will be removed.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("This cannot be automatically undone.")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 8)
    }
}


struct MoveToSharedListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let show: Show

    var body: some View {
        ThemedList {
            Section("Choose a shared list") {
                ForEach(store.sharedShows.lists) { list in
                    NavigationLink(list.name) {
                        SharedProgrammePicker(list: list, initialShow: RemoteShow(title: show.title, year: nil,
                                                                                ids: IDs(trakt: show.traktID, tmdb: show.tmdbID, imdb: show.imdbID)))
                    }
                }
            }
            if store.sharedShows.lists.isEmpty {
                Text("Create a list in Shared Shows first, then move this programme into it.")
            }
        }
        .navigationTitle("Move to Shared Shows")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await store.sharedShows.refresh() }
    }
}

struct SharedHistoryInboxView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var offers: [SharedHistoryOffer] = []
    @State private var selectedProgrammes: [SharedProgramme] = []
    @State private var showingReview = false
    private let previewOffers: [SharedHistoryOffer]?

    init(previewOffers: [SharedHistoryOffer]? = nil) {
        self.previewOffers = previewOffers
    }

    var body: some View {
        ThemedList {
            if offers.isEmpty {
                ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle",
                                       description: Text("You can sync later from Shared Shows."))
            } else {
                Section {
                    SharedHistoryInboxHeader(count: offers.count) {
                        review(offers)
                    }
                    .disabled(store.busy)
                }
                Section {
                    ForEach(offers) { offer in
                        SharedHistoryOfferRow(offer: offer) {
                            review([offer])
                        } keepHistory: {
                            store.sharedShows.review(offer)
                            offers.removeAll { $0.id == offer.id }
                        }
                        .disabled(store.busy)
                    }
                } header: {
                    Text("Or choose individually")
                } footer: {
                    Text("Syncing replaces your Trakt progress. You'll review changes before confirming.")
                }
            }
        }
        .navigationTitle("Sync shared shows")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingReview) {
            SharedHistoryImportView(programmes: selectedProgrammes)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(store.sharedHistoryImport.running || store.sharedHistoryImport.preparing)
            }
        }
        .interactiveDismissDisabled(store.sharedHistoryImport.running || store.sharedHistoryImport.preparing)
        .onAppear { offers = previewOffers ?? store.sharedShows.historyOffers }
    }

    private func review(_ selection: [SharedHistoryOffer]) {
        selectedProgrammes = selection.map(\.programme)
        for offer in selection {
            store.sharedShows.review(offer)
        }
        showingReview = true
    }
}

private struct SharedHistoryInboxHeader: View {
    @Environment(\.themeAccent) private var accent
    let count: Int
    let syncAll: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.fill")
                .font(.largeTitle)
                .foregroundStyle(accent)
                .padding(18)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Watch together")
                    .font(.title2.bold())
                Text("Match your progress for \(count) shared programmes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Button(action: syncAll) {
                Label("Sync all", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Review changes for all shared programmes.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct SharedHistoryOfferRow: View {
    let offer: SharedHistoryOffer
    let sync: () -> Void
    let keepHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SharedPickerThumbnail(tmdbID: offer.programme.show.ids.tmdb)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(offer.programme.show.title)
                        .font(.headline)
                    Text(offer.listName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("\(offer.programme.episodes.count) watched", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SharedHistoryOfferActions(sync: sync, keepHistory: keepHistory)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SharedHistoryOfferActions(sync: sync, keepHistory: keepHistory)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SharedHistoryOfferActions: View {
    let sync: () -> Void
    let keepHistory: () -> Void

    var body: some View {
        Button("Sync", systemImage: "arrow.triangle.2.circlepath", action: sync)
            .buttonStyle(.bordered)
        Button("Keep my progress", action: keepHistory)
            .buttonStyle(.borderless)
    }
}

#if DEBUG

#Preview("Shared Shows") {
    PreviewHost { data in
        NavigationStack { SharedShowsView() }
    }
}

#Preview("Household list") {
    PreviewHost { data in
        NavigationStack { HouseholdListView(listID: data.list.id) }
    }
}

#Preview("Shared programme row") {
    PreviewHost { data in
        List { SharedProgrammeRow(list: data.list, programme: data.programme) }
    }
}

#Preview("Move shared programme") {
    PreviewHost { data in
        NavigationStack { MoveSharedProgrammeView(programme: data.programme, source: data.list) }
    }
}

#Preview("Programme picker") {
    PreviewHost { data in
        NavigationStack { SharedProgrammePicker(list: data.list) }
    }
}

#Preview("Import history") {
    PreviewHost { data in
        NavigationStack { SharedHistoryImportView(programme: data.programme) }
    }
}

#Preview("Move to shared list") {
    PreviewHost { data in
        NavigationStack { MoveToSharedListView(show: data.show) }
    }
}

#Preview("History inbox") {
    PreviewHost { data in
        NavigationStack { SharedHistoryInboxView(previewOffers: data.historyOffers) }
    }
}

#Preview("History inbox — All caught up") {
    PreviewHost { _ in
        NavigationStack { SharedHistoryInboxView(previewOffers: []) }
    }
}
#endif

private struct SharedPickerThumbnail: View {
    @Environment(AppStore.self) private var store
    let tmdbID: Int?
    var posterPath: String? = nil
    @State private var fetchedPath: String?

    var body: some View {
        PosterImageView(posterPath: posterPath ?? fetchedPath, width: 40)
            .task(id: tmdbID) {
                fetchedPath = nil
                guard posterPath == nil, !PreviewEnvironment.isRunning,
                      let tmdbID, store.catalogue.configured else { return }
                let path = try? await store.catalogue.posterPath(tmdbID: tmdbID)
                guard !Task.isCancelled else { return }
                fetchedPath = path
            }
    }
}
