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
        for id in deleted { recordData.removeValue(forKey: id.recordName) }
        for record in records where record.recordType.hasPrefix("Household") {
            recordData[record.recordID.recordName] = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        }
        tokenData = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    func list() throws -> HouseholdList? {
        var records: [String: CKRecord] = [:]
        for (key, data) in recordData {
            guard let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else {
                throw APIError.message("The saved shared list could not be read.")
            }
            records[key] = record
        }
        guard let header = records.values.first(where: { $0.recordType == "HouseholdList" }),
              let name = header["name"] as? String else { return nil }
        let programmes = try records.values.filter { $0.recordType == "HouseholdShow" && ($0["removed"] as? Int ?? 0) == 0 }.map { record -> SharedProgramme in
            guard let data = record["payload"] as? Data else { throw APIError.message("A shared programme could not be read.") }
            let programme = try JSONDecoder().decode(SharedProgramme.self, from: data)
            var episodes = Dictionary(programme.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var skipped = programme.skippedEpisodeIDs ?? []
            for event in records.values where event.recordType == "HouseholdEpisode" && event["showID"] as? Int == programme.id && event["revision"] as? String == programme.revision {
                guard let id = event["episodeID"] as? Int else { continue }
                if let date = event["watchedAt"] as? Date,
                   let season = event["season"] as? Int, let number = event["number"] as? Int {
                    episodes[id] = SharedEpisode(id: id, season: season, number: number, watchedAt: date)
                } else { episodes.removeValue(forKey: id) }
                if episodes[id] == nil && (event["skipped"] as? Int) == 1 { skipped.insert(id) }
                else { skipped.remove(id) }
            }
            return SharedProgramme(show: programme.show, addedBy: programme.addedBy,
                                   episodes: episodes.values.sorted { ($0.season, $0.number) < ($1.season, $1.number) }, skippedEpisodeIDs: skipped, revision: programme.revision)
        }
        return HouseholdList(zoneID: zoneID, name: name, shared: shared,
                                 programmes: programmes.sorted { $0.show.title < $1.show.title },
                                 photoData: header["photoData"] as? Data)
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
