import SwiftUI
import SwiftData

struct UpNextView: View {
    var isPreparing = false
    @State private var initialCatalogueLoaded = false

    private var showingInitialRefresh: Bool { isPreparing || !initialCatalogueLoaded }
    private var initialRefreshStage: Int { isPreparing ? store.completedRefreshStages : 5 }

    private var initialRefreshMessage: LocalizedStringKey {
        switch initialRefreshStage {
        case 0: "Checking watched episodes…"
        case 1: "Syncing shared lists…"
        case 2: "Syncing preferences…"
        case 3: "Updating episode details…"
        case 4: "Syncing shared progress…"
        default: "Preparing Up Next…"
        }
    }
    @State private var showingAirDateInfo = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppStore.self) private var store
    @Query(Show.withEpisodes) private var shows: [Show]

    @State private var sharedCatalogue = SharedDiscoveryCatalogue()

    private var personalShows: [Show] {
        let sharedIDs = store.sharedShows.showIDs
        let personalIDs = store.sharedShows.personalShowIDs
        return shows.filter { $0.isFollowing && (!sharedIDs.contains($0.traktID) || personalIDs.contains($0.traktID)) }
    }

    var body: some View {
        let followedShows = personalShows
        let waitingByShow = followedShows.map { (show: $0, episodes: store.waiting($0)) }
        let entries = waitingByShow.compactMap { item -> UpNextEntry? in
            guard let episode = item.episodes.first else { return nil }
            return UpNextEntry(show: item.show, episode: episode, waitingCount: item.episodes.count)
        }.sorted {
            $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending
        }
        let shared = SharedDiscoveryEntry.entries(lists: store.sharedShows.lists, catalogues: sharedCatalogue.episodes,
                                                  includeSpecials: store.settings.includeSpecials)
        let sharedWaiting = SharedDiscoveryEntry.waiting(shared)
        let sharedNext = SharedDiscoveryEntry.next(sharedWaiting)
        let sharedByList = Dictionary(grouping: sharedNext, by: \.listID)
        let sharedCounts = sharedWaiting.reduce(into: [String: [Int: Int]]()) { counts, entry in
            counts[entry.listID, default: [:]][entry.showID, default: 0] += 1
        }
        let sharedGroups = store.sharedShows.lists.compactMap { list -> SharedDiscoverySection? in
            let entries = (sharedByList[list.id] ?? []).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return entries.isEmpty ? nil : SharedDiscoverySection(id: list.id, name: list.name, entries: entries)
        }
        let watchedEpisodes = followedShows.flatMap(\.episodes).filter {
            $0.watchedAt != nil && (store.settings.includeSpecials || $0.season > 0)
        }
        let remainingEpisodes = waitingByShow.flatMap(\.episodes)
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
                            .foregroundStyle(.secondary)
                        Label("Watched: \(duration(of: watchedEpisodes.map(\.runtime) + shared.filter(\.watched).map { $0.episode.runtime }))", systemImage: "clock")
                        Label("Left to watch: \(duration(of: remainingEpisodes.map(\.runtime) + sharedWaiting.map { $0.episode.runtime }))", systemImage: "hourglass")
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
            if sharedCatalogue.loading { ProgressView("Loading shared programmes…") }
            if let message = sharedCatalogue.message { Text(message).foregroundStyle(.secondary) }
            if entries.isEmpty && sharedNext.isEmpty && !sharedCatalogue.loading && sharedCatalogue.message == nil {
                ContentUnavailableView("You're caught up", systemImage: "checkmark.circle", description: Text("Add programmes using + in My Shows, or connect Trakt."))
            }
            Section {
                ForEach(entries) { entry in
                    VStack(spacing: 8) {
                        NavigationLink {
                            EpisodeDetailView(episode: entry.episode)
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
                                Task { await store.setWatched(entry.episode, watched: true) }
                            }
                            Button("Skip") {
                                Task { await store.skip(entry.episode) }
                            }
                        }
                        .buttonStyle(.bordered)
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
        // Keep the list mounted so its data can settle without exposing intermediate rows.
        .opacity(showingInitialRefresh ? 0 : 1)
        .allowsHitTesting(!showingInitialRefresh)
        .accessibilityHidden(showingInitialRefresh)
        .overlay {
            if showingInitialRefresh {
                UpNextSyncView(stage: initialRefreshStage, message: initialRefreshMessage)
            }
        }
        .task(id: "\(isPreparing):\(store.sharedShows.showIDs.sorted()):\(store.catalogueRevision)") {
            guard !isPreparing else { return }
            await sharedCatalogue.load(store: store, shows: shows)
            guard !Task.isCancelled else { return }
            initialCatalogueLoaded = true
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
        }
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

private struct UpNextSyncView: View {
    @AppStorage("appTheme") private var themeValue = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeAccent) private var accent
    let stage: Int
    let message: LocalizedStringKey

    var body: some View {
        let theme = AppTheme(rawValue: themeValue) ?? .system
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "play.tv.fill")
                        .font(.largeTitle)
                        .foregroundStyle(accent)
                        .frame(width: 88, height: 88)
                        .background(
                            LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.06)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 26)
                        )
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Setting the scene")
                            .font(.title2.bold())
                        Text("Getting your next watch ready.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(message)
                            .font(.subheadline.weight(.medium))
                        ProgressView(value: Double(stage), total: 6)
                            .progressViewStyle(.linear)
                            .tint(accent)
                            .accessibilityLabel("Syncing your shows")
                            .accessibilityValue("Step \(stage + 1) of 6")
                        Text("Step \(stage + 1) of 6")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                    .padding(20)
                    .background(theme.chartSurfaceColor(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 20))
                }
                .padding(24)
                .background(theme.tileColor(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 30))
                .overlay {
                    RoundedRectangle(cornerRadius: 30)
                        .strokeBorder(accent.opacity(0.12), lineWidth: 1)
                }
                .frame(maxWidth: 380)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
            .background(theme.backgroundColor(for: colorScheme))
        }
    }
}

private struct UpNextEntry: Identifiable {
    let show: Show
    let episode: Episode
    let waitingCount: Int
    var id: String { episode.key }
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
    @Query(Show.withEpisodes) private var shows: [Show]
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
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("S\(entry.episode.season) E\(entry.episode.number) · \(entry.episode.title ?? "Episode")")
                            .font(.subheadline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        if let date = entry.date {
                            Group {
                                if AirDates.hasAired(date) { Text("Aired: \(Text(date, style: .date))") }
                                else { Text("Airs: \(Text(date, style: .date))") }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        if providers.isEmpty {
                            Text("Streaming availability unknown").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProviderNamesView(providers: providers).font(.caption).foregroundStyle(.secondary)
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
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(store.busy)
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .task(id: "\(entry.id):\(entry.tmdbID ?? 0):\(store.settings.region)") {
            let local = try? store.allShows().first { $0.traktID == entry.showID }
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
