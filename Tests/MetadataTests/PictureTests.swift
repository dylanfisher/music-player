import Foundation
import Testing

@testable import Fixtures
@testable import Metadata

// Every picture a file embeds, for the art viewer to step through (53.3).

/// Three made-up images, told apart by their bytes.
private let images = (1...3).map { Data(repeating: UInt8($0), count: 40 + $0) }

/// Each picture's bytes, read back from the file through the URL entry points.
private func pictureBytes(_ file: Data) throws -> [Data] {
    try withFile(file) { url in
        try readMetadata(at: url).metadata.pictures.map { try readArt($0.art, at: url) }
    }
}

@Test func flacListsEveryPictureWithItsTypeAndKeepsTheFrontAsTheArt() throws {
    let file = flac([
        (0, streamInfo()), (6, flacPicture(type: 4, image: images[0])),
        (6, flacPicture(type: 3, image: images[1])), (6, flacPicture(type: 6, image: images[2])),
    ])
    let metadata = try parse(file).metadata
    #expect(metadata.pictures.map(\.type) == [4, 3, 6])
    #expect(metadata.pictures.map(\.typeName) == ["Back Cover", "Front Cover", "Media"])
    #expect(metadata.art == metadata.pictures[1].art)
    #expect(try pictureBytes(file) == images)
}

@Test func id3ListsEveryPictureWithItsType() throws {
    func apic(_ type: UInt8, _ description: String, _ image: Data) -> Data {
        id3Frame("APIC", Data([0]) + ascii("image/png\0") + Data([type]) + ascii(description)
            + Data([0]) + image)
    }
    let file =
        id3Tag([apic(3, "front", images[0]), apic(4, "back", images[1]), apic(0, "", images[2])])
        + mpegFrames(4)
    let metadata = try parse(file).metadata
    #expect(metadata.pictures.map(\.typeName) == ["Front Cover", "Back Cover", "Other"])
    #expect(metadata.art == metadata.pictures[0].art)
    #expect(try pictureBytes(file) == images)
}

@Test func mp4ListsEveryCoverWithNoType() throws {
    let covers = atom(
        "covr",
        images.map { atom("data", bigEndian32(13) + bigEndian32(0) + $0) }.reduce(Data(), +))
    let file = mp4File(
        moov(
            entry: alacEntry(rate: 44_100, channels: 2, bits: 16), timescale: 44_100,
            duration: 4410, items: covers))
    let metadata = try parse(file).metadata
    let types: [UInt32?] = metadata.pictures.map(\.type)
    #expect(types == [nil, nil, nil])
    let names: [String?] = metadata.pictures.map(\.typeName)
    #expect(names == [nil, nil, nil])
    #expect(metadata.art == metadata.pictures[0].art)
    #expect(try pictureBytes(file) == images)
}

@Test func aTypePastTheNamedOnesIsOther() {
    let art = EmbeddedArt(offset: 0, byteCount: 1, mimeType: "image/png", unsynchronised: false)
    #expect(EmbeddedPicture(art: art, type: 20).typeName == "Publisher Logo")
    #expect(EmbeddedPicture(art: art, type: 21).typeName == "Other")
}
