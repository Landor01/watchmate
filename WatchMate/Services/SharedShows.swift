import CloudKit
import Foundation
import Observation
import UIKit

struct SharedEpisode: Codable, Identifiable {
    let id: Int
    let season: Int
    let number: Int
    let watchedAt: Date
}

struct SharedProgramme: Codable, Identifiable {
    let show: RemoteShow
    let addedBy: String
    let episodes: [SharedEpisode]
    var skippedEpisodeIDs: Set<Int>? = nil
    var revision: String = UUID().uuidString
    var id: Int { show.id }
}

struct HouseholdList: Identifiable {
    let zoneID: CKRecordZone.ID
    let name: String
    let shared: Bool
    let programmes: [SharedProgramme]
    var photoData: Data? = nil
    var id: String { zoneID.ownerName + "/" + zoneID.zoneName }
}

struct SharedHistoryOffer: Identifiable {
    let listID: String
    let listName: String
    let programme: SharedProgramme
    var id: String { listID + ":" + String(programme.id) + ":" + programme.revision }
}

/// Shared progress is independent of every participant's personal Trakt history.
@MainActor @Observable
final class SharedShows {
    let container = CKContainer(identifier: "iCloud.net.andrewroland.WatchMate")
    private(set) var lists: [HouseholdList] = []
    private(set) var loading = false
    var errorMessage: String?
    var invitationReceived = false
    private var generation = UUID()
    private var accountID: String?
    private var reviewedOffers: Set<String> = []
    private(set) var personalShowIDs: Set<Int> = []
    private var cache: SharedShowsCache?
    private var lastSuccessfulRefresh: Date?
    private var refreshRequested = false
    private var cacheRevision = 0
    private(set) var refreshMessage: String?
    @ObservationIgnored private var accountTask: Task<Void, Never>?

    #if DEBUG
    func preparePreview(lists: [HouseholdList]) {
        self.lists = lists
    }
    #endif

