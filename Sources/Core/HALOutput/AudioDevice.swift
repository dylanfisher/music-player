import CoreAudio
import Playback

/// A snapshot of an output device's properties, read once from the HAL.
public struct AudioDevice: Sendable {
    struct Stream: Sendable {
        var id: AudioStreamID
        var current: PhysicalFormat
        var available: [PhysicalFormat]
    }

    public var id: AudioObjectID
    public var name: String
    var manufacturer: String
    public var uid: String
    /// Four-character code: `'usb '`, `'bltn'` (built-in), `'hdmi'`, and so on.
    var transport: String
    var nominalSampleRateHz: Double
    var availableSampleRatesHz: [ClosedRange<Double>]
    var outputStreams: [Stream]
    /// The process holding exclusive access, or nil when no one is.
    var hogModeOwner: pid_t?

    init(
        id: AudioObjectID, name: String, manufacturer: String, uid: String, transport: String,
        nominalSampleRateHz: Double, availableSampleRatesHz: [ClosedRange<Double>],
        outputStreams: [Stream], hogModeOwner: pid_t?
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.uid = uid
        self.transport = transport
        self.nominalSampleRateHz = nominalSampleRateHz
        self.availableSampleRatesHz = availableSampleRatesHz
        self.outputStreams = outputStreams
        self.hogModeOwner = hogModeOwner
    }

    /// Every device with at least one output stream.
    public static func outputDevices() throws -> [AudioDevice] {
        let ids: [AudioObjectID] = try readArray(
            AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
        return try ids.compactMap { id in
            let streams: [AudioStreamID] = try readArray(
                id, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput))
            return streams.isEmpty ? nil : try AudioDevice(id: id, streamIDs: streams)
        }
    }

    /// The device macOS sends sound to by default (System Settings → Sound → Output).
    static func defaultOutputID() throws -> AudioObjectID {
        try readScalar(
            AudioObjectID(kAudioObjectSystemObject),
            address(kAudioHardwarePropertyDefaultOutputDevice))
    }

    private init(id: AudioObjectID, streamIDs: [AudioStreamID]) throws {
        let rates: [AudioValueRange] = try readArray(
            id, address(kAudioDevicePropertyAvailableNominalSampleRates))
        let hogOwner: pid_t = try readScalar(id, address(kAudioDevicePropertyHogMode))
        self.init(
            id: id,
            name: try readString(id, address(kAudioObjectPropertyName)),
            manufacturer: try readString(id, address(kAudioObjectPropertyManufacturer)),
            uid: try readString(id, address(kAudioDevicePropertyDeviceUID)),
            transport: fourCharCode(try readScalar(id, address(kAudioDevicePropertyTransportType))),
            nominalSampleRateHz: try readScalar(id, address(kAudioDevicePropertyNominalSampleRate)),
            availableSampleRatesHz: rates.map { $0.mMinimum...$0.mMaximum },
            outputStreams: try streamIDs.map { stream in
                let current: AudioStreamBasicDescription = try readScalar(
                    stream, address(kAudioStreamPropertyPhysicalFormat))
                let available: [AudioStreamRangedDescription] = try readArray(
                    stream, address(kAudioStreamPropertyAvailablePhysicalFormats))
                return Stream(
                    id: stream,
                    current: PhysicalFormat(current),
                    available: available.map(PhysicalFormat.init)
                )
            },
            hogModeOwner: hogOwner == -1 ? nil : hogOwner
        )
    }
}
