import CoreAudio
import Foundation
import Testing

@testable import HALOutput

/// Records listeners as the HAL would hold them, and refuses a removal it never added.
private final class FakeListening: PropertyListening, @unchecked Sendable {
    private(set) var registered: Set<PropertyKey> = []
    private(set) var adds = 0
    private(set) var unmatchedRemoves = 0
    /// Objects that refuse new listeners, as a device that's going away does.
    var refusing: Set<AudioObjectID> = []

    func add(
        _ key: PropertyKey, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        guard !refusing.contains(key.object) else { return OSStatus(kAudioHardwareBadObjectError) }
        adds += 1
        registered.insert(key)
        return noErr
    }

    func remove(
        _ key: PropertyKey, _ queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        guard registered.remove(key) != nil else {
            unmatchedRemoves += 1
            return OSStatus(kAudioHardwareBadObjectError)
        }
        return noErr
    }
}

private func keys(device: AudioObjectID, stream: AudioObjectID) -> Set<PropertyKey> {
    deviceSignalKeys(device).union([PropertyKey(stream, kAudioStreamPropertyPhysicalFormat)])
}

@Test func followingADeviceToANewObjectIDAndStoppingRemovesEveryListenerAdded() {
    let fake = FakeListening()
    let listeners = PropertyListeners(
        fake, queue: DispatchQueue(label: "test"), block: { _, _ in })
    listeners.set(keys(device: 10, stream: 11))
    #expect(fake.registered == keys(device: 10, stream: 11))
    // The device was plugged back in, so it has new IDs.
    listeners.set(keys(device: 20, stream: 21))
    #expect(fake.registered == keys(device: 20, stream: 21))
    #expect(listeners.active == fake.registered)
    listeners.set([])
    #expect(fake.registered.isEmpty)
    #expect(listeners.active.isEmpty)
    #expect(fake.unmatchedRemoves == 0)
    #expect(fake.adds == 8)
}

@Test func aListenerThatWontAddIsRetriedAndNeverRemoved() {
    let fake = FakeListening()
    fake.refusing = [11]
    let listeners = PropertyListeners(
        fake, queue: DispatchQueue(label: "test"), block: { _, _ in })
    let wanted = keys(device: 10, stream: 11)
    listeners.set(wanted)
    #expect(fake.registered == deviceSignalKeys(10))
    fake.refusing = []
    listeners.set(wanted)
    #expect(fake.registered == wanted)
    listeners.set([])
    #expect(fake.unmatchedRemoves == 0)
    #expect(fake.registered.isEmpty)
}
