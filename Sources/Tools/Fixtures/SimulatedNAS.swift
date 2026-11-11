import Foundation
import Library
import Metadata

/// Files on this Mac, scanned as if they were on a NAS: a network volume where each file
/// operation (opening, each read, closing) takes `operationSeconds` and listing a directory
/// takes `listingSeconds`, and at most `capacity` operations are served at once while the rest
/// wait. Its cost is per request, not per byte: a NAS's disks and network serve a few kilobytes
/// of tags in about the same time as a megabyte, so what scales is how many requests are in
/// flight. Each file can also wait a `FileDelay` on the NAS's disks, which is what makes one
/// file's cost vary so much on spinning disks. It tells the scanner the volume is a network one, so the scan tunes its readers as it
/// would on the NAS.
/// Its state is guarded by `lock`.
public final class SimulatedNAS: ScanFileAccess, @unchecked Sendable {
    /// Extra seconds per file, log-normal around `medianSeconds`: most files cost little more,
    /// and a few in a hundred cost ten times the median, as a seek behind other requests does.
    public struct FileDelay: Sendable {
        public var medianSeconds: Double
        /// The spread of the delay's logarithm. Above 1, the slowest files dominate a short
        /// measurement.
        public var sigma: Double

        public init(medianSeconds: Double, sigma: Double) {
            precondition(medianSeconds > 0 && sigma >= 0, "a delay needs a median and a spread")
            self.medianSeconds = medianSeconds
            self.sigma = sigma
        }

        /// The mean delay, which is above the median by the tail.
        var meanSeconds: Double { medianSeconds * exp(sigma * sigma / 2) }
    }

    private let operationSeconds: Double
    private let listingSeconds: Double
    private let fileDelay: FileDelay?
    private let slots: DispatchSemaphore
    private let system = SystemFileAccess()
    // Guarded by `lock`.
    private let lock = NSLock()
    private var reading = 0
    private var mostReading = 0
    /// Operations served before the NAS drops, or nil while it stays up.
    private var operationsBeforeDrop: Int?
    // Seeded, so the same delays are drawn every run, though threads take them in any order.
    private var random = SplitMix64(seed: 0x4E41_5344_454C_4159)

    public init(
        operationSeconds: Double, listingSeconds: Double, capacity: Int, fileDelay: FileDelay?
    ) {
        precondition(
            operationSeconds >= 0 && listingSeconds >= 0 && capacity > 0,
            "a NAS that can't serve anything")
        self.operationSeconds = operationSeconds
        self.listingSeconds = listingSeconds
        self.fileDelay = fileDelay
        slots = DispatchSemaphore(value: capacity)
    }

    /// Drops the NAS after `operations` more operations: every listing and file operation after
    /// that fails, as on an SMB mount whose server went away while the mount stayed.
    func drop(afterOperations operations: Int) {
        lock.withLock { operationsBeforeDrop = operations }
    }

    /// Brings a dropped NAS back.
    func reconnect() { lock.withLock { operationsBeforeDrop = nil } }

    /// The most files that were being read at once.
    var mostFilesReadAtOnce: Int { lock.withLock { mostReading } }

    public func volumeIsLocal(_ path: String) throws -> Bool? { false }

    public func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL] {
        guard serve(1, seconds: listingSeconds) else {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [NSFilePathErrorKey: directory, NSUnderlyingErrorKey: POSIXError(.EIO)])
        }
        return try system.contentsOfDirectory(directory, keys: keys)
    }

    public func readMetadata(at path: String) throws(MetadataError) -> ParsedFile {
        lock.withLock {
            reading += 1
            mostReading = max(mostReading, reading)
        }
        defer { lock.withLock { reading -= 1 } }
        let dropped = MetadataError(unreadable: path, detail: "the simulated NAS dropped")
        // Opening, then each read the parser made (one, when it failed), then closing.
        guard serve(1, seconds: operationSeconds) else { throw dropped }
        if let fileDelay {
            // Box-Muller, from two uniform draws in (0, 1].
            let (u, v) = lock.withLock {
                (
                    1 - Double.random(in: 0..<1, using: &random),
                    Double.random(in: 0..<1, using: &random)
                )
            }
            let normal = (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
            guard serve(1, seconds: fileDelay.medianSeconds * exp(fileDelay.sigma * normal)) else {
                throw dropped
            }
        }
        let result = Result { () throws(MetadataError) -> ParsedFile in
            try system.readMetadata(at: path)
        }
        let reads =
            switch result {
            case .success(let parsed): parsed.readCount
            case .failure: 1
            }
        guard serve(reads + 1, seconds: operationSeconds) else { throw dropped }
        return try result.get()
    }

    /// Serves `operations` one at a time; false once the NAS has dropped.
    private func serve(_ operations: Int, seconds: Double) -> Bool {
        for _ in 0..<operations {
            let up = lock.withLock {
                guard let left = operationsBeforeDrop else { return true }
                operationsBeforeDrop = max(0, left - 1)
                return left > 0
            }
            guard up else { return false }
            slots.wait()
            usleep(useconds_t(seconds * 1e6))
            slots.signal()
        }
        return true
    }
}
