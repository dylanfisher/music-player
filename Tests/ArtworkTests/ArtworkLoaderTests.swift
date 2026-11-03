import CoreGraphics
import Foundation
import ImageIO
import Metadata
import Testing

@testable import Artwork

/// A file holding `prefix` junk bytes, then a PNG of `width` by `height`, and where the PNG is.
private func fileWithArt(width: Int, height: Int, prefix: Int = 100) throws -> (
    String, EmbeddedArt
) {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let png = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("artwork-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("track.flac").path
    try (Data(repeating: 7, count: prefix) + (png as Data)).write(
        to: URL(fileURLWithPath: path))
    return (
        path,
        EmbeddedArt(
            offset: prefix, byteCount: png.length, mimeType: pngMIMEType, unsynchronised: false)
    )
}

@Test func artReplacedInPlaceByOneOfAnotherLengthIsReadAgain() throws {
    let (path, art) = try fileWithArt(width: 40, height: 40)
    let loader = ArtworkLoader(maxPixelSize: 96, capacity: 4)
    let first = try loader.image(art, path: path)
    #expect(first.width == 40)
    // A tag edit writes a larger cover at the same place.
    let (larger, replaced) = try fileWithArt(width: 80, height: 80)
    try FileManager.default.removeItem(atPath: path)
    try FileManager.default.copyItem(atPath: larger, toPath: path)
    #expect(replaced.offset == art.offset)
    #expect(try loader.image(replaced, path: path).width == 80)
}

@Test func decodesStraightToTheDisplaySize() throws {
    let (path, art) = try fileWithArt(width: 1200, height: 800)
    let loader = ArtworkLoader(maxPixelSize: 96, capacity: 4)
    let image = try loader.image(art, path: path)
    #expect(image.width == 96)
    #expect(image.height == 64)
    #expect(loader.cached(ArtworkKey(path: path, art: art)) === image)
}

@Test func keepsAtMostItsCapacityDroppingTheLeastRecentlyUsed() throws {
    let loader = ArtworkLoader(maxPixelSize: 32, capacity: 2)
    let files = try (0..<3).map { _ in try fileWithArt(width: 64, height: 64) }
    let keys = files.map { ArtworkKey(path: $0.0, art: $0.1) }
    _ = try loader.image(files[0].1, path: files[0].0)
    _ = try loader.image(files[1].1, path: files[1].0)
    #expect(loader.cached(keys[0]) != nil)  // now the most recently used
    _ = try loader.image(files[2].1, path: files[2].0)
    #expect(loader.cached(keys[1]) == nil)
    #expect(loader.cached(keys[0]) != nil)
    #expect(loader.cached(keys[2]) != nil)
}

@Test func artThatIsntAnImageFailsWithThePath() throws {
    let (path, art) = try fileWithArt(width: 8, height: 8)
    var garbage = art
    garbage.offset = 0
    let loader = ArtworkLoader(maxPixelSize: 32, capacity: 2)
    #expect(throws: ArtworkError.undecodable(path: path, mimeType: pngMIMEType)) {
        try loader.image(garbage, path: path)
    }
    var past = art
    past.byteCount += 10
    #expect {
        try loader.image(past, path: path)
    } throws: { error in
        guard case .unreadable(let failed, _) = error as? ArtworkError else { return false }
        return failed == path
    }
}

/// A picture of more pixels than any cover. ImageIO scales while it decodes, so only the
/// thumbnail is made; measured on a 400-megapixel PNG, the peak was 23 MB (ADR 0025).
@Test func aHugeImageDecodesOnlyToItsThumbnail() throws {
    let side = 8_000
    let context = try #require(
        CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    let png = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("artwork-\(UUID().uuidString).flac").path
    try (png as Data).write(to: URL(fileURLWithPath: path))
    let art = EmbeddedArt(
        offset: 0, byteCount: png.length, mimeType: pngMIMEType, unsynchronised: false)
    let image = try ArtworkLoader(maxPixelSize: 96, capacity: 1).image(art, path: path)
    #expect(image.width == 96)
    #expect(image.height == 96)
}

/// A 16-pixel image encoded as `type`, then its header changed to declare `side` by `side`
/// pixels, as a hostile file's art could: a few hundred bytes claiming billions of pixels.
private func imageDeclaring(side: Int, type: String) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let encoded = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(encoded, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    var bytes = [UInt8](encoded as Data)
    func put(_ value: Int, _ count: Int, at offset: Int) {
        for index in 0..<count {
            bytes[offset + index] = UInt8(value >> (8 * (count - 1 - index)) & 0xFF)
        }
    }
    if type == "public.png" {
        // IHDR's width and height, then its CRC over the type and the fields.
        put(side, 4, at: 16)
        put(side, 4, at: 20)
        put(Int(crc32(bytes[12..<29])), 4, at: 29)
    } else {
        // The baseline frame header: length, precision, then height and width.
        let frame = try #require(
            bytes.indices.dropLast().first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xC0 })
        put(side, 2, at: frame + 5)
        put(side, 2, at: frame + 7)
    }
    return Data(bytes)
}

private func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
}

@Test(arguments: ["public.png", "public.jpeg"])
func aTinyImageDeclaringAHugeOneDecodesOnlyToAThumbnailOrNot(_ type: String) throws {
    let side = type == "public.png" ? 1_000_000 : 65_000
    let bytes = try imageDeclaring(side: side, type: type)
    #expect(bytes.count < 4096)
    let started = Date()
    let image = thumbnail(of: bytes, maxPixelSize: 96)
    #expect(Date().timeIntervalSince(started) < 5, "\(type)")
    if let image { #expect(max(image.width, image.height) <= 96, "\(type)") }
}
