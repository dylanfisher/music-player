import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

/// Hand-built files with the sizes, offsets and text a hostile file would hold, one set per
/// parser (ADR 0025). Each must end in a typed failure or warnings, never a trap, and never read
/// more than the file.
private enum Outcome {
    case fails(MetadataError.Kind)
    /// Reads, with a warning of this kind.
    case warns(MetadataWarning.Kind)
    /// Reads: a count or a length the parser can't judge as wrong, or damage inside a block the
    /// file holds, which spoils only a field.
    case parses
}

private let alac = alacEntry(rate: 44_100, channels: 2, bits: 16)

private func withItems(_ items: Data) -> Data {
    mp4File(moov(entry: alac, timescale: 44_100, duration: 10, items: items))
}

private func id3Header(version: UInt8 = 3, size: [UInt8]) -> Data {
    ascii("ID3") + Data([version, 0, 0]) + Data(size)
}

/// A version 1 `mdhd`, whose duration is 64 bits.
private func longMediaHeader(duration: UInt64) -> Data {
    var body = Data([1, 0, 0, 0]) + Data(count: 16) + bigEndian32(44_100)
    body.appendBigEndian(duration)
    return atom("mdhd", body + Data(count: 4))
}

private let dsdChannels = (0..<2).map { dsdTone(samples: 8 * 4096, rateHz: 2_822_400, channel: $0) }
private let dsf = dsfFile(rateHz: 2_822_400, channels: dsdChannels)
private let dff = dffFile(rateHz: 2_822_400, channels: dsdChannels)

/// `file` with the little-endian 32- or 64-bit field at `offset` set to `value`.
private func patched(_ file: Data, at offset: Int, _ value: UInt64, bytes: Int = 8) -> Data {
    var file = file
    for index in 0..<bytes {
        file[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
    }
    return file
}

/// `file` with the big-endian 64-bit field at `offset` set to `value`.
private func patchedBE(_ file: Data, at offset: Int, _ value: UInt64) -> Data {
    var file = file
    for index in 0..<8 {
        file[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (7 - index)))
    }
    return file
}

