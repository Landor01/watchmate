import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsOpen = false
    var body: some View {
        @Bindable var store = store
        TabView {
            NavigationStack { UpNextView().toolbar { settingsButton } }
                .tabItem { Label("Up Next", systemImage: "play.circle.fill") }
            NavigationStack { ComingSoonView().toolbar { settingsButton } }
                .tabItem { Label("Coming Soon", systemImage: "calendar") }
            NavigationStack { MyShowsView().toolbar { settingsButton } }
                .tabItem { Label("My Shows", systemImage: "tv") }
            NavigationStack { SearchView().toolbar { settingsButton } }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.settings.demoMode || store.busy {
                HStack(spacing: 8) {
                    if store.busy { ProgressView() }
                    Image(systemName: store.settings.demoMode ? "sparkles" : "arrow.triangle.2.circlepath")
                    Text(store.busy ? store.status : "Demo mode · sample shows").font(.caption)
                    Spacer()
                    if store.settings.demoMode { Button("Connect") { settingsOpen = true }.font(.caption.bold()) }
                }.padding(.horizontal).padding(.vertical, 8).background(.thinMaterial)
            }
        }
        .sheet(isPresented: $settingsOpen) { NavigationStack { SettingsView() } }
        .alert("WatchMate", isPresented: Binding(get: { store.errorMessage != nil && !settingsOpen }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.start() } }
        }
    }
    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { settingsOpen = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Settings")
        }
    }
}

struct PosterView: View {
    let show: Show
    var width: CGFloat = 64
    var body: some View {
        Group {
            if let path = show.posterPath, let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
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
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PosterView(show: show)
            VStack(alignment: .leading, spacing: 5) {
                Text(show.title).font(.headline)
                if let episode {
                    Text("\(episode.label) · \(episode.title)").font(.subheadline).lineLimit(2)
                    if let date = episode.firstAired { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                } else {
                    let total = show.episodes.filter { store.settings.includeSpecials || $0.season > 0 }.count
                    let seen = show.episodes.filter { $0.watchedAt != nil && (store.settings.includeSpecials || $0.season > 0) }.count
                    Text("\(seen) of \(total) episodes watched").font(.subheadline).foregroundStyle(.secondary)
                    if total > 0 { ProgressView(value: Double(seen), total: Double(total)).frame(maxWidth: 150) }
                }
                if show.providerRegion == store.settings.region && !show.providers.isEmpty {
                    Text(show.providers.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else { Text("Streaming availability unknown").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
}
