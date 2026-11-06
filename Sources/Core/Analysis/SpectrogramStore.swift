import Foundation
import Log
import Metadata

private let logger = moduleLogger()

/// Spectrograms kept on disk between launches, beside the thumbnails (ADR 0079, 0115), so a
/// file shown before draws again without being read over the NAS: its 8-bit cells and its
/// average, about 0.5 MB a file. A cache, not app state: a file that can't be read or written
/// is logged and the audio analyzed again. Least recently used goes first once it holds more
/// than `capacityBytes`. Safe to use from any thread.
public final class SpectrogramStore: @unchecked Sendable {
    /// About 200 files of an hour or more, 1,000 columns each.
    static let capacityBytes = 100_000_000
    /// Bytes written between trims.
    static let trimEveryBytes = capacityBytes / 10
    /// The most write and read failures logged a session.
    static let loggedFailures = 20
    /// The columns count, Nyquist frequency and duration before the cells.
    private static let headerBytes = 4 + 8 + 8

    let directory: URL
    private let capacityBytes: Int
    private let lock = NSLock()
    // Guarded by `lock`.
    private var writtenSinceTrim = 0
    private var trimming = false
    private var failures = 0

    public convenience init(directory: URL) {
        self.init(directory: directory, capacityBytes: Self.capacityBytes)
    }

    init(directory: URL, capacityBytes: Int) {
        self.directory = directory
        self.capacityBytes = capacityBytes
    }

    /// The stored spectrogram of `path`, made from the file as `stamp` describes it, or nil.
    func spectrogram(path: String, stamp: FileStamp) -> Spectrogram? {
        let url = fileURL(path: path, stamp: stamp)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            fail("can't read the stored spectrogram \(url.path): \(error)")
            return nil
        }
        guard let spectrogram = Self.decode(bytes) else {
            fail("the stored spectrogram \(url.path) doesn't decode; removing it")
            remove(url)
            return nil
        }
        // Marks it recently used, for the trim.
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path)
        } catch {
            fail("can't mark the stored spectrogram \(url.path) used: \(error)")
        }
        return spectrogram
    }

    /// Stores `spectrogram`, made from `path` as `stamp` describes the file.
    func store(_ spectrogram: Spectrogram, path: String, stamp: FileStamp) {
        let data = Self.encode(spectrogram)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(path: path, stamp: stamp), options: .atomic)
        } catch {
            return fail("can't store the spectrogram of \(path): \(error)")
        }
        let due = lock.withLock {
            writtenSinceTrim += data.count
            return writtenSinceTrim >= Self.trimEveryBytes
        }
        if due { trimInBackground() }
    }

    static func encode(_ spectrogram: Spectrogram) -> Data {
        var data = Data(capacity: headerBytes + spectrogram.cells.count + 4 * Spectrogram.rows)
        data.appendLittleEndian(UInt32(spectrogram.columns))
        data.appendLittleEndian(spectrogram.nyquistHz.bitPattern)
        data.appendLittleEndian(spectrogram.durationSeconds.bitPattern)
        data.append(contentsOf: spectrogram.cells)
        for level in spectrogram.averageDB { data.appendLittleEndian(level.bitPattern) }
        return data
    }

    /// Nil for bytes of any other length than their columns make, as from an earlier shape.
    static func decode(_ data: Data) -> Spectrogram? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerBytes else { return nil }
        func word(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
        }
        let columns = Int(word(0, 4))
        let cellBytes = columns * Spectrogram.rows
        guard columns > 0, columns <= Spectrogram.maximumColumns,
            bytes.count == headerBytes + cellBytes + 4 * Spectrogram.rows
        else { return nil }
        let average = (0..<Spectrogram.rows).map { row in
            Float(bitPattern: UInt32(word(headerBytes + cellBytes + 4 * row, 4)))
        }
        return Spectrogram(
            columns: columns, cells: Array(bytes[headerBytes..<headerBytes + cellBytes]),
            averageDB: average, nyquistHz: Double(bitPattern: word(4, 8)),
            durationSeconds: Double(bitPattern: word(12, 8)))
    }

    /// Removes the least recently used spectrograms until the store is within its capacity,
    /// on a utility queue. Does nothing while a trim is under way.
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
            return fail("can't list the stored spectrograms in \(directory.path): \(error)")
        }
        var bytes = files.reduce(0) { $0 + $1.bytes }
        for file in files.sorted(by: { $0.used < $1.used }) where bytes > capacityBytes {
            remove(file.url)
            bytes -= file.bytes
        }
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Another trim got there first.
        } catch {
            fail("can't remove the stored spectrogram \(url.path): \(error)")
        }
    }

    /// The file for one spectrogram, named by a 128-bit hash of the path and the file's stamp.
    func fileURL(path: String, stamp: FileStamp) -> URL {
        let name = [path, "\(stamp.sizeBytes)", "\(stamp.modifiedSeconds.bitPattern)"]
            .joined(separator: "\u{0}")
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

/// FNV-1a over `bytes` from `basis`, as the thumbnails are named.
private func fnv1a(_ bytes: [UInt8], basis: UInt64) -> UInt64 {
    bytes.reduce(basis) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
}

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
