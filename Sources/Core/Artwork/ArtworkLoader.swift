import CoreGraphics
import Foundation
import ImageIO
import Log
import Metadata

/// Album art, decoded straight to a thumbnail at display size and kept in a cache of bounded
/// size. The file's full-size image is never decoded: ImageIO scales while it decodes, so only the
/// compressed bytes and the thumbnail exist, and only the thumbnail outlives the call. Safe to use
/// from any thread.
public final class ArtworkLoader: @unchecked Sendable {
    /// The longest side of each thumbnail, in pixels.
    public let maxPixelSize: Int
    /// The most thumbnails kept. The least recently used goes first.
    public let capacity: Int
    private let read: ArtRead
    private let lock = NSLock()
    private var images: [ArtworkKey: CGImage] = [:]
    /// Least recently used first.
    private var recency: [ArtworkKey] = []

    /// `read` reads the art's bytes from its file; the scroll measurement wraps it to add a
    /// NAS's latency.
    public init(maxPixelSize: Int, capacity: Int, read: @escaping ArtRead = readArtBytes) {
        precondition(maxPixelSize > 0 && capacity > 0, "an art cache needs a size and a capacity")
        self.maxPixelSize = maxPixelSize
        self.capacity = capacity
        self.read = read
    }

    /// The thumbnail if it's cached.
    public func cached(_ key: ArtworkKey) -> CGImage? {
        lock.withLock {
            guard let image = images[key] else { return nil }
            touch(key)
            return image
        }
    }

    /// The thumbnail of `art` in the file at `path`, from the cache or read and decoded now.
    /// Blocks on the file, which may be on a slow network volume, so call it off the main thread.
    public func image(_ art: EmbeddedArt, path: String) throws -> CGImage {
        let key = ArtworkKey(path: path, art: art)
        if let image = cached(key) { return image }
        let image = try signposted(.artLoad) {
            let bytes: Data
            do {
                bytes = try read(art, path)
            } catch {
                throw ArtworkError.unreadable(path: path, reason: "\(error)")
            }
            guard let image = thumbnail(of: bytes, maxPixelSize: maxPixelSize) else {
                throw ArtworkError.undecodable(path: path, mimeType: art.mimeType)
            }
            return image
        }
        lock.withLock {
            if images.updateValue(image, forKey: key) == nil {
                recency.append(key)
            } else {
                touch(key)
            }
            while recency.count > capacity { images[recency.removeFirst()] = nil }
        }
        return image
    }

    /// `image(_:path:)` on a queue of the loaders' own instead of the cooperative pool. The pool
    /// has a thread per core, 4 on the 2015 MacBook Pro, and a read that waits on a slow NAS
    /// would hold one, stalling every other task meanwhile.
    public func load(_ art: EmbeddedArt, path: String) async -> Result<CGImage, any Error> {
        await withCheckedContinuation { continuation in
            Self.reads.async {
                continuation.resume(returning: Result { try self.image(art, path: path) })
            }
        }
    }

    /// Where `load` reads. Concurrent: each caller bounds its own loads.
    private static let reads = DispatchQueue(
        label: "ArtworkLoader", qos: .userInitiated, attributes: .concurrent)

    /// Marks `key` most recently used. Runs under `lock`.
    private func touch(_ key: ArtworkKey) {
        guard let index = recency.firstIndex(of: key) else { return }
        recency.remove(at: index)
        recency.append(key)
    }
}

/// Reads the bytes of `art` from the file at a path.
public typealias ArtRead = @Sendable (EmbeddedArt, String) throws -> Data

/// The bytes of `art` in the file at `path`.
public func readArtBytes(_ art: EmbeddedArt, path: String) throws -> Data {
    try readArt(art, at: URL(fileURLWithPath: path, isDirectory: false))
}

/// `bytes` decoded straight to an image whose longest side is at most `maxPixelSize`, or nil
/// when they aren't an image. Every decode of art goes through this: the full-size image is
/// never made, so a small file that declares a huge image costs only the thumbnail.
public func thumbnail(of bytes: Data, maxPixelSize: Int) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// One picture in one file. Its length is part of it, so art replaced in place by one of
/// another length isn't served from the cache.
public struct ArtworkKey: Hashable, Sendable {
    public var path: String
    public var offset: Int
    var byteCount: Int

    public init(path: String, art: EmbeddedArt) {
        self.path = path
        offset = art.offset
        byteCount = art.byteCount
    }
}

enum ArtworkError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    /// The bytes aren't an image ImageIO can decode.
    case undecodable(path: String, mimeType: String)

    var description: String {
        switch self {
        case .unreadable(let path, let reason): "can't read the art in \(path): \(reason)"
        case .undecodable(let path, let mimeType):
            "the art in \(path) (\(mimeType)) isn't an image that can be decoded"
        }
    }
}
