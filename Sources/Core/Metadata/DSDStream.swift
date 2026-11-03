/// Where a DSD file's 1-bit audio is and how it's laid out, read from its header without reading
/// the audio. The DoP reader plays from it (ADR 0064).
struct DSDStream: Equatable, Sendable {
    enum Interleave: Equatable, Sendable {
        /// DSF: each channel's bytes in blocks of `blockBytes`, one block of each channel in turn.
        case blocks(blockBytes: Int)
        /// DSDIFF: one byte of each channel in turn.
        case bytes
    }

    var rateHz: Int
    var channels: Int
    /// The file offset of the first audio byte.
    var dataStart: Int
    /// DSD samples (bits) per channel: the length the header states, cut to the bytes present.
    var samplesPerChannel: Int
    var interleave: Interleave
    /// DSF stores each byte's oldest bit lowest; DSDIFF stores it highest.
    var lsbFirst: Bool

    var bytesPerChannel: Int { (samplesPerChannel + 7) / 8 }

    var audio: TrackAudio {
        TrackAudio(
            codec: .dsd, sampleRateHz: rateHz, bitsPerSample: 1, channels: channels,
            lengthFrames: samplesPerChannel)
    }
}

/// The most channels a DSD file may have: DSF allows 6, and DSDIFF files hold at most 5.1.
let maximumDSDChannels = 6

/// The DSD stream of a DSF or DSDIFF file; any other format is unsupported.
func dsdStream(_ reader: ByteReader) throws(ParseFailure) -> DSDStream {
    switch try FileFormat(reader) {
    case .dsf: try dsfLayout(reader).stream
    case .dff: try dffLayout(reader).stream
    case .flac, .mp4, .mp3, .wav, .aiff: throw .unsupported(at: 0, "not a DSF or DSDIFF file")
    }
}

/// Checks the channel count and rate a DSD header states.
func checkDSDFormat(channels: Int, rateHz: Int, at offset: Int, _ form: String)
    throws(ParseFailure)
{
    guard channels > 0 else { throw .malformed(at: offset, "\(form) with no channels") }
    guard channels <= maximumDSDChannels else {
        throw .unsupported(
            at: offset, "\(form) with \(channels) channels, more than \(maximumDSDChannels)")
    }
    guard dsdMultiplier(rateHz) != nil else {
        throw .unsupported(at: offset, "\(form) at \(rateHz) Hz, which isn't a DSD rate")
    }
}

/// Warns once that the file is cut short, as the WAV and AIFF forms do.
func warnTruncated(_ reader: ByteReader, at offset: Int, _ detail: String) {
    guard !reader.warnings.contains(where: { $0.kind == .truncated }) else { return }
    reader.warn(.truncated, at: offset, detail)
}
