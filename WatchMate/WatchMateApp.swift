import SwiftUI
import SwiftData
import OSLog

@main
struct WatchMateApp: App {
    @UIApplicationDelegateAdaptor(SharingAppDelegate.self) private var sharingDelegate

    var body: some Scene {
        WindowGroup {
            AppStartupView()
                .modifier(AppAppearanceModifier())
        }
    }
}

private struct AppStartupView: View {
    @State private var services: AppServices?
    @State private var startupFailed = false
    @State private var tips = TipStore()
    @State private var pendingEpisodeLink: WidgetEpisodeLink?

    var body: some View {
        Group {
            if let services {
                AppEntryView()
                    .environment(services.store)
                    .modelContainer(services.container)
                    .environment(tips)
                    .task {
                        guard !AppStoreScreenshotMode.isEnabled else { return }
                        await tips.finishUnfinishedTransactions()
                    }
            } else if startupFailed {
                ContentUnavailableView {
                    Label("Couldn’t Open Your Library", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("WatchMate couldn’t open its saved data. Your data hasn’t been removed. Check your device’s available storage and try again.")
                } actions: {
                    Button("Try Again", action: loadServices)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Opening your library…")
            }
        }
        .task { loadServices() }
        .onOpenURL { url in
            guard let link = WidgetEpisodeLink(url: url) else { return }
            if let services {
                services.store.widgetEpisodeLink = link
            } else {
                pendingEpisodeLink = link
            }
        }
    }

    private func loadServices() {
        guard services == nil else { return }
        do {
            let services = try AppServices.shared()
            let store = services.store
            store.publishStartupWidgetSnapshot()
            // Preserve the startup experience for people already using the app.
            if !AppStoreScreenshotMode.isEnabled, !PreviewEnvironment.isRunning,
               !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
               !UserDefaults.standard.bool(forKey: "onboardingStarted"),
               (store.connected && !store.settings.demoMode) || ((try? store.hasShows()) == true) {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            }
            store.widgetEpisodeLink = pendingEpisodeLink
            pendingEpisodeLink = nil
            startupFailed = false
            self.services = services
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "WatchMate", category: "Startup")
                .error("Could not open local database: \(error.localizedDescription, privacy: .private)")
            startupFailed = true
        }
    }
}

#if DEBUG
#Preview("WatchMate") {
    PreviewHost { _ in
        AppEntryView()
    }
}
#endif
