import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsOpen = false
    @State private var searchOpen = false
    @State private var selectedTab = 0
    @State private var widgetEpisodePath: [WidgetEpisodeLink] = []
    var body: some View {
        @Bindable var store = store
        TabView(selection: $selectedTab) {
            NavigationStack(path: $widgetEpisodePath) {
                UpNextView()
                    .modifier(ActivityToastModifier())
                    .toolbar { settingsButton }
                    .navigationDestination(for: WidgetEpisodeLink.self) { link in
                        if let episode = store.episode(forWidgetLink: link) {
                            EpisodeDetailView(episode: episode)
                        } else {
                            ContentUnavailableView("Episode unavailable", systemImage: "tv",
                                                   description: Text("This programme is no longer in your current library."))
                        }
                    }
            }
                .tabItem { Label("Up Next", systemImage: "play.circle.fill") }
                .tag(0)
            NavigationStack { ComingSoonView().modifier(ActivityToastModifier()).toolbar { settingsButton } }
                .tabItem { Label("Coming Soon", systemImage: "calendar") }
                .tag(1)
            NavigationStack {
                MyShowsView()
                    .modifier(ActivityToastModifier())
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Add programme", systemImage: "plus") { searchOpen = true }
                                .labelStyle(.iconOnly)
                        }
                        settingsButton
                    }
            }
            .tabItem { Label("My Shows", systemImage: "tv") }
            .tag(2)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.settings.demoMode {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Demo mode · sample shows").font(.caption)
                    Spacer()
                    Button("Connect") { settingsOpen = true }.font(.caption.bold())
                }.padding(.horizontal).padding(.vertical, 8).background(.thinMaterial)
            }
        }
        .disabled(store.seasonUpdateInProgress)
        .accessibilityHidden(store.seasonUpdateInProgress)
        .overlay {
            if store.seasonUpdateInProgress {
                SeasonUpdateOverlay(
                    completed: store.seasonUpdateCompleted,
                    total: store.seasonUpdateTotal
                )
            }
        }
        .sheet(isPresented: $settingsOpen) {
            NavigationStack { SettingsView() }
                .modifier(AppAppearanceModifier())
        }
        .sheet(isPresented: $searchOpen) {
            NavigationStack {
                SearchView()
                    .modifier(ActivityToastModifier())
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { searchOpen = false }
                        }
                    }
            }
            .modifier(AppAppearanceModifier())
            .alert("WatchMate", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
        .alert("WatchMate", isPresented: Binding(get: { store.errorMessage != nil && !settingsOpen && !searchOpen }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task(id: store.widgetEpisodeLink) {
            guard let link = store.widgetEpisodeLink else { return }
            settingsOpen = false
            searchOpen = false
            selectedTab = 0
            widgetEpisodePath = [link]
            store.widgetEpisodeLink = nil
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await store.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await store.start()
            }
        }
    }
    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { settingsOpen = true } label: {
                ProfilePhotoView(image: store.settings.profileImage, size: store.settings.profileImage == nil ? 28 : 36)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Settings")
        }
    }
}

private struct ActivityToastModifier: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var showToast = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if showToast && store.busy && !store.seasonUpdateInProgress {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(store.status)
                            .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
                }
            }
            .task(id: store.busy) {
                showToast = false
                guard store.busy else { return }
                // Avoid flashing a toast for brief background syncs.
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    showToast = true
                } catch { }
            }
    }
}

private struct SeasonUpdateOverlay: View {
    let completed: Int
    let total: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Marking season watched…")
                    .font(.headline)
                Text("\(completed) of \(total) episodes processed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isModal)
        }
    }
}

struct PosterView: View {
    let show: Show
    var width: CGFloat = 64
    var body: some View {
        PosterImageView(posterPath: show.posterPath, width: width)
    }
}

struct PosterImageView: View {
    let posterPath: String?
    var width: CGFloat = 64

    var body: some View {
        Group {
            if let path = posterPath, let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                }
            } else { placeholder }
        }.frame(width: width, height: width * 1.5).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.teal.opacity(0.75), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "tv.fill").font(.title2).foregroundStyle(.white)
        }
    }
}

struct ShowRow: View {
    @Environment(AppStore.self) private var store
    let show: Show
    var episode: Episode?
    var onlyMyServices = false
    var squareArtwork = false
    var showsAirDate = true
    var showsAiredPrefix = false
    var squareArtworkSize: CGFloat = 112

    private var displayedProviders: [Provider] {
        guard show.providerRegion == store.settings.region else { return [] }
        return show.providers.filter { !onlyMyServices || store.settings.selectedProviders.contains($0.id) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let episode {
                EpisodeArtworkView(show: show, episode: episode, width: squareArtwork ? squareArtworkSize : 96, squareCrop: squareArtwork)
            } else {
                PosterView(show: show)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(show.title).font(.headline)
                if let episode {
                    Text("\(episode.label) · \(episode.title)").font(.subheadline).lineLimit(2)
                    if showsAirDate, let date = episode.firstAired {
                        Group {
                            if showsAiredPrefix {
                                Text("Aired: \(Text(date, style: .date))")
                            } else {
                                Text(date, style: .date)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    let total = show.episodes.filter { store.settings.includeSpecials || $0.season > 0 }.count
                    let seen = show.episodes.filter { $0.watchedAt != nil && (store.settings.includeSpecials || $0.season > 0) }.count
                    Text("\(seen) of \(total) episodes watched").font(.subheadline).foregroundStyle(.secondary)
                    if total > 0 { ProgressView(value: Double(seen), total: Double(total)).frame(maxWidth: 150) }
                }
                if !displayedProviders.isEmpty {
                    Text(displayedProviders.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else { Text("Streaming availability unknown").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
}
