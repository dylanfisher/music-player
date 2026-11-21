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
        guard let data = encoded(image, key) else { return }
        folder.store(data, Self.name(key, stamp: stamp, pixels: pixels), of: key.path)
    }

    /// `image` as JPEG when it's opaque, else PNG; nil, reported, when it can't be encoded.
    private func encoded(_ image: CGImage, _ key: ArtworkKey) -> Data? {
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
        else {
            folder.fail("can't make an encoder for a thumbnail")
            return nil
        }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            folder.fail("can't encode the thumbnail of \(key.path)")
            return nil
        }
        return data as Data
    }

    /// The stored thumbnail of `art` in the file at `path` at `pixels`, as JPEG or PNG bytes;
    /// on a miss it's read with `read`, made and stored now, for the web remote, which sends
    /// the bytes as they are. Blocks on the file, so call it off the main thread.
    public func encodedThumbnail(
        _ art: EmbeddedArt, path: String, stamp: FileStamp, pixels: Int,
        read: ArtRead = readArtBytes
    ) throws -> Data {
        let key = ArtworkKey(path: path, art: art)
        let name = Self.name(key, stamp: stamp, pixels: pixels)
        if let bytes = folder.data(name) { return bytes }
        let bytes: Data
        do {
            bytes = try read(art, path)
        } catch {
            throw ArtworkError.unreadable(path: path, reason: "\(error)")
        }
        guard let image = thumbnail(of: bytes, maxPixelSize: pixels),
            let data = encoded(image, key)
        else { throw ArtworkError.undecodable(path: path, mimeType: art.mimeType) }
        folder.store(data, name, of: path)
        return data
    }

    /// What names `art` in the file as `stamp` describes it, at every size: a hash of the
    /// parts its thumbnails' files are named by, which changes when the file does.
    public static func pictureName(_ art: EmbeddedArt, path: String, stamp: FileStamp)
        -> String
    {
        CacheFolder.name(name(ArtworkKey(path: path, art: art), stamp: stamp, pixels: 0))
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
