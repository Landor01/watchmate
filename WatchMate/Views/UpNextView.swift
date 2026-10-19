import SwiftUI
import SwiftData

struct UpNextView: View {
    @State private var showingAirDateInfo = false
    @Environment(AppStore.self) private var store
    @Query(sort: \Show.title) private var shows: [Show]

    private var waitingEntries: [UpNextEntry] {
        shows.compactMap { show in
            guard show.isFollowing else { return nil }
            let episodes = store.waiting(show)
            guard let episode = episodes.first else { return nil }
            return UpNextEntry(show: show, episode: episode, waitingCount: episodes.count)
        }
    }

    var body: some View {
        let entries = waitingEntries
        let followedShows = shows.filter { $0.isFollowing }
        let watchedEpisodes = followedShows.flatMap(\.episodes).filter {
            $0.watchedAt != nil && (store.settings.includeSpecials || $0.season > 0)
        }
        let remainingEpisodes = followedShows.flatMap { store.waiting($0) }
        ThemedList {
            Section {
                HStack(spacing: 12) {
                    let count = entries.reduce(0) { $0 + $1.waitingCount }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("^[\(count) episode](inflect: true) left to watch")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Label("Watched: \(duration(of: watchedEpisodes))", systemImage: "clock")
                        Label("Left to watch: \(duration(of: remainingEpisodes))", systemImage: "hourglass")
                    }
                    .font(.subheadline)
                    Spacer(minLength: 0)
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
            if entries.isEmpty {
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
                        HStack {
                            Text("\(entry.waitingCount) to watch").font(.caption.bold()).foregroundStyle(.tint)
                            Spacer()
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
        }
        .navigationTitle("Up Next").navigationBarTitleDisplayMode(.inline)
        .alert("Air dates and streaming", isPresented: $showingAirDateInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Air dates from Trakt. Streaming listings apply to the series; check your service for this episode.")
        }
        .refreshable { await store.refresh() }
    }

    private func duration(of episodes: [Episode]) -> String {
        let minutes = episodes.reduce(0) { $0 + max(0, $1.runtime ?? 0) }
        let hasUnknownRuntime = episodes.contains { ($0.runtime ?? 0) <= 0 }
        guard minutes > 0 else {
            return hasUnknownRuntime ? String(localized: "Unknown") : String(localized: "0 min")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }
}

private struct UpNextEntry: Identifiable {
    let show: Show
    let episode: Episode
    let waitingCount: Int
    var id: String { episode.key }
}

struct MyShowsView: View {
    @State private var showToRemove: Show?
    @State private var confirmRemoval = false
    @State private var showToShare: Show?
    @Query(sort: \Show.title) private var shows: [Show]
    @Environment(AppStore.self) private var store
    var body: some View {
        let personalShows = shows.filter { $0.isFollowing && !store.sharedShows.showIDs.contains($0.traktID) }
        ThemedList {
            if personalShows.isEmpty {
                ContentUnavailableView("Your shows live here", systemImage: "tv", description: Text("Tap + to find and add programmes, or connect Trakt in Settings to import your history and watchlist."))
            }
            ForEach(personalShows) { show in
                NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show) }
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
        }.navigationTitle("My Shows").navigationBarTitleDisplayMode(.inline).refreshable { await store.refresh() }
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
}
