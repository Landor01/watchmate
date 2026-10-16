import SwiftUI
import SwiftData

struct UpNextView: View {
    @State private var showingAirDateInfo = false
    @Environment(AppStore.self) private var store
    @Query(sort: \Show.title) private var shows: [Show]

    private var waitingEntries: [UpNextEntry] {
        shows.compactMap { show in
            guard show.isFollowing, store.passesServiceFilter(show) else { return nil }
            let episodes = store.waiting(show)
            guard let episode = episodes.first else { return nil }
            return UpNextEntry(show: show, episode: episode, waitingCount: episodes.count)
        }
    }

    var body: some View {
        let entries = waitingEntries
        ThemedList {
            Section {
                HStack(spacing: 12) {
                    let count = entries.reduce(0) { $0 + $1.waitingCount }
                    Text("^[\(count) episode](inflect: true) left to watch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                if store.settings.onlyMyServices {
                    ContentUnavailableView("No shows on your services", systemImage: "line.3.horizontal.decrease.circle", description: Text("Choose services in Settings or turn off the service filter to see other shows."))
                } else {
                    ContentUnavailableView("You're caught up", systemImage: "checkmark.circle", description: Text("Add programmes using + in My Shows, or connect Trakt."))
                }
            }
            Section {
                ForEach(entries) { entry in
                    VStack(spacing: 8) {
                        NavigationLink {
                            EpisodeDetailView(episode: entry.episode)
                        } label: {
                            ShowRow(show: entry.show, episode: entry.episode, onlyMyServices: store.settings.onlyMyServices, squareArtwork: true, showsAiredPrefix: true, squareArtworkSize: 96)
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
    @Query(sort: \Show.title) private var shows: [Show]
    @Environment(AppStore.self) private var store
    var body: some View {
        ThemedList {
            if shows.filter({ $0.isFollowing && store.passesServiceFilter($0) }).isEmpty {
                if store.settings.onlyMyServices && !store.settings.selectedProviders.isEmpty {
                    ContentUnavailableView("No shows on your services", systemImage: "tv", description: Text("Change your service filter in Settings to see other programmes."))
                } else {
                    ContentUnavailableView("Your shows live here", systemImage: "tv", description: Text("Tap + to find and add programmes, or connect Trakt in Settings to import your history and watchlist."))
                }
            }
            ForEach(shows.filter { $0.isFollowing && store.passesServiceFilter($0) }) { show in
                NavigationLink { ShowDetailView(show: show) } label: { ShowRow(show: show) }
                    .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                        dimensions[.leading]
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            showToRemove = show
                            confirmRemoval = true
                        }
                        .disabled(store.busy)
                    }
            }
        }.navigationTitle("My Shows").refreshable { await store.refresh() }
            .confirmationDialog("Remove from My Shows?", isPresented: $confirmRemoval, titleVisibility: .visible, presenting: showToRemove) { show in
                Button("Remove", role: .destructive) {
                    Task { await store.hide(show) }
                }
            } message: { show in
                Text("Remove \(show.title) from WatchMate? Your Trakt history and watchlist will be kept. You can add it again using +.")
            }
    }
}