    init() {
        guard !PreviewEnvironment.isRunning else { return }
        accountTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard !Task.isCancelled else { return }
                self?.invalidateCloudAccount()
            }
        }
    }

    deinit { accountTask?.cancel() }

    private func invalidateCloudAccount() {
        generation = UUID()
        cache = nil
        lists = []
        lastSuccessfulRefresh = nil
        refreshMessage = nil
        if let accountID { try? FileManager.default.removeItem(at: SharedShowsCache.url(accountID: accountID)) }
        Task { [weak self] in await self?.refresh(reportErrors: false) }
    }

    var showIDs: Set<Int> { Set(lists.flatMap { $0.programmes.map(\.id) }) }

    var historyOffers: [SharedHistoryOffer] {
        guard let accountID else { return [] }
        return lists.flatMap { list in
            list.programmes.compactMap { programme in
                let offer = SharedHistoryOffer(listID: list.id, listName: list.name, programme: programme)
                return programme.addedBy != accountID && !reviewedOffers.contains(offer.id) ? offer : nil
            }
        }
    }

    func review(_ offer: SharedHistoryOffer) {
        guard let accountID else { return }
        reviewedOffers.insert(offer.id)
        UserDefaults.standard.set(Array(reviewedOffers), forKey: "sharedHistoryReviewed:" + accountID)
    }

    func activate(accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        personalShowIDs = Set(UserDefaults.standard.array(forKey: "sharedPersonalShows:" + (accountID ?? "")) as? [Int] ?? [])
        reviewedOffers = Set(UserDefaults.standard.stringArray(forKey: "sharedHistoryReviewed:" + (accountID ?? "")) ?? [])
        generation = UUID()
        lists = []
        cache = nil
        lastSuccessfulRefresh = nil
        refreshMessage = nil
        if loading { refreshRequested = true }
    }

    func database(for list: HouseholdList) -> CKDatabase {
        list.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    func refresh(reportErrors: Bool = true, automatic: Bool = false) async {
        guard !PreviewEnvironment.isRunning else { return }
        guard let accountID else { return }
        if loading {
            // A write or pull-to-refresh during a fetch needs a follow-up, not a dropped refresh.
            if !automatic { refreshRequested = true }
            return
        }
        guard SharedRefreshPolicy.needsRefresh(automatic: automatic, lastSuccess: lastSuccessfulRefresh) else { return }
        loading = true
        let session = generation
        defer {
            loading = false
            if refreshRequested {
                refreshRequested = false
                Task { [weak self] in await self?.refresh(reportErrors: false) }
            }
        }
        do {
            let status = try await container.accountStatus()
            guard session == generation else { return }
            guard status == .available else {
                if status == .noAccount || status == .restricted { clearCachedLists() }
                throw APIError.message("Sign in to iCloud in device Settings to use Shared Shows.")
            }
            if cache == nil {
                // Verify the Apple account once per process/account change before exposing saved data.
                let owner = try await container.userRecordID().recordName
                guard session == generation else { return }
                cache = (try? SharedShowsCache.read(accountID: accountID, ownerID: owner)) ?? SharedShowsCache(ownerID: owner)
                do { lists = try cache?.lists() ?? [] }
                catch { cache = SharedShowsCache(ownerID: owner); lists = [] }
            }

            // Enumerate the two databases concurrently; removed zones also remove revoked invitations.
            let revision = cacheRevision
            async let owned = container.privateCloudDatabase.allRecordZones()
            async let invited = container.sharedCloudDatabase.allRecordZones()
            let inventories = try await [(false, owned), (true, invited)]
            guard session == generation else { return }
            guard revision == cacheRevision else { refreshRequested = true; return }
            let previousKeys = Set(cache?.zones.keys.map { $0 } ?? [])
            for (shared, zones) in inventories {
                let ids = Set(zones.filter { $0.zoneID.zoneName.hasPrefix("Household-") }.map(\.zoneID))
                cache?.retainZones(ids, shared: shared)
            }
            if previousKeys != Set(cache?.zones.keys.map { $0 } ?? []) { publishCache() }

            var firstError: Error?
            for (shared, zones) in inventories {
                let database = shared ? container.sharedCloudDatabase : container.privateCloudDatabase
                for zone in zones where zone.zoneID.zoneName.hasPrefix("Household-") {
                    let key = SharedZoneCache.key(zoneID: zone.zoneID, shared: shared)
                    let revision = cacheRevision
                    let previous = cache?.zones[key] ?? SharedZoneCache(zoneID: zone.zoneID, shared: shared)
                    do {
                        let updated = try await fetchZone(previous, database: database)
                        guard session == generation else { return }
                        guard revision == cacheRevision else { refreshRequested = true; continue }
                        // Only publish a complete page sequence; a failed page must not advance the token.
                        _ = try updated.list()
                        cache?.zones[key] = updated
                        if updated.recordData != previous.recordData { publishCache(persist: false) }
                    } catch {
                        guard session == generation else { return }
                        if let cloudError = error as? CKError,
                           [.zoneNotFound, .userDeletedZone, .permissionFailure, .unknownItem].contains(cloudError.code) {
                            cache?.zones.removeValue(forKey: key)
                            publishCache()
                        } else { firstError = firstError ?? error }
                    }
                }
            }
            try cache?.save(accountID: accountID)
            if let firstError { throw firstError }
            guard session == generation else { return }
            lastSuccessfulRefresh = Date()
            refreshMessage = nil
        } catch {
            guard session == generation else { return }
            if let cloudError = error as? CKError, cloudError.code == .notAuthenticated { clearCachedLists() }
            refreshMessage = lists.isEmpty ? error.localizedDescription : "Couldn’t refresh. Showing saved shared lists."
            if reportErrors && !automatic { errorMessage = error.localizedDescription }
        }
    }

    private func fetchZone(_ previous: SharedZoneCache, database: CKDatabase) async throws -> SharedZoneCache {
        var updated = previous
        var retried = false
        while true {
            do {
                let token: CKServerChangeToken?
                do { token = try updated.changeToken() }
                catch { updated = SharedZoneCache(zoneID: previous.zoneID, shared: previous.shared); token = nil }
                let page = try await database.recordZoneChanges(inZoneWith: previous.zoneID, since: token)
                let records = try page.modificationResultsByID.values.map { try $0.get().record }
                try updated.apply(records: records, deleted: page.deletions.map(\.recordID), token: page.changeToken)
                if !page.moreComing { return updated }
            } catch let error as CKError where error.code == .changeTokenExpired && !retried {
                // An expired token requires a fresh snapshot of this zone, not every shared list.
                retried = true
                updated = SharedZoneCache(zoneID: previous.zoneID, shared: previous.shared)
            }
        }
    }

    private func publishCache(persist: Bool = true) {
        guard let cache, let accountID else { return }
        do {
            lists = try cache.lists()
            if persist { try cache.save(accountID: accountID) }
        } catch {
            refreshMessage = "Shared lists are available, but could not be saved on this device."
        }
    }

    private func clearCachedLists() {
        cache = nil
        lists = []
        lastSuccessfulRefresh = nil
        if let accountID { try? FileManager.default.removeItem(at: SharedShowsCache.url(accountID: accountID)) }
    }

    /// Merge acknowledged writes immediately, without advancing the server's change token.
    private func remember(_ record: CKRecord, shared: Bool, session: UUID) {
        guard session == generation else { return }
        cacheRevision += 1
        guard cache != nil else { return }
        let key = SharedZoneCache.key(zoneID: record.recordID.zoneID, shared: shared)
        var zone = cache?.zones[key] ?? SharedZoneCache(zoneID: record.recordID.zoneID, shared: shared)
        do {
            let token = try zone.changeToken()
            try zone.apply(records: [record], deleted: [], token: token)
            cache?.zones[key] = zone
            publishCache()
        } catch {
            // Recover with a full fetch of this zone if its saved token or record is damaged.
            cache?.zones.removeValue(forKey: key)
            lastSuccessfulRefresh = nil
        }
    }

    func create(name: String) async throws {
        let session = generation
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, accountID != nil else { return }
        let zone = CKRecordZone(zoneName: "Household-" + UUID().uuidString)
        let database = container.privateCloudDatabase
        _ = try await database.save(zone)
        let header = CKRecord(recordType: "HouseholdList", recordID: .init(recordName: "list", zoneID: zone.zoneID))
        header["name"] = name as CKRecordValue
        let saved = try await database.save(header)
        remember(saved, shared: false, session: session)
        await refresh()
    }

    func setPhoto(_ image: UIImage?, for list: HouseholdList) async throws {
        let session = generation
        let data = try image.map { try Settings.profilePhotoData(for: $0) }
        let database = database(for: list)
        let header = try await database.record(for: .init(recordName: "list", zoneID: list.zoneID))
        header["photoData"] = data as CKRecordValue?
        var saving = [header]
        if !list.shared {
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: list.zoneID)
            do {
                if let share = try await database.record(for: shareID) as? CKShare {
                    share[CKShare.SystemFieldKey.thumbnailImageData] = SharedListAvatar.image(name: list.name, photoData: data).pngData() as CKRecordValue?
                    saving.append(share)
                }
            } catch let error as CKError where error.code == .unknownItem {
                // A list need not have an invitation yet.
            }
        }
        let result = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        for outcome in result.saveResults.values {
            let saved = try outcome.get()
            if saved.recordType == "HouseholdList" { remember(saved, shared: list.shared, session: session) }
        }
        guard session == generation else { return }
        if let index = lists.firstIndex(where: { $0.id == list.id }) {
            lists[index].photoData = data
        }
    }

    func share(for list: HouseholdList) async throws -> CKShare {
        let database = database(for: list)
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: list.zoneID)
        do {
            guard let share = try await database.record(for: id) as? CKShare else {
                throw APIError.message("The invitation could not be loaded.")
            }
            let thumbnail = SharedListAvatar.image(name: list.name, photoData: list.photoData).pngData()
            if !list.shared, share[CKShare.SystemFieldKey.thumbnailImageData] as? Data != thumbnail {
                share[CKShare.SystemFieldKey.thumbnailImageData] = thumbnail as CKRecordValue?
                guard let saved = try await database.save(share) as? CKShare else {
                    throw APIError.message("The invitation image could not be saved.")
                }
                return saved
            }
            return share
        } catch let error as CKError where error.code == .unknownItem && !list.shared {
            let share = CKShare(recordZoneID: list.zoneID)
            share[CKShare.SystemFieldKey.title] = list.name as CKRecordValue
            share[CKShare.SystemFieldKey.thumbnailImageData] = SharedListAvatar.image(name: list.name, photoData: list.photoData).pngData() as CKRecordValue?
            share.publicPermission = .none
            guard let saved = try await database.save(share) as? CKShare else {
                throw APIError.message("The invitation could not be saved.")
            }
            return saved
        }
    }

    func accept(_ metadata: CKShare.Metadata) async {
        do {
            guard metadata.containerIdentifier == container.containerIdentifier else { return }
            _ = try await container.accept(metadata)
            invitationReceived = true
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func showInMyShows(_ showID: Int, visible: Bool = true) {
        guard let accountID else { return }
        if visible { personalShowIDs.insert(showID) }
        else { personalShowIDs.remove(showID) }
        UserDefaults.standard.set(Array(personalShowIDs), forKey: "sharedPersonalShows:" + accountID)
    }

    /// Save the destination first: a failed copy must never remove the source.
    func move(_ programme: SharedProgramme, from source: HouseholdList, to destination: HouseholdList) async throws {
        guard source.id != destination.id else { return }
        let session = generation
        let zone = try await fetchZone(SharedZoneCache(zoneID: source.zoneID, shared: source.shared),
                                       database: database(for: source))
        guard session == generation else { throw CancellationError() }
        guard let current = try zone.list()?.programmes.first(where: { $0.id == programme.id }),
              current.revision == programme.revision else {
            throw APIError.message("This programme has changed or been removed. Refresh the list and try again.")
        }
        var copy = current
        copy.revision = UUID().uuidString
        try await add(copy, to: destination, failIfExists: true)
        guard session == generation else { throw CancellationError() }
        do { try await remove(current, from: source) }
        catch {
            throw APIError.message("The programme was added to the destination, but could not be removed from the original list. It is in both lists. Remove it from the original list when ready. " + error.localizedDescription)
        }
    }

    func add(_ programme: SharedProgramme, to list: HouseholdList, failIfExists: Bool = false) async throws {
        let session = generation
        let id = CKRecord.ID(recordName: "show-\(programme.id)", zoneID: list.zoneID)
        let database = database(for: list)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "HouseholdShow", recordID: id)
        }
        if record["payload"] != nil && (record["removed"] as? Int ?? 0) == 0 {
            if failIfExists {
                throw APIError.message("This programme is already in the destination list. Its progress has not been overwritten.")
            }
            return
        }
        record["payload"] = try JSONEncoder().encode(programme) as CKRecordValue
        record["removed"] = 0 as CKRecordValue
        let saved = try await database.save(record)
        remember(saved, shared: list.shared, session: session)
        await refresh()
    }

    func remove(_ programme: SharedProgramme, from list: HouseholdList) async throws {
        let session = generation
        let database = database(for: list)
        let id = CKRecord.ID(recordName: "show-\(programme.id)", zoneID: list.zoneID)
        let record = try await database.record(for: id)
        guard session == generation else { throw CancellationError() }
        if let payload = record["payload"] as? Data {
            let current = try JSONDecoder().decode(SharedProgramme.self, from: payload)
            guard current.revision == programme.revision else {
                throw APIError.message("This programme has been replaced. Refresh the list before removing it.")
            }
        }
        // A tombstone makes removal atomic. Re-adding uses a new revision so old episode events cannot reappear.
        record["removed"] = 1 as CKRecordValue
        let saved = try await database.save(record)
        remember(saved, shared: list.shared, session: session)
        await refresh()
    }

    func setWatched(_ episode: RemoteEpisode, showID: Int, in list: HouseholdList, watched: Bool) async throws {
        try await updateEpisodes([episode], showID: showID, in: list, action: .watched(watched))
    }

    /// Each acknowledged episode is retained if a later write fails. Refresh once for the whole action.
    func updateEpisodes(_ episodes: [RemoteEpisode], showID: Int, in list: HouseholdList,
                        action: SharedEpisodeAction, progress: (Int) -> Void = { _ in }) async throws {
        let database = database(for: list)
        let session = generation
        guard let programme = list.programmes.first(where: { $0.id == showID }) else {
            throw APIError.message("This programme is no longer shared.")
        }
        do {
            let showRecord = try await database.record(for: .init(recordName: "show-\(showID)", zoneID: list.zoneID))
            guard (showRecord["removed"] as? Int ?? 0) == 0,
                  let data = showRecord["payload"] as? Data else {
                throw APIError.message("This shared programme has changed. Refresh the list before editing its progress.")
            }
            let seed = try JSONDecoder().decode(SharedProgramme.self, from: data)
            guard seed.revision == programme.revision else {
                throw APIError.message("This shared programme has changed. Refresh the list before editing its progress.")
            }
            for (index, episode) in episodes.enumerated() {
                try Task.checkCancellation()
                guard session == generation else { throw APIError.message("Your account changed. Update stopped.") }
                let id = CKRecord.ID(recordName: "episode-\(programme.revision)-\(episode.ids.trakt)", zoneID: list.zoneID)
                let record: CKRecord
                do { record = try await database.record(for: id) }
                catch let error as CKError where error.code == .unknownItem {
                    record = CKRecord(recordType: "HouseholdEpisode", recordID: id)
                    record["watchedAt"] = seed.episodes.first { $0.id == episode.ids.trakt }?.watchedAt as CKRecordValue?
                }
                record["revision"] = programme.revision as CKRecordValue
                record["showID"] = showID as CKRecordValue
                record["episodeID"] = episode.ids.trakt as CKRecordValue
                record["season"] = episode.season as CKRecordValue
                record["number"] = episode.number as CKRecordValue
                switch action {
                case .watched(let watched):
                    if watched && Dates.parse(episode.firstAired).map({ !AirDates.hasAired($0) }) == true {
                        progress(index + 1)
                        continue
                    }
                    if watched {
                        if record["watchedAt"] == nil { record["watchedAt"] = Date() as CKRecordValue }
                        record["skipped"] = 0 as CKRecordValue
                    } else { record["watchedAt"] = nil }
                case .skipped(let skipped):
                    // Preserve watches made by another participant after this screen loaded.
                    record["skipped"] = (skipped && record["watchedAt"] == nil ? 1 : 0) as CKRecordValue
                }
                guard session == generation else { throw APIError.message("Your account changed. Update stopped.") }
                let saved = try await database.save(record)
                guard session == generation else { throw APIError.message("Your account changed. Update stopped.") }
                remember(saved, shared: list.shared, session: session)
                progress(index + 1)
            }
        } catch {
            await refresh(reportErrors: false)
            throw error
        }
        await refresh()
    }

}

