import Foundation
import Observation
import UIKit
import ImageIO

@MainActor @Observable
final class Settings {
    private(set) var profileImage: UIImage? = {
        guard let url = profileImageURL else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source: source, maximumPixels: 512)
    }()

    private static var profileImageURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("profile_avatar.jpg")
    }

    // Keep the exact saved bytes so applying a remote photo does not create another revision.
    private(set) var profilePhotoData: Data? = {
        guard let url = profileImageURL else { return nil }
        return try? Data(contentsOf: url)
    }()

    func saveProfileImage(_ image: UIImage) throws {
        try applyProfilePhotoData(Self.profilePhotoData(for: image))
        onPreferencesChanged?()
    }

    func removeProfileImage() throws {
        // Persist an explicit empty value so iCloud propagates removal instead of restoring the old photo.
        try applyProfilePhotoData(Data())
        onPreferencesChanged?()
    }

    static func profilePhotoData(for image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else {
            throw APIError.message("This profile photo could not be opened.")
        }
        // A small avatar fits in the existing preference record without a new CloudKit schema.
        let scale = min(1, 512 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.8), data.count <= 512_000 else {
            throw APIError.message("Your profile photo could not be saved. Please choose another photo.")
        }
        return data
    }

    /// Decode only the pixels needed by the cropper, never the full camera original.
    static func photoForCropping(_ data: Data, maximumPixels: Int = 2048) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source: source, maximumPixels: maximumPixels)
    }

    private static func thumbnail(source: CGImageSource, maximumPixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// Camera capture already supplies a UIImage; release that original before presenting the cropper.
    static func photoForCropping(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0, longest * image.scale > 2048 else { return image }
        let scale = 2048 / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func applyProfilePhotoData(_ data: Data) throws {
        guard data != profilePhotoData else { return }
        guard let url = Self.profileImageURL else {
            throw APIError.message("Your profile photo could not be saved.")
        }
        if data.isEmpty {
            try data.write(to: url, options: .atomic)
            profilePhotoData = data
            profileImage = nil
            return
        }
        guard let image = Self.photoForCropping(data, maximumPixels: 512) else {
            throw APIError.message("Your profile photo could not be opened.")
        }
        try data.write(to: url, options: .atomic)
        profilePhotoData = data
        profileImage = image
    }

    func prepareProfilePhotoForSync() throws {
        // Migrate photos saved before iCloud photo sync to the bounded avatar format.
        if let data = profilePhotoData, let image = profileImage,
           data.count > 512_000 || max(image.size.width * image.scale, image.size.height * image.scale) > 512 {
            try applyProfilePhotoData(Self.profilePhotoData(for: image))
        }
    }

    @ObservationIgnored var onPreferencesChanged: (() -> Void)?
    var historyRevision: String? {
        didSet { UserDefaults.standard.set(historyRevision, forKey: "historyRevision") }
    }
    var traktAccountID: String? {
        didSet { UserDefaults.standard.set(traktAccountID, forKey: "traktAccountID") }
    }
    var highlightAvailableServices = UserDefaults.standard.bool(forKey: "onlyMyServices") {
        didSet { UserDefaults.standard.set(highlightAvailableServices, forKey: "onlyMyServices"); onPreferencesChanged?() }
    }
    var sharedShowsUpdateTraktHistory = UserDefaults.standard.object(forKey: "sharedShowsUpdateTraktHistory") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sharedShowsUpdateTraktHistory, forKey: "sharedShowsUpdateTraktHistory"); onPreferencesChanged?() }
    }
    var region: String { didSet { UserDefaults.standard.set(region, forKey: "region"); onPreferencesChanged?() } }
    var includeSpecials: Bool { didSet { UserDefaults.standard.set(includeSpecials, forKey: "specials"); onPreferencesChanged?() } }
    var selectedProviders: Set<Int> { didSet { UserDefaults.standard.set(Array(selectedProviders), forKey: "providers"); onPreferencesChanged?() } }
    var demoMode: Bool { didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode") } }
    var hiddenShowIDs: Set<Int> { didSet { UserDefaults.standard.set(Array(hiddenShowIDs), forKey: "hidden") } }
    var lastSync: Date? { didSet { UserDefaults.standard.set(lastSync, forKey: "lastSync") } }
    init() {
        let defaults = UserDefaults.standard
        traktAccountID = defaults.string(forKey: "traktAccountID")
        historyRevision = defaults.string(forKey: "historyRevision")
        region = defaults.string(forKey: "region") ?? "GB"
        includeSpecials = defaults.bool(forKey: "specials")
        selectedProviders = Set(defaults.array(forKey: "providers") as? [Int] ?? [])
        demoMode = defaults.object(forKey: "demoMode") as? Bool ?? true
        hiddenShowIDs = Set(defaults.array(forKey: "hidden") as? [Int] ?? [])
        lastSync = defaults.object(forKey: "lastSync") as? Date
    }
}

enum Configuration {
    static var traktClientID: String { bundledValue("TraktClientID") }
    static var tmdbReadAccessToken: String { bundledValue("TMDBReadAccessToken") }

    // Ignore unresolved build settings so incomplete development builds fail cleanly.
    private static func bundledValue(_ key: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("$(") ? "" : value
    }

    static var callbackHost: String { Bundle.main.object(forInfoDictionaryKey: "OAuthHost") as? String ?? "example.invalid" }
    static var callbackPath: String { "/oauth/trakt" }
    static var redirectURI: String { "https://\(callbackHost)\(callbackPath)" }
    static var callbackConfigured: Bool { !callbackHost.isEmpty && callbackHost != "example.invalid" && !callbackHost.contains("$") }
}
