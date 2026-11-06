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
public final class ThumbnailStore: @unchecked Sendable {
    /// About 6,000 covers at the column's default size, well over the albums of a 43k-track
    /// library.
    static let capacityBytes = 100_000_000
    static let capacityFiles = 20_000
    /// Bytes written between trims, so the store never runs far over its capacity in one
    /// session.
    static let trimEveryBytes = capacityBytes / 10
    /// The most write and read failures logged a session.
    static let loggedFailures = 20

    let directory: URL
    private let capacityBytes: Int
    private let capacityFiles: Int
    private let lock = NSLock()
    // Guarded by `lock`.
    private var writtenSinceTrim = 0
    private var trimming = false
    private var failures = 0

    public convenience init(directory: URL) {
        self.init(
            directory: directory, capacityBytes: Self.capacityBytes,
            capacityFiles: Self.capacityFiles)
    }

    init(directory: URL, capacityBytes: Int, capacityFiles: Int) {
        self.directory = directory
        self.capacityBytes = capacityBytes
        self.capacityFiles = capacityFiles
    }

    /// The stored thumbnail of `key`'s art at `pixels`, made from the file as `stamp` describes
    /// it, or nil.
    func image(_ key: ArtworkKey, stamp: FileStamp, pixels: Int) -> CGImage? {
        let url = fileURL(key, stamp: stamp, pixels: pixels)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            fail("can't read the stored thumbnail \(url.path): \(error)")
            return nil
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            fail("the stored thumbnail \(url.path) doesn't decode; removing it")
            remove(url)
            return nil
        }
        // Marks it recently used, for the trim.
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            fail("can't mark the stored thumbnail \(url.path) used: \(error)")
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
        else { return fail("can't make an encoder for a thumbnail") }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return fail("can't encode the thumbnail of \(key.path)")
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try (data as Data).write(
                to: fileURL(key, stamp: stamp, pixels: pixels), options: .atomic)
        } catch {
            return fail("can't store the thumbnail of \(key.path): \(error)")
        }
        let due = lock.withLock {
            writtenSinceTrim += data.length
            return writtenSinceTrim >= Self.trimEveryBytes
        }
        if due { trimInBackground() }
    }

    /// Removes the least recently used thumbnails until the store is within its capacity, on a
    /// utility queue. Does nothing while a trim is under way.
    public func trimInBackground() {
        let start = lock.withLock {
            guard !trimming else { return false }
            trimming = true
            writtenSinceTrim = 0
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            self.trim()
            self.lock.withLock { self.trimming = false }
        }
    }

    /// `trimInBackground`'s work, on the calling thread.
    func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files: [(url: URL, bytes: Int, used: Date)]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ).map { url in
                let values = try url.resourceValues(forKeys: Set(keys))
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            return fail("can't list the stored thumbnails in \(directory.path): \(error)")
        }
        var bytes = files.reduce(0) { $0 + $1.bytes }
        var count = files.count
        for file in files.sorted(by: { $0.used < $1.used }) {
            guard bytes > capacityBytes || count > capacityFiles else { break }
            remove(file.url)
            bytes -= file.bytes
            count -= 1
        }
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Another trim got there first.
        } catch {
            fail("can't remove the stored thumbnail \(url.path): \(error)")
        }
    }

    /// The file for one thumbnail, named by a 128-bit hash of everything that makes it.
    func fileURL(_ key: ArtworkKey, stamp: FileStamp, pixels: Int) -> URL {
        let name = [
            key.path, "\(key.offset)", "\(key.byteCount)", "\(stamp.sizeBytes)",
            "\(stamp.modifiedSeconds.bitPattern)", "\(pixels)",
        ].joined(separator: "\u{0}")
        let bytes = Array(name.utf8)
        let hash = fnv1a(bytes, basis: 0xcbf2_9ce4_8422_2325)
        let second = fnv1a(bytes, basis: 0x8422_2325_cbf2_9ce4)
        return directory.appendingPathComponent(
            String(format: "%016llx%016llx", hash, second), isDirectory: false)
    }

    private func fail(_ message: String) {
        let log = lock.withLock {
            failures += 1
            return failures <= Self.loggedFailures
        }
        if log { logger.error("\(message)") }
    }
}

/// FNV-1a over `bytes` from `basis`. Two bases give two halves of the name; they are not independent, only a longer name.
private func fnv1a(_ bytes: [UInt8], basis: UInt64) -> UInt64 {
    bytes.reduce(basis) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
}
