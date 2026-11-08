import Foundation

/// Reads the tags, audio properties and art location of the file at `url`, without decoding
/// audio or reading art. Reads FLAC, MP4 (ALAC and AAC), MP3, WAV, AIFF, DSF and DSDIFF, choosing
/// by content, not extension. `pictures` lists every embedded picture in
/// `TrackMetadata.pictures`, for the art viewer; without it the list is empty.
public func readMetadata(at url: URL, hints: ReadHints = .all, pictures: Bool = false)
    throws(MetadataError) -> ParsedFile
{
    do throws(ParseFailure) {
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let source = try FileSource(path: url.path, hints: hints)
        let opened = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var parsed = try parse(ByteReader(source, keepsPictures: pictures))
        parsed.openSeconds = Double(opened - started) / 1e9
        return parsed
    } catch {
        throw error.error(path: url.path)
    }
}

/// Files read at once for what the user is waiting to see, so on a NAS they arrive together
/// instead of one after another. One short of the threads the cores run, which leaves the 2015
/// MacBook Pro's 4 threads one for the main thread and playback.
public let filesReadAtOnce = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)

/// The most art `readArt` reads. A length from the file is otherwise bounded only by the file's
/// size; real art is under 2 MB.
let maximumArtBytes = 64 * 1024 * 1024

/// The image bytes of `art`, as recorded by `readMetadata` for the same file.
public func readArt(_ art: EmbeddedArt, at url: URL) throws(MetadataError) -> Data {
    do throws(ParseFailure) {
        return try readArt(art, from: FileSource(path: url.path))
    } catch {
        throw error.error(path: url.path)
    }
}

/// `readArt` from a file already open, as the one `readMetadata`'s parse read, so a caller that
/// wants both opens the file once, or from the file a tag write plans before it's written.
package func readArt(_ art: EmbeddedArt, from source: some ByteSource) throws(ParseFailure)
    -> Data
{
    guard art.byteCount <= maximumArtBytes else {
        throw .unsupported(
            at: art.offset,
            "art of \(art.byteCount) bytes, more than the \(maximumArtBytes) this reads")
    }
    guard art.offset >= 0, art.byteCount >= 0, art.byteCount <= source.size - art.offset
    else {
        throw .malformed(
            at: art.offset,
            "art of \(art.byteCount) bytes runs past the end of the file (\(source.size)"
                + " bytes); the file changed since it was read")
    }
    let range = art.offset..<art.offset + art.byteCount
    guard art.unsynchronised else { return try source.readData(range) }
    return Data(UnsyncEscapes.decode(try source.read(range)).0)
}

/// Picks the parser from the file's first bytes.
package func parse(_ reader: ByteReader) throws(ParseFailure) -> ParsedFile {
    let metadata: TrackMetadata
    switch try FileFormat(reader) {
    case .flac: metadata = try parseFLAC(reader)
    case .mp4: metadata = try parseMP4(reader)
    case .wav: metadata = try parseWAV(reader)
    case .aiff: metadata = try parseAIFF(reader)
    case .mp3: metadata = try parseMP3(reader)
    case .dsf: metadata = try parseDSF(reader)
    case .dff: metadata = try parseDFF(reader)
    }
    return ParsedFile(
        metadata: metadata, warnings: reader.keptWarnings, bytesRead: reader.bytesRead,
        readCount: reader.readCount, readSeconds: reader.readSeconds)
}

/// The container a file's first bytes announce, which picks its parser and its tag writer.
package enum FileFormat: String, Sendable {
    case flac, mp4, mp3, wav, aiff, dsf, dff

    package init(_ reader: ByteReader) throws(ParseFailure) {
        guard reader.size > 0 else {
            throw ParseFailure(kind: .unrecognizedFormat, offset: nil, detail: "the file is empty")
        }
        let start = try reader.bytes(0..<min(16, reader.size))
        if start.matches(flacMarker, at: 0) {
            self = .flac
        } else if start.matches("ftyp", at: 4) {
            self = .mp4
        } else if start.matches(riffFormID, at: 0), start.matches(wavFormType, at: 8) {
            self = .wav
        } else if start.matches(aiffFormID, at: 0),
            start.matches(aiffFormType, at: 8) || start.matches(aifcFormType, at: 8)
        {
            self = .aiff
        } else if start.matches(dsfHeaderID, at: 0) {
            self = .dsf
        } else if start.matches(dffFormID, at: 0), start.matches(dsfHeaderID, at: 12) {
            self = .dff
        } else if start.matches(id3v2Identifier, at: 0) || MPEGFrameHeader(start, at: 0) != nil {
            self = .mp3
        } else {
            throw ParseFailure(
                kind: .unrecognizedFormat, offset: 0,
                detail: "doesn't start like a FLAC, MP4, MP3, WAV, AIFF, DSF or DSDIFF file")
        }
    }
}