private let hostileFiles: [(String, Data, Outcome)] = [
    // DSF
    ("DSF header size of UInt64.max", patched(dsf, at: 4, .max), .fails(.malformed)),
    ("DSF file size past the end", patched(dsf, at: 12, .max), .warns(.truncated)),
    ("DSF metadata pointer past the end", patched(dsf, at: 20, .max), .warns(.truncated)),
    ("DSF metadata pointer inside the header", patched(dsf, at: 20, 8), .warns(.unreadableField)),
    ("DSF metadata pointer inside the audio", patched(dsf, at: 20, 100), .warns(.unreadableField)),
    (
        "DSF metadata pointer at bytes that aren't a tag",
        patched(dsf + Data(repeating: 0x41, count: 64), at: 20, UInt64(dsf.count)),
        .warns(.unreadableField)
    ),
    ("DSF with no channels", patched(dsf, at: 52, 0, bytes: 4), .fails(.malformed)),
    (
        "DSF with 4 billion channels", patched(dsf, at: 52, 0xFFFF_FFFF, bytes: 4),
        .fails(.unsupported)
    ),
    ("DSF at a PCM rate", patched(dsf, at: 56, 44_100, bytes: 4), .fails(.unsupported)),
    ("DSF block size of 0", patched(dsf, at: 72, 0, bytes: 4), .fails(.malformed)),
    ("DSF block size of 4 GB", patched(dsf, at: 72, 0xFFFF_FFFF, bytes: 4), .fails(.malformed)),
    ("DSF sample count of UInt64.max", patched(dsf, at: 64, .max), .parses),
    ("DSF data size of UInt64.max", patched(dsf, at: 84, .max), .warns(.truncated)),
    ("DSF data size smaller than its header", patched(dsf, at: 84, 3), .fails(.malformed)),
    ("DSF cut inside fmt", dsf.prefix(50), .fails(.malformed)),
    // DSDIFF
    ("DSDIFF form size of UInt64.max", patchedBE(dff, at: 4, .max), .warns(.truncated)),
    ("DSDIFF FVER of UInt64.max", patchedBE(dff, at: 20, .max), .fails(.malformed)),
    ("DSDIFF PROP property past PROP", patchedBE(dff, at: 52, 0x7FFF_FFFF), .fails(.malformed)),
    (
        // CMPR renamed: a property, not the audio, so not clamped to the file.
        "DSDIFF PROP property named like the audio, past PROP",
        patchedBE(
            Data(dff.prefix(86)) + Data("DSD ".utf8) + Data(dff.dropFirst(90)), at: 90, 0x7FFF_FFFF),
        .fails(.malformed)
    ),
    ("DSDIFF cut inside a chunk header", dff.prefix(22), .fails(.malformed)),
    ("DSDIFF audio past the end", dff.prefix(dff.count - 100), .warns(.truncated)),
    // MP4
    (
        "MP4 top-level atom of 4 GB",
        atom("ftyp", ascii("M4A ")) + bigEndian32(0xFFFF_FFFF)
            + ascii("moov"), .fails(.malformed)
    ),
    (
        "MP4 64-bit size of UInt64.max",
        atom("ftyp", ascii("M4A ")) + bigEndian32(1) + ascii("moov")
            + Data(repeating: 0xFF, count: 8), .fails(.malformed)
    ),
    (
        "MP4 64-bit size of Int.max",
        atom("ftyp", ascii("M4A ")) + bigEndian32(1) + ascii("moov") + Data([0x7F])
            + Data(repeating: 0xFF, count: 7), .fails(.malformed)
    ),
    (
        "MP4 64-bit size smaller than its header",
        atom("ftyp", ascii("M4A ")) + bigEndian32(1) + ascii("moov") + Data(count: 7)
            + Data([8]), .fails(.malformed)
    ),
    (
        "MP4 mdhd duration that overflows",
        mp4File(
            atom(
                "moov",
                atom(
                    "trak",
                    atom(
                        "mdia",
                        longMediaHeader(duration: UInt64.max) + handler("soun")
                            + atom("minf", atom("stbl", fullBox("stsd", bigEndian32(1) + alac))))
                ))), .fails(.malformed)
    ),
    (
        "MP4 ALAC rate of 4 GHz for 2^31 seconds",
        mp4File(
            moov(
                entry: alacEntry(rate: 0xFFFF_FFFF, channels: 2, bits: 16), timescale: 1,
                duration: 0x7FFF_FFFF, items: nil)), .parses
    ),
    (
        "MP4 data atom past its item",
        withItems(atom("\u{A9}nam", bigEndian32(0x7FFF_FFF0) + ascii("data"))),
        .parses
    ),
    (
        "MP4 esds descriptor of 256 MB",
        mp4File(
            moov(
                entry: atom(
                    "mp4a",
                    sampleEntryFields(channels: 2, bits: 16, rate: 44_100)
                        + fullBox("esds", Data([3, 0xFF, 0xFF, 0xFF, 0x7F]))),
                timescale: 44_100, duration: 10, items: nil)), .fails(.malformed)
    ),
    // ID3v2 and MPEG audio
    (
        "ID3 tag of 256 MB", id3Header(size: [0x7F, 0x7F, 0x7F, 0x7F]) + mpegFrames(2),
        .fails(.malformed)
    ),
    (
        "ID3v2.3 frame of 4 GB",
        id3Tag([ascii("TIT2") + bigEndian32(0xFFFF_FFFF) + Data(count: 2) + Data(count: 16)])
            + mpegFrames(2), .fails(.malformed)
    ),
    (
        "ID3v2.4 frame size that is neither syncsafe nor plain",
        id3Tag(version: 4, [ascii("TIT2") + Data([0x80, 0x80, 0x80, 0x80, 0, 0]) + Data(count: 8)])
            + mpegFrames(2), .fails(.malformed)
    ),
    (
        "ID3 unsynchronised tag of escapes",
        id3Tag(
            flags: 0x80, [id3Frame("TIT2", Data([0]) + Data(repeating: 0xFF, count: 4096))])
            + mpegFrames(2), .parses
    ),
    (
        "MPEG Xing frame count of 4 billion",
        Data(mpeg1Header) + Data(count: 32) + ascii("Xing") + bigEndian32(1)
            + bigEndian32(0xFFFF_FFFF) + Data(count: 369) + mpegFrames(2),
        .parses
    ),
    // FLAC and Vorbis comments
    (
        "FLAC block of 16 MB", ascii("fLaC") + Data([0x80, 0xFF, 0xFF, 0xFF]) + streamInfo(),
        .fails(.malformed)
    ),
    (
        "Vorbis comment of 4 GB",
        flac([(0, streamInfo()), (4, littleEndian32(0) + littleEndian32(1) + littleEndian32(-1))]),
        .fails(.malformed)
    ),
    (
        "FLAC total of 2^36 - 1 samples at 1 Hz",
        flac([(0, streamInfo(rate: 1, total: 0xF_FFFF_FFFF))]), .parses
    ),
    // WAV and AIFF
    (
        "WAV chunk of 4 GB before data",
        riffForm(
            "WAVE", chunks: ascii("LIST") + littleEndian32(0xFFFF_FFFE) + Data(count: 8), .little),
        .fails(.malformed)
    ),
    (
        "WAV block align of 0",
        riffForm(
            "WAVE",
            chunks: riffChunk("fmt ", wavFormat().prefix(12) + Data(count: 4), .little)
                + riffChunk("data", Data(count: 8), .little), .little), .fails(.malformed)
    ),
    (
        "WAV data chunk of 4 GB",
        riffForm(
            "WAVE",
            chunks: riffChunk("fmt ", wavFormat(), .little) + ascii("data")
                + littleEndian32(0xFFFF_FFF0) + Data(count: 16), .little), .warns(.truncated)
    ),
    (
        "AIFF rate exponent past any Int",
        riffForm(
            "AIFF",
            chunks: riffChunk(
                "COMM",
                aiffCommon().prefix(8) + Data([0x7F, 0xFF]) + Data(repeating: 0xFF, count: 8),
                .big), .big), .fails(.malformed)
    ),
    (
        "AIFF SSND of 4 GB",
        riffForm(
            "AIFF",
            chunks: riffChunk("COMM", aiffCommon(frames: 0xFFFF_FFFF), .big) + ascii("SSND")
                + bigEndian32(0xFFFF_FFF0) + Data(count: 16), .big), .warns(.truncated)
    ),
]

