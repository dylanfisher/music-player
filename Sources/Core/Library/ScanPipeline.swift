import Foundation
import Metadata

/// Walks a folder and reads its new and changed files at the same time, storing the results in
/// batches. Listers walk depth-first and queue each directory's changed files in listing order,
/// so neighbouring files are read together; readers take them under a limit that
/// `ReadConcurrency` can change mid-scan.
///
/// The index isn't `Sendable`; `condition` is what makes sharing it between the threads safe,
/// and every field below it is guarded by it.
final class ScanPipeline: @unchecked Sendable {
    /// Directories listed at once. A listing is a round trip or two that yields about ten files,
    /// each of which costs several to read, so a few listers stay ahead of many readers without
    /// crowding the NAS with directory requests.
    static let listers = 4
    /// A throughput window closes once it's at least this long and each reader has finished
    /// `windowFilesPerReader` files in it, so one slow file doesn't decide the level.
    static let windowSeconds = 0.25
    static let windowFilesPerReader = 4

    enum Readers {
        case fixed(Int)
        case tuned(ReadConcurrency)
    }

    /// What the walk and the reads found.
    struct Outcome {
        /// Every audio file the walk found, changed or not.
        var seen: Set<String> = []
        var otherFiles = 0
        var issues: [ScanIssue] = []
        /// Entries in `root`'s listing, when it was listed.
        var rootEntries: Int?
        var unchanged = 0
        var read = 0
        var failed = 0
        var cancelled = false
        var rootLost = false
        var readers = ScanSummary.Readers.fixed(0)
    }

    private let root: String
    private let filter: FolderFilter
    private let known: [String: KnownFile]
    private let access: any ScanFileAccess
    private let control: ScanControl
    private let counter: ProgressCounter
    private let rootIsThere: @Sendable () -> Bool
    private let threads = DispatchGroup()

    private let condition = NSCondition()
    private let index: LibraryIndex
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
    private var controller: ReadConcurrency?
    private var window: Window
    private var batch: [ScannedFile] = []
    private var storeError: (any Error)?

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

    /// Scans `starts`, each `root` or a directory inside it that the filter includes.
    init(
        _ starts: [String], root: String, filter: FolderFilter, known: [String: KnownFile],
        index: LibraryIndex, readers: Readers, access: any ScanFileAccess, control: ScanControl,
        counter: ProgressCounter, rootIsThere: @escaping @Sendable () -> Bool
    ) {
        directories = starts.reversed()
        self.root = root
        self.filter = filter
        self.known = known
        self.index = index
        self.access = access
        self.control = control
        self.counter = counter
        self.rootIsThere = rootIsThere
        switch readers {
        case .fixed(let count):
            precondition(count > 0, "a scan needs at least one reader")
            limit = count
        case .tuned(let tuning):
            controller = tuning
            limit = tuning.level
        }
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
            try flush()
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
            outcome.issues += listed.issues
            directories += listed.directories.reversed()
            found += listed.files.count
            for file in listed.files {
                outcome.seen.insert(file.path)
                if isChanged(file) {
                    queued.append(file)
                    toRead += 1
                } else {
                    outcome.unchanged += 1
                }
            }
            counter.update { [found, unchanged = outcome.unchanged, toRead, walkFinished] in
                $0.stage = walkFinished ? .reading : .walking
                $0.found = found
                $0.unchanged = unchanged
                $0.toRead = toRead
            }
            condition.broadcast()
        }
    }

    private func isChanged(_ file: WalkedFile) -> Bool {
        guard let previous = known[file.path] else { return true }
        return previous.sizeBytes != file.sizeBytes
            || previous.modifiedSeconds != file.modifiedSeconds
            || previous.failure == .unreadable
    }

    /// Called with `condition` held.
    private var walkFinished: Bool { directories.isEmpty && listing == 0 }

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
                    modifiedSeconds: file.modifiedSeconds, known: known[file.path],
                    outcome: result),
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
                condition.wait()
            }
            readerThreads -= 1
            return nil
        }
    }

    private func finish(_ file: ScannedFile, seconds: Double) {
        condition.withLock {
            outcome.read += 1
            if case .failure = file.outcome { outcome.failed += 1 }
            batch.append(file)
            if batch.count >= LibraryScanner.batchSize {
                do {
                    try flush()
                } catch {
                    storeError = error
                    condition.broadcast()
                }
            }
            // Every file would wake a waiting progress reader 43k times a scan for no visible
            // difference.
            if outcome.read % 32 == 0 || outcome.read == toRead {
                counter.update { [read = outcome.read, failed = outcome.failed] in
                    $0.read = read
                    $0.failed = failed
                }
            }
            measure(seconds)
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
            tuning.observe(measured)
            controller = tuning
            setLimit(tuning.level)
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

    /// Called with `condition` held.
    private func flush() throws {
        guard !batch.isEmpty else { return }
        try index.store(batch)
        batch.removeAll(keepingCapacity: true)
    }
}
