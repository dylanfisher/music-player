import CacheFolder
import CoreGraphics
import Foundation
import ImageIO
import Log
import Metadata
import UniformTypeIdentifiers

private let logger = moduleLogger()

/// Thumbnails kept on disk between launches, so a cover shown before comes back without reading
/// its file over the NAS and decoding it again (ADR 0079). A cache, not app state: a file that
/// can't be read or written is logged and the cover read from its file instead. Least recently
/// used goes first once it holds more than `capacityBytes` or `capacityFiles`. Safe to use from
/// any thread.
public final class ThumbnailStore: Sendable {
    /// About 6,000 covers at the column's default size, well over the albums of a 43k-track
    /// library.
    static let capacityBytes = 100_000_000
    static let capacityFiles = 20_000
    /// Bytes written between trims, so the store never runs far over its capacity in one
    /// session.
    static let trimEveryBytes = capacityBytes / 10

    private let folder: CacheFolder
    var directory: URL { folder.directory }

    public convenience init(directory: URL) {
        self.init(
            directory: directory, capacityBytes: Self.capacityBytes,
            capacityFiles: Self.capacityFiles)
    }

    init(directory: URL, capacityBytes: Int, capacityFiles: Int) {
        folder = CacheFolder(
            directory: directory, noun: "thumbnail", capacityBytes: capacityBytes,
            capacityFiles: capacityFiles, trimEveryBytes: Self.trimEveryBytes,
            report: { logger.error("\($0)") })
    }

    /// The stored thumbnail of `key`'s art at `pixels`, made from the file as `stamp` describes
    /// it, or nil.
    func image(_ key: ArtworkKey, stamp: FileStamp, pixels: Int) -> CGImage? {
        let name = Self.name(key, stamp: stamp, pixels: pixels)
        guard let bytes = folder.data(name) else { return nil }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else {
            folder.discard(name)
            return nil
        }
        return image
    }

    /// Stores `image`, the thumbnail of `key`'s art at `pixels` from the file as `stamp`
    /// describes it.
    func store(_ image: CGImage, _ key: ArtworkKey, stamp: FileStamp, pixels: Int) {
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
        else { return folder.fail("can't make an encoder for a thumbnail") }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return folder.fail("can't encode the thumbnail of \(key.path)")
        }
        folder.store(data as Data, Self.name(key, stamp: stamp, pixels: pixels), of: key.path)
    }

    /// Removes the least recently used thumbnails until the store is within its capacity, on a
    /// utility queue. Does nothing while a trim is under way.
    public func trimInBackground() { folder.trimInBackground() }

    /// `trimInBackground`'s work, on the calling thread.
    func trim() { folder.trim() }

    /// The file for one thumbnail, named by a hash of everything that makes it.
    func fileURL(_ key: ArtworkKey, stamp: FileStamp, pixels: Int) -> URL {
        folder.fileURL(Self.name(key, stamp: stamp, pixels: pixels))
    }

    private static func name(_ key: ArtworkKey, stamp: FileStamp, pixels: Int) -> [String] {
        [
            key.path, "\(key.offset)", "\(key.byteCount)", "\(stamp.sizeBytes)",
            "\(stamp.modifiedSeconds.bitPattern)", "\(pixels)",
        ]
    }
}
