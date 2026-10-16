import CloudKit
import CryptoKit
import Foundation
import Observation

struct CloudValue: Codable, Equatable {
    let data: Data
    let modifiedAt: Date
    let revision: String

    func isNewer(than other: CloudValue) -> Bool {
        modifiedAt == other.modifiedAt ? revision > other.revision : modifiedAt > other.modifiedAt
    }
}

/// Each preference has its own revision, so edits to different shows/episodes merge independently.
struct CloudSyncJournal: Codable {
    var values: [String: CloudValue] = [:]
    var baseline: [String: Data] = [:]
    var pending: Set<String> = []
    var owner: String?

    mutating func capture(_ snapshot: [String: Data], initial: Bool = false) {
        for (key, data) in snapshot where baseline[key] != data {
            // First import yields to choices already in iCloud. Later explicit edits win by revision.
            if initial && values[key] != nil { continue }
            values[key] = CloudValue(data: data, modifiedAt: initial ? .distantPast : Date(),
                                     revision: UUID().uuidString)
            pending.insert(key)
        }
        baseline = snapshot
    }

    mutating func merge(_ key: String, value: CloudValue) {
        if let local = values[key], local.modifiedAt != .distantPast, local.isNewer(than: value) { return }
        values[key] = value
        pending.remove(key)
    }
}

@MainActor @Observable
final class CloudSync {
    private(set) var status = "Connect Trakt to sync with iCloud."
    private(set) var lastSync: Date?
    private(set) var syncing = false
    private(set) var accountID: String?
    private var journal = CloudSyncJournal()
    private var fileURL: URL?
    private var zoneID: CKRecordZone.ID?
    private var generation = UUID()
    private var changeToken: CKServerChangeToken?
    private var serverRecords: [String: CKRecord] = [:]
    private var zoneReady = false
    private let container = CKContainer(identifier: "iCloud.net.andrewroland.WatchMate")

    var values: [String: Data] { journal.values.mapValues(\.data) }
    var pendingCount: Int { journal.pending.count }
    func data(for key: String) -> Data? { journal.values[key]?.data }

    func activate(accountID: String) throws {
        guard self.accountID != accountID else { return }
        let identifier = Self.digest(accountID)
        let directory = URL.applicationSupportDirectory.appending(path: "CloudSync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: identifier + ".json")
        let loaded = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(CloudSyncJournal.self, from: Data(contentsOf: url))
            : CloudSyncJournal()
        generation = UUID()
        changeToken = nil
        serverRecords = [:]
        zoneReady = false
        journal = loaded
        fileURL = url
        zoneID = CKRecordZone.ID(zoneName: "Library-" + identifier, ownerName: CKCurrentUserDefaultName)
        self.accountID = accountID
        lastSync = nil
        status = "Waiting to sync with iCloud."
    }

    func deactivate() {
        generation = UUID()
        changeToken = nil
        serverRecords = [:]
        zoneReady = false
        accountID = nil
        fileURL = nil
        zoneID = nil
        journal = CloudSyncJournal()
        lastSync = nil
        status = "Connect Trakt to sync with iCloud."
    }

    func capture(_ snapshot: [String: Data], initial: Bool = false) throws {
        guard accountID != nil, snapshot != journal.baseline else { return }
        journal.capture(snapshot, initial: initial)
        try persist()
    }

    func accept(_ snapshot: [String: Data]) throws {
        guard snapshot != journal.baseline else { return }
        journal.baseline = snapshot
        try persist()
    }

    func report(_ error: Error) {
        status = "iCloud sync paused: \(error.localizedDescription)"
    }

    func synchronize() async {
        guard !syncing, let zoneID, accountID != nil else { return }
        let session = generation
        syncing = true
        status = "Syncing with iCloud…"
        defer { syncing = false }
        do {
            guard try await container.accountStatus() == .available else {
                status = "Sign into iCloud in device Settings. Changes remain saved on this device."
                return
            }
            guard session == generation else { return }
            let owner = try await container.userRecordID().recordName
            guard session == generation else { return }
            if let previous = journal.owner, previous != owner {
                status = "The iCloud account has changed. Sync is paused to keep the previous account's data private."
                return
            }
            if journal.owner != owner {
                journal.owner = owner
                try persist()
            }

            let database = container.privateCloudDatabase
            if !zoneReady {
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
                guard session == generation else { return }
                zoneReady = true
            }
            var token = changeToken
            // The first fetch restores the library; subsequent fetches request only changes.
            let previousValues = journal.values
            let previousPending = journal.pending
            repeat {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                guard session == generation else { return }
                for result in changes.modificationResultsByID.values {
                    let record = try result.get().record
                    guard let key = record["key"] as? String else { continue }
                    let value = try Self.value(from: record)
                    serverRecords[key] = record
                    journal.merge(key, value: value)
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            } while true
            if journal.values != previousValues || journal.pending != previousPending { try persist() }
            changeToken = token

            // Small batches avoid CloudKit request limits; only acknowledged revisions leave the outbox.
            let keys = journal.pending.sorted()
            for offset in stride(from: 0, to: keys.count, by: 100) {
                let batchKeys = Array(keys[offset..<min(offset + 100, keys.count)])
                var sent: [CKRecord.ID: (String, CloudValue)] = [:]
                let records = batchKeys.compactMap { key -> CKRecord? in
                    guard let value = journal.values[key] else { return nil }
                    let id = CKRecord.ID(recordName: Self.digest(key), zoneID: zoneID)
                    let record = serverRecords[key] ?? CKRecord(recordType: "WatchMatePreference", recordID: id)
                    record["key"] = key as CKRecordValue
                    record["data"] = value.data as CKRecordValue
                    record["modifiedAt"] = value.modifiedAt as CKRecordValue
                    record["revision"] = value.revision as CKRecordValue
                    sent[id] = (key, value)
                    return record
                }
                let result = try await database.modifyRecords(saving: records, deleting: [],
                                                              savePolicy: .ifServerRecordUnchanged, atomically: false)
                guard session == generation else { return }
                var failure: Error?
                for (id, outcome) in result.saveResults {
                    guard let (key, value) = sent[id] else { continue }
                    switch outcome {
                    case .success(let saved):
                        serverRecords[key] = saved
                        if journal.values[key] == value { journal.pending.remove(key) }
                    case .failure(let error):
                        if let cloudError = error as? CKError,
                           cloudError.code == .serverRecordChanged,
                           let server = cloudError.serverRecord {
                            serverRecords[key] = server
                            journal.merge(key, value: try Self.value(from: server))
                        } else {
                            failure = error
                        }
                    }
                }
                try persist()
                if let failure { throw failure }
            }
            lastSync = Date()
            status = journal.pending.isEmpty ? "Up to date with iCloud." : "Changes queued. iCloud sync will retry."
        } catch {
            guard session == generation else { return }
            if let cloudError = error as? CKError, cloudError.code == .changeTokenExpired {
                changeToken = nil
                serverRecords = [:]
            }
            report(error)
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try JSONEncoder().encode(journal).write(to: fileURL, options: .atomic)
    }

    private static func value(from record: CKRecord) throws -> CloudValue {
        guard let data = record["data"] as? Data,
              let date = record["modifiedAt"] as? Date,
              let revision = record["revision"] as? String else {
            throw APIError.message("An iCloud record could not be read. Your local changes are retained.")
        }
        return CloudValue(data: data, modifiedAt: date, revision: revision)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
