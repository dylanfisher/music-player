import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

/// The fixture library's sample of each container, tag layout and art, as bytes.
private let samples = Result { () throws -> [(path: String, data: Data)] in
    let (root, manifest) = try fixtureLibrary.get()
    var seen = Set<String>()
    var samples: [(String, Data)] = []
    for file in manifest.files where file.malformation == nil {
        let key = "\(file.container) \(file.tagFormats) \(file.art != nil)"
        guard seen.insert(key).inserted else { continue }
        samples.append((file.path, try Data(contentsOf: root.appendingPathComponent(file.path))))
    }
    return samples
}

@Test func everyTruncationFailsOrParses() throws {
    for (path, data) in try samples.get() {
        // Every cut in the header region, where the structure is, then coarser steps.
        let cuts =
            Array(0..<min(data.count, 600)) + Array(stride(from: 600, to: data.count, by: 97))
        for cut in cuts {
            let kind = failure(data.prefix(cut))?.kind
            #expect(kind != .unreadable, "\(path) cut at \(cut)")
        }
    }
}

@Test func oversizedLengthsAreMalformedNotAllocated() {
    let huge = 0x7FFF_FFF0
    let cases: [(String, Data)] = [
        ("FLAC picture", flac([(0, streamInfo()), (6, bigEndian32(3) + bigEndian32(huge))])),
        (
            "FLAC picture data",
            flac([
                (0, streamInfo()),
                (
                    6,
                    flacPicture(image: Data(count: 8)).dropLast(12) + bigEndian32(huge)
                        + Data(count: 8)
                ),
            ])
        ),
        ("Vorbis vendor", flac([(0, streamInfo()), (4, littleEndian32(huge))])),
        ("Vorbis count", flac([(0, streamInfo()), (4, littleEndian32(0) + littleEndian32(huge))])),
        (
            "MP4 64-bit size",
            atom("ftyp", ascii("M4A ")) + bigEndian32(1) + ascii("moov")
                + Data(repeating: 0x7F, count: 8)
        ),
        (
            "ID3 extended header",
            id3Tag(version: 3, flags: 0x40, [], extendedHeader: bigEndian32(huge))
        ),
        (
            "WAV fmt",
            riffForm("WAVE", chunks: ascii("fmt ") + littleEndian32(huge) + wavFormat(), .little)
        ),
        (
            "AIFF COMM",
            riffForm("AIFF", chunks: ascii("COMM") + bigEndian32(huge) + aiffCommon(), .big)
        ),
        ("RIFF form", ascii("RIFF") + littleEndian32(huge) + ascii("WAVE")),
    ]
    for (name, data) in cases {
        let source = MemorySource(data)
        var thrown: ParseFailure?
        do throws(ParseFailure) {
            _ = try parse(ByteReader(source))
        } catch {
            thrown = error
        }
        #expect(thrown?.kind == .malformed, "\(name): \(String(describing: thrown))")
        #expect(thrown?.offset != nil, "\(name)")
        #expect(
            source.reads.allSatisfy { $0.count <= max(data.count, ByteReader.minimumReadBytes) })
    }
}

@Test func garbageInsideValidBlocksFailsOrParses() {
    var random = SplitMix64(seed: 0x6761_7262_6167_65)
    for _ in 0..<200 {
        let garbage = Data(
            (0..<Int.random(in: 0..<300, using: &random)).map { _ in
                UInt8.random(in: 0...255, using: &random)
            })
        let files = [
            flac([(0, streamInfo()), (4, garbage)]),
            flac([(0, streamInfo()), (6, garbage)]),
            flac([(0, garbage)]),
            mp4File(
                moov(
                    entry: alacEntry(rate: 44_100, channels: 2, bits: 16), timescale: 44_100,
                    duration: 10, items: garbage)),
            mp4File(moov(entry: garbage, timescale: 44_100, duration: 10, items: nil)),
            id3Tag([garbage]) + mpegFrames(2),
            id3Tag(version: 4, [id3Frame("APIC", garbage, version: 4)]) + mpegFrames(2),
            id3Tag([id3Frame("COMM", garbage), id3Frame("TCON", garbage)]) + mpegFrames(2),
            riffForm("WAVE", chunks: riffChunk("fmt ", garbage, .little), .little),
            riffForm(
                "WAVE",
                chunks: riffChunk("fmt ", wavFormat(), .little) + riffChunk("data", Data(), .little)
                    + riffChunk("LIST", ascii("INFO") + garbage, .little), .little),
            riffForm("AIFF", chunks: riffChunk("COMM", garbage, .big), .big),
            garbage,
        ]
        for file in files {
            // Typed throws: anything thrown is a ParseFailure, so not crashing is the check.
            _ = failure(file)
        }
    }
}

