import Settings

/// What the watcher's scans are doing, so the window can refresh as rows arrive and show what
/// went wrong.
public enum WatcherEvent: Sendable {
    /// A scan of the watched folder at this path is under way and may have stored rows. Sent at
    /// most once per `LibraryWatcher.progressIntervalSeconds`.
    case scanning(folder: String, ScanProgress)
    /// Pause Scan held the running scan of the watched folder at this path, or, false, Resume
    /// Scan let it go on. Its `scanned`, `scanFailed` or `scanStopped` ends the pause too.
    case scanPaused(folder: String, Bool)
    case scanned(folder: String, ScanSummary)
    /// Files the tag editor wrote were read again and stored (`LibraryWatcher.rescan(files:)`).
    case edited(ScanSummary)
    /// The scan stopped because the database failed. What it stored before then stays.
    case scanFailed(folder: String, reason: String)
    /// `LibraryWatcher.stop()` cancelled the scan of the watched folder at this path, as when
    /// a folder is removed or Settings restart the watcher. What it stored stays.
    case scanStopped(folder: String)
    /// At start, the network folder at this path shows what the index holds, and is first
    /// polled `pollIntervalMinutes` later.
    case keptIndex(folder: String)
    /// Every folder's scan at start has ended, or was left to the index: once per start.
    case launchScansEnded
    /// At start, this many files outside every watched folder left the index, such as those of a
    /// folder no longer watched.
    case removed(count: Int)
    /// The watched folders are at these paths now, in the order Settings lists them, since a
    /// share they're on was mounted somewhere else (ADR 0028).
    case folders([WatchedFolder])
    /// A sync with the sync folder ran (ADR 0038).
    case synced(SyncReport)
    /// The sync folder couldn't be used, or this machine's log there didn't match.
    case syncFailed(reason: String)
}
