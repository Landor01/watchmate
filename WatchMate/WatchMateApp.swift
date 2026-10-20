import SwiftUI
import SwiftData

@main
struct WatchMateApp: App {
    @UIApplicationDelegateAdaptor(SharingAppDelegate.self) private var sharingDelegate
    private let container: ModelContainer
    @State private var store: AppStore
    @State private var tips = TipStore()
    init() {
        do {
            let services = try AppServices.shared()
            self.container = services.container
            let store = services.store
            store.publishStartupWidgetSnapshot()
            // Preserve the startup experience for people already using the app.
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
               !UserDefaults.standard.bool(forKey: "onboardingStarted"),
               (store.connected && !store.settings.demoMode) || ((try? store.hasShows()) == true) {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            }
            _store = State(initialValue: store)
        } catch { fatalError("WatchMate could not open its local database: \(error)") }
    }
    var body: some Scene {
        WindowGroup {
            AppEntryView().environment(store).modelContainer(container)
                .modifier(AppAppearanceModifier())
                .environment(tips)
                .task { await tips.finishUnfinishedTransactions() }
                .onOpenURL { url in
                    if let link = WidgetEpisodeLink(url: url) {
                        store.widgetEpisodeLink = link
                    }
                }
        }
    }
}
