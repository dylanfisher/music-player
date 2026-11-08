import CoreGraphics
import Foundation
import HTTPSClient
import ImageIO
import Testing

@testable import Discogs
@testable import Fixtures
@testable import Metadata
@testable import Settings
@testable import TagWriter

// A release's primary image as the files' cover (ADR 0140): fetched, checked, and written by
// TagWriter in the same batch as the tags. Only copies in a temp folder are written, and the
// images are generated, never downloaded.

/// The fixture generator's covers: a JPEG and a PNG.
private let images = Result { try makeArtwork() }

private func image(_ mimeType: String) throws -> [UInt8] {
    Array(try #require(try images.get().first { $0.mimeType == mimeType }).data)
}

/// The fake's release 1001, whose primary image is `/front-1001.jpg`, serving `bytes`.
private func serving(_ bytes: [UInt8], headers: [String: String] = [:]) -> FakeDiscogs {
    let fake = FakeDiscogs()
    fake.queue("/front-1001.jpg", status: 200, headers: headers, body: bytes)
    return fake
}

@Test func aJPEGAndAPNGAreCoversOfTheirTypeAndSize() async throws {
    for (mimeType, side) in [(jpegMIMEType, 64), (pngMIMEType, 120)] {
        let bytes = try image(mimeType)
        let fake = serving(bytes)
        let cover = try await fake.api().cover(release: 1001)
        #expect(cover.mimeType == mimeType)
        #expect(cover.width == side && cover.height == side)
        #expect(cover.bytes == Data(bytes))
        // The image request goes to the image host, with no token.
        let request = try #require(fake.requests.last)
        #expect(request.url.host == DiscogsAPI.imageHost)
        #expect(request.headers["Authorization"] == nil)
    }
}

/// A real PNG `width` pixels wide and one high.
private func wide(_ width: Int) throws -> [UInt8] {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let encoded = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return Array(encoded as Data)
}

/// A PNG whose header declares `side` × `side`, its CRC fixed, a few hundred bytes long.
private func pngDeclaring(side: Int) throws -> [UInt8] {
    var bytes = try image(pngMIMEType)
    for (offset, value) in [(16, side), (20, side)] {
        for index in 0..<4 { bytes[offset + index] = UInt8(value >> (8 * (3 - index)) & 0xFF) }
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes[12..<29] {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
    }
    crc = ~crc
    for index in 0..<4 { bytes[29 + index] = UInt8(crc >> (8 * (3 - UInt32(index))) & 0xFF) }
    return bytes
}

@Test func anImageThatIsntAWholeSmallJPEGOrPNGIsNoCover() async throws {
    let jpeg = try image(jpegMIMEType)
    for (bytes, problem) in [
        (Array("<html>not an image</html>".utf8), CoverProblem.notAnImage),
        (Array(jpeg.prefix(jpeg.count / 2)), .damaged),
        (try wide(Cover.largestSide + 1), .tooLarge(width: Cover.largestSide + 1, height: 1)),
    ] {
        await #expect(throws: problem) { try await serving(bytes).api().cover(release: 1001) }
    }
    // A few hundred bytes declaring 400 megapixels: refused, by the size or the decode.
    await #expect(throws: CoverProblem.self) {
        try await serving(try pngDeclaring(side: 20_000)).api().cover(release: 1001)
    }
    // Past the cap, the transport stops reading.
    let fake = FakeDiscogs()
    fake.queue("/front-1001.jpg", .failure(.tooLarge(cap: Cover.byteCap)))
    await #expect(throws: CoverProblem.fetch(.tooLarge)) {
        try await fake.api().cover(release: 1001)
    }
}

@Test func theTypeIsReadFromTheBytesNotTheServersContentType() async throws {
    let png = try image(pngMIMEType)
    let cover = try await serving(png, headers: ["Content-Type": "image/jpeg"]).api()
        .cover(release: 1001)
    #expect(cover.mimeType == pngMIMEType)
}

