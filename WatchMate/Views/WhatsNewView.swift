import SwiftUI

struct WhatsNewView: View {
    struct Item: Identifiable {
        let id: String
        let systemImage: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
    }

    // Launch highlights. Give each feature a unique, stable ID when updating future releases.
    static let defaultItems: [Item] = [
        Item(
            id: "shared-shows",
            systemImage: "person.2",
            title: "Watch together with Shared Shows",
            detail: "Create separate lists for different people, invite them through iCloud, and add programmes by searching or moving them from My Shows. Everyone can keep their own Trakt account while tracking episodes and seasons together."
        ),
        Item(
            id: "shared-progress",
            systemImage: "person.2.badge.gearshape",
            title: "Shared progress, your choice",
            detail: "See episodes watched together, time watched and time left. Mark or skip episodes and whole seasons together. Watched changes also update your own Trakt history when Shared shows update Trakt history is on in Settings. Replacing your complete history with a shared list’s progress requires a separate review and confirmation."
        ),
        Item(
            id: "next-episode-widget",
            systemImage: "rectangle.and.hand.point.up.left",
            title: "Your next episode, on your Home Screen",
            detail: "Add the Next Episode widget and choose a programme from My Shows. See artwork and details for the next aired episode to watch, then mark it watched or skip it without opening WatchMate. Available in small, medium and large sizes."
        ),
        Item(
            id: "up-next",
            systemImage: "play.circle.fill",
            title: "Pick up where you left off",
            detail: "Up Next brings together the next aired episode of each show you follow, with counts to help you see how much you have left to watch."
        ),
        Item(
            id: "coming-soon",
            systemImage: "calendar",
            title: "See what’s coming soon",
            detail: "Browse scheduled episodes in a monthly calendar or see the next 30 days in a list. Air dates come from Trakt and may differ from local streaming releases."
        ),
        Item(
            id: "my-shows",
            systemImage: "tv",
            title: "All your shows in one place",
            detail: "Build your collection in My Shows. Add programmes you want to follow and remove ones you no longer need without deleting your Trakt history or watchlist."
        ),
        Item(
            id: "discovery",
            systemImage: "magnifyingglass",
            title: "Find your next watch",
            detail: "Connect Trakt, then use + in My Shows to search for programmes. Explore artwork, synopses and streaming information before adding a show."
        ),
        Item(
            id: "episode-details",
            systemImage: "rectangle.stack",
            title: "Explore every season",
            detail: "Browse seasons and open individual episodes for artwork, synopses and air dates. Completed seasons stay tucked away until you want to revisit them."
        ),
        Item(
            id: "watch-progress",
            systemImage: "checkmark.circle",
            title: "Track watching your way",
            detail: "Mark episodes watched, undo a watched status, or skip and unskip episodes. Mark or skip a whole season to catch up quickly, and choose whether to include specials in Settings."
        ),
        Item(
            id: "streaming-services",
            systemImage: "play.rectangle",
            title: "Find where to watch",
            detail: "See streaming services for your selected region and follow links to check where a series is available. Listings are powered by TMDB and JustWatch and apply to the series, not individual episodes."
        ),
        Item(
            id: "service-filters",
            systemImage: "line.3.horizontal.decrease.circle",
            title: "Highlight your services",
            detail: "Choose your streaming services in Settings and enable Highlight available services to see them in the highlight colour. All other services remain visible so you can discover more places to watch."
        ),
        Item(
            id: "reminders",
            systemImage: "bell.badge",
            title: "Get a nudge on air day",
            detail: "Turn on reminders for individual shows to receive notifications on scheduled air dates. Enable notifications on each device where you want reminders."
        ),
        Item(
            id: "trakt-sync",
            systemImage: "arrow.triangle.2.circlepath",
            title: "Bring your Trakt history along",
            detail: "Connect your Trakt account to import your viewing history and watchlist, and sync watched episodes back to Trakt. Pull to refresh to update your shows."
        ),
        Item(
            id: "icloud-sync",
            systemImage: "icloud",
            title: "Keep your devices in step",
            detail: "Your followed and hidden shows, skips, reminder choices, viewing preferences and profile photo sync through private iCloud storage. Use the same Apple Account and Trakt account on each device."
        ),
        Item(
            id: "appearance",
            systemImage: "paintpalette",
            title: "Make WatchMate yours",
            detail: "Choose System, Ocean, Forest, Sunset or Lavender themes and your preferred light or dark appearance. Add a profile photo from your library or take a new one."
        ),
        Item(
            id: "demo-guidance",
            systemImage: "sparkles",
            title: "Explore before signing in",
            detail: "Try WatchMate with real programme artwork and sample viewing progress in demo mode, then connect Trakt in Settings when you’re ready to bring in your own shows and viewing history."
        ),
        Item(
            id: "privacy",
            systemImage: "hand.raised",
            title: "Enjoy a quieter app",
            detail: "WatchMate has no advertising or analytics and no app backend. Viewing data is cached on your device, with watched history synced through Trakt and preferences through private iCloud storage."
        )
    ]

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let currentVersionDisplay: String = {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { return currentVersion }
        return "\(currentVersion) (\(build))"
    }()

    @AppStorage("appTheme") private var themeValue = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    let version: String
    var items: [Item] = Self.defaultItems
    var navigationTitle: LocalizedStringResource = "What’s New"
    var introduction: LocalizedStringResource = "Welcome to WatchMate! Your new home for the shows you love, the episodes you’re watching and what’s coming next."
    var footerText: LocalizedStringResource = "Thanks for using WatchMate!"
    var dismissButtonTitle: LocalizedStringResource = "Continue"
    let onDismiss: () -> Void

    var body: some View {
        let theme = AppTheme(rawValue: themeValue) ?? .system
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WhatsNewHeader(version: version, introduction: introduction)
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(items) { item in
                            WhatsNewFeatureRow(item: item)
                        }
                    }
                    Divider()
                    Text(footerText)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(theme.backgroundColor(for: colorScheme))
            .navigationTitle(Text(navigationTitle))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDismiss) {
                        Text(dismissButtonTitle)
                    }
                }
            }
        }
    }
}

private struct WhatsNewHeader: View {
    let version: String
    let introduction: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(introduction)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            Text("What’s New in \(version)")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct WhatsNewFeatureRow: View {
    let item: WhatsNewView.Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Current release") {
    WhatsNewView(version: "1.1", onDismiss: {})
}

#Preview("Custom release") {
    WhatsNewView(
        version: "2.0",
        items: [
            .init(
                id: "example",
                systemImage: "sparkles",
                title: "Your feature title",
                detail: "Describe the new feature here."
            )
        ],
        introduction: "Customise this introduction for your next release.",
        footerText: "Enjoy the update!",
        dismissButtonTitle: "Done",
        onDismiss: {}
    )
}

#Preview("Large text") {
    WhatsNewView(version: "1.1", onDismiss: {})
        .environment(\.dynamicTypeSize, .accessibility3)
}

#if DEBUG

#Preview("Release header") {
    PreviewHost { data in
        WhatsNewHeader(version: "1.0", introduction: "Welcome to WatchMate").padding()
    }
}

#Preview("Feature row") {
    PreviewHost { data in
        if let item = WhatsNewView.defaultItems.first { WhatsNewFeatureRow(item: item).padding() }
    }
}
#endif
