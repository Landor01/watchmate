import SwiftUI
import SwiftData

@main
struct WatchMateApp: App {
    private let container: ModelContainer
    @State private var store: AppStore
    init() {
        do {
            let container = try ModelContainer(for: Show.self, Episode.self)
            self.container = container
            _store = State(initialValue: AppStore(context: container.mainContext, settings: Settings()))
        } catch { fatalError("WatchMate could not open its local database: \(error)") }
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).modelContainer(container).tint(.mint)
                .task { await store.start() }
        }
    }
}
