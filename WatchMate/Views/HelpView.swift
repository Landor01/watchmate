import SwiftUI

struct HelpView: View {
    var body: some View {
        ThemedList {
            HelpGettingStartedSection()
            HelpShowsSection()
            HelpProgressSection()
            HelpWidgetsSection()
            HelpSettingsSection()
            HelpTroubleshootingSection()
        }
        .navigationTitle("Help")
        .toolbarTitleDisplayMode(.inline)
    }
}

private struct HelpGettingStartedSection: View {
    var body: some View {
        Section("Getting Started") {
            HelpRow(icon: "person.crop.circle", title: "Connect Trakt",
                    description: "Open Settings and connect your Trakt account to import your viewing history and watchlist. Watched episodes sync back to Trakt.")
            HelpRow(icon: "sparkles", title: "Try Demo Mode",
                    description: "Explore WatchMate with fictional sample programmes before connecting an account. Demo actions do not change your Trakt history.")
            HelpRow(icon: "arrow.clockwise", title: "Refresh Your Shows",
                    description: "Pull down in Up Next, Coming Soon or My Shows to refresh episode information and viewing progress. Cached information remains available between refreshes.")
        }
    }
}

private struct HelpShowsSection: View {
    var body: some View {
        Section("Finding Your Shows") {
            HelpRow(icon: "play.circle", title: "Up Next",
                    description: "See the next aired, unwatched episode of each programme you follow. Watched and skipped episodes are left out. The remaining count helps you see how much you have to catch up on.")
            HelpRow(icon: "calendar", title: "Coming Soon",
                    description: "Use the calendar and list buttons at the top left to switch displays. Select a date in the calendar, move between months or tap Today. The list shows episodes scheduled for the next 30 days.")
            HelpRow(icon: "tv", title: "My Shows",
                    description: "Browse the programmes you follow and tap one to see its seasons and episodes. Removing a show from My Shows does not delete your Trakt history or watchlist.")
            HelpRow(icon: "magnifyingglass", title: "Add a Programme",
                    description: "Tap + in My Shows and search by title. Tap a result to explore its details, or tap Add to follow it. Search requires a connected Trakt account.")
            Text("Air dates come from Trakt and may differ from release dates on your local streaming services.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HelpProgressSection: View {
    var body: some View {
        Section("Tracking Progress") {
            HelpRow(icon: "checkmark.circle", title: "Mark Watched",
                    description: "Mark an episode watched after you finish it. When connected, WatchMate saves this to Trakt. You can undo a watched status from the app if you make a mistake.")
            HelpRow(icon: "forward.end", title: "Skip an Episode",
                    description: "Skip an episode to leave it out of Up Next without marking it watched on Trakt. You can unskip it from the app to put it back.")
            HelpRow(icon: "rectangle.stack", title: "Catch Up on a Season",
                    description: "Open a programme to browse its seasons. Use the season actions to mark aired episodes watched or skip a whole season. Completed seasons stay tucked away until you open them.")
            HelpRow(icon: "star", title: "Include Specials",
                    description: "Turn on Include Specials in Settings if you want season-zero episodes included in Up Next, Coming Soon and the Next Episode widget.")
        }
    }
}

private struct HelpWidgetsSection: View {
    var body: some View {
        Section("Widgets") {
            HelpRow(icon: "rectangle.and.hand.point.up.left", title: "Add the Next Episode Widget",
                    description: "Open WatchMate once to make your shows available. Touch and hold the Home Screen, choose Edit, then Add Widget. Search for WatchMate and add the small, medium or large Next Episode widget.")
            HelpRow(icon: "tv", title: "Choose Your Show",
                    description: "Touch and hold the widget, choose Edit Widget, then select a programme from My Shows. You can add several widgets and choose a different show for each one.")
            HelpRow(icon: "play.rectangle", title: "See What’s Next",
                    description: "The widget shows the next aired, unwatched episode with its season and episode number and title. Every size includes the aired date. Medium and large widgets add square artwork and runtime when available, using season or show artwork if an episode image is unavailable. The large widget also includes the synopsis. Tap the widget outside its buttons to open that episode in WatchMate. It uses your Include Specials preference.")
            HelpRow(icon: "checkmark.circle", title: "Mark Watched or Skip",
                    description: "Tap Mark watched or Skip directly in the widget. On the small widget, use the checkmark to mark watched and the skip icon to skip. After the change is saved, it advances to the next episode without opening the app. Mark watched needs a working Trakt connection outside demo mode. Skips sync through iCloud when available.")
            HelpRow(icon: "checkmark.seal", title: "All Caught Up",
                    description: "When no aired episodes remain, the widget shows that you’re caught up and the next known air date, if available. Open WatchMate and refresh to check for new episode information.")
            Text("The widget uses the latest information saved by WatchMate. Home Screen updates are scheduled by iOS, so changes may take a moment to appear. Undo watched or skipped episodes from the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HelpSettingsSection: View {
    var body: some View {
        Section("Make WatchMate Yours") {
            HelpRow(icon: "play.tv", title: "Streaming Services",
                    description: "Choose your region and streaming services in Settings. Enable the service filter to show programmes with confirmed availability on your selected services. Listings come from TMDB and JustWatch and apply to the whole series.")
            HelpRow(icon: "bell", title: "Air-Day Reminders",
                    description: "Enable reminders for a programme to receive notifications on scheduled air dates. Allow notifications on each device where you want reminders.")
            HelpRow(icon: "paintpalette", title: "Appearance",
                    description: "Use Settings to choose a theme and light, dark or system appearance. Add a profile photo from your photo library or camera.")
            HelpRow(icon: "icloud", title: "Sync Between Devices",
                    description: "Use the same Apple Account and Trakt account on each device. WatchMate syncs followed and hidden shows, skips, reminder choices, viewing preferences and your profile photo through private iCloud storage. Viewing history syncs through Trakt.")
        }
    }
}

private struct HelpTroubleshootingSection: View {
    var body: some View {
        Section("Troubleshooting") {
            HelpRow(icon: "line.3.horizontal.decrease.circle", title: "A Programme Is Missing",
                    description: "Check that it is in My Shows. If a service filter is enabled, try turning it off in Settings. Streaming availability may not yet be confirmed for your region.")
            HelpRow(icon: "arrow.triangle.2.circlepath", title: "An Update Didn’t Save",
                    description: "Check your internet connection and Trakt sign-in, then try again. If the app is already refreshing, wait for it to finish. The widget keeps the episode visible when a watched update fails.")
            HelpRow(icon: "rectangle", title: "The Widget Is Empty",
                    description: "Open WatchMate and check My Shows, then edit the widget to select a programme. If you removed the selected show or changed accounts, choose a show from your current library.")
        }
    }
}

private struct HelpRow: View {
    let icon: String
    let title: LocalizedStringResource
    let description: LocalizedStringResource

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 28)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        HelpView()
    }
}
