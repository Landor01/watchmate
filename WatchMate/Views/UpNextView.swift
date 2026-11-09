import SwiftUI
import SwiftData

struct UpNextView: View {
    @State private var showingAirDateInfo = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppStore.self) private var store
    @Query(Show.followed) private var shows: [Show]

    @State private var sharedCatalogue = SharedDiscoveryCatalogue()

    private var personalShows: [Show] {
        let sharedIDs = store.sharedShows.showIDs
        let personalIDs = store.sharedShows.personalShowIDs
        return shows.filter { $0.isFollowing && (!sharedIDs.contains($0.traktID) || personalIDs.contains($0.traktID)) }
    }

    var body: some View {
        let snapshot = store.upNext?.accountScope == store.widgetAccountScope ? store.upNext : nil
        let entries = snapshot?.entries ?? []
        let shared = snapshot?.shared ?? []
        let sharedWaiting = SharedDiscoveryEntry.waiting(shared)
        let sharedNext = SharedDiscoveryEntry.next(sharedWaiting)
        let sharedByList = Dictionary(grouping: sharedNext, by: \.listID)
        let sharedCounts = sharedWaiting.reduce(into: [String: [Int: Int]]()) { counts, entry in
            counts[entry.listID, default: [:]][entry.showID, default: 0] += 1
        }
        let sharedGroups = sharedByList.map { id, entries in
            SharedDiscoverySection(id: id, name: entries.first?.listName ?? "",
                entries: entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        ThemedList {
            Section {
                let summaryLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                summaryLayout {
                    let count = entries.reduce(0) { $0 + $1.waitingCount } + sharedWaiting.count
                    VStack(alignment: .leading, spacing: 8) {
                        Text("^[\(count) episode](inflect: true) left to watch")
                            .font(.headline)
                            .foregroundStyle(Color.readableSecondary)
                        Label("Watched: \(duration(of: snapshot?.watchedRuntimes ?? []))", systemImage: "clock")
                        Label("Left to watch: \(duration(of: snapshot?.waitingRuntimes ?? []))", systemImage: "hourglass")
                    }
                    .font(.subheadline)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                    }
                    Button {
                        showingAirDateInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("About air dates and streaming availability")
                }
            }
            if snapshot == nil { ProgressView("Loading your shows…") }
            if let message = snapshot?.message { Text(message).foregroundStyle(Color.readableSecondary) }
            if entries.isEmpty && sharedNext.isEmpty && snapshot != nil && snapshot?.message == nil {
                ContentUnavailableView("You're caught up", systemImage: "checkmark.circle", description: Text("Add programmes using + in My Shows, or connect Trakt."))
            }
            Section {
                ForEach(entries) { entry in
                    VStack(spacing: 8) {
                        NavigationLink {
                            if let episode = liveEpisode(entry) {
                                EpisodeDetailView(episode: episode)
                            }
                        } label: {
                            ShowRow(show: entry.show, episode: entry.episode, squareArtwork: true, showsAiredPrefix: true, squareArtworkSize: 96)
                        }
                        let actionsLayout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout())
                        actionsLayout {
                            Text("\(entry.waitingCount) to watch").font(.caption.bold()).foregroundStyle(.tint)
                            if !dynamicTypeSize.isAccessibilitySize {
                                Spacer()
                            }
                            Button("Mark watched") {
                                Task { if let episode = liveEpisode(entry) { await store.setWatched(episode, watched: true) } }
                            }
                            Button("Skip") {
                                Task { if let episode = liveEpisode(entry) { await store.skip(episode) } }
                            }
                        }
                        .buttonStyle(WatchActionButtonStyle())
                        .font(.caption)
                        .disabled(store.busy)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                        dimensions[.leading]
                    }
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                        dimensions[.trailing]
                    }
                }
            }
            ForEach(sharedGroups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        SharedDiscoveryRow(entry: entry, showsActions: true, showsListName: false,
                                           waitingCount: sharedCounts[entry.listID]?[entry.showID] ?? 0, opensEpisode: true)
                    }
                } header: {
                    Label(group.name, systemImage: "person.2")
                }
            }
        }
        .task(id: store.widgetAccountScope) {
            if store.upNext?.accountScope != store.widgetAccountScope {
                if !store.settings.demoMode { store.sharedShows.activate(accountID: store.settings.traktAccountID) }
                await store.prepareUpNext()
            }
        }
        .navigationTitle("Up Next").navigationBarTitleDisplayMode(.inline)
        .alert("Air dates and streaming", isPresented: $showingAirDateInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Air dates from Trakt. Streaming listings apply to the series; check your service for this episode.")
        }
        .refreshable {
            await store.refresh(showIDs: Set(personalShows.filter { !store.waiting($0).isEmpty || ($0.seriesStatus != "Ended" && $0.seriesStatus != "Canceled") }.map(\.traktID)))
            await store.refreshSharedShows()
            await sharedCatalogue.load(store: store, shows: shows, forceRefresh: true)
            await store.prepareUpNext()
        }
    }

    private func liveEpisode(_ entry: UpNextSnapshot.PersonalEntry) -> Episode? {
        (try? store.show(id: entry.show.traktID))?.episodes.first { $0.key == entry.id }
    }

    private func duration(of runtimes: [Int?]) -> String {
        let minutes = runtimes.reduce(0) { $0 + max(0, $1 ?? 0) }
        let hasUnknownRuntime = runtimes.contains { ($0 ?? 0) <= 0 }
        guard minutes > 0 else {
            return hasUnknownRuntime ? String(localized: "Unknown") : String(localized: "0 min")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }
}

