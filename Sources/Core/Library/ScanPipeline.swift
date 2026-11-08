import Foundation
import Log
import Metadata
import Settings

/// Walks a folder and reads its new and changed files at the same time, storing the results in
/// batches. Listers walk depth-first and queue each directory's changed files in listing order,
/// so neighbouring files are read together; readers take them under a limit that
/// `ReadConcurrency` can change mid-scan.
///
/// The index isn't `Sendable`; `storeLock` is what makes sharing it between the threads safe,
/// since a store takes about 12 ms per batch and mustn't stall the readers and listers, which
/// share `condition`. Every field below `condition` is guarded by it.
final class ScanPipeline: @unchecked Sendable {
    /// Directories listed at once. A listing is a round trip or two that yields about ten files,
    /// each of which costs several to read, so a few listers stay ahead of many readers without
    /// crowding the NAS with directory requests.
    static let listers = 4
    /// A throughput window closes once it's at least this long and each reader has finished
    /// `windowFilesPerReader` files in it, so a few slow files don't decide the level. On a cold
    /// NAS a file can take ten times the median, and shorter windows of 15 to 30 files hid a
    /// doubling's gain in that noise.
    static let windowSeconds = 2.0
    static let windowFilesPerReader = 4
    /// The most walk problems one scan lists. A folder of a million links or unreadable files
    /// would otherwise make a summary of a million lines.
    static let maximumIssues = 100

    /// What the walk and the reads found.
    struct Outcome {
        /// Every audio file the walk found, changed or not.
        var seen: Set<String> = []
        var otherFiles = 0
        /// The walk's first `maximumIssues` problems.
        var issues: [ScanIssue] = []
        /// How many more there were, and the first of them.
        var moreIssues = 0
        var firstMoreIssue: ScanIssue?
        /// Every directory or entry the walk couldn't read, listed or not, which the scan
        /// mustn't remove anything under.
        var unreadablePaths: [String] = []
        /// Entries in `root`'s listing, when it was listed.
        var rootEntries: Int?
        var unchanged = 0
        var read = 0
        var failed = 0
        var cancelled = false
        var rootLost = false
        var readers = ScanSummary.Readers.fixed(0)
        var readCost = ScanSummary.ReadCost()
        var idleReaderSeconds = 0.0
        var windows = ScanSummary.Windows()
    }

    private let root: String
    private let filter: FolderFilter
    private let known: [String: KnownFile]
    /// Whether a known file whose size or time changed is read again (`ScanOptions`).
    private let rescansModifiedFiles: Bool
    /// The paths removed from the library, in NFC, which the walk passes over.
    private let removed: Set<String>
    /// Directories the walk doesn't descend into: the staging folder (`ScanOptions`).
    private let skipped: [String]
    private let access: any ScanFileAccess
    private let control: ScanControl
    private let counter: ProgressCounter
    private let rootIsThere: @Sendable () -> Bool
    private let threads = DispatchGroup()

    private let storeLock = NSLock()
    private let index: LibraryIndex
    private let condition = NSCondition()
    private var outcome = Outcome()
    /// Directories still to list, popped from the end.
    private var directories: [String]
    private var listing = 0
    private var found = 0
    /// Changed files waiting for a reader, taken from `nextQueued` on.
    private var queued: [WalkedFile] = []
    private var nextQueued = 0
    private var toRead = 0
    private var limit: Int
    private var readerThreads = 0
    /// Readers waiting in `nextFile` for the walk.
    private var idleReaders = 0
    private var controller: ReadConcurrency?
    private var window: Window
    private var batch: [ScannedFile] = []
    private var storeError: (any Error)?
    private let batchSize: Int

    /// Files finished since `start`, and whether readers waited for the walk or the scan paused
    /// during it, either of which makes its throughput say nothing about the NAS.
    struct Window {
        var start: UInt64
        var pauseChanges: Int
        var files = 0
        var seconds = 0.0
        var starved = false

        /// Whether it's long enough, and has enough files for `readers`, to close.
        func isDue(at now: UInt64, readers: Int) -> Bool {
            Double(now - start) / 1e9 >= ScanPipeline.windowSeconds
                && files >= ScanPipeline.windowFilesPerReader * readers
        }

        /// What the controller should see, or nil for a window that says nothing about the NAS:
        /// one that waited for the walk, or that spans or ends in a pause. `pause` was read
        /// before `now`, so a pause that begins in between only drops the next window.
        func measurement(at now: UInt64, pause: (isPaused: Bool, changes: Int))
            -> ReadConcurrency.Window?
        {
            guard !starved, !pause.isPaused, pause.changes == pauseChanges else { return nil }
            let elapsed = Double(now - start) / 1e9
            return .init(
                filesPerSecond: Double(files) / elapsed, secondsPerFile: seconds / Double(files))
        }
    }

