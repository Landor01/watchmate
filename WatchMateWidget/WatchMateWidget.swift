import WidgetKit
import AppIntents
import UIKit
import SwiftUI

struct NextEpisodeEntry: TimelineEntry {
    let date: Date
    let accountScope: String
    let show: WidgetShow?
    let needsSelection: Bool
    var errorMessage: String? = nil
    var artwork: UIImage? = nil

    static let preview = NextEpisodeEntry(
        date: .now, accountScope: "demo",
        show: WidgetShow(id: -1, title: "Harbour Lights", episodes: [
            WidgetEpisode(id: "-1:1:4", season: 1, number: 4, title: "The Long Way Home",
                          overview: "An unexpected visitor brings news that changes everything.",
                          firstAired: Date().addingTimeInterval(-86_400), runtime: 45)
        ]), needsSelection: false
    )
}

struct NextEpisodeProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NextEpisodeEntry { .preview }

    func snapshot(for configuration: NextEpisodeConfiguration, in context: Context) async -> NextEpisodeEntry {
        if context.isPreview { return .preview }
        return await entry(for: configuration, at: .now)
    }

    func timeline(for configuration: NextEpisodeConfiguration, in context: Context) async -> Timeline<NextEpisodeEntry> {
        let now = Date()
        let current = await entry(for: configuration, at: now)
        var entries = [current]
        let refresh = now.addingTimeInterval(3_600)
        // Make newly aired episodes actionable at their air time without waiting for an app launch.
        if let airDate = current.show?.nextAirDate(after: now), airDate < refresh {
            entries.append(await entry(for: configuration, at: airDate))
        }
        return Timeline(entries: entries, policy: .after(refresh))
    }

    private func entry(for configuration: NextEpisodeConfiguration, at date: Date) async -> NextEpisodeEntry {
        do {
            let library = try WidgetSnapshotStore.read()
            let show = library.shows.first { $0.id == configuration.show?.id }
            return NextEpisodeEntry(
                date: date, accountScope: library.accountScope, show: show,
                needsSelection: configuration.show == nil,
                errorMessage: library.errorShowID == show?.id ? library.errorMessage : nil,
                artwork: await WidgetArtworkLoader.shared.image(for: show, at: date)
            )
        } catch {
            return NextEpisodeEntry(date: date, accountScope: "", show: nil, needsSelection: false,
                                    errorMessage: "Open WatchMate to refresh your shows.")
        }
    }
}

