import Foundation

/// An MPEG audio Layer III frame header.
struct MPEGFrameHeader {
    var sampleRateHz: Int
    var channels: Int
    var bitRate: Int
    var samplesPerFrame: Int
    /// Including the header.
    var byteCount: Int
    /// Bytes of side information after the header, where a Xing/Info header starts.
    var sideInfoBytes: Int
    /// Two CRC bytes sit between the header and the side information when the protection bit is 0.
    var crcBytes: Int

    /// Nil unless `bytes` at `offset` hold a valid Layer III header: an 11-bit sync, a known
    /// version, and a bit rate and sample rate that aren't reserved or "free".
    init?(_ bytes: Bytes, at offset: Int) {
        guard let b0 = try? bytes.uint8(offset), let b1 = try? bytes.uint8(offset + 1),
            let b2 = try? bytes.uint8(offset + 2), let b3 = try? bytes.uint8(offset + 3),
            b0 == 0xFF, b1 & 0xE0 == 0xE0
        else { return nil }
        let version = b1 >> 3 & 3  // 0 MPEG-2.5, 2 MPEG-2, 3 MPEG-1
        let layer = b1 >> 1 & 3  // 1 Layer III
        let bitRateIndex = Int(b2 >> 4)
        let rateIndex = Int(b2 >> 2 & 3)
        guard version != 1, layer == 1, bitRateIndex != 0, bitRateIndex != 15, rateIndex != 3
        else { return nil }
        let isMPEG1 = version == 3
        let mono = b3 >> 6 == 3
        bitRate = (isMPEG1 ? mpeg1BitRates : mpeg2BitRates)[bitRateIndex] * 1000
        sampleRateHz =
            [44_100, 48_000, 32_000][rateIndex] >> (version == 3 ? 0 : version == 2 ? 1 : 2)
        channels = mono ? 1 : 2
        samplesPerFrame = isMPEG1 ? 1152 : 576
        byteCount = samplesPerFrame / 8 * bitRate / sampleRateHz + Int(b2 >> 1 & 1)
        sideInfoBytes = isMPEG1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        crcBytes = b1 & 1 == 0 ? 2 : 0
    }

    /// The average frame length, since padding adds a byte to some frames.
    var averageByteCount: Double {
        Double(samplesPerFrame / 8 * bitRate) / Double(sampleRateHz)
    }
}

private let mpeg1BitRates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
private let mpeg2BitRates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

/// How far past the tag to look for the first frame.
private let frameSearchBytes = 64 * 1024

/// MP3: an optional ID3v2 tag, then MPEG audio frames. The length comes from a Xing/Info or VBRI
/// header in the first frame when there is one, otherwise from the file size at the first frame's
/// bit rate. ID3v1 and APE tags at the end aren't read.
func parseMP3(_ reader: ByteReader) throws(ParseFailure) -> TrackMetadata {
    let first = try firstMP3Frame(reader)
    let header = first.header
    let audioBytes = reader.size - (first.audioStart + first.frameOffset)
    let frames =
        try storedFrameCount(first.frame, header)
        ?? Int((Double(audioBytes) / header.averageByteCount).rounded())
    return TrackMetadata(
        tags: first.tag?.tags ?? TrackTags(),
        audio: TrackAudio(
            codec: .mp3, sampleRateHz: header.sampleRateHz, bitsPerSample: nil,
            channels: header.channels, lengthFrames: frames * header.samplesPerFrame),
        art: first.tag?.art)
}

/// The length in samples per channel that the MP3 at `url` states in a Xing/Info or VBRI
/// header, or nil without one, when its length is only an estimate from the file size, which a
/// VBR file can miss by seconds. Decoders may estimate even when it's stated.
public func mp3StatedLengthFrames(at url: URL) throws(MetadataError) -> Int? {
    do throws(ParseFailure) {
        let first = try firstMP3Frame(ByteReader(try FileSource(path: url.path)))
        return try storedFrameCount(first.frame, first.header).map {
            $0 * first.header.samplesPerFrame
        }
    } catch {
        throw error.error(path: url.path)
    }
}

private func storedFrameCount(_ frame: Bytes, _ header: MPEGFrameHeader) throws(ParseFailure)
    -> Int?
{
    if let count = try xingFrameCount(frame, header) { return count }
    return try vbriFrameCount(frame, header)
}

/// The ID3v2 tag, if any, and the first MPEG frame after it, with the bytes from there.
private func firstMP3Frame(_ reader: ByteReader) throws(ParseFailure) -> (
    tag: ID3v2Tag?, audioStart: Int, frameOffset: Int, header: MPEGFrameHeader, frame: Bytes
) {
    var tag: ID3v2Tag?
    var audioStart = 0
    if try reader.bytes(0..<min(3, reader.size)).matches(id3v2Identifier, at: 0) {
        tag = try parseID3v2(reader, at: 0, end: reader.size, container: wholeFileName)
        audioStart = tag!.byteCount
    }

    let searchEnd = min(reader.size, audioStart + frameSearchBytes)
    let area = try reader.bytes(audioStart..<searchEnd)
    var found: (offset: Int, header: MPEGFrameHeader)?
    for offset in 0..<area.count {
        guard let header = MPEGFrameHeader(area, at: offset) else { continue }
        // A real frame is followed by another, or by the end of the file.
        let next = offset + header.byteCount
        if audioStart + next >= reader.size || MPEGFrameHeader(area, at: next) != nil
            || next + 4 > area.count
        {
            found = (offset, header)
            break
        }
    }
    guard let (frameOffset, header) = found else {
        throw .malformed(
            at: audioStart,
            "no MPEG Layer III frame in the \(area.count) bytes after the start of the audio")
    }

    return (tag, audioStart, frameOffset, header, try area.suffix(from: frameOffset))
}

/// "Xing" (VBR) or "Info" (CBR) after the side information: flags, then the frame count when
/// flag 1 is set. The count excludes this frame, which decodes as silence. A count of 0 is a
/// writer that never filled it in, so it counts as absent.
private func xingFrameCount(_ frame: Bytes, _ header: MPEGFrameHeader) throws(ParseFailure) -> Int?
{
    let offset = 4 + header.crcBytes + header.sideInfoBytes
    guard frame.matches("Xing", at: offset) || frame.matches("Info", at: offset) else {
        return nil
    }
    guard try frame.uint32BE(offset + 4) & 1 != 0 else { return nil }
    let count = Int(try frame.uint32BE(offset + 8))
    return count == 0 ? nil : count
}

/// Fraunhofer's "VBRI", 32 bytes after the header: version, delay, quality, byte count, then the
/// frame count.
private func vbriFrameCount(_ frame: Bytes, _ header: MPEGFrameHeader) throws(ParseFailure) -> Int?
{
    let offset = 36 + header.crcBytes
    guard frame.matches("VBRI", at: offset) else { return nil }
    return Int(try frame.uint32BE(offset + 14))
}
