import Foundation
import Settings

/// One scan the watcher runs: a whole watched folder, or only the listed directories in it.
struct WatchJob: Equatable, Sendable {
    var folder: WatchedFolder
    /// Empty for the whole folder.
    var subtrees: [String]
    /// Rescan Now asked for it, so it runs while playing even if `pausePollingDuringPlayback`
    /// says not to. It still waits while a track starts, which takes seconds.
    var ignoresPlaybackPause = false
}

/// What the watcher scans and when, apart from timers, FSEvents and threads, so tests can drive
/// it with a fake clock and a fake playback engine. One scan runs at a time.
///
/// Local folders are scanned whole at start, then by the subtrees FSEvents reports. Network
/// folders are polled `pollIntervalMinutes` after start and after each scan ends, and never
/// while playback holds polls back. One the index holds no files for is polled at start.
struct WatchState {
    /// How long after a failed scan of a local folder it's first scanned again, whole. FSEvents
    /// reports a change once, so a failed scan would otherwise lose it until the next launch;
    /// the wait keeps a full disk or a locked database from making it spin. Each failure in a
    /// row doubles it, up to `longestRetrySeconds`.
    static let failedScanRetrySeconds = 60.0
    static let longestRetrySeconds = 15.0 * 60

    private(set) var folders: [WatchedFolder]
    private(set) var running: WatchJob?
    private var activity = PlaybackActivity.stopped
    private var pausePollingDuringPlayback: Bool
    /// Local folders queued for a whole scan, by path.
    private var wholeScans: [String]
    /// Changed directories under each folder, by the folder's path: from FSEvents for local
    /// folders, and from tag edits for any folder.
    private var changed: [String: Set<String>] = [:]
    /// When each network folder's next poll is due, by path. Absent while it's being scanned.
    private var pollDue: [String: Date] = [:]
    /// When each local folder whose scan failed is scanned again, by path.
    private var retryDue: [String: Date] = [:]
    /// Scans of each folder that failed in a row, by path; absent after one that finished.
    private var failuresInARow: [String: Int] = [:]
    /// Network folders Rescan Now asked for, by path, in Settings order.
    private var requested: [String] = []
    /// The network folders not polled at start, by path, in Settings order.
    private(set) var leftToTheIndex: [String] = []

    /// `indexed` is the network folders, by path, the index already holds files for. Unless
    /// `rescanNetworkFoldersAtLaunch`, those show what the index holds until their first poll,
    /// since walking a share at launch keeps the NAS busy when the first track is read.
    init(
        folders: [WatchedFolder], indexed: Set<String>, rescanNetworkFoldersAtLaunch: Bool,
        pausePollingDuringPlayback: Bool, now: Date
    ) {
        self.folders = folders
        self.pausePollingDuringPlayback = pausePollingDuringPlayback
        wholeScans = folders.filter { $0.kind == .local }.map(\.path)
        for folder in folders where folder.kind == .network {
            if indexed.contains(folder.path) && !rescanNetworkFoldersAtLaunch {
                pollDue[folder.path] = now.addingTimeInterval(
                    TimeInterval(folder.pollIntervalMinutes * 60))
                leftToTheIndex.append(folder.path)
            } else {
                pollDue[folder.path] = now
            }
        }
    }

    /// The folders at new paths, in the same order, after a share moved (ADR 0028). What was
    /// pending for each moves with it, but its changed directories are dropped: a moved network
    /// folder is polled now, which scans it whole at its new path.
    mutating func relocated(_ moved: [WatchedFolder], now: Date) {
        precondition(moved.count == folders.count, "relocated a different set of folders")
        precondition(running == nil, "relocated during a scan")
        for (old, new) in zip(folders, moved) where old.path != new.path {
            changed[old.path] = nil
            wholeScans = wholeScans.map { $0 == old.path ? new.path : $0 }
            requested = requested.map { $0 == old.path ? new.path : $0 }
            retryDue[new.path] = retryDue.removeValue(forKey: old.path)
            failuresInARow[new.path] = failuresInARow.removeValue(forKey: old.path)
            pollDue[old.path] = nil
            if new.kind == .network { pollDue[new.path] = now }
        }
        folders = moved
    }

    /// Directories FSEvents reports changed. Paths outside every local folder are ignored.
    mutating func directoriesChanged(_ paths: [String]) {
        for path in paths {
            guard let folder = localFolder(containing: path) else { continue }
            changed[folder.path, default: []].insert(path)
        }
    }

    /// Directories whose files the tag editor wrote. Network folders get these too, since
    /// FSEvents reports nothing there; they wait for playback as polls do.
    mutating func directoriesEdited(_ paths: [String]) {
        for path in paths {
            guard
                let folder = folders.first(where: {
                    $0.path == path || isPath(path, under: $0.path)
                })
            else { continue }
            changed[folder.path, default: []].insert(path)
        }
    }

    /// FSEvents lost track of a folder's changes (events dropped, or the folder itself moved),
    /// so the whole folder is scanned again.
    mutating func folderNeedsWholeScan(containing path: String) {
        guard let folder = localFolder(containing: path), !wholeScans.contains(folder.path)
        else { return }
        wholeScans.append(folder.path)
        changed[folder.path] = nil
    }

