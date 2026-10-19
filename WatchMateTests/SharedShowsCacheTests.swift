import CloudKit
import Foundation
import Testing
@testable import WatchMate

struct SharedShowsCacheTests {
    private func zone(_ name: String = "Household-test", shared: Bool = false) -> SharedZoneCache {
        SharedZoneCache(zoneID: .init(zoneName: name, ownerName: "owner"), shared: shared)
    }

    private func header(_ zone: SharedZoneCache, name: String = "Together") -> CKRecord {
        let record = CKRecord(recordType: "HouseholdList", recordID: .init(recordName: "list", zoneID: zone.zoneID))
        record["name"] = name as CKRecordValue
        return record
    }

    private func show(_ zone: SharedZoneCache) throws -> CKRecord {
        let record = CKRecord(recordType: "HouseholdShow", recordID: .init(recordName: "show-1", zoneID: zone.zoneID))
        let programme = SharedProgramme(show: RemoteShow(title: "Show", year: nil, ids: IDs(trakt: 1, tmdb: nil)),
                                        addedBy: "trakt", episodes: [], revision: "revision")
        record["payload"] = try JSONEncoder().encode(programme) as CKRecordValue
        return record
    }

    @Test func incrementalEpisodeChangesPreserveUnchangedListAndShow() throws {
        var cache = zone()
        try cache.apply(records: [header(cache), show(cache)], deleted: [], token: nil)
        let event = CKRecord(recordType: "HouseholdEpisode", recordID: .init(recordName: "episode-1", zoneID: cache.zoneID))
        event["showID"] = 1 as CKRecordValue
        event["episodeID"] = 10 as CKRecordValue
        event["season"] = 1 as CKRecordValue
        event["number"] = 1 as CKRecordValue
        event["revision"] = "revision" as CKRecordValue
        event["watchedAt"] = Date(timeIntervalSince1970: 100) as CKRecordValue
        try cache.apply(records: [event], deleted: [], token: nil)
        let list = try #require(try cache.list())
        #expect(list.name == "Together")
        #expect(list.programmes.count == 1)
        #expect(list.programmes.first?.episodes.first?.id == 10)
    }

    @Test func deletionsRemoveCachedShowsAndHeaders() throws {
        var cache = zone()
        let record = try show(cache)
        try cache.apply(records: [header(cache), record], deleted: [], token: nil)
        try cache.apply(records: [], deleted: [record.recordID], token: nil)
        #expect(try cache.list()?.programmes.isEmpty == true)
        try cache.apply(records: [], deleted: [header(cache).recordID], token: nil)
        #expect(try cache.list() == nil)
    }

    @Test func diskRoundTripRetainsPhotoAndUnchangedRecords() throws {
        var cache = zone()
        let listHeader = header(cache)
        let photo = Data([1, 2, 3])
        listHeader["photoData"] = photo as CKRecordValue
        try cache.apply(records: [listHeader, show(cache)], deleted: [], token: nil)
        let restored = try JSONDecoder().decode(SharedZoneCache.self, from: JSONEncoder().encode(cache))
        #expect(try restored.list()?.photoData == photo)
        #expect(try restored.list()?.programmes.first?.id == 1)
        #expect(restored.zoneID == cache.zoneID)
        #expect(try restored.changeToken() == nil)
    }

    @Test func revokedSharedZoneDoesNotRemoveOwnedLists() throws {
        var owned = zone("Household-owned")
        var invited = zone("Household-invited", shared: true)
        try owned.apply(records: [header(owned)], deleted: [], token: nil)
        try invited.apply(records: [header(invited)], deleted: [], token: nil)
        var cache = SharedShowsCache(ownerID: "apple", zones: [owned.key: owned, invited.key: invited])
        cache.retainZones([], shared: true)
        #expect(cache.zones[owned.key] != nil)
        #expect(cache.zones[invited.key] == nil)
        #expect(try cache.lists().count == 1)
    }

    @Test func emptyIncrementalResponseDoesNotClearExistingData() throws {
        var cache = zone()
        try cache.apply(records: [header(cache), show(cache)], deleted: [], token: nil)
        let previous = cache.recordData
        try cache.apply(records: [], deleted: [], token: nil)
        #expect(cache.recordData == previous)
        #expect(try cache.list()?.programmes.count == 1)
    }

    @Test func recentAutomaticRefreshIsSkippedButManualRefreshIsNot() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(!SharedRefreshPolicy.needsRefresh(automatic: true, lastSuccess: now.addingTimeInterval(-10), now: now))
        #expect(SharedRefreshPolicy.needsRefresh(automatic: false, lastSuccess: now, now: now))
        #expect(SharedRefreshPolicy.needsRefresh(automatic: true, lastSuccess: nil, now: now))
        #expect(SharedRefreshPolicy.needsRefresh(automatic: true, lastSuccess: now.addingTimeInterval(-60), now: now))
    }

    @Test func differentAppleAccountCannotRestorePreviousCache() throws {
        let account = "cache-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: SharedShowsCache.url(accountID: account)) }
        var saved = zone()
        try saved.apply(records: [header(saved)], deleted: [], token: nil)
        let cache = SharedShowsCache(ownerID: "apple-a", zones: [saved.key: saved])
        try cache.save(accountID: account)
        #expect(try SharedShowsCache.read(accountID: account, ownerID: "apple-a").zones.count == 1)
        #expect(try SharedShowsCache.read(accountID: account, ownerID: "apple-b").zones.isEmpty)
    }

    @Test func damagedTokenCanBeDetectedWithoutLosingCachedDisplay() throws {
        var cache = zone()
        try cache.apply(records: [header(cache)], deleted: [], token: nil)
        cache.tokenData = Data("invalid archive".utf8)
        #expect(throws: (any Error).self) { try cache.changeToken() }
        #expect(try cache.list()?.name == "Together")
    }
}
