import CoreServices
import Foundation
import Log
import Settings

private let logger = moduleLogger()

/// Keeps the index in line with the watched folders while the app runs: FSEvents
/// for local folders, a poll for network ones, one scan at a time on its own thread.
///
/// Idle, it costs nothing but FSEvents' own delivery and one one-shot timer for the next poll;
/// no timer fires more often than a folder's `pollIntervalMinutes`.
public final class LibraryWatcher: @unchecked Sendable {
    /// How long FSEvents collects changes before reporting them, so copying an album in causes
    /// one rescan of its folder rather than one per file.
    static let fsEventsLatencySeconds = 2.0
    /// How often a running scan reports progress: often enough that rows appear while a long
    /// first scan runs, rarely enough that the window's refreshes cost little.
    public static let progressIntervalSeconds = 1.0

    private let scanner: LibraryScanner
    private let events: @Sendable (WatcherEvent) -> Void
    /// Guards every field below it, and runs FSEvents and timer callbacks.
    private let queue = DispatchQueue(label: "\(bundleIdentifier).watcher")
    private let scanQueue = DispatchQueue(label: "\(bundleIdentifier).scan", qos: .utility)
    private var state: WatchState?
    private var control: ScanControl?
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    /// Each local folder's path with symbolic links resolved, as FSEvents reports it, and the
    /// path as configured.
    private var resolvedFolders: [(resolved: String, configured: String)] = []

    /// `networkReaders` is the files a network scan reads at once, or nil to tune it per scan.
    /// `events` is called on a background thread for every scan's progress and outcome.
    public init(
        databaseURL: URL, networkReaders: Int?,
        events: @escaping @Sendable (WatcherEvent) -> Void = { _ in }
    ) {
        scanner = LibraryScanner(databaseURL: databaseURL, networkReaders: networkReaders)
        self.events = events
    }

    /// Removes files outside `folders` from the index, scans every folder, and starts watching
    /// them. The caller reads them from Settings.
    public func start(folders: [WatchedFolder], pausePollingDuringPlayback: Bool) {
        queue.async { [self] in
            precondition(state == nil, "the watcher is already running")
            let folders = folders.map { folder in
                var folder = folder
                folder.path = canonicalPath(folder.path)
                return folder
            }
            state = WatchState(
                folders: folders,
                pausePollingDuringPlayback: pausePollingDuringPlayback, now: Date())
            scanQueue.async { [scanner, events] in
                do {
                    let removed = try LibraryIndex(at: scanner.databaseURL).removeFiles(
                        outside: folders.map(\.path))
                    if removed > 0 {
                        logger.notice("removed \(removed) files outside the watched folders")
                        events(.removed(count: removed))
                    }
                } catch {
                    logger.error("couldn't remove files outside the watched folders: \(error)")
                }
            }
            watchLocalFolders(folders.filter { $0.kind == .local })
            advance()
        }
    }

