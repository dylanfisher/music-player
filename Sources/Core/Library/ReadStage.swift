import Foundation
import Metadata

/// Reads changed files on a fixed number of threads and stores the results in batches. The index
/// isn't `Sendable`; `lock` is what makes sharing it between the readers safe, and every field
/// below it is guarded by it.
final class ReadStage: @unchecked Sendable {
    private let files: [WalkedFile]
    private let known: [String: KnownFile]
    private let readers: Int
    private let control: ScanControl
    private let counter: ProgressCounter
    private let rootIsThere: @Sendable () -> Bool

    private let lock = NSLock()
    private let index: LibraryIndex
    private var next = 0
    private var batch: [ScannedFile] = []
    private var storeError: (any Error)?
    private(set) var read = 0
    private(set) var failed = 0
    private(set) var cancelled = false
    private(set) var rootLost = false

    init(
        _ files: [WalkedFile], known: [String: KnownFile], index: LibraryIndex, readers: Int,
        control: ScanControl, counter: ProgressCounter, rootIsThere: @escaping @Sendable () -> Bool
    ) {
        self.files = files
        self.known = known
        self.index = index
        self.readers = readers
        self.control = control
        self.counter = counter
        self.rootIsThere = rootIsThere
    }

    /// Returns once every file is read and stored, or the scan is cancelled, the root goes away
    /// or a store fails, which it rethrows.
    func run() throws {
        DispatchQueue.concurrentPerform(iterations: min(readers, max(files.count, 1))) { _ in
            while let file = take() {
                let outcome = Result { () throws(MetadataError) -> ParsedFile in
                    try readMetadata(at: URL(fileURLWithPath: file.path))
                }
                if case .failure(let error) = outcome, error.kind == .unreadable, !rootIsThere() {
                    lock.withLock { rootLost = true }
                    return
                }
                finish(
                    ScannedFile(
                        path: file.path, sizeBytes: file.sizeBytes,
                        modifiedSeconds: file.modifiedSeconds, known: known[file.path],
                        outcome: outcome))
            }
        }
        try lock.withLock {
            if let storeError { throw storeError }
            try flush()
        }
    }

    /// The next file to read, or nil when this reader should stop.
    private func take() -> WalkedFile? {
        // Outside the lock, since it blocks while the scan is paused.
        let proceed = control.proceed()
        return lock.withLock {
            if !proceed { cancelled = true }
            guard proceed, !rootLost, storeError == nil, next < files.count else { return nil }
            next += 1
            return files[next - 1]
        }
    }

    private func finish(_ file: ScannedFile) {
        lock.withLock {
            read += 1
            if case .failure = file.outcome { failed += 1 }
            batch.append(file)
            if batch.count >= LibraryScanner.batchSize {
                do {
                    try flush()
                } catch {
                    storeError = error
                }
            }
            // Every file would wake a waiting progress reader 43k times a scan for no visible
            // difference.
            if read % 32 == 0 || read == files.count {
                counter.update { [read, failed] in
                    $0.read = read
                    $0.failed = failed
                }
            }
        }
    }

    /// Called with `lock` held.
    private func flush() throws {
        guard !batch.isEmpty else { return }
        try index.store(batch)
        batch.removeAll(keepingCapacity: true)
    }
}
