import Foundation

/// What the generator wrote, so tests can assert parsers against it. Stored as `manifest.json` at
/// the fixture root.
public struct FixtureManifest: Codable, Equatable, Sendable {
    static let fileName = "manifest.json"

    public var fileCount: Int
    /// Sorted by path.
    public var files: [FixtureFile]
}

public struct FixtureFile: Codable, Equatable, Sendable {
    public enum Container: String, Codable, Sendable { case flac, mp4, mp3, wav, aiff, dsf, dff }
    enum Codec: String, Codable, Sendable { case flac, alac, aac, mp3, pcm, dsd }
    public enum TagFormat: String, Codable, Sendable {
        case vorbisComment, mp4, id3v22, id3v23, id3v24, riffInfo
    }

    /// Relative to the fixture root.
    public var path: String
    public var byteCount: Int
    public var container: Container
    /// Nil for files broken in their structure.
    var audio: AudioProperties?
    /// The tag blocks in the file, in file order. Each holds the same values.
    public var tagFormats: [TagFormat]
    /// What a parser should read. Nil when the file is untagged or broken in its structure; for a
    /// file with a bad field, the tags without that field. Fields a format can't hold are nil,
    /// and ID3v2.2 and 2.3 hold only the year of `date`.
    public var tags: FixtureTags?
    public var art: FixtureArt?
    /// Set for a file that's broken on purpose. A parser must reject it or read what it can,
    /// without crashing or hanging. A file whose damage `isFieldLevel` must read, without the
    /// bad field.
    public var malformation: Malformation?
}

struct AudioProperties: Codable, Equatable, Sendable {
    var codec: FixtureFile.Codec
    var sampleRateHz: Int
    /// Nil for lossy codecs.
    var bitsPerSample: Int?
    var channels: Int
    /// For AAC, without the encoder's priming and remainder frames. For MP3, which carries no
    /// length, every frame's samples.
    var lengthFrames: Int
}

public struct FixtureTags: Codable, Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    /// "1997" or "1997-05-12".
    public var date: String?
    public var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    public var compilation: Bool
    public var comment: String?
}

/// Embedded front-cover art.
public struct FixtureArt: Codable, Equatable, Sendable {
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var byteCount: Int
}

public enum Malformation: String, Codable, Sendable, CaseIterable {
    /// A FLAC file cut off partway through its audio.
    case truncated
    /// Zero bytes.
    case empty
    /// Random bytes with a `.flac` extension.
    case garbage
    /// A FLAC metadata block whose length runs past the end of the file.
    case flacBlockPastEnd
    /// A Vorbis comment whose length runs past its block.
    case vorbisCommentPastBlock
    /// An ID3v2 tag whose size runs past the end of the file.
    case id3TagPastEnd
    /// An ID3v2 frame whose size runs past the end of its tag.
    case id3FramePastTag
    /// An MP4 atom smaller than its own header, which loops forever if read naively.
    case mp4AtomTooSmall
    /// An MP4 atom that runs past the end of its parent.
    case mp4AtomPastParent
    /// A WAV chunk whose size runs past the end of the file.
    case riffChunkPastEnd
    /// A FLAC whose Vorbis TRACKNUMBER is "A" instead of a number, in an otherwise valid file.
    case unreadableTrackNumber

    /// Damage to one tag field, not to the file's structure.
    public var isFieldLevel: Bool { self == .unreadableTrackNumber }
}

/// Reads the manifest of a generated fixture library.
public func loadManifest(in root: URL) throws -> FixtureManifest {
    try JSONDecoder().decode(
        FixtureManifest.self,
        from: Data(contentsOf: root.appendingPathComponent(FixtureManifest.fileName)))
}