@Test func hostileSizesInEveryParserAreTypedErrors() throws {
    for (name, data, outcome) in hostileFiles {
        let source = MemorySource(data)
        var parsed: ParsedFile?
        var thrown: ParseFailure?
        do throws(ParseFailure) {
            parsed = try parse(ByteReader(source))
        } catch {
            thrown = error
        }
        switch outcome {
        case .fails(let kind):
            #expect(thrown?.kind == kind, "\(name): \(String(describing: thrown))")
            #expect(thrown?.offset != nil, "\(name)")
        case .warns(let kind):
            #expect(
                parsed?.warnings.contains { $0.kind == kind } == true,
                "\(name): \(String(describing: parsed?.warnings)) \(String(describing: thrown))")
        case .parses:
            #expect(thrown == nil, "\(name): \(String(describing: thrown))")
        }
        #expect(source.reads.allSatisfy { $0.upperBound <= data.count }, "\(name)")
        #expect(source.reads.reduce(0) { $0 + $1.count } <= 4 * data.count, "\(name)")
    }
}

/// Text no tagger should write, in each encoding the formats declare.
@Test func hostileTextInEveryEncodingReadsWithWarnings() throws {
    let bidi = "\u{202E}cod.exe\u{202C}"
    let frames: [(String, Data, String?)] = [
        ("invalid UTF-8", Data([3, 0xC3, 0x28, 0xFF]), "Ã(ÿ"),
        ("UTF-8 overlong NUL", Data([3, 0xC0, 0x80]), "À\u{80}"),
        ("lone byte-order mark", Data([1, 0xFF, 0xFE]), nil),
        ("odd UTF-16", Data([1, 0xFF, 0xFE, 0x41, 0x00, 0x42]), nil),
        ("unpaired high surrogate", Data([2, 0xD8, 0x00, 0x00, 0x41]), "\u{FFFD}A"),
        ("unpaired low surrogate", Data([1, 0xFF, 0xFE, 0x00, 0xDC]), "\u{FFFD}"),
        ("NUL inside", id3Text("a\u{0}b", encoding: 3), "a"),
        ("bidi override", id3Text(bidi, encoding: 3), bidi),
        ("escape sequence", id3Text("\u{1B}]0;title\u{07}", encoding: 3), "\u{1B}]0;title\u{07}"),
    ]
    for (name, body, expected) in frames {
        let file = id3Tag(version: 4, [id3Frame("TIT2", body, version: 4)]) + mpegFrames(2)
        var parsed: ParsedFile?
        do throws(ParseFailure) {
            parsed = try parse(file)
        } catch {
            Issue.record("\(name): \(error)")
        }
        if let expected { #expect(parsed?.metadata.tags.title == expected, "\(name)") }
        let isInvalid = !["lone byte-order mark", "NUL inside", "bidi override", "escape sequence"]
            .contains(name)
        #expect(parsed?.warnings.contains { $0.kind == .badText } == isInvalid, "\(name)")
    }
    // Vorbis comments are UTF-8 with lengths, so a NUL can sit inside a value. It's read up to
    // the NUL, as ID3 is, with a warning when text follows it; NULs only at the end are padding.
    let vorbis = flac(
        [
            (0, streamInfo()),
            (4, vorbisComment(["TITLE=a\u{0}b", "ARTIST=\(bidi)", "ALBUM=padded\u{0}\u{0}"])),
        ])
    let parsed = try parse(vorbis)
    #expect(parsed.metadata.tags.title == "a")
    #expect(parsed.metadata.tags.artist == bidi)
    #expect(parsed.metadata.tags.album == "padded")
    #expect(parsed.warnings.map(\.detail) == ["text holds a NUL; read up to it"])
}

@Test func artLongerThanTheMaximumIsRefusedBeforeReading() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hostile-art-\(UUID().uuidString).mp3")
    defer { try? FileManager.default.removeItem(at: url) }
    // An ID3v2.4 tag whose APIC claims more than the maximum, written sparse so the test doesn't
    // write the bytes.
    let imageBytes = maximumArtBytes + 1
    let apic = Data([0]) + ascii("image/png\u{0}") + Data([3, 0])
    var frame = ascii("APIC")
    frame.appendSyncsafe(apic.count + imageBytes)
    frame.append(Data(count: 2))
    var header = ascii("ID3") + Data([4, 0, 0])
    header.appendSyncsafe(frame.count + apic.count + imageBytes)
    try (header + frame + apic).write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(header.count + frame.count + apic.count + imageBytes))
    try handle.seekToEnd()
    try handle.write(contentsOf: mpegFrames(2))
    try handle.close()

    let art = try #require(try readMetadata(at: url).metadata.art)
    #expect(art.byteCount == imageBytes)
    let error = #expect(throws: MetadataError.self) { try readArt(art, at: url) }
    #expect(error?.kind == .unsupported)
    #expect(error?.offset == art.offset)
}

