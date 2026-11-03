/// The audio stream's format, from the container's headers.
public struct TrackAudio: Equatable, Sendable {
    public enum Codec: String, Sendable {
        case flac, alac, aac, mp3
        /// Integer or floating-point PCM in WAV or AIFF.
        case pcm
        /// 1-bit DSD in DSF or DSDIFF, with `bitsPerSample` 1 and `sampleRateHz` the bit rate.
        case dsd
    }

    public var codec: Codec
    public var sampleRateHz: Int
    /// Nil for lossy codecs.
    public var bitsPerSample: Int?
    public var channels: Int
    /// Frames at `sampleRateHz`. For AAC with an `iTunSMPB` tag, without the encoder's priming and
    /// remainder; for MP3, every frame's samples.
    public var lengthFrames: Int
}