/// Keeps episode navigation inside the split view's detail column.
struct MyShowsDetailView: View {
    let show: Show

    var body: some View {
        NavigationStack {
            ShowDetailView(show: show)
        }
        // Selecting another programme starts a fresh detail navigation stack.
        .id(show.persistentModelID)
    }
}

struct MyShowsView: View {
    var leadingMargin: CGFloat = 16
    var trailingMargin: CGFloat = 16
    @State private var showToRemove: Show?
    @State private var confirmRemoval = false
    @State private var showToShare: Show?
    @Query(Show.followed) private var shows: [Show]
    @Environment(AppStore.self) private var store
    var body: some View {
        let personalShows = shows.filter { $0.isFollowing && (!store.sharedShows.showIDs.contains($0.traktID) || store.sharedShows.personalShowIDs.contains($0.traktID)) }
        let now = Date()
        let completedIDs = Set(personalShows.filter {
            EpisodeRules.isComplete($0.episodes.map(\.state), includeSpecials: store.settings.includeSpecials)
        }.map(\.traktID))
        let upToDateIDs = Set(personalShows.filter {
            EpisodeRules.isUpToDate($0.episodes.map(\.state), now: now, includeSpecials: store.settings.includeSpecials)
        }.map(\.traktID))
        let activeShows = personalShows.filter { !completedIDs.contains($0.traktID) && !upToDateIDs.contains($0.traktID) }
        let upToDateShows = personalShows.filter { upToDateIDs.contains($0.traktID) }
        let completedShows = personalShows.filter { completedIDs.contains($0.traktID) }
        ThemedList {
            if personalShows.isEmpty {
                ContentUnavailableView(
                    "Your shows live here",
                    systemImage: "tv",
                    description: store.connected
                        ? Text("Tap + to find and add programmes.")
                        : Text("Tap + to find and add programmes, or connect Trakt in Settings to import your history and watchlist.")
                )
            }
            showRows(activeShows)
            if !upToDateShows.isEmpty {
                Section("Up to date") {
                    showRows(upToDateShows)
                }
            }
            if !completedShows.isEmpty {
                Section("Completed") {
                    showRows(completedShows)
                }
            }
        }.navigationTitle("My Shows").navigationBarTitleDisplayMode(.inline).refreshable { await store.refresh() }
            .listStyle(.insetGrouped)
            .contentMargins(.leading, leadingMargin, for: .scrollContent)
            .contentMargins(.trailing, trailingMargin, for: .scrollContent)
            .sheet(item: $showToShare) { show in
                NavigationStack { MoveToSharedListView(show: show) }
            }
            .confirmationDialog("Remove from My Shows?", isPresented: $confirmRemoval, titleVisibility: .visible, presenting: showToRemove) { show in
                Button("Remove", role: .destructive) {
                    Task { await store.hide(show) }
                }
            } message: { show in
                Text("Remove \(show.title) from WatchMate? Your Trakt history and watchlist will be kept. You can add it again using +.")
            }
    }

    private func showRows(_ shows: [Show]) -> some View {
        ForEach(shows) { show in
            NavigationLink { MyShowsDetailView(show: show) } label: { ShowRow(show: show) }
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading]
                }
                .contextMenu {
                    Button("Move to Shared Shows", systemImage: "person.2") { showToShare = show }
                        .disabled(store.busy || store.settings.demoMode || !store.connected)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        showToRemove = show
                        confirmRemoval = true
                    }
                    .disabled(store.busy)
                }
        }
    }
}

#if DEBUG

