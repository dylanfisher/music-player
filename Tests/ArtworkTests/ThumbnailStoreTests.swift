import CoreGraphics
import Foundation
import ImageIO
import Metadata
import Testing

@testable import Artwork

private func scratchStore(capacityBytes: Int = 1_000_000, capacityFiles: Int = 100)
    -> ThumbnailStore
{
    ThumbnailStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "thumbnails-\(UUID().uuidString)", isDirectory: true),
        capacityBytes: capacityBytes, capacityFiles: capacityFiles)
}

private func square(_ side: Int, alpha: Bool = false) throws -> CGImage {
    let context = try #require(
        CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (alpha
                ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return try #require(context.makeImage())
}

private let art = EmbeddedArt(
    offset: 10, byteCount: 500, mimeType: jpegMIMEType, unsynchronised: false)
private let key = ArtworkKey(path: "/Volumes/music/a.flac", art: art)
private let stamp = FileStamp(sizeBytes: 9000, modifiedSeconds: 1_700_000_000.5)

@Test func aStoredThumbnailComesBackOnlyForTheSameFileAndSize() throws {
    let store = scratchStore()
    #expect(store.image(key, stamp: stamp, pixels: 64) == nil)
    store.store(try square(64), key, stamp: stamp, pixels: 64)
    let image = try #require(store.image(key, stamp: stamp, pixels: 64))
    #expect(image.width == 64)
    // A tag edit changes the file's size or time; another column width wants other pixels.
    #expect(
        store.image(key, stamp: FileStamp(sizeBytes: 9000, modifiedSeconds: 1), pixels: 64) == nil)
    #expect(
        store.image(
            key, stamp: FileStamp(sizeBytes: 9001, modifiedSeconds: stamp.modifiedSeconds),
            pixels: 64) == nil)
    #expect(store.image(key, stamp: stamp, pixels: 128) == nil)
    let moved = ArtworkKey(path: "/Volumes/music/b.flac", art: art)
    #expect(store.image(moved, stamp: stamp, pixels: 64) == nil)
}

@Test func artWithAlphaKeepsIt() throws {
    let store = scratchStore()
    store.store(try square(32, alpha: true), key, stamp: stamp, pixels: 32)
    let image = try #require(store.image(key, stamp: stamp, pixels: 32))
    #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
}

@Test func aStoredThumbnailThatDoesntDecodeIsRemoved() throws {
    let store = scratchStore()
    store.store(try square(16), key, stamp: stamp, pixels: 16)
    let url = store.fileURL(key, stamp: stamp, pixels: 16)
    try Data("not an image".utf8).write(to: url)
    #expect(store.image(key, stamp: stamp, pixels: 16) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func aTrimRemovesTheLeastRecentlyUsedUntilWithinCapacity() throws {
    let store = scratchStore(capacityFiles: 2)
    let keys = (0..<4).map { ArtworkKey(path: "/m/\($0).flac", art: art) }
    for (age, key) in keys.enumerated() {
        store.store(try square(16), key, stamp: stamp, pixels: 16)
        // Oldest first: key 0 was used longest ago.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: Double(age - 10) * 60)],
            ofItemAtPath: store.fileURL(key, stamp: stamp, pixels: 16).path)
    }
    // Reading key 0 marks it used now, so keys 1 and 2 go.
    #expect(store.image(keys[0], stamp: stamp, pixels: 16) != nil)
    store.trim()
    #expect(
        keys.map { store.image($0, stamp: stamp, pixels: 16) != nil } == [true, false, false, true])
}

@Test func aTrimKeepsTheStoreWithinItsBytes() throws {
    let store = scratchStore()
    store.store(try square(64), key, stamp: stamp, pixels: 64)
    let bytes = try #require(
        try store.fileURL(key, stamp: stamp, pixels: 64).resourceValues(forKeys: [.fileSizeKey])
            .fileSize)
    let small = ThumbnailStore(
        directory: store.directory, capacityBytes: bytes - 1, capacityFiles: 100)
    small.trim()
    #expect(store.image(key, stamp: stamp, pixels: 64) == nil)
}

/// A second loader, as at the next launch, gets the thumbnail from the store without reading
/// the file, and a loader without a stamp never uses the store.
@Test func theNextLaunchDoesntReadTheFileAgain() throws {
    let store = scratchStore()
    let reads = CountedReads()
    let image = try square(200)
    let bytes = try #require(pngData(image))
    let read: ArtRead = { _, _ in
        reads.count += 1
        return bytes
    }
    let first = ArtworkLoader(maxPixelSize: 64, capacity: 4, read: read, thumbnails: store)
    #expect(try first.image(art, path: key.path, stamp: stamp).width == 64)
    let second = ArtworkLoader(maxPixelSize: 64, capacity: 4, read: read, thumbnails: store)
    #expect(try second.image(art, path: key.path, stamp: stamp).width == 64)
    #expect(reads.count == 1)
    let unstamped = ArtworkLoader(maxPixelSize: 64, capacity: 4, read: read, thumbnails: store)
    _ = try unstamped.image(art, path: key.path)
    #expect(reads.count == 2)
}

private final class CountedReads: @unchecked Sendable {
    var count = 0
}

private func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}
