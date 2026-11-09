import CoreServices
import Foundation
import Log
import Metadata
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
    private let mounts: any ShareMounts
    private let events: @Sendable (WatcherEvent) -> Void
    /// Guards every field below it, and runs FSEvents and timer callbacks.
    private let queue = DispatchQueue(label: "\(bundleIdentifier).watcher")
    private let scanQueue = DispatchQueue(label: "\(bundleIdentifier).scan", qos: .utility)
    /// Reads the files the tag editor wrote, one write's files at a time.
    private let editQueue = DispatchQueue(
        label: "\(bundleIdentifier).edited", qos: .userInitiated)
    private var state: WatchState?
    private var control: ScanControl?
    private var timer: DispatchSourceTimer?
    private var stream: FSEventStreamRef?
    /// Each local folder's path with symbolic links resolved, as FSEvents reports it, and the
    /// path as configured.
    private var resolvedFolders: [(resolved: String, configured: String)] = []
    /// The folders as Settings has them, and where each one's share was found when they were
    /// last located; nil for a folder stored by path.
    private var configured: [WatchedFolder] = []
    private var lookups: [ShareLookup?] = []
    /// Set by a trigger, or a failed try, until the folders are found again.
    private var locateDue = false
    /// The sync folder as Settings has it (ADR 0038); nil syncs nothing.
    private var syncFolder: SyncFolder?
    /// The staging folder as Settings has it (ADR 0144), and where it was last found: the
    /// share's mount points it could be under when the share is ambiguous, none when it isn't
    /// mounted. No scan reads in them.
    private var stagingFolder: StagingFolder?
    private var stagingPaths: [String] = []
    /// Set by a trigger or a scan's end until the next sync, and by an edit until the next push.
    private var syncDue = false
    private var pushDue = false
    private var syncing = false
    /// Set once `launchScansEnded` went out.
    private var launchReported = false

    /// `networkReaders` is the files a network scan reads at once, or nil to tune it per scan.
    /// `mounts` finds the shares that folders on one are under. `events` is called on a
    /// background thread for every scan's progress and outcome.
    public convenience init(
        databaseURL: URL, networkReaders: Int?, mounts: any ShareMounts = SystemShareMounts(),
        events: @escaping @Sendable (WatcherEvent) -> Void = { _ in }
    ) {
        self.init(
            scanner: LibraryScanner(databaseURL: databaseURL, networkReaders: networkReaders),
            mounts: mounts, events: events)
    }

    /// For tests, which scan through a simulated NAS.
    init(
        scanner: LibraryScanner, mounts: any ShareMounts,
        events: @escaping @Sendable (WatcherEvent) -> Void
    ) {
        self.scanner = scanner
        self.mounts = mounts
        self.events = events
    }

    /// Finds each of `folders` (ADR 0028), removes files outside them from the index unless
    /// there are none (ADR 0082), scans
    /// the local folders and the network ones whose last whole scan didn't finish, and starts watching
    /// them, and syncs through `syncFolder` at start once the local folders are scanned, after
    /// each scan and on each trigger. No scan reads in `stagingFolder`, wherever it's found.
    /// The caller reads them from Settings.
    public func start(
        folders: [WatchedFolder], syncFolder: SyncFolder? = nil,
        stagingFolder: StagingFolder? = nil,
        rescanNetworkFoldersAtLaunch: Bool, pausePollingDuringPlayback: Bool,
        options: ScanOptions = ScanOptions()
    ) {
        queue.async { [self] in
            precondition(state == nil, "the watcher is already running")
            configured = folders
            self.syncFolder = syncFolder
            self.stagingFolder = stagingFolder
            locateStaging()
            syncDue = true
            var located: [WatchedFolder]
            var locatedAll = true
            do {
                located = try locate()
            } catch {
                // The local folders are watched anyway, and the shares found again at the next
                // trigger or scan. Removing files outside the folders waits for a launch that
                // found them, or the files under a share's real root would read as outside.
                logger.error("couldn't find the watched folders on their shares: \(error)")
                events(
                    .scanFailed(
                        folder: folders.compactMap(\.share).joined(separator: ", "),
                        reason: "couldn't find the watched folders on their shares: \(error)"))
                located = lastKnown()
                locatedAll = false
                locateDue = true
            }
            let folders = located.map { $0.located(at: canonicalPath($0.path)) }
            let started = WatchState(
                folders: folders, indexed: indexed(folders),
                rescanNetworkFoldersAtLaunch: rescanNetworkFoldersAtLaunch,
                pausePollingDuringPlayback: pausePollingDuringPlayback, options: options,
                now: Date())
            state = started
            for path in started.leftToTheIndex { events(.keptIndex(folder: path)) }
            reportLaunchIfEnded()
            // No folders is what a lost or default config gives, so it never empties the index;
            // Stop Watching on the last folder calls `removeEveryFile` instead.
            if locatedAll, !folders.isEmpty { removeFiles(outside: folders) }
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

    /// Reads `files`, which the tag editor just wrote, again at once, on a queue of their own:
    /// not behind a running scan and not waiting for playback, since the user is looking at
    /// them. A file in `parsed`, as the tag writer read it back, is stored from that unless it
    /// changed since. Sends `edited` when they're stored. Their folders are rescanned after,
    /// as `rescan(directories:)` does, in case a scan read a file before the write and stores
    /// it after; that rescan finds them unchanged.
    public func rescan(files: [String], parsed: [String: StampedParse] = [:]) {
        editQueue.async { [scanner, events] in
            do {
                events(.edited(try scanner.rescan(files: files, parsed: parsed)))
            } catch {
                // The folder rescan below tries them again.
                logger.error("couldn't read the edited files again: \(error)")
            }
        }
        rescan(directories: Set(files.map { ($0 as NSString).deletingLastPathComponent }).sorted())
    }

    /// Rescan All: scans every watched folder whole, now, whatever the poll timer says and even
    /// while playing with `library.pausePollingDuringPlayback` on, since the owner asked for it.
    /// It still waits while a track starts.
    public func rescanNow() {
        queue.async { [self] in
            state?.rescanEverything()
            advance()
        }
    }

    /// Rescan: scans `chosen`, as Settings has them, whole, the way `rescanNow` scans them all.
    /// One no longer in Settings is skipped, since the watcher restarts without it.
    public func rescan(folders chosen: [WatchedFolder]) {
        queue.async { [self] in
            guard let current = state else { return }
            // The state holds each folder where it was found, in Settings order.
            let paths = chosen.compactMap { folder -> String? in
                guard let position = configured.firstIndex(of: folder) else {
                    logger.notice("not rescanning \(folder.path): it's no longer watched")
                    return nil
                }
                return current.folders[position].path
            }
            state?.rescan(wholeFolders: paths)
            advance()
        }
    }

    /// Pause Scan: the running scan stops before its next directory or file until `resumeScan`,
    /// whatever playback does, and other scans wait behind it. Nothing happens while none runs.
    public func pauseScan() {
        queue.async { [self] in
            guard let path = state?.pauseRunningScan() else { return }
            events(.scanPaused(folder: path, true))
            advance()
        }
    }

    /// Resume Scan: the scan paused by `pauseScan` goes on from where it was, unless playback
    /// holds it.
    public func resumeScan() {
        queue.async { [self] in
            guard let path = state?.resumeRunningScan() else { return }
            events(.scanPaused(folder: path, false))
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

    /// A share may have been mounted somewhere new: on wake, a network change or a mount. The
    /// folders are found again once no scan is running.
    public func sharesMayHaveMoved() {
        queue.async { [self] in
            locateDue = true
            syncDue = true
            advance()
        }
    }

    /// The user changed something in the library window: this machine's log goes to the sync
    /// folder, without reading the others'.
    public func pushSync() {
        queue.async { [self] in
            pushDue = true
            advance()
        }
    }

    /// Import Moves…: applies the move list at `list` (ADR 0026) on the scan queue, so between
    /// scans and syncs, which map the paths it changes.
    public func importMoves(from list: URL) async throws -> MoveListImport {
        try await withCheckedThrowingContinuation { continuation in
            scanQueue.async { [scanner] in
                continuation.resume(
                    with: Result {
                        try LibraryIndex(at: scanner.databaseURL).importMoves(from: list)
                    })
            }
        }
    }

    /// Applies `lines`, each an old absolute path and its new one, as `importMoves(from:)`
    /// applies a list's lines: for an upgrade, whose old files' stats go to the new ones
    /// (ADR 0147).
    public func importMoves(lines: [(from: String, to: String)]) async throws -> MoveListImport {
        try await withCheckedThrowingContinuation { continuation in
            scanQueue.async { [scanner] in
                continuation.resume(
                    with: Result {
                        try LibraryIndex(at: scanner.databaseURL).importMoves(
                            MoveList(moves: lines))
                    })
            }
        }
    }

    /// Runs `job` on the scan queue, so after the running scan or sync, paused or not, and
    /// before the next: a snapshot of the index (ADR 0142).
    public func betweenScans(_ job: @escaping @Sendable () -> Void) {
        scanQueue.async(execute: job)
    }

    /// Stop Watching on the last folder: removes every file from the index, as `start` does for
    /// the files outside the folders when there are some. Its stats stay, by path.
    public func removeEveryFile() {
        queue.async { [self] in removeFiles(outside: []) }
    }

    /// Removes the index's files outside `folders`, such as those of a folder no longer
    /// watched, before the first scan.
    private func removeFiles(outside folders: [WatchedFolder]) {
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
    }

    /// When the last whole scan of each network folder among `folders` that finished started,
    /// by path. When the index can't say, they're all scanned.
    private func indexed(_ folders: [WatchedFolder]) -> [String: Date] {
        let network = folders.filter { $0.kind == .network }
        guard !network.isEmpty else { return [:] }
        do {
            let index = try LibraryIndex(at: scanner.databaseURL)
            var started: [String: Date] = [:]
            for folder in network {
                started[folder.path] = try index.finishedWholeScan(of: folder.path)
            }
            return started
        } catch {
            logger.error(
                "couldn't tell which network folders were scanned whole; scanning them: \(error)")
            return [:]
        }
    }

    /// The configured folders where their paths were last, or, when the index can't say, a
    /// share folder at its URL, which no scan finds.
    private func lastKnown() -> [WatchedFolder] {
        do {
            return try LibraryIndex(at: scanner.databaseURL).lastKnownFolders(configured)
        } catch {
            logger.error("couldn't read where the watched folders were: \(error)")
            return configured.map { $0.share == nil ? $0 : $0.located(at: unfoundRoot(of: $0)) }
        }
    }

    /// The configured folders where they are now, rewriting the paths of any whose share
    /// moved, and notes where each share was found. Runs on `queue`.
    private func locate() throws -> [WatchedFolder] {
        let shares = configured.contains { $0.share != nil } ? try mounts.mountedShares() : []
        let index = try LibraryIndex(at: scanner.databaseURL)
        let before = try index.lastKnownFolders(configured)
        let located = try index.locate(configured, among: shares)
        lookups = configured.map { folder in
            folder.share.flatMap(ShareURL.init).map { ShareLookup($0, among: shares) }
        }
        if located != before { events(.folders(located)) }
        return located
    }

    /// After a trigger, or before a scan starts: finds the share folders again if a share is
    /// mounted somewhere other than when they were last located, or the last try failed. Runs
    /// on `queue`, with no scan running.
    private func relocateIfMoved(_ current: inout WatchState) {
        guard configured.contains(where: { $0.share != nil }) else { return }
        do {
            if !locateDue {
                let shares = try mounts.mountedShares()
                let now = configured.map { folder in
                    folder.share.flatMap(ShareURL.init).map { ShareLookup($0, among: shares) }
                }
                guard now != lookups else { return }
            }
            current.relocated(
                try locate().map { $0.located(at: canonicalPath($0.path)) }, now: Date())
            locateStaging()
            locateDue = false
        } catch {
            locateDue = true
            logger.error("couldn't find the watched folders on their shares again: \(error)")
        }
    }

    /// Starts the next scan if one may run, pauses or resumes the running one for playback,
    /// and sets the timer for the next poll. Runs on `queue`.
    private func advance() {
        guard var current = state else { return }
        defer { state = current }
        // Not under a running sync either, which maps paths by the roots it started with.
        if control == nil, !syncing {
            // Only on a trigger or before a scan, not on every FSEvents batch or playback change.
            var next = current
            if locateDue || next.start(now: Date()) != nil { relocateIfMoved(&current) }
        }
        if let control {
            if current.holdsRunningScan { control.pause() } else { control.resume() }
        }
        // A sync reads and writes the NAS, so it waits as network scans do, and runs between
        // scans on their queue. It waits for the local folders' launch scans too: merging a long
        // log can take minutes on an old Mac, and the window waits for the scan (ADR 0076).
        if control == nil, !syncing, syncDue || pushDue, current.pollsAllowed,
            !current.localLaunchScansPending, startSync(among: current.folders)
        {
            return
        }
        if !syncing, let job = current.start(now: Date()) {
            var skipping = job.options
            skipping.skippedFolders = stagingPaths
            let options = skipping
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
                        job.folder, only: job.subtrees, control: control, progress: progress,
                        options: options)
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
        guard state != nil else {
            // Stopped, so it ends with no outcome; the window still shows it, maybe paused.
            events(.scanStopped(folder: job.folder.path))
            return
        }
        switch result {
        case .success(let summary):
            state?.finished(now: Date())
            syncDue = true
            for issue in summary.issues { logger.error("\(issue.description)") }
            events(.scanned(folder: job.folder.path, summary))
        case .failure(let error):
            // Its retries fail the same way until something changes, so only the first is
            // logged as an error. Each still ends with its event, which clears the scan the
            // window shows and Analyze Library waits for.
            if state?.failed(now: Date()) == true {
                logger.error("scanning \(job.folder.path) failed: \(error)")
            } else {
                logger.notice("scanning \(job.folder.path) failed again: \(error)")
            }
            events(.scanFailed(folder: job.folder.path, reason: "\(error)"))
        }
        reportLaunchIfEnded()
        advance()
    }

    private func reportLaunchIfEnded() {
        guard !launchReported, state?.launchScansPending == false else { return }
        launchReported = true
        events(.launchScansEnded)
    }

    /// Starts a sync on the scan queue, or only a push when an edit is all that's due, and
    /// returns whether it did. Runs on `queue`, with no scan running.
    private func startSync(among folders: [WatchedFolder]) -> Bool {
        let pushOnly = !syncDue
        syncDue = false
        pushDue = false
        guard let syncFolder else { return false }
        let path: String
        do {
            switch try locate(syncFolder) {
            case .found(let found): path = found
            case .unmounted:
                logger.notice("the sync folder's share isn't mounted; changes wait in the library")
                return false
            case .ambiguous(let mountPoints):
                logger.notice(
                    "the sync folder's share could be any of \(mountPoints); changes wait in the library"
                )
                return false
            }
        } catch {
            events(.syncFailed(reason: "couldn't find the sync folder: \(error)"))
            return false
        }
        if let watched = folders.first(where: { isPath(path, inOrAt: $0.path) }) {
            events(
                .syncFailed(
                    reason: "the sync folder \(path) is inside the watched folder \(watched.path);"
                        + " it must be outside every watched folder, so nothing was synced"))
            return false
        }
        if let staging = stagingPaths.first(where: { stagingOverlap($0, [path]) != nil }) {
            events(
                .syncFailed(
                    reason: "the sync folder \(path) is in or around the staging folder"
                        + " \(staging), where downloads are deleted, so nothing was synced"))
            return false
        }
        syncing = true
        scanQueue.async { [self, scanner] in
            let result = Result {
                try LibraryIndex(at: scanner.databaseURL).sync(
                    folder: syncFolder.identity, at: path, pushOnly: pushOnly)
            }
            queue.async { [self] in
                syncing = false
                guard state != nil else { return }
                switch result {
                case .success(let report):
                    logger.info(
                        "synced with \(path): \(report.pushed) events out, \(report.applied) in")
                    for problem in report.problems { logger.error("\(problem)") }
                    events(.synced(report))
                case .failure(let error):
                    logger.error("syncing with \(path) failed: \(error)")
                    events(.syncFailed(reason: "\(path): \(error)"))
                }
                advance()
            }
        }
        return true
    }

    private func locate(_ folder: SyncFolder) throws -> SyncFolderPlace {
        Library.locate(folder, among: folder.share == nil ? [] : try mounts.mountedShares())
    }

    /// Finds the staging folder again. A share that can't be listed leaves the last paths
    /// found, so a scan never reads where the folder was. Runs on `queue`.
    private func locateStaging() {
        guard let stagingFolder else {
            stagingPaths = []
            return
        }
        let place: SyncFolderPlace
        do {
            place = Library.locate(
                stagingFolder,
                among: stagingFolder.share == nil ? [] : try mounts.mountedShares())
        } catch {
            logger.error("couldn't find the staging folder on its share: \(error)")
            return
        }
        switch place {
        case .found(let path): stagingPaths = [path]
        case .unmounted: stagingPaths = []
        case .ambiguous(let mountPoints):
            stagingPaths = mountPoints.map { mountPoint in
                canonicalPath(
                    stagingFolder.path.isEmpty ? mountPoint : mountPoint + "/" + stagingFolder.path)
            }
        }
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
