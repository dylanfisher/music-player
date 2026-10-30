import CoreAudio

/// A snapshot of an output device's properties, read once from the HAL.
public struct AudioDevice: Sendable {
    public struct Stream: Sendable {
        public var id: AudioStreamID
        public var current: PhysicalFormat
        public var available: [PhysicalFormat]

        public init(id: AudioStreamID, current: PhysicalFormat, available: [PhysicalFormat]) {
            self.id = id
            self.current = current
            self.available = available
        }
    }

    public var id: AudioObjectID
    public var name: String
    public var manufacturer: String
    public var uid: String
    /// Four-character code: `'usb '`, `'bltn'` (built-in), `'hdmi'`, and so on.
    public var transport: String
    public var nominalSampleRateHz: Double
    public var availableSampleRatesHz: [ClosedRange<Double>]
    public var outputStreams: [Stream]
    /// The process holding exclusive access, or nil when no one is.
    public var hogModeOwner: pid_t?

    public init(
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
                    current: PhysicalFormat(
                        AudioStreamRangedDescription(
                            mFormat: current,
                            mSampleRateRange: AudioValueRange(
                                mMinimum: current.mSampleRate, mMaximum: current.mSampleRate))),
                    available: available.map(PhysicalFormat.init)
                )
            },
            hogModeOwner: hogOwner == -1 ? nil : hogOwner
        )
    }
}