enum SharedHistoryPlan {
    /// Compare episode identities, not counts: histories may have different gaps.
    static func changes(shared: [SharedEpisode], watched: Set<String>, catalogue: [RemoteEpisode]) throws -> [SharedHistoryChange] {
        let target = Set(shared.map { "\($0.season):\($0.number)" })
        let known = Set(catalogue.map { "\($0.season):\($0.number)" })
        guard watched.subtracting(target).isSubset(of: known) else {
            throw APIError.message("Some watched episodes could not be found in Trakt's catalogue. No history has been changed. Try again later.")
        }
        var seen = Set<Int>()
        var changes = shared.filter {
            !watched.contains("\($0.season):\($0.number)") && seen.insert($0.id).inserted
        }.map { SharedHistoryChange(episode: $0, watched: true) }
        changes += catalogue.filter {
            let key = "\($0.season):\($0.number)"
            return watched.contains(key) && !target.contains(key) && seen.insert($0.ids.trakt).inserted
        }.map {
            SharedHistoryChange(episode: SharedEpisode(id: $0.ids.trakt, season: $0.season,
                                                       number: $0.number, watchedAt: .distantPast), watched: false)
        }
        return changes.sorted { ($0.episode.season, $0.episode.number) < ($1.episode.season, $1.episode.number) }
    }
}
