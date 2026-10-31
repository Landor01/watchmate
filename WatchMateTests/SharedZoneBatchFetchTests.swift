import CloudKit
import Testing
@testable import WatchMate

struct SharedZoneBatchFetchTests {
    @Test func changesStayIsolatedAndRecordErrorsSurviveZoneCompletion() throws {
        let results = SharedZoneFetchResults()
        let first = CKRecordZone.ID(zoneName: "Household-first")
        let second = CKRecordZone.ID(zoneName: "Household-second")
        let goodID = CKRecord.ID(recordName: "list", zoneID: first)
        let badID = CKRecord.ID(recordName: "list", zoneID: second)
        results.record(goodID, result: .success(CKRecord(recordType: "HouseholdList", recordID: goodID)))
        results.record(badID, result: .failure(CKError(.permissionFailure)))
        results.finish(first, token: nil, moreComing: false, error: nil)
        results.finish(second, token: nil, moreComing: false, error: nil)
        let snapshot = results.snapshot()
        #expect(snapshot[first]?.records.count == 1)
        #expect(snapshot[first]?.error == nil)
        #expect((snapshot[second]?.error as? CKError)?.code == .permissionFailure)
        #expect(snapshot[second]?.records.isEmpty == true)
    }

    @Test func laterPagesKeepFinalChangeForEachRecord() throws {
        let results = SharedZoneFetchResults()
        let zone = CKRecordZone.ID(zoneName: "Household-test")
        let id = CKRecord.ID(recordName: "episode", zoneID: zone)
        results.record(id, result: .success(CKRecord(recordType: "HouseholdEpisode", recordID: id)))
        results.deleted(id)
        #expect(results.snapshot()[zone]?.records.isEmpty == true)
        #expect(results.snapshot()[zone]?.deleted == [id])

        let replacement = CKRecord(recordType: "HouseholdEpisode", recordID: id)
        replacement["number"] = 2
        results.record(id, result: .success(replacement))
        #expect(results.snapshot()[zone]?.deleted.isEmpty == true)
        #expect(results.snapshot()[zone]?.records.count == 1)
        #expect(results.snapshot()[zone]?.records.first?["number"] as? Int == 2)
    }

    @Test func partialZoneDoesNotBecomeComplete() {
        let results = SharedZoneFetchResults()
        let zone = CKRecordZone.ID(zoneName: "Household-test")
        results.finish(zone, token: nil, moreComing: true, error: nil)
        #expect(results.snapshot()[zone]?.complete == false)
        results.finish(zone, token: nil, moreComing: false, error: CKError(.networkFailure))
        #expect(results.snapshot()[zone]?.complete == false)
        #expect((results.snapshot()[zone]?.error as? CKError)?.code == .networkFailure)
    }
}
