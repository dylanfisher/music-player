import CoreGraphics
import Foundation
import ImageIO
import Log
import Metadata

/// Album art, decoded straight to a thumbnail at display size and kept in a cache of bounded
/// size. The file's full-size image is never decoded: ImageIO scales while it decodes, so only the
/// compressed bytes and the thumbnail exist, and only the thumbnail outlives the call. Safe to use
/// from any thread.
/// The cache's fields are guarded by `lock`.
public final class ArtworkLoader: @unchecked Sendable {
    /// The longest side of each thumbnail, in pixels.
    public let maxPixelSize: Int
    /// The most thumbnails kept. The least recently used goes first.
    public let capacity: Int
    private let read: ArtRead
    private let thumbnails: ThumbnailStore?
    private let lock = NSLock()
    private var images: [ArtworkKey: CGImage] = [:]
    /// Least recently used first.
    private var recency: [ArtworkKey] = []

    /// `read` reads the art's bytes from its file; the scroll measurement wraps it to add a
    /// NAS's latency. `thumbnails` keeps the images made for a file with a stamp between
    /// launches.
    public init(
        maxPixelSize: Int, capacity: Int, read: @escaping ArtRead = readArtBytes,
        thumbnails: ThumbnailStore? = nil
    ) {
        precondition(maxPixelSize > 0 && capacity > 0, "an art cache needs a size and a capacity")
        self.maxPixelSize = maxPixelSize
        self.capacity = capacity
        self.read = read
        self.thumbnails = thumbnails
    }

    /// A loader of thumbnails at another size that reads files as this one does, so through a
    /// `SharedArtRead` the two read a picture they both want once.
    public func sharingReads(maxPixelSize: Int, capacity: Int) -> ArtworkLoader {
        ArtworkLoader(
            maxPixelSize: maxPixelSize, capacity: capacity, read: read, thumbnails: thumbnails)
    }

    /// The thumbnail if it's cached.
    public func cached(_ key: ArtworkKey) -> CGImage? {
        lock.withLock {
            guard let image = images[key] else { return nil }
            touch(key)
            return image
        }
    }

    /// The thumbnail of `art` in the file at `path`, from the cache, from the thumbnail store
    /// when the file's `stamp` is given, or read and decoded now. Blocks on the file, which may
    /// be on a slow network volume, so call it off the main thread.
    public func image(_ art: EmbeddedArt, path: String, stamp: FileStamp? = nil) throws -> CGImage {
        let key = ArtworkKey(path: path, art: art)
        if let image = cached(key) { return image }
        let stored = stamp.flatMap { thumbnails?.image(key, stamp: $0, pixels: maxPixelSize) }
        let image =
            try stored
            ?? signposted(.artLoad) {
                let bytes: Data
                do {
                    bytes = try read(art, path)
                } catch {
                    throw ArtworkError.unreadable(path: path, reason: "\(error)")
                }
                guard let image = thumbnail(of: bytes, maxPixelSize: maxPixelSize) else {
                    throw ArtworkError.undecodable(path: path, mimeType: art.mimeType)
                }
                if let stamp { thumbnails?.store(image, key, stamp: stamp, pixels: maxPixelSize) }
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
    public func load(_ art: EmbeddedArt, path: String, stamp: FileStamp? = nil) async -> Result<
        CGImage, any Error
    > {
        await withCheckedContinuation { continuation in
            Self.reads.async {
                continuation.resume(
                    returning: Result { try self.image(art, path: path, stamp: stamp) })
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

/// One read of a picture for loaders of different sizes that want it at the same time, as the
/// bar's and Now Playing's do on each track change: a second caller for the picture being read
/// waits for those bytes instead of reading the file again over the NAS. Keeps the bytes of the
/// last picture read, and none after a failure, so the next caller tries the file again. Safe
/// to use from any thread.
/// `last` is guarded by `condition`.
public final class SharedArtRead: @unchecked Sendable {
    private let readFile: ArtRead
    private let condition = NSCondition()
    /// The picture read last, with its bytes, or nil for them while it's being read.
    private var last: (key: ArtworkKey, bytes: Data?)?

    public init(read: @escaping ArtRead = readArtBytes) {
        readFile = read
    }

    /// The bytes of `art` in the file at `path`, as `ArtRead` gives them.
    public func read(_ art: EmbeddedArt, path: String) throws -> Data {
        let key = ArtworkKey(path: path, art: art)
        condition.lock()
        while let last, last.key == key, last.bytes == nil { condition.wait() }
        if let last, last.key == key, let bytes = last.bytes {
            condition.unlock()
            return bytes
        }
        last = (key, nil)
        condition.unlock()
        let result = Result { try readFile(art, path) }
        condition.withLock {
            if last?.key == key {
                if case .success(let bytes) = result { last = (key, bytes) } else { last = nil }
            }
            condition.broadcast()
        }
        return try result.get()
    }
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