    /// Rescan Now: every folder is scanned whole, network ones too while playing with
    /// `pausePollingDuringPlayback` on. A running whole scan of a folder counts for it, and
    /// stops waiting for playback.
    mutating func rescanEverything() {
        for folder in folders {
            if running?.folder.path == folder.path, running?.subtrees.isEmpty == true {
                running?.ignoresPlaybackPause = true
            } else if folder.kind == .local {
                if !wholeScans.contains(folder.path) { wholeScans.append(folder.path) }
                changed[folder.path] = nil
            } else if !requested.contains(folder.path) {
                requested.append(folder.path)
            }
        }
    }

    mutating func playbackChanged(_ activity: PlaybackActivity, pausePollingDuringPlayback: Bool) {
        self.activity = activity
        self.pausePollingDuringPlayback = pausePollingDuringPlayback
    }

    /// Whether network folders may be scanned now.
    var pollsAllowed: Bool {
        switch activity {
        case .stopped: true
        case .starting: false
        case .playing: !pausePollingDuringPlayback
        }
    }

    /// Whether the running scan has to wait for playback.
    var holdsRunningScan: Bool {
        guard let running else { return false }
        guard running.folder.kind == .network else { return false }
        return activity == .starting || (!running.ignoresPlaybackPause && !pollsAllowed)
    }

    /// The scan to start now, which then counts as running, or nil when one is already running
    /// or nothing may run. Local changes go first, since someone is likely waiting to see them.
    mutating func start(now: Date) -> WatchJob? {
        guard running == nil else { return nil }
        let job: WatchJob
        if let (path, directories) = changed.first(where: { entry in
            !entry.value.isEmpty && (folder(entry.key).kind == .local || pollsAllowed)
        }) {
            changed[path] = nil
            job = WatchJob(folder: folder(path), subtrees: directories.sorted())
        } else if !wholeScans.isEmpty {
            let path = wholeScans.removeFirst()
            changed[path] = nil
            retryDue[path] = nil
            job = WatchJob(folder: folder(path), subtrees: [])
        } else if activity != .starting, !requested.isEmpty {
            let path = requested.removeFirst()
            changed[path] = nil
            pollDue[path] = nil
            job = WatchJob(folder: folder(path), subtrees: [], ignoresPlaybackPause: true)
        } else if pollsAllowed,
            let (path, _) = retryDue.filter({ $0.value <= now }).min(by: {
                $0.value < $1.value
            })
        {
            retryDue[path] = nil
            changed[path] = nil
            job = WatchJob(folder: folder(path), subtrees: [])
        } else if pollsAllowed,
            let (path, _) = pollDue.filter({ $0.value <= now }).min(by: { $0.value < $1.value })
        {
            pollDue[path] = nil
            job = WatchJob(folder: folder(path), subtrees: [])
        } else {
            return nil
        }
        running = job
        return job
    }

    /// The running scan ended at `now`. A polled folder is next due an interval later.
    mutating func finished(now: Date) {
        guard let job = running else { preconditionFailure("no scan is running") }
        running = nil
        failuresInARow[job.folder.path] = nil
        if job.folder.kind == .network {
            pollDue[job.folder.path] = now.addingTimeInterval(
                TimeInterval(job.folder.pollIntervalMinutes * 60))
        }
    }

    /// The running scan failed at `now`, as on a full disk. A polled folder waits for its next
    /// poll; a local folder is scanned whole `failedScanRetrySeconds` later, doubling with each
    /// failure in a row. True for the first failure of a run of them, the one worth reporting.
    mutating func failed(now: Date) -> Bool {
        guard let job = running else { preconditionFailure("no scan is running") }
        let path = job.folder.path
        let failures = (failuresInARow[path] ?? 0) + 1
        if job.folder.kind == .local {
            running = nil
            let wait = min(
                Self.failedScanRetrySeconds * pow(2, Double(failures - 1)), Self.longestRetrySeconds
            )
            retryDue[path] = now.addingTimeInterval(wait)
        } else {
            finished(now: now)
        }
        failuresInARow[path] = failures
        return failures == 1
    }

    /// When the next poll or retry falls due, for a one-shot timer. Nil when none is pending;
    /// polls and retries held back for playback don't count, since `playbackChanged` wakes the watcher then. One already
    /// due runs when the running scan finishes.
    func nextPoll(after now: Date) -> Date? {
        guard pollsAllowed else { return nil }
        return (Array(pollDue.values) + retryDue.values).filter { $0 > now }.min()
    }

    private func localFolder(containing path: String) -> WatchedFolder? {
        folders.first { $0.kind == .local && ($0.path == path || isPath(path, under: $0.path)) }
    }

    private func folder(_ path: String) -> WatchedFolder {
        guard let folder = folders.first(where: { $0.path == path }) else {
            preconditionFailure("\(path) isn't a watched folder")
        }
        return folder
    }
}
