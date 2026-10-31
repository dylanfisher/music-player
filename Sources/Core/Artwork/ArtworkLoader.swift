import CoreGraphics
import Foundation
import ImageIO
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
    private let lock = NSLock()
    private var images: [ArtworkKey: CGImage] = [:]
    /// Least recently used first.
    private var recency: [ArtworkKey] = []

    public init(maxPixelSize: Int, capacity: Int) {
        precondition(maxPixelSize > 0 && capacity > 0, "an art cache needs a size and a capacity")
        self.maxPixelSize = maxPixelSize
        self.capacity = capacity
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
        let key = ArtworkKey(path: path, offset: art.offset)
        if let image = cached(key) { return image }
        let bytes: Data
        do {
            bytes = try readArt(art, at: URL(fileURLWithPath: path))
        } catch {
            throw ArtworkError.unreadable(path: path, reason: "\(error)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ArtworkError.undecodable(path: path, mimeType: art.mimeType) }
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

    /// How many thumbnails are cached.
    public var count: Int { lock.withLock { images.count } }

    /// Marks `key` most recently used. Runs under `lock`.
    private func touch(_ key: ArtworkKey) {
        guard let index = recency.firstIndex(of: key) else { return }
        recency.remove(at: index)
        recency.append(key)
    }
}

/// One picture in one file.
public struct ArtworkKey: Hashable, Sendable {
    public var path: String
    public var offset: Int

    public init(path: String, offset: Int) {
        self.path = path
        self.offset = offset
    }
}

public enum ArtworkError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    /// The bytes aren't an image ImageIO can decode.
    case undecodable(path: String, mimeType: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason): "can't read the art in \(path): \(reason)"
        case .undecodable(let path, let mimeType):
            "the art in \(path) (\(mimeType)) isn't an image that can be decoded"
        }
    }
}
