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

@Test func aRecordForADisconnectedDeviceIsKeptForLater() throws {
    let url = temporaryRecord()
    defer { try? FileManager.default.removeItem(at: url) }
    try JSONEncoder().encode(snapshot).write(to: url)
    let report = try #require(try HALDeviceProvider.recoverAfterCrash(restoreRecordURL: url))
    #expect(report.contains("isn't connected"))
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func noRecordMeansNothingToRecover() throws {
    #expect(try HALDeviceProvider.recoverAfterCrash(restoreRecordURL: temporaryRecord()) == nil)
}
