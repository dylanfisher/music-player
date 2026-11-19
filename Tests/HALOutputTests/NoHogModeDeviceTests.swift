import CoreAudio
import Foundation
import Testing

@testable import HALOutput

/// A private multi-output device over the default output, as Audio MIDI Setup makes one, visible
/// to this process only, destroyed when `body` returns.
private func withMultiOutputDevice(_ body: (AudioObjectID) throws -> Void) throws {
    let defaultID = try AudioDevice.defaultOutputID()
    let uid = try readString(defaultID, address(kAudioDevicePropertyDeviceUID))
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "NoHogModeDeviceTests",
        kAudioAggregateDeviceUIDKey: "NoHogModeDeviceTests-\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceIsStackedKey: 1,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
    ]
    var id = AudioObjectID(kAudioObjectUnknown)
    try throwIfError(
        "AudioHardwareCreateAggregateDevice",
        AudioHardwareCreateAggregateDevice(description as CFDictionary, &id))
    defer { AudioHardwareDestroyAggregateDevice(id) }
    try body(id)
}

@Test func aDeviceWithoutHogModeIsListedAsFree() throws {
    try withMultiOutputDevice { id in
        #expect(!hasHogMode(id))
        #expect(try readHogModeOwner(id) == nil)
        let listed = try AudioDevice.outputDevices().first { $0.id == id }
        #expect(listed?.hogModeOwner == nil)
        #expect(!deviceSignalKeys(id).contains(PropertyKey(id, kAudioDevicePropertyHogMode)))
    }
}