    /// Stops watching and cancels a running scan, which keeps what it stored. FSEvents holds the
    /// watcher until then. Don't call it from a scan's progress or the watcher's own queue.
    public func stop() {
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            timer?.cancel()
            timer = nil
            control?.cancel()
            state = nil
        }
    }

    /// Rescans `directories`, whose files the tag editor just wrote, in local and network
    /// folders alike.
    public func rescan(directories: [String]) {
        queue.async { [self] in
            state?.directoriesEdited(directories.map(canonicalPath))
            advance()
        }
    }

    /// The playback engine's hook. While playback is starting no network scan starts, and a
    /// running one pauses; while playing, the same holds if `library.pausePollingDuringPlayback`
    /// is on.
    public func playbackChanged(_ activity: PlaybackActivity, pausePollingDuringPlayback: Bool) {
        queue.async { [self] in
            state?.playbackChanged(
                activity, pausePollingDuringPlayback: pausePollingDuringPlayback)
            advance()
        }
    }

    /// Starts the next scan if one may run, pauses or resumes the running one for playback,
    /// and sets the timer for the next poll. Runs on `queue`.
    private func advance() {
        guard var current = state else { return }
        defer { state = current }
        if let control {
            if current.holdsRunningScan { control.pause() } else { control.resume() }
        }
        if let job = current.start(now: Date()) {
            let control = ScanControl()
            self.control = control
            scanQueue.async { [self, scanner, events] in
                let (stream, progress) = ScanProgress.makeStream()
                let reported = Task.detached {
                    var last = Date.distantPast
                    for await update in stream
                    where Date().timeIntervalSince(last) >= Self.progressIntervalSeconds {
                        last = Date()
                        events(.scanning(folder: job.folder.path, update))
                    }
                }
                let result = Result {
                    try scanner.scan(
                        job.folder, only: job.subtrees, control: control, progress: progress)
                }
                progress.finish()
                Task { [self] in
                    // The last progress goes out before the outcome.
                    await reported.value
                    queue.async { [self] in finished(job, result) }
                }
            }
        }
        schedulePoll(at: current.nextPoll(after: Date()))
    }

    private func finished(_ job: WatchJob, _ result: Result<ScanSummary, any Error>) {
        control = nil
        guard state != nil else { return }
        switch result {
        case .success(let summary):
            state?.finished(now: Date())
            for issue in summary.issues { logger.error("\(issue.description)") }
            events(.scanned(folder: job.folder.path, summary))
        case .failure(let error):
            state?.failed(now: Date())
            logger.error("scanning \(job.folder.path) failed: \(error)")
            events(.scanFailed(folder: job.folder.path, reason: "\(error)"))
        }
        advance()
    }

    private func schedulePoll(at date: Date?) {
        timer?.cancel()
        timer = nil
        guard let date else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Polls are minutes apart, so a few seconds' slack lets the system batch the wakeup.
        timer.schedule(
            deadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.advance() }
        timer.resume()
        self.timer = timer
    }

    private func watchLocalFolders(_ folders: [WatchedFolder]) {
        guard !folders.isEmpty else { return }
        // realpath, not resolvingSymlinksInPath, which drops the "/private" FSEvents reports.
        resolvedFolders = folders.map { folder in
            let resolved = realpath(folder.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            }
            return (resolved ?? folder.path, folder.path)
        }
        // The stream retains the watcher, so a callback never reaches a freed one.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                info.map {
                    UnsafeRawPointer(Unmanaged<LibraryWatcher>.fromOpaque($0).retain().toOpaque())
                }
            },
            release: { info in
                info.map { Unmanaged<LibraryWatcher>.fromOpaque($0).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, fsEventsCallback, &context,
                folders.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.fsEventsLatencySeconds,
                flags)
        else {
            logger.error("FSEvents refused to watch \(folders.map(\.path)); changes need a rescan")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            logger.error("FSEvents couldn't start watching \(folders.map(\.path))")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// Runs on `queue`.
    fileprivate func received(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let wholeScanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        var directories: [String] = []
        for event in events {
            let path = configuredPath(event.path)
            if event.flags & wholeScanFlags != 0 {
                state?.folderNeedsWholeScan(containing: path)
            } else {
                directories.append(path)
            }
        }
        state?.directoriesChanged(directories)
        advance()
    }

    /// An FSEvents path, which has symbolic links resolved and ends in "/", spelled as the
    /// watched folder is configured, since the index stores paths that way.
    private func configuredPath(_ eventPath: String) -> String {
        let path = canonicalPath(eventPath)
        for folder in resolvedFolders {
            if path == folder.resolved { return folder.configured }
            if isPath(path, under: folder.resolved) {
                return folder.configured + path.dropFirst(folder.resolved.count)
            }
        }
        return path
    }
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    watcher.received((0..<count).map { (paths[$0], flags[$0]) })
}

/// Throws `LibraryError.notWatched` unless `path` is one of `folders`.
public func requireWatched(_ path: String, in folders: [WatchedFolder]) throws {
    guard folders.contains(where: { canonicalPath($0.path) == canonicalPath(path) }) else {
        throw LibraryError.notWatched(path)
    }
}
