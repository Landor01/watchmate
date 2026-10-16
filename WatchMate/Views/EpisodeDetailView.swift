import SwiftUI

struct EpisodeDetailView: View {
    let episode: Episode

    var body: some View {
        ThemedList {
            EpisodeSummarySection(episode: episode)
            Section("Synopsis") {
                if episode.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No synopsis is available for this episode yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(episode.overview)
                }
            }
            EpisodeViewingSection(episode: episode)
        }
        .navigationTitle(episode.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EpisodeSummarySection: View {
    let episode: Episode

    var body: some View {
        Section {
            if let show = episode.show {
                HStack(alignment: .top, spacing: 16) {
                    EpisodeArtworkView(show: show, episode: episode, width: 120, adaptsToImage: true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(show.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(episode.title).font(.title2.bold())
                        Text("Season \(episode.season) · Episode \(episode.number)")
                            .font(.subheadline)
                    }
                }
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading]
                }
            } else {
                Text(episode.title).font(.title2.bold())
            }
            if let date = episode.firstAired {
                LabeledContent(date > Date() ? "Scheduled air date" : "First aired") {
                    Text(date, format: .dateTime.day().month(.wide).year())
                }
            } else {
                LabeledContent("First aired", value: "Unknown")
            }
            if let runtime = episode.runtime, runtime > 0 {
                LabeledContent("Runtime") {
                    Text("\(runtime) minutes")
                }
            }
        }
    }
}

private struct EpisodeViewingSection: View {
    @Environment(AppStore.self) private var store
    let episode: Episode

    var body: some View {
        Section("Watch status") {
            HStack(spacing: 8) {
                if let watchedAt = episode.watchedAt {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Watched")
                    if watchedAt != .distantPast {
                        Text(watchedAt, format: .dateTime.day().month(.abbreviated).year())
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Watched on \(watchedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                } else if episode.isSkipped {
                    Image(systemName: "forward.end.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Skipped")
                } else {
                    Label("Unwatched", systemImage: "circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(episode.watchedAt == nil ? "Mark watched" : "Unwatch") {
                    Task { await store.setWatched(episode, watched: episode.watchedAt == nil) }
                }
                .disabled(episode.watchedAt == nil && episode.isScheduledInFuture)
                Button(episode.isSkipped ? "Unskip" : "Skip") {
                    Task { await store.skip(episode) }
                }
                .disabled(episode.watchedAt != nil)
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled(store.busy)
        }
    }
}
