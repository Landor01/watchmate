import SwiftUI

struct ShowDetailView: View {
    @Environment(AppStore.self) private var store
    let show: Show
    @State private var hideConfirmation = false
    @State private var showingStreamingInfo = false
    @Environment(\.dismiss) private var dismiss
    @State private var seasonPosters: [Int: String] = [:]
    @State private var selectedEpisode: Episode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completedSeasonsExpanded = false
    @State private var completionMessage: String?

    private var seasonGroups: (ready: [Int], upcoming: [Int], completed: [Int]) {
        let episodes = show.episodes.filter { store.settings.includeSpecials || $0.season > 0 }
        let grouped = Dictionary(grouping: episodes, by: \.season)
        let now = Date()
        var ready: [Int] = []
        var upcoming: [Int] = []
        var completed: [Int] = []
        for season in grouped.keys.sorted() {
            let remaining = (grouped[season] ?? []).filter { $0.watchedAt == nil && !$0.isSkipped }
            if remaining.isEmpty {
                completed.append(season)
            } else if remaining.contains(where: { $0.firstAired.map { AirDates.hasAired($0, now: now) } == true }) {
                ready.append(season)
            } else {
                upcoming.append(season)
            }
        }
        return (ready, upcoming, completed)
    }
    var body: some View {
        let groups = seasonGroups
        ThemedList {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    PosterView(show: show, width: 96)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(show.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text("\(store.waiting(show).count) aired episodes to watch")
                            .foregroundStyle(.tint)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        if show.providerRegion == store.settings.region {
                            ProviderNamesView(providers: show.providers).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        showingStreamingInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("About streaming availability")
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                if !show.overview.isEmpty { Text(show.overview).font(.subheadline) }
                if let imdbURL = show.imdbURL {
                    Link(destination: imdbURL) {
                        Label("View show on IMDb", systemImage: "arrow.up.right.square")
                    }
                }
                Toggle("Remind me on scheduled air dates", isOn: Binding(get: { show.notificationsEnabled }, set: { enabled in
                    Task { await store.enableNotifications(show, enabled: enabled) }
                })).disabled(store.busy || store.settings.demoMode)
                if show.notificationsEnabled {
                    DatePicker("Reminder time", selection: Binding(
                        get: {
                            Calendar.current.date(bySettingHour: show.reminderMinutes / 60,
                                                  minute: show.reminderMinutes % 60, second: 0,
                                                  of: Date()) ?? Date()
                        },
                        set: { store.setReminderTime(show, date: $0) }
                    ), displayedComponents: .hourAndMinute)
                    .disabled(store.busy || store.settings.demoMode)
                    Text("Remind me at this local time on each scheduled air date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if groups.ready.isEmpty && groups.upcoming.isEmpty && groups.completed.isEmpty {
                Text("Episode details haven't loaded. Pull to refresh to try again.").foregroundStyle(.secondary)
            }
            ForEach(groups.ready, id: \.self) { season in
                SeasonSection(show: show, season: season, posterPath: seasonPosters[season] ?? show.posterPath, selectedEpisode: $selectedEpisode)
            }
            ForEach(groups.upcoming, id: \.self) { season in
                SeasonSection(show: show, season: season, posterPath: seasonPosters[season] ?? show.posterPath, selectedEpisode: $selectedEpisode)
            }
            if !groups.completed.isEmpty {
                Section {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut) {
                            completedSeasonsExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Completed seasons (\(groups.completed.count))")
                            Spacer()
                            Image(systemName: completedSeasonsExpanded ? "chevron.down" : "chevron.right")
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(completedSeasonsExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Show or hide watched and skipped seasons")
                }
                if completedSeasonsExpanded {
                    ForEach(groups.completed, id: \.self) { season in
                        SeasonSection(show: show, season: season, posterPath: seasonPosters[season] ?? show.posterPath, selectedEpisode: $selectedEpisode)
                    }
                }
            }
            Section {
                Button("Remove from My Shows", role: .destructive) { hideConfirmation = true }.disabled(store.busy)
                Text("This removes the programme from WatchMate. Your Trakt history and watchlist are kept. Use + in My Shows to add it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(show.title).navigationBarTitleDisplayMode(.inline)
            .alert("Streaming availability", isPresented: $showingStreamingInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Streaming availability powered by JustWatch. Listings are for the series, not individual episodes.")
            }
            .navigationDestination(item: $selectedEpisode) { episode in
                EpisodeDetailView(episode: episode)
            }
            .refreshable { await store.refresh() }
            .task(id: show.tmdbID) {
                guard let tmdbID = show.tmdbID, store.catalogue.configured else { return }
                if let posters = try? await store.catalogue.seasonPosters(tmdbID: tmdbID), !Task.isCancelled {
                    seasonPosters = posters
                }
            }
            .animation(reduceMotion ? nil : .easeInOut, value: groups.ready)
            .animation(reduceMotion ? nil : .easeInOut, value: groups.completed)
            .onChange(of: groups.completed) { previous, current in
                if let season = current.first(where: { !previous.contains($0) }) {
                    completionMessage = season == 0
                        ? String(localized: "Specials moved to completed seasons")
                        : String(localized: "Season \(season) moved to completed seasons")
                }
                if current.isEmpty { completedSeasonsExpanded = false }
            }
            .safeAreaInset(edge: .bottom) {
                if let completionMessage {
                    Text(completionMessage)
                        .font(.subheadline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
            .task(id: completionMessage) {
                guard completionMessage != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                    completionMessage = nil
                } catch { }
            }
            .confirmationDialog("Remove \(show.title) from My Shows?", isPresented: $hideConfirmation, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task {
                        await store.hide(show)
                        if !show.isFollowing { dismiss() }
                    }
                }
            }
    }
}

private struct SeasonSection: View {
    @Environment(AppStore.self) private var store
    let show: Show
    let season: Int
    let posterPath: String?
    @Binding var selectedEpisode: Episode?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var episodes: [Episode] {
        show.episodes.filter { $0.season == season }.sorted { $0.number < $1.number }
    }

    var body: some View {
        let seasonEpisodes = episodes
        Section {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        FallbackArtworkView(paths: [posterPath, show.posterPath].compactMap { $0 }, width: 44, height: 66)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(season == 0 ? "Specials" : "Season \(season)")
                                .font(.headline)
                            Text("\(seasonEpisodes.filter { $0.watchedAt != nil }.count) of \(seasonEpisodes.count) watched")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide season episodes")

                VStack(alignment: .trailing, spacing: 8) {
                    Button("Mark watched") {
                        Task { await store.markSeasonWatched(show, season: season) }
                    }
                    .disabled(seasonEpisodes.allSatisfy { $0.isScheduledInFuture || ($0.watchedAt != nil && !$0.isSkipped) })
                    Button("Skip") {
                        Task { await store.skipSeason(show, season: season) }
                    }
                    .disabled(seasonEpisodes.allSatisfy { $0.watchedAt != nil || $0.isSkipped })
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(store.busy)

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut) {
                        expanded.toggle()
                    }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse season" : "Expand season")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
            .padding(.vertical, 4)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading]
            }

            if expanded {
                ForEach(seasonEpisodes) { episode in
                    SeasonEpisodeRow(episode: episode, selectedEpisode: $selectedEpisode)
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                            dimensions[.leading]
                        }
                }
            }
        }
    }
}

private struct SeasonEpisodeRow: View {
    @Environment(AppStore.self) private var store
    let episode: Episode
    @Binding var selectedEpisode: Episode?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let show = episode.show {
                EpisodeArtworkView(show: show, episode: episode, width: 72, squareCrop: true)
            } else {
                FallbackArtworkView(paths: [], width: 72, height: 72)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    selectedEpisode = episode
                } label: {
                    HStack {
                        Text("\(episode.label) · \(episode.title)").font(.subheadline.bold())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show episode details")
                if let date = episode.firstAired {
                    Group {
                        if !AirDates.hasAired(date) {
                            Text("Airs: \(Text(date, style: .date))")
                        } else {
                            Text("Aired: \(Text(date, style: .date))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !AirDates.hasAired(date) { Text("Scheduled").font(.caption).foregroundStyle(.orange) }
                } else { Text("Air date unknown").font(.caption).foregroundStyle(.secondary) }
                if let watchedAt = episode.watchedAt {
                    if watchedAt == .distantPast {
                        Text("Watched · date unknown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Watched on \(watchedAt, format: .dateTime.day().month(.abbreviated).year())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if episode.isSkipped { Text("Skipped in WatchMate").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(episode.watchedAt == nil ? "Mark watched" : "Unwatch") {
                        Task { await store.setWatched(episode, watched: episode.watchedAt == nil) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(episode.watchedAt == nil && episode.isScheduledInFuture)
                    Button(episode.isSkipped ? "Unskip" : "Skip") { Task { await store.skip(episode) } }
                        .buttonStyle(.bordered)
                        .disabled(episode.watchedAt != nil)
                }.font(.caption).disabled(store.busy)
            }
        }.padding(.vertical, 4)
    }
}

#if DEBUG

#Preview("Programme details") {
    PreviewHost { data in
        NavigationStack { ShowDetailView(show: data.show) }
    }
}

#Preview("Season") {
    PreviewHost { data in
        List { SeasonSection(show: data.show, season: 1, posterPath: data.show.posterPath, selectedEpisode: .constant(nil)) }
    }
}

#Preview("Season episode") {
    PreviewHost { data in
        List { SeasonEpisodeRow(episode: data.episode, selectedEpisode: .constant(nil)) }
    }
}
#endif
