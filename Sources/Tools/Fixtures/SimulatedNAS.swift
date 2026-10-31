import Foundation
import Library
import Metadata

/// Files on this Mac, scanned as if they were on a NAS: a network volume where each operation
/// (listing a directory, and opening, reading and closing a file) takes `latencySeconds`, and
/// at most `capacity` are served at once while the rest wait. It tells the scanner the volume is
/// a network one, so the scan tunes its readers as it would on the NAS.
public final class SimulatedNAS: ScanFileAccess, @unchecked Sendable {
    public let latencySeconds: Double
    public let capacity: Int
    private let slots: DispatchSemaphore
    private let system = SystemFileAccess()
    // Guarded by `lock`.
    private let lock = NSLock()
    private var reading = 0
    private var mostReading = 0

    public init(latencySeconds: Double, capacity: Int) {
        precondition(latencySeconds >= 0 && capacity > 0, "a NAS that can't serve anything")
        self.latencySeconds = latencySeconds
        self.capacity = capacity
        slots = DispatchSemaphore(value: capacity)
    }

    /// The most files that were being read at once.
    public var mostFilesReadAtOnce: Int { lock.withLock { mostReading } }

    public func volumeIsLocal(_ path: String) throws -> Bool? { false }

    public func contentsOfDirectory(_ directory: String, keys: [URLResourceKey]) throws -> [URL] {
        serve(1)
        return try system.contentsOfDirectory(directory, keys: keys)
    }

    public func readMetadata(at path: String) throws(MetadataError) -> ParsedFile {
        lock.withLock {
            reading += 1
            mostReading = max(mostReading, reading)
        }
        defer { lock.withLock { reading -= 1 } }
        // Opening, then each read the parser made (one, when it failed), then closing.
        serve(1)
        let result = Result { () throws(MetadataError) -> ParsedFile in
            try system.readMetadata(at: path)
        }
        let reads =
            switch result {
            case .success(let parsed): parsed.readCount
            case .failure: 1
            }
        serve(reads + 1)
        return try result.get()
    }

    private func serve(_ operations: Int) {
        for _ in 0..<operations {
            slots.wait()
            usleep(useconds_t(latencySeconds * 1e6))
            slots.signal()
        }
    }
}
