import AudioToolbox
import CoreAudio
import Playback

/// The device's signal properties, and the listeners that report a change to any of them: its
/// rate, hog mode, stream list and volume controls, and its first output stream's format.
func readSignal(of id: AudioObjectID) throws -> (signal: DeviceSignal, keys: Set<PropertyKey>) {
    let streams: [AudioStreamID] = try readArray(
        id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
    guard let stream = streams.first else { throw HALDeviceError.noOutputStream }
    let physical: AudioStreamBasicDescription = try readScalar(
        stream, address(kAudioStreamPropertyPhysicalFormat))
    let owner: pid_t = try readScalar(id, address(kAudioDevicePropertyHogMode))
    let volumes = volumeControls(of: id, channels: physical.mChannelsPerFrame)
    let signal = DeviceSignal(
        nominalSampleRateHz: try readScalar(id, address(kAudioDevicePropertyNominalSampleRate)),
        physical: SignalFormat(physical),
        isMixable: physical.mFormatFlags & kAudioFormatFlagIsNonMixable == 0,
        hogMode: owner == -1 ? .free : owner == getpid() ? .thisProcess : .otherProcess(pid: owner),
        volumes: try volumes.map { kind, key in
            VolumeControl(kind, scalar: try readScalar(id, key.address))
        })
    let keys = deviceSignalKeys(id).union(volumes.map(\.key)).union([
        PropertyKey(stream, kAudioStreamPropertyPhysicalFormat)
    ])
    return (signal, keys)
}

/// The device's own signal properties, which a device whose stream can't be read still has.
func deviceSignalKeys(_ id: AudioObjectID) -> Set<PropertyKey> {
    [
        PropertyKey(id, kAudioDevicePropertyNominalSampleRate),
        PropertyKey(id, kAudioDevicePropertyHogMode),
        PropertyKey(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
    ]
}

/// The output volume controls the device has: the virtual main volume, which the HAL derives from
/// the others when the device has no main control of its own, the main control, and one per
/// channel.
private func volumeControls(of id: AudioObjectID, channels: UInt32)
    -> [(kind: VolumeControl.Kind, key: PropertyKey)]
{
    let output = kAudioObjectPropertyScopeOutput
    let candidates: [(VolumeControl.Kind, PropertyKey)] =
        [
            (
                .virtualMain,
                PropertyKey(
                    id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: output)
            )
        ]
        + (0...channels).map { element in
            (
                element == 0 ? .main : .channel(element),
                PropertyKey(id, kAudioDevicePropertyVolumeScalar, scope: output, element: element)
            )
        }
    return candidates.filter { _, key in
        var address = key.address
        return AudioObjectHasProperty(id, &address)
    }
}
