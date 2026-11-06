/// What analyzing a file's audio measured (phase 45), as the index keeps it: the format the
/// decoder read, and the measures the verdicts come from. Each measure is nil where it doesn't
/// apply, so the verdicts can be worked out again from a stored row alone.
public struct FileMeasures: Equatable, Sendable, Codable {
    /// The four-character format code, such as `flac` or `aac `, as `SignalFormat` has it.
    public var formatID: String
    public var sampleRateHz: Double
    /// The bits the file stores per sample; nil for a lossy codec.
    public var storedBits: Int?
    public var channels: Int
    /// Floating-point samples, which have no effective bits.
    public var isFloat: Bool
    public var durationSeconds: Double
    /// Where the average spectrum falls steeply and stays down; nil when it doesn't.
    public var cutoffHz: Double?
    /// How fast it falls there, in dB per kHz.
    public var cutoffSteepnessDBPerKHz: Double?
    /// The bits any sample uses: the stored bits less the trailing zero bits every sample has.
    /// Nil for float and lossy samples, and for a file that's all zeros.
    public var effectiveBits: Int?
    /// Whether the first two channels hold the same samples; nil for mono.
    public var identicalChannels: Bool?
    /// The highest sample, in dB of full scale; nil for silence.
    public var peakDBFS: Double?
    /// The highest point between samples too, 4× oversampled, in dB of full scale; nil for
    /// silence.
    public var truePeakDBTP: Double?
    /// Runs of 3 or more samples at full scale, over every channel.
    public var clippedRuns: Int
    /// The DR meters' score, in dB; nil for silence.
    public var dynamicRange: Int?

    public init(
        formatID: String, sampleRateHz: Double, storedBits: Int?, channels: Int, isFloat: Bool,
        durationSeconds: Double, cutoffHz: Double?, cutoffSteepnessDBPerKHz: Double?,
        effectiveBits: Int?, identicalChannels: Bool?, peakDBFS: Double?, truePeakDBTP: Double?,
        clippedRuns: Int, dynamicRange: Int?
    ) {
        self.formatID = formatID
        self.sampleRateHz = sampleRateHz
        self.storedBits = storedBits
        self.channels = channels
        self.isFloat = isFloat
        self.durationSeconds = durationSeconds
        self.cutoffHz = cutoffHz
        self.cutoffSteepnessDBPerKHz = cutoffSteepnessDBPerKHz
        self.effectiveBits = effectiveBits
        self.identicalChannels = identicalChannels
        self.peakDBFS = peakDBFS
        self.truePeakDBTP = truePeakDBTP
        self.clippedRuns = clippedRuns
        self.dynamicRange = dynamicRange
    }
}
