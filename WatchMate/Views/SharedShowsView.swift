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
            await loadCatalogues()
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
        if let show = shows.first(where: { $0.traktID == programme.id }), show.catalogueUpdatedAt != nil {
            return show.episodes.map {
                RemoteEpisode(season: $0.season, number: $0.number, title: $0.title,
                              ids: IDs(trakt: $0.traktID, tmdb: nil), overview: $0.overview,
                              firstAired: $0.firstAired.map { Dates.string($0) }, runtime: $0.runtime)
            }
        }
        return catalogues[programme.id]
    }

    private func loadCatalogues() async {
        guard let list else { return }
        for programme in list.programmes {
            if let show = shows.first(where: { $0.traktID == programme.id }), show.catalogueUpdatedAt != nil { continue }
            do {
                let episodes = try await TraktService(auth: store.auth).episodes(showID: programme.id)
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
                await store.refresh()
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
                        Button(show.title) {
                            selection = RemoteShow(title: show.title, year: nil, ids: IDs(trakt: show.traktID, tmdb: show.tmdbID, imdb: show.imdbID))
                        }
                    }
                }
            } else {
                Section("Search results") {
                    ForEach(results) { show in
                        Button {
                            selection = show
                        } label: {
                            HStack {
                                Text(show.title)
                                Spacer()
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
    let programme: SharedProgramme
    @State private var confirming = false

    var body: some View {
        let importer = store.sharedHistoryImport
        ThemedList {
            Section {
                Text(programme.show.title).font(.headline)
                Text("Replace your viewing progress?")
                    .font(.title3.bold())
                Text("Syncing will overwrite your existing Trakt viewing progress for this programme to match the shared progress. Episodes you have watched beyond that progress will be marked unwatched. Removing a watched episode also removes its Trakt watch history, including repeat watches.")
                Text("All seasons and specials are included. This can take several minutes for a long-running programme. Keep WatchMate open and connected to the internet.")
                    .foregroundStyle(.secondary)
            }
            if importer.preparing { ProgressView("Comparing all seasons and episodes…") }
            if let preview = importer.preview {
                Section("Changes to your Trakt account") {
                    Text("You currently have \(preview.existingCount) watched episodes.")
                    Text("\(preview.watchCount) episodes will be marked watched.")
                    Text("\(preview.unwatchCount) episodes will be marked unwatched.")
                    Text("Estimated minimum time: \(max(1, Int(ceil(Double(preview.changes.count) * 1.1 / 60)))) minute(s). Network delays and Trakt limits may increase this.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Overwrite my progress and sync", role: .destructive) { confirming = true }
                        .disabled(preview.changes.isEmpty)
                }
            }
            if importer.running {
                Section {
                    ProgressView(value: Double(importer.completed), total: Double(max(1, importer.total)))
                    Text("\(importer.completed) of \(importer.total) episodes updated")
                    Text(importer.currentEpisode).font(.caption)
                    Button("Stop syncing", role: .cancel) { importer.cancel() }
                    Text("Stopping keeps changes already made. You can review and sync again to finish.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !importer.status.isEmpty { Text(importer.status) }
            if !importer.running && !importer.preparing {
                Button("Review changes again") { Task { await importer.prepare(programme: programme, store: store) } }
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
        .task { if !PreviewEnvironment.isRunning, !importer.running { await importer.prepare(programme: programme, store: store) } }
        .alert("Overwrite your existing progress?", isPresented: $confirming) {
            Button("Overwrite and sync", role: .destructive) { importer.start(store: store) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your existing viewing progress for \(programme.show.title) will be overwritten to match the sharer’s progress. \(importer.preview?.watchCount ?? 0) episodes will be marked watched and \(importer.preview?.unwatchCount ?? 0) will be marked unwatched. This cannot be automatically undone.")
        }
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

    var body: some View {
        ThemedList {
            Section {
                Text("New programmes have been shared with you. You can keep your own viewing history or replace it with the shared progress, programme by programme.")
            }
            ForEach(offers) { offer in
                Section(offer.programme.show.title) {
                    Text(offer.listName).font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Review and sync viewing history") {
                        SharedHistoryImportView(programme: offer.programme)
                            .onAppear { store.sharedShows.review(offer) }
                    }
                    Button("Keep my existing history") {
                        store.sharedShows.review(offer)
                        offers.removeAll { $0.id == offer.id }
                    }
                }
            }
            if offers.isEmpty { Text("You can sync a programme later from its Shared Shows page.") }
        }
        .navigationTitle("Shared viewing history")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(store.sharedHistoryImport.running || store.sharedHistoryImport.preparing)
            }
        }
        .interactiveDismissDisabled(store.sharedHistoryImport.running || store.sharedHistoryImport.preparing)
        .onAppear { offers = store.sharedShows.historyOffers }
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
        NavigationStack { SharedHistoryInboxView() }
    }
}
#endif
