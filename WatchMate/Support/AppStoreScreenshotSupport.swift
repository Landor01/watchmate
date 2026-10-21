import Foundation
import SwiftData

/// Opt-in fixtures for marketing captures. Never enabled in App Store builds.
enum AppStoreScreenshotMode {
    static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--app-store-screenshots")
        #else
        false
        #endif
    }

    static var screen: String {
        guard isEnabled else { return "" }
        return ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--screenshot-screen=") }?
            .replacingOccurrences(of: "--screenshot-screen=", with: "") ?? "up-next"
    }

    static var selectedTab: Int {
        switch screen {
        case "coming-soon": 1
        case "my-shows", "show": 2
        default: 0
        }
    }

    /// Volatile overrides keep fixture preferences out of the saved user defaults.
    static func prepareDefaults() {
        guard isEnabled else { return }
        var values = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        values.merge([
            "demoMode": true, "region": "GB", "specials": false,
            "providers": [8, 337, 350], "onlyMyServices": false,
            "hidden": [Int](), "appTheme": "ocean", "appAppearance": "light",
            "comingSoonCalendar": true
        ]) { _, fixture in fixture }
        UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    }

    static var calendarDate: Date {
        (isEnabled || PreviewEnvironment.isRunning) ? DemoLibrary.calendarDate : Date()
    }

    @MainActor
    static func seed(in context: ModelContext) throws {
        try DemoLibrary.seed(in: context)
    }
}
