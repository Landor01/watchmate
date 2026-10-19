import CloudKit
import SwiftUI
import SwiftData

struct SharedShowsView: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var creating = false
    @State private var working = false

    var body: some View {
        List {
            if !store.connected || store.settings.demoMode {
                ContentUnavailableView("Connect Trakt first", systemImage: "person.crop.circle",
                                       description: Text("Connect your own Trakt account in Settings. Shared Shows also requires iCloud."))
            } else {
                Section {
                    Text("Share programmes and group progress while keeping separate Trakt accounts. Personal history changes only when you choose to sync it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
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
        .task { if store.connected && !store.settings.demoMode { await store.sharedShows.refresh(automatic: true) } }
        .refreshable { await store.sharedShows.refresh() }
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
    let listID: String
    @State private var adding = false
    @State private var share: CKShare?
    @State private var sharing = false
    @State private var working = false
    @State private var removing: SharedProgramme?

    private var list: HouseholdList? { store.sharedShows.lists.first { $0.id == listID } }

    var body: some View {
        List {
            if let list {
                SharedListPhotoSection(list: list)
                if list.programmes.isEmpty {
                    Text("Add programmes from My Shows or search for something new.")
                }
                ForEach(list.programmes) { programme in
                    NavigationLink {
                        SharedProgrammeView(listID: listID, showID: programme.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(programme.show.title).font(.headline)
                            Text("\(programme.episodes.count) episodes watched together")
                                .font(.caption).foregroundStyle(.secondary)
                            if programme.addedBy != store.settings.traktAccountID {
                                Text("Review or sync viewing history").font(.caption).foregroundStyle(.tint)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { removing = programme }
                    }
                }
            } else {
                ContentUnavailableView("List unavailable", systemImage: "person.2.slash",
                                       description: Text("Pull to refresh. The owner may have stopped sharing this list."))
            }
        }
        .navigationTitle("")
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
        .refreshable { await store.sharedShows.refresh() }
        .sheet(isPresented: $adding) {
            if let list { NavigationStack { SharedProgrammePicker(list: list) } }
        }
        .sheet(isPresented: $sharing, onDismiss: { Task { await store.sharedShows.refresh() } }) {
            if let share, let list { HouseholdSharingSheet(share: share, service: store.sharedShows, list: list) }
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
        List {
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
                            selection = RemoteShow(title: show.title, year: nil, ids: IDs(trakt: show.traktID, tmdb: show.tmdbID))
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
        List {
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
        .task { if !importer.running { await importer.prepare(programme: programme, store: store) } }
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
        List {
            Section("Choose a shared list") {
                ForEach(store.sharedShows.lists) { list in
                    NavigationLink(list.name) {
                        SharedProgrammePicker(list: list, initialShow: RemoteShow(title: show.title, year: nil,
                                                                                ids: IDs(trakt: show.traktID, tmdb: show.tmdbID)))
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
        List {
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