@Test func anImageOffTheImageHostIsNeverFetchedAndWithoutATokenNothingIs() async throws {
    let fake = FakeDiscogs()
    await #expect(throws: DiscogsAPIError.refusedAddress) {
        try await fake.api().image(at: URL(string: "https://evil.example/front.jpg")!)
    }
    #expect(fake.requests.isEmpty)
    // A release whose image is elsewhere has none.
    var object =
        try JSONSerialization.jsonObject(with: Data(apiFixture("release-simple")))
        as! [String: Any]
    object["images"] = [["type": "primary", "uri": "https://evil.example/front.jpg"]]
    fake.queue(
        "/releases/1001", status: 200,
        body: Array(try JSONSerialization.data(withJSONObject: object)))
    await #expect(throws: CoverProblem.noImage) { try await fake.api().cover(release: 1001) }
    #expect(!fake.requests.contains { $0.url.host != DiscogsAPI.host })
    let without = FakeDiscogs()
    await #expect(throws: CoverProblem.needsToken) {
        try await without.api(token: nil).cover(release: 1001)
    }
    #expect(without.requests.isEmpty)
}

private let release = CatalogRelease(
    id: 1001, title: "Stockholm", artists: [artist(1, "Persuader")],
    tracks: [song("1", "Östermalm"), song("2", "Gamla Stan")])

private func cover(_ mimeType: String) throws -> Cover { try Cover(checking: try image(mimeType)) }

@Test func fillEmptyCoversOnlyFilesWithoutOneAndReplaceCoversEvery() throws {
    var withArt = albumFile(2, .flac, TrackTags())
    withArt.metadata.art = EmbeddedArt(
        offset: 100, byteCount: 10, mimeType: jpegMIMEType, unsynchronised: false)
    let files = [albumFile(1, .flac, TrackTags()), withArt]
    let set = changeSet(for: files, match: match(release), mapping: DiscogsPreset.minimal.mapping)
    let jpeg = try cover(jpegMIMEType)
    let filling = set.covering(jpeg, mode: .fillEmpty)
    #expect(filling.files.map(\.cover) == [.adds, .none])
    #expect(try filling.edits().map { $0.edit.art != nil } == [true, false])
    let replacing = set.covering(jpeg, mode: .replace)
    #expect(replacing.files.map(\.cover) == [.adds, .replaces])
    #expect(replacing.coveredFiles == 2)
    #expect(
        try replacing.edits().allSatisfy {
            $0.edit.art == .replace(jpeg.bytes, mimeType: jpegMIMEType)
        })
    // Unticked, the cover isn't written; the tags still are.
    let unticked = try replacing.edits(includingCover: false)
    #expect(unticked.allSatisfy { $0.edit.art == nil })
    #expect(!unticked.isEmpty)
    #expect(set.covering(jpeg, mode: .off).coveredFiles == 0)
}

@Test(arguments: [WrittenSample.flac, .mp3v24, .mp4])
func aCoverIsWrittenWithTheTagsAndUndoneWithThem(_ sample: WrittenSample) throws {
    let urls = try sample.copies()
    let (before, problems) = readAlbumFiles(
        urls.enumerated().map { (id: Int64($0.offset + 1), path: $0.element.path) })
    try #require(problems == [])
    let originalArt = try before.map { file in
        try file.metadata.art.map { try readArt($0, at: URL(fileURLWithPath: file.path)) }
    }
    for mimeType in [jpegMIMEType, pngMIMEType] {
        let image = try cover(mimeType)
        let set = changeSet(
            for: before, match: match(release, files: urls.count),
            mapping: DiscogsPreset.oneToOne.mapping
        ).covering(image, mode: .replace)
        let writer = TagWriter(
            journal: TagUndoJournal(
                dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "discogs-cover-journal-\(UUID().uuidString)", isDirectory: true)))
        let report = writer.write(try set.edits())
        #expect(report.failures == [], "\(sample) \(mimeType)")
        let (after, _) = readAlbumFiles(
            urls.enumerated().map { (id: Int64($0.offset + 1), path: $0.element.path) })
        for file in after {
            let art = try #require(file.metadata.art, "\(sample)")
            #expect(try readArt(art, at: URL(fileURLWithPath: file.path)) == image.bytes)
            #expect(file.metadata.tags.album == "Stockholm")
        }
        // One undo puts back the art and the tags together.
        #expect(writer.undoLast().failures == [])
        let (undone, _) = readAlbumFiles(
            urls.enumerated().map { (id: Int64($0.offset + 1), path: $0.element.path) })
        #expect(undone.map(\.metadata.tags) == before.map(\.metadata.tags), "\(sample)")
        let undoneArt = try undone.map { file in
            try file.metadata.art.map { try readArt($0, at: URL(fileURLWithPath: file.path)) }
        }
        #expect(undoneArt == originalArt, "\(sample)")
    }
}