struct WatchMateWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextEpisodeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 4) {
            if let show = entry.show {
                HStack {
                    Text(show.title)
                        .font(family == .systemSmall ? .subheadline.bold() : .headline)
                        .lineLimit(family == .systemSmall ? nil : 1)
                        .fixedSize(horizontal: false, vertical: family == .systemSmall)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    if family != .systemSmall {
                        Image(systemName: "tv")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                if let episode = show.nextEpisode(at: entry.date) {
                    if family == .systemSmall {
                        SmallWidgetEpisodeDetails(episode: episode)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            if let artwork = entry.artwork {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: family == .systemLarge ? 116 : 64, height: family == .systemLarge ? 116 : 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .accessibilityHidden(true)
                            }
                            WidgetEpisodeDetails(episode: episode, expanded: family == .systemLarge)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                    if let message = entry.errorMessage {
                        Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    WidgetEpisodeActions(showID: show.id, episodeKey: episode.id, accountScope: entry.accountScope, compact: family == .systemSmall)
                } else {
                    Spacer(minLength: 0)
                    Label("You’re all caught up", systemImage: "checkmark.circle")
                        .font(.headline)
                    if let airDate = show.nextAirDate(after: entry.date) {
                        Text("Next episode airs \(airDate, format: .dateTime.day().month().hour().minute())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No unwatched aired episodes. Open WatchMate to refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Label("Next Episode", systemImage: "play.rectangle")
                    .font(family == .systemSmall ? .subheadline.bold() : .headline)
                Spacer(minLength: 0)
                Text(entry.needsSelection ? "Choose your show" : "Show unavailable")
                    .font(family == .systemSmall ? .subheadline.bold() : .headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.errorMessage ?? (entry.needsSelection
                    ? "Edit this widget to choose a programme from My Shows."
                    : "Open WatchMate or edit this widget to choose another show."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .dynamicTypeSize(.large)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(entry.show?.nextEpisode(at: entry.date).flatMap {
            WidgetEpisodeLink(episodeKey: $0.id, accountScope: entry.accountScope).url
        })
    }
}

private struct SmallWidgetEpisodeDetails: View {
    let episode: WidgetEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("S\(episode.season) E\(episode.number)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(episode.title)
                .font(.caption.bold())
                .lineLimit(1)
            Text("Aired: \(episode.firstAired, format: .dateTime.day().month(.abbreviated).year())")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WidgetEpisodeDetails: View {
    let episode: WidgetEpisode
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("S\(episode.season) E\(episode.number)")
                if let runtime = episode.runtime {
                    Text("· \(runtime) min")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(episode.title)
                .font(expanded ? .title3.bold() : .subheadline.bold())
                .lineLimit(2)
            if expanded {
                Text(episode.overview.isEmpty ? "No synopsis available." : episode.overview)
                    .font(.body)
                    .lineLimit(5)
            }
            Text("Aired: \(episode.firstAired, format: .dateTime.day().month(.abbreviated).year())")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WidgetEpisodeActions: View {
    let showID: Int
    let episodeKey: String
    let accountScope: String
    var compact = false

    var body: some View {
        HStack {
            Toggle(isOn: false, intent: MarkWidgetEpisodeWatched(showID: showID, episodeKey: episodeKey, accountScope: accountScope)) {
                if compact {
                    Image(systemName: "checkmark")
                        .frame(minWidth: 28, minHeight: 28)
                        .accessibilityLabel("Mark watched")
                } else {
                    Label("Mark watched", systemImage: "checkmark")
                }
            }
            .toggleStyle(WidgetPendingActionStyle(message: compact ? "Saving…" : "Marking watched…"))
            .buttonStyle(.borderedProminent)

            Toggle(isOn: false, intent: SkipWidgetEpisode(showID: showID, episodeKey: episodeKey, accountScope: accountScope)) {
                if compact {
                    Image(systemName: "forward.end")
                        .frame(minWidth: 28, minHeight: 28)
                        .accessibilityLabel("Skip")
                } else {
                    Label("Skip", systemImage: "forward.end")
                }
            }
            .toggleStyle(WidgetPendingActionStyle(message: "Skipping…"))
            .buttonStyle(.bordered)
        }
        .font(.caption)
        .disabled(accountScope.isEmpty)
    }
}

private struct WidgetPendingActionStyle: ToggleStyle {
    let message: LocalizedStringKey

    func makeBody(configuration: Configuration) -> some View {
        // WidgetKit archives both toggle appearances and switches immediately on tap.
        // The next timeline resets the control after the intent succeeds or fails.
        Button {
            configuration.isOn = true
        } label: {
            if configuration.isOn {
                Text(message)
                    .frame(minHeight: 28)
            } else {
                configuration.label
            }
        }
        .disabled(configuration.isOn)
    }
}

struct WatchMateWidget: Widget {
    let kind = WidgetSnapshotStore.kind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: NextEpisodeConfiguration.self, provider: NextEpisodeProvider()) { entry in
            WatchMateWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next Episode")
        .description("Choose a show and mark or skip its next episode without opening WatchMate.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) {
    WatchMateWidget()
} timeline: {
    NextEpisodeEntry.preview
}

#Preview(as: .systemLarge) {
    WatchMateWidget()
} timeline: {
    NextEpisodeEntry.preview
}

#Preview(as: .systemSmall) {
    WatchMateWidget()
} timeline: {
    NextEpisodeEntry.preview
}

#Preview("Compact episode details") {
    if let episode = NextEpisodeEntry.preview.show?.episodes.first {
        SmallWidgetEpisodeDetails(episode: episode).padding()
    }
}

#Preview("Expanded episode details") {
    if let episode = NextEpisodeEntry.preview.show?.episodes.first {
        WidgetEpisodeDetails(episode: episode, expanded: true).padding()
    }
}

#Preview("Episode actions") {
    WidgetEpisodeActions(showID: -1, episodeKey: "-1:1:4", accountScope: "preview").padding()
}
