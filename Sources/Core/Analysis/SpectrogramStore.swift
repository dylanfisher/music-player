import CacheFolder
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
    /// The columns count, Nyquist frequency and duration before the cells.
    private static let headerBytes = 4 + 8 + 8

    private let folder: CacheFolder
    var directory: URL { folder.directory }

    public convenience init(directory: URL) {
        self.init(directory: directory, capacityBytes: Self.capacityBytes)
    }

    init(directory: URL, capacityBytes: Int) {
        folder = CacheFolder(
            directory: directory, noun: "spectrogram", capacityBytes: capacityBytes,
            trimEveryBytes: Self.trimEveryBytes, report: { logger.error("\($0)") })
    }

    /// The stored spectrogram of `path`, made from the file as `stamp` describes it, or nil.
    func spectrogram(path: String, stamp: FileStamp) -> Spectrogram? {
        let key = Self.key(path: path, stamp: stamp)
        guard let bytes = folder.data(key) else { return nil }
        guard let spectrogram = Self.decode(bytes) else {
            folder.discard(key)
            return nil
        }
        return spectrogram
    }

    /// Stores `spectrogram`, made from `path` as `stamp` describes the file.
    func store(_ spectrogram: Spectrogram, path: String, stamp: FileStamp) {
        folder.store(Self.encode(spectrogram), Self.key(path: path, stamp: stamp), of: path)
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

    /// Nil for bytes of any other length than their columns make, as from an earlier shape, or
    /// whose Nyquist frequency or length isn't a positive number, as from damage.
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
        let nyquistHz = Double(bitPattern: word(4, 8))
        let durationSeconds = Double(bitPattern: word(12, 8))
        guard nyquistHz.isFinite, nyquistHz > 0, durationSeconds.isFinite, durationSeconds > 0
        else { return nil }
        let average = (0..<Spectrogram.rows).map { row in
            Float(bitPattern: UInt32(word(headerBytes + cellBytes + 4 * row, 4)))
        }
        return Spectrogram(
            columns: columns, cells: Array(bytes[headerBytes..<headerBytes + cellBytes]),
            averageDB: average, nyquistHz: nyquistHz, durationSeconds: durationSeconds)
    }

    /// Removes the least recently used spectrograms until the store is within its capacity,
    /// on a utility queue. Does nothing while a trim is under way.
    public func trimInBackground() { folder.trimInBackground() }

    /// `trimInBackground`'s work, on the calling thread.
    func trim() { folder.trim() }

    /// The file for one spectrogram, named by a hash of the path and the file's stamp.
    func fileURL(path: String, stamp: FileStamp) -> URL {
        folder.fileURL(Self.key(path: path, stamp: stamp))
    }

    private static func key(path: String, stamp: FileStamp) -> [String] {
        [path, "\(stamp.sizeBytes)", "\(stamp.modifiedSeconds.bitPattern)"]
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
