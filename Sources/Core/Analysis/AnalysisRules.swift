/// Every threshold the analysis and its verdicts use, each defined once (ADR 0115). Set from
/// the generated fixtures and the published cutoffs of common lossy encoders, as the owner has
/// no files to tune them on.
public enum AnalysisRules {
    /// A cutoff is a fall of at least this much in the average spectrum, from the half of
    /// `cutoffSpanHz` below a frequency to the half above it. Music rolls off far slower: even
    /// 12 dB an octave is under 1 dB across a kilohertz at 16 kHz.
    static let cutoffDropDB = 20.0
    static let cutoffSpanHz = 1000.0
    /// Cutoffs are looked for from here up; below it a fall is the music, not an encoder.
    static let cutoffSearchFromHz = 5000.0

    /// A lossless file with a cutoff at or under this, and a Nyquist frequency of at least
    /// `lossyMinimumNyquistHz`, is suspect: a 320k MP3 or AAC stops near 20 kHz, a CD's own
    /// anti-alias filter above it.
    static let lossyCutoffHz = 20_500.0
    static let lossyMinimumNyquistHz = 22_050.0
    /// A file at a rate over this whose content stops at or under `upsampledCutoffHz` is
    /// suspect: 44.1 or 48 kHz audio at a higher rate.
    static let upsampledMinimumRateHz = 48_000.0
    static let upsampledCutoffHz = 24_000.0
    /// A run of at least this many samples at full scale counts as clipped.
    static let clippedRunSamples = 3
    /// The verdict needs at least this many runs; one or two can be a single loud transient.
    static let clippedRunsForVerdict = 10
    /// Float samples at or over this count as full scale: the largest 16-bit code.
    static let clippedFloatLevel = Float(32767) / 32768

    /// The DR score's blocks, and the share of the loudest it takes the RMS of.
    static let dynamicRangeBlockSeconds = 3.0
    static let dynamicRangeLoudestShare = 0.2

    /// What two files have to differ by for the Spectrum window's differences to say so (ADR
    /// 0120). Cutoffs: under this a fall is the same filter measured twice.
    static let differentCutoffHz = 1000.0
    /// The overall level, from the average spectra: about the smallest change a listener
    /// hears.
    static let differentLevelDB = 1.0
    /// The level is summed from here up, as rows under it are a DC offset, not sound.
    static let levelFromHz = 20.0
    /// A band against the midrange: bass from `levelFromHz` up to it, treble from it up to
    /// `topBandFromHz`.
    static let differentBandDB = 1.0
    static let midrangeHz = 250.0...4000.0
    /// The top band, from here to where both files stop, where lossy encoders cut and
    /// noise-shaped dither goes.
    static let topBandFromHz = 16_000.0
    /// DR scores: one apart is the meters' rounding.
    static let differentDynamicRange = 2
    /// Lengths: under this is a gap or a fade trimmed.
    static let differentLengthSeconds = 2.0
    /// Sizes, as a share of the larger: under this is tags and art.
    static let differentSizeShare = 0.05
    /// A true peak over this is over full scale between samples.
    static let overFullScaleDBTP = 0.0

    /// The most files Show Spectrum compares, and `music-player analyze` takes.
    public static let comparedFiles = 8
}
