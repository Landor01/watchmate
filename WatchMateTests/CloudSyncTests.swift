import Foundation
import Testing
import UIKit
@testable import WatchMate

struct CloudSyncTests {
    @Test func unchangedSnapshotDoesNotCreateAnotherRevision() {
        var journal = CloudSyncJournal()
        let snapshot = ["region": Data("GB".utf8)]
        journal.capture(snapshot)
        let first = journal.values
        journal.pending = []
        journal.capture(snapshot)
        #expect(journal.values == first)
        #expect(journal.pending.isEmpty)
    }

    @Test func editDuringSyncSurvivesOlderServerResponse() throws {
        var journal = CloudSyncJournal()
        journal.capture(["region": Data("GB".utf8)])
        let sent = try #require(journal.values["region"])
        let edited = CloudValue(data: Data("FR".utf8),
                                modifiedAt: sent.modifiedAt.addingTimeInterval(1), revision: "new-edit")
        journal.values["region"] = edited
        journal.baseline["region"] = edited.data
        journal.pending.insert("region")
        journal.merge("region", value: sent)
        #expect(journal.values["region"] == edited)
        #expect(journal.pending.contains("region"))
    }

    @Test @MainActor func profilePhotoIsBoundedForCloudRecord() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 1200), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1200))
        }
        let data = try Settings.profilePhotoData(for: image)
        let decoded = try #require(UIImage(data: data))
        #expect(data.count <= 512_000)
        #expect(decoded.size.width <= 512)
        #expect(decoded.size.height <= 512)
    }

    @Test func profilePhotoRestoresOnAnotherDeviceWithoutReupload() throws {
        let photo = Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])
        var source = CloudSyncJournal()
        source.capture(["profilePhoto": photo])
        let restored = try JSONDecoder().decode(CloudSyncJournal.self, from: JSONEncoder().encode(source))
        var destination = CloudSyncJournal()
        destination.capture([:], initial: true)
        destination.merge("profilePhoto", value: try #require(restored.values["profilePhoto"]))
        destination.baseline = ["profilePhoto": photo]
        destination.capture(["profilePhoto": photo])
        #expect(destination.values["profilePhoto"]?.data == photo)
        #expect(destination.pending.isEmpty)
    }

    private func value(_ text: String, date: TimeInterval = 100, revision: String = "remote") -> CloudValue {
        CloudValue(data: Data(text.utf8), modifiedAt: Date(timeIntervalSince1970: date), revision: revision)
    }

    @Test func existingCloudChoicesWinDuringMigration() {
        var journal = CloudSyncJournal()
        journal.capture(["region": Data("GB".utf8)], initial: true)
        let remote = CloudValue(data: Data("FR".utf8), modifiedAt: .distantPast, revision: "old-import")
        journal.merge("region", value: remote)
        #expect(journal.values["region"] == remote)
        #expect(!journal.pending.contains("region"))
    }

    @Test func editsToDifferentEpisodesMergeIndependently() {
        var journal = CloudSyncJournal()
        journal.capture(["skip:1:1:1": Data("true".utf8)])
        journal.merge("skip:1:1:2", value: value("true"))
        #expect(journal.values.count == 2)
        #expect(journal.pending == ["skip:1:1:1"])
    }

    @Test func unskipIsAnExplicitValueAndSurvivesRelaunch() throws {
        var journal = CloudSyncJournal()
        journal.capture(["skip:1:1:1": Data("true".utf8)])
        journal.capture(["skip:1:1:1": Data("false".utf8)])
        let restored = try JSONDecoder().decode(CloudSyncJournal.self, from: JSONEncoder().encode(journal))
        #expect(restored.values["skip:1:1:1"]?.data == Data("false".utf8))
        #expect(restored.pending == ["skip:1:1:1"])
    }

    @Test func olderRemoteValueCannotUndoAnOfflineEdit() {
        var journal = CloudSyncJournal()
        journal.capture(["following:1": Data("false".utf8)])
        journal.merge("following:1", value: value("true"))
        #expect(journal.values["following:1"]?.data == Data("false".utf8))
        #expect(journal.pending.contains("following:1"))
    }

    @Test func acceptedRemoteValuesAreNotUploadedAgain() {
        var journal = CloudSyncJournal()
        journal.merge("region", value: value("FR"))
        journal.baseline = ["region": Data("FR".utf8)]
        journal.capture(["region": Data("FR".utf8)])
        #expect(journal.pending.isEmpty)
    }

    @Test func clearingLocalCacheDoesNotDeleteCloudChoices() {
        var journal = CloudSyncJournal()
        journal.capture(["following:1": Data("false".utf8)])
        journal.capture([:])
        #expect(journal.values["following:1"]?.data == Data("false".utf8))
        #expect(journal.pending.contains("following:1"))
    }

    @Test func equalTimestampConflictsHaveDeterministicWinner() {
        var first = CloudSyncJournal()
        var second = CloudSyncJournal()
        let a = value("true", revision: "a")
        let b = value("false", revision: "b")
        first.merge("skip:1:1:1", value: a)
        first.merge("skip:1:1:1", value: b)
        second.merge("skip:1:1:1", value: b)
        second.merge("skip:1:1:1", value: a)
        #expect(first.values == second.values)
    }
}
