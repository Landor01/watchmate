import SwiftUI
import SwiftData

struct UpNextView: View {
    @Environment(AppStore.self) private var store
    @Query(sort: \Show.title) private var shows: [Show]
    @State private var onlyMyServices = false
    private var waitingShows: [Show] {
        shows.filter { $0.isFollowing && !store.waiting($0).isEmpty && (!onlyMyServices || store.matchesServices($0)) }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your next great watch.").font(.largeTitle.bold())
                    Text("\(waitingShows.reduce(0) { $0 + store.waiting($1).count }) aired episodes unwatched")
                        .font(.title3).foregroundStyle(.mint)
                    Text("Air dates from Trakt. Streaming listings apply to the series; check your service for this episode.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                Toggle("Filter to my services", isOn: $onlyMyServices)
                    .disabled(store.settings.selectedProviders.isEmpty)
            }
            if waitingShows.isEmpty {
                ContentUnavailableView("You're caught up", systemImage: "checkmark.circle", description: Text("Follow shows in Search, connect Trakt, or change your service filter."))
            }
            ForEach(waitingShows) { show in
                if let episode = store.waiting(show).first {
                    Section {
                        NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show, episode: episode) }
                        HStack {
                            Text("\(store.waiting(show).count) to watch").font(.caption.bold()).foregroundStyle(.mint)
                            Spacer()
                            Button("Mark watched", systemImage: "checkmark") { Task { await store.setWatched(episode, watched: true) } }
                                .buttonStyle(.bordered).disabled(store.busy)
                        }
                    }
                }
            }
            if !store.status.isEmpty { Text(store.status).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("WatchMate").navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }
}

struct ComingSoonView: View {
    @Environment(AppStore.self) private var store
    @Query(sort: \Show.title) private var shows: [Show]
    private var entries: [(show: Show, episode: Episode)] {
        shows.filter(\.isFollowing).flatMap { show in store.upcoming(show).map { (show: show, episode: $0) } }
            .sorted { $0.episode.firstAired! < $1.episode.firstAired! }
    }
    var body: some View {
        List {
            Section {
                Text("Scheduled over the next 30 days. Air dates can change and may differ from local streaming release dates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if entries.isEmpty { ContentUnavailableView("Nothing scheduled yet", systemImage: "calendar", description: Text("New air dates will appear when supplied by Trakt.")) }
            ForEach(entries, id: \.episode.key) { entry in
                NavigationLink { ShowDetailView(show: entry.show) } label: { ShowRow(show: entry.show, episode: entry.episode) }
            }
        }.navigationTitle("Coming Soon").refreshable { await store.refresh() }
    }
}

struct MyShowsView: View {
    @Query(sort: \Show.title) private var shows: [Show]
    @Environment(AppStore.self) private var store
    var body: some View {
        List {
            if shows.filter(\.isFollowing).isEmpty {
                ContentUnavailableView("Your shows live here", systemImage: "tv", description: Text("Connect Trakt to import your history and watchlist."))
            }
            ForEach(shows.filter(\.isFollowing)) { show in
                NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show) }
            }
        }.navigationTitle("My Shows").refreshable { await store.refresh() }
    }
}
