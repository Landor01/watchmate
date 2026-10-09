import Foundation
import Observation

@MainActor @Observable
final class Settings {
    var region: String { didSet { UserDefaults.standard.set(region, forKey: "region") } }
    var includeSpecials: Bool { didSet { UserDefaults.standard.set(includeSpecials, forKey: "specials") } }
    var selectedProviders: Set<Int> { didSet { UserDefaults.standard.set(Array(selectedProviders), forKey: "providers") } }
    var demoMode: Bool { didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode") } }
    var hiddenShowIDs: Set<Int> { didSet { UserDefaults.standard.set(Array(hiddenShowIDs), forKey: "hidden") } }
    var lastSync: Date? { didSet { UserDefaults.standard.set(lastSync, forKey: "lastSync") } }
    init() {
        let defaults = UserDefaults.standard
        region = defaults.string(forKey: "region") ?? "GB"
        includeSpecials = defaults.bool(forKey: "specials")
        selectedProviders = Set(defaults.array(forKey: "providers") as? [Int] ?? [])
        demoMode = defaults.object(forKey: "demoMode") as? Bool ?? true
        hiddenShowIDs = Set(defaults.array(forKey: "hidden") as? [Int] ?? [])
        lastSync = defaults.object(forKey: "lastSync") as? Date
    }
}

enum Configuration {
    static var callbackHost: String { Bundle.main.object(forInfoDictionaryKey: "OAuthHost") as? String ?? "example.invalid" }
    static var callbackPath: String { "/oauth/trakt" }
    static var redirectURI: String { "https://\(callbackHost)\(callbackPath)" }
    static var callbackConfigured: Bool { !callbackHost.isEmpty && callbackHost != "example.invalid" && !callbackHost.contains("$") }
}