    /// Scans `starts`, each `root` or a directory inside it that the filter includes. It starts
    /// with `readers`, and `controller`, if any, changes that as it measures.
    init(
        _ starts: [String], root: String, filter: FolderFilter, known: [String: KnownFile],
        removed: Set<String>, skipped: [String] = [], index: LibraryIndex,
        controller: ReadConcurrency?, readers: Int,
        access: any ScanFileAccess,
        control: ScanControl,
        counter: ProgressCounter, batchSize: Int, rescansModifiedFiles: Bool = true,
        rootIsThere: @escaping @Sendable () -> Bool
    ) {
        self.batchSize = batchSize
        self.rescansModifiedFiles = rescansModifiedFiles
        directories = starts.reversed()
        self.root = root
        self.filter = filter
        self.known = known
        self.removed = removed
        self.skipped = skipped
        self.index = index
        self.access = access
        self.control = control
        self.counter = counter
        self.rootIsThere = rootIsThere
        precondition(readers > 0, "a scan needs at least one reader")
        self.controller = controller
        limit = readers
        window = Window(
            start: DispatchTime.now().uptimeNanoseconds, pauseChanges: control.pauseState.changes)
    }

    /// Returns once the walk has finished and every changed file is read and stored, or the scan
    /// is cancelled, the root goes away or a store fails, which it rethrows.
    func run() throws -> Outcome {
        condition.withLock {
            for _ in 0..<Self.listers { spawn(lister) }
            setLimit(limit)
        }
        threads.wait()
        return try condition.withLock {
            if let storeError { throw storeError }
            // Every thread has finished, so no store is running.
            if !batch.isEmpty { try index.store(batch) }
            outcome.readers =
                controller.map { .tuned($0.trace, climbing: $0.isClimbing) } ?? .fixed(limit)
            return outcome
        }
    }

    // MARK: Walking

    private func lister() {
        while let directory = nextDirectory() {
            // Foundation autoreleases each listing's URLs, and these threads have no pool of
            // their own to drain them.
            let listed = autoreleasepool {
                list(directory, root: root, filter: filter, access: access)
            }
            add(listed, of: directory)
        }
    }

    private func nextDirectory() -> String? {
        // Outside the lock, since it blocks while the scan is paused.
        let proceed = control.proceed()
        return condition.withLock {
            if !proceed { cancel() }
            while directories.isEmpty && listing > 0 && !stopped { condition.wait() }
            guard !stopped, let directory = directories.popLast() else { return nil }
            listing += 1
            return directory
        }
    }

    private func add(_ listed: DirectoryListing, of directory: String) {
        condition.withLock {
            listing -= 1
            if directory == root { outcome.rootEntries = listed.entries }
            outcome.otherFiles += listed.otherFiles
            for issue in listed.issues {
                if issue.kind == .unreadable { outcome.unreadablePaths.append(issue.path) }
                if outcome.issues.count < Self.maximumIssues {
                    outcome.issues.append(issue)
                } else {
                    if outcome.moreIssues == 0 { outcome.firstMoreIssue = issue }
                    outcome.moreIssues += 1
                }
            }
            directories += listed.directories.reversed().filter { directory in
                !skipped.contains { isPath(directory, inOrAt: $0) }
            }
            found += listed.files.count
            for file in listed.files {
                if !removed.isEmpty,
                    removed.contains(file.path.precomposedStringWithCanonicalMapping)
                {
                    continue
                }
                outcome.seen.insert(file.path)
                if isChanged(file) {
                    queued.append(file)
                    toRead += 1
                } else {
                    outcome.unchanged += 1
                }
            }
            counter.update { [found, unchanged = outcome.unchanged, toRead, walkFinished, load] in
                $0.stage = walkFinished ? .reading : .walking
                $0.found = found
                $0.unchanged = unchanged
                $0.toRead = toRead
                $0.load = load
            }
            condition.broadcast()
        }
    }

    private func isChanged(_ file: WalkedFile) -> Bool {
        guard let previous = known[file.path] else { return true }
        // An unreadable file is read again whatever the setting: it didn't change, it failed.
        return previous.failure == .unreadable
            || (rescansModifiedFiles
                && (previous.sizeBytes != file.sizeBytes
                    || previous.modifiedSeconds != file.modifiedSeconds))
    }

    /// Called with `condition` held.
    private var walkFinished: Bool { directories.isEmpty && listing == 0 }

    /// Called with `condition` held.
    private var load: ScanProgress.Load {
        .init(
            readers: limit, idleReaders: idleReaders, listers: listing,
            queued: queued.count - nextQueued)
    }

    // MARK: Reading

