import Foundation
import Settings

/// One scan the watcher runs: a whole watched folder, or only the listed directories in it.
struct WatchJob: Equatable, Sendable {
    var folder: WatchedFolder
    /// Empty for the whole folder.
    var subtrees: [String]
}

/// What the watcher scans and when, apart from timers, FSEvents and threads, so tests can drive
/// it with a fake clock and a fake playback engine. One scan runs at a time.
///
/// Local folders are scanned whole at start, then by the subtrees FSEvents reports. Network
/// folders are polled: at start, then `pollIntervalMinutes` after each scan ends, and never
/// while playback holds polls back.
struct WatchState {
    /// How long after a failed scan of a local folder it's scanned again, whole. FSEvents
    /// reports a change once, so a failed scan would otherwise lose it until the next launch;
    /// the wait keeps a full disk or a locked database from making it spin.
    static let failedScanRetrySeconds = 60.0

    let folders: [WatchedFolder]
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

    init(folders: [WatchedFolder], pausePollingDuringPlayback: Bool, now: Date) {
        self.folders = folders
        self.pausePollingDuringPlayback = pausePollingDuringPlayback
        wholeScans = folders.filter { $0.kind == .local }.map(\.path)
        for folder in folders where folder.kind == .network { pollDue[folder.path] = now }
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
    var holdsRunningScan: Bool { running?.folder.kind == .network && !pollsAllowed }

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
        } else if let (path, _) = retryDue.filter({ $0.value <= now }).min(by: {
            $0.value < $1.value
        }) {
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
        if job.folder.kind == .network {
            pollDue[job.folder.path] = now.addingTimeInterval(
                TimeInterval(job.folder.pollIntervalMinutes * 60))
        }
    }

    /// The running scan failed at `now`, as on a full disk. A polled folder waits for its next
    /// poll; a local folder is scanned whole `failedScanRetrySeconds` later.
    mutating func failed(now: Date) {
        guard let job = running else { preconditionFailure("no scan is running") }
        guard job.folder.kind == .local else { return finished(now: now) }
        running = nil
        retryDue[job.folder.path] = now.addingTimeInterval(Self.failedScanRetrySeconds)
    }

    /// When the next poll or retry falls due, for a one-shot timer. Nil when none is pending;
    /// polls held back don't count, since `playbackChanged` wakes the watcher then. One already
    /// due runs when the running scan finishes.
    func nextPoll(after now: Date) -> Date? {
        let polls = pollsAllowed ? Array(pollDue.values) : []
        return (polls + retryDue.values).filter { $0 > now }.min()
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
