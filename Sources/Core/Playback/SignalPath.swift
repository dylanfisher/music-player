/// What happens to the samples between the file and where an output sends them, for the signal
/// path panel. An output publishes one whenever any part of it changes.
public struct SignalPath: Sendable, Equatable {
    /// The track the listener hears, or nil when nothing is loaded.
    public var track: TrackSignal?
    public var sink: SignalSink

    public init(track: TrackSignal?, sink: SignalSink) {
        self.track = track
        self.sink = sink
    }
}

/// Where an output sends the samples.
public enum SignalSink: Sendable, Equatable {
    case device(DeviceSink)
    /// A network renderer, sent the file's own bytes.
    case renderer(RendererSink)
}

/// A track's samples as the file holds them and as the decoder hands them on. A renderer
/// decodes the file itself, so for one `decoded` is the file's format.
public struct TrackSignal: Sendable, Equatable {
    public var file: SignalFormat
    public var decoded: SignalFormat
    /// The device can't take the file's format, so the output converts it to `decoded`, the
    /// device's best (ADR 0071).
    public var isConverted: Bool
    /// The file doesn't name the order of its more than two channels, so a downmix takes them
    /// in the WAV and FLAC default order (ADR 0071).
    public var channelOrderAssumed: Bool

    public init(
        file: SignalFormat, decoded: SignalFormat, isConverted: Bool, channelOrderAssumed: Bool
    ) {
        self.file = file
        self.decoded = decoded
        self.isConverted = isConverted
        self.channelOrderAssumed = channelOrderAssumed
    }
}

/// A UPnP renderer and how the output plays to it (ADR 0041).
public struct RendererSink: Sendable, Equatable {
    /// Display text, escaped.
    public var name: String
    public var address: String
    /// The type the current file is offered as, such as `audio/flac`; nil when nothing is
    /// loaded.
    public var contentType: String?
    public var gapless: RendererGapless
    /// True for a Denon receiver, whose volume is the receiver's own, which receiver control
    /// sets; the output sends no volume to any renderer.
    public var volumeIsReceivers: Bool

    public init(
        name: String, address: String, contentType: String?, gapless: RendererGapless,
        volumeIsReceivers: Bool
    ) {
        self.name = name
        self.address = address
        self.contentType = contentType
        self.gapless = gapless
        self.volumeIsReceivers = volumeIsReceivers
    }
}

/// How one track follows another on a renderer.
public enum RendererGapless: Sendable, Equatable {
    /// Not known until the renderer's AVTransport description has been read.
    case unknown
    /// The next track is handed over with `SetNextAVTransportURI` while one plays.
    case nextURI
    /// Each track is sent once the last has stopped, so there's a gap; says why.
    case afterStop(String)
}

public struct SignalFormat: Sendable, Equatable {
    /// The four-character format code, such as `lpcm`, `flac` or `.mp3`.
    public var formatID: String
    public var sampleRateHz: Double
    /// Nil for a lossy codec, whose samples have no depth until they're decoded.
    public var bitsPerChannel: UInt32?
    public var channels: UInt32
    public var isFloat: Bool

    public init(
        formatID: String, sampleRateHz: Double, bitsPerChannel: UInt32?, channels: UInt32,
        isFloat: Bool
    ) {
        self.formatID = formatID
        self.sampleRateHz = sampleRateHz
        self.bitsPerChannel = bitsPerChannel
        self.channels = channels
        self.isFloat = isFloat
    }
}

/// An output device, and the gain the output applies before it.
public struct DeviceSink: Sendable, Equatable {
    public var name: String
    public var uid: String
    public var state: DeviceState
    /// The digital volume, as a linear amplitude: exactly 1 when off or at full.
    public var gain: Double

    public init(name: String, uid: String, state: DeviceState, gain: Double) {
        self.name = name
        self.uid = uid
        self.state = state
        self.gain = gain
    }
}

public enum DeviceState: Sendable, Equatable {
    case notConnected
    /// Reading its properties failed, with why.
    case unreadable(String)
    case connected(DeviceSignal)
}

/// The properties of a device that decide whether it plays samples unchanged.
public struct DeviceSignal: Sendable, Equatable {
    public var nominalSampleRateHz: Double
    /// The first output stream's hardware format.
    public var physical: SignalFormat
    /// False for a format the system can't mix other apps' sound into.
    public var isMixable: Bool
    public var hogMode: HogMode
    /// Every volume control on the device's output that it has, as a linear scalar.
    public var volumes: [VolumeControl]
    public var formats: DeviceFormats

    public init(
        nominalSampleRateHz: Double, physical: SignalFormat, isMixable: Bool, hogMode: HogMode,
        volumes: [VolumeControl], formats: DeviceFormats
    ) {
        self.nominalSampleRateHz = nominalSampleRateHz
        self.physical = physical
        self.isMixable = isMixable
        self.hogMode = hogMode
        self.volumes = volumes
        self.formats = formats
    }
}

public enum HogMode: Sendable, Equatable {
    case free
    case thisProcess
    case otherProcess(pid: Int32)
}

public struct VolumeControl: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The one macOS's volume slider moves, which may stand for several channels' controls.
        case virtualMain
        /// The device's main control, element 0.
        case main
        case channel(UInt32)
    }

    public var kind: Kind
    public var scalar: Float

    public init(_ kind: Kind, scalar: Float) {
        self.kind = kind
        self.scalar = scalar
    }
}