@Test func garbageNeverReadsAsAFormat() {
    let error = failure(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) }))
    #expect(error?.kind == .unrecognizedFormat)
    #expect(failure(Data())?.kind == .unrecognizedFormat)
}

@Test func artPastTheEndOfAChangedFileIsMalformed() throws {
    let art = EmbeddedArt(offset: 10, byteCount: 100, mimeType: "image/png", unsynchronised: false)
    let error = try withFile(Data(count: 50)) { url in
        #expect(throws: MetadataError.self) { try readArt(art, at: url) }
    }
    #expect(error?.kind == .malformed)
}

/// Structures the fixtures don't write, for the fuzz test to damage too.
private let handBuilt: [Data] = [
    id3Tag(
        version: 3, flags: 0xC0,
        [
            id3Frame("TIT2", id3Text("ÿ title", encoding: 1)),
            id3Frame("APIC", Data([0]) + ascii("image/png\0") + Data([3, 0, 0xFF, 0xD8])),
        ],
        padding: 4, extendedHeader: bigEndian32(6) + Data(count: 6))
        + mpegFrames(3),
    id3Tag(
        version: 4, flags: 0x10,
        [
            id3Frame("TCON", id3Text("(17)", encoding: 3), version: 4),
            id3Frame("COMM", Data([3]) + ascii("eng\0text"), version: 4, flags: 0x43),
        ]) + mpegFrames(3),
    Data(mpeg1Header) + Data(count: 32) + ascii("Xing") + bigEndian32(1) + bigEndian32(100)
        + Data(count: 369)
        + mpegFrames(2),
    mp4File(
        moov(
            entry: mp4aEntry(audioSpecificConfig: [0x11, 0x90]), timescale: 48_000, duration: 9600,
            items: ilstItem("trkn", code: 0, Data([0, 0, 0, 1, 0, 2, 0, 0]))
                + ilstItem("gnre", code: 0, Data([0, 18]))),
        moovFirst: false),
    riffForm(
        "AIFC",
        chunks: riffChunk("COMM", aiffCommon() + ascii("sowt") + Data([0, 0]), .big)
            + riffChunk("SSND", Data(count: 8), .big), .big),
]

/// Seeded byte flips over a sample of every fixture kind and the hand-built files. Most flips land
/// in tag text or audio and parse; the rest must fail with a ParseFailure, never trap or hang.
@Test func fuzzedFilesFailOrParse() throws {
    var random = SplitMix64(seed: 0x6675_7A7A)
    var failures = 0
    var parses = 0
    for data in try samples.get().map(\.data) + handBuilt {
        for _ in 0..<300 {
            var mutant = data
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                // Half the flips go in the first kilobyte, where the headers are.
                let limit = random.chance(0.5) ? min(1024, mutant.count) : mutant.count
                let index = Int.random(in: 0..<limit, using: &random)
                mutant[index] ^= UInt8.random(in: 1...255, using: &random)
            }
            if failure(mutant) == nil { parses += 1 } else { failures += 1 }
        }
    }
    // Both outcomes happen, or the flips aren't reaching the parsers.
    #expect(failures > 0)
    #expect(parses > 0)
}

/// Fields too short for the ranges computed from them: each once trapped on an inverted range.
@Test func blocksTooShortForTheirFieldsAreMalformed() {
    let alac = alacEntry(rate: 44_100, channels: 2, bits: 16)
    func withItems(_ items: Data) -> Data {
        mp4File(moov(entry: alac, timescale: 44_100, duration: 10, items: items))
    }
    let cases: [(String, Data)] = [
        ("short data atom", withItems(atom("\u{A9}nam", atom("data", Data(count: 2))))),
        ("short mean atom", withItems(atom("----", atom("mean", Data(count: 2))))),
        (
            "short sample entry",
            mp4File(
                moov(entry: atom("alac", Data(count: 4)), timescale: 1, duration: 1, items: nil))
        ),
        (
            "short stsd",
            mp4File(
                atom(
                    "moov",
                    atom(
                        "trak",
                        atom(
                            "mdia",
                            mediaHeader(timescale: 1, duration: 1) + handler("soun")
                                + atom("minf", atom("stbl", atom("stsd", Data(count: 2))))))))
        ),
        ("short RIFF form", ascii("RIFF") + littleEndian32(2) + ascii("WAVE")),
        ("short AIFF form", ascii("FORM") + bigEndian32(2) + ascii("AIFF")),
    ]
    for (name, data) in cases {
        #expect(failure(data)?.kind == .malformed, "\(name)")
    }
}
