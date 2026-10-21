import Foundation
import SwiftData

/// One store per app process, shared by the UI and background widget actions.
@MainActor
final class AppServices {
    private static var instance: AppServices?
    let container: ModelContainer
    let store: AppStore

    static func shared() throws -> AppServices {
        if let instance { return instance }
        let services = try AppServices()
        instance = services
        return services
    }

    private init() throws {
        if AppStoreScreenshotMode.isEnabled || PreviewEnvironment.isRunning {
            PreviewEnvironment.prepareDefaults()
            AppStoreScreenshotMode.prepareDefaults()
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            container = try ModelContainer(for: Show.self, Episode.self, configurations: configuration)
            try AppStoreScreenshotMode.seed(in: container.mainContext)
            store = AppStore(context: container.mainContext, settings: Settings())
            return
        }
        // Keep the existing database location when adding the widget's App Group.
        let directory = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("default.store")
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        container = try ModelContainer(for: Show.self, Episode.self, configurations: configuration)
        store = AppStore(context: container.mainContext, settings: Settings())
    }
}
