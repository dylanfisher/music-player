import Foundation

/// Reads the tags, audio properties and art location of the file at `url`, without decoding
/// audio or reading art. Reads FLAC, MP4 (ALAC and AAC), MP3, WAV and AIFF, choosing by content,
/// not extension.
public func readMetadata(at url: URL) throws(MetadataError) -> ParsedFile {
    do throws(ParseFailure) {
        return try parse(ByteReader(try FileSource(path: url.path)))
    } catch {
        throw error.error(path: url.path)
    }
}

/// The image bytes of `art`, as recorded by `readMetadata` for the same file.
public func readArt(_ art: EmbeddedArt, at url: URL) throws(MetadataError) -> Data {
    do throws(ParseFailure) {
        let source = try FileSource(path: url.path)
        guard art.offset >= 0, art.byteCount >= 0, art.byteCount <= source.size - art.offset
        else {
            throw .malformed(
                at: art.offset,
                "art of \(art.byteCount) bytes runs past the end of the file (\(source.size)"
                    + " bytes); the file changed since it was read")
        }
        let bytes = try source.read(art.offset..<art.offset + art.byteCount)
        return Data(art.unsynchronised ? UnsyncEscapes.decode(bytes).0 : bytes)
    } catch {
        throw error.error(path: url.path)
    }
}

/// Picks the parser from the file's first bytes.
func parse(_ reader: ByteReader) throws(ParseFailure) -> ParsedFile {
    guard reader.size > 0 else {
        throw ParseFailure(kind: .unrecognizedFormat, offset: nil, detail: "the file is empty")
    }
    let start = try reader.bytes(0..<min(12, reader.size))
    let metadata: TrackMetadata
    if start.matches("fLaC", at: 0) {
        metadata = try parseFLAC(reader)
    } else if start.matches("ftyp", at: 4) {
        metadata = try parseMP4(reader)
    } else if start.matches("RIFF", at: 0), start.matches("WAVE", at: 8) {
        metadata = try parseWAV(reader)
    } else if start.matches("FORM", at: 0),
        start.matches("AIFF", at: 8) || start.matches("AIFC", at: 8)
    {
        metadata = try parseAIFF(reader)
    } else if start.matches("ID3", at: 0) || MPEGFrameHeader(start, at: 0) != nil {
        metadata = try parseMP3(reader)
    } else {
        throw ParseFailure(
            kind: .unrecognizedFormat, offset: 0,
            detail: "doesn't start like a FLAC, MP4, MP3, WAV or AIFF file")
    }
    return ParsedFile(
        metadata: metadata, bytesRead: reader.bytesRead, readCount: reader.readCount)
}
