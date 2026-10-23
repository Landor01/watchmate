import SwiftUI

/// Display values only; each caller retains its own source of watch progress.
struct EpisodeDetails {
    let title: String
    let showTitle: String?
    let season: Int
    let number: Int
    let firstAired: Date?
    let runtime: Int?
    let overview: String
    let episodeIMDbURL: URL?
    let showIMDbURL: URL?

    init(episode: Episode) {
        title = episode.title
        showTitle = episode.show?.title
        season = episode.season
        number = episode.number
        firstAired = episode.firstAired
        runtime = episode.runtime
        overview = episode.overview
        episodeIMDbURL = episode.imdbURL
        showIMDbURL = episode.show?.imdbURL
    }

    init(episode: RemoteEpisode, showTitle: String?, showIMDbURL: URL?) {
        title = episode.title ?? String(localized: "Episode")
        self.showTitle = showTitle
        season = episode.season
        number = episode.number
        firstAired = Dates.parse(episode.firstAired)
        runtime = episode.runtime
        overview = episode.overview ?? ""
        episodeIMDbURL = episode.ids.imdbURL
        self.showIMDbURL = showIMDbURL
    }
}

/// One layout for personal and shared episodes, with source-specific content.
struct EpisodeDetailsScreen<Artwork: View, Streaming: View, Watching: View>: View {
    let details: EpisodeDetails
    let navigationTitle: String
    @ViewBuilder let artwork: Artwork
    @ViewBuilder let streaming: Streaming
    @ViewBuilder let watching: Watching

    var body: some View {
        ThemedList {
            EpisodeSummarySection(details: details) { artwork }
            EpisodeSynopsisSection(overview: details.overview)
            streaming
            watching
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EpisodeSynopsisSection: View {
    let overview: String

    var body: some View {
        Section("Synopsis") {
            if overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No synopsis is available for this episode yet.")
                    .foregroundStyle(.secondary)
            } else {
                Text(overview)
            }
        }
    }
}

struct EpisodeDetailView: View {
    let episode: Episode

    var body: some View {
        EpisodeDetailsScreen(details: EpisodeDetails(episode: episode), navigationTitle: episode.label) {
            if let show = episode.show {
                EpisodeArtworkView(show: show, episode: episode, width: 120, adaptsToImage: true)
            }
        } streaming: {
            EpisodeStreamingSection(show: episode.show)
        } watching: {
            EpisodeViewingSection(episode: episode)
        }
    }
}

struct EpisodeSummarySection<Artwork: View>: View {
    let details: EpisodeDetails
    @ViewBuilder let artwork: Artwork

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                artwork
                VStack(alignment: .leading, spacing: 8) {
                    if let showTitle = details.showTitle {
                        Text(showTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(details.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Season \(details.season) · Episode \(details.number)")
                        .font(.subheadline)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            if let date = details.firstAired {
                LabeledContent(!AirDates.hasAired(date) ? "Scheduled air date" : "First aired") {
                    Text(date, format: .dateTime.day().month(.wide).year())
                }
            } else {
                LabeledContent("First aired", value: "Unknown")
            }
            if let runtime = details.runtime, runtime > 0 {
                LabeledContent("Runtime") {
                    Text("\(runtime) minutes")
                }
            }
            if let imdbURL = details.episodeIMDbURL ?? details.showIMDbURL {
                Link(destination: imdbURL) {
                    Label(details.episodeIMDbURL != nil ? "View episode on IMDb" : "View show on IMDb", systemImage: "arrow.up.right.square")
                }
            }
        }
    }
}

private struct EpisodeStreamingSection: View {
    @Environment(AppStore.self) private var store
    let show: Show?

    var body: some View {
        Section {
            if let show, show.providerRegion == store.settings.region {
                if show.providers.isEmpty {
                    Text("Streaming availability unknown")
                        .foregroundStyle(.secondary)
                } else {
                    ProviderNamesView(providers: show.providers)
                }
            } else {
                Text("Streaming availability unknown")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Where to watch")
        } footer: {
            Text("Streaming availability powered by JustWatch. Listings are for the series, not individual episodes.")
        }
    }
}

private struct EpisodeViewingSection: View {
    @Environment(AppStore.self) private var store
    let episode: Episode

    var body: some View {
        EpisodeWatchSection(
            watchedAt: episode.watchedAt, isSkipped: episode.isSkipped,
            isFuture: episode.isScheduledInFuture, isShared: false,
            isDisabled: store.busy, isUpdating: false,
            toggleWatched: {
                Task { await store.setWatched(episode, watched: episode.watchedAt == nil) }
            },
            toggleSkipped: {
                Task { await store.skip(episode) }
            }
        )
    }
}

struct EpisodeWatchSection: View {
    let watchedAt: Date?
    let isSkipped: Bool
    let isFuture: Bool
    let isShared: Bool
    let isDisabled: Bool
    let isUpdating: Bool
    let toggleWatched: () -> Void
    let toggleSkipped: () -> Void

    var body: some View {
        Section("Watch status") {
            HStack(spacing: 8) {
                if let watchedAt {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(isShared ? Text("Watched together") : Text("Watched"))
                    if watchedAt != .distantPast {
                        Text(watchedAt, format: .dateTime.day().month(.abbreviated).year())
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(isShared
                                ? Text("Watched together on \(watchedAt.formatted(date: .abbreviated, time: .omitted))")
                                : Text("Watched on \(watchedAt.formatted(date: .abbreviated, time: .omitted))"))
                    }
                } else if isSkipped {
                    Image(systemName: "forward.end.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isShared ? Text("Skipped in this shared list") : Text("Skipped"))
                } else {
                    Label("Unwatched", systemImage: "circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(watchedAt == nil ? "Mark watched" : "Unwatch", action: toggleWatched)
                    .disabled(watchedAt == nil && isFuture)
                Button(isSkipped ? "Unskip" : "Skip", action: toggleSkipped)
                    .disabled(watchedAt != nil)
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled(isDisabled)
            if isUpdating {
                ProgressView("Updating shared progress…")
            }
        }
    }
}

#if DEBUG

#Preview("Episode details") {
    PreviewHost { data in
        NavigationStack { EpisodeDetailView(episode: data.episode) }
    }
}

#Preview("Episode summary") {
    PreviewHost { data in
        List {
            EpisodeSummarySection(details: EpisodeDetails(episode: data.episode)) {
                EpisodeArtworkView(show: data.show, episode: data.episode, width: 120, adaptsToImage: true)
            }
        }
    }
}

#Preview("Streaming") {
    PreviewHost { data in
        List { EpisodeStreamingSection(show: data.show) }
    }
}

#Preview("Viewing progress") {
    PreviewHost { data in
        List { EpisodeViewingSection(episode: data.episode) }
    }
}
#endif