    private func reader() {
        while let file = nextFile() {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = Result { () throws(MetadataError) -> ParsedFile in
                try access.readMetadata(at: file.path)
            }
            if case .failure(let error) = result, error.kind == .unreadable, !rootIsThere() {
                condition.withLock {
                    readerThreads -= 1
                    outcome.rootLost = true
                    condition.broadcast()
                }
                return
            }
            finish(
                ScannedFile(
                    path: file.path, sizeBytes: file.sizeBytes,
                    modifiedSeconds: file.modifiedSeconds, createdSeconds: file.createdSeconds,
                    known: known[file.path], outcome: result),
                seconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
        }
    }

    /// The next file to read, or nil when this reader should stop, which it has then been
    /// counted as doing.
    private func nextFile() -> WalkedFile? {
        let proceed = control.proceed()
        return condition.withLock {
            if !proceed { cancel() }
            while true {
                if stopped || readerThreads > limit { break }
                if nextQueued < queued.count {
                    let file = queued[nextQueued]
                    nextQueued += 1
                    if nextQueued == queued.count {
                        queued.removeAll(keepingCapacity: true)
                        nextQueued = 0
                    }
                    return file
                }
                if walkFinished { break }
                window.starved = true
                idleReaders += 1
                let waited = DispatchTime.now().uptimeNanoseconds
                condition.wait()
                outcome.idleReaderSeconds +=
                    Double(DispatchTime.now().uptimeNanoseconds - waited) / 1e9
                idleReaders -= 1
            }
            readerThreads -= 1
            return nil
        }
    }

    private func finish(_ file: ScannedFile, seconds: Double) {
        let full: [ScannedFile]? = condition.withLock {
            outcome.read += 1
            switch file.outcome {
            case .success(let parsed):
                outcome.readCost.files += 1
                outcome.readCost.bytes += parsed.bytesRead
                outcome.readCost.calls += parsed.readCount
                outcome.readCost.openSeconds += parsed.openSeconds
                outcome.readCost.readSeconds += parsed.readSeconds
                outcome.readCost.fileSeconds += seconds
            case .failure: outcome.failed += 1
            }
            batch.append(file)
            var full: [ScannedFile]?
            if batch.count >= batchSize {
                full = batch
                batch = []
                batch.reserveCapacity(batchSize)
            }
            // Every file would wake a waiting progress reader 43k times a scan for no visible
            // difference.
            if outcome.read % 32 == 0 || outcome.read == toRead {
                counter.update { [read = outcome.read, failed = outcome.failed, load] in
                    $0.read = read
                    $0.failed = failed
                    $0.load = load
                }
            }
            measure(seconds)
            return full
        }
        if let full { store(full) }
    }

    /// Stores a full batch outside `condition`, one thread at a time. A failure stops the scan.
    private func store(_ files: [ScannedFile]) {
        storeLock.withLock {
            guard condition.withLock({ storeError == nil }) else { return }
            do {
                try signposted(.scanBatch) { try index.store(files) }
            } catch {
                condition.withLock {
                    storeError = error
                    condition.broadcast()
                }
            }
        }
    }

    /// Adds a finished file to the window, and when the window closes, lets the controller pick
    /// the next level. Called with `condition` held.
    private func measure(_ seconds: Double) {
        guard var tuning = controller else { return }
        window.files += 1
        window.seconds += seconds
        let pause = control.pauseState
        let now = DispatchTime.now().uptimeNanoseconds
        guard window.isDue(at: now, readers: limit) else { return }
        if let measured = window.measurement(at: now, pause: pause) {
            outcome.windows.judged += 1
            tuning.observe(measured)
            controller = tuning
            setLimit(tuning.level)
        } else if window.starved {
            outcome.windows.waitedForWalk += 1
        } else {
            outcome.windows.paused += 1
        }
        window = Window(start: now, pauseChanges: pause.changes)
    }

    /// How many readers to start so `running` reaches `limit`. None once the scan has stopped,
    /// or the walk has finished and nothing is queued, since they would only exit.
    static func readersToSpawn(
        running: Int, limit: Int, stopped: Bool, walkFinished: Bool, queued: Int
    ) -> Int {
        guard !stopped, !walkFinished || queued > 0 else { return 0 }
        return max(limit - running, 0)
    }

    /// Called with `condition` held. Readers above a lowered limit stop at their next file.
    private func setLimit(_ level: Int) {
        limit = level
        for _
            in 0..<Self.readersToSpawn(
                running: readerThreads, limit: limit, stopped: stopped, walkFinished: walkFinished,
                queued: queued.count - nextQueued)
        {
            readerThreads += 1
            spawn(reader)
        }
        condition.broadcast()
    }

    // MARK: Shared

    private func spawn(_ body: @escaping @Sendable () -> Void) {
        threads.enter()
        let thread = Thread { [threads] in
            body()
            threads.leave()
        }
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
    }

    /// Called with `condition` held.
    private var stopped: Bool { outcome.cancelled || outcome.rootLost || storeError != nil }

    /// Called with `condition` held.
    private func cancel() {
        outcome.cancelled = true
        condition.broadcast()
    }
}
