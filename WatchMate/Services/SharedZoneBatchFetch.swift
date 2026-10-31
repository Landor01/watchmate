import CloudKit
import Foundation

/// Collect callbacks off the main actor. CloudKit serializes these callbacks;
/// the lock also makes the handoff to the awaiting task explicit.
nonisolated final class SharedZoneFetchResults: @unchecked Sendable {
    struct Changes {
        var records: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var token: CKServerChangeToken?
        var error: (any Error)?
        var complete = false
    }

    private let lock = NSLock()
    private var zones: [CKRecordZone.ID: Changes] = [:]

    func record(_ id: CKRecord.ID, result: Result<CKRecord, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let record):
            zones[id.zoneID, default: Changes()].records.removeAll { $0.recordID == id }
            zones[id.zoneID, default: Changes()].deleted.removeAll { $0 == id }
            zones[id.zoneID, default: Changes()].records.append(record)
        case .failure(let error): zones[id.zoneID, default: Changes()].error = error
        }
    }

    func deleted(_ id: CKRecord.ID) {
        lock.lock()
        defer { lock.unlock() }
        zones[id.zoneID, default: Changes()].records.removeAll { $0.recordID == id }
        zones[id.zoneID, default: Changes()].deleted.append(id)
    }

    func finish(_ id: CKRecordZone.ID, token: CKServerChangeToken?, moreComing: Bool, error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        zones[id, default: Changes()].token = token
        zones[id, default: Changes()].complete = !moreComing && error == nil
        if let error { zones[id, default: Changes()].error = error }
    }

    func snapshot() -> [CKRecordZone.ID: Changes] {
        lock.lock()
        defer { lock.unlock() }
        return zones
    }
}

@MainActor
enum SharedZoneBatchFetch {
    static func fetch(_ previous: [SharedZoneCache], database: CKDatabase) async -> [CKRecordZone.ID: Result<SharedZoneCache, any Error>] {
        var results: [CKRecordZone.ID: Result<SharedZoneCache, any Error>] = [:]
        for offset in stride(from: 0, to: previous.count, by: 100) {
            let batch = Array(previous[offset..<min(offset + 100, previous.count)])
            results.merge(await fetchBatch(batch, database: database)) { _, latest in latest }
        }
        return results
    }

    private static func fetchBatch(_ previous: [SharedZoneCache], database: CKDatabase) async -> [CKRecordZone.ID: Result<SharedZoneCache, any Error>] {
        guard !previous.isEmpty else { return [:] }
        var seeds: [CKRecordZone.ID: SharedZoneCache] = [:]
        var configurations: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
        for zone in previous {
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            var seed = zone
            do { configuration.previousServerChangeToken = try zone.changeToken() }
            catch { seed = SharedZoneCache(zoneID: zone.zoneID, shared: zone.shared) }
            seeds[zone.zoneID] = seed
            configurations[zone.zoneID] = configuration
        }
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: previous.map(\.zoneID),
                                                         configurationsByRecordZoneID: configurations)
        operation.fetchAllChanges = true
        let collected = SharedZoneFetchResults()
        operation.recordWasChangedBlock = { id, result in collected.record(id, result: result) }
        operation.recordWithIDWasDeletedBlock = { id, _ in collected.deleted(id) }
        operation.recordZoneFetchResultBlock = { id, result in
            switch result {
            case .success(let value):
                collected.finish(id, token: value.serverChangeToken, moreComing: value.moreComing, error: nil)
            case .failure(let error):
                collected.finish(id, token: nil, moreComing: false, error: error)
            }
        }
        let outcome: Result<Void, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.fetchRecordZoneChangesResultBlock = { continuation.resume(returning: $0) }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        let changes = collected.snapshot()
        return seeds.mapValues { seed in
            do {
                try Task.checkCancellation()
                guard let change = changes[seed.zoneID] else {
                    try outcome.get()
                    throw APIError.message("iCloud did not return changes for a shared list.")
                }
                if let error = change.error { throw error }
                guard change.complete, let token = change.token else {
                    try outcome.get()
                    throw APIError.message("iCloud returned an incomplete shared list.")
                }
                var updated = seed
                try updated.apply(records: change.records, deleted: change.deleted, token: token)
                return .success(updated)
            } catch { return .failure(error) }
        }
    }
}
