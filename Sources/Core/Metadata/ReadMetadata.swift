import Foundation

/// Reads the tags, audio properties and art location of the file at `url`, without decoding
/// audio or reading art. Reads FLAC, MP4 (ALAC and AAC), MP3, WAV and AIFF, choosing by content,
/// not extension.
public func readMetadata(at url: URL, hints: ReadHints = .all) throws(MetadataError) -> ParsedFile {
    do throws(ParseFailure) {
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let source = try FileSource(path: url.path, hints: hints)
        let opened = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var parsed = try parse(ByteReader(source))
        parsed.openSeconds = Double(opened - started) / 1e9
        return parsed
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
    let metadata: TrackMetadata
    switch try FileFormat(reader) {
    case .flac: metadata = try parseFLAC(reader)
    case .mp4: metadata = try parseMP4(reader)
    case .wav: metadata = try parseWAV(reader)
    case .aiff: metadata = try parseAIFF(reader)
    case .mp3: metadata = try parseMP3(reader)
    }
    return ParsedFile(
        metadata: metadata, warnings: reader.warnings, bytesRead: reader.bytesRead,
        readCount: reader.readCount, readSeconds: reader.readSeconds)
}

/// The container a file's first bytes announce, which picks its parser and its tag writer.
package enum FileFormat: String, Sendable {
    case flac, mp4, mp3, wav, aiff

    package init(_ reader: ByteReader) throws(ParseFailure) {
        guard reader.size > 0 else {
            throw ParseFailure(kind: .unrecognizedFormat, offset: nil, detail: "the file is empty")
        }
        let start = try reader.bytes(0..<min(12, reader.size))
        if start.matches(flacMarker, at: 0) {
            self = .flac
        } else if start.matches("ftyp", at: 4) {
            self = .mp4
        } else if start.matches(riffFormID, at: 0), start.matches("WAVE", at: 8) {
            self = .wav
        } else if start.matches(aiffFormID, at: 0),
            start.matches("AIFF", at: 8) || start.matches("AIFC", at: 8)
        {
            self = .aiff
        } else if start.matches(id3v2Identifier, at: 0) || MPEGFrameHeader(start, at: 0) != nil {
            self = .mp3
        } else {
            throw ParseFailure(
                kind: .unrecognizedFormat, offset: 0,
                detail: "doesn't start like a FLAC, MP4, MP3, WAV or AIFF file")
        }
    }
}
