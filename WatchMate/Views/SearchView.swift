import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(AppStore.self) private var store
    @Query(filter: #Predicate<Show> { $0.isFollowing }) private var followedShows: [Show]
    @State private var query = ""
    @State private var results: [RemoteShow] = []
    @State private var details: [Int: CatalogueDetails] = [:]
    @State private var searching = false
    @State private var loadingAvailability = false
    @State private var message: String?
    @State private var artworkMessage: String?

    private var visibleResults: [RemoteShow] {
        guard store.settings.onlyMyServices, !store.settings.selectedProviders.isEmpty else { return results }
        return results.filter { show in
            details[show.id]?.providers.contains { store.settings.selectedProviders.contains($0.id) } == true
        }
    }

    var body: some View {
        let addedShowIDs = Set(followedShows.map(\.traktID)).subtracting(store.settings.hiddenShowIDs)
        let visible = visibleResults
        ThemedList {
            if store.settings.demoMode {
                ContentUnavailableView("Connect to discover shows", systemImage: "magnifyingglass", description: Text("Search uses Trakt. Connect your account in Settings to add real programmes."))
            } else if !store.connected {
                ContentUnavailableView("Connect Trakt first", systemImage: "person.crop.circle", description: Text("Open Settings to sign in."))
            } else if !query.isEmpty {
                if searching { ProgressView("Searching…") }
                if loadingAvailability { ProgressView("Checking streaming availability…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                if let artworkMessage { Text(artworkMessage).font(.caption).foregroundStyle(.secondary) }
                if store.settings.onlyMyServices && !store.settings.selectedProviders.isEmpty {
                    Text("Filtered to your services. Change this in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !searching && !loadingAvailability && visible.isEmpty && query.count >= 2 && message == nil {
                    Text(store.settings.onlyMyServices && !store.settings.selectedProviders.isEmpty
                         ? "No matching programmes with confirmed availability on your services."
                         : "No shows found.")
                }
                ForEach(visible) { show in
                    NavigationLink {
                        if let saved = followedShows.first(where: { $0.traktID == show.id && !store.settings.hiddenShowIDs.contains($0.traktID) }) {
                            ShowDetailView(show: saved)
                        } else {
                            SearchProgrammeDetailView(show: show, details: details[show.id])
                        }
                    } label: {
                        HStack(spacing: 12) {
                            PosterImageView(posterPath: details[show.id]?.posterPath, width: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(show.title).font(.headline)
                                if let year = show.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                                ProgrammeAvailabilityView(details: details[show.id])
                            }
                            Spacer(minLength: 0)
                            Button {
                                Task { await store.follow(show) }
                            } label: {
                                if addedShowIDs.contains(show.id) {
                                    Label("Added", systemImage: "checkmark")
                                } else {
                                    Label("Add", systemImage: "plus")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.busy || addedShowIDs.contains(show.id))
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                }
            }
        }
        .overlay {
            if query.isEmpty && store.connected && !store.settings.demoMode {
                SearchWelcomeView()
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Search TV programmes")
        .task(id: query + "|" + store.settings.region) {
            results = []; details = [:]; message = nil; artworkMessage = nil
            searching = false; loadingAvailability = false
            guard query.trimmingCharacters(in: .whitespaces).count >= 2,
                  !store.settings.demoMode, store.connected else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                searching = true
                let found = try await TraktService(auth: store.auth).search(query)
                try Task.checkCancellation()
                results = found; searching = false; loadingAvailability = true
                defer { if !Task.isCancelled { loadingAvailability = false } }
                for show in found {
                    try Task.checkCancellation()
                    guard let tmdbID = show.ids.tmdb else { continue }
                    do {
                        let info = try await store.catalogue.details(tmdbID: tmdbID, region: store.settings.region)
                        try Task.checkCancellation()
                        details[show.id] = info
                    } catch {
                        try Task.checkCancellation()
                        artworkMessage = error.localizedDescription
                    }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { message = error.localizedDescription; searching = false }
            }
        }
    }
}

private struct SearchWelcomeView: View {
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 20) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "tv")
                        .font(.system(size: 64, weight: .light))
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32, weight: .semibold))
                        .padding(6)
                        .background(.background, in: Circle())
                        .offset(x: 12, y: 8)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
                Text("Find your next watch")
                    .font(.title2.bold())
            }
        } description: {
            Text("Search for a programme to see where it’s streaming and add it to My Shows.")
        }
    }
}

struct ProgrammeAvailabilityView: View {
    @Environment(AppStore.self) private var store
    let details: CatalogueDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let details {
                if details.providers.isEmpty {
                    Text("No streaming services listed in your region.")
                } else {
                    Text(details.providers.map(\.name).joined(separator: " · "))
                }
                if !store.settings.selectedProviders.isEmpty &&
                    !details.providers.contains(where: { store.settings.selectedProviders.contains($0.id) }) {
                    Text("Not available on your selected services.")
                }
            } else {
                Text("Streaming availability not confirmed.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct SearchProgrammeDetailView: View {
    @Environment(AppStore.self) private var store
    @Query(filter: #Predicate<Show> { $0.isFollowing }) private var followedShows: [Show]
    let show: RemoteShow
    @State private var details: CatalogueDetails?
    @State private var loading = false
    @State private var message: String?

    init(show: RemoteShow, details: CatalogueDetails?) {
        self.show = show
        _details = State(initialValue: details)
    }

    private var added: Bool {
        followedShows.contains { $0.traktID == show.id && !store.settings.hiddenShowIDs.contains($0.traktID) }
    }

    var body: some View {
        ThemedList {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    PosterImageView(posterPath: details?.posterPath, width: 96)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(show.title).font(.title2.bold())
                        if let year = show.year { Text(String(year)).foregroundStyle(.secondary) }
                        ProgrammeAvailabilityView(details: details)
                    }
                }
                Button {
                    Task { await store.follow(show) }
                } label: {
                    if added { Label("Added", systemImage: "checkmark") }
                    else { Label("Add to My Shows", systemImage: "plus") }
                }
                .disabled(added || store.busy)
            }
            if loading { ProgressView("Loading programme details…") }
            if let message { Text(message).foregroundStyle(.secondary) }
            Section("Synopsis") {
                Text(details?.overview.isEmpty == false ? details?.overview ?? "" : "No synopsis available.")
            }
            if let link = details?.watchURL, let url = URL(string: link), url.scheme == "https" {
                Link("Check where to watch", destination: url)
            }
            Text("Streaming availability powered by JustWatch. Listings are for the series, not individual episodes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.settings.region) {
            guard let tmdbID = show.ids.tmdb else { return }
            loading = true
            defer { loading = false }
            do {
                let info = try await store.catalogue.details(tmdbID: tmdbID, region: store.settings.region)
                try Task.checkCancellation()
                details = info
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
}