/// A FIFO among the music would block an open for reading until something wrote to it.
@Test func aFIFOOrALinkIsRefusedWithoutBlocking() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("hostile-fifo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fifo = folder.appendingPathComponent("track.flac")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let real = folder.appendingPathComponent("real.flac")
    try flac([(0, streamInfo())]).write(to: real)
    let link = folder.appendingPathComponent("link.flac")
    #expect(symlink(real.path, link.path) == 0)
    for url in [fifo, link] {
        let done = DispatchSemaphore(value: 0)
        let outcome = ThrownError()
        Thread.detachNewThread {
            do throws(MetadataError) {
                _ = try readMetadata(at: url)
            } catch {
                outcome.set(error)
            }
            done.signal()
        }
        try #require(done.wait(timeout: .now() + 5) == .success, "\(url.lastPathComponent) blocked")
        #expect(outcome.error?.kind == .unreadable, "\(url.lastPathComponent)")
    }
    #expect(try readMetadata(at: real).metadata.audio.sampleRateHz == 44_100)
}

/// What the reading thread threw, read once it has signalled.
private final class ThrownError: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MetadataError?
    var error: MetadataError? { lock.withLock { stored } }
    func set(_ error: MetadataError) { lock.withLock { stored = error } }
}

/// Comments and frames of a few bytes each, millions of them in a large enough block, would
/// cost a loop turn and often a warning apiece.
@Test func aFileOfTinyStructuresStopsAtTheBudget() throws {
    let tooMany = ByteReader.maximumSteps + 10
    var comments = littleEndian32(0) + littleEndian32(tooMany)
    for _ in 0..<tooMany { comments += littleEndian32(0) }
    let vorbis = flac([(0, streamInfo()), (4, comments)])
    var frames = Data()
    for _ in 0..<tooMany { frames += ascii("XXXX") + Data(count: 6) }
    let id3 = id3Tag([frames]) + mpegFrames(2)
    for (name, file) in [("Vorbis comments", vorbis), ("ID3 frames", id3)] {
        let thrown = failure(file)
        #expect(thrown?.kind == .malformed, "\(name)")
        #expect(thrown?.detail.contains("more than \(ByteReader.maximumSteps)") == true, "\(name)")
    }
}

@Test func warningsPastTheCapAreCountedInOne() throws {
    let extra = 250
    let fields = Array(repeating: "no equals sign", count: ByteReader.maximumWarnings + extra)
    let parsed = try parse(flac([(0, streamInfo()), (4, vorbisComment(fields))]))
    #expect(parsed.warnings.count == ByteReader.maximumWarnings + 1)
    #expect(parsed.warnings.last?.detail.hasPrefix("\(extra) more warnings, not kept") == true)
    #expect(parsed.warnings.last?.kind == .unreadableField)
}
