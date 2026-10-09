import SwiftUI

struct ShowDetailView: View {
    @Environment(AppStore.self) private var store
    let show: Show
    @State private var hideConfirmation = false
    private var seasons: [Int] { Set(show.episodes.filter { store.settings.includeSpecials || $0.season > 0 }.map(\.season)).sorted() }
    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    PosterView(show: show, width: 96)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(show.title).font(.title2.bold())
                        Text("\(store.waiting(show).count) aired episodes to watch").foregroundStyle(.mint)
                        if show.providerRegion == store.settings.region {
                            Text(show.providers.map(\.name).joined(separator: " · ")).font(.caption)
                        }
                    }
                }
                if !show.overview.isEmpty { Text(show.overview).font(.subheadline) }
                if show.providerRegion == store.settings.region, let link = show.watchURL, let url = URL(string: link), url.scheme == "https" {
                    Link("Check where to watch", destination: url)
                }
                Text("Streaming availability powered by JustWatch. Listings are for the series, not individual episodes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Remind me on scheduled air dates", isOn: Binding(get: { show.notificationsEnabled }, set: { enabled in
                    Task { await store.enableNotifications(show, enabled: enabled) }
                })).disabled(store.busy || store.settings.demoMode)
            }
            if seasons.isEmpty { Text("Episode details haven't loaded. Pull to refresh to try again.").foregroundStyle(.secondary) }
            ForEach(seasons, id: \.self) { season in
                Section(season == 0 ? "Specials" : "Season \(season)") {
                    ForEach(show.episodes.filter { $0.season == season }.sorted { $0.number < $1.number }) { episode in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: episode.watchedAt != nil ? "checkmark.circle.fill" : episode.isSkipped ? "forward.end.circle" : "circle")
                                .foregroundStyle(episode.watchedAt != nil ? Color.mint : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(episode.label) · \(episode.title)").font(.subheadline.bold())
                                if let date = episode.firstAired {
                                    Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                    if date > Date() { Text("Scheduled").font(.caption).foregroundStyle(.orange) }
                                } else { Text("Air date unknown").font(.caption).foregroundStyle(.secondary) }
                                if episode.isSkipped { Text("Skipped locally").font(.caption).foregroundStyle(.secondary) }
                                HStack {
                                    Button(episode.watchedAt == nil ? "Mark watched" : "Mark unwatched") {
                                        Task { await store.setWatched(episode, watched: episode.watchedAt == nil) }
                                    }.buttonStyle(.bordered)
                                    Button(episode.isSkipped ? "Unskip" : "Skip") { Task { await store.skip(episode) } }
                                        .buttonStyle(.borderless)
                                }.font(.caption).disabled(store.busy)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section {
                Button("Hide from WatchMate", role: .destructive) { hideConfirmation = true }.disabled(store.busy)
                Text("This hides the show here. It does not remove your Trakt history or watchlist entry. Find it in Search to follow it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(show.title).navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .confirmationDialog("Hide \(show.title)?", isPresented: $hideConfirmation, titleVisibility: .visible) {
                Button("Hide", role: .destructive) { Task { await store.hide(show) } }
            }
    }
}