#Preview("Up Next") {
    PreviewHost { data in
        NavigationStack { UpNextView() }
    }
}

#Preview("My Shows") {
    PreviewHost { data in
        NavigationStack { MyShowsView() }
    }
}
#endif

private struct SharedDiscoverySection: Identifiable {
    let id: String
    let name: String
    let entries: [SharedDiscoveryEntry]
}

struct SharedDiscoveryRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: SharedDiscoveryEntry
    var showsActions = false
    var showsListName = true
    var waitingCount = 0
    var opensEpisode = false
    @State private var artwork: [String] = []
    @State private var providers: [Provider] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                if opensEpisode {
                    SharedEpisodeDetails(listID: entry.listID, showID: entry.showID, episode: entry.episode,
                                         tmdbID: entry.tmdbID, posterPath: artwork.last) { _, action in
                        update(action)
                    }
                } else {
                    SharedProgrammeView(listID: entry.listID, showID: entry.showID)
                }
            } label: {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
                layout {
                    FallbackArtworkView(paths: artwork, width: 96, height: 96, contentMode: .fill)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.headline)
                        if showsListName {
                            Label(entry.listName, systemImage: "person.2")
                                .font(.caption).foregroundStyle(Color.readableSecondary)
                        }
                        Text("S\(entry.episode.season) E\(entry.episode.number) · \(entry.episode.title ?? "Episode")")
                            .font(.subheadline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        if let date = entry.date {
                            Group {
                                if AirDates.hasAired(date) { Text("Aired: \(Text(date, style: .date))") }
                                else { Text("Airs: \(Text(date, style: .date))") }
                            }
                            .font(.caption).foregroundStyle(Color.readableSecondary)
                        }
                        if providers.isEmpty {
                            Text("Streaming availability unknown").font(.caption).foregroundStyle(Color.readableSecondary)
                        } else {
                            ProviderNamesView(providers: providers).font(.caption).foregroundStyle(Color.readableSecondary)
                        }
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                }
                .padding(.vertical, 6)
            }
            if showsActions {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout())
                layout {
                    Text("\(waitingCount) to watch").font(.caption.bold()).foregroundStyle(.tint)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Button("Mark watched") { update(.watched(true)) }
                    Button("Skip") { update(.skipped(true)) }
                }
                .buttonStyle(WatchActionButtonStyle())
                .font(.caption)
                .disabled(store.busy)
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .task(id: "\(entry.id):\(entry.tmdbID ?? 0):\(store.settings.region)") {
            let local = try? store.show(id: entry.showID)
            let demo = DemoLibrary.artwork(for: "\(entry.showID):\(entry.episode.season):\(entry.episode.number)")
            artwork = [demo, local?.posterPath].compactMap { $0 }
            providers = local?.providerRegion == store.settings.region ? local?.providers ?? [] : []
            guard !PreviewEnvironment.isRunning, let tmdbID = entry.tmdbID ?? local?.tmdbID,
                  store.catalogue.configured else { return }
            let details = try? await store.catalogue.details(tmdbID: tmdbID, region: store.settings.region)
            guard !Task.isCancelled else { return }
            providers = details?.providers ?? providers
            let poster = details?.posterPath ?? local?.posterPath
            artwork = [poster].compactMap { $0 }
            let episodeArtwork = try? await store.catalogue.episodeArtwork(
                tmdbID: tmdbID, season: entry.episode.season, episode: entry.episode.number)
            guard !Task.isCancelled else { return }
            artwork = (episodeArtwork ?? []) + [poster].compactMap { $0 }
        }
    }

    private func update(_ action: SharedEpisodeAction) {
        guard !store.busy, let list = store.sharedShows.lists.first(where: { $0.id == entry.listID }) else { return }
        store.busy = true
        Task {
            defer { store.busy = false }
            do {
                try await store.updateSharedEpisodes([entry.episode], showID: entry.showID, in: list, action: action)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}

#if DEBUG
#Preview("Shared discovery rows") {
    PreviewHost { data in
        let entry = SharedDiscoveryEntry(listID: data.list.id, listName: data.list.name,
                                         showID: data.show.traktID, title: data.show.title,
                                         episode: data.remoteEpisode, watched: false, skipped: false)
        NavigationStack {
            ThemedList {
                Section {
                    SharedDiscoveryRow(entry: entry, showsActions: true, showsListName: false, waitingCount: 3, opensEpisode: true)
                } header: {
                    Label(data.list.name, systemImage: "person.2")
                }
                Section("Coming Soon") {
                    SharedDiscoveryRow(entry: entry)
                }
            }
        }
    }
}
#endif
