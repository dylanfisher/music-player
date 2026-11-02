import CoreAudio
import Foundation
import Log

private let logger = moduleLogger()

/// Calls `changed` on the main actor each time a device is added or removed, as long as it's
/// kept, so the output picker follows devices as they come and go.
public final class DeviceListWatch {
    private let block: AudioObjectPropertyListenerBlock

    public init(_ changed: @escaping @MainActor () -> Void) throws {
        block = { _, _ in MainActor.assumeIsolated { changed() } }
        var devices = address(kAudioHardwarePropertyDevices)
        try throwIfError(
            "AudioObjectAddPropertyListenerBlock(device list)",
            AudioObjectAddPropertyListenerBlock(systemObject, &devices, .main, block))
    }

    deinit {
        var devices = address(kAudioHardwarePropertyDevices)
        let status = AudioObjectRemovePropertyListenerBlock(systemObject, &devices, .main, block)
        if status != noErr { logger.error("removing the device list listener failed: \(status)") }
    }
}
