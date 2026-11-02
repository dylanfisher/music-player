import CoreAudio
import Foundation
import Testing

@testable import HALOutput

private let snapshot = DeviceSnapshot(
    deviceUID: "test-device-that-is-never-connected", sampleRateHz: 44_100,
    physicalFormat: StoredFormat(
        AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)),
    defaultOutputUID: "speakers", defaultSystemOutputUID: nil)

private func temporaryRecord() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "device-restore-\(UUID().uuidString).json")
}

@Test func snapshotsRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(DeviceSnapshot.self, from: data) == snapshot)
}

@Test func unknownKeysAreRejectedAtEveryLevel() throws {
    let data = try JSONEncoder().encode(snapshot)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["extra"] = 1
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            DeviceSnapshot.self, from: try JSONSerialization.data(withJSONObject: object))
    }
    object["extra"] = nil
    var format = try #require(object["physicalFormat"] as? [String: Any])
    format["extra"] = 1
    object["physicalFormat"] = format
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            DeviceSnapshot.self, from: try JSONSerialization.data(withJSONObject: object))
    }
}

@Test func aRecordThatDoesntReadIsDiscardedAndReported() throws {
    let url = temporaryRecord()
    try Data("{\"deviceUID\": 3}".utf8).write(to: url)
    let report = try #require(try HALDeviceProvider.recoverAfterCrash(restoreRecordURL: url))
    #expect(report.contains("discarded"))
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func recordsForDisconnectedDevicesAreKeptForLater() throws {
    let url = temporaryRecord()
    defer { try? FileManager.default.removeItem(at: url) }
    var other = snapshot
    other.deviceUID = "another-device-that-is-never-connected"
    try writeRestoreRecords([snapshot, other], to: url)
    let report = try #require(try HALDeviceProvider.recoverAfterCrash(restoreRecordURL: url))
    #expect(report.components(separatedBy: "isn't connected").count == 3)
    #expect(try readRestoreRecords(url) == [snapshot, other])
}

@Test func aNewSessionNeverOverwritesAnUnrestoredRecord() {
    var later = snapshot
    later.sampleRateHz = 96_000
    #expect(adding(later, to: [snapshot]) == [snapshot])
    var other = snapshot
    other.deviceUID = "other"
    #expect(adding(other, to: [snapshot]) == [snapshot, other])
}

@Test func writingNoRecordsDeletesTheFile() throws {
    let url = temporaryRecord()
    try writeRestoreRecords([snapshot], to: url)
    try writeRestoreRecords([], to: url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func noRecordMeansNothingToRecover() throws {
    #expect(try HALDeviceProvider.recoverAfterCrash(restoreRecordURL: temporaryRecord()) == nil)
}

@Test func aProviderMadeForASettingsChangeRestoresTheStateFromBeforeTheRun() {
    let snapshots = DeviceSnapshots()
    let uid = snapshot.deviceUID
    // The first provider's first open: the device as it was before playback.
    snapshots.keep(snapshots.original(of: uid, recorded: []) { snapshot })
    // Hog mode was turned off and a new provider opened the device before the old session's
    // restore landed, so the device still reads in the hog session's format.
    var hogged = snapshot
    hogged.sampleRateHz = 96_000
    hogged.physicalFormat.sampleRate = 96_000
    hogged.physicalFormat.formatFlags |= kAudioFormatFlagIsNonMixable
    let restored = snapshots.original(of: uid, recorded: []) { hogged }
    snapshots.keep(restored)
    #expect(restored == snapshot)
    #expect(snapshots.snapshot(of: uid) == snapshot)
}

@Test func theFirstOpenTakesAnUnrestoredRecordOverTheDeviceNow() {
    var earlier = snapshot
    earlier.sampleRateHz = 48_000
    #expect(
        DeviceSnapshots().original(of: snapshot.deviceUID, recorded: [earlier]) { snapshot }
            == earlier)
}
