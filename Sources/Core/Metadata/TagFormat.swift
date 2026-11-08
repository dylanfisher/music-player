/// The kind of tag a file holds, which decides how a custom key is spelled in it (ADRs 0128,
/// 0129): Vorbis comments in FLAC, iTunes items in MP4, and ID3 in MP3, AIFF and WAV.
public enum TagFormat: String, CaseIterable, Codable, Sendable {
    case vorbis, mp4, id3

    /// The tag format of a file whose audio is `codec`; nil for DSD, whose tags the writer
    /// can't write.
    public init?(_ codec: TrackAudio.Codec) {
        switch codec {
        case .flac: self = .vorbis
        case .alac, .aac: self = .mp4
        case .mp3, .pcm: self = .id3
        case .dsd: return nil
        }
    }
}
