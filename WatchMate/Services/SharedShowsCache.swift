import CloudKit
import CryptoKit
import Foundation

/// Persist records and their token together: a token alone would lose unchanged records after relaunch.
struct SharedZoneCache: Codable {
    let zoneName: String
    let ownerName: String
    let shared: Bool
    var recordData: [String: Data] = [:]
    var tokenData: Data?
    // Only revisions explicitly replaced or removed are safe to discard across incremental pages.
    var obsoleteEpisodeRevisions: Set<String>?

    init(zoneID: CKRecordZone.ID, shared: Bool) {
        zoneName = zoneID.zoneName
        ownerName = zoneID.ownerName
        self.shared = shared
    }

    var zoneID: CKRecordZone.ID { .init(zoneName: zoneName, ownerName: ownerName) }
    var key: String { Self.key(zoneID: zoneID, shared: shared) }

    static func key(zoneID: CKRecordZone.ID, shared: Bool) -> String {
        "\(shared):\(zoneID.ownerName)/\(zoneID.zoneName)"
    }

    func changeToken() throws -> CKServerChangeToken? {
        guard let tokenData else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData)
    }

    mutating func apply(records: [CKRecord], deleted: [CKRecord.ID], token: CKServerChangeToken?) throws {
        var obsolete = obsoleteEpisodeRevisions ?? []
        // Inspect programme changes before events; CloudKit may deliver them in either order.
        for record in records where record.recordType == "HouseholdShow" {
            let name = record.recordID.recordName
            let replacement = try programme(in: record)
            if let data = recordData[name], let old = try programme(in: decode(data)),
               old.revision != replacement?.revision {
                obsolete.insert(old.revision)
            }
            if (record["removed"] as? Int ?? 0) != 0, let replacement {
                obsolete.insert(replacement.revision)
            }
        }
        for id in deleted { recordData.removeValue(forKey: id.recordName) }
        for record in records where record.recordType.hasPrefix("Household") {
            recordData[record.recordID.recordName] = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        }
        if !obsolete.isEmpty {
            for (key, data) in recordData {
                let discard = try autoreleasepool {
                    let record = try decode(data)
                    return record.recordType == "HouseholdEpisode"
                        && (record["revision"] as? String).map { obsolete.contains($0) } == true
                }
                if discard { recordData.removeValue(forKey: key) }
            }
        }
        obsoleteEpisodeRevisions = obsolete.isEmpty ? nil : obsolete
        tokenData = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    private func decode(_ data: Data) throws -> CKRecord {
        guard let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else {
            throw APIError.message("The saved shared list could not be read.")
        }
        return record
    }

    private func programme(in record: CKRecord) throws -> SharedProgramme? {
        guard let data = record["payload"] as? Data else { return nil }
        return try JSONDecoder().decode(SharedProgramme.self, from: data)
    }

    func list() throws -> HouseholdList? {
        struct Event {
            let revision: String
            let id: Int
            let season: Int?
            let number: Int?
            let watchedAt: Date?
            let skipped: Bool
        }
        var name: String?
        var photo: Data?
        var programmes: [SharedProgramme] = []
        var events: [Int: [Event]] = [:]
        // Release each unarchived CloudKit object immediately; retain only display fields.
        for data in recordData.values {
            try autoreleasepool {
                let record = try decode(data)
                switch record.recordType {
                case "HouseholdList":
                    name = record["name"] as? String
                    photo = record["photoData"] as? Data
                case "HouseholdShow":
                    if (record["removed"] as? Int ?? 0) == 0 {
                        guard let programme = try programme(in: record) else {
                            throw APIError.message("A shared programme could not be read.")
                        }
                        programmes.append(programme)
                    }
                case "HouseholdEpisode":
                    if let showID = record["showID"] as? Int, let id = record["episodeID"] as? Int,
                       let revision = record["revision"] as? String {
                        events[showID, default: []].append(Event(revision: revision, id: id,
                            season: record["season"] as? Int, number: record["number"] as? Int,
                            watchedAt: record["watchedAt"] as? Date, skipped: (record["skipped"] as? Int) == 1))
                    }
                default: break
                }
            }
        }
        guard let name else { return nil }
        let merged = programmes.map { programme in
            var episodes = Dictionary(programme.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var skipped = programme.skippedEpisodeIDs ?? []
            for event in events[programme.id] ?? [] where event.revision == programme.revision {
                if let date = event.watchedAt, let season = event.season, let number = event.number {
                    episodes[event.id] = SharedEpisode(id: event.id, season: season, number: number, watchedAt: date)
                } else { episodes.removeValue(forKey: event.id) }
                if episodes[event.id] == nil && event.skipped { skipped.insert(event.id) }
                else { skipped.remove(event.id) }
            }
            return SharedProgramme(show: programme.show, addedBy: programme.addedBy,
                episodes: episodes.values.sorted { ($0.season, $0.number) < ($1.season, $1.number) },
                skippedEpisodeIDs: skipped, notes: programme.notes, revision: programme.revision)
        }
        return HouseholdList(zoneID: zoneID, name: name, shared: shared,
                             programmes: merged.sorted { $0.show.title < $1.show.title }, photoData: photo)
    }

}

struct SharedShowsCache: Codable {
    let ownerID: String
    var zones: [String: SharedZoneCache] = [:]

    mutating func retainZones(_ ids: Set<CKRecordZone.ID>, shared: Bool) {
        zones = zones.filter { $0.value.shared != shared || ids.contains($0.value.zoneID) }
    }

    func lists() throws -> [HouseholdList] {
        try zones.values.compactMap { try $0.list() }.sorted { $0.name < $1.name }
    }

    static func url(accountID: String) -> URL {
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory.appending(path: "SharedShowsCache", directoryHint: .isDirectory)
            .appending(path: key + ".json")
    }

    static func readForLaunch(accountID: String) -> SharedShowsCache? {
        guard let data = try? Data(contentsOf: url(accountID: accountID)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func read(accountID: String, ownerID: String) throws -> SharedShowsCache {
        let url = url(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return SharedShowsCache(ownerID: ownerID) }
        let cache = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        // Never display data saved by a different Apple account.
        return cache.ownerID == ownerID ? cache : SharedShowsCache(ownerID: ownerID)
    }

    func save(accountID: String) throws {
        let url = Self.url(accountID: accountID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum SharedRefreshPolicy {
    static func needsRefresh(automatic: Bool, lastSuccess: Date?, now: Date = Date()) -> Bool {
        guard automatic, let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= 60
    }
}
