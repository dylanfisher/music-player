import Foundation
import Metadata

/// A file's tag structure, parsed for writing.
enum TagFile {
    case mp4(MP4File)
    case id3(ID3File)
    case flac(FLACFile)

    init(_ reader: ByteReader) throws(ParseFailure) {
        switch try FileFormat(reader) {
        case .mp4: self = .mp4(try MP4File(reader))
        case .flac: self = .flac(try FLACFile(reader))
        case .mp3: self = .id3(try ID3File(reader, container: .mp3))
        case .aiff: self = .id3(try ID3File(reader, container: .aiff))
        case .wav: self = .id3(try ID3File(reader, container: .wav))
        }
    }

    init(path: String) throws(ParseFailure) {
        try self.init(ByteReader(FileSource(path: path)))
    }

    func layout() throws(ParseFailure) -> TagLayout {
        switch self {
        case .mp4(let file): try file.layout()
        case .id3(let file): file.layout()
        case .flac(let file): try file.layout()
        }
    }

    var payload: [Range<Int>] {
        switch self {
        case .mp4(let file): file.payload
        case .id3(let file): [file.payload]
        case .flac(let file): [file.audioStart..<file.size]
        }
    }

    /// The new file for `groups` set to their values in `tags`, and `art`.
    func rewrite(_ groups: [TagGroup], from tags: TrackTags, art: ArtChange?, artOffset: Int?)
        throws(ParseFailure) -> [Segment]
    {
        switch self {
        case .mp4(let file): try file.rewrite(groups, from: tags, art: art)
        case .id3(let file): file.rewrite(groups, from: tags, art: art, artOffset: artOffset)
        case .flac(let file):
            try file.rewrite(groups, from: tags, art: art, artOffset: artOffset)
        }
    }
}

/// Every block of the file at `url` and where its audio is, for the corpus survey and for
/// checking that an edit left the other blocks alone.
public func readTagLayout(at url: URL) throws(MetadataError) -> TagLayout {
    do throws(ParseFailure) {
        return try TagFile(path: url.path).layout()
    } catch {
        throw error.error(path: url.path)
    }
}
